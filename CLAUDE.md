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
files under SBCL (`make host-test`, ten seconds), then boots both
architectures headless under QEMU, fourteen boots in about four minutes,
types a session at each kernel, and saves what each screen shows to
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
  entry records the version. The picture on the website goes with it
  (Julio, twice on 2026-11-17, about a caption that named an older version
  than the page: "this text is still out-of-sync with the version we're
  on"): after the last `make test` of the change, `make screenshot` makes
  site/boot.png of build/screen-aarch64-resumed.png and writes the version
  into it, and `make site` stops when the picture is of another version
  than the kernel's. When tools/resumed.txt ends in another way, or types
  something else into the listener's window, the words beside the picture
  in site/index.html, its `alt`, are changed by hand.
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
  (`--fat`, `--table`): build/disk-<arch>.img for `make run-*`, made once
  and kept from then on, with whatever the kernel wrote to it; and for a
  boot of the tests build/boot-<name>.img, new every time. Run by hand
  without `DISK=`, tools/run.sh works on the first of those: it gives the
  machine a newer build as a second disk, which the system on the disk
  takes as it starts (upgrades, below), so the disk that Julio runs from
  is another system afterwards. Give it `DISK=` and a file of the
  session's own, or use tools/boottest.sh, which always does. In another
  worktree build/ is another directory, and nothing of his is touched.
- `WORK=file` gives a machine a second disk, the user's own (the manual,
  "A disk of your own"): tools/run.sh puts it in front of the other
  arguments, which is behind the boot disk and the keyboard and pointers
  on the bus, since names are looked up on the first volume there. It
  makes no such file and stops when there is none. tools/boottest.sh
  takes `WORK=` like `DISK=`: the machine gets a copy,
  build/work-<name>.img, which the next boot of that machine can be given
  and which the host's checker looks at with the boot volume. `make test`
  clears the variable (`test: export WORK :=`), so a work disk that the
  environment names stays out of it, and gives one to the manual's two
  boots, where the manual's section is typed. A disk of either kind that
  is open on the Mac, in the Finder, is ejected by tools/run.sh before
  QEMU is started (`release`), because QEMU does not start with one and
  says only that it failed to get a lock. hdiutil lists an open file as it
  was named when it was opened, so the script asks whether that is the
  same file (`-ef`) and does not hold the names against each other. No
  boot of `make test` comes that way: after a change there, try it by
  hand with a scratch disk in /tmp, opened with `hdiutil attach`, and
  never with a disk of Julio's that is mounted.
- Disks and files. lisp/disk.lisp is the driver for virtio's disks:
  sectors of 512 bytes, into and out of page frames, one request at a
  time. lisp/fat.lisp reads FAT volumes on them, and hands the language
  its two functions with `clara:provide-files`; OPEN, LOAD, PROBE-FILE
  and DIRECTORY are in lisp/boot.lisp and ask those. Whatever a function
  there takes from `clara.unsafe:allocate-memory` it gives back on every
  way out, with UNWIND-PROTECT, and whatever looks at a volume's table
  holds the volume's lock. Whatever looks a name up takes its volume from
  `the-volume`, which gives `clara.fat:*volume*` only when START found it:
  a user binds that variable to a second volume, and a world that was
  saved can hold a volume of an earlier start, with a disk and a page
  frame that are no longer its own. The host tests have the other side:
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
  a heap that it is not. (An image is started by the system that saved it
  and by no other since 0.0.26, and every build is another system, so the
  number matters for an image that is carried to another build by hand
  and for nothing else; it is raised all the same.) So does a change to what code for the processor
  leans on, since a world holds its code: the order of the words of
  `struct lisp_machine`, what the functions that it names take and give,
  the numbers of machine.h, and how such code begins and what it keeps
  in which register (lisp/native.lisp, entry.S). A row can go anywhere in `lisp_primitives` and
  in the table of special forms: an image finds its functions in C by
  their names, so it is a name that must not change, and a function that
  is taken out makes older images refused. A new word in an object that
  holds an address of the kernel's is cleared in `settle`. To try an
  image by hand: `tools/boottest.sh <arch>`, then
  `NAME=<arch>-resumed DISK=build/boot-<arch>.img SESSION=tools/resumed.txt tools/boottest.sh <arch>`;
  `SPOIL=1` changes a byte of the image first, and `EXPECT=` is a line
  that the boot report has to have: give it with `SPOIL=1`, since a
  spoiled world that is resumed all the same shows only in answers that
  make no sense. The boot report says
  `lisp: the heap is an image` or `lisp: clara.image is not resumed:`
  and why; a world that came as an image skips the tests of the reader,
  the collector and the evaluator, which `(cl::%self-test)` at its prompt
  makes up for.
- LOAD is Lisp since boot.lisp defines it, over two functions in C:
  `%load`, the boot files, and `%load-text`, a text with a name. `%load`
  takes a name with `/clara/` before it as well, since those are the files
  of that directory: an application's file is found on a machine with no
  disk to read. A text
  of the evaluator's self-test must not reach the file system (PROBE-FILE,
  DIRECTORY, OPEN with a name that could be there): the texts run again
  with a collection at every safe point, and one lookup would take
  minutes on CI.
