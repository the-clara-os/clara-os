# Fonts

`spleen-8x16.bdf` is Spleen 8x16 by Frederic Cambus, unmodified, from
https://github.com/fcambus/spleen at commit
330875ae5ceade41bc1995a941c2f5d8e58b6c95. It is distributed under the BSD
2-Clause license in `LICENSE.spleen`.

`tools/bdf2c.py` turns its printable ASCII range into `kernel/font.c`, which
is checked in. Run `make font` after changing the font or the tool.
