/* x86_64 exceptions (Intel SDM volume 3, chapters 3, 6 and 7): the tables
 * the processor consults when something goes wrong or a device wants
 * attention, and the report the kernel makes of an exception it cannot
 * survive.
 *
 *   GDT  the segments. In 64-bit mode they say little more than "kernel
 *        code" and "kernel data", but the processor still wants them, and
 *        the firmware's are not the kernel's to keep.
 *   TSS  exists to name a spare stack. A fault while the stack pointer is
 *        bad cannot be reported on that stack; the processor then raises a
 *        double fault, and the double fault's gate asks for the spare one.
 *   IDT  one gate per vector, each pointing at its stub in entry.S. */
#include "arch.h"

#define SEL_CODE 0x08
#define SEL_DATA 0x10
#define SEL_TSS  0x18

#define DOUBLE_FAULT 8
#define PAGE_FAULT   14

/* Both segments are already marked "accessed", so the processor never has
 * to write that into the table. The TSS descriptor is two entries long and
 * is filled in at boot, when the address of the TSS is known. */
static uint64_t gdt[5] = {
    0,
    0x00209b0000000000ULL, /* SEL_CODE: present, ring 0, code, 64-bit */
    0x0000930000000000ULL, /* SEL_DATA: present, ring 0, data, writable */
};

static struct {
    uint32_t reserved0;
    uint64_t rsp[3];       /* stacks for a change of privilege: there is none */
    uint64_t reserved1;
    uint64_t ist[7];       /* stacks a gate can ask for by number, counted from 1 */
    uint64_t reserved2;
    uint16_t reserved3;
    uint16_t io_map;       /* offset of the I/O permission map: past the end means none */
} __attribute__((packed)) tss;

static struct gate {
    uint16_t offset_low, selector;
    uint8_t  ist, type;
    uint16_t offset_mid;
    uint32_t offset_high, reserved;
} idt[256];

#define GATE_INTERRUPT 0x8e /* present, ring 0, interrupts off on entry */

struct table_pointer {     /* what lgdt and lidt take */
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));

__attribute__((aligned(16))) static uint8_t double_fault_stack[16 * 1024];

void arch_exceptions_init(void)
{
    uint64_t base = (uint64_t)(uintptr_t)&tss;
    struct table_pointer gdtr = { sizeof gdt - 1, (uint64_t)(uintptr_t)gdt };
    struct table_pointer idtr = { sizeof idt - 1, (uint64_t)(uintptr_t)idt };

    tss.ist[0] = (uint64_t)(uintptr_t)(double_fault_stack + sizeof double_fault_stack);
    tss.io_map = sizeof tss;
    /* Type 9 is a TSS that no processor has loaded yet. */
    gdt[3] = (sizeof tss - 1) | (base & 0xffffff) << 16 | 0x89ULL << 40 | (base >> 24 & 0xff) << 56;
    gdt[4] = base >> 32;

    for (unsigned v = 0; v < 256; v++) {
        uint64_t stub = (uint64_t)(uintptr_t)interrupt_stubs[v];

        idt[v] = (struct gate){
            .offset_low = (uint16_t)stub,
            .selector = SEL_CODE,
            .ist = v == DOUBLE_FAULT ? 1 : 0,
            .type = GATE_INTERRUPT,
            .offset_mid = (uint16_t)(stub >> 16),
            .offset_high = (uint32_t)(stub >> 32),
        };
    }

    /* cs cannot be loaded with a mov: a far return, which pops it along
     * with the address to continue at, is the way. */
    __asm__ volatile("lgdt %[gdtr]\n"
                     "pushq %[code]\n"
                     "leaq 1f(%%rip), %%rax\n"
                     "pushq %%rax\n"
                     "lretq\n"
                     "1:\n"
                     "movl %[data], %%eax\n"
                     "movl %%eax, %%ss\n"
                     "movl %%eax, %%ds\n"
                     "movl %%eax, %%es\n"
                     "xorl %%eax, %%eax\n"
                     "movl %%eax, %%fs\n"
                     "movl %%eax, %%gs\n"
                     "movl %[tss], %%eax\n"
                     "ltr %%ax\n"
                     "lidt %[idtr]"
                     :
                     : [gdtr] "m"(gdtr), [idtr] "m"(idtr), [code] "i"(SEL_CODE), [data] "i"(SEL_DATA),
                       [tss] "i"(SEL_TSS)
                     : "rax", "cc", "memory");
    kprintf("exceptions: a GDT, an IDT and handlers of our own; a double fault gets its own stack\n");
}

static const char *const names[32] = {
    "divide error",        "debug",                 "non-maskable interrupt", "breakpoint",
    "overflow",            "bound range exceeded",  "invalid opcode",         "device not available",
    "double fault",        "reserved",              "invalid TSS",            "segment not present",
    "stack-segment fault", "general protection",    "page fault",             "reserved",
    "x87 floating point",  "alignment check",       "machine check",          "SIMD floating point",
    "virtualization",      "control protection",    "reserved",               "reserved",
    "reserved",            "reserved",              "reserved",               "reserved",
    "hypervisor injection", "VMM communication",    "security",               "reserved",
};

static uint64_t read_cr2(void)
{
    uint64_t v;
    __asm__("mov %%cr2, %0" : "=r"(v));
    return v;
}

