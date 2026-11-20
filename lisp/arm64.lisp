;;;; arm64.lisp: the instructions of lisp/native.lisp as AArch64 writes them
;;;;
;;;; An instruction of this processor is a word of 32 bits, and every one
;;;; that is written here is in the Arm Architecture Reference Manual,
;;;; chapter C6, under the name that the comment beside it gives. The
;;;; registers of the made-up processor are x0 to x3 for :A to :D, which is
;;;; where a function in C takes its arguments and leaves its value, x9 and
;;;; x10 for :E and :F, and five that a function in C leaves alone: x19 for
;;;; :RT, x20 for :VSP, x21 for :LOCALS, x22 for :CONSTS, x23 for :NIL
;;;; (kernel/arch/aarch64/entry.S). x16 is this file's own, for a number
;;;; that an instruction has no room for.

(in-package "CLARA.NATIVE")

(dolist (pair '((:a 0) (:b 1) (:c 2) (:d 3) (:e 9) (:f 10) (:rt 19) (:vsp 20) (:locals 21) (:consts 22) (:nil 23)))
  (setf (get (car pair) 'arm64) (cadr pair)))

(defun a64 (register)
  (or (get register 'arm64) (error "~S is no register of this processor's" register)))

;; MOVZ, MOVN and MOVK: a number into a register, sixteen bits at a time.
;; The first of them clears the other 48, or sets them, which is what a
;; number below zero wants; the parts that are right after that are left
;; out. ALL writes every one of the four, so that the code is as long
;; whatever the number is.
(defun a64-number (rd n all)
  (let ((words nil) (rest (if (and (< n 0) (not all)) #xffff 0)))
    (dotimes (i 4)
      (let ((part (logand (ash n (* -16 i)) #xffff)))
        (when (or all (not (= part rest)))
          (push (cond (words (+ #xf2800000 (ash i 21) (ash part 5) rd))
                      ((= rest 0) (+ #xd2800000 (ash i 21) (ash part 5) rd))
                      (t (+ #x92800000 (ash i 21) (ash (logxor part #xffff) 5) rd)))
                words))))
    (or (nreverse words) (list (+ (if (= rest 0) #xd2800000 #x92800000) rd)))))

;; LDR and STR and their kin, of SIZE bytes: a displacement that is a small
;; multiple of the size goes into the instruction (unsigned offset), a
;; small one of either sign too (LDUR, STUR), and any other into x16.
(defun a64-memory (load size rt base n)
  (let ((scaled (cond ((= size 8) (if load #xf9400000 #xf9000000))
                      ((= size 4) (if load #xb9400000 #xb9000000))
                      (t #x39400000)))
        (unscaled (cond ((= size 8) (if load #xf8400000 #xf8000000))
                        ((= size 4) (if load #xb8400000 #xb8000000))
                        (t #x38400000)))
        (indexed (cond ((= size 8) (if load #xf8606800 #xf8206800))
                       ((= size 4) (if load #xb8606800 #xb8206800))
                       (t #x38606800))))
    (cond ((and (>= n 0) (= (rem n size) 0) (< (truncate n size) 4096))
           (list (+ scaled (ash (truncate n size) 10) (ash base 5) rt)))
          ((and (>= n -256) (< n 256))
           (list (+ unscaled (ash (logand n #x1ff) 12) (ash base 5) rt)))
          (t (append (a64-number 16 n nil)
                     (list (+ indexed (ash 16 16) (ash base 5) rt)))))))

;; ADD and SUB with a number: twelve bits, twelve more above them, or x16.
(defun a64-add (rd rn n)
  (let* ((minus (< n 0)) (size (if minus (- n) n)) (add (if minus #xd1000000 #x91000000))
         (low (logand size #xfff)) (high (ash size -12)))
    (cond ((< size 4096)
           (list (+ add (ash low 10) (ash rn 5) rd)))
          ((< high 4096)
           (if (= low 0)
               (list (+ add (ash 1 22) (ash high 10) (ash rn 5) rd))
               (list (+ add (ash low 10) (ash rn 5) rd)
                     (+ add (ash 1 22) (ash high 10) (ash rd 5) rd))))
          (t (append (a64-number 16 size nil)
                     (list (+ (if minus #xcb000000 #x8b000000) (ash 16 16) (ash rn 5) rd)))))))

;; B, and BL, which leaves in x30 where it came from: as far as 128 MiB
;; either way.
(defun a64-jump (label at &optional link)
  (let ((words (truncate (- (place-of label) at) 4)))
    (unless (and (>= words (- (ash 1 25))) (< words (ash 1 25)))
      (too-far))
    (+ (if link #x94000000 #x14000000) (logand words #x3ffffff))))

;; B.cond: as far as 1 MiB either way.
(defun a64-jump-if (how label at)
  (let ((words (truncate (- (place-of label) at) 4))
        (code (cadr (assoc how '((:eq 0) (:ne 1) (:hs 2) (:lo 3) (:vs 6) (:hi 8) (:ls 9) (:ge 10) (:lt 11) (:gt 12)
                                 (:le 13))))))
    (unless (and (>= words (- (ash 1 18))) (< words (ash 1 18)))
      (too-far))
    (+ #x54000000 (ash (logand words #x7ffff) 5) code)))

;; CMP: with a register, with a small number, or with a larger one in x16.
(defun a64-compare (register with)
  (cond ((eq register :csp)
         (list (+ #xeb2063ff (ash (a64 with) 16))))                       ; SUBS, extended register: sp is no
                                                                          ; register to the plain one
        ((symbolp with)
         (list (+ #xeb00001f (ash (a64 with) 16) (ash (a64 register) 5))))
        ((< with 4096)
         (list (+ #xf100001f (ash with 10) (ash (a64 register) 5))))
        (t (append (a64-number 16 with nil)
                   (list (+ #xeb00001f (ash 16 16) (ash (a64 register) 5)))))))

;; The code of one instruction that begins AT bytes into the code, as words.
(defun write-arm64 (item at)
  (let ((op (car item)) (x (cadr item)) (y (caddr item)) (z (cadddr item)))
    (case op
      (:load (a64-memory t 8 (a64 x) (a64 y) z))
      (:store (a64-memory nil 8 (a64 x) (a64 y) z))
      (:load32 (a64-memory t 4 (a64 x) (a64 y) z))
      (:store32 (a64-memory nil 4 (a64 x) (a64 y) z))
      (:load8 (a64-memory t 1 (a64 x) (a64 y) z))
      (:push (list (+ #xf8008400 (ash (a64 :vsp) 5) (a64 x))))            ; STR x, [vsp], #8
      (:pop (list (+ #xf85f8c00 (ash (a64 :vsp) 5) (a64 x))))             ; LDR x, [vsp, #-8]!
      (:move (list (+ #xaa0003e0 (ash (a64 y) 16) (a64 x))))              ; ORR x, xzr, y
      (:const (a64-number (a64 x) y nil))
      (:word (a64-number (a64 x) (+ y (ash (place-of z) 8)) t))
      (:add (a64-add (a64 x) (a64 x) y))
      (:lea (a64-add (a64 x) (a64 y) z))
      (:add-reg (list (+ #x8b000000 (ash (a64 y) 16) (ash (a64 x) 5) (a64 x))))
      (:sub-reg (list (+ #xcb000000 (ash (a64 y) 16) (ash (a64 x) 5) (a64 x))))
      (:or-reg (list (+ #xaa000000 (ash (a64 y) 16) (ash (a64 x) 5) (a64 x))))
      (:shl (list (+ #xd3400000 (ash (rem (- 64 y) 64) 16) (ash (- 63 y) 10) (ash (a64 x) 5) (a64 x)))) ; UBFM
      (:shr (list (+ #xd3400000 (ash y 16) (ash 63 10) (ash (a64 x) 5) (a64 x))))
      (:add-over (list (+ #xab000000 (ash (a64 y) 16) (ash (a64 x) 5) (a64 x)) ; ADDS, and on when it overflowed
                       (a64-jump-if :vs z (+ at 4))))
      (:sub-over (list (+ #xeb000000 (ash (a64 y) 16) (ash (a64 x) 5) (a64 x)) ; SUBS
                       (a64-jump-if :vs z (+ at 4))))
      (:jump (list (a64-jump x at)))
      (:jump-reg (list (+ #xd61f0000 (ash (a64 x) 5))))                   ; BR
      (:jump-if (let ((compare (a64-compare y z)))
                  (append compare (list (a64-jump-if x (nth 4 item) (+ at (* 4 (length compare))))))))
      ((:jump-tag :jump-not-tag)
       (list (+ #x92400800 (ash (a64 x) 5) 16)                            ; AND x16, x, #7
             (+ #xf100001f (ash y 10) (ash 16 5))                         ; CMP x16, #tag
             (a64-jump-if (if (eq op :jump-tag) :eq :ne) z (+ at 8))))
      (:jump-odd (list (+ #xf240001f (ash (a64 x) 5))                     ; TST x, #1
                       (a64-jump-if :ne y (+ at 4))))
      (:jump-bit-clear (list (+ #xf240001f (ash (rem (- 64 y) 64) 16) (ash (a64 x) 5)) ; TST x, #(1 << bit)
                             (a64-jump-if :eq z (+ at 4))))
      ((:call-c :call-lisp)
       (append (a64-memory t 8 16 (a64 :rt) x)
               (list #xd63f0200)))                                        ; BLR x16
      (:save (list #xa9be7bfd                                             ; STP x29, x30, [sp, #-32]!
                   #xa9015bf5))                                           ; STP x21, x22, [sp, #16]
      (:restore-return (list #xa9415bf5                                   ; LDP x21, x22, [sp, #16]
                             #xa8c27bfd                                   ; LDP x29, x30, [sp], #32
                             #xd65f03c0))                                 ; RET
      (:call-local (list (a64-jump x at t)))                              ; BL
      (:enter-local (list #xa9bf7bfd))                                    ; STP x29, x30, [sp, #-16]!: a function in
                                                                          ; C is about to use x30 for itself
      (:leave-local (list #xa8c17bfd))                                    ; LDP x29, x30, [sp], #16
      (:return-local (list #xd65f03c0))                                   ; RET
      (:forget-local nil)                                                 ; x30 is simply not gone back to
      (t (error "~S is no instruction that this file can write" item)))))

(setf (get :arm64 'writer) 'write-arm64
      (get :arm64 'unit) 4)
