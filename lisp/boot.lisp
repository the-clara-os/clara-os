;;;; boot.lisp: the part of Common Lisp that is written in Lisp
;;;;
;;;; The substrate evaluates this file when the machine starts, before it
;;;; reads anything else. It has the special forms and some hundred
;;;; functions in C (kernel/lisp/eval.c, builtin.c); the macros and the
;;;; functions here make the rest of the language out of them, and every
;;;; other file takes them for granted.
;;;;
;;;; This is the one Lisp file that SBCL never loads: SBCL has all of it
;;;; already. A name that begins with % is the substrate's own, internal to
;;;; COMMON-LISP, and nothing outside this file should need one.

(setq *package* (find-package "COMMON-LISP"))

;;; What this file adds to the language. A name read here is internal to
;;; COMMON-LISP until it is exported, and only an external one is the
;;; symbol that the other packages mean by it.
(export '(when unless and or cond case ecase otherwise return prog1 psetq
          dolist dotimes do do* loop do-symbols
          multiple-value-list multiple-value-setq nth-value
          setf defsetf incf decf push pop
          defstruct in-package defpackage make-package
          identity cadr cddr caar cdar caddr cdddr cadddr
          first rest second third fourth endp nthcdr nth last
          reverse nreverse copy-list mapcar mapc mapcan
          member assoc remove-if remove-if-not remove find-if find position-if position
          every some reduce sort getf get
          zerop plusp minusp evenp oddp abs max min expt
          char= char< char-code-limit concatenate make-string make-array macroexpand
          define-condition make-condition ignore-errors
          condition warning serious-condition storage-condition
          simple-condition simple-error simple-warning
          type-error program-error control-error cell-error
          unbound-variable undefined-function arithmetic-error division-by-zero
          simple-condition-format-control simple-condition-format-arguments
          type-error-datum type-error-expected-type cell-error-name
          stream-error end-of-file parse-error reader-error
          subseq warn room
          *standard-output* *standard-input* streamp
          write-string write-char write-line terpri fresh-line
          prin1 princ print format finish-output force-output
          make-string-output-stream get-output-stream-string with-output-to-string
          make-string-input-stream read-line read-from-string
          open close with-open-file probe-file directory delete-file
          compile disassemble time))

;;; Control

(defmacro when (test &body body)
  `(if ,test (progn ,@body)))

(defmacro unless (test &body body)
  `(if ,test nil (progn ,@body)))

(defmacro and (&rest forms)
  (if (null forms)
      t
      (if (null (cdr forms))
          (car forms)
          `(if ,(car forms) (and ,@(cdr forms))))))

(defmacro or (&rest forms)
  (if (null forms)
      nil
      (if (null (cdr forms))
          (car forms)
          (let ((value (gensym)))
            `(let ((,value ,(car forms)))
               (if ,value ,value (or ,@(cdr forms))))))))

(defmacro cond (&rest clauses)
  (if (null clauses)
      nil
      (let ((clause (car clauses)))
        (if (null (cdr clause))
            `(or ,(car clause) (cond ,@(cdr clauses)))
            `(if ,(car clause)
                 (progn ,@(cdr clause))
                 (cond ,@(cdr clauses)))))))

(defmacro return (&optional value)
  `(return-from nil ,value))

(defmacro prog1 (first &body body)
  (let ((value (gensym)))
    `(let ((,value ,first)) ,@body ,value)))

