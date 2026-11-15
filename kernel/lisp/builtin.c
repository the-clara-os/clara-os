/* The functions written in C: the ones the rest of the language is built
 * from in lisp/boot.lisp, and the ones that have to reach inside an
 * object. Each takes its arguments where the evaluator left them, argc
 * words at argv on the value stack, and lisp_apply has checked how many
 * there are against the table at the end of this file.
 *
 * None of them holds an object in a C variable across a call back into
 * the evaluator, where the collector may run (eval.c says why). The few
 * that call back, FUNCALL, APPLY, EVAL, LOAD and ERROR with the name of a
 * type, have nothing to hold; whatever maps a function over a list is
 * written in Lisp for that reason. The functions that wait are in
 * thread.c, and hold nothing but their arguments while they do. */
#include "lisp.h"

#define PRIMITIVE(name) static lisp name(unsigned argc __attribute__((unused)), lisp *argv)
#define NIL LISP_NIL
#define T   lisp_roots.t
#define INTEGER(x) \
    do { \
        if (!lisp_is_fixnum(x)) \
            return lisp_wants("an integer", x); \
    } while (0)
#define SYMBOL(x) \
    do { \
        if (!lisp_is_symbol(x)) \
            return lisp_wants("a symbol", x); \
    } while (0)

static lisp boolean(int x)
{
    return x ? T : NIL;
}

/* An object as large as a program asked for, and the heap cannot hold it. */
static lisp no_room(void)
{
    return lisp_fail_as("STORAGE-CONDITION", NULL, 0, "the heap is full: there is no room for an object that large");
}

/* The console, as Lisp writes to it: the serial port and the screen. */
int lisp_console_fresh = 1;

void lisp_console_put(void *to, char c)
{
    (void)to;
    kputc(c);
    lisp_console_fresh = c == '\n';
}

void lisp_fresh_line(void)
{
    if (!lisp_console_fresh)
        lisp_console_put(NULL, '\n');
}

/* Conses and lists. */
PRIMITIVE(p_cons)
{
    return lisp_cons(argv[0], argv[1]);
}

PRIMITIVE(p_car)
{
    if (argv[0] == NIL)
        return NIL;
    return lisp_is_cons(argv[0]) ? lisp_as_cons(argv[0])->car : lisp_wants("a list", argv[0]);
}

PRIMITIVE(p_cdr)
{
    if (argv[0] == NIL)
        return NIL;
    return lisp_is_cons(argv[0]) ? lisp_as_cons(argv[0])->cdr : lisp_wants("a list", argv[0]);
}

PRIMITIVE(p_rplaca)
{
    if (!lisp_is_cons(argv[0]))
        return lisp_wants("a cons", argv[0]);
    lisp_as_cons(argv[0])->car = argv[1];
    return argv[0];
}

PRIMITIVE(p_rplacd)
{
    if (!lisp_is_cons(argv[0]))
        return lisp_wants("a cons", argv[0]);
    lisp_as_cons(argv[0])->cdr = argv[1];
    return argv[0];
}

PRIMITIVE(p_list)
{
    lisp list = NIL;

    while (argc--)
        list = lisp_cons(argv[argc], list);
    return list;
}

PRIMITIVE(p_list_star)
{
    lisp list = argv[--argc];

    while (argc--)
        list = lisp_cons(argv[argc], list);
    return list;
}

/* Every list but the last is copied. */
PRIMITIVE(p_append)
{
    lisp head = NIL, tail = NIL;

    for (unsigned i = 0; i < argc; i++) {
        lisp list = argv[i];

        if (i + 1 == argc) {
            if (tail == NIL)
                return list;
            lisp_as_cons(tail)->cdr = list;
            break;
        }
        for (; lisp_is_cons(list); list = lisp_as_cons(list)->cdr) {
            lisp c = lisp_cons(lisp_as_cons(list)->car, NIL);

            if (tail == NIL)
                head = c;
            else
                lisp_as_cons(tail)->cdr = c;
            tail = c;
        }
        if (list != NIL)
            return lisp_wants("lists", argv[i]);
    }
    return head;
}

PRIMITIVE(p_length)
{
    lisp x = argv[0];
    int64_t n = 0;

    if (lisp_is(x, LISP_STRING) || lisp_is(x, LISP_VECTOR))
        return lisp_fixnum((int64_t)lisp_length(*(lisp *)lisp_object(x)));
    for (; lisp_is_cons(x); x = lisp_as_cons(x)->cdr)
        n++;
    return x == NIL ? lisp_fixnum(n) : lisp_wants("a list, a string or a vector", argv[0]);
}

/* What things are. EQL is EQ here: a fixnum and a character are their own
 * words, and there are no other numbers. */
PRIMITIVE(p_eq)
{
    return boolean(argv[0] == argv[1]);
}

static int equal(lisp a, lisp b)
{
    for (;;) {
        if (a == b)
            return 1;
        if (lisp_is_cons(a) && lisp_is_cons(b)) {
            if (lisp_out_of_stack() || !equal(lisp_as_cons(a)->car, lisp_as_cons(b)->car))
                return 0;
            a = lisp_as_cons(a)->cdr;
            b = lisp_as_cons(b)->cdr;
            continue;
        }
        if (lisp_is(a, LISP_STRING) && lisp_is(b, LISP_STRING)) {
            const struct lisp_string *s = lisp_as_string(a), *t = lisp_as_string(b);

            return s->header == t->header && !memcmp(s->chars, t->chars, lisp_length(s->header) * sizeof s->chars[0]);
        }
        return 0;
    }
}

PRIMITIVE(p_equal)
{
    return boolean(equal(argv[0], argv[1]));
}

#define PREDICATE(name, test) \
    PRIMITIVE(name) \
    { \
        lisp x = argv[0]; \
        return boolean(test); \
    }
PREDICATE(p_null, x == NIL)
PREDICATE(p_consp, lisp_is_cons(x))
PREDICATE(p_atom, !lisp_is_cons(x))
PREDICATE(p_listp, lisp_is_cons(x) || x == NIL)
PREDICATE(p_symbolp, lisp_is_symbol(x))
PREDICATE(p_keywordp, lisp_is_symbol(x) && lisp_as_symbol(x)->package == lisp_roots.keyword)
PREDICATE(p_integerp, lisp_is_fixnum(x))
PREDICATE(p_characterp, lisp_is_character(x))
PREDICATE(p_stringp, lisp_is(x, LISP_STRING))
PREDICATE(p_vectorp, lisp_is(x, LISP_VECTOR) || lisp_is(x, LISP_STRING))
PREDICATE(p_functionp, lisp_is(x, LISP_FUNCTION) && (lisp_function_kind(x) == LISP_PRIMITIVE ||
                                                     lisp_function_kind(x) == LISP_CLOSURE))
