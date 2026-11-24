#!/usr/bin/env python3
"""A release of ClaraOS: a system as a directory that a web server hands
out, with a signature that says who made it.

A system is its files and a manifest that lists them, each with its length
and its SHA-512 (tools/system.py). A release is that directory as it is,
and beside the manifest a file manifest.sig: the Ed25519 signature of the
manifest's bytes, 128 digits in base sixteen. A system that fetches a
release holds the manifest against the signature, with the public half of
the key, which it has in it, and every file against the manifest
(lisp/system.lisp). So what a system takes does not depend on the road
by which the files came.

    releases/
      latest               one line: the name of the newest system there
      <name>/manifest      what tools/system.py wrote
      <name>/manifest.sig  the signature of those bytes
      <name>/<file>        every file that the manifest lists

Packages are published the same way (lisp/parker.lisp): a directory that
a web server hands out, with an index of what is there and a signature of
the index. A package is written as a directory of its name, with its
files and a file "package" that says what it is:

    package sun 1.0.0                 its name, which is the directory's, and its version
    about The sun, in a window        what it is, in a line of 44 characters at the most
    system 0.0.52                     the oldest ClaraOS that it is for; this line and the next three are as many as are wanted
    needs another                     a package that is installed with it
    load disc.lisp                    a file that is loaded when it is installed, and into every world after that
    application sun.lisp Sun          a name for the launcher's list, and the file that defines the application

The index has those lines for every package, and after them a line for
each of its files, with the file's length and its SHA-512:

    packages/
      index                      "ClaraOS packages", and then what there is
      index.sig                  the signature of those bytes
      <name>/<version>/<file>    every file that the index lists

usage: release.py key <file>              a new key: the secret half goes into the file, the public half is printed
       release.py public <file>           the public half of the key in that file
       release.py sign <file> <what>      the signature of the file <what>, with the key in <file>, printed
       release.py verify <public> <what> <signature>
       release.py make <system directory> <releases directory> <key file> [<public>]
                                          the system becomes the newest release there; with a public half,
                                          only when the key is the one that it is the half of
       release.py packages <directory of packages> <where> <key file> [<public>]
                                          the packages of that directory are laid out in <where>, which is made
                                          anew, with their index and its signature; with a public half, as above

The key file holds the secret half: 64 digits in base sixteen, and nothing
else. Whoever has it can publish a ClaraOS that every machine takes for
the real one, so it stays with whoever publishes and goes into no
repository.

Ed25519 is written out here, after RFC 8032 (section 6 has it in Python,
which this follows), because Python has SHA-512 and big numbers and
nothing else of it, and a build should need no more than Python. It signs
a manifest in a few milliseconds and is not made to keep a secret from
somebody who can time it: sign where nobody is watching.
"""
import hashlib
import os
import re
import shutil
import sys

P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
ROOT_OF_MINUS_ONE = pow(2, (P - 1) // 4, P)


def sha512(data):
    return hashlib.sha512(data).digest()


def inverse(x):
    return pow(x, P - 2, P)


def recover_x(y, sign):
    """The x of the point with that y whose lowest bit is SIGN, or None."""
    if y >= P:
        return None
    x2 = (y * y - 1) * inverse(D * y * y + 1) % P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * ROOT_OF_MINUS_ONE % P
    if (x * x - x2) % P != 0:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


BASE_Y = 4 * inverse(5) % P
BASE_X = recover_x(BASE_Y, 0)
BASE = (BASE_X, BASE_Y, 1, BASE_X * BASE_Y % P)


def add(p, q):
    a = (p[1] - p[0]) * (q[1] - q[0]) % P
    b = (p[1] + p[0]) * (q[1] + q[0]) % P
    c = 2 * p[3] * q[3] * D % P
    d = 2 * p[2] * q[2] % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def multiply(s, p):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = add(q, p)
        p = add(p, p)
        s >>= 1
    return q


def same(p, q):
    return (p[0] * q[2] - q[0] * p[2]) % P == 0 and (p[1] * q[2] - q[1] * p[2]) % P == 0


def compress(p):
    z = inverse(p[2])
    x, y = p[0] * z % P, p[1] * z % P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % P)


def expand(secret):
    h = sha512(secret)
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_of(secret):
    a, _ = expand(secret)
    return compress(multiply(a, BASE))


def sign(secret, message):
    a, prefix = expand(secret)
    public = compress(multiply(a, BASE))
    r = int.from_bytes(sha512(prefix + message), "little") % L
    first = compress(multiply(r, BASE))
    h = int.from_bytes(sha512(first + public + message), "little") % L
    return first + ((r + h * a) % L).to_bytes(32, "little")


