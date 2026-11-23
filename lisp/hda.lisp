;;;; hda.lisp: Intel's sound card
;;;;
;;;; The sound card that most computers have had since 2004, and that UTM
;;;; gives a machine: what Intel calls High Definition Audio (the
;;;; specification of that name, revision 1.0a, 2010; the numbers of
;;;; chapters below are that document's). It is two things. A controller,
;;;; which is the PCI device: it takes numbers out of the machine's memory
;;;; at the pace of the sound and hands them on, along a wire that is called
;;;; the link. And at the other end of the link a codec, which makes the
;;;; movement of a loudspeaker of them: a small thing with an address on the
;;;; link, that is built of parts, each with a number, and wired together
;;;; inside in a way that it says when it is asked. One part takes the
;;;; numbers off the link, another is the socket that a loudspeaker is
;;;; plugged into, and between them there may be others that mix, choose
;;;; and make louder.
;;;;
;;;; The codec is spoken to in words of 32 bits (7.3): its address, the
;;;; number of the part, and what is asked or told. The driver writes such
;;;; words into a ring in memory, the controller sends them, and puts each
;;;; answer into a second ring (4.4.1).
;;;;
;;;; What is played lies in memory as a ring of periods, a hundredth of a
;;;; second each, which a list names for the controller (3.6.3). The
;;;; controller goes round that ring for as long as it runs, whatever is in
;;;; it, and says after each period that it is done with one. That is the
;;;; difference from virtio's card (lisp/sound.lisp), which plays what it is
;;;; handed and then waits: this one does not wait. So a period that was
;;;; played is made silent again, the driver writes a few periods ahead of
;;;; where the controller is, and a driver that comes too late is heard as
;;;; a gap, and never as what was played before, played again.
;;;;
;;;; This file is the card and nothing else: it finds the way through a
;;;; codec, opens the stream that plays, and says where the next period is
;;;; to be written. lisp/sound.lisp is what has something to play, and its
;;;; thread is the only one that calls anything here once the card is open.

(defpackage "CLARA.HDA"
  (:use "COMMON-LISP")
  (:export "HDA-P" "OPEN-CARD" "CARD-RATE" "CARD-EVENT" "RUN" "HALT" "ADVANCE" "UNDER-WAY" "NEXT-PERIOD" "HAND-OVER"))
(in-package "CLARA.HDA")

(defconstant +periods+ 32)  ; how many periods the ring has: a third of a second
(defconstant +margin+ 2)    ; how many periods ahead of the controller the nearest one is that is written to,
(defconstant +ahead+ 3)     ; and how many more than that the controller is given

(defvar *patience* 1000)    ; how many milliseconds the card may take over what it is asked

(defstruct card
  pci name
  base            ; the address of the controller's registers
  page            ; a page frame: the ring of words for the codec, the list of the periods, and the ring of answers
  words           ; how many words the first ring holds, and how many answers the second
  answers
  (said 0)        ; the place of the last word that was written,
  (heard 0)       ; and of the last answer that was read
  codec           ; the address of the codec on the link,
  parts           ; what it is built of: (number kind abilities) each
  way             ; the parts that the sound goes through, from the socket back to the one that takes it off the link
  rate            ; how many frames a second are played,
  bytes           ; and how many bytes a period is
  format          ; the same as the card writes it
  stream          ; the address of the registers of the stream that plays (3.3.35),
  line            ; and which bit of the controller's interrupts is its own
  ring            ; the page frames of the periods, 2048 bytes apart
  sounding        ; which of them hold something else than silence
  (index 0)       ; the period that the controller was in when it was last asked,
  (played 0)      ; how many periods it has played since it was started,
  (written 0)     ; and how many it has been handed, with the ones that were passed over
  listening       ; whether it interrupts after each period
  event           ; what its interrupt signals
  quiet)          ; an event of the driver's own that nothing signals: to wait a while

;; Is a PCI device such a card? The class 4 with the subclass 3.
(defun hda-p (pci)
  (= (ash (clara.pci:device-kind pci) -8) #x0403))

;;; Registers
;;;
;;; The controller's registers (3.3) are of one, two and four bytes, and
;;; each is read and written as what it is.

(defun r8 (card offset) (clara.unsafe:memory-8 (+ (card-base card) offset)))
(defun r16 (card offset) (clara.unsafe:memory-16 (+ (card-base card) offset)))
(defun r32 (card offset) (clara.unsafe:memory-32 (+ (card-base card) offset)))
(defun w8 (card offset value) (setf (clara.unsafe:memory-8 (+ (card-base card) offset)) value))
(defun w16 (card offset value) (setf (clara.unsafe:memory-16 (+ (card-base card) offset)) value))
(defun w32 (card offset value) (setf (clara.unsafe:memory-32 (+ (card-base card) offset)) value))

(defun bit-p (value n)
  (/= 0 (logand value (ash 1 n))))

;; Wait until TEST is true, looking every hundredth of a second: T, or an
;; error that says in the words of WHAT what the card did not do.
(defun settle (card what test)
  (let ((waited 0))
    (loop
      (when (funcall test)
        (return t))
      (when (>= waited *patience*)
        (error "the sound card ~A ~A in ~D milliseconds" (card-name card) what waited))
      (clara:wait-event (card-quiet card) 10)
      (setq waited (+ waited 10)))))

;;; Speaking to the codec
;;;
;;; The ring of words (CORB) and the ring of answers (RIRB) are in one
;;; page: words of four bytes from its start, answers of eight from its
;;; middle, each ring with a register that says where it is, a place that
;;; the writer has come to and one for the reader, and a switch. A ring has
;;; 256 places, or 16, or 2: the lowest two bits of the register of its
;;; size say which, and it is taken as the controller has it, since one
;;; word is under way at a time.

(defun ring-size (card offset)
  (case (logand (r8 card offset) 3) (0 2) (1 16) (t 256)))

(defun open-rings (card)
  (let ((page (card-page card)))
    (w8 card #x4c 0)
    (w8 card #x5c 0)
    (settle card "did not stop its rings" (lambda () (and (not (bit-p (r8 card #x4c) 1)) (not (bit-p (r8 card #x5c) 1)))))
    (setf (card-words card) (ring-size card #x4e)
          (card-answers card) (ring-size card #x5e))
    (w32 card #x40 (logand page #xffffffff))
    (w32 card #x44 (ash page -32))
    (w16 card #x48 0)
    ;; The reader's place in the ring of words is put back by bit 15, which is taken back again.
    (w16 card #x4a #x8000)
    (w16 card #x4a 0)
    (w32 card #x50 (logand (+ page 2048) #xffffffff))
    (w32 card #x54 (ash (+ page 2048) -32))
    (w16 card #x58 #x8000)
    ;; An answer is to be said after every word (the 1), which the status of the ring then holds
    ;; until it is taken back: nothing here is interrupted for it, and ASK looks.
    (w16 card #x5a 1)
    (setf (card-said card) 0
          (card-heard card) 0)
    (w8 card #x5c 3)
    (w8 card #x4c 2)))

;; Say a word to a part of the codec and wait for the answer: WORD is what
;; is asked or told, in twenty bits (7.3.3). The answer, 32 bits.
(defun ask (card part word)
  (let* ((page (card-page card))
         (place (mod (1+ (card-said card)) (card-words card)))
         (next (mod (1+ (card-heard card)) (card-answers card))))
    (setf (clara.unsafe:memory-32 (+ page (* 4 place))) (logior (ash (card-codec card) 28) (ash part 20) word))
    (setf (card-said card) place)
    (w16 card #x48 place)
    (settle card "did not answer for its codec" (lambda () (= (logand (r16 card #x58) 255) next)))
    (setf (card-heard card) next)
    (w8 card #x5d 5)
    (clara.unsafe:memory-32 (+ page 2048 (* 8 next)))))

;; What a part says of itself, by the number of the question (7.3.4).
(defun parameter (card part number)
  (ask card part (logior #xf0000 number)))

;;; The way through the codec
;;;
;;; The codec's part 0 says where its groups of parts begin and how many
;;; there are (the question 4), each group what it is for (5: 1 is sound),
;;; and the group of sound where its parts are. A part says in bits 20 to
;;; 23 of its abilities (9) what it is: 0 takes numbers off the link and
;;; makes sound of them, 4 is a socket, 2 and 3 mix and choose. A socket
;;; says whether it can give sound out (bit 4 of the question 12), and what
;;; is wired to it when the machine was built (the word #xf1c: nothing at
;;; all, when its top two bits are 01; a line out, a loudspeaker or
;;; headphones, when bits 20 to 23 are 0, 1 or 2). And every part that
;;; takes sound from others lists them (the question 14 for how many, the
;;; word #xf02 for four of them at a time).

(defun part-kind (part)
  (logand (ash (third part) -20) 15))

(defun find-part (card number)
  (find-if (lambda (part) (= (first part) number)) (card-parts card)))

;; The parts that a part takes its sound from, by their numbers.
(defun sources (card number)
  (let* ((count (parameter card number 14)) (found nil))
    (unless (bit-p count 7)
      (dotimes (i (logand count 127))
        (when (zerop (mod i 4))
          (let ((four (ask card number (logior #xf0200 i))))
            (dotimes (k 4)
              (when (< (+ i k) (logand count 127))
                (setq found (cons (logand (ash four (* -8 k)) 127) found))))))))
    (reverse found)))

;; The way from a part to one that takes numbers off the link, through at
;; most four others: the parts in that order, each with the place that the
;; next has among its sources. NIL when there is none.
(defun way-from (card number depth)
  (let ((part (find-part card number)))
    (cond ((null part) nil)
          ((= (part-kind part) 0) (list (list number 0)))
          ((zerop depth) nil)
          (t (let ((place 0))
               (dolist (source (sources card number) nil)
                 (let ((rest (way-from card source (1- depth))))
                   (when rest
                     (return (cons (list number place) rest))))
                 (setq place (1+ place))))))))

;; Find the codec and the way through it: the first codec on the link that
;; has a socket for sound to go out by which leads to a part that takes
;; numbers off the link.
(defun find-way (card present)
  (dotimes (address 15)
    (when (bit-p present address)
      (setf (card-codec card) address)
      (let ((groups (parameter card 0 4)))
        (dotimes (g (logand groups 255))
          (let ((group (+ (logand (ash groups -16) 255) g)))
            (when (= (logand (parameter card group 5) 255) 1)
              (let ((parts (parameter card group 4)) (found nil))
                (dotimes (p (logand parts 255))
                  (let ((number (+ (logand (ash parts -16) 255) p)))
                    (setq found (cons (list number group (parameter card number 9)) found))))
                (setf (card-parts card) (reverse found))
                (dolist (part (card-parts card))
                  (when (and (= (part-kind part) 4)
                             (bit-p (parameter card (first part) 12) 4))
                    (let ((wired (ask card (first part) #xf1c00)))
                      (when (and (/= (ash wired -30) 1) (<= (logand (ash wired -20) 15) 2))
                        (let ((way (way-from card (first part) 4)))
                          (when way
                            (setf (card-way card) way)
                            (return-from find-way card)))))))))))))
    (setf (card-parts card) nil))
  (error "the sound card ~A has no codec with a socket that plays" (card-name card)))

;; How far a part's amplifier is turned for a sound to pass as it is, of
;; the steps that it has (the question 18 for the one behind the part, 13
;; for the ones before it), or NIL when it has none. A part that says
;; nothing of its own (bit 3 of its abilities) has its group's.
(defun level (card part question)
  (let* ((own (bit-p (third part) 3))
         (able (parameter card (if own (first part) (second part)) question)))
    (logand able 127)))

;; Set the way up: every part on it is switched on (the word #x705), its
;; amplifiers are turned to where a sound passes as it is, on both sides
;; and not muted (#x3, 7.3.3.7: bit 15 for the one behind a part, bit 14
;; for the one before, with the place of the source in bits 8 to 11), a
;; part that chooses is told which source (#x701), the socket is told to
;; give sound out (#x707, bit 6), and the part at the end is told what
;; numbers it will be given and under which name on the link they come
;; (#x2, #x706): the name is the number 1 here, and the first side of it.
(defun set-way (card)
  (let ((way (card-way card)))
    (ask card (second (find-part card (first (car way)))) #x70500)
    (dolist (step way)
      (let* ((number (first step)) (part (find-part card number)) (kind (part-kind part)))
        (ask card number #x70500)
        (when (bit-p (third part) 2)
          (ask card number (logior #x3b000 (level card part 18))))
        (when (and (bit-p (third part) 1) (/= kind 0))
          (ask card number (logior #x37000 (ash (second step) 8) (level card part 13))))
        (when (= kind 3)
          (ask card number (logior #x70100 (second step))))
        (when (= kind 4)
          (ask card number #x70740))
        (when (= kind 0)
          (ask card number (logior #x20000 (card-format card)))
          (ask card number #x70610))))))

;; What the part at the end of the way can take: the question 10 says in
;; bit 17 that it takes numbers of 16 bits, in bit 6 that it takes 48000
;; frames a second and in bit 5 that it takes 44100; a part that says
;; nothing of its own (bit 4 of its abilities) has its group's answer. A
;; card is told what it is given in one word (3.7.1): the sides less one,
;; 16 bits in bit 4, and bit 14 for the slower of the two paces.
(defun find-format (card)
  (let* ((part (find-part card (first (car (last (card-way card))))))
         (able (parameter card (if (bit-p (third part) 4) (first part) (second part)) 10)))
    (unless (and (bit-p able 17) (/= 0 (logand able 96)))
      (error "the sound card ~A does not play numbers of 16 bits, 48000 or 44100 times a second" (card-name card)))
    (setf (card-rate card) (if (bit-p able 6) 48000 44100)
          (card-format card) (if (bit-p able 6) #x0011 #x4011)
          (card-bytes card) (* 4 (floor (card-rate card) 100)))))

;;; Opening the card

;; Open the card: the controller is taken through its reset (bit 0 of the
;; register at 8, down and up again), the codecs on the link say that they
;; are there (a bit each at #x0e), the rings are opened, the way through a
;; codec is found and set up, and the stream that plays is given its
;; memory. The streams that play come after the ones that record: how many
;; of those there are is in bits 8 to 11 of the first register. The card,
;; which plays nothing yet.
(defun open-card (pci)
  (clara.pci:enable pci)
  (let ((card (make-card :pci pci :name (clara.pci:location pci)
                         :base (clara.pci:map-registers pci 0 0 4096)
                         :quiet (clara:make-event "sound")))
        (done nil))
    (w32 card 8 (logand (r32 card 8) #xfffffffe))
    (settle card "did not go into its reset" (lambda () (not (bit-p (r32 card 8) 0))))
    (w32 card 8 (logior (r32 card 8) 1))
    (settle card "did not come out of its reset" (lambda () (bit-p (r32 card 8) 0)))
    (settle card "found no codec on its link" (lambda () (/= 0 (logand (r16 card #x0e) #x7fff))))
    (let* ((able (r16 card 0)) (recording (logand (ash able -8) 15)))
      (when (zerop (logand (ash able -12) 15))
        (error "the sound card ~A has no stream that plays" (card-name card)))
      (setf (card-stream card) (+ #x80 (* #x20 recording))
            (card-line card) recording)
      ;; The interrupt comes before the memory: a card that has none to give is left with nothing.
      (setf (card-event card) (clara.pci:message-interrupt pci 0))
      (unwind-protect
           (progn
             (setf (card-page card) (clara.unsafe:allocate-memory 1))
             (unless (or (bit-p able 0) (< (+ (card-page card) 4096) #x100000000))
               (error "the sound card ~A cannot reach memory above four gigabytes" (card-name card)))
             (open-rings card)
             (find-way card (logand (r16 card #x0e) #x7fff))
             (find-format card)
             (set-way card)
             (setf (card-ring card) (clara.unsafe:allocate-memory (floor +periods+ 2))
                   (card-sounding card) (make-array +periods+ :initial-element nil))
             ;; The list of the periods (3.6.3), behind the ring of words: where each is, how long,
             ;; and in the last word bit 0, which has the controller say when it is done with it.
             (dotimes (i +periods+)
               (let ((entry (+ (card-page card) 1024 (* 16 i))) (period (+ (card-ring card) (* 2048 i))))
                 (setf (clara.unsafe:memory-32 entry) (logand period #xffffffff)
                       (clara.unsafe:memory-32 (+ entry 4)) (ash period -32)
                       (clara.unsafe:memory-32 (+ entry 8)) (card-bytes card)
                       (clara.unsafe:memory-32 (+ entry 12)) 1)))
             (setq done t))
        ;; A card that did not open is put back into its reset, where it reads no memory, and
        ;; what it was given is taken back.
        (unless done
          (w32 card 8 (logand (r32 card 8) #xfffffffe))
          (when (card-page card)
            (clara.unsafe:free-memory (card-page card) 1)))))
    card))

;;; The stream
;;;
;;; Its registers (3.3.35): a word of switches at 0, whose bit 0 resets
;;; the stream, bit 1 runs it and bit 2 lets it say when a period is done,
;;; with the stream's name on the link in bits 20 to 23 and, in its top
;;; byte, what has happened, bit 26 for a period that is done, which is
;;; taken back by writing it; at 4 how far into the ring the controller
;;; has come, in bytes; at 8 how long the ring is; at 12 the number of the
;;; last period; at 18 what the numbers are; at 24 where the list is.

(defun stream-at (card offset)
  (+ (card-stream card) offset))

;; Start playing from the beginning of the ring, in which there is nothing
;; but silence then.
(defun run (card)
  (let ((list (+ (card-page card) 1024)))
    (w32 card (stream-at card 0) 1)
    (settle card "did not reset its stream" (lambda () (bit-p (r32 card (stream-at card 0)) 0)))
    (w32 card (stream-at card 0) 0)
    (settle card "did not let go of its stream" (lambda () (not (bit-p (r32 card (stream-at card 0)) 0))))
    (w32 card (stream-at card 0) (logior (ash 1 20) #x1c000000))
    (w16 card (stream-at card 18) (card-format card))
    (w32 card (stream-at card 8) (* +periods+ (card-bytes card)))
    (w16 card (stream-at card 12) (1- +periods+))
    (w32 card (stream-at card 24) (logand list #xffffffff))
    (w32 card (stream-at card 28) (ash list -32))
    (setf (card-index card) 0
          (card-played card) 0
          (card-written card) 0)
    (w32 card (stream-at card 0) (logior (ash 1 20) 4 2))
    t))

;; The controller says after every period that it is done, or keeps that to
;; itself: bit 31 of the register at #x20 lets it interrupt at all, and
;; the stream's own bit lets it interrupt for the stream.
(defun say-periods (card on)
  (unless (eq on (card-listening card))
    (w32 card #x20 (if on (logior #x80000000 (ash 1 (card-line card))) 0))
    (setf (card-listening card) on)))

;; Stop playing. The ring holds nothing but silence then, when the card
;; has played all that it was handed, which is when a card is stopped that
;; will be started again.
(defun halt (card)
  (say-periods card nil)
  (w32 card (stream-at card 0) (ash 1 20))
  (settle card "did not stop its stream" (lambda () (not (bit-p (r32 card (stream-at card 0)) 1))))
  t)

;; How many periods the controller has played since it was last asked.
;; Each of them is made silent again, so that it is silence when the
;; controller comes round to it once more; and with nothing left that it
;; was handed, the controller is told to say no more until it is handed
;; something. One that was not looked at for longer than the ring takes to
;; go round has been round more often than this counts, which changes
;; nothing but the count.
(defun advance (card)
  (let* ((switches (r32 card (stream-at card 0)))
         (index (mod (floor (r32 card (stream-at card 4)) (card-bytes card)) +periods+))
         (count (mod (- index (card-index card)) +periods+)))
    (when (/= 0 (logand switches #x1c000000))
      (w32 card (stream-at card 0) switches))
    (dotimes (i count)
      (let ((entry (mod (+ (card-index card) i) +periods+)))
        (when (svref (card-sounding card) entry)
          (clara.unsafe:fill-memory-32 (+ (card-ring card) (* 2048 entry)) 512 0)
          (setf (svref (card-sounding card) entry) nil))))
    (setf (card-index card) index
          (card-played card) (+ (card-played card) count))
    (when (<= (card-written card) (card-played card))
      (say-periods card nil))
    count))

;; How many periods the controller has been handed and not yet played, the
;; silent ones that it has to pass first among them.
(defun under-way (card)
  (max 0 (- (card-written card) (card-played card))))

;; Where the next period is to be written, or NIL when the controller has
;; all that it is given ahead. The period that it is playing and the one
;; after it are left alone, which may have been begun by the time the
;; writing is done: a driver that fell behind goes on past them.
(defun next-period (card)
  (when (< (card-written card) (+ (card-played card) +margin+))
    (setf (card-written card) (+ (card-played card) +margin+)))
  (when (< (- (card-written card) (card-played card)) (+ +margin+ +ahead+))
    (+ (card-ring card) (* 2048 (mod (card-written card) +periods+)))))

;; The period at the place that NEXT-PERIOD gave is written, and the
;; controller's to play.
(defun hand-over (card)
  (setf (svref (card-sounding card) (mod (card-written card) +periods+)) t
        (card-written card) (1+ (card-written card)))
  (say-periods card t)
  t)
