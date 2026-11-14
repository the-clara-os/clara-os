/* Physical memory: which page frames are free. One bit per 4 KiB frame, from
 * the lowest address of RAM to the highest, set while the frame is in use.
 *
 * The firmware's memory map says what is RAM and what was free when the
 * kernel took the machine. Conventional memory is handed out from the
 * start. Boot-services memory is free on paper too, but the processor goes
 * on using what the firmware left in it, page tables, a stack and exception
 * vectors, until the kernel has put its own in their place. pmm_reclaim
 * adds that memory then. */
#include "efi.h"
#include "kernel.h"

static uint64_t *g_bitmap; /* bit i is frame g_first + i */
static uint64_t g_first;   /* the lowest frame of RAM */
static uint64_t g_frames;  /* how many frames the bitmap covers */
static uint64_t g_free;    /* how many of them are free */
static uint64_t g_lowest;  /* every frame below this index is in use */
static struct lock g_lock; /* one thread at a time in pmm_alloc and pmm_free */

static const char *const type_names[EfiMaxMemoryType] = {
    "reserved",           "loader code",  "loader data",  "boot services code",
    "boot services data", "runtime code", "runtime data", "conventional",
    "unusable",           "ACPI reclaim", "ACPI NVS",     "MMIO",
    "MMIO port space",    "PAL code",     "persistent",
};

/* The part of a region that can be handed out, when the region is of the
 * kind asked for: conventional memory, or else boot-services memory. That
 * part is what lies above LOW_LIMIT. Returns its length in frames and
 * stores where it starts. */
static uint64_t usable_part(const EFI_MEMORY_DESCRIPTOR *d, int boot_services, uint64_t *start)
{
    uint64_t end = d->PhysicalStart + (d->NumberOfPages << PAGE_SHIFT);
    int wanted = boot_services ? d->Type == EfiBootServicesCode || d->Type == EfiBootServicesData
                               : d->Type == EfiConventionalMemory;

    *start = d->PhysicalStart < LOW_LIMIT ? LOW_LIMIT : d->PhysicalStart;
    return wanted && end > *start ? (end - *start) >> PAGE_SHIFT : 0;
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
        const EFI_MEMORY_DESCRIPTOR *d = efi_region(bi->memory_map, bi->desc_size, i);
        uint64_t end = d->PhysicalStart + (d->NumberOfPages << PAGE_SHIFT);

        if (d->Type < EfiMaxMemoryType)
            pages[d->Type] += d->NumberOfPages;
        else
            other += d->NumberOfPages;
        if (!efi_is_ram(d->Type))
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
        if (usable_part(efi_region(bi->memory_map, bi->desc_size, i), 0, &start) >= bitmap_pages)
            g_bitmap = phys_ptr(start);
    if (!g_bitmap)
        panic("no free region can hold the %llu pages of the page-frame bitmap", bitmap_pages);
    memset(g_bitmap, 0xff, bitmap_pages << PAGE_SHIFT);

    /* Free what the firmware says is free, then take the bitmap's own frames back. */
    for (uint64_t i = 0; i < regions; i++) {
        uint64_t count = usable_part(efi_region(bi->memory_map, bi->desc_size, i), 0, &start);

        if (count) {
            mark((start >> PAGE_SHIFT) - g_first, count, 0);
            g_free += count;
        }
    }
    mark(((uintptr_t)g_bitmap >> PAGE_SHIFT) - g_first, bitmap_pages, 1);
    g_free -= bitmap_pages;

    kprintf("page frames: %llu of %llu free (%llu MiB), boot-services memory not counted yet\n", g_free, ram,
            g_free >> (20 - PAGE_SHIFT));
    kprintf("page-frame bitmap: %llu KiB at %p\n", bitmap_pages << 2, (void *)g_bitmap);
}

static uint64_t alloc(uint64_t pages)
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

/* The lowest run of adjacent free frames that is long enough. Returns its
 * physical address, or 0 when there is no such run. The memory is not
 * cleared. */
uint64_t pmm_alloc(uint64_t pages)
{
    lock_acquire(&g_lock);
    uint64_t addr = alloc(pages);
    lock_release(&g_lock);
    return addr;
}

/* Give frames to the allocator: ones that pmm_alloc returned, or memory that
 * was in use since boot and is no longer needed. */
void pmm_free(uint64_t addr, uint64_t pages)
{
    uint64_t frame = addr >> PAGE_SHIFT;

    lock_acquire(&g_lock);
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
    lock_release(&g_lock);
}

uint64_t pmm_free_frames(void)
{
    return g_free;
}

/* Fill frames with a pattern that is different in every word and for every
 * salt, or check that they still hold it. */
static void pattern(uint64_t addr, uint64_t pages, uint64_t salt, int check)
{
    volatile uint64_t *word = phys_ptr(addr);

    for (uint64_t i = 0; i < pages * (PAGE_SIZE / 8); i++) {
        uint64_t want = (addr + i * 8) ^ salt;

        if (!check)
            word[i] = want;
        else if (word[i] != want)
            panic("pmm self-test: %llx holds %llx, not %llx", addr + i * 8, (uint64_t)word[i], want);
    }
}

/* Boot-services memory joins the free frames. Call this once the processor
 * is off the firmware's page tables, stack and exception vectors, all of
 * which lie in that memory. Every frame is overwritten before it is freed:
 * a boot that still needed something in there fails now, where a boot test
 * sees it, and not on the day the frame is handed out. */
void pmm_reclaim(const struct boot_info *bi)
{
    uint64_t regions = bi->memory_map_size / bi->desc_size, reclaimed = 0, start;

    for (uint64_t i = 0; i < regions; i++) {
        uint64_t count = usable_part(efi_region(bi->memory_map, bi->desc_size, i), 1, &start);

        if (!count)
            continue;
        pattern(start, count, 0x4444444444444444ULL, 0);
        pmm_free(start, count);
        reclaimed += count;
    }
    kprintf("page frames: %llu more from boot-services memory, overwritten first: %llu free (%llu MiB)\n",
            reclaimed, g_free, g_free >> (20 - PAGE_SHIFT));
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
