# Roadmap

Each milestone is sized for one working session. A milestone is done when
`make test` passes on both architectures and this file says so. The shape
(DESIGN.md: a C substrate under a Lisp world, booting into a window manager)
was decided on 2026-11-11 and the milestones below follow from it.

Every finished piece of work, a milestone or an infrastructure item, bumps
the patch version (`CLARA_VERSION` in kernel/kernel.h), and its entry here
records the version it shipped as.

Substrate:

- [x] **M0 boot** (2026-11-11, version 0.0.1). Kernel as the UEFI application on both
  architectures; ExitBootServices with the memory-map retry; memory map,
  ACPI RSDP and GOP framebuffer captured; serial output (COM1, PL011);
  `kprintf`; QEMU run and headless test scripts; GPT/FAT32 image for UTM.
- [x] **M1 console** (2026-11-12, version 0.0.2). Spleen 8x16 bitmap font, converted from
  BDF by tools/bdf2c.py; a text console on the framebuffer (kernel/fbcon.c)
  that mirrors the serial port, with wrapping, tabs, three colours and
  scrolling that repaints only the cells that changed; `panic()`; any GOP
  pixel layout, through colour masks; `kprintf` arguments checked by the
  compiler; `make test` saves a screenshot of each architecture.
- [x] **M2 physical memory** (2026-11-12, version 0.0.3). A page-frame
  allocator built from the EFI map (kernel/pmm.c): one bit per 4 KiB frame,
  runs of adjacent frames on request, a self-test on every boot. `kmain`
  starts on a stack inside the kernel image; the memory-map snapshot is as
  large as the firmware says it must be; the handoff has its own file,
  kernel/boot.c. Every file in the ESP's `\clara` directory is read through
  the UEFI file protocol before ExitBootServices, lisp/boot.lisp being the
  first, for M6. Boot-services memory is counted but not reclaimed: that
  moved to M4, because the processor was still running on what the
  firmware had left in it.
- [x] **M3 virtual memory** (2026-11-12, version 0.0.4). The kernel's own
  page tables on both architectures, in 4 KiB pages: the walk in
  kernel/vm.c, the entry formats and the switch in
  kernel/arch/<arch>/mmu.c. RAM is mapped at its own address, and so are
  the screen and the device registers in use, each by name. The first
  megabyte is never mapped, and 64 TiB starting at 64 TiB are reserved for
  the Lisp heap. The kernel image is mapped section by section from its own
  PE headers: code cannot be written, data cannot be run. A guard page lies
  under the boot stack. The firmware's tables are out of use. The image was
  to be mapped high and is not: DESIGN.md, "The address space", says why.
- [x] **M4 exceptions and interrupts** (2026-11-13, version 0.0.6). The
  kernel's own exception vectors on both architectures, in place before
  anything else: a GDT, a TSS and an IDT on x86_64, a vector table at EL1
  on AArch64 (kernel/arch/<arch>/exception.c, entered through entry.S). A
  fault the kernel cannot survive is reported on the serial port and on
  the screen: what happened, in words, where in the kernel image, and
  every register. A stack overflow is reported like any other fault: on
  x86_64 a double fault has a stack of its own, and on AArch64 the kernel
  proper runs on SP_EL0 and every handler on SP_EL1. With the vectors and
  the page tables its own, the kernel takes boot-services memory into the
  page-frame allocator, overwriting it first, and no RAM can be run except
  the kernel image. Every boot provokes nine faults on purpose and checks
  how each one is reported (kernel/fault.c). The ACPI tables are read
  (kernel/acpi.c): the MADT for the local APIC and the I/O APICs on
  x86_64 and for the GIC on AArch64, version 2 or 3, and the GTDT for the
  timer's interrupt. A timer interrupts a hundred times a second on both,
  the local APIC's on x86_64, measured against the 8254, and the generic
  timer on AArch64 (kernel/arch/<arch>/interrupt.c, kernel/timer.c).
- [x] **M5 threads** (2026-11-14, version 0.0.7). Threads that take turns
  on the one processor (kernel/thread.c). A thread that is not running is
  the registers the exception entry saved for it, and a switch exchanges
  them for another thread's on the way out of an interrupt, so M4's entry
  code is all the switching code there is; a thread that has to wait
  raises an exception of its own to get there. A queue of the threads that
  are ready, a turn that lasts one tick, and an idle thread for when none
  can run. Sleep is counted in ticks, and the tick wakes the sleepers.
  Every thread has 64 KiB of stack over a guard page, and a fault report
  names the thread it happened in. Locks that queue their waiters: the
  page-frame allocator, the page tables and the console have one each.
  Stop-the-world for the collector: safe points, and a call that returns
  once every other thread is at one. Every boot sends three threads
  through all of it and stops the world under them.

The Lisp runtime, in the substrate:

- [x] **M6a objects and reader** (2026-11-14, version 0.0.8). The first
  part of the Lisp runtime, in kernel/lisp/. A Lisp value is a tagged
  64-bit word: a fixnum of 63 bits, a character, or the address of an
  object in the heap, with a tag of their own for conses and for symbols.
  Every object begins with a header word, so the heap can be walked from
  end to end; it lies in the region reserved for it, begins with NIL, and
  grows a page frame at a time (heap.c). Symbols live in packages, each
  with its internal and its external symbols: KEYWORD, COMMON-LISP and
  COMMON-LISP-USER are there from the start (symbol.c). A string holds
  Unicode code points, and text outside the heap is UTF-8. The reader
  (read.c) takes Common Lisp's syntax for lists, symbols with their
  packages and escapes, integers, strings, characters, vectors, quotes and
  comments, and refuses what this Lisp has no objects for yet, floats and
  ratios among them. The printer (print.c) writes what the reader reads
  back as the same object. The serial port is read as well as written:
  the kernel ends its boot by reading the forms typed there and printing
  each one back, until Ctrl-D. Every boot reads and prints some hundred
  texts, has some seventy refused, and walks the heap; `make test` types a
  session at each machine and compares the answers (tools/session.txt).
- [x] **M6b evaluator** (2026-11-14, version 0.0.9). The interpreter, in
  kernel/lisp/eval.c: it walks the forms as the reader made them. Thirty
  special forms, Common Lisp's own and the ones that define (`defun`,
  `defmacro`, `defvar` and their kin); lambda lists with optional, rest,
  keyword and auxiliary parameters, and in macros with lists that take an
  argument apart; closures over environments that live in the heap;
  special variables, bound in the symbol and put back on the way out;
  multiple values; `block`, `tagbody` and `catch`, with every non-local
  exit made by returning, never by jumping; macros, expanded once at each
  place, and backquote, which the reader now reads. An error says what
  went wrong, in words, and comes back to the prompt. An integer that
  leaves 63 bits is an error, not a wrong number. Some hundred functions
  in C (builtin.c), and the rest of the language in Lisp: lisp/boot.lisp,
  loaded from the ESP at startup, brings `cond`, `dolist`, `setf`,
  `defstruct`, `defpackage`, the list functions and their like. The Lisp
  world has a thread of its own with a megabyte of stack, and the
  evaluator stops a function that calls itself without end a few thousand
  calls deep. What it holds it keeps on a stack of its own, where M6c's
  collector will find it. Every boot evaluates two hundred texts and
  checks the answers, and the serial port evaluates what is typed.
- [x] **M6c collector and conditions** (2026-11-15, version 0.0.10). The
  collector, in kernel/lisp/heap.c: it marks every object that can be
  reached from what the substrate and the evaluator hold, exactly those,
  and sweeps the heap from end to end, with every other thread stopped.
  What it frees becomes free blocks, which the next objects go into; the
  heap ends where its last object does, and the page frames past that go
  back to the kernel. It runs at the evaluator's safe points, when enough
  has been made since the last time, and never inside an allocation. Freed
  memory is filled with a value that faults when it is followed, and what
  was used after it was freed is refused by the collector and by the
  allocator. An error is a condition now, an object with a type:
  `handler-case` takes the conditions that a clause names the type of,
  `unwind-protect` cleans up on every way out, `error`, `signal` and `warn`
  signal them, `define-condition` makes new types, and the substrate's own
  errors have Common Lisp's types where a program would tell them apart. A
  computation that fills the heap is stopped with an error, and Ctrl-C on
  the serial port stops one that does not end; the prompt comes back after
  either. A thread that comes to a safe point with a lock in its hands is
  a panic. Every boot puts the collector through 70000 objects and
  evaluates some 260 texts, and `make test` boots once more with a
  collection at every safe point of the evaluator.
- [x] **M7 Lisp in the driver's seat** (2026-11-15, version 0.0.11). Lisp
  threads over substrate threads (kernel/lisp/thread.c): each has the
  evaluator's stacks to itself and its own bindings of the special
  variables, one of them at a time has the runtime, and a turn ends at a
  safe point once a tick has gone by. Locks, events, `join-thread`,
  `destroy-thread` and `sleep`, under the names of Bordeaux Threads, in the
  package CLARA; a thread or an interrupt handler can end another thread's
  wait (`thread_wait`, `thread_wake`). The package CLARA.UNSAFE
  (unsafe.c): memory by its address, the I/O ports, page frames for a
  driver, and an interrupt as an event that a thread waits for, the timer's
  and the serial port's so far. Streams, in lisp/boot.lisp: the printer
  makes strings, and a stream is where they go. The console is Lisp
  (lisp/console.lisp): it sends to the UART through ports on one machine
  and memory on the other, draws the font on the framebuffer, and puts the
  lines together that are typed; the listener is Lisp too
  (lisp/listener.lisp). The substrate's console keeps the boot report and
  the kernel's last words, and the two hand the screen to each other.
  `read-from-string`, `#+` and `#-`. The same files load under SBCL, where
  lisp/host/ stands in for the machine, and `make test` begins with some
  five hundred checks of them there before it boots.

Devices and storage:

- [x] **M8 PCIe and virtio** (2026-11-16, version 0.0.12). The PCI bus, in
  Lisp (lisp/pci.lisp): the configuration space is where the ACPI MCFG
  table says, and every device on the first bus and behind its bridges is
  found and listed. A device's registers are mapped where they are, by a
  function of CLARA.UNSAFE. Devices interrupt by message (MSI-X) and never
  by a line: the substrate hands a driver an event, an address and a
  number (kernel/interrupt.c), from whichever of three controllers the
  machine has, the local APIC on x86_64, a GICv2m frame or the GIC's
  interrupt translation service on AArch64, and the interrupts' handlers
  are a table. The virtio transport of version 1 (lisp/virtio.lisp): the
  opening moves, and queues of buffers that driver and device share. On
  it, the driver for virtio's input devices (lisp/input.lisp): a thread
  for each device, the keys of a US keyboard as characters, with Shift,
  Ctrl, Caps Lock and keys that repeat while they are held, and one
  pointer that mice and tablets move. The console reads the keyboard along
  with the serial port, and shows a cursor while it reads a line. Page
  frames can be asked for at an aligned address. `make test` types on the
  keyboard and moves the mouse through QEMU's monitor, on four machines
  that take messages in the three ways, and the host tests put a PCI bus
  and a virtio device of their own making in front of the drivers.
- [x] **M9 disk and files** (2026-11-17, version 0.0.13). The driver for
  virtio's block devices (lisp/disk.lisp): a disk is a row of sectors of
  512 bytes, read and written a request at a time, into and out of page
  frames, by a thread that waits for the device's interrupt. The FAT file
  system, as far as reading it (lisp/fat.lisp): its volumes are found on a
  disk that is one from end to end, in a table of partitions of the old
  kind and in a GUID partition table; its tables of 12, 16 and 32 bits;
  directories with their long names, which are UTF-16, and their short
  ones; a file by its name, a string with a slash before each part, in
  letters of either case. So the volume that the firmware boots from is
  the first whose files can be seen. The language has files
  (lisp/boot.lisp): `open` and `with-open-file` to read one a line at a
  time, `probe-file`, `directory` with `*` in its pattern, and `load`,
  which takes a file from the disk when the file system has it and from
  what the boot handoff read when not; a file system says that it is there
  with `clara:provide-files`. An error in a file that is loaded says the
  file and the line, also when something handles it. `sort`,
  `string-equal` and `string-lessp`; text in memory becomes a string in
  one call. The machines of `make test` boot from a virtio disk on both
  architectures and have a second, empty one that the session writes to
  and reads back; the host tests put disks and volumes of their own
  making, of every kind and layout, in front of the two drivers, and a
  disk there looks at how it is asked.
- [x] **M10 images** (2026-11-17, version 0.0.14). The FAT file system is
  written as well as read (lisp/fat.lisp): a file goes whole into clusters
  that are free, the table chains them in every copy that a volume keeps of
  it, and an entry in a directory names the file, by a short name or, where
  that will not do, by a long one with a short one to stand in for it. A
  file takes the place of another, a directory grows when it is full, and a
  file can be deleted. The language writes files (lisp/boot.lisp): `open`
  for output, with `:if-exists`; `with-open-file`, which makes the file when
  its body ends and not when it fails; and `delete-file`. The world is saved
  (`clara:save-image`, kernel/lisp/image.c): the heap as it is at one
  moment, with what the substrate holds of it, goes into
  `\clara\clara.image` on the boot volume, and a machine that finds that
  file as it starts takes it for its heap and loads no Lisp. The console,
  the drivers and the listener start afresh, in a world where everything
  that was defined is defined. Threads do not come back, a lock that was
  held is free, and a special variable has the value it had outside every
  binding. An image outlives its kernel: the functions in C are found again
  by their names. One that is not whole, that comes from the other
  architecture, or that this kernel cannot run is refused, with the reason,
  and the world is made from the files. `string-upcase` and its kin, and a
  function that takes any number of arguments takes more than 255. The
  machines of `make test` boot from disks of their own, which
  tools/mkdisk.py makes, one of each kind of FAT, and each boots a second
  time from what its first boot saved; the host's own checker of FAT volumes
  looks at every disk that a kernel has written to, and the host tests at
  every volume with a checker of their own, also after a disk that stopped
  at each request of a write in turn.

The world:

- [x] **M11 drawing** (2026-11-17, version 0.0.16). A rasterizer, in Lisp
  (lisp/draw.lisp). It draws on surfaces, rectangles of pixels in memory:
  the screen is one, and a program makes others, of page frames.
  Rectangles, filled and in outline; text, in the console's font; pictures
  of one bit to the pixel; and copies, from one surface to another or
  within one, where the two parts may lie over each other. All of it is cut
  to what the surface has, and to the part of it that drawing is kept to
  for the time being, so what lies outside is not drawn and is no error. A
  surface remembers what was drawn on it, as a few rectangles that are
  joined where two make one, and showing it copies those to the screen and
  nothing else: a picture is put together out of sight, and seen when it is
  whole. A colour becomes a pixel by the masks that the firmware gave for
  the screen. The pixels are written by the substrate, a rectangle to the
  call: CLARA.UNSAFE has a function that fills one and a function that
  copies one, and the one that draws a glyph can leave the pixels around
  the glyph as they are and pass over its right-hand end. A surface that
  came back with a saved world is refused, its pixels having stayed behind.
  The host tests look at every pixel of each operation, at every place on a
  surface and around it, against a rule of their own, and every machine of
  `make test` draws a picture, reads its screen back, and draws the picture
  again from the world that it saved. The picture on the website is that
  screen: it carries the version it shows, and the site is not built from
  one of another version. The manual lists what every package of the world
  exports, held against the files.
- [x] **M12 the window manager** (2026-11-18, version 0.0.17). Windows
  (lisp/windows.lisp): each is a surface that its program draws on, in a
  frame with its title, and they lie over one another on a desk. The
  screen is put together out of sight, the desk, the windows from the
  lowest up, the launcher's list and the pointer over them all, and only
  the rectangles that have changed are put together again and copied to
  it. The window on top has the focus: what is typed goes to it, a click
  brings a window to the top, its title is where it is taken hold of and
  moved, and the box at the end of the title closes it. The keyboard and
  the pointer reach the window manager as calls from their drivers, a
  character or a change at a time, and a window is told of its keys, of
  the buttons on its inside and of its close box by functions that it was
  opened with. A launcher along the top of the screen lists the
  applications that are defined and starts the one that is picked, in a
  thread of its own, whose windows are closed when it ends. The first
  application is the listener in a window (lisp/terminal.lisp): a
  terminal, which is a window with cells and a stream, and the console's
  own listener reading from it, a thread to the window and one world for
  them all. Ctrl-C in a window stops what that window computes: any
  thread can be interrupted the way the one at the serial port is
  (`clara:interrupt-thread`). The console lends the screen, goes on with
  the serial port, and has the screen back when the window manager stops.
  A world that is saved while the window manager runs boots straight into
  it. `lisp-implementation-type` and `lisp-implementation-version` say
  what the system is, which the launcher's bar shows. Found on the way and
  mended: values that left a loop by RETURN lost all but the first of
  them. The host tests hold every pixel of the screen against a rule of
  their own after everything that is done to it, and every machine of
  `make test` types into a window on QEMU's keyboard, moves, launches and
  closes with QEMU's mouse, saves the world there, and starts again in the
  window manager, whose screen is the picture on the website.
- [x] **M13 applications** (2026-11-18, version 0.0.18). A text editor
  (lisp/editor.lisp) and a file browser (lisp/files.lisp), the first two
  applications after the listener. Neither is part of the world that the
  kernel loads: each is a file on the boot volume that the launcher lists
  by a name, loads when it is first picked, in the thread that is to run
  it, and unloads again when asked, which stops it wherever it runs and
  deletes the packages that its file made; the next launch loads the file
  as it is by then. Any file can be installed that way, and an application
  is launched with arguments, which is how the browser opens a file in the
  editor. The editor keeps a text as its lines around the cursor's, reads
  and writes files whole through the language, moves by the arrows, Home,
  End and the page keys and by a click, cuts lines and puts them back, and
  evaluates its text as LOAD would, in a thread that Ctrl-C stops. The
  browser lists a directory, goes into directories and back, opens files
  and deletes them. Both draw a window of cells a row at a time, and only
  the rows that changed. What they stand on is new as well: the keys that
  type no character, the arrows and the function keys among them, reach
  whoever has the keyboard, as codes past the last that a character can
  have, and Alt with a key adds to its code; a window can keep what happens
  to it, keys, buttons and its close box, for its program to take in a
  thread of its own (`next-event`); a window can be given another title;
  Alt and Tab brings each window to the top in turn. The language has
  `destructuring-bind`, `delete-package`, `list-all-packages` and
  `char-code-limit`, and LOAD finds a file of `\clara` by its whole name
  on a machine that has no disk to read it from. The boot that has the
  collector run at every safe point does its work before the world is
  loaded, where a collection is short, when a file on its volume asks for
  it. The host tests hold every cell of both windows against a rule of
  their own, and the editor against a second editor that is written there
  the slow way, over 700 keys as they come; every machine of `make test`
  types a file into the editor on QEMU's keyboard, places the cursor with
  its mouse, saves, evaluates, opens that file from the browser, unloads
  the editor, installs an application from a file that it wrote, and ends
  its second boot with the editor and the browser on the screen, which is
  the picture on the website.

The compiler:

- [x] **M14a the compiler** (2026-11-18, version 0.0.19). A compiler,
  written in Lisp (lisp/compiler.lisp), and the machine that runs what it
  makes, in the substrate (kernel/lisp/vm.c). `compile` makes a function
  that the evaluator walks the forms of into one that the machine carries
  out instruction by instruction: every variable in a slot that is known
  by its number, no frame in the heap for a binding, a loop a jump. It
  means what it meant: the whole language is compiled, every special form,
  lambda lists with all their kinds of parameters, closures, special
  variables, several values, the non-local exits and the conditions, and
  compiled functions and the evaluator's call one another, with an exit, a
  THROW or a condition passing through both. A compiled function is three
  or four times as quick where it counts and calls, and can call itself
  twice as deep. `disassemble` lists its instructions, `compiled-function-p`
  and `function-lambda-expression` say what a function is, `time` how long
  a form took. A world that is saved keeps its compiled functions. Code is
  looked at before the machine is given it, and refused when it points
  where it should not. Every boot compiles the four hundred texts of the
  evaluator's self-test and holds what compiled code makes of them against
  what the evaluator made, and one boot of `make test` does it once more
  with a collection wherever compiled code comes to a safe point, up to
  two hundred times a text. Under SBCL the
  compiler runs on a second machine, written in Lisp, and SBCL itself says
  what a form means: some 180 forms that were written and four hundred
  that are made at random have to give the same compiled. Found on the way
  and mended: the editor made the thread that evaluates its text a step
  before the form that stops that thread when the editor is stopped, so an
  editor that was stopped while it drew left the forms running. The host
  test of it lost that race one run in three on CI, which is how main
  came to fail there after M13 was merged. And the pointer: its place was
  read in one step and written in another, by the thread of whichever
  device had moved it, so a mouse and a tablet that acted in the same
  instant could undo each other. A session of the boot test lets a button
  go on the one and moves the other at once, and one run on CI ended with
  the pointer where it had been. The place is read and written in one
  step now, and the host tests have two devices move the pointer two
  thousand times each at the same moment.
- [x] **M14b a compiled world** (2026-11-18, version 0.0.20). Whatever is
  typed or loaded is compiled before it runs. Once the compiler is there,
  `eval` and `load` hand it every form, so a `defun` gives a compiled
  function at the prompt, in a file and in the editor, and so does a
  `lambda` wherever it stands. A machine that starts from the files has
  the compiler compile itself: lisp/boot.lisp and lisp/compiler.lisp are
  loaded once for the evaluator to walk, which is how the compiler first
  runs, and once more through the compiler, and after them the files of
  the world, which are never walked. That takes a quarter of a second,
  and some four where the machine is emulated. When it is done the heap is
  gone through, and a function that the evaluator would still have to
  walk is a panic. A world that is saved holds 929 functions and 36 macros
  of the machine's and none of the evaluator's, in 880 KiB where it took
  1450, and a machine that starts from one compiles nothing. Macros are
  compiled: a macro is a function of the form that calls it, it sees the
  variables where it was defined, and the macros of a MACROLET see those
  of the MACROLET around them. Then the machine was made quicker where the
  time went. The commonest functions in C, twenty from `car` to `svref`,
  have an instruction each, which does the work without a call and calls
  whatever the name has come to mean once the function is defined again;
  a safe point is a look at one word; and compiled code calls compiled
  code without going through the evaluator's door. Where the processor
  runs the code itself, `(fib 30)` took 100 ms and takes 80, five million
  additions 150 and 70, a million items pushed, reversed and mapped over
  530 and 120, and a small function is compiled in a tenth of a
  millisecond where it took seven. Every boot from the files compiles the
  texts of the self-test three times now: by the compiler that the
  evaluator walks, with a collection at the safe points of compiled code
  on one boot, and by the compiler that has compiled itself, with the
  answers that the evaluator gave each time. Found on the way and mended.
  The evaluator kept the clause that had last taken a condition and the
  place of the last GO where the collector looks, so the functions of
  every self-test since M6c stayed in the heap, 27 of them. And the boot
  test spoiled a saved world by looking for its eight letters at the start
  of a sector, which the kernel has among its own constants: this build
  put those at the start of a sector, a byte of the kernel was turned over
  in place of one of the world, and the boot that has to refuse the world
  resumed it. The tool looks at what follows the letters now. And under
  SBCL a thread that was stopped before it had begun to run, with nobody
  waiting for it, stayed on the list of threads for good. Closing a window
  stops its thread in just that way, and the runner of CI was slow enough,
  on the first run of this milestone, for one such thread not to have had
  a turn yet: the last check of the host tests, which wants every thread
  gone, failed there and nowhere else. Tried by itself it happened 2991
  times in 3000. The list lets go of a thread that SBCL no longer has.

Upgrades:

- [x] **M15a an upgrade in place** (2026-11-20, version 0.0.26). A newer
  ClaraOS came to a machine as another disk, and what was on the old one
  went with it: the files that were written there and the world that was
  saved. The upgrade is now done by the system that is running. A system
  is a directory on the disk, `/clara/<name>`, named by its version and
  eight digits of its build, with its Lisp files, its kernels and a
  manifest that lists them with their sums; the kernel reads the files of
  its own directory and no others, so a second system lies beside the
  first. `(clara.system:upgrade)` takes the system that another disk of
  the machine holds, the one that `make image` makes, attached as one
  more VirtIO drive: file by file, each held against the manifest, into a
  directory of its own, with everything else on the disk left as it is.
  Then the machine starts again and the newer system is tried: the
  firmware starts the old kernel, which starts the new one in place of
  itself, once. When the new system has come to its prompt it puts its
  kernels where the firmware looks and takes the old directory away; when
  it has not, the next start is the old system's, in the world it saved,
  and it says so. A machine can stop at any moment of all that and still
  start. Every start is counted on the disk by the handoff before it is
  known how it goes, and a saved world that did not come to its prompt is
  passed over at the next start, which is the key that was missing for a
  world that does not start. The same count says which volume the machine
  was started from, wherever its disk is on the bus. `make run-*` keeps
  its disk from one build to the next and hands the machine each newer
  build as a second disk to take at once, and the manual's way of putting
  a newer ClaraOS into UTM is this one. Directories can be made and taken
  away (`clara.fat:make-directory`). A world is started by the system
  that saved it and by no other, so what was defined at a prompt does not
  come across an upgrade yet: that is M15b and M15c.
