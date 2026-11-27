/* A machine for the C of the kernel that needs none, made of the computer
 * that the system is built on, so that this C can run there as a program,
 * with the compiler's sanitizers looking at every access to memory and at
 * everything that C leaves undefined (`make sanitize`). That C is the sums,
 * the ciphers and the signatures (sha256.c, sha512.c, hmac.c, aes.c,
 * ed25519.c, bignum.c, ecdsa.c), the functions for bytes (string.c), the
 * console's printing (console.c) and the whole runtime of Lisp
 * (kernel/lisp/), as far as a world comes that makes no code for a
 * processor: the reader, the printer, the heap and its collector, the
 * evaluator, the machine that runs compiled code, the threads of Lisp, and
 * every function in C that the self-tests call. Each of those files is
 * compiled as it stands, and what it asks of the rest of the kernel is
 * here, in a few lines for each thing:
 *
 *   page frames   one stretch of this computer's memory, handed out a page
 *                 at a time. A frame that is given back is filled with a
 *                 byte that no text and no pointer is made of, and where
 *                 the address sanitizer is at work a frame that is free may
 *                 not be touched at all.
 *   addresses     the heap of Lisp has its own, from VM_HEAP_BASE on, as on
 *                 the real machines. A page frame that is mapped there has
 *                 its bytes at that address and at no other until it is
 *                 unmapped: this machine has no tables that give one frame
 *                 two addresses, so what a real one allows, reaching a frame
 *                 of the heap by its own address as well, is refused here.
 *   threads       each a thread of this computer's, of which one at a time
 *                 runs: there is one processor, and a thread has it until it
 *                 waits, yields, or comes to a safe point while another is
 *                 ready. That is the one place where it differs from the
 *                 kernel's own, which takes the processor away at any tick.
 *   interrupts    one, the timer's, a hundred times a second, from a thread
 *                 that does nothing else. "Interrupts off" is a lock that it
 *                 takes as well.
 *   the console   this program's standard output. Nothing is ever typed.
 *
 * It has no screen, no I/O ports, no PCI bus, no disk and no power button,
 * and it says so in the words in which a real machine without them does.
 * What is not here at all is everything that is hardware, which the two
 * kernels are built to check for themselves with SANITIZE=undefined:
 * boot.c, pmm.c, vm.c, thread.c, timer.c, interrupt.c, acpi.c, fault.c,
 * fbcon.c and kernel/arch/. */
#define _GNU_SOURCE /* for the C library of Linux, which keeps what is not ISO C behind it */
#include "acpi.h"
#include "kernel.h"
#include "lisp/lisp.h"
#include "lisp/eval.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>

void host_world(void); /* world.c: the Lisp world, as far as this machine takes it */

/* Memory that may not be touched, for the address sanitizer when the
 * program is built with it, and nothing otherwise. */
#if defined(__has_feature) && __has_feature(address_sanitizer)
void __asan_poison_memory_region(void const volatile *addr, size_t size);
void __asan_unpoison_memory_region(void const volatile *addr, size_t size);
#define refuse(addr, bytes) __asan_poison_memory_region(addr, bytes)
#define allow(addr, bytes)  __asan_unpoison_memory_region(addr, bytes)
#else
#define refuse(addr, bytes) ((void)(addr), (void)(bytes))
#define allow(addr, bytes)  ((void)(addr), (void)(bytes))
#endif

static void stop(const char *why) __attribute__((noreturn));
static void stop(const char *why)
{
    fflush(stdout);
    fprintf(stderr, "host: %s\n", why);
    exit(1);
}

/* Page frames. */
enum { MEMORY_MIB = 256, FRAMES = MEMORY_MIB << (20 - PAGE_SHIFT), NOTHING = 0xa5 };

static uint8_t *g_memory;       /* where the frames are: the address of one is its own */
static uint8_t g_taken[FRAMES]; /* is the frame handed out? */
static uint64_t g_free, g_lowest; /* how many are not, and none below this one is */

