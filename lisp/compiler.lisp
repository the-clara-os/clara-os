;;;; compiler.lisp: Lisp functions into code for the machine
;;;;
;;;; The evaluator walks the lists of a function every time the function is
;;;; called: it looks every variable up by its name, makes a frame in the
;;;; heap for every binding, and decides at every form anew what kind of
;;;; form it is. The compiler does all of that once. What it makes of a
;;;; LAMBDA form is code for the machine in kernel/lisp/vm.c: instructions
;;;; that push and pop on a stack, with every variable in a slot that is
;;;; known by its number. A compiled function means what the same function
;;;; means to the evaluator, down to what its errors say, and the two kinds
;;;; call each other freely.
;;;;
;;;; It works in two passes. The first turns a form into a tree in which
;;;; nothing is left to look up (CONVERT): macros are expanded, every name
;;;; is the variable, the block or the tag that it stands for, and what a
;;;; function inside a function uses of the variables around it is written
;;;; down. Only when all of a function has been through that is it known
;;;; which variables a closure shares, and which blocks are left from
;;;; somewhere that a jump cannot reach. The second pass writes the
;;;; instructions (GENERATE).
;;;;
;;;; A form that is not what it should be is no reason to stop: the
;;;; evaluator would say so when it came to the form, and so does the code,
;;;; with an instruction that fails in the same words.
;;;;
;;;; COMPILE and DISASSEMBLE are Common Lisp's and are in lisp/boot.lisp,
;;;; which finds this file's functions through CLARA:PROVIDE-COMPILER. Under
;;;; SBCL the same file is tested on a machine that lisp/host/ makes up.

(defpackage "CLARA.COMPILER"
  (:use "COMMON-LISP")
  (:export "EVALUATE"))
(in-package "CLARA.COMPILER")

;;; The machine's operations, in the order of their numbers, which is the
;;; order of the table in kernel/lisp/vm.c. With each: what it does to the
;;; depth of the stack, a number, or :A, :B or :SPREAD when that depends on
;;; an operand; and what its two operands are, for the listing.

(defvar *operations*
  '((:const 1 :constant) (:local 1 :number) (:set-local -1 :number) (:closed 1 :number) (:cell 0) (:cell-ref 0)
    (:cell-set -2) (:special 1 :constant) (:set-special -1 :constant) (:bind -1 :constant) (:unbind 0 :number)
    (:function 1 :constant) (:closure :b :code :number) (:call :a :number) (:return -1) (:return-one -1) (:one 0)
    (:drop :a :number) (:nip :a :number) (:dup 1) (:jump 0 :number) (:jump-if-nil -1 :number)
    (:jump-if-true -1 :number) (:jump-if-supplied 0 :number :number) (:supplied 1 :number)
    (:values-push 0 :number) (:values-call 0 :number) (:values-spread :spread :number) (:values-save 20)
    (:values-restore 0) (:block 6 :number :number) (:tagbody 6 :number :number) (:catch 5 :number)
    (:handler 6 :number :constant) (:protect 6 :number) (:unlink 0 :number) (:return-to -2 :constant)
    (:go-to -1 :number :constant) (:throw -2) (:cleanup 24) (:cleanup-end 0) (:dispatch -1 :number)
    (:fset 0 :constant) (:defmacro 1 :constant) (:defvar 1 :constant) (:defconstant 0 :constant)
    (:fail 0 :number :constant)))

