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
  interpreter written in C. A compiler is written in Lisp once the world
  can host it, which it is since M14a ("The compiler", below): it makes
  code for a small machine that the substrate has, and not yet for the
  processor. The interpreter stays as the bootstrap and the fallback.
- **The image is the system.** Booting means taking a saved heap image for
  the heap and starting the world that is in it, with the window manager
  running when the world was saved with it running ("Images" and
  "Windows", below). The boot handoff reads every
  file in the ESP's `\clara` directory through the UEFI file protocol
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
  way, and they wait for CLOS.
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
  stream has, for the same reason: generic functions wait for CLOS. A
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
- An image outlives the kernel that saved it. A function in C is in the
  heap as its place in a table, and a kernel with other rows in its
  tables gives each such function its place again by its name; what the
  newer kernel has more of is added to the world. What an older world
  has in Lisp stays as it was saved: a newer boot.lisp is loaded into it
  by whoever wants it.
- An image is refused, with the reason in the boot report, and the world
  is made from the files as on a machine without one: when the file is
  not whole, by its length or by its checksum, which is taken of the heap
  where it lies after the copy; when it was saved on the other
  architecture, since what is defined in a world depends on the machine;
  when its objects are not laid out as this kernel has them, which is a
  number in image.c that a change to lisp.h has to raise; and when it has
  a function in C that this kernel has not. The files are read at every
  boot for that reason, and stay in memory as before.
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
  that is not. Each waits for the first thing that needs it.
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
