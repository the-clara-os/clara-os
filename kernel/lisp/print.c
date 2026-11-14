/* The printer: an object as text, written so that the reader makes the
 * same object of it again where that can be done. A symbol gets its
 * package when the name alone would not find it from the package that
 * names are being read in, and bars when its name would not read back as
 * it is; a string gets its quotes; (QUOTE X) comes out as 'X. A package
 * has no text that reads back, and prints as #<PACKAGE "NAME">.
 *
 * Lists nest by recursion in C here too: below LISP_DEPTH a list is
 * printed as #. Nothing looks out for a list that leads back into itself;
 * the reader cannot make one. */
#include "lisp.h"

struct printer {
    void (*put)(void *to, char c);
    void *to;
    unsigned depth;
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
    int bars = needs_bars(s->chars, length);

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

    if (symbol->package == lisp_roots.keyword)
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

static void print_list(struct printer *p, lisp x)
{
    const struct lisp_cons *c = lisp_as_cons(x);

    if ((c->car == lisp_roots.quote || c->car == lisp_roots.function) && lisp_is_cons(c->cdr) &&
        lisp_as_cons(c->cdr)->cdr == LISP_NIL) {
        put_text(p, c->car == lisp_roots.quote ? "'" : "#'");
        print_nested(p, lisp_as_cons(c->cdr)->car);
        return;
    }
    put_char(p, '(');
    for (;;) {
        print_nested(p, c->car);
        if (!lisp_is_cons(c->cdr))
            break;
        c = lisp_as_cons(c->cdr);
        put_char(p, ' ');
    }
    if (c->cdr != LISP_NIL) {
        put_text(p, " . ");
        print_object(p, c->cdr);
    }
    put_char(p, ')');
}

static void print_object(struct printer *p, lisp x)
{
    if (lisp_is_fixnum(x)) {
        int64_t n = lisp_fixnum_value(x);

        if (n < 0)
            put_char(p, '-');
        put_number(p, n < 0 ? -(uint64_t)n : (uint64_t)n, 10);
    } else if (lisp_is_character(x))
        print_character(p, lisp_character_code(x));
    else if (lisp_is_symbol(x))
        print_symbol(p, x);
    else if (lisp_is_cons(x))
        print_list(p, x);
    else if (lisp_is(x, LISP_STRING)) {
        const struct lisp_string *s = lisp_as_string(x);

        put_char(p, '"');
        for (uint64_t i = 0; i < lisp_length(s->header); i++) {
            if (s->chars[i] == '"' || s->chars[i] == '\\')
                put_char(p, '\\');
            put_char(p, s->chars[i]);
        }
        put_char(p, '"');
    } else if (lisp_is(x, LISP_VECTOR)) {
        const struct lisp_vector *v = lisp_as_vector(x);

        put_text(p, "#(");
        for (uint64_t i = 0; i < lisp_length(v->header); i++) {
            if (i)
                put_char(p, ' ');
            print_nested(p, v->items[i]);
        }
        put_char(p, ')');
    } else if (lisp_is(x, LISP_PACKAGE)) {
        put_text(p, "#<PACKAGE ");
        print_object(p, lisp_as_package(x)->name);
        put_char(p, '>');
    } else if (x == LISP_UNBOUND)
        put_text(p, "#<unbound>");
    else {
        put_text(p, "#<unknown ");
        put_number(p, x, 16);
        put_char(p, '>');
    }
}

void lisp_print(lisp x, void (*put)(void *to, char c), void *to)
{
    struct printer p = { put, to, 0 };

    print_nested(&p, x);
}
