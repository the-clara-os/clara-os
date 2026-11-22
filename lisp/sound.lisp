;;;; sound.lisp: what the machine plays
;;;;
;;;; Sound is numbers: how far the cone of a loudspeaker is pushed out or
;;;; drawn in, said 48000 times a second for the left side and for the
;;;; right. A sound card takes such numbers at that pace and makes the
;;;; movement of them. Virtio has one (Virtual I/O Device specification
;;;; 1.2, 5.14, the sound device), which under QEMU hands them to the
;;;; computer's own sound, and `tools/run.sh` gives every machine one.
;;;;
;;;; A frame is the two numbers of one instant, left and right, each of 16
;;;; bits with a sign. The card is given a period at a time, a hundredth of
;;;; a second of frames in a page frame, and gives the page back when it
;;;; has played it. A thread keeps it supplied: it adds up what every voice
;;;; that is sounding has to say for the next period, hands the period
;;;; over, and sleeps until the card has room again. With nothing to play
;;;; it sleeps until somebody plays something, and the card is told to stop.
;;;;
;;;; A voice is what one call of TONE, PLAY or PLAY-FILE asked for: notes
;;;; one after the other, or the sound that a file holds. A note is a wave
;;;; that goes round as often in a second as its pitch says, one of a few
;;;; shapes, each a table of 1024 numbers that is gone through at the pace
;;;; of the pitch; it begins and ends over a few thousandths of a second,
;;;; since a wave that is there at once, or gone at once, is heard as a
;;;; click. All of it is worked out in whole numbers, the language having
;;;; no others.
;;;;
;;;; A machine without a sound card plays nothing, and that is no error:
;;;; every function here then gives NIL and does nothing else, so that a
;;;; program which makes a sound when a key is pressed is the same program
;;;; on such a machine.

(defpackage "CLARA.SOUND"
  (:use "COMMON-LISP")
  (:export "START" "CARD" "TONE" "BEEP" "PLAY" "TOGETHER" "WAIT" "STOP" "PLAY-FILE" "*VOLUME*"))
(in-package "CLARA.SOUND")

(defstruct card
  device control out      ; the virtio device, its queue for requests and its queue for what is to be played
  name                    ; where it is on the PCI bus
  stream                  ; which of the device's streams is the one that plays
  rate                    ; how many frames a second that stream takes,
  frames                  ; and how many of them a period is: a hundredth of a second
  page                    ; a page frame for a request and its answer
  free                    ; the page frames of periods that the device does not have,
  (under-way 0)           ; and how many it has
  (silent 0)              ; for how many milliseconds it has given none back
  running                 ; the stream was told to start, and not yet to stop
  lock                    ; for what other threads change: the voices, and who waits
  voices                  ; what is being played
  tail                    ; the period that was handed over last had something in it: one more is to follow
  mix                     ; where a period is added up: two numbers to the frame
  rest                    ; signalled when there is nothing more to play, once for each that waits for that,
  (waiting 0)             ; and how many do
  thread
  failed)                 ; what went wrong with it, as words, when something has: it plays nothing more

(defvar *card* nil)        ; the card that START found and opened, or NIL
(defvar *volume* 100)      ; how loud the machine is, of 100
(defvar *patience* 5000)   ; how many milliseconds the card may take over a request, or over a period
(defvar *linger* 300)      ; how many milliseconds after the last sound the card is told to stop
(defvar *held* nil)        ; inside TOGETHER: a list whose first item is the voices that are to begin at one instant

;;; The requests
;;;
;;; A request is some words of 32 bits for the device to read, the first of
;;; them what is asked, and an answer for it to write, which begins with a
;;; word that says how it went (5.14.6): #x8000 that it went well, and
;;; three numbers after that for what went wrong.

(defun put-32 (card offset value)
  (setf (clara.unsafe:memory-32 (+ (card-page card) offset)) value))

