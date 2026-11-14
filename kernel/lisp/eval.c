/* The evaluator: a form and an environment in, values out.
 *
 * It is an interpreter that walks the forms as the reader made them. A
 * symbol is a variable, a list is a call, a macro call or one of the
 * special forms in the table below, and anything else is its own value.
 *
 * An environment is a chain of frames, each a vector in the heap: the
 * frame outside it, what kind it is, then its contents. A frame of
 * variables or of local functions holds names and values in pairs; a BLOCK
 * and a TAGBODY each have one, which is what RETURN-FROM and GO look for.
 * A closure keeps the chain it was made in. A special variable is never in
 * a frame: its value is in the symbol, binding it puts the old value on a
 * stack of bindings, and whatever bound it puts the old value back.
 *
 * A non-local exit is not a jump. RETURN-FROM, GO, THROW and an error set
 * g_unwind and return, and every piece of C on the way out sees that it is
 * set, undoes what it did, and returns in turn, until the BLOCK, the
 * TAGBODY or the CATCH that it is meant for clears it. An error goes all
 * the way to the top level, which prints it: there are no conditions yet
 * (M6c). So there is no setjmp here, nothing to keep in step with the
 * exception entry of two architectures, and UNWIND-PROTECT will be a few
 * lines.
 *
 * The collector (M6c) will run at safe points only, and the evaluator
 * comes to one at every call and every GO. Whatever it holds then has to
 * be findable, so it keeps its objects on a stack of its own, the value
 * stack, not in C variables: the arguments of a call while they are
 * evaluated, every frame it makes, for as long as it evaluates in it, and
 * the values that wait for a body to finish. A C variable may hold an
 * object only from one call of the evaluator to the next. Forms are not
 * pushed: a form is part of the body of a function that is being called,
 * which is on the stack, or of the cell that lisp_eval pushes.
 *
 * A macro call is expanded once: the expansion takes the call's place in
 * the list that holds it, so the next time round the evaluator finds the
 * expansion there. The call itself is left as it was, for whoever else
 * holds it, a quoted copy in an error message for one. */
#include "lisp.h"

enum {
    STACK_SLOTS = 65536, /* of the value stack */
    STACK_SPARE = 64,    /* past its end, for the pushes that are not checked: a few between two checks */
    BINDINGS = 8192,     /* special variables bound at one time */
    MARGIN = 48 * 1024,  /* of the thread's stack that the evaluator leaves alone: the reader, the printer and an
                            interrupt on x86_64 run on what is left */
};

/* What a frame of an environment holds: its second item. */
enum { VARIABLES, FUNCTIONS, BLOCK, TAGS };

/* What g_unwind.to is when it is not a frame: immediates, like LISP_UNBOUND. */
#define THROWING 0x17ULL
#define FAILING  0x1fULL

struct lisp_values lisp_values;

static lisp g_stack[STACK_SLOTS + STACK_SPARE];
static lisp *g_sp = g_stack;
static struct {
    lisp symbol, value; /* a special variable, and the value it had before it was bound */
} g_bindings[BINDINGS];
static unsigned g_bound;
static struct {
    lisp to;  /* 0, or where control is on its way to: a BLOCK or TAGS frame, THROWING, FAILING */
    lisp tag; /* GO: the place in the body. THROW: the tag. An error: what went wrong, a string */
} g_unwind;
struct catch {
    struct catch *outer;
    lisp *tag; /* on the value stack */
};
static struct catch *g_catches;
static uintptr_t g_c_limit; /* the lowest address the thread's own stack may reach while it evaluates */
static const struct lisp_primitive *g_primitive; /* the one that was called last */
static const struct boot_file *g_files;
static struct {
    lisp lambda, declare, special, optional, rest, body, key, allow_other_keys, aux, whole, environment;
    lisp execute, eval, allow;
} S; /* symbols the evaluator knows by sight: all in COMMON-LISP or KEYWORD, so the packages hold them */

static const char stack_full[] =
    "the stack is full: the forms are nested too deep, or a function calls itself without end";

static lisp eval_car(lisp cell, lisp env);
static lisp progn(lisp body, lisp env);

/* A form that is not what it should be must not take the kernel down, so
 * the evaluator never follows a pointer it has not looked at: the CAR and
 * the CDR of anything but a cons are NIL here. */
static inline lisp car(lisp x)
{
    return lisp_is_cons(x) ? lisp_as_cons(x)->car : LISP_NIL;
}

static inline lisp cdr(lisp x)
{
    return lisp_is_cons(x) ? lisp_as_cons(x)->cdr : LISP_NIL;
}

static inline int special(lisp symbol)
{
    return lisp_symbol_flags(symbol) & LISP_SPECIAL;
}

static inline int constant(lisp symbol)
{
    return lisp_symbol_flags(symbol) & LISP_CONSTANT;
}

int lisp_unwinding(void)
{
    return g_unwind.to != 0;
}

/* Errors. What went wrong is a string, made the way FORMAT would: ~S
 * prints a Lisp object, ~A prints one for a person, ~Z is a C string. It
 * is at most 255 bytes long. */
struct buffer {
    char text[256];
    size_t length;
};

static void buffer_put(void *to, char c)
{
    struct buffer *b = to;

    if (b->length < sizeof b->text - 1)
        b->text[b->length++] = c;
}

static lisp message(const char *control, va_list ap)
{
    struct buffer b;

    b.length = 0;
    for (; *control; control++) {
        if (*control != '~') {
            buffer_put(&b, *control);
            continue;
        }
        switch (*++control) {
        case 'S':
            lisp_print(va_arg(ap, lisp), buffer_put, &b);
            break;
        case 'A':
            lisp_princ(va_arg(ap, lisp), buffer_put, &b);
            break;
        case 'Z':
            for (const char *s = va_arg(ap, const char *); *s; s++)
                buffer_put(&b, *s);
            break;
        }
    }
    return lisp_string_from_utf8(b.text, b.length);
}

static lisp text(const char *control, ...)
{
    va_list ap;
    lisp string;

    va_start(ap, control);
    string = message(control, ap);
    va_end(ap);
    return string;
}

/* An error: from here every caller returns, up to the top level. What is
 * returned is NIL, so that a function can say return lisp_fail(...). */
lisp lisp_fail(const char *control, ...)
{
    va_list ap;

    if (g_unwind.to)
        return LISP_NIL; /* the first thing to go wrong is the one that is reported */
    va_start(ap, control);
    g_unwind.tag = message(control, ap);
    va_end(ap);
    g_unwind.to = FAILING;
    return LISP_NIL;
}

