/* Symbols, and the packages that find them by name.
 *
 * A package has two tables of its own symbols: the internal ones, and the
 * external ones, which every package that uses it can have by name as
 * well. Reading a name in a package gives the symbol that is accessible
 * there, one of its own or an external one of a package it uses, and
 * makes a new internal one when there is none.
 *
 * Three packages exist from the start. KEYWORD, where every symbol is
 * external and is its own value. COMMON-LISP, for the symbols of the
 * language, which the substrate adds as it learns them. COMMON-LISP-USER,
 * which uses COMMON-LISP and is where names are read until something says
 * otherwise.
 *
 * A table is a vector: item 0 counts the symbols, and the rest are slots,
 * a power of two of them, each a symbol or fixnum zero. A symbol goes in
 * the slot its name hashes to, or the next free one after it, and a table
 * that is half full is replaced by one twice the size. A symbol leaves a
 * table only to go into the other one of its package, when it is
 * exported. */
#include "lisp.h"

enum { TABLE_SLOTS = 32 }; /* of a new table */

struct lisp_roots lisp_roots;

/* FNV-1a over the code points. */
static uint64_t hash(const uint32_t *name, uint64_t length)
{
    uint64_t h = 0xcbf29ce484222325ULL;

    while (length--)
        h = (h ^ *name++) * 0x100000001b3ULL;
    return h;
}

static int string_is(lisp string, const uint32_t *chars, uint64_t length)
{
    const struct lisp_string *s = lisp_as_string(string);

    return lisp_length(s->header) == length && !memcmp(s->chars, chars, length * sizeof chars[0]);
}

/* The symbol of that name in the table, or 0. */
static lisp table_find(lisp table, const uint32_t *name, uint64_t length)
{
    const struct lisp_vector *v = lisp_as_vector(table);
    uint64_t mask = lisp_length(v->header) - 2; /* one less than the slots */

    for (uint64_t i = hash(name, length) & mask; v->items[1 + i]; i = (i + 1) & mask)
        if (string_is(lisp_as_symbol(v->items[1 + i])->name, name, length))
            return v->items[1 + i];
    return 0;
}

/* Put a symbol in a table that has room for it and does not have it. */
static void table_put(lisp table, lisp symbol)
{
    struct lisp_vector *v = lisp_as_vector(table);
    const struct lisp_string *name = lisp_as_string(lisp_as_symbol(symbol)->name);
    uint64_t mask = lisp_length(v->header) - 2;
    uint64_t i = hash(name->chars, lisp_length(name->header)) & mask;

    while (v->items[1 + i])
        i = (i + 1) & mask;
    v->items[1 + i] = symbol;
    v->items[0] += lisp_fixnum(1);
}

/* Add a symbol that the table does not have. What comes back is the table
 * to keep: the same one, or a larger one with everything in it. */
static lisp table_add(lisp table, lisp symbol)
{
    const struct lisp_vector *v = lisp_as_vector(table);
    uint64_t slots = lisp_length(v->header) - 1;

    if (2 * ((uint64_t)lisp_fixnum_value(v->items[0]) + 1) > slots) {
        lisp larger = lisp_make_vector(1 + 2 * slots);

        for (uint64_t i = 1; i <= slots; i++)
            if (v->items[i])
                table_put(larger, v->items[i]);
        table = larger;
    }
    table_put(table, symbol);
    return table;
}

/* Take out a symbol that the table has. The ones in the slots after it,
 * up to the next free slot, may be where they are only because its slot
 * was taken, so each of them is put in again. */
static void table_remove(lisp table, lisp symbol)
{
    struct lisp_vector *v = lisp_as_vector(table);
    uint64_t mask = lisp_length(v->header) - 2, i = 0;

    while (v->items[1 + i] != symbol)
        i++;
    do {
        lisp moved = v->items[1 + i];

        v->items[1 + i] = 0;
        v->items[0] -= lisp_fixnum(1);
        if (moved != symbol)
            table_put(table, moved);
        i = (i + 1) & mask;
    } while (v->items[1 + i]);
}

