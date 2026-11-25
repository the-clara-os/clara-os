/* Kernel-wide interfaces. Note: our targets are LLP64 (long is 32 bits), so
 * the kernel never uses long; it uses the <stdint.h> types. */
#pragma once
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#define CLARA_VERSION "0.0.58"

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

/* system.c: what this system is called, its version and the digits of its
 * build, which is also the name of its directory under \clara on the boot
 * volume. A name is this long at most, the 0 at its end included. */
#define SYSTEM_NAME 40
extern const char clara_system[];

/* The time of day as the firmware's clock had it when the machine was
 * taken: the kernel has no driver for a clock, and counts on from there. */
struct boot_clock {
    int      known;            /* the firmware said something that can be a time */
    unsigned year, month, day, hour, minute, second;
    int      behind;           /* minutes that this is behind Greenwich's time; 0 when the firmware does not say */
};

/* What the boot handoff learned from the firmware before taking the machine,
 * and from the boot volume about the starts before this one. */
struct boot_info {
    struct framebuffer fb;
    void    *memory_map;       /* EFI memory map; descriptors are desc_size bytes apart */
    uint64_t memory_map_size;
    uint64_t desc_size;
    void    *acpi_rsdp;        /* ACPI 2.0 root pointer, or NULL */
    void    *dtb;              /* flattened device tree, or NULL */
    struct boot_file *files;   /* the system's own, in directory order, and the world that was saved; or NULL */
    unsigned starts;           /* how many starts in a row, before this one, did not come to a prompt */
    uint64_t token;            /* what the handoff wrote on the boot volume for this start, which says which volume that is; or 0 */
    int      trial;            /* this system is being tried: the one before it started it, and is still there */
    char     failed[SYSTEM_NAME]; /* the system that was tried and did not come to its prompt, or "" */
    int      image_passed_over; /* a saved world is there and was not read, the start before this not having come to a prompt */
    struct boot_clock clock;   /* what time the firmware said it was */
};

/* boot.c: the stack kmain starts on. It is part of the kernel image, and its
 * lowest page is a guard that vm_init unmaps. */
#define KERNEL_STACK_SIZE (64 * 1024)
extern uint8_t kernel_stack[PAGE_SIZE + KERNEL_STACK_SIZE];

/* console.c: the substrate's own console, for the boot report and for its
 * last words. Text goes to the serial port and, after fbcon_init, to the
 * screen, unless that is lent to the console in Lisp. %d %u %x %X %s %c %p and %% are supported, with zero padding and
 * width. The compiler checks the arguments: 64-bit ones are %llu, %llx. */
