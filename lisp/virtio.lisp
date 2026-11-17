;;;; virtio.lisp: what every virtio device has in common
;;;;
;;;; Virtio is how a virtual machine gives its guest a keyboard, a disk or
;;;; a network card without pretending to be some piece of hardware of old
;;;; (Virtual I/O Device specification, version 1.2; the numbers here are
;;;; from its chapters 2 and 4.1). A virtio device is a PCI device with two
;;;; things to it.
;;;;
;;;; Registers. A few are the same on every device: what state it is in,
;;;; what it can do and how much of that the driver wants, and where its
;;;; queues are. The device says in its PCI capabilities where they lie,
;;;; and the registers of its own kind likewise.
;;;;
;;;; Queues. Driver and device hand each other buffers of the driver's
;;;; memory through queues, and nothing else passes between them. A queue
;;;; is three tables in memory that both can reach. The descriptors say
;;;; where each buffer is, how long, and whether the device may write to
;;;; it; buffers can be chained into one piece of work. The driver puts the
;;;; number of a chain's first descriptor into the ring of what is
;;;; available and tells the device, by writing to a register. The device
;;;; does what its kind does with the chain, puts its number into the ring
;;;; of what is used, and raises its interrupt. Each side only ever adds to
;;;; its own ring, and counts how many it has added in 16 bits that go
;;;; round.
;;;;
;;;; This file is the part that no kind of device has to itself: OPEN-DEVICE
;;;; takes a PCI device through the opening moves, OPEN-QUEUE sets a queue
;;;; up, QUEUE-ADD, QUEUE-NOTIFY and QUEUE-TAKE are the driver's side of it,
;;;; and START-DEVICE says that the driver is ready. lisp/input.lisp is the
;;;; first driver on top of it.

(defpackage "CLARA.VIRTIO"
  (:use "COMMON-LISP")
  (:export "DEVICE-TYPE" "OPEN-DEVICE" "START-DEVICE" "DEVICE-P" "DEVICE-PCI" "DEVICE-EVENT"
           "REGISTER-8" "REGISTER-16" "REGISTER-32"
           "OPEN-QUEUE" "QUEUE-P" "QUEUE-SIZE" "QUEUE-ADD" "QUEUE-NOTIFY" "QUEUE-TAKE"))
(in-package "CLARA.VIRTIO")

