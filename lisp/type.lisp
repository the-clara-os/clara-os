;;;; type.lisp: outline fonts
;;;;
;;;; Letters as shapes. A font of this kind is a file that holds, for each
;;;; of its characters, the outline of the character's glyph: closed lines,
;;;; straight ones and curves, in units of the font's own. A glyph is drawn
;;;; at any size by scaling its outline and working out, for every pixel
;;;; that the shape touches, how much of the pixel it covers. That is the
;;;; pixel's shade, and the pixel takes that much of the colour of the text
;;;; (CLARA.DRAW:DRAW-SHADES): an edge that goes through pixels at a slant
;;;; comes out smooth, where a picture of one bit to the pixel has steps.
;;;;
;;;; The files are TrueType's: tables in a file, numbers with their highest
;;;; byte first, outlines of straight lines and of curves of the second
;;;; degree. What is read of one is which glyph a character has (the table
;;;; "cmap", in its formats 4 and 12), how far a glyph moves on ("hmtx"),
;;;; its outline ("glyf"), also when it is put together of other glyphs, and
;;;; where the lines of a font lie ("hhea", "post", "OS/2"). And of a font
;;;; of pictures, of emoji: which glyphs are laid over each other to make
;;;; one, each in which colour ("COLR", "CPAL"), and which glyphs in a row
;;;; are drawn as one, a flag for the two letters of its country ("GSUB",
;;;; its lists of the kind that does that). What is not read: the programs
;;;; in a font that fit an outline to the pixels of a small size, kerning,
;;;; pictures in other forms than layers of one colour each, and outlines of
;;;; the other kind (CFF), whose files are refused.
;;;;
;;;; A font, here, is such a file at a size: (font "Sans" 16) is one, and
;;;; CLARA.DRAW:DRAW-TEXT and TEXT-WIDTH take it. "Sans" is a family, the
;;;; names of four files: upright, bold, italic and both. The files of the
;;;; three families that come with the system, the Go fonts for Sans and
;;;; Mono and Charter for Serif (fonts/README.md), are among the system's
;;;; own that the handoff read into memory, so they are there on a machine
;;;; with no disk that is known here; any other name is that of a file,
;;;; which is read from its volume. A fourth family, Emoji, is the font of
;;;; the pictures, Twemoji: a text in any font has its emoji from there, at
;;;; the font's size, and so has a text in the console's letters.
;;;;
;;;; Text is drawn in a font in two ways. A line of it has each character
;;;; where the one before it ends, as wide as the character is. And text in
;;;; cells has a character to the cell, all cells as wide as the widest
;;;; character that is typed and as high as a line: a terminal, an editor
;;;; and a list are grids of those, in any font (CLARA.DRAW:DRAW-CELLS,
;;;; CELL-WIDTH and CELL-HEIGHT).
;;;;
;;;; The picture of a glyph is made the first time its character is drawn
;;;; in a font and kept with the font. It is a vector of shades in the heap,
;;;; not page frames, so the collector takes it when its font is gone. A
;;;; font comes back with a world that was saved; the bytes of its file do
;;;; not, and START, at every boot, forgets where they were and lets go of
;;;; the pictures that were made of them. The file is found again, and its
;;;; glyphs are made again, when the font is next used.
;;;;
;;;; This file loads under SBCL as well, where lisp/host/ stands in for the
;;;; machine, and the tests there hold the shades against areas that they
;;;; work out with fractions.

(defpackage "CLARA.TYPE"
  (:use "COMMON-LISP")
  (:export "START" "FONT" "FONT-P" "FONT-NAME" "FONT-SIZE" "FONT-HEIGHT" "FONT-ASCENT" "FONT-DESCENT"
           "FAMILIES" "DEFINE-FAMILY" "FORGET"))
(in-package "CLARA.TYPE")

(defconstant +smallest+ 4)      ; a font is from this many pixels to the em
(defconstant +largest+ 400)     ; to this many
(defconstant +pixels+ 1048576)  ; the most that the picture of one glyph has
(defconstant +cells+ 1048576)   ; the most shades that the fonts keep between them, before they are all let go
(defconstant +work+ 16384)      ; the most points and parts that the outline of one glyph is put together of
(defconstant +depth+ 8)         ; how deep a glyph may be made of glyphs that are made of glyphs
(defconstant +layers+ 256)      ; the most layers that a picture is put together of
(defconstant +joined+ 16)       ; the most characters that are drawn as one glyph between them
(defconstant +lists+ 4096)      ; the most lists of glyphs that go together that are looked at in one file

;; A file of outlines, as it was read at this start.
(defstruct face
  file      ; its name, as it was asked for
  memory    ; where its bytes are,
  size      ; how many of them there are,
  pages     ; and the page frames that they were read into, for FORGET to give back; NIL for a file of the system's
  start     ; *START*, as it was when the file was read
  units     ; how many of the font's units make an em
  glyphs    ; how many glyphs it has
  ascent    ; how far the letters reach above the baseline, in units,
  descent   ; how far below, a negative number,
  gap       ; and how much is left between two lines
  under     ; where a line under the text lies, from the baseline: its middle, negative below,
  stroke    ; and how thick it is
  through   ; where a line through the text lies: its top, above the baseline,
  cut       ; and how thick that is
  metrics   ; how many glyphs have an advance of their own; the ones after them have the last one's
  hmtx      ; where in the file the advances are,
  loca      ; the places of the glyphs,
  long      ; which are four bytes each, or two,
  glyf      ; the outlines,
  outlines  ; how many bytes of them,
  map       ; and the table that says which glyph a character has,
  kind      ; whose format is 4 or 12
  painted   ; where the glyphs are listed that are pictures in colours, when the file has any,
  (paintings 0) ; and how many of them there are; each is so many layers,
  layers    ; which are listed here, a glyph and the number of its colour each,
  (layered 0)   ; so many in all,
  palette   ; and the colours are here,
  (colours 0)   ; so many of them
  joins)    ; where the lists are of the glyphs that are drawn as one when they stand in a row

;; A file at a size. What was read and made for it is not in it but beside
;; it (*MADE*), so that a font which is printed at a prompt is a line, and
;; not the pictures of all its glyphs.
(defstruct font
  name      ; what it was asked for by: a family's name, or a file's
  file      ; the file that it is read from
  size      ; in pixels to the em
  underline ; a line is drawn under its text,
  strike    ; or through it
  up        ; in pixels: from the top of a line of text to its baseline,
  down      ; from there to its bottom,
  gap       ; and from there to the top of the next line
  under     ; where the line under the text begins, in rows below the baseline, and how thick it is
  stroke
  over      ; where the line through the text begins, in rows above the baseline, and how thick it is
  cut)

;; What is kept for a font at one start of the machine.
(defstruct kept
  face      ; its file, as it was read
  glyphs    ; the glyphs of the characters whose codes are below 256, where they were made, or NIL
  others    ; and of the others: (code . glyph)
  joined    ; the glyphs that stand for several characters, by their numbers in the file: (number . glyph)
  emoji     ; the font that the emoji of a text in this one are drawn in, or :NONE, once that was asked for
  wide)     ; how wide a cell of the font is, once that was asked for: CELL-WIDTH

;; What a character looks like in a font.
(defstruct glyph
  advance   ; how far the next character is to the right, in pixels
  left      ; the picture's upper left corner, from the place on the baseline where the character begins
  top
  width     ; the picture, in pixels
  height
  step      ; the shades of a row are this many items after those of the row above
  shades    ; a vector of them, or NIL for a glyph that shows nothing, a space
  layers    ; for a picture in colours, which has no shades of its own: ((glyph . pixel) ...), the lowest first,
            ; each glyph laid on in its pixel, or in the colour of the text where that is NIL
  missing)  ; the font has no glyph for the character, and this is the one that it shows for those

