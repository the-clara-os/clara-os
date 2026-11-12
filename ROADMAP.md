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
  moved to M4, for the reason given under M4 in the loose ends below.
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
- [ ] **M4 exceptions and interrupts.** x86_64 IDT and exception handlers
  with a register dump; AArch64 vector table and EL1 exception dump; APIC
  and GIC initialisation from ACPI MADT; a timer tick on both (LAPIC timer,
  generic timer). Boot-services memory handed to the page-frame allocator,
  now that nothing in it is in use.
- [ ] **M5 threads.** Context switch, run queue, sleep and wake on the
  timer, an idle thread, stop-the-world for the collector.

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

Infrastructure, for sessions with budget left over:

- GitHub Actions: build and headless boot test on Ubuntu (clang, lld,
  qemu-system-x86 and qemu-system-arm, ovmf and qemu-efi-aarch64), and the
  SBCL host tests.
- Read the UART base from ACPI (SPCR or DBG2) instead of assuming
  0x09000000 in kernel/arch/aarch64/arch.c.
- `make run-*` with a GDB stub and a debugging recipe for PE images.
- A slow test mode for the checks that M2 ran once, by hand, with temporary
  patches, and that `make test` does not run: every free frame allocated,
  written, read back and freed; a stale map key on the first
  ExitBootServices; a fault on purpose; odd boot files (dot files, a
  subdirectory, an empty file, a 300 KB one, a long name, an accented
  name); 128 MiB and 4 GiB of memory; AArch64 without hvf; booting
  build/claraos.img instead of the ESP directory. M3 added: accesses that
  must fault (a write to code or to constants, running data, a null
  pointer, the guard page, an unmapped heap address), and `-cpu max` on
  both architectures.

Shortcuts and loose ends, under the milestone that settles each one. A
session reads its own group before it starts, and whatever it leaves open
is added here in the same change.

M4:

- Boot-services memory, 30 to 45 MiB under QEMU, stays out of the
  page-frame allocator, because the processor still uses what the firmware
  left in it: on x86_64 the IDT (boot-services data) and its handlers
  (boot-services code), on AArch64 the vector table (boot-services code).
  M2 was to reclaim this memory and could not. Once the vectors are the
  kernel's own, every region of those two types goes to `pmm_free`.
- Until then the firmware's handlers are the only fault report there is: a
  register dump on the serial port, nothing on the screen. They keep
  working under the kernel's page tables because vm_init leaves
  boot-services code writable and executable, AArch64 keeps SCTLR_EL1.WXN
  off, and x86_64 maps the local APIC page, from which they read the
  processor's ID. When the memory is reclaimed, map it as plain data and
  turn WXN on.
- A kernel stack overflow hits the guard page, and then the handler has no
  stack to run on. AArch64 still prints a dump, marked as a recursive
  exception; x86_64 resets without a word. The kernel's own handlers need a
  stack of their own for this case (an IST entry on x86_64).
- x86_64 runs on the firmware's GDT. It is in runtime-services data, so the
  reclaim leaves it intact, but the kernel should load its own with the
  IDT.
- Neither the page-frame allocator nor vm_map has a lock. They must not be
  called from an interrupt handler, and from M5 on not from two threads at
  once.

M6a:

- The heap region is reserved and empty. A frame mapped there can also be
  reached at its physical address, like all RAM; decide whether heap frames
  lose that second mapping.

M6b:

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

M6c, M8:

- The console is output only: no cursor and no keyboard.

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
- A fault dump gives addresses, not names. To find the function, subtract
  the "kernel image at" address printed at boot and look the offset up in
  the build; nothing does that yet.
- The handoff does not give back a memory-map buffer that turned out too
  small, or the pages of a boot file it failed to read: a few pages, at
  most once per boot.
- When ExitBootServices fails for good, the handoff says so through the
  firmware's console, which the specification no longer promises will work
  by then.
