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
  Since M20, classes, generic functions and methods ("Objects", below).
  Later: floats, the rest of format.
- **Interpreter first, compiler later.** The substrate evaluates Lisp with an
  interpreter written in C. A compiler is written in Lisp once the world
  can host it, which it is since M14a ("The compiler", below): it makes
  code for a small machine that the substrate has, and not yet for the
  processor. The interpreter stays as the bootstrap and the fallback.
- **The image is the system.** Booting means taking a saved heap image for
  the heap and starting the world that is in it, with the window manager
  running when the world was saved with it running ("Images" and
  "Windows", below). The boot handoff reads the files of the system's own
  directory under the ESP's `\clara` through the UEFI file protocol
  before ExitBootServices, so no disk driver is needed to start: the image
  when there is one, and the Lisp sources that the build puts there from
  lisp/, which a machine without an image makes its world from.
- **Threads are substrate threads.** A Lisp thread is a kernel thread with a
  Lisp-visible dynamic-binding stack. The garbage collector runs while no
  other Lisp thread does; precise, non-moving mark-sweep first, something
  better when it hurts.
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
  in tools/session.txt, to the byte. A machine boots from a disk that is
  made for it, writes to it, and boots a second time from what it left
  there. Lisp code is also tested on the host under SBCL, where a test can
  look at what a boot cannot: `make test` runs lisp/host/tests.lisp before
  it boots anything.
- The user manual is part of the system, and is held to it
  (site/manual.html, built by site/build.py). What it shows of the prompt
  is a session like the others, typed at a kernel by `make test`, and its
  lists of what is defined are compared with the kernel's tables when the
  website is built, in both directions. A manual that is only written
  falls behind in a week; this one stops the build when it does.
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
  Since M16a there is a second kind, the code that the Lisp world makes
  for the processor: 1 GiB starting at 32 TiB (`VM_CODE_BASE`) are
  reserved for it, mapped to be run and never to be written. It is
  written through the addresses that its page frames have as RAM, so the
  rule holds as it stands, that no address is both (Code for the
  processor, below).

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
- Since M7 the collector does not stop the world: one Lisp thread at a
  time has the runtime, which is all that stopping the others was for.
  The mechanism is still in kernel/thread.c, with no caller but its own
  test.

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
  on its way out. Every Lisp thread has such a stack, and the symbol holds
  the value that the running thread sees (M7, below).
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
  made. A report function would write to a stream, which there was none
  of when this was decided; DEFINE-CONDITION still refuses one.
- A stack or a heap that is full is not an error in Common Lisp's
  sense, and neither is Ctrl-C: `(handler-case ... (error ...))` and
  IGNORE-ERRORS let them pass, as they do under SBCL, and a clause for
  STORAGE-CONDITION or SERIOUS-CONDITION takes them.
- Ctrl-C stops a computation where it can be stopped cleanly, at the
  evaluator's next safe point, as a condition that unwinds like any
  other, CLARA:KEYBOARD-INTERRUPT. The timer's tick takes in what is
  typed on the serial port, so that it is seen while the evaluator is
  busy.
- A thread that stands at a safe point holds no lock, because the thread
  that stopped the world may want any of them. That was a rule in
  comments; now a thread counts the locks it holds, and sleeping,
  joining or coming to a safe point with one is a panic.

## Lisp in the driver's seat (decided in M7, 2026-11-15)

- A Lisp thread is a thread of the substrate that evaluates
  (kernel/lisp/thread.c). It has a megabyte of stack for the evaluator's
  calls of itself, and the evaluator's two stacks to itself: its values,
  and its bindings of the special variables.
- One Lisp thread at a time has the runtime: the heap, the packages, the
  evaluator's own variables. It keeps it from one safe point to the next,
  and gives it up there when a tick has gone by and another thread wants
  it, or when it has to wait. So the C of the runtime is what it was with
  one thread: nothing in it takes a lock, and between two safe points
  nobody else is in the heap. It also follows that the collector, which
  runs in the thread that has the runtime, finds every other Lisp thread
  at a safe point without stopping anybody. The alternative, a lock on
  the heap and one on every table, with threads that can lose the
  processor in the middle of the runtime, is the larger half of a
  runtime for several processors, and this kernel runs on one. The price:
  a function in C that takes long holds every Lisp thread up, and a
  second processor would be of no use to Lisp. The substrate goes on
  taking the processor away at every tick; what it gives it to meanwhile
  is a thread that does not evaluate.
- A special variable keeps its value in the symbol, and what the symbol
  holds is what the running thread sees. When a thread makes way, its
  bindings are undone, the newest first, and when it comes back they are
  done again: a binding travels with its thread. A thread that has bound
  nothing sees the value that was there before anybody did, so a new
  thread starts with those and not with its maker's bindings, as under
  SBCL.
- Waiting is one mechanism in the substrate: a thread sleeps until
  another thread or an interrupt handler says that there is something
  for it to look at, or until a time has passed, and then it looks
  (`thread_wait`, `thread_wake`). A wake that comes before the wait is
  remembered, so a thread can put itself on record with what it waits for
  and then wait, with nothing held in between. Locks, events,
  `join-thread` and `sleep` are built on that in thread.c: a thread that
  waits gives the runtime up first.
- An interrupt reaches Lisp as an event. A handler cannot run Lisp and
  does not have to: it signals the event of its source, and the driver
  is a thread that waits for it. An event counts what a program signals;
  an interrupt that arrives while the last one has not been waited for
  is not counted again, as with an interrupt line.
- Nobody has to wait for a thread. When its function returns, when a
  condition comes out of it that nothing handled, or when it has been
  told to stop, what became of it stays in the object that Lisp holds,
  and a thread of the substrate's that does nothing else gives its
  memory back. Stopping a thread is asked of it, and done by it: at its
  next safe point, or out of the wait it is in, it leaves by way of
  every UNWIND-PROTECT, and no handler sees it go, because it is no
  condition. It is not stopped in the middle of the cleanup of an
  UNWIND-PROTECT, nor interrupted there: the cleanup runs to its end
  first, since what it is there to give back, a lock for one, would
  otherwise stay taken (found in M12, when Ctrl-C began to reach threads
  that hold locks).
- What the substrate offers that Common Lisp has no name for is in two
  packages. CLARA has the threads, locks and events, under the names
  that Bordeaux Threads made usual, a way to make a stream, and the
  condition that Ctrl-C is. CLARA.UNSAFE has what only a driver should
  touch (unsafe.c): memory by its address, the I/O ports of the machine
  that has them, page frames to share with a device, the events of the
  interrupts, and what the firmware said about the screen and the serial
  port. That is the one place where Lisp can make a pointer of an
  integer, so who uses it can be found by its name. It catches one
  mistake, an address where nothing is mapped; any other is a mistake in
  the kernel.
- A stream is two functions: one that is given a string to write, and
  one that gives the next line that was read. The printer, which is C,
  makes strings, and everything that writes is Lisp that hands one to a
  stream (lisp/boot.lisp). Generic functions would be the Common Lisp
  way, and there were none when this was decided; they are there since
  M20 ("Objects", below), and a stream is still two functions.
- There are two consoles. The substrate's (console.c, fbcon.c) prints the
  boot report, before there is a Lisp, and the kernel's last words, when
  there may be none left. The world's is Lisp (lisp/console.lisp), and a
  driver in the full sense: it sends each byte to the UART itself,
  through I/O ports on one machine and through memory on the other, and
  draws each character on the framebuffer from the font, which is Lisp
  data. The two draw the same cells, neither remembers what the screen
  shows, and both scroll by moving the pixels up, so all they hand each
  other is where the next character goes. A fault report takes the
  screen without asking, and clears it.
- Input stays half in the substrate. The timer's interrupt takes in the
  bytes that have arrived on the serial port, because Ctrl-C has to be
  seen while Lisp is busy, and signals an event; the console in Lisp
  waits for it, puts the line together and echoes it. While a line is
  being read, Ctrl-C is a byte like the others, which gives the line up;
  at any other time it stops what the thread is computing.
- The listener is Lisp (lisp/listener.lisp): it reads lines from
  `*standard-input*`, hands them to the reader until they hold a form,
  evaluates, and prints. The substrate starts it, and starts it again
  should a condition come all the way out of it.
- The files in lisp/ are developed and tested under SBCL as well.
  lisp/host/clara.lisp stands in for the substrate there: CLARA is made
  of SBCL's threads and Gray streams, and CLARA.UNSAFE is a machine that
  is a vector, with devices that are functions put at an address. The
  tests in lisp/host/tests.lisp load the same files and look at every
  byte the console sends, every pixel it draws and every key it is
  typed, which a boot cannot do. They also hold the names on both sides
  against each other: what boot.lisp exports from COMMON-LISP has to be
  Common Lisp's, and what the substrate has in CLARA and CLARA.UNSAFE has
  to have its stand-in. What they cannot say is whether the interpreter
  runs the files: that is what the boots are for.

## Devices (decided in M8, 2026-11-16)

- Devices are found, not assumed. The firmware's MCFG table says where
  the configuration space of the PCI devices is in memory, and Lisp reads
  it from there (lisp/pci.lisp): what is on the first bus, and what is
  behind every bridge. The firmware has been there before and has given
  each device addresses for its registers; they are taken as they are.
- A driver is Lisp, all of it, and the substrate gives it four things
  through CLARA.UNSAFE: where the configuration space is; a device's
  registers as memory, mapped at their own address like everything else;
  page frames whose address is their physical address, for what driver
  and device share; and an interrupt as an event to wait for.
- A device interrupts by sending a message: it writes a number to an
  address, and the interrupt controller makes an interrupt of the write
  (MSI-X). It never does so by a line. Which line of which controller a
  device is wired to is written in the DSDT, in ACPI's bytecode, and an
  interpreter for that is a larger thing than everything here that takes
  messages; a message needs no wiring to be known. The price is paid on
  AArch64, where what takes a message is one of two things, a GICv2m
  frame or the interrupt translation service with its tables and its
  queue of commands, and the kernel has to drive both: QEMU has the one
  under Apple's hypervisor and with GIC version 2, and the other when it
  emulates version 3. On x86_64 it is the local APIC, and nothing needs
  setting up. A device that cannot send messages cannot interrupt.
- The substrate keeps a table of the interrupts it has handed out
  (kernel/interrupt.c), and all a handler does is signal the event of its
  source. The driver is a thread that waits for the event, which is what
  M7 decided for every interrupt that reaches Lisp.
- Virtio is the one family of devices with drivers (lisp/virtio.lisp):
  version 1 of it, over PCI, with queues of the plain kind and nothing
  that a device merely offers. One file has what every virtio device has
  in common, the opening moves and the queues, and a file for each kind
  of device has the rest.
- A keyboard's driver turns keys into characters and hands them to the
  console, where they are read along with what the serial port brings. A
  key that types no character, an arrow or a function key, is handed on as
  well, as a code past the last that a character can have, and a key that
  is typed with Alt held has a number added to its code: one stream of
  integers serves a line at a prompt, which passes over what is no
  character, and an editor, which does not.
  Mice and tablets move one pointer, whose place is kept for whoever
  asks. Both can be sent to a function in place of that, a call for every
  character and for every change of the pointer, which is how the window
  manager has them. Each device has a thread of its own.
- A driver is tested twice. Under SBCL, against a device that the tests
  make up, registers, queues and messages and all, which is where its
  logic is looked at closely; and by booting, where `make test` types on
  QEMU's keyboard and moves its mouse, which says that the real device,
  the interrupt controller and the interpreter agree with the tests.

## Disks and files (decided in M9, 2026-11-17)

