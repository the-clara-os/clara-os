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
