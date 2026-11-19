/* Code for the processor.
 *
 * The compiler makes instructions for a machine that the substrate has
 * (vm.c), and lisp/native.lisp makes of those the instructions of the
 * processor itself, which then runs a function without the machine in
 * between. This file is the substrate's part in that: where such code
 * lies, how it gets there, and how the heap holds on to it.
 *
 * It lies in a region of its own, the same addresses on every machine and
 * every boot (kernel/vm.c), and so apart from the heap, whose memory can be
 * written and for that reason cannot be run. The region is mapped to be
 * run and never to be written. What is written there goes through the
 * address that its page frames have as RAM, where they can be written and
 * not run: no address is both, as on the rest of the machine, and the one
 * function that writes code is here (put).
 *
 * The region is one run of pieces, each with two words before it that say
 * how long it is and whether it is in use. A piece is the code of one
 * function. The heap has an object for it (struct lisp_native, lisp.h),
 * which the function's code holds: when the collector frees that object,
 * the piece is free, and is filled with what the processor refuses to run.
 *
 * Code here names nothing of the kernel's by its address, since the kernel
 * is somewhere else on every boot and a world that is saved holds its code
 * (image.c). Whatever it needs of the kernel it reaches through struct
 * lisp_machine, whose address it is handed in a register when it is
 * entered. lisp/native.lisp is told where the words of that struct and of
 * the objects are by NATIVE-LAYOUT, below, so the numbers are written down
 * once, here and in machine.h.
 *
 * That the code does what the function's instructions say is the word of
 * whoever made it, like the stack that the instructions themselves claim:
 * the function that puts code here is in CLARA.UNSAFE. */
#include "eval.h"

enum {
    KEEP = 512, /* page frames that the region leaves to the rest of the kernel, like the heap */
    CHUNK = 256, /* words of code that are copied at a time */
};

/* What stands before every piece. Both words are read where the region is
 * mapped, and written like the code. */
struct piece {
    uint64_t bytes; /* of the piece, these two words among them: a multiple of 16 */
    uint64_t state; /* IN_USE or FREE: anything else, and the region is damaged */
};
#define IN_USE 0x65737520ULL
#define FREE   0x65657266ULL

static uint64_t g_next = VM_CODE_BASE; /* where the last piece ends */
static uint64_t g_end = VM_CODE_BASE;  /* where the mapped part ends: a whole number of pages */
static uint64_t g_free;                /* bytes in the pieces that are free */
static uint64_t g_pieces, g_made;

_Static_assert(offsetof(struct lisp_machine, sp) == MACHINE_SP, "machine.h and struct lisp_machine disagree");
_Static_assert(offsetof(struct lisp_machine, attention) == MACHINE_ATTENTION,
               "machine.h and struct lisp_machine disagree");
_Static_assert(offsetof(struct lisp_symbol, function) - LISP_TAG_SYMBOL == SYMBOL_FUNCTION,
               "machine.h and struct lisp_symbol disagree");
_Static_assert(offsetof(struct lisp_function, entry) - LISP_TAG_OBJECT == FUNCTION_ENTRY,
               "machine.h and struct lisp_function disagree");
_Static_assert(LISP_TAG_SYMBOL == TAG_SYMBOL && LISP_TAG_OBJECT == TAG_OBJECT && LISP_FUNCTION == TYPE_FUNCTION &&
                   0 - (int)LISP_TAG_OBJECT == OBJECT_TYPE,
               "machine.h and lisp.h disagree");

/* What code for the processor calls, where it finds it. */
void lisp_native_init(void)
{
    lisp_machine.call = lisp_native_call;
    lisp_machine.step = lisp_native_step;
    lisp_machine.unwinding = lisp_native_unwinding;
    lisp_machine.safe_point = lisp_native_safe_point;
    lisp_machine.arguments = lisp_native_arguments;
    lisp_machine.finish = lisp_native_finish;
    lisp_machine.stack_full = lisp_native_stack_full;
}

/* Bytes go into the region, through the addresses that its page frames
 * have as RAM. */
