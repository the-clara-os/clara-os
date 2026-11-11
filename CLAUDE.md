# ClaraOS: working notes for Claude

Read DESIGN.md and ROADMAP.md first. This project is capped at about 100K
tokens of assistant usage per day, so one session is one roadmap slice:
state the slice, build it, finish with `make test` green on both
architectures, update ROADMAP.md, stage with `git add -A`, and stop. Never
commit or push; commits are GPG-signed by Julio in his own terminal.

Build with `make` (expects Homebrew llvm and lld under /opt/homebrew/opt;
override with `LLVM=` and `LLD=`). `make test` boots both architectures
headless under QEMU in about ten seconds. `make run-aarch64` and
`make run-x86_64` open a QEMU window with serial on the terminal; `make image`
produces the UTM disk.

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
