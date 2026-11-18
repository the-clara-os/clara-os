/* The machine that compiled code runs on.
 *
 * The compiler is Lisp (lisp/compiler.lisp). What it makes of a LAMBDA is
 * code: a vector that holds the instructions, the constants they name, and
 * what the function takes (enum lisp_code, lisp.h). A compiled function is
 * a function of the kind LISP_COMPILED, whose code is that vector and whose
 * environment is the values it closes over, in a vector, or NIL.
 *
 * An instruction is one word, a fixnum: which operation in its lowest
 * eight bits, an operand in the 24 above them and another in the bits
 * above those. The operations work on a stack, and that stack is the
 * evaluator's value stack (eval.c): a call of a compiled function takes
 * the function itself, then its local variables, the parameters first,
 * then what the instructions push and pop, all in one stretch of it.
 * Nothing that the function holds is anywhere else, so the collector finds
 * it all where it looks already, and a safe point is what it is in the
 * evaluator: every call, and every jump backwards.
 *
 * A variable that no function inside this one uses lives in its slot. One
 * that an inner function uses is handed to that function when it is made,
 * in its vector of closed-over values: the value itself when the variable
 * is never set, and otherwise a cell that both hold, a vector of one item.
 * Which of the three a variable is the compiler knows, and says with the
 * instruction it chooses.
 *
 * Leaving is done the evaluator's way, by returning: RETURN-FROM, GO and
 * THROW that cannot be a jump inside the function set g_unwind and so does
 * an error, in a function that was called from here or in an instruction.
 * What the function has in force at that moment is on the stack as
 * records, six words each, the innermost first: a block or a tagbody that
 * something inside may leave for, a CATCH, a HANDLER-CASE, an
 * UNWIND-PROTECT, a cleanup that is under way. The way out goes through
 * them one by one. A record that the exit is meant for takes it: the stack
 * is cut back to the record, the bindings to what they were when it was
 * made, and the instructions go on at the place it names. The record of an
 * UNWIND-PROTECT puts the exit and its values on the stack and runs the
 * cleanup, whose last instruction takes the exit up again. With no record
 * left the function returns, and its caller has the exit to look at. */
#include "eval.h"

enum {
    RECORD = 6,    /* words of a record */
    NESTED = 64,   /* functions inside functions, as deep as code is looked into */
    SMALL = 0xffff /* the most that a function has of parameters, of local variables, of stack */
};

/* A record on the value stack:
 *   [0] the record outside it, of this call; an address, or 0
 *   [1] its kind, and above the lowest eight bits the instruction to go on at
 *   [2] how many special variables were bound when it was made
 *   [3] what it is known by: the tag of a block or of a tagbody, a cons whose CAR is NIL once it has been left; the
 *       tag of a CATCH; the clauses of a HANDLER-CASE
 *   [4] [5] for a CATCH a struct catch, for a HANDLER-CASE a struct handler: what THROW and a condition look for
 * Addresses are multiples of eight, so the collector takes them for fixnums. */
enum { R_BLOCK = 1, R_TAGBODY, R_CATCH, R_HANDLER, R_PROTECT, R_CLEANING };

/* What an operand of an instruction is, for looking at code before it runs. */
enum { NONE, COUNT, CONSTANT, SYMBOL, CLAUSES, CODE, LOCAL, CLOSED, TARGET, KIND };

/* The operations, in the order of their numbers: lisp/compiler.lisp has the
 * same list, and lisp/host/tests.lisp holds the two against each other.
 * What each does to the stack is said where it is done, below. */
enum {
    OP_CONST, OP_LOCAL, OP_SET_LOCAL, OP_CLOSED, OP_CELL, OP_CELL_REF, OP_CELL_SET, OP_SPECIAL, OP_SET_SPECIAL,
    OP_BIND, OP_UNBIND, OP_FUNCTION, OP_CLOSURE, OP_CALL, OP_RETURN, OP_RETURN_ONE, OP_ONE, OP_DROP, OP_NIP, OP_DUP,
    OP_JUMP, OP_JUMP_IF_NIL, OP_JUMP_IF_TRUE, OP_JUMP_IF_SUPPLIED, OP_SUPPLIED, OP_VALUES_PUSH, OP_VALUES_CALL,
    OP_VALUES_SPREAD, OP_VALUES_SAVE, OP_VALUES_RESTORE, OP_BLOCK, OP_TAGBODY, OP_CATCH, OP_HANDLER, OP_PROTECT,
    OP_UNLINK, OP_RETURN_TO, OP_GO_TO, OP_THROW, OP_CLEANUP, OP_CLEANUP_END, OP_DISPATCH, OP_FSET, OP_DEFMACRO,
    OP_DEFVAR, OP_DEFCONSTANT, OP_FAIL, OPERATIONS
};

