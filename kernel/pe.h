/* The layout of a PE/COFF image (Microsoft, "PE Format"): the parts the kernel
 * reads of itself. The firmware loads the headers along with the sections,
 * so they are in memory at the image base. */
#pragma once
#include <stdint.h>

#define PE_DOS_MAGIC 0x5a4d     /* "MZ" */
#define PE_SIGNATURE 0x00004550 /* "PE\0\0" */

struct pe_dos_header {
    uint16_t e_magic;
    uint8_t  unused[58];
    uint32_t e_lfanew;          /* at 0x3c: the offset of struct pe_header */
};

struct pe_header {              /* the signature, then the COFF file header */
    uint32_t signature;
    uint16_t machine;
    uint16_t sections;
    uint32_t timestamp;
    uint32_t symbol_table, symbols;
    uint16_t optional_header_size; /* the section table follows the optional header */
    uint16_t characteristics;
};

struct pe_section {
    char     name[8];           /* not terminated when all eight are used */
    uint32_t virtual_size;
    uint32_t virtual_address;   /* relative to the image base */
    uint32_t raw_size, raw_pointer;
    uint32_t relocations, line_numbers;
    uint16_t relocation_count, line_number_count;
    uint32_t characteristics;
};

#define PE_SECTION_EXECUTE 0x20000000u
#define PE_SECTION_WRITE   0x80000000u
