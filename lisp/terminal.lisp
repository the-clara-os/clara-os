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
;;;; What is typed is Lisp more often than not, so a line shows which of
;;;; its parentheses belong together as it is typed (lisp/syntax.lisp):
;;;; each pair in a colour of its own, and while the last character is a
;;;; closing one, a block under the one that opens it, wherever in the
;;;; lines of the form that is. The rows keep those colours with what they
;;;; say.
;;;;
;;;; The pointer highlights what the rows say, from where its left button
;;;; goes down to where it is moved with the button held, and Ctrl-C copies
;;;; that text for every window (CLARA.WINDOWS:CLIPBOARD). Ctrl-V types what
;;;; was copied last, here or in another window, as if on the keyboard.
;;;;
;;;; A line that a listener read here is remembered, for every such window:
;;;; while the next one is typed, the arrow up brings back the line before,
;;;; to be read again or changed first, and the arrow down the one after it
;;;; (HISTORY).
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
  (:export "OPEN-TERMINAL" "TERMINAL-P" "TERMINAL-STREAM" "TERMINAL-WINDOW" "CLEAR" "*ROWS-KEPT*" "HISTORY" "*LINES-KEPT*"
           "REPL"))
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
  tints       ; the cells of that row that are in another colour than the ink: a list of (column . pixel)
  kept        ; what the rows before it say, without the spaces at their ends: a ring of strings,
  tinted      ; and a ring like it of their cells in other colours,
  joined      ; and one that says of each whether its line went on in the row after it,
  (oldest 0)  ; in which the oldest row is at this place,
  (held 0)    ; and which holds so many rows
  (count 0)   ; so many rows were finished since the first: the number of the row that is being written
  (back 0)    ; so many rows before the last ones are what the window shows: Page Up and Page Down
  lock        ; one string is written at a time, and the window shows other rows between two of them
  keys        ; the codes of the characters that were typed and not read yet, the oldest first
  keys-lock
  typed       ; the event that says there are some
  reading     ; a line is being read: the cursor shows, and Ctrl-C gives the line up
  cursor      ; (column . row) of the cursor that is drawn, or NIL when none is
  thread      ; the thread that reads here, which Ctrl-C is for
  stream
  start       ; what is known of the text where the line begins that is being read (CLARA.SYNTAX:SCAN),
  (before 0)  ; and how many characters that text has before the line
  cells       ; where each character of the line was drawn, the last one first: (row . column), the row by its number
  lines       ; the lines of the text that were read before it, the last one first: (line . cells)
  match       ; where the parenthesis was drawn that opens the one typed last, (row . column), or NIL
  hint        ; (column . row) of the hint that is drawn, or NIL when none is
  pressed     ; where the left button of the pointer went down last: (row . column), the row by its number,
  marked)     ; and what is highlighted: (from . to), two such places in the order of the text, or NIL when nothing is

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

;; And which of its cells are in other colours.
(defun kept-tints (terminal place)
  (let ((tinted (terminal-tinted terminal)))
    (aref tinted (mod (+ (terminal-oldest terminal) place) (length tinted)))))

;; And whether the line that it is of went on in the row after it.
(defun kept-joined (terminal place)
  (let ((joined (terminal-joined terminal)))
    (aref joined (mod (+ (terminal-oldest terminal) place) (length joined)))))