static const struct operation {
    const char *name;
    uint8_t a, b; /* what its two operands are */
} operations[OPERATIONS] = {
    { "CONST", CONSTANT, NONE },
    { "LOCAL", LOCAL, NONE },
    { "SET-LOCAL", LOCAL, NONE },
    { "CLOSED", CLOSED, NONE },
    { "CELL", NONE, NONE },
    { "CELL-REF", NONE, NONE },
    { "CELL-SET", NONE, NONE },
    { "SPECIAL", SYMBOL, NONE },
    { "SET-SPECIAL", SYMBOL, NONE },
    { "BIND", SYMBOL, NONE },
    { "UNBIND", COUNT, NONE },
    { "FUNCTION", SYMBOL, NONE },
    { "CLOSURE", CODE, COUNT },
    { "CALL", COUNT, NONE },
    { "RETURN", NONE, NONE },
    { "RETURN-ONE", NONE, NONE },
    { "ONE", NONE, NONE },
    { "DROP", COUNT, NONE },
    { "NIP", COUNT, NONE },
    { "DUP", NONE, NONE },
    { "JUMP", TARGET, NONE },
    { "JUMP-IF-NIL", TARGET, NONE },
    { "JUMP-IF-TRUE", TARGET, NONE },
    { "JUMP-IF-SUPPLIED", TARGET, LOCAL },
    { "SUPPLIED", LOCAL, NONE },
    { "VALUES-PUSH", LOCAL, NONE },
    { "VALUES-CALL", LOCAL, NONE },
    { "VALUES-SPREAD", COUNT, NONE },
    { "VALUES-SAVE", NONE, NONE },
    { "VALUES-RESTORE", NONE, NONE },
    { "BLOCK", TARGET, LOCAL },
    { "TAGBODY", TARGET, LOCAL },
    { "CATCH", TARGET, NONE },
    { "HANDLER", TARGET, CLAUSES },
    { "PROTECT", TARGET, NONE },
    { "UNLINK", COUNT, NONE },
    { "RETURN-TO", CONSTANT, NONE },
    { "GO-TO", COUNT, CONSTANT },
    { "THROW", NONE, NONE },
    { "CLEANUP", NONE, NONE },
    { "CLEANUP-END", NONE, NONE },
    { "DISPATCH", COUNT, NONE },
    { "FSET", SYMBOL, NONE },
    { "DEFMACRO", CONSTANT, NONE },
    { "DEFVAR", SYMBOL, NONE },
    { "DEFCONSTANT", SYMBOL, NONE },
    { "FAIL", KIND, CONSTANT },
};

/* The types of the errors that FAIL makes, by its first operand. */
static const char *const failures[] = { "ERROR", "PROGRAM-ERROR", "CONTROL-ERROR" };

static unsigned g_watched; /* the self-test wants a collection at so many more safe points of compiled code */

static inline unsigned small(lisp x)
{
    return (unsigned)lisp_fixnum_value(x);
}

/* For the self-test (lisp.c): the collector runs before each of the next
 * so many safe points that the machine itself comes to, a call of a
 * function in Lisp and a jump backwards. Whatever the machine holds and has
 * not on the stack by then is gone when it looks again. A number, and not
 * all of them for good, because a text that goes round a loop, or calls
 * itself until the stack is full, shows nothing the thousandth time that
 * it did not show the first. */
void lisp_compiled_watched(unsigned points)
{
    g_watched = points;
}

static inline void watched(void)
{
    if (g_watched) {
        g_watched--;
        lisp_collect();
    }
}

/* A record is made, on top of the stack: the innermost of this call. */
static lisp *record(lisp *outer, unsigned kind, unsigned pad, lisp tag)
{
    lisp *r = g_sp;

    r[0] = (lisp)(uintptr_t)outer;
    r[1] = lisp_fixnum((int64_t)(kind | (uint64_t)pad << 8));
    r[2] = lisp_fixnum(g_bound);
    r[3] = tag;
    g_sp += RECORD;
    return r;
}

/* A record is no longer in force, whichever way control went past it: what
 * it stood for is undone. Returns the record outside it. Its words stay
 * where they are, for whoever cuts the stack back. */
static lisp *retire(lisp *r)
{
    switch (small(r[1]) & 0xff) {
    case R_BLOCK:
    case R_TAGBODY:
        lisp_as_cons(r[3])->car = LISP_NIL; /* a RETURN-FROM or a GO that comes for it from now on is told so */
        break;
    case R_CATCH:
        g_catches = ((struct catch *)&r[4])->outer;
        break;
    case R_HANDLER:
        g_handlers = ((struct handler *)&r[4])->outer;
        break;
    case R_CLEANING:
        g_cleaning--;
        break;
    }
    return (lisp *)(uintptr_t)r[0];
}

/* The cleanup of an UNWIND-PROTECT begins. What it must not lose goes on
 * the stack: the values of the form that was protected, or the ones that
 * the exit under way carries, and that exit; then a record that says a
 * cleanup is being done. From here to CLEANUP-END the thread is neither
 * stopped nor interrupted (g_cleaning, eval.c). The compiler has counted
 * these words into the stack that the function needs. */
