/* The Lisp runtime's beginning, its self-test, and the loop that reads
 * from the serial port and prints back: all there is to do with a form
 * until there is an evaluator (M6b). */
#include "lisp.h"

void lisp_init(void)
{
    lisp_symbols_init();
    kprintf("lisp: objects are tagged 64-bit words, in a heap at %p that begins with NIL\n",
            (void *)(uintptr_t)VM_HEAP_BASE);
}

/* Where the self-test prints to: memory, so that it can look at the text. */
struct text {
    char chars[512];
    size_t length;
};

static void text_put(void *to, char c)
{
    struct text *t = to;

    if (t->length + 1 < sizeof t->chars)
        t->chars[t->length++] = c;
    t->chars[t->length] = 0;
}

static int same(const char *a, const char *b)
{
    return strlen(a) == strlen(b) && !memcmp(a, b, strlen(a));
}

/* Read the one form that the text is, and store its print. Returns how the
 * read went; anything after the form counts as an error. */
static enum lisp_read_status read_and_print(const char *text, struct text *printed, lisp *form)
{
    struct lisp_reader r;
    enum lisp_read_status status;
    lisp extra;

    printed->length = 0;
    printed->chars[0] = 0;
    lisp_reader_init(&r, text, strlen(text));
    status = lisp_read(&r, form);
    if (status != LISP_READ_OK)
        return status;
    lisp_print(*form, text_put, printed);
    return lisp_read(&r, &extra) == LISP_READ_END ? LISP_READ_OK : LISP_READ_ERROR;
}

static lisp read_one(const char *text)
{
    struct text printed;
    lisp form = LISP_NIL;

    if (read_and_print(text, &printed, &form) != LISP_READ_OK)
        panic("lisp self-test: %s was not read", text);
    return form;
}

/* What the reader makes of a text, shown by what the printer makes of the
 * result. The texts are read in a package of the self-test's own, so that
 * the symbols it invents do not stay behind in COMMON-LISP-USER. */
