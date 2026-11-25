;;;; emma.lisp: Emma, a text editor
;;;;
;;;; An application (lisp/windows.lisp): a window of cells with the lines of
;;;; a text in it, a cursor where what is typed goes in, and a row below the
;;;; text that says which file it is and where the cursor is. The text is
;;;; that of a file, read whole and written whole (OPEN, in lisp/boot.lisp),
;;;; or of no file yet. The arrows, Home, End, Page Up and Page Down move
;;;; the cursor, and so does a click; Enter, Backspace and Delete do what
;;;; they say; and with Ctrl held, S saves, O opens another file, K cuts to
;;;; the end of the line and Y puts back what was cut, E evaluates the text
;;;; as LOAD would, and Q closes the window, as its close box does. The
;;;; pointer, moved with its left button held, highlights text, which Ctrl-X
;;;; cuts, Ctrl-C copies, and what is typed takes the place of; Ctrl-V puts
;;;; in what was cut or copied last, in this window or in any other
;;;; (CLARA.WINDOWS:CLIPBOARD).
;;;;
;;;; The text is kept as its lines, around the one that the cursor is in:
;;;; the lines above it, the nearest first, the line itself, and the lines
;;;; below. A character that is typed makes a new string of one line, and a
;;;; new line or a line that goes is a cons at the cursor, however long the
;;;; text is.
;;;;
;;;; What the window shows is drawn a row at a time, and only the rows that
;;;; no longer show what they should: the editor remembers what it drew in
;;;; each. When the text moves up or down, the rows that stay are copied.
;;;;
;;;; A text is Lisp more often than not, so the window shows which of its
;;;; parentheses belong together (lisp/syntax.lisp): each pair in a colour
;;;; of its own, and while the cursor stands behind a closing one, a block
;;;; under the one that opens it.
;;;;
;;;; This file is not part of the world that the kernel loads. The launcher
;;;; loads it when Emma is first picked, and CLARA.WINDOWS:UNLOAD-APPLICATION
;;;; takes it out again. It loads under SBCL as well, where lisp/host/
;;;; stands in for the machine.

(defpackage "CLARA.EMMA"
  (:use "COMMON-LISP")
  (:export "EDIT"))
(in-package "CLARA.EMMA")

(defstruct editor
  window
  surface      ; what its window is drawn on
  font         ; what the text is written in: one of CLARA.TYPE:FONT's, or NIL for the console's letters
  wide         ; the size of a cell of that, in pixels
  high
  columns      ; the size of the text's part of the window, in cells:
  rows         ;   the window has one row more, below it, for the status
  ink          ; the pixel of a glyph,
  paper        ; and the pixel around it; the status row has the two the other way round
  name         ; of the file that the text is of, or NIL while it has none
  above        ; the lines above the cursor's, the nearest first
  (line "")    ; the line that the cursor is in
  below        ; the lines below it, in order
  (row 0)      ; the number of the cursor's line, from 0: as many as there are above
  (column 0)   ; where in its line the cursor is: before the character of that number
  (top 0)      ; the number of the line in the window's first row,
  (left 0)     ;   and of the column in the first cell of a row
  shown        ; what each row of the window shows, as it was drawn, or NIL for a row to draw again: its text,
               ;   and after that its cells that are not ink on paper, each (column ink) or (column ink paper)
  paints       ; such cells of each row of the text, for the drawing that is under way
  known        ; the lines above the cursor's that STATES is about: ABOVE, as it was when the window was drawn last,
  states       ;   and what is known of the text at the end of each of them (CLARA.SYNTAX:SCAN), the nearest first
  cursor       ; the row of the window that the cursor is drawn in, or NIL
  changed      ; the text is not what the file holds
  message      ; words for the status row, until the next key
  asking       ; a question in the status row: (words . a function of the answer), or NIL
  (answer "")  ; what was typed to it so far
  cut          ; what Ctrl-K took last: it is what was cut last, CLARA.WINDOWS:CLIPBOARD, until something else is
  cutting      ; the key before this one was Ctrl-K: what the next takes is added
  pressed      ; where the left button of the pointer went down last: (row . column), between two characters of the text
  mark         ; where what is highlighted began, (row . column): it is the text from there to the cursor. NIL when nothing is
  sure         ; the key that was refused because the text is not saved: typed once more, it is obeyed
  done)        ; the window is to close

;;; Strings of the width of a row

(defvar *blank* "        ")

