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
 * one it is, then handled, then ended. The generic timer's (Arm ARM,
 * chapter D12) is private to each processor.
 *
 * A device's interrupt is a message: the device writes a number to an
 * address. Which line a device is wired to is written in the DSDT, in a
 * bytecode that the kernel does not read, and a message needs no line.
 * What takes the message is one of two things, and the MADT says which
 * the machine has:
 *
 *   a GICv2m frame   a register next to the GIC. The number written is
 *                    that of a shared interrupt, out of a range that is
 *                    kept for the purpose, and the interrupt is raised as
 *                    if a line had been. Version 2 has it, and so has
 *                    version 3 under Apple's hypervisor.
 *   an ITS           the interrupt translation service of version 3. The
 *                    number written is an event of the device that writes,
 *                    and tables in memory, which the kernel fills in with
 *                    commands, say which interrupt that is: one of a kind
 *                    that exists for messages only, the LPIs, numbered
 *                    from 8192. Version 3 has it when it is emulated. */
#include "acpi.h"
#include "arch.h"

/* Registers of the distributor. A redistributor has the same ones, at the
 * same offsets, in its second 64 KiB, for its 32 private interrupts. */
#define GICD_CTLR     0x000
#define GICD_TYPER    0x004
#define GIC_GROUP     0x080 /* one bit an interrupt: group 1 arrives as an IRQ */
#define GIC_ENABLE    0x100 /* one bit an interrupt: writing a 1 switches it on */
#define GIC_PRIORITY  0x400 /* one byte an interrupt: lower is more urgent */
#define GICD_TARGETS  0x800 /* version 2, one byte an interrupt: a bit for each processor it may go to */
#define GIC_CONFIG    0xc00 /* two bits an interrupt: the upper one says that it is raised by an edge */
#define GICD_ROUTER   0x6000 /* version 3, 64 bits an interrupt: the affinity of the processor it goes to */

#define GICD_ON_V2    0x1
#define GICD_ON_V3    0x13         /* group 1 on, in both places the bit can be, and affinity routing */
#define GICD_BUSY     (1u << 31)   /* a write to GICD_CTLR is still taking effect */
#define GICD_LPIS     (1u << 17)   /* in GICD_TYPER: the GIC has LPIs */

/* Version 2: the CPU interface. */
#define GICC_CTLR     0x00
#define GICC_PRIORITY 0x04         /* only interrupts more urgent than this get through */
#define GICC_ACK      0x0c
#define GICC_END      0x10

/* Version 3: the first 64 KiB of a redistributor. */
#define GICR_CTLR     0x00
#define GICR_TYPER    0x08         /* 64 bits: whose it is, in the upper half */
#define GICR_WAKER    0x14
#define GICR_PROPBASER 0x70        /* 64 bits: where the table of the LPIs' priorities and switches is */
#define GICR_PENDBASER 0x78        /* 64 bits: and the table of the ones that are pending */
#define GICR_LPIS_ON  (1u << 0)    /* in GICR_CTLR */
#define GICR_PLPIS    (1u << 0)    /* in GICR_TYPER: this redistributor has LPIs */
#define GICR_LAST     (1u << 4)    /* in GICR_TYPER: no redistributor follows this one */
#define GICR_VLPIS    (1u << 1)    /* in GICR_TYPER: this one is four frames long, not two */
#define GICR_SLEEP    (1u << 1)    /* in GICR_WAKER: the processor is said to be asleep */
#define GICR_ASLEEP   (1u << 2)    /* in GICR_WAKER: and the redistributor has gone quiet */
#define GICR_FRAME    0x10000

#define PRIORITY_ANY  0xff
#define PRIORITY_OURS 0x80
#define NO_INTERRUPT  1020         /* acknowledging yields this, or a few more, when nothing is pending */
#define LPI_FIRST     8192         /* the numbers from here on are LPIs */

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

/* A register of 64 bits among the 32-bit ones. */
static uint64_t read64(volatile uint32_t *regs, unsigned reg)
{
    return *(volatile uint64_t *)((uintptr_t)regs + reg);
}

