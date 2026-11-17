/* The threads of the Lisp world, and what they wait for.
 *
 * A Lisp thread is a thread of the substrate (kernel/thread.c) that
 * evaluates: it has a megabyte of stack for the evaluator's calls of
 * itself, and a struct lisp_evaluator, which holds the evaluator's two
 * stacks for it (eval.c). To Lisp it is an object, which MAKE-THREAD
 * returns and JOIN-THREAD waits for.
 *
 * One thread at a time has the runtime: the heap, the packages, and the
 * evaluator's own variables. A thread that has it keeps it until it comes
 * to a safe point, and gives it up there when a tick has gone by and
 * another thread wants it, or when it has to wait. So everything in
 * kernel/lisp/ runs as it did when there was one thread: nothing in it
 * takes a lock, and between two safe points nobody else is in the heap.
 * The substrate still takes the processor away at any tick; what it gives
 * it to meanwhile is a thread that does not evaluate. The price is that a
 * function in C that takes long holds every Lisp thread up, as it holds
 * up the collector.
 *
 * It follows that the collector, which runs in the thread that has the
 * runtime, finds every other Lisp thread standing at a safe point: it
 * waits for the runtime, or for something else, and in both cases its
 * evaluator has put away all that it holds (lisp_thread_roots).
 *
 * Waiting is built on one thing, thread_wait and thread_wake. A thread
 * that waits puts itself in the queue of what it waits for, gives the
 * runtime up, and sleeps until it is woken; then it takes the runtime
 * back and looks again. What it can wait for: the runtime, a lock, an
 * event, a thread to finish, and time. An interrupt handler can signal an
 * event, and that is the one thing here a handler touches, so the events'
 * count and queue are only ever changed with interrupts off.
 *
 * A thread ends when its function returns, when a condition that nothing
 * handles comes out of it, or when DESTROY-THREAD has told it to stop:
 * then it leaves by way of every UNWIND-PROTECT, from its next safe point
 * or from the wait it is in. Nobody has to wait for it. What it was to the
 * substrate goes to a thread that does nothing else but give such memory
 * back. */
#include "lisp.h"

#define STACK_SIZE (1024 * 1024)

struct context {
    struct context *next;  /* in g_contexts, or in g_dead */
    struct context *queue; /* the next thread that waits for the same lock, event or thread */
    struct context *wants; /* the next thread that waits for the runtime */
    struct thread *thread; /* what it is to the substrate */
    struct lisp_evaluator *evaluator; /* right after this struct, in the same run of page frames */
    uint64_t pages;        /* how long that run is */
    lisp self;             /* what it is to Lisp */
    void (*main)(void);    /* the first thread's: what it runs, in C */
    volatile int stop;     /* DESTROY-THREAD was called for it, and it has not acted on that yet */
    char name[40];         /* for the substrate, which says it in a fault report */
};

static struct context *g_contexts;     /* every Lisp thread that has not finished */
static struct context *g_running;      /* the one that has the runtime, or NULL */
static struct context *g_wanting;      /* the ones that wait for it, in order of arrival */
static struct context *g_first;        /* the thread the Lisp world started on, which reads from the console */
static uint64_t g_turn;                /* the tick at which g_running got the runtime */
static int g_break = 1;                /* Ctrl-C stops what g_first is computing: not while it reads a line */
static struct context *volatile g_dead; /* finished, for the reaper */
static struct thread *g_reaper;

/* The runtime. */
static void enter(struct context *me)
{
    int on = arch_interrupts_off();

    if (g_running) {
        struct context **at = &g_wanting;

        while (*at)
            at = &(*at)->wants;
        me->wants = NULL;
        *at = me;
    } else
        g_running = me;
    if (on)
        arch_interrupts_on();
    while (g_running != me) /* until leave() hands it over */
        thread_wait(THREAD_FOREVER);
    g_turn = timer_ticks();
    lisp_evaluator_in(me->evaluator);
}

