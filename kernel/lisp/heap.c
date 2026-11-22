/* The Lisp heap: where every object lives, and the collector, which finds
 * the objects that nothing can reach any more and makes their memory free
 * to be used again.
 *
 * The heap is the region that vm.c reserves, the same addresses on every
 * machine and every boot. It is one run of objects and free blocks, each
 * with a header word that says how long it is, from the first object, NIL,
 * to the end. A new object goes into a free block if one is long enough,
 * and otherwise where the heap ends, with a page frame mapped whenever that
 * runs past what is mapped so far. Objects never move.
 *
 * The collector marks and sweeps. From what the substrate and the evaluator
 * hold, for the thread that collects and for every other (lisp_roots,
 * lisp_eval_roots, lisp_thread_roots), it follows every value to the object
 * it points at, and marks each object it reaches in the byte of the header
 * that is kept for it. Then it walks the heap from one end to the other:
 * what is marked stays, and every run of what is not becomes one free
 * block. It knows exactly which words are values, so it never has to
 * guess, and it never keeps an object by mistake. A few objects hold an
 * address in the kernel's own memory in one of their words (lisp.h, at
 * struct lisp_thread): such an address is a multiple of eight, which as a
 * value is a fixnum, and so nothing to follow.
 *
 * It runs at the evaluator's safe points and nowhere else, in the thread
 * that has the runtime: every other Lisp thread is waiting, for the
 * runtime or for something else, and stands at a safe point of its own
 * meanwhile (thread.c). So nobody has to be stopped, and the threads that
 * do not evaluate go on as they were: they never touch the heap. Making an
 * object never collects. So
 * the C code of the runtime may hold an object in a variable for as long
 * as it comes to no safe point, and whatever it holds across one has to be
 * where the collector looks (eval.c). An object that was freed all the same
 * does not go unnoticed for long: freed memory is filled with LISP_FREED,
 * which the collector refuses to follow, which faults when it is followed
 * as an address, and which has to be there still when the memory is used
 * again.
 *
 * A frame mapped here can still be reached at its physical address, like
 * all RAM. That keeps "RAM is at its own address" a rule with no exceptions
 * but the guard pages, and a driver that is handed a heap object for a
 * device to fill can reach its frames the way it reaches any others. The
 * price is that a stray write through a physical address can land in an
 * object, as it can anywhere else in RAM.
 *
 * One thread at a time has the runtime (thread.c), so nothing here takes
 * a lock. */
#include "lisp.h"

enum {
    BINS = 32,   /* a free block of up to this many words is in a list with the others of its length */
    MARKS = 4096, /* objects that can wait at one time for the collector to look inside them */
    KEEP = 512,  /* page frames that the heap leaves to the rest of the kernel */
    FIRST = 256 * 1024, /* bytes of new objects before the first collection, and between any two at least */
};

/* The collector's byte of a header. */
#define MARK_MASK 0xff00ULL
#define REACHED   0x0100ULL /* in use, and what it holds is still to be looked at */
#define SCANNED   0x0200ULL /* in use, and so is everything it holds */

static uint64_t g_next = VM_HEAP_BASE; /* where the heap ends: the next object goes here when no free block will do */
static uint64_t g_end = VM_HEAP_BASE;  /* where the mapped part ends: a whole number of pages */

/* A free block is a header of the type LISP_FREE, whose length is the
 * block's own in words, and after it LISP_FREED in every word but the
 * second, which links the block into its list. A block of one word has no
 * room for the link and is in no list: it waits for the next collection to
 * join it to its neighbours. */
static lisp *g_bin[BINS + 1]; /* g_bin[n]: the free blocks of n words */
static uint64_t g_bins;       /* bit n: g_bin[n] is not empty */
static lisp *g_large;         /* the longer ones */
static uint64_t g_free_words, g_large_words; /* in all the lists, and in g_large */

static uint64_t g_since;           /* bytes of objects made since the last collection */
static uint64_t g_trigger = FIRST; /* how many of those it takes for the next one */
static uint64_t g_low;             /* with less room than this after a collection, the heap is full */
static int g_full;                 /* the last collection left less than that */
static uint64_t g_every, g_passed; /* collect at every g_every-th safe point, and how many have gone by */
static uint64_t g_collections;

