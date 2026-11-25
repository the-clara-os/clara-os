;;;; console.lisp: the console
;;;;
;;;; What Lisp writes goes to the serial port and to the screen, and what
;;;; is typed on the serial port comes back a line at a time. Both ends are
;;;; drivers written in Lisp, on top of CLARA.UNSAFE: the serial port is a
;;;; UART whose registers are I/O ports on one machine and memory on the
;;;; other, and the screen is a framebuffer, memory with 32 bits to the
;;;; pixel. Typing arrives as an interrupt, which is an event that this
;;;; file waits for, and from the driver of a keyboard, when the machine
;;;; has one (lisp/input.lisp).
;;;;
;;;; The substrate has a console of its own (kernel/console.c, fbcon.c),
;;;; which prints the boot report before there is a Lisp to run this, and
;;;; the kernel's last words when something goes wrong. START takes the
;;;; screen over from it, at the place where it left off, and STOP hands it
;;;; back. The two draw the same characters in the same cells.
;;;;
;;;; The screen can go to somebody else for a time, who draws on all of it:
;;;; the window manager (lisp/windows.lisp), with LEND-SCREEN. The console
;;;; goes on with the serial port alone until it has the screen again, and
;;;; a console in a window is another file's (lisp/terminal.lisp), which
;;;; puts its lines together the way this one does, READ-EDITED-LINE.
;;;;
;;;; This file loads under SBCL as well, where lisp/host/ stands in for the
;;;; machine, and the tests there look at what it puts on a screen that is
;;;; a vector.

(defpackage "CLARA.CONSOLE"
  (:use "COMMON-LISP")
  (:export "START" "STOP" "WRITE-TEXT" "READ-TEXT-LINE" "USE-SERIAL" "USE-SCREEN" "MAKE-CONSOLE-STREAM"
           "KEY-TYPED" "READ-EDITED-LINE" "LEND-SCREEN" "RETURN-SCREEN"))
(in-package "CLARA.CONSOLE")

;;; The serial port
;;;
;;; Two UARTs. The 16550 of a PC has eight registers on I/O ports: data in
;;; the first, and in the sixth the line status, whose bit 5 says that the
;;; next byte can be handed over. The PL011 of an ARM machine has its
;;; registers in memory, four bytes apart: data in the first, and at #x18
;;; the flags, whose bit 5 says that there is no room for another byte.
;;; The substrate set both up at boot (kernel/arch/), and takes in what
;;; arrives there, from the timer's interrupt: only sending is done here.

(defvar *serial-kind* nil)  ; :NS16550 or :PL011; NIL when there is no serial port to write to
(defvar *serial-base* 0)    ; its first I/O port, or the address of its registers

(defun use-serial (kind base)
  (setq *serial-kind* kind
        *serial-base* base))

