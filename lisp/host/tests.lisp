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

;; What the error says that FUNCTION ends in, or NIL when it ends in none.
(defun condition-text (function)
  (handler-case (progn (funcall function) nil)
    (error (condition) (princ-to-string condition))))

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
(load-source "lisp/random.lisp")
(load-source "lisp/net.lisp")
(load-source "lisp/listener.lisp")
(load-source "lisp/windows.lisp")
(load-source "lisp/terminal.lisp")
(load-source "lisp/system.lisp")
(load-source "lisp/tls.lisp")
(load-source "lisp/editor.lisp")               ; the two that the kernel leaves on the volume for the launcher to load
(load-source "lisp/files.lisp")
(defvar *defined-applications* clara.windows::*applications*) ; what the files defined, for the tests to put back
(defvar *defined-commands* clara.windows::*commands*)

;; What this system knows of where ClaraOS is published, and the key that
;; it holds a release against: an address that begins with https:// and
;; ends with a /, and the 64 digits of a key. The tests are then run by a
;; system that knows of neither, as one is that somebody builds for a
;; place of their own, and each says where it looks and with which key:
;; what is tested here asks nothing of the place that the system names.
(check '(t #\/ 64 t)
       (list (and (clara.net::secure-address-p clara.system:*releases*) t)
             (char clara.system:*releases* (1- (length clara.system:*releases*)))
             (length clara.system:*release-key*)
             (and (every (lambda (digit) (digit-char-p digit 16)) clara.system:*release-key*) t)))
(setq clara.system:*releases* nil
      clara.system:*release-key* nil)

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
                                  :sub-over :word :call-local))
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

