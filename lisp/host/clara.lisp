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
           "JOIN-THREAD" "DESTROY-THREAD" "THREAD-YIELD"
           "MAKE-LOCK" "ACQUIRE-LOCK" "RELEASE-LOCK" "WITH-LOCK-HELD"
           "MAKE-EVENT" "SIGNAL-EVENT" "WAIT-EVENT"
           "MAKE-STREAM" "KEYBOARD-INTERRUPT" "PROVIDE-FILES" "SAVE-IMAGE"))

(defpackage "CLARA.UNSAFE"
  (:use "COMMON-LISP")
  (:export "MEMORY-8" "MEMORY-16" "MEMORY-32" "MEMORY-64"
           "FILL-MEMORY-32" "COPY-MEMORY" "EXPAND-BITS-32" "ALLOCATE-MEMORY" "FREE-MEMORY"
           "PORT-8" "PORT-16" "PORT-32"
           "INTERRUPT-EVENT" "FRAMEBUFFER" "SERIAL-DEVICE" "SERIAL-BYTE" "SERIAL-BREAK"
           "TAKE-SCREEN" "GIVE-SCREEN"
           "MAP-MEMORY" "PCI-CONFIGURATION" "MESSAGE-INTERRUPT" "KEYBOARD-BREAK" "MEMORY-STRING"
           "STRING-BYTES" "STRING-MEMORY" "HEAP-IMAGE"))

(defpackage "CLARA.HOST"
  (:use "COMMON-LISP")
  (:export "RESET-MACHINE" "+MEMORY-BASE+" "MAP-DEVICE" "MAP-PORTS"
           "SET-FRAMEBUFFER" "SET-SERIAL-DEVICE" "SET-SCREEN-CURSOR" "GIVEN-SCREEN"
           "TYPE-BYTES" "RAISE-INTERRUPT" "SERIAL-BREAK-P"
           "SET-PCI-CONFIGURATION" "SEND-MESSAGE" "MESSAGE-INTERRUPTS" "KEYBOARD-BREAKS"
           "ALLOCATED-PAGES" "PROVIDED-FILES" "SET-HEAP-IMAGE"))

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

(defun all-threads ()
  (sb-thread:with-mutex (*threads-lock*)
    (cons *this-thread* (remove *this-thread* (copy-list *threads*)))))

(defun make-thread (function &key name)
  (let ((thread (%make-thread :name name)))
    (sb-thread:with-mutex (*threads-lock*)
      (push thread *threads*))
    (setf (thread-native thread)
          (sb-thread:make-thread
           (lambda ()
             (let ((*this-thread* thread) (state :stopped) (result nil))
               (unwind-protect
                    (handler-case (setq result (multiple-value-list (funcall function))
                                        state :finished)
                      (serious-condition (condition)
                        (fresh-line)
                        (format t "error in ~S: ~A~%" thread condition)
                        (setq result condition
                              state :failed)))
                 (setf (thread-result thread) result
                       (thread-state thread) state)
                 (sb-thread:with-mutex (*threads-lock*)
                   (setq *threads* (remove thread *threads*))))))
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

(defun destroy-thread (thread)
  (when (thread-alive-p thread)
    (sb-thread:terminate-thread (thread-native thread))
    t))

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
   (fresh :initform t)))

(defun make-stream (&key write-string read-line)
  (make-instance 'function-stream :write write-string :read read-line))

(defmethod sb-gray:stream-write-string ((stream function-stream) string &optional (start 0) end)
  (let ((part (subseq string start end)))
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

(defun provide-files (&key text names write delete)
  (setq *files* (if (and text names) (list text names write delete)))
  nil)

;; SAVE-IMAGE as lisp/boot.lisp has it: the heap goes into a file, by way
;; of the file system that is there. The heap of this machine is whatever a
;; test says it is (CLARA.HOST:SET-HEAP-IMAGE).
(defun save-image (&optional (name "/clara/clara.image"))
  (let ((write (third *files*)))
    (unless write
      (error "the file ~A cannot be written: no disk has a file system that is known here" name))
    (multiple-value-bind (memory bytes pages) (clara.unsafe:heap-image)
      (unwind-protect (funcall write name memory bytes)
        (clara.unsafe:free-memory memory pages)))
    name))

;;; CLARA.HOST: the machine that is not there

(in-package "CLARA.HOST")

(defconstant +memory-base+ #x100000)   ; where the machine's memory begins,
(defconstant +memory-size+ #x400000)   ; and how much there is of it

(defvar *memory* (make-array +memory-size+ :element-type '(unsigned-byte 8) :initial-element 0))
(defvar *pages*              ; the page frames that ALLOCATE-MEMORY has handed out and FREE-MEMORY not had back
  (make-array (floor +memory-size+ 4096) :element-type 'bit :initial-element 0))
(defvar *pages-lock* (sb-thread:make-mutex :name "pages")) ; threads here run at the same time, as they do not on ClaraOS
(defvar *devices* nil)       ; (first last read write mapped): registers in memory
(defvar *mapped* nil)        ; (first . last): what MAP-MEMORY was called for
(defvar *pci-configuration* nil) ; what PCI-CONFIGURATION gives, as a list, or NIL
(defvar *messages* nil)      ; (device event address data): what MESSAGE-INTERRUPT has handed out, the last first
(defvar *keyboard-breaks* 0) ; how often KEYBOARD-BREAK was called
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
  (setq *devices* nil *ports* nil *framebuffer* nil *serial-device* nil
        *screen-cursor* nil *given-screen* nil *typed* nil *interrupts* nil *serial-break* t
        *mapped* nil *pci-configuration* nil *messages* nil *keyboard-breaks* 0)
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

;; How many page frames are handed out: a driver that gives back what it
;; takes leaves this as it was.
(defun allocated-pages ()
  (count 1 *pages*))

;; What CLARA:PROVIDE-FILES was given last: the functions, or NIL.
(defun provided-files ()
  clara::*files*)

;; What the heap of this machine is, to whoever saves it.
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

(defun expand-bits-32 (address pitch bits start rows width one zero)
  (dotimes (row rows)
    (dotimes (x width)
      (setf (memory-32 (+ address (* row pitch) (* 4 x)))
            (if (logbitp (- width 1 x) (aref bits (+ start row))) one zero))))
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
