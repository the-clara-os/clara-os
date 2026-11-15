/* The printer: an object as text. lisp_print writes it so that the reader
 * makes the same object of it again where that can be done. A symbol gets
 * its package when the name alone would not find it from the package that
 * names are being read in, and bars when its name would not read back as
 * it is; a string gets its quotes; (QUOTE X) comes out as 'X, and what the
 * reader made of a backquote comes out as the backquote. A package, a
 * function, a structure and a condition have no text that reads back, and
 * print as #<PACKAGE "NAME">, #<FUNCTION NAME>, #S(NAME :SLOT value) and
 * #<TYPE "what it says">. lisp_princ writes for a person: no quotes, no
 * bars, no package, and of a condition what it says and no more.
 *
 * Lists nest by recursion in C here too: below LISP_DEPTH a list is
 * printed as #. Nothing looks out for a list that leads back into itself,
 * which RPLACD can make; the printer stops after LIMIT objects with three
 * dots, so it ends whatever it is given. */
#include "lisp.h"

enum { LIMIT = 65536 };

struct printer {
    void (*put)(void *to, char c);
    void *to;
    int escape;    /* lisp_print: write what reads back */
    unsigned depth;
    unsigned left; /* objects it may still print */
};

static void print_object(struct printer *p, lisp x);

/* One character, as UTF-8. */
static void put_char(struct printer *p, uint32_t c)
{
    if (c < 0x80)
        p->put(p->to, (char)c);
    else {
        unsigned more = c < 0x800 ? 1 : c < 0x10000 ? 2 : 3;

        p->put(p->to, (char)(uint8_t)(0xf0 << (3 - more) | c >> (6 * more))); /* 110x xxxx, 1110 xxxx, 1111 0xxx */
        while (more--)
            p->put(p->to, (char)(0x80 | ((c >> (6 * more)) & 0x3f)));
    }
}

static void put_text(struct printer *p, const char *s)
{
    while (*s)
        put_char(p, (uint8_t)*s++);
}

static void put_number(struct printer *p, uint64_t n, unsigned base)
{
    char digits[24];
    int i = 0;

    do
        digits[i++] = "0123456789ABCDEF"[n % base];
    while (n /= base);
    while (i--)
        put_char(p, (uint8_t)digits[i]);
}

/* The list, or the vector, one level further in. */
static void print_nested(struct printer *p, lisp x)
{
    if (p->depth == LISP_DEPTH && (lisp_is_cons(x) || lisp_is(x, LISP_VECTOR))) {
        put_char(p, '#');
        return;
    }
    p->depth++;
    print_object(p, x);
    p->depth--;
}

static int is_one_of(uint32_t c, const char *these)
{
    for (; *these; these++)
        if (c == (uint8_t)*these)
            return 1;
    return 0;
}

/* Would the reader make something else of this name: another name, a
 * number, or more than one thing? */
static int needs_bars(const uint32_t *s, uint64_t length)
{
    uint64_t dots = 0;

    if (!length || s[0] == '#')
        return 1;
    for (uint64_t i = 0; i < length; i++) {
        if (s[i] <= ' ' || s[i] == 0x7f || (s[i] >= 'a' && s[i] <= 'z') || is_one_of(s[i], "()'\";`,|\\:"))
            return 1;
        dots += s[i] == '.';
    }
    return dots == length || lisp_number_syntax(s, length) != LISP_NOT_A_NUMBER;
}

/* The name of a symbol or of a package, between bars when it needs them. */
static void print_name(struct printer *p, lisp string)
{
    const struct lisp_string *s = lisp_as_string(string);
    uint64_t length = lisp_length(s->header);
    int bars = p->escape && needs_bars(s->chars, length);

    if (bars)
        put_char(p, '|');
    for (uint64_t i = 0; i < length; i++) {
        if (bars && (s->chars[i] == '|' || s->chars[i] == '\\'))
            put_char(p, '\\');
        put_char(p, s->chars[i]);
    }
    if (bars)
        put_char(p, '|');
}

