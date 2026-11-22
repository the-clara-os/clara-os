/* The Lisp runtime: what a Lisp object is, and the substrate's part in
 * making, reading, printing and evaluating one.
 *
 * A Lisp value is one 64-bit word, and its lowest bits say what it is:
 *
 *   ...0   a fixnum: the integer is the other 63 bits
 *   .001   a cons
 *   .011   a symbol
 *   .101   any other object in the heap, whose first word says which
 *   .111   an immediate: a character, or a marker
 *
 * The three in the middle are addresses in the heap (heap.c), which are
 * multiples of 8, with the tag added. Every object in the heap begins with
 * a header word, conses included: its type in the lowest byte, a byte that
 * the collector marks in, and a length in the other 48 bits, the characters
 * of a string or the items of a vector. With a header on everything the
 * heap can be walked from one end to the other, which is what the
 * collector's sweep does, and what is done with a heap that was saved
 * (image.c); the price is a third word in every cons.
 *
 * NIL is the symbol at the very start of the heap, so its word is a
 * constant, and the empty list is that same word. */
#pragma once
#include "kernel.h"

typedef uint64_t lisp;

#define LISP_TAG_MASK      7ULL
#define LISP_TAG_CONS      1ULL
#define LISP_TAG_SYMBOL    3ULL
#define LISP_TAG_OBJECT    5ULL
#define LISP_TAG_IMMEDIATE 7ULL

#define LISP_CHARACTER 0x07ULL /* the lowest byte of a character; its code point is in the bits above */
#define LISP_UNBOUND   0x0fULL /* in a symbol's value or function: there is none */
#define LISP_FREED     0x00007deaddeaddedULL /* what the collector fills freed memory with: as a value, the
                                                address of an object where nothing is mapped */
#define LISP_NIL       (VM_HEAP_BASE | LISP_TAG_SYMBOL)

#define LISP_FIXNUM_MAX (((int64_t)1 << 62) - 1) /* and the least is -LISP_FIXNUM_MAX - 1 */
#define LISP_CODE_LIMIT 0x110000u                /* characters are Unicode code points */

/* What the first word of an object in the heap says it is. Zero is not a
 * type, so memory that was never an object does not pass for one. */
enum lisp_type {
    LISP_CONS = 1,
    LISP_SYMBOL,
    LISP_STRING,
    LISP_VECTOR,
    LISP_PACKAGE,
    LISP_FUNCTION,
    LISP_STRUCTURE,
    LISP_CONDITION,
    LISP_THREAD,
    LISP_LOCK,
    LISP_EVENT,
    LISP_NATIVE, /* code for the processor, which lies outside the heap: this is what holds on to it (native.c) */
    LISP_FREE, /* no object: memory that the collector found unused, as long as its length says */
    LISP_TYPES
};

struct lisp_cons {
    lisp header, car, cdr;
};

/* A symbol has no length, and keeps its flags where the length would be. */
#define LISP_SPECIAL  1u /* every binding of it is dynamic: DEFVAR and its kin said so */
#define LISP_CONSTANT 2u /* its value cannot be changed: T, NIL, the keywords, DEFCONSTANT */

struct lisp_symbol {
    lisp header;
    lisp name;     /* a string */
    lisp package;  /* the one it lives in, or NIL */
    lisp value;    /* LISP_UNBOUND until it has one */
    lisp function; /* the same; otherwise a function, whatever its kind */
    lisp plist;
};

struct lisp_string {
    lisp header;      /* the length is in characters */
    uint32_t chars[]; /* code points, two to a word */
};

struct lisp_vector {
    lisp header;
    lisp items[];
};

struct lisp_package {
    lisp header;
    lisp name;      /* a string */
    lisp nicknames; /* a list of strings */
    lisp uses;      /* a list of packages: their external symbols can be had here by name */
    lisp internal;  /* its own symbols, in two tables (symbol.c): the ones it keeps */
    lisp external;  /* and the ones it offers to the packages that use it */
};

/* Whatever can be the function of a symbol. Which of the five it is sits
 * where the length would be. */
enum lisp_function_kind {
    LISP_PRIMITIVE, /* a function written in C: code is its place in lisp_primitives */
    LISP_SPECIAL_OPERATOR, /* IF, LET and the like: code is its place in the evaluator's table */
    LISP_CLOSURE,   /* a function written in Lisp: code is (lambda-list . body) */
    LISP_MACRO,     /* the same, called with the subforms of a form to make the form to evaluate instead; or, made by
                       compiled code, code is a function that is given the form itself */
    LISP_COMPILED,  /* a function written in Lisp that the compiler has been over: code is what it made (vm.c) */
};