static lisp *cleanup(lisp *outer)
{
    unsigned n = lisp_values.count;
    lisp *r;

    memcpy(g_sp, lisp_values.value, n * sizeof(lisp));
    g_sp += n;
    *g_sp++ = lisp_fixnum(n);
    *g_sp++ = g_unwind.to;
    *g_sp++ = g_unwind.tag;
    *g_sp++ = g_unwind.clause;
    *g_sp++ = (lisp)(uintptr_t)g_unwind.handler;
    g_unwind.to = 0;
    r = record(outer, R_CLEANING, 0, LISP_NIL);
    r[4] = r[5] = 0;
    g_cleaning++;
    return r;
}

/* A compiled function, called with arguments that are on the value stack. */
lisp lisp_call_compiled(lisp f, unsigned argc, lisp *argv)
{
    const struct lisp_function *fn = lisp_as_function(f);
    const lisp *code = lisp_as_vector(fn->code)->items;
    const lisp *instructions = lisp_as_vector(code[LISP_CODE_INSTRUCTIONS])->items;
    const lisp *constants = lisp_as_vector(code[LISP_CODE_CONSTANTS])->items;
    const lisp *closed = fn->env == LISP_NIL ? NULL : lisp_as_vector(fn->env)->items;
    const lisp *more;
    unsigned required = small(code[LISP_CODE_REQUIRED]), positional = required + small(code[LISP_CODE_OPTIONAL]);
    unsigned variables = small(code[LISP_CODE_LOCALS]), depth = small(code[LISP_CODE_DEPTH]);
    unsigned bound = g_bound, extra, i, j, k, a, b, n;
    lisp *base = g_sp, *locals = base + 1, *records = NULL, *r, *args, value = LISP_NIL, tag, symbol;
    uint64_t pc = 0, word;
    struct unwind exit;

    if (lisp_out_of_stack())
        return LISP_NIL;
    if (base + 1 + variables + depth > g_stack + STACK_SLOTS)
        return stack_is_full();

    /* The arguments go into the first local variables: the required parameters, the optional ones, a
     * list of the rest if the function asked for one, and the keyword parameters in the order of the
     * code's list of keywords. A parameter that got no argument is LISP_UNBOUND, for the instructions
     * to put the value of its default there. */
    if (argc < required)
        return program_error("~S got too few arguments", f);
    if (argc > positional && code[LISP_CODE_REST] == LISP_NIL && code[LISP_CODE_KEYS] == LISP_NIL)
        return program_error("~S got too many arguments", f);
    for (i = 0; i < positional; i++)
        locals[i] = i < argc ? argv[i] : LISP_UNBOUND;
    more = argv + positional;
    extra = argc > positional ? argc - positional : 0;
    if (code[LISP_CODE_REST] != LISP_NIL) {
        lisp list = LISP_NIL;

        for (k = extra; k--;)
            list = lisp_cons(more[k], list);
        locals[i++] = list;
    }
    if (code[LISP_CODE_KEYS] != LISP_NIL) {
        const struct lisp_vector *keys = lisp_as_vector(code[LISP_CODE_KEYS]);
        int allow = code[LISP_CODE_ALLOW] != LISP_NIL;

        n = (unsigned)lisp_length(keys->header);
        if (extra & 1)
            return program_error("~S got an odd number of keyword arguments", f);
        for (k = 0; k < extra; k += 2)
            if (more[k] == S.allow && more[k + 1] != LISP_NIL)
                allow = 1;
        for (j = 0; j < n; j++) {
            for (k = 0; k < extra && more[k] != keys->items[j]; k += 2)
                ;
            locals[i + j] = k < extra ? more[k + 1] : LISP_UNBOUND;
        }
        for (k = 0; k < extra && !allow; k += 2) {
            for (j = 0; j < n && keys->items[j] != more[k]; j++)
                ;
            if (j == n && more[k] != S.allow)
                return program_error("~S does not take the keyword argument ~S", f, more[k]);
        }
        i += n;
    }
    for (; i < variables; i++)
        locals[i] = LISP_NIL;
    base[0] = f; /* in use for as long as it runs, whatever its name comes to mean meanwhile */
    g_sp = locals + variables;

    for (;;) {
        word = (uint64_t)lisp_fixnum_value(instructions[pc++]);
        a = (unsigned)(word >> 8) & 0xffffff;
        b = (unsigned)(word >> 32);
        switch (word & 0xff) {
        case OP_CONST: /* -> the constant a */
            *g_sp++ = constants[a];
            break;
        case OP_LOCAL: /* -> what the local variable a holds */
            *g_sp++ = locals[a];
            break;
        case OP_SET_LOCAL: /* value -> */
            locals[a] = *--g_sp;
            break;
        case OP_CLOSED: /* -> the closed-over value a */
            *g_sp++ = closed[a];
            break;
        case OP_CELL: /* value -> a cell that holds it */
            value = lisp_make_vector(1);
            lisp_as_vector(value)->items[0] = g_sp[-1];
            g_sp[-1] = value;
            break;
        case OP_CELL_REF: /* cell -> what it holds */
            g_sp[-1] = lisp_as_vector(g_sp[-1])->items[0];
            break;
        case OP_CELL_SET: /* value cell -> */
            g_sp -= 2;
            lisp_as_vector(g_sp[1])->items[0] = g_sp[0];
            break;
        case OP_SPECIAL: /* -> the value of the symbol a */
            value = lisp_as_symbol(constants[a])->value;
            if (value == LISP_UNBOUND) {
                unbound_variable(constants[a]);
                goto unwind;
            }
            *g_sp++ = value;
            break;
        case OP_SET_SPECIAL: /* value -> */
            lisp_as_symbol(constants[a])->value = *--g_sp;
            break;
        case OP_BIND: /* value -> ; the symbol a is bound to it */
            bind_special(constants[a], *--g_sp);
            if (g_unwind.to)
                goto unwind;
            break;
        case OP_UNBIND: /* the a newest bindings are undone */
            unbind(g_bound - a);
            break;
        case OP_FUNCTION: /* -> the function that the symbol a names */
            symbol = constants[a];
            value = lisp_as_symbol(symbol)->function;
            if (value == LISP_UNBOUND) {
                undefined_function(symbol);
                goto unwind;
            }
            if (lisp_function_kind(value) == LISP_SPECIAL_OPERATOR || lisp_function_kind(value) == LISP_MACRO) {
                lisp_fail("~S is a macro or a special operator, not a function", symbol);
                goto unwind;
            }
            *g_sp++ = value;
            break;
        case OP_CLOSURE: /* b values -> a function of the code a that closes over them */
            value = LISP_NIL;
            if (b) {
                value = lisp_make_vector(b);
                g_sp -= b;
                memcpy(lisp_as_vector(value)->items, g_sp, b * sizeof(lisp));
            }
            value = make_function(LISP_COMPILED, lisp_as_vector(constants[a])->items[LISP_CODE_NAME], constants[a],
                                  value);
            *g_sp++ = value;
            break;
        case OP_CALL: /* function, a arguments -> its first value; the others are in lisp_values */
            args = g_sp - a;
            value = args[-1];
            if (lisp_is_symbol(value))
                value = lisp_as_symbol(value)->function;
            if (lisp_is(value, LISP_FUNCTION) && lisp_function_kind(value) == LISP_PRIMITIVE) {
                /* A function in C is called from here, without the safe point that lisp_apply is:
                 * it does not last, and the next call of a function in Lisp, or the next turn of
                 * a loop, is one. A wrong number of arguments is lisp_apply's to say. */
                const struct lisp_primitive *p = &lisp_primitives[lisp_fixnum_value(lisp_as_function(value)->code)];

                if (a >= p->min && (a <= p->max || p->max == LISP_MANY)) {
                    lisp_values.count = 1;
                    g_primitive = p;
                    value = p->fn(a, args);
                } else
                    value = lisp_apply(args[-1], a, args);
            } else {
                watched();
                value = lisp_apply(args[-1], a, args);
            }
            g_sp = args - 1;
            if (g_unwind.to)
                goto unwind;
            *g_sp++ = value;
            break;
        case OP_RETURN: /* value -> ; the function returns it, and the values that lisp_values has */
            value = *--g_sp;
            goto leave;
        case OP_RETURN_ONE: /* value -> ; the function returns it, the one value */
            value = *--g_sp;
            lisp_values.count = 1;
            goto leave;
        case OP_ONE: /* what is on top is all the values there are */
            lisp_values.count = 1;
            break;
        case OP_DROP: /* a values -> */
            g_sp -= a;
            break;
        case OP_NIP: /* a values, value -> value */
            g_sp -= a;
            g_sp[-1] = g_sp[a - 1];
            break;
        case OP_DUP: /* value -> value value */
            g_sp[0] = g_sp[-1];
            g_sp++;
            break;
        case OP_JUMP: /* on at a; backwards is a safe point, so that a loop can be stopped and others get their turn */
            if (a < pc) {
                watched();
                if (!safe_point())
                    goto unwind;
            }
            pc = a;
            break;
        case OP_JUMP_IF_NIL: /* value -> */
            if (*--g_sp == LISP_NIL)
                pc = a;
            break;
        case OP_JUMP_IF_TRUE: /* value -> */
            if (*--g_sp != LISP_NIL)
                pc = a;
            break;
        case OP_JUMP_IF_SUPPLIED: /* on at a when the parameter in the local variable b got an argument */
            if (locals[b] != LISP_UNBOUND)
                pc = a;
            break;
        case OP_SUPPLIED: /* -> T when the parameter in the local variable a got an argument */
            *g_sp++ = locals[a] != LISP_UNBOUND ? lisp_roots.t : LISP_NIL;
            break;
        case OP_VALUES_PUSH: /* first value -> every value of the form; the local variable a counts them */
            n = lisp_values.count;
            if (n != 1) {
                if (g_sp + n + depth > g_stack + STACK_SLOTS) {
                    stack_is_full();
                    goto unwind;
                }
                g_sp--;
                memcpy(g_sp, lisp_values.value, n * sizeof(lisp));
                g_sp += n;
            }
            locals[a] += lisp_fixnum(n);
            break;
        case OP_VALUES_CALL: /* function, as many arguments as the local variable a counted -> its first value */
            n = small(locals[a]);
            args = g_sp - n;
            watched();
            value = lisp_apply(args[-1], n, args);
            g_sp = args - 1;
            if (g_unwind.to)
                goto unwind;
            *g_sp++ = value;
            break;
        case OP_VALUES_SPREAD: /* first value -> a values of the form: NIL for the ones it did not give */
            value = *--g_sp;
            n = lisp_values.count;
            settle(value);
            for (i = 0; i < a; i++)
                *g_sp++ = i < n ? lisp_values.value[i] : LISP_NIL;
            break;
        case OP_VALUES_SAVE: /* first value -> every value of the form, and how many they are */
            value = *--g_sp;
            n = lisp_values.count;
            settle(value);
            memcpy(g_sp, lisp_values.value, n * sizeof(lisp));
            g_sp += n;
            *g_sp++ = lisp_fixnum(n);
            break;
        case OP_VALUES_RESTORE: /* values, how many -> the first; lisp_values has them again */
            n = small(*--g_sp);
            g_sp -= n;
            lisp_values.count = n;
            memcpy(lisp_values.value, g_sp, n * sizeof(lisp));
            *g_sp++ = n ? lisp_values.value[0] : LISP_NIL;
            break;
        case OP_BLOCK: /* -> a record: a block that can be left from anywhere, with its tag in the local variable b */
        case OP_TAGBODY: /* the same for a tagbody */
            tag = lisp_cons(lisp_roots.t, LISP_NIL);
            locals[b] = tag;
            records = record(records, (word & 0xff) == OP_BLOCK ? R_BLOCK : R_TAGBODY, a, tag);
            records[4] = records[5] = 0;
            break;
        case OP_CATCH: { /* tag -> a record: a CATCH for it */
            struct catch *c;

            tag = *--g_sp;
            records = record(records, R_CATCH, a, tag);
            c = (struct catch *)&records[4];
            c->outer = g_catches;
            c->tag = &records[3];
            g_catches = c;
            break;
        }
        case OP_HANDLER: { /* -> a record: a HANDLER-CASE with the clauses b, each (type . which) */
            struct handler *h;

            for (lisp c = constants[b]; lisp_is_cons(c); c = lisp_as_cons(c)->cdr) {
                lisp type = lisp_is_cons(lisp_as_cons(c)->car) ? lisp_as_cons(lisp_as_cons(c)->car)->car : LISP_NIL;

                if (!lisp_is_symbol(type) || (type != lisp_roots.t && property(type, S.condition) == LISP_NIL)) {
                    lisp_fail("HANDLER-CASE has a clause for ~S, which is not the name of a type of condition", type);
                    goto unwind;
                }
            }
            records = record(records, R_HANDLER, a, constants[b]);
            h = (struct handler *)&records[4];
            h->outer = g_handlers;
            h->clauses = constants[b];
            g_handlers = h;
            break;
        }
        case OP_PROTECT: /* -> a record: an UNWIND-PROTECT whose cleanup begins at a */
            records = record(records, R_PROTECT, a, LISP_NIL);
            records[4] = records[5] = 0;
            break;
        case OP_UNLINK: /* the a innermost records are no longer in force; their words stay on the stack */
            while (a--)
                records = retire(records);
            break;
        case OP_RETURN_TO: /* tag, value -> ; control leaves for the block of that tag, whose name is the constant a */
            value = *--g_sp;
            tag = *--g_sp;
            if (lisp_as_cons(tag)->car == LISP_NIL) {
                control_error("RETURN-FROM ~S, a block that has been left already", constants[a]);
                goto unwind;
            }
            settle(value);
            g_unwind.to = tag;
            goto unwind;
        case OP_GO_TO: /* tag -> ; control leaves for the a-th tag of the tagbody of that tag; the constant b is its name */
            tag = *--g_sp; /* the function that is running holds it too, in a variable or in what it closes over */
            watched();
            if (!safe_point())
                goto unwind;
            if (lisp_as_cons(tag)->car == LISP_NIL) {
                control_error("GO to ~S, in a TAGBODY that has been left already", constants[b]);
                goto unwind;
            }
            g_unwind.to = tag;
            g_unwind.tag = lisp_fixnum(a);
            goto unwind;
        case OP_THROW: { /* tag, value -> ; control leaves for the CATCH of that tag */
            const struct catch *c = g_catches;

            value = *--g_sp;
            tag = *--g_sp;
            while (c && *c->tag != tag)
                c = c->outer;
            if (!c) {
                control_error("THROW to ~S, and no CATCH is waiting for it", tag);
                goto unwind;
            }
            settle(value);
            g_unwind.to = THROWING;
            g_unwind.tag = tag;
            goto unwind;
        }
        case OP_CLEANUP: /* the record of an UNWIND-PROTECT, first value of its form -> what cleanup() keeps */
            value = *--g_sp;
            settle(value);
            r = records;
            records = retire(r);
            g_sp = r;
            records = cleanup(records);
            break;
        case OP_CLEANUP_END: /* what cleanup() kept -> the first value of the form, or the exit goes on */
            r = records;
            records = retire(r);
            g_sp = r;
            exit.handler = (struct handler *)(uintptr_t)*--g_sp;
            exit.clause = *--g_sp;
            exit.tag = *--g_sp;
            exit.to = *--g_sp;
            n = small(*--g_sp);
            g_sp -= n;
            g_unwind = exit;
            lisp_values.count = n;
            memcpy(lisp_values.value, g_sp, n * sizeof(lisp));
            if (exit.to)
                goto unwind;
            *g_sp++ = n ? lisp_values.value[0] : LISP_NIL;
            break;
        case OP_DISPATCH: /* which -> ; on at that one of the a jumps that follow */
            n = small(*--g_sp);
            if (n >= a) {
                lisp_fail("compiled code was sent to the ~Ath of ~A places", lisp_fixnum(n), lisp_fixnum(a));
                goto unwind;
            }
            pc += n;
            break;
        case OP_FSET: /* function -> the symbol a, whose function it is from now on: DEFUN */
            symbol = constants[a];
            value = lisp_as_symbol(symbol)->function;
            if (value != LISP_UNBOUND && lisp_function_kind(value) == LISP_SPECIAL_OPERATOR) {
                lisp_fail("~S is a special operator, and stays one", symbol);
                goto unwind;
            }
            lisp_as_symbol(symbol)->function = g_sp[-1];
            g_sp[-1] = symbol;
            break;
        case OP_DEFMACRO: /* -> the name; the constant a is (name lambda-list form...), a macro for the evaluator */
            symbol = lisp_as_cons(constants[a])->car;
            value = lisp_as_symbol(symbol)->function;
            if (value != LISP_UNBOUND && lisp_function_kind(value) == LISP_SPECIAL_OPERATOR) {
                lisp_fail("~S is a special operator, and stays one", symbol);
                goto unwind;
            }
            lisp_as_symbol(symbol)->function = make_function(LISP_MACRO, symbol, lisp_as_cons(constants[a])->cdr, LISP_NIL);
            *g_sp++ = symbol;
            break;
        case OP_DEFVAR: /* -> T when the symbol a has no value yet; it is a special variable from here on */
            symbol = constants[a];
            if (constant(symbol)) {
                lisp_fail("~S cannot be made a variable", symbol);
                goto unwind;
            }
            lisp_symbol_flag(symbol, LISP_SPECIAL);
            *g_sp++ = lisp_as_symbol(symbol)->value == LISP_UNBOUND ? lisp_roots.t : LISP_NIL;
            break;
        case OP_DEFCONSTANT: /* value -> the symbol a, a constant with that value */
            symbol = constants[a];
            value = g_sp[-1];
            if (constant(symbol)) {
                if (lisp_as_symbol(symbol)->value != value) {
                    lisp_fail("~S is a constant already, and its value is ~S", symbol, lisp_as_symbol(symbol)->value);
                    goto unwind;
                }
            } else {
                lisp_as_symbol(symbol)->value = value;
                lisp_symbol_flag(symbol, LISP_SPECIAL | LISP_CONSTANT);
            }
            g_sp[-1] = symbol;
            break;
        case OP_FAIL: /* an error of the type a that says the constant b: a form that is not what it should be */
            lisp_fail_as(failures[a], NULL, 0, "~A", constants[b]);
            goto unwind;
        }
        continue;

    unwind:
        /* An exit is under way, and g_unwind says where to. It passes the records of this call, the
         * innermost first, until one takes it. */
        while (records) {
            unsigned kind, pad;

            r = records;
            kind = small(r[1]) & 0xff;
            pad = small(r[1]) >> 8;
            if (kind == R_TAGBODY && g_unwind.to == r[3]) {
                /* A GO to one of its tags: the tagbody is not left, and its record stays. */
                value = g_unwind.tag;
                g_unwind.to = 0;
                g_unwind.tag = LISP_NIL;
                unbind(small(r[2]));
                g_sp = r + RECORD;
                *g_sp++ = value; /* which tag, for DISPATCH */
                pc = pad;
                break;
            }
            records = retire(r);
            if (kind == R_CLEANING)
                continue; /* an exit out of a cleanup: the one that the cleanup interrupted is forgotten */
            if (kind == R_PROTECT) {
                unbind(small(r[2]));
                g_sp = r;
                records = cleanup(records);
                pc = pad;
                break;
            }
            if (kind == R_BLOCK && g_unwind.to == r[3]) {
                value = lisp_values.count ? lisp_values.value[0] : LISP_NIL;
                g_unwind.to = 0;
            } else if (kind == R_CATCH && g_unwind.to == THROWING && g_unwind.tag == r[3]) {
                g_unwind.to = 0;
                g_unwind.tag = LISP_NIL;
                value = lisp_values.count ? lisp_values.value[0] : LISP_NIL;
            } else if (kind == R_HANDLER && g_unwind.to == HANDLING && g_unwind.handler == (struct handler *)&r[4]) {
                g_unwind.to = 0;
                unbind(small(r[2]));
                g_sp = r;
                *g_sp++ = g_unwind.tag; /* the condition, and under DISPATCH's eyes which clause takes it */
                *g_sp++ = lisp_as_cons(g_unwind.clause)->cdr;
                pc = pad;
                break;
            } else
                continue;
            unbind(small(r[2]));
            g_sp = r;
            *g_sp++ = value;
            pc = pad;
            break;
        }
        if (!g_unwind.to)
            continue;
        value = LISP_NIL;
    leave:
        while (records)
            records = retire(records);
        unbind(bound);
        g_sp = base;
        return value;
    }
}