- The compiler (lisp/compiler.lisp) and its machine (kernel/lisp/vm.c).
  A compiled function means what the evaluator makes of its forms, and
  that is tested, not hoped: `compiler_selftest` (lisp.c) has every text
  of `evaluations` compiled and run at every boot from the files, and what
  comes back has to be the evaluator's answer. So a change to the
  evaluator, to builtin.c or to boot.lisp that gets a row in `evaluations`
  is tried compiled by that row; a text that has to differ once it is
  compiled goes into `compiled`, with what it gives then; and what only
  makes sense with a compiler, COMPILE and its kin, a function of one kind
  calling one of the other, goes into `compilations`, which the evaluator
  is given once the compiler is loaded. A new special form in eval.c gets
  a converter in `*special-forms*` and a generator, with the same count of
  parts: the host tests hold the two tables against each other. The texts
  are gone through four times at such a boot: by the evaluator; compiled
  by the compiler while the evaluator still walks it; compiled by the
  compiler once it has compiled itself and boot.lisp (`new_world`); and
  compiled and then translated, so that the processor runs them itself
  (`native_selftest`), with `compilations` in the last three. A text of
  `compilations` whose answer is another once it is translated, a listing,
  has a row in `translated`. So a text leaves nothing behind that
  the next round trips over: one that gives a function of the system's
  another meaning puts the old one back in an UNWIND-PROTECT.
- A compiled world. Once lisp/compiler.lisp has said that it is there
  (`clara:provide-compiler`), EVAL compiles the form it is given and LOAD
  every form that it reads (`lisp_eval_form`, eval.c), so whatever is
  typed or loaded is the machine's. `lisp_evaluate` in C is still the
  evaluator: the texts of the self-test go to it, so `(defun ...)` in a
  text of `compilations` makes a function that is walked, and `(eval
  '(defun ...))` a compiled one. lisp/boot.lisp and lisp/compiler.lisp are
  loaded twice when a machine starts from the files, walked and then
  compiled, the compiler first, so every form at the top of those two
  bears being evaluated twice: what lasts is in a DEFVAR, and nothing
  there adds to what the first load made, a PUSH onto a list, a counter.
  While compiler.lisp is loaded the second time the compiler is partly
  walked and partly compiled, and each definition has to work with either
  kind of every other. A file of the world is never walked: it is
  compiled a form at a time as it is loaded, so a macro stands before the
  first function that uses it, as in any file that is compiled. When the
  world is loaded, `new_world` goes through the heap and panics if a
  function or a macro is left that the evaluator would walk
  (`lisp_heap_functions`): something that the first load of one of the
  two files put into a table and the second did not replace, or something
  that is held from outside the heap, on the value stack, in the bindings,
  in `lisp_values` or in `g_unwind`. An exit that is over leaves nothing
  in `g_unwind`: the collector looks there, and a clause that stayed held
  on to its function and to all that the function's symbols lead to.
- A macro that compiled code makes is a function of the kind LISP_MACRO
  whose code is a compiled function of the whole form (`convert-expander`
  in lisp/compiler.lisp, `expand` in eval.c); the evaluator's own has a
  lambda list and a body there. The compiled one takes its form apart
  with `destructure-bindings`, which is told who is doing it, for what an
  error says: the words are the ones of `bind` in eval.c, and the texts of
  `evaluations` about macros hold the two to one answer.
- The machine's instructions are a table in vm.c, with the enum above it
  in the same order, and a list in lisp/compiler.lisp, `*operations*`,
  which says for each what it does to the depth of the stack and what its
  operands are; lisp/host/vm.lisp is the same machine a second time, in
  Lisp. A new instruction goes into all of them in the same change, at the
  end, and raises `FORMAT` in image.c: a world that was saved holds its
  code. Code for the processor leaves a new instruction to the machine
  without being told (below), unless it makes a record or binds a special
  variable: then its name goes into `plain-p` of lisp/native.lisp. `check` in vm.c looks at every operand of code before it is made a
  function, by the kinds that the table gives them; it looks at an
  instruction's number before it uses it for anything.
- The instructions from `OP_CAR` on stand for a function in C, each under
  that function's name. One more of them is a row in both tables, a line
  `ONE` or `TWO` in vm.c, the name in the list of lisp/compiler.lisp that
  gives the symbols their `instruction`, and a place in the manual's
  sentence that names them. The line in vm.c says which arguments the
  instruction takes for itself and what it gives for them, which has to
  be what the function in builtin.c gives; anything else it leaves to the
  function (`known:`), which says what is wrong in its own words. It does
  its work only while its bit of `g_original` is set, and
  `lisp_set_function` is what keeps those bits: nothing else gives a
  symbol its function once the evaluator has started, and the host tests
  count the places in the sources that do.
- vm.c keeps what it holds on the value stack, like eval.c, which it
  shares its state with through eval.h: across `lisp_apply` and
  `safe_point` nothing that the collector has to find is in a C variable
  alone. The stress boot has the collector run at every safe point of
  compiled code, so that whatever does is found. A record on the stack is six words that
  the collector takes for values, so an address in one is a multiple of
  eight.
- Code for the processor (lisp/native.lisp, kernel/lisp/native.c, the two
  routines at the end of each entry.S). Translating is the rule
  (`clara.native:*translate*` is true): whatever the compiler makes is
  translated before it is run, and a world is the processor's through and
  through. lisp/native.lisp and the processor's file are loaded right
  after the compiler has compiled itself, as code for the machine; then
  `clara.native:translate-all` goes through the heap for every function
  that the machine still runs (`clara.unsafe:untranslated-code`),
  translates it, its own first, and has every function entered by the
  processor (`clara.unsafe:native-functions`). Nothing has to be done for a
  new file of the world: it is translated a form at a time as it is
  compiled. What must not be is a compiled function in the heap that the
  machine runs once the world is loaded: `new_world` panics at that, as
  it does at one that the evaluator would walk. The machine of vm.c stays:
  it does the instructions that this code leaves to it, it runs what is
  compiled while the variable is NIL, and the texts are run on it twice
  before the translator is loaded.
