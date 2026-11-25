;;;; jaid.lisp: Jaid, a file browser
;;;;
;;;; An application (lisp/windows.lisp): a window that lists what a
;;;; directory holds, the directories first, with one of the names picked.
;;;; The arrows, Home, End, Page Up and Page Down pick another, and so does
;;;; a click. Enter goes into the directory that is picked, or opens the
;;;; file that is in the editor, Emma, which is another application and is
;;;; launched for it; a click on the name that is picked does the same.
;;;; Backspace goes to the directory that this one is in, Delete deletes the
;;;; file that is picked, when asked twice, Ctrl-R reads the directory again
;;;; and Ctrl-Q closes the window, as its close box does. Ctrl-C copies the
;;;; name that is picked, with its directory, for Ctrl-V in another window
;;;; (CLARA.WINDOWS:CLIPBOARD).
;;;;
;;;; What a directory holds is asked of the language, DIRECTORY, and that of
;;;; whatever file system said that it is there (lisp/boot.lisp): this file
;;;; knows nothing of disks.
;;;;
;;;; This file is not part of the world that the kernel loads. The launcher
;;;; loads it when Jaid is first picked, and CLARA.WINDOWS:UNLOAD-APPLICATION
;;;; takes it out again. It loads under SBCL as well, where lisp/host/
;;;; stands in for the machine.

(defpackage "CLARA.JAID"
  (:use "COMMON-LISP")
  (:export "BROWSE"))
(in-package "CLARA.JAID")

(defstruct browser
  window
  surface         ; what its window is drawn on
  columns         ; the size of the list's part of the window, in cells:
  rows            ;   the window has one row more, below it, for the status
  ink             ; the pixel of a glyph,
  paper           ; and the pixel around it; the name that is picked has the two the other way round, and so has the status
  (directory "/") ; the name of the directory that is listed, with a slash at its end
  names           ; what it holds, as each is shown: a directory's name with a slash at its end, and "../" first for the way up
  (picked 0)      ; the number of the name that is picked
  (top 0)         ; the number of the name in the window's first row
  shown           ; what each row of the window shows, as it was drawn: (text . picked), or NIL for a row to draw again
  message         ; words for the status row, until the next key
  doomed          ; the name of the file that Delete was typed on, while the question is open
  done)           ; the window is to close

;;; Strings of the width of a row

(defvar *blank* "        ")

