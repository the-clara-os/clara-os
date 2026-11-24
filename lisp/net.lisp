;;;; net.lisp: the network
;;;;
;;;; What it takes to fetch a file from another machine, and to be a
;;;; machine that others connect to: the driver for virtio's network card
;;;; (Virtual I/O Device specification 1.2, 5.1, on top of
;;;; lisp/virtio.lisp), and above it the protocols of the Internet.
;;;;
;;;;   Ethernet    frames on the wire, from one card to another
;;;;   ARP         which card has an address (RFC 826)
;;;;   IPv4        packets from one address to another, whole ones only (RFC 791)
;;;;   ICMP        what machines say about packets: that one did not arrive, and "are you there?" (RFC 792)
;;;;   IPv6        the same packets with addresses of 128 bits (RFC 8200), and with them ICMPv6 (RFC 4443),
;;;;               which is also how a machine finds its neighbours and its routers, and learns from the
;;;;               routers which addresses it has (RFC 4861, RFC 4862)
;;;;   UDP         one packet and no promise (RFC 768), for the two below
;;;;   DHCP        asks the network which address this machine has, and for how long (RFC 2131)
;;;;   DNS         asks which address a name has (RFC 1035)
;;;;   TCP         bytes in order, and all of them or an error (RFC 9293)
;;;;   HTTP        a file, by its name on another machine (RFC 9112)
;;;;
;;;; Nothing in this file is kept from anybody: what is fetched from an
;;;; address that begins with http:// comes as the other side sends it, and
;;;; whoever is on the way can read it and change it. An address that
;;;; begins with https:// is fetched over a connection that TLS keeps
;;;; closed, which is lisp/tls.lisp: that file is loaded after this one and
;;;; tells this one what it can do (*SECURE*), and FETCH then asks it to
;;;; open the connection, to say the request, and to make of what arrives
;;;; what the other side said.
;;;;
;;;; A frame is put together and taken apart in page frames, which is where
;;;; the card reads and writes: numbers go onto the wire with their highest
;;;; byte first, and are read and written here a byte at a time. One thread
;;;; takes what arrives, hands it up through the protocols, and answers
;;;; what has to be answered at once: who has this address, that this
;;;; machine is there, and that a piece of a file has come. It is also the
;;;; thread that time passes for: what a connection has sent, and the other
;;;; side has not said that it has, goes out again from there, and the
;;;; network is asked there whether the machine may keep its address before
;;;; the time runs out that it was given for. Whoever asks for something
;;;; waits for that thread to say that something has arrived, looks whether
;;;; it was what it waited for, and asks again every second for as long as
;;;; it was not.
;;;;
;;;; The machine asks for its address when something first wants the
;;;; network, and not as it starts: a machine that fetches nothing sends
;;;; nothing.
;;;;
;;;; An address is a number when it is one of IPv4's, and a list of eight
;;;; numbers of sixteen bits when it is one of IPv6's: the language has no
;;;; number of 128 bits. Whatever compares two addresses does it with
;;;; EQUAL, and the protocols above the packets do not care which kind
;;;; they are handed.
;;;;
;;;; A connection is a stream to whoever wants one: lines are read from it
;;;; and text is written to it. CONNECT opens one to another machine. SERVE
;;;; has the machine take the connections that others open to one of its
;;;; ports, and hands each to a function, in a thread of its own. Nothing
;;;; is taken at a port until somebody says so. A machine reaches itself
;;;; the same way, at the address that it has or at 127.0.0.1, without
;;;; anything going onto the wire.

(defpackage "CLARA.NET"
  (:use "COMMON-LISP")
  (:export "START" "UP" "ADDRESS" "ADDRESSES" "STATION" "RESOLVE" "PING" "FETCH" "FETCH-TEXT"
           "CONNECT" "WITH-CONNECTION" "SERVE" "STOP-SERVING" "SERVING"
           "*PATIENCE*" "*AGAIN*" "*NAME-SERVER*" "*NAME-PORT*" "*IPV6*" "*SECURE*"))
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
  book                  ; a lock for the lists below, which more than one thread adds to and takes from
  address mask router   ; this machine's address, the mask of its network, and the way out of it
  names                 ; who knows names: their addresses, the one that is asked first at the front
  server lease leased   ; who gave the machine its address, for how many milliseconds, and when
  question offer given  ; an exchange with a DHCP server that is under way: its number, what was offered, what was given
  renewed               ; when the server was last asked whether the machine may keep its address
  tried                 ; when no DHCP server answered, the last time
  addresses6            ; ((address . until) ...): the addresses of IPv6 that the machine has, the one that goes no
                        ; further than its own network first, which is its own for good (NIL); the others for a time
  routers6              ; ((address . until) ...): the ways out for IPv6, by what the routers said of themselves
  prefixes6             ; ((numbers . until) ...): which addresses are on this network: each by its first four numbers
  names6                ; who knows names, by addresses of IPv6
  asked6 times6         ; when the routers were last asked to say what the network is, and how many times they were
  heard6                ; a router has said so
  said6                 ; and it was said what the machine learned from that
  neighbours            ; ((address . station) ...): who has which address on this network
  answering             ; (address . station): who sent the packet that is being looked at, and from which card
  packet                ; (place . bytes): where that packet begins, and how many bytes its head is and eight more
  listeners             ; ((port . function) ...): who takes the UDP packets that come for a port
  closed                ; ((address port own) ...): where a UDP packet from the port OWN was not taken, by what came back
  echoes                ; ((identifier number . answer) ...): the pings that wait for their answers
  known                 ; ((name until . address) ...): the names that were asked for, and until when each holds
  connections           ; the TCP connections that there are
  spoken                ; ((port . until) ...): the ports that a connection spoke from which is no more, each with
                        ; the time until which no other connection speaks from it
  inside                ; ((place . bytes) ...): the packets that this machine has sent to itself, each in a page frame
  trouble               ; what last went wrong in what time brings about, as text: nobody was there to be told
  (count 1)             ; a number that no packet of this start has had yet
  (dropped 0))          ; how many frames could not be made sense of

;; A port of this machine's at which connections are taken (SERVE).
(defstruct door
  port
  function     ; what each connection is handed to, as a stream: a function, or the name of one
  most         ; how many connections are taken at once
  (count 0)    ; how many were taken since somebody said that they are to be
  trouble)     ; what the function last ended in, when it ended in an error: as text

(defstruct connection
  card from to to-port port
  state        ; :asked, while the other side has not answered; :answered, while the other side, which began, has
               ; not said that it has this side's answer; :open; :refused; :unreachable; :broken, when the other
               ; side gave it up; :silent, when it no longer says that it has what it is sent; :overrun, when more
               ; came than may; :closed
  door thread  ; of a connection that another machine began: the door that it came by, and the thread that has it
  (taken 0)    ; of a connection that is read a line at a time: how many bytes at the front of its memory were read,
  (scanned 0)  ; and how far that memory has been looked through for the end of the next line
  said         ; who said that the other side cannot be reached
  first        ; the number that our bytes are counted from
  heard        ; how far the other side has said that it has them: the number of the first byte that it has not
  expected     ; the number of the next byte of theirs
  memory room  ; what has arrived: page frames, and how many bytes they hold
  (held 0)     ; how many of those are filled, from the first byte on without a gap
  later        ; ((from . to) ...): what has arrived beyond a gap, as places in that memory
  limit        ; how many bytes may arrive,
  allowed      ; and how many of them the file may be that is fetched, which is what an error names
  ended        ; the other side has sent all that it will
  lock         ; for the two memories: the thread that takes what arrives moves what is in them
  frozen       ; nothing more is taken: the memory is somebody else's from here on, or nobody's
  secure       ; what lisp/tls.lisp keeps of a connection that it keeps closed, or NIL
  out          ; what is to be sent and the other side has not said that it has: page frames,
  (out-room 0) ; how many bytes they hold,
  (out-held 0) ; how many bytes there are in them, of which the first is the one that HEARD numbers,
  (sent 0)     ; and how many of those have gone out
  closing      ; this side is done: :asked, while the word for it waits behind what is to be sent; :sent; :heard
  (theirs 0)   ; how many bytes the other side has room for
  (piece 1400) ; how many bytes go into one segment at most
  (dares 14000) ; how many bytes this side lets be on their way at once
  (same 0)     ; how many times running the other side has said the same of how far it has them
  recover      ; a piece was lost: the number up to which bytes were on their way then
  patience again ; how long the other side is given to say something, and to say that it has what it was sent the
               ; first time, in milliseconds: as whoever last used the connection has them
  wait         ; after how many milliseconds without a word what is on its way goes out again
  moment       ; when something last went out that had not been out before, or was said to have arrived
  alive)       ; when the other side last said anything

(defvar *card* nil)          ; the network card that START found and opened, or NIL
(defvar *up-lock* (clara:make-lock "network")) ; one thread at a time asks which address this machine has
(defconstant +rest+ 120000)  ; how many milliseconds a port rests after a connection spoke from it
(defvar *patience* 10000)    ; how many milliseconds the other side may take over an answer
(defvar *again* 1000)        ; and after how many of them a question that has no answer yet is asked again
(defvar *name-server* nil)   ; who is asked for names instead of the ones that the network named: an address, as text
(defvar *name-port* 53)      ; and at which port
;; What keeps a connection closed, as lisp/tls.lisp says it: functions, each by its name. :OPEN, of a
;; connection and the name of the machine at its other end, greets that machine and gives what is kept
;; of the connection from then on, which the others take: :SAY, with a text, says it; :TAKE opens what
;; has arrived since; :HELD is how many bytes of what the other side said lie at the beginning of the
;; connection's memory; :ENDED is whether the other side has said that it is done; :CLOSE says that this
;; side is. NIL until that file is loaded.
(defvar *secure* nil)
;; May whoever needs to know which card has an address wait for the answer? Not the thread that takes
;; what arrives, which is the one that would have to take the answer, and nobody who holds the lock of a
;; connection, which that thread may be waiting for.
(defvar *waits* t)
(defvar *out-room* 65536)    ; how many bytes a connection keeps of what the other side has not said that it has
(defvar *ipv6* t)            ; does the machine speak IPv6 at all? NIL, before something first wants the network, and it does not
(defvar *router-wait* 1000)  ; how many milliseconds the routers of the network are given to say what the network is
(defvar *doors* nil)         ; the ports at which connections are taken: they are the world's, and outlast a card
(defvar *doors-lock* (clara:make-lock "doors"))

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

;; An address of IPv6 in memory, sixteen bytes, as its eight numbers; and
;; the other way.
(defun sixteen (at)
  (let ((address nil))
    (dotimes (i 8)
      (setq address (cons (two (+ at (* 2 (- 7 i)))) address)))
    address))

(defun put-sixteen (at address)
  (dolist (number address)
    (put-two at number)
    (setq at (+ at 2))))