- What the compiler made is translated an instruction at a time, and an
  instruction is the machine's unless `instruction` or `known` in
  lisp/native.lisp writes it out: `(flush)` and `machine-step` have vm.c
  do that one instruction (`lisp_native_step`), by the piece of code that
  every function has for that behind it (`step-piece`). So a new
  instruction is right there without a line, and gets one only to be
  quick. What is written out does what the case in vm.c does, to the
  word: the same test of the arguments, the same count of values, the
  stack as deep afterwards. Where it finds arguments that it cannot do, it
  goes to the machine (`to-machine`) with the arguments on the stack as
  the machine would have found them, so nothing is changed before the
  last test has passed, and a sum that did not fit is taken back first.
  Every word of the kernel's is reached through :RT, by a number from
  `where`, and never by an address: a saved world's code has to be good
  for a kernel that lies somewhere else.
- A value that the machine would push is not pushed until it has to be
  (`*pending*`): `(:local n)`, `(:const n)` and `(:closed n)` are still to
  be fetched, and `(:reg)`, always the oldest, is in :A and nowhere else.
  An instruction that is written out takes its arguments with
  `arguments`, which brings them into :A and :B and pushes the rest, and
  says `result` when what it made is in :A. Everything else begins with
  `(flush)`. Nothing is pending where two ways through the code meet,
  which is at the instructions that `targets` finds, at a call, at a jump,
  or anywhere that the collector can look: nothing that it has to find is
  in a register across `:call-lisp`, a jump backwards or an instruction of
  the machine's, and :A to :F mean nothing after `:call-lisp`. The three
  functions in C that make an object (`:cons`, `:cell`, `:closure`) are
  no safe point and are called with what is in the registers. A
  comparison whose value only the next instruction wants, a JUMP-IF-NIL
  that nothing else jumps to, is written with it as one (`jump-after`,
  `*taken*`); and an instruction that stands for a function in C does not
  write that it made one value when the next one takes the value off the
  stack for itself (`value-made`): an instruction that reads the count of
  values, or leaves the value where it is, must not be put on that list.
- `machine` in vm.c is the machine three ways: a call from its arguments
  to its return (CALL), and for a call that the processor is in the
  middle of one instruction (STEP) or the way out when an exit is under
  way (UNWIND), each of which says where the code goes on. The place that
  a record names, `pad`, is the number of an instruction to the machine
  and a count of bytes into the code to the processor, which
  lisp/native.lisp writes into the instruction's word (`:word`); wherever
  the machine sets `pc` to one, it sets `landed`. A call of the
  processor's keeps the innermost record and the count of bindings in two
  words after its local variables, when its code makes either, and has
  no such words otherwise (`hidden`, `LISP_NATIVE_HIDDEN`): whoever makes
  such a call's variables, `machine` for a call from C, the code itself
  for a function of required parameters, `lisp_native_arguments` for any
  other, makes those two.
- `struct lisp_machine` (lisp.h) is all that such code knows of the
  kernel. `g_sp`, `g_unwind`, `g_bound`, `lisp_values`, `lisp_attention`
  and `g_original` are words of it under the names they always had. A
  word that the code is to read goes there, into the table of
  NATIVE-LAYOUT in native.c and into the stand-in of lisp/host/vm.lisp
  with the same number: the host tests hold the names of the two against
  each other. The two routines in entry.S take their few numbers from
  machine.h, which native.c holds against the structs.
- The code lies outside the heap (native.c): pieces in a region that is
  mapped to be run, written only by `put`, through the address that a
  page frame has as RAM. The heap's object for a piece is a LISP_NATIVE,
  and the collector's sweep frees the piece with it. What is written is
  followed by `arch_code_written`, or AArch64 goes on running what was
  there before.
- The two processors (lisp/arm64.lisp, lisp/x86-64.lisp) write the
  instructions of the processor that lisp/native.lisp makes up and lists
  at its top. A new one of those is written in both files, and gets a row
  in the host tests with the bytes that LLVM's assembler writes for it,
  for both: `echo 'add x9, x20, #32' | llvm-mc -triple=aarch64
  -show-encoding`, and `-triple=x86_64` with `leaq 32(%rbx), %r10`. How
  long an instruction is must not depend on where a label lies, and the
  first twenty bytes of a function's code are the same count on both
  (`NATIVE_LEAVE`, `NATIVE_FAST`). `sh tools/processor-code.sh arm64
  '(lambda (n) (+ n 1))'` shows what is made of a form, read back by
  LLVM.
