/* Boot handoff. ClaraOS is itself the UEFI application: the firmware loads
 * BOOTX64.EFI or BOOTAA64.EFI and calls efi_main. Everything the kernel wants
 * from the firmware is collected here, while boot services still exist: the
 * ACPI tables, the framebuffer, the files of this system in the boot
 * volume's \clara directory and, last, the memory map. Then the machine is
 * ours, and kmain starts on the kernel's own stack.
 *
 * This is also where a start is counted, and where a newer system that is
 * on the volume is tried, which are the two things that the firmware's
 * file system is written to for: both have to happen before the kernel
 * has run a line of Lisp, so that they hold when the Lisp does not come to
 * its prompt. */
#include "efi.h"
#include "kernel.h"

#define BOOT_DIR L"\\clara"

static EFI_SYSTEM_TABLE *g_st;
static struct boot_info g_boot;

__attribute__((aligned(4096))) uint8_t kernel_stack[PAGE_SIZE + KERNEL_STACK_SIZE];

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
    return phys_ptr(addr);
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
    fb->pixels = phys_ptr(gop->Mode->FrameBufferBase);
    fb->width = info->HorizontalResolution;
    fb->height = info->VerticalResolution;
    fb->pitch = info->PixelsPerScanLine;
}

/* The boot volume: the one this image came from, and its \clara directory,
 * open for reading and for writing. Everything below that has to do with
 * files goes through these two, and does nothing when the volume has no
 * such directory. */
static EFI_HANDLE g_device;
static EFI_FILE_PROTOCOL *g_dir;

union entry { /* what reading a directory gives, with room for a FAT name of 255 characters */
    EFI_FILE_INFO info;
    uint8_t room[sizeof(EFI_FILE_INFO) + 256 * sizeof(CHAR16)];
};

static void open_boot_volume(EFI_HANDLE image)
{
    static const EFI_GUID loaded_image_guid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
    static const EFI_GUID file_system_guid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
    EFI_BOOT_SERVICES *bs = g_st->BootServices;
    EFI_LOADED_IMAGE_PROTOCOL *loaded = NULL;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *volume = NULL;
    EFI_FILE_PROTOCOL *root = NULL;

    if (EFI_ERROR(bs->HandleProtocol(image, &loaded_image_guid, (void **)&loaded)) ||
        EFI_ERROR(bs->HandleProtocol(loaded->DeviceHandle, &file_system_guid, (void **)&volume)) ||
        EFI_ERROR(volume->OpenVolume(volume, &root))) {
        efi_puts(L"ClaraOS: the volume that the kernel came from cannot be read\r\n");
        return;
    }
    g_device = loaded->DeviceHandle;
    /* For writing as well, where the volume can be written; and for reading where it cannot. */
    if (EFI_ERROR(root->Open(root, &g_dir, BOOT_DIR, EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE, 0)) &&
        EFI_ERROR(root->Open(root, &g_dir, BOOT_DIR, EFI_FILE_MODE_READ, 0))) {
        g_dir = NULL;
        efi_puts(L"ClaraOS: the boot volume has no " BOOT_DIR L" directory\r\n");
    }
    root->Close(root);
}

/* A name in ASCII, as the firmware wants names: 16 bits to the character. */
static void widen(CHAR16 *to, size_t room, const char *from)
{
    size_t i = 0;

    for (; from[i] && i + 1 < room; i++)
        to[i] = (CHAR16)(uint8_t)from[i];
    to[i] = 0;
}

/* Is that what the file is called, in letters of either case, as FAT has it? */
static int named(const CHAR16 *file, const char *name)
{
    size_t i = 0;

    for (; file[i] && name[i]; i++) {
        CHAR16 a = file[i], b = (CHAR16)(uint8_t)name[i];

        if ((a >= 'A' && a <= 'Z' ? a | 0x20 : a) != (b >= 'A' && b <= 'Z' ? b | 0x20 : b))
            return 0;
    }
    return !file[i] && !name[i];
}