void kputc(char c);
void kputs(const char *s);
void kprintf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void kvprintf(const char *fmt, va_list ap) __attribute__((format(printf, 1, 0)));
void panic(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
void console_serial_only(void); /* leave the screen alone from now on */
int  console_getc(void);          /* the next byte typed on the serial port, or -1: the reader does the waiting */
void console_tick(void);          /* from the timer's interrupt: take in what has arrived on the serial port */
extern volatile int console_break; /* Ctrl-C has arrived there, and nobody has acted on it yet */
void console_break_now(void);     /* Ctrl-C has been typed somewhere else: on a keyboard, which has a driver in Lisp */
struct thread;
void console_break_wakes(struct thread *t); /* and this thread is woken when it does */
int  console_interrupted(void);   /* for a computation that can stop: has it? Asked once, it is acted on */

/* fbcon.c: the text console on the framebuffer */
enum fbcon_color { FBCON_TEXT, FBCON_ACCENT, FBCON_ALERT, FBCON_COLORS };
void fbcon_init(const struct framebuffer *fb);
void fbcon_putc(char c);
void fbcon_set_color(enum fbcon_color color);
int  fbcon_lend(uint32_t *row, uint32_t *column);  /* another console draws from now on: where this one left off */
void fbcon_return(uint32_t row, uint32_t column);  /* and gives the screen back, with its own cursor there */

/* font.c, generated from fonts/spleen-8x16.bdf by tools/bdf2c.py */
#define FONT_WIDTH  8
#define FONT_HEIGHT 16
const uint8_t *font_glyph(char c); /* FONT_HEIGHT bytes, one per scanline, leftmost pixel in bit 7 */

/* pmm.c: the page frames of physical memory. Addresses here are physical,
 * which is why they are numbers and not pointers. */
void     pmm_init(const struct boot_info *bi);
uint64_t pmm_alloc(uint64_t pages);  /* adjacent frames, lowest first; 0 when no run is long enough */
uint64_t pmm_alloc_aligned(uint64_t pages, uint64_t align); /* the same, at a multiple of align bytes, a power of two */
int      pmm_is_ram(uint64_t addr);  /* does the firmware's map call the page frame at addr memory? */
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
#define VM_CODE_BASE 0x0000200000000000ULL /* and for the code that the Lisp world makes for the processor: */
#define VM_CODE_SIZE 0x0000000040000000ULL /* 1 GiB, starting at 32 TiB */
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
void     timer_set_clock(const struct boot_clock *clock); /* what time it was at some moment, from which the ticks count on */
uint64_t timer_clock(void);    /* seconds since 1970 began in Greenwich; 0 when nobody said what time it is */
void     timer_selftest(void);

/* thread.c: threads, taking turns on the processor, and locks between them */
#define THREAD_STACK_SIZE (64 * 1024) /* of a thread that asks for no more; the first is on kernel_stack */
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
/* A thread that runs fn(arg) on a stack of that many bytes. The name is kept, not copied. NULL when
 * there is no memory for the stack. */
struct thread *thread_create(const char *name, void (*fn)(void *), void *arg, size_t stack);
void thread_join(struct thread *t);  /* wait until it has finished, and free it: once for every thread */
void thread_exit(void) __attribute__((noreturn)); /* what returning from fn does */
void thread_yield(void);             /* the other threads that are ready go first */
void thread_sleep(uint64_t ticks);   /* until the timer has ticked that many more times */
#define THREAD_FOREVER (~0ULL)
int  thread_wait(uint64_t ticks);    /* until thread_wake, or for that many ticks: was it woken? */
void thread_wake(struct thread *t);  /* its thread_wait returns, this one or the next: also from a handler */
void thread_safe_point(void);        /* the thread waits here while the world is stopped */
void thread_stop_the_world(void);    /* returns when every other thread is asleep or at a safe point */
void thread_start_the_world(void);
void thread_tick(uint64_t now);      /* from timer_tick */
void thread_switch(struct frame *f); /* from the architecture's exception code, interrupts off */
uint64_t thread_stack_guard(void);   /* the unmapped page under the running thread's stack */
const char *thread_name(void);       /* the running thread's */
struct thread *thread_self(void);    /* the running thread */
void thread_selftest(void);
void lock_acquire(struct lock *l);   /* waits its turn; never in an interrupt handler */
void lock_release(struct lock *l);

/* sha512.c: the sixty-four bytes that stand for any number of bytes (FIPS 180-4) */
struct sha512_state {
    uint64_t h[8], bytes; /* the sum so far, and of how many bytes */
    uint8_t rest[128];    /* what has not filled a block yet, */
    unsigned held;        /* and how much that is */
};
void sha512(const void *data, uint64_t bytes, uint8_t sum[64]);
void sha512_begin(struct sha512_state *state);
void sha512_add(struct sha512_state *state, const void *data, uint64_t bytes);
void sha512_end(struct sha512_state *state, uint8_t sum[64]);
void sha512_selftest(void);

void sha384_begin(struct sha512_state *state); /* another beginning, of which the first 48 bytes of the end are kept */

/* sha256.c: the thirty-two bytes that stand for any number of bytes */
struct sha256_state {
    uint32_t h[8];
    uint64_t bytes;
    uint8_t  rest[64];
    unsigned held;
};
void sha256(const void *data, uint64_t bytes, uint8_t sum[32]);
void sha256_begin(struct sha256_state *state);
void sha256_add(struct sha256_state *state, const void *data, uint64_t bytes);
void sha256_end(struct sha256_state *state, uint8_t sum[32]);
void sha256_selftest(void);

/* hmac.c: the sums by their number of bits, 256, 384 or 512, and the sum that takes a key (RFC 2104) */
struct digest_state {
    unsigned bits;
    union {
        struct sha256_state small;
        struct sha512_state large;
    } of;
};
unsigned digest_bytes(unsigned bits);
void digest_begin(struct digest_state *state, unsigned bits);
void digest_add(struct digest_state *state, const void *data, uint64_t bytes);
void digest_end(struct digest_state *state, uint8_t *sum);
void digest(unsigned bits, const void *data, uint64_t bytes, uint8_t *sum);
void hmac(unsigned bits, const void *key, uint64_t key_bytes, const void *data, uint64_t bytes, uint8_t *sum);
void hmac_selftest(void);

/* aes.c: bytes closed and opened with a key, and a tag that says nobody changed them (NIST SP 800-38D) */
int  aes128_gcm(int opening, const uint8_t key[16], const uint8_t nonce[12], const uint8_t *beside, uint64_t beside_bytes,
                const uint8_t *from, uint64_t bytes, uint8_t *to, uint8_t tag[16]);
void aes_selftest(void);

/* ed25519.c: whether a signature is that of a key (RFC 8032), and what two sides agree on (RFC 7748) */
int ed25519_verify(const uint8_t key[32], const void *message, uint64_t bytes, const uint8_t signature[64]);
void ed25519_selftest(void);
int  x25519(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32]);
void x25519_selftest(void);

