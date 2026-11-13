/* Faults: memory accesses that the page tables refuse.
 *
 * The architecture's exception handler (kernel/arch/<arch>/exception.c)
 * works out what was refused and puts it in a struct mem_fault. From there
 * on the two architectures have everything in common, and it is here: the
 * words for a fault, and a self-test that provokes one fault of every kind
 * the address space of vm.c is supposed to produce.
 *
 * The self-test works through probes, small routines in entry.S that try
 * one access each. While a probe runs, a fault is not the end of the
 * machine: the handler notes what it saw and makes the probe return 1. */
#include "kernel.h"

static int g_probing;           /* a probe is running, and its fault is expected */
static int g_seen_memory;       /* the fault it caused was one the page tables can explain */
static struct mem_fault g_seen; /* and this is how the handler described it */

int fault_in_stack_guard(uint64_t addr)
{
    return addr - (uint64_t)(uintptr_t)kernel_stack < PAGE_SIZE;
}

/* For the handlers: is a probe waiting for this exception? mf is NULL when
 * the exception was not a refused access. */
int fault_probing(const struct mem_fault *mf)
{
    if (!g_probing)
        return 0;
    g_seen_memory = mf != NULL;
    if (mf)
        g_seen = *mf;
    return 1;
}

/* The end of a fault report's first line, and a line more when the address
 * gives the cause away. */
void fault_describe(const struct mem_fault *mf)
{
    static const char *const act[] = { "a read of", "a write to", "a jump to" };
    static const char *const refused[] = { "which may not be read", "which is read-only", "which is not code" };

    kprintf("%s 0x%llx, %s\n", act[mf->access], mf->addr,
            mf->mapped ? refused[mf->access] : "where nothing is mapped");
    if (fault_in_stack_guard(mf->addr))
        kputs("  that is the guard page under the kernel stack: the stack has overflowed\n");
    else if (mf->addr < LOW_LIMIT)
        kputs("  an address that low is a null pointer, most likely\n");
}

static int probe(enum mem_access access, uint64_t addr, uint8_t value)
{
    int faulted;

    g_seen_memory = 0;
    g_probing = 1;
    if (access == MEM_READ)
        faulted = arch_probe_read(addr);
    else if (access == MEM_WRITE)
        faulted = arch_probe_write(addr, value);
    else
        faulted = arch_probe_exec(addr);
    g_probing = 0;
    return faulted;
}

/* Every access below is one the address space must refuse, apart from the
 * first three, which show that a probe does not cry wolf. Each fault has
 * to come back as what it is: the address, the kind of access, and whether
 * anything is mapped there. */
void fault_selftest(void)
{
    static const uint8_t constant = 0x5a;
    static uint8_t data;
    uint64_t code = (uint64_t)(uintptr_t)arch_probe_nothing;
    uint64_t guard = (uint64_t)(uintptr_t)kernel_stack;
    uint64_t frame = pmm_alloc(1);
    const struct {
        const char *what;
        enum mem_access access;
        uint64_t addr;
        int faults, mapped;
    } cases[] = {
        { "a read of data", MEM_READ, (uint64_t)(uintptr_t)&data, 0, 1 },
        { "a write to data", MEM_WRITE, (uint64_t)(uintptr_t)&data, 0, 1 },
        { "a call of code", MEM_EXEC, code, 0, 1 },
        { "a read through a null pointer", MEM_READ, 0, 1, 0 },
        { "a write to code", MEM_WRITE, code, 1, 1 },
        { "a write to a constant", MEM_WRITE, (uint64_t)(uintptr_t)&constant, 1, 1 },
        { "a call of data", MEM_EXEC, (uint64_t)(uintptr_t)&data, 1, 1 },
        { "a call of a page frame", MEM_EXEC, frame, 1, 1 },
        { "a read of the empty heap", MEM_READ, VM_HEAP_BASE, 1, 0 },
        { "a call of the empty heap", MEM_EXEC, VM_HEAP_BASE, 1, 0 },
        { "a write to the stack's guard page", MEM_WRITE, guard + PAGE_SIZE - 8, 1, 0 },
    };
    unsigned survived = 0;

    if (!frame)
        panic("fault self-test: no free frame");
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        /* A write that goes through, wrongly or not, puts back the byte that was there. */
        uint8_t value = cases[i].mapped ? *(volatile uint8_t *)(uintptr_t)cases[i].addr : 0;
        int faulted = probe(cases[i].access, cases[i].addr, value);

        if (faulted != cases[i].faults)
            panic("fault self-test: %s %s", cases[i].what, faulted ? "faulted" : "went through");
        if (!faulted)
            continue;
        if (!g_seen_memory || g_seen.addr != cases[i].addr || g_seen.access != cases[i].access ||
            g_seen.mapped != cases[i].mapped)
            panic("fault self-test: %s came back as access %u at %llx, mapped %u", cases[i].what,
                  (unsigned)g_seen.access, g_seen.addr, (unsigned)g_seen.mapped);
        survived++;
    }
    pmm_free(frame, 1);

    /* The stack overflows: the stack pointer is at the guard page and the
     * next push lands in it. The handler cannot run on that stack, and
     * this passes only when it has another to run on. */
    g_seen_memory = 0;
    g_probing = 1;
    int faulted = arch_probe_push(guard + PAGE_SIZE);
    g_probing = 0;
    if (!faulted || !g_seen_memory || !fault_in_stack_guard(g_seen.addr))
        panic("fault self-test: a push into the stack's guard page %s",
              faulted ? "came back as something else" : "went through");
    survived++;

    kprintf("exceptions: self-test passed, %u faults provoked and survived\n", survived);
}
