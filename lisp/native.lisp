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
;;;; Between two such places the code does not do everything that the
;;;; machine would. A value that the machine pushes for the next instruction
;;;; to take off again stays where it is, in a variable, among the
;;;; constants or in a register, until that instruction asks for it; and a
;;;; comparison whose value is only wanted by the jump after it is written
;;;; with the jump, as the processor compares and jumps.
;;;;
;;;; This is how every function is run: the compiler hands what it makes to
;;;; this file (*TRANSLATE*), and the world that was compiled before this
;;;; file was loaded, the compiler and this file among it, is translated in
;;;; one go when a machine starts from the files (TRANSLATE-ALL).
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
  (:export "*TRANSLATE*" "TRANSLATE" "TRANSLATE-ALL" "TRANSLATED-P" "START"))
(in-package "CLARA.NATIVE")

;; While true, whatever the compiler makes is translated as well, which is
;; the rule: the hook below is what the compiler calls. Bound to NIL around
;; a form, it leaves what is compiled there to the machine.
(defvar *translate* t)

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
;;; Registers: :A :B :C :D pass what the code has in hand, and they are
;;; what a function in C is given and :A what it gives back; :E and :F are
;;; for the moment. None of the six outlasts a call. Five more are the
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
;;;   (:call-local l) (:return-local)           into a piece of the same code and back out of it, which
;;;   (:enter-local) (:leave-local)             keeps where it came from across a function in C,
;;;   (:forget-local)                           or never goes back there

(defvar *code* nil)        ; what is being translated
(defvar *items* nil)       ; the instructions so far, the last first
(defvar *later* nil)       ; what is written behind the function, where the code only comes when an instruction
                           ; got something else than it usually gets: lists like *ITEMS*, the last first
(defvar *labels* nil)      ; of the machine's instructions, by their numbers,
(defvar *targets* nil)     ; and which of them something jumps to: only those have their label put somewhere
(defvar *plain* t)         ; the function makes no record and binds no special variable
(defvar *out* nil)         ; where a call ends
(defvar *leave* nil)       ; where it ends when an exit passes through it
(defvar *unwind* nil)      ; where it finds out what an exit is to do here
(defvar *steps* nil)       ; the three ways into the piece that leaves an instruction to the machine,
(defvar *stepped* nil)     ; and whether any was used
(defvar *taken* 1)         ; how many of the machine's instructions the last piece of code was for

;; What the machine would have pushed by now and this code has not, the
;; last first. An instruction of the machine's takes what it works on from
;; the stack and puts what it makes there, and the next one takes it off
;; again: here a value stays where it is until somebody wants it. (:LOCAL
;; n), (:CONST n) and (:CLOSED n) are a local variable, a constant and a
;; closed-over value that nobody has fetched yet; (:REG) is a value that is
;; in :A and nowhere else, and it is always the oldest of them, since
;; whatever makes one has pushed the rest first (ARGUMENTS, FLUSH). Nothing
;; is pending where two ways through the code meet, at a call, or anywhere
;; that the collector could look.
(defvar *pending* nil)

(defun emit (&rest item)
  (push item *items*))

(defun label ()
  (list nil))

(defun place (label)
  (emit :label label))

