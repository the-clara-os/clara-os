;;;; pci.lisp: the PCI bus
;;;;
;;;; A machine's devices sit on its PCI buses, and each says what it is in
;;;; 4 KiB of registers, its configuration space: who made it, what kind of
;;;; device it is, where its other registers are, what else it can do. On
;;;; the machines ClaraOS runs on, the configuration space of every device
;;;; is in memory, at an address that the firmware gives in a table
;;;; (CLARA.UNSAFE:PCI-CONFIGURATION): a megabyte for each bus, in it 32 KiB
;;;; for each of the 32 devices a bus can have, and in that a page for each
;;;; of a device's 8 functions. A function is what the rest of this file,
;;;; and every driver, calls a device.
;;;;
;;;; START looks at every place on the first bus where a device could be,
;;;; and behind every bridge it finds there. The firmware has done the same
;;;; before, and has given every device addresses for its registers, which
;;;; are taken as they are.
;;;;
;;;; A driver finds its device among DEVICES by the numbers in VENDOR, ID
;;;; and KIND, maps the registers that a base address register points at,
;;;; and asks for an interrupt. The numbers are those of the PCI Local Bus
;;;; Specification 3.0, chapter 6, and of the PCI Code and ID Assignment
;;;; Specification for the classes.
;;;;
;;;; This file loads under SBCL as well, where the tests put a
;;;; configuration space of their own making in front of it.

(defpackage "CLARA.PCI"
  (:use "COMMON-LISP")
  (:export "START" "DEVICES" "DEVICE-P" "DEVICE-BUS" "DEVICE-SLOT" "DEVICE-PART"
           "DEVICE-VENDOR" "DEVICE-ID" "DEVICE-KIND" "DEVICE-REVISION"
           "LOCATION" "DESCRIPTION" "HEX"
           "CONFIG-8" "CONFIG-16" "CONFIG-32"
           "CAPABILITIES" "BASE-ADDRESS" "MAP-REGISTERS" "ENABLE" "MESSAGE-INTERRUPT"))
(in-package "CLARA.PCI")

(defvar *base* nil)      ; the address at which the configuration space of bus 0 would begin
(defvar *first-bus* 0)   ; the buses that the firmware's table covers
(defvar *last-bus* 0)
(defvar *scanned* nil)   ; the buses that have been looked at
(defvar *devices* nil)   ; what was found there, in the order it was found

;; A device: where it is, and what it says it is. PART is which of the
;; eight functions of its slot it is, and KIND its class, its subclass and
;; its programming interface, a byte each, the class first.
(defstruct device
  bus slot part
  address      ; of its configuration space
  vendor id kind revision
  header)      ; how the rest of its configuration space is laid out: 0 for a device, 1 for a bridge

(defun devices ()
  *devices*)

;;; The configuration space of a device

(defun config-8 (device offset)
  (clara.unsafe:memory-8 (+ (device-address device) offset)))

(defun config-16 (device offset)
  (clara.unsafe:memory-16 (+ (device-address device) offset)))

(defun config-32 (device offset)
  (clara.unsafe:memory-32 (+ (device-address device) offset)))

(defun set-config-8 (device offset value)
  (setf (clara.unsafe:memory-8 (+ (device-address device) offset)) value))

(defun set-config-16 (device offset value)
  (setf (clara.unsafe:memory-16 (+ (device-address device) offset)) value))

(defun set-config-32 (device offset value)
  (setf (clara.unsafe:memory-32 (+ (device-address device) offset)) value))

(defsetf config-8 set-config-8)
(defsetf config-16 set-config-16)
(defsetf config-32 set-config-32)

;;; What a device is, in words

;; A number in hexadecimal, with that many digits.
(defun hex (number digits)
  (let ((text ""))
    (dotimes (i digits text)
      (setq text (concatenate 'string
                              (string (char "0123456789abcdef" (logand (ash number (* -4 i)) 15)))
                              text)))))

;; Where a device is, the way every tool writes it: bus, slot and function.
(defun location (device)
  (format nil "~A:~A.~D" (hex (device-bus device) 2) (hex (device-slot device) 2) (device-part device)))

;; The same three as one number, which is how the device is known to
;; whatever takes its interrupts.
(defun source (device)
  (+ (* 256 (device-bus device)) (* 8 (device-slot device)) (device-part device)))

