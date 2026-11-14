/* Kernel-wide interfaces. Note: our targets are LLP64 (long is 32 bits), so
 * the kernel never uses long; it uses the <stdint.h> types. */
#pragma once
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#define CLARA_VERSION "0.0.7"

#define PAGE_SHIFT 12
#define PAGE_SIZE  (1ULL << PAGE_SHIFT)

/* Nothing below this address is handed out or mapped. Frame 0 would be
 * mistaken for a failed allocation and a null pointer has to fault; on x86
 * the first megabyte also holds the firmware's leftovers and, later, the
 * code that starts the other processors. */
#define LOW_LIMIT 0x100000ULL

/* RAM is mapped at its own address (vm.c), so a cast is all it takes to
 * reach a physical address. The cast lives here so that every place that
 * relies on that can be found. */
static inline void *phys_ptr(uint64_t pa)
{
    return (void *)(uintptr_t)pa;
}

struct framebuffer {
    volatile uint32_t *pixels; /* 32 bits per pixel; NULL when there is no display */
    uint32_t width, height;    /* in pixels */
    uint32_t pitch;            /* pixels per scanline, >= width */
    uint32_t red_mask, green_mask, blue_mask; /* the bits of a pixel that hold each colour */
};

/* A file the boot handoff read from the boot volume's \clara directory. */
struct boot_file {
    struct boot_file *next;
    const char *name;          /* as the volume spells it; a character outside ASCII becomes '?' */
    uint8_t    *data;
    uint64_t    size;          /* in bytes */
};

/* What the boot handoff learned from the firmware before taking the machine. */
struct boot_info {
    struct framebuffer fb;
    void    *memory_map;       /* EFI memory map; descriptors are desc_size bytes apart */
    uint64_t memory_map_size;
    uint64_t desc_size;
    void    *acpi_rsdp;        /* ACPI 2.0 root pointer, or NULL */
    void    *dtb;              /* flattened device tree, or NULL */
    struct boot_file *files;   /* in directory order, or NULL */
};

/* boot.c: the stack kmain starts on. It is part of the kernel image, and its
 * lowest page is a guard that vm_init unmaps. */
#define KERNEL_STACK_SIZE (64 * 1024)
extern uint8_t kernel_stack[PAGE_SIZE + KERNEL_STACK_SIZE];

/* console.c: text goes to the serial port and, after fbcon_init, to the
 * screen. %d %u %x %X %s %c %p and %% are supported, with zero padding and
 * width. The compiler checks the arguments: 64-bit ones are %llu, %llx. */
