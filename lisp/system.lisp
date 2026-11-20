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
;;;; This file loads under SBCL as well, where lisp/host/ stands in for the
;;;; machine, which there stays on whatever it is told.

(defpackage "CLARA.SYSTEM"
  (:use "COMMON-LISP")
  (:export "START" "SHUT-DOWN" "START-AGAIN" "SYSTEM" "SYSTEM-FILE" "BOOT-VOLUME" "UPGRADE"))
(in-package "CLARA.SYSTEM")

(defvar *lock* (clara:make-lock "system"))
(defvar *leaving* nil)      ; the machine is being shut down, :OFF, or started again, :AGAIN
(defvar *watcher* nil)      ; the thread that looks at the power button
(defvar *state* nil)        ; what the kernel knows of this start: CLARA.UNSAFE:START-STATE
(defvar *boot-volume* nil)  ; the volume that the machine was started from, or NIL when no disk has it

;; A line for whoever is watching, on the console: the serial port, and the
;; screen once the window manager has given it back.
(defun say (control &rest arguments)
  (fresh-line)
  (write-line (apply #'format nil control arguments)))

;;; Shutting down, and starting again

(defun done-to (how)
  (if (eq how :off) "shut down" "started again"))

;; The second half: nothing asks any more. A world that cannot be saved is
;; a reason to stop here, with everything as it was, so that whoever asked
;; can do something about it; a machine without a disk has nowhere to save
;; one, and goes all the same. After the window manager has stopped there
;; is no going back. Should the machine still be there after the substrate
;; was told, it has no way of doing it, and that is said.
(defun finish (how save)
  (unwind-protect
       (handler-case
           (progn
             (when save
               (cond ((clara.fat:volumes)
                      (clara:save-image)
                      (say "clara: the world is saved"))
                     (t
                      (say "clara: there is no disk to save the world on"))))
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
                    (say "clara: this machine cannot be started again from inside: that is for whoever runs it"))))
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

;;; An upgrade

;; What the firmware calls the kernel of this machine's processor, and of
;; the other.
(defun kernel-name ()
  (if (member :arm64 *features*) "BOOTAA64.EFI" "BOOTX64.EFI"))

(defun other-kernel ()
  (if (member :arm64 *features*) "BOOTX64.EFI" "BOOTAA64.EFI"))

;; One file of a system, from the volume it is taken from to the one that
;; the machine was started from, when it is what the manifest says: as long,
;; and with that sum.
(defun take-file (volume directory file)
  (let ((name (concatenate 'string directory (first file))))
    (multiple-value-bind (memory size pages) (on-volume (volume) (clara.fat:read-file name))
      (unwind-protect
           (progn
             (unless (and (= size (second file)) (string= (clara.unsafe:sha-512 memory size) (third file)))
               (error "the file ~A is not what the manifest of its system says it is" name))
             (on-volume (*boot-volume*)
               (clara.fat:write-file name memory size)))
        (clara.unsafe:free-memory memory pages)))))

;; The system that MANIFEST describes, taken from VOLUME: its directory is
;; made on the volume that the machine was started from, its files are
;; copied there, each held against the manifest, the manifest goes last,
;; which is what says that the system is whole, and then /clara/next says
;; that it is to be tried. Until that last file is written the machine
;; starts as it did before, whatever became of the rest. Its name.
(defun take (volume manifest)
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
      (take-file volume directory file))
    (multiple-value-bind (memory size pages)
        (on-volume (volume) (clara.fat:read-file (concatenate 'string directory "manifest")))
      (unwind-protect
           (on-volume (*boot-volume*)
             (clara.fat:write-file (concatenate 'string directory "manifest") memory size))
        (clara.unsafe:free-memory memory pages)))
    (on-volume (*boot-volume*)
      (write-text "/clara/next" (format nil "try ~A~%" name)))
    name))

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

;; A newer ClaraOS, or any other, takes the place of this one: the system
;; that another disk of the machine holds, or the volume FROM, is taken,
;; and the machine is started again to try it, unless START-AGAIN is NIL.
;; The system that was there stays until the new one has come to its
;; prompt. The name of the system that was taken.
(defun upgrade (&key from (start-again t))
  (unless *boot-volume*
    (error "the machine was not started from a disk that is known here, so there is nowhere to put a system"))
  (let ((source (if from
                    (let ((manifest (system-on from)))
                      (and manifest (cons from manifest)))
                    (find-source))))
    (unless source
      (error (if from
                 "that volume holds no ClaraOS other than this one, ~A"
                 "no other disk of this machine holds a ClaraOS other than this one, ~A")
             (system)))
    (let ((name (take (car source) (cdr source))))
      (say "system: ~A is on the disk, and is tried at the next start" name)
      (when start-again
        (leave :again t nil))
      name)))

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
;; and the machine started again; and otherwise the start has come to its
;; prompt.
(defun settle ()
  (format t "system: this is ClaraOS ~A~A~%" (system)
          (if (state :trial) ", on trial: the system before it is still in place" ""))
  (when *boot-volume*
    (when (state :failed)
      (note-failure (state :failed)))
    (let ((source (and (not (state :trial)) (at-once-source))))
      (cond ((state :trial)
             (commit))
            (source
             (take (car source) (cdr source))
             (format t "system: ~A is taken from another disk, and the machine starts again to try it~%"
                     (car (cdr source)))
             (leave :again nil t))))
    (came-to-prompt)))

;; For the substrate, at every boot, when the file system has started. A
;; world that was saved by a shutdown was in the middle of one, and is not
;; any more; the thread that watched the button was another machine's; and
;; what the kernel says of this start is another start's than the world
;; may remember.
(defun start ()
  (setq *leaving* nil
        *state* (clara.unsafe:start-state)
        *boot-volume* (find-boot-volume))
  (when *boot-volume*
    (setq clara.fat:*volume* *boot-volume*))
  (setq clara.windows:*application-directory* (and *boot-volume* (directory-of (system))))
  (handler-case (settle)
    (error (condition)
      (format t "system: ~A~%" condition)))
  (when (and *watcher* (clara:thread-alive-p *watcher*))
    (clara:destroy-thread *watcher*))
  (setq *watcher* (clara:make-thread #'watch-button :name "power button"))
  nil)

(clara.windows:define-command "Restart" (lambda () (asked :again)))
(clara.windows:define-command "Shut Down" (lambda () (asked :off)))