static lisp *g_marks[MARKS];
static unsigned g_waiting;
static int g_overflow; /* an object was reached and there was no room in g_marks for it */

void lisp_heap_init(void)
{
    g_low = pmm_free_frames() / 16 * PAGE_SIZE;
}

/* For an image (image.c): the heap, which is empty, becomes a copy of the
 * bytes that a heap was when it was saved. Says 0 when it is not empty, or
 * when the machine has not the memory for that and for going on. What
 * comes back has been neither marked nor swept: the free blocks of the heap
 * that was saved are in no list until the next collection finds them, and
 * until then whatever is made goes after the last object. */
int lisp_heap_restore(const void *from, uint64_t bytes)
{
    if (g_next != VM_HEAP_BASE || bytes % sizeof(lisp) || bytes > VM_HEAP_SIZE ||
        pmm_free_frames() < KEEP + bytes / PAGE_SIZE + g_low / PAGE_SIZE)
        return 0;
    while (g_end - VM_HEAP_BASE < bytes) {
        uint64_t frame = pmm_alloc(1);

        if (!frame)
            return 0;
        vm_map(g_end, frame, 1, VM_WRITE);
        g_end += PAGE_SIZE;
    }
    memcpy((void *)(uintptr_t)VM_HEAP_BASE, from, bytes);
    g_next = VM_HEAP_BASE + bytes;
    return 1;
}

/* And empty again, for an image that could not be used after all: the
 * next object is the first, and the page frames go back to the kernel, so
 * that the heap begins the way it does on a machine without an image. */
void lisp_heap_empty(void)
{
    g_next = VM_HEAP_BASE;
    while (g_end > VM_HEAP_BASE) {
        uint64_t frame;

        g_end -= PAGE_SIZE;
        frame = vm_lookup(g_end);
        vm_unmap(g_end, 1);
        pmm_free(frame, 1);
    }
    memset(g_bin, 0, sizeof g_bin);
    g_bins = 0;
    g_large = NULL;
    g_free_words = g_large_words = 0;
    g_since = 0;
}

/* How many words the object under this header takes, the header included,
 * or 0 when it is no header at all. The one place that knows, for making
 * objects and for walking past them.
 *
 * It is written into the collector's two loops, and so is `reach` below,
 * where each could be a call. A collection asks this of every object in
 * the heap, twice, and reaches every word of every object that is in use:
 * some hundred thousand calls. Where the machine is emulated, as on CI, a
 * call to a function that lies on another page of the kernel than its
 * caller is several times as dear as one to a function on the same page
 * (QEMU chains the pieces of code that it translates only within a page),
 * and which functions share a page changes whenever any code before them
 * grows. That made a collection a seventh slower from one build to the
 * next, with nothing in this file changed, and the boot that collects at
 * every safe point with it. */
static inline __attribute__((always_inline)) uint64_t words_of(lisp header)
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
    case LISP_CONDITION:
        return sizeof(struct lisp_condition) / sizeof(lisp);
    case LISP_THREAD:
        return sizeof(struct lisp_thread) / sizeof(lisp);
    case LISP_LOCK:
        return sizeof(struct lisp_lock) / sizeof(lisp);
    case LISP_EVENT:
        return sizeof(struct lisp_event) / sizeof(lisp);
    case LISP_NATIVE:
        return sizeof(struct lisp_native) / sizeof(lisp);
    case LISP_FREE:
        return length;
    }
    return 0;
}

uint64_t lisp_object_words(lisp header)
{
    return words_of(header);
}

/* Memory that is free from here on, words long: its body holds LISP_FREED
 * already. */
static void put_free(lisp *block, uint64_t words)
{
    block[0] = lisp_header(LISP_FREE, words);
    if (words < 2)
        return;
    if (words <= BINS) {
        block[1] = (lisp)(uintptr_t)g_bin[words];
        g_bin[words] = block;
        g_bins |= 1ULL << words;
    } else {
        block[1] = (lisp)(uintptr_t)g_large;
        g_large = block;
        g_large_words += words;
    }
    g_free_words += words;
}

/* Does a block that long do for an object of words? It has to be the same
 * length, or leave a block that can be linked into a list. */
