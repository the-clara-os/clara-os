# ClaraOS design

## What it is for

A system small enough for one person to hold in their head, running on the
two machines at hand: Apple silicon (AArch64, virtualized in UTM) and x86_64
(emulated in UTM). It should read well from top to bottom. It is not a Unix,
not POSIX, and does not aim to run existing software.

## Decided

- UEFI only, on both architectures. No BIOS path, no multiboot, no separate
  bootloader: the kernel is the EFI application (`efi_main` in kernel/main.c)
  and ExitBootServices is the moment the machine becomes ours.
- One source tree, one toolchain. clang and lld targeting `*-unknown-windows`
  produce the PE/COFF images the firmware wants. Architecture-specific code
  lives under kernel/arch/<arch>/ behind the few `arch_*` functions declared
  in kernel/kernel.h; everything else compiles for both.
- Serial first. Every milestone is observable on the serial port before
  anything is drawn, and the boot test reads the serial log.
- The firmware describes the hardware. ACPI tables on both architectures
  (EDK2 exposes ACPI, not a device tree, on the virt machine), PCIe for
  device discovery, virtio for the first drivers.
- Tests are boots. `make test` boots both architectures headless; no
  milestone lands without it passing on both.
- C11, freestanding, no libc, `-Wall -Wextra -Werror`. The targets are LLP64,
  so `long` is 32 bits: the kernel uses the stdint types and never `long`.

## Not decided: the shape of the system

This is the choice that makes it not Linux, and it has not been made. The
options on the table, from most to least conventional:

1. **Capability microkernel.** The kernel owns address spaces, threads, IPC
   and capabilities; drivers and filesystems are servers. L4/seL4 lineage.
   Well understood; the IPC design dominates everything else.
2. **Single address space.** One flat space with protection domains, cheap
   sharing by pointer, no copying between programs. Oberon, Singularity and
   Theseus lineage. Simple and fast, but leans on discipline that C does not
   enforce.
3. **Lisp substrate.** The C kernel is a substrate (memory, scheduling,
   devices, a tiny evaluator); the system language, the shell and most of
   what a user touches is Lisp living in the image. Lisp machine lineage.
4. **Exokernel.** The kernel only multiplexes hardware safely; each program
   links the abstractions it wants as a library.

Milestones 0 to 5 (boot, console, memory, interrupts, timers, threads) are
needed under all four and come first. The decision is due before user mode.

## Conventions

- lower_snake_case for functions and files. Kernel-wide symbols carry their
  subsystem as a prefix: `kprintf`, `fb_fill`, `arch_halt`.
- Comments say why, or what the hardware requires. The code says what.
- One C struct per hardware or firmware table, laid out as the specification
  says, with a comment on any padding or reserved slot that matters.
- Numbers from specifications cite the document when they are not obvious.
- No early abstraction: write it for one architecture, make it work on the
  second, then extract the shared interface.