- A disk, to its driver, is a row of sectors and nothing else
  (lisp/disk.lisp, on virtio like the keyboard's). A request names the
  sectors and the memory, and the thread that makes it waits for the
  device's interrupt with the disk's lock in its hands, so one request is
  under way at a time. Queues of requests, and anything held back in
  memory, can come when something is slow for the want of them.
- What a disk reads and writes is page frames, not objects. The device
  goes by physical addresses, and the heap is somewhere else. A file
  system looks at what was read where it lies, a byte or a word at an
  address, as the other drivers look at their devices' memory, and Lisp
  gets what a file holds in one piece: its text as a string, or the page
  frames themselves for whoever can use those. The other way is the same:
  a text is written out into page frames, and those become a file. There
  is no vector of bytes yet for anything between the two.
- The first file system is FAT, because that is what the firmware boots
  from: the volume that the kernel came from is there to be read without
  another format having to be made up, on the tests' machines and in UTM
  alike. And it is there to be written to, which is what an image needs:
  a file that the firmware finds at the next boot.
- A file is written whole, and in an order: its bytes into clusters that
  are free, then the table that makes those clusters a file, in every
  copy of it, and last the entry in a directory that says where the file
  begins and how long it is. A machine that stops at any moment of that
  leaves clusters that belong to nobody, which a program that mends
  volumes gives back, and never a name that leads to what is not a file.
  A file that takes the place of another keeps the other's entry, and the
  other is whole until that entry changes. Nothing is written in the
  middle of a file, and what a program writes to a stream is kept until
  the stream is closed. There is no clock, so a file has no date but the
  first that the format knows.
- Volumes are found by looking: a disk that is one volume from its first
  sector on, the partitions of a table in that sector, the partitions of
  a GUID partition table. Which of the three kinds of FAT a volume is
  follows from how many clusters it has, as its specification says, and
  from nothing that the volume says of itself. Names are looked up on the
  first that was found, the one the machine was started from, until
  `clara.fat:*volume*` is given another: a second disk is how a user's
  files outlive the system's disk, which is made again for every newer
  system. The volumes are found again at every start, and a name is looked
  up on one of those and on nothing else: a volume that a saved world
  still holds from an earlier start knows a disk and a page frame that are
  no longer its own.
- A file is named by a string: the directories that lead to it from the
  root and then its own name, with a slash before each. There are no
  pathnames. Common Lisp's are a small language of their own, and what
  they are for, a name that means the same on every file system, is
  nothing this system needs while it has one. Letters match whatever
  their case, as FAT has it.
- The language's own functions for files, OPEN, LOAD, PROBE-FILE,
  DIRECTORY and DELETE-FILE, are in lisp/boot.lisp and know nothing of
  disks. A file system is four functions that it hands over when it has
  started (`clara:provide-files`): one that gives the text of the file of
  a name, one that gives the names in a directory, one that makes a file
  of bytes in memory, and one that deletes a file. That is the shape a
  stream has, for the same reason: there were no generic functions. A
  program written with those five runs under SBCL on the host's files.
- LOAD takes a file from the disk when the file system has one of that
  name, and otherwise from the files that the boot handoff read. Those
  stay: the world is loaded from them before there is any driver, and a
  machine whose disk has no driver here still starts. An image takes
  their place as what a world is made of, and they are read all the same,
  for the boot at which an image is refused.
- The disk driver and the file system are tested three times over. Under
  SBCL, on disks that the tests make up, which look at how they are
  asked, and on volumes that the tests lay out by the specification, of
  every kind, in pieces and back to front; a volume that was written to
  is looked at there by a checker of the tests' own, which reads its
  bytes without the file system, also after a disk that stopped at each
  request of a write in turn. By booting, on disks that tools/mkdisk.py
  makes, of the three kinds: the firmware reads what the kernel wrote,
  since it boots from it again, and after every boot the host's own
  program for mending FAT volumes has to find nothing to mend, which is a
  second opinion and a third. And by hand on volumes that macOS made,
  where its own driver reads the files back.

## Images (decided in M10, 2026-11-17)

- A world is saved by writing its heap out. Everything that is defined is
  an object in the heap, the heap is at the same addresses on every
  machine and every boot, and nothing in it is an address of the kernel's
  own: so the file is the heap word for word, with the substrate's hold
  on it, `lisp_roots`, and a few words that say what it is
  (kernel/lisp/image.c). Nothing is moved and nothing translated, on the
  way out or on the way in.
- An image is made at one moment: by a function in C that comes to no
  safe point, so that no other thread has the runtime while the heap is
  copied into page frames. Writing those to a file is Lisp's part, by way
  of the file system, like any other file (`clara:save-image`). The file
  is `\clara\clara.image` on the boot volume, and the boot handoff reads
  it with the other files there, before the kernel has a driver for
  anything.
- The machine is not in the image. A thread is a stack of calls in the
  kernel's code, which lies somewhere else at every boot and in every
  build, so no thread comes back, the one that saved included: saving is
  not a place that a world wakes up in. It begins again where a new world
  does, with the console, the drivers and the file system started afresh
  and the listener at its prompt, and with the window manager started
  again if it was running; what a driver knew of its device was true of
  another boot. So the same lines of C start a world that was
  loaded from the files and one that came as an image. The alternative, a
  world that goes on in the middle of what it was doing, needs the
  evaluator's own state in the heap, which an interpreter that calls
  itself in C does not have.
- What comes back of the threads, the locks and the events is the
  objects, without what they were to the substrate: a thread that ran was
  stopped when its machine was, a lock is free, and nobody waits for
  anything.
- A special variable comes back with the value it has outside every
  binding. Its value is in the symbol, and what is there while a thread
  runs is that thread's view: so for as long as the heap is copied the
  bindings of the thread that saves are undone, as they are whenever a
  thread makes way for another.
- A world is started by the system that saved it, and by no other (since
  M15a; until then an image outlived the kernel that saved it). A world
  holds the system's own Lisp as it was when the world was made: the
  console, the file system, the window manager. A newer kernel that went
  on in it would run under the older system's Lisp, with whatever the two
  no longer agree on, and nobody would have asked for that. So an image
  has its system's name in it, and a kernel of another system makes a
  world of its own files (Upgrades, below). A function in C is still in
  the heap as its place in a table and found again by its name, which is
  what lets a row be put anywhere in a table without a new format.
- An image is refused, with the reason in the boot report, and the world
  is made from the files as on a machine without one: when the file is
  not whole, by its length or by its checksum, which is taken of the heap
  where it lies after the copy; when it was saved on the other
  architecture, since what is defined in a world depends on the machine;
  when its objects are not laid out as this kernel has them, which is a
  number in image.c that a change to lisp.h has to raise; when it has
  a function in C that this kernel has not; and when another system saved
  it. The files are read at every boot for that reason, and stay in
  memory as before. An image that was started and did not come to its
  prompt is not started a second time: the handoff does not read it
  (Upgrades, below).
- A world that came as an image is not tested by the kernel. The tests
  of the reader, the collector and the evaluator are for a world that
  this boot has made, and somebody else's world is not the place to try
  what a new one has to be like. The first thing done in it is a
  collection: that frees what the threads held that are gone, and finds
  the free blocks of the heap, which are in no list in a file.
- Images are tested by booting twice. Each machine of `make test` ends
  its first session by saving the world to the disk it booted from, with
  a lock held, a thread waiting and names read in a package that uses no
  other; the second boot starts from a copy of that disk, has to say that
  its heap is an image, and answers for what the first one defined
  (tools/resumed.txt), the evaluator's whole self-test among it. One more
  machine boots from such a disk with a byte of the image changed, and
  has to refuse it.

## Drawing (decided in M11, 2026-11-17)

- Whatever is drawn is drawn on a surface: a rectangle of pixels in
  memory, 32 bits to the pixel (lisp/draw.lisp). The screen is one, whose
  memory is the framebuffer, and a program makes others. There is one way
  of drawing, whatever it is drawn on.
- A surface's pixels are page frames, not an object in the heap. The
  language has no vector of anything but Lisp values, a collector that
  walked megabytes of pixels at every collection would find nothing in
  them, and a saved world would carry every picture that was ever drawn.
  The price is the one that a driver's memory has: the collector does not
  give page frames back, so a surface is freed by whoever made it, and a
  world that is saved keeps its surfaces without their pixels. A surface
  that came back with a world is refused when something draws on it, since
  its address is somebody else's memory by then: each holds the machine it
  was made on, and that is made anew at every boot.
- Every surface has its pixels the way the screen has them, red, green and
  blue in the bits that the firmware said, so that copying to the screen
  is copying and nothing else. A colour is made a pixel once, when it is
  named, and what draws takes pixels.
- The substrate writes the pixels and Lisp says which. The interpreter,
  going from pixel to pixel, takes 80 ms over a screen of 800 by 600 where
  the processor is the host's own and more than a second where it is
  emulated; the substrate fills such a screen and copies it in a third of a
  millisecond. So three functions of CLARA.UNSAFE do a rectangle to the
  call: one fills it, one copies it, in the order that is right when the
  two lie over each other, and one makes pixels of a bitmap of one bit to
  the pixel, which is a glyph. What is left is the rasterizer, and all of
  it is Lisp: what a surface has of a rectangle, where a string's
  characters go and which of them show, what has changed.
- Everything is cut to what can be drawn on: the surface, and within it
  the part that drawing is kept to for the time being. A rectangle that
  lies half outside is drawn half, and one that lies outside is not an
  error; a function that draws says whether it drew anything. Whoever
  draws need not know where the edges are, which is what a window will
  want of what is drawn in it.
- A surface remembers what was drawn on it, its damage, as a few
  rectangles, and showing a surface copies those to the screen and
  forgets them. That is the whole of double buffering here: a picture is
  put together out of sight, on a surface that is not the screen, and what
  reaches the screen is what has changed, when it is whole. The
  rectangles are kept few by joining them, two that make one rectangle
  between them and, past a handful, all of them into the one around them:
  what is copied may be more than changed and is never less.
- The console is not drawn with any of this. It has the screen, as it had,
  draws its own cells and moves the pixels up when a line is full,
  whatever those pixels show: a picture on the screen scrolls away with
  the text around it. The console is the first thing that works and the
  last that should stop, and it pays some forty calls of the evaluator for
  a character as it is. The window manager takes the screen from it, and
  a console in a window draws the way everything else does ("Windows").
- The text that can be drawn is the console's font, in its one size. There
  are no lines but those along a row or a column, which are rectangles, no
  curves, no scaling, and nothing between a pixel that is drawn and one
  that is not. Each waits for the first thing that needs it. (Text was
  the first: "Fonts of outlines" has letters at any size, and with them a
  pixel that takes a part of a colour.)
- It is tested where it can be seen. Under SBCL the tests draw on surfaces
  of a machine that is made up and look at every pixel, against what the
  pixel should be by a rule that the tests write down themselves:
  rectangles, outlines, bitmaps, text and copies at every place on a
  surface and around it. The three functions in C are tried by the
  kernel's own self-test at every boot. And each machine of `make test`
  draws a picture on its screen, reads pixels of the screen back, and
  draws it again from the world that it saved, which is the picture on the
  website.

## Windows (decided in M12, 2026-11-18)

- A window is a surface and a place. Its program draws on the surface,
  which is the inside of the window, and says when it has; the window
  manager (lisp/windows.lisp) draws the frame around it, and knows where
  it lies and what lies over it. So a program draws in a window the way it
  draws anywhere, and never learns how much of it can be seen.
- Nothing draws on the screen. What the screen is to show is put together
  on a surface of the screen's size, out of sight, from the lowest layer
  to the topmost: the desk and the launcher's bar, the windows, the
  launcher's list, the pointer. Whatever changes says which rectangle of
  the screen it changed; those rectangles are put together again, and
  then copied to the screen. The price is the memory of a second screen
  and a copy. What it buys: nothing is seen half drawn, a window that is
  moved needs no help from its program, and the pointer needs no memory of
  what is under it, being the last thing that is painted. The topmost
  window whose inside takes in a whole rectangle hides the rest, so text
  that is printed in the window on top costs one copy, however many
  windows there are.
- The focus is the top. The window on top is the one that the keys go to,
  and a click brings a window there. One order is easier to hold in the
  head than two, and nothing yet needs a window that is typed in while
  another lies over it.
- Input comes to the window manager as calls, in the thread of the device.
  The driver of the keyboards calls a function for every character, and
  the driver of the pointers one for every change (lisp/input.lisp), each
  in the order in which its device said them: no press is lost between two
  looks at the pointer, and nothing waits for a thread of the window
  manager's, which has none. A window is told the same way: a key, a
  button on its inside, a click on its close box are functions that it was
  opened with, called in that thread, and they hand on what they are told
  to the window's own.
- A window belongs to the thread that opened it. Its pixels are page
  frames, which the substrate writes to without asking whose they are, so
  a surface must not be freed while somebody draws on it: the thread that
  draws is the one that closes, and anybody else may only when that thread
  is no more. The window manager reads a window's surface and never
  writes to it. Everything else, the windows there are, their order, the
  surface that the screen is put together on, is touched with one lock
  held, by whichever thread it is.
- An application is a name and a function, and running it is a thread
  that calls the function. The launcher lists the names. Whatever windows
  the thread has open when the function is done, or when the thread is
  stopped, are closed on its way out, so stopping the thread is how an
  application is ended, by its close box or by anybody. Applications are
  threads in the one world, with what protects any part of it from
  another: the language.
- The listener in a window is the console's listener with other streams.
  A terminal (lisp/terminal.lisp) is a window with a grid of cells and a
  stream, and puts its lines together with the console's own function for
  that. Each listener has a thread and a package to be in, and they share
  everything else, which is what one world means: what is defined in a
  window is defined at the serial port.
- Ctrl-C is for a thread. The serial port's goes to the thread that reads
  from the console, as it did. The keyboard's goes to the window that has
  the focus, whose terminal stops the thread that reads from it, by a
  function of the substrate that does to any thread what the serial port's
  Ctrl-C does to the first (CLARA:INTERRUPT-THREAD).
- The console keeps the serial port. When the window manager starts, the
  console lends it the screen and goes on without one, with its listener:
  that is how the tests type, and how a machine without a keyboard is
  reached. The substrate's console still takes the screen for a fault
  report, without asking.
- A world that was saved with the window manager running starts in it.
  Whether it ran is a variable of the world's, and the window manager's
  own function looks at it when the substrate calls it at every boot
  (RESUME): what it knew of windows and pixels is forgotten, the pixels
  and the threads having stayed behind, and it starts afresh, with one
  listener. A world that is made from the files starts at the console, and
  the window manager is started from there.
- The window manager has one key of its own, Tab with Alt held, which
  brings the lowest window to the top and so each in turn. Every other key
  is the focused window's, as it comes.
- It is tested where it can be seen. Under SBCL the tests have a rule of
  their own for what every pixel of the screen should be, from the windows
  there are and where they lie, and hold the whole screen against it after
  everything that is done, some two hundred times, most of them in an
  order that is drawn at random. The boots type on QEMU's keyboard into a
  window, take a window by its title with QEMU's mouse, launch from the
  list, close by the box, save the world, and start again in it.

## Applications (decided in M13, 2026-11-18)

- An application that comes with the system is a file, and not part of
  the world. The kernel loads the console, the drivers, the file system and
  the window manager as it starts, and leaves the editor and the file
  browser on the boot volume. The launcher knows each by a name and the
  name of its file, and loads the file when the application is first
  launched, in the thread that is to run it. So the world that starts is no
  larger for the applications it could run, an application can be changed
  while everything else goes on, and the first two are made the way that a
  third will be: nothing about them is the kernel's to know.
- The file says what it is. Its last form defines the application, under
  the name that the launcher has for it, the way the listener's file does
  for the listener. What a launcher would otherwise have to be told, which
  function to call, is then in one place, the file.
- Unloading is deleting packages. An application's file makes a package
  for what it defines, and the launcher notes which packages were not there
  before it loaded the file. To unload the application is to stop its
  threads, which closes its windows, and to delete those packages: nothing
  finds its functions by name any more, and the collector takes them when
  the last thread that was running one has gone. That is all the unloading
  a single heap needs, and all it can have: what something else still
  holds, stays.
- An application runs on what the language has. The editor reads and
  writes files with OPEN, and the browser lists a directory with DIRECTORY:
  neither knows of disks or of FAT. The price is what the language does not
  say, the size of a file for one, which the browser therefore does not
  show.
- A program takes what happens to its window in its own thread. The window
  manager's three functions for a key, a button and the close box are
  called in the thread of the device, where nothing may draw; a window that
  is opened to keep them queues what it is told, and its program asks for
  the next when it is ready (`next-event`). An application is then a loop:
  wait, change what it holds, draw. The terminal did by hand what this
  gives every window.
- One application starts another by its name, with arguments. The browser
  opens a file by launching the editor with the file's name, and holds no
  symbol of the editor's: either can be unloaded, or be another program
  altogether under the same name, without the other knowing.
- The editor's text is its lines, around the cursor. The lines above the
  cursor's are a list, the nearest first, the line itself is a string, and
  the lines below are a list in order. Whatever is typed is done at the
  cursor, so a character makes a new string of one line, and a new line, or
  a line that goes, is a cons, however long the text is. A vector of lines
  would be copied at every Enter, by an interpreter; a single string would
  be copied at every key.
- A window of text is drawn a row at a time, and only the rows that
  changed. Each of the two keeps what it drew in every row, as a string,
  and draws a row again when what it should show is another string. That
  is one comparison in the substrate for a row that stays, where drawing
  it is eighty calls. When the text moves up or down, the rows that stay
  are copied as pixels and what was noted moves with them.
- A file, to the editor, is lines with an end after each. The line with
  nothing in it after the last is where the text ends, and is not written.
  A file comes back as it was saved, and a text that was typed without a
  last Enter is a file that ends in a new line, like any other.
- The forms of a text are evaluated in a thread of their own. An editor
  that evaluated in its own thread would hear nothing while a form runs,
  not Ctrl-C and not its close box; so it starts a thread for the forms,
  waits for it, and stops it when Ctrl-C comes. What the forms define is
  defined in the one world, as with a file that is loaded.
- They are tested where they can be seen. Under SBCL each is driven key by
  key in the thread of the test, with no thread of its own to wait for, and
  every cell of its window is held against what its text or its list says
  it should show. The editor is also held against a second editor, written
  in the tests the slow way, a list of lines and two numbers, over hundreds
  of keys drawn at random. The files are the host's own there, since SBCL's
  OPEN is what an application calls under SBCL. The boots type on QEMU's
  keyboard into both windows, on the real file system.

## The compiler (decided in M14a, 2026-11-18)

- The compiler makes code for a machine that the substrate has, and not
  for the processor (lisp/compiler.lisp, kernel/lisp/vm.c). Four things
  follow. One compiler serves both architectures. Compiled code is data in
  the heap like any other, so a world that is saved holds it, and the rule
  that nothing can be run but the kernel image's code stays as it is. The
  collector stays precise, because such a machine keeps what it holds where
  the evaluator does. And an image still holds no address of the kernel's.
  Code for the processor would be several times as quick again, and would
  cost all four: two generators and their assemblers, memory that is
  written and then run, a way for the collector to know what a register
  and a frame of the processor's hold, and code in the heap that must not
  name where the kernel is. It can come later, behind the same first pass.
  (It came with M16a, behind the second pass and not the first, and most
  of the four did not have to be paid: Code for the processor, below.)
- The machine works on a stack, and the stack is the evaluator's value
  stack: a call of a compiled function is the function, its local
  variables and what its instructions push and pop, in one stretch of it.
  So nothing had to be taught to the collector, and a safe point means
  what it meant. An instruction is a word, a fixnum: the operation in its
  lowest eight bits and two operands above them. Bytes would be a quarter
  of that, and want a kind of object that the heap does not have; a word
  is read without taking it apart, and the vector that holds the
  instructions is a vector like any other.
- A compiled function means what the evaluator makes of its forms, which
  is the rule that the reader and the arithmetic go by: the same text must
  not mean one thing here and another there. So a function is found by its
  name at every call, and one that is defined again is the one that is
  called; nothing is put in the place of a call, however small the
  function, without a look whether the name still means what it meant (the
  instructions of M14b, below). The errors are the evaluator's, in its
  words and of its types.
  A form that is not what it should be does not stop the compiler: the
  code fails when it comes to the form, as the evaluator would. And the
  test is that rule: every text of the evaluator's self-test is compiled
  and run at every boot, and has to give the answer that the evaluator
  gave. The differences that remain are few and are written down: a
  DEFVAR counts for the forms that are compiled after it has been
  evaluated, as in a file under any Common Lisp, a macro that is defined
  again does not reach the functions that were compiled before, and the
  macros of a MACROLET run while their form is compiled, where the
  variables around them have no values yet.
- It is Lisp, in the world, in the part of the language that the evaluator
  has, and the evaluator runs it, until it has compiled itself (M14b,
  below). Walked, it takes half a millisecond for a small function, which
  is slow by a compiler's standards and was no obstacle: the 400 texts are
  compiled in under half a second. It works in
  two passes. The first makes a tree of a form in which nothing is left to
  look up: macros are expanded, a name is the variable, the block or the
  tag that it stands for, and what a function inside a function uses of
  the variables around it is noted. Only then is it known which variables
  are shared and which blocks are left from afar, and the second pass
  writes the instructions.
- A variable is a slot of its function's call, known by its number. One
  that a function inside uses is handed to that function when it is made,
  among the values that it closes over: the value itself when the variable
  is never set, and a cell that both hold when it is. The evaluator's
  frames in the heap, a vector for every LET, are gone from compiled code;
  what is left in the heap is what closures need.
- Leaving is the evaluator's way, by returning, so that an exit, a THROW
  or a condition passes through functions of both kinds without either
  knowing the other. What a compiled function has in force, a CATCH, a
  HANDLER-CASE, an UNWIND-PROTECT, a block or a tagbody that can be left
  from afar, is a record on the stack, and the way out goes through the
  records. A RETURN-FROM or a GO that stays inside its function and leaves
  nothing undone on the way is a jump, which is every loop. The compiler
  tells the two apart by a barrier: a function inside, the form and the
  cleanup of an UNWIND-PROTECT, and wherever the stack is as deep as some
  forms have values.
- A safe point is a call of a function in Lisp and a jump backwards. A
  function in C is called without one: it does not last, and the turn of a
  loop or the next call in Lisp is near. That is where compiled code gains
  most of what it gains after the variables.
- A macro's body runs when a call is expanded, and for compiled code that
  is while it is compiled. In M14a macros were the evaluator's and nothing
  was compiled unless somebody asked: DEFUN made a function for the
  evaluator, and COMPILE made it a compiled one. Both changed with M14b.
- Code is looked at before it is made a function: every operand has to
  name a constant, a variable or an instruction that is there. That the
  instructions use the stack as they say is the compiler's word, and not
  checked, so the function that makes a function of code is in
  CLARA.UNSAFE with the others that can bring the kernel down. Checking it
  is possible, by following every path through the code, and is what a
  machine that took code from strangers would have to do.
- Under SBCL the compiler is the same file, and the machine is a second
  one, written in Lisp the slow way (lisp/host/vm.lisp), which keeps a
  stack as deep as the kernel's and says so when code needs more than it
  claims. The tests there have a witness that the kernel does not: SBCL
  says what a form means, and what the compiler makes of the form has to
  give the same, for some 180 forms that were written and four hundred
  that are put together at random.

## A compiled world (decided in M14b, 2026-11-18)

- Whatever is typed or loaded is compiled before it runs. EVAL, and LOAD
  for every form that it reads, hand the form to the compiler once a
  compiler has said that it is there (`lisp_eval_form`, eval.c;
  CLARA.COMPILER:EVALUATE): the form is compiled and what that made is
  run. The listener, the editor and the launcher go through those two, so
  they needed no change. The other way would have been for DEFUN to
  compile and for everything else to stay with the evaluator. It was not
  taken, because a function is not only made by DEFUN: a closure made at
  the top of a file, a LAMBDA kept in a table, a loop typed at the prompt
  would have gone on being walked, and a world would have been compiled
  in parts. Evaluating a form by compiling it is also the path that the
  400 texts had been through since M14a.
- The evaluator stays. It runs lisp/boot.lisp and lisp/compiler.lisp when
  a machine starts from the files, since something has to run the
  compiler before the compiler has compiled itself; it evaluates the few
  forms that the substrate writes itself (`lisp_evaluate`); and it is the
  witness of the self-test, which holds compiled code against it. Nothing
  that a user types reaches it any more.
- The compiler compiles itself by being loaded a second time. A new world
  is made in this order: boot.lisp, walked, and the evaluator's texts;
  compiler.lisp, walked, and the same texts compiled by it; then
  compiler.lisp again, which LOAD now hands to the compiler form by form,
  so that the walked compiler puts a compiled definition in the place of
  each of its own as it goes; then boot.lisp again, compiled by a compiler
  that is compiled; the texts a third time; and the files of the world,
  which were never walked. So the two files are written to bear a second
  load, which is little to ask: a DEFVAR leaves alone what the first one
  made, and the rest says the same things again. The other way, to compile
  every function where it is from the form it was made of, needs a walk
  over all the symbols and leaves behind whatever a file put into a table
  as it was loaded. Doing it in the build, under SBCL, was looked at in
  M14a and left alone: it wants ClaraOS's macros under SBCL, which is a
  cross-compiler. Measured: the two files take 150 ms and the world 70 ms
  where the processor runs the code itself, 1.9 to 2.7 s and 0.8 to 1.2 s
  where it is emulated. A machine that starts from an image pays none of
  it.
- "Through and through" is checked and not hoped. When the world is
  loaded, the heap is gone through, and a function or a macro that the
  evaluator would still have to walk is a panic. The first run of that
  found two, of the self-test's own and held by nothing in the heap: the
  evaluator kept the clause that had last taken a condition, and the place
  that the last GO went to, where the collector looks, and the clause held
  on to a symbol, and the symbol to its package and every function in it.
  That had been so since M6c, and the heap had held 27 functions more
  than boot.lisp defines after every self-test. An exit that is over
  leaves nothing there now.
- A macro is a function of a form. DEFMACRO in compiled code makes a
  compiled function of one argument, the form that calls the macro, which
  takes the subforms apart itself by the way the compiler has for
  DESTRUCTURING-BIND, and fails in the words that the evaluator has for a
  macro that is called wrongly. It is made where the DEFMACRO stands, so
  it sees the variables there. The object is still a function of the kind
  LISP_MACRO; its code is that function where the evaluator's has a lambda
  list and a body, and whoever expands a call looks which it is. The
  macros of a MACROLET are compiled when the compiler comes to the form,
  and it calls them: they see the macros of the MACROLETs around them and
  no variable, as in any Common Lisp.
- The commonest functions in C have an instruction each, twenty of them
  (`car` to `svref`, vm.c). Such an instruction does the function's work
  for the arguments that it usually gets and calls the function for any
  others, so an error is the function's own, in its words. It does not
  look the name up, and still a function of that name that is defined
  again is the one that is called: a word has a bit for each of the twenty
  that says whether its name still means the function in C, and the one
  place where a symbol is given a function keeps the bits right
  (`lisp_set_function`). The dearer way was to look at the symbol's
  function at every such instruction, five loads where this is one. The
  price is a rule, that nothing else writes the function of a symbol, and
  the host tests read the sources to see that it holds. A world that was
  saved with one of the twenty defined again comes back with its bit off,
  which a session of the boot test does with `svref`.
- A safe point is a look at a word (`lisp_attention`, `safe_point` in
  eval.h). Whoever has something for a thread to look at there says so:
  the allocator when enough has been made for a collection, a thread that
  wants the runtime, whoever stops or interrupts a thread, Ctrl-C, and
  every interrupt, the timer's among them, so that what nobody said in so
  many words is seen within a tick. The call behind it clears the word
  before it looks, so nothing that comes up meanwhile is lost, and sets it
  again for what is still to be answered. And compiled code calls compiled
  code without the detour through `lisp_apply`.
- What it gained, where the processor runs the code itself: `(fib 30)` 100
  ms before and 80 after, five million additions in a loop 150 and 70, a
  million items pushed, reversed and mapped over 530 and 120, a small
  function compiled in 0.7 ms and in 0.1. The boot that collects at every
  safe point, emulated, took 110 s before M14a, 133 s after it and takes
  61 s now, because compiled code comes to a safe point at a call of a
  function in Lisp and at a jump backwards, where the evaluator came to
  one at every call. What is left is the call itself: a function is
  entered through some thirty lines of C that look at its lambda list
  every time, and a function of two lines, the reader of a structure's
  slot or `cadr`, costs as much to call as a long one. Putting such a
  function into its caller is the next thing to gain from, and wants an
  answer to what happens when it is defined again, as the instructions
  have one.

## Code for the processor (decided in M16a, 2026-11-18)

- The processor runs a compiled function itself, when it is asked to:
  lisp/native.lisp makes of the function's instructions the instructions
  of AArch64 or of x86-64. What is translated is what the compiler's
  second pass wrote, the machine's instructions one after the other, and
  not the tree of the first pass a second time, which is what "behind the
  first pass" had meant. A second generator from the tree would have been
  the compiler's second pass again, twice over: every special form with
  its records, its barriers and its counting of the stack, once for each
  processor, and three things to keep in step from then on. The machine's
  instructions are the place where all of that has been decided already.
  What the tree knows and they do not is little: that a value on the stack
  is about to be taken off again, and that a comparison is only wanted for
  a jump. Both can be seen in the instructions themselves by looking one
  ahead, and are left to be gained later.
- The processor does alone what a function spends its time on: its
  variables, constants and closed-over values, the stack, the jumps, calls
  and returns, and the instructions that stand for the commonest functions
  in C (`car`, `<`, `+`, `svref` and the rest, without `cons` and `*`) for
  the arguments that they usually get. Every other instruction is left to
  the machine of vm.c, which is called for that one instruction
  (`lisp_native_step`) and says where to go on. So records, exits,
  cleanups, bindings, the values of forms and every error are written
  once, in C, for both ways of running a function, and the two cannot
  come to mean different things. The price is a call into the kernel for
  such an instruction, which costs about what the machine spends on any
  instruction.
- A call keeps on the value stack what the machine's call keeps there, in
  the same places: the function, its local variables, then what its
  instructions push and pop. The machine's own two variables, the
  innermost record and the count of bindings, are two words after the
  local variables, in a function that makes records or binds special
  variables, and nowhere in one that does not. Nothing that the collector
  has to find is in a register across a call or a jump backwards, and the
  processor's own stack holds return addresses and no value. That is how
  the third of the four costs was not paid: the collector looks where it
  looked, and a safe point is what it was. The registers that such code
  keeps for itself are ones that a function in C leaves alone, so a call
  into the kernel saves nothing.
- One function of such code calls another without the kernel: a routine
  in entry.S looks at what is called, the function or the symbol that
  names it at that moment, and when it is such code too, and no safe point
  has anything to look at, goes straight on into it. The arguments stay
  where they were pushed and are the callee's first local variables as
  they lie. A function object has a word for where it is entered that way
  (`entry`), which is why a function is five words now. Anything else is
  C's: another kind of function, something that is no function, a safe
  point with something to look at, and the arguments of a lambda list
  with more to it than required parameters, which C sorts into the local
  variables in place.
- The code is not in the heap. Memory that is written cannot be run here,
  on AArch64 by the processor's own rule, and that rule was worth more
  than having one allocator. Code lies in a region of its own at fixed
  addresses, 1 GiB at 32 TiB, in pieces, mapped to be run and not to be
  written; the one function that writes there goes through the address
  that the same page frame has as RAM, where it can be written and not
  run. The heap has a small object for each piece (`LISP_NATIVE`), which
  the code vector of the function holds, and when the collector's sweep
  frees that object the piece is free. A piece that is freed is filled
  with what the processor refuses to run. On AArch64 the processor is
  told to forget what it remembers of memory that was written
  (`arch_code_written`).
- Code names no address of the kernel's, which is somewhere else on every
  boot. One register holds the address of `lisp_machine`, a struct with
  the words of the running thread that such code reads and writes itself,
  the top of the value stack, the exit under way, the word that a safe
  point looks at, the count of values, and after them the functions that
  it calls. The words were variables of eval.c and vm.c before, and are
  known there by the names they had. Where each lies the kernel tells the
  translator (`clara.unsafe:native-layout`), so the numbers are written
  once, in C. A world that is saved holds its code, word for word after
  the heap, and it is good on the next boot as it is; the order of those
  words is therefore part of what an image is (`FORMAT`, image.c).
- The translation is written once, for a processor that lisp/native.lisp
  makes up: eleven registers and some two dozen instructions. Each real
  processor has a file that writes those, lisp/arm64.lisp and
  lisp/x86-64.lisp, about a hundred lines, and a machine loads its own.
  What they write is held against LLVM's assembler, byte for byte, in the
  host tests.
- SBCL cannot run such code, so the witness is the kernel's: at every
  boot from the files the texts of the self-test are compiled, translated
  and run by the processor, on all three machines of `make test`, and
  have to give the evaluator's answers; one boot has the collector run at
  the safe points of such code; and when the texts are over no piece of
  code may be left. Under SBCL every function that the compiler's tests
  compile is translated for both processors and looked at as far as that
  goes without running it.
- In M16a nothing is translated unless somebody asks:
  `clara.native:translate` for a function, `clara.native:*translate*`
  for whatever is compiled from then on. The world itself is still the
  machine's, which is M16b. (It came the day after: A world for the
  processor, below.)
