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
keyboard is read like what arrives on the serial port. A keyboard, a
mouse and a tablet that hang from a USB controller have drivers as well
(lisp/usb.lisp), which is what UTM gives a machine. A virtio disk has
its driver too, and on it the FAT file system is read and written: the
volume the machine booted from is the first whose files can be listed,
read, loaded, written and deleted from the prompt,
`(directory "/*")`, `(load "/hello.lisp")` or
`(with-open-file (out "/notes.txt" :direction :output) (write-line "kept" out))`.
And the world can be saved: `(clara:save-image)` writes the heap to a file
on the boot volume, and the next boot starts from that file, with
everything that was defined, and loads no Lisp. Lisp draws: a rasterizer
(lisp/draw.lisp) puts rectangles, text and bitmaps on surfaces, cut to
what a surface has of them, copies one surface to another, and shows on
the screen what has changed of a picture that was made out of sight,
`(clara.draw:fill-rectangle (clara.draw:screen) 40 40 200 120 (clara.draw:color 255 184 108))`
for a start. Text is drawn in the console's font or in a font of outlines,
at any size (lisp/type.lisp): `(clara.type:font "Sans" 24)` is one, of
the Go fonts that come with the system, read from their TrueType files
and made into pictures in which a pixel at the edge of a letter takes a
part of the colour. And there is a window manager (lisp/windows.lisp):
`(clara.windows:start)` takes the screen from the console and puts windows
on it, each a surface that its program draws on, with the focus, the keys
and the pointer going to the one that is picked, a launcher along the top,
and the REPL, a listener in a window (lisp/terminal.lisp), which is the
same world as the prompt on the serial port. A world that is saved while it runs
boots straight into it. Three applications come with it, Emma, a text editor
(lisp/emma.lisp), Jaid, a file browser (lisp/jaid.lisp), and Ares, a web
browser (lisp/ares.lisp): each is a file on the boot volume that the
launcher loads when it is first picked, and unloads again when asked, and
`(clara.windows:launch "Emma" "/notes.txt")` opens a file from a prompt.
Ares shows what a page of the web says, its text, headings, lists, tables
and links, in the system's own letters, and goes where the links lead:
`(clara.windows:launch "Ares" "claraos.org")`. It asks for every page by
HTTPS, reads a page by the rules that browsers read one by, and fetches no
pictures, runs no scripts and reads no style sheets. And there is a compiler, written in Lisp
(lisp/compiler.lisp), which everything goes through: what is typed at a
prompt or loaded from a file is compiled before it runs, and so are the
console, the file system, the window manager, the applications and the
compiler itself, which it compiles when a machine starts from the files.
What it makes are instructions for a small machine in the kernel, which
`(disassemble 'name)` shows, and those are translated once more, into the
instructions of the processor itself, AArch64's or x86-64's
(lisp/native.lisp, and lisp/arm64.lisp or lisp/x86-64.lisp), so that the
processor runs a function with nothing in between: what is typed, and the
world from the language's own functions to the window manager, which
translates itself when a machine starts from the files. That is some ten
times as quick as the kernel's machine where the time goes into calls and
arithmetic. The evaluator is still there to run the compiler until it has
compiled itself, and the kernel's machine to do what the processor's code
leaves to it, and every such start holds the three against each other.
And the machine is shut down by asking it (lisp/system.lisp):
`(clara.system:shut-down)` at a prompt, `Shut Down` in the launcher's
list, or the power button that a host presses. It asks the windows whether
something would be lost, saves the world, has the disks keep what they
were given, and turns itself off; `(clara.system:start-again)` starts it
again instead, in the world that it saved. A newer ClaraOS is put on the
disk by the one that is running: `(clara.system:upgrade)` takes the system
that another disk of the machine holds, into a directory of its own beside
the one that runs, and starts the machine again to try it. The old system
stays until the new one has come to its prompt, and is what the machine
starts as when the new one does not; the files that were written stay
where they are. What was defined at a prompt comes across too: each form
that defines something is written down as it is typed, in
`/home/defined.lisp`, and a world that is made from the files loads that
file after `/home/init.lisp`, which is the user's to write. The system
that is leaving also writes down what its variables had come to, as far
as that is text, and the one that comes gives those values back, saves
the world that it made, and says by name what did not come across;
`(clara.system:report)` says it again. And a newer ClaraOS can be fetched:
there is a network (lisp/net.lisp), a driver for virtio's network card
with ARP, IPv4, UDP, DHCP, DNS, TCP and HTTP over it, as far as fetching a
file takes, and HTTPS (lisp/tls.lisp): TLS 1.3, with certificates held
against the authorities that sign for the web,
`(clara.net:fetch-text "https://claraos.org/")`. The newest ClaraOS is
published at `https://claraos.org/releases/`, built and signed each time
a change is merged, and `(clara.system:upgrade)` takes it from there when
no other disk of the machine holds a system: when it is newer than the
one that runs, its manifest is signed with the key that the system has
(Ed25519, checked in the kernel), and every file is what the manifest
says. `:from "https://.../"` names another place. What a connection is kept closed with is in the kernel too,
each piece held against the examples of its standard at every boot.
And something can be added to a system that runs (lisp/parker.lisp): a
package is a name, a version and files of Lisp, some of which are loaded
when it is installed and some of which are applications for the
launcher's list. Packages are published as the system is, and beside it,
at `https://claraos.org/packages/`: an index of what there is, signed
with the key of the releases, and the files, each of which a machine
holds against the index. Parker, an application in the launcher's list,
shows what is installed and what can be had, and installs the package
that is picked; `(clara.parker:install "sun")` does the same at a prompt.
What is installed is a directory of the disk, which an upgrade leaves
alone, and every world that is made from the files loads it.
And the machine plays sound (lisp/sound.lisp): a driver for virtio's sound
card and one for Intel's (lisp/hda.lisp), and a thread that adds up what
is sounding, a hundredth of a second at a time. `(clara.sound:tone 440 500)` is a tone, of one of five shapes;
`(clara.sound:play '(c4 e4 g4 (c5 2)))` plays notes by their names, one
after the other or several together; and `(clara.sound:play-file
"/home/chime.wav")` plays a file of sound. All of it is worked out in
whole numbers, and all of it is Lisp.
Common Lisp's object system is there (lisp/clos.lisp): `defclass` for
classes whose instances have slots, `defgeneric` and `defmethod` for
functions that are put together from methods, each for arguments of some
classes, with `call-next-method` and the methods that run before, after
and around. A class can be a kind of several, an instance is written by
a method of `print-object`, and a class that is defined again takes its
instances with it. It is Lisp too, held against SBCL's own object system
form for form.
The same Lisp files load
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
                      # each kind of processor starts once more to be shut down, started again and
                      # turned off by its power button (tools/power.txt); a machine of each kind takes
                      # another system from a second disk and has to come up as it, and one takes a
                      # system that does not start and has to be the old one again (tools/upgrade.txt,
                      # tools/at-once.txt, tools/trial.txt); one installs a package from a web server
                      # on this computer, fetches a signed release of another system from it, and has to
                      # come up as that system with the package in its world (tools/network.txt,
                      # tools/serve.py);
                      # and what the user manual shows of the prompt is typed at one more machine,
                      # which has a second disk, as WORK= below gives one
    make run-aarch64  # QEMU window, serial on the terminal: type a form in either; Ctrl-C stops a form
                      # that does not end, (clara.system:shut-down) saves the world and turns the
                      # machine off, which ends QEMU, and Ctrl-A X in the terminal leaves QEMU as it is;
                      # hvf-accelerated on Apple silicon. The disk, build/disk-aarch64.img, is made once
                      # and kept, with the files and the world on it; a newer build goes to the machine
                      # as a second disk, and the system on the disk takes it as it starts. The machine
                      # has a network card on a network that QEMU makes up, through which it reaches
                      # this computer at 10.0.2.2 and whatever this computer reaches (NET= for none)
    FRESH=1 make run-aarch64
                      # the same with a new disk; the one that was there is kept under another name
    make run-x86_64   # same, emulated (TCG), so the firmware takes a few seconds
    WORK=~/clara-work.img make run-aarch64
                      # the same machine with a second disk, which is yours alone:
                      # the manual's "A disk of your own" says how to make one and how to reach it
    make image        # build/claraos.img, a GPT + FAT32 raw disk for UTM; needs macOS
    make site         # build/site: the website, which is not built when the manual lacks a name that
                      # the system defines, or when its picture is of another version than the kernel's
    make screenshot   # after make test: site/boot.png, the website's picture, of the screen as it was left
    make release KEY=my.key RELEASES=releases
                      # the build as a release in that directory, signed with the key in that file: what the
                      # website's workflow publishes at https://claraos.org/releases/, with the project's key;
                      # with PACKAGES=<a directory> the packages of packages/ are laid out there as well,
                      # with their index and its signature, which is what https://claraos.org/packages/ has