static void put(uint64_t va, const void *from, uint64_t bytes)
{
    const uint8_t *source = from;

    while (bytes) {
        uint64_t offset = va & (PAGE_SIZE - 1), n = PAGE_SIZE - offset;

        if (n > bytes)
            n = bytes;
        memcpy((uint8_t *)phys_ptr(vm_lookup(va - offset)) + offset, source, n);
        va += n;
        source += n;
        bytes -= n;
    }
}

/* That much of the region, a multiple of four bytes, becomes what the
 * processor refuses to run: a jump to code that is gone is a fault, and
 * not whatever the next function there happens to do. */
static void refuse(uint64_t va, uint64_t bytes)
{
    uint32_t traps[CHUNK];

    for (unsigned i = 0; i < CHUNK; i++)
        traps[i] = arch_code_trap;
    while (bytes) {
        uint64_t n = bytes < sizeof traps ? bytes : sizeof traps;

        put(va, traps, n);
        va += n;
        bytes -= n;
    }
}

static void head(uint64_t at, uint64_t bytes, uint64_t state)
{
    struct piece piece = { bytes, state };

    put(at, &piece, sizeof piece);
}

static const struct piece *piece_at(uint64_t at)
{
    const struct piece *piece = (const struct piece *)(uintptr_t)at;

    if ((piece->state != IN_USE && piece->state != FREE) || piece->bytes < sizeof *piece || piece->bytes % 16 ||
        piece->bytes > g_next - at)
        panic("lisp: the code for the processor is damaged: at %llx a piece says that it is %llu bytes, and %llx",
              at, piece->bytes, piece->state);
    return piece;
}

/* Room for that many bytes of code: where they go, or 0 when the machine
 * has no memory for them. The first free piece that is long enough is
 * taken, free pieces that lie side by side being one piece from then on;
 * and with none, the region grows. */
static uint64_t take(uint64_t bytes)
{
    uint64_t need = (bytes + sizeof(struct piece) + 15) & ~15ULL;

    for (uint64_t at = VM_CODE_BASE; g_free >= need && at < g_next;) {
        const struct piece *piece = piece_at(at);
        uint64_t whole = piece->bytes;

        if (piece->state == FREE) {
            while (at + whole < g_next && piece_at(at + whole)->state == FREE) {
                uint64_t more = piece_at(at + whole)->bytes;

                refuse(at + whole, sizeof *piece);
                whole += more;
            }
            if (whole == need || whole >= need + 2 * sizeof *piece) {
                if (whole > need)
                    head(at + need, whole - need, FREE);
                head(at, need, IN_USE);
                g_free -= need;
                return at + sizeof *piece;
            }
            if (whole != piece->bytes)
                head(at, whole, FREE);
        }
        at += whole;
    }
    if (need > VM_CODE_BASE + VM_CODE_SIZE - g_next)
        return 0;
    while (g_end - g_next < need) {
        uint64_t frame = pmm_free_frames() > KEEP ? pmm_alloc(1) : 0;
        uint32_t *words;

        if (!frame)
            return 0;
        words = phys_ptr(frame);
        for (unsigned i = 0; i < PAGE_SIZE / sizeof *words; i++)
            words[i] = arch_code_trap;
        vm_map(g_end, frame, 1, VM_EXEC);
        g_end += PAGE_SIZE;
    }
    head(g_next, need, IN_USE);
    g_next += need;
    return g_next - need + sizeof(struct piece);
}

/* The free pieces at the end of the region are no pieces any more: the
 * region ends where its last piece in use does, and the page frames past
 * that go back to the kernel. */
static void trim(void)
{
    uint64_t last = VM_CODE_BASE;

    for (uint64_t at = VM_CODE_BASE; at < g_next; at += piece_at(at)->bytes)
        if (piece_at(at)->state == IN_USE)
            last = at + piece_at(at)->bytes;
    if (last < g_next) {
        g_free -= g_next - last;
        refuse(last, g_next - last);
        g_next = last;
    }
    while (g_end - g_next >= PAGE_SIZE) {
        uint64_t frame;

        g_end -= PAGE_SIZE;
        frame = vm_lookup(g_end);
        vm_unmap(g_end, 1);
        pmm_free(frame, 1);
    }
}

