/* AArch64: turning the machine off, starting it again, and its power button.
 *
 * Off and again are calls to whatever runs above the kernel, the firmware
 * at a higher exception level or a hypervisor: PSCI, the Power State
 * Coordination Interface (Arm DEN 0022). A call is a function's number in
 * x0 and one instruction, SMC or HVC, and the FADT says whether the
 * machine has PSCI and which of the two instructions reaches it.
 *
 * The power button of a machine without the fixed hardware of a PC is an
 * event of its generic event device (ACPI 6.5, 5.6.9), "ACPI0013" in the
 * DSDT: a register that says which events are pending, and an interrupt
 * that says some are. The interrupt comes by a line, whose number is in
 * the DSDT's bytecode, so it is not waited for: the register is looked at,
 * a few times a second, by whoever asks arch_power_button. QEMU's is one
 * word, read once and cleared by the reading, with the button in its bit 1
 * (hw/acpi/generic_event_device.c: ACPI_GED_PWR_DOWN_EVT). */
#include "acpi.h"
#include "arch.h"

#define PSCI_VERSION      0x84000000u
#define PSCI_SYSTEM_OFF   0x84000008u
#define PSCI_SYSTEM_RESET 0x84000009u

#define EVENT_POWER_DOWN 2u

enum { NONE, BY_SMC, BY_HVC };

static int g_psci;
static volatile uint32_t *g_events; /* the generic event device's register, or NULL */

/* The caller's registers x0 to x3 hold the arguments and come back with
 * the results, and x4 to x17 are whatever the other side left in them
 * (Arm DEN 0028, the SMC calling convention). */
static uint64_t psci(uint32_t function)
{
    register uint64_t x0 __asm__("x0") = function;
    register uint64_t x1 __asm__("x1") = 0;
    register uint64_t x2 __asm__("x2") = 0;
    register uint64_t x3 __asm__("x3") = 0;

    if (g_psci == BY_HVC)
        __asm__ volatile("hvc #0" : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3) : :
                         "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17",
                         "memory");
    else
        __asm__ volatile("smc #0" : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3) : :
                         "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17",
                         "memory");
    return x0;
}

void arch_power_init(void)
{
    const struct acpi_fadt *fadt = acpi_fadt();
    uint64_t events;

    if (fadt && (fadt->arm_boot_flags & ACPI_FADT_ARM_PSCI))
        g_psci = fadt->arm_boot_flags & ACPI_FADT_ARM_PSCI_HVC ? BY_HVC : BY_SMC;
    if (acpi_device_memory("ACPI0013", &events) && events >= LOW_LIMIT && !(events & 3) && !pmm_is_ram(events)) {
        vm_map(events & ~(PAGE_SIZE - 1), events & ~(PAGE_SIZE - 1), 1, VM_WRITE | VM_DEVICE);
        g_events = (volatile uint32_t *)(uintptr_t)events;
        (void)*g_events; /* whatever was pending before anybody listened is not a request to this system */
    }

    kprintf("power: ");
    if (g_psci) {
        uint64_t version = psci(PSCI_VERSION);

        kprintf("off and again by PSCI %llu.%llu, called by %s", version >> 16 & 0x7fff, version & 0xffff,
                g_psci == BY_HVC ? "HVC" : "SMC");
    } else
        kprintf("the machine has no PSCI, and is turned off and started from outside");
    if (g_events)
        kprintf("; the power button in the events at %p\n", (void *)(uintptr_t)events);
    else
        kprintf("; no power button\n");
}

/* A machine takes a moment over either, and one that is still here after
 * that is not going to do it: both return then, and only then. */
void arch_power_off(void)
{
    if (!g_psci)
        return;
    psci(PSCI_SYSTEM_OFF);
    thread_sleep(2 * TIMER_HZ);
}

void arch_restart(void)
{
    if (!g_psci)
        return;
    psci(PSCI_SYSTEM_RESET);
    thread_sleep(2 * TIMER_HZ);
}

int arch_power_button(void)
{
    if (!g_events)
        return -1;
    return (*g_events & EVENT_POWER_DOWN) != 0;
}
