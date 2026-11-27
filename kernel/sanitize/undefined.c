/* Undefined behaviour, said and stopped at. A kernel that is built with
 * SANITIZE=undefined (Makefile) has a check from the compiler in front of
 * every place where C leaves open what happens: a sum that does not fit
 * its type, a shift by more bits than there are, an index outside its
 * array, a load through a pointer that is null or not aligned for what it
 * points at, a call of a function through a pointer to another kind of
 * function. A check that fails calls one of the functions here, with what
 * the compiler wrote down about the place, and this is their whole job:
 * say where it was and what was about to happen, the way panic says it,
 * and stop the machine. So a boot of such a kernel that comes to its end
 * has done nothing of the kind on the way, and one that has not says why,
 * in a line that begins with "panic:", which is what ends a boot of
 * tools/boottest.sh.
 *
 * The names of these functions and the layout of what they are handed are
 * the compiler's (clang's compiler-rt, lib/ubsan/ubsan_handlers.h). They
 * are the ones that it calls when it has been told that a check which
 * failed is not to be gone on from (-fno-sanitize-recover): none of them
 * returns. A kernel that is built without SANITIZE has no check in it and
 * nothing of this file. */
#include "kernel.h"

struct place {
    const char *file;
    uint32_t line, column;
};

/* A type, as the compiler describes one: what kind it is, and for an
 * integer whether it has a sign, in the lowest bit of info, and how many
 * bits it has, as a power of two, in the bits above. The name is the one
 * in the source, between quotes. */
enum { AN_INTEGER = 0 };

struct type {
    uint16_t kind, info;
    char name[];
};

static int g_stopping; /* a report is being made: whatever goes wrong in making it is not reported in turn */

static void begin(const struct place *at)
{
    arch_interrupts_off();
    if (g_stopping++)
        arch_halt();
    fbcon_set_color(FBCON_ALERT);
    kprintf("\npanic: undefined behaviour at %s:%u:%u: ", at->file, at->line, at->column);
}

static void end(void) __attribute__((noreturn));
static void end(void)
{
    kputc('\n');
    arch_halt();
}

static unsigned bits_of(const struct type *t)
{
    return 1u << (t->info >> 1);
}

static int is_signed(const struct type *t)
{
    return t->kind == AN_INTEGER && (t->info & 1);
}

/* A value of that type, as it was handed over: in a word, with zeroes
 * above its own bits whatever its sign. */
static int64_t signed_value(const struct type *t, uintptr_t v)
{
    unsigned spare = bits_of(t) < 64 ? 64 - bits_of(t) : 0;

    return (int64_t)((uint64_t)v << spare) >> spare;
}

static void put_value(const struct type *t, uintptr_t v)
{
    if (t->kind != AN_INTEGER || bits_of(t) > 64)
        kprintf("0x%llx", (uint64_t)v); /* no integer, or one too wide for a word: what was handed over */
    else if (is_signed(t))
        kprintf("%lld", (long long)signed_value(t, v));
    else
        kprintf("%llu", (uint64_t)v);
}

/* Arithmetic whose result is not a value of its type. */
struct overflow {
    struct place at;
    const struct type *type;
};

static void overflow(const struct overflow *o, uintptr_t a, const char *operation, uintptr_t b)
    __attribute__((noreturn));
static void overflow(const struct overflow *o, uintptr_t a, const char *operation, uintptr_t b)
{
    begin(&o->at);
    put_value(o->type, a);
    kputs(operation);
    put_value(o->type, b);
    kprintf(" is not a value of %s", o->type->name);
    end();
}

void __ubsan_handle_add_overflow_abort(const struct overflow *o, uintptr_t a, uintptr_t b)
{
    overflow(o, a, " + ", b);
}

void __ubsan_handle_sub_overflow_abort(const struct overflow *o, uintptr_t a, uintptr_t b)
{
    overflow(o, a, " - ", b);
}

void __ubsan_handle_mul_overflow_abort(const struct overflow *o, uintptr_t a, uintptr_t b)
{
    overflow(o, a, " * ", b);
}

void __ubsan_handle_negate_overflow_abort(const struct overflow *o, uintptr_t a)
{
    begin(&o->at);
    kputs("the negative of ");
    put_value(o->type, a);
    kprintf(" is not a value of %s", o->type->name);
    end();
}

void __ubsan_handle_divrem_overflow_abort(const struct overflow *o, uintptr_t a, uintptr_t b)
{
    if (b)
        overflow(o, a, " / ", b); /* the least value of its type, divided by -1 */
    begin(&o->at);
    put_value(o->type, a);
    kputs(" divided by zero");
    end();
}

struct shift {
    struct place at;
    const struct type *type, *by;
};