static const struct {
    const char *text, *printed;
} forms[] = {
    /* integers */
    { "0", "0" },
    { "-0", "0" },
    { "+17", "17" },
    { "007", "7" },
    { "-42", "-42" },
    { "10.", "10" },
    { "4611686018427387903", "4611686018427387903" },
    { "-4611686018427387904", "-4611686018427387904" },
    { "#xFF", "255" },
    { "#x-ff", "-255" },
    { "#b101", "5" },
    { "#o17", "15" },
    { "#X3fffffffffffffff", "4611686018427387903" },
    /* symbols */
    { "foo", "FOO" },
    { "Foo-Bar", "FOO-BAR" },
    { "|foo|", "|foo|" },
    { "|FOO|", "FOO" },
    { "a\\ b", "|A B|" },
    { "fo\\o", "|FOo|" },
    { "||", "||" },
    { "|1|", "|1|" },
    { "\\1", "|1|" },
    { "|1.5|", "|1.5|" },
    { "1+", "1+" },
    { "+", "+" },
    { "-", "-" },
    { "1e", "1E" },
    { "1/", "1/" },
    { "a.b", "A.B" },
    { ".b", ".B" },
    { "|.|", "|.|" },
    { "a#", "A#" },
    { "|#a|", "|#a|" },
    { "|a:b|", "|a:b|" },
    { "a\\:b", "|A:B|" },
    { "|a\\|b|", "|a\\|b|" },
    { "caf\xc3\xa9", "CAF\xc3\xa9" },
    { "nil", "NIL" },
    { "()", "NIL" },
    { "( )", "NIL" },
    { "t", "T" },
    { "*package*", "*PACKAGE*" },
    { ":key", ":KEY" },
    { "keyword:key", ":KEY" },
    { ":|key|", ":|key|" },
    { "cl:t", "T" },
    { "common-lisp::nil", "NIL" },
    { "clara.self-test::foo", "FOO" },
    { "#:gensym", "#:GENSYM" },
    /* characters */
    { "#\\a", "#\\a" },
    { "#\\A", "#\\A" },
    { "#\\space", "#\\Space" },
    { "#\\ ", "#\\Space" },
    { "#\\Newline", "#\\Newline" },
    { "#\\LINEFEED", "#\\Newline" },
    { "#\\tab", "#\\Tab" },
    { "#\\Rubout", "#\\Rubout" },
    { "#\\nul", "#\\Nul" },
    { "#\\(", "#\\(" },
    { "#\\\\", "#\\\\" },
    { "#\\;", "#\\;" },
    { "#\\\xc3\xa9", "#\\\xc3\xa9" },
    { "#\\u+e9", "#\\\xc3\xa9" },
    { "#\\U+2600", "#\\\xe2\x98\x80" },
    { "#\\U+1F600", "#\\\xf0\x9f\x98\x80" },
    { "#\\U+1", "#\\U+1" },
    { "#\\u+9B", "#\\U+9B" },
    /* strings */
    { "\"\"", "\"\"" },
    { "\"hello, world\"", "\"hello, world\"" },
    { "\"a\\\"b\\\\c\"", "\"a\\\"b\\\\c\"" },
    { "\"a\\nb\"", "\"anb\"" },
    { "\"two\nlines\"", "\"two\nlines\"" },
    { "\"caf\xc3\xa9 \xe2\x98\x80 \xf0\x9f\x98\x80\"", "\"caf\xc3\xa9 \xe2\x98\x80 \xf0\x9f\x98\x80\"" },
    { "\"; not a comment #| nor this\"", "\"; not a comment #| nor this\"" },
    /* lists */
    { "(a b c)", "(A B C)" },
    { "(a . b)", "(A . B)" },
    { "(a . (b . (c)))", "(A B C)" },
    { "(a . nil)", "(A)" },
    { "((a) (b (c)) . d)", "((A) (B (C)) . D)" },
    { "(a.b)", "(A.B)" },
    { "(a .b)", "(A .B)" },
    { "(1 2 . 3)", "(1 2 . 3)" },
    { "(a\"b\"c)", "(A \"b\" C)" },
    { "(a(b)c)", "(A (B) C)" },
    { "( a ; a comment\n b )", "(A B)" },
    { "(a #| b #| c |# d |# e)", "(A E)" },
    { "#| before |# (a) ; after", "(A)" },
    { "'a", "'A" },
    { "''a", "''A" },
    { "' a", "'A" },
    { "(quote a)", "'A" },
    { "(quote a b)", "(QUOTE A B)" },
    { "(quote . a)", "(QUOTE . A)" },
    { "(quote)", "(QUOTE)" },
    { "'(a 'b)", "'(A 'B)" },
    { "#'car", "#'CAR" },
    { "(function car)", "#'CAR" },
    /* vectors */
    { "#()", "#()" },
    { "#(1 #(2 3) \"x\" y #\\z)", "#(1 #(2 3) \"x\" Y #\\z)" },
    { "(a #(b (c)) . #(d))", "(A #(B (C)) . #(D))" },
    /* and a piece of a program */
    { "(defun fact (n) \"n!\" (if (> n 1) (* n (fact (1- n))) 1))",
      "(DEFUN FACT (N) \"n!\" (IF (> N 1) (* N (FACT (1- N))) 1))" },
};

/* Texts the reader has to turn down, and how: an error, or text that has
 * stopped short of a form, or nothing there to read. */
