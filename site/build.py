#!/usr/bin/env python3
"""Build the ClaraOS website into a directory.

usage: python3 -I site/build.py [out-dir]      (default: build/site)

The page is site/index.html with its {{...}} marks filled in from the
repository, so that the site cannot fall behind it:

  {{version}} {{done}} {{total}} {{latest}} {{roadmap}}
      from the milestone list in ROADMAP.md
  {{spleen:some text}}
      the text drawn with the console's font, fonts/spleen-8x16.bdf, one
      inline SVG per word

Run by `make site` and by .github/workflows/site.yml, which publishes the
result on GitHub Pages. Only the standard library is used.
"""
import html
import os
import re
import shutil
import sys

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
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "site")
    groups = milestones(read("ROADMAP.md"))
    items = [item for _, group in groups for item in group]
    done = [item for item in items if item[2]]
    if len(items) < 10 or not done:
        sys.exit("site/build.py: could not find the milestone list in ROADMAP.md")
    font = load_font(read("fonts", "spleen-8x16.bdf"))

    values = {
        "version": done[-1][2],
        "done": str(len(done)),
        "total": str(len(items)),
        "latest": f"{done[-1][0]}, {done[-1][1]}",
        "roadmap": roadmap_html(groups),
    }
    page = read("site", "index.html")
    page = re.sub(r"<!-- The source of the ClaraOS website\..*?-->\n", "", page, count=1, flags=re.S)
    page = re.sub(r"\{\{(\w+)\}\}", lambda m: values[m.group(1)], page)
    page = re.sub(r"\{\{spleen:(.*?)\}\}", lambda m: spleen(m.group(1), font), page)

    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8") as f:
        f.write(page)
    for name in ("sun.png", "boot.png"):
        shutil.copyfile(os.path.join(SITE, name), os.path.join(out, name))
    print(f"wrote {out}: version {values['version']}, {values['done']} of {values['total']} milestones done")


if __name__ == "__main__":
    main()
