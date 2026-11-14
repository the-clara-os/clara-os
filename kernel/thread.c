/* Threads: several flows of control that take turns on the one processor.
 *
 * A thread that is not running is its registers, put away. The entry code
 * of the architecture (entry.S) saves the registers of whatever an
 * exception or an interrupt cut short in a struct frame, hands the frame
 * to C, and resumes with what the frame holds when C is done. So a switch
 * is two copies: the frame goes into the thread that was running, and the
 * frame of the thread that runs next takes its place. Nothing else saves or
 * restores a register. A thread that has to wait takes an exception on
 * purpose (arch_yield) and is switched the same way.
 *
 * Who runs next is a queue. A thread that becomes ready joins the back,
 * and the timer's tick sends the running thread to the back when another
 * is waiting for a turn. When none is, the idle thread runs, which sleeps
 * until the next interrupt.
 *
 * There is one processor, so with interrupts off the running thread is
 * alone. Everything here that touches a queue does so with interrupts off,
 * and that is all the locking this file needs. A thread decides to wait and
 * starts waiting inside one such stretch, so that what it waits for cannot
 * happen in between and go unnoticed.
 *
 * The collector (M6c) needs every other thread to stand still, somewhere
 * it can account for what the thread holds. Such a place is a safe point:
 * a call of thread_safe_point, and every wait for a tick or for another
 * thread to finish. thread_stop_the_world returns once every other thread
 * is at one, and they stay until thread_start_the_world. */
#include "kernel.h"

#define STACK_PAGES (THREAD_STACK_SIZE / PAGE_SIZE)

enum state {
    RUNNING,  /* the one that has the processor */
    READY,    /* in the queue for a turn; the idle thread is in no queue */
    SLEEPING, /* until a tick: in g_sleepers */
    WAITING,  /* for a lock, for a thread to finish, or for the world to stop */
    PARKED,   /* at a safe point, until the world starts again */
    FINISHED, /* for good: thread_join frees it */
};

struct thread {
    const char *name;
    enum state state;
    struct thread *next;   /* in the queue it is waiting in, whichever that is */
    uint64_t wake;         /* a sleeper: the tick it is waiting for */
    void (*fn)(void *);
    void *arg;
    uint8_t *stack;        /* its memory, lowest address first: a guard page, then the stack */
    struct thread *joiner; /* the thread that waits for this one to finish */
    struct frame *frame;   /* its registers, while it is not running */
};

/* The first thread is the flow of control that kmain started in, on the
 * stack in the kernel image (boot.c). It exists from the first instruction:
 * the locks in the allocators want an owner long before thread_init. */
static uint64_t g_boot_frame[64]; /* room for the registers of either architecture */
static struct thread g_boot = {
    .name = "boot",
    .state = RUNNING,
    .stack = kernel_stack,
    .frame = (struct frame *)g_boot_frame,
};

static struct thread *g_current = &g_boot;
static struct thread *g_idle;
static struct thread_queue g_ready;
static struct thread *g_sleepers; /* soonest first */
static unsigned g_awake = 1;      /* threads that are running or ready, the idle thread aside */
static int g_turn_over;           /* the running thread has had its turn */
static uint64_t g_switches;

static struct thread *g_stopper;  /* the thread that has stopped the world, or is stopping it */
static int g_stopping;            /* it is waiting for the others to stop */
static struct thread_queue g_parked;

static void push(struct thread_queue *q, struct thread *t)
{
    t->next = NULL;
    if (q->last)
        q->last->next = t;
    else
        q->first = t;
    q->last = t;
}

static struct thread *pop(struct thread_queue *q)
{
    struct thread *t = q->first;

    if (t && !(q->first = t->next))
        q->last = NULL;
    return t;
}

/* t can run again, and joins the queue for a turn. Interrupts are off. */
static void ready(struct thread *t)
{
    t->state = READY;
    g_awake++;
    push(&g_ready, t);
}

/* The running thread stops here, in the state given, until something calls
 * ready() on it. Interrupts are off, and have been since the caller looked
 * at what it is going to wait for and put itself on record there: the look
 * and the wait are one step. */
static void block(enum state why)
{
    g_current->state = why;
    if (--g_awake == 0 && g_stopping) {
        /* That was the last thread the world was waiting for. */
        g_stopping = 0;
        ready(g_stopper);
    }
    arch_yield();
}

