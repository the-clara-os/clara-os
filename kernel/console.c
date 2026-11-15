#include "kernel.h"
#include "lisp/lisp.h"

static int g_serial_only;
static struct lock g_lock;

/* A thread has the console to itself for the length of one call, so that
 * what two threads print does not mix inside it. With interrupts off there
 * is nobody to wait for and no way to wait: that is the boot before it
 * lets interrupts in, a handler, a fault report or a panic, and it prints
 * at once, into the middle of another thread's line if it must. Says
 * whether the lock was taken. */
static int enter(void)
{
    int on = arch_interrupts_off();

    if (on) {
        arch_interrupts_on();
        lock_acquire(&g_lock);
    }
    return on;
}

static void leave(int locked)
{
    if (locked)
        lock_release(&g_lock);
}

/* Every character goes to the serial port and, once fbcon_init has found a
 * display, to the screen as well. Text is UTF-8, and the screen has one
 * cell for a character, whatever it is: the bytes that continue one are
 * not shown, and the first byte of a character outside ASCII gets the
 * font's sign for what it does not have. */
static void put_char(char c)
{
    if (c == '\n')
        arch_serial_putc('\r');
    arch_serial_putc(c);
    if (!g_serial_only && ((uint8_t)c & 0xc0) != 0x80)
        fbcon_putc(c);
}

static void put_string(const char *s)
{
    while (*s)
        put_char(*s++);
}

void kputc(char c)
{
    int locked = enter();

    put_char(c);
    leave(locked);
}

/* For a report of trouble that may lie in drawing on the screen itself. */
void console_serial_only(void)
{
    g_serial_only = 1;
}

void kputs(const char *s)
{
    int locked = enter();

    put_string(s);
    leave(locked);
}

/* What has been typed on the serial port and not read yet. No interrupt
 * arrives for a byte there (ROADMAP.md, M8), so the timer's tick takes in
 * what the port holds, as far as there is room here; what there is no room
 * for stays in the port. A thread takes bytes out at the other end, and
 * each of the two changes only its own end, so they need no lock between
 * them.
 *
 * Ctrl-C is a byte like the others, and it is also noted when it arrives,
 * because the thread it is meant for is not reading: it is computing, and
 * looks at console_break whenever it could stop, or it is waiting, and is
 * woken to look. */
enum { TYPED = 256 };
static volatile uint8_t g_typed[TYPED];
static volatile unsigned g_typed_in, g_typed_out; /* where the next byte goes in, and where the next comes out */
volatile int console_break;
static struct thread *g_break_wakes; /* the thread that Ctrl-C is meant for, which may be waiting */

/* Ctrl-C is for this thread from now on: it is woken when one arrives, so
 * that a wait can be given up like a computation. */
void console_break_wakes(struct thread *t)
{
    g_break_wakes = t;
}

void console_tick(void)
{
    int c, some = 0;

    while ((g_typed_in + 1) % TYPED != g_typed_out && (c = arch_serial_getc()) >= 0) {
        some = 1;
        if (c == 0x03) {
            console_break = 1;
            if (g_break_wakes)
                thread_wake(g_break_wakes);
        }
        g_typed[g_typed_in] = (uint8_t)c;
        g_typed_in = (g_typed_in + 1) % TYPED;
    }
    if (some)
        lisp_interrupt(LISP_INTERRUPT_SERIAL); /* for a reader in Lisp, which waits for this */
}

/* The next byte that was typed, or -1 when there is none. */
static int typed(void)
{
    int c;

    if (g_typed_out == g_typed_in)
        return -1;
    c = g_typed[g_typed_out];
    g_typed_out = (g_typed_out + 1) % TYPED;
    return c;
}

/* For the console in Lisp, which reads the lines: the next byte that was
 * typed, or -1. It waits for the event that console_tick signals. A Ctrl-C
 * that is read has done what it was typed for. */
int console_getc(void)
{
    int c = typed();

    if (c == 0x03)
        console_break = 0;
    return c;
}

/* For a computation, at a place where it can stop: was Ctrl-C typed? Then
 * the computation acts on it, and it is not asked for again. A Ctrl-C that
 * is the next byte to be read has done all it was typed for and goes; one
 * with other bytes before it stays, to give up the line that they begin. */
int console_interrupted(void)
{
    if (!console_break)
        return 0;
    console_break = 0;
    if (g_typed_out != g_typed_in && g_typed[g_typed_out] == 0x03)
        g_typed_out = (g_typed_out + 1) % TYPED;
    return 1;
}

static void put_num(uint64_t v, unsigned base, int width, char pad, int negative, int upper)
{
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char buf[24];
    int i = 0;

    do {
        buf[i++] = digits[v % base];
        v /= base;
    } while (v);
    if (negative && pad != '0')
        buf[i++] = '-';
    while (i < width - (negative && pad == '0'))
        buf[i++] = pad;
    if (negative && pad == '0')
        buf[i++] = '-';
    while (i--)
        put_char(buf[i]);
}

static void format(const char *fmt, va_list ap)
{
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            put_char(*fmt);
            continue;
        }
        fmt++;
        char pad = ' ';
        int width = 0, wide = 0;
        if (*fmt == '0') {
            pad = '0';
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l' || *fmt == 'z') {
            wide = 1;
            fmt++;
        }
        switch (*fmt) {
        case 'c':
            put_char((char)va_arg(ap, int));
            break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            put_string(s ? s : "(null)");
            break;
        }
        case 'd': {
            int64_t v = wide ? va_arg(ap, int64_t) : va_arg(ap, int);
            put_num(v < 0 ? -(uint64_t)v : (uint64_t)v, 10, width, pad, v < 0, 0);
            break;
        }
        case 'u':
            put_num(wide ? va_arg(ap, uint64_t) : va_arg(ap, unsigned), 10, width, pad, 0, 0);
            break;
        case 'x':
            put_num(wide ? va_arg(ap, uint64_t) : va_arg(ap, unsigned), 16, width, pad, 0, 0);
            break;
        case 'X':
            put_num(wide ? va_arg(ap, uint64_t) : va_arg(ap, unsigned), 16, width, pad, 0, 1);
            break;
        case 'p':
            put_string("0x");
            put_num((uint64_t)(uintptr_t)va_arg(ap, void *), 16, 16, '0', 0, 0);
            break;
        case '%':
            put_char('%');
            break;
        case 0:
            return;
        default:
            put_char('%');
            put_char(*fmt);
            break;
        }
    }
}

void kvprintf(const char *fmt, va_list ap)
{
    int locked = enter();

    format(fmt, ap);
    leave(locked);
}

void kprintf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    kvprintf(fmt, ap);
    va_end(ap);
}

/* Say why, in the alert colour, and stop the machine. */
void panic(const char *fmt, ...)
{
    va_list ap;

    arch_interrupts_off();
    fbcon_set_color(FBCON_ALERT);
    kputs("\npanic: ");
    va_start(ap, fmt);
    kvprintf(fmt, ap);
    va_end(ap);
    kputc('\n');
    arch_halt();
}