static int fits(uint64_t have, uint64_t words)
{
    return have == words || have >= words + 2;
}

/* A free block for an object of that many words, taken out of its list, or
 * NULL when none is long enough. Up to BINS words: a block of exactly that
 * length, or else the shortest longer one; what is left of a longer one is
 * a free block again. A long block that was cut goes back to the front of
 * its list, so the objects made one after the other lie side by side. */
static lisp *take(uint64_t words)
{
    lisp *block = NULL, **link;
    uint64_t have = 0, candidates;

    candidates = words <= BINS ? g_bins & (1ULL << words | ~0ULL << (words + 2)) : 0;
    if (candidates) {
        have = (uint64_t)__builtin_ctzll(candidates);
        block = g_bin[have];
        g_bin[have] = (lisp *)(uintptr_t)block[1];
        if (!g_bin[have])
            g_bins &= ~(1ULL << have);
    } else {
        for (link = &g_large; (block = *link); link = (lisp **)&block[1])
            if (fits(have = lisp_length(block[0]), words))
                break;
        if (!block)
            return NULL;
        *link = (lisp *)(uintptr_t)block[1];
        g_large_words -= have;
    }
    g_free_words -= have;
    /* Nothing may have written here since the collector freed it. */
    for (uint64_t i = 2; i < words; i++)
        if (block[i] != LISP_FREED)
            panic("lisp: the heap is damaged: %p was freed, and has been written to since: %llx",
                  (void *)&block[i], block[i]);
    if (have > words)
        put_free(block + words, have - words);
    return block;
}

/* A new object of that type and length, every word after the header zero:
 * as Lisp values those are fixnum zeroes, so an object is fit to be looked
 * at from the moment it exists. This never collects. When the machine has
 * no memory left for it, that is the end: whoever makes an object as large
 * as a program asks for looks at lisp_heap_room first, and for the rest
 * the evaluator stops a computation well before it comes to this. */
void *lisp_alloc(enum lisp_type type, uint64_t length)
{
    lisp header = lisp_header(type, length), *object;
    uint64_t words = lisp_object_words(header), bytes = words * sizeof(lisp);

    if (lisp_length(header) != length || words > (VM_HEAP_BASE + VM_HEAP_SIZE - g_next) / sizeof(lisp))
        panic("lisp: an object of length %llu does not fit in what is left of the heap region", length);
    object = take(words);
    if (!object) {
        while (g_end - g_next < bytes) {
            uint64_t frame = pmm_alloc(1);

            if (!frame)
                panic("lisp: out of memory: the heap has %llu KiB, and no page frame is free for more",
                      (g_end - VM_HEAP_BASE) >> 10);
            vm_map(g_end, frame, 1, VM_WRITE);
            g_end += PAGE_SIZE;
        }
        object = (lisp *)(uintptr_t)g_next;
        g_next += bytes;
    }
    g_since += bytes;
    if (g_since >= g_trigger)
        lisp_attention = 1; /* time to collect, at the next safe point */
    memset(object, 0, bytes);
    object[0] = header;
    return object;
}

/* The memory that an object of any length could still be made in, in
 * bytes: the page frames that are free, less the ones the heap leaves
 * alone, what is mapped past the heap's end, and the long free blocks. The
 * short ones are not counted: they are of use only to objects as short. */
static uint64_t room(void)
{
    uint64_t frames = pmm_free_frames();

    return (frames > KEEP ? (frames - KEEP) * PAGE_SIZE : 0) + (g_end - g_next) + g_large_words * sizeof(lisp);
}

/* Can an object that long be made, and the heap still not be full? For
 * whoever makes one as large as a program says: a short one always can. */
int lisp_heap_room(uint64_t words)
{
    uint64_t frames = pmm_free_frames(), bytes;

    if (words <= BINS)
        return 1;
    if (words > VM_HEAP_SIZE / sizeof(lisp))
        return 0;
    for (const lisp *block = g_large; block; block = (const lisp *)(uintptr_t)block[1])
        if (fits(lisp_length(block[0]), words))
            return 1;
    bytes = (frames > KEEP ? (frames - KEEP) * PAGE_SIZE : 0) + (g_end - g_next);
    return bytes >= words * sizeof(lisp) && bytes - words * sizeof(lisp) >= g_low / 2;
}