static void write64(volatile uint32_t *regs, unsigned reg, uint64_t v)
{
    *(volatile uint64_t *)((uintptr_t)regs + reg) = v;
}

/* Messages, the first way: a GICv2m frame (Arm DEN 0029, the Server Base
 * System Architecture, appendix E). The frame owns a range of shared
 * interrupts, and a device raises one by writing its number to the
 * frame. */
#define V2M_TYPER  0x008 /* bits 16 to 25: the first interrupt of the range; bits 0 to 9: how many there are */
#define V2M_SETSPI 0x040 /* where a device writes */

static uint64_t g_frame; /* the address of the frame, or 0 */
static uint32_t g_frame_first, g_frame_count;

const char *arch_message_controller; /* stays NULL when the machine has neither */

static void frame_init(const struct acpi_madt_gic_msi_frame *f)
{
    volatile uint32_t *regs = phys_ptr(f->base);
    uint32_t type, first, count;

    vm_map(f->base, f->base, 1, VM_WRITE | VM_DEVICE);
    type = regs[V2M_TYPER / 4];
    first = f->flags & 1 ? f->spi_base : type >> 16 & 0x3ff;
    count = f->flags & 1 ? f->spi_count : type & 0x3ff;
    if (first < 32 || !count || first + count > NO_INTERRUPT) {
        kprintf("interrupts: the GICv2m frame at %p claims interrupts %u to %u, which are not shared\n", (void *)regs,
                first, first + count - 1);
        return;
    }
    g_frame = f->base;
    g_frame_first = first;
    g_frame_count = count;
    arch_message_controller = "a GICv2m frame";
    kprintf("interrupts: devices send messages to the GICv2m frame at %p, interrupts %u to %u\n", (void *)regs, first,
            first + count - 1);
}

/* A shared interrupt that a write to the frame raises: by an edge, there
 * being no line that could stay raised, and for this processor. */
static void gic_enable_message(uint32_t id)
{
    volatile uint8_t *bytes = (volatile uint8_t *)g_dist;

    g_dist[GIC_CONFIG / 4 + id / 16] |= 2u << (id % 16 * 2);
    if (g_version == 3)
        write64(g_dist, GICD_ROUTER + 8 * id, affinity());
    else
        bytes[GICD_TARGETS + id] = bytes[GICD_TARGETS]; /* for a private interrupt this reads as the processor that asks */
    gic_enable(id);
}

/* Messages, the second way: the interrupt translation service (IHI 0069,
 * chapters 5 and 6, and 12.19 for its registers). A device writes the
 * number of one of its events to the ITS, which knows who is writing, and
 * looks up what that is to be: an LPI, an interrupt of a kind that has no
 * line and no state but "pending", and which processor gets it. It looks
 * that up in tables that live in the kernel's memory: one of devices, one
 * of the events of each device, one of collections, which are the
 * processors. The kernel hands it the memory and fills the tables in by
 * putting commands in a queue. The LPIs have two tables of their own,
 * which belong to the redistributor: the priority and the switch of each,
 * and which are pending.
 *
 * Every one of those tables is a run of page frames at a multiple of
 * 64 KiB, the coarsest of the alignments the GIC asks for. */
#define GITS_CTLR       0x0000
#define GITS_TYPER      0x0008  /* 64 bits: what this ITS is like */
#define GITS_CBASER     0x0080  /* 64 bits: where the queue of commands is */
#define GITS_CWRITER    0x0088  /* 64 bits: how far the kernel has written it */
#define GITS_CREADR     0x0090  /* 64 bits: how far the ITS has read it */
#define GITS_BASER      0x0100  /* eight registers of 64 bits, one for each of its tables */
#define GITS_TRANSLATER 0x10040 /* where a device writes */

