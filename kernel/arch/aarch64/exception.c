/* AArch64 exceptions (Arm ARM, chapter D1): the kernel's vector table at
 * EL1, the stack its handlers run on, and the report the kernel makes of an
 * exception it cannot survive. The entry code is in entry.S. */
#include "arch.h"

#define EC_SVC 0x15 /* the exception class of svc, which arch_yield raises */

/* The processor state a thread starts with, as SPSR_EL1 spells it: EL1 on
 * SP_EL0, IRQs let in, and debug exceptions, SError and FIQ masked, which
 * is how the kernel has run since arch_early_init. */
#define PSTATE_THREAD 0x344

__attribute__((aligned(16))) static uint8_t exception_stack[16 * 1024];

void arch_exceptions_init(void)
{
    uint64_t el = read_sysreg(CurrentEL) >> 2 & 3;

    if (el != 1)
        panic("the firmware started ClaraOS at EL%llu, and it only knows how to run at EL1", el);
    /* arch_switch_stack put the kernel on SP_EL0. Exceptions arrive on
     * SP_EL1, which still points into the firmware's memory: select it
     * for a moment to point it at a stack of the kernel's. */
    __asm__ volatile("msr spsel, #1\n"
                     "mov sp, %0\n"
                     "msr spsel, #0"
                     :
                     : "r"(exception_stack + sizeof exception_stack));
    write_sysreg(vbar_el1, exception_vectors);
    isb();
    kprintf("exceptions: a vector table of our own at EL1, its handlers on a stack of their own\n");
}

/* The exception class, bits 26 to 31 of ESR_EL1 (Arm ARM, D24.2.40). */
static const char *class_name(unsigned ec)
{
    switch (ec) {
    case 0x00: return "an instruction the processor does not know";
    case 0x0e: return "illegal execution state";
    case EC_SVC: return "supervisor call, which is how a thread waits";
    case 0x18: return "a system register that is out of bounds here";
    case 0x20: /* the same from EL0 */
    case 0x21: return "instruction abort";
    case 0x22: return "misaligned program counter";
    case 0x24:
    case 0x25: return "data abort";
    case 0x26: return "misaligned stack pointer";
    case 0x2f: return "SError";
    case 0x3c: return "breakpoint instruction";
    default:   return "an exception of a class the kernel has no name for";
    }
}

/* Was this exception a memory access that the page tables refused? Aborts
 * are, and the low six bits of the syndrome say why: 4 to 7 nothing mapped
 * at one level of the tables or another, 12 to 15 mapped and not allowed. */
static int memory_fault(uint64_t esr, uint64_t far, struct mem_fault *mf)
{
    unsigned ec = esr >> 26 & 0x3f, status = esr & 0x3f;
    int instruction = ec == 0x20 || ec == 0x21, data = ec == 0x24 || ec == 0x25;

    if (!instruction && !data)
        return 0;
    mf->addr = far;
    mf->access = instruction ? MEM_EXEC : esr & (1 << 6) ? MEM_WRITE : MEM_READ;
    mf->mapped = status >> 2 == 3;
    return 1;
}

/* Say everything there is to say, and stop. */
static void report(const struct frame *f, uint64_t esr, uint64_t far, const struct mem_fault *mf)
{
    static const char *const kinds[4] = { "", "IRQ", "FIQ", "SError" };
    static int reporting;
    unsigned from = f->vector >> 2, kind = f->vector & 3;
    /* A handler was running on the stack this frame is on. */
    uint64_t sp = from == 1 ? (uint64_t)(uintptr_t)f + FRAME_SIZE : f->sp;

    if (reporting++) {
        /* The first report did not get through, and the screen may be why. */
        console_serial_only();
        kputs("\nthe report was cut short by another exception:");
    }
    fbcon_set_color(FBCON_ALERT);
    kprintf("\nexception%s: %s",
            from == 0 ? "" : from == 1 ? " inside an exception handler" : " from EL0, where nothing runs",
            kind ? kinds[kind] : class_name(esr >> 26 & 0x3f));
    if (mf) {
        kputs(", ");
        fault_describe(mf);
    } else
        kputc('\n');
    kprintf("  at %p", (void *)(uintptr_t)f->pc);
    if (vm_image_offset(f->pc))
        kprintf(", kernel image +0x%llx", vm_image_offset(f->pc));
    kprintf(", in thread %s", thread_name());
    for (unsigned i = 0; i < 31; i++) /* four to a line, and sp completes the last */
        kprintf("%sx%u%s %016llx", i % 4 ? "  " : "\n  ", i, i < 10 ? " " : "", f->x[i]);
    kprintf("  sp  %016llx\n", sp);
    kprintf("  pc  %016llx  pstate %08llx  syndrome %08llx", f->pc, f->pstate, esr);
    if (mf) /* the register keeps its old value through any other exception */
        kprintf("  fault address %016llx", far);
    kputc('\n');
    arch_halt();
}

/* Called by entry.S for every entry of the vector table, with the
 * interrupted code's registers in the frame. What is changed there is what
 * the code resumes with, and thread_switch changes all of it when another
 * thread is to run. */
void exception_dispatch(struct frame *f)
{
    unsigned from = f->vector >> 2, kind = f->vector & 3;
    struct mem_fault mf;

    if (from == 0 && kind == 1) {
        interrupt_handle();
        /* It may have woken a thread, or ended the turn of the one it interrupted. */
        thread_switch(f);
        return;
    }
    uint64_t esr = read_sysreg(esr_el1), far = read_sysreg(far_el1);
    /* A thread that gives the processor up. A handler that tried would
     * arrive from SP_EL1, and is reported below like any other fault. */
    if (from == 0 && kind == 0 && (esr >> 26 & 0x3f) == EC_SVC) {
        thread_switch(f);
        return;
    }
    int memory = kind == 0 && memory_fault(esr, far, &mf);
    if (from == 0 && kind == 0 && fault_probing(memory ? &mf : NULL)) {
        /* Make the probe return 1 (entry.S). */
        f->pc = (uint64_t)(uintptr_t)probe_failed;
        f->sp = probe_return[0];
        f->x[30] = probe_return[1];
        return;
    }
    report(f, esr, far, memory ? &mf : NULL);
}

/* What a thread switch is made of (kernel/thread.c). */
const size_t arch_frame_size = sizeof(struct frame);

/* The frame pointer and the link register are zero: there is no frame
 * above start and nowhere for it to return to. */
void arch_frame_init(struct frame *f, void *stack_top, void (*start)(void))
{
    memset(f, 0, sizeof *f);
    f->pc = (uint64_t)(uintptr_t)start;
    f->sp = (uint64_t)(uintptr_t)stack_top;
    f->pstate = PSTATE_THREAD;
}

/* A supervisor call is taken whether or not interrupts are on, and returns
 * to the next instruction when this thread's turn comes again, with the
 * processor state it left with. */
void arch_yield(void)
{
    __asm__ volatile("svc #0" ::: "memory");
}
