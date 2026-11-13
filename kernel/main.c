/* The kernel proper. The boot handoff (boot.c) has taken the machine from the
 * firmware; kmain starts on the kernel's own stack and never returns. */
#include "acpi.h"
#include "kernel.h"

/* Each file with the start of its first line, to show that the contents
 * arrived and not only the name. */
static void report_boot_files(const struct boot_info *bi)
{
    if (!bi->files)
        panic("nothing to load: the boot volume has no files in \\clara");
    for (const struct boot_file *f = bi->files; f; f = f->next) {
        kprintf("boot file %s, %llu bytes: ", f->name, f->size);
        for (uint64_t i = 0; i < f->size && i < 56 && f->data[i] >= ' ' && f->data[i] < 0x7f; i++)
            kputc((char)f->data[i]);
        kputc('\n');
    }
}

void kmain(struct boot_info *bi)
{
    arch_early_init();
    fbcon_init(&bi->fb);

    fbcon_set_color(FBCON_ACCENT);
    kprintf("\nClaraOS %s on %s: the machine is ours\n", CLARA_VERSION, arch_name);
    fbcon_set_color(FBCON_TEXT);

    /* From here on a fault is reported by the kernel, not by the firmware. */
    arch_exceptions_init();

    /* The address of a local variable says which stack this is. */
    if ((uintptr_t)&bi - (uintptr_t)(kernel_stack + PAGE_SIZE) >= KERNEL_STACK_SIZE)
        panic("kmain is not running on the kernel stack");
    kprintf("kernel stack: %u KiB at %p\n", KERNEL_STACK_SIZE >> 10, (void *)(kernel_stack + PAGE_SIZE));

    pmm_init(bi);
    pmm_selftest();
    vm_init(bi);
    vm_selftest();

    /* The stack, the exception vectors and now the page tables are the
     * kernel's own, so nothing the firmware left behind is in use. */
    pmm_reclaim(bi);
    fault_selftest();

    acpi_init(bi->acpi_rsdp);
    arch_interrupts_init();
    timer_selftest();

    report_boot_files(bi);
    if (bi->fb.pixels)
        kprintf("framebuffer %ux%u at %p, pitch %u, masks r %06x g %06x b %06x\n", bi->fb.width,
                bi->fb.height, (void *)bi->fb.pixels, bi->fb.pitch, bi->fb.red_mask,
                bi->fb.green_mask, bi->fb.blue_mask);
    else
        kprintf("framebuffer: none\n");
    kprintf("clara: nothing more to do, halting\n");
    arch_halt();
}
