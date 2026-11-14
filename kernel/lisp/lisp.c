/* The Lisp runtime's beginning, its self-tests, and the thread that the
 * Lisp world runs on: it loads lisp/boot.lisp, and then reads forms from
 * the serial port, evaluates them and prints what they give. */
#include "lisp.h"

/* The evaluator calls itself in C for every form inside a form, so its
 * thread has a stack to match: a function that calls itself gets some
 * thousands of calls deep before the evaluator says the stack is full. */
#define LISP_STACK_SIZE (1024 * 1024)

void lisp_init(const struct boot_file *files)
{
    lisp_symbols_init();
    kprintf("lisp: objects are tagged 64-bit words, in a heap at %p that begins with NIL\n",
            (void *)(uintptr_t)VM_HEAP_BASE);
    lisp_eval_init(files);
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
    { "`a", "`A" },
    { "`(a ,b ,@c . ,d)", "`(A ,B ,@C . ,D)" },
    { "`(a `(b ,(c ,d)))", "`(A `(B ,(C ,D)))" },
    { "`(a ,.b)", "`(A ,@B)" },
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
    { ",a", LISP_READ_ERROR },
    { ",@a", LISP_READ_ERROR },
    { "`(a ,,b)", LISP_READ_ERROR }, /* two commas to one backquote */
    { "`#(a ,b)", LISP_READ_ERROR },
    { "`", LISP_READ_SHORT },
    { "`(a ,", LISP_READ_SHORT },
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

    kprintf("lisp: the reader and the printer passed: %u texts read and printed back, %u refused, lists %u deep\n",
            (unsigned)(sizeof forms / sizeof forms[0]), (unsigned)(sizeof refused / sizeof refused[0]), LISP_DEPTH);
}

/* What the evaluator makes of a text: the forms in it are evaluated one
 * after the other, and what the last one gives is written down, its
 * values with a space between them, or the error. */
static void evaluate_text(const char *source, struct text *printed)
{
    struct lisp_reader r;
    enum lisp_read_status status;
    lisp form;

    printed->length = 0;
    printed->chars[0] = 0;
    lisp_reader_init(&r, source, strlen(source));
    while ((status = lisp_read(&r, &form)) == LISP_READ_OK) {
        printed->length = 0;
        printed->chars[0] = 0;
        if (!lisp_evaluate(form)) {
            for (const char *s = "error: "; *s; s++)
                text_put(printed, *s);
            lisp_princ(lisp_values.value[0], text_put, printed);
            return;
        }
        for (unsigned i = 0; i < lisp_values.count; i++) {
            if (i)
                text_put(printed, ' ');
            lisp_print(lisp_values.value[i], text_put, printed);
        }
    }
    if (status != LISP_READ_END)
        panic("lisp self-test: %s was not read", source);
}

#define TOO_LARGE  "error: the result is an integer too large for a fixnum, and there are no larger integers yet"
#define STACK_FULL "error: the stack is full: the forms are nested too deep, or a function calls itself without end"

/* Texts and what evaluating them has to give. They are evaluated in
 * order, in a package of the self-test's own, and a text can use what an
 * earlier one defined. The first part needs nothing but the substrate;
 * from the macros on, lisp/boot.lisp has its share in the answers. */
