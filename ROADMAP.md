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
- [ ] **M12 the window manager.** Windows, focus, input routing, a REPL
  window, a launcher; the saved image boots straight into it.
- [ ] **M13 applications.** A text editor and a file browser as the first
  two Lisp applications, loaded and unloaded while the system runs.

Later, in no order: a compiler written in Lisp; virtio-net and TCP/IP;
outline fonts; sound; CLOS; a USB keyboard and mouse, which is what UTM
gives a machine that is not told otherwise.

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

Shortcuts and loose ends, under the milestone that settles each one. A
session reads its own group before it starts, and whatever it leaves open
is added here in the same change.

M12:

- The console does not draw with lisp/draw.lisp. It has the screen, draws
  its cells with CLARA.UNSAFE as before, turns a colour into a pixel by a
  function of its own, and moves the pixels up when a line is full,
  whatever they show: what a program puts on the screen lies under the
  next line of text that reaches it and scrolls away with the rest. A
  window manager has to take the screen from the console, which then goes
  on with the serial port alone, and a console in a window draws like
  everything else.
- Nothing draws the pointer yet. A picture of one bit to the pixel, drawn
  without a background, is what it would be drawn with, and what was under
  it has to be put back when it moves.
- A surface is one thread's at a time. What drawing is kept to and what was
  drawn on are the surface's own, and nothing locks them: two threads that
  draw on one surface get in each other's way.
- What a world starts with is three lines of C, the same for a world that
  was loaded from the files and for one that came as an image: the console,
  the drivers and the file system, and the listener (kernel/lisp/lisp.c). An
  image that is to boot straight into a window manager has to say so itself:
  a function of its own that the substrate calls in place of the listener.

No milestone yet, to be picked up when they start to matter:

- Drawing. What can be drawn is rectangles, outlines a pixel thick, text
  in the one font and its one size, pictures of one bit to the pixel that
  are 62 pixels wide at most, and copies. There are no lines but along a
  row or a column, no curves, no scaling, and nothing between a pixel that
  is drawn and one that is not: no colour lets what is under it show
  through. Text is drawn a glyph to the call of the substrate. A surface is
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
  `clara.fat:*volume*`, and there is no name that says which volume. A
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
  to the device is not set up. A mouse's wheel is ignored, and nothing
  draws the pointer, whose place is kept for whoever asks. Every device
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
  `coerce`, `destructuring-bind`, and the functions on strings beyond
  `string=`, `string-equal`, `string-lessp`, `string-upcase`,
  `string-downcase` and `subseq`; those two and `char-upcase` and
  `char-downcase` know the letters of ASCII, and take no `:start` and
  `:end`.
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
  the evaluator for each, and its lock is taken once for every string.
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
  nearly the same kernel, of the ten that the boot test gives it. It grows
  with the world, since each of those collections goes through the whole
  heap, so it wants a cheaper session or a longer limit before the world is
  half as large again; a text in the kernel's self-test that goes round a
  thousand times costs seconds there, since every call of a function in Lisp
  is a safe point, FORMAT's among them.
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
- None of M4 to M11 has been booted in UTM itself. UTM runs AArch64
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
- The screen has glyphs for ASCII only (kernel/font.c). A character
  outside it takes one cell, with the font's sign for a glyph it does not
  have.
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
