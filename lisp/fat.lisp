;;;; fat.lisp: files
;;;;
;;;; The FAT file system: the one the firmware boots from, so the volume
;;;; this kernel came from is the first whose files it can see, and the
;;;; first it can leave a file on for the firmware to find. The numbers
;;;; are those of Microsoft's "FAT: General Overview of On-Disk Format"
;;;; (version 1.03, 2000), and for the tables of partitions those of the
;;;; UEFI specification 2.10, chapter 5.
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
;;;; which is what OPEN, LOAD, PROBE-FILE, DIRECTORY and DELETE-FILE go by.
;;;; A name is looked up on one volume, the first until *VOLUME* is given
;;;; another, unless the name itself says which: the number of a volume
;;;; among the ones that were found, from 1 on, and a colon, before
;;;; everything else, as in "2:/mine.lisp". No name of a file has a colon
;;;; in it, so nothing else begins that way.
;;;;
;;;; A file is written whole: its bytes go into clusters that the table
;;;; has as free, the table then chains those in every copy that the
;;;; volume keeps of it, and last an entry in the file's directory says
;;;; where the file begins and how long it is. In that order, so that a
;;;; machine which stops halfway leaves a volume with clusters that belong
;;;; to nobody, and never an entry that leads to what is not there. A file
;;;; that was there before under the name keeps its entry, and its old
;;;; clusters are free once the entry has the new ones, so a volume needs
;;;; room for both. A world that is saved is the one file that goes first
;;;; when the volume has no room for the one after it as well. There is no clock
;;;; here, so every file is of the first day that the format has a date
;;;; for. A directory is made the same way, its one cluster first, with the
;;;; two entries in it that every directory begins with, and it is taken
;;;; away when nothing is left in it.

(defpackage "CLARA.FAT"
  (:use "COMMON-LISP")
  (:export "START" "VOLUMES" "*VOLUME*" "*IMAGE-VOLUME*" "VOLUME-P" "VOLUME-DISK" "VOLUME-KIND" "VOLUME-FIRST"
           "ENTRIES" "ENTRY-P" "ENTRY-NAME" "ENTRY-SHORT" "ENTRY-DIRECTORY-P" "ENTRY-SIZE"
           "NAMES" "FILE-TEXT" "READ-FILE" "WRITE-FILE" "REMOVE-FILE" "COPY-FILE"
           "MAKE-DIRECTORY" "REMOVE-DIRECTORY" "FREE-BYTES"))
(in-package "CLARA.FAT")

(defstruct volume
  disk
  first            ; the sector of the disk that the volume begins at
  kind             ; how many bits an entry of its table has: 12, 16 or 32
  cluster-sectors  ; how many sectors a cluster is
  table            ; the sector of the disk that the table begins at: the copy of it that is read,
  table-sectors    ;   how many sectors one copy is,
  copies           ;   and where each copy begins that a change has to reach, this one among them
  root             ; where the directory of the root begins, and how many sectors it is:
  root-sectors     ;   on the kinds 12 and 16 it is no file, and lies before the clusters
  root-cluster     ; on the kind 32 it is a file like any other, and this is its first cluster
  data             ; the sector of the disk at which cluster 2 begins: there is no cluster 0 or 1
  clusters         ; how many clusters there are
  information      ; on the kind 32, the sector that says how many clusters are free, or NIL
  lock             ; for the page frame below, which every look at the table goes through
  cache            ; a page frame with eight sectors of the table in it,
  cached           ;   from this sector of the table on, or NIL;
  changed          ;   they have been written to, and the disk has not
  (next 2))        ; the cluster at which the next search for a free one begins

(defstruct entry
  name             ; its name: the long one, when it has one
  short            ; its name of eight characters and three
  directory-p
  size             ; of a file, in bytes
  cluster          ; its first cluster, or 0 when it has none
  at               ; where in its directory the entry is, in bytes from the directory's first,
  first)           ;   and where the first of the entries is that spell its long name out

