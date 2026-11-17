/* The reader: text into objects, in the syntax of Common Lisp as far as
 * this Lisp has the objects for it.
 *
 *   lists, with a dot before the last item if it is to be the tail
 *   symbols: letters fold to upper case; \ and | | keep a character as it
 *     is; package:name, package::name, :keyword, #:in-no-package
 *   integers that fit a fixnum, and #x #o #b for other bases
 *   "strings", #\a and #\Space characters, #(vectors)
 *   'form and #'form
 *   `form, and inside it ,form and ,@form: lists for the evaluator, which
 *     knows what a backquote stands for (eval.c)
 *   ; to the end of the line, and #| |# around anything, as comments
 *   #+feature form and #-feature form: the form is there or is not,
 *     by whether *FEATURES* has the feature
 *
 * A token that Common Lisp would read as a float or a ratio is refused,
 * not taken for a symbol: the same text must not mean one thing here and
 * another under SBCL. The rest of the # syntax is refused for now too,
 * and so is a vector inside a backquote.
 *
 * The text is all in memory, so the reader never waits. Where the text
 * ends in the middle of a form it says LISP_READ_SHORT, and whoever can
 * get more of the text comes back with all of it. Lists nest by recursion
 * in C, on a stack of fixed size, so they may nest LISP_DEPTH deep. */
#include "lisp.h"

enum item { FORM, CLOSE, DOT, END }; /* what read_item came upon */

struct token {
    uint64_t length;   /* characters in r->token */
    int escaped;       /* a \ or a | was in it: it is a symbol, whatever it looks like */
    unsigned colons;   /* package markers: colons that were not escaped */
    uint64_t colon[2]; /* where the first two are */
};

const struct lisp_character_name lisp_character_names[] = {
    { ' ', "Space" },   { '\n', "Newline" }, { '\n', "Linefeed" }, { '\t', "Tab" },     { '\r', "Return" },
    { '\f', "Page" },   { '\b', "Backspace" }, { 0x7f, "Rubout" }, { 0x1b, "Escape" }, { 0, "Nul" },
    { 0, NULL },
};

static enum item read_item(struct lisp_reader *r, lisp *form);

static int failed(const struct lisp_reader *r)
{
    return r->status != LISP_READ_OK;
}

/* The first thing to go wrong is the one that is reported. */
static lisp fail(struct lisp_reader *r, const uint8_t *where, const char *error)
{
    if (!failed(r)) {
        r->status = LISP_READ_ERROR;
        r->where = where;
        r->error = error;
    }
    return LISP_NIL;
}

/* The text has run out in the middle of something. */
static lisp short_of(struct lisp_reader *r, const char *error)
{
    if (!failed(r)) {
        r->status = LISP_READ_SHORT;
        r->where = r->end;
        r->error = error;
    }
    return LISP_NIL;
}

/* The next character, or -1 at the end of the text and after a failure.
 * The text is UTF-8, and what is not well-formed UTF-8 is refused: a byte
 * out of place, a longer form than the character needs, half of a
 * surrogate pair, anything past U+10FFFF. */
static int64_t next(struct lisp_reader *r)
{
    const uint8_t *p = r->at;
    uint32_t c, least;
    unsigned more;

    if (failed(r) || p == r->end)
        return -1;
    c = *p++;
    if (c < 0x80) {
        r->at = p;
        return c;
    }
    if (c >= 0xc2 && c < 0xe0)
        more = 1, c &= 0x1f, least = 0x80;
    else if (c >= 0xe0 && c < 0xf0)
        more = 2, c &= 0x0f, least = 0x800;
    else if (c >= 0xf0 && c < 0xf5)
        more = 3, c &= 0x07, least = 0x10000;
    else
        more = 0, least = LISP_CODE_LIMIT; /* not the first byte of anything */
    for (; more && p != r->end && (*p & 0xc0) == 0x80; more--)
        c = c << 6 | (*p++ & 0x3f);
    if (more || c < least || c >= LISP_CODE_LIMIT || (c >= 0xd800 && c < 0xe000)) {
        fail(r, r->at, "the text is not UTF-8 here");
        return -1;
    }
    r->at = p;
    return c;
}

static int is_blank(int64_t c)
{
    return c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == '\f';
}

/* The characters a token stops at, the end of the text among them: blanks
 * and the ones that mean something on their own (CLHS 2.1.4). A # stops
 * nothing: it only means something at the start. */