- What it gained, where the processor runs the code itself: `(fib 32)`
  takes 210 ms on the machine and 30 translated, five million additions
  in a loop 70 and 20, `(tak 22 16 8)` 30 and 10. A million items pushed,
  reversed and mapped over take 100 ms either way: the time goes into
  `mapcar` and `reverse`, which are the world's and not translated, and
  into making conses, which is left to the machine. The code is four to
  five times as long as the instructions that it was made of, 732 bytes
  on AArch64 and 828 on x86-64 for the 18 instructions of `fib`, because
  every instruction is translated by itself: a value is pushed and taken
  off again at once, and every instruction that can fail has its own way
  to the machine written out.

## A world for the processor (decided in M16b, 2026-11-19)

- Translating is the rule. Whatever the compiler makes is translated
  before it is run (`clara.native:*translate*` is true in every world), so
  a machine that starts from the files, or from a world that was saved,
  runs on its processor from the language's own functions to the window
  manager, as it ran on the kernel's machine before. The machine stays. It
  does the instructions that the processor's code leaves to it, it runs
  what is compiled while the variable is NIL and a function that is too
  long for a processor's jumps, and it is the second witness of the
  self-test, after the evaluator: the texts are run on it twice at every
  start from the files, before the translator is loaded.
- The translator translates itself by going through what is there, and
  not by being loaded twice like the compiler. lisp/native.lisp and the
  processor's file are loaded right after the compiler has compiled itself
  and lisp/boot.lisp, as code for the machine like those; then every
  function in the heap is translated (`clara.native:translate-all`), the
  translator's own first, so that the processor runs it while it does the
  rest, and every function object is given the place where the processor
  enters it. A second load would have translated the three files a form at
  a time and left behind whatever holds on to a function of the first
  load; going through the heap finds those as well, and it is also what
  `translate` needed to reach the closures that were made before their
  code was translated, which M16a had left open. A function that the
  machine is in the middle of a call of, the translator at that moment,
  finishes the call there: the machine looked at the function when the
  call began, and does not look again. Everything after that is compiled
  and translated a form at a time, by code that the processor runs.