/* From the architecture's exception code, with interrupts off: at the end
 * of every interrupt, and when a thread asks through arch_yield. f holds
 * the registers of the thread that was running. When it is another's turn,
 * they are put away and the other's take their place, and the exception
 * returns into the other thread. */
void thread_switch(struct frame *f)
{
    struct thread *prev = g_current, *next;
    int turn_over = g_turn_over || prev == g_idle; /* the idle thread makes way for anyone */

    g_turn_over = 0;
    if (prev->state == RUNNING) {
        if (!turn_over || !g_ready.first)
            return;
        prev->state = READY;
        if (prev != g_idle)
            push(&g_ready, prev);
    }
    next = pop(&g_ready);
    if (!next)
        next = g_idle;
    if (!next)
        panic("the only thread there is has started to wait: thread_init comes first");
    memcpy(prev->frame, f, arch_frame_size);
    memcpy(f, next->frame, arch_frame_size);
    next->state = RUNNING;
    g_current = next;
    g_switches++;
}

/* From the timer's interrupt, with the new count of ticks: wake the
 * sleepers whose tick has come, and end the running thread's turn. */
void thread_tick(uint64_t now)
{
    while (g_sleepers && g_sleepers->wake <= now) {
        struct thread *t = g_sleepers;

        g_sleepers = t->next;
        ready(t);
    }
    g_turn_over = 1;
}

void thread_yield(void)
{
    int on = arch_interrupts_off();

    g_turn_over = 1;
    arch_yield();
    if (on)
        arch_interrupts_on();
}

/* Until the timer has ticked that many more times, and once at least. The
 * tick in progress counts as one, so the wait is shorter than the ticks
 * asked for by up to the length of one. */
void thread_sleep(uint64_t ticks)
{
    int on = arch_interrupts_off();
    struct thread **at = &g_sleepers;

    g_current->wake = timer_ticks() + ticks;
    while (*at && (*at)->wake <= g_current->wake)
        at = &(*at)->next;
    g_current->next = *at;
    *at = g_current;
    block(SLEEPING);
    if (on)
        arch_interrupts_on();
    thread_safe_point();
}

/* Wait at a safe point until the world starts again. Interrupts are off. */
static void park(void)
{
    push(&g_parked, g_current);
    block(PARKED);
}

/* A place where the running thread can be held up for as long as the world
 * is stopped: it holds no lock here, and nothing that the thread which
 * stopped the world cannot account for. One comparison when the world is
 * not being stopped, so it can be called often. */
void thread_safe_point(void)
{
    if (!g_stopper || g_stopper == g_current)
        return;
    int on = arch_interrupts_off();

    while (g_stopper && g_stopper != g_current)
        park();
    if (on)
        arch_interrupts_on();
}

/* Returns when every other thread is at a safe point: parked at one,
 * asleep, or waiting for a thread to finish. Whichever of them wakes before
 * the world starts again parks before it does anything else. A thread that
 * waits for a lock is on its way and not there yet: it gets the lock and
 * runs on to its next safe point, like the threads that were ready. So the
 * caller must hold no lock, and a thread that never comes to a safe point
 * keeps this from returning.
 *
 * Between here and thread_start_the_world the caller may sleep and take
 * locks; the others stay where they are. */
void thread_stop_the_world(void)
{
    int on = arch_interrupts_off();

    while (g_stopper) /* another thread is at it: this is a safe point like any other */
        park();
    g_stopper = g_current;
    while (g_awake > 1) {
        g_stopping = 1;
        block(WAITING);
    }
    if (on)
        arch_interrupts_on();
}

void thread_start_the_world(void)
{
    int on = arch_interrupts_off();
    struct thread *t;

    if (g_stopper != g_current)
        panic("thread %s starts a world that it did not stop", g_current->name);
    g_stopper = NULL;
    while ((t = pop(&g_parked)))
        ready(t);
    if (on)
        arch_interrupts_on();
}

/* A lock is held by one thread at a time. A thread that finds it taken
 * queues up and sleeps, and the lock is handed to the queue in order of
 * arrival. Never from an interrupt handler, which cannot wait. Hold one
 * briefly: not across a sleep, and not at a safe point. */
void lock_acquire(struct lock *l)
{
    int on = arch_interrupts_off();

    if (l->owner == g_current)
        panic("thread %s wants a lock that it already holds", g_current->name);
    if (l->owner) {
        push(&l->waiting, g_current);
        block(WAITING); /* and it is the owner when it runs again */
    } else
        l->owner = g_current;
    if (on)
        arch_interrupts_on();
}

