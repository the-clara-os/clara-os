;;;; syntax.lisp: which parentheses of a text count, and which belong together
;;;;
;;;; Whoever shows Lisp as it is typed, a terminal at its prompt
;;;; (lisp/terminal.lisp) or the editor (lisp/emma.lisp), shows which
;;;; parentheses belong together: each pair in a colour of its own, by how
;;;; many pairs it lies within, and a mark on the one that opens what the
;;;; last one typed closes. This file says which those are, and in which
;;;; colours.
;;;;
;;;; A text is gone through a character at a time, the way the reader goes
;;;; through it (kernel/lisp/read.c), and nothing is made of it. A
;;;; parenthesis counts unless it is in a string, in a comment, between two
;;;; bars or after a backslash, and unless it is the character of #\( or
;;;; #\). What the going-through knows at one place of a text, it can go on
;;;; from at another time: a text is gone through a line at a time, or a
;;;; piece at a time, and only as far back as it has changed.
;;;;
;;;; This file loads under SBCL as well, where the tests hold what it says
;;;; against what SBCL's reader makes of the same texts.

(defpackage "CLARA.SYNTAX"
  (:use "COMMON-LISP")
  (:export "SCAN" "NEXT-LINE" "COLOR" "HINT" "*COLORS*" "*STRAY*" "*HINT*"))
(in-package "CLARA.SYNTAX")

;;; Colours
;;;
;;; Each is its red, green and blue, from 0 to 255, as CLARA.DRAW:COLOR
;;; takes them: a pixel is the screen's to say, and is made when something
;;; is drawn.