;; How many characters STRING has without the spaces at its end.
(defun text-end (string)
  (let ((end (length string)))
    (loop
      (when (or (zerop end) (not (char= (char string (1- end)) #\Space)))
        (return end))
      (setq end (1- end)))))

;; Where, among the rows that are kept, the window's first row is when it
;; shows the last ones: as many rows as that can be gone back.
(defun top (terminal)
  (max 0 (- (1+ (terminal-held terminal)) (terminal-rows terminal))))

;; The row that is being written is finished. What it says is kept, as the
;; newest row, with its cells in other colours, and with whether its line
;; GOES-ON in the row that comes, which a row says that was written to its
;; last cell and was ended by a character more; the oldest go when there are
;; more than may be kept; and the string is blank again for the row that
;; comes.
(defun keep-row (terminal goes-on)
  (let* ((line (terminal-line terminal)) (end (text-end line)) (limit (limit terminal))
         (tints (terminal-tints terminal)))
    (let ((says (if (zerop end) "" (subseq line 0 end))))
      (dotimes (i end)
        (setf (char line i) #\Space))
      (setf (terminal-tints terminal) nil
            (terminal-count terminal) (1+ (terminal-count terminal)))
      (loop
        (when (or (null limit) (< (terminal-held terminal) limit) (zerop (terminal-held terminal)))
          (return))
        ;; Nothing holds on to what the oldest row said.
        (setf (aref (terminal-kept terminal) (terminal-oldest terminal)) ""
              (aref (terminal-tinted terminal) (terminal-oldest terminal)) nil
              (aref (terminal-joined terminal) (terminal-oldest terminal)) nil
              (terminal-oldest terminal) (mod (1+ (terminal-oldest terminal)) (length (terminal-kept terminal)))
              (terminal-held terminal) (1- (terminal-held terminal))))
      (unless (and limit (zerop limit))
        (when (= (terminal-held terminal) (length (terminal-kept terminal)))
          ;; The rings are full: three twice as long, with the oldest row at their start.
          (let ((longer (make-array (* 2 (terminal-held terminal)) :initial-element ""))
                (more (make-array (* 2 (terminal-held terminal)) :initial-element nil))
                (others (make-array (* 2 (terminal-held terminal)) :initial-element nil)))
            (dotimes (i (terminal-held terminal))
              (setf (aref longer i) (kept-row terminal i)
                    (aref more i) (kept-tints terminal i)
                    (aref others i) (kept-joined terminal i)))
            (setf (terminal-kept terminal) longer
                  (terminal-tinted terminal) more
                  (terminal-joined terminal) others
                  (terminal-oldest terminal) 0)))
        (let ((place (mod (+ (terminal-oldest terminal) (terminal-held terminal)) (length (terminal-kept terminal)))))
          (setf (aref (terminal-kept terminal) place) says
                (aref (terminal-tinted terminal) place) tints
                (aref (terminal-joined terminal) place) goes-on
                (terminal-held terminal) (1+ (terminal-held terminal))))))))

;; What the row ROW of the window says, and which of its cells are in other
;; colours: the rows that it shows are the last ones, or the ones that are
;; so many rows before them.
(defun shown-row (terminal row)
  (let ((place (+ (- (top terminal) (terminal-back terminal)) row)) (held (terminal-held terminal)))
    (cond ((< place held) (values (kept-row terminal place) (kept-tints terminal place)))
          ((= place held) (values (terminal-line terminal) (terminal-tints terminal)))
          (t (values "" nil)))))

;;; What is highlighted
;;;
;;; Text that is highlighted stands on another ground than the paper
;;; (CLARA.WINDOWS:HIGHLIGHT): what the rows say from one place to another,
;;; in the order in which they are read. A place is a row and a column, the
;;; row by its number, counted from the first row that there was, so what is
;;; highlighted stays with its rows when they move up, and when the window
;;; shows others. Whatever draws a cell asks GROUND what it stands on.

;; The number of the row that the window shows in its row ROW.
(defun row-number (terminal row)
  (+ (- (terminal-count terminal) (terminal-held terminal)) (- (top terminal) (terminal-back terminal)) row))

;; What the row of that number says, without the spaces at its end, and
;; whether its line goes on in the row after it: two values, or NIL for a
;; row that is not kept any more, or not there yet.
(defun row-says (terminal number)
  (let ((place (- number (- (terminal-count terminal) (terminal-held terminal)))) (held (terminal-held terminal)))
    (cond ((< -1 place held)
           (values (kept-row terminal place) (kept-joined terminal place)))
          ((= place held)
           (let ((line (terminal-line terminal)))
             (values (subseq line 0 (text-end line)) nil))))))

;; STRING with spaces behind it: WIDTH characters at the least.
(defun padded (string width)
  (if (>= (length string) width)
      string
      (concatenate 'string string (make-string (- width (length string)) :initial-element #\Space))))

;; Is the place A before the place B, as the rows are read?
(defun before-p (a b)
  (or (< (car a) (car b))
      (and (= (car a) (car b)) (< (cdr a) (cdr b)))))

;; The cells of the row of that number that are highlighted when MARKED is:
;; (from . to), from the one column to before the other, or NIL when none
;; is. A row is highlighted as far as it says something. Where its line ends
;; within what is highlighted, the cell behind its last character is too,
;; which is how a row with nothing in it shows; and a row whose line goes on
;; in the next is, up to its last cell.
(defun lit (terminal number marked)
  (when (and marked (<= (car (car marked)) number (car (cdr marked))))
    (multiple-value-bind (says joined) (row-says terminal number)
      (when says
        (let* ((columns (terminal-columns terminal))
               (last (= number (car (cdr marked))))
               (end (cond (joined columns)
                          (last (length says))
                          (t (min columns (1+ (length says))))))
               (from (if (= number (car (car marked))) (cdr (car marked)) 0))
               (to (if last (min end (cdr (cdr marked))) end)))
          (and (< from to) (cons from to)))))))

;; The pixel that the cell at COLUMN of the window's row ROW stands on:
;; PAPER, or the highlight's when the cell is highlighted and PAPER is the
;; terminal's own.
(defun ground (terminal column row paper)
  (let ((marked (terminal-marked terminal)))
    (if (and marked (eql paper (terminal-paper terminal)))
        (let ((lit (lit terminal (row-number terminal row) marked)))
          (if (and lit (<= (car lit) column) (< column (cdr lit)))
              (clara.windows:highlight)
              paper))
        paper)))

;; The cell at COLUMN of the row ROW of the window is drawn again, from what
;; the row says there, on PAPER, or on the highlight's ground.
(defun draw-cell (terminal column row paper)
  (multiple-value-bind (says tints) (shown-row terminal row)
    (let ((tint (assoc column tints)))
      (clara.draw:draw-text (terminal-surface terminal) (* column clara.font:+width+) (* row clara.font:+height+)
                            (if (< column (length says)) (string (char says column)) " ")
                            (if tint (cdr tint) (terminal-ink terminal)) (ground terminal column row paper)))))

;; The row ROW of the window is drawn again, from what it says and in the
;; colours that it says it in, with what is highlighted of it on that
;; ground.
(defun draw-row (terminal row)
  (let ((surface (terminal-surface terminal)) (y (* row clara.font:+height+))
        (ink (terminal-ink terminal)) (paper (terminal-paper terminal))
        (marked (terminal-marked terminal)))
    (clara.draw:fill-rectangle surface 0 y (* (terminal-columns terminal) clara.font:+width+) clara.font:+height+ paper)
    (multiple-value-bind (says tints) (shown-row terminal row)
      (when (plusp (length says))
        (clara.draw:draw-text surface 0 y says ink paper))
      (let ((lit (and marked (lit terminal (row-number terminal row) marked))))
        (when lit
          (clara.draw:draw-text surface (* (car lit) clara.font:+width+) y
                                (subseq (padded says (cdr lit)) (car lit) (cdr lit)) ink (clara.windows:highlight))))
      (dolist (tint tints)
        (draw-cell terminal (car tint) row paper)))))

;; What the window shows is drawn again, from what its rows say and in the
;; colours that they say it in: the last ones, or the ones that are so many
;; rows before them.
(defun repaint (terminal)
  (dotimes (row (terminal-rows terminal))
    (draw-row terminal row)))

;;; Writing
;;;
;;; What is written goes to the last row, whatever the window shows. While
;;; it shows the last rows, each character is drawn as it comes. While it
;;; shows rows from further back, nothing is drawn: the rows that it shows
;;; stay, one row further back with every row that is finished, until the
;;; oldest of them is no longer kept.

;; A new row, which the line of the row before GOES-ON in, or which begins
;; another. Past the last one, every row moves up by one, and the last is
;; blank.
(defun new-row (terminal &optional goes-on)
  (setf (terminal-column terminal) 0)
  (keep-row terminal goes-on)
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

;; The cells of the row that is being written from COLUMN to before AFTER
;; were drawn on paper: the ones of them that are highlighted are drawn
;; again.
(defun relight (terminal column after)
  (let ((lit (lit terminal (terminal-count terminal) (terminal-marked terminal))))
    (when lit
      (do ((at (max column (car lit)) (1+ at)))
          ((>= at (min after (cdr lit))))
        (draw-cell terminal at (terminal-row terminal) (terminal-paper terminal))))))

;; The characters of STRING from START to END, which the row has room for,
;; where the next character goes: in the terminal's ink, or in INK, which
;; the row then remembers of those cells.
(defun put (terminal string start end &optional ink)
  (let* ((line (terminal-line terminal)) (column (terminal-column terminal)) (after (+ column (- end start)))
         (tints (terminal-tints terminal)))
    (dotimes (i (- end start))
      (setf (char line (+ column i)) (char string (+ start i))))
    (when tints
      (setq tints (remove-if (lambda (tint) (and (>= (car tint) column) (< (car tint) after))) tints)))
    (when ink
      (dotimes (i (- end start))
        (setq tints (cons (cons (+ column i) ink) tints))))
    (setf (terminal-tints terminal) tints)
    (when (zerop (terminal-back terminal))
      (clara.draw:draw-text (terminal-surface terminal)
                            (* column clara.font:+width+)
                            (* (terminal-row terminal) clara.font:+height+)
                            (subseq string start end) (or ink (terminal-ink terminal)) (terminal-paper terminal))
      (when (terminal-marked terminal)
        (relight terminal column after)))
    (setf (terminal-column terminal) after)))

;; A tab: spaces up to the next column that is a multiple of eight.
(defun tab (terminal)
  (loop
    (when (= (terminal-column terminal) (terminal-columns terminal))
      (new-row terminal t))
    (put terminal " " 0 1)
    (when (or (zerop (mod (terminal-column terminal) 8))
              (= (terminal-column terminal) (terminal-columns terminal)))
      (return))))

;; The four characters that move the place of the next one and draw nothing.
(defun moves-p (code)
  (or (= code 10) (= code 13) (= code 8) (= code 9)))

;; While a line is being read, a bar under the cell where the next
;; character goes says where that is, as on the console: the lowest two
;; rows of the cell's pixels. And while the last character of the line is a
;; closing parenthesis, the one that opens it has a block under it, the
;; hint, when the window shows the row that it is in. Both are taken away
;; before anything is drawn and put back after, and a window that shows
;; rows from further back has neither.
(defun paint-cursor (terminal column row pixel)
  (clara.draw:fill-rectangle (terminal-surface terminal) (* column clara.font:+width+)
                             (- (* (1+ row) clara.font:+height+) 2) clara.font:+width+ 2 pixel))

(defun hide-cursor (terminal)
  (let ((cursor (terminal-cursor terminal)) (hint (terminal-hint terminal)))
    (when cursor
      (paint-cursor terminal (car cursor) (cdr cursor)
                    (ground terminal (car cursor) (cdr cursor) (terminal-paper terminal)))
      (setf (terminal-cursor terminal) nil))
    (when hint
      (draw-cell terminal (car hint) (cdr hint) (terminal-paper terminal))
      (setf (terminal-hint terminal) nil))))

(defun show-cursor (terminal)
  (when (and (terminal-reading terminal) (zerop (terminal-back terminal)))
    (when (< (terminal-column terminal) (terminal-columns terminal))
      (setf (terminal-cursor terminal) (cons (terminal-column terminal) (terminal-row terminal)))
      (paint-cursor terminal (terminal-column terminal) (terminal-row terminal) (terminal-ink terminal)))
    (let ((match (terminal-match terminal)) (shade (clara.syntax:hint)))
      (when (and match shade)
        ;; The row of the window that the row of that number is in, when it is in one,
        ;; and it still says there what was typed.
        (let ((row (- (terminal-row terminal) (- (terminal-count terminal) (car match)))) (column (cdr match)))
          (when (and (<= 0 row (terminal-row terminal)) (< column (terminal-columns terminal))
                     (let ((says (shown-row terminal row)))
                       (and (< column (length says)) (char= (char says column) #\())))
            (draw-cell terminal column row shade)
            (setf (terminal-hint terminal) (cons column row))))))))

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
                   (new-row terminal t))
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
;; is kept: there is nothing to go back to, no parenthesis to point at, and
;; nothing that is highlighted.
(defun clear (terminal)
  (clara:with-lock-held ((terminal-lock terminal))
    (clara.draw:fill-rectangle (terminal-surface terminal) 0 0
                               (* (terminal-columns terminal) clara.font:+width+)
                               (* (terminal-rows terminal) clara.font:+height+) (terminal-paper terminal))
    (dotimes (i (terminal-columns terminal))
      (setf (char (terminal-line terminal) i) #\Space))
    (setf (terminal-cursor terminal) nil
          (terminal-hint terminal) nil
          (terminal-column terminal) 0
          (terminal-row terminal) 0
          (terminal-tints terminal) nil
          (terminal-kept terminal) (make-array +ring+ :initial-element "")
          (terminal-tinted terminal) (make-array +ring+ :initial-element nil)
          (terminal-joined terminal) (make-array +ring+ :initial-element nil)
          (terminal-oldest terminal) 0
          (terminal-held terminal) 0
          (terminal-count terminal) 0
          (terminal-back terminal) 0
          (terminal-pressed terminal) nil
          (terminal-marked terminal) nil
          ;; Where what was typed was drawn is nowhere now.
          (terminal-cells terminal) nil
          (terminal-lines terminal) nil
          (terminal-match terminal) nil)
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

;;; Highlighting, copying and pasting
;;;
;;; The left button of the pointer goes down at a place of the window, and
;;; the text from there to where the pointer is moved with the button held
;;; is highlighted: a cell counts when the pointer has passed its middle.
;;; The window is told both in the thread of the mouse, and the rows are
;;; drawn there, for the reason that Page Up has: the thread that reads may
;;; be computing. Those two keys work while the button is held, so what is
;;; highlighted can be more than a window holds. A click takes the
;;; highlight away again.
;;;
;;; Ctrl-C copies what is highlighted, and so does Ctrl-X, since nothing
;;; that a window has written can be taken out of it: the text is what was
;;; copied last, for every window (CLARA.WINDOWS:CLIPBOARD), and is
;;; highlighted no longer, so that the next Ctrl-C is the one that stops
;;; what is computing. Ctrl-V types what was copied last.

;; What is highlighted is MARKED from now on, two places in the order of
;; the text, or nothing at all: the rows of the window whose highlighted
;; cells are other ones then are drawn again, and shown.
(defun mark (terminal marked)
  (unless (equal marked (terminal-marked terminal))
    (let ((before nil))
      (dotimes (row (terminal-rows terminal))
        (setq before (cons (lit terminal (row-number terminal row) (terminal-marked terminal)) before)))
      (setq before (nreverse before))
      (hide-cursor terminal)
      (setf (terminal-marked terminal) marked)
      (dotimes (row (terminal-rows terminal))
        (unless (equal (car before) (lit terminal (row-number terminal row) marked))
          (draw-row terminal row))
        (setq before (cdr before)))
      (show-cursor terminal)
      (clara.windows:show (terminal-window terminal)))))

;; What is highlighted, as text: what its rows say, with a new line after
;; each but the last, and none after a row whose line goes on in the next.
(defun marked-text (terminal)
  (let* ((marked (terminal-marked terminal)) (first (car (car marked))) (last (car (cdr marked))))
    (with-output-to-string (out)
      (do ((number first (1+ number)))
          ((> number last))
        (multiple-value-bind (says joined) (row-says terminal number)
          (when says
            (let* ((says (if joined (padded says (terminal-columns terminal)) says))
                   (from (if (= number first) (min (cdr (car marked)) (length says)) 0))
                   (to (if (= number last) (min (cdr (cdr marked)) (length says)) (length says))))
              (when (< from to)
                (write-string (subseq says from to) out))
              (unless (or joined (= number last))
                (write-char #\Newline out)))))))))

;; Ctrl-C and Ctrl-X: what is highlighted is the text that was copied last,
;; and is highlighted no longer. True when something was highlighted.
(defun copy (terminal)
  (clara:with-lock-held ((terminal-lock terminal))
    (when (terminal-marked terminal)
      (let ((text (marked-text terminal)))
        (when (plusp (length text))
          (setf (clara.windows:clipboard) text)))
      (mark terminal nil)
      t)))

;; Ctrl-V: what was copied last is typed, all of it, however long it is:
;; its characters, the ends of its lines, and a tab as one. So each line of
;; it that is whole is read as it stands, and its last, which has no end,
;; waits for Enter.
(defun paste (terminal)
  (let ((text (clara.windows:clipboard)) (codes nil))
    (dotimes (i (length text))
      (let ((code (char-code (char text i))))
        (when (or (= code 10) (= code 9) (and (>= code 32) (/= code 127)))
          (setq codes (cons code codes)))))
    (when codes
      (clara:with-lock-held ((terminal-keys-lock terminal))
        (setf (terminal-keys terminal) (append (terminal-keys terminal) (nreverse codes))))
      (clara:signal-event (terminal-typed terminal)))))

;; Where in the rows a place of the window is: (row . column), the row by
;; its number, and the column that the place is nearest to the left edge
;; of. A place under the last row that there is, is the end of that row.
(defun cell-at (terminal x y)
  (let* ((row (max 0 (min (1- (terminal-rows terminal)) (floor y clara.font:+height+))))
         (column (max 0 (min (terminal-columns terminal)
                             (floor (+ x (floor clara.font:+width+ 2)) clara.font:+width+))))
         (number (row-number terminal row)))
    (if (> number (terminal-count terminal))
        (cons (terminal-count terminal) (terminal-columns terminal))
        (cons number column))))

;; A button of the pointer went down or up in the window: with the left one
;; down, nothing is highlighted any more, and what is highlighted next
;; begins here.
(defun pointed (terminal x y buttons)
  (when (= 1 (logand buttons 1))
    (clara:with-lock-held ((terminal-lock terminal))
      (mark terminal nil)
      (setf (terminal-pressed terminal) (cell-at terminal x y)))))

;; And the pointer was moved with that button held: the text from where it
;; went down to where the pointer is now is highlighted, whichever of the
;; two comes first. Within one row that is text only where the row says
;; something.
(defun dragged (terminal x y buttons)
  (when (= 1 (logand buttons 1))
    (clara:with-lock-held ((terminal-lock terminal))
      (let ((pressed (terminal-pressed terminal)) (at (cell-at terminal x y)))
        (when pressed
          (let ((marked (cond ((before-p pressed at) (cons pressed at))
                              ((before-p at pressed) (cons at pressed)))))
            (when (and marked (= (car (car marked)) (car (cdr marked)))
                       (null (lit terminal (car (car marked)) marked)))
              (setq marked nil))
            (mark terminal marked)))))))

;;; Reading
;;;
;;; The window manager hands in the characters that are typed while the
;;; window has the focus, KEY-TYPED, in the thread of the keyboard. They
;;; wait here for the thread that reads lines. Ctrl-C is the exception. A
;;; thread that is reading a line gets it as a character, which gives the
;;; line up. A thread that is not is computing, or about to, a line that
;;; ends being as good as read: what it does is stopped
;;; (CLARA:INTERRUPT-THREAD), and whatever was typed ahead is forgotten.
;;; Page Up and Page Down are not handed on at all (SCROLL), and neither
;;; are Ctrl-C and Ctrl-X while something is highlighted (COPY), nor Ctrl-V
;;; (PASTE), which hands on what was copied in its place. Any other key
;;; brings the last rows back first, where what it types is echoed.

(defun key-typed (terminal code)
  (let ((page (max 1 (1- (terminal-rows terminal)))))
    (cond ((= code clara.input:+page-up+)
           (scroll terminal page))
          ((= code clara.input:+page-down+)
           (scroll terminal (- page)))
          ((and (or (= code 3) (= code 24)) (copy terminal)))
          (t
           (when (plusp (terminal-back terminal))
             (scroll terminal nil))
           (if (= code 22)
               (paste terminal)
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
                     (clara:signal-event (terminal-typed terminal))))))))
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

;;; What is typed
;;;
;;; A line that is read is echoed here and not by writing to the stream,
;;; because its parentheses have colours (lisp/syntax.lisp). Which colour
;;; one has, and which one opens it, is a matter of the whole text that it
;;; is in, and a form is often more lines than one: the listener says what
;;; the line goes on from (CLARA.LISTENER:*BEGUN*), and the terminal
;;; remembers where it drew every character of the lines that it read, for
;;; as long as the listener still has them to make something of. The row
;;; of a character is remembered by its number, counted from the first row
;;; that there was, since the rows of a window move up.

;; A line is about to be read. The text that it goes on from is gone
;; through for what its parentheses leave open, and of the lines that were
;; read here before, the last ones are remembered, as many as that text is
;; made of. A line that goes on from nothing the listener knows of, some
;; program's, leaves those lines be: the listener may go on from them yet.
(defun begin (terminal)
  (let ((begun clara.listener:*begun*) (lines nil))
    (clara:with-lock-held ((terminal-lock terminal))
      (when (stringp begun)
        (let ((more (length begun)))
          (dolist (entry (terminal-lines terminal))
            (unless (plusp more)
              (return))
            (setq lines (cons entry lines)
                  more (- more (length (car entry)) 1))))
        (setf (terminal-lines terminal) (nreverse lines)))
      (setf (terminal-before terminal) (if (stringp begun) (length begun) 0)
            (terminal-start terminal) (and (stringp begun) (clara.syntax:scan begun nil :before nil))
            (terminal-cells terminal) nil
            (terminal-match terminal) nil))))

;; Where the opening parenthesis was drawn that CLARA.SYNTAX:SCAN remembers
;; as OPEN: one of LINE, the line that is being read, or one of the text
;; before it. NIL when that is not remembered.
(defun place (terminal line open)
  (let ((index (cdr open)))
    (if (eq (car open) :line)
        (nth (- (length line) 1 index) (terminal-cells terminal))
        (let ((end (terminal-before terminal)))
          (dolist (entry (terminal-lines terminal))
            (let* ((length (length (car entry))) (start (- end length 1)))
              (when (>= index start)
                (return (and (< (- index start) length)
                             (nth (- length 1 (- index start)) (cdr entry)))))
              (setq end start)))))))

;; The reverse of NEW-ROW: the row that was finished last is the one that
;; is being written again, with what it said. In a window that was full,
;; every row that it shows moves down by one. Where the next character
;; goes is for whoever asks to say.
(defun old-row (terminal)
  (let* ((held (1- (terminal-held terminal)))
         (kept (terminal-kept terminal))
         (place (mod (+ (terminal-oldest terminal) held) (length kept)))
         (says (aref kept place))
         (line (terminal-line terminal)))
    (dotimes (i (terminal-columns terminal))
      (setf (char line i) (if (< i (length says)) (char says i) #\Space)))
    (setf (terminal-tints terminal) (aref (terminal-tinted terminal) place)
          (aref kept place) ""
          (aref (terminal-tinted terminal) place) nil
          (aref (terminal-joined terminal) place) nil
          (terminal-held terminal) held
          (terminal-count terminal) (1- (terminal-count terminal)))
    (cond ((< held (1- (terminal-rows terminal)))
           (clara.draw:fill-rectangle (terminal-surface terminal) 0 (* (terminal-row terminal) clara.font:+height+)
                                      (* (terminal-columns terminal) clara.font:+width+) clara.font:+height+
                                      (terminal-paper terminal))
           (setf (terminal-row terminal) (1- (terminal-row terminal))))
          ((plusp (terminal-back terminal))
           (setf (terminal-back terminal) (1- (terminal-back terminal))))
          (t
           (repaint terminal)))))

;; The character that was drawn last of the line that is being read is
;; taken back: its cell is blank, and the next character goes there. From
;; the start of a row that is the last cell of the row above, which a line
;; that is longer than a row has gone on from.
(defun take-back (terminal)
  (let ((cell (car (terminal-cells terminal))))
    (setf (terminal-cells terminal) (cdr (terminal-cells terminal)))
    (when cell
      (when (and (= (car cell) (1- (terminal-count terminal))) (zerop (terminal-column terminal))
                 (plusp (terminal-held terminal)))
        (old-row terminal))
      (when (and (= (car cell) (terminal-count terminal)) (< (cdr cell) (terminal-columns terminal)))
        (setf (terminal-column terminal) (cdr cell))
        (put terminal " " 0 1)
        (setf (terminal-column terminal) (cdr cell))))))

;; The line that is being read is LINE now: it has gained CHARACTER, which
;; is drawn where the next character goes, a parenthesis that counts in the
;; colour of its pair; or it has lost its last character, when that is NIL.
;; Either way the hint is for the character that is its last now.
(defun echo (terminal line character)
  (clara:with-lock-held ((terminal-lock terminal))
    (hide-cursor terminal)
    (let ((index nil) (level nil) (open nil))
      (clara.syntax:scan line (terminal-start terminal) :line
                         (lambda (at depth opening)
                           (setq index at
                                 level depth
                                 open opening)))
      ;; Is its last character a parenthesis that counts?
      (let ((last (and index (= index (1- (length line))))))
        (cond (character
               (when (= (terminal-column terminal) (terminal-columns terminal))
                 (new-row terminal t))
               (setf (terminal-cells terminal)
                     (cons (cons (terminal-count terminal) (terminal-column terminal)) (terminal-cells terminal)))
               (put terminal (string character) 0 1 (and last (clara.syntax:color level))))
              (t
               (take-back terminal)))
        (setf (terminal-match terminal) (and last open (place terminal line open)))))
    (show-cursor terminal)
    (clara.windows:show (terminal-window terminal))))

;;; What was typed before
;;;
;;; The lines that a listener read in a window are remembered, the newest
;;; first, in one list for all the windows: they are prompts of the one
;;; world, so a line that was typed in one comes back in the next, and in a
;;; window that is opened when the first is long closed. While a listener's
;;; line is read, the arrow up puts the line before it in its place, and
;;; the arrow down the line after it, down to the one that was being typed.
;;; A line that the arrows have left is left as it stands, with what was
;;; typed into it, until the reading is over: only the line that is read in
;;; the end is remembered, as the newest. A line that some program reads is
;;; not remembered, and the arrows mean nothing while it is typed.

;; How many lines are remembered, the newest of them: a number, or NIL for
;; all of them, which is also what a value that is no number of lines comes
;; to. The lines are held to it whenever one is remembered.
(defvar *lines-kept* 1000)

(defvar *history* nil)                              ; the lines, the newest first: HISTORY
(defvar *history-lock* (clara:make-lock "history")) ; two windows may each have read a line

;; The first of LINES, as many as may be remembered.
(defun newest (lines)
  (let ((kept *lines-kept*))
    (if (and (integerp kept) (>= kept 0) (> (length lines) kept))
        (subseq lines 0 kept)
        lines)))

;; The lines that are remembered, the newest first, in a list that is the
;; caller's own. (SETF (HISTORY) lines) makes LINES those lines, and with
;; NIL there are none.
(defun history ()
  (copy-list *history*))

(defun set-history (lines)
  (let ((rest lines))
    (loop
      (when (null rest)
        (return))
      (unless (and (consp rest) (stringp (car rest)))
        (error "the lines that were typed before are a list of strings, and ~S is not one" lines))
      (setq rest (cdr rest))))
  (clara:with-lock-held (*history-lock*)
    (setq *history* (newest (copy-list lines))))
  lines)

(defsetf history set-history)

;; LINE was read by a listener, and is the newest of the lines from now
;; on: unless it says nothing, or is what the line before it was.
(defun remember (line)
  (when (plusp (text-end line))
    (clara:with-lock-held (*history-lock*)
      (unless (equal line (car *history*))
        (setq *history* (newest (cons line *history*)))))))

;; The next line that was typed, without its end, or NIL when no more is
;; coming, which is what Ctrl-D at the start of a line says. The cursor
;; shows for as long, and Ctrl-C is from now on for the thread that reads.
(defun read-text-line (terminal)
  (setf (terminal-thread terminal) (clara:current-thread)
        (terminal-reading terminal) t)
  (begin terminal)
  (cursor-shows terminal)
  (unwind-protect
       (let* ((listening (stringp clara.listener:*begun*))
              (asked nil)   ; an arrow has asked for the lines: they are the ones that there were then
              (older nil)   ; the lines before the one that the window shows, the newest first,
              (newer nil)   ; and the ones after it, the nearest first: what the arrows have left, as it was left
              (line (clara.console:read-edited-line
                     (lambda () (next-code terminal)) (terminal-stream terminal)
                     (lambda (line character) (echo terminal line character))
                     (and listening
                          (lambda (code typed)
                            (cond ((= code clara.input:+up+)
                                   (unless asked
                                     (setq older *history*
                                           asked t))
                                   (when older
                                     (push typed newer)
                                     (pop older)))
                                  ((and (= code clara.input:+down+) newer)
                                   (push typed older)
                                   (pop newer))))))))
         ;; A line of the listener's is one that the next may go on from, and that the arrows bring back.
         (when (and line listening)
           (clara:with-lock-held ((terminal-lock terminal))
             (setf (terminal-lines terminal) (cons (cons line (terminal-cells terminal)) (terminal-lines terminal))))
           (remember line))
         line)
    (setf (terminal-reading terminal) nil
          (terminal-match terminal) nil)
    (cursor-shows terminal)))

;;; A terminal

;; A window of COLUMNS by ROWS cells with that title, and the terminal in
;; it, whose stream is TERMINAL-STREAM. The window is the thread's that
;; opens it, like any other (CLARA.WINDOWS:OPEN-WINDOW, which X, Y and
;; CLOSE are for). What is typed in it is the stream's to give back, but for
;; Page Up and Page Down, and for the keys that copy; and the pointer
;; highlights what its rows say.
(defun open-terminal (title &key (columns 80) (rows 24) x y close)
  (unless (and (integerp columns) (integerp rows) (plusp columns) (plusp rows))
    (error "a terminal has a number of columns and of rows, and ~S by ~S are not that" columns rows))
  (let* ((terminal (make-terminal :columns columns :rows rows
                                  :line (make-string columns :initial-element #\Space)
                                  :kept (make-array +ring+ :initial-element "")
                                  :tinted (make-array +ring+ :initial-element nil)
                                  :joined (make-array +ring+ :initial-element nil)
                                  :ink (clara.draw:color 232 227 244) :paper (clara.draw:color 30 27 46)
                                  :lock (clara:make-lock "terminal") :keys-lock (clara:make-lock "keys")
                                  :typed (clara:make-event "typed")))
         (window (clara.windows:open-window title (* columns clara.font:+width+) (* rows clara.font:+height+)
                                            :x x :y y :close close
                                            :key (lambda (code) (key-typed terminal code))
                                            :pointer (lambda (x y buttons) (pointed terminal x y buttons))
                                            :drag (lambda (x y buttons) (dragged terminal x y buttons)))))
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
