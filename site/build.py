#!/usr/bin/env python3
"""Build the ClaraOS website into a directory.

usage: python3 -I site/build.py [out-dir]      (default: build/site)
       python3 -I site/build.py --sessions <dir>

The pages are site/index.html and site/manual.html, the user manual, with
their {{...}} marks filled in from the repository, so that the site cannot
fall behind it:

  {{version}}
      CLARA_VERSION in kernel/kernel.h
  {{done}} {{total}} {{latest}} {{roadmap}}
      from the milestone list in ROADMAP.md
  {{screenshot}}
      the version that site/boot.png is a picture of, which is written in
      the picture itself (below)
  {{spleen:some text}}
      the text drawn with the console's font, fonts/spleen-8x16.bdf, one
      inline SVG per word
  {{style}}
      in the manual: the style sheet of site/index.html, which the two
      pages share

       python3 -I site/build.py --screenshot <png> <serial log>

The manual cannot fall behind either, in two ways. Every name that the
system gives a meaning, the special forms and the functions in C
(kernel/lisp/eval.c, builtin.c, symbol.c), what lisp/boot.lisp exports,
and what the package of every other file in lisp/ exports, has to be in
one of the manual's lists of names, the elements of the class "names", and
nothing else may be in one: a function that is added without a word in the
manual stops the build, and so does a word about one that is gone. And
what the manual shows of the prompt is typed at a kernel:
--sessions writes the manual's transcripts, the <pre> elements of the
class "session", out as sessions for tools/boottest.sh, manual-first.txt
for a machine that has just started and manual-again.txt for the same
machine started again from the world that the first session saved (the
class "session again"), and `make test` boots both.

Nor can the picture on the front page, site/boot.png, which is what a
screen showed at the end of `make test`. --screenshot makes it of such a
screenshot and writes into it, as a line of text that a PNG file can
carry, the version that the machine named in the first line of its report
on the serial port. The site is not built from a picture of another
version than the kernel's: `make test` and `make screenshot` go with
every change of version.

Run by `make site` and by .github/workflows/site.yml, which publishes the
result on GitHub Pages. Only the standard library is used.
"""
import glob
import html
import os
import re
import shutil
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def load_font(text):
    """A BDF font as {code point: [(x, y, run length), ...]}, y counted from the top of the cell."""
    glyphs, lines = {}, text.split("\n")
    ascent = code = box = None
    i = 0
    while i < len(lines):
        word = lines[i].split()
        if word[:1] == ["FONTBOUNDINGBOX"]:
            ascent = int(word[2]) + int(word[4])  # cell height plus the (negative) descent
        elif word[:1] == ["ENCODING"]:
            code = int(word[1])
        elif word[:1] == ["BBX"]:
            box = [int(n) for n in word[1:5]]  # width, height, x offset, y offset
        elif word[:1] == ["BITMAP"]:
            runs, top = [], ascent - (box[1] + box[3])
            for row in range(box[1]):
                i += 1
                digits = lines[i].strip()
                bits = bin(int(digits, 16))[2:].zfill(len(digits) * 4)[:box[0]]
                for run in re.finditer("1+", bits):
                    runs.append((box[2] + run.start(), top + row, len(run.group())))
            glyphs[code] = runs
        i += 1
    return glyphs


def spleen(text, font):
    """Inline SVG for text. Each word is its own drawing so that a line can break between words."""
    words = []
    for word in text.split():
        path = "".join(f"M{8 * n + x} {y}h{length}v1h-{length}z"
                       for n, char in enumerate(word) for x, y, length in font[ord(char)])
        words.append(f'<svg style="--n:{len(word)}" viewBox="0 0 {8 * len(word)} 16" aria-hidden="true">'
                     f'<path d="{path}"/></svg>')
    return f'<span class="spleen" role="img" aria-label="{html.escape(text, quote=True)}">{"".join(words)}</span>'