/* The thread that has the runtime gives it to the one that has waited
 * longest, or to nobody. It is at a safe point: whatever it holds is
 * where its evaluator keeps it. */
static void leave(void)
{
    struct context *me = g_running, *next;
    int on;

    lisp_evaluator_out(me->evaluator);
    on = arch_interrupts_off();
    next = g_wanting;
    if (next) {
        g_wanting = next->wants;
        thread_wake(next->thread);
    }
    g_running = next;
    if (on)
        arch_interrupts_on();
}

/* Give the runtime up and wait: until thread_wake, or for that many ticks.
 * Other threads have evaluated, and the collector may have run, by the
 * time this returns. */
static void wait(uint64_t ticks)
{
    struct context *me = g_running;

    leave();
    thread_wait(ticks);
    enter(me);
}

/* From the evaluator's safe point. When a tick has gone by since this
 * thread got the runtime and another waits for it, the other has its
 * turn, and this one queues up behind the rest. Then: has the thread been
 * told to stop, or, if it is the one that reads from the console, has
 * Ctrl-C been typed there? */
enum lisp_turn lisp_thread_safe_point(void)
{
    struct context *me = g_running;

    if (!me)
        return LISP_GO_ON;
    if (g_wanting && timer_ticks() != g_turn) {
        leave();
        enter(me);
    }
    if (me->stop) {
        me->stop = 0;
        return LISP_STOP;
    }
    if (me == g_first && g_break && console_break && console_interrupted())
        return LISP_BREAK;
    return LISP_GO_ON;
}

/* For the collector, which runs in the thread that has the runtime: every
 * thread there is, and what the evaluator has put away for each of the
 * others. */
void lisp_thread_roots(void)
{
    for (const struct context *c = g_contexts; c; c = c->next) {
        lisp_reach(c->self);
        if (c != g_running)
            lisp_evaluator_reach(c->evaluator);
    }
}

/* The queue of the threads that wait for a lock, an event or a thread: a
 * word of the object, which holds the address of the first. */
static struct context *first(const lisp *queue)
{
    return (struct context *)(uintptr_t)*queue;
}

static void queue_add(lisp *queue, struct context *c)
{
    struct context *last = first(queue);

    c->queue = NULL;
    if (!last) {
        *queue = (lisp)(uintptr_t)c;
        return;
    }
    while (last->queue)
        last = last->queue;
    last->queue = c;
}

static void queue_remove(lisp *queue, struct context *c)
{
    struct context *at = first(queue);

    if (at == c) {
        *queue = (lisp)(uintptr_t)c->queue;
        return;
    }
    for (; at; at = at->queue)
        if (at->queue == c) {
            at->queue = c->queue;
            return;
        }
}

/* The end of a thread: what became of it is in the object, for whoever
 * asks, the threads that wait for it are woken, and the collector no
 * longer looks at what it held. */
static void finish(struct context *c, enum lisp_thread_state state, lisp result)
{
    struct lisp_thread *t = lisp_as_thread(c->self);

    t->state = lisp_fixnum(state);
    t->result = result;
    t->function = LISP_NIL;
    t->context = 0;
    for (const struct context *w = first(&t->waiting); w; w = w->queue)
        thread_wake(w->thread);
    for (struct context **at = &g_contexts; *at; at = &(*at)->next)
        if (*at == c) {
            *at = c->next;
            break;
        }
}

/* Where every Lisp thread begins. The first runs the function in C that it
 * was given, and whoever started it waits for it. Any other calls its
 * Lisp function; when that is over, the reaper gives its memory back. */
