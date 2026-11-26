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
;;;; and Ctrl-Q closes the window, as its close box does.
;;;;
;;;; A machine can have several volumes, and above the first directory of
;;;; each is the list of them, which is how another volume is gone to: the
;;;; way up from such a directory when there is more than one volume, and
;;;; Enter on the one that is wanted.
;;;;
;;;; A file is copied, and moved, from one directory to another, on the
;;;; same volume or not. Ctrl-C copies the name that is picked, with its
;;;; directory, for Ctrl-V in another window (CLARA.WINDOWS:CLIPBOARD);
;;;; Ctrl-V in a window of this kind puts a copy of the file of that name
;;;; into the directory that is listed; and Ctrl-X is Ctrl-C for a file that
;;;; Ctrl-V is to move. The pointer does the same: a name that it takes
;;;; hold of and lets go on a directory, here or in another window of this
;;;; kind, is put there, a copy of it on another volume and the file itself
;;;; on its own (CLARA.WINDOWS:CARRY).
;;;;
;;;; What a directory holds is asked of the language, DIRECTORY, and that of
;;;; whatever file system said that it is there (lisp/boot.lisp): this file
;;;; knows nothing of disks. Which volumes there are, and a file like
;;;; another, are the language's too: CLARA:VOLUMES and CLARA:COPY-FILE.
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
  font            ; what the names are written in: one of CLARA.TYPE:FONT's, or NIL for the console's letters
  wide            ; the size of a cell of that, in pixels
  high
  columns         ; the size of the list's part of the window, in cells:
  rows            ;   the window has one row more, below it, for the status
  ink             ; the pixel of a glyph,
  paper           ; and the pixel around it; the name that is picked has the two the other way round, and so has the status
  (directory "/") ; the name of the directory that is listed, with a slash at its end; or "", and the volumes are
  names           ; what it holds, as each is named: a directory's name with a slash at its end, and "../" first for the way
                  ;   up; of the volumes, the names of their first directories
  volumes         ; while the volumes are listed: what the language says of them (CLARA:VOLUMES)
  (picked 0)      ; the number of the name that is picked
  (top 0)         ; the number of the name in the window's first row
  shown           ; what each row of the window shows, as it was drawn: (text . picked), or NIL for a row to draw again
  message         ; words for the status row, until the next key
  asked           ; a question that is open: (words . function), what the status row asks and what is done when y answers
  pressed         ; while the left button is down that went down on a name: (number . open), the name, and whether
                  ;   letting go of it there opens it, which it does when the name was the picked one already
  carrying        ; the name of the file that the pointer carries from this window, with its directory, or NIL
  done)           ; the window is to close

;; The name of the file that Ctrl-X was typed on last, in whichever window
;; of this kind, with its directory: Ctrl-V moves that file, while its name
;; is still what was copied last.
(defvar *cut* nil)

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

;; Does NAME begin with START, in letters of either case?
(defun begins-p (name start)
  (and (<= (length start) (length name)) (string-equal start (subseq name 0 (length start)))))

;;; Directories

