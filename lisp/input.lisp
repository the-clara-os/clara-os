;;;; input.lisp: keyboards, mice and tablets
;;;;
;;;; Two kinds of them: virtio's, which are devices on the PCI bus, and
;;;; the ones that hang from a USB controller (lisp/usb.lisp), further
;;;; down. Both end in the same events, and in one pointer.
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
;;;; POINTER-CHANGED. Both can be sent somewhere else, to a function that
;;;; is called for every character and one that is called for every change
;;;; of the pointer: the window manager asks for that (lisp/windows.lisp),
;;;; and it is what draws the pointer.
;;;;
;;;; The codes are Linux's (include/uapi/linux/input-event-codes.h), and a
;;;; key's code is the key and not the character on it: which character a
;;;; key types is decided here, for a keyboard that is laid out as in the
;;;; United States. A key that types no character, an arrow for one, is
;;;; handed on all the same, as a code that no character has.

(defpackage "CLARA.INPUT"
  (:use "COMMON-LISP")
  (:export "START" "DEVICES" "POINTER" "POINTER-CHANGED" "SET-POINTER-LIMITS" "KEY-CHARACTER"
           "SEND-KEYS-TO" "SEND-POINTER-TO" "*REPEAT-DELAY*" "*REPEAT-INTERVAL*"
           "+UP+" "+DOWN+" "+LEFT+" "+RIGHT+" "+HOME+" "+END+" "+PAGE-UP+" "+PAGE-DOWN+" "+INSERT+" "+F1+" "+ALT+"))
(in-package "CLARA.INPUT")

;;; Keys
;;;
;;; The characters of the keys with the codes 0 to 57, without Shift and
;;; with it; a space is a key that types nothing by itself. The numbers of
;;; the keypad's keys begin at 71.

;;; A key that types no character has a code as well, for whoever can use
;;; it, an editor or the window manager: one from CHAR-CODE-LIMIT on, which
;;; is past the last code that a character can have. And a key that is
;;; typed while Alt is held has +ALT+ added to its code, whatever it is.