/* Code, looked at before it is made a function: whether the machine can run
 * it without reading or writing where it should not. Says NULL when it is
 * in order and otherwise what is wrong. What is looked at is where every
 * operand points; that the stack is used the way the instructions assume
 * is the compiler's word, which is why the function that makes a function
 * of code is in CLARA.UNSAFE. */
static const char *check(lisp code, unsigned nesting)
{
    const struct lisp_vector *v = lisp_as_vector(code), *instructions, *constants;
    uint64_t count, known, variables, closed, words[] = { LISP_CODE_REQUIRED, LISP_CODE_OPTIONAL, LISP_CODE_LOCALS,
                                                          LISP_CODE_DEPTH, LISP_CODE_CLOSED };
    uint64_t parameters;

    if (nesting == NESTED)
        return "its functions are nested too deep";
    if (!lisp_is(code, LISP_VECTOR) || lisp_length(v->header) != LISP_CODE_ITEMS)
        return "it is not a vector of the items that code has";
    if (!lisp_is(v->items[LISP_CODE_INSTRUCTIONS], LISP_VECTOR) || !lisp_is(v->items[LISP_CODE_CONSTANTS], LISP_VECTOR))
        return "its instructions or its constants are not a vector";
    if (!lisp_is_symbol(v->items[LISP_CODE_NAME]))
        return "its name is not a symbol";
    for (unsigned i = 0; i < sizeof words / sizeof words[0]; i++)
        if (!lisp_is_fixnum(v->items[words[i]]) || v->items[words[i]] > lisp_fixnum(SMALL))
            return "it has a count that is not a small number";
    instructions = lisp_as_vector(v->items[LISP_CODE_INSTRUCTIONS]);
    constants = lisp_as_vector(v->items[LISP_CODE_CONSTANTS]);
    count = lisp_length(instructions->header);
    known = lisp_length(constants->header);
    variables = small(v->items[LISP_CODE_LOCALS]);
    closed = small(v->items[LISP_CODE_CLOSED]);
    parameters = small(v->items[LISP_CODE_REQUIRED]) + small(v->items[LISP_CODE_OPTIONAL]) +
                 (v->items[LISP_CODE_REST] != LISP_NIL);
    if (v->items[LISP_CODE_KEYS] != LISP_NIL) {
        const struct lisp_vector *keys = lisp_as_vector(v->items[LISP_CODE_KEYS]);

        if (!lisp_is(v->items[LISP_CODE_KEYS], LISP_VECTOR))
            return "its keywords are not a vector";
        for (uint64_t i = 0; i < lisp_length(keys->header); i++)
            if (!lisp_is_symbol(keys->items[i]))
                return "one of its keywords is not a symbol";
        parameters += lisp_length(keys->header);
    }
    if (parameters > variables)
        return "it has more parameters than local variables";
    if (!count || count > 0xffffff || known > 0xffffff)
        return "it has no instructions, or too many of them or of constants";
    for (uint64_t pc = 0; pc < count; pc++) {
        uint64_t word = (uint64_t)lisp_fixnum_value(instructions->items[pc]), operand[2] = { word >> 8 & 0xffffff, word >> 32 };
        uint8_t kinds[2];

        if (!lisp_is_fixnum(instructions->items[pc]) || (int64_t)instructions->items[pc] < 0 || (word & 0xff) >= OPERATIONS)
            return "one of its instructions is none that the machine has";
        kinds[0] = operations[word & 0xff].a;
        kinds[1] = operations[word & 0xff].b;
        for (unsigned i = 0; i < 2; i++) {
            uint64_t x = operand[i];
            lisp c = x < known ? constants->items[x] : 0;

            switch (kinds[i]) {
            case CONSTANT:
            case SYMBOL:
            case CLAUSES:
            case CODE:
                if (x >= known)
                    return "an instruction names a constant that is not there";
                if (kinds[i] == SYMBOL && !lisp_is_symbol(c))
                    return "an instruction wants a symbol, and its constant is not one";
                if (kinds[i] == CODE) {
                    const char *wrong = check(c, nesting + 1);

                    if (wrong)
                        return wrong;
                    if (lisp_as_vector(c)->items[LISP_CODE_CLOSED] != lisp_fixnum((int64_t)operand[1]))
                        return "a function inside it is not given the values that it closes over";
                }
                for (; kinds[i] == CLAUSES && c != LISP_NIL; c = lisp_as_cons(c)->cdr)
                    if (!lisp_is_cons(c) || !lisp_is_cons(lisp_as_cons(c)->car) ||
                        !lisp_is_fixnum(lisp_as_cons(lisp_as_cons(c)->car)->cdr))
                        return "the clauses of a HANDLER-CASE are not a list of types with their places";
                break;
            case LOCAL:
                if (x >= variables)
                    return "an instruction names a local variable that is not there";
                break;
            case CLOSED:
                if (x >= closed)
                    return "an instruction names a closed-over value that is not there";
                break;
            case TARGET:
                if (x >= count)
                    return "an instruction jumps past the end";
                break;
            case KIND:
                if (x >= sizeof failures / sizeof failures[0])
                    return "an instruction fails in a way that there is no type for";
                break;
            }
        }
        if ((word & 0xff) == OP_DISPATCH && pc + operand[0] >= count)
            return "an instruction jumps past the end";
        if ((word & 0xff) == OP_DEFMACRO && !lisp_is_symbol(lisp_is_cons(constants->items[operand[0]])
                                                                  ? lisp_as_cons(constants->items[operand[0]])->car
                                                                  : 0))
            return "a macro has no symbol for a name";
        if (pc + 1 == count && (word & 0xff) != OP_RETURN && (word & 0xff) != OP_RETURN_ONE && (word & 0xff) != OP_JUMP &&
            (word & 0xff) != OP_FAIL && (word & 0xff) != OP_RETURN_TO && (word & 0xff) != OP_GO_TO && (word & 0xff) != OP_THROW)
            return "its last instruction lets the machine run on past the end";
    }
    return NULL;
}

