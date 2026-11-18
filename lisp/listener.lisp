;;;; listener.lisp: read, evaluate, print
;;;;
;;;; The listener reads what is typed on the console, a line at a time,
;;;; evaluates every form as soon as it is whole, and prints what the form
;;;; gives: its values, one to a line, or the condition that nothing
;;;; handled, as it reads for a person. A mistake at the prompt costs a
;;;; line of text and nothing more.
;;;;
;;;; It reads from *STANDARD-INPUT* and writes to *STANDARD-OUTPUT*, which
;;;; on ClaraOS are the console (lisp/console.lisp): what is typed on the
;;;; serial port, or on a keyboard. A listener in a window binds the two to
;;;; the window's stream, and is this one all the same (lisp/terminal.lisp).
;;;; Under SBCL the tests in lisp/host/ run it on strings.

(defpackage "CLARA.LISTENER"
  (:use "COMMON-LISP")
  (:export "RUN" "ANSWER" "READ-AND-ANSWER" "ANSWER-LINES"))
(in-package "CLARA.LISTENER")

;; What READ-FROM-STRING gives when no form is left: a cons, which is EQ to
;; nothing that a text can be read as.
(defvar *nothing* (list 'nothing))

;; A form: evaluated, and its values printed, each on a line of its own.
;; An error is said and goes no further; so does a heap that is full, and
;; Ctrl-C, which are no errors and stop a computation all the same.
(defun answer (form)
  (handler-case
      (dolist (value (multiple-value-list (eval form)))
        (fresh-line)
        (prin1 value))
    (serious-condition (condition)
      (fresh-line)
      (format t "error: ~A" condition)))
  (fresh-line))

;; The forms of a text, each answered as soon as it has been read. What is
;; returned is the text that is still to be read: the beginning of a form
;; that the next line may finish, or nothing. A text that cannot be read
;; is dropped, with the reason.
(defun read-and-answer (text)
  (let ((start 0))
    (loop
      (multiple-value-bind (form position)
          (handler-case (read-from-string text nil *nothing* :start start)
            (end-of-file ()
              (return (subseq text start)))
            (reader-error (condition)
              (fresh-line)
              (format t "error: ~A~%" condition)
              (return "")))
        (when (eq form *nothing*)
          (return ""))
        (answer form)
        (setq start position)))))

;; Read and answer until the input ends. Ctrl-C at the prompt gives up the
;; line and the form that it was to go on.
(defun answer-lines ()
  (let ((text ""))
    (loop
      (write-string (if (zerop (length text)) "> " "  "))
      (let ((line (handler-case (read-line *standard-input* nil)
                    (clara:keyboard-interrupt () :given-up))))
        (cond ((null line)
               (terpri)
               (when (plusp (length text))
                 (write-line "the input ended in the middle of a form"))
               (return))
              ((eq line :given-up)
               (setq text ""))
              (t
               (setq text (read-and-answer (concatenate 'string text line (string #\Newline))))))))))

;; The listener of the console. CONDITION is for the substrate, which
;; starts it again when a condition has come all the way out of it, and
;; says which.
(defun run (&optional condition)
  (if condition
      (progn
        (fresh-line)
        (format t "error: ~A~%" condition))
      (write-line "clara: reading the serial port and the keyboard: a form is evaluated, Ctrl-C stops it, Ctrl-D ends"))
  (answer-lines))
