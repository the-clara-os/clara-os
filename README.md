# ClaraOS

[![CI](https://github.com/the-clara-os/clara-os/actions/workflows/ci.yml/badge.svg)](https://github.com/the-clara-os/clara-os/actions/workflows/ci.yml)

Website: <https://claraos.org>. User manual: <https://claraos.org/manual.html>

A small operating system for x86_64 and AArch64, written in C to be read and
understood from the first instruction up. It is not a Unix and does not try
to run Linux software. The kernel is its own UEFI application: the firmware
loads `BOOTX64.EFI` or `BOOTAA64.EFI`, and from `efi_main` on it is ClaraOS.

Status: milestone 11. Both architectures boot under QEMU with EDK2 firmware
(the same firmware and machine types UTM uses), read their boot files from
the ESP, and take the machine from the firmware. From then on they use
nothing of the firmware's: they run on their own stack, page tables and
exception vectors, and the page-frame allocator has all the free memory
there is. A fault is reported in words, with every register. The interrupt
controller is found through ACPI, and a timer ticks a hundred times a
second. Threads take turns on that tick, sleep, share locks, and wait for
one another or for an interrupt. The Lisp
runtime has its objects, its heap, symbols and packages, a reader, a
printer and an evaluator: an interpreter for a subset of Common Lisp, with
closures, special variables, multiple values, macros, structures and
conditions. A collector frees what nothing can reach any more. Part of
the language is written in Lisp itself, in lisp/boot.lisp, which the
kernel loads as it starts. From there on Lisp is in the driver's seat.
Lisp has threads, each with its own bindings of the special variables,
and locks and events between them. A package for drivers reaches memory
by its address, the I/O ports and the interrupts. The console is a
driver written in Lisp: it sends to the serial port, draws on the screen
and puts together the lines that are typed. The listener, Lisp as well,
reads the forms typed there, evaluates each one and prints what it gives;
a mistake is answered with what went wrong, a computation that does not
end is stopped with Ctrl-C, and the prompt comes back. The devices on the
PCI bus are found and listed, and the ones that speak virtio have drivers,
in Lisp as well: a keyboard, a mouse and a tablet so far, which interrupt
by message through whatever the machine has for that, the local APIC, a
GICv2m frame or the GIC's translation service. What is typed on the
keyboard is read like what arrives on the serial port. A virtio disk has
its driver too, and on it the FAT file system is read and written: the
volume the machine booted from is the first whose files can be listed,
read, loaded, written and deleted from the prompt,
`(directory "/clara/*.lisp")`, `(load "/clara/hello.lisp")` or
`(with-open-file (out "/notes.txt" :direction :output) (write-line "kept" out))`.
And the world can be saved: `(clara:save-image)` writes the heap to a file
on the boot volume, and the next boot starts from that file, with
everything that was defined, and loads no Lisp. Lisp draws: a rasterizer
(lisp/draw.lisp) puts rectangles, text and bitmaps on surfaces, cut to
what a surface has of them, copies one surface to another, and shows on
the screen what has changed of a picture that was made out of sight,
`(clara.draw:fill-rectangle (clara.draw:screen) 40 40 200 120 (clara.draw:color 255 184 108))`
for a start. And there is a window manager (lisp/windows.lisp):
`(clara.windows:start)` takes the screen from the console and puts windows
on it, each a surface that its program draws on, with the focus, the keys
and the pointer going to the one that is picked, a launcher along the top,
and a listener in a window (lisp/terminal.lisp), which is the same world
as the prompt on the serial port. A world that is saved while it runs
boots straight into it. Two applications come with it, a text editor
(lisp/editor.lisp) and a file browser (lisp/files.lisp): each is a file on
the boot volume that the launcher loads when it is first picked, and
unloads again when asked, and `(clara.windows:launch "Editor" "/notes.txt")`
opens a file from a prompt. The same Lisp files load
under SBCL on the host, where they are tested against a machine that is
made up for the purpose.
[ROADMAP.md](ROADMAP.md) has what comes next, [DESIGN.md](DESIGN.md) the
ideas and conventions.

## Building

clang cross-compiles both targets as PE/COFF and lld links them; no GNU
toolchain is involved. On macOS the tools come from Homebrew:

    brew install llvm lld qemu sbcl

On Ubuntu they come from the distribution. That is also where every pull
request is built and booted, by [.github/workflows/ci.yml](.github/workflows/ci.yml):

    sudo apt install clang lld make qemu-system-x86 qemu-system-arm ovmf qemu-efi-aarch64 netcat-openbsd sbcl \
        python3 dosfstools

Then, on either:

    make              # build/esp: EFI/BOOT/BOOTX64.EFI and BOOTAA64.EFI, and the boot files in clara/
    make test         # test the Lisp files under SBCL (lisp/host/tests.lisp), then
                      # boot both headless, each from a disk made for it (tools/mkdisk.py),
                      # type tools/session.txt at each kernel and compare its answers,
                      # wait for the kernel's last line, save build/screen-<name>.png, and have
                      # the host's fsck look at the disk; the session ends by saving the world,
                      # and a second boot from the same disk has to start from it and answer
                      # tools/resumed.txt; AArch64 does all that twice, once for each version of
                      # its interrupt controller, and boots once more with the Lisp collector
                      # running at every chance it has, from a disk whose saved world is damaged;
                      # and what the user manual shows of the prompt is typed at one more machine
    make run-aarch64  # QEMU window, serial on the terminal: type a form in either; Ctrl-C stops a form
                      # that does not end, Ctrl-D ends the session, Ctrl-A X in the terminal leaves QEMU;
                      # hvf-accelerated on Apple silicon. The disk, build/disk-aarch64.img, is kept from
                      # one run to the next, with a world that was saved on it, until the next build
    make run-x86_64   # same, emulated (TCG), so the firmware takes a few seconds
    make image        # build/claraos.img, a GPT + FAT32 raw disk for UTM; needs macOS
    make site         # build/site: the website, which is not built when the manual lacks a name that
                      # the system defines, or when its picture is of another version than the kernel's
    make screenshot   # after make test: site/boot.png, the website's picture, of the screen as it was left

Layout:

    kernel/          architecture-independent code and the UEFI handoff (boot.c)
    kernel/arch/     one directory per architecture: the only assembly and the only MMIO addresses
    kernel/lisp/     the Lisp runtime: objects and the heap, symbols and packages, the reader, the printer
    lisp/            Lisp sources: the language's own part, the console, drawing, the drivers, the file system, the listener,
                     the window manager and the terminal in a window, which the kernel loads as it starts, and
                     the two applications, editor.lisp and files.lisp, which the launcher loads when they are picked;
                     the build copies them to the ESP's \clara directory, read at boot
    fonts/           the console font, Spleen 8x16, which tools/bdf2c.py turns into kernel/font.c
    site/            the website: the front page and the user manual (manual.html), filled in from the
                     repository and held against it by site/build.py (`make site`)
    tools/           run.sh (QEMU), mkdisk.py (the disk a machine boots from), boottest.sh (headless
                     check, typed session and screenshot), session.txt and resumed.txt (what the check
                     types and what must come back, at a new world and at one that was saved),
                     mkimage.sh (UTM disk)

## Running in UTM

The [user manual](https://claraos.org/manual.html) has these steps too, and
what to do at the prompt once it is there.

1. `make image`.
2. UTM, New, then Virtualize (AArch64 on Apple silicon) or Emulate (x86_64),
   operating system Other. Skip the ISO. Leave "UEFI Boot" checked. 512 MiB
   of memory is plenty.
3. Remove the drive UTM created. Drives, Import, pick `build/claraos.img`,
   with the VirtIO interface: that is the disk ClaraOS has a driver for.
   With NVMe the machine still boots, and sees no disk and no files.
4. Add a Serial device with mode "Built-in Terminal": the kernel talks
   there, and a form can be typed there.
5. For a keyboard in the display's own window: UTM gives a machine USB
   devices, which ClaraOS has no driver for, so add virtio's by hand.
   QEMU, Arguments, two new ones: `-device virtio-keyboard-pci` and
   `-device virtio-tablet-pci`.
6. Start. The display and the serial window both show the boot report,
   which ends at a prompt. A form typed in either,
   `(mapcar #'1+ '(1 2 3))` say, is evaluated, and what it gives is printed
   on both. `(directory "/clara/*")` lists the files the system was
   loaded from. Ctrl-C stops a form that does not end, `(loop)` for one,
   and the prompt comes back. Ctrl-D ends it, and the kernel halts with
   `clara: nothing more to do`. `(clara.windows:start)` puts the window
   manager on the display, with a prompt in a window; the tablet of step 5
   is its pointer.
7. `(clara:save-image)` saves the world on the disk. The next start says
   `lisp: the heap is an image` in its report, and whatever was defined is
   there. To start from the Lisp files again, import `build/claraos.img`
   afresh.

UTM copies the image into the VM bundle, so after a rebuild either import it
again or replace the copy inside the `.utm` bundle (Show Package Contents,
`Data/`). `utmctl start ClaraOS` starts the VM from the terminal.

## License

GPL-3.0, see [LICENSE](LICENSE). The console font is Spleen by Frederic
Cambus, under the BSD 2-Clause license in
[fonts/LICENSE.spleen](fonts/LICENSE.spleen).