(defvar *start* (list 'start))  ; stands for this start of the machine
(defvar *lock* (clara:make-lock "fonts")) ; one file is read at a time
(defvar *faces* nil)            ; the files that were read at this start
(defvar *fonts* nil)            ; the fonts that were made, each once
(defvar *made* nil)             ; ((font . kept) ...): what was read and made for the ones that were used at this start
(defvar *cells* 0)              ; how many shades are kept there
(defvar *among* nil)            ; (start . font): the font of the emoji among the console's letters at that start, or NIL

;; The families: a name, and the files of its upright, bold, italic and
;; bold italic.
(defvar *families*
  (list (list "Sans" "Go-Regular.ttf" "Go-Bold.ttf" "Go-Italic.ttf" "Go-Bold-Italic.ttf")
        (list "Mono" "Go-Mono.ttf" "Go-Mono-Bold.ttf" "Go-Mono-Italic.ttf" "Go-Mono-Bold-Italic.ttf")
        (list "Serif" "Charter-Regular.ttf" "Charter-Bold.ttf" "Charter-Italic.ttf" "Charter-Bold-Italic.ttf")
        (list "Emoji" "Twemoji.Mozilla.ttf" "Twemoji.Mozilla.ttf" "Twemoji.Mozilla.ttf" "Twemoji.Mozilla.ttf")))

;;; Numbers

;; N divided by D, to the nearest whole number.
(defun nearest (n d)
  (if (< d 0)
      (floor (- 0 n n d) (- 0 d d))
      (floor (+ n n d) (+ d d))))

;; N divided by D, a whole number that is not less.
(defun at-least (n d)
  (- 0 (floor (- 0 n) d)))

;;; The bytes of a file
;;;
;;; A file is whatever somebody put on a volume, so nothing in it is taken
;;; on trust: every byte is asked for by its place in the file, and a place
;;; past the end is an error, not somebody else's memory.

(defun u8 (face at)
  (if (and (<= 0 at) (< at (face-size face)))
      (clara.unsafe:memory-8 (+ (face-memory face) at))
      (error "the font ~A ends before its byte ~D" (face-file face) at)))

(defun u16 (face at)
  (if (and (<= 0 at) (< (+ at 1) (face-size face)))
      (let ((address (+ (face-memory face) at)))
        (+ (* 256 (clara.unsafe:memory-8 address)) (clara.unsafe:memory-8 (+ address 1))))
      (error "the font ~A ends before its byte ~D" (face-file face) (+ at 1))))

(defun i8 (face at)
  (let ((n (u8 face at)))
    (if (< n 128) n (- n 256))))

(defun i16 (face at)
  (let ((n (u16 face at)))
    (if (< n 32768) n (- n 65536))))

(defun u32 (face at)
  (+ (* 65536 (u16 face at)) (u16 face (+ at 2))))

;; The four letters that a table is known by, as the number that they are
;; in a file.
(defun tag (name)
  (+ (* 16777216 (char-code (char name 0))) (* 65536 (char-code (char name 1)))
     (* 256 (char-code (char name 2))) (char-code (char name 3))))

;;; A file, read
;;;
;;; A file begins with a list of its tables: for each its four letters,
;;; where it begins, and how long it is.

;; Where the table of that name begins in the file, and how long it is; NIL
;; when the file has none. One that is shorter than LEAST bytes, or that
;; goes on past the end of the file, is an error.
(defun table (face name least)
  (let ((wanted (tag name)) (count (u16 face 4)) (found nil) (length 0))
    (dotimes (i count)
      (let ((entry (+ 12 (* 16 i))))
        (when (= (u32 face entry) wanted)
          (setq found (u32 face (+ entry 8))
                length (u32 face (+ entry 12)))
          (return))))
    (cond ((null found)
           nil)
          ((or (< length least) (> (+ found length) (face-size face)))
           (error "the table ~A of the font ~A is cut short" name (face-file face)))
          (t
           (values found length)))))

(defun needed (face name least)
  (multiple-value-bind (at length) (table face name least)
    (unless at
      (error "~A has no table ~A, and a font with outlines of this kind has one" (face-file face) name))
    (values at length)))

;; The table of a font's characters has several, for the kinds of codes
;; that there were before there was one. The ones read here are by the
;; codes of Unicode: of the form 12, which has every code, when there is
;; one, and of the form 4, which has the first 65536, otherwise.
(defun find-map (face)
  (let* ((cmap (needed face "cmap" 4)) (count (u16 face (+ cmap 2))) (best 0))
    (dotimes (i count)
      (let* ((entry (+ cmap 4 (* 8 i)))
             (platform (u16 face entry))
             (encoding (u16 face (+ entry 2)))
             (at (+ cmap (u32 face (+ entry 4))))
             (form (u16 face at))
             (worth (cond ((not (or (= platform 0) (and (= platform 3) (or (= encoding 1) (= encoding 10))))) 0)
                          ((= form 12) 2)
                          ((= form 4) 1)
                          (t 0))))
        (when (> worth best)
          (setq best worth)
          (setf (face-map face) at
                (face-kind face) form))))
    (when (= best 0)
      (error "~A has no table of its characters by their codes in Unicode" (face-file face)))))

;; A font of pictures has, for a glyph that is one, a list of other glyphs
;; that are laid over each other, the lowest first, each in a colour of the
;; font's own: the table "COLR", as far as it is such lists, and "CPAL", the
;; colours, of which the first palette is read. What a file says of its
;; colours is held against the two tables here, once, so that a layer and a
;; colour are read by their numbers afterwards.
(defun find-colours (face)
  (multiple-value-bind (colr length) (table face "COLR" 14)
    (multiple-value-bind (cpal room) (table face "CPAL" 12)
      (when (and colr cpal)
        (let ((glyphs (u16 face (+ colr 2)))
              (glyphs-at (u32 face (+ colr 4)))
              (layers-at (u32 face (+ colr 8)))
              (layers (u16 face (+ colr 12)))
              (colours (u16 face (+ cpal 2)))
              (palettes (u16 face (+ cpal 4)))
              (all (u16 face (+ cpal 6)))
              (colours-at (u32 face (+ cpal 8))))
          (unless (and (<= (+ glyphs-at (* 6 glyphs)) length)
                       (<= (+ layers-at (* 4 layers)) length)
                       (<= 1 palettes)
                       (<= (+ 12 (* 2 palettes)) room)
                       (<= (+ (u16 face (+ cpal 12)) colours) all)
                       (<= (+ colours-at (* 4 all)) room))
            (error "the font ~A says of its colours what its tables have no room for" (face-file face)))
          (setf (face-painted face) (+ colr glyphs-at)
                (face-paintings face) glyphs
                (face-layers face) (+ colr layers-at)
                (face-layered face) layers
                (face-palette face) (+ cpal colours-at (* 4 (u16 face (+ cpal 12))))
                (face-colours face) colours))))))

;; And which glyphs in a row are drawn as one: the table "GSUB" is lists of
;; several kinds, of which the kind 4 is read, glyphs that are replaced by
;; one, in its one form. A list of the kind 7 says where one of another
;; kind is, further away than two bytes can say.
(defun find-joins (face)
  (multiple-value-bind (gsub length) (table face "GSUB" 10)
    (when gsub
      (let* ((lists (+ gsub (u16 face (+ gsub 8))))
             (count (u16 face lists))
             (looked 0)
             (joins nil))
        (dotimes (i count)
          (let* ((list (+ lists (u16 face (+ lists 2 (* 2 i)))))
                 (kind (u16 face list))
                 (parts (u16 face (+ list 4))))
            (dotimes (k parts)
              (let ((part (+ list (u16 face (+ list 6 (* 2 k))))) (is kind))
                (setq looked (+ looked 1))
                (when (> looked +lists+)
                  (error "the font ~A has more than ~D lists of glyphs that go together" (face-file face) +lists+))
                (when (and (= is 7) (= (u16 face part) 1))
                  (setq is (u16 face (+ part 2))
                        part (+ part (u32 face (+ part 4)))))
                (when (and (= is 4) (< part (+ gsub length)) (= (u16 face part) 1))
                  (setq joins (cons part joins)))))))
        (setf (face-joins face) (nreverse joins))))))

;; What a file says of itself, before any glyph is asked for.
(defun read-tables (face)
  (let ((kind (u32 face 0)))
    (cond ((= kind (tag "OTTO"))
           (error "~A has outlines of the other kind (CFF), which is not read here" (face-file face)))
          ((= kind (tag "ttcf"))
           (error "~A is a collection of fonts, and one font to a file is what is read here" (face-file face)))
          ((not (or (= kind 65536) (= kind (tag "true"))))
           (error "~A is not a file of outlines: it does not begin as one" (face-file face)))))
  (let ((head (needed face "head" 54)) (maxp (needed face "maxp" 6)) (hhea (needed face "hhea" 36)))
    (setf (face-units face) (u16 face (+ head 18))
          (face-long face) (not (= 0 (i16 face (+ head 50))))
          (face-glyphs face) (u16 face (+ maxp 4))
          (face-ascent face) (i16 face (+ hhea 4))
          (face-descent face) (i16 face (+ hhea 6))
          (face-gap face) (i16 face (+ hhea 8))
          (face-metrics face) (u16 face (+ hhea 34)))
    (unless (and (= (u32 face (+ head 12)) 1594834165) ; 5F0F3CF5, which every such table has
                 (<= 16 (face-units face) 16384)
                 (<= 1 (face-metrics face) (face-glyphs face)))
      (error "the font ~A says of itself what no font is: ~D units to the em, ~D glyphs, ~D of them with an advance"
             (face-file face) (face-units face) (face-glyphs face) (face-metrics face))))
  (setf (face-hmtx face) (needed face "hmtx" (+ (* 4 (face-metrics face)) (* 2 (- (face-glyphs face) (face-metrics face)))))
        (face-loca face) (needed face "loca" (* (if (face-long face) 4 2) (+ (face-glyphs face) 1))))
  (multiple-value-bind (glyf length) (needed face "glyf" 0)
    (setf (face-glyf face) glyf
          (face-outlines face) length))
  (find-map face)
  (find-colours face)
  (find-joins face)
  ;; Where its lines lie. A font that does not say has them where most do.
  (let ((post (table face "post" 12)) (os2 (table face "OS/2" 30)) (units (face-units face)))
    (setf (face-under face) (if post (i16 face (+ post 8)) (- 0 (floor units 10)))
          (face-stroke face) (if post (i16 face (+ post 10)) (floor units 20))
          (face-cut face) (if os2 (i16 face (+ os2 26)) (floor units 20))
          (face-through face) (if os2 (i16 face (+ os2 28)) (floor units 4))))
  face)

;; Where the bytes of a file are, how many there are, and the page frames
;; that they were read into: none for a file that came with the kernel,
;; which is in memory already.
(defun bytes-of (file)
  (multiple-value-bind (memory size) (clara.unsafe:system-file file)
    (if memory
        (values memory size nil)
        (clara.fat:read-file file))))

(defun read-face (file)
  (multiple-value-bind (memory size pages) (bytes-of file)
    (let ((face (make-face :file file :memory memory :size size :pages pages :start *start*))
          (read nil))
      (unwind-protect
           (progn
             (read-tables face)
             (setq read t)
             face)
        (unless (or read (null pages))
          (clara.unsafe:free-memory memory pages))))))

;; The file of that name, read once at every start, however many fonts are
;; made of it.
(defun face-of (file)
  (clara:with-lock-held (*lock*)
    (or (find-if (lambda (face) (string= (face-file face) file)) *faces*)
        (let ((face (read-face file)))
          (setq *faces* (cons face *faces*))
          face))))

;;; Which glyph a character has

(defun index-4 (face map code)
  (let* ((twice (u16 face (+ map 6)))    ; the ranges of codes, counted twice
         (ends (+ map 14))               ; the last code of each, in rising order,
         (starts (+ ends twice 2))       ; the first of each,
         (deltas (+ starts twice))       ; what is added to a code to make it a glyph,
         (ranges (+ deltas twice))       ; and, where that is not all, how far from here the glyphs of the range are listed
         (low 0) (high (- (floor twice 2) 1)))
    (if (or (> code 65535) (< high 0))
        0
        (progn
          ;; The first range that ends at the code or after it.
          (loop
            (when (>= low high)
              (return))
            (let ((middle (floor (+ low high) 2)))
              (if (< (u16 face (+ ends (* 2 middle))) code)
                  (setq low (+ middle 1))
                  (setq high middle))))
          (let ((first (u16 face (+ starts (* 2 low)))))
            (if (or (< (u16 face (+ ends (* 2 low))) code) (> first code))
                0
                (let ((delta (u16 face (+ deltas (* 2 low))))
                      (range (u16 face (+ ranges (* 2 low)))))
                  (if (= range 0)
                      (mod (+ code delta) 65536)
                      (let ((glyph (u16 face (+ ranges (* 2 low) range (* 2 (- code first))))))
                        (if (= glyph 0) 0 (mod (+ glyph delta) 65536)))))))))))

(defun index-12 (face map code)
  (let ((low 0) (high (- (u32 face (+ map 12)) 1)) (groups (+ map 16)))
    (if (< high 0)
        0
        (progn
          ;; The first group that ends at the code or after it.
          (loop
            (when (>= low high)
              (return))
            (let ((middle (floor (+ low high) 2)))
              (if (< (u32 face (+ groups (* 12 middle) 4)) code)
                  (setq low (+ middle 1))
                  (setq high middle))))
          (let ((group (+ groups (* 12 low))))
            (if (or (< (u32 face (+ group 4)) code) (> (u32 face group) code))
                0
                (+ (u32 face (+ group 8)) (- code (u32 face group)))))))))

;; The number of the glyph that the character of a code has in the file: 0,
;; the glyph for a character that the font does not have, when it has none.
(defun index (face code)
  (let ((glyph (if (= (face-kind face) 12)
                   (index-12 face (face-map face) code)
                   (index-4 face (face-map face) code))))
    (if (< glyph (face-glyphs face)) glyph 0)))

;; How far the glyph of that number moves on, in the font's units. The
;; table has that and a second number for each of the first glyphs, and
;; the second number alone for the rest, which move on as far as the last
;; of the first.
(defun advance (face glyph)
  (let ((metrics (face-metrics face)))
    (u16 face (+ (face-hmtx face) (* 4 (if (< glyph metrics) glyph (- metrics 1)))))))

;; The second number: how far to the right of where its character begins
;; the glyph's left edge lies.
(defun bearing (face glyph)
  (let ((metrics (face-metrics face)))
    (i16 face (+ (face-hmtx face)
                 (if (< glyph metrics)
                     (+ (* 4 glyph) 2)
                     (+ (* 4 metrics) (* 2 (- glyph metrics))))))))

;;; Pictures in colours, and glyphs that stand for several characters

;; The layers of the glyph of that number, when the file has it as a
;; picture in colours: ((glyph . colour) ...), the lowest first, each a
;; glyph's number and the number of its colour. NIL for a glyph that is
;; drawn as its own outline. The glyphs that are pictures are listed in the
;; order of their numbers.
(defun layers-of (face glyph)
  (let ((low 0) (high (- (face-paintings face) 1)) (at (face-painted face)))
    (when (>= high 0)
      (loop
        (when (>= low high)
          (return))
        (let ((middle (floor (+ low high) 2)))
          (if (< (u16 face (+ at (* 6 middle))) glyph)
              (setq low (+ middle 1))
              (setq high middle))))
      (let ((entry (+ at (* 6 low))))
        (when (= (u16 face entry) glyph)
          (let ((first (u16 face (+ entry 2))) (count (u16 face (+ entry 4))) (layers nil))
            (when (or (> count +layers+) (> (+ first count) (face-layered face)))
              (error "a picture of the font ~A is put together of more than ~D layers, or of layers that the font has not"
                     (face-file face) +layers+))
            (dotimes (i count)
              (let ((layer (+ (face-layers face) (* 4 (+ first i)))))
                (setq layers (cons (cons (u16 face layer) (u16 face (+ layer 2))) layers))))
            (nreverse layers)))))))

;; The colour of that number in the font's palette: its pixel, and how much
;; of it shows, from 0 to 255. A number that the palette does not have, the
;; 65535 that a font writes for it among them, is the colour of the text:
;; NIL, and all of it.
(defun colour (face number)
  (if (< number (face-colours face))
      (let ((at (+ (face-palette face) (* 4 number))))
        (values (clara.draw:color (u8 face (+ at 2)) (u8 face (+ at 1)) (u8 face at)) (u8 face (+ at 3))))
      (values nil 255)))

;; Which of the glyphs that a list covers GLYPH is, counted from 0, or NIL
;; when it is none of them. The list at AT is the numbers of the glyphs in
;; rising order, or runs of them, the first and the last of each and which
;; the first is.
(defun covered (face at glyph)
  (let ((form (u16 face at)) (low 0) (high (- (u16 face (+ at 2)) 1)))
    (when (>= high 0)
      (cond ((= form 1)
             (loop
               (when (>= low high)
                 (return))
               (let ((middle (floor (+ low high) 2)))
                 (if (< (u16 face (+ at 4 (* 2 middle))) glyph)
                     (setq low (+ middle 1))
                     (setq high middle))))
             (and (= (u16 face (+ at 4 (* 2 low))) glyph) low))
            ((= form 2)
             (loop
               (when (>= low high)
                 (return))
               (let ((middle (floor (+ low high) 2)))
                 (if (< (u16 face (+ at 6 (* 6 middle))) glyph)
                     (setq low (+ middle 1))
                     (setq high middle))))
             (let ((run (+ at 4 (* 6 low))))
               (and (<= (u16 face run) glyph) (<= glyph (u16 face (+ run 2)))
                    (+ (u16 face (+ run 4)) (- glyph (u16 face run))))))))))

;; The glyph that the characters of STRING from START on are drawn as when
;; the font has one for several of them between them, and how many of them
;; that is: (glyph . count), or NIL when it joins nothing there. A list has, for
;; each glyph that something begins with, what may follow it and the glyph
;; that stands for all of it, and the first that fits is the one, which a
;; font writes with the longest first. A list that cannot be read joins
;; nothing, and is no error: the characters are still drawn, each by itself.
(defun joined (face string start)
  (handler-case (joined-in face string start)
    (error () nil)))

(defun joined-in (face string start)
  (let ((joins (face-joins face)) (end (length string)))
    (when joins
      (let ((first (index face (char-code (char string start))))
            (numbers (make-array +joined+ :initial-element nil)))
        (unless (= first 0)
          (dolist (part joins)
            (let ((which (covered face (+ part (u16 face (+ part 2))) first)))
              (when (and which (< which (u16 face (+ part 4))))
                (let* ((set (+ part (u16 face (+ part 6 (* 2 which)))))
                       (count (u16 face set)))
                  (dotimes (i count)
                    (let* ((entry (+ set (u16 face (+ set 2 (* 2 i)))))
                           (parts (u16 face (+ entry 2)))
                           (k 1))
                      (when (and (<= 2 parts) (<= parts +joined+) (<= (+ start parts) end))
                        (loop
                          (when (= k parts)
                            (return-from joined-in (cons (u16 face entry) parts)))
                          (unless (svref numbers k)
                            (setf (svref numbers k) (index face (char-code (char string (+ start k))))))
                          (unless (= (svref numbers k) (u16 face (+ entry 2 (* 2 k))))
                            (return))
                          (setq k (+ k 1)))))))))))))))

;;; Outlines
;;;
;;; The outline of a glyph is a list of its contours, the closed lines that
;;; it is made of. A contour is a vector with three items for each of its
;;; points: where the point is, across and up, and whether the contour goes
;;; through it. A point that it does not go through pulls a curve towards
;;; itself, from the point before it to the one after.

;; What goes with an outline from part to part while a glyph is put
;; together is a cons, BUDGET. Its CAR is how many points and parts may
;; still be taken for the glyph. Its CDR, once a glyph has been read, says
;; how that glyph lies and moves on: (move . advance), how far its points
;; are to be moved across to lie where the file says, and how far it moves
;; on, both in the font's units.
(defun spend (face budget count)
  (when (> count (car budget))
    (error "a glyph of the font ~A is put together of more than ~D points and parts" (face-file face) +work+))
  (setf (car budget) (- (car budget) count)))

;; Where in the file the glyph of that number is described; NIL for one
;; that has no outline, as a space has none.
(defun where (face glyph)
  (unless (< -1 glyph (face-glyphs face))
    (error "the font ~A has no glyph ~D" (face-file face) glyph))
  (let* ((loca (face-loca face))
         (from (if (face-long face) (u32 face (+ loca (* 4 glyph))) (* 2 (u16 face (+ loca (* 2 glyph))))))
         (to (if (face-long face) (u32 face (+ loca (* 4 glyph) 4)) (* 2 (u16 face (+ loca (* 2 glyph) 2))))))
    (cond ((>= from to)
           nil)
          ((> to (face-outlines face))
           (error "the glyph ~D of the font ~A lies past the end of the outlines" glyph (face-file face)))
          (t
           (+ (face-glyf face) from)))))

;; A glyph that is its own outline: after the count of its contours and the
;; rectangle around it, the number of the last point of each contour, the
;; program that would fit it to pixels, which is passed over, then a byte of
;; flags for every point, and then where the points are, all the places
;; across and then all the places up, each as the way from the point before.
(defun plain-outline (face at contours budget)
  (let* ((ends (+ at 10))
         (points (if (= contours 0) 0 (+ 1 (u16 face (+ ends (* 2 (- contours 1)))))))
         (place (+ ends (* 2 contours) 2 (u16 face (+ ends (* 2 contours)))))
         (flags (make-array points))
         (across (make-array points))
         (up (make-array points))
         (i 0))
    (spend face budget points)
    ;; The flags: one that has the bit 8 is followed by how often it is meant again.
    (loop
      (when (>= i points)
        (return))
      (let ((flag (u8 face place)) (again 0))
        (setq place (+ place 1))
        (unless (= 0 (logand flag 8))
          (setq again (u8 face place)
                place (+ place 1)))
        (loop
          (setf (svref flags i) flag)
          (setq i (+ i 1))
          (when (or (= again 0) (>= i points))
            (return))
          (setq again (- again 1)))))
    ;; A way across is a byte, with its sign in the flag's bit 16, when the
    ;; flag has the bit 2; else nothing at all, with the bit 16, and two bytes
    ;; without. The ways up are the same with the bits 4 and 32.
    (let ((x 0))
      (dotimes (k points)
        (let ((flag (svref flags k)))
          (cond ((not (= 0 (logand flag 2)))
                 (setq x (if (= 0 (logand flag 16)) (- x (u8 face place)) (+ x (u8 face place)))
                       place (+ place 1)))
                ((= 0 (logand flag 16))
                 (setq x (+ x (i16 face place))
                       place (+ place 2)))))
        (setf (svref across k) x)))
    (let ((y 0))
      (dotimes (k points)
        (let ((flag (svref flags k)))
          (cond ((not (= 0 (logand flag 4)))
                 (setq y (if (= 0 (logand flag 32)) (- y (u8 face place)) (+ y (u8 face place)))
                       place (+ place 1)))
                ((= 0 (logand flag 32))
                 (setq y (+ y (i16 face place))
                       place (+ place 2)))))
        (setf (svref up k) y)))
    (let ((outline nil) (first 0))
      (dotimes (c contours)
        (let ((last (u16 face (+ ends (* 2 c)))))
          (unless (and (<= first last) (< last points))
            (error "a contour of the font ~A ends before it begins" (face-file face)))
          (let ((contour (make-array (* 3 (- (+ last 1) first)))) (to 0))
            (do ((k first (+ k 1)))
                ((> k last))
              (setf (svref contour to) (svref across k)
                    (svref contour (+ to 1)) (svref up k)
                    (svref contour (+ to 2)) (not (= 0 (logand (svref flags k) 1))))
              (setq to (+ to 3)))
            (setq outline (cons contour outline)
                  first (+ last 1)))))
      (nreverse outline))))

;; The point of that number in an outline, counted through its contours:
;; where it is, across and up, as a cons.
(defun point-of (face outline number)
  (dolist (contour outline (error "a glyph of the font ~A is to be laid on a point that it does not have" (face-file face)))
    (let ((points (floor (length contour) 3)))
      (when (< number points)
        (return (cons (svref contour (* 3 number)) (svref contour (+ (* 3 number) 1)))))
      (setq number (- number points)))))

;; A glyph that is put together of others, an accented letter of the letter
;; and the accent: for each part the number of its glyph, where it goes, and
;; perhaps how it is made larger, smaller or slanted on the way, four
;; numbers in 16384ths. Where it goes is a way across and up, or two points
;; that are to lie on each other, one of what is there so far and one of the
;; part.
(defun joined-outline (face at depth budget)
  (let ((place (+ at 10)) (outline nil) (metrics nil))
    (loop
      (let* ((flags (u16 face place))
             (part (u16 face (+ place 2)))
             (words (not (= 0 (logand flags 1))))
             (ways (not (= 0 (logand flags 2))))
             (one 0) (two 0)
             (a 16384) (b 0) (c 0) (d 16384))
        (spend face budget 1)
        (setq place (+ place 4))
        (cond (words
               (setq one (if ways (i16 face place) (u16 face place))
                     two (if ways (i16 face (+ place 2)) (u16 face (+ place 2)))
                     place (+ place 4)))
              (t
               (setq one (if ways (i8 face place) (u8 face place))
                     two (if ways (i8 face (+ place 1)) (u8 face (+ place 1)))
                     place (+ place 2))))
        (cond ((not (= 0 (logand flags 8)))        ; one number for both ways
               (setq a (i16 face place)
                     d a
                     place (+ place 2)))
              ((not (= 0 (logand flags 64)))       ; one for each
               (setq a (i16 face place)
                     d (i16 face (+ place 2))
                     place (+ place 4)))
              ((not (= 0 (logand flags 128)))      ; four: across from across and from up, up from across and from up
               (setq a (i16 face place)
                     b (i16 face (+ place 2))
                     c (i16 face (+ place 4))
                     d (i16 face (+ place 6))
                     place (+ place 8))))
        (let ((contours (outline face part (+ depth 1) budget)))
          (unless (= 0 (logand flags 512))       ; the whole glyph lies and moves on as this part does by itself
            (setq metrics (cdr budget)))
          (unless (and (= a 16384) (= b 0) (= c 0) (= d 16384))
            (dolist (contour contours)
              (let ((i 0) (end (length contour)))
                (loop
                  (when (>= i end)
                    (return))
                  (let ((x (svref contour i)) (y (svref contour (+ i 1))))
                    (setf (svref contour i) (nearest (+ (* a x) (* c y)) 16384)
                          (svref contour (+ i 1)) (nearest (+ (* b x) (* d y)) 16384)))
                  (setq i (+ i 3))))))
          (unless ways
            (let ((there (point-of face outline one)) (its (point-of face contours two)))
              (setq one (- (car there) (car its))
                    two (- (cdr there) (cdr its)))))
          (dolist (contour contours)
            (let ((i 0) (end (length contour)))
              (loop
                (when (>= i end)
                  (return))
                (setf (svref contour i) (+ (svref contour i) one)
                      (svref contour (+ i 1)) (+ (svref contour (+ i 1)) two))
                (setq i (+ i 3)))))
          (setq outline (append outline contours)))
        (when (= 0 (logand flags 32))            ; no part follows this one
          (return))))
    (setf (cdr budget) metrics)
    outline))

;; The outline of the glyph of that number, in the font's units, the
;; baseline at 0 and up counted upwards. The vectors are new ones, for
;; whoever asked to change. A glyph lies where the file says that its left
;; edge is, from the place where its character begins; its points need not
;; be written from there, so a glyph that is asked for by itself, and not
;; as a part of another, has them moved by what the file says less where
;; the leftmost of them is, which its description begins with. A glyph of
;; parts lies and moves on as the part does that it names for that, when it
;; names one.
(defun outline (face glyph depth budget)
  (let ((at (where face glyph)))
    (setf (cdr budget) (cons 0 (advance face glyph)))
    (when at
      (let* ((count (i16 face at))
             (own (cons (- (bearing face glyph) (i16 face (+ at 2))) (advance face glyph)))
             (contours (cond ((>= count 0)
                              (plain-outline face at count budget))
                             ((< depth +depth+)
                              (joined-outline face at depth budget))
                             (t
                              (error "a glyph of the font ~A is made of glyphs that are made of glyphs, more than ~D deep"
                                     (face-file face) +depth+)))))
        (when (or (>= count 0) (null (cdr budget)))
          (setf (cdr budget) own))
        (when (and (= depth 0) (not (= (car (cdr budget)) 0)))
          (let ((move (car (cdr budget))))
            (dolist (contour contours)
              (let ((i 0) (end (length contour)))
                (loop
                  (when (>= i end)
                    (return))
                  (setf (svref contour i) (+ (svref contour i) move))
                  (setq i (+ i 3)))))))
        contours))))

;;; Shades
;;;
;;; How much of each pixel a shape covers. The places of an outline are in
;;; 256ths of a pixel from the upper left corner of the picture, counted
;;; across and down. Every straight piece of it is followed through the
;;; pixels that it crosses, and leaves two numbers in each: by how much the
;;; shape begins or ends to the right of the piece within that pixel, and
;;; by how much it does in every pixel further to the right, which is put
;;; into the next cell. A piece that goes down adds and one that goes up
;;; takes away, so a shape that is closed leaves nothing behind it, and
;;; summing a row from the left gives, in each cell, what the shape covers
;;; of that pixel: 131072, which is 2 times 256 times 256, for all of it.
;;;
;;; A row of the picture has a cell more than it has pixels, for what the
;;; last pixel passes on.

;; The part of a piece that lies in one pixel, going D down, with TWICE the
;; sum of how far across the pixel it begins and ends.
(defun note (cells at d twice)
  (setf (svref cells at) (+ (svref cells at) (* d (- 512 twice))))
  (setf (svref cells (+ at 1)) (+ (svref cells (+ at 1)) (* d twice))))

;; The part of a piece that lies in one row of pixels, whose cells begin at
;; AT: from XA and YA to XB and YB. Where it leaves a pixel for the next is
;; worked out from its two ends each time, so that the parts add up to the
;; whole however they are rounded.
(defun across (cells at xa ya xb yb)
  (let ((d (- yb ya)))
    (cond ((= xa xb)
           (let ((column (ash xa -8)))
             (note cells (+ at column) d (* 2 (- xa (* 256 column))))))
          ((< xa xb)
           (let ((column (ash xa -8)) (last (ash (- xb 1) -8)) (x xa) (y ya) (xe 0) (ye 0) (edge 0))
             (loop
               (setq edge (* 256 column))
               (if (= column last)
                   (setq xe xb
                         ye yb)
                   (setq xe (+ edge 256)
                         ye (+ ya (nearest (* (- xe xa) d) (- xb xa)))))
               (note cells (+ at column) (- ye y) (+ (- x edge) (- xe edge)))
               (when (= column last)
                 (return))
               (setq x xe
                     y ye
                     column (+ column 1)))))
          (t
           (let ((column (ash (- xa 1) -8)) (last (ash xb -8)) (x xa) (y ya) (xe 0) (ye 0) (edge 0))
             (loop
               (setq edge (* 256 column))
               (if (= column last)
                   (setq xe xb
                         ye yb)
                   (setq xe edge
                         ye (+ ya (nearest (* (- xe xa) d) (- xb xa)))))
               (note cells (+ at column) (- ye y) (+ (- x edge) (- xe edge)))
               (when (= column last)
                 (return))
               (setq x xe
                     y ye
                     column (- column 1))))))))

;; A straight piece of an outline, from X0 and Y0 to X1 and Y1. One that
;; runs along a row covers nothing to its right.
(defun cover (cells step x0 y0 x1 y1)
  (unless (= y0 y1)
    (let ((dx (- x1 x0)) (dy (- y1 y0)) (xa x0) (ya y0) (xb 0) (yb 0))
      (if (< y0 y1)
          (let ((row (ash y0 -8)) (last (ash (- y1 1) -8)))
            (loop
              (if (= row last)
                  (setq xb x1
                        yb y1)
                  (setq yb (* 256 (+ row 1))
                        xb (+ x0 (nearest (* (- yb y0) dx) dy))))
              (across cells (* row step) xa ya xb yb)
              (when (= row last)
                (return))
              (setq xa xb
                    ya yb
                    row (+ row 1))))
          (let ((row (ash (- y0 1) -8)) (last (ash y1 -8)))
            (loop
              (if (= row last)
                  (setq xb x1
                        yb y1)
                  (setq yb (* 256 row)
                        xb (+ x0 (nearest (* (- yb y0) dx) dy))))
              (across cells (* row step) xa ya xb yb)
              (when (= row last)
                (return))
              (setq xa xb
                    ya yb
                    row (- row 1))))))))

;; A curve from X0 and Y0 to X1 and Y1 that the point at CX and CY pulls
;; towards itself, as so many straight pieces that none of them is further
;; from the curve than a sixty-fourth of a pixel, across or down: how far
;; the curve is from the straight line between its ends is a quarter of how
;; far its middle is pulled, and for a piece of an nth of the curve it is
;; that divided by n times n. The pieces lie inside the curve, so a round
;; shape comes out lighter than it is by what they cut off; at a sixteenth
;; of a pixel, which is what others allow, that was a pixel in sixty.
(defun bend (cells step x0 y0 cx cy x1 y1)
  (let* ((pull-x (- (+ x0 x1) cx cx))
         (pull-y (- (+ y0 y1) cy cy))
         (far (let ((a (if (< pull-x 0) (- 0 pull-x) pull-x))
                    (b (if (< pull-y 0) (- 0 pull-y) pull-y)))
                (if (< a b) b a)))
         (pieces 1)
         (x x0) (y y0))
    (loop
      (when (>= (* pieces pieces 16) far)
        (return))
      (setq pieces (+ pieces 1)))
    (let ((whole (* pieces pieces)))
      (dotimes (k pieces)
        (let* ((i (+ k 1))
               (j (- pieces i))
               (to-x (if (= j 0) x1 (nearest (+ (* x0 j j) (* 2 cx i j) (* x1 i i)) whole)))
               (to-y (if (= j 0) y1 (nearest (+ (* y0 j j) (* 2 cy i j) (* y1 i i)) whole))))
          (cover cells step x y to-x to-y)
          (setq x to-x
                y to-y))))))

;; A contour, whose places are from LEFT and TOP on, which are taken off
;; them. It begins at its first point when it goes through that one, else
;; at its last, else halfway between the two; and where two points in a row
;; pull at it, it goes through the place halfway between them.
(defun follow (cells step contour left top)
  (let ((points (floor (length contour) 3)))
    (when (> points 1)
      (let* ((end (* 3 (- points 1)))
             (from 0) (to points)
             (start-x 0) (start-y 0))
        (cond ((svref contour 2)
               (setq start-x (svref contour 0)
                     start-y (svref contour 1)
                     from 1))
              ((svref contour (+ end 2))
               (setq start-x (svref contour end)
                     start-y (svref contour (+ end 1))
                     to (- points 1)))
              (t
               (setq start-x (ash (+ (svref contour 0) (svref contour end)) -1)
                     start-y (ash (+ (svref contour 1) (svref contour (+ end 1))) -1))))
        (setq start-x (- start-x left)
              start-y (- start-y top))
        (let ((x start-x) (y start-y) (pulled nil) (pull-x 0) (pull-y 0))
          (do ((i from (+ i 1)))
              ((>= i to))
            (let ((to-x (- (svref contour (* 3 i)) left))
                  (to-y (- (svref contour (+ (* 3 i) 1)) top)))
              (cond ((svref contour (+ (* 3 i) 2))
                     (if pulled
                         (bend cells step x y pull-x pull-y to-x to-y)
                         (cover cells step x y to-x to-y))
                     (setq x to-x
                           y to-y
                           pulled nil))
                    (pulled
                     (let ((middle-x (ash (+ pull-x to-x) -1)) (middle-y (ash (+ pull-y to-y) -1)))
                       (bend cells step x y pull-x pull-y middle-x middle-y)
                       (setq x middle-x
                             y middle-y
                             pull-x to-x
                             pull-y to-y)))
                    (t
                     (setq pulled t
                           pull-x to-x
                           pull-y to-y)))))
          (if pulled
              (bend cells step x y pull-x pull-y start-x start-y)
              (cover cells step x y start-x start-y)))))))

;; What the pieces left becomes shades: each cell of a row the sum of the
;; ones up to it, whichever way round the shape was drawn, as so many 255ths
;; of a pixel, to the nearest. Where two shapes lie over each other a pixel
;; is covered more than once, and is no darker for it.
(defun shade (cells step width height)
  (dotimes (row height)
    (let ((at (* row step)) (sum 0) (covered 0))
      (dotimes (column width)
        (setq sum (+ sum (svref cells (+ at column)))
              covered (if (< sum 0) (- 0 sum) sum))
        (setf (svref cells (+ at column))
              (if (< covered 131072) (ash (+ (* covered 255) 65536) -17) 255)))
      (setf (svref cells (+ at width)) 0)))
  cells)

;; The picture of a shape whose contours are given in 256ths of a pixel,
;; across and down from anywhere: a glyph that moves nothing on, or NIL for
;; a shape without a point. The picture begins at the pixel that the
;; leftmost and the topmost point lie in, and has a pixel for every one that
;; a point lies in or on the edge of.
(defun render (contours)
  (let ((left nil) (top 0) (right 0) (bottom 0))
    (dolist (contour contours)
      (let ((i 0) (end (length contour)))
        (loop
          (when (>= i end)
            (return))
          (let ((x (svref contour i)) (y (svref contour (+ i 1))))
            (cond ((null left)
                   (setq left x
                         right x
                         top y
                         bottom y))
                  (t
                   (when (< x left)
                     (setq left x))
                   (when (> x right)
                     (setq right x))
                   (when (< y top)
                     (setq top y))
                   (when (> y bottom)
                     (setq bottom y)))))
          (setq i (+ i 3)))))
    (when left
      (let* ((x (ash left -8))
             (y (ash top -8))
             (width (+ 1 (- (ash right -8) x)))
             (height (+ 1 (- (ash bottom -8) y)))
             (step (+ width 1)))
        (when (> (* width height) +pixels+)
          (error "a glyph of ~D by ~D pixels is more than is drawn here" width height))
        (let ((cells (make-array (* step height) :initial-element 0)))
          (dolist (contour contours)
            (follow cells step contour (* 256 x) (* 256 y)))
          (shade cells step width height)
          (make-glyph :advance 0 :left x :top y :width width :height height :step step :shades cells))))))

;;; Glyphs

;; Every font lets go of the glyphs that were made for it: they are made
;; again when they are next drawn.
(defun shed ()
  (setq *made* nil
        *cells* 0))

;; The glyph of that number in a font as its own outline makes it: the
;; outline brought to the font's size, in 256ths of a pixel, and turned
;; over, since a font counts upwards from its baseline and a picture
;; downwards from its top; and the picture of that. An outline that cannot
;; be read is a glyph that shows nothing, and is no error: a window still
;; has its other letters.
(defun plain (font face number)
  (let* ((size (font-size font))
         (units (face-units face))
         (budget (list +work+))
         (contours (handler-case (outline face number 0 budget)
                     (error ()
                       (setf (cdr budget) nil))))
         (advance (if (cdr budget) (cdr (cdr budget)) (advance face number))))
    (dolist (contour contours)
      (let ((i 0) (end (length contour)))
        (loop
          (when (>= i end)
            (return))
          (setf (svref contour i) (nearest (* (svref contour i) size 256) units)
                (svref contour (+ i 1)) (nearest (* (- 0 (svref contour (+ i 1))) size 256) units))
          (setq i (+ i 3)))))
    (let ((glyph (or (handler-case (render contours)
                       (error () nil))
                     (make-glyph :left 0 :top 0 :width 0 :height 0 :step 0 :shades nil))))
      (setf (glyph-advance glyph) (nearest (* advance size) units))
      glyph)))

;; The glyph of that number in a font, made: a picture in colours when the
;; file has it as one, each of its layers the glyph that it names, in its
;; colour, and as much of that as the colour says shows; and what its own
;; outline makes otherwise. A picture whose layers cannot be read shows
;; nothing, like an outline that cannot.
(defun form (font face number)
  (let ((layers (handler-case (layers-of face number)
                  (error () nil))))
    (if (null layers)
        (plain font face number)
        (let ((made nil))
          (dolist (layer layers)
            (let ((part (plain font face (car layer))))
              (when (glyph-shades part)
                (multiple-value-bind (pixel shows) (colour face (cdr layer))
                  (unless (= shows 255)
                    (let ((shades (glyph-shades part)))
                      (dotimes (i (length shades))
                        (setf (svref shades i) (nearest (* (svref shades i) shows) 255)))))
                  (setq made (cons (cons part pixel) made))))))
          (make-glyph :advance (nearest (* (advance face number) (font-size font)) (face-units face))
                      :left 0 :top 0 :width 0 :height 0 :step 0 :shades nil :layers (nreverse made))))))

;; The glyph of a character in a font, made.
(defun shape (font face code)
  (let* ((number (index face code))
         (glyph (form font face number)))
    (setf (glyph-missing glyph) (= number 0))
    glyph))

;; How many shades GLYPH holds, in itself or in its layers.
(defun shades-in (glyph)
  (let ((count (length (glyph-shades glyph))))
    (dolist (layer (glyph-layers glyph) count)
      (setq count (+ count (length (glyph-shades (car layer))))))))

;; Has the font something of its own to show for the character that GLYPH
;; was made for?
(defun shows-p (glyph)
  (and (not (glyph-missing glyph))
       (or (glyph-layers glyph) (glyph-shades glyph))
       t))

;; Where the lines of FONT lie, in pixels, by what FACE says, which is its
;; file. A line of text is high enough for whatever the font says its
;; letters reach. How far they reach below the baseline is a number below
;; nought in a file, and some files say the distance itself, the ones of
;; Serif among them: it is taken for the same either way.
(defun fit (font face)
  (let* ((size (font-size font))
         (units (face-units face))
         (below (if (< (face-descent face) 0) (- 0 (face-descent face)) (face-descent face)))
         (stroke (max 1 (nearest (* (face-stroke face) size) units)))
         (cut (max 1 (nearest (* (face-cut face) size) units))))
    (setf (font-up font) (max 1 (at-least (* (face-ascent face) size) units))
          (font-down font) (max 0 (at-least (* below size) units))
          (font-gap font) (max 0 (nearest (* (face-gap face) size) units))
          (font-stroke font) stroke
          (font-under font) (max 1 (floor (* (- 0 (face-under face) (floor (face-stroke face) 2)) size) units))
          (font-cut font) cut
          (font-over font) (max cut (nearest (* (face-through face) size) units)))
    face))

;; What is kept for FONT at this start: its file, as this start has read
;; it, and the glyphs that were made of it since. A font that was made at
;; an earlier start, in a world that was saved, finds its file again here.
(defun live (font)
  (unless (font-p font)
    (error "~S is not a font" font))
  (let ((found (assoc font *made*)))
    (if (and found (eq (face-start (kept-face (cdr found))) *start*))
        (cdr found)
        (let* ((face (face-of (font-file font)))
               (kept (make-kept :face face)))
          (fit font face)
          (setq *made* (cons (cons font kept) *made*))
          kept))))

(defun glyph (font code)
  (when (> *cells* +cells+)
    (shed))
  (let* ((kept (live font))
         (face (kept-face kept)))
    (flet ((made ()
             (let ((glyph (shape font face code)))
               (setq *cells* (+ *cells* (shades-in glyph)))
               glyph)))
      (cond ((< code 256)
             (unless (kept-glyphs kept)
               (setf (kept-glyphs kept) (make-array 256 :initial-element nil)))
             (or (svref (kept-glyphs kept) code)
                 (setf (svref (kept-glyphs kept) code) (made))))
            (t
             (let ((found (assoc code (kept-others kept))))
               (if found
                   (cdr found)
                   (let ((glyph (made)))
                     (setf (kept-others kept) (cons (cons code glyph) (kept-others kept)))
                     glyph))))))))

;; The glyph of that number in a font, which no character has by itself:
;; the one that stands for several.
(defun numbered (font number)
  (when (> *cells* +cells+)
    (shed))
  (let* ((kept (live font))
         (found (assoc number (kept-joined kept))))
    (if found
        (cdr found)
        (let ((glyph (form font (kept-face kept) number)))
          (setq *cells* (+ *cells* (shades-in glyph)))
          (setf (kept-joined kept) (cons (cons number glyph) (kept-joined kept)))
          glyph))))

;;; Fonts

(defun families ()
  (mapcar #'car *families*))

;; A family of the name NAME from here on: the files of its upright, bold,
;; italic and bold italic. Where there is no file for one, the nearest that
;; there is stands in.
(defun define-family (name regular &key bold italic bold-italic)
  (dolist (file (list name regular (or bold "") (or italic "") (or bold-italic "")))
    (unless (stringp file)
      (error "a family is a name and the names of its files, in strings, and ~S is not one" file)))
  (setq *families*
        (append (remove-if (lambda (family) (string-equal (car family) name)) *families*)
                (list (list name regular (or bold regular) (or italic regular) (or bold-italic bold italic regular)))))
  name)

;; The file of a font that is asked for by NAME: the family's, or the name
;; itself when no family has it.
(defun file-of (name bold italic)
  (let ((family (find-if (lambda (family) (string-equal (car family) name)) *families*)))
    (cond ((null family) name)
          ((and bold italic) (nth 4 family))
          (italic (cadddr family))
          (bold (caddr family))
          (t (cadr family)))))

;; The font of that name at SIZE pixels to the em: the same one every time
;; that the same is asked for. NAME is a family, "Sans", "Mono", "Serif",
;; "Emoji" or one that DEFINE-FAMILY made, of which BOLD and ITALIC pick the file, or
;; it is the name of a file of outlines. With UNDERLINE a line is drawn under its
;; text, and with STRIKE one through it.
(defun font (name size &key bold italic underline strike)
  (unless (stringp name)
    (error "a font is asked for by the name of a family or of a file, in a string, and ~S is not one" name))
  (unless (and (integerp size) (<= +smallest+ size +largest+))
    (error "the size of a font is a whole number of pixels from ~D to ~D, and ~S is not" +smallest+ +largest+ size))
  (let* ((file (file-of name bold italic))
         (underline (and underline t))
         (strike (and strike t))
         (font (or (find-if (lambda (font)
                              (and (string= (font-file font) file) (= (font-size font) size)
                                   (eq (font-underline font) underline) (eq (font-strike font) strike)))
                            *fonts*)
                   (make-font :name name :file file :size size :underline underline :strike strike))))
    ;; The file is read here, when nobody has read it yet, and what is no font is refused.
    (handler-case (live font)
      (error (condition)
        (error "~A is not a font that can be had here: ~A" name condition)))
    (unless (member font *fonts*)
      (setq *fonts* (cons font *fonts*)))
    font))

(defun font-ascent (font)
  (live font)
  (font-up font))

(defun font-descent (font)
  (live font)
  (font-down font))

;; From the top of one line of text to the top of the next.
(defun font-height (font)
  (live font)
  (+ (font-up font) (font-down font) (font-gap font)))

;;; Emoji
;;;
;;; A text has its emoji from the family Emoji, whatever font it is in: a
;;; character from the code 8192 on that the text's font has no glyph for is
;;; the picture that the font of pictures has of it, when it has one, at the
;;; same size and on the same baseline. And characters that the font of pictures has one glyph for
;;; between them are that glyph: the two letters of a country its flag, a
;;; hand and a colour the hand in that colour, two people and what joins
;;; them a pair. A character that only says such a thing shows nothing by
;;; itself (CLARA.DRAW::SILENT-P).

;; The font that the emoji of a text in FONT are drawn in: the family Emoji
;; at FONT's size, or NIL when there is no such file, or when FONT is of
;; that file itself.
(defun pictures (font)
  (let ((kept (live font)))
    (unless (kept-emoji kept)
      (let ((emoji (handler-case (font "Emoji" (font-size font))
                     (error () nil))))
        (setf (kept-emoji kept)
              (if (and emoji (not (string= (font-file emoji) (font-file font)))) emoji :none))))
    (and (font-p (kept-emoji kept)) (kept-emoji kept))))

;; Can the character of the code NEXT make one picture with the one of the
;; code CODE before it? One that shows nothing by itself, one of the five
;; colours of a hand or a face, and the second letter of a country.
(defun goes-with-p (code next)
  (or (<= #xFE00 next #xFE0F) (= next #x200D) (= next #x20E3) (<= #x1F3FB next #x1F3FF) (<= #xE0020 next #xE007F)
      (and (<= #x1F1E6 next #x1F1FF) (<= #x1F1E6 code #x1F1FF))))

;; What is drawn for the characters of STRING from START on in FONT, and how
;; many of them it is drawn for: a glyph, or NIL for a character that shows
;; nothing. EMOJI is the font of the pictures, or NIL for none.
(defun next-glyph (string start font emoji)
  (let* ((code (char-code (char string start)))
         (next (and (< (+ start 1) (length string)) (char-code (char string (+ start 1)))))
         (with (or emoji font)))
    (when (and next (goes-with-p code next))
      (let ((found (joined (kept-face (live with)) string start)))
        (when found
          (return-from next-glyph (values (numbered with (car found)) (cdr found)))))
      ;; A character that is told to be a picture is one, when there is a picture of it.
      (when (and emoji (= next #xFE0F))
        (let ((picture (glyph emoji code)))
          (when (shows-p picture)
            (return-from next-glyph (values picture 2))))))
    (if (clara.draw::silent-p (char string start))
        (values nil 1)
        (let ((glyph (glyph font code)))
          ;; The letters below 8192 are the font's own to have or not, in every text.
          (if (and emoji (glyph-missing glyph) (>= code #x2000))
              (let ((picture (glyph emoji code)))
                (values (if (shows-p picture) picture glyph) 1))
              (values glyph 1))))))

;; GLYPH with the place where its character begins on the baseline at X and
;; Y: in COLOR, or a picture in its own colours. Says whether anything of it
;; was drawn.
(defun put-glyph (surface x y glyph color)
  (let ((drew nil))
    (when (glyph-shades glyph)
      (when (clara.draw:draw-shades surface (+ x (glyph-left glyph)) (+ y (glyph-top glyph)) (glyph-shades glyph)
                                    (glyph-width glyph) (glyph-height glyph) color (glyph-step glyph))
        (setq drew t)))
    (dolist (layer (glyph-layers glyph))
      (let ((part (car layer)))
        (when (clara.draw:draw-shades surface (+ x (glyph-left part)) (+ y (glyph-top part)) (glyph-shades part)
                                      (glyph-width part) (glyph-height part) (or (cdr layer) color) (glyph-step part))
          (setq drew t))))
    drew))

;; A picture across two cells of WIDTH by HEIGHT pixels, the first of which
;; has its upper left corner at X and Y, the picture's baseline at BASELINE:
;; in the middle of the two, and nothing of it outside them.
(defun draw-pair (surface x y width height baseline picture color)
  (clara.draw:with-clip (surface x y (* 2 width) height)
    (put-glyph surface (+ x (floor (- (* 2 width) (glyph-advance picture)) 2)) baseline picture color)))

;;; Text

;; How many pixels wide STRING is in FONT: every glyph moves on by a whole
;; number of them.
(defun width (string font)
  (let ((width 0))
    (if (clara.draw::plain-p string)
        (dotimes (i (length string) width)
          (setq width (+ width (glyph-advance (glyph font (char-code (char string i)))))))
        (let ((emoji (pictures font)) (i 0) (end (length string)))
          (loop
            (when (>= i end)
              (return width))
            (multiple-value-bind (glyph count) (next-glyph string i font emoji)
              (when glyph
                (setq width (+ width (glyph-advance glyph))))
              (setq i (+ i count))))))))

;; STRING in FONT, the upper left corner of its line at X and Y, in COLOR.
;; With BACKGROUND the line is filled with that first, as wide as the text
;; and as high as the font. Says whether anything of it was drawn.
(defun draw (surface x y string color background font)
  (live font)
  (let* ((baseline (+ y (font-up font)))
         (wide (width string font))
         (plain (clara.draw::plain-p string))
         (emoji (and (not plain) (pictures font)))
         (pen x)
         (i 0)
         (end (length string))
         (drew nil))
    (when (and background (> wide 0))
      (when (clara.draw:fill-rectangle surface x y wide (+ (font-up font) (font-down font)) background)
        (setq drew t)))
    (loop
      (when (>= i end)
        (return))
      (multiple-value-bind (glyph count) (if plain
                                             (values (glyph font (char-code (char string i))) 1)
                                             (next-glyph string i font emoji))
        (when glyph
          (when (put-glyph surface pen baseline glyph color)
            (setq drew t))
          (setq pen (+ pen (glyph-advance glyph))))
        (setq i (+ i count))))
    (when (and (font-underline font) (> wide 0))
      (when (clara.draw:fill-rectangle surface x (+ baseline (font-under font)) wide (font-stroke font) color)
        (setq drew t)))
    (when (and (font-strike font) (> wide 0))
      (when (clara.draw:fill-rectangle surface x (- baseline (font-over font)) wide (font-cut font) color)
        (setq drew t)))
    drew))

;;; Text in cells
;;;
;;; A grid: every character has a cell, and all cells are one size, so that
;;; a row of text is as many cells and a place in the text a cell. A cell is
;;; as wide as the widest of the characters that are typed, the ones from the
;;; space to the tilde, moves on, which in a font of one width is how far
;;; every one of them does, and as high as a line of the font. A character
;;; stands in the middle of its cell, and nothing of it is drawn outside:
;;; a cell is drawn again by itself, whatever is in the cells around it. An
;;; emoji has two cells, its own and the next, in which the string has
;;; CLARA.DRAW:+TAKEN+, and its picture stands in the middle of the two.

;; How wide a cell of FONT is, in pixels.
(defun cell-width (font)
  (or (kept-wide (live font))
      (let ((wide 1))
        (do ((code 32 (+ code 1)))
            ((> code 126))
          (let ((advance (glyph-advance (glyph font code))))
            (when (> advance wide)
              (setq wide advance))))
        ;; The glyphs may all have been let go of on the way, and what was kept with them.
        (setf (kept-wide (live font)) wide)
        wide)))

;; STRING in FONT, a character to the cell, the upper left corner of the
;; first cell at X and Y, in COLOR. With BACKGROUND the cells are filled with
;; that first. A line under the text or through it goes across the cells,
;; as far as it lies within them. Says whether anything of it was drawn.
(defun draw-cells (surface x y string color background font)
  (live font)
  (let* ((width (cell-width font))
         (up (font-up font))
         (height (+ up (font-down font) (font-gap font)))
         (count (length string))
         (emoji (and (not (clara.draw::plain-p string)) (pictures font)))
         (drew nil))
    (when (> count 0)
      (when background
        (when (clara.draw:fill-rectangle surface x y (* count width) height background)
          (setq drew t)))
      (dotimes (i count)
        (let* ((character (char string i))
               (cell (+ x (* i width)))
               ;; The picture of an emoji that has its second cell after it.
               (picture (and emoji (< (+ i 1) count) (char= (char string (+ i 1)) clara.draw:+taken+)
                             (let ((glyph (glyph emoji (char-code character))))
                               (and (shows-p glyph) glyph)))))
          (cond (picture
                 (when (draw-pair surface cell y width height (+ y up) picture color)
                   (setq drew t)))
                ((char= character clara.draw:+taken+))
                (t
                 (let ((glyph (glyph font (char-code character))))
                   (when (glyph-shades glyph)
                     ;; Where the picture lies in its cell, from the cell's upper left corner.
                     (let ((left (+ (floor (- width (glyph-advance glyph)) 2) (glyph-left glyph)))
                           (top (+ up (glyph-top glyph))))
                       (if (and (>= left 0) (>= top 0)
                                (<= (+ left (glyph-width glyph)) width) (<= (+ top (glyph-height glyph)) height))
                           (when (clara.draw:draw-shades surface (+ cell left) (+ y top) (glyph-shades glyph)
                                                         (glyph-width glyph) (glyph-height glyph) color (glyph-step glyph))
                             (setq drew t))
                           ;; Some of it lies outside the cell, and is left out.
                           (clara.draw:with-clip (surface cell y width height)
                             (when (clara.draw:draw-shades surface (+ cell left) (+ y top) (glyph-shades glyph)
                                                           (glyph-width glyph) (glyph-height glyph) color (glyph-step glyph))
                               (setq drew t)))))))))))
      ;; As much of either line as lies within the cells, which may be none of it.
      (when (font-underline font)
        (let ((top (+ up (font-under font))))
          (when (clara.draw:fill-rectangle surface x (+ y top) (* count width)
                                           (- (min height (+ top (font-stroke font))) top) color)
            (setq drew t))))
      (when (font-strike font)
        ;; It ends above the baseline, and begins no higher than the cells do.
        (let* ((top (max 0 (- up (font-over font))))
               (bottom (+ (- up (font-over font)) (font-cut font))))
          (when (clara.draw:fill-rectangle surface x (+ y top) (* count width) (- bottom top) color)
            (setq drew t)))))
    drew))

;;; Emoji among the console's letters
;;;
;;; The console's letters are pictures of 8 by 16 pixels, of the characters
;;; from the space to the tilde. An emoji among them has two of their cells,
;;; a line of text as well as a text in cells, and is drawn in the family
;;; Emoji at the largest size whose line is no higher than a cell and whose
;;; pictures, which are an em wide, are no wider than two.

;; That font at the largest size at which a picture is no wider than WIDTH
;; pixels and a line no higher than HEIGHT; NIL when there is no such file,
;; or no such size.
(defun fitting (width height)
  (let ((face (handler-case (face-of (file-of "Emoji" nil nil))
                (error () nil))))
    (when face
      (let ((size (min width height +largest+))
            (units (face-units face))
            (below (if (< (face-descent face) 0) (- 0 (face-descent face)) (face-descent face))))
        (loop
          (when (< size +smallest+)
            (return nil))
          (when (<= (+ (max 1 (at-least (* (face-ascent face) size) units)) (max 0 (at-least (* below size) units)))
                    height)
            (return (handler-case (font "Emoji" size)
                      (error () nil))))
          (setq size (- size 1)))))))

;; The font of the emoji among the console's letters, found once at every
;; start; NIL when there is none.
(defun among-letters ()
  (let ((found *among*))
    (if (and found (eq (car found) *start*))
        (cdr found)
        (let ((font (fitting (* 2 clara.font:+width+) clara.font:+height+)))
          (setq *among* (cons *start* font))
          font))))

;; What is drawn for the characters of STRING from START on in the console's
;; letters, and how many of them it is drawn for: a glyph of EMOJI for a
;; picture, T for one cell of the console's, the character's letter or the
;; box of one that has none, and NIL for a character that shows nothing.
(defun next-letter (string start emoji)
  (let* ((character (char string start))
         (code (char-code character))
         (next (and (< (+ start 1) (length string)) (char-code (char string (+ start 1))))))
    (when (and next (goes-with-p code next))
      (let ((found (joined (kept-face (live emoji)) string start)))
        (when found
          (return-from next-letter (values (numbered emoji (car found)) (cdr found)))))
      (when (= next #xFE0F)
        (let ((picture (glyph emoji code)))
          (when (shows-p picture)
            (return-from next-letter (values picture 2))))))
    (cond ((clara.draw::silent-p character)
           (values nil 1))
          ((clara.draw:emoji-p character)
           (let ((picture (glyph emoji code)))
             (values (if (shows-p picture) picture t) 1)))
          (t
           (values t 1)))))

;; How many pixels wide STRING is in the console's letters.
(defun letters-width (string)
  (let ((emoji (among-letters)) (wide clara.font:+width+))
    (if (null emoji)
        (* wide (length string))
        (let ((width 0) (i 0) (end (length string)))
          (loop
            (when (>= i end)
              (return width))
            (multiple-value-bind (item count) (next-letter string i emoji)
              (cond ((eq item t)
                     (setq width (+ width wide)))
                    (item
                     (setq width (+ width wide wide))))
              (setq i (+ i count))))))))

;; Where the baseline of a picture of EMOJI lies in a cell of the console's
;; whose top is at Y: its line in the middle of the cell.
(defun letters-baseline (emoji y)
  (+ y (floor (- clara.font:+height+ (font-up emoji) (font-down emoji)) 2) (font-up emoji)))

;; STRING as a line of the console's letters, its upper left corner at X and
;; Y: the letters a run at a time, and the pictures between them.
(defun draw-among-letters (surface x y string color background)
  (let ((emoji (among-letters)))
    (if (null emoji)
        (clara.draw::draw-letters surface x y string color background)
        (let ((wide clara.font:+width+) (high clara.font:+height+) (baseline (letters-baseline emoji y))
              (pen x) (from nil) (i 0) (end (length string)) (drew nil))
          (flet ((letters (to)
                   ;; The letters that have waited, from FROM to before TO.
                   (when from
                     (when (clara.draw::draw-letters surface pen y (subseq string from to) color background)
                       (setq drew t))
                     (setq pen (+ pen (* wide (- to from)))
                           from nil))))
            (loop
              (when (>= i end)
                (return))
              (multiple-value-bind (item count) (next-letter string i emoji)
                (cond ((eq item t)
                       (unless from
                         (setq from i)))
                      (t
                       (letters i)
                       (when item
                         (when (and background (clara.draw:fill-rectangle surface pen y (* 2 wide) high background))
                           (setq drew t))
                         (when (draw-pair surface pen y wide high baseline item color)
                           (setq drew t))
                         (setq pen (+ pen wide wide)))))
                (setq i (+ i count))))
            (letters end))
          drew))))

;; STRING in the console's letters, a character to the cell: an emoji that
;; has its second cell after it is its picture across the two.
(defun cells-among-letters (surface x y string color background)
  (let ((emoji (among-letters)))
    (if (null emoji)
        (clara.draw::draw-letters surface x y string color background)
        (let ((wide clara.font:+width+) (high clara.font:+height+) (baseline (letters-baseline emoji y))
              (count (length string)) (from 0) (i 0) (drew nil))
          (loop
            (when (>= i count)
              (return))
            (let ((picture (and (< (+ i 1) count) (char= (char string (+ i 1)) clara.draw:+taken+)
                                (let ((glyph (glyph emoji (char-code (char string i)))))
                                  (and (shows-p glyph) glyph)))))
              (cond (picture
                     (when (< from i)
                       (when (clara.draw::draw-letters surface (+ x (* wide from)) y (subseq string from i) color background)
                         (setq drew t)))
                     (when (and background (clara.draw:fill-rectangle surface (+ x (* wide i)) y (* 2 wide) high background))
                       (setq drew t))
                     (when (draw-pair surface (+ x (* wide i)) y wide high baseline picture color)
                       (setq drew t))
                     (setq i (+ i 2)
                           from i))
                    (t
                     (setq i (+ i 1))))))
          (when (< from count)
            (when (clara.draw::draw-letters surface (+ x (* wide from)) y (subseq string from count) color background)
              (setq drew t)))
          drew))))

;;; The machine

;; The files that were read are let go of, and the glyphs that were made of
;; them: a file that has changed on its volume is read anew when a font of
;; it is next used.
(defun forget ()
  (clara:with-lock-held (*lock*)
    (dolist (face *faces*)
      (when (face-pages face)
        (clara.unsafe:free-memory (face-memory face) (face-pages face))))
    (setq *faces* nil
          *start* (list 'start)))
  (shed)
  nil)

;; NAMES with commas between them and "and" before the last.
(defun listed (names)
  (cond ((null (cdr names)) (car names))
        ((null (cddr names)) (concatenate 'string (car names) " and " (cadr names)))
        (t (concatenate 'string (car names) ", " (listed (cdr names))))))

;; What this file knew of a machine is forgotten: in a world that was saved
;; and has started again, the files that were read are memory of the
;; machine before, which is this start's to hand out again, and not given
;; back. Says which of the families have files that came with the system.
(defun start ()
  (setq *start* (list 'start)
        *faces* nil
        *lock* (clara:make-lock "fonts"))
  (shed)
  (let ((files 0) (names nil))
    (dolist (family *families*)
      (let ((seen nil) (here 0))
        (dolist (file (cdr family))
          (unless (member file seen :test #'string=)
            (setq seen (cons file seen))
            (when (clara.unsafe:system-file file)
              (setq here (+ here 1)))))
        (when (> here 0)
          (setq files (+ files here)
                names (cons (car family) names)))))
    (if names
        (format t "type: ~D files of outlines came with the system, for the fonts ~A~%" files (listed (nreverse names)))
        (format t "type: no file of outlines came with the system, and the letters are the console's~%"))
    (and names t)))

;; What draws takes it from here when it is handed a font: how wide a
;; string is and the string drawn, and for text in cells how wide and how
;; high a cell is, and a string drawn a character to the cell. And the same
;; three for a text in the console's letters that has emoji in it.
(clara.draw:provide-fonts (lambda (string font) (width string font))
                          (lambda (surface x y string color background font)
                            (draw surface x y string color background font))
                          (lambda (font) (cell-width font))
                          (lambda (font) (font-height font))
                          (lambda (surface x y string color background font)
                            (draw-cells surface x y string color background font))
                          (lambda (string) (letters-width string))
                          (lambda (surface x y string color background)
                            (draw-among-letters surface x y string color background))
                          (lambda (surface x y string color background)
                            (cells-among-letters surface x y string color background)))