PREDICATE(p_packagep, lisp_is(x, LISP_PACKAGE))

/* Integers. They are fixnums, and a result that is not one is an error:
 * never the wrong number. Two fixnums can be added as the words they are,
 * and the sum leaves 64 bits exactly when the integers leave 63. */
static lisp too_large(void)
{
    return lisp_fail_as("ARITHMETIC-ERROR", NULL, 0,
                        "the result is an integer too large for a fixnum, and there are no larger integers yet");
}

PRIMITIVE(p_add)
{
    int64_t sum = 0;

    for (unsigned i = 0; i < argc; i++) {
        INTEGER(argv[i]);
        if (__builtin_add_overflow(sum, (int64_t)argv[i], &sum))
            return too_large();
    }
    return (lisp)sum;
}

PRIMITIVE(p_subtract)
{
    int64_t difference = argc == 1 ? 0 : (int64_t)argv[0];

    INTEGER(argv[0]);
    for (unsigned i = argc > 1; i < argc; i++) {
        INTEGER(argv[i]);
        if (__builtin_sub_overflow(difference, (int64_t)argv[i], &difference))
            return too_large();
    }
    return (lisp)difference;
}

PRIMITIVE(p_multiply)
{
    int64_t product = (int64_t)lisp_fixnum(1);

    for (unsigned i = 0; i < argc; i++) {
        INTEGER(argv[i]);
        if (__builtin_mul_overflow(product, lisp_fixnum_value(argv[i]), &product))
            return too_large();
    }
    return (lisp)product;
}

/* n divided by d, or by 1: the quotient, rounded down or toward zero, and
 * what is left over. Says 0 after failing. */
static int divide(lisp n, lisp d, int down, int64_t *quotient, int64_t *remainder)
{
    int64_t a = lisp_fixnum_value(n), b = lisp_fixnum_value(d);

    if (!lisp_is_fixnum(n) || !lisp_is_fixnum(d)) {
        lisp_wants("an integer", lisp_is_fixnum(n) ? d : n);
        return 0;
    }
    if (!b) {
        lisp_fail_as("DIVISION-BY-ZERO", NULL, 0, "division by zero");
        return 0;
    }
    *quotient = a / b;
    *remainder = a % b;
    if (down && *remainder && (*remainder < 0) != (b < 0)) {
        --*quotient;
        *remainder += b;
    }
    if (*quotient > LISP_FIXNUM_MAX) {
        too_large();
        return 0;
    }
    return 1;
}

static lisp quotient_and_remainder(unsigned argc, lisp *argv, int down, unsigned which)
{
    int64_t part[2];

    if (!divide(argv[0], argc > 1 ? argv[1] : lisp_fixnum(1), down, &part[0], &part[1]))
        return NIL;
    if (which)
        return lisp_fixnum(part[1]);
    lisp_values.count = 2;
    lisp_values.value[0] = lisp_fixnum(part[0]);
    lisp_values.value[1] = lisp_fixnum(part[1]);
    return lisp_values.value[0];
}

PRIMITIVE(p_floor)
{
    return quotient_and_remainder(argc, argv, 1, 0);
}

PRIMITIVE(p_truncate)
{
    return quotient_and_remainder(argc, argv, 0, 0);
}

PRIMITIVE(p_mod)
{
    return quotient_and_remainder(argc, argv, 1, 1);
}

PRIMITIVE(p_rem)
{
    return quotient_and_remainder(argc, argv, 0, 1);
}

/* / gives an integer or nothing: there are no ratios to give instead. */
PRIMITIVE(p_divide)
{
    lisp n = argc == 1 ? lisp_fixnum(1) : argv[0];
    int64_t quotient, remainder;

    for (unsigned i = argc > 1; i < argc; i++) {
        if (!divide(n, argv[i], 0, &quotient, &remainder))
            return NIL;
        if (remainder)
            return lisp_fail("~S divided by ~S is not an integer, and there are no ratios yet", n, argv[i]);
        n = lisp_fixnum(quotient);
    }
    return n;
}

PRIMITIVE(p_add_one)
{
    int64_t n;

    INTEGER(argv[0]);
    return __builtin_add_overflow((int64_t)argv[0], (int64_t)lisp_fixnum(1), &n) ? too_large() : (lisp)n;
}

PRIMITIVE(p_subtract_one)
{
    int64_t n;

    INTEGER(argv[0]);
    return __builtin_sub_overflow((int64_t)argv[0], (int64_t)lisp_fixnum(1), &n) ? too_large() : (lisp)n;
}

/* Is every argument to the one after it as the three flags allow? */
static lisp compare(unsigned argc, lisp *argv, int less, int same, int greater)
{
    for (unsigned i = 0; i < argc; i++)
        INTEGER(argv[i]);
    for (unsigned i = 0; i + 1 < argc; i++) {
        int64_t a = (int64_t)argv[i], b = (int64_t)argv[i + 1];

        if (!(a < b ? less : a == b ? same : greater))
            return NIL;
    }
    return T;
}

PRIMITIVE(p_same)
{
    return compare(argc, argv, 0, 1, 0);
}

PRIMITIVE(p_less)
{
    return compare(argc, argv, 1, 0, 0);
}

PRIMITIVE(p_greater)
{
    return compare(argc, argv, 0, 0, 1);
}

PRIMITIVE(p_at_most)
{
    return compare(argc, argv, 1, 1, 0);
}

PRIMITIVE(p_at_least)
{
    return compare(argc, argv, 0, 1, 1);
}

PRIMITIVE(p_different)
{
    for (unsigned i = 0; i < argc; i++)
        INTEGER(argv[i]);
    for (unsigned i = 0; i < argc; i++)
        for (unsigned j = i + 1; j < argc; j++)
            if (argv[i] == argv[j])
                return NIL;
    return T;
}

/* The bits of two fixnums can be combined as the words they are: the tag
 * bit is 0 in both, and stays 0. */
PRIMITIVE(p_logand)
{
    lisp bits = lisp_fixnum(-1);

    for (unsigned i = 0; i < argc; i++) {
        INTEGER(argv[i]);
        bits &= argv[i];
    }
    return bits;
}

PRIMITIVE(p_logior)
{
    lisp bits = 0;

    for (unsigned i = 0; i < argc; i++) {
        INTEGER(argv[i]);
        bits |= argv[i];
    }
    return bits;
}