/* Walk the heap from its first object to its last and count the objects
 * of each type, the free blocks among them. Returns the bytes that objects
 * take. A word that is no header where one has to be, or an object that
 * runs past the end, means the heap is damaged. */
uint64_t lisp_heap_census(uint64_t count[LISP_TYPES])
{
    uint64_t at = VM_HEAP_BASE, in_use = 0;

    memset(count, 0, LISP_TYPES * sizeof count[0]);
    while (at < g_next) {
        lisp header = *(lisp *)(uintptr_t)at;
        uint64_t words = lisp_object_words(header);

        if (!words || words > (g_next - at) / sizeof(lisp))
            panic("lisp: the heap is damaged: at %llx the header is %llx", at, header);
        count[header & 0xff]++;
        if ((header & 0xff) != LISP_FREE)
            in_use += words * sizeof(lisp);
        at += words * sizeof(lisp);
    }
    return in_use;
}

/* The functions in the heap, by who runs them. A collection first leaves
 * only the ones that somebody can still call. */
void lisp_heap_functions(struct lisp_functions *count)
{
    memset(count, 0, sizeof *count);
    for (uint64_t at = VM_HEAP_BASE; at < g_next;) {
        lisp *object = (lisp *)(uintptr_t)at;
        uint64_t words = lisp_object_words(*object);

        if (!words || words > (g_next - at) / sizeof(lisp))
            panic("lisp: the heap is damaged: at %llx the header is %llx", at, *object);
        if ((*object & 0xff) == LISP_FUNCTION) {
            const struct lisp_function *f = (const struct lisp_function *)object;

            switch ((enum lisp_function_kind)lisp_length(f->header)) {
            case LISP_PRIMITIVE:
            case LISP_SPECIAL_OPERATOR:
                count->in_c++;
                break;
            case LISP_COMPILED:
                count->compiled++;
                count->native += f->entry != 0;
                break;
            case LISP_MACRO:
                if (lisp_is(f->code, LISP_FUNCTION)) {
                    count->macros++;
                    break;
                }
                /* fall through */
            case LISP_CLOSURE:
                count->walked++;
                break;
            }
        }
        at += words * sizeof(lisp);
    }
}

/* Every function in the heap that the compiler made is handed to EACH,
 * which makes no object meanwhile: for whoever goes through the functions
 * that there are (native.c). */
void lisp_heap_compiled(void (*each)(struct lisp_function *f, void *with), void *with)
{
    for (uint64_t at = VM_HEAP_BASE; at < g_next;) {
        lisp *object = (lisp *)(uintptr_t)at;
        uint64_t words = lisp_object_words(*object);

        if (!words || words > (g_next - at) / sizeof(lisp))
            panic("lisp: the heap is damaged: at %llx the header is %llx", at, *object);
        if ((*object & 0xff) == LISP_FUNCTION && lisp_length(*object) == LISP_COMPILED)
            each((struct lisp_function *)object, with);
        at += words * sizeof(lisp);
    }
}

void lisp_heap_state(struct lisp_heap *state)
{
    uint64_t count[LISP_TYPES];

    state->size = g_next - VM_HEAP_BASE;
    state->free = state->size - lisp_heap_census(count);
    state->collections = g_collections;
}

/* The object that a value points at, or NULL when it is a value that
 * points at nothing, a fixnum or a character. Anything else that is not
 * an object in the heap means that somebody held on to one across a safe
 * point without the collector knowing, or wrote where it should not have. */