def defined():
    """The names that the system gives a meaning as it starts, by package:
    the special forms, the functions in C whose names do not begin with a
    %, the symbols that the substrate makes external by hand, what
    lisp/boot.lisp exports, and what the package of each other file in
    lisp/ does."""
    names = {"COMMON-LISP": {"NIL"}, "CLARA": set(), "CLARA.UNSAFE": set()}
    evaluator, builtins = read("kernel", "lisp", "eval.c"), read("kernel", "lisp", "builtin.c")
    for name in re.findall(r'^    \{ "([^"]+)"', evaluator + builtins, flags=re.M):
        package, _, own = name.rpartition(":")
        if not own.startswith("%") and own != "QUASIQUOTE":
            names[package or "COMMON-LISP"].add(own)
    for source in (evaluator, read("kernel", "lisp", "symbol.c")):
        names["COMMON-LISP"].update(re.findall(r'lisp_symbol_in\((?:cl|lisp_roots\.common_lisp), "([^"]+)", 1\)', source))
    boot = read("lisp", "boot.lisp")
    language, _, clara = boot.partition('(in-package "CLARA")')
    for package, text in (("COMMON-LISP", language), ("CLARA", clara)):
        exports = re.search(r"\(export '\((.*?)\)\)", text, flags=re.S)
        if not exports:
            sys.exit(f"site/build.py: lisp/boot.lisp no longer says what it exports from {package}")
        names[package].update(word.upper() for word in exports.group(1).split())
    for path in sorted(glob.glob(os.path.join(ROOT, "lisp", "*.lisp"))):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for package, options in re.findall(r'^\(defpackage "([^"]+)"(.*?)^\(in-package', text, flags=re.M | re.S):
            exports = re.search(r"\(:export(.*?)\)\)", options, flags=re.S)
            names[package] = set(re.findall(r'"([^"]+)"', exports.group(1))) if exports else set()
    return names


def check_names(manual):
    """The manual's lists of names against what is defined: stops the build
    when a name is in one and not in the other."""
    listed = {}
    for package, block in re.findall(r'<p class="names"(?: data-package="([^"]+)")?>(.*?)</p>', manual, flags=re.S):
        package = package or "COMMON-LISP"
        for name in re.findall(r"<code>(.*?)</code>", block, flags=re.S):
            name = html.unescape(name).upper()
            if name.startswith(package + ":"):
                name = name[len(package) + 1:]
            listed.setdefault(package, set()).add(name)
    problems = []
    for package, names in sorted(defined().items()):
        missing, gone = names - listed.get(package, set()), listed.get(package, set()) - names
        if missing:
            problems.append(f"the manual has no word about {' '.join(sorted(missing))} of {package}")
        if gone:
            problems.append(f"the manual lists {' '.join(sorted(gone))} in {package}, and nothing defines that")
    if problems:
        sys.exit("site/build.py: site/manual.html is behind the kernel:\n  " + "\n  ".join(problems))


PNG = b"\x89PNG\r\n\x1a\n"


def png_chunks(data, name):
    """The chunks of a PNG file as [(type, data), ...]."""
    if data[:8] != PNG:
        sys.exit(f"site/build.py: {name} is not a PNG file")
    chunks, at = [], 8
    while at + 12 <= len(data):
        length, kind = struct.unpack(">I4s", data[at:at + 8])
        chunks.append((kind, data[at + 8:at + 8 + length]))
        at += 12 + length
    return chunks


def pictured(data, name):
    """The version that a picture says it is of, or None when it says none."""
    for kind, text in png_chunks(data, name):
        key, _, value = text.partition(b"\0")
        if kind == b"tEXt" and key == b"ClaraOS":
            return value.decode("latin-1")
    return None


def screenshot(picture, log):
    """site/boot.png, made of a screenshot of the boot test and of what the
    same machine wrote to its serial port, whose first line names the
    version: the picture carries it from then on."""
    with open(picture, "rb") as f:
        data = f.read()
    with open(log, encoding="utf-8", errors="replace") as f:
        version = re.search(r"^ClaraOS ([\d.]+) on ", f.read(), flags=re.M)
    if not version:
        sys.exit(f"site/build.py: {log} does not say which version of ClaraOS started")
    chunks = [chunk for chunk in png_chunks(data, picture) if chunk[0] != b"tEXt"]
    chunks.insert(1, (b"tEXt", b"ClaraOS\0" + version.group(1).encode("ascii")))
    with open(os.path.join(SITE, "boot.png"), "wb") as f:
        f.write(PNG)
        for kind, text in chunks:
            f.write(struct.pack(">I", len(text)) + kind + text + struct.pack(">I", zlib.crc32(kind + text)))
    print(f"wrote site/boot.png: the screen of version {version.group(1)}")