PRIMITIVE(p_logxor)
{
    lisp bits = 0;

    for (unsigned i = 0; i < argc; i++) {
        INTEGER(argv[i]);
        bits ^= argv[i];
    }
    return bits;
}

PRIMITIVE(p_lognot)
{
    INTEGER(argv[0]);
    return ~argv[0] & ~1ULL;
}

PRIMITIVE(p_ash)
{
    int64_t n, count, shifted;

    INTEGER(argv[0]);
    INTEGER(argv[1]);
    n = lisp_fixnum_value(argv[0]);
    count = lisp_fixnum_value(argv[1]);
    if (count <= 0)
        return lisp_fixnum(count < -62 ? -(n < 0) : n >> -count);
    if (!n)
        return argv[0];
    if (count > 62)
        return too_large();
    shifted = (int64_t)((uint64_t)n << count);
    if (shifted >> count != n || shifted > LISP_FIXNUM_MAX || shifted < -LISP_FIXNUM_MAX - 1)
        return too_large();
    return lisp_fixnum(shifted);
}

/* Characters, strings and vectors. */
PRIMITIVE(p_char_code)
{
    if (!lisp_is_character(argv[0]))
        return lisp_wants("a character", argv[0]);
    return lisp_fixnum(lisp_character_code(argv[0]));
}

PRIMITIVE(p_code_char)
{
    int64_t code;

    INTEGER(argv[0]);
    code = lisp_fixnum_value(argv[0]);
    if (code < 0 || code >= LISP_CODE_LIMIT || (code & ~0x7ffLL) == 0xd800)
        return NIL;
    return lisp_character((uint32_t)code);
}

/* What a string, a symbol or a character stands for where a string is
 * wanted, or 0 after failing. */
static lisp string_of(lisp x)
{
    uint32_t c = lisp_character_code(x);

    if (lisp_is(x, LISP_STRING))
        return x;
    if (lisp_is_symbol(x))
        return lisp_as_symbol(x)->name;
    if (lisp_is_character(x))
        return lisp_make_string(&c, 1);
    lisp_wants("a string, a symbol or a character", x);
    return 0;
}

PRIMITIVE(p_string)
{
    lisp string = string_of(argv[0]);

    return string ? string : NIL;
}

PRIMITIVE(p_string_same)
{
    lisp a = string_of(argv[0]), b = a ? string_of(argv[1]) : 0;

    return boolean(b && equal(a, b));
}

PRIMITIVE(p_string_append)
{
    uint64_t length = 0, at = 0;
    lisp string;

    for (unsigned i = 0; i < argc; i++) {
        if (!lisp_is(argv[i], LISP_STRING))
            return lisp_wants("a string", argv[i]);
        length += lisp_length(lisp_as_string(argv[i])->header);
    }
    if (!lisp_heap_room(1 + (length + 1) / 2))
        return no_room();
    string = lisp_make_string(NULL, length);
    for (unsigned i = 0; i < argc; i++) {
        const struct lisp_string *s = lisp_as_string(argv[i]);

        memcpy(lisp_as_string(string)->chars + at, s->chars, lisp_length(s->header) * sizeof s->chars[0]);
        at += lisp_length(s->header);
    }
    return string;
}

/* Is index a place in something that long? Says 0 after failing. */
static int index_in(lisp index, uint64_t length, uint64_t *i)
{
    if (lisp_is_fixnum(index) && (uint64_t)lisp_fixnum_value(index) < length) {
        *i = (uint64_t)lisp_fixnum_value(index);
        return 1;
    }
    lisp_wants("an index that is inside what it is given", index);
    return 0;
}

PRIMITIVE(p_char)
{
    uint64_t i;

    if (!lisp_is(argv[0], LISP_STRING))
        return lisp_wants("a string", argv[0]);
    if (!index_in(argv[1], lisp_length(lisp_as_string(argv[0])->header), &i))
        return NIL;
    return lisp_character(lisp_as_string(argv[0])->chars[i]);
}

PRIMITIVE(p_set_char) /* string index character */
{
    uint64_t i;

    if (!lisp_is(argv[0], LISP_STRING))
        return lisp_wants("a string", argv[0]);
    if (!lisp_is_character(argv[2]))
        return lisp_wants("a character", argv[2]);
    if (!index_in(argv[1], lisp_length(lisp_as_string(argv[0])->header), &i))
        return NIL;
    lisp_as_string(argv[0])->chars[i] = lisp_character_code(argv[2]);
    return argv[2];
}

PRIMITIVE(p_aref)
{
    uint64_t i;

    if (lisp_is(argv[0], LISP_STRING))
        return p_char(argc, argv);
    if (!lisp_is(argv[0], LISP_VECTOR))
        return lisp_wants("a vector", argv[0]);
    if (!index_in(argv[1], lisp_length(lisp_as_vector(argv[0])->header), &i))
        return NIL;
    return lisp_as_vector(argv[0])->items[i];
}

PRIMITIVE(p_set_aref) /* vector index value */
{
    uint64_t i;

    if (lisp_is(argv[0], LISP_STRING))
        return p_set_char(argc, argv);
    if (!lisp_is(argv[0], LISP_VECTOR))
        return lisp_wants("a vector", argv[0]);
    if (!index_in(argv[1], lisp_length(lisp_as_vector(argv[0])->header), &i))
        return NIL;
    return lisp_as_vector(argv[0])->items[i] = argv[2];
}

PRIMITIVE(p_vector)
{
    lisp vector = lisp_make_vector(argc);

    memcpy(lisp_as_vector(vector)->items, argv, argc * sizeof(lisp));
    return vector;
}

PRIMITIVE(p_make_vector) /* length, and what every item is to be */
{
    uint64_t length;
    lisp vector;

    if (!index_in(argv[0], 1ULL << 32, &length))
        return NIL;
    if (!lisp_heap_room(1 + length))
        return no_room();
    vector = lisp_make_vector(length);
    for (uint64_t i = 0; i < length; i++)
        lisp_as_vector(vector)->items[i] = argv[1];
    return vector;
}

/* Symbols. */
PRIMITIVE(p_symbol_name)
{
    SYMBOL(argv[0]);
    return lisp_as_symbol(argv[0])->name;
}

PRIMITIVE(p_symbol_package)
{
    SYMBOL(argv[0]);
    return lisp_as_symbol(argv[0])->package;
}

PRIMITIVE(p_symbol_value)
{
    SYMBOL(argv[0]);
    if (lisp_as_symbol(argv[0])->value == LISP_UNBOUND)
        return lisp_fail_as("UNBOUND-VARIABLE", "NAME", argv[0], "the variable ~S has no value", argv[0]);
    return lisp_as_symbol(argv[0])->value;
}

