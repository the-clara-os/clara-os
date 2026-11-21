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
    ACPI_MADT_GIC_MSI_FRAME = 13,
    ACPI_MADT_GICR = 14,
    ACPI_MADT_GIC_ITS = 15,
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

/* The two ways a GIC takes an interrupt that a device raises by writing to
 * memory: a frame of registers that turns the write into one of a range of
 * shared interrupts (GICv2m), or an interrupt translation service (GICv3). */
struct acpi_madt_gic_msi_frame {
    struct acpi_madt_entry entry;
    uint16_t reserved;
    uint32_t id;
    uint64_t base;
    uint32_t flags;             /* bit 0: the range is in the two fields below, not in the frame's own register */
    uint16_t spi_count;
    uint16_t spi_base;
} ACPI_PACKED;

struct acpi_madt_gic_its {
    struct acpi_madt_entry entry;
    uint16_t reserved;
    uint32_t id;
    uint64_t base;
    uint32_t reserved2;
} ACPI_PACKED;

/* MCFG: where the configuration space of the PCI devices is in memory (PCI
 * Firmware Specification 3.3, 4.1.2). One entry for each range of buses:
 * 4 KiB for every function, 8 functions to a device, 32 devices to a bus. */
struct acpi_mcfg_entry {
    uint64_t base;              /* where bus 0 of the segment would be, whichever bus the range begins with */
    uint16_t segment;
    uint8_t  first_bus, last_bus;
    uint32_t reserved;
} ACPI_PACKED;

struct acpi_mcfg {
    struct acpi_header header;
    uint64_t reserved;
    struct acpi_mcfg_entry entries[];
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

/* A register, wherever it is: in memory, or behind an I/O port (5.2.3.2). */
struct acpi_address {
    uint8_t  space;             /* 0: memory, 1: an I/O port */
    uint8_t  bit_width, bit_offset, access_size;
    uint64_t address;
} ACPI_PACKED;

#define ACPI_SPACE_MEMORY 0
#define ACPI_SPACE_PORT   1

/* FADT, signature "FACP": the fixed hardware of power management (5.2.9).
 * The kernel reads what it needs to turn the machine off, to start it
 * again and to hear its power button, and passes over the rest. */
struct acpi_fadt {
    struct acpi_header header;
    uint32_t firmware_control;
    uint32_t dsdt;              /* where the DSDT is, in 32 bits: x_dsdt replaces it when that is not 0 */
    uint8_t  reserved, profile;
    uint16_t sci_interrupt;
    uint32_t smi_command;       /* the port that puts the machine's power management into the system's hands, */
    uint8_t  acpi_enable;       /*   by this value written to it: both 0 when it is there already */
    uint8_t  acpi_disable, s4bios_request, pstate_control;
    uint32_t pm1a_event;        /* ports: the status and enable registers of the fixed events, */
    uint32_t pm1b_event;
    uint32_t pm1a_control;      /*   and the register that puts the machine to sleep */
    uint32_t pm1b_control;
    uint32_t pm2_control, pm_timer, gpe0, gpe1;
    uint8_t  pm1_event_length;  /* in bytes: the status register is the first half, the enable register the second */
    uint8_t  pm1_control_length;
    uint8_t  other_lengths[6];
    uint8_t  unused[13];        /* latencies, flush sizes, the duty cycle, the alarms and the century */
    uint16_t pc_boot_flags;
    uint8_t  reserved2;
    uint32_t flags;
    struct acpi_address reset;  /* writing reset_value there starts the machine again */
    uint8_t  reset_value;
    uint16_t arm_boot_flags;
    uint8_t  minor_version;
    uint64_t x_firmware_control;
    uint64_t x_dsdt;
} ACPI_PACKED;                  /* more fields follow, which the kernel does not read */

#define ACPI_FADT_RESET_REGISTER (1u << 10) /* flags: the reset register is there */
#define ACPI_FADT_ARM_PSCI       (1u << 0)  /* arm_boot_flags: the machine has PSCI, */
#define ACPI_FADT_ARM_PSCI_HVC   (1u << 1)  /*   and it is called by HVC, not by SMC */

#define ACPI_PM1_POWER_BUTTON (1u << 8)     /* in the status and the enable register of the fixed events (4.8.4.1) */
#define ACPI_PM1_SCI_ENABLE   (1u << 0)     /* in the control register: power management is the system's (4.8.4.2) */
#define ACPI_PM1_SLEEP_ENABLE (1u << 13)    /*   and: go to the sleep state whose type is in the bits from 10 on */

/* acpi.c */
void acpi_init(const void *rsdp);              /* check the root tables and list what there is */
const void *acpi_table(const char *signature); /* the first table with this signature, or NULL */
const struct acpi_fadt *acpi_fadt(void);       /* or NULL */
/* Two facts from the DSDT, which is written in a bytecode that the kernel
 * does not interpret (acpi.c says how they are read all the same): the
 * type of a sleep state, by its name of four characters, "_S5_" for off;
 * and where the registers of the device with a hardware identity are in
 * memory. Each says 0 when the DSDT does not say. */
int acpi_sleep_type(const char *name, uint8_t *type);
int acpi_device_memory(const char *identity, uint64_t *address);
const struct acpi_madt *acpi_madt(void);
/* The MADT's entries, one after another: NULL asks for the first one and
 * is the answer after the last. */
const struct acpi_madt_entry *acpi_madt_next(const struct acpi_madt_entry *entry);