- "Through and through" is checked as it was in M14b, by going through the
  heap once the world is loaded: a compiled function that the processor
  does not run is a panic there, like a function that the evaluator would
  walk.
- The translation is still one instruction of the machine's after the
  other, and looks no further than one instruction ahead and at what it
  has not yet written. A value that the machine would push is not pushed
  until somebody needs it on the stack. A local variable, a constant and a
  closed-over value stay where they are, and what an instruction made
  stays in a register, and the instruction that takes them as its
  arguments fetches them from there. Everything is on the stack wherever
  two ways through the code meet, at every call and wherever the collector
  can look, so that neither the collector nor the machine had to learn
  anything: an instruction that goes to the machine after all puts its
  arguments on the stack first, as the machine would have found them. A
  small integer that is written into a function is written into the code.
  A comparison whose value is wanted by the jump after it and by nothing
  else is one comparison and one jump of the processor's, and no T or NIL
  is made. The way to the machine is written once for a function and
  called from the instructions that need it, three instructions each
  where there were ten. A cons, a cell and a closure are made by a
  function in C that the code calls as it stands, with nothing of the
  stack handed over. And an instruction that stands for a function in C
  no longer says that it made one value when the next instruction takes
  the value for itself, since nobody reads it then.
- CASE compares its keys with EQ where that is what EQL comes to, for
  symbols and integers, which is nearly every CASE in the system and every
  one in the translator. EQ is an instruction, and with the jump after it
  a comparison of the processor's; EQL and MEMBER are calls. It was
  measured before it was changed: the translator spends its time going
  through CASE forms of thirty clauses, once for every instruction that it
  writes.
- What it costs to start from the files. Where the processor runs the code
  itself, the language, the compiler and the translator are translated in
  100 ms, 450 functions, and the rest of the world is compiled and
  translated in 90 ms, where compiling it took 60; the texts of the
  self-test take 110 ms where they took 200. Where x86-64 is emulated,
  those are 2.1 s, 2.3 s where it was 0.7, and 1.5 s where it was 3.1.
  Translating a small function takes about five times as long as compiling
  it, 0.06 ms against 0.01, because the translator makes a list for every
  instruction of the processor's and goes through it twice. A machine
  that starts from an image pays none of it.
- What it costs in memory. The code for the processor of the whole world
  is 700 KiB on AArch64 and 830 KiB on x86-64, beside a heap of a mebibyte
  in use, and an image is that much longer: 3.2 MiB where it was 2.2. A
  function keeps the compiler's instructions too, which the listing shows
  and the machine needs for the instructions that are left to it.
- What it gained, where the processor runs the code itself: `(fib 35)`
  takes 750 ms on the machine and 70 translated, fifty million additions
  in a loop 610 and 70, `(tak 22 16 8)` ten times over 240 and 20. A
  million items pushed, reversed and mapped over take 60 ms on the machine
  and 50 translated: `mapcar` and `reverse` are the processor's now, and
  what is left is the making of a million conses and their collection,
  which the translation does not touch. The code of `fib` is 560 bytes on
  AArch64 and 660 on x86-64, where it was 732 and 828.

## Upgrades (decided in M15a, 2026-11-20)

- A system is one build: two kernels and the Lisp files that they were
  built with. It has a name, its version and eight digits worked out from
  every source that goes into it (tools/system.py), so the same sources
  are the same system wherever they are built and any change is another.
  The version alone would not do: a version is one number for many builds,
  and what has to be told apart is builds.
- On a disk a system is a directory, `\clara\<name>`: its Lisp files, a
  copy of its two kernels, and a manifest that lists them all, each with
  its length and its SHA-512. The kernel has its system's name in it and
  reads the files of that directory and no others (kernel/boot.c). So two
  systems lie side by side on one volume without either seeing the
  other's files, which is the whole of what makes an upgrade safe: a
  kernel is never started with Lisp that it was not built with. The world
  that was saved, `\clara\clara.image`, is outside those directories and
  has its system's name inside it.
- An upgrade is done by the system that is running (lisp/system.lisp). It
  takes the directory of another system from another disk, any disk that
  ClaraOS starts from being such a disk, holds every file against the
  manifest as it comes, and writes the manifest last, which is what says
  that a system is whole. Nothing else on the volume is written to. A
  machine that stops at any moment of that starts as it did before.
- The newer system is tried before it takes the old one's place. The
  upgrade ends by writing one line into `\clara\next`, "try" and the
  system's name, and starting the machine again. The firmware starts the
  kernel that it always started, the old one, whose handoff reads the
  line, writes "tried" in its place, and has the firmware load and start
  the new system's kernel from its directory, in place of itself. When
  that system has come to its prompt it puts its kernels where the
  firmware looks for them, each in the one step that writing a file over
  another is, takes the line away, and then the old system's directory.
  When it does not come to its prompt, the machine is started again by
  whoever is there, the old kernel reads "tried", and goes on as itself,
  in the world that it saved before the upgrade: the old system was never
  touched. So the kernel that the firmware starts is always one that has
  come to its prompt on this machine, until a newer one has.
- There is still no boot loader. What chooses between two systems is the
  first few hundred lines of the kernel that is in place, while the
  firmware's services are there, and it chooses once, on a line that the
  system itself wrote.
