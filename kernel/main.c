/* The kernel proper. The boot handoff (boot.c) has taken the machine from the
 * firmware; kmain starts on the kernel's own stack and never returns. */
#include "acpi.h"
#include "kernel.h"
#include "lisp/lisp.h"

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

    sha512_selftest();
    ed25519_selftest();
    /* What a connection that is kept closed is made of (lisp/tls.lisp). */
    sha256_selftest();
    hmac_selftest();
    aes_selftest();
    x25519_selftest();
    bignum_selftest();
    ecdsa_selftest();
    acpi_init(bi->acpi_rsdp);
    arch_interrupts_init();
    timer_selftest();
    timer_set_clock(&bi->clock);
    if (bi->clock.known)
        kprintf("clock: the firmware says that it is %u-%02u-%02u %02u:%02u:%02u\n", bi->clock.year, bi->clock.month,
                bi->clock.day, bi->clock.hour, bi->clock.minute, bi->clock.second);
    else
        kprintf("clock: the firmware does not say what time it is\n");
    arch_power_init();

    /* With a tick to take turns on, this flow of control becomes one
     * thread among others. */
    thread_init();
    thread_selftest();

    lisp_init(bi);
    lisp_selftest();

    if (bi->fb.pixels)
        kprintf("framebuffer %ux%u at %p, pitch %u, masks r %06x g %06x b %06x\n", bi->fb.width,
                bi->fb.height, (void *)bi->fb.pixels, bi->fb.pitch, bi->fb.red_mask,
                bi->fb.green_mask, bi->fb.blue_mask);
    else
        kprintf("framebuffer: none\n");

    /* The rest is Lisp: the world, made from the files of the boot volume
     * or come whole as an image of one that was saved there, and then
     * whatever is typed, until that ends. */
    lisp_run();
    kprintf("clara: nothing more to do, halting\n");
    arch_halt();
}
