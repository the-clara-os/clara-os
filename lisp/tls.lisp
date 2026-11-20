;;;; tls.lisp: a connection that is kept closed
;;;;
;;;; What goes over a connection of lisp/net.lisp can be read by whoever is
;;;; on the way, and changed. TLS is what two machines do about that (RFC
;;;; 8446, The Transport Layer Security Protocol Version 1.3; only that
;;;; version is spoken here, and nothing older). It has three parts, and so
;;;; has this file.
;;;;
;;;; Certificates. The other side shows who it is with a certificate: its
;;;; name, its key, and the signature of somebody who vouches for the two,
;;;; who has a certificate of the same kind, and so on up to one that this
;;;; system has had from the beginning (RFC 5280, Internet X.509 Public Key
;;;; Infrastructure Certificate). A certificate is read as it is written,
;;;; in the nested pieces of ASN.1's DER; its name is held against the
;;;; name that was asked for, its dates against the clock, and each
;;;; signature against the key above it. The ones that the system has from
;;;; the beginning are in the file roots.pem beside this one: the list
;;;; that Mozilla keeps for its browser, as curl publishes it. TRUST adds
;;;; to them.
;;;;
;;;; The greeting. The two sides agree on a secret that nobody who listens
;;;; can work out (X25519), make their keys of it and of everything they
;;;; have said so far (HKDF over SHA-256), and the other side shows that
;;;; the key in its certificate is its own by signing what was said. Each
;;;; ends with a word that only somebody with the keys can make of the
;;;; whole greeting, so that a greeting which was changed on the way ends
;;;; there.
;;;;
;;;; Records. From then on everything goes in records, each closed with
;;;; the key and a number that counts them (AES-128 in Galois/Counter
;;;; Mode), so that none can be read, changed, left out or sent twice.
;;;;
;;;; The arithmetic is the substrate's, in C: sums, HMAC, AES, X25519,
;;;; numbers to a power, and the signatures of two curves (CLARA.UNSAFE).
;;;; Everything that says what the bytes mean is here. The numbers that
;;;; nobody can guess are lisp/random.lisp's, and the time of day is the
;;;; firmware's clock (GET-UNIVERSAL-TIME).
;;;;
;;;; This side asks and does not serve, as in lisp/net.lisp: it has no
;;;; certificate of its own, comes back to no connection of an earlier
;;;; day, and sends nothing before the greeting is over.

(defpackage "CLARA.TLS"
  (:use "COMMON-LISP")
  (:export "START" "TRUST" "ROOTS"))
(in-package "CLARA.TLS")

;;; Numbers in memory, the highest byte first

(defun one (at)
  (clara.unsafe:memory-8 at))

(defun two (at)
  (+ (ash (clara.unsafe:memory-8 at) 8) (clara.unsafe:memory-8 (+ at 1))))

(defun three (at)
  (+ (ash (clara.unsafe:memory-8 at) 16) (two (+ at 1))))

(defun put-one (at value)
  (setf (clara.unsafe:memory-8 at) (logand value 255)))

(defun put-two (at value)
  (put-one at (ash value -8))
  (put-one (+ at 1) value))

(defun put-three (at value)
  (put-one at (ash value -16))
  (put-two (+ at 1) value))

(defun put-four (at value)
  (put-two at (ash value -16))
  (put-two (+ at 2) value))

;; A text of ASCII, written out: how many bytes that was.
(defun put-text (at text)
  (dotimes (i (length text) (length text))
    (put-one (+ at i) (char-code (char text i)))))

(defun clear (at bytes)
  (dotimes (i bytes)
    (setf (clara.unsafe:memory-8 (+ at i)) 0)))

(defun same-bytes (a b count)
  (dotimes (i count t)
    (unless (= (one (+ a i)) (one (+ b i)))
      (return nil))))

;; Are the COUNT bytes at AT the ones of the list?
(defun bytes-are (at count bytes)
  (and (= count (length bytes))
       (let ((i 0))
         (dolist (byte bytes t)
           (unless (= (one (+ at i)) byte)
             (return nil))
           (setq i (1+ i))))))

;; Does a text have another in it?
(defun holds (text part)
  (let ((last (- (length text) (length part))))
    (dotimes (i (max 0 (1+ last)) nil)
      (when (string= (subseq text i (+ i (length part))) part)
        (return t)))))

;;; What is refused, and what the other side is told about it
;;;
;;; An error on a connection is an error like any other, with one thing
;;; more: the other side is told a number that says what kind it was (RFC
;;; 8446, 6), by whoever opened the connection, once the error has come
;;; that far. NIL for an error that the other side is not told of, since it
;;; gave up first.

(defvar *alert* nil)

