/* AArch64 interrupts: the GIC, as the ACPI MADT describes it, and the
 * generic timer.
 *
 * The Generic Interrupt Controller comes in two shapes that matter here
 * (Arm IHI 0048 for version 2, IHI 0069 for versions 3 and 4). Both have a
 * distributor, one for the whole machine, with a switch and a priority for
 * every interrupt. They differ in the part each processor has to itself:
 *
 *   version 2   a CPU interface, which is more memory-mapped registers.
 *   version 3   a redistributor, memory-mapped, which takes over the
 *               switches for the processor's private interrupts, and a
 *               CPU interface that is reached through system registers.
 *
 * QEMU's virt machine has version 2 unless told otherwise, and UTM tells
 * it otherwise. Either way an interrupt is acknowledged, which says which
 * one it is, then handled, then ended. The only one in use so far is the
 * generic timer's (Arm ARM, chapter D12), private to each processor. */
#include "acpi.h"
#include "arch.h"

/* Registers of the distributor. A redistributor has the same ones, at the
 * same offsets, in its second 64 KiB, for its 32 private interrupts. */
#define GICD_CTLR     0x000
#define GIC_GROUP     0x080 /* one bit an interrupt: group 1 arrives as an IRQ */
#define GIC_ENABLE    0x100 /* one bit an interrupt: writing a 1 switches it on */
#define GIC_PRIORITY  0x400 /* one byte an interrupt: lower is more urgent */

#define GICD_ON_V2    0x1
#define GICD_ON_V3    0x13         /* group 1 on, in both places the bit can be, and affinity routing */
#define GICD_BUSY     (1u << 31)   /* a write to GICD_CTLR is still taking effect */

/* Version 2: the CPU interface. */
#define GICC_CTLR     0x00
#define GICC_PRIORITY 0x04         /* only interrupts more urgent than this get through */
#define GICC_ACK      0x0c
#define GICC_END      0x10

/* Version 3: the first 64 KiB of a redistributor. */
#define GICR_TYPER    0x08         /* 64 bits: whose it is, in the upper half */
#define GICR_WAKER    0x14
#define GICR_LAST     (1u << 4)    /* in GICR_TYPER: no redistributor follows this one */
#define GICR_VLPIS    (1u << 1)    /* in GICR_TYPER: this one is four frames long, not two */
#define GICR_SLEEP    (1u << 1)    /* in GICR_WAKER: the processor is said to be asleep */
#define GICR_ASLEEP   (1u << 2)    /* in GICR_WAKER: and the redistributor has gone quiet */
#define GICR_FRAME    0x10000

#define PRIORITY_ANY  0xff
#define PRIORITY_OURS 0x80
#define NO_INTERRUPT  1020         /* acknowledging yields this or more when nothing is pending */

static int g_version;              /* 2 or 3 once the GIC is set up */
static volatile uint32_t *g_dist;
static volatile uint32_t *g_cpu;    /* version 2 */
static volatile uint32_t *g_redist; /* version 3: this processor's */

static uint32_t g_timer_irq;
static uint64_t g_tick;            /* the length of a tick, in counts of the timer */

/* This processor's affinity, the four numbers that name it, as the MADT
 * spells them: bits 0 to 23 and 32 to 39 of MPIDR_EL1. */
static uint64_t affinity(void)
{
    return read_sysreg(mpidr_el1) & 0xff00ffffffULL;
}

/* Walk a range of redistributors for the one that belongs to this processor. */
static volatile uint32_t *find_redistributor(uint64_t base, uint64_t length)
{
    uint64_t self = affinity(), wanted = (self >> 32) << 24 | (self & 0xffffff);

    vm_map(base, base, length >> PAGE_SHIFT, VM_WRITE | VM_DEVICE);
    for (uint64_t at = base; at + 2 * GICR_FRAME <= base + length;) {
        volatile uint32_t *rd = phys_ptr(at);
        uint32_t type = rd[GICR_TYPER / 4];

        if (rd[GICR_TYPER / 4 + 1] == wanted)
            return rd;
        if (type & GICR_LAST)
            break;
        at += (type & GICR_VLPIS ? 4 : 2) * GICR_FRAME;
    }
    return NULL;
}