- [x] **M15b work kept as text** (2026-11-20, version 0.0.27). What is
  defined at a prompt was in the heap and nowhere else, so it lasted as
  long as the world it was defined in, and a world that was saved is of no
  use to another system: after an upgrade it was gone. The work is now
  kept as text as well, which every system reads, in a directory that is
  the user's and that no upgrade touches: `/home`, on the disk that the
  machine starts from, which a system makes when it is not there.
  `/home/defined.lisp` is written by the listeners, the one on the serial
  port and the ones in windows: each form that defines something, as it
  was typed, comments and all, once it has been evaluated, with a form
  that defines a name again in the place of the earlier one, and the
  package that forms are read in said between them. `/home/init.lisp` is
  the user's to write. A world that is made from the files loads the two,
  a form at a time: a form that fails is said in the report and passed
  over, a file that does not come to an end is stopped after a minute,
  and after two starts in a row that did not come to a prompt nothing of
  it is loaded. So an upgrade ends in a world that has what was defined
  in the one before it, the functions, the macros, the structures, the
  packages and the variables as their forms give them, and so does a
  start that had to pass a saved world over. A world is saved on the disk
  that the machine started from, wherever names are looked up at the
  moment. The image stays what makes a machine start quickly.
- [x] **M15c a world made again** (2026-11-20, version 0.0.28). An upgrade
  ended in a world that had the definitions of the one before it, from
  the text, and nothing else of it; that world was not saved, so every
  later start made it again; and nothing said what was missing. Now the
  world that is leaving writes an account of itself for the system that
  is to take its place, as the machine is started again to try it: which
  functions and variables there are in the packages that are the user's,
  and of the variables the values that can be written as text. The system
  that comes makes its world from its own files, starts the window
  manager when it was running, loads the text of `/home`, gives the
  variables the values that they had come to, saves the world without
  anybody asking, and says what it found, by name: which variables have
  their values, which held something that is no text and are as their
  forms make them, and which names of the old world are not defined in
  the new one. `(clara.system:report)` says it again. A world also knows
  which text it has, so a start in a saved world loads what the two files
  have that the world has not: what was defined after the world was
  saved, on a machine that then stopped without saving, is there at the
  next start, with an image or without one. A saved world that does not
  come to its prompt is kept the first time and replaced the second, by
  the world that was made in its place. The language has `do-symbols`. No
  converter from one layout of the heap to another was needed: the old
  system writes text, and the new one reads it.
- [x] **M15d upgrades over the network** (2026-11-20, version 0.0.29). A
  newer ClaraOS is fetched, and not carried on a disk. ClaraOS has a
  network for that, as much of one as fetching takes: a driver for
  virtio's network card, and over it ARP, IPv4, UDP, DHCP, DNS, TCP and
  HTTP, each as far as a machine needs it that asks and does not serve
  (lisp/net.lisp). `(clara.net:fetch-text "http://...")` fetches a file,
  and the machine asks the network for its address the first time
  something wants one. A release is a system's directory on a web server
  with a signature of its manifest beside it; `(clara.system:upgrade :from
  "http://.../")` asks which system is the newest there, takes it when it
  is newer than the one that runs, holds the manifest against the
  signature with the key that the system has, and every file against the
  manifest, and from there on it is the upgrade of M15a: tried at the
  next start, and the old system there until the new one has come to its
  prompt. There is no TLS: what arrives is believed for its signature and
  not for the road it came by, and the kernel checks Ed25519 signatures,
  in C. `tools/release.py` makes a key, signs, and lays a release out.
  `make run-*` gives every machine a network card. Two things are not
  decided here and are empty: where ClaraOS is published, and the key
  that it is signed with, without which nothing is taken over the
  network.
- [x] **M15e shutting down** (2026-11-20, version 0.0.25). A machine that
  runs ClaraOS was stopped from outside, by leaving QEMU or with UTM's
  button, and that was the plug pulled: the system was not told, and what
  the world held that was not saved was gone. Shutting down is now
  something that the system does itself, and starting again with it. It is
  asked to at a prompt, `(clara.system:shut-down)` and
  `(clara.system:start-again)`; in the window manager, by `Shut Down` and
  `Restart` at the end of the launcher's list; or by the machine's power
  button, which is what a host presses when it wants a machine to stop,
  `system_powerdown` to QEMU and Request power down in UTM. It asks the
  windows whether their programs hold something that would be lost, and
  goes no further while one says so, an editor whose text is not saved for
  one: that window comes to the top, and whoever asked is told. Then it
  saves the world unless it was told not to, stops the window manager and
  with it the applications, has every disk put what it was given where it
  lasts, and turns the machine off or starts it again. The substrate does
  the last step by what ACPI's table of fixed hardware says of the machine:
  PSCI on AArch64, the sleep state S5 and the reset register on x86_64,
  with the two facts that only the DSDT has searched for in its bytes,
  since nothing here interprets them. The firmware's own service for it is
  not called, and DESIGN.md says why. The power button is looked at four
  times a second, by a thread. A machine that has no way of being turned
  off is told so in its boot report, and after a shutdown it is saved,
  stopped and left for the host. `make test` has two more boots for it,
  one for each kind of processor, which refuse to shut down over an
  editor's text, start again into the world that was saved on the way, and
  go by themselves when the power button is pressed. Starting again is how
  an upgrade ends, so M15a has that half of it to stand on.
- [x] **M15f HTTPS** (2026-11-20, version 0.0.30). What M15d fetched came
  over a road that anybody on it can read and change, which is no way to
  publish a system. An address that begins with `https://` is now fetched
  over a connection that is kept closed: TLS 1.3 (lisp/tls.lisp). The
  other side shows a certificate, and the machine holds it against the
  name that was asked for, against the day, and against the certificates
  that signed it, up to one that the system trusts: the authorities that
  sign for the web, Mozilla's list, a file of the system
  (lisp/roots.pem), to which `(clara.tls:trust ...)` adds. `(clara.net:fetch-text
  "https://claraos.org/")` fetches the website. A release is fetched by
  HTTPS and from no other kind of address; its signature stays under
  that. The arithmetic is in C, each piece held against the examples of
  its standard at every boot: SHA-256 and SHA-384, HMAC, AES-128 in
  Galois/Counter Mode, X25519, numbers of thousands of bits to a power,
  and signatures on the curves P-256 and P-384. Two things that such a
  connection needs came with it: the time of day, from the firmware's
  clock (`get-universal-time`), and numbers that nobody can guess, from
  virtio's device for them (lisp/random.lisp, `clara.random:below`).

Code for the processor:

- [x] **M16a code for the processor** (2026-11-18, version 0.0.21). The
  processor runs a compiled function itself, when it is asked to. What the
  compiler makes are instructions for a machine that the kernel plays, and
  lisp/native.lisp makes of those the instructions of AArch64 or of
  x86-64, the machine's one after the other. (This had stood under
  "Later" as code for the processor behind the compiler's first pass. It
  is behind the second, and DESIGN.md says why.) The processor does alone
  what a function spends its time on: its variables and constants, the
  stack, jumps, calls and returns, and the instructions for the commonest
  functions in C with the arguments that they usually get. Every other
  instruction is left to the machine of vm.c, which does that one
  instruction when it is called for it, so records, exits, cleanups,
  bindings and every error are written once for both ways of running a
  function. A call keeps on the value stack what the machine's call keeps
  there, and nothing that the collector has to find is in a register at a
  safe point, so the collector was not taught anything. One such function
  calls another without the kernel in between, by a routine in each
  entry.S, with the arguments left where they were pushed. The code is not
  in the heap, whose memory can be written and so cannot be run: it lies
  in a region of its own, mapped to be run and written only through the
  addresses that its page frames have as RAM, and the collector frees a
  piece of it when it frees the object that the heap has for it. It names
  no address of the kernel's: one register reaches a struct with the words
  that it reads and the functions that it calls, and the kernel tells the
  translator where each of them is. So a world that is saved holds its
  code, and the image has a new format: a world that 0.0.20 saved is
  refused once, and the machine starts from the files. The translation is
  written once, for a processor that lisp/native.lisp makes up, and
  lisp/arm64.lisp and lisp/x86-64.lisp each write that one's instructions
  for a real one; a machine loads its own. In this version nothing is
  translated unless somebody asks: `(clara.native:translate 'name)` for a
  function, `clara.native:*translate*` for whatever is compiled from then
  on. Every boot from the files has the texts of the self-test compiled,
  translated and run by the processor, on all three machines, with the
  evaluator's answers, and no code may be left when they are over; one
  boot has the collector run at the safe points of such code; a world is
  saved with translated functions in it and has to run them when it comes
  back; and what the two files write for each instruction is LLVM's
  assembler's, byte for byte, in the host tests. Where the processor runs
  the code itself, `(fib 32)` takes 210 ms on the machine and 30
  translated, five million additions 70 and 20, and a million items
  pushed, reversed and mapped over 100 either way, since the world's own
  functions are not translated yet.
- [x] **M16b a world for the processor** (2026-11-19, version 0.0.24).
  Translating is the rule and no longer asked for: whatever is compiled is
  translated before it is run, what is typed, what is loaded and the
  system itself, so that a machine which starts from the files, or from a
  world that was saved, runs on its processor through and through, as it
  has run on the kernel's machine since M14b. lisp/native.lisp and the
  processor's file are loaded right after the compiler has compiled
  itself, and then everything that is there is translated, the language,
  the compiler and the translator, by going through the heap for every
  function (`clara.native:translate-all`); the files of the world after
  that are translated a form at a time as they are compiled. It is checked
  like the last time: when the world is loaded, a compiled function that
  the processor does not run is a panic. The kernel's machine stays, for
  the instructions that the processor's code leaves to it, for what is
  compiled while `clara.native:*translate*` is NIL, and as the witness
  that the texts of the self-test are run on, twice, before the translator
  is loaded. Functions of the two kinds call each other, and
  `clara.native:translate` now reaches the functions that were made of a
  code before it was translated. Before all that, the code became shorter
  and quicker by what the last milestone had left. A value that would be
  pushed and taken off again stays where it is, a local variable, a
  constant or a register, until an instruction takes it as its argument. A
  comparison whose value is only wanted by the jump after it is one
  comparison and one jump of the processor's. The way to the machine is
  written once for a function, and an instruction that can fail calls it
  in three instructions where it had ten of its own. And a cons, a cell
  and a closure are made by a function in C that the code calls as it
  stands. Where the processor runs the code itself, `(fib 35)` takes 750
  ms on the machine and 70 translated, fifty million additions 610 and
  70, and a million items pushed, reversed and mapped over 60 and 50; the
  code of `fib` is 560 bytes on AArch64 where it was 732. Translating what
  is there takes 100 ms and the rest of the world 90 where compiling it
  took 60, and where x86-64 is emulated 2.1 s and 2.3 s where it was 0.7;
  the code of the world is 700 KiB, and a saved world 3.2 MiB where it was
  2.2. A world that 0.0.23 saved is refused once, since the code leans on
  three more functions of the kernel's, and the machine starts from the
  files. CASE compares symbols and integers with EQ, an instruction, where
  it called EQL and MEMBER, which the translator spent its time in.

The network:

- [x] **M17a the rest of a network** (2026-11-21, version 0.0.33). The
  network of M15d was as much of one as fetching a file takes, and what
  it left out showed as patience running out. A machine now hears what
  others say about its packets, and says such things itself (ICMP): one
  that is told that a machine cannot be reached has its error at once
  and not ten seconds later; it answers when it is asked whether it is
  there, and `(clara.net:ping "10.0.2.2")` asks another machine. The
  address that the network gave is kept: when half the time is over for
  which it was given, the machine asks the server whether it may keep
  it. Every name server that the network named is asked, the next one
  when one cannot say or says nothing, and by TCP when an answer came
  cut short; a name is asked for again when what was said of it no
  longer holds. And a connection sends more than a request. What is to
  be sent waits in memory of the connection's; as much of it is on its
  way as the other side has room for and as this side dares; a piece
  that is lost goes out again, at once when the other side says three
  times that it lacks it, and after a while that grows when it says
  nothing; a piece is as long as the other side says that it takes, and
  shorter when the way turns out to be narrower. The thread of the card
  looks after that, and after a connection that is over, until both
  sides have said that they are done. The numbers that a connection
  counts its bytes from, that an answer has to have and that a question
  is asked from are no longer worked out from the clock: they come from
  the device that makes numbers which nobody can guess.
- [x] **M17b a machine that listens** (2026-11-21, version 0.0.34). The
  machine takes connections, where it only opened them. `(clara.net:serve
  7 'shout)` has it take the ones that other machines open to its port 7,
  as many at once as it is told, and hand each to the function, in a
  thread of its own, as a stream: READ-LINE gives what the other side
  says, a line at a time, and what is written to the stream goes to the
  other side. When the function returns the connection is over, and an
  error that it ends in is kept for `(clara.net:serving)` to show.
  `(clara.net:connect "claraos.org" 80)` is the same stream for a
  connection that the machine opens, and `clara.net:with-connection`
  closes it. Nothing is taken at any port until somebody says so, and
  `clara.net:stop-serving` ends it. A machine reaches itself, at its own
  address and at 127.0.0.1, without a frame on the wire, which is how a
  function is tried before another machine is there. A world that is
  saved while it takes connections takes them again when it is started.
  Under QEMU, whose network lets nothing in, `FORWARD=8007:7 make
  run-aarch64` hands on what connects to a port of the computer. There is
  no web server: what is served this way is in the open, and the half of
  TLS that a server speaks is not written.
- [x] **M17c IPv6** (2026-11-21, version 0.0.35). Addresses of 128 bits
  beside the ones of 32. When something first wants the network, the
  machine makes itself an address that goes no further than its own
  network, out of its card's address, and asks the routers what the
  network is; from what a router answers it makes its address on that
  network, and knows the way out, which addresses are its neighbours',
  and who knows names. It finds a neighbour's card by asking the
  neighbours, answers when it is asked for its own, and says and hears
  over ICMPv6 what it does over ICMP. Above that nothing changed but the
  addresses: a ping, a connection, a port that takes connections, a
  question for a name and a file by HTTP or by HTTPS go over either
  kind, `http://[fec0::2]:8000/` is how such an address is written where
  a machine's name stands, and a certificate can be for one. A name is
  asked for the kinds of address that the machine has itself; the
  machine goes by IPv6 first when its own address is one of the
  Internet's and by IPv4 otherwise, and tries the next address when
  nothing takes the connection at the first. `(clara.net:addresses)`
  lists what the machine has, and `clara.net:*ipv6*`, set to NIL, keeps
  it from speaking IPv6 at all. On a network where no DHCP server answers
  and a router does, the machine gets by with IPv6 alone. An address of
  that kind is a list of eight numbers in the language, which has no
  number of 128 bits.

Fonts:

- [x] **M18a outline fonts** (2026-11-21, version 0.0.36). Letters as
  shapes, at any size, where there was one font of 8 by 16 pixels.
  lisp/type.lisp reads a font file of the kind that most are, TrueType:
  which glyph a character has, how far a glyph moves on, its outline of
  straight lines and curves, also where it is put together of other
  glyphs, and where the lines of a font lie. A glyph is drawn by bringing
  its outline to the size, cutting its curves into straight pieces, and
  working out for every pixel how much of it the shape covers, in whole
  numbers, the language having no others. That is the pixel's shade, and
  the pixel takes that much of the colour of the text, so an edge that
  slants or bends comes out smooth. Laying a colour over pixels by their
  shades is the one thing that the substrate was given for it
  (`clara.unsafe:blend-shades-32`), and `clara.draw:draw-shades` draws any
  such picture. `(clara.type:font "Sans" 24)` is a font;
  `clara.draw:draw-text` and `text-width` take one as their last argument,
  and are what they were without. Two families come with the system, Sans
  and Mono, each upright, bold, italic and bold italic: the Go fonts of
  Bigelow & Holmes, eight files of 1.3 MiB between them, under a BSD
  license like the console's Spleen. `:bold` and `:italic` pick the file,
  `:underline` and `:strike` draw a line, and a name that is no family's
  is the name of a file, so a font of the user's own is drawn in from the
  disk that it lies on. The system's own are among the files that the
  handoff reads into memory, like its Lisp (`clara.unsafe:system-file`),
  so they are there on a machine with no disk that is known. The picture
  of a glyph is made when its character is first drawn in a font, and
  kept; a font comes back with a world that was saved, and finds its file
  again. All of it is held against three things that this code did not
  make: areas that the host tests work out in fractions, for shapes and
  for every glyph of font files that they put together byte by byte; what
  FreeType reads of the eight files, to every point of every outline; and
  FreeType's own pictures, from which these differ by a shade in 255 on
  the average.
- [x] **M18b the window manager's letters** (2026-11-21, version 0.0.37).
  The bar along the top of the screen, the list of the applications and
  the titles of the windows are written in the font Sans, at 13 pixels, in
  the places and at the heights that they had. `clara.windows:*font*` says
  which font it is, or NIL for the console's letters; and those are what a
  machine has whose system came without the files, with a line that says
  so. What is inside a window is its program's to draw, and the listener,
  the editor and the file browser draw the console's letters in their
  cells, as they did.

Later, in no order: sound; CLOS; a USB keyboard and mouse, which is what
UTM gives a machine that is not told otherwise.

The website, <https://claraos.org>, is built from this file by
site/build.py: the milestone list above, with its version numbers, is what
the page shows, so keep the form of those entries.

Infrastructure, done:

- **CI** (2026-11-13, version 0.0.5). .github/workflows/ci.yml builds both
  kernels on Ubuntu and boots them under QEMU, for every pull request and
  every push to main, then builds the website; the serial logs and a
  screenshot of each machine are kept with the run. The Makefile and
  tools/run.sh find the compiler and the firmware on Ubuntu as they do
  under Homebrew. The website takes its version from kernel/kernel.h, since
  a version no longer has to belong to a milestone. The ruleset on main
  has required the check, `build-and-boot`, since the workflow was merged.

- **User manual** (2026-11-17, version 0.0.15). The website has a second
  page, site/manual.html: how to build ClaraOS, start it under QEMU and in
  UTM, work at its prompt, use the language as far as it goes, read and
  write files, save the world, run threads, look at the machine, and what to
  do when something goes wrong, with every name that the system defines at
  its end, by subject. It is held to the kernel: site/build.py stops when
  the kernel defines a name that the manual lists nowhere, or the manual
  lists one that is gone, and `make test` types what the manual shows of the
  prompt at a kernel, before and after the machine is started again from the
  world it saved, two more boots. tools/mkdisk.py makes its partition of the
  kind for plain data, as macOS does for the UTM disk, so that the host
  opens a machine's disk like any other and files can be carried to it and
  back.

- **A disk of the user's own** (2026-11-19, version 0.0.22). `WORK=file`
  gives the machine of `make run-*` a second disk (tools/run.sh): a file
  that no build makes again, attached behind the boot disk, so that names
  are still looked up on the system's volume. A file that is not there is
  said before anything else is done, with the line that makes one. The
  manual has a section for it under Files, "A disk of your own": making
  the volume with tools/mkdisk.py, binding `clara.fat:*volume*` to read
  and write there, carrying a file across, setting the variable so that
  the Editor and the file browser work there, loading a file of one's own
  on a newer system, and what to mind. `make test` types that at the
  manual's machine, which has such a disk, and at the same machine started
  again, which has to find the file there; tools/boottest.sh takes `WORK=`
  like `DISK=`, boots with a copy, and has the host's checker look at that
  volume too. A work disk that the environment names stays out of `make
  test`. One mend in the file system came with it, since the section
  teaches the variable: a volume that a variable had kept from an earlier
  start, in a world that was saved, was used as it was, with the disk and
  the page frame of that time. On the machine a lookup through it read
  memory that was no longer its own and failed on what it found there, and
  under the host tests a file written through it went to the disk. No name
  is looked up on such a volume now, nor on what is no volume
  (`the-volume`, lisp/fat.lisp).

- **A disk that is open on the Mac** (2026-11-19, version 0.0.23). A work
  disk that macOS had made, a `.dmg` of a gibibyte, would not start with
  `WORK=` once it had been opened in the Finder, which the manual invites:
  QEMU does not start with a disk that the host has open, and says only
  that it failed to get a lock, so the file looked like the wrong kind of
  file. tools/run.sh now looks whether the boot disk or the work disk is
  open there, ejects it, says so, and starts the machine; when the disk
  cannot be ejected, because something on the Mac is using it, it says
  that and starts nothing. The manual names a `.dmg` among the disks that
  do, says that a disk left open is ejected, and has the lock in its table
  of what goes wrong.

- **ClaraOS, published** (2026-11-20, version 0.0.31). The newest ClaraOS
  is at `https://claraos.org/releases/`, and a machine takes it from
  there: `(clara.system:upgrade)` on a machine with no other disk that
  holds a system says where it looks, asks which system is the newest,
  and takes it when it is newer than the one that runs and signed with
  the key whose public half the system has. The address and that half
  are in lisp/system.lisp now (`clara.system:*releases*`,
  `clara.system:*release-key*`). The secret half is Julio's, on his
  computer, and a secret of the environment that the website is deployed
  from, `github-pages`, which takes deployments from main and from
  nowhere else. The website's workflow (.github/workflows/site.yml) runs
  for every change to the system as well as to the site, builds both
  kernels, and has `make release` lay the system out beside the pages,
  sign it, and hold what it laid out against the public half in the
  source, as a machine will: with another key in the secret, or with
  none, the job fails, and the site stays as it was. A system without a
  key asks for nothing, where it used to ask and then refuse. `make
  release-test`, which `make test` begins with, runs `make release` with
  a key that it makes: the release has to be laid out when that key is
  the one to go by, and refused when it is held against the system's.
  And a build no longer goes wrong when its sources go back to what they
  were at an earlier build (below).

- **MAKE-STRING** (2026-11-20, version 0.0.32). `(make-string length
  :initial-element character)` makes a new string of that many
  characters, which `(setf (char string index) character)` then changes a
  place at a time. Until now a string of a length had to be written by a
  loop into a string stream, or put together with CONCATENATE and cut
  with SUBSEQ, as the editor does for its blanks. It is one object of the
  size that it is to have, made by a function in C, `%make-string`, under
  a definition in lisp/boot.lisp, the way MAKE-ARRAY stands on
  `%make-vector`. With no `:initial-element` every place holds the
  character of code 0, which is what SBCL fills a string with, so that a
  form gives the same string on the machine and under the host tests.
  `:element-type` is refused: there is one kind of character. The
  evaluator's self-test has five texts for it, which every boot from the
  files also compiles and translates, and the manual shows it at the
  prompt, where `make test` types it. Mistakes that were planted, one at
  a time, and that a boot noticed by a text that gave another answer:
  the last place left as it was, every place filled with a letter
  whatever was asked for, anything taken for a character, no limit to
  the length, a function in C of one argument, a string of spaces when
  nothing is said, and the name left out of what boot.lisp exports.
  Without the look at whether the heap has the room, the machine ran out
  of memory at the text that asks for four thousand million characters,
  which is a panic.

Infrastructure, for sessions with budget left over:

- Read the UART base from ACPI (SPCR or DBG2) instead of assuming
  0x09000000 in kernel/arch/aarch64/arch.c.
