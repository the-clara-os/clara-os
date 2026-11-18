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
(load-source "lisp/font.lisp")
(load-source "lisp/console.lisp")
(load-source "lisp/draw.lisp")
(load-source "lisp/pci.lisp")
(load-source "lisp/virtio.lisp")
(load-source "lisp/input.lisp")
(load-source "lisp/disk.lisp")
(load-source "lisp/fat.lisp")
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
  (let ((echo (symbol-function 'clara.console::echo)))
    (unwind-protect
         (progn
           (setf (symbol-function 'clara.console::echo)
                 (lambda (string)
                   (funcall echo string)
                   (setf (clara.unsafe:port-8 #x80) 0)))
           (check "x" (clara.console:read-text-line)))
      (setf (symbol-function 'clara.console::echo) echo)))
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
        clara.console::*cursor* #x7fff0100
        clara.console::*reading* t
        clara.console::*keys* (list 97)
        clara.console::*after-return* t)
  (clara.host:set-serial-device :pl011 #x9000000)
  (attach-pl011 #x9000000)
  (clara.console:start)
  (check '(nil nil nil nil nil)
         (list clara.console::*screen* clara.console::*cursor* clara.console::*reading* clara.console::*keys*
               clara.console::*after-return*))
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
(check '(nil nil nil nil nil nil nil nil nil nil nil)   ; the keys that type nothing: Esc, the modifiers, the arrows
       (mapcar (lambda (key) (clara.input:key-character key t t t)) '(0 1 29 42 54 56 58 59 103 108 300)))

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
    (check '((10 0 0) t) (events mouse (first vdevs) 2 0 10 0 0 0))))    ; and the mouse goes on from where the pen was

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
