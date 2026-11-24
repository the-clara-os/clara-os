#!/usr/bin/env python3
"""Chrome's word on what a page is: the trees of lisp/host/pages.lisp, made again.

usage: pagecheck.py [--write] [<file of pages>]

lisp/host/pages.lisp is a list of pages, each a text with the tree that a
browser makes of it, and lisp/host/tests.lisp holds the reader of
lisp/ares.lisp to those trees. They are not written by hand, and not by
that reader: they are what Chrome's parser makes of each text. This asks
Chrome again, for every page of the file, and says where its answer is not
the one that the file has; with --write the file gets Chrome's answers, so
a page that is new there is written with any tree at all, an empty string,
and this fills it in.

It is no part of `make test`: it needs Chrome, which CI has not. Run it by
hand after adding a page. CHROME= names the program when it is not where
macOS has it.

A tree is written as the tests write theirs: an element is (name
attribute="value" ... child ...), a text is "...", with \\n, \\t, \\\\,
\\" and \\u{hex} for what is not a plain character. Remarks are left out,
and the white space that a page has between its head and its body or
between the rows of a table. The parser asked is the one that reads a page
as it arrives (document.write): the quicker one behind DOMParser differs
from the standard where a name of a character stands in what a tag says.
"""
import base64
import html
import json
import os
import re
import subprocess
import sys
import tempfile

SCRIPT = r"""
const WS = /^[ \t\n\f\r]*$/;
const NOWS = new Set(['html','head','table','tbody','thead','tfoot','tr','colgroup']);
function q(s){ let o='"'; for (const ch of s){ const c=ch.codePointAt(0);
  if (ch==='\\') o+='\\\\'; else if (ch==='"') o+='\\"'; else if (c===10) o+='\\n'; else if (c===9) o+='\\t'; else if (c===13) o+='\\r';
  else if (c<32||c>126) o+='\\u{'+c.toString(16)+'}'; else o+=ch; } return o+'"'; }
function dump(el){
  const name = el.localName.toLowerCase();
  let o='('+name;
  for (const a of el.attributes) o+=' '+a.name.toLowerCase()+'='+q(a.value);
  const kids = (name==='template' && el.content) ? el.content.childNodes : el.childNodes;
  let text=null;
  const flush=()=>{ if(text!==null){ if(!(NOWS.has(name)&&WS.test(text))) o+=' '+q(text); text=null; } };
  for (const k of kids){
    if (k.nodeType===3){ text=(text===null?'':text)+k.data; }
    else if (k.nodeType===1){ flush(); o+=' '+dump(k); }
  }
  flush();
  return o+')';
}
function read(t){ const d = document.implementation.createHTMLDocument(''); d.open(); d.write(t); d.close(); return d; }
const bytes = Uint8Array.from(atob(DATA), c => c.charCodeAt(0));
const texts = JSON.parse(new TextDecoder().decode(bytes));
const lines = texts.map(t => dump(read(t).documentElement));
document.getElementById('out').textContent = navigator.userAgent.replace(/.*Chrome\/([0-9.]+).*/, '$1') + '\n' + lines.join('\n');
"""


def chrome_says(pages):
    """The version of Chrome, and the tree that it makes of each page."""
    program = os.environ.get("CHROME") or "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    with tempfile.TemporaryDirectory() as work:
        data = base64.b64encode(json.dumps(pages).encode()).decode()
        page = os.path.join(work, "pages.html")
        with open(page, "w") as out:
            out.write('<!DOCTYPE html><meta charset=utf-8><pre id=out></pre><script>const DATA="%s";%s</script>' % (data, SCRIPT))
        said = subprocess.run([program, "--headless=new", "--no-first-run", "--user-data-dir=" + os.path.join(work, "profile"),
                               "--virtual-time-budget=10000", "--dump-dom", "file://" + page],
                              capture_output=True, text=True, timeout=300).stdout
    found = re.search(r'<pre id="out">(.*?)</pre>', said, re.S)
    if not found:
        sys.exit("pagecheck: %s said nothing that could be read" % program)
    # what the browser wrote for &, < and > in its own text, and nothing else
    lines = found.group(1).replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&").split("\n")
    if len(lines) != len(pages) + 1:
        sys.exit("pagecheck: %d pages were asked about, and %d answers came" % (len(pages), len(lines) - 1))
    return lines[0], lines[1:]


def strings_of(text):
    """The strings of a file of Lisp, in their order, and what stands before the first parenthesis."""
    strings, at, head = [], 0, None
    while at < len(text):
        c = text[at]
        if c == ";":
            at = text.find("\n", at)
            at = len(text) if at < 0 else at
        elif c == '"':
            end, piece = at + 1, []
            while text[end] != '"':
                if text[end] == "\\":
                    end += 1
                piece.append(text[end])
                end += 1
            strings.append("".join(piece))
            at = end + 1
        else:
            if c == "(" and head is None:
                head = text[:at]
            at += 1
    return strings, head or ""


def written(string):
    return '"' + string.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main(argv):
    write = "--write" in argv
    names = [a for a in argv[1:] if a != "--write"]
    name = names[0] if names else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lisp", "host", "pages.lisp")
    with open(name, encoding="utf-8") as file:
        strings, head = strings_of(file.read())
    if len(strings) % 2:
        sys.exit("pagecheck: %s has a page without a tree, or a tree without a page" % name)
    pages, trees = strings[0::2], strings[1::2]
    version, says = chrome_says(pages)
    differ = 0
    for page, tree, said in zip(pages, trees, says):
        if tree != said:
            differ += 1
            print("page    %r\n  file    %s\n  chrome  %s" % (page, tree, said))
    print("pagecheck: Chrome %s, %d pages, %d of them with another tree than the file has" % (version, len(pages), differ))
    if write:
        head = re.sub(r"Chrome [0-9.]+", "Chrome " + version, head)
        with open(name, "w", encoding="utf-8") as file:
            file.write(head + "(")
            for number, (page, said) in enumerate(zip(pages, says)):
                file.write("%s(%s\n  %s)" % ("" if number == 0 else "\n ", written(page), written(said)))
            file.write(")\n")
        print("pagecheck: %s has Chrome's trees" % name)
    return 1 if differ and not write else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
