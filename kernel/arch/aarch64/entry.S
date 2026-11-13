/* AArch64: where the processor enters the kernel when it takes an exception
 * (Arm ARM, section D1.3), and the probes that the fault self-test provokes
 * exceptions with.
 *
 * The processor has two stack pointers at EL1. The kernel proper runs on
 * SP_EL0. An exception switches to SP_EL1, so a handler always has a stack
 * to run on, even when the exception is the first stack overflowing. */
#include "arch.h"

    .text

/* The vector table: sixteen entries of 128 bytes, four kinds of exception
 * (synchronous, IRQ, FIQ, SError) from each of four places. An entry makes
 * room for a struct frame, frees two registers, notes its own number, and
 * leaves the rest to exception_entry. */
    .macro vector number
    .balign 128
    sub sp, sp, #FRAME_SIZE
    stp x0, x1, [sp]
    mov x0, #\number
    b exception_entry
    .endm

    .globl exception_vectors
    .balign 2048
exception_vectors:
    vector 0    /* from the kernel proper, on SP_EL0 */
    vector 1
    vector 2
    vector 3
    vector 4    /* from an exception handler, on SP_EL1 */
    vector 5
    vector 6
    vector 7
    vector 8    /* from EL0 in 64-bit state: there is no such code */
    vector 9
    vector 10
    vector 11
    vector 12   /* from EL0 in 32-bit state: nor such */
    vector 13
    vector 14
    vector 15

/* Complete the frame (arch.h), hand its address to C, and resume with
 * whatever the frame holds afterwards. */
    .balign 128
exception_entry:
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    mrs x1, sp_el0
    mrs x2, elr_el1
    mrs x3, spsr_el1
    stp x30, x1, [sp, #240]
    stp x2, x3, [sp, #256]
    stp x0, xzr, [sp, #272]
    mov x0, sp
    mov x29, xzr                    /* no frame above this one for a debugger to follow */
    bl exception_dispatch
    ldp x2, x3, [sp, #256]
    ldp x30, x1, [sp, #240]
    msr spsr_el1, x3
    msr elr_el1, x2
    msr sp_el0, x1
    ldp x28, x29, [sp, #224]
    ldp x26, x27, [sp, #208]
    ldp x24, x25, [sp, #192]
    ldp x22, x23, [sp, #176]
    ldp x20, x21, [sp, #160]
    ldp x18, x19, [sp, #144]
    ldp x16, x17, [sp, #128]
    ldp x14, x15, [sp, #112]
    ldp x12, x13, [sp, #96]
    ldp x10, x11, [sp, #80]
    ldp x8, x9, [sp, #64]
    ldp x6, x7, [sp, #48]
    ldp x4, x5, [sp, #32]
    ldp x2, x3, [sp, #16]
    ldp x0, x1, [sp]
    add sp, sp, #FRAME_SIZE
    eret

/* The probes: each tries one access that the page tables may refuse and
 * returns 0 when it went through. When it faults, the handler restores the
 * stack pointer and the return address noted here and resumes at
 * probe_failed, which returns 1 to the probe's caller. */
    .macro probe_start
    adrp x9, probe_return
    add x9, x9, :lo12:probe_return
    mov x10, sp
    stp x10, x30, [x9]
    .endm

    .globl arch_probe_read          /* int arch_probe_read(uint64_t addr) */
arch_probe_read:
    probe_start
    ldrb w9, [x0]
    mov x0, #0
    ret

    .globl arch_probe_write         /* int arch_probe_write(uint64_t addr, uint8_t value) */
arch_probe_write:
    probe_start
    strb w1, [x0]
    mov x0, #0
    ret

    .globl arch_probe_exec          /* int arch_probe_exec(uint64_t addr): call it */
arch_probe_exec:
    probe_start
    stp x29, x30, [sp, #-16]!
    blr x0
    ldp x29, x30, [sp], #16
    mov x0, #0
    ret

    .globl arch_probe_push          /* int arch_probe_push(uint64_t sp): push with the stack pointer there */
arch_probe_push:
    probe_start
    mov sp, x0
    str x1, [sp, #-16]!
    mov sp, x10
    mov x0, #0
    ret

    .globl arch_probe_nothing       /* void arch_probe_nothing(void): code that is safe to call */
arch_probe_nothing:
    ret

    .globl probe_failed
probe_failed:
    mov x0, #1
    ret

    .bss
    .globl probe_return
    .balign 8
probe_return:
    .quad 0, 0