PRIMITIVE(p_symbol_function)
{
    SYMBOL(argv[0]);
    if (lisp_as_symbol(argv[0])->function == LISP_UNBOUND)
        return lisp_fail_as("UNDEFINED-FUNCTION", "NAME", argv[0], "the function ~S is not defined", argv[0]);
    return lisp_as_symbol(argv[0])->function;
}

PRIMITIVE(p_symbol_plist)
{
    SYMBOL(argv[0]);
    return lisp_as_symbol(argv[0])->plist;
}

PRIMITIVE(p_boundp)
{
    SYMBOL(argv[0]);
    return boolean(lisp_as_symbol(argv[0])->value != LISP_UNBOUND);
}

PRIMITIVE(p_fboundp)
{
    SYMBOL(argv[0]);
    return boolean(lisp_as_symbol(argv[0])->function != LISP_UNBOUND);
}

PRIMITIVE(p_set)
{
    SYMBOL(argv[0]);
    if (lisp_symbol_flags(argv[0]) & LISP_CONSTANT)
        return lisp_fail("~S cannot be set: it is not a variable", argv[0]);
    return lisp_as_symbol(argv[0])->value = argv[1];
}

PRIMITIVE(p_set_symbol_function) /* symbol function */
{
    lisp old;

    SYMBOL(argv[0]);
    old = lisp_as_symbol(argv[0])->function;
    if (!lisp_is(argv[1], LISP_FUNCTION) || lisp_function_kind(argv[1]) == LISP_SPECIAL_OPERATOR)
        return lisp_wants("a function", argv[1]);
    if (argv[0] == NIL || (old != LISP_UNBOUND && lisp_function_kind(old) == LISP_SPECIAL_OPERATOR))
        return lisp_fail("~S cannot be given a function", argv[0]);
    return lisp_as_symbol(argv[0])->function = argv[1];
}

PRIMITIVE(p_set_symbol_plist) /* symbol list */
{
    SYMBOL(argv[0]);
    return lisp_as_symbol(argv[0])->plist = argv[1];
}

PRIMITIVE(p_make_symbol)
{
    const struct lisp_string *name = lisp_as_string(argv[0]);

    if (!lisp_is(argv[0], LISP_STRING))
        return lisp_wants("a string", argv[0]);
    return lisp_make_symbol(name->chars, lisp_length(name->header));
}

/* A symbol in no package, with a name that says which one it is: G and a
 * number that goes up. */
PRIMITIVE(p_gensym)
{
    static uint64_t counter;
    uint32_t name[24];
    char digits[20];
    unsigned length = 0, n = 0;

    (void)argv;
    name[length++] = 'G';
    for (uint64_t c = ++counter; c; c /= 10)
        digits[n++] = (char)('0' + c % 10);
    while (n)
        name[length++] = (uint8_t)digits[--n];
    return lisp_make_symbol(name, length);
}

/* Packages. Where a package is wanted its name will do, as a string or a
 * symbol. */
static lisp package_of(lisp x)
{
    lisp name, package;

    if (lisp_is(x, LISP_PACKAGE))
        return x;
    if (!(name = string_of(x)))
        return 0;
    package = lisp_find_package(lisp_as_string(name)->chars, lisp_length(lisp_as_string(name)->header));
    if (!package)
        lisp_fail("there is no package named ~A", name);
    return package;
}

PRIMITIVE(p_find_package)
{
    lisp name, package;

    if (lisp_is(argv[0], LISP_PACKAGE))
        return argv[0];
    if (!(name = string_of(argv[0])))
        return NIL;
    package = lisp_find_package(lisp_as_string(name)->chars, lisp_length(lisp_as_string(name)->header));
    return package ? package : NIL;
}

PRIMITIVE(p_package_name)
{
    lisp package = package_of(argv[0]);

    return package ? lisp_as_package(package)->name : NIL;
}

PRIMITIVE(p_make_package) /* name, a list of nicknames, a list of the packages it uses */
{
    for (unsigned i = 0; i < 2; i++)
        for (lisp names = i ? argv[1] : lisp_cons(argv[0], NIL); names != NIL; names = lisp_as_cons(names)->cdr) {
            const struct lisp_string *name;

            if (!lisp_is_cons(names) || !lisp_is(lisp_as_cons(names)->car, LISP_STRING))
                return lisp_wants("a list of strings for the names of a package", names);
            name = lisp_as_string(lisp_as_cons(names)->car);
            if (lisp_find_package(name->chars, lisp_length(name->header)))
                return lisp_fail("there is a package named ~A already", lisp_as_cons(names)->car);
        }
    for (lisp uses = argv[2]; uses != NIL; uses = lisp_as_cons(uses)->cdr)
        if (!lisp_is_cons(uses) || !lisp_is(lisp_as_cons(uses)->car, LISP_PACKAGE))
            return lisp_wants("a list of packages to use", uses);
    return lisp_new_package(argv[0], argv[1], argv[2]);
}

/* INTERN and FIND-SYMBOL: the symbol a name gives in a package, and how
 * it comes to be there. INTERN makes it when there is none. */
static lisp find_symbol(unsigned argc, lisp *argv, int make)
{
    static const char *const how[] = { NULL, "INTERNAL", "EXTERNAL", "INHERITED" };
    lisp package = argc > 1 ? package_of(argv[1]) : lisp_current_package(), symbol;
    const struct lisp_string *name = lisp_as_string(argv[0]);
    enum lisp_access access;

    if (!package)
        return NIL;
    if (!lisp_is(argv[0], LISP_STRING))
        return lisp_wants("a string", argv[0]);
    access = lisp_find_symbol(package, name->chars, lisp_length(name->header), &symbol);
    if (access == LISP_ABSENT)
        symbol = make ? lisp_intern(package, name->chars, lisp_length(name->header)) : NIL;
    lisp_values.count = 2;
    lisp_values.value[0] = symbol;
    lisp_values.value[1] = access == LISP_ABSENT ? NIL : lisp_symbol_in(lisp_roots.keyword, how[access], 1);
    return symbol;
}

PRIMITIVE(p_intern)
{
    return find_symbol(argc, argv, 1);
}

PRIMITIVE(p_find_symbol)
{
    return find_symbol(argc, argv, 0);
}