- Every start is counted before it is known how it goes. The handoff
  writes `\clara\starts`, through the firmware's file system, with how
  many starts in a row have not come to a prompt, and the world deletes
  the file when it has come to its prompt. A start that finds the file
  knows that the one before it did not get there, and is more careful:
  the saved world is passed over, and a new one made from the files. That
  is the key that was missing since M10, for a world that was saved in a
  state which does not start; it needs nobody at the keyboard at the right
  moment, only that the machine be started once more. It has to be the
  firmware that writes, since the point is that it holds when no Lisp
  runs.
- The same file says which volume the machine was started from. The
  handoff puts a number into it that no other start was given, the kernel
  knows the number, and the volume that has it is the system's own,
  wherever its disk is on the bus. Until this, the first volume on the bus
  was taken for it, and a second disk in front of it was mistaken for the
  system's.
- The manifest is a text that a later system may add to: a reader passes
  over every line that it does not know. The upgrade of one version reads
  the manifest of the next, so its form cannot be changed, only extended.
- `make run-*` goes the same way, which is what keeps the mechanism
  honest. The machine's disk is made once and kept. When the build is
  another system than the one on it, tools/run.sh gives the machine the
  build as a second disk with a file on it that says "at once", and the
  system takes it as it starts and starts again by itself. A system that
  was tried that way and failed is not taken a second time unasked.
- What does not come across is the world. The newer system does not start
  the older one's image (Images, above), and makes a world of its own.
  What was defined at a prompt comes across as text (Work kept as text,
  below), and what the variables had come to, as far as that is text (A
  world made again, below).
- Upgrades are tested by doing them. The build makes two more systems of
  the same sources under other names, one of which has a boot.lisp that
  is no Lisp. A machine of each kind of processor takes the good one and
  has to come up as it, by way of the old kernel, with the files that
  were written before; a machine that takes the bad one has to be the old
  system again after it is reset; and a world that is saved standing still
  before its prompt has to be passed over at the next start. Under SBCL
  the same procedures run on volumes that the tests make up and look at
  afterwards without the file system.

## Work kept as text (decided in M15b, 2026-11-20)

- A world is kept two ways. The image is the heap, quick to start and
  good for the system that saved it and no other. The text is what was
  typed, which every system reads. So what a user defines is written down
  as text as it is defined, without anybody asking, and a world that is
  made from the files is given that text.
- It lives in `/home`, on the volume that the machine was started from.
  The directory is the user's: no system writes there but for one file,
  no upgrade touches it, and a system makes it at its first start, so
  neither `make image` nor tools/mkdisk.py knows of it. It is on the boot
  volume, and not on a disk of the user's own, because a machine may have
  no second disk, and because the text has to be where the system that
  reads it is: an upgrade in place leaves both where they are.
- Two files there. `init.lisp` is the user's to write, for whatever a new
  world should begin with. `defined.lisp` is written by the listeners
  (`clara.listener:*record*`, `clara.system::record`): a form that was
  typed at a prompt, at the top and not inside another, that was
  evaluated without an error, and that defines something. The file is
  plain Lisp, and the user's to read and to change.
- What "defines something" means is decided by the form's first word,
  since nothing short of evaluating a form says what it does: a word that
  begins with DEFINE-, whatever it names, as the window manager's
  DEFINE-APPLICATION, which is a function; a word that begins with DEF
  and is one of the language's own or a macro, which is what a defining
  form is called, the user's own among them; and LOAD, since what a file
  defined is in none of the forms that were typed. A function whose name
  happens to begin with the three letters, DEFAULT-SIZE, is called and
  not written down.
- What takes a definition back is not written down, with one exception:
  the window manager's two functions that take an application or a
  command out of the launcher's list take the form that put it there out
  of the file. Without that, an application that was tried and removed
  was there again in the next world, which nobody would have expected of
  a function called remove. DELETE-PACKAGE and whatever else undoes a
  definition are left to the user and the editor: the file is theirs.
- A form is kept as it was typed, comments and all, and not as the
  printer would write it: the text is for a person to read. A form that
  defines a name again takes the place of the earlier one, so the file
  holds each definition once, where it was first made, and does not grow
  with every correction. Which name a form defines is its first two
  words, in the package that it was read in; a line `(cl:in-package ...)`
  stands wherever the package changes.
- A world that was made from the files loads `init.lisp` and then
  `defined.lisp`, a form at a time. A form that fails is said, with the
  reason, and passed over, and the rest goes on: the forms were written
  under another system, and one that this system does not understand must
  not keep a world from being made. When the form that fails is the one
  that says which package the next ones are read in, those are passed
  over with it: read in another package they would define other names.
- Nothing in the text may keep a machine from its prompt. Each file is
  loaded by a thread that is given a minute (`*patience*`) and is stopped
  after it. A LOAD of one of the two files from one of them is refused,
  since the file would load itself without end. And after two starts in a
  row that did not come to a prompt the text is not loaded at all: the
  first such start costs the image (Upgrades, above), the second the
  text, and the third is the system's files alone.
- A world is saved on the volume that the machine was started from,
  wherever names are looked up at the moment (`clara.fat:*image-volume*`):
  a machine looks for an image there and nowhere else. Until this, a
  world saved while `clara.fat:*volume*` named another disk was an error,
  or a file that no start found.
- What is not text is not kept by this: the value that a variable came to
  after it was defined, an object that was built by hand, whatever a form
  did that was no definition. The next section is about those.

## A world made again (decided in M15c, 2026-11-20)

- A world is two things on the disk, the image and the text, and the two
  are kept in step. A world knows which text it has: each of the two
  files as it last loaded or wrote it. A start in a saved world holds the
  files against that and loads the forms that the world does not have:
  what was defined after the world was saved, on a machine that then
  stopped without saving, and what somebody wrote into a file since. So a
  machine that has its plug pulled loses no definition, with an image or
  without one. A form that the world has is not evaluated a second time.
- After an upgrade the world is made again, and saved without anybody
  asking. The newer system makes a world of its own files, loads the text
  into it, and saves it, since the world on the disk is the old system's
  and of no use to it. The next start is then as quick as before the
  upgrade.
- What the text does not have is known to the world that is leaving and to
  nobody else. So that world leaves an account of itself for the system
  that is to be tried, as its last act before the machine starts again
  (`carry`, from the shutdown): which functions and variables there are in
  the packages that are the user's, and of the variables the values that
  can be written as text and read back the same, numbers, characters,
  strings, symbols and lists of those. The system that comes gives the
  variables those values, after the text has defined them, and says what
  it found: which variables have the values that they had come to, which
  held something that is no text, a function, a lock, a window, and are
  as their forms make them, and which names of the old world are not
  defined in the new one at all. That is the whole of "what did not come
  across", by name, and it is kept in the world and said again when it is
  asked for (`clara.system:report`).
- The account is a text of the same kind as the manifest: forms of
  keywords and strings, one to a line, of which a reader passes over the
  ones it does not know. It is written by one system and read by the
  next, so its form is only ever added to. It is for one start, the trial
  of the system that it names, and is deleted by any other.
- What is the user's is what is in COMMON-LISP-USER and in the packages
  that were made after the world was, apart from the ones called CLARA,
  which the launcher makes when it loads an application of the system's.
  A value is carried when it reads back as an equal value, which is tried
  before it is written; nothing is said to be text on trust.
- No converter from one layout of the heap to the next was written, and
  none is needed: the old system knows its own objects and writes text,
  and the new one reads text. What cannot be text is named and left
  behind.
- The window manager is started in the new world when it was running in
  the old one, before the text is loaded, so that a form of the text which
  opens a window finds a screen to open it on.
- A saved world that does not come to its prompt is replaced, the second
  time. The first time the handoff passes it over, a world is made of the
  files and the text in its place, the saved one is kept and the next
  start tries it again: one start that did not come to a prompt may have
  been anything, a machine that was switched off as it started. A note of
  which world it was stays on the disk. When the same world is passed over
  again, it is the world that is at fault, and the one that was made
  takes its place. A saved world that comes to its prompt takes the note
  away.
- After two starts in a row that did not come to a prompt, the world is
  the system's alone and follows no text: nothing of `/home` is loaded
  into it by itself, then or at a later start, until the user has put the
  files right and asks (`clara.system:load-home`).

## The network, and a system fetched over it (decided in M15d, 2026-11-20)

- There is a network because a newer ClaraOS should be fetched and not
  carried, and there is as much of it as that takes (lisp/net.lisp): a
  machine that asks and does not serve, over IPv4, with one card. The
  driver is for virtio's network card, on lisp/virtio.lisp like the disk's;
  above it are ARP, IPv4 without pieces, UDP for DHCP and DNS, TCP, and
  HTTP as far as fetching a file goes.
- A frame is put together and taken apart where the card reads and writes
  it, in page frames, a byte at a time, since the wire has its numbers the
  other way round from the processor. One thread takes what arrives, hands
  it up through the protocols and answers what is answered at once.
  Whoever waits for something is told to look, looks, and asks again every
  second until an answer comes or patience ends: nothing waits for one
  particular packet. The sums that the protocols make of every byte are
  added up in C (`clara.unsafe:internet-sum`), which is a loop and nothing
  more.
- The machine asks which address it has when something first wants the
  network, and not as it starts. A machine that fetches nothing sends
  nothing, and a boot is no slower for having a card.
- TCP is the client's half. What arrives goes into one stretch of page
  frames that grows, each piece where it belongs: a piece that comes
  before the one that is missing is kept for when the gap is filled, so a
  lost piece costs the other side one piece and not everything after it.
  Every piece is answered with how far the bytes have come without a gap,
  which is how the other side learns what to send again. What this side
  sends is one request of a few hundred bytes, so it has no need of the
  rules by which a sender finds out how fast it may send.
- There is no encryption, and what replaces it is a signature. TLS would
  be the largest thing in the system: an exchange of keys, ciphers,
  certificates and their chain to a root, the time of day to hold them
  against, which the machine does not know, and arithmetic on numbers of
  thousands of bits. What an upgrade needs is less than what TLS gives:
  not that nobody reads a system which is published for everybody, but
  that what arrives is what was published. So a release is signed, and
  the road is not trusted at all. That is as far as M15d went, and it was
  not far enough: Julio's word on it (2026-11-20) was that ClaraOS is not
  published over plain HTTP ("we don't do that here"). M15f is the
  answer: TLS, under the signature, which stays. A release is fetched by
  HTTPS and from no other kind of address (below).
- A release is a system as a disk holds it, a directory with its files
  and its manifest, on a web server, and beside the manifest a signature
  of it (tools/release.py): Ed25519, whose check is five hundred lines of
  C that need nothing but SHA-512, which the kernel has (kernel/ed25519.c,
  `clara.unsafe:ed25519`). The manifest has the sum of every file, so the
  one signature covers all of them. The system that fetches holds the
  manifest against the signature with the public half of the key, which
  is in the system (`clara.system:*release-key*`), and every file against
  the manifest as it arrives, exactly as it does with a system from a
  disk: taking a system is one function, which is given a way of reading
  a file by its name (`take`).
- Which release is the newest is said by a file that is not signed. That
  is enough: whoever changes it can name another release that was really
  published, and no more, since any release is held against its
  signature and its manifest names its system. A system that is no newer
  than the one that runs is not taken unless somebody asks for it by
  saying so (`:any t`), so nobody can send a machine back to an older
  ClaraOS by changing that file. Withholding everything is what remains,
  and nothing protects from that.
- A system without a key takes nothing over the network, and a system
  that knows of no place where ClaraOS is published looks nowhere: both
  are variables, which were empty until there was a key and a place.
  Since 0.0.31 the system has both (below).
- Signatures are checked here and never made. The secret half of the key
  is with whoever publishes, in no repository and on no machine that runs
  ClaraOS.
- The network is tested against a network. Under SBCL the tests make one
  up at the other end of a made-up card's wire: it answers for ARP, DHCP
  and DNS, serves files over a TCP of its own, holds every frame that the
  machine sends against checksums that it works out another way, and
  loses, spoils and mixes up what it sends when a test says so. On a real
  kernel, QEMU's own network is at the other end, and a web server and a
  name server on the host (tools/serve.py), from which a machine fetches a
  signed release of another system and has to come up as it. The check
  of signatures is held against the examples of RFC 8032 at every boot.

## Where ClaraOS is published (decided 2026-11-20)

- The place is the website: `https://claraos.org/releases/`, which was
  Julio's choice. It answers HTTPS as it is, so nothing had to be set up
  or switched off for it, and a deployment was there already. The system
  has the address in it (`clara.system:*releases*`), and the public half
  of the key that what is published there is signed with
  (`clara.system:*release-key*`): the two came in one change, since a
  system with a place and no key would ask and then take nothing.
- A machine asks there when it is told to upgrade and no other disk of
  it holds a system, and at no other time: nothing looks for a newer
  ClaraOS by itself. It says where it looks before it does. That is the
  one address which a machine asks without somebody having typed it.
- A system without a key asks for nothing. The key is looked for before
  the network is: whatever came could be held against nothing.
- What is published is the system of main's newest commit. Pages puts a
  whole site in the place of the one before, so every deployment has to
  carry the release, and the website's workflow builds it, each time,
  from the commit that it publishes the pages of
  (.github/workflows/site.yml). There is one release there, the newest,
  and no history of them: a machine only ever asks for the newest.
