/* What the AArch64 files share with each other and with nobody else.
 * entry.S includes this too, for the size of the frame. */
#pragma once

#define FRAME_SIZE 288 /* sizeof(struct frame) */

#ifndef __ASSEMBLER__
#include "kernel.h"

/* What entry.S saves for every exception, lowest address first. */
struct frame {
    uint64_t x[31];  /* x0 to x30 */
    uint64_t sp;     /* SP_EL0, the stack pointer of the kernel proper */
    uint64_t pc;     /* ELR_EL1: where to resume */
    uint64_t pstate; /* SPSR_EL1: the processor state to resume with */
    uint64_t vector; /* which of the sixteen entries of the vector table was taken */
    uint64_t unused; /* the stack pointer must stay a multiple of 16 */
};
_Static_assert(sizeof(struct frame) == FRAME_SIZE, "entry.S and struct frame disagree");

/* System registers have names, not addresses, so reading one takes an
 * instruction with the name in it. */
#define read_sysreg(name) ({                                        \
    uint64_t value_;                                                \
    __asm__ volatile("mrs %0, " #name : "=r"(value_));              \
    value_;                                                         \
})
#define write_sysreg(name, value) __asm__ volatile("msr " #name ", %0" : : "r"((uint64_t)(value)))

static inline void isb(void) /* what was written to a system register takes effect before the next instruction */
{
    __asm__ volatile("isb" ::: "memory");
}

/* entry.S */
extern const uint8_t exception_vectors[];
extern uint64_t probe_return[2]; /* the stack pointer and the return address of the probe in progress */
void probe_failed(void);         /* where a probe that faulted is resumed */

/* interrupt.c */
void interrupt_handle(void);     /* an IRQ has arrived */
void interrupt_quiet(void);      /* no more of them, so that the processor can sleep for good */
#endif
