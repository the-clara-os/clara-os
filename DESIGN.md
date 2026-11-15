# ClaraOS design

## What it is for

A system small enough for one person to hold in their head, running on the
two machines at hand: Apple silicon (AArch64, virtualized in UTM) and x86_64
(emulated in UTM). It should read well from top to bottom. It is not a Unix,
not POSIX, and does not aim to run existing software.

## The shape: a Lisp machine (decided 2026-11-11)

ClaraOS is a C substrate under a Lisp world. The machine boots into a window
manager, and the applications are Lisp programs loaded into that world.

- **The substrate** is the C kernel: bringing up the CPU, physical and
  virtual memory, threads and the scheduler, interrupt and exception entry,
  timers, the lowest layer of device access, and the Lisp runtime itself:
  object representation, reader, printer, evaluator and garbage collector.
  It has no policy and no personality.
- **The world** is Lisp: the console and the REPL, the logic of the drivers,
  the filesystem, the window manager, every application.
- **One address space, one heap, kernel mode.** Lisp runs in supervisor mode
  next to the substrate. There is no user mode, no system-call layer and no
  inter-process communication. Protection comes from the language: Lisp code
  cannot forge a pointer, and the few unsafe primitives (raw memory access,
  port I/O) live in one package that only drivers use. Applications are
  isolated by packages and threads, not by page tables. An application error
  is a condition the window manager handles; stopping an application means
  unwinding its threads. A bug in the substrate or a driver takes the whole
  machine down, as on a Lisp machine. The alternative, hardware-protected
  Lisp processes with a kernel between them, was rejected as Unix with Lisp
  paint.
- **The Lisp is a subset of Common Lisp, not a new dialect.** The subset is
  chosen so that every Lisp file in this repository also loads under SBCL on
  the host: development and tests happen in SBCL, deployment is ClaraOS, and
  existing Common Lisp knowledge and code carry over. First: symbols and
  packages, conses, fixnums, characters and strings, vectors, hash tables,
  closures, special variables, multiple values, macros, defstruct, the
  lambda-list keywords, conditions with handler-case and unwind-protect.
  Later: floats, CLOS, the rest of format.
- **Interpreter first, compiler later.** The substrate evaluates Lisp with an
  interpreter written in C. A compiler, to bytecode or native code, is
  written in Lisp once the world can host it; the interpreter stays as the
  bootstrap and the fallback.
- **The image is the system.** Booting means loading a saved heap image from
  disk and resuming it with the window manager running. Until images exist,
  the boot handoff reads Lisp source files from the ESP through the UEFI
  file protocol before ExitBootServices, so no disk driver is needed early:
  every file in the ESP's `\clara` directory, which the build fills from
  lisp/.
- **Threads are substrate threads.** A Lisp thread is a kernel thread with a
  Lisp-visible dynamic-binding stack. The garbage collector stops the world;
  precise, non-moving mark-sweep first, something better when it hurts.
- **Graphics is a framebuffer.** The UEFI GOP framebuffer, software rendered
  from Lisp with double buffering and damage rectangles. Input arrives as
  virtio-input events on both architectures. Fonts are bitmaps first.

## Platform decisions

- UEFI only, on both architectures. No BIOS path, no multiboot, no separate
  bootloader: the kernel is the EFI application (`efi_main` in kernel/boot.c)
  and ExitBootServices is the moment the machine becomes ours.
- One source tree, one toolchain. clang and lld targeting `*-unknown-windows`
  produce the PE/COFF images the firmware wants. Architecture-specific code
  lives under kernel/arch/<arch>/ behind the few `arch_*` functions declared
  in kernel/kernel.h; everything else compiles for both. Each of the two
  directories has one assembly file, entry.S, for what C cannot say, and
  one header, arch.h, for what its own files share.
- Serial first. Every milestone is observable on the serial port before
  anything is drawn, and the boot test reads the serial log.
- The firmware describes the hardware. ACPI tables on both architectures
  (EDK2 exposes ACPI, not a device tree, on the virt machine), PCIe for
  device discovery, virtio for the drivers.
- Tests are boots. `make test` boots both architectures headless; no
  milestone lands without it passing on both. Substrate code that can check
  itself does so during the boot and panics when a check fails, so a boot
  that reaches its last line has passed. The boot test also types at the
  kernel over the serial port, and what comes back has to be the session
  in tools/session.txt, to the byte. Lisp code is also tested on the host
  under SBCL.