- The processor's self-test is `native_selftest` (lisp.c), which runs
  when the language, the compiler and the translator are translated and
  before the rest of the world is loaded: the texts once more, which has
  to make code and has to send the processor into it; a function that
  calls itself and a loop that adds, of which next to nothing may be left
  to C (the answers are right, too, when every call and every instruction
  goes the long way, and then it is no quicker than the machine);
  functions of the machine's and of the processor's that call each other,
  with exits through both, and one of the machine's made the processor's
  with a closure that was made of it before; a loop and a function that
  calls itself, which have to stop for the collector; and at the end as
  many pieces of code in use as before the texts. On the stress boot
  there is a collection before the first fifty safe points that such code
  comes to after a function has been made of what the compiler made
  (`lisp_native_watched`, `lisp_p_make_compiled_function`): the compiler
  is such code too, and would use them up before a text had run. A loop
  without a call has to have one at each of its first fifty turns. A new
  place where code for the processor comes to a safe point gets a
  `watched_native()`. What that boot costs was guessed wrongly three
  times before it was measured (ROADMAP.md, "What a translated world costs
  CI"): to see where its time goes, start it with `NO_HVF=1` and print the
  time whenever build/boot-<name>.log has a new line. A form that is
  typed with a collection at every safe point is translated with one at
  every call of the translator's, which is seconds: tools/stress.txt
  types one translation and compiles its other forms for the machine.
- The way to the machine of an instruction that is written out, when its
  name was given another function, comes back with a value: for a
  comparison that was written with its jump, the jump is made there
  (`to-machine`). Only a text that gives such a name another function
  comes that way, since a comparison of what are no numbers is an error:
  `compilations` has one, which puts the names right with
  `cl::%set-symbol-function` and not with SETF, which is Lisp and
  compares while it expands.
  Under SBCL nothing of it runs: the tests there translate every function
  that the compiler's forms make, for both processors, and look at what
  can be seen without running it.
- A fault in such code says "code that the Lisp world made for the
  processor" where the kernel's would name a place in the image. On
  AArch64 x19 is `lisp_machine`, x20 the top of the value stack, x21 the
  call's local variables, with the function itself in the word under
  them, x22 its constants and x23 NIL; on x86_64 those are r15, rbx, rsi,
  r14 and rdi.
- Four things of the kernel's Lisp that lisp/native.lisp ran into. A file
  of the world is compiled a form at a time, so a DEFVAR has to stand
  before the first function that binds the variable, or the function
  binds a variable of its own and nobody sees the value. A call takes a
  word of the stack for each argument: `(apply #'vector items)` is not
  how a vector of thousands is made. `make-array` fills a vector with 0,
  here and under SBCL, and 0 is true: a vector of flags is made with
  `:initial-element nil`. (Without it every instruction counted as one
  that something jumps to, nothing stayed pending, the code was as long
  as before and every test passed: the host tests now hold the code of
  `fib` to a length.) And a variable that the compiler or the translator
  looks at counts when a form is compiled, which for a form that is typed
  is before any of it runs: `(let ((clara.native:*translate* nil)) (defun
  ...))` translates the function, and a SETQ on a line of its own, or the
  LET around a COMPILE or a LOAD, does not.
- The compiler counts the stack: every `emit` moves `*depth*` by what the
  table says, and `gen` puts it right after a form, whichever way the
  form's branches went. What code says it needs of stack is the deepest
  that got. The kernel's machine believes that; the one under SBCL counts
  the words and fails the run when code needs more, so a new generator is
  tried there first. Where the depth is not known as the code is written,
  the values of a form on the stack, no jump may leave: the forms there
  are converted behind a barrier (`behind`), and an exit from them goes by
  a tag and a record.
- compiler.lisp is in the world, so it is written in what the evaluator
  has, loads under SBCL as it stands, and names nothing of the substrate's
  that begins with a %: what compiled code needs done is an instruction,
  or a function of the compiler's own package (`key-tail`). What the
  compiler has to write into a form that it rewrites are three forms of
  its own, `%call`, `%fail` and `%raise`. Under SBCL a macro is expanded by
  SBCL, so the forms of the host tests keep to the special forms, to
  functions, and to the macros whose expansions are plain: WHEN, UNLESS,
  AND, OR, COND, DOLIST, DOTIMES, RETURN, and INCF and PUSH of a variable.
  SETF of anything else, CASE and LOOP with keywords are SBCL's own
  business there. A form in `same` is evaluated by SBCL too, so it cannot
  bind a name of Common Lisp's as a function.
- What DISASSEMBLE writes is in a session and in the manual, and a line
  of a session that begins with two spaces is one that is typed: a line of
  a listing begins with its number.
- `make test` boots fourteen times. Three machines, x86_64, AArch64 with GIC
  version 3, and AArch64 emulated with GIC version 2, whose files in build/
  are named aarch64-gic2, each from a disk of another kind, and each twice:
  the first boot is typed tools/session.txt, which ends by saving the world,
  and the second, named with `-resumed` at its end, starts from that image
  and is typed tools/resumed.txt. Then AArch64 once more for
  the collector at every safe point of the evaluator (aarch64-stress). Its
  disk is the one that the first AArch64 session left, with two things on it
  for that boot: the saved world with a byte changed, which the kernel has
  to refuse, and a file `\clara\stress`, which tools/session.txt writes and
  which makes the kernel load boot.lisp again and repeat the evaluator's
  self-test with a collection at every safe point, in `new_world`, before
  the rest of the world is in the heap: a collection goes through 270 KiB
  there and through everything later, so that is where a new text of the
  self-test costs least. The texts are then compiled and run once more
  with a collection before the first two hundred safe points that
  compiled code itself comes to in each text, a call of a function in
  Lisp or a jump backwards (`compiler_selftest`, `lisp_compiled_watched`):
  with one at every safe point, that boot took three times as long on CI,
  435 s of its 600, most of it in the texts that call themselves until
  the stack is full. A new place where vm.c comes to a safe point gets a
  `watched()` before it. That boot then has the texts translated and run
  by the processor, with the same done at the safe points of its code.
  tools/stress.txt then types a few forms with the collector still at it,
  one of them on the keyboard. Each of those forms is compiled under the
  collector, by a compiler that the processor runs, and read by a console
  that it runs: that session is where the processor's code is tried with
  a collection at every one of its safe points in code that nobody wrote
  for the test. One of its forms translates a function there; the others
  are compiled for the machine, which runs them among the processor's. Both lines of the
  boot report are asked for with `EXPECT=`, whose patterns have `;;`
  between them. That boot runs the kernel that is on its disk, which is
  the one the first AArch64 session booted: to try a change there by
  hand, run `tools/boottest.sh aarch64` first and give the stress boot
  `DISK=build/boot-aarch64.img`. Before that one, two boots for what is
  done to a machine and not in it, x86_64-power and aarch64-power, each
  from the disk that its machine's first session left (tools/power.txt,
  below, under shutting down), three for upgrades, x86_64-upgrade,
  aarch64-at-once and aarch64-trial (tools/upgrade.txt, tools/at-once.txt,
  tools/trial.txt), each with the disk of another system beside its own,
  and two boots for the user
  manual, named manual and manual-again: what the manual shows of the prompt
  is typed at them. The serial port of each is QEMU's standard input and
  output: the log is what the kernel printed, and a FIFO feeds it what the
  session types. QEMU's hvf has no version 2, and UTM uses version 3.
  tools/boottest.sh passes any further arguments on to QEMU, which is how to
  try another machine: `tools/boottest.sh aarch64 -smp 4 -cpu max`.
