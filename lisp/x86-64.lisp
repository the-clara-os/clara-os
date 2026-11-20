;;;; x86-64.lisp: the instructions of lisp/native.lisp as x86-64 writes them
;;;;
;;;; An instruction of this processor is some bytes: a prefix that says
;;;; which half of the sixteen registers each of up to three is among and
;;;; whether the operation is of 64 bits (REX), the operation itself, a
;;;; byte that names a register and what the other operand is (ModRM), and
;;;; after those a displacement or a number. Every one that is written here
;;;; is in the Intel Software Developer's Manual, volume 2, under the name
;;;; that the comment beside it gives. The registers of the made-up
;;;; processor are rcx, rdx, r8 and r9 for :A to :D, which is where a
;;;; function in C takes its arguments, r10 and r11 for :E and :F, and five
;;;; that a function in C leaves alone: r15 for :RT, rbx for :VSP, rsi for
;;;; :LOCALS, r14 for :CONSTS, rdi for :NIL (kernel/arch/x86_64/entry.S).
;;;; rax is this file's own, and is where a function in C leaves its value.

(in-package "CLARA.NATIVE")

(dolist (pair '((:a 1) (:b 2) (:c 8) (:d 9) (:e 10) (:f 11) (:rt 15) (:vsp 3) (:locals 6) (:consts 14) (:nil 7)
                (:csp 4)))
  (setf (get (car pair) 'x86-64) (cadr pair)))

(defun x86 (register)
  (or (get register 'x86-64) (error "~S is no register of this processor's" register)))

(defun x86-number (n bytes)
  (let ((list nil))
    (dotimes (i bytes (nreverse list))
      (push (logand (ash n (* -8 i)) 255) list))))

;; REX, when it has anything to say: the operation is of 64 bits, or R or
;; RM is one of the upper eight registers.
(defun x86-prefix (wide r rm)
  (let ((rex (+ #x40 (if wide 8 0) (ash (ash r -3) 2) (ash rm -3))))
    (if (= rex #x40) nil (list rex))))

;; REX, the operation, and ModRM for two registers: R is the one that the
;; operation names in its own field, RM the other.
(defun x86-registers (wide operation r rm)
  (append (x86-prefix wide r rm)
          operation
          (list (+ #xc0 (ash (logand r 7) 3) (logand rm 7)))))

;; The same for a register and memory, N bytes from where BASE points. A
;; base whose number ends in 100 is written with a byte more (SIB), and one
;; that ends in 101 always with a displacement.
(defun x86-memory (wide operation r base n)
  (let ((short (and (>= n -128) (< n 128))))
    (append (x86-prefix wide r base)
            operation
            (list (+ (cond ((and (= n 0) (not (= (logand base 7) 5))) 0) (short #x40) (t #x80))
                     (ash (logand r 7) 3) (logand base 7)))
            (if (= (logand base 7) 4) (list #x24) nil)
            (cond ((and (= n 0) (not (= (logand base 7) 5))) nil)
                  (short (x86-number n 1))
                  (t (x86-number n 4))))))

;; An operation with a number: FIELD says which (ADD 0, AND 4, SUB 5, CMP 7).
(defun x86-with-number (field rm n)
  (if (and (>= n -128) (< n 128))
      (append (x86-registers t '(#x83) field rm) (x86-number n 1))
      (append (x86-registers t '(#x81) field rm) (x86-number n 4))))

;; Where a jump of four bytes that ends at END has to go to reach a label.
(defun x86-reach (label end)
  (let ((n (- (place-of label) end)))
    (unless (and (>= n (- (ash 1 31))) (< n (ash 1 31)))
      (too-far))
    (x86-number n 4)))

;; Jcc: END is where the six bytes of it end.
(defun x86-jump-if (how label end)
  (append (list #x0f (+ #x80 (cadr (assoc how '((:over 0) (:lo 2) (:hs 3) (:eq 4) (:ne 5) (:ls 6) (:hi 7) (:lt 12)
                                                 (:ge 13) (:le 14) (:gt 15))))))
          (x86-reach label end)))

;; The code of one instruction that begins AT bytes into the code, as bytes.
(defun write-x86-64 (item at)
  (let ((op (car item)) (x (cadr item)) (y (caddr item)) (z (cadddr item)))
    (case op
      (:load (x86-memory t '(#x8b) (x86 x) (x86 y) z))                    ; MOV r64, m64
      (:store (x86-memory t '(#x89) (x86 x) (x86 y) z))                   ; MOV m64, r64
      (:load32 (x86-memory nil '(#x8b) (x86 x) (x86 y) z))                ; MOV r32, m32: the upper half is cleared
      (:store32 (x86-memory nil '(#x89) (x86 x) (x86 y) z))
      (:load8 (x86-memory nil '(#x0f #xb6) (x86 x) (x86 y) z))            ; MOVZX r32, m8
      (:push (append (x86-memory t '(#x89) (x86 x) (x86 :vsp) 0)
                     (x86-with-number 0 (x86 :vsp) 8)))
      (:pop (append (x86-with-number 5 (x86 :vsp) 8)
                    (x86-memory t '(#x8b) (x86 x) (x86 :vsp) 0)))
      (:move (x86-registers t '(#x89) (x86 y) (x86 x)))                   ; MOV r64, r64
      (:const (cond ((and (>= y 0) (< y (ash 1 32)))                      ; MOV r32, imm32
                     (append (x86-prefix nil 0 (x86 x)) (list (+ #xb8 (logand (x86 x) 7))) (x86-number y 4)))
                    ((and (< y 0) (>= y (- (ash 1 31))))                  ; MOV r64, imm32 with its sign
                     (append (x86-registers t '(#xc7) 0 (x86 x)) (x86-number y 4)))
                    (t (append (list (+ #x48 (ash (x86 x) -3)) (+ #xb8 (logand (x86 x) 7))) ; MOV r64, imm64
                               (x86-number y 8)))))
      (:word (append (list (+ #x48 (ash (x86 x) -3)) (+ #xb8 (logand (x86 x) 7)))
                     (x86-number (+ y (ash (place-of z) 8)) 8)))
      (:add (x86-with-number 0 (x86 x) y))
      (:lea (x86-memory t '(#x8d) (x86 x) (x86 y) z))                     ; LEA
      (:add-reg (x86-registers t '(#x01) (x86 y) (x86 x)))                ; ADD r64, r64
      (:sub-reg (x86-registers t '(#x29) (x86 y) (x86 x)))                ; SUB
      (:or-reg (x86-registers t '(#x09) (x86 y) (x86 x)))                 ; OR
      (:shl (if (= y 1)
                (x86-registers t '(#xd1) 4 (x86 x))                       ; SHL r64, 1
                (append (x86-registers t '(#xc1) 4 (x86 x)) (list y))))   ; SHL r64, imm8
      (:shr (if (= y 1)
                (x86-registers t '(#xd1) 5 (x86 x))
                (append (x86-registers t '(#xc1) 5 (x86 x)) (list y))))   ; SHR
      (:add-over (append (x86-registers t '(#x01) (x86 y) (x86 x))
                         (x86-jump-if :over z (+ at 9))))                 ; JO, after the three bytes of the ADD
      (:sub-over (append (x86-registers t '(#x29) (x86 y) (x86 x))
                         (x86-jump-if :over z (+ at 9))))
      (:jump (cons #xe9 (x86-reach x (+ at 5))))                          ; JMP rel32
      (:jump-reg (x86-registers nil '(#xff) 4 (x86 x)))                   ; JMP r64
      (:jump-if (let ((compare (if (symbolp z)
                                   (x86-registers t '(#x39) (x86 z) (x86 y)) ; CMP r64, r64
                                   (x86-with-number 7 (x86 y) z))))
                  (append compare (x86-jump-if x (nth 4 item) (+ at (length compare) 6)))))
      ((:jump-tag :jump-not-tag)
       (let ((tag (append (x86-registers nil '(#x89) (x86 x) 0)           ; MOV eax, r32
                          (list #x83 #xe0 7)                              ; AND eax, 7
                          (list #x83 #xf8 y))))                           ; CMP eax, tag
         (append tag (x86-jump-if (if (eq op :jump-tag) :eq :ne) z (+ at (length tag) 6)))))
      (:jump-odd (let ((test (append (x86-registers nil '(#xf7) 0 (x86 x)) (x86-number 1 4)))) ; TEST r32, 1
                   (append test (x86-jump-if :ne y (+ at (length test) 6)))))
      (:jump-bit-clear (append (x86-registers t '(#x0f #xba) 4 (x86 x)) (list y) ; BT r64, imm8: the bit, in the carry
                               (x86-jump-if :hs z (+ at 11))))
      (:call-c (append (x86-memory nil '(#xff) 2 (x86 :rt) x)            ; CALL m64
                       (x86-registers t '(#x89) 0 (x86 :a))))             ; MOV rcx, rax: what the function gave
      (:call-lisp (x86-memory nil '(#xff) 2 (x86 :rt) x))
      (:save (list #x56                                                   ; PUSH rsi
                   #x41 #x56                                              ; PUSH r14
                   #x48 #x83 #xec #x28))                                  ; SUB rsp, 40: 32 bytes for a function in C
                                                                          ; to use, and 8 that put the stack right
      (:restore-return (list #x48 #x83 #xc4 #x28                          ; ADD rsp, 40
                             #x41 #x5e                                    ; POP r14
                             #x5e                                         ; POP rsi
                             #xc3))                                       ; RET
      (:call-local (cons #xe8 (x86-reach x (+ at 5))))                    ; CALL rel32: where it came from is on
                                                                          ; the processor's stack
      (:enter-local (list #x48 #x83 #xec #x28))                           ; SUB rsp, 40: for a function in C, and
                                                                          ; the stack right again, as in (:save)
      (:leave-local (list #x48 #x83 #xc4 #x28))                           ; ADD rsp, 40
      (:return-local (list #xc3))                                         ; RET
      (:forget-local (list #x48 #x83 #xc4 #x08))                          ; ADD rsp, 8: past where it came from
      (t (error "~S is no instruction that this file can write" item)))))

(setf (get :x86-64 'writer) 'write-x86-64
      (get :x86-64 'unit) 1)