- C11, freestanding, no libc, `-Wall -Wextra -Werror`. The targets are LLP64,
  so `long` is 32 bits: the kernel uses the stdint types and never `long`.

## The address space (decided in M3, 2026-11-12)

One address space and one set of page tables, in 4 KiB pages on both
architectures (kernel/vm.c).

- RAM is mapped at its own address: in RAM a virtual address is the
  physical address. Page tables, device queues and everything else that
  deals in physical addresses need no translation, and `phys_ptr()` is the
  one place where that cast is written.
- The screen and device registers sit at their own addresses too, mapped
  one by one by the code that uses them. What nobody mapped faults.
- The first megabyte is never mapped, so a null pointer faults.
- The kernel image stays where the firmware loaded it and is mapped by
  section: code and constants read-only, data not executable. It is not
  moved to the upper half of the address space. A higher-half kernel leaves
  the lower half to user programs, and here there are none; moving would
  mean applying the image's relocations a second time and translating
  between physical and virtual addresses from then on. The price is that C
  code has no fixed address, so a saved heap must never hold one.
- 64 TiB starting at 64 TiB (`VM_HEAP_BASE`) are reserved for the Lisp
  heap: the same addresses on every machine and every boot, which is what a
  saved heap image needs. The region is above any physical address the two
  machines have, and inside the 47 bits both architectures offer without
  x86_64's upper half or AArch64's second table register.
- The only memory that can be run is the kernel image's code. All other
  RAM is data, the firmware's old code included, and on AArch64 the
  processor is also told that whatever can be written cannot be run.

## Exceptions and interrupts (decided in M4, 2026-11-13)

- The kernel installs its own exception vectors first, before it touches
  memory management, so a fault anywhere after the first line of the boot
  report is the kernel's to report. Once its page tables are in place as
  well, nothing of the firmware's is in use: boot-services memory joins
  the free page frames, and it is overwritten on the way in, so that a
  boot which still depended on it would fail there and then.
- A fault the kernel did not provoke stops the machine. The kernel says
  what happened in words ("a write to 0x..., which is read-only"), where
  in its image, and what was in every register, on the serial port and on
  the screen, and halts. The only faults it recovers from are those of the
  self-test's probes, which provoke one fault of each kind at every boot
  and check how it comes back.
- A stack that overflows cannot be reported on the stack it happened on,
  so a handler never depends on that stack. On AArch64 the kernel proper
  runs on SP_EL0 and every exception is taken on SP_EL1, which points at a
  stack kept for the purpose. On x86_64 handlers run on the stack they
  interrupted, and the double fault that follows a failed push has a spare
  stack, named in the TSS.
- Whatever the cause, the entry code in entry.S saves every register in a
  frame and hands the frame to C, and what C leaves in the frame is what
  the interrupted code resumes with. That is how a probe is made to resume
  somewhere else, and how threads will be switched.
- An interrupt handler runs with interrupts off, never allocates memory,
  never maps any, never waits, and returns. Anything longer belongs to a
  thread. The timer is the only source so far; devices will deliver theirs
  to Lisp as events.
- The interrupt controller comes from ACPI, not from an assumed address:
  the MADT names the local APIC and the I/O APICs on x86_64, and on
  AArch64 the GIC, whose versions 2 and 3 are both driven because QEMU
  offers the first and UTM asks for the second.
- Time is a count of ticks, `TIMER_HZ` of them a second, from the local
  APIC's timer on x86_64 and the generic timer on AArch64.

## Threads (decided in M5, 2026-11-14)

- A thread is a stack and, while it is not running, the registers the
  exception entry saved for it. The processor changes threads in one
  place only, on the way out of an exception or an interrupt: the frame in
  hand is put away in the thread that was running, and the next thread's
  frame takes its place (kernel/thread.c). Being taken off the processor
  by the timer and giving it up to wait are the same mechanism; a thread
  that waits raises an exception of its own to get there. There is no
  second way of saving registers to keep in step with the first. The
  price is that a wait costs an exception.
- One processor. With interrupts off the running thread is alone, and the
  scheduler's own state is only ever touched that way. A thread looks at
  what it is about to wait for and starts waiting inside one such stretch,
  so nothing it waits for can slip in between.
