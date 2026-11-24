;;;; disc.lisp: a disc, drawn
;;;;
;;;; The file of the package "sun" that is loaded when the package is
;;;; installed, and into every world after that: what it defines is there
;;;; for anybody, (sun:disc surface x y radius color). The package of the
;;;; language that it makes, SUN, is the package's: it goes when the package
;;;; is taken out.

(defpackage "SUN"
  (:use "COMMON-LISP")
  (:export "DISC"))
(in-package "SUN")

;; Half the width of a disc of that radius, DY rows from its middle: the
;; most pixels that are no further from the centre than the radius.
(defun reach (radius dy)
  (let ((half 0))
    (loop
      (when (> (+ (* (1+ half) (1+ half)) (* dy dy)) (* radius radius))
        (return half))
      (setq half (1+ half)))))

;; A disc of that colour on a surface, with its centre at X and Y: a row of
;; pixels for each row that it covers (CLARA.DRAW:FILL-RECTANGLE, which
;; leaves out what lies outside the surface).
(defun disc (surface x y radius color)
  (dotimes (i (1+ (* 2 radius)))
    (let* ((dy (- i radius)) (half (reach radius dy)))
      (clara.draw:fill-rectangle surface (- x half) (+ y dy) (1+ (* 2 half)) 1 color)))
  t)