void lock_release(struct lock *l)
{
    int on = arch_interrupts_off();

    if (l->owner != g_current)
        panic("thread %s releases a lock that it does not hold", g_current->name);
    l->owner = pop(&l->waiting);
    if (l->owner)
        ready(l->owner);
    if (on)
        arch_interrupts_on();
}

/* Where every thread but the first begins, with interrupts on. */
static void start(void)
{
    thread_safe_point(); /* a thread made while the world is stopped waits like the rest */
    g_current->fn(g_current->arg);
    thread_exit();
}

/* A thread and its stack are one run of page frames. The lowest is a guard
 * page, unmapped, so that a stack which overflows faults instead of
 * writing over whatever lies below. The struct thread and the room for its
 * registers are at the top, and the stack starts right under them. */
static struct thread *create(const char *name, void (*fn)(void *), void *arg)
{
    uint64_t memory = pmm_alloc(1 + STACK_PAGES);
    uint64_t top = memory + (1 + STACK_PAGES) * PAGE_SIZE;
    struct thread *t = phys_ptr((top - arch_frame_size - sizeof *t) & ~15ULL);

    if (!memory)
        return NULL;
    vm_unmap(memory, 1);
    memset(t, 0, sizeof *t);
    t->name = name;
    t->fn = fn;
    t->arg = arg;
    t->stack = phys_ptr(memory);
    t->frame = (struct frame *)(t + 1);
    arch_frame_init(t->frame, t, start);
    return t;
}

/* A new thread that runs fn(arg) and finishes when fn returns, or NULL
 * when there is no memory for its stack. Somebody has to thread_join it. */
struct thread *thread_create(const char *name, void (*fn)(void *), void *arg)
{
    struct thread *t = create(name, fn, arg);

    if (t) {
        int on = arch_interrupts_off();

        ready(t);
        if (on)
            arch_interrupts_on();
    }
    return t;
}

void thread_exit(void)
{
    arch_interrupts_off();
    if (g_current->joiner)
        ready(g_current->joiner);
    block(FINISHED);
    panic("thread %s has finished and is running again", g_current->name);
}

/* Wait for t to finish, then give its memory back. Once for every thread
 * that thread_create returned, and by one thread: nothing else frees it. */
void thread_join(struct thread *t)
{
    uint64_t memory = (uint64_t)(uintptr_t)t->stack;
    int on = arch_interrupts_off();

    if (t == g_current || t->joiner)
        panic("thread %s is joined by itself, or twice", t->name);
    t->joiner = g_current;
    if (t->state != FINISHED)
        block(WAITING);
    if (on)
        arch_interrupts_on();
    vm_map(memory, memory, 1, VM_WRITE); /* the guard page is RAM like any other again */
    pmm_free(memory, 1 + STACK_PAGES);
    thread_safe_point();
}

/* The page under the running thread's stack, where nothing is mapped. */
uint64_t thread_stack_guard(void)
{
    return (uint64_t)(uintptr_t)g_current->stack;
}

const char *thread_name(void)
{
    return g_current->name;
}

static void idle(void *arg)
{
    (void)arg;
    for (;;)
        arch_wait();
}

void thread_init(void)
{
    if (arch_frame_size > sizeof g_boot_frame)
        panic("the boot thread has room for %u bytes of registers, and the processor has %u",
              (unsigned)sizeof g_boot_frame, (unsigned)arch_frame_size);
    g_idle = create("idle", idle, NULL);
    if (!g_idle)
        panic("no memory for the idle thread");
    kprintf("threads: kmain is the first, an idle thread runs when no other can; %u KiB stacks, turns of %u ms\n",
            THREAD_STACK_SIZE >> 10, 1000 / TIMER_HZ);
}

/* The self-test. Three threads go through every way there is of losing the
 * processor and getting it back, and the boot thread stops the world under
 * them. Nothing here measures time, so it passes on a machine of any speed.
 * What goes wrong is a panic, or a thread that waits for good, and then
 * the boot test runs into its timeout. */
enum { TEST_THREADS = 3, TEST_ROUNDS = 2 };

static struct lock test_lock;
static volatile unsigned test_baton;               /* whose move it is */
static volatile uint64_t test_total;               /* under test_lock */
static volatile uint64_t test_count[TEST_THREADS]; /* how far each thread has counted */
static volatile int test_over;

