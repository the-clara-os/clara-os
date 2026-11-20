;;;; disk.lisp: disks
;;;;
;;;; The driver for virtio's block devices (Virtual I/O Device
;;;; specification 1.2, 5.2, on top of lisp/virtio.lisp). To its driver a
;;;; disk is a row of sectors of 512 bytes each, numbered from 0, and
;;;; nothing more: what the sectors mean is for whoever reads them
;;;; (lisp/fat.lisp).
;;;;
;;;; A request goes to the device through its one queue, as a chain of
;;;; three buffers: 16 bytes that say what to do, read or write, and from
;;;; which sector on; the memory that the sectors are read into or written
;;;; from; and one byte in which the device says how it went. The device
;;;; raises its interrupt when it is done. One request is under way at a
;;;; time, and the thread that made it waits for it with the disk's lock in
;;;; its hands.
;;;;
;;;; The memory of a request is page frames (CLARA.UNSAFE:ALLOCATE-MEMORY):
;;;; the device reads and writes memory by its physical address, which is
;;;; the address of a page frame and not of an object in the heap.
;;;;
;;;; A write that the device has answered may still be in the memory of
;;;; whatever the device is made of, a host's for one. FLUSH asks the device
;;;; to put what it holds where it lasts, which is what a machine does
;;;; before it is turned off (lisp/system.lisp).

(defpackage "CLARA.DISK"
  (:use "COMMON-LISP")
  (:export "START" "DISKS" "DISK-P" "DISK-NAME" "DISK-SECTORS" "DISK-READ-ONLY"
           "READ-SECTORS" "WRITE-SECTORS" "FLUSH" "*PATIENCE*"))
(in-package "CLARA.DISK")

(defstruct disk
  device queue
  name        ; where it is on the PCI bus, which is all the name it has
  sectors     ; how many sectors it has
  read-only   ; it cannot be written
  flushes     ; it holds writes back until it is told to put them where they last
  lock        ; for the one request that is under way
  request     ; a page frame for what a request says, and for the device's answer to it
  failed)     ; a request went unanswered: nothing more is asked of this disk

(defvar *disks* nil)       ; the disks that START found and opened
(defvar *patience* 10000)  ; how many milliseconds a disk may take over a request

(defun disks ()
  *disks*)

;; One request (5.2.6): TYPE is 0 to read and 1 to write the sectors from
;; SECTOR on that DATA has the memory of, a buffer as the queue takes them,
;; and 4 to put what the device holds back where it lasts, which has no
;; sectors and no memory to it. What a request says is its type, in 32
;; bits, 32 bits of nothing, and the sector, in 64. The device's answer is
;; what this gives: 0 when all went well, 1 when it could not do it, and 2
;; when it does not know the request. A wait ends every tenth of a second
;; to look at the queue, so an interrupt that got lost costs that much and
;; no more. A disk that a variable has kept from an earlier start, in a
;; world that was saved, is not asked: its queue and its page frame are
;; somebody else's memory by now.
(defun ask (disk type sector data)
  (clara:with-lock-held ((disk-lock disk))
    (unless (member disk *disks*)
      (error "the disk ~A is from an earlier start; (clara.disk:disks) has this start's" (disk-name disk)))
    (when (disk-failed disk)
      (error "the disk ~A left a request unanswered, and is asked nothing more" (disk-name disk)))
    (let ((frame (disk-request disk))
          (queue (disk-queue disk))
          (event (clara.virtio:device-event (disk-device disk)))
          (waited 0))
      (setf (clara.unsafe:memory-32 frame) type
            (clara.unsafe:memory-32 (+ frame 4)) 0
            (clara.unsafe:memory-64 (+ frame 8)) sector
            (clara.unsafe:memory-8 (+ frame 16)) 255) ; which no device answers
      (clara.virtio:queue-add queue
                              (append (list (list frame 16 nil)) data (list (list (+ frame 16) 1 t)))
                              disk)
      (clara.virtio:queue-notify queue)
      (loop
        (when (clara.virtio:queue-take queue)
          (return))
        (unless (clara:wait-event event 100)
          (setq waited (+ waited 100))
          (when (>= waited *patience*)
            (setf (disk-failed disk) t)
            (error "the disk ~A has not answered a request in ~D milliseconds" (disk-name disk) waited))))
      (clara.unsafe:memory-8 (+ frame 16)))))