/* Memory of this computer's: anywhere, or at an address, which it is
 * asked for and not made to give, since something of the program's own
 * could be there. */
static void *reserve(void *at, size_t bytes)
{
    void *memory = mmap(at, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);

    if (memory == MAP_FAILED || (at && memory != at))
        stop("this computer has no memory for the machine, or none at the addresses that the heap of Lisp has");
    return memory;
}

static void memory_init(void)
{
    g_memory = reserve(NULL, (size_t)FRAMES << PAGE_SHIFT);
    g_free = FRAMES;
    refuse(g_memory, (size_t)FRAMES << PAGE_SHIFT);
}

static uint64_t frame_of(uint64_t addr)
{
    return (addr - (uint64_t)(uintptr_t)g_memory) >> PAGE_SHIFT;
}

int pmm_is_ram(uint64_t addr)
{
    return addr >= (uint64_t)(uintptr_t)g_memory && frame_of(addr) < FRAMES;
}

uint64_t pmm_free_frames(void)
{
    return g_free;
}

uint64_t pmm_alloc(uint64_t pages)
{
    for (uint64_t first = g_lowest, run = 0; pages && first + pages <= FRAMES; first += run + 1) {
        for (run = 0; run < pages && !g_taken[first + run]; run++)
            ;
        if (run < pages)
            continue;
        memset(g_taken + first, 1, pages);
        g_free -= pages;
        while (g_lowest < FRAMES && g_taken[g_lowest])
            g_lowest++;
        allow(g_memory + (first << PAGE_SHIFT), pages << PAGE_SHIFT);
        return (uint64_t)(uintptr_t)g_memory + (first << PAGE_SHIFT);
    }
    return 0;
}

void pmm_free(uint64_t addr, uint64_t pages)
{
    uint64_t first = frame_of(addr);

    if (!pmm_is_ram(addr) || addr % PAGE_SIZE || first + pages > FRAMES)
        panic("host: %llu page frames at %p are freed, which are none of this machine's", (unsigned long long)pages,
              phys_ptr(addr));
    for (uint64_t i = first; i < first + pages; i++)
        if (!g_taken[i])
            panic("host: the page frame at %p is freed, and was free", (void *)(g_memory + (i << PAGE_SHIFT)));
    memset(g_taken + first, 0, pages);
    g_free += pages;
    if (first < g_lowest)
        g_lowest = first;
    allow(phys_ptr(addr), pages << PAGE_SHIFT);
    memset(phys_ptr(addr), NOTHING, pages << PAGE_SHIFT);
    refuse(phys_ptr(addr), pages << PAGE_SHIFT);
}

/* Addresses. The heap's are set aside when the machine starts, as many as
 * there are page frames, and a page of them can be used while a frame is
 * mapped there: its bytes are copied in when it is, and out again when it
 * is unmapped. */
static uint64_t g_mapped[FRAMES]; /* the frame at each page of the heap's addresses, or 0 */

static void addresses_init(void)
{
    reserve((void *)(uintptr_t)VM_HEAP_BASE, (size_t)FRAMES << PAGE_SHIFT);
    refuse((void *)(uintptr_t)VM_HEAP_BASE, (size_t)FRAMES << PAGE_SHIFT);
}

static int in_heap(uint64_t va)
{
    return va >= VM_HEAP_BASE && (va - VM_HEAP_BASE) >> PAGE_SHIFT < FRAMES;
}

uint64_t vm_lookup(uint64_t va)
{
    if (in_heap(va))
        return g_mapped[(va - VM_HEAP_BASE) >> PAGE_SHIFT];
    return pmm_is_ram(va) ? va & ~(PAGE_SIZE - 1) : 0;
}

