#include "arch.h"

const char *const arch_name = "aarch64";
const char *const arch_kernel = "BOOTAA64.EFI";
const char *const arch_feature = "ARM64";

/* PL011 UART of the QEMU/UTM "virt" machine. The address is assumed, not
 * read from ACPI yet (ROADMAP.md). */
#define UART_BASE   0x09000000ULL
#define UARTDR      (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UARTFR      (*(volatile uint32_t *)(UART_BASE + 0x18))
#define UARTLCR_H   (*(volatile uint32_t *)(UART_BASE + 0x2c))
#define UARTCR      (*(volatile uint32_t *)(UART_BASE + 0x30))
#define UARTFR_BUSY (1u << 3)
#define UARTFR_RXFE (1u << 4)
#define UARTFR_TXFF (1u << 5)
#define UARTLCR_H_FEN (1u << 4)
#define UARTCR_UARTEN (1u << 0)

/* The firmware has configured the UART (115200 8N1), but with room for one
 * character in each direction. Nothing interrupts for a character yet: the
 * port is looked at a hundred times a second (console.c), and whatever
 * arrives between two looks has to wait in the UART. So its FIFOs are
 * switched on, which the line control register may only be told while the
 * UART is off and has sent what it was sending (PL011 Technical Reference
 * Manual, 3.3.8). */
void arch_early_init(void)
{
    uint32_t control;

    __asm__ volatile("msr daifset, #0xf" ::: "memory");
    control = UARTCR;
    UARTCR = control & ~UARTCR_UARTEN;
    while (UARTFR & UARTFR_BUSY)
        ;
    UARTLCR_H |= UARTLCR_H_FEN;
    UARTCR = control;
}

void arch_serial_putc(char c)
{
    while (UARTFR & UARTFR_TXFF)
        ;
    UARTDR = (uint8_t)c;
}

int arch_serial_getc(void)
{
    return UARTFR & UARTFR_RXFE ? -1 : (int)(UARTDR & 0xff); /* the bits above are error flags */
}

const char *const arch_serial_kind = "PL011";
const uint64_t arch_serial_base = UART_BASE;

/* There are no I/O ports on this architecture: every device is in memory. */
int arch_port_read(uint16_t port, unsigned size, uint32_t *value)
{
    (void)port;
    (void)size;
    (void)value;
    return 0;
}

int arch_port_write(uint16_t port, unsigned size, uint32_t value)
{
    (void)port;
    (void)size;
    (void)value;
    return 0;
}

void arch_map_devices(void)
{
    vm_map(UART_BASE, UART_BASE, 1, VM_WRITE | VM_DEVICE);
}

void arch_halt(void)
{
    __asm__ volatile("msr daifset, #0xf");
    interrupt_quiet();
    for (;;)
        __asm__ volatile("wfi");
}

/* The first argument travels in x0. The frame pointer and the link register
 * are cleared: there is no frame above fn and nowhere for it to return to.
 * The processor has two stack pointers at EL1, and the firmware runs on
 * SP_EL1. The kernel proper takes SP_EL0, selected here, and keeps SP_EL1
 * for its exception handlers (exception.c). */
void arch_switch_stack(void *top, void (*fn)(struct boot_info *), struct boot_info *arg)
{
    register struct boot_info *x0 __asm__("x0") = arg;
    register void *x9 __asm__("x9") = top;
    register void (*x10)(struct boot_info *) __asm__("x10") = fn;

    __asm__ volatile("msr spsel, #0\n"
                     "mov sp, x9\n"
                     "mov x29, xzr\n"
                     "mov x30, xzr\n"
                     "br x10"
                     : : "r"(x0), "r"(x9), "r"(x10));
    __builtin_unreachable();
}
