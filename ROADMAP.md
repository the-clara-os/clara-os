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

- [ ] **M6a objects and reader.** Tagged 64-bit words, fixnums, conses,
  symbols and packages, strings, vectors; a bump allocator in the heap
  region; the reader and the printer; `(print (read))` over serial.
- [ ] **M6b evaluator.** The interpreter: lambda, closures, special forms,
  special variables, multiple values, macros, `defstruct`, a core of
  built-in functions; `boot.lisp` loaded from the ESP at startup.
- [ ] **M6c collector and conditions.** Precise mark-sweep with all threads
  stopped; `unwind-protect`, `handler-case`, `error`; a REPL on the console
  that survives mistakes.
- [ ] **M7 Lisp in the driver's seat.** Lisp threads over substrate threads;
  the unsafe package: raw memory, port I/O, interrupts delivered as events;
  the console rewritten in Lisp; the same sources loading under SBCL with
  host shims, and a host test run in `make test`.

Devices and storage:

- [ ] **M8 PCIe and virtio.** ECAM from ACPI MCFG, PCI enumeration in Lisp,
  the virtio transport, virtio-input for keyboard and mouse (UTM provides
  both on both architectures).
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
outline fonts; sound; CLOS.

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
  frame not given back by thread_join.

Shortcuts and loose ends, under the milestone that settles each one. A
session reads its own group before it starts, and whatever it leaves open
is added here in the same change.

M6a:

- The heap region is reserved and empty. A frame mapped there can also be
  reached at its physical address, like all RAM; decide whether heap frames
  lose that second mapping.

M6b:

- A thread's stack is 64 KiB (`THREAD_STACK_SIZE`), the same for all and
  fixed, which an interpreter that recurses in C will find small. Decide
  which thread the evaluator runs on, how much stack it gets, and how it
  notices that it is running out before the guard page does.
- lisp/boot.lisp is a placeholder that nothing evaluates, and kmain prints
  the start of each boot file only to show that it arrived.
- The kernel panics when the ESP has no files in `\clara`, although it has
  no use for them yet. Decide what a missing boot.lisp means once something
  reads it, and again when images replace the sources (M10).
- Boot files arrive in directory order, which is not sorted. A character
  outside ASCII in a name becomes `?`, so two names can collide.
  Subdirectories of `\clara` are not read, and names that start with a dot
  are skipped.
- Boot files stay in loader-data memory for good. Once their contents are
  in the Lisp heap, the pages can go to `pmm_free`.
- A file deleted from lisp/ stays in build/esp/clara, and so on the ESP and
  in the UTM image, until `make clean`.

M6c:

- Nothing calls `thread_safe_point` except the self-test. The interpreter
  has to, often enough that the world stops promptly (at every call and
  every turn of a loop, say), and never with a lock held. A thread that
  does not come to a safe point keeps `thread_stop_the_world` from
  returning, and nothing says which thread it is.
- A thread that waits for a lock is not at a safe point, and the world
  stops around it only because no thread holds a lock while it sleeps,
  joins or parks. That rule is in comments and nowhere in the code.
- There is no list of all threads. The collector needs one to find what
  each thread holds; so far a thread is only in the queue it waits in.

M6c, M8:

- The console is output only: no cursor and no keyboard.

M7:

- CI runs no Lisp tests, because there are none. When the SBCL host tests
  join `make test`, the workflow has to install SBCL.
- An interrupt has no way to reach Lisp. The handlers are C, and the
  timer's is the only one.
- A thread can wait for a tick, for a lock and for another thread to
  finish, and for nothing else. A handler can already wake a thread, which
  is what the tick does to a sleeper, but there is no event for a thread
  to wait on that a handler could signal.
- A thread cannot be stopped from outside, and a sleep cannot be cut
  short. Stopping an application means unwinding its threads (DESIGN.md),
  which has to be asked of each thread and done by it.
- A thread owns a stack and its registers and nothing more: there is no
  place yet for the dynamic bindings of a Lisp thread.
- Every thread has to be joined by somebody, or its stack is never given
  back. Lisp threads that nobody waits for need another arrangement.

M8:

- Whether to keep GIC version 2 at all is best decided here, when device
  interrupts would have to be written and tested for both versions. UTM
  never uses version 2; QEMU's virt machine has it unless told otherwise,
  and it costs `make test` a third boot, emulated.
- No device interrupt can arrive yet. On x86_64 every I/O APIC pin is
  masked and nothing can unmask one; a device that signals through MSI
  needs only a vector, and nothing hands vectors out. On AArch64
  `gic_enable` has only ever switched on a private interrupt: the path
  for a shared one, through the distributor, is written and has never
  run, and the trigger mode ACPI gives for an interrupt is not applied.
- The architecture's handler tells interrupts apart with an `if`. The
  second source needs a table of handlers.

M10:

- The kernel image runs wherever the firmware loaded it, so the address of
  a C function changes with the machine and the build. A saved heap has to
  name the substrate's functions by index or by name, never by address.

No milestone yet, to be picked up when they start to matter:

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
- Neither M4 nor M5 has been booted in UTM itself. UTM runs AArch64 under
  hvf with GIC version 3, four processors and 4 GiB, and that was checked
  with Homebrew's QEMU 11 from the disk image; UTM brings QEMU 10.0 and a
  display device of its own.
- The handoff does not give back a memory-map buffer that turned out too
  small, or the pages of a boot file it failed to read: a few pages, at
  most once per boot.
- When ExitBootServices fails for good, the handoff says so through the
  firmware's console, which the specification no longer promises will work
  by then.
- CI covers Ubuntu only, with clang 18 and QEMU 8.2 where the Mac has
  clang 23 and QEMU 11. Nothing builds or boots on macOS except by hand.
- `make image` needs macOS (hdiutil), so CI neither builds nor boots the
  disk image that UTM gets.
- site/boot.png, on the website, is a screenshot of version 0.0.7, to be
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
