#!/bin/sh
# Boot the built ESP directory under QEMU with EDK2 firmware, from a disk
# that is made of it.
# usage: tools/run.sh <x86_64|aarch64> [extra qemu args...]
# env:   SERIAL=mon:stdio|stdio|file:path   MEM=512M   NO_HVF=1 (force TCG on aarch64)
#        (mon:stdio, the default, hands Ctrl-C to the kernel, which stops a
#        computation with it; Ctrl-A X leaves QEMU. With stdio, Ctrl-C ends QEMU.)
#        DISK=build/claraos.img (boot that raw image, and write to it, instead of
#        build/disk-<arch>.img, the disk that tools/mkdisk.py makes of the ESP
#        directory. That one is made again whenever the directory has something
#        newer, a kernel or a Lisp file, and is kept until then, with whatever
#        the kernel wrote to it: a world that was saved starts again at the next
#        run, and is gone after the next build.)
#        INPUT="-device virtio-keyboard-pci ..." (the keyboard and the pointers the
#        machine gets; the default is a virtio keyboard, mouse and tablet, and
#        INPUT= gives a machine with none of them)
#        WORK=~/clara-work.img (a second disk, the user's own: a raw image with a
#        FAT volume, for the files that are to outlive the disk above, which is
#        made again for every newer system. A .dmg that macOS made is such an
#        image too, when it is a plain read/write one. Nothing here makes that
#        file or makes it again; the kernel finds its volume after the boot
#        volume, and the manual says how to make one and how to reach it, under
#        "A disk of your own".)
#        Either disk that is still open on the Mac, in the Finder, is ejected
#        there first, which is said: QEMU does not start with one that is.
set -eu
arch=${1:?usage: tools/run.sh <x86_64|aarch64> [qemu args]}
shift
esp=${ESP:-build/esp}
share=${QEMU_SHARE:-/opt/homebrew/share/qemu}
serial=${SERIAL:-mon:stdio}
mem=${MEM:-512M}
input=${INPUT--device virtio-keyboard-pci -device virtio-mouse-pci -device virtio-tablet-pci}
mkdir -p build

# A disk that the host has open as well is no disk for a machine: the two
# would write to it without knowing of each other, and QEMU does not start
# with one, saying no more than that it failed to get a lock. On macOS a
# double click on such a file opens it in the Finder, and it stays open
# until it is ejected, so that is done here, and said: the machine is what
# was asked for. A disk that cannot be ejected is in use over there, and
# the machine is not started.
release() {
    command -v hdiutil > /dev/null 2>&1 || return 0
    [ -f "$1" ] || return 0
    # What is open there, as its device and the file it is: the file is
    # written as it was named when it was opened, so the two are held
    # against each other as files, and not as names.
    device=$(hdiutil info 2> /dev/null | awk '
        /^image-path/ { path = $0; sub(/^image-path[ \t]*:[ \t]*/, "", path) }
        /^\/dev\/disk[0-9]+[ \t]/ { print $1 "\t" path }' |
        while IFS="$(printf '\t')" read -r open file; do
            if [ "$file" -ef "$1" ]; then
                echo "$open"
                break
            fi
        done)
    [ -n "$device" ] || return 0
    if diskutil eject "$device" > /dev/null 2>&1; then
        echo "tools/run.sh: $1 was open on this Mac, and has been ejected there: the machine has it now" >&2
    else
        echo "tools/run.sh: $1 is open on this Mac and cannot be ejected: something there is using it." >&2
        echo "    Close that, eject the disk in the Finder, and start the machine again." >&2
        exit 1
    fi
}

# The user's own disk goes in front of whatever else was asked for, which
# puts it behind the boot disk and the keyboard and pointers: the kernel
# looks names up on the first volume of the bus, and that has to stay the
# one that the machine was started from. A ~ that the shell left as it was
# written, as it does in an argument of make's, is the home directory.
if [ -n "${WORK:-}" ]; then
    case "$WORK" in
    "~/"*) WORK=$HOME/${WORK#??} ;;
    esac
    if [ ! -f "$WORK" ]; then
        echo "tools/run.sh: there is no disk $WORK to attach. To make one, a FAT volume with nothing on it:" >&2
        echo "    mkdir -p build/empty && python3 tools/mkdisk.py build/empty \"$WORK\"" >&2
        exit 1
    fi
    release "$WORK"
    set -- -drive "if=none,id=work,format=raw,file=$WORK" -device virtio-blk-pci,drive=work "$@"
fi

# EDK2 firmware is two flash images: the code, which is read-only, and a
# variable store, which each machine keeps its own copy of. Homebrew's qemu
# brings both along; Debian and Ubuntu have them in the ovmf and
# qemu-efi-aarch64 packages. The arguments are code and variable-store files
# in pairs, and the first pair that exists is used.
firmware() {
    vars=build/vars-$arch.fd
    while [ $# -ge 2 ]; do
        if [ -f "$1" ] && [ -f "$2" ]; then
            code=$1
            [ -f "$vars" ] || cp "$2" "$vars"
            return
        fi
        shift 2
    done
    echo "tools/run.sh: no EDK2 firmware for $arch here; see the top of the Makefile" >&2
    exit 1
}

if [ -n "${DISK:-}" ]; then
    disk=$DISK
    release "$disk"
else
    disk=build/disk-$arch.img
    release "$disk"
    if [ ! -f "$disk" ] || [ -n "$(find "$esp" -newer "$disk" -print | head -1)" ]; then
        python3 -I tools/mkdisk.py "$esp" "$disk"
    fi
fi

case "$arch" in
x86_64)
    firmware "$share/edk2-x86_64-code.fd" "$share/edk2-i386-vars.fd" \
             /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd
    exec qemu-system-x86_64 -machine q35 -m "$mem" \
        -drive if=pflash,format=raw,readonly=on,file="$code" \
        -drive if=pflash,format=raw,file="$vars" \
        -drive if=none,id=esp,format=raw,file="$disk" -device virtio-blk-pci,drive=esp,bootindex=0 $input \
        -serial "$serial" -no-reboot "$@"
    ;;
aarch64)
    firmware "$share/edk2-aarch64-code.fd" "$share/edk2-arm-vars.fd" \
             /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/AAVMF/AAVMF_VARS.fd
    accel=tcg cpu=cortex-a72
    if [ "$(uname -m)" = arm64 ] && [ -z "${NO_HVF:-}" ]; then
        accel=hvf cpu=host
    fi
    # The boot volume is a PCI device on this machine, and the firmware
    # remembers its place on the bus in the variable store: named before
    # the keyboard and the pointers, it stays where it was without them.
    exec qemu-system-aarch64 -machine virt -accel "$accel" -cpu "$cpu" -m "$mem" \
        -drive if=pflash,format=raw,readonly=on,file="$code" \
        -drive if=pflash,format=raw,file="$vars" \
        -drive if=none,id=esp,format=raw,file="$disk" -device virtio-blk-pci,drive=esp,bootindex=0 $input \
        -device ramfb -serial "$serial" -no-reboot "$@"
    ;;
*)
    echo "unknown arch: $arch" >&2
    exit 2
    ;;
esac