(defun serial-busy-p ()
  (case *serial-kind*
    (:ns16550 (zerop (logand (clara.unsafe:port-8 (+ *serial-base* 5)) #x20)))
    (:pl011 (/= 0 (logand (clara.unsafe:memory-32 (+ *serial-base* #x18)) #x20)))))

(defun serial-send (byte)
  (loop
    (unless (serial-busy-p)
      (return)))
  (case *serial-kind*
    (:ns16550 (setf (clara.unsafe:port-8 *serial-base*) byte))
    (:pl011 (setf (clara.unsafe:memory-32 *serial-base*) byte))))

;; A character goes out as UTF-8, and a new line as a carriage return and
;; a line feed, which is what a terminal expects.
(defun serial-send-character (code)
  (cond ((= code 10)
         (serial-send 13)
         (serial-send 10))
        ((< code #x80)
         (serial-send code))
        ((< code #x800)
         (serial-send (logior #xc0 (ash code -6)))
         (serial-send (logior #x80 (logand code #x3f))))
        ((< code #x10000)
         (serial-send (logior #xe0 (ash code -12)))
         (serial-send (logior #x80 (logand (ash code -6) #x3f)))
         (serial-send (logior #x80 (logand code #x3f))))
        (t
         (serial-send (logior #xf0 (ash code -18)))
         (serial-send (logior #x80 (logand (ash code -12) #x3f)))
         (serial-send (logior #x80 (logand (ash code -6) #x3f)))
         (serial-send (logior #x80 (logand code #x3f))))))

;;; The screen
;;;
;;; A grid of cells, each as large as a glyph of the font, in the middle of
;;; the screen. A character is drawn where the cursor is, and the cursor
;;; moves on; past the last row, every row moves up by one, which is done
;;; by copying the pixels. Nothing remembers what the screen shows.

(defvar *screen* nil)   ; the address of the screen's first pixel; NIL when there is no screen to draw on
(defvar *pitch* 0)      ; bytes from one row of pixels to the next
(defvar *top* 0)        ; the address of the first row of pixels of the grid
(defvar *left* 0)       ; bytes from the start of a row of pixels to the grid
(defvar *columns* 0)    ; the size of the grid, in cells
(defvar *rows* 0)
(defvar *column* 0)     ; where the next character goes; past the last column, it starts a new row first
(defvar *row* 0)
(defvar *ink* 0)        ; the pixel of a glyph,
(defvar *paper* 0)      ; and the pixel around it
(defvar *reading* nil)  ; a line is being read: the cursor shows, and Ctrl-C gives the line up
(defvar *lent* nil)     ; the screen is somebody else's for the time being: LEND-SCREEN
(defvar *cursor* nil)   ; the address of the cursor that is on the screen, or NIL when none is

;; An 8-bit colour channel, moved to the bits of a pixel that MASK selects.
(defun channel (mask value)
  (if (zerop mask)
      0
      (let ((shift 0) (bits 0))
        (loop
          (unless (zerop (logand mask (ash 1 shift)))
            (return))
          (setq shift (1+ shift)))
        (loop
          (when (zerop (logand mask (ash 1 (+ shift bits))))
            (return))
          (setq bits (1+ bits)))
        ;; Its highest bits, when the pixel has fewer than eight for it.
        (ash (ash value (- bits 8)) shift))))

;; The pixel of a colour, given as #xRRGGBB, on a screen whose pixels keep
;; red, green and blue in the bits that the three masks select.
(defun pixel (colour red green blue)
  (logior (channel red (logand (ash colour -16) #xff))
          (channel green (logand (ash colour -8) #xff))
          (channel blue (logand colour #xff))))

;; A screen of WIDTH by HEIGHT pixels of 32 bits at ADDRESS, PITCH bytes
;; from one row of them to the next, with the cursor at ROW and COLUMN.
;; The grid and the colours are those of the substrate's console
;; (kernel/fbcon.c), so that one can go on where the other left off.
(defun use-screen (address width height pitch red green blue row column)
  (let* ((columns (min (floor width clara.font:+width+) 256))
         (rows (min (floor height clara.font:+height+) 128)))
    (setq *pitch* pitch
          *columns* columns
          *rows* rows
          *top* (+ address (* pitch (floor (- height (* rows clara.font:+height+)) 2)))
          *left* (* 4 (floor (- width (* columns clara.font:+width+)) 2))
          *row* (min row (1- rows))
          *column* (min column columns)
          *paper* (pixel #x1e1b2e red green blue)
          *ink* (pixel #xe8e3f4 red green blue)
          *screen* address)))

;; The glyph of a character, at the cursor. A character that the font has
;; no glyph for gets the box that comes after the last glyph.
(defun draw (code)
  (clara.unsafe:expand-bits-32
   (+ *top* (* *row* clara.font:+height+ *pitch*) *left* (* *column* clara.font:+width+ 4))
   *pitch*
   clara.font:*glyphs*
   (* clara.font:+height+
      (- (if (<= clara.font:+first+ code clara.font:+last+) code (1+ clara.font:+last+))
         clara.font:+first+))
   clara.font:+height+
   clara.font:+width+
   *ink*
   *paper*))

;; Every row moves up by one, and the last one is blank.
(defun scroll ()
  (let* ((row (* clara.font:+height+ *pitch*))
         (kept (* (1- *rows*) row)))
    (clara.unsafe:copy-memory *top* (+ *top* row) kept)
    (clara.unsafe:fill-memory-32 (+ *top* kept) (floor row 4) *paper*)))

(defun new-row ()
  (setq *column* 0)
  (if (< (1+ *row*) *rows*)
      (setq *row* (1+ *row*))
      (scroll)))

(defun show (code)
  (cond ((= code 10) (new-row))
        ((= code 13) (setq *column* 0))
        ((= code 8)
         (when (plusp *column*)
           (setq *column* (1- *column*))))
        ((= code 9)
         (loop
           (show 32)
           (when (or (zerop (mod *column* 8)) (>= *column* *columns*))
             (return))))
        (t
         (when (= *column* *columns*)
           (new-row))
         (draw code)
         (setq *column* (1+ *column*)))))

;;; The cursor
;;;
;;; While a line is being read, a bar under the cell where the next
;;; character goes says where that is: the lowest two rows of the cell's
;;; pixels, in ink. It is taken away before anything is drawn and put back
;;; after, so it never moves up with a row. At the end of a row that is
;;; full there is no cell for it, and it does not show.

(defun paint-cursor (address pixel)
  (clara.unsafe:fill-memory-32 address clara.font:+width+ pixel)
  (clara.unsafe:fill-memory-32 (+ address *pitch*) clara.font:+width+ pixel))

(defun hide-cursor ()
  (when *cursor*
    (paint-cursor *cursor* *paper*)
    (setq *cursor* nil)))

(defun show-cursor ()
  (when (and *screen* *reading* (< *column* *columns*))
    (setq *cursor* (+ *top* (* (- (* (1+ *row*) clara.font:+height+) 2) *pitch*)
                      *left* (* *column* clara.font:+width+ 4)))
    (paint-cursor *cursor* *ink*)))

;;; Writing
;;;
;;; A string goes to both, a character at a time, and no other thread's
;;; string gets in between.

(defvar *lock* (clara:make-lock "console"))

(defun write-text (string)
  (clara:with-lock-held (*lock*)
    (hide-cursor)
    (dotimes (i (length string))
      (let ((code (char-code (char string i))))
        (serial-send-character code)
        (when *screen*
          (show code))))
    (show-cursor))
  string)

;;; Reading
;;;
;;; The substrate takes in the bytes that arrive on the serial port and
;;; signals an event when it has (kernel/console.c). A line is put together
;;; from them here, and echoed as it is typed. Backspace or Delete takes
;;; the last character back, a tab counts as a space, and the other control
;;; characters are dropped, as are the keys of a keyboard that type no
;;; character, the arrows among them. Ctrl-D at the start of a line means
;;; that no more is coming, and Ctrl-C anywhere gives the line up.
;;;
;;; A keyboard has a driver of its own, which hands in the characters that
;;; are typed on it, KEY-TYPED. They are read along with the bytes of the
;;; serial port, whichever is there first.

(defconstant +line-limit+ 4096) ; characters in a line; what is typed past that is dropped
(defconstant +keys-limit+ 1024) ; characters from a keyboard that wait to be read; what is typed past that is dropped

(defvar *typed* nil)        ; the event that says bytes have arrived, or keys
(defvar *keys* nil)         ; the codes of the characters typed on a keyboard and not read yet, the oldest first
(defvar *keys-lock* (clara:make-lock "keys"))
(defvar *after-return* nil) ; the last line ended with a carriage return: a line feed right after it is its other half
(defvar *stream* nil)       ; where what is typed is echoed
(defvar *rubout* (concatenate 'string (string #\Backspace) " " (string #\Backspace)))

;; From the driver of a keyboard: the character with this code was typed.
;; Ctrl-C does there what it does on the serial port. While a line is
;; being read it is a character like the others, which gives the line up;
;; at any other time it is no character at all, and stops what the thread
;; that reads from the console is computing.
(defun key-typed (code)
  (if (and (= code 3) (not *reading*))
      (clara.unsafe:keyboard-break)
      (progn
        (clara:with-lock-held (*keys-lock*)
          (when (< (length *keys*) +keys-limit+)
            (setq *keys* (append *keys* (list code)))))
        (when *typed*
          (clara:signal-event *typed*))))
  code)

(defun next-key ()
  (clara:with-lock-held (*keys-lock*)
    (let ((code (car *keys*)))
      (setq *keys* (cdr *keys*))
      code)))

(defun next-byte ()
  (loop
    (let ((byte (clara.unsafe:serial-byte)))
      (when byte
        (return byte)))
    (clara:wait-event *typed*)))

;; The code of the next character that was typed: on a keyboard, or else
;; on the serial port. What is typed there is UTF-8; a byte that cannot
;; begin a character is passed over.
(defun next-code ()
  (loop
    (let ((key (and *keys* (next-key))))
      (when key
        (return key)))
    (let ((byte (clara.unsafe:serial-byte)))
      (cond ((null byte)
             (clara:wait-event *typed*))
            ((< byte #x80)
             (return byte))
            ((>= byte #xc0)
             (let ((more (cond ((< byte #xe0) 1) ((< byte #xf0) 2) (t 3)))
                   (code (logand byte (cond ((< byte #xe0) #x1f) ((< byte #xf0) #x0f) (t #x07)))))
               (dotimes (i more)
                 (setq code (logior (ash code 6) (logand (next-byte) #x3f))))
               (return code)))))))

;; The next code, for a line: a line feed that comes right after a
;; carriage return is the other half of the end of the line before, and is
;; passed over.
(defun next-typed ()
  (loop
    (let ((code (next-code)))
      (if (and (= code 10) *after-return*)
          (setq *after-return* nil)
          (progn
            (setq *after-return* (= code 13))
            (return code))))))

;; A line, put together from the codes of the characters that were typed,
;; which NEXT gives one at a time, and echoed to STREAM as it grows: the
;; line without its end, or NIL when no more is coming. It is how a line
;; is typed on this console, and on a console in a window, which has other
;; codes and another stream. Such a window shows more of a line than its
;; characters, and echoes for itself: ECHO, when there is one, is called
;; in place of writing to STREAM whenever the line has gained a character
;; or lost its last, with the line as it is now and the character that it
;; gained, or NIL.
;;
;; A key that types no character means nothing to a line, unless RECALL
;; says otherwise: when there is one, it is called with the code of such a
;; key and with the line as it is, and gives the line that is to stand in
;; its place, or NIL. That is how a line that was typed before comes back
;; in a window, at an arrow (lisp/terminal.lisp). The line that is there is
;; taken back then, a character at a time, and the other one typed after
;; it, as a hand would do it: whoever echoes is told nothing new, and the
;; line holds what could have been typed and no more.
(defun read-edited-line (next stream &optional echo recall)
  (let ((line ""))
    (flet ((lose ()
             (setq line (subseq line 0 (1- (length line))))
             (if echo
                 (funcall echo line nil)
                 (write-string *rubout* stream)))
           (gain (code)
             (let ((character (if (= code 9) #\Space (and (>= code 32) (< code char-code-limit) (code-char code)))))
               (when (and character (< (length line) +line-limit+))
                 (setq line (concatenate 'string line (string character)))
                 (if echo
                     (funcall echo line character)
                     (write-string (string character) stream))))))
      (loop
        (let ((code (funcall next)))
          (cond ((or (= code 13) (= code 10))
                 (write-string (string #\Newline) stream)
                 (return line))
                ((= code 4)
                 (when (zerop (length line))
                   (return nil)))
                ((= code 3)
                 (write-string "^C" stream)
                 (write-string (string #\Newline) stream)
                 (error 'clara:keyboard-interrupt))
                ((or (= code 8) (= code 127))
                 (when (plusp (length line))
                   (lose)))
                ((>= code char-code-limit)
                 (let ((other (and recall (funcall recall code line))))
                   (when other
                     (dotimes (i (length line))
                       (lose))
                     (dotimes (i (length other))
                       (gain (char-code (char other i)))))))
                (t
                 (gain code))))))))

;; The next line that was typed, without its end, or NIL when no more is
;; coming. While a line is being read, Ctrl-C is a byte like the others,
;; which gives the line up; at any other time it stops what the thread is
;; computing (CLARA.UNSAFE:SERIAL-BREAK says which, and *READING* says it
;; to KEY-TYPED). The cursor shows for as long.
(defun read-text-line ()
  (let ((computing (clara.unsafe:serial-break nil)))
    (setq *reading* t)
    (clara:with-lock-held (*lock*)
      (show-cursor))
    (unwind-protect (read-edited-line #'next-typed *stream*)
      (setq *reading* nil)
      (clara:with-lock-held (*lock*)
        (hide-cursor))
      (clara.unsafe:serial-break computing))))

;;; The stream that is both

(defun make-console-stream ()
  (setq *stream* (clara:make-stream :write-string #'write-text :read-line #'read-text-line)))

;; Take the machine's console over from the substrate: from here on,
;; *STANDARD-OUTPUT* and *STANDARD-INPUT* are this file's. What this file
;; knew of a screen, of a cursor on it and of keys that were typed is
;; forgotten first: in a world that was saved and has started again, that
;; was another machine's.
(defun start ()
  (setq *screen* nil
        *lent* nil
        *cursor* nil
        *reading* nil
        *keys* nil
        *after-return* nil)
  (multiple-value-bind (kind base) (clara.unsafe:serial-device)
    (use-serial kind base))
  (setq *typed* (clara.unsafe:interrupt-event :serial))
  (multiple-value-bind (address width height pitch red green blue) (clara.unsafe:framebuffer)
    (when address
      (multiple-value-bind (row column) (clara.unsafe:take-screen)
        (when row
          (use-screen address width height pitch red green blue row column)))))
  (make-console-stream)
  (setq *standard-output* *stream*
        *standard-input* *stream*)
  *stream*)

;; The screen goes to whoever asks, to draw on all of it, and this console
;; goes on with the serial port alone. NIL when it had no screen to lend.
(defun lend-screen ()
  (clara:with-lock-held (*lock*)
    (when *screen*
      (hide-cursor)
      (setq *screen* nil
            *lent* t))))

;; And it has the screen again: all of it is cleared, whatever was drawn
;; there meanwhile, and the next character goes to the first cell.
(defun return-screen ()
  (clara:with-lock-held (*lock*)
    (when *lent*
      (setq *lent* nil)
      (multiple-value-bind (address width height pitch red green blue) (clara.unsafe:framebuffer)
        (when address
          (clara.unsafe:fill-rectangle-32 address pitch width height (pixel #x1e1b2e red green blue))
          (use-screen address width height pitch red green blue 0 0)
          (show-cursor)
          t)))))

;; Hand the screen back to the substrate, for its last line. While it is
;; lent to somebody else there is nothing to hand back: the substrate says
;; its last line on the serial port, and the screen stays as it is.
(defun stop ()
  (when *screen*
    (hide-cursor)
    (clara.unsafe:give-screen *row* *column*)
    (setq *screen* nil))
  nil)