/* (clara.unsafe:make-compiled-function code): a function of code that the
 * compiler made, which closes over nothing. */
LISP_PRIMITIVE(lisp_p_make_compiled_function)
{
    const char *wrong = check(argv[0], 0);

    (void)argc;
    if (!wrong && lisp_as_vector(argv[0])->items[LISP_CODE_CLOSED] != lisp_fixnum(0))
        wrong = "it closes over values, and here are none";
    if (wrong)
        return lisp_fail("the machine cannot run that code: ~Z", wrong);
    return make_function(LISP_COMPILED, lisp_as_vector(argv[0])->items[LISP_CODE_NAME], argv[0], LISP_NIL);
}

/* (clara.unsafe:compiled-function-code function): the code of a compiled
 * function, for whoever lists it, or NIL for a function of another kind. */
LISP_PRIMITIVE(lisp_p_compiled_function_code)
{
    (void)argc;
    if (!lisp_is(argv[0], LISP_FUNCTION))
        return lisp_wants("a function", argv[0]);
    return lisp_function_kind(argv[0]) == LISP_COMPILED ? lisp_as_function(argv[0])->code : LISP_NIL;
}

/* (compiled-function-p object): a function that the evaluator does not
 * walk the forms of, one in C or one that the compiler made. */
LISP_PRIMITIVE(lisp_p_compiled_function_p)
{
    (void)argc;
    return lisp_is(argv[0], LISP_FUNCTION) &&
                   (lisp_function_kind(argv[0]) == LISP_COMPILED || lisp_function_kind(argv[0]) == LISP_PRIMITIVE)
               ? lisp_roots.t
               : LISP_NIL;
}

