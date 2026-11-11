# ClaraOS

A small operating system for x86_64 and AArch64, written in C to be read and
understood from the first instruction up. It is not a Unix and does not try
to run Linux software. The kernel is its own UEFI application: the firmware
loads `BOOTX64.EFI` or `BOOTAA64.EFI`, and from `efi_main` on it is ClaraOS.

Status: milestone 0. Both architectures boot under QEMU with EDK2 firmware
(the same firmware and machine types UTM uses), take the machine from the
firmware, print the memory map and the ACPI root pointer over serial, and
paint the framebuffer. [ROADMAP.md](ROADMAP.md) has what comes next,
[DESIGN.md](DESIGN.md) the ideas and conventions.

## Building

On macOS with Homebrew. clang cross-compiles both targets as PE/COFF and
lld links them; no GNU toolchain is involved.

    brew install llvm lld qemu
    make              # build/esp/EFI/BOOT/BOOTX64.EFI and BOOTAA64.EFI
    make test         # boot both under QEMU headless and wait for the kernel's last line
    make run-aarch64  # QEMU window, serial on the terminal; hvf-accelerated on Apple silicon
    make run-x86_64   # same, emulated (TCG), so the firmware takes a few seconds
    make image        # build/claraos.img, a GPT + FAT32 raw disk for UTM

Layout:

    kernel/          architecture-independent code and the UEFI handoff (main.c)
    kernel/arch/     one directory per architecture: the only assembly and the only MMIO addresses
    tools/           run.sh (QEMU), boottest.sh (headless check), mkimage.sh (UTM disk)

## Running in UTM

1. `make image`.
2. UTM, New, then Virtualize (AArch64 on Apple silicon) or Emulate (x86_64),
   operating system Other. Skip the ISO. Leave "UEFI Boot" checked. 512 MiB
   of memory is plenty.
3. Remove the drive UTM created. Drives, Import, pick `build/claraos.img`
   (VirtIO or NVMe interface, either works).
4. Add a Serial device with mode "Built-in Terminal": the kernel talks there.
5. Start. The display turns dark with a pink band across the middle and the
   serial window shows the memory map, then `clara: nothing more to do`.

UTM copies the image into the VM bundle, so after a rebuild either import it
again or replace the copy inside the `.utm` bundle (Show Package Contents,
`Data/`). `utmctl start ClaraOS` starts the VM from the terminal.

## License

GPL-3.0, see [LICENSE](LICENSE).
