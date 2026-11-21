#!/usr/bin/env python3
"""What a system is called, and what it is made of.

usage: tools/system.py id <file>...
       tools/system.py manifest <directory> <name>

A system is one build of ClaraOS: its two kernels and its Lisp files. It
has a name, its version and eight digits that are worked out from its
sources: `id` prints those digits, the beginning of the SHA-256 of the
names and the contents of the files it is given, in the order of their
names. So the same sources are the same system wherever they are built,
and any change to them is another one. The kernel has its system's name in
it, and finds its Lisp files on the boot volume in the directory of that
name (kernel/boot.c).

`manifest` writes the file `manifest` into a system's directory: its name
in the first line, and then a line for every other file there, with how
many bytes it has and its SHA-512. That is what a running system reads
before it takes a newer one from another disk (lisp/system.lisp): which
system it is, which files make it up, and what each has to be. A system
that reads a manifest passes over the lines that it does not know, so
that a later version can say more.
"""
import hashlib
import os
import sys


def identity(files):
    digest = hashlib.sha256()
    for name in sorted(files):
        with open(name, "rb") as f:
            data = f.read()
        digest.update(name.encode() + b"\0" + str(len(data)).encode() + b"\0" + data)
    return digest.hexdigest()[:8]


def manifest(directory, name):
    lines = ["ClaraOS system: %s" % name]
    for entry in sorted(os.listdir(directory)):
        path = os.path.join(directory, entry)
        if entry == "manifest" or entry.startswith(".") or not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            data = f.read()
        lines.append("file %d %s %s" % (len(data), hashlib.sha512(data).hexdigest(), entry))
    with open(os.path.join(directory, "manifest"), "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def main(arguments):
    if len(arguments) >= 2 and arguments[0] == "id":
        print(identity(arguments[1:]))
    elif len(arguments) == 3 and arguments[0] == "manifest":
        manifest(arguments[1], arguments[2])
    else:
        sys.exit(__doc__.strip().split("\n\n")[1])


if __name__ == "__main__":
    main(sys.argv[1:])