void vm_map(uint64_t va, uint64_t pa, uint64_t pages, unsigned flags)
{
    if (flags != VM_WRITE || va % PAGE_SIZE || pa % PAGE_SIZE)
        panic("host: %llu pages are mapped at %p with flags %u: this machine maps memory that can be written, for the "
              "heap, and neither code for a processor nor a device",
              (unsigned long long)pages, (void *)(uintptr_t)va, flags);
    for (; pages; pages--, va += PAGE_SIZE, pa += PAGE_SIZE) {
        if (!in_heap(va) || vm_lookup(va) || !pmm_is_ram(pa) || !g_taken[frame_of(pa)])
            panic("host: the page frame at %p is mapped at %p, which is no free address of the heap's, or it is no "
                  "frame that was handed out",
                  phys_ptr(pa), (void *)(uintptr_t)va);
        g_mapped[(va - VM_HEAP_BASE) >> PAGE_SHIFT] = pa;
        allow((void *)(uintptr_t)va, PAGE_SIZE);
        memcpy((void *)(uintptr_t)va, phys_ptr(pa), PAGE_SIZE);
        refuse(phys_ptr(pa), PAGE_SIZE);
    }
}

void vm_unmap(uint64_t va, uint64_t pages)
{
    for (; pages; pages--, va += PAGE_SIZE) {
        uint64_t pa = vm_lookup(va);

        if (!in_heap(va) || !pa)
            panic("host: %p is unmapped, where nothing was mapped", (void *)(uintptr_t)va);
        allow(phys_ptr(pa), PAGE_SIZE);
        memcpy(phys_ptr(pa), (void *)(uintptr_t)va, PAGE_SIZE);
        g_mapped[(va - VM_HEAP_BASE) >> PAGE_SHIFT] = 0;
        refuse((void *)(uintptr_t)va, PAGE_SIZE);
    }
}

/* Threads. One has the processor, and the others that could run wait for
 * it in the order in which they came to. A thread waits on the one
 * condition that it has for all that it can wait for, and nobody else
 * waits on it: the processor, a wake, the end of the thread that it joins.
 * Each of those is looked at again when the condition says that something
 * has changed. */
struct thread {
    pthread_t self;
    pthread_cond_t changed;
    const char *name;
    void (*fn)(void *);
    void *arg;
    uint8_t *stack;       /* the memory that it runs on, the lowest byte first, */
    size_t stack_bytes;   /* and how much that is */
    struct thread *next;  /* in the queue for the processor */
    struct thread *joiner; /* the thread that waits for this one to end */
    struct thread *sleeper; /* the next thread that waits for a tick */
    uint64_t until;       /* the tick at which its wait is over */
    int woken;            /* thread_wake was called, and its thread_wait has not said so yet */
    int finished;
    int interrupts_off;
};

/* A stack is larger than the kernel would make it: the sanitizers put
 * more into every call. The evaluator is told that it ends SPARE bytes
 * above where it does, since what the evaluator leaves for the C that
 * does not ask how deep it is (MARGIN, eval.c) was measured without them. */
enum { LARGER = 4, SPARE = 2 << 20 };

static pthread_mutex_t g_threads = PTHREAD_MUTEX_INITIALIZER; /* for everything from here to the interrupts */
static struct thread *g_running, *g_ready, *g_ready_last;
static struct thread *g_sleepers; /* the threads whose wait ends at a tick */
static uint64_t g_ticks;          /* how often the timer has ticked */
static struct thread g_first = { .name = "host" };
static _Thread_local struct thread *g_self;

/* All three with g_threads held. Whoever asks this file for something
 * that can take the processor away has it: one that had not would be a
 * second thread running, which this machine does not have. */
static struct thread *the_running(const char *what)
{
    struct thread *me = g_self;

    if (g_running != me) {
        fflush(stdout);
        fprintf(stderr, "host: thread %s %s, and thread %s has the processor\n", me->name, what,
                g_running ? g_running->name : "nobody");
        abort();
    }
    return me;
}

