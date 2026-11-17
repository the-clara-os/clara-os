;;;; fat.lisp: files
;;;;
;;;; The FAT file system, as far as reading it goes: the one the firmware
;;;; boots from, so the volume this kernel came from is the first whose
;;;; files it can see. The numbers are those of Microsoft's "FAT: General
;;;; Overview of On-Disk Format" (version 1.03, 2000), and for the tables
;;;; of partitions those of the UEFI specification 2.10, chapter 5.
;;;;
;;;; A disk is cut into partitions, by a table in its first sector or by
;;;; one of the newer kind behind it, or it is one volume from end to end.
;;;; A volume begins with a sector that says how it is laid out: some
;;;; sectors that are kept back, then the table that gives the file system
;;;; its name, then the directory of the root on the older kinds, then the
;;;; clusters, which are runs of sectors and what files are made of.
;;;;
;;;; The table has an entry for every cluster, of 12, 16 or 32 bits, by how
;;;; many clusters there are: the number of the cluster that comes after
;;;; this one in its file, or a mark that it is the last. A directory is a
;;;; file of entries of 32 bytes. An entry holds a name of eight characters
;;;; and three, in capitals, the size of a file and its first cluster. A
;;;; name that does not fit that is spelt out, 13 characters of UTF-16 at a
;;;; time, in the entries before, the last part first.
;;;;
;;;; Here a file is found by its name, a string: the names of the
;;;; directories that lead to it from the root and then its own, with a
;;;; slash before each, as in "/clara/boot.lisp". The case of a letter
;;;; makes no difference. START finds the volumes on the disks and tells
;;;; the language where its files are from then on (CLARA:PROVIDE-FILES),
;;;; which is what OPEN, LOAD, PROBE-FILE and DIRECTORY go by. Nothing here
;;;; writes to a disk.

(defpackage "CLARA.FAT"
  (:use "COMMON-LISP")
  (:export "START" "VOLUMES" "*VOLUME*" "VOLUME-P" "VOLUME-DISK" "VOLUME-KIND" "VOLUME-FIRST"
           "ENTRIES" "ENTRY-P" "ENTRY-NAME" "ENTRY-SHORT" "ENTRY-DIRECTORY-P" "ENTRY-SIZE"
           "NAMES" "FILE-TEXT" "READ-FILE"))
(in-package "CLARA.FAT")

(defstruct volume
  disk
  first            ; the sector of the disk that the volume begins at
  kind             ; how many bits an entry of its table has: 12, 16 or 32
  cluster-sectors  ; how many sectors a cluster is
  table            ; the sector of the disk that the table begins at
  root             ; where the directory of the root begins, and how many sectors it is:
  root-sectors     ;   on the kinds 12 and 16 it is no file, and lies before the clusters
  root-cluster     ; on the kind 32 it is a file like any other, and this is its first cluster
  data             ; the sector of the disk at which cluster 2 begins: there is no cluster 0 or 1
  clusters         ; how many clusters there are
  lock             ; for the page frame below, which every look at the table goes through
  cache            ; a page frame with eight sectors of the table in it,
  cached)          ;   from this sector of the table on, or NIL

(defstruct entry
  name             ; its name: the long one, when it has one
  short            ; its name of eight characters and three
  directory-p
  size             ; of a file, in bytes
  cluster)         ; its first cluster, or 0 when it has none

(defvar *volumes* nil) ; the volumes that START found, in the order of their disks
(defvar *volume* nil)  ; the one that names are looked up on

(defun volumes ()
  *volumes*)

;;; Bytes on a disk

;; A number of SIZE bytes at an address, the lowest first. What a disk
;; holds is not always at a multiple of its size, so it is put together
;; from its bytes.
(defun le (address size)
  (let ((value 0))
    (dotimes (i size value)
      (setq value (+ value (ash (clara.unsafe:memory-8 (+ address i)) (* 8 i)))))))

(defun page-frames (bytes)
  (max 1 (floor (+ bytes 4095) 4096)))

;; FUNCTION, called with the address of COUNT sectors of a disk, read from
;; SECTOR on into memory that is given back afterwards.
(defun call-with-sectors (disk sector count function)
  (let* ((pages (page-frames (* 512 count)))
         (memory (clara.unsafe:allocate-memory pages)))
    (unwind-protect
         (progn
           (clara.disk:read-sectors disk sector count memory)
           (funcall function memory))
      (clara.unsafe:free-memory memory pages))))