- The threads that are ready take turns in the order they became ready. A
  turn ends at the next tick when another thread is waiting for one. No
  priorities. An idle thread runs when no other can, and sleeps until the
  next interrupt.
- A thread sleeps for a number of ticks, and the tick wakes it.
- Shared data sits behind a lock, and locks are for threads: one that
  finds a lock taken queues up and sleeps, and the lock is handed down the
  queue in order. An interrupt handler takes no lock, because it cannot
  wait; it may wake a thread and that is all. A lock is held briefly:
  never across a sleep, never while the thread waits for another to
  finish, never at a safe point.
- Every thread but the first has a stack of fixed size with an unmapped
  page under it, so an overflow is a fault that names the thread, not
  damage to whatever lay below. The first thread is the flow of control
  that kmain started in, on the stack in the kernel image.
- Stopping the world is by agreement. A safe point is a place where a
  thread says it can be held up: where the interpreter will know that
  everything the thread holds can be found. A thread asleep, or waiting
  for another to finish, is at one as well, and parks if it wakes while
  the world is stopped. `thread_stop_the_world` returns when every other
  thread is at a safe point; a thread that was waiting for a lock gets it
  and runs on to its next one first. This is what the collector's
  "all threads stopped" means on one processor: not that the others are
  off the processor, which they always are, but that each is somewhere
  its state can be read.
- Whoever makes a thread waits for it to finish (`thread_join`), and that
  is when its stack is given back.

## Lisp objects, the reader and the printer (decided in M6a, 2026-11-14)

- A Lisp value is one 64-bit word, and its lowest bits say what it is
  (kernel/lisp/lisp.h). A clear lowest bit is a fixnum, the integer in the
  other 63. The lowest three bits tell a cons, a symbol, any other object
  in the heap, and an immediate apart; an immediate is a character or a
  marker, such as the one for a symbol without a value. Type tests for
  the commonest things read no memory.
- Every object in the heap begins with a header word: its type, a byte
  for the collector, and a length. Conses have one too, which makes them
  three words where two would do. In return the heap can be walked from
  its first object to its last by anything that knows the header, and
  that is all the collector's sweep, a saved image and a census need. The
  alternative, pages that hold conses only and a table that says which,
  is more machinery for less memory, and can come later.
- The heap is the region the address space reserves for it. It fills from
  the bottom and grows a page frame at a time. Objects do not move, so a
  C pointer to one stays good, and NIL, the first object of all, has an
  address that is a constant. A frame in the heap keeps its place in the
  mapping of RAM as well: the rule that RAM is at its own address has no
  exceptions but the guard pages, and a driver can reach the frames of a
  heap object the way it reaches any others. A stray write through a
  physical address can therefore land in an object, as it can anywhere
  in RAM.
- NIL is a symbol like the others, and the empty list is the same word.
- A character is a Unicode code point, and a string holds its characters
  at 32 bits each, so that the n-th one is found at once, as Common Lisp
  expects. Text on its way in or out, the serial port and files, is
  UTF-8. The reader refuses text that is not well-formed UTF-8.
- Integers are fixnums until there are larger ones. What the reader has no
  object for, a float, a ratio, an integer too large, it refuses with an
  error; it does not read it as a symbol, because the same text must not
  mean one thing here and another under SBCL.
- Packages work as in Common Lisp: a symbol is internal or external in the
  package that holds it, and a package that uses another finds the other's
  external symbols by name. The tables are vectors in the heap, so a saved
  image holds them. `*PACKAGE*` says where names are read.
- The reader reads text that is already in memory, all of it, and never
  waits. When the text ends inside a form it says so, and whoever can get
  more of the text comes back with the form from its beginning. Reading a
  line again costs nothing that matters, and it leaves no place in the
  reader where a thread could be held up with half a list in its hands.
- The collector runs at safe points only, never inside an allocation. The
  C code of the runtime relies on it: between two safe points it keeps
  objects in local variables and nothing has to be told. The evaluator,
  which does come to safe points, keeps what it holds where the collector
  can find it (below). M6c built the collector on this and found it to
  hold.
- The printer writes an object so that the reader makes the same object of
  it, wherever there is such a text: a symbol with its package when the
  name alone would not find it, bars around a name that would not read
  back, `'x` for `(QUOTE X)`.
- Lists nest by recursion in C in both, on a thread's fixed stack, so
  there is a depth past which the reader refuses and the printer cuts
  short. The evaluator has a limit of the same kind (below).
