/* x86_64: where the processor enters the kernel when it takes an exception
 * or an interrupt (Intel SDM volume 3, chapter 6), and the probes that the
 * fault self-test provokes exceptions with.
 *
 * This is the 64-bit Microsoft calling convention, like the rest of the
 * kernel: the first two arguments arrive in rcx and rdx, the result leaves
 * in rax, and a caller keeps 32 bytes free above the return address. */

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

    .bss
    .globl probe_sp
    .balign 8
probe_sp:
    .quad 0
