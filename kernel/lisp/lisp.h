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
 * collector's sweep does and the saved image (M10) will do; the price is a
 * third word in every cons.
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

/* Whatever can be the function of a symbol. Which of the four it is sits
 * where the length would be. */
enum lisp_function_kind {
    LISP_PRIMITIVE, /* a function written in C: code is its place in lisp_primitives */
    LISP_SPECIAL_OPERATOR, /* IF, LET and the like: code is its place in the evaluator's table */
    LISP_CLOSURE,   /* a function written in Lisp: code is (lambda-list . body) */
    LISP_MACRO,     /* the same, called with the subforms of a form to make the form to evaluate instead */
};

struct lisp_function {
    lisp header;
    lisp name; /* a symbol, or NIL for a LAMBDA */
    lisp code; /* a fixnum for the two kinds in C, never an address: an image has to outlive the kernel that saved it (M10) */
    lisp env;  /* the environment a closure or a macro was made in (eval.c) */
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

/* What the substrate itself holds on to in the Lisp world. The collector
 * starts from here, and from what the evaluator keeps (eval.c): every
 * word of this is a Lisp value. A saved image has to bring these back
 * (M10). */
struct lisp_roots {
    lisp t, quote, function;
    lisp quasiquote, unquote, splice; /* what the reader makes of ` , and ,@ */
    lisp package;               /* the symbol *PACKAGE*, whose value is the package that names are read in */
    lisp packages;              /* a list of every package there is */
    lisp keyword, common_lisp, user;
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
void     lisp_heap_state(struct lisp_heap *state);
uint64_t lisp_collect(void);                               /* free what is not in use; how many bytes that was */
void     lisp_reach(lisp x);                               /* from the collector's helpers: x is in use */
int      lisp_heap_safe_point(void);                       /* collect if it is time; 0 when the heap is full even so */
void     lisp_collect_if_full(void);                       /* collect, if the last time left the heap full */
uint64_t lisp_collect_every(uint64_t n);                   /* at every nth safe point; 0: when it is time. What it was */
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
    uint32_t token[LISP_TOKEN_MAX];
};

void lisp_reader_init(struct lisp_reader *r, const void *text, size_t size);
enum lisp_read_status lisp_read(struct lisp_reader *r, lisp *form); /* the next form of the text */
void lisp_reader_where(const struct lisp_reader *r, unsigned *line, unsigned *column); /* r->where, both from 1 */
lisp lisp_string_from_utf8(const void *text, size_t size); /* as far as it is UTF-8 */

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
struct lisp_values {
    unsigned count;
    lisp value[LISP_VALUES_MAX];
};
extern struct lisp_values lisp_values;

void lisp_eval_init(const struct boot_file *files); /* the files that LOAD can find */
void lisp_eval_start(void);                 /* the thread that calls this is the one that evaluates */
lisp lisp_eval(lisp form, lisp env);        /* env is NIL outside every binding */
lisp lisp_apply(lisp function, unsigned argc, lisp *argv); /* the arguments have to be on the value stack */
int  lisp_evaluate(lisp form);              /* at the top level. 1: lisp_values has the values, the only one too. 0: the
                                               condition that nothing handled */
int  lisp_unwinding(void);
lisp lisp_fail(const char *control, ...);   /* an error: ~S and ~A take a lisp, ~Z a C string. Returns NIL, to be returned */
lisp lisp_fail_as(const char *type, const char *slot, lisp value, const char *control, ...);
lisp lisp_wants(const char *what, lisp x);  /* the error of a primitive that was given x where it wants something else */
int  lisp_signal(lisp condition);           /* 1: a HANDLER-CASE takes it, and control is on its way there. 0: none does */
lisp lisp_error(lisp condition);            /* the same, and with no handler to the top level. Returns NIL */
void lisp_eval_roots(void);                 /* for the collector: lisp_reach for everything the evaluator holds */
lisp lisp_macroexpand_1(lisp form, int *expanded);
lisp lisp_load(lisp name);                  /* evaluate the forms of the boot file of that name */
int  lisp_out_of_stack(void);               /* for C that calls itself: fails, and says 1, when it must go no deeper */
lisp *lisp_stack(void);                     /* the top of the value stack */
int  lisp_push(lisp x);                     /* 0 after failing, when the stack is full */
void lisp_stack_drop(lisp *to);             /* back to where lisp_stack said */

/* builtin.c: the functions written in C */
#define LISP_MANY 255 /* for max: any number of arguments */
struct lisp_primitive {
    const char *name; /* in COMMON-LISP: external, or internal when it begins with % */
    lisp (*fn)(unsigned argc, lisp *argv);
    uint8_t min, max; /* how many arguments it takes */
};
extern const struct lisp_primitive lisp_primitives[];
extern const unsigned lisp_primitive_count;
extern int lisp_console_fresh;              /* nothing has been written on the console's line yet */
void lisp_console_put(void *to, char c);    /* for lisp_print: to the serial port and the screen */
void lisp_fresh_line(void);                 /* a new line, unless the console is at the start of one */

/* lisp.c */
void lisp_init(const struct boot_file *files);
void lisp_selftest(void);
void lisp_run(void); /* load boot.lisp, check the evaluator, then read and evaluate what is typed until the input ends */
unsigned lisp_eval_texts(void); /* the evaluator's part of the self-test, again: how many texts it evaluated */
