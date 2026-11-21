#!/usr/bin/env python3
"""The other machine of a boot test that fetches something: a web server
for a directory, and somebody who knows names, both on this computer and
on one port, which is whatever port is free; and, when it is given
certificates, the same web server once more on another port, where it
keeps its connections closed (TLS).

usage: serve.py <directory> <file to write the ports' numbers to> [<directory of certificates>]

A machine under QEMU reaches this computer at 10.0.2.2, so what is served
here is http://10.0.2.2:<port>/ to it, and https://<name>:<other port>/ for
every name that the certificates are for (tools/boottest.sh, SERVE= and
CERTS=). The file gets the two ports' numbers on one line, the second
being 0 without certificates.

The web server hands out the files of the directory, and a few things
that are no files, for what a fetch has to cope with:

    /moved/<path>    is somewhere else: at /<path>
    /secure/<path>   is somewhere else: at https://releases.test:<other port>/<path>
    /open/<path>     is somewhere else: at http://releases.test:<port>/<path>, where nothing is kept closed
    /round           is somewhere else: at /round
    /unsized/<path>  the file, without saying how long it is, and the connection ended after it
    /cut/<path>      the same, and the connection only dropped: on a closed one, without the word that it is over
    /short/<path>    the file, said to be longer than what is sent

The certificates are the ones that tools/certs.py makes: for each name a
file <name>.pem with what the server shows and <name>.key with its key.
Which of them a connection gets is said by the name that the other side
asks for as it greets (RFC 6066, 3); one that asks for no name, or for a
name that there is no certificate for, gets the one for releases.test,
or the first that there is.

The name server answers on the first port, by UDP: every name that ends
in ".test" is this computer, 10.0.2.2, and any other name is said not to
exist. A name that begins with "long." gets an answer that says of
itself that it was cut short, as one does that is too long for a packet
of UDP's, and its whole answer only by TCP, at the same port: a question
that comes that way begins with its length, in two bytes, where a
request of HTTP's begins with a word, and the web server tells the two
apart by that. That is all of DNS that it knows.
"""
import http.server
import os
import socket
import socketserver
import ssl
import struct
import sys
import threading

PORTS = [0, 0]  # the port where nothing is kept closed, and the one where everything is


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        sys.stderr.write("%s\n" % (format % args))
        sys.stderr.flush()

    def moved(self, to):
        self.send_response(301)
        self.send_header("Location", to)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def handle(self):
        if not isinstance(self.connection, ssl.SSLSocket):
            try:
                first = self.connection.recv(2, socket.MSG_PEEK)
            except OSError:
                first = b""
            if len(first) == 2 and not first.isalpha():
                self.name_by_tcp()
                return
        super().handle()

    def name_by_tcp(self):
        """A question about a name, with its length before it, and the answer likewise (RFC 7766)."""
        try:
            length = struct.unpack(">H", self.rfile.read(2))[0]
            said = answer(self.rfile.read(length), True)
            if said:
                self.wfile.write(struct.pack(">H", len(said)) + said)
                self.wfile.flush()
        except (OSError, struct.error):
            pass

    def do_GET(self):
        self.close_connection = True
        if self.path.startswith("/moved/"):
            self.moved(self.path[len("/moved"):])
        elif self.path.startswith("/secure/"):
            self.moved("https://releases.test:%d%s" % (PORTS[1], self.path[len("/secure"):]))
        elif self.path.startswith("/open/"):
            self.moved("http://releases.test:%d%s" % (PORTS[0], self.path[len("/open"):]))
        elif self.path == "/round":
            self.moved("/round")
        elif self.path.startswith("/unsized/") or self.path.startswith("/short/") or self.path.startswith("/cut/"):
            kind, rest = self.path[1:].split("/", 1)
            try:
                data = open(os.path.join(self.directory, rest), "rb").read()
            except OSError:
                self.send_error(404)
                return
            self.send_response(200)
            if kind == "short":
                self.send_header("Content-Length", str(len(data) + 100))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            if kind == "unsized" and isinstance(self.connection, ssl.SSLSocket):
                # A file that is over when the connection is has to be ended with the word that says so,
                # or the other side cannot tell its end from a connection that somebody cut.
                self.wfile.flush()
                try:
                    self.connection.unwrap()
                except OSError:
                    pass
        else:
            super().do_GET()


