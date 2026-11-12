/* Physical memory: which page frames are free. One bit per 4 KiB frame, from
 * the lowest address of RAM to the highest, set while the frame is in use.
 *
 * The firmware's memory map says what is RAM and what was free when the
 * kernel took the machine. Only conventional memory is handed out so far.
 * Boot-services memory is free on paper, but the processor still uses two
 * things the firmware left inside it: the page tables, and the exception
 * vectors whose register dump on the serial port is all the kernel has for a
 * fault handler. It stays out until both are the kernel's own (M3, M4); then
 * all of it can go to pmm_free. */
#include "efi.h"
#include "kernel.h"

/* Nothing below this address is handed out. Frame 0 would be mistaken for a
 * failed allocation, and on x86 the first megabyte belongs to the firmware's
 * leftovers and, later, to the code that starts the other processors. */
#define LOW_LIMIT 0x100000ULL

static uint64_t *g_bitmap; /* bit i is frame g_first + i */
static uint64_t g_first;   /* the lowest frame of RAM */
static uint64_t g_frames;  /* how many frames the bitmap covers */
static uint64_t g_free;    /* how many of them are free */
static uint64_t g_lowest;  /* every frame below this index is in use */

static const char *const type_names[EfiMaxMemoryType] = {
    "reserved",           "loader code",  "loader data",  "boot services code",
    "boot services data", "runtime code", "runtime data", "conventional",
    "unusable",           "ACPI reclaim", "ACPI NVS",     "MMIO",
    "MMIO port space",    "PAL code",     "persistent",
};

/* Is this kind of region ordinary memory, whoever is using it? The firmware
 * also lists device and reserved address space, which can lie far above RAM
 * and must not stretch the bitmap. */
static int is_ram(uint32_t type)
{
    switch (type) {
    case EfiLoaderCode:
    case EfiLoaderData:
    case EfiBootServicesCode:
    case EfiBootServicesData:
    case EfiRuntimeServicesCode:
    case EfiRuntimeServicesData:
    case EfiConventionalMemory:
    case EfiACPIReclaimMemory:
    case EfiACPIMemoryNVS:
        return 1;
    default:
        return 0;
    }
}

static const EFI_MEMORY_DESCRIPTOR *region(const struct boot_info *bi, uint64_t i)
{
    return (const void *)((const uint8_t *)bi->memory_map + i * bi->desc_size);
}

/* The part of a region that can be handed out: free memory above LOW_LIMIT.
 * Returns its length in frames and stores where it starts. */
static uint64_t free_part(const EFI_MEMORY_DESCRIPTOR *d, uint64_t *start)
{
    uint64_t end = d->PhysicalStart + (d->NumberOfPages << PAGE_SHIFT);

    *start = d->PhysicalStart < LOW_LIMIT ? LOW_LIMIT : d->PhysicalStart;
    return d->Type == EfiConventionalMemory && end > *start ? (end - *start) >> PAGE_SHIFT : 0;
}

static int in_use(uint64_t i)
{
    return (g_bitmap[i / 64] >> (i % 64)) & 1;
}

static void mark(uint64_t i, uint64_t count, int used)
{
    for (; count--; i++) {
        if (used)
            g_bitmap[i / 64] |= 1ULL << (i % 64);
        else
            g_bitmap[i / 64] &= ~(1ULL << (i % 64));
    }
}

void pmm_init(const struct boot_info *bi)
{
    uint64_t regions = bi->memory_map_size / bi->desc_size;
    uint64_t pages[EfiMaxMemoryType] = {0}, other = 0;
    uint64_t low = ~0ULL, high = 0, ram = 0, start;

    /* What the map holds, and how far RAM extends. */
    for (uint64_t i = 0; i < regions; i++) {
        const EFI_MEMORY_DESCRIPTOR *d = region(bi, i);
        uint64_t end = d->PhysicalStart + (d->NumberOfPages << PAGE_SHIFT);

        if (d->Type < EfiMaxMemoryType)
            pages[d->Type] += d->NumberOfPages;
        else
            other += d->NumberOfPages;
        if (!is_ram(d->Type))
            continue;
        ram += d->NumberOfPages;
        if (d->PhysicalStart < low)
            low = d->PhysicalStart;
        if (end > high)
            high = end;
    }
    kprintf("memory map: %llu regions\n", regions);
    for (unsigned t = 0; t < EfiMaxMemoryType; t++)
        if (pages[t])
            kprintf("  %10llu KiB  %s\n", pages[t] << 2, type_names[t]);
    if (other)
        kprintf("  %10llu KiB  of types this kernel does not know\n", other << 2);
    if (!ram)
        panic("the memory map lists no RAM");
    g_first = low >> PAGE_SHIFT;
    g_frames = (high - low) >> PAGE_SHIFT;

    /* The bitmap goes at the start of the first free region that has room,
     * and begins with every frame in use. */
    uint64_t bitmap_pages = (g_frames + 8 * PAGE_SIZE - 1) / (8 * PAGE_SIZE);
    for (uint64_t i = 0; i < regions && !g_bitmap; i++)
        if (free_part(region(bi, i), &start) >= bitmap_pages)
            g_bitmap = (uint64_t *)(uintptr_t)start;
    if (!g_bitmap)
        panic("no free region can hold the %llu pages of the page-frame bitmap", bitmap_pages);
    memset(g_bitmap, 0xff, bitmap_pages << PAGE_SHIFT);

    /* Free what the firmware says is free, then take the bitmap's own frames back. */
    for (uint64_t i = 0; i < regions; i++) {
        uint64_t count = free_part(region(bi, i), &start);

        if (count) {
            mark((start >> PAGE_SHIFT) - g_first, count, 0);
            g_free += count;
        }
    }
    mark(((uintptr_t)g_bitmap >> PAGE_SHIFT) - g_first, bitmap_pages, 1);
    g_free -= bitmap_pages;

    kprintf("page frames: %llu of %llu free (%llu MiB), %llu of boot services memory not yet reclaimed\n",
            g_free, ram, g_free >> (20 - PAGE_SHIFT),
            pages[EfiBootServicesCode] + pages[EfiBootServicesData]);
    kprintf("page-frame bitmap: %llu KiB at %p\n", bitmap_pages << 2, (void *)g_bitmap);
}

