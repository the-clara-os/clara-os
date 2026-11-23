;;;; windows.lisp: the window manager
;;;;
;;;; Windows on the screen: each is a surface that its program draws on
;;;; (lisp/draw.lisp), inside a frame with a title that this file draws.
;;;; They lie over one another, the one on top has the focus, which is
;;;; where the keys go, and the pointer picks one, moves one by its title
;;;; and closes one by the box in it. Along the top of the screen is the
;;;; launcher: a bar whose button lists the applications there are, and
;;;; starts the one that is picked, in a thread of its own. An application
;;;; is defined in the world, or it is a file that is loaded when it is
;;;; first picked, and can be unloaded again. Under the applications the
;;;; list has the commands: things that are done and open no window, such
;;;; as shutting the machine down (lisp/system.lisp). What the bar, the list
;;;; and the titles say is written in a font of outlines (lisp/type.lisp),
;;;; and in the console's letters on a machine that has no such font.
;;;;
;;;; Nothing here draws on the screen. What the screen is to show is put
;;;; together on a surface of the same size, out of sight: the desk, the
;;;; windows from the lowest to the topmost, the launcher's list, and the
;;;; pointer over them all. Only the rectangles that have changed are put
;;;; together again, and those are then copied to the screen, so nothing is
;;;; ever seen half drawn, and the pointer needs no memory of what is under
;;;; it.
;;;;
;;;; A window's surface is its program's: the thread that opened the window
;;;; draws on it, says when it has (SHOW), and closes it. This file only
;;;; reads it. Everything else that is here, the windows there are, their
;;;; order, the surface that the screen is put together on and the screen
;;;; itself, is touched with the lock held, by whichever thread it is: a
;;;; program's, or the thread of a keyboard or a mouse, which is where
;;;; KEY-TYPED and POINTER-MOVED are called (lisp/input.lisp).
;;;;
;;;; START takes the screen from the console, which goes on with the serial
;;;; port, and STOP gives it back. A world that is saved while the window
;;;; manager runs starts in it: RESUME, which the substrate calls at every
;;;; boot.
;;;;
;;;; This file loads under SBCL as well, where lisp/host/ stands in for the
;;;; machine, and the tests there hold every pixel of the screen against
;;;; what the windows should come to.

(defpackage "CLARA.WINDOWS"
  (:use "COMMON-LISP")
  (:export "START" "STOP" "RESUME" "RUNNING-P"
           "OPEN-WINDOW" "CLOSE-WINDOW" "SHOW" "WINDOW-P" "WINDOW-TITLE" "WINDOW-SURFACE" "WINDOW-POSITION"
           "MOVE-WINDOW" "RAISE-WINDOW" "RENAME-WINDOW" "NEXT-EVENT" "WINDOWS" "FOCUSED-WINDOW"
           "DEFINE-APPLICATION" "INSTALL-APPLICATION" "UNLOAD-APPLICATION" "REMOVE-APPLICATION"
           "APPLICATIONS" "LAUNCH" "*APPLICATION-DIRECTORY*" "DEFINE-COMMAND" "REMOVE-COMMAND" "COMMANDS"
           "UNFINISHED" "*FONT*"
           "KEY-TYPED" "POINTER-MOVED"))
(in-package "CLARA.WINDOWS")

(defstruct window
  title    ; a string, for its frame
  surface  ; what its program draws on: the inside of the window; NIL once it has been closed
  x y      ; where the inside's upper left corner is on the screen
  width    ; of the inside, in pixels
  height
  key      ; a function of a character's code, called for what is typed while the window has the focus, or NIL
  pointer  ; a function of a place on the inside and the buttons, called when a button goes down or up there, or NIL
  close    ; a function of no arguments, called when the close box is clicked; without one there is no box
  unfinished ; a function of no arguments that says what its program has not finished, in words, or NIL: see UNFINISHED
  thread   ; the thread that opened it, whose it is to draw on and to close
  open     ; it is on the screen
  closing  ; its close box was clicked, and CLOSE called
  events   ; of a window that keeps what happens to it for NEXT-EVENT: what did and was not taken yet, the oldest first,
  events-lock
  happened) ;   and the event that says there is some

;;; The layout, in pixels. A frame is a line around the inside and a band
;;; above it: 21 rows from the top of the frame to the inside, with the
;;; title in them, and at their right-hand end the close box.
(defconstant +bar+ 20)      ; the launcher's bar, along the top of the screen, is this high,
(defconstant +item+ 20)     ; and so is a line of its list
(defconstant +button+ 112)  ; the bar's button, at its left-hand end, is this wide
(defconstant +band+ 21)     ; from the top of a window's frame to its inside
(defconstant +box+ 16)      ; the close box is this wide, and as high as the band
(defconstant +events-limit+ 1024) ; what happens to a window and waits to be taken; what happens past that is dropped

