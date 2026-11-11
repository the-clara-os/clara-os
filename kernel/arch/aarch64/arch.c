#include "kernel.h"

const char *const arch_name = "aarch64";

/* PL011 UART of the QEMU/UTM "virt" machine. Device memory stays reachable
 * after ExitBootServices because we still run on the firmware's page tables.
 * TODO: take the address from the device tree instead of assuming it. */
#define UART_BASE   0x09000000ULL
#define UARTDR      (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UARTFR      (*(volatile uint32_t *)(UART_BASE + 0x18))
#define UARTFR_TXFF (1u << 5)

void arch_early_init(void)
{
    __asm__ volatile("msr daifset, #0xf" ::: "memory");
    /* the firmware already configured the UART (115200 8N1) */
}

void arch_serial_putc(char c)
{
    while (UARTFR & UARTFR_TXFF)
        ;
    UARTDR = (uint8_t)c;
}

void arch_halt(void)
{
    for (;;)
        __asm__ volatile("wfi");
}
