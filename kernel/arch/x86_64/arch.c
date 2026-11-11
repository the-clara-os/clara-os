#include "kernel.h"

const char *const arch_name = "x86_64";

static inline void outb(uint16_t port, uint8_t v)
{
    __asm__ volatile("outb %0, %1" : : "a"(v), "Nd"(port));
}

static inline uint8_t inb(uint16_t port)
{
    uint8_t v;
    __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
    return v;
}

#define COM1 0x3f8

void arch_early_init(void)
{
    __asm__ volatile("cli");
    outb(COM1 + 1, 0x00); /* no interrupts */
    outb(COM1 + 3, 0x80); /* DLAB on */
    outb(COM1 + 0, 0x01); /* divisor 1: 115200 baud */
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03); /* 8N1, DLAB off */
    outb(COM1 + 2, 0xc7); /* FIFO on and cleared, 14-byte threshold */
    outb(COM1 + 4, 0x0b); /* DTR, RTS, OUT2 */
}

void arch_serial_putc(char c)
{
    while (!(inb(COM1 + 5) & 0x20)) /* transmitter holding register empty */
        ;
    outb(COM1, (uint8_t)c);
}

void arch_halt(void)
{
    for (;;)
        __asm__ volatile("cli; hlt");
}