static void thread_main(void *arg)
{
    struct context *c = arg;
    lisp result = LISP_NIL, report[2];
    int on;

    enter(c);
    lisp_eval_start();
    if (c->main) {
        c->main();
        finish(c, LISP_FINISHED, LISP_NIL);
        leave();
        return;
    }
    switch (lisp_call(lisp_as_thread(c->self)->function, 0, NULL)) {
    case 1:
        for (unsigned i = lisp_values.count; i--;)
            result = lisp_cons(lisp_values.value[i], result);
        finish(c, LISP_FINISHED, result);
        break;
    case 0:
        /* Nobody may ever ask what became of it, so it is said here and now, by the function in
         * lisp/boot.lisp that writes it to the console. The condition is on the value stack while
         * that runs, and in nobody's hands but this variable's from there to finish(). */
        report[0] = c->self;
        report[1] = lisp_values.value[0];
        lisp_call(lisp_symbol_in(lisp_roots.clara, "%THREAD-FAILED", 0), 2, report);
        result = report[1];
        finish(c, LISP_FAILED, result);
        break;
    default:
        finish(c, LISP_STOPPED, LISP_NIL);
    }
    leave();
    on = arch_interrupts_off();
    c->next = g_dead;
    g_dead = c;
    if (on)
        arch_interrupts_on();
    thread_wake(g_reaper);
}

/* A thread cannot give back the stack it is running on. This one waits
 * for each Lisp thread that has finished to leave the processor for good,
 * and then frees its stack and what the evaluator kept for it. It never
 * touches the runtime. */
static void reaper(void *arg)
{
    (void)arg;
    for (;;) {
        thread_wait(THREAD_FOREVER);
        for (;;) {
            int on = arch_interrupts_off();
            struct context *c = g_dead;

            if (c)
                g_dead = c->next;
            if (on)
                arch_interrupts_on();
            if (!c)
                break;
            thread_join(c->thread);
            pmm_free((uint64_t)(uintptr_t)c, c->pages);
        }
    }
}

/* A new thread, which is ready to run and waits for the runtime: NULL when
 * there is no memory for it. The substrate knows it by the ASCII of its
 * name. */
static struct context *make(lisp name, lisp function, void (*main)(void))
{
    uint64_t pages = (sizeof(struct context) + lisp_evaluator_bytes() + PAGE_SIZE - 1) / PAGE_SIZE;
    uint64_t memory = pmm_alloc(pages);
    struct context *c = phys_ptr(memory);
    struct lisp_thread *t;

    if (!memory)
        return NULL;
    memset(c, 0, sizeof *c);
    c->pages = pages;
    c->evaluator = (struct lisp_evaluator *)(c + 1);
    lisp_evaluator_new(c->evaluator);
    c->main = main;
    memcpy(c->name, "lisp", 5);
    if (lisp_is(name, LISP_STRING)) {
        const struct lisp_string *s = lisp_as_string(name);
        uint64_t i = 0;

        for (; i < lisp_length(s->header) && i < sizeof c->name - 1; i++)
            c->name[i] = s->chars[i] >= ' ' && s->chars[i] < 0x7f ? (char)s->chars[i] : '?';
        c->name[i] = 0;
    }
    t = lisp_alloc(LISP_THREAD, 0);
    t->name = name;
    t->function = function;
    t->state = lisp_fixnum(LISP_RUNNING);
    t->result = LISP_NIL;
    t->context = (lisp)(uintptr_t)c;
    c->self = (lisp)(uintptr_t)t | LISP_TAG_OBJECT;
    c->next = g_contexts;
    g_contexts = c;
    c->thread = thread_create(c->name, thread_main, c, STACK_SIZE);
    if (!c->thread) {
        g_contexts = c->next;
        t->state = lisp_fixnum(LISP_STOPPED);
        t->context = 0;
        pmm_free(memory, pages);
        return NULL;
    }
    return c;
}

/* The thread that the Lisp world starts on, and the reaper for the ones
 * that it will make. Whoever calls this waits for the thread it returns. */
