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
(load-source "lisp/font.lisp")
(load-source "lisp/console.lisp")
(load-source "lisp/listener.lisp")

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

;;; The listener, on strings.

(defun listen-to (text)
  (with-output-to-string (*standard-output*)
    (with-input-from-string (*standard-input* text)
      (clara.listener:run))))

(defvar *invitation*
  (format nil "clara: reading from the serial port: a form typed there is evaluated, Ctrl-C stops it, Ctrl-D ends~%"))

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
(check 1 (length (clara:all-threads)))

(format t "host tests: ~D checks under ~A ~A, ~D failed~%"
        *checks* (lisp-implementation-type) (lisp-implementation-version) *failures*)
(sb-ext:exit :code (if (zerop *failures*) 0 1) :abort t)
