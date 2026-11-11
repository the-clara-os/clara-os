# Roadmap

Each milestone is sized for one working session. A milestone is done when
`make test` passes on both architectures and this file says so.

- [x] **M0 boot** (2026-11-11). Kernel as the UEFI application on both
  architectures; ExitBootServices with the memory-map retry; memory map,
  ACPI RSDP and GOP framebuffer captured; serial output (COM1, PL011);
  `kprintf`; QEMU run and headless test scripts; GPT/FAT32 image for UTM.
- [ ] **M1 console.** Bitmap font, framebuffer text console mirroring the
  serial port, `panic()`, scrolling.
- [ ] **M2 physical memory.** Page-frame allocator built from the EFI map,
  our own kernel stack, boot-services memory reclaimed.
- [ ] **M3 virtual memory.** Our own page tables on both architectures
  (4 KiB pages), kernel mapped high, framebuffer and MMIO mapped on purpose,
  the firmware's tables dropped.
- [ ] **M4 exceptions and interrupts.** x86_64 IDT and exception handlers
  with a register dump; AArch64 vector table and EL1 exception dump; APIC
  and GIC initialisation from ACPI MADT; a timer tick on both (LAPIC timer,
  generic timer).
- [ ] **M5 threads.** Context switch, run queue, sleep and wake on the
  timer, an idle thread.
- [ ] **M6 the decision.** Choose the system shape from DESIGN.md and write
  its design section before writing its code.
- [ ] **M7 user mode.** Ring 3 and EL0 entry and return; the system-call or
  IPC path on both.
- [ ] **M8 devices.** PCIe ECAM from ACPI MCFG, virtio-blk and virtio-net
  (UTM provides both), keyboard input.
- [ ] **M9 storage.** A filesystem (own format, or FAT to reuse the ESP) and
  loading programs from it.
- [ ] **M10 a shell or system language**, as M6 decides.

Infrastructure, for sessions with budget left over:

- GitHub Actions: build and headless boot test on Ubuntu (clang, lld,
  qemu-system-x86 and qemu-system-arm, ovmf and qemu-efi-aarch64).
- Read the UART base from ACPI (SPCR or DBG2) instead of assuming
  0x09000000 in kernel/arch/aarch64/arch.c.
- `make run-*` with a GDB stub and a debugging recipe for PE images.

Shortcuts taken in M0, to be removed by the milestones above:

- The kernel keeps running on the firmware's page tables and stack (M2, M3).
- Only 32-bit RGBx and BGRx framebuffers are handled (M1).
- The memory-map snapshot is a fixed 32 KiB buffer (M2).