static int ends_token(int64_t c)
{
    return c < 0 || is_blank(c) || c == '(' || c == ')' || c == '\'' || c == '"' || c == ';' || c == '`' || c == ',';
}

/* Is the next byte this one? Only for ASCII, which is a byte in UTF-8. */
static int looking_at(const struct lisp_reader *r, char c)
{
    return r->at != r->end && *r->at == (uint8_t)c;
}

/* Past blanks and comments, to whatever comes next. */
static void skip(struct lisp_reader *r)
{
    for (;;) {
        const uint8_t *before = r->at;
        int64_t c = next(r);

        if (is_blank(c))
            continue;
        if (c == ';') {
            while (c >= 0 && c != '\n')
                c = next(r);
            continue;
        }
        if (c == '#' && looking_at(r, '|')) {
            /* #| |# comments can hold one another. */
            unsigned open = 1;

            r->at++;
            while (open) {
                c = next(r);
                if (c < 0) {
                    short_of(r, "the text ends inside a #| |# comment");
                    return;
                }
                if (c == '|' && looking_at(r, '#'))
                    r->at++, open--;
                else if (c == '#' && looking_at(r, '|'))
                    r->at++, open++;
            }
            continue;
        }
        r->at = before;
        return;
    }
}

/* A token into r->token: the characters up to one that ends it (CLHS 2.2,
 * steps 8 and 9). Letters fold to upper case, ASCII ones only. After a \
 * the next character is taken as it is, and so is everything between two
 * bars. */
static void read_token(struct lisp_reader *r, struct token *t)
{
    int bars = 0;

    t->length = 0;
    t->escaped = 0;
    t->colons = 0;
    for (;;) {
        const uint8_t *before = r->at;
        int64_t c = next(r);

        if (bars && c < 0) {
            short_of(r, "the text ends between two bars");
            return;
        }
        if (!bars && ends_token(c)) {
            r->at = before;
            return;
        }
        if (c == '|') {
            bars = !bars;
            t->escaped = 1;
            continue;
        }
        if (c == '\\') {
            t->escaped = 1;
            c = next(r);
            if (c < 0) {
                short_of(r, "the text ends after a backslash");
                return;
            }
        } else if (!bars) {
            if (c < ' ' || c == 0x7f) {
                fail(r, before, "a control character that is not a blank");
                return;
            }
            if (c == ':') {
                if (t->colons < 2)
                    t->colon[t->colons] = t->length;
                t->colons++;
            } else if (c >= 'a' && c <= 'z')
                c -= 'a' - 'A';
        }
        if (t->length == LISP_TOKEN_MAX) {
            fail(r, before, "a name or a number of more than 255 characters");
            return;
        }
        r->token[t->length++] = (uint32_t)c;
    }
}

static int is_digit(uint32_t c)
{
    return c >= '0' && c <= '9';
}

/* What a token spells in base ten when none of its characters was escaped:
 *
 *   integer  [sign] digits [.]
 *   ratio    [sign] digits / digits
 *   float    [sign] [digits] . digits [exponent]
 *            [sign] digits [. [digits]] exponent
 *   exponent a letter out of E S F D L, [sign] digits
 *
 * and anything else is a symbol. The letters are in upper case by now. */
enum lisp_number lisp_number_syntax(const uint32_t *s, uint64_t length)
{
    uint64_t i = 0, whole = 0, fraction = 0, exponent = 0;

    if (i < length && (s[i] == '+' || s[i] == '-'))
        i++;
    for (; i < length && is_digit(s[i]); i++)
        whole++;
    if (i == length)
        return whole ? LISP_INTEGER : LISP_NOT_A_NUMBER;
    if (s[i] == '/') {
        for (i++; i < length && is_digit(s[i]); i++)
            fraction++;
        return whole && fraction && i == length ? LISP_RATIO : LISP_NOT_A_NUMBER;
    }
    if (s[i] == '.') {
        for (i++; i < length && is_digit(s[i]); i++)
            fraction++;
        if (i == length)
            return fraction ? LISP_FLOAT : whole ? LISP_INTEGER : LISP_NOT_A_NUMBER;
    }
    if (!whole && !fraction)
        return LISP_NOT_A_NUMBER;
    if (s[i] != 'E' && s[i] != 'S' && s[i] != 'F' && s[i] != 'D' && s[i] != 'L')
        return LISP_NOT_A_NUMBER;
    i++;
    if (i < length && (s[i] == '+' || s[i] == '-'))
        i++;
    for (; i < length && is_digit(s[i]); i++)
        exponent++;
    return exponent && i == length ? LISP_FLOAT : LISP_NOT_A_NUMBER;
}