Layout:

    kernel/          architecture-independent code and the UEFI handoff (boot.c)
    kernel/arch/     one directory per architecture: the only assembly and the only MMIO addresses
    kernel/lisp/     the Lisp runtime: objects and the heap, symbols and packages, the reader, the printer,
                     the evaluator, and the machine that compiled code runs on (vm.c)
    lisp/            Lisp sources: the language's own part, the compiler, the object system, the console, drawing, the drivers, the
                     file system, the fonts, the network, sound, the listener, the window manager, the terminal in a window and Parker, which installs packages,
                     all of which the kernel loads as it starts, and the three applications, emma.lisp, jaid.lisp and ares.lisp, which the launcher loads when they are picked;
                     the build copies them to the system's directory on the ESP, \clara\<its name>, read at boot
    fonts/           the console font, Spleen 8x16, which tools/bdf2c.py turns into kernel/font.c, and the
                     fonts of outlines, the Go fonts, which go onto the boot volume as they are
    packages/        the packages that https://claraos.org/packages/ has, a directory each: the package's
                     files, and a file "package" that says what it is (the manual, "A package of your own")
    site/            the website: the front page and the user manual (manual.html), filled in from the
                     repository and held against it by site/build.py (`make site`)
    tools/           run.sh (QEMU), mkdisk.py (the disk a machine boots from), system.py (the name of a build
                     and the list of its files), boottest.sh (headless check, typed session and
                     screenshot), session.txt and resumed.txt (what the check types and what must come
                     back, at a new world and at one that was saved), power.txt, upgrade.txt, at-once.txt,
                     trial.txt and network.txt (the same for shutting down and for upgrades), serve.py (the
                     web server that a boot fetches from), pages/ (the pages that it has for the browser), release.py (a key, a signature, a system
                     laid out as a release, and packages laid out with their index), heard.py (what a machine played, from the file that QEMU wrote
                     of it), mkimage.sh (UTM disk), fontcheck.c (what FreeType says of a
                     font file, for the tests of lisp/type.lisp; built by hand, and no part of `make test`),
                     pagecheck.py (what Chrome makes of a page, for the tests of lisp/ares.lisp: the trees of
                     lisp/host/pages.lisp; run by hand, and no part of `make test` either)

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
5. The keyboard and the pointer need nothing done on a machine that is
   virtualized on Apple silicon: UTM gives it a USB controller with a
   keyboard, a mouse and a tablet, which ClaraOS has drivers for. A
   machine that is emulated as x86_64 gets a USB controller of an older
   kind, which it has none for: there, QEMU, Arguments, two new ones,
   `-device virtio-keyboard-pci` and `-device virtio-tablet-pci`.