/* From the collector's sweep: the object that held this code is freed, so
 * nothing can call it any more. */
void lisp_code_free(lisp address)
{
    uint64_t at = (uint64_t)address - sizeof(struct piece);
    const struct piece *piece;

    if (at < VM_CODE_BASE || at >= g_next || at % 16)
        panic("lisp: the heap is damaged: code for the processor at %llx, where there is none", (uint64_t)address);
    piece = piece_at(at);
    if (piece->state != IN_USE)
        panic("lisp: the code for the processor at %llx is freed twice", (uint64_t)address);
    refuse(at + sizeof *piece, piece->bytes - sizeof *piece);
    head(at, piece->bytes, FREE);
    g_free += piece->bytes;
    g_pieces--;
    if (g_free == g_next - VM_CODE_BASE)
        trim(); /* nothing is in use: the region is empty again, and its memory the kernel's */
}

void lisp_code_state(struct lisp_code_state *state)
{
    state->size = g_next - VM_CODE_BASE;
    state->free = g_free;
    state->pieces = g_pieces;
    state->made = g_made;
}

int lisp_code_holds(uint64_t address)
{
    return address >= VM_CODE_BASE && address < g_next;
}

/* For an image (image.c): the region as it lies, without the free pieces
 * at its end. The code in it names no address of this kernel's, so the
 * bytes are good for the next boot as they are. */
uint64_t lisp_code_bytes(void)
{
    trim();
    return g_next - VM_CODE_BASE;
}

void lisp_code_save(void *to)
{
    memcpy(to, (const void *)(uintptr_t)VM_CODE_BASE, g_next - VM_CODE_BASE);
}

/* And the other way: the region, which is empty, becomes a copy of those
 * bytes. Says 0 when it is not empty, when the machine has not the memory,
 * or when the bytes are not pieces one after the other. */
int lisp_code_restore(const void *from, uint64_t bytes)
{
    if (g_next != VM_CODE_BASE || bytes % 16 || bytes > VM_CODE_SIZE ||
        pmm_free_frames() < KEEP + bytes / PAGE_SIZE + 1)
        return 0;
    while (g_end - VM_CODE_BASE < bytes) {
        uint64_t frame = pmm_alloc(1);

        if (!frame) {
            lisp_code_empty();
            return 0;
        }
        vm_map(g_end, frame, 1, VM_EXEC);
        g_end += PAGE_SIZE;
    }
    put(VM_CODE_BASE, from, bytes);
    if (g_end > VM_CODE_BASE + bytes)
        refuse(VM_CODE_BASE + bytes, g_end - VM_CODE_BASE - bytes);
    g_next = VM_CODE_BASE + bytes;
    for (uint64_t at = VM_CODE_BASE; at < g_next;) {
        const struct piece *piece = (const struct piece *)(uintptr_t)at;

        if ((piece->state != IN_USE && piece->state != FREE) || piece->bytes < sizeof *piece || piece->bytes % 16 ||
            piece->bytes > g_next - at) {
            lisp_code_empty();
            return 0;
        }
        if (piece->state == FREE)
            g_free += piece->bytes;
        else
            g_pieces++;
        at += piece->bytes;
    }
    arch_code_written(VM_CODE_BASE, bytes);
    return 1;
}

void lisp_code_empty(void)
{
    g_next = VM_CODE_BASE;
    g_free = g_pieces = 0;
    while (g_end > VM_CODE_BASE) {
        uint64_t frame;

        g_end -= PAGE_SIZE;
        frame = vm_lookup(g_end);
        vm_unmap(g_end, 1);
        pmm_free(frame, 1);
    }
}

/* Where code for the processor enters a function of that code, or 0 when
 * the machine of vm.c is what runs it. */
