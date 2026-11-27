/* The Lisp world on the machine that machine.c makes of this computer, as
 * far as it comes without code for a processor: what new_world does until
 * the language and the compiler are to be translated (kernel/lisp/lisp.c).
 * That is the collector's test in the empty heap; boot.lisp, and the
 * evaluator's texts; both once more with a collection at every safe point
 * of the evaluator, which a kernel does when its boot volume asks for it;
 * the compiler, and the texts as compiled code, a second time with a
 * collection at the safe points of that code; the compiler compiled by
 * itself, and boot.lisp by it; and the texts a third time, which compiled
 * code compiles by then.
 *
 * The functions for all of that belong to lisp.c alone, so this file is
 * that one, whole, with one function after it, and it is compiled like
 * every file of the kernel. The order below is new_world's: what changes
 * there before the processor's code is loaded changes here. */
#include "lisp/lisp.c"

static void language(void)
{
    struct lisp_heap heap;
    struct text printed;
    uint64_t collections, between;
    unsigned texts;
    int64_t depth;

    collector_selftest();
    load("boot.lisp");
    kprintf("lisp: boot.lisp is loaded\n");
    eval_selftest();

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

    load("compiler.lisp");
    compiler_selftest(1);
    load("compiler.lisp");
    load("boot.lisp");
    texts = eval_texts(&depth, own_form("clara.compiler:evaluate"), 0);
    kprintf("lisp: the compiler compiled itself and boot.lisp, and then the %u texts as before\n", texts);

    lisp_collect();
    lisp_heap_state(&heap);
    collections = heap.collections;
    evaluate_text("(funcall (compile nil '(lambda () (dotimes (i 20000) (list i i i)))))", &printed, 0);
    lisp_heap_state(&heap);
    if (heap.collections == collections)
        panic("lisp self-test: compiled code made 20000 lists and did not once stop to collect");
    collections = heap.collections;
    evaluate_text("(funcall (compile nil '(lambda () (labels ((grow (n) (if (= n 0) (list 1 2 3)"
                  " (progn (grow (- n 1)) (grow (- n 1)))))) (grow 15)))))",
                  &printed, 0);
    lisp_heap_state(&heap);
    if (heap.collections == collections)
        panic("lisp self-test: a compiled function called itself 60000 times and did not once stop to collect");
    heap_report();
}

void host_world(void)
{
    thread_join(lisp_first_thread(language));
}
