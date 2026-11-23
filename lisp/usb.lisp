;;;; usb.lisp: the Universal Serial Bus
;;;;
;;;; A USB device does not sit on the PCI bus. It hangs from a port of a
;;;; controller that does, and only the controller speaks to it: the driver
;;;; tells the controller what to say, and the controller says when it is
;;;; said and what came back. The controllers that are driven here are of
;;;; the newest kind, xHCI (eXtensible Host Controller Interface, revision
;;;; 1.2, Intel 2019; the numbers of chapters below are that document's),
;;;; which is what UTM gives a machine, with a keyboard, a mouse and a
;;;; tablet at its ports. What a device is asked, and what it says of
;;;; itself, is in the Universal Serial Bus Specification, revision 2.0,
;;;; chapter 9.
;;;;
;;;; Driver and controller hand each other work through rings, as virtio's
;;;; do through queues. A ring is a page frame of entries of 16 bytes, each
;;;; a piece of work (a TRB, 4.11): eight bytes of it are an address or a
;;;; few numbers, four more are lengths, and the last four say what kind of
;;;; work it is, and, in their lowest bit, which lap of the ring it belongs
;;;; to. Whoever writes a ring writes that bit as it stands in this lap,
;;;; and whoever reads one stops at the first entry that has it the other
;;;; way round, which is one of the lap before. The driver writes one ring
;;;; of commands for the controller itself and one for every endpoint of a
;;;; device that it speaks to; the controller writes one ring, of events:
;;;; a command is done, a transfer is done, something happened at a port.
;;;;
;;;; A device has endpoints, numbered places that bytes go to or come from.
;;;; Endpoint 0 is there on every device and takes requests (CONTROL): eight
;;;; bytes that say what is asked, then bytes one way or the other, then a
;;;; word that it went well. The others are of the device's own kind. A
;;;; keyboard or a mouse has one from which a report is fetched every few
;;;; thousandths of a second, when it has one to give: LISTEN-AT has the
;;;; controller ask there for good, and calls a function with every report
;;;; that comes.
;;;;
;;;; What the reports of a keyboard or a mouse mean is not this file's
;;;; business. It finds the devices, says what each says it is (its
;;;; interfaces, by class), and carries bytes. lisp/input.lisp takes the
;;;; interfaces of the class 3, the things that people type and point with.
;;;;
;;;; One thread for each controller waits for its interrupt and takes in
;;;; the events. Everything that speaks to a controller runs in that
;;;; thread, or before it is started: START itself, and whatever START and
;;;; the thread call when a device has arrived (*ARRIVAL*). So nothing here
;;;; needs a lock.

(defpackage "CLARA.USB"
  (:use "COMMON-LISP")
  (:export "START" "DEVICES" "DEVICE-P" "DEVICE-PLACE" "DEVICE-NAME" "DEVICE-VENDOR" "DEVICE-PRODUCT"
           "DEVICE-INTERFACES" "INTERFACE-P" "INTERFACE-DEVICE" "INTERFACE-NUMBER" "INTERFACE-CLASS"
           "INTERFACE-SUBCLASS" "INTERFACE-PROTOCOL" "INTERFACE-EXTRAS"
           "CONTROL" "LISTEN-AT" "*ARRIVAL*" "*DEPARTURE*"))
(in-package "CLARA.USB")

(defvar *controllers* nil)   ; the ones that START found and opened
(defvar *patience* 2000)     ; how many milliseconds a controller or a device may take over what it is asked
(defvar *arrival* nil)       ; a function that is called with every device that has arrived and said what it is,
(defvar *departure* nil)     ; and one that is called with a device that has been taken away

(defstruct ring
  memory          ; a page frame: 255 entries, and a last one that leads back to the first
  (next 0)        ; the entry that is written next,
  (cycle 1))      ; and the bit that this lap is written with

(defstruct controller
  pci name
  operational     ; the address of its operational registers (5.4),
  runtime         ; of the registers of its first interrupter (5.5.2),
  doorbells       ; and of its doorbells (5.6): one for the commands, and one for every device
  ports           ; how many ports it has,
  wide            ; whether a context is 64 bytes, and not 32 (the bit CSZ),
  table           ; a page frame of addresses, the device contexts by the numbers of their slots (6.1)
  input           ; a page frame for what a command is told about a device (6.2.5)
  commands        ; the ring of commands
  events          ; the page frame of the ring of events, which the controller writes,
  (event-next 0)  ; the entry of it that is read next,
  (event-cycle 1) ; and the bit that an entry of this lap has
  event           ; what its interrupt signals
  quiet           ; an event of the driver's own that nothing signals: to wait a while
  done            ; what was said of commands and transfers and nobody has asked for yet: (address code left slot)
  changed         ; the ports at which something happened, and that have not been looked at yet
  failed          ; the ports whose device did not start, and that have not said since that they were plugged anew
  devices         ; what is at its ports
  thread)

(defstruct device
  controller
  port            ; the port of the controller that it hangs from, counted from 1
  slot            ; the number that the controller knows it by
  speed           ; 1 full, 2 low, 3 high, 4 super (the numbers of 7.2.2.1.1)
  context         ; a page frame that the controller keeps what it knows of the device in
  ring            ; the ring of endpoint 0
  page            ; a page frame for the bytes of a request
  vendor product  ; who made it and what it is, by number
  name            ; what it calls itself, or NIL
  interfaces
  endpoints)      ; the ones that are listened at

(defstruct interface
  device number
  class subclass protocol   ; what kind of thing it is: 3 is something to type or point with
  endpoints                 ; each (address attributes most interval), as the device says it
  extras)                   ; the descriptors that came with it and are of its class's own kind: (type . bytes)

(defstruct endpoint
  device
  index           ; twice its number, and one more when bytes come from it (4.5.1)
  ring
  buffer          ; where a report is put,
  most            ; and how many bytes one has at the most
  function)       ; what is called with each

(defun devices ()
  (let ((all nil))
    (dolist (controller *controllers* all)
      (setq all (append all (controller-devices controller))))))

;; Where a device is, in words: the controller's place on the PCI bus, and
;; the port.
(defun device-place (device)
  (format nil "~A port ~D" (controller-name (device-controller device)) (device-port device)))

;;; Registers and memory

(defun r32 (address)
  (clara.unsafe:memory-32 address))

(defun w32 (address value)
  (setf (clara.unsafe:memory-32 address) value))

;; An address of 64 bits, in two halves, the lower one first: a register
;; that takes one is written in that order (5.1).
(defun w64 (address value)
  (w32 address (logand value #xffffffff))
  (w32 (+ address 4) (ash value -32)))

(defun bit-p (value n)
  (/= 0 (logand value (ash 1 n))))

;; Wait until TEST is true, looking every hundredth of a second: T, or an
;; error that says in the words of WHAT what the controller did not do.
(defun settle (controller what test)
  (let ((waited 0))
    (loop
      (when (funcall test)
        (return t))
      (when (>= waited *patience*)
        (error "the USB controller ~A ~A in ~D milliseconds" (controller-name controller) what waited))
      (clara:wait-event (controller-quiet controller) 10)
      (setq waited (+ waited 10)))))

;;; Rings

;; A new ring. Its last entry is a link (the kind 6) back to the first,
;; whose bit 1 has the controller turn its own lap bit over as it follows.
(defun new-ring ()
  (let ((memory (clara.unsafe:allocate-memory 1)))
    (w64 (+ memory (* 16 255)) memory)
    (make-ring :memory memory)))

;; Write an entry: its address or numbers in two halves, its lengths, and
;; what it is, to which this lap's bit is added. The address of the entry,
;; which is how the controller names it when it is done.
(defun ring-put (ring low high status control)
  (let* ((index (ring-next ring)) (at (+ (ring-memory ring) (* 16 index))))
    (w32 at low)
    (w32 (+ at 4) high)
    (w32 (+ at 8) status)
    (w32 (+ at 12) (logior control (ring-cycle ring)))
    (cond ((< index 254)
           (setf (ring-next ring) (1+ index)))
          (t
           ;; The link is given to the controller with this lap's bit, and the next lap has the other.
           (w32 (+ (ring-memory ring) (* 16 255) 12) (logior (ash 6 10) 2 (ring-cycle ring)))
           (setf (ring-next ring) 0
                 (ring-cycle ring) (- 1 (ring-cycle ring)))))
    at))

;; Where the controller is to go on in a ring, as it wants to be told: the
;; address of the next entry, with the lap's bit in its lowest.
(defun ring-place (ring)
  (logior (+ (ring-memory ring) (* 16 (ring-next ring))) (ring-cycle ring)))

;;; Events
;;;
;;; An event (6.4.2) has the address of the entry that it is about in its
;;; first eight bytes; in the next four a code for how it went, in the
;;; highest byte, 1 for well and 13 for fewer bytes than there was room
;;; for, and under it how many bytes were not transferred; and in the last
;;; four its kind, in bits 10 to 15, the slot of the device in the highest
;;; byte and the endpoint in bits 16 to 20.

(defun said (code)
  (case code
    (1 "that it went well")
    (4 "that the device did not answer as a device should")
    (6 "that the device refused")
    (9 "that it has no room for another device")
    (13 "that fewer bytes came than there was room for")
    (t (format nil "~D, which is one of its numbers for what went wrong" code))))

(defun device-of-slot (controller slot)
  (find-if (lambda (device) (eql (device-slot device) slot)) (controller-devices controller)))

(defun endpoint-of (device index)
  (find-if (lambda (endpoint) (= (endpoint-index endpoint) index)) (device-endpoints device)))

;; Ask for the next report of an endpoint: one entry of the plain kind
;; (1), with room for a whole report, which is to be said when it is done
;; (bit 5) also when fewer bytes came (bit 2); and the device's doorbell
;; is rung with the endpoint's number.
(defun ask (endpoint)
  (let* ((device (endpoint-device endpoint)) (controller (device-controller device)))
    (ring-put (endpoint-ring endpoint) (logand (endpoint-buffer endpoint) #xffffffff) (ash (endpoint-buffer endpoint) -32)
              (endpoint-most endpoint) (logior (ash 1 10) 32 4))
    (w32 (+ (controller-doorbells controller) (* 4 (device-slot device))) (endpoint-index endpoint))))

;; A report has come: the function is given its bytes, and the next one is
;; asked for. What the function does wrong is said, and the endpoint goes
;; on. An endpoint that the controller says something else of than that it
;; went well is not asked again: the device is silent from then on.
(defun report (endpoint code left)
  (cond ((or (= code 1) (= code 13))
         (let* ((count (max 0 (- (endpoint-most endpoint) left)))
                (bytes (make-array count :initial-element 0)))
           (dotimes (i count)
             (setf (svref bytes i) (clara.unsafe:memory-8 (+ (endpoint-buffer endpoint) i))))
           (handler-case (funcall (endpoint-function endpoint) bytes)
             (error (condition)
               (fresh-line)
               (format t "usb: what the device at ~A sent came to nothing: ~A~%"
                       (device-place (endpoint-device endpoint)) condition)))
           (ask endpoint)))
        (t
         (fresh-line)
         (format t "usb: the device at ~A is no longer heard: the controller says ~A~%"
                 (device-place (endpoint-device endpoint)) (said code)))))

(defun handle (controller low high status control)
  (let ((kind (logand (ash control -10) 63))
        (code (ash status -24))
        (slot (ash control -24)))
    (case kind
      (32 (let* ((device (device-of-slot controller slot))
                 (endpoint (and device (endpoint-of device (logand (ash control -16) 31)))))
            (if endpoint
                (report endpoint code (logand status #xffffff))
                (setf (controller-done controller)
                      (cons (list (+ low (ash high 32)) code (logand status #xffffff) slot)
                            (controller-done controller))))))
      (33 (setf (controller-done controller)
                (cons (list (+ low (ash high 32)) code 0 slot) (controller-done controller))))
      (34 (let ((port (ash low -24)))
            (unless (member port (controller-changed controller))
              (setf (controller-changed controller) (append (controller-changed controller) (list port)))))))))

;; Take in every event that the controller has written, and tell it how
;; far the reading has come (the register ERDP, whose bit 3 says that the
;; events were taken, and lets the controller interrupt again). T when
;; there was one.
(defun take-events (controller)
  (let ((taken nil))
    (loop
      (let* ((at (+ (controller-events controller) (* 16 (controller-event-next controller))))
             (control (r32 (+ at 12))))
        (unless (= (logand control 1) (controller-event-cycle controller))
          (return))
        (setq taken t)
        (if (= (controller-event-next controller) 255)
            (setf (controller-event-next controller) 0
                  (controller-event-cycle controller) (- 1 (controller-event-cycle controller)))
            (setf (controller-event-next controller) (1+ (controller-event-next controller))))
        (handle controller (r32 at) (r32 (+ at 4)) (r32 (+ at 8)) control)))
    (when taken
      (w64 (+ (controller-runtime controller) #x18)
           (logior (+ (controller-events controller) (* 16 (controller-event-next controller))) 8)))
    taken))

;; What the controller said of the entry at ADDRESS, taken off the list:
;; (address code left slot), or NIL when it has said nothing of it yet.
(defun answer-for (controller address)
  (let ((answer (find-if (lambda (answer) (= (car answer) address)) (controller-done controller))))
    (when answer
      (setf (controller-done controller) (remove-if (lambda (other) (eq other answer)) (controller-done controller))))
    answer))

;; Wait for what FOUND looks for, taking in events meanwhile. A wait ends
;; every tenth of a second to look, so an interrupt that got lost costs
;; that; under QEMU the answer is there before the first look.
(defun await (controller found what)
  (let ((waited 0))
    (loop
      (take-events controller)
      (let ((answer (funcall found)))
        (when answer
          (return answer)))
      (unless (clara:wait-event (controller-event controller) 100)
        (setq waited (+ waited 100))
        (when (>= waited *patience*)
          (error "the USB controller ~A was asked ~A and has not answered in ~D milliseconds"
                 (controller-name controller) what waited))))))

;; A command for the controller itself (4.6): the entry, the doorbell
;; that has the number 0, and the answer, which is an error unless it says
;; that it went well. The slot that the answer names.
(defun command (controller low high control what)
  (let ((entry (ring-put (controller-commands controller) low high 0 control)))
    (w32 (controller-doorbells controller) 0)
    (let ((answer (await controller (lambda () (answer-for controller entry)) what)))
      (unless (= (second answer) 1)
        (error "the USB controller ~A was asked ~A and says ~A" (controller-name controller) what (said (second answer))))
      (fourth answer))))

;;; What a command is told about a device
;;;
;;; The page that a command points at (6.2.5) begins with a context of
;;; flags, which says in its second word which of the contexts after it the
;;; command is to take: bit 0 the device's own, the slot's, and bit N the
;;; endpoint with the index N. The slot's context says how fast the device
;;; is, at which port it hangs, and what the highest index of its endpoints
;;; is; an endpoint's says what kind it is, how many bytes go in one
;;; packet, and where its ring is.

(defun context-bytes (controller)
  (if (controller-wide controller) 64 32))

(defun fill-input (device flags entries)
  (let* ((controller (device-controller device)) (input (controller-input controller))
         (slot (+ input (context-bytes controller))))
    (w32 (+ input 4) flags)
    (w32 slot (logior (ash entries 27) (ash (device-speed device) 20)))
    (w32 (+ slot 4) (ash (device-port device) 16))
    input))

;; The context of the endpoint with the index INDEX: its kind (4 for
;; requests, 7 for one that is asked every so often and gives bytes), up
;; to three tries, the bytes of a packet, how often it is asked, and its
;; ring.
(defun fill-endpoint (device index kind most interval ring)
  (let* ((controller (device-controller device))
         (at (+ (controller-input controller) (* (1+ index) (context-bytes controller)))))
    (w32 at (ash interval 16))
    (w32 (+ at 4) (logior (ash 3 1) (ash kind 3) (ash most 16)))
    (w64 (+ at 8) (ring-place ring))
    (w32 (+ at 16) (logior most (ash most 16)))))

;;; Requests
;;;
;;; A request to endpoint 0 (4.11.2.2, and chapter 9 of the USB
;;; specification) is three entries: the eight bytes of the request
;;; themselves, in the entry (the kind 2, bit 6); the bytes that go with it
;;; or come back, when there are any (the kind 3; bit 16 says that they
;;; come back, and bit 2 that the controller is to say so when fewer came);
;;; and the word that it went well, which goes the other way than the
;;; bytes (the kind 4), and is the one that the controller is to speak of
;;; when it is done (bit 5).

;; The endpoint of a device stands still after something went wrong at
;; it, until it is told to start again (the command 14) and where (16).
(defun mend (device)
  (let ((controller (device-controller device)) (slot (ash (device-slot device) 24)))
    (handler-case
        (progn
          (command controller 0 0 (logior (ash 14 10) (ash 1 16) slot) "to let a device's requests through again")
          (let ((place (ring-place (device-ring device))))
            (command controller (logand place #xffffffff) (ash place -32) (logior (ash 16 10) (ash 1 16) slot)
                     "where a device's requests go on")))
      (error () nil))))

;; Ask a device something: KIND says who is asked and which way the bytes
;; go (bit 7: from the device), REQUEST what is asked, VALUE and INDEX what
;; about. With bytes to come, LENGTH is how many at the most, and what is
;; returned is a vector of the ones that came; otherwise DATA is the bytes
;; that go with the request, a list, and what is returned is T. A device
;; that refuses is an error.
(defun control (device kind request value index &optional (length 0) data)
  (let* ((controller (device-controller device)) (ring (device-ring device)) (page (device-page device))
         (in (>= kind 128))
         (length (if in length (length data)))
         (setup nil) (body nil) (end nil) (came length))
    (when (> length 4096)
      (error "a request of ~D bytes is more than a page, which is all that a request carries here" length))
    (unless in
      (let ((i 0))
        (dolist (byte data)
          (setf (clara.unsafe:memory-8 (+ page i)) byte)
          (setq i (1+ i)))))
    (setq setup (ring-put ring (logior kind (ash request 8) (ash value 16)) (logior index (ash length 16)) 8
                          (logior (ash 2 10) 64 (ash (cond ((zerop length) 0) (in 3) (t 2)) 16))))
    (when (plusp length)
      (setq body (ring-put ring (logand page #xffffffff) (ash page -32) length
                           (logior (ash 3 10) 4 (if in 65536 0)))))
    (setq end (ring-put ring 0 0 0 (logior (ash 4 10) 32 (if (and in (plusp length)) 0 65536))))
    (w32 (+ (controller-doorbells controller) (* 4 (device-slot device))) 1)
    ;; What is said of the three: of the bytes that fewer came, of the last that it is done, of any
    ;; that something went wrong.
    (let ((wrong (await controller
                        (lambda ()
                          (let ((found nil))
                            (dolist (entry (list setup body end) found)
                              (let ((answer (and entry (not found) (answer-for controller entry))))
                                (when answer
                                  (cond ((and (eq entry body) (= (second answer) 13))
                                         (setq came (- length (third answer))))
                                        ((and (eq entry end) (= (second answer) 1))
                                         (setq found :done))
                                        ((/= (second answer) 1)
                                         (setq found (second answer)))))))))
                        "to pass a request on to a device")))
      (unless (eq wrong :done)
        (mend device)
        (error "the USB device at ~A was asked for ~D of the kind ~D, and the controller says ~A"
               (device-place device) request kind (said wrong))))
    (if in
        (let ((bytes (make-array came :initial-element 0)))
          (dotimes (i came bytes)
            (setf (svref bytes i) (clara.unsafe:memory-8 (+ page i)))))
        t)))

;;; What a device says of itself
;;;
;;; A descriptor (9.6) is some bytes that begin with their own count and
;;; their kind: 1 for the device, 2 for a way of setting it up, 4 for an
;;; interface, 5 for an endpoint, 3 for a text. The device is asked for one
;;; by the request 6, with the kind in the upper byte of VALUE. Asked for
;;; its setting up, it gives that descriptor and after it those of all its
;;; interfaces and their endpoints, and whatever a class has of its own
;;; between them.

(defun two (bytes at)
  (+ (svref bytes at) (* 256 (svref bytes (1+ at)))))

;; A text of a device, by its number: letters of 16 bits each, in English
;; of the United States (#x0409), of which those of ASCII are kept. NIL
;; when the device has no such text, or does not say.
(defun text (device number)
  (when (plusp number)
    (handler-case
        (let ((bytes (control device #x80 6 (+ #x300 number) #x0409 255)) (text ""))
          (do ((at 2 (+ at 2))) ((>= (1+ at) (min (length bytes) (svref bytes 0))) text)
            (let ((code (two bytes at)))
              (when (< 31 code 127)
                (setq text (concatenate 'string text (string (code-char code))))))))
      (error () nil))))

;; The interfaces of a device, from the bytes of its setting up: each
;; descriptor in turn, by its count, and one that says it has fewer than
;; two bytes ends the reading. Only the first way of each interface is
;; taken (its byte at 3 is 0), and what follows another is passed over.
(defun read-interfaces (device bytes)
  (let ((found nil) (current nil) (at 0))
    (loop
      (when (or (>= (1+ at) (length bytes)) (< (svref bytes at) 2) (> (+ at (svref bytes at)) (length bytes)))
        (return))
      (let ((count (svref bytes at)) (kind (svref bytes (1+ at))))
        (cond ((and (= kind 4) (>= count 9))
               (setq current (and (zerop (svref bytes (+ at 3)))
                                  (make-interface :device device :number (svref bytes (+ at 2))
                                                  :class (svref bytes (+ at 5)) :subclass (svref bytes (+ at 6))
                                                  :protocol (svref bytes (+ at 7)))))
               (when current
                 (setq found (cons current found))))
              ((null current))
              ((and (= kind 5) (>= count 7))
               (setf (interface-endpoints current)
                     (append (interface-endpoints current)
                             (list (list (svref bytes (+ at 2)) (svref bytes (+ at 3))
                                         (logand (two bytes (+ at 4)) #x7ff) (svref bytes (+ at 6)))))))
              (t
               (let ((extra (make-array count :initial-element 0)))
                 (dotimes (i count)
                   (setf (svref extra i) (svref bytes (+ at i))))
                 (setf (interface-extras current) (append (interface-extras current) (list (cons kind extra)))))))
        (setq at (+ at count))))
    (reverse found)))

;;; A device at a port
;;;
;;; A port's register (5.4.8) says in bit 0 whether something hangs from
;;; it, in bit 1 whether the port is switched through, and in bits 10 to 13
;;; how fast the device is. Bits 17 to 23 each say that something has
;;; changed, and are taken back by writing them; bit 4 resets the port,
;;; which is what brings a device of USB 2 to the point where it can be
;;; spoken to, and bit 21 says when that is done, which is one more change
;;; for LOOK to take back when the controller speaks of it. Writing bit 1
;;; switches the
;;; port off, so what is written back of a register that was read is the
;;; bits that mean the same both ways: the power, the lights and what wakes
;;; a machine.

(defconstant +kept+ #x0e00c200)
(defconstant +changes+ #x00fe0000)

(defun port-register (controller port)
  (+ (controller-operational controller) #x400 (* 16 (1- port))))

(defun device-at (controller port)
  (find-if (lambda (device) (= (device-port device) port)) (controller-devices controller)))

;; Let go of a device: the controller is told that its slot is free (the
;; command 10), and what was kept for it is given back, unless the
;; controller does not say that it has let go, since it may write there
;; yet.
(defun forget (device)
  (let ((controller (device-controller device)) (released t))
    (when (device-slot device)
      (handler-case (command controller 0 0 (logior (ash 10 10) (ash (device-slot device) 24)) "to let go of a device")
        (error () (setq released nil)))
      (w64 (+ (controller-table controller) (* 8 (device-slot device))) 0))
    (when released
      (dolist (endpoint (device-endpoints device))
        (clara.unsafe:free-memory (ring-memory (endpoint-ring endpoint)) 1)
        (clara.unsafe:free-memory (endpoint-buffer endpoint) 1))
      (when (device-context device)
        (clara.unsafe:free-memory (device-context device) 1))
      (when (device-ring device)
        (clara.unsafe:free-memory (ring-memory (device-ring device)) 1))
      (when (device-page device)
        (clara.unsafe:free-memory (device-page device) 1)))
    (setf (device-endpoints device) nil
          (device-slot device) nil
          (controller-devices controller)
          (remove-if (lambda (other) (eq other device)) (controller-devices controller)))
    nil))

;; Something hangs from a port: it is given a slot (the command 9), a page
;; for the controller to keep what it knows of it, a ring for its
;; requests, and an address (the command 11, which is told of the slot and
;; of endpoint 0). How many bytes a packet of endpoint 0 has is in the
;; eighth byte of what the device says of itself, and the controller is
;; told when it is not what a device of that speed mostly has (the command
;; 13). Then the device says who made it and what it is, what its
;; interfaces are, and is set up the first way that it offers (the request
;; 9). The device, which is among the controller's from then on.
(defun arrive (controller port)
  (let* ((register (port-register controller port)) (device nil) (done nil))
    (unless (bit-p (r32 register) 1)
      (w32 register (logior (logand (r32 register) +kept+) 16))
      (settle controller "did not reset a port" (lambda () (bit-p (r32 register) 21))))
    (unless (bit-p (r32 register) 1)
      (error "the port did not come up when it was reset"))
    (unwind-protect
         (let* ((speed (logand (ash (r32 register) -10) 15))
                (most (case speed (4 512) (3 64) (t 8)))
                (slot nil))
           (setq device (make-device :controller controller :port port :speed speed))
           (setf (device-slot device) (command controller 0 0 (ash 9 10) "for room for a device"))
           (setq slot (ash (device-slot device) 24))
           (setf (device-context device) (clara.unsafe:allocate-memory 1)
                 (device-ring device) (new-ring)
                 (device-page device) (clara.unsafe:allocate-memory 1))
           (w64 (+ (controller-table controller) (* 8 (device-slot device))) (device-context device))
           (let ((input (fill-input device 3 1)))
             (fill-endpoint device 1 4 most 0 (device-ring device))
             (command controller (logand input #xffffffff) (ash input -32) (logior (ash 11 10) slot)
                      "to give a device its address"))
           (setf (controller-devices controller) (append (controller-devices controller) (list device)))
           (let ((packet (svref (control device #x80 6 #x100 0 8) 7)))
             (when (and (/= packet most) (member packet '(8 16 32 64)))
               (let ((input (fill-input device 2 1)))
                 (fill-endpoint device 1 4 packet 0 (device-ring device))
                 (command controller (logand input #xffffffff) (ash input -32) (logior (ash 13 10) slot)
                          "to take the size of a device's packets"))))
           (let ((whole (control device #x80 6 #x100 0 18)))
             (unless (>= (length whole) 18)
               (error "the device says ~D bytes of itself where there are 18" (length whole)))
             (setf (device-vendor device) (two whole 8)
                   (device-product device) (two whole 10)
                   (device-name device) (text device (svref whole 15))))
           (let ((head (control device #x80 6 #x200 0 9)))
             (unless (>= (length head) 9)
               (error "the device says ~D bytes of how it is set up where there are 9" (length head)))
             (let ((bytes (control device #x80 6 #x200 0 (two head 2))))
               (setf (device-interfaces device) (read-interfaces device bytes))
               (control device 0 9 (svref head 5) 0)))
           (setq done t)
           device)
      (unless (or done (null device))
        (forget device)))))

;; How often an endpoint is asked, as the controller counts it: 125
;; millionths of a second, doubled so many times (6.2.3.6). A device of the
;; faster kinds says it that way, less one; a slower one says thousandths
;; of a second.
(defun pace (speed often)
  (if (>= speed 3)
      (max 0 (min 15 (1- often)))
      (let ((doublings 3))
        (loop
          (when (or (= doublings 10) (> (ash 2 doublings) (* 8 (max 1 often))))
            (return doublings))
          (setq doublings (1+ doublings))))))

;; Listen at the endpoint of an interface from which reports come: the
;; first that is asked every so often (its attributes say 3) and gives
;; bytes (bit 7 of its address). The controller is told of it (the command
;; 12), and from then on FUNCTION is called with a vector of the bytes of
;; every report, in the controller's thread. T, or an error when the
;; interface has no such endpoint.
(defun listen-at (interface function)
  (let* ((device (interface-device interface)) (controller (device-controller device))
         (found (find-if (lambda (endpoint) (and (>= (first endpoint) 128) (= (logand (second endpoint) 3) 3)))
                         (interface-endpoints interface))))
    (unless found
      (error "the interface ~D of the USB device at ~A has nothing to listen at" (interface-number interface)
             (device-place device)))
    (let* ((index (1+ (* 2 (logand (first found) 15))))
           (most (max 1 (min (third found) 1024)))
           (endpoint (make-endpoint :device device :index index :most most :function function))
           (highest index) (done nil))
      (when (endpoint-of device index)
        (error "the USB device at ~A is listened to already at its endpoint ~D" (device-place device) (first found)))
      (dolist (other (device-endpoints device))
        (setq highest (max highest (endpoint-index other))))
      (unwind-protect
           (progn
             (setf (endpoint-ring endpoint) (new-ring)
                   (endpoint-buffer endpoint) (clara.unsafe:allocate-memory 1))
             (let ((input (fill-input device (logior 1 (ash 1 index)) highest)))
               (fill-endpoint device index 7 most (pace (device-speed device) (fourth found)) (endpoint-ring endpoint))
               (command controller (logand input #xffffffff) (ash input -32)
                        (logior (ash 12 10) (ash (device-slot device) 24)) "to listen to a device"))
             (setf (device-endpoints device) (cons endpoint (device-endpoints device)))
             (setq done t)
             (ask endpoint)
             t)
        (unless done
          (when (endpoint-ring endpoint)
            (clara.unsafe:free-memory (ring-memory (endpoint-ring endpoint)) 1))
          (when (endpoint-buffer endpoint)
            (clara.unsafe:free-memory (endpoint-buffer endpoint) 1)))))))

;; Whoever takes devices is told of one, and what goes wrong there is said.
(defun announce (function device)
  (when function
    (handler-case (funcall function device)
      (error (condition)
        (fresh-line)
        (format t "usb: the device at ~A is not in use: ~A~%" (device-place device) condition)))))

(defun describe-device (device)
  (format nil "~A:~A ~A" (clara.pci:hex (device-vendor device) 4) (clara.pci:hex (device-product device) 4)
          (or (device-name device) "a device that gives itself no name")))

;; Look at a port: what changed there is taken back, a device that is new
;; arrives, and one that is gone is let go of. A port that says it was
;; plugged anew (bit 17) while a device is known there has another device
;; now. A device that did not start is not tried again until its port says
;; that: the port has more to say while the device is being started, a
;; reset that is done for one, and each time would be another try. When
;; SAID is true, the coming and going is written out, and whoever takes
;; devices is told: START does both itself, later.
(defun look (controller port said)
  (handler-case
      (let* ((register (port-register controller port)) (status (r32 register))
             (device (device-at controller port)))
        (w32 register (logior (logand status +kept+) +changes+))
        (when (or (not (bit-p status 0)) (bit-p status 17))
          (setf (controller-failed controller) (remove port (controller-failed controller))))
        (when (and device (or (not (bit-p status 0)) (bit-p status 17)))
          (when said
            (fresh-line)
            (format t "usb: the device at ~A is gone: ~A~%" (device-place device) (describe-device device)))
          (announce *departure* device)
          (forget device)
          (setq device nil))
        (when (and (bit-p status 0) (null device) (not (member port (controller-failed controller))))
          (setf (controller-failed controller) (cons port (controller-failed controller)))
          (setq device (arrive controller port))
          (setf (controller-failed controller) (remove port (controller-failed controller)))
          (when said
            (fresh-line)
            (format t "usb: a device at ~A: ~A~%" (device-place device) (describe-device device))
            (announce *arrival* device))))
    (error (condition)
      (fresh-line)
      (format t "usb: what is at ~A port ~D did not start: ~A~%" (controller-name controller) port condition))))

;;; A controller
;;;
;;; Its registers (5.3) begin with what it is: how long that part is, in
;;; the first byte; at 4 how many devices it has slots for, in the lowest
;;; byte, and how many ports, in the highest; at 8 how many pages it wants
;;; for itself, in two pieces of five bits; at 16 a bit for contexts of 64
;;; bytes; at 20 and 24 where its doorbells and its interrupters are. After
;;; that part come the registers that it is run by (5.4): a command at 0,
;;; whose bit 0 runs it, bit 1 resets it and bit 2 lets it interrupt; its
;;; status at 4, where bit 0 says that it stands still and bit 11 that it
;;; is not ready; at #x18 where the ring of commands is; at #x30 where the
;;; table of the devices' contexts is; at #x38 how many slots are in use;
;;; and from #x400 on the ports.

;; Open a controller: stopped, reset, given its memory, an interrupt, and
;; started. The ring of events is one page, which a table of one row
;; names (6.5): the table is in the upper half of the page of contexts,
;; which the controller's 255 slots at the most leave free.
(defun open-controller (pci)
  (clara.pci:enable pci)
  (let* ((base (clara.pci:map-registers pci 0 0 #x20))
         (structure (r32 (+ base 4)))
         (slots (logand structure 255))
         (ports (ash structure -24))
         (scratch (let ((more (r32 (+ base 8))))
                    (+ (* 32 (logand (ash more -21) 31)) (logand (ash more -27) 31))))
         (operational (clara.pci:map-registers pci 0 (logand (r32 base) 255) (+ #x400 (* 16 ports))))
         (runtime (+ (clara.pci:map-registers pci 0 (logand (r32 (+ base 24)) #xffffffe0) #x40) #x20))
         (doorbells (clara.pci:map-registers pci 0 (logand (r32 (+ base 20)) #xfffffffc) (* 4 (1+ slots))))
         (controller (make-controller :pci pci :name (clara.pci:location pci)
                                      :operational operational :runtime runtime :doorbells doorbells
                                      :ports ports :wide (bit-p (r32 (+ base 16)) 2)
                                      :quiet (clara:make-event "usb"))))
    (settle controller "was not ready" (lambda () (not (bit-p (r32 (+ operational 4)) 11))))
    (w32 operational (logand (r32 operational) #xfffffffe))
    (settle controller "did not stop" (lambda () (bit-p (r32 (+ operational 4)) 0)))
    (w32 operational 2)
    (settle controller "did not come out of its reset"
            (lambda () (and (not (bit-p (r32 operational) 1)) (not (bit-p (r32 (+ operational 4)) 11)))))
    ;; The interrupt comes before the memory: a controller that has none to give is left with nothing.
    (setf (controller-event controller) (clara.pci:message-interrupt pci 0))
    (setf (controller-table controller) (clara.unsafe:allocate-memory 1)
          (controller-input controller) (clara.unsafe:allocate-memory 1)
          (controller-commands controller) (new-ring)
          (controller-events controller) (clara.unsafe:allocate-memory 1))
    (let ((table (controller-table controller)) (events (controller-events controller)))
      ;; The pages that the controller wants for itself are named in a list that the first row of the table points at.
      (when (plusp scratch)
        (let ((list (clara.unsafe:allocate-memory (floor (+ (* 8 scratch) 4095) 4096)))
              (pages (clara.unsafe:allocate-memory scratch)))
          (dotimes (i scratch)
            (w64 (+ list (* 8 i)) (+ pages (* 4096 i))))
          (w64 table list)))
      (w32 (+ operational #x38) slots)
      (w64 (+ operational #x30) table)
      (w64 (+ operational #x18) (logior (ring-memory (controller-commands controller)) 1))
      (w64 (+ table 2048) events)
      (w32 (+ table 2056) 256)
      (w32 (+ runtime 8) 1)
      (w64 (+ runtime #x18) events)
      (w64 (+ runtime #x10) (+ table 2048))
      (w32 runtime 3)
      (w32 operational 5))
    (settle controller "did not start" (lambda () (not (bit-p (r32 (+ operational 4)) 0))))
    controller))

;;; The thread of a controller
;;;
;;; It waits for the interrupt, takes in what the controller says, and
;;; looks at the ports where something happened. With nothing plugged or
;;; typed it never wakes.

(defun serve (controller)
  (loop
    (take-events controller)
    (loop
      (when (null (controller-changed controller))
        (return))
      (let ((port (car (controller-changed controller))))
        (setf (controller-changed controller) (cdr (controller-changed controller)))
        (when (<= 1 port (controller-ports controller))
          (look controller port t))))
    (clara:wait-event (controller-event controller))))

;; Find the USB controllers among the PCI devices (the class 12, the
;; subclass 3), open the ones of the kind that is driven here (#x30 in the
;; last byte), and find what hangs from their ports. Then whoever takes
;; devices is told of every one that was found, and only then is a thread
;; started for each controller: until it runs, this thread is the one that
;; speaks to the controller. A controller that an earlier start left is
;; another machine's, and its thread is stopped when it is of this one.
(defun start ()
  (dolist (controller *controllers*)
    (when (and (controller-thread controller) (clara:thread-alive-p (controller-thread controller)))
      (clara:destroy-thread (controller-thread controller))))
  (setq *controllers* nil)
  (dolist (pci (clara.pci:devices))
    (when (= (ash (clara.pci:device-kind pci) -8) #x0c03)
      (let ((kind (logand (clara.pci:device-kind pci) 255)))
        (if (/= kind #x30)
            (format t "usb: ~A is a USB controller of an older kind~A, which has no driver here~%"
                    (clara.pci:location pci)
                    (case kind (#x00 " (UHCI)") (#x10 " (OHCI)") (#x20 " (EHCI)") (t "")))
            (handler-case
                (let ((controller (open-controller pci)))
                  (setq *controllers* (append *controllers* (list controller)))
                  (dotimes (i (controller-ports controller))
                    (look controller (1+ i) nil))
                  (format t "usb: ~A is a USB controller: ~D ports, and at them ~D devices~%"
                          (controller-name controller) (controller-ports controller)
                          (length (controller-devices controller)))
                  (dolist (device (controller-devices controller))
                    (format t "usb:   port ~D ~A~%" (device-port device) (describe-device device))))
              (error (condition)
                (format t "usb: ~A did not start: ~A~%" (clara.pci:location pci) condition)))))))
  (dolist (device (devices))
    (announce *arrival* device))
  (dolist (controller *controllers*)
    (let ((controller controller))
      (setf (controller-thread controller)
            (clara:make-thread (lambda () (serve controller))
                               :name (concatenate 'string "usb " (controller-name controller))))))
  *controllers*)
