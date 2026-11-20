;;;; system.lisp: the machine as a whole
;;;;
;;;; Shutting the machine down, and starting it again. Either is something
;;;; that the system does itself when it is asked to: at a prompt, by the
;;;; launcher's list, or by the machine's power button, which is what a
;;;; host presses when it wants a machine to stop. Until this file, a
;;;; machine was stopped from outside, and that was the plug pulled.
;;;;
;;;; What it does, in this order. It asks the windows whether their
;;;; programs hold something that would be lost, a text that is not saved,
;;;; and goes no further while one says so. It saves the world, so that the
;;;; machine starts in it the next time. It stops the window manager, and
;;;; with it the applications. It has every disk put what it was given
;;;; where it lasts. And then the substrate turns the machine off, or
;;;; starts it again (CLARA.UNSAFE:POWER-OFF, RESET). All of it in a thread
;;;; of its own, since the thread that asked may be an application's, and
;;;; stopped on the way.
;;;;
;;;; This file loads under SBCL as well, where lisp/host/ stands in for the
;;;; machine, which there stays on whatever it is told.

(defpackage "CLARA.SYSTEM"
  (:use "COMMON-LISP")
  (:export "START" "SHUT-DOWN" "START-AGAIN"))
(in-package "CLARA.SYSTEM")

(defvar *lock* (clara:make-lock "system"))
(defvar *leaving* nil)  ; the machine is being shut down, :OFF, or started again, :AGAIN
(defvar *watcher* nil)  ; the thread that looks at the power button

;; A line for whoever is watching, on the console: the serial port, and the
;; screen once the window manager has given it back.
(defun say (control &rest arguments)
  (fresh-line)
  (write-line (apply #'format nil control arguments)))

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

;; For the substrate, at every boot. A world that was saved by a shutdown
;; was in the middle of one, and is not any more; and the thread that
;; watched the button was another machine's.
(defun start ()
  (setq *leaving* nil)
  (when (and *watcher* (clara:thread-alive-p *watcher*))
    (clara:destroy-thread *watcher*))
  (setq *watcher* (clara:make-thread #'watch-button :name "power button"))
  nil)

(clara.windows:define-command "Restart" (lambda () (asked :again)))
(clara.windows:define-command "Shut Down" (lambda () (asked :off)))