(defconstant +up+ (+ char-code-limit 1))
(defconstant +down+ (+ char-code-limit 2))
(defconstant +left+ (+ char-code-limit 3))
(defconstant +right+ (+ char-code-limit 4))
(defconstant +home+ (+ char-code-limit 5))
(defconstant +end+ (+ char-code-limit 6))
(defconstant +page-up+ (+ char-code-limit 7))
(defconstant +page-down+ (+ char-code-limit 8))
(defconstant +insert+ (+ char-code-limit 9))
(defconstant +f1+ (+ char-code-limit 32)) ; and the eleven function keys after it follow, F12 being 11 more
(defconstant +alt+ #x200000)

(defvar *plain*   "  1234567890-=  qwertyuiop[]  asdfghjkl;'` \\zxcvbnm,./ *  ")
(defvar *shifted* "  !@#$%^&*()_+  QWERTYUIOP{}  ASDFGHJKL:\"~ |ZXCVBNM<>? *  ")
(defvar *keypad* "789-456+1230.")

;; The code of the character that a key types, the code of a key that
;; types none and has one of its own, or NIL for any other key. Enter is a
;; new line and Backspace takes a character back, as on the serial port;
;; Escape and Delete are the characters that ASCII has for them; Caps Lock
;; turns the letters round and nothing else, and Ctrl with a letter is the
;; control character of that letter, so that Ctrl-C is 3 here as it is
;; there.
(defun key-character (key shift control caps)
  (cond ((= key 28) 10)
        ((= key 96) 10)
        ((= key 14) 8)
        ((= key 111) 127)
        ((= key 15) 9)
        ((= key 57) 32)
        ((= key 98) 47)
        ((= key 1) 27)
        ((= key 103) +up+)
        ((= key 108) +down+)
        ((= key 105) +left+)
        ((= key 106) +right+)
        ((= key 102) +home+)
        ((= key 107) +end+)
        ((= key 104) +page-up+)
        ((= key 109) +page-down+)
        ((= key 110) +insert+)
        ((<= 59 key 68) (+ +f1+ (- key 59)))
        ((<= 87 key 88) (+ +f1+ 10 (- key 87)))
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
(defvar *keys-to* nil)     ; a function of a character's code, for what is typed; NIL means the console
(defvar *pointer-to* nil)  ; a function of the pointer's place and its buttons, called when any has changed, or NIL

;; What is typed goes to FUNCTION from now on, a character's code to the
;; call, and with NIL to the console again. The function is called in the
;; thread of the keyboard, and so is the one that is told of the pointer:
;; what either does wrong is said, and the device goes on.
(defun send-keys-to (function)
  (setq *keys-to* function))

(defun send-pointer-to (function)
  (setq *pointer-to* function))

(defun deliver (function &rest arguments)
  (handler-case (apply function arguments)
    (error (condition)
      (fresh-line)
      (format t "input: what was typed or pointed at came to nothing: ~A~%" condition))))

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

;; The pointer goes to a place, where one is given, and from there by so
;; much. Where it is now is read and written with the lock held all the
;; while: each device has a thread of its own, and a mouse and a tablet
;; that move the pointer at the same moment would otherwise undo each
;; other, the one writing back the place that it read before the other
;; moved.
(defun move-pointer (to-x to-y by-x by-y buttons)
  (let ((x nil) (y nil) (changed nil))
    (clara:with-lock-held (*lock*)
      (setq x (max 0 (min (+ (or to-x *x*) by-x) (1- *width*)))
            y (max 0 (min (+ (or to-y *y*) by-y) (1- *height*))))
      (unless (and (= x *x*) (= y *y*) (= buttons *buttons*))
        (setq *x* x
              *y* y
              *buttons* buttons
              changed t)))
    ;; Whoever waits for the event finds that the function has been told.
    (when changed
      (when *pointer-to*
        (deliver *pointer-to* x y buttons))
      (clara:signal-event *changed*))))

;;; A device
;;;
;;; What the driver keeps for one: its queue, and what its events so far
;;; add up to.

(defstruct input
  device queue
  name
  kind              ; in words, for the boot report
  (shift 0)         ; which Shift, Ctrl and Alt keys are down: bit 0 the left one, bit 1 the right
  (control 0)
  (alt 0)
  caps              ; Caps Lock is on
  held              ; the key that is down and types a character, the last of them
  repeating         ; it has been down long enough to type again and again
  (dx 0) (dy 0)     ; how far a mouse has moved since the last report,
  ax ay             ; and where a pen is, as the tablet counts it, when that was said since
  (x-limits '(0 . 32767)) ; the least and the most a tablet counts along each axis
  (y-limits '(0 . 32767))
  (buttons 0)       ; which of the pointer's buttons are down on this device
  usb               ; of a device of USB: the interface that it is,
  fields            ; what its reports are made of,
  numbered          ; whether a report begins with its number,
  keys              ; the keys that were down in its last report,
  reports           ; the reports that have come and are not taken in yet, the oldest first,
  lock event        ; what keeps that list whole, and what says that it has grown,
  thread)           ; and the thread that takes them in

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
          ((or (= key 56) (= key 100))
           (let ((bit (if (= key 56) 1 2)))
             (setf (input-alt input)
                   (if down (logior (input-alt input) bit) (logand (input-alt input) (- 3 bit))))))
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
      (when (/= 0 (input-alt input))
        (setq code (+ code +alt+)))
      (if *keys-to*
          (deliver *keys-to* code)
          (clara.console:key-typed code)))))

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
    (0 (let ((buttons (input-buttons input)))
         ;; A button is down when it is down on any of the devices.
         (dolist (other *inputs*)
           (setq buttons (logior buttons (input-buttons other))))
         (move-pointer (and (input-ax input) (scale (input-ax input) (input-x-limits input) *width*))
                       (and (input-ay input) (scale (input-ay input) (input-y-limits input) *height*))
                       (input-dx input) (input-dy input) buttons)
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

(defun serve (input event take)
  (loop
    (if (clara:wait-event event (cond ((null (input-held input)) nil)
                                      ((input-repeating input) *repeat-interval*)
                                      (t *repeat-delay*)))
        (funcall take input)
        (when (input-held input)
          (setf (input-repeating input) t)
          (type-key input (input-held input))))))

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

;;; Keyboards, mice and tablets of USB
;;;
;;; Such a device is an interface of the class 3 of a USB device (Device
;;; Class Definition for Human Interface Devices, version 1.11; the
;;; numbers of what a thing is are in the HID Usage Tables). It says what
;;; has happened to it in reports of a few bytes, and what a report is
;;; made of in a description that it gives when asked: items, each a byte
;;; that says what the item is and how many bytes of a number follow it.
;;; Some items say what the next values are about: the page of things that
;;; they are among (1 a pointer's axes, 7 the keys of a keyboard, 9
;;; buttons), which things of that page, the least and the most a value
;;; can be, how many bits it has, how many values there are, and which
;;; report they are in, on a device that numbers its reports. An item of
;;; the kind "input" then stands for that many bits of a report, and they
;;; follow each other in the report as the items do in the description.
;;;
;;; So a keyboard is not known by the report that keyboards mostly have,
;;; but by what it says of its own, and a tablet is told from a mouse by
;;; saying where its pen is, and not how far it moved.

(defstruct field
  report            ; the number of the report that it is in, or 0
  at                ; the bit of the report at which it begins,
  size count        ; how many bits a value has, and how many values there are
  variable          ; a value is the state of one thing; otherwise it names a thing that is down
  relative          ; a value says how far, and not where
  page              ; what kind of things
  usages            ; which things, one for each value, the last for the rest,
  lowest            ; or the first of them, the others following by number
  least most)       ; the least and the most a value can be

;; The fields of a device's reports, from the bytes of its description
;; (6.2.2). The top two bits of an item's first byte and the two under
;; them say what it is; the lowest two how many bytes follow, where 3
;; means four. An item of the kind 1 holds for all that comes after it,
;; one of the kind 2 for the next item of the kind 0, and of those the one
;; with the number 8 is the input: bit 0 of its value says that the bits
;; mean nothing, bit 1 that each value is a thing's state, bit 2 that a
;; value is a distance.
(defun read-fields (bytes)
  (let ((fields nil) (at 0) (places nil) (kept nil)
        (page 0) (least 0) (most 0) (plain-most 0) (size 0) (count 0) (report 0)
        (usages nil) (lowest nil))
    (loop
      (when (>= at (length bytes))
        (return))
      (let* ((head (svref bytes at))
             (length (case (logand head 3) (0 0) (1 1) (2 2) (t 4)))
             (kind (logand (ash head -2) 3))
             (number (ash head -4))
             (value 0) (signed 0))
        (when (> (+ at 1 length) (length bytes))
          (return))
        (dotimes (i length)
          (setq value (+ value (ash (svref bytes (+ at 1 i)) (* 8 i)))))
        (setq signed (if (and (plusp length) (>= value (ash 1 (1- (* 8 length)))))
                         (- value (ash 1 (* 8 length)))
                         value))
        (cond ((= head #xfe)
               ;; An item of the long kind says its own length in the next byte, and nothing here reads one.
               (setq length (+ 2 (if (< (1+ at) (length bytes)) (svref bytes (1+ at)) 0))))
              ((= kind 1)
               (case number
                 (0 (setq page value))
                 (1 (setq least signed))
                 (2 (setq most signed
                          plain-most value))
                 (7 (setq size value))
                 (8 (setq report value))
                 (9 (setq count value))
                 (10 (setq kept (cons (list page least most plain-most size count report) kept)))
                 (11 (when kept
                       (let ((was (car kept)))
                         (setq kept (cdr kept)
                               page (nth 0 was) least (nth 1 was) most (nth 2 was) plain-most (nth 3 was)
                               size (nth 4 was) count (nth 5 was) report (nth 6 was)))))))
              ((= kind 2)
               (case number
                 (0 (setq usages (append usages (list (logand value #xffff)))))
                 (1 (setq lowest (logand value #xffff)))))
              ((= kind 0)
               (when (= number 8)
                 (let* ((place (assoc report places)) (bit (if place (cdr place) 0)))
                   (when (and (zerop (logand value 1)) (<= 1 size 32))
                     (setq fields (cons (make-field :report report :at bit :size size :count count
                                                    :variable (/= 0 (logand value 2))
                                                    :relative (/= 0 (logand value 4))
                                                    :page page :usages usages :lowest lowest
                                                    ;; A most that is under the least was meant without a sign: 255, written in one byte.
                                                    :least least :most (if (< most least) plain-most most))
                                        fields)))
                   (if place
                       (rplacd place (+ bit (* size count)))
                       (setq places (cons (cons report (* size count)) places)))))
               (setq usages nil
                     lowest nil)))
        (setq at (+ at 1 length))))
    (reverse fields)))

;; Which thing the value with the number I of a field is about.
(defun usage-of (field i)
  (let ((usages (field-usages field)))
    (cond ((null usages) (+ (or (field-lowest field) 0) i))
          ((< i (length usages)) (nth i usages))
          (t (car (last usages))))))

;; The value of SIZE bits that begins at the bit AT of a report, with a
;; sign when SIGNED is true. Bits that the report is too short for are 0.
(defun report-bits (bytes at size signed)
  (let ((value 0))
    (dotimes (i size)
      (let ((byte (floor (+ at i) 8)))
        (when (and (< byte (length bytes))
                   (/= 0 (logand (svref bytes byte) (ash 1 (mod (+ at i) 8)))))
          (setq value (+ value (ash 1 i))))))
    (if (and signed (>= value (ash 1 (1- size))))
        (- value (ash 1 size))
        value)))

;; The key of a keyboard, as this file knows keys, for its number on the
;; page of keys (HID Usage Tables, 10): the letters come first there, in
;; the order of the alphabet, and the keys that are held with others have
;; the numbers from 224 on. NIL for a key that types nothing here.
(defvar *usage-keys*
  (vector nil nil nil nil 30 48 46 32 18 33 34 35 23 36 37 38 50 49 24 25 16 19 31 20 22 47 17 45 21 44
          2 3 4 5 6 7 8 9 10 11
          28 1 14 15 57 12 13 26 27 43 43 39 40 41 51 52 53 58
          59 60 61 62 63 64 65 66 67 68 87 88
          99 70 119 110 102 104 111 107 109 106 105 108 103
          69 98 55 74 78 96 79 80 81 75 76 77 71 72 73 82 83 86 127))

(defvar *usage-held* (vector 29 42 56 125 97 54 100 126))

(defun usage-key (usage)
  (cond ((< -1 usage (length *usage-keys*)) (svref *usage-keys* usage))
        ((<= 224 usage 231) (svref *usage-held* (- usage 224)))))

;; One report of a device. Every field of the report with its number is
;; gone through. A keyboard says which keys are down, and not what
;; happened: the keys that are no longer among them went up, and the new
;; ones went down, in that order. One that says more keys are down than it
;; can tell apart, with the numbers 1 to 3 where keys should be, says
;; nothing about any of them. What a report says of buttons and axes is
;; the events of a mouse or a tablet, and the pointer moves once for the
;; whole report.
(defun usb-report (input bytes)
  (let* ((numbered (input-numbered input))
         (report (cond ((not numbered) 0)
                       ((plusp (length bytes)) (svref bytes 0))
                       (t -1)))
         (base (if numbered 8 0))
         (down nil) (keys nil) (too-many nil) (pointer nil))
    (dolist (field (input-fields input))
      (when (= (field-report field) report)
        (let ((page (field-page field)) (signed (< (field-least field) 0)))
          (dotimes (i (field-count field))
            (let ((value (report-bits bytes (+ base (field-at field) (* i (field-size field))) (field-size field) signed)))
              (cond ((= page 7)
                     (setq keys t)
                     (if (field-variable field)
                         (when (/= value 0)
                           (setq down (cons (usage-of field i) down)))
                         (let ((usage (+ (or (field-lowest field) 0) (- value (field-least field)))))
                           (cond ((<= 1 usage 3) (setq too-many t))
                                 ((> usage 3) (setq down (cons usage down)))))))
                    ((not (field-variable field)))
                    ((= page 9)
                     (let ((button (usage-of field i)))
                       (when (<= 1 button 3)
                         (setq pointer t)
                         (handle-event input 1 (+ #x10f button) value))))
                    ((= page 1)
                     (let ((usage (usage-of field i)))
                       (when (<= #x30 usage #x31)
                         (setq pointer t)
                         (handle-event input (if (field-relative field) 2 3) (- usage #x30) value))))))))))
    (when (and keys (not too-many))
      (let ((before (input-keys input)) (now (reverse down)))
        (setf (input-keys input) now)
        (dolist (usage before)
          (unless (member usage now)
            (let ((key (usage-key usage)))
              (when key
                (key-event input key 0)))))
        (dolist (usage now)
          (unless (member usage before)
            (let ((key (usage-key usage)))
              (when key
                (key-event input key 1)))))))
    (when pointer
      (handle-event input 0 0 0))))

;; The reports that have come since the last look, one after the other.
(defun take-reports (input)
  (loop
    (let ((bytes nil))
      (clara:with-lock-held ((input-lock input))
        (when (input-reports input)
          (setq bytes (car (input-reports input)))
          (setf (input-reports input) (cdr (input-reports input)))))
      (unless bytes
        (return))
      (usb-report input bytes))))

;; A report arrives, in the thread of the USB controller, which has other
;; devices to hear: it is put by for the device's own thread. Of a device
;; whose thread does not get to them, the oldest go once there are a few
;; hundred: the newest report is the one that says which keys are down.
(defun usb-heard (input bytes)
  (clara:with-lock-held ((input-lock input))
    (when (>= (length (input-reports input)) 256)
      (setf (input-reports input) (cdr (input-reports input))))
    (setf (input-reports input) (append (input-reports input) (list bytes))))
  (clara:signal-event (input-event input)))

;; What a device of USB is, by the fields of its reports: keys make a
;; keyboard, a place along the two axes a tablet, a distance a mouse. NIL
;; for a thing that is none of them.
(defun usb-kind (fields)
  (let ((kind nil))
    (dolist (field fields kind)
      (cond ((= (field-page field) 7)
             (return "a keyboard"))
            ((and (= (field-page field) 1) (field-variable field)
                  (or (member #x30 (field-usages field)) (eql (field-lowest field) #x30)))
             (setq kind (if (field-relative field) "a mouse" "a tablet")))))))

;; The least and the most that a tablet says along an axis, from the field
;; that holds it.
(defun usb-limits (fields usage)
  (dolist (field fields '(0 . 32767))
    (when (and (= (field-page field) 1) (field-variable field) (not (field-relative field)))
      (dotimes (i (field-count field))
        (when (= (usage-of field i) usage)
          (return-from usb-limits (cons (field-least field) (field-most field))))))))

;; A USB device has arrived: each of its interfaces of the class 3 that is
;; a keyboard, a mouse or a tablet becomes a device here, with a thread of
;; its own. The interface says in a descriptor of its class (the kind
;; #x21) how long the description of its reports is, in the two bytes at
;; 7, and gives the description when it is asked for the descriptor #x22
;; (7.1). A keyboard or a mouse of the simple kind (its subclass is 1) may
;; have been told by the firmware to report in the one way that a firmware
;; knows, and is told to report as its description says (the request 11,
;; 7.2.6), which it may refuse.
(defun usb-arrived (device)
  (dolist (interface (clara.usb:device-interfaces device))
    (when (= (clara.usb:interface-class interface) 3)
      (handler-case
          (let* ((number (clara.usb:interface-number interface))
                 (class (cdr (assoc #x21 (clara.usb:interface-extras interface))))
                 (length (if (and class (>= (length class) 9)) (+ (svref class 7) (* 256 (svref class 8))) 0)))
            (when (= (clara.usb:interface-subclass interface) 1)
              (handler-case (clara.usb:control device #x21 11 1 number)
                (error () nil)))
            (let* ((fields (read-fields (clara.usb:control device #x81 6 #x2200 number length)))
                   (kind (usb-kind fields)))
              (when kind
                (let* ((name (concatenate 'string (clara.usb:device-place device)))
                       (input (make-input :name (or (clara.usb:device-name device) "which gives itself no name")
                                          :kind kind :usb interface :fields fields
                                          :numbered (and (find-if (lambda (field) (/= (field-report field) 0)) fields) t)
                                          :x-limits (usb-limits fields #x30) :y-limits (usb-limits fields #x31)
                                          :lock (clara:make-lock "input") :event (clara:make-event "input"))))
                  (clara.usb:listen-at interface (lambda (bytes) (usb-heard input bytes)))
                  (setq *inputs* (append *inputs* (list input)))
                  (setf (input-thread input)
                        (clara:make-thread (lambda () (serve input (input-event input) #'take-reports))
                                           :name (concatenate 'string "input " name)))
                  (format t "input: ~A is ~A, ~A~%" name kind (input-name input))))))
        (error (condition)
          (format t "input: ~A did not start: ~A~%" (clara.usb:device-place device) condition))))))

;; A USB device was taken away: its keyboards and pointers are no more,
;; and a key or a button that was down on one is up.
(defun usb-departed (device)
  (dolist (input *inputs*)
    (when (and (input-usb input) (eq (clara.usb:interface-device (input-usb input)) device))
      (setq *inputs* (remove-if (lambda (other) (eq other input)) *inputs*))
      (when (and (input-thread input) (clara:thread-alive-p (input-thread input)))
        (clara:destroy-thread (input-thread input)))
      (setf (input-buttons input) 0)
      (handle-event input 0 0 0))))

(defun devices ()
  *inputs*)

;; Find the input devices among the PCI devices, and start a thread for
;; each; then the ones of USB, which the controllers find. A device that
;; does not start is said, and left alone: the serial port is still there
;; to type on. A thread that an earlier start made for a device of USB is
;; stopped: the controller that it heard from is started anew.
(defun start ()
  (dolist (input *inputs*)
    (when (and (input-thread input) (clara:thread-alive-p (input-thread input)))
      (clara:destroy-thread (input-thread input))))
  (setq *inputs* nil
        *keys-to* nil
        *pointer-to* nil)
  (multiple-value-bind (address width height) (clara.unsafe:framebuffer)
    (when address
      (set-pointer-limits width height)))
  (dolist (pci (clara.pci:devices))
    (when (eql (clara.virtio:device-type pci) 18)
      (handler-case
          (let ((input (open-input pci)))
            (setq *inputs* (append *inputs* (list input)))
            (clara:make-thread (lambda ()
                                 (serve input (clara.virtio:device-event (input-device input)) #'take-events))
                               :name (concatenate 'string "input " (clara.pci:location pci)))
            (format t "input: ~A is ~A, ~A~%" (clara.pci:location pci) (input-kind input) (input-name input)))
        (error (condition)
          (format t "input: ~A did not start: ~A~%" (clara.pci:location pci) condition)))))
  (setq clara.usb:*arrival* #'usb-arrived
        clara.usb:*departure* #'usb-departed)
  (clara.usb:start)
  (when (null *inputs*)
    (format t "input: no keyboard and no mouse that has a driver here: the serial port is where to type~%"))
  *inputs*)
