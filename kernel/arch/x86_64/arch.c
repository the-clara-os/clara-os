#include "arch.h"

const char *const arch_name = "x86_64";

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

/* The serial port is reached through I/O ports and needs no mapping. */
void arch_map_devices(void)
{
}

void arch_halt(void)
{
    for (;;)
        __asm__ volatile("cli; hlt");
}

/* This target follows the Microsoft x64 calling convention: the first
 * argument in rcx, the stack 16-byte aligned at the call, and 32 bytes of
 * home space for the callee above its return address. The registers are
 * named so that none of the operands lands in rbp, which is cleared to end
 * the chain of frames. */
void arch_switch_stack(void *top, void (*fn)(struct boot_info *), struct boot_info *arg)
{
    __asm__ volatile("mov %%rax, %%rsp\n"
                     "sub $32, %%rsp\n"
                     "xor %%ebp, %%ebp\n"
                     "call *%%rdx\n"
                     "ud2"
                     : : "a"(top), "d"(fn), "c"(arg));
    __builtin_unreachable();
}