struct thread *lisp_first_thread(void (*main)(void))
{
    g_reaper = thread_create("lisp reaper", reaper, NULL, THREAD_STACK_SIZE);
    g_first = make(lisp_string_from_utf8("listener", 8), LISP_NIL, main);
    if (!g_reaper || !g_first)
        panic("lisp: no memory for the first thread of the Lisp world");
    console_break_wakes(g_first->thread);
    kprintf("lisp: threads of %u KiB of stack and %llu KiB for the evaluator; one at a time has the runtime\n",
            STACK_SIZE >> 10, (g_first->pages * PAGE_SIZE) >> 10);
    return g_first->thread;
}

/* The functions that Lisp calls, in the package CLARA. */
#define NIL LISP_NIL
#define T   lisp_roots.t

static lisp name_of(unsigned argc, const lisp *argv, unsigned i)
{
    return argc > i ? argv[i] : NIL;
}

LISP_PRIMITIVE(lisp_p_make_thread) /* function name */
{
    const struct context *c;

    (void)argc;
    if (!lisp_is_symbol(argv[0]) && !lisp_is(argv[0], LISP_FUNCTION))
        return lisp_wants("a function", argv[0]);
    if (argv[1] != NIL && !lisp_is(argv[1], LISP_STRING))
        return lisp_wants("a string, or NIL, for the name of a thread", argv[1]);
    c = make(argv[1], argv[0], NULL);
    if (!c)
        return lisp_fail_as("STORAGE-CONDITION", NULL, 0, "there is no memory for another thread");
    return c->self;
}

LISP_PRIMITIVE(lisp_p_current_thread)
{
    (void)argc;
    (void)argv;
    return g_running->self;
}

LISP_PRIMITIVE(lisp_p_threadp)
{
    (void)argc;
    return lisp_is(argv[0], LISP_THREAD) ? T : NIL;
}

LISP_PRIMITIVE(lisp_p_thread_name)
{
    (void)argc;
    return lisp_is(argv[0], LISP_THREAD) ? lisp_as_thread(argv[0])->name : lisp_wants("a thread", argv[0]);
}

LISP_PRIMITIVE(lisp_p_thread_alive_p)
{
    (void)argc;
    if (!lisp_is(argv[0], LISP_THREAD))
        return lisp_wants("a thread", argv[0]);
    return lisp_as_thread(argv[0])->state == lisp_fixnum(LISP_RUNNING) ? T : NIL;
}

LISP_PRIMITIVE(lisp_p_all_threads)
{
    lisp list = NIL;

    (void)argc;
    (void)argv;
    for (const struct context *c = g_contexts; c; c = c->next)
        list = lisp_cons(c->self, list);
    return list;
}

/* (join-thread thread): wait until it has finished; the values of its
 * function. A thread that ended any other way is an error here. */
LISP_PRIMITIVE(lisp_p_join_thread)
{
    struct context *me = g_running;
    struct lisp_thread *t = lisp_as_thread(argv[0]);
    unsigned n = 0;

    (void)argc;
    if (!lisp_is(argv[0], LISP_THREAD))
        return lisp_wants("a thread", argv[0]);
    if (argv[0] == me->self)
        return lisp_fail("the thread ~S cannot wait for itself to finish", argv[0]);
    while (t->state == lisp_fixnum(LISP_RUNNING)) {
        queue_add(&t->waiting, me);
        wait(THREAD_FOREVER);
        queue_remove(&t->waiting, me);
        if (!lisp_safe_point())
            return NIL;
    }
    if (t->state == lisp_fixnum(LISP_FAILED))
        return lisp_fail("the thread ~S ended with an error: ~A", argv[0], t->result);
    if (t->state == lisp_fixnum(LISP_STOPPED))
        return lisp_fail("the thread ~S was stopped", argv[0]);
    for (lisp v = t->result; lisp_is_cons(v) && n < LISP_VALUES_MAX; v = lisp_as_cons(v)->cdr)
        lisp_values.value[n++] = lisp_as_cons(v)->car;
    lisp_values.count = n;
    return n ? lisp_values.value[0] : NIL;
}

