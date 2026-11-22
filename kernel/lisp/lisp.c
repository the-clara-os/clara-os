/* The Lisp runtime's beginning, its self-tests, and what the first thread
 * of the Lisp world does. The world is an image, when the boot volume had
 * one that this kernel can take (image.c); and otherwise it is made here,
 * out of the files of lisp/, with the runtime tested on the way. Then the
 * console, the drivers and the listener are started, which reads forms,
 * evaluates them and prints what they give. */
#include "lisp.h"

#define IMAGE "clara.image" /* the file of \clara that is a world, saved */

static int g_resumed; /* the world is an image's: it was made on the boot that saved it, and not on this one */
static const struct boot_info *g_boot; /* what the handoff learned of the starts before this one */

/* The image among the files that the boot handoff read, when there is
 * one, taken out of their list: it is no file for LOAD to find. Its name
 * is found in letters of either case, as a file's is. */
static struct boot_file *take_image(struct boot_info *bi)
{
    for (struct boot_file **at = &bi->files; *at; at = &(*at)->next) {
        struct boot_file *f = *at;
        size_t i = 0;

        while (f->name[i] && IMAGE[i] && (f->name[i] | 0x20) == IMAGE[i])
            i++;
        if (!f->name[i] && !IMAGE[i]) {
            *at = f->next;
            return f;
        }
    }
    return NULL;
}

void lisp_init(struct boot_info *bi)
{
    struct boot_file *image = take_image(bi);

    g_boot = bi;
    lisp_heap_init();
    kprintf("lisp: objects are tagged 64-bit words, in a heap at %p that begins with NIL\n",
            (void *)(uintptr_t)VM_HEAP_BASE);
    /* A world that did not come to its prompt the last time is not started a second time: the
     * handoff did not read it (boot.c), and the world is made of the files, as on a new machine. */
    if (bi->image_passed_over)
        kprintf("lisp: clara.image is passed over: the start before this one did not come to its prompt\n");
    if (image) {
        g_resumed = lisp_image_load(image);
        /* What it held is in the heap by now, or of no use: the page frames it was read into are free. */
        pmm_free((uint64_t)(uintptr_t)image,
                 ((uint64_t)(image->data - (const uint8_t *)image) + image->size + PAGE_SIZE - 1) / PAGE_SIZE);
    }
    if (!g_resumed)
        lisp_symbols_init();
    lisp_eval_init(bi->files);
    lisp_unsafe_init(&bi->fb);
}

/* (start-state): what the kernel knows of this start and of the ones
 * before it, for the Lisp that sees to the system as a whole
 * (lisp/system.lisp), as a list of names and values: :SYSTEM, the name of
 * this system; :RESUMED, whether the world is one that was saved, and not
 * made on this start; :STARTS, how many starts in a row before this one
 * did not come to a prompt; :TOKEN, the sixteen digits that the handoff
 * wrote into \clara\starts on the volume that the machine was started
 * from, or NIL when it could write nothing; :TRIAL, whether this system is
 * being tried, with the one before it still in place; :FAILED, the name of
 * a system that was tried and did not come to its prompt, or NIL; and
 * :PASSED-OVER, whether a saved world was there and was not started. */
