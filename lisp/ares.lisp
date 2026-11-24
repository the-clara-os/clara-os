;;;; ares.lisp: Ares, a web browser
;;;;
;;;; An application (lisp/windows.lisp): a window that shows a page of the
;;;; web, what it says, and goes where its links lead. The row at its top
;;;; has the address of the page, and takes another when Ctrl-L is typed or
;;;; the row is clicked; Tab picks the next link and Enter follows it, as a
;;;; click on a link does; Alt with the arrow to the left, or Backspace,
;;;; goes back to the page before, and Alt with the arrow to the right on
;;;; again; Ctrl-R asks for the page once more; the arrows, Page Up, Page
;;;; Down, Home and End move the page; and Ctrl-Q closes the window, as its
;;;; close box does.
;;;;
;;;; A page is asked for by HTTPS and by nothing else (lisp/net.lisp,
;;;; lisp/tls.lisp): an address that is written with http:// is asked for
;;;; with https:// in its place. What arrives is bytes, which are read as
;;;; text; the text is read into a tree of its elements, by the rules that
;;;; browsers read a page by, so that a page which leaves out what pages
;;;; leave out is here the page that it is elsewhere; the tree is laid out
;;;; as lines of text for the width of the window, each element as its kind
;;;; looks: headings, paragraphs, lists, tables, text as it is typed,
;;;; links; and the lines are drawn in the system's fonts (lisp/type.lisp).
;;;;
;;;; What is not here: nothing that a page says about its looks is read
;;;; (style sheets); no picture is fetched, and the words that a page has
;;;; for one stand in its place; no script is run; and a form shows its
;;;; fields and cannot be filled in or sent. A page that is put together by
;;;; its scripts shows what it has without them, which may be nothing.
;;;;
;;;; This file is not part of the world that the kernel loads. The launcher
;;;; loads it when Ares is first picked, and CLARA.WINDOWS:UNLOAD-APPLICATION
;;;; takes it out again. It loads under SBCL as well, where lisp/host/
;;;; stands in for the machine.

(defpackage "CLARA.ARES"
  (:use "COMMON-LISP")
  (:export "BROWSE" "*HOME*"))
(in-package "CLARA.ARES")

;;; Characters, and where a word stands in a text
;;;
;;; A page is somebody else's, and so is every address in it: nothing here
;;; takes a character for what it should be without having looked.

;; Is the character with this code white space, as a page counts it: a
;; space, a tab, a new line, a form feed or a return?
(defun space-p (code)
  (or (= code 32) (= code 10) (= code 9) (= code 13) (= code 12)))

(defun letter-p (code)
  (or (and (>= code 97) (<= code 122)) (and (>= code 65) (<= code 90))))

(defun digit-p (code)
  (and (>= code 48) (<= code 57)))

;; The code of the small letter of a letter's code, and any other code as
;; it is.
(defun small (code)
  (if (and (>= code 65) (<= code 90)) (+ code 32) code))

;; Is ITEM one of ITEMS, the very same?
(defun in (item items)
  (loop
    (when (null items)
      (return nil))
    (when (eq item (car items))
      (return t))
    (setq items (cdr items))))

;; Is a text white space and nothing else?
(defun blank-p (text)
  (let ((i 0) (end (length text)))
    (loop
      (when (>= i end)
        (return t))
      (unless (space-p (char-code (char text i)))
        (return nil))
      (setq i (+ i 1)))))

;; Does WORD, which is in small letters, stand in TEXT at the place AT, in
;; letters of either kind?
(defun stands-at (text at word)
  (let ((length (length word)) (i 0))
    (and (<= (+ at length) (length text))
         (loop
           (when (>= i length)
             (return t))
           (unless (= (small (char-code (char text (+ at i)))) (char-code (char word i)))
             (return nil))
           (setq i (+ i 1))))))

;; The first place from FROM on where WORD stands in TEXT, or NIL.
(defun seek (text word from)
  (let ((last (- (length text) (length word))))
    (loop
      (when (> from last)
        (return nil))
      (when (stands-at text from word)
        (return from))
      (setq from (+ from 1)))))

;; The first place from FROM on, and before END, where the character with
;; the code CODE is, or END.
(defun place-of (code text from end)
  (loop
    (when (or (>= from end) (= (char-code (char text from)) code))
      (return from))
    (setq from (+ from 1))))

;; The first place from FROM on that is not white space, or END.
(defun past-space (text from end)
  (loop
    (when (or (>= from end) (not (space-p (char-code (char text from)))))
      (return from))
    (setq from (+ from 1))))

;; A text without the white space at its two ends.
(defun trimmed (text)
  (let* ((end (length text)) (from (past-space text 0 end)))
    (loop
      (when (or (<= end from) (not (space-p (char-code (char text (- end 1))))))
        (return))
      (setq end (- end 1)))
    (subseq text from end)))

;; The number that a text is in the digits of BASE, ten or sixteen, or NIL
;; for a text that is none, or one too long to be meant.
(defun number-in (text base)
  (let ((number 0) (i 0) (end (length text)))
    (and (< 0 end 10)
         (loop
           (when (>= i end)
             (return number))
           (let* ((code (small (char-code (char text i))))
                  (digit (cond ((digit-p code) (- code 48))
                               ((and (= base 16) (>= code 97) (<= code 102)) (- code 87)))))
             (unless digit
               (return nil))
             (setq number (+ (* number base) digit)
                   i (+ i 1)))))))

;;; Characters by their names
;;;
;;; What a page writes as &amp; or &#38; is a character. The names are the
;;; ones of HTML 4 and some more of the ones that are met; a name that is
;;; not here stays as it was written. The first list has the names that a
;;; page may write without the semicolon, as it could when there were no
;;; others. The lists are worked out from the table that Python has of
;;; them (html.entities), and not typed.

(defvar *old-names*
  '(
    "Aacute" 193 "aacute" 225 "Acirc" 194 "acirc" 226 "acute" 180 "AElig" 198 "aelig" 230 "Agrave" 192 "agrave" 224
    "AMP" 38 "amp" 38 "Aring" 197 "aring" 229 "Atilde" 195 "atilde" 227 "Auml" 196 "auml" 228 "brvbar" 166
    "Ccedil" 199 "ccedil" 231 "cedil" 184 "cent" 162 "COPY" 169 "copy" 169 "curren" 164 "deg" 176 "divide" 247
    "Eacute" 201 "eacute" 233 "Ecirc" 202 "ecirc" 234 "Egrave" 200 "egrave" 232 "ETH" 208 "eth" 240 "Euml" 203
    "euml" 235 "frac12" 189 "frac14" 188 "frac34" 190 "GT" 62 "gt" 62 "Iacute" 205 "iacute" 237 "Icirc" 206
    "icirc" 238 "iexcl" 161 "Igrave" 204 "igrave" 236 "iquest" 191 "Iuml" 207 "iuml" 239 "laquo" 171 "LT" 60 "lt" 60
    "macr" 175 "micro" 181 "middot" 183 "nbsp" 160 "not" 172 "Ntilde" 209 "ntilde" 241 "Oacute" 211 "oacute" 243
    "Ocirc" 212 "ocirc" 244 "Ograve" 210 "ograve" 242 "ordf" 170 "ordm" 186 "Oslash" 216 "oslash" 248 "Otilde" 213
    "otilde" 245 "Ouml" 214 "ouml" 246 "para" 182 "plusmn" 177 "pound" 163 "QUOT" 34 "quot" 34 "raquo" 187 "REG" 174
    "reg" 174 "sect" 167 "shy" 173 "sup1" 185 "sup2" 178 "sup3" 179 "szlig" 223 "THORN" 222 "thorn" 254 "times" 215
    "Uacute" 218 "uacute" 250 "Ucirc" 219 "ucirc" 251 "Ugrave" 217 "ugrave" 249 "uml" 168 "Uuml" 220 "uuml" 252
    "Yacute" 221 "yacute" 253 "yen" 165 "yuml" 255))

(defvar *names*
  '(
    "alefsym" 8501 "Alpha" 913 "alpha" 945 "and" 8743 "ang" 8736 "apos" 39 "ast" 42 "asymp" 8776 "bdquo" 8222
    "Beta" 914 "beta" 946 "bigstar" 9733 "bsol" 92 "bull" 8226 "bullet" 8226 "cap" 8745 "centerdot" 183
    "check" 10003 "Chi" 935 "chi" 967 "circ" 710 "clubs" 9827 "colon" 58 "comma" 44 "commat" 64 "cong" 8773
    "crarr" 8629 "cross" 10007 "ctdot" 8943 "cup" 8746 "Dagger" 8225 "dagger" 8224 "dArr" 8659 "darr" 8595
    "dash" 8208 "Delta" 916 "delta" 948 "diams" 9830 "dollar" 36 "downarrow" 8595 "empty" 8709 "emsp" 8195
    "ensp" 8194 "Epsilon" 917 "epsilon" 949 "equals" 61 "equiv" 8801 "Eta" 919 "eta" 951 "euro" 8364 "excl" 33
    "exist" 8707 "female" 9792 "fnof" 402 "forall" 8704 "frac13" 8531 "frac15" 8533 "frac18" 8539 "frac23" 8532
    "frasl" 8260 "Gamma" 915 "gamma" 947 "ge" 8805 "grave" 96 "hairsp" 8202 "half" 189 "hArr" 8660 "harr" 8596
    "hearts" 9829 "hellip" 8230 "horbar" 8213 "hyphen" 8208 "image" 8465 "infin" 8734 "int" 8747 "Iota" 921
    "iota" 953 "isin" 8712 "Kappa" 922 "kappa" 954 "Lambda" 923 "lambda" 955 "lang" 10216 "lArr" 8656 "larr" 8592
    "lbrace" 123 "lbrack" 91 "lceil" 8968 "lcub" 123 "ldquo" 8220 "le" 8804 "LeftArrow" 8592 "leftarrow" 8592
    "lfloor" 8970 "lowast" 8727 "lowbar" 95 "loz" 9674 "lpar" 40 "lrm" 8206 "lsaquo" 8249 "lsqb" 91 "lsquo" 8216
    "male" 9794 "mdash" 8212 "minus" 8722 "mldr" 8230 "Mu" 924 "mu" 956 "nabla" 8711 "ndash" 8211 "ne" 8800
    "NewLine" 10 "ni" 8715 "nldr" 8229 "NoBreak" 8288 "notin" 8713 "nsub" 8836 "Nu" 925 "nu" 957 "num" 35
    "numsp" 8199 "OElig" 338 "oelig" 339 "oline" 8254 "Omega" 937 "omega" 969 "Omicron" 927 "omicron" 959
    "oplus" 8853 "or" 8744 "otimes" 8855 "part" 8706 "percnt" 37 "period" 46 "permil" 8240 "perp" 8869 "Phi" 934
    "phi" 966 "phone" 9742 "Pi" 928 "pi" 960 "piv" 982 "plus" 43 "Prime" 8243 "prime" 8242 "prod" 8719 "prop" 8733
    "Psi" 936 "psi" 968 "puncsp" 8200 "quest" 63 "radic" 8730 "rang" 10217 "rArr" 8658 "rarr" 8594 "rbrace" 125
    "rbrack" 93 "rceil" 8969 "rcub" 125 "rdquo" 8221 "real" 8476 "rfloor" 8971 "Rho" 929 "rho" 961 "RightArrow" 8594
    "rightarrow" 8594 "rlm" 8207 "rpar" 41 "rsaquo" 8250 "rsqb" 93 "rsquo" 8217 "sbquo" 8218 "Scaron" 352
    "scaron" 353 "sdot" 8901 "semi" 59 "Sigma" 931 "sigma" 963 "sigmaf" 962 "sim" 8764 "sol" 47 "spades" 9824
    "star" 9734 "starf" 9733 "sub" 8834 "sube" 8838 "sum" 8721 "sup" 8835 "supe" 8839 "Tab" 9 "Tau" 932 "tau" 964
    "there4" 8756 "Theta" 920 "theta" 952 "thetasym" 977 "thinsp" 8201 "tilde" 732 "trade" 8482 "uArr" 8657
    "uarr" 8593 "uparrow" 8593 "upsih" 978 "Upsilon" 933 "upsilon" 965 "vellip" 8942 "verbar" 124 "Vert" 8214
    "vert" 124 "weierp" 8472 "Xi" 926 "xi" 958 "Yuml" 376 "ZeroWidthSpace" 8203 "Zeta" 918 "zeta" 950 "zwj" 8205
    "zwnj" 8204))

;; The same by the first letter of the name: for each code below 128 the
;; names that begin so, each (name code . whether it is one of the old).
(defvar *named* nil)