static void give_processor(void)
{
    g_running = g_ready;
    if (g_running) {
        g_ready = g_running->next;
        pthread_cond_signal(&g_running->changed);
    }
}

static void take_processor(struct thread *me)
{
    if (!g_running)
        g_running = me;
    else {
        me->next = NULL;
        if (g_ready)
            g_ready_last->next = me;
        else
            g_ready = me;
        g_ready_last = me;
    }
    while (g_running != me)
        pthread_cond_wait(&me->changed, &g_threads);
}

static void threads_init(void)
{
    pthread_cond_init(&g_first.changed, NULL);
    g_self = g_running = &g_first;
}

static void *begin(void *thread)
{
    struct thread *me = g_self = thread;

    pthread_mutex_lock(&g_threads);
    take_processor(me);
    pthread_mutex_unlock(&g_threads);
    me->fn(me->arg);
    pthread_mutex_lock(&g_threads);
    me->finished = 1;
    if (me->joiner)
        pthread_cond_signal(&me->joiner->changed);
    give_processor();
    pthread_mutex_unlock(&g_threads);
    return NULL;
}

struct thread *thread_create(const char *name, void (*fn)(void *), void *arg, size_t stack)
{
    struct thread *t = calloc(1, sizeof *t);
    pthread_attr_t attr;

    if (!t)
        return NULL;
    t->name = name;
    t->fn = fn;
    t->arg = arg;
    t->stack_bytes = (stack * LARGER + SPARE + 0xffff) & ~(size_t)0xffff;
    t->stack = reserve(NULL, t->stack_bytes);
    pthread_cond_init(&t->changed, NULL);
    pthread_attr_init(&attr);
    if (pthread_attr_setstack(&attr, t->stack, t->stack_bytes) || pthread_create(&t->self, &attr, begin, t))
        stop("this computer does not start a thread for the machine");
    pthread_attr_destroy(&attr);
    return t;
}

void thread_join(struct thread *t)
{
    struct thread *me;

    pthread_mutex_lock(&g_threads);
    me = the_running("waits for another to end");
    if (!t->finished) {
        t->joiner = me;
        give_processor();
        while (!t->finished)
            pthread_cond_wait(&me->changed, &g_threads);
        take_processor(me);
    }
    pthread_mutex_unlock(&g_threads);
    pthread_join(t->self, NULL);
    munmap(t->stack, t->stack_bytes);
    pthread_cond_destroy(&t->changed);
    free(t);
}

void thread_yield(void)
{
    struct thread *me;

    pthread_mutex_lock(&g_threads);
    me = the_running("yields");
    if (g_ready) {
        give_processor();
        take_processor(me);
    }
    pthread_mutex_unlock(&g_threads);
}

/* The kernel's own takes the processor from a thread at any tick. This
 * one takes it where the evaluator looks up, which it does at every tick
 * (lisp_interrupt): a thread in a loop of Lisp gives way to one that has
 * just been made, as it does there. */
void thread_safe_point(void)
{
    thread_yield();
}

int thread_wait(uint64_t ticks)
{
    struct thread *me;
    int woken;

    pthread_mutex_lock(&g_threads);
    me = the_running("waits");
    if (!me->woken && ticks) {
        me->until = ticks == THREAD_FOREVER ? THREAD_FOREVER : g_ticks + ticks;
        me->sleeper = g_sleepers;
        g_sleepers = me;
        give_processor();
        while (!me->woken && g_ticks < me->until)
            pthread_cond_wait(&me->changed, &g_threads);
        for (struct thread **at = &g_sleepers; *at; at = &(*at)->sleeper)
            if (*at == me) {
                *at = me->sleeper;
                break;
            }
        take_processor(me);
    }
    woken = me->woken;
    me->woken = 0;
    pthread_mutex_unlock(&g_threads);
    return woken;
}

