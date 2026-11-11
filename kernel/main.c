/* Boot handoff. ClaraOS is itself the UEFI application: the firmware loads
 * BOOTX64.EFI or BOOTAA64.EFI, calls efi_main, and we never return. */
#include "efi.h"
#include "kernel.h"

static EFI_SYSTEM_TABLE *g_st;
static struct boot_info g_boot;

/* Memory map snapshot. 32 KiB holds some 680 descriptors; the maps we have
 * seen use a tenth of that. Static, so nothing is allocated this early. */
static __attribute__((aligned(16))) uint8_t g_mmap_buf[32 * 1024];

static void efi_puts(const CHAR16 *s)
{
    g_st->ConOut->OutputString(g_st->ConOut, s);
}

static int guid_eq(const EFI_GUID *a, const EFI_GUID *b)
{
    const uint8_t *x = (const uint8_t *)a, *y = (const uint8_t *)b;
    for (int i = 0; i < 16; i++)
        if (x[i] != y[i])
            return 0;
    return 1;
}

static void find_config_tables(void)
{
    static const EFI_GUID acpi20 = EFI_ACPI_20_TABLE_GUID;
    static const EFI_GUID dtb = EFI_DTB_TABLE_GUID;

    for (UINTN i = 0; i < g_st->NumberOfTableEntries; i++) {
        EFI_CONFIGURATION_TABLE *t = &g_st->ConfigurationTable[i];
        if (guid_eq(&t->VendorGuid, &acpi20))
            g_boot.acpi_rsdp = t->VendorTable;
        else if (guid_eq(&t->VendorGuid, &dtb))
            g_boot.dtb = t->VendorTable;
    }
}

static void find_framebuffer(void)
{
    static const EFI_GUID gop_guid = EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID;
    EFI_GRAPHICS_OUTPUT_PROTOCOL *gop = NULL;

    if (EFI_ERROR(g_st->BootServices->LocateProtocol(&gop_guid, NULL, (void **)&gop)))
        return;
    if (!gop || !gop->Mode || !gop->Mode->Info || gop->Mode->Info->PixelFormat == PixelBltOnly)
        return;
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info = gop->Mode->Info;
    g_boot.fb.pixels = (volatile uint32_t *)(uintptr_t)gop->Mode->FrameBufferBase;
    g_boot.fb.width = info->HorizontalResolution;
    g_boot.fb.height = info->VerticalResolution;
    g_boot.fb.pitch = info->PixelsPerScanLine;
    g_boot.fb.format = info->PixelFormat;
}

/* Snapshot the memory map and take the machine from the firmware. The first
 * ExitBootServices may fail because the map changed under us; the spec
 * allows one retry with a fresh map. */
static EFI_STATUS exit_boot_services(EFI_HANDLE image)
{
    EFI_BOOT_SERVICES *bs = g_st->BootServices;
    UINTN key = 0;
    uint32_t version = 0;

    for (int attempt = 0; attempt < 2; attempt++) {
        UINTN size = sizeof g_mmap_buf;
        EFI_STATUS s = bs->GetMemoryMap(&size, (EFI_MEMORY_DESCRIPTOR *)g_mmap_buf, &key,
                                        &g_boot.desc_size, &version);
        if (EFI_ERROR(s))
            return s;
        g_boot.memory_map = g_mmap_buf;
        g_boot.memory_map_size = size;
        if (!EFI_ERROR(bs->ExitBootServices(image, key)))
            return EFI_SUCCESS;
    }
    return EFI_INVALID_PARAMETER;
}

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
    g_st = st;
    efi_puts(L"ClaraOS: taking the machine from the firmware\r\n");
    find_config_tables();
    find_framebuffer();

    EFI_STATUS s = exit_boot_services(image);
    if (EFI_ERROR(s)) {
        efi_puts(L"ClaraOS: ExitBootServices failed\r\n");
        return s;
    }
    kmain(&g_boot);
}

static const char *const mem_type_names[EfiMaxMemoryType] = {
    "reserved",      "loader code",  "loader data",  "boot services code",
    "boot services data", "runtime code", "runtime data", "conventional",
    "unusable",      "ACPI reclaim", "ACPI NVS",     "MMIO",
    "MMIO port space", "PAL code",   "persistent",
};

static void report_memory(const struct boot_info *bi)
{
    uint64_t usable = 0, top = 0;
    unsigned n = 0;

    kprintf("memory map (%u-byte descriptors):\n", (unsigned)bi->desc_size);
    for (uint64_t off = 0; off + bi->desc_size <= bi->memory_map_size; off += bi->desc_size, n++) {
        const EFI_MEMORY_DESCRIPTOR *d = (const void *)((const uint8_t *)bi->memory_map + off);
        uint64_t bytes = d->NumberOfPages << 12;
        uint64_t end = d->PhysicalStart + bytes;
        const char *name = d->Type < EfiMaxMemoryType ? mem_type_names[d->Type] : "?";

        kprintf("  %012lx-%012lx %6lu KiB  %s\n", d->PhysicalStart, end - 1, bytes >> 10, name);
        switch (d->Type) {
        case EfiConventionalMemory:
        case EfiBootServicesCode:
        case EfiBootServicesData:
            usable += bytes;
            /* fallthrough */
        case EfiLoaderCode:
        case EfiLoaderData:
        case EfiRuntimeServicesCode:
        case EfiRuntimeServicesData:
        case EfiACPIReclaimMemory:
        case EfiACPIMemoryNVS:
            if (end > top)
                top = end;
            break;
        }
    }
    kprintf("%u regions, %lu MiB usable RAM, highest RAM address %lx\n", n, usable >> 20, top);
}

void kmain(struct boot_info *bi)
{
    arch_early_init();
    kprintf("\nClaraOS %s on %s: the machine is ours\n", CLARA_VERSION, arch_name);
    report_memory(bi);
    kprintf("ACPI RSDP %p, device tree %p\n", bi->acpi_rsdp, bi->dtb);

    if (bi->fb.pixels) {
        kprintf("framebuffer %ux%u, pitch %u, format %u, at %p\n", bi->fb.width, bi->fb.height,
                bi->fb.pitch, bi->fb.format, (void *)bi->fb.pixels);
        fb_fill(&bi->fb, 0, bi->fb.height, 0x1e, 0x1b, 0x2e);
        fb_fill(&bi->fb, bi->fb.height / 2 - 8, bi->fb.height / 2 + 8, 0xff, 0x79, 0xc6);
    } else {
        kprintf("framebuffer: none\n");
    }
    kprintf("clara: nothing more to do, halting\n");
    arch_halt();
}