- A system and its directory (the Makefile, tools/system.py,
  kernel/system.c, kernel/boot.c). A build has a name, `$(SYSTEM)` in the
  Makefile: the version and eight digits worked out from `SYSTEM_SRCS`,
  which are all the sources of the two kernels and of lisp/. A new kind of
  source that goes into a kernel or onto the boot volume goes into that
  list. The name is in both kernels (`clara_system`) and is the name of
  the directory on the boot volume that holds the system's files, its
  kernels a second time and its `manifest`; the kernel reads its own
  directory and no other. So a path of a system's file has digits in it
  that change with every edit: Lisp asks `(clara.system:system-file
  "boot.lisp")`, a session writes `{{system}}` and `{{version}}`, which
  tools/boottest.sh fills in, and the manual shows such a name only in a
  `<pre>` that nothing types. `/clara/<name>` in LOAD still finds a file
  of the system's among what was read at boot, and an application that is
  installed by a bare name is a file of the system's directory
  (`clara.windows:*application-directory*`). `make build/system-other/stamp`
  makes a second system of the same sources under the name
  `<version>-other`, as build/system-other/esp, for two links; a name that
  begins with `broken` gets a boot.lisp that is no Lisp. The Makefile must
  never have `.SECONDARY:`: with it make does not relink a kernel when
  the system's name has changed, and the kernel then looks for a
  directory that the build did not make.
- What the handoff does with files (kernel/boot.c), all of it through the
  firmware's file system and before a line of Lisp runs, so that it holds
  when the Lisp does not start. `\clara\starts` counts the starts that did
  not come to a prompt: the handoff writes the count plus one, with a
  number of this start's own behind it, and `clara.system::came-to-prompt`
  deletes the file. After one such start the image is not read
  (`image_passed_over`). `\clara\next` is a system to try: "try <name>",
  which the old kernel's handoff turns into "tried <name>" before it has
  the firmware load and start the new system's kernel in place of itself
  (`start_system`), and into "failed <name>" when it finds "tried" at a
  later start. What Lisp knows of all that is `(clara.unsafe:start-state)`.
  A change there is tried on both architectures, whose firmware is not the
  same program: the `-upgrade`, `-at-once` and `-trial` boots of
  `make test`.
- Upgrades (lisp/system.lisp). `take` copies a system's directory from
  another volume, each file held against the manifest (`take-file`,
  `clara.unsafe:sha-512`), the manifest last, and then writes
  `/clara/next`: that order is what lets a machine stop anywhere, and the
  host tests look at the volume after each refusal. `settle` is what a
  start does about the system, from `start`: a system on trial takes the
  old one's place (`commit`), a failed trial is said and marked, a disk
  that says `/clara/at-once` is taken from at once, and then the start has
  come to its prompt. It uses `clara.fat` and never OPEN or
  WITH-OPEN-FILE, which under SBCL are the host's. The manifest's form is
  read by every older system that upgrades to a newer one, so it is only
  ever added to: a reader passes over a line it does not know. In the host
  tests `system-tree` makes a system's directory with a right manifest or
  a wrong one, `two-disks` a machine with its own disk and another, and
  `clara.host:set-start-state` what the kernel says of the start.
- Work kept as text (lisp/system.lisp, lisp/listener.lisp). A listener
  calls `clara.listener:*record*` with every form that was typed and went
  well, its text and the name of the package it was read in.
  `clara.system::record` writes the ones that define something
  (`defining-p`) into `/home/defined.lisp` on the volume that the machine
  was started from, and a world that this start made from the files loads
  `/home/init.lisp` and then that file (`load-home`, from `settle`), a
  form at a time, each file in a thread that is given `*patience*`. So
  what a session defines at the top of a line is written to the disk of
  its boot, and is loaded by every later boot that makes a world from
  that disk: the upgrade boots and the stress boot. A form of
  tools/session.txt that must not come back that way, one that starts a
  thread or redefines a function of the language's, is typed inside a
  PROGN. What a new world says of the text, the lines that begin with
  `home:`, is asked for with `EXPECT=` (`UPGRADED` in the Makefile). The
  file's form is read by every later system, like the manifest's: forms,
  comments and `(cl:in-package "NAME")` lines, and nothing else. A world
  is saved on that volume too, whatever `clara.fat:*volume*` holds
  (`clara.fat:*image-volume*`). In the host tests `home-tree` gives a
  machine a `/home` and `one-disk` a machine with one disk; a test that
  types definitions sets the start to `:resumed t`, since a world that
  was made loads them in a thread, and SBCL then warns that a function is
  defined a second time.
- A session can wait for the kernel to say something before it goes on:
  `^W pattern`, for a kernel that will say nothing more by itself, a panic
  for one, which `PANICS=1` allows the boot once. `^M system_reset` after
  it starts the machine again the hard way.
