# Roadmap

Each milestone is sized for one working session. A milestone is done when
`make test` passes on both architectures and this file says so. The shape
(DESIGN.md: a C substrate under a Lisp world, booting into a window manager)
was decided on 2026-11-11 and the milestones below follow from it.

Substrate:

- [x] **M0 boot** (2026-11-11). Kernel as the UEFI application on both
  architectures; ExitBootServices with the memory-map retry; memory map,
  ACPI RSDP and GOP framebuffer captured; serial output (COM1, PL011);
  `kprintf`; QEMU run and headless test scripts; GPT/FAT32 image for UTM.
- [x] **M1 console** (2026-11-12). Spleen 8x16 bitmap font, converted from
  BDF by tools/bdf2c.py; a text console on the framebuffer (kernel/fbcon.c)
  that mirrors the serial port, with wrapping, tabs, three colours and
  scrolling that repaints only the cells that changed; `panic()`; any GOP
  pixel layout, through colour masks; `kprintf` arguments checked by the
  compiler; `make test` saves a screenshot of each architecture.
- [ ] **M2 physical memory.** Page-frame allocator built from the EFI map,
  our own kernel stack, boot-services memory reclaimed. Files read from the
  ESP through the UEFI file protocol during the handoff, for M6.
- [ ] **M3 virtual memory.** Our own page tables on both architectures
  (4 KiB pages), kernel mapped high, a large reserved region for the Lisp
  heap, framebuffer and MMIO mapped on purpose, the firmware's tables
  dropped.
- [ ] **M4 exceptions and interrupts.** x86_64 IDT and exception handlers
  with a register dump; AArch64 vector table and EL1 exception dump; APIC
  and GIC initialisation from ACPI MADT; a timer tick on both (LAPIC timer,
  generic timer).
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

Shortcuts taken so far, to be removed by the milestones above:

- The kernel keeps running on the firmware's page tables and stack (M2, M3).
- The memory-map snapshot is a fixed 32 KiB buffer (M2).
- The console is output only: no cursor and no keyboard (M6c, M8).
