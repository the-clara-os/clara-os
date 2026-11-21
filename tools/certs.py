#!/usr/bin/env python3
"""Certificates for a web server that keeps its connections closed (TLS),
for the boot test that fetches over HTTPS and for whoever serves a release
of their own from their own computer.

usage: certs.py <directory> <name>[:kind] ...

A certificate says whom a key belongs to, and is believed because somebody
who is trusted signed it. A machine trusts the certificates that its system
came with, which are the ones of the authorities that sign for the web
(lisp/roots.pem), and none of those signs for a server on this computer.
So this makes an authority of its own, the root, and has it sign for each
name. A ClaraOS that is told to trust the root (CLARA.TLS:TRUST) then
takes a server that shows one of these certificates for the machine of
that name.

    <directory>/root.pem     the root: what the machine is told to trust
    <directory>/<name>.pem   what a server shows as <name>: its own certificate first, then any signer in between
    <directory>/<name>.key   the key that goes with it, which the server keeps

A name's kind says what its certificate is like:

    (none)   a key on the curve P-256, signed by the root
    rsa      a key of RSA's, signed by a signer in between whose key is RSA's too, which the root signed
    large    a key on the curve P-256, signed by a signer in between whose key is on the larger curve, P-384
    old      like the first, and good until yesterday

The keys are made here and now, and are worth nothing: the root's is
thrown away when this ends, so nothing more can ever be signed with it,
and the others lie beside their certificates, readable by anybody. They
are for tests and for a server that is one's own.

Everything is written out here, like the signatures of tools/release.py:
Python has SHA-256 and big numbers, and a build should need no more than
Python. A certificate is pieces within pieces (ITU-T X.690); what is in
one is RFC 5280's; a signature on a curve is FIPS 186-5's, and one of
RSA's is RFC 8017's.
"""
import base64
import hashlib
import os
import sys
import time

class Curve:
    """One of the two curves that certificates are signed on (NIST SP 800-186): the points (x, y) with
    y*y = x*x*x - 3*x + b modulo p, of which g is the one that keys are made from, and n how many there are."""

    def __init__(self, p, b, g, n, name, sum):
        self.p, self.b, self.g, self.n = p, b, g, n
        self.bytes = (p.bit_length() + 7) // 8
        self.name, self.sum = name, sum  # how a certificate names the curve, and the sum that goes with it

    def add(self, a, b):
        """The sum of two points; None is no point at all."""
        p = self.p
        if a is None:
            return b
        if b is None:
            return a
        if a[0] == b[0]:
            if (a[1] + b[1]) % p == 0:
                return None
            slope = (3 * a[0] * a[0] - 3) * pow(2 * a[1], p - 2, p) % p
        else:
            slope = (b[1] - a[1]) * pow(b[0] - a[0], p - 2, p) % p
        x = (slope * slope - a[0] - b[0]) % p
        return (x, (slope * (a[0] - x) - a[1]) % p)

    def times(self, number, point):
        result = None
        while number:
            if number & 1:
                result = self.add(result, point)
            point = self.add(point, point)
            number >>= 1
        return result


P256 = Curve(0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff,
             0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b,
             (0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296,
              0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5),
             0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551,
             "2a8648ce3d030107", ("2a8648ce3d040302", hashlib.sha256))
P384 = Curve(0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff,
             0xb3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef,
             (0xaa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7,
              0x3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f),
             0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973,
             "2b81040022", ("2a8648ce3d040303", hashlib.sha384))