static const struct {
    const char *text, *printed;
} evaluations[] = {
    /* what is its own value, and variables */
    { "42", "42" },
    { "\"text\"", "\"text\"" },
    { "#\\a", "#\\a" },
    { ":key", ":KEY" },
    { "t", "T" },
    { "()", "NIL" },
    { "#(1 a)", "#(1 A)" },
    { "'(a . b)", "(A . B)" },
    { "no-such-variable", "error: the variable NO-SUCH-VARIABLE has no value" },
    { "(no-such-function 1)", "error: the function NO-SUCH-FUNCTION is not defined" },
    { "(1 2)", "error: 1 is not the name of a function, so (1 2) is not a form" },
    /* integers */
    { "(+ 1 2 3)", "6" },
    { "(+)", "0" },
    { "(- 10 3 2)", "5" },
    { "(- 5)", "-5" },
    { "(* 2 3 4)", "24" },
    { "(/ 12 3 2)", "2" },
    { "(/ 7 2)", "error: 7 divided by 2 is not an integer, and there are no ratios yet" },
    { "(/ 1 0)", "error: division by zero" },
    { "(+ 4611686018427387903 1)", TOO_LARGE },
    { "(1+ 4611686018427387903)", TOO_LARGE },
    { "(- -4611686018427387904 1)", TOO_LARGE },
    { "(- -4611686018427387904)", TOO_LARGE },
    { "(* 4611686018427387903 2)", TOO_LARGE },
    { "(* -2305843009213693952 2)", "-4611686018427387904" },
    { "(floor 7 2)", "3 1" },
    { "(floor -7 2)", "-4 1" },
    { "(truncate -7 2)", "-3 -1" },
    { "(mod -7 2)", "1" },
    { "(rem -7 2)", "-1" },
    { "(< 1 2 3)", "T" },
    { "(< 1 3 2)", "NIL" },
    { "(= 2 2 2)", "T" },
    { "(/= 1 2 1)", "NIL" },
    { "(>= 3 3 2)", "T" },
    { "(ash 1 10)", "1024" },
    { "(ash -1024 -3)", "-128" },
    { "(ash 1 62)", TOO_LARGE },
    { "(list (logand 12 10) (logior 12 10) (logxor 12 10) (lognot 0))", "(8 14 6 -1)" },
    { "(+ 1 \"2\")", "error: + wants an integer, and \"2\" is not one" },
    /* special forms */
    { "(if nil 1 2)", "2" },
    { "(if 0 1 2)", "1" },
    { "(if nil 1)", "NIL" },
    { "(if)", "error: (IF) has the wrong number of parts for IF" },
    { "(progn 1 2 3)", "3" },
    { "(progn)", "NIL" },
    { "(let ((a 1) (b 2)) (+ a b))", "3" },
    { "(let ((a 1)) (let ((a 2) (b a)) (list a b)))", "(2 1)" },
    { "(let* ((a 1) (b (+ a 1))) (list a b))", "(1 2)" },
    { "(let (a (b)) (list a b))", "(NIL NIL)" },
    { "(let ((a 1)) (setq a 2 b a) (list a b))", "(2 2)" },
    { "(setq)", "NIL" },
    { "(setq t 1)", "error: T cannot be set: it is not a variable" },
    { "(let ((x 1)) (declare (ignorable x)) \"not documentation\")", "\"not documentation\"" },
    { "(let ((x 1)) (declare (special x)) x)",
      "error: (DECLARE (SPECIAL ...)), which the evaluator does not know yet: DEFVAR makes a variable special" },
    /* functions and closures */
    { "(defun add (a b) \"The sum.\" (+ a b))", "ADD" },
    { "(add 1 2)", "3" },
    { "(add 1)", "error: #<FUNCTION ADD> got too few arguments" },
    { "(add 1 2 3)", "error: #<FUNCTION ADD> got too many arguments" },
    { "((lambda (x) (* x x)) 7)", "49" },
    { "(lambda (x) x)", "#<FUNCTION (LAMBDA (X))>" },
    { "(funcall (lambda (&optional (a 1) (b (+ a 1) b-p)) (list a b b-p)))", "(1 2 NIL)" },
    { "(funcall (lambda (&optional (a 1) (b (+ a 1) b-p)) (list a b b-p)) 5 6)", "(5 6 T)" },
    { "(funcall (lambda (a &rest more) (list a more)) 1 2 3)", "(1 (2 3))" },
    { "(funcall (lambda (&key a (b 2) ((:see c) 3 c-p)) (list a b c c-p)) :b 5 :see 6)", "(NIL 5 6 T)" },
    { "(funcall (lambda (&key a) a) :b 1)",
      "error: #<FUNCTION (LAMBDA (&KEY A))> does not take the keyword argument :B" },
    { "(funcall (lambda (&key a) a) :b 1 :allow-other-keys t)", "NIL" },
    { "(funcall (lambda (&key a &allow-other-keys) a) :b 1 :a 2 :a 3)", "2" },
    { "(funcall (lambda (&key a) a) :a)",
      "error: #<FUNCTION (LAMBDA (&KEY A))> got an odd number of keyword arguments" },
    { "(funcall (lambda (&rest all &key a) (list a all)) :a 1)", "(1 (:A 1))" },
    { "(funcall (lambda (a &aux (b (* a 2))) (list a b)) 4)", "(4 8)" },
    { "(defun make-counter () (let ((n 0)) (lambda () (setq n (+ n 1)))))", "MAKE-COUNTER" },
    { "(let ((c (make-counter)) (d (make-counter))) (funcall c) (funcall c) (list (funcall c) (funcall d)))",
      "(3 1)" },
    { "(apply #'+ 1 2 '(3 4))", "10" },
    { "(funcall 'add 1 2)", "3" },
    { "(funcall 5)", "error: 5 is not a function" },
    { "(list #'car #'add)", "(#<FUNCTION CAR> #<FUNCTION ADD>)" },
    { "(function if)", "error: IF is a macro or a special operator, not a function" },
    { "(flet ((add (a b) (* a b))) (add 3 4))", "12" },
    { "(labels ((even (n) (if (= n 0) t (odd (- n 1)))) (odd (n) (if (= n 0) nil (even (- n 1))))) (even 10))",
      "T" },
    { "(defun fact (n) (if (< n 2) 1 (* n (fact (- n 1)))))", "FACT" },
    { "(fact 20)", "2432902008176640000" },
    { "(fact 21)", TOO_LARGE },
    { "(car 1)", "error: CAR wants a list, and 1 is not one" },
    { "(car)", "error: the number of arguments CAR takes is 1, not 0" },
    { "(cons 1)", "error: the number of arguments CONS takes is 2, not 1" },
    /* special variables */
    { "(defvar *level* 1)", "*LEVEL*" },
    { "(defun level () *level*)", "LEVEL" },
    { "(list (let ((*level* 2)) (level)) (level))", "(2 1)" },
    { "(list (let* ((*level* 3) (deeper (level))) deeper) (level))", "(3 1)" },
    { "(defvar *level* 5) *level*", "1" },
    { "(defparameter *level* 6) *level*", "6" },
    { "(list (funcall (lambda (*level*) (level)) 7) (level))", "(7 6)" },
    { "(list (catch 'out (let ((*level* 8)) (throw 'out (level)))) (level))", "(8 6)" },
    { "(defconstant +two+ 2)", "+TWO+" },
    { "(setq +two+ 3)", "error: +TWO+ cannot be set: it is not a variable" },
    { "(let ((+two+ 3)) +two+)", "error: +TWO+ cannot be the name of a variable" },
    { "(list (let ((*package* (find-package \"KEYWORD\"))) (package-name *package*)) (package-name *package*))",
      "(\"KEYWORD\" \"CLARA.SELF-TEST\")" },
    /* blocks, tags and catches */
    { "(block b 1 (return-from b 2) 3)", "2" },
    { "(block b (funcall (lambda () (return-from b 5))) 6)", "5" },
    { "(funcall (block b (lambda () (return-from b 1))))", "error: RETURN-FROM B, a block that has been left already" },
    { "(return-from nowhere 1)", "error: RETURN-FROM NOWHERE, and no block of that name is in sight" },
    { "(defun early (n) (if (< n 0) (return-from early 'negative)) n) (list (early 1) (early -1))",
      "(1 NEGATIVE)" },
    { "(let ((n 0) (sum 0)) (tagbody again (setq sum (+ sum n) n (+ n 1)) (if (< n 5) (go again))) sum)", "10" },
    { "(let ((x nil)) (tagbody (go b) a (setq x (cons 'a x)) (go c) b (setq x (cons 'b x)) (go a) c) x)",
      "(A B)" },
    { "(go nowhere)", "error: GO to NOWHERE, and no TAGBODY in sight has that tag" },
    { "(catch 'c 1 (throw 'c 2) 3)", "2" },
    { "(catch 'c (catch 'd (throw 'c 1)) 2)", "1" },
    { "(defun thrower () (throw 'out 9)) (catch 'out (thrower) 1)", "9" },
    { "(throw 'c 1)", "error: THROW to C, and no CATCH is waiting for it" },
    /* several values, and none */
    { "(values 1 2 3)", "1 2 3" },
    { "(values)", "" },
    { "(list (values 1 2) (values))", "(1 NIL)" },
    { "(multiple-value-bind (a b c) (values 1 2) (list a b c))", "(1 2 NIL)" },
    { "(multiple-value-call #'list (values 1 2) 3 (values) (values 4 5))", "(1 2 3 4 5)" },
    { "(multiple-value-prog1 (values 1 2) (values 3 4))", "1 2" },
    { "(block b (return-from b (values 1 2)))", "1 2" },
    { "(catch 'c (throw 'c (values 1 2)))", "1 2" },
    { "(if t (values 1 2))", "1 2" },
    { "(let () (values 1 2))", "1 2" },
    { "(progn (values 1 2) 3)", "3" },
    { "(values-list '(1 2))", "1 2" },
    { "(funcall (lambda () (floor 17 5)))", "3 2" },
    /* macros and backquote */
    { "(defmacro swap (a b) `(let ((old ,a)) (setq ,a ,b ,b old)))", "SWAP" },
    { "(let ((x 1) (y 2)) (swap x y) (list x y))", "(2 1)" },
    { "(macroexpand-1 '(swap p q))", "(LET ((OLD P)) (SETQ P Q Q OLD)) T" },
    { "(macroexpand-1 '(car x))", "(CAR X) NIL" },
    { "(swap 1)", "error: #<MACRO SWAP> got too few arguments" },
    { "`(1 ,(+ 1 1) ,@(list 3 4) . 5)", "(1 2 3 4 . 5)" },
    { "`(a . ,(+ 1 2))", "(A . 3)" },
    { "(let ((x '(b c))) `(a ,@x d ,x ,@nil))", "(A B C D (B C))" },
    { "``(a ,,(+ 1 2))", "`(A ,3)" },
    { "(defmacro with-pair ((a b) pair &body body) `(let ((,a (car ,pair)) (,b (cdr ,pair))) ,@body))",
      "WITH-PAIR" },
    { "(with-pair (x y) '(1 . 2) (list y x))", "(2 1)" },
    { "(defmacro whole (&whole form a . more) (list 'quote (list form a more))) (whole 1 2)", "((WHOLE 1 2) 1 (2))" },
    { "(macrolet ((twice (x) `(* 2 ,x))) (twice 21))", "42" },
    { "(defun swapped (a b) (swap a b) (list a b)) (list (swapped 1 2) (swapped 3 4))", "((2 1) (4 3))" },
    { "(defmacro show (form) `(list ',form ,form)) (defun shows () (show (when t 1))) (list (shows) (shows))",
      "(((WHEN T 1) 1) ((WHEN T 1) 1))" },
    { "(eval '(+ 1 2))", "3" },
    { "(let ((form (list 'when t 1))) (list (eval form) form))", "(1 (WHEN T 1))" },
    /* the language in boot.lisp: control */
    { "(cond ((= 1 2) 'a) ((= 1 1) 'b) (t 'c))", "B" },
    { "(cond ((= 1 2) 'a) (7))", "7" },
    { "(list (and) (and 1 2 3) (and 1 nil 3) (or) (or nil 2 3) (or nil nil))", "(T 3 NIL NIL 2 NIL)" },
    { "(list (when (= 1 1) 1 2) (unless (= 1 1) 1))", "(2 NIL)" },
    { "(case 2 (1 'one) ((2 3) 'few) (t 'many))", "FEW" },
    { "(case 'x (y 1) (otherwise 2))", "2" },
    { "(ecase 5 (1 'one))", "error: 5 fell through an ECASE form" },
    { "(let ((sum 0)) (dolist (x '(1 2 3) sum) (setq sum (+ sum x))))", "6" },
    { "(dolist (x '(1 2 3)) (if (= x 2) (return x)))", "2" },
    { "(let ((l nil)) (dotimes (i 4 l) (push i l)))", "(3 2 1 0)" },
    { "(do ((i 0 (1+ i)) (l nil (cons i l))) ((= i 3) l))", "(2 1 0)" },
    { "(do* ((i 0 (1+ i)) (l (list i) (cons i l))) ((= i 2) l))", "(2 1 0)" },
    { "(let ((n 0)) (loop (if (> n 9) (return n)) (incf n 3)))", "12" },
    { "(let ((a 1) (b 2)) (psetq a b b a) (list a b))", "(2 1)" },
    { "(prog1 1 2 3)", "1" },
    { "(multiple-value-list (floor 17 5))", "(3 2)" },
    { "(nth-value 1 (floor 17 5))", "2" },
    { "(let (q r) (multiple-value-setq (q r) (floor 17 5)) (list q r))", "(3 2)" },
    /* lists */
    { "(mapcar #'1+ '(1 2 3))", "(2 3 4)" },
    { "(mapcar #'+ '(1 2 3) '(10 20))", "(11 22)" },
    { "(mapcan (lambda (x) (list x x)) '(1 2))", "(1 1 2 2)" },
    { "(reduce #'+ '(1 2 3 4))", "10" },
    { "(reduce #'list '(1 2) :initial-value 0)", "((0 1) 2)" },
    { "(remove-if #'evenp '(1 2 3 4))", "(1 3)" },
    { "(list (find 2 '(1 2 3)) (position 3 '(1 2 3)) (every #'oddp '(1 3)) (some #'evenp '(1 3)))",
      "(2 2 T NIL)" },
    { "(member 2 '(1 2 3))", "(2 3)" },
    { "(member \"b\" '(\"a\" \"b\") :test #'equal)", "(\"b\")" },
    { "(assoc 'b '((a . 1) (b . 2)))", "(B . 2)" },
    { "(append '(1) '(2 3) nil '(4))", "(1 2 3 4)" },
    { "(list (reverse '(1 2 3)) (nth 1 '(a b c)) (last '(1 2 3)) (length '(1 2 3)) (third '(1 2 3)))",
      "((3 2 1) B (3) 3 3)" },
    { "(list (equal '(1 \"a\" (b)) (list 1 \"a\" '(b))) (eq \"a\" \"a\") (eql 1 1))", "(T NIL T)" },
    { "(list (max 1 3 2) (min 1 3 2) (abs -5) (expt 2 10) (evenp 4))", "(3 1 5 1024 T)" },
    { "(getf '(a 1 b 2) 'b)", "2" },
    /* places */
    { "(let ((l (list 1 2 3))) (setf (car l) 'a (cadr l) 'b) (incf (nth 2 l) 10) l)", "(A B 13)" },
    { "(let ((v (vector 1 2 3))) (setf (aref v 1) 'x) (push 0 (aref v 0)) v)", "#((0 . 1) X 3)" },
    { "(let ((l '(1 2))) (list (pop l) l))", "(1 (2))" },
    { "(let ((i 0) (v (vector 0 0))) (incf (aref v (incf i))) (list i v))", "(1 #(0 1))" },
    { "(progn (setf (get 'thing 'colour) 'red) (get 'thing 'colour))", "RED" },
    { "(setf (no-such-place 1) 2)", "error: SETF does not know the place (NO-SUCH-PLACE 1)" },
    /* structures */
    { "(defstruct point x (y 10))", "POINT" },
    { "(make-point :x 1)", "#S(POINT :X 1 :Y 10)" },
    { "(let ((p (make-point :x 1 :y 2))) (setf (point-x p) 5) (incf (point-y p))"
      " (list (point-x p) (point-y p) (point-p p) (point-p 5)))",
      "(5 3 T NIL)" },
    { "(point-x 5)", "error: 5 is not a structure of type POINT" },
    { "(let* ((p (make-point :x 1)) (q (copy-point p))) (setf (point-x q) 2) (list (point-x p) (point-x q)))",
      "(1 2)" },
    /* characters, strings, symbols and packages */
    { "(list (char \"abc\" 1) (char-code #\\A) (code-char 955) (length \"four\"))", "(#\\b 65 #\\\xce\xbb 4)" },
    { "(char \"abc\" 3)", "error: CHAR wants an index that is inside what it is given, and 3 is not one" },
    { "(list (string= \"ABC\" 'abc) (string= \"a\" \"b\") (concatenate 'string \"ab\" \"cd\"))", "(T NIL \"abcd\")" },
    { "(format nil \"~A and ~S: ~D~%\" \"a\" \"b\" 42)", "\"a and \\\"b\\\": 42\n\"" },
    { "(format nil \"~Q\")", "error: FORMAT does not know the directive #\\Q in \"~Q\"" },
    { "(list (symbol-name 'foo) (eq (intern \"FOO\") 'foo) (symbolp (gensym)) (symbol-package (gensym)))",
      "(\"FOO\" T T NIL)" },
    { "(intern \"CAR\")", "CAR :INHERITED" },
    { "(find-symbol \"NO-SUCH\")", "NIL NIL" },
    { "(symbol-package 'car)", "#<PACKAGE \"COMMON-LISP\">" },
    { "(defpackage \"SCRATCH\" (:use \"COMMON-LISP\") (:export \"THING\"))", "#<PACKAGE \"SCRATCH\">" },
    { "(list 'scratch:thing (let ((*package* *package*)) (in-package \"SCRATCH\") (package-name *package*)))",
      "(SCRATCH:THING \"SCRATCH\")" },
    { "(error \"~A went wrong\" 'this)", "error: THIS went wrong" },
    { "(load \"nothing.lisp\")", "error: LOAD: the boot volume has no file \"nothing.lisp\" in its \\clara directory" },
};