;; COUNT sectors from SECTOR on, read into the memory at ADDRESS or written
;; from it.
(defun request (disk type sector count address)
  (unless (and (integerp sector) (integerp count) (<= 0 sector) (< 0 count)
               (<= (+ sector count) (disk-sectors disk)))
    (error "the disk ~A has the sectors 0 to ~D, and not ~S of them from ~S on"
           (disk-name disk) (1- (disk-sectors disk)) count sector))
  (when (and (= type 1) (disk-read-only disk))
    (error "the disk ~A cannot be written" (disk-name disk)))
  (let ((answer (ask disk type sector (list (list address (* 512 count) (= type 0))))))
    (case answer
      (0 count)
      (1 (error "the disk ~A could not ~A its sectors ~D to ~D"
                (disk-name disk) (if (= type 0) "read" "write") sector (+ sector count -1)))
      (t (error "the disk ~A does not know how to ~A: its answer is ~D"
                (disk-name disk) (if (= type 0) "read" "write") answer)))))

;; COUNT sectors from SECTOR on, read into the memory at ADDRESS, which is
;; page frames with room for them. COUNT is returned.
(defun read-sectors (disk sector count address)
  (request disk 0 sector count address))

;; The same sectors, written from that memory. A write that is answered is
;; the device's to keep, and FLUSH is what makes it last.
(defun write-sectors (disk sector count address)
  (request disk 1 sector count address))

;; What was written to the disk is where it lasts: T when the device was
;; asked and has answered, and NIL for a disk that holds nothing back, or
;; cannot be written at all.
(defun flush (disk)
  (when (and (disk-flushes disk) (not (disk-read-only disk)))
    (let ((answer (ask disk 4 0 nil)))
      (unless (= answer 0)
        (error "the disk ~A could not put what it holds where it lasts: its answer is ~D" (disk-name disk) answer))
      t)))

;; Open a virtio block device. Of what such a device can do, the driver
;; asks for bit 5, by which the device says that it cannot be written, and
;; for bit 9, by which it says that it knows the request to flush. Its
;; own registers begin with how many sectors it has, in 64 bits (5.2.4);
;; a sector is 512 bytes there whatever the device is made of. Three
;; buffers make a request, so the queue need not be long.
(defun open-disk (pci)
  (let* ((device (clara.virtio:open-device pci (+ 32 512)))
         (queue (clara.virtio:open-queue device 0 8))
         (disk (make-disk :device device :queue queue
                          :name (clara.pci:location pci)
                          :sectors (+ (clara.virtio:register-32 device 0)
                                      (ash (clara.virtio:register-32 device 4) 32))
                          :read-only (/= 0 (logand (clara.virtio:device-features device) 32))
                          :flushes (/= 0 (logand (clara.virtio:device-features device) 512))
                          :lock (clara:make-lock "disk")
                          :request (clara.unsafe:allocate-memory 1))))
    (when (< (clara.virtio:queue-size queue) 3)
      (error "the virtio device at ~A has a queue of ~D buffers, and a request takes three"
             (disk-name disk) (clara.virtio:queue-size queue)))
    (clara.virtio:start-device device)
    disk))

;; Find the disks among the PCI devices, and say what each is. One that
;; does not start is said, and left alone.
(defun start ()
  (setq *disks* nil)
  (dolist (pci (clara.pci:devices))
    (when (eql (clara.virtio:device-type pci) 2)
      (handler-case
          (let ((disk (open-disk pci)))
            (setq *disks* (append *disks* (list disk)))
            (format t "disk: ~A has ~D sectors of 512 bytes, ~D MiB~A~%"
                    (disk-name disk) (disk-sectors disk) (floor (disk-sectors disk) 2048)
                    (if (disk-read-only disk) ", and cannot be written" "")))
        (error (condition)
          (format t "disk: ~A did not start: ~A~%" (clara.pci:location pci) condition)))))
  (when (null *disks*)
    (format t "disk: no disk that has a driver here: the files are the ones that were read as the machine started~%"))
  *disks*)