/* The functions that the heap holds, counted (lisp_heap_functions). */
struct lisp_functions {
    uint64_t in_c;     /* functions in C, and the special forms */
    uint64_t compiled; /* functions that the machine runs the code of, */
    uint64_t macros;   /* and macros whose function is one of those */
    uint64_t walked;   /* functions and macros whose forms the evaluator walks */
    uint64_t native;   /* of the compiled ones, those that the processor runs the code of itself */
};

struct lisp_function {
    lisp header;
    lisp name; /* a symbol, or NIL for a LAMBDA */
    lisp code; /* a fixnum for the two kinds in C, never an address: an image has to outlive the kernel that saved it */
    lisp env;  /* the environment a closure or a macro was made in (eval.c); of a compiled function, the values it
                  closes over, in a vector, or NIL */
    lisp entry; /* 0, or where the processor goes on when code for the processor calls this function: an address in
                   the region of such code (native.c), which is the same on every boot, and even, so a fixnum to
                   the collector */
};

/* The code of a compiled function: a vector with these items, which the
 * compiler makes (lisp/compiler.lisp) and the machine in vm.c runs. */
enum lisp_code {
    LISP_CODE_INSTRUCTIONS, /* a vector of fixnums, an instruction each */
    LISP_CODE_CONSTANTS,    /* a vector of what the instructions name */
    LISP_CODE_NAME,         /* a symbol, or NIL for a LAMBDA */
    LISP_CODE_LAMBDA_LIST,  /* as it was written: for the printer */
    LISP_CODE_REQUIRED,     /* how many parameters have to get an argument, */
    LISP_CODE_OPTIONAL,     /* and how many more can */
    LISP_CODE_REST,         /* T when the arguments after those are wanted as a list */
    LISP_CODE_KEYS,         /* NIL, or a vector of the keywords that the function takes */
    LISP_CODE_ALLOW,        /* T when it takes any other keyword too */
    LISP_CODE_LOCALS,       /* how many local variables a call has, the parameters among them, */
    LISP_CODE_DEPTH,        /* how many more words of stack its instructions use, */
    LISP_CODE_CLOSED,       /* and how many values a function of this code closes over */
    LISP_CODE_NATIVE,       /* NIL, or what holds the code for the processor that was made of the instructions */
    LISP_CODE_ITEMS
};

/* Code for the processor, as the heap has it: the code itself is in a
 * region of its own, where memory can be run (native.c), and this object
 * is what the collector sees of it. When nothing holds the object any
 * more, the code is freed with it. Its words are an address and two small
 * numbers, fixnums all three to the collector. */
struct lisp_native {
    lisp header;
    lisp address; /* where the code begins, a multiple of 16 */
    lisp bytes;   /* how long it is, a fixnum */
    lisp hidden;  /* a fixnum: the words that a call of it keeps between its local variables and its stack, for
                     the records in force and the bindings that it began with (vm.c). None, when it makes neither */
};

struct lisp_structure {
    lisp header; /* the length is the number of slots */
    lisp type;   /* (name slot...), as DEFSTRUCT wrote it down: shared by every structure of the type */
    lisp slots[];
};

/* What ERROR and SIGNAL pass to a HANDLER-CASE. */
struct lisp_condition {
    lisp header;
    lisp type;    /* a symbol: DEFINE-CONDITION gave it its parents and its slots (lisp/boot.lisp) */
    lisp message; /* what it says to a person, a string, or NIL when it has nothing to say but its slots */
    lisp slots;   /* the names of its slots and their values, in turn */
};

/* A thread of the Lisp world, as Lisp holds it (thread.c). Three of these
 * objects have a word that is no Lisp value but an address in the kernel's
 * own memory: what the thread is to the substrate while it runs, and the
 * first of the threads that wait, here for this one to finish. An address
 * there is a multiple of eight, so to the collector it is a fixnum, and it
 * passes it by. */
enum lisp_thread_state { LISP_RUNNING, LISP_FINISHED, LISP_FAILED, LISP_STOPPED };

struct lisp_thread {
    lisp header;
    lisp name;     /* a string, or NIL */
    lisp function; /* what it calls; NIL once it has */
    lisp state;    /* an enum lisp_thread_state, as a fixnum */
    lisp result;   /* FINISHED: a list of the values of the function. FAILED: the condition that nothing handled */
    lisp context;  /* an address, while it runs */
    lisp waiting;  /* an address: the threads in JOIN-THREAD */
};

/* A lock that one Lisp thread at a time can hold, and an event that
 * counts how often it was signalled and not yet waited for. */