lisp lisp_wants(const char *what, lisp x)
{
    return lisp_fail("~Z wants ~Z, and ~S is not one", g_primitive->name, what, x);
}

/* The value stack. lisp_push looks whether there is room; the evaluator's
 * own few pushes between two checks do not, and STACK_SPARE is for them. */
lisp *lisp_stack(void)
{
    return g_sp;
}

void lisp_stack_drop(lisp *to)
{
    g_sp = to;
}

int lisp_push(lisp x)
{
    if (g_sp >= g_stack + STACK_SLOTS) {
        lisp_fail(stack_full);
        return 0;
    }
    *g_sp++ = x;
    return 1;
}

/* The evaluator calls itself in C for every form inside a form, and so do
 * a few of the functions in C, on a stack that ends at a guard page. The
 * address of a local variable says how far down it has come. */
int lisp_out_of_stack(void)
{
    char here;

    if ((uintptr_t)&here >= g_c_limit && g_sp < g_stack + STACK_SLOTS)
        return 0;
    lisp_fail(stack_full);
    return 1;
}

/* Special variables. */
static void bind_special(lisp symbol, lisp value)
{
    if (g_bound == BINDINGS) {
        lisp_fail("too many special variables are bound at once: more than ~A", lisp_fixnum(BINDINGS));
        return;
    }
    g_bindings[g_bound].symbol = symbol;
    g_bindings[g_bound++].value = lisp_as_symbol(symbol)->value;
    lisp_as_symbol(symbol)->value = value;
}

static void unbind(unsigned to)
{
    while (g_bound > to) {
        g_bound--;
        lisp_as_symbol(g_bindings[g_bound].symbol)->value = g_bindings[g_bound].value;
    }
}

/* Environments. */
static lisp make_frame(lisp parent, int kind, uint64_t pairs)
{
    lisp frame = lisp_make_vector(2 + 2 * pairs);

    lisp_as_vector(frame)->items[0] = parent;
    lisp_as_vector(frame)->items[1] = lisp_fixnum(kind);
    return frame;
}

/* Where the nearest frame of that kind keeps what the name stands for, or
 * NULL when no frame has the name. */
static lisp *lookup(lisp env, int kind, lisp name)
{
    for (; env != LISP_NIL; env = lisp_as_vector(env)->items[0]) {
        struct lisp_vector *frame = lisp_as_vector(env);

        if (frame->items[1] != lisp_fixnum(kind))
            continue;
        for (uint64_t i = 2; i < lisp_length(frame->header); i += 2)
            if (frame->items[i] == name)
                return &frame->items[i + 1];
    }
    return NULL;
}

/* A variable gets its value. A special one is bound there and then. Any
 * other waits on the value stack, name and value, for flush to put it in
 * a frame with the ones around it. */
static void bind_variable(lisp symbol, lisp value)
{
    if (!lisp_is_symbol(symbol) || constant(symbol))
        lisp_fail("~S cannot be the name of a variable", symbol);
    else if (special(symbol))
        bind_special(symbol, value);
    else if (lisp_push(symbol))
        lisp_push(value);
}

/* The variables that wait on the stack from pairs up become a frame on
 * top of the environment in *e, which is a slot of the stack too. */
static void flush(lisp *e, lisp *pairs)
{
    uint64_t n = (uint64_t)(g_sp - pairs) / 2;

    if (n && !g_unwind.to) {
        lisp frame = make_frame(*e, VARIABLES, n);

        memcpy(lisp_as_vector(frame)->items + 2, pairs, 2 * n * sizeof(lisp));
        *e = frame;
    }
    g_sp = pairs;
}

static lisp make_function(enum lisp_function_kind kind, lisp name, lisp code, lisp env)
{
    struct lisp_function *f = lisp_alloc(LISP_FUNCTION, kind);

    f->name = name;
    f->code = code;
    f->env = env;
    return (lisp)(uintptr_t)f | LISP_TAG_OBJECT;
}

/* Lambda lists: parameters to arguments.
 *
 *   required parameters
 *   &optional name, (name default), (name default supplied-p)
 *   &rest name, and &body, which is the same
 *   &key name, (name default supplied-p), ((keyword name) default supplied-p), &allow-other-keys
 *   &aux name, (name value)
 *
 * and in a macro's lambda list also &whole name, a list in the place of a
 * name, for an argument that is a list and is taken apart in the same
 * way, and a dot before the last name instead of &rest.
 *
 * The arguments are argc words at argv, on the value stack; source is the
 * list they were spread from, for a macro, or 0. A default is evaluated
 * where the parameters before it can be seen: the ones that wait become a
 * frame first. So do they when a list is taken apart, which uses the top
 * of the stack for its own arguments. */
static void bind(lisp f, lisp list, unsigned argc, lisp *argv, lisp source, lisp *e, int macro, lisp whole);

static lisp nthcdr(lisp list, unsigned n)
{
    while (n--)
        list = cdr(list);
    return list;
}

static void bind_parameter(lisp f, lisp parameter, lisp value, lisp *e, lisp *pairs, int macro)
{
    lisp *argv;
    unsigned argc = 0;

    if (!macro || lisp_is_symbol(parameter)) {
        bind_variable(parameter, value);
        return;
    }
    flush(e, pairs);
    argv = g_sp;
    for (lisp v = value; lisp_is_cons(v); v = lisp_as_cons(v)->cdr, argc++)
        if (!lisp_push(lisp_as_cons(v)->car))
            return;
    bind(f, parameter, argc, argv, value, e, 1, LISP_NIL);
    g_sp = pairs;
}

