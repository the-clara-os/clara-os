;;;; terminal.lisp: a console in a window
;;;;
;;;; A terminal is a window with a grid of cells in it, each as large as a
;;;; glyph of the font, and a stream: what is written to the stream is
;;;; drawn in the cells, a new line past the last row moves every row up by
;;;; one, and what is typed while the window has the focus comes back from
;;;; the stream a line at a time, put together and echoed the way the
;;;; console does it (lisp/console.lisp). It draws like everything else, on
;;;; its window's surface (lisp/draw.lisp), and shows what it has drawn
;;;; when a string is written (lisp/windows.lisp).
;;;;
;;;; The REPL is the first application, the listener in a window: a
;;;; terminal, and a thread that reads forms from it, evaluates them and
;;;; prints what they give (lisp/listener.lisp). It is the one world that
;;;; every listener evaluates in: what is defined in one window is defined
;;;; on the serial port, and in the next window.
;;;;
;;;; This file loads under SBCL as well, where lisp/host/ stands in for the
;;;; machine.

(defpackage "CLARA.TERMINAL"
  (:use "COMMON-LISP")
  (:export "OPEN-TERMINAL" "TERMINAL-P" "TERMINAL-STREAM" "TERMINAL-WINDOW" "CLEAR" "REPL"))
(in-package "CLARA.TERMINAL")

(defstruct terminal
  window      ; the window that it is in,
  surface     ; and what that is drawn on
  columns     ; the size of the grid, in cells
  rows
  (column 0)  ; where the next character goes; past the last column, it starts a new row first
  (row 0)
  ink         ; the pixel of a glyph,
  paper       ; and the pixel around it
  lock        ; one string is written at a time
  keys        ; the codes of the characters that were typed and not read yet, the oldest first
  keys-lock
  typed       ; the event that says there are some
  reading     ; a line is being read: the cursor shows, and Ctrl-C gives the line up
  cursor      ; (column . row) of the cursor that is drawn, or NIL when none is
  thread      ; the thread that reads here, which Ctrl-C is for
  stream)

(defconstant +keys-limit+ 1024) ; characters that wait to be read; what is typed past that is dropped

;;; Writing

;; A new row. Past the last one, every row moves up by one, and the last
;; is blank.
(defun new-row (terminal)
  (setf (terminal-column terminal) 0)
  (if (< (1+ (terminal-row terminal)) (terminal-rows terminal))
      (setf (terminal-row terminal) (1+ (terminal-row terminal)))
      (let* ((surface (terminal-surface terminal))
             (width (* (terminal-columns terminal) clara.font:+width+))
             (kept (* (1- (terminal-rows terminal)) clara.font:+height+)))
        (clara.draw:copy-rectangle surface 0 clara.font:+height+ width kept surface 0 0)
        (clara.draw:fill-rectangle surface 0 kept width clara.font:+height+ (terminal-paper terminal)))))

;; The characters of STRING from START to END, which the row has room for,
;; where the next character goes.
(defun put (terminal string start end)
  (clara.draw:draw-text (terminal-surface terminal)
                        (* (terminal-column terminal) clara.font:+width+)
                        (* (terminal-row terminal) clara.font:+height+)
                        (subseq string start end) (terminal-ink terminal) (terminal-paper terminal))
  (setf (terminal-column terminal) (+ (terminal-column terminal) (- end start))))

;; A tab: spaces up to the next column that is a multiple of eight.
(defun tab (terminal)
  (loop
    (when (= (terminal-column terminal) (terminal-columns terminal))
      (new-row terminal))
    (put terminal " " 0 1)
    (when (or (zerop (mod (terminal-column terminal) 8))
              (= (terminal-column terminal) (terminal-columns terminal)))
      (return))))

;; The four characters that move the place of the next one and draw nothing.
(defun moves-p (code)
  (or (= code 10) (= code 13) (= code 8) (= code 9)))

;; While a line is being read, a bar under the cell where the next
;; character goes says where that is, as on the console: the lowest two
;; rows of the cell's pixels. It is taken away before anything is drawn and
;; put back after.
(defun paint-cursor (terminal column row pixel)
  (clara.draw:fill-rectangle (terminal-surface terminal) (* column clara.font:+width+)
                             (- (* (1+ row) clara.font:+height+) 2) clara.font:+width+ 2 pixel))