6. Sound needs nothing done either: the card that UTM picks by itself,
   one of Intel's, has a driver, and so has Virtio Sound.
7. Start. The display and the serial window both show the boot report,
   which ends at a prompt. A form typed in either,
   `(mapcar #'1+ '(1 2 3))` say, is evaluated, and what it gives is printed
   on both. `(clara.fat:names (clara.system:system-file ""))` lists the
   files the system was loaded from. Ctrl-C stops a form that does not end, `(loop)` for one,
   and the prompt comes back. `(clara.windows:start)` puts the window
   manager on the display, with a prompt in a window; the tablet of step 5
   is its pointer. `(clara.sound:beep)` is heard with the card of step 6. `(clara.system:shut-down)` saves the world and turns
   the machine off, and so should UTM's Request power down, which presses
   the machine's power button.
7. `(clara:save-image)` saves the world on the disk. The next start says
   `lisp: the heap is an image` in its report, and whatever was defined is
   there. To start from the Lisp files again,
   `(delete-file "/clara/clara.image")`.

UTM copies the image into the VM bundle, and that copy is the machine's
disk from then on. To put a newer ClaraOS on it, add the newer
`build/claraos.img` as a second VirtIO drive, start the machine and say
`(clara.system:upgrade)`: the manual's chapter "A newer ClaraOS" has the
steps. `utmctl start ClaraOS` starts the VM from the terminal.

## License

GPL-3.0, see [LICENSE](LICENSE). The console font is Spleen by Frederic
Cambus, under the BSD 2-Clause license in
[fonts/LICENSE.spleen](fonts/LICENSE.spleen). The fonts of outlines are
the Go fonts by Bigelow & Holmes, under the BSD 3-Clause license in
[fonts/LICENSE.go](fonts/LICENSE.go).
