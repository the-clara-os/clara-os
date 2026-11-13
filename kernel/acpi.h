/* ACPI: the firmware's description of the machine. Only the tables ClaraOS
 * reads are laid out here, as the ACPI specification 6.5 gives them in
 * chapter 5. Nothing in a table is aligned, and a table can start at any
 * address, hence "packed" on every structure. */
#pragma once
#include <stdint.h>

#define ACPI_PACKED __attribute__((packed))

struct acpi_rsdp {              /* the root pointer, which UEFI hands over (5.2.5.3) */
    char     signature[8];      /* "RSD PTR " */
    uint8_t  checksum;          /* of the first 20 bytes */
    char     oem_id[6];
    uint8_t  revision;          /* 2 and up have the fields below */
    uint32_t rsdt_address;
    uint32_t length;
    uint64_t xsdt_address;
    uint8_t  extended_checksum; /* of all `length` bytes */
    uint8_t  reserved[3];
} ACPI_PACKED;

struct acpi_header {            /* how every other table begins (5.2.6) */
    char     signature[4];
    uint32_t length;            /* of the whole table, this header included */
    uint8_t  revision;
    uint8_t  checksum;          /* makes the bytes of the table add up to 0 */
    char     oem_id[6];
    char     oem_table_id[8];
    uint32_t oem_revision;
    uint32_t creator_id;
    uint32_t creator_revision;
} ACPI_PACKED;

struct acpi_xsdt {              /* the list of all the other tables (5.2.8) */
    struct acpi_header header;
    uint64_t tables[];          /* their physical addresses */
} ACPI_PACKED;

/* MADT, signature "APIC": the interrupt controllers (5.2.12). After these
 * fields come entries of various types, each starting with its type and
 * its length. */
struct acpi_madt {
    struct acpi_header header;
    uint32_t local_apic_address;
    uint32_t flags;
} ACPI_PACKED;

#define ACPI_MADT_PCAT_COMPAT 1u /* flags: the machine also has two 8259s */

struct acpi_madt_entry {
    uint8_t type;
    uint8_t length;
} ACPI_PACKED;

enum {
    ACPI_MADT_IO_APIC = 1,
    ACPI_MADT_LOCAL_APIC_ADDRESS = 5,
    ACPI_MADT_GICC = 11,
    ACPI_MADT_GICD = 12,
    ACPI_MADT_GICR = 14,
};

struct acpi_madt_io_apic {
    struct acpi_madt_entry entry;
    uint8_t  id;
    uint8_t  reserved;
    uint32_t address;
    uint32_t interrupt_base;    /* the number of its first pin among all interrupts */
} ACPI_PACKED;

struct acpi_madt_local_apic_address { /* replaces the 32-bit address in the MADT itself */
    struct acpi_madt_entry entry;
    uint16_t reserved;
    uint64_t address;
} ACPI_PACKED;

struct acpi_madt_gicc {         /* one per processor: its side of the GIC */
    struct acpi_madt_entry entry;
    uint16_t reserved;
    uint32_t cpu_interface;
    uint32_t processor_uid;
    uint32_t flags;
    uint32_t parking_version;
    uint32_t performance_interrupt;
    uint64_t parked_address;
    uint64_t base;              /* GICv2: the CPU interface's registers */
    uint64_t gicv;
    uint64_t gich;
    uint32_t vgic_interrupt;
    uint64_t redistributor;     /* GICv3: its redistributor, when no GICR entry lists them */
    uint64_t mpidr;             /* the processor's affinity fields, as in MPIDR_EL1 */
} ACPI_PACKED;                  /* more fields follow, which the kernel does not read */

struct acpi_madt_gicd {         /* the GIC's distributor */
    struct acpi_madt_entry entry;
    uint16_t reserved;
    uint32_t id;
    uint64_t base;
    uint32_t vector_base;
    uint8_t  version;           /* 0: not stated, ask the hardware */
    uint8_t  reserved2[3];
} ACPI_PACKED;

struct acpi_madt_gicr {         /* GICv3: a range of memory holding redistributors */
    struct acpi_madt_entry entry;
    uint16_t reserved;
    uint64_t base;
    uint32_t length;
} ACPI_PACKED;

/* GTDT: the Arm generic timer's interrupts (5.2.25). */
struct acpi_gtdt {
    struct acpi_header header;
    uint64_t control_base;
    uint32_t reserved;
    uint32_t secure_el1_interrupt, secure_el1_flags;
    uint32_t el1_interrupt, el1_flags;
    uint32_t virtual_interrupt, virtual_flags;
    uint32_t el2_interrupt, el2_flags;
} ACPI_PACKED;                  /* more fields follow, which the kernel does not read */

/* acpi.c */
void acpi_init(const void *rsdp);              /* check the root tables and list what there is */
const void *acpi_table(const char *signature); /* the first table with this signature, or NULL */
const struct acpi_madt *acpi_madt(void);
/* The MADT's entries, one after another: NULL asks for the first one and
 * is the answer after the last. */
const struct acpi_madt_entry *acpi_madt_next(const struct acpi_madt_entry *entry);
