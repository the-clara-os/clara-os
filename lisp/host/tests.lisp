;;;; host/tests.lisp: the Lisp of ClaraOS, tested under SBCL
;;;;
;;;; usage: sbcl --script lisp/host/tests.lisp        (`make test` runs it before the boots)
;;;;
;;;; The files in lisp/ are loaded here as they stand, on top of the machine
;;;; that host/clara.lisp makes up, and put through what a boot cannot look
;;;; at closely: every byte the console sends, every pixel it draws, every
;;;; key it is typed. The file that SBCL cannot load, boot.lisp, and the
;;;; functions that the substrate has in C are checked in another way: by
;;;; their names, against Common Lisp's own and against the stand-ins here.
;;;; A check that fails says so, and the run ends with status 1.

(defpackage "CLARA.TESTS"
  (:use "COMMON-LISP"))
(in-package "CLARA.TESTS")

(defvar *root* (merge-pathnames "../../" (make-pathname :name nil :type nil :defaults *load-truename*)))

;; A driver that waits for a device which never answers would wait for
;; good, and the tests with it. They take seconds, so after two minutes
;; something has gone wrong, and the run ends with that.
(sb-thread:make-thread (lambda ()
                         (sleep 120)
                         (format t "host tests: FAILED: still running after two minutes: something waits for what never comes~%")
                         (finish-output)
                         (sb-ext:exit :code 1 :abort t))
                       :name "watchdog")
(defvar *checks* 0)
(defvar *failures* 0)

(defun source (name)
  (merge-pathnames name *root*))

(defun failed (control &rest arguments)
  (incf *failures*)
  (format t "host tests: FAILED: ~?~%" control arguments))

;; FORM has to give EXPECTED, by EQUAL.
(defmacro check (expected form)
  `(let ((expected ,expected)
         (got (handler-case ,form
                (serious-condition (condition) (list :condition (princ-to-string condition))))))
     (incf *checks*)
     (unless (equal expected got)
       (failed "~S gave ~S, not ~S" ',form got expected))))

;; FORM has to signal a condition of TYPE.
(defmacro check-condition (type form)
  `(progn
     (incf *checks*)
     (handler-case (progn ,form (failed "~S did not signal ~S" ',form ',type))
       (,type () nil))))

;;; The sources: each has to load, and without a warning.

