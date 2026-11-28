#!/usr/bin/env python3
"""The characters that are emoji, as lisp/draw.lisp has them.

usage: tools/emoji.py emoji-data.txt

Reads Unicode's emoji-data.txt (https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt)
and prints the table *EMOJI* of lisp/draw.lisp: the first and the last code
of every run of characters that have the property Emoji, from U+2000 on.
The ones below that are the digits, # and *, which are emoji only as the
first of a sequence, and the signs for a copyright and a registered mark,
which every font of letters has.
"""
import sys

LOWEST = 0x2000
ACROSS = 8


def main(path):
    version = None
    emoji = set()
    with open(path, encoding="utf-8") as data:
        for line in data:
            if line.startswith("# Version:"):
                version = line.split(":")[1].strip()
            line = line.split("#")[0].strip()
            if not line:
                continue
            codes, name = [part.strip() for part in line.split(";")]
            if name != "Emoji":
                continue
            first, _, last = codes.partition("..")
            emoji.update(range(int(first, 16), int(last or first, 16) + 1))
    runs = []
    for code in sorted(code for code in emoji if code >= LOWEST):
        if runs and runs[-1][1] == code - 1:
            runs[-1][1] = code
        else:
            runs.append([code, code])
    count = sum(last - first + 1 for first, last in runs)
    print(f";; Unicode {version}: {count} characters in {len(runs)} runs. Made by tools/emoji.py, and not by hand.")
    print("(defvar *emoji*")
    print("  #(", end="")
    for i, (first, last) in enumerate(runs):
        if i and i % ACROSS == 0:
            print("\n    ", end="")
        elif i:
            print(" ", end="")
        print(f"#x{first:X} #x{last:X}", end="")
    print("))")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