struct lisp_lock {
    lisp header;
    lisp name;    /* a string, or NIL */
    lisp owner;   /* a thread, or NIL when it is free */
    lisp waiting; /* an address: the threads in ACQUIRE-LOCK, in order of arrival */
};

struct lisp_event {
    lisp header;
    lisp name;    /* a string, or NIL */
    lisp count;   /* a fixnum */
    lisp waiting; /* an address: the threads in WAIT-EVENT, in order of arrival */
};

static inline lisp lisp_header(enum lisp_type type, uint64_t length)
{
    return length << 16 | type;
}

static inline uint64_t lisp_length(lisp header)
{
    return header >> 16;
}

static inline int lisp_is_fixnum(lisp x)
{
    return !(x & 1);
}

static inline lisp lisp_fixnum(int64_t n)
{
    return (lisp)n << 1;
}

static inline int64_t lisp_fixnum_value(lisp x)
{
    return (int64_t)x >> 1;
}

static inline int lisp_is_character(lisp x)
{
    return (x & 0xff) == LISP_CHARACTER;
}

static inline lisp lisp_character(uint32_t code)
{
    return (lisp)code << 8 | LISP_CHARACTER;
}

static inline uint32_t lisp_character_code(lisp x)
{
    return (uint32_t)(x >> 8);
}

static inline int lisp_is_cons(lisp x)
{
    return (x & LISP_TAG_MASK) == LISP_TAG_CONS;
}

static inline int lisp_is_symbol(lisp x)
{
    return (x & LISP_TAG_MASK) == LISP_TAG_SYMBOL;
}

/* Where in the heap x is. Only for a cons, a symbol or another object: the
 * caller has looked at the tag. */
static inline void *lisp_object(lisp x)
{
    return (void *)(uintptr_t)(x & ~LISP_TAG_MASK);
}

/* Is x an object of this type? For the types that have no tag of their own. */
static inline int lisp_is(lisp x, enum lisp_type type)
{
    return (x & LISP_TAG_MASK) == LISP_TAG_OBJECT && (*(lisp *)lisp_object(x) & 0xff) == (lisp)type;
}

