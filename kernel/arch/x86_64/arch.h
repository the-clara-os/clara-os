/* What the x86_64 files share with each other and with nobody else. */
#pragma once
#include "kernel.h"

static inline void outb(uint16_t port, uint8_t v)
{
    __asm__ volatile("outb %0, %1" : : "a"(v), "Nd"(port));
}

static inline uint8_t inb(uint16_t port)
{
    uint8_t v;
    __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
    return v;
}

static inline uint64_t rdmsr(uint32_t msr)
{
    uint32_t lo, hi;
    __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
    return (uint64_t)hi << 32 | lo;
}

static inline void wrmsr(uint32_t msr, uint64_t v)
{
    __asm__ volatile("wrmsr" : : "a"((uint32_t)v), "d"((uint32_t)(v >> 32)), "c"(msr));
}

/* What entry.S leaves on the stack for every exception and interrupt, lowest
 * address first. */
struct frame {
    uint64_t r15, r14, r13, r12, r11, r10, r9, r8, rdi, rsi, rbp, rbx, rdx, rcx, rax;
    uint64_t vector, error;            /* from the stub; the error code is the processor's when it has one */
    uint64_t rip, cs, rflags, rsp, ss; /* pushed by the processor */
};

/* The vectors the kernel hands out. 0 to 31 are the processor's exceptions,
 * and 32 to 47 are where the 8259s are parked, masked. */
#define VECTOR_TIMER    0xf0
#define VECTOR_SPURIOUS 0xff /* the local APIC's, when an interrupt vanishes before it is delivered */

/* entry.S */
extern const uint8_t interrupt_stubs[256][16]; /* one entry point per vector */
extern uint64_t probe_sp;                      /* the stack pointer of the probe in progress */
void probe_failed(void);                       /* where a probe that faulted is resumed */

/* interrupt.c */
void interrupt_handle(unsigned vector);        /* vectors 32 and up */
