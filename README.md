# ClaraOS

Website: <https://the-clara-os.github.io/clara-os/>

A small operating system for x86_64 and AArch64, written in C to be read and
understood from the first instruction up. It is not a Unix and does not try
to run Linux software. The kernel is its own UEFI application: the firmware
loads `BOOTX64.EFI` or `BOOTAA64.EFI`, and from `efi_main` on it is ClaraOS.

Status: milestone 3. Both architectures boot under QEMU with EDK2 firmware
(the same firmware and machine types UTM uses), read their boot files from
the ESP, take the machine from the firmware, and run on their own stack and
their own page tables, with a page-frame allocator built from the
firmware's memory map. A text console on the serial port and on the screen
reports each step.
[ROADMAP.md](ROADMAP.md) has what comes next, [DESIGN.md](DESIGN.md) the
ideas and conventions.

## Building

On macOS with Homebrew. clang cross-compiles both targets as PE/COFF and
lld links them; no GNU toolchain is involved.

    brew install llvm lld qemu
    make              # build/esp: EFI/BOOT/BOOTX64.EFI and BOOTAA64.EFI, and the boot files in clara/
    make test         # boot both headless, wait for the kernel's last line, save build/screen-<arch>.png
    make run-aarch64  # QEMU window, serial on the terminal; hvf-accelerated on Apple silicon
    make run-x86_64   # same, emulated (TCG), so the firmware takes a few seconds
    make image        # build/claraos.img, a GPT + FAT32 raw disk for UTM

Layout:

    kernel/          architecture-independent code and the UEFI handoff (boot.c)
    kernel/arch/     one directory per architecture: the only assembly and the only MMIO addresses
    lisp/            Lisp sources; the build copies them to the ESP's \clara directory, read at boot
    fonts/           the console font, Spleen 8x16, which tools/bdf2c.py turns into kernel/font.c
    site/            the website: one page, filled in from ROADMAP.md by site/build.py (`make site`)
    tools/           run.sh (QEMU), boottest.sh (headless check and screenshot), mkimage.sh (UTM disk)

## Running in UTM

1. `make image`.
2. UTM, New, then Virtualize (AArch64 on Apple silicon) or Emulate (x86_64),
   operating system Other. Skip the ISO. Leave "UEFI Boot" checked. 512 MiB
   of memory is plenty.
3. Remove the drive UTM created. Drives, Import, pick `build/claraos.img`
   (VirtIO or NVMe interface, either works).
4. Add a Serial device with mode "Built-in Terminal": the kernel talks there.
5. Start. The display and the serial window both show the boot report,
   which ends with `clara: nothing more to do`.

UTM copies the image into the VM bundle, so after a rebuild either import it
again or replace the copy inside the `.utm` bundle (Show Package Contents,
`Data/`). `utmctl start ClaraOS` starts the VM from the terminal.

## License

GPL-3.0, see [LICENSE](LICENSE). The console font is Spleen by Frederic
Cambus, under the BSD 2-Clause license in
[fonts/LICENSE.spleen](fonts/LICENSE.spleen).