- `make run-*` with a GDB stub and a debugging recipe for PE images.
- A slow test mode for the checks that were run once, by hand, most of
  them with temporary patches, and that `make test` does not run. From M2:
  every free frame allocated, written, read back and freed, which M4
  repeated with interrupts on; a stale map key on the first
  ExitBootServices; odd boot files (dot files, a subdirectory, an empty
  file, a 300 KB one, a long name, an accented name); 128 MiB and 4 GiB of
  memory; booting build/claraos.img instead of the ESP directory. From M3:
  `-cpu max` on both architectures. From M4: faults that are not survived,
  to read the report (a null pointer, a write to code, a jump to data, a
  stack that really overflows, an unknown instruction, a division by zero,
  an exception inside the report itself, a fault before the kernel's page
  tables exist); a software interrupt on a vector nothing asked for; four
  processors; AArch64 started at EL2; 500 ticks timed against the host's
  clock; how much processor time QEMU uses once the kernel has halted.
  (AArch64 without hvf and the accesses that must fault were on this
  list. `make test` runs both now.) From M5: the thread self-test a
  hundred times in one boot, on x86_64 (as it comes, with four processors,
  with `-cpu max` and 4 GiB) and on AArch64 (under hvf, the same with four
  processors and 4 GiB, emulated with GIC version 3, emulated with version
  2 and `-cpu max`); threads made until memory ran out, about 1800 in
  128 MiB, each asleep for a different time, then all joined and every
  frame back; four threads printing 1500 lines each, none of them mixed,
  and hundreds mixed once the console's lock was taken out; how often the
  idle thread wakes in a hundred ticks (a hundred times, two hundred under
  hvf); in a thread, a stack that really overflows and a null pointer, to
  read the report; a lock taken twice, a lock released by a thread that
  does not hold it, the world started by a thread that had not stopped it,
  an interrupt handler that tries to wait. And the self-test with the
  scheduler broken on purpose, to see that it notices: no lock around the
  shared total, no parking after a sleep, no end of turn on the tick, a
  register left out of a switch, a sleep one tick short, no guard page, a
  frame not given back by thread_join. From M6a: typing by hand through
  a FIFO, with backspace and Delete, a tab, lines that end in a carriage
  return, a line feed and both, Ctrl-D in the middle of a line and in the
  middle of a form, characters outside ASCII typed and taken back; 400
  forms pasted at once, 23 KB, none lost, on x86_64 and on AArch64; a
  string that never ends, typed until the 8 KiB the loop keeps were full;
  the session on the disk image with 4 GiB and four processors, and on
  x86_64 with `-cpu max`, 128 MiB and four processors; how much stack the
  deepest nesting takes; the whole of `make test` in an Ubuntu container.
  And the self-test and the session with the runtime broken on purpose,
  to see that they notice: a page too few mapped for the heap, a string
  one word short, a symbol made anew at every read, nothing inherited
  from the packages a package uses, a table that forgets its symbols when
  it grows, a printer that never writes bars, a reader that does not fold
  case, floats read as symbols, a dotted tail dropped, an integer too
  large let through, UTF-8 longer than it need be let through, no limit
  on nesting in the reader or in the printer, typed characters not
  echoed. From M6b: a second file in lisp/, loaded from the prompt, with
  a form in the middle that fails (the error names the file and the
  line, what came before it stays defined, `*package*` is what it was,
  and the name finds the file in either case); the same file deleted
  again, and gone from the ESP after `make`; a list that leads back into
  itself, printed into a string: 131073 characters, the last three of
  them dots; a loop of 100000 turns and `(fib 20)`; the session from the
  disk image with 4 GiB and four processors, on x86_64 with 128 MiB,
  `-cpu max` and four processors, and on AArch64 emulated with
  `-cpu max`. And the self-test with the evaluator broken on purpose, to
  see that it notices: LET that does not undo its special bindings, or
  binds in turn like LET*, or puts a special variable in a frame; no
  count of values set before a function in C; a block not marked as
  left; GO that does not move; a default computed where the parameters
  before it cannot be seen; `+` without its look at overflow; no check
  of the stack's depth, which ends in the guard page; EXPORT that leaves
  the rest of a table's cluster where it was; a macro call overwritten
  with its expansion; an unknown keyword argument let through;
  RETURN-FROM that does not keep its values; CATCH that takes a THROW to
  any tag; PRINC that writes like PRIN1; variables looked up among the
  local functions; `&rest` one argument short; closures without their
  environment; a boot.lisp that ends inside a form, and one with a form
  that fails. One got through the first version of the self-test: EVAL
  without the copy of its form, because the text that was to catch it
  had the macro call at the top of the form, where the evaluator leaves
  it alone anyway. From M6c: the heap filled on a machine of 128 MiB, by
  a list of vectors of 10000 items and by a list of ones, at the prompt,
  inside an UNWIND-PROTECT whose cleanup form calls a function, inside a
  HANDLER-CASE for STORAGE-CONDITION and inside one for ERROR, which
  must not take it (the prompt comes back each time, and ROOM shows a
  heap of 464 KiB again); Ctrl-C at an empty prompt, after three
  characters of a line, and at the prompt for the rest of a form; a
  Ctrl-C typed ahead of the form it was meant for, which stops the form
  before it; the session from the disk image with 4 GiB and four
  processors, on x86_64 with 128 MiB, `-cpu max` and four processors,
  and on AArch64 emulated with `-cpu max`; tools/stress.txt on x86_64,
  half a minute; the whole of `make test` in an Ubuntu container. And
  the boot and the stress session with the runtime broken on purpose,
  to see that they notice. The collector: without the value stack among
  what it starts from, without the bindings, without the values of the
  last form, without `lisp_roots`; that does not follow the last word of
  an object, or the first; that forgets an object which had no room to
  wait; a sweep that leaves the marks on, that fills nothing, that makes
  a free block a word short, that frees nothing; a block that stays in
  its list when it is taken; a heap that does not end where its last
  free run begins; a write into freed memory. The evaluator: a function
  being called that is not held, nor a list being taken apart, nor the
  exit under way during a cleanup; UNWIND-PROTECT that does not put the
  values back, or cleans up only when the form ends by itself; a type of
  condition that is not one of its parents; HANDLER-CASE that does not
  bind its variable, that stays in force after its form, that asks the
  outermost first; an evaluator that never collects, and one that never
  looks for Ctrl-C; PRINC that writes a condition like PRIN1; a
  condition made in C without its slot; MAKE-CONDITION without the
  defaults. And a thread that sleeps with a lock held. One got through:
  LOAD that leaves `*package*` changed when a form fails, which is older
  than this milestone and was only ever looked at by hand; the boot
  volume has a file with a mistake in it since, kernel/lisp/self-test.lisp,
  for a text to load. From M7: raw bytes typed at the console in Lisp
  through the standard input of tools/run.sh, with Delete and Backspace,
  tabs, lines that end in a carriage return, a line feed and both,
  characters outside ASCII typed and taken back, control characters,
  Ctrl-D in the middle of a line and of a form, Ctrl-C at an empty
  prompt, after three characters, at the prompt for the rest of a form,
  during `(loop)` and during `(sleep 100)`; 400 forms pasted at once, 24
  KB, none lost, on AArch64 and on x86_64; a write from the prompt into
  the kernel's code, to see the fault report take the screen back from
  the console in Lisp; the stress session emulated, on both
  architectures, 39 s and 57 s; the whole of `make test` in an Ubuntu
  container, with SBCL 2.2.9. And the boot, the stress session and the
  host tests with the code broken on purpose, to see that they notice.
  Threads: bindings that do not travel with their thread; a collector
  that does not look at the other threads; no turn for another thread at
  a tick; a lock that wakes nobody when it is released, and one that
  anybody can take; a thread that is told to stop and never looks, and a
  stop that a handler can take; a wake before the wait that is lost; a
  sleeper that the tick leaves marked as waiting; an event that wakes
  nobody. The unsafe package: 16 bits read as 8, 64 written as 32, a copy
  that always starts at the front, a bitmap with its rows mirrored, any
  address taken for mapped, a fill one word short, an interrupt that
  signals nothing, interrupts counted one by one, a negative integer
  refused. The reader and the streams: a top level inside another that
  sees the handlers outside it; READ-FROM-STRING one character off; `#+`
  that makes sense of what it leaves out, and one for which every
  feature is there; PRIN1-TO-STRING that writes like PRINC; a stream that
  does not know whether its line is fresh; a string stream with its
  parts back to front. The console and the listener, which the host
  tests caught and a boot mostly could not: UTF-8 with a wrong first
  byte; a new line without its carriage return; a scroll that keeps a
  row too many; no new row at the last column; Backspace that takes
  nothing back; a line feed after a carriage return taken for a line;
  Ctrl-C left a byte after the line is over; a colour in the wrong bits;
  a grid that begins at the screen's left edge; the values of a form on
  one line; a form that is not finished forgotten; Ctrl-C at the prompt
  ending the listener. Two got through the first version of the
  kernel's texts: a lock that wakes nobody and a lock that anybody can
  take, because the threads of the text never ran at the same time;
  `thread-yield` gives the processor up since, not only the runtime.
  From M8: the session on x86_64 with `-cpu max`, 128 MiB and four
  processors, and with 4 GiB; on AArch64 from the disk image with 4 GiB
  and four processors, and emulated with `-cpu max`; tools/stress.txt on
  x86_64, 52 s; a keyboard behind a PCI bridge (`-device pcie-root-port`),
  on x86_64 and with the ITS, where the device's number is 256; a machine
  with a keyboard and nothing else, and one with no input device at all
  (`INPUT=`), which says so and reads the serial port; a machine that
  takes no messages (`-machine gic-version=3,its=off`, emulated), where
  each input device is given up with the reason; a tablet's pen moved
  through QMP (`input-send-event` with `abs` events: the monitor that the
  boot test types at has only moves of a mouse), on both architectures; a
  key held for a second and a half (`sendkey a 1500`), which types 29
  times; the whole of `make test` in an Ubuntu container, with QEMU 8.2
  and SBCL 2.2.9, where the stress boot takes a minute. And the code
  broken on purpose, 104 ways. The substrate, by booting: an aligned run
  that begins anywhere; a map of the firmware's in which nothing is
  memory; a message with the next vector, the next interrupt, the next
  event or the next LPI in it, to a processor that is not there, or to
  the wrong register of a frame or of the ITS; vectors, a frame's
  interrupts and LPIs that are acknowledged and go nowhere; a source
  whose handler is not called, every device given the first source, the
  event of the next source signalled, an event that is not kept where the
  handler looks; registers mapped read-only, not mapped at all, memory
  taken for a device, a mapping where the heap is; the configuration
  space a page further on; a break from the keyboard that does nothing,
  or wakes nobody; drivers that are loaded and never started, or loaded
  in the wrong order; a frame's interrupt left as one of a level, or
  never switched on; an ITS without its collection, its queue, its tables
  or its switch, a device it is not told about, an LPI that is switched
  off, LPIs switched off as a whole, interrupt numbers of 13 bits. The
  Lisp files, by the host tests: 65 ways, among them an empty place read
  as zero, one function to a device, nothing behind a bridge, a list of
  capabilities without an end, half an address, messages never switched
  on or written to the wrong entry; a device that is not started afresh,
  asked for everything, taken though it is too old or does not agree; a
  queue of the wrong size, without its switch or its message, descriptors
  that do not chain, that are used twice or never free again, counts that
  do not go round; Shift, Ctrl and Caps Lock each wrong in two ways, keys
  that stay held or never repeat, buffers that do not go back to the
  device, a pointer off the screen, a button that stays down, a tablet
  whose least place is taken for 0; Ctrl-C from the keyboard always or
  never a character, the serial port read ahead of the keyboard, a cursor
  that shows when nobody reads, moves up with a row, or stays. Three got
  through, all in the substrate, and for a reason outside it: a frame's
  interrupt that is bound for no processor (GIC version 2) or routed
  nowhere in particular (version 3), because the firmware had sent every
  shared interrupt to the processor that boots before the kernel did, and
  an LPI changed without telling the redistributor, which QEMU's looks up
  again every time. Five of the breakages in Lisp were noticed by tests
  that never ended, which is why the host tests end themselves after two
  minutes now. From M9: the session from the disk image, a GUID partition
  table and a volume of the kind 32 that macOS makes, on AArch64 with
  4 GiB and four processors and on x86_64; on x86_64 with `-cpu max`,
  128 MiB and four processors; on AArch64 emulated with `-cpu max`;
  volumes that macOS made of the kind 12, behind a table of partitions,
  and of the kind 16, a disk from end to end that cannot be written, as a
  third and a fourth disk, each listed and a file on each the same as on
  the boot volume; the kernel's own image, 300 KiB, read from the volume
  and summed, against the sum on the host; a machine whose boot disk has
  no driver here (SATA), which says so, loads what the handoff read and
  finds no file otherwise; devices ahead of the boot disk on AArch64 with
  the firmware's variables as they were, which boots since the disk has a
  boot index; tools/stress.txt emulated, 90 s where it was 77; the whole
  of `make test` in an Ubuntu container, with QEMU 8.2 and SBCL 2.2.9.
  And the code broken on purpose, 117 ways. The drivers, by the host
  tests, 87 ways: what a device can do asked for though it has it not,
  never asked for, read from the wrong half; a read that is a write, the
  sector left out or in the wrong place, memory and an answer that the
  device may not write, one sector's memory for several, no look at the
  end of the disk or at the answer, no lock, a disk written that cannot
  be, asked again after it went silent, never told that there is work; 12
  bits with odd and even the wrong way round, an entry across the end of
  what is held of the table, 4085 and 65525 clusters taken for the kind
  below and 4084 for the one above, the root, the table and the clusters
  each a step from where they are, clusters counted from 1; the parts of a
  long name in the order of the disk, a long name for any short name or
  with a part missing, a checksum turned the other way, a character at the
  wrong place; deleted entries, the name of the volume, `.` and `..` kept;
  the upper half of a first cluster on every kind and on none; clusters
  taken to lie side by side, no end to one request, a whole cluster read
  where a file ends, a file one cluster short; names in the order of the
  disk, by the case of their letters, without the short ones; memory kept
  in each of the four places that give it back; every look that START has
  at a first sector and at the two tables of partitions; the upper four
  bits of 32 kept, one mark only for the end of a file, a root of the kind
  32 at cluster 2 whatever the volume says, the first table whatever it
  says; no lock on a volume. The substrate and boot.lisp, by booting, 30
  ways: text taken for UTF-8 unlooked at, or a byte short; STRING-EQUAL by
  the case of the letters or without a look at the lengths, STRING-LESSP
  the other way round; a text loaded without `*package*` bound, with no
  place for a condition that is handled, a byte short; a world without
  its disks or without its file system; SORT with its predicate the wrong
  way round, its halves in the wrong order, without its key; a `*` that is
  one character, a pattern that fits the beginning of a name, a directory
  without its slash; PROBE-FILE by the case of the letters; DIRECTORY back
  to front; OPEN for any direction, CLOSE that closes nothing; LOAD that
  never asks the file system, or gives its text no name. Eight got
  through at first, and the tests have what catches each since: a disk
  that gives up the moment it has to wait, because the disk of the tests
  answered at once, so that nothing ever waited for an interrupt there (it
  can take its time now, and can lose its interrupt); a long name without
  its first part; a file that holds what a directory would, used as one on
  the way to a name; a GUID partition table whose entries are not in the
  sector after its header; the upper four bits of an entry of 32 bits; a
  root of the kind 32 that is not at cluster 2; the lock of a volume,
  because threads under SBCL are too quick to catch each other with the
  table in hand (the disk of the tests looks whether who asks it holds the
  lock); and the page frames that a text keeps when it has been loaded,
  which no boot looked at, nor at those of READ-FROM-STRING (the
  evaluator's self-test counts them now). One still gets through and does
  no harm: LOAD that leaves the name of a boot file on the value stack,
  since whoever calls a function in C puts the stack back. The tests also
  found a mistake of their own on the way: the page frames of the machine
  that lisp/host/ makes up were handed out without a lock, to threads
  that, unlike those of ClaraOS, run at the same time.
  From M10: the two sessions on the disk image that macOS makes, a GUID
  partition table and a volume of the kind 32, with 4 GiB and four
  processors, and afterwards macOS's own driver reading the files that
  ClaraOS wrote there, the image of 1.6 MiB among them; a third boot, from
  the disk of a second, of a world that a saved world saved; the second
  session on x86_64 with 128 MiB, `-cpu max` and four processors; the image
  of AArch64 given to x86_64, which is refused by the machine it names; an
  image given to a kernel with a row put into the middle of its table of
  functions, which starts from it with every function in its place and the
  new one there, and that kernel's image given to the one without the row,
  which refuses it by the name of the function and passes the whole first
  session in a world made from the files; an image given to a kernel whose
  number for the layout of objects is another; half an image, a text under
  the image's name, and an empty file, each refused and each followed by a
  world from the files; how long a world of 1.5 MiB takes to save, two
  ticks; fsck.fat 4.2 on new and on used volumes of the three kinds, which
  found that tools/mkdisk.py named a volume in the first sector and not in
  the directory of the root; the whole of `make test` in an Ubuntu
  container, with QEMU 8.2, SBCL 2.2.9 and fsck.fat. And the code broken on
  purpose, 88 ways. The file system and the console, by the host tests, 59
  ways: the table written to one copy only, or eight sectors of it past its
  end; 12 bits with odd and even the wrong way round; the upper four bits of
  32 lost; a mark for a last cluster that is none; a search for free
  clusters that does not go round; a file without the mark at its end;
  clusters that are given back and stay marked; free clusters counted the
  other way, never, or into a sector that only sits where the count would;
  clusters and the sectors of a directory a step from where they are; a
  number that is taken, taken again; small letters without a long name; the
  halves of a character and of a first cluster the wrong way round; a size a
  byte short; an entry that is a directory's; a long name without its end,
  filled with zeroes, numbered upwards, without the mark on its last part,
  with the checksum of another name or one turned the other way, with an end
  it does not need; one free entry taken for as many as are wanted; deleted
  entries never used again; a place past the end of a directory; a directory
  that no longer ends, that grows into a cluster as it was left, whose new
  cluster is not chained or keeps its page frames; an entry changed or
  deleted in the wrong place; clusters kept by a file that went, that was
  replaced, or that never got its entry; the entry written before the table;
  a last sector not written; a table that is not taken to the disk, or
  thrown away unwritten; any name let through; no lock; a directory written
  over, deleted, or stood in for by a file; one cluster more or fewer than a
  volume has; the place of an entry taken for an address; a console that
  keeps the screen of the machine before. Five got through at first. One was
  a look that could never find anything, at whether a name that is a short
  name in capitals is taken, and is gone. One still gets through and does no
  harm: the table written before the file's bytes, since what has to come
  last is the entry. Three were the tests': the cluster a directory grew
  into was left full of bytes that pass for names of volumes, which a
  directory is read past; no file was deleted while the disk looked at who
  held the lock; and nothing started a console in a world that had known a
  screen. The substrate and boot.lisp, by booting twice, 29 ways: an image
  with the bindings of the thread that saves; a checksum that is not looked
  at; threads left running, locks left held, and the queues of a lock and of
  an event and the address of a thread left in an image, each of which the
  second session runs into; roots that are not brought back; a heap that
  comes back a word short, an image without its last page, and one that says
  it is longer than it is; the substrate's own forms read in the package the
  world was left in; a world that came as an image made again from the
  files; an image never looked for; more than 255 arguments refused; the
  functions in C put over what a world made of their names; GENSYM that does
  not count, STRING-UPCASE that makes small letters, UTF-8 of four bytes
  that begins like three, STRING-BYTES that counts characters; CLOSE that
  makes no file, a file made although the body that wrote it failed,
  `:append` that forgets what was there, a file written over without a word,
  DELETE-FILE that deletes nothing, the strings of a list joined one on top
  of the other, a text a byte short, a file opened for `:io`, SAVE-IMAGE
  that saves nothing. One got through at first, the heap that came back a
  word short, because the checksum was taken of the file: it is taken of the
  heap now, after the copy. And three of them showed a mistake that no case
  was looking for: an image that was refused after its heap had been copied
  left the page frames where they were, and the world made from the files
  then failed the heap's own test; they are given back, and the machine of
  `make test` that boots from a damaged image goes that way every time. The
  first real session found two more that the host tests could not, both
  older than this milestone: a function that takes any number of arguments
  refused more than 255, and so a string stream that had been written to 300
  times could not be read. The strings of a stream are joined by a function
  in C now, which takes them as a list, however many there are.
  From M11: the two sessions from the disk image that macOS makes, with
  4 GiB and four processors; a machine without a screen (x86_64 with
  `-vga none`), which says so, draws on a surface all the same and shows
  nothing; a machine of 128 MiB, where a surface of 8192 by 8192 pixels is
  refused as a STORAGE-CONDITION and one of 2048 by 2048 is made, filled,
  shown and freed; a world that 0.0.15 saved, started by this kernel: it has
  no CLARA.DRAW and starts without, loads draw.lisp from its prompt, draws,
  and the world that it saves then starts drawing by itself; how long
  drawing takes, in the hundredths of a second that the machine counts:
  under Apple's hypervisor 4 µs for a rectangle of 50 by 30 pixels, 22 µs
  for ten characters, a third of a millisecond to fill a surface of 800 by
  600 and copy it to the screen, and 80 ms to write as many pixels one at a
  time from Lisp; on x86_64, emulated, 50 µs, 280 µs, a millisecond and
  1.2 s; the manual's new chapter, as a browser shows it; the whole of
  `make test` in an Ubuntu container, with clang 18, QEMU 8.2 and SBCL
  2.2.9. And the code broken on purpose, 84 ways. lisp/draw.lisp, by the
  host tests, 67 ways: a rectangle not cut on one side, or cut a pixel
  late; one of no pixels taken for drawn; a surface of another boot, or one
  that was freed, taken for one to draw on; a pixel's address a pixel off,
  or by rows as long as the surface is wide; the part that drawing is kept
  to left narrowed, not put back after a failure, wider than what it lay
  in, a row short; damage that keeps what it should drop, joins rectangles
  of different heights or widths or ones that lie apart, never joins a
  second time, knows no limit, or makes the rectangle around them all too
  small; a screen that keeps damage, a surface that keeps none; damage
  given by its corners, taken and left where it was, counted past the
  edges; PIXEL a pixel past the end of a row, or with rows and columns
  changed over; a rectangle filled as wide as was asked, or from where it
  was asked; an outline without its lower edge, with its right edge
  outside, or of an empty rectangle; a copy of more than the first surface
  has, from the corner or to the corner whatever was cut, with one length
  of row for both surfaces, from a surface that nobody looked at; a bitmap
  and a glyph whose right-hand end is not passed over, or that begin with
  their first row whatever was cut; a bitmap with its colours changed over;
  text without the box, with every character the first, without its
  background, without its damage; the width of a text by the height of a
  character; a surface shown whole every time, always at the corner of the
  screen, with its damage left, or said not to have been shown; START that
  keeps the machine or the screen it knew, takes the colours to be where
  they usually are, or the rows to be as long as the screen is wide; a
  colour of any number, with all eight bits whatever a pixel has, with
  green and blue changed over, a mask counted from the bottom; a surface a
  page frame short, of any size, kept to nothing; one that is still a
  surface after it was freed, one that gives nothing back, a screen that
  can be freed. Two got through the first version of the tests: PIXEL with
  rows and columns changed over, which only a session noticed, the tests
  having read pixels of a surface that was all zeroes; and a screen that
  can be freed, which failed in the substrate all the same, in other words.
  The tests read a surface whose every pixel is another number since, and
  hold the words of each refusal. The substrate, by booting, 17 ways: a
  rectangle filled a row short, a pixel short in every row, with rows as
  long as it is wide; one copied with its rows always from the top or
  always from the bottom, its pixels always from the left or always from
  the right, with one length of row for both, from a place that is not
  looked at; a bitmap whose lowest bits are not passed over, and one with a
  pixel written where NIL says to leave it, of either kind; a rectangle
  that is not looked at for whether it is mapped, or for how long its rows
  are; EXPAND-BITS-32 with eight arguments and no more; a world without
  draw.lisp, and one in which drawing is never started. One got through at
  first: the rectangle of which only the first pixel is looked at for
  whether it is mapped, since the text that tried it began where nothing
  is; two texts begin in memory now and run off the end of it. And the
  tests found a mistake as they were written: the outline of a rectangle
  that has no width drew its left edge.
  From M12: the two sessions from the disk image that macOS makes, with
  4 GiB and four processors, and on x86_64 with 128 MiB, `-cpu max` and
  four processors; a machine without a screen (x86_64 with `-vga none`),
  where the window manager does not start, and says so when a window is
  asked for; a machine with no keyboard and no pointer (`INPUT=`), where it
  starts, and its window is typed in and moved by the functions that the
  drivers would call; the window manager started and stopped, a window
  opened, drawn on, moved and closed and a form typed into the listener's
  window on the keyboard, all with a collection at every safe point of the
  evaluator, 20 s; how long things take, in the hundredths of a second
  that the machine counts: under Apple's hypervisor half a millisecond for
  a line of 72 characters in a window of 80 by 24 cells that moves up a
  row for it, half a millisecond to move that window, and 50 µs to move
  the pointer; emulated on the same Mac, 5 ms, 4 ms and 0.75 ms; the
  manual's new chapter, as a browser shows it; the whole of `make test` in
  an Ubuntu container, with clang 18, QEMU 8.2 and SBCL 2.2.9. And the
  code broken on purpose, 105 ways. lisp/windows.lisp, by the host tests,
  57 ways: rectangles that are joined into less than both; the damage of a
  window without its band, or a column short, and that of the pointer too
  low by a third; a bar without its word, or with the system's name where
  there is no room; a frame that is never lit, or always, without its
  bottom line, with a side a column in; a title that runs into the box,
  and a box on a window that cannot be closed; a window that hides more
  than it covers, a band that is not counted as window, the topmost
  painted first, the pointer under the list, a screen that is put together
  and not shown, and a rectangle forgotten that was never painted; a
  window that can go above the bar, or is kept wholly on the screen; an
  old top that stays lit under a new window or a raised one, and a next
  one that is not lit after a close; a new window that is not the colour
  of paper, that keeps the damage of being made, that goes where the one
  before went; a window closed by a thread that is not its own, a surface
  that is not freed, a closed window that is still held; what was drawn,
  shown at the corner of the screen; a move that leaves the old picture;
  keys that go to the lowest window; the line of a frame taken for desk,
  the whole band taken for the box, the lowest window found under the
  pointer and not the topmost; a program told the place on the screen and
  not on its inside, not told of a button that comes up, or told at every
  move; a list read from the top of the screen, left open, opened by the
  whole bar; a click that does not raise, a box that calls at every click,
  a window of no thread that cannot be closed; a pointer that leaves a
  trail, a hold that outlasts the button, every move taken for a press; an
  application defined twice over, one that leaves its windows; keys that
  stay with the console, a console that keeps the screen, a stop that
  keeps the keys, the surface, the applications or the screen; a boot that
  keeps the windows of the machine before, that starts the window manager
  whatever the world says, or never. All were noticed. lisp/terminal.lisp,
  the console and the driver of the keyboards and pointers, by the host
  tests, 35 ways: a terminal that does not move its rows up, or leaves the
  last one as it was; a place that does not move on, no new row at the
  last column, a run of characters as long as the string; Backspace and a
  carriage return that do nothing, a tab that is one space; text that is
  drawn and not shown; a cursor that is never taken away, that shows when
  nobody reads, that is at the top of its cell; CLEAR that leaves the
  place; Ctrl-C that is always a character, or never, with what was typed
  ahead kept, with a line that waits not seen; a reading that goes on past
  the end of its line, or is never over; a listener that writes somewhere
  else, whose box does nothing, that says nothing first; a terminal of any
  size; a console that draws while the screen is lent, a screen that comes
  back as it was left, or to where the console was, or that was never
  lent; a loan that outlasts the machine; a line feed after a carriage
  return taken for a line, an echo on another stream; a failure in what is
  told of a key or the pointer that takes the driver down; the pointer
  told after whoever waits, or when nothing changed; keys that go to the
  console whatever was asked; a boot that keeps where they went. Three got
  through at first, and the tests have what catches each since: the last
  row left as it was after a scroll, because the row that the test wrote
  there was as long as the one before; the refusal of a terminal of no
  size, which the window under it refused in other words; and the loan of
  the screen that outlasts the machine. The substrate and the sessions, by
  booting, 13 ways: values that are lost on the way out of a loop; an
  interrupt that stops the thread for good, or is never looked at; a
  version that is the name; a world without the terminal; a boot that does
  not ask the window manager; and, for the sessions to notice on a real
  keyboard and mouse, a box that does nothing, a hold that does not move, a
  list that launches nothing, a stop that leaves the desk on the screen,
  keys that go nowhere; a cleanup that can be cut short, and a stop that
  is forgotten when it came during one. All were noticed, and one of them
  showed a mistake that no case was looking for. With the launcher broken,
  a listener's thread once ended holding the window manager's lock: Ctrl-C
  had reached it at the safe point before the call that gives a lock back,
  in the cleanup of an UNWIND-PROTECT, and the cleanup stopped there. DESTROY-THREAD
  could always do that to a thread, which then died with the lock; an
  interrupt leaves the thread alive to ask for the lock again. A thread is
  no longer stopped or interrupted in the middle of a cleanup. And before
  any of this, the first boot with windows found that values which leave a
  loop by RETURN lost all but the first, in the evaluator since M6b, where
  SBCL keeps them: the function that says which window the pointer is on
  gives two.
  From M13: the two sessions from the disk image that macOS makes, with
  4 GiB and four processors, and the first on x86_64 with 128 MiB,
  `-cpu max` and four processors; a machine whose file system was taken
  away at the prompt, with `(clara:provide-files)`, where the editor and
  the browser are loaded from the files that the handoff read, and the
  browser says that nothing is there; how long things take, in the
  hundredths of a second that the machine counts: under Apple's hypervisor
  one to load the editor's file and open its window, and four to read
  boot.lisp, 1100 lines, and show it; emulated on the same Mac, six and 43;
  the boot with a collection at every safe point, 23 s on the Mac while
  its collections went through the whole world and 15 s since they are
  made before the world is loaded; the manual's new chapter, as a browser
  shows it; the whole of `make test` in an Ubuntu container, with clang 18,
  QEMU 8.2 and SBCL 2.2.9. And the code broken on purpose, 131 ways.
  lisp/editor.lisp, by the host tests, 48 ways: a character that leaves the
  cursor where it was; a new line that is not counted, that is not
  indented, that is indented past the cursor; a line up that keeps the
  column whatever the line; the arrows that stop at the end of a line, or
  come out at the wrong end of the next; Backspace and Delete that join
  nothing, that leave the cursor at the start, that take the wrong
  character; Ctrl-K that always begins afresh, that always adds, that
  empties what it kept when there is nothing to take; a text put back
  without its new lines; a place past the end of a line; a file read
  without the line that ends it, with the cursor left where it was, with
  the old title; a text saved with its last line whatever that holds, and
  one that stays marked as changed; the line of an error counted from a
  comment, an error that does not move the cursor, forms that Ctrl-C does
  not stop, forms read in the package of whoever asks; rows that are not
  copied when the text moves, or copied the wrong way, or that keep their
  old place in what was drawn; a cursor that stays on the screen; a window
  that does not follow the cursor down, or along a line; rows drawn from
  their first column whatever is in sight; a status in the colours of the
  text, without the cursor of a question, without the place; Escape that
  gives nothing up, Enter that takes no answer for one; a text thrown away
  at the first asking, a refusal that is never taken back, or taken back
  after another key; a tab of eight spaces wherever it is, a page a row
  too long, Ctrl-S that asks for no name; a click that counts rows by the
  width of a cell, a button that comes up taken for a click, a click on the
  status row; a close box that closes whatever the text; an editor that a
  file it cannot read takes down. Two got through at first, and the tests
  have what catches each since: forms read in the package of whoever asks,
  which under SBCL is the same package unless the text says IN-PACKAGE, as
  the test's text now does; and Enter with no answer, which saved under no
  name and said so, where the test had only looked at the text.
  lisp/files.lisp, by the host tests, 27 ways: directories and files in one
  order, or in the order they came; a way up from the top; names with the
  directory before them; a directory above that is always the top; going up
  that picks the first name, a list that keeps its place; a title that
  stays; a file gone into like a directory, an editor launched without the
  name; a status that always has the keys; a name that is picked and looks
  like the others, a row that is drawn once and never again; a list that
  does not follow the pick, up or down, and a pick past the last name; any
  key that deletes, a list that is not read again after, a directory asked
  about like a file; Ctrl-R that loses the pick; a page a name too long, an
  arrow to the left that does nothing; a click that opens at once, one
  below the names, a button that comes up; a name without its slash that
  is no directory's; a directory that fails and takes the browser down.
  All were noticed. lisp/windows.lisp, by the host tests, 28 ways: a close
  box told once and for all; what happens kept without a limit, the newest
  first, never waited for, asked of a window that keeps nothing; a window
  of events without its box, a button told where it is on the screen; a
  title that the screen does not show, or that is anything; Alt and Tab
  that bring the second window up, that go to the window as well, that the
  screen does not show; an application launched without its arguments; a
  file loaded at every launch, or twice by two that launch at once; the
  packages of a file not noted, or forgotten when the file failed; a file
  that defines nothing and is not said; unloading that keeps the function,
  the threads or the packages, or does not wait for the threads; an
  application of the world's unloaded; one that is removed and stays in
  the list, a list that stays open while it changes; installing that takes
  the function away; a name found only as it is spelt; threads that are
  not noted. Two got through at first: the file that defines nothing, where
  the thread failed all the same, in other words, and the window that
  keeps nothing, which failed in the lock it does not have; the tests hold
  the words of both refusals since. The keys, by the host tests, 11 ways:
  up and down the other way round, Home for End, an Escape that types
  nothing, F11 for F12, two keys with one code, a key's code that a
  character could have; Alt that changes nothing, that stays down, the
  right Alt that is none; a line that takes every code for a character; the
  applications not installed. All were noticed. The substrate, by booting,
  17 ways: a deleted package that is still found, one that another uses and
  one of the system's deleted, no package listed; a list within a list not
  taken apart, &WHOLE that is nothing, a special variable that stays bound,
  a body that does not see the variables, one value where there are
  several; a whole name that is no name of a boot file, the directory's
  name in small letters only, any seven characters taken for it; a limit
  of the codes that is the highest code; and for the boot that collects at
  every safe point: a file that asks in vain, collections that are asked
  for and not made, boot.lisp not loaded again, the texts not evaluated
  again. One got through at first, boot.lisp not loaded again, since the
  line of the report counted the collections of both together; it counts
  them apart now, and the boot test wants thousands of the one and tens of
  thousands of the other. Trying these found two mistakes that no case was
  looking for. The boot test handed its patterns for the boot report to
  awk in a way that takes a backslash for awk's own, so a pattern with
  `\{5,\}` in it could never have matched: the patterns come from the
  environment now. And that boot runs the kernel that is on its disk, the
  one the first session of the machine was booted with: a kernel is tried
  there only after a first session of its own. From M14a: how long things
  take, under hvf, with `time` at the prompt (`(fib 30)` 390 ms walked
  and 110 ms compiled, five million additions in a loop 590 and 130, a
  million items pushed, reversed and mapped over 700 and 460); the pass
  over the 400 texts on x86_64 and on AArch64 emulated, 1.4 s each where
  hvf takes 0.4 s; the boot with the
  collector at every safe point emulated on the Mac, 108 s; the listing
  of functions with every kind of instruction in them, read by eye
  against the forms. And the machine and the compiler broken on purpose,
  143 times, in four copies of the tree at once. The machine, 68 ways,
  each tried by a boot: an instruction that does half of what it does or
  none of it, for most of the 47; a record that is not taken off, or is
  taken off when a GO from afar comes back to its tagbody; a block, a
  tagbody or a HANDLER-CASE that comes back with the bindings of what was
  left; a cleanup that keeps no values, forgets the exit, or begins with
  the bindings of its form still made; a function that returns with its
  bindings or its records left; arguments put in the wrong slots, the
  rest back to front, the last of two keywords and not the first; a
  function in C called with any number of arguments, or with the count of
  values left as it was; the checks of code, one by one. Ten got through
  at first. One was no mistake, a tag that a C variable held across a
  safe point, which the running function holds as well. One cannot be
  shown by a text: without the look at the stack before a call, the spare
  words past its end take what a frame of the usual size overruns by. The
  other eight each became a text, and five of them were of one kind, a
  single value taken from where the values of the form before it still
  lay. The compiler, 75 ways, each tried by the host tests and then by a
  boot: a shared variable that is no cell, or a cell that is never made;
  a function between two that is not handed a variable; LET and LET*,
  FLET and LABELS taken for each other; bindings and records left by a
  jump, and a word too many taken; nothing far, everything far, no
  barrier; a form with one value where it has several, in nine places; a
  default worked out too early, SUPPLIED-P asked too late; backquote
  without its depth, its splice, its dot; a list taken apart that may be
  too long or too short; an operand in the wrong bits of its word; the
  stack said to be a word shallower than it is. Sixty-three were noticed
  by the host tests and three more by the boot; of the nine that got
  through, three change nothing that can be seen (every exit the long
  way, a call counted too deep, a string before a body taken for a form
  of no effect) and six became forms of the host tests and texts of the
  kernel: a :NO-ERROR clause and a far block with words on the stack
  around them, a far block that is the last thing a function does, a
  local function under the name of a macro, a macro at the top that
  makes a DEFVAR. The machine under SBCL was too forgiving of one, a
  record left on the stack by a tagbody, which the kernel answered with a
  fault: it now knows where its records are, and says so when one is
  taken off while it is in force. Two more for the collector: the
  arguments of a call taken off the stack before the call, which every
  boot notices, and those of a MULTIPLE-VALUE-CALL, which only the boot
  with a collection at the safe points of compiled code does. From M14b:
  the same forms timed on the kernel of main and on this one, under hvf
  (the figures are in the entry of the milestone); the boot with the
  collector at every safe point emulated on the Mac, 61 s; what a world
  holds that main saved and that this one saved, 1449 KiB in 3159 and 879
  KiB in 1707; and a world that 0.0.19 saved, put on a disk beside the
  kernel of 0.0.20, which says that its objects are not laid out as they
  are here and makes the world from the files. And 69 mistakes
  planted, in four copies of the tree at once. The machine and the
  substrate, 51 ways, each tried by a boot: an instruction of the twenty
  that takes arguments it should leave to its function, forgets to look
  at the size of a sum, gives the wrong answer, leaves the values of the
  form before it or a word on the stack; the bit that says whether a name
  still means its function in C never looked at, never kept, taken for
  set in a world that was resumed, set for any function in C; a call of a
  compiled function with no safe point; the allocator, the interrupts and
  the collector's own count saying nothing of what they have for a
  thread; EVAL and LOAD that never reach the compiler, either of the two
  files not loaded a second time, a macro handed its subforms, a DEFMACRO
  that makes a function, the clause of a condition kept. The compiler, 18
  ways, each tried by the host tests and then by a boot: an instruction
  for any number of arguments, with one value where its function may give
  several, with the wrong count of what it takes off the stack; a macro
  that takes its own name apart, that has no block, that does not see the
  variables or the macros around it, that says DESTRUCTURING-BIND where
  it is the one that fails; the compiler not saying that it can evaluate.
  Twelve got through at first. Four of them were two holes in the new
  texts, which are closed. The texts that give `svref` another function
  called it with something that is no vector, which the instruction hands
  to the function whatever its bit says, so the bit was never what was
  tried: they call it with a vector now. And nothing looked at what an
  instruction leaves on the stack when it has called its function in the
  middle of a form. The other eight change nothing that can be seen and
  stay as they are: a stop, a thread that queues and a turn that waits,
  which are seen a tick later through the timer; a collection less in
  each text of the boot that collects at the safe points of compiled
  code; the look at an exit under way that a safe point still takes,
  which nothing comes to; an instruction that always calls its function,
  which is only slower; and two words of an exit that is over, the clause
  in compiled code and the place of a GO in the evaluator's, which hold a
  few conses until the next exit and no function. From M16a: four small
  programs timed on the machine and translated, under hvf (the figures
  are in the entry of the milestone); the code of `fib` for both
  processors read back by LLVM's disassembler, instruction by
  instruction; every instruction that the two files write held against
  LLVM's assembler, 86 of them, all the same; and how long the texts take
  translated where the machine is emulated, 3.3 s on x86-64 and 2.2 s on
  AArch64. And 113 mistakes planted, in four copies of the tree at once,
  twice over, the second time against the tests that the first time
  asked for. The translation, 72 ways, each tried by a boot: an
  instruction that takes the wrong variable, constant or closed-over
  value, leaves a word on the stack or takes one too many, jumps the
  other way or to the next place, forgets its safe point, forgets to look
  whether an exit is under way after a call, or to ask whether its name
  still means the function in C; an instruction for a function in C that
  takes arguments it should leave to the function, a list that is none, a
  sum that does not fit, a place past the end of a vector; a function
  that takes any number of arguments, does not look for room on either
  stack, leaves its variables as it found them, counts its bindings
  wrongly, never asks its records about an exit; the top of the stack not
  handed to the kernel or not taken back. The two processors' files, 18
  ways, by the host tests and two of them by a boot of x86-64: a register
  in the wrong half, a displacement or a jump that is a byte off, a
  condition turned round, a number written short. The kernel's part, 23
  ways, by a boot, and by two boots where a world has to come back: code
  that the processor is never told was written, or that is never freed;
  a record not kept from one instruction to the next, a place that a
  record names not gone to; arguments sorted over each other; a function
  that returns with its bindings left; no T; a function that is never
  entered by such code; the routine that calls, in both entry.S, not
  keeping the function, not looking whether a safe point has something,
  leaving the value where C left it; an image without its code. Twelve
  got through at first, and eight of them were holes, which are closed
  with a text each. Nothing counted what a form leaves on the stack, and
  a jump out of the middle of a form that dropped one word for six went
  unseen: the texts count the stack now, after every form that makes a
  record, takes values or is left from the middle (`%stack-depth`), which
  holds the machine to it as well. Nothing gave a vector a character for
  a place, which is a small number to code that does not ask. No
  function with a record was called by such code while its caller had a
  special variable bound, so a count of bindings that was half of what
  it should be undid the caller's and was not seen; nor one whose
  arguments C sorts out. Nothing called itself with as little in hand as
  a call can have, which is the one way to come to the end of the
  processor's own stack before the value stack's on AArch64. No call of
  a function came upon variables that held what an earlier call had left
  there, a list that was freed since: the collector follows such a word
  into memory that is no object, and a text now puts one there. And the
  answers were the same when the processor left every call, or every
  instruction, to C after all, which is correct and no quicker than the
  machine: the self-test now counts what is left to C while a function
  calls itself twenty thousand times and a loop adds, and on the stress
  boot that a loop without a call has a collection at each of its first
  fifty turns. The other four change nothing that can be seen: JUMP-IF-
  TRUE turned round, which no part of the compiler writes; the CAR of NIL
  left to the function, which is only slower; the stack cut back short
  when it is full, which every caller above puts right; and the
  processor's stack eight bytes off what the calling convention says on
  x86-64, which nothing in a kernel built without those instructions
  minds. From M16b: four small programs timed on the machine and on the
  processor, under hvf, with loads ten times as long as the clock's tick
  wants (the figures are in the entry of the milestone); the translator's
  two halves timed by themselves, on a function of 870 instructions and
  on one of 70, before and after CASE and before and after the assembler
  kept what it wrote, which is how it was known where the time went; the
  code of `fib` for AArch64 read back by LLVM's disassembler; 38 more
  rows of the two files' instructions held against LLVM's assembler; the
  stress boot timed line by line under hvf and emulated, for this
  version and for the one before it, built from the same sources in a
  copy. And 116 mistakes planted, in four copies of the tree at once,
  twice over. What is pending, 50 ways: pushed in the wrong order, not
  pushed where two ways through the code meet, before a call, a jump, a
  record or a closure; arguments in each other's registers; a variable
  fetched after it was set; a constant, a variable or a closed-over value
  off by one; a small integer written without its tag; a value dropped or
  kept one too many. A comparison written with its jump, 20 ways: the
  jump turned round, here or behind the function; the jump written twice;
  the name not asked whether it still means the function in C. The count
  of values, the sums, the way to the machine and what the assembler
  keeps, 30 ways. The world translated, and CASE, 15 ways. Twenty got
  through at first, and nine of them were holes in the texts, which three
  new texts close. No text read a variable, set it and read it again
  within one form, so a variable that was fetched after it was set went
  unseen. None compared with a number below zero that was written into
  the function. And no text gave another function to a name whose
  comparison is written with its jump: that way comes back with a value
  only then, since a comparison of what are no numbers is an error, and a
  jump that was turned round there, or left out, or a name that was not
  asked, changed nothing. The new text gives `<`, `null`, `eq` and `cons`
  other functions and calls a function that was compiled before, with
  numbers and with lists. (A fourth text asks how many values there are
  after a function that has an instruction of its own, wherever its value
  goes next; it closed nothing that was planted.) One more was a check that
  came too late: a start that translated only the translator was put
  right by the first `translate` of the self-test, which reaches every
  function, and passed; the count is taken right after TRANSLATE-ALL now.
  One was no mistake: the count of values was still written when the
  instruction that takes the value is one that something jumps to, which
  nobody reads either, and it is not written there any more. The other
  nine change nothing that can be seen: three pushes of what is
  pending where nothing ever is, before DISPATCH, SUPPLIED and under a
  NIP; the count of values not written before a DUP, after which the
  compiler always says how many there are; a function translated a second
  time and the second code thrown away; functions that nobody holds
  translated too; what the assembler wrote the first time not kept, which
  is only slower; and a function more in the world, which was the check
  of the harness itself. And the mistake that was not planted: every
  instruction taken for one that something jumps to, because
  `make-array` fills with 0 and 0 is true, left the code as long as it
  had been and every answer right, and was seen in the listing of `fib`.
  The host tests hold that code to a length now. From the disk of the
  user's own (0.0.22): tools/run.sh by hand
  with a file that is not there, with a `~` that the shell had left as it
  was written, and with `WORK=` empty; x86_64 and AArch64 emulated with
  GIC version 2 with such a disk, and AArch64 with a volume of 64 MiB that
  macOS made (hdiutil), each reading, writing and carrying a file across;
  a file typed into the Editor and saved while the variable was set, which
  was on the user's volume and not on the system's, with the file browser
  open there; a volume kept in a variable across a start from a saved
  world, which 0.0.21 looked a name up on; QEMU refusing a disk that macOS
  had open, and macOS opening one that QEMU had, which the manual warns
  of; and a work volume with a cluster of nobody's planted in its table,
  which the boot test's checker found. Seven mistakes planted, all
  noticed: the guard taken out of `the-volume`, and out of `names` alone
  (the host tests); no copy of the work disk for a boot, the copy made
  and not used, the work disk ahead of the boot disk on the bus, the disk
  not attached at all (the manual's two boots); and `make test` taking a
  work disk from the environment. From the disk that is open on the Mac
  (0.0.23): a copy of a `.dmg` of a gibibyte that macOS had made, with a
  file on it that 0.0.21 had written, which 0.0.22 listed, loaded, carried
  across and wrote beside; tools/run.sh by hand with a work disk that the
  Finder had open, which was ejected and the machine started, and the
  same with the boot disk; a work disk that a process on the Mac had its
  directory in, which stopped the script with what to do; and a disk that
  was opened under another name of its directory, /tmp for /private/tmp,
  which the first version missed because it held names against each
  other and not files. None of this is in `make test`: it needs a Mac and
  a disk in the Finder.

Shortcuts and loose ends, under the milestone that settles each one. A
session reads its own group before it starts, and whatever it leaves open
is added here in the same change.

M15a, an upgrade in place, what it left:

- UTM was not tried: a second VirtIO drive added for the upgrade and taken
  out after it, whether it has to come after the system's drive in UTM's
  list (the system finds its own volume by what the handoff wrote there,
  so it should not have to), and what UTM makes of a machine that starts
  itself again in the middle. A folder that UTM shares is still no way in.
- The handoff writes to the boot volume at every start, through the
  firmware's file system: `\clara\starts`, and `\clara\next` when a system
  is tried. A volume that the firmware cannot write to gets neither. Such
  a machine starts, never passes a world over, cannot be upgraded in
  place, and takes the first volume on the bus for its own. Nothing says
  so in the boot report.
- The old kernel stays in memory while the system that it started is
  tried: the firmware lists it as loaded, and the new kernel's allocator
  leaves those two mebibytes alone until the next start. And the old
  kernel's handoff is what starts the new one, so a kernel from before
  0.0.26 cannot be upgraded from at all: tools/run.sh puts a disk of that
  kind aside, under a name that it says, and starts from a new one.
- A system that was tried and failed keeps its directory, with a file
  `failed` in it, until an upgrade is asked for again or another system
  takes the old one's place. The disk has room for it, and nothing shows
  it but a listing of `/clara`.
- (Settled in M15b and M15c: what was defined comes across as text, the
  values of variables as far as they are text, the new world is saved in
  the place of the old system's, and the window manager is started in it
  when it was running. A saved world that does not come to its prompt a
  second time is replaced.)
- Sums are held when a system is taken from another disk, and not when a
  kernel is started: a file of the system's directory that went bad on the
  disk afterwards is read as it is.
- The upgrade takes any system that is not the one that runs, an older
  one as well, and says nothing about which is newer: `make run-*` after a
  `git checkout` of an older commit puts the older system on the disk.
- Both kernels are on the disk and both are replaced, the other
  processor's without ever having been started on this machine.
- `make test` builds its systems to upgrade to from the same sources under
  other names (build/system-other, build/system-broken), so what is tested
  is the mechanism and never a real difference between two versions. An
  upgrade from the release before to this tree would need that release
  built, which CI's one commit does not have.
- By hand, and in no test: tools/run.sh itself, which `make test` never
  runs without `DISK=`. A disk kept across a build and given the build as
  a second disk; the same build twice, which gives no second disk;
  `FRESH=1`; a disk from before 0.0.26, a copy of Julio's, put aside; a
  second machine on a disk that one is running from, which is refused
  with the reason where `lsof` is there to ask; and a work disk beside all
  of it, a copy of his, with his own file loaded from it.
- What was broken on purpose: 67 mistakes in lisp/fat.lisp,
  lisp/system.lisp, kernel/boot.c, kernel/lisp/image.c, kernel/sha512.c
  and the function that says what a start was, each run through the host
  tests or through the boots that upgrade. Five got through. Four became
  tests: a line of a manifest that is no file and reads like one; a count
  of free bytes that left the last cluster out; a directory that could
  not be entered in a full root, whose cluster has to be given back; and
  the count of starts, which a system on trial has to begin anew, seen
  only where a disk says "at once", so `make test` has a boot that goes
  that way (tools/at-once.txt). The fifth changes nothing: the length of
  a file is held against the manifest before its sum is, and no file has
  the right sum and the wrong length.
M15b, work kept as text, what it left:

- What takes a definition back is not written down, apart from the window
  manager's REMOVE-APPLICATION and REMOVE-COMMAND with a name that is
  written out (since 0.0.28): after DELETE-PACKAGE, or a SETF that takes
  a function's place, the form that defined the thing is still in the
  file, and a world that is made of the text has it again.
- What is written down is decided by a form's first word (DESIGN.md), so
  a good deal of what changes a world is not: a form inside another, a
  PROGN or a LET; a SETQ, and a SETF of a function or of a property; what
  was done to a package after its DEFPACKAGE, by EXPORT, IMPORT or
  USE-PACKAGE, so that a package which was put together by hand comes
  back as its DEFPACKAGE made it; what Ctrl-E evaluated in the editor,
  which is in the editor's file; and the forms of a file that was loaded,
  of which the LOAD is written down and nothing else.
- What is not a definition is not written down: in a world that is made
  of the text alone, a variable that was changed after its DEFVAR has the
  value that the form gives it, and a form that got its value by doing
  something does it again, or fails: a DEFVAR that opened a window is
  passed over in a world without a window manager. Across an upgrade the
  values come along and the window manager is started (M15c).
- The file keeps a definition where its name was first defined. A later
  version of it that leans on something which was defined in between, a
  macro for one, is loaded before that, compiled as a call of a function,
  and fails when it is called. The order of a session is not always an
  order that loads, and nothing here sorts it: the user moves the form in
  the file.
- (Settled in M15c: a world that came back as an image loads what the
  two files have that it has not.)
- A LOAD is written down as it was typed, and the name of a file does not
  say which volume it is on: a new world looks it up on the volume that
  the machine started from. A file that was loaded from a disk of the
  user's own, with `clara.fat:*volume*` set, is not found there, which the
  report says. The volume has no name of its own yet. A LET of the
  variable does not reach another thread, so the Editor and the file
  browser follow a SETQ only, and a user who sets it has to set it back.
  Which disk is the user's is "the second" still; a machine with more
  disks needs a mark on the volume.
- The file is read and written whole for every form that is written down,
  and read a form at a time to find the one to replace. That is nothing
  for the hundreds of forms of a session and grows with the file; nothing
  makes it shorter but the user.
- A text that takes the kernel down, a fault and not an error, costs two
  starts, and the third has nothing of `/home` and says so. The file is
  not marked: once a start has come to its prompt the count begins anew,
  and the next world that is made from the files loads the text again.
  It is for the user to put the file right at that third start, or to
  save the world there.
- A file is given a minute (`clara.system:*patience*`), by the clock,
  whatever the machine: where a machine is emulated, an honest file that
  loads a great deal may be cut short. The variable is the world's, so a
  form of `init.lisp` can give `defined.lisp` longer, and nothing can
  give `init.lisp` longer but a world that was saved with another value.
- The two files are refused as the argument of a LOAD that stands at the
  top of either. A file that one of them loads, and that loads one of
  them, goes round until the stack is full or the minute is over.
- UTM was not tried: that `/home` is made and written on the drive that
  UTM made of the image. A second drive for the user's files was not
  tried there either (0.0.22): whether UTM keeps it apart from the
  system's drive when that is imported again. UTM turns an imported drive
  into a qcow2 file of its own, which the host does not open, so carrying
  files in and out by the host is QEMU's way only.
- A form of the text that fills the stack is passed over on ClaraOS, which
  the upgrade boot sees. Under SBCL a full stack in a thread ends the
  whole run, so the host tests have no such form.
- What was broken on purpose: 64 mistakes in lisp/system.lisp,
  lisp/listener.lisp, lisp/fat.lisp and lisp/boot.lisp, each run through
  the host tests, and through the upgrade boot or the manual's where only
  a kernel can tell. Seven got through. Five became tests: the package
  that a listener says a form was read in, which the test could not tell
  from the package afterwards; a variable and a function of one name,
  which are two entries of the file; a LOAD whose name is worked out, on
  the host and at a kernel; and a volume of an earlier start, which the
  file system has to forget and has to refuse as the place for a world.
  Two change nothing: the name that a form defines is printed in the
  form's own package, and any one package would do as long as it is the
  same for both forms; and a text that names a package which is not there
  is marked as not read to its end, where the name alone has the same
  effect.

M15c, a world made again, what it left:

- What counts as the user's is COMMON-LISP-USER and the packages that
  were made after the world was, apart from the ones called CLARA. So a
  function that the user added to a package of the system's is in no
  account, and a package of the user's that is called CLARA-something is
  taken for the system's.
- What comes across as a value: numbers, characters, strings, symbols and
  lists of those, up to 20000 parts and 64000 characters of text. Not a
  vector that is no string; not a structure, until the reader takes back
  the `#S(...)` that the printer writes; not a list that leads back into
  itself. Two variables that held one list hold two after the upgrade.
  The variables of the system's own packages are not carried at all: a
  setting like `clara.native:*translate*` or `clara.system:*patience*` is
  as the new system makes it, unless `init.lisp` sets it.
- The values are given back after the whole text is loaded. A form of the
  text that works something out from a variable sees the value that the
  variable's form gave it, and not the one that was carried.
- The account is written by the shutdown that starts the trial. A machine
  that is reset from outside after `(clara.system:upgrade :start-again
  nil)` leaves none, and neither does a system from before 0.0.28: the
  new system says that it has no account, and the world is the text's.
- The new system takes the old one's place before it loads the text
  (`commit`). A text that takes the new kernel down does not send the
  machine back to the old system: the count of starts is what catches
  it, and the third start has no text.
- A start in a saved world compares forms as text. A form that was only
  written differently counts as new and is evaluated again; a form that
  was taken out of a file stays defined in the world; and of `init.lisp`
  only what is new is evaluated, so that file is no script that runs at
  every start.
- A world that was made without the text, after two starts that went
  wrong, follows no text until `(clara.system:load-home)` is typed in it,
  and no later start says so again.
- The note of a saved world that was passed over is the length of its
  file and where it begins on the disk. Two worlds saved one after the
  other could have both numbers in common; nothing reads the file to
  tell them apart. And when the world that takes the place of one that
  does not start fails in the same way once it is saved, the two go
  round: every other start comes to its prompt.
- A world is saved without being asked after an upgrade and when a saved
  one failed twice, and at no other start. A machine whose world was
  never saved has no image, and makes its world at every start, as it
  did.
- What is said is kept in the world, the last four hundred lines of it,
  and `(clara.system:report)` writes all of them out at once.
- UTM was not tried.
- The stress boot writes nothing down: tools/stress.txt begins by telling
  the listener not to. With a collection at every safe point, writing one
  form into `/home/defined.lisp` took twenty seconds on the Mac's emulator
  and about a minute on CI, where the boot went from 249 s to 423 s of its
  600 with M15b. So the writing down is not tried under the collector's
  slow test, and what it costs grows with the file: every form reads the
  whole of it.
- By hand, and in no test: tools/run.sh from the seat, with a copy of
  Julio's work disk beside the machine's. A new disk, a function and a
  variable defined, the variable changed, a file written to `/home`, the
  window manager started, a shutdown; then another build, which the
  machine took as it started, and the new world had the function, the
  value, the file's form and the window manager; then the plug pulled
  after one more definition, and the start after it loaded that one from
  the text into the world that the upgrade had saved.
- What was broken on purpose: 105 mistakes in lisp/system.lisp,
  kernel/lisp/builtin.c and lisp/boot.lisp, each run through the host
  tests, and through the boot that upgrades, the one that fails, the
  manual's or a first boot where only a kernel can tell. Thirteen got
  through. Ten became tests: packages of the system's own in the account,
  two ways; an account written where names are looked up and not where
  the machine started; a value that does not read back as it was; a name
  that was a function there and is a variable here; a saved world told
  from another by its length alone, and by its place alone; a form that
  the world has in another package; and a world that is made keeping the
  report, and the knowledge of the text, of the one before it. One was a
  restriction that restricted nothing, a name that had to be written out
  before a removal was held against the file, and is gone. Two change
  nothing: a form that names a package is never among the forms that a
  world is said to have, so it is evaluated whether it is looked for
  there or not; and a world that does not note what it took out of the
  file finds at its next start that the file has nothing new.
- Once, the host tests ended with SBCL's "unhandled condition in
  --disable-debugger mode, quitting" and no line of their own, right
  after a test was edited, and passed when they were run again as they
  were, and in the two hundred runs after that, eighty of them one after
  the other for no other reason. What it was is not known. (It is since
  2026-11-21, when CI showed it again and with where it came from: under
  SBCL, `clara:destroy-thread` looked whether the thread was running and
  then told it to stop, and a thread that ended between the two had SBCL
  signal that there was nobody to tell. lisp/host/clara.lisp takes that
  for what it is now, a thread that needed no telling, and the same for
  `clara:interrupt-thread`. ClaraOS's own threads were never in it.)

M15d, upgrades over the network, what it left:

- ClaraOS was not published when this slice ended, and no machine took a
  release without being given an address and a key by hand. It is since
  0.0.31 ("ClaraOS, published", under the infrastructure that is done),
  with what Julio said to each of the three things that stood in the way
  (2026-11-20). Where: not at a place that answers plain HTTP, which is
  what this slice had asked for, with "Enforce HTTPS" switched off for
  the website ("we don't do that here"), but at
  `https://claraos.org/releases/`, the directory `releases` of what the
  site's workflow publishes, which M15f lets a machine fetch from. The
  key: he made one (`python3 tools/release.py key <file>`), its public
  half is in lisp/system.lisp, and the secret half is his and the
  publishing's. It says whose releases a machine takes over the network
  and nothing else: a system from a disk is held against its manifest
  and against no key, and somebody who publishes a ClaraOS of their own
  gives the variable the public half of their own key. And publishing:
  the website's workflow builds, signs and lays out a release for every
  change that is merged. What that left has a group of its own, below.
- No TLS was this slice's, and is M15f's. The entry had left two ways
  open, HTTPS in ClaraOS or a file that is trusted and a road that is
  not, and this slice took the second: what it built fetches by plain
  HTTP. That stays, for a web server on one's own computer; a release is
  no longer fetched that way.
- The network was the client's half of each protocol, and of that the
  part that fetching needs: no ICMP, an address that was asked for once
  and kept whatever the server said about how long it lasts, one name
  server and no TCP for an answer that is too long, a TCP that sent one
  piece and waited, every second without growing slower, and counted its
  bytes from a number that the clock gives away. All of that is M17a's.
  What is still not there has its group below, under M17a: one card, the
  first; no pieces of packets, in either direction; no window above 64
  KiB, no selective acknowledgement and no time stamps. This side never
  listens, which is M17b, and there is no IPv6, which is M17c. Pieces
  that come early are kept, sixty-four of them at most.
- HTTP: one file to a connection, which is closed after it. An answer
  that is sent in chunks is put together. Nothing is compressed, since
  nothing says that it may be. An address is followed three times when a
  server says that the file is somewhere else.
- The machine does not know the time. A release cannot be too old, and a
  key cannot have ended.
- `latest` is believed as far as its name goes (DESIGN.md), so somebody
  on the way can keep a machine from learning of a newer release, and
  can offer it any release that was once published and is newer than the
  one that runs.
- A fetch says nothing while it runs, and a release is a few megabytes: on
  a slow line the prompt stands still, and comes back with an error when
  nothing has arrived for ten seconds (`clara.net:*patience*`).
- Not tried: a web server on the Internet. Everything was fetched from
  this computer, through QEMU's network, and from a network that the
  tests make up. And UTM: its machine has a virtio network card on a
  network that it shares with the host, which should be this one.
- By hand, and in no test: tools/run.sh from the seat, with a web server
  on the Mac (`python3 -m http.server`) handing out the release that
  `make test` had laid out in build/releases: the machine asked for its
  address, fetched, was given the key, took the release, started again
  and came up as the other system. And `NET=`, which has to say `-nic
  none` to QEMU: left to itself, QEMU gives the AArch64 machine a card of
  its own.
- The thread that takes what arrives must never ask the network anything.
  It did: to answer a piece of a connection that it does not have, it
  asked who has the sender's address, and the answer to that was its own
  to take, so it stood still for ten seconds for every such piece. An
  answer now goes to the card that the packet came from. A test found
  it, and not a planted mistake.
- What was broken on purpose: 129 mistakes in lisp/net.lisp,
  lisp/system.lisp, kernel/ed25519.c, kernel/sha512.c and
  kernel/lisp/unsafe.c, each run through the host tests, a first boot, or
  the boot that fetches. One could not be built. Seventeen got through.
  Thirteen became tests: a frame whose padding is not cleared, and one
  that does not say whose it is; a question for an address that goes to
  one card and not to all; a card of an earlier start that still sends;
  a page that is written again while the card still has it; an answer to
  the beginning of a connection that is none; a machine on the same
  network that is reached by the way out; the end of a file that is not
  counted; the memory of a connection that grows and forgets what had
  come early; the end of an answer's head that falls between two pieces;
  a frame that the thread cannot answer, which must not end the thread;
  a disk that no longer goes before the network; and, in the kernel's
  own tests, a sum taken of pieces that end in the middle of a block. One
  was a line that did nothing, clearing twelve bytes that nothing ever
  writes, and is gone. Three change nothing that can be seen: whoever
  waits for something looks every twentieth of a second whether or not
  it is told that something arrived, so not telling costs time only; a
  signature whose number is exactly the order of the base point, which
  the check takes for too large, cannot be made to pass the rest of the
  check either; and a check that held only thirty-one of the thirty-two
  bytes of a signature's point against what it worked out would still
  refuse every signature that a test can make, since the point goes
  into the sum that the rest is worked out from.
- What the five milestones cost CI, on the first green run of each: the
  whole job 7m54s, 10m33s, 14m10s, 14m40s and 15m28s, of a limit that went
  from 15 minutes to 25. The boot that fetches takes 47 s there. The
  stress boot took 202 s, 249 s, 423 s, 371 s and 382 s of its 600: it
  grows with the world, since every form that its session types is
  compiled with a collection at every safe point, and a collection goes
  through a heap that now has the network and twice the system in it.
  The 423 s were the writing down, which that session no longer does. It
  is the boot to watch when more goes into the world. Twice that day a
  run stood in its first step, installing packages on the runner at 46
  kB/s, until the limit ended it: started again, each passed.
- The made-up network of the host tests answered every repeated
  acknowledgement by sending a whole window again, which made thirty
  thousand pieces of one lost piece in a second and looked like a fault
  of the machine's. A web server sends the one piece again, once, and so
  does it now.

M15e, shutting down, what it left:

- UTM was not tried. Its Request power down sends QEMU the same
  `system_powerdown` that the tests send, to the same kind of machine, and
  a ClaraOS that turns itself off should end the virtual machine there as
  it ends QEMU; that it does, and what UTM makes of a machine that starts
  itself again, is for somebody at a UTM window to see.
- The DSDT is searched and not read (kernel/acpi.c). "Off" is the first
  number after the name `_S5_`, and the power button of a machine without
  a PC's fixed hardware is in the first region of memory after the string
  `ACPI0013`. QEMU writes both that way, on both machines and with either
  version of the interrupt controller. A firmware that writes them another
  way is said to have no way of being turned off, or no button. The type
  of S5 is 0 on QEMU, so that the kernel shifts it to the right bits of
  the control register is not something a boot can notice.
- The button is asked for four times a second, by a thread. Its interrupt
  comes by a line on both machines, and no line is wired here (Devices, in
  DESIGN.md).
- Ctrl-D at the first prompt halts the machine as it always did, with
  nothing saved, and a machine that has halted is deaf to its power
  button: the host has to stop it. The tests end their sessions that way
  and look at the screen afterwards, which a machine that turned itself
  off does not have.
- What is asked before a shutdown is the windows, and of those only the
  ones that were given a function for it (`:unfinished`), which the editor
  is. A thread that computes, a program without a window, and a file that
  is open for writing and not closed yet are not asked and go with the
  machine: such a file is not written.
- A world is saved at every shutdown, as it is. One that was broken at the
  prompt is saved broken, and starts like that: `:save nil` is for the one
  who knows. One that does not come to its prompt is passed over (M15a),
  and replaced the second time (M15c).
- (Settled in M15b: a world is saved on the volume that the machine was
  started from, wherever `clara.fat:*volume*` points, so a shutdown with
  the variable set to a second disk no longer stops at SAVE-IMAGE.)
- tools/run.sh no longer starts QEMU with `-no-reboot`, under which a
  machine that started itself again ended QEMU instead. A kernel that
  resets the machine by a fault it cannot report, three faults in a row on
  x86_64, now starts again and again where it used to end QEMU.
- By hand, and in no test: `(clara.unsafe:power-off)` and
  `(clara.unsafe:reset)` straight from a prompt, on the three machines;
  the button pressed with nobody listening, which the kernel has to forget;
  and a session that pressed it twice. What a machine says when the
  substrate cannot turn it off is seen under SBCL only, where no machine
  can: every machine that the tests boot has a way.
- What was broken on purpose, to see that something notices: 66 mistakes
  in lisp/disk.lisp, lisp/windows.lisp, lisp/editor.lisp, lisp/system.lisp,
  kernel/acpi.c, the two power.c and the three functions in C, each run
  through the host tests or through the two boots of tools/power.txt. Four
  got through. Two became tests: a command taken out of the launcher's
  list that is not its first, and a second request to shut down while the
  first is saving the world. One draws nothing that differs, the line
  across a list without applications, which lies on the list's own edge.
  And one cannot be seen on these machines: the search for a device's
  registers in the DSDT stops at the next device's name, and QEMU's
  generic event device has its registers before any other is named.

M15f, HTTPS, what it left:

- UTM was not tried, as with the five before it. A machine there needs
  the device that makes numbers, which the manual says how to add when
  the report says that there is none; whether UTM gives a machine one by
  itself was not looked at.
- One of each, and no more: TLS 1.3; X25519 for the exchange of keys;
  AES-128 in Galois/Counter Mode with SHA-256. A server that speaks only
  an older TLS is refused in those words. One that wants another exchange
  of keys asks to begin again, which is refused too, and not answered
  with another: the curve P-256 is the one that every server has to have,
  and its arithmetic is there, for signatures, but with a number that is
  a secret it would have to take the same time whatever the number is,
  which it does not. The cipher of ChaCha20 and Poly1305 is not there
  either, nor AES-256.
- AES is written with its table of 256 bytes, so how long it takes
  depends a little on the key (DESIGN.md says why that is let be). The
  cipher that does not have that is the one in the point before.
- A certificate that was taken back by whoever signed it is still taken:
  nothing asks (no OCSP, no lists). Certificates are known that are
  signed with RSA's older padding or on the two curves, over SHA-256,
  SHA-384 or SHA-512, and that have keys of RSA's, from 2048 bits to
  4096, or on the two curves. Anything else is "signed in a way that is
  not known here": RSA's newer padding in a certificate, Ed25519, the
  curve of 521 bits, which one certificate of the list has its key on,
  and SHA-1, which three of the list's certificates are signed with, each
  by itself, where nothing checks it. What a
  certificate says that has to be understood is understood for four
  things (whether it may sign, what its key is for, its names, what it
  may be shown for); a certificate with anything else of that kind is not
  taken, limits on the names that a signer may sign for among them.
- The list of whom the system trusts is Mozilla's of 2026-11-05, 118
  certificates, the file that curl publishes (SHA-256 427c0642...7285).
  It is renewed by hand: `curl -o lisp/roots.pem
  https://curl.se/ca/cacert.pem`, and a look at what changed. A system
  has the list that it was built with until it is upgraded. Nothing
  takes a certificate out of the list short of editing the file, and
  what `clara.tls:trust` added is forgotten by a world that is made
  again: a line in `/home/init.lisp` is where it belongs.
- The clock is asked once, as the machine starts, and counted on from
  there with the kernel's ticks. Nothing sets it, nothing asks the
  network what time it is, and it has no zone: it is Greenwich's when the
  firmware's is, which QEMU's is. A file that the system writes is still
  dated 1980.
- The numbers that nobody can guess come from virtio's device and from
  nowhere else: not from the processor's own instruction for them, where
  it has one, and not from a pool that is kept. The numbers that TCP and
  DNS tell their exchanges apart by are still the ones of M15d, made by a
  rule from the time and a count.
- Every file is a connection of its own, greeted from the beginning:
  some thirty greetings for a system. Nothing comes back to a connection
  of before (the tickets for that are passed over), and nothing asks for
  two files over one. Where the machine is virtualized, a greeting and
  300,000 bytes after it take less than two hundredths of a second.
- A machine that is asked who it is says that it has no certificate, and
  what the server makes of that is the server's.
- A file whose length is not said has to be ended with the word that the
  connection is over. Python's web server does not say it unless it is
  told to, which tools/serve.py does; a web server that drops such a
  connection is refused, where a browser would take the file.
- The Internet was tried by hand, and no test goes there:
  https://claraos.org/ and a picture from it, the same from an address
  that begins with http://, which the website sends on, a file of the
  repository from github.com, which sends on to
  raw.githubusercontent.com, and that address itself. Those are
  certificates of two authorities, with keys of both kinds. The machine
  says "ClaraOS" and its version to every web server that it asks
  (User-Agent), which is why nothing else was asked.
- Found on the way, in M15d's code: the memory of a connection is moved
  to where there is more room by the thread that takes what arrives,
  while the thread that fetches reads it, or has just handed it to its
  caller. A connection has a lock for its memory now, and takes nothing
  more once the file is somebody's (`frozen`). Nothing had shown it. With
  TLS it shows: a long file over a closed connection fails under SBCL,
  whose threads really run at once, when the lock is taken out again.
- Found on the way, in M15a's tests: tools/trial.txt listed `/clara` with
  the system's own directory before the one named "broken", which is how
  the two sort for a system whose eight digits begin with 0 to b, and
  not for one whose digits begin with c to f. One build in four failed
  that boot. No commit on the way had been one of them; 0.0.30's first
  build was. One verdict of M15a's planted mistakes had rested on it
  (`:starts` always 0, in a copy of the tree whose digits began with c):
  planted again, with the session put right, it is noticed for what it
  is.
- The disk of the kind FAT12 that one machine of `make test` starts from
  was twelve megabytes, with clusters of four kilobytes, and the world is
  saved on it twice over for a moment. With this slice the world and the
  system no longer fitted: it is twenty-four megabytes now, with clusters
  of eight, which is as far as that kind goes with such clusters.
- Mistakes planted on purpose: 238, of which 66 in the arithmetic in C,
  held against the self-tests that a boot runs, 16 in what Lisp calls of
  it, in the clock and in what is started, held against a boot with its
  session, and 156 in the Lisp, held against the host tests. 29 got
  through at first. 22 of them became examples and tests: a
  multiplication that needs its topmost piece, which next to no numbers
  do and numbers just below a power of two do; a modulus with a zero
  before it; a signature whose second number is the order too much, and
  a key whose x is above the order, both made up for the purpose and
  both taken by OpenSSL where they are signatures; the session's sum
  with a key, whose key and bytes were of one length; a piece of a
  certificate that says it is longer than what it is in, a length
  without end, a date that is not Greenwich's and one of the last
  century, an authority that says outright that it is none; signatures
  of RSA's with one thing wrong in the block that they are made of, the
  word for the sum, a zero before the signature, dirt among the zeroes
  and the bit above the block; a greeting that goes on for longer than
  is kept, a word of an older TLS that is none, a half of the exchange
  of keys that makes nothing, a question about who the machine is that
  is asked wrongly, the beginning of a message in the record of the
  first one, the older way of signing with RSA where only the newer is
  allowed; a request that is longer than one piece of a connection; and
  an answer that ends in words while the connection under it stays
  open. Seven change nothing that can be seen: a whole block of SHA-256
  that waits is summed with what comes next, or at the end; a key that
  is no point of its curve gives sums that no signature fits, and no
  numbers can be made that tell; a sum above the order comes to the same
  in the multiplication; a signature with a zero in it, and one that
  comes to no point at all, are each refused by the check for the other;
  a number below another that is taken from an uneven stretch of
  numbers is wrong by one part in millions of millions; and a piece that
  arrives after the file was handed on arrives in an instant that no
  test can make.
- What it cost CI, on the first green run: 12m16s for the job, of its 25
  minutes; the boot that fetches 38 s, where M15d's had taken 47; the
  first boots of the three machines 43, 38 and 37 s; and the stress boot
  231 s of its 600, where M15d's had taken 382. That run's machine was
  plainly a faster one than the ones before it, so the two are not to be
  held against each other, and what the new files cost a boot there is
  not known from it. On the Mac the emulated first boot went from 31 s
  to 36.
- One more fault was mine and lasted an hour: what is said over a
  connection gave up with words of its own when the connection was no
  longer open, which it is not when the answer has already come and was
  too long. The host tests failed for it one time in two with six of
  them running at once, and never alone. They are run eight at once
  after a change to lisp/net.lisp now, three times.

ClaraOS, published, what it left:

- The workflow has not run. The environment `github-pages` takes
  deployments from main only, and its secret is read by nothing else, so
  the first run is the one that the merge of the pull request starts.
  What was tried instead, on the Mac: the script of the signing step,
  taken out of the workflow file as it is written there and run by bash
  with a key that was made for the purpose. With no secret it stops and
  says so; with a key that is not the system's, `make release` refuses,
  and nothing is in `_site/releases`; with a key whose public half
  `make release` was told to go by, the release is laid out and holds.
  The file with the key is gone afterwards each time. The build is CI's
  own, with the same packages, and `make release` runs in CI with every
  `make test` (`make release-test`). Not tried, since they cannot be before the
  merge: that the secret holds the key whose public half is in the
  source (if not, the step fails and the site stays as it was); the
  upload and the deployment with a directory `releases` in them; and how
  Pages hands out files that end in `.EFI`, `.pem` and `.sig`, or in
  nothing. The first thing to do after the merge: `(clara.system:newest)`
  on a machine, which has to name the system of main.
- No machine has taken a release from there. The first that can is one
  that runs an older system than the published one, so the next version
  is the first real upgrade over the Internet. Until then what is known
  is the two halves: a machine that takes a release by HTTPS from a web
  server on this computer (`make test`), and one that fetches pages and
  a picture from claraos.org (M15f, by hand).
- Only the newest release is there. A deployment puts the whole site in
  the place of the one before, and the release of the one before goes
  with it. Pages lets a file be kept for ten minutes by whoever fetched
  it on the way, so for that long after a deployment `latest` may name
  the release before, whose files are gone, or a file may be the one of
  the build before: the machine says that a file is not there, or is not
  what the manifest says, takes nothing, and has to be asked again
  later.
- What is published is main, as soon as it is merged, without waiting
  for the run of CI on main: the check that a pull request must pass is
  what stands before it, and behind it the trial that every machine
  gives a new system, which keeps the old one until the new one has come
  to its prompt. The kernels that are published are built by the
  website's job, and are not the files that CI booted: the same sources,
  and the same compiler as long as both jobs install the same packages.
  A release that waits for a green run on main, or is made of the very
  files that were booted, would be one workflow started by the other,
  and the site would wait a quarter of an hour for it. Julio was told of
  the two ways (2026-11-20, in the pull request and in the report); it
  is published at the merge until he says otherwise.
- A system's name says which sources it is, and not who built it: the
  system that the Mac builds from a commit and the one that is published
  from it have one name and kernels that differ. A machine that runs the
  one is told that it has the newest. And a deployment for a change to
  the site alone builds the same system again, with whatever compiler
  the runner has by then.
- One key, with no end and no successor. A machine takes what is signed
  with the key that its system has, so a new key reaches the machines by
  a release that is signed with the old one, which is only possible
  while the old one is there. Nothing says what happens when it is lost,
  or read by somebody else: every machine would have to be given the new
  half by hand, `(setq clara.system:*release-key* ...)`, or a system from
  a disk.
- `https://claraos.org/releases/` shows a browser nothing, a page that is
  not there: the directory has files and no page, and the manual names
  the address without linking to it.
- No test asks the place. The host tests look at what the two variables
  are, set both to NIL, and say where they look each time. A session
  that tells a machine to upgrade when no other disk has a system for it
  sets `clara.system:*releases*` first (tools/upgrade.txt,
  tools/at-once.txt), or has given the machine a name server that knows
  no name outside this computer (tools/network.txt, which so shows that
  the place is asked for: "there is no machine of the name
  claraos.org"). Nothing but that rule stops a new session from asking
  the real place: QEMU's network reaches the Internet.
- Found on the way, in M15a's Makefile, and mended: a build whose sources
  had gone back to what they were at an earlier build did not start. A
  Lisp file is changed, the system is built, the change is taken out
  again, and the system is built once more: its name is the earlier one
  again, the object with that name in it is still there, and older than
  the kernels of the build in between, so make did not link them again.
  They kept the other name, looked for their files in a directory that
  was gone, and the machine stopped with "boot.lisp did not load". Now
  the name is in a file, build/system.name, which is written when the
  name changes, and the object is made again when that file is newer;
  and the build stops when a kernel does not name the system whose
  directory it is copied into. Tried by hand in a copy of the tree: from
  that state, with nothing changed, with a Lisp file changed, and with
  the change taken out and the file as old as before. No test does it,
  since a test would have to change a source. make still goes by the
  second: a file that is put back in the second in which a build ended
  is not seen, which a script does and a person does not.
- By hand, and in no test, from a machine under tools/boottest.sh with a
  session of its own: a file of this repository of 568,718 bytes, more
  than either kernel, by HTTPS from raw.githubusercontent.com, held
  against its SHA-512; and `(clara.system:newest)` and
  `(clara.system:upgrade)` at the real place, which answered 404 for
  `/releases/latest`, as it must before anything is published.
- What was broken on purpose: 23 mistakes. Fifteen in lisp/system.lisp,
  in the order of what an upgrade over the network looks at, in what it
  says and when, and in the place and the key themselves: the host tests
  noticed thirteen, and the boot that fetches the other two, another
  address and a key with one digit changed, which is why its session
  names both in full. Eight in tools/release.py, the Makefile and the
  line that the Makefile reads the key from: `make release-test` noticed
  six. Two change nothing by themselves. Without the line that holds the
  release against the key once more, everything is laid out as before;
  that line speaks when the tool signs wrongly, which a planted wrong
  signature showed. And the count of the key's digits is only a clearer
  word for what the tool refuses anyway. The workflow file itself is
  held against nothing: a step that is left out of it is not noticed
  before a merge.
- What it cost CI, on its first green run: 17m09s for the job, the boot
  that fetches 54 s, and the stress boot 431 s of the 600 that it had.
  Publishing added nothing to that boot: the counts of its collections
  are within a hundredth of those of the run before, which was a commit
  of words alone and took 327 s, 14m39s for the job; and the first green
  run of M15f, earlier that evening, took 231 s, on a machine that was
  plainly a faster one. So the same work takes between 231 s and 431 s
  there, by the machine that a run is given, and what M15f's files cost
  that boot is now known: on a machine like the ones before it, 431 s
  where M15d's took 382. A machine a third slower than this run's would
  have run into the limit with nothing wrong. The stress boot has 900 s
  now, and the job 30 minutes where it had 25. That buys time and
  nothing else: the session is still the thing to make cheaper before
  more goes into the world.
- UTM: not tried, as before.

M17a, the rest of a network, what it left:

- Still not there. One card, the first that the machine has. No pieces
  of packets: one of IPv4's that was taken apart on the way is dropped,
  and the machine's own packets say of themselves that they are not to
  be taken apart. Of what ICMP can say, the machine hears that a
  packet did not arrive and that one was too long, and answers a ping;
  that a packet went round until its time was over, and that there is a
  better way than the one it took, it passes over. It does not answer a
  ping that was sent to everybody.
- A connection that is open is not ended by the word that the other
  side cannot be reached: that is believed of one that is beginning,
  whose number the word has to have, and anything later ends in the
  other side's silence, after as long as patience is.
- How fast a connection sends is found out roughly: ten pieces at first,
  one more for every word that more has arrived, half after a piece was
  lost, one after a silence, and never more than 64 KiB on their way.
  There is no stretch in which it grows slowly (RFC 5681 has one), the
  time that it waits for a word is a second that doubles, and is not
  measured (RFC 6298), small pieces are not kept back until there are
  more, and nothing is sent over a connection that is quiet to see
  whether the other side is still there.
- The server that gave the address is the only one that is asked whether
  the machine may keep it. When that server is gone the address is lost
  when its time is over, and the machine asks for one anew the next time
  that something wants the network; a connection that was open then
  goes on speaking from an address that is no longer its own, until
  the other side's silence ends it.
- A name is known by the first address that an answer has for it. A
  question says nothing of how long an answer this machine takes (EDNS),
  so an answer by UDP is 512 bytes at most, and anything longer is asked
  for again by TCP.
- What a real kernel was not seen to do, because QEMU's network does not
  bring it about: hearing by UDP that a port takes no questions (QEMU
  says nothing when the port of the host is closed, and the machine
  waits as long as patience is), hearing that a packet was too long, and
  asking whether it may keep its address, which QEMU gives for a day.
  Those three are tested against the network that the host tests make
  up, and against nothing else.

M17b, a machine that listens, what it left:

- Nothing keeps a connection closed that the machine takes: TLS here is
  the half that asks. So there is no web server in the system, since one
  would hand out its pages in the open, which is not how ClaraOS
  publishes anything (Julio, 2026-11-20, on plain HTTP: "we don't do that
  here"). A server's half of TLS 1.3 would need a certificate and a key
  of the machine's own, signatures made and not only checked, which the
  arithmetic in C does not do, and somewhere to keep the key. Whether
  that is wanted is Julio's to say; nothing of it is begun.
- A stream over a connection is lines of text, because that is what a
  stream is in this language: a function that writes a string and one
  that reads a line. So there are no bytes that are no text, a line is
  UTF-8 or an error, and one of more than 64 KiB is an error. Reading
  waits as long as `clara.net:*patience*` is and then fails; a function
  cannot wait for a line and for something else at once.
- What is written goes out as it is written: `write-line` is two
  segments, the text and the end of the line. Nothing gathers small
  pieces (Nagle's rule), which costs packets and no time.
- `close` ends a connection both ways: this side cannot say that it is
  done and go on listening.
- A port takes connections at every address that the machine has; there
  is no taking them from the machine itself only.
- UDP is not there for a program: the machine takes its packets for DHCP
  and for names, and nothing lets a function listen at a port of UDP's.
- A machine that begins connections and does not go on with them keeps
  a port busy: each such beginning holds one of the port's places, eight
  unless SERVE was told otherwise, for as long as patience is, and
  others are told meanwhile that there is no connection for them.
- `stop-serving` stops the threads that have connections, wherever each
  is: a function that was writing a file is stopped in the middle of it.
- The ports come back with a world that was saved, and the machine asks
  for its address as it starts for that, in a thread, so the line that
  says which address it has comes when it comes, between the lines of the
  boot report or after the prompt. A world that is made again, after an
  upgrade, takes no connections until a file of `/home` says so.
- Seen at a real kernel: a connection from outside, through the port that
  QEMU hands on, answered, and 300000 bytes sent to it (tools/network.txt,
  where the test's web server does the knocking, `/knock/`), on AArch64;
  and the machine speaking to itself, on all three machines
  (tools/session.txt). Not seen there: several connections at once, a
  port that is full, another side that goes quiet, a saved world that
  takes connections again; those are the host tests'. And UTM, where the
  machine is on a network that it shares with the Mac and should be
  reached at its address: untried.

M17c, IPv6, what it left:

- The machine does not ask whether somebody else on the network has the
  address that it makes for itself (RFC 4862 has it ask, and wait a
  second for an answer): two machines whose cards have the same address
  would both go on.
- The second half of its addresses is its card's address, the same on
  every network that the machine is ever on, which tells whoever sees
  both that it is the same machine. Addresses that do not give that away
  (RFC 8981, RFC 7217) are not made.
- It learns what a network is from the routers' own word and from
  nothing else. A network whose router says "ask a DHCP server for your
  address", or for who knows names, gives the machine neither: there is
  no DHCP for IPv6 here.
- One router, the first that said it is a way out, and no word about a
  better one is heard. What a neighbour said of its card is believed
  until the machine is started again: nobody is asked whether it is
  still so, and nothing is forgotten.
- Packets in pieces are dropped, as over IPv4, and none are made. What
  stands between the head of a packet and what it carries is passed
  over when it says how long it is, and the machine puts nothing there
  itself. It does not tell the network which addresses for many machines
  it listens to (MLD), which a switch may want to know before it hands
  the neighbours' questions on. How long a packet a router says the
  network takes is not looked at: pieces of a connection are 1380 bytes
  until somebody says that this was too long.
- Which address of a name is tried first is one rule out of the many of
  RFC 6724. When nothing answers at the first, the next is tried after
  as long as patience is, ten seconds, and not at the same time.
- A machine that comes onto a network without a router waits a second
  for one, the first time that something wants the network, and asks
  twice more, four seconds apart, in the background.
- What a router says later, a new network, an end to an old one, changes
  the machine's addresses without a word: `(clara.net:addresses)` shows
  them.
- Written out, an address of IPv4 inside one of IPv6 ("::ffff:10.0.2.2")
  is not read.
- Seen at a real kernel, under QEMU, whose network has a router: the
  address, the way out and who knows names; pings to the router's two
  addresses and to the machine itself; a file by HTTP and by HTTPS from
  the computer that QEMU runs on, by a name that has only an address of
  IPv6 and by the address between brackets; a connection of the
  machine's own to itself. Not seen there: a connection from outside by
  IPv6, since QEMU hands on a port by IPv4 only; an address of the
  Internet's own, and with it IPv6 going first; a network with IPv6
  alone; what a router said running out. Those are the host tests'. And
  not seen at all: UTM, and any network that is not made up.
- The boots that fetch need the computer that runs them to have IPv6 at
  all, at least to itself (::1): the test's web server listens there for
  what the machine sends to fec0::2.
- The line that the machine says about IPv6 names its address and the
  way out, and not who knows names, though it has that from the router
  too. Under QEMU the router names somebody only when the computer that
  QEMU runs on has a name server of IPv6 itself, so with it the line was
  one thing on the Mac and another in the Ubuntu container, and would
  have been another on the Mac from one network to the next. The
  container found it before CI did: every boot of `make test` was run
  there before the first push.

M17a to M17c, the three together, what checking them found:

- What was broken on purpose: 134 mistakes in lisp/net.lisp and
  lisp/tls.lisp, one at a time, each run through the host tests in a copy
  of the tree. Eighteen got through the first time, and each is a test
  now, or made one stricter: a name server that cannot say, after which
  the next has to be asked at once and not a second later; the answer to
  an earlier ping, which is no answer to this one; a server that says
  that the machine may not keep its address, which has to count before
  the time runs out by itself; the word that bytes have arrived which
  were never sent; a beginning that is said again every second and not
  after twice as long; the word that a machine cannot be reached, about
  a packet that another machine sent; a name server that is silent about
  addresses of IPv6, which must not cost the address of IPv4; a
  connection that both sides have ended, which has to be forgotten then
  and not when patience is over; threads that `stop-serving` has to
  stop, and not leave to their own patience; a side that says how long
  a piece it takes, to a machine that had not begun the connection; a
  function that goes on writing to a side that has given up; a router's
  word from an address that is not on this wire; a message of ICMPv6's
  whose checksum is wrong, and a packet of UDP's over IPv6 that has
  none; two ways of writing an address with one colon too many; and, two
  of them, what had come early and waits behind a gap while the machine
  makes room in front of it, which needed a network that loses pieces on
  their way to the machine before it showed. Two more were planted after
  that and change nothing that a test can see: whether a thread other
  than the card's goes by the card's note of where the packet came from
  that it is looking at, now that the note is read once (below); and
  the order in which a machine that begins to speak IPv6 writes down
  that it asked the routers and that it has an address, which the
  card's thread could read in between, a thousandth of a second wide.
- The network that the tests make up threw away what came early, which
  no machine does: so every piece after a lost one had to be sent again,
  the machine's quick way of sending a lost piece again had nothing to
  be quick for, and a lost piece cost a second. It keeps what comes
  early now, as the machine itself does, and a lost piece costs a tenth
  of that; two tests hold the machine to it.
- A fault that a test found, one run in several, and that was in the
  network of M15d as well: whoever sends a packet looked whether the
  card's thread had a note of where an answer to this address goes,
  read the note a second time to compare, and a third time to take the
  card from it, and by then the card's thread could have taken the note
  away. The packet then went to a card's address that was none, which is
  an error and no packet. It showed when a file had moved: the answer
  that says so and the second connection are to the same address at the
  same moment. The note is read once now, and by the card's thread only.
- Twice a boot stood still, and what it was is not known. Once in the
  Ubuntu container, in the boot that fetches, while eight runs of the
  host tests had the Mac to themselves: the same boot alone, and the
  whole of `make test` again on a quiet computer, passed. And once on CI,
  in the first run of this pull request: the x86_64 machine that
  upgrades was told to start again, a second time, said that it was
  starting again, and nothing more came from its serial port in the four
  minutes that were left, neither from the firmware nor from the system.
  That boot had not touched the network, these slices changed nothing in
  C, and the machine starts itself again by the same instructions as
  before; the same boot then passed fourteen times running in the
  container and twelve on the Mac, and the same commit passed on CI when
  the run was started again. Eleven runs of CI before this pull
  request had not shown it, so it is put down here as something that
  these slices may have brought about, and not as chance. A boot that
  does not get to its end now leaves a picture of its screen with its
  logs (tools/boottest.sh), since the serial port says nothing of a
  machine that stands still: the next time that picture tells a
  firmware that did not start the system from a system that reported a
  fault, and both from a machine that never went down.
- What the three cost CI. The first run that passed took 13m18s where
  main's last had 12m21s, and its stress boot 281 s of its 900 where it
  had 251; the next took 20m18s, and its stress boot 549 s. The runner
  was slower that time, by a third for every other boot, and by twice
  for that one. The boot's own report said where: what it does before
  its session took what it takes on main, to the second, and the session
  took the rest. The session is typed with a collection at every safe
  point, which every call of a function in Lisp is, in every thread; and
  the card's thread had come to make a dozen such calls four times a
  second, on a machine that never used its network, to look at what time
  had brought about. An idle card's thread wakes once a second now,
  four times while the machine has an address to keep and twenty while
  there is a connection, and reads two words before it looks further.
  Measured as
  the note under "What a translated world costs CI" says, on the Mac
  with the machine emulated: 186 s before, 169 s after, 167 s with no
  network card at all, and 157 s for main the day before, so what is
  left is the world, which is larger by what lisp/net.lisp grew. That is
  a tenth of the boot on the Mac. On CI it is to be seen only between
  two runs on runners of the same speed, which is luck: after the
  change, one run took 13m59s and its stress boot 288 s, on a runner
  about as fast as the one that had taken 281 s before it; and the next
  took 18m29s and 466 s, on a runner on which every other boot took the
  seconds that it had taken in the run of 549 s. So the slow runner is
  most of that figure, and the thread was some eighty seconds of it.
  Main had been seen at 17m19s and 435 s on such a runner (#38), so the
  three slices cost CI about a tenth, by either kind of runner. The
  limits stay as they are, 900 s for that boot and thirty minutes for
  the job; 549 s and 20m18s are the most that either has been seen to
  take, and neither would have been without the thread.

M18a and M18b, fonts, what they left:

- Nothing fits an outline to the pixels. A font file has programs for
  that, one for each glyph, which are passed over, and nothing stands in
  for them: a stem lands between two columns of pixels as often as on
  one, so at 9 to 13 pixels the letters are softer than the console's,
  and two stems of one letter can differ in weight. What would mend it is
  the machine that runs those programs, some two hundred instructions and
  the tables that they use, or a rule of this system's own that moves
  the stems and the lines of a font onto whole pixels.
- No kerning: the Go fonts have no table of it (`kern`), and the newer
  table that most fonts have (`GPOS`) is not read. Every glyph moves on
  by a whole number of pixels, its own way rounded, so a line is not as
  wide as the font's units add up to, by half a pixel a letter at the
  most; letters at places between two pixels would want a picture of each
  glyph for each such place.
- One glyph to the character, in the order of the string: letters are not
  joined (ligatures), an accent that is a character of its own is not
  put on the letter before it, and nothing is written from right to left.
  Of the tables that say which glyph a character has, the forms 4 and 12
  are read and no other; a font that has only others is refused.
- Files of the other kind of outline (CFF, curves of the third degree,
  which most files have whose names end in `.otf`) are refused, and so
  are collections of several fonts in one file. A font whose outlines can
  be varied (`gvar`) is read as its plain self.
- A glyph of parts: a part's way across and up is taken as it is written,
  also where the file says that it is to be changed with the part
  (`SCALED_COMPONENT_OFFSET`); and where two parts lie over each other
  and go round opposite ways, which a part that is mirrored does, they
  leave a hole, since what a shape covers is summed with its sign, as
  FreeType sums it. The Go fonts have no such glyph, and none of parts at
  all: that half of the reader is held against the tests' own files, and
  was held once, by hand, against FreeType on fonts of the Mac's that do
  (below).
- A shade is laid over a pixel on the numbers as the pixel has them, not
  on the light that they stand for, so light letters on dark come out
  thinner than dark ones on light. And a pixel has one shade: the three
  parts of a pixel on a flat screen, which lie side by side, are not
  shaded each by itself.
- The pictures of the glyphs are in the heap, a word of 8 bytes for every
  shade, and a world that is saved holds the ones that were made by then,
  although the next start lets go of them: 7000 shades in six fonts when
  the first session of `make test` saves its world, 54 KiB. All fonts
  together keep 1048576 shades at the most, and then all of them let go.
  A vector of bytes would be an eighth of that, when the language has
  one. The world itself is larger by what lisp/type.lisp is, 163
  functions, most of them the readers and writers of its four
  structures: a world that the first session saves is 4604 KiB where
  main's is 3895, with 1444 KiB of code for the processor where that has
  1334, and is loaded from the files in 270 to 300 ms where that takes
  230.
- The system's fonts are read into memory by the handoff at every start,
  1.3 MiB of them, whether anything is drawn in them or not, and a system
  is that much more to copy or to fetch when a machine takes a newer one
  (the manifest holds every file against its sum). No boot of `make
  test` took longer for it on the Mac that could be told from one run to
  the next; "What the two cost CI", below, has what was measured.
- A family that has no file for a style gives the nearest that it has:
  nothing makes a bold or an italic of an upright. Sizes are whole
  pixels, from 4 to 400, and a glyph of more than a million pixels shows
  nothing.
- `clara.windows:*font*` is read when the window manager starts, so a
  change shows after STOP and START, which ends the applications. The
  bar, the list and the bands of the windows keep their heights, 20 and
  21 pixels: a font of more than 16 pixels is cut off there, and no font
  makes them lower. A terminal, the editor and the file browser are grids
  of the console's cells: Julio's issue #51, styles and sizes in the
  applications, is that work, and this is what it would stand on. The
  console itself, before the window manager and in a fault report, keeps
  its pictures of 8 by 16: it is the first thing that works and the last
  that should stop.
- A file is read once at a start, with a lock, and a font of it can be
  made by two threads at once, which then both make the same glyph: the
  second one's is kept, and nothing else is lost. A program that draws
  in one font from two threads at the moment when the fonts let go of
  their glyphs makes some of them twice.
- What was only checked by hand, with tools/fontcheck.c, which is not a
  part of `make test` because it needs FreeType on the computer. (1)
  FreeType's pictures against these, pixel by pixel, with nothing fitted
  to the pixels on either side: every character from 32 to 1279, which is
  Latin, Greek and Cyrillic, of all eight files at 9, 13, 16, 24 and 64
  pixels, some ten million pixels. They differ by 0.3 to 1.8 shades of
  255 on the average, by 23 at the worst, and by more than 16 in one
  pixel of ten thousand; no glyph moves on by another number of pixels
  than FreeType's own way rounded. The differences are where curves are:
  FreeType cuts a curve into pieces that lie up to a sixteenth of a pixel
  from it, and these lie within a sixty-fourth, which is why making them
  finer made the difference larger and not smaller. (2) The reader
  against FreeType on eight fonts of macOS that have glyphs of parts,
  Arial, Times New Roman, Verdana, Georgia, Courier New, Trebuchet MS,
  Comic Sans MS and Andale Mono, some 14 000 glyphs: every point of every
  outline is the same. That comparison found two rules that the first
  version did not have, and each has its test now: a glyph's points are
  moved to where the file says that its left edge lies, and a glyph of
  parts lies and moves on as the part does that it names for that. The
  fonts of macOS are not ours to put into the tests; the Go fonts, whose
  every outline the host tests hold against FreeType's sums, have neither
  case but for one glyph of the italics.
- Planted mistakes, 143 of them, each in a copy of the tree, with the
  host tests after it or, for the functions in C, a build and a boot: 115
  in lisp/type.lisp, 7 in what lisp/draw.lisp gained, 10 in
  lisp/windows.lisp and 11 in the substrate. 122 were noticed at once,
  and one did not build, was planted another way and was noticed. Twelve
  of the rest became tests: a number of two bytes that is read across the
  end of a file (a file is now cut at every length of its list of tables,
  with a device behind its last byte that fails the run when it is read);
  a table of characters without its last range; groups of more than one
  character in the form 12; a character whose glyph the file does not
  have; a part that lies elsewhere when it is drawn by itself; a line of
  text whose height is no whole number of pixels, and a glyph that moves
  on by a half; the cell that a row of a picture has to spare; a glyph of
  more parts than can be counted, none of them too deep; letters of
  another height in the window manager, and a name in its list that is
  wider than the button; and a kernel that does not start the fonts when
  it starts from a saved world, which every session passes by luck, the
  handoff having read the files to the same place as before, and which the
  report's line `type:` now tells. Eight change nothing that can be seen:
  four that have a piece go on into a row or a pixel that it only
  touches, where it adds nothing; a code past 65535 in the form 4, which
  the table's own last range answers; a font that keeps its glyphs when
  its file is read again, which START and FORGET have let go of by then;
  and two that take a check away where the bytes of the file, held
  against its length, refuse the same glyph a moment later.
- A fault of M17a's, found here and mended here, because eight more
  files to fetch made it show: a connection spoke from a port that was
  picked among 16384 with nothing asked but whether a connection of this
  machine's has it now. So a machine that opens many connections to one
  place, one after the other, sooner or later speaks from a port that a
  connection which is just over spoke from; the other side still
  remembers that one, takes the new beginning for a piece of it that has
  come late, and says nothing, and ten seconds later the machine says
  that the other side does not answer at its port. `aarch64-network`
  takes a system of 46 files from a web server over 55 connections, and
  failed that way on the Mac while it was being watched, at the last file
  but one. A machine that was made to speak from one port twice in a row
  gets no answer the second time, every time; and of 300 files fetched by
  HTTPS one after the other, main's kernel lost one in three runs of
  four, and this one none in four. A port now rests for two minutes after
  a connection spoke from it (`next-port`, `forget`, and a host test that
  has the device that makes numbers say the same number twice, which
  notices either half of the change taken out again). Over
  plain HTTP the same 300 lost none on either kernel: the test's web
  server lets go of such a connection at once, and of one that is kept
  closed a moment later.
- One run of `make test` in the Ubuntu container, of three, failed in
  `aarch64-network` before that was mended, while the Mac ran its own
  `make test` beside it. By where the difference lay, the machine did not
  say within the time that it gives itself that 10.0.2.2 takes no
  connection at its port 1; the log of that run went with its container,
  so that is read off the last line of what was printed and no more, and
  whether it was the same fault is not known. The same boot then passed
  twelve times there, ten of them one after the other with the Mac loaded
  in the same way. M17's group has that boot standing still once in the
  container on a loaded Mac: it is put down here because it was seen in
  this work, and not as chance.
- What the two cost CI. The system's directory is 3400 KiB where it was
  2012, and every boot reads it. The stress boot, where the machine is
  emulated, on the Mac, main and this at the same time: 190 s and 203 s.
  What that boot does before its session takes what it took, to the
  second but for seven more texts of the self-test, and the session,
  which is typed with a collection at every safe point in a world that
  is larger by lisp/type.lisp, takes the rest: a fifteenth. On CI the
  first run took 16m3s of the job's thirty minutes, and its stress boot
  365 s of its 900, on a runner between the two kinds that there are: its
  x86_64 boot took 48 s and its `aarch64-network` 53, where the fast kind
  has 44 and 40 to 45 and the slow 55 and 57. Main's stress boot has been
  seen at 251 to 263 s on the fast kind and at 435 to 466 on the slow, so
  365 s on one between them says no more than the Mac's two figures do,
  and nothing against them. No other boot took longer there than main's
  last run had it, which was on the slow kind.

No milestone yet, to be picked up when they start to matter:

- Code for the processor, what it is still long and slow by. An
  instruction is translated with a look at the one after it and at what
  has not been pushed yet, and no further: a value lives in a register
  from the instruction that makes it to the next one, and every argument
  of a call is written to the stack. An instruction that stands for a
  function in C looks every time whether its name still means that
  function, three instructions of the processor's, where once between two
  calls would do. `*`, a binding, the values of a form and every record
  go to the machine, by the function's one way there. `(fib 35)` is ten
  times as quick as on the machine; a compiler that kept values in
  registers across instructions would be twice that again. What makes
  lists gains little: a million conses cost what the allocator and the
  collector take for them, which is C either way.
- Code for the processor, what translating costs. Translating a function
  takes five times as long as compiling it, 0.06 ms against 0.01 for a
  small one where the processor runs the code itself: the translator makes
  a list for every instruction of the processor's, and the two files that
  write them go through each list with `cadr` and `caddr`, with `get` for
  every register and with `ash` and `logand`, which are calls. Writing
  bytes into a vector as they are made, and the processor's instructions
  as numbers, would take most of that away. A typed form is translated
  before it is run, so the prompt pays it for every line, a tenth of a
  millisecond; with a collection at every safe point it is seconds, which
  is why tools/stress.txt types all but one of its forms with
  `*translate*` NIL.
- Code for the processor, what is not said. A function whose code would
  be longer than a megabyte is not translated on AArch64, where a jump
  that depends on a condition reaches no further: `translate` signals an
  error for it, and with `*translate*` it is left to the machine in
  silence; were it a function of the world's files, the start from the
  files would panic at its check, and none is near that. `disassemble`
  lists the machine's instructions and says that a function is
  translated; the processor's own are listed by
  `tools/processor-code.sh`, under SBCL and with LLVM, and by nothing on
  ClaraOS. `(room)` says nothing of the memory that code takes; the boot
  report does. A fault in such code is reported with its address and the
  words "code that the Lisp world made for the processor", and not with
  the function that it is in. `(let ((clara.native:*translate* nil))
  (defun ...))` at the prompt translates the function all the same, since
  the form is compiled before the LET binds anything; the manual says so,
  and a way to say "not this one" in the function itself is not there.
- Code for the processor, its memory. The region of the code is searched
  from its beginning for a free piece whenever one is free, which is a
  walk over every piece, a thousand in a new world and one more for every
  form that is typed: 2000 functions compiled and translated one after the
  other took 120 ms, the search among it, and it is to be looked at when a
  world has ten times as many. Its page frames go back to the kernel when
  the last piece is freed and when an image is made, and not in between.
  A function keeps the compiler's instructions beside the processor's,
  for the listing and for the machine; a world that never ran on the
  machine could do without half of them, the ones that the processor's
  code never leaves to it. Code is made of the instructions that a
  function has when it is translated: whoever changes those afterwards,
  which `clara.unsafe:compiled-function-code` lets him do, has changed
  what the machine would run and not what the processor does.
- Code for the processor, what nothing tries. The machine has an
  instruction that no part of the compiler writes, JUMP-IF-TRUE: its case
  in vm.c and its translation are tried by nothing. On x86-64 the
  processor's stack is kept a multiple of 16 bytes at every call into C,
  in a function and in the piece that leaves an instruction to the
  machine, as the calling convention has it, and nothing here would
  notice if it were not: the kernel is built without the instructions
  that care. Two threads that translate the same function at the same
  moment: the second looks again before it hands its code over, and that
  was read and not run. The bytes that the two files write for each
  instruction are held against what LLVM's assembler wrote for the same,
  by hand, 124 rows of the host tests' table now: a new instruction is
  one more line of `llvm-mc` (CLAUDE.md). And UTM: under QEMU's hvf the
  code runs on the Mac's own processor, which is what UTM uses.
- What a translated world costs CI, where both machines are emulated.
  Emulated on the Mac, x86-64 starts from the files in 33 s where it took
  30: translating what is there 2.1 s, the rest of the world 2.3 s where
  compiling it took 0.7, and the texts on the processor 1.5 s where they
  took 3.1 while the world they call was the machine's. The boot that
  collects at every safe point takes 19 s under hvf where it took 14, and
  emulated on the Mac 132 s where it took 102, timed line by line. Two
  things there were found by timing and not by thought. The collections
  at the safe points of the processor's code, fifty to a text, were all
  used up by the compiler, which is such code now, before the text had
  run a step: they begin when a function is made of what the compiler
  made (`lisp_native_watched`, vm.c), and that round runs before the rest
  of the world is loaded, 9400 collections where there were 900, because
  the functions of lisp/boot.lisp that a text calls are counted now. And
  the session at the end took 23 s under hvf where it had taken 8: every
  form that is typed there was translated with a collection at every
  call of the translator's. It types one translation now, of a function
  that the machine ran until then, 17 s of the 132, and compiles the rest
  for the machine. What CI's own runner makes of it is in the run of the
  pull request: read `ok after` there.

- The compiler. A form that is not what it should be fails when the code
  comes to it, with the evaluator's words, and nothing says so when the
  function is compiled: there are no warnings. A DEFVAR counts for what is
  compiled after it has been evaluated, so a function that is compiled
  before the DEFVAR of a variable binds that variable like any other, as
  under any Common Lisp, and unlike the evaluator, which looks at every
  call. The lambda list of a compiled function has its parts in Common
  Lisp's order, and the evaluator takes them in any. A compiled function
  takes any number of keyword arguments, and the evaluator's stops at 64.
  The errors of a list that is taken apart are a PROGRAM-ERROR as the
  evaluator's are, apart from the one for a keyword that is not known,
  which is a plain ERROR with the same words. Backquote makes every list
  anew, as the evaluator does, where a compiler may share what never
  changes. There are no tail calls: a function that calls itself last
  still goes deeper. Code is 8 bytes an instruction. That code uses its
  stack as it says is taken on the compiler's word (DESIGN.md), and a
  mistake there is a mistake in the kernel: the machine under SBCL counts
  the words and says so, the kernel's does not. A RETURN-FROM or a GO from
  one thread to a block of another's leaves that thread by its top, which
  is a panic for compiled code as it is for the evaluator's.
  Since M14b. The call is where the time of compiled code goes: a function
  is entered through some thirty lines of C that look at its lambda list
  each time, so a function of two lines, the reader of a structure's slot
  or `cadr`, costs as much to call as a long one. Putting such a function
  into its caller needs an answer to what happens when it is defined
  again, as the twenty instructions have one. Those twenty are a list in
  vm.c and in lisp/compiler.lisp: `length`, `list`, `logand`, `ash` and
  `char` are still calls, and a function of the twenty that is defined
  again is a call for everybody from then on. lisp/boot.lisp and
  lisp/compiler.lisp are loaded twice when a machine starts from the
  files, so nothing at their top level may count on being said once, and
  such a start takes a quarter of a second longer than it did, four
  seconds where the machine is emulated: compiling in the build would
  save that and wants a cross-compiler (DESIGN.md). EVAL compiles whatever
  it is given, also `(+ 1 2)` at the prompt, and TIME counts that in. The
  evaluator is still there, for the two files, for the substrate's own
  forms and for `(cl::%self-test)`, which evaluates its texts on top of a
  compiled boot.lisp in a world that was resumed; its DEFUN and DEFMACRO
  make what they always made, so a macro is one of two things, a lambda
  list with a body or a function of a form, and `expand` in eval.c looks
  which. A macro of MACROLET cannot use the variables of the function it
  is written in, where the evaluator let it. There is no `macro-function`,
  so nothing lists the instructions of a macro. The boot with a collection
  at every safe point now compiles each form that tools/stress.txt types
  under the collector, compiler and all, which nothing did before, and is
  quicker all the same: emulated on the Mac it takes 61 s, where it took
  110 s before M14a and 133 s after. On CI it took 127 s of its 600, in a
  run of five and a half minutes of its fifteen, where the runs of M14a
  took seven to nine minutes and that boot 215 to 328 s; a start from the
  files spends 3 s there on the two files and 1.1 s on the world.

- Applications. An application that fails, in its file as it is loaded or
  later, says so on the console, which is the serial port while the windows
  have the screen: its window goes, or never comes, and nothing on the
  screen says why. The launcher loads a file in the thread of the
  application, and LAUNCH waits for the window, so a click on a name in the
  list holds the pointer still for as long as the file takes to load, a
  hundredth of a second under a hypervisor and some tenths where the
  machine is emulated. The packages of an application are the ones that
  were not there before its file was loaded: a file that another thread
  loads at that moment is counted with it, and a file that adds to a
  package that was there leaves that behind when it is unloaded. Unloading
  deletes packages and nothing else: a function that the file defined in
  COMMON-LISP-USER stays, and so does whatever of the application something
  else still holds, a thread that it started for one. An application is
  installed with the whole name of its file, `/clara/editor.lisp`, and on a
  machine without a disk that has a driver the file is the one that the
  handoff read, as it was at boot. There is no list of what an application
  needs: a file that leans on another has to load it. The windows that an
  application had open do not come back with a saved world, though whether
  its file was loaded does. Nothing but the pointer opens the launcher's
  list, moves a window or closes one; Alt and Tab is the window manager's
  one key.
- The editor. A text is strings in the heap, one to the line, and a
  character that is typed makes a new string of its line: a line of many
  thousands of characters is slow to type in, and a file of many megabytes
  does not fit. There is no undo, no search, nothing is marked, and what is
  cut is one piece of text that each window keeps for itself. A file is
  read and written as its lines: one that does not end in a new line has
  one after it was saved, and whether its lines ended in a carriage return
  as well is kept only because the carriage return stays in the line, where
  it shows as a box, as a tab does. A name is typed whole, with nothing to
  complete it, and nothing says that a file is open in another window. The
  forms of Ctrl-E are read from a copy of the text and evaluated in a thread
  of their own, which the editor looks at every 20 ms; what they print goes
  to the console, and while they run every key but Ctrl-C is dropped. The
  line of an error is the line where the form begins, found by passing over
  blanks and comments of the one kind, `;`. The window is the size it was
  opened with, and a line longer than the window is wide moves all rows
  sideways. Left to the keys that the keyboard has: there is no way to the
  start or the end of the text but by pages.
- The file browser. It shows names, and neither sizes nor dates: the
  language's DIRECTORY gives names and nothing else, and the browser asks
  the language. It reads a directory when it comes to it and when it is
  told to, and does not notice what is written meanwhile. Every file opens
  in the editor, which refuses what is no text. It makes no directories and
  deletes none, as nothing in the system does yet, and renames and copies
  nothing. It lists the volume that names are looked up on, and no other.
- Keys. A key that types no character is a code from CHAR-CODE-LIMIT on,
  and whoever is handed codes has to pass over the ones it does not know:
  the console does, for a line, and so do the two applications. The
  function keys and Insert are handed on and nothing uses them. Ctrl and
  Shift change nothing about an arrow. The keypad's keys are their digits
  whatever Num Lock says. At a prompt a line is still edited with Backspace
  alone, on the console and in a window.
- Windows that keep what happens to them (`:events`) hold up to 1024
  things, and what happens past that is dropped without a word. Such a
  window always has a close box. A program is told of a button that goes
  down or comes up on its inside, and not of the pointer moving there, nor
  of the wheel. A window is the size it was opened with.
- A terminal keeps no memory of what it shows: text that has moved off its
  top is gone, nothing can be marked or copied, and its window cannot be
  drawn again in another size.
- The boot that has a collection at every safe point does its work before
  the world is loaded, when its volume has a file `\clara\stress`: boot.lisp
  again and the evaluator's texts again, in a heap of 270 KiB. What it does
  at the prompt afterwards, a few forms and a line on the keyboard, still
  goes through the whole world at every collection, and so does a session
  that somebody types by hand with `(cl::%collect-every 1)`. The files of
  the world, the console and the drivers and the windows, are never
  evaluated under it but for what those few forms touch.
- The host tests of the two applications. The editor and the browser are
  tested under SBCL on the host's own files, in a directory under /tmp that
  the run makes and deletes: OPEN, PROBE-FILE and DELETE-FILE are SBCL's
  there, and DIRECTORY, which gives pathnames under SBCL, is replaced by a
  function of the tests' (`clara.files::*names*`). So the one line of the
  browser that asks the language is tested by the boots alone, and so is
  everything that lisp/boot.lisp does between an application and the file
  system. An application that the launcher loads from its file is tested
  there with files that the tests write; the editor and the browser
  themselves are loaded by the tests, as the other files of lisp/ are.

- Windows. The windows that were open when a world was saved do not come
  back: the window manager starts with one listener, whatever was open.
  One lock is held for everything that is done to the screen, and what a
  window is told is called in the thread of the keyboard or of the mouse:
  a function there that takes long, LAUNCH for one, which waits for the
  application's window, holds that device up. QEMU sends the buttons of
  its mouse through another device than its moves, the tablet, each with a
  thread of its own, so a burst of both from a script can be handled out
  of order; a person is slower than that. A window whose thread ended
  without closing it, one that a thread opened at no launcher's bidding
  and then finished, stays on the screen: its close box closes it, if it
  has one, and CLOSE-WINDOW from anybody. CLOSE-WINDOW is refused to every thread but the
  window's own while that one lives, also where it would do no harm.
  Ctrl-C in a window forgets what was typed ahead of it. The cursor of a
  terminal shows while its thread reads, whether or not its window has the
  focus. What is drawn on the screen itself while the window manager runs,
  by `clara.draw:show` or on the screen as a surface, is painted over when
  a window moves there. The surface that the screen is put together on is
  as large as the screen, page frames side by side, 469 of them for 800 by
  600, and a rectangle that changes is painted from the desk up unless one
  window takes in all of it: how long that takes on a large screen, or on
  a real display, has not been measured. Ctrl-D on the serial port halts
  the machine with its windows open. A world that an older kernel saved
  starts without the window manager, as one from before 0.0.16 starts
  without what draws, and its console and its driver for the keyboard are
  the older ones as well: whether the files of lisp/, loaded at its
  prompt, bring the window manager in has not been tried. A world that was
  saved before 0.0.18 has the window manager of its day, whose launcher
  knows the listener and nothing of applications in files: the editor and
  the browser are on its volume and not in its list. Nor has the window
  manager been tried in UTM, where the keyboard and the tablet of virtio
  have to be added by hand, and neither have the editor and the browser:
  whether Alt and Tab and the arrows arrive there as they do from QEMU's
  monitor is for a person at a keyboard to say.

- Drawing. A surface is one thread's at a time: what drawing is kept to
  and what was drawn on are the surface's own, and nothing locks them, so
  two threads that draw on one surface get in each other's way, and a
  surface that one thread frees while another draws on it is memory that
  is written to after it was given back. The window manager keeps a
  window's surface to the thread that opened the window for that reason.
  What can be drawn is rectangles, outlines a pixel thick, text
  in the console's font and, since M18a, in fonts of outlines at any size,
  pictures of one bit to the pixel that are 62 pixels wide at most,
  pictures in shades, and copies. There are no lines but along a row or a
  column, no curves but a letter's, and no scaling of a picture. A colour
  lets what is under it show through only by the shades of such a
  picture. Text is drawn a glyph to the call of the substrate. A surface is
  page frames side by side, 469 of them for a screen of 800 by 600, and
  needs that many free in a row; it is never made larger or smaller. The
  collector knows nothing of that memory: a surface that nobody holds any
  more keeps its page frames until the machine stops, unless it was freed.
  A pixel that a program keeps in a variable is of the screen it was made
  for, and a world that is saved on one machine and started on another
  whose screen has its colours elsewhere shows the wrong ones. The damage
  of a surface is eight rectangles at most, and then the one around them
  all, so a change in two corners costs a copy of everything between. SHOW
  copies when it is called: nothing waits for the display to be between two
  pictures, there being no such signal from a framebuffer. PIXEL and a copy
  from the screen read the framebuffer, which a real display is slow at.
  The functions of CLARA.UNSAFE that write rectangles look whether the
  memory is mapped, not whose it is. START called a second time in one boot
  leaves the surfaces of the first unusable, with their memory. A world
  that was saved before 0.0.16 has no CLARA.DRAW, and starts without:
  `(load "draw.lisp")` and `(clara.draw:start)` at its prompt bring it in,
  and a world that is saved after that starts it by itself.
- The user manual. What is checked is its transcripts and its lists of
  names. Its prose is not: a sentence that was true when it was written
  stays until somebody reads it again. Three things in it are shown and not
  typed, since a machine answers them in its own way: the boot report, the
  line that says a heap is an image, and the reasons for which an image is
  refused, which are the kernel's words copied by hand. What each function
  of a package takes and gives is prose as well; only its name is compared
  with the files. Nothing in it shows a picture that was drawn, only the
  forms that draw one. The transcripts are typed at AArch64 only. The
  steps for UTM are as they were worked out from its source, and have not
  been followed in UTM itself. The page is one long page, without a search
  and without a place of its own for each function.

- Images. One file is looked for, `\clara\clara.image` on the volume that
  the firmware booted from, and SAVE-IMAGE writes where names are looked up,
  the first volume of the first disk: the two are the same volume as long as
  the boot disk is first on the bus. The firmware reads the image whole
  before the kernel starts, and the kernel copies it into the heap: for a
  moment the machine holds it twice, and a boot takes as long as the reading
  does. An image is as long as the heap, the free blocks in it included,
  since nothing moves: 1.5 MiB where 750 KiB are in use. Whether an image is
  one that this kernel can run is a number in image.c, raised by hand when
  lisp.h changes what an object is in memory; nothing notices when that is
  forgotten. An image from the other architecture is refused although most
  of a world would run there. A world that was saved in a state that does
  not start, with CAR redefined for one, starts like that at every boot
  until the file is deleted from outside, in the firmware's shell or on the
  host: there is no key to hold that says "from the files". The files of
  `\clara` are read at every boot and stay in memory, also when the world
  came from an image, for the boot at which an image is refused and for
  LOAD; without them and without an image the kernel panics, there being no
  world to start. An event comes back with the count it had. What a driver
  held when the world was saved, page frames and the registers of its
  device, is forgotten and not given back, which is right for another boot
  and means that a START called a second time in one boot still leaves the
  first one's behind.
- Disks. The block device of virtio is the one disk with a driver: UTM's
  drive has to be on its VirtIO interface, and with NVMe or USB the
  machine boots and sees no disk. One request is under way on a disk at a
  time, and whoever made it waits with the disk's lock: there is no queue
  of requests, and nothing is read ahead or kept. A disk that leaves a
  request unanswered for ten seconds (`clara.disk:*patience*`) is asked
  nothing more until the machine starts again, the request being still in
  its queue. A sector is 512 bytes; a disk that would rather be asked for
  larger blocks is not asked what it would like. Nothing tells a disk to
  put what it holds back on its platters: the driver does not ask for
  that part of virtio, and a device then has to have written what it
  answers for, which QEMU's does. A disk that arrives, leaves or changes
  its size while the machine runs is not noticed.
- lisp/virtio.lisp gives a device one interrupt for all its queues, asks
  for what its driver names among the bits 0 to 31 and for nothing else a
  device offers (no indirect descriptors, no event index, no packed
  queues), never tells a device to hold its interrupts back, and does not
  look at the bit by which a device says that it has to be started
  afresh. A device from before version 1 is refused, and so is one that
  insists on what was not asked for.
- Files. FAT is the one file system. Names
  are looked up on the first volume that START found, in the order of the
  disks on the PCI bus: the kernel does not know which disk it was booted
  from, and with the boot disk first on the bus, as QEMU and UTM have it,
  that is the ESP. Another volume is reached by binding
  `clara.fat:*volume*`, and there is no name that says which volume; one
  that START did not find is refused. A
  name has no `.` and no `..` in it. Letters match whatever their case as
  far as ASCII goes, where FAT means every alphabet; a short name outside
  ASCII is in an alphabet that the volume does not name, and shows as
  question marks. An entry's dates and its marks for hidden and system
  files are not read: the `._` files that macOS leaves on a volume show
  like any other. Every lookup reads its directories from the disk again,
  whole, and of the table eight sectors are held. A file is read whole,
  into page frames side by side, so a file larger than the largest run of
  free frames cannot be read, and there is no reading from the middle of
  one. Of a volume's tables the first is read, or the one the volume
  names; a table of partitions of the newer kind is taken as it is, its
  checksums unread and its second copy unused; partitions inside an
  extended partition of the old kind are not looked for. What a volume
  says of whether it was left in order is not read.
- Writing files. A file is written whole, from page frames that hold all of
  it: there is no writing at the end of a file or in its middle, and a file
  that takes the place of another needs room for both until its entry has
  changed. Directories are found and not made, and nothing is renamed or
  moved. There is no clock, so every file is of the first of January 1980. A
  volume is not marked as in use while it is written to, so nothing tells
  whoever mounts it next that a write was cut short; what is left then is
  clusters that belong to no file, for a program that mends volumes to give
  back. A free cluster is looked for from where the last search ended, an
  entry of the table at a time, and of the table eight sectors are held and
  written back to every copy when the next eight are wanted. The count of
  free clusters that a volume of the kind 32 keeps is kept in step when it
  is there, and not looked at. A short name is made of the letters of ASCII;
  any other letter becomes a `_` in it, and a name in small letters that
  would fit a short name gets a long one, where other systems set two bits.
- Files in the language. A name is a string: there are no pathnames, and
  where SBCL gives one, from PROBE-FILE and DIRECTORY, there is a string
  here. OPEN opens for reading or for writing, and not for both; a stream
  to read from has the whole file, read when it was opened, and gives it
  a line at a time, and a stream to write to keeps what it is given, in
  memory, until CLOSE makes the file of it. A file is text, UTF-8: there
  is no `:element-type`, and bytes are written by a driver, from page
  frames. `:if-exists` knows `:error`, `:supersede`, `:append` and NIL,
  and `:if-does-not-exist` `:error`, `:create` and NIL. There is no
  RENAME-FILE, FILE-LENGTH, FILE-WRITE-DATE or
  ENSURE-DIRECTORIES-EXIST. The errors of files are plain ERRORs, there
  being no FILE-ERROR. DIRECTORY knows `*`, and in the last part of its
  pattern only. PROBE-FILE gives the last part of a name as the disk has
  it and the directories as they were asked for. LOAD looks on the disk
  first: a file in the root of the volume with the name of a boot file
  takes its place. SORT takes lists, and STRING-EQUAL and STRING-LESSP two
  strings and no keywords.
- The disks of `make test`. A machine boots from build/boot-<name>.img,
  which tools/mkdisk.py makes of build/esp for every first boot: a volume of
  the kind 32 behind a GUID partition table for x86_64, one of the kind 16
  behind a table of partitions of old for AArch64, and one of the kind 12
  that is the whole disk for AArch64 with GIC version 2. A second boot gets
  a copy of the disk that the first one left. They take 12 to 36 MiB each,
  some 170 MiB of build/ after a run. tools/mkdisk.py is this repository's
  own reading of the format, like lisp/fat.lisp: what keeps the two honest
  is the firmware, which boots from the one and reads what the other wrote,
  the host's checker, fsck_msdos on macOS and fsck.fat on Linux, and by hand
  the image that macOS makes, which `make image` still needs macOS for. The
  second disk is build/scratch-<name>.img, a mebibyte of zeroes that
  tools/boottest.sh makes anew for every boot, for sectors that are
  nobody's. A session cannot show all of a directory: on the image that
  macOS makes there are `._` files beside the others, and the session has to
  pass there too. `make run-*` boots from build/disk-<arch>.img, which is
  made again when build/esp has something newer: a world that was saved
  there starts again at the next run, and is gone after the next build.
- The evaluator's self-test must not come near the file system, since
  its texts are evaluated again from the prompt with a collection at
  every safe point, where finding one file is thousands of calls. So
  what OPEN, PROBE-FILE and DIRECTORY do without a file system, on a
  machine without a disk, is only looked at by hand.

- A device interrupts by message or not at all. One whose interrupt is a
  line cannot be heard: which line goes where is written in the DSDT, in
  a bytecode the kernel has no interpreter for, so the pins of the I/O
  APICs stay masked. MSI-X is what the PCI code knows, and plain MSI is
  not. There are 32 interrupts for devices, and one that was handed out
  is never given back. With an ITS: the kernel takes a device's number
  there to be its bus, device and function, which the IORT table could
  say otherwise and is not read; a device has 32 events, 16 devices can
  have any, and every event goes to the one processor. Of several GICv2m
  frames the first is used. The trigger mode that ACPI gives for the
  timer's interrupt is still not applied.
- GIC version 2 stays (it was to be decided at M8). Its GICv2m frame is
  how a device interrupts under Apple's hypervisor too, where the GIC is
  of version 3, and the emulated boot with version 2 is the only one that
  takes that way on CI, which has no hypervisor: without it the frame
  would go untested there.
- No interrupt arrives for a character on the serial port. The timer's
  tick takes in what the port holds, so a character waits up to 10 ms,
  and what arrives meanwhile has to fit in the UART's FIFO: 16
  characters on the PL011, or 32, by its revision, and 14 on the 16550
  as it is set up. QEMU holds the rest back; a real serial line would
  lose it. What has been taken in and not read waits in 256 bytes, and a
  Ctrl-C behind more typing than that is not seen until some of it has
  been read.
- CLARA.UNSAFE. A write to memory that is mapped read-only is a fault
  that stops the machine; only an address where nothing is mapped is
  caught and made an error. `memory-64` gives an error for a value that
  does not fit in a fixnum, 62 bits and a sign: a driver reads such a
  register as two halves. `map-memory` maps a device where it is, so one
  whose registers lie at 64 TiB or above cannot be mapped: those are the
  heap's addresses, and on x86_64 the lower half of the address space
  ends at 128 TiB anyway. The firmware puts 64-bit registers that high
  when the processor has 47 or more bits of physical address, and no
  machine at hand has. What was mapped stays mapped, and nothing checks
  that an address belongs to a device, only that it is not memory.
- The PCI bus. Only the first range of buses of segment 0 is looked at.
  The addresses of a device's registers are the ones the firmware gave
  it, and a device the firmware left without any has none; nothing sizes
  a base address register. Bridges lead where the firmware numbered the
  buses. A device that arrives or leaves while the machine runs is not
  noticed. Registers behind I/O ports are told apart and not used.
- Keyboards and pointers. The keys type what a keyboard of the United
  States has on them, and nothing else can be chosen. Alt, the arrows
  and the function keys type nothing, so a line is still edited with
  Backspace alone. Caps Lock has no light: the queue that would carry it
  to the device is not set up. A mouse's wheel is ignored. The pointer is
  drawn by the window manager, and by nothing while that does not run. Every device
  costs a Lisp thread, a megabyte of stack and 644 KiB. `clara.input:start`
  is for the boot: called again, it opens the devices afresh and leaves
  the old threads and their memory behind.
- The console reads the keyboard ahead of the serial port: what is typed
  on both at once is not read in the order it was typed. Its cursor is a
  bar in the two lowest rows of a cell, and when it sits on a character,
  after a carriage return, it takes those rows of the character with it
  when it goes.
- The machines of `make test` have a virtio keyboard, mouse and tablet
  (tools/run.sh, `INPUT=`). The boot volume is a virtio disk with
  `bootindex=0`, which the firmware goes by whatever its variables in
  build/vars-<arch>.fd remember: a device ahead of the disk on the bus
  used to send the firmware to its own shell until that file was
  deleted, and no longer does. The boot test's keyboard is QEMU's
  `sendkey`, 0.1 s a key, and a line for it has to fit the 64 events of
  the device's queue.

- One Lisp thread at a time has the runtime, and gives it up only at a
  safe point or to wait. The evaluator comes to a safe point at every
  call and every GO, and nowhere else: a function in C that takes long
  holds every Lisp thread up meanwhile, the collector with them, and
  neither Ctrl-C nor `destroy-thread` stops it: the LENGTH of a list that
  leads back into itself still runs for good. A second processor would
  be of no use to Lisp as it is.
- The Lisp threads take turns of one tick in the order they asked, with
  no priorities, like the substrate's. A Lisp thread costs a megabyte of
  stack and 644 KiB for the evaluator whatever it does, and
  `make-thread` is an error when the machine has no such memory left.
- A thread is not stopped and not interrupted in the middle of the
  cleanup of an UNWIND-PROTECT: that waits until the cleanup is done. So a
  cleanup that never ends, one that waits for what does not come, makes a
  thread that nothing stops.
- A lock that a thread holds when it ends stays held. A lock cannot be
  taken twice by its holder, there is no wait for one with a limit, and
  there are no condition variables: an event does for what they would.
  `join-thread` on a thread that failed or was stopped signals a plain
  ERROR. The thread that reads from the console cannot be destroyed.
- The collector no longer stops the world, the runtime being one
  thread's at a time. `thread_stop_the_world` and the safe points of
  kernel/thread.c are still there and run in the thread self-test at
  every boot; nothing else calls them. They can go, or stay for what
  does not evaluate.
- A stream takes strings and gives lines, a file's as well, and a file
  that is written is strings until it is closed. There is no
  `read-char`, no `read` from a stream, no `with-input-from-string`, no
  `*error-output*` or `*terminal-io*`, and `write-string` takes no
  `:start` and `:end`. Everything that prints makes a string first, and
  a string stream keeps every string it was given until it is asked for
  them. DEFINE-CONDITION still refuses `:report`, though there would be
  a stream for it to write to now, and a condition of a type that has
  nothing to say prints as its type and its slots.
- HANDLER-CASE is the one way to handle a condition. There is no
  HANDLER-BIND, no restart and no debugger, and a clause names a type by
  its name and not as `(or ...)`. An error that nothing handles ends the
  evaluation and is printed. WARN does not look whether what it is given
  is a WARNING. Of the substrate's own errors, the ones a program is
  likely to tell apart have Common Lisp's types; Ctrl-C is
  CLARA:KEYBOARD-INTERRUPT; every other is a plain ERROR.
- What the language does not have yet, and refuses where it could be
  misread: `(declare (special ...))`, `&environment`, the keywords of
  LOOP, the options of DEFSTRUCT (`:include`, `:conc-name` and the
  rest). What is simply not there: hash tables, which DESIGN.md counts in
  the first subset; `(defun (setf f) ...)`, `macro-function`,
  `symbol-macrolet`, `progv`; `typep`, `typecase`, `check-type`; `elt`,
  `coerce`, and the functions on strings beyond `make-string`,
  `string=`, `string-equal`, `string-lessp`, `subseq`, `string-upcase`
  and `string-downcase`; those two and `char-upcase` and
  `char-downcase` know the letters of ASCII, and take no `:start` and
  `:end`. MAKE-STRING takes `:initial-element` and
  refuses `:element-type`, and MAKE-ARRAY a length and
  `:initial-element`; what is wrong with an argument of either is said
  under the name of its function in C, `%MAKE-STRING` and `%MAKE-VECTOR`,
  and a length that is no length is called an index there.
  FORMAT knows `~A ~S ~D ~%` and `~~`. The functions on sequences take
  lists only, SUBSEQ strings as well, and of their keyword arguments
  `:test`, with `:key` for MEMBER and ASSOC and `:initial-value` for
  REDUCE. SETF knows the places that boot.lisp lists with DEFSETF and the
  ones DEFSTRUCT adds. `eq` and `eql` are one function, `char=` and
  `char<` take two characters. A file in lisp/ that needs one of these
  loads under SBCL and not here: only a boot tells.
- What `#+` and `#-` leave out still has to be syntax that the reader
  knows, apart from its symbols, numbers and characters, which are
  passed over.
- Packages can be made, used at their making, and exported from. There is
  no `import`, `unintern`, `shadow`, `use-package` or `delete-package`;
  `export` does not look whether the name is taken in a package that uses
  this one; and nothing stops `(defun car ...)` from replacing CAR.
- Letters fold to upper case in the reader, and the printer tells the two
  cases apart, for ASCII only: `é` stays as it is where SBCL makes `É` of
  it. A character has one of the ten names in read.c, or `U+` and its
  code point.
- The console in Lisp writes a character at a time, some forty calls of
  the evaluator for each, and its lock is taken once for every string. It
  draws its cells with CLARA.UNSAFE and a pixel of its own making, and not
  with lisp/draw.lisp: a terminal in a window does, a row of characters to
  the call.
  It has one colour. It scrolls by copying every row of pixels up, and
  so does the substrate's console since M7: that reads the framebuffer,
  which a real display is slow at. When the kernel reports a fault while
  the screen is the Lisp console's, it clears the screen first, not
  knowing where that console left off; and whatever else the substrate
  prints meanwhile goes to the serial port alone.
- Ctrl-C that is typed right behind the end of a line can reach the
  evaluator before the console has read it: the line is given up as it
  should be, without the `^C` that shows it. A condition that comes all
  the way out of the listener starts the listener again, and what was
  typed of a form so far is lost.
- READ-FROM-STRING writes its whole string out as UTF-8 for the reader,
  into page frames, every time it is called, and the listener calls it
  once for every form and once more for every line of a form that is
  not finished: a form of very many lines is read in time that grows
  with the square of them.
- lisp/host/ is a stand-in, not the machine. Under SBCL a thread is
  preempted anywhere, memory is 4 MiB at one address, nothing is mapped
  read-only, and the Lisp is all of Common Lisp. The host tests say that
  the console and the listener do what they should with the bytes and
  the pixels; whether the interpreter runs them is for the boot to say.
  The names in boot.lisp are checked there by reading the file as text:
  a definition counts when its line begins with `(defun ` or its like.
  The kernel's own texts are evaluated before the console is loaded, so
  the console and the listener have no self-test at boot but the
  session.
- CI has SBCL 2.6.0, the Mac 2.6.10, and the Ubuntu 24.04 container that
  stands in for CI on the Mac 2.2.9. The stress boot, a collection at every
  safe point, takes 18 s on the Mac, two minutes there when AArch64 is
  emulated, and between two and five on CI, 132 s to 294 s on four runs of
  nearly the same kernel, of the ten that the boot test gives it. With the
  window manager in the world (0.0.17) it is 19 s on the Mac, two and a
  half minutes in the container, and 331 s on CI, where the kernel before
  took 227 s. It grew
  with the world, since each of those collections went through the whole
  heap. Since 0.0.18 the kernel makes them before the world is loaded,
  34 000 of them in a heap of 270 KiB, when the boot volume asks for it,
  and that boot is 15 s on the Mac, 100 s in the container and 145 s on
  CI, whatever is added to the world; a text in the kernel's self-test that goes round a
  thousand times still costs seconds there, since every call of a function
  in Lisp is a safe point, FORMAT's among them.
- lisp/font.lisp and kernel/font.c hold the same glyphs, one for each
  console, from the one generator.

- Integers are fixnums, 63 bits. A result that does not fit is an error,
  and so is a division that does not come out even: there are no larger
  integers, no ratios and no floats.
- The evaluator's limits. A function can call itself about 2700 deep on
  x86_64 and 3460 on AArch64, on the Lisp thread's megabyte of stack,
  less 48 KiB that the evaluator leaves for the reader, the printer and
  an interrupt; then, or when the 65536 slots of the value stack are
  full, it is the error "the stack is full". 8192 special variables
  bound at once, 20 values, 64 keyword arguments in a call, 255 bytes in
  the text of an error. Lists still nest 64 deep at most for the reader
  and the printer (`LISP_DEPTH`).
- The printer stops after 65536 objects, with three dots, which is what
  ends a list that leads back into itself. There is no `*print-circle*`,
  and none of the other printer variables.
- The reader refuses `#.`, `#nR`, `#*`, `#C`, `#P`, `#S` and `#n=`, and a
  vector inside a backquote.
- DEFUN, DEFMACRO, DEFVAR, DEFPARAMETER, DEFCONSTANT, LAMBDA,
  MULTIPLE-VALUE-BIND and HANDLER-CASE are special forms here and macros
  in Common Lisp, so MACROEXPAND-1 leaves them as they are.
  MACROEXPAND-1 does not see the macros of a MACROLET.
- The collector goes through the whole heap every time, and no Lisp
  thread runs meanwhile, so its time grows with what is in use; nothing
  has measured it.
  Nothing moves, so free memory is in pieces: a short free block serves
  only an object that fits it, and the heap gives page frames back to
  the kernel only from its end, where one object that stays keeps the
  heap as long as it is.
- Making an object never collects, so memory can still run out for good
  inside a function in C, between two safe points, and then the kernel
  panics. The evaluator stops a computation when a collection leaves
  less than a sixteenth of the machine's memory, and MAKE-ARRAY, FORMAT
  into a string and string concatenation look before they make
  something large. What remains is a function in C that makes very many
  small objects at one go: APPEND with lists of millions, for one.
- The collector has room for 4096 objects that wait to be looked into.
  When more wait, a vector of that many things for one, it walks the
  heap to find the rest, once more for every time the room runs out.
- A macro whose function changes the form it was given can leave the
  evaluator with a list in its hands that the collector has freed: a
  form is held through the function it belongs to, not by itself.
  Common Lisp leaves that undefined; here it can end in a fault.
- The values of the last form and the last exit stay where the
  collector finds them until others take their place: some twenty
  objects that can live longer than they have to.
- Every word of an object that goes into a free block is read first, to
  see that nothing has written there since the collector freed it.
- kernel/lisp/self-test.lisp, a file with a mistake in it, is on every
  boot volume, because the evaluator's self-test loads it at every boot.
- NREVERSE makes a new list, MAPC makes one and drops it, and a function
  with keyword parameters looks its keywords up by name at every call.
  How fast the interpreter is has not been measured.

- The first megabyte of RAM is never handed out or mapped. Frame 0 would
  look like a failed allocation, a null pointer has to fault, and x86 needs
  memory below 1 MiB to start the other processors, which this roadmap does
  not do yet.
- The allocator finds free frames with a linear scan of its bitmap, lowest
  address first. A long run on a fragmented machine reads the whole
  bitmap, and there is no way to ask for an aligned run, such as 2 MiB for
  a large page.
- The allocator goes by the type of each region in the EFI map and ignores
  the attribute bits; QEMU and UTM set none that matter. `pmm_free` takes
  any frame the bitmap covers that is in use, holes that are not RAM
  included: it trusts its caller.
- The page tables use 4 KiB pages only, about 2 MiB of tables for each GiB
  of RAM, and vm_unmap leaves an emptied table where it is.
- All RAM is mapped writable at its own address, free frames and the
  firmware's leftovers included, so a stray write that lands in RAM is not
  caught.
- The screen is mapped like RAM. A real display wants write-combining (the
  PAT on x86_64, a non-cacheable attribute on AArch64); under QEMU and UTM
  it makes no difference.
- Runtime-services code is mapped as data. Nothing calls UEFI runtime
  services; calling one would need that memory executable.
- Five-level paging on x86_64 is written but has never run: OVMF leaves it
  off, even with `-cpu max`.
- A fault report gives the place as an offset into the kernel image, and
  `llvm-symbolizer` turns that into the name of the function (CLAUDE.md
  has the command). It cannot give the line: the objects carry their line
  numbers in CodeView form, and the link keeps none of it. The report has
  no backtrace either, so it says where the fault was and not how the
  kernel got there.
- Only the processor that boots is set up. The others stay where the
  firmware left them, parked on x86_64 and never started on AArch64. The
  GDT, the TSS, the exception stacks, the interrupt controller's
  per-processor part and the timer are all set up for one. The scheduler
  counts on it: with interrupts off the running thread is alone, and that
  is all the locking kernel/thread.c has. A second processor needs a real
  lock under the queues and a running thread of its own.
- The threads that are ready take turns in the order they became ready,
  with no priorities: a thread that wakes waits for every thread ahead of
  it, a tick each at most.
- Time is a count of ticks, a hundred a second, and nothing finer: there
  is no clock to read between two ticks, and `thread_sleep` comes out up
  to one tick short. On x86_64 the length of a tick is measured once, at
  boot, over a single tick of the 8254, and comes out a few parts in a
  thousand apart from one boot to the next.
- The timer interrupts a hundred times a second whether or not anything
  is waiting for it, because turns and sleeps both hang on the tick. An
  idle machine wakes that often for nothing.
- The console's lock covers one call of kprintf, kputs or kputc. A line
  put together from several calls can be split by another thread's line,
  and `fbcon_set_color` changes the colour for everybody. A handler, a
  fault report and a panic cannot wait, so they print without the lock,
  into the middle of a thread's line or of a scroll if it comes to that.
- On x86_64 an interrupt is handled on the stack of the thread it
  interrupts, so a thread's 64 KiB have to hold the handlers too. On
  AArch64 the handlers have their own stack.
- The exception stacks, 16 KiB each, have no guard page: the spare stack
  for double faults on x86_64 and the handlers' stack on AArch64.
- AArch64 at EL2 stops with a message: the kernel does not know how to
  step down to EL1. QEMU starts there with `virtualization=on`, which UTM
  sets when it emulates AArch64 instead of virtualizing it.
- x86_64 with the local APIC in x2APIC mode stops with a message. The
  firmware leaves that mode off on the machines at hand.
- On x86_64 the timer is measured against the 8254, and the kernel stops
  when there is none. The HPET, the ACPI timer and the time-stamp counter
  are not used.
- A non-maskable interrupt on x86_64 is reported like a fault and stops
  the machine; the pin it arrives on is left as the firmware set it. On
  AArch64 asynchronous aborts (SError) stay masked.
- The handlers do not save the floating-point and vector registers,
  because nothing in the kernel uses them (`-mgeneral-regs-only`), and a
  thread switch moves only what the handlers save. Floats in Lisp will
  change that.
- The ACPI tables are read where the firmware put them, and the kernel
  faults if that is not RAM it mapped. Only the XSDT is followed, and
  there is no interpreter for the bytecode in the DSDT, which is where a
  machine describes how its devices' interrupt lines are wired.
- QEMU's hvf has no GIC version 2, which is why `make test` boots AArch64
  a second time, emulated.
- None of M4 to M12 has been booted in UTM itself. UTM runs AArch64
  under hvf with GIC version 3, four processors and 4 GiB, and that was
  checked with Homebrew's QEMU 11 from the disk image; UTM brings QEMU
  10.0 and a display device of its own. Whether its machine takes
  messages through a GICv2m frame, as Homebrew's does under hvf, or
  through an ITS, is not known; the kernel drives both. UTM gives a
  machine a USB keyboard, mouse and tablet, for which there is no driver:
  the roadmap had it that UTM provides virtio's, and it does not unless
  they are added by hand, `-device virtio-keyboard-pci` and
  `-device virtio-tablet-pci` among the machine's QEMU arguments
  (README.md). Without them, and without a serial device, there is
  nowhere to type. Its drive has to be on the VirtIO interface for the
  kernel to see a disk, and to save a world on it.
- The console has glyphs for ASCII only (kernel/font.c), and so has
  whatever is written in its cells: a terminal, the editor and the file
  browser. A character outside it takes one cell, with the font's sign
  for a glyph it does not have. The fonts of outlines (M18a) have Latin,
  Greek and Cyrillic letters, and nothing draws in them yet where text is
  typed.
- A string takes 32 bits for every character, whatever the characters
  are.
- On AArch64 `arch_early_init` switches the PL011's FIFOs on, and leaves
  the rest of the UART as the firmware set it up.
- The handoff does not give back a memory-map buffer that turned out too
  small, or the pages of a boot file it failed to read: a few pages, at
  most once per boot.
- When ExitBootServices fails for good, the handoff says so through the
  firmware's console, which the specification no longer promises will work
  by then.
- CI covers Ubuntu only, with clang 18 and QEMU 8.2 where the Mac has
  clang 23 and QEMU 11, and fsck.fat for the checker of volumes where the
  Mac has fsck_msdos. Nothing builds or boots on macOS except by hand.
  The boot with a collection at every safe point is emulated there, and
  is the longest of the nine.
- `make image` needs macOS (hdiutil), so CI neither builds nor boots the
  disk image that UTM gets.
- site/boot.png, on the website, is build/screen-aarch64-resumed.png, the
  end of the session that a world which was saved answers, as `make
  screenshot` copies it after `make test`, with the version that the
  machine named written into the file. The website is not built from a
  picture of another version than the kernel's, so a change of version
  takes those two commands, and the repository gets a picture of some
  16 KiB with each. The words beside the picture in site/index.html, for
  whoever cannot see it, say what the session's end shows, and are changed
  by hand when tools/resumed.txt ends in another way.
- Where the logo, site/sun.png, came from and under what license is not
  recorded.
- www.claraos.org has no DNS record; only the bare domain reaches the
  website.
- claraos.org has not been verified for the GitHub organization (the Pages
  API shows no protected domain state). Verifying it is what stops someone
  else from claiming the name on GitHub Pages if the site is ever switched
  off.
