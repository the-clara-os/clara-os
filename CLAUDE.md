# ClaraOS: working notes for Claude

Read DESIGN.md and ROADMAP.md first. One session is one roadmap slice: state
the slice, build it, finish with `make test` green on both architectures,
bump the patch version, update ROADMAP.md, stage with `git add -A`, and stop.
Never commit or push; commits are GPG-signed by Julio in his own terminal.

Budget: assistant work on this project is capped at 50 dollars per day, at
list prices. `tools/session-cost.py` adds up what the day's Claude Code
sessions in this repository have cost; run it when a slice is finished and
report the figure. Never say a session stayed within the cap without having
measured it. The money goes on context, not on tool calls: every message
sent after five idle minutes re-sends the whole conversation at full price,
so start each slice in a fresh session instead of continuing a long one.

Build with `make` (expects Homebrew llvm and lld under /opt/homebrew/opt;
override with `LLVM=` and `LLD=`). `make test` boots both architectures
headless under QEMU in about ten seconds and saves what each screen shows to
build/screen-<arch>.png; look at those images when a change touches the
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
  taken out again.
- A physical address is a `uint64_t`, not a pointer (kernel/pmm.c).
- Until M4 a fault lands in the firmware's exception handlers, which print a
  register dump on serial: read build/boot-<arch>.log. They and the page
  tables in use live in boot-services memory, which is why the allocator
  leaves that memory alone.
- lisp/*.lisp is copied to the ESP's \clara directory, and the handoff
  (kernel/boot.c) reads every file there into a `struct boot_file`.
- Whatever a session leaves open goes into ROADMAP.md in the same change,
  under the milestone that settles it: a shortcut, a provisional decision,
  a limit, a check that was only run by hand. Saying it in the summary at
  the end is not enough; the next session starts from the files. Before
  starting a milestone, read its group there.