def sessions(manual):
    """What the manual shows of the prompt, as two sessions for
    tools/boottest.sh: of a machine that has just started, and of the same
    machine started again. A line that is the key Ctrl-C is the boot
    test's own line for it."""
    out = {"first": [], "again": []}
    for which, block in re.findall(r'<pre class="session( again)?">(.*?)</pre>', manual, flags=re.S):
        for line in block.strip("\n").split("\n"):
            if line.strip() == "<kbd>Ctrl-C</kbd>":
                out["again" if which else "first"].append("^C")
            else:
                out["again" if which else "first"].append(html.unescape(re.sub(r"<[^>]+>", "", line)))
    return out


def milestones(roadmap):
    """The milestone list of ROADMAP.md as [(group, [(code, title, version or None), ...]), ...]."""
    groups, lines = [], roadmap.split("\n")
    for n, line in enumerate(lines):
        if line.startswith(("Later", "Infrastructure")):
            break
        item = re.match(r"- \[(x| )\] \*\*(M\w+) (.+?)\.?\*\*(.*)", line)
        if item:
            done, code, title, rest = item.groups()
            version = re.search(r"version ([\d.]+)", rest) if done == "x" else None
            groups[-1][1].append((code, title, version.group(1) if version else None))
        elif line.endswith(":") and n + 2 < len(lines) and lines[n + 2].startswith("- ["):
            groups.append((line[:-1], []))
    return groups


def roadmap_html(groups):
    out = ['<div class="roadmap">']
    for group, items in groups:
        out.append(f"<div><h3>{html.escape(group)}</h3><ol>")
        for code, title, version in items:
            state = ' class="done"' if version else ""
            stamp = f'<span class="version">{version}</span>' if version else ""
            out.append(f"<li{state}><span>{code}</span><span>{html.escape(title)}</span>{stamp}</li>")
        out.append("</ol></div>")
    out.append("</div>")
    return "\n    ".join(out)


def main():
    manual = read("site", "manual.html")
    if sys.argv[1:2] == ["--screenshot"] and len(sys.argv) == 4:
        screenshot(sys.argv[2], sys.argv[3])
        return
    if sys.argv[1:2] == ["--sessions"] and len(sys.argv) == 3:
        os.makedirs(sys.argv[2], exist_ok=True)
        for name, lines in sessions(manual).items():
            if not lines:
                sys.exit(f"site/build.py: the manual shows nothing of the prompt for the session {name}")
            with open(os.path.join(sys.argv[2], f"manual-{name}.txt"), "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
        return
    check_names(manual)
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "site")
    groups = milestones(read("ROADMAP.md"))
    items = [item for _, group in groups for item in group]
    done = [item for item in items if item[2]]
    if len(items) < 10 or not done:
        sys.exit("site/build.py: could not find the milestone list in ROADMAP.md")
    font = load_font(read("fonts", "spleen-8x16.bdf"))

    version = re.search(r'#define CLARA_VERSION "([\d.]+)"', read("kernel", "kernel.h"))
    if not version:
        sys.exit("site/build.py: could not find CLARA_VERSION in kernel/kernel.h")

    with open(os.path.join(SITE, "boot.png"), "rb") as f:
        shown = pictured(f.read(), "site/boot.png")
    if shown != version.group(1):
        sys.exit(f"site/build.py: site/boot.png is a picture of {'version ' + shown if shown else 'no version that it names'},"
                 f" and the kernel is version {version.group(1)}: run `make test`, then `make screenshot`")

    values = {
        "version": version.group(1),
        "screenshot": shown,
        "done": str(len(done)),
        "total": str(len(items)),
        "latest": f"{done[-1][0]}, {done[-1][1]}",
        "roadmap": roadmap_html(groups),
    }
    index = read("site", "index.html")
    values["style"] = re.search(r"<style>\n(.*?)</style>", index, flags=re.S).group(1)
    os.makedirs(out, exist_ok=True)
    for name, page in (("index.html", index), ("manual.html", manual)):
        page = re.sub(r"<!-- The source of the ClaraOS .*?-->\n", "", page, count=1, flags=re.S)
        page = re.sub(r"\{\{(\w+)\}\}", lambda m: values[m.group(1)], page)
        page = re.sub(r"\{\{spleen:(.*?)\}\}", lambda m: spleen(m.group(1), font), page)
        with open(os.path.join(out, name), "w", encoding="utf-8") as f:
            f.write(page)
    for name in ("sun.png", "boot.png"):
        shutil.copyfile(os.path.join(SITE, name), os.path.join(out, name))
    print(f"wrote {out}: version {values['version']}, {values['done']} of {values['total']} milestones done")


if __name__ == "__main__":
    main()