static void bind(lisp f, lisp list, unsigned argc, lisp *argv, lisp source, lisp *e, int macro, lisp whole)
{
    enum { REQUIRED, OPTIONAL, REST, KEY, AUX } mode = REQUIRED;
    lisp *pairs = g_sp, parameter, variable, value, supplied, keyword;
    unsigned i = 0, first = 0, k;
    uint64_t known = 0; /* the keyword arguments that some parameter asked for: a bit for each */
    int rest = 0, keys = 0, allow = 0;

    for (; lisp_is_cons(list) && !g_unwind.to; list = lisp_as_cons(list)->cdr) {
        parameter = lisp_as_cons(list)->car;
        if (parameter == S.optional)
            mode = OPTIONAL;
        else if (parameter == S.rest || parameter == S.body)
            mode = REST;
        else if (parameter == S.key) {
            mode = KEY;
            keys = 1;
            first = i;
            if ((argc - i) & 1)
                lisp_fail("~S got an odd number of keyword arguments", f);
            else if (argc - i > 128)
                lisp_fail("~S got more than 64 keyword arguments", f);
            for (k = i; k + 1 < argc; k += 2)
                if (argv[k] == S.allow && argv[k + 1] != LISP_NIL)
                    allow = 1;
        } else if (parameter == S.allow_other_keys)
            allow = 1;
        else if (parameter == S.aux)
            mode = AUX;
        else if (parameter == S.whole && macro) {
            list = lisp_as_cons(list)->cdr;
            bind_variable(car(list), whole);
        } else if (parameter == S.environment)
            lisp_fail("&ENVIRONMENT in a lambda list, which the evaluator does not know yet");
        else {
            variable = mode != REQUIRED && mode != REST && lisp_is_cons(parameter) ? lisp_as_cons(parameter)->car
                                                                                    : parameter;
            supplied = lisp_roots.t;
            switch (mode) {
            case REQUIRED:
                if (i == argc) {
                    lisp_fail("~S got too few arguments", f);
                    return;
                }
                value = argv[i++];
                break;
            case REST:
                value = LISP_NIL;
                if (source)
                    value = nthcdr(source, i);
                else
                    for (k = argc; k > i; k--)
                        value = lisp_cons(argv[k - 1], value);
                rest = 1;
                break;
            case OPTIONAL:
                if (i < argc) {
                    value = argv[i++];
                    break;
                }
                goto missing;
            case KEY:
                if (lisp_is_cons(variable)) {
                    keyword = lisp_as_cons(variable)->car;
                    variable = car(lisp_as_cons(variable)->cdr);
                } else if (lisp_is_symbol(variable)) {
                    const struct lisp_string *name = lisp_as_string(lisp_as_symbol(variable)->name);

                    keyword = lisp_intern(lisp_roots.keyword, name->chars, lisp_length(name->header));
                } else {
                    lisp_fail("~S cannot be the name of a variable", variable);
                    return;
                }
                value = LISP_UNBOUND;
                for (k = first; k + 1 < argc; k += 2)
                    if (argv[k] == keyword) {
                        known |= 1ULL << ((k - first) / 2);
                        if (value == LISP_UNBOUND)
                            value = argv[k + 1];
                    }
                if (value != LISP_UNBOUND)
                    break;
                goto missing;
            default:
            missing:
                supplied = LISP_NIL;
                value = LISP_NIL;
                if (lisp_is_cons(parameter) && lisp_is_cons(lisp_as_cons(parameter)->cdr)) {
                    flush(e, pairs);
                    value = eval_car(lisp_as_cons(parameter)->cdr, *e);
                    if (g_unwind.to)
                        return;
                }
            }
            bind_parameter(f, variable, value, e, pairs, macro);
            if ((mode == OPTIONAL || mode == KEY) && car(cdr(cdr(parameter))) != LISP_NIL)
                bind_variable(car(cdr(cdr(parameter))), supplied);
        }
    }
    if (g_unwind.to)
        return;
    if (list != LISP_NIL) {
        if (!macro || !lisp_is_symbol(list)) {
            lisp_fail("the lambda list of ~S ends in ~S", f, list);
            return;
        }
        bind_variable(list, nthcdr(source, i));
        rest = 1;
    }
    if (!rest && !keys && i < argc)
        lisp_fail("~S got too many arguments", f);
    if (keys && !allow)
        for (k = first; k + 1 < argc; k += 2)
            if (!(known >> ((k - first) / 2) & 1) && argv[k] != S.allow) {
                lisp_fail("~S does not take the keyword argument ~S", f, argv[k]);
                break;
            }
    flush(e, pairs);
}

/* What a body begins with and is not a form: declarations, which are
 * looked at and passed over, and a string before them or before the rest
 * of the body, which is documentation. One declaration changes what the
 * forms mean, SPECIAL, and it is refused until it is done properly. */
static lisp declarations(lisp body)
{
    for (;; body = lisp_as_cons(body)->cdr) {
        lisp form = car(body);

        if (lisp_is(form, LISP_STRING) && lisp_is_cons(cdr(body)))
            continue;
        if (car(form) != S.declare || !lisp_is_cons(form))
            return body;
        for (lisp d = cdr(form); lisp_is_cons(d); d = lisp_as_cons(d)->cdr)
            if (car(lisp_as_cons(d)->car) == S.special) {
                lisp_fail("(DECLARE (SPECIAL ...)), which the evaluator does not know yet: DEFVAR makes a variable special");
                return LISP_NIL;
            }
    }
}

/* The forms of a body with a name that RETURN-FROM can leave them by. */
static lisp block(lisp name, lisp body, lisp env)
{
    lisp frame = make_frame(env, BLOCK, 1), value;
    struct lisp_vector *v = lisp_as_vector(frame);

    v->items[2] = name;
    v->items[3] = lisp_roots.t; /* until it has been left */
    *g_sp++ = frame;
    value = progn(body, frame);
    v->items[3] = LISP_NIL;
    if (g_unwind.to == frame) {
        g_unwind.to = 0;
        value = lisp_values.count ? lisp_values.value[0] : LISP_NIL;
    }
    g_sp--;
    return value;
}

/* A function written in Lisp, or a macro's, called. The parameters go into
 * a frame on top of the environment the function was made in, and a
 * function with a name has a block of that name around its body. */
static lisp apply_closure(lisp f, unsigned argc, lisp *argv, lisp whole)
{
    const struct lisp_function *fn = lisp_as_function(f);
    lisp *base = g_sp, value = LISP_NIL, body;
    unsigned bound = g_bound;

    *g_sp++ = fn->env;
    bind(f, car(fn->code), argc, argv, whole == LISP_NIL ? 0 : cdr(whole), base,
         lisp_function_kind(f) == LISP_MACRO, whole);
    if (!g_unwind.to) {
        body = declarations(cdr(fn->code));
        if (!g_unwind.to)
            value = fn->name == LISP_NIL ? progn(body, *base) : block(fn->name, body, *base);
    }
    unbind(bound);
    g_sp = base;
    return value;
}

/* What a macro makes of a form: its function, called with the subforms of
 * the form as they stand. */
static lisp expand(lisp macro, lisp form)
{
    lisp *base = g_sp, value = LISP_NIL;
    unsigned argc = 0;

    *g_sp++ = macro;
    for (lisp a = cdr(form); lisp_is_cons(a); a = lisp_as_cons(a)->cdr, argc++)
        if (!lisp_push(lisp_as_cons(a)->car))
            goto out;
    value = apply_closure(macro, argc, base + 1, form);
out:
    g_sp = base;
    return value;
}

