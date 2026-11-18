/* What the evaluator keeps for the thread that is running, for the two
 * files that run Lisp: eval.c, which walks the forms as the reader made
 * them, and vm.c, which runs what the compiler made of them. Nothing else
 * includes this: the rest of the runtime has lisp.h.
 *
 * Both keep what they hold on the value stack, bind special variables on
 * the stack of bindings, and leave by returning: whichever of them is on
 * the way of a non-local exit sees g_unwind.to, undoes what it did, and
 * returns in turn. So a function of either kind can call one of the other,
 * and an exit, a condition or a THROW passes through both. */
#pragma once
#include "lisp.h"

enum {
    STACK_SLOTS = 65536, /* of the value stack */
    STACK_SPARE = 64,    /* past its end, for the pushes that are not checked: a few between two checks */
    BINDINGS = 8192,     /* special variables bound at one time */
};

/* What g_unwind.to is when it is not a frame of the evaluator's or a tag of
 * compiled code's: immediates, like LISP_UNBOUND. */
#define THROWING 0x17ULL
#define FAILING  0x1fULL /* a condition that no HANDLER-CASE takes, on its way to the top level */
#define HANDLING 0x27ULL /* a condition on its way to the HANDLER-CASE that takes it */
#define STOPPING 0x2fULL /* the thread was told to stop: all the way out, past every handler */

struct binding {
    lisp symbol, value; /* a special variable, and the value it had before it was bound */
};

/* A HANDLER-CASE that is being evaluated. The evaluator has one in a
 * variable of the C function that evaluates the form, and compiled code
 * has one in two words of the value stack: both are in this list, the
 * innermost first. */
struct handler {
    struct handler *outer;
    lisp clauses; /* each begins with the type it is for: (type ([variable]) form...) to the evaluator, (type . n) in
                     compiled code */
};

/* The collector looks at every lisp here whether or not an exit is under
 * way, so each of them is a Lisp value at all times. */
struct unwind {
    lisp to;     /* 0, or where control is on its way to: a BLOCK or TAGS frame, the tag of a block or a tagbody of
                    compiled code, THROWING, HANDLING, FAILING, STOPPING */
    lisp tag;    /* GO: the place in the body, or which of the tags it is. THROW: the tag. HANDLING and FAILING: the
                    condition */
    lisp clause; /* HANDLING: the clause that takes the condition, */
    struct handler *handler; /* and the HANDLER-CASE it belongs to */
};

/* A CATCH that is waiting, in the same two ways as a handler. */
struct catch {
    struct catch *outer;
    lisp *tag; /* on the value stack */
};

extern lisp *g_stack; /* STACK_SLOTS + STACK_SPARE words: the running thread's */
extern lisp *g_sp;
extern unsigned g_bound;
extern struct handler *g_handlers;
extern struct unwind g_unwind;
extern struct catch *g_catches;
extern unsigned g_cleaning; /* the cleanups of UNWIND-PROTECT that the thread is in the middle of: none is cut short */
extern const struct lisp_primitive *g_primitive; /* the function in C that was called last: an error names it */

/* Symbols the evaluator knows by sight: all in COMMON-LISP or KEYWORD, so
 * the packages hold them. */
struct known {
    lisp lambda, declare, special, optional, rest, body, key, allow_other_keys, aux, whole, environment;
    lisp execute, eval, allow, no_error, condition, destructuring_bind;
};
extern struct known S;

int  safe_point(void);                      /* 0: an exit is under way, and the evaluation is not to go on */
void bind_special(lisp symbol, lisp value);
void unbind(unsigned to);                   /* back to that many bindings */
lisp make_function(enum lisp_function_kind kind, lisp name, lisp code, lisp env);
lisp property(lisp symbol, lisp indicator); /* what a symbol has under an indicator on its property list, or NIL */
lisp unbound_variable(lisp symbol);         /* the errors that a program can tell apart: each returns NIL */
lisp undefined_function(lisp symbol);
lisp program_error(const char *control, ...);
lisp control_error(const char *control, ...);
lisp stack_is_full(void);

/* The values of the form that was evaluated last, all in lisp_values: with
 * one value, only the count is sure to be there until this is called. */
static inline void settle(lisp value)
{
    if (lisp_values.count == 1)
        lisp_values.value[0] = value;
}

static inline int special(lisp symbol)
{
    return lisp_symbol_flags(symbol) & LISP_SPECIAL;
}

static inline int constant(lisp symbol)
{
    return lisp_symbol_flags(symbol) & LISP_CONSTANT;
}

/* vm.c: compiled code, called. The arguments are on the value stack. */
lisp lisp_call_compiled(lisp function, unsigned argc, lisp *argv);