/* Was this exception a memory access that the page tables refused? A page
 * fault says so itself, in its error code. A double fault says nothing,
 * but when the address of the last page fault is in the guard page under
 * the stack, the processor failed to push a frame there. */
static int memory_fault(const struct frame *f, struct mem_fault *mf)
{
    mf->addr = read_cr2();
    if (f->vector == PAGE_FAULT) {
        mf->access = f->error & 0x10 ? MEM_EXEC : f->error & 0x02 ? MEM_WRITE : MEM_READ;
        mf->mapped = f->error & 0x01;
        return 1;
    }
    if (f->vector == DOUBLE_FAULT && fault_in_stack_guard(mf->addr)) {
        mf->access = MEM_WRITE;
        mf->mapped = 0;
        return 1;
    }
    return 0;
}

/* Say everything there is to say, and stop. */
static void report(const struct frame *f, const struct mem_fault *mf)
{
    static int reporting;
    uint64_t cr0, cr3, cr4;

    if (reporting++) {
        /* The first report did not get through, and the screen may be why. */
        console_serial_only();
        kputs("\nthe report was cut short by another exception:");
    }
    __asm__("mov %%cr0, %0" : "=r"(cr0));
    __asm__("mov %%cr3, %0" : "=r"(cr3));
    __asm__("mov %%cr4, %0" : "=r"(cr4));

    fbcon_set_color(FBCON_ALERT);
    kprintf("\nexception %llu, %s", f->vector, names[f->vector]);
    if (mf) {
        kputs(": ");
        fault_describe(mf);
    } else
        kputc('\n');
    kprintf("  at %p", (void *)(uintptr_t)f->rip);
    if (vm_image_offset(f->rip))
        kprintf(", kernel image +0x%llx", vm_image_offset(f->rip));
    kprintf(", in thread %s", thread_name());
    kprintf("\n  rax %016llx  rbx %016llx  rcx %016llx  rdx %016llx\n", f->rax, f->rbx, f->rcx, f->rdx);
    kprintf("  rsi %016llx  rdi %016llx  rbp %016llx  rsp %016llx\n", f->rsi, f->rdi, f->rbp, f->rsp);
    kprintf("  r8  %016llx  r9  %016llx  r10 %016llx  r11 %016llx\n", f->r8, f->r9, f->r10, f->r11);
    kprintf("  r12 %016llx  r13 %016llx  r14 %016llx  r15 %016llx\n", f->r12, f->r13, f->r14, f->r15);
    kprintf("  rip %016llx  rflags %08llx  cs %04llx  ss %04llx  error code %04llx\n", f->rip, f->rflags,
            f->cs, f->ss, f->error);
    kprintf("  cr0 %016llx  cr2 %016llx  cr3 %016llx  cr4 %016llx\n", cr0, read_cr2(), cr3, cr4);
    arch_halt();
}

/* Called by entry.S for every vector, with the interrupted code's registers
 * in the frame. What is changed there is what the code resumes with, and
 * thread_switch changes all of it when another thread is to run. */
void interrupt_dispatch(struct frame *f)
{
    static int handling; /* an interrupt handler is running */
    struct mem_fault mf;

    if (f->vector == VECTOR_YIELD) {
        if (handling)
            panic("an interrupt handler tried to wait, which only a thread can do");
        thread_switch(f);
        return;
    }
    if (f->vector >= 32) {
        handling = 1;
        interrupt_handle((unsigned)f->vector);
        handling = 0;
        /* It may have woken a thread, or ended the turn of the one it interrupted. */
        thread_switch(f);
        return;
    }
    int memory = memory_fault(f, &mf);
    if (fault_probing(memory ? &mf : NULL)) {
        /* Make the probe return 1 (entry.S), and forget the address, so
         * that a later double fault is not taken for this one. */
        f->rip = (uint64_t)(uintptr_t)probe_failed;
        f->rsp = probe_sp;
        __asm__ volatile("mov %0, %%cr2" : : "r"((uint64_t)0));
        return;
    }
    report(f, memory ? &mf : NULL);
}

/* What a thread switch is made of (kernel/thread.c). */
const size_t arch_frame_size = sizeof(struct frame);

/* A function expects to have been called: its return address at the top
 * of the stack, 32 bytes of home space above that, and the stack pointer
 * 8 short of a multiple of 16. The address is zero, since start never
 * returns, and so is rbp, where the chain of frames ends. */
void arch_frame_init(struct frame *f, void *stack_top, void (*start)(void))
{
    uint64_t *sp = (uint64_t *)stack_top - 5;

    *sp = 0;
    memset(f, 0, sizeof *f);
    f->rip = (uint64_t)(uintptr_t)start;
    f->cs = SEL_CODE;
    f->rflags = 0x202; /* interrupts on; bit 1 is always set */
    f->rsp = (uint64_t)(uintptr_t)sp;
    f->ss = SEL_DATA;
}

/* A software interrupt arrives like any other, whether or not interrupts
 * are on, and returns to the next instruction when this thread's turn
 * comes again, with the flags it left with. */
void arch_yield(void)
{
    __asm__ volatile("int %0" : : "i"(VECTOR_YIELD) : "memory");
}
