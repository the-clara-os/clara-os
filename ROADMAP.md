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
- [ ] **M9 disk and files.** virtio-blk; FAT, so the ESP is the first
  filesystem; files visible from the REPL.
- [ ] **M10 images.** Save the heap to disk and boot by resuming it; the
  substrate loads the image instead of the sources.

The world:

- [ ] **M11 drawing.** A software rasterizer in Lisp: rectangles, blits,
  clipping, bitmap text, double buffering, damage rectangles.
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
  minutes now.

Shortcuts and loose ends, under the milestone that settles each one. A
session reads its own group before it starts, and whatever it leaves open
is added here in the same change.

M9:

- A queue's buffers are page frames from `allocate-memory`, which a device
  can be given because their address is their physical address. An object
  in the heap cannot be handed to a device, so a disk driver copies between
  the two, and CLARA.UNSAFE has nothing yet that copies bytes between
  memory and a string or a vector: a byte at a time from Lisp is slow.
- lisp/virtio.lisp gives a device one interrupt for all its queues, asks
  for nothing a device offers beyond version 1 (no indirect descriptors,
  no event index, no packed queues), never tells a device to hold its
  interrupts back, and does not look at the bit by which a device says
  that it has to be started afresh. A device from before version 1 is
  refused, and so is one that insists on what was not asked for.
- LOAD finds the files that the boot handoff read from `\clara` and no
  others, by name, whatever the case of the letters. They arrive in
  directory order, which no longer matters, since boot.lisp is loaded
  first and loads what else it wants. A character outside ASCII in a name
  becomes `?`, so two names can collide; subdirectories are not read, and
  names that start with a dot are skipped.
- The boot files stay in loader-data memory for good, because LOAD can be
  asked for one at any time. Once there are files on a disk, their pages
  can go to `pmm_free`.

M10:

- A thread, a lock and an event each hold an address in the kernel's own
  memory in one of their words, and `lisp_roots` holds the events of the
  interrupts: a saved heap has to come back without the first and with
  the second put right. Which thread reads from the console, and whether
  Ctrl-C stops it, are C variables.
- The kernel image runs wherever the firmware loaded it, so the address of
  a C function changes with the machine and the build. A saved heap has to
  name the substrate's functions by index or by name, never by address.
  It is by index now: a function object holds its place in
  `lisp_primitives` or in the evaluator's table of special forms, so a
  row put in the middle of either makes an older image call the wrong
  function. By name would not.
- The kernel panics when `\clara` has no boot.lisp, font.lisp,
  console.lisp or listener.lisp, or when loading one of them fails, there
  being no Lisp world without them. An image takes their place.
- GENSYM counts in a C variable, which an image would not bring back.
- A heap that is saved has free blocks in it, in lists that are C
  pointers and C variables (heap.c). After loading, a sweep puts the
  lists together again; when the next collection is due is in C
  variables as well.

No milestone yet, to be picked up when they start to matter:

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
  (tools/run.sh, `INPUT=`). On AArch64 the boot volume is a PCI device,
  and the firmware keeps its place on the bus in build/vars-aarch64.fd:
  a device added ahead of it there moves it, the firmware then boots its
  own shell first, and goes on doing so until that file is deleted. The
  boot test's keyboard is QEMU's `sendkey`, 0.1 s a key, and a line for
  it has to fit the 64 events of the device's queue.

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
- A stream takes strings and gives lines. There is no `read-char`, no
  `read` from a stream, no `with-input-from-string`, no
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
  `coerce`, and the functions on strings beyond `string=` and `subseq`.
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
  stands in for CI on the Mac 2.2.9. The stress boot, a collection at
  every safe point, takes 8 s on the Mac and a minute on CI, where
  AArch64 is emulated; a text in the kernel's self-test that goes
  round a thousand times costs seconds there, since every call of a
  function in Lisp is a safe point, FORMAT's among them.
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
- None of M4 to M8 has been booted in UTM itself. UTM runs AArch64
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
  nowhere to type.
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
  clang 23 and QEMU 11. Nothing builds or boots on macOS except by hand.
  The boot with a collection at every safe point is emulated there, and
  is the longest of the four.
- `make image` needs macOS (hdiutil), so CI neither builds nor boots the
  disk image that UTM gets.
- site/boot.png, on the website, is a screenshot of version 0.0.12, to be
  replaced by hand when the boot report has changed enough to matter:
  build/screen-aarch64.png after `make test` is the same picture of the
  current kernel.
- Where the logo, site/sun.png, came from and under what license is not
  recorded.
- www.claraos.org has no DNS record; only the bare domain reaches the
  website.
- claraos.org has not been verified for the GitHub organization (the Pages
  API shows no protected domain state). Verifying it is what stops someone
  else from claiming the name on GitHub Pages if the site is ever switched
  off.
