/* The Lisp heap: where every object lives.
 *
 * It is the region that vm.c reserves, the same addresses on every machine
 * and every boot, and it fills from the bottom: a new object goes where the
 * last one ended, and a page frame is mapped whenever that runs past what
 * is mapped so far. Nothing is ever moved or given back yet; giving back
 * is the collector's work (M6c).
 *
 * A frame mapped here can still be reached at its physical address, like
 * all RAM. That keeps "RAM is at its own address" a rule with no exceptions
 * but the guard pages, and a driver that is handed a heap object for a
 * device to fill can reach its frames the way it reaches any others. The
 * price is that a stray write through a physical address can land in an
 * object, as it can anywhere else in RAM.
 *
 * One thread at a time: nothing here takes a lock (ROADMAP.md, M7). */
#include "lisp.h"

static uint64_t g_next = VM_HEAP_BASE; /* where the next object goes */
static uint64_t g_end = VM_HEAP_BASE;  /* where the mapped part ends: a whole number of pages */

/* How many words the object under this header takes, the header included,
 * or 0 when it is no header at all. The one place that knows, for making
 * objects and for walking past them. */
uint64_t lisp_object_words(lisp header)
{
    uint64_t length = lisp_length(header);

    switch (header & 0xff) {
    case LISP_CONS:
        return sizeof(struct lisp_cons) / sizeof(lisp);
    case LISP_SYMBOL:
        return sizeof(struct lisp_symbol) / sizeof(lisp);
    case LISP_STRING:
        return 1 + (length + 1) / 2;
    case LISP_VECTOR:
        return 1 + length;
    case LISP_PACKAGE:
        return sizeof(struct lisp_package) / sizeof(lisp);
    case LISP_FUNCTION:
        return sizeof(struct lisp_function) / sizeof(lisp);
    case LISP_STRUCTURE:
        return 2 + length;
    }
    return 0;
}

/* A new object of that type and length, every word after the header zero:
 * as Lisp values those are fixnum zeroes, so an object is fit to be looked
 * at from the moment it exists. */
void *lisp_alloc(enum lisp_type type, uint64_t length)
{
    lisp header = lisp_header(type, length), *object = (lisp *)(uintptr_t)g_next;
    uint64_t words = lisp_object_words(header);

    if (lisp_length(header) != length || words > (VM_HEAP_BASE + VM_HEAP_SIZE - g_next) / sizeof(lisp))
        panic("lisp: an object of length %llu does not fit in what is left of the heap region", length);
    while (g_end - g_next < words * sizeof(lisp)) {
        uint64_t frame = pmm_alloc(1);

        if (!frame)
            panic("lisp: out of memory: the heap has %llu KiB, and no page frame is free for more",
                  (g_end - VM_HEAP_BASE) >> 10);
        vm_map(g_end, frame, 1, VM_WRITE);
        g_end += PAGE_SIZE;
    }
    g_next += words * sizeof(lisp);
    memset(object, 0, words * sizeof(lisp));
    object[0] = header;
    return object;
}

/* Walk the heap from its first object to its last, the way the collector
 * will, and count the objects of each type. Returns the bytes in use. A
 * word that is no header where one has to be, or an object that runs past
 * the end, means the heap is damaged. */
uint64_t lisp_heap_census(uint64_t count[LISP_TYPES])
{
    uint64_t at = VM_HEAP_BASE;

    memset(count, 0, LISP_TYPES * sizeof count[0]);
    while (at < g_next) {
        lisp header = *(lisp *)(uintptr_t)at;
        uint64_t words = lisp_object_words(header);

        if (!words || words > (g_next - at) / sizeof(lisp))
            panic("lisp: the heap is damaged: at %llx the header is %llx", at, header);
        count[header & 0xff]++;
        at += words * sizeof(lisp);
    }
    return g_next - VM_HEAP_BASE;
}

lisp lisp_cons(lisp car, lisp cdr)
{
    struct lisp_cons *c = lisp_alloc(LISP_CONS, 0);

    c->car = car;
    c->cdr = cdr;
    return (lisp)(uintptr_t)c | LISP_TAG_CONS;
}

lisp lisp_make_string(const uint32_t *chars, uint64_t length)
{
    struct lisp_string *s = lisp_alloc(LISP_STRING, length);

    if (chars)
        memcpy(s->chars, chars, length * sizeof chars[0]);
    return (lisp)(uintptr_t)s | LISP_TAG_OBJECT;
}

lisp lisp_make_vector(uint64_t length)
{
    return (lisp)(uintptr_t)lisp_alloc(LISP_VECTOR, length) | LISP_TAG_OBJECT;
}