/* The evaluator, and the language that lisp/boot.lisp builds on it. Then a
 * function that calls itself without end: the evaluator has to say that
 * the stack is full, well before the guard page says it. */
static void eval_selftest(void)
{
    struct lisp_symbol *package = lisp_as_symbol(lisp_roots.package);
    lisp user = package->value, packages = lisp_roots.packages;
    unsigned texts = sizeof evaluations / sizeof evaluations[0], wrong = 0;
    uint64_t count[LISP_TYPES], bytes;
    struct text printed;
    int64_t depth;

    package->value = lisp_make_package("CLARA.SELF-TEST", NULL, lisp_cons(lisp_roots.common_lisp, LISP_NIL));
    for (unsigned i = 0; i < texts; i++) {
        evaluate_text(evaluations[i].text, &printed);
        if (!same(printed.chars, evaluations[i].printed)) {
            kprintf("lisp self-test: %s gave %s, not %s\n", evaluations[i].text, printed.chars,
                    evaluations[i].printed);
            wrong++;
        }
    }
    if (wrong)
        panic("lisp self-test: the evaluator gave %u wrong answers out of %u", wrong, texts);

    evaluate_text("(defvar *depth* 0) (defun dive (n) (setq *depth* n) (+ 1 (dive (+ n 1)))) (dive 1)", &printed);
    if (!same(printed.chars, STACK_FULL))
        panic("lisp self-test: a function that calls itself without end gave %s", printed.chars);
    evaluate_text("*depth*", &printed);
    depth = lisp_fixnum_value(lisp_values.value[0]);
    if (depth < 1000)
        panic("lisp self-test: a function could call itself only %lld deep", (long long)depth);

    /* The packages the texts made go with the self-test's own. */
    package->value = user;
    lisp_roots.packages = packages;

    bytes = lisp_heap_census(count);
    kprintf("lisp: the evaluator passed: %u texts evaluated, and a function called itself %lld deep\n", texts,
            (long long)depth);
    kprintf("lisp: %llu KiB of heap in use: %llu conses, %llu symbols, %llu strings, %llu vectors, %llu packages,\n",
            bytes >> 10, count[LISP_CONS], count[LISP_SYMBOL], count[LISP_STRING], count[LISP_VECTOR],
            count[LISP_PACKAGE]);
    kprintf("lisp:   %llu functions and %llu structures\n", count[LISP_FUNCTION], count[LISP_STRUCTURE]);
}