static lisp *object_of(lisp x)
{
    static const uint8_t tag_of[LISP_TYPES] = {
        [LISP_CONS] = LISP_TAG_CONS,        [LISP_SYMBOL] = LISP_TAG_SYMBOL,   [LISP_STRING] = LISP_TAG_OBJECT,
        [LISP_VECTOR] = LISP_TAG_OBJECT,    [LISP_PACKAGE] = LISP_TAG_OBJECT,  [LISP_FUNCTION] = LISP_TAG_OBJECT,
        [LISP_STRUCTURE] = LISP_TAG_OBJECT, [LISP_CONDITION] = LISP_TAG_OBJECT, [LISP_THREAD] = LISP_TAG_OBJECT,
        [LISP_LOCK] = LISP_TAG_OBJECT,      [LISP_EVENT] = LISP_TAG_OBJECT,    [LISP_NATIVE] = LISP_TAG_OBJECT,
    };
    lisp *object = lisp_object(x);
    uint64_t type;

    if (lisp_is_fixnum(x) || (x & LISP_TAG_MASK) == LISP_TAG_IMMEDIATE)
        return NULL;
    if (x == LISP_FREED)
        panic("lisp: the collector came upon a value out of memory that was freed: something used an object "
              "that nothing held");
    if ((uint64_t)(uintptr_t)object < VM_HEAP_BASE || (uint64_t)(uintptr_t)object >= g_next)
        panic("lisp: the collector came upon %llx, which is no Lisp value: it points outside the heap", x);
    type = *object & 0xff;
    if (type >= LISP_TYPES || tag_of[type] != (x & LISP_TAG_MASK))
        panic("lisp: the collector came upon %llx, which points at no object of its kind: the header there is %llx",
              x, *object);
    return object;
}

/* x is in use. If it is an object, and this is the first time the
 * collector comes to it, it is marked, and waits to be looked into. */
static inline __attribute__((always_inline)) void reach(lisp x)
{
    lisp *object = object_of(x);

    if (!object || (*object & MARK_MASK))
        return;
    *object |= REACHED;
    if (g_waiting < MARKS)
        g_marks[g_waiting++] = object;
    else
        g_overflow = 1; /* it is marked, and the heap will be searched for it */
}

void lisp_reach(lisp x)
{
    reach(x);
}

/* Look into every object that waits: whatever it holds is in use too.
 * Every word after the header of an object is a value, except in a
 * string, which holds none. The last value of an object is followed at
 * once, without waiting: that is the CDR of a cons, so a list of any
 * length takes one place in g_marks, and the collector never calls itself. */
static void look_into_the_waiting(void)
{
    while (g_waiting) {
        lisp *object = g_marks[--g_waiting];

        while (object) {
            lisp header = *object;
            uint64_t words = (header & 0xff) == LISP_STRING ? 1 : words_of(header);

            *object = (header & ~MARK_MASK) | SCANNED;
            for (uint64_t i = 1; i + 1 < words; i++)
                reach(object[i]);
            object = words > 1 ? object_of(object[words - 1]) : NULL;
            if (object && (*object & MARK_MASK))
                object = NULL;
        }
    }
}

/* The free memory from start to end becomes one block, at the end of its
 * list: the lists come out with the lowest addresses first. */
static lisp **free_run(uint64_t start, uint64_t end, lisp **last_large)
{
    lisp *block = (lisp *)(uintptr_t)start;
    uint64_t words = (end - start) / sizeof(lisp);

    if (words <= BINS) {
        put_free(block, words);
        return last_large;
    }
    block[0] = lisp_header(LISP_FREE, words);
    block[1] = 0;
    *last_large = block;
    g_large_words += words;
    g_free_words += words;
    return (lisp **)&block[1];
}

/* Walk the heap. An object that is marked stays, without its mark. Every
 * run of the rest, objects that were not reached and blocks that were free
 * before, becomes one free block, filled with LISP_FREED. A run at the
 * very end of the heap is no block: the heap ends where it begins, and the
 * page frames past that go back to the kernel. Returns the bytes that
 * objects take afterwards. */
