#!/usr/bin/env python3
"""A disk for a machine to boot from: one FAT volume with the files of a
directory on it, as a raw image.

usage: tools/mkdisk.py [--fat 12|16|32] [--table gpt|mbr|none] [--size MiB] <directory> <image>
       tools/mkdisk.py [--size MiB] --grow <image> <image of the larger disk>
       tools/mkdisk.py --volume <image> <file>
       tools/mkdisk.py --spoil <image>
       tools/mkdisk.py --systems <image>

The machines of `make test` used to boot from a directory of the host's
that QEMU shows as a disk, which cannot be written to. A kernel that saves
its world has to write to its boot volume, and the firmware has to read
what it wrote, so the volume is a real one, made here: of any of the three
kinds of FAT, behind a GUID partition table, behind a table of partitions
of the old kind, or as the whole disk. The volume is laid out by the
specification ("FAT: General Overview of On-Disk Format", 1.03; UEFI 2.10,
chapter 5, for the tables), with long names where a name needs one, and it
is the same bytes every time for the same files. tools/mkimage.sh makes
the disk for UTM, with macOS's own tools.

--size says how many mebibytes the disk has, for a volume of the kind 32
with more room than the few that the tests boot from: a machine saves its
world on its disk, which is as large as the heap has grown, and the one
that was saved before is there until the new one is whole. --grow puts
the files of a disk's volume on a new disk of that size, 1024 when
nothing says, for a machine whose disk is too small: every file and every
directory of the old volume, held against it once more when the new disk
is written, and nothing is done to the old one.

--volume writes the first volume of a disk into a file of its own, for a
program that looks at a volume and knows nothing of partitions, such as
the host's own checker of FAT volumes (tools/boottest.sh). --spoil changes
one byte of the world that a kernel saved on such a disk
(\\clara\\clara.image), for a boot that has to notice and start from the
files instead. --systems prints the names of the systems that a disk holds,
one to a line: the directories of \\clara that have a manifest, which is
what makes a system whole (tools/system.py). tools/run.sh asks that of the
disk that it keeps for a machine, to know whether the build is another
system than the one that is there, and gets nothing for a disk from before
a system had a directory.
"""
import os
import struct
import sys
import zlib

SECTOR = 512
FIRST = 2048  # the sector that a partition begins at, a mebibyte into the disk

# How large a volume of each kind is, in sectors, how many sectors a
# cluster of it has, how many are kept back before its table, and how many
# entries the directory of its root has where that is no file. What makes
# a volume the kind it is is how many clusters it has: fewer than 4085,
# fewer than 65525, or more. So the kind that may have fewest has the
# largest: a volume has to hold a system and, twice over for a moment,
# the world that is saved on it.
KINDS = {
    12: dict(sectors=49152, cluster=16, reserved=1, root=224),
    16: dict(sectors=49152, cluster=4, reserved=1, root=512),
    32: dict(sectors=70000, cluster=1, reserved=32, root=0),
}



def cluster_sectors(sectors):
    """How many sectors a cluster has on a volume of the kind 32 with that
    many sectors: the table of the overview (page 20), which is what the
    programs that make such volumes go by. Half a kilobyte up to 260 MiB,
    four kilobytes up to 8 GiB, and twice that for each doubling after."""
    for most, each in ((532480, 1), (16777216, 8), (33554432, 16), (67108864, 32)):
        if sectors <= most:
            return each
    return 64


SHORT = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$%'-_@~`!(){}^#&")
PLACES = (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)
DAY = 0x21  # the first of January 1980: the same disk for the same files


def parts(name):
    dot = name.rfind(".")
    return (name[:dot], name[dot + 1:]) if dot > 0 else (name, "")


def kept(text, most):
    """What a short name keeps of a text: capitals, no spaces and no dots."""
    return "".join(c if c in SHORT else "_" for c in text.upper() if c not in " .")[:most]