/* A form from the serial port: evaluated, and its values printed, one to
 * a line, or what went wrong. */
static void answer(lisp form)
{
    if (lisp_evaluate(form))
        for (unsigned i = 0; i < lisp_values.count; i++) {
            lisp_fresh_line();
            lisp_print(lisp_values.value[i], lisp_console_put, NULL);
        }
    else {
        lisp_fresh_line();
        for (const char *s = "error: "; *s; s++)
            lisp_console_put(NULL, *s);
        lisp_princ(lisp_values.value[0], lisp_console_put, NULL);
    }
    lisp_fresh_line();
}

/* Read forms from the serial port, evaluate each and print what it gives,
 * until the input ends. The reader wants its text whole, so lines are
 * gathered until they hold a form: after every line the reader starts
 * again at the first form that is not finished, and as long as that one
 * stops short, another line is asked for. Nothing is held across the wait
 * for a line, which is a safe point. */
static void lisp_listen(void)
{
    static uint8_t text[8192];
    size_t used = 0;

    kprintf("clara: reading from the serial port: a form typed there is evaluated, and Ctrl-D ends it\n");
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
        lisp_console_fresh = 1;

        lisp_reader_init(&r, text, used);
        do {
            unread = r.at;
            status = lisp_read(&r, &form);
            if (status == LISP_READ_OK)
                answer(form);
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

/* The thread of the Lisp world. boot.lisp is the part of the language
 * that is written in Lisp, and the machine is of no use without it. */
static void lisp_thread(void *arg)
{
    uint64_t before[LISP_TYPES], after[LISP_TYPES];
    lisp load = lisp_cons(lisp_symbol_in(lisp_roots.common_lisp, "LOAD", 1),
                          lisp_cons(lisp_string_from_utf8("boot.lisp", 9), LISP_NIL));

    (void)arg;
    lisp_eval_start();
    lisp_heap_census(before);
    if (!lisp_evaluate(load)) {
        kputs("lisp: ");
        lisp_princ(lisp_values.value[0], lisp_console_put, NULL);
        kputc('\n');
        panic("lisp: boot.lisp did not load, and without it there is no Lisp world to start");
    }
    lisp_heap_census(after);
    kprintf("lisp: boot.lisp is loaded, with %llu functions and macros in Lisp\n",
            after[LISP_FUNCTION] - before[LISP_FUNCTION]);
    eval_selftest();
    lisp_listen();
}

void lisp_run(void)
{
    struct thread *t = thread_create("lisp", lisp_thread, NULL, LISP_STACK_SIZE);

    if (!t)
        panic("lisp: no memory for the stack of the Lisp thread");
    thread_join(t);
}
