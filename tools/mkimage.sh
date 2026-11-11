#!/bin/sh
# Raw GPT disk image with one FAT32 partition holding the ESP, for UTM.
# usage: tools/mkimage.sh [build/claraos.img]
set -eu
out=${1:-build/claraos.img}
dmg=${out%.img}.dmg
rm -f "$out" "$dmg"
hdiutil create -quiet -fs "MS-DOS FAT32" -size 64m -volname CLARAOS -layout GPTSPUD \
    -srcfolder build/esp -format UDRW -o "$dmg"
mv "$dmg" "$out"
echo "wrote $out"