- What the substrate itself holds on to in the Lisp world is in one
  struct, `lisp_roots`: where the collector starts, and what an image has
  to bring back.

## The evaluator (decided in M6b, 2026-11-14)

- It is an interpreter that walks the lists the reader made; there is no
  form in between. A symbol is a variable, a list is a special form, a
  macro call or a call, and anything else is its own value
  (kernel/lisp/eval.c). The special forms are a table in C. Whatever can
  be a symbol's function is one type of object, of four kinds: a function
  in C, a special operator, a closure, a macro. The two in C hold their
  place in a table, never an address.
- An environment lives in the heap: a chain of frames, each a vector,
  that hold variables, local functions, a block or a tagbody. A closure
  keeps the chain it was made in. Finding a variable walks the chain,
  which is slow and plain; a compiler will know where each one is.
- A special variable has its value in the symbol. Binding it puts the old
  value on a stack of bindings, and whatever bound it puts the value back
  on its way out. Until there are Lisp threads (M7) that is one value for
  the machine.
- A non-local exit is not a jump. RETURN-FROM, GO, THROW and an error
  mark where control is going and return; every piece of C on the way
  sees the mark and returns in turn; the block, the tagbody or the catch
  it is meant for takes the mark off. There is no setjmp, nothing in
  assembly to keep in step on two architectures, and since the way out
  passes through every frame, each undoes what it did: bindings now,
  UNWIND-PROTECT later. The price is a look at the mark after every form.
- An error is what went wrong, in words, and unless something handles it
  (below) it goes to the top level, which prints it and reads on: `error:
  CAR wants a list, and 5 is not one`. A mistake at the prompt does not
  stop the machine.
- A form can give several values or none. C returns the first, and one
  place holds how many there are and the rest; only the forms that pass
  the values of a form inside them on keep more than one.
- The evaluator keeps what it holds on a stack of its own, the value
  stack: the arguments of a call while they are evaluated, every frame it
  makes for as long as it evaluates in it, values that wait for a body to
  finish. A C variable holds an object only from one call of the
  evaluator to the next. That is what "precise" asks of an interpreter
  written in C: at a safe point, which the evaluator comes to at every
  call and every GO, the collector finds everything in the heap, on that
  stack, on the stack of bindings and in a few words beside them, and
  never has to guess at what a C frame holds. The alternative, looking
  through the thread's own stack for words that might be objects, is
  less code here and gives up knowing.
- A macro call is expanded once. The expansion takes the call's place in
  the list that holds the call, so the next time round the evaluator
  finds the expansion; the call itself is not touched, because somebody
  else may hold it, quoted, to show it in a message. Without this every
  turn of a loop would expand its macros again, and until there is a
  compiler the interpreter runs everything. EVAL copies the form it is
  given, so that data stays what it was.
- The Lisp world has a thread of its own, with a megabyte of stack,
  because the evaluator calls itself in C for every form inside a form.
  It looks at how far down the stack it is, and well before the guard
  page it stops with an error, "the stack is full", like any other
  error: a function that calls itself without end is a mistake in a
  program, not a fault of the machine.
- Arithmetic gives the right integer or an error. A sum that leaves 63
  bits is refused, and so is a division that does not come out even,
  for the reason the reader refuses a float: the same text must not mean
  one thing here and another under SBCL.
- The same goes for the language: what the evaluator does not know it
  refuses, with an error that says so, where taking it for something
  else would change what a program means. `(declare (special ...))` is
  one, `&environment` another.
- The language is in two parts. In C is what has to be, the special
  forms and the functions that reach inside an object, and what the rest
  is built from. The rest is Lisp, lisp/boot.lisp: the macros, the
  functions on lists, SETF, DEFSTRUCT, DEFPACKAGE. The kernel loads it
  before anything else and stops if it cannot. What C defines is external
  in COMMON-LISP, boot.lisp is read in COMMON-LISP and exports what it
  defines, and a name that begins with % is the implementation's own and
  stays internal there.

## The collector and conditions (decided in M6c, 2026-11-15)

- The collector marks and sweeps (kernel/lisp/heap.c). It starts from
  what the substrate holds, `lisp_roots`, and from what the evaluator
  holds: its value stack, the special variables that are bound, the
  values of the last form, the exit under way. It follows every value to
  the object it points at, and what it has not reached by the end is
  free. It is precise. Every word after the header of an object is a
  value, except in a string, which has none, so the collector never
  guesses and never keeps an object by mistake. Objects do not move.