/* (destroy-thread thread): tell it to stop. It does so itself, at its next
 * safe point or out of the wait it is in, and leaves by way of every
 * UNWIND-PROTECT; no handler sees it go. */
LISP_PRIMITIVE(lisp_p_destroy_thread)
{
    struct context *c;

    (void)argc;
    if (!lisp_is(argv[0], LISP_THREAD))
        return lisp_wants("a thread", argv[0]);
    c = first(&lisp_as_thread(argv[0])->context);
    if (c == g_first)
        return lisp_fail("the thread ~S reads from the console, and cannot be stopped", argv[0]);
    if (!c)
        return NIL;
    c->stop = 1;
    thread_wake(c->thread);
    return T;
}

/* (thread-yield): every other thread that can run goes first, the ones
 * that wait for the runtime and the ones that have yet to ask for it. */
LISP_PRIMITIVE(lisp_p_thread_yield)
{
    struct context *me = g_running;

    (void)argc;
    (void)argv;
    leave();
    thread_yield();
    enter(me);
    lisp_safe_point(); /* it may have been told to stop meanwhile */
    return NIL;
}

/* How many ticks a time is that Lisp gives in units of which there are
 * that many to a second, rounded up; 0 after failing. */
static int ticks_of(lisp time, uint64_t per_second, uint64_t *ticks)
{
    if (!lisp_is_fixnum(time) || lisp_fixnum_value(time) < 0 || lisp_fixnum_value(time) > (int64_t)1 << 40) {
        lisp_wants("a time, an integer that is not negative", time);
        return 0;
    }
    *ticks = ((uint64_t)lisp_fixnum_value(time) * TIMER_HZ + per_second - 1) / per_second;
    return 1;
}

/* (sleep seconds): the other threads run meanwhile. */
LISP_PRIMITIVE(lisp_p_sleep)
{
    uint64_t ticks, until, now;

    (void)argc;
    if (!ticks_of(argv[0], 1, &ticks))
        return NIL;
    until = timer_ticks() + ticks;
    while ((now = timer_ticks()) < until) {
        wait(until - now);
        if (!lisp_safe_point())
            return NIL;
    }
    return NIL;
}

/* Locks. A lock is held by one thread, and the threads that want it
 * meanwhile get it in the order they asked. Only a thread that has the
 * runtime looks at one, so this needs no more protection than that. */
LISP_PRIMITIVE(lisp_p_make_lock)
{
    struct lisp_lock *l;
    lisp name = name_of(argc, argv, 0);

    if (name != NIL && !lisp_is(name, LISP_STRING))
        return lisp_wants("a string, or NIL, for the name of a lock", name);
    l = lisp_alloc(LISP_LOCK, 0);
    l->name = name;
    l->owner = NIL;
    return (lisp)(uintptr_t)l | LISP_TAG_OBJECT;
}

LISP_PRIMITIVE(lisp_p_acquire_lock)
{
    struct context *me = g_running;
    struct lisp_lock *l = lisp_as_lock(argv[0]);

    (void)argc;
    if (!lisp_is(argv[0], LISP_LOCK))
        return lisp_wants("a lock", argv[0]);
    if (l->owner == me->self)
        return lisp_fail("the thread ~S holds the lock ~S already", me->self, argv[0]);
    for (;;) {
        if (l->owner == NIL)
            l->owner = me->self;
        if (l->owner == me->self)
            return T;
        queue_add(&l->waiting, me);
        wait(THREAD_FOREVER);
        if (l->owner == me->self)
            return T; /* RELEASE-LOCK handed it over, and took this thread out of the queue */
        queue_remove(&l->waiting, me);
        if (!lisp_safe_point())
            return NIL;
    }
}

