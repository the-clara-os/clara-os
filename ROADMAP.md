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
- [ ] **M3 virtual memory.** Our own page tables on both architectures
  (4 KiB pages), kernel mapped high, a large reserved region for the Lisp
  heap, framebuffer and MMIO mapped on purpose, the firmware's tables
  dropped.
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
  build/claraos.img instead of the ESP directory.

Shortcuts and loose ends, under the milestone that settles each one. A
session reads its own group before it starts, and whatever it leaves open
is added here in the same change.

M3:

- The kernel keeps running on the firmware's page tables.
- Physical addresses are used as pointers, which works only under the
  firmware's identity mapping: the page-frame bitmap and the self-test's
  writes in kernel/pmm.c, and from `struct boot_info` the memory map, the
  boot files, the framebuffer and the ACPI root pointer. The AArch64 UART
  is reachable for the same reason. Each needs a mapping of its own.
- The handoff does not record where the kernel image was loaded or how big
  it is. EFI_LOADED_IMAGE_PROTOCOL, which kernel/boot.c already opens, has
  both. The firmware lists the whole image, code, data and the boot stack,
  as one "loader code" region, so the memory map cannot say which pages to
  map read-only or no-execute; the PE section table can.
- The image is relocated for the address the firmware loaded it at.
  Running it at a high address means applying the PE base relocations a
  second time, or leaving it where it is.
- The boot stack is 64 KiB inside the kernel image, with nothing to stop
  an overflow from running into kernel data. It is not page-aligned, so a
  guard page needs it moved or padded.
- The memory report gives totals per region type. The region-by-region
  dump of M1 is gone, and may be wanted back while the page tables are
  built.

M4:

- Boot-services memory, 30 to 45 MiB under QEMU, stays out of the
  page-frame allocator, because the processor still uses what the firmware
  left in it. Measured on both architectures: the page tables are in
  boot-services data; on x86_64 the IDT is in boot-services data and its
  handlers in boot-services code; on AArch64 the vector table is in
  boot-services code. M2 was to reclaim this memory and could not. Once the
  tables (M3) and the vectors (M4) are the kernel's own, every region of
  those two types goes to `pmm_free`.
- Until then the firmware's handlers are the only fault report there is: a
  register dump on the serial port, nothing on the screen. Reclaiming any
  earlier would silence it.
- x86_64 runs on the firmware's GDT. It is in runtime-services data, so the
  reclaim leaves it intact, but the kernel should load its own with the
  IDT.
- The page-frame allocator has no lock. It must not be called from an
  interrupt handler, and from M5 on not from two threads at once.

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

No milestone yet, to be picked up when they start to matter:

- The first megabyte of RAM is never handed out. Frame 0 would look like a
  failed allocation, and x86 needs memory below 1 MiB to start the other
  processors, which this roadmap does not do yet.
- The allocator finds free frames with a linear scan of its bitmap, lowest
  address first. A long run on a fragmented machine reads the whole
  bitmap, and there is no way to ask for an aligned run, such as 2 MiB for
  a large page.
- The allocator goes by the type of each region in the EFI map and ignores
  the attribute bits; QEMU and UTM set none that matter. `pmm_free` takes
  any frame the bitmap covers that is in use, holes that are not RAM
  included: it trusts its caller.
- The handoff does not give back a memory-map buffer that turned out too
  small, or the pages of a boot file it failed to read: a few pages, at
  most once per boot.
- When ExitBootServices fails for good, the handoff says so through the
  firmware's console, which the specification no longer promises will work
  by then.
