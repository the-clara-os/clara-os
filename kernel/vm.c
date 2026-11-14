/* Virtual memory: the kernel's own page tables, in place of the firmware's.
 *
 * There is one address space, in 4 KiB pages:
 *
 *   0 to LOW_LIMIT           never mapped, so a null pointer faults
 *   RAM                      at its own address: virtual equals physical
 *   the screen, devices      at their own address too, each mapped by name
 *   VM_HEAP_BASE, 64 TiB     reserved for the Lisp heap, empty until M6
 *
 * The kernel image stays where the firmware loaded it and is mapped section
 * by section, so code cannot be written and data cannot be run. Nothing is
 * moved to the upper half of the address space: there is no user mode to
 * leave the lower half to, and staying put saves relocating the image and
 * translating every physical address the drivers will handle.
 *
 * Both architectures walk four levels of 512-entry tables (x86_64 five, if
 * the firmware turned that on), keep "present" in bit 0 of an entry and the
 * address in bits 12 to 47. So the walk is shared, and
 * kernel/arch/<arch>/mmu.c supplies the other bits and the registers. */
#include "efi.h"
#include "kernel.h"
#include "pe.h"

#define PTE_PRESENT 1ULL
#define PTE_ADDR    0x0000fffffffff000ULL

extern const uint8_t __ImageBase[]; /* from the linker: where the image starts in memory */

static uint64_t g_root;   /* the top-level table */
static int g_levels;
static int g_live;        /* the processor is using these tables */
static uint64_t g_tables; /* how many there are, one page each */
static struct lock g_lock; /* one thread at a time in the tables; new_table takes the allocator's lock inside it */

static uint64_t new_table(void)
{
    uint64_t page = pmm_alloc(1);

    if (!page)
        panic("out of memory for a page table");
    memset(phys_ptr(page), 0, PAGE_SIZE);
    g_tables++;
    return page;
}

/* The entry that maps va, in the lowest table. With create, tables missing
 * on the way down are added; without, NULL says there is nothing there. */
static uint64_t *entry_for(uint64_t va, int create)
{
    uint64_t *table = phys_ptr(g_root);

    for (int level = g_levels; level > 1; level--) {
        uint64_t *e = &table[(va >> (PAGE_SHIFT + 9 * (level - 1))) & 511];

        if (!(*e & PTE_PRESENT)) {
            if (!create)
                return NULL;
            *e = arch_pte_table(new_table());
        }
        table = phys_ptr(*e & PTE_ADDR);
    }
    return &table[(va >> PAGE_SHIFT) & 511];
}

static void set_entry(uint64_t va, uint64_t entry)
{
    uint64_t *e = entry_for(va, entry != 0);

    if (!e)
        return;
    if (g_live && (*e & PTE_PRESENT)) {
        /* Break before make: the processor must have forgotten the old
         * translation before a different one takes its place. */
        *e = 0;
        arch_tlb_flush(va);
    }
    *e = entry;
    if (g_live && entry)
        arch_tlb_flush(va);
}

void vm_map(uint64_t va, uint64_t pa, uint64_t pages, unsigned flags)
{
    if ((va | pa) & (PAGE_SIZE - 1))
        panic("vm_map: %llx to %llx is not page-aligned", va, pa);
    lock_acquire(&g_lock);
    for (; pages--; va += PAGE_SIZE, pa += PAGE_SIZE)
        set_entry(va, arch_pte_page(pa, flags));
    lock_release(&g_lock);
}

void vm_unmap(uint64_t va, uint64_t pages)
{
    lock_acquire(&g_lock);
    for (; pages--; va += PAGE_SIZE)
        set_entry(va & ~(PAGE_SIZE - 1), 0);
    lock_release(&g_lock);
}

uint64_t vm_lookup(uint64_t va)
{
    lock_acquire(&g_lock);
    uint64_t *e = entry_for(va, 0);
    uint64_t pa = e && (*e & PTE_PRESENT) ? *e & PTE_ADDR : 0;
    lock_release(&g_lock);
    return pa;
}

/* The section table of the kernel's own image, and how many entries it has. */
static const struct pe_section *image_sections(unsigned *count)
{
    const struct pe_dos_header *dos = (const void *)__ImageBase;
    const struct pe_header *pe = (const void *)(__ImageBase + dos->e_lfanew);

    if (dos->e_magic != PE_DOS_MAGIC || pe->signature != PE_SIGNATURE)
        panic("no PE image at %p", (void *)__ImageBase);
    *count = pe->sections;
    return (const void *)((const uint8_t *)(pe + 1) + pe->optional_header_size);
}

/* The image is loaded at a different address on every machine, so a fault
 * report gives a place in it as an offset, which is also what the tools
 * that know the function names want (CLAUDE.md). */
