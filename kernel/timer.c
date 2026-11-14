/* Time, so far, is a count of ticks. The architecture programs a timer to
 * interrupt TIMER_HZ times a second (kernel/arch/<arch>/interrupt.c), and
 * each interrupt calls timer_tick. The tick is also what wakes the threads
 * that sleep and moves the processor from one thread to the next. */
#include "kernel.h"

static volatile uint64_t g_ticks;

void timer_tick(void)
{
    g_ticks++;
    thread_tick(g_ticks);
}

uint64_t timer_ticks(void)
{
    return g_ticks;
}

/* Let interrupts in and sleep until a few ticks have gone by. Nothing here
 * measures how long that takes, so it passes on a machine of any speed; a
 * timer that never interrupts leaves the boot waiting here for good, and
 * the boot test fails on its timeout. Interrupts stay on afterwards.
 *
 * This runs before thread_init, with no other thread to hand the
 * processor to, and waits the way the idle thread does. A tick that
 * arrives between the look at the count and arch_wait is slept through,
 * which costs one tick here; after thread_init there is thread_sleep,
 * where that cannot happen. */
void timer_selftest(void)
{
    enum { TICKS = 3 };
    uint64_t start = g_ticks;

    arch_interrupts_on();
    while (g_ticks - start < TICKS)
        arch_wait();
    kprintf("timer: self-test passed, %u ticks counted with interrupts on\n", TICKS);
}