(defun refuse (alert control &rest arguments)
  (setq *alert* (or alert :none))
  (error "~A" (apply #'format nil control arguments)))

;; What the other side meant with the number that it gave up with.
(defun alert-text (number)
  (case number
    (10 "it did not expect what it was sent")
    (20 "what it was sent did not open with the key of the connection")
    (22 "it was sent a record that is too long")
    (40 "it found nothing in what this machine speaks that it speaks too")
    (42 "it does not like the certificate")
    (47 "something it was sent says what cannot be")
    (48 "it does not know who signed the certificate")
    (50 "it could not make sense of what it was sent")
    (51 "a signature, or the word at the end of the greeting, was not right")
    (70 "it does not speak TLS 1.3")
    (80 "something went wrong inside it")
    (109 "something that it wants was not in the greeting")
    (112 "it serves nobody of that name")
    (116 "it wants a certificate from this machine, which has none")
    (120 "it speaks no HTTP of the kind that was asked for")
    (t (format nil "the reason has the number ~D" number))))

;;; The time of day
;;;
;;; A day is counted as kernel/timer.c counts it, from the first of March
;;; of a year that can be divided by 400, and a time is seconds since 1900
;;; began in Greenwich, which is what GET-UNIVERSAL-TIME gives.

(defun day-number (year month day)
  (let* ((year (if (<= month 2) (1- year) year))
         (month (if (> month 2) (- month 3) (+ month 9)))
         (era (floor year 400))
         (of-era (- year (* era 400))))
    (+ (* era 146097) (* of-era 365) (floor of-era 4) (- (floor of-era 100)) (floor (+ (* 153 month) 2) 5) day -1 -719468)))

(defun universal (year month day hour minute second)
  (+ (* (+ (day-number year month day) 25567) 86400) (* hour 3600) (* minute 60) second))

(defun two-digits (number)
  (if (< number 10) (format nil "0~D" number) (format nil "~D" number)))

;; A time as it is written: "2026-11-20 20:53", in Greenwich.
(defun date-text (time)
  (let* ((days (+ (- (floor time 86400) 25567) 719468))
         (seconds (mod time 86400))
         (era (floor days 146097))
         (of-era (- days (* era 146097)))
         (year-of-era (floor (- (+ of-era (floor of-era 36524)) (floor of-era 1460) (floor of-era 146096)) 365))
         (of-year (- of-era (- (+ (* 365 year-of-era) (floor year-of-era 4)) (floor year-of-era 100))))
         (part (floor (+ (* 5 of-year) 2) 153))
         (day (1+ (- of-year (floor (+ (* 153 part) 2) 5))))
         (month (if (< part 10) (+ part 3) (- part 9)))
         (year (+ year-of-era (* era 400) (if (<= month 2) 1 0))))
    (format nil "~D-~A-~A ~A:~A" year (two-digits month) (two-digits day)
            (two-digits (floor seconds 3600)) (two-digits (mod (floor seconds 60) 60)))))

;;; Certificates, as they are written
;;;
;;; A certificate is pieces within pieces (ITU-T X.690, the Distinguished
;;; Encoding Rules): each piece is a byte that says what kind it is, its
;;; length, and that many bytes, which for some kinds are pieces again. A
;;; length below 128 is one byte; a longer one is a byte that says how many
;;; bytes the length takes, 128 more than that, and then those.

(defun wrong (what)
  (error "it is not written as a certificate is: ~A" what))

;; The piece that begins at AT, in something that ends before END: its
;; kind, where its bytes begin, how many they are, and where the piece
;; after it begins.
(defun piece (at end)
  (unless (<= (+ at 2) end)
    (wrong "it ends in the middle of a piece"))
  (let* ((kind (one at)) (first (one (+ at 1))) (inside (+ at 2)) (bytes first))
    (when (>= first 128)
      (let ((count (- first 128)))
        (unless (and (<= 1 count 3) (<= (+ inside count) end))
          (wrong "a piece has a length that is none"))
        (setq bytes 0)
        (dotimes (i count)
          (setq bytes (+ (* 256 bytes) (one (+ inside i)))))
        (setq inside (+ inside count))))
    (unless (<= (+ inside bytes) end)
      (wrong "a piece is longer than what it is in"))
    (values kind inside bytes (+ inside bytes))))

;; The same, for a piece that has to be of one kind: where its bytes begin,
;; how many, and where the next piece begins.
(defun piece-of (kind at end)
  (multiple-value-bind (found inside bytes next) (piece at end)
    (unless (= found kind)
      (wrong (format nil "a piece is of the kind ~D where one of the kind ~D belongs" found kind)))
    (values inside bytes next)))

(defstruct certificate
  at bytes                       ; where it lies in memory, and how long it is
  body body-bytes                ; the part of it that is signed
  signed                         ; how: (:rsa . 256), (:ecdsa . 384), the kind of signature and the bits of the sum; NIL for a way that is not known here
  signature signature-bytes
  issuer issuer-bytes            ; who signed it, by name, as the name is written
  subject subject-bytes          ; whom it is for, likewise
  name                           ; and as a text, for what is said about it
  from until                     ; the times between which it is good
  key                            ; the kind of its key: :RSA, or the bits of its curve, 256 or 384; NIL for a kind that is not known here
  modulus modulus-bytes exponent ; of a key of RSA's
  point                          ; of a key on a curve: where its x begins, with its y behind it
  authority                      ; it may sign certificates,
  depth                          ; and how many of those that sign in their turn may be below it, when it says
  usage                          ; what its key may be used for, as the bits of a byte; NIL when it does not say
  (serves t)                     ; it may be shown by a machine that serves, which it may when it does not say what it is for
  names addresses                ; the names it is for, and the addresses, as numbers
  unknown)                       ; something in it has to be understood by whoever takes it, and is not understood here

(defun number-at (at count)
  (let ((number 0))
    (dotimes (i count number)
      (let ((code (one (+ at i))))
        (unless (<= 48 code 57)
          (wrong "a date has something that is no digit"))
        (setq number (+ (* 10 number) (- code 48)))))))

;; A time, written as "261120205300Z", with the century left out, or with
;; it (RFC 5280, 4.1.2.5): the time, and where the next piece begins.
(defun read-time (at end)
  (multiple-value-bind (kind inside bytes next) (piece at end)
    (let ((year (cond ((and (= kind 23) (= bytes 13))
                       (let ((short (number-at inside 2)))
                         (setq inside (+ inside 2))
                         (+ short (if (< short 50) 2000 1900))))
                      ((and (= kind 24) (= bytes 15))
                       (let ((long (number-at inside 4)))
                         (setq inside (+ inside 4))
                         long))
                      (t (wrong "a date is not written as dates are")))))
      (let ((month (number-at inside 2)) (day (number-at (+ inside 2) 2)))
        (unless (and (= (one (+ inside 10)) 90) (<= 1 month 12) (<= 1 day 31))
          (wrong "a date is none, or is not Greenwich's"))
        (values (universal year month day (number-at (+ inside 4) 2) (number-at (+ inside 6) 2) (number-at (+ inside 8) 2))
                next)))))

(defun text-at (at bytes)
  (handler-case (clara.unsafe:memory-string at bytes)
    (error () nil)))

;; A name is a list of sets of pairs, each a kind and a text. What the name
;; is called for somebody to read: its common name, kind 2.5.4.3, or else
;; the organization, 2.5.4.10.
(defun name-text (at end)
  (let ((common nil) (other nil))
    (loop
      (when (>= at end)
        (return))
      (multiple-value-bind (set set-bytes next) (piece-of 49 at end)
        (let ((set-end (+ set set-bytes)))
          (loop
            (when (>= set set-end)
              (return))
            (multiple-value-bind (pair pair-bytes after) (piece-of 48 set set-end)
              (multiple-value-bind (kind kind-bytes value-at) (piece-of 6 pair (+ pair pair-bytes))
                (multiple-value-bind (written value value-bytes) (piece value-at (+ pair pair-bytes))
                  (let ((text (and (member written '(12 19 20 22)) (text-at value value-bytes))))
                    (cond ((and text (bytes-are kind kind-bytes '(#x55 4 3)))
                           (setq common text))
                          ((and text (null other) (bytes-are kind kind-bytes '(#x55 4 10)))
                           (setq other text))))))
              (setq set after))))
        (setq at next)))
    (or common other "a certificate without a name")))

;; How a certificate is signed, from the piece that says so: the kind of
;; signature and the bits of the sum that is signed. NIL for any other way.
(defun signing-way (at end)
  (multiple-value-bind (kind bytes) (piece-of 6 at end)
    (cond ((bytes-are kind bytes '(#x2a #x86 #x48 #x86 #xf7 #x0d 1 1 11)) '(:rsa . 256))
          ((bytes-are kind bytes '(#x2a #x86 #x48 #x86 #xf7 #x0d 1 1 12)) '(:rsa . 384))
          ((bytes-are kind bytes '(#x2a #x86 #x48 #x86 #xf7 #x0d 1 1 13)) '(:rsa . 512))
          ((bytes-are kind bytes '(#x2a #x86 #x48 #xce #x3d 4 3 2)) '(:ecdsa . 256))
          ((bytes-are kind bytes '(#x2a #x86 #x48 #xce #x3d 4 3 3)) '(:ecdsa . 384))
          ((bytes-are kind bytes '(#x2a #x86 #x48 #xce #x3d 4 3 4)) '(:ecdsa . 512)))))

;; The key of a certificate: of RSA's, a number of 2048 bits at least and
;; a small one; or a point on one of the two curves, written as a 4 and
;; its x and y. A key of any other kind is left unknown.
(defun read-key (certificate at end)
  (multiple-value-bind (algorithm algorithm-bytes next) (piece-of 48 at end)
    (multiple-value-bind (kind kind-bytes more) (piece-of 6 algorithm (+ algorithm algorithm-bytes))
      (multiple-value-bind (bits bits-bytes) (piece-of 3 next end)
        (unless (and (>= bits-bytes 1) (= (one bits) 0))
          (wrong "a key is no whole number of bytes"))
        (let ((key (1+ bits)) (key-bytes (1- bits-bytes)))
          (cond ((bytes-are kind kind-bytes '(#x2a #x86 #x48 #x86 #xf7 #x0d 1 1 1))
                 (multiple-value-bind (pair pair-bytes) (piece-of 48 key (+ key key-bytes))
                   (multiple-value-bind (modulus modulus-bytes after) (piece-of 2 pair (+ pair pair-bytes))
                     (multiple-value-bind (exponent exponent-bytes) (piece-of 2 after (+ pair pair-bytes))
                       (loop
                         (unless (and (> modulus-bytes 1) (= (one modulus) 0))
                           (return))
                         (setq modulus (1+ modulus)
                               modulus-bytes (1- modulus-bytes)))
                       (let ((number 0))
                         (when (<= exponent-bytes 5)
                           (dotimes (i exponent-bytes)
                             (setq number (+ (* 256 number) (one (+ exponent i)))))
                           (when (and (<= 256 modulus-bytes 512) (<= 3 number #xffffffff))
                             (setf (certificate-key certificate) :rsa
                                   (certificate-modulus certificate) modulus
                                   (certificate-modulus-bytes certificate) modulus-bytes
                                   (certificate-exponent certificate) number))))))))
                ((and (bytes-are kind kind-bytes '(#x2a #x86 #x48 #xce #x3d 2 1))
                      (< more (+ algorithm algorithm-bytes)) (= (one more) 6))
                 (multiple-value-bind (curve curve-bytes) (piece-of 6 more (+ algorithm algorithm-bytes))
                   (cond ((and (bytes-are curve curve-bytes '(#x2a #x86 #x48 #xce #x3d 3 1 7)) (= key-bytes 65) (= (one key) 4))
                          (setf (certificate-key certificate) 256
                                (certificate-point certificate) (1+ key)))
                         ((and (bytes-are curve curve-bytes '(#x2b #x81 4 0 #x22)) (= key-bytes 97) (= (one key) 4))
                          (setf (certificate-key certificate) 384
                                (certificate-point certificate) (1+ key))))))))))))

;; What a certificate says beyond its name and its key (RFC 5280, 4.2):
;; each is a kind, perhaps the word that it has to be understood, and its
;; bytes. Four are understood here: whether it may sign certificates
;; (2.5.29.19), what its key is for (2.5.29.15), the names it is for
;; (2.5.29.17), and what it may be shown for (2.5.29.37). Anything else
;; that has to be understood makes the certificate one that is not taken.
(defun read-more (certificate at end)
  (loop
    (when (>= at end)
      (return))
    (multiple-value-bind (item item-bytes next) (piece-of 48 at end)
      (let ((item-end (+ item item-bytes)) (must nil))
        (multiple-value-bind (kind kind-bytes after) (piece-of 6 item item-end)
          (when (and (< after item-end) (= (one after) 1))
            (multiple-value-bind (flag flag-bytes following) (piece-of 1 after item-end)
              (setq must (and (= flag-bytes 1) (/= (one flag) 0))
                    after following)))
          (multiple-value-bind (value value-bytes) (piece-of 4 after item-end)
            (let ((value-end (+ value value-bytes)))
              (cond ((bytes-are kind kind-bytes '(#x55 #x1d #x13))
                     (multiple-value-bind (inside bytes) (piece-of 48 value value-end)
                       (let ((inside-end (+ inside bytes)))
                         (when (and (< inside inside-end) (= (one inside) 1))
                           (multiple-value-bind (flag flag-bytes following) (piece-of 1 inside inside-end)
                             (setf (certificate-authority certificate) (and (= flag-bytes 1) (/= (one flag) 0)))
                             (setq inside following)))
                         (when (and (< inside inside-end) (= (one inside) 2))
                           (multiple-value-bind (number number-bytes) (piece-of 2 inside inside-end)
                             (setf (certificate-depth certificate)
                                   (if (= number-bytes 1) (one number) 255)))))))
                    ((bytes-are kind kind-bytes '(#x55 #x1d #x0f))
                     (multiple-value-bind (bits bits-bytes) (piece-of 3 value value-end)
                       (setf (certificate-usage certificate) (if (>= bits-bytes 2) (one (1+ bits)) 0))))
                    ((bytes-are kind kind-bytes '(#x55 #x1d #x11))
                     (multiple-value-bind (inside bytes) (piece-of 48 value value-end)
                       (let ((inside-end (+ inside bytes)))
                         (loop
                           (when (>= inside inside-end)
                             (return))
                           (multiple-value-bind (written name name-bytes following) (piece inside inside-end)
                             (cond ((= written #x82)
                                    (let ((text (text-at name name-bytes)))
                                      (when text
                                        (setf (certificate-names certificate)
                                              (append (certificate-names certificate) (list text))))))
                                   ((and (= written #x87) (= name-bytes 4))
                                    (setf (certificate-addresses certificate)
                                          (cons (+ (ash (two name) 16) (two (+ name 2))) (certificate-addresses certificate)))))
                             (setq inside following))))))
                    ((bytes-are kind kind-bytes '(#x55 #x1d #x25))
                     (multiple-value-bind (inside bytes) (piece-of 48 value value-end)
                       (let ((inside-end (+ inside bytes)) (serves nil))
                         (loop
                           (when (>= inside inside-end)
                             (return))
                           (multiple-value-bind (purpose purpose-bytes following) (piece-of 6 inside inside-end)
                             (when (or (bytes-are purpose purpose-bytes '(#x2b 6 1 5 5 7 3 1))
                                       (bytes-are purpose purpose-bytes '(#x55 #x1d #x25 0)))
                               (setq serves t))
                             (setq inside following)))
                         (setf (certificate-serves certificate) serves))))
                    (must
                     (setf (certificate-unknown certificate) t)))))))
      (setq at next))))

;; The part of a certificate that is signed: a version, when it is not the
;; first; a number; how it is signed, once more; who signed it; from when
;; to when it is good; whom it is for; the key; and, in a piece of the kind
;; 163, what else it says.
(defun read-body (certificate at end)
  (when (and (< at end) (= (one at) 160))
    (setq at (nth-value 3 (piece at end))))
  (setq at (nth-value 2 (piece-of 2 at end)))
  (setq at (nth-value 2 (piece-of 48 at end)))
  (multiple-value-bind (inside bytes next) (piece-of 48 at end)
    (declare (ignore inside bytes))
    (setf (certificate-issuer certificate) at
          (certificate-issuer-bytes certificate) (- next at))
    (setq at next))
  (multiple-value-bind (inside bytes next) (piece-of 48 at end)
    (multiple-value-bind (from until-at) (read-time inside (+ inside bytes))
      (setf (certificate-from certificate) from
            (certificate-until certificate) (read-time until-at (+ inside bytes))))
    (setq at next))
  (multiple-value-bind (inside bytes next) (piece-of 48 at end)
    (setf (certificate-subject certificate) at
          (certificate-subject-bytes certificate) (- next at)
          (certificate-name certificate) (name-text inside (+ inside bytes)))
    (setq at next))
  (multiple-value-bind (inside bytes next) (piece-of 48 at end)
    (read-key certificate inside (+ inside bytes))
    (setq at next))
  (loop
    (when (>= at end)
      (return))
    (multiple-value-bind (kind inside bytes next) (piece at end)
      (when (= kind 163)
        (multiple-value-bind (list list-bytes) (piece-of 48 inside (+ inside bytes))
          (read-more certificate list (+ list list-bytes))))
      (setq at next))))

;; The certificate that BYTES bytes of memory are: what is signed, how, and
;; the signature, which is a string of bits of which none is left over.
(defun read-certificate (at bytes)
  (let ((certificate (make-certificate :at at :bytes bytes)) (end (+ at bytes)))
    (multiple-value-bind (inside length after) (piece-of 48 at end)
      (unless (= after end)
        (wrong "something comes after it"))
      (let ((end (+ inside length)))
        (multiple-value-bind (body body-bytes next) (piece-of 48 inside end)
          (setf (certificate-body certificate) inside
                (certificate-body-bytes certificate) (- next inside))
          (read-body certificate body (+ body body-bytes))
          (multiple-value-bind (way way-bytes next) (piece-of 48 next end)
            (setf (certificate-signed certificate) (signing-way way (+ way way-bytes)))
            (multiple-value-bind (bits bits-bytes next) (piece-of 3 next end)
              (unless (and (>= bits-bytes 1) (= (one bits) 0) (= next end))
                (wrong "its signature is no whole number of bytes, or something comes after it"))
              (setf (certificate-signature certificate) (1+ bits)
                    (certificate-signature-bytes certificate) (1- bits-bytes)))))))
    certificate))

;;; Signatures
;;;
;;; WORK is memory for the checking: 3072 bytes, of which the first 64 are
;;; the sum of what is signed.

;; What a signature of RSA's has before the sum, which says which sum it is
;; (RFC 8017, 9.2, the notes): SHA-256, SHA-384 or SHA-512.
(defun sum-prefix (bits)
  (case bits
    (256 '(#x30 #x31 #x30 #x0d #x06 #x09 #x60 #x86 #x48 #x01 #x65 #x03 #x04 #x02 #x01 #x05 #x00 #x04 #x20))
    (384 '(#x30 #x41 #x30 #x0d #x06 #x09 #x60 #x86 #x48 #x01 #x65 #x03 #x04 #x02 #x02 #x05 #x00 #x04 #x30))
    (512 '(#x30 #x51 #x30 #x0d #x06 #x09 #x60 #x86 #x48 #x01 #x65 #x03 #x04 #x02 #x03 #x05 #x00 #x04 #x40))))

;; A signature of RSA's, of the older kind, which certificates have (RFC
;; 8017, 8.2.2): the signature to the power of the key's small number,
;; modulo its large one, has to be a 0, a 1, bytes of 255, eight at least,
;; a 0, the prefix, and the sum, and nothing else.
(defun rsa-good-p (owner bits size signature signature-bytes work)
  (let* ((length (certificate-modulus-bytes owner)) (prefix (sum-prefix bits))
         (filling (- length 3 (length prefix) size)) (made (+ work 64)))
    (and (= signature-bytes length)
         (>= filling 8)
         (clara.unsafe:power-mod signature signature-bytes (certificate-exponent owner) (certificate-modulus owner) length made)
         (= (one made) 0)
         (= (one (+ made 1)) 1)
         (dotimes (i filling t)
           (unless (= (one (+ made 2 i)) 255)
             (return nil)))
         (= (one (+ made 2 filling)) 0)
         (bytes-are (+ made 3 filling) (length prefix) prefix)
         (same-bytes (+ made 3 filling (length prefix)) work size))))

(defun bits-of (byte)
  (let ((bits 0))
    (loop
      (when (= byte 0)
        (return bits))
      (setq byte (ash byte -1)
            bits (1+ bits)))))

;; A signature of RSA's, of the newer kind, which is the one that ends a
;; greeting (RFC 8017, 8.1.2 and 9.1.2): the signature to the power is a
;; block that ends in 188, with a sum H before that and, before H, bytes
;; that were covered with a mask made of H. Uncovered, they are zeroes, a
;; 1, and a salt as long as the sum; and H has to be the sum of eight
;; zeroes, the sum of what was signed, and the salt. The block is a bit
;; shorter than the key's number, so its first bits are zero.
(defun pss-good-p (owner bits size signature signature-bytes work)
  (let* ((length (certificate-modulus-bytes owner))
         (top (bits-of (one (certificate-modulus owner))))
         (lead (if (= top 1) 1 0))
         (spare (if (= top 1) 0 (- 9 top)))
         (made (+ work 64)) (block-at (+ made lead)) (block-bytes (- length lead))
         (covered (- block-bytes size 1))
         (open (+ work 640)) (scratch (+ work 1280)))
    (and (= signature-bytes length)
         (>= block-bytes (+ size size 2))
         (clara.unsafe:power-mod signature signature-bytes (certificate-exponent owner) (certificate-modulus owner) length made)
         (or (= lead 0) (= (one made) 0))
         (= (one (+ block-at block-bytes -1)) 188)
         (= 0 (logand (one block-at) (- 256 (ash 1 (- 8 spare)))))
         (progn
           ;; the mask: the sums of H with a count behind it, one after another (appendix B.2.1)
           (clara.unsafe:copy-memory scratch (+ block-at covered) size)
           (let ((done 0) (count 0))
             (loop
               (when (>= done covered)
                 (return))
               (put-four (+ scratch size) count)
               (clara.unsafe:digest bits scratch (+ size 4) (+ scratch 128))
               (dotimes (i (min size (- covered done)))
                 (put-one (+ open done i) (logxor (one (+ block-at done i)) (one (+ scratch 128 i)))))
               (setq done (+ done size)
                     count (1+ count))))
           (put-one open (logand (one open) (1- (ash 1 (- 8 spare)))))
           (let ((zeroes (- covered size 1)))
             (and (dotimes (i zeroes t)
                    (unless (= (one (+ open i)) 0)
                      (return nil)))
                  (= (one (+ open zeroes)) 1)
                  (progn
                    (clear (+ scratch 256) 8)
                    (clara.unsafe:copy-memory (+ scratch 264) work size)
                    (clara.unsafe:copy-memory (+ scratch 264 size) (+ open zeroes 1) size)
                    (clara.unsafe:digest bits (+ scratch 256) (+ 8 size size) (+ scratch 128))
                    (same-bytes (+ scratch 128) (+ block-at covered) size))))))))

;; A signature on a curve is two numbers, written as two pieces in one
;; (RFC 5480, 2.2.3 has it from SEC 1). Neither is negative.
(defun ecdsa-good-p (owner size signature signature-bytes work)
  (handler-case
      (multiple-value-bind (inside bytes next) (piece-of 48 signature (+ signature signature-bytes))
        (multiple-value-bind (r r-bytes after) (piece-of 2 inside (+ inside bytes))
          (multiple-value-bind (s s-bytes last) (piece-of 2 after (+ inside bytes))
            (and (= next (+ signature signature-bytes))
                 (= last (+ inside bytes))
                 (<= 1 r-bytes 49) (<= 1 s-bytes 49)
                 (< (one r) 128) (< (one s) 128)
                 (clara.unsafe:ecdsa (certificate-key owner) (certificate-point owner) work size r r-bytes s s-bytes)))))
    (error () nil)))

;; Is the signature the one that the key of the certificate OWNER gives
;; those bytes? WAY says how it was made: (:RSA . bits), (:PSS . bits) or
;; (:ECDSA . bits), the bits being those of the sum.
(defun signature-good-p (owner way from bytes signature signature-bytes work)
  (let* ((bits (cdr way)) (size (floor bits 8)))
    (clara.unsafe:digest bits from bytes work)
    (case (car way)
      (:rsa (and (eq (certificate-key owner) :rsa) (rsa-good-p owner bits size signature signature-bytes work)))
      (:pss (and (eq (certificate-key owner) :rsa) (pss-good-p owner bits size signature signature-bytes work)))
      (:ecdsa (and (integerp (certificate-key owner)) (ecdsa-good-p owner size signature signature-bytes work))))))

;; Did the certificate ISSUER sign this one? It did when it has the name
;; that this one says signed it, byte for byte, and the signature is its
;; key's.
(defun signed-by-p (certificate issuer work)
  (and (= (certificate-issuer-bytes certificate) (certificate-subject-bytes issuer))
       (same-bytes (certificate-issuer certificate) (certificate-subject issuer) (certificate-subject-bytes issuer))
       (certificate-signed certificate)
       (signature-good-p issuer (certificate-signed certificate)
                         (certificate-body certificate) (certificate-body-bytes certificate)
                         (certificate-signature certificate) (certificate-signature-bytes certificate) work)))

;;; Who is trusted
;;;
;;; The certificates that a chain may end in. The system's own are in the
;;; file roots.pem of its directory, which is read the first time that
;;; somebody asks, and not before: a machine that fetches nothing by HTTPS
;;; reads nothing. The user's are the texts that TRUST was given, which a
;;; world that is saved keeps; they are read again at every start, like the
;;; file, since what is read lies in memory that is this start's.

(defvar *system-roots* nil)  ; the certificates of the system's list, once it is read
(defvar *system-read* nil)   ; it is read
(defvar *own-roots* nil)     ; the certificates of the user's texts, as far as this start has read them
(defvar *own-read* 0)        ; how many of the texts that is
(defvar *trusted* nil)       ; the texts that TRUST was given, the first one first
(defvar *lock* (clara:make-lock "certificates")) ; one thread at a time reads a list

;; What a character stands for in base 64 (RFC 4648, 4), by its code; NIL
;; for one that stands for nothing, which the end of a line is, and the
;; sign that fills the last group up.
(defun sixty-fourth (code)
  (cond ((<= 65 code 90) (- code 65))
        ((<= 97 code 122) (- code 71))
        ((<= 48 code 57) (+ code 4))
        ((= code 43) 62)
        ((= code 47) 63)))

(defun begins (memory at bytes text)
  (and (<= (+ at (length text)) bytes)
       (dotimes (i (length text) t)
         (unless (= (one (+ memory at i)) (char-code (char text i)))
           (return nil)))))

;; The certificates in a text that lies in memory, as files of certificates
;; are written (RFC 7468): each between a line that says that one begins
;; and a line that says that it ends, in base 64, four characters to three
;; bytes. The bytes are written where the text was, which they are shorter
;; than, and the certificates lie there from then on. One that cannot be
;; read is passed over; how many those were is the second value.
(defun certificates-in (memory bytes)
  (let ((at 0) (found nil) (passed 0) (begin "-----BEGIN CERTIFICATE-----"))
    (loop
      (loop
        (when (or (> (+ at (length begin)) bytes) (begins memory at bytes begin))
          (return))
        (setq at (1+ at)))
      (when (> (+ at (length begin)) bytes)
        (return (values (reverse found) passed)))
      (setq at (+ at (length begin)))
      (let ((start at) (to at) (held 0) (count 0))
        (loop
          (when (>= at bytes)
            (error "a certificate in the list has no end"))
          (let ((code (one (+ memory at))))
            (when (= code 45)
              (return))
            (let ((value (sixty-fourth code)))
              (when value
                (setq held (+ (* 64 held) value)
                      count (1+ count))
                (when (= count 4)
                  (put-three (+ memory to) held)
                  (setq to (+ to 3)
                        held 0
                        count 0))))
            (setq at (1+ at))))
        (cond ((= count 2)
               (put-one (+ memory to) (ash held -4))
               (setq to (1+ to)))
              ((= count 3)
               (put-two (+ memory to) (ash held -2))
               (setq to (+ to 2))))
        (handler-case (setq found (cons (read-certificate (+ memory start) (- to start)) found))
          (error ()
            (setq passed (1+ passed))))))))

;; The system's list, read: the file stays in memory, with the certificates
;; where its text was.
(defun read-system-roots ()
  (let ((volume (clara.system:boot-volume)))
    (unless volume
      (error "the machine was not started from a disk that is known here, so the list of whom this system trusts cannot be read"))
    (multiple-value-bind (memory bytes) (let ((clara.fat:*volume* volume))
                                          (clara.fat:read-file (clara.system:system-file "roots.pem")))
      (multiple-value-bind (certificates passed) (certificates-in memory bytes)
        (format t "tls: this system trusts ~D certificates to say who a machine is~A~%" (length certificates)
                (if (> passed 0) (format nil ", and could not read ~D more in its list" passed) ""))
        certificates))))

;; A text of certificates, read into memory of its own.
(defun read-text (text)
  (let* ((bytes (clara.unsafe:string-bytes text))
         (pages (max 1 (floor (+ bytes 4095) 4096)))
         (memory (clara.unsafe:allocate-memory pages))
         (kept nil))
    (unwind-protect
         (progn
           (clara.unsafe:string-memory text memory)
           (let ((certificates (certificates-in memory bytes)))
             (when certificates
               (setq kept t))
             certificates))
      (unless kept
        (clara.unsafe:free-memory memory pages)))))

;; Every certificate that a chain may end in: the user's, and the system's.
(defun anchors ()
  (clara:with-lock-held (*lock*)
    (loop
      (when (>= *own-read* (length *trusted*))
        (return))
      (let ((text (nth *own-read* *trusted*)))
        (setq *own-read* (1+ *own-read*)
              *own-roots* (append *own-roots* (read-text text)))))
    (unless *system-read*
      (setq *system-roots* (read-system-roots)
            *system-read* t))
    (append *own-roots* *system-roots*)))

;; The names of the certificates that this system trusts, the ones that
;; TRUST added first.
(defun roots ()
  (mapcar #'certificate-name (anchors)))

;; Certificates are trusted from here on: WHAT is their text, as files of
;; certificates are written, or the name of such a file. The names of the
;; ones that were added. A world that is saved keeps them; a world that is
;; made again does not, so a line in /home/init.lisp is where this belongs.
(defun trust (what)
  (unless (stringp what)
    (error "~S is neither the text of a certificate nor the name of a file that has one" what))
  (let ((text (if (holds what "-----BEGIN CERTIFICATE-----")
                  what
                  (multiple-value-bind (memory bytes pages) (clara.fat:read-file what)
                    (unwind-protect (clara.unsafe:memory-string memory bytes)
                      (clara.unsafe:free-memory memory pages))))))
    (let ((certificates (read-text text)))
      (unless certificates
        (error "there is no certificate in ~A that can be read" (if (eq text what) "that text" what)))
      (clara:with-lock-held (*lock*)
        ;; they are read once more, with the others, the next time that somebody asks who is trusted
        (setq *trusted* (append *trusted* (list text))))
      (mapcar #'certificate-name certificates))))

;;; Chains

;; Is a certificate for the machine that was asked for? A name of the
;; certificate is the machine's name, whichever kind of letters either is
;; written in; or it begins with a star and a dot, and the rest is the
;; machine's name from its first dot on (RFC 9525, 6.3). For a machine
;; that was asked for by its address, the certificate has to have the
;; address.
(defun for-name-p (certificate host)
  (let ((address (clara.net::text-address host)))
    (if address
        (member address (certificate-addresses certificate))
        (some (lambda (name)
                (or (string-equal name host)
                    (and (> (length name) 2) (char= (char name 0) #\*) (char= (char name 1) #\.)
                         (let ((dot nil))
                           (dotimes (i (length host))
                             (when (and (null dot) (char= (char host i) #\.))
                               (setq dot i)))
                           (and dot (> dot 0) (string-equal (subseq name 1) (subseq host dot)))))))
              (certificate-names certificate)))))

(defun check-dates (certificate now)
  (when (< now (certificate-from certificate))
    (refuse 45 "the certificate of ~A is good from ~A on, and this machine's clock says that it is ~A"
            (certificate-name certificate) (date-text (certificate-from certificate)) (date-text now)))
  (when (> now (certificate-until certificate))
    (refuse 45 "the certificate of ~A was good until ~A, and this machine's clock says that it is ~A"
            (certificate-name certificate) (date-text (certificate-until certificate)) (date-text now))))

;; The certificates that a machine has shown, its own first, are held
;; against the name that was asked for, the time, and each other, up to
;; one that this system trusts: the machine's own certificate, when all of
;; that is in order, and an error that says what is not.
(defun check-chain (certificates host now work)
  (let ((own (car certificates)) (current (car certificates)) (others (cdr certificates)) (below 0)
        (trusted (anchors)))
    (unless (for-name-p own host)
      (refuse 42 "the certificate that ~A shows is not for that name: it is for ~A" host
              (if (certificate-names own)
                  (format nil "~A~A" (car (certificate-names own))
                          (if (cdr (certificate-names own))
                              (format nil " and ~D other names" (length (cdr (certificate-names own))))
                              ""))
                  "no name at all")))
    (unless (certificate-key own)
      (refuse 43 "the certificate of ~A has a key of a kind that is not known here" host))
    (when (and (certificate-usage own) (= 0 (logand (certificate-usage own) 128)))
      (refuse 43 "the certificate of ~A has a key that is not for signing a greeting" host))
    (loop
      (check-dates current now)
      (when (certificate-unknown current)
        (refuse 43 "the certificate of ~A says something that has to be understood, and is not understood here"
                (certificate-name current)))
      (unless (certificate-serves current)
        (refuse 43 "the certificate of ~A is not for a machine that serves" (certificate-name current)))
      (unless (certificate-signed current)
        (refuse 43 "the certificate of ~A is signed in a way that is not known here" (certificate-name current)))
      ;; somebody who is trusted has signed it, and is trusted today: the chain ends
      (let ((late nil))
        (dolist (root trusted)
          (when (signed-by-p current root work)
            (when (<= (certificate-from root) now (certificate-until root))
              (return-from check-chain own))
            (setq late root)))
        (when late
          (check-dates late now)))
      ;; or one of the others that the machine has shown has signed it, and may sign
      (let ((next (find-if (lambda (other) (signed-by-p current other work)) others)))
        (unless next
          (if (and (= (certificate-issuer-bytes current) (certificate-subject-bytes current))
                   (same-bytes (certificate-issuer current) (certificate-subject current) (certificate-subject-bytes current)))
              (refuse 48 "the certificate of ~A is signed by nobody but itself, and is none that this system trusts"
                      (certificate-name current))
              (refuse 48 "the certificate of ~A is signed by somebody whom this system does not know, and who was not shown"
                      (certificate-name current))))
        (unless (certificate-authority next)
          (refuse 42 "the certificate of ~A is signed by ~A, who may not sign certificates"
                  (certificate-name current) (certificate-name next)))
        (when (and (certificate-usage next) (= 0 (logand (certificate-usage next) 4)))
          (refuse 42 "the certificate of ~A is signed by ~A, whose key is not for signing certificates"
                  (certificate-name current) (certificate-name next)))
        (when (and (certificate-depth next) (> below (certificate-depth next)))
          (refuse 42 "the certificate of ~A is too far below ~A, who lets fewer sign in between"
                  (certificate-name own) (certificate-name next)))
        (setq others (remove next others)
              current next
              below (1+ below))
        (when (> below 8)
          (refuse 42 "the certificates that ~A shows go on for longer than is followed" host))))))

;;; A connection that is kept closed
;;;
;;; What is kept of one. Its secrets, and the memory that sums and keys are
;;; made in, are a page frame; what goes out is put together in a second
;;; one behind it. The messages of the greeting are gathered in memory of
;;; their own, in the order in which they were said, since each side's keys
;;; and last word are made of the sum of them. What arrives is opened where
;;; it lies, in the memory of the connection: what the other side says
;;; after the greeting is moved to the beginning of that memory as it is
;;; opened, which is always behind the place that the next record is read
;;; from, and there lisp/net.lisp finds it.

(defstruct session
  connection host
  page             ; two page frames: secrets and room to work in, and what is sent
  hand             ; the messages of the greeting, and later whatever else of that kind comes: sixteen page frames
  (said 0)         ; how many bytes of them are there,
  (read 0)         ; and how many of those were taken as messages
  (at 0)           ; where the next record begins, in the memory of the connection
  (plain 0)        ; how many bytes of what the other side says lie opened at the beginning of that memory
  begun            ; the greeting has begun: something was sent
  opening          ; what arrives is closed, and there are the keys to open it
  closing          ; what is sent is closed
  (heard 0)        ; how many records were opened with the keys that there are now,
  (sent 0)         ; and how many closed
  open             ; the greeting is over
  ended            ; the other side has said that it is done
  renew            ; the other side wants what is sent from here on closed with new keys
  alert)           ; something went wrong after the greeting: what the other side is to be told of it

(defconstant +private+ 0)        ; this side's secret number, 32 bytes,
(defconstant +public+ 32)        ; and what it makes of the point 9
(defconstant +shared+ 64)        ; what both sides agree on
(defconstant +zeroes+ 96)        ; 32 bytes that nothing writes to
(defconstant +early+ 128)        ; the secrets, one made of the other: before the greeting,
(defconstant +greeting+ 160)     ; of the greeting,
(defconstant +master+ 192)       ; and of everything after it
(defconstant +ours+ 224)         ; what this side's keys are made of at the moment,
(defconstant +theirs+ 256)       ; and the other side's
(defconstant +our-next+ 288)     ; the same for after the greeting, made before they are used
(defconstant +their-next+ 320)
(defconstant +our-key+ 352)      ; 16 bytes
(defconstant +our-count+ 368)    ; 12 bytes that the number of a record is added to
(defconstant +their-key+ 384)
(defconstant +their-count+ 400)
(defconstant +word-key+ 416)     ; the key that the word at the end of a greeting is made with
(defconstant +sum+ 448)          ; the sum of the greeting so far
(defconstant +made+ 512)         ; what was last made with a key
(defconstant +nonce+ 576)        ; the twelve bytes of one record
(defconstant +label+ 640)        ; what a secret is made into another with
(defconstant +signed+ 768)       ; what the other side signs at the end of its greeting
(defconstant +work+ 1024)        ; for checking signatures: 3072 bytes
(defconstant +out+ 4096)         ; what is sent

(defconstant +hand-pages+ 16)

(defun host-of (session)
  (session-host session))

;; One secret made into another, or into a key: LENGTH bytes at TO, from
;; the secret, a word that says what they are for, and CONTEXT (RFC 8446,
;; 7.1, HKDF-Expand-Label; no more than one sum's worth is ever asked for,
;; so one turn of HKDF's loop is all of it).
(defun expand (session to secret label context context-bytes length)
  (let* ((page (session-page session)) (at (+ page +label+)) (text (concatenate 'string "tls13 " label)))
    (put-two at length)
    (put-one (+ at 2) (length text))
    (put-text (+ at 3) text)
    (put-one (+ at 3 (length text)) context-bytes)
    (when (> context-bytes 0)
      (clara.unsafe:copy-memory (+ at 4 (length text)) context context-bytes))
    (put-one (+ at 4 (length text) context-bytes) 1)
    (clara.unsafe:hmac 256 secret 32 at (+ 5 (length text) context-bytes) (+ page +made+))
    (clara.unsafe:copy-memory to (+ page +made+) length)))

;; A secret made of another and of the greeting as far as it has come: of
;; the sum of its first COUNT bytes (7.1, Derive-Secret).
(defun derive (session to secret label count)
  (let ((page (session-page session)))
    (clara.unsafe:digest 256 (session-hand session) count (+ page +sum+))
    (expand session to secret label (+ page +sum+) 32 32)))

;; The key and the twelve bytes that records are closed with, from what
;; they are made of (7.3).
(defun make-keys (session secret key count)
  (expand session key secret "key" 0 0 16)
  (expand session count secret "iv" 0 0 12))

;; The twelve bytes that one record is closed with: the twelve of the
;; keys, with the number of the record added in at their end (5.3).
(defun nonce (session base number)
  (let ((at (+ (session-page session) +nonce+)))
    (dotimes (i 12)
      (put-one (+ at i) (logxor (one (+ base i))
                                (if (< i 4) 0 (logand (ash number (* -8 (- 11 i))) 255)))))
    at))

;; A record goes out: five bytes that say what kind it is and how long,
;; and its bytes. Once there are keys, the bytes are closed, with the kind
;; behind them, and the record says that it is of the kind 23 whatever is
;; in it (5.2).
(defun send-record (session kind from bytes)
  (let* ((page (session-page session)) (out (+ page +out+)))
    (when (> bytes 4000)
      (error "~D bytes are more than is said in one record" bytes))
    (cond ((session-closing session)
           (clara.unsafe:copy-memory (+ out 5) from bytes)
           (put-one (+ out 5 bytes) kind)
           (put-one out 23)
           (put-two (+ out 1) #x0303)
           (put-two (+ out 3) (+ bytes 17))
           (clara.unsafe:aes-128-gcm-seal (+ page +our-key+) (nonce session (+ page +our-count+) (session-sent session))
                                          out 5 (+ out 5) (1+ bytes) (+ out 5) (+ out 6 bytes))
           (setf (session-sent session) (1+ (session-sent session)))
           (clara.net::say-bytes (session-connection session) out (+ bytes 22)))
          (t
           (put-one out kind)
           (put-two (+ out 1) (if (session-begun session) #x0303 #x0301))
           (put-two (+ out 3) bytes)
           (clara.unsafe:copy-memory (+ out 5) from bytes)
           (clara.net::say-bytes (session-connection session) out (+ bytes 5))))
    (setf (session-begun session) t)))

;; The other side is told that this side is done, or that it gives up:
;; two bytes, how bad it is and what it is (6).
(defun send-alert (session level alert)
  (let ((at (+ (session-page session) +label+)))
    (put-one at level)
    (put-one (+ at 1) alert)
    (send-record session 21 at 2)))

;; What a record carried, by its kind: a piece of the greeting, or of what
;; comes after it and is of that kind, goes to the other messages; what
;; the other side says, once the greeting is over, goes to the beginning
;; of the connection's memory; and an alert is the end, a good one when it
;; is the number 0.
(defun deliver (session memory kind from bytes)
  (let ((host (host-of session)))
    (cond ((= kind 22)
           (when (= bytes 0)
             (refuse 10 "~A sent a piece of its greeting that has nothing in it" host))
           (when (> (+ (session-said session) bytes) (* 4096 +hand-pages+))
             (refuse 80 "~A says more in its greeting than is taken" host))
           (clara.unsafe:copy-memory (+ (session-hand session) (session-said session)) from bytes)
           (setf (session-said session) (+ (session-said session) bytes)))
          ((= kind 23)
           (unless (session-open session)
             (refuse 10 "~A sent something before the greeting was over" host))
           (clara.unsafe:copy-memory (+ memory (session-plain session)) from bytes)
           (setf (session-plain session) (+ (session-plain session) bytes)))
          ((= kind 21)
           (unless (= bytes 2)
             (refuse 50 "~A sent a word about the connection that is none" host))
           (if (= (one (+ from 1)) 0)
               (setf (session-ended session) t)
               (refuse nil "~A gave the connection up: ~A" host (alert-text (one (+ from 1))))))
          (t
           (refuse 10 "~A sent a record of a kind that there is none of" host)))))

;; The next record, when all of it has arrived, is taken: opened where it
;; lies, if there are keys, and what it carried delivered. T when there
;; was one. A record that is closed is 16 bytes longer than what it
;; carries, which are the tag, and what it carries ends with its kind, and
;; after that with as many zeroes as the other side liked to add (5.2,
;; 5.4). All of it with the lock of the connection, whose memory the thread
;; that takes what arrives may move.
(defun take-record (session)
  (let ((connection (session-connection session)) (host (host-of session)) (page (session-page session)))
    (clara:with-lock-held ((clara.net::connection-lock connection))
      (let* ((memory (clara.net::connection-memory connection))
             (have (- (clara.net::connection-held connection) (session-at session)))
             (record (+ memory (session-at session))))
        (when (>= have 5)
          (let ((kind (one record)) (bytes (two (+ record 3))))
            ;; what is no record of TLS's at all, before anything is closed: the other side speaks something else
            (unless (or (session-opening session) (and (<= 20 kind 22) (= (one (+ record 1)) 3)))
              (refuse 10 "~A does not answer as TLS does: nothing at that port of it keeps a connection closed" host))
            (when (> bytes 16640)
              (refuse 22 "~A sent a record of ~D bytes, which is longer than a record may be" host bytes))
            (when (>= have (+ 5 bytes))
              (setf (session-at session) (+ (session-at session) 5 bytes))
              (cond ((and (= kind 20) (not (session-open session)))
                     ;; a word of older TLS, said for the sake of machines on the way that look for it: it means nothing
                     (unless (and (= bytes 1) (= (one (+ record 5)) 1))
                       (refuse 10 "~A sent a word of an older TLS that is none" host)))
                    ((session-opening session)
                     (unless (and (= kind 23) (>= bytes 17))
                       (refuse 10 "~A sent a record in the open where everything is closed" host))
                     (unless (clara.unsafe:aes-128-gcm-open (+ page +their-key+)
                                                            (nonce session (+ page +their-count+) (session-heard session))
                                                            record 5 (+ record 5) (- bytes 16) (+ record 5)
                                                            (+ record 5 (- bytes 16)))
                       (refuse 20 "what ~A sent does not open with the key of this connection: it was changed on the way, or is not from ~A"
                               host host))
                     (setf (session-heard session) (1+ (session-heard session)))
                     (let ((end (- bytes 16)))
                       (loop
                         (unless (and (> end 0) (= (one (+ record 4 end)) 0))
                           (return))
                         (setq end (1- end)))
                       (when (= end 0)
                         (refuse 10 "~A sent a record with nothing in it" host))
                       (deliver session memory (one (+ record 4 end)) (+ record 5) (1- end))))
                    (t
                     (when (> bytes 16384)
                       (refuse 22 "~A sent a record of ~D bytes, which is longer than a record may be" host bytes))
                     (deliver session memory kind (+ record 5) bytes)))
              t)))))))

;; Wait for more to arrive on the connection than there is.
(defun wait-more (session)
  (let* ((connection (session-connection session)) (held (clara.net::connection-held connection)))
    (unless (clara.net::wait-for connection (lambda () (> (clara.net::connection-held connection) held)))
      (refuse nil "~A ended the connection in the middle of its greeting" (host-of session)))))

;; The next message of the greeting: its kind, where its bytes are, and how
;; many. A message is a byte for its kind and three for its length, and it
;; may come in one record, in several, or with others in one (5.1); so
;; records are taken until all of it is there, and no further, since the
;; keys change after some messages.
(defun message (session)
  (loop
    (let* ((hand (session-hand session)) (read (session-read session)) (have (- (session-said session) read)))
      (when (>= have 4)
        (let ((bytes (three (+ hand read 1))))
          (when (>= have (+ 4 bytes))
            (setf (session-read session) (+ read 4 bytes))
            (return (values (one (+ hand read)) (+ hand read 4) bytes))))))
    (when (session-ended session)
      (refuse nil "~A said that it was done in the middle of its greeting" (host-of session)))
    (unless (take-record session)
      (wait-more session))))

;; The same, for a message that has to be of one kind.
(defun message-of (session kind what)
  (multiple-value-bind (found at bytes) (message session)
    (unless (= found kind)
      (refuse 10 "~A sent something else where ~A belongs in a greeting" (host-of session) what))
    (values at bytes)))

;; Nothing of a message may be left over where the keys change (5.1).
(defun nothing-left (session)
  (unless (= (session-read session) (session-said session))
    (refuse 10 "~A sent the beginning of something with the keys of what came before it" (host-of session))))

;; This side's first message (4.1.2): thirty-two bytes that nobody can
;; guess; the one cipher; and what else it has to say, each a kind, a
;; length and bytes: the name of the machine that is meant (RFC 6066, 3),
;; unless it was asked for by its address; that the exchange of keys is
;; X25519 (4.2.7), and this side's half of it (4.2.8); the signatures that
;; it can check (4.2.3); and that it speaks TLS 1.3 (4.2.1). It is written
;; where the messages of the greeting are gathered, since it is the first.
(defun put-hello (session)
  (let* ((page (session-page session)) (hand (session-hand session)) (host (host-of session))
         (named (not (clara.net::text-address host)))
         (at (+ hand 4)) (start (+ at 43)) (e start)
         (ways '(#x0403 #x0503 #x0804 #x0805 #x0806 #x0401 #x0501 #x0601)))
    (when (> (length host) 253)
      (error "~A is longer than the name of a machine can be" host))
    (put-two at #x0303)
    (clara.random:bytes (+ at 2) 32)
    (put-one (+ at 34) 0)
    (put-two (+ at 35) 2)
    (put-two (+ at 37) #x1301)
    (put-one (+ at 39) 1)
    (put-one (+ at 40) 0)
    (when named
      (put-two e 0)
      (put-two (+ e 2) (+ 5 (length host)))
      (put-two (+ e 4) (+ 3 (length host)))
      (put-one (+ e 6) 0)
      (put-two (+ e 7) (length host))
      (put-text (+ e 9) host)
      (setq e (+ e 9 (length host))))
    (put-two e 10)
    (put-two (+ e 2) 4)
    (put-two (+ e 4) 2)
    (put-two (+ e 6) 29)
    (setq e (+ e 8))
    (put-two e 13)
    (put-two (+ e 2) (+ 2 (* 2 (length ways))))
    (put-two (+ e 4) (* 2 (length ways)))
    (setq e (+ e 6))
    (dolist (way ways)
      (put-two e way)
      (setq e (+ e 2)))
    (put-two e 43)
    (put-two (+ e 2) 3)
    (put-one (+ e 4) 2)
    (put-two (+ e 5) #x0304)
    (setq e (+ e 7))
    (put-two e 51)
    (put-two (+ e 2) 38)
    (put-two (+ e 4) 36)
    (put-two (+ e 6) 29)
    (put-two (+ e 8) 32)
    (clara.unsafe:copy-memory (+ e 10) (+ page +public+) 32)
    (setq e (+ e 42))
    (put-two (+ at 41) (- e start))
    (put-one hand 1)
    (put-three (+ hand 1) (- e at))
    (setf (session-said session) (- e hand)
          (session-read session) (- e hand))))

;; The other side's first message (4.1.3): that it speaks TLS 1.3, the
;; cipher, and its half of the exchange of keys, whose address this gives.
;; A message that says "begin again" has, where the other side's
;; thirty-two bytes belong, the sum of the words HelloRetryRequest (4.1.3):
;; it asks for another exchange of keys, and there is only the one.
(defun heard-hello (session at bytes)
  (let* ((host (host-of session)) (end (+ at bytes)) (work (+ (session-page session) +work+)))
    (unless (>= bytes 40)
      (refuse 50 "~A answers the greeting with something that is too short to be an answer" host))
    (put-text work "HelloRetryRequest")
    (clara.unsafe:digest 256 work 17 (+ work 32))
    (when (same-bytes (+ at 2) (+ work 32) 32)
      (refuse 40 "~A asks to begin again with another exchange of keys, and this system has the one only" host))
    (let* ((again (one (+ at 34))) (rest (+ at 35 again)) (version nil) (key nil))
      (unless (<= (+ rest 5) end)
        (refuse 50 "~A answers the greeting with something that ends too early" host))
      (let* ((e (+ rest 5)) (list-end (+ e (two (+ rest 3)))))
        (unless (= list-end end)
          (refuse 50 "~A answers the greeting with something that is not as long as it says" host))
        (loop
          (when (>= e list-end)
            (return))
          (unless (<= (+ e 4) list-end)
            (refuse 50 "~A answers the greeting with something that ends too early" host))
          (let ((kind (two e)) (length (two (+ e 2))) (inside (+ e 4)))
            (unless (<= (+ inside length) list-end)
              (refuse 50 "~A answers the greeting with something that ends too early" host))
            (cond ((= kind 43)
                   (when (= length 2)
                     (setq version (two inside))))
                  ((= kind 51)
                   (unless (and (= length 36) (= (two inside) 29) (= (two (+ inside 2)) 32))
                     (refuse 47 "~A answers with an exchange of keys that it was not offered" host))
                   (setq key (+ inside 4)))
                  (t
                   (refuse 110 "~A answers the greeting with something that it was not asked for" host)))
            (setq e (+ inside length)))))
      (unless (and (eql version #x0304) (= (two at) #x0303))
        (refuse 70 "~A speaks no TLS 1.3, and nothing older is spoken here" host))
      (unless (and (= again 0) (= (two rest) #x1301) (= (one (+ rest 2)) 0))
        (refuse 47 "~A answers with a cipher, or with a way of going on, that it was not offered" host))
      (unless key
        (refuse 109 "~A answers without its half of the exchange of keys" host))
      key)))

;; The keys of the greeting (7.1): what both sides agree on is this side's
;; number times the other side's point; the secret of the greeting is made
;; of that, and each side's keys of that secret and of the two messages
;; that were said so far. The number is wiped as soon as it has been used.
(defun greeting-keys (session key)
  (let ((page (session-page session)) (count (session-read session)))
    (unless (clara.unsafe:x25519 (+ page +private+) key (+ page +shared+))
      (refuse 47 "~A sent a half of the exchange of keys that makes nothing" (host-of session)))
    (clear (+ page +private+) 32)
    (clara.unsafe:hmac 256 (+ page +zeroes+) 32 (+ page +zeroes+) 32 (+ page +early+))
    (derive session (+ page +master+) (+ page +early+) "derived" 0)
    (clara.unsafe:hmac 256 (+ page +master+) 32 (+ page +shared+) 32 (+ page +greeting+))
    (clear (+ page +shared+) 32)
    (derive session (+ page +ours+) (+ page +greeting+) "c hs traffic" count)
    (derive session (+ page +theirs+) (+ page +greeting+) "s hs traffic" count)
    (make-keys session (+ page +ours+) (+ page +our-key+) (+ page +our-count+))
    (make-keys session (+ page +theirs+) (+ page +their-key+) (+ page +their-count+))
    (setf (session-opening session) t
          (session-closing session) t
          (session-heard session) 0
          (session-sent session) 0)))

;; The certificates that the other side shows (4.4.2): its own first, each
;; with its length before it and, behind it, things that go with it and
;; that are passed over here.
(defun heard-certificates (session at bytes)
  (let ((host (host-of session)) (end (+ at bytes)) (found nil))
    (unless (and (>= bytes 4) (= (one at) 0) (= (+ at 4 (three (+ at 1))) end))
      (refuse 50 "~A shows its certificates in a way that is none" host))
    (let ((list (+ at 4)))
      (loop
        (when (>= list end)
          (return))
        (unless (<= (+ list 3) end)
          (refuse 50 "~A shows certificates that end too early" host))
        (let* ((size (three list)) (certificate (+ list 3)))
          (unless (<= (+ certificate size 2) end)
            (refuse 50 "~A shows certificates that end too early" host))
          (setq found (cons (handler-case (read-certificate certificate size)
                              (error (condition)
                                (refuse 42 "~A shows a certificate that cannot be read: ~A" host condition)))
                            found))
          (setq list (+ certificate size 2 (two (+ certificate size))))))
      (unless (and found (= list end) (<= (length found) 10))
        (refuse 50 "~A shows no certificate, or more than are looked at" host)))
    (reverse found)))

;; The other side shows that the key of its certificate is its own (4.4.3):
;; it signs sixty-four spaces, these words, a zero, and the sum of the
;; greeting up to its certificates. The first two bytes say how; for a key
;; on a curve the way and the curve go together.
(defun heard-signature (session own count at bytes)
  (let* ((host (host-of session)) (page (session-page session)) (signed (+ page +signed+))
         (words "TLS 1.3, server CertificateVerify"))
    (unless (and (>= bytes 4) (= (+ 4 (two (+ at 2))) bytes))
      (refuse 50 "~A signs its greeting in a way that is none" host))
    (let* ((number (two at))
           (way (case number
                  (#x0403 (and (eql (certificate-key own) 256) '(:ecdsa . 256)))
                  (#x0503 (and (eql (certificate-key own) 384) '(:ecdsa . 384)))
                  (#x0804 (and (eq (certificate-key own) :rsa) '(:pss . 256)))
                  (#x0805 (and (eq (certificate-key own) :rsa) '(:pss . 384)))
                  (#x0806 (and (eq (certificate-key own) :rsa) '(:pss . 512))))))
      (unless way
        (refuse 47 "~A signs its greeting in a way that it was not offered, or that does not go with its key" host))
      (dotimes (i 64)
        (put-one (+ signed i) 32))
      (put-text (+ signed 64) words)
      (put-one (+ signed 64 (length words)) 0)
      (clara.unsafe:digest 256 (session-hand session) count (+ signed 65 (length words)))
      (unless (signature-good-p own way signed (+ 97 (length words)) (+ at 4) (- bytes 4) (+ page +work+))
        (refuse 51 "~A has not shown that the key of its certificate is its own: its greeting is not signed with it" host)))))

;; The word at the end of a side's greeting (4.4.4): what the key that is
;; made of that side's secret makes of the sum of the greeting's first
;; COUNT bytes. Written into the page, at the place of what was last made.
(defun last-word (session secret count)
  (let ((page (session-page session)))
    (expand session (+ page +word-key+) secret "finished" 0 0 32)
    (clara.unsafe:digest 256 (session-hand session) count (+ page +sum+))
    (clara.unsafe:hmac 256 (+ page +word-key+) 32 (+ page +sum+) 32 (+ page +made+))
    (+ page +made+)))

;; The greeting (2): this side's first message and the other side's, in
;; the open; then, closed with the keys of the greeting, what else the
;; other side has to say, its certificates, its signature and its last
;; word; this side's last word; and from there the keys of everything
;; after it.
(defun greet (session)
  (let* ((page (session-page session)) (host (host-of session)) (hand (session-hand session)))
    ;; this side's half of the exchange of keys: a number that nobody can guess, and what it makes of the point 9
    (clara.random:bytes (+ page +private+) 32)
    (put-one (+ page +work+) 9)
    (unless (clara.unsafe:x25519 (+ page +private+) (+ page +work+) (+ page +public+))
      (error "the exchange of keys makes nothing of the point that it begins with"))
    (clear (+ page +work+) 32)
    (put-hello session)
    (send-record session 22 hand (session-said session))
    (multiple-value-bind (at bytes) (message-of session 2 "its first word")
      (let ((key (heard-hello session at bytes)))
        (nothing-left session)
        (greeting-keys session key)))
    ;; what else it has to say about the connection (4.3.1): nothing that this side asked for is wanted back
    (multiple-value-bind (at bytes) (message-of session 8 "what it has to say about the connection")
      (unless (and (>= bytes 2) (= (+ 2 (two at)) bytes))
        (refuse 50 "~A says something about the connection that is not as long as it says" host))
      (let ((e (+ at 2)) (end (+ at bytes)))
        (loop
          (when (>= e end)
            (return))
          (unless (and (<= (+ e 4) end) (<= (+ e 4 (two (+ e 2))) end))
            (refuse 50 "~A says something about the connection that ends too early" host))
          (unless (member (two e) '(0 10))
            (refuse 110 "~A says something about the connection that it was not asked for" host))
          (setq e (+ e 4 (two (+ e 2)))))))
    (let ((asked nil) (own nil))
      (multiple-value-bind (kind at bytes) (message session)
        ;; it may ask who this machine is (4.3.2), which has no certificate to show
        (when (= kind 13)
          (unless (and (>= bytes 1) (= (one at) 0))
            (refuse 47 "~A asks who this machine is in a way that is none" host))
          (setq asked t)
          (multiple-value-setq (kind at bytes) (message session)))
        (unless (= kind 11)
          (refuse 10 "~A sent something else where its certificates belong in a greeting" host))
        (let ((certificates (heard-certificates session at bytes))
              (now (handler-case (get-universal-time)
                     (error ()
                       (refuse 46 "this machine does not know what time it is, and cannot say whether a certificate is good today")))))
          (setq own (check-chain certificates host now (+ page +work+)))))
      (let ((count (session-read session)))
        (multiple-value-bind (at bytes) (message-of session 15 "its signature")
          (heard-signature session own count at bytes)))
      (let ((count (session-read session)))
        (multiple-value-bind (at bytes) (message-of session 20 "its last word")
          (unless (and (= bytes 32) (same-bytes at (last-word session (+ page +theirs+) count) 32))
            (refuse 51 "~A and this machine have not heard the same greeting: something of it was changed on the way" host))))
      (nothing-left session)
      ;; the secrets of everything after the greeting, made of all of it up to the other side's last word (7.1)
      (let ((count (session-read session)))
        (derive session (+ page +master+) (+ page +greeting+) "derived" 0)
        (clara.unsafe:hmac 256 (+ page +master+) 32 (+ page +zeroes+) 32 (+ page +master+))
        (derive session (+ page +our-next+) (+ page +master+) "c ap traffic" count)
        (derive session (+ page +their-next+) (+ page +master+) "s ap traffic" count))
      ;; a machine that was asked who it is, and has no certificate, says so: a list of none (4.4.2)
      (when asked
        (let ((at (+ hand (session-read session))))
          (put-one at 11)
          (put-three (+ at 1) 4)
          (put-four (+ at 4) 0)
          (send-record session 22 at 8)
          (setf (session-read session) (+ (session-read session) 8)
                (session-said session) (+ (session-said session) 8))))
      ;; this side's last word
      (let ((word (last-word session (+ page +ours+) (session-read session))) (at (+ page +signed+)))
        (put-one at 20)
        (put-three (+ at 1) 32)
        (clara.unsafe:copy-memory (+ at 4) word 32)
        (send-record session 22 at 36)))
    ;; and the keys change, for both sides
    (clara.unsafe:copy-memory (+ page +ours+) (+ page +our-next+) 32)
    (clara.unsafe:copy-memory (+ page +theirs+) (+ page +their-next+) 32)
    (make-keys session (+ page +ours+) (+ page +our-key+) (+ page +our-count+))
    (make-keys session (+ page +theirs+) (+ page +their-key+) (+ page +their-count+))
    (clear (+ page +early+) 96)
    (setf (session-heard session) 0
          (session-sent session) 0
          (session-said session) 0
          (session-read session) 0
          (session-open session) t)
    session))

;; What a side sends from here on is closed with new keys, made of the old
;; (7.2).
(defun renew (session secret key count)
  (expand session secret secret "traffic upd" 0 0 32)
  (make-keys session secret key count))

;; Messages of the greeting's kind that come after it (4.6): a ticket to
;; come back with on another day, which is not kept; and the word that the
;; other side closes what it sends with new keys from here on, perhaps
;; with the wish that this side does the same.
(defun later-messages (session)
  (let ((page (session-page session)) (host (host-of session)))
    (loop
      (let* ((hand (session-hand session)) (read (session-read session)) (have (- (session-said session) read)))
        (unless (>= have 4)
          (return))
        (let ((kind (one (+ hand read))) (bytes (three (+ hand read 1))))
          (unless (>= have (+ 4 bytes))
            (return))
          (setf (session-read session) (+ read 4 bytes))
          (cond ((= kind 4))
                ((= kind 24)
                 (unless (and (= bytes 1) (<= (one (+ hand read 4)) 1) (= (session-read session) (session-said session)))
                   (refuse 47 "~A says that its keys change in a way that is none" host))
                 (renew session (+ page +theirs+) (+ page +their-key+) (+ page +their-count+))
                 (setf (session-heard session) 0)
                 (when (= (one (+ hand read 4)) 1)
                   (setf (session-renew session) t)))
                (t
                 (refuse 10 "~A sent a piece of a greeting after the greeting was over" host))))))
    (when (= (session-read session) (session-said session))
      (setf (session-read session) 0
            (session-said session) 0))))

;;; What lisp/net.lisp is told of (CLARA.NET:*SECURE*)

;; A connection is greeted: what is kept of it, when the other side is the
;; machine that HOST names and the two have their keys. Whatever goes wrong
;; on the way, the other side is told, and what was taken is given back.
(defun open-session (connection host)
  (let* ((page (clara.unsafe:allocate-memory 2))
         (hand (clara.unsafe:allocate-memory +hand-pages+))
         (session (make-session :connection connection :host host :page page :hand hand))
         (done nil) (*alert* nil))
    (unwind-protect
         (progn
           (greet session)
           (setq done t)
           session)
      (unless done
        (setf (session-alert session) (or *alert* 80))
        (close-session session)))))

;; A text is said over the connection, closed.
(defun say (session text)
  (let* ((bytes (clara.unsafe:string-bytes text)) (page (clara.unsafe:allocate-memory 1)))
    (when (> bytes 4000)
      (error "~D bytes are more than is said at once" bytes))
    (unwind-protect
         (progn
           (clara.unsafe:string-memory text page)
           (send-record session 23 page bytes))
      (clara.unsafe:free-memory page 1))))

;; Whatever has arrived is opened: every record that is whole, up to the
;; one in which the other side says that it is done.
(defun take (session)
  (let ((*alert* nil) (fine nil))
    (when (session-alert session)
      (error "the connection to ~A is one on which something went wrong" (host-of session)))
    (unwind-protect
         (progn
           (loop
             (unless (and (not (session-ended session)) (take-record session))
               (return))
             (later-messages session))
           (setq fine t))
      (unless fine
        (setf (session-alert session) (or *alert* 80))))))

;; The connection is over, as far as this side goes: the other side is told
;; so, or told what went wrong, and what was kept of the connection is
;; wiped and given back.
(defun close-session (session)
  (let ((page (session-page session)))
    (when page
      (unwind-protect
           (ignore-errors
             (cond ((eq (session-alert session) :none))
                   ;; a side that has said nothing yet has nothing to take back
                   ((not (session-begun session)))
                   ((session-alert session)
                    (send-alert session 2 (session-alert session)))
                   ((session-open session)
                    (when (session-renew session)
                      (let ((at (+ page +signed+)))
                        (put-one at 24)
                        (put-three (+ at 1) 1)
                        (put-one (+ at 4) 0)
                        (send-record session 22 at 5)
                        (renew session (+ page +ours+) (+ page +our-key+) (+ page +our-count+))
                        (setf (session-sent session) 0)))
                    (send-alert session 1 0))))
        (clear page 8192)
        (setf (session-page session) nil)
        (clara.unsafe:free-memory page 2)
        (clara.unsafe:free-memory (session-hand session) +hand-pages+)))
    nil))

;; A start: what an earlier one read lies in memory that is no longer this
;; system's, and is read again when it is wanted.
(defun start ()
  (setq *system-roots* nil
        *system-read* nil
        *own-roots* nil
        *own-read* 0)
  nil)

(setq clara.net:*secure* (list :open #'open-session :say #'say :take #'take
                               :held #'session-plain :ended #'session-ended :close #'close-session))