(defun hide-cursor (terminal)
  (let ((cursor (terminal-cursor terminal)))
    (when cursor
      (paint-cursor terminal (car cursor) (cdr cursor) (terminal-paper terminal))
      (setf (terminal-cursor terminal) nil))))

(defun show-cursor (terminal)
  (when (and (terminal-reading terminal) (< (terminal-column terminal) (terminal-columns terminal)))
    (setf (terminal-cursor terminal) (cons (terminal-column terminal) (terminal-row terminal)))
    (paint-cursor terminal (terminal-column terminal) (terminal-row terminal) (terminal-ink terminal))))

;; A string: its characters are drawn, as many to the call as a row has
;; room for, and then the window shows what has changed. No other thread's
;; string gets in between.
(defun write-text (terminal string)
  (clara:with-lock-held ((terminal-lock terminal))
    (hide-cursor terminal)
    (let ((start 0) (length (length string)))
      (loop
        (when (= start length)
          (return))
        (let ((code (char-code (char string start))))
          (cond ((= code 10)
                 (new-row terminal)
                 (setq start (1+ start)))
                ((= code 13)
                 (setf (terminal-column terminal) 0)
                 (setq start (1+ start)))
                ((= code 8)
                 (when (plusp (terminal-column terminal))
                   (setf (terminal-column terminal) (1- (terminal-column terminal))))
                 (setq start (1+ start)))
                ((= code 9)
                 (tab terminal)
                 (setq start (1+ start)))
                (t
                 (when (= (terminal-column terminal) (terminal-columns terminal))
                   (new-row terminal))
                 (let ((end (1+ start))
                       (limit (min length (+ start (- (terminal-columns terminal) (terminal-column terminal))))))
                   (loop
                     (when (or (= end limit) (moves-p (char-code (char string end))))
                       (return))
                     (setq end (1+ end)))
                   (put terminal string start end)
                   (setq start end)))))))
    (show-cursor terminal)
    (clara.windows:show (terminal-window terminal)))
  string)

;; Every cell is blank, and the next character goes to the first.
(defun clear (terminal)
  (clara:with-lock-held ((terminal-lock terminal))
    (clara.draw:fill-rectangle (terminal-surface terminal) 0 0
                               (* (terminal-columns terminal) clara.font:+width+)
                               (* (terminal-rows terminal) clara.font:+height+) (terminal-paper terminal))
    (setf (terminal-cursor terminal) nil
          (terminal-column terminal) 0
          (terminal-row terminal) 0)
    (show-cursor terminal)
    (clara.windows:show (terminal-window terminal)))
  nil)

;;; Reading
;;;
;;; The window manager hands in the characters that are typed while the
;;; window has the focus, KEY-TYPED, in the thread of the keyboard. They
;;; wait here for the thread that reads lines. Ctrl-C is the exception. A
;;; thread that is reading a line gets it as a character, which gives the
;;; line up. A thread that is not is computing, or about to, a line that
;;; ends being as good as read: what it does is stopped
;;; (CLARA:INTERRUPT-THREAD), and whatever was typed ahead is forgotten.

(defun key-typed (terminal code)
  (let ((stops nil))
    (clara:with-lock-held ((terminal-keys-lock terminal))
      (cond ((and (= code 3)
                  (or (not (terminal-reading terminal))
                      (member 10 (terminal-keys terminal))
                      (member 13 (terminal-keys terminal))))
             (setf (terminal-keys terminal) nil)
             (setq stops t))
            ((< (length (terminal-keys terminal)) +keys-limit+)
             (setf (terminal-keys terminal) (append (terminal-keys terminal) (list code))))))
    (if stops
        (when (terminal-thread terminal)
          (clara:interrupt-thread (terminal-thread terminal)))
        (clara:signal-event (terminal-typed terminal))))
  code)

;; The next character that was typed. With the end of a line the reading
;; is over, there and then: a Ctrl-C that comes after it finds a thread
;; that computes.
(defun next-code (terminal)
  (loop
    (let ((code (clara:with-lock-held ((terminal-keys-lock terminal))
                  (let ((code (car (terminal-keys terminal))))
                    (setf (terminal-keys terminal) (cdr (terminal-keys terminal)))
                    (when (and code (or (= code 10) (= code 13)))
                      (setf (terminal-reading terminal) nil))
                    code))))
      (when code
        (return code)))
    (clara:wait-event (terminal-typed terminal))))