- The secret half of the key is a secret of the environment that the
  site is deployed from, which takes deployments from main and from no
  other branch. So what can be signed is what was merged, and a pull
  request cannot read the key, whatever it changes in the workflow. The
  price is that the publishing cannot be tried before a merge. What can
  be tried is everything but the secret: the laying out and the signing
  are `make release`, which `make test` runs with a key that it makes
  (`make release-test`).
- `make release` lays nothing out with a key whose public half is not the
  one in the source, and holds what it did lay out against that half,
  with the check that a machine makes, before anything is uploaded. A
  secret that holds another key therefore publishes nothing: the job
  fails, and the site that is there stays, with its release.
  The same for a secret that is missing, since a site without a release
  would take away the one that machines are told to look for.
- No test asks the place. What is tested is a system that knows of none,
  or of one on this computer: the tests are to say the same thing with
  the Internet and without it, and the website is not theirs to load.

## A connection that is kept closed (decided in M15f, 2026-11-20)

- HTTPS is there because plain HTTP is not how a system is published, or
  how anything else is fetched that matters: what a machine asks for is
  nobody's to read on the way, and which release is the newest is said by
  a file that nobody signed. TLS closes both (lisp/tls.lisp). The
  signature of a release stays under it: the connection says that this is
  the web server that was asked, and the signature that the release is
  its publisher's, whoever serves it.
- TLS 1.3, and nothing older (RFC 8446). A version that was made after
  twenty years of mending the ones before is the one to write once: one
  round of greeting, no ciphers that are known to be weak to refuse, and
  every server that matters speaks it. Of what it allows, one of each:
  X25519 for the exchange of keys, AES-128 in Galois/Counter Mode for the
  records, SHA-256 under the keys. The cipher is the one that every TLS
  1.3 has to have, so no server is left out for it; the exchange is one
  that a server should have and nearly every one has, and a server that
  has not is told so.
- The arithmetic is the substrate's and everything else is Lisp, as with
  SHA-512 and Ed25519: sums, HMAC, AES in its mode, X25519, a number to a
  power, and the signatures of the two curves P-256 and P-384 are C
  (kernel/sha256.c, hmac.c, aes.c, ed25519.c, bignum.c, ecdsa.c), each
  held against the examples of its standard at every boot, and each a
  function of CLARA.UNSAFE on bytes of memory. What the bytes mean is
  Lisp: the pieces of a certificate, the greeting, the records, and the
  two ways in which RSA pads a signature. It is written here and not
  taken from a library, like everything else in the system. What stands
  in for the review that a library has had: the examples of the
  standards; the same arithmetic a second time, in SBCL's big numbers,
  which the host tests hold against the same examples; a third time in
  Python, against which the C was run on two thousand numbers made at
  random, once; a web server of OpenSSL's at the other end in the boot
  test; and the certificates of Mozilla's list, which are a hundred
  signatures that nobody here made.
- Nothing in the checking of a signature is a secret, so none of it takes
  care to take the same time whatever the numbers are. What is a secret
  is this side's number in the exchange of keys, and the keys: X25519 does
  the same work for every number, and the multiplication of the mode's
  tag has no branch. AES is written with its table, so its time depends a
  little on the key, which somebody who shared the processor's cache
  could measure: nobody does, since the machine runs one world.
- Who the other side is: a certificate for the name that was asked for,
  good today, signed by somebody whose certificate is good today and who
  may sign, and so on up to a certificate that the system trusts (RFC
  5280, as far as the web uses it). The ones that it trusts are Mozilla's
  list, as curl publishes it, a file of the system (lisp/roots.pem): the
  same authorities that a browser believes, and no list of this system's
  own making, which nobody would keep up. The list is the system's, so an
  upgrade is what renews it. The user can add to it (`clara.tls:trust`),
  for a server of their own. What a certificate says that has to be
  understood and is not understood here makes it one that is not taken.
  Whether a certificate was taken back since it was signed is not asked.
- A certificate is good from one day to another, so the system has to
  know the day. It asks the firmware's clock once, in the handoff, and
  counts on from there with its own ticks: there is no driver for a clock
  (`get-universal-time`). A machine whose clock is wrong takes no
  certificate, and the error says what the clock says.
- The keys of a connection are made of numbers that nobody can guess, and
  a machine that computes has none of its own. They come from virtio's
  device for that, which hands on the host's (lisp/random.lisp), and are
  used as they come: nothing is kept of them and nothing is made of them
  by a rule, since a world that is saved and comes back twice would make
  the same numbers twice. A machine without the device fetches nothing by
  HTTPS, and says why.
- What arrives is opened where it lies, in the memory of the connection,
  and what the other side said is moved to the beginning of that memory
  as it is opened: always behind the place that the next record is read
  from, since a record is longer than what it carries. So HTTP finds its
  answer where it always did, and the file that is fetched is in the same
  page frames at the end. lisp/net.lisp knows of TLS only that there are
  six functions for it, which lisp/tls.lisp hands over when it is loaded
  (`clara.net:*secure*`).
- A file whose length nobody said is over when the connection is. On a
  connection that is kept closed the other side has to say that it is
  done, in a record like any other; an end without that word is an end
  that somebody on the way may have made, and the file is not taken. That
  is what TLS says, and stricter than most programs are.
- A machine goes from an address that is not kept closed to one that is,
  when a web server sends it there, and never the other way.
- A release is fetched by HTTPS only (`clara.system:upgrade :from`). What
  M15d built for plain HTTP stays for `clara.net:fetch`, for a web server
  on one's own computer: it is no way to publish, and it is not shut off.

## The rest of a network (decided in M17a, 2026-11-21)

- What a connection sends is looked after by the thread of the card.
  Until now whoever had something to say sent a piece and waited for the
  word that it had arrived, which does for a request and for nothing
  longer: the other side waits a while before it says that one piece
  has arrived, in case a second follows, so a piece went out every
  twentieth of a second at best. Now what is to be sent lies in memory
  of the connection's until the other side has it. Whoever says
  something puts it there, and the thread that takes what arrives sends
  more as the other side makes room, sends again what was lost, and
  gives up when nothing comes back. `say-bytes` still returns when all
  of it has arrived, which is what a request wants, so HTTP and TLS are
  as they were.
- That thread still waits for nobody, and it now also acts when nothing
  arrives: it looks at what time has brought about (`tend`) twenty times
  a second while there is a connection, four times while the machine has
  an address to keep, and once a second on a machine that has nothing to
  do with its network, which should pay next to nothing for having one.
  Since it cannot wait to learn which card has an address, it sends that
  question, drops what it meant to send, and comes to it again at its
  next turn.
- Bytes go out with the connection's lock held, because the memory that
  they lie in moves up when the other side says that it has some of
  them. So nothing waits for the network with that lock: whoever puts
  bytes there has asked who has the other side's address before, and
  inside the lock an address that nobody has claimed is an error and not
  a wait (`*waits*`).
- How much is on its way at once is a rough answer to a question that
  has careful ones (RFC 5681): ten pieces at first, one more for every
  word that more has arrived, half after the other side has said three
  times that it lacks a piece, one piece after a silence, and never more
  than the other side has room for. A piece that is missing goes out
  again as soon as the other side says so three times, and after a
  second otherwise, then two, then four; when more than one piece was
  lost, each word that some more has arrived sends the next that is
  missing (RFC 6582). A side that has no room is asked with one byte
  whether it has some again.
- A connection ends in the background. Whoever is done with one says so
  and goes: the word that this side is done is sent behind what is
  still to be sent, and sent again like any piece, the other side's
  word is taken, and then the connection is forgotten, or after as long
  as patience is when the other side says nothing. What arrives for it
  after its owner has gone is answered with the word that nobody takes
  it. The patience is the owner's: a thread that looks after the
  connections of others has its own bindings of `*patience*` and
  `*again*`, so each connection keeps the ones of whoever last used it.
- What other machines say about this machine's packets (ICMP) is
  anybody's to send, and is believed as far as it can be held against
  something that an outsider would have to guess. The word that a
  machine cannot be reached ends a connection that is beginning, when
  the word has that connection's number; it does not end one that is
  open. The word that a packet was too long makes the pieces of that
  connection shorter, which costs time and nothing else when it is a
  lie. The word that a connection is given up (TCP's own) is taken when
  it has the number that is expected next.
- The numbers that tell one exchange from another, the number that a
  connection counts its bytes from, the number of a question, the port
  that it is asked from, are from the device that makes numbers which
  nobody can guess, when the machine has one (lisp/random.lisp). They
  were worked out from the clock, which somebody who wants to put a
  word in from outside can do as well.
- A port that a connection spoke from rests for two minutes before
  another speaks from it (added with M18a, 2026-11-21, which found the
  need). The other side remembers a connection that is over for a while,
  by the two addresses and the two ports, so that a piece of it which
  comes late is not taken for something new; a beginning from the same
  port is such a piece to it, and gets no answer. A port that is picked
  by chance comes up a second time sooner than it seems: one time in ten
  among fifty connections to one place. Two minutes is what the other
  side's memory is at its longest in the systems that are met, and of
  16384 ports a hundred and thirty connections a second can be begun
  with that.
- The machine keeps its address by asking the server that gave it,
  from half the time on for which it was given. When the time is over
  without an answer, the address is given up, and whatever wants the
  network next asks for one as a machine does that never had one.
- The name servers are asked in turn, a second apart, and the next at
  once when one says that it cannot say or the word comes back that it
  takes no questions. An answer that says of itself that it was cut
  short is asked for again by TCP. What is known of a name is forgotten
  when the time is over that the answer gave it.
- The network that the tests make up learned the other side of each of
  these: it answers a ping and says when something cannot be reached or
  was too long, gives an address for a time and is asked for it again,
  has two name servers that can refuse, fail or cut an answer short,
  loses pieces that the machine sends, says how much room it has, and
  fails the run when more arrives than that. On a real kernel QEMU's
  network is at the other end, which brings about less of it; ROADMAP.md
  says which three things no kernel was seen to do.

## A machine that listens (decided in M17b, 2026-11-21)

- A connection is handed to a program as a stream, and a stream here is
  two functions, one that writes a string and one that reads a line. So a
  connection is lines of text to whoever has it. That is what the
  Internet's older protocols are made of, and it is all that the
  language can say about a stream; bytes that are no text would need
  another kind of stream, which is not here.
- Nothing is taken at a port until somebody says so (`serve`), and what
  is taken is handed to a function of the user's, each connection in a
  thread of its own. The card's thread answers the beginning of a
  connection, since that is something that is answered at once, keeps
  what TCP needs of it, and starts the thread when the other side has
  said that it heard the answer. Nothing of the user's runs in the
  card's thread. A port takes as many connections at once as it was told
  (eight), and a machine that asks for one more is told that there is
  none, which it hears at once, and does not wait for an answer that is
  not coming.
- What the function ends in, when that is an error, is kept and not
  printed: another side that goes away in the middle of a line is an
  everyday thing for a machine that listens, and the prompt is no place
  for it. `(clara.net:serving)` shows the last one.
- Reading takes from the front of what has arrived. The memory is put in
  order, what was not read moved to its front, when all of it was read
  or sixteen thousand bytes of it were; the room that the other side is
  told of is what is free behind what arrived, and when reading makes
  room where there was next to none, the other side is told at once, or
  it would wait for room that it never hears of.
- What is written is the connection's to send when the write returns,
  and not yet the other side's (the card's thread sends it, above). That
  the other side is gone shows at the next write or read. `close` says
  that this side is done, behind what is still to be sent.
- A machine reaches itself without the wire. A packet for an address of
  its own, or for 127.0.0.1, is put together in a page frame and left
  for the card's thread, which takes it as it takes what arrives: so one
  thread looks at everything that arrives, wherever it came from, no
  protocol calls itself, and no lock is taken twice. From the wire,
  nothing is taken that is for 127.0.0.1 or that says it is from this
  machine's own address.
- The ports are the world's and not the card's (`*doors*`). A world that
  is saved while it takes connections takes them again when it starts,
  on the card of that start; the connections themselves are gone, like
  every thread. For that the machine needs its address at once, which a
  thread asks for, so the start does not wait for a network that may say
  nothing.
- There is no web server, and no TLS for what the machine takes. What M15f
  wrote is the half of TLS that asks. A machine that hands out pages in
  the open is what Julio ruled out for ClaraOS's own publishing, so it is
  not put into the system by the way; ROADMAP.md has what the other half
  would take.

## IPv6 (decided in M17c, 2026-11-21)

- An address is a number when it is one of IPv4's and a list of eight
  numbers of sixteen bits when it is one of IPv6's. The language has no
  number of 128 bits, and a list is what it compares (EQUAL), prints and
  takes apart without help. Everything above the packets takes an
  address as it comes: UDP, TCP, the name servers, HTTP, TLS and the
  ports that take connections are written once, and only what puts a
  packet together or takes one apart asks which kind it has.
- The machine speaks IPv6 unless it is told not to (`clara.net:*ipv6*`).
  That costs a network that has none of it one question to the routers,
  when something first wants the network, and up to a second of waiting
  for an answer that does not come. It was that or a machine that has to
  be told which networks have routers.
