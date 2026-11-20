;;;; net.lisp: the network
;;;;
;;;; As much of it as it takes to fetch a file from another machine: the
;;;; driver for virtio's network card (Virtual I/O Device specification 1.2,
;;;; 5.1, on top of lisp/virtio.lisp), and above it the protocols of the
;;;; Internet, each as far as a machine needs it that asks and does not
;;;; serve.
;;;;
;;;;   Ethernet    frames on the wire, from one card to another
;;;;   ARP         which card has an address (RFC 826)
;;;;   IPv4        packets from one address to another, whole ones only (RFC 791)
;;;;   UDP         one packet and no promise (RFC 768), for the two below
;;;;   DHCP        asks the network which address this machine has (RFC 2131)
;;;;   DNS         asks which address a name has (RFC 1035)
;;;;   TCP         bytes in order, and all of them or an error (RFC 9293)
;;;;   HTTP        a file, by its name on another machine (RFC 9112)
;;;;
;;;; There is no encryption here: what is fetched comes as the other side
;;;; sends it, and anybody on the way can read it and change it. Whoever
;;;; fetches something that matters has to hold it against something that
;;;; did not come by the same road, as lisp/system.lisp does with a release
;;;; and its signature.
;;;;
;;;; A frame is put together and taken apart in page frames, which is where
;;;; the card reads and writes: numbers go onto the wire with their highest
;;;; byte first, and are read and written here a byte at a time. One thread
;;;; takes what arrives, hands it up through the protocols, and answers
;;;; what has to be answered at once: who has this address, and that a
;;;; piece of a file has come. Whoever asks for something waits for that
;;;; thread to say that something has arrived, looks whether it was what it
;;;; waited for, and asks again every second for as long as it was not.
;;;;
;;;; The machine asks for its address when something first wants the
;;;; network, and not as it starts: a machine that fetches nothing sends
;;;; nothing.

(defpackage "CLARA.NET"
  (:use "COMMON-LISP")
  (:export "START" "UP" "ADDRESS" "STATION" "RESOLVE" "FETCH" "FETCH-TEXT"
           "*PATIENCE*" "*AGAIN*" "*NAME-SERVER*" "*NAME-PORT*"))
(in-package "CLARA.NET")

(defstruct card
  device receive send   ; the virtio device and its two queues: for what arrives, and for what goes out
  name                  ; where it is on the PCI bus
  station               ; its address on the wire, 48 bits
  lock                  ; for putting a frame together and handing it to the card
  spare                 ; the page frames that a frame can be put together in
  thread                ; what takes the frames that arrive
  heard                 ; an event: something has arrived that somebody may be waiting for
  idle                  ; an event that nothing signals, to wait a while on
  address mask router names  ; this machine's address, the mask of its network, the way out of it, and who knows names
  neighbours            ; ((address . station) ...): who has which address on this network
  answering             ; (address . station): who sent the packet that is being looked at, and from which card
  listeners             ; ((port . function) ...): who takes the UDP packets that come for a port
  known                 ; ((name . address) ...): the names that were asked for since the machine started
  connections           ; the TCP connections that are open
  (port 49152)          ; the port that the next one speaks from
  (count 1)             ; a number that no packet of this start has had yet
  (dropped 0))          ; how many frames could not be made sense of

(defvar *card* nil)          ; the network card that START found and opened, or NIL
(defvar *up-lock* (clara:make-lock "network")) ; one thread at a time asks which address this machine has
(defvar *patience* 10000)    ; how many milliseconds the other side may take over an answer
(defvar *again* 1000)        ; and after how many of them a question that has no answer yet is asked again
(defvar *name-server* nil)   ; who is asked for names instead of the one that the network named: an address, as text
(defvar *name-port* 53)      ; and at which port

;;; Numbers in memory, the highest byte first

(defun one (at)
  (clara.unsafe:memory-8 at))

(defun two (at)
  (+ (ash (clara.unsafe:memory-8 at) 8) (clara.unsafe:memory-8 (+ at 1))))

(defun four (at)
  (+ (ash (two at) 16) (two (+ at 2))))

(defun six (at)
  (+ (ash (two at) 32) (four (+ at 2))))

(defun put-one (at value)
  (setf (clara.unsafe:memory-8 at) (logand value 255)))

(defun put-two (at value)
  (setf (clara.unsafe:memory-8 at) (logand (ash value -8) 255)
        (clara.unsafe:memory-8 (+ at 1)) (logand value 255)))