void __ubsan_handle_shift_out_of_bounds_abort(const struct shift *s, uintptr_t a, uintptr_t by)
{
    begin(&s->at);
    if (is_signed(s->by) && signed_value(s->by, by) < 0)
        kprintf("a shift by %lld bits", (long long)signed_value(s->by, by));
    else if (by >= bits_of(s->type))
        kprintf("a shift by %llu bits of %s, which has %u", (uint64_t)by, s->type->name, bits_of(s->type));
    else {
        put_value(s->type, a);
        kprintf(" shifted left by %llu bits is not a value of %s", (uint64_t)by, s->type->name);
    }
    end();
}

struct bounds {
    struct place at;
    const struct type *array, *index;
};

void __ubsan_handle_out_of_bounds_abort(const struct bounds *b, uintptr_t index)
{
    begin(&b->at);
    kputs("index ");
    put_value(b->index, index);
    kprintf(" of %s", b->array->name);
    end();
}

/* A pointer that cannot be used for what it is about to be used for. */
struct mismatch {
    struct place at;
    const struct type *type;
    uint8_t alignment; /* which the type asks for, as a power of two */
    uint8_t use;       /* what the pointer is for */
};

void __ubsan_handle_type_mismatch_v1_abort(const struct mismatch *m, uintptr_t pointer)
{
    static const char *const uses[] = { "a load of", "a store to", "a reference to", "a member of" };
    const char *use = m->use < sizeof uses / sizeof uses[0] ? uses[m->use] : "a use of";

    begin(&m->at);
    if (!pointer)
        kprintf("%s %s through a null pointer", use, m->type->name);
    else if (pointer & (((uintptr_t)1 << m->alignment) - 1))
        kprintf("%s %s at %p, which is no multiple of %u", use, m->type->name, (void *)pointer, 1u << m->alignment);
    else
        kprintf("%s %s at %p, where the object is too small for one", use, m->type->name, (void *)pointer);
    end();
}

struct pointer_overflow {
    struct place at;
};

void __ubsan_handle_pointer_overflow_abort(const struct pointer_overflow *p, uintptr_t base, uintptr_t result)
{
    begin(&p->at);
    if (!base)
        kprintf("an offset of %lld added to a null pointer", (long long)(int64_t)result);
    else if (!result)
        kprintf("an offset added to %p that makes a null pointer of it", (void *)base);
    else
        kprintf("an offset added to %p that takes it round the end of memory, to %p", (void *)base, (void *)result);
    end();
}

struct unreachable {
    struct place at;
};

void __ubsan_handle_builtin_unreachable(const struct unreachable *u)
{
    begin(&u->at);
    kputs("the processor is where the source says that it never comes");
    end();
}

struct function_mismatch {
    struct place at;
    const struct type *type;
};

void __ubsan_handle_function_type_mismatch_abort(const struct function_mismatch *f, uintptr_t function)
{
    begin(&f->at);
    kprintf("a call of the function at %p through a pointer to %s, which it is not", (void *)function, f->type->name);
    end();
}

/* A value that its type does not have: a bool that is neither 0 nor 1. */
struct invalid_value {
    struct place at;
    const struct type *type;
};

void __ubsan_handle_load_invalid_value_abort(const struct invalid_value *i, uintptr_t value)
{
    begin(&i->at);
    kputs("a load of ");
    put_value(i->type, value);
    kprintf(", which is no value of %s", i->type->name);
    end();
}

struct invalid_builtin {
    struct place at;
    uint8_t kind; /* 0 and 1: the count of the zero bits at either end. 2: an assumption */
};

void __ubsan_handle_invalid_builtin_abort(const struct invalid_builtin *i)
{
    begin(&i->at);
    kputs(i->kind < 2 ? "the zero bits at one end of 0 were asked for, which the builtin has no answer to"
                      : "something that the source tells the compiler to assume is not so");
    end();
}

struct array_length {
    struct place at;
    const struct type *type;
};

void __ubsan_handle_vla_bound_not_positive_abort(const struct array_length *a, uintptr_t length)
{
    begin(&a->at);
    kputs("an array of ");
    put_value(a->type, length);
    kputs(" items");
    end();
}

struct nonnull_argument {
    struct place at, declared;
    int argument;
};

void __ubsan_handle_nonnull_arg_abort(const struct nonnull_argument *n)
{
    begin(&n->at);
    kprintf("a null pointer as argument %d of a function that is declared to take none", n->argument);
    end();
}

struct nonnull_return {
    struct place declared;
};

void __ubsan_handle_nonnull_return_v1_abort(const struct nonnull_return *n, const struct place *at)
{
    (void)n;
    begin(at);
    kputs("a null pointer returned by a function that is declared to return none");
    end();
}

struct assumed_alignment {
    struct place at, assumed;
    const struct type *type;
};

void __ubsan_handle_alignment_assumption_abort(const struct assumed_alignment *a, uintptr_t pointer, uintptr_t alignment,
                                               uintptr_t offset)
{
    (void)offset;
    begin(&a->at);
    kprintf("%p is assumed to be a multiple of %llu, and is not", (void *)pointer, (uint64_t)alignment);
    end();
}
