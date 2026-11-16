;;;; input.lisp: keyboards, mice and tablets
;;;;
;;;; The driver for virtio's input devices (Virtual I/O Device
;;;; specification 1.2, 5.8, on top of lisp/virtio.lisp). Such a device
;;;; says what happens to it in events of 8 bytes, which are the events of
;;;; Linux's input layer: a type, a code and a value. A key went down or
;;;; up; the mouse moved so far along one axis; the pen is at this place
;;;; on another; and, after the events that belong together, one that says
;;;; so. The driver hands the device empty buffers through its first
;;;; queue, the device gives each back with an event in it, and a thread
;;;; for each device waits for its interrupt and takes them in.
;;;;
;;;; What is typed on a keyboard goes to the console as characters, which
;;;; is where the listener reads its lines (lisp/console.lisp). Where the
;;;; pointer is and which of its buttons are down is kept here for whoever
;;;; asks, POINTER, with an event for whoever waits for it to change,
;;;; POINTER-CHANGED: nothing draws a pointer yet.
;;;;
;;;; The codes are Linux's (include/uapi/linux/input-event-codes.h), and a
;;;; key's code is the key and not the character on it: which character a
;;;; key types is decided here, for a keyboard that is laid out as in the
;;;; United States.

(defpackage "CLARA.INPUT"
  (:use "COMMON-LISP")
  (:export "START" "DEVICES" "POINTER" "POINTER-CHANGED" "SET-POINTER-LIMITS" "KEY-CHARACTER"
           "*REPEAT-DELAY*" "*REPEAT-INTERVAL*"))
(in-package "CLARA.INPUT")

;;; Keys
;;;
;;; The characters of the keys with the codes 0 to 57, without Shift and
;;; with it; a space is a key that types nothing by itself. The numbers of
;;; the keypad's keys begin at 71.

(defvar *plain*   "  1234567890-=  qwertyuiop[]  asdfghjkl;'` \\zxcvbnm,./ *  ")
(defvar *shifted* "  !@#$%^&*()_+  QWERTYUIOP{}  ASDFGHJKL:\"~ |ZXCVBNM<>? *  ")
(defvar *keypad* "789-456+1230.")

;; The code of the character that a key types, or NIL for a key that types
;; none. Enter is a new line and Backspace takes a character back, as on
;; the serial port; Caps Lock turns the letters round and nothing else,
;; and Ctrl with a letter is the control character of that letter, so that
;; Ctrl-C is 3 here as it is there.
(defun key-character (key shift control caps)
  (cond ((= key 28) 10)
        ((= key 96) 10)
        ((= key 14) 8)
        ((= key 111) 127)
        ((= key 15) 9)
        ((= key 57) 32)
        ((= key 98) 47)
        ((<= 71 key 83) (char-code (char *keypad* (- key 71))))
        ((< 1 key 57)
         (let* ((plain (char-code (char *plain* key)))
                (letter (<= 97 plain 122)))
           (cond ((= plain 32) nil)
                 ((and control letter) (- plain 96))
                 ((if letter (not (eq shift caps)) shift) (char-code (char *shifted* key)))
                 (t plain))))))

;;; The pointer
;;;
;;; One for all the mice and tablets there are: a place, in pixels of the
;;; screen, and the buttons that are down, bit 0 for the left one, bit 1
;;; for the right, bit 2 for the middle.

(defvar *lock* (clara:make-lock "pointer"))
(defvar *changed* (clara:make-event "pointer"))
(defvar *width* 1024)  ; the pointer stays within these
(defvar *height* 768)
(defvar *x* 512)
(defvar *y* 384)
(defvar *buttons* 0)

;; Where the pointer is, and its buttons: three values.
(defun pointer ()
  (clara:with-lock-held (*lock*)
    (values *x* *y* *buttons*)))

;; The event that is signalled whenever any of the three has changed.
(defun pointer-changed ()
  *changed*)

;; The pointer moves on a screen of this size, and starts in its middle.
(defun set-pointer-limits (width height)
  (clara:with-lock-held (*lock*)
    (setq *width* width
          *height* height
          *x* (floor width 2)
          *y* (floor height 2)
          *buttons* 0)))

(defun move-pointer (x y buttons)
  (let ((x (max 0 (min x (1- *width*))))
        (y (max 0 (min y (1- *height*))))
        (changed nil))
    (clara:with-lock-held (*lock*)
      (unless (and (= x *x*) (= y *y*) (= buttons *buttons*))
        (setq *x* x
              *y* y
              *buttons* buttons
              changed t)))
    (when changed
      (clara:signal-event *changed*))))