- tools/run.sh, without `DISK=`: the machine's disk is kept, and
  `python3 tools/mkdisk.py --systems <disk>` says which systems are on it.
  When that is not the build's, the build goes along as
  build/upgrade-<arch>.img, a disk with `/clara/at-once` on it. A disk
  with no system that has a directory, one from before 0.0.26, is put
  aside under a name that is said (`-old`), and so is the disk when
  `FRESH=1` asks for a new one (`-before`): nothing of the machine's is
  ever deleted there. No boot of `make test` goes that way, so after a
  change it is run by hand, in a worktree of its own: twice with the same
  build, once with another (a line added to a file of lisp/ and taken out
  again), with `FRESH=1`, and with a disk of the old kind.
- Shutting down (lisp/system.lisp, kernel/arch/<arch>/power.c,
  kernel/acpi.c). `leave` is the one procedure behind every way of asking,
  and `finish` its second half, in a thread of its own, since the thread
  that asked may be an application's and stopped on the way: whatever is
  added to a shutdown goes into `finish`, in the order that DESIGN.md
  gives, and gets a line in the host tests, whose machine stays on
  whatever it is told and whose disk says at every request whether the
  window manager still runs (`vdev-watch`). What a new thread writes goes
  where `*standard-output*` points outside every binding, so a test hears
  it with `said-by-all`. The substrate's three functions are
  `clara.unsafe:power-off`, `reset` and `power-button`; each architecture
  finds its way in `arch_power_init`, from ACPI's FADT, and says in the
  boot report's line `power:` what it found. Two facts are searched for in
  the bytes of the DSDT (`acpi_sleep_type`, `acpi_device_memory`): a
  change there is tried on all three machines, since each has a DSDT of
  its own. A program that holds what would be lost gives its window an
  `:unfinished` function, as lisp/editor.lisp does, and nothing else is
  asked before a shutdown.
- A session can go across a start: a line `^R` after the form that starts
  the machine again, and what follows is typed at the kernel that comes up
  then. What the kernel says between "clara: starting the machine again"
  and its next invitation is no part of the transcript. A session that
  ends with the machine turning itself off is given
  `MARKER='^clara: turning the machine off'`: nothing is typed to end it,
  it may end with a `^M` line, the machine has to be gone by itself ten
  seconds later, and there is no screen to save. To press the power
  button: `^M system_powerdown`. tools/run.sh no longer passes QEMU
  `-no-reboot`, so a machine that starts itself again does.
- A function in a file of the world cannot have a name of Common Lisp's,
  also one that the kernel's own COMMON-LISP does not export: under SBCL
  the name is the symbol of COMMON-LISP, which is locked. RESTART is one,
  which is why it is `clara.system:start-again` and `clara.unsafe:reset`.
- The launcher's list has applications and, under a line, commands
  (`clara.windows:define-command`): a command is a function that is called
  in a thread of its own and that nothing waits for, where LAUNCH waits
  for an application's window. The tests' desk has the commands that a
  test gives it and no others (`new-desk :commands`), like its
  applications; `*defined-commands*` are the ones that the files defined.
- Assembly lives in kernel/arch/<arch>/entry.S and nowhere else. On x86_64
  it follows the Microsoft calling convention, like the C around it:
  arguments in rcx and rdx, 32 bytes of home space above the return
  address. What the files of one architecture share is in its arch.h.
- `struct frame` (arch.h) is what entry.S saves, and it is also what a
  thread is while it waits. Shared code never looks inside one: it copies
  `arch_frame_size` bytes, and `arch_frame_init` fills in a new thread's.
  A register added to the frame is switched with the rest; a register
  left out of it is shared by all threads.
