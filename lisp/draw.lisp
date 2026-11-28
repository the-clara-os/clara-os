;;;; draw.lisp: drawing
;;;;
;;;; A rasterizer: what makes pixels of rectangles, of text and of other
;;;; pixels. It draws on surfaces. A surface is a rectangle of pixels in
;;;; memory, 32 bits to the pixel. The screen is one, whose memory is the
;;;; framebuffer, and any number of others can be made, in page frames: a
;;;; picture is put together on one of those, out of sight, and copied to
;;;; the screen when it is whole, so that nobody watches it being drawn.
;;;; Text is drawn in the console's font, a picture of one bit to the pixel
;;;; for each character, or in a font of outlines, at any size, which is the
;;;; business of lisp/type.lisp: as a line, each character as wide as it is,
;;;; or a character to the cell, in cells of one size, which is what a
;;;; window of text is made of. A character that is an emoji is a picture in
;;;; colours, from a font of those, and takes two cells.
;;;;
;;;; Whatever is drawn is cut to what the surface has of it, and to the part
;;;; of the surface that drawing is kept to for the time being (WITH-CLIP):
;;;; a rectangle can lie half outside, and what is outside is not drawn. A
;;;; surface remembers which parts of it were drawn on, its damage, so that
;;;; SHOW copies to the screen what has changed and nothing else.
;;;;
;;;; The pixels themselves are written by the substrate, a rectangle to the
;;;; call (CLARA.UNSAFE:FILL-RECTANGLE-32, COPY-RECTANGLE-32, EXPAND-BITS-32
;;;; and BLEND-SHADES-32): an interpreter takes too long over every pixel.
;;;; What is here is the rest: which pixels.
;;;;
;;;; This file loads under SBCL as well, where lisp/host/ stands in for the
;;;; machine, and the tests there look at every pixel.

(defpackage "CLARA.DRAW"
  (:use "COMMON-LISP")
  (:export "START" "SCREEN" "COLOR"
           "ALLOCATE-SURFACE" "FREE-SURFACE" "SURFACE-P" "SURFACE-WIDTH" "SURFACE-HEIGHT" "PIXEL"
           "FILL-RECTANGLE" "DRAW-RECTANGLE" "COPY-RECTANGLE" "DRAW-BITMAP" "DRAW-SHADES" "DRAW-TEXT" "TEXT-WIDTH"
           "DRAW-CELLS" "CELL-WIDTH" "CELL-HEIGHT" "PROVIDE-FONTS"
           "EMOJI-P" "+TAKEN+" "IN-CELLS" "FROM-CELLS"
           "WITH-CLIP" "DAMAGE" "ADD-DAMAGE" "TAKE-DAMAGE" "SHOW"))
(in-package "CLARA.DRAW")

;;; Surfaces
;;;
;;; The pixels of a surface are not in the heap: they are page frames, or
;;; the screen's own memory, and a surface is where they are and how they
;;; are laid out. So a world that is saved keeps its surfaces and not
;;; their pixels, and a surface that came back with a world must not be
;;; drawn on: its address is somebody else's memory by then. Each surface
;;; therefore holds the machine it was made on, *MACHINE*, which START makes
;;; anew at every boot, and nothing is drawn on a surface of another.

(defstruct surface
  address  ; of its first pixel
  width    ; in pixels
  height
  pitch    ; bytes from one row of pixels to the next
  pages    ; the page frames it was made of; NIL for the screen, whose memory is not this file's to give back
  left     ; what drawing is kept to: from this pixel
  top
  right    ; to the one before this
  bottom
  damage   ; the rectangles that were drawn on since they were last taken, each a vector: left, top, right, bottom
  machine) ; *MACHINE*, as it was when the surface was made; NIL once it has been freed

(defconstant +side+ 16384)  ; the most pixels that a surface is wide or high
(defconstant +pieces+ 8)    ; the most rectangles that a surface's damage is kept as