/* The integer that s spells in a base up to 36: digits, with a sign before
 * them or without. Says whether it is one. An integer that is too large
 * for a fixnum is one, and fails the read: there are no larger ones yet. */
static int read_integer(struct lisp_reader *r, const uint8_t *where, const uint32_t *s, uint64_t length,
                        unsigned base, lisp *value)
{
    const uint64_t limit = (uint64_t)LISP_FIXNUM_MAX + 1; /* how far below zero fixnums reach */
    uint64_t magnitude = 0, i = length && (s[0] == '+' || s[0] == '-');
    int negative = length && s[0] == '-', fits = 1;

    if (i == length)
        return 0;
    for (; i < length; i++) {
        unsigned digit = is_digit(s[i]) ? s[i] - '0' : s[i] >= 'A' && s[i] <= 'Z' ? s[i] - 'A' + 10 : base;

        if (digit >= base)
            return 0;
        if (magnitude > (limit - digit) / base)
            fits = 0;
        else
            magnitude = magnitude * base + digit;
    }
    if (!fits || (magnitude == limit && !negative))
        fail(r, where, "an integer too large for a fixnum, and there are no larger integers yet");
    *value = lisp_fixnum(negative ? -(int64_t)magnitude : (int64_t)magnitude);
    return 1;
}

/* The symbol that a token names: in the package where names are read, or
 * in the one named before the colon. */
static lisp read_symbol(struct lisp_reader *r, const struct token *t, const uint8_t *where)
{
    const uint32_t *s = r->token;
    uint64_t name = t->colons ? t->colon[t->colons > 1] + 1 : 0; /* where the symbol's own name begins */
    lisp package, symbol;

    if (!t->colons)
        return lisp_intern(lisp_current_package(), s, t->length);
    if (t->colons > 2 || (t->colons == 2 && t->colon[1] != t->colon[0] + 1))
        return fail(r, where, "colons in the wrong places: it is package:name, package::name or :name");
    if (name == t->length)
        return fail(r, where, "a colon with no name after it");
    if (t->colon[0] == 0) {
        if (t->colons == 2)
            return fail(r, where, "two colons with no package before them");
        return lisp_intern(lisp_roots.keyword, s + name, t->length - name);
    }
    package = lisp_find_package(s, t->colon[0]);
    if (!package)
        return fail(r, where, "no package has the name before the colon");
    if (t->colons == 2 || package == lisp_roots.keyword)
        return lisp_intern(package, s + name, t->length - name);
    if (lisp_find_symbol(package, s + name, t->length - name, &symbol) != LISP_EXTERNAL)
        return fail(r, where, "the package has no external symbol of that name: package::name reaches the others");
    return symbol;
}

/* A token is a number if it spells one and a symbol if it does not. A dot
 * all by itself is neither: it belongs to the list around it. */
static enum item read_atom(struct lisp_reader *r, lisp *form)
{
    const uint8_t *start = r->at;
    struct token t;
    uint64_t dots = 0;

    read_token(r, &t);
    if (failed(r))
        return FORM;
    while (dots < t.length && r->token[dots] == '.')
        dots++;
    if (!t.escaped && dots == t.length) {
        if (dots == 1)
            return DOT;
        fail(r, start, "a name of nothing but dots");
    } else if (r->suppress)
        *form = LISP_NIL; /* part of a form that #+ or #- leaves out: it need not make sense here */
    else if (!t.escaped && !t.colons && lisp_number_syntax(r->token, t.length) != LISP_NOT_A_NUMBER) {
        if (!read_integer(r, start, r->token, t.length - (r->token[t.length - 1] == '.'), 10, form))
            fail(r, start, "a ratio or a floating-point number, which this Lisp does not have yet");
    } else
        *form = read_symbol(r, &t, start);
    return FORM;
}

/* The items up to the closing parenthesis, as a list. open is where the
 * list began, to say so when it turns out to be nested too deep. */