PRIMITIVE(p_export) /* a symbol or a list of them, and the package */
{
    lisp package = argc > 1 ? package_of(argv[1]) : lisp_current_package(), symbols = argv[0];

    if (!package)
        return NIL;
    while (symbols != NIL) {
        lisp symbol = lisp_is_cons(symbols) ? lisp_as_cons(symbols)->car : symbols;

        SYMBOL(symbol);
        if (!lisp_export(package, symbol))
            return lisp_fail("EXPORT: ~S is not a symbol of the package ~A's own", symbol,
                             lisp_as_package(package)->name);
        symbols = lisp_is_cons(symbols) ? lisp_as_cons(symbols)->cdr : NIL;
    }
    return T;
}

/* Structures, for DEFSTRUCT (lisp/boot.lisp). The type of one is the list
 * DEFSTRUCT made of its name and the names of its slots. */
PRIMITIVE(p_make_structure) /* (name slot...) and a value for each slot */
{
    struct lisp_structure *s;

    if (!lisp_is_cons(argv[0]))
        return lisp_wants("the name and the slots of a structure, in a list", argv[0]);
    s = lisp_alloc(LISP_STRUCTURE, argc - 1);
    s->type = argv[0];
    memcpy(s->slots, argv + 1, (argc - 1) * sizeof(lisp));
    return (lisp)(uintptr_t)s | LISP_TAG_OBJECT;
}

static int is_structure(lisp x, lisp name)
{
    return lisp_is(x, LISP_STRUCTURE) && lisp_as_cons(lisp_as_structure(x)->type)->car == name;
}

PRIMITIVE(p_structure_p) /* object name */
{
    return boolean(is_structure(argv[0], argv[1]));
}

PRIMITIVE(p_structure_ref) /* object name index */
{
    uint64_t i;

    if (!is_structure(argv[0], argv[1]))
        return lisp_fail("~S is not a structure of type ~S", argv[0], argv[1]);
    if (!index_in(argv[2], lisp_length(lisp_as_structure(argv[0])->header), &i))
        return NIL;
    return lisp_as_structure(argv[0])->slots[i];
}

PRIMITIVE(p_structure_set) /* object name index value */
{
    uint64_t i;

    if (!is_structure(argv[0], argv[1]))
        return lisp_fail("~S is not a structure of type ~S", argv[0], argv[1]);
    if (!index_in(argv[2], lisp_length(lisp_as_structure(argv[0])->header), &i))
        return NIL;
    return lisp_as_structure(argv[0])->slots[i] = argv[3];
}

PRIMITIVE(p_copy_structure)
{
    const struct lisp_structure *s = lisp_as_structure(argv[0]);
    struct lisp_structure *copy;

    if (!lisp_is(argv[0], LISP_STRUCTURE))
        return lisp_wants("a structure", argv[0]);
    copy = lisp_alloc(LISP_STRUCTURE, lisp_length(s->header));
    copy->type = s->type;
    memcpy(copy->slots, s->slots, lisp_length(s->header) * sizeof(lisp));
    return (lisp)(uintptr_t)copy | LISP_TAG_OBJECT;
}

/* Calling and evaluating. */
PRIMITIVE(p_funcall)
{
    return lisp_apply(argv[0], argc - 1, argv + 1);
}

/* (apply function argument... list): the items of the list are the last
 * arguments. They are spread on the value stack after the others. */
PRIMITIVE(p_apply)
{
    lisp *base = lisp_stack(), list = argv[argc - 1], value = NIL;

    for (unsigned i = 1; i + 1 < argc; i++)
        if (!lisp_push(argv[i]))
            goto out;
    for (; lisp_is_cons(list); list = lisp_as_cons(list)->cdr)
        if (!lisp_push(lisp_as_cons(list)->car))
            goto out;
    if (list != NIL)
        lisp_wants("a list for its last argument", argv[argc - 1]);
    else
        value = lisp_apply(argv[0], (unsigned)(lisp_stack() - base), base);
out:
    lisp_stack_drop(base);
    return value;
}

PRIMITIVE(p_values)
{
    if (argc > LISP_VALUES_MAX)
        return lisp_fail("VALUES with ~A values, and the most there can be is ~A", lisp_fixnum(argc),
                         lisp_fixnum(LISP_VALUES_MAX));
    lisp_values.count = argc;
    memcpy(lisp_values.value, argv, argc * sizeof(lisp));
    return argc ? argv[0] : NIL;
}

PRIMITIVE(p_values_list)
{
    unsigned n = 0;

    for (lisp list = argv[0]; lisp_is_cons(list); list = lisp_as_cons(list)->cdr) {
        if (n == LISP_VALUES_MAX)
            return lisp_fail("VALUES-LIST with more than ~A values", lisp_fixnum(LISP_VALUES_MAX));
        lisp_values.value[n++] = lisp_as_cons(list)->car;
    }
    lisp_values.count = n;
    return n ? lisp_values.value[0] : NIL;
}

/* The lists of a form, copied: the evaluator puts the expansion of a
 * macro call in the place of the call, and what EVAL is given is the
 * caller's own, to be left as it was. */
static lisp copy(lisp form)
{
    lisp head = NIL, tail = NIL;

    if (!lisp_is_cons(form) || lisp_out_of_stack())
        return form;
    for (; lisp_is_cons(form); form = lisp_as_cons(form)->cdr) {
        lisp c = lisp_cons(copy(lisp_as_cons(form)->car), NIL);

        if (tail == NIL)
            head = c;
        else
            lisp_as_cons(tail)->cdr = c;
        tail = c;
    }
    lisp_as_cons(tail)->cdr = form;
    return head;
}

PRIMITIVE(p_eval)
{
    lisp form = copy(argv[0]);

    return lisp_unwinding() ? NIL : lisp_eval(form, NIL);
}

PRIMITIVE(p_macroexpand_1)
{
    int expanded;
    lisp form = lisp_macroexpand_1(argv[0], &expanded);

    if (lisp_unwinding())
        return NIL;
    lisp_values.count = 2;
    lisp_values.value[0] = form;
    lisp_values.value[1] = boolean(expanded);
    return form;
}

PRIMITIVE(p_load)
{
    return lisp_load(argv[0]);
}

/* Writing. PRINT, PRIN1, PRINC and TERPRI write to the console. FORMAT
 * writes there for T and into a new string for NIL, and knows five
 * directives: ~A and ~S for an argument as PRINC and PRIN1 write it, ~D
 * for an integer, ~% for a new line, and ~~. */
PRIMITIVE(p_prin1)
{
    lisp_print(argv[0], lisp_console_put, NULL);
    return argv[0];
}

PRIMITIVE(p_princ)
{
    lisp_princ(argv[0], lisp_console_put, NULL);
    return argv[0];
}