/* bignum.c: numbers of up to 4096 bits, in pieces of 32, the lowest first, and their products modulo another */
#define BIG_WORDS 128
struct big_modulus {
    unsigned words;             /* how many pieces it has */
    uint32_t n[BIG_WORDS];      /* the modulus */
    uint32_t square[BIG_WORDS]; /* R times R modulo it, R being one more than its pieces can hold */
    uint32_t inverse;           /* minus one over it, modulo 2^32 */
};
int      big_read(uint32_t *words, unsigned count, const uint8_t *bytes, uint64_t length);
void     big_write(uint8_t *bytes, uint64_t length, const uint32_t *words, unsigned count);
int      big_compare(const uint32_t *a, const uint32_t *b, unsigned words);
int      big_zero(const uint32_t *a, unsigned words);
uint32_t big_add(uint32_t *r, const uint32_t *a, const uint32_t *b, unsigned words);
uint32_t big_subtract(uint32_t *r, const uint32_t *a, const uint32_t *b, unsigned words);
int      big_modulus(struct big_modulus *m, const uint8_t *bytes, uint64_t count);
void     big_multiply(uint32_t *r, const uint32_t *a, const uint32_t *b, const struct big_modulus *m);
void     big_enter(uint32_t *r, const uint32_t *a, const struct big_modulus *m);
void     big_leave(uint32_t *r, const uint32_t *a, const struct big_modulus *m);
void     big_power(uint32_t *r, const uint32_t *a, const uint32_t *exponent, unsigned exponent_words,
                   const struct big_modulus *m);
int      power_mod(uint8_t *out, const uint8_t *base, uint64_t base_bytes, uint64_t exponent, const uint8_t *modulus,
                   uint64_t modulus_bytes);
void     bignum_selftest(void);

/* ecdsa.c: whether two numbers are the signature that a key gives a sum, on the curves P-256 and P-384 (FIPS 186-5) */
int  ecdsa_verify(unsigned bits, const uint8_t *key, const uint8_t *sum, uint64_t sum_bytes, const uint8_t *r, uint64_t r_bytes,
                  const uint8_t *s, uint64_t s_bytes);
