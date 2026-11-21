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

_Static_assert(offsetof(struct acpi_fadt, flags) == 112 && offsetof(struct acpi_fadt, reset) == 116 &&
                   offsetof(struct acpi_fadt, x_dsdt) == 140,
               "struct acpi_fadt is not laid out as the specification has the table");

/* The table of fixed hardware, when it is as long as the fields that are
 * read of it: the oldest kind ends before the reset register. */
const struct acpi_fadt *acpi_fadt(void)
{
    const struct acpi_fadt *fadt = acpi_table("FACP");

    return fadt && fadt->header.length >= sizeof *fadt ? fadt : NULL;
}

/* The DSDT describes the machine in AML, a bytecode with names, methods
 * and control flow, which takes an interpreter to read in general and has
 * none here (DESIGN.md, Devices). Two things that power management needs
 * are in it and nowhere else, and each is written there in a form that
 * can be found without running anything: a name and a constant after it.
 * So the table is searched for those bytes. What the search does not find
 * is said to be not there, and the machine then does without. */
static const uint8_t *dsdt(uint64_t *length)
{
    const struct acpi_fadt *fadt = acpi_fadt();
    const struct acpi_header *table;

    if (!fadt || (!fadt->x_dsdt && !fadt->dsdt))
        return NULL;
    table = phys_ptr(fadt->x_dsdt ? fadt->x_dsdt : fadt->dsdt);
    if (memcmp(table->signature, "DSDT", 4) || table->length < sizeof *table || !adds_up(table, table->length))
        return NULL;
    *length = table->length;
    return (const uint8_t *)table;
}

/* A sleep state is a name with a package of numbers behind it, of which
 * the first is the type to write to the control register (7.4.2): the
 * byte 0x08 for a name, perhaps a backslash, the four characters, 0x12
 * for a package, how long the package is in one to four bytes, of which
 * the first says in its two highest bits how many follow, how many
 * elements it has, and the elements, each a byte that is 0 or 1 or a 0x0a
 * and then the byte (20.2: NameOp, PackageOp, PkgLength, ZeroOp, OneOp,
 * BytePrefix). */
int acpi_sleep_type(const char *name, uint8_t *type)
{
    uint64_t length = 0;
    const uint8_t *aml = dsdt(&length);

    for (uint64_t i = sizeof(struct acpi_header) + 2; aml && i + 4 < length; i++) {
        uint64_t at = i + 4;

        if (memcmp(aml + i, name, 4) || !(aml[i - 1] == 0x08 || (aml[i - 1] == '\\' && aml[i - 2] == 0x08)))
            continue;
        if (at + 2 >= length || aml[at] != 0x12)
            continue;
        at += 2 + (aml[at + 1] >> 6); /* past 0x12 and the bytes of the package's length, */
        at += 1;                      /* and past how many elements it has */
        if (at < length && aml[at] == 0x0a)
            at++;
        if (at >= length)
            return 0;
        *type = aml[at];
        return 1;
    }
    return 0;
}

/* A device says what it is by a name, _HID, with a string behind it, and
 * says where its registers are by an operation region: 0x5b 0x80, the
 * region's name of four characters, a byte for the kind of address, 0 for
 * memory, and the address as a constant, 0x0c before 32 bits of it or
 * 0x0e before 64 (20.2: ExtOpPrefix, OpRegionOp, DWordPrefix,
 * QWordPrefix). The first such region after the string is the device's,
 * when it comes before the next device has said what it is. */
int acpi_device_memory(const char *identity, uint64_t *address)
{
    uint64_t length = 0, n = strlen(identity);
    const uint8_t *aml = dsdt(&length);

    for (uint64_t i = sizeof(struct acpi_header); aml && i + n < length; i++) {
        if (memcmp(aml + i, identity, n))
            continue;
        for (uint64_t at = i + n; at + 16 < length; at++) {
            if (!memcmp(aml + at, "_HID", 4))
                break;
            if (aml[at] != 0x5b || aml[at + 1] != 0x80 || aml[at + 6] != 0)
                continue;
            if (aml[at + 7] == 0x0c) {
                uint32_t value;

                memcpy(&value, aml + at + 8, sizeof value);
                *address = value;
                return 1;
            }
            if (aml[at + 7] == 0x0e) {
                memcpy(address, aml + at + 8, sizeof *address);
                return 1;
            }
        }
    }
    return 0;
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
