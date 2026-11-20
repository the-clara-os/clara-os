;;;; host/vm.lisp: the machine that compiled code runs on, under SBCL
;;;;
;;;; On ClaraOS what lisp/compiler.lisp makes is run by the machine in
;;;; kernel/lisp/vm.c. This file is that machine a second time, written the
;;;; slow way, so that the compiler can be tested where a test can hold what
;;;; a compiled function does against what SBCL makes of the same form. It
;;;; has the same instructions, taken from the compiler's own list, and what
;;;; it keeps on its stack is as deep, word for word, as what the kernel's
;;;; keeps: a function that needs more stack than its code says is caught
;;;; here.
;;;;
;;;; A compiled function is a function of SBCL's that runs its code, so
;;;; compiled functions and SBCL's own call one another freely. What vm.c
;;;; does with records on its stack is done here with what SBCL has for it,
;;;; CATCH, HANDLER-BIND and UNWIND-PROTECT, each around the instructions
;;;; that the record would be in force for: an exit then passes through
;;;; functions of either kind, as it does on ClaraOS. A special variable is
;;;; bound the way the kernel binds one: its old value is put away and the
;;;; new one is set.
;;;;
;;;; It is loaded after lisp/compiler.lisp.

(in-package "CLARA.HOST")

(defvar *names* (map 'vector #'car clara.compiler::*operations*)) ; of the operations, by their numbers
(defvar *codes* (make-hash-table :test 'eq :weakness :key :synchronized t)) ; a compiled function's code
(defvar *values* :one)   ; every value of the form before, in a list, or :ONE when the one on the stack is all
(defvar +unsupplied+ (list 'unsupplied))  ; what a parameter holds that got no argument

;; What EXECUTE says when it stops: the function returned; the records that
;; were in force are left, and so many more outside them; the form of an
;; UNWIND-PROTECT is done; its cleanup is done. And what is thrown to a
;; tagbody and to a HANDLER-CASE.
(defvar +return+ (list :return))
(defvar +unlink+ (list :unlink))
(defvar +cleanup+ (list :cleanup))
(defvar +cleanup-end+ (list :cleanup-end))
(defvar +gone+ (list :gone))
(defvar +handled+ (list :handled))

;; What FAIL signals, and the errors that the kernel's machine has types for.
(define-condition compiled-error (error)
  ((text :initarg :text :reader compiled-error-text))
  (:report (lambda (condition stream) (write-string (compiled-error-text condition) stream))))
(define-condition compiled-program-error (compiled-error program-error) ())
(define-condition compiled-control-error (compiled-error control-error) ())

(defun fail (type control &rest arguments)
  (error type :text (apply #'format nil control arguments)))

(defstruct frame
  code
  closed          ; the values that the function closes over
  locals
  (stack (make-array 16 :adjustable t :fill-pointer 0))
  (bindings nil)  ; (symbol . the value it had), the newest first
  (records nil)   ; where on the stack the records begin that are in force, the innermost first
  (extra 0)       ; words on the stack that the compiler could not count: the values of forms, beyond one each
  (extras nil))   ; and how many of them each counter of VALUES-PUSH stands for

(defun bind (frame symbol value)
  (push (cons symbol (if (boundp symbol) (symbol-value symbol) +unsupplied+)) (frame-bindings frame))
  (setf (symbol-value symbol) value))

(defun unbind-to (frame count)
  (loop while (> (length (frame-bindings frame)) count)
        do (destructuring-bind (symbol . value) (pop (frame-bindings frame))
             (if (eq value +unsupplied+)
                 (makunbound symbol)
                 (setf (symbol-value symbol) value)))))

(defun settled (value)
  (if (eq *values* :one) (list value) *values*))

(defun make-function (code closed)
  (let ((function (lambda (&rest arguments) (call-code code closed arguments))))
    (setf (gethash function *codes*) code)
    function))

;; The instructions of FRAME's code from PC on, until the function returns
;; or the stretch that this call is for comes to its end.
(defun execute (frame pc)
  (let* ((code (frame-code frame)) (instructions (aref code 0)) (constants (aref code 1))
         (locals (frame-locals frame)) (stack (frame-stack frame)) (closed (frame-closed frame)))
    (labels ((push-value (value)
               (when (>= (- (fill-pointer stack) (frame-extra frame)) (aref code 10))
                 (error "~S needs more stack than the ~D words that its code says"
                        (clara.compiler::code-title code) (aref code 10)))
               (vector-push-extend value stack))
             (popped (value)
               ;; A record is six words that stay where they are for as long as it is in force.
               (when (and (frame-records frame) (< (fill-pointer stack) (+ (car (frame-records frame)) 6)))
                 (error "~S took a record off its stack that was still in force"
                        (clara.compiler::code-title code)))
               value)
             (pop-value ()
               (popped (vector-pop stack)))
             (pop-values (count)
               (let ((values nil))
                 (dotimes (i count (popped values))
                   (push (vector-pop stack) values))))
             (bound ()
               (length (frame-bindings frame)))
             (call (function arguments)
               (setq *values* (multiple-value-list (apply function arguments)))
               (push-value (car *values*)))
             ;; A stretch of instructions that a record was in force for has come to its end.
             (over (results)
               (cond ((eq (car results) +return+)
                      (return-from execute (values-list results)))
                     ((plusp (cadr results))
                      (return-from execute (values +unlink+ (1- (cadr results)) (caddr results))))
                     (t (setq pc (caddr results)))))
             ;; Control has come back to a record: the stack and the bindings are what they were.
             (land (base bindings)
               (unbind-to frame bindings)
               (setf (fill-pointer stack) base))
             (record ()
               (push (fill-pointer stack) (frame-records frame))
               (dotimes (i 6)
                 (push-value nil)))
             ;; The stretch that a record was made for, with what is thrown to TAG coming back as
             ;; values; after it the record is in force no more.
             (stretch (tag outside)
               (let ((results (multiple-value-list (catch tag (execute frame pc)))))
                 (setf (frame-records frame) outside)
                 results)))
      (loop
        (let* ((word (aref instructions pc))
               (a (logand (ash word -8) #xffffff))
               (b (ash word -32)))
          (incf pc)
          (case (aref *names* (logand word 255))
            (:const (push-value (aref constants a)))
            (:local (push-value (aref locals a)))
            (:set-local (setf (aref locals a) (pop-value)))
            (:closed (push-value (aref closed a)))
            (:cell (push-value (vector (pop-value))))
            (:cell-ref (push-value (aref (pop-value) 0)))
            (:cell-set (let ((cell (pop-value)))
                         (setf (aref cell 0) (pop-value))))
            (:special (push-value (symbol-value (aref constants a))))
            (:set-special (setf (symbol-value (aref constants a)) (pop-value)))
            (:bind (bind frame (aref constants a) (pop-value)))
            (:unbind (unbind-to frame (- (bound) a)))
            (:function (let ((symbol (aref constants a)))
                         (when (or (special-operator-p symbol) (macro-function symbol))
                           (fail 'compiled-error "~S is a macro or a special operator, not a function" symbol))
                         (push-value (fdefinition symbol))))
            (:closure (let ((values (coerce (pop-values b) 'vector)))
                        (push-value (make-function (aref constants a) values))))
            (:call (let ((arguments (pop-values a)))
                     (call (pop-value) arguments)))
            (:return (return-from execute (values +return+ (settled (pop-value)))))
            (:return-one (return-from execute (values +return+ (list (pop-value)))))
            (:one (setq *values* :one))
            (:drop (pop-values a))
            (:nip (let ((value (pop-value)))
                    (pop-values a)
                    (push-value value)))
            (:dup (push-value (aref stack (1- (fill-pointer stack)))))
            (:jump (setq pc a))
            (:jump-if-nil (when (null (pop-value)) (setq pc a)))
            (:jump-if-true (when (pop-value) (setq pc a)))
            (:jump-if-supplied (unless (eq (aref locals b) +unsupplied+) (setq pc a)))
            (:supplied (push-value (not (eq (aref locals a) +unsupplied+))))
            (:values-push (let ((values (settled (pop-value))))
                            (dolist (value values)
                              (vector-push-extend value stack))
                            (incf (frame-extra frame) (1- (length values)))
                            (incf (getf (frame-extras frame) a 0) (1- (length values)))
                            (incf (aref locals a) (length values))))
            (:values-call (let ((arguments (pop-values (aref locals a))))
                            (decf (frame-extra frame) (getf (frame-extras frame) a 0))
                            (setf (getf (frame-extras frame) a) 0)
                            (call (pop-value) arguments)))
            (:values-spread (let ((values (settled (pop-value))))
                              (dotimes (i a)
                                (push-value (nth i values)))))
            (:values-save (let ((values (settled (pop-value))))
                            (dolist (value values)
                              (vector-push-extend value stack))
                            (vector-push-extend (length values) stack)))
            (:values-restore (setq *values* (pop-values (vector-pop stack)))
                             (push-value (car *values*)))
            (:block (let ((tag (list t)) (base (fill-pointer stack)) (bindings (bound))
                          (outside (frame-records frame)))
                      (setf (aref locals b) tag)
                      (record)
                      (let ((results (stretch tag outside)))
                        (setf (car tag) nil)
                        (cond ((or (eq (car results) +return+) (eq (car results) +unlink+))
                               (over results))
                              (t (land base bindings)
                                 (setq *values* results)
                                 (push-value (car results))
                                 (setq pc a))))))
            (:tagbody (let ((tag (list t)) (base (fill-pointer stack)) (bindings (bound))
                            (outside (frame-records frame)))
                        (setf (aref locals b) tag)
                        (record)
                        (loop
                          (let ((results (stretch tag outside)))
                            (unless (eq (car results) +gone+)
                              (setf (car tag) nil)
                              (over results)
                              (return))
                            (push base (frame-records frame)) ; a GO from afar: the tagbody is not left
                            (land (+ base 6) bindings)
                            (push-value (cadr results))
                            (setq pc a)))))
            (:catch (let ((tag (pop-value)) (base (fill-pointer stack)) (bindings (bound))
                          (outside (frame-records frame)))
                      (record)
                      (let ((results (stretch tag outside)))
                        (cond ((or (eq (car results) +return+) (eq (car results) +unlink+))
                               (over results))
                              (t (land base bindings)
                                 (setq *values* results)
                                 (push-value (car results))
                                 (setq pc a))))))
            (:handler (let ((clauses (aref constants b)) (base (fill-pointer stack)) (bindings (bound))
                            (landing (list nil)) (outside (frame-records frame)))
                        (dolist (clause clauses)
                          (unless (or (eq (car clause) t)
                                      (and (symbolp (car clause)) (find-class (car clause) nil)
                                           (subtypep (car clause) 'condition)))
                            (fail 'compiled-error
                                  "HANDLER-CASE has a clause for ~S, which is not the name of a type of condition"
                                  (car clause))))
                        (record)
                        (let ((results (multiple-value-list
                                        (catch landing
                                          (handler-bind ((condition
                                                           (lambda (condition)
                                                             (let ((clause (find-if (lambda (clause)
                                                                                      (typep condition (car clause)))
                                                                                    clauses)))
                                                               (when clause
                                                                 (throw landing (values +handled+ condition (cdr clause))))))))
                                            (execute frame pc))))))
                          (setf (frame-records frame) outside)
                          (cond ((eq (car results) +handled+)
                                 (land base bindings)
                                 (push-value (cadr results))
                                 (push-value (caddr results))
                                 (setq pc a))
                                (t (over results))))))
            (:protect (let ((base (fill-pointer stack)) (bindings (bound)) (results nil)
                            (outside (frame-records frame)))
                        (record)
                        (unwind-protect
                             (setq results (multiple-value-list (execute frame pc)))
                          (setf (frame-records frame) outside)
                          (land base bindings)
                          (let ((values *values*))
                            (setq pc (nth-value 1 (execute frame a)))
                            (setq *values* values)))
                        (setq *values* (cadr results))
                        (push-value (car *values*))))
            (:unlink (return-from execute (values +unlink+ (1- a) pc)))
            (:return-to (let ((values (settled (pop-value))) (tag (pop-value)))
                          (unless (car tag)
                            (fail 'compiled-control-error "RETURN-FROM ~S, a block that has been left already"
                                  (aref constants a)))
                          (throw tag (values-list values))))
            (:go-to (let ((tag (pop-value)))
                      (unless (car tag)
                        (fail 'compiled-control-error "GO to ~S, in a TAGBODY that has been left already"
                              (aref constants b)))
                      (throw tag (values +gone+ a))))
            (:throw (let ((values (settled (pop-value))))
                      (throw (pop-value) (values-list values))))
            (:cleanup (return-from execute (values +cleanup+ (settled (pop-value)))))
            (:cleanup-end (return-from execute (values +cleanup-end+ pc)))
            (:dispatch (let ((which (pop-value)))
                         (unless (< -1 which a)
                           (error "compiled code was sent to the ~Dth of ~D places" which a))
                         (incf pc which)))
            (:fset (let ((function (pop-value)))
                     (setf (fdefinition (aref constants a)) function)
                     (push-value (aref constants a))))
            (:defmacro (let ((expander (pop-value)) (name (aref constants a)))
                         (setf (macro-function name)
                               (lambda (form environment)
                                 (declare (ignore environment))
                                 (funcall expander form)))
                         (push-value name)))
            (:defvar (let ((symbol (aref constants a)))
                       (proclaim (list 'special symbol))
                       (push-value (not (boundp symbol)))))
            (:defconstant (let ((value (pop-value)))
                            (eval (list 'defconstant (aref constants a) (list 'quote value)))
                            (push-value (aref constants a))))
            (:fail (fail (aref #(compiled-error compiled-program-error compiled-control-error) a)
                         "~A" (aref constants b)))
            ;; An instruction that stands for a function in C: here the function is SBCL's, and is
            ;; called. What the kernel's machine does instead, and how it knows that the name still
            ;; means that function, is tested there (kernel/lisp/lisp.c).
            (t (let* ((name (aref *names* (logand word 255)))
                      (function (find-symbol (symbol-name name) "COMMON-LISP")))
                 (unless (and function (eq (get function 'clara.compiler::instruction) name))
                   (error "~S is no instruction of the machine's" name))
                 (call (fdefinition function) (pop-values (- 1 (get name 'clara.compiler::effect))))))))))))

;; Code, called: the arguments go into its first local variables as
;; kernel/lisp/vm.c puts them there.
(defun call-code (code closed arguments)
  (let* ((required (aref code 4)) (positional (+ required (aref code 5)))
         (keys (aref code 7)) (allow (aref code 8))
         (locals (make-array (aref code 9) :initial-element nil))
         (more (nthcdr positional arguments)) (next positional)
         (title (clara.compiler::code-title code))
         (frame (make-frame :code code :closed closed :locals locals)))
    (when (< (length arguments) required)
      (fail 'compiled-program-error "~S got too few arguments" title))
    (when (and more (not (aref code 6)) (not keys))
      (fail 'compiled-program-error "~S got too many arguments" title))
    (dotimes (i positional)
      (setf (aref locals i) (if (< i (length arguments)) (nth i arguments) +unsupplied+)))
    (when (aref code 6)
      (setf (aref locals next) (copy-list more))
      (incf next))
    (when keys
      (when (oddp (length more))
        (fail 'compiled-program-error "~S got an odd number of keyword arguments" title))
      (loop for (key value) on more by #'cddr
            do (when (and (eq key :allow-other-keys) value)
                 (setq allow t)))
      (dotimes (i (length keys))
        (let ((found (loop for tail on more by #'cddr
                           when (eq (car tail) (aref keys i)) return tail)))
          (setf (aref locals (+ next i)) (if found (cadr found) +unsupplied+))))
      (unless allow
        (loop for (key) on more by #'cddr
              do (unless (or (find key keys) (eq key :allow-other-keys))
                   (fail 'compiled-program-error "~S does not take the keyword argument ~S" title key)))))
    (unwind-protect
         (multiple-value-bind (kind values) (execute frame 0)
           (unless (eq kind +return+)
             (error "~S came to an end without returning" title))
           (values-list values))
      (unbind-to frame 0))))

(in-package "CLARA.UNSAFE")

(defun make-compiled-function (code)
  (unless (and (vectorp code) (= (length code) 13) (eql (aref code 11) 0))
    (error "~S is not code that the machine can run" code))
  (clara.host::make-function code nil))

(defun compiled-function-code (function)
  (values (gethash function clara.host::*codes*)))

;;; Code for the processor (lisp/native.lisp). SBCL runs none of it: what
;;; the translation makes is kept beside the code that it was made of, for
;;; a test to look at, and the machine above goes on running the function.
;;; The numbers are the ones that the kernel gives for its own structs
;;; (kernel/lisp/native.c), so that what is looked at here is what a kernel
;;; would be handed.

(defun native-layout ()
  (list :sp 0 :unwind 8 :attention 40 :bound 44 :count 48 :original 216 :stack-end 224 :c-limit 232 :t 240
        :call 248 :step 256 :unwinding 264 :safe-point 272 :arguments 280 :finish 288 :stack-full 296
        :cons 304 :cell 312 :closure 320
        :leave 12 :fast 20 :car 7 :cdr 15 :value 21 :header -5 :items 3 :code 11 :env 19 :constants 1
        :tag-cons 1 :tag-object 5 :type-vector 4 :unbound 15 :hidden 2))

(defun install-native-code (code words hidden)
  (unless (and (vectorp code) (= (length code) 13) (null (aref code 12)))
    (error "~S is not code that can be given code for the processor" code))
  (unless (and (vectorp words) (> (length words) 5) (every (lambda (word) (typep word '(unsigned-byte 32))) words))
    (error "~S is not the words of code for the processor" words))
  (unless (member hidden '(0 2))
    (error "~S is not the number of words that a call hides" hidden))
  (setf (aref code 12) (list :native words hidden))
  (* 4 (length words)))

(defun native-code-bytes (code)
  (and (aref code 12) (* 4 (length (cadr (aref code 12))))))

(defun native-function (function &optional refresh)
  (declare (ignore refresh))
  (let ((code (gethash function clara.host::*codes*)))
    (and code (aref code 12) t)))

;; What the compiler made of every function that has no code for the
;; processor: here, of every function that was made and that SBCL has not
;; let go of since.
(defun untranslated-code ()
  (let ((codes nil))
    (maphash (lambda (function code)
               (declare (ignore function))
               (unless (aref code 12)
                 (push code codes)))
             clara.host::*codes*)
    (coerce codes 'vector)))

;; The kernel's functions each have a word for where the processor enters
;; them, and this is what puts those right. Here a function is asked for
;; its code every time, so there is nothing to put right.
(defun native-functions ()
  0)
