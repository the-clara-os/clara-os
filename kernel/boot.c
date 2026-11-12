/* Boot handoff. ClaraOS is itself the UEFI application: the firmware loads
 * BOOTX64.EFI or BOOTAA64.EFI and calls efi_main. Everything the kernel wants
 * from the firmware is collected here, while boot services still exist: the
 * ACPI tables, the framebuffer, the files in the boot volume's \clara
 * directory and, last, the memory map. Then the machine is ours, and kmain
 * starts on the kernel's own stack. */
#include "efi.h"
#include "kernel.h"

#define BOOT_DIR L"\\clara"

static EFI_SYSTEM_TABLE *g_st;
static struct boot_info g_boot;

__attribute__((aligned(16))) uint8_t kernel_stack[KERNEL_STACK_SIZE];

static void efi_puts(const CHAR16 *s)
{
    g_st->ConOut->OutputString(g_st->ConOut, s);
}

/* Whole pages from the firmware, typed as loader data: the memory map will
 * list them as ours, and they stay ours after the handoff. */
static void *efi_alloc(uint64_t bytes)
{
    EFI_PHYSICAL_ADDRESS addr = 0;
    UINTN pages = (bytes + PAGE_SIZE - 1) >> PAGE_SHIFT; /* UEFI pages are 4 KiB as well */

    if (EFI_ERROR(g_st->BootServices->AllocatePages(AllocateAnyPages, EfiLoaderData, pages, &addr)))
        return NULL;
    return (void *)(uintptr_t)addr;
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
    if (!gop || !gop->Mode || !gop->Mode->Info)
        return;
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info = gop->Mode->Info;
    struct framebuffer *fb = &g_boot.fb;

    /* Every GOP framebuffer has 32-bit pixels. The formats differ in which
     * bits hold which colour. */
    switch (info->PixelFormat) {
    case PixelRedGreenBlueReserved8BitPerColor:
        fb->red_mask = 0x0000ff;
        fb->green_mask = 0x00ff00;
        fb->blue_mask = 0xff0000;
        break;
    case PixelBlueGreenRedReserved8BitPerColor: /* QEMU and UTM */
        fb->red_mask = 0xff0000;
        fb->green_mask = 0x00ff00;
        fb->blue_mask = 0x0000ff;
        break;
    case PixelBitMask:
        fb->red_mask = info->RedMask;
        fb->green_mask = info->GreenMask;
        fb->blue_mask = info->BlueMask;
        break;
    default: /* PixelBltOnly: nothing we can write to */
        return;
    }
    fb->pixels = (volatile uint32_t *)(uintptr_t)gop->Mode->FrameBufferBase;
    fb->width = info->HorizontalResolution;
    fb->height = info->VerticalResolution;
    fb->pitch = info->PixelsPerScanLine;
}

/* One file, in one allocation: the header, the name, then the contents. */
static struct boot_file *read_file(EFI_FILE_PROTOCOL *dir, const EFI_FILE_INFO *info)
{
    EFI_FILE_PROTOCOL *file = NULL;
    uint64_t name_len = 0;

    while (info->FileName[name_len])
        name_len++;
    uint64_t name_room = (name_len + 1 + 15) & ~15ULL; /* keeps the contents 16-byte aligned */
    struct boot_file *f = efi_alloc(sizeof *f + name_room + info->FileSize);

    if (!f || EFI_ERROR(dir->Open(dir, &file, info->FileName, EFI_FILE_MODE_READ, 0)))
        return NULL;
    char *name = (char *)(f + 1);
    for (uint64_t i = 0; i <= name_len; i++)
        name[i] = info->FileName[i] < 0x80 ? (char)info->FileName[i] : '?';
    f->next = NULL;
    f->name = name;
    f->data = (uint8_t *)name + name_room;
    f->size = info->FileSize;

    UINTN size = f->size;
    EFI_STATUS s = file->Read(file, &size, f->data);
    file->Close(file);
    return EFI_ERROR(s) || size != f->size ? NULL : f;
}

