;;;; self-test.lisp: a file with a mistake in it, for the evaluator's
;;;; self-test to load
;;;;
;;;; kernel/lisp/lisp.c loads this at every boot to see what LOAD does when
;;;; a form in the middle of a file fails: the error has to say which file
;;;; and which line, what came before the form has to stay, what comes
;;;; after it must not happen, and *PACKAGE* has to be what it was before
;;;; the file changed it. The build puts the file on the boot volume beside
;;;; lisp/boot.lisp. It is not in lisp/ because no Lisp should load it for
;;;; any other reason, SBCL least of all.

(defpackage "CLARA.LOADED" (:use "COMMON-LISP"))
(in-package "CLARA.LOADED")
(defvar *reached* 'the-form-before)
(car 'not-a-list)
(setq *reached* 'the-form-after)