(defun load-source (name)
  (handler-bind ((warning (lambda (condition)
                            (unless (typep condition 'style-warning)
                              (failed "~A: ~A" name condition)))))
    (load (source name))))

(load-source "lisp/host/clara.lisp")
(load-source "lisp/compiler.lisp")
(load-source "lisp/host/vm.lisp")              ; the machine that runs what the compiler makes
(load-source "lisp/native.lisp")               ; what makes code for the processor of that, and the two processors,
(load-source "lisp/arm64.lisp")                ; of which a kernel loads its own
(load-source "lisp/x86-64.lisp")
(load-source "lisp/font.lisp")
(load-source "lisp/console.lisp")
(load-source "lisp/draw.lisp")
(load-source "lisp/pci.lisp")
(load-source "lisp/virtio.lisp")
(load-source "lisp/input.lisp")
(load-source "lisp/disk.lisp")
(load-source "lisp/fat.lisp")
(load-source "lisp/listener.lisp")
(load-source "lisp/windows.lisp")
(load-source "lisp/terminal.lisp")
(load-source "lisp/editor.lisp")               ; the two that the kernel leaves on the volume for the launcher to load
(load-source "lisp/files.lisp")
(defvar *defined-applications* clara.windows::*applications*) ; what the files defined, for the tests to put back

;;; Names. boot.lisp is the part of Common Lisp that ClaraOS has in Lisp,
;;; and SBCL has all of it already, so it is read here as text. What it
;;; exports from COMMON-LISP has to be Common Lisp's, what it defines there
;;; has to be exported, or begin with a %, and what it and the substrate
;;; put in CLARA and CLARA.UNSAFE has to be in the stand-ins of host/ too:
;;; a name that is only on one side is a program that loads only there.

(defun file-text (name)
  (with-open-file (stream (source name) :external-format :utf-8)
    (let ((text (make-string (file-length stream))))
      (subseq text 0 (read-sequence text stream)))))

(defun lines (text)
  (let ((start 0) (lines nil))
    (loop
      (let ((end (position #\Newline text :start start)))
        (push (subseq text start end) lines)
        (unless end
          (return (nreverse lines)))
        (setq start (1+ end))))))

(defun words (text)
  (let ((words nil) (start nil))
    (dotimes (i (1+ (length text)) (nreverse words))
      (let ((blank (or (= i (length text)) (find (char text i) " ()'\"
"))))
        (cond ((and blank start)
               (push (string-upcase (subseq text start i)) words)
               (setq start nil))
              ((and (not blank) (not start))
               (setq start i)))))))

(defun starts-with (prefix line)
  (and (>= (length line) (length prefix)) (string= prefix line :end2 (length prefix))))

;; The lines of boot.lisp from the one that begins with FROM up to the one
;; that begins with TO, or to the end.
(defun section (lines from to)
  (let ((rest (if from (member-if (lambda (line) (starts-with from line)) lines) lines)))
    (ldiff rest (and to (member-if (lambda (line) (starts-with to line)) rest)))))

;; The names that a section defines at the start of a line.
(defun definitions (lines)
  (let ((names nil))
    (dolist (line lines (nreverse names))
      (dolist (definer '("(defun " "(defmacro " "(defvar " "(defparameter " "(defconstant "
                         "(define-condition " "(defstruct "))
        (when (starts-with definer line)
          (push (first (words (subseq line (length definer)))) names))))))

;; The names in the first (export '(...)) of a section.
(defun exports (lines)
  (let* ((text (format nil "~{~A~%~}" lines))
         (start (search "(export '(" text))
         (end (and start (search "))" text :start2 start))))
    (and end (words (subseq text (+ start (length "(export '(")) end)))))

(defun external-p (name package)
  (eq (nth-value 1 (find-symbol name package)) :external))

;; The names of the rows of a table in a C file: lines like { "NAME", ...
(defun table-names (name)
  (let ((names nil))
    (dolist (line (lines (file-text name)) (nreverse names))
      (when (starts-with "    { \"" line)
        (push (subseq line 7 (position #\" line :start 7)) names)))))

(let* ((boot (lines (file-text "lisp/boot.lisp")))
       (language (section boot nil "(in-package \"CLARA\")"))
       (clara (section boot "(in-package \"CLARA\")" "(in-package \"CLARA.UNSAFE\")"))
       ;; What is external in COMMON-LISP: the list in boot.lisp, and what the substrate has in C.
       (exported (append (exports language) (table-names "kernel/lisp/builtin.c") (table-names "kernel/lisp/eval.c"))))
  (check t (> (length (exports language)) 100))
  (dolist (name (exports language))
    (incf *checks*)
    (unless (external-p name "COMMON-LISP")
      (failed "boot.lisp exports ~A from COMMON-LISP, which Common Lisp does not have" name)))
  (dolist (name (definitions language))
    (incf *checks*)
    (unless (or (char= (char name 0) #\%) (member name exported :test #'string=))
      (failed "boot.lisp defines ~A in COMMON-LISP and does not export it" name)))
  (dolist (name (append (exports clara) (definitions clara)))
    (incf *checks*)
    (unless (or (char= (char name 0) #\%) (external-p name "CLARA"))
      (failed "boot.lisp has ~A in CLARA, and lisp/host/clara.lisp does not" name))))

(dolist (name (table-names "kernel/lisp/builtin.c"))
  (incf *checks*)
  (let* ((colon (position #\: name))
         (package (if colon (subseq name 0 colon) "COMMON-LISP"))
         (name (if colon (subseq name (1+ colon)) name)))
    (cond ((starts-with "%SET-" name)
           (when colon
             (unless (fboundp (list 'setf (find-symbol (subseq name 5) package)))
               (failed "the substrate has ~A::~A, and under SBCL nothing sets ~A" package name (subseq name 5)))))
          ((char= (char name 0) #\%))
          ((not (external-p name package))
           (failed "the substrate has the function ~A:~A, and SBCL has no such symbol" package name)))))

(dolist (name (table-names "kernel/lisp/eval.c"))
  (incf *checks*)
  (unless (or (string= name "QUASIQUOTE") (external-p name "COMMON-LISP"))
    (failed "the evaluator has the special form ~A, which Common Lisp does not have" name)))

;;; Whatever the compiler makes from here on is translated for the two
;;; processors as well (lisp/native.lisp), each function for both, and the
;;; code is looked at as far as that can be done without a processor to
;;; run it: further down, where the rest about such code is.
(defvar *translations* 0)

(defun code-p (object)
  (and (vectorp object) (= (length object) 13) (vectorp (aref object 0)) (vectorp (aref object 1))))

(defun translation-labels (items)
  (let ((placed nil) (named nil))
    (dolist (item items)
      (cond ((eq (car item) :label) (push (cadr item) placed))
            ((member (car item) '(:jump :jump-if :jump-tag :jump-not-tag :jump-odd :jump-bit-clear :add-over
                                  :sub-over :word))
             (push (car (last item)) named))))
    (cond ((/= (length placed) (length (remove-duplicates placed :test #'eq))) "a label is put in two places")
          ((notevery (lambda (label) (member label placed :test #'eq)) named) "a jump goes to a label that is nowhere"))))

(defun check-translation (code)
  (dolist (machine '(:arm64 :x86-64))
    (let ((clara.native::*machine* machine))
      (multiple-value-bind (items leave fast hidden) (clara.native::lower code)
        (let ((words (clara.native::assemble items (get machine 'clara.native::writer)
                                             (get machine 'clara.native::unit)))
              (title (clara.compiler::code-title code)))
          (incf *checks*)
          (incf *translations*)
          (cond ((null words) (failed "no code for ~A was made of ~S" machine title))
                ((notevery (lambda (word) (typep word '(unsigned-byte 32))) words)
                 (failed "the code for ~A of ~S is not words of 32 bits" machine title))
                ((not (and (eql (car leave) 12) (eql (car fast) 20)))
                 (failed "the code for ~A of ~S begins with ~S and ~S bytes, and not the 12 and 20 of machine.h"
                         machine title (car leave) (car fast)))
                ((translation-labels items)
                 (failed "in the code for ~A of ~S, ~A" machine title (translation-labels items)))
                ((not (eql hidden (if (clara.native::plain-p (aref code 0)) 0 2)))
                 (failed "a call of ~S hides ~S words" title hidden)))))))
  (loop for constant across (aref code 1)
        when (code-p constant) do (check-translation constant)))

(clara.native:start)
(setq clara.native:*translate* t
      clara.compiler::*translator* (lambda (code)
                                     (when clara.native:*translate*
                                       (check-translation code))
                                     (clara.native::translate-compiled code)))

;;; The compiler. What it makes of a form runs here on the machine of
;;; host/vm.lisp, and SBCL says what the form means: every form below is
;;; evaluated twice, by SBCL's own evaluator and compiled by
;;; lisp/compiler.lisp, and the two have to give the same values, or both
;;; an error. The kernel holds its compiler against its evaluator in the
;;; same way, with the texts of its self-test (kernel/lisp/lisp.c).

;; The instructions are the kernel's, by their numbers, and the special
;; forms the evaluator's, each with as many parts.
(check (table-names "kernel/lisp/vm.c")
       (mapcar (lambda (row) (symbol-name (car row))) clara.compiler::*operations*))
(dolist (line (lines (file-text "kernel/lisp/eval.c")))
  (when (starts-with "    { \"" line)
    (let* ((parts (words (substitute #\Space #\, line)))
           (known (assoc (second parts) clara.compiler::*special-forms* :test #'string=)))
      (incf *checks*)
      (cond ((string= (second parts) "QUASIQUOTE"))     ; the reader's own, which SBCL reads another way
            ((null known)
             (failed "the evaluator has the special form ~A, and the compiler does not" (second parts)))
            ((not (equal (list (second known) (third known))
                         (list (parse-integer (fourth parts))
                               (and (string/= (fifth parts) "LISP_MANY") (parse-integer (fifth parts))))))
             (failed "the compiler takes ~A with ~A to ~A parts, and the evaluator with ~A to ~A"
                     (second parts) (second known) (third known) (fourth parts) (fifth parts)))))))

(check '(clara.compiler::compile-lambda clara.compiler::list-function clara.compiler:evaluate)
       (clara.host:provided-compiler))

;; The instructions after FAIL stand for functions in C, each under the
;; name of its function, which it calls when it cannot do the work itself:
;; so the function has to be one of builtin.c's, and take as many arguments
;; as the instruction does.
(let ((known (cdr (member :fail clara.compiler::*operations* :key #'car)))
      (table (lines (file-text "kernel/lisp/builtin.c"))))
  (check 20 (length known))
  (dolist (row known)
    (incf *checks*)
    (let* ((function (find-symbol (symbol-name (car row)) "COMMON-LISP"))
           (arguments (- 1 (second row)))
           (line (find-if (lambda (line) (starts-with (format nil "    { \"~A\", " (car row)) line)) table))
           (parts (and line (words (substitute #\Space #\, line)))))
      (cond ((not (and function (eq (get function 'clara.compiler::instruction) (car row))))
             (failed "the machine has the instruction ~A, and the compiler has no function for it" (car row)))
            ((null parts)
             (failed "the machine has the instruction ~A, and no function in C has that name" (car row)))
            ((or (< arguments (parse-integer (fourth parts)))
                 (and (string/= (fifth parts) "LISP_MANY") (> arguments (parse-integer (fifth parts)))))
             (failed "the instruction ~A takes ~A arguments, and the function in C ~A to ~A"
                     (car row) arguments (fourth parts) (fifth parts)))))))

;; Such an instruction looks whether its name still means the function in
;; C, in a word that is kept right where a symbol is given a function
;; (lisp_set_function, kernel/lisp/vm.c). So nothing else may write the
;; function of a symbol, apart from the evaluator as it starts, which has
;; the machine look afterwards.
(let ((writes nil))
  (dolist (file (directory (merge-pathnames "*.c" (source "kernel/lisp/"))))
    (let ((name (format nil "kernel/lisp/~A.c" (pathname-name file))))
      (dolist (line (lines (file-text name)))
        (when (and (search "lisp_as_symbol(" line) (search ")->function = " line))
          (push name writes)))))
  (check '("kernel/lisp/eval.c" "kernel/lisp/eval.c" "kernel/lisp/vm.c") (sort writes #'string<)))

;; What a form gives: its values, or :ERROR.
(defun outcome (function form)
  (handler-case (multiple-value-list (funcall function form))
    (error () :error)))

(defun reference (form)
  (let ((sb-ext:*evaluator-mode* :interpret))
    (eval form)))

(defmacro same (&rest forms)
  `(dolist (form ',forms)
     (incf *checks*)
     (let ((wanted (outcome #'reference form)) (got (outcome #'clara.compiler:evaluate form)))
       (unless (equal wanted got)
         (failed "compiled, ~S gave ~S, and it means ~S" form got wanted)))))

(defvar *cv* 1)
(defun cv () *cv*)

(same
 ;; what is its own value, variables, and the plainest forms
 42 "text" #\a :key t nil '(a . b) 'sym
 (let ((a 1) (b 2)) (list a b))
 (let ((a 1)) (let ((a 2) (b a)) (list a b)))
 (let* ((a 1) (b (+ a 1))) (list a b))
 (let (a (b)) (list a b))
 (let ((a 1) (b 2)) (setq a b b 5) (list a b (setq a 7) a))
 (setq)
 (if nil 1 2) (if 0 1) (if nil 1) (progn) (progn 1 2 3)
 (let ((x 3)) (cond ((= x 1) 'one) ((= x 3) 'three) (t 'many)))
 (list (and) (and 1 2 3) (and 1 nil 3) (or) (or nil 2 3) (or nil nil))
 (let ((x 1)) (declare (ignorable x)) "not documentation")
 (funcall (lambda (x) "documentation" (declare (ignorable x)) (+ x 1)) 2)
 (eq "a" "a")
 ;; functions and what they take
 ((lambda (x) (* x x)) 7)
 (funcall (lambda (&optional (a 1) (b (+ a 1) b-p)) (list a b b-p)))
 (funcall (lambda (&optional (a 1) (b (+ a 1) b-p)) (list a b b-p)) 5 6)
 (funcall (lambda (a &rest more) (list a more)) 1 2 3)
 (funcall (lambda (&key a (b 2) ((:see c) 3 c-p)) (list a b c c-p)) :b 5 :see 6)
 (funcall (lambda (&key a) a) :b 1)
 (funcall (lambda (&key a) a) :b 1 :allow-other-keys t)
 (funcall (lambda (&key a &allow-other-keys) a) :b 1 :a 2 :a 3)
 (funcall (lambda (&key a) a) :a)
 (funcall (lambda (&rest all &key a) (list a all)) :a 1)
 (funcall (lambda (a &aux (b (* a 2))) (list a b)) 4)
 (funcall (lambda (a b) (list a b)) 1)
 (funcall (lambda (a) a) 1 2)
 (funcall (lambda (a &optional b &rest c &key d) (list a b c d)) 1 2 :d 4)
 (apply (lambda (&rest all) (length all)) (make-list 300 :initial-element 0))
 ;; closures: a variable that is shared, and one that is set as well
 (let ((c (let ((n 0)) (lambda () (setq n (+ n 1)))))) (funcall c) (funcall c) (funcall c))
 (let ((n 0)) (let ((up (lambda () (setq n (+ n 1)))) (down (lambda () (setq n (- n 1)))))
                (funcall up) (funcall up) (funcall down) n))
 (let ((made nil)) (dolist (x '(1 2 3)) (push (lambda () x) made)) (mapcar #'funcall made))
 (let ((x 5)) (funcall (funcall (funcall (lambda () (lambda () (lambda () x)))))))
 (let ((n 0)) (funcall (lambda () (funcall (lambda () (setq n (+ n 5)))))) n)
 (funcall (lambda (a) (funcall (lambda () (setq a (* a 2)))) a) 4)
 (funcall (lambda (a &optional (b (lambda () a))) (setq a 9) (funcall b)) 1)
 (let ((x 1)) (flet ((f (y) (+ x y))) (setq x 10) (f 1)))
 (flet ((add (a b) (* a b))) (list (add 3 4) (funcall #'add 2 5)))
 (flet ((f () 1)) (flet ((f () (+ (f) 1))) (f)))
 (labels ((even (n) (if (= n 0) t (odd (- n 1)))) (odd (n) (if (= n 0) nil (even (- n 1)))))
   (list (even 10) (odd 7) (funcall #'even 3)))
 (labels ((fact (n) (if (< n 2) 1 (* n (fact (- n 1)))))) (fact 10))
 (labels ((tally (n acc) (if (= n 0) acc (tally (- n 1) (cons n acc))))) (tally 5 nil))
 (let ((f (labels ((self (n) (if (= n 0) 'done (self (- n 1))))) #'self))) (funcall f 3))
 ;; blocks: left by a jump, from a function inside, with words on the stack in the way
 (block b 1 (return-from b 2) 3)
 (block b (funcall (lambda () (return-from b 5))) 6)
 (block nil (dolist (x '(1 2 3)) (when (= x 2) (return x))))
 (block outer (block inner (return-from outer 1)) 2)
 (+ 1 (block b (+ 10 (return-from b 5))))
 (block b (list 1 (return-from b 2) 3))
 (list 1 (block b (list 2 (funcall (lambda () (return-from b 3))) 4)) 5)
 (block b (block b (return-from b 1)) 2)
 (let ((f (block b (lambda () (return-from b 1))))) (funcall f))
 (block b (mapcar (lambda (x) (if (= x 2) (return-from b x) x)) '(1 2 3)))
 (list 1 (block b (funcall (lambda (x) (if x (return-from b 2) 3)) nil)) 4)
 (list 0 (block b (list 1 (car '(2)) (return-from b 3) 4)) 5)
 (multiple-value-list (funcall (lambda (f) (block b (funcall f (lambda () (return-from b 1))) (floor 7 2) 5))
                               (lambda (g) g)))
 ;; tags
 (let ((n 0) (sum 0)) (tagbody again (setq sum (+ sum n) n (+ n 1)) (if (< n 5) (go again))) sum)
 (let ((x nil)) (tagbody (go b) a (setq x (cons 'a x)) (go c) b (setq x (cons 'b x)) (go a) c) x)
 (let ((n 0)) (tagbody (funcall (lambda () (go out))) (setq n 1) out) n)
 (let ((n 0) (f nil))
   (tagbody (setq f (lambda () (go again))) (go start)
    again (setq n (+ n 1)) (if (< n 3) (funcall f)) (go out)
    start (funcall f)
    out)
   n)
 (let ((n 0)) (tagbody 1 (setq n (+ n 1)) (if (< n 4) (go 1)) 2) n)
 (let ((log nil)) (dotimes (i 3) (tagbody (when (= i 1) (go skip)) (push i log) skip)) log)
 (let ((f (tagbody (lambda () (go out)) out))) f)
 ;; catch and throw
 (catch 'c 1 (throw 'c 2) 3)
 (catch 'c (catch 'd (throw 'c 1)) 2)
 (catch 'c (funcall (lambda () (throw 'c 4))) 5)
 (multiple-value-list (catch 'c (throw 'c (values 1 2))))
 (list 1 (catch 'c (list 2 (throw 'c 3))) 4)
 (catch 'c (catch 'c (throw 'c 1)) 2)
 ;; several values, and none
 (values 1 2 3) (values)
 (list (values 1 2) (values))
 (multiple-value-bind (a b c) (values 1 2) (list a b c))
 (multiple-value-bind () (values 1 2) 3)
 (multiple-value-call #'list (values 1 2) 3 (values) (values 4 5))
 (multiple-value-call #'list)
 (multiple-value-call (lambda (&rest all) all) 1 (floor 7 2))
 (multiple-value-prog1 (values 1 2) (values 3 4))
 (list (multiple-value-prog1 1 2) (multiple-value-prog1 (values 3 4) 5))
 (block b (return-from b (values 1 2)))
 (if t (values 1 2)) (let () (values 1 2)) (progn (values 1 2) 3)
 (funcall (lambda () (floor 17 5)))
 (multiple-value-list (funcall (lambda () (values))))
 (multiple-value-list (let ((x 1)) (values x 2 3)))
 (multiple-value-list (catch 'c (values 1 2)))
 (multiple-value-list (multiple-value-call #'values (values 1 2) (values 3 4)))
 (multiple-value-list (block b (multiple-value-call #'list 1 (return-from b (values 7 8)))))
 (multiple-value-list (block b (funcall (lambda () (return-from b (values 1 2))))))
 (block b (funcall (lambda () (values) (return-from b 7))))
 (multiple-value-list (multiple-value-call #'list (progn (floor 7 2) 5) (values)))
 (list (catch 'c (funcall (lambda () (values) (throw 'c 7)))) (multiple-value-list (progn (floor 7 2) 5)))
 (multiple-value-list (funcall (lambda () (floor 7 2) 5)))
 (funcall (lambda () (values 8 9)
            (list (multiple-value-list (multiple-value-prog1 5 (values 3 4))) (multiple-value-bind (a b) 6 (list a b))
                  (unwind-protect 7 (identity 1)) (catch 'c (throw 'c 4)))))
 (list (funcall (lambda () (block b (catch 'x (return-from b 1)))))
       (funcall (lambda () (block b (handler-case (return-from b 2) (error () 3)))))
       (catch 'x (throw 'x 4)) (handler-case (car 5) (error () 6)))
 (list (multiple-value-call #'+ 1 (block b (multiple-value-prog1 5 (return-from b 2)))))
 ;; unwind-protect
 (let ((log nil)) (list (unwind-protect 1 (push 'cleaned log)) log))
 (multiple-value-list (unwind-protect (values 1 2) (values 3 4)))
 (let ((log nil)) (list (block b (unwind-protect (return-from b 1) (push 'cleaned log))) log))
 (multiple-value-list (catch 'c (unwind-protect (throw 'c (values 1 2)) (values 3 4))))
 (let ((n 0)) (tagbody (unwind-protect (go out) (setq n (+ n 1))) out) n)
 (block b (unwind-protect (return-from b 1) (return-from b 2)))
 (let ((log nil)) (list (handler-case (unwind-protect (error "oops") (push 'cleaned log)) (error () 'handled)) log))
 (let ((log nil)) (catch 'c (unwind-protect (unwind-protect (throw 'c 1) (push 1 log)) (push 2 log))) log)
 (let ((log nil)) (list (catch 'c (funcall (lambda () (unwind-protect (throw 'c 1) (push 'inside log))))) log))
 (let ((log nil)) (unwind-protect (push 1 log) (unwind-protect (push 2 log) (push 3 log))) log)
 (let ((log nil)) (list (block b (unwind-protect 1 (push 'a log) (return-from b 2))) log))
 (let ((n 0)) (dotimes (i 3) (unwind-protect (setq n (+ n 1)) (setq n (+ n 10)))) n)
 ;; conditions
 (handler-case (error "x") (error () 'caught))
 (handler-case (+ 1 2) (error () 'never))
 (handler-case (values 1 2) (error () 'never))
 (handler-case (floor 7 2) (error () 'never) (:no-error (q r) (list r q)))
 (handler-case (car 5) (type-error () 'type) (error () 'other))
 (handler-case (car 5) (program-error () 'program) (error () 'other))
 (handler-case (handler-case (car 5) (program-error () 'inner)) (error () 'outer))
 (handler-case (handler-case (error "a") (error () (car 5))) (type-error () 'from-the-clause))
 (handler-case (funcall (lambda () (error "deep"))) (error (c) (princ-to-string c)))
 (let ((x 1)) (handler-case (progn (setq x 2) (error "x")) (error () x)))
 (handler-case (error "x") (error (c) (setq c 5) c))
 (handler-case (handler-case (error "x") (:no-error () 'fine)) (error () 'outside))
 (list 1 (handler-case (list 2 (error "x")) (error () 3)) 4)
 (list 1 (handler-case (error "x") (error () 2) (:no-error () 3)) (handler-case 5 (error () 2) (:no-error (v) (+ v 1))) 4)
 (handler-case 1)
 (handler-case (values 1 2) (:no-error (&rest all) all))
 (car (multiple-value-list (ignore-errors (car 5) 7)))
 (ignore-errors (values 1 2))
 ;; special variables: bound, and put back whichever way control leaves
 (list (let ((*cv* 2)) (cv)) (cv))
 (list (let* ((*cv* 3) (deeper (cv))) deeper) (cv))
 (list (let ((*cv* 4) (other (cv))) (list (cv) other)) (cv))
 (list (funcall (lambda (*cv*) (cv)) 7) (cv))
 (list (funcall (lambda (&optional (*cv* 8)) (cv))) (cv))
 (list (catch 'out (let ((*cv* 8)) (throw 'out (cv)))) (cv))
 (list (block b (let ((*cv* 9)) (return-from b (cv)))) (cv))
 (list (block b (let ((*cv* 9)) (funcall (lambda () (return-from b (cv)))))) (cv))
 (list (let ((n 0)) (tagbody (let ((*cv* 9)) (setq n (cv)) (go out)) out) n) (cv))
 (let ((n 0)) (tagbody (let ((*cv* 9)) (funcall (lambda () (go out)))) out (setq n (cv))) n)
 (let ((*cv* 5)) (setq *cv* 6) (cv))
 (list (handler-case (let ((*cv* 9)) (error "x")) (error () (cv))) (cv))
 (list (multiple-value-bind (*cv* b) (values 4 5) (list (cv) b)) (cv))
 (list (unwind-protect (let ((*cv* 3)) (cv)) (setq *cv* 1)) (cv))
 (let ((log nil)) (list (handler-case (unwind-protect (let ((*cv* 9)) (error "x")) (push (cv) log)) (error () (cv))) log))
 (list (let ((*cv* 2)) (let ((*cv* 3)) (cv))) (cv))
 ;; a list taken apart
 (destructuring-bind (a (b &optional (c 5)) &rest d) '(1 (2) 3 4) (list a b c d))
 (destructuring-bind (first second . others) (list 1 2 3 4) (list first second others))
 (destructuring-bind (&whole all &key x (y (+ x 6))) '(:x 1) (list x y all))
 (destructuring-bind (a &optional (b 2 b-p)) '(1) (list a b b-p))
 (destructuring-bind (a &key (b 2 b-p) ((:see c))) '(1 :see 3) (list a b b-p c))
 (destructuring-bind (a b) '(1) (list a b))
 (destructuring-bind (a) '(1 2) a)
 (destructuring-bind (a (b)) '(1 2) (list a b))
 (destructuring-bind (&key a) '(:b 1) a)
 (destructuring-bind (&key a) '(:a) a)
 (destructuring-bind (a &aux (b (* a 2))) '(4) (list a b))
 ;; macros
 (macrolet ((twice (x) (list '* 2 x))) (twice 21))
 (macrolet ((twice (x) (list '* 2 x))) (flet ((twice (x) (+ x 1))) (twice 21)))
 (flet ((twice (x) (+ x 1))) (macrolet ((twice (x) (list '* 2 x))) (twice 21)))
 (progn (defmacro cm-twice (x) (list '* 2 x)) (flet ((cm-twice (x) (+ x 1))) (cm-twice 5)))
 (macrolet ((pair ((a b) &body body) (list* 'let (list (list a 1) (list b 2)) body))) (pair (x y) (list y x)))
 (progn (defmacro cm-swap (a b) (list 'let (list (list 'old a)) (list 'setq a b b 'old)))
        (let ((x 1) (y 2)) (cm-swap x y) (list x y)))
 ;; the forms that define, and the rest
 (progn (defun c-add (a b) "The sum." (+ a b)) (list (c-add 1 2) (funcall 'c-add 3 4) (funcall #'c-add 5 6)))
 (progn (defun c-early (n) (if (< n 0) (return-from c-early 'negative)) n) (list (c-early 1) (c-early -1)))
 (progn (defun c-redefined () (defun c-redefined () 'new) 'old) (list (funcall 'c-redefined) (c-redefined)))
 (progn (defparameter *cp* 6) (defvar *cp* 7) *cp*)
 (progn (defvar *cd* 3) (let ((*cd* 4)) (symbol-value '*cd*)))
 (eval-when (:execute) 1 2) (eval-when (:compile-toplevel) 1) (locally (declare (optimize speed)) 3) (the fixnum 4)
 (funcall (function (lambda (x) (+ x 1))) 1)
 (mapcar #'1+ '(1 2 3))
 (funcall 'list 1 2)
 ;; the functions that the machine has instructions for: what they give, with any number of arguments,
 ;; as the one value of a form, with arguments that they do not take, and by their names
 (let ((a '(1 2)) (b 2))
   (list (car a) (cdr a) (cons b a) (not a) (null b) (consp a) (atom a) (eq a a) (+ b 1) (- b 1) (* b 3) (1+ b) (1- b)
         (< b 3) (> b 3) (<= b 2) (>= b 3) (= b 2) (aref (vector 5 6) 1) (svref (vector 7 8) 0)))
 (list (+) (+ 1) (+ 1 2 3) (- 5) (- 9 1 2) (* 2 3 4) (< 1 2 3) (= 2 2 2) (>= 3 3 1) (car nil) (cdr nil))
 (multiple-value-list (funcall (lambda (x) (floor 7 2) (car x)) '(1 2)))
 (multiple-value-list (progn (floor 7 2) (+ 1 2)))
 (multiple-value-call #'list (floor 7 2) (car '(a)) (1+ 2))
 (progn (car '(1)) (+ 1 2) (cons 1 2) 3)
 (let ((n 0)) (dotimes (i 10) (setq n (+ n (* i 2)))) n)
 (block b (+ 1 (return-from b 2)))
 (list 1 (block b (cons 2 (funcall (lambda () (return-from b 3))))) 4)
 (catch 'c (+ 1 (throw 'c (* 2 3))))
 (handler-case (+ 1 (car 5)) (type-error () 'caught))
 (car 5) (+ 1 'a) (svref (vector 1) 3) (cons 1) (car)
 (list (funcall #'car '(1)) (apply '+ '(1 2)) (mapcar #'1+ '(1 2)) (funcall '< 1 2))
 ;; macros that the compiler makes functions of: of MACROLET, which see the macros around them,
 ;; and of DEFMACRO, which see the variables
 (macrolet ((make-form (op) (list 'quote (list op 1 2)))) (macrolet ((sum () (make-form +))) (sum)))
 (macrolet ((taken (&whole all (a b) &optional (c 3) &rest more) (list 'quote (list a b c more all))))
   (list (taken (1 2)) (taken (1 2) 4 5 6)))
 (macrolet ((keyed (&key a (b 2)) (list 'quote (list a b)))) (list (keyed) (keyed :b 5 :a 1)))
 (macrolet ((dotted (a . more) (list 'quote (list a more)))) (dotted 1 2 3))
 (macrolet ((early (x) (if x (return-from early 'left) 'stayed))) (list (early t) (early nil)))
 (progn (defmacro cm-taken (&whole all (a b) &optional (c 3) &rest more) (list 'quote (list a b c more all)))
        (list (cm-taken (1 2)) (cm-taken (1 2) 4 5 6)))
 (progn (let ((n 5)) (defmacro cm-five-more (x) (list '+ x n))) (cm-five-more 1))
 (progn (defmacro cm-early (x) (if x (return-from cm-early ''left) ''stayed)) (list (cm-early t) (cm-early nil))))

;; A form is taken a part at a time, and so is what a macro makes of it: a
;; DEFVAR counts for the part after it. (SBCL is not asked: it would have
;; made the variable special before the compiler saw the form.)
(check 2 (clara.compiler:evaluate '(progn (defvar *apart-here* 1) (let ((*apart-here* 2)) (symbol-value '*apart-here*)))))
(defmacro define-and-bind ()
  '(progn (defvar *bound-at-once* 1) (let ((*bound-at-once* 2)) (symbol-value '*bound-at-once*))))
(check 2 (clara.compiler:evaluate '(define-and-bind)))

;; Forms that are not what they should be fail when they are evaluated, and
;; not before: in the words that the evaluator has for them.
(defun failing (form)
  (handler-case (progn (clara.compiler:evaluate form) :nothing)
    (error (condition) (princ-to-string condition))))

(check "(IF) has the wrong number of parts for IF" (failing '(if)))
(check 'fine (clara.compiler:evaluate '(if t 'fine (if))))
(check "5 cannot be the name of a variable" (failing '(let ((5 1)) 2)))
(check "T cannot be set: it is not a variable" (failing '(setq t 1)))
(check "RETURN-FROM NOWHERE, and no block of that name is in sight" (failing '(return-from nowhere 1)))
(check "GO to NOWHERE, and no TAGBODY in sight has that tag" (failing '(go nowhere)))
(check "1 is not the name of a function, so (1 2) is not a form" (failing '(1 2)))
(check "a DECLARE where a form has to be: it belongs at the start of a body" (failing '(list (declare))))
(check "RETURN-FROM B, a block that has been left already"
       (failing '(funcall (block b (lambda () (return-from b 1))))))
(check "HANDLER-CASE has a clause for NO-SUCH-TYPE, which is not the name of a type of condition"
       (failing '(handler-case 1 (no-such-type () 2))))
(check-condition program-error (clara.compiler:evaluate '(if)))
(check-condition control-error (clara.compiler:evaluate '(go nowhere)))
(check-condition program-error (clara.compiler:evaluate '(funcall (lambda (a) a))))
(check-condition error (clara.compiler::compile-lambda '(not a lambda)))
;; A macro that the compiler made says what is wrong with a form in the
;; words that the evaluator has for its own.
(clara.compiler:evaluate '(defmacro cm-keyed (&key a) (list 'quote a)))
(check "#<MACRO CM-TAKEN> got too few arguments" (failing '(cm-taken)))
(check "#<MACRO CM-TAKEN> got too few arguments" (failing '(cm-taken (1))))
(check "#<MACRO CM-TAKEN> got too many arguments" (failing '(cm-taken (1 2 3))))
(check "#<MACRO CM-KEYED> does not take the keyword argument :C" (failing '(cm-keyed :c 1)))
(check "#<MACRO CM-KEYED> got an odd number of keyword arguments" (failing '(cm-keyed :a)))
(check "&ENVIRONMENT in a lambda list, which the evaluator does not know yet"
       (progn (clara.compiler:evaluate '(defmacro cm-environment (&environment e) e))
              (failing '(cm-environment))))
;; So does a macro of MACROLET, and the error is of the type that it was.
(check 'a-program-error
       (clara.compiler:evaluate '(handler-case (macrolet ((needs-one (a) a)) (needs-one))
                                  (program-error () 'a-program-error))))
;; A macro that fails is the form's own failure, when the form is reached.
(defmacro always-wrong () (error "the macro went wrong"))
(check "the macro went wrong" (failing '(always-wrong)))
(check 'fine (funcall (clara.compiler::compile-lambda '(lambda () (if t 'fine (always-wrong))))))

;; Backquote, as the kernel's reader hands it over: SBCL reads ` another
;; way, so the forms are made here, with symbols of the tests' own.
(let ((clara.compiler::*quasiquote* 'quasi) (clara.compiler::*unquote* 'unq) (clara.compiler::*splice* 'spl))
  (flet ((backquoted (form)
           (funcall (clara.compiler::compile-lambda
                     (list 'lambda '(x y) (clara.compiler::quasi form 1)))
                    2 (list 3 4))))
    (check '(1 2 3 4 . 5) (backquoted '(1 (unq x) (spl y) . 5)))
    (check '(a . 2) (backquoted '(a unq x)))
    (check '(a 3 4 d (3 4)) (backquoted '(a (spl y) d (unq y) (spl nil))))
    (check '(quasi (a (unq 2))) (backquoted '(quasi (a (unq (unq x))))))
    (check '((a 2) "b") (backquoted '((a (unq x)) "b")))
    (check 'x (backquoted 'x))
    (let ((list (backquoted '(a b))))          ; made anew each time, as the evaluator makes it
      (check nil (eq list (backquoted '(a b)))))))

;; The listing of a function, and of a function inside it.
(check (format nil "~{~A~%~}" '("LISTED: 1 local variable, 3 words of stack"
                                "0   CONST LIST"
                                "1   LOCAL 0"
                                "2   CONST 1"
                                "3   +"
                                "4   CALL 1"
                                "5   RETURN"))
       (let ((clara.native:*translate* nil))  ; a listing says when a function is translated: further down
         (with-output-to-string (*standard-output*)
           (clara.compiler::list-function (clara.compiler::compile-lambda '(lambda (x) (list (+ x 1))) 'listed)))))
(check t (let* ((clara.native:*translate* nil)
                (text (with-output-to-string (*standard-output*)
                        (clara.compiler::list-function
                         (clara.compiler::compile-lambda '(lambda (x) (lambda () x)))))))
           (and (search "CLOSURE (LAMBDA ()) 1" text)
                (search (format nil "~%(LAMBDA ()): 0 local variables, 1 word of stack~%0   CLOSED 0~%") text)
                t)))
(check t (and (search "written in C" (with-output-to-string (*standard-output*)
                                       (clara.compiler::list-function #'car)))
              t))
(check nil (clara.unsafe:compiled-function-code #'car))
(check-condition error (clara.unsafe:make-compiled-function (vector 1 2 3)))

;; Forms that nobody wrote: each is put together at random from the forms
;; that bind, set, call, close over, leave and clean up, and has to give
;; compiled what SBCL makes of it. The numbers are the same on every run.
(defun random-form (depth variables blocks catching state)
  (flet ((sub (&optional (variables variables) (blocks blocks) (catching catching))
           (random-form (1- depth) variables blocks catching state))
         (pick (list)
           (nth (random (length list) state) list)))
    (if (or (<= depth 0) (zerop (random 7 state)))
        (if (and variables (zerop (random 2 state))) (pick variables) (random 10 state))
        (ecase (random 17 state)
          (0 `(+ ,(sub) ,(sub)))
          (1 `(if (< ,(sub) ,(sub)) ,(sub) ,(sub)))
          (2 (let ((v (gensym "V"))) `(let ((,v ,(sub))) ,(sub (cons v variables)))))
          (3 (if variables `(setq ,(pick variables) ,(sub)) (sub)))
          (4 `(progn ,(sub) ,(sub)))
          (5 (let ((v (gensym "V"))) `(funcall (lambda (,v) ,(sub (cons v variables))) ,(sub))))
          (6 (let ((b (gensym "B"))) `(block ,b ,(sub variables (cons b blocks)))))
          (7 (if blocks `(return-from ,(pick blocks) ,(sub)) (sub)))
          (8 `(catch 'thrown ,(sub variables blocks t)))
          (9 (if catching `(throw 'thrown ,(sub)) (sub)))
          (10 `(unwind-protect ,(sub) ,(if variables `(setq ,(pick variables) ,(sub)) (sub))))
          (11 `(multiple-value-call #'+ (values ,(sub) ,(sub)) ,(sub)))
          (12 (let ((f (gensym "F"))) `(let ((,f (lambda () ,(sub)))) (+ (funcall ,f) (funcall ,f)))))
          (13 (let ((f (gensym "F")) (v (gensym "V")))
                `(flet ((,f (,v) ,(sub (cons v variables)))) (,f ,(sub)))))
          (14 `(multiple-value-prog1 ,(sub) ,(sub)))
          (15 (let ((v (gensym "V")) (w (gensym "W")))
                `(multiple-value-bind (,v ,w) (values ,(sub) ,(sub)) ,(sub (list* v w variables)))))
          (16 (let ((v (gensym "V")))
                `(let ((*cv* ,(sub))) (+ (cv) (let ((,v (cv))) ,(sub (cons v variables)))))))))))

(let ((state (sb-ext:seed-random-state 20261118)))
  (dotimes (i 400)
    (let* ((form `(let ((a 1) (b 2)) (list ,(random-form 6 '(a b) nil nil state) a b (cv))))
           (wanted (outcome #'reference form)) (got (outcome #'clara.compiler:evaluate form)))
      (incf *checks*)
      (unless (equal wanted got)
        (failed "compiled, ~S gave ~S, and it means ~S" form got wanted)))))

;;; Code for the processor (lisp/native.lisp). SBCL runs none of it, and
;;; the kernels run all of it: every text of the self-test at every boot
;;; from the files, on both processors, with the evaluator's answers
;;; (kernel/lisp/lisp.c). What is looked at here is what a boot does not
;;; say. Every function that the compiler made above was translated for
;;; both processors, whichever of them this host has, and each time the
;;; code had to begin as the kernel counts on, every label had to be
;;; somewhere, and a call had to hide its two words exactly when the
;;; function makes records or binds special variables.
(setq clara.native:*translate* nil
      clara.compiler::*translator* 'clara.native::translate-compiled)
(incf *checks*)
(when (< *translations* 2000)
  (failed "the compiler's forms were to be translated for both processors, and ~D translations were made"
          *translations*))
(check '(nil t t "QUICK: 1 local variable, 2 words of stack, translated for the processor")
       (let* ((before (clara.compiler::compile-lambda '(lambda (x) (+ x 1)) 'slow))
              (clara.native:*translate* t)
              (after (clara.compiler::compile-lambda '(lambda (x) (+ x 1)) 'quick)))
         (list (clara.native:translated-p before)
               (clara.native:translated-p after)
               (progn (clara.native:translate before) (clara.native:translated-p before))
               (let ((listing (with-output-to-string (*standard-output*) (clara.compiler::list-function after))))
                 (subseq listing 0 (position #\Newline listing))))))
(check-condition error (clara.native:translate #'car))

;; Where the words lie that such code reads is the kernel's to say
;; (NATIVE-LAYOUT, kernel/lisp/native.c). The stand-in here has to say
;; something for every name that the kernel has, and nothing else, and the
;; two places where code begins are machine.h's.
(check (let ((names nil) (inside nil))
         (dolist (line (lines (file-text "kernel/lisp/native.c")) (sort names #'string<))
           (cond ((search "} layout[] = {" line) (setq inside t))
                 ((and inside (starts-with "    };" line)) (setq inside nil))
                 ((and inside (starts-with "        { \"" line))
                  (push (subseq line 11 (position #\" line :start 11)) names)))))
       (sort (loop for (name) on (clara.unsafe:native-layout) by #'cddr collect (symbol-name name)) #'string<))
(dolist (pair '(("NATIVE_LEAVE" :leave) ("NATIVE_FAST" :fast)))
  (check (list (first pair) (getf (clara.unsafe:native-layout) (second pair)))
         (let ((line (find-if (lambda (line) (starts-with (format nil "#define ~A " (first pair)) line))
                              (lines (file-text "kernel/lisp/machine.h")))))
           (list (first pair) (and line (parse-integer (second (words (subseq line 8)))))))))

;; Each instruction of the processor that lisp/native.lisp makes up, as
;; the two real ones write it: the bytes here are what LLVM's assembler
;; writes for the same instruction (llvm-mc 21, by hand, once), so an
;; instruction that is written another way has to be shown to mean the
;; same before the bytes are changed. L is a label 1000 bytes into the
;; code, and the instruction is at its beginning, or 2000 bytes in when it
;; says :BACK.
(defun written (machine item at)
  (let* ((clara.native::*final* t)
         (pieces (funcall (get machine 'clara.native::writer) item at)))
    (format nil "~{~2,'0X~}"
            (if (= (get machine 'clara.native::unit) 4)
                (loop for word in pieces append (loop for i below 4 collect (ldb (byte 8 (* 8 i)) word)))
                pieces))))

(dolist (row '(
           ((:load :a :vsp -8) "80825FF8" "488B4BF8")
           ((:load :e :rt 216) "696E40F9" "4D8B97D8000000")
           ((:load :e :consts 32760) "C9FE7FF9" "4D8B96F87F0000")
           ((:load :e :consts 32768) "100090D2C96A70F8" "4D8B9600800000")
           ((:load :e :consts 0) "C90240F9" "4D8B16")
           ((:load :a :e 3) "203140F8" "498B4A03")
           ((:load :e :locals -8) "A9825FF8" "4C8B56F8")
           ((:load :consts :a 11) "16B040F8" "4C8B710B")
           ((:load :b :vsp -4096) "F0FF8192816A70F8" "488B9300F0FFFF")
           ((:store :f :vsp -8) "8A821FF8" "4C895BF8")
           ((:store :vsp :rt 0) "740200F9" "49891F")
           ((:store :e :locals 800) "A99201F9" "4C899620030000")
           ((:store :f :e 3) "2A3100F8" "4D895A03")
           ((:load32 :e :rt 40) "692A40B9" "458B5728")
           ((:load32 :e :rt 44) "692E40B9" "458B572C")
           ((:store32 :e :rt 48) "693200B9" "45895730")
           ((:load8 :e :a -5) "09B05F38" "440FB651FB")
           ((:push :e) "898600F8" "4C89134883C308")
           ((:push :nil) "978600F8" "48893B4883C308")
           ((:push :a) "808600F8" "48890B4883C308")
           ((:pop :e) "898E5FF8" "4883EB084C8B13")
           ((:pop :a) "808E5FF8" "4883EB08488B0B")
           ((:move :a :locals) "E00315AA" "4889F1")
           ((:move :f :nil) "EA0317AA" "4989FB")
           ((:move :locals :vsp) "F50314AA" "4889DE")
           ((:move :e :b) "E90301AA" "4989D2")
           ((:const :b 0) "010080D2" "BA00000000")
           ((:const :b 5) "A10080D2" "BA05000000")
           ((:const :e 1) "290080D2" "41BA01000000")
           ((:const :b 65536) "2100A0D2" "BA00000100")
           ((:const :b 4886718345) "21F18CD2A168A4F22100C0F2" "48BA8967452301000000")
           ((:const :b -5) "81008092" "48C7C2FBFFFFFF")
           ((:const :b -1) "01008092" "48C7C2FFFFFFFF")
           ((:const :b -65536) "E1FF9F92" "48C7C20000FFFF")
           ((:const :b -100000) "E1D39092C1FFBFF2" "48C7C26079FEFF")
           ((:word :b 42 l) "41059DD26100A0F20100C0F20100E0F2" "48BA2AE8030000000000")
           ((:add :vsp -16) "944200D1" "4883C3F0")
           ((:add :vsp 8) "94220091" "4883C308")
           ((:add :consts 3) "D60E0091" "4983C603")
           ((:add :vsp -8000) "94023DD1940640D1" "4881C3C0E0FFFF")
           ((:lea :e :vsp 4096) "89064091" "4C8D9300100000")
           ((:lea :e :vsp 4104) "8922009129054091" "4C8D9308100000")
           ((:lea :e :vsp 32) "89820091" "4C8D5320")
           ((:lea :locals :vsp -8) "952200D1" "488D73F8")
           ((:lea :vsp :locals -8) "B42200D1" "488D5EF8")
           ((:lea :locals :vsp 0) "95020091" "488D33")
           ((:add-reg :e :a) "2901008B" "4901CA")
           ((:sub-reg :locals :e) "B50209CB" "4C29D6")
           ((:or-reg :e :b) "290101AA" "4909D2")
           ((:shl :e 3) "29F17DD3" "49C1E203")
           ((:shl :e 1) "29F97FD3" "49D1E2")
           ((:shl :e 2) "29F57ED3" "49C1E202")
           ((:shr :e 16) "29FD50D3" "49C1EA10")
           ((:add-over :a :b l) "000001AB261F0054" "4801D10F80DF030000")
           ((:sub-over :a :b l) "000001EB261F0054" "4829D10F80DF030000")
           ((:jump l) "FA000014" "E9E3030000")
           ((:jump l) :back "06FFFF17" "E913FCFFFF")
           ((:jump-reg :a) "00001FD6" "FFE1")
           ((:jump-if :eq :a 0 l) "1F0000F1201F0054" "4883F9000F84DE030000")
           ((:jump-if :ne :e :nil l) :back "3F0117EBA1E0FF54" "4939FA0F850FFCFFFF")
           ((:jump-if :eq :e :nil l) "3F0117EB201F0054" "4939FA0F84DF030000")
           ((:jump-if :lt :a :b l) "1F0001EB2B1F0054" "4839D10F8CDF030000")
           ((:jump-if :ge :a :b l) "1F0001EB2A1F0054" "4839D10F8DDF030000")
           ((:jump-if :gt :a :b l) "1F0001EB2C1F0054" "4839D10F8FDF030000")
           ((:jump-if :le :a :b l) "1F0001EB2D1F0054" "4839D10F8EDF030000")
           ((:jump-if :hs :b :e l) "3F0009EB221F0054" "4C39D20F83DF030000")
           ((:jump-if :hi :e :f l) "3F010AEB281F0054" "4D39DA0F87DF030000")
           ((:jump-if :ls :e :f l) "3F010AEB291F0054" "4D39DA0F86DF030000")
           ((:jump-if :lo :csp :f l) "FF632AEB231F0054" "4C39DC0F82DF030000")
           ((:jump-if :ne :b 3 l) "3F0C00F1211F0054" "4883FA030F85DE030000")
           ((:jump-if :ne :b 5000 l) "107182D23F0010EB011F0054" "4881FA881300000F85DB030000")
           ((:jump-if :ne :e 15 l) "3F3D00F1211F0054" "4983FA0F0F85DE030000")
           ((:jump-if :eq :e 6 l) "3F1900F1201F0054" "4983FA060F84DE030000")
           ((:jump-tag :a 1 l) "100840921F0600F1001F0054" "89C883E00783F8010F84DA030000")
           ((:jump-not-tag :a 5 l) "100840921F1600F1011F0054" "89C883E00783F8050F85DA030000")
           ((:jump-not-tag :e 1 l) :back "300940921F0600F181E0FF54" "4489D083E00783F8010F8509FCFFFF")
           ((:jump-odd :e l) "3F0140F2211F0054" "41F7C2010000000F85DB030000")
           ((:jump-odd :a l) "1F0040F2211F0054" "F7C1010000000F85DC030000")
           ((:jump-odd :b l) "3F0040F2211F0054" "F7C2010000000F85DC030000")
           ((:jump-bit-clear :e 0 l) "3F0140F2201F0054" "490FBAE2000F83DD030000")
           ((:jump-bit-clear :e 13 l) "3F0173F2201F0054" "490FBAE20D0F83DD030000")
           ((:jump-bit-clear :e 19 l) :back "3F016DF2A0E0FF54" "490FBAE2130F830DFCFFFF")
           ((:call-c 256) "708240F900023FD6" "41FF97000100004889C1")
           ((:call-lisp 248) "707E40F900023FD6" "41FF97F8000000")
           ((:save) "FD7BBEA9F55B01A9" "5641564883EC28")
           ((:restore-return) "F55B41A9FD7BC2A8C0035FD6" "4883C428415E5EC3")
               ))
  (let* ((back (eq (second row) :back))
         (item (subst (list 1000) 'l (first row)))
         (bytes (if back (cddr row) (cdr row))))
    (check bytes (list (written :arm64 item (if back 2000 0)) (written :x86-64 item (if back 2000 0))))))

;; A jump of AArch64's that depends on a condition reaches a megabyte and
;; no further, and code that is longer than that is not to be had: the
;; machine of the kernel goes on running such a function. x86-64 reaches
;; two gigabytes.
(let ((far (list nil)) (items nil))
  (dotimes (i 270000)
    (push '(:const :a 0) items))
  (setq items (append (list (list :jump-if :eq :a 0 far)) items (list (list :label far))))
  (check '(nil t)
         (list (clara.native::assemble items 'clara.native::write-arm64 4)
               (vectorp (clara.native::assemble items 'clara.native::write-x86-64 1)))))

;;; The console, on a machine that is made up for the purpose.

(defvar *sent* nil) ; the bytes that the UART was given, the last first

(defun sent ()
  (prog1 (reverse *sent*)
    (setq *sent* nil)))

(defun text-of (bytes)
  (sb-ext:octets-to-string (coerce bytes '(vector (unsigned-byte 8))) :external-format :utf-8))

(defun bytes-of (text)
  (coerce (sb-ext:string-to-octets text :external-format :utf-8) 'list))

;; A PL011 in memory. Its flags say that there is no room for a byte the
;; first BUSY times they are looked at.
(defun attach-pl011 (address &key (busy 0))
  (clara.host:map-device address #x1000
                         (lambda (offset size)
                           (declare (ignore size))
                           (cond ((/= offset #x18) 0)
                                 ((plusp busy) (decf busy) #x20)
                                 (t 0)))
                         (lambda (offset size value)
                           (declare (ignore size))
                           (when (zerop offset)
                             (push value *sent*))))
  (clara.console:use-serial :pl011 address))

;; A 16550 on I/O ports. Its line status says that it can take a byte only
;; after it has been looked at BUSY times.
(defun attach-ns16550 (port &key (busy 0))
  (clara.host:map-ports port 8
                        (lambda (offset size)
                          (declare (ignore size))
                          (cond ((/= offset 5) 0)
                                ((plusp busy) (decf busy) 0)
                                (t #x60)))
                        (lambda (offset size value)
                          (declare (ignore size))
                          (when (zerop offset)
                            (push value *sent*))))
  (clara.console:use-serial :ns16550 port))

(defun new-machine ()
  (clara.host:reset-machine)
  (setq *sent* nil
        clara.console::*screen* nil
        clara.console::*cursor* nil
        clara.console::*reading* nil
        clara.console::*keys* nil
        clara.console::*typed* (clara.unsafe:interrupt-event :serial)
        clara.console::*after-return* nil)
  (clara.console:use-serial nil 0)
  (clara.console:make-console-stream))

;; The serial port: text goes out as UTF-8, a new line as CR LF, and a UART
;; that is busy is waited for.
(new-machine)
(attach-pl011 #x9000000)
(clara.console:write-text (format nil "h~C~%" (code-char 233)))
(check '(104 #xc3 #xa9 13 10) (sent))
(clara.console:write-text (coerce (list (code-char #x2600) (code-char #x1f600) #\~) 'string))
(check '(#xe2 #x98 #x80 #xf0 #x9f #x98 #x80 126) (sent))

(new-machine)
(attach-pl011 #x9000000 :busy 5)
(clara.console:write-text "slow")
(check "slow" (text-of (sent)))

(new-machine)
(attach-ns16550 #x3f8 :busy 3)
(clara.console:write-text (format nil "ports~%"))
(check '(112 111 114 116 115 13 10) (sent))

(new-machine)
(check "nowhere" (clara.console:write-text "nowhere")) ; no serial port, no screen: nothing to do, and no harm done

;; The screen. This one is 67 by 50 pixels: a grid of 8 columns and 3 rows
;; with a pixel to spare on the left and one above, and rows of pixels that
;; are longer than the screen is wide.
(defvar *pixels* 0)
(defvar *pitch* 0)

(defun new-screen (&key (width 67) (height 50) (row 0) (column 0))
  (new-machine)
  (setq *pitch* (* 4 (+ width 3))
        *pixels* (clara.unsafe:allocate-memory 16))
  (clara.console:use-screen *pixels* width height *pitch* #xff0000 #x00ff00 #x0000ff row column))

(defun pixel-at (x y)
  (clara.unsafe:memory-32 (+ *pixels* (* y *pitch*) (* 4 x))))

;; Does the cell at ROW and COLUMN show the glyph of CHARACTER, in the
;; console's ink on its paper? LEFT and TOP are the pixels around the grid.
(defun shows-p (row column character &key (left 1) (top 1))
  (let* ((code (char-code character))
         (glyph (* clara.font:+height+
                   (- (if (<= clara.font:+first+ code clara.font:+last+) code (1+ clara.font:+last+))
                      clara.font:+first+))))
    (dotimes (y clara.font:+height+ t)
      (dotimes (x clara.font:+width+)
        (unless (= (pixel-at (+ left (* column clara.font:+width+) x) (+ top (* row clara.font:+height+) y))
                   (if (logbitp (- clara.font:+width+ 1 x) (aref clara.font:*glyphs* (+ glyph y)))
                       clara.console::*ink*
                       clara.console::*paper*))
          (return-from shows-p nil))))))

(defun cursor ()
  (list clara.console::*row* clara.console::*column*))

(check #xe8e3f4 (clara.console::pixel #xe8e3f4 #xff0000 #x00ff00 #x0000ff))
(check #xf4e3e8 (clara.console::pixel #xe8e3f4 #x0000ff #x00ff00 #xff0000))
(check 61214 (clara.console::pixel #xe8e3f4 #xf800 #x07e0 #x001f)) ; five bits of red, six of green, five of blue
(check #x3f0 (clara.console::pixel #xe8e3f4 #x300 0 #x0f0))        ; a mask can be anywhere, and missing

(new-screen)
(check '(8 3) (list clara.console::*columns* clara.console::*rows*))
(clara.console:write-text "A")
(check t (shows-p 0 0 #\A))
(check '(0 1) (cursor))
(check 0 (pixel-at 0 0))                      ; nothing is drawn outside the grid,
(check 0 (pixel-at 9 1))                      ; nor in a cell that nothing was written to
(check 0 (clara.unsafe:memory-32 (+ *pixels* (* 4 67)))) ; nor past the end of a row of pixels

(new-screen)
(clara.console:write-text "abcdefghi")        ; the ninth character starts a new row
(check t (and (shows-p 0 7 #\h) (shows-p 1 0 #\i)))
(check '(1 1) (cursor))
(clara.console:write-text (format nil "~%2"))
(check t (and (shows-p 0 0 #\a) (shows-p 1 0 #\i) (shows-p 2 0 #\2))) ; three rows in use,
(clara.console:write-text (format nil "~%3"))                         ; and a new line moves them all up
(check t (and (shows-p 0 0 #\i) (shows-p 1 0 #\2) (shows-p 2 0 #\3)))
(check t (and (shows-p 2 1 #\Space) (shows-p 2 7 #\Space)))            ; the last row was made blank first
(check 0 (pixel-at 9 1))                      ; what was never written to has moved up as it was
(check '(2 1) (cursor))
(clara.console:write-text (format nil "~%4"))
(check t (and (shows-p 0 0 #\2) (shows-p 1 0 #\3) (shows-p 2 0 #\4)))
(clara.console:write-text (coerce (list #\Backspace #\x #\Return #\y (code-char 233)) 'string))
(check t (and (shows-p 2 0 #\y) (shows-p 2 1 (code-char 127)))) ; a character without a glyph is a box
(check '(2 2) (cursor))

(new-screen :width 200)                       ; 25 columns, to have room for a tab
(clara.console:write-text (coerce (list #\a #\Tab #\b #\Tab #\Tab #\c) 'string))
(check t (and (shows-p 0 0 #\a :left 0) (shows-p 0 8 #\b :left 0) (shows-p 0 24 #\c :left 0)))
(check '(0 25) (cursor))

(new-screen :row 2 :column 5)                 ; the screen as the substrate's console left it
(clara.console:write-text "z")
(check t (shows-p 2 5 #\z))

;; Reading a line: what is typed arrives as bytes and an interrupt.
(defun typed (&rest bytes)
  (clara.host:type-bytes bytes)
  (clara.console:read-text-line))

(new-machine)
(attach-pl011 #x9000000)
(check "ab" (typed 97 98 13))
(check (list 97 98 13 10) (sent))             ; echoed as it was typed
(check "one" (typed 111 110 101 13 10 116 119 111 10))
(check "two" (clara.console:read-text-line))  ; the line feed after a carriage return is its other half
(check "ad" (typed 97 98 99 127 8 100 10))    ; Delete and Backspace take the last character back
(check (list 97 98 99 8 32 8 8 32 8 100 13 10) (nthcdr 10 (sent)))
(check "" (typed 8 127 10))                   ; and there is nothing to take back from an empty line
(check "a b" (typed 97 9 98 10))              ; a tab counts as a space
(check (format nil "caf~C" (code-char 233)) (typed 99 97 102 #xc3 #xa9 10))
(check (string (code-char #x1f600)) (typed #xf0 #x9f #x98 #x80 10))
(check "ab" (typed 1 97 27 4 98 10))          ; the other control characters are dropped, Ctrl-D in a line too
(check nil (typed 4))                         ; and at the start of one it ends the input
(sent)
(check-condition clara:keyboard-interrupt (typed 97 98 3))
(check "ab^C" (string-right-trim '(#\Return #\Newline) (text-of (sent))))
(check t (clara.host:serial-break-p))         ; Ctrl-C stops a computation again once the line is over
(check "next" (typed 110 101 120 116 10))

;; What a keyboard's driver hands in is read along with the serial port's
;; bytes, and ahead of them.
(new-machine)
(attach-pl011 #x9000000)
(dolist (code '(107 233 10))
  (clara.console:key-typed code))
(check (format nil "k~C" (code-char 233)) (clara.console:read-text-line))
(clara.host:type-bytes '(115 10))
(clara.console:key-typed 107)
(check "ks" (clara.console:read-text-line))
;; Ctrl-C from a keyboard: it stops what is being computed, and is no
;; character; while a line is being read it is one, and gives the line up.
(clara.console:key-typed 3)
(check '(1 nil) (list (clara.host:keyboard-breaks) clara.console::*keys*))
(let ((clara.console::*reading* t))
  (clara.console:key-typed 97)
  (clara.console:key-typed 3))
(check 1 (clara.host:keyboard-breaks))
(check-condition clara:keyboard-interrupt (clara.console:read-text-line))
(check nil clara.console::*reading*)
(dotimes (i 2000)                             ; what nobody reads is kept up to a limit, and no further
  (clara.console:key-typed 120))
(check 1024 (length clara.console::*keys*))

;; The cursor: the lowest two rows of pixels of the cell where the next
;; character goes, while a line is being read and at no other time.
(defun bar-p (row column pixel &key (left 1) (top 1))
  (let ((y (+ top (* row clara.font:+height+) (- clara.font:+height+ 2))))
    (dotimes (x clara.font:+width+ t)
      (unless (and (= (pixel-at (+ left (* column clara.font:+width+) x) y) pixel)
                   (= (pixel-at (+ left (* column clara.font:+width+) x) (1+ y)) pixel))
        (return nil)))))

(new-screen)
(clara.console:write-text "a")
(check nil clara.console::*cursor*)           ; nobody is reading
(check 0 (pixel-at 9 16))
(setq clara.console::*reading* t)
(clara.console:write-text "b")
(check t (bar-p 0 2 clara.console::*ink*))
(check t (and (shows-p 0 0 #\a) (shows-p 0 1 #\b)))
(clara.console:write-text "c")                ; it moves on, and leaves nothing behind
(check t (and (bar-p 0 3 clara.console::*ink*) (bar-p 0 2 clara.console::*paper*) (shows-p 0 2 #\c)))
(clara.console:write-text "defgh")            ; the row is full: there is no cell for it
(check nil clara.console::*cursor*)
(check t (shows-p 0 7 #\h))
(dolist (line '("1" "2" "3"))                 ; rows move up, and the cursor does not move with them
  (clara.console:write-text (format nil "~%~A" line)))
(check t (and (shows-p 0 0 #\1) (shows-p 1 0 #\2) (shows-p 2 0 #\3) (bar-p 2 1 clara.console::*ink*)))
(check t (and (bar-p 0 1 clara.console::*paper*) (bar-p 1 1 clara.console::*paper*)))
(setq clara.console::*reading* nil)
(clara.console:write-text "4")
(check t (and (shows-p 2 1 #\4) (bar-p 2 2 clara.console::*paper*)))
(check nil clara.console::*cursor*)

(new-screen)                                  ; it shows while a line is read, and is gone when the line is
(attach-pl011 #x9000000)
(let ((seen nil))
  (clara.host:map-ports #x80 1
                        (lambda (offset size) (declare (ignore offset size)) 0)
                        (lambda (offset size value)
                          (declare (ignore offset size value))
                          (push (list (cursor) (and clara.console::*cursor* t)) seen)))
  (clara.host:type-bytes '(120 13))
  ;; A look at the screen from inside the line: when the x has been echoed.
  (let ((stream clara.console::*stream*))
    (unwind-protect
         (progn
           (setq clara.console::*stream*
                 (clara:make-stream :write-string (lambda (string)
                                                    (clara.console:write-text string)
                                                    (setf (clara.unsafe:port-8 #x80) 0))))
           (check "x" (clara.console:read-text-line)))
      (setq clara.console::*stream* stream)))
  (check '(((1 0) t) ((0 1) t)) seen))
(check '(nil nil) (list clara.console::*cursor* clara.console::*reading*))
(check t (and (shows-p 0 0 #\x) (bar-p 0 1 clara.console::*paper*) (bar-p 1 0 clara.console::*paper*)))

;; Start and stop: the console takes the serial port and the screen from
;; where the substrate says they are, and hands the screen back.
(new-machine)
(let ((*standard-output* *standard-output*) (*standard-input* *standard-input*))
  (setq *pixels* (clara.unsafe:allocate-memory 8))
  (clara.host:set-serial-device :pl011 #x9000000)
  (attach-pl011 #x9000000)
  (setq *pitch* 280)
  (clara.host:set-framebuffer *pixels* 67 50 *pitch* #xff0000 #x00ff00 #x0000ff)
  (clara.host:set-screen-cursor 1 2)
  (clara.console:start)
  (format t "hi~%")
  (check "hi" (string-right-trim '(#\Return #\Newline) (text-of (sent))))
  (check t (and (shows-p 1 2 #\h) (shows-p 1 3 #\i)))
  (check nil (fresh-line))
  (clara.host:type-bytes '(111 107 10))
  (check "ok" (read-line))
  (clara.console:stop)
  (check '(2 0) (clara.host:given-screen)))

;; A console that starts in a world which was saved knows nothing of the
;; screen, the cursor and the keys that it had when the world was saved:
;; that was another machine, and this one has no screen.
(clara.host:reset-machine)
(let ((*standard-output* *standard-output*) (*standard-input* *standard-input*))
  (setq *sent* nil
        clara.console::*screen* #x7fff0000
        clara.console::*lent* t
        clara.console::*cursor* #x7fff0100
        clara.console::*reading* t
        clara.console::*keys* (list 97)
        clara.console::*after-return* t)
  (clara.host:set-serial-device :pl011 #x9000000)
  (attach-pl011 #x9000000)
  (clara.console:start)
  (check '(nil nil nil nil nil nil)
         (list clara.console::*screen* clara.console::*cursor* clara.console::*reading* clara.console::*keys*
               clara.console::*after-return* clara.console::*lent*))
  (format t "still here~%")
  (check "still here" (string-right-trim '(#\Return #\Newline) (text-of (sent)))))

;;; Drawing, on surfaces of a machine that is made up. A picture is looked
;;; at here as its rows, a character to the pixel: a dot for a pixel that
;;; is 0, and a digit or a letter for one that is a small number, which is
;;; all that a colour is to what draws. What a surface should show after
;;; something was drawn on it is worked out here pixel by pixel, from what
;;; was asked for, and not by the code that drew it.

(defun dot (word)
  (cond ((zerop word) #\.)
        ((< word 36) (char "0123456789abcdefghijklmnopqrstuvwxyz" word))
        (t #\?)))

(defun word-at (surface x y)
  (clara.unsafe:memory-32 (+ (clara.draw::surface-address surface) (* y (clara.draw::surface-pitch surface)) (* 4 x))))

(defun picture (surface)
  (loop for y below (clara.draw:surface-height surface)
        collect (coerce (loop for x below (clara.draw:surface-width surface) collect (dot (word-at surface x y)))
                        'string)))

;; The picture in which the pixel at X and Y is what PIXEL says of them.
(defun expected (width height pixel)
  (loop for y below height
        collect (coerce (loop for x below width collect (dot (funcall pixel x y))) 'string)))

(defun clear (surface)
  (clara.unsafe:fill-rectangle-32 (clara.draw::surface-address surface) (clara.draw::surface-pitch surface)
                                  (clara.draw:surface-width surface) (clara.draw:surface-height surface) 0)
  (setf (clara.draw::surface-damage surface) nil))

;; A machine with a screen, or without one, and what draws started on it:
;; the screen, and what START had to say.
(defvar *said* "")

(defun new-drawing (&key width (height 10) (slack 2) (red #xff0000) (green #x00ff00) (blue #x0000ff))
  (clara.host:reset-machine)
  (when width
    (clara.host:set-framebuffer (clara.unsafe:allocate-memory 4) width height (* 4 (+ width slack)) red green blue))
  (setq *said* (with-output-to-string (*standard-output*) (clara.draw:start)))
  (clara.draw:screen))

;; A machine without a screen: there is nothing to show on, and everything
;; to draw on. A colour is red, green and blue in the places that the
;; screen has them, and without a screen in the commonest ones.
(check nil (new-drawing))
(check (format nil "draw: no screen, and surfaces to draw on all the same~%") *said*)
(check '(#xff0000 #x00ff00 #x0000ff #x010203 0 #xffffff)
       (list (clara.draw:color 255 0 0) (clara.draw:color 0 255 0) (clara.draw:color 0 0 255) (clara.draw:color 1 2 3)
             (clara.draw:color 0 0 0) (clara.draw:color 255 255 255)))
(check-condition error (clara.draw:color 256 0 0))
(check-condition error (clara.draw:color 0 -1 0))
(check-condition error (clara.draw:fill-rectangle (clara.draw:screen) 0 0 1 1 1)) ; NIL is no surface
(check-condition error (clara.draw:fill-rectangle "a picture" 0 0 1 1 1))

;; With a screen: its size is said, and a colour goes where the screen's
;; masks say, the highest bits of it when there are fewer than eight.
(let ((screen (new-drawing :width 20 :height 10 :red #x0000ff :blue #xff0000)))
  (check (format nil "draw: a screen of 20 by 10 pixels~%") *said*)
  (check '(t 20 10) (list (clara.draw:surface-p screen) (clara.draw:surface-width screen) (clara.draw:surface-height screen)))
  (check #xf4e3e8 (clara.draw:color #xe8 #xe3 #xf4)))
(new-drawing :width 20 :red #xf800 :green #x07e0 :blue #x001f)
(check 61214 (clara.draw:color #xe8 #xe3 #xf4))
(new-drawing :width 20 :red #x300 :green 0 :blue #x0f0)
(check #x3f0 (clara.draw:color #xe8 #xe3 #xf4))

;; A surface is page frames, all zeroes, and gives them back when it is
;; freed; after that it is not drawn on, read or freed again.
(new-drawing :width 20)
(let* ((pages (clara.host:allocated-pages))
       (surface (clara.draw:allocate-surface 40 30)))
  (check 2 (- (clara.host:allocated-pages) pages)) ; 4800 bytes
  (check '(40 30 0 0 nil nil)
         (list (clara.draw:surface-width surface) (clara.draw:surface-height surface)
               (clara.draw:pixel surface 0 0) (clara.draw:pixel surface 39 29)
               (clara.draw:pixel surface 40 0) (clara.draw:pixel surface 0 -1)))
  (check nil (clara.draw:free-surface surface))
  (check pages (clara.host:allocated-pages))
  (check-condition error (clara.draw:fill-rectangle surface 0 0 1 1 1))
  (check-condition error (clara.draw:pixel surface 0 0))
  (check-condition error (clara.draw:free-surface surface))
  (check pages (clara.host:allocated-pages))
  ;; What is refused is refused in words that say why.
  (flet ((said (function)
           (handler-case (progn (funcall function) nil)
             (error (condition) (princ-to-string condition)))))
    (check '("this surface was freed" "the screen is not a surface that can be freed" "5 is not a surface")
           (list (said (lambda () (clara.draw:draw-text surface 0 0 "gone" 1)))
                 (said (lambda () (clara.draw:free-surface (clara.draw:screen))))
                 (said (lambda () (clara.draw:show 5))))))
  (check-condition error (clara.draw:allocate-surface 0 10))
  (check-condition error (clara.draw:allocate-surface 10 16385))
  (check-condition error (clara.draw:allocate-surface 10 "ten"))
  (check pages (clara.host:allocated-pages)))

;; Rectangles. Every place a rectangle of every size can lie in, on a
;; surface and around it: what is on the surface is drawn, and the
;; function says whether anything was.
(defvar *canvas* nil)

(defun sweep (function)
  (loop for x from -6 to 14
        do (loop for y from -5 to 9
                 do (funcall function x y))))

(new-drawing :width 20)
(setq *canvas* (clara.draw:allocate-surface 12 8))
(let ((wrong 0))
  (dolist (size '((5 3) (1 1) (30 30) (12 8) (0 4) (4 0) (-3 2)))
    (destructuring-bind (width height) size
      (sweep (lambda (x y)
               (clear *canvas*)
               (let ((drew (clara.draw:fill-rectangle *canvas* x y width height 7))
                     (want (expected 12 8 (lambda (px py)
                                            (if (and (<= x px (+ x width -1)) (<= y py (+ y height -1))) 7 0)))))
                 (unless (and (equal want (picture *canvas*))
                              (eq drew (and (find #\7 (format nil "~{~A~}" want)) t)))
                   (incf wrong)))))))
  (check '(fill 0) (list 'fill wrong)))
(clear *canvas*)
(check t (clara.draw:fill-rectangle *canvas* 2 1 5 3 7))
(check '("............"
         "..77777....."
         "..77777....."
         "..77777....."
         "............"
         "............"
         "............"
         "............")
       (picture *canvas*))

;; The outline of one is a pixel thick and just inside it, also when the
;; rectangle is too small to have an inside.
(let ((wrong 0))
  (dolist (size '((6 4) (1 1) (2 2) (1 5) (5 1) (2 5) (30 30) (12 8) (0 3) (5 0) (-2 4) (4 -2)))
    (destructuring-bind (width height) size
      (sweep (lambda (x y)
               (clear *canvas*)
               (clara.draw:draw-rectangle *canvas* x y width height 3)
               (unless (equal (picture *canvas*)
                              (expected 12 8 (lambda (px py)
                                               (if (and (<= x px (+ x width -1)) (<= y py (+ y height -1))
                                                        (or (= px x) (= px (+ x width -1)) (= py y) (= py (+ y height -1))))
                                                   3 0))))
                 (incf wrong))))))
  (check '(outline 0) (list 'outline wrong)))
(clear *canvas*)
(check t (clara.draw:draw-rectangle *canvas* 1 1 6 4 3))
(check nil (clara.draw:draw-rectangle *canvas* 12 0 6 4 3))
(check '("............"
         ".333333....."
         ".3....3....."
         ".3....3....."
         ".333333....."
         "............"
         "............"
         "............")
       (picture *canvas*))

;; Drawing can be kept to a part of a surface for a while, and to a part
;; of that part within it; afterwards it is kept to what it was before,
;; also when what was done meanwhile failed.
(let ((wrong 0))
  (dolist (part '((3 2 5 4) (-2 -2 6 5) (8 5 30 30) (4 4 0 2) (20 20 3 3) (0 0 12 8)))
    (destructuring-bind (left top width height) part
      (sweep (lambda (x y)
               (clear *canvas*)
               (clara.draw:with-clip (*canvas* left top width height)
                 (clara.draw:fill-rectangle *canvas* x y 6 4 5))
               (unless (equal (picture *canvas*)
                              (expected 12 8 (lambda (px py)
                                               (if (and (<= x px (+ x 5)) (<= y py (+ y 3))
                                                        (<= left px (+ left width -1)) (<= top py (+ top height -1)))
                                                   5 0))))
                 (incf wrong))))))
  (check '(clip 0) (list 'clip wrong)))
(clear *canvas*)
(check '(one two)
       (multiple-value-list
        (clara.draw:with-clip (*canvas* 2 1 8 6)
          (clara.draw:with-clip (*canvas* 0 0 6 4)        ; the part of the part: from 2 and 1 to 5 and 3
            (clara.draw:fill-rectangle *canvas* 0 0 12 8 1))
          (clara.draw:fill-rectangle *canvas* 9 0 3 8 2)  ; kept to the outer part again
          (values 'one 'two))))
(check '("............"
         "..1111...2.."
         "..1111...2.."
         "..1111...2.."
         ".........2.."
         ".........2.."
         ".........2.."
         "............")
       (picture *canvas*))
(check-condition error (clara.draw:with-clip (*canvas* 0 0 2 2) (error "in the middle")))
(clara.draw:fill-rectangle *canvas* 0 7 12 1 4)
(check "444444444444" (car (last (picture *canvas*))))

;; A picture of one bit to the pixel. This one is an arrow, seven pixels
;; wide; where a bit is set the pixel takes the colour, and where it is not
;; the background, when there is one.
(defvar *arrow* (vector #b1000000 #b1100000 #b1110000 #b1111000 #b1111100 #b1100000 #b0010000))

(defun arrow-p (x y)
  (and (<= 0 x 6) (<= 0 y 6) (logbitp (- 6 x) (aref *arrow* y))))

(dolist (background '(nil 2))
  (let ((wrong 0))
    (sweep (lambda (x y)
             (clear *canvas*)
             (clara.draw:fill-rectangle *canvas* 0 0 12 8 9)
             (clara.draw:draw-bitmap *canvas* x y *arrow* 7 4 background)
             (unless (equal (picture *canvas*)
                            (expected 12 8 (lambda (px py)
                                             (cond ((arrow-p (- px x) (- py y)) 4)
                                                   ((and background (<= x px (+ x 6)) (<= y py (+ y 6))) background)
                                                   (t 9)))))
               (incf wrong))))
    (check '(bitmap 0) (list 'bitmap wrong))))
(clear *canvas*)
(check t (clara.draw:draw-bitmap *canvas* 1 0 *arrow* 7 4))
(check nil (clara.draw:draw-bitmap *canvas* 1 8 *arrow* 7 4))
(check t (clara.draw:draw-bitmap *canvas* 9 4 *arrow* 7 nil 6)) ; the background alone, and cut off on two sides
(check '(".4.........."
         ".44........."
         ".444........"
         ".4444......."
         ".44444....66"
         ".44........6"
         "...4........"
         "............")
       (picture *canvas*))

;; Text, in the console's font. A character is a cell of 8 by 16 pixels,
;; and a character that the font has no glyph for is the box after its
;; last glyph.
(defun glyph-p (character x y)
  (let ((code (char-code character)))
    (and (<= 0 x (1- clara.font:+width+)) (<= 0 y (1- clara.font:+height+))
         (logbitp (- clara.font:+width+ 1 x)
                  (aref clara.font:*glyphs*
                        (+ y (* clara.font:+height+
                                (- (if (<= clara.font:+first+ code clara.font:+last+) code (1+ clara.font:+last+))
                                   clara.font:+first+))))))))

(defun text-p (string x y)
  (and (<= 0 x (1- (* clara.font:+width+ (length string))))
       (glyph-p (char string (floor x clara.font:+width+)) (mod x clara.font:+width+) y)))

(clara.draw:free-surface *canvas*)
(setq *canvas* (clara.draw:allocate-surface 30 20))
(dolist (background '(nil 2))
  (let ((wrong 0) (string (coerce (list #\A #\g (code-char 955) #\!) 'string)))
    (loop for x from -40 to 34 by 3
          do (loop for y from -18 to 22 by 3
                   do (clear *canvas*)
                      (clara.draw:fill-rectangle *canvas* 0 0 30 20 9)
                      (let ((drew (clara.draw:draw-text *canvas* x y string 4 background))
                            (want (expected 30 20 (lambda (px py)
                                                    (cond ((text-p string (- px x) (- py y)) 4)
                                                          ((and background (<= x px (+ x 31)) (<= y py (+ y 15))) background)
                                                          (t 9))))))
                        (unless (and (equal want (picture *canvas*))
                                     (eq drew (and (< -32 x 30) (< -16 y 20))))
                          (incf wrong)))))
    (check '(text 0) (list 'text wrong))))
(check '(0 8 104) (mapcar #'clara.draw:text-width (list "" "a" "thirteen long")))
(check nil (clara.draw:draw-text *canvas* 0 0 "" 4))
(clear *canvas*)
(clara.draw:draw-text *canvas* 3 2 "Hi" 1)
(check t (and (find #\1 (format nil "~{~A~}" (picture *canvas*))) t))
(check (expected 30 20 (lambda (px py) (if (text-p "Hi" (- px 3) (- py 2)) 1 0))) (picture *canvas*))

;; Copying. The pixels of a part of one surface become those of a part of
;; another: what the first has of the rectangle, where the second can be
;; drawn on. To know what should be there, each pixel of the first is its
;; own place, as a number.
(defvar *source* (clara.draw:allocate-surface 9 6))

(defun number-pixels (surface)
  (dotimes (y (clara.draw:surface-height surface))
    (dotimes (x (clara.draw:surface-width surface))
      (clara.draw:fill-rectangle surface x y 1 1 (+ 1 (mod (+ x (* 5 y)) 35)))))
  (setf (clara.draw::surface-damage surface) nil))

(number-pixels *source*)
(check t (loop for y below 6 always (loop for x below 9 always (= (clara.draw:pixel *source* x y) (word-at *source* x y)))))
(check '(1 9 6 nil nil) (list (clara.draw:pixel *source* 0 0) (clara.draw:pixel *source* 8 0) (clara.draw:pixel *source* 0 1)
                              (clara.draw:pixel *source* 9 0) (clara.draw:pixel *source* 0 6)))
(clara.draw:free-surface *canvas*)
(setq *canvas* (clara.draw:allocate-surface 12 8))
(let ((wrong 0))
  (dolist (part '((0 0 9 6) (2 1 4 3) (-3 -2 8 6) (5 3 30 30) (9 0 2 2) (3 3 0 2) (0 0 100 100)))
    (destructuring-bind (x y width height) part
      (sweep (lambda (to-x to-y)
               (clear *canvas*)
               (let ((drew (clara.draw:copy-rectangle *source* x y width height *canvas* to-x to-y))
                     (want (expected 12 8 (lambda (px py)
                                            (let ((sx (+ x (- px to-x))) (sy (+ y (- py to-y))))
                                              (if (and (<= x sx (+ x width -1)) (<= y sy (+ y height -1))
                                                       (<= 0 sx 8) (<= 0 sy 5))
                                                  (word-at *source* sx sy)
                                                  0))))))
                 (unless (and (equal want (picture *canvas*))
                              (eq drew (and (notevery (lambda (row) (every (lambda (c) (char= c #\.)) row)) want) t)))
                   (incf wrong)))))))
  (check '(copy 0) (list 'copy wrong)))
;; Kept to a part of where it goes, as everything that draws is.
(clear *canvas*)
(clara.draw:with-clip (*canvas* 1 1 3 2)
  (clara.draw:copy-rectangle *source* 0 0 9 6 *canvas* 0 0))
(check (expected 12 8 (lambda (px py) (if (and (<= 1 px 3) (<= 1 py 2)) (word-at *source* px py) 0)))
       (picture *canvas*))
;; And what the first surface is kept to makes no difference: that is for
;; drawing on it, not for reading it.
(clear *canvas*)
(clara.draw:with-clip (*source* 4 4 1 1)
  (clara.draw:copy-rectangle *source* 0 0 9 6 *canvas* 0 0))
(check (expected 12 8 (lambda (px py) (if (and (<= px 8) (<= py 5)) (word-at *source* px py) 0)))
       (picture *canvas*))

;; Within one surface, with the two rectangles over each other, in every
;; direction: each pixel gets what was there before anything moved.
(let ((wrong 0))
  (loop for dx from -4 to 4
        do (loop for dy from -3 to 3
                 do (number-pixels *source*)
                    (let ((before (loop for y below 6 collect (loop for x below 9 collect (word-at *source* x y)))))
                      (clara.draw:copy-rectangle *source* 2 1 5 4 *source* (+ 2 dx) (+ 1 dy))
                      (unless (equal (picture *source*)
                                     (expected 9 6 (lambda (px py)
                                                     (let ((sx (- px dx)) (sy (- py dy)))
                                                       (if (and (<= 2 sx 6) (<= 1 sy 4))
                                                           (nth sx (nth sy before))
                                                           (nth px (nth py before)))))))
                        (incf wrong)))))
  (check '(overlap 0) (list 'overlap wrong)))
(check-condition error (clara.draw:copy-rectangle "nothing" 0 0 1 1 *canvas* 0 0))
(check-condition error (clara.draw:copy-rectangle *source* 0 0 1 1 nil 0 0))

;; Damage: what was drawn on, as a few rectangles. What lies in one that
;; is there adds none; one that takes others in replaces them; and two that
;; make one rectangle between them become it.
(defun damage ()
  (sort (clara.draw:damage *canvas*)
        (lambda (a b) (or (< (second a) (second b)) (and (= (second a) (second b)) (< (first a) (first b)))))))

(clara.draw:free-surface *canvas*)
(setq *canvas* (clara.draw:allocate-surface 40 30))
(check nil (damage))
(clara.draw:fill-rectangle *canvas* 4 4 10 6 1)
(check '((4 4 10 6)) (damage))
(clara.draw:fill-rectangle *canvas* 5 5 3 3 2)        ; inside it
(clara.draw:fill-rectangle *canvas* 4 4 10 6 2)        ; the same again
(check '((4 4 10 6)) (damage))
(clara.draw:fill-rectangle *canvas* 50 50 3 3 2)       ; nothing was drawn
(clara.draw:fill-rectangle *canvas* 38 28 10 10 2)     ; what was drawn of it
(check '((4 4 10 6) (38 28 2 2)) (damage))
(clara.draw:fill-rectangle *canvas* 20 4 5 6 1)        ; apart from the first,
(check '((4 4 10 6) (20 4 5 6) (38 28 2 2)) (damage))
(clara.draw:fill-rectangle *canvas* 14 4 6 6 1)        ; and what lies between them: one rectangle, of the three
(check '((4 4 21 6) (38 28 2 2)) (damage))
(clara.draw:fill-rectangle *canvas* 4 10 21 3 1)       ; under it
(clara.draw:fill-rectangle *canvas* 4 2 21 4 1)        ; over its upper edge
(check '((4 2 21 11) (38 28 2 2)) (damage))
(clara.draw:fill-rectangle *canvas* 4 13 20 2 1)       ; not as wide: two rectangles do not make one
(check '((4 2 21 11) (4 13 20 2) (38 28 2 2)) (damage))
(clara.draw:fill-rectangle *canvas* 0 0 40 30 3)       ; all of it
(check '((0 0 40 30)) (damage))
(check '((0 0 40 30)) (clara.draw:take-damage *canvas*))
(check nil (damage))
;; Text that is written a character at a time is one rectangle, and so is
;; an outline with what is inside it.
(dotimes (i 4)
  (clara.draw:draw-text *canvas* (+ 3 (* 8 i)) 5 (string (char "text" i)) 1 2))
(check '((3 5 32 16)) (damage))
(clara.draw:take-damage *canvas*)
(clara.draw:draw-rectangle *canvas* 10 10 8 6 1)
(check 4 (length (damage)))
(clara.draw:fill-rectangle *canvas* 11 11 6 4 1)
(check '((10 10 8 6)) (damage))
;; More than a few rectangles become the one around them all.
(clara.draw:take-damage *canvas*)
(dotimes (i 8)
  (clara.draw:fill-rectangle *canvas* (* 4 i) (* 3 i) 2 2 1))
(check 8 (length (damage)))
(clara.draw:fill-rectangle *canvas* 36 27 2 2 1)
(check '((0 0 38 29)) (damage))
;; By hand: as much of a rectangle as the surface has.
(clara.draw:take-damage *canvas*)
(check '(t nil nil) (list (clara.draw:add-damage *canvas* -5 -5 10 10) (clara.draw:add-damage *canvas* 40 0 5 5)
                          (clara.draw:add-damage *canvas* 3 3 0 5)))
(check '((0 0 5 5)) (damage))
(clara.draw:take-damage *canvas*)
(clara.draw:copy-rectangle *source* 0 0 9 6 *canvas* 35 27)
(clara.draw:draw-bitmap *canvas* -2 -3 *arrow* 7 1)
(check '((0 0 5 4) (35 27 5 3)) (damage))

;; Whatever is drawn, and wherever: a pixel that has changed lies in the
;; damage, which is never more than a few rectangles.
(let ((seed 11) (wrong 0))
  (flet ((pick (n) (setq seed (mod (+ (* seed 1103515245) 12345) 2147483648)) (mod (floor seed 65536) n)))
    (dotimes (round 60)
      (clear *canvas*)
      (let ((before (picture *canvas*)))
        (dotimes (i (1+ (pick 12)))
          (let ((x (- (pick 60) 10)) (y (- (pick 50) 10)) (colour (1+ (pick 9))))
            (case (pick 5)
              (0 (clara.draw:fill-rectangle *canvas* x y (pick 20) (pick 15) colour))
              (1 (clara.draw:draw-rectangle *canvas* x y (pick 20) (pick 15) colour))
              (2 (clara.draw:draw-text *canvas* x y (subseq "damage" (pick 6)) colour (and (zerop (pick 2)) 1)))
              (3 (clara.draw:draw-bitmap *canvas* x y *arrow* 7 colour))
              (4 (clara.draw:copy-rectangle *source* 0 0 9 6 *canvas* x y)))))
        (let ((after (picture *canvas*)) (damage (clara.draw:damage *canvas*)))
          (when (> (length damage) 8)
            (incf wrong))
          (dotimes (y 30)
            (dotimes (x 40)
              (unless (or (char= (char (nth y before) x) (char (nth y after) x))
                          (some (lambda (r) (and (<= (first r) x (+ (first r) (third r) -1))
                                                 (<= (second r) y (+ (second r) (fourth r) -1))))
                                damage))
                (incf wrong))))))))
  (check '(damage 0) (list 'damage wrong)))

;; The screen. Its rows are longer than it is wide, and what lies past the
;; end of a row is not the screen's. Drawing on it keeps no damage, since
;; what is drawn there shows already.
(let ((screen (new-drawing :width 20 :height 10 :slack 3)))
  (check t (clara.draw:fill-rectangle screen -5 -5 100 100 6))
  (check nil (clara.draw:damage screen))
  (check '(6 6 0 0 0) (list (word-at screen 0 0) (word-at screen 19 9) (word-at screen 20 0) (word-at screen 22 9)
                            (clara.unsafe:memory-32 (+ (clara.draw::surface-address screen) (* 10 92)))))
  ;; Showing: what was drawn on a surface since it was last shown goes to
  ;; the screen, to the place that is asked for, and nothing else does.
  (clear screen)
  (setq *canvas* (clara.draw:allocate-surface 8 6))
  (clara.draw:fill-rectangle *canvas* 0 0 8 6 1)
  (check t (clara.draw:show *canvas* 3 2))
  (check nil (clara.draw:damage *canvas*))
  (check (expected 20 10 (lambda (px py) (if (and (<= 3 px 10) (<= 2 py 7)) 1 0))) (picture screen))
  (clear screen)
  (check nil (clara.draw:show *canvas* 3 2))          ; nothing has changed, so nothing is copied
  (check (expected 20 10 (lambda (px py) (declare (ignore px py)) 0)) (picture screen))
  (clara.draw:fill-rectangle *canvas* 1 1 2 2 4)
  (clara.draw:fill-rectangle *canvas* 6 4 2 2 5)
  (check t (clara.draw:show *canvas* 3 2))             ; two small parts, and not what is between them
  (check (expected 20 10 (lambda (px py)
                           (cond ((and (<= 4 px 5) (<= 3 py 4)) 4)
                                 ((and (<= 9 px 10) (<= 6 py 7)) 5)
                                 (t 0))))
         (picture screen))
  (clear screen)
  (clara.draw:add-damage *canvas* 0 0 8 6)
  (check t (clara.draw:show *canvas* 16 7))            ; partly on the screen
  (check (expected 20 10 (lambda (px py) (if (and (<= 16 px) (<= 7 py)) (word-at *canvas* (- px 16) (- py 7)) 0)))
         (picture screen))
  (check 0 (word-at screen 20 7))
  (clara.draw:add-damage *canvas* 0 0 8 6)
  (check nil (clara.draw:show *canvas* 20 0))          ; and not on it at all: the damage is gone all the same
  (check nil (clara.draw:damage *canvas*))
  (check nil (clara.draw:show screen)))

;; Without a screen there is nothing to show on.
(new-drawing)
(setq *canvas* (clara.draw:allocate-surface 8 6))
(clara.draw:fill-rectangle *canvas* 0 0 8 6 1)
(check '(nil nil) (list (clara.draw:show *canvas*) (clara.draw:damage *canvas*)))

;; A world that was saved comes back without its pixels: the surfaces in it
;; are another machine's, whose memory is somebody else's by now. Nothing
;; is drawn on one, and nothing of it is freed.
(let ((old *canvas*) (old-screen (new-drawing :width 20)) (pages (clara.host:allocated-pages)))
  (new-drawing :width 20)                               ; the machine starts again
  (check-condition error (clara.draw:fill-rectangle old 0 0 1 1 1))
  (check-condition error (clara.draw:fill-rectangle old-screen 0 0 1 1 1))
  (check-condition error (clara.draw:copy-rectangle old 0 0 1 1 (clara.draw:screen) 0 0))
  (check-condition error (clara.draw:show old))
  (check-condition error (clara.draw:free-surface old))
  (check "this surface is of a machine that was switched off: a world is saved without its pixels"
         (handler-case (clara.draw:pixel old 0 0) (error (condition) (princ-to-string condition))))
  (check 4 (clara.host:allocated-pages))                ; the new screen's, and no fewer
  (check t (> pages 0))
  (check t (clara.draw:fill-rectangle (clara.draw:screen) 0 0 1 1 1)))

;;; A PCI bus that is made up: a configuration space with some devices in
;;; it, and among them virtio devices, keyboards and pointers and further
;;; down disks, that do what such a device does with its registers and its
;;; queues. The drivers find nothing mapped there, and have to ask for
;;; every address they read.

(defconstant +ecam+ #x30000000)

(defvar *bus* nil) ; every function there is: (bus slot part . the 256 bytes of its configuration space)

(defun le (bytes offset size)
  (let ((value 0))
    (dotimes (i size value)
      (setq value (logior value (ash (aref bytes (+ offset i)) (* 8 i)))))))

(defun (setf le) (value bytes offset size)
  (dotimes (i size value)
    (setf (aref bytes (+ offset i)) (ldb (byte 8 (* 8 i)) value))))

(defun function-at (offset)
  (cdddr (find (list (ash offset -20) (logand (ash offset -15) 31) (logand (ash offset -12) 7)) *bus*
               :test (lambda (place function) (equal place (subseq function 0 3))))))

(defun attach-bus ()
  (setq *bus* nil)
  (clara.host:set-pci-configuration +ecam+ 0 255)
  (clara.host:map-device +ecam+ (ash 256 20)
                         (lambda (offset size)
                           (let ((config (function-at offset)) (at (logand offset 4095)))
                             (cond ((null config) (ldb (byte (* 8 size) 0) -1))
                                   ((< at 256) (le config at size))
                                   (t 0))))
                         (lambda (offset size value)
                           (let ((config (function-at offset)) (at (logand offset 4095)))
                             (when (and config (< at 256))
                               (setf (le config at size) value))))
                         :mapped nil))

;; A function at a place: the bytes of its configuration space.
(defun add-function (bus slot part vendor id kind &key (header 0))
  (let ((config (make-array 256 :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (le config 0 2) vendor
          (le config 2 2) id
          (le config 8 4) (logior (ash kind 8) 1)
          (le config 14 1) header)
    (push (list* bus slot part config) *bus*)
    config))

(defun device-at (bus slot part)
  (find-if (lambda (device)
             (and (= (clara.pci:device-bus device) bus) (= (clara.pci:device-slot device) slot)
                  (= (clara.pci:device-part device) part)))
           (clara.pci:devices)))

;; The other side of a queue, and of a device.
(defstruct vq (size 64) (message #xffff) (enabled 0) (descriptors 0) (available 0) (used 0)
  (seen 0)     ; how many chains the device has taken from what is available,
  (done 0))    ; and how many it has put into what is used

(defstruct vdev
  config                   ; the bytes of its PCI configuration space
  table                    ; and of its table of messages
  (offers (list 0 1))      ; what it can do, in two halves: bit 32 is version 1
  (wanted (list 0 0))      ; what the driver asked for
  (agreeable t)            ; it takes what the driver asks for
  (status 0) (offer-half 0) (want-half 0) (config-message 0) (queue 0)
  history                  ; every status the driver has written, the last first
  (queues (vector (make-vq) (make-vq)))
  (select 0) (subselect 0) ; what the driver asks its own registers about
  name bits axes           ; and the answers: a string; (type . bytes); (axis least most)
  notified                 ; the queues it was told of new work in, the last first
  disk                     ; of a disk: its sectors, a vector of bytes,
  read-only                ; which cannot be written,
  (answer 0)               ; what it says of every request that is not 0, "all went well",
  silent                   ; or that it never says anything,
  delay                    ; how many seconds it takes over a request, when it takes any,
  mute                     ; that it has no message to send when it is done,
  watch                    ; a function that a test has it call at every request,
  requests)                ; and the requests it was given, the last first: (type sector count)

(defun answer (vdev)
  (case (vdev-select vdev)
    (1 (append (map 'list #'char-code (vdev-name vdev)) '(0)))
    (#x11 (cdr (assoc (vdev-subselect vdev) (vdev-bits vdev))))
    (#x12 (let ((axis (assoc (vdev-subselect vdev) (vdev-axes vdev))) (bytes (make-array 20 :initial-element 0)))
            (when axis
              (setf (le bytes 0 4) (second axis)
                    (le bytes 4 4) (third axis))
              (coerce bytes 'list))))))

(defun peek (address size)
  (clara.host::peek address size))

(defun poke (address size value)
  (clara.host::poke address size value))

;; The device sends its message for a queue, if it has been told one and
;; messages are switched on.
(defun interrupt (vdev vq)
  (let ((entry (* 16 (vq-message vq))) (table (vdev-table vdev)))
    (when (and (/= (vq-message vq) #xffff)
               (logbitp 15 (le (vdev-config vdev) #x42 2))
               (not (logbitp 0 (le table (+ entry 12) 4))))
      (clara.host:send-message (logior (le table entry 4) (ash (le table (+ entry 4) 4) 32))
                               (le table (+ entry 8) 4)))))

;; The first descriptor of the next chain that the driver made available.
(defun next-available (vq)
  (unless (= (vq-seen vq) (peek (+ (vq-available vq) 2) 2))
    (prog1 (peek (+ (vq-available vq) 4 (* 2 (mod (vq-seen vq) (vq-size vq)))) 2)
      (setf (vq-seen vq) (logand (1+ (vq-seen vq)) #xffff)))))

;; The descriptors of a chain, each as (address bytes flags).
(defun chain (vq first)
  (let ((at (+ (vq-descriptors vq) (* 16 first))))
    (cons (list (peek at 8) (peek (+ at 8) 4) (peek (+ at 12) 2))
          (when (logbitp 0 (peek (+ at 12) 2))
            (chain vq (peek (+ at 14) 2))))))

(defun complete (vdev vq first bytes)
  (let ((at (+ (vq-used vq) 4 (* 8 (mod (vq-done vq) (vq-size vq))))))
    (poke at 4 first)
    (poke (+ at 4) 4 bytes)
    (setf (vq-done vq) (logand (1+ (vq-done vq)) #xffff))
    (poke (+ (vq-used vq) 2) 2 (vq-done vq))
    (unless (vdev-mute vdev)
      (interrupt vdev vq))))

;; A disk serves what is in its first queue. A request is three buffers or
;; more: 16 bytes for the device to read, the type in the first four and
;; the sector in the last eight; the memory of the sectors, for the device
;; to write when it is a read; and a byte for its answer.
(defun serve-disk (vdev)
  (let ((vq (aref (vdev-queues vdev) 0)) (disk (vdev-disk vdev)))
    (loop
      (let ((first (next-available vq)))
        (unless first
          (return))
        (let* ((buffers (chain vq first))
               (header (first buffers))
               (answer (car (last buffers)))
               (data (butlast (cdr buffers)))
               (type (peek (first header) 4))
               (sector (peek (+ (first header) 8) 8))
               (bytes (reduce #'+ (mapcar #'second data)))
               (at (* 512 sector))
               (went (vdev-answer vdev)))
          (unless (and (>= (length buffers) 3) (= (second header) 16) (not (logbitp 1 (third header)))
                       (= (second answer) 1) (logbitp 1 (third answer))
                       (plusp bytes) (zerop (mod bytes 512))
                       (every (lambda (buffer) (eq (logbitp 1 (third buffer)) (= type 0))) data))
            (failed "the driver gave the disk a request that is not one: ~S" buffers))
          (dolist (buffer data)
            (let ((first (floor (clara.host::memory-index (first buffer) (second buffer)) 4096)))
              (when (find 0 clara.host::*pages* :start first :end (+ first (ceiling (second buffer) 4096)))
                (failed "the driver gave the disk ~D bytes of memory at #x~X that are not all its own"
                        (second buffer) (first buffer)))))
          (push (list type sector (floor bytes 512)) (vdev-requests vdev))
          (when (vdev-watch vdev)
            (funcall (vdev-watch vdev)))
          (cond ((/= went 0))
                ((or (> (+ at bytes) (length disk)) (and (= type 1) (vdev-read-only vdev)))
                 (setq went 1))
                ((> type 1)
                 (setq went 2))
                (t
                 (dolist (buffer data)
                   (let ((index (clara.host::memory-index (first buffer) (second buffer))))
                     (if (= type 0)
                         (replace clara.host::*memory* disk :start1 index :start2 at :end2 (+ at (second buffer)))
                         (replace disk clara.host::*memory* :start1 at :start2 index :end2 (+ index (second buffer)))))
                   (incf at (second buffer)))))
          (poke (first answer) 1 went)
          ;; A disk that takes its time has read or written by now, and says so later.
          (let ((written (+ (if (= type 0) bytes 0) 1)))
            (cond ((vdev-silent vdev))
                  ((vdev-delay vdev)
                   (sb-thread:make-thread (lambda ()
                                            (sleep (vdev-delay vdev))
                                            (complete vdev vq first written))))
                  (t (complete vdev vq first written)))))))))

(defun vdev-read (vdev offset size)
  (let* ((n (vdev-queue vdev)) (vq (aref (vdev-queues vdev) (min n 1))))
    (cond ((and (>= offset #x2000) (vdev-disk vdev))
           ;; A disk's own registers begin with how many sectors it has, in 64 bits.
           (ldb (byte (* 8 size) (* 8 (- offset #x2000))) (floor (length (vdev-disk vdev)) 512)))
          ((>= offset #x2000)
           (let ((at (- offset #x2000)) (answer (answer vdev)))
             (case at
               (0 (vdev-select vdev))
               (1 (vdev-subselect vdev))
               (2 (length answer))
               (t (let ((value 0))
                    (dotimes (i size value)
                      (setq value (logior value (ash (or (nth (+ at -8 i) answer) 0) (* 8 i))))))))))
          (t
           (case offset
             (#x00 (vdev-offer-half vdev))
             (#x04 (or (nth (vdev-offer-half vdev) (vdev-offers vdev)) 0))
             (#x08 (vdev-want-half vdev))
             (#x0c (or (nth (vdev-want-half vdev) (vdev-wanted vdev)) 0))
             (#x10 (vdev-config-message vdev))
             (#x12 2)
             (#x14 (vdev-status vdev))
             (#x16 n)
             (#x18 (if (< n 2) (vq-size vq) 0))
             (#x1a (vq-message vq))
             (#x1c (vq-enabled vq))
             (#x1e n)
             (t 0))))))

(defun vdev-write (vdev offset size value)
  (declare (ignore size))
  (let* ((n (vdev-queue vdev)) (vq (aref (vdev-queues vdev) (min n 1))))
    (cond ((>= offset #x3000)
           ;; New work in a queue: its number, written to its own register, which is four bytes on
           ;; from the one before. The second queue is one that gives every chain straight back, with
           ;; as many bytes as the device was allowed to write.
           (push (if (= offset (+ #x3000 (* 4 value))) value :at-the-wrong-register) (vdev-notified vdev))
           (when (and (= value 0) (vdev-disk vdev))
             (serve-disk vdev))
           (when (= value 1)
             (let ((vq (aref (vdev-queues vdev) 1)))
               (loop
                 (let ((first (next-available vq)))
                   (unless first
                     (return))
                   (complete vdev vq first
                             (reduce #'+ (mapcar (lambda (buffer) (if (logbitp 1 (third buffer)) (second buffer) 0))
                                                 (chain vq first)))))))))
          ((>= offset #x2000)
           (case (- offset #x2000)
             (0 (setf (vdev-select vdev) value))
             (1 (setf (vdev-subselect vdev) value))))
          (t
           (case offset
             (#x00 (setf (vdev-offer-half vdev) value))
             (#x08 (setf (vdev-want-half vdev) value))
             (#x0c (setf (nth (vdev-want-half vdev) (vdev-wanted vdev)) value))
             (#x10 (setf (vdev-config-message vdev) value))
             (#x14 (push value (vdev-history vdev))
                   (cond ((zerop value)
                          (setf (vdev-status vdev) 0
                                (vdev-wanted vdev) (list 0 0)
                                (vdev-queues vdev) (vector (make-vq) (make-vq))))
                         ((and (logbitp 3 value)
                               (not (and (vdev-agreeable vdev)
                                         (every (lambda (want offer) (zerop (logandc2 want offer)))
                                                (vdev-wanted vdev) (vdev-offers vdev)))))
                          (setf (vdev-status vdev) (logandc2 value 8)))
                         (t (setf (vdev-status vdev) value))))
             (#x16 (setf (vdev-queue vdev) value))
             (#x18 (setf (vq-size vq) value))
             (#x1a (setf (vq-message vq) (if (< value 2) value #xffff)))
             (#x1c (setf (vq-enabled vq) value))
             (#x20 (setf (ldb (byte 32 0) (vq-descriptors vq)) value))
             (#x24 (setf (ldb (byte 32 32) (vq-descriptors vq)) value))
             (#x28 (setf (ldb (byte 32 0) (vq-available vq)) value))
             (#x2c (setf (ldb (byte 32 32) (vq-available vq)) value))
             (#x30 (setf (ldb (byte 32 0) (vq-used vq)) value))
             (#x34 (setf (ldb (byte 32 32) (vq-used vq)) value)))))))

;; A virtio device in a slot of bus 0, as QEMU makes them: its table of two
;; messages behind base address register 1, its other registers behind
;; register 4, which is one of 64 bits, and capabilities that say so.
;; Without MESSAGES it cannot send any, and without REGISTERS it does not
;; say where its registers are.
(defun add-virtio (slot id kind vdev &key (messages t) (registers t))
  (let* ((config (add-function 0 slot 0 #x1af4 id kind))
         (table (make-array 4096 :element-type '(unsigned-byte 8) :initial-element 0))
         (low (+ #x40000000 (* slot #x10000)))
         (high (+ #x8000000000 (* slot #x100000))))
    (setf (vdev-config vdev) config
          (vdev-table vdev) table)
    (setf (le config 6 2) #x10
          (le config #x34 1) (cond (messages #x40) (registers #x50) (t 0))
          (le config #x14 4) low
          (le config #x20 4) (logior (ldb (byte 32 0) high) #xc)
          (le config #x24 4) (ash high -32))
    (when messages
      (replace config (list #x11 (if registers #x50 0) 1 0 1 0 0 0 1 8 0 0) :start1 #x40))
    (when registers
      (replace config (list 9 #x60 16 1 4 0 0 0  0 0 0 0  56 0 0 0) :start1 #x50)
      (replace config (list 9 #x74 20 2 4 0 0 0  0 #x30 0 0  16 0 0 0  4 0 0 0) :start1 #x60)
      (replace config (list 9 0 16 4 4 0 0 0  0 #x20 0 0  0 1 0 0) :start1 #x74))
    (clara.host:map-device low 4096
                           (lambda (offset size) (le table offset size))
                           (lambda (offset size value) (setf (le table offset size) value))
                           :mapped nil)
    (clara.host:map-device high #x4000
                           (lambda (offset size) (vdev-read vdev offset size))
                           (lambda (offset size value) (vdev-write vdev offset size value))
                           :mapped nil)
    vdev))

;; An input device: a keyboard, a mouse or a tablet, by the events it says
;; it has.
(defun add-input (slot name bits &key axes (offers (list 0 1)) (agreeable t) (messages t) (registers t))
  (add-virtio slot #x1052 #x090000
              (make-vdev :name name :bits bits :axes axes :offers offers :agreeable agreeable)
              :messages messages :registers registers))

;; A disk, whose sectors are BYTES. It can do a good deal that no driver
;; here asks for, and bit 5 of that says that it cannot be written.
(defun add-disk (slot bytes &key read-only (answer 0) silent delay mute (offers (list (+ #x6e54 (if read-only 32 0)) 1)))
  (add-virtio slot #x1042 #x010000
              (make-vdev :disk bytes :read-only read-only :answer answer :silent silent :delay delay :mute mute
                         :offers offers)))

(defvar *keys-bits* '((1 0 0 0 #x40)))        ; events of type 1, and among their codes 30, the key A
(defvar *mouse-bits* '((1 0 0) (2 3)))        ; types 1 and 2
(defvar *tablet-bits* '((1 0 0) (3 3)))       ; types 1 and 3

;; An event from the device: into the next empty buffer of its first queue.
;; NIL when the driver has left it none.
(defun send-event (vdev type code value)
  (let* ((vq (aref (vdev-queues vdev) 0)) (first (next-available vq)))
    (when first
      (let ((buffer (car (chain vq first))))
        (unless (and (>= (second buffer) 8) (logbitp 1 (third buffer)))
          (failed "the driver gave the device a buffer of ~D bytes with the flags ~D for an event"
                  (second buffer) (third buffer)))
        (poke (first buffer) 2 type)
        (poke (+ (first buffer) 2) 2 code)
        (poke (+ (first buffer) 4) 4 (ldb (byte 32 0) value))
        (complete vdev vq first 8)
        t))))

(defun press (vdev key)
  (send-event vdev 1 key 1)
  (send-event vdev 0 0 0))

(defun release (vdev key)
  (send-event vdev 1 key 0)
  (send-event vdev 0 0 0))

(defun tap (vdev &rest keys)
  (dolist (key keys)
    (press vdev key)
    (release vdev key)))

;; The bus: what START finds, and says.
(new-machine)
(attach-bus)
(add-function 0 0 0 #x8086 #x29c0 #x060000)
(setf (le (add-function 0 1 0 #x1b36 #x000c #x060400 :header 1) #x19 1) 1) ; a bridge, with bus 1 behind it
(add-function 1 0 0 #x8086 #x10d3 #x020000)
(add-function 0 2 0 #x1234 #x1111 #x030000 :header #x80)                  ; a device with more functions than one
(add-function 0 2 3 #x8086 #x2922 #x010601)
(add-function 0 3 5 #x8086 #x9999 #x0c0330)                               ; nothing at its first function: not looked for
(defvar *keyboard* (add-input 4 "QEMU Virtio Keyboard" *keys-bits*))
(let ((disk (add-function 0 5 0 #x8086 #x1041 #x010180)))                 ; not Red Hat's, whatever its number
  (setf (le disk #x20 4) #xc041                                           ; its fifth base address is of ports
        (le disk #x34 1) #x40                                             ; and it does not say that it has
        (le disk #x40 1) 9))                                              ; capabilities, so what is there is none

(check (format nil "pci: 7 devices, by the configuration space at #x0030000000~%~
                    pci:   00:00.0 8086:29c0 a host bridge~%~
                    pci:   00:01.0 1b36:000c a PCI bridge~%~
                    pci:   00:02.0 1234:1111 a display controller~%~
                    pci:   00:02.3 8086:2922 a SATA controller~%~
                    pci:   00:04.0 1af4:1052 a keyboard~%~
                    pci:   00:05.0 8086:1041 an IDE controller~%~
                    pci:   01:00.0 8086:10d3 a network controller~%")
       (with-output-to-string (*standard-output*)
         (clara.pci:start)))
(check 7 (length (clara.pci:devices)))
(check-condition error (clara.unsafe:memory-16 (+ +ecam+ (ash 2 20)))) ; a bus that nothing leads to stays unmapped
(let ((keyboard (device-at 0 4 0)) (disk (device-at 0 5 0)))
  (check '(#x1af4 #x1052 #x090000 1) (list (clara.pci:device-vendor keyboard) (clara.pci:device-id keyboard)
                                           (clara.pci:device-kind keyboard) (clara.pci:device-revision keyboard)))
  (check '(#x40040000 :memory) (multiple-value-list (clara.pci:base-address keyboard 1)))
  (check '(#x8000400000 :memory) (multiple-value-list (clara.pci:base-address keyboard 4)))
  (check nil (clara.pci:base-address keyboard 0))
  (check '(#xc040 :ports) (multiple-value-list (clara.pci:base-address disk 4)))
  (check-condition error (clara.pci:map-registers disk 4 0 16))
  (check '((#x50 #x60 #x74) (#x40) nil)
         (list (clara.pci:capabilities keyboard 9) (clara.pci:capabilities keyboard #x11)
               (clara.pci:capabilities keyboard 5)))
  (check nil (clara.pci:capabilities disk 9))             ; it says that it has no list
  (check-condition error (clara.pci:message-interrupt disk 0))
  (check-condition error (clara.pci:message-interrupt keyboard 2)) ; its table has two messages
  (check 18 (clara.virtio:device-type keyboard))
  (check nil (clara.virtio:device-type disk))
  (setf (le (function-at (ash 4 15)) #x75 1) #x50)        ; a list that leads back into itself has an end all the same
  (check 47 (length (clara.pci:capabilities keyboard 9)))
  (setf (le (function-at (ash 4 15)) #x75 1) 0))

(new-machine)                                             ; a firmware that names no configuration space
(check "pci: the firmware names no configuration space, so no PCI device can be found"
       (string-right-trim '(#\Newline) (with-output-to-string (*standard-output*) (clara.pci:start))))
(check nil (clara.pci:devices))

;; A virtio device: the opening moves, and a queue.
(defun new-bus (&rest inputs)
  (new-machine)
  (attach-bus)
  (add-function 0 0 0 #x8086 #x29c0 #x060000)
  (prog1 (mapcar (lambda (input) (apply #'add-input input)) inputs)
    (with-output-to-string (*standard-output*)
      (clara.pci:start))))

(let* ((vdev (car (new-bus (list 3 "QEMU Virtio Keyboard" *keys-bits* :offers (list #x30000000 3)))))
       (pci (device-at 0 3 0))
       (device (clara.virtio:open-device pci))
       (message (car (clara.host:message-interrupts))))
  (check '(0 1 3 11) (reverse (vdev-history vdev)))       ; afresh, noticed, known, agreed: not ready yet
  (check '(0 1) (vdev-wanted vdev))                       ; version 1, and nothing else of what was offered
  (check #x406 (logand (le (vdev-config vdev) 4 2) #x406)) ; its registers answer, it may write memory, its line is off
  (check #x8001 (le (vdev-config vdev) #x42 2))           ; messages are on, and none is kept back
  (check (list (* 8 3) (logand (third message) #xffffffff) (ash (third message) -32) (fourth message) 0)
         (list (first message) (le (vdev-table vdev) 0 4) (le (vdev-table vdev) 4 4) (le (vdev-table vdev) 8 4)
               (le (vdev-table vdev) 12 4)))
  (check #xffff (vdev-config-message vdev))
  (check t (eq (clara.virtio:device-event device) (second message)))
  (let* ((queue (clara.virtio:open-queue device 1 8))
         (vq (aref (vdev-queues vdev) 1))
         (memory (clara.unsafe:allocate-memory 1)))
    (check '(8 8 0 1) (list (clara.virtio:queue-size queue) (vq-size vq) (vq-message vq) (vq-enabled vq)))
    (check 3 (length (remove-duplicates (list (vq-descriptors vq) (vq-available vq) (vq-used vq)))))
    (check '(0 0 0) (mapcar (lambda (address) (mod address 4096))
                            (list (vq-descriptors vq) (vq-available vq) (vq-used vq))))
    ;; A chain of three: two for the device to read, one for it to write.
    (check t (clara.virtio:queue-add queue (list (list memory 16 nil) (list (+ memory 16) 4 nil)
                                                 (list (+ memory 32) 100 t))
                                     :first))
    (check 1 (peek (+ (vq-available vq) 2) 2))
    (check (list (list memory 16 1) (list (+ memory 16) 4 1) (list (+ memory 32) 100 2))
           (chain vq (peek (+ (vq-available vq) 4) 2)))
    (check nil (clara.virtio:queue-take queue))           ; the device has not been told, and has done nothing
    (check t (clara.virtio:queue-add queue (list (list memory 8 t) (list memory 8 t)) :second))
    (check t (clara.virtio:queue-add queue (list (list memory 1 nil) (list memory 2 t)) :third))
    (check nil (clara.virtio:queue-add queue (list (list memory 1 nil) (list memory 1 nil)) :too-long))
    (check 3 (peek (+ (vq-available vq) 2) 2))            ; one descriptor is left, and nothing was added for the two
    (check t (clara.virtio:queue-add queue (list (list memory 1 nil)) :fourth))
    (check nil (clara.virtio:queue-add queue (list (list memory 1 nil)) :no-room))
    (clara.virtio:queue-notify queue)
    (check '(1) (vdev-notified vdev))
    (check '((:first 100) (:second 16) (:third 2) (:fourth 0) (nil))
           (list (multiple-value-list (clara.virtio:queue-take queue))
                 (multiple-value-list (clara.virtio:queue-take queue))
                 (multiple-value-list (clara.virtio:queue-take queue))
                 (multiple-value-list (clara.virtio:queue-take queue))
                 (multiple-value-list (clara.virtio:queue-take queue))))
    (check t (clara:wait-event (clara.virtio:device-event device) 0)) ; and it sent its message
    ;; Every descriptor is free again, and the counts go round past 16 bits.
    (check 8 (let ((added 0))
               (dotimes (i 9 added)
                 (when (clara.virtio:queue-add queue (list (list memory 1 t)) i)
                   (incf added)))))
    (clara.virtio:queue-notify queue)
    (check '(0 1 2 3 4 5 6 7 nil) (let ((taken nil))
                                    (dotimes (i 9 (reverse taken))
                                      (push (clara.virtio:queue-take queue) taken))))
    (check 66000 (let ((rounds 0))
                   (dotimes (i 66000 rounds)
                     (clara.virtio:queue-add queue (list (list memory 4 nil) (list memory 4 t)) (1+ i))
                     (clara.virtio:queue-notify queue)
                     (when (equal (list (1+ i) 4) (multiple-value-list (clara.virtio:queue-take queue)))
                       (incf rounds)))))
    (check nil (clara.virtio:queue-take queue))
    ;; A device that says it is done with something it never had.
    (poke (+ (vq-used vq) 4 (* 8 (mod (vq-done vq) 8))) 4 5)
    (poke (+ (vq-used vq) 2) 2 (logand (1+ (vq-done vq)) #xffff))
    (check-condition error (clara.virtio:queue-take queue))
    (check 128 (vdev-status vdev)))
  (check-condition error (clara.virtio:open-queue device 5)))  ; it has two queues

(let ((vdev (car (new-bus (list 3 "old" *keys-bits* :offers (list 0 0))))))      ; from before version 1
  (check-condition error (clara.virtio:open-device (device-at 0 3 0)))
  (check 128 (vdev-status vdev)))
(let ((vdev (car (new-bus (list 3 "stubborn" *keys-bits* :agreeable nil)))))     ; it wants more than it is given
  (check-condition error (clara.virtio:open-device (device-at 0 3 0)))
  (check 128 (vdev-status vdev)))
(let ((vdev (car (new-bus (list 3 "silent" *keys-bits* :messages nil)))))        ; it has no messages to send
  (check-condition error (clara.virtio:open-device (device-at 0 3 0)))
  (check 128 (vdev-status vdev)))
(new-bus (list 3 "nowhere" *keys-bits* :registers nil))                          ; it does not say where its registers are
(check-condition error (clara.virtio:open-device (device-at 0 3 0)))

;; Keys: which character each types.
(check '(97 65 65 97 1 1) (list (clara.input:key-character 30 nil nil nil) (clara.input:key-character 30 t nil nil)
                                (clara.input:key-character 30 nil nil t) (clara.input:key-character 30 t nil t)
                                (clara.input:key-character 30 nil t nil) (clara.input:key-character 30 t t t)))
(check "1234567890-=qwertyuiop[]asdfghjkl;'`\\zxcvbnm,./"
       (map 'string (lambda (key) (code-char (clara.input:key-character key nil nil nil)))
            '(2 3 4 5 6 7 8 9 10 11 12 13 16 17 18 19 20 21 22 23 24 25 26 27 30 31 32 33 34 35 36 37 38 39 40 41
              43 44 45 46 47 48 49 50 51 52 53)))
(check "!@#$%^&*()_+QWERTYUIOP{}ASDFGHJKL:\"~|ZXCVBNM<>?"
       (map 'string (lambda (key) (code-char (clara.input:key-character key t nil nil)))
            '(2 3 4 5 6 7 8 9 10 11 12 13 16 17 18 19 20 21 22 23 24 25 26 27 30 31 32 33 34 35 36 37 38 39 40 41
              43 44 45 46 47 48 49 50 51 52 53)))
(check "1!;:" (map 'string #'code-char (list (clara.input:key-character 2 nil nil t) (clara.input:key-character 2 t nil t)
                                             (clara.input:key-character 39 nil t nil) (clara.input:key-character 39 t t nil))))
(check '(10 10 8 127 9 32 47 42) (mapcar (lambda (key) (clara.input:key-character key nil nil nil)) '(28 96 14 111 15 57 98 55)))
(check "789-456+1230." (map 'string (lambda (key) (code-char (clara.input:key-character key nil nil nil)))
                            '(71 72 73 74 75 76 77 78 79 80 81 82 83)))
(check '(nil nil nil nil nil nil nil nil nil)   ; the keys that type nothing and have no code: the modifiers, and no key at all
       (mapcar (lambda (key) (clara.input:key-character key t t t)) '(0 29 42 54 56 58 100 99 300)))
;; Escape is a character. The arrows and their like and the function keys
;; type none, and each has a code of its own past the last that a character
;; can have.
(defvar *keys-without-characters*
  (list clara.input:+up+ clara.input:+down+ clara.input:+left+ clara.input:+right+ clara.input:+home+ clara.input:+end+
        clara.input:+page-up+ clara.input:+page-down+ clara.input:+insert+
        clara.input:+f1+ (+ clara.input:+f1+ 1) (+ clara.input:+f1+ 9) (+ clara.input:+f1+ 10) (+ clara.input:+f1+ 11)))
(check (cons 27 *keys-without-characters*)
       (mapcar (lambda (key) (clara.input:key-character key t nil t)) '(1 103 108 105 106 102 107 104 109 110 59 60 68 87 88)))
(check '(14 t t)
       (list (length (remove-duplicates *keys-without-characters*))
             (every (lambda (code) (<= char-code-limit code)) *keys-without-characters*)
             (every (lambda (code) (< code clara.input:+alt+)) *keys-without-characters*)))

;; A keyboard: what its driver sets up, and what comes of the keys.
(let* ((vdev (car (new-bus (list 3 "QEMU Virtio Keyboard" *keys-bits*))))
       (input (progn (attach-pl011 #x9000000) (clara.input::open-input (device-at 0 3 0))))
       (vq (aref (vdev-queues vdev) 0)))
  (check '("QEMU Virtio Keyboard" "a keyboard") (list (clara.input::input-name input) (clara.input::input-kind input)))
  (check '(0 1 3 11 15) (reverse (vdev-history vdev)))    ; and ready
  (check '(64 1 64) (list (vq-size vq) (vq-enabled vq) (peek (+ (vq-available vq) 2) 2)))
  (check '(0) (vdev-notified vdev))
  (check 64 (length (remove-duplicates (loop for i below 64 collect (first (car (chain vq i)))))))
  (tap vdev 35 23 28)                                     ; h, i, Enter
  (clara.input::take-events input)
  (check "hi" (clara.console:read-text-line))
  (check '(0 0) (vdev-notified vdev))                     ; the device was told that it has its buffers back
  (check 76 (peek (+ (vq-available vq) 2) 2))
  (press vdev 42)                                         ; with the left Shift, and then the right one
  (tap vdev 35)
  (release vdev 42)
  (tap vdev 23)
  (press vdev 54)
  (tap vdev 2)
  (press vdev 42)
  (release vdev 54)
  (tap vdev 53)                                           ; the left one is still down
  (release vdev 42)
  (tap vdev 53 28)
  (clara.input::take-events input)
  (check "Hi!?/" (clara.console:read-text-line))
  (tap vdev 58 30 2 58 30 28)                             ; Caps Lock, on and off again
  (clara.input::take-events input)
  (check "A1a" (clara.console:read-text-line))
  (press vdev 97)                                         ; Ctrl-D, with the right Ctrl
  (tap vdev 32)
  (release vdev 97)
  (clara.input::take-events input)
  (check '(4) clara.console::*keys*)
  (check nil (clara.console:read-text-line))
  (press vdev 29)                                         ; Ctrl-C while nothing reads a line
  (tap vdev 46)
  (release vdev 29)
  (clara.input::take-events input)
  (check '(1 nil) (list (clara.host:keyboard-breaks) clara.console::*keys*))
  (send-event vdev 1 30 2)                                ; a key that says it is still down types again
  (send-event vdev 0 0 0)
  (tap vdev 14 14 31 28)                                  ; and Backspace takes back what there is
  (clara.input::take-events input)
  (check "s" (clara.console:read-text-line))
  (tap vdev 30 103 105 1 59 31 28)                        ; a line takes no arrow, no Escape and no function key
  (clara.input::take-events input)
  (check "as" (clara.console:read-text-line))
  ;; Whoever has the keys is handed those as well, and a key with Alt held,
  ;; either of the two, has +ALT+ added to its code.
  (let ((typed nil))
    (clara.input:send-keys-to (lambda (code) (push code typed)))
    (tap vdev 103)
    (press vdev 56)
    (tap vdev 15)
    (press vdev 100)
    (release vdev 56)
    (tap vdev 108)
    (release vdev 100)
    (tap vdev 30 111)
    (clara.input::take-events input)
    (clara.input:send-keys-to nil)
    (check (list clara.input:+up+ (+ clara.input:+alt+ 9) (+ clara.input:+alt+ clara.input:+down+) 97 127) (reverse typed)))
  (dotimes (i 300)                                        ; the buffers go round many times
    (tap vdev 30)
    (clara.input::take-events input))
  (tap vdev 28)
  (clara.input::take-events input)
  (check 300 (length (clara.console:read-text-line)))
  (check nil (clara.input::take-events input)))           ; nothing new: nothing to do, and nothing to tell the device

;; A mouse and a tablet: where the pointer is, and its buttons.
(let* ((vdevs (new-bus (list 3 "QEMU Virtio Mouse" *mouse-bits*)
                       (list 4 "QEMU Virtio Tablet" *tablet-bits* :axes '((0 0 32767) (1 100 1100)))))
       (mouse (clara.input::open-input (device-at 0 3 0)))
       (tablet (clara.input::open-input (device-at 0 4 0)))
       (changed (clara.input:pointer-changed)))
  (flet ((events (input vdev &rest events)
           (loop for (type code value) on events by #'cdddr
                 do (send-event vdev type code value))
           (clara.input::take-events input)
           (prog1 (list (multiple-value-list (clara.input:pointer)) (clara:wait-event changed 0))
             (loop while (clara:wait-event changed 0)))))
    (setq clara.input::*inputs* (list mouse tablet))
    (check '("a mouse" "a tablet") (list (clara.input::input-kind mouse) (clara.input::input-kind tablet)))
    (check '((0 . 32767) (100 . 1100))
           (list (clara.input::input-x-limits tablet) (clara.input::input-y-limits tablet)))
    (clara.input:set-pointer-limits 1000 500)
    (check '(500 250 0) (multiple-value-list (clara.input:pointer)))
    (check '((530 230 0) t) (events mouse (first vdevs) 2 0 30 2 1 -20 0 0 0))
    (check '((530 230 0) nil) (events mouse (first vdevs) 2 0 5))        ; nothing moves until the device says "that is all"
    (check '((535 230 0) t) (events mouse (first vdevs) 0 0 0))
    (check '((0 499 0) t) (events mouse (first vdevs) 2 0 -100000 2 1 100000 0 0 0)) ; and never off the screen
    (check '((0 499 1) t) (events mouse (first vdevs) 1 #x110 1 0 0 0))
    (check '((0 499 5) t) (events mouse (first vdevs) 1 #x112 1 0 0 0))
    (check '((0 499 5) nil) (events mouse (first vdevs) 0 0 0))          ; nothing changed: nobody is told
    (check '((0 499 7) t) (events tablet (second vdevs) 1 #x111 1 0 0 0)) ; a button is down on either of them
    (check '((0 499 6) t) (events mouse (first vdevs) 1 #x110 0 0 0 0))
    (check '((0 499 2) t) (events mouse (first vdevs) 1 #x112 0 0 0 0))
    (check '((0 499 0) t) (events tablet (second vdevs) 1 #x111 0 0 0 0))
    ;; A place on the tablet is a place on the screen: half way across, and all the way down.
    (check '((499 499 0) t) (events tablet (second vdevs) 3 0 16383 3 1 1100 0 0 0))
    (check '((999 0 0) t) (events tablet (second vdevs) 3 0 32767 3 1 100 0 0 0))
    (check '((0 0 0) t) (events tablet (second vdevs) 3 0 0 0 0 0))      ; one axis, and the other stays
    (check '((0 249 0) t) (events tablet (second vdevs) 3 1 600 0 0 0))
    (check '((0 0 0) t) (events tablet (second vdevs) 3 1 -5 0 0 0))     ; a tablet that counts past its own ends
    (check '((10 0 0) t) (events mouse (first vdevs) 2 0 10 0 0 0))     ; and the mouse goes on from where the pen was
    ;; The pointer can be sent to a function, which is told of every change
    ;; of it, and before whoever waits for the event is. A function that
    ;; fails is said, and the pointer goes on.
    (let ((told nil))
      (clara.input:send-pointer-to (lambda (x y buttons) (push (list x y buttons (clara:wait-event changed 0)) told)))
      (check '((15 0 0) t) (events mouse (first vdevs) 2 0 5 0 0 0))
      (check '((15 0 1) t) (events mouse (first vdevs) 1 #x110 1 0 0 0))
      (check '((15 0 1) nil) (events mouse (first vdevs) 0 0 0))         ; nothing changed: nobody is told
      (check '((15 0 1 nil) (15 0 0 nil)) told)
      (clara.input:send-pointer-to (lambda (x y buttons) (error "no place like ~D ~D ~D" x y buttons)))
      (check (format nil "input: what was typed or pointed at came to nothing: no place like 20 0 1~%")
             (with-output-to-string (*standard-output*)
               (check '((20 0 1) t) (events mouse (first vdevs) 2 0 5 0 0 0))))
      (clara.input:send-pointer-to nil)
      (check '((25 0 1) t) (events mouse (first vdevs) 2 0 5 0 0 0))
      (check 2 (length told)))))

;; What is typed can be sent to a function as well, in place of the
;; console; and START, which is for a new boot, sends both where they went
;; at first.
(let ((input (clara.input::make-input)) (got nil))
  (setq clara.console::*keys* nil)
  (clara.input:send-keys-to (lambda (code) (push code got)))
  (clara.input::key-event input 30 1)          ; the key A, down and up
  (clara.input::key-event input 30 0)
  (check '((97) nil) (list got clara.console::*keys*))
  (clara.input:send-keys-to (lambda (code) (error "nobody is at ~D" code)))
  (check (format nil "input: what was typed or pointed at came to nothing: nobody is at 97~%")
         (with-output-to-string (*standard-output*)
           (clara.input::key-event input 30 1)))
  (clara.input::key-event input 30 0)
  (clara.input:send-keys-to nil)
  (clara.input::key-event input 31 1)          ; S, for the console
  (clara.input::key-event input 31 0)
  (check '((97) (115)) (list got clara.console::*keys*))
  (setq clara.console::*keys* nil)
  (clara.input:send-keys-to #'identity)
  (clara.input:send-pointer-to #'list)
  (new-bus)
  (with-output-to-string (*standard-output*)
    (clara.input:start))
  (check '(nil nil) (list clara.input::*keys-to* clara.input::*pointer-to*)))

;; START: it finds the devices, says what they are, and gives each a
;; thread, which takes in what the device's message announces.
(let* ((vdevs (new-bus (list 3 "QEMU Virtio Keyboard" *keys-bits*)
                       (list 4 "QEMU Virtio Mouse" *mouse-bits*)
                       (list 5 "broken" *keys-bits* :offers (list 0 0))))
       (threads (length (clara:all-threads))))
  (setq clara.input:*repeat-delay* 60       ; for every thread, the ones that START makes included
        clara.input:*repeat-interval* 10)
  (attach-pl011 #x9000000)
  (clara.host:set-framebuffer (clara.unsafe:allocate-memory 1) 640 480 2560 #xff0000 #x00ff00 #x0000ff)
  (let ((said (with-output-to-string (*standard-output*)
                (clara.input:start))))
    (check t (and (search (format nil "input: 00:03.0 is a keyboard, QEMU Virtio Keyboard~%") said)
                  (search (format nil "input: 00:04.0 is a mouse, QEMU Virtio Mouse~%") said)
                  (search "input: 00:05.0 did not start: the virtio device at 00:05.0 is from before version 1" said)
                  t)))
  (check '(2 2) (list (length (clara.input:devices)) (- (length (clara:all-threads)) threads)))
  (check '(320 240 0) (multiple-value-list (clara.input:pointer)))      ; the middle of the screen
  (tap (first vdevs) 24 37 28)                                           ; o, k, Enter
  (check "ok" (sb-ext:with-timeout 10 (clara.console:read-text-line)))
  (send-event (second vdevs) 2 0 7)
  (send-event (second vdevs) 0 0 0)
  (check t (sb-ext:with-timeout 10 (clara:wait-event (clara.input:pointer-changed))))
  (check '(327 240 0) (multiple-value-list (clara.input:pointer)))
  ;; A key that stays down types again after a while, and then again and again.
  (press (first vdevs) 30)
  (sleep 0.5)
  (release (first vdevs) 30)
  (tap (first vdevs) 48)
  (sleep 0.2)
  (tap (first vdevs) 28)
  (let ((line (sb-ext:with-timeout 10 (clara.console:read-text-line))))
    (check t (and (< 5 (length line) 60) (char= (char line (1- (length line))) #\b)
                  (every (lambda (character) (char= character #\a)) (subseq line 0 (1- (length line)))))))
  (setq clara.input:*repeat-delay* 400
        clara.input:*repeat-interval* 40)
  (dolist (thread (clara:all-threads))
    (unless (eq thread (clara:current-thread))
      (clara:destroy-thread thread)
      (ignore-errors (clara:join-thread thread)))))

(let ((said (with-output-to-string (*standard-output*)   ; a machine without a keyboard
              (new-bus)
              (clara.input:start))))
  (check "input: no keyboard and no mouse that has a driver here: the serial port is where to type"
         (string-right-trim '(#\Newline) said)))

;; Two devices that move the pointer at the same moment. Each has a thread
;; of its own, here as on the machine, and neither may undo what the other
;; did. Under SBCL the two really run at once, so a pointer whose place is
;; read in one step and written in another loses moves here by the
;; hundred; on ClaraOS it took a button let go on the tablet in the same
;; instant as a move of the mouse, which is what a session of the boot test
;; does, and one boot in ten or so.
(let ((mouse (clara.input::make-input)) (tablet (clara.input::make-input)))
  (clara.input:set-pointer-limits 10000 10000)
  (flet ((moves (input axis)
           (clara:make-thread (lambda ()
                                (dotimes (i 2000)
                                  (clara.input::handle-event input 2 axis 1)
                                  (clara.input::handle-event input 0 0 0))))))
    (mapc #'clara:join-thread (list (moves mouse 0) (moves tablet 1))))
  (check '(7000 7000 0) (multiple-value-list (clara.input:pointer))))

;;; Disks that are made up: virtio block devices on the same bus, each
;;; with its sectors in a vector, which do what such a device does with a
;;; request, and look at how the driver put it to them.

(defun pattern (sectors)
  (let ((bytes (make-array (* 512 sectors) :element-type '(unsigned-byte 8))))
    (dotimes (i (length bytes) bytes)
      (setf (aref bytes i) (mod (+ i (* 7 (floor i 512))) 251)))))

;; What is in the machine's memory at an address.
(defun memory-bytes (address count)
  (let ((index (- address clara.host:+memory-base+)))
    (subseq clara.host::*memory* index (+ index count))))

;; A machine with these disks and nothing else: each is (slot bytes . what
;; ADD-DISK takes). The devices that were made of them.
(defun new-disks (&rest disks)
  (new-machine)
  (attach-bus)
  (add-function 0 0 0 #x8086 #x29c0 #x060000)
  (prog1 (mapcar (lambda (disk) (apply #'add-disk disk)) disks)
    (with-output-to-string (*standard-output*)
      (clara.pci:start))))

(defun said-by (function)
  (with-output-to-string (*standard-output*)
    (funcall function)))

;; One disk: what the driver sets up, and what it reads and writes.
(let* ((bytes (pattern 100))
       (vdev (car (new-disks (list 3 bytes))))
       (said (said-by #'clara.disk:start))
       (disk (car (clara.disk:disks)))
       (vq (aref (vdev-queues vdev) 0))
       (memory (clara.unsafe:allocate-memory 2))
       (pages (clara.host:allocated-pages)))
  (check (format nil "disk: 00:03.0 has 100 sectors of 512 bytes, 0 MiB~%") said)
  (check '(0 1 3 11 15) (reverse (vdev-history vdev)))
  (check '(0 1) (vdev-wanted vdev))                       ; of all that it offers, version 1 and no more
  (check '(8 1 0) (list (vq-size vq) (vq-enabled vq) (vq-message vq)))
  (check '("00:03.0" 100 nil 1) (list (clara.disk:disk-name disk) (clara.disk:disk-sectors disk)
                                      (clara.disk:disk-read-only disk) (length (clara.disk:disks))))
  (check 3 (clara.disk:read-sectors disk 5 3 memory))
  (check t (equalp (memory-bytes memory 1536) (subseq bytes 2560 4096)))
  (check 0 (aref (memory-bytes (+ memory 1536) 1) 0))     ; and not a byte more
  (check '((0 5 3)) (vdev-requests vdev))
  (check '(0) (vdev-notified vdev))
  (check 1 (clara.disk:read-sectors disk 99 1 memory))    ; the last sector
  (check t (equalp (memory-bytes memory 512) (subseq bytes (* 99 512))))
  (dotimes (i 1024)
    (setf (clara.unsafe:memory-8 (+ memory i)) (mod (* 7 i) 256)))
  (check 2 (clara.disk:write-sectors disk 97 2 memory))
  (check t (and (equalp (subseq bytes (* 97 512) (* 99 512)) (memory-bytes memory 1024))
                (equalp (subseq bytes (* 96 512) (* 97 512)) (subseq (pattern 100) (* 96 512) (* 97 512)))
                (equalp (subseq bytes (* 99 512)) (subseq (pattern 100) (* 99 512)))))
  (check '(1 97 2) (car (vdev-requests vdev)))
  ;; Sectors that the disk does not have are refused here, and the device is not asked.
  (check-condition error (clara.disk:read-sectors disk 99 2 memory))
  (check-condition error (clara.disk:read-sectors disk 100 1 memory))
  (check-condition error (clara.disk:read-sectors disk -1 1 memory))
  (check-condition error (clara.disk:read-sectors disk 0 0 memory))
  (check-condition error (clara.disk:write-sectors disk 100 1 memory))
  (check-condition error (clara.disk:read-sectors disk nil 1 memory))
  (check 3 (length (vdev-requests vdev)))
  ;; The requests go round the queue many times, and two threads take turns at the disk.
  (check 300 (let ((right 0))
               (dotimes (i 300 right)
                 (clara.disk:read-sectors disk (mod (* 37 i) 100) 1 memory)
                 (when (equalp (memory-bytes memory 512)
                               (subseq bytes (* 512 (mod (* 37 i) 100)) (* 512 (1+ (mod (* 37 i) 100)))))
                   (incf right)))))
  (check '(100 100)
         (mapcar #'clara:join-thread
                 (mapcar (lambda (first)
                           (clara:make-thread
                            (lambda ()
                              (let ((mine (clara.unsafe:allocate-memory 1)) (right 0))
                                (dotimes (i 100 (progn (clara.unsafe:free-memory mine 1) right))
                                  (clara.disk:read-sectors disk (+ first (mod i 40)) 1 mine)
                                  (when (equalp (memory-bytes mine 512)
                                                (subseq (pattern 100) (* 512 (+ first (mod i 40)))
                                                        (* 512 (+ first (mod i 40) 1))))
                                    (incf right)))))))
                         '(0 50))))
  (check pages (clara.host:allocated-pages)))

;; A disk that cannot be written says so, and is not asked to.
(let* ((vdev (car (new-disks (list 3 (pattern 4096) :read-only t))))
       (said (said-by #'clara.disk:start))
       (disk (car (clara.disk:disks)))
       (memory (clara.unsafe:allocate-memory 1)))
  (check (format nil "disk: 00:03.0 has 4096 sectors of 512 bytes, 2 MiB, and cannot be written~%") said)
  (check '(32 1) (vdev-wanted vdev))
  (check t (clara.disk:disk-read-only disk))
  (check-condition error (clara.disk:write-sectors disk 0 1 memory))
  (check nil (vdev-requests vdev))
  (check 1 (clara.disk:read-sectors disk 4095 1 memory)))

;; A disk that fails at what it is asked, one that does not know the
;; request, and one that never answers.
(let* ((vdevs (new-disks (list 3 (pattern 16) :answer 1) (list 4 (pattern 16) :answer 2)
                         (list 5 (pattern 16) :silent t)))
       (disks (progn (said-by #'clara.disk:start) (clara.disk:disks)))
       (memory (clara.unsafe:allocate-memory 1)))
  (check 3 (length disks))
  (check "the disk 00:03.0 could not read its sectors 2 to 3"
         (handler-case (clara.disk:read-sectors (first disks) 2 2 memory) (error (c) (princ-to-string c))))
  (check "the disk 00:03.0 could not write its sectors 0 to 0"
         (handler-case (clara.disk:write-sectors (first disks) 0 1 memory) (error (c) (princ-to-string c))))
  (check-condition error (clara.disk:read-sectors (second disks) 0 1 memory))
  (check 2 (length (vdev-requests (first vdevs))))         ; and the disk can be asked again
  (let ((clara.disk:*patience* 300))
    (check-condition error (clara.disk:read-sectors (third disks) 0 1 memory))
    (check "the disk 00:05.0 left a request unanswered, and is asked nothing more"
           (handler-case (clara.disk:read-sectors (third disks) 0 1 memory) (error (c) (princ-to-string c)))))
  (check 1 (length (vdev-requests (third vdevs)))))

;; A disk that takes its time: the driver waits for its message. And one
;; whose message never comes: the driver looks at the queue again before
;; long, and finds its answer there.
(let* ((bytes (pattern 16))
       (disks (progn (new-disks (list 3 bytes :delay 0.35) (list 4 bytes :delay 0.05 :mute t))
                     (said-by #'clara.disk:start)
                     (clara.disk:disks)))
       (memory (clara.unsafe:allocate-memory 1)))
  (dolist (disk disks)
    (let ((before (get-internal-real-time)))
      (check 1 (clara.disk:read-sectors disk 9 1 memory))
      (check t (equalp (memory-bytes memory 512) (subseq bytes (* 9 512) (* 10 512))))
      (check t (< 0.04 (/ (- (get-internal-real-time) before) internal-time-units-per-second) 2)))
    (check 1 (clara.disk:read-sectors disk 3 1 memory))
    (check t (equalp (memory-bytes memory 512) (subseq bytes (* 3 512) (* 4 512))))))

;; START: the disks among the devices, and what is said of each.
(let ((said (progn
              (new-machine)
              (attach-bus)
              (add-function 0 0 0 #x8086 #x29c0 #x060000)
              (add-input 2 "QEMU Virtio Keyboard" *keys-bits*)
              (add-disk 3 (pattern 2048))
              (add-disk 4 (pattern 8) :offers (list 0 0))
              (add-disk 5 (pattern 6000) :read-only t)
              (with-output-to-string (*standard-output*)
                (clara.pci:start))
              (said-by #'clara.disk:start))))
  (check t (and (search (format nil "disk: 00:03.0 has 2048 sectors of 512 bytes, 1 MiB~%") said)
                (search "disk: 00:04.0 did not start: the virtio device at 00:04.0 is from before version 1" said)
                (search (format nil "disk: 00:05.0 has 6000 sectors of 512 bytes, 2 MiB, and cannot be written~%") said)
                t))
  (check '("00:03.0" "00:05.0") (mapcar #'clara.disk:disk-name (clara.disk:disks))))
(new-bus (list 3 "QEMU Virtio Keyboard" *keys-bits*))
(check "disk: no disk that has a driver here: the files are the ones that were read as the machine started"
       (string-right-trim '(#\Newline) (said-by #'clara.disk:start)))
(check nil (clara.disk:disks))

;;; Volumes that are made up: FAT of the three kinds, laid out here by the
;;; specification and not by lisp/fat.lisp, with what a directory can hold
;;; that a reader has to get right. The boots read the volumes that
;;; tools/mkdisk.py makes, and by hand the image that macOS makes: more
;;; witnesses.

(defun octets (text)
  (if (stringp text)
      (sb-ext:string-to-octets text :external-format :utf-8)
      (coerce text '(vector (unsigned-byte 8)))))

(defstruct fat
  kind bytes cluster-sectors reserved table-sectors root-sectors data clusters
  (next 2)       ; the next cluster to be handed out,
  (stride 1)     ; how far apart the clusters of one file lie,
  backwards      ; whether a file goes through its clusters from the highest down,
  (end #xfffffff)) ; and what the table has for the last cluster of a file: the highest eight numbers all say so

(defun cluster-offset (fat cluster)
  (* 512 (+ (fat-data fat) (* (- cluster 2) (fat-cluster-sectors fat)))))

;; An entry of the table, in every copy of it.
(defun (setf fat-entry) (value fat cluster)
  (dotimes (copy 2 value)
    (let ((base (* 512 (+ (fat-reserved fat) (* copy (fat-table-sectors fat))))) (bytes (fat-bytes fat)))
      (ecase (fat-kind fat)
        (12 (let ((at (+ base cluster (floor cluster 2))))
              (if (oddp cluster)
                  (setf (ldb (byte 4 4) (aref bytes at)) (ldb (byte 4 0) value)
                        (aref bytes (1+ at)) (ldb (byte 8 4) value))
                  (setf (aref bytes at) (ldb (byte 8 0) value)
                        (ldb (byte 4 0) (aref bytes (1+ at))) (ldb (byte 4 8) value)))))
        (16 (setf (le bytes (+ base (* 2 cluster)) 2) value))
        ;; Of 32 bits the upper four mean nothing, and are not left empty here.
        (32 (setf (le bytes (+ base (* 4 cluster)) 4) (logior #xa0000000 (ldb (byte 28 0) value))))))))

(defun fat-allocate (fat count)
  (let ((clusters (loop repeat count
                        collect (prog1 (fat-next fat)
                                  (incf (fat-next fat) (fat-stride fat))))))
    (when (> (fat-next fat) (+ 2 (fat-clusters fat)))
      (error "the volume of the test is full"))
    (if (fat-backwards fat) (reverse clusters) clusters)))

;; Bytes as a file: in clusters, which the table chains. The first cluster,
;; which is FIRST when the file has been promised one.
(defun fat-store (fat bytes &optional first)
  (let* ((each (* 512 (fat-cluster-sectors fat)))
         (count (max 1 (ceiling (length bytes) each)))
         (clusters (append (and first (list first)) (fat-allocate fat (- count (if first 1 0))))))
    (loop for (cluster next) on clusters
          for start from 0 by each
          do (replace (fat-bytes fat) bytes :start1 (cluster-offset fat cluster)
                                            :start2 (min start (length bytes))
                                            :end2 (min (+ start each) (length bytes)))
             (setf (fat-entry fat cluster) (or next (fat-end fat))))
    (car clusters)))

;; A name of eight characters and three, as its 11 bytes, when the name is
;; one; and the name that stands in for a long one.
(defun eight-three (name)
  (let* ((dot (position #\. name))
         (base (subseq name 0 dot))
         (extension (if dot (subseq name (1+ dot)) ""))
         (short (make-array 11 :element-type '(unsigned-byte 8) :initial-element 32)))
    (when (and (<= 1 (length base) 8) (<= (length extension) 3)
               (every (lambda (character)
                        (and (< (char-code character) 127) (or (alphanumericp character) (find character "_-~"))))
                      (concatenate 'string base extension)))
      (replace short (octets (string-upcase base)))
      (replace short (octets (string-upcase extension)) :start1 8)
      short)))

(defun alias (name number)
  (let* ((dot (position #\. name :from-end t))
         (clean (lambda (text)
                  (remove-if-not (lambda (character) (and (< (char-code character) 127) (alphanumericp character)))
                                 (string-upcase text))))
         (base (funcall clean (subseq name 0 dot)))
         (extension (if dot (funcall clean (subseq name (1+ dot))) "")))
    (eight-three (format nil "~A~~~D~@[.~A~]"
                         (subseq base 0 (min (- 7 (length (princ-to-string number))) (length base))) number
                         (and (plusp (length extension)) (subseq extension 0 (min 3 (length extension))))))))

(defun utf-16 (name)
  (loop for character across name
        for code = (char-code character)
        if (< code #x10000) collect code
        else collect (+ #xd800 (ash (- code #x10000) -10)) and collect (+ #xdc00 (logand code #x3ff))))

(defun short-checksum (short)
  (let ((sum 0))
    (loop for byte across short
          do (setq sum (logand (+ (if (oddp sum) #x80 0) (ash sum -1) byte) 255)))
    sum))

(defun short-record (short what cluster size &optional (small 0))
  (let ((record (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0)))
    (replace record short)
    (setf (aref record 11) what
          (aref record 12) small
          (le record 20 2) (ash cluster -16)
          (le record 26 2) (logand cluster #xffff)
          (le record 28 4) size)
    record))

;; The entries that spell a long name out, in the order they have on the
;; disk: the last 13 characters first.
(defun long-records (name sum)
  (let* ((units (utf-16 name))
         (units (if (zerop (mod (length units) 13)) units (append units (list 0))))
         (count (ceiling (length units) 13))
         (records nil))
    (dotimes (i count records)
      (let ((record (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0)))
        (setf (aref record 0) (logior (1+ i) (if (= i (1- count)) #x40 0))
              (aref record 11) #x0f
              (aref record 13) sum)
        (loop for place in '(1 3 5 7 9 14 16 18 20 22 24 28 30)
              for j from (* 13 i)
              do (setf (le record place 2) (or (nth j units) #xffff)))
        (push record records)))))

;; The bytes of a directory that holds ITEMS, whose files and directories
;; are put on the volume as they come. An item is (name contents . options):
;; a string or a vector of bytes for a file, a list of items for a
;; directory, :LABEL for the name of the volume, :DELETED for an entry that
;; is no longer one. The options: :SMALL, the name is of eight and three
;; and in small letters by the two bits for it; :BROKEN, its long name was
;; made for another short name; :PARTIAL, the first part of its long name
;; is not there; :SIZE and :CLUSTER, what the entry says in place of the
;; truth; :FROM, the cluster that the file begins in. SELF and
;; PARENT are the clusters for the two entries that a directory which is
;; not the root begins with. On the kinds 12 and 16 the upper half of an
;; entry's first cluster means nothing, and is not left empty here.
(defun fat-directory (fat items &optional self (parent 0))
  (let ((records nil) (aliases 0))
    (when self
      (push (short-record (octets ".          ") #x10 self 0) records)
      (push (short-record (octets "..         ") #x10 parent 0) records))
    (dolist (item items)
      (destructuring-bind (name contents &key small broken partial size cluster from) item
        (when from
          (setf (fat-next fat) from))
        (if (eq contents :label)
            (push (short-record (octets (format nil "~11A" name)) #x08 0 0) records)
            (let* ((plain (eight-three name))
                   (short (or plain (alias name (incf aliases))))
                   (long (not (and plain (or small (string= name (string-upcase name))))))
                   (flags (if small
                              (+ (if (some #'lower-case-p (subseq name 0 (position #\. name))) 8 0)
                                 (if (and (position #\. name) (some #'lower-case-p (subseq name (position #\. name))))
                                     16
                                     0))
                              0))
                   (mine (cond ((eq contents :deleted) nil)
                               ((listp contents)
                                (let ((first (car (fat-allocate fat 1))))
                                  (list (short-record short #x10
                                                      (fat-store fat (fat-directory fat contents first (or self 0)) first)
                                                      0))))
                               (t (let ((bytes (octets contents)))
                                    (list (short-record short #x20
                                                        (or cluster (if (zerop (length bytes)) 0 (fat-store fat bytes)))
                                                        (or size (length bytes)) flags)))))))
              (when (eq contents :deleted)
                (setq mine (list (short-record short #x20 0 0))))
              (unless (= (fat-kind fat) 32)
                (dolist (record mine)
                  (setf (le record 20 2) #x00ee)))
              (when long
                (setq mine (append (long-records name (logand (+ (short-checksum short) (if broken 1 0)) 255)) mine)))
              (when partial
                (setq mine (append (butlast mine 2) (last mine))))
              (when (eq contents :deleted)
                (dolist (record mine)
                  (setf (aref record 0) #xe5)))
              (dolist (record mine)
                (push record records))))))
    (apply #'concatenate '(vector (unsigned-byte 8)) (reverse records))))

;; A volume of a kind, with a tree of files on it. CLUSTERS is how many
;; clusters it has, which is what makes it the kind it is, and the rest
;; says how its files lie: from which cluster on, how far apart, in which
;; direction, with which mark at their end; and ROOT where the directory of
;; the root begins on the kind 32, which with INFORMATION has the sector
;; that says how many of its clusters are free.
(defun make-fat-volume (kind tree &key (cluster-sectors 1) clusters (from 2) (stride 1) backwards (end #xfffffff)
                                    (root 2) information)
  (let* ((clusters (or clusters (ecase kind (12 3000) (16 5000) (32 66000))))
         (reserved (if (= kind 32) 32 1))
         (root-entries (ecase kind (12 224) (16 512) (32 0)))
         (root-sectors (ceiling (* 32 root-entries) 512))
         (table-sectors (ceiling (* (+ clusters 2) kind) (* 8 512)))
         (data (+ reserved (* 2 table-sectors) root-sectors))
         (sectors (+ data (* clusters cluster-sectors)))
         (bytes (make-array (* 512 sectors) :element-type '(unsigned-byte 8) :initial-element 0))
         (fat (make-fat :kind kind :bytes bytes :cluster-sectors cluster-sectors :reserved reserved
                        :table-sectors table-sectors :root-sectors root-sectors :data data :clusters clusters
                        :stride stride :backwards backwards :end end)))
    (replace bytes '(#xeb #x3c #x90))
    (replace bytes (octets "CLARATST") :start1 3)
    (setf (le bytes 11 2) 512
          (le bytes 13 1) cluster-sectors
          (le bytes 14 2) reserved
          (le bytes 16 1) 2
          (le bytes 17 2) root-entries
          (le bytes 19 2) (if (< sectors 65536) sectors 0)
          (le bytes 21 1) #xf8
          (le bytes 22 2) (if (= kind 32) 0 table-sectors)
          (le bytes 32 4) (if (< sectors 65536) 0 sectors)
          (le bytes 510 2) #xaa55)
    (when (= kind 32)
      (setf (le bytes 36 4) table-sectors
            (le bytes 44 4) root))
    (setf (fat-entry fat 0) #xffffff8
          (fat-entry fat 1) #xfffffff)
    (if (= kind 32)
        (progn
          (setf (fat-next fat) (max from (1+ root)))
          (fat-store fat (fat-directory fat tree) root))
        (progn
          (setf (fat-next fat) from)
          (replace bytes (fat-directory fat tree) :start1 (* 512 (+ reserved (* 2 table-sectors))))))
    (when (and information (= kind 32))
      (setf (le bytes 48 2) 1
            (le bytes 512 4) #x41615252
            (le bytes (+ 512 484) 4) #x61417272
            (le bytes (+ 512 488) 4) (loop for cluster from 2 below (+ clusters 2)
                                           count (zerop (le bytes (+ (* 512 reserved) (* 4 cluster)) 4)))
            (le bytes (+ 512 492) 4) #xffffffff
            (le bytes (+ 512 508) 4) #xaa550000))
    fat))

;; A disk with volumes on it. TABLE is :NONE for a disk that is one volume
;; from end to end, :OLD for a table of partitions in the first sector, and
;; :NEW for the one behind it. Each volume is (sector . bytes).
(defun make-disk (table &rest volumes)
  (if (eq table :none)
      (cdar volumes)
      (let* ((end (reduce #'max (mapcar (lambda (volume) (+ (car volume) (floor (length (cdr volume)) 512))) volumes)))
             (disk (make-array (* 512 (+ end 40)) :element-type '(unsigned-byte 8) :initial-element 0)))
        (setf (le disk 510 2) #xaa55)
        (ecase table
          (:old
           ;; The first place in the table is empty, and the last is a partition that is none.
           (setf (le disk (+ 446 48 4) 1) #x83
                 (le disk (+ 446 48 8) 4) 1)
           (loop for (first . bytes) in volumes
                 for entry from (+ 446 16) by 16
                 do (setf (le disk (+ entry 4) 1) #x0c
                          (le disk (+ entry 8) 4) first
                          (le disk (+ entry 12) 4) (floor (length bytes) 512))))
          (:new
           (setf (le disk (+ 446 4) 1) #xee
                 (le disk (+ 446 8) 4) 1
                 (le disk (+ 446 12) 4) (1- (floor (length disk) 512)))
           (replace disk (octets "EFI PART") :start1 512)
           (setf (le disk (+ 512 72) 8) 5
                 (le disk (+ 512 80) 4) 16
                 (le disk (+ 512 84) 4) 128)
           ;; The entries are where the header says, which need not be the sector after it. The first
           ;; two places are empty; a kind of partition is 16 bytes of anything but zeroes.
           (loop for (first . bytes) in volumes
                 for entry from (+ (* 5 512) (* 2 128)) by 128
                 do (replace disk '(#x28 #x73 #x2a #xc1 #x1f #xf8 #xd2 #x11 #xba #x4b #x00 #xa0 #xc9 #x3e #xc9 #x3b)
                             :start1 entry)
                    (setf (le disk (+ entry 32) 8) first
                          (le disk (+ entry 40) 8) (+ first (floor (length bytes) 512) -1)))))
        (loop for (first . bytes) in volumes
              do (replace disk bytes :start1 (* 512 first)))
        disk)))

(defvar *long-text*   ; some 20 KiB of lines that differ
  (with-output-to-string (text)
    (dotimes (i 500)
      (format text "(defvar *line-~D* \"~A\") ; λ~%" i (make-string (mod (* 7 i) 40) :initial-element #\x)))))

(defvar *binary* (coerce (loop for i below 3000 collect (mod (* 37 i) 256)) '(vector (unsigned-byte 8))))

(defvar *long-name* "a name that is long, of more than thirteen and of more than twenty-six characters.text")

(defvar *tree*
  `(("CLARA TESTS" :label)
    ("EFI" (("BOOT" (("BOOTX64.EFI" ,*binary*)))))
    ("clara" (("boot.lisp" ,*long-text*)
              ("self-test.lisp" "(car 'not-a-list)")
              ("gone.lisp" :deleted)
              (,*long-name* "long")
              ("thirteen chrs" "13")
              ("twenty-six characters, yes" "26")
              ("café λ 🙂.txt" "names from further away")
              ("readme.txt" "small letters, by two bits" :small t)
              ("UPPER.txt" "capitals and small letters" :small t)
              ("EMPTY" "")
              ("orphan.lisp" "not by that name" :broken t)
              ("one-cluster" ,(make-string 512 :initial-element #\c))
              ("two-clusters" ,(make-string 1024 :initial-element #\d))
              ,@(loop for i below 40 collect (list (format nil "file number ~D.dat" i) (format nil "~D" i)))
              ("deep" (("deeper" (("deepest.txt" "at the bottom")))))
              ("a long name without its first part.txt" "in parts" :partial t)))
    ("notes.txt" "at the root")))

;; What that directory holds, in the order of the names: the file that was
;; deleted is gone, and the two whose long names are not their own, or not
;; whole, go by their short ones.
(defvar *names-in-clara*
  (substitute "deep/" "deep"
              (sort (append (list *long-name* "boot.lisp" "self-test.lisp" "thirteen chrs" "twenty-six characters, yes"
                                  "café λ 🙂.txt" "readme.txt" "UPPER.txt" "EMPTY" "ORPHAN~8.LIS" "one-cluster"
                                  "two-clusters" "deep" "ALONG~51.TXT")
                            (loop for i below 40 collect (format nil "file number ~D.dat" i)))
                    #'string-lessp)
              :test #'string=))

(defvar *disk* nil) ; the device behind the disk of START-FILES

;; A machine with one disk, and the file system started on it: what START
;; said.
(defun start-files (bytes &rest options)
  (setq *disk* (car (apply #'new-disks (list (list* 3 bytes options)))))
  (said-by #'clara.disk:start)
  (said-by #'clara.fat:start))

(defun text-of-file (name)
  (handler-case (clara.fat:file-text name)
    (error (condition) (list :error (princ-to-string condition)))))

;; The same tree on volumes of every kind, on disks of every kind, with
;; clusters of several sizes and files that lie in one piece, in pieces and
;; back to front.
(dolist (how '((12 :none 0 "1 MiB") (12 :old 63 "750 KiB" :clusters 1500 :stride 3 :from 330 :end #xffffff8)
               (12 :new 40 "3 MiB" :cluster-sectors 4 :clusters 1600 :backwards t)
               (16 :none 0 "2 MiB" :stride 2 :backwards t) (16 :old 2048 "9 MiB" :cluster-sectors 4 :from 2040)
               (16 :new 34 "2 MiB" :from 2000 :stride 5 :end #xffffff8)
               (16 :none 0 "32 MiB" :cluster-sectors 16 :clusters 4200 :stride 2)
               (32 :none 0 "32 MiB" :from 65500) (32 :new 2048 "32 MiB" :stride 4 :backwards t :end #xffffff8 :root 9 :from 12)))
  (destructuring-bind (kind table first size &rest options) how
    (let* ((fat (apply #'make-fat-volume kind *tree* options))
           (said (start-files (make-disk table (cons first (fat-bytes fat)))))
           (pages (clara.host:allocated-pages)))
      (check (format nil "files: a FAT~D volume of ~A on the disk 00:03.0, from its sector ~D on~%" kind size first) said)
      (check (list 1 kind first) (list (length (clara.fat:volumes)) (clara.fat:volume-kind clara.fat:*volume*)
                                       (clara.fat:volume-first clara.fat:*volume*)))
      (check '("clara/" "EFI/" "notes.txt") (clara.fat:names "/"))
      (check '("clara/" "EFI/" "notes.txt") (clara.fat:names ""))
      (check *names-in-clara* (clara.fat:names "/clara"))
      (check '("BOOT/") (clara.fat:names "/EFI/"))
      (check '("deepest.txt") (clara.fat:names "clara/deep//deeper"))
      (check '(nil nil nil) (list (clara.fat:names "/nothing") (clara.fat:names "/notes.txt")
                                  (clara.fat:names "/clara/boot.lisp/x")))
      (check "at the root" (text-of-file "/notes.txt"))
      (check t (string= *long-text* (text-of-file "/clara/boot.lisp")))
      (check t (string= *long-text* (text-of-file "CLARA/BOOT.LISP")))       ; in letters of either case
      (check "at the bottom" (text-of-file "/clara/deep/deeper/deepest.txt"))
      (check '("long" "13" "26" "names from further away" "small letters, by two bits" "capitals and small letters" "")
             (mapcar (lambda (name) (text-of-file (concatenate 'string "/clara/" name)))
                     (list *long-name* "thirteen chrs" "twenty-six characters, yes" "café λ 🙂.txt" "readme.txt"
                           "upper.TXT" "empty")))
      (check (list (make-string 512 :initial-element #\c) (make-string 1024 :initial-element #\d) "39")
             (mapcar #'text-of-file '("/clara/one-cluster" "/clara/two-clusters" "/clara/file number 39.dat")))
      ;; A file is found by its short name as well, and one whose long name is not its own by that alone.
      (check '("(car 'not-a-list)" "not by that name" "long" "in parts")
             (mapcar #'text-of-file '("/clara/SELFTE~2.LIS" "/clara/orphan~8.lis" "/clara/ANAMET~4.TEX"
                                      "/clara/along~51.txt")))
      (check '(:error "there is no file /clara/orphan.lisp") (text-of-file "/clara/orphan.lisp"))
      (check '(:error "there is no file /clara/gone.lisp") (text-of-file "/clara/gone.lisp"))
      (check '(:error "there is no file /clara/CLARA TESTS") (text-of-file "/clara/CLARA TESTS"))
      (check '(:error "there is no file /notes.txt/more") (text-of-file "/notes.txt/more"))
      (check '(:error "/clara is a directory, and not a file") (text-of-file "/clara"))
      (check '(:error "/ is a directory, and not a file") (text-of-file "/"))
      (check '(:error "the file /EFI/BOOT/BOOTX64.EFI is not text: what it holds is not UTF-8")
             (text-of-file "/EFI/BOOT/BOOTX64.EFI"))
      (check-condition error (clara.fat:file-text 'notes.txt))
      (check-condition error (clara.fat:entries "/notes.txt"))
      (check-condition error (clara.fat:entries "/nothing"))
      ;; What a file holds, as bytes in memory that the caller gives back.
      (multiple-value-bind (memory size frames) (clara.fat:read-file "/efi/boot/bootx64.efi")
        (check '(3000 1 t) (list size frames (equalp (memory-bytes memory 3000) *binary*)))
        (clara.unsafe:free-memory memory frames))
      (let ((entries (clara.fat:entries "/clara")))
        (check *names-in-clara* (mapcar (lambda (entry)
                                          (if (clara.fat:entry-directory-p entry)
                                              (concatenate 'string (clara.fat:entry-name entry) "/")
                                              (clara.fat:entry-name entry)))
                                        entries))
        (check (list "BOOT~1.LIS" (length (octets *long-text*)) nil)
               (let ((entry (find "boot.lisp" entries :key #'clara.fat:entry-name :test #'string=)))
                 (list (clara.fat:entry-short entry) (clara.fat:entry-size entry) (clara.fat:entry-directory-p entry)))))
      ;; The language is told where its files are, and nothing that was taken is kept.
      (check '("at the root" ("BOOT/")) (list (funcall (first (clara.host:provided-files)) "/notes.txt")
                                                (funcall (second (clara.host:provided-files)) "/EFI")))
      (check pages (clara.host:allocated-pages)))))

;; A volume whose table and directories are not what they should be: each
;; is an error that says so, and none takes anything else with it.
(let* ((tree `(("ring" (("inside.txt" "never seen")))
               ("short.txt" ,(make-string 600 :initial-element #\s) :size 5000)
               ("nowhere.txt" "x" :cluster 1)
               ("beyond.txt" "x" :cluster 9999)
               ("wild.txt" ,(make-string 2000 :initial-element #\w))
               ("fine.txt" "all is well here")
               ("trap.txt" ,(short-record (octets "MORE       ") #x20 0 0)))) ; a file that holds what a directory would
       (fat (make-fat-volume 16 tree)))
  (setf (fat-entry fat 2) 2)       ; the directory RING, which is the first to get a cluster, leads back into itself
  (setf (fat-entry fat 6) 1)       ; WILD.TXT has the clusters 6 to 9, and the table goes astray after the first
  (start-files (fat-bytes fat))
  (let ((pages (clara.host:allocated-pages)))
    (check '("beyond.txt" "fine.txt" "nowhere.txt" "ring/" "short.txt" "trap.txt" "wild.txt") (clara.fat:names "/"))
    (check '(:error "there is no file /trap.txt/more") (text-of-file "/trap.txt/more"))
    (check nil (clara.fat:names "/trap.txt"))
    (check-condition error (clara.fat:names "/ring"))
    (check-condition error (clara.fat:file-text "/ring/inside.txt"))
    (check '(:error "the file /short.txt is 5000 bytes by its directory, and the table of the volume has fewer for it")
           (text-of-file "/short.txt"))
    (check '(:error "a file begins in the cluster 1, and the volume has no such cluster") (text-of-file "/nowhere.txt"))
    (check '(:error "a file begins in the cluster 9999, and the volume has no such cluster") (text-of-file "/beyond.txt"))
    (check '(:error "the table of the volume has 1 after the cluster 6, and there is no such cluster")
           (text-of-file "/wild.txt"))
    (check "all is well here" (text-of-file "/fine.txt"))
    (check pages (clara.host:allocated-pages))))

;; How many clusters a volume has is what makes it the kind it is: the
;; most that each kind can have, and one more.
(dolist (how '((12 4084) (16 4085) (16 65524) (32 65525)))
  (let ((text (make-string 1500 :initial-element #\k)))
    (start-files (fat-bytes (make-fat-volume (first how) `(("kind.txt" ,text)) :clusters (second how) :stride 2)))
    (check (list (first how) t) (list (clara.fat:volume-kind clara.fat:*volume*) (equal text (text-of-file "/kind.txt"))))))

;; An entry of 12 bits that lies across the end of what is held of the
;; table: the clusters 2729 to 2731, after a file at the table's beginning.
(let ((near (make-string 1000 :initial-element #\n)) (far (make-string 1500 :initial-element #\f)))
  (start-files (fat-bytes (make-fat-volume 12 `(("near.txt" ,near) ("far.txt" ,far :from 2729)))))
  (check (list near far) (list (text-of-file "/near.txt") (text-of-file "/far.txt"))))

;; A file of more than a mebibyte that lies in one piece is read a mebibyte
;; at a time.
(let ((big (make-array 1300000 :element-type '(unsigned-byte 8))))
  (dotimes (i (length big))
    (setf (aref big i) (mod (+ i (floor i 1000)) 251)))
  (start-files (fat-bytes (make-fat-volume 16 `(("big.bin" ,big)) :cluster-sectors 4)))
  (multiple-value-bind (memory size frames) (clara.fat:read-file "/big.bin")
    (check '(1300000 318 t) (list size frames (equalp (memory-bytes memory size) big)))
    (check '(492 2048) (mapcar #'third (subseq (vdev-requests *disk*) 0 2)))
    (clara.unsafe:free-memory memory frames)))

;; A volume of the kind 32 that keeps one of its tables only, and not the
;; first, which holds nothing of use.
(let* ((text (make-string 1500 :initial-element #\m))
       (fat (make-fat-volume 32 `(("mirror.txt" ,text)) :stride 2))
       (bytes (fat-bytes fat)))
  (fill bytes #xff :start (* 512 32) :end (* 512 (+ 32 (fat-table-sectors fat))))
  (setf (le bytes 40 2) #x81)
  (start-files bytes)
  (check text (text-of-file "/mirror.txt")))

;; Two threads at one volume take turns at its table: on a disk that takes
;; its time, with files so far apart that what is held of the table for the
;; one is of no use to the other. Threads under SBCL are too quick for one
;; to catch the other with the table in its hands, so the disk looks as
;; well: whoever asks it for something has the volume's lock.
(let ((near (make-string 1400 :initial-element #\n)) (far (make-string 1500 :initial-element #\f)))
  (start-files (fat-bytes (make-fat-volume 12 `(("near.txt" ,near) ("far.txt" ,far :from 2800)) :stride 2))
               :delay 0.002)
  (setf (vdev-watch *disk*)
        (lambda ()
          (unless (sb-thread:mutex-owner (clara.fat::volume-lock clara.fat:*volume*))
            (failed "the file system asked its disk for something without the lock of the volume"))))
  (check '("far.txt" "near.txt") (clara.fat:names "/"))
  (check 2 (length (clara.fat:entries "/")))
  (check '(12 12)
         (mapcar #'clara:join-thread
                 (mapcar (lambda (name text)
                           (clara:make-thread (lambda ()
                                                (let ((right 0))
                                                  (dotimes (i 12 right)
                                                    (when (equal text (text-of-file name))
                                                      (incf right)))))))
                         (list "/near.txt" "/far.txt")
                         (list near far)))))
(start-files (fat-bytes (make-fat-volume 12 *tree* :stride 3)))
(check '(40 40)
       (mapcar #'clara:join-thread
               (mapcar (lambda (name text)
                         (clara:make-thread (lambda ()
                                              (let ((right 0))
                                                (dotimes (i 40 right)
                                                  (when (equal text (text-of-file name))
                                                    (incf right)))))))
                       (list "/clara/boot.lisp" "/clara/two-clusters")
                       (list *long-text* (make-string 1024 :initial-element #\d)))))

;; Disks without a volume, and with more than one.
(flet ((spoilt (offset value)
         (let ((bytes (copy-seq (fat-bytes (make-fat-volume 12 '(("a.txt" "a")))))))
           (setf (aref bytes offset) value)
           bytes)))
  (dolist (bytes (list (spoilt 510 0)        ; not the two bytes that end a first sector
                       (spoilt 12 4)         ; sectors of 1024 bytes
                       (spoilt 13 3)         ; clusters of three sectors
                       (spoilt 16 0)         ; no table
                       (spoilt 21 #x10)      ; on nothing that a volume can be on
                       (spoilt 20 #xff)      ; more sectors than the disk has
                       (pattern 64)))        ; and nothing of the kind
    (check (format nil "files: the disk 00:03.0 has no volume that is known here~%~
                        files: no volume, so LOAD finds what was read as the machine started and nothing else~%")
           (start-files bytes))
    (check '(nil nil nil) (list (clara.fat:volumes) clara.fat:*volume* (clara.host:provided-files)))
    (check nil (clara.fat:names "/"))
    (check-condition error (clara.fat:file-text "/a.txt"))
    (check-condition error (clara.fat:entries "/"))))
(let* ((first (fat-bytes (make-fat-volume 12 '(("first.txt" "on the first")))))
       (second (fat-bytes (make-fat-volume 16 '(("second.txt" "on the second")))))
       (said (start-files (make-disk :old (cons 63 first) (cons 8000 second)))))
  (check (format nil "files: a FAT12 volume of 1 MiB on the disk 00:03.0, from its sector 63 on~%~
                      files: a FAT16 volume of 2 MiB on the disk 00:03.0, from its sector 8000 on~%~
                      files: names are looked up on the first of these volumes~%")
         said)
  (check '("first.txt") (clara.fat:names "/"))
  (let ((clara.fat:*volume* (second (clara.fat:volumes))))
    (check "on the second" (text-of-file "/second.txt"))))
;; A table of the newer kind that is not one, a partition that begins past
;; the end of the disk, and a disk that cannot be read.
(let ((disk (make-disk :new (cons 40 (fat-bytes (make-fat-volume 12 '(("a.txt" "a"))))))))
  (setf (aref disk 512) 0)
  (check t (and (search "files: the disk 00:03.0 has no volume that is known here" (start-files disk)) t)))
(let ((disk (make-disk :old (cons 63 (fat-bytes (make-fat-volume 12 '(("a.txt" "a"))))))))
  (setf (le disk (+ 446 16 8) 4) 900000)
  (check t (and (search "files: the disk 00:03.0 has no volume that is known here" (start-files disk)) t)))
(check t (and (search "files: the disk 00:03.0 could not be looked at: the disk 00:03.0 could not read its sectors 0 to 0"
                      (start-files (fat-bytes (make-fat-volume 12 '(("a.txt" "a")))) :answer 1))
              t))
(new-bus)
(said-by #'clara.disk:start)
(check (format nil "files: no volume, so LOAD finds what was read as the machine started and nothing else~%")
       (said-by #'clara.fat:start))

;;; Writing. What the file system has written is looked at here without the
;;; file system, the way a program that mends volumes looks at one: every
;;; directory from the root down, every file by the clusters that the table
;;; gives it. INSPECT-VOLUME gives the files it found, each as its name
;;; with its directories and its bytes, and everything that is out of
;;; order: a cluster in two files or in none, a file that is not as long as
;;; its entry says, a long name that is not whole, two entries of one name,
;;; copies of the table that differ, a count of free clusters that is wrong.

(defun inspect-volume (bytes)
  (let* ((cluster-sectors (aref bytes 13))
         (reserved (le bytes 14 2))
         (tables (aref bytes 16))
         (sectors (if (zerop (le bytes 19 2)) (le bytes 32 4) (le bytes 19 2)))
         (table-sectors (if (zerop (le bytes 22 2)) (le bytes 36 4) (le bytes 22 2)))
         (root-sectors (ceiling (* 32 (le bytes 17 2)) 512))
         (data (+ reserved (* tables table-sectors) root-sectors))
         (clusters (floor (- sectors data) cluster-sectors))
         (kind (cond ((< clusters 4085) 12) ((< clusters 65525) 16) (t 32)))
         (flags (if (= kind 32) (le bytes 40 2) 0))
         (active (if (logbitp 7 flags) (logand flags 15) 0))
         (each (* 512 cluster-sectors))
         (owner (make-array (+ clusters 2) :initial-element nil))
         (files nil)
         (problems nil))
    (labels ((problem (control &rest arguments)
               (push (apply #'format nil control arguments) problems))
             (entry (cluster)
               (let ((base (* 512 (+ reserved (* active table-sectors)))))
                 (ecase kind
                   (12 (let ((pair (le bytes (+ base cluster (floor cluster 2)) 2)))
                         (if (oddp cluster) (ash pair -4) (logand pair #xfff))))
                   (16 (le bytes (+ base (* 2 cluster)) 2))
                   (32 (logand (le bytes (+ base (* 4 cluster)) 4) #xfffffff)))))
             ;; The clusters of whatever begins in FIRST, each of them its own from here on.
             (clusters-of (first name)
               (let ((found nil) (cluster first))
                 (loop
                   (unless (< 1 cluster (+ clusters 2))
                     (problem "~A leads to the cluster ~D, and there is no such cluster" name cluster)
                     (return))
                   (when (aref owner cluster)
                     (problem "the cluster ~D is in ~A and in ~A" cluster (aref owner cluster) name)
                     (return))
                   (setf (aref owner cluster) name)
                   (push cluster found)
                   (let ((next (entry cluster)))
                     (cond ((>= next (ecase kind (12 #xff8) (16 #xfff8) (32 #xffffff8)))
                            (return))
                           ((zerop next)
                            (problem "~A goes on in the cluster ~D, which the table has as free" name cluster)
                            (return))
                           (t (setq cluster next)))))
                 (nreverse found)))
             (bytes-of (found)
               (let ((all (make-array (* each (length found)) :element-type '(unsigned-byte 8))))
                 (loop for cluster in found
                       for at from 0 by each
                       do (replace all bytes :start1 at :start2 (* 512 (+ data (* (- cluster 2) cluster-sectors)))
                                             :end2 (* 512 (+ data (* (- cluster 1) cluster-sectors)))))
                 all))
             (short-of (record)
               (flet ((part (start length lower)
                        (let ((text (string-right-trim " " (map 'string #'code-char (subseq record start (+ start length))))))
                          (if lower (string-downcase text) text))))
                 (let ((name (part 0 8 (logbitp 3 (aref record 12)))) (extension (part 8 3 (logbitp 4 (aref record 12)))))
                   (if (string= extension "") name (format nil "~A.~A" name extension)))))
             ;; The name that the entries before a short one spell out, when they are in order.
             (long-of (parts record path)
               (let ((units nil) (count (length parts)) (sum (short-checksum (subseq record 0 11))))
                 (loop for part in parts
                       for number downfrom count
                       do (unless (and (= (logand (aref part 0) #x3f) number)
                                       (eq (logbitp 6 (aref part 0)) (= number count))
                                       (= (aref part 13) sum))
                            (problem "the long name before ~A in ~A is not in order" (short-of record) path)
                            (return-from long-of nil))
                          (setq units (append (loop for place in '(1 3 5 7 9 14 16 18 20 22 24 28 30)
                                                    collect (le part place 2))
                                              units)))
                 (let* ((end (or (position 0 units) (length units)))
                        (rest (subseq units (min (length units) (1+ end)))))
                   (unless (and (every (lambda (unit) (= unit #xffff)) rest) (> (+ end 13) (length units)))
                     (problem "the long name before ~A in ~A does not end as one does" (short-of record) path))
                   (sb-ext:octets-to-string
                    (coerce (loop for unit in (subseq units 0 end) collect (ldb (byte 8 0) unit) collect (ldb (byte 8 8) unit))
                            '(vector (unsigned-byte 8)))
                    :external-format :utf-16le))))
             (walk (records path)
               (let ((parts nil) (ended nil) (names nil) (shorts nil))
                 (loop for at from 0 below (length records) by 32
                       for record = (subseq records at (+ at 32))
                       for first = (aref record 0)
                       for what = (aref record 11)
                       do (cond (ended
                                 (unless (zerop first)
                                   (problem "~A has an entry after the one that ends it" path)
                                   (return)))
                                ((zerop first)
                                 (when parts
                                   (problem "~A ends in the middle of a long name" path))
                                 (setq ended t))
                                ((= first #xe5)
                                 (when parts
                                   (problem "a long name in ~A belongs to an entry that was deleted" path))
                                 (setq parts nil))
                                ((= (logand what #x3f) #x0f)
                                 (push record parts))
                                ((logbitp 3 what)
                                 (setq parts nil))
                                ((member (short-of record) '("." "..") :test #'string=))
                                (t
                                 (let* ((short (short-of record))
                                        (name (or (and parts (long-of (reverse parts) record path)) short))
                                        (whole (format nil "~A/~A" path name))
                                        (cluster (+ (le record 26 2) (if (= kind 32) (ash (le record 20 2) 16) 0)))
                                        (size (le record 28 4)))
                                   (setq parts nil)
                                   (when (or (member name names :test #'string-equal)
                                             (member (subseq record 0 11) shorts :test #'equalp))
                                     (problem "~A has two entries of the name ~A, or of its short name" path name))
                                   (push name names)
                                   (push (subseq record 0 11) shorts)
                                   (cond ((logbitp 4 what)
                                          (walk (bytes-of (clusters-of cluster whole)) whole))
                                         ((zerop size)
                                          (unless (zerop cluster)
                                            (problem "~A is empty, and begins in the cluster ~D" whole cluster))
                                          (push (cons whole (octets "")) files))
                                         (t
                                          (let ((found (clusters-of cluster whole)))
                                            (unless (= (length found) (ceiling size each))
                                              (problem "~A is ~D bytes, and has ~D clusters of ~D" whole size (length found) each))
                                            (push (cons whole (subseq (bytes-of found) 0 (min size (* each (length found)))))
                                                  files)))))))))))
      (if (= kind 32)
          (walk (bytes-of (clusters-of (le bytes 44 4) "/")) "")
          (walk (subseq bytes (* 512 (- data root-sectors)) (* 512 data)) ""))
      (let ((lost (loop for cluster from 2 below (+ clusters 2)
                        count (and (not (aref owner cluster)) (not (zerop (entry cluster)))))))
        (unless (zerop lost)
          (problem "~D clusters are in no file, and not free" lost)))
      (unless (logbitp 7 flags)
        (loop for copy from 1 below tables
              do (unless (equalp (subseq bytes (* 512 reserved) (* 512 (+ reserved table-sectors)))
                                 (subseq bytes (* 512 (+ reserved (* copy table-sectors)))
                                         (* 512 (+ reserved (* (1+ copy) table-sectors)))))
                   (problem "the copies of the table differ"))))
      (when (and (= kind 32) (< 0 (le bytes 48 2) reserved))
        (let ((at (* 512 (le bytes 48 2)))
              (free (loop for cluster from 2 below (+ clusters 2) count (zerop (entry cluster)))))
          (when (and (= (le bytes at 4) #x41615252) (/= (le bytes (+ at 488) 4) #xffffffff)
                     (/= (le bytes (+ at 488) 4) free))
            (problem "~D clusters are free, and the volume says ~D" free (le bytes (+ at 488) 4))))))
    (values (sort files #'string< :key #'car) (nreverse problems))))

;; The files of a tree as INSPECT-VOLUME gives them.
(defun tree-files (tree &optional (path ""))
  (loop for (name contents) in tree
        for whole = (format nil "~A/~A" path name)
        append (cond ((member contents '(:label :deleted)) nil)
                     ((listp contents) (tree-files contents whole))
                     (t (list (cons whole (octets contents)))))))

;; A file of that text, by way of page frames, as lisp/boot.lisp makes one.
(defun put-text (name text)
  (let* ((bytes (clara.unsafe:string-bytes text))
         (pages (max 1 (ceiling bytes 4096)))
         (memory (clara.unsafe:allocate-memory pages)))
    (unwind-protect
         (progn
           (clara.unsafe:string-memory text memory)
           (clara.fat:write-file name memory bytes))
      (clara.unsafe:free-memory memory pages))))

(defun short-of-file (directory name)
  (let ((entry (find name (clara.fat:entries directory) :key #'clara.fat:entry-name :test #'string=)))
    (and entry (clara.fat:entry-short entry))))

(defvar *clean-tree*
  `(("EFI" (("BOOT" (("BOOTX64.EFI" ,*binary*)))))
    ("clara" (("boot.lisp" ,*long-text*)
              ("self-test.lisp" "(car 'not-a-list)")
              ("gone.lisp" :deleted)
              ("gone as well, with a long name.lisp" :deleted)
              ("readme.txt" "small letters, by two bits" :small t)
              ("EMPTY" "")
              ("deep" (("deeper" (("deepest.txt" "at the bottom")))))))
    ("notes.txt" "at the root")))

(defvar *new-text*    ; some 33 KiB, and nothing like *LONG-TEXT*
  (with-output-to-string (text)
    (dotimes (i 900)
      (format text "~D: ~A λ🙂~%" i (make-string (mod (* 11 i) 53) :initial-element (code-char (+ 97 (mod i 26))))))))

;; Volumes of every kind, on disks of every kind, with files that were
;; there in one piece, in pieces and back to front: files are added in
;; every directory, under names of every sort, put in the place of others,
;; made longer, shorter and empty, and taken away. After each round the
;; volume has to be in order and hold exactly what it should, to whoever
;; looks at its bytes and to the file system alike, also when that has
;; started afresh.
(dolist (how '((12 :none 0) (12 :old 63 :clusters 1500 :stride 3 :from 330 :end #xffffff8)
               (12 :new 40 :cluster-sectors 4 :clusters 1600 :backwards t)
               (16 :none 0 :stride 2 :backwards t) (16 :old 2048 :cluster-sectors 4 :from 2040)
               (16 :none 0 :cluster-sectors 16 :clusters 4200 :stride 2)
               (32 :none 0 :from 65500 :information t)
               (32 :new 2048 :stride 4 :backwards t :end #xffffff8 :root 9 :from 12 :information t)))
  (destructuring-bind (kind table first &rest options) how
    (let* ((fat (apply #'make-fat-volume kind *clean-tree* options))
           (disk (make-disk table (cons first (fat-bytes fat))))
           (expected (tree-files *clean-tree*)))
      (flet ((have (name contents)
               (setq expected (remove name expected :key #'car :test #'string-equal))
               (when contents
                 (push (cons name (octets contents)) expected)))
             (in-order (what)
               (multiple-value-bind (files problems) (inspect-volume (subseq disk (* 512 first)))
                 (incf *checks*)
                 (when problems
                   (failed "a FAT~D volume ~A is out of order: ~{~A~^; ~}" kind what problems))
                 (incf *checks*)
                 (unless (equalp files (sort (copy-list expected) #'string< :key #'car))
                   (failed "a FAT~D volume ~A does not hold what it should: it has ~S"
                           kind what (mapcar (lambda (file) (list (car file) (length (cdr file)))) files))))))
        (start-files disk)
        (let ((pages (clara.host:allocated-pages)))
          (in-order "before anything is written")
          ;; New files: a name that is its own short name, one that is in small letters, long ones.
          (check "/NEW.TXT" (put-text "/NEW.TXT" "a short name, as it stands"))
          (have "/NEW.TXT" "a short name, as it stands")
          (put-text "/clara/small.txt" "small letters")
          (have "/clara/small.txt" "small letters")
          (put-text "clara/thirteen.chrs" "13")
          (have "/clara/thirteen.chrs" "13")
          (put-text "/clara/twenty-six characters, yes" "26")
          (have "/clara/twenty-six characters, yes" "26")
          (put-text "/clara/a longer name, with λ and 🙂 in it.text" *new-text*)
          (have "/clara/a longer name, with λ and 🙂 in it.text" *new-text*)
          (put-text "/clara/deep/deeper/.hidden" "a dot first")
          (have "/clara/deep/deeper/.hidden" "a dot first")
          (put-text "/clara/nothing.txt" "")
          (have "/clara/nothing.txt" "")
          (in-order "with new files")
          (check '("NEW.TXT" "SMALL.TXT" "THIRTE~1.CHR" "TWENTY~1" "ALONGE~1.TEX" "HIDDEN~1" "NOTHING.TXT")
                 (list (short-of-file "/" "NEW.TXT") (short-of-file "/clara" "small.txt")
                       (short-of-file "/clara" "thirteen.chrs") (short-of-file "/clara" "twenty-six characters, yes")
                       (short-of-file "/clara" "a longer name, with λ and 🙂 in it.text")
                       (short-of-file "/clara/deep/deeper" ".hidden") (short-of-file "/clara" "nothing.txt")))
          ;; Short names that are taken: the next number.
          (put-text "/clara/boot.lisp2" "two")
          (put-text "/clara/boot.lisp3" "three")
          (have "/clara/boot.lisp2" "two")
          (have "/clara/boot.lisp3" "three")
          (check '("BOOT~1.LIS" "BOOT~2.LIS" "BOOT~3.LIS")
                 (mapcar (lambda (name) (short-of-file "/clara" name)) '("boot.lisp" "boot.lisp2" "boot.lisp3")))
          ;; A file in the place of another: longer, shorter, empty, and something again.
          (put-text "/CLARA/BOOT.LISP" *new-text*)
          (have "/clara/boot.lisp" *new-text*)
          (in-order "with a longer file in the place of another")
          (put-text "/clara/boot.lisp" "short now")
          (have "/clara/boot.lisp" "short now")
          (put-text "/clara/boot~3.lis" "by its short name")
          (have "/clara/boot.lisp3" "by its short name")
          (in-order "with a shorter file in the place of another")
          (put-text "/clara/boot.lisp" "")
          (have "/clara/boot.lisp" "")
          (put-text "/clara/EMPTY" *long-text*)
          (have "/clara/EMPTY" *long-text*)
          (put-text "/notes.txt" "at the root, again")
          (have "/notes.txt" "at the root, again")
          (in-order "with an empty file in the place of another")
          ;; More files than a directory has room for: it grows.
          (dotimes (i 45)
            (put-text (format nil "/clara/deep/file number ~D.data" i) (format nil "~D" i))
            (have (format nil "/clara/deep/file number ~D.data" i) (format nil "~D" i)))
          (in-order "with a directory that has grown")
          ;; Files are taken away, and others take their places.
          (dolist (name '("/clara/deep/file number 7.data" "/clara/deep/FILE NUMBER 8.DATA" "/clara/deep/filenu~1.dat"
                          "/clara/a longer name, with λ and 🙂 in it.text" "/NEW.TXT" "/clara/nothing.txt"
                          "/clara/self-test.lisp"))
            (check name (clara.fat:remove-file name)))
          (dolist (name '("/clara/deep/file number 7.data" "/clara/deep/file number 8.data" "/clara/deep/file number 0.data"
                          "/clara/a longer name, with λ and 🙂 in it.text" "/NEW.TXT" "/clara/nothing.txt"
                          "/clara/self-test.lisp"))
            (have name nil))
          (in-order "with files taken away")
          (put-text "/clara/deep/in the place of one that went.data" *long-text*)
          (have "/clara/deep/in the place of one that went.data" *long-text*)
          (put-text "/clara/x" "x")
          (have "/clara/x" "x")
          (in-order "with files where others were")
          ;; The file system reads what it wrote, and so does one that has only just started.
          (dotimes (again 2)
            (check t (every (lambda (file)
                              (let ((text (ignore-errors (sb-ext:octets-to-string (cdr file) :external-format :utf-8))))
                                (or (string= (car file) "/EFI/BOOT/BOOTX64.EFI") (equal text (text-of-file (car file))))))
                            expected))
            (check (sort (loop for (name) in expected
                               when (and (> (length name) 12) (string= "/clara/deep/" name :end2 12)
                                         (not (find #\/ name :start 12)))
                                 collect (subseq name 12))
                         #'string-lessp)
                   (remove "deeper/" (clara.fat:names "/clara/deep") :test #'string=))
            (check pages (clara.host:allocated-pages))
            (start-files disk))
          (in-order "after it was read"))))))

;; What cannot be written, and what is left when it could not be.
(let* ((fat (make-fat-volume 12 *clean-tree* :clusters 400))
       (disk (fat-bytes fat))
       (expected (tree-files *clean-tree*)))
  (start-files disk)
  (let ((pages (clara.host:allocated-pages)))
    (flet ((untouched (what)
             (multiple-value-bind (files problems) (inspect-volume disk)
               (incf *checks*)
               (unless (and (null problems) (equalp files (sort (copy-list expected) #'string< :key #'car)))
                 (failed "a volume is not what it was ~A: ~{~A~^; ~}" what problems)))))
      (dolist (name (list "" "/" "/clara/" "/clara/bad:name" "/clara/ends in a dot." "/clara/ends in a space "
                          "/clara/.." "/clara/a*b" (format nil "/clara/a~Cb" (code-char 7))
                          (concatenate 'string "/clara/" (make-string 256 :initial-element #\n))
                          "/nowhere/file.txt" "/notes.txt/file.txt" "/clara" "/clara/deep"))
        (check-condition error (put-text name "never written")))
      (check-condition error (clara.fat:write-file 'notes.txt 0 0))
      (check-condition error (clara.fat:write-file "/clara/too long.bin" 0 4294967296))
      (check-condition error (clara.fat:write-file "/clara/no length.bin" 0 -1))
      (dolist (name '("/nothing.txt" "/clara" "/" "" "/nowhere/file.txt"))
        (check-condition error (clara.fat:remove-file name)))
      (untouched "after names that are none")
      ;; More than the volume has room for: 400 clusters of 512 bytes, some of them taken.
      (check '(:error "the volume is full: 391 clusters are wanted, and 337 are free")
             (handler-case (put-text "/big.txt" (make-string 200000 :initial-element #\b))
               (error (condition) (list :error (princ-to-string condition)))))
      (untouched "after a file that it had no room for")
      ;; The directory of the root on this kind is 224 entries and no more: the 5 that are in use,
      ;; and 54 files that take 4 each, three of them for the name.
      (dotimes (i 54)
        (put-text (format nil "/a name of some length, ~D.txt" i) "x")
        (push (cons (format nil "/a name of some length, ~D.txt" i) (octets "x")) expected))
      (check '(:error "the directory of the root is full: it has 224 entries, and on a volume of this kind no more")
             (handler-case (put-text "/one too many for the root, yes.txt" "y")
               (error (condition) (list :error (princ-to-string condition)))))
      (untouched "after a file that its directory had no room for")
      (put-text "/FITS" "one entry is left")
      (push (cons "/FITS" (octets "one entry is left")) expected)
      (untouched "with a full directory")
      ;; The entries of a file that is taken away are there for the next one: four go, and four come.
      (clara.fat:remove-file "/a name of some length, 7.txt")
      (put-text "/a name of that length, 77.txt" "in its place")
      (setq expected (cons (cons "/a name of that length, 77.txt" (octets "in its place"))
                           (remove "/a name of some length, 7.txt" expected :key #'car :test #'string=)))
      (untouched "with a file where another was, in a directory that is full")
      ;; And the volume to its last cluster: a file that takes every one that is free, and no more.
      (let* ((free (count-if #'zerop (loop for cluster from 2 below 402
                                           collect (logand (ash (le disk (+ 512 cluster (floor cluster 2)) 2)
                                                                (if (oddp cluster) -4 0))
                                                           #xfff))))
             (all (make-string (* 512 free) :initial-element #\a)))
        (put-text "/clara/all of it.txt" all)
        (push (cons "/clara/all of it.txt" (octets all)) expected)
        (untouched "that is full to its last cluster")
        (check '(:error "the volume is full: 1 clusters are wanted, and 0 are free")
               (handler-case (put-text "/clara/one more.txt" "x")
                 (error (condition) (list :error (princ-to-string condition)))))
        (clara.fat:remove-file "/clara/all of it.txt")
        (pop expected)
        (untouched "after the file that filled it went"))
      ;; A disk that fails in the middle: what is held of the table is dropped, and reading goes on.
      (setf (vdev-answer *disk*) 1)
      (check-condition error (put-text "/clara/lost.txt" "never arrives"))
      (check-condition error (clara.fat:remove-file "/notes.txt"))
      (setf (vdev-answer *disk*) 0)
      (check "at the root" (text-of-file "/notes.txt"))
      (untouched "after a disk that failed")
      (check pages (clara.host:allocated-pages)))))
(let ((disk (fat-bytes (make-fat-volume 16 *clean-tree*))))
  (start-files disk :read-only t)
  (check '(:error "the disk 00:03.0 cannot be written")
         (handler-case (put-text "/clara/new.txt" "never written")
           (error (condition) (list :error (princ-to-string condition)))))
  (check "at the root" (text-of-file "/notes.txt"))
  (check nil (nth-value 1 (inspect-volume disk))))

;; An entry of 12 bits that lies across the end of a sector, and of what is
;; held of the table: files are written into the clusters around it, and
;; the file that was there before is still what it was.
(let* ((far (make-string 1500 :initial-element #\f))
       (disk (fat-bytes (make-fat-volume 12 `(("far.txt" ,far :from 2729))))))
  (start-files disk)
  (dolist (from '(2720 340 2730 1364 2046))
    (setf (clara.fat::volume-next clara.fat:*volume*) from)
    (put-text (format nil "/from ~D.txt" from) (make-string 5000 :initial-element (code-char (+ 97 (mod from 26))))))
  (multiple-value-bind (files problems) (inspect-volume disk)
    (check nil problems)
    (check '("/far.txt" "/from 1364.txt" "/from 2046.txt" "/from 2720.txt" "/from 2730.txt" "/from 340.txt")
           (mapcar #'car files))
    (check t (equalp (octets far) (cdr (first files))))))

;; A volume of the kind 32 that keeps one of its tables only, and not the
;; first: the first is left as it is.
(let* ((fat (make-fat-volume 32 `(("mirror.txt" "kept in one table")) :stride 2))
       (bytes (fat-bytes fat)))
  (fill bytes #xff :start (* 512 32) :end (* 512 (+ 32 (fat-table-sectors fat))))
  (setf (le bytes 40 2) #x81
        (le bytes 48 2) 3)       ; where the count of free clusters would be, and is not: the sector is empty
  (start-files bytes)
  (put-text "/second.txt" *long-text*)
  (clara.fat:remove-file "/mirror.txt")
  (check t (every (lambda (byte) (= byte #xff)) (subseq bytes (* 512 32) (* 512 (+ 32 (fat-table-sectors fat))))))
  (check t (every #'zerop (subseq bytes (* 512 3) (* 512 4))))
  ;; The cluster that MIRROR.TXT was in is free, and the four bits that mean nothing are what they were.
  (check #xa0000000 (le bytes (+ (* 512 (+ 32 (fat-table-sectors fat))) (* 4 3)) 4))
  (multiple-value-bind (files problems) (inspect-volume bytes)
    (check nil problems)
    (check t (equalp files (list (cons "/second.txt" (octets *long-text*)))))))

;; A directory whose bytes after its last entry are not all zeroes, as a
;; volume may have them that others have written to: the entry that ends
;; it is one that begins with a zero, and there still is one after a file
;; has been added. And a directory that grows into a cluster which a file
;; has left behind is given a cluster of zeroes.
(let* ((fat (make-fat-volume 16 `(("deep" (("first.txt" "1"))) ("one.txt" "1")) :from 100))
       (disk (fat-bytes fat))
       (root (* 512 (- (fat-data fat) (fat-root-sectors fat)))))
  (fill disk #x41 :start (+ root (* 32 5)) :end (+ root (* 32 9))) ; after the four entries in use, and one that ends them
  (start-files disk)
  (put-text "/two.txt" "2")                                         ; two entries, where the end was and after it
  (check '(0 #x41) (list (aref disk (+ root (* 32 6))) (aref disk (+ root (* 32 6) 1))))
  (check '("deep/" "one.txt" "two.txt") (clara.fat:names "/"))
  (setf (clara.fat::volume-next clara.fat:*volume*) 2)
  (put-text "/full of letters.txt" (make-string 40000 :initial-element #\a)) ; which as entries would be files
  (clara.fat:remove-file "/full of letters.txt")
  (setf (clara.fat::volume-next clara.fat:*volume*) 2)
  (dotimes (i 20)
    (put-text (format nil "/deep/a file in a directory that grows, ~D.txt" i) "x"))
  (check 21 (length (clara.fat:names "/deep")))
  (fill disk 0 :start (+ root (* 32 6)) :end (+ root (* 32 9)))    ; what this test put there itself
  (check nil (nth-value 1 (inspect-volume disk))))

;; A disk that stops in the middle of a file being written, at every
;; request it could stop at: from that request on nothing reaches it. What
;; it is left with may have clusters that belong to no file, and copies of
;; its table that differ, which is what a program that mends volumes puts
;; right; every file that was there is still what it was; and the file
;; that was being written is there whole or not at all, or what it was
;; before.
(dolist (how `(("/clara/a new file, with a long name.text" ,*new-text* nil)
               ("/clara/boot.lisp" ,*new-text* ,*long-text*)
               ("/clara/deep/deeper/deepest.txt" "" "at the bottom")))
  (destructuring-bind (name text before) how
    (let ((request 0) (stopped t))
      (loop while stopped
            do (incf request)
               (let* ((disk (fat-bytes (make-fat-volume 16 *clean-tree* :cluster-sectors 2 :stride 3)))
                      (count 0))
                 (start-files disk)
                 (setf (vdev-watch *disk*)
                       (lambda ()
                         (when (= (incf count) request)
                           (setf (vdev-answer *disk*) 1))))
                 (setq stopped (not (ignore-errors (put-text name text) t)))
                 (multiple-value-bind (files problems) (inspect-volume disk)
                   (let ((others (remove name files :key #'car :test #'string-equal))
                         (file (cdr (assoc name files :test #'string-equal))))
                     (incf *checks*)
                     (unless (and (every (lambda (problem)
                                           (or (search "are in no file, and not free" problem)
                                               (search "the copies of the table differ" problem)))
                                         problems)
                                  (equalp others (sort (remove name (tree-files *clean-tree*) :key #'car :test #'string-equal)
                                                       #'string< :key #'car))
                                  (cond (stopped (or (and (null file) (null before))
                                                     (and before (equalp file (octets before)))
                                                     (equalp file (octets text))))
                                        (t (and (null problems) (equalp file (octets text))))))
                       (failed "a disk that stopped at request ~D of writing ~A is left out of order: ~{~A~^; ~}"
                               request name (or problems (list "its files are not what they were"))))))))
      (check t (> request 8)))))

;; The table is changed with the lock of the volume in hand, like every
;; look at it; and two threads that write at the same time leave a volume
;; that is in order, with all that each of them wrote.
(let ((disk (fat-bytes (make-fat-volume 16 *clean-tree* :cluster-sectors 2))))
  (start-files disk :delay 0.0005)
  (setf (vdev-watch *disk*)
        (lambda ()
          (unless (sb-thread:mutex-owner (clara.fat::volume-lock clara.fat:*volume*))
            (failed "the file system asked its disk for something without the lock of the volume"))))
  (mapc #'clara:join-thread
        (mapcar (lambda (who)
                  (clara:make-thread (lambda ()
                                       (dotimes (i 6)
                                         (put-text (format nil "/clara/~A writes ~D.txt" who i)
                                                   (make-string (* 700 (1+ i)) :initial-element (char who 0))))
                                       (put-text (format nil "/clara/~A and gone.txt" who) "soon gone")
                                       (clara.fat:remove-file (format nil "/clara/~A and gone.txt" who)))))
                '("one" "two")))
  (multiple-value-bind (files problems) (inspect-volume disk)
    (check nil problems)
    (check 12 (count-if (lambda (file) (search " writes " (car file))) files))
    (check t (every (lambda (file)
                      (or (not (search " writes " (car file)))
                          (every (lambda (byte) (= byte (char-code (char (car file) 7)))) (cdr file))))
                    files))))

;; The image of the heap goes into a file like any other bytes, and what it
;; was in is given back.
(let ((disk (fat-bytes (make-fat-volume 16 *clean-tree*)))
      (image (coerce (loop for i below 70001 collect (mod (* 13 i) 256)) '(vector (unsigned-byte 8)))))
  (start-files disk)
  (clara.host:set-heap-image image)
  (let ((pages (clara.host:allocated-pages)))
    (check "/clara/clara.image" (clara:save-image))
    (check "/clara/world.image" (clara:save-image "/clara/world.image"))
    (check pages (clara.host:allocated-pages)))
  (multiple-value-bind (files problems) (inspect-volume disk)
    (check nil problems)
    (check '(t t) (list (equalp image (cdr (assoc "/clara/clara.image" files :test #'string=)))
                        (equalp image (cdr (assoc "/clara/world.image" files :test #'string=)))))))
(new-bus)
(said-by #'clara.disk:start)
(said-by #'clara.fat:start)
(check-condition error (clara:save-image))

;;; The listener, on strings.

(defun listen-to (text)
  (with-output-to-string (*standard-output*)
    (with-input-from-string (*standard-input* text)
      (clara.listener:run))))

(defvar *invitation*
  (format nil "clara: reading the serial port and the keyboard: a form is evaluated, Ctrl-C stops it, Ctrl-D ends~%"))

(defun heard (control &rest arguments)
  (concatenate 'string *invitation* (apply #'format nil control arguments)))

(check (heard "> ~%3~%> ~%") (listen-to (format nil "(+ 1 2)~%")))
(check (heard "> ~%1~%2~%> ~%:A~%\"b\"~%> ~%") (listen-to (format nil "(values 1 2)~%:a \"b\" (values)~%")))
(check (heard ">   ~%(1 2)~%> ~%") (listen-to (format nil "(list 1~% 2)~%")))
(check (heard "> ~%error: boom 7~%> ~%1~%> ~%") (listen-to (format nil "(error \"boom ~~D\" 7)~%1~%")))
(check (heard "> x~%\"x\"~%> ~%") (listen-to (format nil "(write-string \"x\")~%")))
(check (heard ">   ~%the input ended in the middle of a form~%") (listen-to (format nil "(car~%")))
(let ((heard (listen-to (format nil "1 ) 2~%3~%"))))    ; what cannot be read is dropped, and said
  (check t (and (search (format nil "> ~%1~%error: ") heard)
                (search (format nil "~%> ~%3~%> ~%") heard)
                (not (search (format nil "~%2~%") heard)))))
(check (format nil "error: gone~%> ~%")
       (with-output-to-string (*standard-output*)
         (with-input-from-string (*standard-input* "")
           (clara.listener:run (make-condition 'simple-error :format-control "gone")))))
;; Ctrl-C at the prompt gives up the line, and the form that it was to go on.
(let ((lines (list "(list 1" :interrupt "(+ 1 2)")))
  (check (heard ">   > ~%3~%> ~%")
         (with-output-to-string (*standard-output*)
           (let ((*standard-input*
                   (clara:make-stream :read-line (lambda ()
                                                   (let ((line (pop lines)))
                                                     (if (eq line :interrupt)
                                                         (error 'clara:keyboard-interrupt)
                                                         line))))))
             (clara.listener:run)))))

;;; The window manager, on a screen that is made up. What the screen should
;;; show is worked out here, pixel by pixel, from the windows there are and
;;; where they lie, by a rule of the tests' own: the pointer over the
;;; launcher's list, that over the windows from the topmost down, those over
;;; the bar and the desk. After everything that is done, every pixel of the
;;; screen has to be what the rule says.

(defconstant +desk+ #x2d2942)
(defconstant +paper+ #x1e1b2e)
(defconstant +ink+ #xe8e3f4)
(defconstant +lit+ #xffb86c)
(defconstant +dim+ #x4a4466)

(defvar *desk-width* 0)
(defvar *desk-height* 0)

(defun eventually (function)
  (loop repeat 1000
        do (when (funcall function)
             (return t))
           (sleep 0.005)))

;; A machine with a screen, what draws started on it, and the window manager
;; as a world has it that never ran one.
(defun new-desk (&key (width 200) (height 140) applications (start t))
  (clara.host:reset-machine)
  (setq *desk-width* width
        *desk-height* height
        *pitch* (* 4 (+ width 2))
        *pixels* (clara.unsafe:allocate-memory (ceiling (* *pitch* height) 4096)))
  (clara.host:set-framebuffer *pixels* width height *pitch* #xff0000 #x00ff00 #x0000ff)
  (with-output-to-string (*standard-output*)
    (clara.draw:start))
  (clara.input:set-pointer-limits width height)
  (clara.input:send-keys-to nil)
  (clara.input:send-pointer-to nil)
  (setq clara.windows::*running* nil
        clara.windows::*applications*
        (mapcar (lambda (application)
                  (if (consp application)
                      (clara.windows::make-application :name (car application) :function (cdr application))
                      application))
                applications))
  (clara.windows:resume)
  (and start (clara.windows:start)))

;; What a window puts at a place on the screen, or NIL when it is not there.
(defun window-rule (window x y lit)
  (let* ((wx (clara.windows::window-x window)) (wy (clara.windows::window-y window))
         (width (clara.windows::window-width window)) (height (clara.windows::window-height window))
         (box (clara.windows::window-close window))
         (frame (if lit +lit+ +dim+)) (text (if lit +paper+ +ink+)))
    (cond ((and (<= wx x (+ wx width -1)) (<= wy y (+ wy height -1)))
           (word-at (clara.windows:window-surface window) (- x wx) (- y wy)))
          ((not (and (<= (1- wx) x (+ wx width)) (<= (- wy 21) y (+ wy height))))
           nil)
          ((>= y wy) frame)                   ; the line down each side and along the bottom
          ((and (<= (+ wx 3) x) (< x (- (+ wx width) 3 (if box 16 0)))
                (text-p (clara.windows:window-title window) (- x wx 3) (- y (- wy 19))))
           text)
          ((and box (glyph-p #\x (- x (- (+ wx width) 12)) (- y (- wy 19)))) text)
          (t frame))))

(defun bar-rule (x y)
  (let* ((name (format nil "~A ~A" (lisp-implementation-type) (lisp-implementation-version)))
         (at (- *desk-width* 8 (* 8 (length name)))))
    (cond ((>= y 20) nil)
          ((text-p "Applications" (- x 8) (- y 2)) +ink+)
          ((and (>= at 112) (text-p name (- x at) (- y 2))) +ink+)
          (t +paper+))))

(defun menu-rule (x y)
  (let* ((names (clara.windows:applications))
         (width (reduce #'max (mapcar (lambda (name) (+ 16 (* 8 (length name)))) names) :initial-value 112))
         (height (* 20 (length names))))
    (cond ((not (and clara.windows::*menu* (< -1 x width) (<= 20 y (+ 19 height)))) nil)
          ((or (= x 0) (= x (1- width)) (= y 20) (= y (+ 19 height))) +ink+)
          ((text-p (nth (floor (- y 20) 20) names) (- x 8) (- (mod (- y 20) 20) 2)) +ink+)
          (t +paper+))))

(defun pointer-rule (x y)
  (let ((dx (- x clara.windows::*pointer-x*)) (dy (- y clara.windows::*pointer-y*)))
    (and (<= 0 dx 11) (<= 0 dy 18)
         (cond ((logbitp (- 11 dx) (aref clara.windows::*arrow-edge* dy)) 0)
               ((logbitp (- 11 dx) (aref clara.windows::*arrow-fill* dy)) +ink+)))))

(defun should-show (x y)
  (or (pointer-rule x y)
      (menu-rule x y)
      (let ((windows (clara.windows:windows)))
        (loop for window in windows
              thereis (window-rule window x y (eq window (first windows)))))
      (bar-rule x y)
      +desk+))

;; How many pixels of the screen are not what they should be, and the first
;; of them, for whoever has to find out why.
(defun wrong-pixels ()
  (let ((wrong 0) (first nil))
    (dotimes (y *desk-height*)
      (dotimes (x *desk-width*)
        (let ((shown (pixel-at x y)) (should (should-show x y)))
          (unless (= shown should)
            (incf wrong)
            (unless first
              (setq first (list x y shown should)))))))
    (if first (list wrong first) 0)))

;; Without a screen there is nothing to start, and nothing to open a window with.
(clara.host:reset-machine)
(with-output-to-string (*standard-output*) (clara.draw:start))
(setq clara.windows::*running* nil)
(check '(nil nil nil) (list (clara.windows:resume) (clara.windows:start) (clara.windows:running-p)))
(check-condition error (clara.windows:open-window "nowhere" 40 30))
(check nil (clara.windows:stop))

;; Started: the desk, the bar with what the system is, and the pointer in
;; the middle. The keys and the pointer are the window manager's.
(check t (new-desk))
(check 0 (wrong-pixels))
(check '(t t nil) (list (clara.windows:running-p) (clara.windows:start) (clara.windows:windows)))
(check t (and (eq clara.input::*keys-to* #'clara.windows:key-typed)
              (eq clara.input::*pointer-to* #'clara.windows:pointer-moved)))
(check 65 (clara.windows:key-typed 65))        ; typed with no window to have it: nothing happens
(new-desk :width 110)                          ; too narrow for the system's name: the button alone
(check 0 (wrong-pixels))

;; A window: on top, with the focus, the colour of paper inside; what is
;; drawn on its surface is on the screen when it has been shown, and not
;; before.
(new-desk)
(defvar *a* (clara.windows:open-window "First" 60 40))
(check 0 (wrong-pixels))
(check '(t "First" (40 64) 60 40)
       (list (clara.windows:window-p *a*) (clara.windows:window-title *a*)
             (multiple-value-list (clara.windows:window-position *a*))
             (clara.draw:surface-width (clara.windows:window-surface *a*))
             (clara.draw:surface-height (clara.windows:window-surface *a*))))
(check (list +paper+ +paper+) (list (clara.draw:pixel (clara.windows:window-surface *a*) 0 0) (pixel-at 99 103)))
(check '(t t) (list (eq (clara.windows:focused-window) *a*) (equal (clara.windows:windows) (list *a*))))
(check nil (clara.windows:show *a*))           ; nothing was drawn
(clara.draw:fill-rectangle (clara.windows:window-surface *a*) 5 5 20 10 #x112233)
(clara.draw:draw-text (clara.windows:window-surface *a*) 2 20 "hello" +ink+)
(check t (listp (wrong-pixels)))
(check '(t 0 nil) (list (clara.windows:show *a*) (wrong-pixels) (clara.windows:show *a*)))

;; A second one lies over the first and has the focus; the first is still
;; drawn on, as far as it can be seen.
(defvar *closed* 0)
(defvar *b* (clara.windows:open-window "Second window, with a long title" 70 50 :x 80 :y 80
                                       :close (lambda () (incf *closed*))))
(check 0 (wrong-pixels))
(check t (equal (clara.windows:windows) (list *b* *a*)))
(clara.draw:fill-rectangle (clara.windows:window-surface *a*) 30 10 30 30 #x445566)
(clara.draw:fill-rectangle (clara.windows:window-surface *b*) 0 0 70 50 #x778899)
(check '(t t 0) (list (clara.windows:show *a*) (clara.windows:show *b*) (wrong-pixels)))
(check (list #x778899 #x445566) (list (pixel-at 95 100) (pixel-at 75 100)))
(check '(t t 0) (list (eq (clara.windows:raise-window *a*) *a*) (eq (clara.windows:focused-window) *a*) (wrong-pixels)))
(check 0 (progn (clara.windows:raise-window *a*) (wrong-pixels)))        ; on top already
(defvar *c* (clara.windows:open-window "3" 24 1))                        ; the third goes a step down and across
(check '((88 112) 0) (list (multiple-value-list (clara.windows:window-position *c*)) (wrong-pixels)))

;; Moving: anywhere, as long as its band stays below the bar and some of
;; it on the screen.
(check '((100 60) 0) (list (multiple-value-list (clara.windows:move-window *a*  100 60)) (wrong-pixels)))
(check '((176 136) 0) (list (multiple-value-list (clara.windows:move-window *a* 500 500)) (wrong-pixels)))
(check '((-36 41) 0) (list (multiple-value-list (clara.windows:move-window *a* -500 -500)) (wrong-pixels)))
(check '((150 41) 0) (list (multiple-value-list (clara.windows:move-window *b* 150 0)) (wrong-pixels)))
(check '((30 50) 0) (list (multiple-value-list (clara.windows:move-window *a* 30 50)) (wrong-pixels)))
(check t (equal (clara.windows:windows) (list *c* *a* *b*)))             ; moving does not raise

;; The pointer: its picture goes where it is said to be, also half off the
;; screen, and what was under it is there again.
(dolist (place '((0 0) (10 5) (199 139) (195 130) (33 47) (60 70) (150 30) (100 100)))
  (clara.windows:pointer-moved (first place) (second place) 0)
  (check (list place 0) (list place (wrong-pixels))))

;; A click on a window brings it to the top. By its frame it is taken hold
;; of, and goes where the pointer goes until the button comes up.
(clara.windows:pointer-moved 160 30 0)
(clara.windows:pointer-moved 160 30 1)         ; on the band of the second one
(check '(t 0) (list (eq (clara.windows:focused-window) *b*) (wrong-pixels)))
(clara.windows:pointer-moved 120 70 1)
(check '((110 81) 0) (list (multiple-value-list (clara.windows:window-position *b*)) (wrong-pixels)))
(clara.windows:pointer-moved 20 60 1)
(check '((10 71) 0) (list (multiple-value-list (clara.windows:window-position *b*)) (wrong-pixels)))
(clara.windows:pointer-moved 20 60 0)          ; let go
(clara.windows:pointer-moved 90 90 0)
(check '((10 71) 0) (list (multiple-value-list (clara.windows:window-position *b*)) (wrong-pixels)))
(clara.windows:pointer-moved 85 90 1)          ; the line along the bottom of the first one, which is frame too
(check t (eq (clara.windows:focused-window) *a*))
(clara.windows:pointer-moved 95 100 1)
(check '((40 60) 0) (list (multiple-value-list (clara.windows:window-position *a*)) (wrong-pixels)))
(clara.windows:pointer-moved 95 100 0)
(clara.windows:pointer-moved 190 130 1)        ; the desk: nothing to take hold of
(clara.windows:pointer-moved 150 100 1)
(clara.windows:pointer-moved 150 100 0)
(check t (equal (list (clara.windows:windows) 0) (list (list *a* *b* *c*) (wrong-pixels))))

;; What is typed is for the window that has the focus, and a button that
;; goes down or up on the inside of a window is for that window: its
;; program is told where, counted from its own corner.
(let* ((typed nil) (pointed nil)
       (d (clara.windows:open-window "keys" 40 30 :x 120 :y 60
                                     :key (lambda (code) (push code typed))
                                     :pointer (lambda (x y buttons) (push (list x y buttons) pointed)))))
  (clara.windows:key-typed 97)
  (clara.windows:raise-window *a*)
  (clara.windows:key-typed 98)                 ; the first has no use for keys
  (clara.windows:pointer-moved 130 70 0)       ; over it: nothing to tell
  (clara.windows:pointer-moved 130 70 1)       ; down on its inside: it has the focus, and is told
  (clara.windows:key-typed 99)
  (clara.windows:pointer-moved 135 75 1)       ; moving with the button down is not a button
  (clara.windows:pointer-moved 135 75 5)       ; another button
  (clara.windows:pointer-moved 135 75 4)
  (clara.windows:pointer-moved 135 75 0)
  (clara.windows:pointer-moved 125 45 1)       ; its band: taken hold of, and nothing to tell
  (clara.windows:pointer-moved 125 45 0)
  (check '((99 97) ((15 15 0) (15 15 4) (15 15 5) (10 10 1))) (list typed pointed))
  (check '(t 0) (list (eq (clara.windows:focused-window) d) (wrong-pixels)))
  (check nil (clara.windows:close-window d))
  (check '(0 3) (list (wrong-pixels) (length (clara.windows:windows)))))

;; The close box, in the band of a window that has a function for it: the
;; function is called, once, and the window is its program's to close.
(clara.windows:raise-window *b*)
(multiple-value-bind (x y) (clara.windows:window-position *b*)
  (clara.windows:pointer-moved (+ x 60) (- y 10) 0)
  (clara.windows:pointer-moved (+ x 60) (- y 10) 1)
  (clara.windows:pointer-moved (+ x 60) (- y 10) 0)
  (clara.windows:pointer-moved (+ x 60) (- y 10) 1)
  (clara.windows:pointer-moved (+ x 60) (- y 10) 0)
  (check '(1 3 nil) (list *closed* (length (clara.windows:windows)) clara.windows::*drag*))
  (clara.windows:pointer-moved (+ x 50) (- y 10) 1)   ; a pixel short of the box: the band
  (check t (eq (car clara.windows::*drag*) *b*))
  (clara.windows:pointer-moved (+ x 50) (- y 10) 0))
(clara.windows:pointer-moved 100 49 1)         ; where the box would be in a window that has none: its band
(check '(t 1) (list (eq (car clara.windows::*drag*) *a*) *closed*))
(clara.windows:pointer-moved 100 49 0)

;; Closing: the window is gone from the screen, the one below has the
;; focus, and its page frames are given back. It is closed by the thread
;; that opened it, which is the one that draws on it, or by anybody when
;; that thread is no more.
(let ((pages (clara.host:allocated-pages)))
  (check :refused (clara:join-thread (clara:make-thread (lambda ()
                                                           (handler-case (clara.windows:close-window *a*)
                                                             (error () :refused))))))
  (check '(nil 0 t) (list (clara.windows:close-window *a*) (wrong-pixels) (equal (clara.windows:windows) (list *b* *c*))))
  (check 3 (- pages (clara.host:allocated-pages)))                        ; 60 by 40 pixels of 4 bytes
  (check nil (clara.windows:close-window *a*))                            ; closed already
  (check-condition error (clara.windows:show *a*))
  (check-condition error (clara.windows:move-window *a* 0 0))
  (check-condition error (clara.windows:raise-window *a*))
  (check-condition error (clara.windows:close-window 5))
  (check nil (clara.windows:window-surface *a*)))
(let* ((made nil)
       (thread (clara:make-thread (lambda () (setq made (clara.windows:open-window "left behind" 30 20 :close #'list))))))
  (clara:join-thread thread)
  (check '(3 0) (list (length (clara.windows:windows)) (wrong-pixels)))
  (multiple-value-bind (x y) (clara.windows:window-position made)
    (clara.windows:pointer-moved (+ x 25) (- y 10) 1)                     ; its close box: nobody is left to ask
    (clara.windows:pointer-moved (+ x 25) (- y 10) 0))
  (check '(2 0 nil) (list (length (clara.windows:windows)) (wrong-pixels) (clara.windows:window-surface made))))
(check-condition error (clara.windows:open-window "small" 23 10))          ; too narrow to have a band to hold
(check-condition error (clara.windows:open-window 'title 40 30))
(check-condition error (clara.windows:open-window "none" 40 0))
(check 2 (length (clara.windows:windows)))

;; The launcher: a click on the bar's button opens the list of what is
;; defined, and a click on a name launches that application, in a thread
;; of its own; any other click shuts the list. LAUNCH comes back when the
;; application has its window, and the windows that it leaves open when it
;; is done are closed for it.
(defvar *finish* (clara:make-event "finish"))
(defvar *ran* nil)

(defun waits-in-a-window (title)
  (lambda ()
    (clara.windows:open-window title 50 20)
    (push title *ran*)
    (clara:wait-event *finish*)))

(new-desk :applications (list (cons "One" (waits-in-a-window "one"))
                              (cons "The second of them" (waits-in-a-window "two"))))
(check '("One" "The second of them") (clara.windows:applications))
(check t (eventually (lambda () (equal *ran* '("one")))))               ; START launches the first
(check '(("one") 0) (list (mapcar #'clara.windows:window-title (clara.windows:windows)) (wrong-pixels)))
(clara.windows:pointer-moved 150 10 1)         ; the bar, and not its button
(clara.windows:pointer-moved 150 10 0)
(check '(nil 0) (list clara.windows::*menu* (wrong-pixels)))
(clara.windows:pointer-moved 111 19 1)         ; the last pixel of the button
(clara.windows:pointer-moved 111 19 0)
(check '(t 0) (list clara.windows::*menu* (wrong-pixels)))
(clara.windows:pointer-moved 20 50 0)          ; the pointer over the list
(check 0 (wrong-pixels))
(clara.windows:pointer-moved 20 50 1)          ; the second name
(clara.windows:pointer-moved 20 50 0)
(check t (eventually (lambda () (equal *ran* '("two" "one")))))
(check '(nil ("two" "one") 0)
       (list clara.windows::*menu* (mapcar #'clara.windows:window-title (clara.windows:windows)) (wrong-pixels)))
(clara.windows:pointer-moved 5 5 1)
(clara.windows:pointer-moved 5 5 0)
(clara.windows:pointer-moved 190 30 1)         ; beside the list: it shuts, and nothing is launched
(clara.windows:pointer-moved 190 30 0)
(check '(nil 2 0) (list clara.windows::*menu* (length (clara.windows:windows)) (wrong-pixels)))
(clara.windows:pointer-moved 5 5 1)
(clara.windows:pointer-moved 5 5 0)
(clara.windows:pointer-moved 20 70 1)          ; under the last name
(clara.windows:pointer-moved 20 70 0)
(check '(nil 2 0) (list clara.windows::*menu* (length (clara.windows:windows)) (wrong-pixels)))
(let ((thread (clara.windows:launch "one")))    ; by its name, in letters of either case
  (check '(t 3 0) (list (clara:thread-alive-p thread) (length (clara.windows:windows)) (wrong-pixels)))
  (clara:signal-event *finish* 3)
  (clara:join-thread thread)
  (check t (eventually (lambda () (null (clara.windows:windows)))))
  (check 0 (wrong-pixels)))
(check-condition error (clara.windows:launch "nothing of the kind"))
;; An application that opens no window, one that fails, and one that is
;; stopped: LAUNCH comes back all the same, and nothing stays open.
(clara.windows:define-application "Quiet" (lambda () 'done))
(clara.windows:define-application "one" (lambda () (clara.windows:open-window "stopped" 40 20) (clara:wait-event *finish*)))
(check '("One" "The second of them" "Quiet") (clara.windows:applications))
(check 'done (clara:join-thread (clara.windows:launch "Quiet")))
(let ((thread (clara.windows:launch "One")))
  (check '("stopped") (mapcar #'clara.windows:window-title (clara.windows:windows)))
  (clara:destroy-thread thread)
  (check t (eventually (lambda () (null (clara.windows:windows)))))
  (check 0 (wrong-pixels)))
(check-condition error (clara.windows:define-application 'name #'list))

;; Stopping: the keys and the pointer are the console's again, the page
;; frames of what the screen was put together on are given back, the
;; applications are stopped and close their windows, and a window of some
;; other thread is off the screen and still that thread's to close.
(let* ((pages (clara.host:allocated-pages))
       (thread (clara.windows:launch "One"))
       (mine (clara.windows:open-window "mine" 40 20)))
  (check '(t nil nil nil) (list (clara.windows:stop) (clara.windows:running-p) clara.input::*keys-to* clara.input::*pointer-to*))
  (check nil (clara.windows:stop))
  (check t (eventually (lambda () (not (clara:thread-alive-p thread)))))
  (check '(nil nil) (list (clara.windows:windows) (clara.windows:show mine)))
  (check-condition error (clara.windows:move-window mine 0 0))
  (check-condition error (clara.windows:launch "One"))
  (clara.windows:close-window mine)
  (check 28 (- pages (clara.host:allocated-pages)))                        ; 200 by 140 pixels of 4 bytes
  (check nil clara.windows::*made*))
(check '(t 0) (list (clara.windows:start) (wrong-pixels)))                 ; and again, afresh
(clara:signal-event *finish* 5)
(check t (eventually (lambda () (null (clara.windows:windows)))))

;; A world that was saved while the window manager ran starts in it: what
;; it knew of windows and pixels was another machine's, and is forgotten.
(let ((window (clara.windows:open-window "of another boot" 40 20)))
  (with-output-to-string (*standard-output*) (clara.draw:start))             ; the machine is another now
  (setq clara.windows::*applications* nil)
  (check (format nil "windows: the window manager has the screen again, as it had when the world was saved~%")
         (with-output-to-string (*standard-output*)
           (check t (clara.windows:resume))))
  (check '(nil 0 nil) (list (clara.windows:windows) (wrong-pixels) (clara.windows:window-surface window)))
  (check nil (clara.windows:close-window window)))
(clara.host:reset-machine)
(with-output-to-string (*standard-output*) (clara.draw:start))
(check (format nil "windows: this world was saved with the window manager running, and this machine has no screen~%")
       (with-output-to-string (*standard-output*)
         (check nil (clara.windows:resume))))
(check "" (with-output-to-string (*standard-output*) (check nil (clara.windows:resume)))) ; and one that was not

;; The console lends the screen and has it back: while the window manager
;; runs, what is written goes to the serial port alone.
(new-desk :start nil)
(attach-pl011 #x9000000)
(clara.console:use-screen *pixels* 200 140 *pitch* #xff0000 #x00ff00 #x0000ff 3 4)
(setq *sent* nil
      clara.console::*lent* nil
      clara.console::*cursor* nil
      clara.console::*reading* nil)
(clara.console:write-text "a")
(check t (shows-p 3 4 #\a :left 0 :top 6))
(check t (clara.windows:start))
(clara.console:write-text "b")
(check '("ab" 0 nil) (list (text-of (sent)) (wrong-pixels) clara.console::*screen*))
(check nil (clara.console:lend-screen))                                     ; it has none to lend
(check t (clara.windows:stop))
(check (list +paper+ +paper+ '(0 0)) (list (pixel-at 0 0) (pixel-at 199 139) (cursor)))
(clara.console:write-text "c")
(check t (shows-p 0 0 #\c :left 0 :top 6))
(check nil (clara.console:return-screen))                                   ; it was not lent

;; Whatever is done, and in whatever order, the screen is what the rule
;; says: windows opened, moved, raised, drawn on and closed, and the
;; pointer taken across them with its button down and up.
(new-desk :width 120 :height 90)
(let ((state (sb-ext:seed-random-state 12)) (wrong 0) (steps 0))
  (dotimes (step 160)
    (let ((windows (clara.windows:windows)))
      (case (if (null windows) 0 (random 9 state))
        (0 (when (< (length windows) 5)
             (clara.windows:open-window (format nil "~D" step) (+ 24 (random 50 state)) (+ 1 (random 40 state))
                                        :x (- (random 140 state) 20) :y (random 100 state)
                                        :close (and (zerop (random 2 state)) #'list))))
        (1 (clara.windows:move-window (nth (random (length windows) state) windows)
                                      (- (random 160 state) 30) (random 110 state)))
        (2 (clara.windows:raise-window (nth (random (length windows) state) windows)))
        (3 (when (zerop (random 3 state))
             (clara.windows:close-window (nth (random (length windows) state) windows))))
        ((4 5) (let ((window (nth (random (length windows) state) windows)))
                 (clara.draw:fill-rectangle (clara.windows:window-surface window) (- (random 60 state) 10)
                                            (- (random 40 state) 10) (random 40 state) (random 30 state)
                                            (1+ (random #xffffff state)))
                 (clara.draw:draw-text (clara.windows:window-surface window) (random 30 state) (random 20 state)
                                       "ab" (1+ (random #xffffff state)))
                 (clara.windows:show window)))
        (t (clara.windows:pointer-moved (random 120 state) (random 90 state) (random 2 state)))))
    (incf steps)
    (unless (eql (wrong-pixels) 0)
      (incf wrong)))
  (check '(160 0) (list steps wrong)))
(dolist (window (clara.windows:windows))
  (clara.windows:close-window window))
(clara.windows:stop)

;;; A console in a window: a terminal, whose cells are looked at on the
;;; surface of its window, and what its stream gives back when keys are
;;; typed at the window manager.

(defun cell-shows-p (surface row column character &optional (ink +ink+) (paper +paper+))
  (let* ((code (char-code character))
         (glyph (* clara.font:+height+
                   (- (if (<= clara.font:+first+ code clara.font:+last+) code (1+ clara.font:+last+))
                      clara.font:+first+))))
    (dotimes (y clara.font:+height+ t)
      (dotimes (x clara.font:+width+)
        (unless (= (word-at surface (+ (* column clara.font:+width+) x) (+ (* row clara.font:+height+) y))
                   (if (logbitp (- clara.font:+width+ 1 x) (aref clara.font:*glyphs* (+ glyph y))) ink paper))
          (return-from cell-shows-p nil))))))

;; The cells of a row from its first on show STRING.
(defun row-shows-p (surface row string &optional (ink +ink+) (paper +paper+))
  (loop for column below (length string)
        always (cell-shows-p surface row column (char string column) ink paper)))

;; The lowest two rows of a cell's pixels, where the cursor is drawn, are all of PIXEL.
(defun bar-at-p (surface row column pixel)
  (loop for y from 14 to 15
        always (loop for x below 8
                     always (= (word-at surface (+ (* column 8) x) (+ (* row 16) y)) pixel))))

(defun type-text (text)
  (map nil (lambda (character) (clara.windows:key-typed (char-code character))) text))

(new-desk :width 300 :height 220)
(defvar *terminal* (clara.terminal:open-terminal "A terminal" :columns 10 :rows 3))
(defvar *out* (clara.terminal:terminal-stream *terminal*))
(defvar *face* (clara.windows:window-surface (clara.terminal:terminal-window *terminal*)))
(check '(t "A terminal" 80 48 0)
       (list (clara.terminal:terminal-p *terminal*) (clara.windows:window-title (clara.terminal:terminal-window *terminal*))
             (clara.draw:surface-width *face*) (clara.draw:surface-height *face*) (wrong-pixels)))
(write-string "ab" *out*)
(check '(t 0) (list (row-shows-p *face* 0 "ab ") (wrong-pixels)))        ; drawn, and shown
(write-string "cdefghijkl" *out*)                                         ; the eleventh character starts a new row
(check t (and (row-shows-p *face* 0 "abcdefghij") (row-shows-p *face* 1 "kl ")))
(write-string (format nil "~%3") *out*)                                    ; three rows in use,
(write-string (format nil "~%4") *out*)                                    ; and a new line moves them all up
(check '(t 0) (list (and (row-shows-p *face* 0 "kl        ") (row-shows-p *face* 1 "3         ")
                         (row-shows-p *face* 2 "4         "))
                    (wrong-pixels)))
(write-string (format nil "~%wide row~%x") *out*)                        ; the last row was made blank first
(check t (and (row-shows-p *face* 1 "wide row  ") (row-shows-p *face* 2 "x         ")))
(write-string (coerce (list #\Backspace #\x #\Return #\y (code-char 233)) 'string) *out*)
(check t (and (cell-shows-p *face* 2 0 #\y) (cell-shows-p *face* 2 1 (code-char 127)))) ; no glyph: a box
(check nil (clara.terminal:clear *terminal*))
(check '(t 0) (list (loop for row below 3 always (row-shows-p *face* row "          ")) (wrong-pixels)))
(write-string (coerce (list #\a #\Tab #\b #\Tab #\c) 'string) *out*)      ; a tab at the end of a row ends the row
(check t (and (row-shows-p *face* 0 "a       b ") (row-shows-p *face* 1 "c ")))
(clara.terminal:clear *terminal*)
(write-string "0123456789ABCDEFGHIJxyz" *out*)                             ; one string, three rows
(check '(t 0) (list (and (row-shows-p *face* 0 "0123456789") (row-shows-p *face* 1 "ABCDEFGHIJ") (row-shows-p *face* 2 "xyz "))
                    (wrong-pixels)))
(check '("a terminal has a number of columns and of rows, and 0 by 24 are not that"
         "a terminal has a number of columns and of rows, and 80 by \"many\" are not that")
       (flet ((said (&rest size)
                (handler-case (apply #'clara.terminal:open-terminal "none" size)
                  (error (condition) (princ-to-string condition)))))
         (list (said :columns 0) (said :rows "many"))))

;; Reading: what is typed while the window has the focus is echoed and
;; comes back as a line; the cursor shows for as long.
(defun reads-a-line ()
  (clara:make-thread (lambda ()
                       (handler-case (read-line *out* nil :end)
                         (clara:keyboard-interrupt () :given-up)))))

(clara.terminal:clear *terminal*)
(let ((reader (reads-a-line)))
  (check t (eventually (lambda () (clara.terminal::terminal-cursor *terminal*))))
  (check '(t 0) (list (bar-at-p *face* 0 0 +ink+) (wrong-pixels)))
  (type-text "hi")
  (check t (eventually (lambda () (and (row-shows-p *face* 0 "hi") (bar-at-p *face* 0 2 +ink+)))))
  (clara.windows:key-typed 8)                                              ; Backspace takes the i back
  (check t (eventually (lambda () (and (bar-at-p *face* 0 1 +ink+) (bar-at-p *face* 0 2 +paper+)))))
  (clara.windows:key-typed 9)                                              ; a tab is a space
  (type-text (format nil "o~%"))
  (check "h o" (clara:join-thread reader))
  (check '(t t nil nil 0)
         (list (row-shows-p *face* 0 "h o ") (bar-at-p *face* 1 0 +paper+) (clara.terminal::terminal-cursor *terminal*)
               (clara.terminal::terminal-reading *terminal*) (wrong-pixels))))
(let ((reader (reads-a-line)))                 ; Ctrl-D at the start of a line: no more is coming
  (clara.windows:key-typed 4)
  (check '(:end nil) (list (clara:join-thread reader) (clara.terminal::terminal-reading *terminal*))))
(let ((reader (reads-a-line)))                 ; and Ctrl-C gives the line up
  (check t (eventually (lambda () (clara.terminal::terminal-reading *terminal*))))
  (type-text "x")
  (clara.windows:key-typed 3)
  (check :given-up (clara:join-thread reader))
  (check t (row-shows-p *face* 1 "x^C ")))
;; Ctrl-C while nobody reads stops what the thread that read last is
;; doing, and what was typed ahead is forgotten.
(let* ((computing (clara:make-event))
       (thread (clara:make-thread (lambda ()
                                    (list (read-line *out*)
                                          (handler-case (progn (clara:signal-event computing) (loop (sleep 0.01)))
                                            (clara:keyboard-interrupt () :stopped)))))))
  (type-text (format nil "go~%"))
  (clara:wait-event computing)
  (type-text "typed ahead")
  (check 11 (length (clara.terminal::terminal-keys *terminal*)))
  (clara.windows:key-typed 3)
  (check '("go" :stopped) (clara:join-thread thread))
  (check nil (clara.terminal::terminal-keys *terminal*)))
;; So does one that comes while a line is being read and the end of that
;; line has been typed already: the line is as good as read.
(let* ((waiting (clara:make-event)) (never (clara:make-event))
       (thread (clara:make-thread (lambda ()
                                    (handler-case (progn (clara:signal-event waiting) (clara:wait-event never))
                                      (clara:keyboard-interrupt () :stopped))))))
  (clara:wait-event waiting)
  (setf (clara.terminal::terminal-thread *terminal*) thread
        (clara.terminal::terminal-reading *terminal*) t)
  (type-text "a")
  (clara.windows:key-typed 3)                  ; in the middle of a line it is a character like the others
  (check '(97 3) (clara.terminal::terminal-keys *terminal*))
  (type-text (format nil "b~%"))
  (clara.windows:key-typed 3)
  (check :stopped (clara:join-thread thread))
  (check nil (clara.terminal::terminal-keys *terminal*))
  ;; The reading is over with the end of the line, as it is taken: a Ctrl-C
  ;; right behind it finds a thread that computes.
  (setf (clara.terminal::terminal-keys *terminal*) (list 97 10 98))
  (check '(97 t 10 nil)
         (list (clara.terminal::next-code *terminal*) (clara.terminal::terminal-reading *terminal*)
               (clara.terminal::next-code *terminal*) (clara.terminal::terminal-reading *terminal*)))
  (setf (clara.terminal::terminal-keys *terminal*) nil))
(clara.windows:close-window (clara.terminal:terminal-window *terminal*))

;; The listener in a window: the application that START launches. It says
;; what it is, reads what is typed, evaluates it and prints what it gives,
;; in the one world there is.
(let ((open-terminal #'clara.terminal:open-terminal))
  (setf (symbol-function 'clara.terminal:open-terminal)
        (lambda (&rest arguments) (setq *terminal* (apply open-terminal arguments))))
  (unwind-protect
       (progn
         (new-desk :width 300 :height 220 :applications (list (cons "Listener" #'clara.terminal:listener)))
         (let* ((window (clara.windows:focused-window))
                (face (clara.windows:window-surface window))
                (thread (car clara.windows::*launched*)))
           (check '("Listener" 248 96 "Listener")
                  (list (clara.windows:window-title window) (clara.draw:surface-width face) (clara.draw:surface-height face)
                        (clara:thread-name thread)))
           (check t (eventually (lambda () (and (row-shows-p face 3 "> ") (bar-at-p face 3 2 +ink+)))))
           (check t (and (row-shows-p face 0 "ClaraOS: a form is evaluated, C") (row-shows-p face 2 "es the window ")))
           (type-text (format nil "(+ 1 2)~%"))
           (check t (eventually (lambda () (and (row-shows-p face 3 "> (+ 1 2) ") (row-shows-p face 4 "3 ")
                                                (row-shows-p face 5 "> ") (bar-at-p face 5 2 +ink+)))))
           (check 0 (wrong-pixels))
           (type-text (format nil "(defvar *in-a-window* 7)~%"))
           (flet ((in-a-window ()
                    (let ((symbol (find-symbol "*IN-A-WINDOW*" "COMMON-LISP-USER")))
                      (and symbol (boundp symbol) (symbol-value symbol)))))
             (check t (eventually (lambda () (eql (in-a-window) 7))))
             ;; Ctrl-C stops what it computes, and it reads again.
             (type-text (format nil "(loop)~%"))
             (check t (eventually (lambda () (not (clara.terminal::terminal-reading *terminal*)))))
             (clara.windows:key-typed 3)
             (check t (eventually (lambda () (clara.terminal::terminal-reading *terminal*))))
             (type-text (format nil "(setq *in-a-window* 8)~%"))
             (check t (eventually (lambda () (eql (in-a-window) 8)))))
           (clara.windows:key-typed 4)             ; Ctrl-D at its prompt: it ends, and its window goes with it
           (check t (eventually (lambda () (and (null (clara.windows:windows)) (not (clara:thread-alive-p thread))))))
           (check '(0 nil) (list (wrong-pixels) clara.windows::*made*)))
         ;; The close box ends it as well.
         (let ((thread (clara.windows:launch "listener")))
           (multiple-value-bind (x y) (clara.windows:window-position (clara.windows:focused-window))
             (clara.windows:pointer-moved (+ x 240) (- y 10) 1)
             (clara.windows:pointer-moved (+ x 240) (- y 10) 0))
           (check t (eventually (lambda () (and (null (clara.windows:windows)) (not (clara:thread-alive-p thread))))))
           (check 0 (wrong-pixels)))
         (clara.windows:stop))
    (setf (symbol-function 'clara.terminal:open-terminal) open-terminal)))
(setq clara.windows::*applications* *defined-applications*)
;; What lisp/terminal.lisp defined and installed when it was loaded: the two
;; that are files have a function here because the tests loaded the files.
(check '(("Listener" nil) ("Editor" "/clara/editor.lisp") ("Files" "/clara/files.lisp"))
       (mapcar (lambda (application)
                 (list (clara.windows::application-name application) (clara.windows::application-file application)))
               clara.windows::*applications*))
(check '("Listener" "Editor" "Files") (clara.windows:applications))
(check (list #'clara.terminal:listener #'clara.editor:edit #'clara.files:browse)
       (mapcar #'clara.windows::application-function clara.windows::*applications*))

;;; What happens to a window, kept for its program: the keys that are typed
;;; while it has the focus, the buttons on its inside and its close box, in
;;; the order in which they happened.

(defun click (x y)
  (clara.windows:pointer-moved x y 1)
  (clara.windows:pointer-moved x y 0))

(new-desk :width 300 :height 220)
(let ((kept (clara.windows:open-window "kept" 80 40 :events t))
      (told (clara.windows:open-window "told" 80 40 :x 150 :y 120)))
  (flet ((refused (window)                     ; a window that was opened without, and what is no window
           (handler-case (clara.windows:next-event window 0)
             (error (condition) (and (search "OPEN-WINDOW with :EVENTS makes one" (princ-to-string condition)) t)))))
    (check '(t t) (list (refused told) (refused 'window))))
  (check '(nil nil) (list (clara.windows:next-event kept 0) (clara.windows:next-event kept 20))) ; nothing has happened
  (type-text "no")                                                           ; typed at the other window
  (clara.windows:raise-window kept)
  (type-text "hi")
  (clara.windows:key-typed clara.input:+up+)
  (multiple-value-bind (x y) (clara.windows:window-position kept)
    (clara.windows:pointer-moved (+ x 5) (+ y 7) 1)
    (clara.windows:pointer-moved (+ x 6) (+ y 7) 1)                          ; a move is not told
    (clara.windows:pointer-moved (+ x 6) (+ y 7) 0)
    (click (+ x 75) (- y 10))                                                ; the box,
    (click (+ x 75) (- y 10))                                                ; and again before anybody heard
    (check (list '(:key 104) '(:key 105) (list :key clara.input:+up+) '(:pointer 5 7 1) '(:pointer 6 7 0) '(:close) nil)
           (loop repeat 7 collect (clara.windows:next-event kept 0)))
    (click (+ x 75) (- y 10))                                                ; heard: the next click is told again
    (check '((:close) nil) (list (clara.windows:next-event kept) (clara.windows:next-event kept 0))))
  (let ((thread (clara:make-thread (lambda () (clara.windows:next-event kept))))) ; it waits for as long as it takes
    (sleep 0.02)
    (check t (clara:thread-alive-p thread))
    (clara.windows:key-typed 65)
    (check '(:key 65) (clara:join-thread thread)))
  (dotimes (i 1100)                                                          ; what nobody takes is kept up to a limit
    (clara.windows:key-typed 66))
  (check '(1024 (:key 66)) (list (length (clara.windows::window-events kept)) (clara.windows:next-event kept)))
  (setf (clara.windows::window-events kept) nil)
  ;; Another title, on the screen at once; and Tab with Alt held brings the
  ;; lowest window to the top, each in its turn, and is no key of a window's.
  (check '("renamed" "renamed" 0)
         (list (clara.windows:rename-window kept "renamed") (clara.windows:window-title kept) (wrong-pixels)))
  (check-condition error (clara.windows:rename-window kept 'renamed))
  (check-condition error (clara.windows:rename-window "kept" "renamed"))
  (let ((third (clara.windows:open-window "third" 60 30 :x 100 :y 60)))
    (flet ((order ()
             (clara.windows:key-typed (+ clara.input:+alt+ 9))
             (list (mapcar #'clara.windows:window-title (clara.windows:windows)) (wrong-pixels))))
      (check '(("told" "third" "renamed") 0) (order))
      (check '(("renamed" "told" "third") 0) (order))
      (check '(("third" "renamed" "told") 0) (order)))
    (check nil (clara.windows:next-event kept 0))
    (clara.windows:close-window third)
    (clara.windows:close-window told)
    (check (+ clara.input:+alt+ 9) (clara.windows:key-typed (+ clara.input:+alt+ 9))) ; one window: nothing to bring up
    (check '(("renamed") 0) (list (mapcar #'clara.windows:window-title (clara.windows:windows)) (wrong-pixels)))
    (clara.windows:rename-window kept "closed")                              ; a window that is off the screen has a title too
    (clara.windows:close-window kept)
    (check '("gone" 0) (list (clara.windows:rename-window kept "gone") (wrong-pixels)))))

;;; Applications that are files. The files are the host's, in a directory of
;;; this run's own: LOAD, OPEN and DELETE-FILE are SBCL's here.

(defvar *scratch* (format nil "/tmp/clara-host-tests-~36R/" (random (expt 36 10) (make-random-state t))))
(ensure-directories-exist *scratch*)

(defun scratch (name)
  (concatenate 'string *scratch* name))

(defun write-scratch (name &rest lines)
  (ensure-directories-exist (scratch name))
  (with-open-file (out (scratch name) :direction :output :if-exists :supersede)
    (format out "~{~A~%~}" lines))
  (scratch name))

(defun scratch-text (name)
  (with-open-file (in (scratch name))
    (let ((text (make-string (file-length in))))
      (subseq text 0 (read-sequence text in)))))

;; What a thread that fails says goes where every thread writes, the value
;; that *STANDARD-OUTPUT* has outside every binding: not for this run's
;; output to show, which this thread goes on writing to.
(defmacro silently (&body body)
  `(let* ((output (sb-ext:symbol-global-value '*standard-output*)) (*standard-output* output)
          (errors (sb-ext:symbol-global-value '*error-output*)))
     (setf (sb-ext:symbol-global-value '*standard-output*) (make-broadcast-stream)
           (sb-ext:symbol-global-value '*error-output*) (make-broadcast-stream)) ; where SBCL's LOAD says which form failed
     (unwind-protect (progn ,@body)
       (setf (sb-ext:symbol-global-value '*standard-output*) output
             (sb-ext:symbol-global-value '*error-output*) errors))))

(defun titles ()
  (mapcar #'clara.windows:window-title (clara.windows:windows)))

(defun hello-file (title)
  (write-scratch "hello.lisp"
                 "(defpackage \"CLARA.TESTS.HELLO\" (:use \"COMMON-LISP\"))"
                 "(in-package \"CLARA.TESTS.HELLO\")"
                 "(defvar *loaded* 0)"
                 "(setq *loaded* (1+ *loaded*))"
                 "(defun hello (&rest arguments)"
                 (format nil "  (clara.windows:open-window (format nil \"~A~~{ ~~A~~}\" arguments) 60 30)" title)
                 "  (clara:wait-event (clara:make-event)))"
                 "(clara.windows:define-application \"Hello\" #'hello)"))

(defun hello-loaded ()
  (let ((symbol (and (find-package "CLARA.TESTS.HELLO") (find-symbol "*LOADED*" "CLARA.TESTS.HELLO"))))
    (and symbol (symbol-value symbol))))

(new-desk :width 300 :height 220)
(check '("Hello" ("Hello") nil)                 ; installed: in the list, and nobody has loaded the file
       (list (clara.windows:install-application "Hello" (hello-file "hello")) (clara.windows:applications) (hello-loaded)))
(let ((first (clara.windows:launch "hello" 1 2)))                            ; loaded now, and called with the arguments
  (check '(("hello 1 2") 1 t 0) (list (titles) (hello-loaded) (clara:thread-alive-p first) (wrong-pixels)))
  (let ((second (clara.windows:launch "Hello")))                             ; and not loaded a second time
    (check '(("hello" "hello 1 2") 1) (list (titles) (hello-loaded)))
    (hello-file "again")
    ;; Unloaded: stopped wherever it ran, its windows closed, its package
    ;; deleted, and still in the list.
    (check '("Hello" nil nil nil nil ("Hello") 0)
           (list (clara.windows:unload-application "HELLO") (titles) (clara:thread-alive-p first)
                 (clara:thread-alive-p second) (find-package "CLARA.TESTS.HELLO") (clara.windows:applications)
                 (wrong-pixels)))))
(let ((thread (clara.windows:launch "Hello" 3)))                             ; the file as it is by now
  (check '(("again 3") 1) (list (titles) (hello-loaded)))
  (clara.windows:pointer-moved 5 5 1)                                        ; with the launcher's list open:
  (clara.windows:pointer-moved 5 5 0)
  (check '(t "Hello" nil nil nil nil 0)                                      ; removed, it is shut, and one name shorter
         (list clara.windows::*menu* (clara.windows:remove-application "hello") clara.windows::*menu* (titles)
               (clara:thread-alive-p thread) (find-package "CLARA.TESTS.HELLO") (wrong-pixels))))
(check nil (clara.windows:applications))
(check-condition error (clara.windows:launch "Hello"))
(check-condition error (clara.windows:unload-application "Hello"))
(check-condition error (clara.windows:remove-application "Hello"))
(check-condition error (clara.windows:install-application "Hello" 'hello.lisp))
(check-condition error (clara.windows:install-application 'hello "hello.lisp"))
;; An application of the world's own has no file to load again: it is not
;; unloaded, and it can be removed. One that is installed under its name
;; keeps the function that it has.
(clara.windows:define-application "World" (lambda () 'done))
(check-condition error (clara.windows:unload-application "World"))
(check '("world" ("World") done)
       (list (clara.windows:install-application "world" (scratch "never.lisp")) (clara.windows:applications)
             (clara:join-thread (clara.windows:launch "World"))))
(check '("World" nil) (list (clara.windows:remove-application "World") (clara.windows:applications)))
;; A file that defines no application of the name, one that fails halfway
;; and one that is not there: the thread ends with the reason, LAUNCH comes
;; back, and what the file made before it failed is deleted with the rest.
(clara.windows:install-application "Nothing" (write-scratch "nothing.lisp"
                                                            "(defpackage \"CLARA.TESTS.NOTHING\" (:use \"COMMON-LISP\"))"))
(clara.windows:install-application "Broken" (write-scratch "broken.lisp"
                                                           "(defpackage \"CLARA.TESTS.BROKEN\" (:use \"COMMON-LISP\"))"
                                                           "(error \"halfway\")"
                                                           "(clara.windows:define-application \"Broken\" #'list)"))
(clara.windows:install-application "Missing" (scratch "missing.lisp"))
(silently
  (flet ((fails (name words)                    ; the thread ended with an error that says WORDS
           (handler-case (clara:join-thread (clara.windows:launch name))
             (error (condition)
               (and (search "ended with an error" (princ-to-string condition))
                    (search words (princ-to-string condition))
                    t)))))
    (check '(t t t) (list (fails "Nothing" "it defined no application \"Nothing\"") (fails "Broken" "halfway")
                          (fails "Missing" "missing.lisp")))
    (check '(t t) (list (and (find-package "CLARA.TESTS.NOTHING") t) (and (find-package "CLARA.TESTS.BROKEN") t)))
    (check t (fails "Broken" "halfway"))                                     ; and it is tried again at the next launch
    (clara.windows:unload-application "Nothing")
    (clara.windows:unload-application "Broken")
    (check '(nil nil) (list (find-package "CLARA.TESTS.NOTHING") (find-package "CLARA.TESTS.BROKEN")))))
(dolist (name '("Nothing" "Broken" "Missing"))
  (clara.windows:remove-application name))
;; Two that are launched at once load the file once between them.
(clara.windows:install-application "Hello" (hello-file "twice"))
(let ((threads (mapcar (lambda (n) (clara:make-thread (lambda () (clara.windows:launch "Hello" n)))) '(1 2))))
  (mapc #'clara:join-thread threads)
  (check '(2 1) (list (length (titles)) (hello-loaded))))
(check '(t nil nil) (list (clara.windows:stop) (titles) (clara.windows:running-p)))
(clara.windows:remove-application "Hello")
(setq clara.windows::*applications* *defined-applications*)

;;; The editor. What its window shows is held against the text, cell by
;;; cell, and the text against an editor of the tests' own, which keeps its
;;; lines in one list and does everything the slow way.

(defun pad (string width)
  (subseq (concatenate 'string string (make-string width :initial-element #\Space)) 0 width))

;; How many cells of a window of text are not what they should be. ROWS is
;; what each row shows from its first cell on: a string, in ink on paper,
;; or a list of one, with the two the other way round. BARS are the cursors
;; that are drawn, each the row, the column and the pixel of the two rows of
;; pixels at the foot of a cell.
(defun wrong-cells (surface rows &optional bars)
  (let ((wrong 0))
    (loop for spec in rows
          for row from 0
          do (let* ((text (if (consp spec) (car spec) spec))
                    (ink (if (consp spec) +paper+ +ink+)) (paper (if (consp spec) +ink+ +paper+)))
               (dotimes (column (length text))
                 (let* ((bar (find-if (lambda (bar) (and (= (first bar) row) (= (second bar) column))) bars))
                        (code (char-code (char text column)))
                        (glyph (* 16 (- (if (<= 32 code 126) code 127) 32))))
                   (unless (loop for y below 16
                                 always (loop for x below 8
                                              always (= (word-at surface (+ (* 8 column) x) (+ (* 16 row) y))
                                                        (cond ((and bar (>= y 14)) (third bar))
                                                              ((logbitp (- 7 x) (aref clara.font:*glyphs* (+ glyph y))) ink)
                                                              (t paper)))))
                     (incf wrong))))))
    wrong))

(defun editor-state (editor)
  (list (clara.editor::all-lines editor) (clara.editor::editor-row editor) (clara.editor::editor-column editor)))

;; The window of an editor against its text, after it was drawn.
(defun editor-wrong (editor)
  (clara.editor::render editor)
  (let* ((lines (clara.editor::all-lines editor))
         (top (clara.editor::editor-top editor)) (left (clara.editor::editor-left editor))
         (columns (clara.editor::editor-columns editor)) (rows (clara.editor::editor-rows editor))
         (asking (clara.editor::editor-asking editor)))
    (wrong-cells (clara.editor::editor-surface editor)
                 (append (loop for r below rows
                               collect (let ((line (or (nth (+ top r) lines) "")))
                                         (pad (if (< left (length line)) (subseq line left) "") columns)))
                         (list (list (pad (clara.editor::status editor) columns))))
                 (cons (list (- (clara.editor::editor-row editor) (clara.editor::editor-top editor))
                             (- (clara.editor::editor-column editor) (clara.editor::editor-left editor)) +ink+)
                       (and asking
                            (list (list rows (+ 1 (length (car asking)) (length (clara.editor::editor-answer editor)))
                                        +paper+)))))))

(defun keys (editor &rest codes)
  (dolist (code codes)
    (if (stringp code)
        (map nil (lambda (character) (clara.editor::key editor (char-code character))) code)
        (clara.editor::key editor code))))

(new-desk :width 300 :height 220)
;; An editor with no file: one line with nothing in it, the cursor at its
;; start, and words about the keys until the first of them.
(let ((editor (clara.editor::open-editor nil :columns 30 :rows 4)))
  (check '((("") 0 0) "Editor" 240 80)
         (list (editor-state editor) (clara.windows:window-title (clara.editor::editor-window editor))
               (clara.draw:surface-width (clara.editor::editor-surface editor))
               (clara.draw:surface-height (clara.editor::editor-surface editor))))
  (check '(0 0 "Ctrl-S saves, Ctrl-O opens a file, Ctrl-E evaluates, Ctrl-Q closes")
         (list (editor-wrong editor) (wrong-pixels) (clara.editor::editor-message editor)))
  (keys editor "ab")
  (check '((("ab") 0 2) " a text with no file yet, not " nil 0)       ; the words, cut to the row
         (list (editor-state editor) (clara.editor::status editor) (clara.editor::editor-message editor)
               (editor-wrong editor)))
  ;; Enter in the middle of a line makes two of it, and the new one begins
  ;; as far in as the one it came from, up to where the cursor was.
  (keys editor clara.input:+home+ "  " clara.input:+end+ clara.input:+left+ 10)
  (check '(("  a" "  b") 1 2) (editor-state editor))
  (keys editor clara.input:+home+ " " clara.input:+home+ 10)
  (check '(("  a" "" "   b") 2 0) (editor-state editor))
  ;; Backspace at the start of a line joins it to the one above, and Delete
  ;; at the end of one joins the next to it.
  (keys editor 8 8)
  (check '(("  a   b") 0 3) (editor-state editor))
  (keys editor 127 127 127)
  (check '(("  ab") 0 3) (editor-state editor))
  (keys editor 10 clara.input:+up+ clara.input:+end+ 127)
  (check '(("  a  b") 0 3) (editor-state editor))
  ;; The arrows go round the ends of the lines, and stop at those of the text.
  (keys editor clara.input:+home+ 11 "ab" 10 "cd" clara.input:+home+ clara.input:+left+)
  (check '(("ab" "cd") 0 2) (editor-state editor))
  (keys editor clara.input:+right+ clara.input:+right+)
  (check '(("ab" "cd") 1 1) (editor-state editor))
  (keys editor clara.input:+down+ clara.input:+down+ clara.input:+end+ clara.input:+right+)
  (check '(("ab" "cd") 1 2) (editor-state editor))
  (keys editor clara.input:+up+ clara.input:+up+ clara.input:+home+ clara.input:+left+ clara.input:+up+)
  (check '(("ab" "cd") 0 0) (editor-state editor))
  ;; A tab is spaces up to the next column that is a multiple of eight.
  (keys editor clara.input:+right+ 9 "x" 9)
  (check '("a       x       b" 16 0)
         (list (clara.editor::editor-line editor) (clara.editor::editor-column editor) (editor-wrong editor)))
  ;; A key that is no character and none of the editor's does nothing.
  (let ((state (editor-state editor)))
    (keys editor clara.input:+insert+ clara.input:+f1+ 27 1 (+ clara.input:+alt+ 97))
    (check state (editor-state editor)))
  (clara.windows:close-window (clara.editor::editor-window editor)))

(let ((editor (clara.editor::open-editor nil :columns 30 :rows 4)))
  (keys editor "one" 10 "two" 10 "three")
  (check '((("one" "two" "three") 2 5) t) (list (editor-state editor) (clara.editor::editor-changed editor)))
  ;; Ctrl-K takes the rest of the line, then the end of the line, and what
  ;; it took in a row comes back with Ctrl-Y, as often as is asked. At the
  ;; end of the text it takes nothing, and what it has stays.
  (keys editor clara.input:+up+ clara.input:+home+ clara.input:+right+ 11)
  (check '("t" "wo") (list (clara.editor::editor-line editor) (clara.editor::editor-cut editor)))
  (keys editor 11 11)
  (check (list '(("one" "t") 1 1) (format nil "wo~%three")) (list (editor-state editor) (clara.editor::editor-cut editor)))
  (keys editor 11 clara.input:+end+ 11)
  (check (list '(("one" "t") 1 1) (format nil "wo~%three")) (list (editor-state editor) (clara.editor::editor-cut editor)))
  (keys editor 25)
  (check '(("one" "two" "three") 2 5) (editor-state editor))
  (keys editor clara.input:+up+ clara.input:+up+ clara.input:+home+ 25)
  (check '(("wo" "threeone" "two" "three") 1 5) (editor-state editor))
  (keys editor clara.input:+home+ 11 clara.input:+down+ 11)                  ; a key in between, and it begins afresh
  (check '((("wo" "" "" "three") 2 0) "two") (list (editor-state editor) (clara.editor::editor-cut editor)))
  ;; A click puts the cursor on the character it is on, or at the end of
  ;; its line; a button that comes up does nothing, and neither does a
  ;; click on the status row.
  (clara.editor::point editor 17 5 1)
  (check '(0 2) (cdr (editor-state editor)))
  (clara.editor::point editor 200 53 1)
  (check '(3 5) (cdr (editor-state editor)))
  (clara.editor::point editor 0 20 1)
  (check '(1 0) (cdr (editor-state editor)))
  (clara.editor::point editor 100 5 0)
  (clara.editor::point editor 100 70 1)
  (check '(1 0 0 0) (append (cdr (editor-state editor)) (list (editor-wrong editor) (wrong-pixels))))
  (clara.editor::go-to editor 99 99)                                         ; as near as there is a line, and a column
  (check '(3 5) (cdr (editor-state editor)))
  ;; The window follows the cursor: down past its last row and up again,
  ;; and along a line that is longer than it is wide.
  (keys editor 10 "five" 10 "six")
  (check '(5 0 2) (list (clara.editor::editor-row editor) (editor-wrong editor) (clara.editor::editor-top editor)))
  (keys editor clara.input:+page-up+)
  (check '(2 0 2) (list (clara.editor::editor-row editor) (editor-wrong editor) (clara.editor::editor-top editor)))
  (keys editor clara.input:+up+ clara.input:+up+ clara.input:+up+)
  (check '(0 0 0) (list (clara.editor::editor-row editor) (editor-wrong editor) (clara.editor::editor-top editor)))
  (keys editor clara.input:+page-down+ clara.input:+page-down+ clara.input:+end+ " is a line of more than thirty characters")
  (check '(5 44 0 2 15)
         (list (clara.editor::editor-row editor) (clara.editor::editor-column editor) (editor-wrong editor)
               (clara.editor::editor-top editor) (clara.editor::editor-left editor)))
  (keys editor clara.input:+home+)
  (check '(0 0 0) (list (editor-wrong editor) (clara.editor::editor-left editor) (wrong-pixels)))
  (clara.windows:close-window (clara.editor::editor-window editor)))

;; The same keys to the editor and to one that is written here, a few
;; hundred of them as they come: the two have the same text, the cursor at
;; the same place and the same lines in the window, and every cell of the
;; window shows it.
(defstruct ref (lines (list "")) (row 0) (column 0) (cut "") cutting (top 0) (left 0))

(defun ref-line (ref)
  (nth (ref-row ref) (ref-lines ref)))

(defun ref-put (ref &rest lines)       ; in place of the cursor's line
  (setf (ref-lines ref) (append (subseq (ref-lines ref) 0 (ref-row ref)) lines (nthcdr (1+ (ref-row ref)) (ref-lines ref)))))

(defun ref-join (ref)                  ; the cursor's line and the next are one
  (let ((next (nth (1+ (ref-row ref)) (ref-lines ref))))
    (setf (ref-lines ref) (append (subseq (ref-lines ref) 0 (ref-row ref))
                                  (list (concatenate 'string (ref-line ref) next))
                                  (nthcdr (+ 2 (ref-row ref)) (ref-lines ref))))))

(defun ref-insert (ref text)
  (loop for character across text
        do (let ((line (ref-line ref)) (column (ref-column ref)))
             (cond ((char= character #\Newline)
                    (ref-put ref (subseq line 0 column) (subseq line column))
                    (incf (ref-row ref))
                    (setf (ref-column ref) 0))
                   (t
                    (ref-put ref (concatenate 'string (subseq line 0 column) (string character) (subseq line column)))
                    (incf (ref-column ref)))))))

(defun ref-key (ref code rows)
  (let* ((cutting (ref-cutting ref)) (line (ref-line ref)) (row (ref-row ref)) (column (ref-column ref))
         (last (1- (length (ref-lines ref)))))
    (setf (ref-cutting ref) nil)
    (flet ((clamp ()
             (setf (ref-column ref) (min (ref-column ref) (length (ref-line ref))))))
      (cond ((= code 10)
             (let ((indent (or (position #\Space line :test-not #'char= :end column) column)))
               (ref-insert ref (string #\Newline))
               (ref-insert ref (make-string indent :initial-element #\Space))))
            ((= code 8)
             (cond ((plusp column)
                    (ref-put ref (concatenate 'string (subseq line 0 (1- column)) (subseq line column)))
                    (decf (ref-column ref)))
                   ((plusp row)
                    (decf (ref-row ref))
                    (setf (ref-column ref) (length (ref-line ref)))
                    (ref-join ref))))
            ((= code 127)
             (cond ((< column (length line))
                    (ref-put ref (concatenate 'string (subseq line 0 column) (subseq line (1+ column)))))
                   ((< row last) (ref-join ref))))
            ((= code 9) (ref-insert ref (make-string (- 8 (mod column 8)) :initial-element #\Space)))
            ((= code clara.input:+up+) (when (plusp row) (decf (ref-row ref)) (clamp)))
            ((= code clara.input:+down+) (when (< row last) (incf (ref-row ref)) (clamp)))
            ((= code clara.input:+left+)
             (cond ((plusp column) (decf (ref-column ref)))
                   ((plusp row) (decf (ref-row ref)) (setf (ref-column ref) (length (ref-line ref))))))
            ((= code clara.input:+right+)
             (cond ((< column (length line)) (incf (ref-column ref)))
                   ((< row last) (incf (ref-row ref)) (setf (ref-column ref) 0))))
            ((= code clara.input:+home+) (setf (ref-column ref) 0))
            ((= code clara.input:+end+) (setf (ref-column ref) (length line)))
            ((= code clara.input:+page-up+) (dotimes (i (1- rows)) (ref-key ref clara.input:+up+ rows)))
            ((= code clara.input:+page-down+) (dotimes (i (1- rows)) (ref-key ref clara.input:+down+ rows)))
            ((= code 11)
             (let ((taken (cond ((< column (length line)) (ref-put ref (subseq line 0 column)) (subseq line column))
                                ((< row last) (ref-join ref) (string #\Newline)))))
               (when taken
                 (setf (ref-cut ref) (if cutting (concatenate 'string (ref-cut ref) taken) taken)
                       (ref-cutting ref) t))))
            ((= code 25) (ref-insert ref (ref-cut ref)))
            ((<= 32 code 126) (ref-insert ref (string (code-char code))))))))

;; Where the window is after it was drawn: it moves as little as shows the cursor.
(defun ref-view (ref rows columns)
  (cond ((< (ref-row ref) (ref-top ref)) (setf (ref-top ref) (ref-row ref)))
        ((>= (ref-row ref) (+ (ref-top ref) rows)) (setf (ref-top ref) (- (ref-row ref) rows -1))))
  (cond ((< (ref-column ref) (ref-left ref)) (setf (ref-left ref) (ref-column ref)))
        ((>= (ref-column ref) (+ (ref-left ref) columns)) (setf (ref-left ref) (- (ref-column ref) columns -1)))))

(let ((editor (clara.editor::open-editor nil :columns 12 :rows 5 :x 20 :y 60))
      (ref (make-ref)) (state (sb-ext:seed-random-state 13)) (apart 0) (wrong 0) (pixels 0) (most 0))
  (dotimes (step 700)
    (let* ((n (random 100 state))
           (code (cond ((< n 34) (char-code (char "abcde ()" (random 8 state))))
                       ((< n 45) 10)
                       ((< n 53) 8)
                       ((< n 58) 127)
                       ((< n 60) 9)
                       ((< n 66) clara.input:+up+)
                       ((< n 72) clara.input:+down+)
                       ((< n 78) clara.input:+left+)
                       ((< n 84) clara.input:+right+)
                       ((< n 86) clara.input:+home+)
                       ((< n 88) clara.input:+end+)
                       ((< n 91) clara.input:+page-up+)
                       ((< n 94) clara.input:+page-down+)
                       ((< n 97) 11)
                       (t 25))))
      (clara.editor::key editor code)
      (ref-key ref code 5)
      (unless (zerop (editor-wrong editor))     ; which draws it
        (incf wrong))
      (ref-view ref 5 12)
      (unless (equal (list (ref-lines ref) (ref-row ref) (ref-column ref) (ref-cut ref) (ref-top ref) (ref-left ref))
                     (append (editor-state editor)
                             (list (clara.editor::editor-cut editor) (clara.editor::editor-top editor)
                                   (clara.editor::editor-left editor))))
        (incf apart))
      (setq most (max most (length (ref-lines ref))))
      (when (zerop (mod step 50))
        (unless (eql (wrong-pixels) 0)
          (incf pixels)))))
  (check '(0 0 0 t) (list apart wrong pixels (> most 12)))
  (clara.windows:close-window (clara.editor::editor-window editor)))

;; The text of a file, read whole: after its last line comes one with
;; nothing in it, where the text ends, and saving writes every line but
;; that one. So a file comes back as it was, and a text with nothing in it
;; is a file with nothing in it.
(let* ((poem (write-scratch "poem.txt" "roses" "  violets" ""))
       (editor (clara.editor::open-editor poem :columns 90 :rows 4)))
  (check (list '(("roses" "  violets" "" "") 0 0) poem nil "3 lines" poem 0)
         (list (editor-state editor) (clara.editor::editor-name editor) (clara.editor::editor-changed editor)
               (clara.editor::editor-message editor) (clara.windows:window-title (clara.editor::editor-window editor))
               (editor-wrong editor)))
  (keys editor 19)                                                           ; saved as it came
  (check (list (format nil "roses~%  violets~%~%") "saved, 3 lines") (list (scratch-text "poem.txt") (clara.editor::editor-message editor)))
  (keys editor "red ")
  ;; The status: which file, that it has changed, and where the cursor is.
  (let ((words (concatenate 'string poem ", not saved")) (place "line 1, column 5 "))
    (check (list (concatenate 'string " " words (make-string (- 89 (length words) (length place)) :initial-element #\Space) place) 0)
           (list (clara.editor::status editor) (editor-wrong editor))))
  (keys editor 19)
  (check (list (format nil "red roses~%  violets~%~%") nil "saved, 3 lines" 0)
         (list (scratch-text "poem.txt") (clara.editor::editor-changed editor) (clara.editor::editor-message editor)
               (editor-wrong editor)))
  (keys editor clara.input:+page-down+ "end" 19)                             ; a last line with something in it gets its end
  (check (list (format nil "red roses~%  violets~%~%end~%") "saved, 4 lines")
         (list (scratch-text "poem.txt") (clara.editor::editor-message editor)))
  (clara.windows:close-window (clara.editor::editor-window editor)))
(let ((editor (clara.editor::open-editor (scratch "empty.txt") :columns 70 :rows 3)))
  (check '((("") 0 0) "a new file: Ctrl-S makes it" nil nil)                 ; a file that is not there yet
         (list (editor-state editor) (clara.editor::editor-message editor) (clara.editor::editor-changed editor)
               (probe-file (scratch "empty.txt"))))
  (keys editor 19)
  (check '("" "saved, 0 lines") (list (scratch-text "empty.txt") (clara.editor::editor-message editor)))
  (keys editor "x" 19)
  (check (format nil "x~%") (scratch-text "empty.txt"))
  (clara.windows:close-window (clara.editor::editor-window editor)))
(let ((editor (clara.editor::open-editor (scratch "empty.txt") :columns 70 :rows 3)))
  (check '((("x" "") 0 0) "1 lines") (list (editor-state editor) (clara.editor::editor-message editor)))
  (clara.windows:close-window (clara.editor::editor-window editor)))
;; An editor that is opened on what cannot be read, a directory for one,
;; says so, and is an editor with no file: its window is not named after it.
(let ((editor (clara.editor::open-editor *scratch* :columns 70 :rows 3)))
  (check '((("") 0 0) t nil nil "Editor" 0)
         (list (editor-state editor) (stringp (clara.editor::editor-message editor)) (clara.editor::editor-name editor)
               (clara.editor::editor-changed editor) (clara.windows:window-title (clara.editor::editor-window editor))
               (editor-wrong editor)))
  (clara.windows:close-window (clara.editor::editor-window editor)))

;; A question in the status row: a text that has no file is asked for a
;; name when it is saved. What is typed then is the answer, Backspace takes
;; a character of it back, Enter hands it over, and Escape gives it up.
(let ((editor (clara.editor::open-editor nil :columns 70 :rows 3)) (note (scratch "note.txt")))
  (flet ((asked ()
           (list (car (clara.editor::editor-asking editor)) (clara.editor::editor-answer editor) (editor-wrong editor))))
    (keys editor "note" 19)
    (check '("Save as: " "" 0) (asked))
    (keys editor "xyz" 8 clara.input:+up+ 9 1)
    (check '("Save as: " "xy" 0) (asked))
    (keys editor 8 8 8 10)                                                   ; no answer: nothing is saved, or tried
    (check '((nil "" 0) (("note") 0 4) t nil nil)
           (list (asked) (editor-state editor) (clara.editor::editor-changed editor) (clara.editor::editor-name editor)
                 (clara.editor::editor-message editor)))
    (keys editor 19 note 27)                                                 ; given up
    (check '(nil 0 nil nil)
           (list (car (asked)) (editor-wrong editor) (clara.editor::editor-name editor) (probe-file note)))
    (keys editor 19 note 10)
    (check (list nil note nil "saved, 1 lines" note (format nil "note~%") 0)
           (list (clara.editor::editor-asking editor) (clara.editor::editor-name editor) (clara.editor::editor-changed editor)
                 (clara.editor::editor-message editor) (clara.windows:window-title (clara.editor::editor-window editor))
                 (scratch-text "note.txt") (editor-wrong editor)))
    ;; Another file, in place of this text: refused once while the text is
    ;; not saved, and done when the key is typed again right after.
    (keys editor "s" 15)
    (check '(nil "the text is not saved: Ctrl-S saves it, and asking once more goes on without")
           (list (clara.editor::editor-asking editor) (clara.editor::editor-message editor)))
    (keys editor clara.input:+left+ 15)                                      ; a key in between: refused again
    (check nil (clara.editor::editor-asking editor))
    (keys editor 15)
    (check '("Open: " "" 0) (asked))
    (keys editor (scratch "poem.txt") 10)
    (check (list '(("red roses" "  violets" "" "end" "") 0 0) (scratch "poem.txt") nil "4 lines" (scratch "poem.txt") 0)
           (list (editor-state editor) (clara.editor::editor-name editor) (clara.editor::editor-changed editor)
                 (clara.editor::editor-message editor) (clara.windows:window-title (clara.editor::editor-window editor))
                 (editor-wrong editor)))
    ;; What cannot be read, a directory for one, is said, and the text stays.
    (keys editor 15 *scratch* 10)
    (check (list t '(("red roses" "  violets" "" "end" "") 0 0) (scratch "poem.txt") nil)
           (list (stringp (clara.editor::editor-message editor)) (editor-state editor) (clara.editor::editor-name editor)
                 (clara.editor::editor-asking editor)))
    ;; Closing: at once when the text is saved; refused once when it is not,
    ;; whether it is Ctrl-Q or the close box that asks.
    (keys editor 17)
    (check t (clara.editor::editor-done editor))
    (setf (clara.editor::editor-done editor) nil)
    (keys editor "!" 17)
    (check '(nil t) (list (clara.editor::editor-done editor) (stringp (clara.editor::editor-message editor))))
    (clara.editor::happened editor '(:close))
    (check t (clara.editor::editor-done editor))
    (setf (clara.editor::editor-done editor) nil)
    (clara.editor::happened editor '(:close))
    (clara.editor::happened editor (list :key clara.input:+down+))
    (clara.editor::happened editor '(:close))
    (check nil (clara.editor::editor-done editor))
    (clara.editor::happened editor '(:pointer 9 20 1))                       ; and a button is the pointer's
    (check '(1 1) (cdr (editor-state editor))))
  (clara.windows:close-window (clara.editor::editor-window editor)))

;; Ctrl-E evaluates the forms of the text, in order, as LOAD would: how
;; many there were is said; what goes wrong is said with the line that the
;; form begins on, where the cursor goes; and Ctrl-C stops them.
(defvar *evaluated* nil)
(let ((editor (clara.editor::open-editor nil :columns 70 :rows 4)))
  (flet ((said (prefix)
           (let ((message (clara.editor::editor-message editor)))
             (list (and (>= (length message) (length prefix)) (string= prefix message :end2 (length prefix)))
                   (clara.editor::editor-row editor) (clara.editor::editor-column editor)))))
    (keys editor "(setq clara.tests::*evaluated* (list 1" 10 "2))" 10 10 "  (push 3 clara.tests::*evaluated*) ; and a comment" 10 5)
    (check '("2 forms evaluated" (3 1 2) 0)
           (list (clara.editor::editor-message editor) *evaluated* (editor-wrong editor)))
    (keys editor "(car 5)" 5)
    (check '((t 4 0) (3 1 2)) (list (said "line 5: ") *evaluated*))
    (keys editor 11 "(list 1" 5)                                             ; a form that the text ends in the middle of
    (check '(t 4 0) (said "line 5: "))
    ;; The forms are read in COMMON-LISP-USER, whatever package the thread
    ;; is in that asks, until the text itself says IN-PACKAGE: which holds
    ;; for the rest of the text, and for nobody else.
    (keys editor 11 "(defvar *in-the-editor* (package-name *package*))" 10 "(in-package \"CLARA.TESTS\")" 10
          "(setq *evaluated* (package-name *package*))" 5)
    (check '("5 forms evaluated" "COMMON-LISP-USER" "CLARA.TESTS" "COMMON-LISP-USER" "CLARA.TESTS")
           (list (clara.editor::editor-message editor)
                 (symbol-value (find-symbol "*IN-THE-EDITOR*" "COMMON-LISP-USER")) *evaluated*
                 (package-name (sb-ext:symbol-global-value '*package*)) (package-name *package*)))
    (keys editor clara.input:+up+ clara.input:+up+ clara.input:+home+ 11 11 11 11 11)
    (keys editor 11 "(loop (sleep 0.01))")
    (let ((thread (clara:make-thread (lambda () (clara.editor::key editor 5)))))
      (check t (eventually (lambda () (equal (clara.editor::editor-message editor) "evaluating: Ctrl-C stops it"))))
      (clara.windows:key-typed 65)                                           ; any other key is nothing to it
      (sleep 0.05)
      (check t (clara:thread-alive-p thread))
      (clara.windows:key-typed 3)
      (clara:join-thread thread)
      (check '(t 4 0) (said "line 5: ")))
    ;; An editor that is stopped while its forms run takes them with it.
    (flet ((evaluating ()
             (find "evaluating" (clara:all-threads) :key #'clara:thread-name :test #'equal)))
      (let ((thread (clara:make-thread (lambda () (clara.editor::key editor 5)))))
        (check t (eventually (lambda ()
                               (and (evaluating) (clara:thread-alive-p (evaluating))
                                    (equal (clara.editor::editor-message editor) "evaluating: Ctrl-C stops it")))))
        (clara:destroy-thread thread)
        (check t (eventually (lambda () (and (not (clara:thread-alive-p thread)) (null (evaluating)))))))))
  (clara.windows:close-window (clara.editor::editor-window editor)))

;; The application, as the launcher runs it: in a thread of its own, with
;; what is typed and pointed at coming to it from the window manager.
(setq clara.windows::*applications* *defined-applications*)
(let* ((thread (clara.windows:launch "editor" (scratch "poem.txt") :columns 30 :rows 3))
       (window (clara.windows:focused-window))
       (face (clara.windows:window-surface window)))
  (check (list (scratch "poem.txt") 240 64 t)
         (list (clara.windows:window-title window) (clara.draw:surface-width face) (clara.draw:surface-height face)
               (clara:thread-alive-p thread)))
  (check t (eventually (lambda () (zerop (wrong-cells face '("red roses " "  violets ") (list (list 0 0 +ink+)))))))
  (type-text "big ")
  (check t (eventually (lambda () (zerop (wrong-cells face '("big red roses ") (list (list 0 4 +ink+)))))))
  (clara.windows:key-typed 19)
  (check t (eventually (lambda () (equal (scratch-text "poem.txt") (format nil "big red roses~%  violets~%~%end~%")))))
  (multiple-value-bind (x y) (clara.windows:window-position window)
    (click (+ x 34) (+ y 20))                                                ; the fifth cell of the second row
    (type-text "#")
    (check t (eventually (lambda () (zerop (wrong-cells face '("big red roses " "  vi#olets ") (list (list 1 5 +ink+)))))))
    (click (+ x 235) (- y 10))                                               ; the box, with the text not saved
    (check t (eventually (lambda () (row-shows-p face 3 " the text is not saved: Ctrl-S" +paper+ +ink+))))
    (check '(1 0) (list (length (clara.windows:windows)) (wrong-pixels)))
    (click (+ x 235) (- y 10)))                                              ; and once more
  (check t (eventually (lambda () (and (null (clara.windows:windows)) (not (clara:thread-alive-p thread))))))
  (check '(0 nil) (list (wrong-pixels) clara.windows::*made*)))

;;; The file browser. What a directory holds is asked of the language, and
;;; the language here is SBCL's, whose DIRECTORY gives pathnames of the
;;; host's: the tests put a function in its place that makes names of them,
;;; the way lisp/boot.lisp has them, and the directories are this run's own.

(defun host-names (place)
  (mapcar (lambda (path)
            (concatenate 'string place
                         (if (pathname-name path)
                             (file-namestring path)
                             (concatenate 'string (car (last (pathname-directory path))) "/"))))
          (directory (concatenate 'string place "*.*"))))

(setq clara.files::*names* #'host-names)
(defvar *shelf* (scratch "tree/"))
(write-scratch "tree/b.txt" "b")
(write-scratch "tree/a.txt" "first" "second")
(write-scratch "tree/sub/inner.txt" "inner")
(write-scratch "tree/Zed/z.txt" "z")
(dotimes (i 12)
  (write-scratch (format nil "tree/many/f~2,'0D" i) "x"))

(defun browser-state (browser)
  (list (clara.files::browser-names browser) (clara.files::browser-picked browser)))

;; The window of a browser against its list, after it was drawn: the names
;; from the first in the window on, the one that is picked with its colours
;; the other way round, and the status.
(defun browser-wrong (browser)
  (clara.files::render browser)
  (let ((names (clara.files::browser-names browser)) (top (clara.files::browser-top browser))
        (columns (clara.files::browser-columns browser)))
    (wrong-cells (clara.files::browser-surface browser)
                 (append (loop for r below (clara.files::browser-rows browser)
                               collect (let* ((name (nth (+ top r) names))
                                              (text (pad (if name (concatenate 'string " " name) "") columns)))
                                         (if (and name (= (+ top r) (clara.files::browser-picked browser))) (list text) text)))
                         (list (list (pad (concatenate 'string " " (clara.files::status browser)) columns)))))))

(defun browser-keys (browser &rest codes)
  (dolist (code codes)
    (clara.files::key browser code)))

(check '("/" "/" "/a/" "/clara/") (mapcar #'clara.files::parent '("/" "/clara/" "/a/b/" "/clara/apps/")))
(new-desk :width 300 :height 220)
(setq clara.windows::*applications* *defined-applications*)
(let ((browser (clara.files::open-browser *shelf* :columns 30 :rows 4)))
  ;; The directories first, in the order of their names whatever the case of
  ;; their letters, then the files, and before them all the way up.
  (check (list '(("../" "many/" "sub/" "Zed/" "a.txt" "b.txt") 0) *shelf* (concatenate 'string "Files in " *shelf*)
               "6 names" 240 80 0 0)               ; and no more, in a row of 30 cells
         (list (browser-state browser) (clara.files::browser-directory browser)
               (clara.windows:window-title (clara.files::browser-window browser)) (clara.files::status browser)
               (clara.draw:surface-width (clara.files::browser-surface browser))
               (clara.draw:surface-height (clara.files::browser-surface browser))
               (browser-wrong browser) (wrong-pixels)))
  ;; The keys that pick another name, which the window follows.
  (flet ((picked (&rest codes)
           (apply #'browser-keys browser codes)
           (list (clara.files::browser-picked browser) (browser-wrong browser) (clara.files::browser-top browser))))
    (check '(2 0 0) (picked clara.input:+down+ clara.input:+down+))
    (check '(1 0 0) (picked clara.input:+up+))
    (check '(0 0 0) (picked clara.input:+up+ clara.input:+up+))
    (check '(5 0 2) (picked clara.input:+end+))
    (check '(5 0 2) (picked clara.input:+down+))
    (check '(2 0 2) (picked clara.input:+page-up+))
    (check '(0 0 0) (picked clara.input:+page-up+))
    (check '(3 0 0) (picked clara.input:+page-down+))
    (check '(5 0 2) (picked clara.input:+page-down+))
    (check '(0 0 0) (picked clara.input:+home+))
    (check '(0 0 0) (picked 65 clara.input:+f1+ 27))                         ; and keys that are none of its own
    ;; Enter goes into the directory that is picked, and Backspace back to
    ;; the one it is in, with the one it came from picked there.
    (check '(1 0 0) (picked clara.input:+down+))
    (browser-keys browser 10)
    (check (list (concatenate 'string *shelf* "many/") (concatenate 'string "Files in " *shelf* "many/") 13 "../" "f00" 0 0)
           (list (clara.files::browser-directory browser) (clara.windows:window-title (clara.files::browser-window browser))
                 (length (clara.files::browser-names browser)) (first (clara.files::browser-names browser))
                 (second (clara.files::browser-names browser)) (clara.files::browser-picked browser)
                 (browser-wrong browser)))
    (check '(12 0 9) (picked clara.input:+end+))
    (browser-keys browser 8)
    (check (list *shelf* 1 0) (list (clara.files::browser-directory browser) (clara.files::browser-picked browser)
                                   (browser-wrong browser)))
    (browser-keys browser clara.input:+end+ clara.input:+up+ clara.input:+up+ 13)  ; Zed, by a carriage return
    (check '(("../" "z.txt") 0) (browser-state browser))
    (browser-keys browser 10)                                                ; the way up is a name like the others,
    (check (list *shelf* 3) (list (clara.files::browser-directory browser) (clara.files::browser-picked browser)))
    (browser-keys browser clara.input:+left+)                                ; and so is the arrow to the left
    (check (list *scratch* "tree/" 0)
           (list (clara.files::browser-directory browser)
                 (nth (clara.files::browser-picked browser) (clara.files::browser-names browser)) (browser-wrong browser)))
    (browser-keys browser 10)
    ;; A file is opened in the editor, which is launched for it.
    (browser-keys browser clara.input:+end+ clara.input:+up+ 10)
    (check (list (concatenate 'string *shelf* "a.txt") (concatenate 'string "Files in " *shelf*)) (titles))
    (let ((face (clara.windows:window-surface (clara.windows:focused-window))))
      (check t (eventually (lambda () (zerop (wrong-cells face '("first " "second ") (list (list 0 0 +ink+))))))))
    (clara.windows:key-typed 17)                                             ; Ctrl-Q, to the editor
    (check t (eventually (lambda () (= 1 (length (clara.windows:windows))))))
    ;; Delete asks, and deletes the file when the answer is y; a directory
    ;; is not deleted.
    (check '(4 0 1) (picked 127))
    (check (list (concatenate 'string "delete " *shelf* "a.txt? y deletes it") (concatenate 'string *shelf* "a.txt"))
           (list (clara.files::status browser) (clara.files::browser-doomed browser)))
    (browser-keys browser 110)                                               ; n, or any other key
    (check '(nil t) (list (clara.files::browser-doomed browser) (and (probe-file (concatenate 'string *shelf* "a.txt")) t)))
    (browser-keys browser 127 121)
    (check (list '(("../" "many/" "sub/" "Zed/" "b.txt") 4) nil (concatenate 'string "deleted " *shelf* "a.txt") 0)
           (list (browser-state browser) (probe-file (concatenate 'string *shelf* "a.txt"))
                 (clara.files::browser-message browser) (browser-wrong browser)))
    (browser-keys browser 127 89)                                            ; the last of the names goes: the one before is picked
    (check '(("../" "many/" "sub/" "Zed/") 3) (browser-state browser))
    (browser-keys browser 127)
    (check '("a directory is not deleted from here" nil 0)
           (list (clara.files::browser-message browser) (clara.files::browser-doomed browser) (browser-wrong browser)))
    ;; Ctrl-R reads the directory again, with the same name picked.
    (write-scratch "tree/new.txt" "new")
    (check '(("../" "many/" "sub/" "Zed/") 3) (browser-state browser))
    (browser-keys browser 18)
    (check '((("../" "many/" "sub/" "Zed/" "new.txt") 3) 0) (list (browser-state browser) (browser-wrong browser)))
    ;; A click picks the name it is on, and on the name that is picked
    ;; opens it; below the names, on the status and with a button that comes
    ;; up it does nothing.
    (clara.files::point browser 20 1)
    (check '(1 0) (list (clara.files::browser-picked browser) (browser-wrong browser)))
    (clara.files::point browser 60 1)
    (check 3 (clara.files::browser-picked browser))
    (clara.files::point browser 20 0)
    (clara.files::point browser 70 1)
    (check (list 3 *shelf*) (list (clara.files::browser-picked browser) (clara.files::browser-directory browser)))
    (clara.files::point browser 60 1)
    (check (list (concatenate 'string *shelf* "Zed/") '("../" "z.txt")) (list (clara.files::browser-directory browser) (clara.files::browser-names browser)))
    (clara.files::point browser 40 1)                                        ; two names, and this is the third row
    (check '(0 0) (list (clara.files::browser-picked browser) (browser-wrong browser)))
    ;; Closing, by the key and by the box.
    (browser-keys browser 17)
    (check t (clara.files::browser-done browser))
    (setf (clara.files::browser-done browser) nil)
    (clara.files::happened browser '(:close))
    (check t (clara.files::browser-done browser))
    (clara.files::happened browser (list :key clara.input:+down+))
    (clara.files::happened browser '(:pointer 5 4 1))
    (check 0 (clara.files::browser-picked browser)))
  (clara.windows:close-window (clara.files::browser-window browser)))
;; A name without the slash at its end is a directory's all the same; a
;; directory with nothing in it has the way up; and where nothing is listed
;; at all, or the file system fails, that is said.
(let ((browser (clara.files::open-browser (scratch "tree/sub"))))            ; as large as it is when nothing is said
  (check (list (scratch "tree/sub/") '("../" "inner.txt") 384 272 "2 names: Enter opens, Backspace goes up" 0)
         (list (clara.files::browser-directory browser) (clara.files::browser-names browser)
               (clara.draw:surface-width (clara.files::browser-surface browser))
               (clara.draw:surface-height (clara.files::browser-surface browser))
               (clara.files::status browser) (browser-wrong browser)))
  (clara.windows:close-window (clara.files::browser-window browser)))
(let ((clara.files::*names* (lambda (place) (declare (ignore place)) nil)))
  (let ((browser (clara.files::open-browser "/" :columns 30 :rows 2)))
    (check '((nil 0) "nothing here" 0) (list (browser-state browser) (clara.files::status browser) (browser-wrong browser)))
    (browser-keys browser 10 127 clara.input:+down+ 8)
    (clara.files::point browser 5 1)
    (check '((nil 0) "/" nil) (list (browser-state browser) (clara.files::browser-directory browser) (clara.files::browser-message browser)))
    (clara.windows:close-window (clara.files::browser-window browser))))
(let ((clara.files::*names* (lambda (place) (error "the disk of ~A does not answer" place))))
  (let ((browser (clara.files::open-browser "/" :columns 40 :rows 2)))
    (check '("the disk of / does not answer" 0) (list (clara.files::status browser) (browser-wrong browser)))
    (clara.windows:close-window (clara.files::browser-window browser))))

;; The application, as the launcher runs it, and the two together: a file
;; that is picked in the browser's window opens in a window of the editor's.
(let* ((thread (clara.windows:launch "files" *shelf* :columns 30 :rows 4))
       (window (clara.windows:focused-window))
       (face (clara.windows:window-surface window)))
  (check t (eventually (lambda () (zerop (wrong-cells face (list (list (pad " ../" 30)) " many/ " " sub/ " " Zed/ "))))))
  (dotimes (i 4)
    (clara.windows:key-typed clara.input:+down+))
  (check t (eventually (lambda () (zerop (wrong-cells face (list " many/ " " sub/ " " Zed/ " (list (pad " new.txt" 30))))))))
  (clara.windows:key-typed 10)
  (check t (eventually (lambda () (equal (titles) (list (concatenate 'string *shelf* "new.txt") (concatenate 'string "Files in " *shelf*))))))
  (check 0 (wrong-pixels))
  (clara.windows:key-typed (+ clara.input:+alt+ 9))                          ; back to the browser's window, by the keyboard
  (multiple-value-bind (x y) (clara.windows:window-position window)
    (click (+ x 235) (- y 10)))
  (check t (eventually (lambda () (not (clara:thread-alive-p thread)))))
  (check (list (concatenate 'string *shelf* "new.txt")) (titles))
  ;; Unloaded, the editor is stopped where it runs, and has no function
  ;; until its file is loaded again. Its package stays here, where the
  ;; tests loaded the file and not the launcher, whose file is one of
  ;; ClaraOS's own volume: so the tests give it its function back.
  (clara.windows:unload-application "Editor")
  (check '(nil t nil) (list (titles) (packagep (find-package "CLARA.EDITOR"))
                            (clara.windows::application-function (clara.windows::find-application "Editor")))))
(clara.windows:define-application "Editor" #'clara.editor:edit)
(clara.windows:stop)
(setq clara.files::*names* #'clara.files::names-in)
(sb-ext:delete-directory *scratch* :recursive t)
(check nil (probe-file *scratch*))


;;; The stand-ins themselves, as far as what is written for ClaraOS will
;;; lean on them: threads, a lock, an event, as the kernel's own self-test
;;; has them (kernel/lisp/lisp.c).

(check 3 (clara:join-thread (clara:make-thread (lambda () (+ 1 2)))))
(check '(1 2) (multiple-value-list (clara:join-thread (clara:make-thread (lambda () (values 1 2))))))
(check "worker" (clara:thread-name (clara:join-thread (clara:make-thread #'clara:current-thread :name "worker"))))
(check 300
       (let ((lock (clara:make-lock "total")) (total 0))
         (mapc #'clara:join-thread
               (mapcar (lambda (n)
                         (clara:make-thread
                          (lambda ()
                            (dotimes (i 50)
                              (clara:with-lock-held (lock)
                                (let ((old total))
                                  (clara:thread-yield)
                                  (setq total (+ old n))))))))
                       '(1 2 3)))
         total))
(check '(t t nil) (let ((event (clara:make-event)))
                    (clara:signal-event event 2)
                    (list (clara:wait-event event) (clara:wait-event event) (clara:wait-event event 20))))
(check '(1 2 3) (let* ((go (clara:make-event))
                       (threads (mapcar (lambda (n) (clara:make-thread (lambda () (clara:wait-event go) n)))
                                        '(1 2 3))))
                  (clara:signal-event go 3)
                  (mapcar #'clara:join-thread threads)))
;; A thread that fails says so where every thread writes, which is the
;; value that *STANDARD-OUTPUT* has outside every binding: not for this
;; run's output to show.
(let ((output (sb-ext:symbol-global-value '*standard-output*)))
  (setf (sb-ext:symbol-global-value '*standard-output*) (make-broadcast-stream))
  (unwind-protect
       (check-condition error (clara:join-thread (clara:make-thread (lambda () (error "in a thread")))))
    (setf (sb-ext:symbol-global-value '*standard-output*) output)))
(let* ((started (clara:make-event)) (cleaned nil)
       (thread (clara:make-thread (lambda ()
                                    (unwind-protect (progn (clara:signal-event started) (loop (sleep 0.01)))
                                      (setq cleaned t))))))
  (clara:wait-event started)
  (check t (clara:thread-alive-p thread))
  (clara:destroy-thread thread)
  (check-condition error (clara:join-thread thread))
  (check '(nil t) (list (clara:thread-alive-p thread) cleaned)))
(let ((thread (clara:make-thread (lambda () (loop (sleep 0.01))))))
  (clara:destroy-thread thread)               ; stopped, perhaps before it began
  (check-condition error (clara:join-thread thread))
  (check nil (clara:thread-alive-p thread)))
;; A thread that is stopped before it has begun, and that nobody waits for,
;; is gone all the same: closing a window stops its thread in that way, and
;; on a machine that is slow enough the thread has not yet had its turn.
(dotimes (i 200)
  (clara:destroy-thread (clara:make-thread (lambda () (loop (sleep 0.01))))))
(check t (eventually (lambda () (= (length (clara:all-threads)) 1))))
;; And one that is stopped a second time while it is ending.
(dotimes (i 200)
  (let ((thread (clara:make-thread (lambda () nil))))
    (clara:destroy-thread thread)
    (clara:destroy-thread thread)))
(check t (eventually (lambda () (= (length (clara:all-threads)) 1))))
(check 1 (length (clara:all-threads)))

(format t "host tests: ~D checks under ~A ~A, ~D failed~%"
        *checks* (lisp-implementation-type) (lisp-implementation-version) *failures*)
(sb-ext:exit :code (if (zerop *failures*) 0 1) :abort t)
