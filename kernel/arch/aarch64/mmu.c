/* AArch64 stage 1 translation at EL1 with a 4 KiB granule and 48-bit
 * addresses (Arm ARM, chapter D8): what goes in a descriptor and how the
 * processor is pointed at the tables. Only TTBR0 is used; everything the
 * kernel maps is in the lower half of the address space. */
#include "kernel.h"

#define PTE_VALID   (1ULL << 0)
#define PTE_TABLE   (1ULL << 1)  /* in the lowest table the same bit says "page" */
#define PTE_ATTR(i) ((uint64_t)(i) << 2) /* which byte of MAIR_EL1 describes the memory */
#define PTE_RDONLY  (1ULL << 7)  /* AP[2] */
#define PTE_SHARED  (3ULL << 8)  /* inner shareable */
#define PTE_AF      (1ULL << 10) /* accessed: without it the first use faults */
#define PTE_PXN     (1ULL << 53) /* not executable at EL1 */
#define PTE_UXN     (1ULL << 54) /* not executable at EL0 */

#define ATTR_NORMAL 0 /* memory, write-back cached */
#define ATTR_DEVICE 1 /* device registers: nGnRE */
#define MAIR_VALUE  (0xffULL << (8 * ATTR_NORMAL) | 0x04ULL << (8 * ATTR_DEVICE))

#define TCR_T0SZ(n)   ((uint64_t)(n) << 0)  /* 64 minus the address bits */
#define TCR_WALK0     (1ULL << 8 | 1ULL << 10 | 3ULL << 12) /* tables: cached, inner shareable */
#define TCR_TG0_4K    (0ULL << 14)
#define TCR_T1SZ(n)   ((uint64_t)(n) << 16)
#define TCR_EPD1      (1ULL << 23)          /* no walks through TTBR1 */
#define TCR_TG1_4K    (2ULL << 30)
#define TCR_IPS(n)    ((uint64_t)(n) << 32) /* physical address size, as ID_AA64MMFR0_EL1 encodes it */

#define SCTLR_M   (1ULL << 0)  /* translation on */
#define SCTLR_C   (1ULL << 2)  /* data cache */
#define SCTLR_I   (1ULL << 12) /* instruction cache */
#define SCTLR_WXN (1ULL << 19) /* writable implies not executable */

int arch_mmu_levels(void)
{
    return 4;
}

uint64_t arch_pte_table(uint64_t pa)
{
    return pa | PTE_TABLE | PTE_VALID;
}

uint64_t arch_pte_page(uint64_t pa, unsigned flags)
{
    uint64_t pte = pa | PTE_TABLE | PTE_VALID | PTE_AF | PTE_UXN;

    if (!(flags & VM_WRITE))
        pte |= PTE_RDONLY;
    if (!(flags & VM_EXEC))
        pte |= PTE_PXN;
    if (flags & VM_DEVICE)
        pte |= PTE_ATTR(ATTR_DEVICE);
    else
        pte |= PTE_ATTR(ATTR_NORMAL) | PTE_SHARED;
    return pte;
}

/* The firmware's tables may use fewer address bits and so a different shape
 * (T0SZ), and the two shapes cannot be swapped while translation is on: for
 * a moment the processor could read the new tables by the old rule. So
 * translation goes off, the registers change, and it comes back on. That is
 * safe here and only here: the code runs at its physical address under both
 * sets of tables, interrupts are masked, and nothing between off and on
 * touches memory, which without translation would bypass the data cache. */
void arch_mmu_switch(uint64_t root)
{
    uint64_t mmfr0, sctlr, tcr, pa_range;

    __asm__("mrs %0, id_aa64mmfr0_el1" : "=r"(mmfr0));
    if (((mmfr0 >> 28) & 0xf) == 0xf)
        panic("this processor has no 4 KiB translation granule");
    pa_range = mmfr0 & 0xf;
    if (pa_range > 5)
        pa_range = 5; /* 48 bits, all that 4 KiB pages reach without LPA2 */
    tcr = TCR_T0SZ(16) | TCR_WALK0 | TCR_TG0_4K | TCR_T1SZ(16) | TCR_EPD1 | TCR_TG1_4K | TCR_IPS(pa_range);

    /* WXN on: whatever can be written cannot be run, even if an entry in
     * the tables were to say otherwise. */
    __asm__("mrs %0, sctlr_el1" : "=r"(sctlr));
    sctlr |= SCTLR_M | SCTLR_C | SCTLR_I | SCTLR_WXN;

    __asm__ volatile("dsb sy\n"
                     "msr sctlr_el1, %[off]\n"
                     "isb\n"
                     "msr mair_el1, %[mair]\n"
                     "msr tcr_el1, %[tcr]\n"
                     "msr ttbr0_el1, %[root]\n"
                     "isb\n"
                     "tlbi vmalle1\n"
                     "dsb nsh\n"
                     "isb\n"
                     "msr sctlr_el1, %[on]\n"
                     "isb"
                     :
                     : [off] "r"(sctlr & ~SCTLR_M), [mair] "r"((uint64_t)MAIR_VALUE), [tcr] "r"(tcr),
                       [root] "r"(root), [on] "r"(sctlr)
                     : "memory");
}

/* The store into the table has to be complete before the stale translation
 * is dropped, and both before the next instruction runs. */
void arch_tlb_flush(uint64_t va)
{
    __asm__ volatile("dsb ishst\n"
                     "tlbi vaae1, %0\n"
                     "dsb ish\n"
                     "isb"
                     :
                     : "r"(va >> PAGE_SHIFT)
                     : "memory");
}
