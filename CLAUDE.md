# ClaraOS: working notes for Claude

Read DESIGN.md and ROADMAP.md first. One session is one roadmap slice: state
the slice, build it, finish with `make test` green on both architectures,
bump the patch version, update ROADMAP.md, and open the pull request. Julio
reviews and merges it.

Pull requests (Julio, 2026-11-12: "feel free to create the PR straight away
in github"). Work on a `julio/<topic>` branch off main. Never `git commit`
here: commits must be signed, and the local key needs Julio at the
keyboard. `python3 tools/api-commit.py <message-file>` sends the working
tree to GitHub as one commit that GitHub signs, creating the branch there
if needed, and moves the local branch onto it. Then `gh pr create --base main`
with a title in his style, `feat(m3): Virtual Memory`, and a body that says
what changed, how it was checked, and every decision that departs from the
roadmap. Never merge, and never push to main. The pull request is built and
booted once more on Ubuntu (.github/workflows/ci.yml): watch that run with
`gh pr checks --watch`, and the slice is not finished until it passes. The
ruleset on main requires that check, `build-and-boot`, before a merge.

Budget: assistant work on this project is capped at 50 dollars per day, at
list prices. `tools/session-cost.py` adds up what the day's Claude Code
sessions in this repository have cost; run it when a slice is finished and
report the figure. Never say a session stayed within the cap without having
measured it. The money goes on context, not on tool calls: every message
sent after five idle minutes re-sends the whole conversation at full price,
so start each slice in a fresh session instead of continuing a long one.

Build with `make` (Homebrew's llvm and lld under /opt/homebrew/opt when they
are there, otherwise clang and lld-link from the PATH; `LLVM=` and `LLD=`
name other directories). `make test` boots both architectures
headless under QEMU in about twenty seconds and saves what each screen shows
to build/screen-<arch>.png; look at those images when a change touches the
display. `make run-aarch64` and `make run-x86_64` open a QEMU window with
serial on the terminal; `make image` produces the UTM disk.

Rules:

- C11 freestanding with `-Werror`; no libc; never `long` (LLP64 targets).
- Architecture-specific code only under kernel/arch/<arch>/. Everything else
  must compile for both targets.
- Hardware and firmware table layouts follow the specification; cite it when
  a number is not obvious.
- Every observable change prints something on serial; tools/boottest.sh
  greps the serial log for the kernel's last line.
- Small readable code over frameworks. Abstract after the second
  architecture works, not before.
- `kprintf` and `panic` are checked by the compiler like printf: 64-bit
  values are `%llu` and `%llx`, pointers are `%p` with a `void *`.
- kernel/font.c is generated. Change tools/bdf2c.py or the font and run
  `make font`; never edit it by hand.
- The version is `CLARA_VERSION` in kernel/kernel.h. Every finished piece
  of work bumps the patch number in the same change, and its ROADMAP.md
  entry records the version.
- Substrate code checks itself during boot (`pmm_selftest`) and panics when
  a check fails, so `make test` covers it. A check that needs a temporary
  change to the sources (a forced fault, an exhaustive loop) is run once and
  taken out again. Look at what `make` says before trusting such a run: a
  build that fails leaves the previous kernel in build/esp, and the boot
  test then passes on a kernel that does not have the change.
- A physical address is a `uint64_t`; `phys_ptr()` makes a pointer of one,
  which works because RAM is mapped at its own address (kernel/vm.c).
- A fault is reported by the kernel itself, on serial and on the screen:
  read build/boot-<arch>.log. The report gives the place as an offset into
  the kernel image, and
  `/opt/homebrew/opt/llvm/bin/llvm-symbolizer --relative-address --obj=build/esp/EFI/BOOT/BOOTAA64.EFI 0x3c20`
  names the function that offset is in (no line number).
- `fault_selftest` (kernel/fault.c) provokes the accesses the address space
  must refuse, at every boot, through the probes in entry.S. A new kind of
  protection gets a case there. To read the report of a fault that is not
  survived, force one with a temporary change and run
  `MARKER='^exception[^s]\|^panic' TIMEOUT=20 tools/boottest.sh <arch>`.
  The marker is a grep pattern; a plain `xception` also matches the boot
  report's own "exceptions:" line and stops the boot before the fault.
- An interrupt handler runs with interrupts off and must not allocate page
  frames, map memory, print, take a lock or wait, apart from reporting
  what should never happen. The allocator, the page tables and the console
  each have a lock, and a lock is something only a thread can wait for.
- Threads (kernel/thread.c). Data that two threads can reach sits behind
  a `struct lock`. Never hold one across `thread_sleep`, `thread_join` or
  `thread_safe_point`: stopping the world depends on that. The page
  tables' lock is taken before the allocator's, never after, and the
  console takes no other. The scheduler's own state is touched with
  interrupts off, as in `int on = arch_interrupts_off(); ...; if (on)
  arch_interrupts_on();`, which is enough only because there is one
  processor. A new kind of wait that a thread may sit in while the world
  is stopped ends with `thread_safe_point()`, like `thread_sleep`.
- `thread_selftest` runs at every boot. After a change to the scheduler,
  break it on purpose and see that the self-test notices: ROADMAP.md lists
  the ways that were tried, under the slow test mode. One of them got
  through the first version of the self-test, which is how it was found
  that the test never woke a sleeper while the world was stopped.
- `make test` boots three machines: x86_64, AArch64 with GIC version 3,
  and AArch64 emulated with GIC version 2, whose files in build/ are named
  aarch64-gic2. QEMU's hvf has no version 2, and UTM uses version 3.
  tools/boottest.sh passes any further arguments on to QEMU, which is how
  to try another machine: `tools/boottest.sh aarch64 -smp 4 -cpu max`.
- Assembly lives in kernel/arch/<arch>/entry.S and nowhere else. On x86_64
  it follows the Microsoft calling convention, like the C around it:
  arguments in rcx and rdx, 32 bytes of home space above the return
  address. What the files of one architecture share is in its arch.h.
- `struct frame` (arch.h) is what entry.S saves, and it is also what a
  thread is while it waits. Shared code never looks inside one: it copies
  `arch_frame_size` bytes, and `arch_frame_init` fills in a new thread's.
  A register added to the frame is switched with the rest; a register
  left out of it is shared by all threads.
- lisp/*.lisp is copied to the ESP's \clara directory, and the handoff
  (kernel/boot.c) reads every file there into a `struct boot_file`.
- Whatever a session leaves open goes into ROADMAP.md in the same change,
  under the milestone that settles it: a shortcut, a provisional decision,
  a limit, a check that was only run by hand. Saying it in the summary at
  the end is not enough; the next session starts from the files. Before
  starting a milestone, read its group there.
- The website, https://claraos.org, is site/index.html, filled in by
  site/build.py from ROADMAP.md, kernel/kernel.h (the version)
  and the console font (`make site`, then open build/site/index.html), and
  published by .github/workflows/site.yml on every push to main that touches
  them. The page reads the milestone entries of ROADMAP.md, so keep their
  form.
- CI (.github/workflows/ci.yml) runs `make`, `make test` and `make site` on
  Ubuntu for every pull request and every push to main. Ubuntu's clang and
  QEMU are older than Homebrew's, and the runners have no hardware
  acceleration, so both machines are emulated there: the code has to build
  without warnings under both compilers, and a boot check must not depend
  on how fast the machine is. The tools `make test` needs are installed in
  the workflow's first step and listed at the top of the Makefile; a new
  one goes into both in the same change. The serial logs and screenshots of
  a run are in its artifact, boot-reports.
- To see a change the way CI will before pushing it, with Docker running:
  an ubuntu:24.04 container with the packages from the workflow, a copy of
  the tree without build/, and `make test` in it. build/ itself must not be
  shared with the container: the objects in it come from another compiler.
