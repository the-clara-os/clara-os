# Fonts

`spleen-8x16.bdf` is Spleen 8x16 by Frederic Cambus, unmodified, from
https://github.com/fcambus/spleen at commit
330875ae5ceade41bc1995a941c2f5d8e58b6c95. It is distributed under the BSD
2-Clause license in `LICENSE.spleen`.

`tools/bdf2c.py` turns its printable ASCII range into `kernel/font.c`, which
is checked in. Run `make font` after changing the font or the tool.

The eight files whose names begin with `Go-` are the Go fonts, version
2.010, which the Bigelow & Holmes foundry made for the Go project:
https://go.dev/blog/go-fonts. They are unmodified, from
https://github.com/golang/image at commit
41969df76e82aeec85fa3821b1e24955ea993001, directory `font/gofont/ttfs`,
and are distributed under the BSD 3-Clause license in `LICENSE.go`, which
is that directory's `README` as it stands. Their SHA-256 sums:

    d6c33857c7ea7d740a8e1d81d37261782f698e9c17a2c9bf3bb0abbaf99e3c90  Go-Bold-Italic.ttf
    c18494baa7ea35b8dbfac3861787d360b9c0ab91232562371a09e6fbf09aaa40  Go-Bold.ttf
    6efef00d080c8fe68bbe2bf08526294c83d52d7b90b16f938953025c0868cc57  Go-Italic.ttf
    cb43aca5ab36631c0b4679831017cf249c33db4f721daad7379e04bba383ef1f  Go-Mono-Bold-Italic.ttf
    b165f1a142dc88d3c388de2c89d3ab62dd04620ef21ad07f43fb51f77857edc3  Go-Mono-Bold.ttf
    10d5f73519ea32b4882897a9bec6c42ba2ca27d6c06ba9a0e55ae38a383cf7e6  Go-Mono-Italic.ttf
    8bc66a0154bbf69cd24e5bde41a12ec9495c8a242c5def2255e4a164900f1ed7  Go-Mono.ttf
    197d9f3703b4c00af609178876a8d73e396f64fe438b2c871778566632374be3  Go-Regular.ttf

The four files whose names begin with `Charter-` are Charter, which
Matthew Carter drew for Bitstream in 1987 and Bitstream gave to the X
Consortium in 1992, as Matthew Butterick made TrueType files of it:
https://practicaltypography.com/charter.html, the archive
`Charter 210112.zip` (SHA-256
`b40297f1a615f94594bdad0995848eb2223fb53ccb4ea197cabf24439bd811c9`), its
directory `TTF format (best for Windows)/Charter`. The files are that
archive's byte for byte, under other names, `Charter-Regular.ttf` for
`Charter Regular.ttf` and so on, since a name with a space in it is one
that `make` cannot list. They are distributed under Bitstream's notice in
`LICENSE.charter`, which is the archive's `Charter license.txt` as it
stands. Their SHA-256 sums:

    f69ac5fa6e4908d5c89d16477ace994893c42eb2ceec9c4cbf8773ace6622d98  Charter-Bold-Italic.ttf
    80424631bd3908efad8a5489df473cae7b7556f90bb6b63251ee22a0ace4f615  Charter-Bold.ttf
    f459d9b7aad4265984d87ed0e38f2c912131488f8a3b91027ef0bed567239506  Charter-Italic.ttf
    5fad789c56e24d323dfa017dffa5305220f03f89b8e43b28594284554df70437  Charter-Regular.ttf

`Twemoji.Mozilla.ttf` is Twemoji, the emoji that Twitter and others
drew (https://github.com/twitter/twemoji), as the font that Mozilla made
of them for Firefox: https://github.com/mozilla/twemoji-colr, the file
`Twemoji.Mozilla.ttf` of its release v0.7.0 (commit
c0460fdb2654dee584e75c4913bfa9fd2f873338), unmodified. The pictures are
distributed under the Creative Commons Attribution 4.0 International
license, and the font was made with code under the Apache License 2.0:
`LICENSE.twemoji` is that repository's `LICENSE.md` as it stands, which
says both. Its SHA-256 sum:

    6d90152ee0d29e82fe2a87793af5aa4b7ad13e6538360889e141e81ed299ee8e  Twemoji.Mozilla.ttf

It has 13,723 glyphs, of which 3,689 are pictures: each of those is a
list of other glyphs that are laid over each other, 33,179 layers in
all, every one in a colour of the file's palette of 1,063 (the tables
`COLR`, in its first form, and `CPAL`). 1,418 characters have a glyph,
the emoji of Unicode 14 among them, and 2,298 rows of characters have
one between them, a flag for the two letters of its country (the table
`GSUB`). The glyphs of the digits, of `#` and of `*` have no outline:
they are there to begin the row of a key.

The Go fonts are the families `Sans` and `Mono` of `lisp/type.lisp`,
Charter is its family `Serif`, and Twemoji its family `Emoji`, where the
emoji of a text in any font come from. It reads them as they are: every
`fonts/*.ttf` goes into the system's directory on the boot volume, and
the handoff reads it into memory with the system's other files. The Go
fonts have the letters of Latin, Greek and Cyrillic writing, 712 glyphs
to the file; Charter has 229, the Latin letters of the languages of
western Europe. Charter's files say how far their letters reach below
the baseline as that distance, 236, where the table is for a number
below nought: `lisp/type.lisp` takes it for the same either way. A font that is added here gets its family in
`clara.type::*families*`, its license beside it, and its row in the table
`*font-facts*` of `lisp/host/tests.lisp`, which `tools/fontcheck.c` prints:
what FreeType says of the file, for the host tests to hold against what
`lisp/type.lisp` reads. A font of pictures gets a row in `*font-colours*`
as well, which `fontcheck colours` prints: FreeType's word on every layer
of every picture and on its colour. Which glyph a row of characters comes
to is HarfBuzz's to say (`hb-shape --no-glyph-names --no-positions
--no-clusters --preserve-default-ignorables -u 1F1FA,1F1F8 <file>`), and
the host tests have a sample of its answers for this file.
