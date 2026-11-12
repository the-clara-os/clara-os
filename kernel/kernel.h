/* Kernel-wide interfaces. Note: our targets are LLP64 (long is 32 bits), so
 * the kernel never uses long; it uses the <stdint.h> types. */
#pragma once
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#define CLARA_VERSION "0.0.1"

struct framebuffer {
    volatile uint32_t *pixels; /* 32 bits per pixel; NULL when there is no display */
    uint32_t width, height;    /* in pixels */
    uint32_t pitch;            /* pixels per scanline, >= width */
    uint32_t red_mask, green_mask, blue_mask; /* the bits of a pixel that hold each colour */
};

/* What the boot handoff learned from the firmware before taking the machine. */
struct boot_info {
    struct framebuffer fb;
    void    *memory_map;       /* EFI memory map; descriptors are desc_size bytes apart */
    uint64_t memory_map_size;
    uint64_t desc_size;
    void    *acpi_rsdp;        /* ACPI 2.0 root pointer, or NULL */
    void    *dtb;              /* flattened device tree, or NULL */
};

/* console.c: text goes to the serial port and, after fbcon_init, to the
 * screen. %d %u %x %X %s %c %p and %% are supported, with zero padding and
 * width. The compiler checks the arguments: 64-bit ones are %llu, %llx. */
void kputc(char c);
void kputs(const char *s);
void kprintf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void kvprintf(const char *fmt, va_list ap) __attribute__((format(printf, 1, 0)));
void panic(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));

/* fbcon.c: the text console on the framebuffer */
enum fbcon_color { FBCON_TEXT, FBCON_ACCENT, FBCON_ALERT, FBCON_COLORS };
void fbcon_init(const struct framebuffer *fb);
void fbcon_putc(char c);
void fbcon_set_color(enum fbcon_color color);

/* font.c, generated from fonts/spleen-8x16.bdf by tools/bdf2c.py */
#define FONT_WIDTH  8
#define FONT_HEIGHT 16
const uint8_t *font_glyph(char c); /* FONT_HEIGHT bytes, one per scanline, leftmost pixel in bit 7 */

/* string.c */
void  *memset(void *dst, int c, size_t n);
void  *memcpy(void *dst, const void *src, size_t n);
size_t strlen(const char *s);

/* arch/<arch>/arch.c */
extern const char *const arch_name;
void arch_early_init(void);   /* right after ExitBootServices: interrupts off, serial ready */
void arch_serial_putc(char c);
void arch_halt(void) __attribute__((noreturn));

/* main.c */
void kmain(struct boot_info *bi) __attribute__((noreturn));