(defmacro with-sectors ((memory disk sector count) &body body)
  `(call-with-sectors ,disk ,sector ,count (lambda (,memory) ,@body)))

;;; Volumes

;; The volume that begins at a sector of a disk, when what is there is the
;; first sector of a FAT volume, and NIL when it is not. By its offsets:
;;   11 how many bytes a sector has   13 how many sectors a cluster
;;   14 how many sectors are kept back before the table
;;   16 how many copies of the table there are
;;   17 how many entries the directory of the root has, on the kinds 12 and 16
;;   19 how many sectors the volume has, or 0 and then at 32, in 32 bits
;;   21 what the volume is on, #xf0 and above
;;   22 how many sectors one table has, or 0 and then at 36, in 32 bits
;;   40 on the kind 32: bit 7 says that one table only is kept, the one in the bits 0 to 3
;;   44 on the kind 32: the first cluster of the directory of the root
;;  510 #x55 and #xaa
;; Which kind it is follows from how many clusters there are, and from
;; nothing else (page 14 of the overview).
(defun open-volume (disk first)
  (with-sectors (boot disk first 1)
    (let* ((cluster-sectors (clara.unsafe:memory-8 (+ boot 13)))
           (reserved (le (+ boot 14) 2))
           (tables (clara.unsafe:memory-8 (+ boot 16)))
           (root-entries (le (+ boot 17) 2))
           (sectors (if (zerop (le (+ boot 19) 2)) (le (+ boot 32) 4) (le (+ boot 19) 2)))
           (table-sectors (if (zerop (le (+ boot 22) 2)) (le (+ boot 36) 4) (le (+ boot 22) 2)))
           (root-sectors (floor (+ (* 32 root-entries) 511) 512))
           (data (+ reserved (* tables table-sectors) root-sectors)))
      (when (and (= (le (+ boot 510) 2) #xaa55)
                 (= (le (+ boot 11) 2) 512)
                 (member cluster-sectors '(1 2 4 8 16 32 64 128))
                 (> reserved 0)
                 (> tables 0)
                 (> table-sectors 0)
                 (>= (clara.unsafe:memory-8 (+ boot 21)) #xf0)
                 (> sectors data)
                 (<= (+ first sectors) (clara.disk:disk-sectors disk)))
        (let* ((clusters (floor (- sectors data) cluster-sectors))
               (kind (cond ((< clusters 4085) 12)
                           ((< clusters 65525) 16)
                           (t 32)))
               (flags (if (= kind 32) (le (+ boot 40) 2) 0)))
          (when (or (= kind 32) (> root-sectors 0))
            (make-volume :disk disk :first first :kind kind :cluster-sectors cluster-sectors
                         :table (+ first reserved
                                   (if (zerop (logand flags 128)) 0 (* (logand flags 15) table-sectors)))
                         :root (+ first reserved (* tables table-sectors))
                         :root-sectors root-sectors
                         :root-cluster (if (= kind 32) (le (+ boot 44) 4) 0)
                         :data (+ first data)
                         :clusters clusters
                         :lock (clara:make-lock "volume")
                         :cache (clara.unsafe:allocate-memory 1))))))))

;; The partitions in a GUID partition table: the sectors they begin at.
;; The table's header is the second sector of the disk: "EFI PART", at 72
;; the sector where the entries begin, at 80 how many there are, and at 84
;; how many bytes each is. An entry is 16 bytes that say what kind of
;; partition it is, all zeroes when it is none, and at 32 its first sector.
(defun guid-partitions (disk)
  (multiple-value-bind (table count size)
      (with-sectors (header disk 1 1)
        (if (and (= (le header 4) #x20494645) (= (le (+ header 4) 4) #x54524150))
            (values (le (+ header 72) 8) (le (+ header 80) 4) (le (+ header 84) 4))
            (values nil 0 0)))
    (when (and table (<= 1 count 1024) (<= 128 size 4096) (zerop (mod size 8)))
      (with-sectors (entries disk table (floor (+ (* count size) 511) 512))
        (let ((found nil))
          (dotimes (i count (reverse found))
            (let ((entry (+ entries (* i size))))
              (unless (and (zerop (clara.unsafe:memory-32 entry))
                           (zerop (clara.unsafe:memory-32 (+ entry 4)))
                           (zerop (clara.unsafe:memory-32 (+ entry 8)))
                           (zerop (clara.unsafe:memory-32 (+ entry 12))))
                (setq found (cons (le (+ entry 32) 8) found))))))))))

;; The sectors of a disk at which a partition begins. The table of old is
;; in the first sector, which ends in #x55 and #xaa: four entries of 16
;; bytes from 446 on, each with the kind of the partition at 4, which is 0
;; for none, its first sector at 8 and how many it has at 12. A partition
;; of the kind #xee stands for the whole disk and says that the table to go
;; by is the newer one.
(defun partitions (disk)
  (let ((found nil) (newer nil))
    (with-sectors (sector disk 0 1)
      (when (= (le (+ sector 510) 2) #xaa55)
        (dotimes (i 4)
          (let* ((entry (+ sector 446 (* 16 i)))
                 (kind (clara.unsafe:memory-8 (+ entry 4))))
            (cond ((= kind #xee) (setq newer t))
                  ((and (/= kind 0) (> (le (+ entry 12) 4) 0))
                   (setq found (cons (le (+ entry 8) 4) found))))))))
    (if newer
        (guid-partitions disk)
        (reverse found))))

;; The volumes of a disk: the disk itself when it is one from its first
;; sector on, and otherwise the partitions that are one.
(defun disk-volumes (disk)
  (let ((whole (open-volume disk 0)))
    (if whole
        (list whole)
        (let ((found nil))
          (dolist (first (partitions disk))
            (let ((volume (and (< 0 first (clara.disk:disk-sectors disk)) (open-volume disk first))))
              (when volume
                (setq found (cons volume found)))))
          (reverse found)))))

;;; The table

;; The address in memory of the byte of the table at an offset, with the
;; rest of its sector and all of the next behind it: an entry of 12 bits
;; can lie across the end of a sector.
(defun table-address (volume offset)
  (let ((sector (floor offset 512)) (cached (volume-cached volume)))
    (unless (and cached (<= cached sector) (< (1+ sector) (+ cached 8)))
      (let ((first (+ (volume-table volume) sector)))
        (setf (volume-cached volume) nil)
        (clara.disk:read-sectors (volume-disk volume) first
                                 (min 8 (- (clara.disk:disk-sectors (volume-disk volume)) first))
                                 (volume-cache volume))
        (setf (volume-cached volume) sector)))
    (+ (volume-cache volume) (- offset (* 512 (volume-cached volume))))))

(defun cluster-p (volume cluster)
  (and (>= cluster 2) (< cluster (+ 2 (volume-clusters volume)))))

;; The cluster that comes after a cluster in its file, or NIL when it is
;; the last. Two entries of 12 bits share three bytes: the one with the
;; even number has the lower 12 bits of the 16 at its place, the odd one
;; the upper. Of an entry of 32 bits the upper four mean nothing. The
;; highest eight numbers of each kind mark the last cluster of a file.
(defun next-cluster (volume cluster)
  (let* ((kind (volume-kind volume))
         (next (case kind
                 (12 (let ((pair (le (table-address volume (+ cluster (floor cluster 2))) 2)))
                       (if (oddp cluster) (ash pair -4) (logand pair #xfff))))
                 (16 (clara.unsafe:memory-16 (table-address volume (* 2 cluster))))
                 (t (logand (clara.unsafe:memory-32 (table-address volume (* 4 cluster))) #xfffffff)))))
    (cond ((>= next (case kind (12 #xff8) (16 #xfff8) (t #xffffff8))) nil)
          ((cluster-p volume next) next)
          (t (error "the table of the volume has ~D after the cluster ~D, and there is no such cluster"
                    next cluster)))))

;; The clusters of a file from its first on, in order: all of them, or the
;; first MOST.
(defun chain (volume first most)
  (let ((clusters nil) (cluster first) (count 0))
    (unless (cluster-p volume first)
      (error "a file begins in the cluster ~D, and the volume has no such cluster" first))
    (loop
      (setq clusters (cons cluster clusters)
            count (1+ count))
      (when (= count most)
        (return))
      (setq cluster (next-cluster volume cluster))
      (unless cluster
        (return)))
    (reverse clusters)))

;; The first SECTORS sectors of a chain of clusters, read into the memory
;; at ADDRESS. Clusters that lie side by side on the disk are read with
;; one request, up to a mebibyte at a time.
(defun read-clusters (volume clusters sectors address)
  (let ((each (volume-cluster-sectors volume)))
    (loop
      (when (or (null clusters) (<= sectors 0))
        (return))
      (let ((first (car clusters)) (run 1))
        (setq clusters (cdr clusters))
        (loop
          (unless (and clusters (= (car clusters) (+ first run)) (<= (* (1+ run) each) 2048))
            (return))
          (setq run (1+ run)
                clusters (cdr clusters)))
        (let ((count (min sectors (* run each))))
          (clara.disk:read-sectors (volume-disk volume)
                                   (+ (volume-data volume) (* (- first 2) each))
                                   count address)
          (setq sectors (- sectors count)
                address (+ address (* 512 count))))))))

;;; Directories

;; The 13 characters that one entry holds of a long name, as far as the
;; name goes: a zero ends it.
(defvar *name-places* '(1 3 5 7 9 14 16 18 20 22 24 28 30))

(defun name-part (at)
  (let ((units nil))
    (dolist (place *name-places*)
      (let ((unit (le (+ at place) 2)))
        (when (zerop unit)
          (return))
        (setq units (cons unit units))))
    (reverse units)))

;; A long name, from its characters in UTF-16: two halves of a pair make
;; one character, and half a pair makes a question mark.
(defun long-name (units)
  (let ((parts nil))
    (loop
      (when (null units)
        (return))
      (let ((unit (car units)))
        (setq units (cdr units))
        (cond ((and (<= #xd800 unit #xdbff) units (<= #xdc00 (car units) #xdfff))
               (setq parts (cons (string (code-char (+ #x10000 (ash (- unit #xd800) 10) (- (car units) #xdc00))))
                                 parts)
                     units (cdr units)))
              ((<= #xd800 unit #xdfff)
               (setq parts (cons "?" parts)))
              (t
               (setq parts (cons (string (code-char unit)) parts))))))
    (apply #'concatenate 'string (reverse parts))))

;; One of the two parts of a short name, without the spaces that fill it
;; up. It is in capitals, and LOWER says that it is meant in small letters.
;; What is not ASCII is in an alphabet that the entry does not name, and
;; becomes a question mark.
(defun short-part (at length lower)
  (let ((text ""))
    (loop
      (unless (and (> length 0) (= (clara.unsafe:memory-8 (+ at length -1)) 32))
        (return))
      (setq length (1- length)))
    (dotimes (i length text)
      (let ((code (clara.unsafe:memory-8 (+ at i))))
        (setq text (concatenate 'string text
                                (string (code-char (cond ((> code 126) 63)
                                                         ((and lower (<= 65 code 90)) (+ code 32))
                                                         (t code))))))))))

;; The short name of an entry: eight characters, and three more after a
;; dot when there are any. Bits 3 and 4 of the byte at 12 say which of the
;; two parts is meant in small letters.
(defun short-name (at)
  (let* ((small (clara.unsafe:memory-8 (+ at 12)))
         (name (short-part at 8 (/= 0 (logand small 8))))
         (extension (short-part (+ at 8) 3 (/= 0 (logand small 16)))))
    (if (zerop (length extension))
        name
        (concatenate 'string name "." extension))))

;; What the entries of a long name carry of the short name that they
;; belong to: its 11 bytes, each added to the sum so far turned right by
;; one bit.
(defun checksum (at)
  (let ((sum 0))
    (dotimes (i 11 sum)
      (setq sum (logand (+ (ash (logand sum 1) 7) (ash sum -1) (clara.unsafe:memory-8 (+ at i))) 255)))))

;; The entries in the BYTES bytes of a directory at MEMORY. An entry of 32
;; bytes, by its offsets: 0 the short name, 11 bytes; 11 what it is, of
;; which bit 3 is the name of the volume and bit 4 a directory, and the
;; bits 0 to 3 together a part of a long name; 20 and 26 the two halves of
;; its first cluster, the upper one on the kind 32 only; 28 its size. A
;; first byte of 0 ends the directory, and #xe5 is an entry that was
;; deleted. A part of a long name has its place in the name in its first
;; byte, counted from 1, with bit 6 set in the last part, which comes
;; first; at 13 the checksum; and the characters. A long name that is not
;; whole, or was made for another short name, is left out, and the entry
;; goes by its short name. The entries "." and "..", which a directory has
;; for itself and for the one it is in, are left out.
(defun parse-directory (volume memory bytes)
  (let ((entries nil) (long nil) (sum nil) (next nil))
    (do ((at memory (+ at 32)))
        ((>= at (+ memory bytes)))
      (let ((first (clara.unsafe:memory-8 at))
            (what (clara.unsafe:memory-8 (+ at 11))))
        (cond ((= first 0)
               (return))
              ((= first #xe5)
               (setq long nil next nil))
              ((= (logand what #x3f) #x0f)
               (let ((place (logand first #x3f)) (check (clara.unsafe:memory-8 (+ at 13))))
                 (cond ((and (/= 0 (logand first #x40)) (> place 0))
                        (setq long (name-part at) sum check next (1- place)))
                       ((and next (> place 0) (= place next) (= check sum))
                        (setq long (append (name-part at) long) next (1- place)))
                       (t
                        (setq long nil next nil)))))
              ((/= 0 (logand what 8))
               (setq long nil next nil))
              (t
               (let ((short (short-name at)))
                 (unless (or (string= short ".") (string= short ".."))
                   (setq entries
                         (cons (make-entry :name (if (and long (eql next 0) (= sum (checksum at)))
                                                     (long-name long)
                                                     short)
                                           :short short
                                           :directory-p (/= 0 (logand what 16))
                                           :size (le (+ at 28) 4)
                                           :cluster (+ (clara.unsafe:memory-16 (+ at 26))
                                                       (if (= (volume-kind volume) 32)
                                                           (ash (clara.unsafe:memory-16 (+ at 20)) 16)
                                                           0)))
                               entries))))
               (setq long nil next nil)))))
    (reverse entries)))

;; The entries of the directory that begins in a cluster, or of the root
;; for the cluster 0, in the order they have on the disk. A directory is
;; 65536 entries at most, which is two mebibytes.
(defun read-directory (volume cluster)
  (if (and (= cluster 0) (/= (volume-kind volume) 32))
      (with-sectors (memory (volume-disk volume) (volume-root volume) (volume-root-sectors volume))
        (parse-directory volume memory (* 512 (volume-root-sectors volume))))
      (let* ((each (volume-cluster-sectors volume))
             (most (1+ (floor 4096 each)))
             (clusters (chain volume (if (= cluster 0) (volume-root-cluster volume) cluster) most))
             (sectors (* each (length clusters)))
             (pages (page-frames (* 512 sectors)))
             (memory (clara.unsafe:allocate-memory pages)))
        (unwind-protect
             (progn
               (when (= (length clusters) most)
                 (error "a directory is longer than a directory can be: the table of the volume leads round in a ring"))
               (read-clusters volume clusters sectors memory)
               (parse-directory volume memory (* 512 sectors)))
          (clara.unsafe:free-memory memory pages)))))

;;; Names

;; The parts of a name that its slashes keep apart.
(defun name-parts (name)
  (let ((parts nil) (start 0))
    (unless (stringp name)
      (error "the name of a file is a string, and ~S is not one" name))
    (dotimes (i (1+ (length name)))
      (when (or (= i (length name)) (char= (char name i) #\/))
        (when (> i start)
          (setq parts (cons (subseq name start i) parts)))
        (setq start (1+ i))))
    (reverse parts)))

;; The entry of a name, found by way of its directories from the root on,
;; or NIL when there is none. A name fits an entry when it is its long
;; name or its short one, in letters of either case. The root has no entry
;; on the disk, and gets one here.
(defun find-entry (volume name)
  (let ((entry (make-entry :name "" :short "" :directory-p t :size 0 :cluster 0)))
    (dolist (part (name-parts name) entry)
      (unless (entry-directory-p entry)
        (return nil))
      (setq entry (find-if (lambda (other)
                             (or (string-equal part (entry-name other)) (string-equal part (entry-short other))))
                           (read-directory volume (entry-cluster entry))))
      (unless entry
        (return nil)))))

(defun the-volume ()
  (or *volume*
      (error "there are no files: no disk has a volume that is known here")))

(defun sorted (entries)
  (sort entries #'string-lessp :key #'entry-name))

;; What the directory of a name holds: its entries, in the order of their
;; names.
(defun entries (name)
  (let ((volume (the-volume)))
    (clara:with-lock-held ((volume-lock volume))
      (let ((directory (find-entry volume name)))
        (unless (and directory (entry-directory-p directory))
          (error "there is no directory ~A" name))
        (sorted (read-directory volume (entry-cluster directory)))))))

;; The same as names, a directory's with a slash at its end; NIL when
;; there is no such directory.
(defun names (name)
  (let ((volume *volume*))
    (when volume
      (clara:with-lock-held ((volume-lock volume))
        (let ((directory (find-entry volume name)))
          (when (and directory (entry-directory-p directory))
            (mapcar (lambda (entry)
                      (if (entry-directory-p entry)
                          (concatenate 'string (entry-name entry) "/")
                          (entry-name entry)))
                    (sorted (read-directory volume (entry-cluster directory))))))))))

;;; Files

;; What a file holds: the address of the page frames it was read into, how
;; many bytes of them are the file, and how many page frames there are,
;; for whoever gives them back (CLARA.UNSAFE:FREE-MEMORY).
(defun read-file (name)
  (let ((volume (the-volume)))
    (clara:with-lock-held ((volume-lock volume))
      (let ((entry (find-entry volume name)))
        (cond ((null entry)
               (error "there is no file ~A" name))
              ((entry-directory-p entry)
               (error "~A is a directory, and not a file" name)))
        (let* ((size (entry-size entry))
               (each (* 512 (volume-cluster-sectors volume)))
               (pages (page-frames size))
               (memory (clara.unsafe:allocate-memory pages))
               (read nil))
          (unwind-protect
               (progn
                 (when (> size 0)
                   (let* ((needed (floor (+ size each -1) each))
                          (clusters (chain volume (entry-cluster entry) needed)))
                     (when (< (length clusters) needed)
                       (error "the file ~A is ~D bytes by its directory, and the table of the volume has fewer for it"
                              name size))
                     (read-clusters volume clusters (floor (+ size 511) 512) memory)))
                 (setq read t))
            (unless read
              (clara.unsafe:free-memory memory pages)))
          (values memory size pages))))))

;; A file as text: a string of what it holds, which has to be UTF-8.
(defun file-text (name)
  (multiple-value-bind (memory size pages) (read-file name)
    (unwind-protect
         (handler-case (clara.unsafe:memory-string memory size)
           (error ()
             (error "the file ~A is not text: what it holds is not UTF-8" name)))
      (clara.unsafe:free-memory memory pages))))

;;; Starting

(defun size (sectors)
  (if (< sectors 2048)
      (format nil "~D KiB" (floor sectors 2))
      (format nil "~D MiB" (floor sectors 2048))))

;; Find the volumes on the disks, and say what was found. Names are looked
;; up on the first of them, and from here on the language's files are that
;; volume's.
(defun start ()
  (setq *volumes* nil
        *volume* nil)
  (dolist (disk (clara.disk:disks))
    (handler-case
        (let ((volumes (disk-volumes disk)))
          (dolist (volume volumes)
            (format t "files: a FAT~D volume of ~A on the disk ~A, from its sector ~D on~%"
                    (volume-kind volume) (size (* (volume-clusters volume) (volume-cluster-sectors volume)))
                    (clara.disk:disk-name disk) (volume-first volume)))
          (when (null volumes)
            (format t "files: the disk ~A has no volume that is known here~%" (clara.disk:disk-name disk)))
          (setq *volumes* (append *volumes* volumes)))
      (error (condition)
        (format t "files: the disk ~A could not be looked at: ~A~%" (clara.disk:disk-name disk) condition))))
  (cond (*volumes*
         (setq *volume* (car *volumes*))
         (clara:provide-files :text #'file-text :names #'names)
         (when (cdr *volumes*)
           (format t "files: names are looked up on the first of these volumes~%")))
        (t
         (clara:provide-files)
         (format t "files: no volume, so LOAD finds what was read as the machine started and nothing else~%")))
  *volumes*)
