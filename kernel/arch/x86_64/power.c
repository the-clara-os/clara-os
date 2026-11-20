/* x86_64: turning the machine off, starting it again, and its power button.
 *
 * A PC does all three through the fixed hardware of ACPI, a few I/O ports
 * that the FADT names (ACPI 6.5, 4.8.4):
 *
 *   off      the type of the sleep state S5 and the bit "sleep now",
 *            written to the PM1 control register. The type is a number
 *            that the machine's maker chose, and it stands in the DSDT.
 *   again    a value written to the reset register, both from the FADT;
 *            and where there is none, the keyboard controller's line to
 *            the processor's reset pin, which every PC has had since the
 *            AT.
 *   button   a bit in the PM1 status register, once the same bit of the
 *            enable register says that the system wants to know. It would
 *            also raise ACPI's interrupt, which comes by a line and so
 *            never arrives here (interrupt.c): the bit is looked at, a few
 *            times a second, by whoever asks arch_power_button. */
#include "acpi.h"
#include "arch.h"

static uint16_t g_events;  /* the port of the PM1 status register, or 0: the enable register is g_enable further on */
static uint16_t g_enable;
static uint16_t g_control; /* the port of the PM1 control register, or 0 */
static int g_sleep = -1;   /* the type of S5, or -1 when the DSDT does not say */
static uint16_t g_reset;   /* the port of the reset register, or 0, */
static uint8_t g_reset_value;

static uint16_t inw(uint16_t port)
{
    uint32_t value;

    arch_port_read(port, 2, &value);
    return (uint16_t)value;
}

static void outw(uint16_t port, uint16_t value)
{
    arch_port_write(port, 2, value);
}

void arch_power_init(void)
{
    const struct acpi_fadt *fadt = acpi_fadt();
    uint8_t type;

    if (!fadt) {
        kprintf("power: ACPI has no table of fixed hardware: the machine is turned off and started from outside\n");
        return;
    }
    /* The firmware may have kept power management to itself: it hands it
     * over when it is told to, by a value at a port, and says in the
     * control register when it has (4.8.2.5). */
    if (fadt->pm1a_control && fadt->smi_command && fadt->acpi_enable &&
        !(inw((uint16_t)fadt->pm1a_control) & ACPI_PM1_SCI_ENABLE)) {
        outb((uint16_t)fadt->smi_command, fadt->acpi_enable);
        for (unsigned i = 0; i < 1000000 && !(inw((uint16_t)fadt->pm1a_control) & ACPI_PM1_SCI_ENABLE); i++)
            ;
    }
    g_control = (uint16_t)fadt->pm1a_control;
    if (acpi_sleep_type("_S5_", &type))
        g_sleep = type & 7;
    if ((fadt->flags & ACPI_FADT_RESET_REGISTER) && fadt->reset.space == ACPI_SPACE_PORT && fadt->reset.address &&
        fadt->reset.address <= 0xffff) {
        g_reset = (uint16_t)fadt->reset.address;
        g_reset_value = fadt->reset_value;
    }
    if (fadt->pm1a_event && fadt->pm1_event_length >= 4) {
        g_events = (uint16_t)fadt->pm1a_event;
        g_enable = (uint16_t)(g_events + fadt->pm1_event_length / 2);
        outw(g_events, ACPI_PM1_POWER_BUTTON); /* a bit of the status register is cleared by writing it */
        outw(g_enable, inw(g_enable) | ACPI_PM1_POWER_BUTTON);
    }

    kprintf("power: ");
    if (g_control && g_sleep >= 0)
        kprintf("off by ACPI's sleep state S5, type %d at port %x", g_sleep, g_control);
    else
        kprintf("ACPI does not say how the machine is turned off");
    if (g_reset)
        kprintf("; again by %x at port %x", g_reset_value, g_reset);
    else
        kprintf("; again by the keyboard controller");
    if (g_events)
        kprintf("; the power button at port %x\n", g_events);
    else
        kprintf("; no power button\n");
}

/* A machine takes a moment over either, and one that is still here after
 * that is not going to do it: both return then, and only then. */
void arch_power_off(void)
{
    if (!g_control || g_sleep < 0)
        return;
    outw(g_control, (uint16_t)(g_sleep << 10) | ACPI_PM1_SLEEP_ENABLE);
    thread_sleep(2 * TIMER_HZ);
}

void arch_restart(void)
{
    if (g_reset) {
        outb(g_reset, g_reset_value);
        thread_sleep(TIMER_HZ);
    }
    /* The keyboard controller: when it has taken what it was sent before,
     * the command 0xfe pulses the line to the processor's reset pin. */
    for (unsigned i = 0; i < 100000 && (inb(0x64) & 2); i++)
        ;
    outb(0x64, 0xfe);
    thread_sleep(2 * TIMER_HZ);
}

int arch_power_button(void)
{
    if (!g_events)
        return -1;
    if (!(inw(g_events) & ACPI_PM1_POWER_BUTTON))
        return 0;
    outw(g_events, ACPI_PM1_POWER_BUTTON);
    return 1;
}