static const struct {
    const char *text;
    enum lisp_read_status status;
} refused[] = {
    { ")", LISP_READ_ERROR },
    { ".", LISP_READ_ERROR },
    { "..", LISP_READ_ERROR },
    { "(a . )", LISP_READ_ERROR },
    { "(a . b c)", LISP_READ_ERROR },
    { "( . a)", LISP_READ_ERROR },
    { "(a . . b)", LISP_READ_ERROR },
    { "(a . b . c)", LISP_READ_ERROR },
    { "')", LISP_READ_ERROR },
    { "(a ' . b)", LISP_READ_ERROR },
    { "1.5", LISP_READ_ERROR },
    { ".5", LISP_READ_ERROR },
    { "1e3", LISP_READ_ERROR },
    { "-1/2", LISP_READ_ERROR },
    { "6.02e+23", LISP_READ_ERROR },
    { "4611686018427387904", LISP_READ_ERROR },
    { "-4611686018427387905", LISP_READ_ERROR },
    { "123456789012345678901234567890", LISP_READ_ERROR },
    { "#x4000000000000000", LISP_READ_ERROR },
    { "#b102", LISP_READ_ERROR },
    { "#xyz", LISP_READ_ERROR },
    { "#x", LISP_READ_ERROR },
    { "#x|1|", LISP_READ_ERROR },
    { "nowhere:x", LISP_READ_ERROR },
    { "cl:no-such-symbol", LISP_READ_ERROR },
    { "clara.self-test:foo", LISP_READ_ERROR },
    { "a:b:c", LISP_READ_ERROR },
    { "cl:", LISP_READ_ERROR },
    { ":", LISP_READ_ERROR },
    { "::a", LISP_READ_ERROR },
    { "cl:::t", LISP_READ_ERROR },
    { "#:a:b", LISP_READ_ERROR },
    { "#<PACKAGE \"KEYWORD\">", LISP_READ_ERROR },
    { "#q", LISP_READ_ERROR },
    { "#3(a)", LISP_READ_ERROR },
    { "#+clara a", LISP_READ_ERROR },
    { "`a", LISP_READ_ERROR },
    { ",a", LISP_READ_ERROR },
    { "#\\nosuchname", LISP_READ_ERROR },
    { "#\\U+110000", LISP_READ_ERROR },
    { "#\\U+D800", LISP_READ_ERROR },
    { "#(a . b)", LISP_READ_ERROR },
    { "a\x01", LISP_READ_ERROR },
    { "a b", LISP_READ_ERROR }, /* read_and_print wants one form */
    { "\xff", LISP_READ_ERROR },
    { "\"\xc3\"", LISP_READ_ERROR },         /* the second byte is missing */
    { "\xc0\x80", LISP_READ_ERROR },         /* two bytes for what fits in one */
    { "\xed\xa0\x80", LISP_READ_ERROR },     /* U+D800, half a surrogate pair */
    { "\xf4\x90\x80\x80", LISP_READ_ERROR }, /* U+110000 */
    { "\"abc", LISP_READ_SHORT },
    { "\"abc\\", LISP_READ_SHORT },
    { "(a b", LISP_READ_SHORT },
    { "(a . ", LISP_READ_SHORT },
    { "(a . b", LISP_READ_SHORT },
    { "(a ; b)", LISP_READ_SHORT },
    { "'", LISP_READ_SHORT },
    { "#'", LISP_READ_SHORT },
    { "#(1 2", LISP_READ_SHORT },
    { "#| never closed", LISP_READ_SHORT },
    { "(a #| b |# ", LISP_READ_SHORT },
    { "|abc", LISP_READ_SHORT },
    { "abc\\", LISP_READ_SHORT },
    { "#\\", LISP_READ_SHORT },
    { "#", LISP_READ_SHORT },
    { "", LISP_READ_END },
    { "  \n\t ", LISP_READ_END },
    { "; only a comment", LISP_READ_END },
    { "#| one |# ; and another\n", LISP_READ_END },
};

/* Lists inside lists, as deep as the reader goes, and one deeper, which it
 * has to refuse. The printer gets one deeper than it goes as well, made by
 * hand, and has to cut it short with a #. Nothing takes more stack than
 * this: reading at that depth about 18 KiB of the thread's 64 on x86_64
 * and 14 KiB on AArch64, printing about 8 KiB. */