;; What the translation gains by not pushing what is taken off again, by a
;; comparison and its jump as one, and by one way to the machine for a
;; function, is not to be lost without anybody noticing: the answers would
;; be the same. The code of FIB was 732 bytes for AArch64 and 828 for x86-64
;; before those, and is 560 and 660 with them.
(check '(t t)
       (let ((code (clara.compiler::generate
                    (clara.compiler::convert-function
                     'fib '(n) '((if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (clara.compiler::make-env)))))
         (mapcar (lambda (machine limit)
                   (let ((clara.native::*machine* machine))
                     (<= (* 4 (length (clara.native::assemble (clara.native::lower code)
                                                              (get machine 'clara.native::writer)
                                                              (get machine 'clara.native::unit))))
                         limit)))
                 '(:arm64 :x86-64) '(600 700))))

;; Everything that there is and that the machine still runs, translated
;; at once (TRANSLATE-ALL), which is how a kernel's world comes to run on
;; its processor. The kernel goes through its heap for that; here the
;; functions that were ever made are in a table, and for this one check the
;; table holds two, of which one is translated already.
(check '(1 0 t t 0)
       (let* ((clara.host::*codes* (make-hash-table :test 'eq))
              (slow (let ((clara.native:*translate* nil))
                      (clara.compiler::compile-lambda '(lambda (x) (lambda () (car x))) 'slow)))
              (quick (let ((clara.native:*translate* t))
                       (clara.compiler::compile-lambda '(lambda (x) (cdr x)) 'quick))))
         (list (length (clara.unsafe:untranslated-code))
               (clara.native:translate-all)
               (clara.native:translated-p slow)
               (clara.native:translated-p quick)
               (length (clara.unsafe:untranslated-code)))))

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
           ((:call-local l) "FA000094" "E8E3030000")
           ((:call-local l) :back "06FFFF97" "E813FCFFFF")
           ((:enter-local) "FD7BBFA9" "4883EC28")
           ((:leave-local) "FD7BC1A8" "4883C428")
           ((:return-local) "C0035FD6" "C3")
           ((:forget-local) "" "4883C408")
           ((:move :c :vsp) "E20314AA" "4989D8")
           ((:move :b :c) "E10302AA" "4C89C2")
           ((:move :a :b) "E00301AA" "4889D1")
           ((:move :b :a) "E10300AA" "4889CA")
           ((:move :a :f) "E0030AAA" "4C89D9")
           ((:move :a :nil) "E00317AA" "4889F9")
           ((:const :c 49) "220680D2" "41B831000000")
           ((:const :a 4) "800080D2" "B904000000")
           ((:const :b 2) "410080D2" "BA02000000")
           ((:word :c 42 l) "42059DD26200A0F20200C0F20200E0F2" "49B82AE8030000000000")
           ((:pop :b) "818E5FF8" "4883EB08488B13")
           ((:store :a :b 3) "203000F8" "48894A03")
           ((:store :a :e 21) "205101F8" "49894A15")
           ((:store :nil :locals 16) "B70A00F9" "48897E10")
           ((:store :a :locals 8) "A00600F9" "48894E08")
           ((:load :a :a 3) "003040F8" "488B4903")
           ((:load :a :a 19) "003041F8" "488B4913")
           ((:load :b :locals 8) "A10640F9" "488B5608")
           ((:load :a :consts 8) "C00640F9" "498B4E08")
           ((:load :a :locals -8) "A0825FF8" "488B4EF8")
           ((:sub-reg :a :b) "000001CB" "4829D1")
           ((:add-reg :a :b) "0000018B" "4801D1")
           ((:add :vsp -24) "946200D1" "4883C3E8")
           ((:jump-if :ne :a :nil l) "1F0017EB211F0054" "4839F90F85DF030000")
           ((:jump-if :eq :a :nil l) :back "1F0017EBA0E0FF54" "4839F90F840FFCFFFF")
           ((:jump-if :ge :a 4 l) "1F1000F12A1F0054" "4883F9040F8DDE030000")
           ((:jump-if :ne :a 4094 l) "1FF83FF1211F0054" "4881F9FE0F00000F85DB030000")
           ((:jump-if :eq :nil :nil l) "FF0217EB201F0054" "4839FF0F84DF030000")
           ((:jump-if :eq :a 15 l) "1F3C00F1201F0054" "4883F90F0F84DE030000")
           ((:jump-tag :a 1 l) :back "100840921F0600F180E0FF54" "89C883E00783F8010F840AFCFFFF")
           ((:call-c 304) "709A40F900023FD6" "41FF97300100004889C1")
           ((:call-c 320) "70A240F900023FD6" "41FF97400100004889C1")
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
  requests                 ; and the requests it was given, the last first: (type sector count)
  station                  ; of a network card: the six bytes of its address on the wire,
  wire                     ; a function that is given every frame it sends, as a vector of bytes,
  (hold 0)                 ; how many frames it keeps the pages of before it says that they are sent,
  flying                   ; and the ones it is keeping: (first-descriptor address)
  numbers                  ; of a device that makes numbers which nobody can guess: a function that gives the next one,
  few                      ; how many bytes it fills at most of what it is given,
  (asked 0))               ; and how often it was asked

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
;; to write when it is a read; and a byte for its answer. A request of the
;; type 4 is to put what the disk holds where it lasts: no sectors and no
;; memory, and only from a driver that asked whether the disk knows it.
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
          (unless (and (= (second header) 16) (not (logbitp 1 (third header)))
                       (= (second answer) 1) (logbitp 1 (third answer))
                       (if (= type 4)
                           (and (= (length buffers) 2) (= sector 0))
                           (and (>= (length buffers) 3) (plusp bytes) (zerop (mod bytes 512))
                                (every (lambda (buffer) (eq (logbitp 1 (third buffer)) (= type 0))) data))))
            (failed "the driver gave the disk a request that is not one: ~S" buffers))
          (when (and (= type 4) (not (logbitp 9 (first (vdev-wanted vdev)))))
            (failed "the driver asked a disk to flush that it had not asked whether it can"))
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
                ((= type 4))
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
          ((and (>= offset #x2000) (vdev-station vdev))
           ;; A network card's begin with its address on the wire, six bytes.
           (let ((value 0))
             (dotimes (i size value)
               (setq value (logior value (ash (or (nth (+ (- offset #x2000) i) (vdev-station vdev)) 0) (* 8 i)))))))
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
           (when (and (= value 0) (vdev-numbers vdev))
             (serve-numbers vdev))
           (when (= value 1)
             (let ((vq (aref (vdev-queues vdev) 1)))
               (loop
                 (let ((first (next-available vq)))
                   (unless first
                     (return))
                   (cond ((vdev-station vdev)
                          ;; A card has the pages of a frame until it says that the frame is sent, which
                          ;; it may say late: the driver must not have written into them again by then.
                          (let ((address (first (car (chain vq first)))))
                            (when (find address (vdev-flying vdev) :key #'second)
                              (failed "the driver gave the network card a page to send from that the card still has"))
                            (send-on-wire vdev (chain vq first))
                            (setf (vdev-flying vdev) (append (vdev-flying vdev) (list (list first address))))
                            (loop while (> (length (vdev-flying vdev)) (vdev-hold vdev))
                                  do (complete vdev vq (first (pop (vdev-flying vdev))) 0))))
                         (t
                          (complete vdev vq first
                                    (reduce #'+ (mapcar (lambda (buffer) (if (logbitp 1 (third buffer)) (second buffer) 0))
                                                        (chain vq first)))))))))))
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

;; What a network card was given to send: the bytes of the buffers of a
;; chain, which the card only reads, without the twelve bytes that virtio
;; has before a frame, which have to be zero from a driver that asked the
;; card to work nothing out for it. The frame goes to whatever is at the
;; other end of the wire.
(defun send-on-wire (vdev buffers)
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer t)))
    (dolist (buffer buffers)
      (when (logbitp 1 (third buffer))
        (failed "the driver gave the network card a buffer to write into where it sends: ~S" buffers))
      (let ((index (clara.host::memory-index (first buffer) (second buffer))))
        (when (find 0 clara.host::*pages* :start (floor index 4096) :end (ceiling (+ index (second buffer)) 4096))
          (failed "the driver gave the network card ~D bytes of memory at #x~X that are not all its own"
                  (second buffer) (first buffer)))
        (dotimes (i (second buffer))
          (vector-push-extend (aref clara.host::*memory* (+ index i)) bytes))))
    (cond ((< (length bytes) 72)
           (failed "the driver sent a frame of ~D bytes, and one is sixty at least, after twelve of virtio's" (- (length bytes) 12)))
          ((> (length bytes) 1526)
           (failed "the driver sent a frame of ~D bytes, which is more than the wire takes" (- (length bytes) 12)))
          ((find-if #'plusp bytes :end 12)
           (failed "the driver sent a frame with something in the twelve bytes before it: ~S" (subseq bytes 0 12)))
          ((vdev-wire vdev)
           (funcall (vdev-wire vdev) (subseq bytes 12))))))

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

;; A network card, with an address on the wire. Bit 5 of what it can do
;; says that it has one.
(defun add-net (slot station &key (offers (list 32 1)))
  (add-virtio slot #x1041 #x020000 (make-vdev :station station :offers offers)))

;; A frame arrives at a network card: into the next page that the driver
;; gave it for that, after twelve bytes of virtio's. NIL when the driver
;; has left it none.
(defun arrive-on-wire (vdev frame)
  (let* ((vq (aref (vdev-queues vdev) 0)) (first (next-available vq)))
    (when first
      (let ((buffer (car (chain vq first))))
        (unless (and (>= (second buffer) (+ 12 (length frame))) (logbitp 1 (third buffer)))
          (failed "the driver gave the network card a buffer of ~D bytes with the flags ~D for a frame of ~D"
                  (second buffer) (third buffer) (length frame)))
        (let ((index (clara.host::memory-index (first buffer) (+ 12 (length frame)))))
          (fill clara.host::*memory* 0 :start index :end (+ index 12))
          (replace clara.host::*memory* frame :start1 (+ index 12)))
        (complete vdev vq first (+ 12 (length frame)))
        t))))

;; A device that makes numbers which nobody can guess serves what is in
;; its queue: a buffer for it to write into, of which it fills as much as
;; it likes, here all of it unless a test says how little.
(defun serve-numbers (vdev)
  (let ((vq (aref (vdev-queues vdev) 0)))
    (loop
      (let ((first (next-available vq)))
        (unless first
          (return))
        (let* ((buffers (chain vq first)) (buffer (car buffers)))
          (unless (and (= (length buffers) 1) (logbitp 1 (third buffer)) (<= 1 (second buffer) 4096))
            (failed "the driver gave the device that makes numbers a request that is not one: ~S" buffers))
          (let ((index (clara.host::memory-index (first buffer) (second buffer))))
            (when (find 0 clara.host::*pages* :start (floor index 4096) :end (ceiling (+ index (second buffer)) 4096))
              (failed "the driver gave the device that makes numbers memory that is not all its own"))
            (incf (vdev-asked vdev))
            (let ((count (min (second buffer) (or (vdev-few vdev) (second buffer)))))
              (dotimes (i count)
                (setf (aref clara.host::*memory* (+ index i)) (funcall (vdev-numbers vdev))))
              (unless (vdev-silent vdev)
                (complete vdev vq first count)))))))))

;; Such a device. Its numbers here are made by a rule, so that a test that
;; fails fails again: each is the last one times a number plus another.
(defun add-numbers (slot &key few silent mute (offers (list 0 1)))
  (let ((state (+ 12345 slot)))
    (add-virtio slot #x1044 #xff0000
                (make-vdev :numbers (lambda ()
                                      (setq state (logand #xffffffff (+ (* state 1103515245) 12345)))
                                      (ldb (byte 8 16) state))
                           :few few :silent silent :mute mute :offers offers))))

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
  (check '(512 1) (vdev-wanted vdev))                     ; of all that it offers, version 1 and the flush
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
  ;; What was written is put where it lasts: a request without sectors.
  (check '(t (4 0 0)) (list (clara.disk:flush disk) (car (vdev-requests vdev))))
  (pop (vdev-requests vdev))
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
  (check '(544 1) (vdev-wanted vdev))
  (check t (clara.disk:disk-read-only disk))
  (check-condition error (clara.disk:write-sectors disk 0 1 memory))
  (check '(nil nil) (list (clara.disk:flush disk) (vdev-requests vdev))) ; nothing was written that could be held back
  (check 1 (clara.disk:read-sectors disk 4095 1 memory)))

;; A disk that does not say that it knows how to flush holds nothing back,
;; and is not asked to. One that fails at it is an error. And a disk that a
;; variable has kept from an earlier start is not asked anything: its queue
;; and its page frame were that start's.
(let* ((vdevs (new-disks (list 3 (pattern 16) :offers (list #x6c54 1)) (list 4 (pattern 16))))
       (disks (progn (said-by #'clara.disk:start) (clara.disk:disks)))
       (memory (clara.unsafe:allocate-memory 1)))
  (check '((0 1) nil nil) (list (vdev-wanted (first vdevs)) (clara.disk:flush (first disks)) (vdev-requests (first vdevs))))
  (setf (vdev-answer (second vdevs)) 1)
  (check "the disk 00:04.0 could not put what it holds where it lasts: its answer is 1"
         (handler-case (clara.disk:flush (second disks)) (error (c) (princ-to-string c))))
  (setf (vdev-answer (second vdevs)) 0)
  (check t (clara.disk:flush (second disks)))
  (new-disks (list 3 (pattern 16)))
  (said-by #'clara.disk:start)
  (check "the disk 00:04.0 is from an earlier start; (clara.disk:disks) has this start's"
         (handler-case (clara.disk:read-sectors (second disks) 0 1 memory) (error (c) (princ-to-string c))))
  (check-condition error (clara.disk:write-sectors (first disks) 0 1 memory))
  (check-condition error (clara.disk:flush (second disks)))
  (check 1 (clara.disk:read-sectors (car (clara.disk:disks)) 0 1 (clara.unsafe:allocate-memory 1))))

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
       (disk (make-disk :old (cons 63 first) (cons 8000 second)))
       (said (start-files disk)))
  (check (format nil "files: a FAT12 volume of 1 MiB on the disk 00:03.0, from its sector 63 on~%~
                      files: a FAT16 volume of 2 MiB on the disk 00:03.0, from its sector 8000 on~%~
                      files: names are looked up on the first of these volumes~%")
         said)
  (check '("first.txt") (clara.fat:names "/"))
  (let ((clara.fat:*volume* (second (clara.fat:volumes))))
    (check "on the second" (text-of-file "/second.txt")))
  ;; A volume that a variable keeps while the machine is started again, as
  ;; a world that was saved is, is none of the volumes that are found then:
  ;; it knows a disk and a page frame that are no longer its own, and no
  ;; name is looked up on it, to read or to write. Nor on what is no volume.
  (let ((kept (second (clara.fat:volumes)))
        (earlier "the volume in CLARA.FAT:*VOLUME* is from an earlier start; (clara.fat:volumes) has this start's"))
    (start-files disk)
    (check '(2 nil) (list (length (clara.fat:volumes)) (and (member kept (clara.fat:volumes)) t)))
    (let ((clara.fat:*volume* kept))
      (check (list :error earlier) (text-of-file "/second.txt"))
      (check (list :error earlier) (handler-case (clara.fat:names "/") (error (c) (list :error (princ-to-string c)))))
      (check-condition error (clara.fat:entries "/"))
      (check-condition error (clara.fat:read-file "/second.txt"))
      (check-condition error (clara.fat:write-file "/new.txt" 0 0))
      (check-condition error (clara.fat:remove-file "/second.txt")))
    (let ((clara.fat:*volume* "second"))
      (check '(:error "CLARA.FAT:*VOLUME* holds \"second\", which is no volume: (clara.fat:volumes) has them")
             (text-of-file "/second.txt"))
      (check-condition error (clara.fat:names "/"))
      (check-condition error (clara.fat:write-file "/new.txt" 0 0)))
    (let ((clara.fat:*volume* (second (clara.fat:volumes))))
      (check '("second.txt") (clara.fat:names "/"))
      (check "on the second" (text-of-file "/second.txt")))))
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
             (walk (records path &optional own above)
               (let ((parts nil) (ended nil) (names nil) (shorts nil))
                 ;; A directory that begins with an entry for itself has one for the directory it is in
                 ;; after it, and each leads where it says: to its own first cluster, and to the other's,
                 ;; or to none when that is the root.
                 (when (and own (>= (length records) 64) (string= (short-of (subseq records 0 32)) "."))
                   (flet ((leads (at) (+ (le records (+ at 26) 2) (if (= kind 32) (ash (le records (+ at 20) 2) 16) 0))))
                     (unless (and (logbitp 4 (aref records 11)) (= (leads 0) own)
                                  (string= (short-of (subseq records 32 64)) "..") (logbitp 4 (aref records 43))
                                  (= (leads 32) above))
                       (problem "the directory ~A does not begin with entries for itself and for the one it is in" path))))
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
                                          (walk (bytes-of (clusters-of cluster whole)) whole cluster (or own 0)))
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

;; Directories that are made: on volumes of every kind, at the root and
;; inside another, by a name that is short and by one that is not. What is
;; written is a volume in order, with the directory there, empty, and
;; beginning with its two entries; a file goes into it and comes back; and
;; it is taken away again when nothing is left in it, after which as many
;; bytes are free as before.
(dolist (kind '(12 16 32))
  (let ((disk (fat-bytes (make-fat-volume kind *clean-tree* :cluster-sectors (if (= kind 32) 1 2) :information t))))
    (start-files disk)
    (let ((free (clara.fat:free-bytes)) (pages (clara.host:allocated-pages)))
      (check '("/letters" "/letters/a directory with a long name" "/clara/inner/")
             (list (clara.fat:make-directory "/letters")
                   (clara.fat:make-directory "/letters/a directory with a long name")
                   (clara.fat:make-directory "/clara/inner/")))
      (check '(("a directory with a long name/") nil nil)
             (list (clara.fat:names "/letters") (clara.fat:names "/letters/a directory with a long name")
                   (clara.fat:names "/clara/inner")))
      (check t (clara.fat:entry-directory-p (find "letters" (clara.fat:entries "/") :key #'clara.fat:entry-name
                                                                                     :test #'string-equal)))
      (put-text "/letters/a directory with a long name/first.txt" "in a directory that was made here")
      (check "in a directory that was made here" (text-of-file "/LETTERS/A Directory With A Long Name/first.txt"))
      (check (* 3 512 (if (= kind 32) 1 2)) (- free (clara.fat:free-bytes) (* 512 (if (= kind 32) 1 2))))
      (multiple-value-bind (files problems) (inspect-volume disk)
        (check nil problems)
        (check t (equalp (octets "in a directory that was made here")
                         (cdr (assoc "/letters/a directory with a long name/first.txt" files :test #'string=)))))
      ;; What is there already, of either kind, is not made a second time; and a directory goes
      ;; where there is one for it to be in.
      (check "there is /letters already" (condition-text (lambda () (clara.fat:make-directory "/letters"))))
      (check "there is /notes.txt already" (condition-text (lambda () (clara.fat:make-directory "/notes.txt"))))
      (check-condition error (clara.fat:make-directory "/nowhere/inside"))
      (check-condition error (clara.fat:make-directory "/letters/not: a name"))
      (check-condition error (clara.fat:make-directory "/"))
      ;; Taking one away: an empty one, and no other, and nothing that is a file.
      (check "the directory /letters is not empty" (condition-text (lambda () (clara.fat:remove-directory "/letters"))))
      (check "/notes.txt is a file, and not a directory"
             (condition-text (lambda () (clara.fat:remove-directory "/notes.txt"))))
      (check "there is no directory /nothing" (condition-text (lambda () (clara.fat:remove-directory "/nothing"))))
      (check-condition error (clara.fat:remove-file "/letters"))
      (clara.fat:remove-file "/letters/a directory with a long name/first.txt")
      (check '("/letters/a directory with a long name" "/letters" "/clara/inner")
             (list (clara.fat:remove-directory "/letters/a directory with a long name")
                   (clara.fat:remove-directory "/letters") (clara.fat:remove-directory "/clara/inner")))
      (check (list free pages nil) (list (clara.fat:free-bytes) (clara.host:allocated-pages)
                                         (nth-value 1 (inspect-volume disk))))
      (check t (equalp (inspect-volume disk) (sort (copy-list (tree-files *clean-tree*)) #'string< :key #'car))))))

;; A directory of the root that is full, on the kinds whose root is no file,
;; takes no directory more; and a volume without a cluster to spare none at all.
(let ((disk (fat-bytes (make-fat-volume 12 '(("only.txt" "x")) :clusters 3))))
  (start-files disk)
  (check 1024 (clara.fat:free-bytes))             ; two of its three clusters, the last among them
  (put-text "/one.txt" (make-string 512 :initial-element #\a))
  (put-text "/two.txt" (make-string 512 :initial-element #\b))
  (check 0 (clara.fat:free-bytes))
  (check-condition error (clara.fat:make-directory "/more"))
  (check nil (nth-value 1 (inspect-volume disk))))
(let ((disk (fat-bytes (make-fat-volume 12 (loop for i below 224 collect (list (format nil "F~D" i) "x"))))))
  (start-files disk)
  (let ((free (clara.fat:free-bytes)))
    (check "the directory of the root is full: it has 224 entries, and on a volume of this kind no more"
           (condition-text (lambda () (clara.fat:make-directory "/MORE"))))
    ;; The cluster that was to be the directory is nobody's again.
    (check (list free nil) (list (clara.fat:free-bytes) (nth-value 1 (inspect-volume disk))))))

;; A disk that stops while a directory is being made, at every request it
;; could stop at: what was there is there, and the directory is whole or
;; not there at all.
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
             (setq stopped (not (ignore-errors (clara.fat:make-directory "/clara/a directory that may not get made") t)))
             (setf (vdev-answer *disk*) 0
                   (vdev-watch *disk*) nil)
             (multiple-value-bind (files problems) (inspect-volume disk)
               (incf *checks*)
               (unless (and (every (lambda (problem)
                                     (or (search "are in no file, and not free" problem)
                                         (search "the copies of the table differ" problem)))
                                   problems)
                            (equalp files (sort (copy-list (tree-files *clean-tree*)) #'string< :key #'car))
                            (or stopped (null problems)))
                 (failed "a disk that stopped at request ~D of making a directory is left out of order: ~{~A~^; ~}"
                         request (or problems (list "its files are not what they were")))))))
  (check t (> request 4)))

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
;; Whoever wants to keep what was typed is told of every form that went
;; well, with the text it was read from and the package it was read in,
;; and of none that ended in an error or could not be read.
(let ((told nil))
  (let ((clara.listener:*record* (lambda (form text package)
                                   (push (list form (string-trim '(#\Space #\Newline) text) package) told))))
    (listen-to (format nil "(list 1~% 2) (car 5)~%(in-package \"COMMON-LISP-USER\")~%'told-in-it ) (list 3)~%"))
    (setq *package* (find-package "CLARA.TESTS")))
  (check (list (list '(list 1 2) (format nil "(list 1~% 2)") "CLARA.TESTS")
               (list '(in-package "COMMON-LISP-USER") "(in-package \"COMMON-LISP-USER\")" "CLARA.TESTS")
               (list ''cl-user::told-in-it "'told-in-it" "COMMON-LISP-USER"))
         (reverse told)))
(check '(t nil) (let ((well nil) (badly t))
                  (with-output-to-string (*standard-output*)
                    (setq well (clara.listener:answer '(+ 1 2))
                          badly (clara.listener:answer '(car 5))))
                  (list well badly)))
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
(defun new-desk (&key (width 200) (height 140) applications commands (start t) (machine t))
  (when machine
    (clara.host:reset-machine))
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
        clara.windows::*commands* commands
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

;; The launcher's list: the applications and under them the commands, with
;; a line across where the commands begin, when there are both.
(defun menu-rule (x y)
  (let* ((applications (clara.windows:applications))
         (names (append applications (clara.windows:commands)))
         (width (reduce #'max (mapcar (lambda (name) (+ 16 (* 8 (length name)))) names) :initial-value 112))
         (height (* 20 (length names))))
    (cond ((not (and clara.windows::*menu* (< -1 x width) (<= 20 y (+ 19 height)))) nil)
          ((or (= x 0) (= x (1- width)) (= y 20) (= y (+ 19 height))) +ink+)
          ((and applications (clara.windows:commands) (= y (+ 20 (* 20 (length applications))))) +ink+)
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

;; Commands: under the applications in the launcher's list, with a line
;; across where they begin. A click on one calls its function in a thread
;; of its own, which has the command's name, and nothing waits for it.
(defvar *commanded* nil)
(new-desk :applications (list (cons "One" (lambda () 'done)) (cons "The second of them" (lambda () 'done))
                              (cons "Quiet" (lambda () 'done))))
(check '("Do it" ("Do it"))
       (list (clara.windows:define-command "Do it" (lambda () (push (clara:thread-name (clara:current-thread)) *commanded*)))
             (clara.windows:commands)))
(check "Another" (clara.windows:define-command "Another" (lambda () (push 'another *commanded*))))
(clara.windows:pointer-moved 5 5 1)
(clara.windows:pointer-moved 5 5 0)
(check '(t 0) (list clara.windows::*menu* (wrong-pixels)))
(clara.windows:pointer-moved 20 85 1)          ; the fourth line: after three applications, the first command
(clara.windows:pointer-moved 20 85 0)
(check t (eventually (lambda () (equal *commanded* '("Do it")))))
(check '(nil 0) (list clara.windows::*menu* (wrong-pixels)))
(clara.windows:pointer-moved 5 5 1)
(clara.windows:pointer-moved 5 5 0)
(clara.windows:pointer-moved 20 119 1)         ; the last pixel of the last line
(clara.windows:pointer-moved 20 119 0)
(check t (eventually (lambda () (equal *commanded* '(another "Do it")))))
(clara.windows:pointer-moved 5 5 1)
(clara.windows:pointer-moved 5 5 0)
(clara.windows:pointer-moved 20 120 1)         ; and under it: nothing
(clara.windows:pointer-moved 20 120 0)
(check '(nil (another "Do it") 0) (list clara.windows::*menu* *commanded* (wrong-pixels)))
;; A name that is defined again, in letters of either case, keeps its place
;; and has the new function. One that is removed is gone from the list.
(check '("do it" ("Do it" "Another")) (list (clara.windows:define-command "do it" (lambda () (push 'again *commanded*)))
                                            (clara.windows:commands)))
(clara.windows:pointer-moved 5 5 1)
(clara.windows:pointer-moved 5 5 0)
(clara.windows:pointer-moved 20 85 1)
(clara.windows:pointer-moved 20 85 0)
(check t (eventually (lambda () (eq (car *commanded*) 'again))))
(clara.windows:pointer-moved 5 5 1)            ; the list is open while a command goes: it shuts, and is right after
(clara.windows:pointer-moved 5 5 0)
(check '("ANOTHER" ("Do it") nil 0)
       (list (clara.windows:remove-command "ANOTHER") (clara.windows:commands) clara.windows::*menu* (wrong-pixels)))
(check '("none of that name" ("Do it")) (list (clara.windows:remove-command "none of that name") (clara.windows:commands)))
(check-condition error (clara.windows:define-command 'name #'list))
;; Commands and no application: the button opens the list all the same,
;; and there is no line across it.
(new-desk :commands (list (cons "Alone" (lambda () (push 'alone *commanded*)))))
(clara.windows:pointer-moved 5 5 1)
(clara.windows:pointer-moved 5 5 0)
(check '(t 0) (list clara.windows::*menu* (wrong-pixels)))
(clara.windows:pointer-moved 20 30 1)
(clara.windows:pointer-moved 20 30 0)
(check t (eventually (lambda () (eq (car *commanded*) 'alone))))
(check '(nil 0) (list clara.windows::*menu* (wrong-pixels)))

;; What the windows' programs have not finished: each window that was given
;; a function for it is asked, and the ones that answer in words are
;; listed, the topmost first. A function that fails has nothing to say.
(let* ((says nil)
       (quiet (clara.windows:open-window "quiet" 40 20))
       (busy (clara.windows:open-window "busy" 40 20 :unfinished (lambda () says)))
       (broken (clara.windows:open-window "broken" 40 20 :unfinished (lambda () (error "it cannot say"))))
       (other (clara.windows:open-window "other" 40 20 :unfinished (lambda () "more of the same"))))
  (check (list (cons other "more of the same")) (clara.windows:unfinished))
  (setq says "a letter half written")
  (check (list (cons other "more of the same") (cons busy "a letter half written")) (clara.windows:unfinished))
  (clara.windows:raise-window busy)
  (check (list busy other) (mapcar #'car (clara.windows:unfinished)))
  (setq says 12)                               ; which is not words
  (check (list other) (mapcar #'car (clara.windows:unfinished)))
  (mapc #'clara.windows:close-window (list quiet busy broken other))
  (check nil (clara.windows:unfinished)))

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
(check '(("Listener" nil) ("Editor" "editor.lisp") ("Files" "files.lisp"))
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
;;; Shutting the machine down, and starting it again (lisp/system.lisp).
;;; The machine of these tests does neither: it takes note of what it was
;;; told and goes on, as a machine does that cannot be turned off from
;;; inside. So what is looked at is the order of things up to there: what
;;; the windows are asked, the world saved while the window manager still
;;; runs, the window manager stopped, the disk asked to put what it holds
;;; where it lasts, the substrate told, and what is said on the way.

;; What FUNCTION writes, and what the threads write that it makes: a new
;; thread writes where *STANDARD-OUTPUT* points outside every binding.
(defun said-by-all (function)
  (let ((output (sb-ext:symbol-global-value '*standard-output*)) (text (make-string-output-stream)))
    (setf (sb-ext:symbol-global-value '*standard-output*) text)
    ;; What SBCL has to say about a form that a test has loaded a second time is nobody's business.
    (unwind-protect (let ((*standard-output* text))
                      (handler-bind ((warning #'muffle-warning))
                        (funcall function)))
      (setf (sb-ext:symbol-global-value '*standard-output*) output))
    (get-output-stream-string text)))

(defvar *cannot-off* "clara: this machine cannot be turned off from inside: it can be switched off now")
(defvar *cannot-again* "clara: this machine cannot be started again from inside: that is for whoever runs it")

(check '("Restart" "Shut Down") (mapcar #'car *defined-commands*))

;; A machine with a disk and no window manager: the world goes to the disk,
;; the disk is told to keep it, and the machine is told to go.
(start-files (fat-bytes (make-fat-volume 16 '(("clara" (("kept.txt" "x")))))))
(clara.host:set-heap-image (octets "the world, as bytes"))
(let ((asked nil) (meanwhile nil))
  ;; One at a time: whoever asks while the world is on its way to the disk is refused.
  (setf (vdev-watch *disk*) (lambda ()
                              (push (first (car (vdev-requests *disk*))) asked)
                              (unless meanwhile
                                (setq meanwhile (condition-text #'clara.system:start-again)))))
  (check (format nil "clara: the world is saved~%clara: turning the machine off~%~A~%" *cannot-off*)
         (said-by-all (lambda () (clara.system:shut-down))))
  (check "the machine is being shut down already" meanwhile)
  (check '(:off) (clara.host:power))
  (check '(4 t) (list (car asked) (and (member 1 asked) t)))  ; written, and then put where it lasts
  (check "the world, as bytes" (text-of-file "/clara/clara.image"))
  (check nil clara.system::*leaving*)
  ;; Without saving: the world that was saved last stays as it is, and nothing is written.
  (clara.fat:remove-file "/clara/clara.image")
  (setq asked nil)
  (check (format nil "clara: starting the machine again~%~A~%" *cannot-again*)
         (said-by-all (lambda () (clara.system:start-again :save nil))))
  (check '((:off :again) (4) nil)
         (list (clara.host:power) asked (find "clara.image" (clara.fat:names "/clara") :test #'string-equal)))
  ;; One at a time.
  (setq clara.system::*leaving* :again)
  (check "the machine is being started again already" (condition-text #'clara.system:shut-down))
  (setq clara.system::*leaving* nil))

;; A world that cannot be saved: the machine stays as it was, and says why.
(start-files (fat-bytes (make-fat-volume 16 '(("notes.txt" "x")))))
(check (format nil "clara: the machine is not shut down: there is no directory for a file /clara/clara.image to be in~%")
       (said-by-all (lambda () (clara.system:shut-down))))
(check '(nil nil) (list (clara.host:power) clara.system::*leaving*))
(start-files (fat-bytes (make-fat-volume 16 '(("clara" (("kept.txt" "x")))))) :read-only t)
(check t (and (search "clara: the machine is not started again: the disk 00:03.0 cannot be written"
                      (said-by-all (lambda () (clara.system:start-again))))
              t))
(check nil (clara.host:power))

;; A machine without a disk has nowhere to save a world, and goes all the same.
(new-disks)
(said-by #'clara.disk:start)
(said-by #'clara.fat:start)
(check (format nil "clara: there is no disk to save the world on~%clara: turning the machine off~%~A~%" *cannot-off*)
       (said-by-all (lambda () (clara.system:shut-down))))
(check '(:off) (clara.host:power))

;; With the window manager running. A window whose program has something
;; unfinished stops the whole thing before anything is done: it comes to
;; the top, and whoever asked is told which it is. With FORCE nobody is
;; asked. The world is saved while the window manager runs, so that the
;; machine starts in it; then it is stopped, and then the disk is told.
(start-files (fat-bytes (make-fat-volume 16 '(("clara" (("kept.txt" "x")))))))
(new-desk :machine nil :width 300 :height 220)
(let* ((editor (clara.editor::open-editor nil :columns 20 :rows 3))
       (second (clara.editor::open-editor nil :columns 20 :rows 3))
       (plain (clara.windows:open-window "plain" 40 20))
       (seen nil))
  (check nil (clara.windows:unfinished))
  (keys editor "a")
  (check '("plain" "Editor" "Editor") (titles))
  (check (format nil "the machine is not shut down: the window \"Editor\" has text that is not saved. ~
                      Finish that, or ask with :FORCE T, which goes on without")
         (condition-text #'clara.system:shut-down))
  (check (list (clara.editor::editor-window editor) plain (clara.editor::editor-window second)) (clara.windows:windows))
  (keys second "b")
  (check (format nil "the machine is not started again: the window \"Editor\" has text that is not saved, ~
                      and 1 more have something too. Finish that, or ask with :FORCE T, which goes on without")
         (condition-text #'clara.system:start-again))
  (check '(nil t nil 0) (list (clara.host:power) (clara.windows:running-p) clara.system::*leaving* (wrong-pixels)))
  ;; The same from the launcher's list, where there is nobody to hand an error to: it is said.
  (check t (and (search "clara: the machine is not shut down: the window \"Editor\" has text that is not saved"
                        (said-by-all (lambda () (clara.system::asked :off))))
                t))
  (setf (vdev-watch *disk*)
        (lambda () (push (cons (first (car (vdev-requests *disk*))) (clara.windows:running-p)) seen)))
  (check (format nil "clara: the world is saved~%clara: starting the machine again~%~A~%" *cannot-again*)
         (said-by-all (lambda () (clara.system:start-again :force t))))
  (check '((4) t (:again) nil)
         (list (car seen) (every #'cdr (remove 4 seen :key #'car)) (clara.host:power) (clara.windows:running-p)))
  (check t (and (member '(1 . t) seen :test #'equal) t))
  (mapc #'clara.windows:close-window
        (list (clara.editor::editor-window editor) (clara.editor::editor-window second) plain)))

;; The launcher's list has the two commands that this file defined, and a
;; click on one is the same as asking at a prompt.
(new-disks)
(said-by #'clara.disk:start)
(said-by #'clara.fat:start)
(new-desk :machine nil :commands *defined-commands*)
(clara.windows:pointer-moved 5 5 1)
(clara.windows:pointer-moved 5 5 0)
(check '(t 0) (list clara.windows::*menu* (wrong-pixels)))
(check t (and (search (format nil "clara: turning the machine off~%~A~%" *cannot-off*)
                      (said-by-all (lambda ()
                                     (clara.windows:pointer-moved 20 50 1)       ; the second line: Shut Down
                                     (clara.windows:pointer-moved 20 50 0)
                                     (eventually (lambda () (clara.host:power)))
                                     (eventually (lambda () (null clara.system::*leaving*))))))
              t))
(check '((:off) nil) (list (clara.host:power) (clara.windows:running-p)))

;; The power button: START has a thread look at it, four times a second,
;; and a press is a request to shut down. A world that was saved by a
;; shutdown was in the middle of one, and is not when it starts.
(new-disks)
(said-by #'clara.disk:start)
(said-by #'clara.fat:start)
(setq clara.windows::*running* nil
      clara.system::*leaving* :off)
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(check '(nil t) (list clara.system::*leaving* (clara:thread-alive-p clara.system::*watcher*)))
(check '("power button" 2) (list (clara:thread-name clara.system::*watcher*) (length (clara:all-threads))))
(check nil (clara.host:power))
(check (format nil "clara: the power button was pressed~%clara: there is no disk to save the world on~%~
                    clara: turning the machine off~%~A~%" *cannot-off*)
       (said-by-all (lambda ()
                      (clara.host:press-power-button)
                      (eventually (lambda () (clara.host:power)))
                      (eventually (lambda () (null clara.system::*leaving*))))))
(check '(:off) (clara.host:power))
(let ((first clara.system::*watcher*))       ; started again: one thread watches, and it is another
  (said-by-all #'clara.system:start)
  (check '(nil t) (list (eq first clara.system::*watcher*) (eventually (lambda () (not (clara:thread-alive-p first)))))))
;;; A system is taken from another disk, tried, and takes the place of the
;;; one before it (lisp/system.lisp). The disks are made up here: a volume
;;; with a system in it, as a build lays one out, and another to take a
;;; system from. What the kernel says of a start is what the tests say it
;;; says, and afterwards the volume is looked at without the file system.

(defvar *this-kernel* (if (member :arm64 *features*) "BOOTAA64.EFI" "BOOTX64.EFI"))
(defvar *other-kernel* (if (member :arm64 *features*) "BOOTX64.EFI" "BOOTAA64.EFI"))

;; The directory of a system, for MAKE-FAT-VOLUME: its files, each (name
;; contents), and the manifest that lists them; with WRONG, the name of a
;; file whose sum the manifest has wrong, and without MANIFEST, none.
(defun system-tree (name files &key (manifest t) wrong)
  (let ((lines (list "what a later system may say, and this one passes over" (format nil "ClaraOS system: ~A" name))))
    (loop for (file contents) in files
          do (push (format nil "file ~D ~A ~A" (length (octets contents))
                           (if (equal file wrong)
                               (make-string 128 :initial-element #\0)
                               (clara.host:sha-512-of (octets contents)))
                           file)
                   lines))
    (list name (append files (and manifest (list (list "manifest" (format nil "~{~A~%~}" (reverse lines)))))))))

(defvar *old-files* (list '("boot.lisp" "(the old system)") (list *this-kernel* "the old kernel")
                          (list *other-kernel* "the old kernel of the other processor")))
(defvar *new-files* (list '("boot.lisp" "(the new system)") (list "long.lisp" *long-text*) '("empty.lisp" "")
                          (list *this-kernel* "the new kernel") (list *other-kernel* "the new kernel of the other processor")))

;; What a machine's own disk holds: where the firmware looks, the system
;; that runs, the world it saved, what a start has left there, and a file
;; of the user's.
(defun machine-tree (&rest more)
  `(("EFI" (("BOOT" ((,*this-kernel* "the old kernel") (,*other-kernel* "the old kernel of the other processor")))))
    ("clara" (,(system-tree "0.0.0-host" *old-files*) ("clara.image" "the world that the old system saved") ,@more))
    ("notes.txt" "written before any of this")))

(defvar *machine-disk* nil)   ; the bytes of the disk that the machine was started from,
(defvar *other-disk* nil)     ; and of the other one

;; A machine with those two volumes, the other one first on the bus when
;; FIRST says so, and the file system started on them.
(defun two-disks (machine other &key (first :machine))
  (setq *machine-disk* (fat-bytes (make-fat-volume 16 machine))
        *other-disk* (fat-bytes (make-fat-volume 16 other)))
  (if (eq first :machine)
      (new-disks (list 3 *machine-disk*) (list 4 *other-disk*))
      (new-disks (list 3 *other-disk*) (list 4 *machine-disk*)))
  (setq clara.windows::*running* nil)
  (said-by #'clara.disk:start)
  (said-by #'clara.fat:start))

;; What a file of a volume holds, as text, or NIL when the volume has none
;; of that name; and whether anything on the volume is out of order.
(defun on-disk (bytes name)
  (let ((file (assoc name (inspect-volume bytes) :test #'string-equal)))
    (and file (sb-ext:octets-to-string (coerce (cdr file) '(vector (unsigned-byte 8))) :external-format :utf-8))))

(defun in-order-p (bytes)
  (null (nth-value 1 (inspect-volume bytes))))

;; What a manifest says, and what is none.
(check '("0.0.1-new" ("boot.lisp" 5 "ab") ("a name with spaces.lisp" 0 "cd"))
       (let ((ab (make-string 128 :initial-element #\a)) (cd (make-string 128 :initial-element #\c)))
         (subst "cd" cd
                (subst "ab" ab
                       (clara.system::read-manifest
                        (format nil "ClaraOS system: 0.0.1-new~%file 5 ~A boot.lisp~%signed by somebody~%~
                                     file 0 ~A a name with spaces.lisp~%file 12 short-sum wrong.lisp~%~
                                     file x ~A no-length.lisp~%file 3 ~A ../outside.lisp~%file 3 ~A in/side.lisp~%~
                                     file 3 ~A .hidden~%file 7~%sums 9 ~A no-file-at-all.lisp~%"
                                ab cd ab ab ab ab ab))
                       :test #'equal)
                :test #'equal)))
(check '(nil nil nil) (list (clara.system::read-manifest "") (clara.system::read-manifest "file 5 x boot.lisp")
                            (clara.system::read-manifest (format nil "Some other system: x~%"))))
(check '(("a" "b" "c d e") ("a") ("" "b")) (list (clara.system::words "a b c d e" 2) (clara.system::words "a" 2)
                                                (clara.system::words " b" 1)))
(check '(0 1234567 nil nil nil) (mapcar #'clara.system::number-of '("0" "1234567" "" "12a" "1234567890123456")))

;; The volume that the machine was started from is the one that has this
;; start's number in /clara/starts, wherever its disk is on the bus; and a
;; start that gets to its end takes that file away. The names of files are
;; looked up there from then on, and the applications of the system are
;; its files.
(two-disks (machine-tree '("starts" "1 00000000000000aa
")) `(("clara" (,(system-tree "0.0.1-new" *new-files*) ("starts" "1 00000000000000bb
")))) :first :other)
(clara.host:set-start-state :token "00000000000000aa")
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(check '(t t "0.0.0-host" "/clara/0.0.0-host/boot.lisp" "/clara/0.0.0-host/")
       (list (eq (clara.system:boot-volume) (second (clara.fat:volumes))) (eq clara.fat:*volume* (clara.system:boot-volume))
             (clara.system:system) (clara.system:system-file "boot.lisp") clara.windows:*application-directory*))
(check '(nil t) (list (on-disk *machine-disk* "/clara/starts") (and (on-disk *other-disk* "/clara/starts") t)))
;; Without a number, or with one that no volume has, it is the first.
(clara.host:set-start-state :token "00000000000000cc")
(said-by-all #'clara.system:start)
(check t (eq (clara.system:boot-volume) (first (clara.fat:volumes))))

;; An upgrade: the other system's directory comes across file by file, the
;; manifest last, and then /clara/next says that it is to be tried.
;; Everything that was on the disk before is as it was, and what was taken
;; for the copying is given back.
(two-disks (machine-tree) `(("clara" (,(system-tree "0.0.1-new" *new-files*)))))
(clara.host:set-start-state)
(said-by-all #'clara.system:start)
(let ((pages (clara.host:allocated-pages)) (before (inspect-volume *machine-disk*)))
  (check (format nil "system: 0.0.1-new is on the disk, and is tried at the next start~%")
         (said-by-all (lambda () (check "0.0.1-new" (clara.system:upgrade :start-again nil)))))
  (check (list pages nil t) (list (clara.host:allocated-pages) (clara.host:power) (in-order-p *machine-disk*)))
  (check (format nil "try 0.0.1-new~%") (on-disk *machine-disk* "/clara/next"))
  (check t (loop for (name contents) in *new-files*
                 always (equal contents (on-disk *machine-disk* (format nil "/clara/0.0.1-new/~A" name)))))
  (check t (equal (on-disk *machine-disk* "/clara/0.0.1-new/manifest") (on-disk *other-disk* "/clara/0.0.1-new/manifest")))
  (check t (every (lambda (file) (equalp file (assoc (car file) (inspect-volume *machine-disk*) :test #'string=))) before))
  (check "the old kernel" (on-disk *machine-disk* (format nil "/EFI/BOOT/~A" *this-kernel*)))
  ;; Asked a second time, what the first left is taken away and the system is taken again; and
  ;; this time the machine is started again, which this one cannot be.
  (check t (and (search (format nil "clara: the world is saved~%clara: starting the machine again~%")
                        (said-by-all #'clara.system:upgrade))
                t))
  (check (list '(:again) t pages) (list (clara.host:power) (in-order-p *machine-disk*) (clara.host:allocated-pages)))
  (check (format nil "try 0.0.1-new~%") (on-disk *machine-disk* "/clara/next")))

;; What is not taken: a system with a file that is not what its manifest
;; says, one without a kernel for this machine, one that is not whole, the
;; system that runs, and anything when the disk has no room. Nothing then
;; says that a system is to be tried, and the machine starts as it did.
(dolist (how (list (list (system-tree "0.0.1-new" *new-files* :wrong "long.lisp")
                         "the file /clara/0.0.1-new/long.lisp is not what the manifest of its system says it is")
                   (list (system-tree "0.0.1-new" (remove *this-kernel* *new-files* :key #'car :test #'string=))
                         (format nil "the system 0.0.1-new has no kernel for this machine, which would be ~A" *this-kernel*))
                   (list (system-tree "0.0.1-new" *new-files* :manifest nil)
                         "no other disk of this machine holds a ClaraOS other than this one, 0.0.0-host")
                   (list (system-tree "0.0.0-host" *old-files*)
                         "no other disk of this machine holds a ClaraOS other than this one, 0.0.0-host")
                   (list (list "0.0.1-new" (cadr (system-tree "0.0.2-other" *new-files*)))
                         "no other disk of this machine holds a ClaraOS other than this one, 0.0.0-host")))
  (two-disks (machine-tree) `(("clara" (,(first how)))))
  (said-by-all #'clara.system:start)
  (let ((pages (clara.host:allocated-pages)))
    (check (second how) (condition-text #'clara.system:upgrade))
    (check (list nil nil t pages)
           (list (on-disk *machine-disk* "/clara/next") (on-disk *machine-disk* "/clara/0.0.1-new/manifest")
                 (in-order-p *machine-disk*) (clara.host:allocated-pages)))))
(two-disks (machine-tree) `(("clara" (,(system-tree "0.0.1-new" *new-files*)))))
(said-by-all #'clara.system:start)
(check "that volume holds no ClaraOS other than this one, 0.0.0-host"
       (condition-text (lambda () (clara.system:upgrade :from (clara.system:boot-volume)))))
(check "0.0.1-new" (progn (said-by-all (lambda () (clara.system:upgrade :from (second (clara.fat:volumes)) :start-again nil)))
                          (car (clara.system::system-on (second (clara.fat:volumes))))))
(setq *machine-disk* (fat-bytes (make-fat-volume 12 (machine-tree) :clusters 40)))   ; a disk with 20 KiB to it
(new-disks (list 3 *machine-disk*) (list 4 (fat-bytes (make-fat-volume 16 `(("clara" (,(system-tree "0.0.1-new" *new-files*))))))))
(said-by #'clara.disk:start)
(said-by #'clara.fat:start)
(said-by-all #'clara.system:start)
(check t (let ((said (condition-text #'clara.system:upgrade)))
           (and (search "KiB free, and the system 0.0.1-new takes" said) (null (on-disk *machine-disk* "/clara/next"))
                (in-order-p *machine-disk*))))
;; A machine that was not started from a disk has nowhere to put a system.
(new-disks)
(said-by #'clara.disk:start)
(said-by #'clara.fat:start)
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(check '(nil nil) (list (clara.system:boot-volume) clara.windows:*application-directory*))
(check-condition error (clara.system:upgrade))

;; On trial: the system that the old kernel started in place of itself has
;; come to its prompt, and takes the old one's place. Its kernels are where
;; the firmware looks, /clara/next is gone, and so is the old system's
;; directory, and the count of this start.
(two-disks (append (machine-tree '("next" "tried 0.0.1-new
") '("starts" "1 0000000000000001
")) nil)
           '(("nothing.txt" "of interest")))
(setq *machine-disk* (fat-bytes (make-fat-volume 16 (let ((tree (machine-tree '("next" "tried 0.0.1-new
") '("starts" "1 0000000000000001
"))))
                                                    (setf (second (second tree))
                                                          (cons (system-tree "0.0.1-new" *new-files*) (second (second tree))))
                                                    tree))))
(new-disks (list 3 *machine-disk*))
(said-by #'clara.disk:start)
(said-by #'clara.fat:start)
;; The world that it has made is saved in the place of the old system's,
;; which is of no use to it, and it says that the old world left no
;; account of itself.
(clara.host:set-start-state :system "0.0.1-new" :trial t :token "0000000000000001")
(clara.host:set-heap-image (octets "the world that the new system made"))
(check (format nil "system: this is ClaraOS 0.0.1-new, on trial: the system before it is still in place~%~
                    system: 0.0.1-new has come to its prompt, and is the system of this machine from here on~%~
                    world: made anew by ClaraOS 0.0.1-new, of its files and of what /home/ holds as text~%~
                    world: the system before this one left no account of its world: what that had beyond the text is not known~%~
                    world: it is saved as it is now, and the next start is in it; (clara.system:report) says this again~%")
       (said-by-all #'clara.system:start))
(check '("the new kernel" "the new kernel of the other processor" nil nil nil "(the new system)" t)
       (list (on-disk *machine-disk* (format nil "/EFI/BOOT/~A" *this-kernel*))
             (on-disk *machine-disk* (format nil "/EFI/BOOT/~A" *other-kernel*))
             (on-disk *machine-disk* "/clara/next") (on-disk *machine-disk* "/clara/starts")
             (on-disk *machine-disk* "/clara/0.0.0-host/boot.lisp") (on-disk *machine-disk* "/clara/0.0.1-new/boot.lisp")
             (in-order-p *machine-disk*)))
(check '("written before any of this" "the world that the new system made")
       (list (on-disk *machine-disk* "/notes.txt") (on-disk *machine-disk* "/clara/clara.image")))
(check '("0.0.1-new") (clara.system::systems-here))

;; A trial that did not come to its prompt: the system from before says so
;; when it is started again, and marks the one that failed.
(setq *machine-disk* (fat-bytes (make-fat-volume 16 (let ((tree (machine-tree '("next" "failed 0.0.1-new
"))))
                                                    (setf (second (second tree))
                                                          (cons (system-tree "0.0.1-new" *new-files*) (second (second tree))))
                                                    tree))))
(new-disks (list 3 *machine-disk*) (list 4 (fat-bytes (make-fat-volume 16 `(("clara" (,(system-tree "0.0.1-new" *new-files*)
                                                                                     ("at-once" ""))))))))
(said-by #'clara.disk:start)
(said-by #'clara.fat:start)
(clara.host:set-start-state :failed "0.0.1-new")
;; It is on another disk as well, to be taken at once, and is not, having failed.
(check (format nil "system: this is ClaraOS 0.0.0-host~%~
                    system: 0.0.1-new was tried and did not come to its prompt: this is still 0.0.0-host~%~
                    system: 0.0.1-new, on another disk, is not taken again: it did not come to its prompt~%")
       (said-by-all #'clara.system:start))
(check '(nil t t "the old kernel" nil)
       (list (on-disk *machine-disk* "/clara/next") (and (on-disk *machine-disk* "/clara/0.0.1-new/failed") t)
             (in-order-p *machine-disk*) (on-disk *machine-disk* (format nil "/EFI/BOOT/~A" *this-kernel*))
             (clara.host:power)))
;; Asked for, it is taken once more: what the failure left is replaced.
(clara.host:set-start-state)
(said-by-all (lambda () (clara.system:upgrade :start-again nil)))
(check (list (format nil "try 0.0.1-new~%") nil t)
       (list (on-disk *machine-disk* "/clara/next") (on-disk *machine-disk* "/clara/0.0.1-new/failed") (in-order-p *machine-disk*)))

;; A disk that says "at once": the system on it is taken as the machine
;; starts, and the machine started again to try it, without a word from
;; anybody. The start that does that has not come to its prompt.
(two-disks (machine-tree '("starts" "1 0000000000000002
")) `(("clara" (,(system-tree "0.0.1-new" *new-files*) ("at-once" "")))))
(clara.host:set-start-state :token "0000000000000002")
(check t (let ((said (said-by-all #'clara.system:start)))
           (and (search (format nil "system: this is ClaraOS 0.0.0-host~%~
                                     system: 0.0.1-new is taken from another disk, and the machine starts again to try it~%~
                                     clara: starting the machine again~%")
                        said)
                t)))
(check (list '(:again) (format nil "try 0.0.1-new~%") t)
       (list (clara.host:power) (on-disk *machine-disk* "/clara/next") (in-order-p *machine-disk*)))
(check (list "1 0000000000000002
" 0) (list (on-disk *machine-disk* "/clara/starts")
           (search "(:carried \"0.0.0-host\" \"0.0.1-new\")" (on-disk *machine-disk* "/clara/carried"))))
;; A disk that says so and has the system that runs is left alone.
(two-disks (machine-tree) `(("clara" (,(system-tree "0.0.0-host" *old-files*) ("at-once" "")))))
(clara.host:set-start-state)
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(check '(nil nil) (list (clara.host:power) (on-disk *machine-disk* "/clara/next")))

;;; What the user keeps as text (lisp/system.lisp): /home on the volume
;;; that the machine was started from, with the file that the listeners
;;; write, each form that defines something as it was typed, and the file
;;; that is the user's own. A world that is made from the files loads both.

(defvar *order* nil)   ; what the files of the tests' /home say as they are loaded

(defun home-tree (&rest files)
  (append (machine-tree) (list (list "home" files))))

(defun one-disk (tree)
  (setq *machine-disk* (fat-bytes (make-fat-volume 16 tree))
        *disk* (car (new-disks (list 3 *machine-disk*))))
  (setq clara.windows::*running* nil)
  (said-by #'clara.disk:start)
  (said-by #'clara.fat:start))

;; What is written down, and what is not: a form that defines, by a word
;; of the language's, by a macro that is called that way or by anything
;; that is called DEFINE-, and a LOAD; not a function that happens to
;; begin with the three letters, and not a LOAD of one of the two files,
;; which would then load itself.
(defmacro deftest (name) `(quote ,name))
(defun default-of (value) value)
(defmacro defective (name) (error "~S cannot be expanded" name))
(check '(t t t t t t t t t t t nil nil nil nil nil nil nil nil nil nil nil)
       (mapcar (lambda (form) (and (clara.system::defining-p form) t))
               '((defun f ()) (defmacro m ()) (defvar *v* 1) (defparameter *p* 1) (define-condition c () ()) (defstruct s a)
                 (deftest of-the-users) (load "/x.lisp") (clara.windows:define-application "Mine" #'car) (define-whatever)
                 (clara.windows:install-application "Mine" "/mine.lisp")
                 (clara.windows:remove-application "Mine") (default-of 1) (defective one) (defer-nothing) (load "/home/defined.lisp") (load "/HOME/Init.lisp")
                 (setq *v* 2) (in-package "X") 5 ((lambda ())) (let () (defun f ())))))
(check (list (concatenate 'string (make-string 84 :initial-element #\a) " ...") "one line ..." "short")
       (list (clara.system::brief (make-string 85 :initial-element #\a)) (clara.system::brief (format nil "  one line~%and another"))
             (clara.system::brief "short")))
(check '(t t nil nil nil)
       (mapcar (lambda (name) (and (clara.system::home-name-p name) t))
               '("/home/init.lisp" "/home/DEFINED.lisp" "/home/other.lisp" "/defined.lisp" defined)))
(check '("" "a b" "a" "(f)") (mapcar #'clara.system::trimmed (list "" (format nil " ~% a b~%  ") "a" (format nil "~%(f)"))))
(check '(4 4 14 2) (list (clara.system::form-start "    (f)" 0 7) (clara.system::form-start "(a) (f)" 3 7)
                          (clara.system::form-start (format nil " ; (not this)~%(f)") 0 17)
                          (clara.system::form-start "  " 0 2)))
(check '(3 3 0) (list (clara.system::form-end "(f) " 0 4) (clara.system::form-end "(f)" 0 3) (clara.system::form-end "  " 0 2)))

;; A machine without /home gets one when it starts, and what is defined
;; from then on is written into it: a new form at the end, a form that
;; defines a name again in the place of the first, and a line between forms
;; that were read in different packages.
(one-disk (machine-tree))
(clara.host:set-start-state)
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(check '("clara/" "EFI/" "home/" "notes.txt") (clara.fat:names "/"))
(check t (eq clara.listener:*record* #'clara.system::record))
(defpackage "CLARA.TESTS.PLAY" (:use "COMMON-LISP"))
(flet ((typed (text package)
         (let ((form (let ((*package* (find-package package))) (read-from-string text))))
           (clara.system::record form (format nil "~% ~A " text) package))))
  (let ((pages (clara.host:allocated-pages)))
    (typed "(defun one () 1)" "COMMON-LISP-USER")
    (typed "(+ 1 2)" "COMMON-LISP-USER")
    (typed "(defvar *two* 2)" "COMMON-LISP-USER")
    (typed "(defun ball () 'round)" "CLARA.TESTS.PLAY")
    (typed "(defun one () 'in-play)" "CLARA.TESTS.PLAY")
    (typed (format nil "(defun one ()~%  ;; a second time~%  'again)") "COMMON-LISP-USER")
    (typed "(load \"/tools.lisp\")" "COMMON-LISP-USER")
    (typed "(defun ONE () 'in-play-again)" "CLARA.TESTS.PLAY")
    (typed "(load \"/tools.lisp\")" "COMMON-LISP-USER")
    (typed "(defvar one 'a-variable-of-the-name-of-a-function)" "COMMON-LISP-USER")
    (check (format nil "~A~%(defun one ()~%  ;; a second time~%  'again)~%~%(defvar *two* 2)~%~%~
                        (cl:in-package \"CLARA.TESTS.PLAY\")~%~%(defun ball () 'round)~%~%(defun ONE () 'in-play-again)~%~%~
                        (cl:in-package \"COMMON-LISP-USER\")~%~%(load \"/tools.lisp\")~%~%~
                        (defvar one 'a-variable-of-the-name-of-a-function)~%"
                   clara.system::*first-lines*)
           (on-disk *machine-disk* "/home/defined.lisp"))
    (check (list pages t) (list (clara.host:allocated-pages) (in-order-p *machine-disk*)))))
;; It goes to the disk that the machine was started from, wherever names
;; are looked up at the moment; and what cannot be written is said, and is
;; nobody's error.
(check "" (said-by-all (lambda ()
                         (let ((clara.fat:*volume* nil))
                           (clara.system::record '(defun three () 3) "(defun three () 3)" "COMMON-LISP-USER")))))
(check t (and (search "(defun three () 3)" (on-disk *machine-disk* "/home/defined.lisp")) t))
(setf (vdev-answer *disk*) 1)
(check t (and (search "home: what was defined could not be written down in /home/defined.lisp: the disk 00:03.0 could not"
                      (said-by-all (lambda () (clara.system::record '(defun four () 4) "(defun four () 4)" "COMMON-LISP-USER"))))
              t))
(setf (vdev-answer *disk*) 0)

;; What the window manager's two functions take out of the launcher's list
;; goes out of the file as well, whichever form put it there and in
;; whichever package, so that a world which is made of the text is without
;; it too. A name that is not in the file changes nothing, and neither
;; does a name that is worked out.
(one-disk (home-tree (list "defined.lisp" (format nil ";; mine~%(defun one () 1)~%~%;; an application~%~
                                                       (clara.windows:define-application \"Mine\" #'one)~%~%~
                                                       (clara.windows:define-command \"Tidy\" #'one)~%~%~
                                                       (cl:in-package \"CLARA.TESTS\")~%~%~
                                                       (clara.windows:install-application \"Mine\" \"/mine.lisp\")~%~%~
                                                       (clara.windows:define-application \"Mine too\" #'car)~%"))))
(clara.host:set-start-state :resumed t)
(setq clara.system::*follows* nil)
(said-by-all #'clara.system:start)
(let ((before (on-disk *machine-disk* "/home/defined.lisp")))
  (clara.system::record '(clara.windows:remove-application "Nobody's") "(clara.windows:remove-application \"Nobody's\")" "COMMON-LISP-USER")
  (clara.system::record '(clara.windows:remove-application (car (list "Mine"))) "(clara.windows:remove-application (car (list \"Mine\")))"
                        "COMMON-LISP-USER")
  (clara.system::record '(clara.windows:unload-application "Mine") "(clara.windows:unload-application \"Mine\")" "COMMON-LISP-USER")
  (check before (on-disk *machine-disk* "/home/defined.lisp")))
(clara.system::record '(clara.windows:remove-application "Mine") "(clara.windows:remove-application \"Mine\")" "COMMON-LISP-USER")
(check (format nil ";; mine~%(defun one () 1)~%~%;; an application~%~%~
                    (clara.windows:define-command \"Tidy\" #'one)~%~%~
                    (cl:in-package \"CLARA.TESTS\")~%~%~
                    (clara.windows:define-application \"Mine too\" #'car)~%")
       (on-disk *machine-disk* "/home/defined.lisp"))
(clara.system::record '(clara.windows:remove-command "Tidy") "(clara.windows:remove-command \"Tidy\")" "CLARA.TESTS")
(clara.system::record '(clara.windows:remove-application "Mine too") "(clara.windows:remove-application \"Mine too\")" "CLARA.TESTS")
(check (list (format nil ";; mine~%(defun one () 1)~%~%;; an application~%~%(cl:in-package \"CLARA.TESTS\")~%~%") t)
       (list (on-disk *machine-disk* "/home/defined.lisp") (in-order-p *machine-disk*)))
;; What cannot be taken out is said, and is nobody's error.
(clara.system::record '(defun three () 3) "(clara.windows:define-command \"Tidy\" #'car)" "COMMON-LISP-USER")
(setf (vdev-answer *disk*) 1)
(check t (and (search "home: what was taken back could not be taken out of /home/defined.lisp: "
                      (said-by-all (lambda () (clara.system::record '(clara.windows:remove-command "Tidy")
                                                                    "(clara.windows:remove-command \"Tidy\")" "COMMON-LISP-USER"))))
              t))
(setf (vdev-answer *disk*) 0)

;; A file that the user has written into: what stands before a form stays
;; before it, and a form in a package that is not there, or a place that
;; cannot be read, leaves everything from there on as it is, with the new
;; form after it and the name of its package before it. (The world of
;; these is one that was saved without the text, so that nothing of the
;; files is loaded.)
(clara.host:set-start-state :resumed t)
(setq clara.system::*follows* nil)
(one-disk (home-tree (list "defined.lisp" (format nil ";; mine~%(defun one () 1) ; the first~%~%;; and the second~%(defun two () 2)~%"))))
(said-by-all #'clara.system:start)
(clara.system::record '(defun two () 22) "(defun two () 22)" "COMMON-LISP-USER")
(clara.system::record '(defun one () 11) "(defun one () 11)" "COMMON-LISP-USER")
(check (format nil ";; mine~%(defun one () 11) ; the first~%~%;; and the second~%(defun two () 22)~%")
       (on-disk *machine-disk* "/home/defined.lisp"))
(one-disk (home-tree (list "defined.lisp" (format nil "(defun one () 1)~%(cl:in-package \"NO-SUCH-PACKAGE-HERE\")~%(defun two () 2)~%"))))
(said-by-all #'clara.system:start)
(clara.system::record '(defun two () 22) "(defun two () 22)" "COMMON-LISP-USER")
(clara.system::record '(defun one () 11) "(defun one () 11)" "COMMON-LISP-USER")
(check (format nil "(defun one () 11)~%(cl:in-package \"NO-SUCH-PACKAGE-HERE\")~%(defun two () 2)~%~%~
                    (cl:in-package \"COMMON-LISP-USER\")~%~%(defun two () 22)~%")
       (on-disk *machine-disk* "/home/defined.lisp"))
(one-disk (home-tree (list "defined.lisp" (format nil "(defun one () 1)~%(defun two () (~%"))))
(said-by-all #'clara.system:start)
(clara.system::record '(defun two () 22) "(defun two () 22)" "COMMON-LISP-USER")
(check (format nil "(defun one () 1)~%(defun two () (~%~%(cl:in-package \"COMMON-LISP-USER\")~%~%(defun two () 22)~%")
       (on-disk *machine-disk* "/home/defined.lisp"))

;; A world that was made on this start loads what /home has: init.lisp and
;; then defined.lisp, each form by itself, in COMMON-LISP-USER until a form
;; says otherwise. A form that fails is passed over and said, with the
;; reason; what cannot be read ends that file; and the package that names
;; are read in afterwards is the one from before.
(one-disk (home-tree (list "init.lisp" (format nil "(push :init clara.tests::*order*)~%(error \"this form fails\")~%~
                                                    (cl:in-package \"CLARA.TESTS\")~%(push (package-name *package*) *order*)~%"))
                     (list "defined.lisp" (format nil "(push (list :defined (package-name *package*)) clara.tests::*order*)~%~
                                                       (car 'not-a-list)~%(push :after clara.tests::*order*)~%(this (is not whole~%"))))
(clara.host:set-start-state)
(setq *order* nil)
(let ((package *package*)
      (said (said-by-all #'clara.system:start)))
  (check '(:init "CLARA.TESTS" (:defined "COMMON-LISP-USER") :after) (reverse *order*))
  (check t (eq package *package*))
  (check t (and (search (format nil "home: /home/init.lisp is loaded, 3 forms of it, and 1 was passed over:~%~
                                     home:   (error \"this form fails\")~%home:     this form fails~%")
                        said)
                (search "home: /home/defined.lisp is loaded, 2 forms of it, and 2 were passed over:" said)
                (search "home:   (car 'not-a-list)" said)
                (search "home:   (this (is not whole" said)
                t)))
(check 2 (length (clara:all-threads)))                ; the thread that loaded is gone, and one watches the button
;; A world that was saved has it all already, and is not loaded into; and
;; after two starts that did not come to a prompt, the text may be why.
(setq *order* nil)
(clara.host:set-start-state :resumed t)
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(clara.host:set-start-state :starts 1)
(check t (and (search "home: /home/init.lisp is loaded" (said-by-all #'clara.system:start)) t))
(setq *order* nil)
(clara.host:set-start-state :starts 2)
(check (format nil "system: this is ClaraOS 0.0.0-host~%~
                    home: the two starts before this one did not come to a prompt: what is in /home/ is not loaded~%~
                    home:   this world is the system's alone. Put the files right, and (clara.system:load-home) loads them~%")
       (said-by-all #'clara.system:start))
(check '(nil nil) (list *order* clara.system::*follows*))
;; Asked for, the text is loaded into that world, which has it from then on.
(check t (and (search "home: /home/init.lisp is loaded" (said-by-all #'clara.system:load-home)) t))
(check '(t t) (list (and (member :init *order*) t) clara.system::*follows*))

;; A text that does not come to an end is given so long, and stopped: the
;; machine comes to its prompt all the same, and the file after it is
;; loaded.
(one-disk (home-tree (list "init.lisp" (format nil "(push :begun clara.tests::*order*)~%(loop (sleep 0.01))~%(push :never clara.tests::*order*)~%"))
                     (list "defined.lisp" "(push :defined clara.tests::*order*)")))
(clara.host:set-start-state)
(setq *order* nil)
(let ((clara.system:*patience* 300))
  (check (format nil "system: this is ClaraOS 0.0.0-host~%~
                      home: /home/init.lisp was not loaded to its end: it took more than 0 seconds, or could not be read~%~
                      home: /home/defined.lisp is loaded, 1 form~%")
         (said-by-all #'clara.system:start)))
(check '(:begun :defined) (reverse *order*))
(check t (eventually (lambda () (= (length (clara:all-threads)) 2))))

;; A file that would load itself, or the other of the two, by a LOAD at
;; its top: such a form is refused and said, whether the name is written
;; there or worked out, and the rest of the file is loaded.
(one-disk (home-tree (list "init.lisp" (format nil "(push :init clara.tests::*order*)~%(load \"/home/defined.lisp\")~%"))
                     (list "defined.lisp" (format nil "(push :defined clara.tests::*order*)~%~
                                                       (load (clara.system:home-file \"defined.lisp\"))~%~
                                                       (load \"/HOME/INIT.LISP\")~%(push :after clara.tests::*order*)~%"))))
(clara.host:set-start-state)
(setq *order* nil)
(let ((said (said-by-all #'clara.system:start)))
  (check '(:init :defined :after) (reverse *order*))
  (check t (and (search (format nil "home: /home/init.lisp is loaded, 1 form of it, and 1 was passed over:~%~
                                     home:   (load \"/home/defined.lisp\")~%~
                                     home:     /home/defined.lisp is loaded into a new world by itself, and not by a form of /home/~%")
                        said)
                (search "home: /home/defined.lisp is loaded, 2 forms of it, and 2 were passed over:" said)
                (search (format nil "home:   (load (clara.system:home-file \"defined.lisp\"))~%~
                                     home:     /home/defined.lisp is loaded into a new world by itself, and not by a form of /home/~%")
                        said)
                (search (format nil "home:   (load \"/HOME/INIT.LISP\")~%~
                                     home:     /HOME/INIT.LISP is loaded into a new world by itself, and not by a form of /home/~%")
                        said)
                t)))

;; The two files are the ones on the disk that the machine was started
;; from, also when a form of the first has names looked up on another disk
;; from then on, whether that has a /home of its own or none. And the
;; start has not come to its prompt while they are loaded: the file that
;; counts it is still there, so that a text which takes the machine down
;; is found out.
(dolist (other '((("home" (("defined.lisp" "(push :of-the-other-disk clara.tests::*order*)"))))
                 (("mine.txt" "a disk without a home"))))
  (two-disks (append (machine-tree '("starts" "1 00000000000000ee
"))
                     (list (list "home" (list (list "init.lisp"
                                                    (format nil "(push (clara.system::there-p \"/clara/\" \"starts\") clara.tests::*order*)~%~
                                                                 (setq clara.fat:*volume* (first (clara.fat:volumes)))"))
                                              (list "defined.lisp" "(push :of-the-machine clara.tests::*order*)")))))
             other :first :other)
  (clara.host:set-start-state :token "00000000000000ee")
  (setq *order* nil)
  (check (format nil "system: this is ClaraOS 0.0.0-host~%~
                      home: /home/init.lisp is loaded, 2 forms~%home: /home/defined.lisp is loaded, 1 form~%")
         (said-by-all #'clara.system:start))
  (check '((:of-the-machine t) t nil) (list *order* (eq clara.fat:*volume* (first (clara.fat:volumes)))
                                            (on-disk *machine-disk* "/clara/starts"))))

;; A world is saved on the disk that the machine was started from, also
;; while the names of files are looked up on another.
(two-disks (machine-tree '("starts" "1 00000000000000dd
")) '(("mine.txt" "on a disk of my own")) :first :other)
(clara.host:set-start-state :token "00000000000000dd")
(said-by-all #'clara.system:start)
(clara.host:set-heap-image (octets "a world, saved from anywhere"))
(setq clara.fat:*volume* (first (clara.fat:volumes)))
(check '(("mine.txt") "/clara/clara.image") (list (clara.fat:names "/") (clara:save-image)))
(check '("a world, saved from anywhere" nil t)
       (list (on-disk *machine-disk* "/clara/clara.image") (on-disk *other-disk* "/clara/clara.image")
             (and (in-order-p *machine-disk*) (in-order-p *other-disk*))))
;; A volume of an earlier start is no place for a world, whoever names it:
;; its disk is not this start's. The world then goes where names are looked
;; up first.
(let ((earlier clara.fat:*image-volume*))
  (said-by #'clara.fat:start)
  (check nil clara.fat:*image-volume*)
  (setq clara.fat:*image-volume* earlier)
  (clara.host:set-heap-image (octets "a world of a later start"))
  (check '(nil "there is no directory for a file /clara/clara.image to be in")
         (list (and (member earlier (clara.fat:volumes)) t) (condition-text #'clara:save-image)))
  (check '("a world, saved from anywhere" nil) (list (on-disk *machine-disk* "/clara/clara.image")
                                                     (on-disk *other-disk* "/clara/clara.image"))))

;;; A world made again (lisp/system.lisp): what a world that is leaving
;;; writes down of itself, what the system that comes makes of it, a world
;;; that takes what is new of the text, and a saved world that does not
;;; come to its prompt.

;; What can be written as text and read back the same.
(check '("5" "\"a \\\"b\\\"\"" "(1 \"two\" #\\3 FOUR (:FIVE . 6))" "NIL" nil nil nil nil nil)
       (let ((ring (list 1 2 3)))
         (setf (cdr (last ring)) ring)
         (mapcar #'clara.system::as-text
                 (list 5 "a \"b\"" '(1 "two" #\3 cl-user::four (:five . 6)) nil
                       ring #'car (make-symbol "LOOSE") (list 1 (vector 2)) (make-list 20001 :initial-element 0)))))
(check '(t nil nil) (list (and (clara.system::as-text (make-list 5000 :initial-element 'cl-user::item)) t)
                          (clara.system::as-text (make-list 15000 :initial-element 'cl-user::item))
                          (clara.system::as-text (make-list 100 :initial-element (make-string 1000 :initial-element #\x)))))
;; Nothing is text on trust: what does not read back as it was is none. (Here a number, to a reader that counts in sixteens.)
(check '("17" nil) (list (clara.system::as-text 17) (let ((*read-base* 16)) (clara.system::as-text 17))))
;; Names in lines that fit, and a line that says there are more than were said.
(check '(() ("one") ("one, two")) (mapcar #'clara.system::name-lines '(() ("one") ("one" "two"))))
(let ((lines (clara.system::name-lines (loop for i below 40 collect (format nil "A-NAME-OF-SOME-LENGTH-~D" i)))))
  (check '(t t 40) (list (every (lambda (line) (<= (length line) 88)) lines) (> (length lines) 3)
                         (+ (length lines) (reduce #'+ (mapcar (lambda (line) (count #\, line)) lines))))))
(setq clara.system::*report* nil)
(check (format nil "world: 5 things:~%world:   a, b, c, d, e~%")
       (said-by (lambda () (clara.system::tell-names "world: 1 thing:" "world: ~D things:" '("a" "b" "c" "d" "e")))))
(check (format nil "world: 1 thing:~%world:   a~%")
       (said-by (lambda () (clara.system::tell-names "world: 1 thing:" "world: ~D things:" '("a")))))
(let ((said (said-by (lambda () (clara.system::tell-names "world: 1 name:" "world: ~D names:"
                                                          (loop for i below 40 collect (format nil "A-NAME-OF-SOME-LENGTH-~D" i)))))))
  (check '(5 t) (list (count #\Newline said)
                      (and (search (format nil "world:   and more: (clara.system:report) names them all~%") said) t))))
;; What was said is kept and said again, the oldest lines going when there are too many.
(check t (let ((again (said-by #'clara.system:report)))
           (and (search (format nil "world: 5 things:~%world:   a, b, c, d, e~%world: 1 thing:~%world:   a~%world: 40 names:~%") again)
                (search "A-NAME-OF-SOME-LENGTH-39" again)
                t)))
(setq clara.system::*report* nil)
(dotimes (i 450)
  (clara.system::keep (format nil "line ~D" i)))
(check '(349 "line 449" "line 101") (list (length clara.system::*report*) (first clara.system::*report*)
                                           (car (last clara.system::*report*))))
(setq clara.system::*report* nil)

;; The account that a world leaves when a system waits to be tried: the
;; system it is for, the window manager when that runs, and of every
;; package that is the user's the functions and the variables, with the
;; values that are text. It is written as the machine is started again,
;; and not before.
(two-disks (machine-tree) `(("clara" (,(system-tree "0.0.1-new" *new-files*)))))
(clara.host:set-start-state)
(said-by-all #'clara.system:start)
(defpackage "PLAYGROUND" (:use "COMMON-LISP"))
(defun playground::swing () 'high)
(defmacro playground::twice (form) `(progn ,form ,form))
(defvar playground::*count* 3)
(defvar playground::*words* (list "one" #\2 'playground::three :four '(5 . cl-user::six)))
(defvar playground::*lock* (clara:make-lock "held"))
(defvar playground::*ring* (let ((ring (list 1 2))) (setf (cdr (last ring)) ring) ring))
(defvar playground::swing 'a-variable-too)
(defpackage "CLARA.LATER" (:use "COMMON-LISP"))       ; as the launcher makes one for an application of the system's
(defun clara.later::of-the-system () 'not-the-users)
(check '(t nil t) (list (and (member (find-package "PLAYGROUND") (clara.system::user-packages)) t)
                        (member (find-package "CLARA.SYSTEM") (clara.system::user-packages))
                        (and (member (find-package "COMMON-LISP-USER") (clara.system::user-packages)) t)))
(check nil (clara.system::waiting))
(clara.system::write-text "/clara/next" (format nil "tried 0.0.1-new~%"))
(check nil (clara.system::waiting))
(clara.fat:remove-file "/clara/next")
(said-by-all (lambda () (clara.system:upgrade :start-again nil)))
(check '("0.0.1-new" nil) (list (clara.system::waiting) (on-disk *machine-disk* "/clara/carried")))
;; (It goes to the disk that the machine was started from, wherever names are looked up at the moment.)
(setq clara.fat:*volume* (second (clara.fat:volumes)))
(check t (and (search "clara: starting the machine again" (said-by-all (lambda () (clara.system:start-again :save nil)))) t))
(setq clara.fat:*volume* (first (clara.fat:volumes)))
(check nil (on-disk *other-disk* "/clara/carried"))
(let ((account (on-disk *machine-disk* "/clara/carried")))
  (check 0 (search (format nil "(:carried \"0.0.0-host\" \"0.0.1-new\")~%(:name ") account))
  (check t (and (search (format nil "(:name \"PLAYGROUND\" \"*COUNT*\" :variable)~%(:value \"PLAYGROUND\" \"*COUNT*\" \"3\")~%~
                                     (:name \"PLAYGROUND\" \"*LOCK*\" :variable)~%~
                                     (:name \"PLAYGROUND\" \"*RING*\" :variable)~%~
                                     (:name \"PLAYGROUND\" \"*WORDS*\" :variable)~%~
                                     (:value \"PLAYGROUND\" \"*WORDS*\" \"(\\\"one\\\" #\\\\2 PLAYGROUND::THREE :FOUR (5 . SIX))\")~%~
                                     (:name \"PLAYGROUND\" \"SWING\" :function)~%~
                                     (:name \"PLAYGROUND\" \"SWING\" :variable)~%~
                                     (:value \"PLAYGROUND\" \"SWING\" \"CLARA.TESTS::A-VARIABLE-TOO\")~%~
                                     (:name \"PLAYGROUND\" \"TWICE\" :function)~%")
                        account)
                t))
  ;; Nothing of the system's, nothing that a package only has of another, and no symbol that is neither.
  (check '(nil nil nil nil nil nil t)
         (list (search "CLARA.SYSTEM" account) (search "CLARA.LATER" account) (search "(:name \"COMMON-LISP\" " account)
               (search "(:name \"KEYWORD\" " account)
               (search "(:name \"PLAYGROUND\" \"CAR\"" account) (search "\"THREE\"" account)
               (in-order-p *machine-disk*))))
;; With the window manager running, that is said in it; and a world that
;; cannot be written down goes all the same, and says so.
(let ((clara.windows::*running* t))
  (clara.system::carry "0.0.1-new"))
(check 0 (search (format nil "(:carried \"0.0.0-host\" \"0.0.1-new\")~%(:windows)~%(:name ") (on-disk *machine-disk* "/clara/carried")))
(clara.fat:remove-file "/clara/carried")
(clara.fat:make-directory "/clara/carried")
(check t (let ((said (said-by-all (lambda () (clara.system:start-again :save nil)))))
           (and (search "system: what this world has could not be written down for 0.0.1-new: " said)
                (search "clara: starting the machine again" said)
                t)))
(clara.fat:remove-directory "/clara/carried")
;; A start that is not the trial of a system has no use for an account.
(clara.system::carry "0.0.1-new")
(clara.host:set-start-state)
(said-by-all #'clara.system:start)
(check nil (on-disk *machine-disk* "/clara/carried"))

;; The system that comes: it makes its world, loads the text, gives the
;; variables the values that they had come to, says what it does not have
;; of the names that the old world had, and saves the world.
(defun trial-disk (account &rest home)
  (let ((tree (append (machine-tree '("next" "tried 0.0.1-new
") '("starts" "1 0000000000000007
"))
                      (and home (list (list "home" home))))))
    (setf (second (second tree))
          (append (list (system-tree "0.0.1-new" *new-files*)) (and account (list (list "carried" account)))
                  (second (second tree))))
    (one-disk tree))
  (said-by #'clara.draw:start)                        ; a machine without a screen, until a test gives it one
  (clara.host:set-start-state :system "0.0.1-new" :trial t :token "0000000000000007")
  (clara.host:set-heap-image (octets "the world that was made again")))

(trial-disk (format nil "(:carried \"0.0.0-host\" \"0.0.1-new\")~%~
                         (:later \"a line of a later system\" 5)~%42~%~
                         (:name \"SANDPIT\" \"DIG\" :function)~%(:name \"SANDPIT\" \"DIG\" :variable)~%~
                         (:name \"SANDPIT\" \"*TOOL*\" :function)~%(:name \"SANDPIT\" \"FILL\" :function)~%~
                         (:name \"SANDPIT\" \"*DEPTH*\" :variable)~%(:value \"SANDPIT\" \"*DEPTH*\" \"7\")~%~
                         (:name \"SANDPIT\" \"*SAME*\" :variable)~%(:value \"SANDPIT\" \"*SAME*\" \"(1 2)\")~%~
                         (:name \"SANDPIT\" \"*TOOL*\" :variable)~%~
                         (:name \"SANDPIT\" \"*GONE*\" :variable)~%~
                         (:name \"SANDPIT\" \"*FOUND*\" :variable)~%(:value \"SANDPIT\" \"*FOUND*\" \"(\\\"a\\\" #\\\\b SHELL)\")~%~
                         (:name \"SANDPIT\" \"*BROKEN*\" :variable)~%(:value \"SANDPIT\" \"*BROKEN*\" \"(1 2\")~%~
                         (:name \"NOWHERE\" \"THING\" :variable)~%(:value \"NOWHERE\" \"THING\" \"1\")~%~
                         (:name \"COMMON-LISP-USER\" \"NEVER-DEFINED-HERE\" :function)~%~
                         (:value \"SANDPIT\" 5 \"1\")~%(:name 5)~%")
            (list "defined.lisp" (format nil "(defpackage \"SANDPIT\" (:use \"COMMON-LISP\"))~%~
                                              (cl:in-package \"SANDPIT\")~%~
                                              (defun dig () 'deeper)~%(defvar *depth* 0)~%(defvar *same* (list 1 2))~%~
                                              (defvar *tool* (list 'a 'spade))~%")))
(when (find-package "SANDPIT")
  (delete-package "SANDPIT"))
(clara.system::keep "a line that was said of the world before this one")
(let ((said (said-by-all #'clara.system:start)))
  (check (format nil "system: this is ClaraOS 0.0.1-new, on trial: the system before it is still in place~%~
                      system: 0.0.1-new has come to its prompt, and is the system of this machine from here on~%~
                      world: made anew by ClaraOS 0.0.1-new, of its files and of what /home/ holds as text~%~
                      home: /home/defined.lisp is loaded, 6 forms~%~
                      world: 2 variables have the values that they had come to in the world before:~%~
                      world:   SANDPIT::*DEPTH*, SANDPIT::*FOUND*~%~
                      world: 1 variable held what is no text, and is as its form makes it here:~%~
                      world:   SANDPIT::*TOOL*~%~
                      world: 7 names that the world before had are not defined in this one:~%~
                      world:   SANDPIT::DIG (a variable), SANDPIT::*TOOL*, SANDPIT::FILL, SANDPIT::*GONE* (a variable)~%~
                      world:   SANDPIT::*BROKEN* (a variable), NOWHERE::THING (a variable), NEVER-DEFINED-HERE~%~
                      world: it is saved as it is now, and the next start is in it; (clara.system:report) says this again~%")
         said)
  ;; All of it but the system's two lines is said again when it is asked for.
  (check (subseq said (search "world: made anew" said)) (said-by #'clara.system:report)))
(check '(7 ("a" #\b cl-user::shell) (1 2) (a spade) deeper)
       (list (symbol-value (find-symbol "*DEPTH*" "SANDPIT")) (symbol-value (find-symbol "*FOUND*" "SANDPIT"))
             (symbol-value (find-symbol "*SAME*" "SANDPIT"))
             (mapcar (lambda (symbol) (intern (symbol-name symbol) "CLARA.TESTS")) (symbol-value (find-symbol "*TOOL*" "SANDPIT")))
             (intern (symbol-name (funcall (find-symbol "DIG" "SANDPIT"))) "CLARA.TESTS")))
(check '("the world that was made again" nil nil t t)
       (list (on-disk *machine-disk* "/clara/clara.image") (on-disk *machine-disk* "/clara/carried")
             (on-disk *machine-disk* "/clara/starts") (in-order-p *machine-disk*) clara.system::*follows*))
;; An account that was written for another system is not this one's, and
;; one that says nothing of the old world's names says that all are here.
(trial-disk (format nil "(:carried \"0.0.0-host\" \"0.0.9-another\")~%(:name \"COMMON-LISP-USER\" \"NEVER-DEFINED-HERE\" :function)~%"))
(check t (let ((said (said-by-all #'clara.system:start)))
           (and (search "world: the system before this one left no account of its world" said)
                (not (search "NEVER-DEFINED-HERE" said)))))
(check nil (on-disk *machine-disk* "/clara/carried"))
(trial-disk (format nil "(:carried \"0.0.0-host\" \"0.0.1-new\")~%(:name \"COMMON-LISP\" \"CAR\" :function)~%"))
(check t (and (search (format nil "world: every function and every variable that the world before had is defined in this one~%")
                      (said-by-all #'clara.system:start))
              t))
(dolist (none (list "this is no account (" (format nil "(:name \"COMMON-LISP-USER\" \"NEVER-DEFINED-HERE\" :function)~%") ""))
  (trial-disk none)
  (check t (and (search "world: the system before this one left no account of its world" (said-by-all #'clara.system:start)) t)))
;; A world that cannot be saved, here one that the disk has no room for,
;; says so, and the start comes to its prompt.
(trial-disk nil)
(clara.host:set-heap-image (make-array (+ (clara.fat:free-bytes) 200000) :element-type '(unsigned-byte 8) :initial-element 0))
(check t (and (search (format nil "world: it is saved as it is now, and the next start is in it; (clara.system:report) says this again~%~
                                   world: no, it could not be saved: ")
                      (said-by-all #'clara.system:start))
              t))
(check '(nil t) (list (on-disk *machine-disk* "/clara/starts") (in-order-p *machine-disk*)))

;; The window manager, when the account says that it was running, is
;; started before the text is loaded, so that a form of the text which
;; opens a window can. On a machine without a screen that is said. And an
;; account that does not speak of it leaves it as it is.
(dolist (screen '(nil t))
  (trial-disk (format nil "(:carried \"0.0.0-host\" \"0.0.1-new\")~%(:windows)~%")
              (list "init.lisp" "(push (clara.windows:running-p) clara.tests::*order*)"))
  (when screen
    (new-desk :machine nil :start nil))
  (setq *order* nil)
  (let ((said (said-by-all #'clara.system:start)))
    (check (list (list screen) screen (not screen))
           (list *order* (clara.windows:running-p)
                 (and (search "world: the window manager was running in the world before, and could not be started in this one"
                              said)
                      t))))
  (clara.windows:stop))
(trial-disk (format nil "(:carried \"0.0.0-host\" \"0.0.1-new\")~%")
            (list "init.lisp" "(push (clara.windows:running-p) clara.tests::*order*)"))
(new-desk :machine nil :start nil)
(setq *order* nil)
(said-by-all #'clara.system:start)
(check '((nil) nil) (list *order* (clara.windows:running-p)))

;; A world that came back as an image takes what the two files have that
;; it has not: what was defined after it was saved, and what somebody
;; wrote into a file since. A form that it has is not evaluated again.
(one-disk (home-tree (list "init.lisp" (format nil "(push :init clara.tests::*order*)~%"))
                     (list "defined.lisp" (format nil "(push :one clara.tests::*order*)~%~%(cl:in-package \"CLARA.TESTS\")~%~
                                                       (push :two clara.tests::*order*)~%"))))
(clara.host:set-start-state)
(setq *order* nil)
(said-by-all #'clara.system:start)
(check '((:init :one :two) t) (list (reverse *order*) clara.system::*follows*))
(clara.host:set-start-state :resumed t)
(setq *order* nil)
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(check nil *order*)
;; The files change on the disk, as they do when a machine goes on after
;; its world was saved and is then stopped without saving.
(clara.system::write-text "/home/defined.lisp"
                          (format nil ";; a comment that is new~%(push :one clara.tests::*order*)~%(push :one-and-a-half clara.tests::*order*)~%~%~
                                       (cl:in-package \"CLARA.TESTS\")~%(push :two clara.tests::*order*)~%~
                                       (push (list :three (package-name *package*)) *order*)~%~
                                       (error \"a new form that fails\")~%(cl:in-package \"COMMON-LISP-USER\")~%~
                                       (push :two clara.tests::*order*)~%"))
(clara.system::write-text "/home/init.lisp" (format nil "(push :init clara.tests::*order*)~%   ~%"))
(check (format nil "system: this is ClaraOS 0.0.0-host~%~
                    home: /home/defined.lisp has 3 forms that this world did not have, which are loaded now, and 1 was passed over:~%~
                    home:   (error \"a new form that fails\")~%home:     a new form that fails~%")
       (said-by-all #'clara.system:start))
;; (The last of them is a form that the world has, word for word, in another package.)
(check '(:one-and-a-half (:three "CLARA.TESTS") :two) (reverse *order*))
;; Nothing is new the next time, and a world that was made without the text takes none of it.
(setq *order* nil)
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(clara.system::write-text "/home/defined.lisp" (format nil "(push :unasked clara.tests::*order*)~%"))
(setq clara.system::*follows* nil)
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(check nil *order*)
(setq clara.system::*follows* t)
(check (format nil "system: this is ClaraOS 0.0.0-host~%~
                    home: /home/defined.lisp has 1 form that this world did not have, which is loaded now~%")
       (said-by-all #'clara.system:start))
(check '(:unasked) *order*)
;; What a listener writes down the world has, and does not load again. A
;; form that somebody wrote into the file in between it has not: that one
;; is loaded at the next start, and the form that was typed with it.
(setq *order* nil)
(clara.system::record '(defvar *typed-here* (push :typed clara.tests::*order*)) "(defvar *typed-here* (push :typed clara.tests::*order*))"
                      "COMMON-LISP-USER")
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(clara.system::write-text "/home/defined.lisp"
                          (concatenate 'string (on-disk *machine-disk* "/home/defined.lisp")
                                       (format nil "(push :by-hand clara.tests::*order*)~%")))
(clara.system::record '(defvar *typed-later* 1) "(defvar *typed-later* (push :typed-later clara.tests::*order*))" "COMMON-LISP-USER")
(check t (and (search "home: /home/defined.lisp has 2 forms that this world did not have, which are loaded now"
                      (said-by-all #'clara.system:start))
              t))
(check '(:by-hand :typed-later) (reverse *order*))
;; A file that is there for the first time is the world's when a listener made it.
(one-disk (machine-tree))
(clara.host:set-start-state)
(said-by-all #'clara.system:start)
(setq *order* nil)
(clara.system::record '(defvar *first-of-all* 1) "(defvar *first-of-all* (push :first-of-all clara.tests::*order*))" "COMMON-LISP-USER")
(clara.host:set-start-state :resumed t)
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(check nil *order*)

;; A world that is made knows nothing of a text that another world had:
;; a file that is written later with the very words of one that the world
;; before had loaded is new to it.
(one-disk (home-tree (list "init.lisp" "(push :of-the-world-before clara.tests::*order*)")))
(clara.host:set-start-state)
(said-by-all #'clara.system:start)
(one-disk (machine-tree))
(said-by-all #'clara.system:start)
(clara.system::write-text "/home/init.lisp" "(push :of-the-world-before clara.tests::*order*)")
(clara.host:set-start-state :resumed t)
(setq *order* nil)
(check t (and (search "home: /home/init.lisp has 1 form that this world did not have, which is loaded now"
                      (said-by-all #'clara.system:start))
              t))
(check '(:of-the-world-before) *order*)

;; A form that says which package the next ones are read in, and fails:
;; those are passed over, up to the next such form, since they would be
;; read in a package that they were not written for.
(one-disk (home-tree (list "defined.lisp" (format nil "(cl:in-package \"NO-SUCH-PACKAGE-ANYWHERE\")~%~
                                                       (push :in-the-wrong-package clara.tests::*order*)~%(defun lost () 1)~%~
                                                       (cl:in-package \"CLARA.TESTS\")~%(push :in-the-right-one *order*)~%"))))
(clara.host:set-start-state)
(setq *order* nil)
(let ((said (said-by-all #'clara.system:start)))
  (check t (and (search "home: /home/defined.lisp is loaded, 2 forms of it, and 3 were passed over:" said)
                (search (format nil "home:   (push :in-the-wrong-package clara.tests::*order*)~%~
                                     home:     its package, NO-SUCH-PACKAGE-ANYWHERE, is not there~%")
                        said)
                (search (format nil "home:   (defun lost () 1)~%home:     its package, NO-SUCH-PACKAGE-ANYWHERE, is not there~%") said)
                t)))
(check '(:in-the-right-one) *order*)

;; A saved world that did not come to its prompt is passed over by the
;; handoff, and a world is made in its place. The first time the saved one
;; is kept, with a note of which it was, and the next start tries it again;
;; the second time, the world that was made takes its place.
(one-disk (home-tree (list "init.lisp" "(push :made-anew clara.tests::*order*)")))
(clara.host:set-start-state :starts 1 :passed-over t)
(clara.host:set-heap-image (octets "a world made in the place of one that did not start"))
(setq *order* nil)
(check (format nil "system: this is ClaraOS 0.0.0-host~%home: /home/init.lisp is loaded, 1 form~%~
                    world: the world that was saved did not come to its prompt at the start before this one.~%~
                    world:   It is kept, and the next start tries it once more; this world is of the files and of /home/~%")
       (said-by-all #'clara.system:start))
(check '("the world that the old system saved" t t)
       (list (on-disk *machine-disk* "/clara/clara.image") (and (on-disk *machine-disk* "/clara/passed") t) (in-order-p *machine-disk*)))
(check (format nil "system: this is ClaraOS 0.0.0-host~%home: /home/init.lisp is loaded, 1 form~%~
                    world: the world that was saved did not come to its prompt a second time: this one takes its place~%~
                    world: it is saved as it is now, and the next start is in it; (clara.system:report) says this again~%")
       (said-by-all #'clara.system:start))
(check '("a world made in the place of one that did not start" nil t)
       (list (on-disk *machine-disk* "/clara/clara.image") (on-disk *machine-disk* "/clara/passed") (in-order-p *machine-disk*)))
;; What tells one saved world from another is how long its file is and
;; where the file begins: a world that is saved over another of the same
;; length begins elsewhere.
(flet ((numbers ()
         (let* ((identity (clara.system::image-identity)) (space (position #\Space identity)))
           (list (parse-integer identity :end space) (parse-integer identity :start (1+ space))))))
  (let ((first (numbers)))
    (clara.host:set-heap-image (octets "a world of just the same length as the first one is"))
    (clara:save-image)
    (let ((second (numbers)))
      (clara.host:set-heap-image (octets "and one that is a little longer than that, by a few words"))
      (clara:save-image)
      (check '(51 51 57 nil) (list (first first) (first second) (first (numbers)) (= (second first) (second second)))))))
(clara.host:set-heap-image (octets "a world made in the place of one that did not start"))
(clara:save-image)
;; Another saved world than the one that was noted is passed over for the
;; first time: one that is as long and begins elsewhere, and one that
;; begins there and is not as long.
(let* ((identity (clara.system::image-identity))
       (space (position #\Space identity))
       (size (parse-integer identity :end space)) (cluster (parse-integer identity :start (1+ space))))
  (dolist (other (list (format nil "~D ~D" size (1+ cluster)) (format nil "~D ~D" (1+ size) cluster)))
    (clara.system::write-text "/clara/passed" other)
    (check t (and (search "world:   It is kept, and the next start tries it once more" (said-by-all #'clara.system:start)) t))
    (check (list "a world made in the place of one that did not start" (format nil "~A~%" identity))
           (list (on-disk *machine-disk* "/clara/clara.image") (on-disk *machine-disk* "/clara/passed")))))
;; A saved world that comes to its prompt after all was not the reason, and the note goes.
(clara.host:set-start-state :resumed t)
(said-by-all #'clara.system:start)
(check nil (on-disk *machine-disk* "/clara/passed"))
;; With no saved world on the disk there is nothing to keep or to replace.
(one-disk (let ((tree (machine-tree)))
            (setf (second (second tree)) (remove "clara.image" (second (second tree)) :key #'car :test #'equal))
            tree))
(clara.host:set-start-state :starts 1 :passed-over t)
(check (format nil "system: this is ClaraOS 0.0.0-host~%") (said-by-all #'clara.system:start))
(check '(nil nil) (list (on-disk *machine-disk* "/clara/passed") (on-disk *machine-disk* "/clara/clara.image")))

;;; The network (lisp/net.lisp): a machine with a network card, and at the
;;; other end of its wire a network that the tests make up. It knows which
;;; card has an address (ARP), gives the machine an address (DHCP), knows
;;; names (DNS), answers when it is asked whether it is there and says
;;; when something cannot be reached (ICMP), and has a web server, with as
;;; much of TCP under it as a server needs, and a port where everything
;;; that the machine sends is taken and kept. It holds every frame that
;;; the machine sends against the checksums that the protocols want,
;;; worked out here in another way; and it can be told to lose, spoil and
;;; mix up what it sends, and to lose what it is sent, as a wire does. It
;;; has a thread of its own: a network does not wait for the machine.

(defun be (bytes offset size)
  (let ((value 0))
    (dotimes (i size value)
      (setq value (+ (* 256 value) (aref bytes (+ offset i)))))))

(defun (setf be) (value bytes offset size)
  (dotimes (i size value)
    (setf (aref bytes (+ offset i)) (ldb (byte 8 (* 8 (- size i 1))) value))))

;; The bytes from START to END added up two at a time, the first of two
;; being the higher half, with what gathers above sixteen bits added back
;; in below, and MORE added to it.
(defun wire-sum (bytes start end &optional (more 0))
  (let ((sum more))
    (loop for i from start below end by 2
          do (incf sum (+ (ash (aref bytes i) 8) (if (< (1+ i) end) (aref bytes (1+ i)) 0))))
    (loop while (> sum #xffff)
          do (setq sum (+ (logand sum #xffff) (ash sum -16))))
    sum))

(defun around-sum (from to protocol bytes)
  (+ (ash from -16) (logand from #xffff) (ash to -16) (logand to #xffff) protocol bytes))

(defun bytes-of (&rest parts)
  (let ((bytes (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer t)))
    (dolist (part parts (coerce bytes '(simple-array (unsigned-byte 8) (*))))
      (map nil (lambda (byte) (vector-push-extend byte bytes)) part))))

(defun number-bytes (value size)
  (loop for i from (1- size) downto 0 collect (ldb (byte 8 (* 8 i)) value)))

(defstruct network
  vdev thread stopped
  (lock (sb-thread:make-mutex :name "the made-up network")) (wake (sb-thread:make-semaphore))
  inbox                         ; the frames that the machine has sent and that are still to be looked at
  (machine #x525400123456)      ; the machine's card,
  (station #x52550a000202)      ; and the one at the other end of the wire,
  (address #x0a000202)          ; whose address is also the way out and who knows names
  (lease #x0a00020f)            ; the address that it gives the machine
  (names (list (cons "releases.test" #x0a000202)))
  files                         ; what its web server has: ((path . what) ...)
  heard                         ; what the machine did, the last first
  mute                          ; of :arp :dhcp :names :connections, what it does not answer
  refuse                        ; it takes no connection
  nak                           ; it does not give the address that it offered
  names-fail                    ; it cannot say which address a name has
  another-record                ; its answer for a name has another record before the address
  (hosts (list (cons #x0a000209 #x525500000009))) ; other machines on it, each with its card: they serve what it serves
  false-start                   ; a connection's beginning is first answered with something that is no answer to it
  pause                         ; how many seconds it waits after each piece of an answer
  strangers                     ; before each answer about an address or a name it sends one that is for another question
  spoil-names                   ; how many of its answers for a name arrive with a byte changed
  (pieces 0)                    ; how many pieces of answers its web server has sent, the ones sent again among them
  (lose-opening 0)              ; how many of its answers to the beginning of a connection are lost,
  (lose-request 0)              ; how many requests are lost before one arrives,
  drop spoil swap               ; which segments of an answer are lost the first time, arrive with a byte changed, or
                                ; arrive after the one that follows them: by their number in the answer, from 0
  (first #xfffff000)            ; the number that its bytes are counted from on a connection, which soon goes round
  (piece 1460)                  ; how long a segment of an answer is at most
  no-end                        ; it does not say that an answer is over
  (secure (list 443))           ; the ports at which its web server keeps the connection closed (TLS)
  chain                         ; the certificates that it shows there, its own first,
  key                           ; and the key of its own
  accident                      ; what goes wrong on such a connection, of the things that the code below knows to get wrong
  (record 1200)                 ; how many bytes of an answer it closes in one record
  (lease-time 86400)            ; for how many seconds it gives the machine its address
  renewals                      ; asked whether the machine may keep its address, it says no (:deny), or nothing (:mute)
  unreachable                   ; the way out says of every connection that begins, and of every ping, that the other machine
                                ; cannot be reached; :forged, when it says so of a connection with another number than the machine's
  narrow                        ; how long a packet may be on the way, when that is less than the machine thinks: a longer
                                ; one does not arrive, and the machine is told
  names-closed                  ; the name servers at which nothing takes questions, by their addresses, or T for all of them
  cut                           ; an answer about a name comes cut short by UDP, and whole only by TCP
  (ttl 60)                      ; for how many seconds what it says of a name holds
  (room 65535)                  ; how many bytes its machines say that they have room for
  (longest 1460)                ; how long a segment its machines say that they take, as a connection begins; NIL when they do not say
  sunk                          ; what the machine has sent to the port 9, where everything is taken and nothing answered
  lose-pieces                   ; which of the segments with bytes in them from the machine are lost: by their count, from 0
  (seen 0)                      ; how many such segments have come,
  (longest-seen 0)              ; and how many bytes the longest of them carried
  calls                         ; the connections that machines of the network have opened to the machine
  connections)

;; A connection that a machine of the network opens to a port of the
;; machine's: it begins, says what it has to say, takes what the machine
;; says, and ends, with whatever a test wants to go wrong.
(defstruct call
  network
  port                          ; the port of the machine's that it is to,
  from-port                     ; the port that it is from,
  (address #x0a000202) station  ; and the machine of the network that it is from, with its card when that is not the network's own
  (state :new)                  ; :new, :asked while the machine has not answered, :open, :refused, :reset
  (first 7000)                  ; the number that its bytes are counted from
  theirs                        ; the number of the machine's next byte
  (say (octets ""))             ; what it says, once it is open
  (sent 0) (heard 0)            ; how many bytes of that went out, and how many the machine says that it has
  end ended end-heard           ; it is to say that it is done when the machine has all of that; it has; the machine knows
  (got (bytes-of))              ; what the machine has said
  done                          ; the machine has said that it is done
  (moment 0)
  (room 65535)                  ; how many bytes it says that it has room for
  (window 65535)                ; how many the machine says that it has room for
  (piece 1000)                  ; how long a segment of it is at most
  (longest 1460)                ; how long a segment it says that it takes
  (begun 1)                     ; how many times it has begun
  answers                       ; the numbers that the machine's answers to its beginning had
  (lose-answers 0)              ; how many of those answers it does not hear
  half                          ; it begins, and does not go on when the machine answers
  mute                          ; it says nothing to what the machine sends
  lose                          ; which of the machine's segments with bytes in them it does not hear: by their count, from 0
  (pieces 0))                   ; how many such segments have come

(defvar *calls* 0)

(defun call-next (call)
  (+ (call-first call) 1 (call-sent call) (if (call-ended call) 1 0)))

;; A segment of a call's, for the machine.
(defun call-segment (call number flags data)
  (let* ((network (call-network call)) (from (call-address call)) (to (network-lease network))
         (*from-station* (call-station call))
         (says (and (logbitp 1 flags) (call-longest call)))
         (segment (bytes-of (number-bytes (call-from-port call) 2) (number-bytes (call-port call) 2)
                            (number-bytes (ldb (byte 32 0) number) 4) (number-bytes (or (call-theirs call) 0) 4)
                            (list (if says #x60 #x50) flags) (number-bytes (call-room call) 2) (list 0 0 0 0)
                            (and says (list 2 4)) (and says (number-bytes says 2)) data)))
    (setf (be segment 16 2)
          (logxor #xffff (wire-sum segment 0 (length segment) (around-sum from to 6 (length segment)))))
    (packet-to-machine network from to 6 segment)))

;; What a call does next: it begins, and begins again when the machine
;; says nothing; once it is open it says what it has to say, as far as the
;; machine has room, and again from where the machine has it when nothing
;; was heard for a while; and then it says that it is done, when it is to.
(defun call-step (call)
  (let ((now (get-internal-real-time)) (wait (* 0.15 internal-time-units-per-second)))
    (case (call-state call)
      (:new
       (setf (call-state call) :asked
             (call-moment call) now)
       (call-segment call (call-first call) #x02 nil))
      (:asked
       (when (and (not (call-half call)) (> (- now (call-moment call)) wait))
         (setf (call-moment call) now)
         (incf (call-begun call))
         (call-segment call (call-first call) #x02 nil)))
      (:open
       (let ((say (call-say call)))
         (when (and (< (call-heard call) (call-sent call)) (> (- now (call-moment call)) wait))
           (setf (call-sent call) (call-heard call)
                 (call-moment call) now))
         (loop while (and (< (call-sent call) (length say))
                          (< (- (call-sent call) (call-heard call)) (min (call-window call) (* 8 (call-piece call)))))
               do (let* ((start (call-sent call))
                         (end (min (length say) (+ start (call-piece call)) (+ (call-heard call) (call-window call)))))
                    (when (= start (call-heard call))
                      (setf (call-moment call) now))
                    (call-segment call (+ (call-first call) 1 start) #x18 (subseq say start end))
                    (setf (call-sent call) end)))
         (when (and (call-end call) (not (call-ended call)) (= (call-heard call) (length say)))
           (call-segment call (+ (call-first call) 1 (length say)) #x11 nil)
           (setf (call-ended call) t)))))))

;; A segment from the machine that belongs to a call.
(defun call-heard-segment (call frame)
  (let* ((at 34) (whole (- (be frame 16 2) 20)) (header (* 4 (ash (aref frame (+ at 12)) -4)))
         (number (be frame (+ at 4) 4)) (arrived (be frame (+ at 8) 4)) (flags (aref frame (+ at 13)))
         (data (subseq frame (+ at header) (+ at whole))) (network (call-network call)))
    (setf (call-window call) (be frame (+ at 14) 2))
    (cond ((logbitp 2 flags)
           (network-note network :call-given-up (call-port call))
           (setf (call-state call) (if (eq (call-state call) :asked) :refused :reset)))
          ((eq (call-state call) :asked)
           (when (and (= (logand flags #x12) #x12) (= arrived (ldb (byte 32 0) (1+ (call-first call)))))
             (unless (and (= header 24) (= (aref frame (+ at 20)) 2) (= (be frame (+ at 22) 2) 1460))
               (failed "the machine answers the beginning of a connection without saying how long a segment may be"))
             (push number (call-answers call))
             (cond ((plusp (call-lose-answers call))
                    (decf (call-lose-answers call)))
                   ((call-half call))
                   (t
                    (setf (call-theirs call) (ldb (byte 32 0) (1+ number))
                          (call-state call) :open)
                    (call-segment call (+ (call-first call) 1) #x10 nil)))))
          ((eq (call-state call) :open)
           (when (logbitp 4 flags)
             (let ((got (ldb (byte 32 0) (- arrived (call-first call) 1))))
               (cond ((and (call-ended call) (= got (1+ (length (call-say call)))))
                      (setf (call-end-heard call) t))
                     ((and (<= got (length (call-say call))) (> got (call-heard call)))
                      (setf (call-heard call) got
                            (call-moment call) (get-internal-real-time))))))
           (unless (call-mute call)
             (when (plusp (length data))
               (incf (call-pieces call))
               (when (> (length data) (or (call-longest call) 536))
                 (failed "the machine sent a segment of ~D bytes to a machine that takes ~D" (length data) (call-longest call)))
               (cond ((member (1- (call-pieces call)) (call-lose call)))
                     ((= number (call-theirs call))
                      (sb-thread:with-mutex ((network-lock network))
                        (setf (call-got call) (bytes-of (call-got call) data)))
                      (setf (call-theirs call) (ldb (byte 32 0) (+ number (length data))))
                      (call-segment call (call-next call) #x10 nil))
                     (t
                      (call-segment call (call-next call) #x10 nil))))
             (when (logbitp 0 flags)
               (when (= (ldb (byte 32 0) (+ number (length data))) (call-theirs call))
                 (setf (call-theirs call) (ldb (byte 32 0) (1+ (call-theirs call)))
                       (call-done call) t))
               (call-segment call (call-next call) #x10 nil)))))))

;; A machine of the network calls the machine at PORT.
(defun call-machine (port &rest options)
  (let ((call (apply #'make-call :network *network* :port port :from-port (+ 40000 (incf *calls*)) options)))
    (when (stringp (call-say call))
      (setf (call-say call) (octets (call-say call))))
    (sb-thread:with-mutex ((network-lock *network*))
      (push call (network-calls *network*)))
    (sb-thread:signal-semaphore (network-wake *network*))
    call))

;; What the machine has said on a call, as text.
(defun call-text (call)
  (sb-ext:octets-to-string (sb-thread:with-mutex ((network-lock (call-network call))) (copy-seq (call-got call)))
                           :external-format :utf-8))

(defstruct served
  port to-port state theirs first request answer
  address station                ; the machine of the network that the connection is to, and its card
  end-heard                      ; the machine has said that it knows the answer to be over
  (sent 0) (heard 0)            ; of the answer: how many bytes went out, and how many the machine says it has
  ended (moment 0) (same 0) (window 65535)
  again                         ; the piece that was sent a second time because the machine said three times that it lacks it
  secure                        ; what the network keeps of a connection that is kept closed
  more                          ; more is to come after what there is of the answer: it is not said to be over
  dropped spoiled swapped held)

(defvar *network* nil)
(defvar *numbers* nil)         ; the device of the machine that makes numbers which nobody can guess, when it has one

(defun network-note (network &rest what)
  (sb-thread:with-mutex ((network-lock network))
    (push what (network-heard network))))

(defun network-saw (network what)
  (sb-thread:with-mutex ((network-lock network))
    (count what (network-heard network) :key #'car)))

;; A frame for the machine: it waits for the card to have a page for it,
;; which the driver gives back as soon as it has taken the frame before.
(defun network-send (network frame)
  (let ((frame (if (< (length frame) 60)
                   (bytes-of frame (make-list (- 60 (length frame)) :initial-element 0))
                   frame)))
    (loop repeat 3000
          do (when (network-stopped network)
               (return))
             (when (arrive-on-wire (network-vdev network) frame)
               (return t))
             (sleep 0.001)
          finally (failed "the driver left the network card no page for a frame in three seconds"))))

(defvar *from-station* nil)    ; the card that a frame for the machine is from, when it is not the network's own

(defun frame-to-machine (network kind &rest parts)
  (network-send network (apply #'bytes-of (number-bytes (network-machine network) 6)
                               (number-bytes (or *from-station* (network-station network)) 6)
                               (number-bytes kind 2) parts)))

(defun packet-to-machine (network from to protocol &rest parts)
  (let* ((inside (apply #'bytes-of parts))
         (header (bytes-of (list #x45 0) (number-bytes (+ 20 (length inside)) 2) (list 0 0 #x40 0 64 protocol 0 0)
                           (number-bytes from 4) (number-bytes to 4))))
    (setf (be header 10 2) (logxor #xffff (wire-sum header 0 20)))
    (frame-to-machine network #x0800 header inside)))

(defun datagram-to-machine (network from to from-port to-port &rest parts)
  (let* ((inside (apply #'bytes-of parts))
         (datagram (bytes-of (number-bytes from-port 2) (number-bytes to-port 2) (number-bytes (+ 8 (length inside)) 2) (list 0 0)
                             inside)))
    (setf (be datagram 6 2)
          (logxor #xffff (wire-sum datagram 0 (length datagram) (around-sum from to 17 (length datagram)))))
    (packet-to-machine network from to 17 datagram)))

;; A message of ICMP's for the machine: its kind, which of that kind, a
;; checksum, the four bytes that the kind has its own use for, and what
;; it carries.
(defun control-to-machine (network from to kind code word &rest parts)
  (let ((message (apply #'bytes-of (list kind code 0 0) (number-bytes word 4) parts)))
    (setf (be message 2 2) (logxor #xffff (wire-sum message 0 (length message))))
    (packet-to-machine network from to 1 message)))

;; A segment for the machine, with a byte of what it carries changed after
;; the checksum was worked out when SPOILED says so. One that begins a
;; connection says how long a segment may be, unless the network has no
;; such number.
(defun segment-to-machine (network connection number flags data &optional spoiled)
  (when (plusp (length data))
    (incf (network-pieces network)))
  (let* ((from (or (served-address connection) (network-address network))) (to (network-lease network))
         (*from-station* (served-station connection))
         (says (and (logbitp 1 flags) (network-longest network)))
         (segment (bytes-of (number-bytes (served-to-port connection) 2) (number-bytes (served-port connection) 2)
                            (number-bytes (ldb (byte 32 0) number) 4) (number-bytes (served-theirs connection) 4)
                            (list (if says #x60 #x50) flags) (number-bytes (network-room network) 2) (list 0 0 0 0)
                            (and says (list 2 4)) (and says (number-bytes says 2)) data)))
    (setf (be segment 16 2)
          (logxor #xffff (wire-sum segment 0 (length segment) (around-sum from to 6 (length segment)))))
    (when spoiled
      (setf (aref segment (1- (length segment))) (logxor 1 (aref segment (1- (length segment))))))
    (packet-to-machine network from to 6 segment)))

(defun lines-bytes (&rest lines)
  (octets (format nil "~{~A~C~C~}~C~C" (loop for line in lines append (list line (code-char 13) (code-char 10)))
                  (code-char 13) (code-char 10))))

;; What the web server says to a request for a path.
(defun network-answer (network path)
  (let ((what (cdr (assoc path (network-files network) :test #'string=))))
    (cond ((null what)
           (bytes-of (lines-bytes "HTTP/1.1 404 Not Found" "Content-Length: 9" "Connection: close") (octets "not here.")))
          ((and (consp what) (eq (car what) :unsized))
           (bytes-of (lines-bytes "HTTP/1.0 200 OK") (octets (second what))))
          ((and (consp what) (eq (car what) :short))
           (bytes-of (lines-bytes "HTTP/1.1 200 OK" (format nil "content-length:   ~D" (+ 100 (length (octets (second what))))))
                     (octets (second what))))
          ((and (consp what) (eq (car what) :moved))
           (lines-bytes "HTTP/1.1 301 Moved Permanently" (format nil "Location: ~A" (second what)) "Content-Length: 0"))
          ((and (consp what) (eq (car what) :status))
           (lines-bytes (format nil "HTTP/1.1 ~D Something" (second what)) "Content-Length: 0"))
          ((and (consp what) (eq (car what) :raw))
           (octets (second what)))
          ((and (consp what) (eq (car what) :chunked))
           ;; in chunks of 1, 2, 3 and so on, each with its length in base sixteen before it, in either kind of letter
           (let ((bytes (octets (second what))) (parts (list (lines-bytes "HTTP/1.1 200 OK" "Transfer-Encoding: Chunked"))) (at 0) (size 1))
             (loop while (< at (length bytes))
                   do (let ((end (min (length bytes) (+ at size))))
                        (push (octets (format nil (if (evenp size) "~X;with=more~C~C" "~(~X~)~C~C") (- end at) (code-char 13) (code-char 10))) parts)
                        (push (subseq bytes at end) parts)
                        (push (list 13 10) parts)
                        (setq at end
                              size (* size 3))))
             (unless (third what)
               (push (octets (format nil "0~C~C~C~C" (code-char 13) (code-char 10) (code-char 13) (code-char 10))) parts))
             (apply #'bytes-of (reverse parts))))
          (t
           (bytes-of (lines-bytes "HTTP/1.1 200 OK" "Server: made up" (format nil "Content-Length: ~D" (length (octets what)))
                                  "Connection: close")
                     (octets what))))))

;; As much of an answer goes out as the machine has room for, in segments,
;; each with the accident that the test wants it to have the first time;
;; and after the last one the word that the answer is over.
(defun network-say (network connection)
  (let ((answer (served-answer connection)) (piece (network-piece network)))
    (when answer
      (loop while (and (< (served-sent connection) (length answer))
                       (< (- (served-sent connection) (served-heard connection)) (min (served-window connection) (* 12 piece))))
            do (let* ((start (served-sent connection)) (end (min (length answer) (+ start piece))) (index (floor start piece))
                      (number (+ (served-first connection) 1 start)) (data (subseq answer start end))
                      (flags (if (= end (length answer)) #x18 #x10)))
                 (setf (served-sent connection) end)
                 (cond ((and (member index (network-drop network)) (not (member index (served-dropped connection))))
                        (push index (served-dropped connection)))
                       ((and (member index (network-spoil network)) (not (member index (served-spoiled connection))))
                        (push index (served-spoiled connection))
                        (segment-to-machine network connection number flags data t))
                       ((and (member index (network-swap network)) (not (member index (served-swapped connection))))
                        (push index (served-swapped connection))
                        (setf (served-held connection) (list number flags data)))
                       (t
                        (segment-to-machine network connection number flags data)
                        (when (served-held connection)
                          (apply #'segment-to-machine network connection (served-held connection))
                          (setf (served-held connection) nil))))
                 (when (network-pause network)
                   (sleep (network-pause network)))))
      (when (and (served-held connection) (= (served-sent connection) (length answer)))
        (apply #'segment-to-machine network connection (served-held connection))
        (setf (served-held connection) nil))
      (when (and (= (served-sent connection) (length answer)) (not (served-ended connection)) (not (network-no-end network))
                 (not (served-more connection)))
        (setf (served-ended connection) t)
        (segment-to-machine network connection (+ (served-first connection) 1 (length answer)) #x11 nil)))))

;; What the web server answers to what the machine has asked of it so far:
;; NIL until all of a request is there.
(defun network-request (network connection bytes)
  (let* ((request (sb-ext:octets-to-string bytes :external-format :latin-1))
         (end (search (format nil "~C~C~C~C" (code-char 13) (code-char 10) (code-char 13) (code-char 10)) request)))
    (when (and (null end) (>= (length request) 4) (string/= (subseq request 0 4) "GET "))
      ;; what is no request at all, the beginning of a greeting for one, is answered as a web server answers it
      (return-from network-request (lines-bytes "HTTP/1.1 400 Bad Request" "Content-Length: 0" "Connection: close")))
    (when end
      (let ((path (subseq request 4 (search " HTTP/1.1" request)))
            (port (served-to-port connection)))
        (unless (and (string= (subseq request 0 4) "GET ") (search "Host: " request)
                     (search "Connection: close" request) (search "User-Agent: ClaraOS/" request))
          (failed "the machine asks a web server in a way that is not HTTP's: ~S" request))
        ;; the port is named after the machine's name unless it is the one that goes without saying
        (unless (eq (and (search (format nil ":~D~C" port (code-char 13)) request) t)
                    (not (member port '(80 443))))
          (failed "the machine asks a web server at the port ~D and names the port wrongly, or not at all: ~S" port request))
        (network-note network :get path)
        (network-answer network path)))))

;; The name that a question about a name asks for, which begins at START
;; of some bytes, each part with its length before it; and where the zero
;; is that ends it.
(defun name-in (bytes start)
  (let ((labels nil) (place start))
    (loop while (and (< place (length bytes)) (plusp (aref bytes place)))
          do (push (sb-ext:octets-to-string (subseq bytes (1+ place) (+ place 1 (aref bytes place)))) labels)
             (incf place (1+ (aref bytes place))))
    (values (format nil "~{~A~^.~}" (reverse labels)) place)))

;; What whoever knows names says to a question, as the bytes of the
;; answer: the address of the name, with another record before it when a
;; test wants that; that it cannot say; that there is no such name; or,
;; when CUT says so, nothing but the word that the answer was too long.
(defun network-name-answer (network number question name &optional cut)
  (let ((address (cdr (assoc name (network-names network) :test #'string-equal))))
    (cond (cut
           (bytes-of (number-bytes number 2) (list #x83 #x80 0 1 0 0 0 0 0 0) question))
          ((network-names-fail network)
           (bytes-of (number-bytes number 2) (list #x81 #x82 0 1 0 0 0 0 0 0) question))
          (address
           (bytes-of (number-bytes number 2)
                     (list #x81 #x80 0 1 0 (if (network-another-record network) 2 1) 0 0 0 0) question
                     (and (network-another-record network)
                          (list #xc0 #x0c 0 5 0 1 0 0 0 60 0 9 5 97 108 105 97 115 #xc0 #x0c 0))
                     (list #xc0 #x0c 0 1 0 1) (number-bytes (network-ttl network) 4) (list 0 4) (number-bytes address 4)))
          (t
           (bytes-of (number-bytes number 2) (list #x81 #x83 0 1 0 0 0 0 0 0) question)))))

;; A question about a name that came by TCP, with its length before it:
;; the answer, with its length before it, or NIL until all of the
;; question is there.
(defun network-name-request (network bytes)
  (when (and (>= (length bytes) 2) (>= (length bytes) (+ 2 (be bytes 0 2))))
    (let ((message (subseq bytes 2 (+ 2 (be bytes 0 2)))))
      (multiple-value-bind (name place) (name-in message 12)
        (unless (and (= (be message 2 2) #x0100) (= (be message 4 2) 1)
                     (= (be message (1+ place) 2) 1) (= (be message (+ place 3) 2) 1) (= (length message) (+ place 5)))
          (failed "the machine asks for the address of a name by TCP in a way that is not DNS's"))
        (network-note network :name-whole name)
        (let ((answer (network-name-answer network (be message 0 2) (subseq message 12 (+ place 5)) name)))
          (bytes-of (number-bytes (length answer) 2) answer))))))

;; A segment from the machine, for the web server.
(defun network-heard-segment (network frame)
  (let* ((at 34) (whole (- (be frame 16 2) 20)) (header (* 4 (ash (aref frame (+ at 12)) -4)))
         (port (be frame at 2)) (to-port (be frame (+ at 2) 2)) (number (be frame (+ at 4) 4)) (arrived (be frame (+ at 8) 4))
         (flags (aref frame (+ at 13))) (data (subseq frame (+ at header) (+ at whole)))
         (connection (find port (network-connections network) :key #'served-port)))
    (unless (= (wire-sum frame at (+ at whole) (around-sum (be frame 26 4) (be frame 30 4) 6 whole)) #xffff)
      (failed "the machine sent a segment whose checksum is wrong"))
    ;; one that belongs to a connection which a machine of the network opened is that connection's
    (let ((call (find-if (lambda (call)
                           (and (= (call-port call) port) (= (call-from-port call) to-port) (= (call-address call) (be frame 30 4))))
                         (sb-thread:with-mutex ((network-lock network)) (copy-list (network-calls network))))))
      (when call
        (return-from network-heard-segment (call-heard-segment call frame))))
    (cond ((logbitp 2 flags)
           (network-note network :given-up port)
           (setf (network-connections network) (remove connection (network-connections network))))
          ((and (logbitp 1 flags) (not (logbitp 4 flags)))
           (network-note network :connect to-port)
           (unless (and (= header 24) (= (aref frame (+ at 20)) 2) (= (be frame (+ at 22) 2) 1460))
             (failed "the machine begins a connection without saying how long a segment may be"))
           (cond ((member :connections (network-mute network)))
                 ((network-unreachable network)
                  ;; The way out says that no such machine can be reached, with the head of the packet and
                  ;; eight bytes more, as such a word comes: the number of the connection is among them,
                  ;; and is another when the word is to be one that anybody could have sent.
                  (let ((quoted (subseq frame 14 42)))
                    (when (eq (network-unreachable network) :forged)
                      (setf (be quoted 24 4) (ldb (byte 32 0) (+ 77 (be quoted 24 4)))))
                    (control-to-machine network (network-address network) (be frame 26 4) 3 1 0 quoted)))
                 ((network-refuse network)
                  (segment-to-machine network (make-served :port port :to-port to-port :theirs (ldb (byte 32 0) (1+ number))
                                                           :address (be frame 30 4) :station (be frame 0 6))
                                      0 #x14 nil))
                 (t
                  (unless connection
                    (setq connection (make-served :port port :to-port to-port :state :opening
                                                  :theirs (ldb (byte 32 0) (1+ number)) :first (network-first network)
                                                  :address (be frame 30 4) :station (be frame 0 6)))
                    (push connection (network-connections network)))
                  (when (network-false-start network)
                    ;; something that is no answer to the beginning: it says that it has bytes that nobody sent
                    (let ((theirs (served-theirs connection)))
                      (setf (served-theirs connection) (ldb (byte 32 0) (+ theirs 77)))
                      (segment-to-machine network connection 12345 #x10 nil)
                      (setf (served-theirs connection) theirs)))
                  (if (plusp (network-lose-opening network))
                      (decf (network-lose-opening network))
                      (segment-to-machine network connection (served-first connection) #x12 nil)))))
          ((null connection)
           (network-note network :stray port))
          (t
           (setf (served-window connection) (be frame (+ at 14) 2))
           (when (and (eq (served-state connection) :opening) (logbitp 4 flags)
                      (= arrived (ldb (byte 32 0) (1+ (served-first connection)))))
             (setf (served-state connection) :open))
           (when (plusp (length data))
             (let ((index (network-seen network))
                   (beyond (ldb (byte 32 0) (- (+ number (length data)) (served-theirs connection)))))
               (incf (network-seen network))
               (setf (network-longest-seen network) (max (network-longest-seen network) (length data)))
               (cond ((plusp (network-lose-request network))
                      (decf (network-lose-request network)))
                     ((member index (network-lose-pieces network)))
                     ((and (network-narrow network) (> (be frame 16 2) (network-narrow network)))
                      ;; too long for the way: it does not arrive, and the machine is told how long a packet may be
                      (network-note network :too-long (be frame 16 2))
                      (control-to-machine network (network-address network) (be frame 26 4) 3 4 (network-narrow network)
                                          (subseq frame 14 42)))
                     ((and (< beyond #x80000000) (> beyond (network-room network)))
                      ;; More than there is room for. One byte into no room at all is how a machine asks
                      ;; whether there is room again, and is answered; anything else is the machine's mistake.
                      (unless (and (zerop (network-room network)) (= (length data) 1))
                        (failed "the machine sent ~D bytes where the other side had said that it has room for ~D"
                                beyond (network-room network)))
                      (segment-to-machine network connection (+ (served-first connection) 1 (served-sent connection)) #x10 nil))
                     ((= number (served-theirs connection))
                      (setf (served-request connection) (bytes-of (served-request connection) data)
                            (served-theirs connection) (ldb (byte 32 0) (+ number (length data))))
                      (cond ((= (served-to-port connection) 9)
                             (sb-thread:with-mutex ((network-lock network))
                               (setf (network-sunk network) (bytes-of (network-sunk network) data)))
                             (setf (served-request connection) nil))
                            ((member (served-to-port connection) (network-secure network))
                             (tls-heard network connection))
                            (t
                             (let ((answer (and (null (served-answer connection))
                                                (if (= (served-to-port connection) 53)
                                                    (network-name-request network (served-request connection))
                                                    (network-request network connection (served-request connection))))))
                               (when answer
                                 (setf (served-answer connection) answer
                                       (served-moment connection) (get-internal-real-time))))))
                      (segment-to-machine network connection (+ (served-first connection) 1 (served-sent connection)) #x10 nil))
                     (t
                      (segment-to-machine network connection (+ (served-first connection) 1 (served-sent connection)) #x10 nil)))))
           (when (logbitp 0 flags)
             (when (= (ldb (byte 32 0) (+ number (length data))) (served-theirs connection))
               (setf (served-theirs connection) (ldb (byte 32 0) (1+ (served-theirs connection))))
               (network-note network :ended port))
             (segment-to-machine network connection
                                 (+ (served-first connection) 1 (served-sent connection) (if (served-ended connection) 1 0)) #x10 nil))
           (when (and (logbitp 4 flags) (served-answer connection) (served-ended connection) (not (served-end-heard connection))
                      (= arrived (ldb (byte 32 0) (+ (served-first connection) 2 (length (served-answer connection))))))
             (setf (served-end-heard connection) t)
             (network-note network :end-heard port))
           (when (and (logbitp 4 flags) (served-answer connection))
             (let ((got (min (length (served-answer connection))
                             (ldb (byte 32 0) (- arrived (served-first connection) 1)))))
               (cond ((> got (served-heard connection))
                      (setf (served-heard connection) got
                            (served-same connection) 0
                            (served-moment connection) (get-internal-real-time)))
                     ((and (= got (served-heard connection)) (< got (served-sent connection))
                           (zerop (length data)) (not (logbitp 0 flags)))
                      (incf (served-same connection))
                      ;; The machine says three times more that it has no more than before: the one
                      ;; piece that it lacks goes out again, once, as a web server sends it (RFC 5681).
                      ;; Everything after it goes out again when nothing has moved for a while.
                      (when (and (>= (served-same connection) 3) (not (eql (served-again connection) got)))
                        (setf (served-again connection) got)
                        (let ((end (min (length (served-answer connection)) (+ got (network-piece network)))))
                          (segment-to-machine network connection (+ (served-first connection) 1 got) #x10
                                              (subseq (served-answer connection) got end))))))))
           (network-say network connection)))))

;; A packet from the machine that is one of UDP's: a question to the DHCP
;; server, or to whoever knows names.
(defun network-heard-datagram (network frame)
  (let* ((at 34) (whole (be frame (+ at 4) 2)) (from (be frame 26 4)) (to (be frame 30 4))
         (port (be frame at 2)) (to-port (be frame (+ at 2) 2)) (inside (+ at 8)))
    (unless (and (/= (be frame (+ at 6) 2) 0)
                 (= (wire-sum frame at (+ at whole) (around-sum from to 17 whole)) #xffff))
      (failed "the machine sent a packet of UDP's whose checksum is wrong, or that has none"))
    (cond ((= to-port 67)
           (let ((kind nil) (wanted nil) (server nil) (number (be frame (+ inside 4) 4)) (option (+ inside 240))
                 ;; a machine that says which address it has is asking whether it may keep it
                 (keeping (/= (be frame (+ inside 12) 4) 0)))
             (loop while (and (< option (+ at whole)) (/= (aref frame option) 255))
                   do (let ((code (aref frame option)) (length (aref frame (1+ option))))
                        (case code
                          (53 (setq kind (aref frame (+ option 2))))
                          (50 (setq wanted (be frame (+ option 2) 4)))
                          (54 (setq server (be frame (+ option 2) 4))))
                        (incf option (+ 2 length))))
             (unless (and (= port 68) (= (aref frame inside) 1) (= (be frame (+ inside 28) 6) (network-machine network))
                          (= (be frame (+ inside 236) 4) #x63825363) (>= (- whole 8) 300)
                          (if keeping
                              ;; to the server alone, from the address that the machine has and names, and
                              ;; without the two options that name an offer
                              (and (eql kind 3) (= from (network-lease network)) (= to (network-address network))
                                   (= (be frame (+ inside 12) 4) (network-lease network))
                                   (= (be frame 0 6) (network-station network))
                                   (not (logbitp 15 (be frame (+ inside 10) 2))) (null wanted) (null server))
                              (and (= from 0) (= to #xffffffff) (= (be frame 0 6) #xffffffffffff)
                                   (logbitp 15 (be frame (+ inside 10) 2)))))
               (failed "the machine asks for an address in a way that is not DHCP's"))
             (when (and (eql kind 3) (not keeping)
                        (not (and (eql wanted (network-lease network)) (eql server (network-address network)))))
               (failed "the machine takes the address ~S from ~S, which nobody offered it" wanted server))
             (network-note network (if keeping :dhcp-keep :dhcp) kind)
             (unless (or (member :dhcp (network-mute network)) (and keeping (eq (network-renewals network) :mute)))
               (let ((answer (cond ((eql kind 1) 2)
                                   ((or (network-nak network) (and keeping (eq (network-renewals network) :deny))) 6)
                                   (t 5))))
                 (when (network-strangers network)
                   ;; somebody else's answer, and one that is no DHCP: neither is this machine's
                   (datagram-to-machine
                    network (network-address network) #xffffffff 67 68
                    (list 2 1 6 0) (number-bytes (logxor number 1) 4) (list 0 0 #x80 0) (number-bytes 0 4)
                    (number-bytes #x0a000263 4) (number-bytes 0 8) (number-bytes (network-machine network) 6)
                    (make-list 202 :initial-element 0) (number-bytes #x63825363 4)
                    (list 53 1 answer 54 4) (number-bytes (network-address network) 4) (list 255))
                   (datagram-to-machine
                    network (network-address network) #xffffffff 67 68
                    (list 2 1 6 0) (number-bytes number 4) (list 0 0 #x80 0) (number-bytes 0 4)
                    (number-bytes #x0a000264 4) (number-bytes 0 8) (number-bytes (network-machine network) 6)
                    (make-list 202 :initial-element 0) (number-bytes #x12345678 4)
                    (list 53 1 answer 54 4) (number-bytes (network-address network) 4) (list 255)))
                 (datagram-to-machine
                  network (network-address network) (if keeping (network-lease network) #xffffffff) 67 68
                  (list 2 1 6 0) (number-bytes number 4) (list 0 0 (if keeping 0 #x80) 0)
                  (number-bytes (if keeping (network-lease network) 0) 4)
                  (number-bytes (if (= answer 6) 0 (network-lease network)) 4) (number-bytes 0 8)
                  (number-bytes (network-machine network) 6) (make-list 202 :initial-element 0)
                  (number-bytes #x63825363 4)
                  (list 0 53 1 answer 54 4) (number-bytes (network-address network) 4)
                  (list 51 4) (number-bytes (network-lease-time network) 4)
                  (list 1 4 255 255 255 0 3 4) (number-bytes (network-address network) 4)
                  (list 6 8) (number-bytes (network-address network) 4) (number-bytes #x08080808 4) (list 255))))))
          (t
           (multiple-value-bind (name place) (name-in frame (+ inside 12))
             (let ((question (subseq frame (+ inside 12) (+ place 5)))
                   (number (be frame inside 2)))
               (unless (and (= (be frame (+ inside 2) 2) #x0100) (= (be frame (+ inside 4) 2) 1)
                            (= (be frame (1+ place) 2) 1) (= (be frame (+ place 3) 2) 1))
                 (failed "the machine asks for the address of a name in a way that is not DNS's"))
               (network-note network :name name to-port)
               (network-note network :name-asked-of to)
               (unless (member :names (network-mute network))
                 (progn
                   (when (network-strangers network)
                     ;; the answer to another question, and the answer of somebody who was not asked
                     (datagram-to-machine network to from to-port port
                                          (number-bytes (logxor number 1) 2) (list #x81 #x80 0 1 0 1 0 0 0 0) question
                                          (list #xc0 #x0c 0 1 0 1 0 0 0 60 0 4 10 0 2 99))
                     (datagram-to-machine network #x0a000263 from to-port port
                                          (number-bytes number 2) (list #x81 #x80 0 1 0 1 0 0 0 0) question
                                          (list #xc0 #x0c 0 1 0 1 0 0 0 60 0 4 10 0 2 98)))
                   (cond ((plusp (or (network-spoil-names network) 0))
                          (decf (network-spoil-names network))
                          (let* ((inside (bytes-of (number-bytes number 2) (list #x81 #x80 0 1 0 1 0 0 0 0) question
                                                   (list #xc0 #x0c 0 1 0 1 0 0 0 60 0 4 10 0 2 97)))
                                 (datagram (bytes-of (number-bytes to-port 2) (number-bytes port 2)
                                                     (number-bytes (+ 8 (length inside)) 2) (list #x12 #x34) inside)))
                            (packet-to-machine network to from 17 datagram)))
                         ((or (eq (network-names-closed network) t) (member to (network-names-closed network)))
                          ;; nothing takes questions there: the word comes back that the packet was not taken
                          (control-to-machine network to from 3 3 0 (subseq frame 14 42)))
                         (t
                          (datagram-to-machine network to from to-port port
                                               (network-name-answer network number question name (network-cut network)))))))))))))

;; A message of ICMP's from the machine. When the machine asks whether a
;; machine of this network is there, that machine says that it is, with
;; the bytes that it was sent, or the way out says that it cannot be
;; reached. What the machine answers to such a question itself, and what
;; it says of a packet that it did not take, is put down for the test.
(defun network-heard-control (network frame)
  (let* ((at 34) (whole (- (be frame 16 2) 20)) (kind (aref frame at)) (code (aref frame (+ at 1)))
         (from (be frame 26 4)) (to (be frame 30 4)))
    (unless (= (wire-sum frame at (+ at whole)) #xffff)
      (failed "the machine sent a message of ICMP's whose checksum is wrong"))
    (cond ((and (= kind 8) (= code 0))
           (network-note network :ping to (be frame (+ at 6) 2))
           (cond ((member :ping (network-mute network)))
                 ((network-unreachable network)
                  (control-to-machine network (network-address network) from 3 1 0 (subseq frame 14 (+ at 8))))
                 (t
                  (let ((*from-station* (cdr (assoc to (network-hosts network)))))
                    (control-to-machine network to from 0 0 (be frame (+ at 4) 4) (subseq frame (+ at 8) (+ at whole)))))))
          ((and (= kind 0) (= code 0))
           (network-note network :pong (coerce (subseq frame (+ at 4) (+ at whole)) 'list)))
          ((= kind 3)
           (network-note network :not-taken code (coerce (subseq frame (+ at 8) (+ at whole)) 'list)))
          (t
           (failed "the machine sent a message of ICMP's of the kind ~D" kind)))))

(defun network-heard-frame (network frame)
  (let* ((kind (be frame 12 2)) (to (be frame 0 6))
         ;; where what the frame carries ends, after which there is only what makes it sixty bytes long
         (end (cond ((= kind #x0806) 42)
                    ((= kind #x0800) (+ 14 (be frame 16 2)))
                    (t (length frame)))))
    (unless (= (be frame 6 6) (network-machine network))
      (failed "the machine sent a frame that does not say that it is from its card"))
    (unless (or (= to #xffffffffffff) (= to (network-station network)) (rassoc to (network-hosts network)))
      (failed "the machine sent a frame to a card that is not on its network: ~X" to))
    (when (find-if #'plusp frame :start (min end (length frame)))
      (failed "the machine sent a frame with something after what it carries, where there should be nothing"))
    (cond ((= kind #x0806)
           (let* ((question (= (be frame 20 2) 1)) (wanted (be frame 38 4))
                  (station (cond ((= wanted (network-address network)) (network-station network))
                                 (t (cdr (assoc wanted (network-hosts network)))))))
             (network-note network (if question :who-has :i-have) (if question wanted (be frame 28 4)))
             (unless (and (= (be frame 14 2) 1) (= (be frame 16 2) #x0800) (= (aref frame 18) 6) (= (aref frame 19) 4)
                          (= (be frame 22 6) (network-machine network))
                          (if question (= to #xffffffffffff) (/= to #xffffffffffff)))
               (failed "the machine asks who has an address in a way that is not ARP's"))
             (when (and question station (not (member :arp (network-mute network))))
               (let ((*from-station* station))
                 (frame-to-machine network #x0806 (list 0 1 8 0 6 4 0 2) (number-bytes station 6)
                                   (number-bytes wanted 4) (number-bytes (network-machine network) 6)
                                   (number-bytes (be frame 28 4) 4))))))
          ((= kind #x0800)
           (unless (and (= (aref frame 14) #x45) (= (wire-sum frame 14 34) #xffff) (<= (+ 14 (be frame 16 2)) (length frame))
                        (= (be frame 20 2) #x4000) (plusp (aref frame 22)))
             (failed "the machine sent a packet that is not one of IPv4's, whole and with a right checksum"))
           (network-note network :packet-to to (be frame 30 4))
           (case (aref frame 23)
             (1 (network-heard-control network frame))
             (17 (network-heard-datagram network frame))
             (6 (network-heard-segment network frame))
             (t (failed "the machine sent a packet of the protocol ~D" (aref frame 23)))))
          (t (failed "the machine sent a frame of the kind ~X" kind)))))

;; The network's own thread: it takes what the machine has sent, and sends
;; an answer again that the machine has said nothing to for a while.
(defun network-loop (network)
  (loop
    (sb-thread:wait-on-semaphore (network-wake network) :timeout 0.02)
    (when (network-stopped network)
      (return))
    (loop
      (let ((frame (sb-thread:with-mutex ((network-lock network)) (pop (network-inbox network)))))
        (unless frame
          (return))
        (handler-case (network-heard-frame network frame)
          (error (condition)
            (failed "the made-up network could not make sense of a frame: ~A" condition)))))
    (dolist (call (sb-thread:with-mutex ((network-lock network)) (reverse (network-calls network))))
      (call-step call))
    (dolist (connection (network-connections network))
      (when (and (served-answer connection) (< (served-heard connection) (served-sent connection))
                 (> (- (get-internal-real-time) (served-moment connection)) (* 0.15 internal-time-units-per-second)))
        (setf (served-sent connection) (served-heard connection)
              (served-ended connection) nil
              (served-moment connection) (get-internal-real-time))
        (network-say network connection)))))

;;; Certificates and keys for the made-up network, and its side of a
;;; connection that is kept closed (lisp/tls.lisp). Certificates are written
;;; here from RFC 5280, piece by piece, and signed with SBCL's big numbers;
;;; the network's half of TLS 1.3 is written from RFC 8446, the half that a
;;; server speaks, with the arithmetic of host/clara.lisp. So what the
;;; machine reads, checks and opens was made by other code than its own.

(defun der (kind &rest parts)
  (let* ((inside (apply #'bytes-of parts)) (length (length inside)))
    (bytes-of (list kind)
              (cond ((< length 128) (list length))
                    ((< length 256) (list #x81 length))
                    (t (list #x82 (ash length -8) (logand length 255))))
              inside)))

(defun der-number (number)
  (let ((bytes (number-bytes number (max 1 (ceiling (integer-length number) 8)))))
    (der 2 (if (logbitp 7 (car bytes)) (cons 0 bytes) bytes))))

(defun der-time (time &optional long)
  (multiple-value-bind (second minute hour day month year) (decode-universal-time time 0)
    (if long
        (der 24 (octets (format nil "~4,'0D~2,'0D~2,'0D~2,'0D~2,'0D~2,'0DZ" year month day hour minute second)))
        (der 23 (octets (format nil "~2,'0D~2,'0D~2,'0D~2,'0D~2,'0D~2,'0DZ" (mod year 100) month day hour minute second))))))

;; A name: an organization, when one is given, and a common name.
(defun der-name (common &optional organization)
  (der 48
       (and organization (der 49 (der 48 (der 6 '(#x55 4 10)) (der 12 (octets organization)))))
       (and common (der 49 (der 48 (der 6 '(#x55 4 3)) (der 19 (octets common)))))))

;; A key: on one of the two curves, a secret number and its point; or of
;; RSA's, the number N, the small number E, and the secret one D.
(defstruct tkey kind curve secret point n (e 65537) d)

(defun curve-key (bits secret)
  (let ((curve (clara.host:curve bits)))
    (make-tkey :kind :curve :curve curve :secret secret :point (clara.host:curve-public curve secret))))

(defun rsa-key (p q)
  (let ((n (* p q)))
    (make-tkey :kind :rsa :n n
               :d (let ((phi (* (1- p) (1- q))))
                    ;; one over 65537 modulo phi, the long way: the first d from 1 on with e*d = 1
                    (loop for k from 1
                          when (zerop (mod (1+ (* k phi)) 65537)) return (floor (1+ (* k phi)) 65537))))))

(defvar *authority-key* (curve-key 256 #x1f2e3d4c5b6a79880123456789abcdeffedcba98765432100f1e2d3c4b5a6978))
(defvar *signer-key* (curve-key 384 #x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff0123456789abcdef0123456789abcdef))
(defvar *shown-key* (curve-key 256 #x7a6b5c4d3e2f10010203040506070809a0b0c0d0e0f0112233445566778899aa))
(defvar *other-key* (curve-key 256 #x5a4b3c2d1e0f11223344556677889900aabbccddeeff00112233445566778899))
(defvar *large-key* (curve-key 384 #x0f0e0d0c0b0a09080706050403020100ffeeddccbbaa99887766554433221100123456789abcdef0fedcba9876543210))
(defvar *rsa-key*
  (rsa-key #xe37581af564c71b5aab937f738b2c11bbd52718f5855a5b2e3e9a7888a85a456d5804ce3dab3c88096d0800c2d843b37a9fc272b19b5bbfd6393575795244cc58e1a1f582fd1f2bfc17d970c967f056e0f9945790e8b399afb15a9bc45ec506c0ee49eb32ee163cb2d765cbf72bde358921425ec51729a379d4a61c4939ab577
           #xc48957c6895c0f2116c0b8595fe936005243bf6cbd6fe31a19e0f38a988b81e61e214650d15f38039713f3dbbb35115be2650efd11b20d33b338c01aac02c8665c92acd75b2792331b882276e64635dda3b71d78a77c686d9accac23d20ff71bcfaf5cd6e0a37ff2a3fb3d2c686a602b60ace1336f7b71f9c434537ee26b5469))

(defun key-size (key)
  (if (eq (tkey-kind key) :curve)
      (floor (clara.host:curve-bits (tkey-curve key)) 8)
      (ceiling (integer-length (tkey-n key)) 8)))

;; A key as a certificate has it.
(defun der-key (key)
  (if (eq (tkey-kind key) :curve)
      (let ((size (key-size key)))
        (der 48
             (der 48 (der 6 '(#x2a #x86 #x48 #xce #x3d 2 1))
                  (der 6 (if (= size 32) '(#x2a #x86 #x48 #xce #x3d 3 1 7) '(#x2b #x81 4 0 #x22))))
             (der 3 '(0 4) (number-bytes (car (tkey-point key)) size) (number-bytes (cdr (tkey-point key)) size))))
      (der 48
           (der 48 (der 6 '(#x2a #x86 #x48 #x86 #xf7 #x0d 1 1 1)) (der 5))
           (der 3 '(0) (der 48 (der-number (tkey-n key)) (der-number (tkey-e key)))))))

(defvar *sum-prefixes*
  '((256 #x30 #x31 #x30 #x0d #x06 #x09 #x60 #x86 #x48 #x01 #x65 #x03 #x04 #x02 #x01 #x05 #x00 #x04 #x20)
    (384 #x30 #x41 #x30 #x0d #x06 #x09 #x60 #x86 #x48 #x01 #x65 #x03 #x04 #x02 #x02 #x05 #x00 #x04 #x30)
    (512 #x30 #x51 #x30 #x0d #x06 #x09 #x60 #x86 #x48 #x01 #x65 #x03 #x04 #x02 #x03 #x05 #x00 #x04 #x40)))

;; The block that a signature of RSA's newer kind is made of (RFC 8017, 9.1.1).
(defun pss-block (bits sum modulus-bits)
  (let* ((size (length sum)) (block-bits (1- modulus-bits)) (block-bytes (ceiling block-bits 8))
         (salt (subseq (clara.host:digest-of 512 (bytes-of sum (octets "salt"))) 0 size))
         (h (clara.host:digest-of bits (bytes-of (make-list 8 :initial-element 0) sum salt)))
         (open (bytes-of (make-list (- block-bytes size size 2) :initial-element 0) '(1) salt))
         (mask (apply #'bytes-of (loop for count from 0 below (ceiling (length open) size)
                                       collect (clara.host:digest-of bits (bytes-of h (number-bytes count 4))))))
         (covered (map 'vector #'logxor open mask)))
    (setf (aref covered 0) (logand (aref covered 0) (ash #xff (- block-bits (* 8 block-bytes)))))
    (bytes-of covered h '(#xbc))))

;; The signature that a key gives some bytes, over the sum of that many
;; bits: two numbers in a piece, on a curve; and of RSA's the older kind,
;; or the newer when PSS says so.
(defun sign-with (key bits bytes &key pss)
  (let ((sum (clara.host:digest-of bits bytes)))
    (if (eq (tkey-kind key) :curve)
        (let* ((curve (tkey-curve key)) (n (clara.host:curve-n curve))
               (k (1+ (mod (clara.host:octets-number (clara.host:digest-of 512 (bytes-of (number-bytes (tkey-secret key) 48) sum)))
                           (1- n)))))
          (multiple-value-bind (r s) (clara.host:curve-sign curve (tkey-secret key) sum k)
            (der 48 (der-number r) (der-number s))))
        (let* ((size (key-size key))
               (prefix (cdr (assoc bits *sum-prefixes*)))
               (block (if pss
                          (pss-block bits sum (integer-length (tkey-n key)))
                          (bytes-of '(0 1) (make-list (- size 3 (length prefix) (length sum)) :initial-element 255) '(0) prefix sum))))
          (bytes-of (number-bytes (clara.host:expt-mod (clara.host:octets-number block) (tkey-d key) (tkey-n key)) size))))))

;; How a certificate says that it is signed: by the kind of the signer's key
;; and the sum.
(defun der-way (signer bits)
  (if (eq (tkey-kind signer) :curve)
      (der 48 (der 6 (list #x2a #x86 #x48 #xce #x3d 4 3 (ecase bits (256 2) (384 3) (512 4)))))
      (der 48 (der 6 (list #x2a #x86 #x48 #x86 #xf7 #x0d 1 1 (ecase bits (256 11) (384 12) (512 13) (1 5)))) (der 5))))

;; A certificate: for SUBJECT, with KEY, signed by ISSUER with the key
;; SIGNER. NAMES are the names it is for, and ADDRESSES the addresses.
;; AUTHORITY says that it may sign certificates, DEPTH how many signers may
;; be below it, USAGE what its key is for, as the bits of a byte, PURPOSES
;; what it may be shown for, as lists of bytes, and MUST adds something
;; that has to be understood and that nobody understands. WAY is how it
;; says that it is signed, when that is not how it is; SPOIL changes a bit
;; of what is signed after it was signed.
(defun certificate (&key subject organization (issuer subject issuer-p) (issuer-organization (and (not issuer-p) organization))
                         key (signer key) (bits 256)
                         names addresses authority depth usage (purposes nil purposes-p) must
                         (from (- (get-universal-time) 86400)) (until (+ (get-universal-time) 864000))
                         way spoil long-dates (version t) (number 4660))
  (let* ((way (or way (der-way signer bits)))
         (more (bytes-of
                (and (or authority depth)
                     (der 48 (der 6 '(#x55 #x1d #x13)) (der 1 '(255))
                          ;; :NO says outright that it may not sign, which is how some write what need not be written
                          (der 4 (der 48 (and authority (der 1 (if (eq authority :no) '(0) '(255)))) (and depth (der-number depth))))))
                (and usage (der 48 (der 6 '(#x55 #x1d #x0f)) (der 1 '(255)) (der 4 (der 3 (list 0 usage)))))
                (and (or names addresses)
                     (der 48 (der 6 '(#x55 #x1d #x11))
                          (der 4 (apply #'der 48 (append (mapcar (lambda (name) (der #x82 (octets name))) names)
                                                         (mapcar (lambda (address) (der #x87 (number-bytes address 4))) addresses))))))
                (and purposes-p
                     (der 48 (der 6 '(#x55 #x1d #x25)) (der 4 (apply #'der 48 (mapcar (lambda (purpose) (der 6 purpose)) purposes)))))
                (and must (der 48 (der 6 '(#x2a 3 4 5)) (der 1 '(255)) (der 4 (der 5))))))
         (body (der 48
                    (and version (der #xa0 (der-number 2)))
                    (der-number number)
                    way
                    (der-name issuer issuer-organization)
                    (der 48 (der-time from long-dates) (der-time until long-dates))
                    (der-name subject organization)
                    (der-key key)
                    (and (plusp (length more)) (der #xa3 (der 48 more)))))
         (signature (sign-with signer bits body)))
    (when spoil
      ;; a bit of its number, which changes nothing else of what it says
      (let ((at (+ 3 (search (bytes-of '(2 2) (number-bytes number 2)) body))))
        (setf (aref body at) (logxor 1 (aref body at)))))
    (der 48 body way (der 3 '(0) signature))))

;; A certificate as files of certificates have it: in base 64, between two lines.
(defun pem (bytes)
  (let ((letters "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"))
    (with-output-to-string (out)
      (format out "-----BEGIN CERTIFICATE-----~%")
      (loop for start from 0 below (length bytes) by 3
            for column from 1
            do (let* ((end (min (length bytes) (+ start 3)))
                      (group (ash (be bytes start (- end start)) (* 8 (- 3 (- end start))))))
                 (dotimes (i 4)
                   (write-char (if (<= i (- end start)) (char letters (ldb (byte 6 (* 6 (- 3 i))) group)) #\=) out))
                 (when (zerop (mod column 16))
                   (terpri out))))
      (format out "~%-----END CERTIFICATE-----~%"))))

(defvar *authority* (certificate :subject "The tests' root" :organization "ClaraOS tests" :key *authority-key* :authority t :usage 6))
(defvar *signer* (certificate :subject "The tests' signer in between" :issuer "The tests' root" :issuer-organization "ClaraOS tests"
                              :key *signer-key* :signer *authority-key* :authority t :depth 0 :usage 6))
(defvar *shown* (certificate :subject "releases.test" :issuer "The tests' signer in between" :key *shown-key* :signer *signer-key* :bits 384
                           :names '("releases.test" "*.wild.test") :addresses '(#x0a000202) :usage 128
                           :purposes '((#x2b 6 1 5 5 7 3 1))))

;; The machine trusts these and nothing else: no list is read from a disk.
;; They are read at once, into memory that is the machine's for as long as
;; it runs, so that a test which counts page frames afterwards counts only
;; what a fetch took.
(defun trust-only (&rest certificates)
  (clara.tls:start)
  (setq clara.tls::*trusted* (mapcar #'pem certificates)
        clara.tls::*system-roots* nil
        clara.tls::*system-read* t)
  (clara.tls::anchors))

;;; The network's side of TLS 1.3

(defstruct tls
  (state :hello)                 ; :HELLO, then :WORD while the machine's last word is waited for, then :OPEN, and :OVER
  (read 0)                       ; how far what the machine sent has been taken as records
  (greeting (bytes-of))          ; the messages of the greeting so far
  client server                  ; (key twelve-bytes) that each side closes its records with
  (client-count 0) (server-count 0)
  client-secret server-secret    ; what the keys of the greeting are made of,
  client-next server-next        ; and the ones after it
  asked                          ; the machine was asked who it is
  (request (bytes-of)))          ; what the machine said after the greeting

(defun tls-label (secret label context length)
  (let ((full (octets (concatenate 'string "tls13 " label))))
    (subseq (clara.host:hmac-of 256 secret (bytes-of (number-bytes length 2) (list (length full)) full
                                                     (list (length context)) context '(1)))
            0 length)))

(defun tls-secret (secret label greeting)
  (tls-label secret label (clara.host:digest-of 256 greeting) 32))

(defun tls-pair (secret)
  (list (tls-label secret "key" #() 16) (tls-label secret "iv" #() 12)))

(defun tls-nonce (pair count)
  (map 'vector #'logxor (second pair) (bytes-of '(0 0 0 0) (number-bytes count 8))))

;; A record, closed: its bytes, their kind, and PADDING zeroes.
(defun tls-seal (pair count kind bytes &key (padding 0) spoil)
  (let* ((inside (bytes-of bytes (list kind) (make-list padding :initial-element 0)))
         (header (bytes-of '(23 3 3) (number-bytes (+ (length inside) 16) 2))))
    (multiple-value-bind (closed tag) (clara.host:aes-gcm (first pair) (tls-nonce pair count) header inside)
      (when spoil
        (setf (aref closed 0) (logxor 1 (aref closed 0))))
      (bytes-of header closed tag))))

;; A record, opened: its kind and its bytes, or NIL when it does not open.
(defun tls-open (pair count record)
  (let* ((length (- (length record) 21))
         (opened (and (>= length 1)
                      (clara.host:aes-gcm (first pair) (tls-nonce pair count) (subseq record 0 5) (subseq record 5 (+ 5 length))
                                          :opening t :tag (subseq record (+ 5 length))))))
    (when opened
      (let ((end (position-if #'plusp opened :from-end t)))
        (and end (values (aref opened end) (subseq opened 0 end)))))))

(defun tls-message (kind &rest parts)
  (let ((inside (apply #'bytes-of parts)))
    (bytes-of (list kind) (number-bytes (length inside) 3) inside)))

(defun tls-extension (kind &rest parts)
  (let ((inside (apply #'bytes-of parts)))
    (bytes-of (number-bytes kind 2) (number-bytes (length inside) 2) inside)))

;; More goes out on a connection, after what went out before.
(defun tls-send (connection &rest parts)
  (setf (served-answer connection) (apply #'bytes-of (or (served-answer connection) (bytes-of)) parts)
        (served-moment connection) (get-internal-real-time)))

;; What the machine's first message says, as (kind . bytes) for each thing
;; in it, after the checks of everything that has one right way.
(defun tls-read-hello (network hello)
  (let* ((again (aref hello 38)) (at (+ 39 again)) (ciphers (be hello at 2))
         (methods (+ at 2 ciphers)) (list (+ methods 1 (aref hello methods))) (end (+ list 2 (be hello list 2)))
         (found nil))
    (unless (and (= (aref hello 0) 1) (= (be hello 1 3) (- (length hello) 4)) (= (be hello 4 2) #x0303)
                 (= again 0) (= ciphers 2) (= (be hello (+ at 2) 2) #x1301)
                 (= (aref hello methods) 1) (= (aref hello (1+ methods)) 0) (= end (length hello)))
      (failed "the machine begins a greeting in a way that is not TLS 1.3's: ~S" hello))
    (let ((e (+ list 2)))
      (loop while (< e end)
            do (push (cons (be hello e 2) (subseq hello (+ e 4) (+ e 4 (be hello (+ e 2) 2)))) found)
               (incf e (+ 4 (be hello (+ e 2) 2)))))
    (let ((name (cdr (assoc 0 found))) (versions (cdr (assoc 43 found))) (groups (cdr (assoc 10 found)))
          (share (cdr (assoc 51 found))) (ways (cdr (assoc 13 found))))
      (unless (and (equalp versions #(2 3 4)) (equalp groups #(0 2 0 29))
                   share (= (length share) 38) (= (be share 0 2) 36) (= (be share 2 2) 29) (= (be share 4 2) 32)
                   ways (= (be ways 0 2) (- (length ways) 2)) (evenp (length ways))
                   (= (length found) (if name 5 4)))
        (failed "the machine's greeting does not say what it has to, or says it wrongly: ~S" found))
      (when name
        (unless (and (= (be name 0 2) (- (length name) 2)) (= (aref name 2) 0) (= (be name 3 2) (- (length name) 5)))
          (failed "the machine names the machine that it means in a way that is none"))
        (network-note network :named (sb-ext:octets-to-string (subseq name 5)))))
    (unless (/= (length (remove-duplicates (subseq hello 6 38))) 1)
      (failed "the machine's thirty-two bytes that nobody can guess are all the same"))
    found))

;; The network's greeting, when the machine's first message has come: its
;; own first message, in the open, and the rest of what it has to say,
;; closed. What the test wants wrong is wrong.
(defun tls-greet (network connection tls hello)
  (let* ((accident (network-accident network))
         (found (tls-read-hello network hello))
         (key (network-key network))
         (secret (bytes-of (loop for i below 32 collect (logand 255 (+ 7 (* i 13) (served-port connection))))))
         (shared (clara.host:x25519-of secret (subseq (cdr (assoc 51 found)) 6)))
         (first (tls-message 2 '(3 3)
                             (if (eq accident :again)
                                 (clara.host:digest-of 256 (octets "HelloRetryRequest"))
                                 (loop for i below 32 collect (logand 255 (+ 1 (* i 3)))))
                             (if (eq accident :echo) '(4 1 2 3 4) '(0))
                             (if (eq accident :other-cipher) '(#x13 #x02) '(#x13 #x01))
                             '(0)
                             (let ((more (bytes-of
                                          (and (not (eq accident :old)) (tls-extension 43 '(3 4)))
                                          (and (not (eq accident :no-share))
                                               (cond ((eq accident :other-share)
                                                      (tls-extension 51 '(0 23 0 65) (make-list 65 :initial-element 4)))
                                                     ((eq accident :nothing-share)
                                                      ;; a point that makes zeroes of every number
                                                      (tls-extension 51 '(0 29 0 32) (make-list 32 :initial-element 0)))
                                                     (t
                                                      (tls-extension 51 '(0 29 0 32) (clara.host:x25519-of secret (cons 9 (make-list 31 :initial-element 0)))))))
                                          (and (eq accident :more) (tls-extension 16 '(0 3 2 104 50))))))
                               (bytes-of (number-bytes (length more) 2) more)))))
    (when (eq accident :gives-up)
      (tls-send connection '(21 3 3 0 2 2 40))
      (setf (tls-state tls) :over)
      (return-from tls-greet))
    (setf (tls-greeting tls) (bytes-of hello first))
    (if (eq accident :trailing-hello)
        ;; the beginning of another message in the record of the first, where the keys are about to change
        (tls-send connection '(22 3 3) (number-bytes (+ 2 (length first)) 2) first '(8 0))
        (tls-send connection '(22 3 3) (number-bytes (length first) 2) first))
    (when (eq accident :old-word)
      (tls-send connection '(20 3 3 0 1 1)))
    (when (eq accident :old-word-wrong)
      (tls-send connection '(20 3 3 0 1 2)))
    (let* ((zeroes (make-list 32 :initial-element 0))
           (early (clara.host:hmac-of 256 zeroes zeroes))
           (greeting (clara.host:hmac-of 256 (tls-secret early "derived" #()) shared))
           (master (clara.host:hmac-of 256 (tls-secret greeting "derived" #()) zeroes))
           (said nil))
      (setf (tls-client-secret tls) (tls-secret greeting "c hs traffic" (tls-greeting tls))
            (tls-server-secret tls) (tls-secret greeting "s hs traffic" (tls-greeting tls))
            (tls-client tls) (tls-pair (tls-client-secret tls))
            (tls-server tls) (tls-pair (tls-server-secret tls)))
      (flet ((say (message)
               (setf (tls-greeting tls) (bytes-of (tls-greeting tls) message))
               (push message said)))
        (say (tls-message 8 (if (eq accident :says-more) (bytes-of '(0 9) (tls-extension 16 '(0 3 2 104 50))) '(0 0))))
        (when (eq accident :asks)
          (setf (tls-asked tls) t)
          (say (tls-message 13 '(0) (let ((more (tls-extension 13 '(0 2 4 3)))) (bytes-of (number-bytes (length more) 2) more)))))
        (when (eq accident :asks-wrongly)
          (say (tls-message 13 '(1 9) (let ((more (tls-extension 13 '(0 2 4 3)))) (bytes-of (number-bytes (length more) 2) more)))))
        (when (eq accident :endless)
          ;; a greeting that goes on for longer than anybody keeps
          (say (tls-message 99 (make-list 80000 :initial-element 0))))
        (let ((list (apply #'bytes-of (loop for certificate in (if (eq accident :no-certificate) nil (network-chain network))
                                            collect (bytes-of (number-bytes (length certificate) 3) certificate
                                                              ;; what goes with a certificate, which the machine passes over
                                                              (if (eq accident :with-more)
                                                                  (let ((more (tls-extension 5 '(1 2 3 4))))
                                                                    (bytes-of (number-bytes (length more) 2) more))
                                                                  '(0 0)))))))
          (say (tls-message 11 '(0) (number-bytes (length list) 3) list)))
        (unless (eq accident :no-signature)
          (let* ((curve (eq (tkey-kind key) :curve))
                 (bits (if (and curve (= (key-size key) 48) (not (eq accident :short-way))) 384 256))
                 (signed (bytes-of (make-list 64 :initial-element 32) (octets "TLS 1.3, server CertificateVerify") '(0)
                                   (clara.host:digest-of 256 (tls-greeting tls))))
                 (signature (sign-with (if (eq accident :other-key) *other-key* key) bits signed :pss (not (eq accident :older-way)))))
            (when (eq accident :signature)
              (setf (aref signature (- (length signature) 3)) (logxor 4 (aref signature (- (length signature) 3)))))
            (say (tls-message 15
                              (cond ((eq accident :wrong-way) '(8 7))
                                    ((eq accident :other-way) (if curve '(8 4) '(4 3)))
                                    ((eq accident :older-way) '(4 1))
                                    ((not curve) '(8 4))
                                    ((eq accident :short-way) '(4 3))
                                    ((= bits 384) '(5 3))
                                    (t '(4 3)))
                              (number-bytes (length signature) 2) signature))))
        (let ((word (clara.host:hmac-of 256 (tls-label (tls-server-secret tls) "finished" #() 32)
                                        (clara.host:digest-of 256 (tls-greeting tls)))))
          (when (eq accident :word)
            (setf (aref word 5) (logxor 1 (aref word 5))))
          (say (tls-message 20 word))))
      (setf (tls-client-next tls) (tls-secret master "c ap traffic" (tls-greeting tls))
            (tls-server-next tls) (tls-secret master "s ap traffic" (tls-greeting tls)))
      ;; the messages go out closed: all in one record; each in one of its own; in pieces of a
      ;; few bytes, whatever message they are of; or in the open, which nothing after the first may be
      (let ((messages (reverse said)))
        (flet ((closed (bytes &optional (kind 22))
                 (prog1 (tls-seal (tls-server tls) (tls-server-count tls) kind bytes
                                  :padding (if (eq accident :padded) 37 0))
                   (incf (tls-server-count tls)))))
          (cond ((eq accident :in-the-open)
                 (let ((all (apply #'bytes-of messages)))
                   (tls-send connection '(22 3 3) (number-bytes (length all) 2) all)))
                ((eq accident :apart)
                 (dolist (message messages)
                   (tls-send connection (closed message))))
                ((member accident '(:pieces :endless))
                 (let ((all (apply #'bytes-of messages)) (size (if (eq accident :pieces) 61 16000)))
                   (loop for start from 0 below (length all) by size
                         do (tls-send connection (closed (subseq all start (min (length all) (+ start size))))))))
                ((eq accident :early)
                 (tls-send connection (closed (apply #'bytes-of (butlast messages))))
                 (tls-send connection (closed (octets "too early") 23))
                 (tls-send connection (closed (car (last messages)))))
                ((eq accident :nothing)
                 (tls-send connection (tls-seal (tls-server tls) 0 0 (bytes-of)))
                 (incf (tls-server-count tls)))
                ((eq accident :trailing)
                 ;; the beginning of a message after the last word, with the keys of the greeting
                 (tls-send connection (closed (bytes-of (apply #'bytes-of messages) '(4 0)))))
                (t
                 (tls-send connection (closed (apply #'bytes-of messages)))))))
      (setf (tls-state tls) :word))))

;; What the network says once the machine has asked for something: the
;; answer of its web server, in records, and at the end the word that it is
;; done. What the test wants wrong is wrong.
(defun tls-answer (network connection tls answer)
  (let ((accident (network-accident network)) (size (network-record network)))
    (flet ((closed (bytes &optional (kind 23) &rest more)
             (prog1 (apply #'tls-seal (tls-server tls) (tls-server-count tls) kind bytes
                           :padding (if (eq accident :padded) 37 0) more)
               (incf (tls-server-count tls))))
           (renew ()
             (setf (tls-server-next tls) (tls-label (tls-server-next tls) "traffic upd" #() 32)
                   (tls-server tls) (tls-pair (tls-server-next tls))
                   (tls-server-count tls) 0)))
      (when (eq accident :tickets)
        (tls-send connection (closed (bytes-of (tls-message 4 '(0 0 1 0 1 2 3 4 0 0 4 9 9 9 9 0 0))
                                               (tls-message 4 '(0 0 1 0 1 2 3 4 0 0 4 8 8 8 8 0 0)))
                                     22)))
      (when (eq accident :late-greeting)
        (tls-send connection (closed (tls-message 8 '(0 0)) 22)))
      (when (eq accident :old-word-late)
        (tls-send connection '(20 3 3 0 1 1)))
      (when (eq accident :cut)
        (setq answer (subseq answer 0 (floor (length answer) 2))))
      (loop for start from 0 below (length answer) by size
            for number from 0
            do (let ((piece (subseq answer start (min (length answer) (+ start size)))))
                 (when (and (member accident '(:renew :renew-quietly :renew-wrongly)) (= number 1))
                   (tls-send connection (closed (bytes-of (tls-message 24 (list (ecase accident (:renew 1) (:renew-quietly 0) (:renew-wrongly 7))))
                                                          (if (eq accident :renew-wrongly) (bytes-of) (bytes-of)))
                                                22))
                   (renew))
                 (cond ((and (eq accident :spoiled) (= number 1))
                        (tls-send connection (closed piece 23 :spoil t)))
                       ((and (eq accident :twice) (= number 1))
                        (let ((record (closed piece)))
                          (tls-send connection record record)))
                       ((and (eq accident :open-record) (= number 1))
                        (tls-send connection '(23 3 3) (number-bytes (length piece) 2) piece))
                       ((and (eq accident :long) (= number 1))
                        (tls-send connection '(23 3 3) (number-bytes 17000 2) (make-list 17000 :initial-element 1)))
                       (t
                        (tls-send connection (closed piece))))))
      (unless (member accident '(:no-goodbye :cut))
        (tls-send connection (closed (if (eq accident :complains) '(2 80) '(1 0)) 21))))
    (setf (tls-state tls) :over
          (served-more connection) nil)))

;; A record from the machine.
(defun tls-record (network connection tls record)
  (let ((kind (aref record 0)))
    (case (tls-state tls)
      (:hello
       (unless (and (= kind 22) (= (be record 1 2) #x0301))
         (failed "the machine begins a connection that is to be kept closed with a record of the kind ~D" kind))
       (tls-greet network connection tls (subseq record 5)))
      (:word
       (multiple-value-bind (inner bytes) (and (= kind 23) (tls-open (tls-client tls) (tls-client-count tls) record))
         (incf (tls-client-count tls))
         (cond ((and (= kind 21) (= (length record) 7) (= (aref record 5) 2))
                ;; the machine gives up before it has any keys, which it says in the open
                (network-note network :alert (aref record 6))
                (setf (tls-state tls) :over
                      (served-more connection) nil))
               ((null inner)
                (failed "the machine sent a record in its greeting that does not open with the keys of the greeting"))
               ((= inner 21)
                (network-note network :alert (aref bytes 1))
                (unless (= (aref bytes 0) 2)
                  (failed "the machine gives a greeting up without saying that it is for good"))
                (setf (tls-state tls) :over
                      (served-more connection) nil))
               ((/= inner 22)
                (failed "the machine sent something of the kind ~D in its greeting" inner))
               (t
                (when (and (tls-asked tls) (= (aref bytes 0) 11))
                  (unless (equalp (subseq bytes 0 8) #(11 0 0 4 0 0 0 0))
                    (failed "the machine, asked who it is, does not say that it has no certificate: ~S" bytes))
                  (network-note network :no-certificate)
                  (setf (tls-greeting tls) (bytes-of (tls-greeting tls) (subseq bytes 0 8))
                        (tls-asked tls) nil
                        bytes (subseq bytes 8)))
                (when (plusp (length bytes))
                  (when (tls-asked tls)
                    (failed "the machine, asked who it is, says its last word without answering"))
                  (unless (equalp bytes (tls-message 20 (clara.host:hmac-of 256 (tls-label (tls-client-secret tls) "finished" #() 32)
                                                                           (clara.host:digest-of 256 (tls-greeting tls)))))
                    (failed "the machine's last word is not the one that goes with the greeting"))
                  (network-note network :word)
                  (setf (tls-client tls) (tls-pair (tls-client-next tls))
                        (tls-server tls) (tls-pair (tls-server-next tls))
                        (tls-client-count tls) 0
                        (tls-server-count tls) 0
                        (tls-state tls) :open))))))
      ((:open :over)
       (multiple-value-bind (inner bytes) (and (= kind 23) (tls-open (tls-client tls) (tls-client-count tls) record))
         (incf (tls-client-count tls))
         (cond ((null inner)
                (failed "the machine sent a record after the greeting that does not open with its keys"))
               ((= inner 21)
                (network-note network (if (equalp bytes #(1 0)) :goodbye :alert) (aref bytes 1)))
               ((and (= inner 22) (equalp bytes #(24 0 0 1 0)))
                (network-note network :renewed)
                (setf (tls-client-next tls) (tls-label (tls-client-next tls) "traffic upd" #() 32)
                      (tls-client tls) (tls-pair (tls-client-next tls))
                      (tls-client-count tls) 0))
               ((/= inner 23)
                (failed "the machine sent something of the kind ~D after the greeting" inner))
               ((eq (tls-state tls) :over)
                (failed "the machine goes on asking on a connection whose answer it has"))
               (t
                (setf (tls-request tls) (bytes-of (tls-request tls) bytes))
                (let ((answer (network-request network connection (tls-request tls))))
                  (when answer
                    (tls-answer network connection tls answer))))))))))

;; What has arrived on a connection that is to be kept closed: every record
;; that is whole.
(defun tls-heard (network connection)
  (let ((tls (or (served-secure connection)
                 (setf (served-more connection) t
                       (served-secure connection) (make-tls)))))
    (loop
      (let* ((bytes (served-request connection)) (at (tls-read tls)) (have (- (length bytes) at)))
        (unless (and (>= have 5) (>= have (+ 5 (be bytes (+ at 3) 2))))
          (return))
        (setf (tls-read tls) (+ at 5 (be bytes (+ at 3) 2)))
        (tls-record network connection tls (subseq bytes at (tls-read tls)))))))

;; The network is no more, and neither is the thread of the machine's
;; card: a machine that is made after this one gets the same memory, and a
;; thread that still looked at the old card's queues there would be
;; looking at the new machine's.
(defun stop-network ()
  ;; the ports at which a machine took connections are its world's: the next machine is another world
  (setq clara.net::*doors* nil)
  (when *network*
    (setf (network-stopped *network*) t)
    (sb-thread:signal-semaphore (network-wake *network*))
    (sb-thread:join-thread (network-thread *network*) :default nil :timeout 5)
    (setq *network* nil))
  (let ((thread (and clara.net::*card* (clara.net::card-thread clara.net::*card*))))
    (when (and thread (clara:thread-alive-p thread))
      (clara:destroy-thread thread)
      (unless (eventually (lambda () (not (clara:thread-alive-p thread))))
        (failed "the thread of a network card does not end when it is told to")))))

;; A machine with a network card, a network at the other end of it, and a
;; disk when BYTES are given. What START says of the card.
(defun new-network (&rest options)
  (stop-network)
  (let ((disk (getf options :disk)) (offers (getf options :offers (list 32 1)))
        (numbers (getf options :numbers t)) (trusted (getf options :trusted (list *authority*)))
        (doors (getf options :doors)))
    (remf options :doors)
    (remf options :disk)
    (remf options :offers)
    (remf options :numbers)
    (remf options :trusted)
    (new-machine)
    (attach-bus)
    (add-function 0 0 0 #x8086 #x29c0 #x060000)
    (apply #'trust-only trusted)
    (setq *numbers* (and numbers (if (eq numbers t) (add-numbers 6) (apply #'add-numbers 6 numbers))))
    (when disk
      (setq *disk* (add-disk 3 disk)))
    (when (getf options :other)
      (add-disk 5 (getf options :other))
      (remf options :other))
    (let* ((hold (getf options :hold 0))
           (vdev (add-net 4 (list #x52 #x54 0 #x12 #x34 #x56) :offers offers))
           (network (progn
                      (remf options :hold)
                      (setf (vdev-hold vdev) hold)
                      (apply #'make-network :vdev vdev (append options (list :chain (list *shown* *signer*) :key *shown-key*))))))
      (setf (vdev-wire vdev)
            (lambda (frame)
              (sb-thread:with-mutex ((network-lock network))
                (setf (network-inbox network) (append (network-inbox network) (list frame))))
              (sb-thread:signal-semaphore (network-wake network))))
      (setf (network-thread network) (sb-thread:make-thread (lambda () (network-loop network)) :name "the made-up network"))
      (setq *network* network)
      (with-output-to-string (*standard-output*)
        (clara.pci:start))
      (when disk
        (said-by #'clara.disk:start)
        (said-by #'clara.fat:start))
      (said-by #'clara.random:start)
      ;; the ports at which the world of this machine took connections before it was started, when a test says so
      (setq clara.net::*doors* doors)
      (said-by #'clara.net:start))))

;; The other side is given three seconds to say something here, where a
;; machine gives it ten: nothing on this network takes longer than a
;; fraction of one, and a test that waits in vain should not wait long.
(setq clara.net:*patience* 3000)

;; Numbers in memory, the highest byte first, and the sums that the
;; protocols make of them: the example of RFC 1071 is the sum ddf2, of
;; which the checksum is 220d.
(let ((page (clara.unsafe:allocate-memory 1)))
  (clara.net::put-one page #x12)
  (clara.net::put-two (+ page 1) #x3456)
  (clara.net::put-four (+ page 3) #x789abcde)
  (clara.net::put-six (+ page 7) #xf0123456789a)
  (check '(#x12 #x3456 #x789abcde #xf0123456789a #x12 #x34 #x9a)
         (list (clara.net::one page) (clara.net::two (+ page 1)) (clara.net::four (+ page 3)) (clara.net::six (+ page 7))
               (clara.unsafe:memory-8 page) (clara.unsafe:memory-8 (+ page 1)) (clara.unsafe:memory-8 (+ page 12))))
  (dotimes (i 8)
    (setf (clara.unsafe:memory-8 (+ page 100 i)) (nth i '(#x00 #x01 #xf2 #x03 #xf4 #xf5 #xf6 #xf7))))
  (check '(#x2ddf0 #xddf2 #x220d #x2ddf0 #xf600)
         (list (clara.unsafe:internet-sum (+ page 100) 8) (clara.net::fold (clara.unsafe:internet-sum (+ page 100) 8))
               (clara.net::checksum (clara.unsafe:internet-sum (+ page 100) 8))
               (+ (clara.unsafe:internet-sum (+ page 100) 7) #xf7) (clara.unsafe:internet-sum (+ page 106) 1)))
  (clara.net::clear (+ page 100) 8)
  (check 0 (clara.unsafe:internet-sum (+ page 100) 8))
  (clara.unsafe:free-memory page 1))
(check '(#xffff #x1 #x1 #x3 0) (mapcar #'clara.net::fold '(#xffff #x10000 #xffff0001 #x20001 0)))
(check '(t nil nil t nil) (list (clara.net::after 5 4) (clara.net::after 4 5) (clara.net::after 4 4)
                                (clara.net::after 2 #xfffffffe) (clara.net::after #xfffffffe 2)))
;; Addresses as text, and text as addresses.
(check '("10.0.2.15" "255.255.255.255" "0.0.0.0" "52:54:00:12:34:56" "ff:0a:00:00:00:01")
       (list (clara.net::address-text #x0a00020f) (clara.net::address-text #xffffffff) (clara.net::address-text 0)
             (clara.net::station-text #x525400123456) (clara.net::station-text #xff0a00000001)))
(check '(#x0a00020f #xffffffff nil nil nil nil nil nil)
       (mapcar #'clara.net::text-address '("10.0.2.15" "255.255.255.255" "10.0.2" "10.0.2.256" "10.0.2.x" "releases.test" "" "1.2.3.4.5")))
(check '(("a" "b" "") ("") ("ab")) (list (clara.net::pieces "a.b." #\.) (clara.net::pieces "" #\.) (clara.net::pieces "ab" #\.)))
(check '(0 42 123456789 nil nil nil) (mapcar #'clara.net::number-of '("0" "42" "123456789" "" "4x" "1234567890")))
;; The address of something on a web server, taken apart.
(check '(("claraos.org" 80 "/" nil) ("claraos.org" 80 "/releases/latest" nil) ("10.0.2.2" 8000 "/a:b/c" nil) ("h" 1 "/" nil)
         ("claraos.org" 443 "/" t) ("claraos.org" 443 "/x?y" t) ("h" 8443 "/" t) ("h" 80 "/" t))
       (mapcar (lambda (address) (multiple-value-list (clara.net::parse-address address)))
               '("http://claraos.org" "HTTP://claraos.org/releases/latest" "http://10.0.2.2:8000/a:b/c" "http://h:1"
                 "https://claraos.org" "HTTPS://claraos.org/x?y" "https://h:8443/" "https://h:80")))
(check '("ftp://claraos.org/ is no address that begins with http:// or https://"
         "https:/claraos.org/ is no address that begins with http:// or https://"
         "http:///x names no machine, or no port of one" "http://h:0/ names no machine, or no port of one"
         "http://h:65536/ names no machine, or no port of one" "http://h:x/ names no machine, or no port of one"
         "https:///x names no machine, or no port of one")
       (mapcar (lambda (address) (condition-text (lambda () (clara.net::parse-address address))))
               '("ftp://claraos.org/" "https:/claraos.org/" "http:///x" "http://h:0/" "http://h:65536/" "http://h:x/" "https:///x")))
(check '(t t nil nil nil nil)
       (mapcar (lambda (address) (and (clara.net::secure-address-p address) t))
               '("https://claraos.org/" "HTTPS://h" "http://claraos.org/" "https://" "https:/h" nil)))

;; A machine without a network card says so, and everything that wants
;; the network says that there is none.
(new-machine)
(attach-bus)
(add-function 0 0 0 #x8086 #x29c0 #x060000)
(with-output-to-string (*standard-output*)
  (clara.pci:start))
(check (format nil "net: no network card that has a driver here: nothing is fetched from another machine~%")
       (said-by #'clara.net:start))
(check '(nil nil "this machine has no network card that has a driver here")
       (list (clara.net:address) (clara.net:station) (condition-text (lambda () (clara.net:fetch-text "http://10.0.2.2/")))))
;; A card that does not say which address it has is not started.
(check t (and (search "net: 00:04.0 did not start: the card does not say which address it has on the wire"
                      (new-network :offers (list 0 1)))
              t))
(check nil (clara.net:station))

;; A card: its address on the wire. The machine asks for nothing as it
;; starts. When something first wants the network, it asks which address it
;; has, takes the one that it is offered, and says what it learned.
(check (format nil "net: 00:04.0 is a network card, 52:54:00:12:34:56 on the wire~%") (new-network))
(check '("52:54:00:12:34:56" nil) (list (clara.net:station) (network-heard *network*)))
(let ((pages (clara.host:allocated-pages)))
  (check (format nil "net: this machine is 10.0.2.15 on its network, 10.0.2.2 is the way out, 10.0.2.2 and 8.8.8.8 know names~%")
         (said-by #'clara.net:up))
  (check '("10.0.2.15" 1 1 0) (list (clara.net:address) (count '(:dhcp 1) (network-heard *network*) :test #'equal)
                                    (count '(:dhcp 3) (network-heard *network*) :test #'equal)
                                    (network-saw *network* :who-has)))
  (check pages (clara.host:allocated-pages)))

;; The machine says that it has its address when it is asked who has it,
;; and remembers who asked. Whoever is asked about another address says
;; nothing.
(let ((asked (count '(:i-have #x0a00020f) (network-heard *network*) :test #'equal)))
  (frame-to-machine *network* #x0806 (list 0 1 8 0 6 4 0 1) (number-bytes #x525500000009 6) (number-bytes #x0a000209 4)
                    (number-bytes 0 6) (number-bytes #x0a00020f 4))
  (check t (eventually (lambda () (> (count '(:i-have #x0a00020f) (network-heard *network*) :test #'equal) asked))))
  (check #x525500000009 (cdr (assoc #x0a000209 (clara.net::card-neighbours clara.net::*card*))))
  (setq asked (network-saw *network* :i-have))
  (frame-to-machine *network* #x0806 (list 0 1 8 0 6 4 0 1) (number-bytes #x525500000009 6) (number-bytes #x0a000209 4)
                    (number-bytes 0 6) (number-bytes #x0a000210 4))
  (sleep 0.1)
  (check asked (network-saw *network* :i-have)))
;; What is on a wire is anybody's to send: frames that are too short, of
;; another kind, with a wrong checksum, or in pieces, are dropped, and the
;; card goes on.
(frame-to-machine *network* #x86dd (make-list 40 :initial-element 7))
(network-send *network* (bytes-of (list 1 2 3)))
(packet-to-machine *network* #x0a000202 #x0a00020f 17 (list 0 53 0 68 0 4 0 0))
(packet-to-machine *network* #x0a000202 #x0a00020f 6 (list 1 2 3))
(let ((frame (bytes-of (number-bytes #x525400123456 6) (number-bytes #x52550a000202 6) (list 8 0)
                       (list #x45 0 0 28 0 0 #x20 0 64 17 0 0 10 0 2 2 10 0 2 15) (list 0 53 0 68 0 8 0 0))))
  (setf (be frame 24 2) (logxor #xffff (wire-sum frame 14 34)))
  (network-send *network* frame)                                  ; a piece of a packet
  (setf (be frame 20 2) #x4000
        (be frame 24 2) #x1234)
  (network-send *network* frame))                                 ; a wrong checksum
(sleep 0.1)
(check t (clara:thread-alive-p (clara.net::card-thread clara.net::*card*)))

;; Names. The name server that the network named is asked, once for a
;; name; an address that is written out is asked of nobody.
(check '("10.0.2.2" "10.0.2.2" "10.0.2.2" "192.168.1.20" 1)
       (list (clara.net:resolve "releases.test") (clara.net:resolve "RELEASES.test") (clara.net:resolve "10.0.2.2")
             (clara.net:resolve "192.168.1.20") (network-saw *network* :name)))
(check '(:name "releases.test" 53) (find :name (network-heard *network*) :key #'car))
(check "there is no machine of the name nowhere.example" (condition-text (lambda () (clara.net:resolve "nowhere.example"))))
(check "a..b is no name that can be asked for" (condition-text (lambda () (clara.net:resolve "a..b"))))
;; Another record before the address is passed over; a server that cannot
;; say is believed; and one that is named instead of the network's is the
;; one that is asked, at the port that is named.
(setf (network-names *network*) (list (cons "long.way.round.test" #x0a000207))
      (network-another-record *network*) t)
(check "10.0.2.7" (clara.net:resolve "long.way.round.test"))
(setf (network-names-fail *network*) t)
(check "10.0.2.2, who knows names, could not say which address another.test has"
       (condition-text (lambda () (clara.net:resolve "another.test"))))
(setf (network-names-fail *network*) nil
      (network-another-record *network*) nil
      (network-names *network*) (list (cons "third.test" #x0a000208)))
(let ((clara.net:*name-server* "10.0.2.2") (clara.net:*name-port* 5353))
  (check "10.0.2.8" (clara.net:resolve "third.test"))
  (check '(:name "third.test" 5353) (find :name (network-heard *network*) :key #'car)))
(let ((clara.net:*name-server* "not an address"))
  (check "\"not an address\", in CLARA.NET:*NAME-SERVER*, is no address" (condition-text (lambda () (clara.net:resolve "fourth.test")))))
;; Nobody answers: the question is asked again, and then it is an error.
(setf (network-mute *network*) (list :names))
(let ((clara.net:*patience* 250) (clara.net:*again* 60) (asked (network-saw *network* :name)))
  (check "10.0.2.2 and 8.8.8.8, who know names, do not say which address fifth.test has"
         (condition-text (lambda () (clara.net:resolve "fifth.test"))))
  (check t (>= (- (network-saw *network* :name) asked) 3)))
(setf (network-mute *network*) nil)
(check nil (clara.net::card-listeners clara.net::*card*))

;; A card of an earlier start is another machine's: a world that was
;; saved may still hold one, and nothing is sent through it.
(let ((earlier clara.net::*card*))
  (new-network)
  (check '("the network card 00:04.0 is from an earlier start" nil)
         (list (condition-text (lambda () (clara.net::arp-out earlier nil 0 #x0a000202))) (network-heard *network*))))

;; Answers that are for another question, that come from somebody who was
;; not asked, or that are no answers at all, are nobody's: the machine goes
;; on waiting for its own. And an answer that arrives damaged is no answer:
;; the question is asked again.
(new-network :strangers t)
(check (format nil "net: this machine is 10.0.2.15 on its network, 10.0.2.2 is the way out, 10.0.2.2 and 8.8.8.8 know names~%")
       (said-by #'clara.net:up))
(check "10.0.2.2" (clara.net:resolve "releases.test"))
(new-network :spoil-names 1)
(said-by #'clara.net:up)
(let ((clara.net:*again* 60))
  (check '("10.0.2.2" 2) (list (clara.net:resolve "releases.test") (network-saw *network* :name))))

;; What arrives for the machine that is not right is dropped without a
;; word. Here that is seen by what the machine does say: to a piece of a
;; connection that it does not have, that it has no such connection.
(new-network)
(said-by #'clara.net:up)
(flet ((given-up ()
         (sleep 0.1)
         (network-saw *network* :given-up))
       (stray (&key (to #x0a00020f) (header 20) (pieces #x4000) spoil-packet spoil-segment (flags #x10))
         (let* ((segment (bytes-of (list 0 80 #xc0 #x01) (number-bytes 1000 4) (number-bytes 2000 4) (list #x50 flags #xff #xff 0 0 0 0)))
                (packet (bytes-of (list (+ #x40 (floor header 4)) 0) (number-bytes (+ header (length segment)) 2) (list 0 0)
                                  (number-bytes pieces 2) (list 64 6 0 0) (number-bytes #x0a000202 4) (number-bytes to 4)
                                  (make-list (- header 20) :initial-element 1))))
           (setf (be segment 16 2) (logxor #xffff (wire-sum segment 0 20 (around-sum #x0a000202 to 6 20)))
                 (be packet 10 2) (logxor #xffff (wire-sum packet 0 header)))
           (when spoil-packet
             (setf (aref packet 8) 63))
           (when spoil-segment
             (setf (aref segment 7) 1))
           (frame-to-machine *network* #x0800 packet segment))))
  (stray)
  (check 1 (given-up))
  (stray :header 24)                       ; more in its head than the twenty bytes: what it carries begins later
  (check 2 (given-up))
  (stray :spoil-packet t)
  (stray :spoil-segment t)
  (stray :pieces #x2000)                   ; the first piece of a packet
  (stray :pieces #x0005)                   ; a later piece of one
  (stray :to #x0a000210)                   ; for another machine
  (stray :flags #x04)                      ; one that gives up itself is not answered by giving up
  (check 2 (given-up)))

;; A network on which nobody says which address the machine has, or says
;; it and then takes it back: an error, and the machine has no address.
(new-network :mute (list :dhcp))
(let ((clara.net:*patience* 250) (clara.net:*again* 60))
  (check "no DHCP server says which address this machine has on its network" (condition-text #'clara.net:up))
  (check t (>= (count '(:dhcp 1) (network-heard *network*) :test #'equal) 3)))
(check '(nil nil) (list (clara.net::card-address clara.net::*card*) (clara.net::card-listeners clara.net::*card*)))
(new-network :nak t)
(let ((clara.net:*patience* 250) (clara.net:*again* 60))
  (check "the DHCP server that offered this machine an address did not give it" (condition-text #'clara.net:up)))
;; And one where nobody says who has an address: a machine of the network
;; is not reached, and neither is one beyond it, once the machine has
;; forgotten which card the way out has, which it knew from the answer
;; that gave it its address.
(new-network :mute (list :arp) :names nil)
(let ((clara.net:*patience* 250) (clara.net:*again* 60))
  (said-by #'clara.net:up)
  (check '((#x0a000202 . #x52550a000202)) (clara.net::card-neighbours clara.net::*card*))
  (check "nobody on the network says that it has the address 10.0.2.9" (condition-text (lambda () (clara.net:fetch-text "http://10.0.2.9/x"))))
  (setf (clara.net::card-neighbours clara.net::*card*) nil)
  (check "nobody on the network says that it has the address 10.0.2.2" (condition-text (lambda () (clara.net:fetch-text "http://192.168.7.7/x")))))

;;; Files from a web server, and what a wire does to them on the way.

(defvar *long* (let ((text (make-string 200000)))
                 (dotimes (i (length text) text)
                   (setf (char text i) (code-char (+ 32 (mod (* i 7) 90)))))))

;; What a fetch gives of an address: the text, when it is one; and the page
;; frames that are in use are the ones that were before.
(defun fetched (address &rest options)
  (let ((pages (clara.host:allocated-pages)))
    (prog1 (handler-case (apply #'clara.net:fetch-text address options)
             (error (condition) (list :error (princ-to-string condition))))
      (unless (eventually (lambda () (= pages (clara.host:allocated-pages))))
        (failed "a fetch of ~A kept ~D page frames" address (- (clara.host:allocated-pages) pages))))))

(defun files ()
  (list (cons "/hello.txt" "hello from the made-up network")
        (cons "/empty" "")
        (cons "/long" *long*)
        (cons "/unsized" (list :unsized "nobody said how long this is"))
        (cons "/unsized-long" (list :unsized *long*))
        (cons "/short" (list :short "less than was promised"))
        (cons "/moved" (list :moved "/hello.txt"))
        (cons "/moved-far" (list :moved "http://releases.test/moved"))
        (cons "/secure" (list :moved "https://claraos.org/hello.txt"))
        (cons "/round" (list :moved "/round"))
        (cons "/nowhere" (list :moved ""))
        (cons "/broken" (list :status 500))
        (cons "/no-http" (list :raw (format nil "this is not what a web server says~C~C~C~C" (code-char 13) (code-char 10)
                                            (code-char 13) (code-char 10))))
        (cons "/endless-head" (list :raw (make-string 20000 :initial-element #\h)))
        (cons "/chunks" (list :chunked "a file that comes in chunks, each longer than the one before it"))
        (cons "/long-chunks" (list :chunked *long*))
        (cons "/no-chunks" (list :chunked ""))
        (cons "/cut-chunks" (list :chunked "chunks without the one that ends them" t))))

(check t (and (search "is a network card" (new-network :files (files))) t))
(said-by #'clara.net:up)
(check '("hello from the made-up network" "" "nobody said how long this is" "hello from the made-up network"
         "hello from the made-up network")
       (list (fetched "http://10.0.2.2/hello.txt") (fetched "http://releases.test/empty") (fetched "http://releases.test:8080/unsized")
             (fetched "http://releases.test/moved") (fetched "http://releases.test/moved-far")))
(check '((:get "/hello.txt") (:get "/empty") (:get "/unsized") (:get "/moved") (:get "/hello.txt") (:get "/moved-far") (:get "/moved")
         (:get "/hello.txt"))
       (reverse (remove :get (network-heard *network*) :key #'car :test-not #'eq)))
(check '(80 80 8080) (subseq (reverse (mapcar #'second (remove :connect (network-heard *network*) :key #'car :test-not #'eq))) 0 3))
;; A long file comes whole, in a hundred and more pieces, over numbers that go round to zero on the way.
(check t (equal *long* (fetched "http://releases.test/long")))
(check t (equal *long* (fetched "http://releases.test/unsized-long")))
(multiple-value-bind (memory bytes pages) (clara.net:fetch "http://releases.test/long")
  (check (list 200000 (clara.host:sha-512-of (octets *long*)) t)
         (list bytes (clara.unsafe:sha-512 memory bytes) (>= (* 4096 pages) bytes)))
  (clara.unsafe:free-memory memory pages))
;; What a server can say that is no file.
(check '((:error "releases.test answers 404 to the request for /nothing")
         (:error "releases.test answers 500 to the request for /broken")
         (:error "releases.test ended the connection after 22 bytes of the 122 of /short")
         (:error "there is no machine of the name claraos.org")
         (:error "http://releases.test/round is said to be somewhere else more often than is followed")
         (:error "releases.test answers 301 to the request for /nowhere")
         (:error "releases.test does not answer as HTTP does")
         (:error "releases.test answers with a head that does not end"))
       (mapcar #'fetched '("http://releases.test/nothing" "http://releases.test/broken" "http://releases.test/short"
                           "http://releases.test/secure" "http://releases.test/round" "http://releases.test/nowhere"
                           "http://releases.test/no-http" "http://releases.test/endless-head")))
;; A file that comes in chunks is put together.
(check '("a file that comes in chunks, each longer than the one before it" t ""
         (:error "releases.test sends /cut-chunks in chunks that do not come to an end"))
       (list (fetched "http://releases.test/chunks") (equal *long* (fetched "http://releases.test/long-chunks"))
             (fetched "http://releases.test/no-chunks") (fetched "http://releases.test/cut-chunks")))
;; No more is taken than was asked for, whether the server says how long the file is or not.
(check '((:error "http://releases.test/long is 200000 bytes, and more than 100000 are not taken")
         (:error "10.0.2.2 sends more than the 100000 bytes that were to be taken from it") t)
       (list (fetched "http://releases.test/long" :limit 100000) (fetched "http://releases.test/unsized-long" :limit 100000)
             (equal *long* (fetched "http://releases.test/long" :limit 200000))))
;; A connection that is over is forgotten once both sides have said that they are done.
(check t (eventually (lambda () (null (clara.net::card-connections clara.net::*card*)))))

;; A wire loses things, changes them, and brings them in another order.
;; Whatever becomes of the pieces of a file on the way, the file is the
;; file: a piece that did not come is sent again when the machine says
;; what it has, a piece that was changed fails its checksum and counts as
;; one that did not come, and a piece that comes early is not taken.
(dolist (accident '((:drop (0)) (:drop (3 4 5 77)) (:drop (35)) (:spoil (0 1 50)) (:swap (0 9 10 60)) (:drop (2) :spoil (3) :swap (4))
                    (:piece 100 :drop (5 6 7 8 1000)) (:piece 1 :drop (3)) (:first #xffffffff) (:first 0)))
  (apply #'new-network :files (list (cons "/long" (if (eql (getf accident :piece) 1) (subseq *long* 0 300) *long*))) accident)
  (said-by #'clara.net:up)
  (let ((whole (fetched "http://releases.test/long")))
    (check (list accident t) (list accident (equal whole (if (eql (getf accident :piece) 1) (subseq *long* 0 300) *long*))))))
;; A card that does not send what it is given: whatever would have
;; answered through it gives up after a while, and the thread that takes
;; what arrives goes on, having dropped the frame that it could not answer.
(new-network :hold 100)
(said-by #'clara.net:up)
(flet ((stray ()
         (let ((segment (bytes-of (list 0 80 #xc0 #x01) (number-bytes 1000 4) (number-bytes 2000 4) (list #x50 #x10 #xff #xff 0 0 0 0))))
           (setf (be segment 16 2) (logxor #xffff (wire-sum segment 0 20 (around-sum #x0a000202 #x0a00020f 6 20))))
           (packet-to-machine *network* #x0a000202 #x0a00020f 6 segment))))
  (dotimes (i 8)
    (stray))
  (check t (eventually (lambda () (plusp (clara.net::card-dropped clara.net::*card*)))))
  (check '(t 6) (list (clara:thread-alive-p (clara.net::card-thread clara.net::*card*)) (network-saw *network* :given-up))))

;; A machine that is on the machine's own network is spoken to itself,
;; and one that is not, by the way out: each frame goes to the card of the
;; one or of the other.
(new-network :files (files))
(said-by #'clara.net:up)
(check '("hello from the made-up network" "hello from the made-up network")
       (list (fetched "http://10.0.2.9/hello.txt") (fetched "http://192.168.7.7/hello.txt")))
(check '((#x525500000009) (#x52550a000202))
       (flet ((cards (address)
                (remove-duplicates (mapcar #'second (remove-if-not (lambda (note) (and (eq (car note) :packet-to) (= (third note) address)))
                                                                    (network-heard *network*))))))
         (list (cards #x0a000209) (cards #xc0a80707))))
;; The other side hears that the machine knows a file to be over.
(check t (eventually (lambda () (= (network-saw *network* :end-heard) 2))))
;; A card may say late that it has sent a frame, and has the page of the
;; frame until then: three frames are on their way here at any moment.
(new-network :files (list (cons "/long" *long*)) :hold 3)
(said-by #'clara.net:up)
(check t (equal *long* (fetched "http://releases.test/long")))
;; The beginning of a connection is answered first by something that is
;; no answer to it: that is not taken for the answer.
(new-network :files (files) :false-start t)
(said-by #'clara.net:up)
(check "hello from the made-up network" (fetched "http://10.0.2.2/hello.txt"))
;; The head of an answer comes in two pieces, with the end of it between
;; them and a while between the pieces: the end is found all the same.
(new-network :files (list (cons "/slow" (list :raw (format nil "HTTP/1.1 200 OK~C~CContent-Length: 5~C~C~C~Chello"
                                                                (code-char 13) (code-char 10) (code-char 13) (code-char 10)
                                                                (code-char 13) (code-char 10)))))
             :piece 36 :pause 0.15)
(said-by #'clara.net:up)
(check "hello" (fetched "http://10.0.2.2/slow"))
;; A piece that is lost costs the other side that piece, and not what
;; came after it: those pieces are kept until the one before them is there.
(new-network :files (list (cons "/long" *long*)) :drop (list 0 60))
(said-by #'clara.net:up)
(check '(t t) (list (equal *long* (fetched "http://releases.test/long")) (< (network-pieces *network*) 150)))
;; The end of a file that does not say how long it is counts only when
;; everything before it is there: here the last piece comes after it.
(new-network :files (list (cons "/unsized-long" (list :unsized *long*))) :drop (list 136))
(said-by #'clara.net:up)
(check t (equal *long* (fetched "http://releases.test/unsized-long")))
;; The other side hears that the machine has done with a connection.
(check t (eventually (lambda () (plusp (network-saw *network* :ended)))))
;; The beginning of a connection is lost, twice, and so is the request:
;; each is said again until it is heard.
(new-network :files (files) :lose-opening 2 :lose-request 2)
(said-by #'clara.net:up)
(let ((clara.net:*again* 50))
  (check "hello from the made-up network" (fetched "http://10.0.2.2/hello.txt")))
(check '(3 1) (list (network-saw *network* :connect) (network-saw *network* :get)))
;; A server that takes no connection, one that does not answer at all, one
;; that takes a connection and then says nothing, and one that never says
;; that a file without a length is over.
(new-network :files (files) :refuse t)
(said-by #'clara.net:up)
(check '(:error "10.0.2.2 takes no connection at its port 80") (fetched "http://10.0.2.2/hello.txt"))
(new-network :files (files) :mute (list :connections))
(said-by #'clara.net:up)
(let ((clara.net:*patience* 250) (clara.net:*again* 60))
  (check '(:error "10.0.2.2 does not answer at its port 81") (fetched "http://10.0.2.2:81/hello.txt")))
(new-network :files (files) :lose-request 1000)
(said-by #'clara.net:up)
(let ((clara.net:*patience* 250) (clara.net:*again* 60))
  (check '(:error "10.0.2.2 does not say that it has what it was sent") (fetched "http://10.0.2.2/hello.txt")))
(new-network :files (files) :no-end t)
(said-by #'clara.net:up)
(let ((clara.net:*patience* 300))
  (check '("hello from the made-up network" (:error "10.0.2.2 has sent nothing for 0 seconds"))
         (list (fetched "http://10.0.2.2/hello.txt") (fetched "http://10.0.2.2/unsized"))))
;; The machine has said that it is done with those connections, and the
;; other side never says so of itself: after a while the machine forgets
;; them. Whoever goes on speaking then is told that there is no such
;; connection.
(check t (eventually (lambda () (null (clara.net::card-connections clara.net::*card*)))))
(let ((connection (car (network-connections *network*))))
  (segment-to-machine *network* connection (+ (served-first connection) 1 (served-sent connection)) #x18 (list 1 2 3)))
(check t (eventually (lambda () (plusp (network-saw *network* :given-up)))))

;;; What the first network could not do: say whether a machine is there
;;; and hear that one is not (ICMP), keep its address, ask more than one
;;; who knows names, and send more over a connection than a request.

(check '("a" "a and b" "a, b and c") (mapcar #'clara.net::listed '(("a") ("a" "b") ("a" "b" "c"))))

;; Is a machine there? It is asked, and says so: how long that took is a
;; number of milliseconds.
(new-network)
(said-by #'clara.net:up)
(check '(t t t) (list (<= 0 (clara.net:ping "10.0.2.2") 3000) (<= 0 (clara.net:ping "10.0.2.9") 3000)
                      (<= 0 (clara.net:ping "releases.test") 3000)))
(check '((:ping #x0a000202 1) (:ping #x0a000209 1) (:ping #x0a000202 1))
       (reverse (remove :ping (network-heard *network*) :key #'car :test-not #'eq)))
(check nil (clara.net::card-echoes clara.net::*card*))
;; One that does not answer is asked again, each time with the next number, and then it is an error.
(setf (network-mute *network*) (list :ping))
(let ((clara.net:*patience* 250) (clara.net:*again* 60) (asked (network-saw *network* :ping)))
  (check "10.0.2.2 does not answer a ping" (condition-text (lambda () (clara.net:ping "10.0.2.2"))))
  (check '(1 2 3)
         (let ((numbers (mapcar #'third (nthcdr asked (reverse (remove :ping (network-heard *network*) :key #'car :test-not #'eq))))))
           (and (>= (length numbers) 3) (subseq numbers 0 3)))))
(setf (network-mute *network*) nil)
;; The way out says that a machine cannot be reached: that is the answer, and at once.
(setf (network-unreachable *network*) t)
(check "10.0.2.2 says that 192.168.7.7 cannot be reached" (condition-text (lambda () (clara.net:ping "192.168.7.7"))))
(setf (network-unreachable *network*) nil)
(check nil (clara.net::card-echoes clara.net::*card*))
;; The machine says that it is there when it is asked, with the bytes that
;; it was sent; not when everybody is asked, not when the question arrives
;; damaged, and an answer that nobody here asked for is nobody's.
(control-to-machine *network* #x0a000202 #x0a00020f 8 0 #xbeef0007 (list 1 2 3 4 5))
(check t (and (eventually (lambda () (plusp (network-saw *network* :pong)))) t))
(check '(:pong (#xbe #xef 0 7 1 2 3 4 5)) (find :pong (network-heard *network*) :key #'car))
(control-to-machine *network* #x0a000202 #xffffffff 8 0 #xbeef0008 (list 1 2 3))
(packet-to-machine *network* #x0a000202 #x0a00020f 1 (list 8 0 0 0 #xbe #xef 0 9 1 2 3))
(control-to-machine *network* #x0a000202 #x0a00020f 0 0 #x12340001 (list 1 2 3))
(control-to-machine *network* #x0a000202 #x0a00020f 3 1 0 (list #x45 0 0 28))
(sleep 0.1)
(check '(1 t) (list (network-saw *network* :pong) (clara:thread-alive-p (clara.net::card-thread clara.net::*card*))))
;; A packet of UDP's for a port where nobody listens is answered with the
;; word that it was not taken (3), with the head of the packet and its
;; first eight bytes; one that was for everybody is not answered.
(datagram-to-machine *network* #x0a000202 #x0a00020f 4000 9 (list 104 105))
(check t (and (eventually (lambda () (plusp (network-saw *network* :not-taken)))) t))
(let ((word (find :not-taken (network-heard *network*) :key #'car)))
  (check '(3 28 #x45 17 (10 0 2 2) (10 0 2 15) (#x0f #xa0 0 9))
         (list (second word) (length (third word)) (first (third word)) (nth 9 (third word))
               (subseq (third word) 12 16) (subseq (third word) 16 20) (subseq (third word) 20 24))))
(datagram-to-machine *network* #x0a000202 #xffffffff 4000 9 (list 104 105))
(sleep 0.1)
(check '(1 nil) (list (network-saw *network* :not-taken) (clara.net::card-trouble clara.net::*card*)))

;; The way out says that a machine cannot be reached: a connection to it
;; ends there, and not when patience does. Such a word with another
;; number than the connection's own is anybody's, and ends nothing.
(new-network :files (files) :unreachable t)
(said-by #'clara.net:up)
(let ((begun (get-internal-real-time)))
  (check '(:error "10.0.2.2 says that 192.168.7.7 cannot be reached") (fetched "http://192.168.7.7/hello.txt"))
  (check t (< (- (get-internal-real-time) begun) internal-time-units-per-second)))
(new-network :files (files) :unreachable :forged)
(said-by #'clara.net:up)
(let ((clara.net:*patience* 250) (clara.net:*again* 60))
  (check '(:error "192.168.7.7 does not answer at its port 80") (fetched "http://192.168.7.7/hello.txt")))

;; Who knows names. The network names two. The second is asked as soon as
;; the word comes back that the first takes no questions, or when the
;; first says that it cannot say; when neither can, that is the error, and
;; while neither says anything both are asked in turn.
(new-network :names-closed (list #x0a000202))
(said-by #'clara.net:up)
(let ((begun (get-internal-real-time)))
  (check "10.0.2.2" (clara.net:resolve "releases.test"))
  (check t (< (- (get-internal-real-time) begun) (floor internal-time-units-per-second 2))))
(check '((:name-asked-of #x08080808) (:name-asked-of #x0a000202))
       (remove :name-asked-of (network-heard *network*) :key #'car :test-not #'eq))
(check '(nil nil) (list (clara.net::card-closed clara.net::*card*) (clara.net::card-listeners clara.net::*card*)))
(new-network :names-closed t)
(said-by #'clara.net:up)
(check "10.0.2.2 takes no questions about names at its port 53" (condition-text (lambda () (clara.net:resolve "releases.test"))))
(check '(nil nil) (list (clara.net::card-closed clara.net::*card*) (clara.net::card-listeners clara.net::*card*)))
(new-network :names-fail t)
(said-by #'clara.net:up)
(check '("10.0.2.2, who knows names, could not say which address releases.test has" 2)
       (list (condition-text (lambda () (clara.net:resolve "releases.test"))) (network-saw *network* :name)))
(new-network :mute (list :names))
(said-by #'clara.net:up)
(let ((clara.net:*patience* 250) (clara.net:*again* 60))
  (check "10.0.2.2 and 8.8.8.8, who know names, do not say which address releases.test has"
         (condition-text (lambda () (clara.net:resolve "releases.test"))))
  (check '(#x0a000202 #x08080808 #x0a000202)
         (let ((asked (reverse (mapcar #'second (remove :name-asked-of (network-heard *network*) :key #'car :test-not #'eq)))))
           (and (>= (length asked) 3) (subseq asked 0 3)))))
;; An answer that is too long for a packet of UDP's comes cut short, and
;; the server is asked again by TCP, where the question and the answer
;; each have their length before them.
(new-network :cut t :names (list (cons "long.answer.test" #x0a000207)))
(said-by #'clara.net:up)
(check '("10.0.2.7" (:name-whole "long.answer.test") (:connect 53))
       (list (clara.net:resolve "long.answer.test") (find :name-whole (network-heard *network*) :key #'car)
             (find :connect (network-heard *network*) :key #'car)))
(check "there is no machine of the name short.answer.test" (condition-text (lambda () (clara.net:resolve "short.answer.test"))))
(check t (eventually (lambda () (null (clara.net::card-connections clara.net::*card*)))))
;; What was said of a name holds for as long as the answer said, and the
;; name is asked for again after that.
(new-network :ttl 0)
(said-by #'clara.net:up)
(check '("10.0.2.2" "10.0.2.2" 2 1)
       (list (clara.net:resolve "releases.test") (clara.net:resolve "releases.test") (network-saw *network* :name)
             (length (clara.net::card-known clara.net::*card*))))

;; The address is the machine's for a time. When half of that is over, the
;; machine asks the server that gave it whether it may keep it, the
;; server alone and from the address that it has, and is told that it
;; may: so it has the address after the time for which it was first given.
(new-network :lease-time 1)
(said-by #'clara.net:up)
(check '(1000 0) (list (clara.net::card-lease clara.net::*card*) (network-saw *network* :dhcp-keep)))
(sleep 1.3)
(check '(#x0a00020f t 1 nil)
       (list (clara.net::card-address clara.net::*card*) (>= (network-saw *network* :dhcp-keep) 1)
             (count '(:dhcp 1) (network-heard *network*) :test #'equal) (clara.net::card-trouble clara.net::*card*)))
;; A server that says that the machine may not keep it takes the address
;; away, and so does the time, when the server says nothing: whatever
;; wants the network next asks for an address anew.
(new-network :lease-time 1 :renewals :deny)
(said-by #'clara.net:up)
(check t (eventually (lambda () (null (clara.net::card-address clara.net::*card*)))))
(setf (network-renewals *network*) nil)
(check (format nil "net: this machine is 10.0.2.15 on its network, 10.0.2.2 is the way out, 10.0.2.2 and 8.8.8.8 know names~%")
       (said-by #'clara.net:up))
(new-network :lease-time 1 :renewals :mute)
(said-by #'clara.net:up)
(check t (eventually (lambda () (null (clara.net::card-address clara.net::*card*)))))
(check t (>= (network-saw *network* :dhcp-keep) 1))

;; How long a segment the other side takes, among the options of a
;; segment that begins a connection.
(let ((page (clara.unsafe:allocate-memory 1)))
  (flet ((longest (&rest options)
           (clara.net::clear page 64)
           (loop for byte in options for i from 20 do (setf (clara.unsafe:memory-8 (+ page i)) byte))
           (clara.net::longest-piece page (+ 20 (length options)))))
    (check '(1460 536 1200 nil nil nil nil nil)
           (list (longest 2 4 5 180) (longest 1 1 2 4 2 24) (longest 3 3 7 1 2 4 4 176) (longest) (longest 0 2 4 5 180)
                 (longest 2 3 5 180) (longest 2 4 5) (longest 3 0 2 4 5 180))))
  (clara.unsafe:free-memory page 1))

;; What the machine sends over a connection arrives, all of it and in its
;; order: BYTES bytes go to the port 9 of the network, where everything is
;; taken. T when what was taken there is what was sent; and the page
;; frames that are in use afterwards are the ones that were before.
(defun sent-whole (bytes &rest options)
  (apply #'new-network options)
  (said-by #'clara.net:up)
  (let* ((before (clara.host:allocated-pages)) (connection (clara.net::begin clara.net::*card* #x0a000202 9 0))
         (pages (ceiling bytes 4096)) (memory (clara.unsafe:allocate-memory pages)))
    (unwind-protect
         (progn
           (clara.unsafe:string-memory (subseq *long* 0 bytes) memory)
           (clara.net::say-bytes connection memory bytes))
      (clara.unsafe:free-memory memory pages)
      (clara.net::disconnect connection))
    (unless (eventually (lambda () (= before (clara.host:allocated-pages))))
      (failed "a connection that sent ~D bytes kept ~D page frames" bytes (- (clara.host:allocated-pages) before)))
    (equalp (network-sunk *network*) (octets (subseq *long* 0 bytes)))))

(check '(t t t nil) (list (sent-whole 200000) (<= (network-longest-seen *network*) 1400) (> (network-seen *network*) 140)
                          (clara.net::card-trouble clara.net::*card*)))
;; The other side says how long a piece it takes, and no piece is longer;
;; one that does not say is sent pieces of 536 bytes.
(check '(t 500) (list (sent-whole 30000 :longest 500) (network-longest-seen *network*)))
(check '(t 536) (list (sent-whole 30000 :longest nil) (network-longest-seen *network*)))
;; Pieces are lost on the way: the first, one in the middle, some in a
;; row, and the last. Each goes out again, when the other side has said
;; three times that it lacks it or when it has said nothing for a while.
(let ((clara.net:*again* 50))
  (dolist (lost '((0) (1) (3 4 5 30) (10 11 12 13 14 15 16 17 18 19 20) (142) (140 141 142 143 144)))
    (check (list lost t) (list lost (sent-whole 200000 :lose-pieces lost)))))
;; No more is on its way than the other side has said that it has room
;; for: the network fails the run when more comes.
(check t (sent-whole 100000 :room 3000))
;; A side that has no room at all is asked now and then whether it has
;; some again, with one byte, and when it has, the rest follows.
(new-network :room 0)
(said-by #'clara.net:up)
(let* ((clara.net:*again* 50) (connection (clara.net::begin clara.net::*card* #x0a000202 9 0))
       (memory (clara.unsafe:allocate-memory 2)))
  (clara.unsafe:string-memory (subseq *long* 0 8000) memory)
  (let ((thread (clara:make-thread (lambda () (clara.net::say-bytes connection memory 8000)))))
    (sleep 0.4)
    (check '(t nil) (list (clara:thread-alive-p thread) (network-sunk *network*)))
    (setf (network-room *network*) 65535)
    (check t (eventually (lambda () (not (clara:thread-alive-p thread)))))
    (check t (equalp (network-sunk *network*) (octets (subseq *long* 0 8000)))))
  (clara.unsafe:free-memory memory 2)
  (clara.net::disconnect connection))
;; The way is narrower than the machine thinks: a packet that is too long
;; does not arrive, and the machine is told how long one may be. What it
;; sends from then on is no longer than that.
(let ((clara.net:*again* 50))
  (check '(t t) (list (sent-whole 60000 :narrow 600) (plusp (network-saw *network* :too-long)))))
;; The word that the other side gives a connection up is believed when it
;; has the number that is expected next, and not otherwise: anybody can
;; send such a word.
(new-network)
(said-by #'clara.net:up)
(let* ((connection (clara.net::begin clara.net::*card* #x0a000202 9 0)) (served (car (network-connections *network*))))
  (segment-to-machine *network* served (+ (served-first served) 5000) #x04 nil)
  (sleep 0.1)
  (check :open (clara.net::connection-state connection))
  (segment-to-machine *network* served (+ (served-first served) 1) #x04 nil)
  (check t (eventually (lambda () (eq (clara.net::connection-state connection) :broken))))
  (check "10.0.2.2 has given the connection up" (condition-text (lambda () (clara.net::wait-for connection (lambda () nil)))))
  (clara.net::disconnect connection))
(check nil (clara.net::card-connections clara.net::*card*))

;;; A machine that listens: the connections that other machines open to a
;;; port of the machine's are taken there, and each is handed to a
;;; function, as a stream of lines, in a thread of its own. A connection
;;; that the machine opens is such a stream too. And the machine reaches
;;; itself.

;; What is said to the machine comes back in capitals, a line at a time.
(defun shout (stream)
  (loop
    (let ((line (read-line stream nil)))
      (unless line
        (return))
      (write-line (string-upcase line) stream))))

;; The machine has forgotten every connection, and the page frames that
;; are in use are the ones that were.
(defun settled (pages)
  (and (eventually (lambda () (null (clara.net::card-connections clara.net::*card*))))
       (eventually (lambda () (= pages (clara.host:allocated-pages))))
       t))

(defun done-p (call)
  (and (eventually (lambda () (call-done call))) t))

(new-network)
(said-by #'clara.net:up)
(let ((pages (clara.host:allocated-pages)))
  (check '(7 ((7 0 0 nil))) (list (clara.net:serve 7 'shout) (clara.net:serving)))
  ;; Lines that end as the Internet's protocols end theirs, and as others do; and what is said last, without
  ;; the end of a line, is a line. When the other side is done, the function is, and then the machine.
  (let ((call (call-machine 7 :say (format nil "hello~%is anybody there~C~%and a last line without its end" (code-char 13)) :end t)))
    (check t (done-p call))
    (check (format nil "HELLO~%IS ANYBODY THERE~%AND A LAST LINE WITHOUT ITS END~%") (call-text call))
    (check '(:open t) (list (call-state call) (and (eventually (lambda () (call-end-heard call))) t))))
  (check '(t ((7 1 0 nil)) nil) (list (settled pages) (clara.net:serving) (clara.net::card-trouble clara.net::*card*)))
  ;; Two at once, each in a thread of its own. A third is told that there is no connection for it while as
  ;; many are open as may be, and one is taken again when one of the two is over.
  (clara.net:stop-serving 7)
  (clara.net:serve 7 'shout :most 2)
  (let ((one (call-machine 7 :say (format nil "one~%"))) (two (call-machine 7 :say (format nil "two~%"))))
    (check t (eventually (lambda () (and (string= (call-text one) (format nil "ONE~%"))
                                         (string= (call-text two) (format nil "TWO~%"))))))
    (check '((7 2 2 nil)) (clara.net:serving))
    (let ((three (call-machine 7 :say (format nil "three~%"))))
      (check t (eventually (lambda () (eq (call-state three) :refused)))))
    (setf (call-end one) t)
    (check t (done-p one))
    (let ((four (call-machine 7 :say (format nil "four~%") :end t)))
      (check t (done-p four))
      (check (format nil "FOUR~%") (call-text four)))
    ;; When no more are to be taken, the one that is still open is over, and the next is told that there is none.
    (check t (clara.net:stop-serving 7))
    (check t (done-p two))
    (setf (call-end two) t)
    (let ((five (call-machine 7 :say "x")))
      (check t (eventually (lambda () (eq (call-state five) :refused)))))
    (check '(nil nil) (list (clara.net:serving) (clara.net:stop-serving 7))))
  (check t (settled pages))
  ;; The machine's answer to a beginning is lost, twice: the beginning comes again and is answered again,
  ;; with the number that the first answer had.
  (clara.net:serve 7 'shout)
  (let ((call (call-machine 7 :lose-answers 2 :say (format nil "at last~%") :end t)))
    (check t (done-p call))
    (check (list (format nil "AT LAST~%") 3 1)
           (list (call-text call) (length (call-answers call)) (length (remove-duplicates (call-answers call))))))
  (check t (settled pages))
  ;; A machine that begins and does not go on is answered, and then forgotten, with what was kept for it.
  (let ((patience clara.net:*patience*))
    (setq clara.net:*patience* 300)
    (unwind-protect
         (let ((call (call-machine 7 :half t)))
           (check t (eventually (lambda () (= (length (call-answers call)) 1))))
           (check '(1 ((7 1 0 nil))) (list (length (clara.net::card-connections clara.net::*card*)) (clara.net:serving)))
           (check '(t ((7 1 0 nil))) (list (settled pages) (clara.net:serving))))
      (setq clara.net:*patience* patience)))
  (clara.net:stop-serving 7))

;; A long text to the machine, which is read a line at a time while it
;; arrives: the machine makes room as it reads, and says that it has. And
;; a long text from the machine, of which pieces are lost on the way.
(defvar *lines*
  (with-output-to-string (out)
    (dotimes (i 4000)
      (format out "line ~D of what a machine of the network says to the machine, which is a good deal~%" i))))

(defun count-lines (stream)
  (let ((lines 0) (characters 0))
    (loop
      (let ((line (read-line stream nil)))
        (unless line
          (return))
        (setq lines (1+ lines)
              characters (+ characters (length line)))))
    (format stream "~D lines, ~D characters~%" lines characters)))

(new-network)
(said-by #'clara.net:up)
(let ((pages (clara.host:allocated-pages)))
  (clara.net:serve 9000 #'count-lines)
  (let ((call (call-machine 9000 :say *lines* :end t)))
    (check t (done-p call))
    (check (format nil "4000 lines, ~D characters~%" (- (length *lines*) 4000)) (call-text call)))
  (clara.net:serve 9001 (lambda (stream) (read-line stream) (write-string *long* stream)))
  (dolist (lose '(nil (0) (3 4 5 30) (100)))
    (let ((call (call-machine 9001 :say (format nil "go~%") :lose lose)))
      (check t (done-p call))
      (check (list lose t) (list lose (string= (call-text call) *long*)))
      (setf (call-end call) t)))
  (check '(t nil) (list (settled pages) (clara.net::card-trouble clara.net::*card*)))
  ;; What the function ends in is kept, when that is an error: a line that is no text; a line that is longer
  ;; than is kept of one; an error of the function's own; a line that does not come; and another side that
  ;; stops saying that it has what it is sent.
  (clara.net:serve 9002 'shout)
  (let ((call (call-machine 9002 :say (bytes-of (list 104 105 10 #xff #xfe 10)) :end t)))
    (check t (done-p call))
    (check (list (format nil "HI~%") '(9002 1 0 "10.0.2.2 sent a line that is no text: it is not UTF-8"))
           (list (call-text call) (assoc 9002 (clara.net:serving)))))
  (let ((call (call-machine 9002 :say (make-string 70000 :initial-element #\a))))
    (check t (done-p call))
    (check '(9002 2 0 "10.0.2.2 sent a line of more than 65536 bytes, which is more than is kept of one")
           (assoc 9002 (clara.net:serving)))
    (setf (call-end call) t))
  (clara.net:serve 9003 (lambda (stream) (error "nothing is to be had here, ~A" (read-line stream))))
  (let ((call (call-machine 9003 :say (format nil "whoever asks~%"))))
    (check t (done-p call))
    (check '(9003 1 0 "nothing is to be had here, whoever asks") (assoc 9003 (clara.net:serving)))
    (setf (call-end call) t))
  (let ((patience clara.net:*patience*))
    (setq clara.net:*patience* 300)
    (unwind-protect
         (progn
           (let ((call (call-machine 9002 :say "a line that does not end")))
             (check t (done-p call))
             (check '(9002 3 0 "10.0.2.2 has sent nothing for 0 seconds") (assoc 9002 (clara.net:serving)))
             (setf (call-end call) t))
           (let ((call (call-machine 9001 :say (format nil "go~%") :mute t)))
             (check t (eventually (lambda () (equal (fourth (assoc 9001 (clara.net:serving)))
                                                    "10.0.2.2 does not say that it has what it was sent"))))
             (setf (call-mute call) nil)))
      (setq clara.net:*patience* patience)))
  ;; A function that is done, and another side that goes on speaking: it is told that nobody takes that.
  (clara.net:serve 9004 (lambda (stream) (read-line stream)))
  (let ((call (call-machine 9004 :say (format nil "one line~%"))))
    (check t (done-p call))
    (setf (call-say call) (octets (format nil "one line~%and more, which nobody takes~%")))
    (check t (eventually (lambda () (eq (call-state call) :reset)))))
  (dolist (port '(9000 9001 9002 9003 9004))
    (clara.net:stop-serving port))
  (check t (settled pages)))

;; The machine reaches itself, at the address that it has and at
;; 127.0.0.1, and nothing of that goes onto the wire.
(new-network)
(said-by #'clara.net:up)
(let ((pages (clara.host:allocated-pages)) (heard (length (network-heard *network*))))
  (clara.net:serve 7 'shout)
  (check '("TO MYSELF" "AND AGAIN")
         (list (clara.net:with-connection (stream "127.0.0.1" 7) (write-line "to myself" stream) (read-line stream))
               (clara.net:with-connection (stream "10.0.2.15" 7) (write-line "and again" stream) (read-line stream))))
  (check '(t t) (list (<= 0 (clara.net:ping "127.0.0.1") 1000) (<= 0 (clara.net:ping "10.0.2.15") 1000)))
  (check "127.0.0.1 takes no connection at its port 8" (condition-text (lambda () (clara.net:connect "127.0.0.1" 8))))
  (check '((7 2 0 nil)) (and (eventually (lambda () (= 0 (third (car (clara.net:serving)))))) (clara.net:serving)))
  (check heard (length (network-heard *network*)))
  ;; What comes from the wire for an address by which a machine means itself, or from an address that is
  ;; the machine's own, is nobody's: here it would be told that there is no such connection.
  (flet ((stray (from to)
           (let ((segment (bytes-of (list 0 80 #xc0 #x01) (number-bytes 1000 4) (number-bytes 2000 4) (list #x50 #x10 #xff #xff 0 0 0 0))))
             (setf (be segment 16 2) (logxor #xffff (wire-sum segment 0 20 (around-sum from to 6 20))))
             (packet-to-machine *network* from to 6 segment))))
    (stray #x0a000202 #x7f000001)
    (stray #x0a00020f #x0a00020f)
    (stray #x7f000001 #x0a00020f)
    (sleep 0.1)
    (check 0 (network-saw *network* :given-up))
    (stray #x0a000202 #x0a00020f)
    (check t (eventually (lambda () (= 1 (network-saw *network* :given-up))))))
  (clara.net:stop-serving 7)
  (check '(t nil) (list (settled pages) (clara.net::card-trouble clara.net::*card*))))

;; A connection that the machine opens is such a stream: here to the web
;; server of the network, which is asked as FETCH asks it.
(new-network :files (files))
(said-by #'clara.net:up)
(let ((pages (clara.host:allocated-pages)) (end (format nil "~C~C" (code-char 13) (code-char 10))))
  (check '("HTTP/1.1 200 OK" "hello from the made-up network")
         (clara.net:with-connection (stream "releases.test" 80)
           (write-string (concatenate 'string "GET /hello.txt HTTP/1.1" end "Host: releases.test" end
                                      "User-Agent: ClaraOS/by hand" end "Connection: close" end end)
                         stream)
           (let ((first (read-line stream)) (last nil))
             (loop
               (let ((line (read-line stream nil)))
                 (unless line
                   (return))
                 (setq last line)))
             (list first last))))
  (check t (settled pages)))
;; What is no port, no function, and a port that is taken.
(check '("0 is no port: a port is a number from 1 to 65535"
         "NIL is no function, and no name of one, that a connection could be handed to"
         "connections are taken at the port 7 already: CLARA.NET:STOP-SERVING ends that"
         "70000 is no port: a port is a number from 1 to 65535"
         "0 is no number of connections that could be taken at once")
       (list (condition-text (lambda () (clara.net:serve 0 'shout))) (condition-text (lambda () (clara.net:serve 7 nil)))
             (progn (clara.net:serve 7 'shout) (condition-text (lambda () (clara.net:serve 7 'shout))))
             (condition-text (lambda () (clara.net:connect "10.0.2.2" 70000)))
             (condition-text (lambda () (clara.net:serve 8 'shout :most 0)))))

;; The ports are the world's. A world that was saved while it took
;; connections takes them again when it is started: it says so, and asks
;; for its address without anything having asked for the network.
(let ((doors clara.net::*doors*) (said nil))
  (check 1 (length doors))
  (let ((all (said-by-all (lambda ()
                            (setq said (new-network :doors doors))
                            (eventually (lambda () (clara.net::card-address clara.net::*card*)))))))
    (check (format nil "net: 00:04.0 is a network card, 52:54:00:12:34:56 on the wire~%net: connections are taken at the port 7, as before this start~%")
           said)
    (check t (and (search "net: this machine is 10.0.2.15 on its network" all) t)))
  (let ((call (call-machine 7 :say (format nil "as before~%") :end t)))
    (check t (done-p call))
    (check (format nil "AS BEFORE~%") (call-text call)))
  (clara.net:stop-serving 7))

;;; What a connection that is kept closed is made of (CLARA.UNSAFE): the
;;; arithmetic that the kernel has in C, here in SBCL's big numbers
;;; (host/clara.lisp). Each is held against the examples of its standard,
;;; which are the ones that the kernel's own self-tests have, so that the
;;; two sides are the same arithmetic because both are the standard's.

(defun hex (text)
  (loop for i from 0 below (length text) by 2 collect (parse-integer text :start i :end (+ i 2) :radix 16)))

(defun in-memory (address bytes)
  (let ((i 0))
    (map nil (lambda (byte)
               (setf (clara.unsafe:memory-8 (+ address i)) byte)
               (incf i))
         bytes)
    i))

(defun from-memory (address count)
  (format nil "~(~{~2,'0x~}~)" (loop for i below count collect (clara.unsafe:memory-8 (+ address i)))))

(stop-network)
(new-machine)
(let ((page (clara.unsafe:allocate-memory 2)))
  ;; sums (FIPS 180-4), of "abc", of nothing, and written over the bytes that they are the sum of
  (in-memory page (octets "abc"))
  (check '(32 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
           48 "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"
           64 "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" "e3b0c44298fc1c14" 32 "ba7816bf8f01cfea")
         (list (clara.unsafe:digest 256 page 3 (+ page 64)) (from-memory (+ page 64) 32)
               (clara.unsafe:digest 384 page 3 (+ page 64)) (from-memory (+ page 64) 48)
               (clara.unsafe:digest 512 page 3 (+ page 64)) (from-memory (+ page 64) 32)
               (progn (clara.unsafe:digest 256 page 0 (+ page 64)) (from-memory (+ page 64) 8))
               (clara.unsafe:digest 256 page 3 page) (from-memory page 8)))
  (check "there is no sum of 224 bits here: there are the ones of 256, of 384 and of 512"
         (condition-text (lambda () (clara.unsafe:digest 224 page 3 (+ page 64)))))
  (check t (string= (clara.unsafe:sha-512 page 32) (progn (clara.unsafe:digest 512 page 32 (+ page 64)) (from-memory (+ page 64) 64))))
  ;; a sum with a key (RFC 4231, the second example and the sixth, whose key is longer than a block)
  (in-memory page (octets "Jefe"))
  (in-memory (+ page 16) (octets "what do ya want for nothing?"))
  (check '(32 "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" 48 "af45d2e376484031" 64 "164b7a7bfcf819e2")
         (list (clara.unsafe:hmac 256 page 4 (+ page 16) 28 (+ page 64)) (from-memory (+ page 64) 32)
               (clara.unsafe:hmac 384 page 4 (+ page 16) 28 (+ page 64)) (from-memory (+ page 64) 8)
               (clara.unsafe:hmac 512 page 4 (+ page 16) 28 (+ page 64)) (from-memory (+ page 64) 8)))
  (in-memory page (make-list 131 :initial-element #xaa))
  (in-memory (+ page 256) (octets "Test Using Larger Than Block-Size Key - Hash Key First"))
  (check '("60e431591ee0b67f" "80b24263c7c1a3eb")
         (list (progn (clara.unsafe:hmac 256 page 131 (+ page 256) 54 (+ page 512)) (from-memory (+ page 512) 8))
               (progn (clara.unsafe:hmac 512 page 131 (+ page 256) 54 (+ page 512)) (from-memory (+ page 512) 8))))
  ;; a secret made into keys (RFC 5869, the first example): the sum with a key is all that it takes
  (in-memory page (hex "000102030405060708090a0b0c"))
  (in-memory (+ page 32) (make-list 22 :initial-element 11))
  (clara.unsafe:hmac 256 page 13 (+ page 32) 22 (+ page 64))
  (check "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5" (from-memory (+ page 64) 32))
  (in-memory (+ page 128) (hex "f0f1f2f3f4f5f6f7f8f901"))
  (clara.unsafe:hmac 256 (+ page 64) 32 (+ page 128) 11 (+ page 192))
  (check "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf" (from-memory (+ page 192) 32))
  ;; bytes closed and opened (the fourth example of the mode, which has bytes beside it and ends in no whole block)
  (let ((key page) (nonce (+ page 16)) (beside (+ page 32)) (data (+ page 64)) (tag (+ page 160)) (out (+ page 256))
        (plain "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"))
    (in-memory key (hex "feffe9928665731c6d6a8f9467308308"))
    (in-memory nonce (hex "cafebabefacedbaddecaf888"))
    (in-memory beside (hex "feedfacedeadbeeffeedfacedeadbeefabaddad2"))
    (in-memory data (hex plain))
    (check (list t "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091"
                 "5bc94fbc3221a5db94fae95ae7121a47" t plain)
           (list (clara.unsafe:aes-128-gcm-seal key nonce beside 20 data 60 out tag) (from-memory out 60) (from-memory tag 16)
                 (clara.unsafe:aes-128-gcm-open key nonce beside 20 out 60 out tag) (from-memory out 60)))
    ;; what does not open: a bit of the bytes, of the tag, of what went beside them, of the twelve bytes, of the key; and nothing is written then
    (clara.unsafe:aes-128-gcm-seal key nonce beside 20 data 60 out tag)
    (dolist (place (list out tag beside nonce key (+ out 59) (+ tag 15)))
      (setf (clara.unsafe:memory-8 place) (logxor 1 (clara.unsafe:memory-8 place)))
      (in-memory (+ page 512) (make-list 60 :initial-element 0))
      (check '(nil "0000000000000000")
             (list (clara.unsafe:aes-128-gcm-open key nonce beside 20 out 60 (+ page 512) tag) (from-memory (+ page 512) 8)))
      (setf (clara.unsafe:memory-8 place) (logxor 1 (clara.unsafe:memory-8 place))))
    ;; and nothing at all is closed and opened too, with a tag of its own
    (in-memory key (make-list 16 :initial-element 0))
    (in-memory nonce (make-list 12 :initial-element 0))
    (check '(t "58e2fccefa7e3061367f1d57a4e7455a" t)
           (list (clara.unsafe:aes-128-gcm-seal key nonce beside 0 data 0 out tag) (from-memory tag 16)
                 (clara.unsafe:aes-128-gcm-open key nonce beside 0 out 0 out tag))))
  ;; what two sides agree on (RFC 7748, 6.1), and the points that make nothing
  (in-memory page (hex "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
  (in-memory (+ page 32) (hex "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"))
  (in-memory (+ page 64) (cons 9 (make-list 31 :initial-element 0)))
  (in-memory (+ page 96) (make-list 32 :initial-element 0))
  (check '(t "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742" t
           "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" nil nil)
         (list (clara.unsafe:x25519 page (+ page 32) (+ page 128)) (from-memory (+ page 128) 32)
               (clara.unsafe:x25519 page (+ page 64) (+ page 128)) (from-memory (+ page 128) 32)
               (clara.unsafe:x25519 page (+ page 96) (+ page 128))
               (progn (setf (clara.unsafe:memory-8 (+ page 96)) 1) (clara.unsafe:x25519 page (+ page 96) (+ page 128)))))
  ;; a number to a power, modulo another: small ones that anybody can check, and what is refused
  (in-memory page '(4))
  (in-memory (+ page 16) '(1 #xf1))
  (check '(t "01bd" t "0001" nil nil nil nil)
         (list (clara.unsafe:power-mod page 1 13 (+ page 16) 2 (+ page 32)) (from-memory (+ page 32) 2)
               (clara.unsafe:power-mod page 1 0 (+ page 16) 2 (+ page 32)) (from-memory (+ page 32) 2)
               (progn (in-memory (+ page 16) '(1 #xf0)) (clara.unsafe:power-mod page 1 13 (+ page 16) 2 (+ page 32)))
               (progn (in-memory (+ page 16) '(0 #xf1)) (clara.unsafe:power-mod page 1 13 (+ page 16) 2 (+ page 32)))
               (progn (in-memory (+ page 16) '(3)) (clara.unsafe:power-mod page 1 13 (+ page 16) 1 (+ page 32)))
               (clara.unsafe:power-mod page 1 13 (+ page 16) 0 (+ page 32))))
  ;; the numbers that the kernel's self-test makes by a rule, of 2048 bits, to the power 65537
  (let ((modulus (loop for i below 256 collect (logand 255 (+ (* i 37) 129)))) (base (loop for i below 256 collect (logand 255 (+ (* i 91) 7)))))
    (in-memory page (cons (logior (car modulus) #x80) (append (butlast (cdr modulus)) (list (logior (car (last modulus)) 1)))))
    (in-memory (+ page 512) (cons (logand (car base) #x7f) (cdr base)))
    (check '(t "8052ee4799e04978" "95ab5feec05dd654")
           (list (clara.unsafe:power-mod (+ page 512) 256 65537 page 256 (+ page 1024))
                 (from-memory (+ page 1024) 8) (from-memory (+ page 1272) 8))))
  ;; signatures on the two curves: the examples of the kernel's self-test, which OpenSSL takes too
  (dolist (bits '(256 384))
    (let* ((size (floor bits 8)) (key (if (= bits 256) *shown-key* *signer-key*)) (curve (tkey-curve key))
           (sum (clara.host:digest-of bits (octets "a sum to sign")))
           (key-at page) (sum-at (+ page 128)) (r-at (+ page 256)) (s-at (+ page 384)))
      (multiple-value-bind (r s) (clara.host:curve-sign curve (tkey-secret key) sum 123456789)
        (in-memory key-at (append (number-bytes (car (tkey-point key)) size) (number-bytes (cdr (tkey-point key)) size)))
        (in-memory sum-at sum)
        (in-memory r-at (number-bytes r size))
        (in-memory s-at (cons 0 (number-bytes s size)))
        (check '(t nil nil nil nil nil nil)
               (list (clara.unsafe:ecdsa bits key-at sum-at size r-at size s-at (1+ size))
                     (clara.unsafe:ecdsa bits key-at sum-at size s-at (1+ size) r-at size)
                     (clara.unsafe:ecdsa (if (= bits 256) 384 256) key-at sum-at size r-at size s-at (1+ size))
                     (clara.unsafe:ecdsa 521 key-at sum-at size r-at size s-at (1+ size))
                     (progn (setf (clara.unsafe:memory-8 sum-at) (logxor 1 (clara.unsafe:memory-8 sum-at)))
                            (prog1 (clara.unsafe:ecdsa bits key-at sum-at size r-at size s-at (1+ size))
                              (setf (clara.unsafe:memory-8 sum-at) (logxor 1 (clara.unsafe:memory-8 sum-at)))))
                     (progn (setf (clara.unsafe:memory-8 (+ key-at size)) (logxor 1 (clara.unsafe:memory-8 (+ key-at size))))
                            (prog1 (clara.unsafe:ecdsa bits key-at sum-at size r-at size s-at (1+ size))
                              (setf (clara.unsafe:memory-8 (+ key-at size)) (logxor 1 (clara.unsafe:memory-8 (+ key-at size))))))
                     (progn (in-memory r-at (make-list size :initial-element 0))
                            (clara.unsafe:ecdsa bits key-at sum-at size r-at size s-at (1+ size))))))))
  (clara.unsafe:free-memory page 2))

;;; Numbers that nobody can guess (lisp/random.lisp): the driver of the
;;; device that makes them, which here makes them by a rule.

(defun new-numbers (&rest options)
  (new-machine)
  (attach-bus)
  (add-function 0 0 0 #x8086 #x29c0 #x060000)
  (setq *numbers* (apply #'add-numbers 6 options))
  (with-output-to-string (*standard-output*)
    (clara.pci:start))
  (said-by #'clara.random:start))

(check (format nil "random: 00:06.0 makes numbers that nobody can guess~%") (new-numbers))
(let ((pages (clara.host:allocated-pages)) (memory (clara.unsafe:allocate-memory 3)))
  ;; as many bytes as were asked for, and no more: what lies behind them is as it was
  (in-memory memory (make-list 12288 :initial-element 0))
  (check '(1 "0000") (list (clara.random:bytes memory 1) (from-memory (+ memory 1) 2)))
  (check 0 (clara.random:bytes memory 0))
  (check '(5000 2 nil) (let ((asked (vdev-asked *numbers*)))
                         (list (clara.random:bytes memory 5000) (- (vdev-asked *numbers*) asked)
                               (find-if #'plusp (loop for i from 5000 below 5010 collect (clara.unsafe:memory-8 (+ memory i)))))))
  ;; they are not all the same, and not the same twice
  (check '(t t) (list (> (length (remove-duplicates (loop for i below 64 collect (clara.unsafe:memory-8 (+ memory i))))) 16)
                      (let ((first (from-memory memory 32)))
                        (clara.random:bytes memory 32)
                        (not (string= first (from-memory memory 32))))))
  ;; the page that the device wrote into is wiped: the numbers lie where they were asked for, and nowhere else
  (check nil (find-if #'plusp (loop for i below 4096
                                   collect (clara.unsafe:memory-8 (+ (clara.random::source-page clara.random::*source*) i)))))
  ;; numbers below another: all of them come up, and none that is not below
  (check '(0 1 2 3 4 5) (sort (remove-duplicates (loop repeat 300 collect (clara.random:below 6))) #'<))
  (check '(0) (remove-duplicates (loop repeat 20 collect (clara.random:below 1))))
  (check t (every (lambda (number) (< -1 number 1000000000000)) (loop repeat 50 collect (clara.random:below 1000000000000))))
  (check '("0 is not a number above 0 and up to 281474976710656, below which a number could be taken"
           "281474976710657 is not a number above 0 and up to 281474976710656, below which a number could be taken"
           "SIX is not a number above 0 and up to 281474976710656, below which a number could be taken")
         (mapcar (lambda (limit) (condition-text (lambda () (clara.random:below limit)))) '(0 281474976710657 six)))
  (clara.unsafe:free-memory memory 3)
  (check pages (clara.host:allocated-pages)))
;; A device that fills less than it is given is asked again, until all is there.
(new-numbers :few 7)
(let ((memory (clara.unsafe:allocate-memory 1)))
  (check '(100 15) (let ((asked (vdev-asked *numbers*)))
                     (list (clara.random:bytes memory 100) (- (vdev-asked *numbers*) asked))))
  (check t (> (length (remove-duplicates (loop for i below 100 collect (clara.unsafe:memory-8 (+ memory i))))) 16))
  (clara.unsafe:free-memory memory 1))
;; One that has no message to send is looked at all the same; one that says nothing is given up, and asked nothing more;
;; and one that answers with no numbers at all is not asked for ever.
(new-numbers :mute t)
(let ((memory (clara.unsafe:allocate-memory 1)))
  (check 40 (clara.random:bytes memory 40))
  (clara.unsafe:free-memory memory 1))
(new-numbers :silent t)
(let ((memory (clara.unsafe:allocate-memory 1)) (clara.random:*patience* 300))
  (check '("the device 00:06.0 has made no numbers in 300 milliseconds"
           "the device 00:06.0 left a request unanswered, and is asked nothing more")
         (list (condition-text (lambda () (clara.random:bytes memory 8))) (condition-text (lambda () (clara.random:bytes memory 8)))))
  (clara.unsafe:free-memory memory 1))
(new-numbers :few 0)
(let ((memory (clara.unsafe:allocate-memory 1)))
  (check "the device 00:06.0 goes on answering with no numbers at all" (condition-text (lambda () (clara.random:bytes memory 8))))
  (clara.unsafe:free-memory memory 1))
;; A machine without the device says so, as it starts and when a number is wanted.
(new-machine)
(attach-bus)
(add-function 0 0 0 #x8086 #x29c0 #x060000)
(with-output-to-string (*standard-output*)
  (clara.pci:start))
(check (format nil "random: no device that makes numbers which nobody can guess: nothing is fetched by HTTPS~%")
       (said-by #'clara.random:start))
(check '("this machine has no device that makes numbers which nobody can guess: a virtio RNG device is one"
         "this machine has no device that makes numbers which nobody can guess: a virtio RNG device is one")
       (list (condition-text (lambda () (clara.random:bytes clara.host:+memory-base+ 1)))
             (condition-text (lambda () (clara.random:below 6)))))
;; And a device that a world has kept from an earlier start is forgotten by the next one.
(new-numbers)
(new-machine)
(attach-bus)
(add-function 0 0 0 #x8086 #x29c0 #x060000)
(with-output-to-string (*standard-output*)
  (clara.pci:start))
(check '(t nil) (list (and clara.random::*source* t) (progn (said-by #'clara.random:start) clara.random::*source*)))

;;; Certificates (lisp/tls.lisp): read as they are written, and held
;;; against a name, against the time, and against each other.

(defun read-bytes (bytes)
  (let* ((pages (max 1 (ceiling (length bytes) 4096))) (memory (clara.unsafe:allocate-memory pages)))
    (in-memory memory bytes)
    (clara.tls::read-certificate memory (length bytes))))

(new-machine)
;; The time of day, both ways, on days that a count of days gets wrong when it forgets a leap year.
(check t (every (lambda (time)
                  (multiple-value-bind (second minute hour day month year) (decode-universal-time time 0)
                    (and (= time (clara.tls::universal year month day hour minute second))
                         (string= (clara.tls::date-text time) (format nil "~D-~2,'0D-~2,'0D ~2,'0D:~2,'0D" year month day hour minute)))))
                (append (loop for year in '(1970 1999 2000 2001 2024 2026 2028 2099 2100 2101 2400)
                              append (loop for (month day) in '((1 1) (2 28) (3 1) (12 31) (7 4))
                                           collect (encode-universal-time 59 58 23 day month year 0)))
                        (list (encode-universal-time 0 0 0 29 2 2024 0) (encode-universal-time 0 0 0 29 2 2000 0) 0 3913056000))))
(check '("2026-11-20 20:53" "1900-01-01 00:00" "2000-02-29 12:00")
       (list (clara.tls::date-text (encode-universal-time 48 53 20 20 11 2026 0)) (clara.tls::date-text 0)
             (clara.tls::date-text (encode-universal-time 0 0 12 29 2 2000 0))))
;; What a certificate says, read back: whom it is for, its names, its dates, its key, and what it may be used for.
(let* ((from (encode-universal-time 0 30 12 1 2 2026 0)) (until (encode-universal-time 59 59 23 31 12 2049 0))
       (plain (read-bytes (certificate :subject "one.test" :organization "Somebody" :issuer "The tests' root" :key *shown-key*
                                       :signer *authority-key* :names '("one.test" "*.one.test") :addresses '(#x0a000203)
                                       :from from :until until)))
       (signer (read-bytes *signer*))
       (later (read-bytes (certificate :subject "late.test" :key *rsa-key* :signer *rsa-key* :bits 384 :usage 128 :must t
                                       :purposes '((#x2b 6 1 5 5 7 3 2)) :long-dates t :version nil
                                       :from (encode-universal-time 0 0 0 1 1 2050 0) :until (encode-universal-time 0 0 0 1 1 2051 0))))
       (nameless (read-bytes (certificate :subject nil :organization "Only an organization" :key *large-key* :signer *large-key* :bits 384
                                          :purposes '((#x55 #x1d #x25 0))))))
  (check (list "one.test" '("one.test" "*.one.test") '(#x0a000203) from until 256 '(:ecdsa . 256) nil nil nil t nil)
         (list (clara.tls::certificate-name plain) (clara.tls::certificate-names plain) (clara.tls::certificate-addresses plain)
               (clara.tls::certificate-from plain) (clara.tls::certificate-until plain) (clara.tls::certificate-key plain)
               (clara.tls::certificate-signed plain) (clara.tls::certificate-authority plain) (clara.tls::certificate-depth plain)
               (clara.tls::certificate-usage plain) (clara.tls::certificate-serves plain) (clara.tls::certificate-unknown plain)))
  (check '("The tests' signer in between" 384 (:ecdsa . 256) t 0 6 t nil nil)
         (list (clara.tls::certificate-name signer) (clara.tls::certificate-key signer) (clara.tls::certificate-signed signer)
               (clara.tls::certificate-authority signer) (clara.tls::certificate-depth signer) (clara.tls::certificate-usage signer)
               (clara.tls::certificate-serves signer) (clara.tls::certificate-unknown signer) (clara.tls::certificate-names signer)))
  (check (list "late.test" :rsa 256 65537 '(:rsa . 384) 128 nil t (encode-universal-time 0 0 0 1 1 2050 0))
         (list (clara.tls::certificate-name later) (clara.tls::certificate-key later) (clara.tls::certificate-modulus-bytes later)
               (clara.tls::certificate-exponent later) (clara.tls::certificate-signed later) (clara.tls::certificate-usage later)
               (clara.tls::certificate-serves later) (clara.tls::certificate-unknown later) (clara.tls::certificate-from later)))
  (check '("Only an organization" 384 t) (list (clara.tls::certificate-name nameless) (clara.tls::certificate-key nameless)
                                                (clara.tls::certificate-serves nameless)))
  ;; who signed whom: by the name and by the signature, and a bit of either is another answer
  (let ((work (clara.unsafe:allocate-memory 1)) (root (read-bytes *authority*)) (own (read-bytes *shown*)))
    (check '(t t t nil nil nil t nil)
           (list (clara.tls::signed-by-p signer root work) (clara.tls::signed-by-p own signer work) (clara.tls::signed-by-p root root work)
                 (clara.tls::signed-by-p own root work) (clara.tls::signed-by-p signer own work) (clara.tls::signed-by-p plain signer work)
                 (clara.tls::signed-by-p later later work)
                 (clara.tls::signed-by-p (read-bytes (certificate :subject "one.test" :issuer "The tests' root" :issuer-organization "ClaraOS tests"
                                                                  :key *shown-key* :signer *authority-key* :spoil t))
                                         root work)))
    ;; and each of the names that a certificate is for: its own, in either kind of letters; the star for one part, the first; an address
    (check '(t t t nil nil nil t nil nil t nil)
           (mapcar (lambda (host) (and (clara.tls::for-name-p plain host) t))
                   '("one.test" "ONE.Test" "a.one.test" "a.b.one.test" "two.test" "one.test.evil.example" "*.one.test" ".one.test"
                     "aone.test" "10.0.2.3" "10.0.2.4")))))
;; A date of the last century, which is written with two digits like one of this; a certificate that says outright that it
;; may not sign; and three that are certificates but for one byte: a piece that says it is longer than what it is in, a
;; length of the kind that has no end, and a date that is not Greenwich's.
(let ((old (read-bytes (certificate :subject "old.test" :key *shown-key* :from (encode-universal-time 0 0 0 1 7 1998 0)
                                    :until (encode-universal-time 0 0 0 1 7 2049 0))))
      (none (read-bytes (certificate :subject "none.test" :key *shown-key* :authority :no))))
  (check (list (encode-universal-time 0 0 0 1 7 1998 0) (encode-universal-time 0 0 0 1 7 2049 0) nil)
         (list (clara.tls::certificate-from old) (clara.tls::certificate-until old) (clara.tls::certificate-authority none))))
(flet ((changed (find replace)
         (let* ((bytes (copy-seq *shown*)) (at (search find bytes)))
           (replace bytes replace :start1 at)
           (condition-text (lambda () (read-bytes bytes))))))
  (check '("it is not written as a certificate is: a piece is longer than what it is in"
           "it is not written as a certificate is: a piece has a length that is none"
           "it is not written as a certificate is: a date is none, or is not Greenwich's")
         (list (changed (bytes-of '(#x82 13) (octets "releases.test")) '(#x82 77))
               (changed (bytes-of '(#x82 13) (octets "releases.test")) '(#x82 #x80))
               (let* ((bytes (copy-seq *shown*)) (at (position 90 bytes)))   ; the first Z, which ends the first date
                 (setf (aref bytes at) 43)
                 (condition-text (lambda () (read-bytes bytes)))))))
;; What is not a certificate at all, and what is one with something wrong in how it is written.
(dolist (wrong (list (bytes-of) (bytes-of '(48 3 1 2 3)) (bytes-of '(49 0)) (subseq *shown* 0 100) (bytes-of *shown* '(0))
                     (bytes-of '(48 #x84 0 0 0 1 0)) (bytes-of '(48 #x82 #xff #xff) (subseq *shown* 4))))
  (check t (and (search "it is not written as a certificate is" (condition-text (lambda () (read-bytes wrong)))) t)))
;; A file of certificates: each between its two lines, whatever else the file says, and with either kind of line end; one that
;; cannot be read is passed over, and one that does not end is an error.
(let* ((text (format nil "Somebody wrote this file.~%~A~%# and a remark~%~A~A-----BEGIN CERTIFICATE-----~%AAAA~%-----END CERTIFICATE-----~%"
                     (pem *authority*) (substitute #\Return #\Tab (pem *signer*)) (pem *shown*)))
       (memory (clara.unsafe:allocate-memory 2)))
  (clara.unsafe:string-memory text memory)
  (check '(("The tests' root" "The tests' signer in between" "releases.test") 1)
         (multiple-value-bind (certificates passed) (clara.tls::certificates-in memory (clara.unsafe:string-bytes text))
           (list (mapcar #'clara.tls::certificate-name certificates) passed)))
  (clara.unsafe:string-memory "-----BEGIN CERTIFICATE-----MIIB" memory)
  (check "a certificate in the list has no end" (condition-text (lambda () (clara.tls::certificates-in memory 31))))
  (check nil (clara.tls::certificates-in memory 5)))
;; The list that the system has from the beginning (lisp/roots.pem): every certificate in it is read; each has a name and dates
;; that are dates; and each that signed itself in a way that is known here did sign itself, which is hundreds of signatures that
;; nobody here made, of RSA's and on both curves.
(let* ((text (with-open-file (in (source "lisp/roots.pem") :external-format :latin-1)
               (let ((all (make-string (file-length in))))
                 (subseq all 0 (read-sequence all in)))))
       (bytes (sb-ext:string-to-octets text :external-format :latin-1))
       (memory (clara.unsafe:allocate-memory (ceiling (length bytes) 4096)))
       (work (clara.unsafe:allocate-memory 1)))
  (in-memory memory bytes)
  (multiple-value-bind (certificates passed) (clara.tls::certificates-in memory (length bytes))
    (check '(t 0) (list (> (length certificates) 100) passed))
    (check nil (remove-if (lambda (certificate)
                            (and (stringp (clara.tls::certificate-name certificate))
                                 (< (clara.tls::certificate-from certificate) (clara.tls::certificate-until certificate))
                                 (clara.tls::certificate-authority certificate)))
                          certificates))
    (let ((kinds (mapcar #'clara.tls::certificate-key certificates))
          (themselves (remove-if-not (lambda (certificate)
                                       (and (clara.tls::certificate-signed certificate) (clara.tls::certificate-key certificate)))
                                     certificates)))
      (check '(t t t) (list (> (count :rsa kinds) 30) (> (count 384 kinds) 10) (> (length themselves) 80)))
      (check nil (mapcar #'clara.tls::certificate-name
                         (remove-if (lambda (certificate) (clara.tls::signed-by-p certificate certificate work)) themselves)))
      (check t (and (find "ISRG Root X1" certificates :key #'clara.tls::certificate-name :test #'string=) t)))))

;; Signatures, as closely as they can be looked at: what a signer with the key could make that is nearly a signature and
;; is none. A signature of RSA's is a block to a secret power; each of these blocks is right but for one thing, and what
;; is made of it has to be refused. The older kind first (RFC 8017, 9.2): another second byte, a byte of the filling that
;; is not 255, no zero after the filling, the word for another sum, and a filling that is too short with something after
;; the sum to make up for it, which is how such signatures were once made up without the key.
(new-machine)
(let* ((owner (read-bytes (certificate :subject "an owner" :key *rsa-key* :signer *rsa-key*)))
       (work (clara.unsafe:allocate-memory 1)) (memory (clara.unsafe:allocate-memory 1))
       (message (octets "what is signed")) (size 256)
       (sum (clara.host:digest-of 256 message)) (prefix (cdr (assoc 256 *sum-prefixes*))))
  (flet ((good-p (way block)
           (let ((signature (number-bytes (clara.host:expt-mod (clara.host:octets-number block) (tkey-d *rsa-key*) (tkey-n *rsa-key*)) size)))
             (in-memory memory message)
             (in-memory (+ memory 1024) signature)
             (and (clara.tls::signature-good-p owner way memory (length message) (+ memory 1024) size work) t)))
         (padded (&key (second 1) (filling 255) (after 0) (prefix prefix) (sum sum) more)
           (let ((fill (- size 3 (length prefix) (length sum) (length more))))
             (bytes-of (list 0 second) (make-list fill :initial-element filling) (list after) prefix sum more))))
    (check '(t nil nil nil nil nil nil)
           (list (good-p '(:rsa . 256) (padded))
                 (good-p '(:rsa . 256) (padded :second 2))
                 (good-p '(:rsa . 256) (let ((bytes (padded))) (setf (aref bytes 20) 254) bytes))
                 (good-p '(:rsa . 256) (padded :after 255))
                 (good-p '(:rsa . 256) (padded :prefix (cdr (assoc 384 *sum-prefixes*)) :sum (subseq (clara.host:digest-of 384 message) 0 32)))
                 (good-p '(:rsa . 256) (padded :more (make-list 190 :initial-element 7)))
                 (good-p '(:rsa . 256) (let ((bytes (padded))) (setf (aref bytes (1- size)) (logxor 1 (aref bytes (1- size)))) bytes))))
    ;; the word for the sum with a byte of it another, over the right sum; and the signature with a zero before it, which is
    ;; the same number and not the same signature
    (check '(nil nil)
           (list (good-p '(:rsa . 256) (padded :prefix (let ((other (copy-list prefix))) (setf (nth 14 other) 2) other)))
                 (let ((signature (number-bytes (clara.host:expt-mod (clara.host:octets-number (padded)) (tkey-d *rsa-key*) (tkey-n *rsa-key*)) size)))
                   (in-memory memory message)
                   (in-memory (+ memory 1024) (cons 0 signature))
                   (and (clara.tls::signature-good-p owner '(:rsa . 256) memory (length message) (+ memory 1024) (1+ size) work) t))))
    ;; and the newer kind (9.1): as it should be; another last byte; a salt of another length; the 1 before the salt another
    ;; number; a bit of the sum at its end changed; and the same signature held against the other way of reading it
    (flet ((newer (&key (last #xbc) (salt-bytes 32) (one 1) spoil dirt top)
             (let* ((salt (subseq (clara.host:digest-of 512 (octets "another salt")) 0 salt-bytes))
                    (h (clara.host:digest-of 256 (bytes-of (make-list 8 :initial-element 0) sum salt)))
                    (open (bytes-of (make-list (- size 32 salt-bytes 2) :initial-element 0) (list one) salt))
                    (mask (apply #'bytes-of (loop for count from 0 below (ceiling (length open) 32)
                                                  collect (clara.host:digest-of 256 (bytes-of h (number-bytes count 4))))))
                    (covered (map 'vector #'logxor open mask)))
               (setf (aref covered 0) (logand (aref covered 0) 127))
               (when dirt
                 ;; something among the zeroes before the salt
                 (setf (aref covered 9) (logxor 4 (aref covered 9))))
               (when top
                 ;; the bit above the block, set: still a number below the key's, whose first byte is above 128
                 (setf (aref covered 0) (logior (aref covered 0) 128)))
               (when spoil
                 (setf (aref h 31) (logxor 1 (aref h 31))))
               (bytes-of covered h (list last)))))
      (check '(t nil nil nil nil nil t)
             (list (good-p '(:pss . 256) (newer))
                   (good-p '(:pss . 256) (newer :last #xbd))
                   (good-p '(:pss . 256) (newer :salt-bytes 20))
                   (good-p '(:pss . 256) (newer :one 2))
                   (good-p '(:pss . 256) (newer :spoil t))
                   (good-p '(:rsa . 256) (newer))
                   (good-p '(:pss . 256) (pss-block 256 sum 2048))))
      (check '(nil nil t)
             (list (good-p '(:pss . 256) (newer :dirt t))
                   (good-p '(:pss . 256) (newer :top t))
                   (< (aref (newer :top t) 0) (ldb (byte 8 2040) (tkey-n *rsa-key*)))))))
  ;; A signature on a curve is two numbers in a piece, and nothing else: not with something after it, not with a
  ;; number that is written as a negative one, and not as a piece that says it is longer than it is.
  (let* ((own (read-bytes (certificate :subject "an owner" :key *shown-key*)))
         (signature (loop for i from 0
                          do (let ((signed (sign-with *shown-key* 256 (bytes-of message (list i)))))
                               ;; one whose first number has its highest bit set, and so a zero before it
                               (when (and (= (aref signed 3) 33) (= (aref signed 4) 0))
                                 (setq message (bytes-of message (list i)))
                                 (return signed))))))
    (flet ((good-p (signature &optional (bytes (length signature)))
             (in-memory memory message)
             (in-memory (+ memory 1024) signature)
             (and (clara.tls::signature-good-p own '(:ecdsa . 256) memory (length message) (+ memory 1024) bytes work) t)))
      (check '(t nil nil nil nil nil)
             (list (good-p signature)
                   (good-p (bytes-of signature '(0)))
                   ;; the same number without its zero, which is a negative number as such things are written
                   (good-p (bytes-of (list 48 (1- (aref signature 1)) 2 32) (subseq signature 5)))
                   (good-p (bytes-of (list 48 (1+ (aref signature 1))) (subseq signature 2) '(0)))
                   (good-p signature (1- (length signature)))
                   (good-p (bytes-of '(49) (subseq signature 1)))))))
  ;; A key of RSA's that is shorter than 2048 bits is a key of no kind that is known here; and a certificate whose name
  ;; for its signer is not that signer's name was not signed by it, whatever its signature says.
  (let ((short (rsa-key #xeb79384708c4695a4a0b8d00211ab2ae920a5aef788006a1134480d70ae42880ac56e9c60760525d715606691538fe815d03a9775b186cbee267e833b9d0f8b1
                        #xcfff6457b1996d04505fa636f298252030faba4962bb974caee064bc5f4a27e2edc37bb616d82190198a02c4fdea82154fecbed3f287dc4f1bc8b3a7fdbc1acd))
        (root (read-bytes *authority*)))
    (check '(nil t nil)
           (list (clara.tls::certificate-key (read-bytes (certificate :subject "short.test" :key short :signer *shown-key*)))
                 (and (clara.tls::signed-by-p (read-bytes (certificate :subject "one.test" :issuer "The tests' root" :issuer-organization "ClaraOS tests"
                                                                       :key *shown-key* :signer *authority-key*))
                                              root work)
                      t)
                 (clara.tls::signed-by-p (read-bytes (certificate :subject "one.test" :issuer "The tests' root" :key *shown-key*
                                                                  :signer *authority-key*))
                                         root work)))))
;; A sum with a key that is exactly a block long, which is used as it is, and one that is a byte longer, which is not.
(let ((page (clara.unsafe:allocate-memory 1)))
  (in-memory page (loop for i below 65 collect i))
  (in-memory (+ page 128) (octets "what do ya want for nothing?"))
  (check '("5431cc41830bee78" "b8510ec6c86f16d7")
         (list (progn (clara.unsafe:hmac 256 page 64 (+ page 128) 28 (+ page 256)) (from-memory (+ page 256) 8))
               (progn (clara.unsafe:hmac 256 page 65 (+ page 128) 28 (+ page 256)) (from-memory (+ page 256) 8)))))

;;; A connection that is kept closed (lisp/tls.lisp), to a web server of the
;;; made-up network that keeps its side of it (above): what is fetched over
;;; it, what the machine makes of every way in which the other side can be
;;; somebody else or the connection another, and what it tells the other
;;; side then.

;; What the machine told the network about its connections, the first thing first.
(defun told ()
  (reverse (remove-if-not (lambda (what) (member (car what) '(:alert :goodbye :renewed :no-certificate :word :named)))
                          (network-heard *network*))))

;; A machine and a network whose web server shows a certificate, with what
;; the test wants wrong; what a fetch of ADDRESS gives; and what the machine
;; told the network, once the network has heard it.
(defun kept-closed (address &rest options)
  (apply #'new-network :files (files) options)
  (said-by #'clara.net:up)
  (let ((result (fetched address)))
    (eventually (lambda () (or (network-saw *network* :goodbye) (network-saw *network* :alert))))
    (list result (told))))

(defvar *hello* "hello from the made-up network")

;; A file over a connection that is kept closed: the machine names the machine that it means, says its last word, asks,
;; and says that it is done. The same when the certificates come one to a record, in pieces of a few bytes, with zeroes
;; behind what they carry, and after a word of an older TLS that means nothing; when the machine is asked who it is, which
;; it answers with no certificate; and when tickets for another day come before the answer.
(check (list *hello* '((:named "releases.test") (:word) (:goodbye 0))) (kept-closed "https://releases.test/hello.txt"))
(dolist (accident '(:apart :pieces :padded :old-word :tickets :no-goodbye :with-more))
  (check (list accident *hello* (if (eq accident :no-goodbye) '((:named "releases.test") (:word) (:goodbye 0)) '((:named "releases.test") (:word) (:goodbye 0))))
         (cons accident (kept-closed "https://releases.test/hello.txt" :accident accident))))
(check (list *hello* '((:named "releases.test") (:no-certificate) (:word) (:goodbye 0)))
       (kept-closed "https://releases.test/hello.txt" :accident :asks))
;; A long file, in many records, as the wire loses, spoils and swaps its pieces; an empty one; one in chunks; and one at another port.
(check (list *long* '((:named "releases.test") (:word) (:goodbye 0))) (kept-closed "https://releases.test/long"))
(check (list *long* '((:named "releases.test") (:word) (:goodbye 0)))
       (kept-closed "https://releases.test/long" :drop '(1 5 40) :spoil '(2 30) :swap '(3 4 60) :record 16384))
(check (list "" *long* "a file that comes in chunks, each longer than the one before it" *hello* *hello*)
       (progn (new-network :files (files) :secure '(443 8443) :record 100)
              (said-by #'clara.net:up)
              (list (fetched "https://releases.test/empty") (fetched "https://releases.test/long-chunks")
                    (fetched "https://releases.test/chunks") (fetched "https://releases.test:8443/hello.txt")
                    (fetched "https://RELEASES.test/moved"))))
(check 2 (count '(:get "/hello.txt") (network-heard *network*) :test #'equal))
;; The keys change in the middle of an answer, and the machine changes its own when it is asked to, before it says that it is done.
(check (list *hello* '((:named "releases.test") (:word) (:renewed) (:goodbye 0)))
       (kept-closed "https://releases.test/hello.txt" :accident :renew :record 40))
(check (list *hello* '((:named "releases.test") (:word) (:goodbye 0)))
       (kept-closed "https://releases.test/hello.txt" :accident :renew-quietly :record 40))
;; A file that is as long as may be taken, to the byte, is taken, whether its length was said or not: what the connection
;; carries beside it does not count. One byte more is not.
(check (list *long* *long* '(:error "https://releases.test/long is 200000 bytes, and more than 199999 are not taken")
             '(:error "https://releases.test/unsized-long is more than 199999 bytes, which are not taken"))
       (progn (new-network :files (files) :record 300)
              (said-by #'clara.net:up)
              (list (fetched "https://releases.test/long" :limit 200000) (fetched "https://releases.test/unsized-long" :limit 200000)
                    (fetched "https://releases.test/long" :limit 199999) (fetched "https://releases.test/unsized-long" :limit 199999))))
;; A machine that was asked for by its address is not named, and its certificate has to have the address.
(check (list *hello* '((:word) (:goodbye 0))) (kept-closed "https://10.0.2.2/hello.txt"))
;; From an address that is not kept closed to one that is, the machine goes; the other way it does not.
(check (list *hello* '(:error "releases.test says that /down is to be had at http://releases.test/hello.txt, where nothing is kept closed: it is not fetched from there"))
       (progn (new-network :files (append (list (cons "/up" (list :moved "https://releases.test/hello.txt"))
                                                (cons "/down" (list :moved "http://releases.test/hello.txt")))
                                          (files)))
              (said-by #'clara.net:up)
              (list (fetched "http://releases.test/up") (fetched "https://releases.test/down"))))
;; The other side says that it is done, and that is the end of the file, whether or not it ends the connection under it too.
(check "nobody said how long this is" (car (kept-closed "https://releases.test/unsized" :no-end t)))
;; What is asked for may be longer than goes into one piece of a connection: all of it arrives, in order, either way.
(check (list 2001 2001)
       (let ((path (make-string 2000 :initial-element #\a)))
         (new-network :files (files))
         (said-by #'clara.net:up)
         (fetched (format nil "http://releases.test/~A" path))
         (fetched (format nil "https://releases.test/~A" path))
         (mapcar (lambda (what) (length (second what))) (remove :get (network-heard *network*) :key #'car :test-not #'eq))))
;; A file whose length nobody said is whole only when the other side says that it is done: an end without that word is
;; an end that somebody on the way may have made. And an answer that is cut short is cut short.
(check (list "nobody said how long this is" '(:error "releases.test ended the connection without saying that /unsized was whole: what came of it may be cut short")
             '(:error "releases.test ended the connection without saying that /unsized was whole: what came of it may be cut short"))
       (list (car (kept-closed "https://releases.test/unsized"))
             (car (kept-closed "https://releases.test/unsized" :accident :no-goodbye))
             (car (kept-closed "https://releases.test/unsized" :accident :cut))))
(check t (let ((result (car (kept-closed "https://releases.test/long" :accident :cut))))
           (and (consp result) (search "releases.test ended the connection after" (second result))
                (search "bytes of the 200000 of /long" (second result)) t)))

;; What goes wrong in a greeting, and the number that the other side is told: each of these is somebody else at the other
;; end, or somebody in between.
(dolist (wrong '((:old "releases.test speaks no TLS 1.3, and nothing older is spoken here" 70)
                 (:again "releases.test asks to begin again with another exchange of keys, and this system has the one only" 40)
                 (:other-cipher "releases.test answers with a cipher, or with a way of going on, that it was not offered" 47)
                 (:echo "releases.test answers with a cipher, or with a way of going on, that it was not offered" 47)
                 (:other-share "releases.test answers with an exchange of keys that it was not offered" 47)
                 (:no-share "releases.test answers without its half of the exchange of keys" 109)
                 (:more "releases.test answers the greeting with something that it was not asked for" 110)
                 (:gives-up "releases.test gave the connection up: it found nothing in what this machine speaks that it speaks too" nil)
                 (:says-more "releases.test says something about the connection that it was not asked for" 110)
                 (:no-certificate "releases.test shows no certificate, or more than are looked at" 50)
                 (:no-signature "releases.test sent something else where its signature belongs in a greeting" 10)
                 (:signature "releases.test has not shown that the key of its certificate is its own: its greeting is not signed with it" 51)
                 (:other-key "releases.test has not shown that the key of its certificate is its own: its greeting is not signed with it" 51)
                 (:wrong-way "releases.test signs its greeting in a way that it was not offered, or that does not go with its key" 47)
                 (:other-way "releases.test signs its greeting in a way that it was not offered, or that does not go with its key" 47)
                 (:word "releases.test and this machine have not heard the same greeting: something of it was changed on the way" 51)
                 (:in-the-open "releases.test sent a record in the open where everything is closed" 10)
                 (:early "releases.test sent something before the greeting was over" 10)
                 (:nothing "releases.test sent a record with nothing in it" 10)
                 (:trailing "releases.test sent the beginning of something with the keys of what came before it" 10)
                 (:trailing-hello "releases.test sent the beginning of something with the keys of what came before it" 10)
                 (:old-word-wrong "releases.test sent a word of an older TLS that is none" 10)
                 (:nothing-share "releases.test sent a half of the exchange of keys that makes nothing" 47)
                 (:asks-wrongly "releases.test asks who this machine is in a way that is none" 47)
                 (:endless "releases.test says more in its greeting than is taken" 80)))
  (check (list (first wrong) (list :error (second wrong)) (and (third wrong) (list (list :alert (third wrong)))))
         (destructuring-bind (result told) (kept-closed "https://releases.test/hello.txt" :accident (first wrong))
           (list (first wrong) result (remove :named told :key #'car)))))
;; And after it, in what is fetched: a record that was changed on the way, one that comes twice, one in the open, one that is
;; too long, a piece of a greeting, a word of an older TLS, and keys that change in a way that is none.
(dolist (wrong '((:spoiled "what releases.test sent does not open with the key of this connection: it was changed on the way, or is not from releases.test" 20)
                 (:twice "what releases.test sent does not open with the key of this connection: it was changed on the way, or is not from releases.test" 20)
                 (:open-record "what releases.test sent does not open with the key of this connection: it was changed on the way, or is not from releases.test" 20)
                 (:long "releases.test sent a record of 17000 bytes, which is longer than a record may be" 22)
                 (:late-greeting "releases.test sent a piece of a greeting after the greeting was over" 10)
                 (:old-word-late "releases.test sent a record in the open where everything is closed" 10)
                 (:renew-wrongly "releases.test says that its keys change in a way that is none" 47)))
  (check (list (first wrong) (list :error (second wrong)) (list '(:word) (list :alert (third wrong))))
         (destructuring-bind (result told) (kept-closed "https://releases.test/hello.txt" :accident (first wrong) :record 40)
           (list (first wrong) result (remove :named told :key #'car)))))
;; At a port where nothing keeps a connection closed, and at one where nothing answers.
(check '((:error "releases.test does not answer as TLS does: nothing at that port of it keeps a connection closed")
         (:error "10.0.2.2 takes no connection at its port 443"))
       (list (car (kept-closed "https://releases.test:80/hello.txt")) (car (kept-closed "https://releases.test/hello.txt" :refuse t))))

;; Certificates: who the other side is. Each of these is a machine that shows certificates which are in order but for one
;; thing, with the key that goes with its own.
(defun shown (own key &rest more)
  (destructuring-bind (&key (chain (list *signer*)) (trusted (list *authority*)) (host "releases.test") accident) more
    (destructuring-bind (result told) (kept-closed (format nil "https://~A/hello.txt" host) :chain (cons own chain) :key key :trusted trusted
                                                   :accident accident
                                                   :names (list (cons "releases.test" #x0a000202) (cons "a.wild.test" #x0a000202)
                                                                (cons "wild.test" #x0a000202) (cons "a.b.wild.test" #x0a000202)))
      (list result (second (find :alert told :key #'car))))))

(defun signed-below (&rest options)
  (apply #'certificate :subject "releases.test" :issuer "The tests' signer in between" :key *shown-key* :signer *signer-key* :bits 384
         (append options (list :names '("releases.test")))))

(let ((day 86400) (now (get-universal-time)))
  ;; keys of RSA's, with the newer kind of signature at the end of the greeting and the older in the certificates; the larger
  ;; curve; a certificate that the trusted one signed itself; one that is trusted itself; and the names with a star
  (check (list (list *hello* nil) (list *hello* nil) (list *hello* nil) (list *hello* nil) (list *hello* nil))
         (let ((root (certificate :subject "An RSA root" :key *rsa-key* :authority t :bits 512)))
           (list (shown (certificate :subject "releases.test" :issuer "An RSA root" :key *rsa-key* :signer *rsa-key* :bits 384 :names '("releases.test"))
                        *rsa-key* :chain nil :trusted (list root))
                 (shown (certificate :subject "releases.test" :issuer "The tests' signer in between" :key *large-key* :signer *signer-key* :bits 384
                                     :names '("releases.test"))
                        *large-key*)
                 (shown (certificate :subject "releases.test" :issuer "The tests' root" :issuer-organization "ClaraOS tests" :key *shown-key*
                                     :signer *authority-key* :names '("releases.test"))
                        *shown-key* :chain nil)
                 (let ((alone (certificate :subject "releases.test" :key *other-key* :names '("releases.test"))))
                   (shown alone *other-key* :chain nil :trusted (list alone)))
                 (shown *shown* *shown-key* :host "a.wild.test"))))
  ;; a key on the larger curve signs over the larger sum, and says so: the smaller sum under the smaller curve's name is
  ;; a signature that verifies and that nobody was offered
  (check '((:error "releases.test signs its greeting in a way that it was not offered, or that does not go with its key") 47)
         (shown (certificate :subject "releases.test" :issuer "The tests' signer in between" :key *large-key* :signer *signer-key* :bits 384
                             :names '("releases.test"))
                *large-key* :accident :short-way))
  ;; and a key of RSA's signs the end of a greeting in the newer way only: the older one is for certificates
  (check '((:error "releases.test signs its greeting in a way that it was not offered, or that does not go with its key") 47)
         (let ((root (certificate :subject "An RSA root" :key *rsa-key* :authority t)))
           (shown (certificate :subject "releases.test" :issuer "An RSA root" :key *rsa-key* :signer *rsa-key* :names '("releases.test"))
                  *rsa-key* :chain nil :trusted (list root) :accident :older-way)))
  ;; the certificates in another order, and with one among them that has nothing to do with the others
  (check (list *hello* nil) (shown *shown* *shown-key* :chain (list (certificate :subject "A bystander" :key *other-key* :authority t) *signer*)))
  ;; a name that the certificate is not for
  (check '(((:error "the certificate that wild.test shows is not for that name: it is for releases.test and 1 other names") 42)
           ((:error "the certificate that a.b.wild.test shows is not for that name: it is for releases.test and 1 other names") 42)
           ((:error "the certificate that releases.test shows is not for that name: it is for elsewhere.test") 42)
           ((:error "the certificate that releases.test shows is not for that name: it is for no name at all") 42)
           ((:error "the certificate that 10.0.2.2 shows is not for that name: it is for releases.test") 42))
         (list (shown *shown* *shown-key* :host "wild.test") (shown *shown* *shown-key* :host "a.b.wild.test")
               (shown (certificate :subject "releases.test" :issuer "The tests' signer in between" :key *shown-key* :signer *signer-key* :bits 384
                                   :names '("elsewhere.test"))
                      *shown-key*)
               (shown (certificate :subject "releases.test" :issuer "The tests' signer in between" :key *shown-key* :signer *signer-key* :bits 384)
                      *shown-key*)
               (shown (signed-below) *shown-key* :host "10.0.2.2")))
  ;; the time: a certificate that is not good yet, one that is good no longer, and the same of the ones above it
  (check '(45 45 45 45)
         (mapcar #'second
                 (list (shown (signed-below :from (+ now day) :until (+ now day day)) *shown-key*)
                       (shown (signed-below :from (- now day day) :until (- now day)) *shown-key*)
                       (shown *shown* *shown-key*
                              :chain (list (certificate :subject "The tests' signer in between" :issuer "The tests' root" :issuer-organization "ClaraOS tests"
                                                        :key *signer-key* :signer *authority-key* :authority t :until (- now day))))
                       (shown *shown* *shown-key*
                              :trusted (list (certificate :subject "The tests' root" :organization "ClaraOS tests" :key *authority-key* :authority t
                                                          :until (- now day)))))))
  (check t (let ((result (car (shown (signed-below :from (- now day day) :until (- now day)) *shown-key*))))
             (and (search "the certificate of releases.test was good until " (second result))
                  (search ", and this machine's clock says that it is " (second result))
                  t)))
  ;; who signed it: nobody that is trusted; nobody but itself; somebody who may not sign, whose key is not for signing, or
  ;; who lets nobody sign below; a signature that is not the signer's; and a way of signing that is not known
  (check '(((:error "the certificate of The tests' signer in between is signed by somebody whom this system does not know, and who was not shown") 48)
           ((:error "the certificate of releases.test is signed by somebody whom this system does not know, and who was not shown") 48)
           ((:error "the certificate of releases.test is signed by nobody but itself, and is none that this system trusts") 48)
           ((:error "the certificate of releases.test is signed by The tests' signer in between, who may not sign certificates") 42)
           ((:error "the certificate of releases.test is signed by The tests' signer in between, whose key is not for signing certificates") 42)
           ((:error "the certificate of releases.test is too far below The tests' signer in between, who lets fewer sign in between") 42)
           ((:error "the certificate of releases.test is signed by somebody whom this system does not know, and who was not shown") 48)
           ((:error "the certificate of releases.test is signed in a way that is not known here") 43))
         (flet ((signer (&rest options)
                  (apply #'certificate :subject "The tests' signer in between" :issuer "The tests' root" :issuer-organization "ClaraOS tests"
                         :key *signer-key* :signer *authority-key* options)))
           (list (shown *shown* *shown-key* :trusted nil)
                 (shown *shown* *shown-key* :chain nil)
                 (shown (certificate :subject "releases.test" :key *shown-key* :names '("releases.test")) *shown-key* :chain nil)
                 (shown *shown* *shown-key* :chain (list (signer :authority :no)))
                 (shown *shown* *shown-key* :chain (list (signer :authority t :usage 128)))
                 ;; two signers in between, of which the upper one lets none sign below it
                 (shown (certificate :subject "releases.test" :issuer "The lower signer" :key *shown-key* :signer *other-key* :names '("releases.test"))
                        *shown-key*
                        :chain (list (certificate :subject "The lower signer" :issuer "The tests' signer in between" :key *other-key*
                                                  :signer *signer-key* :bits 384 :authority t)
                                     *signer*))
                 (shown (signed-below :spoil t) *shown-key*)
                 (shown (signed-below :way (der 48 (der 6 '(#x2a #x86 #x48 #x86 #xf7 #x0d 1 1 5)) (der 5))) *shown-key*))))
  ;; what a certificate is for: one that says something which has to be understood, one that is not for a machine that
  ;; serves, and one whose key is not for signing a greeting
  (check '(((:error "the certificate of releases.test says something that has to be understood, and is not understood here") 43)
           ((:error "the certificate of releases.test is not for a machine that serves") 43)
           ((:error "the certificate of releases.test has a key that is not for signing a greeting") 43))
         (list (shown (signed-below :must t) *shown-key*)
               (shown (signed-below :purposes '((#x2b 6 1 5 5 7 3 2))) *shown-key*)
               (shown (signed-below :usage 4) *shown-key*)))
  ;; and what is no certificate, or too many of them
  (check '(t ((:error "releases.test shows no certificate, or more than are looked at") 50))
         (list (let ((result (shown (bytes-of '(48 3 1 2 3)) *shown-key*)))
                 (and (search "releases.test shows a certificate that cannot be read: it is not written as a certificate is" (second (car result)))
                      (eql (second result) 42)))
               (shown *shown* *shown-key* :chain (make-list 10 :initial-element *signer*)))))

;; TRUST adds a certificate to the ones that the machine trusts, from its text or from a file, and says whom it is for; a
;; world keeps the texts, and a start reads them again, into memory of its own.
(new-network :files (files) :trusted nil :disk (fat-bytes (make-fat-volume 16 `(("home" (("root.pem" ,(pem *authority*))))))))
(said-by #'clara.net:up)
(check '(:error "the certificate of The tests' signer in between is signed by somebody whom this system does not know, and who was not shown")
       (fetched "https://releases.test/hello.txt"))
(check '(nil ("The tests' root") ("The tests' root") "hello from the made-up network" ("The tests' signer in between" "The tests' root"))
       (list (clara.tls:roots) (clara.tls:trust "/home/root.pem") (clara.tls:roots) (fetched "https://releases.test/hello.txt")
             (progn (clara.tls:trust (format nil "~A~A" (pem *signer*) (pem *authority*)))
                    (subseq (clara.tls:roots) 1))))
(check '("there is no certificate in that text that can be read" "there is no file /home/none.pem"
         "42 is neither the text of a certificate nor the name of a file that has one" 2)
       (list (condition-text (lambda () (clara.tls:trust (format nil "-----BEGIN CERTIFICATE-----~%AAAA~%-----END CERTIFICATE-----~%"))))
             (condition-text (lambda () (clara.tls:trust "/home/none.pem")))
             (condition-text (lambda () (clara.tls:trust 42)))
             (length clara.tls::*trusted*)))
(clara.tls:start)
(setq clara.tls::*system-read* t)
(check '(nil 0 3) (list clara.tls::*own-roots* clara.tls::*own-read* (length (clara.tls:roots))))
;; Without the device that makes numbers which nobody can guess, nothing is fetched that way, and the machine says why;
;; and the page frames of a greeting that did not begin go back.
(check '(:error "this machine has no device that makes numbers which nobody can guess: a virtio RNG device is one")
       (car (kept-closed "https://releases.test/hello.txt" :numbers nil)))
;; A machine that fetches nothing that way has read no list.
(new-network :files (files))
(setq clara.tls::*system-read* nil)
(said-by #'clara.net:up)
(check '("hello from the made-up network" nil) (list (fetched "http://releases.test/hello.txt") clara.tls::*system-read*))
(setq clara.tls::*system-read* t)

;;; A system from another machine (lisp/system.lisp): a release is a
;;; system's files on a web server, with a signature of its manifest. What
;;; arrives is held against the signature and the manifest, and is taken
;;; like a system from a disk.

(check '((0 0 28) (1 2) (10 0 3 1) (0 0 1) nil nil nil nil)
       (mapcar #'clara.system::version-of '("0.0.28-41d0c97b" "1.2" "10.0.3.1-x-y" "0.0.1-new" "new-0.0.1" "" "-1" "0..1")))
(check '(t t t nil nil nil nil nil t)
       (list (clara.system::newer-p "0.0.29-a" "0.0.28-b") (clara.system::newer-p "0.1.0-a" "0.0.99-b")
             (clara.system::newer-p "1.0-a" "0.9.9-b") (clara.system::newer-p "0.0.28-a" "0.0.28-b")
             (clara.system::newer-p "0.0.27-a" "0.0.28-b") (clara.system::newer-p "0.0-a" "0.0.1-b")
             (clara.system::newer-p "newest" "0.0.1-b") (clara.system::newer-p "0.0.2-a" "this one")
             (clara.system::newer-p "0.0.28.1-a" "0.0.28-b")))
(check '("http://h/a/latest" "http://h/a/latest" "http://h/a/x/manifest")
       (list (clara.system::at-address "http://h/a/" "latest") (clara.system::at-address "http://h/a" "latest")
             (clara.system::at-address "http://h/a" "x" "/manifest")))

(defvar *secret* (loop for i from 1 to 32 collect i))     ; the secret half of the key that the tests sign with
(defun digits-of (bytes)
  (format nil "~(~{~2,'0x~}~)" (coerce bytes 'list)))
(defvar *public* (digits-of (clara.host:ed25519-public *secret*)))

;; What a web server has of a release: the files of the system NAME, its
;; manifest, the signature of that, and the word that it is the newest.
(defun release (name files &key (latest name) (secret *secret*) wrong (at "/releases/") signature manifest)
  (let* ((tree (second (system-tree name files :wrong wrong)))
         (signed (second (assoc "manifest" tree :test #'string=))))
    (append (list (cons (concatenate 'string at "latest") (format nil "~A~%" latest))
                  (cons (format nil "~A~A/manifest.sig" at latest)
                        (or signature (format nil "~A~%" (digits-of (clara.host:ed25519-sign secret (octets signed)))))))
            (loop for (file contents) in tree
                  collect (cons (format nil "~A~A/~A" at latest file) (if (and manifest (string= file "manifest")) manifest contents))))))

;; A machine with its own disk, a network card, and a network that has
;; those files; started, and with the key that the tests sign with.
(defun machine-and-releases (files &rest options)
  (setq *machine-disk* (fat-bytes (make-fat-volume 16 (machine-tree))))
  (apply #'new-network :disk *machine-disk* :files files options)
  (setq clara.windows::*running* nil)
  (clara.host:set-start-state)
  (said-by-all #'clara.system:start)
  (said-by #'clara.net:up)
  (setq clara.system:*release-key* *public*
        clara.system:*releases* nil))

;; The newest system that is published somewhere, and all of it taken: the
;; files are on the disk, each as the manifest says, the manifest is the
;; one that was signed, and the machine is to try the system when it
;; starts next. Every file was asked for once.
(machine-and-releases (release "0.0.1-new" *new-files*))
(check '("0.0.1-new" "0.0.1-new") (list (clara.system:newest "https://releases.test/releases/") (clara.system:newest "https://releases.test/releases")))
(let ((pages (clara.host:allocated-pages)))
  (check (format nil "system: 0.0.1-new is published at https://releases.test/releases/, and signed with the key that this system has: its files are fetched~%~
                      system: 0.0.1-new is on the disk, and is tried at the next start~%")
         (said-by-all (lambda () (clara.system:upgrade :from "https://releases.test/releases/" :start-again nil))))
  (check t (eventually (lambda () (= pages (clara.host:allocated-pages))))))
(check (list "(the new system)" *long-text* "" "the new kernel" "the new kernel of the other processor"
             (second (assoc "manifest" (second (system-tree "0.0.1-new" *new-files*)) :test #'string=))
             (format nil "try 0.0.1-new~%") "(the old system)" t)
       (list (on-disk *machine-disk* "/clara/0.0.1-new/boot.lisp") (on-disk *machine-disk* "/clara/0.0.1-new/long.lisp")
             (on-disk *machine-disk* "/clara/0.0.1-new/empty.lisp") (on-disk *machine-disk* (format nil "/clara/0.0.1-new/~A" *this-kernel*))
             (on-disk *machine-disk* (format nil "/clara/0.0.1-new/~A" *other-kernel*)) (on-disk *machine-disk* "/clara/0.0.1-new/manifest")
             (on-disk *machine-disk* "/clara/next") (on-disk *machine-disk* "/clara/0.0.0-host/boot.lisp") (in-order-p *machine-disk*)))
(check (sort (append (list "/releases/latest" "/releases/latest" "/releases/latest" "/releases/0.0.1-new/manifest.sig"
                           "/releases/0.0.1-new/manifest")
                     (mapcar (lambda (file) (format nil "/releases/0.0.1-new/~A" (car file))) *new-files*))
             #'string<)
       (sort (mapcar #'second (remove :get (network-heard *network*) :key #'car :test-not #'eq)) #'string<))
;; The machine is started again to try it, unless it is told not to; and
;; with nothing said of where, a machine without another disk looks where
;; it knows ClaraOS to be published, when it knows of such a place.
(machine-and-releases (release "0.0.1-new" *new-files*))
(check "no other disk of this machine holds a ClaraOS other than this one, 0.0.0-host" (condition-text #'clara.system:upgrade))
(setq clara.system:*releases* "https://10.0.2.2/releases/")
(check t (let ((said (said-by-all #'clara.system:upgrade)))
           (and (eql 0 (search (format nil "system: no other disk of this machine holds another ClaraOS, so the newest one is looked for at ~
                                            https://10.0.2.2/releases/~%system: 0.0.1-new is published at https://10.0.2.2/releases/")
                               said))
                (search "clara: starting the machine again" said)
                t)))
(check (list '(:again) (format nil "try 0.0.1-new~%") 0)
       (list (clara.host:power) (on-disk *machine-disk* "/clara/next")
             (search "(:carried \"0.0.0-host\" \"0.0.1-new\")" (on-disk *machine-disk* "/clara/carried"))))
(check "this system knows of no place where ClaraOS is published: CLARA.SYSTEM:*RELEASES* names none"
       (let ((clara.system:*releases* nil)) (condition-text #'clara.system:newest)))

;; What is not taken, and what the disk has of it afterwards: nothing that
;; a start would try.
(defun not-taken (files &rest more)
  (machine-and-releases files)
  (let ((pages (clara.host:allocated-pages)))
    (prog1 (list (let ((complaint nil))
                   (said-by-all (lambda ()
                                  (setq complaint (condition-text (lambda () (apply #'clara.system:upgrade :from "https://releases.test/releases/"
                                                                                    :start-again nil more))))))
                   complaint)
                 (on-disk *machine-disk* "/clara/next") (on-disk *machine-disk* "/clara/0.0.1-new/manifest")
                 (and (on-disk *machine-disk* "/clara/0.0.1-new/boot.lisp") t) (in-order-p *machine-disk*))
      (unless (eventually (lambda () (= pages (clara.host:allocated-pages))))
        (failed "an upgrade that was refused kept ~D page frames" (- (clara.host:allocated-pages) pages))))))

;; What an upgrade says, and what it ends with when it ends with an error.
(defun said-and-complaint (&rest arguments)
  (let ((complaint nil))
    (list (said-by-all (lambda () (setq complaint (condition-text (lambda () (apply #'clara.system:upgrade arguments))))))
          complaint)))

;; A release that somebody else signed; one whose signature is no
;; signature; and one whose manifest was changed after it was signed.
(dolist (files (list (release "0.0.1-new" *new-files* :secret (loop for i from 2 to 33 collect i))
                     (release "0.0.1-new" *new-files* :signature "this is no signature")
                     (release "0.0.1-new" *new-files* :signature "")
                     (release "0.0.1-new" *new-files*
                              :manifest (second (assoc "manifest" (second (system-tree "0.0.1-new" (cons '("more.lisp" "(more)") *new-files*)))
                                                       :test #'string=)))))
  (check '("the manifest of 0.0.1-new at https://releases.test/releases/ is not signed with the key that this system has: nothing of it is taken"
           nil nil nil t)
         (not-taken files)))
;; A file that is not what the signed manifest says: the files before it
;; are on the disk, the manifest is not, and nothing says to try it.
(check '("the file /clara/0.0.1-new/long.lisp is not what the manifest of its system says it is" nil nil t t)
       (not-taken (release "0.0.1-new" *new-files* :wrong "long.lisp")))
;; A file that the server does not have.
(check '("releases.test answers 404 to the request for /releases/0.0.1-new/long.lisp" nil nil t t)
       (not-taken (remove "/releases/0.0.1-new/long.lisp" (release "0.0.1-new" *new-files*) :key #'car :test #'string=)))
;; The word of which system is the newest is not signed, and is not
;; believed further than to look: a name that is none, and a name whose
;; manifest is that of another system.
(check '("https://releases.test/releases/latest names no system: what it says is \"../../EFI/BOOT\"" nil nil nil t)
       (not-taken (release "0.0.1-new" *new-files* :latest "../../EFI/BOOT")))
(check '("https://releases.test/releases/latest names no system: what it says is \"the newest of all\"" nil nil nil t)
       (not-taken (release "0.0.1-new" *new-files* :latest "the newest of all")))
(check '("the manifest of 0.0.2-newer at https://releases.test/releases/ is that of another system, or of none" nil nil nil t)
       (not-taken (release "0.0.1-new" *new-files* :latest "0.0.2-newer")))
;; A system that is no newer than the one that runs is not taken unasked,
;; and the one that runs is not taken at all.
(check '("the newest ClaraOS at https://releases.test/releases/ is 0.0.0-other, which is no newer than this one, 0.0.0-host: :ANY T takes it all the same"
         nil nil nil t)
       (list* (car (not-taken (release "0.0.0-other" *new-files*))) (cdr (not-taken (release "0.0.0-other" *new-files*)))))
(machine-and-releases (release "0.0.0-other" *new-files*))
(check '("0.0.0-other" t) (list (progn (said-by-all (lambda () (clara.system:upgrade :from "https://releases.test/releases/" :start-again nil :any t)))
                                        (clara.system::waiting))
                                 (and (on-disk *machine-disk* "/clara/0.0.0-other/manifest") t)))
(check '("the newest ClaraOS at https://releases.test/releases/ is 0.0.0-host, which is the system that runs" nil nil nil t)
       (not-taken (release "0.0.0-host" *old-files*) :any t))
;; A release is fetched over a connection that is kept closed, and over no other: not when the address is given, and not
;; when it is the one that the system knows of, which the machine then does not say that it looks at. Nothing is asked
;; of the network for it.
(machine-and-releases (release "0.0.1-new" *new-files*))
(check '("http://releases.test/releases/ does not begin with https://: a release is fetched over a connection that is kept closed, and over no other"
         "http://releases.test/releases/ does not begin with https://: a release is fetched over a connection that is kept closed, and over no other"
         ("" "releases.test/releases/ does not begin with https://: a release is fetched over a connection that is kept closed, and over no other")
         0 nil)
       (list (condition-text (lambda () (clara.system:newest "http://releases.test/releases/")))
             (condition-text (lambda () (clara.system:upgrade :from "http://releases.test/releases/" :any t)))
             (let ((clara.system:*releases* "releases.test/releases/")) (said-and-complaint))
             (network-saw *network* :get) (on-disk *machine-disk* "/clara/next")))
;; Without a key nothing that is fetched can be held against anything, so
;; nothing is fetched, and the machine does not say that it looks
;; anywhere: not where the address is given, and not where it is the one
;; that the system knows of.
(machine-and-releases (release "0.0.1-new" *new-files*))
(setq clara.system:*release-key* nil)
(check "this system has no key to hold a release against: CLARA.SYSTEM:*RELEASE-KEY* is NIL"
       (condition-text (lambda () (clara.system:upgrade :from "https://releases.test/releases/"))))
(check '("" "this system has no key to hold a release against: CLARA.SYSTEM:*RELEASE-KEY* is NIL")
       (let ((clara.system:*releases* "https://releases.test/releases/")) (said-and-complaint :any t)))
(check '(0 nil nil) (list (network-saw *network* :get) (on-disk *machine-disk* "/clara/next") (clara.host:power)))
;; A disk still goes before the network: a machine that knows where
;; ClaraOS is published and has another disk with a system on it takes the
;; one on the disk, and asks the network nothing.
(setq *machine-disk* (fat-bytes (make-fat-volume 16 (machine-tree))))
(new-network :disk *machine-disk* :files (release "0.0.2-newer" *new-files*)
             :other (fat-bytes (make-fat-volume 16 `(("clara" (,(system-tree "0.0.1-new" *new-files*)))))))
(setq clara.windows::*running* nil)
(clara.host:set-start-state)
(said-by-all #'clara.system:start)
(setq clara.system:*release-key* *public*
      clara.system:*releases* "https://releases.test/releases/")
(check '("0.0.1-new" nil 0)
       (let ((name nil))
         (said-by-all (lambda () (setq name (clara.system:upgrade :start-again nil))))
         (list name (network-heard *network*) (network-saw *network* :get))))
(setq clara.system:*releases* nil)
(machine-and-releases (release "0.0.1-new" *new-files*))
;; And a volume that is named is a volume.
(setq clara.system:*release-key* *public*
      clara.system:*releases* "https://releases.test/releases/")
(check "that volume holds no ClaraOS other than this one, 0.0.0-host"
       (condition-text (lambda () (clara.system:upgrade :from (clara.system:boot-volume)))))
(setq clara.system:*releases* nil)

;; The network's thread and the card's go with the machine.
(stop-network)
(setq clara.net:*patience* 10000)

(clara.host:reset-machine)
(clara.host:set-start-state)
(clara:destroy-thread clara.system::*watcher*)
(check t (eventually (lambda () (= (length (clara:all-threads)) 1))))

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