;; What the directory of a name holds, each with the directory's name
;; before its own, and a directory's with a slash at its end. This is the
;; one place that asks, and it asks the language.
(defun names-in (place)
  (directory (concatenate 'string place "*")))

;; Under SBCL, DIRECTORY gives pathnames of the host's and not names: the
;; tests there put another function here.
(defvar *names* #'names-in)

;; The name of a file or of a directory as the language has it, a
;; directory's with a slash at its end, or NIL when there is none of that
;; name: PROBE-FILE, which gives a pathname under SBCL, so the tests there
;; put another function here as well.
(defvar *found* #'probe-file)

(defun directory-name-p (name)
  (and (plusp (length name)) (char= (char name (1- (length name))) #\/)))

;; The directory that the one of a name is in: "/" for "/clara/", and for
;; "/" itself; "2:/" for "2:/clara/", and for "2:/" itself, the first
;; directory of a volume that says which it is.
(defun parent (place)
  (let ((end (1- (length place))))
    (loop
      (when (or (<= end 0) (char= (char place (1- end)) #\/))
        (return))
      (setq end (1- end)))
    (cond ((> end 0) (subseq place 0 end))
          ((char= (char place 0) #\/) "/")
          (t place))))

;; What a name has after its last slash, and what it has up to there.
(defun own-name (name)
  (let ((slash (position #\/ name :from-end t)))
    (if slash (subseq name (1+ slash)) name)))

(defun directory-of (name)
  (let ((slash (position #\/ name :from-end t)))
    (if slash (subseq name 0 (1+ slash)) "")))

;;; Volumes
;;;
;;; The language says which there are: for each the name of its first
;;; directory, which a name begins with that is on it, "2:/", and what is
;;; known of it. A name that begins with none of them is on the volume that
;;; is said to be the current one.

;; Is PLACE the first directory of a volume? "/" is, of the volume that
;; names are looked up on.
(defun first-directory-p (place)
  (or (string= place "/")
      (and (member place (mapcar #'car (clara:volumes)) :test #'string-equal) t)))

;; The first directory of the volume that a name is on, or NIL when the
;; language says nothing of volumes.
(defun volume-of (name)
  (let ((found nil) (current nil))
    (dolist (volume (clara:volumes))
      (let ((first (car volume)))
        (when (and (null found) (begins-p name first))
          (setq found first))
        (when (getf (cdr volume) :current)
          (setq current first))))
    (or found current)))

;; A name with its volume said first, whether it said so itself or not, so
;; that two names of one file read alike.
(defun whole-name (name)
  (let ((first (volume-of name)) (start 0))
    (cond ((or (null first) (begins-p name first)) name)
          (t (loop
               (unless (and (< start (length name)) (char= (char name start) #\/))
                 (return))
               (setq start (1+ start)))
             (concatenate 'string first (subseq name start))))))

(defun same-volume-p (name other)
  (let ((first (volume-of name)) (second (volume-of other)))
    (or (null first) (null second) (string-equal first second))))

;; Where the way up from a directory leads: to the directory that it is in;
;; from the first directory of a volume to the list of the volumes, "",
;; when there is more than one to pick from; and otherwise nowhere, which is
;; the place itself.
(defun above (place)
  (cond ((string= place "") "")
        ((first-directory-p place) (if (cdr (clara:volumes)) "" place))
        (t (parent place))))

;; So many bytes, said shortly.
(defun size (bytes)
  (cond ((>= bytes 1048576) (format nil "~D MiB" (floor bytes 1048576)))
        ((>= bytes 1024) (format nil "~D KiB" (floor bytes 1024)))
        (t (format nil "~D bytes" bytes))))

;; What the list of the volumes says of one, after its name: how large it
;; is, whether the machine was started from it, which makes it the
;; system's, whether it is where "/" is, and whether it cannot be written.
(defun volume-words (facts)
  (let ((words (if (getf facts :bytes) (size (getf facts :bytes)) "")))
    (when (getf facts :started-from)
      (setq words (concatenate 'string words ", the system's")))
    (when (getf facts :current)
      (setq words (concatenate 'string words ", / is here")))
    (when (getf facts :read-only)
      (setq words (concatenate 'string words ", cannot be written")))
    words))

;; What the row of a name shows: the name, and of a volume what is known
;; of it as well.
(defun row-text (browser name)
  (if (string= (browser-directory browser) "")
      (concatenate 'string (if (< (length name) 5) (fit name 5) name) " "
                   (volume-words (cdr (assoc name (browser-volumes browser) :test #'string=))))
      name))

;; What the window of a directory is called: Jaid, and after that the name
;; of the directory that it lists. Above the directories, with the volumes
;; listed, it is Jaid and nothing more.
(defun title (place)
  (if (string= place "")
      "Jaid"
      (concatenate 'string "Jaid - " place)))

;; The directory of a name is the one that is listed from now on: its
;; directories in the order of their names, then its files, and before
;; them the way up, where there is one. With "" for a name it is the
;; volumes that are listed, in the order that the language has them in.
;; PICK is the name to have picked, if it is there.
(defun list-directory (browser place &optional pick)
  (let* ((volumes (if (string= place "") (clara:volumes) nil))
         (names (if (string= place "")
                    nil
                    (mapcar (lambda (name) (subseq name (length place))) (funcall *names* place))))
         (directories (sort (copy-list (remove-if-not #'directory-name-p names)) #'string-lessp))
         (files (sort (copy-list (remove-if #'directory-name-p names)) #'string-lessp))
         (all (if (string= place "")
                  (mapcar #'car volumes)
                  (append (if (string= (above place) place) nil (list "../")) directories files))))
    (setf (browser-directory browser) place
          (browser-names browser) all
          (browser-volumes browser) volumes
          (browser-picked browser) (or (and pick (position pick all :test #'string-equal)) 0)
          (browser-top browser) 0)
    (clara.windows:rename-window (browser-window browser) (title place))
    nil))

;; To the directory that this one is in, with this one picked there; and
;; from the first directory of a volume to the volumes, with that one
;; picked.
(defun go-up (browser)
  (let* ((place (browser-directory browser)) (above (above place)))
    (unless (string= place above)
      (list-directory browser above (if (string= above "")
                                        (volume-of place)
                                        (subseq place (length above)))))))

;; The name that is picked: a directory is gone into, and so is a volume;
;; a file is opened in the editor, which is launched for it.
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

;; What the status row says: a question; or what the pointer carries from
;; here; or words about what was done last; or how many names there are,
;; and which keys to use on them when the row has room for that.
(defun status (browser)
  (cond ((browser-asked browser) (car (browser-asked browser)))
        ((browser-carrying browser) (concatenate 'string "carrying " (browser-carrying browser)))
        ((browser-message browser))
        ((null (browser-names browser)) "nothing here")
        ((string= (browser-directory browser) "")
         (format nil "~D volumes: Enter opens" (length (browser-names browser))))
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
        (picked (browser-picked browser)) (font (browser-font browser)))
    (cond ((< picked (browser-top browser)) (setf (browser-top browser) picked))
          ((>= picked (+ (browser-top browser) rows)) (setf (browser-top browser) (- picked rows -1))))
    (let ((names (nthcdr (browser-top browser) (browser-names browser))))
      (dotimes (r rows)
        (let ((row (cons (fit (if names (concatenate 'string " " (row-text browser (car names))) "") columns)
                         (and names (= (+ (browser-top browser) r) picked)))))
          (unless (equal (svref shown r) row)
            (if (cdr row)
                (clara.draw:draw-cells surface 0 (* r (browser-high browser)) (car row) paper ink font)
                (clara.draw:draw-cells surface 0 (* r (browser-high browser)) (car row) ink paper font))
            (setf (svref shown r) row))
          (setq names (cdr names)))))
    (let ((text (fit (concatenate 'string " " (status browser)) columns)))
      (unless (equal (svref shown rows) text)
        (clara.draw:draw-cells surface 0 (* rows (browser-high browser)) text paper ink font)
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

;;; A file that goes somewhere else

(defun first-line (text)
  (let ((end (position #\Newline text)))
    (if end (subseq text 0 end) text)))

;; There is a file TO that holds what the file FROM holds, and when MOVING
;; the file FROM is no more: in that order, so that a machine which stops
;; between the two has the file twice and never not at all. The window
;; lists its directory again, with the file picked when it is there, and
;; what was done comes back as words. A file goes through memory whole,
;; and one that the machine has no memory for is not copied: that is no
;; error to the language, which would end the window's thread, so it is
;; made one here, for the status row.
(defun transfer (browser from to moving)
  (handler-case (clara:copy-file from to)
    (storage-condition (condition)
      (error "~A is not copied: ~A" from condition)))
  (let ((kept (and moving
                   (handler-case (progn (delete-file from) nil)
                     (error (condition)
                       (format nil "~A" condition)))))
        (place (browser-directory browser))
        (picked (browser-picked browser)))
    (when (and *cut* (string= *cut* from))
      (setq *cut* nil))
    (list-directory browser place (own-name to))
    (unless (string-equal (directory-of to) place)
      (pick browser picked))
    (cond ((not moving) (concatenate 'string "copied " from " to " to))
          (kept (concatenate 'string "copied " from " to " to ", and it is still where it was: " kept))
          (t (concatenate 'string "moved " from " to " to)))))

;; The file of a name is to be in the directory INTO: a copy of it, or with
;; MOVING the file itself. Words come back for what cannot be, and for what
;; was done; when there is a file of its name there already, nothing is
;; done yet, and the status row asks.
(defun put (browser name into moving)
  (let ((found (and (plusp (length name)) (funcall *found* name))))
    (cond ((string= name "") "nothing was copied that could be put here")
          ((null found) (concatenate 'string "there is no file " name))
          ((directory-name-p found) "a directory is not copied from here")
          ((string= into "") "a file goes into a directory, and this is the list of the volumes")
          (t (let* ((to (concatenate 'string into (own-name found)))
                    (there (funcall *found* to)))
               (cond ((string-equal (whole-name found) (whole-name to))
                      (concatenate 'string found " is there already"))
                     ((and there (directory-name-p there))
                      (concatenate 'string "there is a directory " there))
                     (there
                      (setf (browser-asked browser)
                            (cons (concatenate 'string "replace " to "? y replaces it")
                                  (lambda () (transfer browser found to moving))))
                      nil)
                     (t (transfer browser found to moving))))))))

;; The character with this code was typed in the window, or the key with it.
(defun key (browser code)
  (let ((asked (browser-asked browser)) (picked (browser-picked browser)))
    (setf (browser-message browser) nil
          (browser-asked browser) nil)
    (cond (asked
           (when (or (= code 121) (= code 89)) ; y, or Y
             (attempt browser (cdr asked))))
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
                    (let ((whole (concatenate 'string (browser-directory browser) name)))
                      (setf (browser-asked browser)
                            (cons (concatenate 'string "delete " whole "? y deletes it")
                                  (lambda ()
                                    (delete-file whole)
                                    (list-directory browser (browser-directory browser))
                                    (pick browser picked)
                                    (concatenate 'string "deleted " whole)))))))))
          ((= code 18)                  ; Ctrl-R
           (attempt browser (lambda ()
                              (list-directory browser (browser-directory browser)
                                              (nth picked (browser-names browser))))))
          ((= code 3)                   ; Ctrl-C: the name that is picked is what was copied last, for every window
           (let ((name (nth picked (browser-names browser))))
             (when (and name (not (string= name "../")))
               (let ((whole (concatenate 'string (browser-directory browser) name)))
                 (setf (clara.windows:clipboard) whole
                       (browser-message browser) (concatenate 'string "copied " whole))
                 (setq *cut* nil)))))
          ((= code 24)                  ; Ctrl-X: the same, of a file, and Ctrl-V moves that file
           (let ((name (nth picked (browser-names browser))))
             (cond ((null name))
                   ((directory-name-p name)
                    (setf (browser-message browser) "a directory is not moved from here"))
                   (t
                    (let ((whole (concatenate 'string (browser-directory browser) name)))
                      (setf (clara.windows:clipboard) whole
                            (browser-message browser) (concatenate 'string "cut " whole ": Ctrl-V moves it"))
                      (setq *cut* whole))))))
          ((= code 22)                  ; Ctrl-V: the file whose name was copied last comes here, or was cut and moves here
           (let ((name (first-line (clara.windows:clipboard))))
             (unless (and *cut* (string= *cut* name))
               (setq *cut* nil))
             (attempt browser (lambda () (put browser name (browser-directory browser) (and *cut* t))))))
          ((= code 17)                  ; Ctrl-Q
           (setf (browser-done browser) t)))))

;;; The pointer

;; The number of the name whose row a place of the window is in, or NIL
;; when no name's is.
(defun name-at (browser y)
  (let ((row (floor y (browser-high browser))))
    (and (>= y 0) (< row (browser-rows browser))
         (< (+ (browser-top browser) row) (length (browser-names browser)))
         (+ (browser-top browser) row))))

;; A button of the pointer went down or up in the window. The left one,
;; down on a name, picks it; and when it comes up on the name that it went
;; down on, without having been dragged, and that name was the picked one
;; already, the name is opened.
(defun point (browser y buttons)
  (let ((number (name-at browser y)) (pressed (browser-pressed browser)))
    (setf (browser-pressed browser) nil)
    (cond ((= 1 (logand buttons 1))
           (when number
             (setf (browser-message browser) nil
                   (browser-asked browser) nil
                   (browser-pressed browser) (cons number (= number (browser-picked browser))))
             (pick browser number)))
          ((and pressed (cdr pressed) number (= number (car pressed)))
           (attempt browser (lambda () (open-picked browser)))))))

;; The pointer has moved with the left button down, or with BUTTONS that
;; say no button the button has come up, somewhere. The name that it went
;; down on is carried from the first move on, when it is a file's: the
;; window manager is told, and tells the window that the button comes up
;; on. Such a name is not opened when the button comes up.
(defun drag (browser buttons)
  (let ((pressed (browser-pressed browser)))
    (cond ((= 0 (logand buttons 1))
           (setf (browser-carrying browser) nil))
          (pressed
           (let ((name (nth (car pressed) (browser-names browser))))
             (setf (browser-pressed browser) nil)
             (cond ((null name))
                   ((directory-name-p name)
                    (setf (browser-message browser) "a directory is not carried from here"))
                   (t
                    (let ((whole (concatenate 'string (browser-directory browser) name)))
                      (when (clara.windows:carry (browser-window browser) whole)
                        (setf (browser-carrying browser) whole))))))))))

;; The pointer let go of a text in the window, which it carried from this
;; window or from another: the name of a file, which is put into the
;; directory that it was let go on, or into the one that is listed when it
;; was let go anywhere else. On the volume that it was on already the file
;; moves, and on another there is a copy of it afterwards. The window
;; comes to the top, where its question can be answered.
(defun drop (browser y text)
  (let* ((number (name-at browser y))
         (name (and number (nth number (browser-names browser))))
         (place (browser-directory browser))
         (into (cond ((null name) place)
                     ((string= name "../") (above place))
                     ((directory-name-p name) (concatenate 'string place name))
                     (t place)))
         (from (first-line text)))
    (setf (browser-message browser) nil
          (browser-asked browser) nil)
    (clara.windows:raise-window (browser-window browser))
    (attempt browser (lambda () (put browser from into (same-volume-p from into))))))

(defun happened (browser event)
  (case (car event)
    (:key (key browser (cadr event)))
    (:pointer (point browser (caddr event) (cadddr event)))
    (:drag (drag browser (cadddr event)))
    (:drop (drop browser (caddr event) (cadddr event)))
    (:close (setf (browser-done browser) t))))

;;; The application

;; A browser in a window of its own, which lists the directory of a name.
;; COLUMNS and ROWS are the size of the list, in cells; X and Y are where
;; the window goes; and FONT is what the names are written in, one of
;; CLARA.TYPE:FONT's or NIL for the console's letters, which is the one that
;; CLARA.WINDOWS:*TEXT-FONT* says when the browser is told nothing. The
;; window is the thread's that calls.
(defun open-browser (place &key (columns 48) (rows 16) x y (font (clara.windows:text-font)))
  (let* ((place (if (directory-name-p place) place (concatenate 'string place "/")))
         (wide (clara.draw:cell-width font))
         (high (clara.draw:cell-height font))
         (window (clara.windows:open-window (title place) (* columns wide) (* (1+ rows) high) :x x :y y
                                            :events t :drag t :drop t))
         (browser (make-browser :window window :surface (clara.windows:window-surface window)
                                :font font :wide wide :high high :columns columns :rows rows :directory place
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