static uint64_t sweep(void)
{
    uint64_t at = VM_HEAP_BASE, run = 0, in_use = 0;
    lisp **last_large = &g_large;

    memset(g_bin, 0, sizeof g_bin);
    g_bins = 0;
    g_large = NULL;
    g_free_words = g_large_words = 0;
    while (at < g_next) {
        lisp *object = (lisp *)(uintptr_t)at, header = *object;
        uint64_t words = words_of(header);

        if (!words || words > (g_next - at) / sizeof(lisp))
            panic("lisp: the heap is damaged: at %llx the header is %llx", at, header);
        if (header & MARK_MASK) {
            *object = header & ~MARK_MASK;
            in_use += words * sizeof(lisp);
            if (run)
                last_large = free_run(run, at, last_large);
            run = 0;
        } else {
            if (!run)
                run = at;
            /* Code for the processor lies outside the heap, and goes with the object that held it. */
            if ((header & 0xff) == LISP_NATIVE)
                lisp_code_free(((const struct lisp_native *)object)->address);
            /* A block that was free holds LISP_FREED already, except where its header and its link are. */
            for (uint64_t i = 0; i < ((header & 0xff) == LISP_FREE && words > 2 ? 2 : words); i++)
                object[i] = LISP_FREED;
        }
        at += words * sizeof(lisp);
    }
    if (run) {
        g_next = run;
        while (g_end - g_next >= PAGE_SIZE) {
            uint64_t frame;

            g_end -= PAGE_SIZE;
            frame = vm_lookup(g_end);
            vm_unmap(g_end, 1);
            pmm_free(frame, 1);
        }
    }
    return in_use;
}

/* Free every object that nothing can reach. Returns how many bytes that
 * gave back. The caller has the runtime and is at a safe point: all it
 * holds is where lisp_eval_roots finds it, and what the other threads
 * hold is where lisp_thread_roots does. */
uint64_t lisp_collect(void)
{
    const lisp *roots = (const lisp *)&lisp_roots;
    uint64_t before = g_next - VM_HEAP_BASE - g_free_words * sizeof(lisp), in_use;

    lisp_reach(LISP_NIL);
    for (unsigned i = 0; i < sizeof lisp_roots / sizeof(lisp); i++)
        lisp_reach(roots[i]);
    lisp_eval_roots();
    lisp_thread_roots();
    look_into_the_waiting();
    while (g_overflow) {
        /* More objects waited than g_marks has room for. The ones that were left out are marked as
         * reached and nothing more, and the heap is walked to find them, as often as it takes. */
        g_overflow = 0;
        for (uint64_t at = VM_HEAP_BASE; at < g_next;) {
            lisp *object = (lisp *)(uintptr_t)at;
            uint64_t words = lisp_object_words(*object);

            if (!words)
                panic("lisp: the heap is damaged: at %llx the header is %llx", at, *object);
            if ((*object & MARK_MASK) == REACHED) {
                g_marks[g_waiting++] = object;
                look_into_the_waiting();
            }
            at += words * sizeof(lisp);
        }
    }
    in_use = sweep();

    /* The next one comes when as much again has been made as is in use now, and sooner when there is
     * not the room for that much. When the heap is full, a computation is about to be stopped, and a
     * quarter of what room there is has to do for what it does on its way out. */
    g_collections++;
    g_since = 0;
    g_passed = 0;
    g_full = room() < g_low;
    g_trigger = in_use < FIRST ? FIRST : in_use;
    if (g_trigger > room() / 2)
        g_trigger = room() / 2;
    if (g_full)
        g_trigger = room() / 4;
    return before - in_use;
}

/* The evaluator is at a safe point: everything it holds can be found.
 * Collect, if enough has been made since the last time, or if every nth
 * safe point is to collect. Says 0 when that was done and the heap is full
 * all the same, which is for the evaluator to make an error of. */
int lisp_heap_safe_point(void)
{
    if (g_every)
        lisp_attention = 1; /* the next safe point is to count as well */
    if (g_since < g_trigger && (!g_every || ++g_passed < g_every))
        return 1;
    lisp_collect();
    return !g_full;
}

/* For the top level, once a computation has been given up: if it was
 * stopped because the heap was full, what it held can be freed now. */
void lisp_collect_if_full(void)
{
    if (g_full)
        lisp_collect();
}

/* For testing: from now on every nth safe point collects, whether or not
 * it is time; 0 puts that right again. Says what n was before. With 1,
 * nothing that the evaluator fails to hold on to survives the next call. */
uint64_t lisp_collect_every(uint64_t n)
{
    uint64_t before = g_every;

    g_every = n;
    g_passed = 0;
    lisp_attention = 1;
    return before;
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

lisp lisp_make_condition(lisp type, lisp message, lisp slots)
{
    struct lisp_condition *c = lisp_alloc(LISP_CONDITION, 0);

    c->type = type;
    c->message = message;
    c->slots = slots;
    return (lisp)(uintptr_t)c | LISP_TAG_OBJECT;
}