(defvar *volumes* nil) ; the volumes that START found, in the order of their disks
(defvar *volume* nil)  ; the one that names are looked up on
(defvar *image-volume* nil) ; the one that a world is saved on, which the machine was started from: lisp/system.lisp says which

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
;;   48 on the kind 32: the sector that says how many clusters are free
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
               (flags (if (= kind 32) (le (+ boot 40) 2) 0))
               (information (if (= kind 32) (le (+ boot 48) 2) 0))
               (table (+ first reserved
                         (if (zerop (logand flags 128)) 0 (* (logand flags 15) table-sectors))))
               (copies nil))
          (if (zerop (logand flags 128))
              (dotimes (i tables)
                (setq copies (cons (+ first reserved (* i table-sectors)) copies)))
              (setq copies (list table)))
          (when (or (= kind 32) (> root-sectors 0))
            (make-volume :disk disk :first first :kind kind :cluster-sectors cluster-sectors
                         :table table
                         :table-sectors table-sectors
                         :copies (reverse copies)
                         :information (if (< 0 information reserved) (+ first information) nil)
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

;; What is held of the table goes to the disk if it has been written to:
;; to every copy that the volume keeps. Only sectors of the table go: the
;; eight that are held can reach past its end, into what comes after it.
(defun flush-table (volume)
  (when (volume-changed volume)
    (let ((cached (volume-cached volume)))
      (dolist (copy (volume-copies volume))
        (clara.disk:write-sectors (volume-disk volume) (+ copy cached)
                                  (min 8 (- (volume-table-sectors volume) cached))
                                  (volume-cache volume)))
      (setf (volume-changed volume) nil))))

;; The address in memory of the byte of the table at an offset, with the
;; rest of its sector and all of the next behind it: an entry of 12 bits
;; can lie across the end of a sector.
(defun table-address (volume offset)
  (let ((sector (floor offset 512)) (cached (volume-cached volume)))
    (unless (and cached (<= cached sector) (< (1+ sector) (+ cached 8)))
      (flush-table volume)
      (let ((first (+ (volume-table volume) sector)))
        (setf (volume-cached volume) nil)
        (clara.disk:read-sectors (volume-disk volume) first
                                 (min 8 (- (clara.disk:disk-sectors (volume-disk volume)) first))
                                 (volume-cache volume))
        (setf (volume-cached volume) sector)))
    (+ (volume-cache volume) (- offset (* 512 (volume-cached volume))))))

;; BODY changes the table. When it is over, what is held of the table is on
;; the disk; and when it does not get that far, nothing is held any more,
;; so that the next look at the table is a look at the disk.
(defun call-with-table (volume function)
  (let ((whole nil))
    (unwind-protect
         (multiple-value-prog1 (funcall function)
           (flush-table volume)
           (setq whole t))
      (unless whole
        (setf (volume-cached volume) nil
              (volume-changed volume) nil)))))

(defmacro with-table ((volume) &body body)
  `(call-with-table ,volume (lambda () ,@body)))

(defun cluster-p (volume cluster)
  (and (>= cluster 2) (< cluster (+ 2 (volume-clusters volume)))))

;; What the table has for a cluster. Two entries of 12 bits share three
;; bytes: the one with the even number has the lower 12 bits of the 16 at
;; its place, the odd one the upper. Of an entry of 32 bits the upper four
;; mean nothing.
(defun table-entry (volume cluster)
  (case (volume-kind volume)
    (12 (let ((pair (le (table-address volume (+ cluster (floor cluster 2))) 2)))
          (if (oddp cluster) (ash pair -4) (logand pair #xfff))))
    (16 (clara.unsafe:memory-16 (table-address volume (* 2 cluster))))
    (t (logand (clara.unsafe:memory-32 (table-address volume (* 4 cluster))) #xfffffff))))

;; The same, written: in memory, for FLUSH-TABLE to take to the disk. The
;; other half of a pair of 12 bits stays as it is, and so do the upper four
;; bits of 32.
(defun set-table-entry (volume cluster value)
  (case (volume-kind volume)
    (12 (let* ((at (table-address volume (+ cluster (floor cluster 2))))
               (pair (le at 2))
               (new (if (oddp cluster)
                        (logior (logand pair #xf) (ash value 4))
                        (logior (logand pair #xf000) value))))
          (setf (clara.unsafe:memory-8 at) (logand new 255)
                (clara.unsafe:memory-8 (1+ at)) (ash new -8))))
    (16 (setf (clara.unsafe:memory-16 (table-address volume (* 2 cluster))) value))
    (t (let ((at (table-address volume (* 4 cluster))))
         (setf (clara.unsafe:memory-32 at)
               (logior (logand (clara.unsafe:memory-32 at) #xf0000000) value)))))
  (setf (volume-changed volume) t)
  value)

;; What the table has for the last cluster of a file: the highest number
;; of its kind, and the seven below it mean the same.
(defun last-mark (volume)
  (case (volume-kind volume) (12 #xfff) (16 #xffff) (t #xfffffff)))

;; The cluster that comes after a cluster in its file, or NIL when it is
;; the last.
(defun next-cluster (volume cluster)
  (let ((next (table-entry volume cluster)))
    (cond ((>= next (- (last-mark volume) 7)) nil)
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

;; Every cluster of the file that begins in FIRST, or none for 0, which is
;; what an empty file begins in.
(defun file-clusters (volume first)
  (if (= first 0)
      nil
      (let ((clusters (chain volume first (1+ (volume-clusters volume)))))
        (when (> (length clusters) (volume-clusters volume))
          (error "a file has more clusters than the volume: its table leads round in a ring"))
        clusters)))

;; COUNT clusters that belong to no file, which the table says with a zero:
;; from where the last search ended on, and once round the volume at most.
;; Nothing is written here.
(defun free-clusters (volume count)
  (let ((found nil) (wanted count) (cluster (volume-next volume)) (looked 0))
    (unless (cluster-p volume cluster)
      (setq cluster 2))
    (loop
      (when (= wanted 0)
        (return))
      (when (= looked (volume-clusters volume))
        (error "the volume is full: ~D clusters are wanted, and ~D are free" count (- count wanted)))
      (when (zerop (table-entry volume cluster))
        (setq found (cons cluster found)
              wanted (1- wanted)))
      (setq looked (1+ looked)
            cluster (if (cluster-p volume (1+ cluster)) (1+ cluster) 2)))
    (setf (volume-next volume) cluster)
    (reverse found)))

;; The clusters become one file's: each has the next after it in the table,
;; and the last the mark of a last one. And the other way: they are nobody's
;; again.
(defun link-clusters (volume clusters)
  (do ((rest clusters (cdr rest)))
      ((null rest))
    (set-table-entry volume (car rest) (if (cdr rest) (cadr rest) (last-mark volume)))))

(defun unlink-clusters (volume clusters)
  (dolist (cluster clusters)
    (set-table-entry volume cluster 0)))

;; On the kind 32 a sector near the first says how many clusters are free
;; and where to look for one, for whoever would rather not count: "RRaA" at
;; its beginning and "rrAa" at 484 say that it is that sector, the count is
;; at 488 and the place at 492. A count of all ones means that nobody
;; knows, and stays. CHANGE is how many more clusters are free than were.
(defun note-free (volume change)
  (let ((sector (volume-information volume)))
    (when (and sector (/= change 0))
      (with-sectors (memory (volume-disk volume) sector 1)
        (let ((free (clara.unsafe:memory-32 (+ memory 488))))
          (when (and (= (clara.unsafe:memory-32 memory) #x41615252)
                     (= (clara.unsafe:memory-32 (+ memory 484)) #x61417272)
                     (<= 0 (+ free change) (volume-clusters volume)))
            (setf (clara.unsafe:memory-32 (+ memory 488)) (+ free change)
                  (clara.unsafe:memory-32 (+ memory 492)) (volume-next volume))
            (clara.disk:write-sectors (volume-disk volume) sector 1 memory)))))))

;; The first SECTORS sectors of a chain of clusters, read into the memory
;; at ADDRESS, or written from it, by FUNCTION. Clusters that lie side by
;; side on the disk go with one request, up to a mebibyte at a time.
(defun transfer-clusters (function volume clusters sectors address)
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
          (funcall function (volume-disk volume)
                   (+ (volume-data volume) (* (- first 2) each))
                   count address)
          (setq sectors (- sectors count)
                address (+ address (* 512 count))))))))

(defun read-clusters (volume clusters sectors address)
  (transfer-clusters #'clara.disk:read-sectors volume clusters sectors address))

(defun write-clusters (volume clusters sectors address)
  (transfer-clusters #'clara.disk:write-sectors volume clusters sectors address))

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
;; for itself and for the one it is in, are left out. Each entry knows its
;; place in the directory, for whoever changes it or takes it out.
(defun parse-directory (volume memory bytes)
  (let ((entries nil) (long nil) (sum nil) (next nil) (began nil))
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
                        (setq long (name-part at) sum check next (1- place) began at))
                       ((and next (> place 0) (= place next) (= check sum))
                        (setq long (append (name-part at) long) next (1- place)))
                       (t
                        (setq long nil next nil)))))
              ((/= 0 (logand what 8))
               (setq long nil next nil))
              (t
               (let ((short (short-name at))
                     (whole (and long (eql next 0) (= sum (checksum at)))))
                 (unless (or (string= short ".") (string= short ".."))
                   (setq entries
                         (cons (make-entry :name (if whole (long-name long) short)
                                           :short short
                                           :at (- at memory)
                                           :first (- (if whole began at) memory)
                                           :directory-p (/= 0 (logand what 16))
                                           :size (le (+ at 28) 4)
                                           :cluster (+ (clara.unsafe:memory-16 (+ at 26))
                                                       (if (= (volume-kind volume) 32)
                                                           (ash (clara.unsafe:memory-16 (+ at 20)) 16)
                                                           0)))
                               entries))))
               (setq long nil next nil)))))
    (reverse entries)))

;; FUNCTION, called with what the directory holds that begins in a
;; cluster, or the root's for the cluster 0: the address of its bytes in
;; memory, how many there are, and the clusters it lies in, in order, or
;; NIL for a directory of the root that is no file. A directory is 65536
;; entries at most, which is two mebibytes.
(defun call-with-directory (volume cluster function)
  (if (and (= cluster 0) (/= (volume-kind volume) 32))
      (with-sectors (memory (volume-disk volume) (volume-root volume) (volume-root-sectors volume))
        (funcall function memory (* 512 (volume-root-sectors volume)) nil))
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
               (funcall function memory (* 512 sectors) clusters))
          (clara.unsafe:free-memory memory pages)))))

;; The entries of a directory, in the order they have on the disk.
(defun read-directory (volume cluster)
  (call-with-directory volume cluster
                       (lambda (memory bytes clusters)
                         (declare (ignore clusters))
                         (parse-directory volume memory bytes))))

;; The bytes of a directory from START up to END have been changed in
;; memory, and the sectors that hold them go to the disk.
(defun write-directory (volume clusters memory start end)
  (let ((each (volume-cluster-sectors volume)))
    (do ((index (floor start 512) (1+ index)))
        ((> index (floor (1- end) 512)))
      (clara.disk:write-sectors (volume-disk volume)
                                (if clusters
                                    (+ (volume-data volume)
                                       (* (- (nth (floor index each) clusters) 2) each)
                                       (mod index each))
                                    (+ (volume-root volume) index))
                                1 (+ memory (* 512 index))))))

;;; Entries that are made
;;;
;;; A name that is eight characters and three, in capitals and digits and
;;; a few marks, is its own short name, and needs one entry. Any other name
;;; gets a short name that stands in for it, made of what is left of its
;;; characters when the rest are dropped, and is spelt out as it is in the
;;; entries before that one.

(defun in-string-p (character string)
  (dotimes (i (length string) nil)
    (when (char= character (char string i))
      (return t))))

(defun short-character-p (character)
  (let ((code (char-code character)))
    (or (<= 65 code 90) (<= 48 code 57) (in-string-p character "$%'-_@~`!(){}^#&"))))

;; What a short name keeps of a text: its first MOST characters that are
;; neither a space nor a dot, in capitals, with a _ for each that a short
;; name cannot have.
(defun short-characters (text most)
  (let ((short ""))
    (dotimes (i (length text) short)
      (let ((character (char-upcase (char text i))))
        (unless (or (>= (length short) most) (char= character #\Space) (char= character #\.))
          (setq short (concatenate 'string short
                                   (string (if (short-character-p character) character #\_)))))))))

;; A name, and what it has after its last dot; a dot that begins a name is
;; part of the name.
(defun name-and-extension (name)
  (let ((dot nil))
    (dotimes (i (length name))
      (when (char= (char name i) #\.)
        (setq dot i)))
    (if (and dot (> dot 0))
        (values (subseq name 0 dot) (subseq name (1+ dot)))
        (values name ""))))

(defun padded (text length)
  (loop
    (when (>= (length text) length)
      (return text))
    (setq text (concatenate 'string text " "))))

;; The 11 characters of the short name that a name is, when it is one: as
;; it stands, or with EITHER in letters of either case; NIL when it is not.
(defun plain-short (name either)
  (multiple-value-bind (base extension) (name-and-extension name)
    (let ((short-base (short-characters base 8)) (short-extension (short-characters extension 3)))
      (when (and (<= 1 (length base) 8)
                 (<= (length extension) 3)
                 (if either (string-equal base short-base) (string= base short-base))
                 (if either (string-equal extension short-extension) (string= extension short-extension)))
        (concatenate 'string (padded short-base 8) (padded short-extension 3))))))

;; The short name for a name: itself in capitals, when that is a short
;; name, which no entry can have then, or the name would be that entry's
;; (FIND-IN); or else the first of its characters, a ~ and a number, which
;; goes up until no entry of the directory has that name. TAKEN is the
;; short names that are there.
(defun short-for (name taken)
  (let ((plain (plain-short name t)))
    (if plain
        plain
        (multiple-value-bind (base extension) (name-and-extension name)
          (let ((base (short-characters base 8)) (extension (short-characters extension 3)) (number 1))
            (when (= (length base) 0)
              (setq base "_"))
            (loop
              (let* ((tail (format nil "~~~D" number))
                     (short (concatenate 'string
                                         (padded (concatenate 'string
                                                              (subseq base 0 (min (length base) (- 8 (length tail))))
                                                              tail)
                                                 8)
                                         (padded extension 3))))
                (unless (member short taken :test #'string=)
                  (return short))
                (setq number (1+ number)))))))))

;; The short names that the entries of a directory have, as their 11
;; characters each.
(defun short-names (memory bytes)
  (let ((names nil))
    (do ((at memory (+ at 32)))
        ((>= at (+ memory bytes)) names)
      (let ((first (clara.unsafe:memory-8 at)))
        (cond ((= first 0)
               (return names))
              ((and (/= first #xe5) (/= (logand (clara.unsafe:memory-8 (+ at 11)) #x3f) #x0f))
               (let ((name ""))
                 (dotimes (i 11)
                   (setq name (concatenate 'string name (string (code-char (clara.unsafe:memory-8 (+ at i)))))))
                 (setq names (cons name names)))))))))

;; A name as its characters in UTF-16: one beyond the first 65536 is two.
(defun utf-16 (name)
  (let ((units nil))
    (dotimes (i (length name) (reverse units))
      (let ((code (char-code (char name i))))
        (if (< code #x10000)
            (setq units (cons code units))
            (setq units (cons (+ #xdc00 (logand (- code #x10000) #x3ff))
                              (cons (+ #xd800 (ash (- code #x10000) -10)) units))))))))

;; A name that a file can have here: what the format rules out is ruled
;; out, and so is what other systems cannot say.
(defun check-name (name)
  (let ((length (length name)))
    (when (or (= length 0) (> length 255) (string= name ".") (string= name "..")
              (char= (char name (1- length)) #\Space) (char= (char name (1- length)) #\.))
      (error "~S cannot be the name of a file" name))
    (dotimes (i length name)
      (let ((character (char name i)))
        (when (or (< (char-code character) 32) (in-string-p character "\"*:<>?\\|"))
          (error "~S cannot be the name of a file: it has ~S in it" name character))))))

(defun clear-entry (at)
  (clara.unsafe:fill-memory-32 at 8 0))

;; The entry of a file, at an address: its short name, that it is a file
;; which nothing has put away since it was written (bit 5), the three days
;; of its making, its writing and its last reading, all of them the first
;; of January 1980, its first cluster in two halves, and its size. WHAT is
;; bit 4 instead for the entry of a directory, which has no size.
(defun put-entry (at short cluster size &optional (what #x20))
  (clear-entry at)
  (dotimes (i 11)
    (setf (clara.unsafe:memory-8 (+ at i)) (char-code (char short i))))
  (setf (clara.unsafe:memory-8 (+ at 11)) what
        (clara.unsafe:memory-16 (+ at 16)) #x21
        (clara.unsafe:memory-16 (+ at 18)) #x21
        (clara.unsafe:memory-16 (+ at 24)) #x21
        (clara.unsafe:memory-16 (+ at 20)) (ash cluster -16)
        (clara.unsafe:memory-16 (+ at 26)) (logand cluster #xffff)
        (clara.unsafe:memory-32 (+ at 28)) size))

;; One of the entries that spell a long name out: the NUMBERth 13 of its
;; characters, counted from 1, with bit 6 in the number of the last, and
;; the checksum of the short name it belongs to. A name that ends inside
;; an entry ends with a zero, and what is left of the entry is all ones.
(defun put-name-entry (at number last units sum)
  (clear-entry at)
  (setf (clara.unsafe:memory-8 at) (+ number (if last #x40 0))
        (clara.unsafe:memory-8 (+ at 11)) #x0f
        (clara.unsafe:memory-8 (+ at 13)) sum)
  (let ((rest (nthcdr (* 13 (1- number)) units)) (ended nil))
    (dolist (place *name-places*)
      (let ((unit (cond (rest (car rest))
                        (ended #xffff)
                        (t (setq ended t) 0))))
        (setq rest (cdr rest))
        (setf (clara.unsafe:memory-8 (+ at place)) (logand unit 255)
              (clara.unsafe:memory-8 (+ at place 1)) (ash unit -8))))))

;; Where COUNT entries side by side are free in a directory: how far from
;; its beginning, or NIL when there is no such place; and whether the place
;; runs into the end of the directory. An entry that was deleted is free,
;; and from the first one that begins with a zero on they all are.
(defun free-entries (memory bytes count)
  (let ((run 0) (start 0))
    (do ((offset 0 (+ offset 32)))
        ((>= offset bytes) nil)
      (let ((first (clara.unsafe:memory-8 (+ memory offset))))
        (cond ((= first 0)
               (when (= run 0)
                 (setq start offset))
               (return (if (<= (+ start (* 32 count)) bytes) (values start t) nil)))
              ((= first #xe5)
               (when (= run 0)
                 (setq start offset))
               (setq run (1+ run))
               (when (= run count)
                 (return (values start nil))))
              (t
               (setq run 0)))))))

;; A directory that is full gets one more cluster, all zeroes, at its end.
;; On the kinds 12 and 16 the directory of the root is no file, and is as
;; long as it was made.
(defun grow-directory (volume directory)
  (when (and (= (entry-cluster directory) 0) (/= (volume-kind volume) 32))
    (error "the directory of the root is full: it has ~D entries, and on a volume of this kind no more"
           (* 16 (volume-root-sectors volume))))
  (let* ((each (volume-cluster-sectors volume))
         (clusters (file-clusters volume (if (= (entry-cluster directory) 0)
                                             (volume-root-cluster volume)
                                             (entry-cluster directory))))
         (new (car (free-clusters volume 1)))
         (pages (page-frames (* 512 each)))
         (memory (clara.unsafe:allocate-memory pages)))
    (when (> (* 16 each (1+ (length clusters))) 65536)
      (clara.unsafe:free-memory memory pages)
      (error "a directory holds 65536 entries, and this one is full"))
    (unwind-protect
         (clara.disk:write-sectors (volume-disk volume) (+ (volume-data volume) (* (- new 2) each)) each memory)
      (clara.unsafe:free-memory memory pages))
    (set-table-entry volume new (last-mark volume))
    (set-table-entry volume (car (last clusters)) new)
    (flush-table volume)
    (note-free volume -1)))

;; A new entry in a directory, for the file NAME of SIZE bytes that begins
;; in CLUSTER: where a deleted one was, or after the last, in a directory
;; that grows when it has to. WHAT is for PUT-ENTRY.
(defun add-entry (volume directory name cluster size &optional (what #x20))
  (loop
    (when (call-with-directory
           volume (entry-cluster directory)
           (lambda (memory bytes clusters)
             (let* ((short (or (plain-short name nil) (short-for name (short-names memory bytes))))
                    (units (if (plain-short name nil) nil (utf-16 name)))
                    (long (floor (+ (length units) 12) 13)))
               (multiple-value-bind (start open) (free-entries memory bytes (1+ long))
                 (when start
                   (let ((at (+ memory start)) (end (+ start (* 32 (1+ long)))) (sum 0))
                     (dotimes (i 11)
                       (setq sum (logand (+ (ash (logand sum 1) 7) (ash sum -1) (char-code (char short i))) 255)))
                     (dotimes (i long)
                       (put-name-entry (+ at (* 32 i)) (- long i) (= i 0) units sum))
                     (put-entry (+ at (* 32 long)) short cluster size what)
                     ;; The entry after the last one in use begins with a zero, and has to still.
                     (when (and open (< end bytes))
                       (setf (clara.unsafe:memory-8 (+ memory end)) 0)
                       (setq end (1+ end)))
                     (write-directory volume clusters memory start end)
                     t))))))
      (return))
    (grow-directory volume directory)))

;; The entry of a file gets another first cluster and another size.
(defun change-entry (volume directory entry cluster size)
  (call-with-directory
   volume (entry-cluster directory)
   (lambda (memory bytes clusters)
     (declare (ignore bytes))
     (let ((at (+ memory (entry-at entry))))
       (setf (clara.unsafe:memory-16 (+ at 20)) (ash cluster -16)
             (clara.unsafe:memory-16 (+ at 26)) (logand cluster #xffff)
             (clara.unsafe:memory-32 (+ at 28)) size)
       (write-directory volume clusters memory (entry-at entry) (+ (entry-at entry) 32))))))

;; An entry is deleted, and with it the ones that spell its long name out:
;; each begins with #xe5 from now on.
(defun remove-entry (volume directory entry)
  (call-with-directory
   volume (entry-cluster directory)
   (lambda (memory bytes clusters)
     (declare (ignore bytes))
     (do ((offset (entry-first entry) (+ offset 32)))
         ((> offset (entry-at entry)))
       (setf (clara.unsafe:memory-8 (+ memory offset)) #xe5))
     (write-directory volume clusters memory (entry-first entry) (+ (entry-at entry) 32)))))

;;; Names

;; Where a name begins that says first which volume it is on, "2:/mine.lisp":
;; how many characters the number and its colon are, or NIL for a name that
;; says no such thing.
(defun volume-prefix (name)
  (let ((end 0))
    (loop
      (unless (and (< end (length name)) (<= 48 (char-code (char name end)) 57))
        (return))
      (setq end (1+ end)))
    (and (> end 0) (< end (length name)) (char= (char name end) #\:) (1+ end))))

;; The number that such a name begins with. One that no machine has volumes
;; for is not worked out to its end.
(defun volume-number (name)
  (let ((number 0))
    (dotimes (i (1- (volume-prefix name)) number)
      (when (< number 1000000)
        (setq number (+ (* 10 number) (- (char-code (char name i)) 48)))))))

;; The parts of a name that its slashes keep apart, without what says
;; which volume they are on.
(defun name-parts (name)
  (let ((parts nil) (start 0))
    (unless (stringp name)
      (error "the name of a file is a string, and ~S is not one" name))
    (setq start (or (volume-prefix name) 0))
    (do ((i start (1+ i)))
        ((> i (length name)))
      (when (or (= i (length name)) (char= (char name i) #\/))
        (when (> i start)
          (setq parts (cons (subseq name start i) parts)))
        (setq start (1+ i))))
    (reverse parts)))

;; The entry in a directory that a part of a name fits: by its long name
;; or by its short one, in letters of either case.
(defun find-in (volume directory part)
  (find-if (lambda (other)
             (or (string-equal part (entry-name other)) (string-equal part (entry-short other))))
           (read-directory volume (entry-cluster directory))))

;; The entry that the parts of a name lead to, by way of its directories
;; from the root on, or NIL when there is none. The root has no entry on
;; the disk, and gets one here.
(defun find-parts (volume parts)
  (let ((entry (make-entry :name "" :short "" :directory-p t :size 0 :cluster 0)))
    (dolist (part parts entry)
      (unless (entry-directory-p entry)
        (return nil))
      (setq entry (find-in volume entry part))
      (unless entry
        (return nil)))))

(defun find-entry (volume name)
  (find-parts volume (name-parts name)))

;; The volume that a name says it is on, by its number: one of those that
;; START found, or NIL when there are not that many.
(defun numbered-volume (name)
  (let ((number (volume-number name)))
    (and (> number 0) (nth (1- number) *volumes*))))

;; The volume that a name is looked up on: the one that the name says, when
;; it says one, and otherwise, or with no name, the one that names are
;; looked up on, whichever *VOLUME* was given, which is one of those that
;; START found. A volume that a variable has kept from an earlier start, in
;; a world that was saved, knows the disk and the page frame of that time,
;; which are somebody else's by now, so no name is looked up on it, nor on
;; what is no volume at all.
(defun the-volume (&optional name)
  (let ((volume *volume*))
    (cond ((and (stringp name) (volume-prefix name))
           (or (numbered-volume name)
               (error "there is no volume for ~A: ~A" name
                      (cond ((null *volumes*) "no disk has a volume that is known here")
                            ((null (cdr *volumes*)) "this machine has one, 1:")
                            (t (format nil "this machine has 1: to ~D:" (length *volumes*)))))))
          ((null volume)
           (error "there are no files: no disk has a volume that is known here"))
          ((member volume *volumes*)
           volume)
          ((volume-p volume)
           (error "the volume in CLARA.FAT:*VOLUME* is from an earlier start; (clara.fat:volumes) has this start's"))
          (t
           (error "CLARA.FAT:*VOLUME* holds ~S, which is no volume: (clara.fat:volumes) has them" volume)))))

(defun sorted (entries)
  (sort entries #'string-lessp :key #'entry-name))

;; What the directory of a name holds: its entries, in the order of their
;; names.
(defun entries (name)
  (let ((volume (the-volume name)))
    (clara:with-lock-held ((volume-lock volume))
      (let ((directory (find-entry volume name)))
        (unless (and directory (entry-directory-p directory))
          (error "there is no directory ~A" name))
        (sorted (read-directory volume (entry-cluster directory)))))))

;; The same as names, a directory's with a slash at its end; NIL when
;; there is no such directory, or no volume of the number that the name
;; begins with.
(defun names (name)
  (let ((volume (if (and (stringp name) (volume-prefix name))
                    (numbered-volume name)
                    (and *volume* (the-volume)))))
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
  (let ((volume (the-volume name)))
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

;; The directory that a name puts its file in, as the entry of it, and
;; the file's own name: what the name has after its last slash.
(defun place-of (volume name)
  (let* ((parts (name-parts name))
         (own (car (last parts)))
         (directory (and own (find-parts volume (reverse (cdr (reverse parts)))))))
    (unless own
      (error "~S is not the name of a file" name))
    (unless (and directory (entry-directory-p directory))
      (error "there is no directory for a file ~A to be in" name))
    (values directory own)))

;; How many clusters of a volume are nobody's: counted in the table, and
;; not taken from what the volume says of itself.
(defun free-count (volume)
  (let ((free 0))
    (dotimes (i (volume-clusters volume) free)
      (when (zerop (table-entry volume (+ i 2)))
        (setq free (1+ free))))))

;; So many bytes in mebibytes, to a tenth: what is left over is dropped,
;; or with UP makes one tenth more, so that what is wanted and the less
;; that there is never read as the same number.
(defun mebibytes (bytes up)
  (let ((tenths (floor (+ (* 10 bytes) (if up 1048575 0)) 1048576)))
    (format nil "~D.~D MiB" (floor tenths 10) (mod tenths 10))))

;; A file of that name on a volume, made of the SIZE bytes of memory at
;; ADDRESS, which is page frames: in place of the file that was there under
;; the name, or as a new one. An entry has 32 bits for the size of its
;; file. The file that was there stays until the new one has its entry,
;; so the volume needs room for both. A world is the one file that may be
;; too large for that, and the one that a machine cannot go on without
;; writing: when WORLD says that this is one, and the volume has no room
;; for it beside the one that was saved before, that one goes first, and
;; a machine that stops before the new one has its entry starts from its
;; files the next time. When there is no room for it even so, nothing is
;; touched, and the error says how much is missing.
(defun put-file (volume name address size world)
  (unless (and (integerp size) (<= 0 size #xffffffff))
    (error "a file is 4294967295 bytes at most, and not ~S" size))
  (clara:with-lock-held ((volume-lock volume))
    (multiple-value-bind (directory own) (place-of volume name)
      (check-name own)
      (let ((old (find-in volume directory own)))
        (when (and old (entry-directory-p old))
          (error "~A is a directory, and not a file" name))
        (with-table (volume)
          (let* ((each (* 512 (volume-cluster-sectors volume)))
                 (needed (floor (+ size each -1) each))
                 (gone (if old (file-clusters volume (entry-cluster old)) nil)))
            (when world
              (let ((free (free-count volume)))
                (when (< free needed)
                  (when (< (+ free (length gone)) needed)
                    (error "the world takes ~A, and the disk that it is saved on has room for ~A~A: files have to go from that disk, or the machine needs a larger one"
                           (mebibytes size t) (mebibytes (* each (+ free (length gone))) nil)
                           (if old ", even with the world that was saved before gone" "")))
                  (when old
                    (remove-entry volume directory old)
                    (unlink-clusters volume gone)
                    (flush-table volume)
                    (note-free volume (length gone))
                    (setq old nil
                          gone nil)))))
            (let* ((clusters (free-clusters volume needed))
                   (first (if clusters (car clusters) 0))
                   (entered nil))
              (write-clusters volume clusters (floor (+ size 511) 512) address)
              (link-clusters volume clusters)
              (flush-table volume)
              ;; Without its entry the file is clusters that nobody will ever read: they are given back.
              (unwind-protect
                   (progn
                     (if old
                         (change-entry volume directory old first size)
                         (add-entry volume directory own first size))
                     (setq entered t))
                (unless entered
                  (unlink-clusters volume clusters)
                  (flush-table volume)))
              (unlink-clusters volume gone)
              (note-free volume (- (length gone) (length clusters)))))))))
  name)

;; A file of that name, on the volume that names are looked up on, or on
;; the one that the name says. The name is returned.
(defun write-file (name address size)
  (put-file (the-volume name) name address size nil))

;; Do two names lead to one file? They do when they are on one volume and
;; come to the same entry of the same directory, however each was spelt:
;; with the volume said or not, in letters of either case, by a long name
;; or by a short one.
(defun same-file-p (name other)
  (let ((volume (the-volume name)))
    (and (eq volume (the-volume other))
         (clara:with-lock-held ((volume-lock volume))
           (multiple-value-bind (directory own) (place-of volume name)
             (multiple-value-bind (other-directory other-own) (place-of volume other)
               (let ((entry (find-in volume directory own))
                     (other-entry (find-in volume other-directory other-own)))
                 (and entry other-entry
                      (= (entry-cluster directory) (entry-cluster other-directory))
                      (= (entry-at entry) (entry-at other-entry))))))))))

;; A file like another: what the file FROM holds, under the name TO, on the
;; same volume or on another, in place of a file that was there under that
;; name. It is read whole and then written whole, so each volume has its
;; lock for its own half and nobody holds two. The two names must not be
;; the same file's: whoever deletes FROM once there is a TO, to move a
;; file, would be left with neither. The name TO is returned.
(defun copy-file (from to)
  (multiple-value-bind (memory size pages) (read-file from)
    (unwind-protect
         (progn
           (when (same-file-p from to)
             (error "~A and ~A are one file" from to))
           (write-file to memory size))
      (clara.unsafe:free-memory memory pages)))
  to)

;; The file of that name is no more: its entry is deleted, and its clusters
;; are free.
(defun remove-file (name)
  (let ((volume (the-volume name)))
    (clara:with-lock-held ((volume-lock volume))
      (multiple-value-bind (directory own) (place-of volume name)
        (let ((entry (find-in volume directory own)))
          (cond ((null entry)
                 (error "there is no file ~A" name))
                ((entry-directory-p entry)
                 (error "~A is a directory, and not a file" name)))
          (with-table (volume)
            (let ((clusters (file-clusters volume (entry-cluster entry))))
              (remove-entry volume directory entry)
              (unlink-clusters volume clusters)
              (note-free volume (length clusters)))))))
    name))

;;; Directories that are made

;; A directory of that name, with nothing in it, where the name says: one
;; cluster of zeroes that begins with the two entries every directory has,
;; "." for itself and ".." for the one it is in, which is cluster 0 when
;; that is the root; then the table; then its entry. In that order, like a
;; file. The name is returned.
(defun make-directory (name)
  (let ((volume (the-volume name)))
    (clara:with-lock-held ((volume-lock volume))
      (multiple-value-bind (directory own) (place-of volume name)
        (check-name own)
        (when (find-in volume directory own)
          (error "there is ~A already" name))
        (with-table (volume)
          (let* ((each (volume-cluster-sectors volume))
                 (cluster (car (free-clusters volume 1)))
                 (pages (page-frames (* 512 each)))
                 (memory (clara.unsafe:allocate-memory pages))
                 (entered nil))
            (unwind-protect
                 (progn
                   (put-entry memory ".          " cluster 0 #x10)
                   (put-entry (+ memory 32) "..         " (entry-cluster directory) 0 #x10)
                   (clara.disk:write-sectors (volume-disk volume) (+ (volume-data volume) (* (- cluster 2) each))
                                             each memory))
              (clara.unsafe:free-memory memory pages))
            (link-clusters volume (list cluster))
            (flush-table volume)
            ;; Without its entry the directory is a cluster that nobody will ever find: it is given back.
            (unwind-protect
                 (progn
                   (add-entry volume directory own cluster 0 #x10)
                   (setq entered t))
              (unless entered
                (unlink-clusters volume (list cluster))
                (flush-table volume)))
            (note-free volume -1)))))
    name))

;; The directory of that name is no more: one that has nothing in it, and
;; no other.
(defun remove-directory (name)
  (let ((volume (the-volume name)))
    (clara:with-lock-held ((volume-lock volume))
      (multiple-value-bind (directory own) (place-of volume name)
        (let ((entry (find-in volume directory own)))
          (cond ((null entry)
                 (error "there is no directory ~A" name))
                ((not (entry-directory-p entry))
                 (error "~A is a file, and not a directory" name))
                ((read-directory volume (entry-cluster entry))
                 (error "the directory ~A is not empty" name)))
          (with-table (volume)
            (let ((clusters (file-clusters volume (entry-cluster entry))))
              (remove-entry volume directory entry)
              (unlink-clusters volume clusters)
              (note-free volume (length clusters)))))))
    name))

;; How many bytes of the volume are nobody's: its free clusters, counted
;; in the table, and not taken from what the volume says of itself.
(defun free-bytes ()
  (let ((volume (the-volume)))
    (* 512 (volume-cluster-sectors volume)
       (clara:with-lock-held ((volume-lock volume))
         (free-count volume)))))

;; A file like WRITE-FILE makes, on the volume that a world is saved on,
;; whichever volume names are looked up on: a machine starts from one disk,
;; and finds its world there or nowhere. It is a world, which goes where
;; the one before it was when the volume has no room for the two. A name
;; that says another volume is refused: the file would not be where its
;; name says.
(defun write-image (name address size)
  (let ((*volume* (if (member *image-volume* *volumes*) *image-volume* (car *volumes*))))
    (when (and (stringp name) (volume-prefix name) (not (eq (numbered-volume name) *volume*)))
      (error "a world is saved on the volume that the machine was started from, and ~A is on another" name))
    (put-file (the-volume) name address size t)))

;; What the language says of the volumes (CLARA:VOLUMES): for each, in the
;; order in which they were found, a list of the name of its first
;; directory, "1:/" for the first, and what is known of it, a keyword and
;; then what it says: :BYTES, how large its files can be together;
;; :STARTED-FROM, when the machine was started from it; :CURRENT, when it
;; is the one that a name is looked up on which does not say its volume;
;; and :READ-ONLY, when its disk cannot be written.
(defun described ()
  (let ((number 0))
    (mapcar (lambda (volume)
              (setq number (1+ number))
              (append (list (format nil "~D:/" number)
                            :bytes (* 512 (volume-clusters volume) (volume-cluster-sectors volume)))
                      (if (eq volume *image-volume*) (list :started-from t) nil)
                      (if (eq volume *volume*) (list :current t) nil)
                      (if (clara.disk:disk-read-only (volume-disk volume)) (list :read-only t) nil)))
            *volumes*)))

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
        *volume* nil
        *image-volume* nil)
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
         (clara:provide-files :text #'file-text :names #'names :write #'write-file :delete #'remove-file
                              :image #'write-image :copy #'copy-file :volumes #'described)
         (when (cdr *volumes*)
           (format t "files: names are looked up on the first of these volumes~%")))
        (t
         (clara:provide-files)
         (format t "files: no volume, so LOAD finds what was read as the machine started and nothing else~%")))
  *volumes*)