(let ((number 0))
  (dolist (row *operations*)
    (setf (get (car row) 'number) number
          (get (car row) 'effect) (cadr row))
    (setq number (1+ number))))

;;; What the first pass keeps.

;; A function that is being compiled.
(defstruct fn
  name            ; a symbol, or NIL for a LAMBDA
  lambda-list     ; as it was written
  parent          ; the function that it is written inside, or NIL
  (slots 0)       ; how many local variables it has so far
  (closed nil)    ; the variables of the functions around it that it uses, or that a function inside it does,
                  ; in the order in which a closure holds them
  (required 0)    ; what it takes: how many parameters have to get an argument,
  (optional 0)    ; how many more can,
  (rest nil)      ; whether the rest is wanted as a list,
  (keyed nil)     ; whether it takes keyword arguments,
  (keys nil)      ; which,
  (allow nil)     ; and whether any other too
  (steps nil)     ; what is to be done about each parameter before the body
  (body nil))     ; the body, converted

;; A variable that is not special: it has a slot in a call of its function.
;; When a function inside that one uses it, that function gets it as it is
;; made: its value, or, when the variable is ever set, a cell that holds
;; the value and that the two share.
(defstruct var name fn slot (captured nil) (assigned nil))

;; A block, and a tagbody. One that is left from where a jump cannot reach,
;; from a function inside its own or across an UNWIND-PROTECT, is DYNAMIC:
;; it is known by a tag, which is the value of a variable of its own. The
;; rest is for the second pass: where it ends, and what the stack, the
;; records in force and the bindings are there.
(defstruct blk name fn barrier (dynamic nil) (tag nil) (label nil) (depth 0) (records 0) (bound 0) (mode nil))
(defstruct tb fn barrier (dynamic nil) (tag nil) (count 0) (places nil) (depth 0) (records 0) (bound 0))

;; What is in sight where a form stands: the variables and the functions by
;; their names, a function being a variable too or (:MACRO . symbol) for one
;; of MACROLET; the blocks; the tags, each as (tag tagbody number); the
;; function that the form is part of; and the barrier, which is another
;; object wherever a jump out would leave something undone.
(defstruct env (variables nil) (functions nil) (blocks nil) (tags nil) (fn nil) (barrier nil))

;; A form that is not what it should be. KIND is the type of the error that
;; the evaluator has for it: :ERROR, :PROGRAM or :CONTROL.
(define-condition problem (error)
  ((kind :initarg :kind :reader problem-kind)
   (text :initarg :text :reader problem-text)))

(defun problem (kind control &rest arguments)
  (error 'problem :kind kind :text (apply #'format nil control arguments)))

;; The symbols that the reader makes of ` , and ,@ are the system's own.
(defvar *quasiquote* (find-symbol "QUASIQUOTE" (find-package "COMMON-LISP")))
(defvar *unquote* (find-symbol "UNQUOTE" (find-package "COMMON-LISP")))
(defvar *splice* (find-symbol "UNQUOTE-SPLICING" (find-package "COMMON-LISP")))

;; The forms that are neither calls nor macro calls: (name least most
;; function), the number of parts as the evaluator's table has it.
(defvar *special-forms* nil)

;;; The first pass

(defun new-slot (fn)
  (let ((slot (fn-slots fn)))
    (setf (fn-slots fn) (1+ slot))
    slot))

;; A variable is used where ENV says. Every function from there out to the
;; variable's own has to be given it when it is made.
(defun use (variable env)
  (do ((fn (env-fn env) (fn-parent fn))) ((eq fn (var-fn variable)))
    (setf (var-captured variable) t)
    (unless (member variable (fn-closed fn))
      (setf (fn-closed fn) (append (fn-closed fn) (list variable))))))

;; A name gets a binding. What stands for it from here on: the name itself
;; when it is a special variable, and otherwise a new variable in a slot,
;; which is in sight in ENV from now on. ENV is the caller's to change.
(defun bind-name (name env &optional slot)
  (unless (and (symbolp name) (not (eq (clara:variable-kind name) :constant)))
    (problem :error "~S cannot be the name of a variable" name))
  (if (clara:variable-kind name)
      name
      (let ((variable (make-var :name name :fn (env-fn env) :slot (or slot (new-slot (env-fn env))))))
        (setf (env-variables env) (cons (cons name variable) (env-variables env)))
        variable)))

(defun convert-variable (name env)
  (cond ((or (null name) (eq name t) (keywordp name)) (list :const name))
        ((clara:variable-kind name) (list :special name))
        (t (let ((found (assoc name (env-variables env))))
             (cond (found (use (cdr found) env) (list :ref (cdr found)))
                   (t (list :special name)))))))

(defun count-parts (list)
  (let ((count 0))
    (do ((rest list (cdr rest))) ((atom rest) count)
      (setq count (1+ count)))))

;; What a macro makes of a form. A macro that fails does it when the form
;; is evaluated, as it would for the evaluator.
(defun expand (form)
  (handler-case (macroexpand-1 form)
    (error (condition) (values (list '%raise condition) t))))

(defun convert-all (forms env)
  (mapcar (lambda (form) (convert form env)) forms))

(defun convert-progn (forms env)
  (cond ((atom forms) (list :const nil))
        ((atom (cdr forms)) (convert (car forms) env))
        (t (list :progn (convert-all forms env)))))

(defun convert-cons (form env)
  (let ((operator (car form)))
    (cond ((symbolp operator)
           (let ((local (assoc operator (env-functions env))))
             (cond ((and local (consp (cdr local)))
                    (convert (expand (cons (cddr local) (cdr form))) env))
                   (local
                    (use (cdr local) env)
                    (list :call (list :ref (cdr local)) (convert-all (cdr form) env)))
                   ((and (eq operator 'funcall) (consp (cdr form)))
                    ;; the function is called from here, and not by FUNCALL for us
                    (list :call (convert (cadr form) env) (convert-all (cddr form) env)))
                   (t (let ((special (assoc operator *special-forms*)))
                        (cond (special
                               (let ((parts (count-parts (cdr form))))
                                 (when (or (< parts (cadr special))
                                           (and (caddr special) (> parts (caddr special))))
                                   (problem :program "~S has the wrong number of parts for ~S" form operator)))
                               (funcall (cadddr special) form env))
                              (t (multiple-value-bind (expansion expanded) (expand form)
                                   (if expanded
                                       (convert expansion env)
                                       (list :call (list :const operator) (convert-all (cdr form) env)))))))))))
          ((and (consp operator) (eq (car operator) 'lambda))
           (list :call (list :closure (convert-function nil (cadr operator) (cddr operator) env))
                 (convert-all (cdr form) env)))
          (t (problem :error "~S is not the name of a function, so ~S is not a form" operator form)))))

;; A form, converted: a list that begins with what kind of thing it is.
(defun convert (form env)
  (cond ((symbolp form) (convert-variable form env))
        ((atom form) (list :const form))
        (t (handler-case (convert-cons form env)
             (problem (condition) (list :fail (problem-kind condition) (problem-text condition)))
             (error (condition) (list :fail :error (princ-to-string condition)))))))

;; The forms of a body, after its declarations and a string that documents
;; it. One declaration changes what the forms mean, SPECIAL, and is refused
;; here as the evaluator refuses it.
(defun body-forms (body)
  (loop
    (let ((form (car body)))
      (cond ((and (stringp form) (consp (cdr body)))
             (setq body (cdr body)))
            ((and (consp form) (eq (car form) 'declare))
             (dolist (declaration (cdr form))
               (when (and (consp declaration) (eq (car declaration) 'special))
                 (problem :error "(DECLARE (SPECIAL ...)), which the evaluator does not know yet: DEFVAR makes a variable special")))
             (setq body (cdr body)))
            (t (return body))))))

;;; Lambda lists

(defun keyword-of (name)
  (unless (symbolp name)
    (problem :error "~S cannot be the name of a variable" name))
  (intern (symbol-name name) (find-package "KEYWORD")))

;; The parameters of a function, sorted: (required optional rest keyed keys
;; allow aux), an optional one as (name default supplied-p), a keyword one
;; as (keyword name default supplied-p), an auxiliary one as (name value).
(defun parse-lambda-list (list)
  (let ((stage 0) (required nil) (optional nil) (rest nil) (keyed nil) (keys nil) (allow nil) (aux nil))
    (flet ((on (next)
             (when (< next stage)
               (problem :error "the lambda list ~S has its parts in an order that the compiler does not take" list))
             (setq stage next)))
      (do ((rest-of list (cdr rest-of)))
          ((atom rest-of)
           (when rest-of
             (problem :error "the lambda list ~S ends in ~S" list rest-of)))
        (let ((parameter (car rest-of)))
          (cond ((eq parameter '&optional) (on 1))
                ((or (eq parameter '&rest) (eq parameter '&body)) (on 2))
                ((eq parameter '&key) (on 3) (setq keyed t))
                ((eq parameter '&allow-other-keys) (setq allow t))
                ((eq parameter '&aux) (on 4))
                ((eq parameter '&environment)
                 (problem :error "&ENVIRONMENT in a lambda list, which the evaluator does not know yet"))
                ((= stage 0) (push parameter required))
                ((= stage 1)
                 (push (if (consp parameter)
                           (list (car parameter) (cadr parameter) (caddr parameter))
                           (list parameter nil nil))
                       optional))
                ((= stage 2)
                 (when rest
                   (problem :error "the lambda list ~S has two names for the rest of the arguments" list))
                 (setq rest parameter))
                ((= stage 3)
                 (let* ((spec (if (consp parameter) (car parameter) parameter))
                        (name (if (consp spec) (cadr spec) spec)))
                   (push (list (if (consp spec) (car spec) (keyword-of spec)) name
                               (if (consp parameter) (cadr parameter))
                               (if (consp parameter) (caddr parameter)))
                         keys)))
                (t (push (if (consp parameter) (list (car parameter) (cadr parameter)) (list parameter nil))
                         aux))))))
    (list (reverse required) (reverse optional) rest keyed (reverse keys) allow (reverse aux))))

;; A function: its parameters, then its body, with a block of its name
;; around it when it has one. The arguments arrive in its first slots, in
;; the order of the lambda list (kernel/lisp/vm.c), and STEPS says what is
;; left to do about each: bind it if it is special, put it in a cell if it
;; is shared and set, work its default out if it got no argument.
(defun convert-function (name lambda-list body env)
  (let* ((parsed (parse-lambda-list lambda-list))
         (required (car parsed)) (optional (cadr parsed)) (rest (caddr parsed))
         (keys (nth 4 parsed)) (aux (nth 6 parsed))
         (fn (make-fn :name name :lambda-list lambda-list :parent (env-fn env)
                      :required (length required) :optional (length optional) :rest (if rest t nil)
                      :keyed (cadddr parsed) :keys (mapcar #'car keys) :allow (nth 5 parsed)))
         (inner (copy-env env)) (slot 0) (steps nil))
    (setf (env-fn inner) fn
          (env-barrier inner) (list nil)
          (fn-slots fn) (+ (length required) (length optional) (if rest 1 0) (length keys)))
    (dolist (parameter required)
      (push (list :required (bind-name parameter inner slot) slot) steps)
      (setq slot (1+ slot)))
    (dolist (parameter optional)
      (let* ((default (convert (cadr parameter) inner))
             (variable (bind-name (car parameter) inner slot)))
        (push (list :optional variable slot default (if (caddr parameter) (bind-name (caddr parameter) inner))) steps)
        (setq slot (1+ slot))))
    (when rest
      (push (list :rest (bind-name rest inner slot) slot) steps)
      (setq slot (1+ slot)))
    (dolist (parameter keys)
      (let* ((default (convert (caddr parameter) inner))
             (variable (bind-name (cadr parameter) inner slot)))
        (push (list :key variable slot default (if (cadddr parameter) (bind-name (cadddr parameter) inner))) steps)
        (setq slot (1+ slot))))
    (dolist (parameter aux)
      (let ((value (convert (cadr parameter) inner)))
        (push (list :aux (bind-name (car parameter) inner) value) steps)))
    (setf (fn-steps fn) (reverse steps)
          (fn-body fn) (if name
                           (convert-block name (body-forms body) inner)
                           (convert-progn (body-forms body) inner)))
    fn))

;;; The special forms

(defun c-quote (form env)
  (declare (ignore env))
  (list :const (cadr form)))

(defun c-function (form env)
  (let ((name (cadr form)))
    (cond ((and (consp name) (eq (car name) 'lambda))
           (list :closure (convert-function nil (cadr name) (cddr name) env)))
          ((not (symbolp name))
           (problem :error "~S is not the name of a function" name))
          (t (let ((local (assoc name (env-functions env))))
               (cond ((null local) (list :function name))
                     ((consp (cdr local))
                      (problem :error "~S is a macro or a special operator, not a function" name))
                     (t (use (cdr local) env) (list :ref (cdr local)))))))))

(defun c-lambda (form env)
  (list :closure (convert-function nil (cadr form) (cddr form) env)))

(defun c-if (form env)
  (list :if (convert (cadr form) env) (convert (caddr form) env) (convert (cadddr form) env)))

(defun c-progn (form env)
  (convert-progn (cdr form) env))

;; LET and LET*. In LET the values are all worked out where none of its
;; variables is in sight yet; in LET* each variable is there for the next.
(defun convert-let (form env in-turn)
  (let ((inner (copy-env env)) (bindings nil))
    (dolist (binding (cadr form))
      (let ((value (convert (if (consp binding) (cadr binding)) (if in-turn inner env))))
        (push (cons (if (consp binding) (car binding) binding) value) bindings)
        (when in-turn
          (setf (car (car bindings)) (bind-name (car (car bindings)) inner)))))
    (setq bindings (reverse bindings))
    (unless in-turn
      (dolist (binding bindings)
        (setf (car binding) (bind-name (car binding) inner))))
    (list :let in-turn bindings (convert-progn (body-forms (cddr form)) inner))))

(defun c-let (form env)
  (convert-let form env nil))

(defun c-let* (form env)
  (convert-let form env t))

(defun c-setq (form env)
  (let ((nodes nil))
    (do ((rest (cdr form) (cddr rest))) ((atom rest))
      (let ((name (car rest)))
        (unless (consp (cdr rest))
          (problem :error "SETQ has no value for ~S" name))
        (unless (and (symbolp name) (not (eq (clara:variable-kind name) :constant)))
          (problem :error "~S cannot be set: it is not a variable" name))
        (let ((value (convert (cadr rest) env))
              (found (if (clara:variable-kind name) nil (assoc name (env-variables env)))))
          (cond (found
                 (use (cdr found) env)
                 (setf (var-assigned (cdr found)) t)
                 (push (list :setq (cdr found) value) nodes))
                (t (push (list :set-special name value) nodes))))))
    (if nodes
        (list :progn (reverse nodes))
        (list :const nil))))

(defun convert-block (name forms env)
  (let ((blk (make-blk :name name :fn (env-fn env) :barrier (env-barrier env)))
        (inner (copy-env env)))
    (setf (env-blocks inner) (cons blk (env-blocks inner)))
    (list :block blk (convert-progn forms inner))))

(defun c-block (form env)
  (unless (symbolp (cadr form))
    (problem :error "~S cannot be the name of a block" (cadr form)))
  (convert-block (cadr form) (cddr form) env))

;; Can a jump from where ENV says not reach what FN and BARRIER had in
;; sight? Then control has to leave the long way, by the tag.
(defun far (env fn barrier)
  (not (and (eq (env-fn env) fn) (eq (env-barrier env) barrier))))

(defun c-return-from (form env)
  (let* ((name (cadr form))
         (blk (find-if (lambda (blk) (eq (blk-name blk) name)) (env-blocks env))))
    (unless blk
      (problem :control "RETURN-FROM ~S, and no block of that name is in sight" name))
    (let ((value (convert (caddr form) env)))
      (cond ((far env (blk-fn blk) (blk-barrier blk))
             (setf (blk-dynamic blk) t)
             (unless (blk-tag blk)
               (setf (blk-tag blk) (make-var :fn (blk-fn blk) :slot (new-slot (blk-fn blk)))))
             (use (blk-tag blk) env)
             (list :return-to blk value))
            (t (list :return-from blk value))))))

;; A body in which whatever is not a list is a tag, a place to GO to.
(defun c-tagbody (form env)
  (let ((tb (make-tb :fn (env-fn env) :barrier (env-barrier env)))
        (inner (copy-env env)) (count 0) (tags nil) (items nil))
    (dolist (item (cdr form))
      (unless (consp item)
        (push (list item tb count) tags)
        (setq count (1+ count))))
    (setf (tb-count tb) count
          (env-tags inner) (append (reverse tags) (env-tags inner)))
    (setq count 0)
    (dolist (item (cdr form))
      (cond ((consp item) (push (convert item inner) items))
            (t (push (list :tag count) items)
               (setq count (1+ count)))))
    (list :tagbody tb (reverse items))))

(defun c-go (form env)
  (let* ((tag (cadr form))
         (found (if (consp tag) nil (assoc tag (env-tags env)))))
    (unless found
      (problem :control "GO to ~S, and no TAGBODY in sight has that tag" tag))
    (let ((tb (cadr found)))
      (cond ((far env (tb-fn tb) (tb-barrier tb))
             (setf (tb-dynamic tb) t)
             (unless (tb-tag tb)
               (setf (tb-tag tb) (make-var :fn (tb-fn tb) :slot (new-slot (tb-fn tb)))))
             (use (tb-tag tb) env)
             (list :go-to tb (caddr found) tag))
            (t (list :go tb (caddr found)))))))

(defun c-catch (form env)
  (list :catch (convert (cadr form) env) (convert-progn (cddr form) env)))

(defun c-throw (form env)
  (list :throw (convert (cadr form) env) (convert (caddr form) env)))

(defun function-name (definition)
  (let ((name (car definition)))
    (unless (and name (symbolp name))
      (problem :error "~S cannot be the name of a function" name))
    name))

;; FLET and LABELS: a local function is a variable whose value is the
;; function. Those of LABELS can see one another, so each is made where
;; the variables of all are in sight, and they are variables that are set.
(defun c-flet (form env)
  (let ((inner (copy-env env)) (bindings nil))
    (dolist (definition (cadr form))
      (let* ((name (function-name definition))
             (function (convert-function name (cadr definition) (cddr definition) env))
             (variable (make-var :name name :fn (env-fn env) :slot (new-slot (env-fn env)))))
        (setf (env-functions inner) (cons (cons name variable) (env-functions inner)))
        (push (cons variable (list :closure function)) bindings)))
    (list :let nil (reverse bindings) (convert-progn (body-forms (cddr form)) inner))))

(defun c-labels (form env)
  (let ((inner (copy-env env)) (variables nil) (bindings nil))
    (dolist (definition (cadr form))
      (let ((variable (make-var :name (function-name definition) :fn (env-fn env)
                                :slot (new-slot (env-fn env)) :assigned t)))
        (setf (env-functions inner) (cons (cons (car definition) variable) (env-functions inner)))
        (push variable variables)))
    (setq variables (reverse variables))
    (dolist (definition (cadr form))
      (push (cons (car variables)
                  (list :closure (convert-function (car definition) (cadr definition) (cddr definition) inner)))
            bindings)
      (setq variables (cdr variables)))
    (list :labels (reverse bindings) (convert-progn (body-forms (cddr form)) inner))))

;; MACROLET: each macro is a macro of the evaluator's, under a name that
;; nobody else has, and a call is expanded by putting that name in the
;; place of the macro's.
(defun c-macrolet (form env)
  (let ((inner (copy-env env)))
    (dolist (definition (cadr form))
      (let ((name (function-name definition)) (expander (gensym)))
        (eval (list 'defmacro expander (cadr definition)
                    (list* 'block name (body-forms (cddr definition)))))
        (setf (env-functions inner) (cons (list* name :macro expander) (env-functions inner)))))
    (convert-progn (body-forms (cddr form)) inner)))

;; Where the stack is as deep as the values of a form are many, no jump
;; can leave: the forms there are behind a barrier.
(defun behind (env)
  (let ((inner (copy-env env)))
    (setf (env-barrier inner) (list nil))
    inner))

(defun c-multiple-value-call (form env)
  (list :values-call (convert (cadr form) env) (convert-all (cddr form) (behind env)) (new-slot (env-fn env))))

(defun c-multiple-value-prog1 (form env)
  (list :values-prog1 (convert (cadr form) env) (convert-progn (cddr form) (behind env))))

(defun c-multiple-value-bind (form env)
  (let ((value (convert (caddr form) env)) (inner (copy-env env)) (variables nil))
    (dolist (name (cadr form))
      (push (bind-name name inner) variables))
    (list :values-bind (reverse variables) value (convert-progn (body-forms (cdddr form)) inner))))

(defun c-unwind-protect (form env)
  (list :unwind-protect (convert (cadr form) (behind env)) (convert-progn (cddr form) (behind env))))

;; (handler-case form (type ([variable]) form...)... (:no-error lambda-list form...))
(defun c-handler-case (form env)
  (let ((clauses nil) (no-error nil))
    (dolist (clause (cddr form))
      (cond ((eq (car clause) :no-error)
             (setq no-error (list :closure (convert-function nil (cadr clause) (cddr clause) env))))
            (t (let* ((inner (copy-env env))
                      (variable (if (consp (cadr clause)) (bind-name (car (cadr clause)) inner))))
                 (push (list (car clause) variable (convert-progn (body-forms (cddr clause)) inner)) clauses)))))
    (list :handler-case (convert (cadr form) env) (reverse clauses) no-error (new-slot (env-fn env)))))

(defun c-eval-when (form env)
  (if (or (member :execute (cadr form)) (member 'eval (cadr form)))
      (convert-progn (cddr form) env)
      (list :const nil)))

(defun c-locally (form env)
  (convert-progn (body-forms (cdr form)) env))

(defun c-the (form env)
  (convert (caddr form) env))

(defun c-declare (form env)
  (declare (ignore form env))
  (problem :error "a DECLARE where a form has to be: it belongs at the start of a body"))

(defun c-defun (form env)
  (list :fset (function-name (cdr form))
        (list :closure (convert-function (cadr form) (caddr form) (cdddr form) env))))

;; A macro stays the evaluator's: its body runs when a call of it is
;; expanded, and a call in compiled code was expanded by the compiler.
(defun c-defmacro (form env)
  (declare (ignore env))
  (function-name (cdr form))
  (list :defmacro (cdr form)))

(defun convert-defvar (form env always)
  (unless (symbolp (cadr form))
    (problem :error "~S cannot be made a variable" (cadr form)))
  (list :defvar (cadr form) (if (consp (cddr form)) (convert (caddr form) env)) always))

(defun c-defvar (form env)
  (convert-defvar form env nil))

(defun c-defparameter (form env)
  (convert-defvar form env t))

(defun c-defconstant (form env)
  (unless (symbolp (cadr form))
    (problem :error "~S cannot be made a constant" (cadr form)))
  (list :defconstant (cadr form) (convert (caddr form) env)))

;; Backquote. The form that makes what the backquoted X stands for: a copy
;; of it in which every ,form is the value of the form and the items of the
;; value of every ,@form take its place. Inside another backquote a comma
;; belongs to that one, and stays. Every list is made anew, as the
;; evaluator makes it.
(defun quasi (x depth)
  (if (atom x)
      (list 'quote x)
      (let ((first x) (parts nil) (items nil) (tail nil))
        (cond ((or (eq (car x) *unquote*) (eq (car x) *splice*))
               (cond ((> depth 1) (setq depth (1- depth)))
                     ((eq (car x) *splice*)
                      (problem :error ",@ with no list around it to put the items in"))
                     (t (return-from quasi (cadr x)))))
              ((eq (car x) *quasiquote*) (setq depth (1+ depth))))
        (loop
          (when (atom x)
            (setq tail (list 'quote x))
            (return))
          (let ((item (car x)))
            (cond ((and (eq item *unquote*) (not (eq x first)) (= depth 1))
                   (setq tail (cadr x))       ; (a . ,b) is read as (a unquote b)
                   (return))
                  ((and (= depth 1) (consp item) (eq (car item) *splice*))
                   (when items
                     (push (list* '%call 'list (reverse items)) parts)
                     (setq items nil))
                   (push (cadr item) parts))
                  (t (push (quasi item depth) items))))
          (setq x (cdr x)))
        (cond (parts
               (when items
                 (push (list* '%call 'list (reverse items)) parts))
               (list* '%call 'append (reverse (cons tail parts))))
              ((equal tail '(quote nil))
               (list* '%call 'list (reverse items)))
              (t (list* '%call 'list* (reverse (cons tail items))))))))

(defun c-quasiquote (form env)
  (convert (quasi (cadr form) 1) env))

;; A list taken apart, the way the arguments of a macro are: the bindings
;; of a LET* that give every variable of PATTERN its part of the list that
;; WHOLE is bound to.
(defun bind-pattern (parameter form bindings)
  (if (consp parameter)
      (let ((inner (gensym)))
        (append (reverse (destructure-bindings parameter inner)) (cons (list inner form) bindings)))
      (cons (list parameter form) bindings)))

(defun destructure-bindings (pattern whole)
  (let ((rest (gensym)) (stage 0) (bindings nil) (keys nil) (keyed nil) (allow nil) (all nil))
    (push (list rest whole) bindings)
    (do ((list pattern (cdr list)))
        ((atom list)
         (when list
           (setq bindings (bind-pattern list rest bindings)
                 all t)))
      (let ((parameter (car list)))
        (cond ((eq parameter '&optional) (setq stage 1))
              ((or (eq parameter '&rest) (eq parameter '&body)) (setq stage 2))
              ((eq parameter '&key) (setq stage 3 keyed t))
              ((eq parameter '&allow-other-keys) (setq allow t))
              ((eq parameter '&aux) (setq stage 4))
              ((eq parameter '&whole)
               (setq list (cdr list))
               (setq bindings (bind-pattern (car list) whole bindings)))
              ((eq parameter '&environment)
               (problem :error "&ENVIRONMENT in a lambda list, which the evaluator does not know yet"))
              ((= stage 0)
               (setq bindings
                     (bind-pattern parameter
                                   (list 'if (list '%call 'consp rest)
                                         (list '%call 'car rest)
                                         (list '%fail :program "DESTRUCTURING-BIND got too few arguments"))
                                   bindings))
               (push (list rest (list '%call 'cdr rest)) bindings))
              ((= stage 1)
               (let ((given (gensym)))
                 (push (list given (list '%call 'consp rest)) bindings)
                 (setq bindings
                       (bind-pattern (if (consp parameter) (car parameter) parameter)
                                     (list 'if given (list '%call 'car rest) (if (consp parameter) (cadr parameter)))
                                     bindings))
                 (push (list rest (list 'if given (list '%call 'cdr rest) rest)) bindings)
                 (when (and (consp parameter) (caddr parameter))
                   (push (list (caddr parameter) given) bindings))))
              ((= stage 2)
               (setq bindings (bind-pattern parameter rest bindings)
                     all t))
              ((= stage 3)
               (let* ((spec (if (consp parameter) (car parameter) parameter))
                      (keyword (if (consp spec) (car spec) (keyword-of spec)))
                      (found (gensym)))
                 (push keyword keys)
                 (push (list found (list '%call 'key-tail rest (list 'quote keyword))) bindings)
                 (setq bindings
                       (bind-pattern (if (consp spec) (cadr spec) spec)
                                     (list 'if found (list '%call 'car (list '%call 'cdr found))
                                           (if (consp parameter) (cadr parameter)))
                                     bindings))
                 (when (and (consp parameter) (caddr parameter))
                   (push (list (caddr parameter) (list 'if found t nil)) bindings))))
              (t (push (if (consp parameter) (list (car parameter) (cadr parameter)) (list parameter nil))
                       bindings)))))
    (cond (keyed
           (push (list (gensym)
                       (list 'if (list '%call 'check-keys rest (list 'quote (reverse keys)) (list 'quote allow))
                             (list '%fail :program "DESTRUCTURING-BIND got an odd number of keyword arguments")
                             nil))
                 bindings))
          ((not all)
           (push (list (gensym)
                       (list 'if (list '%call 'consp rest)
                             (list '%fail :program "DESTRUCTURING-BIND got too many arguments")
                             nil))
                 bindings)))
    (reverse bindings)))

(defun c-destructuring-bind (form env)
  (let ((whole (gensym)))
    (convert (list* 'let* (cons (list whole (caddr form)) (destructure-bindings (cadr form) whole)) (cdddr form))
             env)))

;; What the code that takes a list apart calls while it runs: the rest of a
;; list of keywords and values from KEY on, or NIL; and a look at such a
;; list as a whole, which is true when it has a keyword without a value.
(defun key-tail (plist key)
  (do ((rest plist (if (consp (cdr rest)) (cddr rest) nil))) ((atom rest) nil)
    (when (eq (car rest) key)
      (return rest))))

(defun check-keys (plist keys allow)
  (cond ((oddp (count-parts plist)) t)
        (t (do ((rest plist (cddr rest))) ((atom rest))
             (when (and (eq (car rest) :allow-other-keys) (cadr rest))
               (setq allow t)))
           (unless allow
             (do ((rest plist (cddr rest))) ((atom rest))
               (unless (or (member (car rest) keys) (eq (car rest) :allow-other-keys))
                 (error "DESTRUCTURING-BIND does not take the keyword argument ~S" (car rest)))))
           nil)))

;; Three forms that only the compiler writes: a call of the function that a
;; name has for everybody, whatever FLET has made of the name where the
;; form stands; an error of a kind, in words; and a condition that is
;; there already, signalled.
(defun c-call (form env)
  (list :call (list :const (cadr form)) (convert-all (cddr form) env)))

(defun c-fail (form env)
  (declare (ignore env))
  (list :fail (cadr form) (caddr form)))

(defun c-raise (form env)
  (declare (ignore env))
  (list :call (list :const 'error) (list (list :const (cadr form)))))

(setq *special-forms*
      (list (list 'quote 1 1 'c-quote) (list 'function 1 1 'c-function) (list 'lambda 1 nil 'c-lambda)
            (list 'if 2 3 'c-if) (list 'progn 0 nil 'c-progn) (list 'let 1 nil 'c-let) (list 'let* 1 nil 'c-let*)
            (list 'setq 0 nil 'c-setq) (list 'block 1 nil 'c-block) (list 'return-from 1 2 'c-return-from)
            (list 'tagbody 0 nil 'c-tagbody) (list 'go 1 1 'c-go) (list 'catch 1 nil 'c-catch)
            (list 'throw 2 2 'c-throw) (list 'flet 1 nil 'c-flet) (list 'labels 1 nil 'c-labels)
            (list 'macrolet 1 nil 'c-macrolet) (list 'multiple-value-call 1 nil 'c-multiple-value-call)
            (list 'multiple-value-prog1 1 nil 'c-multiple-value-prog1)
            (list 'multiple-value-bind 2 nil 'c-multiple-value-bind)
            (list 'destructuring-bind 2 nil 'c-destructuring-bind) (list 'eval-when 1 nil 'c-eval-when)
            (list 'locally 0 nil 'c-locally) (list 'the 2 2 'c-the) (list 'declare 0 nil 'c-declare)
            (list 'defun 2 nil 'c-defun) (list 'defmacro 2 nil 'c-defmacro) (list 'defvar 1 3 'c-defvar)
            (list 'defparameter 2 3 'c-defparameter) (list 'defconstant 2 3 'c-defconstant)
            (list 'unwind-protect 1 nil 'c-unwind-protect) (list 'handler-case 1 nil 'c-handler-case)
            (list '%call 1 nil 'c-call) (list '%fail 2 2 'c-fail) (list '%raise 1 1 'c-raise)))
(when *quasiquote*
  (push (list *quasiquote* 1 1 'c-quasiquote) *special-forms*))

;;; The second pass
;;;
;;; The instructions of one function are written in order. *DEPTH* is how
;;; many words they have on the stack above the local variables where the
;;; next one goes, *RECORDS* how many records are in force there and
;;; *BOUND* how many special variables the function has bound: a jump out
;;; of the middle of things has to put all three right for where it goes.
;;;
;;; A form is written for one of four uses of its value. :EFFECT: none, and
;;; nothing is left on the stack. :ONE: its first value, on the stack.
;;; :MULTI: the same, and all of its values where the machine keeps them
;;; (lisp_values). :TAIL: they are the values of the function, which
;;; returns.

(defvar *fn* nil)
(defvar *code* nil)        ; the instructions so far, the last first: (number a b), or a label
(defvar *constants* nil)   ; what they name, the last first
(defvar *depth* 0)
(defvar *deepest* 0)
(defvar *records* 0)
(defvar *bound* 0)

(defun emit (name &optional (a 0) (b 0))
  (let ((effect (get name 'effect)))
    (push (list (get name 'number) a b) *code*)
    (setq *depth* (+ *depth* (cond ((eq effect :a) (- a))
                                   ((eq effect :b) (- 1 b))
                                   ((eq effect :spread) (1- a))
                                   (t effect))))
    (when (> *depth* *deepest*)
      (setq *deepest* *depth*))))

;; A place in the instructions that a jump can name before it is known
;; where it is.
(defun label ()
  (list :label nil))

(defun place (label)
  (push label *code*))

;; Which of the function's constants an object is: the one that is there
;; already, if it is the same object.
(defun constant (object)
  (let ((found (member object *constants*)))
    (cond (found (length (cdr found)))
          (t (push object *constants*)
             (1- (length *constants*))))))

(defun gen (node mode)
  (let ((depth *depth*))
    (funcall (get (car node) 'generator) node mode)
    (setq *depth* (if (or (eq mode :one) (eq mode :multi)) (1+ depth) depth))))

;; One value is on the stack, and that is the form done. ALL says that the
;; machine has all of its values too.
(defun done (mode all)
  (cond ((eq mode :effect) (emit :drop 1))
        ((eq mode :multi) (unless all (emit :one)))
        ((eq mode :tail) (emit (if all :return :return-one)))))

(defun cell-p (variable)
  (and (var-captured variable) (var-assigned variable)))

;; What the function has of a variable: its slot, or its place among the
;; values that the function closes over.
(defun gen-raw (variable)
  (if (eq (var-fn variable) *fn*)
      (emit :local (var-slot variable))
      (emit :closed (position variable (fn-closed *fn*)))))

(defun gen-ref (variable)
  (gen-raw variable)
  (when (cell-p variable)
    (emit :cell-ref)))

;; The value on top of the stack goes into a variable,
(defun gen-set (variable)
  (cond ((cell-p variable) (gen-raw variable) (emit :cell-set))
        (t (emit :set-local (var-slot variable)))))

;; or into a new binding of one.
(defun gen-bind (variable)
  (cond ((symbolp variable)
         (emit :bind (constant variable))
         (setq *bound* (1+ *bound*)))
        ((cell-p variable)
         (emit :cell)
         (emit :set-local (var-slot variable)))
        (t (emit :set-local (var-slot variable)))))

;; The bindings of special variables that were made since BOUND are undone,
;; unless the function is about to return, which undoes them all.
(defun unbind-to (bound mode)
  (when (and (> *bound* bound) (not (eq mode :tail)))
    (emit :unbind (- *bound* bound)))
  (setq *bound* bound))

;; Control is about to jump to where RECORDS records were in force, BOUND
;; special variables bound and the stack DEPTH deep. With VALUE, what is on
;; top goes along.
(defun leave (records bound depth value)
  (when (> *records* records)
    (emit :unlink (- *records* records)))
  (when (> *bound* bound)
    (emit :unbind (- *bound* bound)))
  (let ((extra (- *depth* depth (if value 1 0))))
    (when (> extra 0)
      (emit (if value :nip :drop) extra))))

(defun g-const (node mode)
  (unless (eq mode :effect)
    (emit :const (constant (cadr node)))
    (done mode nil)))

(defun g-ref (node mode)
  (unless (eq mode :effect)
    (gen-ref (cadr node))
    (done mode nil)))

(defun g-special (node mode)
  (emit :special (constant (cadr node)))
  (done mode nil))

(defun g-function (node mode)
  (emit :function (constant (cadr node)))
  (done mode nil))

(defun g-setq (node mode)
  (gen (caddr node) :one)
  (unless (eq mode :effect)
    (emit :dup))
  (gen-set (cadr node))
  (unless (eq mode :effect)
    (done mode nil)))

(defun g-set-special (node mode)
  (gen (caddr node) :one)
  (unless (eq mode :effect)
    (emit :dup))
  (emit :set-special (constant (cadr node)))
  (unless (eq mode :effect)
    (done mode nil)))

(defun g-if (node mode)
  (let ((otherwise (label)) (end (label)) (depth *depth*))
    (gen (cadr node) :one)
    (emit :jump-if-nil otherwise)
    (gen (caddr node) mode)
    (unless (eq mode :tail)
      (emit :jump end))
    (place otherwise)
    (setq *depth* depth)
    (gen (cadddr node) mode)
    (place end)))

(defun g-progn (node mode)
  (do ((nodes (cadr node) (cdr nodes))) ((null (cdr nodes)) (gen (car nodes) mode))
    (gen (car nodes) :effect)))

(defun g-call (node mode)
  (gen (cadr node) :one)
  (dolist (argument (caddr node))
    (gen argument :one))
  (emit :call (length (caddr node)))
  (done mode t))

;; A function inside this one is made: what it closes over is pushed, each
;; as this function has it, and goes into the new function.
(defun g-closure (node mode)
  (let* ((fn (cadr node)) (code (generate fn)))
    (dolist (variable (fn-closed fn))
      (gen-raw variable))
    (emit :closure (constant code) (length (fn-closed fn)))
    (done mode nil)))

;; A variable that is not special is bound as soon as its value is there:
;; no form of the same LET can see it. The special ones of a LET wait until
;; every value has been worked out.
(defun g-let (node mode)
  (let ((bound *bound*) (waiting nil))
    (dolist (binding (caddr node))
      (gen (cdr binding) :one)
      (if (and (symbolp (car binding)) (not (cadr node)))
          (push (car binding) waiting)
          (gen-bind (car binding))))
    (dolist (variable waiting)
      (gen-bind variable))
    (gen (cadddr node) mode)
    (unbind-to bound mode)))

(defun g-labels (node mode)
  (dolist (binding (cadr node))
    (when (cell-p (car binding))
      (emit :const (constant nil))
      (emit :cell)
      (emit :set-local (var-slot (car binding)))))
  (dolist (binding (cadr node))
    (gen (cdr binding) :one)
    (gen-set (car binding)))
  (gen (caddr node) mode))

;; A block always has its value on the stack where it ends, since that is
;; where the machine leaves the value of a RETURN-FROM that came the long
;; way. One that is the last thing a function does needs no end at all:
;; whoever leaves it returns from the function.
(defun g-block (node mode)
  (let* ((blk (cadr node)) (end (label)) (inside (if (eq mode :effect) :one mode)))
    (when (and (blk-dynamic blk) (eq inside :tail))
      (setq inside :multi))
    (setf (blk-label blk) end
          (blk-depth blk) *depth*
          (blk-records blk) *records*
          (blk-bound blk) *bound*
          (blk-mode blk) inside)
    (cond ((blk-dynamic blk)
           (emit :block end (var-slot (blk-tag blk)))
           (setq *records* (1+ *records*))
           (gen (caddr node) inside)
           (emit :unlink 1)
           (emit :nip 6)
           (setq *records* (1- *records*))
           (place end)
           (cond ((eq mode :tail) (emit :return))
                 ((eq mode :effect) (emit :drop 1))))
          (t (gen (caddr node) inside)
             (place end)
             (when (eq mode :effect)
               (emit :drop 1))))))

(defun g-return-from (node mode)
  (declare (ignore mode))
  (let ((blk (cadr node)))
    (gen (caddr node) (blk-mode blk))
    (unless (eq (blk-mode blk) :tail)
      (leave (blk-records blk) (blk-bound blk) (blk-depth blk) t)
      (emit :jump (blk-label blk)))))

(defun g-return-to (node mode)
  (declare (ignore mode))
  (let ((blk (cadr node)))
    (gen-ref (blk-tag blk))
    (gen (caddr node) :multi)
    (emit :return-to (constant (blk-name blk)))))

;; A tagbody that is left the long way keeps its record while control is
;; inside it: the machine comes back to the instruction after TAGBODY with
;; the number of the tag on the stack, and DISPATCH sends it on.
(defun g-tagbody (node mode)
  (let ((tb (cadr node)) (places nil))
    (dotimes (i (tb-count tb))
      (push (label) places))
    (setf (tb-places tb) places)
    (when (tb-dynamic tb)
      (let ((landing (label)) (body (label)))
        (emit :tagbody landing (var-slot (tb-tag tb)))
        (setq *records* (1+ *records*))
        (emit :jump body)
        (place landing)
        (setq *depth* (1+ *depth*))
        (when (> *depth* *deepest*)
          (setq *deepest* *depth*))
        (emit :dispatch (tb-count tb))
        (dolist (place places)
          (emit :jump place))
        (place body)))
    (setf (tb-depth tb) *depth*
          (tb-records tb) *records*
          (tb-bound tb) *bound*)
    (dolist (item (caddr node))
      (if (eq (car item) :tag)
          (place (nth (cadr item) places))
          (gen item :effect)))
    (when (tb-dynamic tb)
      (emit :unlink 1)
      (emit :drop 6)
      (setq *records* (1- *records*)))
    (unless (eq mode :effect)
      (emit :const (constant nil))
      (done mode nil))))

(defun g-go (node mode)
  (declare (ignore mode))
  (let ((tb (cadr node)))
    (leave (tb-records tb) (tb-bound tb) (tb-depth tb) nil)
    (emit :jump (nth (caddr node) (tb-places tb)))))

(defun g-go-to (node mode)
  (declare (ignore mode))
  (gen-ref (tb-tag (cadr node)))
  (emit :go-to (caddr node) (constant (cadddr node))))

(defun g-catch (node mode)
  (let ((landing (label)))
    (gen (cadr node) :one)
    (emit :catch landing)
    (setq *records* (1+ *records*))
    (gen (caddr node) (if (or (eq mode :effect) (eq mode :one)) :one :multi))
    (emit :unlink 1)
    (emit :nip 6)
    (setq *records* (1- *records*))
    (place landing)
    (cond ((eq mode :tail) (emit :return))
          ((eq mode :effect) (emit :drop 1)))))

(defun g-throw (node mode)
  (declare (ignore mode))
  (gen (cadr node) :one)
  (gen (caddr node) :multi)
  (emit :throw))

;; The cleanup is written once. Control comes to it from the end of the
;; form and, when the form is left any other way, from the machine, with
;; the same things on the stack (cleanup, kernel/lisp/vm.c).
(defun g-unwind-protect (node mode)
  (let ((cleanup (label)) (depth *depth*))
    (emit :protect cleanup)
    (setq *records* (1+ *records*))
    (gen (cadr node) :multi)
    (emit :cleanup)
    (place cleanup)
    (gen (caddr node) :effect)
    (emit :cleanup-end)
    (setq *records* (1- *records*))
    (setq *depth* (1+ depth))
    (done mode t)))

;; The arguments are as many as the forms have values, which a local
;; variable counts.
(defun g-values-call (node mode)
  (let ((counter (cadddr node)) (depth *depth*))
    (gen (cadr node) :one)
    (emit :const (constant 0))
    (emit :set-local counter)
    (dolist (argument (caddr node))
      (gen argument :multi)
      (emit :values-push counter))
    (emit :values-call counter)
    (setq *depth* (1+ depth))
    (done mode t)))

(defun g-values-prog1 (node mode)
  (cond ((or (eq mode :effect) (eq mode :one))
         (gen (cadr node) mode)
         (gen (caddr node) :effect))
        (t (let ((depth *depth*))
             (gen (cadr node) :multi)
             (emit :values-save)
             (gen (caddr node) :effect)
             (emit :values-restore)
             (setq *depth* (1+ depth))
             (done mode t)))))

(defun g-values-bind (node mode)
  (let ((variables (cadr node)) (bound *bound*))
    (cond ((null variables) (gen (caddr node) :effect))
          (t (gen (caddr node) :multi)
             (emit :values-spread (length variables))
             (dolist (variable (reverse variables))
               (gen-bind variable))))
    (gen (cadddr node) mode)
    (unbind-to bound mode)))

;; The record names the types of the clauses, each with its number. When
;; one of them takes a condition, the machine comes back with the condition
;; and that number on the stack. The function of a :NO-ERROR clause waits
;; under the record for the values of the form.
(defun g-handler-case (node mode)
  (let* ((clauses (caddr node)) (no-error (cadddr node)) (counter (nth 4 node))
         (end (label)) (landing (label)) (depth *depth*) (places nil) (types nil) (number 0)
         (inside (cond (no-error :multi) ((eq mode :effect) :one) ((eq mode :tail) :multi) (t mode))))
    (when no-error
      (gen no-error :one)
      (emit :const (constant 0))
      (emit :set-local counter))
    (cond (clauses
           (dolist (clause clauses)
             (push (cons (car clause) number) types)
             (push (label) places)
             (setq number (1+ number)))
           (emit :handler landing (constant (reverse types)))
           (setq *records* (1+ *records*))
           (gen (cadr node) inside)
           (emit :unlink 1)
           (emit :nip 6)
           (setq *records* (1- *records*)))
          (t (gen (cadr node) inside)))
    (when no-error
      (emit :values-push counter)
      (emit :values-call counter)
      (setq *depth* (1+ depth)))
    (done mode (or no-error (eq inside :multi)))
    (when clauses
      (unless (eq mode :tail)
        (emit :jump end))
      (place landing)
      (setq *depth* (+ depth (if no-error 3 2)))
      (when (> *depth* *deepest*)
        (setq *deepest* *depth*))
      (emit :dispatch (length clauses))
      (dolist (place places)
        (emit :jump place))
      (dolist (clause clauses)
        (let ((bound *bound*))
          (place (car places))
          (setq places (cdr places))
          (setq *depth* (+ depth (if no-error 2 1)))
          (when no-error
            (emit :nip 1))
          (if (cadr clause)
              (gen-bind (cadr clause))
              (emit :drop 1))
          (gen (caddr clause) mode)
          (unbind-to bound mode)
          (unless (eq mode :tail)
            (emit :jump end))))
      (place end))))

(defun g-fail (node mode)
  (declare (ignore mode))
  (emit :fail (position (cadr node) '(:error :program :control)) (constant (caddr node))))

(defun g-fset (node mode)
  (gen (caddr node) :one)
  (emit :fset (constant (cadr node)))
  (done mode nil))

(defun g-defmacro (node mode)
  (emit :defmacro (constant (cadr node)))
  (done mode nil))

(defun g-defvar (node mode)
  (let ((name (constant (cadr node))) (value (caddr node)) (skip (label)))
    (emit :defvar name)
    (cond ((null value) (emit :drop 1))
          ((cadddr node)
           (emit :drop 1)
           (gen value :one)
           (emit :set-special name))
          (t (emit :jump-if-nil skip)
             (gen value :one)
             (emit :set-special name)
             (place skip)))
    (emit :const name)
    (done mode nil)))

(defun g-defconstant (node mode)
  (gen (caddr node) :one)
  (emit :defconstant (constant (cadr node)))
  (done mode nil))

(dolist (row '((:const g-const) (:ref g-ref) (:special g-special) (:function g-function) (:setq g-setq)
               (:set-special g-set-special) (:if g-if) (:progn g-progn) (:call g-call) (:closure g-closure)
               (:let g-let) (:labels g-labels) (:block g-block) (:return-from g-return-from)
               (:return-to g-return-to) (:tagbody g-tagbody) (:go g-go) (:go-to g-go-to) (:catch g-catch)
               (:throw g-throw) (:unwind-protect g-unwind-protect) (:values-call g-values-call)
               (:values-prog1 g-values-prog1) (:values-bind g-values-bind) (:handler-case g-handler-case)
               (:fail g-fail) (:fset g-fset) (:defmacro g-defmacro) (:defvar g-defvar)
               (:defconstant g-defconstant)))
  (setf (get (car row) 'generator) (cadr row)))

;; The parameter whose argument is in a slot: bound, if it is special, and
;; in a cell, if it is shared and set.
(defun gen-parameter (variable slot)
  (cond ((symbolp variable)
         (emit :local slot)
         (gen-bind variable))
        ((cell-p variable)
         (emit :local slot)
         (emit :cell)
         (emit :set-local slot))))

(defun gen-steps (fn)
  (dolist (step (fn-steps fn))
    (let ((kind (car step)) (variable (cadr step)))
      (cond ((or (eq kind :required) (eq kind :rest))
             (gen-parameter variable (caddr step)))
            ((eq kind :aux)
             (gen (caddr step) :one)
             (gen-bind variable))
            (t (let ((slot (caddr step)) (supplied (nth 4 step)) (given (label)))
                 (when supplied
                   (emit :supplied slot))
                 (emit :jump-if-supplied given slot)
                 (gen (cadddr step) :one)
                 (emit :set-local slot)
                 (place given)
                 (gen-parameter variable slot)
                 (when supplied
                   (gen-bind supplied))))))))

;; The instructions as the machine takes them, a word each, with every
;; label the number of the instruction that it stands before; and with them
;; the rest of what code is (enum lisp_code, kernel/lisp/lisp.h).
(defun assemble (fn)
  (let ((items (reverse *code*)) (at 0) (words nil))
    (dolist (item items)
      (if (eq (car item) :label)
          (setf (cadr item) at)
          (setq at (1+ at))))
    (dolist (item items)
      (unless (eq (car item) :label)
        (let ((a (cadr item)))
          (push (+ (car item) (ash (if (consp a) (cadr a) a) 8) (ash (caddr item) 32)) words))))
    (vector (apply #'vector (reverse words)) (apply #'vector (reverse *constants*))
            (fn-name fn) (fn-lambda-list fn) (fn-required fn) (fn-optional fn) (fn-rest fn)
            (if (fn-keyed fn) (apply #'vector (fn-keys fn)) nil) (fn-allow fn)
            (fn-slots fn) *deepest* (length (fn-closed fn)))))

(defun generate (fn)
  (let ((*fn* fn) (*code* nil) (*constants* nil) (*depth* 0) (*deepest* 0) (*records* 0) (*bound* 0))
    (gen-steps fn)
    (gen (fn-body fn) :tail)
    (assemble fn)))

;;; What the compiler is to the rest of the system

;; A compiled function of a LAMBDA form that stands by itself: no variable
;; and no function around it is in sight. NAME is the function's own, and
;; that of a block around its body.
(defun compile-lambda (form &optional name)
  (unless (and (consp form) (eq (car form) 'lambda) (consp (cdr form)))
    (error "the compiler takes a LAMBDA form, and ~S is not one" form))
  (clara.unsafe:make-compiled-function
   (generate (convert-function name (cadr form) (cddr form) (make-env)))))

;; What EVALUATE calls the function with that it has made of a form. The
;; kernel's self-test puts a function here that has the collector run all
;; the while (kernel/lisp/lisp.c).
(defvar *call* 'funcall)

;; The values of a form, like EVAL, with the form compiled first. A PROGN
;; is taken a form at a time, and so is what a macro makes of the form:
;; each is evaluated before the next is compiled, so that a DEFVAR or a
;; DEFMACRO counts for the forms after it, as it does in a file.
(defun evaluate (form)
  (cond ((and (consp form) (eq (car form) 'progn))
         (let ((values (list nil)))
           (dolist (part (cdr form))
             (setq values (multiple-value-list (evaluate part))))
           (values-list values)))
        ((and (consp form) (symbolp (car form)) (not (assoc (car form) *special-forms*)))
         (multiple-value-bind (expansion expanded) (macroexpand-1 form)
           (if expanded
               (evaluate expansion)
               (funcall *call* (compile-lambda (list 'lambda nil form))))))
        (t (funcall *call* (compile-lambda (list 'lambda nil form))))))

;;; The listing of a compiled function, for DISASSEMBLE

(defun padded (number width)
  (let ((text (princ-to-string number)))
    (concatenate 'string text (subseq "        " 0 (max 1 (- width (length text)))))))

(defun code-title (code)
  (or (aref code 2) (list 'lambda (aref code 3))))

(defun list-operand (kind operand constants)
  (cond ((null kind))
        ((eq kind :constant) (format t " ~S" (aref constants operand)))
        ((eq kind :code) (format t " ~S" (code-title (aref constants operand))))
        (t (format t " ~D" operand))))

;; The instructions of code, one to a line: its number, what it does, and
;; its operands, a constant as itself. The functions inside it follow, each
;; in the same way.
(defun list-code (code)
  (let ((instructions (aref code 0)) (constants (aref code 1)) (inner nil))
    (format t "~S: ~D local variable~A, ~D word~A of stack~%" (code-title code)
            (aref code 9) (if (= (aref code 9) 1) "" "s") (aref code 10) (if (= (aref code 10) 1) "" "s"))
    (dotimes (at (length instructions))
      (let* ((word (aref instructions at))
             (row (nth (logand word 255) *operations*))
             (a (logand (ash word -8) #xffffff)))
        (format t "~A~A" (padded at 4) (symbol-name (car row)))
        (list-operand (caddr row) a constants)
        (list-operand (cadddr row) (ash word -32) constants)
        (terpri)
        (when (eq (caddr row) :code)
          (push (aref constants a) inner))))
    (dolist (code (reverse inner))
      (list-code code))))

(defun list-function (function)
  (let ((code (clara.unsafe:compiled-function-code function)))
    (fresh-line)
    (if code
        (list-code code)
        (format t "~S is written in C, and there is no listing of it here~%" function))
    nil))

(clara:provide-compiler :compile 'compile-lambda :list 'list-function)