uint64_t vm_image_offset(uint64_t addr)
{
    unsigned count;
    const struct pe_section *s = image_sections(&count);
    uint64_t offset = addr - (uint64_t)(uintptr_t)__ImageBase;

    for (unsigned i = 0; i < count; i++, s++)
        if (offset - s->virtual_address < s->virtual_size)
            return offset;
    return 0;
}

/* The kernel's own image: its headers, then every section with the access
 * its PE flags ask for, over the plain mapping the image got as RAM. */
static void map_image(void)
{
    uint64_t base = (uint64_t)(uintptr_t)__ImageBase;
    unsigned sections;
    const struct pe_section *s = image_sections(&sections);

    kprintf("kernel image at %p\n", (void *)__ImageBase);
    vm_map(base, base, 1, 0);
    for (unsigned i = 0; i < sections; i++, s++) {
        int write = (s->characteristics & PE_SECTION_WRITE) != 0;
        int exec = (s->characteristics & PE_SECTION_EXECUTE) != 0;
        uint64_t pages = (s->virtual_size + PAGE_SIZE - 1) >> PAGE_SHIFT;

        vm_map(base + s->virtual_address, base + s->virtual_address, pages,
               (write ? VM_WRITE : 0) | (exec ? VM_EXEC : 0));
        kprintf("  +%06x %5llu KiB  r%c%c  ", s->virtual_address, pages << 2, write ? 'w' : '-',
                exec ? 'x' : '-');
        for (unsigned c = 0; c < sizeof s->name && s->name[c]; c++)
            kputc(s->name[c]);
        kputc('\n');
    }
}

/* Build the address space described at the top of this file and switch the
 * processor to it. */
void vm_init(const struct boot_info *bi)
{
    uint64_t regions = bi->memory_map_size / bi->desc_size, ram = 0;

    g_levels = arch_mmu_levels();
    g_root = new_table();

    for (uint64_t i = 0; i < regions; i++) {
        const EFI_MEMORY_DESCRIPTOR *d = efi_region(bi->memory_map, bi->desc_size, i);
        uint64_t start = d->PhysicalStart, end = start + (d->NumberOfPages << PAGE_SHIFT);

        if (start < LOW_LIMIT)
            start = LOW_LIMIT;
        if (!efi_is_ram(d->Type) || start >= end)
            continue;
        /* RAM is data, whatever the firmware kept there: the only code the
         * processor runs from now on is the kernel image's. */
        vm_map(start, start, (end - start) >> PAGE_SHIFT, VM_WRITE);
        ram += (end - start) >> PAGE_SHIFT;
    }
    map_image();
    vm_unmap((uint64_t)(uintptr_t)kernel_stack, 1); /* the guard page under the boot stack */
    if (bi->fb.pixels) {
        uint64_t fb = (uint64_t)(uintptr_t)bi->fb.pixels;
        uint64_t bytes = (uint64_t)bi->fb.pitch * bi->fb.height * 4 + (fb & (PAGE_SIZE - 1));

        vm_map(fb & ~(PAGE_SIZE - 1), fb & ~(PAGE_SIZE - 1), (bytes + PAGE_SIZE - 1) >> PAGE_SHIFT, VM_WRITE);
    }
    arch_map_devices();

    arch_mmu_switch(g_root);
    g_live = 1;
    kprintf("virtual memory: %d-level page tables of our own in %llu KiB, %llu MiB of RAM at its own address\n",
            g_levels, g_tables << 2, ram >> (20 - PAGE_SHIFT));
}

/* Map one frame at each end of the heap region and reach it both ways, then
 * check what must stay unmapped. This reads the tables; whether the
 * processor really refuses a forbidden access is for fault_selftest. */
void vm_selftest(void)
{
    static const uint64_t where[2] = {VM_HEAP_BASE, VM_HEAP_BASE + VM_HEAP_SIZE - PAGE_SIZE};
    uint64_t frame = pmm_alloc(1);
    volatile uint64_t *direct = phys_ptr(frame);

    if (!frame)
        panic("vm self-test: no free frame");
    for (unsigned i = 0; i < 2; i++) {
        volatile uint64_t *mapped = (volatile uint64_t *)(uintptr_t)where[i];

        vm_map(where[i], frame, 1, VM_WRITE);
        *mapped = 0x636c617261ULL + i;
        if (*direct != 0x636c617261ULL + i || vm_lookup(where[i]) != frame)
            panic("vm self-test: %llx does not reach the frame at %llx", where[i], frame);
        vm_unmap(where[i], 1);
        if (vm_lookup(where[i]))
            panic("vm self-test: %llx is still mapped", where[i]);
    }
    pmm_free(frame, 1);
    if (vm_lookup(0) || vm_lookup(LOW_LIMIT - PAGE_SIZE) || vm_lookup((uint64_t)(uintptr_t)kernel_stack))
        panic("vm self-test: the null page, low memory or the stack's guard page is mapped");
    kprintf("virtual memory: self-test passed\n");
}