static inline struct lisp_cons *lisp_as_cons(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_symbol *lisp_as_symbol(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_string *lisp_as_string(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_vector *lisp_as_vector(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_package *lisp_as_package(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_function *lisp_as_function(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_structure *lisp_as_structure(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_condition *lisp_as_condition(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_thread *lisp_as_thread(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_lock *lisp_as_lock(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_event *lisp_as_event(lisp x)
{
    return lisp_object(x);
}

static inline struct lisp_native *lisp_as_native(lisp x)
{
    return lisp_object(x);
}

static inline unsigned lisp_symbol_flags(lisp symbol)
{
    return (unsigned)lisp_length(lisp_as_symbol(symbol)->header);
}

static inline void lisp_symbol_flag(lisp symbol, unsigned flags)
{
    lisp_as_symbol(symbol)->header |= (lisp)flags << 16;
}

static inline enum lisp_function_kind lisp_function_kind(lisp function)
{
    return (enum lisp_function_kind)lisp_length(lisp_as_function(function)->header);
}

/* Where interrupts come from that a Lisp thread can wait for (thread.c):
 * the timer, the serial port, and then the devices that send messages, in
 * the order they asked (kernel/interrupt.c). */
enum lisp_interrupt {
    LISP_INTERRUPT_TIMER,
    LISP_INTERRUPT_SERIAL,
    LISP_INTERRUPT_MESSAGE,
    LISP_INTERRUPTS = LISP_INTERRUPT_MESSAGE + INTERRUPT_SOURCES
};

/* What the substrate itself holds on to in the Lisp world. The collector
 * starts from here, and from what the evaluator keeps (eval.c): every
 * word of this is a Lisp value. An image is these and the heap
 * (image.c). */
struct lisp_roots {
    lisp t, quote, function;
    lisp quasiquote, unquote, splice; /* what the reader makes of ` , and ,@ */
    lisp package;               /* the symbol *PACKAGE*, whose value is the package that names are read in */
    lisp features;              /* the symbol *FEATURES*, whose value #+ and #- look in: keywords */
    lisp packages;              /* a list of every package there is */
    lisp keyword, common_lisp, user;
    lisp clara;                 /* the package CLARA: what the substrate offers that Common Lisp has no name for */
    lisp unsafe;                /* the package CLARA.UNSAFE: memory by its address, I/O ports, interrupts */
    lisp interrupts[LISP_INTERRUPTS]; /* the event each source of interrupts signals, once Lisp has asked for it */
};
extern struct lisp_roots lisp_roots;

/* heap.c: where objects live, the making of the plain ones, and the
 * collector, which frees the ones that nothing can reach any more. Making
 * an object never collects: that happens at the evaluator's safe points
 * only, so C may keep an object in a variable from one of those to the
 * next. */
struct lisp_heap {
    uint64_t size;        /* bytes, from the first object to the end of the last */
    uint64_t free;        /* of those, the bytes in free blocks */
    uint64_t collections; /* so far */
};
void     lisp_heap_init(void);
void    *lisp_alloc(enum lisp_type type, uint64_t length); /* a new object, all zeroes after its header */
uint64_t lisp_object_words(lisp header);                   /* how long the object under that header is */
int      lisp_heap_room(uint64_t words);                   /* can an object that long be made, and memory be left over? */
uint64_t lisp_heap_census(uint64_t count[LISP_TYPES]);     /* walk the heap, count by type; bytes in use */
void     lisp_heap_functions(struct lisp_functions *count); /* how many functions of each kind are in the heap */
void     lisp_heap_compiled(void (*each)(struct lisp_function *f, void *with), void *with); /* every function in the
                                                               heap that the compiler made, one after the other */
void     lisp_heap_state(struct lisp_heap *state);
uint64_t lisp_collect(void);                               /* free what is not in use; how many bytes that was */
void     lisp_reach(lisp x);                               /* from the collector's helpers: x is in use */
int      lisp_heap_safe_point(void);                       /* collect if it is time; 0 when the heap is full even so */
void     lisp_collect_if_full(void);                       /* collect, if the last time left the heap full */
uint64_t lisp_collect_every(uint64_t n);                   /* at every nth safe point; 0: when it is time. What it was */
int      lisp_heap_restore(const void *from, uint64_t bytes); /* for an image: an empty heap becomes a copy of those bytes */
void     lisp_heap_empty(void);                            /* and empty again */
lisp     lisp_cons(lisp car, lisp cdr);
lisp     lisp_make_string(const uint32_t *chars, uint64_t length); /* chars may be NULL, to fill it in later */
lisp     lisp_make_vector(uint64_t length);                /* of fixnum zeroes */
lisp     lisp_make_condition(lisp type, lisp message, lisp slots);

/* symbol.c: symbols, and the packages that find them by name. A name here
 * is characters and how many, as the reader has them. */
enum lisp_access { LISP_ABSENT, LISP_INTERNAL, LISP_EXTERNAL, LISP_INHERITED };
void lisp_symbols_init(void);
lisp lisp_make_symbol(const uint32_t *name, uint64_t length); /* in no package */
lisp lisp_make_package(const char *name, const char *nickname, lisp uses); /* ASCII names; nickname may be NULL */
lisp lisp_new_package(lisp name, lisp nicknames, lisp uses);  /* the same from a string, a list of strings, a list of packages */
lisp lisp_find_package(const uint32_t *name, uint64_t length); /* by name or nickname; 0 when there is none */
enum lisp_access lisp_find_symbol(lisp package, const uint32_t *name, uint64_t length, lisp *symbol);
lisp lisp_intern(lisp package, const uint32_t *name, uint64_t length); /* the symbol of that name there, made if need be */
lisp lisp_symbol_in(lisp package, const char *name, int external); /* the same for a name in C, external if asked */
int  lisp_export(lisp package, lisp symbol); /* one of the package's own becomes external; 0 when it is not one */
lisp lisp_current_package(void);

/* read.c: text into objects. The text is UTF-8 and all of it is in memory:
 * the reader never waits for more, it says that the text stopped short. */
#define LISP_DEPTH     64  /* how deep lists may nest for the reader to read them and the printer to print them */
#define LISP_TOKEN_MAX 255 /* characters in a number or in a symbol's name with its package */

enum lisp_read_status {
    LISP_READ_OK,    /* a form */
    LISP_READ_END,   /* nothing was left but blanks and comments */
    LISP_READ_SHORT, /* the text ended in the middle of a form */
    LISP_READ_ERROR,
};

struct lisp_reader {
    const uint8_t *text, *end;
    const uint8_t *at;    /* how far it has been read */
    enum lisp_read_status status;
    const char *error;    /* SHORT or ERROR: what was wrong, in words */
    const uint8_t *where; /* and the place. After a form: where it began */
    unsigned depth;       /* how many lists are open around what is being read */
    unsigned backquotes;  /* and how many backquotes that no comma has answered yet */
    unsigned suppress;    /* inside a form that #+ or #- leaves out: tokens are passed over, not made sense of */
    uint32_t token[LISP_TOKEN_MAX];
};

void lisp_reader_init(struct lisp_reader *r, const void *text, size_t size);
enum lisp_read_status lisp_read(struct lisp_reader *r, lisp *form); /* the next form of the text */
void lisp_reader_where(const struct lisp_reader *r, unsigned *line, unsigned *column); /* r->where, both from 1 */
lisp lisp_string_from_utf8(const void *text, size_t size); /* as far as it is UTF-8 */
size_t lisp_utf8_length(const void *text, size_t size);   /* which is this many of its bytes */

/* What the characters of a token spell when none of them was escaped
 * (CLHS 2.3.1). The printer asks too: a symbol whose name looks like a
 * number has to be printed between bars. */
enum lisp_number { LISP_NOT_A_NUMBER, LISP_INTEGER, LISP_RATIO, LISP_FLOAT };
enum lisp_number lisp_number_syntax(const uint32_t *s, uint64_t length);

/* The characters that have names, for #\Space and the like. The printer
 * uses the first name a code has, the reader takes any, in either case.
 * The list ends with a NULL name. */
struct lisp_character_name {
    uint32_t code;
    const char *name;
};
extern const struct lisp_character_name lisp_character_names[];

/* print.c: an object as text. It comes out in UTF-8, a byte at a time.
 * lisp_print writes what the reader would read back as the same object,
 * where there is such a text; lisp_princ writes it for a person: a string
 * without its quotes, a character as itself, a symbol by its name alone. */
void lisp_print(lisp x, void (*put)(void *to, char c), void *to);
void lisp_princ(lisp x, void (*put)(void *to, char c), void *to);

/* eval.c: the evaluator. A form may give several values or none: what
 * lisp_eval and lisp_apply return is the first, or NIL, and lisp_values
 * says how many there are and, unless there is exactly one, holds them.
 * Either can come back in the middle of a non-local exit, an error among
 * them: lisp_unwinding says so, the value means nothing then, and the
 * caller's part is to return in turn.
 *
 * An error is a condition. lisp_fail makes one of the type ERROR out of
 * words, and lisp_fail_as one of the type named, in COMMON-LISP, with a
 * slot if slot is not NULL; the innermost HANDLER-CASE that asks for such
 * a type takes it, and with none it goes to the top level. */
#define LISP_VALUES_MAX 20
struct lisp_multiple {
    unsigned count;
    lisp value[LISP_VALUES_MAX];
};

/* A non-local exit that is under way (eval.h says what the words are). The
 * collector looks at every lisp here whether or not an exit is under way,
 * so each of them is a Lisp value at all times. */
struct handler;
struct unwind {
    lisp to;     /* 0, or where control is on its way to: a BLOCK or TAGS frame, the tag of a block or a tagbody of
                    compiled code, THROWING, HANDLING, FAILING, STOPPING */
    lisp tag;    /* GO: the place in the body, or which of the tags it is. THROW: the tag. HANDLING and FAILING: the
                    condition */
    lisp clause; /* HANDLING: the clause that takes the condition, */
    struct handler *handler; /* and the HANDLER-CASE it belongs to */
};

/* The words of the running thread that code for the processor reads and
 * writes itself, side by side, so that one register reaches them all, and
 * after them the functions of the kernel that such code calls (native.c,
 * vm.c). The kernel is somewhere else in memory on every boot, and code
 * that a saved world holds must not know where: it is handed the address
 * of this when it is entered, and finds everything from there. So the
 * order of these words is part of what an image is (FORMAT, image.c), and
 * lisp/native.lisp is told where each is (NATIVE-LAYOUT).
 *
 * The rest of the runtime knows the words by the names that they had when
 * each was a variable of its own. */
struct lisp_machine {
    lisp *sp;                    /* g_sp: the top of the value stack */
    struct unwind unwind;        /* g_unwind */
    volatile int attention;      /* lisp_attention */
    unsigned bound;              /* g_bound: how many special variables are bound */
    struct lisp_multiple values; /* lisp_values */
    uint64_t original;           /* g_original (vm.c): which functions in C still have the names that the
                                    instructions for them go by */
    lisp *stack_end;             /* where the value stack is full */
    uintptr_t c_limit;           /* the lowest address that the thread's own stack may reach while it evaluates */
    lisp t;                      /* the symbol T */
    /* What code for the processor calls: the first is its own way of calling a function (entry.S), the others are
       functions in C, which take up to two arguments and give a word back. */
    void (*call)(void);
    uint64_t (*step)(lisp *locals, uint64_t word);
    uint64_t (*unwinding)(lisp *locals);
    uint64_t (*safe_point)(lisp *locals);
    uint64_t (*arguments)(lisp function, uint64_t argc);
    uint64_t (*finish)(lisp *locals);
    uint64_t (*stack_full)(void);
    /* And three that make an object for it, which is all that they do: nothing of the value stack is theirs. */
    lisp (*cons)(lisp car, lisp cdr);
    lisp (*cell)(lisp value);
    lisp (*closure)(lisp code, uint64_t count, const lisp *top);
};
extern struct lisp_machine lisp_machine;
#define lisp_values lisp_machine.values

void lisp_eval_init(const struct boot_file *files); /* the files that LOAD can find */
int  lisp_boot_file(const char *name);              /* is there one of that name among them? */
const struct boot_file *lisp_boot_file_of(lisp name); /* the one of that name, a string, or NULL */
void lisp_eval_start(void);                 /* for a thread that has just been given the runtime: how deep it may go */
lisp lisp_eval(lisp form, lisp env);        /* env is NIL outside every binding */
lisp lisp_compiler(void);                   /* the function that compiles a form and runs it, or NIL: no compiler yet */
void lisp_set_function(lisp symbol, lisp function); /* the one way to give a symbol a function: the machine that runs
                                               compiled code has to hear of it (vm.c) */
void lisp_vm_init(void);                    /* vm.c: the functions in C that the machine has instructions for */
lisp lisp_eval_form(lisp form);             /* EVAL and LOAD: compiled and run when there is a compiler, walked if not */
lisp lisp_apply(lisp function, unsigned argc, lisp *argv); /* the arguments have to be on the value stack */
int  lisp_evaluate(lisp form);              /* at the top level. 1: lisp_values has the values, the only one too. 0: the
                                               condition that nothing handled */
int  lisp_call(lisp function, unsigned argc, const lisp *argv); /* the same for a function and its arguments,
                                               at the bottom of a thread; -1 when the thread was told to stop */
/* Not zero when a thread that comes to a safe point has something to look
 * at there: it is time to collect, another thread wants the runtime, this
 * one was told to stop, Ctrl-C was typed, an interrupt came in. Whoever
 * brings one of those about says so here, and the safe point itself is a
 * look at this and nothing more for as long as nobody has (eval.h). */
#define lisp_attention lisp_machine.attention
int  lisp_safe_point(void);                 /* for C that has waited: the evaluator's safe point. 0: return, an exit is
                                               under way */
int  lisp_unwinding(void);
lisp lisp_fail(const char *control, ...);   /* an error: ~S and ~A take a lisp, ~X an integer for hexadecimal, ~Z a C
                                               string. Returns NIL, to be returned */
lisp lisp_fail_as(const char *type, const char *slot, lisp value, const char *control, ...);
lisp lisp_wants(const char *what, lisp x);  /* the error of a primitive that was given x where it wants something else */
int  lisp_signal(lisp condition);           /* 1: a HANDLER-CASE takes it, and control is on its way there. 0: none does */
lisp lisp_error(lisp condition);            /* the same, and with no handler to the top level. Returns NIL */
void lisp_eval_roots(void);                 /* for the collector: lisp_reach for everything the evaluator holds */
lisp lisp_macroexpand_1(lisp form, int *expanded);
lisp lisp_load(lisp name);                  /* evaluate the forms of the boot file of that name */
void lisp_load_text(const void *text, size_t size, lisp name); /* and of a text in UTF-8; the name is for what an
                                               error says, a string that the caller holds */
int  lisp_out_of_stack(void);               /* for C that calls itself: fails, and says 1, when it must go no deeper */
lisp *lisp_stack(void);                     /* the top of the value stack */
int  lisp_push(lisp x);                     /* 0 after failing, when the stack is full */
void lisp_stack_drop(lisp *to);             /* back to where lisp_stack said */

/* What the evaluator keeps for a thread while another has the runtime:
 * its two stacks, and the few words that say where it is. eval.c knows
 * what is in one; thread.c gives each thread the memory for it. */
struct lisp_evaluator;
uint64_t lisp_evaluator_bytes(void);                    /* how much memory one takes, stacks included */
void lisp_evaluator_new(struct lisp_evaluator *e);      /* in that much memory: empty stacks */
void lisp_evaluator_out(struct lisp_evaluator *e);      /* the running thread's state goes into e, and its bindings with it */
void lisp_evaluator_in(const struct lisp_evaluator *e); /* and comes back */
void lisp_evaluator_reach(const struct lisp_evaluator *e); /* for the collector: what a thread that is not running holds */
void lisp_bindings_out(void);                           /* the running thread's bindings are undone: a variable is what it
                                                           is outside them */
void lisp_bindings_in(void);                            /* and done again */
int  lisp_function_rebind(lisp function);               /* for an image: a function in C gets its place in this kernel's
                                                           table, by its name; 0 when no row has that name */

/* thread.c: the threads of the Lisp world. One of them at a time has the
 * runtime, and it gives it up only at a safe point or to wait. */
enum lisp_turn { LISP_GO_ON, LISP_STOP, LISP_BREAK };
struct thread *lisp_first_thread(void (*main)(void));   /* the thread that the Lisp world starts on: it runs main */
enum lisp_turn lisp_thread_safe_point(int may_stop);    /* from the evaluator's safe point: let another thread have its
                                                           turn, and say whether this one is to stop, or was interrupted */
void lisp_thread_roots(void);                           /* for the collector: what the other threads hold */
void lisp_interrupt(enum lisp_interrupt source);        /* from its handler: the event of that source is signalled */

/* unsafe.c: the package CLARA.UNSAFE */
void lisp_unsafe_init(const struct framebuffer *fb);    /* the screen, for a driver in Lisp to draw on */

/* vm.c: the machine that compiled code runs on */
void lisp_compiled_watched(unsigned points);            /* for the self-test: a collection before each of the next so
                                                           many safe points that compiled code comes to */
void lisp_native_watched(unsigned points);              /* the same for the safe points of code for the processor */
int  lisp_compiled_watching(void);                      /* is the self-test still waiting for some of either? */
void lisp_native_counts(uint64_t *entered, uint64_t *stepped, uint64_t *slow); /* how often the processor has
                                                           been sent into code of its own, and how often that code
                                                           left an instruction, and a call of a function in Lisp,
                                                           to C */

/* native.c: code for the processor, the region of memory that it lies in,
 * and how the heap holds on to it */
struct lisp_code_state {
    uint64_t size;   /* bytes, from the first piece of code to the end of the last */
    uint64_t free;   /* of those, the bytes that hold none any more */
    uint64_t pieces; /* how many functions' code there is */
    uint64_t made;   /* and how many were ever made, on this boot */
};
void     lisp_native_init(void);                        /* what code for the processor calls is put where it finds it */
uint64_t lisp_native_entry(lisp code);                  /* where a function of that code is entered by such code, or 0 */
void     lisp_code_free(lisp address);                  /* from the collector: nothing holds that code any more */
void     lisp_code_state(struct lisp_code_state *state);
uint64_t lisp_code_bytes(void);                         /* for an image: how many bytes the code takes, as it lies, */
void     lisp_code_save(void *to);                      /* those bytes, */
int      lisp_code_restore(const void *from, uint64_t bytes); /* and an empty region made a copy of them; 0: no memory */
void     lisp_code_empty(void);                         /* and empty again */
int      lisp_code_holds(uint64_t address);             /* is that an address in code that is there? */

/* image.c: the heap as a file, and a file as the heap */
int  lisp_image_load(const struct boot_file *file);     /* 1: the heap and the roots are what that file holds. 0: they
                                                           are as they were, and the boot report says why */

/* builtin.c: the functions written in C */
#define LISP_MANY 255 /* for max: any number of arguments */
struct lisp_primitive {
    const char *name; /* in COMMON-LISP, or in the package named before a colon: external, or internal when it
                         begins with % */
    lisp (*fn)(unsigned argc, lisp *argv);
    uint8_t min, max; /* how many arguments it takes */
};
#define LISP_PRIMITIVE(name) lisp name(unsigned argc, lisp *argv)
LISP_PRIMITIVE(lisp_p_make_thread);
LISP_PRIMITIVE(lisp_p_current_thread);
LISP_PRIMITIVE(lisp_p_threadp);
LISP_PRIMITIVE(lisp_p_thread_name);
LISP_PRIMITIVE(lisp_p_thread_alive_p);
LISP_PRIMITIVE(lisp_p_all_threads);
LISP_PRIMITIVE(lisp_p_join_thread);
LISP_PRIMITIVE(lisp_p_destroy_thread);
LISP_PRIMITIVE(lisp_p_interrupt_thread);
LISP_PRIMITIVE(lisp_p_thread_yield);
LISP_PRIMITIVE(lisp_p_sleep);
LISP_PRIMITIVE(lisp_p_make_lock);
LISP_PRIMITIVE(lisp_p_acquire_lock);
LISP_PRIMITIVE(lisp_p_release_lock);
LISP_PRIMITIVE(lisp_p_make_event);
LISP_PRIMITIVE(lisp_p_signal_event);
LISP_PRIMITIVE(lisp_p_wait_event);
LISP_PRIMITIVE(lisp_p_interrupt_event);
LISP_PRIMITIVE(lisp_p_message_interrupt);
LISP_PRIMITIVE(lisp_p_serial_break);
LISP_PRIMITIVE(lisp_p_memory_8);
LISP_PRIMITIVE(lisp_p_memory_16);
LISP_PRIMITIVE(lisp_p_memory_32);
LISP_PRIMITIVE(lisp_p_memory_64);
LISP_PRIMITIVE(lisp_p_set_memory_8);
LISP_PRIMITIVE(lisp_p_set_memory_16);
LISP_PRIMITIVE(lisp_p_set_memory_32);
LISP_PRIMITIVE(lisp_p_set_memory_64);
LISP_PRIMITIVE(lisp_p_fill_memory_32);
LISP_PRIMITIVE(lisp_p_copy_memory);
LISP_PRIMITIVE(lisp_p_expand_bits_32);
LISP_PRIMITIVE(lisp_p_fill_rectangle_32);
LISP_PRIMITIVE(lisp_p_copy_rectangle_32);
LISP_PRIMITIVE(lisp_p_blend_shades_32);
LISP_PRIMITIVE(lisp_p_system_file);
LISP_PRIMITIVE(lisp_p_allocate_memory);
LISP_PRIMITIVE(lisp_p_free_memory);
LISP_PRIMITIVE(lisp_p_port_8);
LISP_PRIMITIVE(lisp_p_port_16);
LISP_PRIMITIVE(lisp_p_port_32);
LISP_PRIMITIVE(lisp_p_set_port_8);
LISP_PRIMITIVE(lisp_p_set_port_16);
LISP_PRIMITIVE(lisp_p_set_port_32);
LISP_PRIMITIVE(lisp_p_framebuffer);
LISP_PRIMITIVE(lisp_p_serial_device);
LISP_PRIMITIVE(lisp_p_serial_byte);
LISP_PRIMITIVE(lisp_p_take_screen);
LISP_PRIMITIVE(lisp_p_give_screen);
LISP_PRIMITIVE(lisp_p_map_memory);
LISP_PRIMITIVE(lisp_p_pci_configuration);
LISP_PRIMITIVE(lisp_p_keyboard_break);
LISP_PRIMITIVE(lisp_p_sha_512);
LISP_PRIMITIVE(lisp_p_ed25519);
LISP_PRIMITIVE(lisp_p_digest);
LISP_PRIMITIVE(lisp_p_hmac);
LISP_PRIMITIVE(lisp_p_aes_128_gcm_seal);
LISP_PRIMITIVE(lisp_p_aes_128_gcm_open);
LISP_PRIMITIVE(lisp_p_x25519);
LISP_PRIMITIVE(lisp_p_power_mod);
LISP_PRIMITIVE(lisp_p_ecdsa);
LISP_PRIMITIVE(lisp_p_internet_sum);
LISP_PRIMITIVE(lisp_p_start_state);
LISP_PRIMITIVE(lisp_p_power_off);
LISP_PRIMITIVE(lisp_p_reset);
LISP_PRIMITIVE(lisp_p_power_button);
LISP_PRIMITIVE(lisp_p_memory_string);
LISP_PRIMITIVE(lisp_p_string_bytes);
LISP_PRIMITIVE(lisp_p_string_memory);
LISP_PRIMITIVE(lisp_p_heap_image);
LISP_PRIMITIVE(lisp_p_make_compiled_function);
LISP_PRIMITIVE(lisp_p_compiled_function_code);
LISP_PRIMITIVE(lisp_p_compiled_function_p);
LISP_PRIMITIVE(lisp_p_function_lambda_expression);
LISP_PRIMITIVE(lisp_p_variable_kind);
LISP_PRIMITIVE(lisp_p_native_layout);
LISP_PRIMITIVE(lisp_p_install_native_code);
LISP_PRIMITIVE(lisp_p_native_code_bytes);
LISP_PRIMITIVE(lisp_p_native_function);
LISP_PRIMITIVE(lisp_p_untranslated_code);
LISP_PRIMITIVE(lisp_p_native_functions);
extern const struct lisp_primitive lisp_primitives[];
extern const unsigned lisp_primitive_count;

/* lisp.c */
void lisp_init(struct boot_info *bi); /* the world: an image of it, if the boot volume had one, and otherwise empty */
void lisp_selftest(void);
void lisp_run(void); /* unless the world is an image's, load boot.lisp, check the evaluator, and load the console, the
                        drivers and the listener; then start them, and listen until the input ends */
unsigned lisp_eval_texts(void); /* the evaluator's part of the self-test, again: how many texts it evaluated */