PRIMITIVE(p_print)
{
    lisp_console_put(NULL, '\n');
    lisp_print(argv[0], lisp_console_put, NULL);
    lisp_console_put(NULL, ' ');
    return argv[0];
}

PRIMITIVE(p_terpri)
{
    (void)argv;
    lisp_console_put(NULL, '\n');
    return NIL;
}

/* Where FORMAT writes when it makes a string: the printer's bytes become
 * characters again, counted the first time through and stored the second. */
struct sink {
    uint32_t *chars;
    uint64_t length;
    uint32_t code;
    unsigned more; /* bytes of the character still to come */
};

static void sink_put(void *to, char c)
{
    struct sink *s = to;
    uint8_t byte = (uint8_t)c;

    if (byte < 0x80)
        s->code = byte, s->more = 0;
    else if (byte < 0xc0)
        s->code = s->code << 6 | (byte & 0x3f), s->more--;
    else if (byte < 0xe0)
        s->code = byte & 0x1f, s->more = 1;
    else if (byte < 0xf0)
        s->code = byte & 0x0f, s->more = 2;
    else
        s->code = byte & 0x07, s->more = 3;
    if (s->more)
        return;
    if (s->chars)
        s->chars[s->length] = s->code;
    s->length++;
}

/* Says 0 after failing. */
static int format(void (*put)(void *to, char c), void *to, lisp control, unsigned argc, const lisp *argv)
{
    const struct lisp_string *s = lisp_as_string(control);
    uint64_t length = lisp_length(s->header);
    unsigned used = 0;

    for (uint64_t i = 0; i < length; i++) {
        uint32_t c = s->chars[i];

        if (c != '~') {
            lisp_princ(lisp_character(c), put, to);
            continue;
        }
        c = ++i < length ? s->chars[i] : 0;
        if (c >= 'a' && c <= 'z')
            c -= 'a' - 'A';
        if (c == '%')
            put(to, '\n');
        else if (c == '~')
            put(to, '~');
        else if (c != 'A' && c != 'S' && c != 'D') {
            lisp_fail("FORMAT does not know the directive ~S in ~S", lisp_character(c), control);
            return 0;
        } else if (used == argc) {
            lisp_fail("FORMAT has no argument left for a directive of ~S", control);
            return 0;
        } else if (c == 'S')
            lisp_print(argv[used++], put, to);
        else
            lisp_princ(argv[used++], put, to);
    }
    return 1;
}

/* What FORMAT makes of a control string and its arguments, in a new
 * string; 0 after failing. */
static lisp format_string(lisp control, unsigned argc, const lisp *argv)
{
    struct sink sink = { NULL, 0, 0, 0 };
    lisp string;

    if (!format(sink_put, &sink, control, argc, argv))
        return 0;
    if (!lisp_heap_room(1 + (sink.length + 1) / 2)) {
        no_room();
        return 0;
    }
    string = lisp_make_string(NULL, sink.length);
    sink.chars = lisp_as_string(string)->chars;
    sink.length = 0;
    format(sink_put, &sink, control, argc, argv);
    return string;
}

PRIMITIVE(p_format) /* T or NIL, a control string, arguments */
{
    lisp string;

    if (!lisp_is(argv[1], LISP_STRING))
        return lisp_wants("a string to go by", argv[1]);
    if (argv[0] == T) {
        format(lisp_console_put, NULL, argv[1], argc - 2, argv + 2);
        return NIL;
    }
    if (argv[0] != NIL)
        return lisp_fail("FORMAT writes to the console, for T, or into a string, for NIL, and not to ~S", argv[0]);
    string = format_string(argv[1], argc - 2, argv + 2);
    return string ? string : NIL;
}

/* Conditions. One is a type, a symbol that DEFINE-CONDITION gave parents
 * and slots (lisp/boot.lisp), what it says to a person, and the values of
 * its slots. */
PRIMITIVE(p_make_condition) /* type, a string or NIL, the names of slots and their values in turn */
{
    SYMBOL(argv[0]);
    if (argv[1] != NIL && !lisp_is(argv[1], LISP_STRING))
        return lisp_wants("a string, or NIL, for what a condition says", argv[1]);
    return lisp_make_condition(argv[0], argv[1], argv[2]);
}

PRIMITIVE(p_condition_type)
{
    return lisp_is(argv[0], LISP_CONDITION) ? lisp_as_condition(argv[0])->type : lisp_wants("a condition", argv[0]);
}

PRIMITIVE(p_condition_slots)
{
    return lisp_is(argv[0], LISP_CONDITION) ? lisp_as_condition(argv[0])->slots : lisp_wants("a condition", argv[0]);
}

/* What ERROR, SIGNAL and WARN make of their arguments, or 0 after failing.
 * A condition is itself. A string is the control string of a condition of
 * the simple type, and what FORMAT makes of it and of the arguments is
 * what the condition says. The name of a type goes to MAKE-CONDITION
 * (lisp/boot.lisp) with the arguments, which name slots and give their
 * values. */
static lisp condition_of(unsigned argc, lisp *argv, const char *simple)
{
    lisp cl = lisp_roots.common_lisp, datum = argv[0], said, arguments = NIL;

    if (lisp_is(datum, LISP_CONDITION) && argc == 1)
        return datum;
    if (lisp_is(datum, LISP_STRING)) {
        if (!(said = format_string(datum, argc - 1, argv + 1)))
            return 0;
        while (--argc)
            arguments = lisp_cons(argv[argc], arguments);
        arguments = lisp_cons(lisp_symbol_in(cl, "FORMAT-ARGUMENTS", 0), lisp_cons(arguments, NIL));
        return lisp_make_condition(lisp_symbol_in(cl, simple, 1), said,
                                   lisp_cons(lisp_symbol_in(cl, "FORMAT-CONTROL", 0), lisp_cons(datum, arguments)));
    }
    if (lisp_is_symbol(datum) && datum != NIL) {
        datum = lisp_apply(lisp_symbol_in(cl, "MAKE-CONDITION", 1), argc, argv);
        return lisp_unwinding() ? 0 : datum;
    }
    lisp_fail("~S is not a condition, nor the name of a type of one, nor a string to make one of", datum);
    return 0;
}

/* (error datum argument...): a condition that somebody has to handle. With
 * no HANDLER-CASE for it, it goes to the top level. */
PRIMITIVE(p_error)
{
    lisp condition = condition_of(argc, argv, "SIMPLE-ERROR");

    return condition ? lisp_error(condition) : NIL;
}