void thread_wake(struct thread *t)
{
    pthread_mutex_lock(&g_threads);
    t->woken = 1;
    pthread_cond_signal(&t->changed);
    pthread_mutex_unlock(&g_threads);
}

uint64_t thread_stack_guard(void)
{
    struct thread *me = g_self;

    if (!me->stack)
        panic("host: the thread that the machine started on evaluates nothing, and is asked how deep its stack goes");
    return (uint64_t)(uintptr_t)me->stack + SPARE - PAGE_SIZE;
}

/* A lock of the kernel's. A thread loses the processor only where it
 * asks this file for something, and whoever holds a lock asks for nothing
 * of the kind (kernel/thread.c would panic), so the lock is free whenever
 * another thread comes for it. */
void lock_acquire(struct lock *l)
{
    if (l->owner)
        panic("host: a lock is held by thread %s while %s runs", l->owner->name, g_self->name);
    l->owner = g_self;
}

void lock_release(struct lock *l)
{
    l->owner = NULL;
}

/* Interrupts: the timer's, from a thread of its own, which is the handler.
 * While a thread has them off the handler waits, and the other way round.
 * A tick is counted when its interrupt arrives, as kernel/timer.c counts
 * it, and not by this computer's clock: whoever has waited for three
 * interrupts has seen the count go up by as many. */
static pthread_mutex_t g_interrupts = PTHREAD_MUTEX_INITIALIZER;

int arch_interrupts_off(void)
{
    struct thread *me = g_self;

    if (me->interrupts_off)
        return 0;
    pthread_mutex_lock(&g_interrupts);
    me->interrupts_off = 1;
    return 1;
}

void arch_interrupts_on(void)
{
    struct thread *me = g_self;

    if (me->interrupts_off) {
        me->interrupts_off = 0;
        pthread_mutex_unlock(&g_interrupts);
    }
}

uint64_t timer_ticks(void)
{
    uint64_t ticks;

    pthread_mutex_lock(&g_threads);
    ticks = g_ticks;
    pthread_mutex_unlock(&g_threads);
    return ticks;
}

uint64_t timer_clock(void)
{
    return (uint64_t)time(NULL);
}

static void *timer(void *arg)
{
    static struct thread handler = { .name = "the timer's interrupt" };
    const struct timespec tick = { 0, 1000000000 / TIMER_HZ };

    (void)arg;
    g_self = &handler;
    for (;;) {
        nanosleep(&tick, NULL);
        arch_interrupts_off();
        pthread_mutex_lock(&g_threads);
        g_ticks++;
        for (struct thread *t = g_sleepers; t; t = t->sleeper)
            if (g_ticks >= t->until)
                pthread_cond_signal(&t->changed);
        pthread_mutex_unlock(&g_threads);
        lisp_interrupt(LISP_INTERRUPT_TIMER);
        arch_interrupts_on();
    }
    return NULL;
}

static void timer_init(void)
{
    pthread_t thread;

    if (pthread_create(&thread, NULL, timer, NULL))
        stop("this computer does not start a thread for the machine's timer");
    pthread_detach(thread);
}

/* What the machine is, to the kernel that asks. */
#if defined(__x86_64__)
const char *const arch_feature = "X86-64";
#elif defined(__aarch64__)
const char *const arch_feature = "ARM64";
#else
#error "the runtime's self-tests expect a processor that ClaraOS runs on: x86-64 or ARM64"
#endif
const char clara_system[] = CLARA_VERSION "-host";
const char *const arch_serial_kind = "HOST";
const uint64_t arch_serial_base = 0;
const char *arch_message_controller = NULL;
const uint32_t arch_code_trap = 0;

void arch_serial_putc(char c)
{
    if (c != '\r')
        putchar(c);
}

int arch_serial_getc(void)
{
    return -1;
}

void arch_halt(void)
{
    stop("the machine has stopped");
}

int arch_port_read(uint16_t port, unsigned size, uint32_t *value)
{
    (void)port;
    (void)size;
    (void)value;
    return 0;
}

