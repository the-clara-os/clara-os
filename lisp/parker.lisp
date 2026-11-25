;;;; parker.lisp: Parker, which installs packages
;;;;
;;;; A package is something that is added to a ClaraOS: a name, a version,
;;;; and files of Lisp, of which some are loaded when the package is
;;;; installed and some are applications for the launcher's list. (The
;;;; language has packages of its own, which are sets of names. Where this
;;;; file means one of those, it says "a package of the language".)
;;;;
;;;; Packages are published at a source: a directory on a web server, with
;;;; an index that says what is there, package by package and file by file,
;;;; each file with its length and its sum, and beside the index a signature
;;;; of it. What a source has is taken the way a release of ClaraOS is
;;;; (lisp/system.lisp): by HTTPS and by no other road, the index held
;;;; against its signature with the public half of the key that the source
;;;; is named with, and every file against the index. So a package is its
;;;; publisher's, whatever web server hands it out; and what it is then is
;;;; code that does on the machine whatever it likes, as everything does
;;;; here, so a source is named with care.
;;;;
;;;;   <source>/index                      what there is
;;;;   <source>/index.sig                  the signature of those bytes
;;;;   <source>/<name>/<version>/<file>    every file that the index lists
;;;;
;;;; The index is a text. Its first line is "ClaraOS packages". A line
;;;; "package <name> <version>" begins a package, and the lines after it, up
;;;; to the next such line, say the rest:
;;;;
;;;;   about <a line of words>         what it is
;;;;   system <version>                the oldest ClaraOS that it is for
;;;;   needs <name>                    another package, which is installed with it
;;;;   load <file>                     a file that is loaded when it is installed, and into every world after that
;;;;   application <file> <name>       a name for the launcher's list, and the file that defines the application
;;;;   file <bytes> <sum> <name>       a file of it: its length, and its SHA-512 in 128 digits
;;;;
;;;; Any other line is passed over, so that a later Parker can say more: the
;;;; index is read by every ClaraOS that there has been since this one, and
;;;; is only ever added to.
;;;;
;;;; A package that is installed is a directory on the disk that the machine
;;;; was started from, /packages/<name>, with its files and a file "package",
;;;; which holds what the index said of it, word for word. That file is
;;;; written last and deleted first: a machine that stops on the way has a
;;;; package that is not installed, and never one that is and lacks a file.
;;;; No upgrade of the system writes there.
;;;;
;;;; The disk says what is installed, and a world follows it. A world that
;;;; is made from the files, at a first start or after an upgrade, loads
;;;; every package that the disk has; a world that came back as an image has
;;;; what it had when it was saved, and takes what was installed since and
;;;; lets go of what was taken out (FOLLOW, which lisp/system.lisp calls at
;;;; every start, before the text of /home is loaded).
;;;;
;;;; And Parker is an application: a window that lists what is installed and
;;;; what the sources have, where Enter installs the package that is picked
;;;; and Delete takes it out.
;;;;
;;;; This file loads under SBCL as well, where lisp/host/ stands in for the
;;;; machine.

(defpackage "CLARA.PARKER"
  (:use "COMMON-LISP")
  (:export "*SOURCES*" "AVAILABLE" "INSTALLED" "INSTALL" "UNINSTALL" "UPDATE" "LOAD-INSTALLED" "PARKER"))
(in-package "CLARA.PARKER")

(defvar *lock* (clara:make-lock "parker")) ; one thing is done about the packages at a time
(defvar *loaded* nil)       ; what this world has of the packages that are installed: a LOADED for each
(defvar *load* #'load)      ; what loads a file of a package: under SBCL the tests put a function here that reads the made-up disk

;; Where packages are published: each source is the address of a directory
;; and the public half of the key that its index is signed with, 64 digits.
;; The one that the system knows of is beside its releases, and signed with
;; the same key. Of two sources that have a package of one name, the first
;; is the one that it is taken from.
(defvar *sources* (list (list "https://claraos.org/packages/" clara.system:*release-key*)))

;; What a source says of a package, or the disk of one that is installed.
(defstruct entry
  name          ; "hello"
  version       ; "1.0.0"
  (about "")    ; a line of words
  system        ; the oldest ClaraOS that it is for, as "0.0.52", or NIL
  needs         ; the names of the packages that are installed with it
  loads         ; the files that are loaded, in this order
  applications  ; what it has for the launcher's list: (name . file) each
  files         ; its files: (name bytes sum) each
  lines         ; the lines that said all that, the last one first
  wrong)        ; a line of it is not what such a line has to be

;; What this world has of a package.
(defstruct loaded
  name          ; of the package,
  version       ; and which version of it
  packages      ; the names of the packages of the language that loading its files made
  applications) ; the names that it put into the launcher's list

(defun say (control &rest arguments)
  (fresh-line)
  (write-line (concatenate 'string "parker: " (apply #'format nil control arguments))))

;;; What an index says

;; Is every character of a text one of ALLOWED?
(defun made-of-p (text allowed)
  (let ((good t))
    (dotimes (i (length text) good)
      (unless (find (char text i) allowed)
        (setq good nil)))))