/* Arithmetic with nothing to it, except that every step needs the one before. */
static uint64_t test_step(uint64_t x, uint64_t i)
{
    return (x ^ x >> 29) * 0x9e3779b97f4a7c15ULL + i;
}

static void test_thread(void *arg)
{
    unsigned me = (unsigned)(uintptr_t)arg;
    uint64_t x = me, again = me, steps = 0, before;

    /* A stack of its own, over a guard page that the fault handlers know. */
    fault_stack_selftest();

    /* Switches that are imposed. Nobody in this loop gives the processor
     * up, so the baton comes round only because the timer takes the
     * processor from one spinning thread and gives it to the next. The
     * arithmetic lives in registers all the while, and comes out wrong if
     * a switch loses one. */
    for (unsigned round = 0; round < TEST_ROUNDS; round++) {
        while (test_baton != me)
            x = test_step(x, steps++);
        test_baton = (me + 1) % TEST_THREADS;
    }
    for (uint64_t i = 0; i < steps; i++)
        again = test_step(again, i);
    if (x != again)
        panic("thread self-test: thread %u lost a register in a switch", me);

    /* Switches that are asked for, and a lock. A thread reads the total,
     * lets the others run, and writes back one more. Without the lock the
     * others would read the same total meanwhile, and additions would be
     * lost; with it they queue up, and the lock goes from hand to hand. */
    for (unsigned round = 0; round < TEST_ROUNDS; round++) {
        lock_acquire(&test_lock);
        uint64_t total = test_total;
        thread_yield();
        test_total = total + 1;
        lock_release(&test_lock);
    }

    /* Sleep, each thread for a different time, and none woken early. */
    before = timer_ticks();
    thread_sleep(me + 1);
    if (timer_ticks() - before < me + 1)
        panic("thread self-test: thread %u slept %llu ticks, not %u", me, timer_ticks() - before, me + 1);

    /* Work that can be stopped: a thread counts, and between two counts it
     * is at a safe point. For the first thread that is a sleep and nothing
     * else, so it is asleep when the world stops, or soon after, and wakes
     * while the world is stopped: it must not get as far as counting. */
    while (!test_over) {
        test_count[me]++;
        if (me == 0)
            thread_sleep(1);
        else
            thread_safe_point();
    }
}

void thread_selftest(void)
{
    static const char *const names[TEST_THREADS] = { "self-test 0", "self-test 1", "self-test 2" };
    struct thread *threads[TEST_THREADS];
    uint64_t frames = pmm_free_frames(), switches = g_switches, seen[TEST_THREADS];

    test_baton = 0;
    test_total = 0;
    test_over = 0;
    for (unsigned i = 0; i < TEST_THREADS; i++) {
        test_count[i] = 0;
        if (!(threads[i] = thread_create(names[i], test_thread, (void *)(uintptr_t)i)))
            panic("thread self-test: no memory for a thread");
    }

    /* Once all of them are counting, stop the world. They have to stay
     * where they are while time passes, and go on when it starts again. */
    for (unsigned i = 0; i < TEST_THREADS; i++)
        while (!test_count[i])
            thread_sleep(1);
    thread_stop_the_world();
    for (unsigned i = 0; i < TEST_THREADS; i++)
        seen[i] = test_count[i];
    thread_sleep(3);
    for (unsigned i = 0; i < TEST_THREADS; i++)
        if (test_count[i] != seen[i])
            panic("thread self-test: thread %u went on while the world was stopped", i);
    thread_start_the_world();
    for (unsigned i = 0; i < TEST_THREADS; i++)
        while (test_count[i] == seen[i])
            thread_sleep(1);

    test_over = 1;
    for (unsigned i = 0; i < TEST_THREADS; i++)
        thread_join(threads[i]);
    if (test_total != TEST_THREADS * TEST_ROUNDS)
        panic("thread self-test: %llu additions under the lock came to %llu", (uint64_t)TEST_THREADS * TEST_ROUNDS,
              (uint64_t)test_total);
    if (pmm_free_frames() != frames)
        panic("thread self-test: %llu page frames free at the end, %llu at the start", pmm_free_frames(), frames);
    kprintf("threads: self-test passed, %llu switches: by the timer, by choice, on a lock, asleep, world stopped\n",
            g_switches - switches);
}
