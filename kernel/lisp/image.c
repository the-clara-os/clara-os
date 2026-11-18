/* The image: the Lisp world as a file, and a file as the Lisp world.
 *
 * Everything that is defined is in the heap: the packages and their
 * symbols, the functions, the structures, the values of the variables. So
 * a world is saved by writing its heap out, and a machine that finds such
 * a file on its boot volume when it starts takes it for its heap and does
 * not load lisp/ again. The heap is at the same addresses on every machine
 * and every boot (kernel/vm.c), so the file is the heap word for word, and
 * nothing in it has to be moved or put right for where it lies.
 *
 * What an image is: a few words that say what it is, the substrate's own
 * hold on the world (lisp_roots), and the heap from its first object, NIL,
 * to the end of its last. It is made in one go, by a function in C that
 * comes to no safe point, so no other thread has the runtime meanwhile and
 * the heap is caught between two moments (HEAP-IMAGE, below). Writing it
 * to a file is Lisp's part (lisp/boot.lisp, SAVE-IMAGE).
 *
 * What an image is not: the machine. A thread is a stack of calls into
 * the kernel's own code, which is somewhere else on every boot, so no
 * thread comes back: the world begins again where a new one does, with the
 * console and the drivers started afresh and the listener at its prompt.
 * The threads, locks and events of the heap come back as objects, without
 * what they were to the substrate: a thread that ran was stopped, a lock
 * is free, and nobody waits for anything. A special variable comes back
 * with the value it has outside every binding: for as long as the heap is
 * copied, the bindings of the thread that saves are undone, as they are
 * when a thread makes way for another.
 *
 * An image can outlive the kernel that saved it. A function in C is in
 * the heap as its place in a table, and the tables of another kernel are
 * other tables: so each such function is given its place again by its
 * name, which is what stays (lisp_function_rebind). What a newer kernel
 * has more of is added to the world. An image is refused, and the world
 * made from the files as if there had been none, when it is not whole,
 * when it was saved on the other architecture, when its objects are not
 * laid out as this kernel has them, or when it has a function in C that
 * this kernel has not. */
#include "lisp.h"

/* What the objects of an image are in memory: the tags and the types of
 * lisp.h, each struct there, and lisp_roots; and what compiled code is, the
 * items of enum lisp_code and the instructions of vm.c, since a world that
 * was saved holds its compiled functions. A change to any of them is a new
 * number here, and no older image is taken after it. */
#define FORMAT 2

struct image {
    char     magic[8];    /* "CLARAIMG" */
    uint64_t format;      /* FORMAT, as the kernel had it that saved this */
    char     machine[16]; /* arch_feature: what is defined in a world depends on the machine, by #+ and #- */
    char     version[16]; /* CLARA_VERSION of that kernel, for the boot report */
    uint64_t base;        /* VM_HEAP_BASE: where the heap of the image begins */
    uint64_t roots;       /* how many bytes of lisp_roots follow these words, */
    uint64_t heap;        /* and how many of the heap follow those */
    uint64_t checksum;    /* of both */
};

static const char magic[8] = { 'C', 'L', 'A', 'R', 'A', 'I', 'M', 'G' };

/* FNV-1a, a word at a time: any word that is not what it was, or not
 * where it was, changes the sum. It goes on from the sum so far, so that
 * the roots and the heap have one sum between them wherever each lies. */
#define SUM 0xcbf29ce484222325ULL /* of nothing yet */

static uint64_t checksum(uint64_t sum, const void *data, uint64_t bytes)
{
    const uint64_t *word = data;

    for (bytes /= sizeof *word; bytes--;)
        sum = (sum ^ *word++) * 0x100000001b3ULL;
    return sum;
}

static void put_name(char to[16], const char *name)
{
    size_t length = strlen(name);

    memset(to, 0, 16);
    memcpy(to, name, length < 15 ? length : 15);
}

/* (heap-image): the heap as it is now, in page frames of its own, as the
 * image that a file is to hold. Three values: the address of the frames,
 * how many bytes of them the image is, and how many frames there are, for
 * whoever gives them back (FREE-MEMORY). What nothing holds any more is
 * collected first: an image has no reason to keep it. */
LISP_PRIMITIVE(lisp_p_heap_image)
{
    struct lisp_heap heap;
    struct image *image;
    struct lisp_roots *roots;
    uint64_t bytes, pages, memory;

    (void)argc;
    (void)argv;
    lisp_collect();
    lisp_heap_state(&heap);
    bytes = sizeof *image + sizeof *roots + heap.size;
    pages = (bytes + PAGE_SIZE - 1) / PAGE_SIZE;
    if (!lisp_heap_room(pages * PAGE_SIZE / sizeof(lisp)) || !(memory = pmm_alloc(pages)))
        return lisp_fail_as("STORAGE-CONDITION", NULL, 0,
                            "there is no memory for an image of the heap: ~A page frames side by side",
                            lisp_fixnum((int64_t)pages));
    image = phys_ptr(memory);
    roots = (struct lisp_roots *)(image + 1);
    memset(image, 0, pages * PAGE_SIZE);

    /* From here to the end of the copy every special variable holds what it holds outside the
     * bindings of this thread, and those of the other threads were undone when they made way. */
    lisp_bindings_out();
    memcpy(roots, &lisp_roots, sizeof *roots);
    memcpy(roots + 1, (const void *)(uintptr_t)VM_HEAP_BASE, heap.size);
    lisp_bindings_in();

    /* The interrupts of this boot are not those of the next. */
    memset(roots->interrupts, 0, sizeof roots->interrupts);
    memcpy(image->magic, magic, sizeof magic);
    image->format = FORMAT;
    put_name(image->machine, arch_feature);
    put_name(image->version, CLARA_VERSION);
    image->base = VM_HEAP_BASE;
    image->roots = sizeof *roots;
    image->heap = heap.size;
    image->checksum = checksum(checksum(SUM, roots, sizeof *roots), roots + 1, heap.size);

    lisp_values.count = 3;
    lisp_values.value[0] = lisp_fixnum((int64_t)memory);
    lisp_values.value[1] = lisp_fixnum((int64_t)bytes);
    lisp_values.value[2] = lisp_fixnum((int64_t)pages);
    return lisp_values.value[0];
}

