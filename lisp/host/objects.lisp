;;;; host/objects.lisp: what lisp/clos.lisp asks of the substrate, under SBCL
;;;;
;;;; lisp/clos.lisp is the object system of ClaraOS, and SBCL has one of its
;;;; own under the same names. The tests read that file into the package
;;;; CLARA.CLOS with those names hidden behind symbols of that package
;;;; (lisp/host/tests.lisp), so the two live side by side and can be held
;;;; against each other. What the file asks of the kernel, eight functions,
;;;; is answered here from what SBCL knows: this file is loaded after the
;;;; package is made and before the rest of lisp/clos.lisp is read.
;;;;
;;;; A name with CL: before it is SBCL's own; one without is the file's.

(in-package "CLARA.CLOS")

;; What an object is, as the name of a class. The structures of
;; lisp/clos.lisp itself come out under their own names, as they do from
;; the kernel.
(defun kind-of (object)
  (cl:typecase object
    (cl:integer 'integer)
    (cl:character 'character)
    (cl:null 'null)
    (cl:symbol 'symbol)
    (cl:cons 'cons)
    (cl:string 'string)
    (cl:vector 'vector)
    (cl:function 'function)
    (cl:package 'package)
    (cl:stream 'stream)
    ((or cl:structure-object cl:condition) (cl:type-of object))
    (t 't)))

(defun structure-slots (name)
  (let ((class (and (symbolp name) (cl:find-class name nil))))
    (and class (cl:typep class 'cl:structure-class) (list name))))

(defun condition-parents (name)
  (let ((class (and (symbolp name) (cl:find-class name nil))))
    (if (and class (cl:subtypep class 'cl:condition))
        (remove-if-not (lambda (parent) (cl:subtypep parent 'cl:condition))
                       (mapcar #'cl:class-name (sb-mop:class-direct-superclasses class)))
        :none)))

(defun function-named (name)
  (and (fboundp name) (fdefinition name)))

(defun install-function (name function)
  (setf (fdefinition name) function))

;; SBCL's printer asks SBCL's PRINT-OBJECT, which for the structures of a
;; type that is named here asks the one of lisp/clos.lisp. The kernel's
;; printer does the same thing by a mark on the name (kernel/lisp/print.c).
(defun printed-by-method (name)
  (eval `(cl:defmethod cl:print-object ((object ,name) stream)
           (print-object object stream))))

(defun plain-text (object)
  (if (cl:typep object 'cl:structure-object)
      (with-output-to-string (stream)
        (sb-kernel:default-structure-print object stream 0))
      (prin1-to-string object)))

;; Where an object lies. On the machine that is a number which the object
;; keeps, since nothing in its heap moves. SBCL's collector moves what it
;; keeps, so SBCL's own address of an object is not that: here an object
;; is given a number the first time that it is asked for, one that looks
;; like an address of the machine's heap, a multiple of eight above where
;; that heap begins, and it has the same one whenever it is asked for
;; again. NIL lies where the heap begins, and an integer or a character
;; lies nowhere, as on the machine.
(defvar *addresses* (make-hash-table :test 'eq :weakness :key))
(defvar *last-address* #x400000000000)

(defun address-of (object)
  (cond ((cl:typep object '(or cl:integer cl:character)) nil)
        ((null object) #x400000000000)
        ((gethash object *addresses*))
        (t (setf (gethash object *addresses*) (incf *last-address* 24)))))