uint64_t lisp_native_entry(lisp code)
{
    lisp native = lisp_as_vector(code)->items[LISP_CODE_NATIVE];

    return lisp_is(native, LISP_NATIVE) ? (uint64_t)lisp_as_native(native)->address + NATIVE_FAST : 0;
}

/* (clara.unsafe:native-layout): where the words lie that code for the
 * processor reads and writes, as a list of names and numbers, for
 * lisp/native.lisp. In the machine's words (struct lisp_machine) a number
 * is how far the word is from the address that the code is handed; in an
 * object, how far from the object's value, the tag taken off already. */
LISP_PRIMITIVE(lisp_p_native_layout)
{
    static const struct {
        const char *name;
        int64_t value;
    } layout[] = {
        { "SP", offsetof(struct lisp_machine, sp) },
        { "UNWIND", offsetof(struct lisp_machine, unwind.to) },
        { "ATTENTION", offsetof(struct lisp_machine, attention) },
        { "BOUND", offsetof(struct lisp_machine, bound) },
        { "COUNT", offsetof(struct lisp_machine, values.count) },
        { "ORIGINAL", offsetof(struct lisp_machine, original) },
        { "STACK-END", offsetof(struct lisp_machine, stack_end) },
        { "C-LIMIT", offsetof(struct lisp_machine, c_limit) },
        { "T", offsetof(struct lisp_machine, t) },
        { "CALL", offsetof(struct lisp_machine, call) },
        { "STEP", offsetof(struct lisp_machine, step) },
        { "UNWINDING", offsetof(struct lisp_machine, unwinding) },
        { "SAFE-POINT", offsetof(struct lisp_machine, safe_point) },
        { "ARGUMENTS", offsetof(struct lisp_machine, arguments) },
        { "FINISH", offsetof(struct lisp_machine, finish) },
        { "STACK-FULL", offsetof(struct lisp_machine, stack_full) },
        { "LEAVE", NATIVE_LEAVE },
        { "FAST", NATIVE_FAST },
        { "CAR", (int64_t)offsetof(struct lisp_cons, car) - (int64_t)LISP_TAG_CONS },
        { "CDR", (int64_t)offsetof(struct lisp_cons, cdr) - (int64_t)LISP_TAG_CONS },
        { "VALUE", (int64_t)offsetof(struct lisp_symbol, value) - (int64_t)LISP_TAG_SYMBOL },
        { "HEADER", 0 - (int64_t)LISP_TAG_OBJECT },
        { "ITEMS", (int64_t)offsetof(struct lisp_vector, items) - (int64_t)LISP_TAG_OBJECT },
        { "CODE", (int64_t)offsetof(struct lisp_function, code) - (int64_t)LISP_TAG_OBJECT },
        { "ENV", (int64_t)offsetof(struct lisp_function, env) - (int64_t)LISP_TAG_OBJECT },
        { "CONSTANTS", LISP_CODE_CONSTANTS },
        { "TAG-CONS", LISP_TAG_CONS },
        { "TAG-OBJECT", LISP_TAG_OBJECT },
        { "TYPE-VECTOR", LISP_VECTOR },
        { "UNBOUND", LISP_UNBOUND },
        { "HIDDEN", LISP_NATIVE_HIDDEN },
    };
    lisp list = LISP_NIL;

    (void)argc;
    (void)argv;
    for (unsigned i = sizeof layout / sizeof layout[0]; i--;) {
        list = lisp_cons(lisp_fixnum(layout[i].value), list);
        list = lisp_cons(lisp_symbol_in(lisp_roots.keyword, layout[i].name, 1), list);
    }
    return list;
}

/* (clara.unsafe:install-native-code code words hidden): the code for the
 * processor that was made of the instructions of CODE, which is what the
 * compiler made of a function. WORDS is that code, four bytes to a number,
 * the lowest first. HIDDEN says whether a call of it keeps words for its
 * records and its bindings, which it does when its instructions make
 * either. Every function that is made of CODE from now on is entered
 * there by other code for the processor, and by everybody else too.
 * Returns how many bytes it is. */
