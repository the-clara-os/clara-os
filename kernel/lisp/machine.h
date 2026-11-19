/* What entry.S has to know of the Lisp runtime, for the two routines there
 * that stand between C and code for the processor: where a few words lie.
 * Numbers and nothing else, so that the assembler can read this too;
 * native.c holds each of them against the struct that it is taken from. */
#pragma once

#define MACHINE_SP        0   /* struct lisp_machine: the top of the value stack, */
#define MACHINE_ATTENTION 40  /* and the word that says a safe point has something to look at */

/* From the tagged address of an object: */
#define OBJECT_TYPE       (-5) /* the lowest byte of its header, which says what it is */
#define SYMBOL_FUNCTION   29  /* a symbol's function */
#define FUNCTION_ENTRY    27  /* a function's entry for code of the processor's, or 0 */
#define TAG_SYMBOL        3
#define TAG_OBJECT        5
#define TYPE_FUNCTION     6   /* LISP_FUNCTION */

/* Code for the processor begins the same way on both architectures, in
 * as many bytes (lisp/native.lisp): at the code's first byte it is
 * entered from C, with the call's local variables made already; */
#define NATIVE_LEAVE      12  /* here a call ends that an exit is passing through; */
#define NATIVE_FAST       20  /* and here it is entered by other code for the processor, with the arguments
                                 where they were pushed. This is the address that a function keeps. */