/* The lowest run of adjacent free frames that is long enough. Returns its
 * physical address, or 0 when there is no such run. The memory is not
 * cleared. */
uint64_t pmm_alloc(uint64_t pages)
{
    uint64_t run = 0;

    if (pages == 0 || pages > g_free)
        return 0;
    while (g_lowest < g_frames && in_use(g_lowest))
        g_lowest++;
    for (uint64_t i = g_lowest; i < g_frames; i++) {
        if (in_use(i)) {
            run = 0;
            continue;
        }
        if (++run < pages)
            continue;
        uint64_t first = i + 1 - pages;
        mark(first, pages, 1);
        g_free -= pages;
        return (g_first + first) << PAGE_SHIFT;
    }
    return 0;
}

/* Give frames to the allocator: ones that pmm_alloc returned, or memory that
 * was in use since boot and is no longer needed. */
void pmm_free(uint64_t addr, uint64_t pages)
{
    uint64_t frame = addr >> PAGE_SHIFT;

    if ((addr & (PAGE_SIZE - 1)) || frame < g_first || frame - g_first >= g_frames ||
        pages > g_frames - (frame - g_first))
        panic("pmm_free: %llu frames at %llx are not page frames of RAM", pages, addr);
    uint64_t first = frame - g_first;
    for (uint64_t i = first; i < first + pages; i++)
        if (!in_use(i))
            panic("pmm_free: the frame at %llx is already free", (g_first + i) << PAGE_SHIFT);
    mark(first, pages, 0);
    g_free += pages;
    if (first < g_lowest)
        g_lowest = first;
}

/* Fill frames with a pattern that is different in every word and for every
 * salt, or check that they still hold it. */
static void pattern(uint64_t addr, uint64_t pages, uint64_t salt, int check)
{
    volatile uint64_t *word = (volatile uint64_t *)(uintptr_t)addr;

    for (uint64_t i = 0; i < pages * (PAGE_SIZE / 8); i++) {
        uint64_t want = (addr + i * 8) ^ salt;

        if (!check)
            word[i] = want;
        else if (word[i] != want)
            panic("pmm self-test: %llx holds %llx, not %llx", addr + i * 8, (uint64_t)word[i], want);
    }
}

/* Exercise the allocator on real memory. A check that fails is a panic, so a
 * boot that reaches its last line has passed. */
void pmm_selftest(void)
{
    enum { RUN = 256 };
    uint64_t before = g_free;
    uint64_t one = pmm_alloc(1), run = pmm_alloc(RUN), other = pmm_alloc(1);

    if (!one || !run || !other || g_free != before - RUN - 2)
        panic("pmm self-test: could not allocate %u frames out of %llu", RUN + 2, before);

    /* Allocations that overlapped would overwrite each other's pattern. */
    pattern(one, 1, 0x1111111111111111ULL, 0);
    pattern(run, RUN, 0x2222222222222222ULL, 0);
    pattern(other, 1, 0x3333333333333333ULL, 0);
    pattern(one, 1, 0x1111111111111111ULL, 1);
    pattern(run, RUN, 0x2222222222222222ULL, 1);
    pattern(other, 1, 0x3333333333333333ULL, 1);

    pmm_free(one, 1);
    if (pmm_alloc(1) != one)
        panic("pmm self-test: a freed frame below all other free frames was not the next one out");
    pmm_free(one, 1);
    pmm_free(run, RUN);
    pmm_free(other, 1);
    if (g_free != before)
        panic("pmm self-test: %llu frames free at the end, %llu at the start", g_free, before);
    if (pmm_alloc(g_free + 1))
        panic("pmm self-test: got more frames than there are");
    kprintf("page frames: self-test passed\n");
}