/* MACROEXPAND-1, for macros that DEFMACRO made: a form is looked at
 * outside every MACROLET, there being no environment to pass. */
lisp lisp_macroexpand_1(lisp form, int *expanded)
{
    lisp f;

    *expanded = 0;
    if (!lisp_is_symbol(car(form)) || !lisp_is_cons(form))
        return form;
    f = lisp_as_symbol(car(form))->function;
    if (!lisp_is(f, LISP_FUNCTION) || lisp_function_kind(f) != LISP_MACRO)
        return form;
    *expanded = 1;
    return expand(f, form);
}

/* The forms of a body, one after the other: the values of the last. */
static lisp progn(lisp body, lisp env)
{
    lisp value = LISP_NIL;

    lisp_values.count = 1;
    for (; lisp_is_cons(body); body = lisp_as_cons(body)->cdr) {
        value = eval_car(body, env);
        if (g_unwind.to)
            return LISP_NIL;
    }
    return value;
}

/* The values of the form that was evaluated last, all in lisp_values. */
static void settle(lisp value)
{
    if (lisp_values.count == 1)
        lisp_values.value[0] = value;
}

/* The special forms. Each gets the form without its operator, and the
 * environment; eval_car has counted the subforms. */
static lisp sf_quote(lisp args, lisp env)
{
    (void)env;
    return car(args);
}

static lisp sf_function(lisp args, lisp env)
{
    lisp name = car(args), *local, f;

    if (car(name) == S.lambda && lisp_is_cons(name))
        return make_function(LISP_CLOSURE, LISP_NIL, cdr(name), env);
    if (!lisp_is_symbol(name))
        return lisp_fail("~S is not the name of a function", name);
    local = lookup(env, FUNCTIONS, name);
    f = local ? *local : lisp_as_symbol(name)->function;
    if (f == LISP_UNBOUND)
        return lisp_fail("the function ~S is not defined", name);
    if (lisp_function_kind(f) == LISP_SPECIAL_OPERATOR || lisp_function_kind(f) == LISP_MACRO)
        return lisp_fail("~S is a macro or a special operator, not a function", name);
    return f;
}

static lisp sf_lambda(lisp args, lisp env)
{
    return make_function(LISP_CLOSURE, LISP_NIL, args, env);
}

static lisp sf_if(lisp args, lisp env)
{
    lisp test = eval_car(args, env);

    if (g_unwind.to)
        return LISP_NIL;
    args = cdr(args);
    if (test == LISP_NIL)
        args = cdr(args);
    if (!lisp_is_cons(args)) {
        lisp_values.count = 1;
        return LISP_NIL;
    }
    return eval_car(args, env);
}

/* LET and LET*. In LET the values are all computed before any variable is
 * bound; in LET* each variable is there for the value of the next, in a
 * frame of its own. */
static lisp let(lisp args, lisp env, int in_turn)
{
    lisp *base = g_sp, value = LISP_NIL, body;
    unsigned bound = g_bound;

    *g_sp++ = env;
    for (lisp b = car(args); lisp_is_cons(b); b = lisp_as_cons(b)->cdr) {
        lisp binding = lisp_as_cons(b)->car, variable = lisp_is_cons(binding) ? lisp_as_cons(binding)->car : binding;

        if (!lisp_is_symbol(variable) || constant(variable)) {
            lisp_fail("~S cannot be the name of a variable", variable);
            goto out;
        }
        value = lisp_is_cons(cdr(binding)) ? eval_car(lisp_as_cons(binding)->cdr, *base) : LISP_NIL;
        if (g_unwind.to)
            goto out;
        if (in_turn) {
            bind_variable(variable, value);
            flush(base, base + 1);
        } else if (!lisp_push(variable) || !lisp_push(value))
            goto out;
    }
    if (!in_turn) {
        /* Now the special ones are bound, and leave their places in the frame empty. */
        for (lisp *p = base + 1; p < g_sp; p += 2)
            if (special(p[0])) {
                bind_special(p[0], p[1]);
                p[0] = p[1] = 0;
            }
        flush(base, base + 1);
    }
    body = declarations(cdr(args));
    if (!g_unwind.to)
        value = progn(body, *base);
out:
    unbind(bound);
    g_sp = base;
    return value;
}

static lisp sf_let(lisp args, lisp env)
{
    return let(args, env, 0);
}

static lisp sf_let_star(lisp args, lisp env)
{
    return let(args, env, 1);
}

static lisp sf_setq(lisp args, lisp env)
{
    lisp value = LISP_NIL;

    for (; lisp_is_cons(args); args = cdr(lisp_as_cons(args)->cdr)) {
        lisp symbol = lisp_as_cons(args)->car, *local;

        if (!lisp_is_cons(lisp_as_cons(args)->cdr))
            return lisp_fail("SETQ has no value for ~S", symbol);
        if (!lisp_is_symbol(symbol) || constant(symbol))
            return lisp_fail("~S cannot be set: it is not a variable", symbol);
        value = eval_car(lisp_as_cons(args)->cdr, env);
        if (g_unwind.to)
            return LISP_NIL;
        local = special(symbol) ? NULL : lookup(env, VARIABLES, symbol);
        if (local)
            *local = value;
        else
            lisp_as_symbol(symbol)->value = value;
    }
    return value;
}

static lisp sf_block(lisp args, lisp env)
{
    if (!lisp_is_symbol(car(args)))
        return lisp_fail("~S cannot be the name of a block", car(args));
    return block(car(args), cdr(args), env);
}

static lisp sf_return_from(lisp args, lisp env)
{
    lisp name = car(args), frame = env, value = LISP_NIL;

    for (; frame != LISP_NIL; frame = lisp_as_vector(frame)->items[0])
        if (lisp_as_vector(frame)->items[1] == lisp_fixnum(BLOCK) && lisp_as_vector(frame)->items[2] == name)
            break;
    if (frame == LISP_NIL)
        return lisp_fail("RETURN-FROM ~S, and no block of that name is in sight", name);
    lisp_values.count = 1;
    if (lisp_is_cons(cdr(args)))
        value = eval_car(cdr(args), env);
    if (g_unwind.to)
        return LISP_NIL;
    if (lisp_as_vector(frame)->items[3] == LISP_NIL)
        return lisp_fail("RETURN-FROM ~S, a block that has been left already", name);
    settle(value);
    g_unwind.to = frame;
    return LISP_NIL;
}

/* A body in which a symbol or an integer is a tag, a place to GO to, and
 * everything else is a form. */
