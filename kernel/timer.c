/* Time, so far, is a count of ticks. The architecture programs a timer to
 * interrupt TIMER_HZ times a second (kernel/arch/<arch>/interrupt.c), and
 * each interrupt calls timer_tick. The tick is also what wakes the threads
 * that sleep, moves the processor from one thread to the next, and looks
 * at the serial port for what has been typed. A Lisp thread can wait for
 * it, like for any interrupt (lisp/thread.c). */
#include "kernel.h"
#include "lisp/lisp.h"

static volatile uint64_t g_ticks;
static uint64_t g_clock, g_clock_ticks; /* what time it was, in seconds since 1970 began, and at which tick that was */

void timer_tick(void)
{
    g_ticks++;
    console_tick();
    thread_tick(g_ticks);
    lisp_interrupt(LISP_INTERRUPT_TIMER);
}

uint64_t timer_ticks(void)
{
    return g_ticks;
}

/* The time of day is what the firmware's clock said as the machine was
 * taken, and the ticks since. A day is counted from the first of March of
 * a year that could be divided by 400, where the leap days fall at the
 * ends of the years, of the fours of years and of the centuries; and
 * 719468 such days had gone by when 1970 began. */
void timer_set_clock(const struct boot_clock *clock)
{
    uint64_t year, month, days;

    if (!clock->known)
        return;
    year = clock->year - (clock->month <= 2);
    month = clock->month > 2 ? clock->month - 3 : clock->month + 9;
    days = year / 400 * 146097 + year % 400 * 365 + year % 400 / 4 - year % 400 / 100 + (153 * month + 2) / 5 + clock->day - 1 - 719468;
    g_clock = (uint64_t)((int64_t)(days * 86400 + clock->hour * 3600 + clock->minute * 60 + clock->second) + clock->behind * 60);
    g_clock_ticks = g_ticks;
}

uint64_t timer_clock(void)
{
    return g_clock ? g_clock + (g_ticks - g_clock_ticks) / TIMER_HZ : 0;
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