;; DO sets its variables with PSETQ, so PSETQ goes round with a TAGBODY of
;; its own.
(defmacro psetq (&rest pairs)
  (let ((bindings nil) (settings nil) (rest pairs))
    (tagbody
     next
       (when rest
         (let ((value (gensym)))
           (setq bindings (cons (list value (cadr rest)) bindings)
                 settings (cons (car rest) (cons value settings))
                 rest (cddr rest)))
         (go next)))
    `(let ,(reverse bindings) (setq ,@settings) nil)))

;; The keys of a clause of CASE are compared with EQL. For a symbol and for
;; an integer that is EQ, which compiled code does without a call, and those
;; are the keys that nearly every CASE has: a clause with such keys is
;; written as so many EQs, and any other as it reads.
(defun %plain-keys (keys)
  (if (null keys)
      t
      (if (if (symbolp (car keys)) t (integerp (car keys)))
          (%plain-keys (cdr keys))
          nil)))

(defun %case-test (value keys)
  (if (null (cdr keys))
      `(eq ,value ',(car keys))
      `(if (eq ,value ',(car keys)) t ,(%case-test value (cdr keys)))))

(defmacro case (key &rest clauses)
  (let ((value (gensym)))
    `(let ((,value ,key))
       (cond ,@(mapcar (lambda (clause)
                         (let ((keys (car clause)))
                           (cons (cond ((or (eq keys t) (eq keys 'otherwise)) t)
                                       ((null keys) nil)
                                       ((listp keys) (if (%plain-keys keys)
                                                         (%case-test value keys)
                                                         `(member ,value ',keys)))
                                       ((%plain-keys (list keys)) `(eq ,value ',keys))
                                       (t `(eql ,value ',keys)))
                                 (or (cdr clause) '(nil)))))
                       clauses)))))

(defmacro ecase (key &rest clauses)
  (let ((value (gensym)))
    `(let ((,value ,key))
       (case ,value
         ,@clauses
         (t (error "~S fell through an ECASE form" ,value))))))

;;; Loops

(defmacro dolist ((variable list &optional result) &body body)
  (let ((rest (gensym)) (next (gensym)))
    `(block nil
       (let ((,rest ,list))
         (tagbody
          ,next
            (if ,rest
                (progn
                  (let ((,variable (car ,rest))) ,@body)
                  (setq ,rest (cdr ,rest))
                  (go ,next)))))
       ,@(if result `((let ((,variable nil)) ,result))))))

;; DO-SYMBOLS: the body with the variable bound in turn to every symbol
;; that can be had by its name in a package, its own and the external ones
;; of the packages that it uses; in the current package when none is named.
(defmacro do-symbols ((variable &optional (package '*package*) result) &body body)
  `(dolist (,variable (%package-symbols ,package) ,result)
     ,@body))

(defmacro dotimes ((variable count &optional result) &body body)
  (let ((limit (gensym)) (next (gensym)))
    `(block nil
       (let ((,limit ,count) (,variable 0))
         (tagbody
          ,next
            (if (< ,variable ,limit)
                (progn
                  (locally ,@body)
                  (setq ,variable (1+ ,variable))
                  (go ,next))))
         ,result))))

;; DO and DO* differ in how the variables get their values: all at once, or
;; one after the other.
(defun %do (bindings end body let setq)
  (let ((next (gensym)) (steps nil))
    (dolist (binding bindings)
      (if (and (consp binding) (cddr binding))
          (setq steps (append steps (list (car binding) (caddr binding))))))
    `(block nil
       (,let ,(mapcar (lambda (binding)
                        (if (consp binding)
                            (list (car binding) (cadr binding))
                            binding))
                      bindings)
         (tagbody
          ,next
            (if ,(car end) (return (progn ,@(cdr end))))
            (tagbody ,@body)
            (,setq ,@steps)
            (go ,next))))))

(defmacro do (bindings end &body body)
  (%do bindings end body 'let 'psetq))

(defmacro do* (bindings end &body body)
  (%do bindings end body 'let* 'setq))

;; The LOOP with no keywords: its forms, again and again, until a RETURN.
(defmacro loop (&body body)
  (let ((next (gensym)))
    (dolist (form body)
      (if (atom form)
          (error "LOOP with keywords, which is not here yet: ~S" form)))
    `(block nil (tagbody ,next ,@body (go ,next)))))

;;; Several values

(defmacro multiple-value-list (form)
  `(multiple-value-call #'list ,form))

(defmacro nth-value (n form)
  `(nth ,n (multiple-value-list ,form)))

(defmacro multiple-value-setq (variables form)
  (let ((values (mapcar (lambda (variable) (declare (ignore variable)) (gensym))
                        variables)))
    `(multiple-value-bind ,values ,form
       (setq ,@(mapcan #'list variables values))
       ,(car values))))

;;; Lists

(defun identity (x) x)

(defun cadr (list) (car (cdr list)))
(defun cddr (list) (cdr (cdr list)))
(defun caar (list) (car (car list)))
(defun cdar (list) (cdr (car list)))
(defun caddr (list) (car (cddr list)))
(defun cdddr (list) (cdr (cddr list)))
(defun cadddr (list) (car (cdddr list)))

(defun first (list) (car list))
(defun rest (list) (cdr list))
(defun second (list) (cadr list))
(defun third (list) (caddr list))
(defun fourth (list) (cadddr list))

(defun endp (list) (null list))

(defun nthcdr (n list)
  (dotimes (i n list)
    (setq list (cdr list))))

(defun nth (n list)
  (car (nthcdr n list)))

(defun last (list)
  (do () ((atom (cdr list)) list)
    (setq list (cdr list))))

(defun reverse (list)
  (let ((reversed nil))
    (dolist (item list reversed)
      (setq reversed (cons item reversed)))))

;; NREVERSE may use the conses of its list again, and does not have to.
(defun nreverse (list)
  (reverse list))

(defun copy-list (list)
  (let* ((head (list nil)) (tail head))
    (do () ((atom list) (rplacd tail list) (cdr head))
      (setq tail (cdr (rplacd tail (list (car list))))
            list (cdr list)))))

(defun %any-null (lists)
  (dolist (list lists nil)
    (if (null list) (return t))))

(defun mapcar (function list &rest more)
  (let* ((head (list nil)) (tail head))
    (if more
        (do ((lists (cons list more) (mapcar #'cdr lists)))
            ((%any-null lists))
          (setq tail (cdr (rplacd tail (list (apply function (mapcar #'car lists)))))))
        (dolist (item list)
          (setq tail (cdr (rplacd tail (list (funcall function item)))))))
    (cdr head)))

(defun mapc (function list &rest more)
  (apply #'mapcar function list more)
  list)

(defun mapcan (function &rest lists)
  (apply #'append (apply #'mapcar function lists)))

(defun member (item list &key (test #'eql) (key #'identity))
  (do ((rest list (cdr rest))) ((null rest) nil)
    (if (funcall test item (funcall key (car rest)))
        (return rest))))

(defun assoc (item alist &key (test #'eql) (key #'identity))
  (dolist (pair alist)
    (if (and pair (funcall test item (funcall key (car pair))))
        (return pair))))

(defun remove-if (predicate list)
  (let ((kept nil))
    (dolist (item list)
      (unless (funcall predicate item)
        (setq kept (cons item kept))))
    (reverse kept)))

(defun remove-if-not (predicate list)
  (remove-if (lambda (item) (not (funcall predicate item))) list))

(defun remove (item list &key (test #'eql))
  (remove-if (lambda (other) (funcall test item other)) list))

;; FIND, FIND-IF, POSITION and POSITION-IF look into a list, a string or a
;; vector: at the elements from START up to END, for the first that passes,
;; or for the last when FROM-END is true. %SEEK is the four of them. An
;; element passes when TEST is true of ITEM and the element, and when there
;; is no TEST, when ITEM, a predicate then, is true of it; KEY says what of
;; the element is looked at. It gives the element when ELEMENT is true and
;; the element's place otherwise. The test is written into its three loops
;; and is no function: a call for every element is what a long list costs.
(defmacro %passes (item test key element)
  `(if ,test
       (funcall ,test ,item (if ,key (funcall ,key ,element) ,element))
       (funcall ,item (if ,key (funcall ,key ,element) ,element))))

;; Where the part ends that START and END name, which have to name one.
(defun %part-end (sequence start end)
  (let ((length (length sequence)))
    (if (and (integerp start) (or (null end) (integerp end))
             (<= 0 start (or end length) length))
        (or end length)
        (error "~S has no part from ~S to ~S" sequence start (or end length)))))

(defun %seek (name item test sequence start end from-end key element)
  (cond ((listp sequence)
         ;; A whole list is walked once, and its length is nobody's business.
         (let ((end (if (and (eq start 0) (null end)) nil (%part-end sequence start end)))
               (index 0) (found nil) (found-at nil))
           (do ((rest sequence (cdr rest)))
               ((or (atom rest) (and end (>= index end))))
             (when (and (>= index start) (%passes item test key (car rest)))
               (setq found (car rest) found-at index)
               (unless from-end (return)))
             (setq index (1+ index)))
           (if element found found-at)))
        ((or (stringp sequence) (vectorp sequence))
         (let ((end (%part-end sequence start end)))
           (if from-end
               (do ((index (1- end) (1- index))) ((< index start) nil)
                 (when (%passes item test key (aref sequence index))
                   (return (if element (aref sequence index) index))))
               (do ((index start (1+ index))) ((>= index end) nil)
                 (when (%passes item test key (aref sequence index))
                   (return (if element (aref sequence index) index)))))))
        (t (error "~A looks into a list, a string or a vector, and ~S is none" name sequence))))

(defun find-if (predicate sequence &key (start 0) end key from-end)
  (%seek 'find-if predicate nil sequence start end from-end key t))

(defun find (item sequence &key (test #'eql) (start 0) end key from-end)
  (%seek 'find item test sequence start end from-end key t))

(defun position-if (predicate sequence &key (start 0) end key from-end)
  (%seek 'position-if predicate nil sequence start end from-end key nil))

(defun position (item sequence &key (test #'eql) (start 0) end key from-end)
  (%seek 'position item test sequence start end from-end key nil))

(defun every (predicate list)
  (dolist (item list t)
    (unless (funcall predicate item) (return nil))))

(defun some (predicate list)
  (dolist (item list nil)
    (let ((value (funcall predicate item)))
      (if value (return value)))))

(defun reduce (function list &key (initial-value nil initial-value-p))
  (let ((value (if initial-value-p initial-value (car list))))
    (dolist (item (if initial-value-p list (cdr list)) value)
      (setq value (funcall function value item)))))

;; SORT may use up the list it is given, and does not: it makes a new one,
;; by merging, and what the predicate does not tell apart stays in the
;; order it was in.
(defun %merge (a b predicate key)
  (let* ((head (list nil)) (tail head))
    (loop
      (cond ((null a) (rplacd tail b) (return (cdr head)))
            ((null b) (rplacd tail a) (return (cdr head)))
            ((funcall predicate (funcall key (car b)) (funcall key (car a)))
             (setq tail (cdr (rplacd tail (list (car b))))
                   b (cdr b)))
            (t
             (setq tail (cdr (rplacd tail (list (car a))))
                   a (cdr a)))))))

(defun sort (list predicate &key (key #'identity))
  (unless (listp list)
    (error "SORT takes a list, and not ~S yet" list))
  (if (null (cdr list))
      list
      (let ((half (floor (length list) 2)))
        (%merge (sort (subseq list 0 half) predicate :key key)
                (sort (nthcdr half list) predicate :key key)
                predicate key))))

(defun getf (plist indicator &optional default)
  (do ((rest plist (cddr rest))) ((null rest) default)
    (if (eq (car rest) indicator) (return (cadr rest)))))

(defun get (symbol indicator &optional default)
  (getf (symbol-plist symbol) indicator default))

(defun %put (symbol indicator value)
  (do ((rest (symbol-plist symbol) (cddr rest)))
      ((null rest)
       (%set-symbol-plist symbol (list* indicator value (symbol-plist symbol))))
    (if (eq (car rest) indicator)
        (return (rplaca (cdr rest) value))))
  value)

;;; Integers

(defun zerop (n) (= n 0))
(defun plusp (n) (> n 0))
(defun minusp (n) (< n 0))
(defun evenp (n) (= (rem n 2) 0))
(defun oddp (n) (not (evenp n)))
(defun abs (n) (if (< n 0) (- n) n))

(defun max (n &rest more)
  (dolist (other more n)
    (if (> other n) (setq n other))))

(defun min (n &rest more)
  (dolist (other more n)
    (if (< other n) (setq n other))))

(defun expt (base power)
  (if (< power 0)
      (error "~S to the power ~S is not an integer, and there are no ratios yet" base power))
  (let ((result 1))
    (dotimes (i power result)
      (setq result (* result base)))))

;;; Characters, strings and vectors

;; One more than the highest code that a character has: Unicode ends at
;; #x10FFFF. What a keyboard hands on for a key that types no character is
;; a code from here on (lisp/input.lisp).
(defconstant char-code-limit #x110000)

(defun char= (a b) (= (char-code a) (char-code b)))
(defun char< (a b) (< (char-code a) (char-code b)))

(defun concatenate (type &rest sequences)
  (cond ((eq type 'string) (apply #'%string-append sequences))
        ((eq type 'list) (apply #'append sequences))
        (t (error "CONCATENATE makes a STRING or a LIST, and not a ~S yet" type))))

;; A new string of LENGTH characters, each of them INITIAL-ELEMENT. When
;; nothing is said it is the character of code 0, which is what SBCL fills
;; a string with: a program gets the same string here and there.
(defun make-string (length &key (initial-element (code-char 0)))
  (%make-string length initial-element))

(defun make-array (length &key (initial-element 0))
  (%make-vector length initial-element))

;; A part of a string or of a list: from start up to end, or to the end.
(defun subseq (sequence start &optional end)
  (cond ((stringp sequence)
         (%substring sequence start (or end (length sequence))))
        ((listp sequence)
         (let ((kept nil) (rest (nthcdr start sequence)) (index start))
           (do () ((or (null rest) (and end (>= index end))) (reverse kept))
             (setq kept (cons (car rest) kept)
                   rest (cdr rest)
                   index (1+ index)))))
        (t (error "SUBSEQ takes a string or a list, and not ~S yet" sequence))))

;;; Places
;;;
;;; SETF knows a place by the function that reads it: DEFSETF names the
;;; function that writes it, which takes the same arguments and then the
;;; new value, and returns that value.

(defmacro defsetf (reader writer)
  `(progn (%put ',reader '%writer ',writer) ',reader))

;; A place that begins with a name which has no such writer, and is no
;; macro's, is written by the function (SETF name): it is given the new
;; value before the other arguments, and is what a generic function of
;; that name is (lisp/clos.lisp). The function lives in a symbol of its
;; own, which the name keeps. When it is there as the SETF is expanded,
;; the form calls it; when it is not, the form looks for it as it runs,
;; so a function can be written before the class whose accessor it sets.
(defun %setf-name (name)
  (or (get name '%setf)
      (%put name '%setf (make-symbol (%string-append "(SETF " (symbol-name name) ")")))))

(defun %setf-function (name place)
  (let ((symbol (get name '%setf)))
    (if (and symbol (fboundp symbol))
        (symbol-function symbol)
        (error "SETF does not know the place ~S" place))))

(defun %setf (place value)
  (cond ((symbolp place) `(setq ,place ,value))
        ((atom place) (error "SETF cannot store into ~S" place))
        ((not (symbolp (car place))) (error "SETF does not know the place ~S" place))
        ((get (car place) '%writer)
         `(,(get (car place) '%writer) ,@(cdr place) ,value))
        (t (multiple-value-bind (expansion expanded) (macroexpand-1 place)
             (if expanded
                 (%setf expansion value)
                 (multiple-value-bind (bindings read) (%place place)
                   (let ((symbol (get (car place) '%setf)))
                     `(let* ,bindings
                        ,(if (and symbol (fboundp symbol))
                             `(,symbol ,value ,@(cdr read))
                             `(funcall (%setf-function ',(car place) ',place) ,value ,@(cdr read)))))))))))

(defmacro setf (&rest pairs)
  (cond ((null pairs) nil)
        ((null (cddr pairs)) (%setf (car pairs) (cadr pairs)))
        (t `(progn (setf ,(car pairs) ,(cadr pairs))
                   (setf ,@(cddr pairs))))))

;; The forms inside a place are evaluated once, in order, even when the
;; place is read and then written: these are the bindings that do it, and
;; the place written with their variables.
(defun %place (place)
  (if (atom place)
      (values nil place)
      (let ((names (mapcar (lambda (form) (declare (ignore form)) (gensym))
                           (cdr place))))
        (values (mapcar #'list names (cdr place))
                (cons (car place) names)))))

(defmacro incf (place &optional (delta 1))
  (multiple-value-bind (bindings read) (%place place)
    `(let* ,bindings (setf ,read (+ ,read ,delta)))))

(defmacro decf (place &optional (delta 1))
  (multiple-value-bind (bindings read) (%place place)
    `(let* ,bindings (setf ,read (- ,read ,delta)))))

(defmacro push (item place)
  (multiple-value-bind (bindings read) (%place place)
    (let ((value (gensym)))
      `(let* ((,value ,item) ,@bindings)
         (setf ,read (cons ,value ,read))))))

(defmacro pop (place)
  (multiple-value-bind (bindings read) (%place place)
    (let ((list (gensym)))
      `(let* (,@bindings (,list ,read))
         (setf ,read (cdr ,list))
         (car ,list)))))

(defun %set-car (cons value) (rplaca cons value) value)
(defun %set-cdr (cons value) (rplacd cons value) value)
(defun %set-cadr (list value) (%set-car (cdr list) value))
(defun %set-caddr (list value) (%set-car (cddr list) value))
(defun %set-nth (n list value) (%set-car (nthcdr n list) value))

(defsetf car %set-car)
(defsetf first %set-car)
(defsetf cdr %set-cdr)
(defsetf rest %set-cdr)
(defsetf cadr %set-cadr)
(defsetf second %set-cadr)
(defsetf caddr %set-caddr)
(defsetf third %set-caddr)
(defsetf nth %set-nth)
(defsetf aref %set-aref)
(defsetf svref %set-aref)
(defsetf char %set-char)
(defsetf schar %set-char)
(defsetf symbol-value set)
(defsetf symbol-function %set-symbol-function)
(defsetf symbol-plist %set-symbol-plist)
(defsetf get %put)

(defun macroexpand (form)
  (loop
    (multiple-value-bind (expansion expanded) (macroexpand-1 form)
      (unless expanded (return form))
      (setq form expansion))))

;;; Packages

(defun %package (name)
  (or (find-package name)
      (error "there is no package named ~A" (string name))))

(defmacro in-package (name)
  `(setq *package* (%package ',name)))

(defun make-package (name &key nicknames use)
  (%make-package (string name) (mapcar #'string nicknames) (mapcar #'%package use)))

(defun %defpackage (name options)
  (let ((nicknames nil) (use nil) (exports nil))
    (dolist (option options)
      (case (car option)
        (:nicknames (setq nicknames (append nicknames (cdr option))))
        (:use (setq use (append use (cdr option))))
        (:export (setq exports (append exports (cdr option))))
        (t (error "DEFPACKAGE with ~S, which is not here yet" (car option)))))
    (let ((package (or (find-package name)
                       (make-package name :nicknames nicknames :use use))))
      (dolist (symbol exports)
        (export (intern (string symbol) package) package))
      package)))

(defmacro defpackage (name &rest options)
  `(%defpackage ',name ',options))

;;; Structures
;;;
;;; (defstruct name slot...) with a slot written as a name or as
;;; (name default): MAKE-name with a keyword for each slot, name-P,
;;; COPY-name, and name-slot to read a slot, which SETF can write.

(defun %symbol (&rest strings)
  (values (intern (apply #'%string-append strings))))

(defmacro defstruct (name &rest slots)
  (if (consp name)
      (error "DEFSTRUCT with options, which are not here yet: ~S" name))
  (let* ((slots (if (stringp (car slots)) (cdr slots) slots))
         (names (mapcar (lambda (slot) (if (consp slot) (car slot) slot)) slots))
         (text (symbol-name name))
         (type (cons name names))
         (index -1))
    `(progn
       (%put ',name '%structure ',type) ; for whoever asks what the name is the type of (lisp/clos.lisp)
       (defun ,(%symbol "MAKE-" text)
           (&key ,@(mapcar (lambda (slot)
                             (if (consp slot) (list (car slot) (cadr slot)) slot))
                           slots))
         (%make-structure ',type ,@names))
       (defun ,(%symbol text "-P") (object)
         (%structure-p object ',name))
       (defun ,(%symbol "COPY-" text) (object)
         (copy-structure object))
       ,@(mapcan (lambda (slot)
                   (let ((reader (%symbol text "-" (symbol-name slot)))
                         (writer (%symbol "%SET-" text "-" (symbol-name slot))))
                     (setq index (1+ index))
                     `((defun ,reader (object)
                         (%structure-ref object ',name ,index))
                       (defun ,writer (object value)
                         (%structure-set object ',name ,index value))
                       (defsetf ,reader ,writer))))
                 names)
       ',name)))

;;; Conditions
;;;
;;; A type of condition is a name. DEFINE-CONDITION leaves what there is to
;;; know about it on the property list of the name, under %CONDITION: the
;;; parents of the type, and then its own slots, each as (name initarg
;;; default), where the default is a function of no arguments, or NIL. The
;;; substrate looks at the parents to see whether a clause of a
;;; HANDLER-CASE takes a condition (kernel/lisp/eval.c). A condition is its
;;; type, what it says to a person, and the names of its slots with their
;;; values in turn.
;;;
;;; What a condition says is made when the condition is: for the types
;;; below SIMPLE-CONDITION, what FORMAT makes of the control string and its
;;; arguments. DEFINE-CONDITION refuses a :REPORT function, and a condition
;;; of a type that has nothing to say shows its type and its slots.

(defun %slots (type)
  (let ((known (get type '%condition)))
    (unless known
      (error "~S is not the name of a type of condition" type))
    (append (cdr known) (mapcan #'%slots (car known)))))

;; The rest of a property list from the indicator on, when it is there.
(defun %supplied (plist indicator)
  (do ((rest plist (cddr rest))) ((null rest) nil)
    (if (eq (car rest) indicator) (return rest))))

(defun make-condition (type &rest arguments)
  (let ((slots (%slots type)) (values nil))
    (do ((rest arguments (cddr rest))) ((null rest))
      (unless (some (lambda (slot) (eq (cadr slot) (car rest))) slots)
        (error "a condition of the type ~S has no slot that ~S is the argument for"
               type (car rest))))
    (dolist (slot slots)
      (unless (%supplied values (car slot))
        (let ((given (if (cadr slot) (%supplied arguments (cadr slot)))))
          (cond (given
                 (setq values (append values (list (car slot) (cadr given)))))
                ((caddr slot)
                 (setq values (append values (list (car slot) (funcall (caddr slot))))))))))
    (%make-condition type
                     (let ((control (getf values 'format-control)))
                       (if (stringp control)
                           (apply #'format nil control (getf values 'format-arguments))))
                     values)))

(defun %slot (condition name)
  (let ((found (%supplied (%condition-slots condition) name)))
    (if found
        (cadr found)
        (error "the slot ~A of ~S has no value" name condition))))

;; A slot as DEFINE-CONDITION writes it, a name or (name option value...):
;; the form that makes what is kept of it, and the functions that read it.
(defun %slot-form (slot)
  (let ((name (if (consp slot) (car slot) slot)) (initarg nil) (default nil))
    (do ((options (if (consp slot) (cdr slot)) (cddr options))) ((null options))
      (case (car options)
        (:initarg (setq initarg (cadr options)))
        (:initform (setq default `(lambda () ,(cadr options))))
        ((:reader :accessor :type :documentation))
        (t (error "DEFINE-CONDITION with the slot option ~S, which is not here yet"
                  (car options)))))
    `(list ',name ',initarg ,default)))

(defun %slot-readers (slot)
  (let ((readers nil))
    (do ((options (if (consp slot) (cdr slot)) (cddr options))) ((null options) readers)
      (if (member (car options) '(:reader :accessor))
          (setq readers (cons `(defun ,(cadr options) (condition)
                                 (%slot condition ',(car slot)))
                              readers))))))

(defmacro define-condition (name parents slots &rest options)
  (dolist (option options)
    (unless (eq (car option) :documentation)
      (error "DEFINE-CONDITION with ~S, which is not here yet" (car option))))
  `(progn
     (%put ',name '%condition
           (list ',(or parents '(condition)) ,@(mapcar #'%slot-form slots)))
     ,@(mapcan #'%slot-readers slots)
     ',name))

;; The types that Common Lisp begins with, as far as the substrate signals
;; them. CONDITION is the one without a parent.
(%put 'condition '%condition (list nil))
(define-condition warning (condition) ())
(define-condition serious-condition (condition) ())
(define-condition error (serious-condition) ())
(define-condition storage-condition (serious-condition) ())
(define-condition simple-condition (condition)
  ((format-control :initarg :format-control :reader simple-condition-format-control)
   (format-arguments :initarg :format-arguments :initform nil
                     :reader simple-condition-format-arguments)))
(define-condition simple-error (simple-condition error) ())
(define-condition simple-warning (simple-condition warning) ())
(define-condition type-error (error)
  ((datum :initarg :datum :reader type-error-datum)
   (expected-type :initarg :expected-type :reader type-error-expected-type)))
(define-condition program-error (error) ())
(define-condition control-error (error) ())
(define-condition cell-error (error)
  ((name :initarg :name :reader cell-error-name)))
(define-condition unbound-variable (cell-error) ())
(define-condition undefined-function (cell-error) ())
(define-condition arithmetic-error (error) ())
(define-condition division-by-zero (arithmetic-error) ())

(define-condition stream-error (error) ())
(define-condition end-of-file (stream-error) ())
(define-condition parse-error (error) ())
(define-condition reader-error (parse-error stream-error) ())

(defmacro ignore-errors (&body body)
  `(handler-case (progn ,@body)
     (error (condition) (values nil condition))))

;;; Streams
;;;
;;; A stream is where characters go to, or come from. It is made of two
;;; functions: one that is given a string to write, and one that gives the
;;; next line that was read, or NIL when no more will come. The printer
;;; makes strings (kernel/lisp/builtin.c), and whatever writes hands one to
;;; a stream. *STANDARD-OUTPUT* begins as the substrate's own console; the
;;; console that is written in Lisp (lisp/console.lisp) puts its stream
;;; there when it starts.

(defstruct %stream
  write       ; a function of a string, or NIL for a stream that cannot be written to
  read        ; a function of no arguments, or NIL
  (fresh t)   ; nothing has been written since the last new line
  parts       ; of a string stream: what was written, the last first
  close)      ; a function of no arguments for CLOSE to call, when closing is more than letting go

(defvar *standard-output* (make-%stream :write #'%console-write))
(defvar *standard-input* (make-%stream))

(defun streamp (object)
  (%stream-p object))

(defun %output (stream)
  (cond ((or (null stream) (eq stream t)) *standard-output*)
        ((and (%stream-p stream) (%stream-write stream)) stream)
        (t (error "~S is not a stream that can be written to" stream))))

(defun write-string (string &optional stream)
  (let ((stream (%output stream)) (length (length string)))
    (when (plusp length)
      (funcall (%stream-write stream) string)
      (setf (%stream-fresh stream) (char= (char string (1- length)) #\Newline)))
    string))

(defun write-char (character &optional stream)
  (write-string (string character) stream)
  character)

(defun terpri (&optional stream)
  (write-string (string #\Newline) stream)
  nil)

(defun fresh-line (&optional stream)
  (unless (%stream-fresh (%output stream))
    (terpri stream)
    t))

(defun write-line (string &optional stream)
  (write-string string stream)
  (terpri stream)
  string)

(defun prin1 (object &optional stream)
  (write-string (prin1-to-string object) stream)
  object)

(defun princ (object &optional stream)
  (write-string (princ-to-string object) stream)
  object)

(defun print (object &optional stream)
  (terpri stream)
  (prin1 object stream)
  (write-string " " stream)
  object)

;; T is *STANDARD-OUTPUT*, and NIL is no stream at all: the string itself.
(defun format (destination control &rest arguments)
  (let ((text (apply #'%format control arguments)))
    (if destination
        (progn (write-string text destination) nil)
        text)))

;; What is written reaches its stream at once, so there is nothing to finish.
(defun finish-output (&optional stream)
  (declare (ignore stream))
  nil)

(defun force-output (&optional stream)
  (declare (ignore stream))
  nil)

(defun make-string-output-stream ()
  (let ((stream (make-%stream)))
    (setf (%stream-write stream)
          (lambda (string)
            (setf (%stream-parts stream) (cons string (%stream-parts stream)))))
    stream))

(defun get-output-stream-string (stream)
  (let ((parts (reverse (%stream-parts stream))))
    (setf (%stream-parts stream) nil)
    (%join parts)))

(defmacro with-output-to-string ((variable) &body body)
  `(let ((,variable (make-string-output-stream)))
     ,@body
     (get-output-stream-string ,variable)))

;; The lines of a string, one at a time.
(defun make-string-input-stream (string)
  (let ((start 0) (length (length string)))
    (make-%stream
     :read (lambda ()
             (when (< start length)
               (let ((end start))
                 (loop
                   (when (or (= end length) (char= (char string end) #\Newline))
                     (return))
                   (setq end (1+ end)))
                 (prog1 (subseq string start end)
                   (setq start (min (1+ end) length)))))))))

(defun read-line (&optional stream (eof-error-p t) eof-value)
  (let* ((stream (if (or (null stream) (eq stream t)) *standard-input* stream))
         (read (and (%stream-p stream) (%stream-read stream)))
         (line (if read (funcall read))))
    (cond (line (values line nil))
          (eof-error-p (error 'end-of-file))
          (t (values eof-value t)))))

;; The first form of a string, and where in the string it ends. When
;; nothing is left to read: EOF-VALUE, or the condition END-OF-FILE. A
;; string that stops in the middle of a form is END-OF-FILE whatever
;; EOF-ERROR-P says, as under any Common Lisp.
(defun read-from-string (string &optional (eof-error-p t) eof-value &key (start 0))
  (multiple-value-bind (form position) (%read-from-string string start)
    (cond (position (values form position))
          (eof-error-p (error 'end-of-file))
          (t (values eof-value (length string))))))

;;; Files
;;;
;;; A file has a name, and the name is a string: the directories that lead
;;; to it and then its own name, with a slash before each, as in
;;; "/clara/boot.lisp". There are no pathnames. What knows about disks is
;;; Lisp that is loaded after this file (lisp/fat.lisp), and it says that
;;; it is there with CLARA:PROVIDE-FILES, which it gives its functions: one
;;; for the text of the file of a name; one for the names of what the
;;; directory of a name holds, in order, a directory's with a slash at its
;;; end, or NIL when there is no such directory; one that makes a file of
;;; a name out of bytes in memory; one that deletes the file of a name;
;;; one that makes a file like the third, on the volume that the machine
;;; was started from whatever volume the others look on, which is where a
;;; world is saved; one that makes a file of what another holds; and one
;;; that says which volumes there are. A machine can have several, and a
;;; name can say which of them it is on, by what the file system puts
;;; before a name for that, as in "2:/mine.lisp": nothing here looks at
;;; that part of a name, which goes to the file system as it stands, with
;;; the directory.
;;; Until then, and on a machine without a disk that has a driver, there
;;; are no files here, and LOAD finds the ones that the kernel read from
;;; the boot volume as it started.

(defvar %files nil) ; the seven functions, in a list, once a file system has said that it is there

(defun %file-name (name)
  (unless (stringp name)
    (error "the name of a file is a string, and ~S is not one" name))
  name)

(defun %file-text (name)
  (if %files
      (funcall (car %files) (%file-name name))
      (error "there is no file ~A: no disk has a file system that is known here" (%file-name name))))

(defun %file-names (directory)
  (if %files (funcall (cadr %files) directory)))

;; A file of a name, made of BYTES bytes of memory at ADDRESS, which is
;; page frames, as a disk wants them.
(defun %store-file (name address bytes)
  (let ((store (caddr %files)))
    (unless store
      (error "the file ~A cannot be written: ~A" (%file-name name)
             (if %files
                 "the file system that is here reads files, and writes none"
                 "no disk has a file system that is known here")))
    (funcall store name address bytes)))

;; A file of a name, made of a text: its characters as UTF-8, written out
;; in page frames that are given back.
(defun %write-file (name text)
  (let* ((bytes (clara.unsafe:string-bytes text))
         (pages (max 1 (floor (+ bytes 4095) 4096)))
         (memory (clara.unsafe:allocate-memory pages)))
    (unwind-protect
         (progn
           (clara.unsafe:string-memory text memory)
           (%store-file name memory bytes))
      (clara.unsafe:free-memory memory pages))))

;; A name without the slashes at its end, which a directory's may have.
(defun %plain-name (name)
  (let ((end (length name)))
    (loop
      (unless (and (> end 0) (char= (char name (1- end)) #\/))
        (return))
      (setq end (1- end)))
    (subseq name 0 end)))

;; The two parts of a name: its directory, as far as the last slash, and
;; what comes after that. A name without a slash is in the first directory
;; of all.
(defun %split-name (name)
  (let ((slash nil))
    (dotimes (i (length name))
      (if (char= (char name i) #\/) (setq slash i)))
    (if slash
        (values (subseq name 0 (1+ slash)) (subseq name (1+ slash)))
        (values "" name))))

;; Does a name fit a pattern, from the places P and N on? A * in a pattern
;; stands for any characters, or for none, and a letter for itself in
;; either case.
(defun %fits (pattern name p n)
  (cond ((= p (length pattern)) (= n (length name)))
        ((char= (char pattern p) #\*)
         (or (%fits pattern name (1+ p) n)
             (and (< n (length name)) (%fits pattern name p (1+ n)))))
        (t (and (< n (length name))
                (string-equal (char pattern p) (char name n))
                (%fits pattern name (1+ p) (1+ n))))))

;; The first directory of a volume, as the file system names it, when a
;; name is that and nothing more: "2:/", or "2:". No directory lists it, so
;; the file system is asked for the volumes that there are.
(defun %volume-named (name)
  (let ((volumes (nth 6 %files)))
    (if volumes
        (dolist (volume (funcall volumes))
          (if (string-equal (%plain-name name) (%plain-name (car volume)))
              (return (car volume)))))))

;; The name of a file or of a directory as the file system has it, when
;; there is one of that name, and NIL when there is none.
(defun probe-file (name)
  (multiple-value-bind (directory rest) (%split-name (%plain-name name))
    (if (= (length rest) 0)
        (if %files name)
        (or (dolist (entry (%file-names directory))
              (if (string-equal rest (%plain-name entry))
                  (return (concatenate 'string directory entry))))
            (if (= (length directory) 0)
                (%volume-named rest))))))

;; The names that fit a pattern: what the pattern's directory holds whose
;; own name fits what the pattern has after its last slash, in the order
;; the file system gives them.
(defun directory (pattern)
  (multiple-value-bind (directory rest) (%split-name pattern)
    (if (= (length rest) 0)
        (let ((found (probe-file pattern)))
          (if found (list found)))
        (let ((found nil))
          (dolist (entry (%file-names directory))
            (if (%fits rest (%plain-name entry) 0 0)
                (setq found (cons (concatenate 'string directory entry) found))))
          (reverse found)))))

;; A stream that keeps what is written to it, after TEXT if there is some,
;; and makes the file of a name out of all of it when it is closed: a file
;; is written whole.
(defun %output-file (name text)
  (let ((stream (make-%stream)))
    (setf (%stream-parts stream) (if text (list text))
          (%stream-write stream) (lambda (string)
                                   (setf (%stream-parts stream) (cons string (%stream-parts stream))))
          (%stream-close stream) (lambda ()
                                   (%write-file name (get-output-stream-string stream))))
    stream))

;; A file to read from, a line at a time, or to write to. A file that is
;; there already is an error unless :IF-EXISTS says what to do about it:
;; :SUPERSEDE, a new file in its place; :APPEND, what is written goes after
;; what the file holds; NIL, no stream. A file that is not there is made
;; when it is opened for writing, and is an error when it is opened for
;; reading, unless :IF-DOES-NOT-EXIST says NIL, no stream, or for writing
;; :ERROR.
(defun open (name &key (direction :input) (if-exists :error)
                       (if-does-not-exist (if (eq direction :input) :error :create)))
  (%file-name name)
  (case direction
    (:input
     (if (or (eq if-does-not-exist :error) (probe-file name))
         (make-string-input-stream (%file-text name))))
    (:output
     (let ((there (probe-file name)))
       (cond ((and there (eq if-exists :error))
              (error "OPEN: there is a file ~A already, and :IF-EXISTS does not say :SUPERSEDE or :APPEND" name))
             ((and there (null if-exists)) nil)
             ((and there (not (eq if-exists :supersede)) (not (eq if-exists :append)))
              (error "OPEN: :IF-EXISTS can say :ERROR, :SUPERSEDE, :APPEND or NIL, and not ~S" if-exists))
             ((and (not there) (eq if-does-not-exist :error))
              (error "there is no file ~A" name))
             ((and (not there) (null if-does-not-exist)) nil)
             (t (%output-file name (if (and there (eq if-exists :append)) (%file-text name)))))))
    (t (error "OPEN: a file is opened for :INPUT or for :OUTPUT, and not for ~S" direction))))

;; A stream that is closed gives nothing more, and takes nothing. A file
;; that was written to is made now, unless ABORT says that it is not to be.
(defun close (stream &key abort)
  (unless (%stream-p stream)
    (error "~S is not a stream" stream))
  (let ((close (%stream-close stream)))
    (setf (%stream-read stream) nil
          (%stream-write stream) nil
          (%stream-close stream) nil)
    (if (and close (not abort))
        (funcall close)))
  t)

;; The stream is closed whichever way control leaves the body; when that
;; is not by its end, a file that was being written is not made.
(defmacro with-open-file ((variable name &rest options) &body body)
  (let ((whole (gensym)))
    `(let ((,variable (open ,name ,@options)) (,whole nil))
       (unwind-protect (multiple-value-prog1 (progn ,@body) (setq ,whole t))
         (if ,variable (close ,variable :abort (not ,whole)))))))

(defun delete-file (name)
  (let ((delete (cadddr %files)))
    (unless delete
      (error "the file ~A cannot be deleted: ~A" (%file-name name)
             (if %files
                 "the file system that is here reads files, and deletes none"
                 "no disk has a file system that is known here")))
    (funcall delete name)
    t))

;; LOAD: the file of that name when a file system has it, and otherwise the
;; one of that name among the files that the kernel read as it started.
;; From here on this is LOAD, in place of the function in C that is
;; loading this file.
(defun load (name)
  (if (and (stringp name) (probe-file name))
      (%load-text (%file-text name) name)
      (%load name)))

;;; The compiler
;;;
;;; A function that the evaluator walks the forms of can be made one that
;;; the machine in kernel/lisp/vm.c runs instructions for, which means the
;;; same and is several times as quick. What makes it so is Lisp that is
;;; loaded after this file (lisp/compiler.lisp), and it says that it is
;;; there with CLARA:PROVIDE-COMPILER, which it gives its functions: one
;;; that makes a compiled function of a LAMBDA form and a name, and one
;;; that lists the instructions of a function.

(defvar %compiler nil) ; the three functions, in a list, once a compiler has said that it is there

;; A definition as a compiled function: a LAMBDA form is compiled, and so
;; is a function that is not compiled yet, from the form that it was made
;; of. NAME is for the function to have, and for a block around its body,
;; unless the function has a name of its own, which its body may leave by.
(defun %compiled (definition name)
  (cond ((null %compiler)
         (error "there is no compiler here: lisp/compiler.lisp is not loaded"))
        ((and (consp definition) (eq (car definition) 'lambda))
         (funcall (car %compiler) definition name))
        ((not (functionp definition))
         (error "COMPILE takes a function or a LAMBDA form, and ~S is neither" definition))
        ((compiled-function-p definition) definition)
        (t (multiple-value-bind (form closure own) (function-lambda-expression definition)
             (if closure
                 (error "~S was made where variables or local functions were in sight, and holds on to them: the compiler takes a function that stands by itself" definition)
                 (funcall (car %compiler) form (or own name)))))))

;; (compile 'name) makes the function of that name a compiled one, and
;; (compile 'name definition) gives the name the definition, compiled;
;; either gives the name. (compile nil definition) gives the function.
(defun compile (name &optional definition)
  (cond ((null name) (%compiled definition nil))
        ((not (symbolp name))
         (error "COMPILE takes the name of a function, a symbol, and ~S is not one" name))
        (t (%set-symbol-function name (%compiled (or definition (symbol-function name)) name))
           name)))

;; The instructions of a function, written out: of a compiled function, or
;; of what a function, the function of a name or a LAMBDA form is when it
;; is compiled, which leaves the function itself as it was.
(defun disassemble (function)
  (let ((function (if (and function (symbolp function)) (symbol-function function) function)))
    (funcall (cadr %compiler)
             (%compiled function (if (functionp function) (nth-value 2 (function-lambda-expression function)))))
    nil))

;; The values of a form, and how long it took to evaluate, to a hundredth
;; of a second, which is how often the clock ticks.
(defmacro time (form)
  (let ((start (gensym)))
    `(let ((,start (get-internal-real-time)))
       (multiple-value-prog1 ,form
         (fresh-line)
         (format t "~D milliseconds~%"
                 (* (floor 1000 internal-time-units-per-second) (- (get-internal-real-time) ,start)))))))

;; With no HANDLER-CASE for it, a warning is written down and the program
;; goes on.
(defun warn (datum &rest arguments)
  (let ((condition (apply #'%condition 'simple-warning datum arguments)))
    (signal condition)
    (fresh-line)
    (write-string "warning: ")
    (princ condition)
    (terpri)
    nil))

(defun room (&optional detail)
  (declare (ignore detail))
  (multiple-value-bind (size free collections) (%room)
    (fresh-line)
    (format t "the heap is ~D KiB long, with ~D KiB of it free, after ~D collections~%"
            size free collections)))

;;; The package CLARA
;;;
;;; What the substrate offers that Common Lisp has no name for: threads,
;;; locks and events, under the names that Bordeaux Threads made usual, a
;;; way to make a stream of two functions, a way for a file system to say
;;; that it is there, a way to save the world, and the condition that
;;; Ctrl-C is. Their functions are in C (kernel/lisp/thread.c), and what is
;;; said more easily in Lisp is here. Under SBCL, lisp/host/ stands in for
;;; all of it.

(in-package "CLARA")

(export '(make-thread with-lock-held make-stream keyboard-interrupt provide-files save-image provide-compiler
          volumes copy-file))

;; What Ctrl-C on the console is, to the computation it stops and to
;; whoever was reading a line.
(define-condition keyboard-interrupt (serious-condition) ())

;; A stream that writes by calling WRITE-STRING with a string, and reads
;; by calling READ-LINE, which gives a line or NIL when no more will come.
;; CLOSE, when there is one, is called when the stream is closed.
(defun make-stream (&key write-string read-line close)
  (cl::make-%stream :write write-string :read read-line :close close))

;; A file system says that it is there: TEXT gives the text of the file of
;; a name, NAMES the names of what the directory of a name holds, WRITE
;; makes a file of a name out of bytes in memory, and DELETE deletes the
;; file of a name (the comment on files, further up, says more). From then
;; on those are what OPEN, LOAD, PROBE-FILE, DIRECTORY and DELETE-FILE ask;
;; a file system that only reads gives the first two. IMAGE is what
;; SAVE-IMAGE writes with, and is WRITE when nothing else is said; COPY
;; makes a file of a name out of what the file of another name holds, and
;; VOLUMES says which volumes there are, for COPY-FILE and VOLUMES below.
;; Without them, there is no file system any more.
(defun provide-files (&key text names write delete image copy volumes)
  (setq cl::%files (if (and text names) (list text names write delete (or image write) copy volumes)))
  nil)

;; The volumes that the file system has found, in its order: for each a
;; list of the name of its first directory, which is what a name begins
;; with that is to be looked up there, "2:/" for the second, and after it
;; what the file system knows of the volume, a keyword and what it says for
;; each fact: :BYTES, how much room it has for files, used or not;
;; :STARTED-FROM, when the machine was started from it; :CURRENT, when it is
;; the one that a name is looked up on which does not say its volume;
;; :READ-ONLY, when nothing can be written to it. NIL when there is no file
;; system.
(defun volumes ()
  (let ((volumes (nth 6 cl::%files)))
    (if volumes (funcall volumes))))

;; A file of the name TO that holds what the file FROM holds, byte for
;; byte, on the same volume or on another, in place of a file that was
;; there under that name. FROM stays. The name TO is returned.
(defun copy-file (from to)
  (let ((copy (nth 5 cl::%files)))
    (cl::%file-name from)
    (cl::%file-name to)
    (unless copy
      (error "the file ~A cannot be copied: ~A" from
             (if cl::%files
                 "the file system that is here reads files, and writes none"
                 "no disk has a file system that is known here")))
    (funcall copy from to)
    to))

;; A compiler says that it is there: COMPILE makes a compiled function of a
;; LAMBDA form and a name, which may be NIL, LIST writes the instructions
;; of a function out, and EVALUATE gives the values of a form, having
;; compiled it. From then on the first two are what COMPILE and DISASSEMBLE
;; call, and the third is what EVAL is, and what LOAD does with every form
;; that it reads (kernel/lisp/eval.c): whatever is typed or loaded is
;; compiled before it runs.
(defun provide-compiler (&key compile list evaluate)
  (setq cl::%compiler (if compile (list compile list evaluate)))
  nil)

;; The world is saved: all that is in the heap goes into a file, and a
;; machine that finds the file on its boot volume when it starts takes it
;; for its heap, in place of loading the files of lisp/ again
;; (kernel/lisp/image.c). What is defined comes back, and what the special
;; variables hold outside every binding; threads do not, nor what a driver
;; knew of its device: the world begins again at the listener, with the
;; drivers started afresh. NAME is where the kernel looks, and the file is
;; written on the volume that the machine was started from, wherever the
;; names of other files are looked up at the moment.
(defun save-image (&optional (name "/clara/clara.image"))
  (let ((store (nth 4 cl::%files)))
    (unless store
      (error "the world cannot be saved in ~A: ~A" name
             (if cl::%files
                 "the file system that is here reads files, and writes none"
                 "no disk has a file system that is known here")))
    (multiple-value-bind (memory bytes pages) (clara.unsafe:heap-image)
      (unwind-protect (funcall store name memory bytes)
        (clara.unsafe:free-memory memory pages))))
  name)

;; The substrate calls this when a thread ends with a condition that
;; nothing handled: nobody may ever ask what became of the thread.
(defun %thread-failed (thread condition)
  (fresh-line)
  (format t "error in ~S: ~A~%" thread condition))

(defun make-thread (function &key name)
  (%make-thread function name))

;; The lock is given back whichever way control leaves the body, also when
;; the thread is stopped in the middle of it.
(defmacro with-lock-held ((lock) &body body)
  (let ((held (gensym)))
    `(let ((,held ,lock))
       (acquire-lock ,held)
       (unwind-protect (progn ,@body)
         (release-lock ,held)))))

;;; The package CLARA.UNSAFE
;;;
;;; Memory by its address and the I/O ports, for drivers and for nobody
;;; else (kernel/lisp/unsafe.c). What can be read there can be written with
;;; SETF.

(in-package "CLARA.UNSAFE")

(defsetf memory-8 %set-memory-8)
(defsetf memory-16 %set-memory-16)
(defsetf memory-32 %set-memory-32)
(defsetf memory-64 %set-memory-64)
(defsetf port-8 %set-port-8)
(defsetf port-16 %set-port-16)
(defsetf port-32 %set-port-32)