static lisp sf_tagbody(lisp args, lisp env)
{
    lisp frame = make_frame(env, TAGS, 1);
    struct lisp_vector *v = lisp_as_vector(frame);

    v->items[2] = args;
    v->items[3] = lisp_roots.t;
    *g_sp++ = frame;
    for (lisp at = args; lisp_is_cons(at); at = lisp_as_cons(at)->cdr) {
        if (!lisp_is_cons(lisp_as_cons(at)->car))
            continue;
        eval_car(at, frame);
        if (g_unwind.to == frame) {
            /* A GO to one of these tags: on from there. */
            at = g_unwind.tag;
            g_unwind.to = 0;
        } else if (g_unwind.to)
            break;
    }
    v->items[3] = LISP_NIL;
    g_sp--;
    return LISP_NIL;
}

static lisp sf_go(lisp args, lisp env)
{
    lisp tag = car(args);

    thread_safe_point();
    for (; env != LISP_NIL; env = lisp_as_vector(env)->items[0]) {
        const struct lisp_vector *v = lisp_as_vector(env);

        if (v->items[1] != lisp_fixnum(TAGS))
            continue;
        for (lisp at = v->items[2]; lisp_is_cons(at); at = lisp_as_cons(at)->cdr)
            if (lisp_as_cons(at)->car == tag && !lisp_is_cons(tag)) {
                if (v->items[3] == LISP_NIL)
                    return lisp_fail("GO to ~S, in a TAGBODY that has been left already", tag);
                g_unwind.to = env;
                g_unwind.tag = at;
                return LISP_NIL;
            }
    }
    return lisp_fail("GO to ~S, and no TAGBODY in sight has that tag", tag);
}

static lisp sf_catch(lisp args, lisp env)
{
    struct catch here = { g_catches, g_sp };
    lisp value = eval_car(args, env);

    if (g_unwind.to)
        return LISP_NIL;
    *g_sp++ = value;
    g_catches = &here;
    value = progn(cdr(args), env);
    g_catches = here.outer;
    if (g_unwind.to == THROWING && g_unwind.tag == *here.tag) {
        g_unwind.to = 0;
        g_unwind.tag = LISP_NIL;
        value = lisp_values.count ? lisp_values.value[0] : LISP_NIL;
    }
    g_sp--;
    return value;
}

static lisp sf_throw(lisp args, lisp env)
{
    lisp tag = eval_car(args, env), value;
    const struct catch *c = g_catches;

    if (g_unwind.to)
        return LISP_NIL;
    *g_sp++ = tag;
    value = eval_car(cdr(args), env);
    g_sp--;
    if (g_unwind.to)
        return LISP_NIL;
    while (c && *c->tag != tag)
        c = c->outer;
    if (!c)
        return lisp_fail("THROW to ~S, and no CATCH is waiting for it", tag);
    settle(value);
    g_unwind.to = THROWING;
    g_unwind.tag = tag;
    return LISP_NIL;
}

/* FLET, LABELS and MACROLET: a frame of functions. Those of LABELS are
 * made inside the frame, and can call one another. */
static lisp local_functions(lisp args, lisp env, enum lisp_function_kind kind, int inside)
{
    lisp frame, value = LISP_NIL, body;
    uint64_t n = 0, i = 2;

    for (lisp d = car(args); lisp_is_cons(d); d = lisp_as_cons(d)->cdr)
        n++;
    frame = make_frame(env, FUNCTIONS, n);
    *g_sp++ = frame;
    for (lisp d = car(args); lisp_is_cons(d); d = lisp_as_cons(d)->cdr, i += 2) {
        lisp definition = lisp_as_cons(d)->car, name = car(definition);

        if (!lisp_is_symbol(name) || name == LISP_NIL) {
            lisp_fail("~S cannot be the name of a function", name);
            goto out;
        }
        lisp_as_vector(frame)->items[i] = name;
        lisp_as_vector(frame)->items[i + 1] = make_function(kind, name, cdr(definition), inside ? frame : env);
    }
    body = declarations(cdr(args));
    if (!g_unwind.to)
        value = progn(body, frame);
out:
    g_sp--;
    return value;
}

static lisp sf_flet(lisp args, lisp env)
{
    return local_functions(args, env, LISP_CLOSURE, 0);
}

static lisp sf_labels(lisp args, lisp env)
{
    return local_functions(args, env, LISP_CLOSURE, 1);
}

static lisp sf_macrolet(lisp args, lisp env)
{
    return local_functions(args, env, LISP_MACRO, 0);
}

/* (multiple-value-call function form...): the function gets every value
 * of every form. */
static lisp sf_multiple_value_call(lisp args, lisp env)
{
    lisp *base = g_sp, value = eval_car(args, env);

    if (g_unwind.to)
        return LISP_NIL;
    *g_sp++ = value;
    for (args = cdr(args); lisp_is_cons(args); args = lisp_as_cons(args)->cdr) {
        value = eval_car(args, env);
        if (g_unwind.to)
            goto out;
        settle(value);
        for (unsigned i = 0, n = lisp_values.count; i < n; i++)
            if (!lisp_push(lisp_values.value[i]))
                goto out;
    }
    value = lisp_apply(*base, (unsigned)(g_sp - base - 1), base + 1);
out:
    g_sp = base;
    return value;
}

/* The values of the first form, kept while the others are evaluated. */
static lisp sf_multiple_value_prog1(lisp args, lisp env)
{
    lisp *base = g_sp, value = eval_car(args, env);
    unsigned n = lisp_values.count;

    if (g_unwind.to)
        return LISP_NIL;
    settle(value);
    memcpy(base, lisp_values.value, n * sizeof(lisp));
    g_sp += n;
    progn(cdr(args), env);
    if (!g_unwind.to) {
        lisp_values.count = n;
        memcpy(lisp_values.value, base, n * sizeof(lisp));
        value = n ? base[0] : LISP_NIL;
    }
    g_sp = base;
    return value;
}

/* (multiple-value-bind (variable...) form body...) */
static lisp sf_multiple_value_bind(lisp args, lisp env)
{
    lisp *base = g_sp, value, body;
    unsigned bound = g_bound, i = 0;

    *g_sp++ = env;
    value = eval_car(cdr(args), env);
    if (g_unwind.to)
        goto out;
    settle(value);
    for (lisp v = car(args); lisp_is_cons(v) && !g_unwind.to; v = lisp_as_cons(v)->cdr, i++)
        bind_variable(lisp_as_cons(v)->car, i < lisp_values.count ? lisp_values.value[i] : LISP_NIL);
    flush(base, base + 1);
    body = declarations(cdr(cdr(args)));
    if (!g_unwind.to)
        value = progn(body, *base);
out:
    unbind(bound);
    g_sp = base;
    return value;
}