LISP_PRIMITIVE(lisp_p_install_native_code)
{
    const struct lisp_vector *code = lisp_as_vector(argv[0]), *words = lisp_as_vector(argv[1]);
    struct lisp_native *native;
    uint32_t chunk[CHUNK];
    uint64_t count, address;

    (void)argc;
    if (!lisp_is(argv[0], LISP_VECTOR) || lisp_length(code->header) != LISP_CODE_ITEMS)
        return lisp_wants("what the compiler makes of a function", argv[0]);
    if (code->items[LISP_CODE_NATIVE] != LISP_NIL)
        return lisp_fail("~S has code for the processor already", code->items[LISP_CODE_NAME]);
    if (!lisp_is(argv[1], LISP_VECTOR) || lisp_length(words->header) * sizeof(uint32_t) <= NATIVE_FAST)
        return lisp_wants("a vector of the words of code for the processor", argv[1]);
    if (argv[2] != lisp_fixnum(0) && argv[2] != lisp_fixnum(LISP_NATIVE_HIDDEN))
        return lisp_wants("0, or the number of words that a call hides", argv[2]);
    count = lisp_length(words->header);
    for (uint64_t i = 0; i < count; i++)
        if (!lisp_is_fixnum(words->items[i]) || words->items[i] > lisp_fixnum(0xffffffffLL))
            return lisp_wants("a number of 32 bits", words->items[i]);
    address = take(count * sizeof(uint32_t));
    if (!address)
        return lisp_fail_as("STORAGE-CONDITION", NULL, 0, "there is no memory for ~A bytes of code for the processor",
                            lisp_fixnum((int64_t)(count * sizeof(uint32_t))));
    for (uint64_t i = 0; i < count;) {
        unsigned n = 0;

        while (n < CHUNK && i < count)
            chunk[n++] = (uint32_t)lisp_fixnum_value(words->items[i++]);
        put(address + (i - n) * sizeof(uint32_t), chunk, n * sizeof(uint32_t));
    }
    arch_code_written(address, count * sizeof(uint32_t));
    native = lisp_alloc(LISP_NATIVE, 0);
    native->address = (lisp)address;
    native->bytes = lisp_fixnum((int64_t)(count * sizeof(uint32_t)));
    native->hidden = argv[2];
    lisp_as_vector(argv[0])->items[LISP_CODE_NATIVE] = (lisp)(uintptr_t)native | LISP_TAG_OBJECT;
    g_pieces++;
    g_made++;
    return native->bytes;
}

/* (clara.unsafe:native-code-bytes code): how many bytes of code for the
 * processor there are for what the compiler made of a function, or NIL. */
LISP_PRIMITIVE(lisp_p_native_code_bytes)
{
    (void)argc;
    if (!lisp_is(argv[0], LISP_VECTOR) || lisp_length(lisp_as_vector(argv[0])->header) != LISP_CODE_ITEMS)
        return lisp_wants("what the compiler makes of a function", argv[0]);
    return lisp_is(lisp_as_vector(argv[0])->items[LISP_CODE_NATIVE], LISP_NATIVE)
               ? lisp_as_native(lisp_as_vector(argv[0])->items[LISP_CODE_NATIVE])->bytes
               : LISP_NIL;
}

/* (clara.unsafe:native-function function [again]): whether the processor
 * runs that function itself. With AGAIN, a compiled function is asked once
 * more first: one that was made before its code had code for the processor
 * is entered there from now on. */
LISP_PRIMITIVE(lisp_p_native_function)
{
    struct lisp_function *f = lisp_as_function(argv[0]);

    if (!lisp_is(argv[0], LISP_FUNCTION))
        return lisp_wants("a function", argv[0]);
    if (argc > 1 && argv[1] != LISP_NIL && lisp_function_kind(argv[0]) == LISP_COMPILED)
        f->entry = (lisp)lisp_native_entry(f->code);
    return f->entry ? lisp_roots.t : LISP_NIL;
}