class Web(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        # a greeting that the other side gave up, which a test does on purpose, is no news
        sys.stderr.write("a connection ended with an error: %s\n" % (sys.exc_info()[1],))
        sys.stderr.flush()


def closed(certificates):
    """What keeps the connections of the second server closed: one context for each name that has a
    certificate, and the first of them picks the one that a connection asks for by name."""
    contexts = {}
    for entry in sorted(os.listdir(certificates)):
        name, kind = os.path.splitext(entry)
        if kind == ".pem" and os.path.exists(os.path.join(certificates, name + ".key")):
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(os.path.join(certificates, entry), os.path.join(certificates, name + ".key"))
            contexts[name] = context
    if not contexts:
        sys.exit("serve.py: %s has no certificate with its key: tools/certs.py makes them" % certificates)
    first = contexts.get("releases.test") or contexts[sorted(contexts)[0]]

    def pick(connection, name, context):
        sys.stderr.write("greeted as %s\n" % name)
        sys.stderr.flush()
        if name in contexts:
            connection.context = contexts[name]

    first.sni_callback = pick
    return first


def answer(question, whole):
    """What the name server says to a question for an address: a name that ends in .test is 10.0.2.2, and
    no other name exists. One that begins with long. is too long to be said by UDP: WHOLE is whether the
    question came by TCP. None for what is no question."""
    if len(question) < 17:
        return None
    number, flags, count = struct.unpack(">HHH", question[:6])
    at, labels = 12, []
    while at < len(question) and question[at]:
        labels.append(question[at + 1:at + 1 + question[at]].decode("ascii", "replace"))
        at += 1 + question[at]
    asked_for = question[12:at + 5]
    name = ".".join(labels).lower()
    sys.stderr.write("asked which address %s has%s\n" % (name, ", by TCP" if whole else ""))
    sys.stderr.flush()
    if not name.endswith(".test"):
        return struct.pack(">HHHHHH", number, 0x8183, 1, 0, 0, 0) + asked_for
    if name.startswith("long.") and not whole:
        return struct.pack(">HHHHHH", number, 0x8380, 1, 0, 0, 0) + asked_for
    said = struct.pack(">HHHHHH", number, 0x8180, 1, 1, 0, 0) + asked_for
    return said + b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + bytes([10, 0, 2, 2])


def names(port):
    """Answer the questions for addresses that come by UDP."""
    asked = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    asked.bind(("127.0.0.1", port))
    while True:
        try:
            question, who = asked.recvfrom(512)
            said = answer(question, False)
            if said:
                asked.sendto(said, who)
        except OSError:
            pass


def main(argv):
    if len(argv) not in (3, 4):
        sys.exit(__doc__)
    directory = os.path.abspath(argv[1])
    handler = lambda *args, **more: Handler(*args, directory=directory, **more)
    web = Web(("127.0.0.1", 0), handler)
    PORTS[0] = web.server_address[1]
    threading.Thread(target=names, args=(PORTS[0],), daemon=True).start()
    if len(argv) == 4:
        secure = Web(("127.0.0.1", 0), handler)
        PORTS[1] = secure.server_address[1]
        secure.socket = closed(argv[3]).wrap_socket(secure.socket, server_side=True)
        threading.Thread(target=secure.serve_forever, daemon=True).start()
    with open(argv[2] + ".new", "w") as out:
        out.write("%d %d\n" % (PORTS[0], PORTS[1]))
    os.replace(argv[2] + ".new", argv[2])
    web.serve_forever()


if __name__ == "__main__":
    main(sys.argv)