- lisp/*.lisp is copied to the system's directory on the ESP,
  \clara\<the system's name> (upgrades, below), and the handoff
  (kernel/boot.c) reads every file there but the kernels and the manifest
  into a `struct boot_file`, and of \clara itself the image when there is
  one and the file `stress`. Unless the world is an image's, the
  kernel loads boot.lisp itself and panics when that fails, with the file
  and the line. Any other file is loaded by `(load "name.lisp")`, from
  boot.lisp or from the prompt.
- lisp/boot.lisp is the part of the language written in Lisp, on top of
  the special forms (eval.c) and the functions in C (builtin.c). It is
  read in COMMON-LISP: a new definition there also goes into the `export`
  list at the top of the file, or no other package can call it, and a
  helper that nothing else should use has a name that begins with %. A
  macro's body runs when the macro is first used, so the order of the
  file matters only for what runs while it loads, DEFSETF for one. That
  is so the first time, when the evaluator walks the file; it is loaded a
  second time, compiled, once there is a compiler (a compiled world,
  above). Its last two parts are read in CLARA and in CLARA.UNSAFE. The host tests
  read the file as text and hold its names against SBCL's: keep a
  definition's `(defun ` and its like at the start of a line. CASE there
  compares a key that is a symbol or an integer with EQ, which compiled
  code does without a call; what a macro of this file expands into is
  what every file of the world runs, so it is worth a look at the
  instructions (`disassemble`).
- The other files in lisp/ are the world, and each has to load under
  SBCL as it stands: the subset of Common Lisp that the evaluator has,
  no name of Common Lisp's given a new meaning (LISTEN is one), and the
  substrate only through CLARA and CLARA.UNSAFE. The kernel loads them
  in the order of `world` in lisp.c (the compiler, then native and the file
  of the machine's own processor, arm64.lisp or x86-64.lisp, whose name
  is the machine's in `*features*`, and then the console, draw, pci,
  virtio, input, disk, fat, the listener, windows, terminal and system), and
  lisp/host/tests.lisp loads the same files: a new one goes into both, and what its package exports goes into
  a list of names in the manual, or `make site` stops. A file that is an
  application is not in `world`, and the launcher loads it (below). What `lisp_main`
  starts of a file that a world may be without, a world that an older
  kernel saved, it looks for first, as it does for CLARA.DRAW; and a
  function in C that the files call goes on taking the arguments it took,
  since such a world calls it the old way: EXPAND-BITS-32 has a ninth that
  it can do without. What they print while they start is part of the boot
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
- Drawing (lisp/draw.lisp, the package CLARA.DRAW). A surface is where
  some pixels are and how they are laid out; the pixels are page frames,
  or the framebuffer. Whatever draws asks `inside` first, which cuts a
  rectangle to what can be drawn on and refuses a surface that was freed
  or that is of another boot (`*machine*`, made anew by START); hands the
  substrate a rectangle that lies wholly within the surface; and ends with
  `drawn`, which keeps the damage and is the T that it gives back. The
  loops over pixels are in C (unsafe.c: FILL-RECTANGLE-32,
  COPY-RECTANGLE-32, EXPAND-BITS-32), which looks whether every pixel it
  is to touch is mapped and no further: a wrong rectangle from Lisp lands
  in somebody's memory. The host tests hold each operation against a rule
  that is written out there (`expected`), at every place on a surface and
  around it (`sweep`), and say which one failed by its name: a new
  operation gets a sweep, and a new way of joining damage a look at the
  test that draws at random and wants every pixel that changed inside the
  damage. A picture of a surface there is its rows as strings, a character
  to the pixel. tools/session.txt defines `picture`, and tools/resumed.txt
  ends by drawing it in a window: that screen is the picture on the
  website, so the last forms of that session, and what it types into the
  listener's window, are what the front page shows. The console does not draw with this file, and writes over what is
  shown.
- Windows (lisp/windows.lisp, the package CLARA.WINDOWS). Nothing there
  draws on the screen: what changes what the screen should show calls
  `damaged` with the rectangle, and `settle` puts the dirty rectangles
  together again on `*back*` and shows them (`compose`), all with `*lock*`
  held. A window's surface is its thread's to draw on; this file only
  copies from it. What a window is told (its KEY, POINTER and CLOSE
  functions) and what a click launches are called after the lock is let
  go, in the thread of the keyboard or the mouse, which is where
  `key-typed` and `pointer-moved` run (`clara.input:send-keys-to`,
  `send-pointer-to`). A new layer goes into `compose` and into
  `should-show` of the host tests, and a new part of a frame into
  `paint-window`, `window-at` and the tests' `window-rule`: the tests hold
  every pixel of the screen against that rule after each thing they do
  (`new-desk`, `wrong-pixels`), and a walk of random steps does it 160
  times. START is for a user and RESUME for the boot: `lisp_main` calls
  RESUME, having looked for the package, and RESUME starts the window
  manager when `*running*` was true in the world that was saved. A
  terminal (lisp/terminal.lisp) is a window with cells and a stream; the
  listener in a window is its application, the first that is defined,
  which START launches. Ctrl-C there is `clara:interrupt-thread`.
- With the window manager running, the keyboard is the window's and not
  the console's. So a session types into a window with a line `^T text`,
  which echoes nothing on the serial port, and sees what came of it in the
  one world: the sessions type `(k)`, a function that signals an event
  which the serial port's form waits for. The second boot of each machine
  starts in the window manager, so tools/resumed.txt has no `^K`. QEMU
  sends a button through another device than a move of the mouse, each
  with a thread of its own, so a session sends one step at a time and
  waits for it (`pointer-at`, `until`, both defined in tools/session.txt);
  the screens differ, 1280 by 800 on x86_64 and 800 by 600 on AArch64, so
  the session first runs the pointer into the corner; and a line that is
  waited for must be the only one of its text, which is why those lines
  are told apart by a word in a list.
- What several devices share, the pointer for one, is read and written
  with its lock held from the reading to the writing: every device has a
  thread of its own, and a thread can lose its turn at any call. The
  pointer's place was read, worked on and written back in three steps
  once, and a move of the mouse was undone by a button of the tablet in
  the same instant, one boot of CI in ten.
- Keys (lisp/input.lisp). What a keyboard hands on is a code: a
  character's, or for a key that types none a code from `char-code-limit`
  on (`clara.input:+up+` and its like, `+f1+` and the eleven after it), and
  with Alt held `clara.input:+alt+` more. Whoever takes codes passes over
  the ones it does not know, and never hands one to `code-char` without
  looking: `clara.console:read-edited-line` does that for every prompt.
  The window manager keeps one for itself, Alt and Tab, in `key-typed`. A
  session sends such keys by QEMU's monitor, `^M sendkey up`, `^M sendkey
  alt-tab`, `^M sendkey ctrl-s`.
- What an UNWIND-PROTECT is there to stop or to give back is made inside
  its form, with nothing between the making and the variable that the
  cleanup looks at: a thread can be stopped at any call. The editor made
  the thread of its forms three lines before the UNWIND-PROTECT that
  destroys it, and an editor that was stopped while it drew left the forms
  running: one run in three of the host tests on CI, and every run in the
  container, whose SBCL is older and slower. A test that stops a thread
  waits for what says how far the thread has come, not for the thread to
  be there. Under SBCL a thread can be stopped before it has run at all,
  and on CI one is: lisp/host/clara.lisp lets go of a thread that SBCL no
  longer has when the list of threads is asked for, since such a thread
  never took itself off, and the last check of the tests wants that list
  to hold the one thread that runs them.
- A window that is opened with `:events t` keeps what it is told, and its
  program takes it with `clara.windows:next-event`, in its own thread:
  `(:key code)`, `(:pointer x y buttons)`, `(:close)`. That is how an
  application is written: a loop that waits, changes what it holds, and
  draws. The close box is told once until the program has taken it.
- Applications in files (lisp/editor.lisp, lisp/files.lisp). They are in
  lisp/, so the build puts them on the boot volume, and they are not in
  `world` of lisp.c: the last lines of lisp/terminal.lisp install them
  (`clara.windows:install-application`), and the launcher loads the file
  when the application is launched and has no function. The file's last
  form is its `define-application`, under the same name. What the file's
  package exports goes into a list of the manual like any other file's,
  and lisp/host/tests.lisp loads the file itself, next to the others,
  which is why an application has a function there without the launcher.
  `unload-application` stops the threads and deletes the packages that
  were new after the load; a file that puts its definitions somewhere
  else leaves them behind. One application starts another by its name,
  `(clara.windows:launch "Editor" name)`, and holds none of its symbols:
  the package may not be there when the file is read.
- An application is written so that the tests can drive it without its
  thread: `open-editor` makes the window and the state, `key`, `point` and
  `happened` change the state, `render` draws, and `run` is the loop that
  the launcher's thread sits in. The same in lisp/files.lisp. A window of
  cells is drawn a row at a time, by `shown`, the strings that were drawn
  last: whatever changes what a row shows has to make the string another,
  or set the row's place to NIL, and what moves pixels moves `shown` with
  them (`scroll`). In the tests, `wrong-cells` holds every cell of such a
  window against the rows it should show, `editor-wrong` and
  `browser-wrong` say which rows those are, and `ref-key` is a second
  editor, kept as a plain list of lines: a key that the editor learns is
  taught to `ref-key` in the same change, and to the walk of random keys
  below it. Under SBCL the files are the host's, in a directory that the
  tests make under /tmp and delete (`scratch`, `write-scratch`), and the
  one function that lists a directory is replaced by `host-names`
  (`clara.files::*names*`): SBCL's DIRECTORY gives pathnames.
- What an application does with a file it does with the language: OPEN,
  READ-LINE, PROBE-FILE, DIRECTORY, DELETE-FILE. So it only ever sees what
  lisp/boot.lisp makes of the file system, on ClaraOS, and that side is
  tested by the boots: tools/session.txt types a file into the editor,
  saves it and reads it back at the serial port. A session waits for the
  editor through the screen: `cursor-at` (defined there) looks for the
  cursor's bar at a cell of the focused window's surface. What is typed
  between two waits stays under 64 events of the keyboard.
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
- A safe point is `safe_point()` in eval.h, a look at `lisp_attention`,
  and `attend()` in eval.c is the call behind it. Whatever brings about
  something for a thread to see at a safe point sets that word: the
  allocator when it is time to collect, a thread that queues for the
  runtime, whoever stops or interrupts a thread, an interrupt. `attend`
  clears it before it looks at anything, and what is still to be answered
  when it returns sets it again. The timer sets it at every tick, so a
  place that forgets to shows as a wait of up to a hundredth of a second
  and not as a machine that hangs: what finds it is a test that wants the
  thing seen at once, like the loop of `new_world` that makes lists in
  less than a tick and has to collect.
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
  reached in `reach` if it holds an object. `g_cleaning` is one of them:
  while it is not zero the thread is in the cleanup of an UNWIND-PROTECT,
  and its safe points neither stop nor interrupt it (`may_stop`), so that
  `with-lock-held` always gives its lock back. A function in C that has to
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
- A package can be deleted (`delete-package`): it leaves the list that
  names are looked up in, and its symbols and what they hold go when
  nothing points to them any more. The five that the substrate holds in
  `lisp_roots` are refused, and so is one that another package uses. An
  object of a deleted package is still a package, so whatever has one in a
  variable, a thread whose `*package*` it is, goes on as before.
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
  monitor, sent at the same moment, and a line `^T text` is that text and
  Enter typed on the keyboard then, with no echo waited for (`sendkey ctrl-c`, `mouse_move 30
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
- The user manual is site/manual.html, the second page of the website
  (Julio, 2026-11-17: it "should have everything a user needs to operate
  ClaraOS, from installation to command line operations", and "should be
  updated constantly as features are introduced"). So a change that gives
  a user something to type, or something else to see, changes the manual
  in the same pull request: a new function or macro, a new message, a new
  key, another way to start the machine, a limit that went or came. Two
  things see to part of that. `make site` stops when the kernel defines a
  name that is in none of the manual's lists (the elements of the class
  "names", at its end), or when a list has a name that nothing defines:
  put a new name where its subject is, and say what it is for in the
  chapter that it belongs to, since the list alone only names it. The
  same goes for what the package of a file in lisp/ exports, which has a
  list with `data-package` for each package. And
  what the manual shows of the prompt, every `<pre class="session">`, is
  typed at a kernel by `make test`, with the ones of the class
  "session again" typed after the machine was started again from the world
  that the first ones saved: an answer that the kernel no longer gives
  fails the boot named manual. Such a transcript is in the order of the
  page, one world from top to bottom; `&lt;`, `&gt;` and `&amp;` are
  written as in any HTML; a form that goes on has two spaces before its
  next line; a line that is `<kbd>Ctrl-C</kbd>` and nothing else is the
  key, after a form that is typed once in the whole manual; and what a
  machine answers differently from another, its devices, its memory, a
  time, belongs in a `<pre>` without the class, which nothing types. To
  try it: `python3 -I site/build.py --sessions build`, then
  `NAME=manual SESSION=build/manual-first.txt tools/boottest.sh aarch64`
  and
  `NAME=manual-again DISK=build/boot-manual.img SESSION=build/manual-again.txt tools/boottest.sh aarch64`.
  The prose is nobody's to check but the writer's: read the chapter that
  a change touches, and look at the page as it is built
  (build/site/manual.html), not only at its source.
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