static int ends_with(const CHAR16 *file, const char *end)
{
    size_t length = 0, n = strlen(end);

    while (file[length])
        length++;
    return length >= n && named(file + length - n, end);
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

/* The files of a directory, each read and put at the end of the list of
 * boot files when WANTED says so of its name. Subdirectories are not
 * followed, and names that start with a dot are skipped: macOS leaves "._"
 * files of its own on FAT volumes. */
static void read_files(EFI_FILE_PROTOCOL *dir, const CHAR16 *where, int (*wanted)(const CHAR16 *name))
{
    struct boot_file **tail = &g_boot.files;
    union entry entry;

    while (*tail)
        tail = &(*tail)->next;
    dir->SetPosition(dir, 0);
    for (;;) {
        UINTN size = sizeof entry;

        if (EFI_ERROR(dir->Read(dir, &size, &entry)) || size == 0)
            break;
        if ((entry.info.Attribute & EFI_FILE_DIRECTORY) || entry.info.FileName[0] == L'.' ||
            !wanted(entry.info.FileName))
            continue;
        struct boot_file *f = read_file(dir, &entry.info);
        if (!f) {
            efi_puts(L"ClaraOS: could not read ");
            efi_puts(where);
            efi_puts(L"\\");
            efi_puts(entry.info.FileName);
            efi_puts(L"\r\n");
            continue;
        }
        *tail = f;
        tail = &f->next;
    }
}

/* The few bytes of a small file of \clara as text, with a 0 after them:
 * how many there were, and 0 when there is no such file. */
static size_t read_small(const CHAR16 *name, char *text, size_t room)
{
    EFI_FILE_PROTOCOL *file = NULL;
    UINTN size = room - 1;

    text[0] = 0;
    if (!g_dir || EFI_ERROR(g_dir->Open(g_dir, &file, name, EFI_FILE_MODE_READ, 0)))
        return 0;
    if (EFI_ERROR(file->Read(file, &size, text)))
        size = 0;
    file->Close(file);
    text[size] = 0;
    return size;
}

/* A small file of \clara, made or written over from its first byte on.
 * What is written is never shorter than what was there. On a volume that
 * cannot be written nothing happens, and nothing is said. */
static void write_small(const CHAR16 *name, const char *text)
{
    EFI_FILE_PROTOCOL *file = NULL;
    UINTN size = strlen(text);

    if (!g_dir || EFI_ERROR(g_dir->Open(g_dir, &file, name,
                                        EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE, 0)))
        return;
    file->SetPosition(file, 0);
    file->Write(file, &size, text);
    file->Close(file);
}

static void delete_small(const CHAR16 *name)
{
    EFI_FILE_PROTOCOL *file = NULL;

    if (g_dir && !EFI_ERROR(g_dir->Open(g_dir, &file, name, EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE, 0)))
        file->Delete(file);
}

/* Text put together in a buffer: a text, and a number in sixteen digits. */
static char *put_text(char *to, const char *from)
{
    while (*from)
        *to++ = *from++;
    *to = 0;
    return to;
}

static char *put_hex(char *to, uint64_t value)
{
    for (int shift = 60; shift >= 0; shift -= 4)
        *to++ = "0123456789abcdef"[value >> shift & 15];
    *to = 0;
    return to;
}

static int same_text(const char *a, const char *b)
{
    return strlen(a) == strlen(b) && !memcmp(a, b, strlen(a));
}

/* Another system's kernel is started in place of this one: the file
 * \clara\<system>\<kernel> is read, the firmware makes an image of what
 * was read, the image is told which volume it came from, as this one was,
 * and it is started. Returns only when that did not work. */
static void start_system(EFI_HANDLE image, const char *system)
{
    static const EFI_GUID loaded_image_guid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
    EFI_BOOT_SERVICES *bs = g_st->BootServices;
    EFI_LOADED_IMAGE_PROTOCOL *loaded = NULL;
    EFI_FILE_PROTOCOL *dir = NULL, *file = NULL;
    EFI_HANDLE other = NULL;
    CHAR16 name[SYSTEM_NAME];
    union entry entry;
    void *kernel = NULL;
    UINTN size = 0;

    widen(name, SYSTEM_NAME, system);
    if (EFI_ERROR(g_dir->Open(g_dir, &dir, name, EFI_FILE_MODE_READ, 0)))
        return;
    for (;;) {
        UINTN n = sizeof entry;

        if (EFI_ERROR(dir->Read(dir, &n, &entry)) || n == 0)
            break;
        if ((entry.info.Attribute & EFI_FILE_DIRECTORY) || !named(entry.info.FileName, arch_kernel))
            continue;
        size = entry.info.FileSize;
        kernel = efi_alloc(size);
        if (kernel && !EFI_ERROR(dir->Open(dir, &file, entry.info.FileName, EFI_FILE_MODE_READ, 0))) {
            UINTN got = size;

            if (EFI_ERROR(file->Read(file, &got, kernel)) || got != size)
                size = 0;
            file->Close(file);
        } else
            size = 0;
        break;
    }
    dir->Close(dir);
    if (!kernel || !size)
        return;
    if (EFI_ERROR(bs->LoadImage(0, image, NULL, kernel, size, &other)) ||
        EFI_ERROR(bs->HandleProtocol(other, &loaded_image_guid, (void **)&loaded)))
        return;
    /* The image is a copy by now, and what was read is not needed any more. */
    bs->FreePages((EFI_PHYSICAL_ADDRESS)(uintptr_t)kernel, (size + PAGE_SIZE - 1) >> PAGE_SHIFT);
    loaded->DeviceHandle = g_device;
    efi_puts(L"ClaraOS: starting the system that is to be tried\r\n");
    bs->StartImage(other, NULL, NULL);
}

/* A newer system that the running one has put on the volume is tried
 * before it takes the place of the one that is there (lisp/system.lisp).
 * The file \clara\next says where that stands, in one line:
 *
 *   try <system>     the system is on the volume, whole, and is to be tried
 *                    at the next start. The kernel that the firmware starts
 *                    is still the old one, this one: it writes that the
 *                    system has been tried, and starts that system's kernel
 *                    in place of itself.
 *   tried <system>   it has been started. When it is that system which
 *                    reads this, it is on trial: once it has come to its
 *                    prompt it takes the place of the old one and deletes
 *                    the file. When it is the old one, the trial did not
 *                    get that far, and the machine was started again: the
 *                    old system goes on, and says so.
 *   failed <system>  what the old one makes of the line then, so that the
 *                    starts are counted again from here on.
 *
 * So the kernel that the firmware starts is one that has come to its
 * prompt before, until a newer one has. */
static void try_next(EFI_HANDLE image)
{
    char state[96], line[96], *name = NULL, *end;
    int tried = 0, failed = 0;

    read_small(L"next", state, sizeof state);
    if (!memcmp(state, "try ", 4))
        name = state + 4;
    else if (!memcmp(state, "tried ", 6))
        name = state + 6, tried = 1;
    else if (!memcmp(state, "failed ", 7))
        name = state + 7, failed = 1;
    else
        return;
    for (end = name; (uint8_t)*end > ' '; end++)
        ;
    *end = 0;
    if (!*name || strlen(name) >= SYSTEM_NAME)
        return;
    if (same_text(name, clara_system)) {
        g_boot.trial = !failed;
        return;
    }
    memcpy(g_boot.failed, name, strlen(name) + 1);
    if (failed)
        return;
    if (!tried) {
        put_text(put_text(put_text(line, "tried "), name), "\n");
        write_small(L"next", line);
        delete_small(L"starts"); /* the count of starts is the new system's from here */
        start_system(image, name);
    }
    put_text(put_text(put_text(line, "failed "), name), "\n");
    write_small(L"next", line);
    delete_small(L"starts");
}

/* A start is counted before it is known how it goes: the file \clara\starts
 * holds how many starts in a row have not come to a prompt, this one
 * included, and the world deletes it when it has come to its prompt
 * (lisp/system.lisp). So what is found here is how many starts before this
 * one did not get there, and the kernel goes by that: after one, the world
 * that was saved is passed over, and after two, so is what the user keeps
 * as text. Behind the count is a number that no other start was given: the
 * volume that has this file with this number in it is the one that the
 * machine was started from, whichever disk comes first on the bus. */
static void count_start(void)
{
    char text[40], *end;
    uint64_t token = 0;

    read_small(L"starts", text, sizeof text);
    g_boot.starts = text[0] >= '1' && text[0] <= '9' ? (unsigned)(text[0] - '0') : 0;
    if (EFI_ERROR(g_st->BootServices->GetNextMonotonicCount(&token)) || !token)
        token = 1;
    g_boot.token = token;
    text[0] = (char)('0' + (g_boot.starts < 8 ? g_boot.starts + 1 : 9));
    text[1] = ' ';
    end = put_hex(text + 2, token);
    put_text(end, "\n");
    write_small(L"starts", text);
}

/* What time it is, by the firmware's clock, which is the only clock that
 * is asked: a certificate is good from one day to another, and whoever is
 * shown one has to know the day (lisp/tls.lisp). A firmware that has no
 * clock, or one that says a time that is none, leaves the kernel without. */
static void read_clock(void)
{
    EFI_TIME time;

    if (!g_st->RuntimeServices || EFI_ERROR(g_st->RuntimeServices->GetTime(&time, NULL)))
        return;
    if (time.Year < 1970 || time.Year > 9999 || time.Month < 1 || time.Month > 12 || time.Day < 1 || time.Day > 31 ||
        time.Hour > 23 || time.Minute > 59 || time.Second > 59)
        return;
    g_boot.clock.known = 1;
    g_boot.clock.year = time.Year;
    g_boot.clock.month = time.Month;
    g_boot.clock.day = time.Day;
    g_boot.clock.hour = time.Hour;
    g_boot.clock.minute = time.Minute;
    g_boot.clock.second = time.Second;
    g_boot.clock.behind = time.TimeZone == EFI_UNSPECIFIED_TIMEZONE || time.TimeZone < -1440 || time.TimeZone > 1440 ? 0 : time.TimeZone;
}

static int of_the_system(const CHAR16 *name)
{
    /* The kernels are in memory already. The list of whom the system trusts is read from the volume
     * by whoever wants it, when it is wanted (lisp/tls.lisp), and by no machine that fetches nothing. */
    return !ends_with(name, ".EFI") && !ends_with(name, ".pem") && !named(name, "manifest");
}

static int of_the_volume(const CHAR16 *name)
{
    if (named(name, "clara.image") && g_boot.starts) {
        g_boot.image_passed_over = 1;
        return 0;
    }
    return named(name, "clara.image") || named(name, "stress");
}

/* What the kernel needs of the boot volume before it has a driver for any
 * disk: the files of its own system, which are in the directory of the
 * system's name; and of \clara itself the world that was saved, unless the
 * start before this one did not come to its prompt, and the file that asks
 * for the collector's slow test. */
static void read_boot_files(void)
{
    EFI_FILE_PROTOCOL *dir = NULL;
    CHAR16 name[SYSTEM_NAME];

    if (!g_dir)
        return;
    widen(name, SYSTEM_NAME, clara_system);
    if (EFI_ERROR(g_dir->Open(g_dir, &dir, name, EFI_FILE_MODE_READ, 0))) {
        efi_puts(L"ClaraOS: the boot volume has no directory " BOOT_DIR L"\\");
        efi_puts(name);
        efi_puts(L", where the files of this system would be\r\n");
    } else {
        read_files(dir, name, of_the_system);
        dir->Close(dir);
    }
    read_files(g_dir, BOOT_DIR, of_the_volume);
    g_dir->Close(g_dir);
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
    read_clock();
    open_boot_volume(image);
    if (g_dir) {
        try_next(image);
        count_start();
    }
    read_boot_files();

    EFI_STATUS s = exit_boot_services(image);
    if (EFI_ERROR(s)) {
        efi_puts(L"ClaraOS: ExitBootServices failed\r\n");
        return s;
    }
    /* The stack under this function is boot-services memory: the firmware's
     * until a moment ago, and not the kernel's to keep. */
    arch_switch_stack(kernel_stack + sizeof kernel_stack, kmain, &g_boot);
}