#define GITS_ON           (1u << 0)    /* in GITS_CTLR */
#define GITS_QUIET        (1u << 31)   /* in GITS_CTLR: switched off, and done with what it was doing */
#define GITS_PTA          (1ULL << 19) /* in GITS_TYPER: a command names a processor by the address of its redistributor */
#define TABLE_VALID       (1ULL << 63)
#define TABLE_KIND(baser) ((unsigned)((baser) >> 56) & 7)
#define TABLE_DEVICES     1
#define TABLE_COLLECTIONS 4
/* The tables are memory that is cached like any other, and the registers
 * that take their addresses are told so: the same thing in two layouts. */
#define ITS_CACHED    (7ULL << 59 | 1ULL << 10)
#define REDIST_CACHED (7ULL << 7 | 1ULL << 10)

#define ITS_ALIGN      0x10000ULL
#define ITS_EVENT_BITS 5  /* a device can have 32 events */
#define ITS_DEVICES    16 /* and this many devices can have any */

enum { ITS_SYNC = 0x05, ITS_MAPD = 0x08, ITS_MAPC = 0x09, ITS_MAPTI = 0x0a, ITS_INV = 0x0c };

static volatile uint32_t *g_its;      /* its registers, or NULL when there is none in use */
static uint64_t *g_its_queue;         /* one page of commands, four words each */
static uint64_t g_its_target;         /* this processor, as a command names it */
static uint64_t g_its_ids;            /* how many devices its table has room for, by their number */
static volatile uint8_t *g_lpi_config; /* a byte for each LPI */
static struct {
    uint32_t id;                      /* bus, device and function */
    uint32_t events;                  /* how many it has been given */
} g_its_devices[ITS_DEVICES];
static unsigned g_its_device_count;

/* Zeroed page frames for a table: their address, or 0. */
static uint64_t table_memory(uint64_t bytes)
{
    uint64_t pages = (bytes + PAGE_SIZE - 1) >> PAGE_SHIFT, table = pmm_alloc_aligned(pages, ITS_ALIGN);

    if (table)
        memset(phys_ptr(table), 0, pages << PAGE_SHIFT);
    return table;
}

/* One command goes into the queue, and the ITS is waited for. A command it
 * cannot make sense of stalls it, and then this says 0. */
static int its_command(uint64_t w0, uint64_t w1, uint64_t w2)
{
    uint64_t at = read64(g_its, GITS_CWRITER) & (PAGE_SIZE - 32), next = (at + 32) % PAGE_SIZE;
    uint64_t *command = (uint64_t *)((uintptr_t)g_its_queue + at);

    command[0] = w0;
    command[1] = w1;
    command[2] = w2;
    command[3] = 0;
    __asm__ volatile("dsb ishst" ::: "memory");
    write64(g_its, GITS_CWRITER, next);
    for (uint32_t spins = 0; (read64(g_its, GITS_CREADR) & (PAGE_SIZE - 32)) != next; spins++)
        if (spins == 1000000)
            return 0;
    return 1;
}

/* Set the ITS up for this processor. NULL when it is ready, or why it is
 * of no use, in words. */