def verify(public, message, signature):
    if len(public) != 32 or len(signature) != 64:
        return False
    a = decompress(public)
    r = decompress(signature[:32])
    s = int.from_bytes(signature[32:], "little")
    if a is None or r is None or s >= L:
        return False
    h = int.from_bytes(sha512(signature[:32] + public + message), "little") % L
    return same(multiply(s, BASE), add(r, multiply(h, a)))


def limbs(x):
    """A number as sixteen pieces of sixteen bits, the lowest first: how kernel/ed25519.c writes one."""
    return ", ".join("0x%04x" % ((x >> (16 * i)) & 0xffff) for i in range(16))


def read_key(path):
    text = open(path).read().strip()
    if len(text) != 64:
        sys.exit("release.py: %s does not hold a key: 64 digits in base sixteen" % path)
    return bytes.fromhex(text)


def described(directory, name):
    """What the file "package" of a package's directory says, as lines, when
    every line is what lisp/parker.lisp takes such a line to be; and the
    names of the package's files. Whatever is wrong ends the run: a package
    that no machine would install is not published."""
    def wrong(what):
        sys.exit("release.py: %s: %s" % (os.path.join(directory, "package"), what))

    def file_name(text):
        return re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}", text) and text.lower() != "package"

    path = os.path.join(directory, "package")
    if not os.path.isfile(path):
        sys.exit("release.py: %s has no file \"package\" that says what it is" % directory)
    files = sorted(entry for entry in os.listdir(directory) if entry != "package" and not entry.startswith("."))
    for entry in files:
        if not os.path.isfile(os.path.join(directory, entry)) or not file_name(entry):
            sys.exit("release.py: %s is not something that a package can have: a file, with a name of letters, digits, "
                     "\".\", \"-\" and \"_\"" % os.path.join(directory, entry))
    if len(set(entry.lower() for entry in files)) != len(files):
        sys.exit("release.py: %s has two files whose names differ in nothing but the case of their letters" % directory)
    lines = open(path, encoding="utf-8").read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    first = lines[0].split(" ") if lines else []
    if len(first) != 3 or first[0] != "package":
        wrong("its first line is not \"package <name> <version>\"")
    if first[1] != name or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", name):
        wrong("the package is named %s, and its directory %s: one name, of small letters, digits and hyphens" % (first[1], name))
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", first[2]) or len(first[2]) > 24:
        wrong("%s is no version: numbers with dots between them" % first[2])
    said = {"about": 0}
    needs, titles = [], []
    for line in lines[1:]:
        word, _, rest = line.partition(" ")
        if word == "about":
            if not rest.strip() or len(rest) > 44:
                wrong("what the package is, is said in 44 characters at the most, which is what a row of Parker's window "
                      "has room for: \"about ...\"")
            said["about"] += 1
        elif word == "system" and re.fullmatch(r"[0-9]+(\.[0-9]+)*", rest):
            pass
        elif word == "needs" and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", rest) and rest != name and rest not in needs:
            needs.append(rest)
        elif word == "load" and rest in files:
            pass
        elif word == "application" and rest.partition(" ")[0] in files and 0 < len(rest.partition(" ")[2]) <= 40 \
                and not rest.partition(" ")[2].startswith(" ") and rest.partition(" ")[2].lower() not in titles:
            titles.append(rest.partition(" ")[2].lower())
        else:
            wrong("\"%s\" is no line of a package: about, system, needs, load and application are, each with what it "
                  "names, and a file that is named is one of the directory's" % line)
    if said["about"] != 1:
        wrong("it has to say what the package is, once: \"about ...\"")
    return lines, files


