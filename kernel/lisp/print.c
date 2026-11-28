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
 * A structure of a type whose name has %PRINTED on its property list is
 * not the printer's to write: it is an instance of a class, or of a type
 * that a method of PRINT-OBJECT was written for (lisp/clos.lisp), and what
 * it looks like is for Lisp to say. The printer cannot call Lisp in the
 * middle of its work, which is done twice over, once to count and once to
 * store. So lisp_print_asking is told how far things have come: with
 * `found` it leaves such a structure out and notes it there; with `texts`
 * it writes the next text of that list in its place, which is what Lisp
 * said when the caller asked (kernel/lisp/builtin.c). With neither, as
 * lisp_print and lisp_princ are, it writes the name of the type and the
 * structure's address between #< and >, #<STANDARD-OBJECT {40000012A458}>,
 * which is all that can be said where nobody can be asked: in what an
 * error of the substrate's says, for one. The address is what Lisp writes
 * for an instance too, so it says which one is meant.
 *
 * A function that carries such a structure (lisp.h) is left to Lisp in
 * the same way: a generic function is one, and is written by its method
 * of PRINT-OBJECT like an instance. Where nobody can be asked it is the
 * function that it also is, #<FUNCTION NAME>.
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
    struct lisp_printing *ask; /* what to do about a structure that Lisp writes, or NULL */
    lisp printed;  /* the symbol %PRINTED, once it has been looked for */
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

/* Is this a structure that Lisp writes? Its type's name says so, with
 * %PRINTED on its property list. */
static int written_by_lisp(struct printer *p, lisp name)
{
    if (!lisp_is_symbol(name))
        return 0;
    if (!p->printed)
        p->printed = lisp_symbol_in(lisp_roots.common_lisp, "%PRINTED", 0);
    for (lisp l = lisp_as_symbol(name)->plist; lisp_is_cons(l) && lisp_is_cons(lisp_as_cons(l)->cdr);
         l = lisp_as_cons(lisp_as_cons(l)->cdr)->cdr)
        if (lisp_as_cons(l)->car == p->printed)
            return lisp_as_cons(lisp_as_cons(l)->cdr)->car != LISP_NIL;
    return 0;
}

/* An object that Lisp writes: with `found` it is noted and nothing of it
 * is written this time, and with `texts` what Lisp said of it is written
 * in its place. Says 0 when it is still the printer's to write, in words
 * of its own: nobody was asked, or nothing was said. */
static int left_to_lisp(struct printer *p, lisp x)
{
    lisp text = LISP_NIL;

    if (p->ask && p->ask->found) {
        *p->ask->found = lisp_cons(x, *p->ask->found); /* to be asked for */
        return 1;
    }
    if (p->ask && p->ask->texts && lisp_is_cons(*p->ask->texts)) {
        text = lisp_as_cons(*p->ask->texts)->car;
        *p->ask->texts = lisp_as_cons(*p->ask->texts)->cdr;
    }
    if (!lisp_is(text, LISP_STRING))
        return 0;
    for (uint64_t i = 0; i < lisp_length(lisp_as_string(text)->header); i++) /* what Lisp said */
        put_char(p, lisp_as_string(text)->chars[i]);
    return 1;
}

/* A function that carries a structure which Lisp writes is Lisp's to
 * write as well: a generic function is one. Where nobody can be asked it
 * is written as the function that it also is. */
static void print_function(struct printer *p, lisp x)
{
    static const char *const kinds[] = { "FUNCTION", "SPECIAL-OPERATOR", "FUNCTION", "MACRO", "FUNCTION" };
    const struct lisp_function *f = lisp_as_function(x);
    lisp carried = lisp_carried(x);

    if (carried && lisp_is_cons(lisp_as_structure(carried)->type) &&
        written_by_lisp(p, lisp_as_cons(lisp_as_structure(carried)->type)->car) && left_to_lisp(p, x))
        return;
    put_text(p, "#<");
    put_text(p, kinds[lisp_function_kind(x)]);
    put_char(p, ' ');
    if (f->name != LISP_NIL)
        print_object(p, f->name);
    else {
        put_text(p, "(LAMBDA ");
        print_nested(p, lisp_is_cons(f->code)                     ? lisp_as_cons(f->code)->car
                        : lisp_function_kind(x) == LISP_COMPILED ? lisp_as_vector(f->code)->items[LISP_CODE_LAMBDA_LIST]
                                                                 : LISP_NIL);
        put_char(p, ')');
    }
    put_char(p, '>');
}

/* #S(NAME :SLOT value ...): the names come from the structure's type. */
static void print_structure(struct printer *p, lisp x)
{
    const struct lisp_structure *s = lisp_as_structure(x);
    lisp names = s->type;

    if (lisp_is_cons(names) && written_by_lisp(p, lisp_as_cons(names)->car)) {
        if (!left_to_lisp(p, x)) { /* its type, and its address as %ADDRESS gives it */
            put_text(p, "#<");
            print_name(p, lisp_as_symbol(lisp_as_cons(names)->car)->name);
            put_text(p, " {");
            put_number(p, x & ~LISP_TAG_MASK, 16);
            put_text(p, "}>");
        }
        return;
    }
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

/* A thread, a lock or an event: what it is, and its name if it has one. */
static void print_named(struct printer *p, const char *type, lisp name)
{
    put_text(p, "#<");
    put_text(p, type);
    if (name != LISP_NIL) {
        put_char(p, ' ');
        p->escape++;
        print_object(p, name);
        p->escape--;
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
    else if (lisp_is(x, LISP_THREAD))
        print_named(p, "THREAD", lisp_as_thread(x)->name);
    else if (lisp_is(x, LISP_LOCK))
        print_named(p, "LOCK", lisp_as_lock(x)->name);
    else if (lisp_is(x, LISP_EVENT))
        print_named(p, "EVENT", lisp_as_event(x)->name);
    else if (lisp_is(x, LISP_NATIVE)) {
        put_text(p, "#<CODE of ");
        put_number(p, (uint64_t)lisp_fixnum_value(lisp_as_native(x)->bytes), 10);
        put_text(p, " bytes for the processor>");
    }
    else if (x == LISP_UNBOUND)
        put_text(p, "#<unbound>");
    else {
        put_text(p, "#<unknown ");
        put_number(p, x, 16);
        put_char(p, '>');
    }
}

void lisp_print_asking(lisp x, int escape, void (*put)(void *to, char c), void *to, struct lisp_printing *ask)
{
    struct printer p = { put, to, escape, 0, LIMIT, ask, 0 };

    print_nested(&p, x);
}

void lisp_print(lisp x, void (*put)(void *to, char c), void *to)
{
    lisp_print_asking(x, 1, put, to, NULL);
}

void lisp_princ(lisp x, void (*put)(void *to, char c), void *to)
{
    lisp_print_asking(x, 0, put, to, NULL);
}
