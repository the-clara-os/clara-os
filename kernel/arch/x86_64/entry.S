/* x86_64: where the processor enters the kernel when it takes an exception
 * or an interrupt (Intel SDM volume 3, chapter 6), and the probes that the
 * fault self-test provokes exceptions with.
 *
 * This is the 64-bit Microsoft calling convention, like the rest of the
 * kernel: the first two arguments arrive in rcx and rdx, the result leaves
 * in rax, and a caller keeps 32 bytes free above the return address. */
#include "lisp/machine.h"

    .text

/* One entry point per vector, 16 bytes apart, so that the IDT can be filled
 * in by counting. For some exceptions the processor pushes an error code
 * and for the others it does not; a stub of the second kind pushes a zero
 * in its place, and every frame has the same shape. */
    .globl interrupt_stubs
    .balign 16
interrupt_stubs:
vector = 0
    .rept 256
    .balign 16
    .if vector != 8 && (vector < 10 || vector > 14) && vector != 17 && vector != 21 && vector != 29 && vector != 30
    pushq $0
    .endif
    pushq $vector
    jmp interrupt_entry
vector = vector + 1
    .endr

/* Save every register below what the processor and the stub pushed, which
 * completes a struct frame (arch.h), and hand its address to C. The
 * processor aligned the stack before it pushed, and the frame is a
 * multiple of 16 bytes, so the stack is aligned for the call. */
interrupt_entry:
    push %rax
    push %rcx
    push %rdx
    push %rbx
    push %rbp
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15
    cld
    mov %rsp, %rcx
    sub $32, %rsp
    call interrupt_dispatch
    add $32, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rdi
    pop %rsi
    pop %rbp
    pop %rbx
    pop %rdx
    pop %rcx
    pop %rax
    add $16, %rsp                   /* the vector and the error code */
    iretq

/* The probes: each tries one access that the page tables may refuse and
 * returns 0 when it went through. When it faults, the handler puts
 * probe_sp back into rsp and resumes at probe_failed, which returns 1 to
 * the probe's caller. So a probe needs to note only where its stack was. */

    .globl arch_probe_read          /* int arch_probe_read(uint64_t addr) */
arch_probe_read:
    mov %rsp, probe_sp(%rip)
    movb (%rcx), %al
    xor %eax, %eax
    ret

    .globl arch_probe_write         /* int arch_probe_write(uint64_t addr, uint8_t value) */
arch_probe_write:
    mov %rsp, probe_sp(%rip)
    movb %dl, (%rcx)
    xor %eax, %eax
    ret

    .globl arch_probe_exec          /* int arch_probe_exec(uint64_t addr): call it */
arch_probe_exec:
    mov %rsp, probe_sp(%rip)
    sub $40, %rsp
    call *%rcx
    add $40, %rsp
    xor %eax, %eax
    ret

    .globl arch_probe_push          /* int arch_probe_push(uint64_t sp): push with the stack pointer there */
arch_probe_push:
    mov %rsp, probe_sp(%rip)
    mov %rcx, %rsp
    push %rax
    mov probe_sp(%rip), %rsp
    xor %eax, %eax
    ret

    .globl arch_probe_nothing       /* void arch_probe_nothing(void): code that is safe to call */
arch_probe_nothing:
    ret

    .globl probe_failed
probe_failed:
    mov $1, %eax
    ret

/* Code for the processor (kernel/lisp/native.c, lisp/native.lisp): what the
 * Lisp world makes of its functions, and what the two routines here stand
 * between C and. Such code keeps five registers for itself, which a
 * function in C leaves as it found them:
 *
 *   r15  the address of lisp_machine: everything of the kernel's is reached from it
 *   rbx  the top of the value stack, while the code runs; lisp_machine has it across a call into C
 *   rsi  the local variables of the call that is running
 *   r14  the constants of its function
 *   rdi  NIL
 *
 * and passes what it has in hand in rcx, rdx, r8 and r9, which is where a
 * function in C takes its arguments. A function of such code is entered
 * with itself in rcx. It returns its first value there, with the value
 * stack cut back to where the function stood on it. */

/* lisp lisp_native_enter(const void *code, lisp *locals, lisp function, struct lisp_machine *machine, lisp nil)
 * From C into such code: a call whose local variables are made already
 * (lisp_call_compiled). Five registers are pushed, which leaves the stack
 * as a call wants it. */
    .globl lisp_native_enter
lisp_native_enter:
    push %rbx
    push %rsi
    push %rdi
    push %r14
    push %r15
    mov 80(%rsp), %rdi              /* the fifth argument, above the five and the return address */
    mov %rcx, %rax
    mov %rdx, %rsi
    mov %r8, %rcx
    mov %r9, %r15
    mov MACHINE_SP(%r15), %rbx
    call *%rax
    mov %rcx, %rax
    pop %r15
    pop %r14
    pop %rdi
    pop %rsi
    pop %rbx
    ret

/* How such code calls a function: the function, or the symbol that names
 * it, and after it edx arguments are on top of the value stack. When what
 * is called is such code too, and no safe point has anything to look at,
 * this goes straight on into it, and it returns to whoever called this.
 * Everything else is C's to sort out: another kind of function, something
 * that is no function, a safe point (lisp_native_slow_call). */
    .globl lisp_native_call
lisp_native_call:
    lea (,%rdx,8), %r10
    mov %rbx, %r11
    sub %r10, %r11                  /* the first argument */
    mov -8(%r11), %rcx
    mov %ecx, %eax
    and $7, %eax
    cmp $TAG_SYMBOL, %eax
    jne 1f
    mov SYMBOL_FUNCTION(%rcx), %rcx
    mov %ecx, %eax
    and $7, %eax
1:  cmp $TAG_OBJECT, %eax
    jne 2f
    cmpb $TYPE_FUNCTION, OBJECT_TYPE(%rcx)
    jne 2f
    mov FUNCTION_ENTRY(%rcx), %rax
    test %rax, %rax
    jz 2f
    cmpl $0, MACHINE_ATTENTION(%r15)
    jne 2f
    mov %rcx, -8(%r11)              /* the function itself, in use for as long as it runs */
    jmp *%rax
2:  mov %rbx, MACHINE_SP(%r15)
    mov %rdx, %rcx
    sub $40, %rsp                   /* 32 bytes for the callee, and 8 that put the stack right for a call */
    call lisp_native_slow_call
    add $40, %rsp
    mov MACHINE_SP(%r15), %rbx
    mov %rax, %rcx
    ret

    .bss
    .globl probe_sp
    .balign 8
probe_sp:
    .quad 0