/* There is no compiler, so the one time that counts is :EXECUTE, or EVAL
 * as it was once called. */
static lisp sf_eval_when(lisp args, lisp env)
{
    for (lisp when = car(args); lisp_is_cons(when); when = lisp_as_cons(when)->cdr)
        if (lisp_as_cons(when)->car == S.execute || lisp_as_cons(when)->car == S.eval)
            return progn(cdr(args), env);
    lisp_values.count = 1;
    return LISP_NIL;
}

static lisp sf_locally(lisp args, lisp env)
{
    lisp body = declarations(args);

    return g_unwind.to ? LISP_NIL : progn(body, env);
}

static lisp sf_the(lisp args, lisp env)
{
    return eval_car(cdr(args), env);
}

static lisp sf_declare(lisp args, lisp env)
{
    (void)args;
    (void)env;
    return lisp_fail("a DECLARE where a form has to be: it belongs at the start of a body");
}

static lisp define(lisp args, lisp env, enum lisp_function_kind kind)
{
    lisp name = car(args), old;

    if (!lisp_is_symbol(name) || name == LISP_NIL)
        return lisp_fail("~S cannot be the name of a function", name);
    old = lisp_as_symbol(name)->function;
    if (old != LISP_UNBOUND && lisp_function_kind(old) == LISP_SPECIAL_OPERATOR)
        return lisp_fail("~S is a special operator, and stays one", name);
    lisp_as_symbol(name)->function = make_function(kind, name, cdr(args), env);
    return name;
}

static lisp sf_defun(lisp args, lisp env)
{
    return define(args, env, LISP_CLOSURE);
}

static lisp sf_defmacro(lisp args, lisp env)
{
    return define(args, env, LISP_MACRO);
}

/* DEFVAR and DEFPARAMETER: the variable is special from here on, and
 * DEFVAR leaves a value it already has alone. */
static lisp define_variable(lisp args, lisp env, int always)
{
    lisp name = car(args), value;

    if (!lisp_is_symbol(name) || constant(name))
        return lisp_fail("~S cannot be made a variable", name);
    lisp_symbol_flag(name, LISP_SPECIAL);
    if (lisp_is_cons(cdr(args)) && (always || lisp_as_symbol(name)->value == LISP_UNBOUND)) {
        value = eval_car(cdr(args), env);
        if (g_unwind.to)
            return LISP_NIL;
        lisp_as_symbol(name)->value = value;
    }
    return name;
}

static lisp sf_defvar(lisp args, lisp env)
{
    return define_variable(args, env, 0);
}

static lisp sf_defparameter(lisp args, lisp env)
{
    return define_variable(args, env, 1);
}

static lisp sf_defconstant(lisp args, lisp env)
{
    lisp name = car(args), value;

    if (!lisp_is_symbol(name))
        return lisp_fail("~S cannot be made a constant", name);
    value = eval_car(cdr(args), env);
    if (g_unwind.to)
        return LISP_NIL;
    if (constant(name)) {
        if (lisp_as_symbol(name)->value != value)
            return lisp_fail("~S is a constant already, and its value is ~S", name, lisp_as_symbol(name)->value);
        return name;
    }
    lisp_as_symbol(name)->value = value;
    lisp_symbol_flag(name, LISP_SPECIAL | LISP_CONSTANT);
    return name;
}

/* Backquote. The reader makes (QUASIQUOTE x) of `x, (UNQUOTE x) of ,x and
 * (UNQUOTE-SPLICING x) of ,@x, and this builds what the backquoted form
 * stands for: a copy of it in which every ,x is the value of x and the
 * items of the value of every ,@x take its place. Inside another
 * backquote a comma belongs to that one, and stays. What is built so far
 * waits on the stack, its first cons and its last. */
static lisp quasi(lisp x, unsigned depth, lisp env)
{
    lisp *base = g_sp, value = LISP_NIL, first = x;

    if (!lisp_is_cons(x))
        return x;
    if (lisp_out_of_stack())
        return LISP_NIL;
    if (lisp_as_cons(x)->car == lisp_roots.unquote || lisp_as_cons(x)->car == lisp_roots.splice) {
        if (depth == 1) {
            if (lisp_as_cons(x)->car == lisp_roots.splice)
                return lisp_fail(",@ with no list around it to put the items in");
            return eval_car(cdr(x), env);
        }
        depth--;
    } else if (lisp_as_cons(x)->car == lisp_roots.quasiquote)
        depth++;
    *g_sp++ = LISP_NIL; /* base[0]: the first cons */
    *g_sp++ = LISP_NIL; /* base[1]: the last */
    for (; lisp_is_cons(x); x = lisp_as_cons(x)->cdr) {
        lisp item = lisp_as_cons(x)->car, list = LISP_NIL;
        int splice = depth == 1 && lisp_is_cons(item) && lisp_as_cons(item)->car == lisp_roots.splice;

        if (item == lisp_roots.unquote && x != first && depth == 1) {
            /* (a . ,b) is read as (a unquote b): the rest of the list is the value of b. */
            x = eval_car(cdr(x), env);
            break;
        }
        if (splice)
            list = eval_car(cdr(item), env);
        else
            item = quasi(item, depth, env);
        if (g_unwind.to)
            goto out;
        do {
            lisp c;

            if (splice) {
                if (!lisp_is_cons(list))
                    break;
                item = lisp_as_cons(list)->car;
                list = lisp_as_cons(list)->cdr;
            }
            c = lisp_cons(item, LISP_NIL);
            if (base[0] == LISP_NIL)
                base[0] = c;
            else
                lisp_as_cons(base[1])->cdr = c;
            base[1] = c;
        } while (splice);
    }
    if (g_unwind.to)
        goto out;
    if (base[0] == LISP_NIL)
        base[0] = x;
    else
        lisp_as_cons(base[1])->cdr = x;
    value = base[0];
out:
    g_sp = base;
    return value;
}

static lisp sf_quasiquote(lisp args, lisp env)
{
    return quasi(car(args), 1, env);
}