/* Read every file in the \clara directory of the volume this image came
 * from. Until the kernel can drive a disk, this is how the Lisp sources reach
 * it (DESIGN.md). Subdirectories are not followed, and names that start with
 * a dot are skipped: macOS leaves "._" files of its own on FAT volumes. */
static void read_boot_files(EFI_HANDLE image)
{
    static const EFI_GUID loaded_image_guid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
    static const EFI_GUID file_system_guid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
    EFI_BOOT_SERVICES *bs = g_st->BootServices;
    EFI_LOADED_IMAGE_PROTOCOL *loaded = NULL;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *volume = NULL;
    EFI_FILE_PROTOCOL *root = NULL, *dir = NULL;
    struct boot_file **tail = &g_boot.files;
    union {
        EFI_FILE_INFO info;
        uint8_t room[sizeof(EFI_FILE_INFO) + 256 * sizeof(CHAR16)]; /* a FAT name: 255 characters */
    } entry;

    if (EFI_ERROR(bs->HandleProtocol(image, &loaded_image_guid, (void **)&loaded)) ||
        EFI_ERROR(bs->HandleProtocol(loaded->DeviceHandle, &file_system_guid, (void **)&volume)) ||
        EFI_ERROR(volume->OpenVolume(volume, &root)) ||
        EFI_ERROR(root->Open(root, &dir, BOOT_DIR, EFI_FILE_MODE_READ, 0))) {
        efi_puts(L"ClaraOS: the boot volume has no " BOOT_DIR L" directory\r\n");
        return;
    }
    for (;;) {
        UINTN size = sizeof entry;
        if (EFI_ERROR(dir->Read(dir, &size, &entry)) || size == 0)
            break;
        if ((entry.info.Attribute & EFI_FILE_DIRECTORY) || entry.info.FileName[0] == L'.')
            continue;
        struct boot_file *f = read_file(dir, &entry.info);
        if (!f) {
            efi_puts(L"ClaraOS: could not read " BOOT_DIR L"\\");
            efi_puts(entry.info.FileName);
            efi_puts(L"\r\n");
            continue;
        }
        *tail = f;
        tail = &f->next;
    }
    dir->Close(dir);
    root->Close(root);
}

/* Snapshot the memory map and take the machine from the firmware. The map
 * needs a buffer, and allocating the buffer changes the map: so ask how big
 * the map is, allocate that and a page to spare, and read the map into it.
 * ExitBootServices fails when the map changed after it was read; the
 * specification then allows reading it again, allocating again if need be,
 * and one more try. A buffer that turned out too small is not given back:
 * a few pages, once. */
static EFI_STATUS exit_boot_services(EFI_HANDLE image)
{
    EFI_BOOT_SERVICES *bs = g_st->BootServices;
    UINTN capacity = 0, key = 0;
    uint32_t version = 0;

    for (int attempt = 0; attempt < 8; attempt++) {
        UINTN size = capacity;
        EFI_STATUS s = bs->GetMemoryMap(&size, g_boot.memory_map, &key, &g_boot.desc_size, &version);

        if (s == EFI_BUFFER_TOO_SMALL) {
            capacity = size + PAGE_SIZE;
            g_boot.memory_map = efi_alloc(capacity);
            if (!g_boot.memory_map)
                return EFI_OUT_OF_RESOURCES;
            continue;
        }
        if (EFI_ERROR(s))
            return s;
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
    read_boot_files(image);

    EFI_STATUS s = exit_boot_services(image);
    if (EFI_ERROR(s)) {
        efi_puts(L"ClaraOS: ExitBootServices failed\r\n");
        return s;
    }
    /* The stack under this function is boot-services memory: the firmware's
     * until a moment ago, and not the kernel's to keep. */
    arch_switch_stack(kernel_stack + sizeof kernel_stack, kmain, &g_boot);
}
