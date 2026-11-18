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
A large slice does not fit in what is left of a day that has had another:
M6b, the evaluator, took about half a day's cap by itself. Measure before
starting one, say what it will take, and let Julio choose.

Build with `make` (Homebrew's llvm and lld under /opt/homebrew/opt when they
are there, otherwise clang and lld-link from the PATH; `LLVM=` and `LLD=`
name other directories). `make test` runs the host tests of the Lisp
files under SBCL (`make host-test`, four seconds), then boots both
architectures headless under QEMU, seven boots in about a minute and a
half, types a session at each kernel, and saves what each screen shows to
build/screen-<name>.png; look at those images when a change touches the
display. `make run-aarch64` and `make run-x86_64` open a QEMU window with
serial on the terminal; `make image` produces the UTM disk.

Rules:

- C11 freestanding with `-Werror`; no libc; never `long` (LLP64 targets).
- Architecture-specific code only under kernel/arch/<arch>/. Everything else
  must compile for both targets.
- Hardware and firmware table layouts follow the specification; cite it when
  a number is not obvious.
- Every observable change prints something on serial; tools/boottest.sh
  greps the serial log for the kernel's last line. A line of the boot
  report stays under 100 characters, the width of the screen under QEMU.
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
  a `struct lock`. Never hold one across `thread_sleep`, `thread_wait`,
  `thread_join` or `thread_safe_point`: it is a panic. A thread that has
  to wait for something else than a tick or a lock puts itself on record
  with what it waits for and calls `thread_wait`; whoever has it, a
  thread or an interrupt handler, calls `thread_wake`, which says no more
  than "look again", so the waiter looks, in a loop. The page
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
- A device's interrupt is a message (kernel/interrupt.c): the device
  writes a number to an address. `interrupt_message` hands one out, and
  `arch_message` in each arch/<arch>/interrupt.c says which address and
  number: the local APIC on x86_64, a GICv2m frame or the ITS on AArch64.
  Each of the four boots of `make test` takes one of those ways, so a
  change there is tried on all four: `NO_HVF=1 tools/boottest.sh aarch64
  -machine gic-version=3` is the ITS on the Mac, where the plain boot has
  the frame. Lisp gets the three as `clara.unsafe:message-interrupt`.
- A driver is a file in lisp/ like the console: it finds its device among
  `(clara.pci:devices)`, maps registers with `clara.pci:map-registers`,
  asks for its interrupt with `clara.pci:message-interrupt`, shares
  memory from `clara.unsafe:allocate-memory` with the device, and has a
  thread that waits for the interrupt's event. A virtio device goes
  through lisp/virtio.lisp. lisp/host/tests.lisp has a PCI bus and a
  virtio device of its own making (`attach-bus`, `add-input`): a new
  driver gets its device there, and its registers are not readable until
  the driver has mapped them, as on the machine. The host machine refuses
  what the kernel refuses, an address that is not a multiple of the
  access and a value that does not fit.
- tools/run.sh gives every machine a virtio keyboard, mouse and tablet
  (`INPUT=` for none, `INPUT="-device ..."` for others), and its boot
  volume as a virtio disk with `bootindex=0`, which is what the firmware
  boots from whatever build/vars-<arch>.fd remembers. A boot that ends at
  the firmware's `Shell>` means the firmware did not find that disk. The
  disk is a file that tools/mkdisk.py makes of build/esp, a FAT volume of
  any of the three kinds behind either table of partitions or none
  (`--fat`, `--table`): build/disk-<arch>.img for `make run-*`, made again
  when build/esp has something newer and kept until then with whatever
  the kernel wrote to it, a saved world among it; and for a boot of the
  tests build/boot-<name>.img, new every time.