;; The colours of the parentheses that belong together, the outermost
;; pair's first. A pair that lies deeper than there are colours takes them
;; from the first again, and with NIL no parenthesis is coloured.
(defvar *colors* '((255 121 198) (139 233 253) (241 250 140) (189 147 249) (255 184 108) (80 250 123)))

;; The colour of a closing parenthesis that nothing opens, or NIL for none.
(defvar *stray* '(255 85 85))

;; The colour of the block that the hint is: what lies under the opening
;; parenthesis while the one that closes it is the last that was typed. NIL
;; for no hint.
(defvar *hint* '(98 90 134))

;; The pixel of such a colour, or NIL when it is not one.
(defun pixel (parts)
  (and (consp parts) (consp (cdr parts)) (consp (cddr parts)) (null (cdddr parts))
       (let ((red (car parts)) (green (cadr parts)) (blue (caddr parts)))
         (and (integerp red) (integerp green) (integerp blue)
              (<= 0 red 255) (<= 0 green 255) (<= 0 blue 255)
              (clara.draw:color red green blue)))))

;; The pixel that a parenthesis is drawn in: LEVEL is how many pairs it
;; lies within, or NIL for a closing one that nothing opens. NIL when it is
;; drawn like any other character.
(defun color (level)
  (cond ((null level) (pixel *stray*))
        ((and (integerp level) (>= level 0) (consp *colors*))
         (let ((count 0))
           (do ((colors *colors* (cdr colors)))
               ((not (consp colors)))
             (setq count (1+ count)))
           (pixel (nth (mod level count) *colors*))))))

;; The pixel of the hint's block, or NIL when there is to be no hint.
(defun hint ()
  (pixel *hint*))

;;; Going through a text
;;;
;;; What is known at a place of a text is a state: what the place is in, a
;;; string, a comment, a name; what the character before it has begun and
;;; the next one decides; and the opening parentheses that nothing has
;;; closed yet, the innermost first. NIL is the state at the start of a
;;; text. A state is never changed: going on from one makes another, so a
;;; state can be kept for as long as the text before it stays as it is.

(defstruct state
  mode     ; NIL between two things, :TOKEN in a name or a number, :BARS between two bars, :STRING,
           ;   :COMMENT after a semicolon, or how many #| |# comments lie around the place
  pending  ; what the character before has begun: :ESCAPE after a backslash, :SHARP after a #, :CHAR after #\,
           ;   and in a #| |# comment :BAR after a | and :SHARP after a #
  opens)   ; where the opening parentheses are that are not closed yet, the innermost first: (tag . index)

;; The characters of TEXT, gone through from STATE on. FUNCTION, when there
;; is one, is called for every parenthesis that counts, with three
;; arguments: the index of the parenthesis in TEXT; its level, which is how
;; many pairs it lies within, from 0, or NIL for a closing one that nothing
;; opens; and for a closing one where the one is that opens it. That place
;; is (tag . index), with the TAG and the index of the call that went
;; through the opening one: a line of a text, or whatever else tells one
;; piece from another. The state after the last character comes back.
(defun scan (text state tag function)
  (let* ((mode (and state (state-mode state)))
         (pending (and state (state-pending state)))
         (opens (and state (state-opens state)))
         (level (length opens)))
    (dotimes (i (length text))
      (let ((c (char text i)))
        (cond ((eq pending :escape)     ; the character after a backslash is taken as it is,
               (setq pending nil)
               (unless (or (eq mode :string) (eq mode :bars))
                 (setq mode :token)))
              ((eq pending :char)       ; and so is the one after #\, which a name may follow
               (setq pending nil
                     mode :token))
              ((integerp mode)          ; in a #| |# comment, which can hold others
               (cond ((and (eq pending :bar) (char= c #\#))
                      (setq pending nil
                            mode (if (= mode 1) nil (1- mode))))
                     ((and (eq pending :sharp) (char= c #\|))
                      (setq pending nil
                            mode (1+ mode)))
                     ((char= c #\|) (setq pending :bar))
                     ((char= c #\#) (setq pending :sharp))
                     (t (setq pending nil))))
              ((eq mode :string)
               (cond ((char= c #\") (setq mode nil))
                     ((char= c #\\) (setq pending :escape))))
              ((eq mode :bars)
               (cond ((char= c #\|) (setq mode :token))
                     ((char= c #\\) (setq pending :escape))))
              ((eq mode :comment)
               (when (char= c #\Newline)
                 (setq mode nil)))
              ((and (eq pending :sharp) (not (char= c #\()))
               ;; What a # means is for the character after it to say, which
               ;; is no more than that then, with a number between the two
               ;; at most: #\ and #| are the two that matter here, and the
               ;; parenthesis of #( is one like any other.
               (cond ((char= c #\\) (setq pending :char))
                     ((char= c #\|)
                      (setq pending nil
                            mode 1))
                     ((<= 48 (char-code c) 57))
                     (t (setq pending nil))))
              (t
               (setq pending nil)
               (cond ((char= c #\()
                      (when function
                        (funcall function i level nil))
                      (setq opens (cons (cons tag i) opens)
                            level (1+ level)
                            mode nil))
                     ((char= c #\))
                      (cond (opens
                             (setq level (1- level))
                             (when function
                               (funcall function i level (car opens)))
                             (setq opens (cdr opens)))
                            (function
                             (funcall function i nil nil)))
                      (setq mode nil))
                     ((char= c #\") (setq mode :string))
                     ((char= c #\;) (setq mode :comment))
                     ((char= c #\|) (setq mode :bars))
                     ((char= c #\\) (setq pending :escape))
                     ((char= c #\#)     ; which means something only where a thing begins
                      (unless mode
                        (setq pending :sharp)))
                     ((or (char= c #\Space) (char= c #\Newline) (char= c #\') (char= c #\`) (char= c #\,)
                          (char= c #\Tab) (char= c #\Return) (char= c #\Page))
                      (setq mode nil))
                     (t (setq mode :token)))))))
    (if (and state (eq mode (state-mode state)) (eq pending (state-pending state)) (eq opens (state-opens state)))
        state
        (and (or mode pending opens)
             (make-state :mode mode :pending pending :opens opens)))))

(defvar *newline* (string #\Newline))

;; The state at the start of the line after the one that STATE is at the
;; end of: for a text that is kept as its lines, which have no ends in them.
(defun next-line (state)
  (and state
       (scan *newline* state nil nil)))