/* (signal datum argument...): a condition for whoever wants it. With no
 * HANDLER-CASE for it, nothing happens. */
PRIMITIVE(p_signal)
{
    lisp condition = condition_of(argc, argv, "SIMPLE-CONDITION");

    if (condition)
        lisp_signal(condition);
    return NIL;
}

/* (warn datum argument...): the same, except that with no HANDLER-CASE
 * for it the console says what the warning is. */
PRIMITIVE(p_warn)
{
    lisp condition = condition_of(argc, argv, "SIMPLE-WARNING");

    if (condition && !lisp_signal(condition)) {
        lisp_fresh_line();
        for (const char *s = "warning: "; *s; s++)
            lisp_console_put(NULL, *s);
        lisp_princ(condition, lisp_console_put, NULL);
        lisp_console_put(NULL, '\n');
    }
    return NIL;
}

/* The heap. ROOM says how full it is. The three after it are for testing
 * the collector, and internal: one collection now, a collection at every
 * nth safe point, and the texts of the boot's self-test evaluated again. */
PRIMITIVE(p_room)
{
    struct lisp_heap heap;

    (void)argv;
    lisp_heap_state(&heap);
    lisp_fresh_line();
    kprintf("the heap is %llu KiB long, with %llu KiB of it free, after %llu collections\n", heap.size >> 10,
            heap.free >> 10, heap.collections);
    return NIL;
}

PRIMITIVE(p_collect)
{
    (void)argv;
    return lisp_fixnum((int64_t)lisp_collect());
}

PRIMITIVE(p_collect_every)
{
    INTEGER(argv[0]);
    if (lisp_fixnum_value(argv[0]) < 0)
        return lisp_wants("an integer that is not negative", argv[0]);
    return lisp_fixnum((int64_t)lisp_collect_every((uint64_t)lisp_fixnum_value(argv[0])));
}

PRIMITIVE(p_self_test)
{
    (void)argv;
    return lisp_fixnum(lisp_eval_texts());
}

/* Time, as far as there is any: the ticks since the timer was started. */
PRIMITIVE(p_get_internal_real_time)
{
    (void)argv;
    return lisp_fixnum((int64_t)timer_ticks());
}