;; What an address adds to a checksum: its numbers of sixteen bits.
(defun address-sum (address)
  (if (consp address)
      (reduce #'+ address)
      (+ (ash address -16) (logand address #xffff))))

;; What UDP and TCP add to their checksums of the packet around them, and
;; ICMP over IPv6: both addresses, the protocol, and how long their own
;; part is.
(defun around (from to protocol bytes)
  (+ (address-sum from) (address-sum to) protocol bytes))

(defun checksum (sum)
  (logxor #xffff (fold sum)))

;;; Time, and numbers that nobody can guess

(defun now ()
  (floor (* 1000 (get-internal-real-time)) internal-time-units-per-second))

;; Thirty-two bits that nobody can guess, from the device that makes such
;; numbers (lisp/random.lisp): the number that a connection counts its
;; bytes from, the number that an answer has to have, and the port that a
;; question is asked from are what somebody would have to guess who wants
;; to put a word in from outside. A machine without that device takes
;; bits that the last packet did not have, which tells one exchange from
;; another and keeps nobody out.
(defun fresh (card)
  (setf (card-count card) (+ (card-count card) 1))
  (or (ignore-errors (clara.random:below #x100000000))
      (logand (+ (* (logand (now) #xffffff) 40503) (* (card-count card) 7919) (logand (card-station card) #xffffff))
              #xffffffff)))

;;; Addresses as text

;; A number in base sixteen, in small letters.
(defun hex-text (number)
  (let ((digits "0123456789abcdef") (text ""))
    (loop
      (setq text (concatenate 'string (subseq digits (logand number 15) (1+ (logand number 15))) text)
            number (ash number -4))
      (when (= number 0)
        (return text)))))

;; An address of IPv6 as it is written (RFC 5952): its eight numbers in
;; base sixteen with colons between them, and two colons in place of the
;; longest run of numbers that are zero, the first such run when there are
;; two, and none for a single zero.
(defun six-text (address)
  (let ((best nil) (longest 0) (start 0) (run 0) (i 0) (text ""))
    (dolist (number address)
      (cond ((= number 0)
             (when (= run 0)
               (setq start i))
             (setq run (1+ run))
             (when (> run longest)
               (setq best start
                     longest run)))
            (t
             (setq run 0)))
      (setq i (1+ i)))
    (when (< longest 2)
      (setq best nil))
    (setq i 0)
    (dolist (number address)
      (cond ((and best (= i best))
             (setq text (concatenate 'string text "::")))
            ((and best (< best i (+ best longest))))
            (t
             (setq text (concatenate 'string text
                                     (if (or (= i 0) (char= (char text (1- (length text))) #\:)) "" ":")
                                     (hex-text number)))))
      (setq i (1+ i)))
    text))

(defun address-text (address)
  (if (consp address)
      (six-text address)
      (format nil "~D.~D.~D.~D" (logand (ash address -24) 255) (logand (ash address -16) 255)
              (logand (ash address -8) 255) (logand address 255))))

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

;; The number that up to four digits of base sixteen are, or NIL.
(defun hex-number (text)
  (let ((number 0))
    (and (< 0 (length text) 5)
         (dotimes (i (length text) number)
           (let ((digit (sixteenth (char-code (char text i)))))
             (unless digit
               (return nil))
             (setq number (+ (* 16 number) digit)))))))

;; The address of IPv6 that "fec0::2" is, or NIL for a text that is none:
;; numbers in base sixteen with colons between them, eight of them, or
;; fewer and two colons once, which stand for the zeroes that are missing.
(defun text-six (text)
  (let ((parts (pieces text #\:)) (gaps 0) (before nil) (behind nil))
    (when (< (length parts) 3)
      (return-from text-six nil))
    ;; two colons at the beginning or at the end leave one empty part more than they mean, and one colon
    ;; there is no address
    (when (string= (car parts) "")
      (unless (string= (cadr parts) "")
        (return-from text-six nil))
      (setq parts (cdr parts)))
    (let ((back (reverse parts)))
      (when (and (cdr back) (string= (car back) ""))
        (unless (string= (cadr back) "")
          (return-from text-six nil))
        (setq parts (reverse (cdr back)))))
    (dolist (part parts)
      (if (string= part "")
          (setq gaps (1+ gaps))
          (let ((number (hex-number part)))
            (unless number
              (return-from text-six nil))
            (if (= gaps 0)
                (setq before (cons number before))
                (setq behind (cons number behind))))))
    (let ((numbers (+ (length before) (length behind))))
      (cond ((= gaps 0)
             (and (= numbers 8) (reverse before)))
            ((and (= gaps 1) (< numbers 8))
             (let ((address (reverse behind)))
               (dotimes (i (- 8 numbers))
                 (setq address (cons 0 address)))
               (append (reverse before) address)))))))

;; The address that "10.0.2.2" is, or "fec0::2", or NIL for a text that is
;; neither.
(defun text-address (text)
  (let ((parts (pieces text #\.)) (address 0))
    (if (= (length parts) 4)
        (dolist (part parts address)
          (let ((number (number-of part)))
            (unless (and number (< number 256))
              (return nil))
            (setq address (+ (* 256 address) number))))
        (text-six text))))

(defun station-text (station)
  (let ((digits "0123456789abcdef") (text ""))
    (dotimes (i 6)
      (let ((byte (logand (ash station (* -8 (- 5 i))) 255)))
        (setq text (concatenate 'string text (if (= i 0) "" ":")
                                (subseq digits (ash byte -4) (1+ (ash byte -4)))
                                (subseq digits (logand byte 15) (1+ (logand byte 15)))))))
    text))

;; "a", "a and b", "a, b and c": several things, said as one says them.
(defun listed (texts)
  (cond ((null (cdr texts)) (car texts))
        ((null (cddr texts)) (concatenate 'string (car texts) " and " (cadr texts)))
        (t (concatenate 'string (car texts) ", " (listed (cdr texts))))))

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
  (let ((known (assoc address (card-neighbours card) :test #'equal)))
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
;; second (*AGAIN*) for as long as TEST gives nothing, or after twice as
;; long each time when SLOWER says so. What TEST gave; or an error, which
;; SAY makes the text of, when *PATIENCE* is over.
(defun ask-until (card test ask say &optional slower)
  (let ((begun (now)) (asked nil) (wait *again*))
    (loop
      (let ((got (funcall test)))
        (when got
          (return got)))
      (let ((time (now)))
        (when (> (- time begun) *patience*)
          (error "~A" (funcall say)))
        (when (or (null asked) (>= (- time asked) wait))
          (funcall ask)
          (when (and asked slower)
            (setq wait (* 2 wait)))
          (setq asked time)))
      (clara:wait-event (card-heard card) 50))))

;; The card that the packet came from which is being looked at, when
;; ADDRESS is who sent it: where the answer goes. That is the business of
;; the thread that looks at the packet and of nobody else. Another thread
;; that sends to the same address in that moment would find the note
;; there, and then, having lost its turn, find it gone: the card's
;; address that it handed on would be none.
(defun answering-card (card address)
  (let ((answering (and (eq (clara:current-thread) (card-thread card)) (card-answering card))))
    (and answering (equal (car answering) address) (cdr answering))))

;; The card that a packet for ADDRESS is handed to: the one that has the
;; address, when that is on this network, and otherwise the one that is the
;; way out of it. Everybody, for the address that means everybody. And for
;; an answer to the packet that is being looked at, the card that it came
;; from. Where nobody has said yet who has the address, the network is
;; asked, and the answer waited for; but not by somebody who may not wait
;; (*WAITS*), for whom that is an error, the question having gone out.
(defun station-of (card address)
  (cond ((consp address)
         (station-of-six card address))
        ((= address #xffffffff)
         #xffffffffffff)
        ((answering-card card address))
        ((null (card-address card))
         (error "this machine has no address of IPv4, and ~A is one" (address-text address)))
        (t
         (let* ((next (cond ((or (null (card-mask card))
                                 (= (logand address (card-mask card)) (logand (card-address card) (card-mask card))))
                             address)
                            ((card-router card))
                            (t (error "~A is not on this machine's network, and the network named no way out of it"
                                      (address-text address)))))
                (known (cdr (assoc next (card-neighbours card)))))
           (cond (known)
                 (*waits*
                  (ask-until card
                             (lambda () (cdr (assoc next (card-neighbours card))))
                             (lambda () (arp-out card nil 0 next))
                             (lambda () (format nil "nobody on the network says that it has the address ~A" (address-text next)))))
                 (t
                  (arp-out card nil 0 next)
                  (error "nobody on the network has said yet that it has the address ~A" (address-text next))))))))

;;; IPv4

;; Is an address this machine's own: the one that the network gave it, one
;; of those that it has of IPv6, or one by which every machine means
;; itself (127.0.0.0/8, and ::1)?
(defun own-p (card address)
  (if (consp address)
      (or (assoc address (card-addresses6 card) :test #'equal)
          (equal address '(0 0 0 0 0 0 0 1)))
      (or (and (card-address card) (= address (card-address card)))
          (= (ash address -24) 127))))

;; The address that this machine speaks from to an address: for one of
;; IPv4's, the one that the network gave it; for one of IPv6's, the address
;; itself when that is the machine's own, the one that goes no further
;; than the network when the other does not either (fe80::/10, and what
;; is for many at once, ff00::/8), and otherwise the first that a router
;; gave it.
(defun source-for (card to)
  (cond ((not (consp to))
         (or (card-address card) 0))
        ((own-p card to)
         to)
        ((or (= (logand (car to) #xffc0) #xfe80) (>= (car to) #xff00))
         (or (car (car (card-addresses6 card)))
             (error "this machine does not speak IPv6, and ~A is an address of it" (address-text to))))
        (t
         (or (car (cadr (card-addresses6 card)))
             (error "this machine has no address of IPv6 from which ~A could be reached: no router has given it one"
                    (address-text to))))))

;; A packet for this machine itself does not go onto the wire. FILL puts
;; it together in a page frame of its own, and it is left for the thread
;; of the card, which takes it as it takes what arrives: so everything
;; that arrives is looked at by one thread, wherever it came from.
(defun send-inside (card fill)
  (let ((page (clara.unsafe:allocate-memory 1)) (left nil))
    (unwind-protect
         (let ((bytes (funcall fill page)))
           (clara:with-lock-held ((card-book card))
             (setf (card-inside card) (append (card-inside card) (list (cons page bytes)))))
           (setq left t)
           (clara:signal-event (clara.virtio:device-event (card-device card)))
           bytes)
      (unless left
        (clara.unsafe:free-memory page 1)))))

;; A packet goes to an address: twenty bytes that say how long it is, which
;; protocol it carries, who it is from and who it is for, with a checksum
;; of those twenty; and then what it carries, which FILL writes, giving how
;; many bytes. It is not to be taken apart on the way: nothing here puts
;; pieces together.
(defun send-packet (card to protocol fill &optional (from (source-for card to)))
  (when (consp to)
    (return-from send-packet (send-packet-six card to protocol fill from)))
  (flet ((packet (at)
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
             bytes)))
    (if (own-p card to)
        (send-inside card #'packet)
        (send-frame card (station-of card to) #x0800 #'packet))))

;; A packet has arrived: from the wire, through the card STATION, or from
;; this machine itself, when that is NIL. One from the wire is for this
;; machine or for everybody; it is not for an address by which a machine
;; means itself, and it is not from an address of this machine's, which
;; nobody else has. While it is looked at, the card remembers who sent it
;; and through which card, for an answer, and where it begins, for whoever
;; has to send its beginning back with the word that it was not taken.
(defun packet-in (card at bytes station)
  (when (and (>= bytes 20) (= (ash (one at) -4) 4))
    (let ((header (* 4 (logand (one at) 15))) (whole (two (+ at 2)))
          (from (four (+ at 12))) (to (four (+ at 16))))
      (when (and (>= header 20) (<= header whole) (<= whole bytes)
                 (= 0 (logand (two (+ at 6)) #x3fff))     ; whole, and not a piece of a packet
                 (= (fold (clara.unsafe:internet-sum at header)) #xffff)
                 (if station
                     (and (not (own-p card from)) (/= (ash to -24) 127)
                          (or (null (card-address card)) (= to (card-address card)) (= to #xffffffff)))
                     (own-p card to)))
        (setf (card-answering card) (cons from station)
              (card-packet card) (cons at (min whole (+ header 8))))
        (unwind-protect
             (case (one (+ at 9))
               (1 (control-in card from to (+ at header) (- whole header)))
               (17 (datagram-in card from to (+ at header) (- whole header)))
               (6 (segment-in card from to (+ at header) (- whole header))))
          (setf (card-answering card) nil
                (card-packet card) nil))))))

;;; IPv6

;; A packet of IPv6's goes to an address: forty bytes that say that it is
;; one, how long what it carries is, which protocol that is, how many
;; machines may hand it on, who it is from and who it is for; and what it
;; carries, which FILL writes, giving how many bytes. It has no checksum
;; of its own. HOPS is 255 for what a machine says to its neighbours, who
;; know by that number that nobody handed it on.
(defun send-packet-six (card to protocol fill from &optional (hops 64))
  (flet ((packet (at)
           (let ((bytes (funcall fill (+ at 40))))
             (put-four at #x60000000)
             (put-two (+ at 4) bytes)
             (put-one (+ at 6) protocol)
             (put-one (+ at 7) hops)
             (put-sixteen (+ at 8) from)
             (put-sixteen (+ at 24) to)
             (+ 40 bytes))))
    (if (own-p card to)
        (send-inside card #'packet)
        (send-frame card (station-of card to) #x86dd #'packet))))

;; The first four numbers of an address: which network it is on, where
;; networks are 64 bits, as the ones are that a machine makes its own
;; address on.
(defun network-of (address)
  (list (first address) (second address) (third address) (fourth address)))

;; The card that a packet of IPv6's for an address is handed to. One that
;; is for many machines at once goes to a card's address that is made of
;; its last four bytes (RFC 2464, 7). Otherwise it is the card of the
;; address, when that is on this network, which the routers have said or
;; the address says itself (fe80::/10), and the card of a router when it
;; is not; and that card is found by asking the neighbours who has the
;; address, as ARP asks.
(defun station-of-six (card address)
  (cond ((>= (car address) #xff00)
         (+ (ash #x3333 32) (ash (nth 6 address) 16) (nth 7 address)))
        ((answering-card card address))
        (t
         (let* ((next (cond ((or (= (logand (car address) #xffc0) #xfe80)
                                 (assoc (network-of address) (card-prefixes6 card) :test #'equal))
                             address)
                            ((car (car (card-routers6 card))))
                            (t (error "~A is not on this machine's network, and no router has said that it is a way out"
                                      (address-text address)))))
                (known (cdr (assoc next (card-neighbours card) :test #'equal))))
           (cond (known)
                 (*waits*
                  (ask-until card
                             (lambda () (cdr (assoc next (card-neighbours card) :test #'equal)))
                             (lambda () (neighbour-out card next))
                             (lambda () (format nil "nobody on the network says that it has the address ~A" (address-text next)))))
                 (t
                  (neighbour-out card next)
                  (error "nobody on the network has said yet that it has the address ~A" (address-text next))))))))

;; A message of ICMP's over IPv6 goes out: like one over IPv4, but its
;; checksum takes the addresses in.
(defun control-six-out (card to kind code word fill &optional (from (source-for card to)) (hops 64))
  (send-packet-six card to 58
                   (lambda (at)
                     (let ((bytes (+ 8 (funcall fill (+ at 8)))))
                       (put-one at kind)
                       (put-one (+ at 1) code)
                       (put-two (+ at 2) 0)
                       (put-four (+ at 4) word)
                       (put-two (+ at 2) (checksum (+ (around from to 58 bytes) (clara.unsafe:internet-sum at bytes))))
                       bytes))
                   from hops))

;; The address of many machines at once that a machine with ADDRESS
;; listens to for the question who has it: ff02::1:ff and the last three
;; bytes of the address (RFC 4291, 2.7.1).
(defun asked-at (address)
  (list #xff02 0 0 0 0 1 (+ #xff00 (logand (nth 6 address) 255)) (nth 7 address)))

;; Where a card's address goes in what neighbours tell each other: a kind
;; (1 the sender's, 2 the one that was asked for), a length of one, which
;; counts eight bytes, and the six bytes.
(defun put-station (at kind station)
  (put-one at kind)
  (put-one (+ at 1) 1)
  (put-six (+ at 2) station)
  8)

;; The question, to whoever has ADDRESS: which card is yours (135)? With
;; this card's address, so that the answer need not ask in turn.
(defun neighbour-out (card address)
  (control-six-out card (asked-at address) 135 0 0
                   (lambda (at)
                     (put-sixteen at address)
                     (+ 16 (put-station (+ at 16) 1 (card-station card))))
                   (car (car (card-addresses6 card))) 255))

;; The routers are asked to say what the network is (133).
(defun routers-out (card)
  (setf (card-asked6 card) (now)
        (card-times6 card) (1+ (or (card-times6 card) 0)))
  (control-six-out card '(#xff02 0 0 0 0 0 0 2) 133 0 0
                   (lambda (at) (put-station at 1 (card-station card)))
                   (car (car (card-addresses6 card))) 255))

;; The card's address among the things that follow a message between
;; neighbours, each a kind, a length that counts eight bytes, and what it
;; says: the one of KIND, or NIL.
(defun station-among (at end kind)
  (loop
    (when (> (+ at 8) end)
      (return nil))
    (let ((length (* 8 (one (+ at 1)))))
      (when (or (= length 0) (> (+ at length) end))
        (return nil))
      (when (and (= (one at) kind) (= length 8))
        (return (six (+ at 2))))
      (setq at (+ at length)))))

;; The address that this machine has on the network whose first four
;; numbers are given: those, and four that are made of its card's address
;; (RFC 4291, appendix A).
(defun address-on (card network)
  (let ((station (card-station card)))
    (append network
            (list (logxor #x0200 (logand (ash station -32) #xffff))
                  (+ (logand (ash station -16) #xff00) #xff)
                  (+ #xfe00 (logand (ash station -16) #xff))
                  (logand station #xffff)))))

;; A list of things that hold until a time has one more, or has one for
;; longer; one that holds for no time at all is taken off it.
(defun hold (list thing milliseconds)
  (let ((others (remove-if (lambda (held) (equal (car held) thing)) list)))
    (if (> milliseconds 0)
        (append others (list (cons thing (+ (now) milliseconds))))
        others)))

;; How many milliseconds some seconds are that a router said: four
;; thousand million of them mean for good, and are a year here.
(defun lasting (seconds)
  (* 1000 (min seconds 31536000)))

;; A router says what the network is (134): how long it is a way out, and
;; then, each with its kind and its length before it, the networks whose
;; addresses are on this wire (3), with whether a machine is to make its
;; own address on one, and who knows names (25, RFC 8106). The machine
;; takes an address on each network where it is to, with its card's
;; address for the second half.
(defun routers-in (card from at bytes)
  (when (and (>= bytes 16) (= (logand (car from) #xffc0) #xfe80))
    (let ((end (+ at bytes)) (option (+ at 16)))
      (clara:with-lock-held ((card-book card))
        (setf (card-routers6 card) (hold (card-routers6 card) from (lasting (two (+ at 6))))
              (card-heard6 card) t)
        (loop
          (when (> (+ option 8) end)
            (return))
          (let ((kind (one option)) (length (* 8 (one (+ option 1)))))
            (when (or (= length 0) (> (+ option length) end))
              (return))
            (cond ((and (= kind 3) (= length 32) (= (one (+ option 2)) 64))
                   (let ((network (network-of (sixteen (+ option 16)))) (time (lasting (four (+ option 4))))
                         (flags (one (+ option 3))))
                     (unless (= (logand (car network) #xffc0) #xfe80)
                       (when (/= 0 (logand flags #x80))
                         (setf (card-prefixes6 card) (hold (card-prefixes6 card) network time)))
                       (when (/= 0 (logand flags #x40))
                         (setf (card-addresses6 card)
                               (cons (car (card-addresses6 card))
                                     (hold (cdr (card-addresses6 card)) (address-on card network) time)))))))
                  ((and (= kind 25) (>= length 24))
                   (let ((names nil))
                     (when (> (four (+ option 4)) 0)
                       (dotimes (i (floor (- length 8) 16))
                         (setq names (cons (sixteen (+ option 8 (* 16 i))) names))))
                     (setf (card-names6 card) (reverse names)))))
            (setq option (+ option length))))))))

;; A message of ICMP's over IPv6 has arrived. What neighbours and routers
;; say (133 to 136) counts only when nobody handed it on, which the 255 in
;; HOPS says (RFC 4861, 6.1). A machine that asks who has an address of
;; this machine's is told, and its card is learned from the question; an
;; answer to such a question says whose card it is. Then, as over IPv4:
;; whether this machine is there (128), which is answered (129); the
;; answer to that; and the word that a packet did not arrive (1) or was
;; too long (2), for whoever sent it.
(defun control-six-in (card from to at bytes hops)
  (when (and (>= bytes 8) (= (fold (+ (around from to 58 bytes) (clara.unsafe:internet-sum at bytes))) #xffff))
    (let ((kind (one at)) (code (one (+ at 1))) (near (and (= hops 255) (= (one (+ at 1)) 0))))
      (cond ((and (= kind 135) near (>= bytes 24))
             (let ((asked (sixteen (+ at 8))) (station (station-among (+ at 24) (+ at bytes) 1)))
               (when (and station (not (equal from '(0 0 0 0 0 0 0 0))))
                 (learn card from station))
               (when (assoc asked (card-addresses6 card) :test #'equal)
                 (let ((answer-to (if (equal from '(0 0 0 0 0 0 0 0)) '(#xff02 0 0 0 0 0 0 1) from)))
                   (control-six-out card answer-to 136 0 (if (equal from '(0 0 0 0 0 0 0 0)) #x20000000 #x60000000)
                                    (lambda (out)
                                      (put-sixteen out asked)
                                      (+ 16 (put-station (+ out 16) 2 (card-station card))))
                                    asked 255)))))
            ((and (= kind 136) near (>= bytes 24))
             (let ((station (or (station-among (+ at 24) (+ at bytes) 2) (cdr (card-answering card)))))
               (when station
                 (learn card (sixteen (+ at 8)) station))))
            ((and (= kind 134) near)
             (routers-in card from at bytes))
            ((and (= kind 128) (= code 0) (own-p card to))
             (control-six-out card from 129 0 (four (+ at 4))
                              (lambda (out)
                                (clara.unsafe:copy-memory out (+ at 8) (- bytes 8))
                                (- bytes 8))
                              to))
            ((and (= kind 129) (= code 0))
             (let ((echo (assoc (two (+ at 4)) (card-echoes card))))
               (when (and echo (null (cddr echo)) (= (two (+ at 6)) (cadr echo)))
                 (rplacd (cdr echo) (now)))))
            ((or (= kind 1) (= kind 2))
             ;; what came back is the head of a packet of IPv6's that this machine sent, and what it carried
             (let ((back (+ at 8)))
               (when (and (>= bytes 56) (= (ash (one back) -4) 6) (own-p card (sixteen (+ back 8))))
                 (told card from (one (+ back 6)) (sixteen (+ back 24)) (two (+ back 40)) (two (+ back 42))
                       (four (+ back 44)) (and (= kind 2) (max 1280 (four (+ at 4))))))))))))

;; A packet of IPv6's has arrived, from the wire or from this machine
;; itself (STATION is NIL then), as one of IPv4's does. One from the wire
;; is for an address of this machine's or for many machines of this
;; network at once (ff02::/16), which is how neighbours are asked, and it
;; is not from an address of this machine's. What stands between the head
;; and what the packet carries is passed over where it says how long it
;; is; a packet in pieces is dropped.
(defun packet-six-in (card at bytes station)
  (when (and (>= bytes 40) (= (ash (one at) -4) 6) (card-addresses6 card))
    (let ((whole (+ 40 (two (+ at 4)))) (from (sixteen (+ at 8))) (to (sixteen (+ at 24)))
          (kind (one (+ at 6))) (inside (+ at 40)))
      (when (and (<= whole bytes)
                 (if station
                     (and (not (own-p card from)) (not (equal to '(0 0 0 0 0 0 0 1)))
                          (or (own-p card to) (= (car to) #xff02)))
                     (own-p card to)))
        (loop
          (unless (and (member kind '(0 43 60)) (<= (+ inside 8) (+ at whole)))
            (return))
          (setq kind (one inside)
                inside (+ inside 8 (* 8 (one (+ inside 1))))))
        (when (<= inside (+ at whole))
          (setf (card-answering card) (cons from station)
                (card-packet card) (cons at (min whole 48)))
          (unwind-protect
               (case kind
                 (58 (control-six-in card from to inside (- (+ at whole) inside) (one (+ at 7))))
                 (17 (datagram-in card from to inside (- (+ at whole) inside)))
                 (6 (segment-in card from to inside (- (+ at whole) inside))))
            (setf (card-answering card) nil
                  (card-packet card) nil)))))))

;; The machine begins to speak IPv6: it has the address that goes no
;; further than its own network, made of its card's address, and asks the
;; routers what the network is.
(defun begin-six (card)
  ;; when the routers were asked, and how often, is there before the address is: the thread that looks
  ;; at what time brings about goes by the address, and reads the other two
  (setf (card-asked6 card) (now)
        (card-times6 card) 0)
  (setf (card-addresses6 card) (list (cons (address-on card '(#xfe80 0 0 0)) nil)))
  (routers-out card))

;; The routers are given a while to answer, since most of what the machine
;; does with IPv6 waits on what they say.
(defun settle-six (card)
  (loop
    (when (or (card-heard6 card) (>= (- (now) (card-asked6 card)) *router-wait*))
      (return))
    (clara:wait-event (card-heard card) 20)))

;; What the machine learned from a router is said, once: its address, and
;; the way out. Who knows names is not said here. Under QEMU a router
;; names somebody only when the computer that QEMU runs on has a name
;; server of IPv6 itself, so the line would be another from one computer
;; to the next, and from one network of that computer's to the next.
(defun say-six (card)
  (when (and (card-heard6 card) (not (card-said6 card)))
    (setf (card-said6 card) t)
    (let ((own (cadr (card-addresses6 card))) (router (car (car (card-routers6 card)))))
      (format t "net: by IPv6 it is ~A~A~%"
              (address-text (car (or own (car (card-addresses6 card)))))
              (if router (format nil ", ~A is the way out" (address-text router)) "")))))

;; What time brings about for IPv6: routers that have not answered are
;; asked again, three times in all and four seconds apart (RFC 4861,
;; 6.3.7), and what a router said holds no longer than it said.
(defun keep-six (card time)
  (when (card-addresses6 card)
    (when (and (not (card-heard6 card)) (< (card-times6 card) 3) (>= (- time (card-asked6 card)) (* 4 *again*)))
      (routers-out card))
    (flet ((holds (held)
             (or (null (cdr held)) (> (cdr held) time))))
      (when (or (some (lambda (held) (not (holds held))) (card-addresses6 card))
                (some (lambda (held) (not (holds held))) (card-routers6 card))
                (some (lambda (held) (not (holds held))) (card-prefixes6 card)))
        (clara:with-lock-held ((card-book card))
          (setf (card-addresses6 card) (remove-if-not #'holds (card-addresses6 card))
                (card-routers6 card) (remove-if-not #'holds (card-routers6 card))
                (card-prefixes6 card) (remove-if-not #'holds (card-prefixes6 card))))))))

;;; ICMP: what machines say to each other about packets

;; A message of ICMP's goes out: what kind it is, and which of that kind;
;; a checksum of all of it; four bytes that the kind has its own use for;
;; and what FILL writes behind them, which gives how many bytes.
(defun control-out (card to kind code word fill)
  (send-packet card to 1
               (lambda (at)
                 (let ((bytes (+ 8 (funcall fill (+ at 8)))))
                   (put-one at kind)
                   (put-one (+ at 1) code)
                   (put-two (+ at 2) 0)
                   (put-four (+ at 4) word)
                   (put-two (+ at 2) (checksum (clara.unsafe:internet-sum at bytes)))
                   bytes))))

;; The sender of the packet that is being looked at is told that it was
;; not taken, and why (CODE 3: nothing takes packets at that port, which
;; over IPv6 is the kind 1 and of that the kind 4), with the head of the
;; packet and the first eight bytes behind it, by which the sender knows
;; which packet is meant.
(defun return-packet (card to code)
  (let ((packet (card-packet card)))
    (when packet
      (flet ((back (at)
               (clara.unsafe:copy-memory at (car packet) (cdr packet))
               (cdr packet)))
        (if (consp to)
            (control-six-out card to 1 4 0 #'back)
            (control-out card to 3 code 0 #'back))))))

;; Somebody on the way, FROM, says that a packet of this machine's did not
;; arrive where it was going, TO: the word came with the head of that
;; packet and the first eight bytes of what it carried, which are the two
;; ports for UDP and TCP, with the number of the first byte for TCP
;; (NUMBER), and for a ping its numbers. NARROW is how long a packet may
;; be, when the word is that this one was too long. Whoever sent the
;; packet is told: a connection that is beginning ends there, when the
;; number is its own, since anybody can send such a word; one that is told
;; that its packets are too long makes its pieces shorter; a question by
;; UDP is put down as not taken; and a ping has its answer.
(defun told (card from protocol to port to-port number narrow)
  (cond ((= protocol 6)
         (let ((connection (find-connection card to to-port port)))
           (cond ((null connection))
                 (narrow
                  ;; what a packet has before the bytes of a connection is forty bytes over IPv4, and sixty over IPv6
                  (clara:with-lock-held ((connection-lock connection))
                    (setf (connection-piece connection)
                          (max 256 (min (connection-piece connection) (- narrow (if (consp to) 60 40)))))))
                 ((and (eq (connection-state connection) :asked) (= number (connection-first connection)))
                  (setf (connection-said connection) from
                        (connection-state connection) :unreachable)))))
        ((= protocol 17)
         (when (and (null narrow) (assoc port (card-listeners card)))
           (clara:with-lock-held ((card-book card))
             (setf (card-closed card) (cons (list to to-port port) (card-closed card))))))
        ((or (= protocol 1) (= protocol 58))
         (let ((echo (assoc (ash number -16) (card-echoes card))))
           (when (and echo (null narrow) (null (cddr echo)))
             (rplacd (cdr echo) (list :unreachable from)))))))

;; What came back with such a word: the head of a packet of IPv4's, which
;; has to be one that this machine sent, and eight bytes behind it.
(defun returned (card from code room at bytes)
  (when (and (>= bytes 28) (= (ash (one at) -4) 4) (own-p card (four (+ at 12))))
    (let* ((header (* 4 (logand (one at) 15))) (inside (+ at header)))
      (when (and (>= header 20) (>= bytes (+ header 8)))
        (told card from (one (+ at 9)) (four (+ at 16)) (two inside) (two (+ inside 2)) (four (+ inside 4))
              (and (= code 4) (if (< room 296) 576 room)))))))

;; A message of ICMP's has arrived. One that asks whether this machine is
;; there (8) is answered with the same bytes (0); an answer to such a
;; question is put down for whoever asked; and the word that a packet did
;; not arrive (3) goes to whoever sent the packet. Everything else that
;; ICMP can say is passed over.
(defun control-in (card from to at bytes)
  (when (and (>= bytes 8) (= (fold (clara.unsafe:internet-sum at bytes)) #xffff))
    (let ((kind (one at)) (code (one (+ at 1))))
      (cond ((and (= kind 8) (= code 0) (own-p card to))
             (control-out card from 0 0 (four (+ at 4))
                          (lambda (out)
                            (clara.unsafe:copy-memory out (+ at 8) (- bytes 8))
                            (- bytes 8))))
            ((and (= kind 0) (= code 0))
             (let ((echo (assoc (two (+ at 4)) (card-echoes card))))
               (when (and echo (null (cddr echo)) (= (two (+ at 6)) (cadr echo)))
                 (rplacd (cdr echo) (now)))))
            ((= kind 3)
             (returned card from code (two (+ at 6)) (+ at 8) (- bytes 8)))))))

;;; UDP

(defun send-datagram (card to to-port from-port fill &optional (from (source-for card to)))
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
;; The port 68 is where a DHCP server answers, and is the card's own. A
;; packet for this machine that nobody listens for is answered with the
;; word that it was not taken.
(defun datagram-in (card from to at bytes)
  (when (>= bytes 8)
    (let ((whole (two (+ at 4))))
      (when (and (<= 8 whole bytes)
                 ;; over IPv4 a packet may come without a checksum, and over IPv6 it may not
                 (or (and (= (two (+ at 6)) 0) (not (consp from)))
                     (= (fold (+ (around from to 17 whole) (clara.unsafe:internet-sum at whole))) #xffff)))
        (let* ((port (two (+ at 2))) (listener (cdr (assoc port (card-listeners card)))))
          (cond ((= port 68)
                 (dhcp-in card (+ at 8) (- whole 8)))
                (listener
                 (funcall listener from (two at) (+ at 8) (- whole 8)))
                ((own-p card to)
                 (return-packet card from 3))))))))

(defun listen-at (card port function)
  (clara:with-lock-held ((card-book card))
    (setf (card-listeners card) (cons (cons port function) (card-listeners card)))))

;; Nobody listens at a port any more, and what came back for packets that
;; were sent from it means nothing to anybody.
(defun listen-no-more (card port)
  (clara:with-lock-held ((card-book card))
    (setf (card-listeners card) (remove-if (lambda (listener) (= (car listener) port)) (card-listeners card))
          (card-closed card) (remove-if (lambda (closed) (= (third closed) port)) (card-closed card)))))

;; A port to speak from, which nothing of this machine's speaks from at the
;; moment: one of the sixteen thousand that are nobody's by right (RFC
;; 6335, 6), and nobody can say which. Nor is it one that a connection
;; spoke from a short while ago. The other side remembers a connection
;; that is over for a time, by the two addresses and the two ports, so
;; that a piece of it which comes late is not taken for something new
;; (RFC 9293, 3.6.1), and a beginning from the same port to the same place
;; is such a piece to it: it says nothing, and the connection is never
;; begun. A machine that fetches fifty files from one place, each over a
;; connection of its own, would pick a port twice one time in ten.
(defun next-port (card)
  (let ((time (now)))
    (clara:with-lock-held ((card-book card))
      (let ((resting (remove-if (lambda (spoken) (>= time (cdr spoken))) (card-spoken card))))
        ;; More ports than half of those there are do not rest at once: the ones that have rested longest are let go.
        (setf (card-spoken card) (if (> (length resting) 8192) (subseq resting 0 4096) resting)))))
  (loop
    (let ((port (+ 49152 (logand (fresh card) 16383))))
      (unless (or (assoc port (card-listeners card))
                  (assoc port (card-spoken card))
                  (find-if (lambda (connection) (= (connection-port connection) port)) (card-connections card)))
        (return port)))))

;;; DHCP: which address this machine has

;; What a DHCP server says, as (kind address server mask router names
;; seconds), or NIL when the packet is no answer to the question NUMBER.
;; An answer (RFC 2131, 2) is 236 bytes of fixed places, of which this
;; reads that it is an answer, the question's number, and the address that
;; is offered; four bytes that say that options follow; and the options,
;; each a number, a length and that many bytes (RFC 2132): 53 what kind of
;; message, 1 the mask, 3 the ways out, 6 who knows names, 51 for how many
;; seconds the address is this machine's, 54 the server.
(defun dhcp-answer (at bytes number)
  (when (and (>= bytes 240) (= (one at) 2) (= (four (+ at 4)) number) (= (four (+ at 236)) #x63825363))
    (let ((kind nil) (server nil) (mask nil) (router nil) (names nil) (seconds nil) (option (+ at 240)) (end (+ at bytes)))
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
                         ((and (= code 51) (>= length 4)) (setq seconds (four value)))
                         ((and (= code 6) (>= length 4))
                          (setq names nil)
                          (dotimes (i (floor length 4))
                            (setq names (cons (four (+ value (* 4 i))) names)))
                          (setq names (reverse names))))
                   (setq option (+ value length)))))))
      (and kind (list kind (four (+ at 16)) server mask router names seconds)))))

;; A question to whatever DHCP server there is. From a machine that has no
;; address yet it goes to everybody, and so is the answer to: KIND is 1 to
;; ask who has an address for this machine, and 3 to take the one that
;; SERVER offered. A machine that has its address asks the server that
;; gave it, and nobody else, whether it may keep it (KEEPING): that is the
;; kind 3 as well, with the address where a machine says which one it has,
;; and without the two options that name an offer (RFC 2131, 4.3.2).
(defun dhcp-out (card number kind address server &optional keeping)
  (send-datagram card (if keeping server #xffffffff) 67 68
                 (lambda (at)
                   (clear at 300)
                   (put-one at 1)
                   (put-one (+ at 1) 1)
                   (put-one (+ at 2) 6)
                   (put-four (+ at 4) number)
                   (if keeping
                       (put-four (+ at 12) address)
                       (put-two (+ at 10) #x8000))     ; the answer is to go to everybody: this machine has no address
                   (put-six (+ at 28) (card-station card))
                   (put-four (+ at 236) #x63825363)
                   (put-one (+ at 240) 53)
                   (put-one (+ at 241) 1)
                   (put-one (+ at 242) kind)
                   (let ((option (+ at 243)))
                     (when (and address (not keeping))
                       (put-one option 50)
                       (put-one (+ option 1) 4)
                       (put-four (+ option 2) address)
                       (setq option (+ option 6)))
                     (when (and server (not keeping))
                       (put-one option 54)
                       (put-one (+ option 1) 4)
                       (put-four (+ option 2) server)
                       (setq option (+ option 6)))
                     (put-one option 55)              ; what is wanted beside an address: the mask, the way out, who
                     (put-one (+ option 1) 4)         ; knows names, and for how long all of it holds
                     (put-one (+ option 2) 1)
                     (put-one (+ option 3) 3)
                     (put-one (+ option 4) 6)
                     (put-one (+ option 5) 51)
                     (put-one (+ option 6) 255))
                   300)
                 (if keeping address 0)))

;; The address that a DHCP server gave is this machine's from now, with
;; what the server says of the network, for as long as it says: for a day,
;; when it does not say, and for a year at most.
(defun take-lease (card given)
  (setf (card-address card) (second given)
        (card-server card) (third given)
        (card-mask card) (or (fourth given) #xffffff00)
        (card-router card) (nth 4 given)
        (card-names card) (nth 5 given)
        (card-lease card) (* 1000 (min (or (nth 6 given) 86400) 31536000))
        (card-leased card) (now)
        (card-renewed card) nil
        (card-question card) nil)
  ;; the card's thread looks at the time more often from now on, and is told so
  (clara:signal-event (clara.virtio:device-event (card-device card))))

;; The address is no longer this machine's, and nothing says any more
;; which addresses are on its network.
(defun lose-address (card)
  (setf (card-address card) nil
        (card-mask card) nil
        (card-question card) nil))

;; A DHCP server has said something. It is an answer when it has the
;; number of the exchange that is under way. To a machine that asks for an
;; address, an offer (2) is kept, the first one, and so is the word that
;; the offered address is the machine's (5), both for whoever is asking;
;; the word that it is not (6) takes the offer back. To a machine that
;; asks whether it may keep its address, the word that it may makes the
;; address the machine's for as long again, and the word that it may not
;; takes the address away: whatever wants the network next asks anew.
(defun dhcp-in (card at bytes)
  (let* ((answer (and (card-question card) (dhcp-answer at bytes (card-question card)))) (kind (car answer))
         (who (card-answering card)))
    ;; which card the server has is learned here: it will be asked again, and by a thread that cannot wait to find out
    (when (and answer who (/= (car who) 0))
      (learn card (car who) (cdr who)))
    (cond ((null answer))
          ((card-address card)
           (cond ((and (= kind 5) (= (second answer) (card-address card)))
                  (take-lease card answer))
                 ((= kind 6)
                  (lose-address card))))
          ((= kind 2)
           (unless (card-offer card)
             (setf (card-offer card) answer)))
          ((= kind 5)
           (when (card-offer card)
             (setf (card-given card) answer)))
          ((= kind 6)
           (setf (card-offer card) nil)))))

;; The machine asks the network which address it has, and takes the one
;; that the first server offers, with what that server says of the network.
(defun configure (card)
  (let ((number (fresh card)))
    (setf (card-offer card) nil
          (card-given card) nil
          (card-question card) number)
    (unwind-protect
         (progn
           (ask-until card (lambda () (card-offer card)) (lambda () (dhcp-out card number 1 nil nil))
                      (lambda () "no DHCP server says which address this machine has on its network"))
           (ask-until card (lambda () (card-given card))
                      (lambda ()
                        (let ((offer (card-offer card)))
                          (when offer
                            (dhcp-out card number 3 (second offer) (third offer)))))
                      (lambda () "the DHCP server that offered this machine an address did not give it"))
           (take-lease card (card-given card)))
      (setf (card-question card) nil))
    (format t "net: this machine is ~A on its network~A~A~%" (address-text (card-address card))
            (if (card-router card) (format nil ", ~A is the way out" (address-text (card-router card))) "")
            (if (card-names card)
                (format nil ", ~A ~A names" (listed (mapcar #'address-text (card-names card)))
                        (if (cdr (card-names card)) "know" "knows"))
                ""))
    card))

;; An address is the machine's for a time. When half of that is over, the
;; server that gave it is asked whether the machine may keep it, and asked
;; again every ten seconds until it answers; when all of it is over and no
;; answer has come, the address is no longer this machine's. This is looked
;; at by the card's thread, which waits for no answer: the answer comes to
;; DHCP-IN like any other.
(defun keep-address (card time)
  (when (and (card-address card) (card-lease card))
    (let ((had (- time (card-leased card))))
      (cond ((>= had (card-lease card))
             (lose-address card))
            ((and (>= had (floor (card-lease card) 2)) (card-server card)
                  (or (null (card-renewed card)) (>= (- time (card-renewed card)) (* 10 *again*))))
             ;; the time of asking is put down when the question has gone out: one that could not, because
             ;; nobody has said yet which card the server has, is tried again the next time round
             (setf (card-question card) (fresh card))
             (dhcp-out card (card-question card) 3 (card-address card) (card-server card) t)
             (setf (card-renewed card) time))))))

;; The card, with an address: what everything above asks for first. The
;; machine has its addresses from the first time that something asks. It
;; asks the routers what the network is, for IPv6, and a DHCP server which
;; address it has, for IPv4, and then gives the routers a while to have
;; answered. A network on which no DHCP server answers is good enough when
;; a router has given the machine an address: that is said, and the server
;; is not asked again for a minute.
(defun up ()
  (let ((card *card*))
    (unless card
      (error "this machine has no network card that has a driver here"))
    (clara:with-lock-held (*up-lock*)
      (when (and *ipv6* (null (card-addresses6 card)))
        (begin-six card))
      (unless (or (card-address card)
                  (and (card-tried card) (cdr (card-addresses6 card)) (< (- (now) (card-tried card)) 60000)))
        (handler-case (configure card)
          (error (condition)
            (setf (card-tried card) (now))
            (when (card-addresses6 card)
              (settle-six card))
            (unless (cdr (card-addresses6 card))
              (error "~A" condition))
            (format t "net: ~A: this machine has no address of IPv4~%" condition))))
      (when (card-addresses6 card)
        (settle-six card)
        (say-six card)))
    card))

;; This machine's addresses, as texts: the one of IPv4 first, then the ones
;; of IPv6 that a router gave it, and last the one that goes no further
;; than its own network. NIL without a network card. And the first of
;; them; and the address of its card on the wire.
(defun addresses ()
  (and *card*
       (let ((card (up)))
         (mapcar #'address-text
                 (append (and (card-address card) (list (card-address card)))
                         (mapcar #'car (cdr (card-addresses6 card)))
                         (and (card-addresses6 card) (list (car (car (card-addresses6 card))))))))))

(defun address ()
  (car (addresses)))

(defun station ()
  (and *card* (station-text (card-station *card*))))

;;; Is a machine there?

;; A machine is asked to send back what it is sent (RFC 792, echo), every
;; second until it does: how many milliseconds the answer took, as far as
;; the machine's clock can tell, which counts hundredths of a second. An
;; error when no answer comes, and when somebody on the way says that the
;; machine cannot be reached.
(defun ping (name)
  (let* ((card (up)) (to (address-of name)) (identifier (logand (fresh card) #xffff))
         (echo (list* identifier 0 nil)) (sent 0))
    (clara:with-lock-held ((card-book card))
      (setf (card-echoes card) (cons echo (card-echoes card))))
    (unwind-protect
         (let ((answer (ask-until card (lambda () (cddr echo))
                                  (lambda ()
                                    (rplaca (cdr echo) (logand (1+ (cadr echo)) #xffff))
                                    (setq sent (now))
                                    (funcall (if (consp to) #'control-six-out #'control-out)
                                             card to (if (consp to) 128 8) 0 (+ (ash identifier 16) (cadr echo))
                                             (lambda (at)
                                               (dotimes (i 32)
                                                 (put-one (+ at i) (+ 97 (mod i 23))))
                                               32)))
                                  (lambda () (format nil "~A does not answer a ping" (address-text to))))))
           (when (consp answer)
             (error "~A says that ~A cannot be reached" (address-text (second answer)) (address-text to)))
           (max 0 (- answer sent)))
      (clara:with-lock-held ((card-book card))
        (setf (card-echoes card) (remove echo (card-echoes card)))))))

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

;; A question for the address of a name, written at AT: twelve bytes, of
;; which the first two are its number, the next two say that it is a
;; question and that the server is to ask further, and the rest that
;; there is one question; then the name, and what is asked of it, KIND,
;; its address of IPv4 (1) or of IPv6 (28), on the Internet (1). How many
;; bytes that was.
(defun put-question (at number name kind)
  (put-two at number)
  (put-two (+ at 2) #x0100)
  (put-two (+ at 4) 1)
  (put-two (+ at 6) 0)
  (put-two (+ at 8) 0)
  (put-two (+ at 10) 0)
  (let ((bytes (put-name (+ at 12) name)))
    (put-two (+ at 12 bytes) kind)
    (put-two (+ at 14 bytes) 1)
    (+ 16 bytes)))

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

;; What an answer says: (address . seconds), the address and for how long
;; it may be remembered; :NONE when there is no such name; :FAILED when
;; the server could not say; :CUT when the answer was too long for the
;; packet and came without its end; or NIL for a packet that is no answer
;; to the question NUMBER. An answer has twelve bytes of counts before the
;; question again and the records, each a name, a type, a class, how long
;; it holds, a length and that many bytes: the type 1 with four bytes is
;; an address of IPv4, and the type 28 with sixteen one of IPv6. WANTED is
;; the type that was asked for.
(defun name-answer (at bytes number wanted)
  (when (and (>= bytes 12) (= (two at) number) (/= 0 (logand (two (+ at 2)) #x8000)))
    (let ((failure (logand (two (+ at 2)) 15)) (end (+ at bytes)) (place (+ at 12)) (found nil))
      (cond ((= failure 3) :none)
            ((/= failure 0) :failed)
            ((/= 0 (logand (two (+ at 2)) #x0200)) :cut)
            (t
             (dotimes (i (two (+ at 4)))
               (setq place (and place (past-name place end)))
               (setq place (and place (+ place 4))))
             (dotimes (i (two (+ at 6)))
               (setq place (and place (past-name place end)))
               (when (and place (<= (+ place 10) end))
                 (let ((kind (two place)) (length (two (+ place 8))))
                   (when (and (null found) (= kind wanted) (= length (if (= wanted 28) 16 4)) (<= (+ place 10 length) end))
                     (setq found (cons (if (= wanted 28) (sixteen (+ place 10)) (four (+ place 10))) (four (+ place 4)))))
                   (setq place (+ place 10 length)))))
             (or found :none))))))

;; Who is asked for names: the one that CLARA.NET:*NAME-SERVER* names, or
;; the ones that the network named, the DHCP server first and the routers
;; after it.
(defun name-servers (card)
  (if *name-server*
      (list (or (text-address *name-server*)
                (error "~S, in CLARA.NET:*NAME-SERVER*, is no address" *name-server*)))
      (or (append (card-names card) (card-names6 card))
          (error "the network named nobody who knows names, and CLARA.NET:*NAME-SERVER* names nobody"))))

;; The name servers are asked for a name, by UDP: one of them every second,
;; each in its turn, until one has answered. One that says that it cannot
;; say, and one from which the word comes back that the question was not
;; taken, is asked no more, and the next is asked at once; when none is
;; left, that is the error. What the answer was (NAME-ANSWER); for one that
;; came cut short, (:cut . server).
(defun ask-names (card servers name kind)
  (let ((number (logand (fresh card) #xffff)) (port (next-port card))
        (answer nil) (out nil) (hurry nil) (begun (now)) (asked nil) (turn 0))
    (listen-at card port
               (lambda (from from-port at bytes)
                 (when (and (member from servers :test #'equal) from-port (null answer))
                   (let ((said (name-answer at bytes number kind)))
                     (cond ((null said))
                           ((eq said :failed)
                            (unless (assoc from out :test #'equal)
                              (setq out (cons (cons from :failed) out)
                                    hurry t)))
                           ((eq said :cut) (setq answer (cons :cut from)))
                           (t (setq answer said)))))))
    (unwind-protect
         (loop
           (dolist (closed (card-closed card))
             (when (and (= (third closed) port) (not (assoc (car closed) out :test #'equal)))
               (setq out (cons (cons (car closed) :closed) out)
                     hurry t)))
           (when answer
             (return answer))
           (let ((left (remove-if (lambda (server) (assoc server out :test #'equal)) servers)) (time (now)))
             (when (null left)
               (let ((whom (car (last out))))
                 (if (eq (cdr whom) :closed)
                     (error "~A takes no questions about names at its port ~D" (address-text (car whom)) *name-port*)
                     (error "~A, who knows names, could not say which address ~A has" (address-text (car whom)) name))))
             (when (> (- time begun) *patience*)
               (error "~A, who ~A names, ~A not say which address ~A has" (listed (mapcar #'address-text left))
                      (if (cdr left) "know" "knows") (if (cdr left) "do" "does") name))
             (when (or hurry (null asked) (>= (- time asked) *again*))
               (setq hurry nil
                     asked time)
               (send-datagram card (nth (mod turn (length left)) left) *name-port* port
                              (lambda (at) (put-question at number name kind)))
               (setq turn (1+ turn))))
           (clara:wait-event (card-heard card) 50))
      (listen-no-more card port))))

;; The same question by TCP, to a server whose answer by UDP came cut
;; short (RFC 7766): the question with its length before it, in two bytes,
;; and the answer likewise.
(defun ask-name-whole (card server name kind)
  (let ((connection (begin card server *name-port* 65536 0)) (page (clara.unsafe:allocate-memory 1))
        (number (logand (fresh card) #xffff)))
    (unwind-protect
         (let ((bytes (put-question (+ page 2) number name kind)))
           (put-two page bytes)
           (say-bytes connection page (+ 2 bytes))
           (flet ((answered ()
                    (clara:with-lock-held ((connection-lock connection))
                      (let ((held (connection-held connection)) (memory (connection-memory connection)))
                        (and (>= held 2) (>= held (+ 2 (two memory)))
                             (name-answer (+ memory 2) (two memory) number kind))))))
             (wait-for connection #'answered)
             (answered)))
      (clara.unsafe:free-memory page 1)
      (disconnect connection))))

;; What is remembered of a name, while it holds; and a name's addresses
;; are remembered, for as long as the answers said, and for a day at most.
(defun remembered (card name)
  (let ((known (assoc name (card-known card) :test #'string-equal)))
    (and known (> (cadr known) (now)) (cddr known))))

(defun remember (card name addresses seconds)
  (clara:with-lock-held ((card-book card))
    (setf (card-known card)
          (cons (list* name (+ (now) (* 1000 (min seconds 86400))) addresses)
                (remove-if (lambda (known) (string-equal (car known) name)) (card-known card))))))

;; What the name servers say of a name, for one kind of address:
;; (address . seconds), or NIL when the name has no address of that kind.
(defun ask-name (card name kind)
  (let ((answer (ask-names card (name-servers card) name kind)) (server nil))
    (when (and (consp answer) (eq (car answer) :cut))
      (setq server (cdr answer)
            answer (ask-name-whole card server name kind)))
    (cond ((eq answer :none) nil)
          ((consp answer) answer)
          (t (error "~A, who knows names, could not say which address ~A has" (address-text server) name)))))

;; The addresses of a name, the one that is to be tried first at the
;; front: of an address that is written out, that address, and of anything
;; else what the name servers say, who are asked for the kinds of address
;; that this machine has itself, and asked again when what they said no
;; longer holds. An address of IPv6 comes first when this machine has one
;; of the Internet's own (2000::/3), and otherwise the one of IPv4: a
;; machine whose addresses of IPv6 are good on its own network only does
;; better to leave it by IPv4 (RFC 6724). A name server that does not
;; answer for the second kind does not take away what it said for the
;; first.
(defun addresses-of (name)
  (let ((written (text-address name)))
    (if written
        (list written)
        (or (remembered (up) name)
            (let* ((card (up))
                   (older (and (card-address card) (ask-name card name 1)))
                   (newer (and (cdr (card-addresses6 card))
                               (if older
                                   (ignore-errors (ask-name card name 28))
                                   (ask-name card name 28))))
                   (found (remove nil (if (some (lambda (own) (= (logand (car (car own)) #xe000) #x2000))
                                                (cdr (card-addresses6 card)))
                                          (list newer older)
                                          (list older newer)))))
              (unless found
                (error "there is no machine of the name ~A" name))
              (remember card name (mapcar #'car found) (reduce #'min (mapcar #'cdr found)))
              (mapcar #'car found))))))

;; The address of a name: the first of them.
(defun address-of (name)
  (car (addresses-of name)))

;; The same, as text.
(defun resolve (name)
  (address-text (address-of name)))

;;; TCP: bytes in order

(defun wrap (number)
  (logand number #xffffffff))

;; Is the number A after B, as the bytes of a connection are counted, round
;; and round in thirty-two bits?
(defun after (a b)
  (let ((ahead (wrap (- a b))))
    (and (/= ahead 0) (< ahead #x80000000))))

;; Has a connection something that the other side has not said that it
;; has: bytes, or the word that this side is done? And is something of it
;; on its way, sent and not yet said to have arrived?
(defun waiting (connection)
  (or (> (connection-out-held connection) 0)
      (member (connection-closing connection) '(:asked :sent))))

(defun flying (connection)
  (or (> (connection-sent connection) 0) (eq (connection-closing connection) :sent)))

;; The number of the next byte that this side has not sent yet. The word
;; that this side is done counts as a byte, once it is said.
(defun next (connection)
  (wrap (+ (connection-heard connection) (connection-sent connection)
           (if (eq (connection-closing connection) :sent) 1 0))))

(defun find-connection (card to to-port port)
  (find-if (lambda (connection)
             (and (equal (connection-to connection) to) (= (connection-to-port connection) to-port)
                  (= (connection-port connection) port)))
           (card-connections card)))

;; A segment goes out: twenty bytes that say from which port to which, the
;; number of its first byte, how far the other side's bytes have arrived,
;; what it is about (1 the end, 2 the beginning, 4 giving up, 8 hand it on,
;; 16 the number of what has arrived counts), how many more bytes may come,
;; and a checksum of all of it with the addresses; four bytes more at the
;; beginning of a connection, which say how long a segment may be, which
;; is what a frame holds beside the heads of the packet and the segment;
;; and BYTES bytes of what the connection carries, from DATA.
(defun segment-out (card from to from-port to-port number arrived flags window &optional data (bytes 0))
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
                     (put-two (+ at 22) (if (consp to) 1440 1460)))
                   (when (> bytes 0)
                     (clara.unsafe:copy-memory (+ at header) data bytes))
                   (put-two (+ at 16) (checksum (+ (around from to 6 whole) (clara.unsafe:internet-sum at whole))))
                   whole))
               from))

;; How long a segment the other side takes, when it says so as a
;; connection begins: among the options behind the twenty bytes of a
;; segment's head, each a kind, a length and that many bytes, the kind 2
;; (RFC 9293, 3.7.1). NIL when it does not say.
(defun longest-piece (at header)
  (let ((option (+ at 20)) (end (+ at header)))
    (loop
      (when (>= option end)
        (return nil))
      (let ((kind (one option)))
        (cond ((= kind 0) (return nil))
              ((= kind 1) (setq option (1+ option)))
              ((>= (+ option 1) end) (return nil))
              (t
               (let ((length (one (+ option 1))))
                 (cond ((or (< length 2) (> (+ option length) end)) (return nil))
                       ((and (= kind 2) (= length 4)) (return (two (+ option 2))))
                       (t (setq option (+ option length)))))))))))

(defun window (connection)
  (max 0 (min 65535 (- (connection-limit connection) (connection-held connection)))))

;; The other side is told how far its bytes have arrived.
(defun acknowledge (connection)
  (segment-out (connection-card connection) (connection-from connection) (connection-to connection)
               (connection-port connection) (connection-to-port connection)
               (next connection) (connection-expected connection) 16 (window connection)))

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
;; expected. All of it with the connection's lock: whoever reads the memory
;; holds that lock too, since making room moves the memory. A connection
;; that is frozen takes nothing more.
(defun take-piece (connection ahead data bytes)
  (clara:with-lock-held ((connection-lock connection))
    (let* ((from (+ (connection-held connection) ahead))
           (fits (min bytes (- (connection-limit connection) from))))
      (cond ((connection-frozen connection)
             nil)
            ((and (= ahead 0) (< fits bytes))
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
             (= ahead 0))))))

;;; What a connection sends
;;;
;;; What is to be sent lies in page frames of the connection's until the
;;; other side has said that it has it. As much of it is on its way at any
;;; time as the other side has room for, and as this side dares: ten
;;; pieces at first, a piece more for every word that more has arrived,
;;; half as much when the other side says three times running that it
;;; lacks the same piece, which then goes out again at once, and one piece
;;; when nothing was said at all for a while. That while is a second, and
;;; twice as long each time that it has passed in vain (RFC 6298, RFC
;;; 5681). The thread of the card looks after all of this, when it hears
;;; from the other side and when time passes: whoever has something to
;;; say puts it there and is not needed again.

;; The memory of what a connection is to send has room for NEEDED bytes:
;; twice as much as before, or more.
(defun make-way (connection needed)
  (when (> needed (connection-out-room connection))
    (let* ((room (* 4096 (floor (+ (max needed (* 2 (connection-out-room connection))) 4095) 4096)))
           (memory (clara.unsafe:allocate-memory (floor room 4096))))
      (when (connection-out connection)
        (when (> (connection-out-held connection) 0)
          (clara.unsafe:copy-memory memory (connection-out connection) (connection-out-held connection)))
        (clara.unsafe:free-memory (connection-out connection) (floor (connection-out-room connection) 4096)))
      (setf (connection-out connection) memory
            (connection-out-room connection) room))))

;; A connection has nothing more to send, and that memory goes back.
(defun release-out (connection)
  (when (connection-out connection)
    (clara.unsafe:free-memory (connection-out connection) (floor (connection-out-room connection) 4096))
    (setf (connection-out connection) nil
          (connection-out-room connection) 0
          (connection-out-held connection) 0
          (connection-sent connection) 0)))

;; As much goes out of what a connection has to send as may be on its way,
;; in pieces, and behind the last of it the word that this side is done,
;; when it is. With the connection's lock held, since the bytes must stay
;; where they are while a frame is made of them; and so nothing here waits
;; for the network: who has the other side's address is known by now.
(defun pump (connection)
  (let ((card (connection-card connection)) (idle (not (flying connection))) (*waits* nil))
    (loop
      (let* ((sent (connection-sent connection))
             (piece (min (connection-piece connection) (- (connection-out-held connection) sent)
                         (- (min (connection-theirs connection) (connection-dares connection)) sent))))
        (when (<= piece 0)
          (return))
        (segment-out card (connection-from connection) (connection-to connection) (connection-port connection)
                     (connection-to-port connection) (wrap (+ (connection-heard connection) sent))
                     (connection-expected connection) 24 (window connection) (+ (connection-out connection) sent) piece)
        (setf (connection-sent connection) (+ sent piece))))
    (when (and (eq (connection-closing connection) :asked)
               (= (connection-sent connection) (connection-out-held connection)))
      (segment-out card (connection-from connection) (connection-to connection) (connection-port connection)
                   (connection-to-port connection) (wrap (+ (connection-heard connection) (connection-sent connection)))
                   (connection-expected connection) 17 (window connection))
      (setf (connection-closing connection) :sent))
    (when (and idle (flying connection))
      (setf (connection-moment connection) (now)))))

;; The first piece of what the other side has not said that it has goes
;; out again, or the word that this side is done, when that is all there
;; is. One byte goes out even when the other side has said that it has no
;; room at all: the answer to it is how this side learns that there is
;; room again. With the connection's lock.
(defun again (connection)
  (let ((card (connection-card connection)) (held (connection-out-held connection)) (*waits* nil))
    (cond ((> held 0)
           (let ((piece (min (connection-piece connection) held (max 1 (connection-theirs connection)))))
             (segment-out card (connection-from connection) (connection-to connection) (connection-port connection)
                          (connection-to-port connection) (connection-heard connection) (connection-expected connection)
                          24 (window connection) (connection-out connection) piece)
             (setf (connection-sent connection) (max (connection-sent connection) piece))))
          ((eq (connection-closing connection) :sent)
           (segment-out card (connection-from connection) (connection-to connection) (connection-port connection)
                        (connection-to-port connection) (connection-heard connection) (connection-expected connection)
                        17 (window connection))))
    (setf (connection-moment connection) (now))))

;; The other side says how far it has this side's bytes, ARRIVED, and how
;; many more it has room for. What it has is kept no longer, and more may
;; go out. BARE is whether the segment said nothing else: such a one that
;; says the same as the one before it, while something is on its way,
;; means that a later piece has arrived and an earlier one has not.
(defun heard-of (connection arrived theirs bare)
  (clara:with-lock-held ((connection-lock connection))
    (let* ((sent (connection-sent connection)) (held (connection-out-held connection))
           (end (if (eq (connection-closing connection) :sent) 1 0))
           (more (wrap (- arrived (connection-heard connection)))))
      (cond ((and (> more 0) (<= more (+ sent end)))
             (let ((bytes (min more held)))
               (when (> bytes 0)
                 (when (> held bytes)
                   (clara.unsafe:copy-memory (connection-out connection) (+ (connection-out connection) bytes) (- held bytes)))
                 (setf (connection-out-held connection) (- held bytes)
                       (connection-sent connection) (- sent bytes)))
               (setf (connection-heard connection) arrived
                     (connection-theirs connection) theirs
                     (connection-moment connection) (now)
                     (connection-wait connection) (connection-again connection)
                     (connection-same connection) 0
                     (connection-dares connection) (min *out-room* (+ (connection-dares connection) (connection-piece connection))))
               (cond ((> more bytes)
                      ;; the word that this side is done has arrived too
                      (setf (connection-closing connection) :heard
                            (connection-recover connection) nil)
                      (release-out connection))
                     ((and (connection-recover connection) (after (connection-recover connection) arrived))
                      ;; more than one piece was lost: the next one that is missing goes out without waiting
                      (again connection))
                     (t
                      (setf (connection-recover connection) nil)))
               (pump connection)))
            ((and (= more 0) bare (> sent 0) (= theirs (connection-theirs connection)))
             (setf (connection-same connection) (1+ (connection-same connection)))
             (when (= (connection-same connection) 3)
               (setf (connection-dares connection) (max (connection-piece connection) (floor (connection-dares connection) 2))
                     (connection-recover connection) (wrap (+ (connection-heard connection) sent)))
               (again connection)))
            ((= more 0)
             (setf (connection-theirs connection) theirs)
             (pump connection))))))

;; Nothing has been heard of what a connection has on its way for as long
;; as it waits for that: the first piece goes out again, this side dares
;; one piece, and waits twice as long the next time.
(defun overdue (connection time)
  (clara:with-lock-held ((connection-lock connection))
    (when (and (waiting connection) (>= (- time (connection-moment connection)) (connection-wait connection)))
      (setf (connection-wait connection) (min 60000 (* 2 (connection-wait connection)))
            (connection-dares connection) (connection-piece connection)
            (connection-recover connection) (wrap (+ (connection-heard connection) (connection-sent connection)))
            (connection-same connection) 0)
      (again connection)
      (pump connection))))

;; Whoever uses a connection lends it its patience: the thread that looks
;; after what the connection sends has another.
(defun lend (connection)
  (setf (connection-patience connection) *patience*
        (connection-again connection) *again*))

;; The error that a connection which is no longer open ends in, by what
;; became of it.
(defun gone (connection)
  (let ((to (address-text (connection-to connection))))
    (case (connection-state connection)
      (:overrun (error "~A sends more than the ~D bytes that were to be taken from it" to (connection-allowed connection)))
      (:silent (error "~A does not say that it has what it was sent" to))
      (t (error "~A has given the connection up" to)))))

;; A connection is no more: nothing that arrives finds it, and what it
;; still had to send is let go of. So is the memory of what arrived, when
;; nobody has taken the connection and that memory with it: one that
;; another machine began and did not go on with.
(defun forget (connection)
  (let ((card (connection-card connection)))
    (clara:with-lock-held ((card-book card))
      (when (member connection (card-connections card))
        ;; Its port rests: see NEXT-PORT.
        (setf (card-spoken card) (cons (cons (connection-port connection) (+ (now) +rest+)) (card-spoken card))))
      (setf (card-connections card) (remove connection (card-connections card))))
    (clara:with-lock-held ((connection-lock connection))
      (when (member (connection-state connection) '(:open :answered))
        (setf (connection-state connection) :closed))
      (when (and (connection-memory connection) (not (connection-frozen connection)))
        (setf (connection-frozen connection) t)
        (clara.unsafe:free-memory (connection-memory connection) (floor (connection-room connection) 4096))
        (setf (connection-memory connection) nil))
      (release-out connection))))

;; A segment has arrived for a connection.
(defun heard-segment (connection number arrived flags theirs longest data bytes)
  (let ((state (connection-state connection)))
    (setf (connection-alive connection) (now))
    (cond ((/= 0 (logand flags 4))
           ;; The other side gives the connection up. That is believed of a segment that could be the
           ;; other side's own: one that answers the beginning, or has the number that is expected next.
           (cond ((eq state :asked)
                  (when (and (/= 0 (logand flags 16)) (= arrived (wrap (1+ (connection-first connection)))))
                    (setf (connection-state connection) :refused)))
                 ((and (eq state :open) (= number (connection-expected connection)))
                  (if (connection-closing connection)
                      (forget connection)
                      (setf (connection-state connection) :broken)))
                 ((and (eq state :answered) (= number (connection-expected connection)))
                  (forget connection))))
          ((eq state :answered)
           ;; The other side began, and this side has answered. When the beginning comes once more, the
           ;; answer was lost, and goes out again. When the other side says that it has the answer, the
           ;; connection is open, a thread is started for it, and whatever else the segment says is
           ;; taken as on any connection that is open.
           (cond ((/= 0 (logand flags 2))
                  (when (= (wrap (1+ number)) (connection-expected connection))
                    (segment-out (connection-card connection) (connection-from connection) (connection-to connection)
                                 (connection-port connection) (connection-to-port connection)
                                 (connection-first connection) (connection-expected connection) 18 (window connection))))
                 ((and (/= 0 (logand flags 16)) (= arrived (wrap (1+ (connection-first connection)))))
                  (setf (connection-heard connection) arrived
                        (connection-theirs connection) theirs
                        (connection-state connection) :open)
                  (admit connection)
                  (heard-segment connection number arrived flags theirs nil data bytes))))
          ((eq state :asked)
           ;; the answer to the beginning: the other side begins too, and has ours
           (when (and (= (logand flags 18) 18) (= arrived (wrap (1+ (connection-first connection)))))
             (setf (connection-expected connection) (wrap (1+ number))
                   (connection-heard connection) arrived
                   (connection-theirs connection) theirs
                   ;; a side that does not say how long a piece it takes is sent what every network carries
                   (connection-piece connection) (max 64 (min (connection-piece connection)
                                                              (or longest (if (consp (connection-to connection)) 1220 536))))
                   (connection-state connection) :open)
             (acknowledge connection)))
          ((eq state :open)
           (when (/= 0 (logand flags 16))
             (heard-of connection arrived theirs (and (= bytes 0) (= 0 (logand flags 3)))))
           (cond ((and (> bytes 0) (connection-closing connection))
                  ;; nobody is left here to take it, and the other side is told so
                  (segment-out (connection-card connection) (connection-from connection) (connection-to connection)
                               (connection-port connection) (connection-to-port connection) (next connection) 0 4 0)
                  (forget connection))
                 (t
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
                      (acknowledge connection))
                    ;; both sides have said that they are done, and each has heard the other
                    (when (and (eq (connection-closing connection) :heard) (connection-ended connection))
                      (forget connection)))))))))

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
               (connection (find-connection card from from-port to-port)))
          (cond (connection
                 (heard-segment connection number arrived flags (two (+ at 14))
                                (and (/= 0 (logand flags 2)) (longest-piece at header)) (+ at header) carried))
                ((/= 0 (logand flags 4)))
                ((not (own-p card to)))
                ((and (= (logand flags 18) 2) (door-at to-port))
                 ;; a connection begins, at a port where connections are taken
                 (answer-beginning card (door-at to-port) from to from-port to-port number (two (+ at 14))
                                   (longest-piece at header)))
                ((/= 0 (logand flags 16))
                 (segment-out card to from to-port from-port arrived 0 4 0))
                (t
                 (segment-out card to from to-port from-port 0
                              (wrap (+ number carried (if (/= 0 (logand flags 3)) 1 0))) 20 0))))))))

;; A connection to a port of another machine, which may send a file of
;; LIMIT bytes over it, and MORE bytes around that. The beginning is said,
;; and said again after a second, after two more, after four more, until
;; the other side has answered it.
(defun begin (card to to-port limit &optional (more 65536))
  (let* ((first (fresh card)) (from (source-for card to)) (time (now))
         (connection (make-connection :card card :from from :to to :to-port to-port :port (next-port card)
                                      :state :asked :first first :heard first :piece (if (consp to) 1380 1400)
                                      :memory (clara.unsafe:allocate-memory 16) :room 65536
                                      :limit (+ limit more) :allowed limit
                                      :lock (clara:make-lock "connection")
                                      :patience *patience* :again *again* :wait *again* :moment time :alive time))
         (open nil))
    (clara:with-lock-held ((card-book card))
      (setf (card-connections card) (cons connection (card-connections card))))
    ;; the card's thread looks after this connection from now on, and is told so
    (clara:signal-event (clara.virtio:device-event (card-device card)))
    (unwind-protect
         (progn
           (ask-until card (lambda () (not (eq (connection-state connection) :asked)))
                      (lambda () (segment-out card from to (connection-port connection) to-port first 0 2 (window connection)))
                      (lambda () (format nil "~A does not answer at its port ~D" (address-text to) to-port))
                      t)
           (case (connection-state connection)
             (:open)
             (:unreachable (error "~A says that ~A cannot be reached" (address-text (connection-said connection)) (address-text to)))
             (t (error "~A takes no connection at its port ~D" (address-text to) to-port)))
           (setq open t)
           connection)
      (unless open
        (disconnect connection)))))

;; A connection to a port of the machine NAME: each of its addresses is
;; tried in turn, and the first that takes the connection has it. When
;; none does, the error is the one of the last.
(defun reach (card name port limit more)
  (let ((addresses (addresses-of name)))
    (loop
      (let ((address (car addresses)))
        (setq addresses (cdr addresses))
        (if addresses
            (let ((connection (ignore-errors (begin card address port limit more))))
              (when connection
                (return connection)))
            (return (begin card address port limit more)))))))

;; BYTES bytes of memory go over a connection: they are put behind what it
;; still has to send, as far as there is room for them, and the rest when
;; there is room again; and this waits until the other side has said that
;; it has them all, unless WHOLE says that it need not: then it returns
;; when the bytes are the connection's to send. On a connection that is no
;; longer open nothing more is said, and nothing is said about that here:
;; whoever waits for the answer finds out why, and has the better words
;; for it. Only that the other side does not take what it is sent is said
;; here, where it is found.
(defun say-bytes (connection memory bytes &optional (whole t))
  (let ((card (connection-card connection)) (done 0))
    (lend connection)
    ;; which card has the other side's address is asked now, where waiting for the answer is allowed
    (when (and (eq (connection-state connection) :open) (not (own-p card (connection-to connection))))
      (station-of card (connection-to connection)))
    (loop
      (case (connection-state connection)
        (:open)
        (:silent (gone connection))
        (t (return bytes)))
      (when (connection-closing connection)
        (return bytes))
      (let ((put (clara:with-lock-held ((connection-lock connection))
                   (let* ((held (connection-out-held connection)) (fits (min (- bytes done) (- *out-room* held))))
                     (when (> fits 0)
                       (unless (waiting connection)
                         (setf (connection-alive connection) (now)))
                       (make-way connection (+ held fits))
                       (clara.unsafe:copy-memory (+ (connection-out connection) held) (+ memory done) fits)
                       (setf (connection-out-held connection) (+ held fits))
                       (pump connection))
                     (max fits 0)))))
        (setq done (+ done put))
        (when (and (>= done bytes) (or (not whole) (= (connection-out-held connection) 0)))
          (return bytes)))
      (clara:wait-event (card-heard card) 50))))

;; What a connection has to say, as a text.
(defun say (connection text)
  (let ((bytes (clara.unsafe:string-bytes text)) (page (clara.unsafe:allocate-memory 1)))
    (when (> bytes 4096)
      (error "~D bytes are more than is said at once" bytes))
    (unwind-protect
         (progn
           (clara.unsafe:string-memory text page)
           (say-bytes connection page bytes))
      (clara.unsafe:free-memory page 1))))

;; How many bytes of what the other side says lie at the beginning of a
;; connection's memory: all that has arrived, or, on a connection that is
;; kept closed, what has been opened of it.
(defun said (connection)
  (if (connection-secure connection)
      (funcall (getf *secure* :held) (connection-secure connection))
      (connection-held connection)))

;; Wait until TEST is true of what has arrived, or the other side has sent
;; all that it will: T in the first case. An error when the connection is
;; no more, and when nothing has arrived for as long as *PATIENCE* is. On
;; a connection that is kept closed, what has arrived is opened before
;; TEST looks; whether the other side is done is looked at before that, so
;; that nothing arrives between the two looks and is taken for missing.
(defun wait-for (connection test)
  (let ((card (connection-card connection)) (held (connection-held connection)) (since (now))
        (secure (connection-secure connection)))
    (lend connection)
    (loop
      (let ((ended (connection-ended connection)))
        (when secure
          (funcall (getf *secure* :take) secure))
        (when (funcall test)
          (return t))
        (unless (eq (connection-state connection) :open)
          (gone connection))
        (when (or ended (and secure (funcall (getf *secure* :ended) secure)))
          (return nil)))
      (cond ((/= held (connection-held connection))
             (setq held (connection-held connection)
                   since (now)))
            ((> (- (now) since) *patience*)
             (error "~A has sent nothing for ~D seconds" (address-text (connection-to connection)) (floor *patience* 1000))))
      (clara:wait-event (card-heard card) 50))))

;; A connection is over for whoever had it. The memory of what arrived
;; goes back, unless KEEP says that somebody has it; either way nothing
;; more is put into it. The other side is told that nothing more comes,
;; behind whatever is still to be sent, when it is still there to be told:
;; the thread of the card sees to it that this arrives, takes the other
;; side's word that it is done as well, and then forgets the connection,
;; or forgets it when the other side has said nothing for too long.
;; Whatever arrives for a connection that is forgotten finds none, and is
;; answered so.
(defun disconnect (connection &optional keep)
  (let ((open (eq (connection-state connection) :open)))
    (clara:with-lock-held ((connection-lock connection))
      (setf (connection-frozen connection) t)
      (when (and (not keep) (connection-memory connection))
        (clara.unsafe:free-memory (connection-memory connection) (floor (connection-room connection) 4096))
        (setf (connection-memory connection) nil))
      (when (and open (null (connection-closing connection)))
        (unless (waiting connection)
          (setf (connection-alive connection) (now)))
        (setf (connection-closing connection) :asked)
        (ignore-errors (pump connection))))
    (unless open
      (forget connection))
    nil))

;; What time brings about for a connection, looked at by the thread of the
;; card. One that has something for the other side, of which the other
;; side has said nothing for as long as it is given, is no good: whoever
;; has it finds it silent, and one that nobody has any more is forgotten.
;; So is one that is done on both sides but for the other side's word,
;; when that does not come. And what is on its way too long goes out again.
(defun tend-connection (connection time)
  ;; a connection that another machine began and did not go on with is not kept for long
  (when (and (eq (connection-state connection) :answered)
             (> (- time (connection-alive connection)) (connection-patience connection)))
    (forget connection))
  (when (eq (connection-state connection) :open)
    (let ((quiet (> (- time (connection-alive connection)) (connection-patience connection))))
      (cond ((and quiet (waiting connection))
             (if (connection-closing connection)
                 (forget connection)
                 (setf (connection-state connection) :silent)))
            ((and quiet (eq (connection-closing connection) :heard))
             (forget connection))
            (t
             (overdue connection time))))))

;;; A connection as a stream

;; What has arrived on a connection lies at the front of its memory again,
;; without what was read of it. With the connection's lock.
(defun pack (connection)
  (let ((taken (connection-taken connection)) (memory (connection-memory connection))
        (filled (connection-held connection)))
    (when (> taken 0)
      (dolist (piece (connection-later connection))
        (setq filled (max filled (cdr piece))))
      (when (> filled taken)
        (clara.unsafe:copy-memory memory (+ memory taken) (- filled taken)))
      (setf (connection-held connection) (- (connection-held connection) taken)
            (connection-later connection) (mapcar (lambda (piece) (cons (- (car piece) taken) (- (cdr piece) taken)))
                                                  (connection-later connection))
            (connection-scanned connection) (max 0 (- (connection-scanned connection) taken))
            (connection-taken connection) 0))))

;; BYTES more bytes of it were read. The memory is put in order when all
;; of it was read, which costs nothing, and when a good deal was. With the
;; connection's lock.
(defun advance (connection bytes)
  (setf (connection-taken connection) (+ (connection-taken connection) bytes))
  (when (or (>= (connection-taken connection) (connection-held connection)) (>= (connection-taken connection) 16384))
    (pack connection)))

;; Where the line ends that begins where the last one was read to: the
;; place of the byte that ends it, as the bytes of the memory are counted,
;; or NIL when that byte has not arrived. How far the memory was looked
;; through is put down, so that no byte is looked at twice. With the
;; connection's lock.
(defun line-end (connection)
  (let ((memory (connection-memory connection)) (held (connection-held connection))
        (at (max (connection-scanned connection) (connection-taken connection))))
    (loop
      (when (>= at held)
        (setf (connection-scanned connection) at)
        (return nil))
      (when (= (clara.unsafe:memory-8 (+ memory at)) 10)
        (setf (connection-scanned connection) at)
        (return at))
      (setq at (1+ at)))))

;; The next BYTES bytes that were not read, as a text, without the byte 13
;; that the lines of the Internet's protocols have before their end; and
;; they are read, with SKIP bytes more. With the connection's lock.
(defun take-line (connection bytes skip)
  (let* ((from (+ (connection-memory connection) (connection-taken connection)))
         (length (if (and (> bytes 0) (= (clara.unsafe:memory-8 (+ from bytes -1)) 13)) (1- bytes) bytes))
         (line (if (= length 0) "" (ignore-errors (clara.unsafe:memory-string from length)))))
    (advance connection (+ bytes skip))
    (or line
        (error "~A sent a line that is no text: it is not UTF-8" (address-text (connection-to connection))))))

;; The next line that the other side has said, without its end; NIL when
;; the other side is done and has no more. What it said last without
;; ending the line is a line too. The wait is as long as patience is. When
;; reading makes room where there was next to none, the other side is
;; told, or it would wait for room for ever.
(defun next-line (connection)
  (let ((line nil))
    (flet ((look ()
             (let* ((room 0)
                    (found (clara:with-lock-held ((connection-lock connection))
                             (when (connection-memory connection)
                               (setq room (window connection))
                               (let ((end (line-end connection)))
                                 (cond (end
                                        (setq line (take-line connection (- end (connection-taken connection)) 1))
                                        t)
                                       ((> (window connection) 0)
                                        nil)
                                       ((> (connection-taken connection) 0)
                                        (pack connection)
                                        nil)
                                       (t
                                        (error "~A sent a line of more than ~D bytes, which is more than is kept of one"
                                               (address-text (connection-to connection)) (connection-limit connection)))))))))
               (when (and (< room 4096) (>= (window connection) 4096))
                 (ignore-errors (acknowledge connection)))
               found)))
      (unless (wait-for connection #'look)
        (clara:with-lock-held ((connection-lock connection))
          (when (connection-memory connection)
            (let ((rest (- (connection-held connection) (connection-taken connection))))
              (when (> rest 0)
                (setq line (take-line connection rest 0)))))))
      line)))

;; A text goes over a connection: it is the connection's to send when this
;; returns, and not yet the other side's. An error when the connection is
;; no more.
(defun write-text (connection text)
  (let* ((bytes (clara.unsafe:string-bytes text)) (pages (max 1 (floor (+ bytes 4095) 4096)))
         (memory (clara.unsafe:allocate-memory pages)))
    (unwind-protect
         (progn
           (clara.unsafe:string-memory text memory)
           (say-bytes connection memory bytes nil))
      (clara.unsafe:free-memory memory pages))
    (unless (eq (connection-state connection) :open)
      (gone connection))
    text))

;; A connection as a stream: what is written to it goes to the other side,
;; READ-LINE gives what the other side says, a line at a time, and CLOSE
;; says that this side is done.
(defun connection-stream (connection)
  (clara:make-stream :write-string (lambda (text) (write-text connection text))
                     :read-line (lambda () (next-line connection))
                     :close (lambda () (disconnect connection))))

(defun check-port (port)
  (unless (and (integerp port) (< 0 port 65536))
    (error "~S is no port: a port is a number from 1 to 65535" port))
  port)

;; A connection to a port of another machine, by its name or its address:
;; a stream. It is the caller's to close.
(defun connect (name port)
  (check-port port)
  (let ((card (up)))
    (connection-stream (reach card name port 65536 0))))

;; The same, for as long as BODY takes: the stream is closed whichever way
;; control leaves it.
(defmacro with-connection ((stream name port) &body body)
  `(let ((,stream (connect ,name ,port)))
     (unwind-protect (progn ,@body)
       (close ,stream))))

;;; A machine that listens

(defun door-at (port)
  (find-if (lambda (door) (= (door-port door) port)) *doors*))

;; The connections that came by a door and that somebody still has.
(defun door-open (card door)
  (remove-if-not (lambda (connection)
                   (and (eq (connection-door connection) door) (null (connection-closing connection))))
                 (card-connections card)))

;; From now on the machine takes the connections that other machines open
;; to PORT, as many at once as MOST says, and hands each to FUNCTION, a
;; function or the name of one, as a stream, in a thread of its own. The
;; connection is over when the function returns, or ends in an error,
;; which is kept for SERVING to show. The machine asks for its address
;; now, when it has none: there is no reaching a machine without one.
(defun serve (port function &key (most 8))
  (check-port port)
  (unless (or (functionp function) (and function (symbolp function)))
    (error "~S is no function, and no name of one, that a connection could be handed to" function))
  (unless (and (integerp most) (> most 0))
    (error "~S is no number of connections that could be taken at once" most))
  (up)
  (clara:with-lock-held (*doors-lock*)
    (when (door-at port)
      (error "connections are taken at the port ~D already: CLARA.NET:STOP-SERVING ends that" port))
    (setq *doors* (cons (make-door :port port :function function :most most) *doors*)))
  port)

;; No more connections are taken at PORT, and the ones that were are over:
;; their threads are stopped, which closes each. T when connections were
;; taken there.
(defun stop-serving (port)
  (let ((door (door-at port)) (card *card*))
    (when door
      (clara:with-lock-held (*doors-lock*)
        (setq *doors* (remove door *doors*)))
      (when card
        (dolist (connection (card-connections card))
          (when (eq (connection-door connection) door)
            (let ((thread (connection-thread connection)))
              (cond ((null thread)
                     (forget connection))
                    ((and (clara:thread-alive-p thread) (not (eq thread (clara:current-thread))))
                     (clara:destroy-thread thread)))))))
      t)))

;; Where connections are taken: for each port, (port taken open trouble),
;; how many were taken since SERVE, how many of them somebody has at the
;; moment, and what the function last ended in when that was an error.
(defun serving ()
  (let ((card *card*))
    (mapcar (lambda (door)
              (list (door-port door) (door-count door)
                    (if card (length (remove-if-not #'connection-thread (door-open card door))) 0)
                    (door-trouble door)))
            (sort (copy-list *doors*) #'< :key #'door-port))))

;; Another machine begins a connection at a port where connections are
;; taken. When as many are open there as may be, it is told that there is
;; none for it. Otherwise this side begins too, and waits for the other
;; side's word that it has heard that; until then nothing is kept for the
;; connection but its memory, and that not for long (TEND-CONNECTION).
(defun answer-beginning (card door from to from-port to-port number theirs longest)
  (if (>= (length (door-open card door)) (door-most door))
      (segment-out card to from to-port from-port 0 (wrap (1+ number)) 20 0)
      (let* ((first (fresh card)) (time (now))
             (connection (make-connection :card card :from to :to from :to-port from-port :port to-port
                                          :state :answered :door door :first first :heard first
                                          :expected (wrap (1+ number)) :theirs theirs
                                          :piece (max 64 (min (if (consp from) 1380 1400)
                                                              (or longest (if (consp from) 1220 536))))
                                          :memory (clara.unsafe:allocate-memory 16) :room 65536
                                          :limit 65536 :allowed 65536
                                          :lock (clara:make-lock "connection")
                                          :patience *patience* :again *again* :wait *again* :moment time :alive time)))
        (clara:with-lock-held ((card-book card))
          (setf (card-connections card) (cons connection (card-connections card))))
        (segment-out card to from to-port from-port first (connection-expected connection) 18 (window connection)))))

;; A connection that another machine began is open: a thread is started
;; that hands it to the function of its door, and closes it after that,
;; however the function ended.
(defun admit (connection)
  (let ((door (connection-door connection)) (stream (connection-stream connection)))
    (setf (door-count door) (1+ (door-count door)))
    (setf (connection-thread connection)
          (clara:make-thread (lambda ()
                               (unwind-protect
                                    (handler-case (funcall (door-function door) stream)
                                      (error (condition)
                                        (setf (door-trouble door) (princ-to-string condition))))
                                 (ignore-errors (close stream))))
                             :name (format nil "port ~D, for ~A" (door-port door)
                                           (address-text (connection-to connection)))))))

;;; HTTP: a file from another machine

;; Does an address begin with https://, which says that it is fetched over
;; a connection that is kept closed?
(defun secure-address-p (text)
  (and (stringp text) (> (length text) 8) (string-equal (subseq text 0 8) "https://")))

;; "http://host:port/path", taken apart: the host, the port, the path,
;; which is / when there is none, and whether it began with https://. The
;; port is 80 when none is written, and 443 for https://. An address of
;; IPv6 has colons of its own, and stands between brackets where a host is
;; written: "http://[fec0::2]:8000/" (RFC 3986, 3.2.2). The host is given
;; without them.
(defun parse-address (text)
  (let* ((secure (secure-address-p text))
         (begin (cond (secure 8)
                      ((and (> (length text) 7) (string-equal (subseq text 0 7) "http://")) 7)
                      (t (error "~A is no address that begins with http:// or https://" text))))
         (slash (length text)) (colon nil) (open nil) (close nil))
    (dotimes (i (- (length text) begin))
      (let ((character (char text (+ begin i))))
        (cond ((/= slash (length text)))
              ((char= character #\/)
               (setq slash (+ begin i)))
              ((and (char= character #\[) (= i 0))
               (setq open (+ begin i)))
              ((and (char= character #\]) open (null close))
               (setq close (+ begin i)))
              ((and (char= character #\:) (null colon) (or (null open) close))
               (setq colon (+ begin i))))))
    (let ((host (if open
                    (and close (= (1+ close) (or colon slash)) (text-six (subseq text (1+ open) close))
                         (subseq text (1+ open) close))
                    (subseq text begin (or colon slash))))
          (port (if colon (number-of (subseq text (1+ colon) slash)) (if secure 443 80)))
          (path (if (= slash (length text)) "/" (subseq text slash))))
      (unless (and host (> (length host) 0) port (< 0 port 65536))
        (error "~A names no machine, or no port of one" text))
      (values host port path secure))))

(defvar *line-end* (format nil "~A~A" (code-char 13) (code-char 10)))

;; Where the head of an answer ends, when all of it has arrived: after the
;; first empty line. NIL until then.
(defun head-end (connection from)
  (clara:with-lock-held ((connection-lock connection))
    (let ((memory (connection-memory connection)) (held (said connection)))
      (loop
        (when (> (+ from 4) held)
          (return nil))
        (when (and (= (one (+ memory from)) 13) (= (one (+ memory from 1)) 10)
                   (= (one (+ memory from 2)) 13) (= (one (+ memory from 3)) 10))
          (return (+ from 4)))
        (setq from (1+ from))))))

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

;; The file that an address names, fetched by HTTP, or by HTTPS when the
;; address begins that way: the memory that it is in, which is page frames,
;; how many bytes it is, and how many page frames that memory is, which
;; are the caller's to give back (CLARA.UNSAFE:FREE-MEMORY). A file of more
;; than LIMIT bytes is not taken. Where the other side says that the file
;; is to be had at another address, that one is asked, three times at
;; most; but never from an address that is kept closed at one that is not.
;; Three more values say what a browser wants to know: the address that
;; the file was had at in the end, the number that the other side answered
;; with, and the lines of the head of its answer. With ANY, whatever the
;; other side answers is taken as it is, with what it sent along as the
;; file: a page that is not there is a page all the same, and where the
;; other side says that the file is somewhere else, that is for the caller
;; to read from those lines and to follow.
(defun fetch (address &key (limit 16777216) any)
  (let ((moves 0))
    (loop
      (multiple-value-bind (host port path secure) (parse-address address)
        (when (and secure (null *secure*))
          (error "~A is to be had by HTTPS, and nothing in this system speaks it" address))
        (let* ((card (up))
               ;; A connection that is kept closed carries more than the file: a greeting of some
               ;; thousand bytes, and twenty-two bytes around every piece that the other side closes.
               (connection (reach card host port limit (if secure (+ 131072 (floor limit 8)) 65536)))
               (named (concatenate 'string (if (text-six host) (concatenate 'string "[" host "]") host)
                                   (if (= port (if secure 443 80)) "" (format nil ":~D" port))))
               (kept nil) (moved nil))
          (unwind-protect
               (progn
                 (when secure
                   (setf (connection-secure connection) (funcall (getf *secure* :open) connection host)))
                 (let ((request (concatenate 'string "GET " path " HTTP/1.1" *line-end*
                                             "Host: " named *line-end*
                                             "User-Agent: ClaraOS/" (lisp-implementation-version) *line-end*
                                             "Accept: */*" *line-end*
                                             "Connection: close" *line-end* *line-end*)))
                   (if secure
                       (funcall (getf *secure* :say) (connection-secure connection) request)
                       (say connection request)))
                 (let ((from 0) (end nil))
                   (wait-for connection
                             (lambda ()
                               (setq end (head-end connection from)
                                     from (max 0 (- (said connection) 3)))
                               (when (and (null end) (> (said connection) 16384))
                                 (error "~A answers with a head that does not end" host))
                               end))
                   (unless end
                     (error "~A ended the connection before it had answered" host))
                   (let* ((lines (head-lines (clara:with-lock-held ((connection-lock connection))
                                               (clara.unsafe:memory-string (connection-memory connection) end))))
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
                     (cond ((or any (= status 200))
                            (when (and length (> length limit))
                              (error "~A is ~D bytes, and more than ~D are not taken" address length limit))
                            (wait-for connection (lambda () (and length (>= (- (said connection) end) length))))
                            ;; A file that is over when the connection is has to have been ended by the other
                            ;; side, and not by somebody on the way: only a connection that is kept closed can
                            ;; tell the two apart, and it has to.
                            (when (and secure (null length) (not chunked)
                                       (not (funcall (getf *secure* :ended) (connection-secure connection))))
                              (error "~A ended the connection without saying that ~A was whole: what came of it may be cut short"
                                     host path))
                            (clara:with-lock-held ((connection-lock connection))
                              ;; from here on the memory is the caller's, and nothing more is put into it
                              (setf (connection-frozen connection) t)
                              (let ((memory (connection-memory connection)) (bytes (- (said connection) end)))
                                (when (and length (< bytes length))
                                  (error "~A ended the connection after ~D bytes of the ~D of ~A" host bytes length path))
                                (when (> bytes limit)
                                  (error "~A is more than ~D bytes, which are not taken" address limit))
                                (clara.unsafe:copy-memory memory (+ memory end) (or length bytes))
                                (when chunked
                                  (setq length (or (join-chunks memory bytes)
                                                   (error "~A sends ~A in chunks that do not come to an end" host path))))
                                (setq kept t)
                                (return (values memory (or length bytes) (floor (connection-room connection) 4096)
                                                address status (remove "" lines :test #'string=))))))
                           ((and (member status '(301 302 303 307 308)) place (> (length place) 0))
                            (when (>= moves 3)
                              (error "~A is said to be somewhere else more often than is followed" address))
                            (setq moved (if (char= (char place 0) #\/)
                                            (concatenate 'string (if secure "https://" "http://") named place)
                                            place))
                            (when (and secure (not (secure-address-p moved)))
                              (error "~A says that ~A is to be had at ~A, where nothing is kept closed: it is not fetched from there"
                                     host path moved)))
                           (t
                            (error "~A answers ~D to the request for ~A" host status path))))))
            (when (connection-secure connection)
              (funcall (getf *secure* :close) (connection-secure connection)))
            (disconnect connection kept))
          (setq address moved
                moves (1+ moves)))))))

;; The same, for a file that is a text: the text.
(defun fetch-text (address &key (limit 1048576))
  (multiple-value-bind (memory bytes pages) (fetch address :limit limit)
    (unwind-protect (clara.unsafe:memory-string memory bytes)
      (clara.unsafe:free-memory memory pages))))

;;; What arrives, and what time brings about

;; A frame has arrived: by its kind it is ARP's, IPv4's or IPv6's, and
;; anything else is nobody's here.
(defun frame-in (card at bytes)
  (when (>= bytes 14)
    (case (two (+ at 12))
      (#x0806 (arp-in card (+ at 14) (- bytes 14)))
      (#x0800 (packet-in card (+ at 14) (- bytes 14) (six (+ at 6))))
      (#x86dd (packet-six-in card (+ at 14) (- bytes 14) (six (+ at 6)))))))

;; What is done because time has passed, and not because something
;; arrived: the machine's address is asked for again before it runs out,
;; and every connection is looked at for what it has on its way. Nobody
;; waits for any of it, so what goes wrong there has nobody to be told:
;; it is kept, the last of it, where somebody who wonders can look
;; (CARD-TROUBLE).
(defun tend (card)
  (let ((time (now)))
    (handler-case (progn
                    (keep-address card time)
                    (keep-six card time))
      (error (condition)
        (setf (card-trouble card) (princ-to-string condition))))
    (dolist (connection (card-connections card))
      (handler-case (tend-connection connection time)
        (error (condition)
          (setf (card-trouble card) (princ-to-string condition)))))))

;; The thread of a card: whatever the card has put into the pages that it
;; was given is taken, twelve bytes of virtio's before each frame, and the
;; page given back to the card for the next one. Whoever waits for
;; something to arrive is told to look. A frame that cannot be made sense
;; of is counted and dropped: what is on a wire is anybody's to send. When
;; nothing arrives, the thread wakes all the same, to look at what time
;; has brought about: twenty times a second while there is a connection,
;; four times while the machine has an address that it has to keep, and
;; once a second otherwise. A machine that has nothing to do with its
;; network does next to nothing for it: where every call is a collection,
;; as in the boot that tries the collector, a dozen calls four times a
;; second were a good part of what that machine did. It never waits for
;; an answer, since it is the one that would have to take it.
(defun take (card)
  (let ((event (clara.virtio:device-event (card-device card))) (queue (card-receive card)) (*waits* nil)
        (soon nil) (often nil))
    (loop
      (clara:wait-event event (cond (soon 50) (often 250) (t 1000)))
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
        ;; and what this machine has sent to itself
        (when (card-inside card)
          (loop
            (let ((packet (clara:with-lock-held ((card-book card))
                            (let ((first (car (card-inside card))))
                              (setf (card-inside card) (cdr (card-inside card)))
                              first))))
              (unless packet
                (return))
              (setq any t)
              (unwind-protect
                   (handler-case (if (= (ash (one (car packet)) -4) 6)
                                     (packet-six-in card (car packet) (cdr packet) nil)
                                     (packet-in card (car packet) (cdr packet) nil))
                     (error ()
                       (setf (card-dropped card) (1+ (card-dropped card)))))
                (clara.unsafe:free-memory (car packet) 1)))))
        (setq soon (card-connections card)
              often (card-lease card))
        (tend card)
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
               :lock (clara:make-lock "network card") :book (clara:make-lock "network lists") :spare spare
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
                  (clara:make-thread (lambda () (take card))
                                     :name (concatenate 'string "network " (clara.pci:location pci))))
            (setq *card* card)
            (format t "net: ~A is a network card, ~A on the wire~%" (card-name card) (station-text (card-station card))))
        (error (condition)
          (format t "net: ~A did not start: ~A~%" (clara.pci:location pci) condition)))))
  (when (null *card*)
    (format t "net: no network card that has a driver here: nothing is fetched from another machine~%"))
  ;; A world that was saved while it took connections takes them again: the ports are the world's.
  ;; For that the machine needs its address, which is asked for at once, and not by the start itself.
  (when (and *card* *doors*)
    (let ((ports (mapcar (lambda (door) (format nil "~D" (door-port door))) (sort (copy-list *doors*) #'< :key #'door-port))))
      (format t "net: connections are taken at the port~A ~A, as before this start~%" (if (cdr ports) "s" "") (listed ports)))
    (clara:make-thread (lambda ()
                         (handler-case (up)
                           (error (condition)
                             (format t "net: ~A~%" condition))))
                       :name "network address"))
  *card*)