def plain(name, either):
    """The 11 characters of the short name that a name is, or None."""
    base, extension = parts(name)
    b, e = kept(base, 8), kept(extension, 3)
    same = (lambda a, c: a.upper() == c) if either else (lambda a, c: a == c)
    if 1 <= len(base) <= 8 and len(extension) <= 3 and same(base, b) and same(extension, e):
        return b.ljust(8) + e.ljust(3)
    return None


def short_for(name, taken):
    short = plain(name, True)
    if short and short not in taken:
        return short
    base, extension = parts(name)
    b, e, number = kept(base, 8) or "_", kept(extension, 3), 1
    while True:
        tail = "~%d" % number
        short = (b[: 8 - len(tail)] + tail).ljust(8) + e.ljust(3)
        if short not in taken:
            return short
        number += 1


def records(name, short, what, cluster, size):
    """The entries of a directory for one name: the ones that spell a long
    name out, the last part first, and then the one with the short name."""
    out = bytearray()
    if name not in (".", "..") and plain(name, False) is None:
        total = 0
        for byte in short.encode("ascii"):
            total = (((total & 1) << 7) + (total >> 1) + byte) & 0xFF
        raw = name.encode("utf-16-le")
        units = list(struct.unpack("<%dH" % (len(raw) // 2), raw))
        count = (len(units) + 12) // 13
        if len(units) % 13:
            units.append(0)
        units += [0xFFFF] * (13 * count - len(units))
        for number in range(count, 0, -1):
            entry = bytearray(32)
            entry[0] = number | (0x40 if number == count else 0)
            entry[11] = 0x0F
            entry[13] = total
            for place, unit in zip(PLACES, units[13 * (number - 1): 13 * number]):
                struct.pack_into("<H", entry, place, unit)
            out += entry
    entry = bytearray(32)
    entry[0:11] = short.encode("ascii")
    entry[11] = what
    struct.pack_into("<HH", entry, 16, DAY, DAY)
    struct.pack_into("<H", entry, 20, cluster >> 16)
    struct.pack_into("<HH", entry, 24, DAY, cluster & 0xFFFF)
    struct.pack_into("<I", entry, 28, size)
    return out + entry


class Node:
    """A file or a directory that goes onto a volume: its name, what it
    holds, and WHAT its entry says it is, bit 4 for a directory and bit 5
    for a file that nothing has put away since it was written."""

    def __init__(self, name, children=None, data=b"", what=None):
        self.name = name
        self.directory = children is not None
        self.children = children or []
        self.data = data
        self.what = what if what is not None else 0x10 if self.directory else 0x20
        self.first = 0     # its first cluster
        self.clusters = 0  # and how many it has


def host_tree(name, path):
    """What a directory of this computer holds, as nodes: in the order of
    the names, and without what macOS leaves lying about."""
    if os.path.isdir(path):
        return Node(name, [host_tree(child, os.path.join(path, child))
                           for child in sorted(os.listdir(path)) if not child.startswith(".")])
    with open(path, "rb") as f:
        return Node(name, data=f.read())


class Volume:
    def __init__(self, kind, hidden, sectors=None):
        k = KINDS[kind]
        self.kind, self.hidden = kind, hidden
        self.sectors, self.each, self.reserved = k["sectors"], k["cluster"], k["reserved"]
        if sectors is not None:
            # Another size than the usual one, with the clusters that such a size has.
            self.sectors, self.each = sectors, cluster_sectors(sectors)
        self.root_entries = k["root"]
        self.root_sectors = (32 * self.root_entries + SECTOR - 1) // SECTOR
        # A table has to have an entry for every cluster, and the clusters
        # are what the tables leave: so the one is tried until it fits the other.
        self.table = 1
        while True:
            self.clusters = (self.sectors - self.reserved - 2 * self.table - self.root_sectors) // self.each
            need = ((self.clusters + 2) * kind + 7) // 8
            need = (need + SECTOR - 1) // SECTOR
            if need <= self.table:
                break
            self.table = need
        self.data = self.reserved + 2 * self.table + self.root_sectors
        if not {12: self.clusters < 4085, 16: 4085 <= self.clusters < 65525, 32: self.clusters >= 65525}[kind]:
            sys.exit("tools/mkdisk.py: %d clusters do not make a FAT%d volume" % (self.clusters, kind))
        # What lies before the clusters is held whole: the first sectors, the
        # tables, and on the older kinds the directory of the root. Of the
        # clusters only what is written to them, each run with its place in
        # bytes from the start of the volume. The rest of a volume is zeroes,
        # and nothing here holds those, so a disk of a gibibyte costs what
        # its files do.
        self.head = bytearray(self.data * SECTOR)
        self.pieces = []
        self.entries = [0] * (self.clusters + 2)
        self.entries[0] = 0x0FFFFFF8  # the kind of disk, #xf8, in the lowest byte, and ones above it
        self.entries[1] = 0x0FFFFFFF
        self.next = 2

    def take(self, count):
        """COUNT clusters side by side, chained: the first of them, or 0 for none."""
        if count == 0:
            return 0
        first = self.next
        if first + count > self.clusters + 2:
            sys.exit("tools/mkdisk.py: the files do not fit on a FAT%d volume of %d KiB"
                     % (self.kind, self.sectors // 2))
        for cluster in range(first, first + count):
            self.entries[cluster] = cluster + 1
        self.entries[first + count - 1] = 0x0FFFFFFF
        self.next += count
        return first

    def put(self, first, data):
        self.pieces.append(((self.data + (first - 2) * self.each) * SECTOR, bytes(data)))

    def lay_out(self, node, root=False):
        """Clusters for a directory and for everything in it, the directory first."""
        taken, total = set(), 0 if root else 2
        for child in node.children:
            child.short = short_for(child.name, taken)
            taken.add(child.short)
            total += len(records(child.name, child.short, 0, 0, 0)) // 32
        size = self.each * SECTOR
        if root and self.kind != 32:
            if total > self.root_entries:
                sys.exit("tools/mkdisk.py: the root has %d entries, and a FAT%d volume has room for %d"
                         % (total, self.kind, self.root_entries))
        else:
            node.clusters = max(1, (32 * total + size - 1) // size)
            node.first = self.take(node.clusters)
        for child in node.children:
            if child.directory:
                self.lay_out(child)
            else:
                child.clusters = (len(child.data) + size - 1) // size
                child.first = self.take(child.clusters)

    def write(self, node, above=None):
        """The entries of a directory, and then what its entries lead to.
        ABOVE is the first cluster of the directory that this one is in: 0
        when that is the root, of whichever kind, and None for the root."""
        out = bytearray()
        if above is not None:
            out += records(".", ".".ljust(11), 0x10, node.first, 0)
            out += records("..", "..".ljust(11), 0x10, above, 0)
        for child in node.children:
            out += records(child.name, child.short, child.what, child.first,
                           0 if child.directory else len(child.data))
        if node.first:
            self.put(node.first, out)
        else:
            at = (self.data - self.root_sectors) * SECTOR
            self.head[at: at + len(out)] = out
        for child in node.children:
            if child.directory:
                self.write(child, 0 if above is None else node.first)
            elif child.first:
                self.put(child.first, child.data)

    def finish(self):
        """The first sector, which says how the volume is laid out, and the tables."""
        b = self.head
        b[0:3] = b"\xeb\x58\x90" if self.kind == 32 else b"\xeb\x3c\x90"
        b[3:11] = b"CLARAOS "
        small = self.sectors if self.sectors < 65536 else 0
        struct.pack_into("<HBHBHHBHHHII", b, 11, SECTOR, self.each, self.reserved, 2, self.root_entries, small,
                         0xF8, 0 if self.kind == 32 else self.table, 63, 255, self.hidden,
                         0 if small else self.sectors)
        # The volume has no name: there is no entry for one in the directory of the root, and the
        # first sector says "NO NAME" where it would repeat it.
        label = b"\x80\x00\x29" + struct.pack("<I", 0xC1A4A005) + b"NO NAME    " + b"FAT%d   " % self.kind
        if self.kind == 32:
            # The table's length again, in 32 bits; both copies are kept; the directory of the root
            # begins in cluster 2; the sector that counts the free clusters is the second, and the
            # seventh is a copy of this one.
            struct.pack_into("<IHHIHH", b, 36, self.table, 0, 0, 2, 1, 6)
            b[64:90] = label
            free = self.entries.count(0)
            struct.pack_into("<I", b, SECTOR, 0x41615252)
            struct.pack_into("<III", b, SECTOR + 484, 0x61417272, free, self.next)
            struct.pack_into("<I", b, SECTOR + 508, 0xAA550000)
        else:
            b[36:62] = label
        struct.pack_into("<H", b, 510, 0xAA55)
        if self.kind == 32:
            b[6 * SECTOR: 8 * SECTOR] = b[0: 2 * SECTOR]
        table = bytearray(self.table * SECTOR)
        for cluster, entry in enumerate(self.entries):
            if self.kind == 12:
                at, entry = cluster + cluster // 2, entry & 0xFFF
                pair = table[at] | table[at + 1] << 8
                pair = (pair & 0x000F) | entry << 4 if cluster & 1 else (pair & 0xF000) | entry
                table[at], table[at + 1] = pair & 0xFF, pair >> 8
            elif self.kind == 16:
                struct.pack_into("<H", table, 2 * cluster, entry & 0xFFFF)
            else:
                struct.pack_into("<I", table, 4 * cluster, entry)
        for copy in range(2):
            at = (self.reserved + copy * self.table) * SECTOR
            b[at: at + len(table)] = table


def old_table(sectors, kind):
    """The first sector of a disk with one partition, by the table of old."""
    sector = bytearray(SECTOR)
    struct.pack_into("<B3sB3sII", sector, 446, 0x80, b"\xfe\xff\xff", kind, b"\xfe\xff\xff", FIRST, sectors)
    struct.pack_into("<H", sector, 510, 0xAA55)
    return sector


def guid_table(total, sectors):
    """The GUID partition table of a disk of TOTAL sectors with one
    partition: the table, for the first 34 sectors of the disk, and its
    copy, for the last 33, each with its checksums. The partition
    is of the kind for plain data, as on the disk that macOS makes for UTM,
    and not of the kind that is kept for the firmware: the firmware starts
    from a FAT volume of either, and the host opens the first like any
    other disk, which is how files get to a machine and back."""
    data = bytes.fromhex("a2a0d0ebe5b9334487c068b6b72699c7")  # EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
    entries = bytearray(128 * 128)
    entries[0:16] = data
    entries[16:32] = bytes.fromhex("c1a4a05c1a4a0540a05c1a4a05c1a4a0")
    struct.pack_into("<QQQ", entries, 32, FIRST, FIRST + sectors - 1, 0)
    entries[56:56 + 14] = "ClaraOS".encode("utf-16-le")

    def header(own, other, table):
        h = bytearray(SECTOR)
        struct.pack_into("<8sIIIIQQQQ16sQIII", h, 0, b"EFI PART", 0x10000, 92, 0, 0, own, other, 34, total - 34,
                         bytes.fromhex("c1a4a0d15c0040a0a05c1a4a05c1a4a1"), table, 128, 128, zlib.crc32(entries))
        struct.pack_into("<I", h, 16, zlib.crc32(h[:92]))
        return h

    front = old_table(min(total - 1, 0xFFFFFFFF), 0xEE)
    struct.pack_into("<B3sB3sI", front, 446, 0, b"\x00\x02\x00", 0xEE, b"\xff\xff\xff", 1)
    return front + header(1, total - 1, 2) + entries, entries + header(total - 1, 1, total - 33)


def make(kind, table, root, image, size=None):
    """A disk with one volume that holds the files of ROOT, a tree of
    nodes: of the usual size of its kind, or of SIZE mebibytes in all."""
    first = 0 if table == "none" else FIRST
    after = 33 if table == "gpt" else 0
    volume = Volume(kind, first, None if size is None else size * 2048 - first - after)
    volume.lay_out(root, root=True)
    volume.write(root)
    volume.finish()
    total = first + volume.sectors + after
    # Most of a new disk is zeroes, which a file need not hold: only what is not is written.
    with open(image, "wb") as f:
        f.truncate(total * SECTOR)

        def put(at, data):
            chunk = 64 * 1024
            for start in range(0, len(data), chunk):
                piece = data[start: start + chunk]
                if piece.count(0) != len(piece):
                    f.seek(at + start)
                    f.write(piece)

        if table == "gpt":
            front, back = guid_table(total, volume.sectors)
            put(0, front)
            put((total - 33) * SECTOR, back)
        elif table == "mbr":
            put(0, old_table(volume.sectors, 0xEF))
        put(first * SECTOR, volume.head)
        for at, data in volume.pieces:
            put(first * SECTOR + at, data)


def first_sector(f):
    """Where the volume of a disk begins, in sectors: at the first partition
    of its GUID partition table or of its table of old, or at the start of
    a disk that has neither."""
    f.seek(0)
    front = f.read(2 * SECTOR)
    if front[SECTOR: SECTOR + 8] == b"EFI PART":
        entries, count, size = struct.unpack_from("<QII", front, SECTOR + 72)
        f.seek(entries * SECTOR)
        table = f.read(count * size)
        for entry in range(0, len(table), size):
            if any(table[entry: entry + 16]):
                return struct.unpack_from("<Q", table, entry + 32)[0]
    elif front[11:13] != b"\x00\x02" or front[21] < 0xF0:  # not the first sector of a volume: a table of partitions
        for entry in range(446, 510, 16):
            if front[entry + 4]:
                return struct.unpack_from("<I", front, entry + 8)[0]
    return 0


def volume_of(image, out):
    """The volume of a disk, from its first sector to the end of the disk,
    in a file of its own, which holds no more of its zeroes than the disk."""
    with open(image, "rb") as f, open(out, "wb") as o:
        at = first_sector(f) * SECTOR
        o.truncate(f.seek(0, 2) - at)
        f.seek(at)
        while True:
            piece = f.read(1024 * 1024)
            if not piece:
                break
            if piece.count(0) != len(piece):
                o.seek(f.tell() - len(piece) - at)
                o.write(piece)


class Reader:
    """The volume of a disk, read: what its directories hold, and its
    files. Of the disk only what is asked for is read, so a disk that is
    mostly room is read as quickly as a small one."""

    def __init__(self, image):
        self.file = open(image, "rb")
        self.start = first_sector(self.file) * SECTOR
        first = self.read(0, SECTOR)
        self.each = first[13]
        reserved, tables, root_entries, small = struct.unpack_from("<HBHH", first, 14)
        table = struct.unpack_from("<H", first, 22)[0] or struct.unpack_from("<I", first, 36)[0]
        sectors = small or struct.unpack_from("<I", first, 32)[0]
        if struct.unpack_from("<H", first, 11)[0] != SECTOR or not self.each or not table or first[510:512] != b"\x55\xaa":
            sys.exit("tools/mkdisk.py: %s does not begin with a FAT volume" % image)
        self.root = (reserved + tables * table) * SECTOR
        self.root_bytes = 32 * root_entries
        self.data = self.root + (self.root_bytes + SECTOR - 1) // SECTOR * SECTOR
        self.clusters = (sectors * SECTOR - self.data) // (self.each * SECTOR)
        self.kind = 12 if self.clusters < 4085 else 16 if self.clusters < 65525 else 32
        self.root_cluster = struct.unpack_from("<I", first, 44)[0] if self.kind == 32 else 0
        self.table = self.read(reserved * SECTOR, table * SECTOR)

    def read(self, at, count):
        """COUNT bytes of the volume from the byte AT on."""
        self.file.seek(self.start + at)
        return self.file.read(count)

    def after(self, cluster):
        if self.kind == 12:
            pair = struct.unpack_from("<H", self.table, cluster + cluster // 2)[0]
            return pair >> 4 if cluster & 1 else pair & 0xFFF
        if self.kind == 16:
            return struct.unpack_from("<H", self.table, 2 * cluster)[0]
        return struct.unpack_from("<I", self.table, 4 * cluster)[0] & 0x0FFFFFFF

    def chain(self, cluster):
        """What the clusters hold that the table chains from a cluster on."""
        out, last, seen, size = bytearray(), {12: 0xFF8, 16: 0xFFF8, 32: 0x0FFFFFF8}[self.kind], set(), self.each * SECTOR
        while 2 <= cluster < min(last, self.clusters + 2) and cluster not in seen:
            # Clusters that lie side by side are read in one go.
            run = 1
            seen.add(cluster)
            while self.after(cluster + run - 1) == cluster + run and cluster + run < self.clusters + 2 \
                    and cluster + run not in seen:
                seen.add(cluster + run)
                run += 1
            out += self.read(self.data + (cluster - 2) * size, run * size)
            cluster = self.after(cluster + run - 1)
        return bytes(out)

    def listing(self, cluster=None):
        """What a directory holds, the root's for no cluster: (name, what it
        is, its first cluster, its size in bytes) for each entry, by its
        long name when it has one. The entries that spell a long name out
        carry a sum of the short name that they belong to, and count only
        when it is that entry's; a short name is in capitals, and two bits
        of its entry say which of its parts is meant in small letters."""
        if cluster is None:
            data = self.chain(self.root_cluster) if self.kind == 32 else self.read(self.root, self.root_bytes)
        else:
            data = self.chain(cluster)
        found, long, sums = [], [], set()
        for at in range(0, len(data) - 31, 32):
            entry = data[at: at + 32]
            if entry[0] == 0:
                break
            if entry[0] == 0xE5:
                long, sums = [], set()
            elif entry[11] & 0x3F == 0x0F:
                long.insert(0, b"".join(entry[place: place + 2] for place in PLACES))
                sums.add(entry[13])
            elif entry[11] & 8:
                long, sums = [], set()
            else:
                total = 0
                for byte in entry[0:11]:
                    total = (((total & 1) << 7) + (total >> 1) + byte) & 0xFF
                name = b"".join(long).decode("utf-16-le", "replace").split("\0")[0] if sums == {total} else ""
                if not name:
                    base, extension = entry[0:8].decode("ascii", "replace").rstrip(), entry[8:11].decode("ascii", "replace").rstrip()
                    if entry[12] & 8:
                        base = base.lower()
                    if entry[12] & 16:
                        extension = extension.lower()
                    name = base + ("." + extension if extension else "")
                first = struct.unpack_from("<H", entry, 26)[0] | (struct.unpack_from("<H", entry, 20)[0] << 16 if self.kind == 32 else 0)
                if name not in (".", ".."):
                    found.append((name, entry[11], first, struct.unpack_from("<I", entry, 28)[0]))
                long, sums = [], set()
        return found

    def entries(self, cluster=None):
        """The same, as (name, is it a directory, its first cluster)."""
        return [(name, bool(what & 16), first) for name, what, first, size in self.listing(cluster)]

    def within(self, entries, name):
        for entry in entries:
            if entry[0].lower() == name.lower():
                return entry
        return None


def systems(image):
    """The systems that a disk holds: the directories of \\clara that have a
    manifest."""
    reader = Reader(image)
    clara = reader.within(reader.entries(), "clara")
    if not clara or not clara[1]:
        return []
    return [name for name, directory, cluster in reader.entries(clara[2])
            if directory and reader.within(reader.entries(cluster), "manifest")]


def disk_tree(reader, name="", cluster=None, what=0x10, depth=0):
    """What a volume holds, as nodes: every directory from the root down, in
    the order of its entries, and every file with its bytes. A file that
    the table has fewer clusters for than its entry says is a volume out of
    order, and nothing is made of one."""
    if depth > 64:
        sys.exit("tools/mkdisk.py: the directories of the volume lead round in a ring")
    children = []
    for child, kind, first, size in reader.listing(cluster):
        if kind & 0x10:
            children.append(disk_tree(reader, child, first, kind & 0x37, depth + 1))
        else:
            data = reader.chain(first)[:size] if size else b""
            if len(data) != size:
                sys.exit("tools/mkdisk.py: the file %s is %d bytes by its directory, and the table of the volume has %d for it"
                         % (child, size, len(data)))
            children.append(Node(child, data=data, what=kind & 0x27))
    return Node(name, children, what=what)


def flat(node, path=""):
    """Every file and every directory of a tree, by its name from the root
    down, with what it is and what it holds."""
    out = {}
    for child in node.children:
        name = path + "/" + child.name
        out[name] = (child.what, child.data)
        if child.directory:
            out.update(flat(child, name))
    return out


def grow(image, larger, size):
    """The files of a disk's volume on a new disk of SIZE mebibytes: a
    volume of the kind 32 behind a GUID partition table, which is what a
    machine of tools/run.sh starts from. What the new disk holds is read
    back and held against the old one, file by file, and a disk that does
    not hold the same is not left behind. The old disk is only read."""
    before = disk_tree(Reader(image))
    make(32, "gpt", before, larger, size)
    if flat(disk_tree(Reader(larger))) != flat(before):
        os.remove(larger)
        sys.exit("tools/mkdisk.py: the new disk does not hold what %s holds, and is not kept" % image)


def spoil(image):
    """One byte of the saved world is turned over. Where the file begins is
    known by how an image begins (kernel/lisp/image.c): eight letters at the
    start of some sector, and after them the number of its format, which is
    small and not zero. The letters alone will not do. The kernels on the
    disk have them among their constants, and when a build happens to put
    those at the start of a sector, the byte that is turned over is one of
    the kernel's: the boot that was to refuse the world then resumes it."""
    with open(image, "r+b") as f:
        disk = f.read()
        at = disk.find(b"CLARAIMG")
        while at >= 0 and (at % SECTOR or not 0 < struct.unpack_from("<Q", disk, at + 8)[0] < 65536):
            at = disk.find(b"CLARAIMG", at + 1)
        if at < 0:
            sys.exit("tools/mkdisk.py: %s holds no world that a kernel saved" % image)
        at += 200  # among the first of the words that its checksum is of
        f.seek(at)
        f.write(bytes([disk[at] ^ 0xFF]))


def main(arguments):
    kind, table, size, growing, rest = 32, "gpt", None, False, []
    while arguments:
        argument = arguments.pop(0)
        if argument == "--fat" and arguments:
            kind = int(arguments.pop(0))
        elif argument == "--table" and arguments:
            table = arguments.pop(0)
        elif argument == "--size" and arguments and arguments[0].isdigit():
            size = int(arguments.pop(0))
        elif argument == "--grow":
            growing = True
        elif argument == "--spoil" and len(arguments) == 1:
            return spoil(arguments.pop(0))
        elif argument == "--volume" and len(arguments) == 2:
            return volume_of(arguments[0], arguments[1])
        elif argument == "--systems" and len(arguments) == 1:
            return print("\n".join(systems(arguments[0])))
        else:
            rest.append(argument)
    if kind not in KINDS or table not in ("gpt", "mbr", "none") or len(rest) != 2 or (size is not None and kind != 32):
        sys.exit(__doc__.strip().split("\n\n")[1])
    if growing:
        return grow(rest[0], rest[1], 1024 if size is None else size)
    make(kind, table, host_tree("", rest[0]), rest[1], size)


if __name__ == "__main__":
    main(sys.argv[1:])