static void gic_init(void)
{
    const struct acpi_madt_gicd *gicd = NULL;
    const struct acpi_madt_gicc *gicc = NULL;
    int version;

    for (const struct acpi_madt_entry *e = acpi_madt_next(NULL); e; e = acpi_madt_next(e)) {
        if (e->type == ACPI_MADT_GICD)
            gicd = (const void *)e;
        else if (e->type == ACPI_MADT_GICC && ((const struct acpi_madt_gicc *)e)->mpidr == affinity())
            gicc = (const void *)e;
    }
    if (!gicd || !gicc)
        panic("the MADT does not describe a GIC with an entry for this processor");
    /* A MADT that leaves the version open leaves it to the processor,
     * which knows whether it has the system registers of version 3. */
    version = gicd->version ? gicd->version : read_sysreg(id_aa64pfr0_el1) >> 24 & 0xf ? 3 : 2;
    if (version > 3)
        version = 3; /* version 4 adds what a hypervisor needs and changes nothing here */

    vm_map(gicd->base, gicd->base, GICR_FRAME >> PAGE_SHIFT, VM_WRITE | VM_DEVICE);
    g_dist = phys_ptr(gicd->base);

    if (version == 2) {
        vm_map(gicc->base, gicc->base, 2, VM_WRITE | VM_DEVICE);
        g_cpu = phys_ptr(gicc->base);
        g_dist[GICD_CTLR / 4] = GICD_ON_V2;
        g_cpu[GICC_PRIORITY / 4] = PRIORITY_ANY;
        g_cpu[GICC_CTLR / 4] = 1;
        kprintf("interrupts: GIC version 2, distributor at %p, CPU interface at %p\n", (void *)g_dist,
                (void *)g_cpu);
    } else {
        for (const struct acpi_madt_entry *e = acpi_madt_next(NULL); e && !g_redist; e = acpi_madt_next(e))
            if (e->type == ACPI_MADT_GICR)
                g_redist = find_redistributor(((const struct acpi_madt_gicr *)e)->base,
                                              ((const struct acpi_madt_gicr *)e)->length);
        if (!g_redist && gicc->redistributor)
            g_redist = find_redistributor(gicc->redistributor, 2 * GICR_FRAME);
        if (!g_redist)
            panic("no GIC redistributor for processor %llx", affinity());

        g_dist[GICD_CTLR / 4] = GICD_ON_V3;
        while (g_dist[GICD_CTLR / 4] & GICD_BUSY)
            ;
        g_redist[GICR_WAKER / 4] &= ~GICR_SLEEP;
        while (g_redist[GICR_WAKER / 4] & GICR_ASLEEP)
            ;
        write_sysreg(ICC_SRE_EL1, read_sysreg(ICC_SRE_EL1) | 1); /* the system registers, not memory */
        isb();
        if (!(read_sysreg(ICC_SRE_EL1) & 1))
            panic("the GIC's CPU interface cannot be reached through system registers");
        write_sysreg(ICC_PMR_EL1, PRIORITY_ANY);
        write_sysreg(ICC_IGRPEN1_EL1, 1);
        isb();
        kprintf("interrupts: GIC version 3, distributor at %p, redistributor at %p\n", (void *)g_dist,
                (void *)g_redist);
    }
    g_version = version;
}

/* Switch one interrupt on. The switches of the 32 private interrupts are
 * in the redistributor on version 3; all others are in the distributor. */
static void gic_enable(uint32_t id)
{
    volatile uint32_t *regs = g_version == 3 && id < 32 ? g_redist + GICR_FRAME / 4 : g_dist;

    ((volatile uint8_t *)regs)[GIC_PRIORITY + id] = PRIORITY_OURS;
    if (g_version == 3)
        regs[GIC_GROUP / 4 + id / 32] |= 1u << (id % 32);
    regs[GIC_ENABLE / 4 + id / 32] = 1u << (id % 32);
}

/* The virtual timer: a counter that runs at CNTFRQ_EL0 counts a second and
 * an interrupt when it passes the value in CNTV_CVAL_EL0. Of the generic
 * timers it is the one a virtual machine can always use. */
static void timer_init(void)
{
    const struct acpi_gtdt *gtdt = acpi_table("GTDT");
    uint64_t hz = read_sysreg(cntfrq_el0);

    if (!gtdt || !hz)
        panic("no generic timer: %s", gtdt ? "the firmware set no frequency" : "ACPI has no GTDT");
    g_timer_irq = gtdt->virtual_interrupt;
    g_tick = hz / TIMER_HZ;
    gic_enable(g_timer_irq);
    write_sysreg(cntv_cval_el0, read_sysreg(cntvct_el0) + g_tick);
    write_sysreg(cntv_ctl_el0, 1); /* on, and not masked */
    kprintf("timer: generic timer at %llu.%llu MHz, interrupt %u, a tick every %u ms\n", hz / 1000000,
            hz / 100000 % 10, g_timer_irq, 1000 / TIMER_HZ);
}

void arch_interrupts_init(void)
{
    gic_init();
    timer_init();
}

/* An IRQ, from exception_dispatch. The timer's interrupt stays raised until
 * the moment it waits for lies in the future again, so that is moved first.
 * It moves by whole ticks, to keep time, unless the kernel has fallen more
 * than a tick behind: then the ticks that were missed are dropped. */
void interrupt_handle(void)
{
    uint32_t ack = g_version == 3 ? (uint32_t)read_sysreg(ICC_IAR1_EL1) : g_cpu[GICC_ACK / 4];
    uint32_t id = ack & (g_version == 3 ? 0xffffff : 0x3ff); /* version 2 adds the sender of a software interrupt above */

    if (id >= NO_INTERRUPT)
        return;
    if (id == g_timer_irq) {
        uint64_t now = read_sysreg(cntvct_el0), next = read_sysreg(cntv_cval_el0) + g_tick;

        write_sysreg(cntv_cval_el0, (int64_t)(next - now) > 0 ? next : now + g_tick);
        timer_tick();
    } else
        kprintf("interrupt %u, which nothing asked for\n", id);
    if (g_version == 3)
        write_sysreg(ICC_EOIR1_EL1, ack);
    else
        g_cpu[GICC_END / 4] = ack;
}

/* Stop the timer and close the door on every interrupt. A processor that
 * waits for an interrupt wakes for one that is pending even when it will
 * not take it, so a machine that is to sleep for good needs this. */
void interrupt_quiet(void)
{
    write_sysreg(cntv_ctl_el0, 0);
    if (g_version == 3)
        write_sysreg(ICC_PMR_EL1, 0);
    else if (g_version == 2)
        g_cpu[GICC_PRIORITY / 4] = 0;
}

void arch_interrupts_on(void)
{
    __asm__ volatile("msr daifclr, #2");
}

void arch_interrupts_off(void)
{
    __asm__ volatile("msr daifset, #2");
}

void arch_wait(void)
{
    __asm__ volatile("wfi");
}
