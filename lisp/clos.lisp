;;;; clos.lisp: classes, generic functions and methods
;;;;
;;;; The part of Common Lisp that is called its object system. A class says
;;;; what its instances hold, their slots, and which classes it is a kind
;;;; of; a generic function is a function whose behaviour is put together
;;;; from methods, each written for arguments of some classes; and a call
;;;; runs the methods that fit the arguments it was given, the most
;;;; specific first.
;;;;
;;;; Everything here is Lisp. An instance is a structure of three slots:
;;;; its class, the names of its slots in the order of their values, and
;;;; the values, in a vector of their own, so that an instance can be given
;;;; other slots when its class is defined again. A class and a method are
;;;; structures too. A generic function is a function, the one that is
;;;; called under its name: it hands the arguments on (DISPATCH), and it
;;;; carries a structure with what a generic function keeps, its methods
;;;; among it, which is what makes it a generic function to CLASS-OF and
;;;; to the printer. What the methods that fit a list of classes come to,
;;;; one function, is worked out the first time such arguments arrive and
;;;; kept there until a method or a class changes.
;;;;
;;;; The names that Common Lisp has for all this are symbols of
;;;; COMMON-LISP, which this file exports from there, as lisp/boot.lisp
;;;; does for its part of the language; what is its own is in CLARA.CLOS.
;;;; So this is the second file that SBCL cannot load as it stands: it has
;;;; every one of these names already, and they are not to be given another
;;;; meaning. The host tests read the file a form at a time into a package
;;;; in which those names are symbols of its own, and hold what it does
;;;; against what SBCL's object system does with the same forms
;;;; (tools/objects.txt).

(in-package "COMMON-LISP")

;;; A name that is exported here is one that COMMON-LISP did not have: the
;;; host tests make each of them a symbol of their own before they read on,
;;; so a name that the language has already, and that this file calls,
;;; must not be in the list.
(export '(defclass defgeneric defmethod
          make-instance initialize-instance reinitialize-instance shared-initialize
          slot-value slot-boundp slot-makunbound slot-exists-p with-slots with-accessors
          slot-unbound slot-missing unbound-slot unbound-slot-instance
          call-next-method next-method-p no-applicable-method no-next-method
          class-of find-class class-name typep type-of typecase etypecase
          print-object print-unreadable-object
          standard-object standard-class built-in-class structure-class structure-object class
          generic-function standard-generic-function method standard-method
          number real rational integer fixnum character symbol keyword boolean
          sequence array package stream satisfies))

(defpackage "CLARA.CLOS"
  (:use "COMMON-LISP"))
(in-package "CLARA.CLOS")