(defun named ()
  (or *named*
      (let ((table (make-array 128 :initial-element nil)))
        (dolist (old '(t nil))
          (let ((items (if old *old-names* *names*)))
            (loop
              (when (null items)
                (return))
              (let ((first (char-code (char (car items) 0))))
                (setf (svref table first) (cons (cons (car items) (cons (cadr items) old)) (svref table first))))
              (setq items (cddr items)))))
        (setq *named* table))))

;; What a name stands for: (name code . old), or NIL.
(defun find-name (name)
  (let ((first (char-code (char name 0))))
    (and (< first 128)
         (let ((rows (svref (named) first)))
           (loop
             (when (null rows)
               (return nil))
             (when (string= (car (car rows)) name)
               (return (car rows)))
             (setq rows (cdr rows)))))))

;; The characters that the codes from 128 to 159 stand for where a page is
;; written as Windows writes (windows-1252): a page that names such a code
;; means one of them, and so does a byte of a page that is written so.
(defvar *windows* (vector 8364 129 8218 402 8222 8230 8224 8225 710 8240 352 8249 338 141 381 143
                          144 8216 8217 8220 8221 8226 8211 8212 732 8482 353 8250 339 157 382 376))

;; The character that a page means by a number.
(defun character-of (code)
  (cond ((or (= code 0) (>= code char-code-limit) (and (>= code #xd800) (<= code #xdfff))) (code-char #xfffd))
        ((and (>= code 128) (<= code 159)) (code-char (svref *windows* (- code 128))))
        (t (code-char code))))

;; What stands in TEXT at AT, where an & is, is read as the name or the
;; number of a character: the character as a string and the place behind
;; what was read, or NIL when it is no such thing and the & is itself. In
;; what a tag says of its element, an old name without its semicolon is no
;; name when a letter, a digit or = follows it: an address is written so,
;; "?a=1&copy=2".
(defun reference (text at end said)
  (let ((i (+ at 1)))
    (cond ((>= i end) nil)
          ((= (char-code (char text i)) 35)       ; #
           (let* ((sixteen (and (< (+ i 1) end) (= (small (char-code (char text (+ i 1)))) 120)))
                  (from (if sixteen (+ i 2) (+ i 1)))
                  (to from))
             (loop
               (unless (and (< to end)
                            (let ((code (small (char-code (char text to)))))
                              (or (digit-p code) (and sixteen (>= code 97) (<= code 102)))))
                 (return))
               (setq to (+ to 1)))
             (and (> to from)
                  (let ((number (if (> (- to from) 8) #x110000 (number-in (subseq text from to) (if sixteen 16 10)))))
                    (values (string (character-of number))
                            (if (and (< to end) (= (char-code (char text to)) 59)) (+ to 1) to))))))
          (t
           (let ((to i))
             (loop
               (unless (and (< to end) (< (- to i) 32)
                            (let ((code (char-code (char text to))))
                              (or (letter-p code) (digit-p code))))
                 (return))
               (setq to (+ to 1)))
             (and (> to i)
                  (let ((whole (and (< to end) (= (char-code (char text to)) 59) (find-name (subseq text i to)))))
                    (if whole
                        (values (string (character-of (cadr whole))) (+ to 1))
                        ;; the longest old name that it begins with
                        (let ((length (if (> (- to i) 6) 6 (- to i))))
                          (loop
                            (when (< length 2)
                              (return nil))
                            (let ((found (find-name (subseq text i (+ i length)))))
                              (when (and found (cddr found))
                                (let ((next (if (< (+ i length) end) (char-code (char text (+ i length))) 0)))
                                  (return (if (and said (or (= next 61) (letter-p next) (digit-p next)))
                                              nil
                                              (values (string (character-of (cadr found))) (+ i length)))))))
                            (setq length (- length 1))))))))))))

;; The part of TEXT from FROM to END with the characters for their names
;; and numbers. SAID is whether it is what a tag says of its element.
(defun decoded (text from end said)
  (let ((and-sign (place-of 38 text from end)))
    (if (>= and-sign end)
        (subseq text from end)
        (with-output-to-string (out)
          (loop
            (write-string (subseq text from and-sign) out)
            (when (>= and-sign end)
              (return))
            (multiple-value-bind (character next) (reference text and-sign end said)
              (cond (character
                     (write-string character out)
                     (setq from next))
                    (t
                     (write-string "&" out)
                     (setq from (+ and-sign 1)))))
            (setq and-sign (place-of 38 text from end)))))))

;;; Addresses
;;;
;;; An address is taken apart as RFC 3986 says, and one that a page writes
;;; is read from the address of the page: "../a" is a place near the page,
;;; and "#top" a part of the page itself.

;; An address in its five parts (RFC 3986, 3): what kind of address it is,
;; in small letters, as "https"; the machine, with its port when one is
;; written; the path; what is asked there, behind a ?; and the part of the
;; page, behind a #. Each is NIL when it is not written, but the path,
;; which is then empty.
(defun parts (address)
  (let* ((end (length address)) (at 0) (kind nil) (machine nil) (asked nil) (part nil))
    ;; a kind is letters, digits, +, - and ., a letter first, and a colon behind it
    (let ((i 0))
      (loop
        (when (>= i end)
          (return))
        (let ((code (char-code (char address i))))
          (cond ((and (= code 58) (> i 0))
                 (setq kind (string-downcase (subseq address 0 i))
                       at (+ i 1))
                 (return))
                ((or (letter-p code) (and (> i 0) (or (digit-p code) (= code 43) (= code 45) (= code 46))))
                 (setq i (+ i 1)))
                (t (return))))))
    (let ((hash (place-of 35 address at end)))
      (when (< hash end)
        (setq part (subseq address (+ hash 1) end)
              end hash)))
    (let ((question (place-of 63 address at end)))
      (when (< question end)
        (setq asked (subseq address (+ question 1) end)
              end question)))
    (when (and (< (+ at 1) end) (= (char-code (char address at)) 47) (= (char-code (char address (+ at 1))) 47))
      (let ((slash (place-of 47 address (+ at 2) end)))
        (setq machine (subseq address (+ at 2) slash)
              at slash)))
    (values kind machine (subseq address at end) asked part)))

;; The five parts as one address again (RFC 3986, 5.3).
(defun whole (kind machine path asked part)
  (concatenate 'string
               (if kind (concatenate 'string kind ":") "")
               (if machine (concatenate 'string "//" machine) "")
               path
               (if asked (concatenate 'string "?" asked) "")
               (if part (concatenate 'string "#" part) "")))

;; A path without the steps that stay where they are, ".", and with every
;; step back, "..", taken (RFC 3986, 5.2.4).
(defun stepped (path)
  (let* ((end (length path))
         (rooted (and (> end 0) (= (char-code (char path 0)) 47)))
         (from (if rooted 1 0))
         (steps nil)                    ; the steps that stand, the last first
         (open nil))                    ; the path ends in a /
    (loop
      (let* ((slash (place-of 47 path from end))
             (step (subseq path from slash))
             (last (>= slash end)))
        (cond ((string= step ".")
               (setq open t))
              ((string= step "..")
               (setq steps (cdr steps)
                     open t))
              (t
               (setq steps (cons step steps)
                     open nil)))
        (when last
          (return))
        (setq from (+ slash 1))))
    (when (and open (or steps rooted))
      (setq steps (cons "" steps)))
    (with-output-to-string (out)
      (let ((steps (reverse steps)) (first t))
        (when rooted
          (write-string "/" out))
        (dolist (step steps)
          (unless first
            (write-string "/" out))
          (write-string step out)
          (setq first nil))))))

;; The address that WRITTEN means when it is read at the address BASE (RFC
;; 3986, 5.2.2).
(defun address-from (base written)
  (multiple-value-bind (kind machine path asked part) (parts written)
    (multiple-value-bind (base-kind base-machine base-path base-asked) (parts base)
      (cond (kind
             (whole kind machine (if machine (stepped path) path) asked part))
            (machine
             (whole base-kind machine (stepped path) asked part))
            ((= (length path) 0)
             (whole base-kind base-machine base-path (or asked base-asked) part))
            ((= (char-code (char path 0)) 47)
             (whole base-kind base-machine (stepped path) asked part))
            (t
             (let ((slash nil))
               (dotimes (i (length base-path))
                 (when (= (char-code (char base-path i)) 47)
                   (setq slash i)))
               (whole base-kind base-machine
                      (stepped (cond (slash (concatenate 'string (subseq base-path 0 (+ slash 1)) path))
                                     (base-machine (concatenate 'string "/" path))
                                     (t path)))
                      asked part)))))))

(defvar *sixteen* "0123456789ABCDEF")

;; An address as it is sent: without the tabs and the ends of lines that a
;; page may have in it, and with what an address cannot hold written as %
;; and two digits, a space or a letter that is not ASCII's, which is that
;; many bytes of UTF-8. Nothing that a page writes gets a line of its own
;; into what is sent to another machine.
(defun sendable (address)
  (with-output-to-string (out)
    (dotimes (i (length address))
      (let ((code (char-code (char address i))))
        (flet ((byte-out (byte)
                 (write-string "%" out)
                 (write-string (string (char *sixteen* (ash byte -4))) out)
                 (write-string (string (char *sixteen* (logand byte 15))) out)))
          (cond ((or (= code 9) (= code 10) (= code 13)))
                ((or (<= code 32) (= code 34) (= code 60) (= code 62) (= code 92) (= code 94) (= code 96)
                     (= code 123) (= code 124) (= code 125) (= code 127))
                 (byte-out code))
                ((< code 128)
                 (write-string (string (code-char code)) out))
                ((< code #x800)
                 (byte-out (logior #xc0 (ash code -6)))
                 (byte-out (logior #x80 (logand code 63))))
                ((< code #x10000)
                 (byte-out (logior #xe0 (ash code -12)))
                 (byte-out (logior #x80 (logand (ash code -6) 63)))
                 (byte-out (logior #x80 (logand code 63))))
                (t
                 (byte-out (logior #xf0 (ash code -18)))
                 (byte-out (logior #x80 (logand (ash code -12) 63)))
                 (byte-out (logior #x80 (logand (ash code -6) 63)))
                 (byte-out (logior #x80 (logand code 63))))))))))

;; An address without the part of the page that it names, and that part, or
;; NIL: two values.
(defun without-part (address)
  (let ((hash (place-of 35 address 0 (length address))))
    (if (< hash (length address))
        (values (subseq address 0 hash) (subseq address (+ hash 1)))
        (values address nil))))

;; What was typed where an address goes, as an address: with https:// before
;; it when it does not say what kind of address it is and of which machine.
;; "claraos.org" is typed, and "localhost:8000", whose colon makes no kind
;; of address of it.
(defun typed-address (text)
  (let ((text (trimmed text)))
    (multiple-value-bind (kind machine) (parts text)
      (if (or (and kind machine) (stands-at text 0 "about:"))
          text
          (concatenate 'string "https://" text)))))

;; The address that is asked for an address: every page is asked for over a
;; connection that is kept closed, and one that is written with http:// is
;; asked for with https:// in its place. An address of another kind is not
;; one that a page is fetched from, and is NIL here.
(defun secure (address)
  (cond ((stands-at address 0 "https://") address)
        ((stands-at address 0 "http://") (concatenate 'string "https://" (subseq address 7)))))

;;; Bytes as text
;;;
;;; A page arrives as bytes, and says, or not, how its text is written in
;;; them. What is written as UTF-8 is read as that. A page that says so and
;;; has bytes in it that are no UTF-8 is read as well: such a byte is taken
;;; for the character that Windows has there, which is what it nearly
;;; always was meant as. And a page that is written in another way than
;;; UTF-8 is read a byte to the character, by the same table: that is
;;; right for the pages of western Europe and wrong for the others, whose
;;; letters this system has no pictures of.

;; The text of BYTES bytes at MEMORY, a byte to the character.
(defun bytes-as-windows (memory bytes)
  (let ((text (make-string bytes)))
    (dotimes (i bytes text)
      (let ((byte (clara.unsafe:memory-8 (+ memory i))))
        (setf (char text i) (code-char (if (and (>= byte 128) (<= byte 159)) (svref *windows* (- byte 128)) byte)))))))

;; The text of BYTES bytes at MEMORY, as UTF-8 where they are that, and a
;; byte to the character where they are not.
(defun bytes-as-mixed (memory bytes)
  (let ((text (make-string bytes)) (count 0) (i 0))
    (flet ((more (at)                   ; the six bits of a byte that goes on, or NIL
             (and (< at bytes)
                  (let ((byte (clara.unsafe:memory-8 (+ memory at))))
                    (and (= (logand byte #xc0) #x80) (logand byte 63))))))
      (loop
        (when (>= i bytes)
          (return))
        (let* ((byte (clara.unsafe:memory-8 (+ memory i)))
               (code nil) (length 1))
          (cond ((< byte #x80)
                 (setq code byte))
                ((and (>= byte #xc2) (<= byte #xdf))
                 (let ((a (more (+ i 1))))
                   (when a
                     (setq code (logior (ash (logand byte 31) 6) a)
                           length 2))))
                ((and (>= byte #xe0) (<= byte #xef))
                 (let ((a (more (+ i 1))) (b (more (+ i 2))))
                   (when (and a b)
                     (let ((whole (logior (ash (logand byte 15) 12) (ash a 6) b)))
                       (when (and (>= whole #x800) (not (and (>= whole #xd800) (<= whole #xdfff))))
                         (setq code whole
                               length 3))))))
                ((and (>= byte #xf0) (<= byte #xf4))
                 (let ((a (more (+ i 1))) (b (more (+ i 2))) (c (more (+ i 3))))
                   (when (and a b c)
                     (let ((whole (logior (ash (logand byte 7) 18) (ash a 12) (ash b 6) c)))
                       (when (and (>= whole #x10000) (< whole #x110000) (< whole char-code-limit))
                         (setq code whole
                               length 4)))))))
          (setf (char text count)
                (code-char (cond (code code)
                                 ((and (>= byte 128) (<= byte 159)) (svref *windows* (- byte 128)))
                                 (t byte))))
          (setq count (+ count 1)
                i (+ i length)))))
    (subseq text 0 count)))

;; How a page says that it is written: the word behind "charset=" in WORDS,
;; in small letters, or NIL.
(defun written-as (words)
  (let ((at (seek words "charset" 0)))
    (and at
         (let* ((end (length words))
                (from (past-space words (+ at 7) end)))
           (and (< from end) (= (char-code (char words from)) 61)
                (let* ((from (past-space words (+ from 1) end))
                       (from (if (and (< from end) (or (= (char-code (char words from)) 34) (= (char-code (char words from)) 39)))
                                 (+ from 1)
                                 from))
                       (to from))
                  (loop
                    (unless (and (< to end)
                                 (let ((code (char-code (char words to))))
                                   (or (letter-p code) (digit-p code) (= code 45) (= code 95) (= code 46) (= code 58))))
                      (return))
                    (setq to (+ to 1)))
                  (and (> to from) (string-downcase (subseq words from to)))))))))

;; The text that BYTES bytes at MEMORY are. SAID is what came with them
;; about how they are written, or NIL: when that says nothing, the page's
;; own first thousand bytes may.
(defun bytes-text (memory bytes said)
  (let* ((way (or (and said (written-as said))
                  (written-as (bytes-as-windows memory (if (< bytes 1024) bytes 1024)))))
         (text (if (or (null way) (string= way "utf-8") (string= way "utf8"))
                   (or (ignore-errors (clara.unsafe:memory-string memory bytes))
                       (bytes-as-mixed memory bytes))
                   (bytes-as-windows memory bytes))))
    ;; a mark that some put before a text to say which way round its bytes are
    (if (and (> (length text) 0) (= (char-code (char text 0)) #xfeff))
        (subseq text 1)
        text)))

;;; A page as a tree
;;;
;;; The text of a page is read into a tree of its elements, as a page is
;;; meant to be read (the "HTML Standard" of the WHATWG, section 13.2, is
;;; where the rules are from): tags that are left out are made up for, an
;;; element that is not closed is closed by what cannot be inside it, and
;;; nothing that a page can say is an error. Two things of those rules are
;;; left out, both for pages that close their elements in another order than
;;; they opened them: letters that were made bold in one paragraph are not
;;; bold again in the next, and what stands between the rows of a table
;;; stays where it was written.

(defstruct node
  tag          ; the kind of element: a keyword for one that this file names anywhere, as :P, and for any other its name in
               ;   small letters, a string
  said         ; what its tag said of it: (name . value) each, the names in small letters
  children)    ; what is in it, in order: elements, and strings for text. While the page is read, the last comes first.

(defvar *alone* '(:area :base :basefont :bgsound :br :col :embed :frame :hr :img :input :keygen :link :meta :param :source
                  :track :wbr))                       ; these have nothing in them, and no tag that closes them
(defvar *plain* '(:script :style :xmp :iframe :noembed :noframes)) ; what is in these is text and no tags
(defvar *words* '(:title :textarea))                  ; and in these as well, but the names of characters count
(defvar *of-the-head* '(:base :basefont :bgsound :link :meta :title :style :script :noscript :template :noframes))
(defvar *headings* '(:h1 :h2 :h3 :h4 :h5 :h6))
(defvar *ends-paragraph*                              ; one of these begins, and a paragraph that is open is over
  '(:address :article :aside :blockquote :center :details :dialog :dir :div :dl :fieldset :figcaption :figure :footer
    :header :hgroup :main :menu :nav :ol :p :search :section :summary :ul :pre :listing :form :table :hr :xmp :plaintext
    :h1 :h2 :h3 :h4 :h5 :h6))
(defvar *ended-by-name*                               ; these are closed by their own tag, and what is open in them with them
  '(:address :article :aside :blockquote :button :center :details :dialog :dir :div :dl :fieldset :figcaption :figure
    :footer :header :hgroup :listing :main :menu :nav :ol :pre :search :section :summary :ul :form :applet :marquee
    :object))
(defvar *ended-unasked* '(:dd :dt :li :optgroup :option :p :rb :rp :rt :rtc)) ; these end when what holds them ends
(defvar *walls* '(:applet :caption :html :table :td :th :marquee :object :template)) ; no tag closes an element from inside one of these
(defvar *of-tables* '(:caption :colgroup :col :tbody :thead :tfoot :tr :td :th))
(defvar *between-cells* '(:table :tbody :thead :tfoot :tr :colgroup)) ; white space that is straight in one of these is nothing
(defvar *special*                                     ; a tag that closes some other kind of element does not reach past these
  '(:address :applet :area :article :aside :base :basefont :bgsound :blockquote :body :br :button :caption :center :col
    :colgroup :dd :details :dir :div :dl :dt :embed :fieldset :figcaption :figure :footer :form :frame :frameset :h1 :h2
    :h3 :h4 :h5 :h6 :head :header :hgroup :hr :html :iframe :img :input :keygen :li :link :listing :main :marquee :menu
    :meta :nav :noembed :noframes :noscript :object :ol :p :param :plaintext :pre :script :search :section :select
    :source :style :summary :table :tbody :td :template :textarea :tfoot :th :thead :title :tr :track :ul :wbr :xmp))

;; The kind of element that a name stands for.
(defun tag-of (name)
  (or (find-symbol (string-upcase name) "KEYWORD") (string-downcase name)))

;; And the name of a kind, in small letters.
(defun tag-name (tag)
  (if (stringp tag) tag (string-downcase (symbol-name tag))))

(defun same-tag (a b)
  (or (eq a b) (and (stringp a) (stringp b) (string= a b))))

;; What an element's tag said of NAME, or NIL.
(defun said (node name)
  (let ((rows (node-said node)))
    (loop
      (when (null rows)
        (return nil))
      (when (string= (car (car rows)) name)
        (return (cdr (car rows))))
      (setq rows (cdr rows)))))

;; A page while it is read.
(defstruct reading
  text         ; the page
  (at 0)       ; how far it has been read
  open         ; the elements that are open, the innermost first
  root         ; the element that holds all others,
  head         ; the one for what a page says of itself, once there is one,
  body         ; and the one for what it shows
  strict       ; the page says of itself, in its first line, that it is to be read by the rules of today
  (foreign 0)  ; how many elements are open that are drawings or formulas: what is in those is written by other rules
  (kept 0))    ; and how many that keep a piece of a page for later, which is read as what a page shows wherever it stands

(defun innermost (reading)
  (car (reading-open reading)))

(defun open-element (reading tag said)
  (let ((node (make-node :tag tag :said said)) (holder (innermost reading)))
    (setf (node-children holder) (cons node (node-children holder))
          (reading-open reading) (cons node (reading-open reading)))
    (when (or (eq tag :svg) (eq tag :math))
      (setf (reading-foreign reading) (+ (reading-foreign reading) 1)))
    (when (eq tag :template)
      (setf (reading-kept reading) (+ (reading-kept reading) 1)))
    node))

;; The innermost element is over: what is in it is in its order from now on.
(defun close-element (reading)
  (let ((node (innermost reading)))
    (setf (node-children node) (nreverse (node-children node))
          (reading-open reading) (cdr (reading-open reading)))
    (when (or (eq (node-tag node) :svg) (eq (node-tag node) :math))
      (setf (reading-foreign reading) (- (reading-foreign reading) 1)))
    (when (eq (node-tag node) :template)
      (setf (reading-kept reading) (- (reading-kept reading) 1)))
    node))

;; The open elements are closed from the innermost on, up to one of the kind
;; TAG, which is the last; never the one that holds all others, or the one
;; for what the page shows.
(defun close-through (reading tag)
  (loop
    (let ((node (innermost reading)))
      (when (or (eq node (reading-root reading)) (eq node (reading-body reading)))
        (return))
      (close-element reading)
      (when (same-tag (node-tag node) tag)
        (return)))))

;; Is an element of the kind TAG open, with none of WALLS between it and
;; where the page is being read?
(defun open-p (reading tag walls)
  (let ((open (reading-open reading)))
    (loop
      (when (null open)
        (return nil))
      (let ((kind (node-tag (car open))))
        (when (same-tag kind tag)
          (return t))
        (when (in kind walls)
          (return nil)))
      (setq open (cdr open)))))

;; The elements that end without being asked are closed, as far as the
;; innermost ones are such; but none of the kind EXCEPT. (Where a tag
;; closes its element whatever is open in it, CLOSE-THROUGH, nothing asks
;; for this first: what it would close is closed there.)
(defun end-unasked (reading except)
  (loop
    (let ((kind (node-tag (innermost reading))))
      (unless (and (in kind *ended-unasked*) (not (eq kind except)))
        (return))
      (close-element reading))))

(defun close-paragraph (reading)
  (when (open-p reading :p '(:applet :caption :html :table :td :th :marquee :object :template :button))
    (close-through reading :p)))

;; An item of a list begins, or a word of a list of words and what is said
;; of it: one of KINDS that is open is over, unless something stands between
;; that holds things of its own.
(defun close-item (reading kinds)
  (let ((open (reading-open reading)))
    (loop
      (when (null open)
        (return))
      (let ((kind (node-tag (car open))))
        (when (in kind kinds)
          (close-through reading kind)
          (return))
        (when (and (in kind *special*) (not (in kind '(:address :div :p))))
          (return)))
      (setq open (cdr open)))))

;; The open elements are closed until the innermost is one of KINDS.
(defun back-to (reading kinds)
  (loop
    (when (or (in (node-tag (innermost reading)) kinds) (eq (innermost reading) (reading-body reading)))
      (return))
    (close-element reading)))

;; What a tag says of an element that is there already is added to what
;; was said of it, where it is new.
(defun say-more (node said)
  (dolist (pair said)
    (unless (said node (car pair))
      (setf (node-said node) (append (node-said node) (list pair))))))

(defun open-head (reading said)
  (setf (reading-head reading) (open-element reading :head said)))

;; What the page shows begins here, if it has not yet: whatever was open
;; of what the page says of itself is over.
(defun begin-body (reading said)
  (unless (reading-body reading)
    (unless (reading-head reading)
      (open-head reading nil))
    (loop
      (when (eq (innermost reading) (reading-root reading))
        (return))
      (close-element reading))
    (setf (reading-body reading) (open-element reading :body said))))

;; An element of the kind TAG is in the page here. One that has nothing in
;; it is over at once, and so is one in a drawing whose tag ended in />.
(defun put-element (reading tag said closed)
  (open-element reading tag said)
  (when (or (in tag *alone*) (and closed (> (reading-foreign reading) 0)))
    (close-element reading)))

;; Text is in the page here: added to the text before it, when that is what
;; stands there.
(defun put-text (reading text)
  (let* ((node (innermost reading)) (children (node-children node)))
    (if (and children (stringp (car children)))
        (rplaca children (concatenate 'string (car children) text))
        (setf (node-children node) (cons text children)))))

(defun words (reading text)
  (cond ((= (length text) 0))
        ((or (reading-body reading) (> (reading-kept reading) 0))
         (unless (and (in (node-tag (innermost reading)) *between-cells*) (blank-p text))
           (put-text reading text)))
        ((blank-p text))                ; white space before the page shows anything is nothing
        (t
         (begin-body reading nil)
         (put-text reading (subseq text (past-space text 0 (length text)))))))

;; A tag of a table's own: a row, a cell, a group of rows. It closes what is
;; open in the nearest table as far as it has to, and what a page left out
;; between the table and it is made up: a cell is in a row, and a row in a
;; group of rows. Outside a table such a tag is nothing.
(defun table-tag (reading tag said)
  (when (open-p reading :table '(:html :template))
    (cond ((eq tag :tr)
           (back-to reading '(:tbody :thead :tfoot :table))
           (when (eq (node-tag (innermost reading)) :table)
             (open-element reading :tbody nil))
           (open-element reading :tr said))
          ((or (eq tag :td) (eq tag :th))
           (back-to reading '(:tr :tbody :thead :tfoot :table))
           (when (eq (node-tag (innermost reading)) :table)
             (open-element reading :tbody nil))
           (unless (eq (node-tag (innermost reading)) :tr)
             (open-element reading :tr nil))
           (open-element reading tag said))
          ((eq tag :col)
           (back-to reading '(:colgroup :table))
           (when (eq (node-tag (innermost reading)) :table)
             (open-element reading :colgroup nil))
           (open-element reading :col said)
           (close-element reading))
          (t
           (back-to reading '(:table))
           (open-element reading tag said)))))

;; A tag that begins an element, where the page shows things.
(defun shown-tag (reading tag said closed)
  (cond ((in tag *of-tables*)
         (table-tag reading tag said))
        ((eq tag :li)
         (close-item reading '(:li))
         (close-paragraph reading)
         (put-element reading tag said closed))
        ((or (eq tag :dd) (eq tag :dt))
         (close-item reading '(:dd :dt))
         (close-paragraph reading)
         (put-element reading tag said closed))
        ((in tag *headings*)
         (close-paragraph reading)
         (when (in (node-tag (innermost reading)) *headings*)
           (close-element reading))
         (put-element reading tag said closed))
        ((eq tag :table)                ; in a page that is read by the older rules, a table is part of its paragraph
         (when (reading-strict reading)
           (close-paragraph reading))
         (put-element reading tag said closed))
        ((or (eq tag :rb) (eq tag :rtc)) ; small letters over a word, and what stands around them
         (when (open-p reading :ruby *walls*)
           (end-unasked reading nil))
         (put-element reading tag said closed))
        ((or (eq tag :rp) (eq tag :rt))
         (when (open-p reading :ruby *walls*)
           (end-unasked reading :rtc))
         (put-element reading tag said closed))
        ((in tag *ends-paragraph*)
         (close-paragraph reading)
         (put-element reading tag said closed))
        ((eq tag :a)                    ; a link is not in a link
         (when (open-p reading :a *walls*)
           (close-through reading :a))
         (put-element reading tag said closed))
        ((eq tag :button)
         (when (open-p reading :button *walls*)
           (close-through reading :button))
         (put-element reading tag said closed))
        ((eq tag :option)
         (when (eq (node-tag (innermost reading)) :option)
           (close-element reading))
         (put-element reading tag said closed))
        ((eq tag :optgroup)
         (when (eq (node-tag (innermost reading)) :option)
           (close-element reading))
         (when (eq (node-tag (innermost reading)) :optgroup)
           (close-element reading))
         (put-element reading tag said closed))
        ((eq tag :image)                ; an old name for a picture
         (put-element reading :img said closed))
        (t
         (put-element reading tag said closed))))

(defun begin-tag (reading tag said closed)
  (cond ((> (reading-kept reading) 0)
         (unless (or (eq tag :html) (eq tag :head) (eq tag :body))
           (shown-tag reading tag said closed)))
        ((eq tag :html)
         (say-more (reading-root reading) said))
        ((eq tag :head)
         (unless (or (reading-head reading) (reading-body reading))
           (open-head reading said)))
        ((eq tag :body)
         (if (reading-body reading)
             (say-more (reading-body reading) said)
             (begin-body reading said)))
        ((and (null (reading-body reading)) (in tag *of-the-head*))
         (unless (reading-head reading)
           (open-head reading nil))
         (put-element reading tag said closed))
        (t
         (begin-body reading nil)
         (shown-tag reading tag said closed))))

;; A tag that ends an element. One that ends nothing that is open is
;; nothing, but for a paragraph, which is then an empty one, and a break,
;; which is one whichever way its tag is written.
(defun end-tag (reading tag)
  (cond ((or (eq tag :html) (eq tag :body) (eq tag :head)))   ; the page is read on as it was
        ((eq tag :br)
         (begin-tag reading :br nil nil))
        ((eq tag :template)             ; whatever is open in it is over with it
         (when (open-p reading :template '(:html))
           (close-through reading :template)))
        ((and (null (reading-body reading)) (= (reading-kept reading) 0))
         (when (and (open-p reading tag '(:html :head)) (not (stringp tag)))
           (close-through reading tag)))
        ((eq tag :p)
         (unless (open-p reading :p '(:applet :caption :html :table :td :th :marquee :object :template :button))
           (open-element reading :p nil))
         (close-paragraph reading))
        ((in tag *headings*)
         (let ((open (reading-open reading)) (found nil))
           (loop
             (when (or (null open) (in (node-tag (car open)) *walls*))
               (return))
             (when (in (node-tag (car open)) *headings*)
               (setq found t)
               (return))
             (setq open (cdr open)))
           (when found
             (loop
               (when (in (node-tag (close-element reading)) *headings*)
                 (return))))))
        ((eq tag :li)
         (when (open-p reading :li '(:applet :caption :html :table :td :th :marquee :object :template :ol :ul))
           (close-through reading :li)))
        ((or (eq tag :dd) (eq tag :dt))
         (when (open-p reading tag *walls*)
           (close-through reading tag)))
        ((in tag *of-tables*)
         (when (open-p reading tag '(:html :table :template))
           (close-through reading tag)))
        ((eq tag :table)
         (when (open-p reading :table '(:html :template))
           (close-through reading :table)))
        ((in tag *ended-by-name*)
         (when (open-p reading tag *walls*)
           (close-through reading tag)))
        (t
         (let ((open (reading-open reading)))
           (loop
             (when (null open)
               (return))
             (let ((kind (node-tag (car open))))
               (when (same-tag kind tag)
                 (close-through reading tag)
                 (return))
               (when (in kind *special*)
                 (return)))
             (setq open (cdr open)))))))

;;; The text of a page, read into that tree

;; Where a name ends that begins at FROM: at white space, a /, a > or the
;; end. An = ends the name of something that a tag says, where EQUALS says
;; so.
(defun name-end (text from end equals)
  (loop
    (when (>= from end)
      (return from))
    (let ((code (char-code (char text from))))
      (when (or (space-p code) (= code 47) (= code 62) (and equals (= code 61)))
        (return from)))
    (setq from (+ from 1))))

;; The place behind the next > from FROM on, or END when there is none.
(defun past-greater (text from end)
  (let ((greater (place-of 62 text from end)))
    (if (< greater end) (+ greater 1) end)))

;; The text of an element that holds text and no tags is read: up to the tag
;; that closes it, which is passed over, or to the end of the page.
(defun read-plain (reading tag counted)
  (let* ((text (reading-text reading)) (end (length text)) (from (reading-at reading))
         (closing (concatenate 'string "</" (tag-name tag)))
         (to from))
    (loop
      (setq to (or (seek text closing to) end))
      (when (>= to end)
        (return))
      (let* ((behind (+ to (length closing)))
             (code (if (< behind end) (char-code (char text behind)) 62)))
        (when (or (space-p code) (= code 47) (= code 62))
          (return)))
      (setq to (+ to 1)))
    ;; a new line that stands first in a field of text is not part of it
    (when (and (eq tag :textarea) (< from to) (= (char-code (char text from)) 10))
      (setq from (+ from 1)))
    (when (< from to)
      (put-text reading (if counted (decoded text from to nil) (subseq text from to))))
    (setf (reading-at reading) (if (< to end) (past-greater text to end) end))))

;; A tag that begins an element is read, with what it says of the element:
;; names, each with a value or without, the value between quotes of either
;; kind or bare. A tag that the page ends in the middle of is nothing.
(defun read-begin (reading)
  (let* ((text (reading-text reading)) (end (length text)) (from (+ (reading-at reading) 1))
         (i (name-end text from end nil))
         (tag (tag-of (subseq text from i)))
         (said nil) (closed nil) (whole nil))
    (loop
      (setq i (past-space text i end))
      (when (>= i end)
        (return))
      (let ((code (char-code (char text i))))
        (cond ((= code 62)
               (setq i (+ i 1)
                     whole t)
               (return))
              ((= code 47)
               (cond ((and (< (+ i 1) end) (= (char-code (char text (+ i 1))) 62))
                      (setq i (+ i 2)
                            closed t
                            whole t)
                      (return))
                     (t (setq i (+ i 1)))))
              (t
               (let* ((name-from i) (value ""))
                 (setq i (name-end text (+ i 1) end t))
                 (let ((name (string-downcase (subseq text name-from i))))
                   (setq i (past-space text i end))
                   (when (and (< i end) (= (char-code (char text i)) 61))
                     (setq i (past-space text (+ i 1) end))
                     (when (< i end)
                       (let ((quote (char-code (char text i))))
                         (cond ((or (= quote 34) (= quote 39))
                                (let ((close (place-of quote text (+ i 1) end)))
                                  (setq value (decoded text (+ i 1) close t)
                                        i (if (< close end) (+ close 1) end))))
                               ((= quote 62))
                               (t
                                (let ((stop i))
                                  (loop
                                    (when (or (>= stop end) (space-p (char-code (char text stop)))
                                              (= (char-code (char text stop)) 62))
                                      (return))
                                    (setq stop (+ stop 1)))
                                  (setq value (decoded text i stop t)
                                        i stop)))))))
                   (unless (assoc name said :test #'string=)
                     (setq said (cons (cons name value) said)))))))))
    (setf (reading-at reading) i)
    (when whole
      (let ((foreign (> (reading-foreign reading) 0)))
        (begin-tag reading tag (nreverse said) closed)
        (cond (foreign)
              ((not (eq (node-tag (innermost reading)) tag)))  ; it was not put there, or is over already
              ((in tag *plain*)
               (read-plain reading tag nil)
               (close-element reading))
              ((in tag *words*)
               (read-plain reading tag t)
               (close-element reading))
              ((eq tag :plaintext)      ; the rest of the page is text
               (put-text reading (subseq text i end))
               (setf (reading-at reading) end))
              ((or (eq tag :pre) (eq tag :listing)) ; a new line that stands first in text as it is written is not part of it
               (when (and (< i end) (= (char-code (char text i)) 10))
                 (setf (reading-at reading) (+ i 1)))))))))

;; A tag that ends an element is read; whatever else it says is passed over.
(defun read-end (reading)
  (let* ((text (reading-text reading)) (end (length text)) (from (+ (reading-at reading) 2))
         (i (name-end text from end nil))
         (greater (place-of 62 text i end)))
    (setf (reading-at reading) (if (< greater end) (+ greater 1) end))
    (when (< greater end)
      (end-tag reading (tag-of (subseq text from i))))))

;; What begins with <! is read: a remark, which is nothing, as far as --> or
;; the end of the page; or, in a drawing, text between <![CDATA[ and ]]>; or
;; something else that is nothing, as far as the next >.
(defun read-remark (reading)
  (let* ((text (reading-text reading)) (end (length text)) (at (reading-at reading)))
    (when (stands-at text at "<!doctype")
      (setf (reading-strict reading) t))
    (cond ((stands-at text at "<!--")
           (let ((from (+ at 4)))
             (setf (reading-at reading)
                   (cond ((stands-at text from ">") (+ from 1))
                         ((stands-at text from "->") (+ from 2))
                         (t (let ((close (seek text "-->" from)) (bang (seek text "--!>" from)))
                              (cond ((and close (or (null bang) (< close bang))) (+ close 3))
                                    (bang (+ bang 4))
                                    (t end))))))))
          ((and (> (reading-foreign reading) 0) (stands-at text at "<![cdata["))
           (let ((close (or (seek text "]]>" (+ at 9)) end)))
             (words reading (subseq text (+ at 9) close))
             (setf (reading-at reading) (if (< close end) (+ close 3) end))))
          (t
           (setf (reading-at reading) (past-greater text at end))))))

;; What begins with < is read.
(defun read-markup (reading)
  (let* ((text (reading-text reading)) (end (length text)) (at (reading-at reading))
         (next (if (< (+ at 1) end) (char-code (char text (+ at 1))) 0)))
    (cond ((letter-p next)
           (read-begin reading))
          ((= next 47)
           (let ((after (if (< (+ at 2) end) (char-code (char text (+ at 2))) 0)))
             (cond ((letter-p after) (read-end reading))
                   ((>= (+ at 2) end)   ; the page ends there, and those two are text
                    (words reading "</")
                    (setf (reading-at reading) end))
                   ((= after 62) (setf (reading-at reading) (+ at 3)))
                   (t (setf (reading-at reading) (past-greater text at end))))))
          ((= next 33)
           (read-remark reading))
          ((= next 63)
           (setf (reading-at reading) (past-greater text at end)))
          (t
           (words reading "<")
           (setf (reading-at reading) (+ at 1))))))

;; A text with its lines ended the one way, by a new line and nothing else,
;; and without the characters that have the code 0, which are nothing.
(defun even-lines (text)
  (let ((end (length text)))
    (if (and (>= (place-of 13 text 0 end) end) (>= (place-of 0 text 0 end) end))
        text
        (with-output-to-string (out)
          (let ((from 0) (i 0))
            (loop
              (when (>= i end)
                (write-string (subseq text from end) out)
                (return))
              (let ((code (char-code (char text i))))
                (cond ((= code 13)
                       (write-string (subseq text from i) out)
                       (write-string (string (code-char 10)) out)
                       (setq i (if (and (< (+ i 1) end) (= (char-code (char text (+ i 1))) 10)) (+ i 2) (+ i 1))
                             from i))
                      ((= code 0)
                       (write-string (subseq text from i) out)
                       (setq i (+ i 1)
                             from i))
                      (t (setq i (+ i 1)))))))))))

;; The tree of a page: the element that holds all others, which has in it
;; the one for what the page says of itself and the one for what it shows.
(defun read-page (text)
  (let* ((text (even-lines text))
         (root (make-node :tag :html))
         (reading (make-reading :text text :open (list root) :root root))
         (end (length text)))
    (loop
      (let ((at (reading-at reading)))
        (when (>= at end)
          (return))
        (let ((less (place-of 60 text at end)))
          (when (> less at)
            (words reading (decoded text at less nil)))
          (setf (reading-at reading) less)
          (when (< less end)
            (read-markup reading)))))
    (begin-body reading nil)
    (setf (reading-body reading) nil)   ; so that it is closed like the others
    (loop
      (when (null (reading-open reading))
        (return))
      (close-element reading))
    root))

;;; How a page looks
;;;
;;; The tree is laid out for a window of some width: its text is put into
;;; lines, each a few pieces of text that look alike, and the lines one
;;; under the other, with the space that paragraphs, headings and lists
;;; leave around them. Nothing of what a page says about its looks is read
;;; (style sheets): an element looks as its kind looks here. Pictures are
;;; not fetched, and stand as the words that the page has for them.

;; How some text looks.
(defstruct look
  (family "Sans") ; "Sans", or "Mono" for text as it is typed
  (size 16)    ; pixels to the em
  bold
  italic
  underline
  strike
  color        ; the pixel of its letters
  link         ; the number of the link that it is part of, or NIL
  kept         ; its white space is kept as it is written, and its lines end where the page ends them
  (rise 0)     ; how far above its line the letters stand, in pixels, and below it for a number under nought
  font)        ; its font, once it was asked for: one of CLARA.TYPE's, or :CELLS for the console's letters

(defstruct piece
  x            ; where it begins, from the left edge of the page
  up           ; how far below the top of its line its own top is
  width
  text
  look)

(defstruct line
  top          ; from the top of the page
  height
  pieces)      ; from left to right

;; A rectangle of one colour: a rule, the ground under text as it is typed, the frame of a table's cell.
(defstruct box
  x y width height color)

(defstruct page
  address      ; where it was had
  base         ; the address that what it writes is read from: its own, unless it names another
  title        ; what it calls itself, or NIL
  lines        ; a vector of its lines, in the order of their tops
  boxes        ; its rectangles, in the order in which they are drawn
  links        ; a vector: what each link of it is written as
  marks        ; the places in it that have names: (name . how far down) each
  width
  height
  tallest)     ; how high its highest line is

(defstruct colors
  paper        ; the ground of a page
  ink          ; its text
  dim          ; text that stands for something else: a picture, a field
  link         ; a link,
  seen         ; and one that was followed before
  rule         ; a line across, and the frame of a cell
  ground)      ; under text as it is typed

;; A page while it is laid out.
(defstruct laying
  colors
  base         ; the address that the page's links are read from
  seen         ; the addresses that were visited, for the colour of a link
  (left 0)     ; the edges of the block that is being laid out
  (right 0)
  (y 0)        ; where the top of the next line goes, but for the gap
  (gap 0)      ; the space that is to be left above the next line: the largest that was asked for since the last one
  (align :left)
  pieces       ; the pieces of the line that is being put together, the last first
  (pen 0)      ; where the next piece goes
  (fresh t)    ; nothing is on that line yet
  (added 0)    ; how many pieces of text went onto lines so far
  space        ; white space stands behind the last piece: the look of it, or NIL
  (column 0)   ; how many characters of text as it is typed are on the line, for where a tab leads
  marker       ; what is to stand before the next line, left of the block: (text . look), the mark or the number of an item
  lines        ; the lines so far, the last first
  boxes
  links        ; what each link was written as, the last first,
  (count 0)    ;   and how many there are
  marks
  mixed        ; lines were made out of their order, as a table's are, cell by cell
  list         ; the list that an item is in: (:ul . how deep) or (:ol . the number of the next item)
  (depth 0)    ; how deep in the tree the laying out is
  measuring    ; nothing is laid out: only how wide things are is found,
  (least 0)    ;   the widest that cannot be broken,
  (most 0))    ;   and the widest line when nothing is broken

(defconstant +far+ 1000000)   ; the right edge of a line that is as long as it likes, while widths are found
(defconstant +least-room+ 64) ; a block that would be narrower than this for standing in from its edges does not stand in,
(defconstant +least-item+ 16) ; and neither does a list whose items would be narrower than this
(defconstant +deepest+ 200)   ; what lies deeper in the tree of a page than this is not shown

;; The font of a look: NIL for the console's letters, which stand in where
;; a font cannot be had.
(defun font-of (look)
  (let ((font (look-font look)))
    (cond ((eq font :cells) nil)
          (font)
          (t
           (let ((made (ignore-errors (clara.type:font (look-family look) (look-size look) :bold (look-bold look)
                                                       :italic (look-italic look) :underline (look-underline look)
                                                       :strike (look-strike look)))))
             (setf (look-font look) (or made :cells))
             made)))))

(defun wide (text look)
  (clara.draw:text-width text (font-of look)))

;; How far the letters of a look reach above the line that they stand on,
;; and how far below it the next line begins.
(defun above (look)
  (let ((font (font-of look)))
    (+ (look-rise look) (if font (clara.type:font-ascent font) 12))))

(defun below (look)
  (let ((font (font-of look)))
    (- (if font (- (clara.type:font-height font) (clara.type:font-ascent font)) 4) (look-rise look))))

;; A look like LOOK but for CHANGES: :BOLD, :ITALIC, :UNDERLINE, :STRIKE and
;; :KEPT with T, :SIZE with pixels, :SCALE with hundredths of the size that
;; it has, :MONO with T for letters as they are typed, :COLOR, :LINK and
;; :RISE.
(defun changed (look changes)
  (let ((new (copy-structure look)))
    (setf (look-font new) nil)
    (when (getf changes :bold) (setf (look-bold new) t))
    (when (getf changes :italic) (setf (look-italic new) t))
    (when (getf changes :underline) (setf (look-underline new) t))
    (when (getf changes :strike) (setf (look-strike new) t))
    (when (getf changes :kept) (setf (look-kept new) t))
    (when (getf changes :size) (setf (look-size new) (getf changes :size)))
    (when (getf changes :scale)
      (setf (look-size new) (floor (+ (* (look-size new) (getf changes :scale)) 50) 100)))
    (when (and (getf changes :mono) (not (string= (look-family new) "Mono")))
      (setf (look-family new) "Mono"
            (look-size new) (floor (+ (* (look-size new) 13) 8) 16)))
    (when (getf changes :color) (setf (look-color new) (getf changes :color)))
    (when (getf changes :link) (setf (look-link new) (getf changes :link)))
    (when (getf changes :rise) (setf (look-rise new) (+ (look-rise new) (getf changes :rise))))
    (when (< (look-size new) 9) (setf (look-size new) 9))
    (when (> (look-size new) 72) (setf (look-size new) 72))
    new))

;;; Lines

(defun more-gap (laying pixels)
  (when (> pixels (laying-gap laying))
    (setf (laying-gap laying) pixels)))

;; The gap that was asked for is left, here.
(defun leave-gap (laying)
  (setf (laying-y laying) (+ (laying-y laying) (laying-gap laying))
        (laying-gap laying) 0))

;; Text goes onto the line that is being put together, behind what is
;; there: into the piece before it when the two look the same.
(defun add-piece (laying text look width)
  (unless (laying-measuring laying)
    (let ((last (car (laying-pieces laying))))
      (if (and last (eq (piece-look last) look))
          (setf (piece-text last) (concatenate 'string (piece-text last) text)
                (piece-width last) (+ (piece-width last) width))
          (setf (laying-pieces laying)
                (cons (make-piece :x (laying-pen laying) :up 0 :width width :text text :look look) (laying-pieces laying))))))
  (when (> (length text) 0)
    (setf (laying-added laying) (+ (laying-added laying) 1)))
  (setf (laying-pen laying) (+ (laying-pen laying) width)
        (laying-fresh laying) nil))

;; The line that is being put together is done: it is as high as its
;; highest letters, its pieces stand on one line of their own whatever their
;; sizes, and it lies under the line before it and the gap. Nothing happens
;; when nothing is on it.
(defun end-line (laying)
  (unless (laying-fresh laying)
    (if (laying-measuring laying)
        (let ((wide (+ (laying-pen laying) (- +far+ (laying-right laying)))))
          (when (> wide (laying-most laying))
            (setf (laying-most laying) wide)))
        (let ((pieces (nreverse (laying-pieces laying))) (up 0) (down 0)
              (shift (let ((room (- (laying-right laying) (laying-pen laying))))
                       (cond ((<= room 0) 0)
                             ((eq (laying-align laying) :center) (floor room 2))
                             ((eq (laying-align laying) :right) room)
                             (t 0)))))
          (when (laying-marker laying)
            (let* ((marker (laying-marker laying))
                   (width (wide (car marker) (cdr marker))))
              (setq pieces (cons (make-piece :x (- (laying-left laying) width 6 shift) :up 0 :width width :text (car marker)
                                             :look (cdr marker))
                                 pieces))
              (setf (laying-marker laying) nil)))
          (dolist (piece pieces)
            (let ((a (above (piece-look piece))) (b (below (piece-look piece))))
              (when (> a up) (setq up a))
              (when (> b down) (setq down b))))
          (dolist (piece pieces)
            (setf (piece-up piece) (- up (above (piece-look piece)))
                  (piece-x piece) (+ (piece-x piece) shift)))
          (leave-gap laying)
          (setf (laying-lines laying) (cons (make-line :top (laying-y laying) :height (+ up down) :pieces pieces)
                                            (laying-lines laying))
                (laying-y laying) (+ (laying-y laying) up down)))))
  (setf (laying-pieces laying) nil
        (laying-pen laying) (laying-left laying)
        (laying-fresh laying) t
        (laying-column laying) 0))

;; A line ends here because the page says so: the one that is being put
;; together, or an empty one when nothing is on it.
(defun break-line (laying look)
  (cond ((not (laying-fresh laying))
         (end-line laying))
        ((not (laying-measuring laying))
         (leave-gap laying)
         (setf (laying-y laying) (+ (laying-y laying) (above look) (below look))))))

;; How many characters of WORD fit into ROOM pixels: one at the least.
(defun fitting (word look room)
  (let ((count 0) (width 0) (end (length word)))
    (loop
      (when (>= count end)
        (return))
      (setq width (+ width (wide (string (char word count)) look)))
      (when (and (> width room) (> count 0))
        (return))
      (setq count (+ count 1)))
    count))

;; A word goes onto the line, behind the white space that stands before it,
;; or onto the next line when this one has no room for it. A word that no
;; line has room for is cut where the line ends.
(defun place-word (laying word look)
  (let* ((width (wide word look))
         (space (and (not (laying-fresh laying)) (laying-space laying)))
         (gap (if space (wide " " space) 0))
         (left (laying-left laying)) (right (laying-right laying)))
    (when (laying-measuring laying)
      (let ((needed (+ left width (- +far+ right))))
        (when (> needed (laying-least laying))
          (setf (laying-least laying) needed))))
    (when (and (not (laying-fresh laying)) (> (+ (laying-pen laying) gap width) right))
      (end-line laying)
      (setq space nil))
    (unless (laying-measuring laying)
      (loop
        (unless (and (laying-fresh laying) (> width (- right left)) (> (length word) 1))
          (return))
        (let ((count (fitting word look (- right left))))
          (add-piece laying (subseq word 0 count) look (wide (subseq word 0 count) look))
          (end-line laying)
          (setq word (subseq word count)
                width (wide word look)))))
    (when space
      (add-piece laying " " space gap))
    (setf (laying-space laying) nil)
    (add-piece laying word look width)))

;; The word of TEXT from FROM to TO as it is drawn: a space that does not
;; break a line is a space in it, and characters that only say where a word
;; may be broken, or that nothing is drawn for, are not in it.
(defun word-of (text from to)
  (let ((plain t) (i from))
    (loop
      (when (>= i to)
        (return))
      (let ((code (char-code (char text i))))
        (when (or (< code 32) (= code 160) (= code 173) (and (>= code 8203) (<= code 8207)) (= code 8288) (= code 65279))
          (setq plain nil)
          (return)))
      (setq i (+ i 1)))
    (if plain
        (subseq text from to)
        (with-output-to-string (out)
          (let ((i from))
            (loop
              (when (>= i to)
                (return))
              (let ((code (char-code (char text i))))
                (cond ((= code 160) (write-string " " out))
                      ((or (< code 32) (= code 173) (and (>= code 8203) (<= code 8207)) (= code 8288) (= code 65279)))
                      (t (write-string (string (char text i)) out))))
              (setq i (+ i 1))))))))

;; Text as it is typed: its lines end where the page ends them, a tab leads
;; to the next column that eight goes into, and a line that is longer than
;; the block is wide goes on in the next one.
(defun lay-kept (laying text look)
  (let ((from 0) (end (length text)))
    (loop
      (let ((stop (place-of 10 text from end)))
        (when (> stop from)
          (let ((run (if (< (place-of 9 text from stop) stop)
                         (with-output-to-string (out)
                           (let ((column (laying-column laying)) (i from))
                             (loop
                               (when (>= i stop)
                                 (return))
                               (cond ((= (char-code (char text i)) 9)
                                      (write-string (subseq "        " 0 (- 8 (rem column 8))) out)
                                      (setq column (+ column (- 8 (rem column 8)))))
                                     (t
                                      (write-string (string (char text i)) out)
                                      (setq column (+ column 1))))
                               (setq i (+ i 1)))))
                         (word-of text from stop))))
            (setf (laying-column laying) (+ (laying-column laying) (length run)))
            (loop
              (let ((width (wide run look)) (room (- (laying-right laying) (laying-pen laying))))
                (when (or (laying-measuring laying) (<= width room) (<= (length run) 1))
                  (when (> (length run) 0)
                    (add-piece laying run look width))
                  (return))
                (let ((count (if (and (not (laying-fresh laying)) (< room (wide (subseq run 0 1) look)))
                                 0
                                 (fitting run look room))))
                  (when (> count 0)
                    (add-piece laying (subseq run 0 count) look (wide (subseq run 0 count) look)))
                  (end-line laying)
                  (setq run (subseq run count)))))))
        (when (>= stop end)
          (return))
        (break-line laying look)
        (setq from (+ stop 1))))))

;; The text of a page: its words go onto the lines, with one space where
;; the page has white space between them, whatever it is.
(defun lay-text (laying text look)
  (if (look-kept look)
      (lay-kept laying text look)
      (let ((i 0) (end (length text)))
        (loop
          (when (>= i end)
            (return))
          (cond ((space-p (char-code (char text i)))
                 (setf (laying-space laying) look) ; which counts for nothing where no word stands before it
                 (setq i (+ i 1)))
                (t
                 (let ((from i))
                   (loop
                     (when (or (>= i end) (space-p (char-code (char text i))))
                       (return))
                     (setq i (+ i 1)))
                   (let ((word (word-of text from i)))
                     (when (> (length word) 0)
                       (place-word laying word look))))))))))

;;; What is in an element, as words

;; The text of a tree, as it is written, one piece after the other.
(defun text-into (node out)
  (cond ((stringp node) (write-string node out))
        ((in (node-tag node) '(:script :style :template)))
        (t (dolist (child (node-children node))
             (text-into child out)))))

;; A text with one space wherever it has white space, and none at its ends.
(defun squeezed (text)
  (with-output-to-string (out)
    (let ((i 0) (end (length text)) (first t))
      (loop
        (setq i (past-space text i end))
        (when (>= i end)
          (return))
        (let ((from i))
          (loop
            (when (or (>= i end) (space-p (char-code (char text i))))
              (return))
            (setq i (+ i 1)))
          (unless first
            (write-string " " out))
          (write-string (word-of text from i) out)
          (setq first nil))))))

(defun words-of (node)
  (squeezed (with-output-to-string (out) (text-into node out))))

;; The first element of the kind TAG in a tree, or NIL.
(defun find-element (node tag)
  (cond ((stringp node) nil)
        ((eq (node-tag node) tag) node)
        (t (let ((children (node-children node)))
             (loop
               (when (null children)
                 (return nil))
               (let ((found (find-element (car children) tag)))
                 (when found
                   (return found)))
               (setq children (cdr children)))))))

;; Does the page want an element not to be seen? Of all the ways in which a
;; page can say that, these are the ones that an element says of itself.
(defun unseen-p (node)
  (or (said node "hidden")
      (let ((style (said node "style")))
        (and style
             (let ((plain (with-output-to-string (out)
                            (dotimes (i (length style))
                              (unless (space-p (char-code (char style i)))
                                (write-string (string (char style i)) out))))))
               (or (seek plain "display:none" 0) (seek plain "visibility:hidden" 0)))))))

;;; Elements, each as its kind looks

;; The kinds that begin on a line of their own and end one: the space above
;; and below, how far in from the left and from the right, and what changes
;; in how their text looks.
(defvar *blocks*
  '((:p 16 16 0 0) (:div 0 0 0 0) (:body 0 0 0 0) (:html 0 0 0 0) (:section 0 0 0 0) (:article 0 0 0 0) (:aside 0 0 0 0)
    (:nav 0 0 0 0) (:header 0 0 0 0) (:footer 0 0 0 0) (:main 0 0 0 0) (:hgroup 0 0 0 0) (:search 0 0 0 0)
    (:form 0 0 0 0) (:fieldset 8 8 8 8) (:legend 0 0 0 0 :bold t) (:details 0 0 0 0) (:summary 0 0 0 0 :bold t)
    (:figure 16 16 40 40) (:figcaption 0 0 0 0) (:blockquote 16 16 40 40) (:address 0 0 0 0 :italic t)
    (:center 0 0 0 0 :align :center) (:dl 16 16 0 0) (:dt 0 0 0 0) (:dd 0 0 40 0)
    (:h1 21 21 0 0 :size 32 :bold t) (:h2 20 20 0 0 :size 24 :bold t) (:h3 19 19 0 0 :size 19 :bold t)
    (:h4 21 21 0 0 :bold t) (:h5 22 22 0 0 :size 13 :bold t) (:h6 25 25 0 0 :size 11 :bold t)
    (:pre 16 16 0 0 :mono t :kept t :ground t) (:listing 16 16 0 0 :mono t :kept t :ground t)
    (:xmp 16 16 0 0 :mono t :kept t :ground t) (:plaintext 16 16 0 0 :mono t :kept t :ground t)
    (:caption 0 0 0 0 :align :center) (:marquee 0 0 0 0) (:optgroup 0 0 0 0) (:option 0 0 0 0) (:dialog 16 16 0 0)))

;; And the kinds that stand in a line, with what changes in how their text
;; looks.
(defvar *inlines*
  '((:b :bold t) (:strong :bold t) (:i :italic t) (:em :italic t) (:cite :italic t) (:var :italic t) (:dfn :italic t)
    (:u :underline t) (:ins :underline t) (:s :strike t) (:strike :strike t) (:del :strike t)
    (:code :mono t) (:kbd :mono t) (:samp :mono t) (:tt :mono t) (:small :scale 83) (:big :scale 117)
    (:th :bold t)))

;; Kinds of which nothing is shown: what a page says of itself, what it runs,
;; and what stands in for things that this does not do.
(defvar *unshown*
  '(:head :script :style :template :title :meta :link :base :basefont :datalist :noembed :noframes :area :param :source
    :track :col :colgroup :frameset :frame :map :slot))

(defun row-of (tag rows)
  (loop
    (when (null rows)
      (return nil))
    (when (eq (car (car rows)) tag)
      (return (cdr (car rows))))
    (setq rows (cdr rows))))

(defun lay-children (laying node look)
  (dolist (child (node-children node))
    (lay laying child look)))

;; A place of the page has a name: where the next line goes.
(defun note-mark (laying node)
  (unless (laying-measuring laying)
    (let ((name (or (said node "id") (and (eq (node-tag node) :a) (said node "name")))))
      (when (and name (> (length name) 0))
        (setf (laying-marks laying) (cons (cons name (+ (laying-y laying) (laying-gap laying))) (laying-marks laying)))))))

;; How an element says that its lines stand: :CENTER, :RIGHT, :LEFT, or NIL
;; when it says nothing.
(defun align-of (node)
  (let ((align (said node "align")))
    (cond ((null align) nil)
          ((string-equal align "center") :center)
          ((string-equal align "middle") :center)
          ((string-equal align "right") :right)
          ((string-equal align "left") :left))))

;; An element that begins on a line of its own, with SPACE above it and
;; below it, LEFT and RIGHT pixels in from the block that it is in.
(defun lay-block (laying node look above under left right align)
  (end-line laying)
  (more-gap laying above)
  (note-mark laying node)
  (let ((old-left (laying-left laying)) (old-right (laying-right laying)) (old-align (laying-align laying)))
    ;; a block keeps some room, however deep in others it is
    (when (< (- old-right old-left left right) +least-room+)
      (setq left 0
            right 0))
    (setf (laying-left laying) (+ old-left left)
          (laying-right laying) (- old-right right)
          (laying-pen laying) (+ old-left left)
          (laying-align laying) (or align (align-of node) old-align))
    (lay-children laying node look)
    (end-line laying)
    (setf (laying-left laying) old-left
          (laying-right laying) old-right
          (laying-pen laying) old-left
          (laying-align laying) old-align))
  (more-gap laying under))

;; Text as it is typed, in a block of its own, on a ground of another colour.
(defun lay-ground (laying node look above under)
  (end-line laying)
  (more-gap laying above)
  (note-mark laying node)
  (unless (laying-measuring laying)
    (leave-gap laying))
  (let ((top (laying-y laying)) (old-left (laying-left laying)) (old-right (laying-right laying))
        (old-align (laying-align laying)))
    (setf (laying-left laying) (+ old-left 8)
          (laying-right laying) (- old-right 8)
          (laying-pen laying) (+ old-left 8)
          (laying-align laying) :left
          (laying-y laying) (+ top 6))
    (lay-children laying node look)
    (end-line laying)
    (setf (laying-left laying) old-left
          (laying-right laying) old-right
          (laying-pen laying) old-left
          (laying-align laying) old-align)
    (unless (laying-measuring laying)
      (setf (laying-gap laying) 0
            (laying-y laying) (+ (laying-y laying) 6))
      (setf (laying-boxes laying)
            (cons (make-box :x old-left :y top :width (- old-right old-left) :height (- (laying-y laying) top)
                            :color (colors-ground (laying-colors laying)))
                  (laying-boxes laying)))))
  (more-gap laying under))

;; A list. What is kept of it while its items are laid out: its kind, :OL
;; for one that counts and :UL for another; the number of its next item, or
;; how deep in lists of its kind it is; and whether it stands in from its
;; block, which it does where there is room.
(defun lay-list (laying node look)
  (let* ((old (laying-list laying))
         (ordered (eq (node-tag node) :ol))
         (start (and ordered (said node "start") (number-in (said node "start") 10)))
         (room (>= (- (laying-right laying) (laying-left laying) 40) +least-item+)))
    (setf (laying-list laying) (list (if ordered :ol :ul)
                                     (cond (ordered (or start 1))
                                           ((and old (eq (first old) :ul)) (+ (second old) 1))
                                           (t 0))
                                     room))
    (end-line laying)
    (more-gap laying (if old 0 16))
    (note-mark laying node)
    (let ((old-left (laying-left laying)))
      (setf (laying-left laying) (+ old-left (if room 40 0))
            (laying-pen laying) (laying-left laying))
      (lay-children laying node look)
      (end-line laying)
      (setf (laying-left laying) old-left
            (laying-pen laying) old-left))
    (more-gap laying (if old 0 16))
    (setf (laying-list laying) old)))

;; An item of a list: its mark stands left of its first line, a number in a
;; list that counts and a dot in another; or before its first word, where
;; the list has no room to stand in. An item that is in no list is one all
;; the same.
(defun lay-item (laying node look)
  (end-line laying)
  (let* ((list (laying-list laying))
         (deep (and list (eq (first list) :ul) (> (second list) 0)))
         (mark (cond ((and list (eq (first list) :ol))
                      (let ((number (or (and (said node "value") (number-in (said node "value") 10)) (second list))))
                        (rplaca (cdr list) (+ number 1))
                        (format nil "~D." number)))
                     ((null (font-of look)) (if deep "-" "*"))   ; the console's letters have no dot for it
                     (t (string (code-char (if deep 9702 8226))))))
         (beside (if list
                     (third list)
                     (>= (- (laying-right laying) (laying-left laying) 40) +least-room+))))
    (cond (beside
           (unless (laying-measuring laying)
             (setf (laying-marker laying) (cons mark look)))
           (lay-block laying node look 0 0 (if list 0 40) 0 nil)
           ;; an item with nothing in it still has its mark
           (when (laying-marker laying)
             (add-piece laying "" look 0)
             (end-line laying)))
          (t
           (note-mark laying node)
           (place-word laying mark look)
           (setf (laying-space laying) look)
           (lay-children laying node look)
           (end-line laying)))))

;; A line across.
(defun lay-rule (laying)
  (end-line laying)
  (more-gap laying 8)
  (unless (laying-measuring laying)
    (leave-gap laying)
    (setf (laying-boxes laying)
          (cons (make-box :x (laying-left laying) :y (laying-y laying) :width (- (laying-right laying) (laying-left laying))
                          :height 1 :color (colors-rule (laying-colors laying)))
                (laying-boxes laying))
          (laying-y laying) (+ (laying-y laying) 1)))
  (more-gap laying 8))

;; Words that stand for something that is not shown as it is: a picture, a
;; field to type in.
(defun lay-stand-in (laying words look)
  (lay-text laying words (changed look (list :color (colors-dim (laying-colors laying))))))

;; The words that something in a tree has for itself, where it shows none:
;; the first that an element of it says as its label, its title, or what
;; stands for a picture. NIL when there are none.
(defun inner-words (node)
  (and (not (stringp node))
       (or (let ((found nil))
             (dolist (name '("aria-label" "title" "alt") found)
               (let ((words (said node name)))
                 (when (and (null found) words (> (length (trimmed words)) 0))
                   (setq found (squeezed words))))))
           (let ((children (node-children node)) (found nil))
             (loop
               (when (or found (null children))
                 (return found))
               (setq found (inner-words (car children))
                     children (cdr children)))))))

;; A name for the place that an address leads to, for a link that has no
;; words at all: the last step of its path, or the machine.
(defun place-name (address)
  (multiple-value-bind (kind machine path) (parts address)
    (declare (ignore kind))
    (let ((end (length path)))
      (loop
        (unless (and (> end 0) (= (char-code (char path (- end 1))) 47))
          (return))
        (setq end (- end 1)))
      (let ((from end))
        (loop
          (when (or (= from 0) (= (char-code (char path (- from 1))) 47))
            (return))
          (setq from (- from 1)))
        (cond ((> end from) (subseq path from end))
              ((and machine (> (length machine) 0)) machine)
              (t "link"))))))

;; A link: its text looks like one, and where it leads is kept.
(defun lay-link (laying node look)
  (let ((written (said node "href")))
    (note-mark laying node)
    (if (null written)
        (lay-children laying node look)
        (let* ((colors (laying-colors laying))
               (number (laying-count laying))
               (seen (and (laying-seen laying)
                          (member (without-part (sendable (address-from (laying-base laying) (trimmed written))))
                                  (laying-seen laying) :test #'string=))))
          (unless (laying-measuring laying)
            (setf (laying-links laying) (cons written (laying-links laying))
                  (laying-count laying) (+ number 1)))
          (let ((look (changed look (list :link number :underline t :color (if seen (colors-seen colors) (colors-link colors)))))
                (before (laying-added laying)))
            (lay-children laying node look)
            ;; a link that shows nothing gets the words that it has for itself, or a name for where it leads, so that
            ;; there is something of it to pick
            (when (= (laying-added laying) before)
              (lay-text laying (concatenate 'string "[" (or (inner-words node) (place-name (trimmed written))) "]") look)))))))

;; What stands for a field of a form, or for a button: nothing of a form
;; can be filled in or sent.
(defun lay-field (laying node look)
  (let* ((tag (node-tag node))
         (kind (string-downcase (or (said node "type") "text")))
         (value (or (said node "value") "")))
    (cond ((eq tag :textarea)
           (lay-stand-in laying (concatenate 'string "[" (words-of node) "]") look))
          ((eq tag :select)
           (let ((option (or (let ((found nil))
                               (dolist (child (node-children node) found)
                                 (when (and (not (stringp child)) (null found) (eq (node-tag child) :option) (said child "selected"))
                                   (setq found child))))
                             (find-element node :option))))
             (lay-stand-in laying (concatenate 'string "[" (if option (words-of option) "") "]") look)))
          ((eq tag :button)
           (lay-stand-in laying "[" look)
           (lay-children laying node look)
           (lay-stand-in laying "]" look))
          ((string= kind "hidden"))
          ((or (string= kind "submit") (string= kind "button") (string= kind "reset"))
           (lay-stand-in laying (concatenate 'string "[" (if (> (length value) 0) value kind) "]") look))
          ((string= kind "checkbox")
           (lay-stand-in laying (if (said node "checked") "[x]" "[ ]") look))
          ((string= kind "radio")
           (lay-stand-in laying (if (said node "checked") "(o)" "( )") look))
          ((string= kind "image")
           (lay-stand-in laying (concatenate 'string "[" (or (said node "alt") "submit") "]") look))
          (t
           (let ((shown (if (> (length value) 0) value (or (said node "placeholder") ""))))
             (lay-stand-in laying (concatenate 'string "[" shown (if (< (length shown) 8) (subseq "________" (length shown)) "") "]")
                           look))))))

;; A picture, which is not fetched: the words that the page has for it, or
;; a word that says that one is there.
(defun lay-picture (laying node look)
  (let ((words (said node "alt")) (width (said node "width")) (height (said node "height")))
    (cond ((and words (> (length (trimmed words)) 0))
           (lay-stand-in laying (concatenate 'string "[" (squeezed words) "]") look))
          (words)                       ; the page says that the picture needs no words
          ((or (and width (let ((number (number-in width 10))) (and number (< number 3))))
               (and height (let ((number (number-in height 10))) (and number (< number 3)))))) ; a picture that is not for the eye
          (t (lay-stand-in laying "[picture]" look)))))

;;; Tables

;; The rows of a table, each a list of its cells, and the elements that say
;; what the table is, in two values. What stands in a table and is neither
;; is laid out before it, by whoever calls.
(defun table-rows (node)
  (let ((rows nil) (captions nil) (others nil))
    (flet ((row (element)
             (let ((cells nil))
               (dolist (child (node-children element))
                 (unless (and (stringp child) (blank-p child))
                   (setq cells (cons child cells))))
               (setq rows (cons (nreverse cells) rows)))))
      (dolist (child (node-children node))
        (cond ((stringp child)
               (unless (blank-p child)
                 (setq others (cons child others))))
              ((eq (node-tag child) :tr) (row child))
              ((in (node-tag child) '(:tbody :thead :tfoot))
               (dolist (inner (node-children child))
                 (cond ((stringp inner))
                       ((eq (node-tag inner) :tr) (row inner))
                       (t (setq others (cons inner others))))))
              ((eq (node-tag child) :caption) (setq captions (cons child captions)))
              ((in (node-tag child) '(:colgroup :col)))
              (t (setq others (cons child others))))))
    (values (nreverse rows) (nreverse captions) (nreverse others))))

;; Across how many columns a cell reaches.
(defun span-of (cell)
  (let ((span (and (not (stringp cell)) (said cell "colspan") (number-in (trimmed (said cell "colspan")) 10))))
    (if (and span (> span 0) (< span 100)) span 1)))

;; The look of what is in a cell, and how its lines stand.
(defun cell-look (cell look)
  (if (and (not (stringp cell)) (eq (node-tag cell) :th)) (changed look '(:bold t)) look))

(defun cell-align (cell)
  (cond ((stringp cell) :left)
        ((align-of cell))
        ((eq (node-tag cell) :th) :center)
        (t :left)))

;; What is in a cell is laid out by the rules of everything else.
(defun lay-cell (laying cell look)
  (if (stringp cell)
      (lay-text laying cell look)
      (lay-children laying cell look)))

;; How wide what is in a cell is: at the least, when every line is broken
;; wherever it can be, and at the most, when none is.
(defun measure (laying cell look)
  (let ((measuring (make-laying :colors (laying-colors laying) :base (laying-base laying) :right +far+
                                :depth (laying-depth laying) :measuring t)))
    (lay-cell measuring cell look)
    (end-line measuring)
    (values (laying-least measuring) (laying-most measuring))))

(defconstant +cell-side+ 4)    ; the room in a cell left and right of what is in it,
(defconstant +cell-above+ 2)   ; and above and below
(defconstant +cell-between+ 2) ; and between two cells

;; How wide the columns of a table are, in a vector, when the table has
;; ROOM pixels for what is in its cells; and, in two more values, how wide
;; they are together at the least and at the most. Every column is as wide
;; as its widest cell where there is room for that, no narrower than its
;; longest word where there is room for that, and between the two by how
;; much it could do with otherwise.
(defun column-widths (laying rows look count room)
  (let ((least (make-array count :initial-element 0)) (most (make-array count :initial-element 0))
        (spanning nil))
    (dolist (row rows)
      (let ((column 0))
        (dolist (cell row)
          (let ((span (span-of cell)))
            (multiple-value-bind (narrow wide) (measure laying cell (cell-look cell look))
              (cond ((= span 1)
                     (when (> narrow (svref least column)) (setf (svref least column) narrow))
                     (when (> wide (svref most column)) (setf (svref most column) wide)))
                    (t (setq spanning (cons (list column span narrow wide) spanning)))))
            (setq column (+ column span))))))
    ;; a cell across several columns makes them wider between them, when it has to
    (dolist (wide-cell (reverse spanning))
      (let* ((column (first wide-cell)) (span (min (second wide-cell) (- count column)))
             (between (* (- span 1) (+ +cell-side+ +cell-side+ +cell-between+))))
        (dolist (which '(nil t))
          (let ((widths (if which most least)) (needed (- (if which (fourth wide-cell) (third wide-cell)) between)) (have 0))
            (dotimes (i span)
              (setq have (+ have (svref widths (+ column i)))))
            (when (> needed have)
              (let ((more (floor (+ (- needed have) span -1) span)))
                (dotimes (i span)
                  (setf (svref widths (+ column i)) (+ (svref widths (+ column i)) more)))))))))
    (let ((narrow 0) (wide 0) (widths (make-array count :initial-element 0)))
      (dotimes (i count)
        (when (< (svref most i) (svref least i))
          (setf (svref most i) (svref least i)))
        (setq narrow (+ narrow (svref least i))
              wide (+ wide (svref most i))))
      (dotimes (i count)
        (setf (svref widths i)
              (cond ((<= wide room) (svref most i))
                    ((<= narrow room)
                     (+ (svref least i)
                        (if (> wide narrow)
                            (floor (* (- (svref most i) (svref least i)) (- room narrow)) (- wide narrow))
                            0)))
                    ((> narrow 0) (max 1 (floor (* (svref least i) room) narrow)))
                    (t 1))))
      (values widths narrow wide))))

(defun lay-table (laying node look)
  (multiple-value-bind (rows captions others) (table-rows node)
    (end-line laying)
    (note-mark laying node)
    (dolist (other others)
      (lay laying other look))
    (end-line laying)
    (let ((count 0))
      (dolist (row rows)
        (let ((columns 0))
          (dolist (cell row)
            (setq columns (+ columns (span-of cell))))
          (when (> columns count)
            (setq count columns))))
      (let* ((left (laying-left laying)) (right (laying-right laying))
             (around (+ (* count (+ +cell-side+ +cell-side+)) (* (+ count 1) +cell-between+)))
             (room (max count (- right left around))))
        (cond ((= count 0))
              ((laying-measuring laying)
               (multiple-value-bind (widths narrow wide) (column-widths laying rows look count room)
                 (when (and widths (> (+ left narrow around (- +far+ right)) (laying-least laying)))
                   (setf (laying-least laying) (+ left narrow around (- +far+ right))))
                 (when (> (+ left wide around (- +far+ right)) (laying-most laying))
                   (setf (laying-most laying) (+ left wide around (- +far+ right))))))
              (t
               (dolist (caption captions)
                 (lay-block laying caption look 0 0 0 0 :center))
               (let ((widths (column-widths laying rows look count room))
                     (framed (let ((border (said node "border"))) (and border (not (string= border "0")))))
                     (old-align (laying-align laying)) (old-list (laying-list laying)))
                 (leave-gap laying)
                 (setf (laying-mixed laying) t
                       (laying-list laying) nil)
                 (dolist (row rows)
                   (let ((top (laying-y laying)) (bottom (laying-y laying)) (column 0)
                         (x (+ left +cell-between+)) (frames nil))
                     (dolist (cell row)
                       (let* ((span (min (span-of cell) (- count column)))
                              (width (let ((sum (* (- span 1) (+ +cell-side+ +cell-side+ +cell-between+))))
                                       (dotimes (i span sum)
                                         (setq sum (+ sum (svref widths (+ column i))))))))
                         (setf (laying-left laying) (+ x +cell-side+)
                               (laying-right laying) (+ x +cell-side+ width)
                               (laying-pen laying) (+ x +cell-side+)
                               (laying-y laying) (+ top +cell-above+)
                               (laying-gap laying) 0
                               (laying-align laying) (cell-align cell))
                         (unless (stringp cell)
                           (note-mark laying cell))
                         (lay-cell laying cell (cell-look cell look))
                         (end-line laying)
                         (when (> (laying-y laying) bottom)
                           (setq bottom (laying-y laying)))
                         (setq frames (cons (cons x (+ width +cell-side+ +cell-side+)) frames)
                               x (+ x width +cell-side+ +cell-side+ +cell-between+)
                               column (+ column span))))
                     (setq bottom (+ bottom +cell-above+))
                     (when framed
                       (dolist (frame frames)
                         (let ((color (colors-rule (laying-colors laying))) (fx (car frame)) (fw (cdr frame)) (fh (- bottom top)))
                           (setf (laying-boxes laying)
                                 (list* (make-box :x fx :y top :width fw :height 1 :color color)
                                        (make-box :x fx :y (+ top fh -1) :width fw :height 1 :color color)
                                        (make-box :x fx :y top :width 1 :height fh :color color)
                                        (make-box :x (+ fx fw -1) :y top :width 1 :height fh :color color)
                                        (laying-boxes laying))))))
                     (setf (laying-y laying) (+ bottom +cell-between+)
                           (laying-gap laying) 0)))
                 (setf (laying-left laying) left
                       (laying-right laying) right
                       (laying-pen laying) left
                       (laying-gap laying) 0
                       (laying-align laying) old-align
                       (laying-list laying) old-list))))))))

;;; The tree, laid out

(defun lay (laying node look)
  (cond ((stringp node)
         (lay-text laying node look))
        ((>= (laying-depth laying) +deepest+))
        (t
         (setf (laying-depth laying) (+ (laying-depth laying) 1))
         (let* ((tag (node-tag node)) (block (and (not (stringp tag)) (row-of tag *blocks*))))
           (cond ((in tag *unshown*))
                 ((unseen-p node))
                 ((and (said node "aria-label") (said node "role") (string-equal (said node "role") "img"))
                  (note-mark laying node)   ; something that stands for a picture and has words for it: the words
                  (lay-text laying (said node "aria-label") look))
                 ((stringp tag)             ; a kind that this file does not name is text like any other
                  (note-mark laying node)
                  (lay-children laying node look))
                 ((eq tag :svg)
                  (let ((words (or (said node "aria-label")
                                   (let ((title (find-element node :title))) (and title (words-of title))))))
                    (when (and words (> (length words) 0) (not (equal (said node "aria-hidden") "true")))
                      (lay-stand-in laying (concatenate 'string "[" words "]") look))))
                 ((and (eq tag :dialog) (null (said node "open"))))
                 (block
                  (let ((changes (cdr (cdddr block))))
                    (if (getf changes :ground)
                        (lay-ground laying node (changed look changes) (first block) (second block))
                        (lay-block laying node (if changes (changed look changes) look) (first block) (second block)
                                   (third block) (fourth block) (getf changes :align)))))
                 ((in tag '(:ul :ol :menu :dir)) (lay-list laying node look))
                 ((eq tag :li) (lay-item laying node look))
                 ((eq tag :table) (lay-table laying node look))
                 ((in tag '(:tbody :thead :tfoot :tr))   ; outside a table, a row is a line
                  (lay-block laying node look 0 0 0 0 nil))
                 ((eq tag :br)
                  (break-line laying look))
                 ((eq tag :hr) (lay-rule laying))
                 ((eq tag :a) (lay-link laying node look))
                 ((eq tag :img) (note-mark laying node) (lay-picture laying node look))
                 ((in tag '(:input :button :select :textarea)) (lay-field laying node look))
                 ((eq tag :q)
                  (lay-text laying (string (code-char 8220)) look)
                  (lay-children laying node look)
                  (lay-text laying (string (code-char 8221)) look))
                 ((eq tag :sup)
                  (lay-children laying node (changed look (list :scale 75 :rise (floor (look-size look) 3)))))
                 ((eq tag :sub)
                  (lay-children laying node (changed look (list :scale 75 :rise (- (floor (look-size look) 5))))))
                 ((in tag '(:iframe :embed))
                  (let ((from (said node "src")))
                    (when (and from (> (length from) 0))
                      (lay laying (make-node :tag :a :said (list (cons "href" from))
                                             :children (list (concatenate 'string "[a page in this one: " from "]")))
                           look))))
                 ((in tag '(:video :audio))
                  (lay-stand-in laying (if (eq tag :video) "[video]" "[sound]") look))
                 (t
                  (note-mark laying node)
                  (let ((changes (row-of tag *inlines*)))
                    (lay-children laying node (if changes (changed look changes) look))))))
         (setf (laying-depth laying) (- (laying-depth laying) 1)))))

;; The page that a tree is, laid out WIDTH pixels wide. ADDRESS is where it
;; was had, and SEEN the addresses that were visited before.
(defun lay-page (tree address width colors seen)
  (let* ((base (let ((element (find-element tree :base)))
                 (if (and element (said element "href"))
                     (address-from address (trimmed (said element "href")))
                     address)))
         (laying (make-laying :colors colors :base base :seen seen :left 8 :right (- width 8) :pen 8 :gap 8))
         (title (let ((element (find-element tree :title)))
                  (and element (let ((words (words-of element))) (and (> (length words) 0) words)))))
         (body (or (find-element tree :body) tree)))
    (lay laying body (make-look :color (colors-ink colors)))
    (end-line laying)
    (let* ((lines (let ((lines (nreverse (laying-lines laying))))
                    (if (laying-mixed laying) (sort lines #'< :key #'line-top) lines)))
           (count (length lines))
           (vector (make-array count :initial-element nil))
           (links (make-array (laying-count laying) :initial-element nil))
           (tallest 0) (i 0))
      (dolist (line lines)
        (setf (svref vector i) line
              i (+ i 1))
        (when (> (line-height line) tallest)
          (setq tallest (line-height line))))
      (setq i (laying-count laying))
      (dolist (link (laying-links laying))
        (setq i (- i 1))
        (setf (svref links i) link))
      (make-page :address address :base base :title title :lines vector :boxes (nreverse (laying-boxes laying))
                 :links links :marks (laying-marks laying) :width width
                 :height (+ (laying-y laying) (max 8 (laying-gap laying))) :tallest tallest))))

;; The lines of a page as text, a string to the line: what a window of that
;; width shows, without its looks.
(defun page-text (page)
  (let ((texts nil) (lines (page-lines page)))
    (dotimes (i (length lines))
      (setq texts (cons (with-output-to-string (out)
                          (dolist (piece (line-pieces (svref lines i)))
                            (write-string (piece-text piece) out)))
                        texts)))
    (nreverse texts)))

;;; Fetching
;;;
;;; A page is asked for over a connection that is kept closed, HTTPS, and
;;; over no other: an address that is written with http:// is asked for with
;;; https:// in its place, and a machine that does not answer so shows no
;;; page here. What arrives says what it is: a page, a text, or something
;;; that this does not show.

(defconstant +most-bytes+ 4194304) ; a page of more bytes than this is not taken
(defconstant +most-moves+ 10)      ; and one that is said to be somewhere else more often than this is not followed

;; What a head of HTTP's says of NAME, or NIL.
(defun head-says (lines name)
  (let ((found nil))
    (dolist (line lines found)
      (unless found
        (setq found (clara.net::field line name))))))

;; What kind of thing arrived, by what was said of it and by its first
;; bytes: :PAGE, :TEXT, or a string that says what else it is.
(defun kind-of (said memory bytes)
  (let* ((said (and said (string-downcase (trimmed (subseq said 0 (place-of 59 said 0 (length said)))))))
         (first (bytes-as-windows memory (if (< bytes 256) bytes 256))))
    (cond ((or (null said) (= (length said) 0))
           (cond ((< (place-of 0 first 0 (length first)) (length first)) "something that is no text")
                 ((and (< (past-space first 0 (length first)) (length first))
                       (= (char-code (char first (past-space first 0 (length first)))) 60))
                  :page)
                 (t :text)))
          ((or (string= said "text/html") (string= said "application/xhtml+xml")) :page)
          ((or (stands-at said 0 "text/") (string= said "application/json") (string= said "application/xml")
               (string= said "application/javascript")
               (and (> (length said) 4) (or (stands-at said (- (length said) 4) "+xml") (stands-at said (- (length said) 5) "+json"))))
           :text)
          (t said))))

;; What an address has: its text, what kind of thing it is, the address that
;; it was had at in the end, and what the other side answered, 200 when all
;; is well. An address that leads on to another is followed there.
(defun take (address)
  (let ((moves 0))
    (loop
      (multiple-value-bind (memory bytes pages at status lines) (clara.net:fetch address :limit +most-bytes+ :any t)
        (declare (ignore at))
        (let ((onward nil))
          (unwind-protect
               (let ((place (head-says lines "Location")))
                 (cond ((and (member status '(301 302 303 307 308)) place (> (length (trimmed place)) 0))
                        (when (>= moves +most-moves+)
                          (error "~A is said to be somewhere else more often than is followed" address))
                        (let ((next (address-from address (trimmed place))))
                          (setq onward (or (secure (sendable next))
                                           (error "~A leads on to ~A, which is no address of a page" address next)))))
                       (t
                        (let ((kind (kind-of (head-says lines "Content-Type") memory bytes)))
                          (return (values (if (stringp kind) "" (bytes-text memory bytes (head-says lines "Content-Type")))
                                          kind address status bytes))))))
            (clara.unsafe:free-memory memory pages))
          (setq address onward
                moves (+ moves 1)))))))

;; What fetches for a window: a function of an address that gives what TAKE
;; gives. The tests put one here that fetches from nowhere.
(defvar *take* #'take)

;;; The window
;;;
;;; An application, written like the others (lisp/emma.lisp): OPEN-VIEW
;;; makes the window and what it holds, KEY, POINT and HAPPENED change
;;; that, RENDER draws it, and RUN is the loop that the launcher's thread
;;; sits in. The window has a row for the address at its top, a row for
;;; what is going on at its bottom, and the page between them, with a bar
;;; at its right that says how far down the page the window is.

(defvar *home* nil)             ; the address that a window opens at when none is given; NIL for the page that Ares has of itself

(defconstant +row+ 22)          ; how high the row of the address is, and the row at the bottom
(defconstant +bar+ 6)           ; how wide the bar at the right is
(defconstant +step+ 40)         ; how far an arrow moves the page
(defconstant +kept-pages+ 20)   ; how many pages a window remembers the way back to

(defvar *welcome*
  "<title>Ares</title>
<h1>Ares</h1>
<p>A web browser. It shows what a page says: its text, its headings, its lists and tables, and its links. It fetches no
pictures, runs no scripts, and reads nothing of what a page says about its looks.</p>
<p>Every page is asked for over HTTPS, a connection that is kept closed.</p>
<table>
<tr><td><b>Ctrl-L</b><td>an address is typed, and Enter goes there
<tr><td><b>Tab</b><td>picks the next link, and <b>Enter</b> follows it; so does a click
<tr><td><b>Alt-Left</b>, <b>Alt-Right</b><td>the page before, and back again
<tr><td><b>Ctrl-R</b><td>asks for the page once more
<tr><td>the arrows, <b>Page Up</b>, <b>Page Down</b>, <b>Home</b>, <b>End</b><td>move the page
<tr><td><b>Ctrl-Q</b><td>closes the window
</table>
<p>ClaraOS is at <a href=\"https://claraos.org/\">claraos.org</a>, and its manual at
<a href=\"https://claraos.org/manual.html\">claraos.org/manual.html</a>.</p>")

(defstruct view
  window
  surface      ; what its window is drawn on
  width        ; the size of the window's inside
  height
  colors
  letters      ; how the text of the two rows looks
  page         ; the page that it shows
  (top 0)      ; how far down the page the first row of pixels under the address is
  shown        ; how far down it was when the page was last drawn, or NIL when all of it is to be drawn again
  back         ; the pages before this one, the nearest first: (page . how far down it was) each
  forth        ; and the ones that it went back from
  asking       ; an address is being typed
  (answer "")  ; what was typed of it so far
  message      ; words for the row at the bottom, until the next key
  picked       ; the number of the link that is picked, or NIL
  seen         ; the addresses that this window was at
  row-above    ; what the two rows show, as they were drawn
  row-below
  done)        ; the window is to close

(defun area (view)
  (- (view-height view) +row+ +row+))

;; How far down the page the window can be at the most.
(defun lowest (view)
  (max 0 (- (page-height (view-page view)) (area view))))

;;; Drawing

;; The number of the first line of LINES whose top is at Y or below it.
(defun first-line (lines y)
  (let ((low 0) (high (length lines)))
    (loop
      (when (>= low high)
        (return low))
      (let ((middle (floor (+ low high) 2)))
        (if (< (line-top (svref lines middle)) y)
            (setq low (+ middle 1))
            (setq high middle))))))

;; The rows of the page from FROM to TO, counted from its top, are drawn
;; where the window has them.
(defun paint (view from to)
  (let* ((surface (view-surface view)) (page (view-page view)) (colors (view-colors view))
         (top (view-top view)) (width (- (view-width view) +bar+))
         (y (+ +row+ (- from top))))
    (when (< from to)
      (clara.draw:with-clip (surface 0 y width (- to from))
        (clara.draw:fill-rectangle surface 0 y width (- to from) (colors-paper colors))
        (dolist (box (page-boxes page))
          (when (and (< (box-y box) to) (> (+ (box-y box) (box-height box)) from))
            (clara.draw:fill-rectangle surface (box-x box) (+ +row+ (- (box-y box) top)) (box-width box) (box-height box)
                                       (box-color box))))
        (let* ((lines (page-lines page)) (count (length lines))
               (i (first-line lines (- from (page-tallest page)))))
          (loop
            (when (>= i count)
              (return))
            (let ((line (svref lines i)))
              (when (>= (line-top line) to)
                (return))
              (when (> (+ (line-top line) (line-height line)) from)
                (dolist (piece (line-pieces line))
                  (let* ((look (piece-look piece))
                         (at (+ +row+ (- (+ (line-top line) (piece-up piece)) top))))
                    (if (and (look-link look) (eql (look-link look) (view-picked view)))
                        ;; the link that is picked, with its colours the other way round
                        (progn
                          (clara.draw:fill-rectangle surface (piece-x piece) at (piece-width piece)
                                                     (+ (above look) (below look)) (look-color look))
                          (clara.draw:draw-text surface (piece-x piece) at (piece-text piece) (colors-paper colors) nil
                                                (font-of look)))
                        (clara.draw:draw-text surface (piece-x piece) at (piece-text piece) (look-color look) nil
                                              (font-of look)))))))
            (setq i (+ i 1))))))))

;; The bar at the right: how much of the page the window shows, and where.
(defun paint-bar (view)
  (let* ((surface (view-surface view)) (colors (view-colors view)) (area (area view))
         (x (- (view-width view) +bar+)) (whole (page-height (view-page view))))
    (clara.draw:fill-rectangle surface x +row+ +bar+ area (colors-ground colors))
    (when (> whole area)
      (let* ((length (max 12 (floor (* area area) whole)))
             (at (floor (* (view-top view) (- area length)) (- whole area))))
        (clara.draw:fill-rectangle surface x (+ +row+ at) +bar+ length (colors-rule colors))))))

;; TEXT, as much of it as is no wider than ROOM pixels: its beginning, or
;; its end when TAIL says so.
(defun fitted (text look room tail)
  (cond ((<= (wide text look) room) text)
        (tail
         (loop
           (when (or (<= (length text) 1) (<= (wide text look) room))
             (return text))
           (setq text (subseq text (max 1 (floor (length text) 16))))))
        (t (subseq text 0 (fitting text look room)))))

;; One of the two rows: TEXT on GROUND, in the letters of the rows, and a
;; bar behind it where something is being typed.
(defun paint-row (view y text ink ground typing)
  (let* ((surface (view-surface view)) (look (view-letters view))
         (high (+ (above look) (below look))))
    (clara.draw:fill-rectangle surface 0 y (view-width view) +row+ ground)
    (clara.draw:draw-text surface 8 (+ y (floor (- +row+ high) 2)) text ink nil (font-of look))
    (when typing
      (clara.draw:fill-rectangle surface (+ 8 (wide text look)) (+ y +row+ -5) 8 2 ink))))

;; What the row at the top says: the address of the page, or what is being
;; typed where it stands.
(defun above-words (view)
  (if (view-asking view)
      (concatenate 'string "Address: " (view-answer view))
      (or (page-address (view-page view)) "")))

;; Where the link that is picked leads, or NIL: the address that is asked
;; for when it is followed, or the one that is written, when that is no
;; address of a page.
(defun picked-address (view)
  (let ((page (view-page view)) (picked (view-picked view)))
    (and picked (< picked (length (page-links page)))
         (let ((address (address-from (page-base page) (trimmed (svref (page-links page) picked)))))
           (or (secure (sendable address)) address)))))

;; What the row at the bottom says: what is going on, or where the link
;; that is picked leads, or how many links the page has and which keys
;; there are.
(defun below-words (view)
  (cond ((view-message view))
        ((picked-address view))
        (t
         (let* ((links (length (page-links (view-page view))))
                (count (cond ((= links 0) "no links") ((= links 1) "1 link") (t (format nil "~D links" links))))
                (keys ": Tab picks one, Enter follows it, Ctrl-L asks for an address"))
           (if (< (wide (concatenate 'string count keys) (view-letters view)) (- (view-width view) 16))
               (concatenate 'string count keys)
               count)))))

;; What the window should show is drawn on its surface: the two rows where
;; they changed, and the page where the window is over it now, of which the
;; rows that it was over before are moved and the others drawn.
(defun draw (view)
  (let* ((surface (view-surface view)) (colors (view-colors view)) (area (area view))
         (width (- (view-width view) +bar+)))
    ;; of an address that is longer than the row, its beginning shows, and its end while it is typed
    (let ((words (cons (fitted (above-words view) (view-letters view) (- (view-width view) 16) (view-asking view))
                       (view-asking view))))
      (unless (equal words (view-row-above view))
        (paint-row view 0 (car words) (colors-ink colors) (colors-ground colors) (cdr words))
        (setf (view-row-above view) words)))
    (when (> (view-top view) (lowest view))
      (setf (view-top view) (lowest view)))
    (when (< (view-top view) 0)
      (setf (view-top view) 0))
    (let ((old (view-shown view)) (top (view-top view)))
      (cond ((null old)
             (paint view top (+ top area)))
            ((= old top))
            ((and (> top old) (< (- top old) area))
             (clara.draw:copy-rectangle surface 0 (+ +row+ (- top old)) width (- area (- top old)) surface 0 +row+)
             (paint view (+ old area) (+ top area)))
            ((and (< top old) (< (- old top) area))
             (clara.draw:copy-rectangle surface 0 +row+ width (- area (- old top)) surface 0 (+ +row+ (- old top)))
             (paint view top old))
            (t
             (paint view top (+ top area))))
      (unless (eql old top)
        (paint-bar view))
      (setf (view-shown view) top))
    (let ((words (fitted (below-words view) (view-letters view) (- (view-width view) 16) nil)))
      (unless (equal words (view-row-below view))
        (paint-row view (- (view-height view) +row+) words (colors-paper colors) (colors-ink colors) nil)
        (setf (view-row-below view) words)))))

;; The window shows what it should.
(defun render (view)
  (draw view)
  (clara.windows:show (view-window view)))

;;; Pages

;; What a window is called while it shows a page: by the page's title, or
;; by its address when it has none, and by the name alone for the page that
;; Ares has of itself.
(defun title (page)
  (let ((words (or (page-title page) (page-address page))))
    (cond ((or (null words) (stands-at (or (page-address page) "") 0 "about:")) "Ares")
          ((> (length words) 60) (concatenate 'string "Ares - " (subseq words 0 60)))
          (t (concatenate 'string "Ares - " words)))))

;; A page of Ares's own making, with WORDS on it.
(defun words-page (view address heading words)
  (lay-page (make-node :tag :html
                       :children (list (make-node :tag :body
                                                  :children (list (make-node :tag :h2 :children (list heading))
                                                                  (make-node :tag :p :children (list words))))))
            address (- (view-width view) +bar+) (view-colors view) nil))

;; The page that an address has, laid out for this window; and, as a second
;; value, words about it for the row at the bottom, or NIL.
(defun page-of (view address)
  (let ((width (- (view-width view) +bar+)) (colors (view-colors view)))
    (if (stands-at address 0 "about:")
        (lay-page (read-page *welcome*) address width colors (view-seen view))
        (multiple-value-bind (text kind at status bytes) (funcall *take* address)
          (let ((words (and (/= status 200)
                            (format nil "~A answered ~D" (multiple-value-bind (kind machine) (parts at)
                                                           (declare (ignore kind))
                                                           (or machine at))
                                    status))))
            (values (cond ((stringp kind)
                           (words-page view at "Nothing to show"
                                       (format nil "What is at this address is no page and no text: ~A, ~D bytes." kind bytes)))
                          ((and words (= (length (trimmed text)) 0))
                           (words-page view at words "And it sent nothing to show."))
                          ((eq kind :page)
                           (lay-page (read-page text) at width colors (view-seen view)))
                          (t
                           (lay-page (make-node :tag :html
                                                :children (list (make-node :tag :body
                                                                           :children (list (make-node :tag :pre
                                                                                                      :children (list text))))))
                                     at width colors (view-seen view))))
                    words))))))

;; How far down a page the place of a name is, or NIL.
(defun mark-place (page name)
  (let ((found (assoc name (page-marks page) :test #'string=)))
    (and found (cdr found))))

;; The window shows PAGE from now on, TOP pixels down it.
(defun show-page (view page top)
  (setf (view-page view) page
        (view-top view) top
        (view-shown view) nil
        (view-picked view) nil)
  (clara.windows:rename-window (view-window view) (title page)))

;; The window goes to an address: the page there is fetched, which the row
;; at the bottom says while it is done, and shown, at the part that the
;; address names when it names one; and the page that was shown is the one
;; to go back to. An address of this page itself only moves the window.
;; What goes wrong is said in the row at the bottom, and the window stays
;; where it was.
(defun go-to (view address)
  (multiple-value-bind (place part) (without-part (sendable address))
    (let* ((current (view-page view))
           (asked (cond ((stands-at place 0 "about:") place)
                        ((secure place))
                        (t nil))))
      (cond ((null asked)
             (setf (view-message view)
                   (format nil "~A is no address of a page: Ares fetches what begins with https://" address)))
            ((and current part (page-address current) (string= asked (page-address current)))
             (let ((at (mark-place current part)))
               (if at
                   (setf (view-back view) (cons (cons current (view-top view)) (view-back view))
                         (view-forth view) nil
                         (view-top view) at)
                   (setf (view-message view) (format nil "this page has no part of the name ~A" part)))))
            (t
             (setf (view-message view) (concatenate 'string "fetching " asked))
             (when current
               (render view))
             (handler-case
                 (multiple-value-bind (page words) (page-of view asked)
                   (when current
                     (setf (view-back view) (cons (cons current (view-top view)) (view-back view))
                           (view-forth view) nil)
                     (when (> (length (view-back view)) +kept-pages+)
                       (setf (view-back view) (subseq (view-back view) 0 +kept-pages+))))
                   (unless (member (page-address page) (view-seen view) :test #'string=)
                     (setf (view-seen view) (cons (page-address page) (view-seen view))))
                   (show-page view page (or (and part (mark-place page part)) 0))
                   (setf (view-message view) words))
               (serious-condition (condition)
                 (setf (view-message view) (format nil "~A" condition)))))))))

;; The page before this one, or the one that the window went back from.
(defun go-back (view forth)
  (let ((pages (if forth (view-forth view) (view-back view))) (here (cons (view-page view) (view-top view))))
    (cond ((null pages)
           (setf (view-message view) (if forth "there is no page to go on to" "there is no page before this one")))
          (forth
           (setf (view-forth view) (cdr pages)
                 (view-back view) (cons here (view-back view)))
           (show-page view (car (car pages)) (cdr (car pages))))
          (t
           (setf (view-back view) (cdr pages)
                 (view-forth view) (cons here (view-forth view)))
           (show-page view (car (car pages)) (cdr (car pages)))))))

;; The page is asked for once more, and shown where the window was.
(defun again (view)
  (let ((address (page-address (view-page view))) (top (view-top view)))
    (setf (view-message view) (concatenate 'string "fetching " address))
    (render view)
    (handler-case
        (multiple-value-bind (page words) (page-of view address)
          (show-page view page top)
          (setf (view-message view) words))
      (serious-condition (condition)
        (setf (view-message view) (format nil "~A" condition))))))

;;; Links

;; The line in which a link first stands, or NIL.
(defun link-line (page number)
  (let ((lines (page-lines page)) (i 0))
    (loop
      (when (>= i (length lines))
        (return nil))
      (when (let ((found nil))
              (dolist (piece (line-pieces (svref lines i)) found)
                (when (eql (look-link (piece-look piece)) number)
                  (setq found t))))
        (return (svref lines i)))
      (setq i (+ i 1)))))

;; The next link is picked: the one behind the one that is, or the first
;; that the window shows, and the first of the page behind the last. The
;; window goes to where it stands.
(defun pick-next (view)
  (let* ((page (view-page view)) (count (length (page-links page))) (picked (view-picked view)))
    (when (> count 0)
      (let ((next (cond (picked (if (< (+ picked 1) count) (+ picked 1) 0))
                        (t
                         (let ((lines (page-lines page)) (found nil)
                               (i (first-line (page-lines page) (view-top view))))
                           (loop
                             (when (or found (>= i (length lines)))
                               (return))
                             (dolist (piece (line-pieces (svref lines i)))
                               (when (and (null found) (look-link (piece-look piece)))
                                 (setq found (look-link (piece-look piece)))))
                             (setq i (+ i 1)))
                           (or found 0))))))
        (setf (view-picked view) next
              (view-shown view) nil)
        (let ((line (link-line page next)))
          (when (and line (or (< (line-top line) (view-top view))
                              (> (+ (line-top line) (line-height line)) (+ (view-top view) (area view)))))
            (setf (view-top view) (min (lowest view) (max 0 (- (line-top line) +step+))))))))))

;; The link at a place of the window, or NIL.
(defun link-at (view x y)
  (let* ((page (view-page view)) (lines (page-lines page))
         (down (+ (view-top view) (- y +row+)))
         (i (first-line lines (- down (page-tallest page))))
         (found nil))
    (loop
      (when (or found (>= i (length lines)) (> (line-top (svref lines i)) down))
        (return found))
      (let ((line (svref lines i)))
        (when (< down (+ (line-top line) (line-height line)))
          (dolist (piece (line-pieces line))
            (when (and (>= x (piece-x piece)) (< x (+ (piece-x piece) (piece-width piece))) (look-link (piece-look piece)))
              (setq found (look-link (piece-look piece)))))))
      (setq i (+ i 1)))))

(defun follow (view number)
  (let ((page (view-page view)))
    (when (and number (< number (length (page-links page))))
      (go-to view (address-from (page-base page) (trimmed (svref (page-links page) number)))))))

;;; Keys

;; What is typed while the row at the top takes an address.
(defun answer-key (view code)
  (let ((answer (view-answer view)))
    (cond ((or (= code 10) (= code 13))
           (setf (view-asking view) nil)
           (when (> (length (trimmed answer)) 0)
             (go-to view (typed-address answer))))
          ((or (= code 27) (= code 3))
           (setf (view-asking view) nil))
          ((or (= code 8) (= code 127))
           (when (> (length answer) 0)
             (setf (view-answer view) (subseq answer 0 (- (length answer) 1)))))
          ((= code 12)                  ; Ctrl-L once more: the address of the page, to be changed
           (setf (view-answer view) (or (page-address (view-page view)) "")))
          ((and (>= code 32) (< code char-code-limit))
           (setf (view-answer view) (concatenate 'string answer (string (code-char code))))))))

;; The character with this code was typed in the window, or the key with it.
(defun key (view code)
  (setf (view-message view) nil)
  (cond ((view-asking view) (answer-key view code))
        ((= code 12)                    ; Ctrl-L
         (setf (view-asking view) t
               (view-answer view) ""))
        ((= code 9) (pick-next view))
        ((or (= code 10) (= code 13))
         (if (view-picked view)
             (follow view (view-picked view))
             (setf (view-message view) "no link is picked: Tab picks one, and Ctrl-L asks for an address")))
        ((= code 27)
         (when (view-picked view)
           (setf (view-picked view) nil
                 (view-shown view) nil)))
        ((= code clara.input:+up+) (setf (view-top view) (- (view-top view) +step+)))
        ((= code clara.input:+down+) (setf (view-top view) (+ (view-top view) +step+)))
        ((= code clara.input:+page-up+) (setf (view-top view) (- (view-top view) (- (area view) +step+))))
        ((or (= code clara.input:+page-down+) (= code 32))
         (setf (view-top view) (+ (view-top view) (- (area view) +step+))))
        ((= code clara.input:+home+) (setf (view-top view) 0))
        ((= code clara.input:+end+) (setf (view-top view) (lowest view)))
        ((or (= code (+ clara.input:+alt+ clara.input:+left+)) (= code 8)) (go-back view nil))
        ((= code (+ clara.input:+alt+ clara.input:+right+)) (go-back view t))
        ((= code 18) (again view))      ; Ctrl-R
        ((= code 17)                    ; Ctrl-Q
         (setf (view-done view) t))))

;; A button of the pointer went down or up in the window: the left one,
;; down on a link, follows it, and down on the row at the top asks for an
;; address.
(defun point (view x y buttons)
  (when (= 1 (logand buttons 1))
    (cond ((< y +row+)
           (setf (view-message view) nil
                 (view-asking view) t
                 (view-answer view) ""))
          ((and (< y (- (view-height view) +row+)) (not (view-asking view)))
           (let ((link (link-at view x y)))
             (when link
               (setf (view-message view) nil)
               (follow view link)))))))

(defun happened (view event)
  (case (car event)
    (:key (key view (cadr event)))
    (:pointer (point view (cadr event) (caddr event) (cadddr event)))
    (:close (setf (view-done view) t))))

;;; The application

;; A browser in a window of its own, which shows the page that Ares has of
;; itself until it is told where to go. WIDTH and HEIGHT are the size of the
;; window's inside, as wide as a page reads well or what the screen has
;; room for; X and Y are where the window goes. The window is the thread's
;; that calls.
(defun open-view (&key width height x y)
  (let* ((screen (clara.draw:screen))
         (width (or width (max 240 (min 760 (- (clara.draw:surface-width screen) 48)))))
         (height (or height (max 160 (min 640 (- (clara.draw:surface-height screen) 136)))))
         (window (clara.windows:open-window "Ares" width height :x x :y y :events t))
         (colors (make-colors :paper (clara.draw:color 30 27 46) :ink (clara.draw:color 232 227 244)
                              :dim (clara.draw:color 165 159 186) :link (clara.draw:color 255 121 198)
                              :seen (clara.draw:color 189 147 249) :rule (clara.draw:color 74 68 102)
                              :ground (clara.draw:color 45 41 66)))
         (view (make-view :window window :surface (clara.windows:window-surface window) :width width :height height
                          :colors colors :letters (make-look :size 13 :color (clara.draw:color 232 227 244)))))
    ;; A window that nobody said the place of stands where all of it is on the screen.
    (multiple-value-bind (at-x at-y) (clara.windows:window-position window)
      (let ((beyond (- (+ at-x width 1) (clara.draw:surface-width screen)))
            (below (- (+ at-y height 1) (clara.draw:surface-height screen))))
        (when (and (null x) (null y) (or (> beyond 0) (> below 0)))
          (clara.windows:move-window window (if (> beyond 0) (max 1 (- at-x beyond)) at-x)
                                     (if (> below 0) (max 42 (- at-y below)) at-y)))))
    (setf (view-page view) (lay-page (read-page *welcome*) "about:ares" (- width +bar+) colors nil))
    view))

;; What happens to the window is done to what it shows, and the window
;; shows what came of it, until it is to close.
(defun run (view)
  (loop
    (render view)
    (when (view-done view)
      (return))
    (happened view (clara.windows:next-event (view-window view)))
    ;; And whatever else has happened by now, before anything is drawn.
    (loop
      (let ((event (clara.windows:next-event (view-window view) 0)))
        (unless event
          (return))
        (happened view event)))))

;; The application: a window that shows the page at ADDRESS, or the one
;; that *HOME* names, or the page that Ares has of itself, and goes where
;; its links lead, until it closes. Whoever calls is the browser for as
;; long: the launcher starts a thread for that.
(defun browse (&optional address &rest options)
  (let ((view (apply #'open-view options)) (address (or address *home*)))
    (unwind-protect
         (progn
           (when address
             (render view)
             (go-to view (typed-address address)))
           (run view))
      (clara.windows:close-window (view-window view)))
    nil))

(clara.windows:define-application "Ares" #'browse)