static lisp read_list(struct lisp_reader *r, const uint8_t *open)
{
    lisp head = LISP_NIL, tail = LISP_NIL, item = LISP_NIL;

    if (++r->depth > LISP_DEPTH)
        return fail(r, open, "lists nested too deep for the reader");
    for (;;) {
        const uint8_t *before;
        enum item what;

        skip(r);
        before = r->at;
        what = read_item(r, &item);
        if (failed(r))
            return LISP_NIL;
        if (what == END)
            return short_of(r, "the text ends inside a list");
        if (what == CLOSE)
            break;
        if (what == DOT) {
            /* One form after the dot, the tail, and then the list must close. */
            if (head == LISP_NIL)
                return fail(r, before, "a dot with nothing before it in the list");
            skip(r);
            before = r->at;
            what = read_item(r, &item);
            if (failed(r))
                return LISP_NIL;
            if (what == END)
                return short_of(r, "the text ends after the dot in a list");
            if (what != FORM)
                return fail(r, before, "no form between the dot and what follows it");
            lisp_as_cons(tail)->cdr = item;
            skip(r);
            before = r->at;
            what = read_item(r, &item);
            if (failed(r))
                return LISP_NIL;
            if (what == END)
                return short_of(r, "the text ends inside a list");
            if (what != CLOSE)
                return fail(r, before, "more than one form after the dot");
            break;
        }
        item = lisp_cons(item, LISP_NIL);
        if (head == LISP_NIL)
            head = item;
        else
            lisp_as_cons(tail)->cdr = item;
        tail = item;
    }
    r->depth--;
    return head;
}

/* 'form is (QUOTE form), and #'form is (FUNCTION form). */
static lisp read_quoted(struct lisp_reader *r, lisp symbol, const uint8_t *quote)
{
    const uint8_t *before;
    enum item what;
    lisp form = LISP_NIL;

    if (++r->depth > LISP_DEPTH)
        return fail(r, quote, "quotes nested too deep for the reader");
    skip(r);
    before = r->at;
    what = read_item(r, &form);
    if (failed(r))
        return LISP_NIL;
    if (what == END)
        return short_of(r, "the text ends after a quote");
    if (what != FORM)
        return fail(r, before, "no form after the quote");
    r->depth--;
    return lisp_cons(symbol, lisp_cons(form, LISP_NIL));
}

/* Between double quotes. A backslash takes the next character as it is,
 * which is how a string holds a double quote or a backslash. The text is
 * gone through twice: to count the characters, and to copy them. */
static lisp read_string(struct lisp_reader *r)
{
    const uint8_t *start = r->at;
    uint64_t length = 0;
    int64_t c;
    lisp string;

    while ((c = next(r)) != '"') {
        if (c == '\\')
            c = next(r);
        if (c < 0)
            return short_of(r, "the text ends inside a string");
        length++;
    }
    string = lisp_make_string(NULL, length);
    r->at = start;
    for (uint64_t i = 0; i < length; i++) {
        c = next(r);
        if (c == '\\')
            c = next(r);
        lisp_as_string(string)->chars[i] = (uint32_t)c;
    }
    next(r);
    return string;
}

/* #\ and one character, or the name of one: Space, Newline and the others
 * of lisp_character_names in either case, or U+ and its code point in
 * hexadecimal. */
static lisp read_character(struct lisp_reader *r, const uint8_t *start)
{
    int64_t first = next(r);
    struct token t;

    if (first < 0)
        return short_of(r, "the text ends after #\\");
    read_token(r, &t);
    if (failed(r))
        return LISP_NIL;
    if (!t.length)
        return lisp_character((uint32_t)first);
    if (first >= 'a' && first <= 'z')
        first -= 'a' - 'A';
    if (first == 'U' && r->token[0] == '+') {
        lisp code;

        if (read_integer(r, start, r->token + 1, t.length - 1, 16, &code) && !failed(r) &&
            lisp_fixnum_value(code) >= 0 && lisp_fixnum_value(code) < LISP_CODE_LIMIT &&
            (lisp_fixnum_value(code) & ~0x7ffLL) != 0xd800)
            return lisp_character((uint32_t)lisp_fixnum_value(code));
        return fail(r, start, "no character has that code point");
    }
    for (const struct lisp_character_name *n = lisp_character_names; n->name; n++) {
        uint64_t i = 0;

        if (strlen(n->name) != t.length + 1 || n->name[0] != first)
            continue;
        while (i < t.length && (uint32_t)(n->name[1 + i] & ~0x20) == r->token[i])
            i++;
        if (i == t.length)
            return lisp_character(n->code);
    }
    if (r->suppress)
        return lisp_character(' ');
    return fail(r, start, "no character has that name");
}

