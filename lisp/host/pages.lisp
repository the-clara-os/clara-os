;;;; pages.lisp: pages, and the tree that a browser makes of each
;;;;
;;;; A list of pairs, a text and its tree, which lisp/host/tests.lisp reads
;;;; and holds the reader of lisp/ares.lisp to. The trees are what Chrome
;;;; 158.0.0.0 makes of the texts, written out by tools/pagecheck.py, which
;;;; says how a tree is written; nobody typed them, and the reader under
;;;; test did not make them. A page that is added here is added with an
;;;; empty tree, and `python3 tools/pagecheck.py --write` fills it in.

(("Hello"
  "(html (head) (body \"Hello\"))")
 ("<p>Hello <b>world</b>!</p>"
  "(html (head) (body (p \"Hello \" (b \"world\") \"!\")))")
 ("<P CLASS=Big ID='a b'>x</P>"
  "(html (head) (body (p class=\"Big\" id=\"a b\" \"x\")))")
 ("<p>a<br>b<br/>c</br>d"
  "(html (head) (body (p \"a\" (br) \"b\" (br) \"c\" (br) \"d\")))")
 ("a<hr>b<hr/>c"
  "(html (head) (body \"a\" (hr) \"b\" (hr) \"c\"))")
 ("<div><span>a</span><em>b <strong>c</strong></em></div>"
  "(html (head) (body (div (span \"a\") (em \"b \" (strong \"c\")))))")
 ("<i>a<b>b</b>c</i>d"
  "(html (head) (body (i \"a\" (b \"b\") \"c\") \"d\"))")
 ("<p>one</p>
<p>two</p>
"
  "(html (head) (body (p \"one\") \"\\n\" (p \"two\") \"\\n\"))")
 ("<a href=\"x.html\">link</a> and <a name=top>anchor</a>"
  "(html (head) (body (a href=\"x.html\" \"link\") \" and \" (a name=\"top\" \"anchor\")))")
 ("<img src=a.png alt=\"A picture\"><image src=b>"
  "(html (head) (body (img src=\"a.png\" alt=\"A picture\") (img src=\"b\")))")
 ("text <unknown-thing a=1>inside</unknown-thing> after"
  "(html (head) (body \"text \" (unknown-thing a=\"1\" \"inside\") \" after\"))")
 ("<blink>x<marquee>y</marquee></blink>"
  "(html (head) (body (blink \"x\" (marquee \"y\"))))")
 ("<font color=red>r</font><center>c</center>"
  "(html (head) (body (font color=\"red\" \"r\") (center \"c\")))")
 ("<!DOCTYPE html><html><head><title>T</title></head><body><p>x</p></body></html>"
  "(html (head (title \"T\")) (body (p \"x\")))")
 ("<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<title>A title</title>
<link rel=stylesheet href=s.css>
</head>
<body>
<h1>Head</h1>
</body>
</html>
"
  "(html lang=\"en\" (head (meta charset=\"utf-8\") (title \"A title\") (link rel=\"stylesheet\" href=\"s.css\")) (body \"\\n\" (h1 \"Head\") \"\\n\\n\\n\"))")
 ("<title>only a title</title>"
  "(html (head (title \"only a title\")) (body))")
 ("<title>T</title>text"
  "(html (head (title \"T\")) (body \"text\"))")
 ("<meta charset=utf-8><p>x"
  "(html (head (meta charset=\"utf-8\")) (body (p \"x\")))")
 ("  
 <p>x"
  "(html (head) (body (p \"x\")))")
 ("x<title>late</title>y"
  "(html (head) (body \"x\" (title \"late\") \"y\"))")
 ("<head><base href=/x/></head>text"
  "(html (head (base href=\"/x/\")) (body \"text\"))")
 ("<html a=1><html b=2 a=3><body c=4><body d=5 c=6>x"
  "(html a=\"1\" b=\"2\" (head) (body c=\"4\" d=\"5\" \"x\"))")
 ("<body>a</body>b"
  "(html (head) (body \"ab\"))")
 ("<body>a</body></html>b"
  "(html (head) (body \"ab\"))")
 ("<head></head><script>s</script><body>x"
  "(html (head (script \"s\")) (body \"x\"))")
 ("<link href=a><style>b{}</style><script>c</script><p>d"
  "(html (head (link href=\"a\") (style \"b{}\") (script \"c\")) (body (p \"d\")))")
 ("<head><noscript><link href=a></noscript></head><body>x"
  "(html (head (noscript (link href=\"a\"))) (body \"x\"))")
 ("<head><noscript><img src=a></noscript></head><p>y"
  "(html (head (noscript)) (body (img src=\"a\") (p \"y\")))")
 ("</head>x"
  "(html (head) (body \"x\"))")
 ("<html><body>"
  "(html (head) (body))")
 (""
  "(html (head) (body))")
 ("   "
  "(html (head) (body))")
 ("<body class=a>"
  "(html (head) (body class=\"a\"))")
 ("<p>a</p></body>
</html>
"
  "(html (head) (body (p \"a\") \"\\n\\n\"))")
 ("<head>x</head>y"
  "(html (head) (body \"xy\"))")
 ("<head><title>a</title></head> <body> b </body>"
  "(html (head (title \"a\")) (body \" b \"))")
 ("<p>a<div>b"
  "(html (head) (body (p \"a\") (div \"b\")))")
 ("<p>a<p>b"
  "(html (head) (body (p \"a\") (p \"b\")))")
 ("<p>a<ul>b"
  "(html (head) (body (p \"a\") (ul \"b\")))")
 ("<p>a<ol>b"
  "(html (head) (body (p \"a\") (ol \"b\")))")
 ("<p>a<dl>b"
  "(html (head) (body (p \"a\") (dl \"b\")))")
 ("<p>a<pre>b"
  "(html (head) (body (p \"a\") (pre \"b\")))")
 ("<p>a<table><tr><td>b"
  "(html (head) (body (p \"a\" (table (tbody (tr (td \"b\")))))))")
 ("<p>a<h1>b"
  "(html (head) (body (p \"a\") (h1 \"b\")))")
 ("<p>a<h3>b"
  "(html (head) (body (p \"a\") (h3 \"b\")))")
 ("<p>a<blockquote>b"
  "(html (head) (body (p \"a\") (blockquote \"b\")))")
 ("<p>a<form>b"
  "(html (head) (body (p \"a\") (form \"b\")))")
 ("<p>a<hr>b"
  "(html (head) (body (p \"a\") (hr) \"b\"))")
 ("<p>a<section>b"
  "(html (head) (body (p \"a\") (section \"b\")))")
 ("<p>a<article>b"
  "(html (head) (body (p \"a\") (article \"b\")))")
 ("<p>a<nav>b"
  "(html (head) (body (p \"a\") (nav \"b\")))")
 ("<p>a<header>b"
  "(html (head) (body (p \"a\") (header \"b\")))")
 ("<p>a<footer>b"
  "(html (head) (body (p \"a\") (footer \"b\")))")
 ("<p>a<main>b"
  "(html (head) (body (p \"a\") (main \"b\")))")
 ("<p>a<aside>b"
  "(html (head) (body (p \"a\") (aside \"b\")))")
 ("<p>a<address>b"
  "(html (head) (body (p \"a\") (address \"b\")))")
 ("<p>a<fieldset>b"
  "(html (head) (body (p \"a\") (fieldset \"b\")))")
 ("<p>a<figure>b"
  "(html (head) (body (p \"a\") (figure \"b\")))")
 ("<p>a<figcaption>b"
  "(html (head) (body (p \"a\") (figcaption \"b\")))")
 ("<p>a<details>b"
  "(html (head) (body (p \"a\") (details \"b\")))")
 ("<p>a<summary>b"
  "(html (head) (body (p \"a\") (summary \"b\")))")
 ("<p>a<center>b"
  "(html (head) (body (p \"a\") (center \"b\")))")
 ("<p>a<menu>b"
  "(html (head) (body (p \"a\") (menu \"b\")))")
 ("<p>a<dir>b"
  "(html (head) (body (p \"a\") (dir \"b\")))")
 ("<p>a<listing>b"
  "(html (head) (body (p \"a\") (listing \"b\")))")
 ("<p>a<hgroup>b"
  "(html (head) (body (p \"a\") (hgroup \"b\")))")
 ("<p>a<dialog>b"
  "(html (head) (body (p \"a\") (dialog \"b\")))")
 ("<p>a<search>b"
  "(html (head) (body (p \"a\") (search \"b\")))")
 ("<!DOCTYPE html><p>a<table><tr><td>b</table>c"
  "(html (head) (body (p \"a\") (table (tbody (tr (td \"b\")))) \"c\"))")
 ("<!doctype html><title>t</title><p>a<table><tr><td>b"
  "(html (head (title \"t\")) (body (p \"a\") (table (tbody (tr (td \"b\"))))))")
 ("<p>a<span>b<div>c</div>d"
  "(html (head) (body (p \"a\" (span \"b\")) (div \"c\") \"d\"))")
 ("<p>a</p></p>b"
  "(html (head) (body (p \"a\") (p) \"b\"))")
 ("x</p>y"
  "(html (head) (body \"x\" (p) \"y\"))")
 ("<div></p></div>"
  "(html (head) (body (div (p))))")
 ("<p><b>a</b><p><i>b"
  "(html (head) (body (p (b \"a\")) (p (i \"b\"))))")
 ("<p>a<li>b"
  "(html (head) (body (p \"a\") (li \"b\")))")
 ("<p>a<dd>b"
  "(html (head) (body (p \"a\") (dd \"b\")))")
 ("<button><p>a</button>b"
  "(html (head) (body (button (p \"a\")) \"b\"))")
 ("<p>a<button>b<p>c</button>d"
  "(html (head) (body (p \"a\" (button \"b\" (p \"c\")) \"d\")))")
 ("<div><p>a</div>b"
  "(html (head) (body (div (p \"a\")) \"b\"))")
 ("<ul><li>a<li>b<li>c</ul>"
  "(html (head) (body (ul (li \"a\") (li \"b\") (li \"c\"))))")
 ("<ul><li>a<ul><li>b<li>c</ul><li>d</ul>"
  "(html (head) (body (ul (li \"a\" (ul (li \"b\") (li \"c\"))) (li \"d\"))))")
 ("<ol start=3><li>a</li><li>b</li></ol>"
  "(html (head) (body (ol start=\"3\" (li \"a\") (li \"b\"))))")
 ("<li>a<li>b"
  "(html (head) (body (li \"a\") (li \"b\")))")
 ("<ul><li>a</li>x<li>b</ul>"
  "(html (head) (body (ul (li \"a\") \"x\" (li \"b\"))))")
 ("<ul><li><p>a<li><p>b</ul>"
  "(html (head) (body (ul (li (p \"a\")) (li (p \"b\")))))")
 ("<ul><li><div>a<li>b</div></ul>"
  "(html (head) (body (ul (li (div \"a\")) (li \"b\"))))")
 ("<dl><dt>a<dd>b<dt>c<dd>d</dl>"
  "(html (head) (body (dl (dt \"a\") (dd \"b\") (dt \"c\") (dd \"d\"))))")
 ("<dl><dd>a<dd>b<dt>c</dl>"
  "(html (head) (body (dl (dd \"a\") (dd \"b\") (dt \"c\"))))")
 ("<ul><li>a</ul></li>b"
  "(html (head) (body (ul (li \"a\")) \"b\"))")
 ("<ul><li>a</li></li>b</ul>"
  "(html (head) (body (ul (li \"a\") \"b\")))")
 ("<ol><li>a<ul><li>b</ol>c"
  "(html (head) (body (ol (li \"a\" (ul (li \"b\")))) \"c\"))")
 ("<li><span>a<li>b"
  "(html (head) (body (li (span \"a\")) (li \"b\")))")
 ("<ul><li><address>a<li>b</ul>"
  "(html (head) (body (ul (li (address \"a\")) (li \"b\"))))")
 ("<dd>a</dd><dt>b</dt>c"
  "(html (head) (body (dd \"a\") (dt \"b\") \"c\"))")
 ("x</li>y</dd>z</dt>"
  "(html (head) (body \"xyz\"))")
 ("<h1>a<h2>b"
  "(html (head) (body (h1 \"a\") (h2 \"b\")))")
 ("<h1>a</h2>b"
  "(html (head) (body (h1 \"a\") \"b\"))")
 ("<h1><span>a</h3>b"
  "(html (head) (body (h1 (span \"a\")) \"b\"))")
 ("<h2>a</h2><h3>b</h3>"
  "(html (head) (body (h2 \"a\") (h3 \"b\")))")
 ("<h1>a<div><h2>b</h2></div>c</h1>"
  "(html (head) (body (h1 \"a\" (div (h2 \"b\")) \"c\")))")
 ("x</h1>y"
  "(html (head) (body \"xy\"))")
 ("<h1><p>a</h1>b"
  "(html (head) (body (h1 (p \"a\")) \"b\"))")
 ("<h4>a<p>b</h4>c"
  "(html (head) (body (h4 \"a\" (p \"b\")) \"c\"))")
 ("<table><tr><td>a<td>b<tr><td>c</table>"
  "(html (head) (body (table (tbody (tr (td \"a\") (td \"b\")) (tr (td \"c\"))))))")
 ("<table><td>a</table>"
  "(html (head) (body (table (tbody (tr (td \"a\"))))))")
 ("<table><tr><th>h<td>d</tr><tr><td>x</td></tr></table>"
  "(html (head) (body (table (tbody (tr (th \"h\") (td \"d\")) (tr (td \"x\"))))))")
 ("<table><thead><tr><th>a<tbody><tr><td>b<tfoot><tr><td>c</table>"
  "(html (head) (body (table (thead (tr (th \"a\"))) (tbody (tr (td \"b\"))) (tfoot (tr (td \"c\"))))))")
 ("<table><caption>c<tr><td>d</table>"
  "(html (head) (body (table (caption \"c\") (tbody (tr (td \"d\"))))))")
 ("<table><colgroup><col><col span=2></colgroup><tr><td>x</table>"
  "(html (head) (body (table (colgroup (col) (col span=\"2\")) (tbody (tr (td \"x\"))))))")
 ("<table><col><tr><td>x</table>"
  "(html (head) (body (table (colgroup (col)) (tbody (tr (td \"x\"))))))")
 ("<table><tr><td><table><tr><td>in</table>out<td>next</table>"
  "(html (head) (body (table (tbody (tr (td (table (tbody (tr (td \"in\")))) \"out\") (td \"next\"))))))")
 ("<table><tr><td><p>a<td><ul><li>b</table>after"
  "(html (head) (body (table (tbody (tr (td (p \"a\")) (td (ul (li \"b\")))))) \"after\"))")
 ("<table>
 <tr>
  <td>a</td>
  <td>b</td>
 </tr>
</table>
"
  "(html (head) (body (table (tbody (tr (td \"a\") (td \"b\")))) \"\\n\"))")
 ("<table><tr><td>a</td></tr></tbody></table>b"
  "(html (head) (body (table (tbody (tr (td \"a\")))) \"b\"))")
 ("<table><tr><td><b>a</td><td>b</td></tr></table>"
  "(html (head) (body (table (tbody (tr (td (b \"a\")) (td \"b\"))))))")
 ("<table><tbody><tr><td>a</tbody><tbody><tr><td>b</table>"
  "(html (head) (body (table (tbody (tr (td \"a\"))) (tbody (tr (td \"b\"))))))")
 ("<td>a<tr>b<th>c"
  "(html (head) (body \"abc\"))")
 ("<table><tr><td>a</tr><td>b</table>"
  "(html (head) (body (table (tbody (tr (td \"a\")) (tr (td \"b\"))))))")
 ("<table><tr><td>a</table></td></tr>b"
  "(html (head) (body (table (tbody (tr (td \"a\")))) \"b\"))")
 ("<div><table><tr><td>a</div>b</table>c"
  "(html (head) (body (div (table (tbody (tr (td \"ab\")))) \"c\")))")
 ("<table><tr><td><div>a<tr><td>b</table>"
  "(html (head) (body (table (tbody (tr (td (div \"a\"))) (tr (td \"b\"))))))")
 ("<table><tr><td>a</th>b</table>"
  "(html (head) (body (table (tbody (tr (td \"ab\"))))))")
 ("<table border=1 cellpadding=2><tr valign=top><td colspan=2 align=right>a</table>"
  "(html (head) (body (table border=\"1\" cellpadding=\"2\" (tbody (tr valign=\"top\" (td colspan=\"2\" align=\"right\" \"a\"))))))")
 ("<p>a<table><tr><td>b</table>c"
  "(html (head) (body (p \"a\" (table (tbody (tr (td \"b\")))) \"c\")))")
 ("<table><thead><th>a<tbody><td>b</table>"
  "(html (head) (body (table (thead (tr (th \"a\"))) (tbody (tr (td \"b\"))))))")
 ("<table><tr><td>a<caption>b</table>"
  "(html (head) (body (table (tbody (tr (td \"a\"))) (caption \"b\"))))")
 ("<table><tbody></tbody><tr><td>a</table>"
  "(html (head) (body (table (tbody) (tbody (tr (td \"a\"))))))")
 ("<a href=1>a<a href=2>b</a>c"
  "(html (head) (body (a href=\"1\" \"a\") (a href=\"2\" \"b\") \"c\"))")
 ("<a href=1><b>a</b></a>"
  "(html (head) (body (a href=\"1\" (b \"a\"))))")
 ("<a href=1><div>block</div></a>after"
  "(html (head) (body (a href=\"1\" (div \"block\")) \"after\"))")
 ("<b>a<i>b</i>c</b>"
  "(html (head) (body (b \"a\" (i \"b\") \"c\")))")
 ("<u>a</u><s>b</s><small>c</small><big>d</big><tt>e</tt>"
  "(html (head) (body (u \"a\") (s \"b\") (small \"c\") (big \"d\") (tt \"e\")))")
 ("<code>a</code><kbd>b</kbd><samp>c</samp><var>d</var><sub>e</sub><sup>f</sup>"
  "(html (head) (body (code \"a\") (kbd \"b\") (samp \"c\") (var \"d\") (sub \"e\") (sup \"f\")))")
 ("<a href=1>a<table><tr><td><a href=2>b</a></table>c</a>"
  "(html (head) (body (a href=\"1\" \"a\" (table (tbody (tr (td (a href=\"2\" \"b\"))))) \"c\")))")
 ("<span>a</span></span>b"
  "(html (head) (body (span \"a\") \"b\"))")
 ("<em>a</b>b</em>"
  "(html (head) (body (em \"ab\")))")
 ("<b>a</i>b</b>"
  "(html (head) (body (b \"ab\")))")
 ("<nobr>a</nobr>"
  "(html (head) (body (nobr \"a\")))")
 ("<q>a</q><cite>b</cite><abbr title=x>c</abbr><mark>d</mark>"
  "(html (head) (body (q \"a\") (cite \"b\") (abbr title=\"x\" \"c\") (mark \"d\")))")
 ("<script>if (a < b && c > d) { document.write('</p><b>'); }</script>x"
  "(html (head (script \"if (a < b && c > d) { document.write('</p><b>'); }\")) (body \"x\"))")
 ("<script><!-- x --></script>y"
  "(html (head (script \"<!-- x -->\")) (body \"y\"))")
 ("<style>p > a { color: red }</style><p>z"
  "(html (head (style \"p > a { color: red }\")) (body (p \"z\")))")
 ("<textarea>
 a <b>&amp; c</textarea>d"
  "(html (head) (body (textarea \" a <b>& c\") \"d\"))")
 ("<textarea>a</textare>b</textarea>c"
  "(html (head) (body (textarea \"a</textare>b\") \"c\"))")
 ("<title>a <b> &lt;c&gt; &copy</title>"
  "(html (head (title \"a <b> <c> \\u{a9}\")) (body))")
 ("<xmp><b>x</b> &amp;</xmp>y"
  "(html (head) (body (xmp \"<b>x</b> &amp;\") \"y\"))")
 ("<iframe src=x><p>a</p></iframe>b"
  "(html (head) (body (iframe src=\"x\" \"<p>a</p>\") \"b\"))")
 ("<noembed><p>a</noembed>b"
  "(html (head) (body (noembed \"<p>a\") \"b\"))")
 ("<noframes><p>a</noframes>b"
  "(html (head (noframes \"<p>a\")) (body \"b\"))")
 ("<script>a</script >b"
  "(html (head (script \"a\")) (body \"b\"))")
 ("<script>a</script/>b"
  "(html (head (script \"a\")) (body \"b\"))")
 ("<script>a</scriptx>b</script>c"
  "(html (head (script \"a</scriptx>b\")) (body \"c\"))")
 ("<SCRIPT>a</ScRiPt>b"
  "(html (head (script \"a\")) (body \"b\"))")
 ("<script>unclosed <p>"
  "(html (head (script \"unclosed <p>\")) (body))")
 ("<style>unclosed"
  "(html (head (style \"unclosed\")) (body))")
 ("<textarea>unclosed <p>"
  "(html (head) (body (textarea \"unclosed <p>\")))")
 ("<title>unclosed &amp;"
  "(html (head (title \"unclosed &\")) (body))")
 ("<pre>
line one
line two</pre>"
  "(html (head) (body (pre \"line one\\nline two\")))")
 ("<pre>

x</pre>"
  "(html (head) (body (pre \"\\nx\")))")
 ("<pre>a
</pre>"
  "(html (head) (body (pre \"a\\n\")))")
 ("<listing>
x</listing>"
  "(html (head) (body (listing \"x\")))")
 ("<noscript><p>a</p></noscript>b"
  "(html (head (noscript)) (body (p \"a\") \"b\"))")
 ("<plaintext>a<b>c</b>&amp;"
  "(html (head) (body (plaintext \"a<b>c</b>&amp;\")))")
 ("<script></script><script>x</script>"
  "(html (head (script) (script \"x\")) (body))")
 ("a<!-- c -->b"
  "(html (head) (body \"ab\"))")
 ("a<!---->b"
  "(html (head) (body \"ab\"))")
 ("a<!-->b"
  "(html (head) (body \"ab\"))")
 ("a<!--->b"
  "(html (head) (body \"ab\"))")
 ("a<!-- x -- y -->b"
  "(html (head) (body \"ab\"))")
 ("a<!--x--!>b"
  "(html (head) (body \"ab\"))")
 ("a<!-- unclosed"
  "(html (head) (body \"a\"))")
 ("a<!-- <p> -->b"
  "(html (head) (body \"ab\"))")
 ("<!-- before --><p>x"
  "(html (head) (body (p \"x\")))")
 ("<p>a<!-- in --></p><!-- after -->"
  "(html (head) (body (p \"a\")))")
 ("a<!DOCTYPE html>b"
  "(html (head) (body \"ab\"))")
 ("a<?xml version=\"1.0\"?>b"
  "(html (head) (body \"ab\"))")
 ("a</ x>b"
  "(html (head) (body \"ab\"))")
 ("a</>b"
  "(html (head) (body \"ab\"))")
 ("a<3b"
  "(html (head) (body \"a<3b\"))")
 ("a < b > c"
  "(html (head) (body \"a < b > c\"))")
 ("a<"
  "(html (head) (body \"a<\"))")
 ("a</"
  "(html (head) (body \"a</\"))")
 ("a<!"
  "(html (head) (body \"a\"))")
 ("a<?"
  "(html (head) (body \"a\"))")
 ("<p>a</p <b>c"
  "(html (head) (body (p \"a\") \"c\"))")
 ("a<![CDATA[x]]>b"
  "(html (head) (body \"ab\"))")
 ("<><p>x"
  "(html (head) (body \"<>\" (p \"x\")))")
 ("&amp;&lt;&gt;&quot;&apos;&nbsp;&copy;&reg;&trade;&hellip;&mdash;&ndash;&lsquo;&rsquo;&ldquo;&rdquo;&bull;&middot;&euro;&pound;&yen;&cent;&sect;&para;&deg;&plusmn;&times;&divide;"
  "(html (head) (body \"&<>\\\"'\\u{a0}\\u{a9}\\u{ae}\\u{2122}\\u{2026}\\u{2014}\\u{2013}\\u{2018}\\u{2019}\\u{201c}\\u{201d}\\u{2022}\\u{b7}\\u{20ac}\\u{a3}\\u{a5}\\u{a2}\\u{a7}\\u{b6}\\u{b0}\\u{b1}\\u{d7}\\u{f7}\"))")
 ("&Auml;&auml;&Ouml;&ouml;&Uuml;&uuml;&szlig;&eacute;&Eacute;&ntilde;&Ntilde;&ccedil;&aring;&oslash;&aelig;&AElig;&thorn;&ETH;"
  "(html (head) (body \"\\u{c4}\\u{e4}\\u{d6}\\u{f6}\\u{dc}\\u{fc}\\u{df}\\u{e9}\\u{c9}\\u{f1}\\u{d1}\\u{e7}\\u{e5}\\u{f8}\\u{e6}\\u{c6}\\u{fe}\\u{d0}\"))")
 ("&alpha;&beta;&gamma;&Delta;&pi;&Omega;&rarr;&larr;&uarr;&darr;&harr;&rArr;&infin;&ne;&le;&ge;&sum;&radic;"
  "(html (head) (body \"\\u{3b1}\\u{3b2}\\u{3b3}\\u{394}\\u{3c0}\\u{3a9}\\u{2192}\\u{2190}\\u{2191}\\u{2193}\\u{2194}\\u{21d2}\\u{221e}\\u{2260}\\u{2264}\\u{2265}\\u{2211}\\u{221a}\"))")
 ("&#65;&#x41;&#X42;&#0065;&#x000041;"
  "(html (head) (body \"AABAA\"))")
 ("&#128;&#130;&#150;&#151;&#153;&#159;&#129;&#x80;&#x9f;"
  "(html (head) (body \"\\u{20ac}\\u{201a}\\u{2013}\\u{2014}\\u{2122}\\u{178}\\u{81}\\u{20ac}\\u{178}\"))")
 ("&#0;&#x0;&#xD800;&#xDFFF;&#x110000;&#99999999999;&#x10FFFF;&#xFFFF;"
  "(html (head) (body \"\\u{fffd}\\u{fffd}\\u{fffd}\\u{fffd}\\u{fffd}\\u{fffd}\\u{10ffff}\\u{ffff}\"))")
 ("&amp &lt &gt &copy &reg &nbsp &AMP &LT &GT &QUOT &COPY &REG"
  "(html (head) (body \"& < > \\u{a9} \\u{ae} \\u{a0} & < > \\\" \\u{a9} \\u{ae}\"))")
 ("&ampx &ltx &copyright &notit; &notin; &not;in"
  "(html (head) (body \"&x <x \\u{a9}right \\u{ac}it; \\u{2209} \\u{ac}in\"))")
 ("&unknown; &unknown &x; &; & &# &#; &#x; &#xZ; &#12 x &#x1Fg"
  "(html (head) (body \"&unknown; &unknown &x; &; & &# &#; &#x; &#xZ; \\u{c} x \\u{1f}g\"))")
 ("&amp;amp; &amp;lt; &#38;#38;"
  "(html (head) (body \"&amp; &lt; &#38;\"))")
 ("<a href=\"?a=1&copy=2&reg;3&amp=4&amp;5&lt6&ltx&gt;\">x</a>"
  "(html (head) (body (a href=\"?a=1&copy=2\\u{ae}3&amp=4&5&lt6&ltx>\" \"x\")))")
 ("<a href='&#x41;&#66;&notit;&notin;&not=1'>x</a>"
  "(html (head) (body (a href=\"AB&notit;\\u{2209}&not=1\" \"x\")))")
 ("<p title=\"a&nbsp;b&lt;c\">x"
  "(html (head) (body (p title=\"a\\u{a0}b<c\" \"x\")))")
 ("&hearts;&spades;&clubs;&diams;&loz;&lang;&rang;&zwnj;&zwj;&lrm;&rlm;&ensp;&emsp;&thinsp;&shy;"
  "(html (head) (body \"\\u{2665}\\u{2660}\\u{2663}\\u{2666}\\u{25ca}\\u{27e8}\\u{27e9}\\u{200c}\\u{200d}\\u{200e}\\u{200f}\\u{2002}\\u{2003}\\u{2009}\\u{ad}\"))")
 ("x&"
  "(html (head) (body \"x&\"))")
 ("&amp"
  "(html (head) (body \"&\"))")
 ("&#65"
  "(html (head) (body \"A\"))")
 ("&#x41"
  "(html (head) (body \"A\"))")
 ("AT&T and R&D; and Q&A"
  "(html (head) (body \"AT&T and R&D; and Q&A\"))")
 ("x&Tab;&NewLine;&excl;&quest;&lpar;&rpar;&lbrack;&rbrack;&lbrace;&rbrace;&check;&cross;&star;&half;"
  "(html (head) (body \"x\\t\\n!?()[]{}\\u{2713}\\u{2717}\\u{2606}\\u{bd}\"))")
 ("&frac12;&frac14;&frac34;&sup1;&sup2;&sup3;&micro;&ordf;&ordm;&laquo;&raquo;&iexcl;&iquest;&uml;&macr;&acute;&cedil;&brvbar;&curren;"
  "(html (head) (body \"\\u{bd}\\u{bc}\\u{be}\\u{b9}\\u{b2}\\u{b3}\\u{b5}\\u{aa}\\u{ba}\\u{ab}\\u{bb}\\u{a1}\\u{bf}\\u{a8}\\u{af}\\u{b4}\\u{b8}\\u{a6}\\u{a4}\"))")
 ("&Aacute;&aacute;&Agrave;&agrave;&Acirc;&acirc;&Atilde;&atilde;&Iuml;&iuml;&Yacute;&yacute;&yuml;&Yuml;&OElig;&oelig;&Scaron;&scaron;"
  "(html (head) (body \"\\u{c1}\\u{e1}\\u{c0}\\u{e0}\\u{c2}\\u{e2}\\u{c3}\\u{e3}\\u{cf}\\u{ef}\\u{dd}\\u{fd}\\u{ff}\\u{178}\\u{152}\\u{153}\\u{160}\\u{161}\"))")
 ("&apos;&apos &lsqb;&rsqb;&lcub;&rcub;&colon;&semi;&comma;&period;&num;&dollar;&percnt;&ast;&plus;&equals;&sol;&bsol;&commat;&lowbar;&grave;&vert;&verbar;"
  "(html (head) (body \"'&apos []{}:;,.#$%*+=/\\\\@_`||\"))")
 ("&bullet;&centerdot;&hyphen;&dash;&phone;&female;&male;&bigstar;&starf;&hairsp;&numsp;&puncsp;&horbar;&Vert;&vellip;&ctdot;&mldr;&nldr;&frac13;&frac23;&frac15;&frac18;"
  "(html (head) (body \"\\u{2022}\\u{b7}\\u{2010}\\u{2010}\\u{260e}\\u{2640}\\u{2642}\\u{2605}\\u{2605}\\u{200a}\\u{2007}\\u{2008}\\u{2015}\\u{2016}\\u{22ee}\\u{22ef}\\u{2026}\\u{2025}\\u{2153}\\u{2154}\\u{2155}\\u{215b}\"))")
 ("&rightarrow;&leftarrow;&RightArrow;&LeftArrow;&uparrow;&downarrow;&ZeroWidthSpace;&NoBreak;"
  "(html (head) (body \"\\u{2192}\\u{2190}\\u{2192}\\u{2190}\\u{2191}\\u{2193}\\u{200b}\\u{2060}\"))")
 ("&fnof;&circ;&tilde;&thetasym;&upsih;&piv;&bdquo;&sbquo;&dagger;&Dagger;&permil;&lsaquo;&rsaquo;&oline;&frasl;&weierp;&image;&real;&alefsym;&crarr;"
  "(html (head) (body \"\\u{192}\\u{2c6}\\u{2dc}\\u{3d1}\\u{3d2}\\u{3d6}\\u{201e}\\u{201a}\\u{2020}\\u{2021}\\u{2030}\\u{2039}\\u{203a}\\u{203e}\\u{2044}\\u{2118}\\u{2111}\\u{211c}\\u{2135}\\u{21b5}\"))")
 ("&forall;&part;&exist;&empty;&nabla;&isin;&notin;&ni;&prod;&minus;&lowast;&prop;&ang;&and;&or;&cap;&cup;&int;&there4;&sim;&cong;&asymp;&equiv;&sub;&sup;&nsub;&sube;&supe;&oplus;&otimes;&perp;&sdot;&lceil;&rceil;&lfloor;&rfloor;"
  "(html (head) (body \"\\u{2200}\\u{2202}\\u{2203}\\u{2205}\\u{2207}\\u{2208}\\u{2209}\\u{220b}\\u{220f}\\u{2212}\\u{2217}\\u{221d}\\u{2220}\\u{2227}\\u{2228}\\u{2229}\\u{222a}\\u{222b}\\u{2234}\\u{223c}\\u{2245}\\u{2248}\\u{2261}\\u{2282}\\u{2283}\\u{2284}\\u{2286}\\u{2287}\\u{2295}\\u{2297}\\u{22a5}\\u{22c5}\\u{2308}\\u{2309}\\u{230a}\\u{230b}\"))")
 ("&Alpha;&Beta;&Gamma;&Epsilon;&Zeta;&Eta;&Theta;&Iota;&Kappa;&Lambda;&Mu;&Nu;&Xi;&Omicron;&Pi;&Rho;&Sigma;&Tau;&Upsilon;&Phi;&Chi;&Psi;&sigmaf;&delta;&epsilon;&zeta;&eta;&theta;&iota;&kappa;&lambda;&mu;&nu;&xi;&omicron;&rho;&sigma;&tau;&upsilon;&phi;&chi;&psi;&omega;"
  "(html (head) (body \"\\u{391}\\u{392}\\u{393}\\u{395}\\u{396}\\u{397}\\u{398}\\u{399}\\u{39a}\\u{39b}\\u{39c}\\u{39d}\\u{39e}\\u{39f}\\u{3a0}\\u{3a1}\\u{3a3}\\u{3a4}\\u{3a5}\\u{3a6}\\u{3a7}\\u{3a8}\\u{3c2}\\u{3b4}\\u{3b5}\\u{3b6}\\u{3b7}\\u{3b8}\\u{3b9}\\u{3ba}\\u{3bb}\\u{3bc}\\u{3bd}\\u{3be}\\u{3bf}\\u{3c1}\\u{3c3}\\u{3c4}\\u{3c5}\\u{3c6}\\u{3c7}\\u{3c8}\\u{3c9}\"))")
 ("&lArr;&uArr;&dArr;&hArr;&prime;&Prime;&Igrave;&igrave;&Iacute;&iacute;&Icirc;&icirc;&Ograve;&ograve;&Oacute;&oacute;&Ocirc;&ocirc;&Otilde;&otilde;&Ugrave;&ugrave;&Uacute;&uacute;&Ucirc;&ucirc;&Egrave;&egrave;&Ecirc;&ecirc;&Euml;&euml;&Aring;&Ccedil;&Oslash;&THORN;&eth;"
  "(html (head) (body \"\\u{21d0}\\u{21d1}\\u{21d3}\\u{21d4}\\u{2032}\\u{2033}\\u{cc}\\u{ec}\\u{cd}\\u{ed}\\u{ce}\\u{ee}\\u{d2}\\u{f2}\\u{d3}\\u{f3}\\u{d4}\\u{f4}\\u{d5}\\u{f5}\\u{d9}\\u{f9}\\u{da}\\u{fa}\\u{db}\\u{fb}\\u{c8}\\u{e8}\\u{ca}\\u{ea}\\u{cb}\\u{eb}\\u{c5}\\u{c7}\\u{d8}\\u{de}\\u{f0}\"))")
 ("<a HREF=X Href=y href=z>x</a>"
  "(html (head) (body (a href=\"X\" \"x\")))")
 ("<p a b=1 c='2' d=\"3\" e = 4 f= '5' g ='6'>x"
  "(html (head) (body (p a=\"\" b=\"1\" c=\"2\" d=\"3\" e=\"4\" f=\"5\" g=\"6\" \"x\")))")
 ("<a href=/a/b/>x</a>"
  "(html (head) (body (a href=\"/a/b/\" \"x\")))")
 ("<a href=a/>x</a>"
  "(html (head) (body (a href=\"a/\" \"x\")))")
 ("<p a=>x"
  "(html (head) (body (p a=\"\" \"x\")))")
 ("<p =a>x"
  "(html (head) (body (p =a=\"\" \"x\")))")
 ("<p a==b>x"
  "(html (head) (body (p a=\"=b\" \"x\")))")
 ("<p a=b=c>x"
  "(html (head) (body (p a=\"b=c\" \"x\")))")
 ("<p a='x > y' b=\"<z>\">t"
  "(html (head) (body (p a=\"x > y\" b=\"<z>\" \"t\")))")
 ("<p a=\"unclosed>x"
  "(html (head) (body))")
 ("<p a='b\"c' d=\"e'f\">x"
  "(html (head) (body (p a=\"b\\\"c\" d=\"e'f\" \"x\")))")
 ("<p a=1/ b=2 / c=3>x"
  "(html (head) (body (p a=\"1/\" b=\"2\" c=\"3\" \"x\")))")
 ("<p a=\"&quot;&amp;&lt;\">x"
  "(html (head) (body (p a=\"\\\"&<\" \"x\")))")
 ("<br a=1><hr b=2><img c=3>"
  "(html (head) (body (br a=\"1\") (hr b=\"2\") (img c=\"3\")))")
 ("<p a b c>x"
  "(html (head) (body (p a=\"\" b=\"\" c=\"\" \"x\")))")
 ("<input type=text value=\"a b\" disabled>"
  "(html (head) (body (input type=\"text\" value=\"a b\" disabled=\"\")))")
 ("<p a='1'b='2'>x"
  "(html (head) (body (p a=\"1\" b=\"2\" \"x\")))")
 ("<p / a>x"
  "(html (head) (body (p a=\"\" \"x\")))")
 ("<p a/b>x"
  "(html (head) (body (p a=\"\" b=\"\" \"x\")))")
 ("<p a"
  "(html (head) (body))")
 ("<p a="
  "(html (head) (body))")
 ("<p a='x"
  "(html (head) (body))")
 ("<p"
  "(html (head) (body))")
 ("<a title='line
one'>x</a>"
  "(html (head) (body (a title=\"line\\none\" \"x\")))")
 ("<select><option>a<option>b</select>c"
  "(html (head) (body (select (option \"a\") (option \"b\")) \"c\"))")
 ("<select><optgroup label=x><option>a<optgroup label=y><option>b</select>"
  "(html (head) (body (select (optgroup label=\"x\" (option \"a\")) (optgroup label=\"y\" (option \"b\")))))")
 ("<option>a<option>b"
  "(html (head) (body (option \"a\") (option \"b\")))")
 ("<select><option>a</option><option selected>b</option></select>"
  "(html (head) (body (select (option \"a\") (option selected=\"\" \"b\"))))")
 ("<svg width=10 height=10><path d=\"M0 0\"/><circle r=1 /><g><rect/></g></svg>after"
  "(html (head) (body (svg width=\"10\" height=\"10\" (path d=\"M0 0\") (circle r=\"1\") (g (rect))) \"after\"))")
 ("<p>a<svg><title>T</title><desc>D</desc></svg>b"
  "(html (head) (body (p \"a\" (svg (title \"T\") (desc \"D\")) \"b\")))")
 ("<svg viewBox=\"0 0 1 1\"><use xlink:href=\"#a\"/></svg>"
  "(html (head) (body (svg viewbox=\"0 0 1 1\" (use xlink:href=\"#a\"))))")
 ("<svg><text>x</text></svg>y"
  "(html (head) (body (svg (text \"x\")) \"y\"))")
 ("<svg/>a"
  "(html (head) (body (svg) \"a\"))")
 ("<math><mi>x</mi><mo>=</mo><mn>1</mn></math>y"
  "(html (head) (body (math (mi \"x\") (mo \"=\") (mn \"1\")) \"y\"))")
 ("<svg><a href=x><circle/></a></svg>z"
  "(html (head) (body (svg (a href=\"x\" (circle))) \"z\"))")
 ("<svg><![CDATA[a<b]]></svg>c"
  "(html (head) (body (svg \"a<b\") \"c\"))")
 ("<div/>a"
  "(html (head) (body (div \"a\")))")
 ("<span/>b<br/>c"
  "(html (head) (body (span \"b\" (br) \"c\")))")
 ("<svg><style>a{}</style></svg>x"
  "(html (head) (body (svg (style \"a{}\")) \"x\"))")
 ("<div><p>a<b>b"
  "(html (head) (body (div (p \"a\" (b \"b\")))))")
 ("<ul><li>a<ol><li>b"
  "(html (head) (body (ul (li \"a\" (ol (li \"b\"))))))")
 ("<table><tr><td>a"
  "(html (head) (body (table (tbody (tr (td \"a\"))))))")
 ("<a href=x>a"
  "(html (head) (body (a href=\"x\" \"a\")))")
 ("<div"
  "(html (head) (body))")
 ("<div class"
  "(html (head) (body))")
 ("<div class="
  "(html (head) (body))")
 ("<div class=\"a"
  "(html (head) (body))")
 ("<div class=a"
  "(html (head) (body))")
 ("</div"
  "(html (head) (body))")
 ("<!--"
  "(html (head) (body))")
 ("<!"
  "(html (head) (body))")
 ("<p>a</p"
  "(html (head) (body (p \"a\")))")
 ("<form action=/s><input name=q><input type=submit value=Go></form>"
  "(html (head) (body (form action=\"/s\" (input name=\"q\") (input type=\"submit\" value=\"Go\"))))")
 ("<form><p>a<input><p>b</form>c"
  "(html (head) (body (form (p \"a\" (input)) (p \"b\")) \"c\"))")
 ("<fieldset><legend>l</legend>x</fieldset>"
  "(html (head) (body (fieldset (legend \"l\") \"x\")))")
 ("<label>a<input></label><button>b</button>"
  "(html (head) (body (label \"a\" (input)) (button \"b\")))")
 ("<form><select name=s><option value=1>a</select><textarea name=t>x</textarea></form>"
  "(html (head) (body (form (select name=\"s\" (option value=\"1\" \"a\")) (textarea name=\"t\" \"x\"))))")
 ("<details><summary>s</summary>d</details>"
  "(html (head) (body (details (summary \"s\") \"d\")))")
 ("<figure><img src=a><figcaption>c</figcaption></figure>"
  "(html (head) (body (figure (img src=\"a\") (figcaption \"c\"))))")
 ("<template><p>a</p></template>b"
  "(html (head (template (p \"a\"))) (body \"b\"))")
 ("<head><template><li>a<li>b<td>c</template><title>t</title></head>x"
  "(html (head (template (li \"a\") (li \"bc\")) (title \"t\")) (body \"x\"))")
 ("<p>a<template><div>b</div></template>c"
  "(html (head) (body (p \"a\" (template (div \"b\")) \"c\")))")
 ("<template><p>a</template>b"
  "(html (head (template (p \"a\"))) (body \"b\"))")
 ("<ruby>a<rt>b</rt></ruby>"
  "(html (head) (body (ruby \"a\" (rt \"b\"))))")
 ("<ruby>a<rp>(<rt>b<rp>)</ruby>"
  "(html (head) (body (ruby \"a\" (rp \"(\") (rt \"b\") (rp \")\"))))")
 ("<object data=x><p>a</p></object>b"
  "(html (head) (body (object data=\"x\" (p \"a\")) \"b\"))")
 ("<video src=x controls>fallback</video>"
  "(html (head) (body (video src=\"x\" controls=\"\" \"fallback\")))")
 ("<audio><source src=a><source src=b>x</audio>"
  "(html (head) (body (audio (source src=\"a\") (source src=\"b\") \"x\")))")
 ("<map name=m><area href=a><area href=b></map>"
  "(html (head) (body (map name=\"m\" (area href=\"a\") (area href=\"b\"))))")
 ("<bdo dir=rtl>x</bdo><wbr>y<time datetime=1>z</time>"
  "(html (head) (body (bdo dir=\"rtl\" \"x\") (wbr) \"y\" (time datetime=\"1\" \"z\")))")
 ("<main><article><header><h1>t</h1></header><section><p>a</section><footer>f</footer></article></main>"
  "(html (head) (body (main (article (header (h1 \"t\")) (section (p \"a\")) (footer \"f\")))))")
 ("<dl><div><dt>a<dd>b</div><div><dt>c<dd>d</div></dl>"
  "(html (head) (body (dl (div (dt \"a\") (dd \"b\")) (div (dt \"c\") (dd \"d\")))))")
 ("<address>a<p>b</address>c"
  "(html (head) (body (address \"a\" (p \"b\")) \"c\"))")
 ("<blockquote><p>a</blockquote>b"
  "(html (head) (body (blockquote (p \"a\")) \"b\"))")
 ("<center><p>a</center>b"
  "(html (head) (body (center (p \"a\")) \"b\"))")
 ("<div><div><div>deep</div></div></div>"
  "(html (head) (body (div (div (div \"deep\")))))")
 ("aé中😀z"
  "(html (head) (body \"a\\u{e9}\\u{4e2d}\\u{1f600}z\"))")
 ("<ul>
<li>a</li>
<li>b</li>
</ul>
"
  "(html (head) (body (ul \"\\n\" (li \"a\") \"\\n\" (li \"b\") \"\\n\") \"\\n\"))")
 ("<p>
  some   spaced
  text
</p>"
  "(html (head) (body (p \"\\n  some   spaced\\n  text\\n\")))")
 ("<svg><style><g>x</g></style></svg>y"
  "(html (head) (body (svg (style (g \"x\"))) \"y\"))")
 ("<svg><title><g>x</g></title></svg>z"
  "(html (head) (body (svg (title (g \"x\"))) \"z\"))")
 ("x</p"
  "(html (head) (body \"x\"))")
 ("y</div"
  "(html (head) (body \"y\"))")
 ("<p>a</p"
  "(html (head) (body (p \"a\")))")
 ("&middot x &Aacute x &frac12 x &iquest x &THORN"
  "(html (head) (body \"\\u{b7} x \\u{c1} x \\u{bd} x \\u{bf} x \\u{de}\"))")
 ("<ul><li>a<ol></li>b</ol>c</ul>"
  "(html (head) (body (ul (li \"a\" (ol \"b\") \"c\"))))")
 ("<span>a<div>b</span>c</div>d"
  "(html (head) (body (span \"a\" (div \"bc\") \"d\")))")
 ("  hello  "
  "(html (head) (body \"hello  \"))")
 ("<head></head><head><title>x</title></head>y"
  "(html (head (title \"x\")) (body \"y\"))")
 ("<FooBar Baz=1>x</FOOBAR>y"
  "(html (head) (body (foobar baz=\"1\" \"x\") \"y\"))")
 ("<table><tr><td>a<table></tr><tr><td>b</table>c</table>"
  "(html (head) (body (table (tbody (tr (td \"a\" (table (tbody (tr (td \"b\")))) \"c\"))))))")
 ("<p>a<table><tr><td>b</p>c</table>d"
  "(html (head) (body (p \"a\" (table (tbody (tr (td \"b\" (p) \"c\")))) \"d\")))")
 ("<ruby>a<rb>b<rt>c<rtc>d</ruby>"
  "(html (head) (body (ruby \"a\" (rb \"b\") (rt \"c\") (rtc \"d\"))))")
 ("<ruby>a<rtc>b<rt>c<rp>d</ruby>e"
  "(html (head) (body (ruby \"a\" (rtc \"b\" (rt \"c\") (rp \"d\"))) \"e\"))")
 ("<ruby>a<rt>b<rb>c<rt>d</ruby>"
  "(html (head) (body (ruby \"a\" (rt \"b\") (rb \"c\") (rt \"d\"))))"))