static void put(void *to, char c)
{
    (void)to;
    kputc(c);
}

/* The heap is an image's: every object in it is looked at once. A function
 * in C gets its place in this kernel's tables. A thread, a lock and an
 * event lose the word that was an address in the memory of the kernel that
 * saved them; a thread that was running then was stopped when that machine
 * was, and a lock that it held is free. Says 0, and why, when the heap is
 * not one that this kernel can run. */
static int settle(const char *name, uint64_t bytes)
{
    uint64_t at = VM_HEAP_BASE, end = VM_HEAP_BASE + bytes;

    while (at < end) {
        lisp *object = (lisp *)(uintptr_t)at, tagged = (lisp)at | LISP_TAG_OBJECT;
        uint64_t words = lisp_object_words(*object);

        if (!words || words > (end - at) / sizeof(lisp) || (at == VM_HEAP_BASE && (*object & 0xff) != LISP_SYMBOL)) {
            kprintf("lisp: %s is not resumed: its heap is not in order at %llx, where the header is %llx\n", name, at,
                    *object);
            return 0;
        }
        *object &= ~0xff00ULL; /* the collector's byte: nothing is marked in a heap that has not been looked at */
        switch (*object & 0xff) {
        case LISP_FUNCTION:
            if (!lisp_function_rebind(tagged)) {
                kprintf("lisp: %s is not resumed: it has the function ", name);
                lisp_princ(lisp_as_function(tagged)->name, put, NULL);
                kprintf(" in C, and this kernel has none of that name\n");
                return 0;
            }
            break;
        case LISP_THREAD: {
            struct lisp_thread *t = lisp_as_thread(tagged);

            if (t->state == lisp_fixnum(LISP_RUNNING)) {
                t->state = lisp_fixnum(LISP_STOPPED);
                t->function = LISP_NIL;
                t->result = LISP_NIL;
            }
            t->context = 0;
            t->waiting = 0;
            break;
        }
        case LISP_LOCK:
            lisp_as_lock(tagged)->owner = LISP_NIL;
            lisp_as_lock(tagged)->waiting = 0;
            break;
        case LISP_EVENT:
            lisp_as_event(tagged)->waiting = 0;
            break;
        }
        at += words * sizeof(lisp);
    }
    return 1;
}

/* A file of the boot volume that has the name of an image: the heap and
 * the roots become what it holds, if it is one that this kernel can take.
 * Says 1 when they have, and otherwise 0, with the reason in the boot
 * report and the heap as empty as it was. */
int lisp_image_load(const struct boot_file *file)
{
    const struct image *image = (const struct image *)file->data;
    const struct lisp_roots *roots = (const struct lisp_roots *)(image + 1);
    char machine[17] = { 0 }, version[17] = { 0 };

    if (file->size < sizeof *image || memcmp(image->magic, magic, sizeof magic)) {
        kprintf("lisp: %s is not resumed: it does not begin the way an image does\n", file->name);
        return 0;
    }
    memcpy(machine, image->machine, sizeof image->machine);
    memcpy(version, image->version, sizeof image->version);
    if (image->format != FORMAT || image->base != VM_HEAP_BASE || image->roots != sizeof *roots) {
        kprintf("lisp: %s is not resumed: ClaraOS %s saved it, with objects that are not laid out as they are here\n",
                file->name, version);
        return 0;
    }
    if (strlen(machine) != strlen(arch_feature) || memcmp(machine, arch_feature, strlen(arch_feature))) {
        kprintf("lisp: %s is not resumed: it was saved on %s, and this machine is %s\n", file->name, machine,
                arch_feature);
        return 0;
    }
    if (image->heap % sizeof(lisp) || image->heap > VM_HEAP_SIZE ||
        file->size != sizeof *image + sizeof *roots + image->heap) {
        kprintf("lisp: %s is not resumed: it is %llu bytes long, and not as long as it says it is\n", file->name,
                file->size);
        return 0;
    }
    if (!lisp_heap_restore(roots + 1, image->heap)) {
        kprintf("lisp: %s is not resumed: the machine has no memory for its heap of %llu KiB\n", file->name,
                image->heap >> 10);
        return 0;
    }
    /* The sum is taken of the heap where it lies now: it says that the file is what was saved, and
     * that what was copied is what the file held. */
    if (checksum(checksum(SUM, roots, sizeof *roots), (const void *)(uintptr_t)VM_HEAP_BASE, image->heap) !=
        image->checksum) {
        kprintf("lisp: %s is not resumed: it is not what was saved, by its checksum\n", file->name);
        lisp_heap_empty();
        return 0;
    }
    memcpy(&lisp_roots, roots, sizeof lisp_roots);
    memset(lisp_roots.interrupts, 0, sizeof lisp_roots.interrupts);
    if (!settle(file->name, image->heap)) {
        memset(&lisp_roots, 0, sizeof lisp_roots);
        lisp_heap_empty();
        return 0;
    }
    kprintf("lisp: the heap is an image: %llu KiB that ClaraOS %s saved, from %s on the boot volume\n",
            image->heap >> 10, version, file->name);
    return 1;
}