/* What follows a #. */
static lisp read_sharp(struct lisp_reader *r, const uint8_t *start)
{
    int64_t c = next(r);
    struct token t;
    lisp form = LISP_NIL;

    switch (c) {
    case '\'':
        return read_quoted(r, lisp_roots.function, start);
    case '\\':
        return read_character(r, start);
    case '(': {
        /* A vector is read as a list and copied. */
        lisp list = read_list(r, start), vector;
        uint64_t length = 0;

        if (failed(r))
            return LISP_NIL;
        if (r->backquotes)
            return fail(r, start, "a vector inside a backquote, which the reader does not know yet");
        for (form = list; lisp_is_cons(form); form = lisp_as_cons(form)->cdr)
            length++;
        if (form != LISP_NIL)
            return fail(r, start, "a dot in a vector");
        vector = lisp_make_vector(length);
        for (uint64_t i = 0; i < length; i++, list = lisp_as_cons(list)->cdr)
            lisp_as_vector(vector)->items[i] = lisp_as_cons(list)->car;
        return vector;
    }
    case ':':
        read_token(r, &t);
        if (failed(r))
            return LISP_NIL;
        if (t.colons)
            return fail(r, start, "a colon in the name of a symbol that is in no package");
        return lisp_make_symbol(r->token, t.length);
    case 'x': case 'X': case 'o': case 'O': case 'b': case 'B':
        read_token(r, &t);
        if (failed(r))
            return LISP_NIL;
        if (t.escaped || !read_integer(r, start, r->token, t.length, (c | 0x20) == 'x' ? 16 : (c | 0x20) == 'o' ? 8 : 2,
                                       &form))
            return fail(r, start, "not an integer in the base that the # asks for");
        return form;
    case '<':
        return fail(r, start, "#< begins the print of an object that cannot be read back");
    }
    if (c < 0)
        return short_of(r, "the text ends after a #");
    return fail(r, start, "a # followed by something the reader does not know yet");
}

/* Does *FEATURES* have what a feature expression asks for? The expression
 * was read in KEYWORD: a feature, or (:AND ...), (:OR ...), (:NOT x). */
static int featured(lisp expression, unsigned depth)
{
    lisp key = lisp_roots.keyword, operator, rest;

    if (!lisp_is_cons(expression)) {
        for (lisp f = lisp_as_symbol(lisp_roots.features)->value; lisp_is_cons(f); f = lisp_as_cons(f)->cdr)
            if (lisp_as_cons(f)->car == expression)
                return 1;
        return 0;
    }
    operator = lisp_as_cons(expression)->car;
    rest = lisp_as_cons(expression)->cdr;
    if (depth == LISP_DEPTH)
        return 0;
    if (operator == lisp_symbol_in(key, "NOT", 1))
        return lisp_is_cons(rest) && !featured(lisp_as_cons(rest)->car, depth + 1);
    if (operator == lisp_symbol_in(key, "OR", 1)) {
        for (; lisp_is_cons(rest); rest = lisp_as_cons(rest)->cdr)
            if (featured(lisp_as_cons(rest)->car, depth + 1))
                return 1;
        return 0;
    }
    for (; lisp_is_cons(rest); rest = lisp_as_cons(rest)->cdr) /* :AND, and anything else is taken for it */
        if (!featured(lisp_as_cons(rest)->car, depth + 1))
            return 0;
    return 1;
}

static enum item read_item(struct lisp_reader *r, lisp *form);

/* #+feature form and #-feature form, from the sign on. The feature is
 * read in KEYWORD. When the form is to be left out it is read all the
 * same, to get past it, but without asking its symbols and numbers to
 * make sense: it may be written for another Lisp. What this gives is the
 * form, or else whatever comes after it. */
static enum item read_conditional(struct lisp_reader *r, const uint8_t *start, lisp *form)
{
    struct lisp_symbol *package = lisp_as_symbol(lisp_roots.package);
    lisp reading_in = package->value, feature = LISP_NIL, left_out = LISP_NIL;
    int wanted = *r->at++ == '+', kept = 0;
    enum item what;

    if (++r->depth > LISP_DEPTH) {
        fail(r, start, "#+ and #- nested too deep for the reader");
        return FORM;
    }
    package->value = lisp_roots.keyword;
    what = read_item(r, &feature);
    package->value = reading_in;
    if (!failed(r) && what == FORM) {
        kept = featured(feature, 0) == wanted;
        r->suppress += !kept;
        what = read_item(r, kept ? form : &left_out);
        r->suppress -= !kept;
    }
    r->depth--;
    if (failed(r))
        return FORM;
    if (what == END) {
        short_of(r, "the text ends after a #+ or a #-");
        return FORM;
    }
    if (what != FORM) {
        fail(r, start, "a #+ or a #- without a feature and a form after it");
        return FORM;
    }
    return kept ? FORM : read_item(r, form);
}

