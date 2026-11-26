;;;; host/clara.lisp: ClaraOS, as far as SBCL has to stand in for it
;;;;
;;;; The Lisp files in lisp/ load under SBCL as well as on ClaraOS, which is
;;;; where they are developed and tested (DESIGN.md). They are written in
;;;; Common Lisp, and SBCL has all of that. What it does not have is the
;;;; two packages that the substrate provides: CLARA, with threads, locks,
;;;; events, streams made of two functions and the condition that Ctrl-C
;;;; is, and CLARA.UNSAFE, with memory by its address, I/O ports and
;;;; interrupts. This file provides both. CLARA is made of SB-THREAD and
;;;; SB-GRAY. CLARA.UNSAFE is a machine that exists only here: its memory
;;;; is a vector, its devices are functions that a test puts at an address
;;;; or at a port, and its interrupts are raised by calling a function. A
;;;; device can be put there in the way a PCI device is found: nothing can
;;;; be read at its address until MAP-MEMORY has been called for it.
;;;; The package CLARA.HOST is what a test sets that machine up with.
;;;;
;;;; Nothing in this directory is ever loaded on ClaraOS: the build copies
;;;; lisp/*.lisp to the boot volume, and not what is below it.

(defpackage "CLARA"
  (:use "COMMON-LISP")
  (:export "MAKE-THREAD" "CURRENT-THREAD" "THREADP" "THREAD-NAME" "THREAD-ALIVE-P" "ALL-THREADS"
           "JOIN-THREAD" "DESTROY-THREAD" "INTERRUPT-THREAD" "THREAD-YIELD"
           "MAKE-LOCK" "ACQUIRE-LOCK" "RELEASE-LOCK" "WITH-LOCK-HELD"
           "MAKE-EVENT" "SIGNAL-EVENT" "WAIT-EVENT"
           "MAKE-STREAM" "KEYBOARD-INTERRUPT" "PROVIDE-FILES" "SAVE-IMAGE" "VOLUMES" "COPY-FILE"
           "VARIABLE-KIND" "PROVIDE-COMPILER" "PROVIDE-FORMAT"))

(defpackage "CLARA.UNSAFE"
  (:use "COMMON-LISP")
  (:export "MEMORY-8" "MEMORY-16" "MEMORY-32" "MEMORY-64"
           "FILL-MEMORY-32" "COPY-MEMORY" "EXPAND-BITS-32" "FILL-RECTANGLE-32" "COPY-RECTANGLE-32"
           "BLEND-SHADES-32" "SYSTEM-FILE"
           "ALLOCATE-MEMORY" "FREE-MEMORY"
           "PORT-8" "PORT-16" "PORT-32"
           "INTERRUPT-EVENT" "FRAMEBUFFER" "SERIAL-DEVICE" "SERIAL-BYTE" "SERIAL-BREAK"
           "TAKE-SCREEN" "GIVE-SCREEN"
           "MAP-MEMORY" "PCI-CONFIGURATION" "MESSAGE-INTERRUPT" "KEYBOARD-BREAK" "MEMORY-STRING"
           "POWER-OFF" "RESET" "POWER-BUTTON" "SHA-512" "ED25519" "INTERNET-SUM" "START-STATE"
           "DIGEST" "HMAC" "AES-128-GCM-SEAL" "AES-128-GCM-OPEN" "X25519" "POWER-MOD" "ECDSA"
           "STRING-BYTES" "STRING-MEMORY" "HEAP-IMAGE"
           "MAKE-COMPILED-FUNCTION" "COMPILED-FUNCTION-CODE"
           "NATIVE-LAYOUT" "INSTALL-NATIVE-CODE" "NATIVE-CODE-BYTES" "NATIVE-FUNCTION"
           "UNTRANSLATED-CODE" "NATIVE-FUNCTIONS"))

(defpackage "CLARA.HOST"
  (:use "COMMON-LISP")
  (:export "RESET-MACHINE" "+MEMORY-BASE+" "MAP-DEVICE" "MAP-PORTS" "PUT-SYSTEM-FILE"
           "SET-FRAMEBUFFER" "SET-SERIAL-DEVICE" "SET-SCREEN-CURSOR" "GIVEN-SCREEN"
           "TYPE-BYTES" "RAISE-INTERRUPT" "SERIAL-BREAK-P"
           "SET-PCI-CONFIGURATION" "SEND-MESSAGE" "MESSAGE-INTERRUPTS" "KEYBOARD-BREAKS"
           "ALLOCATED-PAGES" "PROVIDED-FILES" "SET-VOLUMES" "SET-HEAP-IMAGE" "PROVIDED-COMPILER"
           "POWER" "PRESS-POWER-BUTTON" "SET-START-STATE" "SHA-512-OF"
           "ED25519-PUBLIC" "ED25519-SIGN" "ED25519-VERIFY"
           "OCTETS-OF" "OCTETS-NUMBER" "NUMBER-OCTETS" "DIGEST-OF" "HMAC-OF" "AES-GCM" "X25519-OF" "EXPT-MOD"
           "CURVE" "CURVE-BITS" "CURVE-N" "CURVE-PUBLIC" "CURVE-SIGN" "CURVE-VERIFY"))

;;; CLARA: threads

(in-package "CLARA")

(define-condition keyboard-interrupt (serious-condition) ())

;; A thread as ClaraOS has it: what became of it is kept, an error that
;; nothing handled ends the thread and not the whole Lisp, and JOIN-THREAD
;; says so.
(defstruct (thread (:constructor %make-thread) (:predicate threadp) (:copier nil))
  name native (state :running) result)

(defmethod print-object ((thread thread) stream)
  (format stream "#<THREAD~@[ ~S~]>" (thread-name thread)))

(defvar *threads-lock* (sb-thread:make-mutex :name "threads"))
(defvar *threads* nil)                  ; the ones that have not finished
(defvar *this-thread*                   ; bound in every thread that MAKE-THREAD made
  (%make-thread :name "listener" :native sb-thread:*current-thread*))

(defun current-thread ()
  *this-thread*)

;; A thread takes itself off the list as it ends. One that was stopped
;; before it got as far as its function never does, and nobody may wait
;; for it either (JOIN-THREAD), so it is taken off here, when somebody
;; asks: a thread that SBCL has no longer is not one that has not finished.
(defun all-threads ()
  (sb-thread:with-mutex (*threads-lock*)
    (setq *threads* (remove-if (lambda (thread)
                                 (let ((native (thread-native thread)))
                                   (and native (not (sb-thread:thread-alive-p native)))))
                               *threads*))
    (cons *this-thread* (remove *this-thread* (copy-list *threads*)))))

(defun make-thread (function &key name)
  (let ((thread (%make-thread :name name)))
    (sb-thread:with-mutex (*threads-lock*)
      (push thread *threads*))
    (setf (thread-native thread)
          (sb-thread:make-thread
           (lambda ()
             (let ((*this-thread* thread) (state :stopped) (result nil))
               ;; What says how the thread ended is not to be cut short by a second
               ;; DESTROY-THREAD, which would leave the thread on the list: it runs with
               ;; interrupts off, and the function itself with them on.
               (sb-sys:without-interrupts
                 (unwind-protect
                      (sb-sys:with-local-interrupts
                        (handler-case (setq result (multiple-value-list (funcall function))
                                            state :finished)
                          (serious-condition (condition)
                            (fresh-line)
                            (format t "error in ~S: ~A~%" thread condition)
                            (setq result condition
                                  state :failed))))
                   (setf (thread-result thread) result
                         (thread-state thread) state)
                   (sb-thread:with-mutex (*threads-lock*)
                     (setq *threads* (remove thread *threads*)))))))
           :name name))
    thread))

(defun thread-alive-p (thread)
  (and (eq (thread-state thread) :running)
       (sb-thread:thread-alive-p (thread-native thread))))

(defun join-thread (thread)
  (when (eq thread *this-thread*)
    (error "the thread ~S cannot wait for itself to finish" thread))
  (sb-thread:join-thread (thread-native thread) :default nil)
  (when (eq (thread-state thread) :running)
    ;; It was stopped before it got as far as its function.
    (setf (thread-state thread) :stopped)
    (sb-thread:with-mutex (*threads-lock*)
      (setq *threads* (remove thread *threads*))))
  (ecase (thread-state thread)
    (:finished (values-list (thread-result thread)))
    (:failed (error "the thread ~S ended with an error: ~A" thread (thread-result thread)))
    (:stopped (error "the thread ~S was stopped" thread))))

;; A thread can end between the look whether it runs and the word that it
;; is to stop, and SBCL then signals that there is nobody to tell: such a
;; thread needed no telling.
(defun destroy-thread (thread)
  (when (thread-alive-p thread)
    (handler-case (progn
                    (sb-thread:terminate-thread (thread-native thread))
                    t)
      (sb-thread:interrupt-thread-error () nil))))

;; Ctrl-C, for that thread: KEYBOARD-INTERRUPT is signalled in it, wherever
;; it is, computing or waiting.
(defun interrupt-thread (thread)
  (when (thread-alive-p thread)
    (handler-case (progn
                    (sb-thread:interrupt-thread (thread-native thread) (lambda () (error 'keyboard-interrupt)))
                    t)
      (sb-thread:interrupt-thread-error () nil))))

(defun thread-yield ()
  (sb-thread:thread-yield)
  nil)

;;; CLARA: locks and events

(defun make-lock (&optional name)
  (sb-thread:make-mutex :name name))

(defun acquire-lock (lock)
  (sb-thread:grab-mutex lock))

(defun release-lock (lock)
  (sb-thread:release-mutex lock)
  nil)

(defmacro with-lock-held ((lock) &body body)
  `(sb-thread:with-mutex (,lock) ,@body))

;; An event counts how often it was signalled: a semaphore.
(defun make-event (&optional name)
  (sb-thread:make-semaphore :name name))

(defun signal-event (event &optional (times 1))
  (sb-thread:signal-semaphore event times)
  event)

(defun wait-event (event &optional milliseconds)
  (and (cond ((null milliseconds) (sb-thread:wait-on-semaphore event))
             ((zerop milliseconds) (sb-thread:try-semaphore event))
             (t (sb-thread:wait-on-semaphore event :timeout (/ milliseconds 1000))))
       t))

;;; CLARA: a stream made of two functions

(defclass function-stream (sb-gray:fundamental-character-output-stream
                           sb-gray:fundamental-character-input-stream)
  ((write :initarg :write :initform nil)
   (read :initarg :read :initform nil)
   (close :initarg :close :initform nil)
   (fresh :initform t)))

(defun make-stream (&key write-string read-line close)
  (make-instance 'function-stream :write write-string :read read-line :close close))

;; A stream that is closed gives nothing more, and takes nothing; what it
;; was given to call when it is closed is called, once.
(defmethod close ((stream function-stream) &key abort)
  (let ((close (slot-value stream 'close)))
    (setf (slot-value stream 'close) nil
          (slot-value stream 'read) nil
          (slot-value stream 'write) nil)
    (when (and close (not abort))
      (funcall close)))
  t)

(defmethod sb-gray:stream-write-string ((stream function-stream) string &optional (start 0) end)
  (let ((part (subseq string start end)))
    (unless (slot-value stream 'write)
      (error "~S is not a stream that can be written to" stream))
    (when (plusp (length part))
      (funcall (slot-value stream 'write) part)
      (setf (slot-value stream 'fresh) (char= (char part (1- (length part))) #\Newline))))
  string)

(defmethod sb-gray:stream-write-char ((stream function-stream) character)
  (sb-gray:stream-write-string stream (string character))
  character)

(defmethod sb-gray:stream-line-column ((stream function-stream))
  (if (slot-value stream 'fresh) 0 nil))

(defmethod sb-gray:stream-start-line-p ((stream function-stream))
  (slot-value stream 'fresh))

(defmethod sb-gray:stream-read-line ((stream function-stream))
  (let ((line (and (slot-value stream 'read) (funcall (slot-value stream 'read)))))
    (if line
        (values line nil)
        (values "" t))))

(defmethod sb-gray:stream-read-char ((stream function-stream))
  (error "~S gives lines, not characters" stream))

;;; CLARA: where files come from
;;;
;;; On ClaraOS a file system hands OPEN, LOAD, PROBE-FILE, DIRECTORY and
;;; DELETE-FILE its functions with this. SBCL has files of its own behind
;;; those, so here the functions are kept for a test to call.

(defvar *files* nil)

(defun provide-files (&key text names write delete image copy volumes)
  (setq *files* (if (and text names) (list text names write delete (or image write) copy volumes)))
  nil)

;; VOLUMES as lisp/boot.lisp has it: the volumes that there are, each a
;; list of the name of its first directory and what is known of it. The
;; files here are the host's, which has no such thing, so they are whatever
;; a test says (CLARA.HOST:SET-VOLUMES), directories of its own, and none
;; until it does.
(defvar *volumes* nil)

(defun volumes ()
  *volumes*)

;; COPY-FILE as lisp/boot.lisp has it: a file of the name TO that holds
;; what the file FROM holds, byte for byte, in place of one that was
;; there, and an error when the two names are one file's. The files are
;; the host's.
(defun copy-file (from to)
  (when (and (probe-file from) (probe-file to) (equal (truename from) (truename to)))
    (error "~A and ~A are one file" from to))
  (with-open-file (in from :element-type '(unsigned-byte 8))
    (with-open-file (out to :direction :output :if-exists :supersede :element-type '(unsigned-byte 8))
      (let ((bytes (make-array 4096 :element-type '(unsigned-byte 8))))
        (loop
          (let ((count (read-sequence bytes in)))
            (when (zerop count)
              (return))
            (write-sequence bytes out :end count))))))
  to)

;; SAVE-IMAGE as lisp/boot.lisp has it: the heap goes into a file, by way
;; of the file system that is there. The heap of this machine is whatever a
;; test says it is (CLARA.HOST:SET-HEAP-IMAGE).
(defun save-image (&optional (name "/clara/clara.image"))
  (let ((write (fifth *files*)))
    (unless write
      (error "the file ~A cannot be written: no disk has a file system that is known here" name))
    (multiple-value-bind (memory bytes pages) (clara.unsafe:heap-image)
      (unwind-protect (funcall write name memory bytes)
        (clara.unsafe:free-memory memory pages)))
    name))

;;; CLARA: what a compiler has to know, and where it says that it is there
;;;
;;; On ClaraOS COMPILE and DISASSEMBLE are in lisp/boot.lisp, and find the
;;; compiler's functions through PROVIDE-COMPILER. SBCL has a compiler of
;;; its own behind those names, so here the functions are kept for a test
;;; to call. The machine that runs what the compiler makes is in
;;; lisp/host/vm.lisp.

(defun variable-kind (symbol)
  (case (sb-int:info :variable :kind symbol)
    (:special :special)
    (:constant :constant)
    (t nil)))

(defvar *compiler* nil)

(defun provide-compiler (&key compile list evaluate)
  (setq *compiler* (if compile (list compile list evaluate)))
  nil)

;; The directives of FORMAT are handed over the same way (lisp/format.lisp,
;; PROVIDE-FORMAT). FORMAT is SBCL's own here, which is what the tests hold
;; that file against, so the function is kept for them to call.
(defvar *format* nil)

(defun provide-format (&optional function)
  (setq *format* function)
  nil)

;;; CLARA.HOST: the machine that is not there

(in-package "CLARA.HOST")

(defconstant +memory-base+ #x100000)   ; where the machine's memory begins,
(defconstant +memory-size+ #x400000)   ; and how much there is of it

(defvar *memory* (make-array +memory-size+ :element-type '(unsigned-byte 8) :initial-element 0))
(defvar *pages*              ; the page frames that ALLOCATE-MEMORY has handed out and FREE-MEMORY not had back
  (make-array (floor +memory-size+ 4096) :element-type 'bit :initial-element 0))
(defvar *pages-lock* (sb-thread:make-mutex :name "pages")) ; threads here run at the same time, as they do not on ClaraOS
(defvar *devices* nil)       ; (first last read write mapped): registers in memory
(defvar *system-files* nil)  ; (name address bytes): the files that the handoff is said to have read
(defvar *mapped* nil)        ; (first . last): what MAP-MEMORY was called for
(defvar *pci-configuration* nil) ; what PCI-CONFIGURATION gives, as a list, or NIL
(defvar *messages* nil)      ; (device event address data): what MESSAGE-INTERRUPT has handed out, the last first
(defvar *keyboard-breaks* 0) ; how often KEYBOARD-BREAK was called
(defvar *power* nil)         ; what the machine was told of its power, the last first: :OFF and :AGAIN
(defvar *button* nil)        ; its power button was pressed, and nobody has asked since
(defvar *start-state*        ; what START-STATE gives: what the kernel knows of this start
  (list :system "0.0.0-host" :resumed nil :starts 0 :token nil :trial nil :failed nil :passed-over nil))
(defvar *ports* nil)         ; the same for I/O ports
(defvar *framebuffer* nil)   ; what FRAMEBUFFER gives, as a list, or NIL
(defvar *serial-device* nil) ; (kind base)
(defvar *screen-cursor* nil) ; (row column) of the substrate's console, for TAKE-SCREEN
(defvar *given-screen* nil)  ; (row column) of the last GIVE-SCREEN
(defvar *typed* nil)         ; bytes that SERIAL-BYTE has yet to give
(defvar *typed-lock* (sb-thread:make-mutex :name "typed"))
(defvar *interrupts* nil)    ; (source . event)
(defvar *serial-break* t)
(defvar *heap-image*         ; the bytes that HEAP-IMAGE gives for the heap
  (coerce (loop for i below 9000 collect (mod (* 7 i) 251)) '(vector (unsigned-byte 8))))

;; A machine with empty memory, no devices, no screen, and nothing typed.
(defun reset-machine ()
  (fill *memory* 0)
  (fill *pages* 0)
  (setf clara::*files* nil)
  (setq *system-files* nil)
  (setq *devices* nil *ports* nil *framebuffer* nil *serial-device* nil
        *screen-cursor* nil *given-screen* nil *typed* nil *interrupts* nil *serial-break* t
        *mapped* nil *pci-configuration* nil *messages* nil *keyboard-breaks* 0
        *power* nil *button* nil)
  nil)

;; SIZE bytes of registers at ADDRESS: READ is called with an offset and
;; how many bytes are read, WRITE with an offset, that and the value. With
;; MAPPED false they are there for a driver to find, and reading or writing
;; them is an error until the driver has called MAP-MEMORY for them, as it
;; is on ClaraOS.
(defun map-device (address size read write &key (mapped t))
  (push (list address (+ address size -1) read write mapped) *devices*))

(defun map-ports (port count read write)
  (push (list port (+ port count -1) read write) *ports*))

;; A file that the handoff read into memory, as the kernel has those of its
;; system: BYTES, a vector of them, under NAME, for CLARA.UNSAFE:SYSTEM-FILE
;; to find. Its memory is page frames of the machine's that nobody gives
;; back.
(defun put-system-file (name bytes)
  (let* ((pages (max 1 (ceiling (length bytes) 4096)))
         (address (clara.unsafe:allocate-memory pages)))
    (replace *memory* bytes :start1 (- address +memory-base+))
    (setq *system-files* (cons (list name address (length bytes))
                               (remove name *system-files* :key #'first :test #'string-equal)))
    address))

(defun set-framebuffer (address width height pitch red green blue)
  (setq *framebuffer* (list address width height pitch red green blue)))

(defun set-serial-device (kind base)
  (setq *serial-device* (list kind base)))

(defun set-screen-cursor (row column)
  (setq *screen-cursor* (list row column)))

(defun given-screen ()
  *given-screen*)

(defun serial-break-p ()
  *serial-break*)

(defun interrupt-event (source)
  (or (cdr (assoc source *interrupts*))
      (cdar (push (cons source (clara:make-event (string source))) *interrupts*))))

(defun raise-interrupt (source)
  (clara:signal-event (interrupt-event source)))

;; Bytes arrive on the serial port, and the interrupt that says so.
(defun type-bytes (bytes)
  (sb-thread:with-mutex (*typed-lock*)
    (setq *typed* (append *typed* (coerce bytes 'list))))
  (raise-interrupt :serial))

(defun set-pci-configuration (base first-bus last-bus)
  (setq *pci-configuration* (list base first-bus last-bus)))

(defun message-interrupts ()
  *messages*)

(defun keyboard-breaks ()
  *keyboard-breaks*)

;; What the machine was told of its power since it was made, the first
;; first: this machine does neither, and goes on, as one does that cannot
;; be turned off from inside.
(defun power ()
  (reverse *power*))

(defun press-power-button ()
  (setq *button* t))

;; What the kernel is to say of this start: the names of CLARA.UNSAFE:START-STATE,
;; each with its value, and the ones that are not named as on a first start.
(defun set-start-state (&key (system "0.0.0-host") resumed (starts 0) token trial failed passed-over)
  (setq *start-state* (list :system system :resumed resumed :starts starts :token token :trial trial
                            :failed failed :passed-over passed-over)))

;; SHA-512 (FIPS 180-4), for the sum that the kernel has in C: of a vector
;; of bytes, as the 128 digits that it is written with.
(defun root (n k)
  (let ((low 0) (high 1))
    (loop while (<= (expt high k) n) do (setq high (* 2 high)))
    (loop while (< low (1- high))
          do (let ((middle (floor (+ low high) 2)))
               (if (<= (expt middle k) n) (setq low middle) (setq high middle))))
    low))

(defvar *primes* (loop with found = nil
                       for n from 2
                       until (= (length found) 80)
                       do (when (notany (lambda (prime) (zerop (mod n prime))) found)
                            (setq found (append found (list n))))
                       finally (return found)))
(defvar *sha-k* (coerce (loop for prime in *primes* collect (ldb (byte 64 0) (root (ash prime 192) 3))) 'vector))
(defvar *sha-h* (loop for prime in (subseq *primes* 0 8) collect (ldb (byte 64 0) (root (ash prime 128) 2))))

(defun sha-512-of (bytes)
  (flet ((rotate (x n) (ldb (byte 64 0) (logior (ash x (- n)) (ash x (- 64 n))))))
    (let* ((length (length bytes))
           (padded (concatenate 'vector bytes '(#x80)
                                (make-list (mod (- 111 length) 128) :initial-element 0)
                                (loop for shift from 120 downto 0 by 8 collect (ldb (byte 8 shift) (* 8 length)))))
           (h (copy-list *sha-h*))
           (w (make-array 80)))
      (loop for start from 0 below (length padded) by 128
            do (dotimes (i 16)
                 (setf (aref w i) (loop with word = 0
                                        for j below 8
                                        do (setq word (+ (ash word 8) (aref padded (+ start (* 8 i) j))))
                                        finally (return word))))
               (loop for i from 16 below 80
                     do (let ((a (aref w (- i 15))) (b (aref w (- i 2))))
                          (setf (aref w i)
                                (ldb (byte 64 0)
                                     (+ (aref w (- i 16)) (logxor (rotate a 1) (rotate a 8) (ash a -7))
                                        (aref w (- i 7)) (logxor (rotate b 19) (rotate b 61) (ash b -6)))))))
               (destructuring-bind (a b c d e f g last) h
                 (dotimes (i 80)
                   (let ((one (ldb (byte 64 0)
                                   (+ last (logxor (rotate e 14) (rotate e 18) (rotate e 41))
                                      (logxor (logand e f) (logandc1 e g)) (aref *sha-k* i) (aref w i))))
                         (two (ldb (byte 64 0)
                                   (+ (logxor (rotate a 28) (rotate a 34) (rotate a 39))
                                      (logxor (logand a b) (logand a c) (logand b c))))))
                     (setq last g g f f e e (ldb (byte 64 0) (+ d one)) d c c b b a a (ldb (byte 64 0) (+ one two)))))
                 (setq h (mapcar (lambda (x y) (ldb (byte 64 0) (+ x y))) h (list a b c d e f g last)))))
      (format nil "~(~{~16,'0X~}~)" h))))

;; How many page frames are handed out: a driver that gives back what it
;; takes leaves this as it was.
(defun allocated-pages ()
  (count 1 *pages*))

;; What CLARA:PROVIDE-FILES was given last: the functions, or NIL.
(defun provided-compiler ()
  clara::*compiler*)

(defun provided-files ()
  clara::*files*)

;; What CLARA:VOLUMES gives from now on.
(defun set-volumes (volumes)
  (setq clara::*volumes* volumes))

;; Ed25519 (RFC 8032): a signature, made and checked, with big numbers. A
;; point of the curve is its x and y, bytes are sequences of numbers, and
;; a key's secret half is thirty-two bytes of anything. The kernel checks
;; signatures in C, and nothing in ClaraOS makes one: these are for the
;; tests, which sign what they then hold against the check.
(defvar *ed-p* (- (expt 2 255) 19))
(defvar *ed-l* (+ (expt 2 252) 27742317777372353535851937790883648493))

(defun ed-power (x n)
  (let ((result 1))
    (loop while (plusp n)
          do (when (oddp n)
               (setq result (mod (* result x) *ed-p*)))
             (setq x (mod (* x x) *ed-p*)
                   n (ash n -1)))
    result))

(defun ed-inverse (x)
  (ed-power x (- *ed-p* 2)))

(defvar *ed-d* (mod (* -121665 (ed-inverse 121666)) *ed-p*))

(defun ed-add (a b)
  (if (null a)
      b
      (let* ((x1 (car a)) (y1 (cdr a)) (x2 (car b)) (y2 (cdr b))
             (k (mod (* *ed-d* x1 x2 y1 y2) *ed-p*)))
        (cons (mod (* (+ (* x1 y2) (* x2 y1)) (ed-inverse (+ 1 k))) *ed-p*)
              (mod (* (+ (* y1 y2) (* x1 x2)) (ed-inverse (- 1 k))) *ed-p*)))))

(defun ed-times (n point)
  (let ((sum nil))
    (loop while (plusp n)
          do (when (oddp n)
               (setq sum (ed-add sum point)))
             (setq point (ed-add point point)
                   n (ash n -1)))
    (or sum (cons 0 1))))

(defun ed-number (octets)
  (let ((n 0))
    (loop for i from (1- (length octets)) downto 0
          do (setq n (+ (* 256 n) (elt octets i))))
    n))

(defun ed-octets (n count)
  (loop for i below count collect (ldb (byte 8 (* 8 i)) n)))

;; The point that thirty-two bytes stand for, or NIL.
(defun ed-point (octets)
  (let* ((n (ed-number octets)) (y (ldb (byte 255 0) n)) (odd (ldb (byte 1 255) n))
         (x2 (mod (* (- (* y y) 1) (ed-inverse (+ 1 (* *ed-d* y y)))) *ed-p*))
         (x (ed-power x2 (/ (+ *ed-p* 3) 8))))
    (unless (zerop (mod (- (* x x) x2) *ed-p*))
      (setq x (mod (* x (ed-power 2 (/ (- *ed-p* 1) 4))) *ed-p*)))
    (and (< y *ed-p*) (zerop (mod (- (* x x) x2) *ed-p*))
         (cons (if (= (logand x 1) odd) x (- *ed-p* x)) y))))

(defun ed-bytes (point)
  (ed-octets (logior (cdr point) (ash (logand (car point) 1) 255)) 32))

(defvar *ed-base* (ed-point (ed-octets (mod (* 4 (ed-inverse 5)) *ed-p*) 32)))

;; The sixty-four bytes of a SHA-512, of several sequences of bytes one after the other.
(defun ed-sum (&rest parts)
  (let ((digits (sha-512-of (apply #'concatenate 'vector parts))))
    (loop for i from 0 below 128 by 2 collect (parse-integer digits :start i :end (+ i 2) :radix 16))))

(defun ed-secret (secret)
  (let* ((sum (ed-sum secret)) (a (ed-number (subseq sum 0 32))))
    (values (logior (logand a (- (ash 1 254) 8)) (ash 1 254)) (subseq sum 32))))

;; The public half of a key, thirty-two bytes, from its secret half.
(defun ed25519-public (secret)
  (ed-bytes (ed-times (ed-secret secret) *ed-base*)))

;; The signature that a key gives a message: sixty-four bytes.
(defun ed25519-sign (secret message)
  (multiple-value-bind (a prefix) (ed-secret secret)
    (let* ((public (ed-bytes (ed-times a *ed-base*)))
           (r (mod (ed-number (ed-sum prefix message)) *ed-l*))
           (first (ed-bytes (ed-times r *ed-base*)))
           (h (mod (ed-number (ed-sum first public message)) *ed-l*)))
      (append first (ed-octets (mod (+ r (* h a)) *ed-l*) 32)))))

;; Is SIGNATURE the signature that the key whose public half is PUBLIC gives the message?
(defun ed25519-verify (public message signature)
  (and (= (length signature) 64) (= (length public) 32)
       (let ((r (ed-point (subseq signature 0 32))) (a (ed-point public)) (s (ed-number (subseq signature 32))))
         (and r a (< s *ed-l*)
              (equal (ed-times s *ed-base*)
                     (ed-add r (ed-times (mod (ed-number (ed-sum (subseq signature 0 32) public message)) *ed-l*) a)))
              t))))

;; What the heap of this machine is, to whoever saves it.
;; What a connection that is kept closed is made of (lisp/tls.lisp), for the
;; arithmetic that the kernel has in C (kernel/sha256.c, hmac.c, aes.c,
;; ed25519.c, bignum.c, ecdsa.c): here by SBCL's big numbers, each written
;; from its standard and not from the C. The tests hold both against the
;; standards' examples, and the made-up network's side of a connection is
;; made of these too.

(defun octets-of (&rest parts)
  (let ((bytes (make-array (reduce #'+ (mapcar #'length parts)) :element-type '(unsigned-byte 8))) (at 0))
    (dolist (part parts bytes)
      (replace bytes part :start1 at)
      (incf at (length part)))))

(defun octets-number (octets &key (start 0) (end (length octets)))
  (let ((number 0))
    (loop for i from start below end
          do (setq number (+ (* 256 number) (elt octets i))))
    number))

(defun number-octets (number count)
  (let ((bytes (make-array count :element-type '(unsigned-byte 8))))
    (dotimes (i count bytes)
      (setf (aref bytes i) (ldb (byte 8 (* 8 (- count i 1))) number)))))

;; SHA-256, SHA-384 and SHA-512 (FIPS 180-4), by the number of their bits:
;; the sum of a vector of bytes, as bytes. The numbers that the standard
;; has as tables are worked out here, from the primes.
(defvar *sha-k-32* (coerce (loop for prime in (subseq *primes* 0 64) collect (ldb (byte 32 0) (root (ash prime 96) 3))) 'vector))
(defvar *sha-h-32* (loop for prime in (subseq *primes* 0 8) collect (ldb (byte 32 0) (root (ash prime 64) 2))))
(defvar *sha-h-384* (loop for prime in (subseq *primes* 8 16) collect (ldb (byte 64 0) (root (ash prime 128) 2))))

(defun digest-of (bits bytes)
  (let* ((small (= bits 256)) (word (if small 32 64)) (size (if small 64 128)) (rounds (if small 64 80))
         (k (if small *sha-k-32* *sha-k*))
         (h (copy-list (ecase bits (256 *sha-h-32*) (384 *sha-h-384*) (512 *sha-h*))))
         (length (length bytes))
         (padded (concatenate 'vector bytes '(#x80)
                              (make-list (mod (- size (if small 9 17) length) size) :initial-element 0)
                              (loop for shift from (if small 56 120) downto 0 by 8 collect (ldb (byte 8 shift) (* 8 length)))))
         (w (make-array rounds)))
    (flet ((rotate (x n) (ldb (byte word 0) (logior (ash x (- n)) (ash x (- word n)))))
           (cut (x) (ldb (byte word 0) x)))
      (loop for start from 0 below (length padded) by size
            do (dotimes (i 16)
                 (setf (aref w i) (octets-number padded :start (+ start (* (floor word 8) i)) :end (+ start (* (floor word 8) (1+ i))))))
               (loop for i from 16 below rounds
                     do (let ((a (aref w (- i 15))) (b (aref w (- i 2))))
                          (setf (aref w i)
                                (cut (+ (aref w (- i 16))
                                        (if small
                                            (logxor (rotate a 7) (rotate a 18) (ash a -3))
                                            (logxor (rotate a 1) (rotate a 8) (ash a -7)))
                                        (aref w (- i 7))
                                        (if small
                                            (logxor (rotate b 17) (rotate b 19) (ash b -10))
                                            (logxor (rotate b 19) (rotate b 61) (ash b -6))))))))
               (destructuring-bind (a b c d e f g last) h
                 (dotimes (i rounds)
                   (let ((one (cut (+ last
                                      (if small
                                          (logxor (rotate e 6) (rotate e 11) (rotate e 25))
                                          (logxor (rotate e 14) (rotate e 18) (rotate e 41)))
                                      (logxor (logand e f) (logandc1 e g)) (aref k i) (aref w i))))
                         (two (cut (+ (if small
                                          (logxor (rotate a 2) (rotate a 13) (rotate a 22))
                                          (logxor (rotate a 28) (rotate a 34) (rotate a 39)))
                                      (logxor (logand a b) (logand a c) (logand b c))))))
                     (setq last g g f f e e (cut (+ d one)) d c c b b a a (cut (+ one two)))))
                 (setq h (mapcar (lambda (x y) (cut (+ x y))) h (list a b c d e f g last)))))
      (subseq (apply #'octets-of (mapcar (lambda (x) (number-octets x (floor word 8))) h)) 0 (floor bits 8)))))

;; HMAC (RFC 2104).
(defun hmac-of (bits key data)
  (let* ((size (if (= bits 256) 64 128))
         (key (if (> (length key) size) (digest-of bits key) key))
         (padded (octets-of key (make-list (- size (length key)) :initial-element 0))))
    (digest-of bits (octets-of (map 'vector (lambda (byte) (logxor byte #x5c)) padded)
                               (digest-of bits (octets-of (map 'vector (lambda (byte) (logxor byte #x36)) padded) data))))))

;; AES-128 (FIPS 197) in Galois/Counter Mode (NIST SP 800-38D).
(defun aes-times (a b)
  (let ((r 0))
    (dotimes (i 8 r)
      (when (logbitp i b)
        (setq r (logxor r a)))
      (setq a (logand #xff (logxor (ash a 1) (if (logbitp 7 a) #x1b 0)))))))

(defvar *aes-s* (let ((box (make-array 256)))
                  (dotimes (x 256 box)
                    (let* ((inverse (if (zerop x) 0 (loop for y from 1 below 256 when (= (aes-times x y) 1) return y)))
                           (s inverse))
                      (dolist (shift '(1 2 3 4))
                        (setq s (logxor s (logand #xff (logior (ash inverse shift) (ash inverse (- shift 8)))))))
                      (setf (aref box x) (logxor s #x63))))))

(defun aes-keys (key)
  (let ((w (make-array 176)) (round 1))
    (replace w key)
    (loop for i from 16 below 176 by 4
          do (let ((word (list (aref w (- i 4)) (aref w (- i 3)) (aref w (- i 2)) (aref w (- i 1)))))
               (when (zerop (mod i 16))
                 (setq word (list (logxor (aref *aes-s* (second word)) round) (aref *aes-s* (third word))
                                  (aref *aes-s* (fourth word)) (aref *aes-s* (first word)))
                       round (aes-times round 2)))
               (dotimes (j 4)
                 (setf (aref w (+ i j)) (logxor (aref w (+ i j -16)) (nth j word))))))
    w))

(defun aes-block (w block)
  (let ((s (make-array 16)) (moved (make-array 16)))
    (dotimes (i 16)
      (setf (aref s i) (logxor (elt block i) (aref w i))))
    (loop for round from 1 to 10
          do (dotimes (c 4)
               (dotimes (r 4)
                 (setf (aref moved (+ (* 4 c) r)) (aref *aes-s* (aref s (+ (* 4 (logand (+ c r) 3)) r))))))
             (if (< round 10)
                 (dotimes (c 4)
                   (let ((a (aref moved (* 4 c))) (b (aref moved (+ (* 4 c) 1))) (d (aref moved (+ (* 4 c) 2))) (e (aref moved (+ (* 4 c) 3))))
                     (setf (aref s (* 4 c)) (logxor (aes-times a 2) (aes-times b 3) d e)
                           (aref s (+ (* 4 c) 1)) (logxor a (aes-times b 2) (aes-times d 3) e)
                           (aref s (+ (* 4 c) 2)) (logxor a b (aes-times d 2) (aes-times e 3))
                           (aref s (+ (* 4 c) 3)) (logxor (aes-times a 3) b d (aes-times e 2)))))
                 (replace s moved))
             (dotimes (i 16)
               (setf (aref s i) (logxor (aref s i) (aref w (+ (* 16 round) i))))))
    s))

;; The product of two blocks, as the mode multiplies (SP 800-38D, 6.3).
(defun gcm-times (x y)
  (let ((z 0) (v y))
    (loop for i from 127 downto 0
          do (when (logbitp i x)
               (setq z (logxor z v)))
             (setq v (logxor (ash v -1) (if (logbitp 0 v) (ash #xe1 120) 0))))
    z))

(defun gcm-sum (h beside data)
  (let ((y 0))
    (dolist (part (list beside data))
      (loop for start from 0 below (length part) by 16
            do (let ((end (min (length part) (+ start 16))))
                 (setq y (gcm-times (logxor y (ash (octets-number part :start start :end end) (* 8 (- 16 (- end start))))) h)))))
    (gcm-times (logxor y (logior (ash (* 8 (length beside)) 64) (* 8 (length data)))) h)))

;; Bytes closed with a key and twelve bytes: the closed bytes and the tag.
;; Or, with OPENING, bytes opened: the open bytes, or NIL when the tag is
;; not theirs.
(defun aes-gcm (key nonce beside data &key opening tag)
  (let* ((w (aes-keys key))
         (h (octets-number (aes-block w (make-list 16 :initial-element 0))))
         (out (make-array (length data) :element-type '(unsigned-byte 8))))
    (loop for start from 0 below (length data) by 16
          for number from 2
          do (let ((stream (aes-block w (octets-of nonce (number-octets number 4)))))
               (loop for i from start below (min (length data) (+ start 16))
                     do (setf (aref out i) (logxor (elt data i) (aref stream (- i start)))))))
    (let ((sum (number-octets (logxor (gcm-sum h beside (if opening data out))
                                      (octets-number (aes-block w (octets-of nonce '(0 0 0 1)))))
                              16)))
      (if opening
          (and (equalp sum (coerce tag '(simple-array (unsigned-byte 8) (*)))) out)
          (values out sum)))))

;; X25519 (RFC 7748, 5): the ladder as the RFC writes it.
(defun x25519-of (scalar point)
  (let* ((p *ed-p*)
         (k (let ((bytes (copy-seq (coerce scalar 'vector))))
              (setf (aref bytes 0) (logand (aref bytes 0) 248)
                    (aref bytes 31) (logior (logand (aref bytes 31) 127) 64))
              (octets-number (reverse bytes))))
         (u (ldb (byte 255 0) (octets-number (reverse (coerce point 'vector)))))
         (x1 u) (x2 1) (z2 0) (x3 u) (z3 1) (swap 0))
    (loop for i from 254 downto 0
          do (let ((bit (ldb (byte 1 i) k)))
               (setq swap (logxor swap bit))
               (when (= swap 1)
                 (rotatef x2 x3)
                 (rotatef z2 z3))
               (setq swap bit)
               (let* ((a (mod (+ x2 z2) p)) (aa (mod (* a a) p)) (b (mod (- x2 z2) p)) (bb (mod (* b b) p))
                      (e (mod (- aa bb) p)) (c (mod (+ x3 z3) p)) (d (mod (- x3 z3) p))
                      (da (mod (* d a) p)) (cb (mod (* c b) p)))
                 (setq x3 (mod (expt (+ da cb) 2) p)
                       z3 (mod (* x1 (expt (- da cb) 2)) p)
                       x2 (mod (* aa bb) p)
                       z2 (mod (* e (+ aa (* 121665 e))) p)))))
    (when (= swap 1)
      (rotatef x2 x3)
      (rotatef z2 z3))
    (reverse (number-octets (mod (* x2 (ed-power z2 (- p 2))) p) 32))))

;; A number to a power, modulo another.
(defun expt-mod (base exponent modulus)
  (let ((result 1) (base (mod base modulus)))
    (loop while (plusp exponent)
          do (when (oddp exponent)
               (setq result (mod (* result base) modulus)))
             (setq base (mod (* base base) modulus)
                   exponent (ash exponent -1)))
    result))

;; The curves P-256 and P-384 (NIST SP 800-186), and ECDSA on them (FIPS
;; 186-5, 6.4): a point is (x . y), and NIL is no point at all.
(defstruct curve bits p b g n)

(defvar *curves*
  (list (make-curve :bits 256
                    :p #xffffffff00000001000000000000000000000000ffffffffffffffffffffffff
                    :b #x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b
                    :g (cons #x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296
                             #x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5)
                    :n #xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551)
        (make-curve :bits 384
                    :p #xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff
                    :b #xb3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef
                    :g (cons #xaa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7
                             #x3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f)
                    :n #xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973)))

(defun curve (bits)
  (find bits *curves* :key #'curve-bits))

(defun curve-on-p (curve point)
  (let ((p (curve-p curve)) (x (car point)) (y (cdr point)))
    (and (< -1 x p) (< -1 y p)
         (zerop (mod (- (* y y) (+ (* x x x) (* -3 x) (curve-b curve))) p)))))

;; Points are added as three numbers, X, Y and Z, of which x is X/(Z*Z) and
;; y is Y/(Z*Z*Z), so that nothing is divided until the end: a point of
;; that kind is a list, and one with a Z of 0 is no point at all.
(defun curve-double (curve point)
  (destructuring-bind (x y z) point
    (if (zerop z)
        point
        (let* ((p (curve-p curve)) (delta (mod (* z z) p)) (gamma (mod (* y y) p)) (beta (mod (* x gamma) p))
               (alpha (mod (* 3 (- x delta) (+ x delta)) p))
               (x3 (mod (- (* alpha alpha) (* 8 beta)) p)))
          (list x3
                (mod (- (* alpha (- (* 4 beta) x3)) (* 8 gamma gamma)) p)
                (mod (- (* (+ y z) (+ y z)) gamma delta) p))))))

(defun curve-plus (curve a b)
  (cond ((zerop (third a)) b)
        ((zerop (third b)) a)
        (t
         (let* ((p (curve-p curve))
                (z1z1 (mod (* (third a) (third a)) p)) (z2z2 (mod (* (third b) (third b)) p))
                (u1 (mod (* (first a) z2z2) p)) (u2 (mod (* (first b) z1z1) p))
                (s1 (mod (* (second a) (third b) z2z2) p)) (s2 (mod (* (second b) (third a) z1z1) p))
                (h (mod (- u2 u1) p)) (r (mod (- s2 s1) p)))
           (cond ((and (zerop h) (zerop r)) (curve-double curve a))
                 ((zerop h) (list 1 1 0))
                 (t
                  (let* ((hh (mod (* h h) p)) (hhh (mod (* h hh) p)) (v (mod (* u1 hh) p))
                         (x3 (mod (- (* r r) hhh (* 2 v)) p)))
                    (list x3
                          (mod (- (* r (- v x3)) (* s1 hhh)) p)
                          (mod (* (third a) (third b) h) p)))))))))

;; From three numbers back to (x . y), or NIL.
(defun curve-point (curve point)
  (destructuring-bind (x y z) point
    (unless (zerop z)
      (let* ((p (curve-p curve)) (inverse (expt-mod z (- p 2) p)) (square (mod (* inverse inverse) p)))
        (cons (mod (* x square) p) (mod (* y square inverse) p))))))

(defun curve-add (curve a b)
  (curve-point curve (curve-plus curve (if a (list (car a) (cdr a) 1) (list 1 1 0)) (if b (list (car b) (cdr b) 1) (list 1 1 0)))))

(defun curve-times (curve number point)
  (let ((result (list 1 1 0)) (point (if point (list (car point) (cdr point) 1) (list 1 1 0))))
    (loop for i from (1- (integer-length number)) downto 0
          do (setq result (curve-double curve result))
             (when (logbitp i number)
               (setq result (curve-plus curve result point))))
    (curve-point curve result)))

;; The point that is the public half of a secret number.
(defun curve-public (curve secret)
  (curve-times curve secret (curve-g curve)))

;; The sum, as far as the curve's order has bits, as a number.
(defun curve-sum (curve sum)
  (octets-number sum :end (min (length sum) (floor (curve-bits curve) 8))))

;; The two numbers that are the signature of a sum, with the secret number
;; and a number K that is used once.
(defun curve-sign (curve secret sum k)
  (let* ((n (curve-n curve))
         (r (mod (car (curve-times curve k (curve-g curve))) n))
         (s (mod (* (expt-mod k (- n 2) n) (+ (curve-sum curve sum) (* r secret))) n)))
    (values r s)))

(defun curve-verify (curve point sum r s)
  (let ((n (curve-n curve)))
    (and (< 0 r n) (< 0 s n) (curve-on-p curve point)
         (let* ((w (expt-mod s (- n 2) n))
                (total (curve-add curve
                                  (curve-times curve (mod (* (curve-sum curve sum) w) n) (curve-g curve))
                                  (curve-times curve (mod (* r w) n) point))))
           (and total (= (mod (car total) n) r))))))

(defun set-heap-image (bytes)
  (setq *heap-image* (coerce bytes '(vector (unsigned-byte 8)))))

;; A device writes DATA to ADDRESS: the interrupt that MESSAGE-INTERRUPT
;; handed out with those two is raised. A message that nobody asked for is
;; an error of the test's.
(defun send-message (address data)
  (let ((message (find-if (lambda (message) (and (= (third message) address) (= (fourth message) data)))
                          *messages*)))
    (unless message
      (error "nothing listens for the message ~D at #x~(~X~)" data address))
    (clara:signal-event (second message))))

(defun device-at (address devices)
  (find-if (lambda (device) (<= (first device) address (second device))) devices))

(defun mapped-p (address size)
  (find-if (lambda (range) (<= (car range) address (+ address size -1) (cdr range))) *mapped*))

(defun memory-index (address size)
  (let ((index (- address +memory-base+)))
    (unless (and (integerp address) (<= 0 index) (<= (+ index size) +memory-size+))
      (error "nothing is mapped at #x~(~X~)" address))
    index))

;; What ClaraOS refuses, this machine refuses too: an address that is not
;; a multiple of the bytes that are read or written there, and a value that
;; does not fit in them.
(defun check-access (address size)
  (unless (and (integerp address) (>= address 0) (zerop (mod address size)))
    (error "#x~(~X~) is not the address of ~D bytes: it is not a multiple of ~D" address size size)))

(defun peek (address size)
  (check-access address size)
  (let ((device (device-at address *devices*)))
    (when (and device (not (fifth device)) (not (mapped-p address size)))
      (error "nothing is mapped at #x~(~X~)" address))
    (if device
        (funcall (third device) (- address (first device)) size)
        (let ((index (memory-index address size)) (value 0))
          (dotimes (i size value)
            (setq value (logior value (ash (aref *memory* (+ index i)) (* 8 i)))))))))

(defun poke (address size value)
  (check-access address size)
  (unless (and (integerp value) (or (= size 8) (< (- -1 (ash 1 (1- (* 8 size)))) value (ash 1 (* 8 size)))))
    (error "~S is not an integer that fits in ~D bits" value (* 8 size)))
  (let ((device (device-at address *devices*)))
    (when (and device (not (fifth device)) (not (mapped-p address size)))
      (error "nothing is mapped at #x~(~X~)" address))
    (if device
        (funcall (fourth device) (- address (first device)) size value)
        (let ((index (memory-index address size)))
          (dotimes (i size)
            (setf (aref *memory* (+ index i)) (ldb (byte 8 (* 8 i)) value)))))
    value))

(defun port-in (port size)
  (let ((device (device-at port *ports*)))
    (unless device
      (error "nothing answers at the I/O port #x~(~X~)" port))
    (funcall (third device) (- port (first device)) size)))

(defun port-out (port size value)
  (let ((device (device-at port *ports*)))
    (unless device
      (error "nothing answers at the I/O port #x~(~X~)" port))
    (funcall (fourth device) (- port (first device)) size value)
    value))

;;; CLARA.UNSAFE

(in-package "CLARA.UNSAFE")

(macrolet ((access (name size)
             `(progn
                (defun ,name (address)
                  (clara.host::peek address ,size))
                (defun (setf ,name) (value address)
                  (clara.host::poke address ,size value))))
           (port (name size)
             `(progn
                (defun ,name (port)
                  (clara.host::port-in port ,size))
                (defun (setf ,name) (value port)
                  (clara.host::port-out port ,size value)))))
  (access memory-8 1)
  (access memory-16 2)
  (access memory-32 4)
  (access memory-64 8)
  (port port-8 1)
  (port port-16 2)
  (port port-32 4))

(defun fill-memory-32 (address count value)
  (dotimes (i count)
    (setf (memory-32 (+ address (* 4 i))) value))
  nil)

(defun copy-memory (to from bytes)
  (let ((to (clara.host::memory-index to bytes)) (from (clara.host::memory-index from bytes)))
    (replace clara.host::*memory* (subseq clara.host::*memory* from (+ from bytes)) :start1 to))
  nil)

;; A bit that is set becomes the word ONE and one that is not the word
;; ZERO, and NIL for either leaves the pixel as it is; the lowest SKIP bits
;; of a row are passed over.
(defun expand-bits-32 (address pitch bits start rows width one zero &optional (skip 0))
  (unless (and (<= 0 width) (<= (+ width skip) 62) (zerop (mod pitch 4)) (<= (* 4 width) pitch))
    (error "a row of ~D pixels does not fit in a fixnum, or in ~D bytes" width pitch))
  (dotimes (row rows)
    (dotimes (x width)
      (let ((word (if (logbitp (+ skip (- width 1 x)) (aref bits (+ start row))) one zero)))
        (when word
          (setf (memory-32 (+ address (* row pitch) (* 4 x))) word)))))
  nil)

;; A rectangle of pixels as ClaraOS takes one: so many in a row, so many
;; rows, and so many bytes from one row to the next.
(defun check-rectangle (pitch width height)
  (unless (and (integerp width) (integerp height) (<= 0 width 65536) (<= 0 height 65536)
               (integerp pitch) (zerop (mod pitch 4)) (<= (* 4 width) pitch (ash 1 24)))
    (error "~D rows of ~D pixels, ~D bytes from one row to the next, are not a rectangle of 32-bit pixels"
           height width pitch)))

(defun fill-rectangle-32 (address pitch width height value)
  (check-rectangle pitch width height)
  (dotimes (row height)
    (fill-memory-32 (+ address (* row pitch)) width value))
  nil)

;; All of it is read before any of it is written, which is right whichever
;; way the two rectangles lie over each other.
(defun copy-rectangle-32 (to to-pitch from from-pitch width height)
  (check-rectangle to-pitch width height)
  (check-rectangle from-pitch width height)
  (let ((pixels (make-array (* width height))))
    (dotimes (row height)
      (dotimes (x width)
        (setf (aref pixels (+ (* row width) x)) (memory-32 (+ from (* row from-pitch) (* 4 x))))))
    (dotimes (row height)
      (dotimes (x width)
        (setf (memory-32 (+ to (* row to-pitch) (* 4 x))) (aref pixels (+ (* row width) x))))))
  nil)

;; A colour laid over pixels, each taking as much of it as its shade says,
;; of 255. The parts of a pixel are the bits that the three masks have, and
;; each part is a number that goes that far towards the colour's, to the
;; nearest; the bits that are no part stay.
(defun blend-shades-32 (address pitch shades start step rows width color red green blue)
  (check-rectangle pitch width rows)
  (unless (vectorp shades)
    (error "CLARA.UNSAFE:BLEND-SHADES-32 wants a vector of shades, and ~S is not one" shades))
  (when (and (plusp rows) (plusp width))
    (unless (<= (+ start (* (1- rows) step) width) (length shades))
      (error "the vector has ~D shades, not ~D rows of ~D from ~D on" (length shades) rows width start))
    (dotimes (row rows)
      (dotimes (x width)
        (let ((shade (aref shades (+ start (* row step) x))))
          (unless (and (integerp shade) (<= 0 shade 255))
            (error "~S is not a shade: an integer from 0 to 255" shade)))))
    (dotimes (row rows)
      (dotimes (x width)
        (let ((shade (aref shades (+ start (* row step) x)))
              (at (+ address (* row pitch) (* 4 x))))
          (unless (zerop shade)
            (let* ((old (memory-32 at))
                   (new (logandc2 old (logior red green blue))))
              (dolist (mask (list red green blue))
                (unless (zerop mask)
                  (let* ((place (1- (integer-length (logand mask (- mask))))) ; how far up the part begins
                         (size (integer-length (ash mask (- place))))
                         (was (ldb (byte size place) old))
                         (to (ldb (byte size place) color)))
                    (setq new (dpb (round (+ (* was (- 255 shade)) (* to shade)) 255) (byte size place) new)))))
              (setf (memory-32 at) new)))))))
  nil)

;; Page frames side by side, all zeroes, the lowest that are free: and
;; what is given back has to have come from here, once.
(defun allocate-memory (pages)
  (sb-thread:with-mutex (clara.host::*pages-lock*)
    (let* ((map clara.host::*pages*)
           (first (and (plusp pages)
                       (loop for start from 0 to (- (length map) pages)
                             when (not (find 1 map :start start :end (+ start pages))) return start))))
      (unless first
        (error "there are no ~D page frames side by side to be had" pages))
      (fill map 1 :start first :end (+ first pages))
      (let ((index (* first 4096)))
        (fill clara.host::*memory* 0 :start index :end (+ index (* pages 4096)))
        (+ clara.host:+memory-base+ index)))))

(defun free-memory (address pages)
  (sb-thread:with-mutex (clara.host::*pages-lock*)
    (let ((first (floor (clara.host::memory-index address (* pages 4096)) 4096)))
      (unless (and (zerop (mod address 4096)) (plusp pages)
                   (not (find 0 clara.host::*pages* :start first :end (+ first pages))))
        (error "#x~(~X~) is not the address of ~D page frames that were handed out" address pages))
      (fill clara.host::*pages* 0 :start first :end (+ first pages))))
  nil)

(defun interrupt-event (source)
  (clara.host::interrupt-event source))

(defun framebuffer ()
  (values-list clara.host::*framebuffer*))

;; A file that came with the kernel: where it is and how long, or NIL.
(defun system-file (name)
  (unless (stringp name)
    (error "CLARA.UNSAFE:SYSTEM-FILE wants the name of a file, in a string, and ~S is not one" name))
  (let ((file (find name clara.host::*system-files* :key #'first :test #'string-equal)))
    (and file (values (second file) (third file)))))

(defun serial-device ()
  (values-list clara.host::*serial-device*))

(defun serial-byte ()
  (sb-thread:with-mutex (clara.host::*typed-lock*)
    (pop clara.host::*typed*)))

(defun serial-break (flag)
  (prog1 clara.host::*serial-break*
    (setq clara.host::*serial-break* (and flag t))))

(defun take-screen ()
  (values-list clara.host::*screen-cursor*))

(defun give-screen (row column)
  (setq clara.host::*given-screen* (list row column))
  nil)

;; The registers of a device become memory. Whole pages are mapped, as on
;; ClaraOS, and what is memory already is refused.
(defun map-memory (address bytes)
  (let ((first (* 4096 (floor address 4096)))
        (last (1- (* 4096 (ceiling (+ address bytes) 4096)))))
    (unless (plusp bytes)
      (error "~D bytes are not the registers of a device" bytes))
    (when (and (<= clara.host:+memory-base+ last)
               (< first (+ clara.host:+memory-base+ clara.host::+memory-size+)))
      (error "#x~(~X~) is memory, not the registers of a device" address))
    (push (cons first last) clara.host::*mapped*)
    address))

(defun pci-configuration ()
  (values-list clara.host::*pci-configuration*))

;; An interrupt for a PCI device to raise by a message. Every one has its
;; own number to write, and they all write to one address, which is no
;; address of the machine's memory and has more than 32 bits to it.
(defun message-interrupt (device)
  (let ((event (clara:make-event (format nil "PCI ~(~2,'0X:~2,'0X.~X~)" (ash device -8) (logand (ash device -3) 31)
                                         (logand device 7))))
        (data (+ 64 (length clara.host::*messages*))))
    (push (list device event #x1fee00000 data) clara.host::*messages*)
    (values event #x1fee00000 data)))

(defun keyboard-break ()
  (incf clara.host::*keyboard-breaks*)
  nil)

(defun power-off ()
  (push :off clara.host::*power*)
  nil)

(defun reset ()
  (push :again clara.host::*power*)
  nil)

(defun power-button ()
  (prog1 clara.host::*button*
    (setq clara.host::*button* nil)))

(defun sha-512 (address bytes)
  (let ((index (clara.host::memory-index address bytes)))
    (clara.host:sha-512-of (subseq clara.host::*memory* index (+ index bytes)))))

;; The check of a signature that the kernel has in C (kernel/ed25519.c):
;; here by SBCL's big numbers (CLARA.HOST:ED25519-VERIFY).
(defun ed25519 (address bytes signature key)
  (flet ((octets (text count)
           (and (stringp text) (= (length text) (* 2 count)) (every (lambda (c) (digit-char-p c 16)) text)
                (loop for i from 0 below (length text) by 2 collect (parse-integer text :start i :end (+ i 2) :radix 16)))))
    (let ((index (clara.host::memory-index address bytes)) (signature (octets signature 64)) (key (octets key 32)))
      (and signature key
           (clara.host:ed25519-verify key (subseq clara.host::*memory* index (+ index bytes)) signature)))))

;; What a connection that is kept closed is made of: the kernel's
;; arithmetic on bytes of memory, here by CLARA.HOST's.
(defun octets-at (address bytes)
  (let ((index (clara.host::memory-index address bytes)))
    (subseq clara.host::*memory* index (+ index bytes))))

(defun put-octets (address octets)
  (replace clara.host::*memory* octets :start1 (clara.host::memory-index address (length octets)))
  (length octets))

(defun digest (bits address bytes to)
  (unless (member bits '(256 384 512))
    (error "there is no sum of ~S bits here: there are the ones of 256, of 384 and of 512" bits))
  (put-octets to (clara.host:digest-of bits (octets-at address bytes))))

(defun hmac (bits key key-bytes address bytes to)
  (unless (member bits '(256 384 512))
    (error "there is no sum of ~S bits here: there are the ones of 256, of 384 and of 512" bits))
  (put-octets to (clara.host:hmac-of bits (octets-at key key-bytes) (octets-at address bytes))))

(defun aes-128-gcm-seal (key nonce beside beside-bytes from bytes to tag)
  (multiple-value-bind (closed sum)
      (clara.host:aes-gcm (octets-at key 16) (octets-at nonce 12) (octets-at beside beside-bytes) (octets-at from bytes))
    (put-octets to closed)
    (put-octets tag sum)
    t))

(defun aes-128-gcm-open (key nonce beside beside-bytes from bytes to tag)
  (let ((opened (clara.host:aes-gcm (octets-at key 16) (octets-at nonce 12) (octets-at beside beside-bytes) (octets-at from bytes)
                                    :opening t :tag (octets-at tag 16))))
    (and opened
         (progn
           (put-octets to opened)
           t))))

(defun x25519 (scalar point to)
  (let ((made (clara.host:x25519-of (octets-at scalar 32) (octets-at point 32))))
    (and (find-if #'plusp made)
         (progn
           (put-octets to made)
           t))))

(defun power-mod (base base-bytes exponent modulus modulus-bytes to)
  (and (<= 1 modulus-bytes 512) (<= base-bytes 1024)
       (let ((n (clara.host:octets-number (octets-at modulus modulus-bytes)))
             (b (clara.host:octets-number (octets-at base base-bytes))))
         (and (plusp (clara.unsafe:memory-8 modulus)) (oddp n) (> n 1) (< b n)
              (progn
                (put-octets to (clara.host:number-octets (clara.host:expt-mod b exponent n) modulus-bytes))
                t)))))

(defun ecdsa (bits key sum sum-bytes r r-bytes s s-bytes)
  (let ((curve (clara.host:curve bits)) (size (floor bits 8)))
    (and curve (<= sum-bytes 64) (<= r-bytes 128) (<= s-bytes 128)
         (clara.host:curve-verify curve
                                  (cons (clara.host:octets-number (octets-at key size))
                                        (clara.host:octets-number (octets-at (+ key size) size)))
                                  (octets-at sum sum-bytes)
                                  (clara.host:octets-number (octets-at r r-bytes))
                                  (clara.host:octets-number (octets-at s s-bytes)))
         t)))

;; The bytes of memory added up two at a time, the first of each two being
;; the higher half.
(defun internet-sum (address bytes)
  (let ((index (clara.host::memory-index address bytes)) (total 0))
    (dotimes (i bytes total)
      (setq total (+ total (ash (aref clara.host::*memory* (+ index i)) (if (evenp i) 8 0)))))))

(defun start-state ()
  (copy-list clara.host::*start-state*))

;; The text that some bytes of memory are: UTF-8, or it is an error.
(defun memory-string (address bytes)
  (let ((index (clara.host::memory-index address bytes)))
    (handler-case (sb-ext:octets-to-string clara.host::*memory* :start index :end (+ index bytes)
                                                                  :external-format :utf-8)
      (error ()
        (error "the ~D bytes at #x~(~X~) are not text: they are not UTF-8" bytes address)))))

;; The other way: how many bytes the text of a string is as UTF-8, and the
;; text written out at an address.
(defun string-bytes (string)
  (length (sb-ext:string-to-octets string :external-format :utf-8)))

(defun string-memory (string address)
  (let* ((octets (sb-ext:string-to-octets string :external-format :utf-8))
         (index (clara.host::memory-index address (length octets))))
    (replace clara.host::*memory* octets :start1 index)
    (length octets)))

;; The heap, as an image of it in page frames that the caller gives back:
;; their address, how many bytes of them the image is, and how many page
;; frames there are.
(defun heap-image ()
  (let* ((image clara.host::*heap-image*)
         (pages (max 1 (ceiling (length image) 4096)))
         (memory (allocate-memory pages)))
    (replace clara.host::*memory* image :start1 (clara.host::memory-index memory (length image)))
    (values memory (length image) pages)))