;; A name that a package can have: small letters, digits and hyphens, 32 at
;; the most, and the first no hyphen. It is the name of a directory.
(defun name-p (name)
  (and (<= 1 (length name) 32)
       (made-of-p name "abcdefghijklmnopqrstuvwxyz0123456789-")
       (not (char= (char name 0) #\-))))

;; A name that a file of a package can have: one that stays in the
;; package's directory, and is not the file that says what is installed.
(defun file-name-p (name)
  (and (<= 1 (length name) 64)
       (made-of-p name "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
       (not (char= (char name 0) #\.))
       (not (string-equal name "package"))))

;; A version: numbers with dots between them, as "1.0.2".
(defun version-p (text)
  (and (<= 1 (length text) 24) (made-of-p text "0123456789.") (clara.system::version-of text) t))

;; The name of an application: what fits a line of the launcher's list.
(defun title-p (name)
  (and (<= 1 (length name) 40) (not (char= (char name 0) #\Space))))

(defun find-entry (name entries)
  (find-if (lambda (entry) (string-equal name (entry-name entry))) entries))

;; One line of the index, for the package that it belongs to.
(defun entry-line (entry line)
  (setf (entry-lines entry) (cons line (entry-lines entry)))
  (cond ((clara.system::starts-with "about " line)
         (setf (entry-about entry) (subseq line 6)))
        ((clara.system::starts-with "system " line)
         (if (version-p (subseq line 7))
             (setf (entry-system entry) (subseq line 7))
             (setf (entry-wrong entry) t)))
        ((clara.system::starts-with "needs " line)
         (if (name-p (subseq line 6))
             (setf (entry-needs entry) (append (entry-needs entry) (list (subseq line 6))))
             (setf (entry-wrong entry) t)))
        ((clara.system::starts-with "load " line)
         (if (file-name-p (subseq line 5))
             (setf (entry-loads entry) (append (entry-loads entry) (list (subseq line 5))))
             (setf (entry-wrong entry) t)))
        ((clara.system::starts-with "application " line)
         (let ((fields (clara.system::words (subseq line 12) 1)))
           (if (and (= (length fields) 2) (file-name-p (first fields)) (title-p (second fields)))
               (setf (entry-applications entry)
                     (append (entry-applications entry) (list (cons (second fields) (first fields)))))
               (setf (entry-wrong entry) t))))
        ((clara.system::starts-with "file " line)
         (let* ((fields (clara.system::words (subseq line 5) 2))
                (bytes (and (= (length fields) 3) (clara.system::number-of (first fields)))))
           (if (and bytes (= (length (second fields)) 128) (file-name-p (third fields)))
               (setf (entry-files entry) (append (entry-files entry) (list (list (third fields) bytes (second fields)))))
               (setf (entry-wrong entry) t))))))

;; Does a list of names have one twice, in letters of either case?
(defun twice-p (names)
  (let ((twice nil))
    (loop
      (when (null names)
        (return twice))
      (when (member (car names) (cdr names) :test #'string-equal)
        (setq twice t))
      (setq names (cdr names)))))

;; Is that a package which can be installed: every line of it what such a
;; line has to be, no file and no application twice, and every file that is
;; loaded or that defines an application among its files?
(defun whole-p (entry)
  (let ((names (mapcar #'car (entry-files entry))))
    (and (not (entry-wrong entry))
         (not (twice-p names))
         (not (twice-p (mapcar #'car (entry-applications entry))))
         (not (twice-p (entry-needs entry)))
         (not (member (entry-name entry) (entry-needs entry) :test #'string-equal))
         (every (lambda (file) (member file names :test #'string=)) (entry-loads entry))
         (every (lambda (application) (member (cdr application) names :test #'string=)) (entry-applications entry)))))

;; What an index says: its packages, in its order, and T; or NIL and NIL for
;; a text that is no index. A package that this cannot install as it is
;; written is left out, and so is the second of two with one name.
(defun read-index (text)
  (let ((lines (clara.system::lines text)) (entries nil) (current nil))
    (if (and lines (string= (car lines) "ClaraOS packages"))
        (progn
          (dolist (line (cdr lines))
            (cond ((clara.system::starts-with "package " line)
                   (let ((fields (clara.system::words (subseq line 8) 1)))
                     (setq current (make-entry :name (first fields) :version (or (second fields) "") :lines (list line)))
                     (unless (and (= (length fields) 2) (name-p (first fields)) (version-p (second fields)))
                       (setf (entry-wrong current) t))
                     (setq entries (cons current entries))))
                  (current
                   (entry-line current line))))
          (let ((kept nil))
            (dolist (entry (reverse entries))
              (when (and (whole-p entry) (not (find-entry (entry-name entry) kept)))
                (setq kept (cons entry kept))))
            (values (reverse kept) t)))
        (values nil nil))))

;; The lines of a package as a text that READ-INDEX reads back: what the
;; file "package" of one that is installed holds.
(defun entry-text (entry)
  (with-output-to-string (out)
    (write-line "ClaraOS packages" out)
    (dolist (line (reverse (entry-lines entry)))
      (write-line line out))))

;;; What the sources have

;; What a source says that it has: its index, fetched, and held against its
;; signature with the key that the source is named with. Without a key
;; nothing is fetched: whatever came could be held against nothing.
(defun ask (source)
  (unless (and (consp source) (stringp (first source)))
    (error "a source is the address of a directory and the public half of a key, two strings in a list, and ~S is not that" source))
  (let ((base (first source)) (key (second source)))
    (unless (clara.net::secure-address-p base)
      (error "~A does not begin with https://: packages are fetched over a connection that is kept closed, and over no other" base))
    (unless (and (stringp key) (= (length key) 64))
      (error "the source ~A is named without the public half of a key, 64 digits: what it has could be held against nothing" base))
    (let ((signature (clara.system::trimmed (clara.net:fetch-text (clara.system::at-address base "index.sig") :limit 4096))))
      (multiple-value-bind (memory size pages) (clara.net:fetch (clara.system::at-address base "index") :limit 1048576)
        (unwind-protect
             (progn
               (unless (clara.unsafe:ed25519 memory size signature key)
                 (error "the index at ~A is not signed with the key that the source is named with: nothing of it is believed" base))
               (multiple-value-bind (entries index) (read-index (clara.unsafe:memory-string memory size))
                 (unless index
                   (error "what is at ~A, and signed, is no index of packages" (clara.system::at-address base "index")))
                 entries))
          (clara.unsafe:free-memory memory pages))))))

;; Every package that the sources have, each as (entry . the address of its
;; source), the first source's first.
(defun offered ()
  (let ((found nil))
    (dolist (source *sources*)
      (dolist (entry (ask source))
        (unless (find-offer (entry-name entry) found)
          (setq found (cons (cons entry (first source)) found)))))
    (reverse found)))

(defun find-offer (name offers)
  (find-if (lambda (offer) (string-equal name (entry-name (car offer)))) offers))

;;; What the disk has

(defun place (name)
  (concatenate 'string "/packages/" name "/"))

;; The package of a name as the disk has it: what its file "package" says,
;; when that is one package, and the one of that name.
(defun described (name)
  (and (clara.system::there-p (place name) "package")
       (let ((entries (read-index (clara.fat:file-text (concatenate 'string (place name) "package")))))
         (and entries (null (cdr entries)) (string-equal (entry-name (car entries)) name) (car entries)))))

;; The packages that are installed, in the order of their names: the
;; directories of /packages that say so, on the disk that the machine was
;; started from. A disk that does not answer is an error, and not a disk
;; with nothing installed: a world would let go of all that it has.
(defun on-disk ()
  (let ((volume (clara.system:boot-volume)) (found nil))
    (when volume
      (clara.system::on-volume (volume)
        (dolist (name (clara.fat:names "/packages/"))
          (let ((length (length name)))
            (when (and (> length 1) (char= (char name (1- length)) #\/))
              (let ((entry (ignore-errors (described (subseq name 0 (1- length))))))
                (when entry
                  (setq found (cons entry found)))))))))
    (sort found #'string-lessp :key #'entry-name)))

;; Packages in an order in which each comes after the ones that it needs,
;; as far as those are among them. Where packages need each other in a
;; ring, the first of them goes first.
(defun in-order (entries)
  (let ((ordered nil) (left entries))
    (loop
      (when (null left)
        (return ordered))
      (let ((ready (or (find-if (lambda (entry)
                                  (every (lambda (need) (or (find-entry need ordered) (not (find-entry need left))))
                                         (entry-needs entry)))
                                left)
                       (car left))))
        (setq ordered (append ordered (list ready))
              left (remove ready left))))))

;; What the disk has of the package of a name is no more: the file that
;; says that it is installed first.
(defun erase (name)
  (let ((volume (clara.system:boot-volume)) (directory (place name)))
    (when volume
      (clara.system::on-volume (volume)
        (when (clara.system::there-p "/packages/" name)
          (when (clara.system::there-p directory "package")
            (clara.fat:remove-file (concatenate 'string directory "package")))
          (dolist (file (clara.fat:names directory))
            (clara.fat:remove-file (concatenate 'string directory file)))
          (clara.fat:remove-directory directory))))))

;;; What a world has

(defun find-loaded (name)
  (find-if (lambda (loaded) (string-equal name (loaded-name loaded))) *loaded*))

;; A package that the disk has comes into this world: its files that are to
;; be loaded are, in their order, and its applications are in the launcher's
;; list from then on, each with its file, which the launcher loads when the
;; application is first picked. The packages of the language that are there
;; afterwards and were not before are the package's; when a file fails,
;; they go again, and nothing of the package is in the world.
(defun bring (entry)
  (let ((before (list-all-packages)) (directory (place (entry-name entry))) (made nil) (done nil))
    (dolist (application (entry-applications entry))
      (when (member (car application) (clara.windows:applications) :test #'string-equal)
        (error "the launcher's list has an application ~A already, which is not this package's" (car application))))
    (unwind-protect
         ;; on the disk that the machine was started from, wherever names are looked up by whoever asked
         (clara.system::on-volume ((clara.system:boot-volume))
           (dolist (file (entry-loads entry))
             (funcall *load* (concatenate 'string directory file)))
           (setq done t))
      (setq made (remove-if (lambda (package) (member package before)) (list-all-packages)))
      (unless done
        (dolist (package made)
          (ignore-errors (delete-package package)))))
    (dolist (application (entry-applications entry))
      (clara.windows:install-application (car application) (concatenate 'string directory (cdr application))))
    (setq *loaded* (cons (make-loaded :name (entry-name entry) :version (entry-version entry)
                                      :packages (mapcar #'package-name made)
                                      :applications (mapcar #'car (entry-applications entry)))
                         *loaded*))
    entry))

;; What this world has of the package of a name leaves it: its applications
;; are stopped and go from the launcher's list, with the packages of the
;; language that their files made, and the ones that its own files made are
;; deleted. One that cannot be, because another still uses it, stays, and
;; that is said.
(defun unload (name)
  (let ((loaded (find-loaded name)))
    (when loaded
      (dolist (application (loaded-applications loaded))
        (ignore-errors (clara.windows:remove-application application)))
      (dolist (package (loaded-packages loaded))
        (when (find-package package)
          (handler-case (delete-package package)
            (error (condition)
              (say "~A, a package of the language that ~A made, stays in this world: ~A" package (loaded-name loaded) condition)))))
      (setq *loaded* (remove loaded *loaded*)))))

;; The beginning of a text, for a line of the report: 84 characters of its
;; first line at the most.
(defun short (text)
  (let ((line (clara.system::brief text)))
    (if (> (length line) 84)
        (concatenate 'string (subseq line 0 80) " ...")
        line)))

;; The same, in a thread of its own that is given as long as a file of
;; /home is and no longer: a package that does not come to an end must not
;; keep the machine from its prompt. NIL when it went well, and otherwise
;; what went wrong, in words.
(defun bring-patiently (entry)
  (let* ((done (clara:make-event "package")) (trouble nil) (loaded nil)
         (thread (clara:make-thread
                  (lambda ()
                    (unwind-protect
                         (handler-case (progn
                                         (bring entry)
                                         (setq loaded t))
                           (serious-condition (condition)
                             (setq trouble (short (format nil "~A" condition)))))
                      (clara:signal-event done)))
                  :name "packages")))
    (unless (clara:wait-event done clara.system:*patience*)
      (clara:destroy-thread thread))
    (ignore-errors (clara:join-thread thread))
    (cond (trouble)
          (loaded nil)
          (t (let ((seconds (floor clara.system:*patience* 1000)))
               (if (= seconds 1)
                   "it took more than 1 second"
                   (format nil "it took more than ~D seconds" seconds)))))))

;; This world is brought into line with the disk. What it has of a package
;; that is no longer installed, or that is installed in another version by
;; now, leaves it; and every package that is installed and that it has not
;; is loaded, each after the ones that it needs. Three lists: the packages
;; that came, what left, and the ones that did not load, each of those with
;; the reason. A machine that was not started from a disk which is known
;; here cannot say what is installed, and its world is left as it is.
(defun follow ()
  (let ((came nil) (went nil) (failed nil))
    (when (clara.system:boot-volume)
      (let ((installed (in-order (on-disk))))
        (dolist (loaded (copy-list *loaded*))
          (let ((entry (find-entry (loaded-name loaded) installed)))
            (unless (and entry (string= (entry-version entry) (loaded-version loaded)))
              (unload (loaded-name loaded))
              (setq went (cons loaded went)))))
        (dolist (entry installed)
          (unless (find-loaded (entry-name entry))
            (let ((trouble (bring-patiently entry)))
              (if trouble
                  (setq failed (cons (cons entry trouble) failed))
                  (setq came (cons entry came))))))))
    (values (reverse came) (reverse went) (reverse failed))))

;; What FOLLOW did, said as lines of the report of how this world came to
;; be what it is (CLARA.SYSTEM:REPORT). MADE says that the world is new, and
;; has every package for the first time. The lines are part of what a
;; machine says as it starts, and stay under the width of its screen: the
;; reason why a package did not load has a line of its own.
(defun tell-of (came went failed made)
  (dolist (loaded went)
    (clara.system::tell "packages: ~A ~A is no longer installed, and has left this world" (loaded-name loaded) (loaded-version loaded)))
  (dolist (entry came)
    (clara.system::tell (if made
                            "packages: ~A ~A is installed, and is loaded into this world"
                            "packages: ~A ~A was installed since this world was saved, and is loaded now")
                        (entry-name entry) (entry-version entry)))
  (dolist (one failed)
    (clara.system::tell "packages: ~A ~A is installed, and did not load:" (entry-name (car one)) (entry-version (car one)))
    (clara.system::tell "packages:   ~A" (cdr one))))

;; For lisp/system.lisp, at every start, before the text of /home is
;; loaded, with what kind of start it is: :MADE for a world that this start
;; made from the files, :RESUMED for one that came back as an image, and
;; :BARE for one that is to be the system's alone, after two starts that
;; did not come to a prompt, which a package may be the reason for.
(defun at-start (how)
  (clara:with-lock-held (*lock*)
    (if (eq how :bare)
        (let ((installed (on-disk)))
          (when installed
            (clara.system::tell "packages: ~A installed, and none of that is loaded: (clara.parker:load-installed) loads it"
                                (if (cdr installed) (format nil "~D are" (length installed)) "1 is"))))
        (multiple-value-bind (came went failed) (follow)
          (tell-of came went failed (eq how :made))))))

;; The names of the packages of the language that the installed packages
;; made, their own files and the files of their applications: what is in
;; those is the packages' and not the user's, and comes back with the
;; packages when a world is made again (lisp/system.lisp).
(defun language-packages ()
  (let ((names nil))
    (dolist (loaded *loaded*)
      (setq names (append (loaded-packages loaded) names))
      (dolist (name (loaded-applications loaded))
        (let ((application (clara.windows::find-application name)))
          (when application
            (dolist (package (clara.windows::application-packages application))
              (when (package-name package)
                (setq names (cons (package-name package) names))))))))
    names))

(setq clara.system::*parker* (list :start #'at-start :packages #'language-packages))

;; The same as a start does, for whoever asks: after a start that loaded
;; none of the packages, when what was wrong is put right. The names of the
;; packages that this world has.
(defun load-installed ()
  (clara:with-lock-held (*lock*)
    (multiple-value-bind (came went failed) (follow)
      (tell-of came went failed t)))
  (reverse (mapcar #'loaded-name *loaded*)))

;;; Installing

;; Is the package for a newer ClaraOS than this one?
(defun too-new-p (entry)
  (and (entry-system entry) (clara.system::newer-p (entry-system entry) (clara.system:system))))

;; The files of a package, fetched from its source, each held against what
;; the index says of it: (name memory bytes pages) for each, whose memory
;; is the caller's to give back. All of them or none: when one cannot be
;; had, or is not what was said, the ones before it are given back here.
(defun fetch-files (entry base)
  (let ((had nil) (whole nil))
    (unwind-protect
         (progn
           (dolist (file (entry-files entry))
             (multiple-value-bind (memory bytes pages)
                 (clara.net:fetch (clara.system::at-address base (entry-name entry) "/" (entry-version entry) "/" (first file))
                                  :limit (max 4096 (second file)))
               (setq had (cons (list (first file) memory bytes pages) had))
               (unless (and (= bytes (second file)) (string= (clara.unsafe:sha-512 memory bytes) (third file)))
                 (error "the file ~A of ~A ~A is not what the index at ~A says it is" (first file) (entry-name entry)
                        (entry-version entry) base))))
           (setq whole t)
           (reverse had))
      (unless whole
        (give-back had)))))

(defun give-back (had)
  (dolist (one had)
    (clara.unsafe:free-memory (second one) (fourth one))))

;; A package that a source has is on the disk: its files are fetched, all
;; of them, before the disk is touched; then what this world and the disk
;; have of an older one goes, its directory is made, its files are written,
;; and the file that says that it is installed last. When the disk fails on
;; the way, the world is brought into line with whatever it holds by then:
;; the older one, when that is still whole, or nothing of the package.
(defun take (entry base)
  (let ((volume (or (clara.system:boot-volume)
                    (error "the machine was not started from a disk that is known here, so there is nowhere to put a package")))
        (name (entry-name entry)))
    (when (too-new-p entry)
      (error "~A ~A is for ClaraOS ~A and newer, and this is ~A" name (entry-version entry) (entry-system entry) (clara.system:system)))
    (let ((had (fetch-files entry base)) (needed 65536) (begun nil) (written nil))
      (unwind-protect
           (clara.system::on-volume (volume)
             (dolist (one had)
               (setq needed (+ needed (third one) 4096)))
             (let ((free (clara.fat:free-bytes)))
               (when (< free needed)
                 (error "the disk has ~D KiB free, and ~A ~A takes ~D" (floor free 1024) name (entry-version entry) (floor needed 1024))))
             (setq begun t)
             (unload name)
             (erase name)
             (unless (clara.system::there-p "/" "packages")
               (clara.fat:make-directory "/packages"))
             (clara.fat:make-directory (place name))
             (dolist (one had)
               (clara.fat:write-file (concatenate 'string (place name) (first one)) (second one) (third one)))
             (clara.system::write-text (concatenate 'string (place name) "package") (entry-text entry))
             (setq written t))
        (give-back had)
        (when (and begun (not written))
          (ignore-errors (follow)))))
    entry))

;; What is said of a package that is installed now.
(defun installed-line (entry)
  (let ((applications (mapcar #'car (entry-applications entry))) (names ""))
    (dolist (name applications)
      (setq names (if (string= names "") name (concatenate 'string names ", " name))))
    (cond ((null applications) (format nil "~A ~A is installed" (entry-name entry) (entry-version entry)))
          ((cdr applications)
           (format nil "~A ~A is installed, with the applications ~A" (entry-name entry) (entry-version entry) names))
          (t (format nil "~A ~A is installed, with the application ~A" (entry-name entry) (entry-version entry) names)))))

;; A package that a source has is taken, and loaded into this world. One
;; that does not load is not installed: the disk has nothing of it
;; afterwards. Unless it took the place of an OLDER one, which is gone by
;; then: it stays, and every start tries it again.
(defun settle-in (entry base older)
  (take entry base)
  (handler-case (bring entry)
    (error (condition)
      (cond (older
             (error "~A ~A is installed in the place of ~A, and did not load: ~A" (entry-name entry) (entry-version entry)
                    (entry-version older) condition))
            (t
             (erase (entry-name entry))
             (error "~A ~A was fetched, and did not load, so it is not installed: ~A" (entry-name entry) (entry-version entry)
                    condition)))))
  (say "~A" (installed-line entry)))

;; What has to be taken for the package of a name to be there: its offer,
;; after the offers of what it needs and the disk has not, each once. TRAIL
;; are the packages on whose account this one is looked at.
(defun plan (name offers installed trail)
  (let ((offer (find-offer name offers)))
    (cond ((find-entry name installed) nil)
          ((member name trail :test #'string-equal)
           (error "the packages ~A and ~A need each other, so neither can be installed first" (car trail) name))
          ((and (null offer) trail)
           (error "~A needs the package ~A, which is not installed, and which no source has" (car trail) name))
          ((null offer)
           (error "there is no package ~A: ~A" name
                  (cond ((null *sources*) "no source is named, CLARA.PARKER:*SOURCES*")
                        ((null offers) "the sources have none at all")
                        (t (format nil "the sources have ~S" (sort (mapcar (lambda (one) (entry-name (car one))) offers)
                                                                   #'string-lessp))))))
          (t
           (let ((before nil))
             (dolist (need (entry-needs (car offer)))
               (dolist (one (plan need offers installed (cons (entry-name (car offer)) trail)))
                 (unless (member one before)
                   (setq before (append before (list one))))))
             (append before (list offer)))))))

;; The package of that name is installed, from the first source that has
;; it, with the packages that it needs, those first. The names of what was
;; installed, or NIL when the package was there already.
(defun install (name)
  (unless (stringp name)
    (error "a package is installed by its name, a string, and ~S is not one" name))
  (clara:with-lock-held (*lock*)
    (let* ((installed (on-disk)) (there (find-entry name installed)))
      (cond (there
             (say "~A ~A is installed already: (clara.parker:update) looks for a newer one" (entry-name there) (entry-version there))
             nil)
            (t
             (let ((wanted (plan name (offered) installed nil)))
               (dolist (offer wanted)
                 (settle-in (car offer) (cdr offer) nil))
               (mapcar (lambda (offer) (entry-name (car offer))) wanted)))))))

;; The package of that name is taken out: of this world, and from the
;; disk. Not while another package that is installed needs it.
(defun uninstall (name)
  (unless (stringp name)
    (error "a package is taken out by its name, a string, and ~S is not one" name))
  (clara:with-lock-held (*lock*)
    (let* ((installed (on-disk)) (entry (find-entry name installed)))
      (unless entry
        (error "no package ~A is installed: the ones that are are ~S" name (mapcar #'entry-name installed)))
      (let ((leans (find-if (lambda (other) (member (entry-name entry) (entry-needs other) :test #'string-equal)) installed)))
        (when leans
          (error "~A is needed by ~A, which is installed: that one goes first" (entry-name entry) (entry-name leans))))
      ;; when the disk fails on the way, the world is brought into line with what it holds by then
      (let ((gone nil))
        (unwind-protect
             (progn
               (unload (entry-name entry))
               (erase (entry-name entry))
               (setq gone t))
          (unless gone
            (ignore-errors (follow)))))
      (say "~A ~A is no longer installed" (entry-name entry) (entry-version entry))
      (entry-name entry))))

;; Every package that is installed, or the ones that are named, when a
;; source has a newer version of it: that one takes its place, with
;; whatever it needs that the older one did not. The names of the packages
;; that were replaced.
(defun update (&rest names)
  (clara:with-lock-held (*lock*)
    (let ((installed (on-disk)) (taken nil))
      (dolist (name names)
        (unless (and (stringp name) (find-entry name installed))
          (error "no package ~A is installed: the ones that are are ~S" name (mapcar #'entry-name installed))))
      (let ((offers (and installed (offered))))
        (dolist (entry (in-order installed))
          (when (or (null names) (member (entry-name entry) names :test #'string-equal))
            (let ((offer (find-offer (entry-name entry) offers)))
              (when (and offer (clara.system::newer-p (entry-version (car offer)) (entry-version entry)))
                (dolist (need (entry-needs (car offer)))
                  (dolist (more (plan need offers (on-disk) (list (entry-name entry))))
                    (settle-in (car more) (cdr more) nil)))
                (settle-in (car offer) (cdr offer) entry)
                (setq taken (cons (entry-name entry) taken)))))))
      (reverse taken))))

;; What the sources have: the name of each package, its version, and what
;; it is, in the order of the names.
(defun available ()
  (clara:with-lock-held (*lock*)
    (sort (mapcar (lambda (offer) (list (entry-name (car offer)) (entry-version (car offer)) (entry-about (car offer))))
                  (offered))
          #'string-lessp :key #'car)))

;; What is installed: the name of each package and its version, in the
;; order of the names.
(defun installed ()
  (mapcar (lambda (entry) (list (entry-name entry) (entry-version entry))) (on-disk)))

;;; The window
;;;
;;; An application, like the file browser (lisp/jaid.lisp), and written
;;; the same way: OPEN-VIEW makes the window and what it holds, KEY, POINT
;;; and HAPPENED change that, RENDER draws it, and RUN is the loop that the
;;; launcher's thread sits in.

;; A line of the window: a package that is installed, or that a source
;; has, or both.
(defstruct row
  name
  here      ; the version that is installed, or NIL
  offered   ; the version that a source has, or NIL
  about)

(defstruct view
  window
  surface         ; what its window is drawn on
  font            ; what the list is written in: one of CLARA.TYPE:FONT's, or NIL for the console's letters
  wide            ; the size of a cell of that, in pixels
  high
  columns         ; the size of the list's part of the window, in cells:
  rows            ;   the window has two rows more, one above it for what the columns are, and one below it for the status
  ink             ; the pixel of a glyph,
  paper           ; and the pixel around it; the package that is picked has the two the other way round, and so has the status
  offers          ; what the sources said when they were last asked
  lines           ; the rows of the list, in the order of their names
  (picked 0)      ; the number of the one that is picked
  (top 0)         ; the number of the one in the list's first row
  shown           ; what each row of the window shows, as it was drawn: (text . picked), or NIL for a row to draw again
  message         ; words for the status row, until the next key
  doomed          ; the name of the package that Delete was typed on, while the question is open
  done)           ; the window is to close

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

;; What the window lists: every package that is installed or that a source
;; has, once.
(defun rows-of (installed offers)
  (let ((rows nil))
    (dolist (entry installed)
      (setq rows (cons (make-row :name (entry-name entry) :here (entry-version entry) :about (entry-about entry)) rows)))
    (dolist (offer offers)
      (let* ((entry (car offer))
             (row (find-if (lambda (row) (string-equal (row-name row) (entry-name entry))) rows)))
        (if row
            (setf (row-offered row) (entry-version entry)
                  (row-about row) (entry-about entry))
            (setq rows (cons (make-row :name (entry-name entry) :offered (entry-version entry) :about (entry-about entry))
                             rows)))))
    (sort rows #'string-lessp :key #'row-name)))

;; The list is made again of what the disk has and of what the sources last
;; said, with the package of the name PICK picked when it is there.
(defun relist (view &optional pick)
  (let ((rows (rows-of (on-disk) (view-offers view))))
    (setf (view-lines view) rows
          (view-picked view) (or (and pick (position-if (lambda (row) (string-equal (row-name row) pick)) rows)) 0)
          (view-top view) 0)
    nil))

;; The name of the package that is picked, or NIL.
(defun picked-name (view)
  (let ((row (nth (view-picked view) (view-lines view))))
    (and row (row-name row))))

;; The text of a row of the list: the package's name, the version that is
;; installed, the version that a source has, and what it is.
(defun row-text (row)
  (concatenate 'string " " (fit (row-name row) 16) " " (fit (or (row-here row) "-") 8) " " (fit (or (row-offered row) "-") 8)
               " " (row-about row)))

;; And what stands over the list, a word for each of the four.
(defun heading ()
  (concatenate 'string " " (fit "package" 16) " " (fit "here" 8) " " (fit "offered" 8) " about"))

;; What the status row says: a question; or words about what was done last;
;; or how many packages there are, and which keys to use on them when the
;; row has room for that.
(defun status (view)
  (cond ((view-doomed view)
         (concatenate 'string "take " (view-doomed view) " out? y does it"))
        ((view-message view))
        ((null (view-lines view)) "no package is installed, and no source has said what there is: Ctrl-R asks")
        (t (let ((count (if (cdr (view-lines view)) (format nil "~D packages" (length (view-lines view))) "1 package"))
                 (keys ": Enter installs, Delete takes out, Ctrl-R asks again"))
             (if (< (+ (length count) (length keys)) (view-columns view))
                 (concatenate 'string count keys)
                 count)))))

;; The window shows the list again, around the package that is picked,
;; between its two rows: each row that is not what was drawn there is
;; drawn, and then shown.
(defun render (view)
  (let ((rows (view-rows view)) (columns (view-columns view)) (surface (view-surface view))
        (shown (view-shown view)) (ink (view-ink view)) (paper (view-paper view))
        (picked (view-picked view)) (font (view-font view)))
    (cond ((< picked (view-top view)) (setf (view-top view) picked))
          ((>= picked (+ (view-top view) rows)) (setf (view-top view) (- picked rows -1))))
    (let ((text (fit (heading) columns)))
      (unless (equal (svref shown 0) text)
        (clara.draw:draw-cells surface 0 0 text ink paper font)
        (setf (svref shown 0) text)))
    (let ((lines (nthcdr (view-top view) (view-lines view))))
      (dotimes (r rows)
        (let ((row (cons (fit (if lines (row-text (car lines)) "") columns)
                         (and lines (= (+ (view-top view) r) picked)))))
          (unless (equal (svref shown (1+ r)) row)
            (if (cdr row)
                (clara.draw:draw-cells surface 0 (* (1+ r) (view-high view)) (car row) paper ink font)
                (clara.draw:draw-cells surface 0 (* (1+ r) (view-high view)) (car row) ink paper font))
            (setf (svref shown (1+ r)) row))
          (setq lines (cdr lines)))))
    (let ((text (fit (concatenate 'string " " (status view)) columns)))
      (unless (equal (svref shown (1+ rows)) text)
        (clara.draw:draw-cells surface 0 (* (1+ rows) (view-high view)) text paper ink font)
        (setf (svref shown (1+ rows)) text)))
    (clara.windows:show (view-window view))))

;; The last line of what was said, without the word that every line of
;; this file's begins with, or NIL when nothing was said.
(defun last-said (text)
  (let ((last nil))
    (dolist (line (clara.system::lines text))
      (unless (string= line "")
        (setq last line)))
    (if (and last (clara.system::starts-with "parker: " last))
        (subseq last 8)
        last)))

;; FUNCTION is called, with WORDS in the status row while it is at work:
;; fetching takes its time. What it said last is in the status row
;; afterwards, and so is what went wrong in it: a network that is not there,
;; a file that is not what the index said.
(defun attempt (view words function)
  (when words
    (setf (view-message view) words)
    (render view))
  (setf (view-message view)
        (handler-case (last-said (with-output-to-string (*standard-output*) (funcall function)))
          (error (condition)
            (format nil "~A" condition)))))

;; The sources are asked what they have, and the list is made again.
(defun ask-sources (view)
  (let ((pick (picked-name view)))
    (attempt view
             (cond ((null *sources*) nil)
                   ((cdr *sources*) (format nil "asking ~D sources what they have" (length *sources*)))
                   (t (format nil "asking ~A what it has" (if (consp (car *sources*)) (car (car *sources*)) (car *sources*)))))
             (lambda ()
               (when (null *sources*)
                 (error "no source is named, so only what is installed is listed: CLARA.PARKER:*SOURCES*"))
               (setf (view-offers view) (clara:with-lock-held (*lock*) (offered)))))
    (relist view pick)))

;; The package that is picked: one that is not installed is, and one that a
;; source has a newer version of is replaced by that.
(defun act (view)
  (let* ((row (nth (view-picked view) (view-lines view))) (name (and row (row-name row))))
    (cond ((null row))
          ((null (row-here row))
           (attempt view (format nil "installing ~A ~A" name (row-offered row)) (lambda () (install name)))
           (relist view name))
          ((and (row-offered row) (clara.system::newer-p (row-offered row) (row-here row)))
           (attempt view (format nil "replacing ~A ~A by ~A" name (row-here row) (row-offered row)) (lambda () (update name)))
           (relist view name))
          (t
           (setf (view-message view) (format nil "~A ~A is installed: Delete takes it out" name (row-here row)))))))

;; The package that is picked is the one of that number, or the nearest
;; there is.
(defun pick (view number)
  (setf (view-picked view) (max 0 (min number (1- (length (view-lines view)))))))

;; The character with this code was typed in the window, or the key with it.
(defun key (view code)
  (let ((doomed (view-doomed view)) (picked (view-picked view)))
    (setf (view-message view) nil
          (view-doomed view) nil)
    (cond (doomed
           (when (or (= code 121) (= code 89)) ; y, or Y
             (attempt view (format nil "taking ~A out" doomed) (lambda () (uninstall doomed)))
             (relist view)
             (pick view picked)))
          ((= code clara.input:+up+) (pick view (1- picked)))
          ((= code clara.input:+down+) (pick view (1+ picked)))
          ((= code clara.input:+page-up+) (pick view (- picked (1- (view-rows view)))))
          ((= code clara.input:+page-down+) (pick view (+ picked (1- (view-rows view)))))
          ((= code clara.input:+home+) (pick view 0))
          ((= code clara.input:+end+) (pick view (length (view-lines view))))
          ((or (= code 10) (= code 13)) (act view))
          ((= code 127)                 ; Delete
           (let ((row (nth picked (view-lines view))))
             (cond ((null row))
                   ((row-here row)
                    (setf (view-doomed view) (row-name row)))
                   (t
                    (setf (view-message view) (format nil "~A is not installed" (row-name row)))))))
          ((= code 18)                  ; Ctrl-R
           (ask-sources view))
          ((= code 17)                  ; Ctrl-Q
           (setf (view-done view) t)))))

;; A button of the pointer went down or up in the window: the left one,
;; down on a package, picks it, and on the one that is picked does what
;; Enter does.
(defun point (view y buttons)
  (let* ((row (1- (floor y (view-high view)))) (number (+ (view-top view) row)))
    (when (and (= 1 (logand buttons 1)) (<= 0 row) (< row (view-rows view)) (< number (length (view-lines view))))
      (setf (view-message view) nil
            (view-doomed view) nil)
      (if (= number (view-picked view))
          (act view)
          (pick view number)))))

(defun happened (view event)
  (case (car event)
    (:key (key view (cadr event)))
    (:pointer (point view (caddr event) (cadddr event)))
    (:close (setf (view-done view) t))))

;; Parker in a window of its own, which lists what is installed. COLUMNS
;; and ROWS are the size of the list, in cells; X and Y are where the
;; window goes; and FONT is what the list is written in, one of
;; CLARA.TYPE:FONT's or NIL for the console's letters, which is the one that
;; CLARA.WINDOWS:*TEXT-FONT* says when Parker is told nothing. The window is
;; the thread's that calls.
(defun open-view (&key (columns 80) (rows 12) x y (font (clara.windows:text-font)))
  (let* ((wide (clara.draw:cell-width font))
         (high (clara.draw:cell-height font))
         (window (clara.windows:open-window "Parker" (* columns wide) (* (+ rows 2) high) :x x :y y :events t))
         (view (make-view :window window :surface (clara.windows:window-surface window)
                          :font font :wide wide :high high :columns columns :rows rows
                          :ink (clara.draw:color 232 227 244) :paper (clara.draw:color 30 27 46)
                          :shown (make-array (+ rows 2) :initial-element nil))))
    (relist view)
    view))

;; The sources are asked once, as the window opens, which the status row
;; says while it is done, and with no source named it says that; then what
;; happens to the window is done to the list, and the window shows what
;; came of it, until it is to close.
(defun run (view)
  (render view)
  (ask-sources view)
  (loop
    (render view)
    (when (view-done view)
      (return))
    (happened view (clara.windows:next-event (view-window view)))
    ;; And whatever else has happened by now, before anything is drawn.
    (loop
      (let ((event (clara.windows:next-event (view-window view) 0)))
        (unless event
          (return))
        (happened view event)))))

;; The application: what is installed and what the sources have, listed
;; until the window closes. Whoever calls is Parker for as long: the
;; launcher starts a thread for that.
(defun parker (&rest options)
  (let ((view (apply #'open-view options)))
    (unwind-protect (run view)
      (clara.windows:close-window (view-window view)))
    nil))

(clara.windows:define-application "Parker" #'parker)