static void nesting_selftest(void)
{
    static char text[2 * LISP_DEPTH + 4];
    struct text printed;
    lisp form, deep = lisp_fixnum(1);

    for (unsigned depth = LISP_DEPTH; depth <= LISP_DEPTH + 1; depth++) {
        memset(text, '(', depth);
        text[depth] = '1';
        memset(text + depth + 1, ')', depth);
        text[2 * depth + 1] = 0;
        if (read_and_print(text, &printed, &form) != (depth > LISP_DEPTH ? LISP_READ_ERROR : LISP_READ_OK))
            panic("lisp self-test: lists nested %u deep were %s", depth, depth > LISP_DEPTH ? "read" : "refused");
        if (depth == LISP_DEPTH && !same(printed.chars, text))
            panic("lisp self-test: lists nested %u deep came back as %s", depth, printed.chars);
    }
    for (unsigned depth = 0; depth <= LISP_DEPTH; depth++)
        deep = lisp_cons(deep, LISP_NIL);
    printed.length = 0;
    lisp_print(deep, text_put, &printed);
    memset(text, '(', LISP_DEPTH);
    text[LISP_DEPTH] = '#';
    memset(text + LISP_DEPTH + 1, ')', LISP_DEPTH);
    text[2 * LISP_DEPTH + 1] = 0;
    if (!same(printed.chars, text))
        panic("lisp self-test: lists nested %u deep were printed as %s", LISP_DEPTH + 1, printed.chars);
}

/* More symbols than a package's table starts with room for. The table has
 * to grow, three times over, and every name still has to give the symbol
 * it gave the first time. */
static void table_selftest(void)
{
    enum { SYMBOLS = 200 };
    struct lisp_vector *first = lisp_as_vector(lisp_make_vector(SYMBOLS));
    char name[] = "symbol-000";

    for (unsigned pass = 0; pass < 2; pass++)
        for (unsigned i = 0; i < SYMBOLS; i++) {
            lisp symbol;

            name[7] = (char)('0' + i / 100);
            name[8] = (char)('0' + i / 10 % 10);
            name[9] = (char)('0' + i % 10);
            symbol = read_one(name);
            if (!pass)
                first->items[i] = symbol;
            else if (first->items[i] != symbol)
                panic("lisp self-test: with %u symbols in a package, %s is not the symbol it was", SYMBOLS, name);
        }
}

/* An object larger than a page, and then many pages: the heap has to map
 * what it grows into, and the frames have to come from the allocator. */
static void heap_selftest(void)
{
    enum { ITEMS = 16384 };
    uint64_t frames = pmm_free_frames();
    struct lisp_vector *v = lisp_as_vector(lisp_make_vector(ITEMS));

    for (uint64_t i = 0; i < ITEMS; i++)
        v->items[i] = lisp_fixnum((int64_t)i - ITEMS / 2);
    for (uint64_t i = 0; i < ITEMS; i++)
        if (lisp_fixnum_value(v->items[i]) != (int64_t)i - ITEMS / 2)
            panic("lisp self-test: item %llu of a large vector did not keep its value", i);
    /* Page tables for the new part of the heap come out of the same frames. */
    if (frames - pmm_free_frames() < ITEMS * sizeof(lisp) / PAGE_SIZE)
        panic("lisp self-test: a vector of %u items took %llu page frames", ITEMS, frames - pmm_free_frames());
}

