;;;; sun.lisp: the sun of ClaraOS over its horizon, in a window
;;;;
;;;; The file of the package "sun" that defines its application: the
;;;; launcher loads it when Sun is first picked from the list under
;;;; Applications, and its last form says which function the application
;;;; is. It is read in the package that disc.lisp made when the package was
;;;; installed.

(in-package "SUN")

;; The window: the sun, half risen, the horizon, and under it the name of
;; the system, in letters of outlines. It stays until a key is typed in it
;; or its x is clicked.
(defun rise ()
  (let* ((window (clara.windows:open-window "Sun" 240 150 :events t))
         (inside (clara.windows:window-surface window))
         (sun (clara.draw:color 255 184 108))
         (ink (clara.draw:color 232 227 244))
         (paper (clara.draw:color 30 27 46))
         (name (concatenate 'string (lisp-implementation-type) " " (lisp-implementation-version)))
         (font (clara.type:font "Sans" 14)))
    (disc inside 120 100 44 sun)
    (clara.draw:fill-rectangle inside 0 100 240 50 paper)
    (clara.draw:fill-rectangle inside 20 100 200 1 ink)
    (clara.draw:draw-text inside (floor (- 240 (clara.draw:text-width name font)) 2) 116 name ink nil font)
    (clara.windows:show window)
    (loop
      (let ((event (clara.windows:next-event window)))
        (when (or (eq (car event) :key) (eq (car event) :close))
          (return))))
    (clara.windows:close-window window)
    nil))

(clara.windows:define-application "Sun" #'rise)
