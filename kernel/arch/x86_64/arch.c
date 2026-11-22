#include "arch.h"

const char *const arch_name = "x86_64";
const char *const arch_kernel = "BOOTX64.EFI";
const char *const arch_feature = "X86-64";

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

int arch_serial_getc(void)
{
    return inb(COM1 + 5) & 0x01 ? inb(COM1) : -1; /* data ready */
}

const char *const arch_serial_kind = "NS16550";
const uint64_t arch_serial_base = COM1;

/* OVMF, the firmware of these machines under QEMU, looks into the page frame
 * at 0x812000 whenever a machine starts: a loader of another kind (IGVM)
 * would have left a map of the memory there and a count of the processors,
 * and where the first words pass for such a map the firmware lays the
 * machine out by them, and not by what QEMU says of it. RAM keeps what it
 * holds when a machine is started again, and as EDK2 was between its
 * commits 5e8db785e4 and e4f99a8554, which is the release of November 2025
 * and so the OVMF that Ubuntu 26.04 has, the firmware's map gives that
 * frame to the system as free memory. With words of the Lisp heap in it,
 * the next start put the 64-bit window of the PCI bus at an address that
 * the processor does not have, and the firmware went round looking for it
 * for good: a machine that was told to start again and never came back.
 * Later firmware keeps the frame to itself, and its map says so. (EDK2:
 * OvmfPkg/Library/PlatformInitLib/Igvm.c, and for the address
 * OvmfPkg/Include/Fdf/MemFd.fdf.inc: 0x12000 above the 8 MiB where that
 * firmware keeps what it needs first.) */
const uint64_t arch_kept_frame = 0x812000;

int arch_port_read(uint16_t port, unsigned size, uint32_t *value)
{
    uint16_t word;

    switch (size) {
    case 1:
        *value = inb(port);
        break;
    case 2:
        __asm__ volatile("inw %1, %0" : "=a"(word) : "Nd"(port));
        *value = word;
        break;
    default:
        __asm__ volatile("inl %1, %0" : "=a"(*value) : "Nd"(port));
    }
    return 1;
}

int arch_port_write(uint16_t port, unsigned size, uint32_t value)
{
    switch (size) {
    case 1:
        outb(port, (uint8_t)value);
        break;
    case 2:
        __asm__ volatile("outw %0, %1" : : "a"((uint16_t)value), "Nd"(port));
        break;
    default:
        __asm__ volatile("outl %0, %1" : : "a"(value), "Nd"(port));
    }
    return 1;
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