static const char *its_init(uint64_t base)
{
    volatile uint32_t *its = phys_ptr(base);
    uint64_t type, config, pending, queue;

    if (!(g_dist[GICD_TYPER / 4] & GICD_LPIS) || !(g_redist[GICR_TYPER / 4] & GICR_PLPIS))
        return "this GIC has no LPIs";
    if (g_redist[GICR_CTLR / 4] & GICR_LPIS_ON)
        return "the firmware left the LPIs on, with its own tables";

    /* The LPIs first. Interrupt numbers of 14 bits are the fewest the GIC
     * lets one ask for: 8192 LPIs, of which INTERRUPT_SOURCES are used. A
     * byte each in one table, all zeroes, which is "switched off", and a
     * bit for each of the 16384 numbers in the other. */
    config = table_memory(LPI_FIRST);
    pending = table_memory(2 * LPI_FIRST / 8);
    if (!config || !pending)
        return "there is no memory for the tables of the LPIs";
    write64(g_redist, GICR_PROPBASER, config | REDIST_CACHED | (14 - 1));
    write64(g_redist, GICR_PENDBASER, pending | REDIST_CACHED | 1ULL << 62); /* bit 62: the table is all zeroes */
    g_redist[GICR_CTLR / 4] |= GICR_LPIS_ON;

    vm_map(base, base, 2 * GICR_FRAME >> PAGE_SHIFT, VM_WRITE | VM_DEVICE);
    if (its[GITS_CTLR / 4] & GITS_ON) {
        its[GITS_CTLR / 4] &= ~GITS_ON;
        while (!(its[GITS_CTLR / 4] & GITS_QUIET))
            ;
    }
    type = read64(its, GITS_TYPER);
    for (unsigned n = 0; n < 8; n++) {
        uint64_t baser = read64(its, GITS_BASER + 8 * n), entry = (baser >> 48 & 0x1f) + 1, bytes, page, table;
        unsigned kind = TABLE_KIND(baser), bits = (unsigned)(type >> 13 & 0x1f) + 1;

        if (kind == TABLE_DEVICES)
            bytes = entry << (bits < 16 ? bits : 16); /* a place for every bus, device and function there can be */
        else if (kind == TABLE_COLLECTIONS)
            bytes = entry;                            /* and for one processor */
        else
            continue;
        bytes = (bytes + ITS_ALIGN - 1) & ~(ITS_ALIGN - 1);
        table = table_memory(bytes);
        if (!table)
            return "there is no memory for its tables";
        /* The ITS counts a table in pages, and how large a page is can be
         * the ITS's to say: 64 KiB is asked for, and what the register
         * holds afterwards is what it is. */
        write64(its, GITS_BASER + 8 * n, table | ITS_CACHED | 2ULL << 8 | (bytes / ITS_ALIGN - 1) | TABLE_VALID);
        baser = read64(its, GITS_BASER + 8 * n);
        page = (baser >> 8 & 3) == 0 ? 0x1000 : (baser >> 8 & 3) == 1 ? 0x4000 : ITS_ALIGN;
        if (page != ITS_ALIGN) {
            if (bytes / page > 256)
                bytes = 256 * page; /* a table has no more pages than that */
            write64(its, GITS_BASER + 8 * n,
                    table | ITS_CACHED | (baser & 3ULL << 8) | (bytes / page - 1) | TABLE_VALID);
        }
        if (kind == TABLE_DEVICES)
            g_its_ids = bytes / entry;
    }
    if (!g_its_ids)
        return "it has no table of devices";

    queue = table_memory(PAGE_SIZE);
    if (!queue)
        return "there is no memory for its queue of commands";
    write64(its, GITS_CBASER, queue | ITS_CACHED | TABLE_VALID); /* the lowest byte: one page of 4 KiB, less one */
    write64(its, GITS_CWRITER, 0);
    its[GITS_CTLR / 4] |= GITS_ON;

    g_its = its;
    g_its_queue = phys_ptr(queue);
    g_lpi_config = phys_ptr(config);
    g_its_target = type & GITS_PTA ? (uint64_t)(uintptr_t)g_redist
                                   : (uint64_t)(g_redist[GICR_TYPER / 4] >> 8 & 0xffff) << 16;
    /* Collection 0 is this processor, and every event is mapped to it. */
    if (!its_command(ITS_MAPC, 0, g_its_target | TABLE_VALID) || !its_command(ITS_SYNC, 0, g_its_target)) {
        g_its = NULL;
        return "it does not take its commands";
    }
    return NULL;
}

/* An event for a device, and the LPI that it is to be. A device that the
 * ITS has not heard of gets a table for its events first, one page, which
 * the ITS keeps. */
