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
;;;; A row that has moved out at the top is not gone. The terminal keeps
;;;; what its rows say, and Page Up and Page Down, which are keys of the
;;;; window's own, show the rows before and after the ones that it shows.
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
  (:export "OPEN-TERMINAL" "TERMINAL-P" "TERMINAL-STREAM" "TERMINAL-WINDOW" "CLEAR" "*ROWS-KEPT*" "REPL"))
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
  line        ; what the row says that is being written: a string as long as a row, with spaces where nothing is
  kept        ; what the rows before it say, without the spaces at their ends: a ring of strings,
  (oldest 0)  ; in which the oldest row is at this place,
  (held 0)    ; and which holds so many rows
  (back 0)    ; so many rows before the last ones are what the window shows: Page Up and Page Down
  lock        ; one string is written at a time, and the window shows other rows between two of them
  keys        ; the codes of the characters that were typed and not read yet, the oldest first
  keys-lock
  typed       ; the event that says there are some
  reading     ; a line is being read: the cursor shows, and Ctrl-C gives the line up
  cursor      ; (column . row) of the cursor that is drawn, or NIL when none is
  thread      ; the thread that reads here, which Ctrl-C is for
  stream)

(defconstant +keys-limit+ 1024) ; characters that wait to be read; what is typed past that is dropped
(defconstant +ring+ 64)         ; rows that a new terminal has room to keep; the room doubles when it is used up

;; How many rows a terminal keeps of the ones that have left its window, the
;; newest of them, for Page Up to show again: a number, or NIL for all of
;; them. They are kept in the heap, so all of them is as much as the memory
;; holds, and a program that writes without end fills it. Every terminal
;; goes by what this says when a row of its is finished.
(defvar *rows-kept* 100000)

;;; The rows that are kept
;;;
;;; What a row says is known for as long as it is written, in a string of
;;; its own, and kept when the row is finished, by a new line or by a
;;; character past its last column: in a ring, which grows for as long as
;;; rows may be added, and in which the newest takes the place of the
;;; oldest after that. The rows of the window above the one that is being
;;; written are the newest of the ring.

;; How many rows the ring may hold: the ones that the window shows above
;; the row that is being written, and *ROWS-KEPT* more. NIL for any number,
;; which is also what a value that is no number of rows comes to.
(defun limit (terminal)
  (and (integerp *rows-kept*) (>= *rows-kept* 0)
       (+ *rows-kept* (1- (terminal-rows terminal)))))

;; What the row at PLACE says, of the ones that are kept: the oldest is at 0.
(defun kept-row (terminal place)
  (let ((kept (terminal-kept terminal)))
    (aref kept (mod (+ (terminal-oldest terminal) place) (length kept)))))

;; Where, among the rows that are kept, the window's first row is when it
;; shows the last ones: as many rows as that can be gone back.
(defun top (terminal)
  (max 0 (- (1+ (terminal-held terminal)) (terminal-rows terminal))))