;; What BODY writes goes behind the function.
(defmacro behind (&body body)
  `(let ((*items* nil))
     ,@body
     (push *items* *later*)))

(defun constant-of (item)
  (aref (aref *code* 1) (cadr item)))

;; The word that the heap has for an integer, which is twice the integer:
;; for one that is small enough to be written into the code as it stands.
(defun word-of (value)
  (and (integerp value)
       (< value 1152921504606846976)
       (> value -1152921504606846976)
       (* 2 value)))

;; A pending value comes into a register.
(defun fetch (item register)
  (case (car item)
    (:reg (unless (eq register :a)
            (emit :move register :a)))
    (:local (emit :load register :locals (* 8 (cadr item))))
    (:closed (emit :load register :locals -8)
             (emit :load register register (where :env))
             (emit :load register register (+ (where :items) (* 8 (cadr item)))))
    (t (let ((value (constant-of item)))
         (cond ((null value) (emit :move register :nil))
               ((word-of value) (emit :const register (word-of value)))
               (t (emit :load register :consts (* 8 (cadr item)))))))))

;; The register that has a pending value, which is SCRATCH unless the value
;; is in one already.
(defun held (item scratch)
  (cond ((eq (car item) :reg) :a)
        ((and (eq (car item) :const) (null (constant-of item))) :nil)
        (t (fetch item scratch)
           scratch)))

;; Everything that is pending is pushed, the oldest first: the stack is
;; then what the machine's would be.
(defun flush ()
  (dolist (item (reverse *pending*))
    (emit :push (held item :e)))
  (setq *pending* nil))

;; The value that an instruction has made is in :A.
(defun result ()
  (push (list :reg) *pending*))

;; The arguments of an instruction, one or two of them, come into :A, or
;; into :A and :B: from what is pending, and from the stack when nothing
;; is. Whatever else is pending is pushed first, so that the stack under
;; the arguments is the machine's.
(defun arguments (count)
  (let* ((last (pop *pending*))
         (first (if (= count 2) (pop *pending*) nil)))
    (flush)
    (cond ((= count 1)
           (if last
               (fetch last :a)
               (emit :pop :a)))
          ((null last)
           (emit :pop :b)
           (emit :pop :a))
          ((null first)
           (fetch last :b)
           (emit :pop :a))
          (t (fetch first :a)
             (fetch last :b)))))

;; A pending value that is a small integer written into the function: the
;; word that the heap has for it, when that is under LIMIT.
(defun small-constant (item limit)
  (and item
       (eq (car item) :const)
       (let ((word (word-of (constant-of item))))
         (and word (>= word 0) (< word limit) word))))

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

;; The piece of a function's code that leaves an instruction to the machine
;; (lisp_native_step, vm.c): one for the whole function, behind it, with
;; three ways in, for an instruction whose two arguments are in :A and :B,
;; whose one argument is in :A, or whose arguments are on the stack, where
;; the machine looks for them. The instruction's word is in :C. It comes
;; back when the machine says to go on, with what the instruction made on
;; the stack, and goes where the machine sends it otherwise.
(defun step-with (count)
  (setq *stepped* t)
  (nth count *steps*))

(defun step-piece ()
  (let ((elsewhere (label)))
    (place (nth 2 *steps*))
    (emit :push :a)
    (emit :move :a :b)
    (place (nth 1 *steps*))
    (emit :push :a)
    (place (nth 0 *steps*))
    (emit :enter-local)
    (out-of-hand)
    (emit :move :a :locals)
    (emit :move :b :c)
    (emit :call-c (where :step))
    (in-hand)
    (emit :leave-local)
    (emit :jump-if :ne :a 0 elsewhere)
    (emit :return-local)
    (place elsewhere)
    (emit :forget-local)
    (emit :jump-reg :a)))

;; One instruction is left to the machine, with the stack as the machine
;; would have it. With a target, the instruction makes a record, and the
;; place that the record names is one in this code.
(defun machine-step (word &optional target)
  (if target
      (emit :word :c word target)
      (emit :const :c word))
  (emit :call-local (step-with 0)))

(defun one-value ()
  (emit :const :e 1)
  (emit :store32 :e :rt (where :count)))

(defun name-at (at)
  (aref *names* (logand (aref (aref *code* 0) at) 255)))

;; An instruction that stands for a function in C leaves word that it made
;; one value, as the function does. Nobody reads that when the instruction
;; after it takes the value off the stack for itself, as most do, whichever
;; way the code came to it, and then it is not written.
(defun value-made (at)
  (let ((next (1+ at)))
    (unless (and (< next (length (aref *code* 0)))
                 (or (>= (operation (name-at next)) (operation :car))
                     (member (name-at next) '(:jump-if-nil :set-local :call :return-one :cell))))
      (one-value))))

;; Where the code goes when the value of the instruction at AT is NIL, if
;; that is all that becomes of the value: the instruction after it is a jump
;; for NIL, and nothing else comes to that jump. The two are then written
;; as one, a comparison and a jump of the processor's, and no T or NIL is
;; made.
(defun jump-after (at)
  (let ((next (1+ at)))
    (and (< next (length (aref *code* 0)))
         (not (aref *targets* next))
         (eq (name-at next) :jump-if-nil)
         (aref *labels* (logand (ash (aref (aref *code* 0) next) -8) #xffffff)))))

;; T or NIL into :A, by a jump that the caller writes between the two.
(defmacro truth (&rest jump)
  (let ((yes (gensym)))
    `(let ((,yes (label)))
       (emit :load :f :rt (where :t))
       (emit ,@jump ,yes)
       (emit :move :f :nil)
       (place ,yes)
       (emit :move :a :f))))

