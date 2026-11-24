;;;; system.lisp: the machine as a whole
;;;;
;;;; What is done to the system, and not in it: shutting the machine down,
;;;; starting it again, and putting a newer ClaraOS in the place of the one
;;;; that runs.
;;;;
;;;; Shutting down is something that the system does itself when it is
;;;; asked to: at a prompt, by the launcher's list, or by the machine's
;;;; power button, which is what a host presses when it wants a machine to
;;;; stop. It asks the windows whether their programs hold something that
;;;; would be lost, a text that is not saved, and goes no further while one
;;;; says so. It saves the world, so that the machine starts in it the next
;;;; time. It stops the window manager, and with it the applications. It
;;;; has every disk put what it was given where it lasts. And then the
;;;; substrate turns the machine off, or starts it again
;;;; (CLARA.UNSAFE:POWER-OFF, RESET). All of it in a thread of its own,
;;;; since the thread that asked may be an application's, and stopped on
;;;; the way.
;;;;
;;;; A system is one build of ClaraOS, and on a disk it is a directory:
;;;; /clara/<its name>, with its Lisp files, its two kernels and a manifest
;;;; that lists them, each with its length and its sum. The kernel has its
;;;; system's name in it and starts with the files of that directory and no
;;;; others (kernel/boot.c), so a second system can lie beside the first.
;;;; An upgrade is that: the running system takes the directory of another
;;;; system from another disk, file by file, each held against the
;;;; manifest; says in /clara/next that the system is to be tried; and
;;;; starts the machine again. The firmware still starts the old kernel,
;;;; which starts the new one in place of itself, once. When the new system
;;;; has come to its prompt it puts its kernels where the firmware looks
;;;; and takes the old system's directory away; when it has not, the next
;;;; start is the old system's again, as if nothing had been done. At no
;;;; moment does the disk hold a kernel that the firmware would start
;;;; without the files that go with it. Nothing else on the disk is
;;;; touched.
;;;;
;;;; What is defined at a prompt is in the heap and nowhere else, and a
;;;; world belongs to the system that saved it, so a newer system starts
;;;; without it. The work is therefore kept as text as well, which every
;;;; system reads, in a directory that is the user's and that no upgrade
;;;; writes to, /home: a file init.lisp, which is the user's to write, and
;;;; a file defined.lisp, which the listeners write, each form that defines
;;;; something as it was typed, in the place of an earlier one of the same
;;;; name. A world that is made from the files loads the two, in that
;;;; order, and a world that came back as an image loads what is new of
;;;; them since it was saved.
;;;;
;;;; A world is made again when a newer system takes this one's place. The
;;;; system that is leaving writes down what its world had that was the
;;;; user's, the names of the functions and the variables, and of the
;;;; variables the values that can be written as text (/clara/carried).
;;;; The system that comes makes a world of its own files, loads the text
;;;; of /home into it, gives the variables the values they had come to,
;;;; saves the world without being asked, and says what did not come
;;;; across (REPORT).
;;;;
;;;; A system can also be fetched, from where ClaraOS is published: a
;;;; directory on a web server that holds a system as a disk does, its files
;;;; and its manifest, and beside the manifest a signature of it, made with
;;;; a key whose public half every system has in it. The road is plain
;;;; HTTP, which anybody on the way can change, so nothing that arrives is
;;;; believed for having arrived: the manifest is held against the
;;;; signature, and every file against the manifest. What is taken that way
;;;; goes into a directory beside the system that runs and is tried like a
;;;; system from a disk.
;;;;
;;;; This file loads under SBCL as well, where lisp/host/ stands in for the
;;;; machine, which there stays on whatever it is told.

(defpackage "CLARA.SYSTEM"
  (:use "COMMON-LISP")
  (:export "START" "SHUT-DOWN" "START-AGAIN" "SYSTEM" "SYSTEM-FILE" "BOOT-VOLUME" "UPGRADE"
           "HOME" "HOME-FILE" "LOAD-HOME" "*PATIENCE*" "REPORT"
           "NEWEST" "*RELEASES*" "*RELEASE-KEY*"))
(in-package "CLARA.SYSTEM")