/* The names the substrate gives are ASCII, in C strings. */
static uint64_t widen(const char *name, uint32_t wide[LISP_TOKEN_MAX])
{
    uint64_t length = strlen(name);

    if (length > LISP_TOKEN_MAX)
        panic("lisp: the name %s is too long", name);
    for (uint64_t i = 0; i < length; i++)
        wide[i] = (uint8_t)name[i];
    return length;
}

static lisp string_of(const char *text)
{
    uint32_t wide[LISP_TOKEN_MAX];
    uint64_t length = widen(text, wide);

    return lisp_make_string(wide, length);
}

/* A symbol that is in no package: nothing can find it by its name. */
lisp lisp_make_symbol(const uint32_t *name, uint64_t length)
{
    struct lisp_symbol *s = lisp_alloc(LISP_SYMBOL, 0);

    s->name = lisp_make_string(name, length);
    s->package = LISP_NIL;
    s->value = LISP_UNBOUND;
    s->function = LISP_UNBOUND;
    s->plist = LISP_NIL;
    return (lisp)(uintptr_t)s | LISP_TAG_SYMBOL;
}

lisp lisp_make_package(const char *name, const char *nickname, lisp uses)
{
    return lisp_new_package(string_of(name), nickname ? lisp_cons(string_of(nickname), LISP_NIL) : LISP_NIL, uses);
}

/* A package with that name, a string, those nicknames, a list of strings,
 * that uses those packages. Whoever calls has seen to it that the names
 * are free. */
lisp lisp_new_package(lisp name, lisp nicknames, lisp uses)
{
    struct lisp_package *p = lisp_alloc(LISP_PACKAGE, 0);
    lisp package = (lisp)(uintptr_t)p | LISP_TAG_OBJECT;

    p->name = name;
    p->nicknames = nicknames;
    p->uses = uses;
    p->internal = lisp_make_vector(1 + TABLE_SLOTS);
    p->external = lisp_make_vector(1 + TABLE_SLOTS);
    lisp_roots.packages = lisp_cons(package, lisp_roots.packages);
    return package;
}

lisp lisp_find_package(const uint32_t *name, uint64_t length)
{
    for (lisp all = lisp_roots.packages; all != LISP_NIL; all = lisp_as_cons(all)->cdr) {
        lisp package = lisp_as_cons(all)->car;
        const struct lisp_package *p = lisp_as_package(package);

        if (string_is(p->name, name, length))
            return package;
        for (lisp n = p->nicknames; n != LISP_NIL; n = lisp_as_cons(n)->cdr)
            if (string_is(lisp_as_cons(n)->car, name, length))
                return package;
    }
    return 0;
}

/* The symbol that the name gives in the package, and how it comes to be
 * accessible there; LISP_ABSENT when there is none. */
enum lisp_access lisp_find_symbol(lisp package, const uint32_t *name, uint64_t length, lisp *symbol)
{
    const struct lisp_package *p = lisp_as_package(package);

    if ((*symbol = table_find(p->external, name, length)))
        return LISP_EXTERNAL;
    if ((*symbol = table_find(p->internal, name, length)))
        return LISP_INTERNAL;
    for (lisp u = p->uses; u != LISP_NIL; u = lisp_as_cons(u)->cdr)
        if ((*symbol = table_find(lisp_as_package(lisp_as_cons(u)->car)->external, name, length)))
            return LISP_INHERITED;
    return LISP_ABSENT;
}

/* A new symbol of the package's own. In KEYWORD every symbol is external
 * and evaluates to itself. */
static lisp add_symbol(lisp package, const uint32_t *name, uint64_t length, int external)
{
    struct lisp_package *p = lisp_as_package(package);
    lisp symbol = lisp_make_symbol(name, length);

    lisp_as_symbol(symbol)->package = package;
    if (package == lisp_roots.keyword) {
        lisp_as_symbol(symbol)->value = symbol;
        lisp_symbol_flag(symbol, LISP_CONSTANT);
        external = 1;
    }
    if (external)
        p->external = table_add(p->external, symbol);
    else
        p->internal = table_add(p->internal, symbol);
    return symbol;
}

lisp lisp_intern(lisp package, const uint32_t *name, uint64_t length)
{
    lisp symbol;

    if (lisp_find_symbol(package, name, length, &symbol) != LISP_ABSENT)
        return symbol;
    return add_symbol(package, name, length, 0);
}

