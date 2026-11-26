;;;; format.lisp: the directives of FORMAT
;;;;
;;;; A control string is text with directives in it: a tilde, the
;;;; parameters and the two modifiers that a directive may have, a colon
;;;; and an at-sign, and the character that names it. The substrate does
;;;; five of them, ~A, ~S, ~D, ~% and ~~ with nothing between the tilde and
;;;; the character (kernel/lisp/builtin.c), which is what most control
;;;; strings are made of. A control string with anything else in it comes
;;;; here whole (FORMAT in lisp/boot.lisp, CLARA:PROVIDE-FORMAT): the five
;;;; again, with their parameters and modifiers, columns, numbers in any
;;;; radix, in words and in Roman numerals, and the directives that say
;;;; what the others are given, ~* ~? ~[ ~{ ~^ ~( and ~<.
;;;;
;;;; What is not here: the directives for numbers with a fraction, ~F ~E
;;;; ~G and ~$, since there are no such numbers, and the pretty printer's,
;;;; ~_ ~I ~/ ~:T and a ~< that ends in ~:>, since there is no pretty
;;;; printer.
;;;;
;;;; A control string is taken apart first, into strings and directives,
;;;; with what stands between a ~[, ~{, ~( or ~< and its end inside that
;;;; directive, and then gone through. The text is made in a string stream
;;;; and handed back whole, so that what one call of FORMAT writes reaches
;;;; its stream in one piece, as it always did.
;;;;
;;;; This file loads under SBCL as well, where the tests hold what it makes
;;;; of a control string against what SBCL's own FORMAT makes of it.

(defpackage "CLARA.FORMAT"
  (:use "COMMON-LISP"))
(in-package "CLARA.FORMAT")

;;; One call of FORMAT

(defstruct job
  control      ; the control string that is being gone through, for what an error says
  out          ; where the text goes, a string stream
  (column 0)   ; how many characters the line has that is being written
  fresh        ; nothing has been written since the last new line
  all          ; the arguments that ~* counts in
  rest         ; the ones that are still to come
  outside      ; within ~:{ the lists that are still to come, which ~:^ asks about
  within)      ; within ~:{, the one place where a ~:^ may stand

;; TEXT is written, and the job knows where its line stands afterwards.
(defun emit (job text)
  (let ((length (length text)))
    (when (plusp length)
      (write-string text (job-out job))
      (let ((i length))
        (loop
          (when (or (zerop i) (char= (char text (1- i)) #\Newline))
            (return))
          (decf i))
        (setf (job-column job) (if (zerop i) (+ (job-column job) length) (- length i)))
        (setf (job-fresh job) (= i length))))))

;; The character C, TIMES times.
(defun emit-many (job times c)
  (when (plusp times)
    (unless (characterp c)
      (error "FORMAT wants a character to pad with in ~S, and ~S is not one" (job-control job) c))
    (emit job (make-string times :initial-element c))))

;; The next argument.
(defun next (job)
  (let ((rest (job-rest job)))
    (when (null rest)
      (error "FORMAT has no argument left for a directive of ~S" (job-control job)))
    (setf (job-rest job) (cdr rest))
    (car rest)))

;;; The pieces of a control string

(defstruct directive
  letter       ; the character that names it, a capital for a letter
  parameters   ; what stands before it: an integer or a character as it is written, :NEXT for a V,
               ; :LEFT for a #, and NIL for one that was left out
  colon        ; the two modifiers
  at
  clauses      ; of ~[ ~{ ~( and ~<: what stands between it and its end, the pieces of each part
  dividers     ; the ~; between those parts
  end)         ; and the directive that ends it

(defun digit-p (c)
  (< 47 (char-code c) 58))

;; The directive whose tilde is at START, and where the control string goes
;; on after it. Parameters have commas between them, and one that is left
;; out is NIL: ~,5D has two.
(defun read-directive (job start)
  (let* ((control (job-control job)) (end (length control)) (i (1+ start))
         (parameters nil) (comma nil) (colon nil) (at nil))
    (flet ((peek ()
             (when (>= i end)
               (error "FORMAT finds the end of ~S in the middle of a directive" control))
             (char control i)))
      (loop
        (let ((c (peek)) (parameter nil))
          (cond ((or (digit-p c) (char= c #\+) (char= c #\-))
                 (let ((value 0) (digits 0))
                   (unless (digit-p c)
                     (incf i))
                   (loop
                     (unless (and (< i end) (digit-p (char control i)))
                       (return))
                     (setq value (+ (* value 10) (- (char-code (char control i)) 48)))
                     (incf digits)
                     (incf i))
                   (when (plusp digits)           ; a sign alone is a parameter that was left out
                     (setq parameter (if (char= c #\-) (- value) value)))))
                ((or (char= c #\v) (char= c #\V))
                 (incf i)
                 (setq parameter :next))
                ((char= c #\#)
                 (incf i)
                 (setq parameter :left))
                ((char= c #\')
                 (incf i)
                 (setq parameter (peek))
                 (incf i)))
          (cond ((char= (peek) #\,)
                 (push parameter parameters)
                 (setq comma t)
                 (incf i))
                (t
                 (when (or parameter comma)
                   (push parameter parameters))
                 (return)))))
      (loop
        (let ((c (peek)))
          (cond ((char= c #\:)
                 (when colon
                   (error "FORMAT finds two colons at one directive of ~S" control))
                 (setq colon t))
                ((char= c #\@)
                 (when at
                   (error "FORMAT finds two at-signs at one directive of ~S" control))
                 (setq at t))
                (t (return)))
          (incf i)))
      (values (make-directive :letter (char-upcase (peek)) :parameters (nreverse parameters) :colon colon :at at)
              (1+ i)))))

;; The pieces from START on, strings and directives, as far as the end of
;; the control string or the first directive that ENDS names, a string of
;; letters, when it is one: the pieces, where the control string goes on,
;; and the directive that ended them. A tilde before the end of a line
;; takes the line's end and the blanks after it out of the text, the blanks
;; only with an at-sign, and the end only with a colon; what it leaves is a
;; piece, if an empty one, so that a ~{ with nothing else in it has a body.
(defun read-pieces (job start ends)
  (let* ((control (job-control job)) (end (length control)) (pieces nil) (i start) (ended nil))
    (loop
      (let ((tilde (or (position #\~ control :start i) end)))
        (when (< i tilde)
          (push (subseq control i tilde) pieces))
        (setq i tilde)
        (when (= tilde end)
          (return))
        (multiple-value-bind (directive next) (read-directive job tilde)
          (let ((letter (directive-letter directive)))
            (setq i next)
            (cond ((and ends (find letter ends))
                   (setq ended directive)
                   (return))
                  ((char= letter #\Newline)
                   (when (or (directive-parameters directive) (and (directive-colon directive) (directive-at directive)))
                     (error "FORMAT finds a tilde before the end of a line in ~S with more than a colon or an at-sign"
                            control))
                   (push (if (directive-at directive) (string #\Newline) "") pieces)
                   (unless (directive-colon directive)
                     (loop
                       (unless (and (< i end) (member (char-code (char control i)) '(32 9 10)))
                         (return))
                       (incf i))))
                  ((find letter "([{<")
                   (setq i (read-clauses job directive next))
                   (push directive pieces))
                  ((find letter ")]}>")
                   (error "FORMAT finds a ~~~A in ~S with nothing before it for it to end" letter control))
                  ((char= letter #\;)
                   (error "FORMAT finds a ~~; in ~S that is not between a ~~[ or a ~~< and its end" control))
                  (t (push directive pieces)))))))
    (values (nreverse pieces) i ended)))

;; Whether one of the pieces of CLAUSES, or of the pieces inside those, is
;; the directive of LETTER.
(defun holds-p (clauses letter)
  (let ((found nil))
    (dolist (pieces clauses)
      (dolist (piece pieces)
        (when (and (not (stringp piece))
                   (or (char= (directive-letter piece) letter) (holds-p (directive-clauses piece) letter)))
          (setq found t))))
    found))

;; What stands between the directive OPENER, which the control string has
;; just had, and its end is read into it: the parts that ~; divides, the
;; dividers, and the end. Where the control string goes on. A ~W is the
;; pretty printer's as well as the printer's, and Common Lisp has none in
;; a field.
(defun read-clauses (job opener start)
  (let* ((letter (directive-letter opener))
         (closer (char ")]}>" (position letter "([{<")))
         (ends (if (or (char= letter #\[) (char= letter #\<))
                   (concatenate 'string (string closer) ";")
                   (string closer)))
         (clauses nil) (dividers nil) (i start))
    (loop
      (multiple-value-bind (pieces next end) (read-pieces job i ends)
        (unless end
          (error "FORMAT finds no ~~~A in ~S to end its ~~~A" closer (job-control job) letter))
        (push pieces clauses)
        (setq i next)
        (cond ((char= (directive-letter end) #\;)
               (push end dividers))
              (t
               (setf (directive-clauses opener) (nreverse clauses))
               (setf (directive-dividers opener) (nreverse dividers))
               (setf (directive-end opener) end)
               (return)))))
    (when (and (char= letter #\<) (not (directive-colon (directive-end opener)))
               (holds-p (directive-clauses opener) #\W))
      (error "FORMAT finds a ~~W between a ~~< and its ~~> in ~S, where there can be none" (job-control job)))
    i))

;;; What a directive is given

;; What the parameters of DIRECTIVE come to, one for each of DEFAULTS: a V
;; takes an argument, a # is how many arguments are left, and a default is
;; what a parameter is when it was left out or a V found NIL for it. Where
;; the default is a number the parameter has to be one; a character to pad
;; with is looked at when there is something to pad.
(defun settle (job directive defaults)
  (let ((given (directive-parameters directive)) (settled nil))
    (when (> (length given) (length defaults))
      (error "FORMAT finds ~D parameters at a ~~~A in ~S, which takes ~D at the most"
             (length given) (directive-letter directive) (job-control job) (length defaults)))
    (dolist (default defaults)
      (let* ((parameter (car given))
             (value (cond ((eq parameter :next) (or (next job) default))
                          ((eq parameter :left) (length (job-rest job)))
                          ((null parameter) default)
                          (t parameter))))
        (when (and (integerp default) (not (integerp value)))
          (error "FORMAT wants a number for a parameter of the ~~~A in ~S, and ~S is not one"
                 (directive-letter directive) (job-control job) value))
        (setq given (cdr given))
        (push value settled)))
    (nreverse settled)))

(defun refuse (job directive what)
  (error "FORMAT finds ~A at a ~~~A in ~S, which has no use for it"
         what (directive-letter directive) (job-control job)))

(defun no-colon (job directive)
  (when (directive-colon directive)
    (refuse job directive "a colon")))

(defun no-at (job directive)
  (when (directive-at directive)
    (refuse job directive "an at-sign")))

(defun not-both (job directive)
  (when (and (directive-colon directive) (directive-at directive))
    (refuse job directive "both a colon and an at-sign")))

;; A divided by B and rounded up, for a B above nought.
(defun up (a b)
  (let ((whole (floor a b)))
    (if (= (* whole b) a) whole (1+ whole))))

;;; Fields

;; TEXT in a field of MINCOL characters at the least: MINPAD copies of PAD
;; beside it, and then COLINC more at a time until the field is as wide as
;; that. The padding is on the left of the text when LEFT says so.
(defun field (job text mincol colinc minpad pad left)
  (when (or (< colinc 1) (minusp mincol))
    (error "FORMAT cannot make a field of ~D characters that grows by ~D, as ~S asks" mincol colinc (job-control job)))
  (let* ((padding (max minpad 0)) (width (+ (length text) padding)))
    (loop
      (when (>= width mincol)
        (return))
      (setq padding (+ padding colinc))
      (setq width (+ width colinc)))
    (unless left
      (emit job text))
    (emit-many job padding pad)
    (when left
      (emit job text))))

;; ~A and ~S: an argument as PRINC or PRIN1 writes it, in a field when
;; there are parameters; with a colon NIL is ().
(defun object (job directive escape)
  (let* ((settled (settle job directive '(0 1 0 #\Space)))
         (object (next job))
         (text (cond ((and (null object) (directive-colon directive)) "()")
                     (escape (prin1-to-string object))
                     (t (princ-to-string object)))))
    (if (directive-parameters directive)
        (field job text (first settled) (second settled) (third settled) (fourth settled) (directive-at directive))
        (emit job text))))

;;; Numbers

(defun string-of (chars)
  (let ((text (make-string (length chars))) (i 0))
    (dolist (c chars)
      (setf (char text i) c)
      (incf i))
    text))

;; The digits of NUMBER in a radix, without its sign.
(defun digits (number radix)
  (if (= radix 10)
      (let ((text (princ-to-string number)))
        (if (minusp number) (subseq text 1) text))
      (let ((digits nil) (left number))
        (loop
          (let ((digit (rem left radix)))
            (push (char "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" (if (minusp digit) (- digit) digit)) digits))
          (setq left (truncate left radix))
          (when (zerop left)
            (return)))
        (string-of digits))))

;; DIGITS with COMMA between every INTERVAL of them, counted from the right.
(defun grouped (digits comma interval)
  (let* ((length (length digits))
         (commas (truncate (1- length) interval))
         (text (make-string (+ length commas)))
         (from length) (to (+ length commas)) (run 0))
    (loop
      (when (zerop from)
        (return))
      (when (= run interval)
        (decf to)
        (setf (char text to) comma)
        (setq run 0))
      (decf from)
      (decf to)
      (setf (char text to) (char digits from))
      (incf run))
    text))

;; ~D ~B ~O ~X, and ~R with a radix: an integer in a field, with a sign for
;; an at-sign and with commas for a colon. Anything else is written as ~A
;; writes it.
(defun whole-number (job directive radix settled)
  (unless (and (integerp radix) (< 1 radix 37))
    (error "FORMAT writes numbers in a radix from 2 to 36, and ~S asks for ~S" (job-control job) radix))
  (let ((number (next job)))
    (if (integerp number)
        (let ((text (digits number radix)))
          (when (directive-colon directive)
            (when (< (fourth settled) 1)
              (error "FORMAT cannot put a comma after every ~D digits, as ~S asks" (fourth settled) (job-control job)))
            (setq text (grouped text (third settled) (fourth settled))))
          (cond ((minusp number) (setq text (concatenate 'string "-" text)))
                ((directive-at directive) (setq text (concatenate 'string "+" text))))
          (field job text (first settled) 1 0 (second settled) t))
        (emit job (princ-to-string number)))))

;;; Numbers in words

(defvar *ones* '(nil "one" "two" "three" "four" "five" "six" "seven" "eight" "nine"))
(defvar *teens* '("ten" "eleven" "twelve" "thirteen" "fourteen" "fifteen" "sixteen" "seventeen" "eighteen" "nineteen"))
(defvar *tens* '(nil nil "twenty" "thirty" "forty" "fifty" "sixty" "seventy" "eighty" "ninety"))
(defvar *ordinal-ones* '(nil "first" "second" "third" "fourth" "fifth" "sixth" "seventh" "eighth" "ninth"))
(defvar *ordinal-tens* '(nil "tenth" "twentieth" "thirtieth" "fortieth" "fiftieth" "sixtieth" "seventieth" "eightieth"
                         "ninetieth"))
(defvar *periods* '("" " thousand" " million" " billion" " trillion" " quadrillion" " quintillion" " sextillion"
                    " septillion" " octillion" " nonillion" " decillion" " undecillion" " duodecillion"
                    " tredecillion" " quattuordecillion" " quindecillion" " sexdecillion" " septendecillion"
                    " octodecillion" " novemdecillion" " vigintillion"))

;; A number from 1 to 999.
(defun write-hundreds (number out)
  (multiple-value-bind (hundreds below) (truncate number 100)
    (when (plusp hundreds)
      (write-string (nth hundreds *ones*) out)
      (write-string " hundred" out)
      (when (plusp below)
        (write-string " " out)))
    (when (plusp below)
      (multiple-value-bind (tens ones) (truncate below 10)
        (cond ((< 1 tens)
               (write-string (nth tens *tens*) out)
               (when (plusp ones)
                 (write-string "-" out)
                 (write-string (nth ones *ones*) out)))
              ((= tens 1) (write-string (nth ones *teens*) out))
              (t (write-string (nth ones *ones*) out)))))))

;; A number above nought, three digits at a time: PERIOD is how many such
;; threes stand to the right of NUMBER.
(defun write-cardinal (number period out)
  (multiple-value-bind (beyond here) (truncate number 1000)
    (when (> period 21)
      (error "FORMAT has no words for a number of more than 66 digits"))
    (unless (zerop beyond)
      (write-cardinal beyond (1+ period) out))
    (unless (zerop here)
      (unless (zerop beyond)
        (write-string " " out))
      (write-hundreds here out)
      (write-string (nth period *periods*) out))))

;; ~R: one, two, three.
(defun cardinal (number)
  (with-output-to-string (out)
    (cond ((zerop number) (write-string "zero" out))
          (t
           (when (minusp number)
             (write-string "negative " out))
           (write-cardinal (abs number) 0 out)))))

;; ~:R: first, second, third.
(defun ordinal (number)
  (with-output-to-string (out)
    (when (minusp number)
      (write-string "negative " out))
    (let ((number (abs number)))
      (multiple-value-bind (top bottom) (truncate number 100)
        (unless (zerop top)
          (write-cardinal (- number bottom) 0 out))
        (when (and (plusp top) (plusp bottom))
          (write-string " " out))
        (multiple-value-bind (tens ones) (truncate bottom 10)
          (cond ((= bottom 12) (write-string "twelfth" out))
                ((= tens 1)
                 (write-string (nth ones *teens*) out)
                 (write-string "th" out))
                ((and (zerop tens) (plusp ones)) (write-string (nth ones *ordinal-ones*) out))
                ((and (zerop ones) (plusp tens)) (write-string (nth tens *ordinal-tens*) out))
                ((plusp bottom)
                 (write-string (nth tens *tens*) out)
                 (write-string "-" out)
                 (write-string (nth ones *ordinal-ones*) out))
                ((plusp number) (write-string "th" out))
                (t (write-string "zeroth" out))))))))

(defvar *roman* '((1000 . "M") (900 . "CM") (500 . "D") (400 . "CD") (100 . "C") (90 . "XC") (50 . "L") (40 . "XL")
                  (10 . "X") (9 . "IX") (5 . "V") (4 . "IV") (1 . "I")))

;; ~@R: IV, and ~:@R, the old way, with no numeral that takes away: IIII.
(defun roman (number old)
  (unless (< 0 number (if old 5000 4000))
    (error "FORMAT writes the numbers from 1 to ~D in Roman numerals~A, and ~D is not one of them"
           (if old 4999 3999) (if old " of the old kind" "") number))
  (with-output-to-string (out)
    (let ((left number))
      (dolist (numeral *roman*)
        (unless (and old (= (length (cdr numeral)) 2))
          (loop
            (when (< left (car numeral))
              (return))
            (write-string (cdr numeral) out)
            (setq left (- left (car numeral)))))))))

;;; Characters and the case of letters

;; What ~:C writes: the character, or its name when it is one that shows
;; nothing, the name that the printer writes after #\.
(defun spelled (c)
  (let ((text (prin1-to-string c)))
    (cond ((char= c #\Space) "Space")
          ((> (length text) 3) (subseq text 2))
          (t (string c)))))

;; What a word is made of: a letter or a digit.
(defun constituent-p (c)
  (let ((code (char-code c)))
    (or (< 47 code 58) (< 64 code 91) (< 96 code 123) (> code 127))))

;; TEXT with a capital at the beginning of every word and small letters
;; after it, or, unless EVERY, with a capital at the beginning of its first
;; word and small letters from there on.
(defun capitalized (text every)
  (let* ((length (length text)) (new (make-string length)) (inside nil) (done nil))
    (dotimes (i length)
      (let ((c (char text i)))
        (setf (char new i)
              (cond ((not (constituent-p c))
                     (setq inside nil)
                     c)
                    ((or inside done) (char-downcase c))
                    (t
                     (setq inside t)
                     (unless every
                       (setq done t))
                     (char-upcase c))))))
    new))

;; ~( to ~): what stands between them is written first, and then its
;; letters are made small, or capitals, as the modifiers say. What had been
;; written when something left in the middle, a ~^, is written too.
(defun convert (job directive)
  (settle job directive '())
  (let ((out (job-out job)) (inner (make-string-output-stream)))
    (setf (job-out job) inner)
    (unwind-protect (run job (car (directive-clauses directive)))
      (setf (job-out job) out)
      (let ((text (get-output-stream-string inner)))
        (write-string (cond ((and (directive-colon directive) (directive-at directive)) (string-upcase text))
                            ((directive-colon directive) (capitalized text t))
                            ((directive-at directive) (capitalized text nil))
                            (t (string-downcase text)))
                      out)))))

;;; Which arguments, and which part

;; ~*: N arguments are passed over; with a colon the N before are to come
;; again; with an at-sign the next one is the one of the number N, the
;; first being 0.
(defun move (job directive)
  (not-both job directive)
  (let* ((all (job-all job))
         (n (car (settle job directive (if (directive-at directive) '(0) '(1)))))
         (to (if (directive-at directive) n (- (- (length all) (length (job-rest job))) n))))
    (cond ((not (or (directive-colon directive) (directive-at directive)))
           (dotimes (i n)
             (next job)))
          ((<= 0 to (length all))
           (setf (job-rest job) (nthcdr to all)))
          (t (error "FORMAT cannot go to the argument ~D of ~D, as ~S asks" to (length all) (job-control job))))))

;; Another control string in the middle of this one. A ~^ in it ends it,
;; and no more.
(defun inner (job control)
  (let ((outer (job-control job)))
    (setf (job-control job) control)
    (catch 'out
      (run job (read-pieces job 0 nil)))
    (setf (job-control job) outer)))

;; ~?: an argument is a control string, and the next the list of its
;; arguments; with an at-sign it goes on with the arguments that are here.
(defun indirect (job directive)
  (no-colon job directive)
  (settle job directive '())
  (let ((control (next job)))
    (unless (stringp control)
      (error "FORMAT wants a control string for the ~~? in ~S, and ~S is not one" (job-control job) control))
    (if (directive-at directive)
        (inner job control)
        (let ((arguments (next job)) (all (job-all job)) (rest (job-rest job)))
          (unless (listp arguments)
            (error "FORMAT wants a list of arguments for the ~~? in ~S, and ~S is not one" (job-control job) arguments))
          (setf (job-all job) arguments)
          (setf (job-rest job) arguments)
          (inner job control)
          (setf (job-all job) all)
          (setf (job-rest job) rest)))))

;; ~[ to ~]: one of the parts between them is gone through, the one that an
;; argument counts to, the first being 0, or the last when a ~:; stands
;; before it and the number names none. With a colon there are two parts,
;; one for NIL and one for anything else; with an at-sign there is one,
;; for an argument that is not NIL, which is then still to come.
(defun choose (job directive)
  (not-both job directive)
  (let ((clauses (directive-clauses directive)) (control (job-control job)))
    (cond ((directive-at directive)
           (settle job directive '())
           (when (cdr clauses)
             (error "FORMAT finds a ~~@[ of more than one part in ~S" control))
           (let ((rest (job-rest job)))
             (when (next job)
               (setf (job-rest job) rest)
               (run job (car clauses)))))
          ((directive-colon directive)
           (settle job directive '())
           (unless (= (length clauses) 2)
             (error "FORMAT finds a ~~:[ in ~S that has not two parts" control))
           (run job (if (next job) (second clauses) (first clauses))))
          (t
           (let* ((index (or (car (settle job directive '(nil))) (next job)))
                  (divider (car (last (directive-dividers directive))))
                  (fallback (and divider (directive-colon divider)))
                  (plain (if fallback (1- (length clauses)) (length clauses))))
             (unless (integerp index)
               (error "FORMAT wants a number to pick a part of the ~~[ in ~S by, and ~S is not one" control index))
             (cond ((< -1 index plain) (run job (nth index clauses)))
                   (fallback (run job (car (last clauses))))))))))

;; ~{ to ~}: what stands between them is gone through again and again, as
;; long as there are arguments for it. They are the items of a list that is
;; an argument; with an at-sign the arguments that are left here; and with
;; a colon each time through has a list of its own, an item of that list
;; or, with both, one of the arguments here. A parameter says how many
;; times at the most, ~:} at the end that once is the least, and with
;; nothing in between the control string is an argument too.
(defun iterate (job directive)
  (let* ((limit (car (settle job directive '(nil))))
         (body (car (directive-clauses directive)))
         (once (directive-colon (directive-end directive)))
         (control (job-control job))
         (string (if (null body) (next job)))   ; looked at when it is first gone through
         (all (job-all job)) (rest (job-rest job))
         (within (job-within job)) (outside (job-outside job)))
    (when (and limit (not (integerp limit)))
      (error "FORMAT wants a number for how many times the ~~{ in ~S goes round, and ~S is not one" control limit))
    (flet ((over-p (left)                ; before a time through: nothing is left, or the times are used up
             (or (and (not once) (null left))
                 (and limit (minusp (setq limit (1- limit))))))
           (turn ()
             (cond ((car (directive-clauses directive)) (run job body))
                   (t
                    (unless (stringp string)
                      (error "FORMAT wants a control string for the ~~{~~} in ~S, and ~S is not one" control string))
                    (setf (job-control job) string)
                    (unless body
                      (setq body (read-pieces job 0 nil)))
                    (catch 'out
                      (run job body))
                    (setf (job-control job) control))))
           (items (list)
             (unless (listp list)
               (error "FORMAT wants a list to go through for the ~~{ in ~S, and ~S is not one" control list))
             list))
      (cond ((not (directive-colon directive))
             (unless (directive-at directive)
               (let ((list (items (next job))))
                 (setq rest (job-rest job))
                 (setf (job-all job) list)
                 (setf (job-rest job) list)))
             (setf (job-within job) nil)
             (catch 'out
               (loop
                 (when (over-p (job-rest job))
                   (return))
                 (turn)
                 (when (and once (null (job-rest job)))
                   (return))))
             (unless (directive-at directive)
               (setf (job-all job) all)
               (setf (job-rest job) rest)))
            (t
             (let ((lists (if (directive-at directive) rest (items (next job)))))
               (unless (directive-at directive)
                 (setq rest (job-rest job)))
               (setf (job-within job) t)
               (catch 'all-out
                 (loop
                   (when (over-p lists)
                     (return))
                   (when (null lists)
                     (error "FORMAT has no argument left for a directive of ~S" control))
                   (let ((list (items (car lists))))
                     (setq lists (cdr lists))
                     (setf (job-all job) list)
                     (setf (job-rest job) list)
                     (setf (job-outside job) lists)
                     (catch 'out
                       (turn))
                     (setf (job-control job) control))
                   (when (and once (null lists))
                     (return))))
               (setf (job-all job) all)
               (setf (job-rest job) (if (directive-at directive) lists rest)))))
      (setf (job-control job) control)
      (setf (job-within job) within)
      (setf (job-outside job) outside))))

;; ~^: what the directive around it was doing ends here when no argument
;; is left: a time through a ~{ and all the times after it, a ~< with the
;; part that it is in, a control string that a ~? named, or else the whole
;; control string. With parameters it asks them and not the arguments: one
;; that is 0, two that are the same, three in their order. ~:^ ends a ~:{
;; when no list is left for it.
(defun leave (job directive)
  (no-at job directive)
  (when (and (directive-colon directive) (not (job-within job)))
    (error "FORMAT finds a ~~:^ in ~S that is not between a ~~:{ and its end" (job-control job)))
  (let* ((settled (settle job directive '(nil nil nil)))
         (one (first settled)) (two (second settled)) (three (third settled)))
    (when (cond (three (<= one two three))
                (two (eql one two))
                (one (eql one 0))
                ((directive-colon directive) (null (job-outside job)))
                (t (null (job-rest job))))
      (throw (if (directive-colon directive) 'all-out 'out) nil))))

;; ~P: an s unless the argument is 1, or with an at-sign a y for 1 and ies
;; otherwise; with a colon it is the argument before that is asked.
(defun plural (job directive)
  (settle job directive '())
  (let ((number (if (directive-colon directive)
                    (let ((all (job-all job)) (rest (job-rest job)))
                      (when (eq all rest)
                        (error "FORMAT has no argument before the ~~:P in ~S" (job-control job)))
                      (loop
                        (when (eq (cdr all) rest)
                          (return (car all)))
                        (setq all (cdr all))))
                    (next job))))
    (emit job (cond ((directive-at directive) (if (eql number 1) "y" "ies"))
                    ((eql number 1) "")
                    (t "s")))))

;;; Columns

;; ~T: blanks as far as a column, the first of a line being 0, and when the
;; line is there already, as far as the next column that is a number of
;; COLINCs after it. With an at-sign so many blanks, and then as far as a
;; column that COLINC divides. A line that this call did not begin is taken
;; to have begun where the call did.
(defun tabulate (job directive)
  (when (directive-colon directive)
    (error "FORMAT has no pretty printer, which the ~~:T in ~S is for" (job-control job)))
  (let* ((settled (settle job directive '(1 1)))
         (to (first settled)) (colinc (second settled)) (column (job-column job)))
    (emit-many job
               (cond ((directive-at directive)
                      (if (plusp colinc) (- (* colinc (up (+ column to) colinc)) column) to))
                     ((< column to) (- to column))
                     ((zerop colinc) 0)
                     (t (- colinc (rem (- column to) colinc))))
               #\Space)))

;; What PIECES write, as a string by itself, a line of its own.
(defun captured (job pieces)
  (let ((inner (make-string-output-stream)))
    (setf (job-out job) inner)
    (setf (job-column job) 0)
    (setf (job-fresh job) t)
    (run job pieces)
    (get-output-stream-string inner)))

;; ~< to ~>: the parts between them are written into a field of MINCOL
;; characters, the first against its left edge and the last against its
;; right, with the padding shared out between them; one part alone goes to
;; the right. A colon pads before the first part as well, and an at-sign
;; after the last. A ~^ in a part leaves the field with the parts before
;; it. When the first part ends in ~:; it is no part of the field: it is
;; written before it when the field would not fit on the line, which is
;; as long as that directive's second parameter says, or 72, with as many
;; characters to spare as its first.
(defun justify (job directive)
  (when (directive-colon (directive-end directive))
    (error "FORMAT has no pretty printer, which the ~~< to ~~:> in ~S is for" (job-control job)))
  (let* ((settled (settle job directive '(0 1 0 #\Space)))
         (mincol (first settled)) (colinc (second settled)) (minpad (third settled)) (pad (fourth settled))
         (clauses (directive-clauses directive))
         (divider (car (directive-dividers directive)))
         (out (job-out job)) (column (job-column job)) (fresh (job-fresh job))
         (before nil) (spare 0) (line 72) (texts nil))
    (unwind-protect
         (catch 'out
           (when (and divider (directive-colon divider))
             (let ((numbers (settle job divider '(0 72))))
               (setq before (captured job (car clauses)))
               (setq clauses (cdr clauses))
               (setq spare (first numbers))
               (setq line (second numbers))))
           (dolist (clause clauses)
             (push (captured job clause) texts)))
      (setf (job-out job) out)
      (setf (job-column job) column)
      (setf (job-fresh job) fresh))
    (setq texts (nreverse texts))
    (let* ((gaps (+ (1- (length texts)) (if (directive-colon directive) 1 0) (if (directive-at directive) 1 0)))
           (chars (* gaps minpad)) (width mincol) (padding 0))
      (dolist (text texts)
        (setq chars (+ chars (length text))))
      (when (> chars mincol)
        (when (< colinc 1)
          (error "FORMAT cannot make a field that grows by ~D, as ~S asks" colinc (job-control job)))
        (setq width (+ mincol (* colinc (up (- chars mincol) colinc)))))
      (setq padding (+ (- width chars) (* gaps minpad)))
      (when (and before (> (+ column width spare) line))
        (emit job before))
      (flet ((pad-out ()
               (let ((share (if (zerop gaps) padding (truncate padding gaps))))
                 (setq padding (- padding share))
                 (setq gaps (1- gaps))
                 (emit-many job share pad))))
        (when (or (directive-colon directive) (and (not (directive-at directive)) (null (cdr texts))))
          (pad-out))
        (when texts
          (emit job (car texts))
          (dolist (text (cdr texts))
            (pad-out)
            (emit job text)))
        (when (directive-at directive)
          (pad-out))))))

;;; Going through the pieces

;; ~%, ~|, ~~ and the like: a character so many times.
(defun repeated (job directive c)
  (no-colon job directive)
  (no-at job directive)
  (emit-many job (car (settle job directive '(1))) c))

(defun obey (job directive)
  (let ((letter (directive-letter directive)))
    (case letter
      (#\A (object job directive nil))
      (#\S (object job directive t))
      (#\D (whole-number job directive 10 (settle job directive '(0 #\Space #\, 3))))
      (#\% (repeated job directive #\Newline))
      (#\~ (repeated job directive #\~))
      (#\& (no-colon job directive)
           (no-at job directive)
           (let ((times (car (settle job directive '(1)))))
             (when (plusp times)
               (unless (job-fresh job)
                 (emit job (string #\Newline)))
               (emit-many job (1- times) #\Newline))))
      (#\{ (iterate job directive))
      (#\^ (leave job directive))
      (#\[ (choose job directive))
      (#\T (tabulate job directive))
      (#\( (convert job directive))
      (#\* (move job directive))
      (#\P (plural job directive))
      (#\C (settle job directive '())
           (let ((c (next job)))
             (unless (characterp c)
               (error "FORMAT wants a character for the ~~C in ~S, and ~S is not one" (job-control job) c))
             (emit job (cond ((directive-colon directive) (spelled c))
                             ((directive-at directive) (prin1-to-string c))
                             (t (string c))))))
      (#\X (whole-number job directive 16 (settle job directive '(0 #\Space #\, 3))))
      (#\B (whole-number job directive 2 (settle job directive '(0 #\Space #\, 3))))
      (#\O (whole-number job directive 8 (settle job directive '(0 #\Space #\, 3))))
      (#\R (let* ((settled (settle job directive '(nil 0 #\Space #\, 3))) (radix (car settled)))
             (if radix
                 (whole-number job directive radix (cdr settled))
                 (let ((number (next job)))
                   (unless (integerp number)
                     (error "FORMAT wants an integer to write in words for the ~~R in ~S, and ~S is not one"
                            (job-control job) number))
                   (emit job (cond ((and (directive-colon directive) (directive-at directive)) (roman number t))
                                   ((directive-at directive) (roman number nil))
                                   ((directive-colon directive) (ordinal number))
                                   (t (cardinal number))))))))
      (#\? (indirect job directive))
      (#\< (justify job directive))
      (#\W (settle job directive '())
           (emit job (prin1-to-string (next job))))
      (#\| (repeated job directive (code-char 12)))
      (t (error "FORMAT does not know the directive ~S in ~S" letter (job-control job))))))

(defun run (job pieces)
  (dolist (piece pieces)
    (if (stringp piece)
        (emit job piece)
        (obey job piece))))

;; What FORMAT makes of a control string and its arguments. FRESH says
;; that the text begins a line, which a ~& at its beginning asks about.
(defun formatted (control arguments fresh)
  (let ((job (make-job :control control :out (make-string-output-stream) :fresh fresh
                       :all arguments :rest arguments)))
    (catch 'out
      (run job (read-pieces job 0 nil)))
    (get-output-stream-string (job-out job))))

(clara:provide-format #'formatted)