LISP_PRIMITIVE(lisp_p_release_lock)
{
    struct lisp_lock *l = lisp_as_lock(argv[0]);
    struct context *next;

    (void)argc;
    if (!lisp_is(argv[0], LISP_LOCK))
        return lisp_wants("a lock", argv[0]);
    if (l->owner != g_running->self)
        return lisp_fail("the thread ~S does not hold the lock ~S", g_running->self, argv[0]);
    next = first(&l->waiting);
    if (next) {
        queue_remove(&l->waiting, next);
        l->owner = next->self;
        thread_wake(next->thread);
    } else
        l->owner = NIL;
    return NIL;
}

/* Events. An event counts how often it was signalled, and WAIT-EVENT
 * takes one of those, waiting for it if there is none. An interrupt
 * handler can signal one, so the count and the queue are looked at and
 * changed with interrupts off, in one go. */
LISP_PRIMITIVE(lisp_p_make_event)
{
    struct lisp_event *e;
    lisp name = name_of(argc, argv, 0);

    if (name != NIL && !lisp_is(name, LISP_STRING))
        return lisp_wants("a string, or NIL, for the name of an event", name);
    e = lisp_alloc(LISP_EVENT, 0);
    e->name = name;
    return (lisp)(uintptr_t)e | LISP_TAG_OBJECT;
}

/* The thread that has waited longest looks again. Interrupts are off. */
static void wake_first(struct lisp_event *e)
{
    const struct context *c = first(&e->waiting);

    if (c)
        thread_wake(c->thread);
}

LISP_PRIMITIVE(lisp_p_signal_event) /* event, and how many times: once */
{
    struct lisp_event *e = lisp_as_event(argv[0]);
    lisp times = argc > 1 ? argv[1] : lisp_fixnum(1);
    int on;

    if (!lisp_is(argv[0], LISP_EVENT))
        return lisp_wants("an event", argv[0]);
    if (!lisp_is_fixnum(times) || lisp_fixnum_value(times) < 1 || lisp_fixnum_value(times) > 1 << 30)
        return lisp_wants("a number of times, a positive integer", times);
    on = arch_interrupts_off();
    e->count += times;
    wake_first(e);
    if (on)
        arch_interrupts_on();
    return argv[0];
}

/* (serial-break flag): whether Ctrl-C on the serial port stops what the
 * thread that reads from the console is computing; what it was before.
 * The console in Lisp turns it off while it reads a line, where Ctrl-C is
 * a byte like the others and gives the line up. */
LISP_PRIMITIVE(lisp_p_serial_break)
{
    int before = g_break;

    (void)argc;
    g_break = argv[0] != NIL;
    return before ? T : NIL;
}

/* Interrupts. A handler cannot run Lisp, and does not have to: it signals
 * an event, and the driver is a thread that waits for it. The event of a
 * source is made when Lisp first asks for it, and is the same from then
 * on. An interrupt that arrives while the last one has not been waited for
 * is not counted again: the event says that the source wants attention,
 * as an interrupt line does. */
static const char *const sources[LISP_INTERRUPT_MESSAGE] = { "TIMER", "SERIAL" };

void lisp_interrupt(enum lisp_interrupt source)
{
    lisp event = lisp_roots.interrupts[source];

    if (lisp_is(event, LISP_EVENT)) {
        struct lisp_event *e = lisp_as_event(event);

        if (!e->count)
            e->count = lisp_fixnum(1);
        wake_first(e);
    }
}

LISP_PRIMITIVE(lisp_p_interrupt_event) /* :TIMER, a hundred times a second, or :SERIAL, when bytes have arrived */
{
    (void)argc;
    for (unsigned i = 0; i < LISP_INTERRUPT_MESSAGE; i++)
        if (argv[0] == lisp_symbol_in(lisp_roots.keyword, sources[i], 1)) {
            if (!lisp_is(lisp_roots.interrupts[i], LISP_EVENT)) {
                struct lisp_event *e = lisp_alloc(LISP_EVENT, 0);

                e->name = lisp_as_symbol(argv[0])->name;
                lisp_roots.interrupts[i] = (lisp)(uintptr_t)e | LISP_TAG_OBJECT;
            }
            return lisp_roots.interrupts[i];
        }
    return lisp_wants("a source of interrupts, :TIMER or :SERIAL", argv[0]);
}