LISP_PRIMITIVE(lisp_p_start_state)
{
    static const char digits[] = "0123456789abcdef";
    lisp t = lisp_roots.t, state = LISP_NIL;
    char token[16];

    (void)argc;
    (void)argv;
#define FACT(name, value) state = lisp_cons(lisp_symbol_in(lisp_roots.keyword, name, 1), lisp_cons(value, state))
    FACT("PASSED-OVER", g_boot->image_passed_over ? t : LISP_NIL);
    FACT("FAILED", g_boot->failed[0] ? lisp_string_from_utf8(g_boot->failed, strlen(g_boot->failed)) : LISP_NIL);
    FACT("TRIAL", g_boot->trial ? t : LISP_NIL);
    for (unsigned i = 0; i < 16; i++)
        token[i] = digits[g_boot->token >> (60 - 4 * i) & 15];
    FACT("TOKEN", g_boot->token ? lisp_string_from_utf8(token, sizeof token) : LISP_NIL);
    FACT("STARTS", lisp_fixnum((int64_t)g_boot->starts));
    FACT("RESUMED", g_resumed ? t : LISP_NIL);
    FACT("SYSTEM", lisp_string_from_utf8(clara_system, strlen(clara_system)));
#undef FACT
    return state;
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

/* A form of the substrate's own, read in COMMON-LISP-USER whatever package
 * names are read in just now: a world that was saved may have been left in
 * any. */
static lisp own_form(const char *text)
{
    struct lisp_symbol *package = lisp_as_symbol(lisp_roots.package);
    lisp current = package->value, form;

    package->value = lisp_roots.user;
    form = read_one(text);
    package->value = current;
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
    /* what is there on one Lisp and not on another */
    { "(a #+clara b #-clara c #+(or nope (not clara)) d #-(and clara nope) e)", "(A B E)" },
    { "#+nope (sb-thread:x #\\nosuchname 1.5 no:where \"s\") a", "A" },
    { "#-nope a", "A" },
    { "(#+nope a)", "NIL" },
    { "#+(and) #+(or) a b", "B" },
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
    { "#+", LISP_READ_SHORT },
    { "#+clara", LISP_READ_SHORT },
    { "#-nope (a", LISP_READ_SHORT },
    { "(a #+clara)", LISP_READ_ERROR },
    { "#+ ) a", LISP_READ_ERROR },
    { "#+nope #.(a) b", LISP_READ_ERROR }, /* what is left out still has to be syntax that the reader knows */
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

/* The reader and the printer, in a world that this boot has made. One
 * that came from an image is somebody's, with whatever they made of it,
 * and is not the place to try what a new world has to be like: the
 * runtime was tested on the boot that made it. */
void lisp_selftest(void)
{
    struct lisp_symbol *package = lisp_as_symbol(lisp_roots.package);
    lisp user = package->value, scratch, form, key, foo;
    struct text printed, again;
    struct lisp_reader r;
    unsigned line = 0, column = 0;

    if (g_resumed)
        return;

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
 * values with a space between them, or the error. With a compiler, which
 * is the function that evaluates a form by compiling it
 * (CLARA.COMPILER:EVALUATE, lisp/compiler.lisp), each form goes to that:
 * what is written down is then what compiled code makes of the text. */
static void evaluate_text(const char *source, struct text *printed, lisp compiler)
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
        if (compiler) /* (evaluate 'form): made here and handed over at once */
            form = lisp_cons(compiler, lisp_cons(lisp_cons(lisp_roots.quote, lisp_cons(form, LISP_NIL)), LISP_NIL));
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
 * from the macros on, lisp/boot.lisp has its share in the answers.
 *
 * The compiler is held to the same texts and the same answers
 * (compiler_selftest): a compiled function means what the evaluator makes
 * of its forms. Where the two differ all the same, the text is in the
 * table after this one, with what compiled code gives. */
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
    { "(list (defconstant +two+ 2) +two+)", "(+TWO+ 2)" },
    { "(defconstant +two+ 3)", "error: +TWO+ is a constant already, and its value is 2" },
    { "(defun if (x) x)", "error: IF is a special operator, and stays one" },
    { "(defmacro if (x) x)", "error: IF is a special operator, and stays one" },
    /* a package that is deleted is found no more, and is a package still; the ones that are needed stay */
    { "(let ((p (make-package \"CLARA.GONE\")))"
      "  (list (delete-package p) (find-package \"CLARA.GONE\") (delete-package p) (packagep p)"
      "        (if (member p (list-all-packages)) 'listed) (if (member (find-package \"CLARA\") (list-all-packages)) 'listed)))",
      "(T NIL NIL T NIL LISTED)" },
    { "(let ((p (make-package \"CLARA.GONE\"))) (intern \"KEPT\" p) (delete-package \"CLARA.GONE\") (cl::%collect)"
      "  (list (find-symbol \"KEPT\" p) (symbol-name (intern \"KEPT\" (make-package \"CLARA.GONE\"))) (delete-package \"CLARA.GONE\")))",
      "(CLARA.GONE::KEPT \"KEPT\" T)" },
    { "(progn (make-package \"CLARA.LEANS\" :use (list (make-package \"CLARA.GONE\")))"
      "  (list (handler-case (delete-package \"CLARA.GONE\") (error (c) (princ-to-string c)))"
      "        (delete-package \"CLARA.LEANS\") (delete-package \"CLARA.GONE\")))",
      "(\"the package CLARA.GONE is used by the package CLARA.LEANS, and is not deleted before that one\" T T)" },
    { "(delete-package \"COMMON-LISP\")",
      "error: the package COMMON-LISP is one that the system cannot do without, and is not deleted" },
    { "(delete-package \"CLARA.NEVER\")", "error: there is no package named CLARA.NEVER" },
    /* every symbol that a package has by name, its own and the ones it has of the packages it uses */
    { "(let* ((lent (make-package \"CLARA.LENT\")) (p (make-package \"CLARA.WALKED\" :use (list lent))) (names nil) (n 0))"
      "  (export (intern \"OFFERED\" lent) lent) (intern \"HIDDEN\" lent) (intern \"OWN\" p) (export (intern \"SHOWN\" p) p)"
      "  (do-symbols (s p) (push (symbol-name s) names))"
      "  (do-symbols (s \"CLARA.WALKED\") (setq n (+ n 1)))"
      "  (list (sort names #'string-lessp) n (do-symbols (s lent 'done))"
      "        (let ((*package* lent) (m 0)) (do-symbols (s) (setq m (+ m 1))) m)"
      "        (do-symbols (s p) (when (eq (symbol-package s) lent) (return (symbol-name s))))"
      "        (delete-package p) (delete-package lent)))",
      "((\"OFFERED\" \"OWN\" \"SHOWN\") 3 DONE 2 \"OFFERED\" T T)" },
    { "(do-symbols (s \"CLARA.NEVER\"))", "error: there is no package named CLARA.NEVER" },
    { "(list char-code-limit (char-code (code-char (1- char-code-limit))))", "(1114112 1114111)" },
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
    /* a list taken apart, as a macro's arguments are */
    { "(destructuring-bind (a (b &optional (c 5)) &rest d) '(1 (2) 3 4) (list a b c d))", "(1 2 5 (3 4))" },
    { "(destructuring-bind (first second . others) (list 1 2 3 4) (list first second others))", "(1 2 (3 4))" },
    { "(destructuring-bind (&whole all &key x (y (+ x 6))) '(:x 1) (values x y all))", "1 7 (:X 1)" },
    { "(let ((n 0)) (destructuring-bind (a b) (progn (cl::%collect) (list 1 (list 2))) (setq n (+ n a)) (cl::%collect) (list n b)))",
      "(1 (2))" },
    { "(progn (defvar *apart* 1) (list (destructuring-bind (*apart* &optional (b *apart*)) '(2) (list *apart* b)) *apart*))",
      "((2 2) 1)" },
    { "(destructuring-bind (a b) '(1) (list a b))", "error: DESTRUCTURING-BIND got too few arguments" },
    { "(destructuring-bind (a) '(1 2) a)", "error: DESTRUCTURING-BIND got too many arguments" },
    { "(destructuring-bind (a (b)) '(1 2) (list a b))", "error: DESTRUCTURING-BIND got too few arguments" },
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
    { "(flet ((swap (a b) (list b a))) (swap 1 2))", "(2 1)" },
    { "(funcall (lambda (x) \"documentation\" (declare (ignorable x)) (+ x 1)) 2)", "3" },
    { "(defun swapped (a b) (swap a b) (list a b)) (list (swapped 1 2) (swapped 3 4))", "((2 1) (4 3))" },
    { "(defmacro show (form) `(list ',form ,form)) (defun shows () (show (when t 1))) (list (shows) (shows))",
      "(((WHEN T 1) 1) ((WHEN T 1) 1))" },
    { "(eval '(+ 1 2))", "3" },
    { "(let ((form (list 'progn (list 'when t 1)))) (list (eval form) form))", "(1 (PROGN (WHEN T 1)))" },
    /* the language in boot.lisp: control */
    { "(cond ((= 1 2) 'a) ((= 1 1) 'b) (t 'c))", "B" },
    { "(cond ((= 1 2) 'a) (7))", "7" },
    { "(list (and) (and 1 2 3) (and 1 nil 3) (or) (or nil 2 3) (or nil nil))", "(T 3 NIL NIL 2 NIL)" },
    { "(list (when (= 1 1) 1 2) (unless (= 1 1) 1))", "(2 NIL)" },
    { "(case 2 (1 'one) ((2 3) 'few) (t 'many))", "FEW" },
    { "(case 'x (y 1) (otherwise 2))", "2" },
    /* a variable that is read, set and read again within one form: each reading is of its own moment */
    { "(let ((x 1) (y 2)) (list x (setq x 5) x (+ x (setq x 7)) y (setq y (+ y x)) y))", "(1 5 5 12 2 9 9)" },
    /* how many values there are after a function that has an instruction of its own, wherever its value goes
     * next: FLOOR has left word of two each time */
    { "(let ((x nil) (v (vector 1 2))) (list (progn (floor 7 2) (multiple-value-list (setq x (car '(a b)))))"
      " (progn (floor 7 2) (multiple-value-list (car '(c)))) (progn (floor 7 2) (multiple-value-list (+ 1 2)))"
      " (progn (floor 7 2) (multiple-value-list (svref v 1))) (progn (floor 7 2) (multiple-value-list (if x (eq x 'a) 'none)))"
      " (progn (floor 7 2) (multiple-value-list (cons 1 2))) (progn (floor 7 2) (multiple-value-list (< 1 2)))))",
      "((A) (C) (3) (2) (T) ((1 . 2)) (T))" },
    /* numbers below zero that are written into a function, compared with */
    { "(let ((n -3)) (list (< n -2) (< n -4) (= n -3) (> n -3) (<= -3 n) (if (>= n -1) 'high 'low)"
      " (if (= n -3) 'same 'other) (+ n -1) (- n -1)))",
      "(T NIL T NIL T LOW SAME -4 -2)" },
    /* keys that EQ tells apart, a clause to themselves or several to a clause, and keys that only EQL does */
    { "(list (case 'c ((a b) 1) ((c d) 2) (t 3)) (case 'd ((a b) 1) ((c d) 2)) (case 'e ((a b) 1) ((c d) 2))"
      " (case nil ((nil) 'none) (t 'some)) (case nil (nil 'never) (t 'some)))",
      "(2 2 NIL NONE SOME)" },
    { "(list (case #\\b (#\\a 1) ((#\\b #\\c) 2)) (case 7 ((1 #\\a) 'mixed) (7 'seven)) (case \"a\" (\"a\" 'same) (t 'other))"
      " (case -3 ((1 2) 'plus) ((-3 -4) 'minus)))",
      "(2 SEVEN OTHER MINUS)" },
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
    { "(load \"nothing.lisp\")",
      "error: LOAD finds no file \"nothing.lisp\": no disk has it, and \\clara had none of that name at boot" },
    /* a file with a form that fails (kernel/lisp/self-test.lisp) */
    { "(load \"self-test.lisp\")",
      "error: CAR wants a list, and NOT-A-LIST is not one, in the form at line 15 of self-test.lisp" },
    { "(list (package-name *package*) clara.loaded::*reached*)",
      "(\"CLARA.SELF-TEST\" CLARA.LOADED::THE-FORM-BEFORE)" },
    /* the same file as the bytes that the handoff read: it begins with a comment */
    { "(multiple-value-bind (at bytes) (clara.unsafe:system-file \"SELF-TEST.lisp\")"
      " (list (code-char (clara.unsafe:memory-8 at)) (< 100 bytes 10000)))",
      "(#\\; T)" },
    { "(list (clara.unsafe:system-file \"no such file\") (clara.unsafe:system-file \"self-test\")"
      " (clara.unsafe:system-file \"self-test.lisp.\"))",
      "(NIL NIL NIL)" },
    /* the same file by its whole name: what the handoff read is what \clara held */
    { "(cl::%load \"/Clara/self-test.lisp\")",
      "error: CAR wants a list, and NOT-A-LIST is not one, in the form at line 15 of self-test.lisp" },
    { "(cl::%load \"/clara/\")",
      "error: LOAD finds no file \"/clara/\": no disk has it, and \\clara had none of that name at boot" },
    /* a text that is loaded, as LOAD does with a file from a disk */
    { "(cl::%load-text \"(defvar *from-a-text* 'the-form-before)\n(car 'not-a-list)\n(setq *from-a-text* nil)\" \"a text\")",
      "error: CAR wants a list, and NOT-A-LIST is not one, in the form at line 2 of a text" },
    { "*from-a-text*", "THE-FORM-BEFORE" },
    { "(handler-case (cl::%load-text \"(list 1 2)\n\n(car 'x)\" \"a text\") (error (c) (princ-to-string c)))",
      "\"CAR wants a list, and X is not one, in the form at line 3 of a text\"" },
    { "(handler-case (cl::%load-text \"(handler-case (car 'x) (error () 'handled-inside))\" \"a text\") (error () 'not-inside))",
      "T" },
    { "(cl::%load-text \"(in-package \\\"COMMON-LISP\\\") (defvar clara.loaded::*text* (package-name *package*))\" \"x\")",
      "T" },
    { "(list (package-name *package*) clara.loaded::*text*)", "(\"CLARA.SELF-TEST\" \"COMMON-LISP\")" },
    /* strings whatever the case of their letters, and SORT */
    { "(list (string-equal \"Boot.Lisp\" \"BOOT.lisp\") (string-equal \"a\" \"ab\") (string-equal #\\a 'a))",
      "(T NIL T)" },
    { "(list (string-lessp \"abc\" \"ABD\") (string-lessp \"b\" \"A\") (string-lessp \"ab\" \"abc\") (string-lessp \"x\" \"X\"))",
      "(2 NIL 2 NIL)" },
    { "(string-equal \"a\" 5)", "error: STRING-EQUAL wants a string, a symbol or a character, and 5 is not one" },
    { "(sort '(3 1 2) #'<)", "(1 2 3)" },
    { "(sort (list \"pci\" \"Boot\" \"console\" \"FAT\") #'string-lessp)", "(\"Boot\" \"console\" \"FAT\" \"pci\")" },
    { "(sort '((2 . a) (1 . b) (2 . c) (1 . d)) #'< :key #'car)", "((1 . B) (1 . D) (2 . A) (2 . C))" },
    { "(list (sort nil #'<) (sort '(7) #'<))", "(NIL (7))" },
    { "(sort (vector 2 1) #'<)", "error: SORT takes a list, and not #(2 1) yet" },
    /* files: names and patterns, and what can be refused before any file system is asked */
    { "(list (cl::%fits \"*.lisp\" \"boot.LISP\" 0 0) (cl::%fits \"b*t*\" \"boot.lisp\" 0 0) (cl::%fits \"*\" \"\" 0 0)"
      " (cl::%fits \"*.lisp\" \"lisp\" 0 0) (cl::%fits \"boot\" \"boot.lisp\" 0 0))",
      "(T T T NIL NIL)" },
    { "(list (multiple-value-list (cl::%split-name \"/clara/boot.lisp\")) (multiple-value-list (cl::%split-name \"boot.lisp\"))"
      " (cl::%plain-name \"/clara//\") (cl::%plain-name \"/\"))",
      "((\"/clara/\" \"boot.lisp\") (\"\" \"boot.lisp\") \"/clara\" \"\")" },
    { "(open \"/clara/boot.lisp\" :direction :io)",
      "error: OPEN: a file is opened for :INPUT or for :OUTPUT, and not for :IO" },
    { "(open 'boot)", "error: the name of a file is a string, and BOOT is not one" },
    { "(delete-file 'boot)", "error: the name of a file is a string, and BOOT is not one" },
    { "(let ((in (make-string-input-stream \"a line\"))) (list (close in) (read-line in nil 'closed)))", "(T CLOSED)" },
    { "(let ((in (make-string-input-stream \"a line\"))) (list (close in :abort t) (read-line in nil 'closed)))",
      "(T CLOSED)" },
    /* more arguments than the 255 that stand for "any number" in the tables, and the strings of a list as
     * one string, which is what a stream that was written to hands over, however many they are */
    { "(let ((numbers '(1 2 3 4 5)) (parts '(\"ab\" \"c\")))"
      " (dotimes (i 8) (setq numbers (append numbers numbers) parts (append parts parts)))"
      " (list (length numbers) (apply #'+ numbers) (length (apply #'list numbers)) (length (cl::%join parts))))",
      "(1280 3840 1280 768)" },
    { "(list (cl::%join nil) (cl::%join '(\"one\")) (cl::%join '(\"a\" \"\" \"b\" \"c\")))", "(\"\" \"one\" \"abc\")" },
    { "(cl::%join '(\"a\" 5))", "error: %JOIN wants a list of strings, and (\"a\" 5) is not one" },
    { "(length (with-output-to-string (s) (dotimes (i 12) (write-string \"abc\" s) (write-char #\\d s))))", "48" },
    /* letters in capitals and in small letters, as far as ASCII has them */
    { "(list (string-upcase \"Hello, world!\") (string-downcase \"Hello\") (char-upcase #\\a) (char-downcase #\\A)"
      " (string-upcase 'abc) (string-downcase #\\Q) (string-upcase \"caf\xc3\xa9\"))",
      "(\"HELLO, WORLD!\" \"hello\" #\\A #\\a \"ABC\" \"q\" \"CAF\xc3\xa9\")" },
    { "(mapcar #'string-upcase (list \"Hello\" \"world!\"))", "(\"HELLO\" \"WORLD!\")" },
    { "(string-upcase 5)", "error: STRING-UPCASE wants a string, a symbol or a character, and 5 is not one" },
    /* a string of so many characters, all the same: the character of code 0 when none is named */
    { "(list (make-string 5 :initial-element #\\a) (make-string 0) (length (make-string 3))"
      " (char-code (char (make-string 2) 1)) (make-string 2 :initial-element #\\\xce\xbb))",
      "(\"aaaaa\" \"\" 3 0 \"\xce\xbb\xce\xbb\")" },
    { "(let ((s (make-string 2 :initial-element #\\-)) (r (make-string 2 :initial-element #\\-)))"
      " (setf (char s 0) #\\x) (list s r))",
      "(\"x-\" \"--\")" },
    { "(make-string 2 :initial-element 5)", "error: %MAKE-STRING wants a character, and 5 is not one" },
    { "(list (handler-case (make-string -1) (error (c) (princ-to-string c)))"
      " (handler-case (make-string 4294967296) (error () 'refused))"
      " (handler-case (make-string 4000000000) (storage-condition (c) (princ-to-string c))))",
      "(\"%MAKE-STRING wants an index that is inside what it is given, and -1 is not one\" REFUSED"
      " \"the heap is full: there is no room for an object that large\")" },
    { "(make-string 2 :element-type 'character)",
      "error: #<FUNCTION MAKE-STRING> does not take the keyword argument :ELEMENT-TYPE" },
    /* what GENSYM counts with is a variable */
    { "(let ((*gensym-counter* 41)) (list (symbol-name (gensym)) (symbol-name (gensym)) *gensym-counter*))",
      "(\"G41\" \"G42\" 43)" },
    { "(let ((*gensym-counter* 'x)) (gensym))",
      "error: *GENSYM-COUNTER* is X, and GENSYM counts with an integer that is not negative" },
    /* memory as text */
    { "(let ((page (clara.unsafe:allocate-memory 1)))"
      " (setf (clara.unsafe:memory-32 page) #x21bbce68)"
      " (prog1 (list (clara.unsafe:memory-string page 4) (clara.unsafe:memory-string page 0)"
      "              (handler-case (clara.unsafe:memory-string page 2) (error () 'not-text)))"
      "   (clara.unsafe:free-memory page 1)))",
      "(\"h\xce\xbb!\" \"\" NOT-TEXT)" },
    /* and text as memory */
    { "(let ((page (clara.unsafe:allocate-memory 1)) (text \"h\xce\xbb\xe2\x98\x80\xf0\x9f\x98\x80!\"))"
      " (prog1 (list (clara.unsafe:string-bytes text) (clara.unsafe:string-memory text page)"
      "              (clara.unsafe:memory-string page 11) (clara.unsafe:memory-8 (+ page 1)) (clara.unsafe:memory-8 (+ page 10))"
      "              (clara.unsafe:string-bytes \"\") (clara.unsafe:string-memory \"\" page))"
      "   (clara.unsafe:free-memory page 1)))",
      "(11 11 \"h\xce\xbb\xe2\x98\x80\xf0\x9f\x98\x80!\" 206 33 0 0)" },
    { "(handler-case (clara.unsafe:string-memory \"text\" 0) (error () 'nowhere))", "NOWHERE" },
    /* the heap as an image of it: how it begins, and that it is whole words in whole page frames */
    { "(multiple-value-bind (memory bytes pages) (clara.unsafe:heap-image)"
      " (prog1 (list (clara.unsafe:memory-string memory 8) (mod bytes 8) (- pages (floor (+ bytes 4095) 4096))"
      "              (> bytes 100000))"
      "   (clara.unsafe:free-memory memory pages)))",
      "(\"CLARAIMG\" 0 0 T)" },
    /* conditions */
    { "(handler-case (error \"~A went wrong\" 'this) (error (c) (list 'caught (format nil \"~A\" c))))",
      "(CAUGHT \"THIS went wrong\")" },
    { "(handler-case (+ 1 2) (error () 'never))", "3" },
    { "(handler-case (values 1 2) (error () 'never))", "1 2" },
    { "(handler-case (floor 7 2) (error () 'never) (:no-error (q r) (list r q)))", "(1 3)" },
    { "(handler-case (car 5) (type-error (c) (type-error-datum c)))", "5" },
    { "(handler-case no-such-variable (unbound-variable (c) (cell-error-name c)))", "NO-SUCH-VARIABLE" },
    { "(handler-case (no-such-function) (undefined-function (c) (cell-error-name c)))", "NO-SUCH-FUNCTION" },
    { "(handler-case (/ 1 0) (division-by-zero () 'zero) (error () 'other))", "ZERO" },
    { "(handler-case (/ 1 0) (arithmetic-error () 'arithmetic))", "ARITHMETIC" },
    { "(handler-case (/ 1 0) (type-error () 'no) (error () 'yes) (t () 'too-late))", "YES" },
    { "(handler-case (handler-case (/ 1 0) (type-error () 'inner)) (error () 'outer))", "OUTER" },
    { "(handler-case (handler-case (/ 1 0) (error () (car 5))) (type-error () 'from-the-clause))", "FROM-THE-CLAUSE" },
    { "(handler-case (car) (program-error () 'program))", "PROGRAM" },
    { "(handler-case (go nowhere) (control-error () 'control))", "CONTROL" },
    { "(defun deeper (n) (+ 1 (deeper n))) (handler-case (deeper 1) (error () 'an-error) (storage-condition () 'full))",
      "FULL" },
    { "(handler-case (make-array 4000000000) (storage-condition (c) (format nil \"~A\" c)))",
      "\"the heap is full: there is no room for an object that large\"" },
    { "(handler-case 1 (no-such-type () 2))",
      "error: HANDLER-CASE has a clause for NO-SUCH-TYPE, which is not the name of a type of condition" },
    { "(error 'no-such-type)", "error: NO-SUCH-TYPE is not the name of a type of condition" },
    { "(error 5)", "error: 5 is not a condition, nor the name of a type of one, nor a string to make one of" },
    { "(define-condition low-fuel (error) ((left :initarg :left :reader fuel-left)"
      " (unit :initform 'litres :reader fuel-unit)))",
      "LOW-FUEL" },
    { "(handler-case (error 'low-fuel :left 3) (low-fuel (c) (list (fuel-left c) (fuel-unit c))))", "(3 LITRES)" },
    { "(error 'low-fuel :left 3)", "error: #<LOW-FUEL :LEFT 3 :UNIT LITRES>" },
    { "(error 'low-fuel :right 3)",
      "error: a condition of the type LOW-FUEL has no slot that :RIGHT is the argument for" },
    { "(fuel-left (make-condition 'low-fuel))", "error: the slot LEFT of #<LOW-FUEL :UNIT LITRES> has no value" },
    { "(handler-case (error (make-condition 'low-fuel :left 2)) (t (c) (fuel-left c)))", "2" },
    { "(handler-case (signal 'low-fuel :left 1) (condition (c) (fuel-left c)))", "1" },
    { "(signal 'low-fuel :left 1)", "NIL" },
    { "(handler-case (warn \"~A is low\" 'fuel) (warning (c) (format nil \"~A\" c)))", "\"FUEL is low\"" },
    { "(let ((c (make-condition 'simple-error :format-control \"~A and ~A\" :format-arguments '(1 2))))"
      " (list (format nil \"~A\" c) (simple-condition-format-control c) (simple-condition-format-arguments c)))",
      "(\"1 and 2\" \"~A and ~A\" (1 2))" },
    { "(handler-case (error \"~A\" 1) (simple-error (c) (simple-condition-format-arguments c)))", "(1)" },
    { "(multiple-value-list (ignore-errors (car 5)))",
      "(NIL #<TYPE-ERROR \"CAR wants a list, and 5 is not one\">)" },
    { "(ignore-errors (values 1 2))", "1 2" },
    { "(define-condition odd () () (:report \"odd\"))", "error: DEFINE-CONDITION with :REPORT, which is not here yet" },
    { "(handler-case (load \"self-test.lisp\") (type-error (c) (list (type-error-datum c) (package-name *package*))))",
      "(CLARA.LOADED::NOT-A-LIST \"CLARA.SELF-TEST\")" },
    { "(type-error-expected-type (make-condition 'type-error :datum 1))",
      "error: the slot EXPECTED-TYPE of #<TYPE-ERROR :DATUM 1> has no value" },
    /* unwind-protect */
    { "(let ((log nil)) (list (unwind-protect 1 (push 'cleaned log)) log))", "(1 (CLEANED))" },
    { "(multiple-value-list (unwind-protect (values 1 2) (values 3 4)))", "(1 2)" },
    { "(let ((log nil)) (list (block b (unwind-protect (return-from b 1) (push 'cleaned log))) log))",
      "(1 (CLEANED))" },
    { "(multiple-value-list (catch 'c (unwind-protect (throw 'c (values 1 2)) (values 3 4))))", "(1 2)" },
    { "(let ((n 0)) (tagbody (unwind-protect (go out) (setq n (+ n 1))) out) n)", "1" },
    { "(block b (unwind-protect (return-from b 1) (return-from b 2)))", "2" },
    { "(let ((log nil)) (list (handler-case (unwind-protect (error \"oops\") (push 'cleaned log)) (error () 'handled))"
      " log))",
      "(HANDLED (CLEANED))" },
    { "(let ((log nil)) (handler-case (unwind-protect (/ 1 0) (push 1 log) (car 5)) (type-error () (list 'second log))))",
      "(SECOND (1))" },
    { "(let ((log nil)) (list (handler-case (let ((*level* 9)) (unwind-protect (error \"x\") (push *level* log)))"
      " (error () *level*)) log))",
      "(6 (9))" },
    { "(handler-case (unwind-protect (error \"~A\" (list 1 2)) (list 3)) (error (c) (format nil \"~A\" c)))",
      "\"(1 2)\"" },
    { "(defvar *log* nil) (unwind-protect (error \"to the top\") (push 'cleaned *log*))", "error: to the top" },
    { "*log*", "(CLEANED)" },
    /* the collector, in the middle of things: what is held only by the evaluator has to come through */
    { "(let ((keep (list 1 2 3))) (cl::%collect) keep)", "(1 2 3)" },
    { "(let ((f (let ((n 10)) (lambda () (setq n (+ n 1)))))) (cl::%collect) (funcall f) (cl::%collect) (funcall f))",
      "12" },
    { "(list (list 1 2) (progn (cl::%collect) (list 3)) (list 4))", "((1 2) (3) (4))" },
    { "(progn (setq *level* (list 'old)) (let ((*level* 1)) (cl::%collect)) (prog1 *level* (setq *level* 6)))",
      "(OLD)" },
    { "(multiple-value-list (multiple-value-prog1 (values (list 1) (list 2)) (cl::%collect)))", "((1) (2))" },
    { "(multiple-value-list (catch 'c (unwind-protect (throw 'c (values (list 1) (list 2))) (cl::%collect))))",
      "((1) (2))" },
    { "(handler-case (unwind-protect (error 'low-fuel :left (list 1 2)) (cl::%collect)) (low-fuel (c) (fuel-left c)))",
      "(1 2)" },
    { "(handler-case (unwind-protect (error 'low-fuel :left (list 1 2)) (ignore-errors (car 5)) (cl::%collect))"
      " (low-fuel (c) (fuel-left c)))",
      "(1 2)" },
    { "(defun redefined () (defun redefined () 'new) (cl::%collect) 'old) (list (funcall 'redefined) (redefined))",
      "(OLD NEW)" },
    { "(defmacro split (&optional ((c &optional (e (progn (cl::%collect) 'e)) &rest d) (list 1))) `'(,c ,e ,d)) (split)",
      "(1 E NIL)" },
    { "(let ((v (make-array 3 :initial-element (list 'x)))) (cl::%collect) (let ((s (make-point :x v))) (cl::%collect)"
      " (point-x s)))",
      "#((X) (X) (X))" },
    { "(let ((l nil)) (dotimes (i 600) (push (list i (format nil \"~D\" i)) l)) (cl::%collect)"
      " (list (length l) (car l) (car (last l))))",
      "(600 (599 \"599\") (0 \"0\"))" },
    /* streams: the printer makes a string, and a stream is where it goes */
    { "(with-output-to-string (s) (write-string \"a\" s) (prin1 \"b\" s) (princ \"c\" s) (write-char #\\d s) (terpri s)"
      " (format s \"~D~A\" 1 'e))",
      "\"a\\\"b\\\"cd\n1E\"" },
    { "(let ((s (make-string-output-stream))) (list (fresh-line s) (progn (write-string \"x\" s) (fresh-line s))"
      " (fresh-line s) (get-output-stream-string s) (get-output-stream-string s)))",
      "(NIL T NIL \"x\n\" \"\")" },
    { "(with-output-to-string (*standard-output*) (print 'a) (write-line \"b\") (format t \"~S\" \"c\"))",
      "\"\nA b\n\\\"c\\\"\"" },
    { "(list (prin1-to-string \"a\") (princ-to-string \"a\") (streamp *standard-output*) (streamp 5))",
      "(\"\\\"a\\\"\" \"a\" T NIL)" },
    { "(write-string \"x\" 5)", "error: 5 is not a stream that can be written to" },
    { "(format nil 5)", "error: FORMAT wants a string to go by, and 5 is not one" },
    { "(with-output-to-string (*standard-output*) (warn \"~A is low\" 'fuel))", "\"warning: FUEL is low\n\"" },
    { "(let ((s (make-string-input-stream (format nil \"one~%two~%~%four\"))))"
      " (list (read-line s) (read-line s) (read-line s) (read-line s) (read-line s nil 'end)))",
      "(\"one\" \"two\" \"\" \"four\" END)" },
    { "(read-line (make-string-input-stream \"\"))", "error: #<END-OF-FILE>" },
    /* the reader, from Lisp */
    { "(read-from-string \"(a b) c\")", "(A B) 5" },
    { "(read-from-string \"(a b) c\" t nil :start 5)", "C 7" },
    { "(read-from-string \" ; nothing\" nil 'none)", "NONE 10" },
    { "(read-from-string \"\")", "error: #<END-OF-FILE>" },
    { "(handler-case (read-from-string \"(a b\") (end-of-file (c) (format nil \"~A\" c)))",
      "\"the text ends inside a list\"" },
    { "(handler-case (read-from-string \"caf\xc3\xa9 (a . )\" t nil :start 4) (reader-error (c) (format nil \"~A\" c)))",
      "\"no form between the dot and what follows it, at line 1, column 11\"" },
    { "(handler-case (read-from-string \"(a b\") (reader-error () 'wrong) (error () 'an-error))", "AN-ERROR" },
    { "(read-from-string \"#+clara here #-clara there\")", "HERE 12" },
    { "(list (subseq \"hello\" 1 3) (subseq \"hello\" 2) (subseq '(a b c d) 1 3) (subseq '(a b c) 1))",
      "(\"el\" \"llo\" (B C) (B C))" },
    { "(subseq \"abc\" 2 5)", "error: \"abc\" has no part from 2 to 5" },
    { "(handler-case (error 'clara:keyboard-interrupt) (error () 'an-error) (clara:keyboard-interrupt () 'a-break))",
      "A-BREAK" },
    /* threads: each has stacks of its own, and its own bindings of the special variables */
    { "(defvar *threads* (length (clara:all-threads))) (clara:thread-name (clara:current-thread))", "\"listener\"" },
    { "(clara:join-thread (clara:make-thread (lambda () (+ 1 2))))", "3" },
    { "(multiple-value-list (clara:join-thread (clara:make-thread (lambda () (values 1 2)))))", "(1 2)" },
    { "(defun five () 5) (clara:join-thread (clara:make-thread 'five))", "5" },
    { "(let ((thread (clara:make-thread (lambda () 1) :name \"one\"))) (clara:join-thread thread)"
      " (list thread (clara:thread-alive-p thread) (clara:threadp thread) (clara:threadp 1)))",
      "(#<THREAD \"one\"> NIL T NIL)" },
    { "(defvar *mine* 'everybodys)"
      " (let ((*mine* 'bound)) (list (clara:join-thread (clara:make-thread (lambda () *mine*))) *mine*))",
      "(EVERYBODYS BOUND)" },
    { "(let ((*mine* 'bound)) (clara:join-thread (clara:make-thread (lambda () (setq *mine* 'set-by-a-thread)))) *mine*)",
      "BOUND" },
    { "*mine*", "SET-BY-A-THREAD" },
    { "(let* ((bound (clara:make-event)) (seen (clara:make-event))"
      " (thread (clara:make-thread (lambda () (let ((*mine* 'theirs))"
      " (clara:signal-event bound) (clara:wait-event seen) *mine*)))))"
      " (clara:wait-event bound) (let ((here *mine*)) (clara:signal-event seen) (list here (clara:join-thread thread))))",
      "(SET-BY-A-THREAD THEIRS)" },
    /* a turn ends at a tick: the thread sets the flag while this one goes round and round */
    { "(let ((flag nil)) (clara:make-thread (lambda () (setq flag 'set))) (do () (flag flag)))", "SET" },
    /* locks: without one, the threads would read the same total and additions would be lost */
    { "(let ((lock (clara:make-lock \"total\")) (total 0))"
      " (mapc #'clara:join-thread (mapcar (lambda (n) (clara:make-thread (lambda () (dotimes (i 50)"
      " (clara:with-lock-held (lock) (let ((old total)) (clara:thread-yield) (setq total (+ old n))))))))"
      " '(1 2 3)))"
      " (list total lock))",
      "(300 #<LOCK \"total\">)" },
    { "(let ((lock (clara:make-lock))) (clara:acquire-lock lock)"
      " (handler-case (clara:acquire-lock lock) (error (c) (format nil \"~A\" c))))",
      "\"the thread #<THREAD \\\"listener\\\"> holds the lock #<LOCK> already\"" },
    { "(clara:release-lock (clara:make-lock \"spare\"))",
      "error: the thread #<THREAD \"listener\"> does not hold the lock #<LOCK \"spare\">" },
    /* events */
    { "(let ((e (clara:make-event \"e\"))) (clara:signal-event e 2)"
      " (list (clara:wait-event e) (clara:wait-event e) (clara:wait-event e 0) e))",
      "(T T NIL #<EVENT \"e\">)" },
    { "(clara:wait-event (clara:make-event) 20)", "NIL" },
    { "(let* ((go (clara:make-event))"
      " (threads (mapcar (lambda (n) (clara:make-thread (lambda () (clara:wait-event go) n))) '(1 2 3))))"
      " (clara:signal-event go 3) (mapcar #'clara:join-thread threads))",
      "(1 2 3)" },
    /* what a thread holds comes through a collection that another thread makes */
    { "(let* ((ready (clara:make-event)) (go (clara:make-event))"
      " (thread (clara:make-thread (lambda () (let ((kept (list 'a (list 'b))))"
      " (clara:signal-event ready) (clara:wait-event go) kept)))))"
      " (clara:wait-event ready) (cl::%collect) (dotimes (i 100) (list i)) (cl::%collect)"
      " (clara:signal-event go) (clara:join-thread thread))",
      "(A (B))" },
    { "(let ((thread (clara:make-thread (lambda () (let ((kept (list 1 2 3))) (clara:thread-yield) (cl::%collect) kept)))))"
      " (cl::%collect) (clara:join-thread thread))",
      "(1 2 3)" },
    /* a thread that fails, and threads that are stopped: computing, and waiting */
    { "(clara:join-thread (clara:make-thread (lambda () (handler-case (car 5) (error (c) (format nil \"~A\" c))))))",
      "\"CAR wants a list, and 5 is not one\"" },
    { "(let* ((started (clara:make-event)) (log nil)"
      " (thread (clara:make-thread (lambda () (unwind-protect (progn (clara:signal-event started) (loop))"
      " (push 'cleaned log))) :name \"spinner\")))"
      " (clara:wait-event started) (clara:destroy-thread thread)"
      " (list (handler-case (clara:join-thread thread) (error (c) (format nil \"~A\" c))) log"
      " (clara:thread-alive-p thread)))",
      "(\"the thread #<THREAD \\\"spinner\\\"> was stopped\" (CLEANED) NIL)" },
    { "(let* ((never (clara:make-event)) (waiting (clara:make-event))"
      " (thread (clara:make-thread (lambda () (clara:signal-event waiting)"
      " (handler-case (clara:wait-event never) (serious-condition () 'handled))))))"
      " (clara:wait-event waiting) (clara:thread-yield) (clara:destroy-thread thread)"
      " (handler-case (clara:join-thread thread) (error () 'stopped)))",
      "STOPPED" },
    { "(clara:destroy-thread (clara:current-thread))",
      "error: the thread #<THREAD \"listener\"> reads from the console, and cannot be stopped" },
    { "(clara:join-thread (clara:current-thread))",
      "error: the thread #<THREAD \"listener\"> cannot wait for itself to finish" },
    { "(clara:join-thread 5)", "error: CLARA:JOIN-THREAD wants a thread, and 5 is not one" },
    /* values that leave a loop, through its TAGBODY, are all still there */
    { "(list (multiple-value-list (dolist (x '(1 2)) (return (values x 'two))))"
      " (multiple-value-list (loop (return (values 1 2 3))))"
      " (multiple-value-list (dotimes (i 3) (when (= i 1) (return (values i 'one))))))",
      "((1 TWO) (1 2 3) (1 ONE))" },
    /* Ctrl-C for one thread: computing, waiting, and the thread itself; it is no error, and can be handled */
    { "(let* ((started (clara:make-event))"
      " (thread (clara:make-thread (lambda () (handler-case (progn (clara:signal-event started) (loop))"
      " (clara:keyboard-interrupt (c) (format nil \"~A\" c)))))))"
      " (clara:wait-event started)"
      " (list (clara:interrupt-thread thread) (clara:join-thread thread) (clara:interrupt-thread thread)))",
      "(T \"interrupted from the keyboard\" NIL)" },
    { "(let* ((never (clara:make-event)) (waiting (clara:make-event))"
      " (thread (clara:make-thread (lambda () (clara:signal-event waiting)"
      " (handler-case (clara:wait-event never) (error () 'an-error) (clara:keyboard-interrupt () 'interrupted))))))"
      " (clara:wait-event waiting) (clara:thread-yield) (clara:interrupt-thread thread) (clara:join-thread thread))",
      "INTERRUPTED" },
    { "(handler-case (progn (clara:interrupt-thread (clara:current-thread)) (identity 1) 'went-on)"
      " (clara:keyboard-interrupt () 'interrupted))",
      "INTERRUPTED" },
    { "(clara:interrupt-thread 5)", "error: CLARA:INTERRUPT-THREAD wants a thread, and 5 is not one" },
    /* a cleanup is not cut short: a thread that is interrupted or told to stop in the middle of one finishes it first */
    { "(let ((log nil))"
      " (handler-case (progn (unwind-protect nil (clara:interrupt-thread (clara:current-thread)) (identity 1)"
      " (setq log 'cleaned)) (identity 2) 'went-on)"
      " (clara:keyboard-interrupt () (list 'interrupted log))))",
      "(INTERRUPTED CLEANED)" },
    { "(let* ((cleaning (clara:make-event)) (go (clara:make-event)) (log nil)"
      " (thread (clara:make-thread (lambda () (unwind-protect nil (clara:signal-event cleaning) (clara:wait-event go)"
      " (identity 1) (push 'cleaned log)) (identity 2) 'went-on))))"
      " (clara:wait-event cleaning) (clara:destroy-thread thread) (clara:thread-yield) (clara:signal-event go)"
      " (list (handler-case (clara:join-thread thread) (error () 'stopped)) log))",
      "(STOPPED (CLEANED))" },
    { "(list (lisp-implementation-type) (lisp-implementation-version))", "(\"ClaraOS\" \"" CLARA_VERSION "\")" },
    { "(list (sleep 0) (- (length (clara:all-threads)) *threads*))", "(NIL 0)" }, /* the drivers have threads too */
    /* memory by its address, in page frames that are nobody else's */
    { "(defvar *page* (clara.unsafe:allocate-memory 2))"
      " (list (integerp *page*) (mod *page* 4096) (clara.unsafe:memory-64 *page*))",
      "(T 0 0)" },
    { "(progn (setf (clara.unsafe:memory-32 *page*) #x12345678) (list (clara.unsafe:memory-8 *page*)"
      " (clara.unsafe:memory-16 *page*) (clara.unsafe:memory-8 (+ *page* 3)) (clara.unsafe:memory-64 *page*)))",
      "(120 22136 18 305419896)" },
    { "(progn (setf (clara.unsafe:memory-8 (+ *page* 8)) -1 (clara.unsafe:memory-16 (+ *page* 10)) #xffff)"
      " (clara.unsafe:memory-32 (+ *page* 8)))",
      "4294902015" },
    { "(progn (setf (clara.unsafe:memory-64 (+ *page* 16)) -1)"
      " (handler-case (clara.unsafe:memory-64 (+ *page* 16)) (arithmetic-error () 'too-large)))",
      "TOO-LARGE" },
    { "(progn (clara.unsafe:fill-memory-32 *page* 1024 #xabcd) (list (clara.unsafe:memory-32 *page*)"
      " (clara.unsafe:memory-32 (+ *page* 4092)) (clara.unsafe:memory-32 (+ *page* 4096))))",
      "(43981 43981 0)" },
    { "(progn (dotimes (i 8) (setf (clara.unsafe:memory-8 (+ *page* 4096 i)) (1+ i)))"
      " (clara.unsafe:copy-memory (+ *page* 4098) (+ *page* 4096) 6) (clara.unsafe:memory-64 (+ *page* 4096)))",
      "433757350076154369" },
    { "(progn (clara.unsafe:copy-memory (+ *page* 4096) (+ *page* 4098) 6) (clara.unsafe:memory-64 (+ *page* 4096)))",
      "433759557723030017" },
    { "(progn (clara.unsafe:copy-memory *page* (+ *page* 4096) 4096)"
      " (list (clara.unsafe:memory-64 *page*) (clara.unsafe:memory-32 (+ *page* 8))))",
      "(433759557723030017 0)" },
    { "(progn (clara.unsafe:expand-bits-32 *page* 16 (vector #b1010 #b0110) 0 2 4 9 1)"
      " (mapcar (lambda (at) (clara.unsafe:memory-32 (+ *page* at))) '(0 4 8 12 16 20 24 28)))",
      "(9 1 9 1 1 9 9 1)" },
    /* a bit that is not set leaves its pixel as it was, a bit that is set does, and the lowest bit is passed over */
    { "(progn (clara.unsafe:fill-memory-32 *page* 8 5)"
      " (clara.unsafe:expand-bits-32 *page* 16 (vector #b1010 #b0110) 0 2 3 9 nil 1)"
      " (mapcar (lambda (at) (clara.unsafe:memory-32 (+ *page* at))) '(0 4 8 12 16 20 24 28)))",
      "(9 5 9 5 5 9 9 5)" },
    { "(progn (clara.unsafe:expand-bits-32 *page* 16 (vector #b1010 #b0110) 0 2 4 nil 1)"
      " (mapcar (lambda (at) (clara.unsafe:memory-32 (+ *page* at))) '(0 4 8 12 16 20 24 28)))",
      "(9 1 9 1 1 9 9 1)" },
    /* rectangles of pixels: rows of four here, 16 bytes from one to the next */
    { "(progn (clara.unsafe:fill-memory-32 *page* 2048 0) (clara.unsafe:fill-rectangle-32 (+ *page* 20) 16 2 3 7)"
      " (mapcar (lambda (at) (clara.unsafe:memory-32 (+ *page* at))) '(16 20 24 28 32 36 40 52 56 60 64 68)))",
      "(0 7 7 0 0 7 7 7 7 0 0 0)" },
    { "(progn (dotimes (i 16) (setf (clara.unsafe:memory-32 (+ *page* (* 4 i))) i))"
      " (clara.unsafe:copy-rectangle-32 (+ *page* 20) 16 *page* 16 2 2)" /* down and to the right, over itself */
      " (mapcar (lambda (i) (clara.unsafe:memory-32 (+ *page* (* 4 i)))) '(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)))",
      "(0 1 2 3 4 0 1 7 8 4 5 11 12 13 14 15)" },
    { "(progn (clara.unsafe:copy-rectangle-32 *page* 16 (+ *page* 20) 16 2 2)" /* and back up */
      " (mapcar (lambda (i) (clara.unsafe:memory-32 (+ *page* (* 4 i)))) '(0 1 2 3 4 5 6 7 8 9 10 11)))",
      "(0 1 2 3 4 5 1 7 8 4 5 11)" },
    { "(progn (clara.unsafe:copy-rectangle-32 (+ *page* 4) 16 *page* 16 3 1)" /* along a row, to the right and back */
      " (clara.unsafe:copy-rectangle-32 (+ *page* 16) 16 (+ *page* 20) 16 3 1)"
      " (mapcar (lambda (i) (clara.unsafe:memory-32 (+ *page* (* 4 i)))) '(0 1 2 3 4 5 6 7)))",
      "(0 0 1 2 5 1 7 7)" },
    { "(progn (clara.unsafe:copy-rectangle-32 (+ *page* 4096) 8 (+ *page* 36) 16 2 2)" /* into rows of another length */
      " (mapcar (lambda (at) (clara.unsafe:memory-32 (+ *page* 4096 at))) '(0 4 8 12 16)))",
      "(4 5 13 14 0)" },
    /* a colour laid over pixels by their shades: none of it, all of it, and what lies between, to the nearest;
     * the fourth pixel of each row is no part of the rectangle */
    { "(progn (clara.unsafe:fill-memory-32 *page* 8 #x102030)"
      " (clara.unsafe:blend-shades-32 *page* 16 (vector 0 255 128 64 1 254 0 9) 0 4 2 3 #xf0e0d0 #xff0000 #xff00 #xff)"
      " (mapcar (lambda (at) (clara.unsafe:memory-32 (+ *page* at))) '(0 4 8 12 16 20 24 28)))",
      "(1056816 15786192 8421504 1056816 1122609 15720399 1056816 1056816)" },
    /* parts of a pixel that are no bytes, bits of it that are no part of a colour, which stay, and shades from the second on */
    { "(progn (clara.unsafe:fill-memory-32 *page* 4 #xabcd1234)"
      " (clara.unsafe:blend-shades-32 *page* 16 (vector 7 255 128 64 1) 1 0 1 4 #xffff #xf800 #x07e0 #x001f)"
      " (mapcar (lambda (at) (clara.unsafe:memory-32 (+ *page* at))) '(0 4 8 12)))",
      "(2882404351 2882374938 2882358199 2882343476)" },
    { "(clara.unsafe:blend-shades-32 *page* 16 (vector 0 256) 0 2 1 2 0 255 0 0)",
      "error: 256 is not a shade: an integer from 0 to 255" },
    { "(clara.unsafe:blend-shades-32 *page* 16 (vector 0 0 0) 0 2 2 2 0 255 0 0)",
      "error: the vector has 3 shades, not 2 rows of 2 from 0 on" },
    { "(handler-case (clara.unsafe:blend-shades-32 4096 16 (vector 1) 0 1 1 1 0 255 0 0) (error () 'nothing-there))",
      "NOTHING-THERE" },
    { "(clara.unsafe:fill-rectangle-32 *page* 8 3 1 0)",
      "error: 1 rows of 3 pixels, 8 bytes from one row to the next, are not a rectangle of 32-bit pixels" },
    { "(clara.unsafe:fill-rectangle-32 4096 16 4 1 0)", "error: nothing is mapped at #x1000" },
    { "(handler-case (clara.unsafe:copy-rectangle-32 *page* 16 4096 16 4 2) (error () 'nothing-there))", "NOTHING-THERE" },
    /* a rectangle that begins in memory and whose rows, 16 MiB apart, go on for a tebibyte: past the end of it */
    { "(handler-case (clara.unsafe:fill-rectangle-32 *page* #x1000000 1 65536 0) (error () 'off-the-end))", "OFF-THE-END" },
    { "(handler-case (clara.unsafe:copy-rectangle-32 *page* 16 *page* #x1000000 1 65536) (error () 'off-the-end))",
      "OFF-THE-END" },
    { "(clara.unsafe:memory-8 0)", "error: nothing is mapped at #x0" },
    { "(clara.unsafe:memory-8 -1)", "error: CLARA.UNSAFE:MEMORY-8 wants an integer that is not negative, and -1 is not one" },
    { "(setf (clara.unsafe:memory-8 *page*) 256)", "error: 256 is not an integer that fits in 8 bits" },
    { "(handler-case (clara.unsafe:memory-32 (+ *page* 2)) (error () 'not-a-multiple-of-four))",
      "NOT-A-MULTIPLE-OF-FOUR" },
    { "(clara.unsafe:free-memory *page* 2)", "NIL" },
    /* an interrupt is an event that a thread waits for */
    { "(let ((tick (clara.unsafe:interrupt-event :timer)) (before (get-internal-real-time)))"
      " (dotimes (i 3) (clara:wait-event tick))"
      " (list tick (>= (- (get-internal-real-time) before) 2) internal-time-units-per-second))",
      "(#<EVENT \"TIMER\"> T 100)" },
    { "(clara.unsafe:interrupt-event :nothing)",
      "error: CLARA.UNSAFE:INTERRUPT-EVENT wants a source of interrupts, :TIMER or :SERIAL, and :NOTHING is not one" },
    /* a device's registers are mapped where they are, and memory is no device */
    { "(let ((page (clara.unsafe:allocate-memory 1)))"
      " (prog1 (handler-case (clara.unsafe:map-memory page 4096) (error () 'memory)) (clara.unsafe:free-memory page 1)))",
      "MEMORY" },
    { "(clara.unsafe:map-memory 4096 4096)",
      "error: the 4096 bytes at #x1000 cannot be mapped: the kernel maps nothing below #x100000, and from"
      " #x400000000000 on the addresses are the heap's" },
    { "(handler-case (clara.unsafe:map-memory #x3ffffffff000 8192) (error () 'the-heap))", "THE-HEAP" },
    { "(clara.unsafe:map-memory #x100000 0)",
      "error: 0 bytes are not the registers of a device: there are some, and no more than 256 MiB" },
    { "(clara.unsafe:message-interrupt 65536)",
      "error: CLARA.UNSAFE:MESSAGE-INTERRUPT wants the bus, device and function of a PCI device, as one number of"
      " 16 bits, and 65536 is not one" },
    /* Ctrl-C on a keyboard is Ctrl-C */
    { "(handler-case (progn (clara.unsafe:keyboard-break) (loop)) (clara:keyboard-interrupt () 'stopped))", "STOPPED" },
    /* &WHOLE in a list inside the lambda list is that list */
    { "(destructuring-bind (&whole all a (&whole inner b c)) '(1 (2 3)) (list a inner b c all))",
      "(1 (2 3) 2 3 (1 (2 3)))" },
    /* a macro inside a function sees the variables there, and one of MACROLET the macros of the one around it */
    { "(let ((n 5)) (defmacro five-more (x) (list '+ x n))) (five-more 1)", "6" },
    { "(macrolet ((make-form (op) (list 'quote (list op 1 2)))) (macrolet ((sum () (make-form +))) (sum)))", "3" },
    { "(handler-case (macrolet ((needs-one (a) a)) (needs-one)) (program-error () 'a-program-error))",
      "A-PROGRAM-ERROR" },
    /* a macro takes its form apart, and says what is wrong with one, the same walked and compiled */
    { "(defmacro taken (&whole all (a b) &optional (c 3) &rest more) (list 'quote (list a b c more all)))"
      " (list (taken (1 2)) (taken (1 2) 4 5 6))",
      "((1 2 3 NIL (TAKEN (1 2))) (1 2 4 (5 6) (TAKEN (1 2) 4 5 6)))" },
    { "(mapcar (lambda (form) (handler-case (macroexpand-1 form) (program-error (c) (princ-to-string c))))"
      " '((taken) (taken (1)) (taken (1 2 3))))",
      "(\"#<MACRO TAKEN> got too few arguments\" \"#<MACRO TAKEN> got too few arguments\""
      " \"#<MACRO TAKEN> got too many arguments\")" },
    { "(defmacro keyed (&key a (b 2)) (list 'quote (list a b)))"
      " (list (keyed) (keyed :b 5 :a 1) (handler-case (macroexpand-1 '(keyed :c 1)) (error (c) (princ-to-string c)))"
      " (handler-case (macroexpand-1 '(keyed :a)) (error (c) (princ-to-string c))))",
      "((NIL 2) (1 5) \"#<MACRO KEYED> does not take the keyword argument :C\""
      " \"#<MACRO KEYED> got an odd number of keyword arguments\")" },
    /* the functions that compiled code has instructions for: what they give, with any number of arguments, */
    { "(defun known (a b) (car a) (list (car a) (cdr a) (cons b a) (not a) (null b) (consp a) (atom a) (eq a a)"
      " (+ b 1) (- b 1) (* b 3) (1+ b) (1- b) (< b 3) (> b 3) (<= b 2) (>= b 3) (= b 2)"
      " (aref (vector 5 6) 1) (svref (vector 7 8) 0))) (known '(1 2) 2)",
      "(1 (2) (2 1 2) NIL NIL T NIL T 3 1 6 3 1 T NIL T NIL T 6 7)" },
    { "(list (+) (+ 1) (+ 1 2 3) (- 5) (- 9 1 2) (* 2 3 4) (< 1 2 3) (= 2 2 2) (>= 3 3 1) (car nil) (cdr nil))",
      "(0 1 6 -5 6 24 T T T NIL NIL)" },
    /* as the one value of a form, whatever the form before it left behind, */
    { "(defun last-is-known (x) (floor 7 2) (car x)) (list (multiple-value-list (last-is-known '(1 2)))"
      " (multiple-value-list (progn (floor 7 2) (+ 1 2))) (multiple-value-call #'list (floor 7 2) (car '(a)) (1+ 2)))",
      "((1) (3) (3 1 A 3))" },
    /* at the ends of what an integer can be, */
    { "(list (+ 4611686018427387902 1) (- -4611686018427387903 1) (* 2305843009213693951 2) (* -4611686018427387904 1)"
      " (1+ 4611686018427387902) (1- -4611686018427387903) (< -4611686018427387904 4611686018427387903))",
      "(4611686018427387903 -4611686018427387904 4611686018427387902 -4611686018427387904 4611686018427387903"
      " -4611686018427387904 T)" },
    { "(mapcar (lambda (f) (handler-case (funcall f) (arithmetic-error () 'too-large)))"
      " (list (lambda () (+ 4611686018427387903 1)) (lambda () (- -4611686018427387904 1))"
      " (lambda () (* 4611686018427387903 2)) (lambda () (1+ 4611686018427387903)) (lambda () (1- -4611686018427387904))))",
      "(TOO-LARGE TOO-LARGE TOO-LARGE TOO-LARGE TOO-LARGE)" },
    /* with arguments that they do not take, in the words of the function, */
    { "(mapcar (lambda (f) (handler-case (funcall f) (error (c) (princ-to-string c))))"
      " (list (lambda () (cdr 5)) (lambda () (+ 1 'a)) (lambda () (- 'a 1)) (lambda () (* nil 1)) (lambda () (< 'a 1))"
      " (lambda () (>= 1 \"2\")) (lambda () (= 1 'a)) (lambda () (1+ nil)) (lambda () (1- 'a))))",
      "(\"CDR wants a list, and 5 is not one\" \"+ wants an integer, and A is not one\""
      " \"- wants an integer, and A is not one\" \"* wants an integer, and NIL is not one\""
      " \"< wants an integer, and A is not one\" \">= wants an integer, and \\\"2\\\" is not one\""
      " \"= wants an integer, and A is not one\" \"1+ wants an integer, and NIL is not one\""
      " \"1- wants an integer, and A is not one\")" },
    { "(mapcar (lambda (f) (handler-case (funcall f) (error (c) (princ-to-string c))))"
      " (list (lambda () (aref 5 0)) (lambda () (svref (vector 1) 3)) (lambda () (aref (vector 1) -1))"
      " (lambda () (aref \"abc\" 1)) (lambda () (svref (vector 1 2) 'a)) (lambda () (aref (vector 1 2) 2))"
      " (lambda () (svref (vector 1 2) 1))))",
      "(\"AREF wants a vector, and 5 is not one\""
      " \"SVREF wants an index that is inside what it is given, and 3 is not one\""
      " \"AREF wants an index that is inside what it is given, and -1 is not one\" #\\b"
      " \"SVREF wants an index that is inside what it is given, and A is not one\""
      " \"AREF wants an index that is inside what it is given, and 2 is not one\" 2)" },
    /* the variables of a call begin as NIL, whatever lay there before. Here it is what a call that is over
       left behind, a list that has been freed since, and the collector comes by before the variables
       have their values: it would follow the old words into memory that holds no object any more */
    { "(defun leaves-lists () (list (list 1 2 3) 4) nil)"
      " (defun has-variables () (let ((a (progn (cl::%collect) 1)) (b 2)) (list a b)))"
      " (defun over-old-words () (leaves-lists) (cl::%collect) (has-variables))"
      " (list (over-old-words) (over-old-words))",
      "((1 2) (1 2))" },
    /* a character is a small number to whoever forgets to ask what it is: small enough to pass for a place
       in a vector as long as this one */
    { "(let ((v (make-array 20000))) (list (svref v 19999) (handler-case (svref v #\\a) (error (c) (princ-to-string c)))"
      " (handler-case (aref v #\\a) (error () 'refused))))",
      "(0 \"SVREF wants an index that is inside what it is given, and #\\\\a is not one\" REFUSED)" },
    /* in the middle of a form, where what the function gave is one of several things on the stack, */
    { "(let ((s \"abc\") (v (vector 1 2))) (list (aref s 0) (aref v 1) (aref s 1) (+ 1 2 3) (aref s 2) (svref v 0)))",
      "(#\\a 2 #\\b 6 #\\c 1)" },
    /* and under their names, when the name means something else where the form stands */
    { "(list (flet ((car (x) (list 'mine x))) (car 5)) (macrolet ((cdr (x) (list 'quote x))) (cdr (a b)))"
      " (funcall #'car '(1)) (apply '+ '(1 2)))",
      "((MINE 5) (A B) 1 3)" },
};

/* The texts above that mean something else once they are compiled, with
 * what they give then, and why. */
static const struct {
    const char *text, *printed;
} compiled[] = {
    /* a block that the compiler can see is never left needs no tag: nothing here to list yet */
    { "", "" },
};

/* Texts for the evaluator once there is a compiler: what COMPILE and its
 * kin give, and a function of each kind calling one of the other. */
static const struct {
    const char *text, *printed;
} compilations[] = {
    { "(list (compile 'add) (add 1 2) (compiled-function-p #'add) (compiled-function-p #'car) (compiled-function-p 'add))",
      "(ADD 3 T T NIL)" },
    { "(add 1)",
      "error: #<FUNCTION ADD> got too few arguments" },
    { "(defun walked (n) (* n 2)) (list (compiled-function-p #'walked) (function-lambda-expression #'walked))",
      "(NIL (LAMBDA (N) (* N 2)))" },
    { "(list (compile 'walked) (compiled-function-p #'walked) (walked 4) (function-lambda-expression #'walked))",
      "(WALKED T 8 NIL)" },
    { "(multiple-value-list (function-lambda-expression (let ((n 1)) (lambda () n))))",
      "((LAMBDA NIL N) T NIL)" },
    { "(funcall (compile nil '(lambda (a &optional (b 2) &key (c (+ a b))) (list a b c))) 1)",
      "(1 2 3)" },
    { "(compile nil (compile nil '(lambda () 1)))",
      "#<FUNCTION (LAMBDA NIL)>" },
    { "(compile nil 5)",
      "error: COMPILE takes a function or a LAMBDA form, and 5 is neither" },
    { "(compile 5)",
      "error: COMPILE takes the name of a function, a symbol, and 5 is not one" },
    { "(compile 'no-such-function)",
      "error: the function NO-SUCH-FUNCTION is not defined" },
    { "(compile 'when)",
      "error: COMPILE takes a function or a LAMBDA form, and #<MACRO WHEN> is neither" },
    { "(let ((n 1)) (compile nil (lambda () n)))",
      "error: #<FUNCTION (LAMBDA NIL)> was made where variables or local functions were in sight, and holds on to them: the compiler takes a function that stands by itself" },
    { "(compile 'named '(lambda (n) (if (< n 0) (return-from named 'negative)) n)) (list (named 1) (named -1) #'named)",
      "(1 NEGATIVE #<FUNCTION NAMED>)" },
    /* an exit, a condition and a binding pass through functions of both kinds */
    { "(progn (compile 'thrower) (catch 'out (thrower) 1))",
      "9" },
    { "(block b (funcall (compile nil '(lambda (f) (funcall f) 'came-back)) (lambda () (return-from b 'left))))",
      "LEFT" },
    { "(funcall (compile nil '(lambda (f) (block b (funcall f (lambda () (return-from b 'left))) 'came-back))) (lambda (g) (funcall g)))",
      "LEFT" },
    { "(defvar *seen* nil) (list (catch 'c (funcall (compile nil '(lambda (f) (unwind-protect (funcall f) (push 'cleaned *seen*)))) (lambda () (throw 'c 1)))) *seen*)",
      "(1 (CLEANED))" },
    { "(handler-case (funcall (compile nil '(lambda () (car 5)))) (type-error (c) (type-error-datum c)))",
      "5" },
    { "(funcall (compile nil '(lambda (f) (handler-case (funcall f) (type-error () 'caught)))) (lambda () (car 5)))",
      "CAUGHT" },
    { "(list (funcall (compile nil '(lambda (f) (let ((*level* 9)) (funcall f)))) #'level) (level))",
      "(9 6)" },
    { "(mapcar (compile nil '(lambda (x) (* x x))) '(1 2 3))",
      "(1 4 9)" },
    { "(clara:join-thread (clara:make-thread (compile nil '(lambda () (+ 1 2)))))",
      "3" },
    /* the listing */
    { "(with-output-to-string (*standard-output*) (disassemble (compile nil '(lambda (x) (car x)))))",
      "\"(LAMBDA (X)): 1 local variable, 1 word of stack\n0   LOCAL 0\n1   CAR\n2   RETURN\n\"" },
    { "(with-output-to-string (*standard-output*) (disassemble 'car))",
      "\"#<FUNCTION CAR> is written in C, and there is no listing of it here\n\"" },
    { "(with-output-to-string (*standard-output*) (disassemble '(lambda (x) (lambda () x))))",
      "\"(LAMBDA (X)): 1 local variable, 1 word of stack\n0   LOCAL 0\n1   CLOSURE (LAMBDA NIL) 1\n2   RETURN-ONE\n"
      "(LAMBDA NIL): 0 local variables, 1 word of stack\n0   CLOSED 0\n1   RETURN-ONE\n\"" },
    /* a form compiled and evaluated at once, a part at a time */
    { "(clara.compiler:evaluate '(progn (defvar *apart-again* 1) (let ((*apart-again* 2)) (symbol-value '*apart-again*))))",
      "2" },
    { "(list (clara:variable-kind 'car) (clara:variable-kind '*package*) (clara:variable-kind :key) (clara:variable-kind t) (clara:variable-kind '+two+))",
      "(NIL :SPECIAL :CONSTANT :CONSTANT :CONSTANT)" },
    { "(clara:variable-kind 5)",
      "error: CLARA:VARIABLE-KIND wants a symbol, and 5 is not one" },
    /* what is not code is refused before the machine is given it */
    { "(clara.unsafe:make-compiled-function (vector 1 2 3))",
      "error: the machine cannot run that code: it is not a vector of the items that code has" },
    { "(let ((code (clara.unsafe:compiled-function-code (compile nil '(lambda () 1))))) (setf (aref (aref code 0) 0) 255) (clara.unsafe:make-compiled-function code))",
      "error: the machine cannot run that code: one of its instructions is none that the machine has" },
    { "(let ((code (clara.unsafe:compiled-function-code (compile nil '(lambda () 1))))) (setf (aref (aref code 0) 0) (+ 20 (ash 99 8))) (clara.unsafe:make-compiled-function code))",
      "error: the machine cannot run that code: an instruction jumps past the end" },
    { "(let ((code (clara.unsafe:compiled-function-code (compile nil '(lambda (x) x))))) (setf (aref code 9) 0) (clara.unsafe:make-compiled-function code))",
      "error: the machine cannot run that code: it has more parameters than local variables" },
    { "(let ((code (clara.unsafe:compiled-function-code (compile nil '(lambda (x) (lambda () x)))))) (clara.unsafe:make-compiled-function (aref (aref code 1) 0)))",
      "error: the machine cannot run that code: it closes over values, and here are none" },
    { "(list (clara.unsafe:compiled-function-code #'car) (vectorp (clara.unsafe:compiled-function-code #'named)))",
      "(NIL T)" },
    { "(clara.unsafe:compiled-function-code 5)",
      "error: CLARA.UNSAFE:COMPILED-FUNCTION-CODE wants a function, and 5 is not one" },
    /* a binding that was made inside a form is undone before the cleanup of that form, and before a block is back */
    { "(let ((log nil)) (list (funcall (compile nil '(lambda (log) (handler-case (unwind-protect (let ((*level* 9)) (error \"x\")) (push *level* log)) (error () (list *level* log))))) log) *level*))",
      "((6 (6)) 6)" },
    { "(list (funcall (compile nil '(lambda () (block b (let ((*level* 9)) (funcall (lambda () (return-from b (level))))))))) (level))",
      "(9 6)" },
    /* values that leave from afar, and one value after a form that gave none */
    { "(multiple-value-list (funcall (compile nil '(lambda () (block b (funcall (lambda () (return-from b (values 1 2)))))))))",
      "(1 2)" },
    { "(funcall (compile nil '(lambda () (block b (funcall (lambda () (values) (return-from b 7)))))))",
      "7" },
    { "(multiple-value-list (funcall (compile nil '(lambda () (multiple-value-call #'list (progn (floor 7 2) 5) (values))))))",
      "((5))" },
    /* one value is one value, whatever the form before it left behind */
    { "(multiple-value-list (funcall (compile nil '(lambda () (floor 7 2) 5))))",
      "(5)" },
    { "(funcall (compile nil '(lambda () (values 8 9) (list (multiple-value-list (multiple-value-prog1 5 (values 3 4))) (multiple-value-bind (a b) 6 (list a b)) (unwind-protect 7 (identity 1)) (catch 'c (throw 'c 4))))))",
      "((5) (6 NIL) 7 4)" },
    /* a GO from afar undoes the bindings on its way, and a function that returns from inside a CATCH or a HANDLER-CASE takes them off */
    { "(funcall (compile nil '(lambda () (let ((n 0)) (tagbody (let ((*level* 9)) (funcall (lambda () (go out)))) out (setq n (level))) n))))",
      "6" },
    { "(list (funcall (compile nil '(lambda () (block b (catch 'x (return-from b 1)))))) (funcall (compile nil '(lambda () (block b (handler-case (return-from b 2) (error () 3)))))) (catch 'x (throw 'x 4)) (handler-case (car 5) (error () 6)))",
      "(1 2 4 6)" },
    /* what is on the stack around a form is still there after it, whichever way the form ended */
    { "(funcall (compile nil '(lambda () (list 1 (handler-case (error \"x\") (error () 2) (:no-error () 3)) (handler-case 5 (error () 2) (:no-error (v) (+ v 1))) 4))))",
      "(1 2 6 4)" },
    { "(funcall (compile nil '(lambda () (list 1 (block b (funcall (lambda (x) (if x (return-from b 2) 3)) nil)) 4))))",
      "(1 3 4)" },
    { "(multiple-value-list (funcall (compile nil '(lambda (f) (block b (funcall f (lambda () (return-from b 1))) (floor 7 2) 5))) (lambda (g) g)))",
      "(5)" },
    { "(defmacro define-and-bind () '(progn (defvar *bound-at-once* 1) (let ((*bound-at-once* 2)) (symbol-value '*bound-at-once*)))) (clara.compiler:evaluate '(define-and-bind))",
      "2" },
    /* a function with much of its own on the stack, calling itself without end */
    { "(compile 'wide '(lambda (n) (unwind-protect (multiple-value-call #'+ 1 (wide (+ n 1))) (identity n)))) (handler-case (wide 1) (storage-condition () 'full))",
      "FULL" },
    /* code with an instruction that names what is not there */
    { "(defun refused (word) (let ((code (clara.unsafe:compiled-function-code (compile nil '(lambda () 1))))) (setf (aref (aref code 0) 0) word) (handler-case (clara.unsafe:make-compiled-function code) (error (c) (subseq (princ-to-string c) 34))))) (list (refused 'x) (refused -1) (refused (ash 99 8)))",
      "(\"one of its instructions is none that the machine has\" \"one of its instructions is none that the machine has\" \"an instruction names a constant that is not there\")" },
    { "(list (refused (+ 1 (ash 99 8))) (refused (+ 3 (ash 5 8))) (refused 7))",
      "(\"an instruction names a local variable that is not there\" \"an instruction names a closed-over value that is not there\" \"an instruction wants a symbol, and its constant is not one\")" },
    { "(list (refused (+ 41 (ash 9 8))) (refused (+ 46 (ash 9 8)))"
      " (let ((code (clara.unsafe:compiled-function-code (compile nil '(lambda () 1))))) (setf (aref (aref code 0) 1) 16)"
      " (handler-case (clara.unsafe:make-compiled-function code) (error (c) (subseq (princ-to-string c) 34)))))",
      "(\"an instruction jumps past the end\" \"an instruction fails in a way that there is no type for\""
      " \"its last instruction lets the machine run on past the end\")" },
    { "(let ((code (clara.unsafe:compiled-function-code (compile nil '(lambda (x) (lambda () x)))))) (setf (aref (aref (aref code 1) 0) 11) 2) (handler-case (clara.unsafe:make-compiled-function code) (error (c) (subseq (princ-to-string c) 34))))",
      "\"a function inside it is not given the values that it closes over\"" },
    /* with a compiler there, what EVAL is given is compiled, and so is what LOAD reads */
    { "(progn (eval '(defun through-eval (n) (* n 2)))"
      " (list (compiled-function-p #'through-eval) (through-eval 4) (compiled-function-p (eval '(lambda () 1)))))",
      "(T 8 T)" },
    { "(progn (eval '(let ((n 0)) (defun counter () (setq n (+ n 1))))) (list (compiled-function-p #'counter) (counter) (counter)))",
      "(T 1 2)" },
    { "(progn (cl::%load-text \"(defun from-a-text (n) (+ n 1))\n(defmacro twice-it (x) (list '* 2 x))\n"
      "(defvar *loaded* (lambda () 'loaded))\" \"a text\")"
      " (list (compiled-function-p #'from-a-text) (from-a-text 1) (twice-it 4) (compiled-function-p *loaded*)))",
      "(T 2 8 T)" },
    { "(let ((form (list 'when t (list 'when t 1)))) (list (eval form) form))",
      "(1 (WHEN T (WHEN T 1)))" },
    /* a macro of each kind, used from the other side */
    { "(defmacro walked-twice (x) (list '* 2 x)) (eval '(defmacro compiled-twice (x) (list '* 2 x)))"
      " (list (funcall (compile nil '(lambda (n) (walked-twice n))) 4) (compiled-twice 5) (macroexpand-1 '(compiled-twice y)))",
      "(8 10 (* 2 Y))" },
    /* a function that the machine has an instruction for is defined again, in each of the ways there are,
     * and is the one that compiled code calls, with arguments that the instruction would have taken for
     * itself; put back, it is the function in C again */
    { "(defun peek (v) (svref v 0)) (defvar *svref* #'svref) (list (compile 'peek) (peek (vector 9)))",
      "(PEEK 9)" },
    /* A comparison that is only there for the jump after it, with its name given another function: the
     * jump is taken on what that function says, either way, for numbers too, which the instruction would
     * otherwise compare itself. The names are put right again by the function in C itself, since SETF is
     * Lisp, and Lisp compares. */
    { "(let ((less (symbol-function '<)) (none (symbol-function 'null)) (same (symbol-function 'eq))"
      " (pair (symbol-function 'cons))"
      " (f (compile nil '(lambda (x y) (list (if (< x y) 'less 'not-less) (if (< x 2) 'short 'long)"
      " (if (null x) 'none 'some) (if (eq x y) 'same 'other) (car (cons x y)))))))"
      " (let ((backwards (lambda (a b) (funcall less (if (listp b) (length b) b) (if (listp a) (length a) a))))"
      " (nothing (lambda (a) (if (listp a) (funcall same (car a) 'nothing) nil)))"
      " (opposite (lambda (a b) (if (funcall same a b) nil t))) (turned (lambda (a b) (funcall pair b a)))"
      " (one '(a)))"
      " (list (funcall f 1 2)"
      " (unwind-protect (progn (cl::%set-symbol-function '< backwards) (cl::%set-symbol-function 'null nothing)"
      " (cl::%set-symbol-function 'eq opposite) (cl::%set-symbol-function 'cons turned)"
      " (list (funcall f '(nothing) '(1 2)) (funcall f '(1 2) '(nothing)) (funcall f 5 1) (funcall f one one)))"
      " (cl::%set-symbol-function '< less) (cl::%set-symbol-function 'null none) (cl::%set-symbol-function 'eq same)"
      " (cl::%set-symbol-function 'cons pair))"
      " (funcall f 2 3))))",
      "((LESS SHORT SOME OTHER 1) ((NOT-LESS LONG NONE SAME (1 2)) (LESS LONG SOME SAME (NOTHING))"
      " (LESS SHORT SOME SAME 1) (NOT-LESS LONG SOME OTHER (A))) (LESS LONG SOME OTHER 2))" },
    { "(unwind-protect (progn (setf (symbol-function 'svref) (lambda (v i) (values (list 'set (length v) i) 'and-more)))"
      " (multiple-value-list (peek (vector 5)))) (setf (symbol-function 'svref) *svref*))",
      "((SET 1 0) AND-MORE)" },
    { "(unwind-protect (progn (defun svref (v i) (list 'walked (length v) i)) (peek (vector 6)))"
      " (setf (symbol-function 'svref) *svref*))",
      "(WALKED 1 0)" },
    { "(unwind-protect (progn (setf (symbol-function 'svref) #'list) (cdr (peek (vector 4))))"
      " (setf (symbol-function 'svref) *svref*))",
      "(0)" },
    { "(unwind-protect (progn (eval '(defun svref (v i) (list 'compiled (length v) i))) (peek (vector 7)))"
      " (setf (symbol-function 'svref) *svref*))",
      "(COMPILED 1 0)" },
    { "(unwind-protect (progn (eval '(defmacro svref (v i) (list 'list v i)))"
      " (handler-case (peek (vector 8)) (error (c) (princ-to-string c)))) (setf (symbol-function 'svref) *svref*))",
      "\"#<MACRO SVREF> is not a function, and cannot be called like one\"" },
    { "(list (peek (vector 3)) (eq #'svref *svref*) (handler-case (peek 5) (error (c) (princ-to-string c))))",
      "(3 T \"SVREF wants a vector, and 5 is not one\")" },
    /* how long a form took goes to where things are written, and its values come back */
    { "(let* ((values nil) (said (with-output-to-string (*standard-output*) (setq values (multiple-value-list (time (floor 7 2))))))) (list values (subseq said (- (length said) 14))))",
      "((3 1) \" milliseconds\n\")" },
    /* whatever a form does, it leaves the stack of its function as deep as it found it: what it took for
       a record, for the values of a form or for arguments that were never used is given back, whichever way
       control went. The compiler counts those words as it writes the code, and here they are counted again. */
    { "(defun left-behind (form) (funcall (compile nil (list 'lambda nil (list 'let '((before (cl::%stack-depth))) form '(- (cl::%stack-depth) before))))))",
      "LEFT-BEHIND" },
    { "(mapcar #'left-behind '((tagbody (funcall (lambda () (go out))) out)"
      " (block b (funcall (lambda () (return-from b 1))))"
      " (block b (let ((f (lambda () (return-from b 1)))) (if (car (list nil)) (funcall f)) 2))"
      " (tagbody (let ((f (lambda () (go out)))) (if (car (list nil)) (funcall f))) out)"
      " (block b (list 1 2 (if (car (list t)) (return-from b 3) 4)))"
      " (tagbody (list 1 2 (if (car (list t)) (go out) 4)) out)"
      " (dotimes (i 3) (list i (if (= i 1) (return 5))))))",
      "(0 0 0 0 0 0 0)" },
    { "(mapcar #'left-behind '((catch 'c (list 1 2 (throw 'c 3))) (catch 'c 1)"
      " (handler-case (list 1 2 (error \"no\")) (error (c) c)) (handler-case 1 (error (c) c))"
      " (handler-case (values 1 2) (error (c) c) (:no-error (a b) (list a b)))"
      " (handler-case (list 1 (car 5)) (program-error () 1) (type-error () 2) (error () 3))"
      " (unwind-protect (list 1 2) (list 3)) (catch 'c (unwind-protect (list 1 (throw 'c 1)) (list 3)))"
      " (let ((*package* *package*)) (catch 'c (list 1 (throw 'c 1))))))",
      "(0 0 0 0 0 0 0 0 0)" },
    { "(mapcar #'left-behind '((multiple-value-call #'list (values 1 2) (values) (values 3 4 5))"
      " (multiple-value-list (multiple-value-prog1 (values 1 2) (list 3)))"
      " (multiple-value-bind (a b c) (values 1 2) (list a b c))"
      " (list 1 (multiple-value-call #'+ (values 1 2) 3))"
      " (funcall (lambda (a &optional (b 2) &rest c &key d) (list a b c d)) 1 5 :d 2)))",
      "(0 0 0 0 0)" },
    /* a function that makes a record, called by compiled code that has a special variable bound: when it
       returns, it undoes what it bound itself and nothing of its caller's */
    { "(defvar *kept* 0) (defvar *within* nil) (defun inner (x) (catch 'c (let ((*within* x)) (+ x *kept*))))"
      " (compile 'inner)"
      " (funcall (compile nil '(lambda () (let ((*kept* 1)) (list (inner 5) *kept* (let ((*kept* 2)) (list (inner 6) *kept*)) *kept*)))))",
      "(6 1 (8 2) 1)" },
    /* the same for one whose arguments C has to sort out, which is where its record of them begins */
    { "(defun keyed (x &optional (y 1) &key z) (catch 'c (let ((*within* x)) (list x y z *kept*))))"
      " (compile 'keyed)"
      " (funcall (compile nil '(lambda () (let ((*kept* 1)) (list (keyed 5) (keyed 5 2 :z 3) *kept*"
      " (handler-case (keyed 5 2 :w 3) (error () 'refused)) (handler-case (keyed) (error () 'refused)) *kept*)))))",
      "((5 1 NIL 1) (5 2 3 1) 1 REFUSED REFUSED 1)" },
};

/* The texts of the table above that give something else when what is
 * compiled is made code for the processor as well (native_selftest): a
 * listing says so. */
static const struct {
    const char *text, *printed;
} translated[] = {
    { "(with-output-to-string (*standard-output*) (disassemble (compile nil '(lambda (x) (car x)))))",
      "\"(LAMBDA (X)): 1 local variable, 1 word of stack, translated for the processor\n0   LOCAL 0\n1   CAR\n"
      "2   RETURN\n\"" },
    { "(with-output-to-string (*standard-output*) (disassemble '(lambda (x) (lambda () x))))",
      "\"(LAMBDA (X)): 1 local variable, 1 word of stack, translated for the processor\n0   LOCAL 0\n"
      "1   CLOSURE (LAMBDA NIL) 1\n2   RETURN-ONE\n"
      "(LAMBDA NIL): 0 local variables, 1 word of stack, translated for the processor\n0   CLOSED 0\n"
      "1   RETURN-ONE\n\"" },
};

/* Texts that give one thing on a machine of one kind and something else on
 * the other: with I/O ports or without, with a screen or without. */
static const struct {
    const char *text, *printed, *otherwise;
} either[] = {
    /* the line status of the serial port, where that is a port */
    { "(handler-case (integerp (clara.unsafe:port-8 #x3fd)) (error (c) (format nil \"~A\" c)))", "T",
      "\"this machine has no I/O ports\"" },
    { "(handler-case (setf (clara.unsafe:port-8 #x80) 0) (error (c) (format nil \"~A\" c)))", "0",
      "\"this machine has no I/O ports\"" },
    /* which of the two this is, for #+ and #- */
    { "*features*", "(:CLARA :X86-64)", "(:CLARA :ARM64)" },
    /* the time of day, where the firmware has a clock: later than the beginning of 2026, and not going backwards */
    { "(handler-case (let ((now (get-universal-time))) (list (> now 3976214400) (<= now (get-universal-time))))"
      " (error (c) (format nil \"~A\" c)))",
      "(T T)", "\"this machine does not know what time it is: its firmware did not say\"" },
    /* what the firmware said about the machine */
    { "(list (keywordp (clara.unsafe:serial-device)) (integerp (nth-value 1 (clara.unsafe:serial-device)))"
      " (let ((screen (multiple-value-list (clara.unsafe:framebuffer)))) (or (null (car screen)) (length screen))))",
      "(T T 7)", "(T T T)" },
    /* and where it put the configuration space of the PCI devices: the first of them is there to be read */
    { "(multiple-value-bind (base first last) (clara.unsafe:pci-configuration)"
      " (if base (list (= base (clara.unsafe:map-memory base 4096)) (/= (clara.unsafe:memory-16 base) #xffff)"
      " (<= first last)) 'none))",
      "(T T T)", "NONE" },
};

/* The evaluator, and the language that lisp/boot.lisp builds on it. Then a
 * function that calls itself without end: the evaluator has to say that
 * the stack is full, well before the guard page says it. Returns how many
 * texts there were, and leaves how deep the function got in *deep.
 *
 * %SELF-TEST runs this again from the prompt, which is how the boot test
 * puts all of it through a collection at every safe point. */
enum {
    WATCHED = 200,      /* the safe points of compiled code that begin with a collection, to a text, */
    WATCHED_NATIVE = 50 /* and those of code for the processor, where a collection goes through the whole world */
};

static int g_translating; /* what is compiled is made code for the processor as well: for what the self-test says */

/* A collection before each of the next so many safe points that the code of
 * a text comes to: the processor's, when the texts are translated, and the
 * machine's otherwise. */
static void watch(unsigned points)
{
    if (g_translating)
        lisp_native_watched(points);
    else
        lisp_compiled_watched(points);
}

static unsigned eval_texts(int64_t *deep, lisp compiler, unsigned watched)
{
    struct lisp_symbol *package = lisp_as_symbol(lisp_roots.package);
    lisp user = package->value, packages = lisp_roots.packages;
    unsigned texts = sizeof evaluations / sizeof evaluations[0], others = sizeof either / sizeof either[0], wrong = 0;
    const char *who = g_translating ? "the processor" : compiler ? "compiled code" : "the evaluator";
    struct text printed;
    int64_t depth;

    package->value = lisp_make_package("CLARA.SELF-TEST", NULL, lisp_cons(lisp_roots.common_lisp, LISP_NIL));
    for (unsigned i = 0; i < texts; i++) {
        const char *expected = evaluations[i].printed;

        for (unsigned k = 0; compiler && k < sizeof compiled / sizeof compiled[0]; k++)
            if (same(evaluations[i].text, compiled[k].text))
                expected = compiled[k].printed;
        watch(watched);
        evaluate_text(evaluations[i].text, &printed, compiler);
        if (!same(printed.chars, expected)) {
            kprintf("lisp self-test: to %s, %s gave %s, not %s\n", who, evaluations[i].text, printed.chars, expected);
            wrong++;
        }
    }
    for (unsigned i = 0; i < others; i++) {
        watch(watched);
        evaluate_text(either[i].text, &printed, compiler);
        if (!same(printed.chars, either[i].printed) && !same(printed.chars, either[i].otherwise)) {
            kprintf("lisp self-test: to %s, %s gave %s, not %s or %s\n", who, either[i].text, printed.chars,
                    either[i].printed, either[i].otherwise);
            wrong++;
        }
    }
    texts += others;
    for (unsigned i = 0; compiler && i < sizeof compilations / sizeof compilations[0]; i++, texts++) {
        const char *expected = compilations[i].printed;

        for (unsigned k = 0; g_translating && k < sizeof translated / sizeof translated[0]; k++)
            if (same(compilations[i].text, translated[k].text))
                expected = translated[k].printed;
        watch(watched);
        evaluate_text(compilations[i].text, &printed, 0);
        if (!same(printed.chars, expected)) {
            kprintf("lisp self-test: with a compiler, %s gave %s, not %s\n", compilations[i].text, printed.chars,
                    expected);
            wrong++;
        }
    }
    if (wrong)
        panic("lisp self-test: %s gave %u wrong answers out of %u", who, wrong, texts);

    watch(watched);
    evaluate_text("(defvar *depth* 0) (defun dive (n) (setq *depth* n) (+ 1 (dive (+ n 1)))) (dive 1)", &printed, compiler);
    watch(0);
    if (!same(printed.chars, STACK_FULL))
        panic("lisp self-test: to %s, a function that calls itself without end gave %s", who, printed.chars);
    evaluate_text("*depth*", &printed, 0);
    depth = lisp_fixnum_value(lisp_values.value[0]);
    if (depth < 1000)
        panic("lisp self-test: to %s, a function could call itself only %lld deep", who, (long long)depth);
    /* And one that keeps nothing in hand while it does: its calls take the least of the value stack that a
     * call can take, so what stops compiled code is how deep the thread's own stack may go. The evaluator
     * comes to that end with the function above, and is spared this one: where every safe point of its
     * collects, it is some thousands of collections for nothing new. */
    if (compiler) {
        evaluate_text("(defun deeper (n) (deeper n)) (deeper 1)", &printed, compiler);
        if (!same(printed.chars, STACK_FULL))
            panic("lisp self-test: to %s, a function that only calls itself gave %s", who, printed.chars);
    }

    /* The packages the texts made go with the self-test's own, and so does what the last texts gave:
     * a value that is left there holds on to its package, and to every function in it. */
    package->value = user;
    lisp_roots.packages = packages;
    lisp_values.count = 1;
    for (unsigned i = 0; i < LISP_VALUES_MAX; i++)
        lisp_values.value[i] = LISP_NIL;
    *deep = depth;
    return texts;
}

unsigned lisp_eval_texts(void)
{
    int64_t depth;

    return eval_texts(&depth, 0, 0);
}

/* What the heap holds, once what nobody holds has been collected. In a
 * heap that is an image's that collection is the first: it frees what the
 * threads held that ran when the image was saved, and it finds the free
 * blocks, which were in no list until now. */
static void heap_report(void)
{
    uint64_t count[LISP_TYPES], bytes;
    struct lisp_functions functions;
    struct lisp_code_state code;
    struct lisp_heap heap;

    lisp_collect();
    bytes = lisp_heap_census(count);
    lisp_heap_state(&heap);
    kprintf("lisp: %llu KiB of heap in use after %llu collections: %llu conses, %llu symbols, %llu strings,\n",
            bytes >> 10, heap.collections, count[LISP_CONS], count[LISP_SYMBOL], count[LISP_STRING]);
    kprintf("lisp:   %llu vectors, %llu packages, %llu functions, %llu structures, %llu conditions,\n",
            count[LISP_VECTOR], count[LISP_PACKAGE], count[LISP_FUNCTION], count[LISP_STRUCTURE],
            count[LISP_CONDITION]);
    kprintf("lisp:   %llu threads, %llu locks and %llu events\n", count[LISP_THREAD], count[LISP_LOCK],
            count[LISP_EVENT]);
    lisp_heap_functions(&functions);
    kprintf("lisp:   of the functions %llu are in C, %llu are compiled, %llu of them macros, and %llu are walked\n",
            functions.in_c, functions.compiled + functions.macros, functions.macros, functions.walked);
    lisp_code_state(&code);
    kprintf("lisp:   the processor runs %llu of the compiled ones itself, %llu KiB of code, and the machine %llu\n",
            functions.native, (code.size - code.free) >> 10, functions.compiled - functions.native);
}

/* The evaluator's self-test, and then what the heap holds once the
 * self-tests' own objects have been collected. */
static void eval_selftest(void)
{
    uint64_t collections, frames;
    struct lisp_heap heap;
    struct text printed;
    int64_t depth;
    unsigned texts = eval_texts(&depth, 0, 0);

    /* Nobody asks for the next collection: the evaluator has to see for itself that it is time. When
     * that is depends on how much was in use after the last one, so there is one first, with
     * nothing in hand. */
    lisp_collect();
    lisp_heap_state(&heap);
    collections = heap.collections;
    evaluate_text("(dotimes (i 5000) (list i i i))", &printed, 0);
    lisp_heap_state(&heap);
    if (heap.collections == collections)
        panic("lisp self-test: the evaluator made 5000 lists and did not once stop to collect");

    /* A text that is read or loaded is written out in page frames first, and those have to come
     * back. A hundred texts of either kind that kept theirs would be a hundred frames; what the
     * heap grows by meanwhile is a few. */
    frames = pmm_free_frames();
    evaluate_text("(dotimes (i 100) (read-from-string \"(a text)\") (cl::%load-text \"(car '(a text))\" \"a text\"))",
                  &printed, 0);
    if ((int64_t)(frames - pmm_free_frames()) > 50)
        panic("lisp self-test: two hundred texts were read and loaded, and %llu page frames did not come back",
              frames - pmm_free_frames());

    kprintf("lisp: the evaluator passed: %u texts evaluated, and a function called itself %lld deep\n", texts,
            (long long)depth);
    heap_report();
}

/* The collector. Objects that are held, on the evaluator's stack, with as
 * many again that nothing holds made in between them: after a collection
 * the first are what they were and the second are gone, and what is made
 * next goes where those were. The objects that are held make the
 * collector work: more of them wait to be looked into at one time than it
 * has room for, a list is longer than any C stack is deep, and a cons
 * leads back to itself. Once nothing is held any more, the heap is what
 * it was before. */
static void collector_selftest(void)
{
    enum { ITEMS = 10000, LINKS = 50000 };
    lisp *base = lisp_stack(), wide, list = LISP_NIL, ring;
    const lisp *lost = NULL;
    struct lisp_heap before, held, again, after;
    uint64_t frames, made = 0, freed, n = 0;
    uint32_t c;

    lisp_collect(); /* what the reader's self-test left behind */
    lisp_heap_state(&before);
    frames = pmm_free_frames();

    wide = lisp_make_vector(ITEMS);
    lisp_push(wide);
    for (uint64_t i = 0; i < ITEMS; i++) {
        const lisp *nobodys = lisp_as_vector(lisp_make_vector(1 + i % 7))->items;

        made += 2 + i % 7;
        if (i == 6)
            lost = &nobodys[6]; /* the last word of one that nobody holds, past where a free block has its link */
        c = (uint32_t)('a' + i % 26);
        lisp_as_vector(wide)->items[i] = lisp_cons(lisp_fixnum((int64_t)i), lisp_make_string(&c, 1));
    }
    lisp_push(LISP_NIL);
    for (uint64_t i = 0; i < LINKS; i++) {
        made += 2 + i % 5;
        lisp_make_vector(1 + i % 5);
        base[1] = list = lisp_cons(lisp_fixnum((int64_t)i), list);
    }
    ring = lisp_cons(wide, LISP_NIL);
    lisp_as_cons(ring)->cdr = ring;
    lisp_push(ring);

    freed = lisp_collect();
    lisp_heap_state(&held);
    if (freed != made * sizeof(lisp))
        panic("lisp self-test: the collector freed %llu bytes where %llu were in nobody's hands", freed,
              made * sizeof(lisp));
    if (*lost != LISP_FREED)
        panic("lisp self-test: an object that the collector freed still holds %llx", *lost);
    for (uint64_t i = 0; i < ITEMS; i++) {
        lisp item = lisp_as_vector(wide)->items[i];

        if (!lisp_is_cons(item) || lisp_as_cons(item)->car != lisp_fixnum((int64_t)i) ||
            !lisp_is(lisp_as_cons(item)->cdr, LISP_STRING) ||
            lisp_as_string(lisp_as_cons(item)->cdr)->chars[0] != 'a' + i % 26)
            panic("lisp self-test: item %llu of a vector did not come through a collection", i);
    }
    for (lisp l = list; lisp_is_cons(l); l = lisp_as_cons(l)->cdr, n++)
        if (lisp_as_cons(l)->car != lisp_fixnum((int64_t)(LINKS - 1 - n)))
            panic("lisp self-test: item %llu of a list did not come through a collection", n);
    if (n != LINKS || lisp_as_cons(ring)->cdr != ring || lisp_as_cons(ring)->car != wide)
        panic("lisp self-test: a list of %u items has %llu after a collection, or a ring is no longer one", LINKS, n);

    /* As much again in nobody's hands: it all fits where the first lot was. */
    for (uint64_t i = 0; i < ITEMS; i++)
        lisp_make_vector(1 + i % 7);
    for (uint64_t i = 0; i < LINKS; i++)
        lisp_make_vector(1 + i % 5);
    lisp_heap_state(&again);
    if (again.size != held.size || held.free - again.free != made * sizeof(lisp))
        panic("lisp self-test: the heap grew from %llu to %llu bytes with %llu of it free", held.size, again.size,
              held.free);

    lisp_stack_drop(base);
    lisp_collect();
    lisp_heap_state(&after);
    if (after.size != before.size || after.free != before.free)
        panic("lisp self-test: the heap is %llu bytes with %llu free, and was %llu with %llu before the collector's test",
              after.size, after.free, before.size, before.free);
    if (frames - pmm_free_frames() > 16) /* a few stay behind as page tables */
        panic("lisp self-test: %llu page frames did not come back from the heap", frames - pmm_free_frames());
    kprintf("lisp: the collector passed: %u objects kept, %llu KiB freed and used again, a heap of %llu KiB\n",
            2 * ITEMS + LINKS + 2, freed >> 10, after.size >> 10);
}

/* The compiler, once lisp/compiler.lisp is loaded: the texts of the
 * evaluator's self-test once more, each form compiled and then run by the
 * machine of vm.c, with the answers that the evaluator gave. Then a
 * function that calls itself without end, compiled: the machine has to say
 * that the stack is full too.
 *
 * When more is asked for (new_world), all of it once again with a
 * collection where compiled code comes to a safe point, at the first
 * WATCHED of them in every text: whatever the machine fails to hold on to
 * is gone at its next call of a function in Lisp, or at the next turn of
 * its loop. The compiler and the functions that compiled code calls are
 * left alone meanwhile. They are Lisp that the evaluator walks, a
 * collection at each of their calls takes minutes where the machine is
 * emulated, and the evaluator has been through that already. */
static void compiler_selftest(int more)
{
    struct lisp_heap heap;
    uint64_t before;
    int64_t depth;
    unsigned texts = eval_texts(&depth, own_form("clara.compiler:evaluate"), 0);

    kprintf("lisp: the compiler passed: %u texts compiled and run, and a function called itself %lld deep\n", texts,
            (long long)depth);
    if (!more)
        return;
    lisp_heap_state(&heap);
    before = heap.collections;
    texts = eval_texts(&depth, own_form("clara.compiler:evaluate"), WATCHED);
    lisp_heap_state(&heap);
    kprintf("lisp: a collection at the safe points of compiled code, %u to a text: %u texts once more in %llu\n",
            WATCHED, texts, heap.collections - before);
}

/* Code for the processor, once the language, the compiler and what makes
 * such code are such code themselves: the same texts a fourth time. Each form is compiled as before, and
 * what the compiler made is then translated, every function of it, so that
 * the processor runs the text itself, and whatever of the world the text
 * calls. The answers are the evaluator's. Then the two kinds of code
 * together, since the machine still runs what is compiled while
 * *TRANSLATE* is NIL: functions of each kind that call each other, with
 * exits that pass through both, and one of the machine's that is made the
 * processor's afterwards, with a closure that was made of it before. Then
 * what a loop and a function that calls itself have to do without being
 * asked, stop for the collector, and with more asked for the texts once
 * again with a collection at the safe points of this code.
 *
 * Nothing of the texts may be left when it is over. The code lies outside
 * the heap, in pieces that are freed when the collector frees what holds
 * them (native.c): once the texts' functions are gone, as many pieces are
 * in use as before. */
static void native_selftest(int more)
{
    struct lisp_code_state code, before;
    struct lisp_heap heap;
    struct text printed;
    struct lisp_symbol *package = lisp_as_symbol(lisp_roots.package);
    lisp user = package->value, packages = lisp_roots.packages;
    uint64_t collections, ticks, entered, stepped, slow, now;
    unsigned texts;
    int64_t depth;

    lisp_collect();
    lisp_code_state(&before);
    g_translating = 1;
    lisp_native_counts(&entered, &stepped, &slow);
    ticks = timer_ticks();
    texts = eval_texts(&depth, own_form("clara.compiler:evaluate"), 0);
    ticks = timer_ticks() - ticks;
    lisp_code_state(&code);
    /* The answers would be right, too, if the machine had run the texts as before: so the code has to
     * have been made, and the processor has to have been sent into it. */
    lisp_native_counts(&now, &stepped, &slow);
    if (code.made - before.made < texts || now - entered < texts)
        panic("lisp self-test: the processor was to run %u texts itself: code was made for %llu functions, and "
              "it was entered %llu times",
              texts, code.made - before.made, now - entered);
    /* And they would be right if the processor left everything to C after all, which is what this code
     * falls back on at every turn. What it is there for is what it does alone: a function that calls
     * itself by its name, twenty thousand times, with a comparison, an addition and two subtractions to
     * a call, and a loop that adds, are C's business a few times at most, when a safe point has
     * something to look at. */
    package->value = lisp_make_package("CLARA.SELF-TEST", NULL, lisp_cons(lisp_roots.common_lisp, LISP_NIL));
    evaluate_text("(defun alone (n) (if (< n 2) n (+ (alone (- n 1)) (alone (- n 2)))))"
                  " (defun adds () (let ((sum 0)) (dotimes (i 10000) (setq sum (+ sum i))) sum))",
                  &printed, own_form("clara.compiler:evaluate"));
    /* (what compiled the two is such code as well, and has left instructions to C by now: only the calls
     * are counted, which the evaluator makes) */
    lisp_native_counts(&entered, &stepped, &slow);
    evaluate_text("(list (alone 20) (adds))", &printed, 0);
    lisp_native_counts(&entered, &now, &collections);
    if (!same(printed.chars, "(6765 49995000)") || now - stepped > 100 || collections - slow > 100)
        panic("lisp self-test: the processor gave %s, and left %llu instructions and %llu calls to C that are its own",
              printed.chars, now - stepped, collections - slow);
    /* The machine's code and the processor's, each calling the other nine and ten deep, and a THROW and
     * an error that go out through all of it. SLOW is the machine's, compiled while nothing was
     * translated, and so is the function that it has made by then, which counts; both are the
     * processor's once SLOW is translated, and the count goes on where it was. */
    evaluate_text("(setq clara.native:*translate* nil)"
                  " (defun slow (n f) (if (= n 0) (funcall f) (+ 1 (quick (- n 1) f))))"
                  " (defun counter () (let ((n 0)) (lambda () (setq n (+ n 1)))))"
                  " (defvar *count* (counter))"
                  " (setq clara.native:*translate* t)"
                  " (defun quick (n f) (if (= n 0) (funcall f) (+ 1 (slow (- n 1) f))))"
                  " (list (clara.native:translated-p 'slow) (clara.native:translated-p 'quick)"
                  " (slow 9 (lambda () 0)) (quick 10 (lambda () 0))"
                  " (catch 'out (slow 7 (lambda () (throw 'out 'thrown))))"
                  " (handler-case (quick 6 (lambda () (error \"no\"))) (error () 'failed))"
                  " (clara.native:translated-p *count*) (funcall *count*)"
                  " (progn (clara.native:translate 'slow) (clara.native:translate 'counter)"
                  " (clara.native:translated-p 'slow))"
                  " (clara.native:translated-p *count*) (funcall *count*) (slow 9 (lambda () 0)))",
                  &printed, own_form("clara.compiler:evaluate"));
    if (!same(printed.chars, "(NIL T 9 10 THROWN FAILED NIL 1 T T 2 9)"))
        panic("lisp self-test: the machine's code and the processor's, calling each other, gave %s", printed.chars);
    package->value = user; /* and the package goes, with the functions in it */
    lisp_roots.packages = packages;
    lisp_values.count = 1;
    lisp_values.value[0] = LISP_NIL;
    kprintf("lisp: code for the processor passed: %u texts in %llu functions and %llu ms, one called itself %lld deep\n",
            texts, code.made - before.made, ticks * (1000 / TIMER_HZ), (long long)depth);
    lisp_collect();
    lisp_heap_state(&heap);
    collections = heap.collections;
    evaluate_text("(funcall (compile nil '(lambda () (dotimes (i 20000) (list i i i)))))", &printed, 0);
    lisp_heap_state(&heap);
    if (heap.collections == collections)
        panic("lisp self-test: code for the processor made 20000 lists and did not once stop to collect");
    collections = heap.collections;
    evaluate_text("(funcall (compile nil '(lambda () (labels ((grow (n) (if (= n 0) (list 1 2 3)"
                  " (progn (grow (- n 1)) (grow (- n 1)))))) (grow 15)))))",
                  &printed, 0);
    lisp_heap_state(&heap);
    if (heap.collections == collections)
        panic("lisp self-test: code for the processor called itself 60000 times and did not once stop to collect");
    if (more) {
        collections = heap.collections;
        texts = eval_texts(&depth, own_form("clara.compiler:evaluate"), WATCHED_NATIVE);
        lisp_heap_state(&heap);
        kprintf("lisp: a collection at the safe points of code for the processor, %u to a text: %u texts in %llu\n",
                WATCHED_NATIVE, texts, heap.collections - collections);
        /* Most of those were calls. A loop that calls nothing comes to its safe points by jumping
         * backwards, and each of the first fifty turns has to have had its collection. */
        collections = heap.collections;
        lisp_native_watched(50);
        evaluate_text("(funcall (compile nil '(lambda () (let ((n 0)) (dotimes (i 100) (setq n (+ n i))) n))))",
                      &printed, 0);
        lisp_native_watched(0);
        lisp_heap_state(&heap);
        if (!same(printed.chars, "4950") || heap.collections - collections < 50)
            panic("lisp self-test: a loop of code for the processor gave %s, and stopped for the collector %llu times "
                  "in its first fifty turns",
                  printed.chars, heap.collections - collections);
    }
    g_translating = 0;
    lisp_collect();
    lisp_code_state(&code);
    if (code.pieces != before.pieces)
        panic("lisp self-test: the texts are over, and %llu pieces of code for the processor are in use, where %llu "
              "were before them",
              code.pieces, before.pieces);
}

static void console_put(void *to, char c)
{
    (void)to;
    kputc(c);
}

/* (load "file"), for a file that the Lisp world cannot do without. */
static void load(const char *file)
{
    /* Made here and handed over at once: nothing holds it but this variable. */
    lisp form = lisp_cons(lisp_symbol_in(lisp_roots.common_lisp, "LOAD", 1),
                          lisp_cons(lisp_string_from_utf8(file, strlen(file)), LISP_NIL));

    if (!lisp_evaluate(form)) {
        kputs("lisp: ");
        lisp_princ(lisp_values.value[0], console_put, NULL);
        kputc('\n');
        panic("lisp: %s did not load, and without it there is no Lisp world to start", file);
    }
}

/* A world, made: the collector is tested in the empty heap; boot.lisp is
 * loaded, the part of the language that is written in Lisp, and the
 * evaluator tested with it; then the compiler, the first file of the
 * world, and tested with the same texts; and then the other files that
 * are the beginning of the world. */
static void new_world(void)
{
    static const char *const world[] = { "compiler.lisp", "native.lisp",   "font.lisp",    "console.lisp",
                                         "draw.lisp",     "pci.lisp",      "virtio.lisp",  "input.lisp",
                                         "disk.lisp",     "fat.lisp",      "type.lisp",     "random.lisp",   "net.lisp",
                                         "sound.lisp",    "listener.lisp",
                                         "windows.lisp",  "terminal.lisp", "system.lisp",   "tls.lisp" };
    uint64_t before[LISP_TYPES], after[LISP_TYPES], ticks, collections;
    char processor[16] = { 0 };
    struct lisp_functions functions;
    struct lisp_code_state code;
    struct lisp_heap heap;
    struct text printed;
    unsigned texts;
    int64_t depth;
    int more;

    collector_selftest();
    lisp_heap_census(before);
    load("boot.lisp");
    lisp_heap_census(after);
    kprintf("lisp: boot.lisp is loaded, with %llu functions and macros in Lisp\n",
            after[LISP_FUNCTION] - before[LISP_FUNCTION]);
    eval_selftest();
    /* A boot volume with a file \clara\stress asks for more: boot.lisp
     * loaded once again and the evaluator's texts evaluated once again,
     * with a collection at every safe point of the evaluator, so that
     * whatever the evaluator fails to hold on to is gone at its next call.
     * Here the heap has the language in it and nothing else yet, and such
     * a collection is as short as it will ever be: afterwards it goes
     * through the whole world every time. The boot test asks for this, on
     * one of its machines (tools/session.txt writes the file). */
    more = lisp_boot_file("stress");
    if (more) {
        uint64_t between;

        lisp_heap_state(&heap);
        collections = heap.collections;
        lisp_collect_every(1);
        load("boot.lisp");
        lisp_heap_state(&heap);
        between = heap.collections;
        texts = lisp_eval_texts();
        lisp_collect_every(0);
        lisp_heap_state(&heap);
        kprintf("lisp: a collection at every safe point: boot.lisp once more in %llu, %u texts once more in %llu\n",
                between - collections, texts, heap.collections - between);
    }
    /* The compiler, and its self-test at once, while the heap is small: with more asked for, every
     * safe point of compiled code is a collection there. */
    load(world[0]);
    compiler_selftest(more);
    /* The compiler has said that it is there, so from here on LOAD compiles
     * every form that it reads, and EVAL the form that it is given
     * (lisp_eval_form, eval.c). The two files that the evaluator has walked
     * until now are loaded once more, the compiler first: the compiler that
     * the evaluator walks compiles itself, a definition at a time, and what
     * comes of that compiles boot.lisp. Both files bear being loaded twice:
     * a DEFVAR leaves what the first one made alone, and everything else
     * in them is said again to the same effect. Then the texts a third
     * time: what compiles them now is compiled code, and so are the
     * functions of boot.lisp that they call, and the answers are the same. */
    ticks = timer_ticks();
    load(world[0]);
    load("boot.lisp");
    ticks = timer_ticks() - ticks;
    texts = eval_texts(&depth, own_form("clara.compiler:evaluate"), 0);
    kprintf("lisp: the compiler compiled itself and boot.lisp in %llu ms, and then the %u texts as before\n",
            ticks * (1000 / TIMER_HZ), texts);
    /* A safe point of compiled code is a look at a word (safe_point, eval.h), and whoever has something
     * for the thread says so there. The allocator does when enough has been made: a loop of compiled
     * code that makes lists and calls nothing in Lisp has to stop and collect all the same. */
    lisp_collect();
    lisp_heap_state(&heap);
    collections = heap.collections;
    evaluate_text("(funcall (compile nil '(lambda () (dotimes (i 20000) (list i i i)))))", &printed, 0);
    lisp_heap_state(&heap);
    if (heap.collections == collections)
        panic("lisp self-test: compiled code made 20000 lists and did not once stop to collect");
    /* The same for code that never jumps backwards: a function that calls itself twice at every level,
     * some thirty thousand calls, each a safe point of the machine's own (call, vm.c). */
    collections = heap.collections;
    evaluate_text("(funcall (compile nil '(lambda () (labels ((grow (n) (if (= n 0) (list 1 2 3)"
                  " (progn (grow (- n 1)) (grow (- n 1)))))) (grow 15)))))",
                  &printed, 0);
    lisp_heap_state(&heap);
    if (heap.collections == collections)
        panic("lisp self-test: a compiled function called itself 60000 times and did not once stop to collect");
    /* What makes code for the processor of what the compiler makes (lisp/native.lisp), and of the files
     * that say how a processor's instructions are written the one for this machine's, which has the name
     * that *FEATURES* has for the machine, in small letters. They are compiled like any file, and so
     * the machine runs them at first, as it runs everything that there is by now. Then all of that is
     * translated, the language, the compiler and the translator itself: from here on the processor
     * runs them, and whatever is compiled is translated before it is run. */
    ticks = timer_ticks();
    load(world[1]);
    for (size_t i = 0; arch_feature[i] && i + 6 < sizeof processor; i++)
        processor[i] = arch_feature[i] >= 'A' && arch_feature[i] <= 'Z' ? (char)(arch_feature[i] | 0x20) : arch_feature[i];
    memcpy(processor + strlen(processor), ".lisp", 6);
    load(processor);
    if (!lisp_evaluate(own_form("(progn (clara.native:start) (clara.native:translate-all))")))
        panic("lisp: the language and the compiler were not translated for the processor");
    ticks = timer_ticks() - ticks;
    lisp_code_state(&code);
    lisp_heap_functions(&functions);
    if (functions.native != functions.compiled)
        panic("lisp: what was there was to be translated, and the machine still runs %llu of its %llu functions",
              functions.compiled - functions.native, functions.compiled);
    kprintf("lisp: all of that is translated for the processor in %llu ms: %lld functions, %llu KiB of code\n",
            ticks * (1000 / TIMER_HZ), (long long)lisp_fixnum_value(lisp_values.value[0]),
            (code.size - code.free) >> 10);
    /* The texts a fourth time, which the processor now runs, and with more asked for a fifth, with a
     * collection at the safe points of its code: here, while the heap holds the language and the two
     * that make code, and a collection is as short as it will be for such code. */
    native_selftest(more);
    ticks = timer_ticks();
    for (unsigned i = 2; i < sizeof world / sizeof world[0]; i++)
        load(world[i]);
    ticks = timer_ticks() - ticks;
    /* What the self-tests made, and the forms of the functions that were compiled, nobody holds any
     * more. Whatever the evaluator would still have to walk after that was not compiled, and whatever
     * the machine would still have to run was not translated: a world that is saved is to be the
     * processor's through and through. */
    lisp_collect();
    lisp_heap_functions(&functions);
    if (functions.walked)
        panic("lisp: the world is loaded, and %llu of its functions and macros are still the evaluator's to walk",
              functions.walked);
    if (functions.native != functions.compiled)
        panic("lisp: the world is loaded, and %llu of its %llu compiled functions are still the machine's to run",
              functions.compiled - functions.native, functions.compiled);
    kprintf("lisp: the world is loaded in %llu ms, compiled and translated: %llu functions, %llu macros\n",
            ticks * (1000 / TIMER_HZ), functions.compiled, functions.macros);
}

/* What the first thread of the Lisp world does. The world is made, unless
 * it came whole, as an image. Then it is started, the same way in both
 * cases, because what is started is the machine's and no image holds it:
 * the console, which takes the serial port and the screen over from the
 * substrate; the drivers, which find the devices on the PCI bus, start a
 * thread for each keyboard and mouse, and open the disks; the file system,
 * which finds the volumes on them; what draws, which finds the screen; the
 * window manager, when the world was saved with it running; and the
 * listener, which reads what is typed on the serial port, and on the
 * keyboard unless the window manager has that, evaluates it and prints
 * what it gives, until the input ends.
 * Should a condition come all the way out of the listener, it is started
 * again and told so. */
static void lisp_main(void)
{
    lisp listen, condition = LISP_NIL;
    unsigned told = 0;

    if (g_resumed)
        heap_report();
    else
        new_world();
    /* What makes code for the processor asks the kernel where its words lie, at every start: a world
     * that an older kernel saved has no such thing. */
    if (!lisp_evaluate(own_form("(let ((native (find-package \"CLARA.NATIVE\")))"
                                "  (if native (funcall (intern \"START\" native))))")))
        panic("lisp: what makes code for the processor did not start");
    if (!lisp_evaluate(own_form("(clara.console:start)")))
        panic("lisp: the console did not start");
    /* A machine without a PCI bus, or without a keyboard or a disk on it,
     * is said and is no reason to stop: there is the serial port, and
     * there are the files that came with the kernel. */
    if (!lisp_evaluate(own_form("(progn (clara.pci:start) (clara.input:start) (clara.disk:start) (clara.fat:start))")))
        panic("lisp: the drivers did not start");
    /* The device that makes numbers which nobody can guess, and the network
     * card, when the machine has them: each is found and opened, and the
     * card asks nothing of the network until something wants it. */
    if (!lisp_evaluate(own_form("(let ((random (find-package \"CLARA.RANDOM\")))"
                                "  (if random (funcall (intern \"START\" random))))")))
        panic("lisp: what makes numbers that nobody can guess did not start");
    if (!lisp_evaluate(own_form("(let ((net (find-package \"CLARA.NET\")))"
                                "  (if net (funcall (intern \"START\" net))))")))
        panic("lisp: the network did not start");
    /* The sound card, when the machine has one: it is found, opened and told what it will be given
     * to play, and plays nothing until something asks it to. */
    if (!lisp_evaluate(own_form("(let ((sound (find-package \"CLARA.SOUND\")))"
                                "  (if sound (funcall (intern \"START\" sound))))")))
        panic("lisp: sound did not start");
    /* What draws finds the screen. A world that was saved before there was
     * anything to draw with has no such package, and starts without it. */
    if (!lisp_evaluate(own_form("(let ((draw (find-package \"CLARA.DRAW\")))"
                                "  (if draw (funcall (intern \"START\" draw))))")))
        panic("lisp: drawing did not start");
    /* The fonts of outlines forget where the files were that an earlier start read: the window
     * manager draws its letters in one, so this comes before it. */
    if (!lisp_evaluate(own_form("(let ((type (find-package \"CLARA.TYPE\")))"
                                "  (if type (funcall (intern \"START\" type))))")))
        panic("lisp: the fonts did not start");
    /* The window manager, in a world that was saved while it ran: it takes
     * the screen, the keyboard and the pointer again, and opens a listener
     * in a window. That is the world's to say and not the substrate's, so
     * all that is here is the question. The listener below goes on all the
     * same, with the serial port. */
    if (!lisp_evaluate(own_form("(let ((windows (find-package \"CLARA.WINDOWS\")))"
                                "  (if windows (funcall (intern \"RESUME\" windows))))")))
        panic("lisp: the window manager did not start");
    /* What shuts the machine down hears its power button from here on. A
     * world that an older kernel saved has no such thing, and is stopped
     * from outside as it always was. */
    if (!lisp_evaluate(own_form("(let ((system (find-package \"CLARA.SYSTEM\")))"
                                "  (if system (funcall (intern \"START\" system))))")))
        panic("lisp: what shuts the machine down did not start");
    /* What keeps a connection closed forgets whom an earlier start had read
     * that it trusts: that was read into memory which is this start's to
     * hand out again. */
    if (!lisp_evaluate(own_form("(let ((tls (find-package \"CLARA.TLS\")))"
                                "  (if tls (funcall (intern \"START\" tls))))")))
        panic("lisp: what keeps a connection closed did not start");
    listen = own_form("clara.listener:run");
    while (!lisp_call(listen, told, &condition)) {
        condition = lisp_values.value[0];
        told = 1;
    }
    if (!lisp_evaluate(own_form("(clara.console:stop)")))
        panic("lisp: the console did not stop");
}

void lisp_run(void)
{
    thread_join(lisp_first_thread(lisp_main));
}
