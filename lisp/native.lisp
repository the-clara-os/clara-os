;;;; native.lisp: code for the machine into code for the processor
;;;;
;;;; What the compiler makes of a function are instructions for a machine
;;;; that the substrate has (lisp/compiler.lisp, kernel/lisp/vm.c), and that
;;;; machine takes them one at a time: it fetches a word, takes it apart,
;;;; finds out what it asks for and does it. This file makes of the same
;;;; instructions the instructions of the processor, which then does what
;;;; they ask without the machine in between. A function that was made that
;;;; way means what it meant: it is the machine's instructions that are
;;;; translated, one after the other, and all but the plainest of them are
;;;; left to the machine itself, which is called for that one instruction
;;;; (STEP). What the processor does alone is what a function spends its
;;;; time on: its variables and constants, its jumps, the calls and the
;;;; returns, and the commonest functions in C when they get the arguments
;;;; that they usually get.
;;;;
;;;; A call keeps on the value stack what the machine's call keeps there,
;;;; in the same order, and nothing that the collector has to find is in a
;;;; register across a call or a jump backwards. So the collector, the
;;;; conditions and the exits needed nothing new, and a function of either
;;;; kind calls one of the other.
;;;;
;;;; The translation is written once, for a processor that this file makes
;;;; up, with a few registers and some two dozen instructions (below). The
;;;; two real ones each have a file that says how those are written for
;;;; them: lisp/arm64.lisp and lisp/x86-64.lisp, of which a machine loads
;;;; its own.
;;;;
;;;; The code names no address. The kernel is somewhere else on every boot,
;;;; and a world that is saved holds its code: what the code needs of the
;;;; kernel it reaches through one register, and where the words lie that
;;;; it reads the kernel says (CLARA.UNSAFE:NATIVE-LAYOUT).

(defpackage "CLARA.NATIVE"
  (:use "COMMON-LISP")
  (:export "*TRANSLATE*" "TRANSLATE" "TRANSLATED-P" "START"))
(in-package "CLARA.NATIVE")

;; When true, whatever the compiler makes is translated as well: the hook
;; below is what the compiler calls.
(defvar *translate* nil)

;; Which processor the code is for, :ARM64 or :X86-64, and where the words
;; lie that it reads: both are the machine's to say, and START asks.
(defvar *machine* nil)
(defvar *layout* nil)