;; The cursor is drawn or taken away, by whether a line is being read.
(defun cursor-shows (terminal)
  (clara:with-lock-held ((terminal-lock terminal))
    (hide-cursor terminal)
    (show-cursor terminal)
    (clara.windows:show (terminal-window terminal))))

;; The next line that was typed, without its end, or NIL when no more is
;; coming, which is what Ctrl-D at the start of a line says. The cursor
;; shows for as long, and Ctrl-C is from now on for the thread that reads.
(defun read-text-line (terminal)
  (setf (terminal-thread terminal) (clara:current-thread)
        (terminal-reading terminal) t)
  (cursor-shows terminal)
  (unwind-protect (clara.console:read-edited-line (lambda () (next-code terminal)) (terminal-stream terminal))
    (setf (terminal-reading terminal) nil)
    (cursor-shows terminal)))

;;; A terminal

;; A window of COLUMNS by ROWS cells with that title, and the terminal in
;; it, whose stream is TERMINAL-STREAM. The window is the thread's that
;; opens it, like any other (CLARA.WINDOWS:OPEN-WINDOW, which X, Y and
;; CLOSE are for).
(defun open-terminal (title &key (columns 80) (rows 24) x y close)
  (unless (and (integerp columns) (integerp rows) (plusp columns) (plusp rows))
    (error "a terminal has a number of columns and of rows, and ~S by ~S are not that" columns rows))
  (let* ((terminal (make-terminal :columns columns :rows rows
                                  :ink (clara.draw:color 232 227 244) :paper (clara.draw:color 30 27 46)
                                  :lock (clara:make-lock "terminal") :keys-lock (clara:make-lock "keys")
                                  :typed (clara:make-event "typed")))
         (window (clara.windows:open-window title (* columns clara.font:+width+) (* rows clara.font:+height+)
                                            :x x :y y :close close
                                            :key (lambda (code) (key-typed terminal code)))))
    (setf (terminal-window terminal) window
          (terminal-surface terminal) (clara.windows:window-surface window)
          (terminal-stream terminal) (clara:make-stream :write-string (lambda (string) (write-text terminal string))
                                                        :read-line (lambda () (read-text-line terminal))))
    terminal))

;;; The REPL
;;;
;;; An application, for the launcher: a terminal of 80 by 24 cells, or as
;;; many as the screen has room for, and the listener reading from it and
;;; writing to it, with a package of its own to be in. Ctrl-D at its prompt
;;; ends it, and so does the close box; either way the window goes with it.

(defun repl ()
  (let* ((screen (clara.draw:screen))
         (thread (clara:current-thread))
         (terminal (open-terminal
                    "REPL"
                    :columns (max 20 (min 80 (floor (- (clara.draw:surface-width screen) 48) clara.font:+width+)))
                    :rows (max 4 (min 24 (floor (- (clara.draw:surface-height screen) 120) clara.font:+height+)))
                    :close (lambda () (clara:destroy-thread thread))))
         (*standard-output* (terminal-stream terminal))
         (*standard-input* (terminal-stream terminal))
         (*package* (find-package "COMMON-LISP-USER")))
    (write-line "ClaraOS: a form is evaluated, Ctrl-C stops it, and Ctrl-D closes the window")
    ;; A condition that comes all the way out of the listener is said, and
    ;; the listener goes on.
    (loop
      (handler-case (return (clara.listener:answer-lines))
        (serious-condition (condition)
          (fresh-line)
          (format t "error: ~A~%" condition))))))

(clara.windows:define-application "REPL" #'repl)

;;; The applications that come with the system, after the REPL in the
;;; launcher's list. Each is a file of its own among the system's, which
;;; nobody loads until the application is picked: lisp/emma.lisp, the
;;; editor, lisp/files.lisp, and lisp/ares.lisp, the web browser. They are
;;; installed by their bare names, which are the system's to find wherever
;;; its files are.

(clara.windows:install-application "Emma" "emma.lisp")
(clara.windows:install-application "Files" "files.lisp")
(clara.windows:install-application "Ares" "ares.lisp")