- It makes its addresses itself (RFC 4862): the one that goes no further
  than its own network, and one on each network that a router names for
  that, each with its card's address as the second half. It does not ask
  first whether another machine has the same address, and it makes no
  address that hides the card; ROADMAP.md says what that costs.
- What neighbours and routers tell each other is believed only when
  nobody handed it on, which the number 255 says that a packet has left
  of the times it may be handed on: that is all that keeps a machine
  elsewhere from naming itself this network's router (RFC 4861).
- Which address of a name comes first is one rule: IPv6 when the
  machine's own address of that kind is one of the Internet's, IPv4
  otherwise. Under QEMU the machine's addresses of IPv6 mean something
  on a network that QEMU makes up, and whether the Internet is reached
  through them depends on the computer that QEMU runs on; the rule keeps
  a machine there on the road that it has always taken. When nothing
  takes a connection at the first address, the next is tried.
- A network with IPv6 alone is good enough: a DHCP server that does not
  answer is said once, and is not asked again for a minute.
- The network that the tests make up serves IPv6 without a second web
  server, name server or caller. What the machine sends by IPv6 is
  turned into the same thing over IPv4 before the code that knows only
  that looks at it, and what that code sends back is turned the other
  way, with the checksums put right for the other addresses both times.
  What only IPv6 has, a router's word, the neighbours' questions and
  ICMPv6, is written there as itself.

## Fonts of outlines (decided in M18a and M18b, 2026-11-21)

- A letter is a shape, and its picture is worked out when it is wanted. A
  font file has the outline of every glyph, in units of its own;
  lisp/type.lisp brings an outline to a size and gives every pixel a
  shade, how much of the pixel the shape covers, and the pixel takes that
  much of the colour of the text. So there is one font for every size,
  and an edge that slants is smooth. The console keeps its pictures of 8
  by 16: it is the first thing that works and the last that should stop,
  and it needs no file.
- The files are TrueType's: tables in a file, outlines of straight lines
  and of curves of the second degree. Fonts of that kind are to be had
  freely, in small files, and a curve of the second degree is cut into
  straight pieces with a handful of multiplications. Files of the other
  kind of outline are refused, in words. The programs in a file that fit
  a glyph to the pixels of a small size are passed over: the machine that
  runs them is more than everything else that is read of a file, and what
  it buys, sharper letters at a dozen pixels, is left for when that is
  what hurts most.
- What a shape covers of a pixel is worked out, and not sampled. Every
  straight piece of an outline is followed through the pixels that it
  crosses, and leaves in each how much of it the shape begins or ends
  there, with a sign for the way the piece runs; the sum along a row is
  each pixel's share. A piece is cut where it leaves a row and where it
  leaves a pixel, and each cut is worked out from the two ends of the
  piece, never from the cut before it: so the parts of a piece add up to
  the piece whatever the rounding, a closed shape leaves nothing behind
  it, and no row has a streak to the right of a letter, which is what a
  sum that is off by one gives.
- All of it is in whole numbers, the language having no others. A place
  is a count of 256ths of a pixel, and a pixel that is covered is 131072,
  twice 256 times 256, so the arithmetic of a letter of 400 pixels stays
  far inside a fixnum. A place is rounded once, to the nearest 256th, the
  upper of two that are as near.
- A curve is cut into as many pieces as it takes for none to lie further
  than a sixty-fourth of a pixel from it, across or down. FreeType allows
  a sixteenth. The pieces lie inside the curve, so what they cut off
  makes a round letter lighter than it is: at a sixteenth that was a
  pixel in sixty of a round shape, at a sixty-fourth it is one in two
  hundred and fifty, for twice the pieces.
- The substrate lays the colour on, and Lisp says how much of it. One
  function was added to the three of "Drawing"
  (`clara.unsafe:blend-shades-32`): a colour over a rectangle of pixels,
  by a vector of shades, with the bits of a pixel that hold each part of
  a colour as arguments, so that it is right on any screen and can be
  tried without one. Everything else is Lisp, which the processor runs
  (M16b): ninety-five glyphs at 13 pixels are made in less than a tick of
  the clock where the processor is the computer's own.
- The picture of a glyph is a vector in the heap, an item to the shade,
  made when its character is first drawn in a font and kept for the
  font: beside it and not in it, so that a font which is the value of a
  form at a prompt prints as a line, its name, its file, its size and
  where its lines lie. It is not page frames, as a surface's pixels are:
  the pictures are many and small, and the collector takes the ones that
  are let go of. The price is a word for a number below 256. What the
  pictures were made from, the bytes of the file, is memory of one start.
  So a font comes back with a world that was saved, and the pictures of
  its glyphs are let go of at the next start, since the file may be
  another by then: the font holds the name of its file, finds the file
  again when it is next used, and makes its glyphs again.
- The fonts that come with the system are files of the system's
  directory, and the handoff reads them into memory with the system's
  Lisp, where `clara.unsafe:system-file` finds them. The window manager
  writes its letters when it starts, which in a world that was saved is
  before the system has asked which volume the machine was started from;
  and a machine with no disk that is known here has its letters all the
  same. Any other font is a file, read through the file system when a
  font is first made of it.
- They are the Go fonts, which Bigelow & Holmes drew for the Go project:
  a sans and a font of fixed width, each upright, bold, italic and bold
  italic, with Latin, Greek and Cyrillic letters, made for screens and
  for reading code, under a BSD license like the console's Spleen. And
  they are small, eight files in 1.3 MiB where the eight of DejaVu are
  four: a system is copied whole when a machine takes a newer one, and
  lies on its volume twice for a moment. There is no font with serifs.
- A font is a file at a size, in whole pixels, and a glyph moves on by a
  whole number of pixels, its own way rounded. So a letter looks the same
  wherever it stands, one picture of it serves, and the width of a string
  is a sum. The price is spacing that is the designer's only to the half
  pixel.
- There is one way to draw text. `clara.draw:draw-text` and `text-width`
  take a font as one more argument, and are what they were without it:
  lisp/type.lisp hands them its two functions when it is loaded, since
  lisp/draw.lisp is loaded before there are files to read a font from.
- The window manager writes the bar, the list and the titles in such a
  font, Sans at 13 pixels, whose line is 16 pixels high like the
  console's, so nothing else on the screen moved. Which font is a
  variable of the world's. On a machine whose system has no such file the
  letters are the console's, and it says so once: a font that cannot be
  read must not cost anybody the screen. For the same reason a glyph that
  cannot be read shows nothing and is no error, while a file that is no
  font is refused when a font is first made of it, where the refusal has
  somebody to go to.
- A file is somebody else's, so nothing in it is trusted. Every byte is
  asked for by its place and held against the file's length; every table
  against the file before anything is read from it; how many points and
  parts a glyph is put together of, how deep it is made of other glyphs,
  and how many pixels its picture has, against limits.
- It is tested against what it did not make. The pictures of shapes,
  against areas that the host tests work out with fractions, by cutting a
  polygon down to the square of each pixel. The reader, against font
  files that the tests put together byte by byte, right ones and wrong
  ones, of outlines that the tests know because they wrote them. And the
  files that come with the system, against what FreeType reads of them,
  to every point of every outline, in a table that a program printed
  (tools/fontcheck.c); FreeType's pictures were held against these by
  hand, and ROADMAP.md says what came of it.

## Sound (decided in M19a, M19b and M19c, 2026-11-22)

- The card is virtio's (lisp/sound.lisp, over lisp/virtio.lisp), the one
  family of devices with drivers here, and QEMU has it: what the machine
  plays goes to the sound of the computer it runs on. UTM gives a machine
  another card unless it is told, one of Intel's, which would be a driver
  of another family: registers of its own, a tree of parts to be asked
  what they are, and an interrupt by a message of the older kind, which
  nothing here sets up. So in UTM the card is chosen by hand, as the
  keyboard is.
- Sound is taken, not sent. A program says what is to sound, which adds
  a voice to a list and returns; a thread of the card's puts the next
  hundredth of a second together out of every voice that is sounding and
  hands it to the card, whenever the card has room for one. The card is
  given four such periods before the first is played. The clock that
  moves threads on ticks a hundred times a second, so a thread that
  computes can keep the card's thread waiting for one of them, and a
  collection for part of another; with fewer periods ahead a gap would be
  heard, and with more a sound that is added to what plays would come
  later than the twentieth of a second that it comes now.
- Time is counted in frames and never read from a clock. A note is so
  many frames long, a voice is at such a frame, and a period is the next
  480 of them, however late the thread comes to it. So what is played is
  the same numbers every time, on a machine that is quick and on one that
  is emulated, and a test can hold them all against what they should be.
- It is all Lisp, and nothing was added to the substrate. Drawing has its
  loops over pixels in C (M11), and the fonts one more (M18a); since M16b
  the processor runs Lisp, and here the loops are a table looked up, two
  multiplications and some additions for each frame of a voice, of which
  every one has an instruction of its own. A voice costs half a
  thousandth of a second for a second of sound where the processor is the
  computer's own, and fifteen where it is emulated, with fifty-five more
  there, once for all voices, to write the frames where the card reads
  them.
- A wave is a table of 1024 numbers for one turn, gone through at the
  pace of the pitch: a place in it is a whole number and 1048576ths, and
  moves on by the pitch over the card's pace, to the nearest. No number
  is made between two of the table, which leaves a tone with what is not
  in it a thousand times fainter than itself. The sine is worked out
  when the file is loaded, by its series, in numbers with 28 bits behind
  the point, and every one of the 1024 is the nearest number to the real
  sine: the tests hold them against SBCL's. Noise is no table: a number
  held until the wave has gone round, and then the next of a row made by
  a rule, so that it is the same noise every time.
- A note comes up over 256 frames and goes down over its last 512, or
  over the largest halvings of those that are a quarter and a half of a
  short one. They are halvings so that the way up is a whole number of
  65536ths a frame, and nothing has to be rounded on the way. There is
  no other shape to a note: one that dies away, as a string that was
  plucked, is an instrument, and there are none yet.
- What the voices add up to is 67108864 times too large, a wave's number
  times how far the note is up times how loud its side is, and is
  brought back once for all of them, to the nearest, and kept at the ends
  of 16 bits where it is past them. A wave at its loudest goes a quarter
  of the way, so that four can sound together and be whole; a file at
  its loudest is as loud as it was made.
- How loud the machine is, is a variable of the world's
  (`clara.sound:*volume*`), which the card's thread reads for every
  period. So it holds for what is already sounding, and it is set and
  not bound: a binding is the thread's that made it.
- What is played returns at once, and `wait` is for whoever wants the
  end. Two things that are played one after the other therefore begin as
  far apart as the second took to be worked out, and `together` holds
  what is played inside it back until its last form is done, and hands it
  to the card in one piece.
- A melody is a list, since this is Lisp: notes by their names, each for
  a step, a list for the notes that sound together, a number at its end
  for how many steps. The language has no fractions, so there are none in
  a melody: the tempo is how many steps there are to the minute, and a
  melody with shorter notes has a quicker tempo and its longer notes
  written as several steps.
- Stopping lets go of a note as its end would: the step is cut to where
  it is and ten thousandths of a second more, which is its way down. So
  nothing clicks, and nothing has to know how to fade.
- Whatever is played ends with a period of nothing. A card that is given
  no more may do as it likes with the last number that it had. And the
  card is told to stop when it has been quiet for three tenths of a
  second, not at once: what it was given last is still on its way to the
  loudspeaker, and one sound is often followed by the next.
- A machine without a card plays nothing, and that is not an error:
  every function gives NIL there. A sound is seldom what a program is
  for, and one that beeps when a key is pressed should not need to ask
  first. What is wrong with what was asked for, a note that is none, is
  an error on every machine. A card that stops answering is given up,
  said once, and from then on the machine is one without a card.
- A file of sound is a WAVE file of plain numbers, 8 or 16 bits, one
  side or two: what every program that makes sound can write, and what
  can be played by reading it. It is read whole into page frames, which
  are given back when the last frame has been played, and brought to the
  card's pace by going through its frames faster or slower than the card
  takes them, the nearest frame before each time. Nothing in it is
  trusted: every piece is held against the length of the file.
- A world that is saved has the tables in it and nothing of the card:
  the card, its thread and what it was playing are another machine's by
  the next start, which finds the card anew.
- It is tested against what it did not make. Under SBCL a card that the
  tests make up keeps every number that it is given, fails the run when
  it is asked out of order or given more than it was told to hold, and
  can play at its own pace, say no, or say nothing; and the numbers are
  held, every one, against a rule that works each frame out by itself,
  in fractions, from how far the wave has gone round by then, where the
  driver adds a step to the frame before. At a real kernel QEMU writes
  what each machine of `make test` plays into a file, tools/heard.py says
  what is in it, how long each stretch of sound is, how often it turns
  and how far it goes on each side, and the session has the lines that it
  is to say; the same forms played under SBCL give the same lines. And
  files that macOS's own converter made of its system sounds were played
  once, by hand, and came out of the card to the byte.

## Objects (decided in M20a, M20b and M20c, 2026-11-22)

