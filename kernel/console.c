#include "kernel.h"

void kputc(char c)
{
    if (c == '\n')
        arch_serial_putc('\r');
    arch_serial_putc(c);
}

void kputs(const char *s)
{
    while (*s)
        kputc(*s++);
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
        kputc(buf[i]);
}

void kvprintf(const char *fmt, va_list ap)
{
    for (; *fmt; fmt++) {
        if (*fmt != '%') {
            kputc(*fmt);
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
            kputc((char)va_arg(ap, int));
            break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            kputs(s ? s : "(null)");
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
            kputs("0x");
            put_num((uint64_t)(uintptr_t)va_arg(ap, void *), 16, 16, '0', 0, 0);
            break;
        case '%':
            kputc('%');
            break;
        case 0:
            return;
        default:
            kputc('%');
            kputc(*fmt);
            break;
        }
    }
}

void kprintf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    kvprintf(fmt, ap);
    va_end(ap);
}

static uint32_t fb_pixel(const struct framebuffer *fb, uint8_t r, uint8_t g, uint8_t b)
{
    if (fb->format == 0) /* RGBx */
        return (uint32_t)r | (uint32_t)g << 8 | (uint32_t)b << 16;
    return (uint32_t)b | (uint32_t)g << 8 | (uint32_t)r << 16; /* BGRx: QEMU and UTM */
}

/* Paint scanlines [y0, y1) a solid colour. */
void fb_fill(const struct framebuffer *fb, uint32_t y0, uint32_t y1,
             uint8_t r, uint8_t g, uint8_t b)
{
    if (!fb->pixels)
        return;
    uint32_t px = fb_pixel(fb, r, g, b);
    if (y1 > fb->height)
        y1 = fb->height;
    for (uint32_t y = y0; y < y1; y++) {
        volatile uint32_t *row = fb->pixels + (uint64_t)y * fb->pitch;
        for (uint32_t x = 0; x < fb->width; x++)
            row[x] = px;
    }
}