;; The row that is being written is finished. What it says is kept, as the
;; newest row, the oldest go when there are more than may be kept, and the
;; string is blank again for the row that comes.
(defun keep-row (terminal)
  (let ((line (terminal-line terminal)) (end (terminal-columns terminal)) (limit (limit terminal)))
    (loop
      (when (or (zerop end) (not (char= (char line (1- end)) #\Space)))
        (return))
      (setq end (1- end)))
    (let ((says (if (zerop end) "" (subseq line 0 end))))
      (dotimes (i end)
        (setf (char line i) #\Space))
      (loop
        (when (or (null limit) (< (terminal-held terminal) limit) (zerop (terminal-held terminal)))
          (return))
        ;; Nothing holds on to what the oldest row said.
        (setf (aref (terminal-kept terminal) (terminal-oldest terminal)) ""
              (terminal-oldest terminal) (mod (1+ (terminal-oldest terminal)) (length (terminal-kept terminal)))
              (terminal-held terminal) (1- (terminal-held terminal))))
      (unless (and limit (zerop limit))
        (when (= (terminal-held terminal) (length (terminal-kept terminal)))
          ;; The ring is full: one twice as long, with the oldest row at its start.
          (let ((longer (make-array (* 2 (terminal-held terminal)) :initial-element "")))
            (dotimes (i (terminal-held terminal))
              (setf (aref longer i) (kept-row terminal i)))
            (setf (terminal-kept terminal) longer
                  (terminal-oldest terminal) 0)))
        (setf (aref (terminal-kept terminal)
                    (mod (+ (terminal-oldest terminal) (terminal-held terminal)) (length (terminal-kept terminal))))
              says
              (terminal-held terminal) (1+ (terminal-held terminal)))))))

;; What the window shows is drawn again, from what its rows say: the last
;; ones, or the ones that are so many rows before them.
(defun repaint (terminal)
  (let ((surface (terminal-surface terminal))
        (held (terminal-held terminal))
        (from (- (top terminal) (terminal-back terminal))))
    (clara.draw:fill-rectangle surface 0 0 (* (terminal-columns terminal) clara.font:+width+)
                               (* (terminal-rows terminal) clara.font:+height+) (terminal-paper terminal))
    (dotimes (row (terminal-rows terminal))
      (let* ((place (+ from row))
             (says (cond ((< place held) (kept-row terminal place))
                         ((= place held) (terminal-line terminal))
                         (t ""))))
        (when (plusp (length says))
          (clara.draw:draw-text surface 0 (* row clara.font:+height+) says
                                (terminal-ink terminal) (terminal-paper terminal)))))))

;;; Writing
;;;
;;; What is written goes to the last row, whatever the window shows. While
;;; it shows the last rows, each character is drawn as it comes. While it
;;; shows rows from further back, nothing is drawn: the rows that it shows
;;; stay, one row further back with every row that is finished, until the
;;; oldest of them is no longer kept.

;; A new row. Past the last one, every row moves up by one, and the last
;; is blank.
(defun new-row (terminal)
  (setf (terminal-column terminal) 0)
  (keep-row terminal)
  (cond ((< (1+ (terminal-row terminal)) (terminal-rows terminal))
         (setf (terminal-row terminal) (1+ (terminal-row terminal))))
        ((zerop (terminal-back terminal))
         (let* ((surface (terminal-surface terminal))
                (width (* (terminal-columns terminal) clara.font:+width+))
                (kept (* (1- (terminal-rows terminal)) clara.font:+height+)))
           (clara.draw:copy-rectangle surface 0 clara.font:+height+ width kept surface 0 0)
           (clara.draw:fill-rectangle surface 0 kept width clara.font:+height+ (terminal-paper terminal))))
        ((< (terminal-back terminal) (top terminal))
         (setf (terminal-back terminal) (1+ (terminal-back terminal))))
        (t
         ;; The oldest row that the window showed is gone: it shows the oldest that there are.
         (setf (terminal-back terminal) (top terminal))
         (repaint terminal))))

;; The characters of STRING from START to END, which the row has room for,
;; where the next character goes.
(defun put (terminal string start end)
  (let ((line (terminal-line terminal)) (column (terminal-column terminal)))
    (dotimes (i (- end start))
      (setf (char line (+ column i)) (char string (+ start i))))
    (when (zerop (terminal-back terminal))
      (clara.draw:draw-text (terminal-surface terminal)
                            (* column clara.font:+width+)
                            (* (terminal-row terminal) clara.font:+height+)
                            (subseq string start end) (terminal-ink terminal) (terminal-paper terminal)))
    (setf (terminal-column terminal) (+ column (- end start)))))

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
;; put back after, and a window that shows rows from further back has none.
(defun paint-cursor (terminal column row pixel)
  (clara.draw:fill-rectangle (terminal-surface terminal) (* column clara.font:+width+)
                             (- (* (1+ row) clara.font:+height+) 2) clara.font:+width+ 2 pixel))

(defun hide-cursor (terminal)
  (let ((cursor (terminal-cursor terminal)))
    (when cursor
      (paint-cursor terminal (car cursor) (cdr cursor) (terminal-paper terminal))
      (setf (terminal-cursor terminal) nil))))

(defun show-cursor (terminal)
  (when (and (terminal-reading terminal) (zerop (terminal-back terminal))
             (< (terminal-column terminal) (terminal-columns terminal)))
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

;; Every cell is blank, the next character goes to the first, and no row
;; is kept: there is nothing to go back to.
(defun clear (terminal)
  (clara:with-lock-held ((terminal-lock terminal))
    (clara.draw:fill-rectangle (terminal-surface terminal) 0 0
                               (* (terminal-columns terminal) clara.font:+width+)
                               (* (terminal-rows terminal) clara.font:+height+) (terminal-paper terminal))
    (dotimes (i (terminal-columns terminal))
      (setf (char (terminal-line terminal) i) #\Space))
    (setf (terminal-cursor terminal) nil
          (terminal-column terminal) 0
          (terminal-row terminal) 0
          (terminal-kept terminal) (make-array +ring+ :initial-element "")
          (terminal-oldest terminal) 0
          (terminal-held terminal) 0
          (terminal-back terminal) 0)
    (show-cursor terminal)
    (clara.windows:show (terminal-window terminal)))
  nil)

;;; Looking back
;;;
;;; Page Up shows the rows before the ones that the window shows, a
;;; window's worth less one, so that a row of what was there stays, and
;;; Page Down the rows after them. The two are the window's own keys, and
;;; nobody reads them: the thread that reads here may be computing, with
;;; rows going by that somebody wants to look at. So the rows are drawn
;;; where the keys arrive, in the thread of the keyboard, with the lock
;;; that whoever writes has.

;; The window shows the rows that are BY rows further back, or further on
;; when BY is negative: as far back as rows are kept, and no further on
;; than the last ones, which are what NIL asks for. True when it shows
;; other rows than before.
(defun scroll (terminal by)
  (clara:with-lock-held ((terminal-lock terminal))
    (let ((back (if by
                    (max 0 (min (top terminal) (+ (terminal-back terminal) by)))
                    0)))
      (unless (= back (terminal-back terminal))
        (hide-cursor terminal)
        (setf (terminal-back terminal) back)
        (repaint terminal)
        (show-cursor terminal)
        (clara.windows:show (terminal-window terminal))
        t))))

;;; Reading
;;;
;;; The window manager hands in the characters that are typed while the
;;; window has the focus, KEY-TYPED, in the thread of the keyboard. They
;;; wait here for the thread that reads lines. Ctrl-C is the exception. A
;;; thread that is reading a line gets it as a character, which gives the
;;; line up. A thread that is not is computing, or about to, a line that
;;; ends being as good as read: what it does is stopped
;;; (CLARA:INTERRUPT-THREAD), and whatever was typed ahead is forgotten.
;;; Page Up and Page Down are not handed on at all (SCROLL), and any other
;;; key brings the last rows back first, where what it types is echoed.

(defun key-typed (terminal code)
  (let ((page (max 1 (1- (terminal-rows terminal)))))
    (cond ((= code clara.input:+page-up+)
           (scroll terminal page))
          ((= code clara.input:+page-down+)
           (scroll terminal (- page)))
          (t
           (when (plusp (terminal-back terminal))
             (scroll terminal nil))
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
                 (clara:signal-event (terminal-typed terminal)))))))
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
;; CLOSE are for). What is typed in it is the stream's to give back, but for
;; Page Up and Page Down.
(defun open-terminal (title &key (columns 80) (rows 24) x y close)
  (unless (and (integerp columns) (integerp rows) (plusp columns) (plusp rows))
    (error "a terminal has a number of columns and of rows, and ~S by ~S are not that" columns rows))
  (let* ((terminal (make-terminal :columns columns :rows rows
                                  :line (make-string columns :initial-element #\Space)
                                  :kept (make-array +ring+ :initial-element "")
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
;;; editor, lisp/jaid.lisp, the file browser, and lisp/ares.lisp, the web
;;; browser. They are installed by their bare names, which are the system's
;;; to find wherever its files are.

(clara.windows:install-application "Emma" "emma.lisp")
(clara.windows:install-application "Jaid" "jaid.lisp")
(clara.windows:install-application "Ares" "ares.lisp")