int arch_port_write(uint16_t port, unsigned size, uint32_t value)
{
    (void)port;
    (void)size;
    (void)value;
    return 0;
}

void arch_power_off(void)
{
}

void arch_restart(void)
{
}

int arch_power_button(void)
{
    return -1;
}

void arch_code_written(uint64_t va, uint64_t bytes)
{
    (void)va;
    (void)bytes;
}

const void *acpi_table(const char *signature)
{
    (void)signature;
    return NULL;
}

int interrupt_message(uint32_t device, void (*handler)(unsigned source), struct interrupt_message *m)
{
    (void)device;
    (void)handler;
    (void)m;
    return -1;
}

void fbcon_putc(char c)
{
    (void)c;
}

void fbcon_set_color(enum fbcon_color color)
{
    (void)color;
}

int fbcon_lend(uint32_t *row, uint32_t *column)
{
    (void)row;
    (void)column;
    return 0;
}

void fbcon_return(uint32_t row, uint32_t column)
{
    (void)row;
    (void)column;
}

/* The two routines of entry.S that stand between C and code for a
 * processor. Nothing makes such code here, so nothing comes to them. */
lisp lisp_native_enter(const void *code, lisp *locals, lisp function, struct lisp_machine *machine, lisp nil)
{
    (void)locals;
    (void)function;
    (void)machine;
    panic("host: code for a processor at %p is to be run, and this machine runs none", code);
    return nil;
}

void lisp_native_call(void)
{
    panic("host: code for a processor calls a function, and this machine runs no such code");
}

/* The files that the boot handoff would have read: each in page frames of
 * its own, behind what says its name and its size, in the order in which
 * they are named. */
static struct boot_file *read_files(int count, char **paths)
{
    struct boot_file *files = NULL, **last = &files;

    for (int i = 0; i < count; i++) {
        const char *name = strrchr(paths[i], '/') ? strrchr(paths[i], '/') + 1 : paths[i];
        FILE *in = fopen(paths[i], "rb");
        struct stat is;
        struct boot_file *file;
        uint64_t head = sizeof *file + strlen(name) + 1, memory;

        if (!in || fstat(fileno(in), &is))
            stop("a file that the machine was to start with is not there to be read");
        memory = pmm_alloc((head + (uint64_t)is.st_size + PAGE_SIZE - 1) / PAGE_SIZE);
        if (!memory)
            stop("the machine has no memory for the files that it was to start with");
        file = phys_ptr(memory);
        file->next = NULL;
        file->name = strcpy((char *)(file + 1), name);
        file->data = (uint8_t *)file + head;
        file->size = (uint64_t)is.st_size;
        if (fread(file->data, 1, file->size, in) != file->size)
            stop("a file that the machine was to start with could not be read to its end");
        fclose(in);
        *last = file;
        last = &file->next;
    }
    return files;
}

/* What kmain does, of what there is here: the self-tests of what has no
 * machine in it, in its order, and then the Lisp world. */
int main(int argc, char **argv)
{
    static struct boot_info boot;

    setvbuf(stdout, NULL, _IOLBF, 0);
    memory_init();
    addresses_init();
    threads_init();
    kprintf("\nClaraOS %s on this computer, as a program: the C that needs no machine, with one made of it\n",
            CLARA_VERSION);
    kprintf("memory: %u MiB in page frames at %p\n", MEMORY_MIB, (void *)g_memory);
    boot.files = read_files(argc - 1, argv + 1);

    sha512_selftest();
    ed25519_selftest();
    sha256_selftest();
    hmac_selftest();
    aes_selftest();
    x25519_selftest();
    bignum_selftest();
    ecdsa_selftest();

    lisp_init(&boot);
    lisp_selftest();
    timer_init();
    host_world();
    kprintf("clara: nothing more to do\n");
    return 0;
}