;; STRING, cut or made longer with spaces: WIDTH characters exactly.
(defun fit (string width)
  (loop
    (when (>= (length *blank*) width)
      (return))
    (setq *blank* (concatenate 'string *blank* *blank*)))
  (if (>= (length string) width)
      (subseq string 0 width)
      (concatenate 'string string (subseq *blank* 0 (- width (length string))))))

;;; Directories

;; What the directory of a name holds, each with the directory's name
;; before its own, and a directory's with a slash at its end. This is the
;; one place that asks, and it asks the language.
(defun names-in (place)
  (directory (concatenate 'string place "*")))

;; Under SBCL, DIRECTORY gives pathnames of the host's and not names: the
;; tests there put another function here.
(defvar *names* #'names-in)

(defun directory-name-p (name)
  (and (plusp (length name)) (char= (char name (1- (length name))) #\/)))

;; The directory that the one of a name is in: "/" for "/clara/", and for
;; "/" itself.
(defun parent (place)
  (let ((end (1- (length place))))
    (loop
      (when (or (<= end 0) (char= (char place (1- end)) #\/))
        (return))
      (setq end (1- end)))
    (subseq place 0 (max end 1))))

;; What the window of a directory is called: Jaid, and after that the name
;; of the directory that it lists.
(defun title (place)
  (concatenate 'string "Jaid - " place))

;; The directory of a name is the one that is listed from now on: its
;; directories in the order of their names, then its files, and before
;; them the way up, where there is one. PICK is the name to have picked, if
;; it is there.
(defun list-directory (browser place &optional pick)
  (let* ((names (mapcar (lambda (name) (subseq name (length place))) (funcall *names* place)))
         (directories (sort (copy-list (remove-if-not #'directory-name-p names)) #'string-lessp))
         (files (sort (copy-list (remove-if #'directory-name-p names)) #'string-lessp))
         (all (append (if (string= place "/") nil (list "../")) directories files)))
    (setf (browser-directory browser) place
          (browser-names browser) all
          (browser-picked browser) (or (and pick (position pick all :test #'string-equal)) 0)
          (browser-top browser) 0)
    (clara.windows:rename-window (browser-window browser) (title place))
    nil))

;; To the directory that this one is in, with this one picked there.
(defun go-up (browser)
  (let* ((place (browser-directory browser)) (above (parent place)))
    (unless (string= place above)
      (list-directory browser above (subseq place (length above))))))

;; The name that is picked: a directory is gone into, and a file is opened
;; in the editor, which is launched for it.
(defun open-picked (browser)
  (let ((name (nth (browser-picked browser) (browser-names browser))))
    (cond ((null name) nil)
          ((string= name "../") (go-up browser))
          ((directory-name-p name)
           (list-directory browser (concatenate 'string (browser-directory browser) name)))
          (t
           (clara.windows:launch "Emma" (concatenate 'string (browser-directory browser) name))
           nil))))

;;; The window

;; What the status row says: a question; or words about what was done
;; last; or how many names there are, and which keys to use on them when
;; the row has room for that.
(defun status (browser)
  (cond ((browser-doomed browser)
         (concatenate 'string "delete " (browser-doomed browser) "? y deletes it"))
        ((browser-message browser))
        ((null (browser-names browser)) "nothing here")
        (t (let ((count (format nil "~D names" (length (browser-names browser))))
                 (keys ": Enter opens, Backspace goes up"))
             (if (< (+ (length count) (length keys)) (browser-columns browser))
                 (concatenate 'string count keys)
                 count)))))

;; The window shows the list again, around the name that is picked, and the
;; status: each row that is not what was drawn there is drawn, and then
;; shown.
(defun render (browser)
  (let ((rows (browser-rows browser)) (columns (browser-columns browser)) (surface (browser-surface browser))
        (shown (browser-shown browser)) (ink (browser-ink browser)) (paper (browser-paper browser))
        (picked (browser-picked browser)))
    (cond ((< picked (browser-top browser)) (setf (browser-top browser) picked))
          ((>= picked (+ (browser-top browser) rows)) (setf (browser-top browser) (- picked rows -1))))
    (let ((names (nthcdr (browser-top browser) (browser-names browser))))
      (dotimes (r rows)
        (let ((row (cons (fit (if names (concatenate 'string " " (car names)) "") columns)
                         (and names (= (+ (browser-top browser) r) picked)))))
          (unless (equal (svref shown r) row)
            (if (cdr row)
                (clara.draw:draw-text surface 0 (* r clara.font:+height+) (car row) paper ink)
                (clara.draw:draw-text surface 0 (* r clara.font:+height+) (car row) ink paper))
            (setf (svref shown r) row))
          (setq names (cdr names)))))
    (let ((text (fit (concatenate 'string " " (status browser)) columns)))
      (unless (equal (svref shown rows) text)
        (clara.draw:draw-text surface 0 (* rows clara.font:+height+) text paper ink)
        (setf (svref shown rows) text)))
    (clara.windows:show (browser-window browser))))

;;; Keys

;; What FUNCTION gives is said in the status row when it is words, and so
;; is what goes wrong in it: a disk that does not answer, a file that
;; cannot be deleted.
(defun attempt (browser function)
  (setf (browser-message browser)
        (handler-case (funcall function)
          (error (condition)
            (format nil "~A" condition)))))

;; The name that is picked is the one of that number, or the nearest there is.
(defun pick (browser number)
  (setf (browser-picked browser) (max 0 (min number (1- (length (browser-names browser)))))))

;; The character with this code was typed in the window, or the key with it.
(defun key (browser code)
  (let ((doomed (browser-doomed browser)) (picked (browser-picked browser)))
    (setf (browser-message browser) nil
          (browser-doomed browser) nil)
    (cond (doomed
           (when (or (= code 121) (= code 89)) ; y, or Y
             (attempt browser (lambda ()
                                (delete-file doomed)
                                (list-directory browser (browser-directory browser))
                                (pick browser picked)
                                (concatenate 'string "deleted " doomed)))))
          ((= code clara.input:+up+) (pick browser (1- picked)))
          ((= code clara.input:+down+) (pick browser (1+ picked)))
          ((= code clara.input:+page-up+) (pick browser (- picked (1- (browser-rows browser)))))
          ((= code clara.input:+page-down+) (pick browser (+ picked (1- (browser-rows browser)))))
          ((= code clara.input:+home+) (pick browser 0))
          ((= code clara.input:+end+) (pick browser (length (browser-names browser))))
          ((or (= code 10) (= code 13)) (attempt browser (lambda () (open-picked browser))))
          ((or (= code 8) (= code clara.input:+left+)) (attempt browser (lambda () (go-up browser))))
          ((= code 127)                 ; Delete
           (let ((name (nth picked (browser-names browser))))
             (cond ((null name))
                   ((directory-name-p name)
                    (setf (browser-message browser) "a directory is not deleted from here"))
                   (t
                    (setf (browser-doomed browser) (concatenate 'string (browser-directory browser) name))))))
          ((= code 18)                  ; Ctrl-R
           (attempt browser (lambda ()
                              (list-directory browser (browser-directory browser)
                                              (nth picked (browser-names browser))))))
          ((= code 3)                   ; Ctrl-C: the name that is picked is what was copied last, for every window
           (let ((name (nth picked (browser-names browser))))
             (when (and name (not (string= name "../")))
               (let ((whole (concatenate 'string (browser-directory browser) name)))
                 (setf (clara.windows:clipboard) whole
                       (browser-message browser) (concatenate 'string "copied " whole))))))
          ((= code 17)                  ; Ctrl-Q
           (setf (browser-done browser) t)))))

;; A button of the pointer went down or up in the window: the left one,
;; down on a name, picks it, and on the name that is picked opens it.
(defun point (browser y buttons)
  (let ((number (+ (browser-top browser) (floor y clara.font:+height+))))
    (when (and (= 1 (logand buttons 1)) (< (floor y clara.font:+height+) (browser-rows browser))
               (< number (length (browser-names browser))))
      (setf (browser-message browser) nil
            (browser-doomed browser) nil)
      (if (= number (browser-picked browser))
          (attempt browser (lambda () (open-picked browser)))
          (pick browser number)))))

(defun happened (browser event)
  (case (car event)
    (:key (key browser (cadr event)))
    (:pointer (point browser (caddr event) (cadddr event)))
    (:close (setf (browser-done browser) t))))

;;; The application

;; A browser in a window of its own, which lists the directory of a name.
;; COLUMNS and ROWS are the size of the list, in cells; X and Y are where
;; the window goes. The window is the thread's that calls.
(defun open-browser (place &key (columns 48) (rows 16) x y)
  (let* ((place (if (directory-name-p place) place (concatenate 'string place "/")))
         (window (clara.windows:open-window (title place) (* columns clara.font:+width+)
                                            (* (1+ rows) clara.font:+height+) :x x :y y :events t))
         (browser (make-browser :window window :surface (clara.windows:window-surface window)
                                :columns columns :rows rows :directory place
                                :ink (clara.draw:color 232 227 244) :paper (clara.draw:color 30 27 46)
                                :shown (make-array (1+ rows) :initial-element nil))))
    (attempt browser (lambda () (list-directory browser place)))
    browser))

;; What happens to the window is done to the list, and the window shows
;; what came of it, until the window is to close.
(defun run (browser)
  (loop
    (render browser)
    (when (browser-done browser)
      (return))
    (happened browser (clara.windows:next-event (browser-window browser)))
    ;; And whatever else has happened by now, before anything is drawn.
    (loop
      (let ((event (clara.windows:next-event (browser-window browser) 0)))
        (unless event
          (return))
        (happened browser event)))))

;; The application: the directory of a name is listed, the first of all
;; unless another is asked for, until the window closes. Whoever calls is
;; the browser for as long: the launcher starts a thread for that.
(defun browse (&optional (place "/") &rest options)
  (let ((browser (apply #'open-browser place options)))
    (unwind-protect (run browser)
      (clara.windows:close-window (browser-window browser)))
    nil))

(clara.windows:define-application "Jaid" #'browse)