- Disks and files. lisp/disk.lisp is the driver for virtio's disks:
  sectors of 512 bytes, into and out of page frames, one request at a
  time. lisp/fat.lisp reads FAT volumes on them, and hands the language
  its two functions with `clara:provide-files`; OPEN, LOAD, PROBE-FILE
  and DIRECTORY are in lisp/boot.lisp and ask those. Whatever a function
  there takes from `clara.unsafe:allocate-memory` it gives back on every
  way out, with UNWIND-PROTECT, and whatever looks at a volume's table
  holds the volume's lock. The host tests have the other side:
  `add-disk` makes a disk of a vector of bytes, which can fail, take its
  time, lose its interrupt or say nothing, and which fails the run when
  it is asked in the wrong way, given memory that was not handed out, or
  (`vdev-watch`) asked without a lock; `make-fat-volume` lays a tree of
  files out as a volume of any kind, with its files in pieces, back to
  front, or wrong in the ways its options say, and `make-disk` puts
  volumes behind a table of partitions. A new case of what a disk can
  hold is a row or an option there. `clara.host:allocated-pages` before
  and after says whether page frames were kept. The boot volume of a
  boot is a real disk, and the session writes files to it; the disk for
  writing sectors that are nobody's is the last one,
  build/scratch-<name>.img, which tools/boottest.sh makes anew for every
  boot. `DISK=file tools/boottest.sh <arch>` boots a copy of that disk,
  so the file itself is never written to: `DISK=build/claraos.img` is
  the image that `make image` makes, a GUID partition table and a volume
  of the kind 32, and both sessions have to pass there as well: macOS
  puts `._` files beside the others, so a session shows a file or a
  pattern, not a whole directory.
- Writing files (lisp/fat.lisp). A file is written in an order that a
  machine can stop in at any moment: its bytes into free clusters, then
  the table, in every copy, then the entry in its directory, and only
  then are the clusters of the file that was there before given back.
  Whatever changes the table does it inside `with-table`, which takes
  what is held of the table to the disk at the end and lets go of it when
  something fails, and with the volume's lock. After every boot
  tools/boottest.sh has the host's own checker look at the volume
  (fsck_msdos on the Mac, fsck.fat on Linux), and the host tests have
  `inspect-volume`, which reads a volume's bytes without the file system
  and says what is out of order: a new way of writing gets a round there,
  and the test of a disk that stops at each request in turn says whether
  the order still holds. What a test puts on a volume as dirt must not
  look like the name of a volume, bit 3 of the byte at 11: a directory is
  read past those.
- Images (kernel/lisp/image.c, `clara:save-image` in lisp/boot.lisp). A
  world that was saved comes back as its heap and nothing else, so
  whatever a file in lisp/ knows of the machine it learns in its START,
  never in a DEFVAR's first value, which is evaluated once, in the world
  that is saved: START forgets what it knew, does not give back what it
  held, since that was another boot's, and is called at every boot,
  image or not. A change to what an object is in memory, to the tags, to
  `enum lisp_type`, to a struct of lisp.h or to `lisp_roots`, raises
  `FORMAT` in image.c in the same change, or an older image is taken for
  a heap that it is not. A row can go anywhere in `lisp_primitives` and
  in the table of special forms: an image finds its functions in C by
  their names, so it is a name that must not change, and a function that
  is taken out makes older images refused. A new word in an object that
  holds an address of the kernel's is cleared in `settle`. To try an
  image by hand: `tools/boottest.sh <arch>`, then
  `NAME=<arch>-resumed DISK=build/boot-<arch>.img SESSION=tools/resumed.txt tools/boottest.sh <arch>`;
  `SPOIL=1` changes a byte of the image first, and `EXPECT=` is a line
  that the boot report has to have. The boot report says
  `lisp: the heap is an image` or `lisp: clara.image is not resumed:`
  and why; a world that came as an image skips the tests of the reader,
  the collector and the evaluator, which `(cl::%self-test)` at its prompt
  makes up for.
- LOAD is Lisp since boot.lisp defines it, over two functions in C:
  `%load`, the boot files, and `%load-text`, a text with a name. A text
  of the evaluator's self-test must not reach the file system (PROBE-FILE,
  DIRECTORY, OPEN with a name that could be there): the texts run again
  with a collection at every safe point, and one lookup would take
  minutes on CI.
