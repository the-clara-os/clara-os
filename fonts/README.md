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

They are the families `Sans` and `Mono` of `lisp/type.lisp`, which reads
them as they are: every `fonts/*.ttf` goes into the system's directory on
the boot volume, and the handoff reads it into memory with the system's
other files. A font that is added here gets its family in
`clara.type::*families*`, its license beside it, and its row in the table
`*font-facts*` of `lisp/host/tests.lisp`, which `tools/fontcheck.c` prints:
what FreeType says of the file, for the host tests to hold against what
`lisp/type.lisp` reads.