(defvar *lock* (clara:make-lock "windows"))
(defvar *running* nil)      ; the window manager has the screen; in a world that was saved: it had
(defvar *back* nil)         ; the surface that the screen is put together on
(defvar *windows* nil)      ; the windows on the screen, the topmost first: that one has the focus
(defvar *made* nil)         ; every window that was opened and not closed, on the screen or not
(defvar *dirty* nil)        ; rectangles of the screen that are to be put together again, none over another
(defvar *applications* nil) ; the applications there are, in the order of the launcher's list
(defvar *commands* nil)     ; and under them the commands, each (name . function), in that order
(defvar *application-directory* nil) ; where the file of an application is that was installed by a bare name, or NIL
(defvar *loading* (clara:make-lock "applications")) ; the file of one application is loaded at a time
(defvar *launched* nil)     ; the threads that LAUNCH made
(defvar *launching* nil)    ; in the thread of an application: the event that LAUNCH waits for, until its window is open
(defvar *opened* 0)         ; how many windows were opened, for where the next one goes
(defvar *menu* nil)         ; the launcher's list is open
(defvar *drag* nil)         ; (window dx . dy): the window that the pointer has by its frame, and where it took hold
(defvar *pointer-x* 0)      ; where the pointer was last said to be,
(defvar *pointer-y* 0)
(defvar *buttons* 0)        ; and its buttons
(defvar *name* "")          ; the system and its version, for the right-hand end of the bar
(defvar *font* (list "Sans" 13)) ; what the bar, the list and the titles are written in: the name of a font of outlines
                            ;   and its size, as CLARA.TYPE:FONT takes them, or NIL for the console's letters. START reads it.
(defvar *letters* nil)      ; that font, as START found it, or NIL: the console's letters

;; Pixels, which are the screen's to say: made of colours by START.
(defvar *desk* 0)   ; behind everything
(defvar *paper* 0)  ; the bar, the list, the inside of a new window, and the title of the window that has the focus
(defvar *ink* 0)    ; the text on those, and the pointer
(defvar *lit* 0)    ; the frame of the window that has the focus
(defvar *dim* 0)    ; and of the others
(defvar *dark* 0)   ; the pointer's edge