static const struct special {
    const char *name;
    lisp (*fn)(lisp args, lisp env);
    uint8_t min, max; /* how many subforms it takes */
    uint8_t values;   /* it passes on the values of a form in it, however many there are */
} specials[] = {
    { "QUOTE", sf_quote, 1, 1, 0 },
    { "FUNCTION", sf_function, 1, 1, 0 },
    { "LAMBDA", sf_lambda, 1, LISP_MANY, 0 },
    { "IF", sf_if, 2, 3, 1 },
    { "PROGN", progn, 0, LISP_MANY, 1 },
    { "LET", sf_let, 1, LISP_MANY, 1 },
    { "LET*", sf_let_star, 1, LISP_MANY, 1 },
    { "SETQ", sf_setq, 0, LISP_MANY, 0 },
    { "BLOCK", sf_block, 1, LISP_MANY, 1 },
    { "RETURN-FROM", sf_return_from, 1, 2, 1 },
    { "TAGBODY", sf_tagbody, 0, LISP_MANY, 0 },
    { "GO", sf_go, 1, 1, 0 },
    { "CATCH", sf_catch, 1, LISP_MANY, 1 },
    { "THROW", sf_throw, 2, 2, 1 },
    { "FLET", sf_flet, 1, LISP_MANY, 1 },
    { "LABELS", sf_labels, 1, LISP_MANY, 1 },
    { "MACROLET", sf_macrolet, 1, LISP_MANY, 1 },
    { "MULTIPLE-VALUE-CALL", sf_multiple_value_call, 1, LISP_MANY, 1 },
    { "MULTIPLE-VALUE-PROG1", sf_multiple_value_prog1, 1, LISP_MANY, 1 },
    { "MULTIPLE-VALUE-BIND", sf_multiple_value_bind, 2, LISP_MANY, 1 },
    { "EVAL-WHEN", sf_eval_when, 1, LISP_MANY, 1 },
    { "LOCALLY", sf_locally, 0, LISP_MANY, 1 },
    { "THE", sf_the, 2, 2, 1 },
    { "DECLARE", sf_declare, 0, LISP_MANY, 0 },
    { "DEFUN", sf_defun, 2, LISP_MANY, 0 },
    { "DEFMACRO", sf_defmacro, 2, LISP_MANY, 0 },
    { "DEFVAR", sf_defvar, 1, 3, 0 },
    { "DEFPARAMETER", sf_defparameter, 2, 3, 0 },
    { "DEFCONSTANT", sf_defconstant, 2, 3, 0 },
    { "QUASIQUOTE", sf_quasiquote, 1, 1, 0 },
};

/* A call: the function, then each argument as it is evaluated, on the
 * value stack, and from there to the function. */
static lisp call(lisp f, lisp args, lisp env)
{
    lisp *base = g_sp, value = LISP_NIL;

    *g_sp++ = f;
    for (; lisp_is_cons(args); args = lisp_as_cons(args)->cdr) {
        value = eval_car(args, env);
        if (g_unwind.to || !lisp_push(value))
            goto out;
    }
    value = lisp_apply(f, (unsigned)(g_sp - base - 1), base + 1);
out:
    g_sp = base;
    return value;
}

/* The value of the form in the CAR of a cons. The evaluator is given the
 * cons and not the form so that it can put the expansion of a macro call
 * where the call was. */
static lisp eval_car(lisp cell, lisp env)
{
    lisp form = lisp_as_cons(cell)->car, operator, f, *local;
    const struct special *s;
    unsigned n = 0, most;

    lisp_values.count = 1;
    if (lisp_is_symbol(form)) {
        local = special(form) ? NULL : lookup(env, VARIABLES, form);
        f = local ? *local : lisp_as_symbol(form)->value;
        return f == LISP_UNBOUND ? lisp_fail("the variable ~S has no value", form) : f;
    }
    if (!lisp_is_cons(form))
        return form;
    if (lisp_out_of_stack())
        return LISP_NIL;
    operator = lisp_as_cons(form)->car;
    if (lisp_is_symbol(operator)) {
        local = lookup(env, FUNCTIONS, operator);
        f = local ? *local : lisp_as_symbol(operator)->function;
        if (f == LISP_UNBOUND)
            return lisp_fail("the function ~S is not defined", operator);
    } else if (car(operator) == S.lambda && lisp_is_cons(operator))
        f = make_function(LISP_CLOSURE, LISP_NIL, lisp_as_cons(operator)->cdr, env);
    else
        return lisp_fail("~S is not the name of a function, so ~S is not a form", operator, form);
    switch (lisp_function_kind(f)) {
    case LISP_SPECIAL_OPERATOR:
        s = &specials[lisp_fixnum_value(lisp_as_function(f)->code)];
        most = s->max == LISP_MANY ? s->min : s->max + 1u;
        for (lisp a = lisp_as_cons(form)->cdr; lisp_is_cons(a) && n < most; a = lisp_as_cons(a)->cdr)
            n++;
        if (n < s->min || n > s->max)
            return lisp_fail("~S has the wrong number of parts for ~S", form, operator);
        f = s->fn(lisp_as_cons(form)->cdr, env);
        if (!s->values)
            lisp_values.count = 1;
        return f;
    case LISP_MACRO:
        f = expand(f, form);
        if (g_unwind.to)
            return LISP_NIL;
        lisp_as_cons(cell)->car = f;
        return eval_car(cell, env);
    default:
        return call(f, lisp_as_cons(form)->cdr, env);
    }
}

static lisp wrong_count(const struct lisp_primitive *p, unsigned argc)
{
    if (p->max == LISP_MANY)
        return lisp_fail("the number of arguments ~Z takes is ~A or more, not ~A", p->name, lisp_fixnum(p->min),
                         lisp_fixnum(argc));
    if (p->min == p->max)
        return lisp_fail("the number of arguments ~Z takes is ~A, not ~A", p->name, lisp_fixnum(p->min),
                         lisp_fixnum(argc));
    return lisp_fail("the number of arguments ~Z takes is ~A to ~A, not ~A", p->name, lisp_fixnum(p->min),
                     lisp_fixnum(p->max), lisp_fixnum(argc));
}

/* A function, or the symbol that names one, called with arguments that are
 * on the value stack. This is a safe point: everything that is in use is
 * on that stack, or can be reached from it. */
lisp lisp_apply(lisp f, unsigned argc, lisp *argv)
{
    const struct lisp_primitive *p;

    thread_safe_point();
    if (lisp_is_symbol(f)) {
        if (lisp_as_symbol(f)->function == LISP_UNBOUND)
            return lisp_fail("the function ~S is not defined", f);
        f = lisp_as_symbol(f)->function;
    }
    if (!lisp_is(f, LISP_FUNCTION))
        return lisp_fail("~S is not a function", f);
    switch (lisp_function_kind(f)) {
    case LISP_PRIMITIVE:
        p = &lisp_primitives[lisp_fixnum_value(lisp_as_function(f)->code)];
        if (argc < p->min || argc > p->max)
            return wrong_count(p, argc);
        lisp_values.count = 1;
        g_primitive = p;
        return p->fn(argc, argv);
    case LISP_CLOSURE:
        return apply_closure(f, argc, argv, LISP_NIL);
    default:
        return lisp_fail("~S is not a function, and cannot be called like one", f);
    }
}