- It runs when the evaluator, at a safe point, finds that as much has
  been made since the last collection as was in use after it. Making an
  object never collects. That is the bet M6a made, and it held: the
  reader, the printer, the packages and the functions in C went under
  the collector as they were, and the evaluator needed three changes, to
  hold a function while it is called, a list while it is taken apart,
  and the words that outlive an exit.
- The price is that memory can run out between two safe points while the
  heap is full of what nobody needs. So the evaluator stops a computation
  early: when a collection leaves less than a sixteenth of the machine's
  memory, the safe point ends in an error, STORAGE-CONDITION, and what is
  left is for the C code that cannot stop halfway. Whatever makes an
  object as large as a program asks for looks first and refuses in the
  same way. Running out for good is still a panic.
- Free memory stays in the heap as free blocks, each with a header like
  an object's, so the heap can still be walked from end to end. A new
  object goes into a block of its length, or into part of a longer one,
  and past the end of the heap only when no block will do. The heap ends
  where its last object does, and gives the page frames beyond that
  back.
- An object that was freed while something still held it must not go
  unnoticed. Freed memory is filled with a value that is the address of
  nothing: following it is a fault, the collector refuses to follow it,
  and the allocator refuses a free block that somebody has written to.
  And there is a way to ask for a collection at every safe point, under
  which nothing that the evaluator fails to hold survives its next call;
  `make test` boots once like that.
- An error is a condition: an object with a type, what it says to a
  person, and slots. A type is a name with parents, which
  DEFINE-CONDITION records in Lisp; all the substrate asks is whether
  one type is another's descendant. The substrate's own errors have
  Common Lisp's types where a program would tell them apart, and are
  plain ERRORs otherwise.
- HANDLER-CASE handles conditions, and nothing else does yet. Signalling
  a condition looks for the innermost clause that names its type and
  leaves for it, the way a THROW leaves for its CATCH; no handler runs
  in the middle of the form that signalled. So there is no HANDLER-BIND
  and there are no restarts: both want a debugger to be of use, and can
  come with it. UNWIND-PROTECT is on the way out like every other form,
  and evaluates its cleanup whichever exit is passing.
- What a condition says is a string, put together when the condition is
  made. A report function would have to write to a stream, and there
  are none yet (M7).
- A stack or a heap that is full is not an error in Common Lisp's
  sense, and neither is Ctrl-C: `(handler-case ... (error ...))` and
  IGNORE-ERRORS let them pass, as they do under SBCL, and a clause for
  STORAGE-CONDITION or SERIOUS-CONDITION takes them.
- Ctrl-C stops a computation where it can be stopped cleanly, at the
  evaluator's next safe point, as a condition that unwinds like any
  other. The timer's tick takes in what is typed on the serial port, so
  that it is seen while the evaluator is busy.
- A thread that stands at a safe point holds no lock, because the thread
  that stopped the world may want any of them. That was a rule in
  comments; now a thread counts the locks it holds, and sleeping,
  joining or coming to a safe point with one is a panic.

## Conventions

- C: lower_snake_case for functions and files. Kernel-wide symbols carry
  their subsystem as a prefix: `kprintf`, `fb_fill`, `arch_halt`. The Lisp
  runtime's C code is prefixed `lisp_` and lives in kernel/lisp/; a Lisp
  value in C has the type `lisp`.
- Lisp: sources live under lisp/, one package per subsystem, named
  `clara.<subsystem>`. Each file loads under SBCL; host-only shims live in
  lisp/host/ and are never loaded on ClaraOS. The exception is
  lisp/boot.lisp, the part of Common Lisp itself that is written in Lisp:
  SBCL has all of it already, and never loads it.
- Comments say why, or what the hardware requires. The code says what.
- One C struct per hardware or firmware table, laid out as the specification
  says, with a comment on any padding or reserved slot that matters.
- Numbers from specifications cite the document when they are not obvious.
- A physical address is a `uint64_t`, and `phys_ptr()` makes a pointer of
  one. Memory is handed out in 4 KiB page frames on both architectures
  (kernel/pmm.c).
- No early abstraction: write it for one architecture, make it work on the
  second, then extract the shared interface.
- Third-party material is vendored unmodified with its license beside it
  (fonts/), and a generated file names its generator in its first line.