/* A symbol that its name finds from the current package is printed as the
 * name alone. Otherwise its package comes first, with one colon when the
 * symbol is external there and two when it is not. A keyword has the
 * colon and no package, and a symbol in no package has #: instead. */
static void print_symbol(struct printer *p, lisp x)
{
    const struct lisp_symbol *symbol = lisp_as_symbol(x);
    const struct lisp_string *name = lisp_as_string(symbol->name);
    uint64_t length = lisp_length(name->header);
    lisp found;

    if (!p->escape)
        ;
    else if (symbol->package == lisp_roots.keyword)
        put_char(p, ':');
    else if (symbol->package == LISP_NIL)
        put_text(p, "#:");
    else if (lisp_find_symbol(lisp_current_package(), name->chars, length, &found) == LISP_ABSENT || found != x) {
        print_name(p, lisp_as_package(symbol->package)->name);
        put_text(p, lisp_find_symbol(symbol->package, name->chars, length, &found) == LISP_EXTERNAL ? ":" : "::");
    }
    print_name(p, symbol->name);
}

static void print_character(struct printer *p, uint32_t code)
{
    put_text(p, "#\\");
    for (const struct lisp_character_name *n = lisp_character_names; n->name; n++)
        if (n->code == code) {
            put_text(p, n->name);
            return;
        }
    if (code < ' ' || (code >= 0x7f && code < 0xa0)) {
        /* A control character with no name. */
        put_text(p, "U+");
        put_number(p, code, 16);
    } else
        put_char(p, code);
}

/* What the reader's shorthand for (operator form) is, if it has one. */
static const char *shorthand(lisp operator)
{
    return operator == lisp_roots.quote        ? "'"
           : operator == lisp_roots.function   ? "#'"
           : operator == lisp_roots.quasiquote ? "`"
           : operator == lisp_roots.unquote    ? ","
           : operator == lisp_roots.splice     ? ",@"
                                               : NULL;
}

static void print_list(struct printer *p, lisp x)
{
    const struct lisp_cons *c = lisp_as_cons(x);

    if (shorthand(c->car) && lisp_is_cons(c->cdr) && lisp_as_cons(c->cdr)->cdr == LISP_NIL) {
        put_text(p, shorthand(c->car));
        print_nested(p, lisp_as_cons(c->cdr)->car);
        return;
    }
    put_char(p, '(');
    for (;;) {
        print_nested(p, c->car);
        /* (a . ,b) is the list (a unquote b), and is printed the way it was written. */
        if (!lisp_is_cons(c->cdr) || !p->left ||
            (lisp_as_cons(c->cdr)->car == lisp_roots.unquote && lisp_is_cons(lisp_as_cons(c->cdr)->cdr) &&
             lisp_as_cons(lisp_as_cons(c->cdr)->cdr)->cdr == LISP_NIL))
            break;
        c = lisp_as_cons(c->cdr);
        put_char(p, ' ');
    }
    if (c->cdr != LISP_NIL && p->left) {
        put_text(p, " . ");
        print_object(p, c->cdr);
    }
    put_char(p, ')');
}

static void print_function(struct printer *p, lisp x)
{
    static const char *const kinds[] = { "FUNCTION", "SPECIAL-OPERATOR", "FUNCTION", "MACRO" };
    const struct lisp_function *f = lisp_as_function(x);

    put_text(p, "#<");
    put_text(p, kinds[lisp_function_kind(x)]);
    put_char(p, ' ');
    if (f->name != LISP_NIL)
        print_object(p, f->name);
    else {
        put_text(p, "(LAMBDA ");
        print_nested(p, lisp_is_cons(f->code) ? lisp_as_cons(f->code)->car : LISP_NIL);
        put_char(p, ')');
    }
    put_char(p, '>');
}

/* #S(NAME :SLOT value ...): the names come from the structure's type. */
static void print_structure(struct printer *p, lisp x)
{
    const struct lisp_structure *s = lisp_as_structure(x);
    lisp names = s->type;

    put_text(p, "#S(");
    print_object(p, lisp_as_cons(names)->car);
    for (uint64_t i = 0; i < lisp_length(s->header) && p->left; i++) {
        names = lisp_is_cons(names) ? lisp_as_cons(names)->cdr : LISP_NIL;
        put_text(p, " :");
        if (lisp_is_cons(names) && lisp_is_symbol(lisp_as_cons(names)->car))
            print_name(p, lisp_as_symbol(lisp_as_cons(names)->car)->name);
        put_char(p, ' ');
        print_nested(p, s->slots[i]);
    }
    put_char(p, ')');
}