(defun put-four (at value)
  (put-two at (logand (ash value -16) #xffff))
  (put-two (+ at 2) (logand value #xffff)))

(defun put-six (at value)
  (put-two at (logand (ash value -32) #xffff))
  (put-four (+ at 2) (logand value #xffffffff)))

(defun clear (at bytes)
  (dotimes (i bytes)
    (setf (clara.unsafe:memory-8 (+ at i)) 0)))

;; A sum of sixteen-bit numbers as a checksum wants it: what has gathered
;; above sixteen bits is added back in below (RFC 1071).
(defun fold (sum)
  (loop
    (when (< sum #x10000)
      (return sum))
    (setq sum (+ (logand sum #xffff) (ash sum -16)))))

;; What UDP and TCP add to their checksums of the packet around them: both
;; addresses, the protocol, and how long their own part is.
(defun around (from to protocol bytes)
  (+ (ash from -16) (logand from #xffff) (ash to -16) (logand to #xffff) protocol bytes))

(defun checksum (sum)
  (logxor #xffff (fold sum)))

;;; Time, and numbers that were not used before

(defun now ()
  (floor (* 1000 (get-internal-real-time)) internal-time-units-per-second))

;; Thirty-two bits that the last packet did not have: an exchange is told
;; from another by such a number, and nothing more is asked of it.
(defun fresh (card)
  (setf (card-count card) (+ (card-count card) 1))
  (logand (+ (* (logand (now) #xffffff) 40503) (* (card-count card) 7919) (logand (card-station card) #xffffff))
          #xffffffff))

;;; Addresses as text

(defun address-text (address)
  (format nil "~D.~D.~D.~D" (logand (ash address -24) 255) (logand (ash address -16) 255)
          (logand (ash address -8) 255) (logand address 255)))

(defun digit (character)
  (let ((code (char-code character)))
    (and (<= 48 code 57) (- code 48))))

;; The number that a text of digits is, or NIL.
(defun number-of (text)
  (let ((number 0))
    (and (< 0 (length text) 10)
         (dotimes (i (length text) number)
           (let ((digit (digit (char text i))))
             (unless digit
               (return nil))
             (setq number (+ (* 10 number) digit)))))))

;; A text cut at every CHARACTER.
(defun pieces (text character)
  (let ((found nil) (start 0))
    (dotimes (i (length text))
      (when (char= (char text i) character)
        (setq found (cons (subseq text start i) found)
              start (1+ i))))
    (reverse (cons (subseq text start) found))))

;; The address that "10.0.2.2" is, or NIL for a text that is none.
(defun text-address (text)
  (let ((parts (pieces text #\.)) (address 0))
    (and (= (length parts) 4)
         (dolist (part parts address)
           (let ((number (number-of part)))
             (unless (and number (< number 256))
               (return nil))
             (setq address (+ (* 256 address) number)))))))

(defun station-text (station)
  (let ((digits "0123456789abcdef") (text ""))
    (dotimes (i 6)
      (let ((byte (logand (ash station (* -8 (- 5 i))) 255)))
        (setq text (concatenate 'string text (if (= i 0) "" ":")
                                (subseq digits (ash byte -4) (1+ (ash byte -4)))
                                (subseq digits (logand byte 15) (1+ (logand byte 15)))))))
    text))

;;; The card

;; A frame goes out. It is put together in a page frame of the card's own:
;; twelve bytes that virtio has before every frame, all zero here, which
;; says that nothing is left for the card to work out (5.1.6), and which
;; nothing ever writes to in a page that came as zeroes; who the
;; frame is for, who it is from, and what kind it is; and then what it
;; carries, which FILL writes at the address that it is called with,
;; giving how many bytes that was. A frame is sixty bytes at least. The
;; card has the page until it says that the frame is sent, which is looked
;; for here before the next one.
(defun send-frame (card to kind fill)
  (clara:with-lock-held ((card-lock card))
    (unless (eq card *card*)
      (error "the network card ~A is from an earlier start" (card-name card)))
    (let ((queue (card-send card)) (waited 0))
      (loop
        (loop
          (let ((page (clara.virtio:queue-take queue)))
            (unless page
              (return))
            (setf (card-spare card) (cons page (card-spare card)))))
        (when (card-spare card)
          (return))
        (when (>= waited 2000)
          (error "the network card ~A does not send what it is given" (card-name card)))
        (clara:wait-event (card-idle card) 10)
        (setq waited (+ waited 10)))
      (let* ((page (car (card-spare card))) (frame (+ page 12))
             (bytes (+ 14 (funcall fill (+ frame 14)))))
        (when (> bytes 1514)
          (error "a frame of ~D bytes is longer than the wire takes" bytes))
        (put-six frame to)
        (put-six (+ frame 6) (card-station card))
        (put-two (+ frame 12) kind)
        (when (< bytes 60)
          (clear (+ frame bytes) (- 60 bytes))
          (setq bytes 60))
        (setf (card-spare card) (cdr (card-spare card)))
        (clara.virtio:queue-add queue (list (list page (+ 12 bytes) nil)) page)
        (clara.virtio:queue-notify queue)
        bytes))))

;;; ARP: who has an address

(defun learn (card address station)
  (let ((known (assoc address (card-neighbours card))))
    (if known
        (rplacd known station)
        (setf (card-neighbours card) (cons (cons address station) (card-neighbours card))))))

;; A question, to everybody: who has ADDRESS? Or an answer, to the one who
;; asked: this card has the address that this machine has.
(defun arp-out (card answer to-station to-address)
  (send-frame card (if answer to-station #xffffffffffff) #x0806
              (lambda (at)
                (put-two at 1)                  ; over Ethernet,
                (put-two (+ at 2) #x0800)       ; about addresses of IPv4,
                (put-one (+ at 4) 6)            ; which are six bytes and four
                (put-one (+ at 5) 4)
                (put-two (+ at 6) (if answer 2 1))
                (put-six (+ at 8) (card-station card))
                (put-four (+ at 14) (or (card-address card) 0))
                (put-six (+ at 18) (if answer to-station 0))
                (put-four (+ at 24) to-address)
                28)))

(defun arp-in (card at bytes)
  (when (and (>= bytes 28) (= (two at) 1) (= (two (+ at 2)) #x0800) (= (one (+ at 4)) 6) (= (one (+ at 5)) 4))
    (let ((from (four (+ at 14))) (station (six (+ at 8))))
      (unless (= from 0)
        (learn card from station))
      (when (and (= (two (+ at 6)) 1) (card-address card) (= (four (+ at 24)) (card-address card)))
        (arp-out card t station from)))))

;; Something is asked for until it is there: ASK is called, and again every
;; second (*AGAIN*) for as long as TEST gives nothing. What TEST gave; or an error,
;; which SAY makes the text of, when *PATIENCE* is over.
(defun ask-until (card test ask say)
  (let ((begun (now)) (asked nil))
    (loop
      (let ((got (funcall test)))
        (when got
          (return got)))
      (let ((time (now)))
        (when (> (- time begun) *patience*)
          (error "~A" (funcall say)))
        (when (or (null asked) (>= (- time asked) *again*))
          (funcall ask)
          (setq asked time)))
      (clara:wait-event (card-heard card) 50))))

;; The card that a packet for ADDRESS is handed to: the one that has the
;; address, when that is on this network, and otherwise the one that is the
;; way out of it. Everybody, for the address that means everybody. And for
;; an answer to the packet that is being looked at, the card that it came
;; from: the thread that takes what arrives asks nobody, since the answer
;; would be its own to take.
(defun station-of (card address)
  (cond ((= address #xffffffff)
         #xffffffffffff)
        ((and (card-answering card) (= (car (card-answering card)) address))
         (cdr (card-answering card)))
        (t
      (let ((next (cond ((or (null (card-mask card))
                             (= (logand address (card-mask card)) (logand (card-address card) (card-mask card))))
                         address)
                        ((card-router card))
                        (t (error "~A is not on this machine's network, and the network named no way out of it"
                                  (address-text address))))))
        (ask-until card
                   (lambda () (cdr (assoc next (card-neighbours card))))
                   (lambda () (arp-out card nil 0 next))
                   (lambda () (format nil "nobody on the network says that it has the address ~A" (address-text next))))))))

;;; IPv4

;; A packet goes to an address: twenty bytes that say how long it is, which
;; protocol it carries, who it is from and who it is for, with a checksum
;; of those twenty; and then what it carries, which FILL writes, giving how
;; many bytes. It is not to be taken apart on the way: nothing here puts
;; pieces together.
(defun send-packet (card to protocol fill &optional (from (or (card-address card) 0)))
  (let ((station (station-of card to)))
    (send-frame card station #x0800
                (lambda (at)
                  (let ((bytes (+ 20 (funcall fill (+ at 20)))))
                    (setf (card-count card) (+ (card-count card) 1))
                    (put-one at #x45)
                    (put-one (+ at 1) 0)
                    (put-two (+ at 2) bytes)
                    (put-two (+ at 4) (logand (card-count card) #xffff))
                    (put-two (+ at 6) #x4000)
                    (put-one (+ at 8) 64)
                    (put-one (+ at 9) protocol)
                    (put-two (+ at 10) 0)
                    (put-four (+ at 12) from)
                    (put-four (+ at 16) to)
                    (put-two (+ at 10) (checksum (clara.unsafe:internet-sum at 20)))
                    bytes)))))

(defun packet-in (card at bytes station)
  (when (and (>= bytes 20) (= (ash (one at) -4) 4))
    (let ((header (* 4 (logand (one at) 15))) (whole (two (+ at 2)))
          (from (four (+ at 12))) (to (four (+ at 16))))
      (when (and (>= header 20) (<= header whole) (<= whole bytes)
                 (= 0 (logand (two (+ at 6)) #x3fff))     ; whole, and not a piece of a packet
                 (= (fold (clara.unsafe:internet-sum at header)) #xffff)
                 (or (null (card-address card)) (= to (card-address card)) (= to #xffffffff)))
        (setf (card-answering card) (cons from station))
        (unwind-protect
             (case (one (+ at 9))
               (17 (datagram-in card from to (+ at header) (- whole header)))
               (6 (segment-in card from to (+ at header) (- whole header))))
          (setf (card-answering card) nil))))))

;;; UDP

(defun send-datagram (card to to-port from-port fill &optional (from (or (card-address card) 0)))
  (send-packet card to 17
               (lambda (at)
                 (let ((bytes (+ 8 (funcall fill (+ at 8)))))
                   (put-two at from-port)
                   (put-two (+ at 2) to-port)
                   (put-two (+ at 4) bytes)
                   (put-two (+ at 6) 0)
                   (let ((sum (checksum (+ (around from to 17 bytes) (clara.unsafe:internet-sum at bytes)))))
                     (put-two (+ at 6) (if (= sum 0) #xffff sum)))
                   bytes))
               from))

;; A packet of UDP's goes to whoever listens at its port: a function of who
;; it is from, from which port, where what it carries is, and how long.
(defun datagram-in (card from to at bytes)
  (when (>= bytes 8)
    (let ((whole (two (+ at 4))))
      (when (and (<= 8 whole bytes)
                 (or (= (two (+ at 6)) 0)
                     (= (fold (+ (around from to 17 whole) (clara.unsafe:internet-sum at whole))) #xffff)))
        (let ((listener (cdr (assoc (two (+ at 2)) (card-listeners card)))))
          (when listener
            (funcall listener from (two at) (+ at 8) (- whole 8))))))))

(defun listen-at (card port function)
  (setf (card-listeners card) (cons (cons port function) (card-listeners card))))

(defun listen-no-more (card port)
  (setf (card-listeners card) (remove-if (lambda (listener) (= (car listener) port)) (card-listeners card))))

(defun next-port (card)
  (setf (card-port card) (if (>= (card-port card) 65535) 49152 (1+ (card-port card)))))

;;; DHCP: which address this machine has

;; What a DHCP server says, as (kind address server mask router names), or
;; NIL when the packet is no answer to the question NUMBER. An answer
;; (RFC 2131, 2) is 236 bytes of fixed places, of which this reads that it
;; is an answer, the question's number, and the address that is offered;
;; four bytes that say that options follow; and the options, each a
;; number, a length and that many bytes (RFC 2132): 53 what kind of
;; message, 1 the mask, 3 the ways out, 6 who knows names, 54 the server.
(defun dhcp-answer (at bytes number)
  (when (and (>= bytes 240) (= (one at) 2) (= (four (+ at 4)) number) (= (four (+ at 236)) #x63825363))
    (let ((kind nil) (server nil) (mask nil) (router nil) (names nil) (option (+ at 240)) (end (+ at bytes)))
      (loop
        (when (>= option end)
          (return))
        (let ((code (one option)))
          (cond ((= code 255)
                 (return))
                ((= code 0)
                 (setq option (1+ option)))
                (t
                 (when (>= (+ option 1) end)
                   (return))
                 (let ((length (one (+ option 1))) (value (+ option 2)))
                   (when (> (+ value length) end)
                     (return))
                   (cond ((and (= code 53) (>= length 1)) (setq kind (one value)))
                         ((and (= code 54) (>= length 4)) (setq server (four value)))
                         ((and (= code 1) (>= length 4)) (setq mask (four value)))
                         ((and (= code 3) (>= length 4)) (setq router (four value)))
                         ((and (= code 6) (>= length 4)) (setq names (four value))))
                   (setq option (+ value length)))))))
      (and kind (list kind (four (+ at 16)) server mask router names)))))

;; A question to whatever DHCP server there is, from a machine that has no
;; address yet, to everybody: KIND is 1 to ask who has an address for this
;; machine, and 3 to take the one that SERVER offered.
(defun dhcp-out (card number kind address server)
  (send-datagram card #xffffffff 67 68
                 (lambda (at)
                   (clear at 300)
                   (put-one at 1)
                   (put-one (+ at 1) 1)
                   (put-one (+ at 2) 6)
                   (put-four (+ at 4) number)
                   (put-two (+ at 10) #x8000)         ; the answer is to go to everybody: this machine has no address
                   (put-six (+ at 28) (card-station card))
                   (put-four (+ at 236) #x63825363)
                   (put-one (+ at 240) 53)
                   (put-one (+ at 241) 1)
                   (put-one (+ at 242) kind)
                   (let ((option (+ at 243)))
                     (when address
                       (put-one option 50)
                       (put-one (+ option 1) 4)
                       (put-four (+ option 2) address)
                       (setq option (+ option 6)))
                     (when server
                       (put-one option 54)
                       (put-one (+ option 1) 4)
                       (put-four (+ option 2) server)
                       (setq option (+ option 6)))
                     (put-one option 55)              ; what is wanted beside an address: the mask, the way out, who knows names
                     (put-one (+ option 1) 3)
                     (put-one (+ option 2) 1)
                     (put-one (+ option 3) 3)
                     (put-one (+ option 4) 6)
                     (put-one (+ option 5) 255))
                   300)
                 0))

;; The machine asks the network which address it has, and takes the one
;; that the first server offers, with what that server says of the network.
(defun configure (card)
  (let ((number (fresh card)) (offer nil) (given nil))
    (listen-at card 68
               (lambda (from port at bytes)
                 (let ((answer (and from port (dhcp-answer at bytes number))))
                   (cond ((null answer))
                         ((and (= (car answer) 2) (null offer)) (setq offer answer))
                         ((and (= (car answer) 5) offer) (setq given answer))
                         ((= (car answer) 6) (setq offer nil))))))
    (unwind-protect
         (progn
           (ask-until card (lambda () offer) (lambda () (dhcp-out card number 1 nil nil))
                      (lambda () "no DHCP server says which address this machine has on its network"))
           (ask-until card (lambda () given)
                      (lambda () (when offer (dhcp-out card number 3 (second offer) (third offer))))
                      (lambda () "the DHCP server that offered this machine an address did not give it")))
      (listen-no-more card 68))
    (setf (card-address card) (second given)
          (card-mask card) (or (fourth given) #xffffff00)
          (card-router card) (nth 4 given)
          (card-names card) (nth 5 given))
    (format t "net: this machine is ~A on its network~A~A~%" (address-text (card-address card))
            (if (card-router card) (format nil ", ~A is the way out" (address-text (card-router card))) "")
            (if (card-names card) (format nil ", ~A knows names" (address-text (card-names card))) ""))
    card))

;; The card, with an address: what everything above asks for first. The
;; machine has its address from the first time that something asks.
(defun up ()
  (let ((card *card*))
    (unless card
      (error "this machine has no network card that has a driver here"))
    (clara:with-lock-held (*up-lock*)
      (unless (card-address card)
        (configure card)))
    card))

;; This machine's address, as text; NIL without a network card. And the
;; address of its card on the wire.
(defun address ()
  (and *card* (address-text (card-address (up)))))

(defun station ()
  (and *card* (station-text (card-station *card*))))

;;; DNS: which address a name has

;; The name, as a question wants it: each part with its length before it,
;; and a zero at the end. How many bytes that was.
(defun put-name (at name)
  (let ((start at))
    (dolist (part (pieces name #\.))
      (when (or (= (length part) 0) (> (length part) 63))
        (error "~A is no name that can be asked for" name))
      (put-one at (length part))
      (dotimes (i (length part))
        (let ((code (char-code (char part i))))
          (when (> code 127)
            (error "~A is no name that can be asked for: it has a character that is not ASCII" name))
          (put-one (+ at 1 i) code)))
      (setq at (+ at 1 (length part))))
    (put-one at 0)
    (- (1+ at) start)))

;; Where the name that begins at AT ends: a name is parts, each with its
;; length before it, up to a zero, or up to two bytes that point at the
;; rest of it elsewhere (RFC 1035, 4.1.4). NIL when it goes past END.
(defun past-name (at end)
  (loop
    (when (>= at end)
      (return nil))
    (let ((length (one at)))
      (cond ((= length 0) (return (1+ at)))
            ((>= length 192) (return (+ at 2)))
            (t (setq at (+ at 1 length)))))))

;; What an answer says: an address, :NONE when there is no such name,
;; :FAILED when the server could not say, or NIL for a packet that is no
;; answer to the question NUMBER. An answer has twelve bytes of counts
;; before the question again and the records, each a name, a type, a
;; class, how long it holds, a length and that many bytes: the type 1 with
;; four bytes is an address.
(defun name-answer (at bytes number)
  (when (and (>= bytes 12) (= (two at) number) (/= 0 (logand (two (+ at 2)) #x8000)))
    (let ((failure (logand (two (+ at 2)) 15)) (end (+ at bytes)) (place (+ at 12)) (found nil))
      (cond ((= failure 3) :none)
            ((/= failure 0) :failed)
            (t
             (dotimes (i (two (+ at 4)))
               (setq place (and place (past-name place end)))
               (setq place (and place (+ place 4))))
             (dotimes (i (two (+ at 6)))
               (setq place (and place (past-name place end)))
               (when (and place (<= (+ place 10) end))
                 (let ((kind (two place)) (length (two (+ place 8))))
                   (when (and (null found) (= kind 1) (= length 4) (<= (+ place 14) end))
                     (setq found (four (+ place 10))))
                   (setq place (+ place 10 length)))))
             (or found :none))))))

;; The address of a name, as a number: of an address that is written out,
;; that address, and of anything else what the network's name server says,
;; which is asked once for a name as long as the machine runs.
(defun address-of (name)
  (or (text-address name)
      (cdr (assoc name (card-known (up)) :test #'string-equal))
      (let* ((card (up))
             (server (if *name-server*
                         (or (text-address *name-server*)
                             (error "~S, in CLARA.NET:*NAME-SERVER*, is no address" *name-server*))
                         (or (card-names card)
                             (error "the network named nobody who knows names, and CLARA.NET:*NAME-SERVER* names nobody"))))
             (number (logand (fresh card) #xffff)) (port (next-port card)) (answer nil))
        (listen-at card port
                   (lambda (from from-port at bytes)
                     (when (and (= from server) from-port (null answer))
                       (setq answer (name-answer at bytes number)))))
        (unwind-protect
             (ask-until card (lambda () answer)
                        (lambda ()
                          (send-datagram card server *name-port* port
                                         (lambda (at)
                                           (put-two at number)
                                           (put-two (+ at 2) #x0100)      ; a question, and the server is to ask further
                                           (put-two (+ at 4) 1)
                                           (put-two (+ at 6) 0)
                                           (put-two (+ at 8) 0)
                                           (put-two (+ at 10) 0)
                                           (let ((bytes (put-name (+ at 12) name)))
                                             (put-two (+ at 12 bytes) 1)  ; its address,
                                             (put-two (+ at 14 bytes) 1)  ; on the Internet
                                             (+ 16 bytes)))))
                        (lambda () (format nil "~A, who knows names, does not say which address ~A has"
                                           (address-text server) name)))
          (listen-no-more card port))
        (cond ((eq answer :none) (error "there is no machine of the name ~A" name))
              ((eq answer :failed) (error "~A, who knows names, could not say which address ~A has"
                                          (address-text server) name))
              (t
               (setf (card-known card) (cons (cons name answer) (card-known card)))
               answer)))))

;; The same, as text.
(defun resolve (name)
  (address-text (address-of name)))

;;; TCP: bytes in order

(defstruct connection
  card to to-port port
  state        ; :asked, while the other side has not answered; :open; :refused; :broken; :overrun, when more came than may
  first        ; the number that our bytes are counted from
  next         ; the number of the next byte of ours
  heard        ; how far the other side has said that it has them
  expected     ; the number of the next byte of theirs
  memory room  ; what has arrived: page frames, and how many bytes they hold
  (held 0)     ; how many of those are filled, from the first byte on without a gap
  later        ; ((from . to) ...): what has arrived beyond a gap, as places in that memory
  limit        ; how many bytes may arrive
  ended)       ; the other side has sent all that it will

(defun wrap (number)
  (logand number #xffffffff))

;; Is the number A after B, as the bytes of a connection are counted, round
;; and round in thirty-two bits?
(defun after (a b)
  (let ((ahead (wrap (- a b))))
    (and (/= ahead 0) (< ahead #x80000000))))

;; A segment goes out: twenty bytes that say from which port to which, the
;; number of its first byte, how far the other side's bytes have arrived,
;; what it is about (1 the end, 2 the beginning, 4 giving up, 8 hand it on,
;; 16 the number of what has arrived counts), how many more bytes may come,
;; and a checksum of all of it with the addresses; four bytes more at the
;; beginning of a connection, which say how long a segment may be; and
;; BYTES bytes of what the connection carries, from DATA.
(defun segment-out (card to to-port from-port number arrived flags window &optional data (bytes 0))
  (let ((from (or (card-address card) 0)))
    (send-packet card to 6
                 (lambda (at)
                   (let* ((header (if (/= 0 (logand flags 2)) 24 20)) (whole (+ header bytes)))
                     (put-two at from-port)
                     (put-two (+ at 2) to-port)
                     (put-four (+ at 4) number)
                     (put-four (+ at 8) arrived)
                     (put-one (+ at 12) (ash (floor header 4) 4))
                     (put-one (+ at 13) flags)
                     (put-two (+ at 14) window)
                     (put-two (+ at 16) 0)
                     (put-two (+ at 18) 0)
                     (when (= header 24)
                       (put-one (+ at 20) 2)
                       (put-one (+ at 21) 4)
                       (put-two (+ at 22) 1460))
                     (when (> bytes 0)
                       (clara.unsafe:copy-memory (+ at header) data bytes))
                     (put-two (+ at 16) (checksum (+ (around from to 6 whole) (clara.unsafe:internet-sum at whole))))
                     whole)))))

(defun window (connection)
  (min 65535 (- (connection-limit connection) (connection-held connection))))

;; The other side is told how far its bytes have arrived.
(defun acknowledge (connection)
  (segment-out (connection-card connection) (connection-to connection) (connection-to-port connection)
               (connection-port connection) (connection-next connection) (connection-expected connection)
               16 (window connection)))

;; The memory of a connection has room for NEEDED bytes in all: twice as
;; much as before, or more, in new page frames, with everything that had
;; arrived, also beyond a gap.
(defun make-room (connection needed)
  (when (> needed (connection-room connection))
    (let* ((room (* 4096 (floor (+ (max needed (* 2 (connection-room connection))) 4095) 4096)))
           (memory (clara.unsafe:allocate-memory (floor room 4096)))
           (filled (connection-held connection)))
      (dolist (piece (connection-later connection))
        (setq filled (max filled (cdr piece))))
      (clara.unsafe:copy-memory memory (connection-memory connection) filled)
      (clara.unsafe:free-memory (connection-memory connection) (floor (connection-room connection) 4096))
      (setf (connection-memory connection) memory
            (connection-room connection) room))))

;; BYTES bytes have arrived whose first is AHEAD bytes beyond the next one
;; that is expected. They go where they belong in the memory. What comes
;; next, with nothing before it missing, makes that much more of the file
;; whole, and so does every piece that had come early and now joins on;
;; what comes early is kept for then, as long as there are few such pieces
;; and it is within what may arrive. T when it was the piece that was
;; expected.
(defun take-piece (connection ahead data bytes)
  (let* ((from (+ (connection-held connection) ahead))
         (fits (min bytes (- (connection-limit connection) from))))
    (cond ((and (= ahead 0) (< fits bytes))
           (setf (connection-state connection) :overrun)
           nil)
          ((or (<= fits 0) (< fits bytes) (and (> ahead 0) (>= (length (connection-later connection)) 64)))
           nil)
          (t
           (make-room connection (+ from bytes))
           (clara.unsafe:copy-memory (+ (connection-memory connection) from) data bytes)
           (if (> ahead 0)
               (setf (connection-later connection) (cons (cons from (+ from bytes)) (connection-later connection)))
               (let ((held (+ from bytes)))
                 (loop
                   (let ((piece (find-if (lambda (piece) (<= (car piece) held)) (connection-later connection))))
                     (unless piece
                       (return))
                     (setq held (max held (cdr piece)))
                     (setf (connection-later connection) (remove piece (connection-later connection)))))
                 (setf (connection-expected connection)
                       (wrap (+ (connection-expected connection) (- held (connection-held connection))))
                       (connection-held connection) held)))
           (= ahead 0)))))

;; A segment has arrived for a connection.
(defun heard-segment (connection number arrived flags data bytes)
  (cond ((/= 0 (logand flags 4))
         (setf (connection-state connection) (if (eq (connection-state connection) :asked) :refused :broken)))
        ((eq (connection-state connection) :asked)
         ;; the answer to the beginning: the other side begins too, and has ours
         (when (and (= (logand flags 18) 18) (= arrived (connection-next connection)))
           (setf (connection-expected connection) (wrap (1+ number))
                 (connection-heard connection) arrived
                 (connection-state connection) :open)
           (acknowledge connection)))
        ((eq (connection-state connection) :open)
         (when (and (/= 0 (logand flags 16))
                    (after arrived (connection-heard connection))
                    (not (after arrived (connection-next connection))))
           (setf (connection-heard connection) arrived))
         (let ((answer nil))
           (when (> bytes 0)
             ;; What comes next is taken, and what comes later is kept for when the gap before it
             ;; is filled. What came before is only said again to have arrived, and that is said
             ;; of everything: it is how the other side learns what it has to send again.
             (let ((ahead (wrap (- number (connection-expected connection)))))
               (when (< ahead #x40000000)
                 (take-piece connection ahead data bytes)))
             (setq answer t))
           (when (/= 0 (logand flags 1))
             (when (and (not (connection-ended connection))
                        (= (wrap (+ number bytes)) (connection-expected connection)))
               (setf (connection-expected connection) (wrap (1+ (connection-expected connection)))
                     (connection-ended connection) t))
             (setq answer t))
           (when answer
             (acknowledge connection))))))

;; A segment has arrived. It is for the connection that has its two ports
;; and its address. One that is for none is answered by giving it up, so
;; that the other side does not go on waiting, unless it is one that gives
;; up itself (RFC 9293, 3.10.7.1).
(defun segment-in (card from to at bytes)
  (when (>= bytes 20)
    (let ((header (* 4 (ash (one (+ at 12)) -4))) (flags (one (+ at 13))))
      (when (and (<= 20 header bytes)
                 (= (fold (+ (around from to 6 bytes) (clara.unsafe:internet-sum at bytes))) #xffff))
        (let* ((from-port (two at)) (to-port (two (+ at 2))) (number (four (+ at 4))) (arrived (four (+ at 8)))
               (carried (- bytes header))
               (connection (find-if (lambda (connection)
                                      (and (= (connection-to connection) from) (= (connection-to-port connection) from-port)
                                           (= (connection-port connection) to-port)))
                                    (card-connections card))))
          (cond (connection
                 (heard-segment connection number arrived flags (+ at header) carried))
                ((/= 0 (logand flags 4)))
                ((/= 0 (logand flags 16))
                 (segment-out card from from-port to-port arrived 0 4 0))
                (t
                 (segment-out card from from-port to-port 0
                              (wrap (+ number carried (if (/= 0 (logand flags 3)) 1 0))) 20 0))))))))

;; A connection to a port of another machine, which may send LIMIT bytes
;; over it. The beginning is said, and said again every second, until the
;; other side has answered it.
(defun connect (card to to-port limit)
  (let* ((first (fresh card))
         (connection (make-connection :card card :to to :to-port to-port :port (next-port card)
                                      :state :asked :first first :next (wrap (1+ first)) :heard first
                                      :memory (clara.unsafe:allocate-memory 16) :room 65536 :limit limit))
         (open nil))
    (setf (card-connections card) (cons connection (card-connections card)))
    (unwind-protect
         (progn
           (ask-until card (lambda () (not (eq (connection-state connection) :asked)))
                      (lambda () (segment-out card to to-port (connection-port connection) first 0 2 65535))
                      (lambda () (format nil "~A does not answer at its port ~D" (address-text to) to-port)))
           (unless (eq (connection-state connection) :open)
             (error "~A takes no connection at its port ~D" (address-text to) to-port))
           (setq open t)
           connection)
      (unless open
        (disconnect connection)))))

;; What a connection has to say, in one segment, said again every second
;; until the other side has it.
(defun say (connection text)
  (let* ((card (connection-card connection)) (bytes (clara.unsafe:string-bytes text))
         (page (clara.unsafe:allocate-memory 1)) (number (connection-next connection)))
    (when (> bytes 1400)
      (error "~D bytes are more than is said in one piece" bytes))
    (unwind-protect
         (progn
           (clara.unsafe:string-memory text page)
           (setf (connection-next connection) (wrap (+ number bytes)))
           (ask-until card
                      (lambda () (or (not (eq (connection-state connection) :open))
                                     (= (connection-heard connection) (connection-next connection))))
                      (lambda () (segment-out card (connection-to connection) (connection-to-port connection)
                                              (connection-port connection) number (connection-expected connection)
                                              24 (window connection) page bytes))
                      (lambda () (format nil "~A does not say that it has what it was sent"
                                         (address-text (connection-to connection))))))
      (clara.unsafe:free-memory page 1))
    bytes))

;; Wait until TEST is true of what has arrived, or the other side has sent
;; all that it will: T in the first case. An error when the connection is
;; no more, and when nothing has arrived for as long as *PATIENCE* is.
(defun wait-for (connection test)
  (let ((card (connection-card connection)) (held (connection-held connection)) (since (now)))
    (loop
      (when (funcall test)
        (return t))
      (case (connection-state connection)
        (:open)
        (:overrun (error "~A sends more than the ~D bytes that were to be taken from it"
                         (address-text (connection-to connection)) (- (connection-limit connection) 65536)))
        (t (error "~A has given the connection up" (address-text (connection-to connection)))))
      (when (connection-ended connection)
        (return nil))
      (cond ((/= held (connection-held connection))
             (setq held (connection-held connection)
                   since (now)))
            ((> (- (now) since) *patience*)
             (error "~A has sent nothing for ~D seconds" (address-text (connection-to connection)) (floor *patience* 1000))))
      (clara:wait-event (card-heard card) 50))))

;; A connection is over. The other side is told that nothing more comes,
;; when it is still there to be told; whatever it says after that finds no
;; connection, and is answered so. The memory of what arrived goes back,
;; unless KEEP says that somebody has it.
(defun disconnect (connection &optional keep)
  (let ((card (connection-card connection)))
    (when (eq (connection-state connection) :open)
      (ignore-errors
        (segment-out card (connection-to connection) (connection-to-port connection) (connection-port connection)
                     (connection-next connection) (connection-expected connection) 17 0)))
    (setf (connection-state connection) :closed
          (card-connections card) (remove connection (card-connections card)))
    (unless keep
      (clara.unsafe:free-memory (connection-memory connection) (floor (connection-room connection) 4096)))
    nil))

;;; HTTP: a file from another machine

;; "http://host:port/path", taken apart: the host, the port, which is 80
;; when none is written, and the path, which is / when there is none.
(defun parse-address (text)
  (unless (and (> (length text) 7) (string-equal (subseq text 0 7) "http://"))
    (error (if (and (> (length text) 8) (string-equal (subseq text 0 8) "https://"))
               "~A is to be had by HTTPS, which this system does not speak: it fetches by plain HTTP"
               "~A is no address that begins with http://")
           text))
  (let ((slash (length text)) (colon nil))
    (dotimes (i (- (length text) 7))
      (let ((character (char text (+ 7 i))))
        (cond ((and (char= character #\/) (= slash (length text)))
               (setq slash (+ 7 i)))
              ((and (char= character #\:) (= slash (length text)) (null colon))
               (setq colon (+ 7 i))))))
    (let ((host (subseq text 7 (or colon slash)))
          (port (if colon (number-of (subseq text (1+ colon) slash)) 80))
          (path (if (= slash (length text)) "/" (subseq text slash))))
      (unless (and (> (length host) 0) port (< 0 port 65536))
        (error "~A names no machine, or no port of one" text))
      (values host port path))))

(defvar *line-end* (format nil "~A~A" (code-char 13) (code-char 10)))

;; Where the head of an answer ends, when all of it has arrived: after the
;; first empty line. NIL until then.
(defun head-end (connection from)
  (let ((memory (connection-memory connection)) (held (connection-held connection)))
    (loop
      (when (> (+ from 4) held)
        (return nil))
      (when (and (= (one (+ memory from)) 13) (= (one (+ memory from 1)) 10)
                 (= (one (+ memory from 2)) 13) (= (one (+ memory from 3)) 10))
        (return (+ from 4)))
      (setq from (1+ from)))))

;; The lines of a text that ends its lines the way HTTP does.
(defun head-lines (text)
  (let ((lines nil) (start 0))
    (dotimes (i (length text))
      (when (and (= (char-code (char text i)) 10) (> i start))
        (setq lines (cons (subseq text start (if (= (char-code (char text (1- i))) 13) (1- i) i)) lines)
              start (1+ i))))
    (reverse lines)))

;; What a line of a head says of NAME, as "Content-Length: 12" says 12 of
;; Content-Length; NIL for another line.
(defun field (line name)
  (let ((length (length name)))
    (and (> (length line) length)
         (string-equal (subseq line 0 length) name)
         (char= (char line length) #\:)
         (let ((start (1+ length)))
           (loop
             (unless (and (< start (length line)) (char= (char line start) #\Space))
               (return))
             (setq start (1+ start)))
           (subseq line start)))))

;; What a digit in base sixteen stands for, by its code, or NIL.
(defun sixteenth (code)
  (cond ((<= 48 code 57) (- code 48))
        ((<= 97 code 102) (- code 87))
        ((<= 65 code 70) (- code 55))))

;; A file that was sent in chunks, put together where it lies (RFC 9112,
;; 7.1): a chunk is its length, in base sixteen, on a line of its own,
;; that many bytes, and the end of a line, and a chunk of no bytes is the
;; last. How many bytes the file is; NIL when what lies there is not
;; chunks up to a last one.
(defun join-chunks (memory bytes)
  (let ((from 0) (to 0))
    (loop
      (let ((size 0) (digits 0))
        (loop
          (when (>= from bytes)
            (return-from join-chunks nil))
          (let ((digit (sixteenth (one (+ memory from)))))
            (unless digit
              (return))
            (setq size (+ (* 16 size) digit)
                  digits (1+ digits)
                  from (1+ from))
            (when (> digits 8)
              (return-from join-chunks nil))))
        (when (= digits 0)
          (return-from join-chunks nil))
        ;; whatever else the line says is passed over
        (loop
          (when (>= from bytes)
            (return-from join-chunks nil))
          (setq from (1+ from))
          (when (= (one (+ memory from -1)) 10)
            (return)))
        (when (= size 0)
          (return to))
        (when (> (+ from size 2) bytes)
          (return-from join-chunks nil))
        (clara.unsafe:copy-memory (+ memory to) (+ memory from) size)
        (setq to (+ to size)
              from (+ from size 2))))))

;; The file that an address names, fetched by HTTP: the memory that it is
;; in, which is page frames, how many bytes it is, and how many page frames
;; that memory is, which are the caller's to give back
;; (CLARA.UNSAFE:FREE-MEMORY). A file of more than LIMIT bytes is not
;; taken. Where the other side says that the file is to be had at another
;; address, that one is asked, three times at most.
(defun fetch (address &key (limit 16777216))
  (let ((moves 0))
    (loop
      (multiple-value-bind (host port path) (parse-address address)
        (let* ((card (up))
               (connection (connect card (address-of host) port (+ limit 65536)))
               (kept nil) (moved nil))
          (unwind-protect
               (progn
                 (say connection
                      (concatenate 'string "GET " path " HTTP/1.1" *line-end*
                                   "Host: " host (if (= port 80) "" (format nil ":~D" port)) *line-end*
                                   "User-Agent: ClaraOS/" (lisp-implementation-version) *line-end*
                                   "Accept: */*" *line-end*
                                   "Connection: close" *line-end* *line-end*))
                 (let ((from 0) (end nil))
                   (wait-for connection
                             (lambda ()
                               (setq end (head-end connection from)
                                     from (max 0 (- (connection-held connection) 3)))
                               (when (and (null end) (> (connection-held connection) 16384))
                                 (error "~A answers with a head that does not end" host))
                               end))
                   (unless end
                     (error "~A ended the connection before it had answered" host))
                   (let* ((lines (head-lines (clara.unsafe:memory-string (connection-memory connection) end)))
                          (words (pieces (or (car lines) "") #\Space))
                          (status (and (cdr words) (number-of (second words))))
                          (length nil) (place nil) (chunked nil))
                     (unless (and status (>= (length (car words)) 5) (string-equal (subseq (car words) 0 5) "HTTP/"))
                       (error "~A does not answer as HTTP does" host))
                     (dolist (line (cdr lines))
                       (let ((value (field line "Content-Length")))
                         (when value
                           (setq length (number-of value))))
                       (let ((value (field line "Transfer-Encoding")))
                         (when (and value (string-equal value "chunked"))
                           (setq chunked t)))
                       (setq place (or (field line "Location") place)))
                     ;; A file in chunks says how long it is as it goes, and is over when the connection is.
                     (when chunked
                       (setq length nil))
                     (cond ((= status 200)
                            (when (and length (> length limit))
                              (error "~A is ~D bytes, and more than ~D are not taken" address length limit))
                            (wait-for connection (lambda () (and length (>= (- (connection-held connection) end) length))))
                            (let ((bytes (- (connection-held connection) end)))
                              (when (and length (< bytes length))
                                (error "~A ended the connection after ~D bytes of the ~D of ~A" host bytes length path))
                              (when (> bytes limit)
                                (error "~A is more than ~D bytes, which are not taken" address limit))
                              (clara.unsafe:copy-memory (connection-memory connection)
                                                        (+ (connection-memory connection) end) (or length bytes))
                              (when chunked
                                (setq length (or (join-chunks (connection-memory connection) bytes)
                                                 (error "~A sends ~A in chunks that do not come to an end" host path))))
                              (setq kept t)
                              (return (values (connection-memory connection) (or length bytes)
                                              (floor (connection-room connection) 4096)))))
                           ((and (member status '(301 302 303 307 308)) place (> (length place) 0))
                            (when (>= moves 3)
                              (error "~A is said to be somewhere else more often than is followed" address))
                            (setq moved (if (and (> (length place) 0) (char= (char place 0) #\/))
                                            (format nil "http://~A~A~A" host (if (= port 80) "" (format nil ":~D" port)) place)
                                            place)))
                           (t
                            (error "~A answers ~D to the request for ~A" host status path))))))
            (disconnect connection kept))
          (setq address moved
                moves (1+ moves)))))))

;; The same, for a file that is a text: the text.
(defun fetch-text (address &key (limit 1048576))
  (multiple-value-bind (memory bytes pages) (fetch address :limit limit)
    (unwind-protect (clara.unsafe:memory-string memory bytes)
      (clara.unsafe:free-memory memory pages))))

;;; What arrives

;; A frame has arrived: by its kind it is ARP's or IPv4's, and anything
;; else is nobody's here.
(defun frame-in (card at bytes)
  (when (>= bytes 14)
    (case (two (+ at 12))
      (#x0806 (arp-in card (+ at 14) (- bytes 14)))
      (#x0800 (packet-in card (+ at 14) (- bytes 14) (six (+ at 6)))))))

;; The thread of a card: whatever the card has put into the pages that it
;; was given is taken, twelve bytes of virtio's before each frame, and the
;; page given back to the card for the next one. Whoever waits for
;; something to arrive is told to look. A frame that cannot be made sense
;; of is counted and dropped: what is on a wire is anybody's to send.
(defun serve (card)
  (let ((event (clara.virtio:device-event (card-device card))) (queue (card-receive card)))
    (loop
      (clara:wait-event event 250)
      (let ((any nil))
        (loop
          (multiple-value-bind (page written) (clara.virtio:queue-take queue)
            (unless page
              (return))
            (setq any t)
            (when (> written 12)
              (handler-case (frame-in card (+ page 12) (min (- written 12) 4084))
                (error ()
                  (setf (card-dropped card) (1+ (card-dropped card))))))
            (clara.virtio:queue-add queue (list (list page 4096 t)) page)))
        (when any
          (clara.virtio:queue-notify queue)
          (clara:signal-event (card-heard card)))))))

;; Open a virtio network card. Of what such a card can do, the driver asks
;; for bit 5, by which the card says that it has an address of its own, in
;; the first six bytes of its own registers (5.1.4). Its first queue is for
;; what arrives and its second for what goes out (5.1.2). The card is given
;; page frames to put arriving frames into, one for each, and a few are
;; kept to put frames together in.
(defun open-card (pci)
  (let* ((device (clara.virtio:open-device pci 32))
         (receive (clara.virtio:open-queue device 0 64))
         (send (clara.virtio:open-queue device 1 64))
         (station 0) (spare nil))
    (unless (/= 0 (logand (clara.virtio:device-features device) 32))
      (error "the card does not say which address it has on the wire"))
    (dotimes (i 6)
      (setq station (+ (* 256 station) (clara.virtio:register-8 device i))))
    (dotimes (i (min 32 (clara.virtio:queue-size receive)))
      (let ((page (clara.unsafe:allocate-memory 1)))
        (clara.virtio:queue-add receive (list (list page 4096 t)) page)))
    (dotimes (i (min 8 (clara.virtio:queue-size send)))
      (setq spare (cons (clara.unsafe:allocate-memory 1) spare)))
    (clara.virtio:start-device device)
    (clara.virtio:queue-notify receive)
    (make-card :device device :receive receive :send send :name (clara.pci:location pci) :station station
               :lock (clara:make-lock "network card") :spare spare
               :heard (clara:make-event "arrived") :idle (clara:make-event "a while"))))

;; Find the network card among the PCI devices, the first one that there
;; is, and say what it is. A card that a world has kept from an earlier
;; start is another machine's: its thread is gone with that machine, and
;; so are its address and whatever was open.
(defun start ()
  (when (and *card* (card-thread *card*) (clara:thread-alive-p (card-thread *card*)))
    (clara:destroy-thread (card-thread *card*)))
  (setq *card* nil)
  (dolist (pci (clara.pci:devices))
    (when (and (null *card*) (eql (clara.virtio:device-type pci) 1))
      (handler-case
          (let ((card (open-card pci)))
            (setf (card-thread card)
                  (clara:make-thread (lambda () (serve card))
                                     :name (concatenate 'string "network " (clara.pci:location pci))))
            (setq *card* card)
            (format t "net: ~A is a network card, ~A on the wire~%" (card-name card) (station-text (card-station card))))
        (error (condition)
          (format t "net: ~A did not start: ~A~%" (clara.pci:location pci) condition)))))
  (when (null *card*)
    (format t "net: no network card that has a driver here: nothing is fetched from another machine~%"))
  *card*)