;; So many spaces.
(defun blank (count)
  (loop
    (when (>= (length *blank*) count)
      (return))
    (setq *blank* (concatenate 'string *blank* *blank*)))
  (subseq *blank* 0 count))

;; STRING, cut or made longer with spaces: WIDTH characters exactly.
(defun fit (string width)
  (if (>= (length string) width)
      (subseq string 0 width)
      (concatenate 'string string (blank (- width (length string))))))

;;; The text

;; STRING, which has no new line in it, goes in at the cursor.
(defun insert (editor string)
  (let ((line (editor-line editor)) (column (editor-column editor)))
    (setf (editor-line editor) (concatenate 'string (subseq line 0 column) string (subseq line column))
          (editor-column editor) (+ column (length string))
          (editor-changed editor) t)))

;; A new line begins at the cursor.
(defun break-line (editor)
  (let ((line (editor-line editor)) (column (editor-column editor)))
    (setf (editor-above editor) (cons (subseq line 0 column) (editor-above editor))
          (editor-line editor) (subseq line column)
          (editor-row editor) (1+ (editor-row editor))
          (editor-column editor) 0
          (editor-changed editor) t)))

;; A text that may have new lines in it.
(defun insert-text (editor text)
  (let ((start 0))
    (dotimes (i (length text))
      (when (char= (char text i) #\Newline)
        (insert editor (subseq text start i))
        (break-line editor)
        (setq start (1+ i))))
    (insert editor (subseq text start))))

;; How many spaces LINE begins with, up to LIMIT.
(defun indentation (line limit)
  (let ((count 0))
    (loop
      (unless (and (< count limit) (char= (char line count) #\Space))
        (return count))
      (setq count (1+ count)))))

;; Enter: a new line, which begins as far in as the one that it comes from.
(defun enter (editor)
  (let ((indent (indentation (editor-line editor) (editor-column editor))))
    (break-line editor)
    (insert editor (blank indent))))

;; The cursor goes a line up, or down, and says whether there was one.
(defun up (editor)
  (when (editor-above editor)
    (setf (editor-below editor) (cons (editor-line editor) (editor-below editor))
          (editor-line editor) (car (editor-above editor))
          (editor-above editor) (cdr (editor-above editor))
          (editor-row editor) (1- (editor-row editor))
          (editor-column editor) (min (editor-column editor) (length (editor-line editor))))
    t))

(defun down (editor)
  (when (editor-below editor)
    (setf (editor-above editor) (cons (editor-line editor) (editor-above editor))
          (editor-line editor) (car (editor-below editor))
          (editor-below editor) (cdr (editor-below editor))
          (editor-row editor) (1+ (editor-row editor))
          (editor-column editor) (min (editor-column editor) (length (editor-line editor))))
    t))

;; A character back, to the end of the line above from the start of one;
;; and a character on.
(defun back (editor)
  (cond ((plusp (editor-column editor))
         (setf (editor-column editor) (1- (editor-column editor))))
        ((up editor)
         (setf (editor-column editor) (length (editor-line editor))))))

(defun forth (editor)
  (cond ((< (editor-column editor) (length (editor-line editor)))
         (setf (editor-column editor) (1+ (editor-column editor))))
        ((down editor)
         (setf (editor-column editor) 0))))

;; The cursor goes to the line of that number, or as near as there is one,
;; and to that column of it, or to its end.
(defun go-to (editor row column)
  (loop
    (unless (and (> (editor-row editor) row) (up editor))
      (return)))
  (loop
    (unless (and (< (editor-row editor) row) (down editor))
      (return)))
  (setf (editor-column editor) (max 0 (min column (length (editor-line editor))))))

;; Backspace: the character before the cursor goes, or at the start of a
;; line the end of the line above, and the two are one.
(defun rub-out (editor)
  (let ((line (editor-line editor)) (column (editor-column editor)))
    (cond ((plusp column)
           (setf (editor-line editor) (concatenate 'string (subseq line 0 (1- column)) (subseq line column))
                 (editor-column editor) (1- column)
                 (editor-changed editor) t))
          ((editor-above editor)
           (let ((before (car (editor-above editor))))
             (setf (editor-above editor) (cdr (editor-above editor))
                   (editor-line editor) (concatenate 'string before line)
                   (editor-row editor) (1- (editor-row editor))
                   (editor-column editor) (length before)
                   (editor-changed editor) t))))))

;; Delete: the character at the cursor goes, or the end of the line.
(defun take-out (editor)
  (let ((line (editor-line editor)) (column (editor-column editor)))
    (cond ((< column (length line))
           (setf (editor-line editor) (concatenate 'string (subseq line 0 column) (subseq line (1+ column)))
                 (editor-changed editor) t))
          ((editor-below editor)
           (setf (editor-line editor) (concatenate 'string line (car (editor-below editor)))
                 (editor-below editor) (cdr (editor-below editor))
                 (editor-changed editor) t)))))

;; Ctrl-K: the rest of the line goes, or at its end the end itself, and is
;; what was cut last, for Ctrl-Y and Ctrl-V, here and in every other window;
;; MORE says that it comes after what the key took before, and it is added
;; to that unless something else was cut or copied since. At the end of the
;; text there is nothing to take, and what was cut last stays.
(defun cut-line (editor more)
  (let* ((line (editor-line editor)) (column (editor-column editor))
         (taken (cond ((< column (length line)) (subseq line column))
                      ((editor-below editor) (string #\Newline)))))
    (when taken
      (if (< column (length line))
          (setf (editor-line editor) (subseq line 0 column)
                (editor-changed editor) t)
          (take-out editor))
      (let ((cut (if (and more (eq (editor-cut editor) (clara.windows:clipboard)))
                     (concatenate 'string (editor-cut editor) taken)
                     taken)))
        (setf (editor-cut editor) cut
              (clara.windows:clipboard) cut
              (editor-cutting editor) t)))))

;; Every line of the text, in order, in a list of its own.
(defun all-lines (editor)
  (append (reverse (editor-above editor)) (cons (editor-line editor) (editor-below editor))))

;;; What is highlighted
;;;
;;; The text from the mark to the cursor, whichever of the two comes first.
;;; The mark is set where the left button of the pointer went down, once
;;; the pointer is moved with the button held, and the cursor goes where the
;;; pointer goes (POINT, DRAG). What is highlighted can be cut, copied, and
;;; typed over; a key that moves the cursor takes the highlight away.

;; Is the place A before the place B in the text? Each is (row . column).
(defun before-p (a b)
  (or (< (car a) (car b))
      (and (= (car a) (car b)) (< (cdr a) (cdr b)))))

;; The two ends of what is highlighted, in the order of the text: two
;; values, each (row . column), or NIL when nothing is.
(defun marked (editor)
  (let ((mark (editor-mark editor)) (cursor (cons (editor-row editor) (editor-column editor))))
    (cond ((null mark) nil)
          ((before-p mark cursor) (values mark cursor))
          ((before-p cursor mark) (values cursor mark)))))

;; The text from the place FROM to the place TO, with a new line where a
;; line ends.
(defun text-between (editor from to)
  (let ((lines (nthcdr (car from) (all-lines editor))))
    (if (= (car from) (car to))
        (subseq (car lines) (cdr from) (cdr to))
        (with-output-to-string (out)
          (write-line (subseq (car lines) (cdr from)) out)
          (setq lines (cdr lines))
          (dotimes (i (- (car to) (car from) 1))
            (write-line (car lines) out)
            (setq lines (cdr lines)))
          (write-string (subseq (car lines) 0 (cdr to)) out)))))

;; What is highlighted goes, and the cursor is where it was. The text that
;; went, or NIL when nothing was highlighted.
(defun take-marked (editor)
  (multiple-value-bind (from to) (marked editor)
    (setf (editor-mark editor) nil)
    (when from
      (let ((text (text-between editor from to)))
        (go-to editor (car to) (cdr to))
        ;; What is behind it in its last line stays, behind what is before it in its first.
        (let ((behind (subseq (editor-line editor) (cdr to))))
          (dotimes (i (- (car to) (car from)))
            (setf (editor-line editor) (car (editor-above editor))
                  (editor-above editor) (cdr (editor-above editor))
                  (editor-row editor) (1- (editor-row editor))))
          (setf (editor-line editor) (concatenate 'string (subseq (editor-line editor) 0 (cdr from)) behind)
                (editor-column editor) (cdr from)
                (editor-changed editor) t))
        text))))

;; Ctrl-C: what is highlighted is the text that was copied last, for Ctrl-V
;; to put in, here and in every other window. NIL when nothing is
;; highlighted, which the status row then says.
(defun copy (editor)
  (multiple-value-bind (from to) (marked editor)
    (if from
        (setf (clara.windows:clipboard) (text-between editor from to))
        (progn
          (setf (editor-message editor) "nothing is highlighted: the pointer does that, moved with its button held")
          nil))))

;; Ctrl-V, and Ctrl-Y: what was cut or copied last goes in at the cursor, in
;; the place of what is highlighted.
(defun paste (editor)
  (let ((text (clara.windows:clipboard)))
    (when (plusp (length text))
      (take-marked editor)
      (insert-text editor text))))

;;; Files

;; What the window of a text is called: Emma, and after that the name of
;; the text's file, once it has one.
(defun title (name)
  (if name
      (concatenate 'string "Emma - " name)
      "Emma"))

;; The lines of the file of a name.
(defun file-lines (name)
  (with-open-file (in name)
    (let ((lines nil))
      (loop
        (let ((line (read-line in nil)))
          (unless line
            (return (nreverse lines)))
          (setq lines (cons line lines)))))))

;; The text becomes that of the file of a name, or nothing at all when
;; there is no such file yet: saving makes it. After the last line of a
;; file comes one with nothing in it, which is where the text ends
;; (WRITE-OUT). What comes back is words for the status row.
(defun read-in (editor name)
  (let* ((there (probe-file name))
         (lines (and there (file-lines name))))
    (setf (editor-name editor) name
          (editor-above editor) nil
          (editor-line editor) (if lines (car lines) "")
          (editor-below editor) (and lines (append (cdr lines) (list "")))
          (editor-row editor) 0
          (editor-column editor) 0
          (editor-mark editor) nil
          (editor-changed editor) nil)
    (clara.windows:rename-window (editor-window editor) (title name))
    (if there
        (format nil "~D lines" (length lines))
        "a new file: Ctrl-S makes it")))

;; The text goes into the file of a name, a new line after every line of
;; it. A last line with nothing in it is where the text ends, and no line
;; of the file: so a text with nothing in it is a file with nothing in it,
;; and a file comes back as it was written.
(defun write-out (editor name)
  (let ((count 0))
    (with-open-file (out name :direction :output :if-exists :supersede)
      (do ((lines (all-lines editor) (cdr lines)))
          ((null lines))
        (unless (and (null (cdr lines)) (zerop (length (car lines))))
          (write-line (car lines) out)
          (setq count (1+ count)))))
    (setf (editor-name editor) name
          (editor-changed editor) nil)
    (clara.windows:rename-window (editor-window editor) (title name))
    (format nil "saved, ~D lines" count)))

;;; Evaluating
;;;
;;; The forms of the text, one after the other, as LOAD evaluates those of
;;; a file: what they define is defined in the world, for every window.
;;; They are evaluated in a thread of their own, so that the editor still
;;; hears Ctrl-C, which stops them.

;; The number of the line that the character INDEX of the text is in.
(defun line-at (lines index)
  (let ((row 0))
    (dolist (line lines row)
      (setq index (- index (length line) 1))
      (when (minusp index)
        (return row))
      (setq row (1+ row)))))

;; Words for the status row, and the number of the line where it went
;; wrong, when it did.
(defun evaluate-lines (lines)
  (let ((text (with-output-to-string (out)
                (dolist (line lines)
                  (write-line line out))))
        (*package* (find-package "COMMON-LISP-USER"))
        (nothing (list nil)) (start 0) (count 0))
    (handler-case
        (loop
          ;; Past what is blank and past the comments that begin with a
          ;; semicolon, so that START is where the next form begins.
          (loop
            (cond ((= start (length text))
                   (return))
                  ((or (char= (char text start) #\Space) (char= (char text start) #\Newline))
                   (setq start (1+ start)))
                  ((char= (char text start) #\;)
                   (loop
                     (when (or (= start (length text)) (char= (char text start) #\Newline))
                       (return))
                     (setq start (1+ start))))
                  (t
                   (return))))
          (multiple-value-bind (form end) (read-from-string text nil nothing :start start)
            (when (eq form nothing)
              (return (values (format nil "~D forms evaluated" count) nil)))
            (eval form)
            (setq start end
                  count (1+ count))))
      (serious-condition (condition)
        (let ((row (line-at lines start)))
          (values (format nil "line ~D: ~A" (1+ row) condition) row))))))

(defun evaluate (editor)
  (let ((lines (all-lines editor)) (words nil) (row nil) (thread nil))
    ;; Should the editor itself be stopped meanwhile, the forms go with it:
    ;; so their thread is made where leaving stops it, and not a step
    ;; before, or an editor that is stopped while it draws would leave the
    ;; forms running with nobody to stop them.
    (unwind-protect
         (progn
           (setq thread (clara:make-thread (lambda ()
                                             (multiple-value-setq (words row) (evaluate-lines lines)))
                                           :name "evaluating"))
           (setf (editor-message editor) "evaluating: Ctrl-C stops it")
           (render editor)
           (loop
             (unless (clara:thread-alive-p thread)
               (return))
             (when (equal (clara.windows:next-event (editor-window editor) 20) '(:key 3))
               (clara:interrupt-thread thread))))
      (when thread
        (clara:destroy-thread thread)))
    (when row
      (setf (editor-mark editor) nil)
      (go-to editor row 0))
    (setf (editor-message editor) (or words "the forms were stopped"))))

;;; The window

;; The text moves up in the window by so many rows, or down by as many as
;; the number is below nought: the rows that stay are copied to where they
;; go, and the others are to be drawn.
(defun scroll (editor delta)
  (let* ((rows (editor-rows editor)) (shown (editor-shown editor)) (surface (editor-surface editor))
         (width (* (editor-columns editor) (editor-wide editor)))
         (kept (- rows (abs delta))))
    (setf (editor-top editor) (+ (editor-top editor) delta))
    (cond ((<= kept 0)
           (dotimes (r rows)
             (setf (svref shown r) nil)))
          ((plusp delta)
           (clara.draw:copy-rectangle surface 0 (* delta (editor-high editor)) width (* kept (editor-high editor))
                                      surface 0 0)
           (dotimes (r rows)
             (setf (svref shown r) (and (< r kept) (svref shown (+ r delta))))))
          (t
           (clara.draw:copy-rectangle surface 0 0 width (* kept (editor-high editor))
                                      surface 0 (* (- delta) (editor-high editor)))
           (dotimes (i rows)
             (let ((r (- rows i 1)))
               (setf (svref shown r) (and (>= (+ r delta) 0) (svref shown (+ r delta))))))))))

;; The lines that the window shows, from its first row on.
(defun lines-in-sight (editor)
  (let ((lines (cons (editor-line editor) (editor-below editor)))
        (above (editor-above editor)))
    (dotimes (i (- (editor-row editor) (editor-top editor)))
      (setq lines (cons (car above) lines)
            above (cdr above)))
    lines))

;; What the status row says: a question and its answer so far; or words
;; about what was done last; or which file this is, and whether the text
;; has changed since; and at its right-hand end where the cursor is, when
;; there is room.
(defun status (editor)
  (let* ((asking (editor-asking editor))
         (words (cond (asking (concatenate 'string (car asking) (editor-answer editor)))
                      ((editor-message editor))
                      (t (concatenate 'string (or (editor-name editor) "a text with no file yet")
                                      (if (editor-changed editor) ", not saved" "")))))
         (place (format nil "line ~D, column ~D " (1+ (editor-row editor)) (1+ (editor-column editor))))
         (room (- (editor-columns editor) 1 (length words) (length place))))
    (if (or asking (< room 2))
        (fit (concatenate 'string " " words) (editor-columns editor))
        (concatenate 'string " " words (blank room) place))))

;; A bar under a cell: the cursor.
(defun bar (editor column row pixel)
  (clara.draw:fill-rectangle (editor-surface editor) (* column (editor-wide editor))
                             (- (* (1+ row) (editor-high editor)) 2) (editor-wide editor) 2 pixel))

;;; Parentheses
;;;
;;; The ones that belong together are drawn in a colour of their own, by
;;; how many pairs they lie within, and while the cursor stands behind a
;;; closing one, the one that opens it has a block under it, the hint, when
;;; it is in the window. Which parentheses count, and which belong
;;; together, is a matter of all the text before them, so what is known at
;;; the end of each line above the cursor's is kept from one drawing to the
;;; next: a line changes only while the cursor is in it. KNOWN is ABOVE as
;;; it was at the drawing before, and the lines that the two lists share,
;;; which they share as conses, are the ones that nothing has to be worked
;;; out for again.

;; What is known of the text at the end of each line above the cursor's,
;; the nearest first.
(defun states (editor)
  (let* ((above (editor-above editor)) (known (editor-known editor)) (states (editor-states editor))
         (more (- (length above) (length known))) (rest above) (new nil))
    ;; The two lists at one length,
    (loop
      (unless (minusp more)
        (return))
      (setq known (cdr known)
            states (cdr states)
            more (1+ more)))
    (dotimes (i more)
      (setq new (cons (car rest) new)
            rest (cdr rest)))
    ;; and then down both until they are one list.
    (loop
      (when (eq rest known)
        (return))
      (setq new (cons (car rest) new)
            rest (cdr rest)
            known (cdr known)
            states (cdr states)))
    ;; The lines that are new, from the one that comes first in the text.
    (let ((number (length rest)) (state (car states)))
      (dolist (line new)
        (setq state (clara.syntax:next-line (clara.syntax:scan line state number nil))
              states (cons state states)
              number (1+ number))))
    (setf (editor-known editor) above
          (editor-states editor) states)))

;; CELLS, the cells of a row of the window that are not ink on paper, with
;; the ones on the highlight's ground that are highlighted of LINE, the line
;; of that NUMBER, when the text from the place FROM to the place TO is: its
;; characters between the two, and the cell behind its last one when the
;; end of the line is between them too, which is how a line with nothing in
;; it shows.
(defun lit-cells (editor cells line number from to)
  (if (and from line (<= (car from) number (car to)))
      (let* ((left (editor-left editor))
             (start (if (= number (car from)) (cdr from) 0))
             (end (if (= number (car to)) (cdr to) (1+ (length line))))
             (first (max 0 (- start left))) (after (min (editor-columns editor) (- end left)))
             (ground (clara.windows:highlight)) (ink (editor-ink editor))
             (others (remove-if (lambda (cell) (and (>= (car cell) first) (< (car cell) after))) cells)))
        (do ((column (1- after) (1- column)))
            ((< column first) others)
          (let ((cell (assoc column cells)))
            (setq others (cons (list column (if cell (cadr cell) ink) ground) others)))))
      cells))

;; The cells of each row of the text that are not ink on paper go into
;; PAINTS: the parentheses of the lines in sight that count, what is
;; highlighted, and the hint.
(defun paint (editor)
  (let* ((rows (editor-rows editor)) (columns (editor-columns editor)) (paints (editor-paints editor))
         (top (editor-top editor)) (left (editor-left editor)) (row (editor-row editor))
         (behind (1- (editor-column editor)))
         (state (nth (- row top) (states editor)))
         (lines (lines-in-sight editor)) (number top) (cells nil) (hint nil)
         (seen (lambda (index level open)
                 ;; The parenthesis that the cursor stands behind, and the one that opens it.
                 (when (and open (= number row) (= index behind))
                   (setq hint open))
                 (let ((pixel (clara.syntax:color level)))
                   (when (and pixel (>= index left) (< index (+ left columns)))
                     (setq cells (cons (list (- index left) pixel) cells)))))))
    (multiple-value-bind (from to) (marked editor)
      (dotimes (r rows)
        (setq cells nil)
        (when lines
          (setq state (clara.syntax:next-line (clara.syntax:scan (car lines) state number seen))))
        (setf (svref paints r) (lit-cells editor cells (car lines) number from to))
        (setq lines (cdr lines)
              number (1+ number))))
    (let ((shade (clara.syntax:hint)))
      (when (and hint shade)
        (let ((r (- (car hint) top)) (column (- (cdr hint) left)))
          (when (and (< -1 r rows) (< -1 column columns))
            (let ((cell (assoc column (svref paints r))))
              (setf (svref paints r)
                    (cons (list column (if cell (cadr cell) (editor-ink editor)) shade)
                          (remove-if (lambda (other) (= (car other) column)) (svref paints r)))))))))))

;; The window shows the text again, around the cursor, and the status: each
;; row that is not what was drawn there is drawn, and then shown.
(defun render (editor)
  (let ((rows (editor-rows editor)) (columns (editor-columns editor)) (surface (editor-surface editor))
        (shown (editor-shown editor)) (ink (editor-ink editor)) (paper (editor-paper editor))
        (font (editor-font editor)))
    ;; The cursor that is drawn goes with its row, which is drawn again.
    (when (editor-cursor editor)
      (setf (svref shown (editor-cursor editor)) nil
            (editor-cursor editor) nil))
    ;; The window follows the cursor.
    (let ((row (editor-row editor)) (top (editor-top editor)))
      (cond ((< row top) (scroll editor (- row top)))
            ((>= row (+ top rows)) (scroll editor (- row top rows -1)))))
    (let ((column (editor-column editor)) (left (editor-left editor)))
      (cond ((< column left) (setf (editor-left editor) column))
            ((>= column (+ left columns)) (setf (editor-left editor) (- column columns -1)))))
    (paint editor)
    (let ((lines (lines-in-sight editor)) (left (editor-left editor)))
      (dotimes (r rows)
        (let* ((line (if lines (car lines) ""))
               (text (fit (if (< left (length line)) (subseq line left) "") columns))
               (cells (svref (editor-paints editor) r))
               (was (svref shown r)))
          (unless (and was (string= (car was) text) (equal (cdr was) cells))
            (clara.draw:draw-cells surface 0 (* r (editor-high editor)) text ink paper font)
            (dolist (cell cells)
              (clara.draw:draw-cells surface (* (car cell) (editor-wide editor)) (* r (editor-high editor))
                                     (string (char text (car cell))) (cadr cell) (or (caddr cell) paper) font))
            (setf (svref shown r) (cons text cells)))
          (setq lines (cdr lines)))))
    (setf (editor-cursor editor) (- (editor-row editor) (editor-top editor)))
    (bar editor (- (editor-column editor) (editor-left editor)) (editor-cursor editor) ink)
    ;; The status row, with the colours the other way round, and the cursor
    ;; in it while a question waits for its answer.
    (let ((text (status editor)))
      (unless (and (svref shown rows) (string= (car (svref shown rows)) text))
        (clara.draw:draw-cells surface 0 (* rows (editor-high editor)) text paper ink font)
        (setf (svref shown rows) (list text))
        (when (editor-asking editor)
          (let ((at (+ 1 (length (car (editor-asking editor))) (length (editor-answer editor)))))
            (when (< at columns)
              (bar editor at rows paper))))))
    (clara.windows:show (editor-window editor))))

;;; Keys

;; A question in the status row. What is typed from now on is its answer,
;; until Enter, which hands the answer to FUNCTION, or Escape.
(defun ask (editor words function)
  (setf (editor-asking editor) (cons words function)
        (editor-answer editor) ""))

;; What FUNCTION gives is said in the status row, and so is what goes wrong
;; in it: a file that is a directory, a volume that is full.
(defun attempt (editor function)
  (setf (editor-message editor)
        (handler-case (funcall function)
          (error (condition)
            (format nil "~A" condition)))))

(defun answer-key (editor code)
  (let ((answer (editor-answer editor)))
    (cond ((or (= code 10) (= code 13))
           (let ((function (cdr (editor-asking editor))))
             (setf (editor-asking editor) nil)
             (when (plusp (length answer))
               (attempt editor (lambda () (funcall function answer))))))
          ((or (= code 27) (= code 3))
           (setf (editor-asking editor) nil))
          ((or (= code 8) (= code 127))
           (when (plusp (length answer))
             (setf (editor-answer editor) (subseq answer 0 (1- (length answer))))))
          ((= code 22)                  ; Ctrl-V: the first line of what was copied last
           (let* ((text (clara.windows:clipboard)) (end (or (position #\Newline text) (length text))))
             (setf (editor-answer editor) (concatenate 'string answer (subseq text 0 end)))))
          ((and (>= code 32) (< code char-code-limit))
           (setf (editor-answer editor) (concatenate 'string answer (string (code-char code))))))))

;; Is the text saved, or is this the second time running that the key
;; asks? Otherwise it is refused, once.
(defun safe-p (editor code sure)
  (or (not (editor-changed editor))
      (eql code sure)
      (progn
        (setf (editor-sure editor) code
              (editor-message editor) "the text is not saved: Ctrl-S saves it, and asking once more goes on without")
        nil)))

;; Is this the code of a key that moves the cursor and does nothing else?
(defun moving-p (code)
  (or (= code clara.input:+up+) (= code clara.input:+down+) (= code clara.input:+left+) (= code clara.input:+right+)
      (= code clara.input:+home+) (= code clara.input:+end+)
      (= code clara.input:+page-up+) (= code clara.input:+page-down+)))

;; The character with this code was typed in the window, or the key with it.
;; What is typed takes the place of what is highlighted; Backspace and
;; Delete take that out and nothing else; and a key that moves the cursor
;; leaves nothing highlighted. A key that comes while the pointer's button
;; is held is the end of what the pointer was highlighting: the place where
;; the button went down may be no place of the text any more.
(defun key (editor code)
  (let ((cutting (editor-cutting editor)) (sure (editor-sure editor)))
    (setf (editor-message editor) nil
          (editor-cutting editor) nil
          (editor-sure editor) nil
          (editor-pressed editor) nil)
    (when (and (not (editor-asking editor)) (or (moving-p code) (= code 11)))
      (setf (editor-mark editor) nil))
    (cond ((editor-asking editor) (answer-key editor code))
          ((= code 3) (copy editor))    ; Ctrl-C
          ((= code 24)                  ; Ctrl-X
           (when (copy editor)
             (take-marked editor)))
          ((or (= code 22) (= code 25)) (paste editor)) ; Ctrl-V, and Ctrl-Y
          ((or (= code 10) (= code 13))
           (take-marked editor)
           (enter editor))
          ((= code 8) (or (take-marked editor) (rub-out editor)))
          ((= code 127) (or (take-marked editor) (take-out editor)))
          ((= code 9)
           (take-marked editor)
           (insert editor (blank (- 8 (mod (editor-column editor) 8)))))
          ((= code clara.input:+up+) (up editor))
          ((= code clara.input:+down+) (down editor))
          ((= code clara.input:+left+) (back editor))
          ((= code clara.input:+right+) (forth editor))
          ((= code clara.input:+home+) (setf (editor-column editor) 0))
          ((= code clara.input:+end+) (setf (editor-column editor) (length (editor-line editor))))
          ((= code clara.input:+page-up+)
           (dotimes (i (1- (editor-rows editor)))
             (up editor)))
          ((= code clara.input:+page-down+)
           (dotimes (i (1- (editor-rows editor)))
             (down editor)))
          ((= code 19)                  ; Ctrl-S
           (if (editor-name editor)
               (attempt editor (lambda () (write-out editor (editor-name editor))))
               (ask editor "Save as: " (lambda (name) (write-out editor name)))))
          ((= code 15)                  ; Ctrl-O
           (when (safe-p editor code sure)
             (ask editor "Open: " (lambda (name) (read-in editor name)))))
          ((= code 17)                  ; Ctrl-Q
           (when (safe-p editor code sure)
             (setf (editor-done editor) t)))
          ((= code 11) (cut-line editor cutting)) ; Ctrl-K
          ((= code 5) (evaluate editor)) ; Ctrl-E
          ((and (>= code 32) (< code char-code-limit))
           (take-marked editor)
           (insert editor (string (code-char code)))))))

;; The cursor goes between the two characters that a place of the window
;; is nearest to, in the line that the place is in: the line of a place
;; above the window or below it is one that the window does not show, and
;; the window follows the cursor there.
(defun go-near (editor x y)
  (go-to editor (+ (editor-top editor) (floor y (editor-high editor)))
         (+ (editor-left editor) (floor (+ x (floor (editor-wide editor) 2)) (editor-wide editor)))))

;; A button of the pointer went down or up in the window: the left one,
;; down on the text, puts the cursor there, on the character that it is on,
;; and nothing is highlighted any more. What is highlighted next begins
;; between the two characters that the place is nearest to.
(defun point (editor x y buttons)
  (let ((row (floor y (editor-high editor))))
    (when (= 1 (logand buttons 1))
      (setf (editor-pressed editor) nil))
    (when (and (= 1 (logand buttons 1)) (not (editor-asking editor)) (< row (editor-rows editor)))
      (setf (editor-message editor) nil
            (editor-cutting editor) nil
            (editor-sure editor) nil
            (editor-mark editor) nil)
      (go-near editor x y)
      (setf (editor-pressed editor) (cons (editor-row editor) (editor-column editor)))
      (go-to editor (+ (editor-top editor) row) (+ (editor-left editor) (floor x (editor-wide editor)))))))

;; The pointer was moved with that button held: the text from where the
;; button went down to where the pointer is now is highlighted, and the
;; cursor is at that end of it.
(defun drag (editor x y buttons)
  (when (and (= 1 (logand buttons 1)) (editor-pressed editor))
    (setf (editor-message editor) nil
          (editor-cutting editor) nil
          (editor-sure editor) nil
          (editor-mark editor) (editor-pressed editor))
    (go-near editor x y)))

(defun happened (editor event)
  (case (car event)
    (:key (key editor (cadr event)))
    (:pointer (destructuring-bind (x y buttons) (cdr event)
                (point editor x y buttons)))
    (:drag (destructuring-bind (x y buttons) (cdr event)
             (drag editor x y buttons)))
    (:close (key editor 17))))

;;; The application

;; An editor in a window of its own, with the text of the file of a name in
;; it, or with no text yet. COLUMNS and ROWS are the size of the text's
;; part, 80 by 24 cells or what the screen has room for; X and Y are where
;; the window goes; and FONT is what the text is written in, one of
;; CLARA.TYPE:FONT's or NIL for the console's letters, which is the one that
;; CLARA.WINDOWS:*TEXT-FONT* says when the editor is told nothing. The
;; window is the thread's that calls. Whoever shuts the machine down asks
;; the window first, and a text that is not saved is what it has to say
;; then.
(defun open-editor (name &key columns rows x y (font (clara.windows:text-font)))
  (let* ((screen (clara.draw:screen))
         (wide (clara.draw:cell-width font))
         (high (clara.draw:cell-height font))
         (columns (or columns (max 20 (min 80 (floor (- (clara.draw:surface-width screen) 48) wide)))))
         (rows (or rows (max 3 (min 24 (floor (- (clara.draw:surface-height screen) 136) high)))))
         (holds (list nil))
         (window (clara.windows:open-window (title name) (* columns wide)
                                            (* (1+ rows) high) :x x :y y :events t :drag t
                                            :unfinished (lambda ()
                                                          (and (car holds) (editor-changed (car holds))
                                                               "text that is not saved"))))
         (editor (make-editor :window window :surface (clara.windows:window-surface window)
                              :font font :wide wide :high high :columns columns :rows rows
                              :ink (clara.draw:color 232 227 244) :paper (clara.draw:color 30 27 46)
                              :shown (make-array (1+ rows) :initial-element nil)
                              :paints (make-array rows :initial-element nil)
                              :message "Ctrl-S saves, Ctrl-O opens a file, Ctrl-E evaluates, Ctrl-Q closes")))
    (setf (car holds) editor)
    (when name
      (attempt editor (lambda () (read-in editor name)))
      ;; A file that could not be read is not what the window has.
      (unless (editor-name editor)
        (clara.windows:rename-window window (title nil))))
    editor))

;; What happens to the window is done to the text, and the window shows
;; what came of it, until the window is to close.
(defun run (editor)
  (loop
    (render editor)
    (when (editor-done editor)
      (return))
    (happened editor (clara.windows:next-event (editor-window editor)))
    ;; And whatever else has happened by now, before anything is drawn.
    (loop
      (let ((event (clara.windows:next-event (editor-window editor) 0)))
        (unless event
          (return))
        (happened editor event)))))

;; The application: the file of a name is edited, or a text that has no
;; file yet, until the window closes. Whoever calls is the editor for as
;; long: the launcher starts a thread for that.
(defun edit (&optional name &rest options)
  (let ((editor (apply #'open-editor name options)))
    (unwind-protect (run editor)
      (clara.windows:close-window (editor-window editor)))
    name))

(clara.windows:define-application "Emma" #'edit)