/* For a person a condition is what it says. Otherwise it is its type and
 * what it says, and one that says nothing shows its slots. */
static void print_condition(struct printer *p, lisp x)
{
    const struct lisp_condition *c = lisp_as_condition(x);

    if (!p->escape && c->message != LISP_NIL) {
        print_object(p, c->message);
        return;
    }
    put_text(p, "#<");
    print_object(p, c->type);
    if (c->message != LISP_NIL) {
        put_char(p, ' ');
        print_object(p, c->message);
    } else
        for (lisp s = c->slots; lisp_is_cons(s) && lisp_is_cons(lisp_as_cons(s)->cdr) && p->left;
             s = lisp_as_cons(lisp_as_cons(s)->cdr)->cdr) {
            put_text(p, " :");
            if (lisp_is_symbol(lisp_as_cons(s)->car))
                print_name(p, lisp_as_symbol(lisp_as_cons(s)->car)->name);
            put_char(p, ' ');
            print_nested(p, lisp_as_cons(lisp_as_cons(s)->cdr)->car);
        }
    put_char(p, '>');
}

static void print_object(struct printer *p, lisp x)
{
    if (!p->left)
        return;
    if (!--p->left) {
        put_text(p, "...");
        return;
    }
    if (lisp_is_fixnum(x)) {
        int64_t n = lisp_fixnum_value(x);

        if (n < 0)
            put_char(p, '-');
        put_number(p, n < 0 ? -(uint64_t)n : (uint64_t)n, 10);
    } else if (lisp_is_character(x)) {
        if (p->escape)
            print_character(p, lisp_character_code(x));
        else
            put_char(p, lisp_character_code(x));
    } else if (lisp_is_symbol(x))
        print_symbol(p, x);
    else if (lisp_is_cons(x))
        print_list(p, x);
    else if (lisp_is(x, LISP_STRING)) {
        const struct lisp_string *s = lisp_as_string(x);

        if (p->escape)
            put_char(p, '"');
        for (uint64_t i = 0; i < lisp_length(s->header); i++) {
            if (p->escape && (s->chars[i] == '"' || s->chars[i] == '\\'))
                put_char(p, '\\');
            put_char(p, s->chars[i]);
        }
        if (p->escape)
            put_char(p, '"');
    } else if (lisp_is(x, LISP_VECTOR)) {
        const struct lisp_vector *v = lisp_as_vector(x);

        put_text(p, "#(");
        for (uint64_t i = 0; i < lisp_length(v->header) && p->left; i++) {
            if (i)
                put_char(p, ' ');
            print_nested(p, v->items[i]);
        }
        put_char(p, ')');
    } else if (lisp_is(x, LISP_PACKAGE)) {
        put_text(p, "#<PACKAGE ");
        p->escape++;
        print_object(p, lisp_as_package(x)->name);
        p->escape--;
        put_char(p, '>');
    } else if (lisp_is(x, LISP_FUNCTION))
        print_function(p, x);
    else if (lisp_is(x, LISP_STRUCTURE))
        print_structure(p, x);
    else if (lisp_is(x, LISP_CONDITION))
        print_condition(p, x);
    else if (x == LISP_UNBOUND)
        put_text(p, "#<unbound>");
    else {
        put_text(p, "#<unknown ");
        put_number(p, x, 16);
        put_char(p, '>');
    }
}

void lisp_print(lisp x, void (*put)(void *to, char c), void *to)
{
    struct printer p = { put, to, 1, 0, LIMIT };

    print_nested(&p, x);
}

void lisp_princ(lisp x, void (*put)(void *to, char c), void *to)
{
    struct printer p = { put, to, 0, 0, LIMIT };

    print_nested(&p, x);
}