void lisp_selftest(void)
{
    struct lisp_symbol *package = lisp_as_symbol(lisp_roots.package);
    lisp user = package->value, scratch, form, key, foo;
    uint64_t count[LISP_TYPES], bytes;
    struct text printed, again;
    struct lisp_reader r;
    unsigned line = 0, column = 0;

    /* The words themselves. */
    if (lisp_fixnum_value(lisp_fixnum(LISP_FIXNUM_MAX)) != LISP_FIXNUM_MAX ||
        lisp_fixnum_value(lisp_fixnum(-LISP_FIXNUM_MAX - 1)) != -LISP_FIXNUM_MAX - 1 ||
        lisp_fixnum_value(lisp_fixnum(-1)) != -1 || lisp_fixnum(0) != 0)
        panic("lisp self-test: a fixnum does not come back as the integer it was made of");
    if (lisp_character_code(lisp_character(0x10ffff)) != 0x10ffff || !lisp_is_character(lisp_character('a')) ||
        lisp_is_fixnum(lisp_character('a')) || lisp_is_character(LISP_UNBOUND))
        panic("lisp self-test: a character is not told apart from the other words");
    if (!lisp_is_symbol(LISP_NIL) || lisp_is_cons(LISP_NIL) || lisp_is_fixnum(LISP_NIL) ||
        !lisp_is_cons(lisp_cons(LISP_NIL, LISP_NIL)) || !lisp_is(lisp_make_vector(0), LISP_VECTOR) ||
        lisp_is(lisp_make_vector(0), LISP_STRING) || lisp_is(lisp_fixnum(5), LISP_VECTOR))
        panic("lisp self-test: the tags do not tell the objects apart");

    /* From here on names are read in a package that is thrown away at the end. */
    scratch = lisp_make_package("CLARA.SELF-TEST", NULL, lisp_cons(lisp_roots.common_lisp, LISP_NIL));
    package->value = scratch;

    for (unsigned i = 0; i < sizeof forms / sizeof forms[0]; i++) {
        if (read_and_print(forms[i].text, &printed, &form) != LISP_READ_OK)
            panic("lisp self-test: %s was not read", forms[i].text);
        if (!same(printed.chars, forms[i].printed))
            panic("lisp self-test: %s was printed as %s, not %s", forms[i].text, printed.chars, forms[i].printed);
        /* What was printed reads back, and prints the same again. */
        if (read_and_print(printed.chars, &again, &form) != LISP_READ_OK || !same(again.chars, printed.chars))
            panic("lisp self-test: %s was read back as %s", printed.chars, again.chars);
    }
    for (unsigned i = 0; i < sizeof refused / sizeof refused[0]; i++) {
        enum lisp_read_status status = read_and_print(refused[i].text, &printed, &form);

        if (status != refused[i].status)
            panic("lisp self-test: reading %s gave status %u, not %u", refused[i].text, (unsigned)status,
                  (unsigned)refused[i].status);
    }

    /* A text with several forms gives them one by one, and an error says where it is. */
    lisp_reader_init(&r, "1 (2) ; three\n four", 19);
    if (lisp_read(&r, &form) != LISP_READ_OK || form != lisp_fixnum(1) || lisp_read(&r, &form) != LISP_READ_OK ||
        !lisp_is_cons(form) || lisp_read(&r, &form) != LISP_READ_OK || form != read_one("four") ||
        lisp_read(&r, &form) != LISP_READ_END)
        panic("lisp self-test: four forms in one text were not read one after the other");
    lisp_reader_init(&r, "(a\n  (b . ) c)", 14);
    if (lisp_read(&r, &form) != LISP_READ_ERROR || (lisp_reader_where(&r, &line, &column), line != 2 || column != 8))
        panic("lisp self-test: an error on line 2, column 8 was reported at line %u, column %u", line, column);

    /* The same name is the same symbol, and so is every way of writing it. */
    foo = read_one("foo");
    key = read_one(":key");
    if (read_one("FOO") != foo || read_one("|FOO|") != foo || read_one("clara.self-test::foo") != foo ||
        read_one("fo\\O") != foo || read_one("|foo|") == foo || read_one("#:foo") == foo ||
        read_one("#:foo") == read_one("#:foo"))
        panic("lisp self-test: a name does not always give the same symbol");
    if (read_one("nil") != LISP_NIL || read_one("()") != LISP_NIL || read_one("cl:nil") != LISP_NIL ||
        read_one("t") != lisp_roots.t || read_one("common-lisp:t") != lisp_roots.t ||
        read_one("quote") != lisp_roots.quote || lisp_as_cons(read_one("'a"))->car != lisp_roots.quote)
        panic("lisp self-test: the symbols of COMMON-LISP are not found from a package that uses it");
    if (read_one("keyword:key") != key || lisp_as_symbol(key)->value != key ||
        lisp_as_symbol(key)->package != lisp_roots.keyword || lisp_as_symbol(foo)->value != LISP_UNBOUND ||
        lisp_as_symbol(foo)->package != scratch || lisp_as_symbol(LISP_NIL)->value != LISP_NIL)
        panic("lisp self-test: a symbol is not in the package it was read in, or has the wrong value");

    /* From a package that uses no other, each symbol is printed with the
     * package it is in, and that reads back as the same symbol. */
    package->value = lisp_roots.keyword;
    printed.length = 0;
    lisp_print(lisp_cons(foo, lisp_cons(lisp_roots.t, lisp_cons(key, lisp_cons(LISP_NIL, LISP_NIL)))), text_put,
               &printed);
    if (!same(printed.chars, "(CLARA.SELF-TEST::FOO COMMON-LISP:T :KEY COMMON-LISP:NIL)") ||
        lisp_as_cons(read_one(printed.chars))->car != foo)
        panic("lisp self-test: from another package the symbols were printed as %s", printed.chars);
    package->value = user;
    printed.length = 0;
    lisp_print(lisp_roots.keyword, text_put, &printed);
    if (!same(printed.chars, "#<PACKAGE \"KEYWORD\">"))
        panic("lisp self-test: a package was printed as %s", printed.chars);

    package->value = scratch;
    table_selftest();
    nesting_selftest();
    package->value = user;
    heap_selftest();

    /* The scratch package was the last one made, so it is the first in the list. */
    lisp_roots.packages = lisp_as_cons(lisp_roots.packages)->cdr;
    if (lisp_find_package((const uint32_t[]){ 'C', 'L' }, 2) != lisp_roots.common_lisp || lisp_current_package() != user)
        panic("lisp self-test: the packages are not as they were before it");

    bytes = lisp_heap_census(count);
    kprintf("lisp: self-test passed, %u texts read and printed back, %u refused, lists nested %u deep\n",
            (unsigned)(sizeof forms / sizeof forms[0]), (unsigned)(sizeof refused / sizeof refused[0]), LISP_DEPTH);
    kprintf("lisp: %llu KiB of heap in use: %llu conses, %llu symbols, %llu strings, %llu vectors, %llu packages\n",
            bytes >> 10, count[LISP_CONS], count[LISP_SYMBOL], count[LISP_STRING], count[LISP_VECTOR],
            count[LISP_PACKAGE]);
}

