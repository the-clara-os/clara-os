;;;; settings.lisp: Settings, what a user sets of the system
;;;;
;;;; An application (lisp/windows.lisp): a window that lists what there is
;;;; to set of ClaraOS, a line each with what it is set to now, under the
;;;; part of the system that it belongs to. Where the machine is, for the
;;;; clock, and how loud it is; which letters the bar, the list and the
;;;; titles are written in, and which the windows of text, and how large;
;;;; whether the bar has a clock; how much a REPL keeps. The arrows up and
;;;; down, Page Up, Page Down, Home and End pick a line, and the arrows to
;;;; the left and to the right give it the value before the one that it
;;;; has, or the one after: a line shows a < and a > where there is such a
;;;; value, and a click on either does the same. The parts of the system
;;;; are headings, in the colour of the frame of the window that has the
;;;; focus. Under the lines the window says which variable the picked line
;;;; sets, and what that is for. Ctrl-Q closes the window, as its close box
;;;; does.
;;;;
;;;; Nothing is kept here. What a line sets is a variable of the system's,
;;;; the one that a form at a prompt would set, and what the line says is
;;;; what the variable holds, whoever set it: a window that is open looks
;;;; again every second. So what was set here is the world's, like
;;;; everything else that is: it is there for as long as the world is, a
;;;; world that is saved has it, and a world that leaves for a newer system
;;;; says it in its account, where the newer system finds it
;;;; (lisp/system.lisp).
;;;;
;;;; This file is not part of the world that the kernel loads. The launcher
;;;; loads it when Settings is first picked, and
;;;; CLARA.WINDOWS:UNLOAD-APPLICATION takes it out again. It loads under SBCL
;;;; as well, where lisp/host/ stands in for the machine.

(defpackage "CLARA.SETTINGS"
  (:use "COMMON-LISP")
  (:export "SETTINGS"))
(in-package "CLARA.SETTINGS")

;;; What there is to set
;;;
;;; A setting is a variable with a few words around it: what it is called
;;; in the window, the values that the window can give it, in an order, and
;;; how each of them is said. Two settings can be two parts of what one
;;; variable holds, as the family and the size of a font are.

(defstruct setting
  name      ; what its line says first
  variable  ; the symbol of the variable that it is a way of setting
  value     ; a function of no arguments: what it is set to now
  choices   ; a function of no arguments: the values that it can be given here, in their order
  change    ; a function of one of those, which sets it
  says      ; a function of a value, of those or any other: the words for it
  note)     ; what it is for, in a few words

;; The whole numbers from FROM to TO, STEP apart, which counts down when it
;; is less than nought.
(defun counted (from to step)
  (let ((numbers nil) (number from))
    (loop
      (when (if (> step 0) (> number to) (< number to))
        (return (reverse numbers)))
      (setq numbers (cons number numbers)
            number (+ number step)))))

;; What is no value of the kind that a line expects, said as it is written.
(defun as-written (value)
  (format nil "~S" value))

;; A time zone is so many hours behind Greenwich, and ahead of it when the
;; number is less than nought (CLARA:*TIME-ZONE*).
(defun zone-words (zone)
  (cond ((not (integerp zone)) (as-written zone))
        ((= zone 0) "Greenwich")
        ((= zone 1) "1 hour behind Greenwich")
        ((> zone 0) (format nil "~D hours behind Greenwich" zone))
        ((= zone -1) "1 hour ahead of Greenwich")
        (t (format nil "~D hours ahead of Greenwich" (- 0 zone)))))

;;; Fonts
;;;
;;; A variable that says a font holds what CLARA.TYPE:FONT is told, in a
;;; list: the name of a family, a size, and whatever else, bold for one; or
;;; such a font itself; or NIL for the console's letters, which have no
;;; family and one size (lisp/windows.lisp, *FONT*). A line here sets the
;;; family and another the size, and the rest of the list stays as it is.

;; The family that SAID names, NIL for the console's letters, and SAID
;; itself when it is nothing that says a font.
(defun family (said)
  (cond ((null said) nil)
        ((clara.type:font-p said) (clara.type:font-name said))
        ((and (consp said) (stringp (car said))) (car said))
        (t said)))

;; And the size, or NIL where there is none to say.
(defun size (said)
  (cond ((clara.type:font-p said) (clara.type:font-size said))
        ((and (consp said) (consp (cdr said))) (car (cdr said)))
        (t nil)))