(defvar *machine* (list 'machine)) ; stands for the machine that is running
(defvar *screen* nil)              ; the surface that is the screen, or NIL when the machine has none
(defvar *red* '(16 . 8))           ; where red is in a pixel: how far up its bits begin, and how many there are
(defvar *green* '(8 . 8))
(defvar *blue* '(0 . 8))
(defvar *fonts* nil)               ; what lisp/type.lisp handed over: eight functions in a list, or NIL

;; SURFACE, when it is one that can be drawn on.
(defun live (surface)
  (cond ((not (surface-p surface))
         (error "~S is not a surface" surface))
        ((eq (surface-machine surface) *machine*)
         surface)
        ((surface-machine surface)
         (error "this surface is of a machine that was switched off: a world is saved without its pixels"))
        (t
         (error "this surface was freed"))))

(defun allocate-surface (width height)
  (unless (and (integerp width) (integerp height) (<= 1 width +side+) (<= 1 height +side+))
    (error "a surface is from 1 to ~D pixels wide and as many high, and ~S by ~S is not" +side+ width height))
  (let* ((pitch (* 4 width))
         (pages (floor (+ (* pitch height) 4095) 4096)))
    (make-surface :address (clara.unsafe:allocate-memory pages) :width width :height height :pitch pitch
                  :pages pages :left 0 :top 0 :right width :bottom height :machine *machine*)))

(defun free-surface (surface)
  (live surface)
  (unless (surface-pages surface)
    (error "the screen is not a surface that can be freed"))
  (clara.unsafe:free-memory (surface-address surface) (surface-pages surface))
  (setf (surface-machine surface) nil
        (surface-damage surface) nil)
  nil)

(defun screen ()
  *screen*)

;;; Colours
;;;
;;; A pixel is 32 bits, and which of them hold red, green and blue is for
;;; the screen to say: every surface has its pixels the way the screen has,
;;; so that copying to the screen is copying and nothing else.

;; Where the bits of MASK are: how far up the lowest of them is, and how
;; many there are in a row.
(defun place (mask)
  (let ((shift 0) (bits 0))
    (unless (zerop mask)
      (loop
        (unless (zerop (logand mask (ash 1 shift)))
          (return))
        (setq shift (1+ shift)))
      (loop
        (when (zerop (logand mask (ash 1 (+ shift bits))))
          (return))
        (setq bits (1+ bits))))
    (cons shift bits)))

;; The pixel of a colour, each of its three parts from 0 to 255.
(defun color (red green blue)
  (unless (and (<= 0 red 255) (<= 0 green 255) (<= 0 blue 255))
    (error "the red, green and blue of a colour are each from 0 to 255, and these are ~S, ~S and ~S" red green blue))
  ;; The highest bits of each part, when a pixel has fewer than eight for it.
  (logior (ash (ash red (- (cdr *red*) 8)) (car *red*))
          (ash (ash green (- (cdr *green*) 8)) (car *green*))
          (ash (ash blue (- (cdr *blue*) 8)) (car *blue*))))

;;; Which pixels

;; The part of the rectangle of WIDTH by HEIGHT pixels at X and Y that can
;; be drawn on SURFACE: its left, its top, its right and its bottom, the
;; last two just outside it, or NIL when no pixel of it can.
(defun inside (surface x y width height)
  (live surface)
  (let ((left (surface-left surface)) (top (surface-top surface))
        (right (surface-right surface)) (bottom (surface-bottom surface)))
    (when (> x left)
      (setq left x))
    (when (> y top)
      (setq top y))
    (when (< (+ x width) right)
      (setq right (+ x width)))
    (when (< (+ y height) bottom)
      (setq bottom (+ y height)))
    (if (and (< left right) (< top bottom))
        (values left top right bottom)
        nil)))

;; The address of the pixel at X and Y.
(defun at (surface x y)
  (+ (surface-address surface) (* y (surface-pitch surface)) (* 4 x)))

;; Drawing is kept to the rectangle, as far as it was kept to it before,
;; while FUNCTION runs.
(defun clip (surface x y width height function)
  (live surface)
  (let ((left (surface-left surface)) (top (surface-top surface))
        (right (surface-right surface)) (bottom (surface-bottom surface)))
    (unwind-protect
         (progn
           (setf (surface-left surface) (max left x)
                 (surface-top surface) (max top y)
                 (surface-right surface) (min right (+ x width))
                 (surface-bottom surface) (min bottom (+ y height)))
           (funcall function))
      (setf (surface-left surface) left
            (surface-top surface) top
            (surface-right surface) right
            (surface-bottom surface) bottom))))

(defmacro with-clip ((surface x y width height) &body body)
  `(clip ,surface ,x ,y ,width ,height (lambda () ,@body)))

;;; Damage
;;;
;;; What was drawn on is kept as a few rectangles that cover it. A new one
;;; that is part of one that is there adds nothing; one that is there and
;;; part of the new one goes; and two that make a rectangle between them,
;;; side by side or one above the other, become that rectangle, which is
;;; what a line of text written a character at a time comes to. More than
;;; a few become the one rectangle around them all: what is copied then is
;;; more than changed, and never less.

(defun join (rectangles left top right bottom)
  (let ((kept nil) (grown nil))
    (dolist (rectangle rectangles)
      (let ((l (svref rectangle 0)) (tp (svref rectangle 1)) (r (svref rectangle 2)) (b (svref rectangle 3)))
        (cond ((and (<= l left) (<= tp top) (>= r right) (>= b bottom))
               (return-from join rectangles))
              ((and (<= left l) (<= top tp) (>= right r) (>= bottom b)))
              ((and (= tp top) (= b bottom) (<= l right) (<= left r))
               (setq left (min l left)
                     right (max r right)
                     grown t))
              ((and (= l left) (= r right) (<= tp bottom) (<= top b))
               (setq top (min tp top)
                     bottom (max b bottom)
                     grown t))
              (t
               (setq kept (cons rectangle kept))))))
    (cond (grown
           ;; It is larger now, and may take in others that it did not before.
           (join kept left top right bottom))
          ((< (length kept) +pieces+)
           (cons (vector left top right bottom) kept))
          (t
           (dolist (rectangle kept)
             (setq left (min left (svref rectangle 0))
                   top (min top (svref rectangle 1))
                   right (max right (svref rectangle 2))
                   bottom (max bottom (svref rectangle 3))))
           (list (vector left top right bottom))))))

;; Those pixels of SURFACE have been drawn on. What is drawn on the screen
;; shows as it is drawn, and there is nothing to remember.
(defun drawn (surface left top right bottom)
  (when (surface-pages surface)
    (setf (surface-damage surface) (join (surface-damage surface) left top right bottom)))
  t)

;; The parts of SURFACE that were drawn on since they were last taken, each
;; as a list: x, y, width and height.
(defun damage (surface)
  (live surface)
  (mapcar (lambda (rectangle)
            (list (svref rectangle 0) (svref rectangle 1)
                  (- (svref rectangle 2) (svref rectangle 0)) (- (svref rectangle 3) (svref rectangle 1))))
          (surface-damage surface)))

(defun take-damage (surface)
  (prog1 (damage surface)
    (setf (surface-damage surface) nil)))

;; For whoever has changed pixels in another way, or wants a part shown
;; again: as much of the rectangle as the surface has counts as drawn on.
(defun add-damage (surface x y width height)
  (live surface)
  (let ((left (max x 0)) (top (max y 0))
        (right (min (+ x width) (surface-width surface))) (bottom (min (+ y height) (surface-height surface))))
    (and (< left right) (< top bottom)
         (drawn surface left top right bottom))))

;;; Drawing
;;;
;;; Each of these says whether it drew anything: NIL when all of it lay
;;; outside.

;; The pixel at X and Y, or NIL when the surface has none there.
(defun pixel (surface x y)
  (live surface)
  (and (< -1 x (surface-width surface)) (< -1 y (surface-height surface))
       (clara.unsafe:memory-32 (at surface x y))))

(defun fill-rectangle (surface x y width height color)
  (multiple-value-bind (left top right bottom) (inside surface x y width height)
    (when left
      (clara.unsafe:fill-rectangle-32 (at surface left top) (surface-pitch surface) (- right left) (- bottom top)
                                      color)
      (drawn surface left top right bottom))))

;; The outline of a rectangle, a pixel thick, just inside it.
(defun draw-rectangle (surface x y width height color)
  (live surface)
  (when (and (plusp width) (plusp height))
    (let ((above (fill-rectangle surface x y width 1 color))
          (below (and (> height 1) (fill-rectangle surface x (+ y height -1) width 1 color)))
          (before (fill-rectangle surface x (1+ y) 1 (- height 2) color))
          (after (and (> width 1) (fill-rectangle surface (+ x width -1) (1+ y) 1 (- height 2) color))))
      (or above below before after))))

;; The pixels of a rectangle of FROM become the pixels of TO from TO-X and
;; TO-Y on: as many of them as FROM has, and as can be drawn on TO. The two
;; can be one surface, and the rectangles lie over each other.
(defun copy-rectangle (from x y width height to to-x to-y)
  (live from)
  (let ((left (max x 0)) (top (max y 0))
        (right (min (+ x width) (surface-width from))) (bottom (min (+ y height) (surface-height from))))
    (multiple-value-bind (to-left to-top to-right to-bottom)
        (inside to (+ to-x (- left x)) (+ to-y (- top y)) (- right left) (- bottom top))
      (when to-left
        (clara.unsafe:copy-rectangle-32 (at to to-left to-top) (surface-pitch to)
                                        (at from (+ x (- to-left to-x)) (+ y (- to-top to-y))) (surface-pitch from)
                                        (- to-right to-left) (- to-bottom to-top))
        (drawn to to-left to-top to-right to-bottom)))))

;; A picture of one bit to the pixel: BITS is a vector of its rows, each an
;; integer whose lowest WIDTH bits are the row, the leftmost pixel in the
;; highest of them. Where a bit is set the pixel becomes COLOR, and where
;; it is not, BACKGROUND; NIL for either leaves those pixels as they are.
(defun draw-bitmap (surface x y bits width color &optional background)
  (multiple-value-bind (left top right bottom) (inside surface x y width (length bits))
    (when left
      (clara.unsafe:expand-bits-32 (at surface left top) (surface-pitch surface) bits (- top y) (- bottom top)
                                   (- right left) color background (- (+ x width) right))
      (drawn surface left top right bottom))))

;; A picture in shades: SHADES is a vector with an item for each of its
;; pixels, the rows one after the other, each WIDTH long and STEP items
;; after the one before it. An item says how much of COLOR its pixel takes,
;; from 0, none, to 255, all of it: the pixel becomes what lies that far
;; between what it was and COLOR, in each of its three parts. That is what
;; the smooth edge of a shape is made of.
(defun draw-shades (surface x y shades width height color &optional (step width))
  (multiple-value-bind (left top right bottom) (inside surface x y width height)
    (when left
      (clara.unsafe:blend-shades-32 (at surface left top) (surface-pitch surface) shades
                                    (+ (* (- top y) step) (- left x)) step (- bottom top) (- right left) color
                                    (bits *red*) (bits *green*) (bits *blue*))
      (drawn surface left top right bottom))))

;; The bits of a pixel that hold a part of a colour, from where they are.
(defun bits (part)
  (ash (- (ash 1 (cdr part)) 1) (car part)))

;; Text in a font that is not the console's is drawn by lisp/type.lisp, which
;; is loaded after this file and hands over its functions: how wide a
;; string is in a font, and the string drawn; and for text in cells how wide
;; a cell of a font is, how high, and a string drawn a character to the cell.
;; The last three are for a text in the console's letters that has emoji in
;; it, whose pictures are a font's: how wide it is, the text drawn, and the
;; text drawn a character to the cell.
(defun provide-fonts (width draw cell-width cell-height cells &optional letters-width letters letter-cells)
  (setq *fonts* (list width draw cell-width cell-height cells letters-width letters letter-cells))
  t)

(defun fonts ()
  (or *fonts*
      (error "there is nothing here that draws in a font: lisp/type.lisp is not loaded")))

;;; Emoji
;;;
;;; A character that is a picture and not a letter. Which characters those
;;; are is Unicode's to say, by the property that it calls Emoji, and the
;;; table here is made of its list (tools/emoji.py). The pictures are a
;;; font's, the family Emoji of lisp/type.lisp, which draws them: in a line
;;; of text an emoji is as wide as its picture, and several characters that
;;; the font has one picture for between them, a flag, a hand in one of its
;;; colours, are that picture. In cells an emoji takes two, its own and the
;;; one after it, and nothing is put together: a cell is a character. The
;;; string that is drawn has +TAKEN+ in the second cell, a character that
;;; stands for a cell which another's picture lies in and shows nothing of
;;; its own, so that a place in such a string is still a cell. IN-CELLS
;;; makes that string of a text, and FROM-CELLS the text of it again.

;; Unicode 17.0: 1424 characters in 146 runs. Made by tools/emoji.py, and not by hand.
(defvar *emoji*
  #(#x203C #x203C #x2049 #x2049 #x2122 #x2122 #x2139 #x2139 #x2194 #x2199 #x21A9 #x21AA #x231A #x231B #x2328 #x2328
    #x23CF #x23CF #x23E9 #x23F3 #x23F8 #x23FA #x24C2 #x24C2 #x25AA #x25AB #x25B6 #x25B6 #x25C0 #x25C0 #x25FB #x25FE
    #x2600 #x2604 #x260E #x260E #x2611 #x2611 #x2614 #x2615 #x2618 #x2618 #x261D #x261D #x2620 #x2620 #x2622 #x2623
    #x2626 #x2626 #x262A #x262A #x262E #x262F #x2638 #x263A #x2640 #x2640 #x2642 #x2642 #x2648 #x2653 #x265F #x2660
    #x2663 #x2663 #x2665 #x2666 #x2668 #x2668 #x267B #x267B #x267E #x267F #x2692 #x2697 #x2699 #x2699 #x269B #x269C
    #x26A0 #x26A1 #x26A7 #x26A7 #x26AA #x26AB #x26B0 #x26B1 #x26BD #x26BE #x26C4 #x26C5 #x26C8 #x26C8 #x26CE #x26CF
    #x26D1 #x26D1 #x26D3 #x26D4 #x26E9 #x26EA #x26F0 #x26F5 #x26F7 #x26FA #x26FD #x26FD #x2702 #x2702 #x2705 #x2705
    #x2708 #x270D #x270F #x270F #x2712 #x2712 #x2714 #x2714 #x2716 #x2716 #x271D #x271D #x2721 #x2721 #x2728 #x2728
    #x2733 #x2734 #x2744 #x2744 #x2747 #x2747 #x274C #x274C #x274E #x274E #x2753 #x2755 #x2757 #x2757 #x2763 #x2764
    #x2795 #x2797 #x27A1 #x27A1 #x27B0 #x27B0 #x27BF #x27BF #x2934 #x2935 #x2B05 #x2B07 #x2B1B #x2B1C #x2B50 #x2B50
    #x2B55 #x2B55 #x3030 #x3030 #x303D #x303D #x3297 #x3297 #x3299 #x3299 #x1F004 #x1F004 #x1F0CF #x1F0CF #x1F170 #x1F171
    #x1F17E #x1F17F #x1F18E #x1F18E #x1F191 #x1F19A #x1F1E6 #x1F1FF #x1F201 #x1F202 #x1F21A #x1F21A #x1F22F #x1F22F #x1F232 #x1F23A
    #x1F250 #x1F251 #x1F300 #x1F321 #x1F324 #x1F393 #x1F396 #x1F397 #x1F399 #x1F39B #x1F39E #x1F3F0 #x1F3F3 #x1F3F5 #x1F3F7 #x1F4FD
    #x1F4FF #x1F53D #x1F549 #x1F54E #x1F550 #x1F567 #x1F56F #x1F570 #x1F573 #x1F57A #x1F587 #x1F587 #x1F58A #x1F58D #x1F590 #x1F590
    #x1F595 #x1F596 #x1F5A4 #x1F5A5 #x1F5A8 #x1F5A8 #x1F5B1 #x1F5B2 #x1F5BC #x1F5BC #x1F5C2 #x1F5C4 #x1F5D1 #x1F5D3 #x1F5DC #x1F5DE
    #x1F5E1 #x1F5E1 #x1F5E3 #x1F5E3 #x1F5E8 #x1F5E8 #x1F5EF #x1F5EF #x1F5F3 #x1F5F3 #x1F5FA #x1F64F #x1F680 #x1F6C5 #x1F6CB #x1F6D2
    #x1F6D5 #x1F6D8 #x1F6DC #x1F6E5 #x1F6E9 #x1F6E9 #x1F6EB #x1F6EC #x1F6F0 #x1F6F0 #x1F6F3 #x1F6FC #x1F7E0 #x1F7EB #x1F7F0 #x1F7F0
    #x1F90C #x1F93A #x1F93C #x1F945 #x1F947 #x1F9FF #x1FA70 #x1FA7C #x1FA80 #x1FA8A #x1FA8E #x1FAC6 #x1FAC8 #x1FAC8 #x1FACD #x1FADC
    #x1FADF #x1FAEA #x1FAEF #x1FAF8))

;; What stands in the cell after an emoji's: the last code of the first
;; 65536, which Unicode keeps free of characters for good.
(defconstant +taken+ (code-char #xFFFF))

;; Is CHARACTER an emoji?
(defun emoji-p (character)
  (let ((code (char-code character)) (low 0) (high (- (floor (length *emoji*) 2) 1)))
    ;; The first run that ends at the code or after it.
    (loop
      (when (>= low high)
        (return))
      (let ((middle (floor (+ low high) 2)))
        (if (< (svref *emoji* (+ middle middle 1)) code)
            (setq low (+ middle 1))
            (setq high middle))))
    (and (<= (svref *emoji* (+ low low)) code) (<= code (svref *emoji* (+ low low 1))))))

;; Does CHARACTER show nothing by itself? The sixteen that say which of its
;; forms the character before them is to be shown in, the one that joins
;; two into one picture, the frame of a key around a digit, and the letters
;; that the region of a flag is spelt in.
(defun silent-p (character)
  (let ((code (char-code character)))
    (or (<= #xFE00 code #xFE0F) (= code #x200D) (= code #x20E3) (<= #xE0020 code #xE007F))))

;; Is STRING one that is drawn as it always was: no emoji in it, and none of
;; the characters that go with one? Every one of those has a code from 8192
;; on, and so has +TAKEN+.
(defun plain-p (string)
  (dotimes (i (length string) t)
    (when (>= (char-code (char string i)) #x2000)
      (return nil))))

;; STRING as it stands in cells: +TAKEN+ after every emoji, and none of the
;; characters that show nothing by themselves. The string itself when it
;; has neither. A +TAKEN+ that it had is left out too, so a string that
;; stands in cells already comes back as it is.
(defun in-cells (string)
  (if (plain-p string)
      string
      (with-output-to-string (out)
        (dotimes (i (length string))
          (let ((character (char string i)))
            (unless (or (char= character +taken+) (silent-p character))
              (write-char character out)
              (when (emoji-p character)
                (write-char +taken+ out))))))))

;; The text of a string that stands in cells: STRING without its +TAKEN+s,
;; or itself when it has none.
(defun from-cells (string)
  (if (plain-p string)
      string
      (with-output-to-string (out)
        (dotimes (i (length string))
          (let ((character (char string i)))
            (unless (char= character +taken+)
              (write-char character out)))))))

;; How many pixels wide STRING is when it is drawn: in the console's font,
;; in which it is CLARA.FONT:+HEIGHT+ high and an emoji as wide as two of
;; its letters, or in FONT, one of CLARA.TYPE:FONT's.
(defun text-width (string &optional font)
  (cond (font
         (funcall (nth 0 (fonts)) string font))
        ((or (null (nth 5 *fonts*)) (plain-p string))
         (* clara.font:+width+ (length string)))
        (t
         (funcall (nth 5 *fonts*) string))))

;; STRING, its first character's upper left corner at X and Y, all on one
;; line: in the console's font, or in FONT. An emoji is its picture, in the
;; picture's own colours, and so are characters that the font of the
;; pictures draws as one. Any other character that the font has no glyph
;; for shows as the glyph that the font has for those, a box. The glyphs
;; are drawn in COLOR, and what is around them in BACKGROUND, or not at all
;; without one.
(defun draw-text (surface x y string color &optional background font)
  (cond (font
         (funcall (nth 1 (fonts)) surface x y string color background font))
        ((or (null (nth 6 *fonts*)) (plain-p string))
         (draw-letters surface x y string color background))
        (t
         (funcall (nth 6 *fonts*) surface x y string color background))))

;; Text in cells: a character to the cell, and every cell of one size, so
;; that a row of text is so many cells, whatever its characters are. That
;; is what a terminal, an editor and a list are made of. A cell of the
;; console's font is CLARA.FONT:+WIDTH+ by +HEIGHT+ pixels, each character's
;; picture; a cell of FONT, one of CLARA.TYPE:FONT's, is as wide as the
;; widest of its characters from the space to the tilde moves on, and as
;; high as a line of it.
(defun cell-width (&optional font)
  (if font
      (funcall (nth 2 (fonts)) font)
      clara.font:+width+))

(defun cell-height (&optional font)
  (if font
      (funcall (nth 3 (fonts)) font)
      clara.font:+height+))

;; STRING, a character to the cell, the first cell's upper left corner at X
;; and Y, in the console's font or in FONT. A character stands in the middle
;; of its cell, and what of it lies outside the cell is not drawn. An emoji
;; that has +TAKEN+ after it is its picture, in the middle of the two cells;
;; one that has not is a character that the font has no glyph for, like any
;; other. The glyphs are drawn in COLOR, and the cells are filled with
;; BACKGROUND first, or left as they are without one.
(defun draw-cells (surface x y string color &optional background font)
  (cond (font
         (funcall (nth 4 (fonts)) surface x y string color background font))
        ((or (null (nth 7 *fonts*)) (plain-p string))
         (draw-letters surface x y string color background))
        (t
         (funcall (nth 7 *fonts*) surface x y string color background))))

;; STRING in the console's letters, a character to the cell: its letter, or
;; the box that stands for a character without one, and nothing for +TAKEN+.
(defun draw-letters (surface x y string color background)
  (multiple-value-bind (left top right bottom)
      (inside surface x y (* clara.font:+width+ (length string)) clara.font:+height+)
    (when left
      (let ((row (+ (surface-address surface) (* top (surface-pitch surface))))
            (pitch (surface-pitch surface))
            (i (floor (- left x) clara.font:+width+)) ; the first character of which something shows
            (cell 0))
        (loop
          (setq cell (+ x (* i clara.font:+width+)))
          (when (>= cell right)
            (return))
          (let ((code (char-code (char string i)))
                (from (max cell left))
                (to (min (+ cell clara.font:+width+) right)))
            (clara.unsafe:expand-bits-32
             (+ row (* 4 from)) pitch clara.font:*glyphs*
             (+ (- top y)
                (* clara.font:+height+
                   (- (cond ((<= clara.font:+first+ code clara.font:+last+) code)
                            ((= code #xFFFF) 32)
                            (t (1+ clara.font:+last+)))
                      clara.font:+first+)))
             (- bottom top) (- to from) color background (- (+ cell clara.font:+width+) to)))
          (setq i (1+ i))))
      (drawn surface left top right bottom))))

;;; The screen
;;;
;;; The other half of drawing out of sight. What was drawn on SURFACE since
;;; it was last shown is copied to the screen, the surface's upper left
;;; corner at X and Y there, and the surface has no damage after. NIL when
;;; nothing was copied: there was no damage, no screen, or none of it lay
;;; on the screen.
(defun show (surface &optional (x 0) (y 0))
  (live surface)
  (let ((shown nil))
    (when *screen*
      (dolist (rectangle (surface-damage surface))
        (let ((left (svref rectangle 0)) (top (svref rectangle 1)))
          (when (copy-rectangle surface left top (- (svref rectangle 2) left) (- (svref rectangle 3) top)
                                *screen* (+ x left) (+ y top))
            (setq shown t)))))
    (setf (surface-damage surface) nil)
    shown))

;; Find the screen, and say whether there is one. What this file knew of a
;; machine is forgotten first: in a world that was saved and has started
;; again, that was another machine, and the surfaces that were made on it
;; are not to be drawn on.
(defun start ()
  (setq *machine* (list 'machine)
        *screen* nil
        *red* (place #xff0000)
        *green* (place #x00ff00)
        *blue* (place #x0000ff))
  (multiple-value-bind (address width height pitch red green blue) (clara.unsafe:framebuffer)
    (cond (address
           (setq *red* (place red)
                 *green* (place green)
                 *blue* (place blue)
                 *screen* (make-surface :address address :width width :height height :pitch pitch
                                        :left 0 :top 0 :right width :bottom height :machine *machine*))
           (format t "draw: a screen of ~D by ~D pixels~%" width height))
          (t
           (format t "draw: no screen, and surfaces to draw on all the same~%"))))
  (and *screen* t))