static void console_put(void *to, char c)
{
    (void)to;
    kputc(c);
}

/* Read forms from the serial port and print each one back, until the
 * input ends. The reader wants its text whole, so lines are gathered until
 * they hold a form: after every line the reader starts again at the first
 * form that is not finished, and as long as that one stops short, another
 * line is asked for. */
void lisp_listen(void)
{
    static uint8_t text[8192];
    size_t used = 0;

    kprintf("clara: reading from the serial port: a form typed there is printed back, and Ctrl-D ends it\n");
    for (;;) {
        struct lisp_reader r;
        enum lisp_read_status status;
        const uint8_t *unread;
        unsigned line, column;
        lisp form;
        int64_t length;

        kputs(used ? "  " : "> ");
        length = kgetline((char *)text + used, sizeof text - used - 1);
        if (length < 0) {
            kputc('\n');
            if (used)
                kprintf("the input ended in the middle of a form\n");
            return;
        }
        used += (size_t)length;
        text[used++] = '\n';

        lisp_reader_init(&r, text, used);
        do {
            unread = r.at;
            status = lisp_read(&r, &form);
            if (status == LISP_READ_OK) {
                lisp_print(form, console_put, NULL);
                kputc('\n');
            }
        } while (status == LISP_READ_OK);
        if (status == LISP_READ_SHORT && used < sizeof text - 1) {
            /* Keep the form that is not finished, and ask for more of it. */
            used = (size_t)(r.end - unread);
            memmove(text, unread, used);
            continue;
        }
        if (status == LISP_READ_SHORT)
            kprintf("that form is longer than the %u bytes there is room for here\n", (unsigned)sizeof text);
        else if (status == LISP_READ_ERROR) {
            lisp_reader_where(&r, &line, &column);
            kprintf("error at line %u, column %u: %s\n", line, column, r.error);
        }
        used = 0;
    }
}