;; What kind of virtio device a PCI device is, by the number the
;; specification gives each kind (5: 1 a network card, 2 a disk, 18 an
;; input device), or NIL when it is no virtio device at all. Red Hat's
;; vendor number, and a device number from #x1040 on, which is the kind
;; plus #x1040; the device numbers below that are from before version 1,
;; and such a device keeps its kind in its subsystem number.
(defun device-type (pci)
  (let ((id (clara.pci:device-id pci)))
    (cond ((/= (clara.pci:device-vendor pci) #x1af4) nil)
          ((<= #x1040 id #x107f) (- id #x1040))
          ((<= #x1000 id #x103f) (clara.pci:config-16 pci #x2e)))))

(defstruct device
  pci          ; the PCI device that it is
  common       ; the address of the registers that every virtio device has
  notify       ; the address of the registers through which queues are told of new work,
  multiplier   ; and how many bytes apart the queues' registers are there
  specific     ; the address of the registers of its own kind, or NIL
  event)       ; what its interrupt signals

;;; The registers of its own kind

(defun register-8 (device offset)
  (clara.unsafe:memory-8 (+ (device-specific device) offset)))

(defun register-16 (device offset)
  (clara.unsafe:memory-16 (+ (device-specific device) offset)))

(defun register-32 (device offset)
  (clara.unsafe:memory-32 (+ (device-specific device) offset)))

(defun set-register-8 (device offset value)
  (setf (clara.unsafe:memory-8 (+ (device-specific device) offset)) value))

(defun set-register-16 (device offset value)
  (setf (clara.unsafe:memory-16 (+ (device-specific device) offset)) value))

(defun set-register-32 (device offset value)
  (setf (clara.unsafe:memory-32 (+ (device-specific device) offset)) value))

(defsetf register-8 set-register-8)
(defsetf register-16 set-register-16)
(defsetf register-32 set-register-32)

;;; Opening a device
;;;
;;; The registers every device has (4.1.4.3), by their offsets:
;;;   #x00  which half of what the device can do is shown at #x04
;;;   #x08  which half of what the driver wants is written at #x0c
;;;   #x10  the message for a change of the device's own registers
;;;   #x14  the status of the device, a byte
;;;   #x16  which queue the registers from here on are about
;;;   #x18  its size   #x1a  its message   #x1c  its switch
;;;   #x1e  which of the registers for new work is its own
;;;   #x20  the addresses of its three tables, 64 bits each

;; The status of a device is a byte of bits that the driver sets one after
;; the other (2.1): 1, a driver has noticed the device; 2, and knows what
;; to do with it; 8, they agree on what the device is to do; 4, the driver
;; is ready; 128, the driver has given the device up.
(defun status (device)
  (clara.unsafe:memory-8 (+ (device-common device) #x14)))

(defun set-status (device value)
  (setf (clara.unsafe:memory-8 (+ (device-common device) #x14)) value))

(defun give-up (device control &rest arguments)
  (set-status device 128)
  (error "the virtio device at ~A ~A" (clara.pci:location (device-pci device))
         (apply #'format nil control arguments)))

;; Where the device keeps its registers. Every capability with the number 9
;; is a structure of virtio's (4.1.4): the byte at 3 says which registers
;; it is about, 1 the common ones, 2 the ones for new work, 4 the device's
;; own; the byte at 4 which base address register they are behind; and the
;; words at 8 and 12 where they begin there and how long they are. A
;; device may list a kind more than once, the one it would rather have
;; used first.
(defun find-registers (device)
  (let ((pci (device-pci device)))
    (dolist (at (clara.pci:capabilities pci 9))
      (let ((kind (clara.pci:config-8 pci (+ at 3)))
            (bar (clara.pci:config-8 pci (+ at 4)))
            (offset (clara.pci:config-32 pci (+ at 8)))
            (bytes (clara.pci:config-32 pci (+ at 12))))
        (cond ((and (= kind 1) (null (device-common device)))
               (setf (device-common device) (clara.pci:map-registers pci bar offset bytes)))
              ((and (= kind 2) (null (device-notify device)))
               (setf (device-notify device) (clara.pci:map-registers pci bar offset bytes)
                     (device-multiplier device) (clara.pci:config-32 pci (+ at 16))))
              ((and (= kind 4) (null (device-specific device)))
               (setf (device-specific device) (clara.pci:map-registers pci bar offset bytes))))))))

;; Take a PCI device that is a virtio device through its opening moves
;; (3.1.1), as far as agreeing on what it is to do. Of all that a device
;; can do, the driver asks for one thing, which is bit 32 and says that
;; both go by version 1 of the specification. The device gets one
;; interrupt, by a message, for all its queues, and none for a change of
;; its own registers. Then the driver sets up its queues, and calls
;; START-DEVICE.
(defun open-device (pci)
  (let ((device (make-device :pci pci)))
    (clara.pci:enable pci)
    (find-registers device)
    (unless (and (device-common device) (device-notify device))
      (error "the PCI device at ~A does not have the registers of a virtio device of version 1"
             (clara.pci:location pci)))
    (let ((common (device-common device)) (waited 0))
      ;; Writing 0 starts the device afresh, and it has when it reads as 0.
      (set-status device 0)
      (loop
        (when (zerop (status device))
          (return))
        (when (= waited 1000)
          (give-up device "does not start afresh when it is told to"))
        (setq waited (1+ waited)))
      (set-status device 1)
      (set-status device 3)
      (setf (clara.unsafe:memory-32 common) 1)
      (when (zerop (logand (clara.unsafe:memory-32 (+ common 4)) 1))
        (give-up device "is from before version 1 of virtio, which this driver does not speak"))
      (setf (clara.unsafe:memory-32 (+ common 8)) 0
            (clara.unsafe:memory-32 (+ common 12)) 0
            (clara.unsafe:memory-32 (+ common 8)) 1
            (clara.unsafe:memory-32 (+ common 12)) 1)
      (set-status device 11)
      (when (zerop (logand (status device) 8))
        (give-up device "does not want to do without what the driver did not ask for"))
      ;; A device that cannot have its interrupt is given up like any other.
      (handler-case (setf (device-event device) (clara.pci:message-interrupt pci 0))
        (error (condition)
          (set-status device 128)
          (error condition)))
      (setf (clara.unsafe:memory-16 (+ common #x10)) #xffff))
    device))

(defun start-device (device)
  (set-status device (logior (status device) 4))
  device)

;;; Queues

(defstruct queue
  device index
  size         ; how many descriptors it has
  descriptors  ; the addresses of its three tables
  available
  used
  doorbell     ; the address of the register that tells the device of new work
  free         ; the descriptors that are in no chain
  chains       ; by the number of a chain's first descriptor: its descriptors,
  tokens       ; and what the driver wants back when the device is done with it
  (added 0)    ; how many chains the driver has made available so far,
  (taken 0))   ; and how many it has taken back: both in 16 bits that go round

(defun page-frames (bytes)
  (floor (+ bytes 4095) 4096))

;; Set up queue INDEX of a device. Its size is the device's to say, and the
;; driver may make it smaller, down to LIMIT. The three tables (2.7): 16
;; bytes for each descriptor; the ring of what is available, 2 bytes each
;; behind 4 bytes of flags and count, and 2 more at its end; the ring of
;; what is used, 8 bytes each in the same frame. Each table gets page
;; frames of its own, all zeroes, whose address is the address the device
;; knows them by.
(defun open-queue (device index &optional (limit 256))
  (let ((common (device-common device)))
    (setf (clara.unsafe:memory-16 (+ common #x16)) index)
    (let ((size (clara.unsafe:memory-16 (+ common #x18))))
      (when (zerop size)
        (give-up device "has no queue ~D" index))
      (when (> size limit)
        (setq size limit)
        (setf (clara.unsafe:memory-16 (+ common #x18)) size))
      (let* ((descriptors (clara.unsafe:allocate-memory (page-frames (* 16 size))))
             (available (clara.unsafe:allocate-memory (page-frames (+ 6 (* 2 size)))))
             (used (clara.unsafe:allocate-memory (page-frames (+ 6 (* 8 size)))))
             (free nil))
        (dotimes (i size)
          (setq free (cons (- size 1 i) free)))
        (setf (clara.unsafe:memory-32 (+ common #x20)) (logand descriptors #xffffffff)
              (clara.unsafe:memory-32 (+ common #x24)) (ash descriptors -32)
              (clara.unsafe:memory-32 (+ common #x28)) (logand available #xffffffff)
              (clara.unsafe:memory-32 (+ common #x2c)) (ash available -32)
              (clara.unsafe:memory-32 (+ common #x30)) (logand used #xffffffff)
              (clara.unsafe:memory-32 (+ common #x34)) (ash used -32)
              (clara.unsafe:memory-16 (+ common #x1a)) 0)
        ;; The device answers #xffff when it has no such message to send.
        (unless (zerop (clara.unsafe:memory-16 (+ common #x1a)))
          (give-up device "cannot send its message for queue ~D" index))
        (setf (clara.unsafe:memory-16 (+ common #x1c)) 1)
        (make-queue :device device :index index :size size
                    :descriptors descriptors :available available :used used
                    :doorbell (+ (device-notify device)
                                 (* (clara.unsafe:memory-16 (+ common #x1e)) (device-multiplier device)))
                    :free free
                    :chains (make-array size :initial-element nil)
                    :tokens (make-array size :initial-element nil))))))

;; Make a piece of work available to the device: a chain of buffers, each
;; given as (address bytes writable), the ones the device is to write to
;; after the ones it is to read. TOKEN, which is not NIL, is what
;; QUEUE-TAKE gives when the device has done with the chain. T, or NIL
;; when the queue has not that many descriptors free. A descriptor (2.7.5):
;; the address, 8 bytes; the length, 4; flags, 2, of which bit 0 says that
;; another descriptor follows and bit 1 that the device may write; and the
;; number of the one that follows, 2.
(defun queue-add (queue buffers token)
  (let ((chain nil) (free (queue-free queue)))
    (dolist (buffer buffers)
      (declare (ignorable buffer))
      (when (null free)
        (return-from queue-add nil))
      (setq chain (cons (car free) chain)
            free (cdr free)))
    (setq chain (reverse chain))
    (setf (queue-free queue) free)
    (do ((descriptors chain (cdr descriptors))
         (rest buffers (cdr rest)))
        ((null descriptors))
      (let ((at (+ (queue-descriptors queue) (* 16 (car descriptors))))
            (buffer (car rest)))
        (setf (clara.unsafe:memory-64 at) (car buffer)
              (clara.unsafe:memory-32 (+ at 8)) (cadr buffer)
              (clara.unsafe:memory-16 (+ at 12)) (+ (if (cdr descriptors) 1 0) (if (caddr buffer) 2 0))
              (clara.unsafe:memory-16 (+ at 14)) (if (cdr descriptors) (cadr descriptors) 0))))
    (let ((first (car chain)) (added (queue-added queue)))
      (setf (aref (queue-chains queue) first) chain
            (aref (queue-tokens queue) first) token
            (clara.unsafe:memory-16 (+ (queue-available queue) 4 (* 2 (mod added (queue-size queue))))) first)
      ;; The count goes up last: that is what makes the chain the device's.
      (setq added (logand (1+ added) #xffff))
      (setf (queue-added queue) added
            (clara.unsafe:memory-16 (+ (queue-available queue) 2)) added))
    t))

;; Tell the device that there is new work in the queue: the number of the
;; queue, written to the queue's own register for it.
(defun queue-notify (queue)
  (setf (clara.unsafe:memory-16 (queue-doorbell queue)) (queue-index queue))
  nil)

;; The next piece of work that the device is done with: its token, and how
;; many bytes the device wrote into its buffers; NIL when there is none.
;; The descriptors of the chain are free again. An entry of the ring of
;; what is used (2.7.8) is the number of the chain's first descriptor and
;; that number of bytes, 4 bytes each, and the ring's count is the 2 bytes
;; at 2.
(defun queue-take (queue)
  (let ((taken (queue-taken queue)) (used (queue-used queue)))
    (unless (= taken (clara.unsafe:memory-16 (+ used 2)))
      (let* ((at (+ used 4 (* 8 (mod taken (queue-size queue)))))
             (first (clara.unsafe:memory-32 at))
             (bytes (clara.unsafe:memory-32 (+ at 4)))
             (chain (and (< first (queue-size queue)) (aref (queue-chains queue) first))))
        (unless chain
          (give-up (queue-device queue) "says that it is done with the buffer ~D of its queue ~D, which it does not have"
                   first (queue-index queue)))
        (setf (queue-taken queue) (logand (1+ taken) #xffff)
              (queue-free queue) (append chain (queue-free queue))
              (aref (queue-chains queue) first) nil)
        (values (aref (queue-tokens queue) first) bytes)))))
