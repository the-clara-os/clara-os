# ClaraOS: working notes for Claude

Read DESIGN.md and ROADMAP.md first. Work comes from the issues of the
repository (Julio, 2026-11-22: "I want to transition into issues based
work"): `gh issue list` says what is open. One session is one slice, and a
slice is an issue, the one that Julio names, or a part of it when it is too
large for a session: say which, build it, finish with `make test` green on
both architectures, bump the patch version, update ROADMAP.md, and open the
pull request. Julio reviews and merges it.

Pull requests (Julio, 2026-11-12: "feel free to create the PR straight away
in github"). Work on a `julio/<topic>` branch off main. Never `git commit`
here: commits must be signed, and the local key needs Julio at the
keyboard. `python3 tools/api-commit.py <message-file>` sends the working
tree to GitHub as one commit that GitHub signs, creating the branch there
if needed, and moves the local branch onto it. Then `gh pr create --base main`
with a title in his style, `feat(m3): Virtual Memory`, and a body that says
what changed, how it was checked, every decision that departs from the
roadmap, and `Closes #N` for each issue that it settles, so that the merge
closes it. Never merge, and never push to main. The pull request is built and
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
files under SBCL (`make host-test`, a minute), then boots both
architectures headless under QEMU, twenty-one boots in some six minutes,
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
  entry records the version. Work that leaves the system as it was, a
  page of the website or a document, bumps nothing, and its entry names
  the issue: the number is the system's, a new one is published as a
  release at the merge (below), and every machine that is told to upgrade
  would take a system that differs from its own in the name alone. The
  picture on the website goes with a new version
  (Julio, twice on 2026-11-17, about a caption that named an older version
  than the page: "this text is still out-of-sync with the version we're
  on"): after the last `make test` of the change, `make screenshot` makes
  site/boot.png of build/screen-aarch64-resumed.png and writes the version
  into it, and `make site` stops when the picture is of another version
  than the kernel's. When tools/resumed.txt ends in another way, or types
  something else into the REPL's window, the words beside the picture
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
  asks for its interrupt with `clara.pci:message-interrupt` (a message of
  the device's table, or the one message of a device that has no table),
  shares
  memory from `clara.unsafe:allocate-memory` with the device, and has a
  thread that waits for the interrupt's event. A virtio device goes
  through lisp/virtio.lisp. lisp/host/tests.lisp has a PCI bus and a
  virtio device of its own making (`attach-bus`, `add-input`): a new
  driver gets its device there, and its registers are not readable until
  the driver has mapped them, as on the machine. The host machine refuses
  what the kernel refuses, an address that is not a multiple of the
  access and a value that does not fit.
- tools/run.sh gives every machine a virtio keyboard, mouse and tablet
  (`INPUT=` for none, `INPUT="-device ..."` for others; `UTM=1` for the
  USB controller, tablet, mouse and keyboard and the sound card of
  Intel's that UTM gives a machine, below), and its boot
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
  `the-volume`, which it hands the name, since a name can say its volume
  (below, under volumes), and which gives `clara.fat:*volume*` for a name
  that does not, and only when START found it:
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
- Room for a world (issue #140; DESIGN.md, Images). Every file is
  written beside the one that it replaces (`put-file` in lisp/fat.lisp),
  and a world is the one file that goes where the one before it was when
  the volume has no room for both (`write-image`, which is what
  `clara:save-image` writes through): the older world's entry and
  clusters go first, and a stop before the newer one has its entry
  leaves a machine that starts from its files. Nothing else may be
  written that way: a file that is half there is worse than one that is
  not written. When there is no room even so, nothing is touched and the
  error has the two sizes, to a tenth of a mebibyte, the one rounded up
  and the other down so that they never read the same. `finish` in
  lisp/system.lisp adds how the machine is stopped without saving, which
  is said nowhere else at that moment. To fill a volume at a prompt,
  `clara.unsafe:allocate-memory` and `clara.fat:write-file` (tools/power.txt
  does it, and leaves half a world's room); to make a world larger than
  what is left, a string in a variable, and NIL there again makes it
  small, since an image is made after a collection. The numbers of such a
  message differ from machine to machine, so a session asks for its end
  and not for all of it. The host tests have a volume of 400 clusters for
  the same (`world-of`, `world-on`), and a disk that stops at every
  request of a save, both ways. Their machine has 4 MiB of memory, so
  no world there is larger than that, and a volume of the kind 32, which
  is 33 MiB at the least, is never full for one: what such a volume
  keeps of its free clusters (`note-free`) is held to account by the
  host's checker after the boots that fill a volume on x86_64. macOS's
  checker ends well when that count is all that it would change, and
  says `Fix?`; tools/boottest.sh takes the question for a finding.
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
- `make test` boots twenty-one times. Three machines, x86_64, AArch64 with GIC
  version 3, and AArch64 emulated with GIC version 2, whose files in build/
  are named aarch64-gic2, each from a disk of another kind, and each twice:
  the first boot is typed tools/session.txt, which ends by saving the world,
  and the second, named with `-resumed` at its end, starts from that image
  and is typed tools/resumed.txt. Then each of the three once more from
  that world with the devices that UTM gives a machine (`UTM=1`,
  tools/utm.txt; below, under USB). Then AArch64 once more for
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
  one of them on the keyboard. Its first form tells the listener to write
  nothing down (`clara.listener:*record*`): a form that is written into
  `/home/defined.lisp` with a collection at every safe point takes twenty
  seconds where the machine is emulated, and a minute on CI. Each of those forms is compiled under the
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
  one that fetches a signed release of another system by HTTPS from a web
  server on this computer and upgrades to it (aarch64-network,
  tools/network.txt), and two boots for the user
  manual, named manual and manual-again: what the manual shows of the prompt
  is typed at them, one for a machine with two volumes, aarch64-volumes,
  which is typed tools/volumes.txt (below, under volumes), and one for the
  object system, x86_64-objects, which
  is typed tools/objects.txt (below, under the object system), and one for
  the directives of FORMAT, aarch64-format, in the world that the first
  AArch64 session saved, which is typed tools/format.txt (below, under
  the directives of FORMAT). The serial
  port of each is QEMU's standard input and
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
  directory that the build did not make. The same happened without it
  when the name went back to one that had been built before, a change to
  a Lisp file that was built and taken out again: the object of that
  name was still there, and older than the kernels. So the name is in
  build/system.name, which is written only when the name is another, the
  object with the name in it depends on that file, and the rule that
  fills the system's directory stops the build when a kernel does not
  name that system. Whatever else is made from the name depends on that
  file too.
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
  that disk: the upgrade boots and the stress boot. A form takes the
  place of an earlier one with the same key (`key-of`), its first two
  words, and for a DEFMETHOD also the words before its parameters and
  what each parameter is for: the methods of a generic function are so
  many definitions, and tools/upgrade.txt asks the world that was made
  again for all three of the ones that tools/session.txt types. A form of
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
- A world made again (lisp/system.lisp). The shutdown (`finish`) has the
  world that is leaving write `/clara/carried` when `/clara/next` says
  that a system is to be tried (`carry`). `make-world` is what a start
  does for a world that it made from the files: the window manager when
  the account says that it ran, the text (`load-home`), the account
  (`arrive`), and the save, in that order; `catch-up` is what it does for
  a world that came as an image. A line about how a world came to be
  what it is begins with `home:` or `world:` and goes through `tell`,
  which keeps it for `(clara.system:report)`. The account's form is read
  by the next system, like the manifest's: forms of keywords and strings,
  one to a line, only ever added to. A world knows the text that it has
  (`*known*`), and whatever loads or writes a file of `/home` says so
  with `know`, or the next start in that world evaluates the forms
  again. In the host tests a start that is `:resumed t` is a world that
  goes on in the same SBCL: what the test before it left in `*known*` and
  `*follows*` is what that world knows, and a test that means something
  else sets them. `trial-disk` there gives a machine a system on trial,
  with an account and a `/home`. A machine of the tests has a screen
  only when `new-desk :machine nil` gave it one after its disks: the
  screen of the machine before is memory that is the disk's by then, and
  a window manager that draws there writes into the volume's table. A
  line that a session waits for with `^W` comes once in the whole log, so
  the world of tools/trial.txt that stands still says a different thing
  the second time.
- The network (lisp/net.lisp). A frame is put together in a page frame
  of the card's by `send-frame`, which calls FILL with the address where
  what the frame carries begins and wants its length back; each protocol
  wraps the FILL of the one above it (`send-packet`, `send-datagram`,
  `segment-out`). FILL runs with the card's lock held, so it writes bytes
  and nothing else: whatever has to ask the network something first, who
  has an address, does that before. Numbers on the wire have their
  highest byte first (`two`, `four`, `put-two`), and a checksum is
  `clara.unsafe:internet-sum`, folded. What arrives is handled in the
  card's thread (`take`), which never waits for an answer, since it is
  the one that would have to take it: it answers what is answered at
  once and goes on. Whoever waits for something does it with `ask-until`,
  which looks, asks again every second and gives up after `*patience*`.
  START forgets the card of an earlier start. Under SBCL the card is
  `add-net` and the network at the other end of its wire `new-network`: a
  thread that answers for ARP, DHCP and DNS and serves files, holds every
  frame that the machine sends against checksums that it works out in
  its own way, and has accidents when it is told to (`:drop`, `:spoil`,
  `:swap`, `:lose-opening`, `:mute`). Whatever the machine learns to send
  gets its check there, and a new way for the other side to go wrong an
  option. That network must not answer every repeated acknowledgement
  with everything again: it did, and one lost piece became thirty
  thousand in a second, which looked like a fault of the machine's.
- What a connection sends (lisp/net.lisp, "What a connection sends").
  The bytes lie in page frames of the connection's (`out`) until the
  other side has said that it has them, and the card's thread sends them:
  `heard-of` when the other side says how far it has them, `tend` when
  time has passed, both by way of `pump` and `again`. Those run with the
  connection's lock held, because the bytes move in that memory, so
  nothing in them may wait for the network: they bind `*waits*` to NIL,
  under which `station-of` signals an error for an address that nobody
  has claimed yet, having sent the question. Whoever puts bytes into a
  connection asks for the other side's card before it takes the lock
  (`say-bytes`). The card's thread has the global `*patience*` and
  `*again*` and not the caller's bindings, so a connection carries the
  ones of whoever last used it (`lend`): a new function that waits on a
  connection lends first. What goes wrong in `tend` has nobody to be
  told and is kept in `card-trouble`, which the tests want to be NIL
  where they look. The lists of a card that several threads change
  (connections, listeners, echoes, what is known) are changed with
  `card-book` held, and nothing is called while it is.
- In the host tests the made-up network has a port 9, where everything
  that the machine sends is kept (`network-sunk`, `sent-whole`), and
  options for what the machine has to bear as a sender: `:lose-pieces`,
  `:room`, `:longest`, `:narrow`. It fails the run when the machine
  sends more than there was room for. `:unreachable`, `:names-closed`,
  `:cut`, `:ttl`, `:lease-time` and `:renewals` are the other side of
  ICMP, of the name servers and of an address that is kept. A test that
  binds `clara.net:*again*` to something small has to do so around
  `begin`, which is where a connection takes its first wait from.
- A machine that listens (lisp/net.lisp, "A connection as a stream" and
  "A machine that listens"). The ports are `*doors*`, a variable of the
  world's: START finds them there after a saved world came back, and the
  host tests' `stop-network` empties the list, so that the next machine
  is another world (`new-network :doors` hands one a list). The card's
  thread answers a beginning (`answer-beginning`, the state `:answered`)
  and starts the connection's thread when the other side has answered
  that (`admit`): the user's function never runs in the card's thread. A
  stream reads with `next-line`, which takes from the front of the
  connection's memory (`taken`, `pack`) with the connection's lock, and
  tells the other side when that made room; it writes with `write-text`,
  which is `say-bytes` told not to wait. A packet for the machine itself
  goes by `send-inside` to the card's thread and never by the wire
  (`own-p`), so nobody asks which card has an address of the machine's
  own: `say-bytes` does not.
- In the host tests a machine of the made-up network opens connections to
  the machine: `call-machine port :say ... :end t`, a `call`, which the
  network's thread moves along (`call-step`), and which can lose the
  machine's answers and pieces, go quiet, or begin and not go on. Its
  sender keeps to the room that the machine says it has, so what a test
  wants said to a machine that has stopped reading is handed to the call
  afterwards (`call-say`). `clara.net:*patience*` for a connection that
  the machine took is the card's thread's and the function's thread's,
  which is the global value: a test sets it with SETQ and puts it back.
- At a real kernel, `SERVE=` also has QEMU hand on a port of this
  computer to the machine's port 7007 (`FORWARD=`, tools/run.sh), and
  the test's web server speaks to the machine through it when it is
  asked for `/knock/<text>`, answering with what the machine said. A
  session asks `(clara.net:serving)` after such a knock, when the
  machine's function is known to be done, and never right after a
  connection of the machine's own to itself, where the function may
  still be on its way out. `with-connection` gives the values of its
  body, and READ-LINE has two.
- IPv6 (lisp/net.lisp). An address is a number (IPv4) or a list of eight
  numbers (IPv6): compare two with EQUAL and never with `=`, look one up
  with `:test #'equal`, and ask `(consp address)` only where a packet is
  put together or taken apart. `source-for` says which address the
  machine speaks from to another, `own-p` whether an address is the
  machine's, `station-of` which card a packet goes to, each for both
  kinds. Whatever is added above the packets takes its addresses as they
  come and is tried over both. What a router said is kept with the time
  until which it holds (`hold`), and `keep-six`, from `tend`, lets go of
  it. `up` waits `*router-wait*` for a router, a second; the host tests
  set that to 0, since most of their networks have no router, and a test
  that wants to hear one calls `up-with-routers`.
- In the host tests a network speaks IPv6 when it is made with `:six t`
  (`:prefix`, `:router-time`, `:prefix-time`, `:prefix-flags`, `:names6`,
  `:six-closed`). Its web server, name servers and callers know only
  IPv4: `network-heard-six` turns what the machine sends by IPv6 into the
  same thing over IPv4 and binds `*six*`, under which
  `packet-to-machine` sends the answer back by IPv6, and a connection
  remembers that it came that way (`served-six`, `call-six`;
  `call-machine port :six t`). So a new thing that the network serves is
  written once, for IPv4, and a test only has to ask for it by an
  address of IPv6. What only IPv6 has is in `network-heard-control-six`.
- What a line of a session shows must not depend on the computer that
  the boot runs on, or on that computer's network. Who knows names by
  IPv6 did: QEMU's router names somebody only when the host has a name
  server of IPv6 itself. So the machine does not say it, and a new line
  that says something of the network is held against the container
  below before it is pushed, as every change to the network is.
- A thread that wakes by itself, the card's for one, is paid for by
  every boot: in the stress boot each call of a function in Lisp is a
  collection, in every thread, and a dozen calls four times a second in
  a thread that had nothing to do were a tenth of that boot on the Mac,
  and perhaps what made it twice as long once on a slow runner of CI
  (ROADMAP.md, "What the three cost CI", has what was measured and what
  was not). What such a thread does when there is nothing to do is
  read a word or two and go back to sleep, and it sleeps as long as it
  can: `take` wakes once a second on a machine without an address, and
  whoever gives it more to look after signals its event.
- A port that a connection spoke from rests for two minutes
  (`card-spoken`, `next-port`, `forget`): the other side remembers a
  connection that is over, by its addresses and ports, and says nothing
  to a new beginning from the same port. Picked at random with nothing
  but the connections of the moment looked at, a port came up twice in
  fifty connections to one place one time in ten, and `aarch64-network`
  failed some runs in a hundred with "does not answer at its port" where
  nothing was wrong with the other side. When a boot fails with those
  words at a server of the test's own, that is where to look first; a
  machine made to speak from one port twice shows it at once
  (`(setf (symbol-function 'clara.net::next-port) (lambda (card) 50123))`
  and two fetches).
- `card-answering`, the card's note of where the packet came from that
  it is looking at, is the card's thread's, and `answering-card` is the
  one place that reads it, once. Whatever the card's thread writes that
  another thread reads is read once into a variable: between two calls a
  thread can lose its turn, under SBCL at any instruction, and the note
  is gone.
- The made-up network keeps what the machine sends early, behind a gap,
  as a machine does (`served-early`, `call-early`): one that threw it
  away made every lost piece cost the machine a second, and hid that the
  machine's quick resending had never run.
- At a real kernel QEMU's network has a router, so every machine there
  says two lines when it comes onto the network, and the sessions and
  the manual show both. The test's web server listens at ::1 as well,
  which is where QEMU hands what the machine sends to fec0::2, and its
  name server gives a name that begins with `six.` an address of IPv6
  and no other. A computer without IPv6 to itself cannot run those boots.
- When the host tests end with SBCL's "unhandled condition in
  --disable-debugger mode" and a reader's error about a package that does
  not exist, somewhere far down lisp/host/tests.lisp, look for a
  parenthesis that was left open further up: everything after it was read
  as one form, and nothing of it was evaluated. A machine of the tests
  that is made while a thread of the machine before it still runs gets
  that thread's writes in its memory: `stop-network` ends the card's
  thread and waits for it before the next machine is made.
- A boot that fetches something: `SERVE=directory` has tools/boottest.sh
  start tools/serve.py, a web server and a name server on one free port
  of this computer, which a machine under QEMU reaches at 10.0.2.2.
  `{{port}}` in the session is that port, and `{{key}}` what `KEY=`
  says. With `CERTS=directory` the same web server is there once more,
  on another port, `{{secure}}`, where it keeps its connections closed
  with the certificates of that directory, which tools/certs.py makes;
  the machine is told to trust their root from a disk, which is how a
  user would do it (`WORK=`, a disk made of the root alone). The web
  server there is OpenSSL's, by way of Python: the one piece of the tests
  of TLS that nobody here wrote. `{{roots}}` is how many certificates
  lisp/roots.pem has, which the system says when it first reads them, and
  `{{now}}` what time it is on this computer as the boot begins, counted
  as the machine counts it: a session holds the machine's clock against
  that, to a quarter of an hour.
  tools/run.sh gives every machine a virtio network card on QEMU's
  own network (`NET=` for none), the device that makes numbers which
  nobody can guess (`RNG=` for none) and a sound card (`SOUND=` for
  none; below, under sound), so every boot of `make test` has all
  three, and the first session asks for the machine's address, a number
  and the time on all three machines. No test goes further than this
  computer. When something is tried by hand against the Internet, it is
  the project's own website and repository and nothing else: the machine
  names ClaraOS to every web server that it asks.
- A release (tools/release.py, lisp/system.lisp). `take` copies a system
  by way of a function that reads a file of it by name, from a volume or
  from a web server (`from-volume`, `take-release`): what a system is
  held against as it is taken is in `take`, once, for both. A signature
  is checked in C (kernel/ed25519.c), which holds itself against the
  examples of RFC 8032 at every boot; `python3 tools/release.py constants`
  works out the numbers that are written there. Under SBCL
  `clara.host:ed25519-sign` signs what a test then offers
  (`release`, `machine-and-releases`). No key is in the repository:
  `make test` makes one for the run, in build/.
- Where ClaraOS is published (DESIGN.md has what was decided). The system
  has the place and the public half of the key in lisp/system.lisp:
  `clara.system:*releases*`, `https://claraos.org/releases/`, and
  `clara.system:*release-key*`. The Makefile reads that half from its
  `defvar` line with sed, so the line keeps its form: `(defvar
  *release-key* "` at the start of a line, and the 64 digits. The secret
  half is Julio's alone: a file on his computer, which is never read, by
  a tool either, and the secret RELEASE_KEY of the environment
  `github-pages`. `make release KEY=<file> RELEASES=<directory>` lays
  the build out as a release, with no other key than the one whose half
  is in the source, and holds what it laid out against that half; with
  `PACKAGES=<directory>` it does the same for the packages of packages/
  (below, under packages). It is what .github/workflows/site.yml runs, and that workflow cannot be
  tried before a merge, so whatever it is to do goes into `make
  release`, which `make release-test` runs with a key of its own, at the
  beginning of `make test` (`PUBLIC=` on the command line says which
  half to go by; the environment does not). Change the step of the
  workflow itself as little as possible, and try its script by hand when
  you do: take it out of the file and run it with bash, with
  `RUNNER_TEMP`, `RELEASE_KEY` from a key made with `tools/release.py
  key`, and `PUBLIC=` on the `make release` line. A scratch directory
  `_site` in the tree is yours to take away afterwards.
- No test asks the place where ClaraOS is published, and nothing typed
  by hand does without need. lisp/host/tests.lisp sets both variables
  to NIL once it has looked at them. A session that types
  `(clara.system:upgrade)` at a machine with no other disk that holds
  another system would ask claraos.org, since QEMU's network reaches the
  Internet: such a session sets `clara.system:*releases*` first, to NIL
  (tools/upgrade.txt, tools/at-once.txt) or to the web server of the
  test, or has given the machine the test's name server, which knows no
  name outside this computer (tools/network.txt).
- A connection that is kept closed (lisp/tls.lisp; DESIGN.md has what was
  decided). The arithmetic is C, a file to each kind (kernel/sha256.c,
  hmac.c, aes.c, the X25519 of ed25519.c, bignum.c, ecdsa.c), each with a
  self-test in kmain that holds it against the examples of its standard,
  and each a function of CLARA.UNSAFE on bytes of memory (unsafe.c). The
  stand-ins in lisp/host/clara.lisp are the same arithmetic in SBCL's big
  numbers, written from the standards and not from the C; the host tests
  hold them against the same examples. After a change to the C, build
  those files for the host with a `panic` of your own and a `main` that
  reads numbers, and hold what they give against Python's big numbers on
  a few thousand cases made at random: that was done once, in /tmp, and
  found nothing, which is what it is for. A table of numbers there is not
  typed: it is worked out, by a script, and pasted.
- lisp/net.lisp knows of TLS that there are six functions for it
  (`clara.net:*secure*`), which lisp/tls.lisp hands over as it is loaded,
  after lisp/system.lisp, whose volume it reads the system's list from.
  Whoever reads the memory of a connection holds the connection's lock:
  the thread that takes what arrives moves that memory to where there is
  more room. And nothing is sent with that lock held, since sending may
  have to ask the network something that only that thread can take the
  answer to. So an error in lisp/tls.lisp is `refuse`, with the number
  that the other side is to be told, and the telling is done by whoever
  opened the connection, once the error has come that far and the lock is
  let go. Everything of a connection that is a secret is in one page
  frame, at the places that the constants name, and that page is wiped
  before it goes back. One record is taken at a time, and no more than
  the greeting needs: the keys change after some messages, and a record
  that was opened with the keys of before is a record that does not open.
- The tests of TLS (lisp/host/tests.lisp). The made-up network's web
  server keeps connections closed at the ports that `:secure` names, 443
  when nothing is said, with its own half of TLS 1.3, written there from
  the RFC on the arithmetic of host/clara.lisp. `certificate` makes a
  certificate with whatever a test wants in it or wrong with it,
  `kept-closed` gives what a fetch gives and what the machine told the
  other side, and `shown` the same for a server that shows the
  certificates it is given. What the other side can get wrong is an
  `:accident`, a keyword that `tls-greet` or `tls-answer` knows: a new
  way of being wrong gets a keyword there, and a row in one of the two
  tables with the words that the machine says and the number that it
  tells the other side. The machine trusts what `:trusted` says and
  reads no list from a disk (`trust-only`); one test reads lisp/roots.pem
  itself and has every certificate in it that signed itself in a way
  which is known here check its own signature. The device that makes
  numbers is `add-numbers`, which makes them by a rule so that a test
  that fails fails again.
- After a change to lisp/net.lisp or lisp/tls.lisp, run the host tests
  eight at once, three times over (`sbcl --script lisp/host/tests.lisp`,
  eight of them started together, and the last line of each). Under SBCL
  the threads of the machine and of the made-up network really run at
  once, and a fault that needs one of them to lose its turn at one
  particular call shows when the computer is busy and not otherwise: one
  such failed one run in two that way, and no run alone.
- lisp/roots.pem is the list that curl publishes of Mozilla's, as it is,
  so that its sum is the published one: `curl -o lisp/roots.pem
  https://curl.se/ca/cacert.pem`, and never the file that Homebrew keeps
  under /opt/homebrew/etc, to which macOS adds the certificates of the
  computer's own keychain. The handoff does not read it into memory
  (kernel/boot.c, `of_the_system`); the system reads it from its volume
  when something is first fetched by HTTPS.
- The time of day is what the firmware's clock said in the handoff
  (kernel/boot.c, `read_clock`) and the ticks since (kernel/timer.c):
  `get-universal-time`, whose answer is in `either` of the self-test,
  since a firmware need not have a clock.
- A session never says in which order the names of two systems come. A
  system is named by eight digits of its sources, which sort before
  "broken" and "other" for some builds and after them for others:
  tools/trial.txt listed `/clara` whole, and failed for every build whose
  digits began with c, d, e or f, one in four, which nobody saw until
  0.0.30 was one of them. Take the system's own name out of such a list,
  and ask for it by itself.
- A boot that does not get to its end, a machine that stands still or a
  kernel that stopped with a report, leaves build/screen-<name>.png like
  one that passed, and says where its processor was: tools/boottest.sh
  asks QEMU for the screen, and for the registers twice, before it stops
  the machine (build/monitor-<name>.log has every register). Look at
  both before anything else when a boot ran out of time and its serial
  log just ends. A screen of 640 by 480 that says `Guest has not
  initialized the display (yet)` is a machine that went down and whose
  firmware has not come to its screen; a processor that is not in the
  kernel's image, whose place the boot report gives (`kernel image at`),
  nor in the code that the world made (0x200000000000 and up), is in the
  firmware. Three times an x86_64 machine that was told to start again
  said so and was never heard from again, and those two things are what
  said why (ROADMAP.md, "A page frame that the firmware reads").
- RAM keeps what it holds when a machine is started again, and the
  firmware starts in it. OVMF of EDK2's release of November 2025, which
  is Ubuntu 26.04's and so CI's, takes the page frame at 0x812000 for a
  map of the memory when two words there are of the right shape, and
  stood still for good when they were the Lisp heap's.
  kernel/arch/x86_64/arch.c names the frame (`arch_kept_frame`), and
  kernel/pmm.c takes it out of use and clears it where the firmware's
  map hands it over: the boot report then has a line `page frames: the
  one at ... is kept out of use`, and a machine with another firmware has
  no such line. Whatever is put low in memory by hand, a table, a
  buffer at an address of the kernel's own choosing, is looked for
  there first when a machine does not come back. Two things that found
  it: QEMU writes words into a machine's memory at every reset
  (`-device loader,addr=0x812000,data=0x20000017a5d0,data-len=8`, and a
  second one for 0x812008 with 0x268), which shows a firmware's fault
  without a system; and `pmemsave 0 0x20000000 "file"` in QEMU's monitor
  saves the memory of a machine that stands still, the name in quotes.
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
  ever deleted there. The disk is made of `SIZE` MiB, 1024 unless that
  says otherwise (`tools/mkdisk.py --size`, a volume of the kind 32 with
  the clusters that the overview's table gives such a size, eight sectors
  from 260 MiB on); one that is smaller is made again that large first,
  with its files (`tools/mkdisk.py --grow`, which reads the new disk back
  and holds it against the old one), and the smaller one is put aside
  too (`-small`). `SIZE=` leaves a disk as it is. tools/mkdisk.py holds
  nothing of a volume in memory but its tables and its files, and reads a
  disk in place, so a disk that is mostly room costs what its files do;
  the disks of the tests are the same bytes as before, which
  `cmp` says of all nine kinds after a change there. No boot of `make
  test` goes through tools/run.sh's own disk, so after a
  change it is run by hand, in a worktree of its own: twice with the same
  build, once with another (a line added to a file of lisp/ and taken out
  again), with `FRESH=1`, with a disk of the old kind, and with a small
  one (`SIZE=` makes one), which has to come back larger with every file.
  Two boots of `make test` start from disks that `--grow` made of the
  first sessions' (300 MiB, `GROWN` in the Makefile): the resumed one on
  AArch64 and the one with UTM's devices on x86_64.
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
  `:unfinished` function, as lisp/emma.lisp does, and nothing else is
  asked before a shutdown.
- A session can go across a start: a line `^R` after the form that starts
  the machine again, and what follows is typed at the kernel that comes up
  then. What the kernel says between "clara: starting the machine again"
  and its next invitation is no part of the transcript. A session that
  ends with the machine turning itself off is given
  `MARKER='^clara: turning the machine off'`: nothing is typed to end it,
  it may end with a `^M` line, the machine has to be gone by itself ten
  seconds later, and there is no screen to save. Such a machine can say
  its last line and be gone between two looks of tools/boottest.sh at
  its log, so the script looks once more when the machine is gone
  (0.0.61: x86_64-power failed that way once, with the line in its log). To press the power
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
- The order of that list (Julio's issue #42) is the order of
  `*applications*` and of `*commands*`, which `clara.windows:move-up` and
  `move-down` change a place at a time, each by making a new list
  (`exchanged`) and never by changing the one that is there: the tests
  hand in lists of their own. Nothing leans on where an application
  stands. START launches the one with the lowest `number`
  (`first-defined`), which is the REPL, and not the first of the list. A
  list that is open while its order changes is painted again where it is
  (`rearranged`); it is not shut, as it is by what makes it longer or
  shorter. `*arranged*` says that the order is the user's, which it is
  once a line has moved. `clara.windows::arrangement` gives such an order
  to lisp/system.lisp, which writes it into the account of a world that
  leaves, `(:applications "REPL" ...)` and `(:commands ...)`, and
  `clara.windows::arrange` puts it back in the world that is made again
  (`in-order`: the account's names in their order, and what it does not
  name behind the name that it was defined after). Those two are the
  system's, like the account, and are not exported. `new-desk` of the
  tests makes the order nobody's again. A session that moves a line does
  it where no later line of the session clicks on the list by its place:
  tools/upgrade.txt does, before and after its upgrade.
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
- The object system (lisp/clos.lisp; DESIGN.md has what was decided) is
  the second file that SBCL cannot load as it stands: it gives Common
  Lisp's own names their meaning, DEFCLASS and the rest. Its first four
  forms are what the host tests take it by: `(in-package "COMMON-LISP")`,
  the `(export '(...))` of those names, the DEFPACKAGE of CLARA.CLOS and
  the IN-PACKAGE. Under SBCL the tests read it a form at a time into
  CLARA.CLOS with every exported name hidden behind a symbol of that
  package (`load-objects`, lisp/host/tests.lisp). So a name goes into
  that list only when the language did not have it before: one that it
  had, and that the file calls, would be a symbol there that nothing
  defines, and the tests say so. The list is also what site/build.py
  reads for the manual's lists of names. Everything else in the file is
  the subset, as in any file of the world, and its own names are internal
  to CLARA.CLOS. What it asks of the kernel is seven functions at its top,
  under `#+clara`, the only place where it names a symbol of
  lisp/boot.lisp's or the substrate's (`cl::%type-of`, `cl::%structure`,
  `cl::%condition`, `cl::%setf-name`, `cl::%printed`); under SBCL
  lisp/host/objects.lisp defines the seven, from what SBCL knows.
- SBCL's own object system is the second opinion on that file, the piece
  of its tests that nobody here wrote. tools/objects.txt is a transcript
  that is answered three times: by lisp/clos.lisp under SBCL, to the
  letter; by SBCL's own, which has to fail where the answer is an error
  and to go well where the answer shows a `#<`, and to give the same text
  otherwise; and by a kernel, x86_64-objects of `make test`. So a form
  there shows nothing that the two systems put differently (the class of
  5, the text of an error of the substrate's), and every error in it is
  one that lisp/clos.lisp words itself. What only a kernel can answer is
  in tools/session.txt, tools/resumed.txt and the manual. A new thing in
  the file gets its forms there: type the form and what should come back,
  and the host tests say what each system answers when that is not it.
  Besides, classes, methods and redefinitions that chance picks are given
  to both systems (`both`, `chance`): a change to the precedence list, to
  which methods fit and in which order, or to how an instance follows its
  class is tried by those. Two things that they taught: SBCL's SORT uses
  up the list that it is given, which ClaraOS's does not, so a list that
  is kept gets a COPY-LIST before it is sorted; and SBCL keeps a class
  that it refused among the ones below the classes it was to be a kind
  of, and fails when one of those is defined again, which is why the
  classes that are defined again there are a family that is never
  refused.
- The directives of FORMAT (lisp/format.lisp, the package CLARA.FORMAT,
  Julio's issues #56 and #81; DESIGN.md has what was decided). The
  substrate does five, `~A ~S ~D ~%` and `~~` with nothing between the
  tilde and the character (`format` in builtin.c), and `%FORMAT` gives a
  character in place of a string when a control string has anything
  else: FORMAT in lisp/boot.lisp then asks the function that the file
  handed over (`clara:provide-format`, `cl::%formatter`), which does the
  whole control string, the five too. So the five are in two places, and
  a change to what one of them writes is a change to both: the same
  argument has to come to the same text whether its control string has a
  sixth directive or not. What a condition says takes the same way from
  C (`condition_of`, `format_in_lisp`), which calls FORMAT itself. A
  directive is a clause of `obey`; one that has an end is also in the
  strings of letters in `read-pieces` and `read-clauses`. An error there
  is worded with the five and nothing else: the function must not need
  itself to say what is wrong. Whatever leaves in the middle, a `~^`, goes
  by THROW, so what a directive has put in the job for a while, another
  stream, another list of arguments, it puts back after its CATCH or in
  an UNWIND-PROTECT. boot.lisp, the compiler, lisp/native.lisp, the
  processors' files and lisp/clos.lisp are loaded before the file, so a
  control string that runs while those load keeps to the five; any other
  file may use them all.
- The tests of FORMAT. SBCL's own FORMAT is the second opinion, as its
  object system is for lisp/clos.lisp. tools/format.txt is a transcript
  that is answered three times: by the file under SBCL, to the letter;
  by SBCL's FORMAT, which has to fail where the answer is an error and
  to give the same text otherwise; and by a kernel, aarch64-format of
  `make test`. Its forms are `(format nil ...)` and nothing that writes
  to a stream, so every answer is a string or an error that the file
  words itself. A new directive, or another way for one to be wrong,
  gets its forms there: type the form and what should come back, and the
  host tests say what each side answers when that is not it. The control
  strings that chance writes (`any-directive` and what it calls in
  lisp/host/tests.lisp) are given to both sides with arguments that fit:
  a new directive gets a piece there, with exactly the arguments that it
  takes, since a loop that takes nothing goes round for good on both
  sides and the run then ends at its two minutes. No piece is a `~W`:
  SBCL refuses one in a control string that has a `~:;` anywhere between
  a `~<` and its `~>`. Where the file is not SBCL on purpose it is asked
  alone, in the checks under that heading. What only a kernel has is in
  tools/session.txt, on all three machines: a condition's text by way of
  C, and a `~&` on a stream that is in the middle of a line. And
  `(cl::%self-test)` is typed in a world that has the file
  (tools/resumed.txt), where the texts of `evaluations` were first run
  without it: a text there about FORMAT gives one answer both times, so
  it keeps to the five, or to an error that both word alike.
- An instance follows its class at two places and no others: a look at a
  slot (`current`) and a call of a generic function with it
  (`class-in-call`, from `dispatch` and `applicable`). CLASS-OF changes
  nothing. A class works out what it keeps when `*epoch*` has moved on
  (`fresh`), which only a class that is defined again moves; whatever
  reads the precedence list, the slots or the layout of a class has it
  from `fresh`. A generic function drops what it keeps when its methods
  change (`tune`) and when the number has moved.
- How an instance is written (kernel/lisp/print.c, builtin.c). The printer
  goes through an object twice and cannot call Lisp in between, so the
  functions that make a string for Lisp go through it three times when
  it comes to a structure whose type's name has `cl::%printed` on its
  property list: once to note those structures, then
  `cl::%object-text` is asked for each, and twice with the texts in place
  (`ask_for_texts`). What is on the value stack there stays on it while
  Lisp runs. `lisp_print` and `lisp_princ` ask nobody and write such a
  structure as its type between `#<` and `>`: that is what an error of
  the substrate's shows, and what the texts of the self-test see. A text
  that gives `cl::%object-text` a function puts back what was there, and
  `#'not` when nothing was, never a function of its own: such a function
  holds a symbol of the text's package, the package stayed in the heap
  with all that the texts had defined until lisp/clos.lisp was loaded,
  and every collection of the stress boot up to there went through it.
  (What showed it: with lisp/clos.lisp left out of `world`, the kernel
  stops with "48 of its functions and macros are still the evaluator's to
  walk".)
- A function that SETF writes with, `(setf name)`, lives in a symbol that
  the name keeps under `cl::%setf` (`%setf-name`, lisp/boot.lisp). `%setf`
  calls that symbol when it has a function as the form is expanded, and
  has `%setf-function` look for it when the form runs otherwise, with
  the error that an unknown place always had. DEFSETF comes first: a
  reader with a writer of that kind never gets as far.
- SYMBOL-MACROLET is in the evaluator (`sf_symbol_macrolet`, a frame of
  the kind SYMBOL_MACROS) and in the compiler (`c-symbol-macrolet`, a
  variable that is `(:symbol-macro . form)`). `lookup_variable` says that
  a name stands for a form by the lowest bit of the address it returns,
  and not through a variable of its caller's: `eval_car` has a frame on
  the stack for every form inside a form, and with one more word in it
  a function called itself 3110 deep where it had 3456. Look at that
  line of the boot report after any change there.
- What a change costs the boot that collects at every safe point is not
  seen where the Mac runs the machine itself: time a collection where it
  is emulated, `(time (dotimes (i 500) (cl::%collect)))` in a session
  with `NO_HVF=1`, on the kernel before and the kernel after, one boot
  after the other. A collection once got a seventh slower with nothing
  in heap.c changed: code that was added elsewhere had moved the
  collector's loop onto another page of the kernel than the function it
  called for every word, and QEMU's emulator pays for a call across a
  page (`llvm-nm build/esp/EFI/BOOT/BOOTAA64.EFI` has the addresses).
  Those calls are written into the loops since (`words_of`, `reach`,
  heap.c). When that boot is slower and the heap is not that much
  larger, look there before anywhere else.
- The other files in lisp/ are the world, and each has to load under
  SBCL as it stands: the subset of Common Lisp that the evaluator has,
  no name of Common Lisp's given a new meaning (LISTEN is one), and the
  substrate only through CLARA and CLARA.UNSAFE. The kernel loads them
  in the order of `world` in lisp.c (the compiler, then native and the file
  of the machine's own processor, arm64.lisp or x86-64.lisp, whose name
  is the machine's in `*features*`, then clos, which is the exception
  above, then format, and then the console, draw, pci,
  virtio, usb, input, disk, fat, type, random, net, hda, sound, syntax, the
  listener, windows, terminal, system, tls and parker), and
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
  REPL's window, are what the front page shows. The console does not draw with this file, and writes over what is
  shown.
- Fonts of outlines (lisp/type.lisp, the package CLARA.TYPE; DESIGN.md has
  what was decided). A font is a TrueType file at a size. Every byte of a
  file is asked for by its place, through `u8` and `u16`, which hold the
  place against the file's length: nothing there reads memory by an
  address of its own making, since a file is somebody else's. A file that
  is no font is refused when a font is first made of it (`read-tables`
  holds every table against the file), and a glyph that cannot be read
  shows nothing and is no error (`shape`), so that a window keeps its
  other letters. Places are whole numbers of 256ths of a pixel; `nearest`
  rounds a half upwards, and the tests round the same way (`nearest-of`).
  Where a piece of an outline leaves a row or a pixel (`cover`, `across`)
  is worked out from the piece's two ends each time and never from the
  cut before it: that is what makes the parts add up to the whole, and a
  sum that is off by one is a streak across the row. A change to how a
  place is rounded, or to how fine a curve is cut (the 16 in `bend`), is
  a change to `at-size` and `pieces-of` of the tests in the same commit.
  The loops there call nothing but the twenty functions that have an
  instruction of their own (`+`, `-`, `*`, the comparisons, `svref`):
  `abs`, `min`, `max` and `zerop` are calls, and are written out.
- START is called at every boot, by `lisp_main`, before the window
  manager's RESUME, which writes its letters in a font: it forgets where
  the files were. A font that came back with a world that was saved finds
  its file again when it is next used (`live`), and makes its glyphs
  again. What is read and made for a font is kept beside it and not in it
  (`*made*`, a `kept` for each font that was used): a structure prints
  with all that it holds, and a font that held the pictures of its glyphs
  filled the REPL's window when it was the value of a form. The
  fonts that come with the system are `fonts/*.ttf`, which the
  Makefile puts into the system's directory (`FONTS`, and so into
  `SYSTEM_SRCS`) and the handoff reads into memory with the system's Lisp
  files; `clara.unsafe:system-file` gives the place of one. A font that
  is added gets its license beside it, its family in
  `clara.type::*families*`, and its row in `*font-facts*` of
  lisp/host/tests.lisp, which fail when a file of fonts/ has none.
- The tests of the fonts (lisp/host/tests.lisp, "Fonts of outlines").
  What a shape covers of a pixel is worked out there with fractions
  (`covered-of`, `shade-of`), and `furthest` says by how many shades a
  picture is off: 0 for straight edges on whole pixels, 1 at the most
  otherwise. `font-file` puts a font file together, with `plain-glyph`
  and `joined-glyph` for its glyphs, and with options for what is wrong
  with it; `*made-outlines*` says what each glyph of the tests' own font
  is, and a glyph that is added there is added to both lists.
  `put-watched` puts a file among the system's with a device behind its
  last byte that fails the run when it is read: a test of a file that is
  cut short uses it. `*font-facts*` is what FreeType says of each file of
  fonts/, units, lines and three sums over every character, advance and
  point; `label-rule` is what a string of the window manager's shows, in
  either kind of letters, and `new-desk :letters t` a desk whose letters
  are outlines.
- tools/fontcheck.c is FreeType's word on a font file, the one piece of
  those tests that nobody here wrote. It is built by hand, on a computer
  that has FreeType, and is no part of `make test`:
  `cc -o build/fontcheck tools/fontcheck.c -I/opt/homebrew/opt/freetype/include/freetype2 -L/opt/homebrew/opt/freetype/lib -lfreetype`.
  `build/fontcheck facts fonts/*.ttf` prints the rows of `*font-facts*`.
  After a change to the reader, hold it against FreeType on fonts that
  have what the Go fonts lack, glyphs of parts above all: `fontcheck
  points <file>` prints a sum for each glyph, the same sums are a dozen
  lines of Lisp over `clara.type::outline`, and macOS has such fonts in
  /System/Library/Fonts/Supplemental (Arial, Times New Roman). That is how
  two rules were found that no test of ours had asked for: where a
  glyph's left edge lies, and which part a glyph of parts takes its place
  from. After a change to the pictures, `fontcheck shades` prints
  FreeType's, to hold these against pixel by pixel; ROADMAP.md has the
  figures to expect. Finer pieces of a curve make the difference from
  FreeType larger, not smaller: FreeType's are the coarser.
- `clara.unsafe:blend-shades-32` (unsafe.c) lays a colour over pixels by
  their shades. The numbers in its texts of the self-test, and in the host
  test that draws on a screen of five, six and five bits, were worked out
  by a script from the rule, each part to the nearest: they are the same
  numbers in both places, so the function in C and its stand-in in
  lisp/host/clara.lisp are held to one answer. tools/session.txt counts
  the pixels of two letters, `(130 156)`: a change to the pictures that
  is meant changes that line on all three machines, and the same form
  under SBCL has to give the same.
- Sound (lisp/sound.lisp, the package CLARA.SOUND; DESIGN.md has what was
  decided). What a program asks for is a voice, which `begin` adds to the
  card's list with the card's lock held. Everything else is the card's
  thread's (`serve`, `turn`), the only one that speaks to the device once
  START has opened it: a request and its answer, a period handed over, a
  period taken back. Time is frames and never the clock: a voice is at a
  frame, and `mix-period` works out the next 480, so a machine plays the
  same numbers however late the thread comes to it. The boots lean on
  that, so nothing there may go by when something happens: no fading by
  the clock, no voice that begins "now". The loops that go round once a
  frame (`render`, `render-noise`, `sound-file`) call nothing but what has
  an instruction of its own, like the fonts'. And a card with nothing to
  play costs nothing: its thread waits without a time, since every boot
  pays for a thread that wakes by itself.
- A change to what a frame comes to, a shape, the way up and down, how
  loud, how a file's pace is brought to the card's, is a change to the
  rule of the tests in the same commit (`up-at`, `wave-at`, `voice-at`,
  `burst` in lisp/host/tests.lisp): the rule works every frame out by
  itself, in fractions, and is what DESIGN.md says, written down a second
  time. It also changes the lines that begin with `^H` in
  tools/session.txt and tools/resumed.txt, and the same lines in the host
  tests, where `said-of` says of numbers what tools/heard.py says of a
  file: the three are held to one answer. Take the new lines from a boot
  (`python3 -I tools/heard.py build/sound-aarch64.wav`), and look whether
  they are what the forms should give before writing them down: a stretch
  turns once for every time its wave goes round, so a tone turns its
  pitch times its length.
- The card of the tests (`add-sound`, `new-sound`) keeps what it is given
  to play (`played`; `sounded` waits for the machine to be quiet first).
  It fails the run when the driver asks out of the order that the
  specification gives, tells the stream what it never offered, or hands
  it more periods than it said it would. `:paced` has it play a period
  when a test says so (`sound-on`, `play-out`), which is how something is
  made to happen at a frame that the test knows: the driver has mixed
  four periods, no more and no fewer, when the card has four. `:refuse`,
  `:silent`, `:mute`, `:stuck`, `:verdict` and `:streams` are the ways for
  a card to be wrong, or another card. Several things whose numbers a
  test wants are played inside `together`: calls that are apart begin
  when the card's thread gets to each. `stop-sound` ends the card's
  thread before the next machine is made, as `stop-network` does, and a
  test that makes a machine by hand after a sound waits for the card to
  be stopped first (`vdev-stage`), or that thread asks a machine that is
  gone, and says so in the middle of the output. `clara.sound::*linger*`
  is 20 there, and `*patience*` is set and not bound where the card's
  thread is to see it.
- At a real kernel tools/boottest.sh gives every machine a card whose
  sound QEMU writes into build/sound-<name>.wav (`SOUND=capture`, which
  `make test` exports, so that a `SOUND=` of the environment stays out of
  it; `SOUND= tools/boottest.sh` is a machine with no card). The file has
  the frames that the machine sent and no others: nothing for the time in
  which nothing is played, and no gap where the machine was late. A
  session says what is to be heard in lines that begin with `^H`, one for
  every stretch of sound as tools/heard.py says it, and every stretch
  that was played has to be among them. So a session waits for the end of
  each sound before the next (`clara.sound:wait`), since two that overlap
  begin at a moment that no session knows; it waits before it ends, or the
  machine is gone before the last period is; and it does not stop a sound
  that is playing, whose length would be the moment's. What the manual
  shows of sound is typed too, and only its answers are held.
- Nobody hears any of this. No test plays through the computer's own
  sound, and a check by hand that does,
  `SOUND="-audiodev coreaudio,id=sound -device virtio-sound-pci,audiodev=sound,streams=1" tools/boottest.sh aarch64`,
  sets `clara.sound:*volume*` to 0 in the first form of its session: the
  computer is Julio's, and it may be the middle of his night. Such a boot
  says whether a second of sound takes a second there and whether the
  card runs dry while the machine is busy, and nothing about how it
  sounds, which is his to say.
- What QEMU's card does, found by trying it: it is there from QEMU 8.2
  on (CI's is 10.2); with `streams=1` it has the one stream that plays,
  and QEMU does not complain of a microphone that the host cannot give;
  a period comes back when QEMU has taken it, which is before it is
  heard; the count of bytes still to play that comes back with it is 0
  on 8.2; and the lengths in the head of the file that QEMU writes are
  only filled in when QEMU ends by itself, so tools/heard.py goes by the
  length of the file.
- USB (lisp/usb.lisp; DESIGN.md has what was decided). Everything that
  speaks to a controller runs in the controller's thread, or in START
  before that thread exists: `control`, `listen-at`, a command, a look at
  a port. Whoever takes devices is called from there (`*arrival*`,
  `*departure*`) and may ask a device things; what it does with a report
  it does in a thread of its own, since a report is handed over in the
  controller's thread, which has other devices to hear. A ring is
  written with the lap's bit last, by `ring-put`, and nothing else
  writes one. What a command is told goes through `fill-input` and
  `fill-endpoint`, which write every word of the contexts that the flags
  name: the page is one for all commands, and the controller reads no
  context that the flags do not name. A function there cannot be called
  LISTEN, nor a part of a
  card STREAM: both are Common Lisp's, and SBCL refuses the file.
- The controller of the tests (`add-xhci`, `new-usb` in
  lisp/host/tests.lisp) is the other side of the rings. It fails the run
  when the driver gives a command to a controller that it did not start,
  names memory that is not its own, tells it of a device or an endpoint
  that cannot be, switches a port off by writing its register back as it
  read it, or leaves the page of a device that is gone in the table. It
  speaks of a port when a change there is news, as a real one does: a
  change that the driver left standing is spoken of once, and the next
  device that is plugged in is never heard of. It
  looks at an endpoint's ring when the doorbell was rung and not before,
  as a real one does: one that looked whenever a test had a report read
  an entry that the driver was in the middle of writing, one run in
  three. Its devices (`usb-keyboard`, `usb-mouse`, `usb-tablet`,
  `make-udev`) answer requests with what they were made with, and
  `:refuses`, `:mute`, and a controller's `:stuck`, `:silent`, `:mute`,
  `:wide`, `:scratch` are the ways for either to be wrong, or another
  kind. `usb-report` is something typed or moved, `usb-plug` a device
  put into a port or, with NIL, pulled out. `xhc-history` is what the
  driver had the controller do, in order, and a test of what a start
  comes to holds it to the whole list. A name of the tests may be taken
  already: `utf-16` was, and a second definition failed fifteen checks
  two thousand lines further down.
- Keyboards and pointers of USB (lisp/input.lisp). What a device's
  reports are made of is read from its description (`read-fields`), and
  a report is gone through by those fields (`usb-report`); nothing there
  knows the report that keyboards mostly have. `fields-of` in the tests
  says what a description comes to, and a new kind of item or a device
  that describes itself in another way gets a line there. A key is a
  number of the page of keys, which `*usage-keys*` turns into the key
  that the rest of the file knows: a key that is added to
  `key-character` is added to that table too. What QEMU's monitor cannot
  do is tried by hand after a change there: a tablet's place, by QEMU's
  other socket (`-qmp unix:...`, the command `input-send-event` with
  events of the type `abs`), and a device that is plugged in while the
  machine runs (`^M device_add usb-kbd,bus=usb-bus.0,id=more`, `^M
  device_del more`), on a machine with fewer than three devices at its
  controller, since QEMU puts the fourth behind a hub of its own.
- Intel's sound card (lisp/hda.lisp; DESIGN.md has what was decided). A
  register of the controller is read and written as what it is, one, two
  or four bytes: QEMU's knows a register by where it begins, and gives
  nothing for the middle of one. The word of switches of a stream holds
  what happened in its top byte, where a bit is taken back by writing
  it: what is written there is the switches and those bits, on purpose.
  The codec is asked through `ask`, which takes the answer's flag back
  each time. Whatever changes when a period is written or which period
  is made silent (`advance`, `next-period`, `hand-over`, `+margin+`,
  `+ahead+`) is a change to what a machine sounds like when it is busy,
  and the test of the driver that comes too late says what: its gaps are
  counted in periods.
- The card of the tests for it (`add-intel`, `new-intel`) is a
  controller and codecs (`plain-codec`, `long-codec`, `modem-codec`, each
  a list of parts as they say what they are). It plays a period only
  when a test says so (`intel-on`; `intel-sounded` plays until the
  machine has nothing more, giving the driver time after each period;
  `intel-at-once` plays several before the driver can do anything), and
  what it has played is numbers, held to the same rule as virtio's
  card's (`burst`, `same-sound`), after two periods of nothing. It fails
  the run when a stream is started before every part on the way has
  been told what it needs to be told, when a register is taken for
  more or fewer bytes than it has, and when a codec is spoken to through
  a controller that the driver has not taken through its reset: it
  begins as a firmware leaves one. Where QEMU's card is kinder than a
  real one, this one is the real one: a stream that was not reset goes on
  where it stopped, and the card says that a period is done only when the
  flag of the last one was taken back.
- A file of the world calls nothing that the machine has not. Under SBCL
  everything of Common Lisp is there, so a function that the kernel's
  Lisp lacks passes every host test and fails on the machine when it is
  first called, which on a way that no boot takes is never: CEILING was
  one, in lisp/usb.lisp. The host tests read every file of lisp/ as text
  and hold what stands first in a pair of parentheses against what
  lisp/boot.lisp, lisp/clos.lisp and the substrate define (`called-names`,
  near the top of lisp/host/tests.lisp). A variable with the name of a
  function of Common Lisp's that stands first in its binding looks like a
  call there: the few that the files bind and never call are in
  `*bound-and-never-called*`, and a new one is either added there or
  given another name.
- A machine as UTM gives one: `UTM=1` for tools/run.sh and
  tools/boottest.sh, which is three boots of `make test` (x86_64-utm,
  aarch64-utm, aarch64-gic2-utm, tools/utm.txt), each from the world that
  its machine's first session saved, so in the window manager. What
  Intel's card played is held to what the one sound of that session is
  like, in a line `^H about ...`: frame for frame is more than QEMU
  gives for that card, which drops what it cannot keep up with. To hear
  what a change does to such a machine that is busy, play a tone and
  keep the machine in one long step, `(clara.unsafe:sha-512 memory
  bytes)` over tens of megabytes, and read tools/heard.py's lines for the
  file: a gap, and all of the tone around it.
- Windows (lisp/windows.lisp, the package CLARA.WINDOWS). Nothing there
  draws on the screen: what changes what the screen should show calls
  `damaged` with the rectangle, and `settle` puts the dirty rectangles
  together again on `*back*` and shows them (`compose`), all with `*lock*`
  held. A window's surface is its thread's to draw on; this file only
  copies from it. What a window is told (its KEY, POINTER, DRAG and CLOSE
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
  REPL, the listener in a window (`clara.terminal:repl`), is its
  application, the first that is defined, which START launches. That is
  the application's name, in the launcher's list, on its window and for
  its thread (Julio's issue #40; it was the Listener until 0.0.49). What
  reads, evaluates and prints there and at the serial port is still the
  listener (lisp/listener.lisp, the package CLARA.LISTENER), and the
  thread at the serial port is still named so. Ctrl-C there is
  `clara:interrupt-thread`. A terminal keeps what its rows say (issue
  #46): `line` is the row that is being written, `kept` a ring of the
  finished ones (`keep-row`, `kept-row`), and `back` how many rows before
  the last ones the window shows, which Page Up and Page Down change in
  the thread of the keyboard (`scroll`, with the terminal's lock). Whatever
  draws a character checks `back` first, and whatever changes what a row
  says changes `line` as well as the pixels: the tests hold the pixels
  against the rows after going back and forth (`rows-show-p`). What
  the bar, the list and the titles say goes through `label`, which writes
  halfway up a strip in the window manager's letters: the font that
  `clara.windows:*font*` names, which START makes (`*letters*`), or the
  console's when that is NIL or the font cannot be had. The strips keep
  their heights, so a rule of the tests for a new piece of text takes its
  place from `label-rule`.
- Parentheses (lisp/syntax.lisp, the package CLARA.SYNTAX, Julio's issue
  #47; DESIGN.md has what was decided). `scan` goes through a text the way
  kernel/lisp/read.c reads one, so what the reader takes for a string, a
  comment or a name is changed in both, and the tests' second opinion is
  SBCL's reader behind a table of their own (`read-parentheses`): a new
  case goes into the list of texts there that were written to be hard. A
  state is never changed, since whoever keeps one keeps it for a text
  that has not changed: Emma's `states`, beside `known`, the lines that
  they are of, and a terminal's `start`. In a terminal a row's colours
  are `tints` and `tinted`, kept in step with `line` and `kept` wherever
  those change (`keep-row`, `old-row`, CLEAR, the rings as they grow);
  `put` with no ink takes the colours of the cells that it writes; and
  whatever draws a row from what it says draws its colours (`repaint`,
  `draw-cell`). The hint is drawn and taken away with the cursor,
  `show-cursor` and `hide-cursor`, around everything that draws. `echo`
  is how a line that is read there is echoed, called by
  `clara.console:read-edited-line`, and what it remembers of where a
  character was drawn is a row by its number (`count`), not by its place
  in the window. The listener binds `clara.listener:*begun*` around the
  line that it reads; a line that is read with the variable NIL is some
  program's, begins a text of its own and is not remembered. In Emma,
  `paint` works out the cells of the rows in sight that are not ink on
  paper, and `shown` holds a row's text with them, so a row whose colours
  alone have changed is drawn again. In the tests the colours are written
  out (`*levels*`, `+stray+`, `+hint+`), `row-tinted-p` and the fourth
  argument of `wrong-cells` name the cells that are in them, and
  `editor-tints` asks SBCL's reader about the editor's whole text: a text
  that a test types into an editor has to be Lisp as far as it goes, or
  the run fails with that. A session holds a row against letters that it
  draws beside it (`shows`, with the cells in other colours after the
  text), and sees the hint by typing with `^M sendkey` and no Enter.
- Highlighting, cutting, copying and pasting (Julio's issue #48; DESIGN.md
  has what was decided). What was cut or copied is
  `clara.windows:clipboard`, one string for all the windows, which a
  program sets with SETF. Nothing else of it is the window manager's but
  the moves of the pointer: a window that was opened with `:drag` is told
  where the pointer is while the left button is down that went down on
  its inside (`*held*`, and `+slack+` for a hand that is not still), in
  the thread of the mouse, and a window with `:events t :drag t` keeps
  `(:drag x y buttons)`, one for all the moves that nobody took
  (`post-drag`). A window that did not ask is told nothing new. A program
  highlights for itself. In a terminal a place is `(row . column)`, the
  row by its number like the cells of a line that is read (`row-number`),
  `marked` is two places in the order of the text, and whatever draws a
  cell asks `ground` what the cell stands on: a new way of drawing there
  goes through `draw-cell` or `draw-row`, or does what `relight` does for
  `put`, or what is highlighted is drawn over on paper. `joined` is the
  third ring, kept in step with `kept` and `tinted` wherever those change
  (`keep-row`, `old-row`, CLEAR, the rings as they grow): it says that a
  row's line went on in the next, which `new-row` is told by whoever
  starts a row for a character that had no room, and what is copied goes
  by it. `pointed` and `dragged` run in the thread of the mouse and draw,
  with the terminal's lock, as `scroll` does in the keyboard's. What
  Ctrl-V types goes to `keys` whole, past `+keys-limit+`, without the
  characters that are no text. In Emma what is highlighted is the text
  from `mark` to the cursor (`marked`), `paint` adds its cells
  (`lit-cells`), and whatever changes the text, or moves the cursor by a
  key, sets `mark` to NIL, or the mark is a place that the text no longer
  has: `take-marked`, `read-in`, the keys of `moving-p`. `pressed` is where
  the button went down, and any key takes it away, for the same reason.
  In the tests `+highlight+` is the ground, `lit-p` a row of the terminal
  with cells on it, `editor-tints` says what is highlighted by counting
  characters through the whole text, and `ref-point`, `ref-drag` and
  `ref-key` are the pointer and the keys of the second editor: a key that
  has to do with what is highlighted is taught to `ref-key` and to the
  walk. An expectation there that names a row with the cursor in it ends
  before the cursor's cell, as for the colours. A session presses and
  moves QEMU's mouse a step at a time and holds a row against `lit`
  (tools/session.txt), which draws the same letters with some of them on
  the highlight's ground. It waits for every row that it looks at
  (`until`, with all the rows of one look in its test), also where the
  row should be as it was: the window's own thread may be drawing the
  row at that moment, text first and colours after, and a slower machine
  shows it. The first run of CI for #48 failed on a row that was read
  once, right after a button had come up.
- History (Julio's issue #49; DESIGN.md has what was decided). The lines
  that a listener read in a terminal are `clara.terminal::*history*`, the
  newest first, one list for all the windows, which a program reads and
  sets with `clara.terminal:history`, a copy both ways. Nothing changes
  that list where it is: `remember` and `set-history` make another one,
  with `*history-lock*` held, since a window that goes through the lines
  holds on to the list that it found (`older` in `read-text-line`, taken
  at the first arrow up, and `newer` for the lines that the arrows have
  left, as they were left). A line is remembered in `read-text-line` and
  nowhere else, and only a listener's, one that was read while
  `clara.listener:*begun*` was a string. `clara.console:read-edited-line`
  knows nothing of any of that: it asks RECALL about a key that types no
  character, and a line that RECALL gives is typed through the two
  functions that every key goes through, `lose` and `gain`. Whatever
  changes a line there goes through those two, or a terminal's `cells`
  no longer say where the line was drawn. In the tests a listener's line
  that an earlier test typed is among the lines, so a test that looks at
  them sets them first, and the section ends with none; that an arrow
  did nothing is seen by typing a character after it, since a row that
  shows what it showed says nothing of whether the key was read; and the
  walk of keys holds the arrows against a row of slots, which is taught
  whatever the arrows learn. A session presses them with `^M sendkey up`
  and waits for a row that differs from what the row showed before. The
  lines of a session's world are the ones that it typed into a REPL's
  window, by `^T` or by `sendkey` and `ret`: tools/session.txt asks for
  them once and tools/resumed.txt again, in the world that came back, so
  a line that is typed into such a window before either changes both
  lists.
- Text in cells, and the letters of a window (Julio's issue #51; DESIGN.md
  has what was decided). `clara.draw:draw-cells`, `cell-width` and
  `cell-height` are text a character to the cell: in the console's letters
  without a font, and through lisp/type.lisp with one (`draw-cells` and
  `cell-width` there, which `provide-fonts` hands over with the other three
  functions). A cell of a font is as wide as the widest of the characters
  from the space to the tilde moves on, which is kept beside the font
  (`kept-wide`) and goes when the fonts let go of their glyphs. A character
  is cut at its cell: `draw-cells` draws a glyph whose picture lies within
  its cell as it is, and any other under `with-clip`, and the two ways have
  to come to the same pixels, since a window draws now a row and now one
  cell of it. The terminal, Emma, Jaid and Parker each keep `font`, `wide`
  and `high` in their structure from when the window opens, and draw every
  string with `clara.draw:draw-cells` and that font: none of the four names
  `clara.font:+width+` or `clara.draw:draw-text` any more, and a new piece
  of drawing there asks the structure how large a cell is. A cursor that is
  taken away in a terminal draws its cell again from what the row says
  (`hide-cursor`), because the bar lies over the foot of a letter that has
  one. Which font is `clara.windows:*text-font*`, which
  `clara.windows:text-font` reads as a window opens, in the thread that
  opens it, and `:font` for one window, where NIL is the console's letters;
  `font-said` is what makes a font of that variable and of `*font*`. As the
  system comes it is NIL, so every session and the picture on the website
  are in the console's letters.
- In the tests `*cell-font*` is the font that the windows of a test are
  written in, and whatever holds cells against what they should show goes by
  it (`cell-size`, `cell-pixel`, `cell-shows-p`, `bar-at-p`, `wrong-cells`,
  `pointer-in`): bind it with LET around the checks. `*terminal*`, `*out*`
  and `*face*` are set with SETQ there, and so is
  `clara.windows:*text-font*` where an application's thread is to read it,
  since a thread that SBCL starts sees nothing of a LET. `new-desk :fonts`
  puts files of fonts/ among the system's. The font of those tests is Mono
  at 15 pixels, bold, because some of its glyphs reach out of their cells
  (`reaches-out-p`): cells in a font whose glyphs all fit say nothing about
  the cut. An expectation that names the row with the cursor in it ends
  before the cursor's cell, as everywhere. tools/session.txt opens a
  terminal in two fonts and counts the pixels of its window, numbers that
  the same forms give under SBCL, and launches the REPL, Emma and Jaid in a
  font; it unloads Emma again, since the session of the world that came back
  wants no package of hers there. The files of Serif say how far their
  letters reach below the baseline as a distance, 236, where a number below
  nought is meant, and `fit` takes either: `*font-facts*` has what FreeType
  reads, the number as it stands.
- The clock (lisp/windows.lisp, Julio's issue #57; DESIGN.md has what was
  decided). What the right-hand end of the bar says is `*time*`, the words
  that the function of `clara.windows:*clock*` made of a time, and before
  them `*name*`: `paint-desk` draws the two from the right, and `bar-says`
  of the tests is the same rule written a second time, so a change to
  where either stands is a change to both. Only `tell-time` changes the
  words, with the lock, and it calls the bar dirty from the button on. The
  function is called outside the lock and only in the clock's thread
  (`keep-time`, `*timekeeper*`), never by START: a world that was saved
  with a clock that does not come back has to start. The thread asks the
  function every second (`clara.windows::*beat*`, the seconds that it
  sleeps until, is 1), which costs a hundred thousandth of the second and
  is what lets a time zone that was set show at once. It is paid for by
  every boot that runs the window manager, and the boot that collects at
  every safe point runs none: should one ever, the clock is the first
  thing to be given a longer beat there. With NIL for the beat START
  makes no thread, and that is how lisp/host/tests.lisp runs. A thread
  that woke by SBCL's clock would draw on a test's screen in the middle of
  a check, so there the tests tell the time themselves, a time of their
  choosing, and say what the bar should be saying in `*bar-clock*`. No
  host test waits for a second to be over, since the host tests have no
  time to spare (issue #122): that the thread wakes by itself is
  tools/resumed.txt's to show, on all three machines, in the world that
  came back, whose boots take seconds. It is not tools/session.txt's: on a
  slow runner of CI the first x86_64 boot has taken 88 of its 90 seconds,
  so nothing that waits, and no function that has to be compiled for it,
  goes into that session for a thing that another boot can show. A
  session never shows the time. It holds the bar against
  `clara.windows::*time*` (`bar-shows`, defined in tools/resumed.txt, inside
  a PROGN) and the words against `(clara.windows:day-and-time
  (get-universal-time))`, inside `until`, since a minute can end between
  two looks. And one more thread runs with the window manager: a count of
  threads in a session is one higher than it was before 0.0.63.
- The time of day (lisp/boot.lisp, "The time of day"). SBCL never loads
  that file, and has a DECODE-UNIVERSAL-TIME of its own, which is the
  second opinion: the host tests read the DEFUN out of the file into a
  package where the name is another symbol, and give both the same times
  and time zones. So the definition begins at the start of a line and ends
  at an empty one, and calls nothing that is only this file's. Under SBCL
  `clara:*time-zone*` is the stand-in's, which SBCL's own function knows
  nothing of: a file of the world hands it over, `(decode-universal-time
  time clara:*time-zone*)`, and never leaves the time zone out. A text of
  `evaluations` binds the variable and does not read the world's:
  `(cl::%self-test)` is typed in worlds where somebody has set it. The
  account of a world that leaves always has the time zone (`(:time-zone
  n)`, `stand` in lisp/system.lisp), so the tests of the account write
  that line out.
- A thread that is stopped while it reads the disk, by
  `clara:destroy-thread` or by a Ctrl-C, leaves the disk refusing every read
  after it (issue #174). So a session closes an application by its own
  key, `(clara.windows:key-typed 17)`, and 4 for a REPL, and waits for the
  window to go before its next form: `clara.windows:launch` comes back when
  the window is open, and Jaid is reading its directory then.
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
  `(:key code)`, `(:pointer x y buttons)`, `(:close)`, and `(:drag x y
  buttons)` when it asked for the moves. That is how an
  application is written: a loop that waits, changes what it holds, and
  draws. The close box is told once until the program has taken it.
- Applications in files (lisp/emma.lisp, lisp/jaid.lisp, lisp/ares.lisp).
  They are in lisp/, so the build puts them on the boot volume, and they
  are not in
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
  `(clara.windows:launch "Emma" name)`, and holds none of its symbols:
  the package may not be there when the file is read.
- The editor is Emma (Julio's issue #41; it was the Editor until 0.0.50):
  that is the application's name, in the launcher's list and for its
  threads, and its file and its package go by it, lisp/emma.lisp and
  CLARA.EMMA, where they were lisp/editor.lisp and CLARA.EDITOR. The
  names inside the file and in the tests say what it is and stayed: the
  struct `editor`, `open-editor`, `editor-wrong`. The title of its
  window is `title`'s to say and nobody else's: `Emma` for a text with no
  file, and `Emma - ` and the name of the file once there is one (Julio,
  the same day: "in the window title, i would like it to say `Emma -
  <name of open file>`"). The host tests and the sessions write such a
  title out; none of them calls `title` for what it expects.
- The file browser is Jaid (Julio's issue #45; it was Files until 0.0.54),
  the same way: lisp/jaid.lisp and CLARA.JAID, where they were
  lisp/files.lisp and CLARA.FILES, with the names inside the file and in
  the tests as they were (the struct `browser`, `open-browser`,
  `browser-wrong`), and a window titled `Jaid - ` and the directory that
  it lists, by a `title` of its own.
- An application of the system's that is renamed gets a line in
  `clara.windows::*former-names*`, the old name and the new one. The
  account of a world that leaves an older system says the order of the
  launcher's list in the names of that system, and `arrange` reads them
  through `present-name`: without the line the application is one that
  the account does not name, and goes back behind the name that it was
  defined after, wherever its user had put it. That is all an old name
  is kept for. Nothing is launched by one, and a session or a test that
  asks for the old name has to be told that there is no such application.
- An application is written so that the tests can drive it without its
  thread: `open-editor` makes the window and the state, `key`, `point` and
  `happened` change the state, `render` draws, and `run` is the loop that
  the launcher's thread sits in. The same in lisp/jaid.lisp. A window of
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
  (`clara.jaid::*names*`): SBCL's DIRECTORY gives pathnames.
- Volumes (Julio's issue #52; DESIGN.md has what was decided). A name
  that begins with a number and a colon is on the volume of that number,
  `"2:/mine.lisp"`, counted from 1 in the order of `(clara.fat:volumes)`,
  and any other name is where it always was, on `clara.fat:*volume*`.
  lisp/fat.lisp is the one place that reads that part of a name
  (`volume-prefix`): `name-parts` passes over it, and every function there
  that takes a name hands it to `the-volume`, as a new one does. `names`
  alone gives NIL for a volume that is not there, which is what makes
  PROBE-FILE and DIRECTORY say that there is no such file; everything else
  is an error that says which volumes there are. lisp/boot.lisp takes a
  name apart at its slashes and knows nothing of this, but for
  `%volume-named`: the first directory of a volume is in no directory.
  The language has two functions for what Common Lisp has no word for,
  `clara:volumes` and `clara:copy-file`, which the file system hands over
  with the rest (`provide-files :copy :volumes`, seven functions now).
  What `volumes` says of a volume is read by programs and only ever added
  to. `copy-file` reads a file whole and writes it whole, so it is
  `put-file`'s order and no new way of writing, and it refuses two names
  that lead to one entry (`same-file-p`), however they are spelt: a move
  is a copy and then a delete, in whoever moves, and a file that was
  moved onto itself would be gone. SBCL never loads lisp/boot.lisp, so
  the two are the boots' to try (tools/volumes.txt, and the manual's
  section on a disk of one's own); under SBCL `clara:copy-file` copies a
  file of the host's, and `clara:volumes` says what a test told it
  (`clara.host:set-volumes`). The tests of the file system have two
  volumes on one disk (`two-volumes`, `volume-holds`, `held`). A machine
  that `make run-*` handed a newer build has that build's disk as one
  more volume, which cannot be written: `the disk ... cannot be written`.
- What the pointer carries (lisp/windows.lisp, `carry`; the same issue).
  `*held*` has a fifth place for it, a text, which the program of the
  window says while the left button is down that went down there, and
  which goes with the press. When the button comes up, `pointer-moved`
  tells the window that it is on the inside of (`:drop`, `(:drop x y
  text)`), then the window that the text came from, through its DRAG with
  the buttons as they are, none, and then the button as ever (`let-go`,
  and `call` after it): a test holds the three to that order. `carry`
  gives NIL to a window that still has a `(:pointer ...)` to take
  (`behind-p`), so a program that is behind the pointer cannot give this
  press what an earlier one took hold of. A window that never calls
  `carry` is told nothing new.
- Jaid and volumes (lisp/jaid.lisp). The directory `""` is the list of
  the volumes, above every first directory: `above` says where the way up
  leads, which is nowhere on a machine with one volume, so nothing that
  such a machine shows has changed. `volume-of` and `whole-name` say
  which volume a name is on, by what the language says of the volumes,
  and never by reading the name for a number: under SBCL the two volumes
  of the tests are two directories of the host's, named `one/` and
  `two/` under a `*default-pathname-defaults*` of the test's. `*found*`
  is PROBE-FILE, which gives a pathname under SBCL, so the tests put
  `host-found` there, as they put `host-names` into `*names*`. A question
  of the last row is `asked`, its words and what y does, for a file that
  is to be deleted and for one that would be replaced. `pressed` is the
  name that the button went down on and whether letting go of it there
  opens it, and the first move takes it away: what is carried is not
  opened. `put` is where a file comes to a directory, by Ctrl-V and by
  the pointer, and `transfer` the copy, and the delete after it for a
  move. In the tests `browser-events` does to a browser what happened to
  its window, as its thread would, and `browser-pointer` moves the
  made-up screen's pointer to a place of its window. tools/volumes.txt
  starts in the world that the first AArch64 session saved, so `until`,
  `pointer-at`, `shows` and `cursor-at` are there, and defines `says`, a
  row of the window on top with its colours either way round; the sizes
  that it expects of the volumes are those of that boot's disks.
- What an application does with a file it does with the language: OPEN,
  READ-LINE, PROBE-FILE, DIRECTORY, DELETE-FILE. So it only ever sees what
  lisp/boot.lisp makes of the file system, on ClaraOS, and that side is
  tested by the boots: tools/session.txt types a file into the editor,
  saves it and reads it back at the serial port. A session waits for the
  editor through the screen: `cursor-at` (defined there) looks for the
  cursor's bar at a cell of the focused window's surface. What is typed
  between two waits stays under 64 events of the keyboard.
- Packages (lisp/parker.lisp, the package CLARA.PARKER, Julio's issue #43;
  DESIGN.md has what was decided). Parker is a file of `world`, the last,
  and its application is defined there like the REPL's, the last of the
  system's in the launcher's list. A package is taken as a release is: HTTPS only, the
  index against its signature, every file against the index
  (`ask`, `fetch-files`). The index's form is read by every ClaraOS that
  there has been, so it is only ever added to: a line that `entry-line`
  does not know is passed over, and a package with a line that it knows
  and that is wrong is left out (`whole-p`). `described` in
  tools/release.py holds what is published to the same rules, so a
  change to what a line may say is a change to both. On the disk the
  file `package` is written last and deleted first (`take`, `erase`), and
  every file is fetched before the first is written.
- The disk says what is installed, and a world follows it (`follow`).
  lisp/system.lisp calls it at every start, before the text of `/home`,
  through `clara.system::*parker*`, which lisp/parker.lisp sets as it is
  loaded: `:start`, with `:made`, `:resumed` or `:bare`, and `:packages`,
  the names of the packages of the language that are an installed
  package's and so not the user's (`user-packages`). What a world has is
  `*loaded*`, a variable of the world's like any other. What a start says
  of packages goes through `clara.system::tell`, so the report has it,
  and begins with `packages: `.
- The tests of Parker (lisp/host/tests.lisp, "Parker"). `published` is
  what a web server has of a source, signed with the tests' key, or wrong
  in the ways its options say; `installed-tree` what a disk has of a
  package; `parker-machine` a machine with such a disk on such a network,
  started as its state says; `not-installed` what a refusal leaves, which
  has to be nothing, on the disk and in the world. Under SBCL the world
  is one for all machines, so the packages of the language that a test's
  package makes are named in `forget-world`, which takes them away
  between machines. LOAD is the host's there: `clara.parker::*load*` is
  given a function that reads the machine's disk, and an application's
  file, which the launcher loads with LOAD, is never loaded by a host
  test. That is the boot's to try: tools/network.txt installs `sun` from
  the test's web server, launches its application, replaces it by a
  newer version (`packages-newer` in the Makefile, the same package under
  a higher number), upgrades the system and takes it out. A package that
  is added to packages/ gets its lines there.
- No test asks the place where packages are published, as none asks the
  place of the releases. lisp/host/tests.lisp takes
  `clara.parker:*sources*` away once it has looked at it. A session that
  types `clara.parker:available`, `install` or `update`, or launches
  Parker, whose window asks as it opens, has set that variable first, or
  has the test's name server, which knows no name outside this computer.
- What claraos.org has of packages is the directory packages/, laid out
  by `python3 tools/release.py packages` and signed with the release's
  key: `make release PACKAGES=<directory>`, which the website's workflow
  runs and `make release-test` tries with a key of its own. The
  directory that is laid out is made anew each time, so it is never one
  that holds anything else. A change to packages/ alone is no change to
  the system and bumps no version of it: a package has its own version,
  in the first line of its file `package`, and a machine that has the
  package takes a change only when that number is higher
  (`clara.parker:update`).
- Ares, the web browser (lisp/ares.lisp, the package CLARA.ARES, Julio's
  issue #44; DESIGN.md has what was decided). It is an application in a
  file, installed by the last lines of lisp/terminal.lisp like Emma, so
  the launcher's list has five applications of the system's, which the
  sessions and the manual write out. A page goes through four steps, each
  a function of what the one before made: `bytes-text`, `read-page`,
  `lay-page`, `paint`; a change belongs to one of them, and so does its
  test. Every page is asked for by HTTPS (`secure`): nothing in that file
  hands `clara.net:fetch` an address that begins with `http://`, and what
  is sent of an address has been through `sendable`, so that a page's
  link cannot write a line of its own into a request.
- The reader (`read-page` and what it calls) follows the rules that
  browsers read a page by, the WHATWG's HTML Standard, 13.2, and the lists
  at its top are that standard's lists: which kinds end a paragraph,
  which end by themselves, which a tag cannot close an element across. A
  change there is held against a browser, not against what seems right.
  lisp/host/pages.lisp has the pages and the tree that Chrome makes of
  each; add the page that a change is about, with an empty tree, and run
  `python3 tools/pagecheck.py --write`, by hand, on a computer that has
  Chrome: it is no part of `make test`. The two places where the reader
  is not the standard's are written down in the tests with the trees
  that it makes. That file cannot hold a return or a character of the
  code 0; the tests make such pages themselves.
- The kind of an element is a keyword for a kind that lisp/ares.lisp
  names anywhere, and the name as a string for any other (`tag-of`): what
  a page writes is never interned. So a kind that gets a clause of its
  own becomes a keyword by being written there, and code that looks at a
  kind compares with `same-tag` or `in`, never with `string=`. Under SBCL
  far more keywords exist than on the machine, so a kind that the file
  does not name is a keyword in the host tests and a string at a kernel:
  what `lay` does with an element must not depend on which, which is why
  the clause for a string stands behind the ones that look at what a tag
  said.
- Laying out (`lay` and what it calls). Whatever makes a line goes
  through `add-piece` and `end-line`, and whatever leaves space through
  `more-gap`, which keeps the largest. `measure` runs the same code with
  nothing laid out, to find how wide a cell is at the least and at the
  most: a new kind of element that makes something other than pieces
  looks at `laying-measuring` before it makes it, or a table's cells are
  laid out twice. The tests have `page-wrong`, what is out of order in
  any page that was laid out (a piece outside the page, over another, or
  not as wide as its text), `broken`, a second way of breaking words into
  lines, and a page of everything that is laid out at every width: a new
  kind goes into that page.
- The window. `draw` draws and `render` draws and shows; the tests call
  `draw` after each key and hold the surface against what drawing
  everything anew gives (`ares-wrong`) and, where they say so, against
  the page (`ares-unruly`), and `render` only where they look at the
  screen (`screen-wrong`): showing a window on the tests' desk takes
  twenty milliseconds under SBCL, and the host tests have little time
  left (issue #122). A window fetches through `clara.ares::*take*`, where
  the tests put a function that hands out a list of pages (`*ares-web*`);
  one test calls the real one, on the made-up network. Whatever the
  window keeps of what it drew (`view-shown`, the two rows) is set to NIL
  by what changes it, or the window shows the page of before.
- No test asks the Internet, and nothing typed by hand does: Ares names
  ClaraOS to every web server. The boot that fetches (tools/network.txt)
  has the test's name server, and launches Ares at the pages of
  tools/pages, which the Makefile puts beside the release that
  tools/serve.py hands out; the lines that the first of those pages comes
  to at the prompt are the ones that SBCL makes of it, so a change to how
  a page is laid out changes that line of the session. The manual's
  transcript launches Ares with no address, since the machines that the
  manual is typed at reach the Internet: with none, Ares shows the page
  that it has of itself and asks nobody.
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
- Whatever a session leaves to be done gets an issue before the session
  ends (Julio, 2026-11-22, of the calls at the end of M20's summary: "Make
  them into GitHub issues"): a shortcut, a provisional decision, a limit,
  a call that Julio may want changed, something that it found wrong and
  did not put right. Saying it in the summary at the end, or in the pull
  request, is not enough; the next session starts from the issues. One
  issue for each thing that can be closed by itself, written like the
  ones that are there (#65 to #75 were the first): a title of the kind
  `CLOS - CHANGE-CLASS`, one of his labels (`feature`, `bug`, `chore`),
  Julio as the assignee, and a few lines that say what happens now, what
  SBCL answers where it is a matter of the language, why it was left,
  where the change goes, and which documents describe it as it is. What
  a kernel answers is typed at one and not written from memory: a session
  with the answers in it passes only when the kernel says exactly that
  (`NAME=probe SESSION=file tools/boottest.sh aarch64`, five seconds).
  Look whether the issue is there already (`gh issue list --search`), and
  file it with `gh issue create --body-file`. A record is no work and no
  issue: what was measured, and what was checked by hand, goes into
  ROADMAP.md under its milestone as before. What ROADMAP.md holds as
  still to be done from before that day stays there until it comes up, in
  a session or because Julio asks for it: it becomes an issue then, its
  entry says the number, and the pull request that closes an issue takes
  out what ROADMAP.md says of it. Before starting an issue, read the
  group of the milestone that it belongs to there.
- The website, https://claraos.org, is site/index.html, filled in by
  site/build.py from ROADMAP.md, kernel/kernel.h (the version)
  and the console font (`make site`, then open build/site/index.html), and
  published by .github/workflows/site.yml on every push to main that touches
  them, the system, or packages/: the same workflow builds the system of
  that commit and publishes it beside the pages, as the release at
  `https://claraos.org/releases/` (above), and the packages at
  `https://claraos.org/packages/`. GitHub lists what the workflow
  uploaded some time after it has taken it, so the deployment waits ten
  seconds and is tried up to three times, and the artifact is named after
  the attempt of its run, which is what lets a run that failed be run
  again (issues #102 and #185). Look at that run after every merge that
  starts it, beside CI's: when it failed, the site and the release are
  still those of the merge before, and `gh run rerun <id> --failed` runs
  it again. The page reads the milestone
  entries of ROADMAP.md, so keep their form.
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
  list with `data-package` for each package. `make site` also stops when
  a link of a page into itself names an id that is not there, or an id is
  there twice: a browser goes to the first of two, which is how the two
  links to the list of the system's files came to lead into the
  compiler's chapter. And
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
- Dependabot (.github/dependabot.yml, issue #53) looks at the actions of
  the two workflows every Friday and opens a pull request, labelled
  `chore`, when one has a newer version than the workflow names. The
  workflows name an action by its major version, so that is the next
  major one, and the releases in between run without a pull request
  (issue #198). CI tries a newer action of ci.yml on Dependabot's pull
  request. One of site.yml is first run by the Website run that the
  merge starts, since nothing of that workflow can be tried before: read
  what the action's release says has changed before the merge, and look
  at that run after it. Whatever else comes to have a list of versions
  that Dependabot reads, a requirements file for the tools in Python, a
  Dockerfile, a submodule, gets its entry in that file in the same
  change.
- To see a change the way CI will before pushing it, with Docker running:
  a container of the Ubuntu release that the runners have, ubuntu:26.04,
  with the packages from the workflow, a copy of the tree without build/,
  and `make test` in it. Which release that is stands in the first lines
  of a run's log (`Image: ubuntu-26.04`), and `ubuntu-latest` moves to
  the next one some day: look there before believing this line. Another
  release has another QEMU and another firmware. This file said 24.04
  until 0.0.44, where CI had been on 26.04 from its first run, and a
  stall that only the firmware of 26.04 has (above) passed fourteen times
  in that container and was written down as unexplained. In zsh a
  pattern that matches no file ends the whole command line before it
  runs: a line that begins with `rm build/*x*` and goes on to `make test`
  and a `grep` of its log then shows the log of the run before. build/
  itself must not be shared with the container: the objects in it come
  from another compiler.
  Have the container print what a failed boot differed in before it ends
  (the lines of test.log from the boot's command on, and the end of its
  build/boot-<name>.log), or start it without `--rm`: a boot that failed
  once and passed twelve times afterwards left nothing to read.