def number_below(limit):
    """A number from 1 up to the limit, which nobody can guess."""
    while True:
        number = int.from_bytes(os.urandom((limit.bit_length() + 7) // 8), "big")
        if 0 < number < limit:
            return number


def is_prime(n):
    for small in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97):
        if n % small == 0:
            return n == small
    odd, twos = n - 1, 0
    while odd % 2 == 0:
        odd //= 2
        twos += 1
    for _ in range(24):
        x = pow(number_below(n - 1) + 1, odd, n)
        if x in (1, n - 1):
            continue
        for _ in range(twos - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


def prime(bits):
    while True:
        n = int.from_bytes(os.urandom(bits // 8), "big") | (3 << (bits - 2)) | 1
        if is_prime(n):
            return n


class CurveKey:
    def __init__(self, curve=P256):
        self.curve = curve
        self.secret = number_below(curve.n)
        self.point = curve.times(self.secret, curve.g)

    def bytes(self):
        size = self.curve.bytes
        return b"\4" + self.point[0].to_bytes(size, "big") + self.point[1].to_bytes(size, "big")

    def written(self):
        return der(0x30, der(0x30, der(6, bytes.fromhex("2a8648ce3d0201")), der(6, bytes.fromhex(self.curve.name))), der(3, b"\0" + self.bytes()))

    def way(self):
        return der(0x30, der(6, bytes.fromhex(self.curve.sum[0])))

    def sign(self, what):
        curve = self.curve
        e = int.from_bytes(curve.sum[1](what).digest()[:curve.bytes], "big")
        while True:
            k = number_below(curve.n)
            r = curve.times(k, curve.g)[0] % curve.n
            s = pow(k, curve.n - 2, curve.n) * (e + r * self.secret) % curve.n
            if r and s:
                return der(0x30, der_number(r), der_number(s))

    def kept(self):
        """The key as a server keeps it (RFC 5915)."""
        return pem("EC PRIVATE KEY", der(0x30, der_number(1), der(4, self.secret.to_bytes(self.curve.bytes, "big")),
                                         der(0xa0, der(6, bytes.fromhex(self.curve.name))), der(0xa1, der(3, b"\0" + self.bytes()))))


class RSAKey:
    def __init__(self):
        while True:
            self.p, self.q = prime(1024), prime(1024)
            self.n = self.p * self.q
            if self.p != self.q and self.n.bit_length() == 2048:
                break
        self.e = 65537
        self.d = pow(self.e, -1, (self.p - 1) * (self.q - 1))

    def written(self):
        return der(0x30, der(0x30, der(6, bytes.fromhex("2a864886f70d010101")), der(5)),
                   der(3, b"\0" + der(0x30, der_number(self.n), der_number(self.e))))

    def way(self):
        return der(0x30, der(6, bytes.fromhex("2a864886f70d01010b")), der(5))

    def sign(self, what):
        which = bytes.fromhex("3031300d060960864801650304020105000420")
        block = b"\0\1" + b"\xff" * (256 - 3 - len(which) - 32) + b"\0" + which + hashlib.sha256(what).digest()
        return pow(int.from_bytes(block, "big"), self.d, self.n).to_bytes(256, "big")

    def kept(self):
        """The key as a server keeps it (RFC 8017, A.1.2)."""
        return pem("RSA PRIVATE KEY", der(0x30, der_number(0), der_number(self.n), der_number(self.e), der_number(self.d),
                                          der_number(self.p), der_number(self.q), der_number(self.d % (self.p - 1)),
                                          der_number(self.d % (self.q - 1)), der_number(pow(self.q, -1, self.p))))


def der(kind, *parts):
    inside = b"".join(parts)
    length = len(inside)
    if length < 128:
        return bytes([kind, length]) + inside
    if length < 256:
        return bytes([kind, 0x81, length]) + inside
    return bytes([kind, 0x82, length >> 8, length & 255]) + inside


def der_number(n):
    return der(2, n.to_bytes(n.bit_length() // 8 + 1, "big"))


def der_time(seconds):
    return der(23, time.strftime("%y%m%d%H%M%SZ", time.gmtime(seconds)).encode())


def der_name(text):
    return der(0x30, der(0x31, der(0x30, der(6, bytes.fromhex("55040a")), der(12, b"ClaraOS, for tests"))),
               der(0x31, der(0x30, der(6, bytes.fromhex("550403")), der(12, text.encode()))))


def pem(what, data):
    text = base64.b64encode(data).decode()
    return "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (what, "\n".join(text[i:i + 64] for i in range(0, len(text), 64)), what)


def certificate(subject, key, issuer, signer, begins, ends, names=(), authority=False):
    """A certificate for SUBJECT's key, signed by ISSUER with the key SIGNER: one that may sign
    certificates itself, or one for a server of those names."""
    if authority:
        more = (der(0x30, der(6, bytes.fromhex("551d13")), der(1, b"\xff"), der(4, der(0x30, der(1, b"\xff")))) +
                der(0x30, der(6, bytes.fromhex("551d0f")), der(1, b"\xff"), der(4, der(3, b"\1\6"))))
    else:
        more = (der(0x30, der(6, bytes.fromhex("551d13")), der(1, b"\xff"), der(4, der(0x30))) +
                der(0x30, der(6, bytes.fromhex("551d0f")), der(1, b"\xff"), der(4, der(3, b"\7\x80"))) +
                der(0x30, der(6, bytes.fromhex("551d25")), der(4, der(0x30, der(6, bytes.fromhex("2b06010505070301"))))) +
                der(0x30, der(6, bytes.fromhex("551d11")), der(4, der(0x30, *[der(0x82, name.encode()) for name in names]))))
    body = der(0x30, der(0xa0, der_number(2)), der_number(int.from_bytes(os.urandom(8), "big") | 1 << 62), signer.way(),
               der_name(issuer), der(0x30, der_time(begins), der_time(ends)), der_name(subject), key.written(),
               der(0xa3, der(0x30, more)))
    return der(0x30, body, signer.way(), der(3, b"\0" + signer.sign(body)))


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    directory, now, day = argv[1], int(time.time()), 86400
    os.makedirs(directory, exist_ok=True)
    root = CurveKey()
    root_name = "A root for one computer, made %s" % time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now))
    with open(os.path.join(directory, "root.pem"), "w") as out:
        out.write(pem("CERTIFICATE", certificate(root_name, root, root_name, root, now - day, now + 30 * day, authority=True)))
    for item in argv[2:]:
        name, _, kind = item.partition(":")
        if kind not in ("", "rsa", "large", "old") or not name or "/" in name or name == "root":
            sys.exit("certs.py: %s is no name with a kind that there is: none, rsa, large, old" % item)
        shown = []
        if kind in ("rsa", "large"):
            between, key = (RSAKey(), RSAKey()) if kind == "rsa" else (CurveKey(P384), CurveKey())
            between_name = "A signer in between, of %s" % root_name[2:]
            shown.append(certificate(name, key, between_name, between, now - day, now + 30 * day, names=[name]))
            shown.append(certificate(between_name, between, root_name, root, now - day, now + 30 * day, authority=True))
        else:
            key = CurveKey()
            ends = now - day if kind == "old" else now + 30 * day
            shown.append(certificate(name, key, root_name, root, now - 3 * day, ends, names=[name]))
        with open(os.path.join(directory, name + ".pem"), "w") as out:
            out.write("".join(pem("CERTIFICATE", one) for one in shown))
        with open(os.open(os.path.join(directory, name + ".key"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as out:
            out.write(key.kept())
    print("%s has a root and certificates for %s, good for thirty days" % (directory, ", ".join(item.partition(":")[0] for item in argv[2:])))


if __name__ == "__main__":
    main(sys.argv)