- Common Lisp's object system is Lisp here, a file of the world
  (lisp/clos.lisp), and not a part of the substrate. An instance, a
  class, a generic function and a method are structures, and what they
  hold are lists, vectors and closures: nothing was added to the heap,
  and a world that is saved holds its classes and its instances as it
  holds everything else. The substrate was given three things for it: a
  function that says what an object is (`%type-of`), a printer that asks
  Lisp what such a structure looks like, and SYMBOL-MACROLET. The other
  ways were an instance as an object of the substrate's own, which is
  more in C for nothing that can be seen yet; and the whole of it in
  lisp/boot.lisp with the rest of the language, which the evaluator would
  walk before it is compiled, twice at every start from the files, and
  whose texts the stress boot would go through with a collection at
  every call.
- Its names are Common Lisp's, symbols of COMMON-LISP, as they are in
  any Common Lisp: `defclass` in a program means the same symbol here and
  under SBCL. So lisp/clos.lisp is the second file that SBCL cannot load
  as it stands, after lisp/boot.lisp, and unlike that one it is tested
  there all the same: the host tests read it a form at a time into a
  package in which those names are symbols of its own, beside SBCL's
  object system, which is then the second opinion that nobody here
  wrote. One transcript, tools/objects.txt, is answered three ways: by
  this file under SBCL, by SBCL's own, and by a kernel at which
  `make test` types it; and classes, methods and redefinitions that
  chance picks are given to both systems under SBCL, which have to agree
  call for call. What that found before any kernel had run a line of it:
  a SORT that used up the list of a generic function's methods, which
  SBCL's does and ClaraOS's does not; and when an instance follows a
  class that was defined again, below.
- An instance is a structure of three slots: its class, the names of its
  slots in the order of their values, and the values in a vector of
  their own. The vector is apart because objects in the heap neither
  move nor grow, and an instance has to be able to get other slots: a
  class can be defined again, at the prompt, with instances of it in
  variables, and that is how programs are written here. The instance
  finds out when it is next used, by its names no longer being the ones
  that its class has, and is given a new vector: the slots that it had
  keep their values, the ones that are gone are dropped, the new ones
  begin as the class says. "Used" is a look at a slot or a call of a
  generic function with the instance. The standard asks only for the
  first; SBCL does the second too, so a slot that one definition took
  away is gone when a later one brings it back, and here it is the same.
- A class does not know the classes below it. A number goes up when a
  class is defined again, and every class and every generic function
  remembers at which number it last worked out what it keeps: a class
  its precedence list and its slots, a generic function what its methods
  come to. Whoever finds the number moved on works that out again, when
  it is next asked. A list of the classes below would have to be kept
  right for classes that go away, with the package of an application
  that is unloaded, and nothing here could say when they do.
- A generic function is called through an ordinary function, which
  closes over it and hands DISPATCH the arguments in a list. What the
  methods that fit come to is one function of that list, made when
  arguments of some classes first arrive and kept under those classes,
  as many of them from the left as any method looks at; for a generic
  function with a method for one particular object, an EQL, nothing is
  kept, and it is worked out at every call. A call costs a list for its
  arguments and a walk through what is kept, which is what a first
  version costs and is measured in ROADMAP.md; a method could be reached
  without either, and the roadmap says how.
- Methods are put together in the standard's standard way, and in no
  other: the :AROUND methods, then the :BEFORE methods, the most specific
  method with its CALL-NEXT-METHOD, and the :AFTER methods. A method is a
  function of the arguments; one whose body names CALL-NEXT-METHOD or
  NEXT-METHOD-P is given two things before them, the arguments as a list
  and the chain of methods that it is the first of, and is the only kind
  that makes a closure when it is called.
- The classes that the language begins with are the standard's, under
  the standard's names, and no others: the class of 5 is INTEGER, where
  SBCL says FIXNUM, since a method for FIXNUM is a program that runs
  under one Common Lisp and not the next. A type that DEFSTRUCT made and
  a type of condition are classes, made when they are first asked for;
  what has no class of its own, a thread, is a T. A method can be
  written for any of them. Only a class that DEFCLASS made can have a
  class below it, and there is one kind of such class: no metaobject
  protocol.
- MAKE-INSTANCE refuses a keyword that fills no slot and that no method
  of INITIALIZE-INSTANCE or SHARED-INITIALIZE takes, as the standard has
  it: that is what finds a keyword that was typed wrongly. A call of any
  other generic function is not held against the keywords of its
  methods, which the standard asks for too; a program that is right
  under SBCL is right here, and one that is wrong there may pass.
- The printer asks. It is in C, and goes through an object twice, once
  to count the characters and once to store them, so it cannot call
  Lisp in the middle: a method of PRINT-OBJECT would run twice, and
  could say something longer the second time. So a structure whose
  type's name is marked is left out of a first round and noted; then
  Lisp is asked for the text of each (PRINT-OBJECT into a string), in
  the order in which the printer came to them, and the two rounds of
  before follow with those texts in place. That
  happens in the functions that make a string for Lisp, PRIN1-TO-STRING,
  PRINC-TO-STRING and FORMAT, so an instance is written by its method
  wherever it stands, at the prompt, in a list, in the text of an error
  that a program signals. Where nobody can be asked, in what an error of
  the substrate's says, it is `#<STANDARD-OBJECT>`. The marked types are
  the four of lisp/clos.lisp, and any structure's type for whose class a
  method of PRINT-OBJECT is written.
- An instance is written as `#<ACCOUNT>`, with no number that tells it
  from another of its class. SBCL writes the address; here the address
  would be another on every machine, and a session or the manual could
  never show an instance. A method of PRINT-OBJECT says what tells two
  apart.
- A function that SETF writes with has the name (SETF name) in Common
  Lisp. Here it lives in a symbol of its own that the name keeps on its
  property list, and SETF calls it for a place that begins with a name
  which is no macro's and has no writer of the older kind (DEFSETF): by
  that symbol when the function is there as the SETF is expanded, and
  found when the form runs otherwise, so a function can be compiled
  before the class whose accessor it writes with. DEFGENERIC, DEFMETHOD
  and the accessors of a class make such functions. DEFUN and FUNCTION do
  not take such a name: that is the evaluator's and the compiler's to
  learn, and nothing needed it.
- SYMBOL-MACROLET is a special form of the evaluator's and a converter of
  the compiler's, which WITH-SLOTS and WITH-ACCESSORS are written with:
  a name stands for a form, where it is evaluated and where it is set.
  The compiler makes nothing for it, the name being a form wherever it
  is in sight. The evaluator keeps such names in a frame of a kind of
  its own and looks for a variable in both kinds; that it found a form
  it says by the lowest bit of the address it gives back, so that the
  function which evaluates a form inside a form, and has a frame on the
  stack for each, has no word more than before.
- TYPEP, TYPE-OF, TYPECASE and ETYPECASE came with it, since a class is
  a type and nothing here asked what type an object is of before. They
  are Lisp over CLASS-OF, and know the classes, a few names that are
  types and no classes, and the types that are put together of others.
- What is typed is kept as text (above), a form taking the place of an
  earlier one that defined the same name. The methods of a generic
  function all begin with the same two words, so each is told apart
  there by what is before its parameters and by what each parameter is
  for: without that, a world made again after an upgrade would have had
  the last method that was typed and no other.

## Shutting down (decided in M15e, 2026-11-20)

- Shutting down is something the system does, and not something that is
  done to it. Until this milestone a machine was stopped from outside,
  which is the plug pulled: nothing was told, and the world as it had
  become since it was last saved was gone. Now the machine is asked: at a
  prompt, by the launcher's list, or by its power button, which is what a
  host presses when it wants a machine to stop. The three come to one
  procedure (lisp/system.lisp), and starting again is the same procedure
  with another last step.
- The procedure is Lisp, and the substrate's part is two functions and a
  question: turn the machine off, start it again, has the button been
  pressed. Each goes by what ACPI's table of fixed hardware says of the
  machine. On AArch64 that is PSCI, a call to whatever runs above the
  kernel, by the instruction that the table names. On x86_64 it is a few
  I/O ports: the sleep state S5 written to the PM1 control register, the
  reset register, and where there is none the keyboard controller's line
  to the processor's reset pin.
- The firmware has a runtime service for both, ResetSystem, the same on
  both architectures, and the kernel does not call it. A runtime service
  is the firmware's code, run by the kernel in the kernel's address space,
  and the address space has one rule about code: the only memory that can
  be run is the kernel's own image and what the Lisp world made for the
  processor. Mapping what the firmware left behind so that it can be run,
  and its data so that it can be written, on the word of a memory map from
  before the handoff, gives that up for the sake of two calls. A call to a
  higher level and a write to a port need nothing of the kind.
- A machine that is started again keeps what its memory held, and its
  firmware starts in that memory. What the firmware's map calls free is
  the system's to write on, and a firmware should take nothing there on
  trust at its next start; one did. OVMF looks for what a loader of
  another kind (IGVM) leaves it in a page frame at a fixed address,
  0x812000, and for three months of EDK2, a release among them, neither
  kept that frame to itself nor looked at more than two words of it:
  with words of the Lisp heap there, a machine that was told to start
  again was laid out by them and stood still in its firmware (ROADMAP.md,
  0.0.44). The firmware was mended by keeping the frame to itself in its
  map. The system does that for itself: on x86_64 that one frame never
  leaves the allocator once the map has given it up, and is cleared
  (kernel/pmm.c, `arch_kept_frame`), so that the firmware finds nothing
  there whatever starts the machine again, the system, the host, or a
  fault. It costs 4 KiB on a machine that has no such firmware. Clearing
  all of memory before the machine is told to start again would guard
  against every firmware that reads what it should not: it takes seconds
  where a machine is emulated, cannot be taken back when the machine
  turns out to have no way of starting again, and does nothing when the
  machine is started again from outside.
- Two facts are in the DSDT and nowhere else: the type of the sleep state
  that is "off", and where the registers of the generic event device are,
  which is what has the power button on a machine without a PC's fixed
  hardware. The DSDT is AML, a bytecode, and there is no interpreter for
  it here (Devices, above). Both facts are written in it as a name with a
  constant behind it, so the table is searched for those bytes
  (kernel/acpi.c). A firmware that says them another way is not
  understood; the boot report then says that the machine has no way of
  being turned off, or no button, and it is stopped from outside as
  before.
- The power button is looked at and not waited for. On both machines it
  would raise an interrupt, and on both the interrupt comes by a line,
  whose number is in the DSDT's bytecode: the same reason for which no
  device here interrupts by a line. A thread asks the substrate four times
  a second, which costs a read of one register.
- Before anything is done, the windows are asked. A window can be given a
  function that says what its program holds that would be lost if the
  window went, in a few words, and the editor's says so when its text is
  not saved. While any window answers, the machine is not shut down: that
  window comes to the top and whoever asked is told which it is. Asking
  with `:force t` asks nobody. This is the whole of what an application is
  told: it is not asked to close, and a program without a window is not
  asked at all.
- The world is saved, unless the shutdown is told not to: the next start
  then goes on in the world that was left. It is saved while the window
  manager still runs, so that the machine starts in it again; then the
  window manager is stopped, which stops the applications; then every disk
  is asked to put what it was given where it lasts, by the request that
  virtio has for that, when the disk says that it holds anything back; and
  then the substrate is told. A world that cannot be saved stops the
  procedure before anything else is done, with the reason, so that
  something can be done about it. A machine without a disk has nowhere to
  save a world and goes all the same.
- A thread of its own does all of that. The thread that asked may be an
  application's, the listener's in a window, and stopping the window
  manager stops it halfway. Whoever asked waits for that thread, and hears
  from the procedure again only if the machine is still there: when a
  world could not be saved, or when the substrate has no way of turning
  this machine off, which is then said, with the world saved and the
  machine left for the host to stop.
- Ctrl-D at the first prompt is what it was: the session ends, the kernel
  says that it has nothing more to do, and the machine stands still. It
  saves nothing and turns nothing off. The boot tests end their sessions
  that way and then look at the screen of a machine that is still there.
- Shutting down is tested twice. Under SBCL the machine that the tests
  make up takes note of what it is told and stays on, as a machine does
  that cannot be turned off from inside, and the tests look at the order
  of things up to there, through a disk that says at each request whether
  the window manager still runs. And by booting: each kind of processor
  starts once more from the disk that its first session left, is asked to
  shut down while an editor holds a text that is not saved, is told to
  start again and has to come up in the world that it saved on the way,
  and has its power button pressed, after which it has to save once more
  and be gone by itself, with its volume in order.

## Conventions

- C: lower_snake_case for functions and files. Kernel-wide symbols carry
  their subsystem as a prefix: `kprintf`, `fb_fill`, `arch_halt`. The Lisp
  runtime's C code is prefixed `lisp_` and lives in kernel/lisp/; a Lisp
  value in C has the type `lisp`.
- Lisp: sources live under lisp/, one package per subsystem, named
  `clara.<subsystem>`. Each file loads under SBCL; host-only shims live in
  lisp/host/ and are never loaded on ClaraOS. The exception is
  lisp/boot.lisp, the part of Common Lisp itself that is written in Lisp:
  SBCL has all of it already, and never loads it. The substrate's own
  packages are CLARA and CLARA.UNSAFE.
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