;;; A device
;;;
;;; What the driver keeps for one: its queue, and what its events so far
;;; add up to.

(defstruct input
  device queue
  name
  kind              ; in words, for the boot report
  (shift 0)         ; which Shift and Ctrl keys are down: bit 0 the left one, bit 1 the right
  (control 0)
  caps              ; Caps Lock is on
  held              ; the key that is down and types a character, the last of them
  repeating         ; it has been down long enough to type again and again
  (dx 0) (dy 0)     ; how far a mouse has moved since the last report,
  ax ay             ; and where a pen is, as the tablet counts it, when that was said since
  (x-limits '(0 . 32767)) ; the least and the most a tablet counts along each axis
  (y-limits '(0 . 32767))
  (buttons 0))      ; which of the pointer's buttons are down on this device

(defvar *inputs* nil) ; the devices that START found and opened

;; A key went down (1) or up (0), or says that it is still down (2).
(defun key-event (input key value)
  (let ((down (/= value 0)))
    (cond ((or (= key 42) (= key 54))
           (let ((bit (if (= key 42) 1 2)))
             (setf (input-shift input)
                   (if down (logior (input-shift input) bit) (logand (input-shift input) (- 3 bit))))))
          ((or (= key 29) (= key 97))
           (let ((bit (if (= key 29) 1 2)))
             (setf (input-control input)
                   (if down (logior (input-control input) bit) (logand (input-control input) (- 3 bit))))))
          ((= key 58)
           (when (= value 1)
             (setf (input-caps input) (not (input-caps input)))))
          ((not down)
           (when (eql key (input-held input))
             (setf (input-held input) nil)))
          (t
           (when (= value 1)
             (setf (input-held input) key
                   (input-repeating input) nil))
           (type-key input key)))))

(defun type-key (input key)
  (let ((code (key-character key (/= 0 (input-shift input)) (/= 0 (input-control input)) (input-caps input))))
    (when code
      (clara.console:key-typed code))))

;; A place on a tablet's axis, as the place on the screen's.
(defun scale (value limits size)
  (let ((least (car limits)) (most (cdr limits)))
    (if (> most least)
        (floor (* (- (max least (min value most)) least) (1- size)) (- most least))
        0)))

;; One event of a device. Type 1 is a key or a button, by its code: the
;; buttons of a mouse begin at #x110. Type 2 is a move along an axis, 0
;; across and 1 down, by so much, and type 3 a place on an axis. Type 0
;; ends what belongs together, and that is when the pointer moves.
(defun handle-event (input type code value)
  (case type
    (1 (cond ((< code 256)
              (key-event input code value))
             ((<= #x110 code #x112)
              (let ((bit (ash 1 (- code #x110))))
                (setf (input-buttons input)
                      (if (zerop value)
                          (logand (input-buttons input) (- 7 bit))
                          (logior (input-buttons input) bit)))))))
    (2 (cond ((= code 0) (setf (input-dx input) (+ (input-dx input) value)))
             ((= code 1) (setf (input-dy input) (+ (input-dy input) value)))))
    (3 (cond ((= code 0) (setf (input-ax input) value))
             ((= code 1) (setf (input-ay input) value))))
    (0 (multiple-value-bind (x y) (pointer)
         (when (input-ax input)
           (setq x (scale (input-ax input) (input-x-limits input) *width*)))
         (when (input-ay input)
           (setq y (scale (input-ay input) (input-y-limits input) *height*)))
         ;; A button is down when it is down on any of the devices.
         (let ((buttons (input-buttons input)))
           (dolist (other *inputs*)
             (setq buttons (logior buttons (input-buttons other))))
           (move-pointer (+ x (input-dx input)) (+ y (input-dy input)) buttons))
         (setf (input-dx input) 0
               (input-dy input) 0
               (input-ax input) nil
               (input-ay input) nil)))))

;;; The device's side
;;;
;;; The registers of an input device (5.8.4) answer questions: the driver
;;; writes what it asks about to the first two, the third says how many
;;; bytes the answer has, and the answer is at 8.

(defun ask (device select subselect)
  (setf (clara.virtio:register-8 device 0) select
        (clara.virtio:register-8 device 1) subselect)
  (clara.virtio:register-8 device 2))

;; A value of 32 bits at an address, with its sign.
(defun signed-32 (address)
  (let ((value (clara.unsafe:memory-32 address)))
    (if (< value #x80000000) value (- value #x100000000))))

;; The name the device gives itself (question 1), as far as it is
;; characters that can be seen.
(defun device-name (device)
  (let ((name ""))
    (dotimes (i (ask device 1 0) name)
      (let ((code (clara.virtio:register-8 device (+ 8 i))))
        (when (< 31 code 127)
          (setq name (concatenate 'string name (string (code-char code)))))))))

;; The least and the most a tablet counts along an axis (question #x12).
(defun axis-limits (device axis)
  (if (>= (ask device #x12 axis) 8)
      (cons (clara.virtio:register-32 device 8) (clara.virtio:register-32 device 12))
      '(0 . 32767)))

;; What the device is, by the kinds of event it says it has (question
;; #x11, which answers with a bit for each code of a type): a keyboard has
;; the key A, which is code 30; a mouse moves along axes; a tablet has
;; places on them.
(defun describe-input (input)
  (let ((device (input-device input)))
    (setf (input-name input) (device-name device)
          (input-kind input)
          (cond ((and (> (ask device #x11 1) 3)
                      (/= 0 (logand (clara.virtio:register-8 device (+ 8 3)) 64)))
                 "a keyboard")
                ((plusp (ask device #x11 3)) "a tablet")
                ((plusp (ask device #x11 2)) "a mouse")
                (t "an input device of some other kind")))
    (when (plusp (ask device #x11 3))
      (setf (input-x-limits input) (axis-limits device 0)
            (input-y-limits input) (axis-limits device 1)))
    input))

;; Every buffer the device has given back: the event in it is handled, and
;; the device gets the buffer again.
(defun take-events (input)
  (let ((queue (input-queue input)) (taken nil))
    (loop
      (let ((buffer (clara.virtio:queue-take queue)))
        (unless buffer
          (return))
        (handle-event input (clara.unsafe:memory-16 buffer) (clara.unsafe:memory-16 (+ buffer 2))
                      (signed-32 (+ buffer 4)))
        (clara.virtio:queue-add queue (list (list buffer 8 t)) buffer)
        (setq taken t)))
    (when taken
      (clara.virtio:queue-notify queue))))

;;; The thread of a device
;;;
;;; It waits for the device's interrupt and takes in what has come. A
;;; device says once that a key went down, however long it stays down, so
;;; a key that is held is typed again from here: after *REPEAT-DELAY*
;;; milliseconds, and then every *REPEAT-INTERVAL*.

(defvar *repeat-delay* 400)
(defvar *repeat-interval* 40)

(defun serve (input)
  (let ((event (clara.virtio:device-event (input-device input))))
    (loop
      (if (clara:wait-event event (cond ((null (input-held input)) nil)
                                        ((input-repeating input) *repeat-interval*)
                                        (t *repeat-delay*)))
          (take-events input)
          (when (input-held input)
            (setf (input-repeating input) t)
            (type-key input (input-held input)))))))

;; Open a virtio input device: one queue of events, every one of its
;; descriptors with an empty buffer of 8 bytes for the device to fill in.
(defun open-input (pci)
  (let* ((device (clara.virtio:open-device pci))
         (queue (clara.virtio:open-queue device 0 64))
         (buffers (clara.unsafe:allocate-memory 1))
         (input (describe-input (make-input :device device :queue queue))))
    (dotimes (i (clara.virtio:queue-size queue))
      (let ((buffer (+ buffers (* 8 i))))
        (clara.virtio:queue-add queue (list (list buffer 8 t)) buffer)))
    (clara.virtio:start-device device)
    (clara.virtio:queue-notify queue)
    input))

(defun devices ()
  *inputs*)

;; Find the input devices among the PCI devices, and start a thread for
;; each. A device that does not start is said, and left alone: the serial
;; port is still there to type on.
(defun start ()
  (setq *inputs* nil)
  (multiple-value-bind (address width height) (clara.unsafe:framebuffer)
    (when address
      (set-pointer-limits width height)))
  (dolist (pci (clara.pci:devices))
    (when (eql (clara.virtio:device-type pci) 18)
      (handler-case
          (let ((input (open-input pci)))
            (setq *inputs* (append *inputs* (list input)))
            (clara:make-thread (lambda () (serve input))
                               :name (concatenate 'string "input " (clara.pci:location pci)))
            (format t "input: ~A is ~A, ~A~%" (clara.pci:location pci) (input-kind input) (input-name input)))
        (error (condition)
          (format t "input: ~A did not start: ~A~%" (clara.pci:location pci) condition)))))
  (when (null *inputs*)
    (format t "input: no keyboard and no mouse that has a driver here: the serial port is where to type~%"))
  *inputs*)