;; The names of the machine's operations by their numbers.
(defvar *names* (apply #'vector (mapcar #'car clara.compiler::*operations*)))

(defun operation (name)
  (get name 'clara.compiler::number))

(defun where (name)
  (or (getf *layout* name)
      (error "the kernel does not say where ~S is, and without that there is no code for the processor" name)))

;;; The processor that is made up.
;;;
;;; Registers: :A :B :C :D pass what the code has in hand, and :A and :B
;;; are what a function in C is given and :A what it gives back; :E and :F
;;; are for the moment. None of the six outlasts a call. Five more are the
;;; code's own, which a function in C leaves alone: :RT, the address that
;;; everything of the kernel's is reached from; :VSP, the top of the value
;;; stack; :LOCALS, the local variables of the call; :CONSTS, the constants
;;; of the function; and :NIL. :CSP is the processor's own stack, which is
;;; only ever looked at.
;;;
;;; Instructions, the register that is changed first:
;;;
;;;   (:label l)
;;;   (:load r base n) (:store r base n)        a word, N bytes from where BASE points
;;;   (:load32 r base n) (:store32 r base n)    half a word, (:load8 r base n) a byte
;;;   (:push r) (:pop r)                        on the value stack
;;;   (:move r s) (:const r n)
;;;   (:word r n l)                             N, and the place of L in the code from bit 8 on
;;;   (:add r n) (:lea r base n)                R + N, BASE + N
;;;   (:add-reg r s) (:sub-reg r s) (:or-reg r s) (:shl r n) (:shr r n)
;;;   (:add-over r s l) (:sub-over r s l)       and on to L when the result does not fit a word
;;;   (:jump l) (:jump-reg r)
;;;   (:jump-if how r x l)                      X a register or a small number; HOW is :EQ :NE, :LT :GE :GT :LE
;;;                                             as numbers with a sign, :LO :HS :HI :LS as numbers without
;;;   (:jump-tag r tag l) (:jump-not-tag r tag l)   by the lowest three bits
;;;   (:jump-odd r l) (:jump-bit-clear r bit l)
;;;   (:call-c n) (:call-lisp n)                what the word N bytes from :RT points at: a function in C, or
;;;                                             the way that this code calls a function
;;;   (:save) (:restore-return)                 where the call came from, and :LOCALS and :CONSTS of the caller

(defvar *code* nil)        ; what is being translated
(defvar *items* nil)       ; the instructions so far, the last first
(defvar *later* nil)       ; (label word done): the instructions that are left to the machine after all, when
                           ; what they got was not what they usually get
(defvar *labels* nil)      ; of the machine's instructions, by their numbers
(defvar *plain* t)         ; the function makes no record and binds no special variable
(defvar *out* nil)         ; where a call ends
(defvar *leave* nil)       ; where it ends when an exit passes through it
(defvar *unwind* nil)      ; where it finds out what an exit is to do here

(defun emit (&rest item)
  (push item *items*))

(defun label ()
  (list nil))

(defun place (label)
  (emit :label label))

;; The top of the value stack is in a register while the code runs, and the
;; kernel has it across everything that the kernel is asked for.
(defun out-of-hand ()
  (emit :store :vsp :rt (where :sp)))

(defun in-hand ()
  (emit :load :vsp :rt (where :sp)))

;; What the kernel said in :A: 0, to go on, or where in the code to go on.
(defun as-told ()
  (let ((on (label)))
    (emit :jump-if :eq :a 0 on)
    (emit :jump-reg :a)
    (place on)))

;; One instruction is left to the machine (lisp_native_step, vm.c). With a
;; target, the instruction makes a record, and the place that the record
;; names is one in this code.
(defun machine-step (word &optional target)
  (out-of-hand)
  (emit :move :a :locals)
  (if target
      (emit :word :b word target)
      (emit :const :b word))
  (emit :call-c (where :step))
  (in-hand)
  (as-told))

(defun one-value ()
  (emit :const :e 1)
  (emit :store32 :e :rt (where :count)))

;; T or NIL into :F, by a jump that the caller writes between the two.
(defmacro truth (&rest jump)
  (let ((yes (gensym)))
    `(let ((,yes (label)))
       (emit :load :f :rt (where :t))
       (emit ,@jump ,yes)
       (emit :move :f :nil)
       (place ,yes))))

;; An instruction that stands for a function in C does the function's work
;; when the name still means that function, and leaves the rest to the
;; machine, which calls whatever the name means now, or the function for
;; arguments that are not the usual ones. LATER is where that is written.
(defun still-original (name later)
  (emit :load :e :rt (where :original))
  (emit :jump-bit-clear :e (- (operation name) (operation :car)) later))

(defun both-fixnums (later)
  (emit :move :e :a)
  (emit :or-reg :e :b)
  (emit :jump-odd :e later))

(defun two-arguments ()
  (emit :load :a :vsp -16)
  (emit :load :b :vsp -8))

(defun one-for-two (register)
  (emit :add :vsp -8)
  (emit :store register :vsp -8)
  (one-value))

(defun compare (name how later)
  (two-arguments)
  (still-original name later)
  (both-fixnums later)
  (truth :jump-if how :a :b)
  (one-for-two :f))

(defun known (name word)
  (let ((later (label)) (done (label)))
    (case name
      ((:car :cdr)
       (emit :load :a :vsp -8)
       (still-original name later)
       (let ((empty (label)))
         (emit :jump-if :eq :a :nil empty)
         (emit :jump-not-tag :a (where :tag-cons) later)
         (emit :load :a :a (where name))
         (emit :store :a :vsp -8)
         (place empty)
         (one-value)))
      ((:not :null)
       (emit :load :a :vsp -8)
       (still-original name later)
       (truth :jump-if :eq :a :nil)
       (emit :store :f :vsp -8)
       (one-value))
      ((:consp :atom)
       (emit :load :a :vsp -8)
       (still-original name later)
       (truth (if (eq name :consp) :jump-tag :jump-not-tag) :a (where :tag-cons))
       (emit :store :f :vsp -8)
       (one-value))
      (:eq
       (two-arguments)
       (still-original name later)
       (truth :jump-if :eq :a :b)
       (one-for-two :f))
      ((:+ :-)
       (two-arguments)
       (still-original name later)
       (both-fixnums later)
       (emit (if (eq name :+) :add-over :sub-over) :a :b later)
       (one-for-two :a))
      ((:1+ :1-)
       (emit :load :a :vsp -8)
       (still-original name later)
       (emit :jump-odd :a later)
       (emit :const :b 2)
       (emit (if (eq name :1+) :add-over :sub-over) :a :b later)
       (emit :store :a :vsp -8)
       (one-value))
      (:< (compare name :lt later))
      (:> (compare name :gt later))
      (:<= (compare name :le later))
      (:>= (compare name :ge later))
      (:= (compare name :eq later))
      ((:aref :svref)
       ;; a vector, and a number that is one of its places: twice the length is the length as a fixnum, and
       ;; a number below zero is a large one without its sign
       (two-arguments)
       (still-original name later)
       (emit :jump-not-tag :a (where :tag-object) later)
       (emit :load8 :e :a (where :header))
       (emit :jump-if :ne :e (where :type-vector) later)
       (emit :jump-odd :b later)
       (emit :load :e :a (where :header))
       (emit :shr :e 16)
       (emit :shl :e 1)
       (emit :jump-if :hs :b :e later)
       (emit :move :e :b)
       (emit :shl :e 2)
       (emit :add-reg :e :a)
       (emit :load :a :e (where :items))
       (one-for-two :a))
      (t (machine-step word)
         (setq later nil)))
    (when later
      (place done)
      (push (list later word done) *later*))))

;; A safe point of this code is a look at one word, as it is of the
;; machine's: here before a jump backwards.
(defun jump-back (to)
  (emit :load32 :e :rt (where :attention))
  (emit :jump-if :eq :e 0 to)
  (out-of-hand)
  (emit :move :a :locals)
  (emit :call-c (where :safe-point))
  (in-hand)
  (as-told)
  (emit :jump to))

;; One instruction of the machine's, which is number AT of its function.
(defun instruction (word at)
  (let* ((name (aref *names* (logand word 255)))
         (a (logand (ash word -8) #xffffff))
         (b (ash word -32)))
    (case name
      (:const (emit :load :e :consts (* 8 a))
              (emit :push :e))
      (:local (emit :load :e :locals (* 8 a))
              (emit :push :e))
      (:set-local (emit :pop :e)
                  (emit :store :e :locals (* 8 a)))
      (:closed (emit :load :e :locals -8)
               (emit :load :e :e (where :env))
               (emit :load :e :e (+ (where :items) (* 8 a)))
               (emit :push :e))
      (:cell-ref (emit :load :e :vsp -8)
                 (emit :load :e :e (where :items))
                 (emit :store :e :vsp -8))
      (:cell-set (emit :load :e :vsp -8)
                 (emit :load :f :vsp -16)
                 (emit :store :f :e (where :items))
                 (emit :add :vsp -16))
      (:special (let ((later (label)) (done (label)))
                  (emit :load :e :consts (* 8 a))
                  (emit :load :e :e (where :value))
                  (emit :jump-if :eq :e (where :unbound) later)
                  (emit :push :e)
                  (place done)
                  (push (list later word done) *later*)))
      (:set-special (emit :pop :e)
                    (emit :load :f :consts (* 8 a))
                    (emit :store :e :f (where :value)))
      (:closure (translate-inside (aref (aref *code* 1) a))
                (machine-step word))
      (:call (emit :const :b a)
             (emit :call-lisp (where :call))
             (emit :load :e :rt (where :unwind))
             (emit :jump-if :ne :e 0 *unwind*)
             (emit :push :a))
      ((:return :return-one)
       (when (eq name :return-one)
         (one-value))
       (unless *plain*
         (out-of-hand)
         (emit :move :a :locals)
         (emit :call-c (where :finish)))
       (emit :load :a :vsp -8)
       (emit :jump *out*))
      (:one (one-value))
      (:drop (unless (= a 0)
               (emit :add :vsp (* -8 a))))
      (:nip (unless (= a 0)
              (emit :load :e :vsp -8)
              (emit :add :vsp (* -8 a))
              (emit :store :e :vsp -8)))
      (:dup (emit :load :e :vsp -8)
            (emit :push :e))
      (:jump (if (<= a at)
                 (jump-back (aref *labels* a))
                 (emit :jump (aref *labels* a))))
      (:jump-if-nil (emit :pop :e)
                    (emit :jump-if :eq :e :nil (aref *labels* a)))
      (:jump-if-true (emit :pop :e)
                     (emit :jump-if :ne :e :nil (aref *labels* a)))
      (:jump-if-supplied (emit :load :e :locals (* 8 b))
                         (emit :jump-if :ne :e (where :unbound) (aref *labels* a)))
      (:supplied (emit :load :e :locals (* 8 a))
                 (truth :jump-if :ne :e (where :unbound))
                 (emit :push :f))
      (:dispatch
       ;; which of the jumps that follow: each of them is an instruction like any other
       (emit :pop :e)
       (dotimes (i a)
         (emit :jump-if :eq :e (* 2 i) (aref *labels* (+ at 1 i))))
       (emit :add :vsp 8)
       (machine-step word))
      ((:block :tagbody :catch :handler :protect)
       (machine-step (- word (ash a 8)) (aref *labels* a)))
      (t (known name word)))))

(defun plain-p (instructions)
  (dotimes (i (length instructions) t)
    (when (member (aref *names* (logand (aref instructions i) 255)) '(:bind :block :tagbody :catch :handler :protect))
      (return nil))))

;; The code for the processor of CODE, which is what the compiler made of a
;; function, as the instructions of the processor that is made up.
;;
;; It begins the same way for every function, and in the same number of
;; bytes on both processors, which the kernel counts on (machine.h). First,
;; the way in from C: the call's local variables are made, :LOCALS points at
;; them and the function is in :A. Then the place where a call ends when an
;; exit passes through it. Then the way in from other code like this: the
;; function is in :A, the number of arguments in :B, and the arguments are
;; on top of the value stack, where they become the first local variables
;; as they lie.
(defun lower (code)
  (let* ((instructions (aref code 0))
         (required (aref code 4)) (variables (aref code 9)) (depth (aref code 10))
         (simple (and (= (aref code 5) 0) (null (aref code 6)) (null (aref code 7))))
         (count (length instructions))
         (common (label)) (fast (label)) (wrong (label)) (full (label))
         (*items* nil) (*later* nil) (*code* code)
         (*labels* (make-array count))
         (*plain* (plain-p instructions))
         (*out* (label)) (*leave* (label)) (*unwind* (label))
         (hidden (if *plain* 0 (where :hidden))))
    (dotimes (i count)
      (setf (aref *labels* i) (label)))
    (emit :save)
    (emit :jump common)
    (place *leave*)
    (emit :move :a :nil)
    (emit :jump *out*)
    (place fast)
    (cond (simple
           (emit :jump-if :ne :b required wrong)
           (emit :save)
           ;; is there room for the call: on the value stack, and on the processor's own
           (emit :lea :e :vsp (* 8 (+ (- variables required) hidden depth)))
           (emit :load :f :rt (where :stack-end))
           (emit :jump-if :hi :e :f full)
           (emit :load :f :rt (where :c-limit))
           (emit :jump-if :lo :csp :f full)
           (emit :lea :locals :vsp (* -8 required))
           (dotimes (i (- variables required))
             (emit :push :nil))
           (unless *plain*
             ;; no record in force yet, and the bindings that there are now, as a fixnum
             (emit :const :e 0)
             (emit :push :e)
             (emit :load32 :e :rt (where :bound))
             (emit :shl :e 1)
             (emit :push :e)))
          (t
           ;; a lambda list with more to it than required parameters: the kernel sorts the arguments out
           (place wrong)
           (emit :save)
           (emit :move :e :b)
           (emit :shl :e 3)
           (emit :move :locals :vsp)
           (emit :sub-reg :locals :e)
           (out-of-hand)
           (emit :call-c (where :arguments))
           (as-told)
           (in-hand)
           (emit :load :a :locals -8)))
    (place common)
    (emit :load :consts :a (where :code))
    (emit :load :consts :consts (+ (where :items) (* 8 (where :constants))))
    (emit :add :consts (where :items))
    (dotimes (at count)
      (place (aref *labels* at))
      (instruction (aref instructions at) at))
    (place *out*)
    (emit :lea :vsp :locals -8)
    (emit :restore-return)
    ;; An exit is under way after a call. A function with records asks the kernel which of them takes
    ;; it, and where to go on; one without is simply over.
    (place *unwind*)
    (cond (*plain* (emit :jump *leave*))
          (t (out-of-hand)
             (emit :move :a :locals)
             (emit :call-c (where :unwinding))
             (in-hand)
             (emit :jump-reg :a)))
    (dolist (later (reverse *later*))
      (place (car later))
      (machine-step (cadr later))
      (emit :jump (caddr later)))
    (when simple
      ;; the wrong number of arguments: the kernel says so
      (place wrong)
      (emit :save)
      (emit :move :e :b)
      (emit :shl :e 3)
      (emit :move :locals :vsp)
      (emit :sub-reg :locals :e)
      (out-of-hand)
      (emit :call-c (where :arguments))
      (emit :jump-reg :a)
      ;; no room: the same, and the stack is cut back to under the arguments
      (place full)
      (out-of-hand)
      (emit :call-c (where :stack-full))
      (emit :lea :locals :vsp (* -8 required))
      (emit :jump *leave*))
    (values (reverse *items*) *leave* fast hidden)))

;;; From the made-up processor to a real one. Each of them has a function
;;; that writes one instruction: it is given the instruction and the place
;;; in the code where it goes, and gives the code for it, in pieces of so
;;; many bytes each. A label is known by then, or stands for 0 while the
;;; code is only measured; what an instruction is in bytes must not depend
;;; on where a label lies.

(defvar *final* nil)       ; the labels are where they will be: an instruction that cannot reach one says so

(defun place-of (label)
  (or (car label) 0))

(defun too-far ()
  (when *final*
    (throw 'too-far nil)))

;; The code for ITEMS as numbers of 32 bits, the lowest byte first, or NIL
;; when an instruction cannot reach as far as the code is long. WRITER gives
;; the code of one instruction as a list of numbers of UNIT bytes each.
(defun assemble (items writer unit)
  (let ((at 0) (*final* nil))
    (dolist (item items)
      (if (eq (car item) :label)
          (setf (car (cadr item)) at)
          (setq at (+ at (* unit (length (funcall writer item at)))))))
    (catch 'too-far
      (let ((bytes nil) (words nil) (*final* t))
        (setq at 0)
        (dolist (item items)
          (unless (eq (car item) :label)
            (let ((pieces (funcall writer item at)))
              (dolist (piece pieces)
                (if (= unit 4)
                    (push piece words)
                    (push piece bytes)))
              (setq at (+ at (* unit (length pieces)))))))
        (when bytes
          ;; four bytes to a word, and what is left over filled with what the processor refuses
          (do ((rest (nreverse bytes) (nthcdr 4 rest))) ((null rest))
            (push (+ (car rest)
                     (ash (or (cadr rest) #xcc) 8)
                     (ash (or (caddr rest) #xcc) 16)
                     (ash (or (cadddr rest) #xcc) 24))
                  words)))
        (let ((code (make-array (length words))) (i (length words)))
          (dolist (word words code)
            (setq i (1- i))
            (setf (aref code i) word)))))))

;; Code for the processor is made of CODE, and of the code of every function
;; that is written inside it, and the kernel is handed each. NIL when the
;; machine is none that this file knows, and for code that is too long for
;; the processor's jumps: the machine of the kernel goes on running that.
(defun install (code)
  (let ((writer (get *machine* 'writer)))
    (cond ((null *layout*) nil)
          ((clara.unsafe:native-code-bytes code) t)
          ((null writer) nil)
          (t (multiple-value-bind (items leave fast hidden) (lower code)
               (let ((words (assemble items writer (get *machine* 'unit))))
                 (cond ((null words) nil)
                       ((not (and (= (place-of leave) (where :leave)) (= (place-of fast) (where :fast))))
                        (error "code for the processor does not begin as the kernel has it: ~D and ~D bytes"
                               (place-of leave) (place-of fast)))
                       (t (clara.unsafe:install-native-code code words hidden)
                          t))))))))

(defun translate-inside (code)
  (install code))

;; What the compiler calls with everything that it makes.
(defun translate-compiled (code)
  (when *translate*
    (install code)))

(setq clara.compiler::*translator* 'translate-compiled)

;; A function that the compiler made, or the one that a symbol names, is run
;; by the processor itself from now on, and so is every function that is
;; made of what is written inside it.
(defun translate (function)
  (let* ((f (if (symbolp function) (symbol-function function) function))
         (code (clara.unsafe:compiled-function-code f)))
    (unless code
      (error "~S is no function that the compiler made, and so there is nothing to translate" function))
    (unless (install code)
      (error "there is no code for the processor to be had for ~S" function))
    (clara.unsafe:native-function f t)
    function))

(defun translated-p (function)
  (clara.unsafe:native-function (if (symbolp function) (symbol-function function) function)))

;; At every boot, image or not: what the machine is, and where its words lie.
(defun start ()
  (setq *machine* (or #+arm64 :arm64 #+x86-64 :x86-64))
  (setq *layout* (clara.unsafe:native-layout))
  t)
