/* x86_64 interrupts: the controllers the ACPI MADT lists, and the timer.
 *
 * A PC carries three generations of interrupt controller, and the firmware
 * leaves each one in whatever state it had a use for:
 *
 *   two 8259s    the PC/AT's own. Masked for good, after being moved off
 *                the vectors they use out of the box, which are the ones
 *                the processor uses for its exceptions.
 *   I/O APICs    route the interrupt lines of devices to processors. Every
 *                pin is masked until a driver asks for one (M8).
 *   local APIC   part of the processor (Intel SDM volume 3, chapter 11).
 *                Interrupts reach the processor through it, and it has a
 *                timer, which gives the kernel its tick. */
#include "acpi.h"
#include "arch.h"

/* Local APIC registers: offsets into its page, each 32 bits wide. */
#define LAPIC_TASK_PRIORITY 0x080 /* interrupts of this priority class and below wait */
#define LAPIC_EOI           0x0b0 /* written at the end of every handler */
#define LAPIC_SPURIOUS      0x0f0 /* the spurious vector, and the switch for the whole APIC */
#define LAPIC_LVT_TIMER     0x320 /* what the timer does when it reaches zero */
#define LAPIC_LVT_LINT0     0x350 /* the pin the 8259s are wired to */
#define LAPIC_TIMER_INITIAL 0x380 /* writing it starts the countdown */
#define LAPIC_TIMER_CURRENT 0x390
#define LAPIC_TIMER_DIVIDE  0x3e0

#define LAPIC_ON        0x100    /* in LAPIC_SPURIOUS */
#define MASKED          0x10000  /* in an LVT register, and in an I/O APIC pin's */
#define TIMER_PERIODIC  0x20000  /* in LAPIC_LVT_TIMER: start again at zero */
#define TIMER_DIVIDE_16 0x3

#define MSR_APIC_BASE    0x1b
#define APIC_BASE_ON     (1u << 11)
#define APIC_BASE_X2APIC (1u << 10)

/* An I/O APIC shows its registers one at a time, through a window. */
#define IOAPIC_SELECT  0x00
#define IOAPIC_WINDOW  0x10
#define IOAPIC_VERSION 1                /* bits 16 to 23: the number of its last pin */
#define IOAPIC_PIN(n)  (0x10 + 2 * (n)) /* two registers a pin */

static volatile uint32_t *g_lapic;

static uint32_t lapic_read(unsigned reg)
{
    return g_lapic[reg / 4];
}

static void lapic_write(unsigned reg, uint32_t v)
{
    g_lapic[reg / 4] = v;
}

/* Initialise both 8259s, which is the only way to tell them their vectors:
 * 32 to 47 instead of 8 to 15 and 112 to 119. Then mask all sixteen lines. */
static void pic_mask_all(void)
{
    outb(0x20, 0x11); /* to each: initialisation starts, three more bytes follow */
    outb(0xa0, 0x11);
    outb(0x21, 32);   /* its first vector */
    outb(0xa1, 40);
    outb(0x21, 0x04); /* how the two are wired: the second hangs off line 2 of the first */
    outb(0xa1, 0x02);
    outb(0x21, 0x01); /* 8086 mode */
    outb(0xa1, 0x01);
    outb(0x21, 0xff); /* the mask */
    outb(0xa1, 0xff);
}

/* Mask every pin of one I/O APIC and say how many there were. */
static unsigned io_apic_mask_all(uint64_t address)
{
    volatile uint32_t *regs = phys_ptr(address);

    vm_map(address, address, 1, VM_WRITE | VM_DEVICE);
    regs[IOAPIC_SELECT / 4] = IOAPIC_VERSION;
    unsigned pins = ((regs[IOAPIC_WINDOW / 4] >> 16) & 0xff) + 1;
    for (unsigned pin = 0; pin < pins; pin++) {
        regs[IOAPIC_SELECT / 4] = IOAPIC_PIN(pin);
        regs[IOAPIC_WINDOW / 4] = MASKED;
        regs[IOAPIC_SELECT / 4] = IOAPIC_PIN(pin) + 1;
        regs[IOAPIC_WINDOW / 4] = 0;
    }
    return pins;
}

/* The local APIC's timer counts down at a rate that no table states, so it
 * is measured against the one clock that runs at the same rate in every
 * PC: the 8254 interval timer, at 1193182 Hz. Its channel 2 needs no
 * interrupt: port 0x61 starts it, and bit 5 of the same port goes up when
 * it has counted down. Returns how far the APIC's timer gets in one tick. */