/* The value of a form that nothing else holds: it goes on the stack in a
 * cons of its own, which is also where a macro call at its top is
 * replaced. */
lisp lisp_eval(lisp form, lisp env)
{
    lisp *base = g_sp, value;

    *g_sp++ = env;
    *g_sp++ = lisp_cons(form, LISP_NIL);
    value = eval_car(base[1], env);
    g_sp = base;
    return value;
}

/* LOAD: the forms of a file, evaluated one after the other. The only
 * files so far are the ones the boot handoff read from the boot volume's
 * \clara directory, and a name finds one whatever the case of its
 * letters. *PACKAGE* is bound meanwhile, so that an IN-PACKAGE in the
 * file ends with the file. An error says where in the file it was. */
static uint32_t fold(uint32_t c)
{
    return c >= 'a' && c <= 'z' ? c - ('a' - 'A') : c;
}

lisp lisp_load(lisp name)
{
    const struct boot_file *f = g_files;
    const struct lisp_string *s = lisp_as_string(name);
    struct lisp_reader r;
    unsigned bound = g_bound, line, column;
    uint64_t i;
    lisp form;

    if (!lisp_is(name, LISP_STRING))
        return lisp_fail("LOAD wants the name of a file, in a string, and ~S is not one", name);
    for (; f; f = f->next) {
        for (i = 0; i < lisp_length(s->header) && f->name[i] && fold(s->chars[i]) == fold((uint8_t)f->name[i]); i++)
            ;
        if (i == lisp_length(s->header) && !f->name[i])
            break;
    }
    if (!f)
        return lisp_fail("LOAD: the boot volume has no file ~S in its \\clara directory", name);
    bind_special(lisp_roots.package, lisp_current_package());
    lisp_reader_init(&r, f->data, f->size);
    while (!g_unwind.to) {
        enum lisp_read_status status = lisp_read(&r, &form);

        if (status == LISP_READ_END)
            break;
        lisp_reader_where(&r, &line, &column);
        if (status != LISP_READ_OK) {
            lisp_fail("~Z, at line ~A, column ~A of ~Z", r.error, lisp_fixnum(line), lisp_fixnum(column), f->name);
            break;
        }
        lisp_eval(form, LISP_NIL);
        if (g_unwind.to == FAILING)
            g_unwind.tag = text("~A, in the form at line ~A of ~Z", g_unwind.tag, lisp_fixnum(line), f->name);
    }
    unbind(bound);
    return lisp_roots.t;
}

/* A form evaluated at the top level, where an error ends up. Returns 1
 * with the values in lisp_values, all of them, or 0 with what went wrong
 * as the one value. The evaluator's stacks have to be where they were:
 * every piece of it gives back what it took, on every way out. */
int lisp_evaluate(lisp form)
{
    lisp *base = g_sp, value;
    unsigned bound = g_bound;
    const struct catch *catches = g_catches;

    value = lisp_eval(form, LISP_NIL);
    if (g_sp != base || g_bound != bound || g_catches != catches)
        panic("lisp: the evaluator left %lld values on its stack, %d bindings, and the catches %s",
              (long long)(g_sp - base), (int)(g_bound - bound), g_catches == catches ? "as they were" : "changed");
    if (!g_unwind.to) {
        settle(value);
        return 1;
    }
    if (g_unwind.to != FAILING)
        panic("lisp: a non-local exit came out at the top level");
    lisp_values.count = 1;
    lisp_values.value[0] = g_unwind.tag;
    g_unwind.to = 0;
    g_unwind.tag = LISP_NIL;
    return 0;
}

/* The symbols of the special forms and of the functions in C, each with
 * its function. The names are the language's own, external in
 * COMMON-LISP, apart from the ones that begin with a %, which are the
 * substrate's and stay internal there. */
void lisp_eval_init(const struct boot_file *files)
{
    lisp cl = lisp_roots.common_lisp, symbol;

    g_files = files;
    S.declare = lisp_symbol_in(cl, "DECLARE", 1);
    S.special = lisp_symbol_in(cl, "SPECIAL", 1);
    S.optional = lisp_symbol_in(cl, "&OPTIONAL", 1);
    S.rest = lisp_symbol_in(cl, "&REST", 1);
    S.body = lisp_symbol_in(cl, "&BODY", 1);
    S.key = lisp_symbol_in(cl, "&KEY", 1);
    S.allow_other_keys = lisp_symbol_in(cl, "&ALLOW-OTHER-KEYS", 1);
    S.aux = lisp_symbol_in(cl, "&AUX", 1);
    S.whole = lisp_symbol_in(cl, "&WHOLE", 1);
    S.environment = lisp_symbol_in(cl, "&ENVIRONMENT", 1);
    S.execute = lisp_symbol_in(lisp_roots.keyword, "EXECUTE", 1);
    S.allow = lisp_symbol_in(lisp_roots.keyword, "ALLOW-OTHER-KEYS", 1);
    for (unsigned i = 0; i < sizeof specials / sizeof specials[0]; i++) {
        symbol = lisp_symbol_in(cl, specials[i].name, specials[i].fn != sf_quasiquote);
        lisp_as_symbol(symbol)->function = make_function(LISP_SPECIAL_OPERATOR, symbol, lisp_fixnum(i), LISP_NIL);
    }
    for (unsigned i = 0; i < lisp_primitive_count; i++) {
        symbol = lisp_symbol_in(cl, lisp_primitives[i].name, lisp_primitives[i].name[0] != '%');
        lisp_as_symbol(symbol)->function = make_function(LISP_PRIMITIVE, symbol, lisp_fixnum(i), LISP_NIL);
    }
    S.lambda = lisp_symbol_in(cl, "LAMBDA", 1);
    S.eval = lisp_symbol_in(cl, "EVAL", 1);
    kprintf("lisp: an evaluator with %u special forms and %u functions in C\n",
            (unsigned)(sizeof specials / sizeof specials[0]), lisp_primitive_count);
}

/* The thread that calls this is the one that evaluates from now on: the
 * depth it can go to is measured on its stack. */
void lisp_eval_start(void)
{
    g_c_limit = (uintptr_t)thread_stack_guard() + PAGE_SIZE + MARGIN;
}
