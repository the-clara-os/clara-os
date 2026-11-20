;;;; random.lisp: numbers that nobody can guess
;;;;
;;;; A machine that computes makes the same numbers every time it is given
;;;; the same beginning, and a machine that was just started has had much
;;;; the same beginning as the last time. Whoever wants a number that
;;;; nobody else can work out, a key that a connection is closed with, has
;;;; to get it from outside the computing. Virtio has a device for that
;;;; (Virtual I/O Device specification 1.2, 5.4, the entropy device): the
;;;; driver hands it memory, and the device fills it with bytes from
;;;; wherever the host gets its own, which under QEMU is the host's
;;;; generator of random numbers. `tools/run.sh` gives every machine one.
;;;;
;;;; The bytes are used as they come. Nothing is kept of them, and nothing
;;;; is made of them by a rule: a world that was saved and comes back
;;;; twice would otherwise make the same numbers twice.
;;;;
;;;; A machine without such a device has no numbers of this kind, and what
;;;; needs them says so: lisp/tls.lisp does, and fetches nothing by HTTPS.

(defpackage "CLARA.RANDOM"
  (:use "COMMON-LISP")
  (:export "START" "BYTES" "BELOW" "*PATIENCE*"))
(in-package "CLARA.RANDOM")

(defstruct source
  device queue
  name        ; where it is on the PCI bus
  lock        ; for the one request that is under way
  page        ; a page frame that the device writes into
  failed)     ; a request went unanswered: nothing more is asked of it

(defvar *source* nil)      ; the device that START found and opened, or NIL
(defvar *patience* 5000)   ; how many milliseconds the device may take over some bytes

;; COUNT bytes that nobody can guess, written at ADDRESS. The device is
;; handed a page frame, as often as it takes: it says how many bytes of it
;; it has filled, which may be fewer than it was given room for. The page
;; is wiped before the next one asks, so that the bytes lie in one place
;; only, the caller's. A wait ends every tenth of a second to look at the
;; queue, so an interrupt that got lost costs that much and no more.
(defun bytes (address count)
  (let ((source *source*))
    (unless source
      (error "this machine has no device that makes numbers which nobody can guess: a virtio RNG device is one"))
    (clara:with-lock-held ((source-lock source))
      (when (source-failed source)
        (error "the device ~A left a request unanswered, and is asked nothing more" (source-name source)))
      (let ((queue (source-queue source))
            (event (clara.virtio:device-event (source-device source)))
            (page (source-page source))
            (done 0) (empty 0))
        (loop
          (when (>= done count)
            (return count))
          (let ((wanted (min 4096 (- count done))) (waited 0) (written nil))
            (clara.virtio:queue-add queue (list (list page wanted t)) page)
            (clara.virtio:queue-notify queue)
            (loop
              (multiple-value-bind (token got) (clara.virtio:queue-take queue)
                (when token
                  (setq written got)
                  (return)))
              (unless (clara:wait-event event 100)
                (setq waited (+ waited 100))
                (when (>= waited *patience*)
                  (setf (source-failed source) t)
                  (error "the device ~A has made no numbers in ~D milliseconds" (source-name source) waited))))
            (unless (and (integerp written) (<= 0 written wanted))
              (setf (source-failed source) t)
              (error "the device ~A says that it wrote ~S bytes into the ~D that it was given" (source-name source) written wanted))
            (cond ((> written 0)
                   (clara.unsafe:copy-memory (+ address done) page written)
                   (dotimes (i written)
                     (setf (clara.unsafe:memory-8 (+ page i)) 0))
                   (setq done (+ done written)
                         empty 0))
                  ((>= empty 50)
                   (error "the device ~A goes on answering with no numbers at all" (source-name source)))
                  (t
                   (setq empty (1+ empty))))))))))

;; A number from 0 up to LIMIT, LIMIT itself not among them, and every one
;; as likely as any other: seven bytes are a number of fifty-six bits, and
;; one that falls in the last, uneven stretch of those is thrown away and
;; another taken, or the low numbers would come up a little more often.
(defun below (limit)
  (unless (and (integerp limit) (< 0 limit) (<= limit #x1000000000000))
    (error "~S is not a number above 0 and up to 281474976710656, below which a number could be taken" limit))
  (let ((page (clara.unsafe:allocate-memory 1)) (all #x100000000000000))
    (unwind-protect
         (loop
           (bytes page 7)
           (let ((number 0))
             (dotimes (i 7)
               (setq number (+ (* 256 number) (clara.unsafe:memory-8 (+ page i)))))
             (when (< number (* limit (floor all limit)))
               (return (mod number limit)))))
      (dotimes (i 8)
        (setf (clara.unsafe:memory-8 (+ page i)) 0))
      (clara.unsafe:free-memory page 1))))

;; Open a virtio entropy device: nothing of what such a device can do has
;; to be asked for, it has no registers of its own, and its one queue is
;; where the driver leaves memory to be filled (5.4.2).
(defun open-source (pci)
  (let* ((device (clara.virtio:open-device pci 0))
         (queue (clara.virtio:open-queue device 0 8))
         (source (make-source :device device :queue queue :name (clara.pci:location pci)
                              :lock (clara:make-lock "random")
                              :page (clara.unsafe:allocate-memory 1))))
    (clara.virtio:start-device device)
    source))

;; Find the device among the PCI devices, the first one that there is, and
;; say so. One that a world has kept from an earlier start is another
;; machine's.
(defun start ()
  (setq *source* nil)
  (dolist (pci (clara.pci:devices))
    (when (and (null *source*) (eql (clara.virtio:device-type pci) 4))
      (handler-case
          (progn
            (setq *source* (open-source pci))
            (format t "random: ~A makes numbers that nobody can guess~%" (source-name *source*)))
        (error (condition)
          (format t "random: ~A did not start: ~A~%" (clara.pci:location pci) condition)))))
  (when (null *source*)
    (format t "random: no device that makes numbers which nobody can guess: nothing is fetched by HTTPS~%"))
  *source*)