void kputc(char c);
void kputs(const char *s);
void kprintf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void kvprintf(const char *fmt, va_list ap) __attribute__((format(printf, 1, 0)));
void panic(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
void console_serial_only(void); /* leave the screen alone from now on */

/* fbcon.c: the text console on the framebuffer */
enum fbcon_color { FBCON_TEXT, FBCON_ACCENT, FBCON_ALERT, FBCON_COLORS };
void fbcon_init(const struct framebuffer *fb);
void fbcon_putc(char c);
void fbcon_set_color(enum fbcon_color color);

/* font.c, generated from fonts/spleen-8x16.bdf by tools/bdf2c.py */
#define FONT_WIDTH  8
#define FONT_HEIGHT 16
const uint8_t *font_glyph(char c); /* FONT_HEIGHT bytes, one per scanline, leftmost pixel in bit 7 */

/* pmm.c: the page frames of physical memory. Addresses here are physical,
 * which is why they are numbers and not pointers. */
void     pmm_init(const struct boot_info *bi);
uint64_t pmm_alloc(uint64_t pages);  /* adjacent frames, lowest first; 0 when no run is long enough */
void     pmm_free(uint64_t addr, uint64_t pages);
void     pmm_selftest(void);
void     pmm_reclaim(const struct boot_info *bi); /* boot-services memory, once the processor uses none of it */
uint64_t pmm_free_frames(void);      /* how many frames are free */

/* vm.c: the kernel's address space, in pages of PAGE_SIZE. RAM, the screen
 * and devices sit at their physical addresses. */
#define VM_WRITE  1u
#define VM_EXEC   2u
#define VM_DEVICE 4u /* device registers: not cached, not reordered */
#define VM_HEAP_BASE 0x0000400000000000ULL /* reserved for the Lisp heap: */
#define VM_HEAP_SIZE 0x0000400000000000ULL /* 64 TiB, starting at 64 TiB */
void     vm_init(const struct boot_info *bi);
void     vm_map(uint64_t va, uint64_t pa, uint64_t pages, unsigned flags); /* read-only data unless flags say more */
void     vm_unmap(uint64_t va, uint64_t pages);
uint64_t vm_lookup(uint64_t va); /* the physical page behind va, or 0 when nothing is mapped there */
void     vm_selftest(void);
uint64_t vm_image_offset(uint64_t addr); /* how far into the kernel image addr is, or 0 when it is outside */

/* fault.c: memory accesses that the page tables refuse */
enum mem_access { MEM_READ, MEM_WRITE, MEM_EXEC };
struct mem_fault {
    uint64_t addr;
    enum mem_access access;
    int mapped;                /* something is mapped at addr, and it does not allow the access */
};
int  fault_probing(const struct mem_fault *mf); /* for the handlers: was this exception provoked on purpose? */
void fault_describe(const struct mem_fault *mf);
int  fault_in_stack_guard(uint64_t addr); /* is it in the page under the running thread's stack? */
void fault_selftest(void);
void fault_stack_selftest(void); /* the running thread's stack overflows, and the handler has to say so */

/* timer.c */
#define TIMER_HZ 100
void     timer_tick(void);     /* called from the architecture's timer interrupt */
uint64_t timer_ticks(void);    /* since the timer was started */
void     timer_selftest(void);

/* thread.c: threads, taking turns on the processor, and locks between them */
#define THREAD_STACK_SIZE (64 * 1024) /* of every thread but the first, whose stack is kernel_stack */
struct thread;
struct frame;                  /* the registers of code that an exception cut short: arch/<arch>/arch.h */
struct thread_queue {
    struct thread *first, *last;
};
struct lock {
    struct thread *owner;        /* NULL when it is free */
    struct thread_queue waiting; /* in order of arrival */
};
void thread_init(void);
/* A thread that runs fn(arg). The name is kept, not copied. NULL when there is no memory for its stack. */
struct thread *thread_create(const char *name, void (*fn)(void *), void *arg);
void thread_join(struct thread *t);  /* wait until it has finished, and free it: once for every thread */
void thread_exit(void) __attribute__((noreturn)); /* what returning from fn does */
void thread_yield(void);             /* the other threads that are ready go first */
void thread_sleep(uint64_t ticks);   /* until the timer has ticked that many more times */
void thread_safe_point(void);        /* the thread waits here while the world is stopped */
void thread_stop_the_world(void);    /* returns when every other thread is asleep or at a safe point */
void thread_start_the_world(void);
void thread_tick(uint64_t now);      /* from timer_tick */
void thread_switch(struct frame *f); /* from the architecture's exception code, interrupts off */
uint64_t thread_stack_guard(void);   /* the unmapped page under the running thread's stack */
const char *thread_name(void);       /* the running thread's */
void thread_selftest(void);
void lock_acquire(struct lock *l);   /* waits its turn; never in an interrupt handler */
void lock_release(struct lock *l);

/* string.c */
void  *memset(void *dst, int c, size_t n);
void  *memcpy(void *dst, const void *src, size_t n);
int    memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);

/* arch/<arch>/arch.c */
extern const char *const arch_name;
void arch_early_init(void);   /* right after ExitBootServices: interrupts off, serial ready */
void arch_serial_putc(char c);
void arch_halt(void) __attribute__((noreturn));
/* Call fn(arg) with the stack pointer at top, which must be 16-byte aligned. */
void arch_switch_stack(void *top, void (*fn)(struct boot_info *), struct boot_info *arg)
    __attribute__((noreturn));
void arch_map_devices(void);  /* vm_map the device registers the code above touches */

/* arch/<arch>/exception.c: the processor's exceptions, in the kernel's hands,
 * and with them what a thread switch is made of (thread.c) */
void arch_exceptions_init(void);
extern const size_t arch_frame_size; /* sizeof(struct frame) */
/* Registers that begin start() on an empty stack that ends at stack_top, interrupts on. */
void arch_frame_init(struct frame *f, void *stack_top, void (*start)(void));
void arch_yield(void);        /* take an exception on purpose, so that thread_switch gets the caller's registers */

/* arch/<arch>/interrupt.c: the interrupt controller and the timer, as ACPI describes them */
void arch_interrupts_init(void);
void arch_interrupts_on(void);
int  arch_interrupts_off(void); /* says whether they were on */
void arch_wait(void);         /* sleep until an interrupt arrives: for the idle thread, which waits for nothing else */

/* arch/<arch>/entry.S: probes. Each tries one access and returns 0 when it
 * went through; when it faults, the exception handler makes it return 1. */
int  arch_probe_read(uint64_t addr);
int  arch_probe_write(uint64_t addr, uint8_t value);
int  arch_probe_exec(uint64_t addr);  /* call addr */
int  arch_probe_push(uint64_t sp);    /* push once with the stack pointer at sp */
void arch_probe_nothing(void);        /* code that is safe to call */

/* arch/<arch>/mmu.c: what a page-table entry holds, for the walk in vm.c */
int      arch_mmu_levels(void);                      /* how many levels of tables the processor walks */
uint64_t arch_pte_table(uint64_t pa);                /* an entry that points at the next table */
uint64_t arch_pte_page(uint64_t pa, unsigned flags); /* an entry that maps a page, flags as for vm_map */
void     arch_mmu_switch(uint64_t root);             /* use the tables under root from now on */
void     arch_tlb_flush(uint64_t va);                /* after changing va's entry in tables in use */

/* main.c */
void kmain(struct boot_info *bi) __attribute__((noreturn));