void ecdsa_selftest(void);

/* string.c */
void  *memset(void *dst, int c, size_t n);
void  *memcpy(void *dst, const void *src, size_t n);
void  *memmove(void *dst, const void *src, size_t n); /* the two may overlap */
int    memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);

/* arch/<arch>/arch.c */
extern const char *const arch_name;
extern const char *const arch_kernel; /* what the firmware calls the kernel of this architecture: "BOOTX64.EFI" */
extern const char *const arch_feature; /* what *FEATURES* calls it, as SBCL does: "X86-64", "ARM64" */
void arch_early_init(void);   /* right after ExitBootServices: interrupts off, serial ready */
void arch_serial_putc(char c);
int  arch_serial_getc(void);  /* the next byte that has arrived, or -1 when none is waiting */
void arch_halt(void) __attribute__((noreturn));
/* Call fn(arg) with the stack pointer at top, which must be 16-byte aligned. */
void arch_switch_stack(void *top, void (*fn)(struct boot_info *), struct boot_info *arg)
    __attribute__((noreturn));
void arch_map_devices(void);  /* vm_map the device registers the code above touches */
/* I/O ports, on the machines that have them: 0 when this one has none. size is 1, 2 or 4 bytes. */
int  arch_port_read(uint16_t port, unsigned size, uint32_t *value);
int  arch_port_write(uint16_t port, unsigned size, uint32_t value);
/* The serial port, for a driver other than the one above: what it is, and
 * its first I/O port or the address of its registers. */
extern const char *const arch_serial_kind;
extern const uint64_t arch_serial_base;
/* A page frame that the firmware of these machines reads whenever one of
 * them starts, by its address, or 0 when it reads none: the allocator never
 * hands it out (pmm.c). */
extern const uint64_t arch_kept_frame;

/* arch/<arch>/power.c: turning the machine off, starting it again, and its
 * power button, each by the way that ACPI names for this machine. */
void arch_power_init(void);   /* find the three, and say in the boot report what there is */
void arch_power_off(void);    /* returns when the machine has no way, or did not go by it: from a thread */
void arch_restart(void);      /* likewise */
int  arch_power_button(void); /* has it been pressed since this was last asked? -1 when the machine has none */

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

/* interrupt.c: interrupts from devices. A PCI device asks for attention by
 * writing a number to an address, a message (MSI, MSI-X), and the
 * interrupt controller makes an interrupt of the write. No wire is
 * involved, so nothing has to be known about how the machine is wired. */
#define INTERRUPT_SOURCES 32  /* how many such interrupts there can be */
struct interrupt_message {
    uint64_t address;         /* where the device has to write */
    uint32_t data;            /* and what */
};
/* A message for the PCI device at that bus, device and function (8, 5 and
 * 3 bits of one number) to send: handler is called with the number of the
 * source, which is also what this returns, whenever the message arrives.
 * -1 when the machine has no controller for messages that the kernel
 * knows, -2 when there are no more to be had. Only from a thread. */
int  interrupt_message(uint32_t device, void (*handler)(unsigned source), struct interrupt_message *m);
void interrupt_deliver(unsigned source); /* from the architecture's handler: the message of that source has arrived */
/* arch/<arch>/interrupt.c again: what takes messages on this machine, in
 * words, or NULL when nothing does; and the message that arrives as
 * interrupt_deliver(source), or 0 when the controller cannot be told. */
extern const char *arch_message_controller;
int  arch_message(uint32_t device, unsigned source, struct interrupt_message *m);

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
void     arch_code_written(uint64_t va, uint64_t bytes); /* code was written there, through another address: the
                                                        processor forgets what it remembers of the old */
extern const uint32_t arch_code_trap;                /* four bytes that the processor refuses to run */

/* main.c */
void kmain(struct boot_info *bi) __attribute__((noreturn));