;; The pointer: an arrow of 12 by 19 pixels whose tip is the place that it
;; points at. Its edge is one picture and what is within the edge another,
;; so that it shows on anything.
(defvar *arrow-edge*
  (vector #b100000000000 #b110000000000 #b101000000000 #b100100000000 #b100010000000 #b100001000000
          #b100000100000 #b100000010000 #b100000001000 #b100000000100 #b100000000010 #b100000011111
          #b100010010000 #b100110010000 #b101001001000 #b110001001000 #b000000100100 #b000000100100
          #b000000011000))
(defvar *arrow-fill*
  (vector #b000000000000 #b000000000000 #b010000000000 #b011000000000 #b011100000000 #b011110000000
          #b011111000000 #b011111100000 #b011111110000 #b011111111000 #b011111111100 #b011111100000
          #b011101100000 #b011001100000 #b010000110000 #b000000110000 #b000000011000 #b000000011000
          #b000000000000))

;;; What is dirty
;;;
;;; Whatever changes what the screen should show says which rectangle of
;;; it, and SETTLE puts those together again. Two that lie over each other
;;; become the one around both, so that little is painted twice.

(defun damaged (left top right bottom)
  (let ((left (max left 0)) (top (max top 0))
        (right (min right (clara.draw:surface-width *back*)))
        (bottom (min bottom (clara.draw:surface-height *back*))))
    (when (and (< left right) (< top bottom))
      (let ((others *dirty*) (apart nil) (grown t))
        ;; Whatever it lies over becomes part of it, and then it may lie over more.
        (loop
          (unless grown
            (return))
          (setq grown nil
                apart nil)
          (dolist (other others)
            (if (and (< (first other) right) (< left (third other)) (< (second other) bottom) (< top (fourth other)))
                (setq left (min left (first other))
                      top (min top (second other))
                      right (max right (third other))
                      bottom (max bottom (fourth other))
                      grown t)
                (setq apart (cons other apart))))
          (setq others apart))
        (setq *dirty* (cons (list left top right bottom) others))))))

;; The frame of a window and all that is in it.
(defun window-damaged (window)
  (damaged (1- (window-x window)) (- (window-y window) +band+)
           (+ (window-x window) (window-width window) 1) (+ (window-y window) (window-height window) 1)))

(defun pointer-damaged ()
  (damaged *pointer-x* *pointer-y* (+ *pointer-x* 12) (+ *pointer-y* (length *arrow-edge*))))

;;; Putting the screen together

;; The font that *FONT* asks for, or NIL, which is the console's letters:
;; when none is asked for, and when the one that is cannot be had, which is
;; said once.
(defun letters ()
  (and (consp *font*)
       (handler-case (clara.type:font (car *font*) (cadr *font*))
         (error (condition)
           (format t "windows: ~A, so the letters are the console's~%" condition)
           nil))))

;; How wide STRING is in the letters of the bar, the list and the titles,
;; and how high a line of them.
(defun label-width (string)
  (clara.draw:text-width string *letters*))

(defun label-height ()
  (if *letters*
      (+ (clara.type:font-ascent *letters*) (clara.type:font-descent *letters*))
      clara.font:+height+))

;; STRING in those letters, from X on, halfway up the strip of HEIGHT rows
;; that begins at TOP.
(defun label (x top height string color)
  (clara.draw:draw-text *back* x (+ top (floor (- height (label-height)) 2)) string color nil *letters*))

(defun paint-desk ()
  (let ((width (clara.draw:surface-width *back*)))
    (clara.draw:fill-rectangle *back* 0 +bar+ width (- (clara.draw:surface-height *back*) +bar+) *desk*)
    (clara.draw:fill-rectangle *back* 0 0 width +bar+ *paper*)
    (label 8 0 +bar+ "Applications" *ink*)
    ;; What this system is, where there is room to say so.
    (let ((x (- width 8 (label-width *name*))))
      (when (>= x +button+)
        (label x 0 +bar+ *name* *ink*)))))

;; A window: its frame, lit when it has the focus, its title, cut short
;; where the close box begins, the box, and its inside, as its program
;; last drew it.
(defun paint-window (window lit)
  (let ((x (window-x window)) (y (window-y window)) (width (window-width window)) (height (window-height window))
        (frame (if lit *lit* *dim*)) (text (if lit *paper* *ink*)))
    (clara.draw:fill-rectangle *back* (1- x) (- y +band+) (+ width 2) +band+ frame)
    (clara.draw:fill-rectangle *back* (1- x) y 1 height frame)
    (clara.draw:fill-rectangle *back* (+ x width) y 1 height frame)
    (clara.draw:fill-rectangle *back* (1- x) (+ y height) (+ width 2) 1 frame)
    (clara.draw:with-clip (*back* (+ x 3) (- y +band+) (- width 6 (if (window-close window) +box+ 0)) +band+)
      (label (+ x 3) (- y +band+) +band+ (window-title window) text))
    (when (window-close window)
      (label (- (+ x width) (floor (+ +box+ (label-width "x")) 2)) (- y +band+) +band+ "x" text))
    (clara.draw:copy-rectangle (window-surface window) 0 0 width height *back* x y)))

;; The launcher's list: the applications, one to a line, under the bar,
;; and under them the commands, with a line between the two.
(defun menu-names ()
  (append (mapcar #'application-name *applications*) (mapcar #'car *commands*)))

(defun menu-width ()
  (let ((width +button+))
    (dolist (name (menu-names) width)
      (setq width (max width (+ 16 (label-width name)))))))

(defun menu-damaged ()
  (damaged 0 +bar+ (menu-width) (+ +bar+ (* +item+ (length (menu-names))))))

(defun paint-menu ()
  (let* ((names (menu-names)) (width (menu-width)) (height (* +item+ (length names))) (y +bar+))
    (clara.draw:fill-rectangle *back* 0 +bar+ width height *paper*)
    (clara.draw:draw-rectangle *back* 0 +bar+ width height *ink*)
    (dolist (name names)
      (label 8 y +item+ name *ink*)
      (setq y (+ y +item+)))
    (when (and *applications* *commands*)
      (clara.draw:fill-rectangle *back* 0 (+ +bar+ (* +item+ (length *applications*))) width 1 *ink*))))

(defun paint-pointer ()
  (clara.draw:draw-bitmap *back* *pointer-x* *pointer-y* *arrow-edge* 12 *dark*)
  (clara.draw:draw-bitmap *back* *pointer-x* *pointer-y* *arrow-fill* 12 *ink*))

;; Is all of the rectangle on the inside of WINDOW?
(defun covers-p (window left top right bottom)
  (and (<= (window-x window) left) (<= (window-y window) top)
       (>= (+ (window-x window) (window-width window)) right)
       (>= (+ (window-y window) (window-height window)) bottom)))

;; Is any of it on WINDOW, its frame included?
(defun touches-p (window left top right bottom)
  (and (< (- (window-x window) 1) right) (< left (+ (window-x window) (window-width window) 1))
       (< (- (window-y window) +band+) bottom) (< top (+ (window-y window) (window-height window) 1))))

;; What the screen should show in a rectangle of it, put together and then
;; shown. The topmost window whose inside takes in all of the rectangle
;; hides what is below it, the desk too: what a program draws in the window
;; that has the focus costs a copy, however many windows there are.
(defun compose (left top right bottom)
  (clara.draw:with-clip (*back* left top (- right left) (- bottom top))
    (let ((layers nil) (hidden nil))
      (dolist (window *windows*)
        (setq layers (cons window layers))
        (when (covers-p window left top right bottom)
          (setq hidden t)
          (return)))
      (unless hidden
        (paint-desk))
      (dolist (window layers) ; the lowest first
        (when (touches-p window left top right bottom)
          (paint-window window (eq window (car *windows*))))))
    (when *menu*
      (paint-menu))
    (paint-pointer))
  (clara.draw:show *back*))

;; Everything that is dirty is put together again. A rectangle is forgotten
;; when it has been, and not before: a thread that is stopped in the middle
;; of one leaves it for whoever settles next.
(defun settle ()
  (loop
    (let ((rectangle (car *dirty*)))
      (unless rectangle
        (return))
      (compose (first rectangle) (second rectangle) (third rectangle) (fourth rectangle))
      (setq *dirty* (cdr *dirty*)))))

;;; Windows

;; A window stays where its band can be got hold of: below the launcher's
;; bar, and with some of it on the screen.
(defun place (window x y)
  (setf (window-x window) (max (- 24 (window-width window)) (min x (- (clara.draw:surface-width *back*) 24)))
        (window-y window) (max (+ +bar+ +band+) (min y (- (clara.draw:surface-height *back*) 4)))))

;; WINDOW, when it is one that is on the screen. The lock is held.
(defun on-screen (window)
  (unless (window-p window)
    (error "~S is not a window" window))
  (unless (and *running* (window-open window))
    (error "the window ~S is not on the screen" (window-title window)))
  window)

;; It comes to the top, and has the focus.
(defun raise (window)
  (unless (eq window (car *windows*))
    (window-damaged (car *windows*))
    (setq *windows* (cons window (remove window *windows*)))
    (window-damaged window)))

;; It leaves the screen, and the one below it has the focus.
(defun unlink (window)
  (let ((top (eq window (car *windows*))))
    (setf (window-open window) nil)
    (setq *windows* (remove window *windows*))
    (when (eq (car *drag*) window)
      (setq *drag* nil))
    (when *running*
      (window-damaged window)
      (when (and top *windows*)
        (window-damaged (car *windows*)))
      (settle))))

;; A new window, on top of the others and with the focus: its inside is
;; WIDTH by HEIGHT pixels, the colour of paper, and is the surface that
;; WINDOW-SURFACE gives. It is the window of the thread that opens it: that
;; thread draws on the surface, shows what it has drawn, and closes the
;; window. KEY, POINTER and CLOSE are functions that are called for what
;; is typed while the window has the focus, for a button of the pointer
;; that goes down or up on its inside, and for a click on its close box,
;; which it has when CLOSE is given. They are called in the thread of the
;; keyboard or of the mouse, so they hand on what they are told and do not
;; draw. With EVENTS the window has the three for itself, and keeps what
;; they are told until its program asks: NEXT-EVENT. UNFINISHED is a
;; function that says, when it is asked, what the window's program still
;; holds that would be lost if the window went now, in a few words, or NIL
;; for nothing: a text that is not saved. It is asked before the machine is
;; shut down, in whatever thread does that.
(defun open-window (title width height &key x y key pointer close events unfinished)
  (unless (stringp title)
    (error "the title of a window is a string, and ~S is not one" title))
  (unless (and (integerp width) (>= width 24))
    (error "a window is 24 pixels wide or more, for its band to be got hold of, and ~S is not" width))
  (let* ((surface (clara.draw:allocate-surface width height))
         (window (make-window :title title :surface surface :width width :height height
                              :key key :pointer pointer :close close :unfinished unfinished
                              :thread (clara:current-thread)))
         (opened nil))
    (when events
      (setf (window-events-lock window) (clara:make-lock "events")
            (window-happened window) (clara:make-event "events")
            (window-key window) (lambda (code) (post window (list :key code)))
            (window-pointer window) (lambda (x y buttons) (post window (list :pointer x y buttons)))
            (window-close window) (lambda () (post window (list :close)))))
    (unwind-protect
         (clara:with-lock-held (*lock*)
           (unless *running*
             (error "there is no window manager to open a window with: (clara.windows:start) starts it"))
           (clara.draw:fill-rectangle surface 0 0 width height *paper*)
           (clara.draw:take-damage surface)
           (let ((step (* 24 (mod *opened* 8))))
             (place window (or x (+ 40 step)) (or y (+ 64 step))))
           (setq *opened* (1+ *opened*))
           (when *windows*
             (window-damaged (car *windows*)))
           (setf (window-open window) t)
           (setq *windows* (cons window *windows*)
                 *made* (cons window *made*)
                 opened t)
           (window-damaged window)
           (settle))
      (unless opened
        (clara.draw:free-surface surface)))
    ;; For LAUNCH, which waits for the application's window.
    (when *launching*
      (clara:signal-event *launching*)
      (setq *launching* nil))
    window))

;; The window leaves the screen, and its surface is freed: by the thread
;; that opened it, which is the one that may be drawing on it, or by
;; anybody once that thread is no more.
(defun close-window (window)
  (unless (window-p window)
    (error "~S is not a window" window))
  (unless (or (eq (window-thread window) (clara:current-thread))
              (not (clara:thread-alive-p (window-thread window))))
    (error "the window ~S is for ~S to close, the thread that draws on it" (window-title window)
           (window-thread window)))
  (let ((surface nil))
    (clara:with-lock-held (*lock*)
      (when (window-open window)
        (unlink window))
      (setq surface (window-surface window)
            *made* (remove window *made*))
      (setf (window-surface window) nil))
    (when surface
      (clara.draw:free-surface surface)))
  nil)

;; What its program has drawn on the window's surface since it was last
;; shown reaches the screen, as far as the window can be seen. NIL when
;; nothing was drawn, or the window is not on the screen.
(defun show (window)
  (unless (window-p window)
    (error "~S is not a window" window))
  (unless (window-surface window)
    (error "the window ~S was closed" (window-title window)))
  (let ((damage (clara.draw:take-damage (window-surface window))) (shown nil))
    (clara:with-lock-held (*lock*)
      (when (and *running* (window-open window))
        (dolist (rectangle damage)
          (let ((left (+ (window-x window) (first rectangle))) (top (+ (window-y window) (second rectangle))))
            (damaged left top (+ left (third rectangle)) (+ top (fourth rectangle))))
          (setq shown t))
        (settle)))
    shown))

;;; What happens to a window, for a program that waits for it
;;;
;;; A window that was opened with EVENTS keeps what it is told, in the order
;;; in which it was: (:KEY code) for what was typed while it had the focus,
;;; a character's code or the code of a key that types none
;;; (lisp/input.lisp); (:POINTER x y buttons) for a button that went down or
;;; up on its inside, with the place there; and (:CLOSE) for a click on its
;;; close box. Its program takes them one at a time, in a thread of its own,
;;; where it can draw.

(defun post (window event)
  (clara:with-lock-held ((window-events-lock window))
    (when (< (length (window-events window)) +events-limit+)
      (setf (window-events window) (append (window-events window) (list event)))))
  (clara:signal-event (window-happened window)))

;; The next thing that happened to WINDOW, waited for when nothing has: for
;; so many milliseconds, after which it is NIL, or for as long as it takes.
(defun next-event (window &optional milliseconds)
  (unless (and (window-p window) (window-happened window))
    (error "~S is not a window that keeps what happens to it: OPEN-WINDOW with :EVENTS makes one" window))
  (loop
    (let ((event (clara:with-lock-held ((window-events-lock window))
                   (let ((event (car (window-events window))))
                     (setf (window-events window) (cdr (window-events window)))
                     event))))
      (when event
        ;; The box has been heard, and the next click on it is told again.
        (when (eq (car event) :close)
          (clara:with-lock-held (*lock*)
            (setf (window-closing window) nil)))
        (return event)))
    (unless (clara:wait-event (window-happened window) milliseconds)
      (return nil))))

;; The window has another title from now on.
(defun rename-window (window title)
  (unless (window-p window)
    (error "~S is not a window" window))
  (unless (stringp title)
    (error "the title of a window is a string, and ~S is not one" title))
  (clara:with-lock-held (*lock*)
    (setf (window-title window) title)
    (when (and *running* (window-open window))
      (damaged (1- (window-x window)) (- (window-y window) +band+)
               (+ (window-x window) (window-width window) 1) (window-y window))
      (settle)))
  title)

;; Where the inside's upper left corner is on the screen: two values.
(defun window-position (window)
  (values (window-x window) (window-y window)))

;; The window goes there, as far as a window can go, and where it is then
;; is what comes back.
(defun move-window (window x y)
  (clara:with-lock-held (*lock*)
    (on-screen window)
    (window-damaged window)
    (place window x y)
    (window-damaged window)
    (settle))
  (window-position window))

(defun raise-window (window)
  (clara:with-lock-held (*lock*)
    (raise (on-screen window))
    (settle))
  window)

;; The windows on the screen, the topmost first, which has the focus.
(defun windows ()
  (clara:with-lock-held (*lock*)
    (copy-list *windows*)))

;; What the programs of the windows have not finished: for every window
;; that says so, the window and what it says, the topmost first. A function
;; that fails has nothing to say.
(defun unfinished ()
  (let ((found nil))
    (dolist (window (windows) (reverse found))
      (let ((says (and (window-unfinished window) (ignore-errors (funcall (window-unfinished window))))))
        (when (stringp says)
          (setq found (cons (cons window says) found)))))))

(defun focused-window ()
  (car (windows)))

;;; The keyboard and the pointer

;; From the driver of a keyboard: the character with this code was typed,
;; or the key with it. It is for the window that has the focus, but for
;; one, which is the window manager's own: Tab with Alt held brings the
;; lowest window to the top, and so each of them in turn.
(defun key-typed (code)
  (if (= code (+ clara.input:+alt+ 9))
      (clara:with-lock-held (*lock*)
        (when (and *running* (cdr *windows*))
          (raise (car (last *windows*)))
          (settle)))
      (let ((window (focused-window)))
        (when (and window (window-key window))
          (funcall (window-key window) code))))
  code)

;; The topmost window that the place is on, and which part of it: :INSIDE,
;; :CLOSE for its close box, and :FRAME for the rest of its frame.
(defun window-at (x y)
  (dolist (window *windows*)
    (let* ((left (window-x window)) (top (window-y window))
           (right (+ left (window-width window))) (bottom (+ top (window-height window))))
      (when (and (<= (1- left) x right) (<= (- top +band+) y bottom))
        (return (values window
                        (cond ((and (<= left x) (< x right) (<= top y) (< y bottom)) :inside)
                              ((and (window-close window) (< y top) (>= x (- right +box+))) :close)
                              (t :frame))))))))

;; What a window's program is to be told of the pointer: a function that
;; tells it, to be called once the lock is free again, or NIL.
(defun tell (window x y buttons)
  (let ((function (window-pointer window)) (x (- x (window-x window))) (y (- y (window-y window))))
    (and function
         (lambda () (funcall function x y buttons)))))

;; The left button went down at that place. With the launcher's list open
;; it picks an application, or none; on the bar's button it opens the list;
;; on a window it brings the window to the top, and then closes it, takes
;; hold of it, or is its program's to know about. What is to be done about
;; it when the lock is free is returned, as a function.
(defun press (x y buttons)
  (cond (*menu*
         (let* ((line (and (< x (menu-width)) (>= y +bar+) (floor (- y +bar+) +item+)))
                (application (and line (nth line *applications*)))
                (command (and line (>= line (length *applications*))
                              (nth (- line (length *applications*)) *commands*))))
           (menu-damaged)
           (setq *menu* nil)
           (cond (application
                  (let ((name (application-name application)))
                    (lambda () (launch name))))
                 (command
                  (lambda () (run-command command))))))
        ((< y +bar+)
         (when (and (< x +button+) (or *applications* *commands*))
           (setq *menu* t)
           (menu-damaged))
         nil)
        (t
         (multiple-value-bind (window part) (window-at x y)
           (when window
             (raise window)
             (case part
               (:inside (tell window x y buttons))
               (:frame (setq *drag* (list* window (- x (window-x window)) (- y (window-y window))))
                nil)
               (:close
                (cond ((not (clara:thread-alive-p (window-thread window)))
                       ;; Nobody is left to close it.
                       (lambda () (close-window window)))
                      ((not (window-closing window))
                       (setf (window-closing window) t)
                       (window-close window))))))))))

;; From the drivers of mice and tablets: the pointer is at that place, with
;; those buttons down, and one of the three has changed. Its picture moves;
;; a window that it has hold of moves with it, until the left button comes
;; up; and a button that changes is for PRESS, or for the program of the
;; window that the pointer is on the inside of.
(defun pointer-moved (x y buttons)
  (let ((call nil))
    (clara:with-lock-held (*lock*)
      (when *running*
        (let ((down (/= 0 (logand buttons 1)))
              (was-down (/= 0 (logand *buttons* 1)))
              (changed (/= buttons *buttons*)))
          (unless (and (= x *pointer-x*) (= y *pointer-y*))
            (pointer-damaged)
            (setq *pointer-x* x
                  *pointer-y* y)
            (pointer-damaged))
          (setq *buttons* buttons)
          (cond ((and down (not was-down))
                 (setq call (press x y buttons)))
                (t
                 (cond ((not down)
                        (setq *drag* nil))
                       (*drag*
                        (let ((window (car *drag*)))
                          (window-damaged window)
                          (place window (- x (car (cdr *drag*))) (- y (cdr (cdr *drag*))))
                          (window-damaged window))))
                 (when changed
                   (multiple-value-bind (window part) (window-at x y)
                     (when (and window (eq part :inside))
                       (setq call (tell window x y buttons)))))))
          (settle))))
    (when call
      (funcall call)))
  nil)

;;; Applications
;;;
;;; An application is a name and a function. Launching it calls the function
;;; in a new thread, where it opens its window and does whatever it does
;;; until it returns or is stopped; whatever windows the thread has open
;;; then are closed, by that thread, on its way out.
;;;
;;; The function is defined in the world, by whatever was loaded into it or
;;; typed at a prompt, or it is in a file that nobody has loaded yet: an
;;; application that is installed is a name and the name of a file, and the
;;; file is loaded when the application is first launched, in the thread
;;; that is to run it. The file defines the application, under the same
;;; name. Unloading it stops it and deletes the packages that the file made,
;;; so that the next launch loads the file as it is by then.

(defstruct application
  name      ; a string, for the launcher's list
  function  ; what running it calls; NIL while its file is still to be loaded
  file      ; the name of the file that defines it, or NIL for one that the world defined
  packages  ; the packages that loading the file made
  threads)  ; the threads that it was launched in

(defun find-application (name)
  (find-if (lambda (application) (string-equal name (application-name application))) *applications*))

(defun the-application (name)
  (or (find-application name)
      (error "there is no application ~S: the ones that there are are ~S" name (applications))))

;; The launcher's list is about to change, and is shut first. The lock is held.
(defun shut-menu ()
  (when (and *running* *menu*)
    (menu-damaged)
    (setq *menu* nil)
    (settle)))

(defun define-application (name function)
  (unless (stringp name)
    (error "the name of an application is a string, and ~S is not one" name))
  (clara:with-lock-held (*lock*)
    (shut-menu)
    (let ((defined (find-application name)))
      (if defined
          (setf (application-function defined) function)
          (setq *applications* (append *applications* (list (make-application :name name :function function)))))))
  name)

;; There is an application of that name in that file: the launcher lists it
;; from now on, and the file is loaded when it is launched and has no
;; function yet. The file is to say (DEFINE-APPLICATION name function).
(defun install-application (name file)
  (unless (and (stringp name) (stringp file))
    (error "an application is installed by its name and the name of its file, two strings, and not ~S and ~S" name file))
  (clara:with-lock-held (*lock*)
    (shut-menu)
    (let ((defined (find-application name)))
      (if defined
          (setf (application-file defined) file)
          (setq *applications* (append *applications* (list (make-application :name name :file file)))))))
  name)

;; The names of the applications, in the order of the launcher's list.
(defun applications ()
  (mapcar #'application-name *applications*))

;; The name of the file of an application. One that was installed by a
;; name without a directory is a file of the system's own, wherever the
;; system keeps its files, which it says in *APPLICATION-DIRECTORY*
;; (lisp/system.lisp); on a machine without a disk nothing says so, and
;; LOAD finds the file by its bare name among what was read at boot.
(defun application-path (application)
  (let ((file (application-file application)) (bare t))
    (dotimes (i (length file))
      (when (char= (char file i) #\/)
        (setq bare nil)))
    (if (and bare *application-directory*)
        (concatenate 'string *application-directory* file)
        file)))

;; The function of an application, its file loaded first when that is still
;; to be done. The packages that are there after the file and were not
;; before are the application's, also when the file failed halfway.
(defun loaded-function (application)
  (clara:with-lock-held (*loading*)
    (unless (application-function application)
      (let ((before (list-all-packages)))
        (unwind-protect (load (application-path application))
          (setf (application-packages application)
                (append (remove-if (lambda (package) (member package before)) (list-all-packages))
                        (application-packages application)))))
      (unless (application-function application)
        (error "the file ~A was loaded, and it defined no application ~S" (application-path application)
               (application-name application))))
    (application-function application)))

(defun run-application (application arguments ready)
  (let ((*launching* ready))
    (unwind-protect (apply (loaded-function application) arguments)
      (when *launching*
        (clara:signal-event *launching*))
      (dolist (window (clara:with-lock-held (*lock*) (copy-list *made*)))
        (when (eq (window-thread window) (clara:current-thread))
          (close-window window))))))

;; Start the application of that name, with ARGUMENTS for its function, and
;; wait until its window is open, or until it is done without having opened
;; one. What comes back is its thread: stopping that closes its windows.
(defun launch (name &rest arguments)
  (let ((application (the-application name)))
    (unless *running*
      (error "there is no window manager to launch ~A with: (clara.windows:start) starts it"
             (application-name application)))
    (let* ((ready (clara:make-event (application-name application)))
           (thread (clara:make-thread (lambda () (run-application application arguments ready))
                                      :name (application-name application))))
      (clara:with-lock-held (*lock*)
        (setq *launched* (cons thread (remove-if-not #'clara:thread-alive-p *launched*)))
        (setf (application-threads application)
              (cons thread (remove-if-not #'clara:thread-alive-p (application-threads application)))))
      (clara:wait-event ready)
      thread)))

;; The application is stopped wherever it runs, and this waits until it has:
;; its windows are closed by then. What its file defined is forgotten with
;; the packages that the file made, which are deleted.
(defun forget (application)
  (let ((threads nil) (packages nil))
    (clara:with-lock-held (*loading*)
      (clara:with-lock-held (*lock*)
        (setq threads (application-threads application)
              packages (application-packages application))
        (setf (application-threads application) nil
              (application-packages application) nil)
        (when (application-file application)
          (setf (application-function application) nil)))
      (dolist (thread threads)
        (unless (eq thread (clara:current-thread))
          (clara:destroy-thread thread)))
      (dolist (thread threads)
        (unless (eq thread (clara:current-thread))
          (ignore-errors (clara:join-thread thread))))
      (dolist (package packages)
        (delete-package package)))))

;; An application that was installed is stopped and forgotten, and stays in
;; the launcher's list: the next launch loads its file again, as the file
;; is then.
(defun unload-application (name)
  (let ((application (the-application name)))
    (unless (application-file application)
      (error "the application ~A was defined in the world and has no file to load again: REMOVE-APPLICATION takes it out"
             (application-name application)))
    (forget application)
    (application-name application)))

;; The application is stopped and leaves the launcher's list.
(defun remove-application (name)
  (let ((application (the-application name)))
    (forget application)
    (clara:with-lock-held (*lock*)
      (shut-menu)
      (setq *applications* (remove application *applications*)))
    (application-name application)))

;;; Commands
;;;
;;; A command is a name in the launcher's list, under the applications, and
;;; a function of no arguments, which is called in a thread of its own when
;;; the name is picked. It is for what is done and over: nothing waits for
;;; it, and it opens no window that the launcher would know of.

(defun run-command (command)
  (clara:make-thread (cdr command) :name (car command)))

;; The command of that name, in letters of either case, or NIL.
(defun find-command (name)
  (find-if (lambda (command) (string-equal name (car command))) *commands*))

(defun define-command (name function)
  (unless (stringp name)
    (error "the name of a command is a string, and ~S is not one" name))
  (clara:with-lock-held (*lock*)
    (shut-menu)
    (let ((defined (find-command name)))
      (if defined
          (rplacd defined function)
          (setq *commands* (append *commands* (list (cons name function)))))))
  name)

(defun remove-command (name)
  (clara:with-lock-held (*lock*)
    (shut-menu)
    (setq *commands* (remove (find-command name) *commands*)))
  name)

;; The names of the commands, in the order of the launcher's list.
(defun commands ()
  (mapcar #'car *commands*))

;;; Starting and stopping

(defun running-p ()
  (and *running* t))

;; The window manager takes the screen, the keyboard and the pointer, and
;; launches the first application that was defined, which is the REPL
;; (lisp/terminal.lisp), so that there is somewhere to type. The console
;; goes on with the serial port alone. T when the window manager is
;; running after this, and NIL on a machine without a screen.
(defun start ()
  (let ((started nil))
    (clara:with-lock-held (*lock*)
      (let ((screen (clara.draw:screen)))
        (when (and screen (not *running*))
          (setq *back* (clara.draw:allocate-surface (clara.draw:surface-width screen) (clara.draw:surface-height screen))
                *desk* (clara.draw:color 45 41 66)
                *paper* (clara.draw:color 30 27 46)
                *ink* (clara.draw:color 232 227 244)
                *lit* (clara.draw:color 255 184 108)
                *dim* (clara.draw:color 74 68 102)
                *dark* (clara.draw:color 0 0 0)
                *name* (concatenate 'string (lisp-implementation-type) " " (lisp-implementation-version))
                *letters* (letters)
                *windows* nil
                *dirty* nil
                *launched* nil
                *opened* 0
                *menu* nil
                *drag* nil)
          (multiple-value-bind (x y buttons) (clara.input:pointer)
            (setq *pointer-x* x
                  *pointer-y* y
                  *buttons* buttons))
          (clara.console:lend-screen)
          (setq *running* t
                started t)
          (damaged 0 0 (clara.draw:surface-width screen) (clara.draw:surface-height screen))
          (settle)
          (clara.input:send-keys-to #'key-typed)
          (clara.input:send-pointer-to #'pointer-moved))))
    (when (and started *applications*)
      (launch (application-name (car *applications*))))
    (running-p)))

;; The window manager lets go of the screen, the keyboard and the pointer,
;; and the console has them again. The applications are stopped, and each
;; closes its windows as it goes; a window that some other thread opened is
;; no longer on the screen, and is still that thread's to close. T when
;; the window manager was running.
(defun stop ()
  (let ((threads nil) (stopped nil))
    (clara:with-lock-held (*lock*)
      (when *running*
        (setq stopped t
              threads *launched*
              *running* nil
              *launched* nil
              *dirty* nil
              *menu* nil
              *drag* nil)
        (dolist (window *windows*)
          (setf (window-open window) nil))
        (setq *windows* nil)
        (clara.input:send-keys-to nil)
        (clara.input:send-pointer-to nil)
        (clara.draw:free-surface *back*)
        (setq *back* nil)))
    (when stopped
      (clara.console:return-screen)
      ;; The thread that stops it may be an application's own: that one last.
      (dolist (thread threads)
        (unless (eq thread (clara:current-thread))
          (clara:destroy-thread thread)))
      (when (member (clara:current-thread) threads)
        (clara:destroy-thread (clara:current-thread))))
    stopped))

;; For the substrate, at every boot. What this file knew of a screen and of
;; windows is forgotten first: in a world that was saved and has started
;; again, that was another machine, whose pixels and threads stayed behind.
;; And when the world was saved with the window manager running, it is
;; started again, as far as this machine has a screen.
(defun resume ()
  (let ((wanted *running*))
    (dolist (window *made*)
      (setf (window-open window) nil
            (window-surface window) nil))
    (setq *running* nil
          *back* nil
          *windows* nil
          *made* nil
          *dirty* nil
          *launched* nil
          *menu* nil
          *drag* nil)
    (when wanted
      (if (start)
          (format t "windows: the window manager has the screen again, as it had when the world was saved~%")
          (format t "windows: this world was saved with the window manager running, and this machine has no screen~%")))
    (running-p)))