- `make test` boots seven times. Three machines, x86_64, AArch64 with
  GIC version 3, and AArch64 emulated with GIC version 2, whose files in
  build/ are named aarch64-gic2, each from a disk of another kind, and
  each twice: the first boot is typed tools/session.txt, which ends by
  saving the world, and the second, named with `-resumed` at its end,
  starts from that image and is typed tools/resumed.txt. Then AArch64
  once more for tools/stress.txt (aarch64-stress), a session that has the
  collector run at every safe point of the evaluator while boot.lisp
  loads again and the evaluator's self-test is repeated; its disk has an
  image with a byte changed, which it has to refuse. The serial port of each is QEMU's standard input and
  output: the log is what the kernel printed, and a FIFO feeds it what
  the session types. QEMU's hvf has no version 2, and UTM uses version 3.
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
  (kernel/boot.c) reads every file there into a `struct boot_file`, the
  image too when there is one. Unless the world is an image's, the
  kernel loads boot.lisp itself and panics when that fails, with the file
  and the line. Any other file is loaded by `(load "name.lisp")`, from
  boot.lisp or from the prompt.
- lisp/boot.lisp is the part of the language written in Lisp, on top of
  the special forms (eval.c) and the functions in C (builtin.c). It is
  read in COMMON-LISP: a new definition there also goes into the `export`
  list at the top of the file, or no other package can call it, and a
  helper that nothing else should use has a name that begins with %. A
  macro's body runs when the macro is first used, so the order of the
  file matters only for what runs while it loads, DEFSETF for one. Its
  last two parts are read in CLARA and in CLARA.UNSAFE. The host tests
  read the file as text and hold its names against SBCL's: keep a
  definition's `(defun ` and its like at the start of a line.
- The other files in lisp/ are the world, and each has to load under
  SBCL as it stands: the subset of Common Lisp that the evaluator has,
  no name of Common Lisp's given a new meaning (LISTEN is one), and the
  substrate only through CLARA and CLARA.UNSAFE. The kernel loads them
  in the order of `world` in lisp.c (the console, pci, virtio, input,
  disk, fat, the listener), and lisp/host/tests.lisp loads the same
  files: a new one goes into both. What they print while they start is part of the boot
  report, and a line of it stays under 100 characters too. Its logic is
  tested there, on the machine that lisp/host/clara.lisp makes up: a
  device is a function put at an address or at a port, and a test looks
  at the bytes and the pixels. A boot only says that the interpreter runs
  the file. To type at the console by hand, bytes and all, run
  tools/run.sh with `SERIAL=stdio` from a script and write to its
  standard input.
- The console in Lisp (lisp/console.lisp) and the substrate's (fbcon.c)
  draw the same cells with the same glyphs, kernel/font.c and
  lisp/font.lisp, both from `make font`. A change to one grid or one
  colour is a change to both. The screen changes hands by
  `clara.unsafe:take-screen` and `give-screen`; a fault report takes it
  back and clears it, which `SESSION=` with a form that writes into the
  kernel's code shows.
- The Lisp runtime is kernel/lisp/, and lisp.h is its interface: the
  comment at its top says what a Lisp value is. In C a value is a `lisp`,
  one tagged word. Look at the tag (`lisp_is_cons`, `lisp_is_symbol`,
  `lisp_is`) before making a pointer of it: `lisp_as_cons` and its like
  check nothing. Every object comes from `lisp_alloc`, and
  `lisp_object_words` is the one place that knows how long an object is:
  a new type gets a name in `enum lisp_type` before LISP_FREE, a case
  there, its tag in `object_of` (heap.c), and a count in the census line
  of lisp.c. Every word after its header has to be a Lisp value, as it
  is for every type but strings, or the collector has to be told
  otherwise where it looks into an object.
- The collector (heap.c) runs at the evaluator's safe points and nowhere
  else: making an object never collects. So the runtime's C code may keep
  objects in local variables while it makes others, and nothing in
  kernel/lisp/ may come to a safe point (a call of `lisp_apply`,
  `lisp_eval` or `lisp_call`, or a wait) while it holds an object that
  nothing else points to: after the call the object is gone, freed by
  this thread or by another. The reader takes its text whole for that
  reason, and the functions that wait (thread.c) hold nothing but their
  arguments. A value the substrate has to find again belongs in
  `lisp_roots`, every word of which is a Lisp value, and not in a static
  variable; what the
  evaluator keeps is listed in `lisp_eval_roots`, and a static lisp
  added there has to hold a Lisp value at all times, also when it means
  nothing.