lisp lisp_current_package(void)
{
    return lisp_as_symbol(lisp_roots.package)->value;
}

/* One of the package's own symbols becomes external: the packages that
 * use this one find it by name from now on. Says whether it could be
 * done, which it cannot for a symbol the package does not have or only
 * inherits. Whether the name is already taken in a package that uses this
 * one is not looked at. */
int lisp_export(lisp package, lisp symbol)
{
    struct lisp_package *p = lisp_as_package(package);
    const struct lisp_string *name = lisp_as_string(lisp_as_symbol(symbol)->name);
    uint64_t length = lisp_length(name->header);

    if (table_find(p->external, name->chars, length) == symbol)
        return 1;
    if (table_find(p->internal, name->chars, length) != symbol)
        return 0;
    table_remove(p->internal, symbol);
    p->external = table_add(p->external, symbol);
    return 1;
}

/* The symbol that the substrate knows by a name in C, in one of its own
 * packages: made if need be, and external there if asked. */
lisp lisp_symbol_in(lisp package, const char *name, int external)
{
    uint32_t wide[LISP_TOKEN_MAX];
    uint64_t length = widen(name, wide);
    lisp symbol;

    if (lisp_find_symbol(package, wide, length, &symbol) == LISP_ABSENT)
        return add_symbol(package, wide, length, external);
    if (external)
        lisp_export(package, symbol);
    return symbol;
}

/* NIL first, because its word is a constant that everything below uses:
 * the first object in the heap. Then the packages, and the few symbols
 * that the reader and the printer know by sight. */
void lisp_symbols_init(void)
{
    struct lisp_symbol *nil = lisp_alloc(LISP_SYMBOL, 0);

    if (((lisp)(uintptr_t)nil | LISP_TAG_SYMBOL) != LISP_NIL)
        panic("lisp: NIL has to be the first object in the heap, and it is at %p", (void *)nil);
    nil->name = string_of("NIL");
    nil->value = LISP_NIL;
    nil->function = LISP_UNBOUND;
    nil->plist = LISP_NIL;
    lisp_roots.packages = LISP_NIL;

    lisp_roots.keyword = lisp_make_package("KEYWORD", NULL, LISP_NIL);
    lisp_roots.common_lisp = lisp_make_package("COMMON-LISP", "CL", LISP_NIL);
    lisp_roots.user = lisp_make_package("COMMON-LISP-USER", "CL-USER", lisp_cons(lisp_roots.common_lisp, LISP_NIL));

    nil->package = lisp_roots.common_lisp;
    lisp_as_package(lisp_roots.common_lisp)->external =
        table_add(lisp_as_package(lisp_roots.common_lisp)->external, LISP_NIL);
    lisp_symbol_flag(LISP_NIL, LISP_CONSTANT);
    lisp_roots.t = lisp_symbol_in(lisp_roots.common_lisp, "T", 1);
    lisp_as_symbol(lisp_roots.t)->value = lisp_roots.t;
    lisp_symbol_flag(lisp_roots.t, LISP_CONSTANT);
    lisp_roots.quote = lisp_symbol_in(lisp_roots.common_lisp, "QUOTE", 1);
    lisp_roots.function = lisp_symbol_in(lisp_roots.common_lisp, "FUNCTION", 1);
    lisp_roots.package = lisp_symbol_in(lisp_roots.common_lisp, "*PACKAGE*", 1);
    lisp_as_symbol(lisp_roots.package)->value = lisp_roots.user;
    lisp_symbol_flag(lisp_roots.package, LISP_SPECIAL);
    /* Common Lisp gives no names to what a backquote is read as, so these
     * are the substrate's own, and stay internal. */
    lisp_roots.quasiquote = lisp_symbol_in(lisp_roots.common_lisp, "QUASIQUOTE", 0);
    lisp_roots.unquote = lisp_symbol_in(lisp_roots.common_lisp, "UNQUOTE", 0);
    lisp_roots.splice = lisp_symbol_in(lisp_roots.common_lisp, "UNQUOTE-SPLICING", 0);
}