static int its_message(uint32_t device, unsigned source, struct interrupt_message *m)
{
    unsigned d = 0;
    uint32_t event;

    while (d < g_its_device_count && g_its_devices[d].id != device)
        d++;
    if (d == g_its_device_count) {
        uint64_t events;

        if (d == ITS_DEVICES || device >= g_its_ids || !(events = table_memory(PAGE_SIZE)) ||
            !its_command(ITS_MAPD | (uint64_t)device << 32, ITS_EVENT_BITS - 1, events | TABLE_VALID))
            return 0;
        g_its_devices[d].id = device;
        g_its_devices[d].events = 0;
        g_its_device_count++;
    }
    event = g_its_devices[d].events;
    if (event == 1u << ITS_EVENT_BITS)
        return 0;
    g_lpi_config[source] = PRIORITY_OURS | 3; /* bit 0 switches it on, and bit 1 is always set */
    if (!its_command(ITS_MAPTI | (uint64_t)device << 32, event | (uint64_t)(LPI_FIRST + source) << 32, 0) ||
        !its_command(ITS_INV | (uint64_t)device << 32, event, 0) || !its_command(ITS_SYNC, 0, g_its_target))
        return 0;
    g_its_devices[d].events = event + 1;
    m->address = (uint64_t)(uintptr_t)g_its + GITS_TRANSLATER;
    m->data = event;
    return 1;
}

int arch_message(uint32_t device, unsigned source, struct interrupt_message *m)
{
    if (g_its)
        return its_message(device, source, m);
    if (source >= g_frame_count)
        return 0;
    gic_enable_message(g_frame_first + source);
    m->address = g_frame + V2M_SETSPI;
    m->data = g_frame_first + source;
    return 1;
}

/* Which of the two the machine has. An ITS comes first: where there is
 * one, the firmware's tables send the devices there. */
static void messages_init(void)
{
    const struct acpi_madt_gic_msi_frame *frame = NULL;
    const struct acpi_madt_gic_its *its = NULL;

    for (const struct acpi_madt_entry *e = acpi_madt_next(NULL); e; e = acpi_madt_next(e)) {
        if (e->type == ACPI_MADT_GIC_ITS && !its)
            its = (const void *)e;
        else if (e->type == ACPI_MADT_GIC_MSI_FRAME && !frame)
            frame = (const void *)e;
    }
    if (its && g_version == 3) {
        const char *why = its_init(its->base);

        if (!why) {
            arch_message_controller = "an ITS";
            kprintf("interrupts: devices send messages to the ITS at %p, LPIs %u to %u\n", (void *)g_its, LPI_FIRST,
                    LPI_FIRST + INTERRUPT_SOURCES - 1);
            return;
        }
        kprintf("interrupts: the ITS at %p is of no use: %s\n", phys_ptr(its->base), why);
    }
    if (frame)
        frame_init(frame);
    if (!arch_message_controller)
        kprintf("interrupts: nothing here takes a message from a device, so no device can interrupt\n");
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
    messages_init();
}

/* An IRQ, from exception_dispatch. The timer's interrupt stays raised until
 * the moment it waits for lies in the future again, so that is moved first.
 * It moves by whole ticks, to keep time, unless the kernel has fallen more
 * than a tick behind: then the ticks that were missed are dropped. */
void interrupt_handle(void)
{
    uint32_t ack = g_version == 3 ? (uint32_t)read_sysreg(ICC_IAR1_EL1) : g_cpu[GICC_ACK / 4];
    uint32_t id = ack & (g_version == 3 ? 0xffffff : 0x3ff); /* version 2 adds the sender of a software interrupt above */

    if (id >= NO_INTERRUPT && id < LPI_FIRST)
        return;
    if (id == g_timer_irq) {
        uint64_t now = read_sysreg(cntvct_el0), next = read_sysreg(cntv_cval_el0) + g_tick;

        write_sysreg(cntv_cval_el0, (int64_t)(next - now) > 0 ? next : now + g_tick);
        timer_tick();
    } else if (id >= LPI_FIRST)
        interrupt_deliver(id - LPI_FIRST);
    else if (g_frame && id - g_frame_first < g_frame_count)
        interrupt_deliver(id - g_frame_first);
    else
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

int arch_interrupts_off(void)
{
    uint64_t daif = read_sysreg(daif);

    __asm__ volatile("msr daifset, #2");
    return !(daif & 0x80); /* the bit that masks IRQs */
}

void arch_wait(void)
{
    __asm__ volatile("wfi");
}