- Lisp threads (kernel/lisp/thread.c). One of them at a time has the
  runtime, and nothing in kernel/lisp/ takes a lock: between two safe
  points a thread is alone in the heap. The evaluator's variables in
  eval.c are the running thread's; whatever is added there is put away
  and brought back in `lisp_evaluator_out` and `lisp_evaluator_in`, and
  reached in `reach` if it holds an object. A function in C that has to
  wait does it through `wait()` in thread.c, which gives the runtime up:
  it puts the thread in the queue of what it waits for, waits, takes
  itself out, and calls `lisp_safe_point()`, returning at once when that
  says 0: the thread was told to stop, or Ctrl-C was typed. All of it in
  a loop, because a wake says only "look again". What an interrupt
  handler touches, an event's count and queue, is changed with
  interrupts off; everything else needs nothing, the runtime being the
  thread's. An object that holds an address of the kernel's (a thread, a
  lock, an event) keeps it in a word that the collector takes for a
  fixnum: only addresses that are multiples of eight.
- When the collector, the allocator or a fault report says that freed
  memory was used (`LISP_FREED`, 0x7deaddeadded, is what a freed word
  holds), something kept an object across a safe point. `(cl::%collect)`
  in a text of the self-test puts a collection where it is wanted, and
  `(cl::%collect-every 1)` has every safe point collect, which is what
  tools/stress.txt types: run it with
  `SESSION=tools/stress.txt NAME=stress tools/boottest.sh aarch64`.
- Evaluating is coming to a safe point: `lisp_apply` is one, and so is
  GO. So across any call of `eval_car`, `progn`, `lisp_eval` or
  `lisp_apply`, an object that has to survive is on the evaluator's value
  stack (`*g_sp++ = x`, or `lisp_push` in a loop, which looks for room),
  not in a C variable: the frame a special form made, the arguments so
  far, a list being built. Forms need no pushing; they hang from the
  function being called. Whatever a function pushes or binds it gives
  back on every way out (`g_sp = base`, `unbind(bound)`):
  `lisp_evaluate` panics when the stacks are not where they were.
- After every one of those calls, look at `g_unwind.to` (or
  `lisp_unwinding()` outside eval.c) and return when it is set: a
  RETURN-FROM, a GO, a THROW or a condition is on its way out, and the
  value in hand means nothing. An error is `return lisp_fail("... ~S
  ...", x)`, with ~S and ~A for a `lisp` and ~Z for a C string; say what
  went wrong in words, the way the fault reports do. It makes a
  condition of the type ERROR. Where a program would want to tell the
  error apart, `lisp_fail_as("TYPE-ERROR", "DATUM", x, "...")` makes one
  of a type that lisp/boot.lisp defines, with a slot or with NULL for
  none. A full stack or heap is a STORAGE-CONDITION, which no handler
  for errors takes.
- A new special form is a function `sf_name(args, env)` in eval.c and a
  row in `specials`: how many subforms it takes, and whether it passes on
  the values of a form inside it. A new function in C is a `PRIMITIVE` in
  builtin.c and a row in `lisp_primitives`: its name, external in
  COMMON-LISP unless it begins with %, and how many arguments it takes;
  `lisp_wants("a list", x)` is the error for an argument of the wrong
  kind. A function that calls a function it was given is written in
  Lisp, in boot.lisp, so that C never holds a list across the call. A
  name that begins with `CLARA:` or `CLARA.UNSAFE:` is in that package;
  the functions of thread.c and unsafe.c are declared in lisp.h with
  `LISP_PRIMITIVE` and have their rows in the same table. Whatever goes
  into CLARA or CLARA.UNSAFE needs its stand-in in lisp/host/clara.lisp
  in the same change, and a name in COMMON-LISP has to be Common Lisp's:
  the host tests read the tables and fail otherwise.
- Nothing in C writes to the console for Lisp. The printer makes a
  string (`PRIN1-TO-STRING`, `%FORMAT`), and the function that writes,
  which is Lisp, in boot.lisp, hands it to a stream. `kprintf` is for the
  boot report and for a panic: once the console in Lisp has the screen,
  what the substrate prints goes to the serial port only.