/* The next thing in the text. A form is stored; a closing parenthesis, a
 * dot on its own and the end of the text are for the caller to make sense
 * of. */
static enum item read_item(struct lisp_reader *r, lisp *form)
{
    const uint8_t *start;
    int64_t c;

    skip(r);
    start = r->at;
    c = next(r);
    if (c < 0)
        return END;
    switch (c) {
    case '(':
        *form = read_list(r, start);
        return FORM;
    case ')':
        return CLOSE;
    case '\'':
        *form = read_quoted(r, lisp_roots.quote, start);
        return FORM;
    case '"':
        *form = read_string(r);
        return FORM;
    case '#':
        if (looking_at(r, '+') || looking_at(r, '-'))
            return read_conditional(r, start, form);
        *form = read_sharp(r, start);
        return FORM;
    case '`':
        r->backquotes++;
        *form = read_quoted(r, lisp_roots.quasiquote, start);
        r->backquotes--;
        return FORM;
    case ',':
        /* A comma answers a backquote, the innermost that is still open. */
        if (!r->backquotes) {
            fail(r, start, "a comma that is not inside a backquote");
            return FORM;
        }
        c = looking_at(r, '@') || looking_at(r, '.');
        r->at += c;
        r->backquotes--;
        *form = read_quoted(r, c ? lisp_roots.splice : lisp_roots.unquote, start);
        r->backquotes++;
        return FORM;
    }
    r->at = start;
    return read_atom(r, form);
}

void lisp_reader_init(struct lisp_reader *r, const void *text, size_t size)
{
    r->text = r->at = text;
    r->end = r->text + size;
    r->status = LISP_READ_OK;
    r->error = NULL;
    r->where = r->text;
    r->depth = 0;
    r->suppress = 0;
}

/* The next form of the text. After LISP_READ_SHORT or LISP_READ_ERROR,
 * r->error says what was wrong and r->where is the place; the reader is
 * of no more use then. */
enum lisp_read_status lisp_read(struct lisp_reader *r, lisp *form)
{
    const uint8_t *start;

    r->status = LISP_READ_OK;
    r->depth = 0;
    r->backquotes = 0;
    r->suppress = 0;
    skip(r);
    start = r->at;
    switch (read_item(r, form)) {
    case FORM:
        if (!failed(r))
            r->where = start; /* for whoever wants to say where the form is */
        break;
    case END:
        if (!failed(r))
            r->status = LISP_READ_END;
        break;
    case CLOSE:
        fail(r, r->at - 1, "a closing parenthesis that closes nothing");
        break;
    case DOT:
        fail(r, r->at - 1, "a dot outside a list");
        break;
    }
    return r->status;
}

/* A string of the characters that the text holds in UTF-8, as far as it is
 * UTF-8: for text that the substrate wrote itself. */
lisp lisp_string_from_utf8(const void *text, size_t size)
{
    struct lisp_reader r;
    uint64_t length = 0;
    lisp string;

    lisp_reader_init(&r, text, size);
    while (next(&r) >= 0)
        length++;
    string = lisp_make_string(NULL, length);
    lisp_reader_init(&r, text, size);
    for (uint64_t i = 0; i < length; i++)
        lisp_as_string(string)->chars[i] = (uint32_t)next(&r);
    return string;
}

/* How many bytes of a text are UTF-8, from its beginning: all of them, or
 * as far as the first that is not. */
size_t lisp_utf8_length(const void *text, size_t size)
{
    struct lisp_reader r;

    lisp_reader_init(&r, text, size);
    while (next(&r) >= 0)
        ;
    return (size_t)(r.at - r.text);
}

/* The line and the column of r->where, counted from 1. A column is a
 * character. */
void lisp_reader_where(const struct lisp_reader *r, unsigned *line, unsigned *column)
{
    *line = *column = 1;
    for (const uint8_t *p = r->text; p < r->where; p++) {
        if (*p == '\n') {
            ++*line;
            *column = 1;
        } else if ((*p & 0xc0) != 0x80)
            ++*column;
    }
}
