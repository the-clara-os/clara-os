/* x86_64 paging (Intel SDM volume 3, chapter 4): what goes in a page-table
 * entry and how the processor is pointed at the tables. */
#include "kernel.h"

#define PTE_P   (1ULL << 0)
#define PTE_RW  (1ULL << 1)
#define PTE_PWT (1ULL << 3)
#define PTE_PCD (1ULL << 4)
#define PTE_NX  (1ULL << 63)

#define MSR_EFER 0xc0000080u
#define EFER_NXE (1u << 11)
#define CR0_WP   (1ULL << 16)
#define CR4_LA57 (1ULL << 12)

/* Five-level paging cannot be turned on or off while paging is on, so the
 * firmware's choice stands. */
int arch_mmu_levels(void)
{
    uint64_t cr4;

    __asm__("mov %%cr4, %0" : "=r"(cr4));
    return cr4 & CR4_LA57 ? 5 : 4;
}

/* Upper levels allow everything; the entry for the page decides. */
uint64_t arch_pte_table(uint64_t pa)
{
    return pa | PTE_P | PTE_RW;
}

uint64_t arch_pte_page(uint64_t pa, unsigned flags)
{
    uint64_t pte = pa | PTE_P;

    if (flags & VM_WRITE)
        pte |= PTE_RW;
    if (!(flags & VM_EXEC))
        pte |= PTE_NX;
    if (flags & VM_DEVICE)
        pte |= PTE_PCD | PTE_PWT; /* uncacheable, in the PAT the processor starts with */
    return pte;
}

void arch_mmu_switch(uint64_t root)
{
    uint32_t eax = 0x80000001u, ebx, ecx = 0, edx, lo, hi;
    uint64_t cr0;

    __asm__("cpuid" : "+a"(eax), "=b"(ebx), "+c"(ecx), "=d"(edx));
    if (!(edx & (1u << 20)))
        panic("this processor cannot mark pages no-execute");
    /* Bit 63 of an entry means no-execute only once EFER.NXE is set, and a
     * read-only page stops the kernel itself only while CR0.WP is. */
    __asm__("rdmsr" : "=a"(lo), "=d"(hi) : "c"(MSR_EFER));
    __asm__ volatile("wrmsr" : : "a"(lo | EFER_NXE), "d"(hi), "c"(MSR_EFER));
    __asm__("mov %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | CR0_WP));
    __asm__ volatile("mov %0, %%cr3" : : "r"(root) : "memory");
}

void arch_tlb_flush(uint64_t va)
{
    __asm__ volatile("invlpg (%0)" : : "r"(va) : "memory");
}