- A Lisp form that is not what it should be must not take the kernel
  down. In eval.c `car` and `cdr` give NIL for anything but a cons; use
  them, or look with `lisp_is_cons` first, wherever a form's shape is not
  yet known.
- `lisp_selftest` (kernel/lisp/lisp.c) runs at every boot: new syntax gets
  a line in `forms`, with the text and its print, and whatever has to be
  refused gets one in `refused`. It reads in a package of its own, so
  that its symbols do not stay in COMMON-LISP-USER. `eval_selftest` runs
  after boot.lisp is loaded: anything new in the evaluator, in builtin.c
  or in boot.lisp gets a line in `evaluations`, a text and what
  evaluating it gives, the values with a space between them or `error: `
  and the text of the error. Every wrong answer is printed before the
  panic. `collector_selftest` runs before boot.lisp is loaded, and a text
  that has to do with what the evaluator holds calls `(cl::%collect)`
  in the middle. A text whose answer depends on the machine, its ports
  or its screen, goes into `either`, with both answers. The texts are
  evaluated again with a collection at every safe point, and every call
  of a function in Lisp is one, so a text that goes round a thousand
  times costs seconds where the machine is emulated. Threads in a text
  have to be made to overlap, with `clara:thread-yield` or an event:
  left alone, each finishes within its first turn. After a change to
  eval.c, look at how deep a function can call itself, in the boot
  report: when the compiler stops inlining a function on that path, a
  third of the depth is gone. After a change to the runtime, break it on
  purpose and see that the boot notices, and after a change to a file in
  lisp/ that the host tests do; ROADMAP.md lists what was tried, under the
  slow test mode. Doing that for the evaluator found a text that could
  not fail. When a source is patched for such a check, delete the object
  that was built from it before `make`, and the kernel image with it:
  make goes by the second, and a patch written in the second of the last
  build is not built, or built and not linked, so the check passes on
  the kernel that was there before.
- kernel/lisp/self-test.lisp is a file with a mistake in it, which the
  build puts on the boot volume beside lisp/boot.lisp and the evaluator's
  self-test loads. A text that needs a file to load finds one there.
- tools/session.txt is what `make test` types at each kernel over the
  serial port once the listener reads from it, and what the kernel has to
  answer, to the byte. The lines that begin with `> `, or with two spaces
  for a form that goes on, are typed; the others have to come back.
  Change it when what the kernel prints there changes. A line that is
  `^C` and nothing else is Ctrl-C, for the form in the line before it,
  which has to be one that never ends and that the session types once:
  the boot test waits for the kernel to echo that line before it types
  the Ctrl-C and the rest. A line `^M command` is a command for QEMU's
  monitor, sent at the same moment (`sendkey ctrl-c`, `mouse_move 30
  20`), and after a line `^K` the next line is typed on the keyboard, by
  `sendkey`, once the kernel has printed the line before the `^K`, which
  therefore has to be one that comes nowhere else. A line for the
  keyboard is short, 64 events at most, a key being four and eight with
  Shift, and a session does not end with a `^M`. What a machine answered is in
  build/session-<name>.txt, and `SESSION=file tools/boottest.sh <arch>`
  types another session. A boot that panics or faults fails at once,
  without waiting for the timeout. tools/resumed.txt is the session for
  a world that came back: what the first session defined has to be
  there, and what it left in the way, a lock that was held, a thread that
  waited, a package that uses no other, has to be out of it. Whatever a
  session of the first boot adds to the world can be asked for there.
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
  one goes into both in the same change. fsck.fat there is stricter than
  the Mac's fsck_msdos, so a change to tools/mkdisk.py or to how
  lisp/fat.lisp writes is tried in the container below before it is
  pushed. The serial logs and screenshots of
  a run are in its artifact, boot-reports.
- To see a change the way CI will before pushing it, with Docker running:
  an ubuntu:24.04 container with the packages from the workflow, a copy of
  the tree without build/, and `make test` in it. In zsh a pattern that
  matches no file ends the whole command line before it runs: a line
  that begins with `rm build/*x*` and goes on to `make test` and a `grep`
  of its log then shows the log of the run before. build/ itself must not be
  shared with the container: the objects in it come from another compiler.