(defun went (status)
  (case status
    (#x8001 "that the request is no request")
    (#x8002 "that it cannot do that")
    (#x8003 "that something went wrong on its side")
    (t (format nil "~D, which is no answer of such a card's" status))))

;; Ask the device what lies in the first BYTES bytes of the card's page,
;; and wait for its answer, ROOM bytes of the second half of the page. An
;; answer that is anything but "it went well" is an error, in the words of
;; WHAT, which says what was asked.
(defun request (card bytes room what)
  (let ((queue (card-control card)) (page (card-page card))
        (event (clara.virtio:device-event (card-device card))) (waited 0))
    (setf (clara.unsafe:memory-32 (+ page 2048)) 0)
    (clara.virtio:queue-add queue (list (list page bytes nil) (list (+ page 2048) room t)) page)
    (clara.virtio:queue-notify queue)
    (loop
      (when (clara.virtio:queue-take queue)
        (return))
      ;; A wait ends every tenth of a second to look at the queue, so an interrupt that got lost costs that.
      (unless (clara:wait-event event 100)
        (setq waited (+ waited 100))
        (when (>= waited *patience*)
          (error "the sound card ~A was asked ~A and has not answered in ~D milliseconds" (card-name card) what waited))))
    (let ((status (clara.unsafe:memory-32 (+ page 2048))))
      (unless (= status #x8000)
        (error "the sound card ~A was asked ~A and says ~A" (card-name card) what (went status))))))

;; A request about the stream that plays: what is asked, and which stream.
;; #x102 gets it ready, #x104 starts it, #x105 stops it (5.14.6.6).
(defun command (card code what)
  (put-32 card 0 code)
  (put-32 card 4 (card-stream card))
  (request card 8 4 what))

;;; Opening the card
;;;
;;; The device's own registers say how many streams it has (5.14.4), and it
;;; says of each, when it is asked, which way it goes and what it takes
;;; (5.14.6.6.2): 32 bytes, of which the words at 8 and 16 have a bit for
;;; every kind of number and for every pace it knows, the byte at 24 is 0
;;; for a stream that plays, and the two after that are the fewest and the
;;; most sides it has. What is wanted here is numbers of 16 bits with a
;;; sign, bit 5, on two sides, 48000 times a second, bit 7, or 44100 times
;;; when that is all it does, bit 6.

(defun find-stream (card)
  (let* ((streams (min 16 (clara.virtio:register-32 (card-device card) 4)))
         (answer (+ (card-page card) 2048 4)))
    (when (zerop streams)
      (error "the sound card has no streams"))
    (put-32 card 0 #x100)
    (put-32 card 4 0)
    (put-32 card 8 streams)
    (put-32 card 12 32)
    (request card 16 (+ 4 (* 32 streams)) "what its streams are")
    (dotimes (i streams)
      (let* ((at (+ answer (* 32 i)))
             (kinds (clara.unsafe:memory-32 (+ at 8)))
             (paces (clara.unsafe:memory-32 (+ at 16))))
        (when (and (zerop (clara.unsafe:memory-8 (+ at 24)))
                   (/= 0 (logand kinds 32))
                   (/= 0 (logand paces 192))
                   (<= (clara.unsafe:memory-8 (+ at 25)) 2 (clara.unsafe:memory-8 (+ at 26))))
          (setf (card-stream card) i
                (card-rate card) (if (/= 0 (logand paces 128)) 48000 44100))
          (return-from find-stream card))))
    (error "the sound card has no stream that plays numbers of 16 bits on two sides, 48000 or 44100 times a second")))

(defconstant +ahead+ 4)   ; how many periods the card is given before the first of them is played

;; Open a virtio sound device. Nothing of what such a device can do has to
;; be asked for. It has four queues (5.14.2): requests, what the device
;; has to tell by itself, which nothing here asks it to, what is to be
;; played, and what was recorded, which nothing here does. The stream is
;; told what it will be given (5.14.6.6.3): how many bytes the card may
;; hold and how many a period is, no extras, two sides, the kind of
;; number and the pace by the numbers of their bits; and is got ready.
(defun open-card (pci)
  (let* ((device (clara.virtio:open-device pci 0))
         (control (clara.virtio:open-queue device 0 16))
         (told (clara.virtio:open-queue device 1 16))
         (out (clara.virtio:open-queue device 2 16))
         (in (clara.virtio:open-queue device 3 16))
         (card (make-card :device device :control control :out out :name (clara.pci:location pci)
                          :page (clara.unsafe:allocate-memory 1)
                          :lock (clara:make-lock "sound") :rest (clara:make-event "quiet"))))
    (declare (ignorable told in))
    (clara.virtio:start-device device)
    (find-stream card)
    (let* ((frames (floor (card-rate card) 100)) (bytes (* 4 frames)))
      (setf (card-frames card) frames
            (card-mix card) (make-array (* 2 frames) :initial-element 0))
      (put-32 card 0 #x101)
      (put-32 card 4 (card-stream card))
      (put-32 card 8 (* +ahead+ bytes))
      (put-32 card 12 bytes)
      (put-32 card 16 0)
      (put-32 card 20 (+ 2 (* 256 5) (* 65536 (if (= (card-rate card) 48000) 7 6))))
      (request card 24 4 "to play 16 bits on two sides")
      (command card #x102 "to get ready"))
    (dotimes (i +ahead+)
      (setf (card-free card) (cons (clara.unsafe:allocate-memory 1) (card-free card))))
    card))

;;; Voices
;;;
;;; A voice of notes is a list of steps, the first of them under way. A
;;; step is how many frames it lasts and the waves that sound for that
;;; long, none for a rest. A wave is a vector: its table, how far it moves
;;; on in the table from one frame to the next, in whole places and in
;;; 1048576ths of a place, and where it is, likewise. A wave of noise has
;;; no table: it holds a number until it has gone round, and then takes
;;; the next one of a row that looks like chance and is none, so that the
;;; same noise is the same numbers every time.
;;;
;;; A voice of a file is the page frames that the file was read into, and
;;; where in them it is.

(defstruct voice
  steps (at 0)            ; what is still to come, and how many frames of the first step are done
  level                   ; how loud: 1024 is a wave from one end of 16 bits to the other
  left right              ; and how much of that each side gets, of 100
  memory pages            ; of a file: the page frames it is in,
  data                    ; where its frames begin,
  bytes sides             ; how many bytes one number has and how many sides a frame,
  count                   ; how many frames there are,
  (whole 0) (part 0)      ; where it is among them, in frames and 1048576ths,
  move-whole move-part)   ; and how far that moves on with each frame that is played

;; The four shapes of a wave, each as one turn in 1024 numbers from -32767
;; to 32767. The sine is worked out a quarter at a time by the series x -
;; x^3/6 + x^5/120 - ..., in numbers with 28 bits behind the point, of
;; which eight terms are right to the last of them; 843314857 is pi so
;; written.
(defun sine-table ()
  (let ((table (make-array 1024 :initial-element 0)))
    (dotimes (i 257)
      (let* ((x (floor (* 843314857 i) 512))
             (square (ash (* x x) -28))
             (term x) (sum x))
        (dotimes (n 8)
          (setq term (floor (ash (* term square) -28) (* (+ n n 2) (+ n n 3))))
          (setq sum (if (evenp n) (- sum term) (+ sum term))))
        (let ((value (ash (+ (* sum 32767) 134217728) -28)))
          (setf (svref table i) value
                (svref table (- 512 i)) value)
          (when (< 0 i 512)
            (setf (svref table (+ 512 i)) (- value)
                  (svref table (- 1024 i)) (- value))))))
    table))

(defun shape-table (shape)
  (let ((table (make-array 1024 :initial-element 0)))
    (dotimes (i 1024)
      (setf (svref table i) (funcall shape i)))
    table))

(defvar *waves*
  (list (cons :sine (sine-table))
        (cons :square (shape-table (lambda (i) (if (< i 512) 32767 -32767))))
        (cons :triangle (shape-table (lambda (i)
                                       (cond ((< i 256) (* 128 i))
                                             ((= i 256) 32767)
                                             ((< i 768) (* 128 (- 512 i)))
                                             ((= i 768) -32767)
                                             (t (* 128 (- i 1024)))))))
        (cons :sawtooth (shape-table (lambda (i) (* 32 (- (+ i i) 1023)))))
        (cons :noise nil)))

;; The next number of the row that noise is made of, from the one before:
;; times a number, plus another, and of that the lowest 31 bits (the rule
;; that C libraries have long had for rand). The upper 16 of them are the
;; wave's number.
(defun next-chance (seed)
  (logand (+ (* seed 1103515245) 12345) #x7fffffff))

(defun chance-value (seed)
  (- (ash seed -15) 32768))

;; A wave of a shape that goes round MILLIHERTZ thousandths of a time in a
;; second, on a card of RATE frames a second: 1024 places a turn, so it
;; moves on by 1024 times its pitch over the rate, to the nearest
;; 1048576th of a place.
(defun make-wave (shape millihertz rate)
  (let ((move (floor (+ (* millihertz 1073741824) (* 500 rate)) (* 1000 rate))))
    (vector (cdr (assoc shape *waves*)) (floor move 1048576) (mod move 1048576) 0 0 (chance-value 20261122) 20261122)))

;; Add COUNT frames of a wave to the period that is being put together,
;; from the frame AT of it on. The wave's number, times how far the note
;; is up (ENV, of 65536, which changes by SLOPE with every frame), times
;; how loud each side is to be (of 1024): what comes of that is 67108864
;; times too large, and MIX-PERIOD brings it back for all the voices at once.
;; This is where the time goes while something plays, so it calls nothing
;; but what the processor does by itself.
(defun render (mix at count wave env slope left right)
  (let ((table (svref wave 0))
        (move-whole (svref wave 1)) (move-part (svref wave 2))
        (whole (svref wave 3)) (part (svref wave 4))
        (i (+ at at)))
    (dotimes (n count)
      (let ((a (* (svref table whole) env)))
        (setf (svref mix i) (+ (svref mix i) (* a left)))
        (setf (svref mix (+ i 1)) (+ (svref mix (+ i 1)) (* a right))))
      (setq i (+ i 2)
            env (+ env slope)
            part (+ part move-part))
      (when (>= part 1048576)
        (setq part (- part 1048576)
              whole (+ whole 1)))
      (setq whole (+ whole move-whole))
      (when (>= whole 1024)
        (setq whole (- whole 1024))))
    (setf (svref wave 3) whole
          (svref wave 4) part)))

;; The same for noise: the number that it holds, and a new one whenever it
;; has gone round.
(defun render-noise (mix at count wave env slope left right)
  (let ((move-whole (svref wave 1)) (move-part (svref wave 2))
        (whole (svref wave 3)) (part (svref wave 4))
        (value (svref wave 5)) (seed (svref wave 6))
        (i (+ at at)))
    (dotimes (n count)
      (let ((a (* value env)))
        (setf (svref mix i) (+ (svref mix i) (* a left)))
        (setf (svref mix (+ i 1)) (+ (svref mix (+ i 1)) (* a right))))
      (setq i (+ i 2)
            env (+ env slope)
            part (+ part move-part))
      (when (>= part 1048576)
        (setq part (- part 1048576)
              whole (+ whole 1)))
      (setq whole (+ whole move-whole))
      (when (>= whole 1024)
        (setq whole (- whole 1024)
              seed (next-chance seed)
              value (chance-value seed))))
    (setf (svref wave 3) whole
          (svref wave 4) part
          (svref wave 5) value
          (svref wave 6) seed)))

;; Over how many frames a step of so many frames comes up, and over how
;; many it goes down again at its end: 256 and 512 when it is long enough,
;; some five and ten thousandths of a second, and otherwise the largest
;; halvings of those that leave it a quarter and a half of itself. They
;; are 1, 2, 4 and so on, so that the way up is a whole number of 65536ths
;; a frame.
(defun ramp (frames most)
  (let ((ramp most))
    (loop
      (when (or (<= ramp frames) (= ramp 0))
        (return ramp))
      (setq ramp (floor ramp 2)))))

;; What a voice of notes adds to a period of FRAMES frames: step after
;; step, each in up to three stretches, the way up, the level, and the way
;; down, until the period is full or the steps are over.
(defun sound-notes (voice mix frames left right)
  (let ((i 0))
    (loop
      (when (or (= i frames) (null (voice-steps voice)))
        (return))
      (let* ((step (car (voice-steps voice)))
             (length (car step))
             (at (voice-at voice))
             (up (ramp (floor length 4) 256))
             (down (ramp (floor length 2) 512))
             (env 65536) (slope 0) (end (- length down)))
        (cond ((< at up)
               (setq slope (floor 65536 up)
                     env (* at slope)
                     end up))
              ((>= at (- length down))
               (setq slope (- (floor 65536 down))
                     env (* (- length at) (floor 65536 down))
                     end length)))
        (let ((count (min (- frames i) (- end at))))
          (dolist (wave (cdr step))
            (if (svref wave 0)
                (render mix i count wave env slope left right)
                (render-noise mix i count wave env slope left right)))
          (setq i (+ i count)
                at (+ at count)))
        (if (= at length)
            (setf (voice-steps voice) (cdr (voice-steps voice))
                  (voice-at voice) 0)
            (setf (voice-at voice) at))))))

;; What a voice of a file adds: for every frame that is played the frame
;; of the file that it has come to, the nearest one before, both sides of
;; it or its one side for both. A number of 16 bits is read as it is, with
;; its sign; one of 8 bits is from 0 to 255 around 128.
(defun sound-file (voice mix frames left right)
  (let ((data (voice-data voice)) (bytes (voice-bytes voice)) (sides (voice-sides voice))
        (count (voice-count voice))
        (whole (voice-whole voice)) (part (voice-part voice))
        (move-whole (voice-move-whole voice)) (move-part (voice-move-part voice))
        (i 0))
    (loop
      (when (or (= i (+ frames frames)) (>= whole count))
        (return))
      (let* ((at (+ data (* whole bytes sides)))
             (one (if (= bytes 2)
                      (let ((value (clara.unsafe:memory-16 at)))
                        (if (>= value 32768) (- value 65536) value))
                      (* 256 (- (clara.unsafe:memory-8 at) 128))))
             (other (cond ((= sides 1) one)
                          ((= bytes 2)
                           (let ((value (clara.unsafe:memory-16 (+ at 2))))
                             (if (>= value 32768) (- value 65536) value)))
                          (t (* 256 (- (clara.unsafe:memory-8 (+ at 1)) 128))))))
        (setf (svref mix i) (+ (svref mix i) (* one 65536 left)))
        (setf (svref mix (+ i 1)) (+ (svref mix (+ i 1)) (* other 65536 right))))
      (setq i (+ i 2)
            part (+ part move-part))
      (when (>= part 1048576)
        (setq part (- part 1048576)
              whole (+ whole 1)))
      (setq whole (+ whole move-whole)))
    (setf (voice-whole voice) whole
          (voice-part voice) part)))

;; Has a voice said all that it had to say?
(defun over-p (voice)
  (if (voice-memory voice)
      (>= (voice-whole voice) (voice-count voice))
      (null (voice-steps voice))))

;; A voice that is no longer played gives back the memory of its file.
(defun discard (voice)
  (when (voice-memory voice)
    (clara.unsafe:free-memory (voice-memory voice) (voice-pages voice))
    (setf (voice-memory voice) nil
          (voice-count voice) 0)))

;; Let go of the voices that are over.
(defun prune (card)
  (let ((over nil))
    (dolist (voice (card-voices card))
      (when (over-p voice)
        (discard voice)
        (setq over t)))
    (when over
      (setf (card-voices card) (remove-if #'over-p (card-voices card))))))

;; How loud the machine is, of 100: what *VOLUME* says, as far as that is a
;; number from 0 to 100, and all of it otherwise.
(defun volume ()
  (let ((volume *volume*))
    (cond ((not (integerp volume)) 100)
          ((< volume 0) 0)
          ((> volume 100) 100)
          (t volume))))

;; Put a period together at ADDRESS, the next hundredth of a second of
;; every voice added up, and let go of the voices that are over with it.
;; A sum is brought back to 16 bits, to the nearest, and one that is past
;; either end of them stays at that end: too many voices at once are heard
;; as a rasp, and not as the howl of numbers that went round.
(defun mix-period (card address)
  (let ((mix (card-mix card)) (frames (card-frames card)) (volume (volume)))
    (dotimes (i (+ frames frames))
      (setf (svref mix i) 0))
    (dolist (voice (card-voices card))
      (let ((left (floor (* (voice-level voice) (voice-left voice) volume) 10000))
            (right (floor (* (voice-level voice) (voice-right voice) volume) 10000)))
        (if (voice-memory voice)
            (sound-file voice mix frames left right)
            (sound-notes voice mix frames left right))))
    (prune card)
    (dotimes (i (+ frames frames))
      (let ((value (ash (+ (svref mix i) 33554432) -26)))
        (setf (clara.unsafe:memory-16 (+ address i i))
              (cond ((> value 32767) 32767)
                    ((< value -32768) 32768)
                    ((< value 0) (+ value 65536))
                    (t value)))))))

;;; The thread of the card
;;;
;;; What is to be played goes to the card as a period in a page frame
;;; (5.14.6.8): a word that says which stream it is for, the frames, and at
;;; the end of the page eight bytes for the card to write how it went, the
;;; same numbers as for a request. The card gives a page back when it has
;;; played what is in it, or as much later as it likes.

;; Take back the periods that the card is done with.
(defun collect (card)
  (let ((taken nil))
    (loop
      (let ((page (clara.virtio:queue-take (card-out card))))
        (unless page
          (return))
        (let ((status (clara.unsafe:memory-32 (+ page 4088))))
          (unless (= status #x8000)
            (error "the sound card ~A was given a period to play and says ~A" (card-name card) (went status))))
        (setf (card-free card) (cons page (card-free card))
              (card-under-way card) (1- (card-under-way card)))
        (setq taken t)))
    taken))

;; Give the card periods for as long as it has room and there is something
;; to play. After a period that had something in it comes another, and
;; when no voice is left by then it is a period of nothing: a card that is
;; given no more may do as it likes with the last number that it had, and
;; this way that number is nothing.
(defun feed (card)
  (let ((bytes (* 4 (card-frames card))) (fed nil))
    (loop
      (when (or (null (card-free card))
                (and (null (card-voices card)) (not (card-tail card))))
        (return))
      (let ((page (car (card-free card))) (sounding (card-voices card)))
        (setf (card-free card) (cdr (card-free card)))
        (setf (clara.unsafe:memory-32 page) (card-stream card)
              (clara.unsafe:memory-32 (+ page 4088)) 0)
        (mix-period card (+ page 4))
        (setf (card-tail card) (and sounding t))
        (clara.virtio:queue-add (card-out card) (list (list page (+ 4 bytes) nil) (list (+ page 4088) 8 t)) page)
        (setf (card-under-way card) (1+ (card-under-way card)))
        (setq fed t)))
    (when fed
      (clara.virtio:queue-notify (card-out card)))))

;; Everybody who waits for it to be quiet is told that it is.
(defun tell-quiet (card)
  (when (> (card-waiting card) 0)
    (clara:signal-event (card-rest card) (card-waiting card))
    (setf (card-waiting card) 0)))

;; One look at the card, with its lock held. What comes back says how the
;; thread is to wait: for the card, which has periods to play; for a while,
;; after which the card is told to stop; or until somebody plays something.
(defun turn (card)
  (when (collect card)
    (setf (card-silent card) 0))
  ;; A voice can be over before a frame of it was played: one that was stopped, a file with nothing in it.
  (prune card)
  (when (and (card-voices card) (not (card-running card)))
    (command card #x104 "to start")
    (setf (card-running card) t))
  (feed card)
  (cond ((> (card-under-way card) 0) :playing)
        (t (tell-quiet card)
           (if (card-running card) :quiet nil))))

(defun serve (card)
  (let ((event (clara.virtio:device-event (card-device card))) (lock (card-lock card)))
    (handler-case
        (loop
          (case (clara:with-lock-held (lock) (turn card))
            (:playing
             ;; A wait ends every tenth of a second to look, so an interrupt that got lost is heard as
             ;; a gap of that length, and a card that gives nothing back at all is given up.
             (unless (clara:wait-event event 100)
               (clara:with-lock-held (lock)
                 (setf (card-silent card) (+ (card-silent card) 100))
                 (when (>= (card-silent card) *patience*)
                   (error "the sound card ~A has not played what it was given ~D milliseconds ago"
                          (card-name card) (card-silent card))))))
            (:quiet
             ;; What the card was given last is on its way to the loudspeaker for a moment yet, and one
             ;; sound is often followed by the next: the card is told to stop when it has been quiet
             ;; for a while, unless something was played in the instant in which the while was over.
             (unless (clara:wait-event event *linger*)
               (clara:with-lock-held (lock)
                 (when (null (card-voices card))
                   (command card #x105 "to stop")
                   (setf (card-running card) nil)))))
            (t
             (clara:wait-event event))))
      (error (condition)
        (clara:with-lock-held (lock)
          (setf (card-failed card) (princ-to-string condition))
          (dolist (voice (card-voices card))
            (discard voice))
          (setf (card-voices card) nil)
          (tell-quiet card))
        (format t "sound: ~A~%" condition)))))

;;; What a program says

;; Hand voices to the card, to begin at the same instant: T when it has
;; them. A card that already plays sixteen takes no more, and a card that
;; has failed takes none.
(defun begin (voices)
  (let ((card *card*) (taken nil))
    (when (and card voices)
      (clara:with-lock-held ((card-lock card))
        (when (and (null (card-failed card))
                   (<= (+ (length (card-voices card)) (length voices)) 16))
          (setf (card-voices card) (append (card-voices card) voices))
          (setq taken t)))
      (if taken
          (clara:signal-event (clara.virtio:device-event (card-device card)))
          (dolist (voice voices)
            (discard voice))))
    taken))

(defun add-voice (voice)
  (cond ((null *card*) nil)
        (*held* (setf (car *held*) (cons voice (car *held*)))
                t)
        (t (begin (list voice)))))

;; What was asked for of a voice: how loud, of 100, and where between the
;; two sides, from -100, all of it on the left, to 100.
(defun check-voice (volume pan)
  (unless (and (integerp volume) (<= 0 volume 100))
    (error "~S is not how loud a sound can be: that is a number from 0 to 100" volume))
  (unless (and (integerp pan) (<= -100 pan 100))
    (error "~S is not a place between the two sides: one is a number from -100, the left, to 100, the right" pan)))

(defun check-shape (shape)
  (unless (assoc shape *waves*)
    (error "~S is not the shape of a wave: one is :SINE, :SQUARE, :TRIANGLE, :SAWTOOTH or :NOISE" shape)))

;; How many frames a second what is played is worked out for: the card's,
;; and on a machine without one the pace that a card would most likely
;; have, so that what is wrong with a note is said there too.
(defun rate ()
  (if *card* (card-rate *card*) 48000))

;; The pitches of the twelve keys from a C to the B above it, in
;; thousandths of a time a second, for the highest octave that has a
;; number here, the eighth: from one key to the next it is the twelfth
;; root of two times as much, and the A is 7040, four octaves above the A
;; of 440 that an orchestra tunes to. An octave down is half of it.
(defvar *top* (vector 4186009 4434922 4698636 4978032 5274041 5587652 5919911 6271927 6644875 7040000 7458620 7902133))

;; How often a note goes round, in thousandths of a time a second, or NIL
;; for a rest. A note is a number, that many times a second, or a name: a
;; letter from A to G; then # or S for the key above it, or B for the key
;; below; then the octave, from 0 to 8, which is 4 when nothing is said,
;; the one that begins with the C in the middle of a piano. NIL and REST
;; are a rest.
(defun pitch-of (note)
  (cond ((null note) nil)
        ((integerp note)
         (unless (<= 20 note 20000)
           (error "~S is not a pitch that is played: as a number one is from 20 to 20000 times a second" note))
         (* 1000 note))
        ((or (symbolp note) (stringp note))
         (let* ((name (string-upcase (string note)))
                (length (length name))
                (key (and (> length 0)
                          (cdr (assoc (char name 0)
                                      '((#\C . 0) (#\D . 2) (#\E . 4) (#\F . 5) (#\G . 7) (#\A . 9) (#\B . 11))))))
                (octave 4) (at 1))
           (cond ((string= name "REST") nil)
                 (t
                  (when (and key (< at length))
                    (let ((mark (char name at)))
                      (cond ((or (char= mark #\#) (char= mark #\S))
                             (setq key (+ key 1)
                                   at (+ at 1)))
                            ((char= mark #\B)
                             (setq key (- key 1)
                                   at (+ at 1))))))
                  (when (and key (< at length))
                    (setq octave (- (char-code (char name at)) 48)
                          at (+ at 1)))
                  ;; The key below a C is the B of the octave before it, and the key above a B the next C.
                  (cond ((eql key -1)
                         (setq key 11
                               octave (- octave 1)))
                        ((eql key 12)
                         (setq key 0
                               octave (+ octave 1))))
                  (unless (and key (= at length) (<= 0 octave 8))
                    (error "~S is not a note: a note has a name like C4, F#3 or BB5, or is a number of times a second, or REST" note))
                  (let ((halves (ash 1 (- 8 octave))))
                    (floor (+ (svref *top* key) (floor halves 2)) halves))))))
        (t
         (error "~S is not a note: a note has a name like C4, F#3 or BB5, or is a number of times a second, or REST" note))))

;; The voice of some steps: how loud, of 100, and where between the two
;; sides. A wave from one end of 16 bits to the other is the loudest thing
;; that a card can play, and leaves no room for a second voice beside it:
;; at 100 a wave is a quarter of that.
(defun notes-voice (steps volume pan)
  (make-voice :steps steps :level (floor (* 256 volume) 100)
              :left (min 100 (- 100 pan)) :right (min 100 (+ 100 pan))))

;; A tone: one pitch, or a rest, for so many thousandths of a second. T
;; when the card has it to play.
(defun tone (pitch milliseconds &key (wave :sine) (volume 100) (pan 0))
  (check-voice volume pan)
  (check-shape wave)
  (unless (and (integerp milliseconds) (<= 1 milliseconds 60000))
    (error "~S is not how long a tone can be: that is from 1 to 60000 thousandths of a second" milliseconds))
  (let* ((rate (rate))
         (millihertz (pitch-of pitch))
         (frames (max 1 (floor (* rate milliseconds) 1000))))
    (add-voice (notes-voice (list (cons frames (and millihertz (list (make-wave wave millihertz rate)))))
                            volume pan))))

;; The sound that says "here", or "no".
(defun beep ()
  (tone 880 120))

;; One step of what PLAY is given: a note, or a list of the notes that
;; sound together, whose last item says how many steps they last when it
;; is a number and not the only item.
(defun step-of (item each shape rate)
  (let ((notes (if (listp item) item (list item))) (count 1) (waves nil))
    (when (and (consp item) (cdr item) (integerp (car (last item))))
      (setq count (car (last item))
            notes (reverse (cdr (reverse item))))
      (unless (<= 1 count 1000)
        (error "~S is not how many steps a note can last: that is from 1 to 1000" count)))
    (dolist (note notes)
      (let ((millihertz (pitch-of note)))
        (when millihertz
          (setq waves (cons (make-wave shape millihertz rate) waves)))))
    (when (> (length waves) 8)
      (error "~S is more than eight notes at once" item))
    (cons (* count each) (nreverse waves))))

;; Notes, one after the other, each for a step: TEMPO is how many steps
;; there are to the minute. It returns at once, T when the card has the
;; notes to play, and they are played while the program goes on.
(defun play (notes &key (tempo 120) (wave :sine) (volume 100) (pan 0))
  (check-voice volume pan)
  (check-shape wave)
  (unless (and (integerp tempo) (<= 1 tempo 6000))
    (error "~S is not a tempo: that is how many steps there are to the minute, from 1 to 6000" tempo))
  (unless (listp notes)
    (error "~S is not a list of notes" notes))
  (let* ((rate (rate))
         (each (floor (* rate 60) tempo))
         (steps (mapcar (lambda (item) (step-of item each wave rate)) notes)))
    (and steps (add-voice (notes-voice steps volume pan)))))

;; Whatever the forms inside play begins at the same instant, when the last
;; of them is done: two calls of PLAY one after the other begin as far
;; apart as the second took to be worked out, which is heard.
(defun call-together (function)
  (if *held*
      (funcall function)
      (let ((held (list nil)) (done nil))
        (unwind-protect
             (multiple-value-prog1 (let ((*held* held))
                                     (funcall function))
               (setq done t)
               (begin (reverse (car held))))
          (unless done
            (dolist (voice (car held))
              (discard voice)))))))

(defmacro together (&body body)
  `(call-together (lambda () ,@body)))

;; Wait until everything has been played that the card was given: T, or
;; NIL on a machine with no card.
(defun wait ()
  (let ((card *card*) (counted nil))
    (when card
      (loop
        (let ((quiet nil))
          (clara:with-lock-held ((card-lock card))
            (cond ((or (card-failed card) (not (eq card *card*))
                       (and (null (card-voices card)) (= (card-under-way card) 0)))
                   (setq quiet t))
                  ((not counted)
                   (setf (card-waiting card) (1+ (card-waiting card)))
                   (setq counted t))))
          (when quiet
            (return t)))
        (when (clara:wait-event (card-rest card) 1000)
          (setq counted nil))))))

;; Nothing more of what is being played. A note that is sounding is let
;; go of as at its end: it goes down over the next hundredth of a second,
;; and what was to follow it does not come. A file is cut off where it is.
;; What the card has been given already, a few hundredths of a second, is
;; heard before that.
(defun stop ()
  (let ((card *card*))
    (when card
      (clara:with-lock-held ((card-lock card))
        (dolist (voice (card-voices card))
          (if (voice-memory voice)
              (setf (voice-count voice) (voice-whole voice))
              (let ((step (car (voice-steps voice))) (at (voice-at voice)))
                (setf (voice-steps voice)
                      (and step (cdr step)
                           (list (cons (+ at (min 512 (- (car step) at))) (cdr step)))))))))
      (clara:signal-event (clara.virtio:device-event (card-device card)))
      t)))

;; What plays on this machine, in a line, or NIL when nothing does.
(defun card ()
  (let ((card *card*))
    (when card
      (if (card-failed card)
          (format nil "the sound card ~A, which plays nothing more: ~A" (card-name card) (card-failed card))
          (format nil "the sound card ~A: ~D frames a second, left and right" (card-name card) (card-rate card))))))

;;; Files
;;;
;;; A file of sound of the commonest kind, a WAVE file, is frames as they
;;; are, behind a few words about them (the Resource Interchange File
;;; Format of Microsoft and IBM, 1991). It begins with RIFF, its length and
;;; WAVE; then come pieces, each four letters, a length of four bytes, and
;;; that many bytes, with one more when the length is odd. The piece "fmt "
;;; says what the numbers are: at 0 their kind, 1 for plain numbers; at 2
;;; how many sides; at 4 how many frames a second; at 14 how many bits a
;;; number has. The kind #xfffe says that the kind is written further on,
;;; at 24. The piece "data" is the frames. Every number in a file has its
;;; lowest byte first.
;;;
;;; A file is somebody else's, so nothing in it is taken on trust: whatever
;;; is read of it is held against how long the file is.

(defun bytes-at (address count)
  (let ((value 0))
    (dotimes (i count)
      (setq value (+ (* 256 value) (clara.unsafe:memory-8 (+ address (- count i 1))))))
    value))

(defun letters-p (address letters)
  (dotimes (i 4 t)
    (unless (= (clara.unsafe:memory-8 (+ address i)) (char-code (char letters i)))
      (return nil))))

;; Read a file of sound into page frames, and make the voice of it: 8 or
;; 16 bits, one side or two, at any pace from 1000 to 192000 frames a
;; second, which is brought to the card's by going through the file's
;; frames faster or slower than the card takes them, by the file's pace
;; over the card's to the nearest 1048576th of a frame. Every piece of a
;; file begins at an even place, so a number of 16 bits does too.
(defun read-sound (name)
  (multiple-value-bind (memory size pages) (clara.fat:read-file name)
    (let ((voice nil))
      (unwind-protect
           (let ((at 12) (kind nil) (sides 0) (pace 0) (bits 0) (data nil) (length 0))
             (unless (and (>= size 12) (letters-p memory "RIFF") (letters-p (+ memory 8) "WAVE"))
               (error "~A is not a file of sound of the kind that is read here, a WAVE file" name))
             (loop
               (when (or data (> (+ at 8) size))
                 (return))
               (let ((bytes (bytes-at (+ memory at 4) 4)) (body (+ at 8)))
                 (cond ((letters-p (+ memory at) "fmt ")
                        (unless (and (>= bytes 16) (<= (+ body 16) size))
                          (error "~A is cut short where it says what its sound is" name))
                        (setq kind (bytes-at (+ memory body) 2)
                              sides (bytes-at (+ memory body 2) 2)
                              pace (bytes-at (+ memory body 4) 4)
                              bits (bytes-at (+ memory body 14) 2))
                        (when (and (= kind #xfffe) (>= bytes 26) (<= (+ body 26) size))
                          (setq kind (bytes-at (+ memory body 24) 2))))
                       ((letters-p (+ memory at) "data")
                        (setq data body
                              length (min bytes (- size body)))))
                 (setq at (+ body bytes (mod bytes 2)))))
             (unless (and kind data)
               (error "~A does not say what its sound is before the sound begins, or has none" name))
             (unless (= kind 1)
               (error "the sound in ~A is not plain numbers but packed in some way, which is not read here" name))
             (unless (and (<= 1 sides 2) (or (= bits 8) (= bits 16)) (<= 1000 pace 192000))
               (error "the sound in ~A has ~D sides, ~D bits to the number and ~D frames a second, and what is read here has 1 or 2, 8 or 16, and 1000 to 192000"
                      name sides bits pace))
             (let ((move (floor (+ (* pace 1048576) (floor (rate) 2)) (rate))) (bytes (floor bits 8)))
               (setq voice (make-voice :memory memory :pages pages :data (+ memory data) :bytes bytes :sides sides
                                       :count (floor length (* bytes sides))
                                       :move-whole (floor move 1048576) :move-part (mod move 1048576)))))
        (unless voice
          (clara.unsafe:free-memory memory pages)))
      voice)))

;; Play a file of sound: T when the card has it to play. The file is read
;; whole before the first of it is heard, and at 100 it is as loud as it
;; was made. On a machine without a card nothing is read.
(defun play-file (name &key (volume 100) (pan 0))
  (check-voice volume pan)
  (when *card*
    (let ((voice (read-sound name)))
      (setf (voice-level voice) (floor (* 1024 volume) 100)
            (voice-left voice) (min 100 (- 100 pan))
            (voice-right voice) (min 100 (+ 100 pan)))
      (add-voice voice))))

;; Find the sound card among the PCI devices, the first one that there is,
;; open it, and start the thread that keeps it supplied. A card that a
;; world has kept from an earlier start is another machine's, and so is
;; whatever it was playing.
(defun start ()
  (when (and *card* (card-thread *card*) (clara:thread-alive-p (card-thread *card*)))
    (clara:destroy-thread (card-thread *card*)))
  (setq *card* nil)
  (dolist (pci (clara.pci:devices))
    (when (and (null *card*) (eql (clara.virtio:device-type pci) 25))
      (handler-case
          (let ((card (open-card pci)))
            (setf (card-thread card) (clara:make-thread (lambda () (serve card)) :name "sound"))
            (setq *card* card)
            (format t "sound: ~A is a sound card: ~D frames a second, left and right~%" (card-name card) (card-rate card)))
        (error (condition)
          (format t "sound: ~A did not start: ~A~%" (clara.pci:location pci) condition)))))
  (when (null *card*)
    (format t "sound: no sound card that has a driver here: nothing is played~%"))
  *card*)