(defun opposite (how)
  (cadr (assoc how '((:eq :ne) (:ne :eq) (:lt :ge) (:ge :lt) (:gt :le) (:le :gt)))))

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

;; Behind the function, for such an instruction: its COUNT arguments, which
;; are in :A and :B and nowhere else, go on the stack, the machine does the
;; instruction, and the code goes on at DONE with the value in :A, where the
;; instruction itself would have left it. NUMBER is the second argument
;; when it never came into :B. With TARGET, the value was only wanted for a
;; jump, which is made here.
(defun to-machine (later done word count &optional number target)
  (behind
    (place later)
    (when number
      (emit :const :b number))
    (emit :const :c word)
    (emit :call-local (step-with count))
    (emit :pop :a)
    (when target
      (emit :jump-if :eq :a :nil target))
    (emit :jump done)))

;; A comparison of two integers. The second is often a small one that is
;; written into the function, and is then compared with as a number and
;; never fetched.
(defun compare (name how word at)
  (let ((later (label)) (done (label)) (target (jump-after at))
        (number (small-constant (car *pending*) 4096)))
    (cond (number (pop *pending*)
                  (arguments 1))
          (t (arguments 2)))
    (still-original name later)
    (if number
        (emit :jump-odd :a later)
        (both-fixnums later))
    (cond (target (emit :jump-if (opposite how) :a (or number :b) target)
                  (setq *taken* 2))
          (t (truth :jump-if how :a (or number :b))
             (value-made at)))
    (place done)
    (unless target
      (result))
    (to-machine later done word 2 number target)))

;; A question that the processor answers by itself, of one argument or of
;; two: HOW says how the jump for "no" is written.
(defun question (name word at count no yes)
  (let ((later (label)) (done (label)) (target (jump-after at)))
    (arguments count)
    (still-original name later)
    (cond (target (funcall no target)
                  (setq *taken* 2))
          (t (emit :load :f :rt (where :t))
             (let ((so (label)))
               (funcall yes so)
               (emit :move :f :nil)
               (place so))
             (emit :move :a :f)
             (value-made at)))
    (place done)
    (unless target
      (result))
    (to-machine later done word count nil target)))

(defun known (name word at)
  (let ((later (label)) (done (label)))
    (case name
      ((:car :cdr)
       (arguments 1)
       (still-original name later)
       (let ((empty (label)))
         (emit :jump-if :eq :a :nil empty)
         (emit :jump-not-tag :a (where :tag-cons) later)
         (emit :load :a :a (where name))
         (place empty))
       (value-made at)
       (place done)
       (result)
       (to-machine later done word 1))
      ((:not :null)
       (question name word at 1
                 (lambda (to) (emit :jump-if :ne :a :nil to))
                 (lambda (to) (emit :jump-if :eq :a :nil to))))
      (:consp
       (question name word at 1
                 (lambda (to) (emit :jump-not-tag :a (where :tag-cons) to))
                 (lambda (to) (emit :jump-tag :a (where :tag-cons) to))))
      (:atom
       (question name word at 1
                 (lambda (to) (emit :jump-tag :a (where :tag-cons) to))
                 (lambda (to) (emit :jump-not-tag :a (where :tag-cons) to))))
      (:eq
       (question name word at 2
                 (lambda (to) (emit :jump-if :ne :a :b to))
                 (lambda (to) (emit :jump-if :eq :a :b to))))
      ((:+ :- :1+ :1-)
       ;; a sum that does not fit has changed :A by the time that is known, and is taken back
       (let* ((two (or (eq name :+) (eq name :-)))
              (add (or (eq name :+) (eq name :1+)))
              (fixed (and two (small-constant (car *pending*) (ash 1 30))))
              (over (label)))
         (arguments (if two 2 1))
         (still-original name later)
         (if (or fixed (not two))
             (emit :jump-odd :a later)
             (both-fixnums later))
         (unless two
           (emit :const :b 2))
         (emit (if add :add-over :sub-over) :a :b over)
         (value-made at)
         (place done)
         (result)
         (behind
           (place over)
           (emit (if add :sub-reg :add-reg) :a :b))
         (to-machine later done word (if two 2 1))))
      (:< (compare name :lt word at))
      (:> (compare name :gt word at))
      (:<= (compare name :le word at))
      (:>= (compare name :ge word at))
      (:= (compare name :eq word at))
      ((:aref :svref)
       ;; a vector, and a number that is one of its places: twice the length is the length as a fixnum, and
       ;; a number below zero is a large one without its sign
       (arguments 2)
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
       (value-made at)
       (place done)
       (result)
       (to-machine later done word 2))
      (:cons
       ;; the kernel makes the cons, and nothing of the stack is its business
       (arguments 2)
       (still-original name later)
       (emit :call-c (where :cons))
       (value-made at)
       (place done)
       (result)
       (to-machine later done word 2))
      (t (flush)
         (machine-step word)))))

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
      ((:const :local :closed)
       (push (list name a) *pending*))
      (:set-local
       (let ((value (pop *pending*)))
         ;; a value that is still to be fetched from this variable is the one that it has now
         (when (member (list :local a) *pending* :test #'equal)
           (flush))
         (emit :store (if value (held value :e) (progn (emit :pop :e) :e)) :locals (* 8 a))))
      (:cell
       (arguments 1)
       (emit :call-c (where :cell))
       (result))
      (:cell-ref
       (arguments 1)
       (emit :load :a :a (where :items))
       (result))
      (:cell-set
       (arguments 2)
       (emit :store :a :b (where :items)))
      (:special
       (let ((later (label)) (done (label)))
         (flush)
         (emit :load :a :consts (* 8 a))
         (emit :load :a :a (where :value))
         (emit :jump-if :eq :a (where :unbound) later)
         (place done)
         (result)
         (to-machine later done word 0)))
      (:set-special
       (arguments 1)
       (emit :load :e :consts (* 8 a))
       (emit :store :a :e (where :value)))
      (:closure
       ;; the kernel makes the function of the values that are on the stack, and is told where those are
       (translate-inside (aref (aref *code* 1) a))
       (flush)
       (emit :load :a :consts (* 8 a))
       (emit :const :b b)
       (emit :move :c :vsp)
       (emit :call-c (where :closure))
       (unless (= b 0)
         (emit :add :vsp (* -8 b)))
       (result))
      (:call
       (flush)
       (emit :const :b a)
       (emit :call-lisp (where :call))
       (emit :load :e :rt (where :unwind))
       (emit :jump-if :ne :e 0 *unwind*)
       (result))
      ((:return :return-one)
       (cond (*plain*
              ;; the value, and nothing else that is pending is anybody's any more
              (let ((value (car *pending*)))
                (setq *pending* nil)
                (if value
                    (fetch value :a)
                    (emit :load :a :vsp -8))))
             (t (flush)
                (out-of-hand)
                (emit :move :a :locals)
                (emit :call-c (where :finish))
                (emit :load :a :vsp -8)))
       (when (eq name :return-one)
         (one-value))
       ;; where a call ends is right behind the last instruction
       (unless (= (1+ at) (length (aref *code* 0)))
         (emit :jump *out*)))
      (:one (one-value))
      (:drop
       (let ((left a))
         (dotimes (i a)
           (when *pending*
             (pop *pending*)
             (setq left (1- left))))
         (unless (= left 0)
           (emit :add :vsp (* -8 left)))))
      (:nip
       (unless (= a 0)
         (let ((top (pop *pending*)) (left a))
           (cond (top
                  (dotimes (i a)
                    (when *pending*
                      (pop *pending*)
                      (setq left (1- left))))
                  (unless (= left 0)
                    (emit :add :vsp (* -8 left)))
                  (push top *pending*))
                 (t (emit :pop :a)
                    (emit :add :vsp (* -8 a))
                    (result))))))
      (:dup
       (let ((top (car *pending*)))
         (cond ((and top (not (eq (car top) :reg)))
                (push top *pending*))
               (t (flush)
                  (emit :load :a :vsp -8)
                  (result)))))
      (:jump
       (flush)
       (if (<= a at)
           (jump-back (aref *labels* a))
           (emit :jump (aref *labels* a))))
      ((:jump-if-nil :jump-if-true)
       (let ((value (pop *pending*)))
         (flush)
         (emit :jump-if (if (eq name :jump-if-nil) :eq :ne)
               (if value (held value :e) (progn (emit :pop :e) :e))
               :nil (aref *labels* a))))
      (:jump-if-supplied
       (flush)
       (emit :load :e :locals (* 8 b))
       (emit :jump-if :ne :e (where :unbound) (aref *labels* a)))
      (:supplied
       (flush)
       (emit :load :e :locals (* 8 a))
       (truth :jump-if :ne :e (where :unbound))
       (result))
      (:dispatch
       ;; which of the jumps that follow: each of them is an instruction like any other
       (flush)
       (emit :pop :e)
       (dotimes (i a)
         (emit :jump-if :eq :e (* 2 i) (aref *labels* (+ at 1 i))))
       (emit :add :vsp 8)
       (machine-step word))
      ((:block :tagbody :catch :handler :protect)
       (flush)
       (machine-step (- word (ash a 8)) (aref *labels* a)))
      (t (known name word at)))))

(defun plain-p (instructions)
  (dotimes (i (length instructions) t)
    (when (member (aref *names* (logand (aref instructions i) 255)) '(:bind :block :tagbody :catch :handler :protect))
      (return nil))))

;; Which of the instructions something jumps to: the ones that a jump or a
;; record names, and the jumps after a DISPATCH, which picks one of them.
(defun targets (instructions)
  (let* ((count (length instructions)) (targets (make-array count :initial-element nil)))
    (dotimes (i count targets)
      (let* ((word (aref instructions i))
             (name (aref *names* (logand word 255)))
             (a (logand (ash word -8) #xffffff)))
        (cond ((member name '(:jump :jump-if-nil :jump-if-true :jump-if-supplied :block :tagbody :catch :handler
                              :protect))
               (when (< a count)
                 (setf (aref targets a) t)))
              ((eq name :dispatch)
               (dotimes (k a)
                 (when (< (+ i 1 k) count)
                   (setf (aref targets (+ i 1 k)) t)))))))))

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
         (*items* nil) (*later* nil) (*code* code) (*pending* nil) (*taken* 1)
         (*labels* (make-array count))
         (*targets* (targets instructions))
         (*plain* (plain-p instructions))
         (*steps* (list (label) (label) (label))) (*stepped* nil)
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
    (do ((at 0 (+ at *taken*)))
        ((>= at count))
      (when (aref *targets* at)
        ;; two ways through the code meet here, and both have everything on the stack
        (flush)
        (place (aref *labels* at)))
      (setq *taken* 1)
      (instruction (aref instructions at) at))
    (setq *pending* nil)
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
    (dolist (items (reverse *later*))
      (setq *items* (append items *items*)))
    (when *stepped*
      (step-piece))
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

;; Whether an instruction says where something else in the code is: what
;; such a one is in bytes is known only when the labels are.
(defun reaches (item)
  (case (car item)
    ((:jump :jump-if :jump-tag :jump-not-tag :jump-odd :jump-bit-clear :add-over :sub-over :word :call-local) t)
    (t nil)))

;; The code for ITEMS as numbers of 32 bits, the lowest byte first, or NIL
;; when an instruction cannot reach as far as the code is long. WRITER gives
;; the code of one instruction as a list of numbers of UNIT bytes each. The
;; instructions are gone through twice, first for where the labels come to
;; lie; what was written then is kept for the second time, apart from the
;; instructions that name a label, which are written again.
(defun assemble (items writer unit)
  (let ((at 0) (*final* nil) (written nil))
    (dolist (item items)
      (if (eq (car item) :label)
          (setf (car (cadr item)) at)
          (let ((pieces (funcall writer item at)))
            (push (if (reaches item) nil pieces) written)
            (setq at (+ at (* unit (length pieces)))))))
    (setq written (nreverse written))
    (catch 'too-far
      (let ((bytes nil) (words nil) (*final* t))
        (setq at 0)
        (dolist (item items)
          (unless (eq (car item) :label)
            (let ((pieces (or (pop written) (funcall writer item at))))
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
                       ;; another thread may have been quicker with the same function
                       ((clara.unsafe:native-code-bytes code) t)
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
;; made of what is written inside it, or that was made of the same code
;; before: for a function that was compiled while *TRANSLATE* was NIL.
(defun translate (function)
  (let* ((f (if (symbolp function) (symbol-function function) function))
         (code (clara.unsafe:compiled-function-code f)))
    (unless code
      (error "~S is no function that the compiler made, and so there is nothing to translate" function))
    (unless (install code)
      (error "there is no code for the processor to be had for ~S" function))
    (clara.unsafe:native-functions)
    function))

;; The same for every function that there is and that the machine still
;; runs: how many of them the processor runs from now on. This is how a
;; world comes to run on the processor that was compiled before this file
;; was loaded, the compiler and this file among it. What this file and the
;; processor's define comes first, so that the processor runs the
;; translator while it does the rest. A function that is in the middle of a
;; call finishes that call on the machine.
(defun translate-all ()
  (let ((codes (clara.unsafe:untranslated-code)) (own (find-package "CLARA.NATIVE")) (first 0))
    (dotimes (i (length codes))
      (let ((name (aref (aref codes i) 2)))
        (when (and name (eq (symbol-package name) own))
          (install (aref codes i)))))
    (setq first (clara.unsafe:native-functions))
    (dotimes (i (length codes))
      (install (aref codes i)))
    (+ first (clara.unsafe:native-functions))))

(defun translated-p (function)
  (clara.unsafe:native-function (if (symbolp function) (symbol-function function) function)))

;; At every boot, image or not: what the machine is, and where its words lie.
(defun start ()
  (setq *machine* (or #+arm64 :arm64 #+x86-64 :x86-64))
  (setq *layout* (clara.unsafe:native-layout))
  t)