const struct lisp_primitive lisp_primitives[] = {
    { "CONS", p_cons, 2, 2 },
    { "CAR", p_car, 1, 1 },
    { "CDR", p_cdr, 1, 1 },
    { "RPLACA", p_rplaca, 2, 2 },
    { "RPLACD", p_rplacd, 2, 2 },
    { "LIST", p_list, 0, LISP_MANY },
    { "LIST*", p_list_star, 1, LISP_MANY },
    { "APPEND", p_append, 0, LISP_MANY },
    { "LENGTH", p_length, 1, 1 },
    { "EQ", p_eq, 2, 2 },
    { "EQL", p_eq, 2, 2 },
    { "EQUAL", p_equal, 2, 2 },
    { "NULL", p_null, 1, 1 },
    { "NOT", p_null, 1, 1 },
    { "CONSP", p_consp, 1, 1 },
    { "ATOM", p_atom, 1, 1 },
    { "LISTP", p_listp, 1, 1 },
    { "SYMBOLP", p_symbolp, 1, 1 },
    { "KEYWORDP", p_keywordp, 1, 1 },
    { "INTEGERP", p_integerp, 1, 1 },
    { "NUMBERP", p_integerp, 1, 1 },
    { "CHARACTERP", p_characterp, 1, 1 },
    { "STRINGP", p_stringp, 1, 1 },
    { "VECTORP", p_vectorp, 1, 1 },
    { "FUNCTIONP", p_functionp, 1, 1 },
    { "PACKAGEP", p_packagep, 1, 1 },
    { "+", p_add, 0, LISP_MANY },
    { "-", p_subtract, 1, LISP_MANY },
    { "*", p_multiply, 0, LISP_MANY },
    { "/", p_divide, 1, LISP_MANY },
    { "FLOOR", p_floor, 1, 2 },
    { "TRUNCATE", p_truncate, 1, 2 },
    { "MOD", p_mod, 2, 2 },
    { "REM", p_rem, 2, 2 },
    { "1+", p_add_one, 1, 1 },
    { "1-", p_subtract_one, 1, 1 },
    { "=", p_same, 1, LISP_MANY },
    { "/=", p_different, 1, LISP_MANY },
    { "<", p_less, 1, LISP_MANY },
    { ">", p_greater, 1, LISP_MANY },
    { "<=", p_at_most, 1, LISP_MANY },
    { ">=", p_at_least, 1, LISP_MANY },
    { "LOGAND", p_logand, 0, LISP_MANY },
    { "LOGIOR", p_logior, 0, LISP_MANY },
    { "LOGXOR", p_logxor, 0, LISP_MANY },
    { "LOGNOT", p_lognot, 1, 1 },
    { "ASH", p_ash, 2, 2 },
    { "CHAR-CODE", p_char_code, 1, 1 },
    { "CODE-CHAR", p_code_char, 1, 1 },
    { "STRING", p_string, 1, 1 },
    { "STRING=", p_string_same, 2, 2 },
    { "%STRING-APPEND", p_string_append, 0, LISP_MANY },
    { "CHAR", p_char, 2, 2 },
    { "SCHAR", p_char, 2, 2 },
    { "%SET-CHAR", p_set_char, 3, 3 },
    { "AREF", p_aref, 2, 2 },
    { "SVREF", p_aref, 2, 2 },
    { "%SET-AREF", p_set_aref, 3, 3 },
    { "VECTOR", p_vector, 0, LISP_MANY },
    { "%MAKE-VECTOR", p_make_vector, 2, 2 },
    { "SYMBOL-NAME", p_symbol_name, 1, 1 },
    { "SYMBOL-PACKAGE", p_symbol_package, 1, 1 },
    { "SYMBOL-VALUE", p_symbol_value, 1, 1 },
    { "SYMBOL-FUNCTION", p_symbol_function, 1, 1 },
    { "SYMBOL-PLIST", p_symbol_plist, 1, 1 },
    { "BOUNDP", p_boundp, 1, 1 },
    { "FBOUNDP", p_fboundp, 1, 1 },
    { "SET", p_set, 2, 2 },
    { "%SET-SYMBOL-FUNCTION", p_set_symbol_function, 2, 2 },
    { "%SET-SYMBOL-PLIST", p_set_symbol_plist, 2, 2 },
    { "MAKE-SYMBOL", p_make_symbol, 1, 1 },
    { "GENSYM", p_gensym, 0, 0 },
    { "FIND-PACKAGE", p_find_package, 1, 1 },
    { "PACKAGE-NAME", p_package_name, 1, 1 },
    { "%MAKE-PACKAGE", p_make_package, 3, 3 },
    { "INTERN", p_intern, 1, 2 },
    { "FIND-SYMBOL", p_find_symbol, 1, 2 },
    { "EXPORT", p_export, 1, 2 },
    { "%MAKE-STRUCTURE", p_make_structure, 1, LISP_MANY },
    { "%STRUCTURE-P", p_structure_p, 2, 2 },
    { "%STRUCTURE-REF", p_structure_ref, 3, 3 },
    { "%STRUCTURE-SET", p_structure_set, 4, 4 },
    { "COPY-STRUCTURE", p_copy_structure, 1, 1 },
    { "FUNCALL", p_funcall, 1, LISP_MANY },
    { "APPLY", p_apply, 2, LISP_MANY },
    { "VALUES", p_values, 0, LISP_MANY },
    { "VALUES-LIST", p_values_list, 1, 1 },
    { "EVAL", p_eval, 1, 1 },
    { "MACROEXPAND-1", p_macroexpand_1, 1, 1 },
    { "LOAD", p_load, 1, 1 },
    { "PRIN1", p_prin1, 1, 1 },
    { "PRINC", p_princ, 1, 1 },
    { "PRINT", p_print, 1, 1 },
    { "TERPRI", p_terpri, 0, 0 },
    { "FORMAT", p_format, 2, LISP_MANY },
    { "ERROR", p_error, 1, LISP_MANY },
    { "SIGNAL", p_signal, 1, LISP_MANY },
    { "WARN", p_warn, 1, LISP_MANY },
    { "%MAKE-CONDITION", p_make_condition, 3, 3 },
    { "%CONDITION-TYPE", p_condition_type, 1, 1 },
    { "%CONDITION-SLOTS", p_condition_slots, 1, 1 },
    { "ROOM", p_room, 0, 1 },
    { "%COLLECT", p_collect, 0, 0 },
    { "%COLLECT-EVERY", p_collect_every, 1, 1 },
    { "%SELF-TEST", p_self_test, 0, 0 },
    /* threads, locks and events (thread.c) */
    { "SLEEP", lisp_p_sleep, 1, 1 },
    { "CLARA:%MAKE-THREAD", lisp_p_make_thread, 2, 2 },
    { "CLARA:CURRENT-THREAD", lisp_p_current_thread, 0, 0 },
    { "CLARA:THREADP", lisp_p_threadp, 1, 1 },
    { "CLARA:THREAD-NAME", lisp_p_thread_name, 1, 1 },
    { "CLARA:THREAD-ALIVE-P", lisp_p_thread_alive_p, 1, 1 },
    { "CLARA:ALL-THREADS", lisp_p_all_threads, 0, 0 },
    { "CLARA:JOIN-THREAD", lisp_p_join_thread, 1, 1 },
    { "CLARA:DESTROY-THREAD", lisp_p_destroy_thread, 1, 1 },
    { "CLARA:THREAD-YIELD", lisp_p_thread_yield, 0, 0 },
    { "CLARA:MAKE-LOCK", lisp_p_make_lock, 0, 1 },
    { "CLARA:ACQUIRE-LOCK", lisp_p_acquire_lock, 1, 1 },
    { "CLARA:RELEASE-LOCK", lisp_p_release_lock, 1, 1 },
    { "CLARA:MAKE-EVENT", lisp_p_make_event, 0, 1 },
    { "CLARA:SIGNAL-EVENT", lisp_p_signal_event, 1, 2 },
    { "CLARA:WAIT-EVENT", lisp_p_wait_event, 1, 2 },
    { "GET-INTERNAL-REAL-TIME", p_get_internal_real_time, 0, 0 },
    /* what only a driver should touch (unsafe.c) */
    { "CLARA.UNSAFE:MEMORY-8", lisp_p_memory_8, 1, 1 },
    { "CLARA.UNSAFE:MEMORY-16", lisp_p_memory_16, 1, 1 },
    { "CLARA.UNSAFE:MEMORY-32", lisp_p_memory_32, 1, 1 },
    { "CLARA.UNSAFE:MEMORY-64", lisp_p_memory_64, 1, 1 },
    { "CLARA.UNSAFE:%SET-MEMORY-8", lisp_p_set_memory_8, 2, 2 },
    { "CLARA.UNSAFE:%SET-MEMORY-16", lisp_p_set_memory_16, 2, 2 },
    { "CLARA.UNSAFE:%SET-MEMORY-32", lisp_p_set_memory_32, 2, 2 },
    { "CLARA.UNSAFE:%SET-MEMORY-64", lisp_p_set_memory_64, 2, 2 },
    { "CLARA.UNSAFE:FILL-MEMORY-32", lisp_p_fill_memory_32, 3, 3 },
    { "CLARA.UNSAFE:COPY-MEMORY", lisp_p_copy_memory, 3, 3 },
    { "CLARA.UNSAFE:EXPAND-BITS-32", lisp_p_expand_bits_32, 8, 8 },
    { "CLARA.UNSAFE:ALLOCATE-MEMORY", lisp_p_allocate_memory, 1, 1 },
    { "CLARA.UNSAFE:FREE-MEMORY", lisp_p_free_memory, 2, 2 },
    { "CLARA.UNSAFE:PORT-8", lisp_p_port_8, 1, 1 },
    { "CLARA.UNSAFE:PORT-16", lisp_p_port_16, 1, 1 },
    { "CLARA.UNSAFE:PORT-32", lisp_p_port_32, 1, 1 },
    { "CLARA.UNSAFE:%SET-PORT-8", lisp_p_set_port_8, 2, 2 },
    { "CLARA.UNSAFE:%SET-PORT-16", lisp_p_set_port_16, 2, 2 },
    { "CLARA.UNSAFE:%SET-PORT-32", lisp_p_set_port_32, 2, 2 },
    { "CLARA.UNSAFE:INTERRUPT-EVENT", lisp_p_interrupt_event, 1, 1 },
    { "CLARA.UNSAFE:FRAMEBUFFER", lisp_p_framebuffer, 0, 0 },
    { "CLARA.UNSAFE:SERIAL-DEVICE", lisp_p_serial_device, 0, 0 },
    { "CLARA.UNSAFE:SERIAL-BYTE", lisp_p_serial_byte, 0, 0 },
};
const unsigned lisp_primitive_count = sizeof lisp_primitives / sizeof lisp_primitives[0];
