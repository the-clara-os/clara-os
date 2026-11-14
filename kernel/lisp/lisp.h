/* The Lisp runtime: what a Lisp object is, and the substrate's part in
 * making, reading and printing one.
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
 * the collector will mark in (M6c), and a length in the other 48 bits, the
 * characters of a string or the items of a vector. With a header on
 * everything the heap can be walked from one end to the other, which is
 * what the collector's sweep and the saved image (M10) will do; the price
 * is a third word in every cons.
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
#define LISP_NIL       (VM_HEAP_BASE | LISP_TAG_SYMBOL)

#define LISP_FIXNUM_MAX (((int64_t)1 << 62) - 1) /* and the least is -LISP_FIXNUM_MAX - 1 */
#define LISP_CODE_LIMIT 0x110000u                /* characters are Unicode code points */

/* What the first word of an object in the heap says it is. Zero is not a
 * type, so memory that was never an object does not pass for one. */
enum lisp_type { LISP_CONS = 1, LISP_SYMBOL, LISP_STRING, LISP_VECTOR, LISP_PACKAGE, LISP_TYPES };

struct lisp_cons {
    lisp header, car, cdr;
};

struct lisp_symbol {
    lisp header;
    lisp name;     /* a string */
    lisp package;  /* the one it lives in, or NIL */
    lisp value;    /* LISP_UNBOUND until it has one */
    lisp function; /* the same */
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

/* What the substrate itself holds on to in the Lisp world. The collector
 * will start from here (M6c), and a saved image has to bring these back
 * (M10). */
struct lisp_roots {
    lisp t, quote, function;
    lisp package;               /* the symbol *PACKAGE*, whose value is the package that names are read in */
    lisp packages;              /* a list of every package there is */
    lisp keyword, common_lisp, user;
};
extern struct lisp_roots lisp_roots;

/* heap.c: where objects live, and the making of the plain ones */
void    *lisp_alloc(enum lisp_type type, uint64_t length); /* a new object, all zeroes after its header */
uint64_t lisp_object_words(lisp header);                   /* how long the object under that header is */
uint64_t lisp_heap_census(uint64_t count[LISP_TYPES]);     /* walk the heap, count by type; bytes in use */
lisp     lisp_cons(lisp car, lisp cdr);
lisp     lisp_make_string(const uint32_t *chars, uint64_t length); /* chars may be NULL, to fill it in later */
lisp     lisp_make_vector(uint64_t length);                /* of fixnum zeroes */

/* symbol.c: symbols, and the packages that find them by name. A name here
 * is characters and how many, as the reader has them. */
enum lisp_access { LISP_ABSENT, LISP_INTERNAL, LISP_EXTERNAL, LISP_INHERITED };
void lisp_symbols_init(void);
lisp lisp_make_symbol(const uint32_t *name, uint64_t length); /* in no package */
lisp lisp_make_package(const char *name, const char *nickname, lisp uses); /* ASCII names; nickname may be NULL */
lisp lisp_find_package(const uint32_t *name, uint64_t length); /* by name or nickname; 0 when there is none */
enum lisp_access lisp_find_symbol(lisp package, const uint32_t *name, uint64_t length, lisp *symbol);
lisp lisp_intern(lisp package, const uint32_t *name, uint64_t length); /* the symbol of that name there, made if need be */
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
    const uint8_t *where; /* and the place */
    unsigned depth;       /* how many lists are open around what is being read */
    uint32_t token[LISP_TOKEN_MAX];
};

void lisp_reader_init(struct lisp_reader *r, const void *text, size_t size);
enum lisp_read_status lisp_read(struct lisp_reader *r, lisp *form); /* the next form of the text */
void lisp_reader_where(const struct lisp_reader *r, unsigned *line, unsigned *column); /* r->where, both from 1 */

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

/* print.c: an object as text that the reader would read back as the same
 * object, where there is such a text. It comes out in UTF-8, a byte at a
 * time. */
void lisp_print(lisp x, void (*put)(void *to, char c), void *to);

/* lisp.c */
void lisp_init(void);
void lisp_selftest(void);
void lisp_listen(void); /* read forms from the serial port and print them back, until the input ends */
