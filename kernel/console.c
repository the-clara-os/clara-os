#include "kernel.h"

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
 * display, to the screen as well. */
static void put_char(char c)
{
    if (c == '\n')
        arch_serial_putc('\r');
    arch_serial_putc(c);
    if (!g_serial_only)
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