;;; What the substrate knows, and SBCL in its place: the host tests define
;;; these ten themselves, from what SBCL knows, before they read on
;;; (lisp/host/objects.lisp).
;;;
;;; KIND-OF is what an object is to the substrate, as the name of a class:
;;; INTEGER, CONS, the name of a structure's type, the type of a condition,
;;; and T for what has no class of its own. CARRY gives a function a
;;; structure to carry and gives back the function that carries it, which
;;; is the only one to use from then on; CARRIED is that structure, and
;;; NIL for a function that carries none and for what is no function. To
;;; KIND-OF such a function is what the structure is, and the printer asks
;;; PRINT-OBJECT for it as it does for the structure. STRUCTURE-SLOTS is
;;; true of the name of a structure's type, and CONDITION-PARENTS gives the
;;; types above a type of condition, or :NONE for a name that is no such
;;; type. FUNCTION-NAMED and INSTALL-FUNCTION are the function of a name,
;;; which is a symbol or (SETF symbol). PRINTED-BY-METHOD tells the printer
;;; to ask PRINT-OBJECT for the structures of a type, and PLAIN-TEXT is a
;;; structure as the printer writes it when it asks nobody, and a function
;;; that carries one as the function that it is. ADDRESS-OF is where an
;;; object lies in the heap, a number that it keeps for as long as it is
;;; there, and NIL for an integer or a character, which lie nowhere.
#+clara
(progn
  (defun kind-of (object)
    (cl::%type-of object))

  (defun carry (function structure)
    (cl::%set-function-structure function structure))

  (defun carried (object)
    (cl::%function-structure object))

  (defun address-of (object)
    (cl::%address object))

  (defun structure-slots (name)
    (get name 'cl::%structure))

  (defun condition-parents (name)
    (let ((known (get name 'cl::%condition)))
      (if known (car known) :none)))

  (defun function-symbol (name)
    (if (consp name) (cl::%setf-name (cadr name)) name))

  (defun function-named (name)
    (let ((symbol (function-symbol name)))
      (if (fboundp symbol) (symbol-function symbol))))

  (defun install-function (name function)
    (setf (symbol-function (function-symbol name)) function))

  (defun printed-by-method (name)
    (setf (get name 'cl::%printed) t))

  (defun plain-text (object)
    (let ((slots (structure-slots (kind-of object))))
      (cond ((not (and slots (get (car slots) 'cl::%printed)))
             (prin1-to-string object))
            ((functionp object)
             (format nil "#<FUNCTION ~S>" (nth-value 2 (function-lambda-expression object))))
            (t
             (let ((index -1))
               (format nil "#S(~S~A)" (car slots)
                       (apply #'concatenate 'string
                              (mapcar (lambda (slot)
                                        (setq index (1+ index))
                                        (format nil " :~A ~S" slot (cl::%structure-ref object (car slots) index)))
                                      (cdr slots))))))))))

;;; What a slot holds that has no value.
(defvar *unbound* (make-symbol "UNBOUND"))

;;; This goes up when a class is defined again. A class and a generic
;;; function remember at which count they last worked out what they keep,
;;; and work it out again when they find that the count has moved on.
(defvar *epoch* 0)

;;; The four kinds of object. The slots of an instance are in a vector of
;;; their own, in the order of LAYOUT, which is the vector of names that
;;; its class had when the values were last put in order. The structure of
;;; a generic function is what the function carries, and stays in this
;;; file: what a program is given, and gives, is the function (GENERIC-OF).
(defstruct standard-object class layout slots)

(defstruct class
  name
  kind                       ; STANDARD-CLASS, BUILT-IN-CLASS or STRUCTURE-CLASS: the name of the class of this class
  direct-superclasses        ; the classes that it was defined as a kind of, in that order
  direct-slots               ; the slots that its own definition names
  direct-default-initargs    ; (keyword function) for each of its :DEFAULT-INITARGS
  precedence-list            ; the class, and every class above it, the most specific first
  slots                      ; every slot of an instance, its own and the ones from above
  layout                     ; the names of the slots that each instance has for itself, in a vector
  shared                     ; (name . cell) for each slot that the instances have between them
  default-initargs
  initargs                   ; every keyword that fills a slot
  epoch
  accessors)                 ; (generic-function . method) for each method that its definition made

(defstruct slot
  name
  initargs
  initfunction               ; a function of no arguments for the value that it begins with, or NIL
  allocation                 ; :INSTANCE or :CLASS
  cell)                      ; of a slot that the instances share: a cons whose CAR is the value

(defstruct standard-generic-function
  name
  lambda-list
  (required 0)               ; how many arguments it has to be given,
  (optional 0)               ; and how many more it can be
  methods
  cache                      ; (classes . function): what the methods come to for arguments of those classes
  (depth 0)                  ; how many of the arguments some method cares about the class of
  particular                 ; true when some method is for one particular object
  (epoch 0)
  function)                  ; the function that is called under its name, which carries this: the generic function

(defstruct standard-method
  generic-function
  qualifiers
  specializers               ; for each required parameter a class, or (EQL object)
  lambda-list
  function
  next                       ; true when the function wants to be told which methods come after it
  keys)                      ; the keywords that it takes, T for any, NIL for none

;;; Classes

(defun find-slot (name slots)
  (dolist (slot slots)
    (if (eq (slot-name slot) name) (return slot))))

;; A class, and the classes above it, each once.
(defun classes-above (class above)
  (let ((found (list class)))
    (labels ((walk (supers)
               (dolist (super supers)
                 (unless (member super found)
                   (setq found (append found (list super)))
                   (walk (class-direct-superclasses super))))))
      (walk above))
    found))

;; The precedence list of a class that is defined as a kind of ABOVE: the
;; class and all above it, in an order in which every class comes before
;; the ones that it was defined as a kind of, and those in the order in
;; which they were written. Where that leaves a choice, the class is taken
;; that has a class below it latest in the list so far (the rule of the
;; standard, 4.3.5).
(defun precedence (class above)
  (let ((left (classes-above class above)) (order nil) (result nil))
    (dolist (one left)
      (let ((before one))
        (dolist (super (if (eq one class) above (class-direct-superclasses one)))
          (setq order (cons (cons before super) order)
                before super))))
    (loop
      (when (null left)
        (return (reverse result)))
      (let ((free (remove-if (lambda (one)
                               (some (lambda (pair) (and (eq (cdr pair) one) (member (car pair) left)))
                                     order))
                             left)))
        (when (null free)
          (error "the classes above ~S cannot be put in an order: ~S each have to come before another of them"
                 (class-name class) (mapcar #'class-name left)))
        (let ((next (car free)))
          (when (cdr free)
            (dolist (placed result)
              (let ((below (find-if (lambda (one)
                                      (member one (if (eq placed class) above (class-direct-superclasses placed))))
                                    free)))
                (when below
                  (setq next below)
                  (return)))))
          (setq result (cons next result)
                left (remove next left)))))))

(defun same-names-p (names layout)
  (and layout
       (= (length names) (length layout))
       (let ((index 0))
         (dolist (name names t)
           (unless (eq name (svref layout index)) (return nil))
           (setq index (1+ index))))))

;; What an instance of a class holds, put together from the slots of the
;; class and of every class above it: a slot of one name is one slot,
;; which takes its kind and its first value from the most specific class
;; that says them, and can be filled by the keywords of them all.
(defun lay-out (class)
  (let ((slots nil) (defaults nil) (names nil) (shared nil) (initargs nil))
    (dolist (above (class-precedence-list class))
      (dolist (direct (class-direct-slots above))
        (let ((known (find-slot (slot-name direct) slots)))
          (cond ((null known)
                 (setq slots (append slots (list (copy-slot direct)))))
                (t
                 (dolist (initarg (slot-initargs direct))
                   (unless (member initarg (slot-initargs known))
                     (setf (slot-initargs known) (append (slot-initargs known) (list initarg)))))
                 (unless (slot-initfunction known)
                   (setf (slot-initfunction known) (slot-initfunction direct)))))))
      (dolist (default (class-direct-default-initargs above))
        (unless (assoc (car default) defaults)
          (setq defaults (append defaults (list default))))))
    (dolist (slot slots)
      (if (eq (slot-allocation slot) :class)
          (setq shared (cons (cons (slot-name slot) (slot-cell slot)) shared))
          (setq names (append names (list (slot-name slot)))))
      (dolist (initarg (slot-initargs slot))
        (unless (member initarg initargs)
          (setq initargs (cons initarg initargs)))))
    (setf (class-slots class) slots
          (class-default-initargs class) defaults
          (class-shared class) shared
          (class-initargs class) initargs)
    (unless (same-names-p names (class-layout class))
      (let ((layout (make-array (length names) :initial-element nil)) (index 0))
        (dolist (name names)
          (setf (svref layout index) name)
          (setq index (1+ index)))
        (setf (class-layout class) layout)))))

(defun finalize (class)
  (setf (class-precedence-list class) (precedence class (class-direct-superclasses class)))
  (when (eq (class-kind class) 'standard-class)
    (lay-out class))
  (setf (class-epoch class) *epoch*)
  class)

;; The class, with what it keeps worked out as the classes are now.
(defun fresh (class)
  (if (eq (class-epoch class) *epoch*)
      class
      (finalize class)))

(defun define-class (name kind superclasses)
  (let ((class (make-class :name name :kind kind :direct-superclasses superclasses)))
    (finalize class)
    (setf (get name 'class) class)
    class))

;; A structure's type and a type of condition are classes too, which are
;; made when they are first asked for.
(defun implied-class (name)
  (let ((parents (condition-parents name)))
    (cond ((structure-slots name)
           (define-class name 'structure-class (list (find-class 'structure-object))))
          ((listp parents)
           (define-class name 'built-in-class (if parents (mapcar #'find-class parents) (list (find-class 't)))))
          (t nil))))

(defun find-class (name &optional (errorp t))
  (or (and (symbolp name)
           (or (get name 'class) (implied-class name)))
      (if errorp
          (error "there is no class named ~S" name))))

;; The class of what is no instance of a class that DEFCLASS defined,
;; from what the substrate says it is. An integer is a FIXNUM: the
;; substrate says INTEGER of every one, and there are no larger integers
;; yet, which would be of another class below INTEGER.
(defun class-of-kind (kind object)
  (cond ((eq kind 'class) (find-class (class-kind object)))
        ((eq kind 'integer) (get 'fixnum 'class))
        (t (or (get kind 'class) (implied-class kind) (find-class 't)))))

(defun class-of (object)
  (let ((kind (kind-of object)))
    (if (eq kind 'standard-object)
        (standard-object-class object)
        (class-of-kind kind object))))

(defun subclass-p (class other)
  (if (member other (class-precedence-list (fresh class))) t nil))

;;; The classes that the language begins with.
(define-class 't 'built-in-class nil)
(define-class 'standard-object 'standard-class (list (find-class 't)))
(dolist (row '((structure-object t)
               (number t) (real number) (rational real) (integer rational) (fixnum integer)
               (character t) (symbol t)
               (sequence t) (list sequence) (cons list) (null symbol list)
               (array t) (vector array sequence) (string vector)
               (function t) (package t) (stream t)
               (class standard-object) (standard-class class) (built-in-class class) (structure-class class)
               (generic-function function) (standard-generic-function generic-function)
               (method t) (standard-method method)))
  (define-class (car row) 'built-in-class (mapcar #'find-class (cdr row))))

#+clara
(progn
  ;; A stream is a structure of lisp/boot.lisp's.
  (setf (get 'cl::%stream 'class) (find-class 'stream))
  (dolist (name '(standard-object class standard-generic-function standard-method))
    (printed-by-method name)))

;;; Types
;;;
;;; A class is a type, and so is the name of one. TYPEP knows those, a few
;;; names that are types and no classes, and the types that are put
;;; together of others.

(defun typep (object type)
  (cond ((class-p type) (subclass-p (class-of object) type))
        ((symbolp type)
         (case type
           ((t) t)
           ((nil) nil)
           (atom (atom object))
           (keyword (keywordp object))
           (boolean (if (or (eq object t) (null object)) t nil))
           (t (subclass-p (class-of object) (find-class type)))))
        ((consp type)
         (case (car type)
           (or (if (some (lambda (one) (typep object one)) (cdr type)) t nil))
           (and (every (lambda (one) (typep object one)) (cdr type)))
           (not (not (typep object (cadr type))))
           (member (if (member object (cdr type)) t nil))
           (eql (eql object (cadr type)))
           (satisfies (if (funcall (cadr type) object) t nil))
           (t (error "TYPEP does not know the type ~S yet" type))))
        (t (error "~S is not the name of a type" type))))

(defun type-of (object)
  (class-name (class-of object)))

(defun type-clauses (value clauses)
  (mapcar (lambda (clause)
            (cons (if (or (eq (car clause) t) (eq (car clause) 'otherwise))
                      t
                      `(typep ,value ',(car clause)))
                  (or (cdr clause) '(nil))))
          clauses))

(defmacro typecase (key &rest clauses)
  (let ((value (gensym)))
    `(let ((,value ,key))
       (cond ,@(type-clauses value clauses)))))

(defmacro etypecase (key &rest clauses)
  (let ((value (gensym)))
    `(let ((,value ,key))
       (cond ,@(type-clauses value clauses)
             (t (error "~S fell through an ETYPECASE form" ,value))))))

;;; Instances and their slots

(defun allocate (class)
  (let ((layout (class-layout class)))
    (make-standard-object :class class :layout layout
                          :slots (make-array (length layout) :initial-element *unbound*))))

(defun index-of (layout name)
  (let ((count (length layout)) (index 0))
    (loop
      (cond ((= index count) (return nil))
            ((eq (svref layout index) name) (return index)))
      (setq index (1+ index)))))

;; An instance whose class was defined again since its slots were put in
;; order gets the slots that the class has now: the ones that it had keep
;; their values, the ones that are gone are dropped, and the new ones
;; begin as the class says a slot begins.
(defun bring-up (instance class)
  (let* ((old (standard-object-layout instance))
         (values (standard-object-slots instance))
         (new (class-layout class))
         (slots (make-array (length new) :initial-element *unbound*))
         (added nil))
    (dotimes (index (length new))
      (let* ((name (svref new index)) (was (index-of old name)))
        (if was
            (setf (svref slots index) (svref values was))
            (setq added (cons name added)))))
    (setf (standard-object-slots instance) slots
          (standard-object-layout instance) new)
    (when added
      (shared-initialize instance added))
    instance))

;; The class of an instance, once the instance has the slots of that class.
(defun current (instance)
  (let ((class (fresh (standard-object-class instance))))
    (unless (eq (standard-object-layout instance) (class-layout class))
      (bring-up instance class))
    class))

;; The class of an argument that a generic function is called with. An
;; instance is brought up to its class as it is now before any method sees
;; it: a class can be defined again twice between two looks at a slot, and
;; a slot that the first of those took away is gone, whatever the second
;; one says.
(defun class-in-call (object)
  (let ((kind (kind-of object)))
    (if (eq kind 'standard-object)
        (current object)
        (class-of-kind kind object))))

(defun slot-value (object name)
  (if (standard-object-p object)
      (let* ((class (current object))
             (index (index-of (standard-object-layout object) name))
             (cell (if index nil (assoc name (class-shared class))))
             (value (cond (index (svref (standard-object-slots object) index))
                          (cell (car (cdr cell))))))
        (cond ((and (null index) (null cell))
               (values (slot-missing class object name 'slot-value)))
              ((eq value *unbound*)
               (values (slot-unbound class object name)))
              (t value)))
      (values (slot-missing (class-of object) object name 'slot-value))))

(defun set-slot-value (object name value)
  (if (standard-object-p object)
      (let* ((class (current object))
             (index (index-of (standard-object-layout object) name))
             (cell (if index nil (assoc name (class-shared class)))))
        (cond (index (setf (svref (standard-object-slots object) index) value))
              (cell (setf (car (cdr cell)) value))
              (t (slot-missing class object name 'setf value))))
      (slot-missing (class-of object) object name 'setf value))
  value)

(defsetf slot-value set-slot-value)

(defun slot-boundp (object name)
  (if (standard-object-p object)
      (let* ((class (current object))
             (index (index-of (standard-object-layout object) name))
             (cell (if index nil (assoc name (class-shared class)))))
        (cond (index (not (eq (svref (standard-object-slots object) index) *unbound*)))
              (cell (not (eq (car (cdr cell)) *unbound*)))
              (t (if (slot-missing class object name 'slot-boundp) t nil))))
      (if (slot-missing (class-of object) object name 'slot-boundp) t nil)))

(defun slot-makunbound (object name)
  (if (standard-object-p object)
      (let* ((class (current object))
             (index (index-of (standard-object-layout object) name))
             (cell (if index nil (assoc name (class-shared class)))))
        (cond (index (setf (svref (standard-object-slots object) index) *unbound*))
              (cell (setf (car (cdr cell)) *unbound*))
              (t (slot-missing class object name 'slot-makunbound))))
      (slot-missing (class-of object) object name 'slot-makunbound))
  object)

(defun slot-exists-p (object name)
  (and (standard-object-p object)
       (let ((class (current object)))
         (if (or (index-of (standard-object-layout object) name) (assoc name (class-shared class))) t nil))))

(defmacro with-slots (slots instance &body body)
  (let ((object (gensym)))
    `(let ((,object ,instance))
       (symbol-macrolet ,(mapcar (lambda (slot)
                                   (if (consp slot)
                                       `(,(car slot) (slot-value ,object ',(cadr slot)))
                                       `(,slot (slot-value ,object ',slot))))
                                 slots)
         ,@body))))

(defmacro with-accessors (accessors instance &body body)
  (let ((object (gensym)))
    `(let ((,object ,instance))
       (symbol-macrolet ,(mapcar (lambda (accessor)
                                   `(,(car accessor) (,(cadr accessor) ,object)))
                                 accessors)
         ,@body))))

;; The rest of a list of keywords and values from the first keyword on
;; that is one of KEYS.
(defun first-supplied (keys initargs)
  (do ((rest initargs (cddr rest))) ((null rest) nil)
    (if (member (car rest) keys) (return rest))))

;; What SHARED-INITIALIZE does when no method says otherwise: a slot gets
;; the value of the first keyword among the arguments that fills it; one
;; that is left without a value, and that NAMES has, T standing for every
;; slot, gets the value that its class says it begins with. A slot that the
;; instances share got that value when the class was defined, and gets it
;; at no other time.
(defun fill-slots (instance names initargs)
  (dolist (slot (class-slots (current instance)))
    (let* ((name (slot-name slot))
           (given (first-supplied (slot-initargs slot) initargs)))
      (cond (given
             (set-slot-value instance name (cadr given)))
            ((and (slot-initfunction slot)
                  (eq (slot-allocation slot) :instance)
                  (or (eq names t) (member name names))
                  (not (slot-boundp instance name)))
             (set-slot-value instance name (funcall (slot-initfunction slot)))))))
  instance)

;;; Generic functions

;; How many parameters a lambda list has that must get an argument, and
;; how many more that can.
(defun parameter-counts (lambda-list)
  (let ((required 0) (optional 0) (stage 0))
    (dolist (parameter lambda-list)
      (cond ((eq parameter '&optional) (setq stage 1))
            ((member parameter '(&rest &body &key &aux &allow-other-keys)) (setq stage 2))
            ((= stage 0) (setq required (1+ required)))
            ((= stage 1) (setq optional (1+ optional)))))
    (list required optional)))

;; The keywords that a lambda list takes: T for any.
(defun parameter-keys (lambda-list)
  (let ((keys nil) (stage 0))
    (dolist (parameter lambda-list)
      (cond ((eq parameter '&key) (setq stage 1))
            ((eq parameter '&allow-other-keys) (setq keys t))
            ((eq parameter '&aux) (setq stage 2))
            ((and (= stage 1) (listp keys))
             (let ((spec (if (consp parameter) (car parameter) parameter)))
               (setq keys (cons (if (consp spec)
                                    (car spec)
                                    (intern (symbol-name spec) (find-package "KEYWORD")))
                                keys))))))
    keys))

;; A name that the system has a function for cannot become a generic
;; function: CAR stays what it is.
(defun system-name-p (name)
  (let* ((symbol (if (consp name) (cadr name) name))
         (package (symbol-package symbol))
         (title (if package (package-name package) "")))
    (or (string= title "COMMON-LISP")
        (string= title "KEYWORD")
        (and (>= (length title) 5) (string= (subseq title 0 5) "CLARA")))))

;; What a generic function keeps, from the function that it is, and NIL
;; for an object that is no generic function. (The structure itself is
;; taken too: it is of the same class, and it must not be what stops the
;; printer, which could come to one in the slot of a method.)
(defun generic-of (object)
  (if (standard-generic-function-p object)
      object
      (let ((kept (carried object)))
        (if (standard-generic-function-p kept) kept))))

;; The same for a generic function that a program hands over, which has
;; to be one.
(defun kept-by (generic)
  (or (generic-of generic)
      (error "~S is not a generic function" generic)))

;; The generic function of a name, as what it keeps: the function of the
;; name has to be one. A name that DEFUN has since given another function
;; has none.
(defun generic-named (name)
  (generic-of (function-named name)))

(defun ensure-generic (name lambda-list maker explicit)
  (let ((generic (generic-named name)) (counts (parameter-counts lambda-list)))
    (cond ((null generic)
           (when (and (function-named name) (system-name-p name))
             (error "~S is a function of the system's, and cannot be made a generic function" name))
           (setq generic (make-standard-generic-function :name name :lambda-list lambda-list
                                                         :required (car counts) :optional (cadr counts)))
           (setf (standard-generic-function-function generic) (carry (funcall maker generic) generic))
           (install-function name (standard-generic-function-function generic)))
          (explicit
           (when (and (standard-generic-function-methods generic)
                      (not (and (= (car counts) (standard-generic-function-required generic))
                                (= (cadr counts) (standard-generic-function-optional generic)))))
             (error "~S has methods with the parameters ~S, and cannot be given ~S"
                    name (standard-generic-function-lambda-list generic) lambda-list))
           (setf (standard-generic-function-lambda-list generic) lambda-list
                 (standard-generic-function-required generic) (car counts)
                 (standard-generic-function-optional generic) (cadr counts))))
    generic))

;; What a generic function keeps is worked out again when its methods
;; change: how many of its arguments any method looks at the class of, and
;; whether one looks at the object itself.
(defun tune (generic)
  (let ((depth 0) (particular nil) (top (find-class 't)))
    (dolist (method (standard-generic-function-methods generic))
      (let ((place 0))
        (dolist (specializer (standard-method-specializers method))
          (setq place (1+ place))
          (cond ((consp specializer)
                 (setq particular t)
                 (if (> place depth) (setq depth place)))
                ((not (eq specializer top))
                 (if (> place depth) (setq depth place)))))))
    (setf (standard-generic-function-depth generic) depth
          (standard-generic-function-particular generic) particular
          (standard-generic-function-cache generic) nil)
    generic))

(defun specializer-of (specializer)
  (cond ((class-p specializer) specializer)
        ((symbolp specializer) (find-class specializer))
        ((and (consp specializer) (eq (car specializer) 'eql)) specializer)
        (t (error "~S does not say which arguments a method is for: a class does, and (EQL object)" specializer))))

(defun same-specializers-p (some others)
  (do ((some some (cdr some)) (others others (cdr others)))
      ((or (null some) (null others)) (and (null some) (null others)))
    (unless (if (consp (car some))
                (and (consp (car others)) (eql (cadr (car some)) (cadr (car others))))
                (eq (car some) (car others)))
      (return nil))))

(defun define-method (name qualifiers lambda-list specializers function next maker)
  (let* ((generic (ensure-generic name lambda-list maker nil))
         (counts (parameter-counts lambda-list)))
    (unless (and (= (car counts) (standard-generic-function-required generic))
                 (= (cadr counts) (standard-generic-function-optional generic)))
      (error "a method of ~S with the parameters ~S: the generic function has ~S"
             name lambda-list (standard-generic-function-lambda-list generic)))
    (when (or (cdr qualifiers)
              (and qualifiers (not (member (car qualifiers) '(:before :after :around)))))
      (error "a method of ~S with ~S before its parameters: it can be :BEFORE, :AFTER or :AROUND"
             name qualifiers))
    (let* ((specializers (mapcar #'specializer-of specializers))
           (method (make-standard-method :generic-function generic :qualifiers qualifiers
                                         :specializers specializers :lambda-list lambda-list
                                         :function function :next next
                                         :keys (parameter-keys lambda-list))))
      (setf (standard-generic-function-methods generic)
            (cons method
                  (remove-if (lambda (other)
                               (and (equal (standard-method-qualifiers other) qualifiers)
                                    (same-specializers-p (standard-method-specializers other) specializers)))
                             (standard-generic-function-methods generic))))
      (tune generic)
      (when (and (eq name 'print-object) (class-p (car specializers))
                 (eq (class-kind (car specializers)) 'structure-class))
        (printed-by-method (class-name (car specializers))))
      method)))

;; The methods of a generic function that fit some arguments, the most
;; specific first. A method fits when each argument that has to be there
;; is of the class that the method names for it, or is the very object.
;; Of two that fit, the one comes first whose class for the first argument
;; in which they differ comes first in the precedence list of that
;; argument's class; and a method for the object itself before any.
(defun more-specific-p (one other lists)
  (do ((some (standard-method-specializers one) (cdr some))
       (others (standard-method-specializers other) (cdr others))
       (lists lists (cdr lists)))
      ((null some) nil)
    (let ((mine (car some)) (theirs (car others)))
      (cond ((consp mine)
             (unless (consp theirs) (return t)))
            ((consp theirs)
             (return nil))
            ((not (eq mine theirs))
             (return (if (member theirs (cdr (member mine (car lists)))) t nil)))))))

(defun applicable (generic arguments)
  (let ((lists nil) (rest arguments))
    (dotimes (index (standard-generic-function-required generic))
      (when (null rest)
        (error "~S was called with ~S arguments, and takes ~S at the least"
               (standard-generic-function-name generic) (length arguments)
               (standard-generic-function-required generic)))
      (setq lists (cons (class-precedence-list (fresh (class-in-call (car rest)))) lists)
            rest (cdr rest)))
    (setq lists (reverse lists))
    ;; SORT may use up the list that it is given, and under SBCL it does: so it gets one of its own
    (sort (copy-list
           (remove-if-not (lambda (method)
                            (do ((specializers (standard-method-specializers method) (cdr specializers))
                                 (lists lists (cdr lists))
                                 (rest arguments (cdr rest)))
                                ((null specializers) t)
                              (unless (if (consp (car specializers))
                                          (eql (car rest) (cadr (car specializers)))
                                          (member (car specializers) (car lists)))
                                (return nil))))
                          (standard-generic-function-methods generic)))
          (lambda (one other) (more-specific-p one other lists)))))

;; A method is called with the arguments, and one that asks for the next
;; method with two things before them: the arguments in a list, and the
;; chain that it is the first of, the methods that come after it being
;; the rest. A function in a chain stands for all that is left to do when
;; the methods before it have called on.
(defun call-chain (chain arguments)
  (let ((first (car chain)))
    (cond ((functionp first) (funcall first arguments))
          ((standard-method-next first) (apply (standard-method-function first) arguments chain arguments))
          (t (apply (standard-method-function first) arguments)))))

(defun call-next (chain arguments)
  (if (cdr chain)
      (call-chain (cdr chain) arguments)
      (apply #'no-next-method (standard-generic-function-function (standard-method-generic-function (car chain)))
             (car chain) arguments)))

;; What the methods that fit come to, as one function of the arguments in
;; a list: the :AROUND methods first, the most specific outermost; and when
;; the last of them calls on, or when there is none, the :BEFORE methods,
;; the most specific first, then the most specific method without a word
;; before its parameters, which gives the values and can call on the next
;; such method, and then the :AFTER methods, the most specific last.
(defun effective (generic arguments)
  (let ((around nil) (before nil) (primary nil) (after nil))
    (dolist (method (applicable generic arguments))
      (let ((qualifier (car (standard-method-qualifiers method))))
        (cond ((eq qualifier :around) (setq around (cons method around)))
              ((eq qualifier :before) (setq before (cons (list method) before)))
              ((eq qualifier :after) (setq after (cons (list method) after)))
              (t (setq primary (cons method primary))))))
    (setq around (reverse around) before (reverse before) primary (reverse primary))
    (cond ((and (null primary) (null around) (null before) (null after))
           (lambda (arguments)
             (apply #'no-applicable-method (standard-generic-function-function generic) arguments)))
          ((null primary)
           (lambda (arguments)
             (error "~S has no method for the arguments ~S that gives a value: the ones that fit are ~S"
                    (standard-generic-function-name generic) arguments
                    (if around :around (if before :before :after)))))
          (t
           (let ((inner (cond ((or before after)
                               (lambda (arguments)
                                 (dolist (chain before) (call-chain chain arguments))
                                 (multiple-value-prog1 (call-chain primary arguments)
                                   (dolist (chain after) (call-chain chain arguments)))))
                              ((or (cdr primary) (standard-method-next (car primary)))
                               (lambda (arguments) (call-chain primary arguments)))
                              (t
                               (let ((function (standard-method-function (car primary))))
                                 (lambda (arguments) (apply function arguments)))))))
             (if around
                 (let ((chain (append around (list inner))))
                   (lambda (arguments) (call-chain chain arguments)))
                 inner))))))

(defun classes-of (generic arguments depth)
  (let ((classes nil) (rest arguments))
    (dotimes (index depth)
      (when (null rest)
        (error "~S was called with ~S arguments, and takes ~S at the least"
               (standard-generic-function-name generic) (length arguments)
               (standard-generic-function-required generic)))
      (setq classes (cons (class-in-call (car rest)) classes)
            rest (cdr rest)))
    classes))

(defun same-classes-p (some others)
  (loop
    (cond ((null some) (return t))
          ((not (eq (car some) (car others))) (return nil)))
    (setq some (cdr some) others (cdr others))))

;; A call of a generic function. What the methods come to for the classes
;; of these arguments is kept, so the second call for such arguments looks
;; it up; nothing is kept for a generic function with a method for one
;; particular object.
(defun dispatch (generic arguments)
  (unless (eq (standard-generic-function-epoch generic) *epoch*)
    (setf (standard-generic-function-cache generic) nil
          (standard-generic-function-epoch generic) *epoch*))
  (if (standard-generic-function-particular generic)
      (funcall (effective generic arguments) arguments)
      (let ((depth (standard-generic-function-depth generic)))
        (if (and (= depth 1) arguments)
            (let ((class (class-in-call (car arguments))) (rest (standard-generic-function-cache generic)))
              (loop
                (cond ((null rest)
                       (let ((function (effective generic arguments)))
                         (setf (standard-generic-function-cache generic)
                               (cons (cons class function) (standard-generic-function-cache generic)))
                         (return (funcall function arguments))))
                      ((eq (car (car rest)) class)
                       (return (funcall (cdr (car rest)) arguments))))
                (setq rest (cdr rest))))
            (let ((classes (classes-of generic arguments depth)) (rest (standard-generic-function-cache generic)))
              (loop
                (cond ((null rest)
                       (let ((function (effective generic arguments)))
                         (setf (standard-generic-function-cache generic)
                               (cons (cons classes function) (standard-generic-function-cache generic)))
                         (return (funcall function arguments))))
                      ((same-classes-p (car (car rest)) classes)
                       (return (funcall (cdr (car rest)) arguments))))
                (setq rest (cdr rest))))))))

;;; The forms that define

;; The function that a generic function is, as a form: it is given what
;; the generic function keeps and makes a function of the name that hands
;; the arguments on, a new one at every call, which ENSURE-GENERIC then
;; has carry what it was given.
(defun maker-form (name)
  (let ((own (if (consp name) (make-symbol (format nil "(SETF ~A)" (cadr name))) name))
        (generic (gensym)) (arguments (gensym)))
    `(lambda (,generic)
       (flet ((,own (&rest ,arguments) (dispatch ,generic ,arguments)))
         (function ,own)))))

(defun mentions-p (tree name)
  (cond ((eq tree name) t)
        ((consp tree) (or (mentions-p (car tree) name) (mentions-p (cdr tree) name)))
        (t nil)))

;; A lambda list whose keywords do not have to be the only ones: a method
;; is given the arguments that the other methods take too.
(defun open-keys (lambda-list)
  (if (and (member '&key lambda-list) (not (member '&allow-other-keys lambda-list)))
      (let ((aux (member '&aux lambda-list)) (before nil))
        (do ((rest lambda-list (cdr rest))) ((eq rest aux))
          (setq before (cons (car rest) before)))
        (append (reverse before) '(&allow-other-keys) aux))
      lambda-list))

;; The parameters of a method as they are written, taken apart: the lambda
;; list of its function, and for each parameter that must get an argument
;; a form for what the method is for there.
(defun parse-parameters (parameters)
  (let ((names nil) (specializers nil) (rest parameters))
    (loop
      (when (or (atom rest) (member (car rest) '(&optional &rest &body &key &aux &allow-other-keys)))
        (return))
      (let ((parameter (car rest)))
        (cond ((consp parameter)
               (setq names (cons (car parameter) names)
                     specializers (cons (let ((specializer (cadr parameter)))
                                          (if (and (consp specializer) (eq (car specializer) 'eql))
                                              `(list 'eql ,(cadr specializer))
                                              `',specializer))
                                        specializers)))
              (t (setq names (cons parameter names)
                       specializers (cons ''t specializers)))))
      (setq rest (cdr rest)))
    (values (append (reverse names) rest) (reverse specializers))))

;; The function of a method, as a form, and whether it wants to be told
;; what comes after it: it does when its body names CALL-NEXT-METHOD or
;; NEXT-METHOD-P.
(defun method-lambda (name lambda-list body)
  (let ((declarations nil) (rest body))
    (loop
      (cond ((and (stringp (car rest)) (cdr rest))
             (setq rest (cdr rest)))
            ((and (consp (car rest)) (eq (car (car rest)) 'declare))
             (setq declarations (append declarations (list (car rest)))
                   rest (cdr rest)))
            (t (return))))
    (let ((inner `(block ,(if (consp name) (cadr name) name) ,@rest))
          (parameters (open-keys lambda-list)))
      (if (or (mentions-p rest 'call-next-method) (mentions-p rest 'next-method-p))
          (let ((arguments (gensym)) (chain (gensym)) (again (gensym)))
            (values `(lambda (,arguments ,chain ,@parameters)
                       ,@declarations
                       (flet ((call-next-method (&rest ,again) (call-next ,chain (or ,again ,arguments)))
                              (next-method-p () (if (cdr ,chain) t nil)))
                         ,inner))
                    t))
          (values `(lambda ,parameters ,@declarations ,inner) nil)))))

(defmacro defmethod (name &rest rest)
  (let ((qualifiers nil))
    (loop
      (when (or (null rest) (listp (car rest)))
        (return))
      (setq qualifiers (cons (car rest) qualifiers)
            rest (cdr rest)))
    (when (null rest)
      (error "DEFMETHOD of ~S without its parameters" name))
    (multiple-value-bind (lambda-list specializers) (parse-parameters (car rest))
      (multiple-value-bind (function next) (method-lambda name lambda-list (cdr rest))
        `(define-method ',name ',(reverse qualifiers) ',lambda-list (list ,@specializers)
                        ,function ,next ,(maker-form name))))))

(defmacro defgeneric (name lambda-list &rest options)
  (let ((methods nil))
    (dolist (option options)
      (cond ((and (consp option) (eq (car option) :method))
             (setq methods (append methods (list `(defmethod ,name ,@(cdr option))))))
            ((and (consp option) (member (car option) '(:documentation declare))))
            ((and (consp option) (eq (car option) :method-combination) (symbolp (cadr option))
                  (string= (symbol-name (cadr option)) "STANDARD") (null (cddr option))))
            (t (error "DEFGENERIC with ~S, which is not here yet" option))))
    `(progn
       (ensure-generic ',name ',lambda-list ,(maker-form name) t)
       ,@methods
       (function-named ',name))))

;; A slot as DEFCLASS writes it, a name or (name option value...): the
;; form that makes what is kept of it, and the forms for the functions
;; that read it and write it.
(defun slot-form (slot)
  (let ((name (if (consp slot) (car slot) slot)) (initargs nil) (initform nil) (allocation :instance))
    (do ((options (if (consp slot) (cdr slot)) (cddr options))) ((null options))
      (case (car options)
        (:initarg (setq initargs (append initargs (list (cadr options)))))
        (:initform (setq initform `(lambda () ,(cadr options))))
        (:allocation
         (unless (member (cadr options) '(:instance :class))
           (error "DEFCLASS: a slot is kept by each :INSTANCE or by the :CLASS, and not by ~S" (cadr options)))
         (setq allocation (cadr options)))
        ((:reader :writer :accessor :type :documentation))
        (t (error "DEFCLASS with the slot option ~S, which is not here yet" (car options)))))
    `(list ',name ',initargs ,initform ,allocation)))

(defun accessor-forms (slot)
  (let ((forms nil) (object (gensym)) (value (gensym)))
    (do ((options (if (consp slot) (cdr slot)) (cddr options))) ((null options) (reverse forms))
      (let ((name (cadr options)))
        (when (member (car options) '(:reader :accessor))
          (setq forms (cons `(list ',name :reader
                                   (lambda (,object) (slot-value ,object ',(car slot)))
                                   ,(maker-form name))
                            forms)))
        (when (member (car options) '(:writer :accessor))
          (let ((name (if (eq (car options) :writer) name (list 'setf name))))
            (setq forms (cons `(list ',name :writer
                                     (lambda (,value ,object) (set-slot-value ,object ',(car slot) ,value))
                                     ,(maker-form name))
                              forms))))))))

(defmacro defclass (name superclasses slots &rest options)
  (let ((defaults nil))
    (dolist (option options)
      (cond ((and (consp option) (eq (car option) :default-initargs))
             (do ((rest (cdr option) (cddr rest))) ((null rest))
               (setq defaults (append defaults (list `(list ,(car rest) (lambda () ,(cadr rest))))))))
            ((and (consp option) (eq (car option) :documentation)))
            (t (error "DEFCLASS with ~S, which is not here yet" option))))
    `(ensure-class ',name ',superclasses
                   (list ,@(mapcar #'slot-form slots))
                   (list ,@defaults)
                   (list ,@(mapcan #'accessor-forms slots)))))

;; The methods that the definition of a class made for its slots go when
;; the class is defined again: the new definition makes its own.
(defun forget-accessors (class)
  (dolist (pair (class-accessors class))
    (let ((generic (car pair)))
      (setf (standard-generic-function-methods generic)
            (remove (cdr pair) (standard-generic-function-methods generic)))
      (tune generic)))
  (setf (class-accessors class) nil))

(defun ensure-class (name superclasses slots defaults accessors)
  (let ((class (find-class name nil))
        (above (mapcar #'find-class (or superclasses '(standard-object)))))
    (unless (and name (symbolp name))
      (error "~S cannot be the name of a class" name))
    (dolist (super above)
      (unless (eq (class-kind super) 'standard-class)
        (error "~S cannot be defined as a kind of ~S: only a class that DEFCLASS defined can have a class below it"
               name (class-name super))))
    (when (and class (not (eq (class-kind class) 'standard-class)))
      (error "~S is a class already, and not one that DEFCLASS defined: it cannot be defined again" name))
    (let ((new (or class (make-class :name name :kind 'standard-class))))
      ;; before anything is changed: the order of the classes above, which may not be there to be had
      (precedence new above)
      (when class
        (forget-accessors class)
        (setq *epoch* (1+ *epoch*)))
      (setf (class-direct-superclasses new) above
            (class-direct-slots new)
            (mapcar (lambda (slot)
                      (let* ((was (find-slot (car slot) (class-direct-slots new)))
                             (cell (if (eq (cadddr slot) :class)
                                       (or (and was (slot-cell was)) (list *unbound*)))))
                        (when (and cell (caddr slot) (eq (car cell) *unbound*))
                          (setf (car cell) (funcall (caddr slot))))
                        (make-slot :name (car slot) :initargs (cadr slot) :initfunction (caddr slot)
                                   :allocation (cadddr slot) :cell cell)))
                    slots)
            (class-direct-default-initargs new) defaults)
      (finalize new)
      (setf (get name 'class) new)
      (dolist (accessor accessors)
        (let ((method (if (eq (cadr accessor) :reader)
                          (define-method (car accessor) nil '(object) (list new)
                                         (caddr accessor) nil (cadddr accessor))
                          (define-method (car accessor) nil '(value object) (list (find-class 't) new)
                                         (caddr accessor) nil (cadddr accessor)))))
          (setf (class-accessors new)
                (cons (cons (standard-method-generic-function method) method) (class-accessors new)))))
      new)))

;;; What the language itself defines with them

(define-condition unbound-slot (cell-error simple-condition)
  ((instance :initarg :instance :reader unbound-slot-instance)))

(defgeneric slot-unbound (class instance name))

(defmethod slot-unbound (class instance name)
  (declare (ignore class))
  (error 'unbound-slot :name name :instance instance
                       :format-control "the slot ~S of ~S has no value"
                       :format-arguments (list name instance)))

(defgeneric slot-missing (class instance name operation &optional value))

(defmethod slot-missing (class instance name operation &optional value)
  (declare (ignore class operation value))
  (error "~S has no slot named ~S" instance name))

(defgeneric no-applicable-method (generic &rest arguments))

(defmethod no-applicable-method (generic &rest arguments)
  (error "~S has no method for the arguments ~S" (standard-generic-function-name (kept-by generic)) arguments))

(defgeneric no-next-method (generic method &rest arguments))

(defmethod no-next-method (generic method &rest arguments)
  (declare (ignore method))
  (error "~S has no next method for the arguments ~S" (standard-generic-function-name (kept-by generic)) arguments))

(defgeneric shared-initialize (instance names &rest initargs))

(defmethod shared-initialize (instance names &rest initargs)
  (fill-slots instance names initargs))

(defgeneric initialize-instance (instance &rest initargs))

(defmethod initialize-instance (instance &rest initargs)
  (apply #'shared-initialize instance t initargs))

;; The keywords that the methods take which a new instance of a class goes
;; through: T for any.
(defun method-keys (instance)
  (let ((keys nil))
    (dolist (method (append (applicable (generic-named 'initialize-instance) (list instance))
                            (applicable (generic-named 'shared-initialize) (list instance t))))
      (cond ((eq (standard-method-keys method) t) (return-from method-keys t))
            (t (setq keys (append (standard-method-keys method) keys)))))
    keys))

;; An argument that fills no slot and that no method takes is a mistake,
;; a keyword that was typed wrongly more often than not.
(defun check-initargs (class instance initargs)
  (let ((more :unasked))
    (do ((rest initargs (cddr rest))) ((null rest))
      (when (null (cdr rest))
        (error "an instance of ~S is made with keywords and values in turn, and ~S has no value"
               (class-name class) (car rest)))
      (unless (or (member (car rest) (class-initargs class)) (eq (car rest) :allow-other-keys))
        (when (eq more :unasked)
          (setq more (if (getf initargs :allow-other-keys) t (method-keys instance))))
        (unless (or (eq more t) (member (car rest) more))
          (error "an instance of ~S cannot be made with ~S: no slot is filled by it, and no method takes it"
                 (class-name class) (car rest)))))))

(defun with-defaults (class initargs)
  (let ((more nil))
    (dolist (default (class-default-initargs class))
      (unless (first-supplied (list (car default)) initargs)
        (setq more (append more (list (car default) (funcall (cadr default)))))))
    (append initargs more)))

(defun make-instance (class &rest initargs)
  (let ((class (fresh (if (symbolp class) (find-class class) class))))
    (unless (eq (class-kind class) 'standard-class)
      (error "MAKE-INSTANCE makes an instance of a class that DEFCLASS defined, and ~S is not one"
             (class-name class)))
    (let ((initargs (with-defaults class initargs))
          (instance (allocate class)))
      (check-initargs class instance initargs)
      (apply #'initialize-instance instance initargs)
      instance)))

(defgeneric reinitialize-instance (instance &rest initargs))

(defmethod reinitialize-instance (instance &rest initargs)
  (check-initargs (current instance) instance initargs)
  (apply #'shared-initialize instance nil initargs))

;;; Printing
;;;
;;; An instance is written by PRINT-OBJECT, which is given the object and
;;; a stream. The printer, which is in C, asks for the text of every
;;; instance that it comes to, wherever in a list (kernel/lisp/builtin.c).
;;; With no method of its class's own an instance is written as the name of
;;; its class and its address, #<ACCOUNT {40000012A458}>: two instances of
;;; a class never show the same text, and one shows the same text every
;;; time.

;; What tells an object from every other that is there: its address, in
;; hexadecimal between braces, {40000012A458}, the way SBCL writes one. It
;; is the last thing before the > and has a space before it when something
;; was written there. An integer or a character has no address and gets
;; nothing. The digits are made here: FORMAT's ~X is in a file that is
;; loaded after this one.
(defun write-identity (object stream space)
  (let ((address (address-of object)) (digits nil))
    (when address
      (do ((left address (floor left 16))) ((< left 16) (push left digits))
        (push (mod left 16) digits))
      (write-string (if space " {" "{") stream)
      (dolist (digit digits)
        (write-char (char "0123456789ABCDEF" digit) stream))
      (write-string "}" stream))))

(defmacro print-unreadable-object ((object stream &key type identity) &body body)
  (let ((thing (gensym)) (to (gensym)) (typed (gensym)) (told-apart (gensym)))
    `(let ((,thing ,object) (,to ,stream) (,typed ,type) (,told-apart ,identity))
       (write-string "#<" ,to)
       (when ,typed
         (prin1 (type-of ,thing) ,to)
         ,@(if body `((write-string " " ,to))))
       ,@body
       (when ,told-apart
         (write-identity ,thing ,to ,(if body t typed)))
       (write-string ">" ,to)
       nil)))

(defun specializer-name (specializer)
  (if (consp specializer) specializer (class-name specializer)))

(defgeneric print-object (object stream))

(defmethod print-object (object stream)
  (write-string (plain-text object) stream)
  object)

(defmethod print-object ((object standard-object) stream)
  (print-unreadable-object (object stream :type t :identity t))
  object)

(defmethod print-object ((class class) stream)
  (print-unreadable-object (class stream)
    (format stream "~S ~S" (class-kind class) (class-name class)))
  class)

(defmethod print-object ((generic standard-generic-function) stream)
  (let ((kept (kept-by generic)))
    (print-unreadable-object (generic stream)
      (format stream "STANDARD-GENERIC-FUNCTION ~S (~D)" (standard-generic-function-name kept)
              (length (standard-generic-function-methods kept)))))
  generic)

(defmethod print-object ((method standard-method) stream)
  (print-unreadable-object (method stream)
    (format stream "STANDARD-METHOD ~S" (standard-generic-function-name (standard-method-generic-function method)))
    (dolist (qualifier (standard-method-qualifiers method))
      (format stream " ~S" qualifier))
    (format stream " ~S" (mapcar #'specializer-name (standard-method-specializers method))))
  method)

#+clara
(defun cl::%object-text (object)
  (with-output-to-string (stream)
    (print-object object stream)))