static uint32_t timer_calibrate(void)
{
    enum { PIT_HZ = 1193182, TICK = PIT_HZ / TIMER_HZ };
    _Static_assert(TICK <= 0xffff, "the 8254 counts 16 bits: a tick of TIMER_HZ must fit");

    outb(0x61, (inb(0x61) & ~0x02) | 0x01); /* channel 2 may count, the speaker stays quiet */
    outb(0x43, 0xb0);                       /* channel 2, two bytes follow, count down once */
    outb(0x42, TICK & 0xff);
    outb(0x42, TICK >> 8);
    lapic_write(LAPIC_TIMER_DIVIDE, TIMER_DIVIDE_16);
    lapic_write(LAPIC_TIMER_INITIAL, 0xffffffff);
    for (uint32_t polls = 0; !(inb(0x61) & 0x20); polls++)
        if (polls == 10000000)
            panic("the 8254 never finished counting: nothing to measure the local APIC's timer against");
    uint32_t counted = 0xffffffff - lapic_read(LAPIC_TIMER_CURRENT);
    lapic_write(LAPIC_TIMER_INITIAL, 0);
    return counted;
}

void arch_interrupts_init(void)
{
    const struct acpi_madt *madt = acpi_madt();
    uint64_t base = madt->local_apic_address, msr = rdmsr(MSR_APIC_BASE);
    unsigned pins = 0;

    for (const struct acpi_madt_entry *e = acpi_madt_next(NULL); e; e = acpi_madt_next(e)) {
        if (e->type == ACPI_MADT_LOCAL_APIC_ADDRESS)
            base = ((const struct acpi_madt_local_apic_address *)e)->address;
        else if (e->type == ACPI_MADT_IO_APIC)
            pins += io_apic_mask_all(((const struct acpi_madt_io_apic *)e)->address);
    }
    if (madt->flags & ACPI_MADT_PCAT_COMPAT)
        pic_mask_all();

    if (base != (msr & 0x000ffffffffff000ULL))
        panic("ACPI puts the local APIC at %llx, the processor at %llx", base, msr & 0x000ffffffffff000ULL);
    if (msr & APIC_BASE_X2APIC)
        panic("the firmware left the local APIC in x2APIC mode, which this kernel cannot drive yet");
    if (!(msr & APIC_BASE_ON))
        wrmsr(MSR_APIC_BASE, msr | APIC_BASE_ON);
    vm_map(base, base, 1, VM_WRITE | VM_DEVICE);
    g_lapic = phys_ptr(base);

    /* The pin called LINT0 carries the 8259s' interrupts, which are no
     * longer wanted. LINT1 is the NMI line by convention, and stays as the
     * firmware set it. */
    lapic_write(LAPIC_LVT_LINT0, MASKED);
    lapic_write(LAPIC_LVT_TIMER, MASKED);
    lapic_write(LAPIC_TASK_PRIORITY, 0);
    lapic_write(LAPIC_SPURIOUS, LAPIC_ON | VECTOR_SPURIOUS);
    kprintf("interrupts: local APIC at %p, %u I/O APIC pins masked, 8259s %s\n", (void *)g_lapic, pins,
            madt->flags & ACPI_MADT_PCAT_COMPAT ? "masked" : "absent");

    uint32_t tick = timer_calibrate();
    if (tick < 1000)
        panic("the local APIC's timer counted %u in a tick: too slow to keep time with", tick);
    lapic_write(LAPIC_LVT_TIMER, VECTOR_TIMER | TIMER_PERIODIC);
    lapic_write(LAPIC_TIMER_DIVIDE, TIMER_DIVIDE_16);
    lapic_write(LAPIC_TIMER_INITIAL, tick);
    kprintf("timer: local APIC timer at %llu MHz by the 8254's clock, a tick every %u ms\n",
            (uint64_t)tick * 16 * TIMER_HZ / 1000000, 1000 / TIMER_HZ);
}

/* Vectors 32 and up, from interrupt_dispatch. Every interrupt the local
 * APIC delivers has to be signed off, or it delivers no more of that
 * priority; the spurious vector is the exception, being no delivery. */
void interrupt_handle(unsigned vector)
{
    if (vector == VECTOR_SPURIOUS)
        return;
    if (vector == VECTOR_TIMER)
        timer_tick();
    else
        kprintf("interrupt on vector %u, which nothing asked for\n", vector);
    if (g_lapic)
        lapic_write(LAPIC_EOI, 0);
}

void arch_interrupts_on(void)
{
    __asm__ volatile("sti");
}

void arch_interrupts_off(void)
{
    __asm__ volatile("cli");
}

void arch_wait(void)
{
    __asm__ volatile("hlt");
}