(defun description (device)
  (let ((class (ash (device-kind device) -16))
        (subclass (logand (ash (device-kind device) -8) 255)))
    (case class
      (1 (case subclass
           (0 "a SCSI controller")
           (1 "an IDE controller")
           (6 "a SATA controller")
           (8 "an NVMe controller")
           (t "a storage controller")))
      (2 "a network controller")
      (3 "a display controller")
      (4 "a sound or video device")
      (5 "a memory controller")
      (6 (case subclass
           (0 "a host bridge")
           (1 "an ISA bridge")
           (4 "a PCI bridge")
           (t "a bridge")))
      (7 "a serial port or the like")
      (8 "a system device")
      (9 (case subclass
           (0 "a keyboard")
           (2 "a mouse")
           (t "an input device")))
      (12 (case subclass
            (3 "a USB controller")
            (5 "an SMBus controller")
            (t "a serial bus controller")))
      (t "a device of a class without a name here"))))

;;; Finding the devices

;; The device at a place, when there is one: an empty place reads as all
;; ones.
(defun probe (bus slot part)
  (let* ((address (+ *base* (ash bus 20) (ash slot 15) (ash part 12)))
         (vendor (clara.unsafe:memory-16 address)))
    (unless (= vendor #xffff)
      (let ((class (clara.unsafe:memory-32 (+ address 8))))
        (make-device :bus bus :slot slot :part part :address address
                     :vendor vendor
                     :id (clara.unsafe:memory-16 (+ address 2))
                     :kind (ash class -8)
                     :revision (logand class 255)
                     :header (logand (clara.unsafe:memory-8 (+ address 14)) 127))))))

;; Every device of a bus, and then the buses behind its bridges. A device
;; says in bit 7 of its header type whether it has more functions than the
;; first, and a bridge says at #x19 which bus is behind it: the firmware
;; numbered them.
(defun scan (bus)
  (unless (or (member bus *scanned*) (< bus *first-bus*) (> bus *last-bus*))
    (setq *scanned* (cons bus *scanned*))
    (clara.unsafe:map-memory (+ *base* (ash bus 20)) (ash 1 20))
    (let ((behind nil))
      (dotimes (slot 32)
        (let ((first (probe bus slot 0)))
          (when first
            (dotimes (part (if (zerop (logand (config-8 first 14) 128)) 1 8))
              (let ((device (if (zerop part) first (probe bus slot part))))
                (when device
                  (setq *devices* (cons device *devices*))
                  (when (= (device-header device) 1)
                    (setq behind (cons (config-8 device #x19) behind)))))))))
      (dolist (next (reverse behind))
        (scan next)))))

;; Find the devices, and say what was found. The list of them, which is
;; empty on a machine whose firmware names no configuration space.
(defun start ()
  (setq *devices* nil
        *scanned* nil)
  (multiple-value-bind (base first last) (clara.unsafe:pci-configuration)
    (if (null base)
        (format t "pci: the firmware names no configuration space, so no PCI device can be found~%")
        (handler-case
            (progn
              (setq *base* base
                    *first-bus* first
                    *last-bus* last)
              (scan first)
              (setq *devices* (reverse *devices*))
              (format t "pci: ~D devices, by the configuration space at #x~A~%"
                      (length *devices*) (hex base 10))
              (dolist (device *devices*)
                (format t "pci:   ~A ~A:~A ~A~%" (location device) (hex (device-vendor device) 4)
                        (hex (device-id device) 4) (description device))))
          (error (condition)
            (setq *devices* nil)
            (format t "pci: the devices could not be found: ~A~%" condition)))))
  *devices*)

;;; What a driver asks of its device

;; The places in the configuration space of the capabilities with this
;; number, in the order the device lists them. Bit 4 of the status register
;; says that there is a list, the byte at #x34 where it begins, and each
;; capability has its number in its first byte and the place of the next
;; in its second. A list that leads back into itself ends after 48, which
;; is as many as fit.
(defun capabilities (device id)
  (let ((found nil))
    (unless (zerop (logand (config-16 device 6) 16))
      (let ((at (logand (config-8 device #x34) 252)) (seen 0))
        (loop
          (when (or (zerop at) (= seen 48))
            (return))
          (when (= (config-8 device at) id)
            (setq found (cons at found)))
          (setq at (logand (config-8 device (1+ at)) 252)
                seen (1+ seen)))))
    (reverse found)))

;; The address in base address register N, and whether it is of memory or
;; of I/O ports. NIL when the register holds none. An address of 64 bits
;; takes the register after it as well (bits 1 and 2 say so).
(defun base-address (device n)
  (let* ((offset (+ 16 (* 4 n)))
         (low (config-32 device offset)))
    (cond ((= 1 (logand low 1))
           (values (logand low #xfffffffc) :ports))
          (t
           (let ((address (if (= 4 (logand low 6))
                              (+ (logand low #xfffffff0) (ash (config-32 device (+ offset 4)) 32))
                              (logand low #xfffffff0))))
             (if (zerop address)
                 nil
                 (values address :memory)))))))

;; BYTES of the registers that base address register N points at, from
;; OFFSET on, as memory: the address at which they can be read and written.
(defun map-registers (device n offset bytes)
  (multiple-value-bind (address kind) (base-address device n)
    (unless (eq kind :memory)
      (error "the PCI device ~A has no registers in memory behind its base address register ~D"
             (location device) n))
    (clara.unsafe:map-memory (+ address offset) bytes)))

;; The device answers at the addresses of its registers, and may read and
;; write memory by itself, which is also how it sends a message: bits 1
;; and 2 of its command register.
(defun enable (device)
  (setf (config-16 device 4) (logior (config-16 device 4) 6))
  device)

;; The older way of sending a message (MSI, capability 5; 6.8.1), for a
;; device that has no table: one message, whose address and number are
;; registers of the capability itself. The word at 2 says in bit 7 whether
;; the address has 64 bits, and with it a second half at 8, which moves
;; the number from 8 to 12; its bit 0 switches the message on, and bits 4
;; to 6 would ask for more messages than the one.
(defun plain-message (device capability index)
  (let* ((control (config-16 device (+ capability 2)))
         (wide (/= 0 (logand control 128))))
    (unless (eql index 0)
      (error "the PCI device ~A has one message to send, and none with the number ~D" (location device) index))
    (multiple-value-bind (event address data) (clara.unsafe:message-interrupt (source device))
      (when (and (not wide) (>= address #x100000000))
        (error "the PCI device ~A cannot send a message to an address of more than 32 bits" (location device)))
      (setf (config-32 device (+ capability 4)) (logand address #xffffffff))
      (when wide
        (setf (config-32 device (+ capability 8)) (ash address -32)))
      (setf (config-16 device (+ capability (if wide 12 8))) data
            (config-16 device (+ capability 2)) (logior (logand control #xff8e) 1)
            (config-16 device 4) (logior (config-16 device 4) #x400))
      event)))

;; An interrupt for the device, which it raises by sending a message
;; (MSI-X, capability #x11). The device has a table of the messages it can
;; send, 16 bytes each: the address to write to, in two halves, what to
;; write, and a word whose lowest bit keeps the message back. Entry INDEX
;; of the table is filled in with what the interrupt controller says
;; (CLARA.UNSAFE:MESSAGE-INTERRUPT), messages are switched on, and the
;; interrupt line of old is switched off (bit 10 of the command register).
;; What is returned is the event that the interrupt signals; which of its
;; messages the device sends for what is for its driver to tell it. A
;; device without such a table has one message of the older way, which is
;; its number 0.
(defun message-interrupt (device index)
  (let ((capability (car (capabilities device #x11))))
    (unless capability
      (let ((plain (car (capabilities device 5))))
        (when plain
          (return-from message-interrupt (plain-message device plain index))))
      (error "the PCI device ~A cannot send a message for an interrupt: it has neither MSI-X nor MSI" (location device)))
    (let* ((control (config-16 device (+ capability 2)))
           (table (config-32 device (+ capability 4)))
           (entries (1+ (logand control #x7ff))))
      (unless (< -1 index entries)
        (error "the PCI device ~A has ~D messages to send, and none with the number ~D"
               (location device) entries index))
      (multiple-value-bind (event address data) (clara.unsafe:message-interrupt (source device))
        (let ((entry (+ (map-registers device (logand table 7) (logand table #xfffffff8) (* 16 entries))
                        (* 16 index))))
          (setf (clara.unsafe:memory-32 entry) (logand address #xffffffff)
                (clara.unsafe:memory-32 (+ entry 4)) (ash address -32)
                (clara.unsafe:memory-32 (+ entry 8)) data
                (clara.unsafe:memory-32 (+ entry 12)) 0))
        ;; Bit 15 switches the messages on, and bit 14 would keep them all back.
        (setf (config-16 device (+ capability 2)) (logior (logand control #x3fff) #x8000)
              (config-16 device 4) (logior (config-16 device 4) #x400))
        event))))