(defvar *lock* (clara:make-lock "system"))
(defvar *leaving* nil)      ; the machine is being shut down, :OFF, or started again, :AGAIN
(defvar *watcher* nil)      ; the thread that looks at the power button
(defvar *state* nil)        ; what the kernel knows of this start: CLARA.UNSAFE:START-STATE
(defvar *boot-volume* nil)  ; the volume that the machine was started from, or NIL when no disk has it
(defvar *home-lock* (clara:make-lock "home")) ; one listener at a time writes down what was defined
(defvar *patience* 60000)   ; how many milliseconds the user's text may take to load into a new world
(defvar *nothing* (list 'nothing)) ; what READ-FROM-STRING gives when no form is left
(defvar *report* nil)       ; what was said of how this world was made, and of what came into it since: lines, the newest first
(defvar *known* nil)        ; the text that this world has of the files of /home, as ((file . text) ...)
(defvar *follows* nil)      ; this world was given the text of /home, and takes what is new of it at every start
(defvar *system-packages* nil) ; the names of the packages that were there when this world was made
(defvar *releases* "https://claraos.org/releases/") ; where ClaraOS is published: the address of a directory there, or NIL for a system that is to know of no such place
(defvar *release-key* "2c67792528bac0b3570bb966e176e9b60ee04bfa0084ce50676db6cd8fca8dc6") ; the public half of the key that what is published there is signed with: 64 digits, or NIL
(defvar *parker* nil)       ; what lisp/parker.lisp hands over as it is loaded, two functions: :START, and :PACKAGES

;; A line for whoever is watching, on the console: the serial port, and the
;; screen once the window manager has given it back.
(defun say (control &rest arguments)
  (fresh-line)
  (write-line (apply #'format nil control arguments)))

;;; What is said of a world

;; The first so many of a list.
(defun first-of (list count)
  (let ((kept nil))
    (dotimes (i count)
      (when list
        (setq kept (cons (car list) kept)
              list (cdr list))))
    (reverse kept)))

;; A line that is kept, so that it can be said again: the lines that say
;; how this world was made and what came into it afterwards. The oldest go
;; when there are too many.
(defun keep (line)
  (setq *report* (cons line *report*))
  (when (> (length *report*) 400)
    (setq *report* (first-of *report* 300))))

;; A line of the report, said where the report goes and kept.
(defun tell (control &rest arguments)
  (let ((line (apply #'format nil control arguments)))
    (keep line)
    (format t "~A~%" line)))

;; Names as lines, as many to a line as fit with what stands before them.
(defun name-lines (names)
  (let ((lines nil) (line ""))
    (dolist (name names)
      (cond ((string= line "")
             (setq line name))
            ((> (+ (length line) 2 (length name)) 88)
             (setq lines (cons line lines)
                   line name))
            (t
             (setq line (concatenate 'string line ", " name)))))
    (unless (string= line "")
      (setq lines (cons line lines)))
    (reverse lines)))

;; A line that counts names, ONE for one of them and MANY for more, and
;; then the names. All of them are kept; a report says the first few lines
;; and where the rest is to be had.
(defun tell-names (one many names)
  (tell "~A" (if (cdr names) (format nil many (length names)) one))
  (let ((said 0))
    (dolist (line (name-lines names))
      (keep (concatenate 'string "world:   " line))
      (when (< said 3)
        (format t "world:   ~A~%" line))
      (setq said (1+ said)))
    (when (> said 3)
      (format t "world:   and more: (clara.system:report) names them all~%"))))

;; Everything that was said of how this world was made, and at every start
;; since that loaded something into it, said again.
(defun report ()
  (dolist (line (reverse *report*))
    (format t "~A~%" line))
  (values))

;;; Shutting down, and starting again

(defun done-to (how)
  (if (eq how :off) "shut down" "started again"))

;; The second half: nothing asks any more. When a system is waiting to be
;; tried at the next start, this world is on its way out, and what it has
;; that is the user's is written down for that system first (CARRY). A
;; world that cannot be saved is
;; a reason to stop here, with everything as it was, so that whoever asked
;; can do something about it, and is told how to go on without saving,
;; which is the one thing that can always be done; a machine without a
;; disk has nowhere to save
;; one, and goes all the same. After the window manager has stopped there
;; is no going back. Should the machine still be there after the substrate
;; was told, it has no way of doing it, and that is said.
(defun finish (how save)
  (unwind-protect
       (handler-case
           (let ((going t))
             (let ((next (waiting)))
               (when next
                 (handler-case (carry next)
                   (error (condition)
                     (say "system: what this world has could not be written down for ~A: ~A" next condition)))))
             (when save
               (cond ((clara.fat:volumes)
                      (handler-case (progn
                                      (clara:save-image)
                                      (say "clara: the world is saved"))
                        (error (condition)
                          (setq going nil)
                          (say "clara: the machine is not ~A: ~A" (done-to how) condition)
                          (say "clara:   ~A does it without saving the world"
                               (if (eq how :off) "(clara.system:shut-down :save nil)" "(clara.system:start-again :save nil)")))))
                     (t
                      (say "clara: there is no disk to save the world on"))))
             (when going
               (clara.windows:stop)
               (dolist (disk (clara.disk:disks))
                 (clara.disk:flush disk))
               (cond ((eq how :off)
                      (say "clara: turning the machine off")
                      (clara.unsafe:power-off)
                      (say "clara: this machine cannot be turned off from inside: it can be switched off now"))
                     (t
                      (say "clara: starting the machine again")
                      (clara.unsafe:reset)
                      (say "clara: this machine cannot be started again from inside: that is for whoever runs it")))))
         (serious-condition (condition)
           (say "clara: the machine is not ~A: ~A" (done-to how) condition)))
    (setq *leaving* nil)))

;; What every way of asking comes to. One at a time; and with FORCE nothing
;; is asked of the windows. The window that holds something back comes to
;; the top, where it can be seen, and the rest is an error for whoever
;; asked. Whoever asked waits for the thread that does the rest, and hears
;; from this again only when the machine is still there.
(defun leave (how save force)
  (clara:with-lock-held (*lock*)
    (when *leaving*
      (error "the machine is being ~A already" (done-to *leaving*)))
    (unless force
      (let ((held (clara.windows:unfinished)))
        (when held
          (ignore-errors (clara.windows:raise-window (car (car held))))
          (error "the machine is not ~A: the window ~S has ~A~A. Finish that, or ask with :FORCE T, which goes on without"
                 (done-to how) (clara.windows:window-title (car (car held))) (cdr (car held))
                 (if (cdr held) (format nil ", and ~D more have something too" (length (cdr held))) "")))))
    (setq *leaving* how))
  (ignore-errors (clara:join-thread (clara:make-thread (lambda () (finish how save)) :name "shutting down")))
  nil)

;; The machine is shut down: asked whether anything would be lost, saved,
;; stopped and turned off. SAVE NIL leaves the world that was saved last as
;; it is, and FORCE T does not ask the windows.
(defun shut-down (&key (save t) force)
  (leave :off save force))

;; The same, and the machine starts again at once, in the world that was
;; saved.
(defun start-again (&key (save t) force)
  (leave :again save force))

;; For the ways of asking that have nobody to hand an error to: the
;; launcher's list and the power button.
(defun asked (how)
  (handler-case (leave how t nil)
    (error (condition)
      (say "clara: ~A" condition))))

;; A host asks a machine to stop by pressing its power button, and the
;; substrate says when that has happened to whoever asks it. So this asks,
;; four times a second, for as long as the machine runs.
(defun watch-button ()
  (let ((tick (clara:make-event "power button")))
    (loop
      (clara:wait-event tick 250)
      (when (clara.unsafe:power-button)
        (say "clara: the power button was pressed")
        (asked :off)))))

;;; The system, and where it is

(defun state (name)
  (getf *state* name))

;; What this system is called: its version, and the digits of its build.
(defun system ()
  (state :system))

(defun directory-of (system)
  (concatenate 'string "/clara/" system "/"))

;; The name of a file of this system's, on the volume that the machine was
;; started from: (system-file "boot.lisp").
(defun system-file (name)
  (concatenate 'string (directory-of (system)) name))

(defun boot-volume ()
  *boot-volume*)

;; BODY with the names of files looked up on VOLUME.
(defmacro on-volume ((volume) &body body)
  `(let ((clara.fat:*volume* ,volume))
     ,@body))

;; Is there something of that name in a directory, a file or a directory?
(defun there-p (directory name)
  (let ((found nil) (as-directory (concatenate 'string name "/")))
    (dolist (entry (clara.fat:names directory) found)
      (when (or (string-equal entry name) (string-equal entry as-directory))
        (setq found t)))))

;; The file of a name, made of a text.
(defun write-text (name text)
  (let* ((bytes (clara.unsafe:string-bytes text))
         (pages (max 1 (floor (+ bytes 4095) 4096)))
         (memory (clara.unsafe:allocate-memory pages)))
    (unwind-protect
         (progn
           (clara.unsafe:string-memory text memory)
           (clara.fat:write-file name memory bytes))
      (clara.unsafe:free-memory memory pages))))

;; The handoff wrote a number into /clara/starts on the volume that the
;; kernel came from, which no other start was given, and the kernel knows
;; the number: the volume that has it is the one that the machine was
;; started from, wherever its disk is on the bus. On a volume that the
;; firmware could not write to there is no such file, and the first volume
;; is taken, as it always was.
(defun find-boot-volume ()
  (let ((token (state :token)) (found nil))
    (when token
      (dolist (volume (clara.fat:volumes))
        (unless found
          (let ((text (ignore-errors (on-volume (volume) (clara.fat:file-text "/clara/starts")))))
            (when (and text (>= (length text) 18) (string= (subseq text 2 18) token))
              (setq found volume))))))
    (or found (car (clara.fat:volumes)))))

;; This start has come to its prompt, and says so by taking away the file
;; in which the handoff counted it: a start that leaves the file where it
;; is makes the next one more careful (kernel/boot.c).
(defun came-to-prompt ()
  (ignore-errors
    (on-volume (*boot-volume*)
      (when (there-p "/clara/" "starts")
        (clara.fat:remove-file "/clara/starts")))))

;;; A system on a disk
;;;
;;; The manifest of a system is a text. Its first line is "ClaraOS system: "
;;; and the system's name; every line that begins with "file " then has
;;; the length of a file in bytes, its SHA-512 in 128 digits, and its name.
;;; Any other line is passed over, so that a later system can say more.

(defun starts-with (prefix text)
  (and (>= (length text) (length prefix)) (string= prefix (subseq text 0 (length prefix)))))

(defun lines (text)
  (let ((lines nil) (start 0))
    (dotimes (i (length text))
      (when (char= (char text i) #\Newline)
        (setq lines (cons (subseq text start i) lines)
              start (1+ i))))
    (when (< start (length text))
      (setq lines (cons (subseq text start) lines)))
    (reverse lines)))

;; The first COUNT words of a line, which single spaces keep apart, and
;; after them the rest of the line as one more.
(defun words (line count)
  (let ((found nil) (start 0) (cut 0))
    (dotimes (i (length line))
      (when (and (< cut count) (char= (char line i) #\Space))
        (setq found (cons (subseq line start i) found)
              start (1+ i)
              cut (1+ cut))))
    (reverse (cons (subseq line start) found))))

;; The number that a text of digits is, or NIL for any other text.
(defun number-of (text)
  (let ((number 0))
    (dotimes (i (length text) (and (> (length text) 0) (< (length text) 16) number))
      (let ((digit (- (char-code (char text i)) 48)))
        (unless (<= 0 digit 9)
          (return nil))
        (setq number (+ (* 10 number) digit))))))

;; A name that a file of a system can have: one that stays in the system's
;; own directory.
(defun plain-name-p (name)
  (let ((plain (and (> (length name) 0) (not (char= (char name 0) #\.)))))
    (dotimes (i (length name) plain)
      (when (or (char= (char name i) #\/) (char= (char name i) #\\))
        (setq plain nil)))))

;; What a manifest says: the name of its system and then its files, each
;; as (name bytes sum); or NIL for a text that is no manifest.
(defun read-manifest (text)
  (let* ((lines (lines text)) (prefix "ClaraOS system: ") (files nil))
    (when (and lines (starts-with prefix (car lines)))
      (dolist (line (cdr lines))
        (when (starts-with "file " line)
          (let* ((fields (words (subseq line 5) 2))
                 (bytes (and (= (length fields) 3) (number-of (first fields)))))
            (when (and bytes (= (length (second fields)) 128) (plain-name-p (third fields)))
              (setq files (cons (list (third fields) bytes (second fields)) files))))))
      (cons (subseq (car lines) (length prefix)) (reverse files)))))

;; The names of the systems that the volume which names are looked up on
;; holds: the directories of /clara.
(defun systems-here ()
  (let ((found nil))
    (dolist (entry (clara.fat:names "/clara/") (reverse found))
      (let ((length (length entry)))
        (when (and (> length 1) (char= (char entry (1- length)) #\/))
          (setq found (cons (subseq entry 0 (1- length)) found)))))))

;; The system that a volume holds and that is not this one: what its
;; manifest says, or NIL. A directory without a manifest is a system that
;; is not whole, and one whose manifest names another is none.
(defun system-on (volume)
  (on-volume (volume)
    (let ((found nil))
      (dolist (name (ignore-errors (systems-here)) found)
        (unless (or found (string= name (system)))
          (let ((manifest (ignore-errors
                            (read-manifest (clara.fat:file-text (concatenate 'string (directory-of name) "manifest"))))))
            (when (and manifest (string= (car manifest) name))
              (setq found manifest))))))))

;; A system's directory, and all that is in it, is no more: a system that
;; was upgraded from, or what an upgrade left that did not get to its end.
(defun remove-system (name)
  (let ((directory (directory-of name)))
    (when (there-p "/clara/" name)
      (dolist (file (clara.fat:names directory))
        (clara.fat:remove-file (concatenate 'string directory file)))
      (clara.fat:remove-directory directory))))

;;; What the user keeps as text
;;;
;;; /home, on the volume that the machine was started from, is the user's:
;;; no system writes there but for the one file that is spoken of here, and
;;; an upgrade leaves it alone. Two files in it are what a world is made of
;;; beside the system's own: init.lisp, which the user writes, and
;;; defined.lisp, which is written here, by RECORD, which the listeners
;;; call with every form that was typed and went well.
;;;
;;; defined.lisp is a file of Lisp like any other: forms, and between them
;;; (cl:in-package "NAME") wherever the forms that follow were read in
;;; another package than the ones before. A form that defines a name which
;;; an earlier form of the file defined, in the same package, takes that
;;; form's place, so that the file has each definition once, where it was
;;; first made; everything else goes to its end. The file is the user's to
;;; read and to change, and what this cannot read of it any more is left
;;; as it is.

(defun home ()
  "/home/")

(defun home-file (name)
  (concatenate 'string (home) name))

(defun blank-p (character)
  (or (char= character #\Space) (char= character #\Newline) (char= character #\Tab) (= (char-code character) 13)))

;; A text without the blank characters at its ends.
(defun trimmed (text)
  (let ((start 0) (end (length text)))
    (loop
      (unless (and (< start end) (blank-p (char text start)))
        (return))
      (setq start (1+ start)))
    (loop
      (unless (and (< start end) (blank-p (char text (1- end))))
        (return))
      (setq end (1- end)))
    (subseq text start end)))

;; Is that the name of one of the two files, as a LOAD would be given it?
(defun home-name-p (name)
  (and (stringp name)
       (or (string-equal name (home-file "init.lisp")) (string-equal name (home-file "defined.lisp")))))

;; A form that is written down: one that defines something, which is told
;; by its first word, since nothing short of evaluating a form says what
;; it does. A word that begins with DEFINE- is such a one, whatever it
;; names, as CLARA.WINDOWS:DEFINE-APPLICATION, which is a function; and a
;; word that begins with DEF when it is one of the language's own or a
;; macro, of the user's as well, and not a function that happens to be
;; called so. And a LOAD, since what a file defined is not in any form
;; that was typed; but not a LOAD of one of the two files themselves,
;; which would load itself from then on. And the one function of the
;; system's that puts something into a world for good under another name,
;; CLARA.WINDOWS:INSTALL-APPLICATION.
(defun defining-p (form)
  (and (consp form) (symbolp (car form))
       (if (eq (car form) 'load)
           (not (home-name-p (car (cdr form))))
           (or (starts-with "DEFINE-" (symbol-name (car form)))
               (eq (car form) 'clara.windows:install-application)
               (and (starts-with "DEF" (symbol-name (car form)))
                    (or (member (car form) '(defun defmacro defvar defparameter defconstant))
                        (handler-case (nth-value 1 (macroexpand-1 form))
                          (error () nil))))))))

;; What follows the name in a DEFMETHOD, as far as it says which method of
;; the generic function this is: the words before the parameters, and what
;; each parameter that must get an argument is for, a class, (EQL form), or
;; T when nothing is said.
(defun method-key (rest)
  (let ((words nil) (specializers nil))
    (loop
      (when (or (atom rest) (listp (car rest)))
        (return))
      (setq words (cons (car rest) words)
            rest (cdr rest)))
    (dolist (parameter (if (consp rest) (car rest)))
      (when (member parameter '(&optional &rest &body &key &aux &allow-other-keys))
        (return))
      (setq specializers (cons (if (consp parameter) (car (cdr parameter)) t) specializers)))
    (list (reverse words) (reverse specializers))))

;; What a form defines, as a text that two forms have in common when the
;; one is to take the other's place: its first word and what follows it,
;; as they print in the package that the form was read in. The methods of
;; a generic function all begin alike, and each is a definition of its own:
;; of a DEFMETHOD the text goes on to say which method it is.
(defun key-of (form package)
  (and (consp form) (symbolp (car form))
       (let ((*package* package))
         (if (and (eq (car form) 'defmethod) (consp (cdr form)))
             (format nil "DEFMETHOD ~S ~S" (car (cdr form)) (method-key (cdr (cdr form))))
             (format nil "~A ~S" (symbol-name (car form)) (car (cdr form)))))))

;; The forms of a text that is defined.lisp, in order, each as (start end
;; package key): where it begins in the text, with what lies before it,
;; and ends; the name of the package it is read in; and what it defines.
;; The second value is the name of the package that a form after the last
;; would be read in, or NIL when the text could not be read to its end,
;; which a form in a package that is not there is enough for.
(defun records (text)
  (let ((package "COMMON-LISP-USER") (start 0) (found nil) (whole t))
    (loop
      (let ((in (find-package package)))
        (unless in
          (setq whole nil)
          (return))
        (multiple-value-bind (form position)
            (handler-case (let ((*package* in)) (read-from-string text nil *nothing* :start start))
              (error ()
                (setq whole nil)
                (return)))
          (when (eq form *nothing*)
            (return))
          (if (and (consp form) (eq (car form) 'in-package) (consp (cdr form)))
              (setq package (string (car (cdr form))))
              (setq found (cons (list start position package (key-of form in)) found)))
          (setq start position))))
    (values (reverse found) (and whole package))))

;; What a new defined.lisp begins with. (The lines are put together here
;; and not in one control string: FORMAT has no way of going on in the next
;; line on ClaraOS.)
(defvar *first-lines*
  (concatenate 'string
               (format nil ";;;; What was defined at the prompt, as it was typed. ClaraOS writes a form~%")
               (format nil ";;;; here when it has been evaluated, in the place of an earlier one that~%")
               (format nil ";;;; defined the same name, and loads this file into a world that is made~%")
               (format nil ";;;; anew, after init.lisp. It is yours to read and to change.~%")))

;; Where a form begins that is read from START on and ends at END: after
;; the blank characters and the comments that stand before it, which are
;; no part of it.
(defun form-start (text start end)
  (loop
    (cond ((>= start end)
           (return end))
          ((blank-p (char text start))
           (setq start (1+ start)))
          ((char= (char text start) #\;)
           (loop
             (when (or (>= start end) (char= (char text start) #\Newline))
               (return))
             (setq start (1+ start))))
          (t
           (return start)))))

;; And where it ends, when reading it ended at END: a reader may take a
;; blank character after a form with it, which is no part of the form
;; either.
(defun form-end (text start end)
  (loop
    (unless (and (> end start) (blank-p (char text (1- end))))
      (return end))
    (setq end (1- end))))

;; What this world has of a file of /home: the text of the file as it was
;; when the world last loaded it or wrote it, or NIL.
(defun known (file)
  (cdr (assoc file *known* :test #'string=)))

(defun know (file text)
  (let ((entry (assoc file *known* :test #'string=)))
    (if entry
        (rplacd entry text)
        (setq *known* (cons (cons file text) *known*)))
    text))

;; TEXT, a form that was read in the package of that name, goes into
;; defined.lisp: where an earlier form of the same name is, or at the end,
;; after a line that says which package it is read in when that is not
;; the package of what stands before it.
(defun note (text package)
  (let* ((name (home-file "defined.lisp"))
         (there (there-p (home) "defined.lisp"))
         (old (if there (clara.fat:file-text name) *first-lines*))
         (in (find-package package))
         (key (and in (key-of (let ((*package* in)) (read-from-string text)) in))))
    (multiple-value-bind (records last) (records old)
      (let* ((same (and key (find-if (lambda (record)
                                       (and (string= (third record) package) (equal (fourth record) key)))
                                     records)))
             (new (if same
                      (concatenate 'string (subseq old 0 (form-start old (first same) (second same))) text
                                   (subseq old (form-end old (first same) (second same))))
                      (concatenate 'string old
                                   (if (and last (string= last package))
                                       ""
                                       (format nil "~%(cl:in-package ~S)~%" package))
                                   (format nil "~%~A~%" text)))))
        (write-text name new)
        ;; The world has this form, having evaluated it. It has the rest of
        ;; the file when the file was what the world last saw of it; what
        ;; somebody wrote into it since is still to be loaded.
        (when (or (not there) (equal old (known "defined.lisp")))
          (know "defined.lisp" new))))))

;; A form that takes back what another form put into the world for good:
;; the window manager's two, which take an application or a command out of
;; the launcher's list. What such a form takes back, as what the forms
;; that put it there define (KEY-OF), or NIL. The name is held against the
;; file as it is written in the form: one that is worked out there finds
;; nothing, unless it was worked out the same way where it was defined.
(defun taken-back (form)
  (and (consp form)
       (cond ((eq (car form) 'clara.windows:remove-application)
              (list (format nil "DEFINE-APPLICATION ~S" (car (cdr form)))
                    (format nil "INSTALL-APPLICATION ~S" (car (cdr form)))))
             ((eq (car form) 'clara.windows:remove-command)
              (list (format nil "DEFINE-COMMAND ~S" (car (cdr form))))))))

;; The forms of defined.lisp that define one of KEYS go out of it, in
;; whichever package they were read, each with the line that it ends: a
;; world that is made of the text is to be without them, like this one.
;; What stood before such a form, a comment, stays.
(defun forget (keys)
  (when (there-p (home) "defined.lisp")
    (let* ((name (home-file "defined.lisp")) (old (clara.fat:file-text name)) (new old))
      ;; From the last one back, so that the places of the ones before stay what they were.
      (dolist (record (reverse (records old)))
        (when (member (fourth record) keys :test #'equal)
          (let* ((start (form-start new (first record) (second record)))
                 (end (form-end new (first record) (second record)))
                 (after (if (and (< end (length new)) (char= (char new end) #\Newline)) (1+ end) end)))
            ;; and of two empty lines that the form stood between, one
            (when (and (>= start 2) (char= (char new (- start 1)) #\Newline) (char= (char new (- start 2)) #\Newline)
                       (< after (length new)) (char= (char new after) #\Newline))
              (setq after (1+ after)))
            (setq new (concatenate 'string (subseq new 0 start) (subseq new after))))))
      (unless (string= new old)
        (write-text name new)
        (when (equal old (known "defined.lisp"))
          (know "defined.lisp" new))))))

;; From a listener: a form was typed and went well. One that defines
;; something is written down, on the volume that the machine was started
;; from, and one that takes such a thing back takes it out of what was
;; written down; one at a time. That it could not be done is said, and is
;; no error of the form's.
(defun record (form text package)
  (when *boot-volume*
    (let ((keys (taken-back form)))
      (when (or keys (defining-p form))
        (handler-case
            (clara:with-lock-held (*home-lock*)
              (on-volume (*boot-volume*)
                (if keys
                    (forget keys)
                    (note (trimmed text) package))))
          (error (condition)
            (say (if keys
                     "home: what was taken back could not be taken out of ~A: ~A"
                     "home: what was defined could not be written down in ~A: ~A")
                 (home-file "defined.lisp") condition)))))))

;; The beginning of a text, on one line, for a report, whose lines stay
;; under a hundred characters with what stands before it.
(defun brief (text)
  (let ((line (trimmed text)) (cut 84))
    (dotimes (i (length line))
      (when (and (< i cut) (char= (char line i) #\Newline))
        (setq cut i)))
    (if (> (length line) cut)
        (concatenate 'string (subseq line 0 cut) " ...")
        line)))

;; A form of one of the two files is evaluated. A LOAD is called here, and
;; not evaluated as it stands: one that names either of the two files
;; would have a file load itself, without end, and is refused.
(defun evaluate (form)
  (if (and (consp form) (eq (car form) 'load))
      (let ((arguments (mapcar #'eval (cdr form))))
        (when (home-name-p (car arguments))
          (error "~A is loaded into a new world by itself, and not by a form of ~A" (car arguments) (home)))
        (apply #'load arguments))
      (eval form)))

;; The forms of a text that is one of the two files, each as the name of
;; the package that it is read in and its text: what a world that has
;; loaded the text has of it.
(defun pieces (text)
  (mapcar (lambda (record)
            (cons (third record)
                  (subseq text (form-start text (first record) (second record))
                          (form-end text (first record) (second record)))))
          (records text)))

;; The forms of a file, evaluated one after the other, as COMMON-LISP-USER
;; finds them. A form that fails is passed over, and so is everything after
;; a place that cannot be read: how many forms went well, and what did
;; not, each as the beginning of its text and the reason. When a form that
;; says which package the next ones are read in fails, those are passed
;; over too, up to the next such form: they would be read in a package
;; that they were not written for. The file is the one on the volume that
;; the machine was started from, wherever its forms have names looked up
;; afterwards. With HAD, a text that the world has loaded before, only the
;; forms that are not in it are evaluated and counted, and the ones that
;; name a package. The third value is the text that was read.
(defun load-forms (name &optional had)
  (let ((text (on-volume (*boot-volume*) (clara.fat:file-text name))) (start 0) (count 0) (failed nil)
        (skip (and had (pieces had))) (missing nil)
        (*package* (find-package "COMMON-LISP-USER")))
    (loop
      (let ((package (package-name *package*)))
        (multiple-value-bind (form position)
            (handler-case (read-from-string text nil *nothing* :start start)
              (error (condition)
                (setq failed (cons (list (brief (subseq text start)) condition) failed))
                (return)))
          (when (eq form *nothing*)
            (return))
          (let* ((piece (subseq text (form-start text start position) (form-end text start position)))
                 (names-package (and (consp form) (eq (car form) 'in-package)))
                 (old (and skip
                           (find-if (lambda (one) (and (string= (car one) package) (string= (cdr one) piece))) skip))))
            (cond (names-package
                   (handler-case
                       (progn
                         (evaluate form)
                         (setq missing nil)
                         (unless had
                           (setq count (1+ count))))
                     (serious-condition (condition)
                       (setq missing (format nil "~A" (car (cdr form))))
                       (setq failed (cons (list (brief piece) condition) failed)))))
                  (old nil)
                  (missing
                   (setq failed (cons (list (brief piece) (format nil "its package, ~A, is not there" missing)) failed)))
                  (t
                   (handler-case
                       (progn
                         (evaluate form)
                         (setq count (1+ count)))
                     (serious-condition (condition)
                       (setq failed (cons (list (brief piece) condition) failed)))))))
          (setq start position))))
    (values count (reverse failed) text)))

(defun forms (count)
  (if (= count 1) "1 form" (format nil "~D forms" count)))

;; A file of the user's is loaded into the world, in a thread of its own
;; that is given so long and no longer: a text that does not come to an
;; end must not keep the machine from its prompt. What was done is said,
;; and the world has that text from then on. With NEW, only the forms that
;; the world does not have yet are loaded, and nothing is said when there
;; are none.
(defun load-home-file (file &optional new)
  (let* ((name (home-file file)) (had (and new (or (known file) "")))
         (done (clara:make-event "loaded")) (count 0) (failed nil) (text nil) (ended nil)
         (thread (clara:make-thread
                  (lambda ()
                    (unwind-protect
                         (multiple-value-bind (went not read) (load-forms name had)
                           (setq count went
                                 failed not
                                 text read
                                 ended t))
                      (clara:signal-event done)))
                  :name "home")))
    (unless (clara:wait-event done *patience*)
      (clara:destroy-thread thread))
    (ignore-errors (clara:join-thread thread))
    (know file (or text (ignore-errors (on-volume (*boot-volume*) (clara.fat:file-text name))) ""))
    (cond ((not ended)
           (tell "home: ~A was not loaded to its end: it took more than ~D seconds, or could not be read"
                 name (floor *patience* 1000)))
          ((and new (= count 0) (null failed)))
          (t
           (let ((what (if new
                           (format nil "has ~A that this world did not have, which ~A loaded now" (forms count)
                                   (if (= count 1) "is" "are"))
                           (format nil "is loaded, ~A" (forms count)))))
             (cond (failed
                    (tell "home: ~A ~A~A, and ~A passed over:" name what (if new "" " of it")
                          (if (cdr failed) (format nil "~D were" (length failed)) "1 was"))
                    (dolist (one failed)
                      (tell "home:   ~A" (first one))
                      (tell "home:     ~A" (brief (format nil "~A" (second one))))))
                   (t
                    (tell "home: ~A ~A" name what))))))
    ended))

;; The directory that is the user's, made when it is not there, and what a
;; world that was made from the files gets of it: init.lisp, and then what
;; the listeners wrote down.
(defun make-home ()
  (ignore-errors
    (on-volume (*boot-volume*)
      (unless (there-p "/" "home")
        (clara.fat:make-directory "/home")))))

(defun home-has (file)
  (and *boot-volume* (ignore-errors (on-volume (*boot-volume*) (there-p (home) file)))))

;; The two files, loaded whole into this world, which follows the text
;; from then on. That is what a start does for a world that it made, and
;; what a user asks for in a world that was made without the text, after
;; two starts that went wrong, when the text has been put right.
(defun load-home ()
  (dolist (file '("init.lisp" "defined.lisp"))
    (when (home-has file)
      (load-home-file file)))
  (setq *follows* t)
  nil)

;; For a world that came back as an image: what the two files have that
;; the world has not, which is what was defined after the world was saved
;; on a machine that then stopped without saving it, and what somebody
;; wrote into a file since. A world that was made without the text takes
;; none of it by itself.
(defun catch-up ()
  (when *follows*
    (dolist (file '("init.lisp" "defined.lisp"))
      (when (home-has file)
        (let ((text (ignore-errors (on-volume (*boot-volume*) (clara.fat:file-text (home-file file))))))
          (when (and text (not (equal text (known file))))
            (load-home-file file t)))))))

;;; A world made again
;;;
;;; A world is its system's, and a newer system makes one of its own. What
;;; was defined comes across as text. What the text does not have is known
;;; to the world that is leaving and to nobody else, so that world leaves
;;; an account of itself for the system that is to be tried, in
;;; /clara/carried: forms, a line each, of keywords and strings, which a
;;; reader that does not know one passes over.
;;;
;;;   (:carried "from" "to")           the system that wrote it, and the one it is for
;;;   (:windows)                       the window manager was running
;;;   (:applications "NAME" ...)       the launcher's list, when its lines were moved: the applications in their order,
;;;   (:commands "NAME" ...)           and the commands
;;;   (:name "PACKAGE" "NAME" :function)   a function or a macro of the user's
;;;   (:name "PACKAGE" "NAME" :variable)   a variable of the user's
;;;   (:value "PACKAGE" "NAME" "text")     and its value, as COMMON-LISP-USER reads it
;;;
;;; What is the user's is what is in COMMON-LISP-USER and in the packages
;;; that were not there when the world was made. The system that comes
;;; makes its world, loads the text into it, puts the launcher's list in
;;; its order, gives the variables their values, and says which names it
;;; does not have.

;; The packages whose symbols are the user's: COMMON-LISP-USER, and every
;; package that was made since this world was, apart from the ones that
;; are called CLARA, which the launcher makes when it loads an application
;; of the system's, and the ones that came of a package which is installed
;; (lisp/parker.lisp): those are on the disk, and the world that is made
;; again has them from there.
(defun user-packages ()
  (let ((found nil) (installed (and *parker* (funcall (getf *parker* :packages)))))
    (dolist (package (list-all-packages))
      (let ((name (package-name package)))
        (when (or (string= name "COMMON-LISP-USER")
                  (not (or (starts-with "CLARA" name) (member name *system-packages* :test #'string=)
                           (member name installed :test #'string=))))
          (setq found (cons package found)))))
    (sort found #'string-lessp :key #'package-name)))

;; Is that made of nothing but what a text can say: numbers, characters,
;; strings, symbols that are in a package, and lists of those? As far as
;; 20000 parts go: a list that leads back into itself has no end.
(defun plain-p (value)
  (let ((left 20000) (pending (list value)))
    (loop
      (when (null pending)
        (return t))
      (let ((one (car pending)))
        (setq pending (cdr pending)
              left (1- left))
        (cond ((< left 0)
               (return nil))
              ((consp one)
               (setq pending (cons (car one) (cons (cdr one) pending))))
              ((or (integerp one) (characterp one) (stringp one)))
              ((and (symbolp one) (or (null one) (symbol-package one))))
              (t
               (return nil)))))))

;; A value as a text that COMMON-LISP-USER reads back as the same value,
;; or NIL when there is no such text of a reasonable length.
(defun as-text (value)
  (and (plain-p value)
       (handler-case
           (let* ((*package* (find-package "COMMON-LISP-USER"))
                  (text (prin1-to-string value)))
             (and (<= (length text) 64000)
                  (equal value (read-from-string text))
                  text))
         (error () nil))))

;; The system that /clara/next says is to be tried at the next start, or
;; NIL.
(defun waiting ()
  (let ((text (and *boot-volume*
                   (ignore-errors
                     (on-volume (*boot-volume*)
                       (and (there-p "/clara/" "next") (clara.fat:file-text "/clara/next")))))))
    (and text (starts-with "try " text) (trimmed (subseq text 4)))))

;; A line of the account that is a word and names: (:word "one" "two").
(defun write-names (out word names)
  (format out "(:~A" word)
  (dolist (name names)
    (format out " ~S" name))
  (format out ")~%"))

;; The account of this world, for the system TO, which is to take this
;; one's place.
(defun carry (to)
  (let ((text (with-output-to-string (out)
                (format out "(:carried ~S ~S)~%" (system) to)
                (when (clara.windows:running-p)
                  (format out "(:windows)~%"))
                (let ((order (clara.windows::arrangement)))
                  (when order
                    (write-names out "applications" (first order))
                    (write-names out "commands" (second order))))
                (dolist (package (user-packages))
                  (let ((in (package-name package)) (own nil))
                    (do-symbols (symbol package)
                      (when (and (eq (symbol-package symbol) package) (or (fboundp symbol) (boundp symbol)))
                        (setq own (cons symbol own))))
                    (dolist (symbol (sort own #'string-lessp :key #'symbol-name))
                      (when (fboundp symbol)
                        (format out "(:name ~S ~S :function)~%" in (symbol-name symbol)))
                      (when (boundp symbol)
                        (format out "(:name ~S ~S :variable)~%" in (symbol-name symbol))
                        (let ((value (as-text (symbol-value symbol))))
                          (when value
                            (format out "(:value ~S ~S ~S)~%" in (symbol-name symbol) value))))))))))
    (on-volume (*boot-volume*)
      (write-text "/clara/carried" text))))

;; The account that the system before this one left for this one, as a
;; list of its forms, or NIL: when there is none, when it was written for
;; another system, or when it does not begin as one.
(defun read-carried ()
  (let ((text (ignore-errors
                (on-volume (*boot-volume*)
                  (and (there-p "/clara/" "carried") (clara.fat:file-text "/clara/carried")))))
        (forms nil) (start 0)
        (*package* (find-package "COMMON-LISP-USER")))
    (when text
      (loop
        (multiple-value-bind (form position)
            (handler-case (read-from-string text nil *nothing* :start start)
              (error ()
                (return)))
          (when (eq form *nothing*)
            (return))
          (when (and (consp form) (keywordp (car form)))
            (setq forms (cons form forms)))
          (setq start position))))
    (setq forms (reverse forms))
    (and (eq (car (car forms)) :carried) (equal (third (car forms)) (system)) forms)))

;; An account is for one start, the one of the system that it was written
;; for, and of no use after it.
(defun forget-carried ()
  (ignore-errors
    (on-volume (*boot-volume*)
      (when (there-p "/clara/" "carried")
        (clara.fat:remove-file "/clara/carried")))))

;; A name of the account, as it is written at a prompt.
(defun written (package name)
  (if (string= package "COMMON-LISP-USER")
      name
      (concatenate 'string package "::" name)))

;; The names of a line of the account that is a word and names, or NIL
;; when there is no such line, or what it has is not names.
(defun names-of (word carried)
  (let ((names (cdr (assoc word carried))))
    (and (every #'stringp names) names)))

;; The launcher's list is in the order that the old world's had, when the
;; account says that its lines were moved there: the text has defined what
;; the list has by now, each name where it was first defined.
(defun arrange (carried)
  (when (or (assoc :applications carried) (assoc :commands carried))
    (handler-case
        (progn
          (clara.windows::arrange (names-of :applications carried) (names-of :commands carried))
          (tell "world: the launcher's list is in the order that its lines were moved into in the world before"))
      (error (condition)
        (tell "world: the launcher's list is not in the order that it had before: ~A" condition)))))

;; This world was made in the place of the one that left the account, and
;; has the text of /home in it. The launcher's list gets the order that it
;; had. The variables get the values that they had come to, where those
;; were written down and are not the ones that the text gave them; and what
;; the old world had and this one has not is said: a function that nothing
;; defines here, a variable without a value.
(defun arrive (carried)
  (arrange carried)
  (let ((put nil) (made nil) (lost nil) (with-value nil))
    (dolist (form carried)
      (when (and (eq (car form) :value) (stringp (second form)) (stringp (third form)) (stringp (fourth form)))
        (setq with-value (cons (written (second form) (third form)) with-value))
        (let ((package (find-package (second form))))
          (when package
            (handler-case
                (let ((symbol (intern (third form) package))
                      (value (let ((*package* (find-package "COMMON-LISP-USER")))
                               (read-from-string (fourth form)))))
                  (unless (and (boundp symbol) (equal (symbol-value symbol) value))
                    (set symbol value)
                    (setq put (cons (written (second form) (third form)) put))))
              (error () nil))))))
    (dolist (form carried)
      (when (and (eq (car form) :name) (stringp (second form)) (stringp (third form)))
        (let* ((package (find-package (second form)))
               (symbol (and package (find-symbol (third form) package)))
               ;; the package's own symbol, as the one of the account was, and not one that it has of another
               (here (and symbol
                          (eq (symbol-package symbol) package)
                          (if (eq (fourth form) :function) (fboundp symbol) (boundp symbol))))
               (name (written (second form) (third form))))
          (cond ((not here)
                 (setq lost (cons (if (eq (fourth form) :function)
                                      name
                                      (concatenate 'string name " (a variable)"))
                                  lost)))
                ((and (eq (fourth form) :variable) (not (member name with-value :test #'string=)))
                 (setq made (cons name made)))))))
    (when put
      (tell-names "world: 1 variable has the value that it had come to in the world before:"
                  "world: ~D variables have the values that they had come to in the world before:"
                  (reverse put)))
    (when made
      (tell-names "world: 1 variable held what is no text, and is as its form makes it here:"
                  "world: ~D variables held what is no text, and are as their forms make them here:"
                  (reverse made)))
    (if lost
        (tell-names "world: 1 name that the world before had is not defined in this one:"
                    "world: ~D names that the world before had are not defined in this one:"
                    (reverse lost))
        (tell "world: every function and every variable that the world before had is defined in this one"))))

;; The packages that are installed are told what kind of start this is
;; (lisp/parker.lisp): :MADE for a world that this start made from the
;; files, which loads them all; :RESUMED for one that came back as an image,
;; which takes what was installed since it was saved and lets go of what
;; was taken out; and :BARE for a world that is to be the system's alone.
;; They come before the text of /home, which may be written with them.
(defun packages (how)
  (when *parker*
    (handler-case (funcall (getf *parker* :start) how)
      (error (condition)
        (tell "packages: ~A" condition)))))

;; The world as it is now becomes the world that the machine starts in.
(defun save-world ()
  (tell "world: it is saved as it is now, and the next start is in it; (clara.system:report) says this again")
  (handler-case (clara:save-image)
    (error (condition)
      (tell "world: no, it could not be saved: ~A" condition))))

;; What tells one saved world from another without reading it: how long
;; its file is, and where on the disk it begins.
(defun image-identity ()
  (ignore-errors
    (on-volume (*boot-volume*)
      (let ((entry (find-if (lambda (entry) (string-equal (clara.fat:entry-name entry) "clara.image"))
                            (clara.fat:entries "/clara/"))))
        (and entry (format nil "~D ~D" (clara.fat:entry-size entry) (clara.fat::entry-cluster entry)))))))

;; The world that was saved did not come to its prompt at the start before
;; this one, so the handoff passed it over, and this world was made in its
;; place. Once, that may have been anything, a machine that was switched
;; off as it started: the saved world is kept, with a note of which one it
;; was (/clara/passed), and the next start tries it again. When the same
;; world is passed over a second time, it is the world, and this one is
;; saved in its place.
(defun passed-over ()
  (let ((identity (image-identity))
        (noted (ignore-errors
                 (on-volume (*boot-volume*)
                   (and (there-p "/clara/" "passed") (trimmed (clara.fat:file-text "/clara/passed")))))))
    (cond ((null identity))
          ((equal noted identity)
           (tell "world: the world that was saved did not come to its prompt a second time: this one takes its place")
           (save-world)
           (forget-passed))
          (t
           (ignore-errors
             (on-volume (*boot-volume*)
               (write-text "/clara/passed" (format nil "~A~%" identity))))
           (tell "world: the world that was saved did not come to its prompt at the start before this one.")
           (tell "world:   It is kept, and the next start tries it once more; this world is of the files and of /home/")))))

(defun forget-passed ()
  (ignore-errors
    (on-volume (*boot-volume*)
      (when (there-p "/clara/" "passed")
        (clara.fat:remove-file "/clara/passed")))))

;; A world that this start made from the files gets what the user keeps as
;; text. After an upgrade it is the world that takes the place of the old
;; system's: the window manager is started when it was running there, so
;; that the forms of the text which open windows have somewhere to open
;; them; the account that the old world left is gone through; and the
;; world is saved, without anybody asking, since the one on the disk is of
;; no use to this system.
(defun make-world ()
  (let ((carried (and (state :trial) (read-carried))))
    (when (state :trial)
      (tell "world: made anew by ClaraOS ~A, of its files and of what ~A holds as text" (system) (home)))
    (when (assoc :windows carried)
      (unless (handler-case (clara.windows:start) (error () nil))
        (tell "world: the window manager was running in the world before, and could not be started in this one")))
    (packages :made)
    (load-home)
    (when (state :trial)
      (if carried
          (arrive carried)
          (tell "world: the system before this one left no account of its world: what that had beyond the text is not known"))
      (forget-carried)
      (save-world))
    (when (state :passed-over)
      (passed-over))))

;; After two starts in a row that did not come to a prompt, the text may
;; be the reason: the world is made of the system's files alone, and says
;; what to do about it.
(defun make-bare-world ()
  (tell "home: the two starts before this one did not come to a prompt: what is in ~A is not loaded" (home))
  (tell "home:   this world is the system's alone. Put the files right, and (clara.system:load-home) loads them")
  (packages :bare))

;;; An upgrade

;; What the firmware calls the kernel of this machine's processor, and of
;; the other.
(defun kernel-name ()
  (if (member :arm64 *features*) "BOOTAA64.EFI" "BOOTX64.EFI"))

(defun other-kernel ()
  (if (member :arm64 *features*) "BOOTX64.EFI" "BOOTAA64.EFI"))

;; One file of a system, from where the system is taken from to the volume
;; that the machine was started from, when it is what the manifest says:
;; as long, and with that sum. READ gives a file of the system by its name:
;; the memory that it is in, how long it is, and how many page frames that
;; memory is.
(defun take-file (read directory file)
  (multiple-value-bind (memory size pages) (funcall read (first file))
    (unwind-protect
         (progn
           (unless (and (= size (second file)) (string= (clara.unsafe:sha-512 memory size) (third file)))
             (error "the file ~A~A is not what the manifest of its system says it is" directory (first file)))
           (on-volume (*boot-volume*)
             (clara.fat:write-file (concatenate 'string directory (first file)) memory size)))
      (clara.unsafe:free-memory memory pages))))

;; The system that MANIFEST describes, taken by READ, which gives a file of
;; it by its name, from another volume or from another machine: its
;; directory is made on the volume that the machine was started from, its
;; files are copied there, each held against the manifest, the manifest
;; goes last, which is what says that the system is whole, and then
;; /clara/next says that it is to be tried. Until that last file is
;; written the machine starts as it did before, whatever became of the
;; rest. Its name.
(defun take (read manifest)
  (let* ((name (car manifest)) (files (cdr manifest)) (directory (directory-of name)) (needed 65536))
    (unless (find-if (lambda (file) (string-equal (first file) (kernel-name))) files)
      (error "the system ~A has no kernel for this machine, which would be ~A" name (kernel-name)))
    (dolist (file files)
      (setq needed (+ needed (second file) 4096)))
    (on-volume (*boot-volume*)
      (remove-system name)
      (let ((free (clara.fat:free-bytes)))
        (when (< free needed)
          (error "the disk has ~D KiB free, and the system ~A takes ~D" (floor free 1024) name (floor needed 1024))))
      (clara.fat:make-directory directory))
    (dolist (file files)
      (take-file read directory file))
    (multiple-value-bind (memory size pages) (funcall read "manifest")
      (unwind-protect
           (on-volume (*boot-volume*)
             (clara.fat:write-file (concatenate 'string directory "manifest") memory size))
        (clara.unsafe:free-memory memory pages)))
    (on-volume (*boot-volume*)
      (write-text "/clara/next" (format nil "try ~A~%" name)))
    name))

;; How the files of a system are read that another volume holds.
(defun from-volume (volume name)
  (lambda (file)
    (on-volume (volume) (clara.fat:read-file (concatenate 'string (directory-of name) file)))))

;;; A system from another machine

;; The numbers of a system's version, as (0 0 28) of "0.0.28-41d0c97b", or
;; NIL for a name that does not begin with such numbers.
(defun version-of (name)
  (let ((numbers nil) (number nil))
    (dotimes (i (length name))
      (let* ((character (char name i)) (code (char-code character)))
        (cond ((<= 48 code 57)
               (setq number (+ (* 10 (or number 0)) (- code 48))))
              ((and number (or (char= character #\.) (char= character #\-)))
               (setq numbers (cons number numbers)
                     number nil)
               (when (char= character #\-)
                 (return)))
              (t
               (setq numbers nil
                     number nil)
               (return)))))
    (reverse (if number (cons number numbers) numbers))))

;; Is the system of one name a later version than that of another? Number
;; by number; two builds of one version are neither newer than the other.
(defun newer-p (name than)
  (let ((new (version-of name)) (old (version-of than)))
    (and new old
         (loop
           (cond ((and (null new) (null old)) (return nil))
                 ((null new) (return nil))
                 ((null old) (return t))
                 ((> (car new) (car old)) (return t))
                 ((< (car new) (car old)) (return nil)))
           (setq new (cdr new)
                 old (cdr old))))))

;; The address of something that is published at BASE.
(defun at-address (base &rest parts)
  (apply #'concatenate 'string base
         (if (and (> (length base) 0) (char= (char base (1- (length base))) #\/)) "" "/")
         parts))

;; Where ClaraOS is published, when nobody says: what the system knows of.
;; It is an address that begins with https://, and no other: a release is
;; held against its signature whatever road it came by, but which release
;; is the newest is said by a file that nobody signed, and what a machine
;; fetches is nobody's to read on the way.
(defun releases (from)
  (let ((base (or from *releases*
                  (error "this system knows of no place where ClaraOS is published: CLARA.SYSTEM:*RELEASES* names none"))))
    (unless (clara.net::secure-address-p base)
      (error "~A does not begin with https://: a release is fetched over a connection that is kept closed, and over no other" base))
    base))

;; The name of the newest system that is published at an address, which is
;; what the file "latest" there says. That file is not signed: whoever
;; changes it can name another release, and no more than that, since a
;; release is held against its signature, and is taken unasked only when
;; it is newer than the system that runs.
(defun newest (&optional from)
  (let* ((base (releases from))
         (name (trimmed (clara.net:fetch-text (at-address base "latest") :limit 4096))))
    (unless (and (plain-name-p name) (version-of name) (<= (length name) 39))
      (error "~A names no system: what it says is ~S" (at-address base "latest") (brief name)))
    name))

;; The newest system that is published at an address, taken: its manifest
;; is fetched, and held against its signature with the key that this system
;; has; then its files, each held against the manifest. A system without
;; a key asks for nothing: whatever came could be held against nothing.
;; UNASKED says that nobody named the place, and then the machine says
;; where it looks before it does. An error when the newest system is the
;; one that runs, and when it is no newer, unless ANY says that it is
;; wanted whatever its version. Its name.
(defun take-release (base any unasked)
  (unless *release-key*
    (error "this system has no key to hold a release against: CLARA.SYSTEM:*RELEASE-KEY* is NIL"))
  (releases base)
  (when unasked
    (say "system: no other disk of this machine holds another ClaraOS, so the newest one is looked for at ~A" base))
  (let ((name (newest base)))
    (when (string= name (system))
      (error "the newest ClaraOS at ~A is ~A, which is the system that runs" base name))
    (unless (or any (newer-p name (system)))
      (error "the newest ClaraOS at ~A is ~A, which is no newer than this one, ~A: :ANY T takes it all the same"
             base name (system)))
    (let ((signature (trimmed (clara.net:fetch-text (at-address base name "/manifest.sig") :limit 4096)))
          (kept nil))
      (multiple-value-bind (memory size pages) (clara.net:fetch (at-address base name "/manifest") :limit 1048576)
        (unwind-protect
             (let ((manifest (progn
                               (unless (clara.unsafe:ed25519 memory size signature *release-key*)
                                 (error "the manifest of ~A at ~A is not signed with the key that this system has: nothing of it is taken"
                                        name base))
                               (read-manifest (clara.unsafe:memory-string memory size)))))
               (unless (and manifest (string= (car manifest) name))
                 (error "the manifest of ~A at ~A is that of another system, or of none" name base))
               (say "system: ~A is published at ~A, and signed with the key that this system has: its files are fetched"
                    name base)
               (take (lambda (file)
                       (if (string= file "manifest")
                           ;; the very bytes that the signature is of, and once
                           (progn
                             (setq kept t)
                             (values memory size pages))
                           (clara.net:fetch (at-address base name "/" file))))
                     manifest))
          (unless kept
            (clara.unsafe:free-memory memory pages)))))))

;; The first volume, other than the one that the machine was started from,
;; that holds another system: the volume and what the system's manifest
;; says, as a pair, or NIL.
(defun find-source ()
  (let ((found nil))
    (dolist (volume (clara.fat:volumes) found)
      (unless (or found (eq volume *boot-volume*))
        (let ((manifest (system-on volume)))
          (when manifest
            (setq found (cons volume manifest))))))))

;; A newer ClaraOS, or any other, takes the place of this one. FROM says
;; where it is taken from: a volume, for the system that another disk of
;; the machine holds; the address of a place where ClaraOS is published,
;; as "https://claraos.org/releases/"; or nothing, and then it is the first
;; other disk that holds a system, and without one the place that this
;; system knows of, which it names before it asks there. From a disk any
;; system is taken that is not the one that runs. From another machine it
;; is the newest one that is published there, when it is signed with the
;; key that this system has, and when it is newer than this system or ANY
;; is true. The machine is started again to try it, unless START-AGAIN is
;; NIL. The system that was there stays until the new one has come to its
;; prompt. The name of the system that was taken.
(defun upgrade (&key from (start-again t) any)
  (unless *boot-volume*
    (error "the machine was not started from a disk that is known here, so there is nowhere to put a system"))
  (let* ((source (cond ((stringp from) nil)
                       (from (let ((manifest (system-on from)))
                               (and manifest (cons from manifest))))
                       (t (find-source))))
         (name (cond (source
                      (take (from-volume (car source) (car (cdr source))) (cdr source)))
                     ((stringp from)
                      (take-release from any nil))
                     ((and (null from) *releases*)
                      (take-release *releases* any t))
                     (t
                      (error (if from
                                 "that volume holds no ClaraOS other than this one, ~A"
                                 "no other disk of this machine holds a ClaraOS other than this one, ~A")
                             (system))))))
    (say "system: ~A is on the disk, and is tried at the next start" name)
    (when start-again
      (leave :again t nil))
    name))

;; A copy of a file on the same volume.
(defun copy-file (from to)
  (multiple-value-bind (memory size pages) (clara.fat:read-file from)
    (unwind-protect (clara.fat:write-file to memory size)
      (clara.unsafe:free-memory memory pages))))

;; This system was on trial, and has come to its prompt: it takes the place
;; of the one before it. Its kernels go where the firmware looks for them,
;; the other processor's first and this machine's own last, each in the
;; one step that writing a file over another is; then the file that asked
;; for the trial goes, and then every other system's directory.
(defun commit ()
  (on-volume (*boot-volume*)
    (dolist (kernel (list (other-kernel) (kernel-name)))
      (when (there-p (directory-of (system)) kernel)
        (copy-file (system-file kernel) (concatenate 'string "/EFI/BOOT/" kernel))))
    (when (there-p "/clara/" "next")
      (clara.fat:remove-file "/clara/next"))
    (dolist (other (systems-here))
      (unless (string= other (system))
        (remove-system other)))
    (format t "system: ~A has come to its prompt, and is the system of this machine from here on~%" (system))))

;; A system was tried and did not come to its prompt, and this is the one
;; from before it, started again. That is said, and noted in the directory
;; of the system that failed, so that it is not taken a second time
;; without anybody asking.
(defun note-failure (name)
  (format t "system: ~A was tried and did not come to its prompt: this is still ~A~%" name (system))
  (ignore-errors
    (on-volume (*boot-volume*)
      (when (there-p "/clara/" name)
        (write-text (concatenate 'string (directory-of name) "failed")
                    (format nil "this system was tried, and did not come to its prompt~%")))
      (when (there-p "/clara/" "next")
        (clara.fat:remove-file "/clara/next")))))

;; A disk that says "at once", by a file /clara/at-once, is one that the
;; machine was given so that it takes the system on it without being asked:
;; `make run-*` gives a machine each newer build that way (tools/run.sh).
;; The volume and the system's manifest, as a pair, or NIL; and NIL for a
;; system that was tried before and did not come to its prompt.
(defun at-once-source ()
  (let ((found nil))
    (dolist (volume (clara.fat:volumes) found)
      (unless (or found (eq volume *boot-volume*))
        (let ((manifest (and (ignore-errors (on-volume (volume) (there-p "/clara/" "at-once")))
                             (system-on volume))))
          (when manifest
            (if (on-volume (*boot-volume*) (there-p (directory-of (car manifest)) "failed"))
                (format t "system: ~A, on another disk, is not taken again: it did not come to its prompt~%"
                        (car manifest))
                (setq found (cons volume manifest)))))))))

;; What a start does about the system, once the drivers and the file system
;; are there: it says which system this is; when it is one on trial, it
;; takes the place of the one before; when another was tried and failed,
;; that is said; when a disk holds a system to take at once, it is taken,
;; and the machine started again. A world that was made on this start then
;; gets what the user keeps as text, unless the two starts before this one
;; did not come to a prompt, which the text may be the reason for. And
;; then the start has come to its prompt.
(defun settle ()
  (format t "system: this is ClaraOS ~A~A~%" (system)
          (if (state :trial) ", on trial: the system before it is still in place" ""))
  (when *boot-volume*
    (when (state :failed)
      (note-failure (state :failed)))
    (unless (state :trial)
      (forget-carried))
    (make-home)
    (when (state :trial)
      (commit))
    (when (state :resumed)
      (packages :resumed)
      (catch-up))
    (let ((source (and (not (state :trial)) (at-once-source))))
      (when source
        (take (from-volume (car source) (car (cdr source))) (cdr source))
        (format t "system: ~A is taken from another disk, and the machine starts again to try it~%"
                (car (cdr source)))
        (leave :again nil t)
        (return-from settle nil)))
    (unless (state :resumed)
      (if (>= (state :starts) 2)
          (make-bare-world)
          (make-world)))
    (came-to-prompt)
    ;; A saved world that has come this far was not why a start before it did not.
    (when (state :resumed)
      (forget-passed))))

;; For the substrate, at every boot, when the file system has started. A
;; world that was saved by a shutdown was in the middle of one, and is not
;; any more; the thread that watched the button was another machine's; and
;; what the kernel says of this start is another start's than the world
;; may remember.
(defun start ()
  (setq *leaving* nil
        *state* (clara.unsafe:start-state)
        *boot-volume* (find-boot-volume))
  (unless (state :resumed)
    (setq *report* nil
          *known* nil
          *follows* nil
          *system-packages* (mapcar #'package-name (list-all-packages))))
  (when *boot-volume*
    (setq clara.fat:*volume* *boot-volume*
          clara.fat:*image-volume* *boot-volume*))
  (setq clara.windows:*application-directory* (and *boot-volume* (directory-of (system))))
  (handler-case (settle)
    (error (condition)
      (format t "system: ~A~%" condition)))
  (when (and *watcher* (clara:thread-alive-p *watcher*))
    (clara:destroy-thread *watcher*))
  (setq *watcher* (clara:make-thread #'watch-button :name "power button"))
  nil)

(setq clara.listener:*record* #'record)

(clara.windows:define-command "Restart" (lambda () (asked :again)))
(clara.windows:define-command "Shut Down" (lambda () (asked :off)))