def packages(source, where, key):
    """The packages of the directory SOURCE, laid out in WHERE, which is made anew."""
    source, where = os.path.realpath(source), os.path.realpath(where)
    if where == source or where.startswith(source + os.sep) or source.startswith(where + os.sep):
        sys.exit("release.py: %s is laid out somewhere else than in itself: %s is made anew" % (source, where))
    names = sorted(entry for entry in os.listdir(source)
                   if os.path.isdir(os.path.join(source, entry)) and not entry.startswith("."))
    index, laid = ["ClaraOS packages"], []
    shutil.rmtree(where, ignore_errors=True)
    os.makedirs(where)
    for name in names:
        lines, files = described(os.path.join(source, name), name)
        version = lines[0].split(" ")[2]
        to = os.path.join(where, name, version)
        os.makedirs(to)
        index.extend(lines)
        for entry in files:
            data = open(os.path.join(source, name, entry), "rb").read()
            index.append("file %d %s %s" % (len(data), hashlib.sha512(data).hexdigest(), entry))
            shutil.copyfile(os.path.join(source, name, entry), os.path.join(to, entry))
        laid.append("%s %s" % (name, version))
    text = ("\n".join(index) + "\n").encode()
    with open(os.path.join(where, "index"), "wb") as out:
        out.write(text)
    with open(os.path.join(where, "index.sig"), "w") as out:
        out.write(sign(key, text).hex() + "\n")
    print("%s in %s, signed by %s%s" % ("1 package is laid out" if len(laid) == 1 else "%d packages are laid out" % len(laid),
                                         where, public_of(key).hex(), ": " + ", ".join(laid) if laid else ""))


def main(argv):
    if len(argv) == 3 and argv[1] == "key":
        if os.path.exists(argv[2]):
            sys.exit("release.py: there is a file %s already, and a key is not written over" % argv[2])
        secret = os.urandom(32)
        with open(os.open(argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as out:
            out.write(secret.hex() + "\n")
        print(public_of(secret).hex())
    elif len(argv) == 3 and argv[1] == "public":
        print(public_of(read_key(argv[2])).hex())
    elif len(argv) == 4 and argv[1] == "sign":
        print(sign(read_key(argv[2]), open(argv[3], "rb").read()).hex())
    elif len(argv) == 5 and argv[1] == "verify":
        good = verify(bytes.fromhex(argv[2]), open(argv[3], "rb").read(), bytes.fromhex(open(argv[4]).read().strip()))
        print("the signature is that key's" if good else "the signature is not that key's of that file")
        sys.exit(0 if good else 1)
    elif len(argv) in (5, 6) and argv[1] == "make":
        system, releases, key = argv[2].rstrip("/"), argv[3], read_key(argv[4])
        # A release that is signed with another key than the one that the
        # systems have is taken by none of them: where the caller says
        # which key that is, nothing is laid out with another.
        if len(argv) == 6 and public_of(key).hex() != argv[5]:
            sys.exit("release.py: the key in %s has the public half %s, and not \"%s\", which is the one to hold it against: "
                     "nothing is laid out" % (argv[4], public_of(key).hex(), argv[5]))
        manifest = open(os.path.join(system, "manifest"), "rb").read()
        first = manifest.split(b"\n", 1)[0].decode()
        if not first.startswith("ClaraOS system: "):
            sys.exit("release.py: %s/manifest does not begin as the manifest of a system" % system)
        name = first[len("ClaraOS system: "):]
        to = os.path.join(releases, name)
        shutil.rmtree(to, ignore_errors=True)
        os.makedirs(to)
        for line in manifest.decode().split("\n")[1:]:
            fields = line.split(" ", 3)
            if len(fields) == 4 and fields[0] == "file":
                shutil.copyfile(os.path.join(system, fields[3]), os.path.join(to, fields[3]))
        shutil.copyfile(os.path.join(system, "manifest"), os.path.join(to, "manifest"))
        with open(os.path.join(to, "manifest.sig"), "w") as out:
            out.write(sign(key, manifest).hex() + "\n")
        with open(os.path.join(releases, "latest"), "w") as out:
            out.write(name + "\n")
        print("%s is the newest release in %s, signed by %s" % (name, releases, public_of(key).hex()))
    elif len(argv) in (5, 6) and argv[1] == "packages":
        key = read_key(argv[4])
        if len(argv) == 6 and public_of(key).hex() != argv[5]:
            sys.exit("release.py: the key in %s has the public half %s, and not \"%s\", which is the one to hold it against: "
                     "nothing is laid out" % (argv[4], public_of(key).hex(), argv[5]))
        packages(argv[2], argv[3], key)
    elif len(argv) == 2 and argv[1] == "constants":
        # What kernel/ed25519.c has as numbers: worked out here, and held against what is written there.
        print("D  = {%s}" % limbs(D))
        print("D2 = {%s}" % limbs(2 * D % P))
        print("X  = {%s}" % limbs(BASE_X))
        print("Y  = {%s}" % limbs(BASE_Y))
        print("I  = {%s}" % limbs(ROOT_OF_MINUS_ONE))
        print("L  = {%s}" % ", ".join("0x%02x" % b for b in L.to_bytes(32, "little")))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
