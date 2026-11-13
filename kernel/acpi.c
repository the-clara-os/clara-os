/* ACPI tables: finding them. UEFI hands over the address of the root
 * pointer, the root pointer leads to the XSDT, and the XSDT lists every
 * other table by address. The tables lie in memory the firmware marked as
 * ACPI's, which vm.c maps along with the rest of RAM. */
#include "acpi.h"
#include "kernel.h"

static const struct acpi_xsdt *g_xsdt;
static const struct acpi_madt *g_madt;
static uint64_t g_tables;

static int adds_up(const void *table, uint64_t length)
{
    const uint8_t *p = table;
    uint8_t sum = 0;

    while (length--)
        sum += *p++;
    return sum == 0;
}

static const struct acpi_header *table_at(uint64_t i)
{
    return phys_ptr(g_xsdt->tables[i]);
}

void acpi_init(const void *pointer)
{
    const struct acpi_rsdp *rsdp = pointer;

    if (!rsdp)
        panic("the firmware has no ACPI tables, and nothing else describes the machine");
    if (memcmp(rsdp->signature, "RSD PTR ", 8) || !adds_up(rsdp, 20) || rsdp->revision < 2 ||
        !adds_up(rsdp, rsdp->length))
        panic("the ACPI root pointer at %p is damaged", pointer);
    g_xsdt = phys_ptr(rsdp->xsdt_address);
    if (memcmp(g_xsdt->header.signature, "XSDT", 4) || !adds_up(g_xsdt, g_xsdt->header.length))
        panic("the ACPI table list at %p is damaged", (const void *)g_xsdt);
    g_tables = (g_xsdt->header.length - sizeof g_xsdt->header) / sizeof g_xsdt->tables[0];

    kprintf("ACPI tables:");
    for (uint64_t i = 0; i < g_tables; i++)
        kprintf(" %c%c%c%c", table_at(i)->signature[0], table_at(i)->signature[1],
                table_at(i)->signature[2], table_at(i)->signature[3]);
    kputc('\n');

    g_madt = acpi_table("APIC");
    if (!g_madt)
        panic("ACPI has no MADT, the table that says where the interrupt controller is");
}

const void *acpi_table(const char *signature)
{
    for (uint64_t i = 0; i < g_tables; i++) {
        const struct acpi_header *t = table_at(i);

        if (memcmp(t->signature, signature, 4))
            continue;
        if (!adds_up(t, t->length))
            panic("the ACPI table %s at %p is damaged", signature, (const void *)t);
        return t;
    }
    return NULL;
}

const struct acpi_madt *acpi_madt(void)
{
    return g_madt;
}

const struct acpi_madt_entry *acpi_madt_next(const struct acpi_madt_entry *entry)
{
    const uint8_t *end = (const uint8_t *)g_madt + g_madt->header.length;
    const uint8_t *next = entry ? (const uint8_t *)entry + entry->length : (const uint8_t *)(g_madt + 1);
    const struct acpi_madt_entry *e = (const void *)next;

    /* An entry shorter than its own first two fields would never end the walk. */
    if (next + sizeof *e > end || e->length < sizeof *e || next + e->length > end)
        return NULL;
    return e;
}