/* A device's interrupt. A PCI device raises one by writing a number to an
 * address, a message, and the interrupt controller says which number and
 * which address (kernel/interrupt.c): the driver puts both into the device.
 * (message-interrupt device) takes the bus, device and function of the
 * device, 8, 5 and 3 bits of one number, and gives three values: the event
 * that the interrupt signals, the address, and the number. An interrupt
 * that was handed out stays handed out. */
static void message_arrived(unsigned source)
{
    lisp_interrupt((enum lisp_interrupt)(LISP_INTERRUPT_MESSAGE + source));
}

LISP_PRIMITIVE(lisp_p_message_interrupt)
{
    static const char digits[] = "0123456789abcdef";
    char name[] = "PCI 00:00.0";
    struct interrupt_message m;
    struct lisp_event *e;
    int64_t device = lisp_fixnum_value(argv[0]);
    int source;

    (void)argc;
    if (!lisp_is_fixnum(argv[0]) || device < 0 || device > 0xffff)
        return lisp_wants("the bus, device and function of a PCI device, as one number of 16 bits", argv[0]);
    source = interrupt_message((uint32_t)device, message_arrived, &m);
    if (source == -1)
        return lisp_fail("nothing in this machine takes a device's message for an interrupt");
    if (source < 0)
        return lisp_fail("there is no interrupt left for the device ~X: ~Z hands out ~A, and not every device can have one",
                         argv[0], arch_message_controller, lisp_fixnum(INTERRUPT_SOURCES));
    name[4] = digits[device >> 12 & 0xf];
    name[5] = digits[device >> 8 & 0xf];
    name[7] = digits[device >> 7 & 0x1];
    name[8] = digits[device >> 3 & 0xf];
    name[10] = digits[device & 0x7];
    e = lisp_alloc(LISP_EVENT, 0);
    e->name = lisp_string_from_utf8(name, sizeof name - 1);
    lisp_roots.interrupts[LISP_INTERRUPT_MESSAGE + source] = (lisp)(uintptr_t)e | LISP_TAG_OBJECT;
    lisp_values.count = 3;
    lisp_values.value[0] = lisp_roots.interrupts[LISP_INTERRUPT_MESSAGE + source];
    lisp_values.value[1] = lisp_fixnum((int64_t)m.address);
    lisp_values.value[2] = lisp_fixnum(m.data);
    return lisp_values.value[0];
}

/* (wait-event event [milliseconds]): T once the event has been signalled,
 * NIL when the time ran out first. */
LISP_PRIMITIVE(lisp_p_wait_event)
{
    struct context *me = g_running;
    struct lisp_event *e = lisp_as_event(argv[0]);
    uint64_t ticks = 0, until = THREAD_FOREVER, now;
    int on;

    if (!lisp_is(argv[0], LISP_EVENT))
        return lisp_wants("an event", argv[0]);
    if (argc > 1 && argv[1] != NIL) {
        if (!ticks_of(argv[1], 1000, &ticks))
            return NIL;
        until = timer_ticks() + ticks;
    }
    for (;;) {
        int taken = 0, waits = 0;

        on = arch_interrupts_off();
        now = timer_ticks();
        if (e->count) {
            e->count -= lisp_fixnum(1);
            if (e->count)
                wake_first(e); /* there is one for the next in line as well */
            taken = 1;
        } else if (now < until) {
            queue_add(&e->waiting, me);
            waits = 1;
        }
        if (on)
            arch_interrupts_on();
        if (taken)
            return T;
        if (!waits)
            return NIL;
        wait(until == THREAD_FOREVER ? THREAD_FOREVER : until - now);
        on = arch_interrupts_off();
        queue_remove(&e->waiting, me);
        if (on)
            arch_interrupts_on();
        if (!lisp_safe_point())
            return NIL;
    }
}
