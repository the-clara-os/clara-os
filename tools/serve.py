#!/usr/bin/env python3
"""The other machine of a boot test that fetches something: a web server
for a directory, and somebody who knows names, both on this computer and
on one port, which is whatever port is free.

usage: serve.py <directory> <file to write the port's number to>

A machine under QEMU reaches this computer at 10.0.2.2, so what is served
here is http://10.0.2.2:<port>/ to it (tools/boottest.sh, SERVE=).

The web server hands out the files of the directory, and a few things
that are no files, for what a fetch has to cope with:

    /moved/<path>    is somewhere else: at /<path>
    /secure/<path>   is somewhere else: at an address that begins with https://
    /round           is somewhere else: at /round
    /unsized/<path>  the file, without saying how long it is, and the connection closed after it
    /short/<path>    the file, said to be longer than what is sent

The name server answers on the same port, by UDP: every name that ends in
".test" is this computer, 10.0.2.2, and any other name is said not to
exist. That is all of DNS that it knows.
"""
import http.server
import os
import socket
import socketserver
import struct
import sys
import threading


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

    def do_GET(self):
        self.close_connection = True
        if self.path.startswith("/moved/"):
            self.moved(self.path[len("/moved"):])
        elif self.path.startswith("/secure/"):
            self.moved("https://claraos.org" + self.path[len("/secure"):])
        elif self.path == "/round":
            self.moved("/round")
        elif self.path.startswith("/unsized/") or self.path.startswith("/short/"):
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
        else:
            super().do_GET()


class Web(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def names(port):
    """Answer questions for addresses: a name that ends in .test is 10.0.2.2, and no other name exists."""
    asked = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    asked.bind(("127.0.0.1", port))
    while True:
        try:
            question, who = asked.recvfrom(512)
            if len(question) < 17:
                continue
            number, flags, count = struct.unpack(">HHH", question[:6])
            at, labels = 12, []
            while at < len(question) and question[at]:
                labels.append(question[at + 1:at + 1 + question[at]].decode("ascii", "replace"))
                at += 1 + question[at]
            asked_for = question[12:at + 5]
            name = ".".join(labels).lower()
            sys.stderr.write("asked which address %s has\n" % name)
            sys.stderr.flush()
            if name.endswith(".test"):
                answer = struct.pack(">HHHHHH", number, 0x8180, 1, 1, 0, 0) + asked_for
                answer += b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + bytes([10, 0, 2, 2])
            else:
                answer = struct.pack(">HHHHHH", number, 0x8183, 1, 0, 0, 0) + asked_for
            asked.sendto(answer, who)
        except OSError:
            pass


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    directory = os.path.abspath(argv[1])
    handler = lambda *args, **more: Handler(*args, directory=directory, **more)
    web = Web(("127.0.0.1", 0), handler)
    port = web.server_address[1]
    threading.Thread(target=names, args=(port,), daemon=True).start()
    with open(argv[2] + ".new", "w") as out:
        out.write("%d\n" % port)
    os.replace(argv[2] + ".new", argv[2])
    web.serve_forever()


if __name__ == "__main__":
    main(sys.argv)