/* (function-lambda-expression function): the LAMBDA form that a function
 * of the evaluator's was made of, or NIL for any other; whether it was
 * made where variables or local functions were in sight, which it holds on
 * to; and its name. The form is the function's own, not a copy. */
LISP_PRIMITIVE(lisp_p_function_lambda_expression)
{
    const struct lisp_function *f = lisp_as_function(argv[0]);
    int walked;

    (void)argc;
    if (!lisp_is(argv[0], LISP_FUNCTION) || lisp_function_kind(argv[0]) == LISP_SPECIAL_OPERATOR)
        return lisp_wants("a function", argv[0]);
    walked = lisp_function_kind(argv[0]) == LISP_CLOSURE;
    lisp_values.count = 3;
    lisp_values.value[0] = walked ? lisp_cons(S.lambda, f->code) : LISP_NIL;
    lisp_values.value[1] = walked ? (f->env != LISP_NIL ? lisp_roots.t : LISP_NIL)
                                  : lisp_function_kind(argv[0]) == LISP_COMPILED && f->env != LISP_NIL ? lisp_roots.t
                                                                                                       : LISP_NIL;
    lisp_values.value[2] = f->name;
    return lisp_values.value[0];
}

/* (clara:variable-kind symbol): :CONSTANT for a symbol whose value cannot
 * be changed, :SPECIAL for one that DEFVAR and its kin have made a special
 * variable, and NIL for any other, which is what a compiler has to know of
 * a name before it binds it. */
LISP_PRIMITIVE(lisp_p_variable_kind)
{
    (void)argc;
    if (!lisp_is_symbol(argv[0]))
        return lisp_wants("a symbol", argv[0]);
    if (constant(argv[0]))
        return lisp_symbol_in(lisp_roots.keyword, "CONSTANT", 1);
    return special(argv[0]) ? lisp_symbol_in(lisp_roots.keyword, "SPECIAL", 1) : LISP_NIL;
}
