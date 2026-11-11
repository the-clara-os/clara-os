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
    uint32_t format;           /* enum efi_pixel_format: 0 RGBx, 1 BGRx */
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

/* console.c: text goes to the serial port for now. %d %u %x %X %s %c %p and
 * %% are supported, with zero padding and width; l/ll/z all mean 64 bits. */
void kputc(char c);
void kputs(const char *s);
void kprintf(const char *fmt, ...);
void kvprintf(const char *fmt, va_list ap);
void fb_fill(const struct framebuffer *fb, uint32_t y0, uint32_t y1,
             uint8_t r, uint8_t g, uint8_t b);

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