;; What SAID is to be with another family, or with the console's letters
;; for NIL. The letters keep their size, and a family that comes after the
;; console's letters has 13 pixels, which is how large the bar's are as the
;; system comes.
(defun with-family (said family)
  (cond ((null family) nil)
        ((and (consp said) (consp (cdr said))) (list* family (car (cdr said)) (cdr (cdr said))))
        ((clara.type:font-p said) (list family (clara.type:font-size said)))
        (t (list family 13))))

;; And with another size, which the console's letters do not have.
(defun with-size (said size)
  (cond ((and (consp said) (consp (cdr said))) (list* (car said) size (cdr (cdr said))))
        ((clara.type:font-p said) (list (clara.type:font-name said) size))
        (t said)))

;; The font that SAID says can be had, or this ends in the error that says
;; why not: a variable is not set to letters that the machine has no file
;; of.
(defun to-be-had (said)
  (when (consp said)
    (apply #'clara.type:font said))
  said)

(defun families ()
  (cons nil (clara.type:families)))

(defun family-words (family)
  (cond ((null family) "the console's")
        ((stringp family) family)
        (t (as-written family))))

(defun size-words (size)
  (cond ((null size) "one size only")
        ((integerp size) (format nil "~D pixels" size))
        (t (as-written size))))

;; How many of something is kept, where NIL is all of them.
(defun count-words (count)
  (cond ((null count) "all of them")
        (t (as-written count))))

;; What the window lists, from its first row down: a heading, which is a
;; string, and under it the settings of that part of the system.
(defvar *lines*
  (list "System"
        (make-setting :name "Time zone" :variable 'clara:*time-zone*
                      :value (lambda () clara:*time-zone*)
                      :choices (lambda () (counted 12 -14 -1))
                      :change (lambda (zone) (setq clara:*time-zone* zone))
                      :says #'zone-words
                      :note "where the machine is, for the clock")
        (make-setting :name "Volume" :variable 'clara.sound:*volume*
                      :value (lambda () clara.sound:*volume*)
                      :choices (lambda () (counted 0 100 5))
                      :change (lambda (volume) (setq clara.sound:*volume* volume))
                      :says (lambda (volume)
                              (if (integerp volume) (format nil "~D of 100" volume) (as-written volume)))
                      :note "how loud the machine is")
        "Desktop"
        ;; The window manager made its letters when it started, and is told that they are others.
        (make-setting :name "Letters of the bar" :variable 'clara.windows:*font*
                      :value (lambda () (family clara.windows:*font*))
                      :choices #'families
                      :change (lambda (family)
                                (setq clara.windows:*font* (to-be-had (with-family clara.windows:*font* family)))
                                (clara.windows:redraw))
                      :says #'family-words
                      :note "for the bar, the list and the titles")
        ;; Their strips are 20 pixels high, and letters of more than 16 are cut off there.
        (make-setting :name "  their size" :variable 'clara.windows:*font*
                      :value (lambda () (size clara.windows:*font*))
                      :choices (lambda () (and (family clara.windows:*font*) (counted 9 16 1)))
                      :change (lambda (size)
                                (setq clara.windows:*font* (to-be-had (with-size clara.windows:*font* size)))
                                (clara.windows:redraw))
                      :says #'size-words
                      :note "their size, in pixels")
        ;; A window reads this as it opens, and keeps what it read.
        (make-setting :name "Letters of a window" :variable 'clara.windows:*text-font*
                      :value (lambda () (family clara.windows:*text-font*))
                      :choices #'families
                      :change (lambda (family)
                                (setq clara.windows:*text-font*
                                      (to-be-had (with-family clara.windows:*text-font* family))))
                      :says #'family-words
                      :note "for windows that open from now on")
        (make-setting :name "  their size" :variable 'clara.windows:*text-font*
                      :value (lambda () (size clara.windows:*text-font*))
                      :choices (lambda () (and (family clara.windows:*text-font*) (counted 9 24 1)))
                      :change (lambda (size)
                                (setq clara.windows:*text-font*
                                      (to-be-had (with-size clara.windows:*text-font* size))))
                      :says #'size-words
                      :note "their size, in pixels")
        (make-setting :name "Clock" :variable 'clara.windows:*clock*
                      :value (lambda () clara.windows:*clock*)
                      :choices (lambda () (list 'clara.windows:day-and-time nil))
                      :change (lambda (clock) (setq clara.windows:*clock* clock))
                      :says (lambda (clock)
                              (cond ((null clock) "none")
                                    ((eq clock 'clara.windows:day-and-time) "the day and the time")
                                    (t (as-written clock))))
                      :note "what the bar says of the time")
        "REPL"
        (make-setting :name "Rows that it keeps" :variable 'clara.terminal:*rows-kept*
                      :value (lambda () clara.terminal:*rows-kept*)
                      :choices (lambda () (list 100 1000 10000 100000 nil))
                      :change (lambda (rows) (setq clara.terminal:*rows-kept* rows))
                      :says #'count-words
                      :note "how far back Page Up goes")
        (make-setting :name "Lines that it remembers" :variable 'clara.terminal:*lines-kept*
                      :value (lambda () clara.terminal:*lines-kept*)
                      :choices (lambda () (list 100 1000 10000 nil))
                      :change (lambda (lines) (setq clara.terminal:*lines-kept* lines))
                      :says #'count-words
                      :note "what the arrow up brings back")))

;;; A step from one value to the next

;; The number of the choice that is nearest to a value which is none of
;; them: by how far apart they are when the value is a whole number and
;; some of the choices are, the first of two that are as near; and the
;; first choice otherwise.
(defun nearest (value choices)
  (let ((best 0) (far nil) (number 0))
    (when (integerp value)
      (dolist (choice choices)
        (when (integerp choice)
          (let ((away (abs (- choice value))))
            (when (or (null far) (< away far))
              (setq best number
                    far away))))
        (setq number (1+ number))))
    best))

;; The number of the choice that a step from VALUE comes to: the one after
;; it, or with BACK the one before it, and NIL when there is none that way.
;; A value that is none of the choices, which somebody set elsewhere, goes
;; to the nearest of them, whichever way the step is.
(defun step-from (value choices back)
  (let ((at (position value choices :test #'equal)))
    (cond ((null choices) nil)
          ((null at) (nearest value choices))
          (back (and (> at 0) (1- at)))
          (t (and (< (1+ at) (length choices)) (1+ at))))))

;;; The window

(defstruct panel
  window
  surface         ; what its window is drawn on
  font            ; what the lines are written in: one of CLARA.TYPE:FONT's, or NIL for the console's letters
  wide            ; the size of a cell of that, in pixels
  high
  columns         ; the size of the list's part of the window, in cells:
  rows            ;   the window has one row more, below it, for the status
  ink             ; the pixel of a glyph,
  paper           ; and the pixel around it; the line that is picked has the two the other way round, and so has the status
  accent          ; the pixel of a heading's glyphs
  lines           ; what is listed: headings and settings (*LINES*)
  (picked 0)      ; the number of the line that is picked, which is a setting's
  (top 0)         ; the number of the line in the window's first row
  shown           ; what each row of the window shows, as it was drawn: (text . kind), where the kind is T for the line
                  ;   that is picked and :HEADING for a heading, or NIL for a row to draw again
  message         ; words for the status row, until the next key: what went wrong
  done)           ; the window is to close

;; Where the parts of a setting's line begin, in cells: its name, the <,
;; and its value. The > stands three cells before the end of the row.
(defconstant +name+ 3)
(defconstant +back+ 28)
(defconstant +value+ 30)

(defvar *blank* "        ")

;; How many milliseconds a window waits for something to happen to it
;; before it looks at the variables again.
(defvar *look* 1000)

;; STRING, cut or made longer with spaces: WIDTH characters exactly.
(defun fit (string width)
  (loop
    (when (>= (length *blank*) width)
      (return))
    (setq *blank* (concatenate 'string *blank* *blank*)))
  (if (>= (length string) width)
      (subseq string 0 width)
      (concatenate 'string string (subseq *blank* 0 (- width (length string))))))

;; The name of a variable as it is written at a prompt, in small letters:
;; clara.sound:*volume*.
(defun written (symbol)
  (string-downcase (concatenate 'string (package-name (symbol-package symbol)) ":" (symbol-name symbol))))

;; What the row of a line shows. A heading is its word. A setting is its
;; name, under the heading and further in, and what it is set to, between a
;; < when there is a value before that one and a > when there is one after.
(defun row-text (panel line)
  (if (stringp line)
      (concatenate 'string " " line)
      (let* ((value (funcall (setting-value line)))
             (choices (funcall (setting-choices line))))
        (concatenate 'string
                     (fit (concatenate 'string (subseq *blank* 0 +name+) (setting-name line)) +back+)
                     (if (step-from value choices t) "< " "  ")
                     (fit (funcall (setting-says line) value) (- (panel-columns panel) +value+ 4))
                     (if (step-from value choices nil) " >" "  ")))))

;; What the status row says: what went wrong with the last key; or the
;; variable that the picked line sets, as a form would name it, and what it
;; is for.
(defun status (panel)
  (let ((line (nth (panel-picked panel) (panel-lines panel))))
    (cond ((panel-message panel))
          ((setting-p line) (concatenate 'string (written (setting-variable line)) ": " (setting-note line)))
          (t ""))))

;; The window shows the lines again, around the one that is picked, and the
;; status: each row that is not what was drawn there is drawn, and then
;; shown. The heading that the picked line stands right under stays in
;; sight with it, in a window that has a row for it.
(defun render (panel)
  (let* ((rows (panel-rows panel)) (columns (panel-columns panel)) (surface (panel-surface panel))
         (shown (panel-shown panel)) (ink (panel-ink panel)) (paper (panel-paper panel))
         (picked (panel-picked panel)) (font (panel-font panel))
         (first (if (and (> rows 1) (> picked 0) (stringp (nth (1- picked) (panel-lines panel))))
                    (1- picked)
                    picked)))
    (cond ((< first (panel-top panel)) (setf (panel-top panel) first))
          ((>= picked (+ (panel-top panel) rows)) (setf (panel-top panel) (- picked rows -1))))
    (let ((lines (nthcdr (panel-top panel) (panel-lines panel))))
      (dotimes (r rows)
        (let ((row (cons (fit (if lines (row-text panel (car lines)) "") columns)
                         (cond ((null lines) nil)
                               ((stringp (car lines)) :heading)
                               (t (= (+ (panel-top panel) r) picked))))))
          (unless (equal (svref shown r) row)
            (cond ((eq (cdr row) :heading)
                   (clara.draw:draw-cells surface 0 (* r (panel-high panel)) (car row) (panel-accent panel) paper font))
                  ((cdr row)
                   (clara.draw:draw-cells surface 0 (* r (panel-high panel)) (car row) paper ink font))
                  (t
                   (clara.draw:draw-cells surface 0 (* r (panel-high panel)) (car row) ink paper font)))
            (setf (svref shown r) row))
          (setq lines (cdr lines)))))
    (let ((text (fit (concatenate 'string " " (status panel)) columns)))
      (unless (equal (svref shown rows) text)
        (clara.draw:draw-cells surface 0 (* rows (panel-high panel)) text paper ink font)
        (setf (svref shown rows) text)))
    (clara.windows:show (panel-window panel))))

;;; Keys

;; The line that is picked is the setting of that number, or the nearest
;; one after it, or with BACK before it: a heading is not picked. Where
;; there is none that way, the one that was picked stays.
(defun pick (panel number back)
  (let ((lines (panel-lines panel)) (number (max 0 (min number (1- (length (panel-lines panel)))))))
    (loop
      (when (or (< number 0) (>= number (length lines)))
        (return))
      (when (setting-p (nth number lines))
        (setf (panel-picked panel) number)
        (return))
      (setq number (if back (1- number) (1+ number))))))

;; The setting that is picked gets the value after the one that it has, or
;; with BACK the one before it, when there is one. What goes wrong in that
;; is said in the status row, and the setting is as it was: letters that
;; the machine has no file of.
(defun change (panel back)
  (let ((setting (nth (panel-picked panel) (panel-lines panel))))
    (when (setting-p setting)
      (let* ((choices (funcall (setting-choices setting)))
             (to (step-from (funcall (setting-value setting)) choices back)))
        (when to
          (setf (panel-message panel)
                (handler-case (progn (funcall (setting-change setting) (nth to choices)) nil)
                  (error (condition)
                    (format nil "~A" condition)))))))))

;; The character with this code was typed in the window, or the key with it.
(defun key (panel code)
  (let ((picked (panel-picked panel)) (last (1- (length (panel-lines panel)))))
    (setf (panel-message panel) nil)
    (cond ((= code clara.input:+up+) (pick panel (1- picked) t))
          ((= code clara.input:+down+) (pick panel (1+ picked) nil))
          ((= code clara.input:+page-up+) (pick panel (- picked (1- (panel-rows panel))) nil))
          ((= code clara.input:+page-down+) (pick panel (+ picked (1- (panel-rows panel))) t))
          ((= code clara.input:+home+) (pick panel 0 nil))
          ((= code clara.input:+end+) (pick panel last t))
          ((= code clara.input:+left+) (change panel t))
          ((= code clara.input:+right+) (change panel nil))
          ((= code 17)                  ; Ctrl-Q
           (setf (panel-done panel) t)))))

;;; The pointer

;; The left button went down in the window: on the line of a setting it
;; picks that line, and on its < or its >, or right beside one, it gives
;; the setting the value before the one that it has, or the one after.
(defun point (panel x y buttons)
  (when (= 1 (logand buttons 1))
    (let* ((row (floor y (panel-high panel)))
           (column (floor x (panel-wide panel)))
           (number (+ (panel-top panel) row))
           (line (and (>= y 0) (< row (panel-rows panel)) (nth number (panel-lines panel))))
           (forward (- (panel-columns panel) 3)))
      (when (setting-p line)
        (setf (panel-message panel) nil
              (panel-picked panel) number)
        (cond ((<= (1- +back+) column (1+ +back+)) (change panel t))
              ((<= (1- forward) column (1+ forward)) (change panel nil)))))))

(defun happened (panel event)
  (case (car event)
    (:key (key panel (cadr event)))
    (:pointer (point panel (cadr event) (caddr event) (cadddr event)))
    (:close (setf (panel-done panel) t))))

;;; The application

;; The letters that the window is written in when it is told none: the ones
;; that the windows of text are written in (CLARA.WINDOWS:*TEXT-FONT*),
;; unless a window of COLUMNS cells would then be wider than the screen has
;; room for, where they are the console's. This is the window in which
;; letters that came out too large are made smaller, so it has to be one
;; that can be read whatever was set in it.
(defun letters-for (columns)
  (let ((font (clara.windows:text-font)) (screen (clara.draw:screen)))
    (if (and font screen
             (> (* columns (clara.draw:cell-width font)) (- (clara.draw:surface-width screen) 48)))
        nil
        font)))

;; The lines in a window of their own. COLUMNS is how wide the window is,
;; in cells, and ROWS how many lines it shows at once, all of them unless
;; it is told otherwise; X and Y are where the window goes; and FONT is
;; what the lines are written in, one of CLARA.TYPE:FONT's or NIL for the
;; console's letters, and what LETTERS-FOR says when the window is told
;; nothing. The window is the thread's that calls.
(defun open-panel (&key (columns 62) rows x y (font :fitting) (lines *lines*))
  (unless (and (integerp columns) (>= columns 40))
    (error "the window of the settings is 40 cells wide or more, for a line to say its value, and ~S is not" columns))
  (let* ((rows (or rows (length lines)))
         (font (if (eq font :fitting) (letters-for columns) font))
         (wide (clara.draw:cell-width font))
         (high (clara.draw:cell-height font))
         (window (clara.windows:open-window "Settings" (* columns wide) (* (1+ rows) high) :x x :y y :events t))
         (panel (make-panel :window window :surface (clara.windows:window-surface window)
                            :font font :wide wide :high high :columns columns :rows rows :lines lines
                            :ink (clara.draw:color 232 227 244) :paper (clara.draw:color 30 27 46)
                            :accent (clara.draw:color 255 184 108)
                            :shown (make-array (1+ rows) :initial-element nil))))
    (pick panel 0 nil)
    panel))

;; What happens to the window is done to the lines, and the window shows
;; what came of it, until the window is to close. When nothing has happened
;; for a second (*LOOK*) the lines are looked at again: what one of them
;; says may have been set somewhere else by then, at a prompt.
(defun run (panel)
  (loop
    (render panel)
    (when (panel-done panel)
      (return))
    (let ((event (clara.windows:next-event (panel-window panel) *look*)))
      (when event
        (happened panel event)))
    ;; And whatever else has happened by now, before anything is drawn.
    (loop
      (let ((event (clara.windows:next-event (panel-window panel) 0)))
        (unless event
          (return))
        (happened panel event)))))

;; The application: the settings are listed until the window closes.
;; Whoever calls is the window's program for as long: the launcher starts a
;; thread for that.
(defun settings (&rest options)
  (let ((panel (apply #'open-panel options)))
    (unwind-protect (run panel)
      (clara.windows:close-window (panel-window panel)))
    nil))

(clara.windows:define-application "Settings" #'settings)
