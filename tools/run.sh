#!/bin/sh
# Boot the built ESP directory under QEMU with EDK2 firmware, from a disk
# that is made of it.
# usage: tools/run.sh <x86_64|aarch64> [extra qemu args...]
# env:   SERIAL=mon:stdio|stdio|file:path   MEM=512M   NO_HVF=1 (force TCG on aarch64)
#        (mon:stdio, the default, hands Ctrl-C to the kernel, which stops a
#        computation with it; Ctrl-A X leaves QEMU. With stdio, Ctrl-C ends QEMU.)
#        DISK=build/claraos.img (boot that raw image, and write to it, instead of
#        build/disk-<arch>.img, the machine's own disk. That one is made of the
#        ESP directory the first time, by tools/mkdisk.py, and kept from then
#        on, with whatever the kernel wrote to it: the world that was saved and
#        every file. A newer build does not make it again. It reaches the
#        machine as a second disk, build/upgrade-<arch>.img, which says that
#        the system on it is to be taken at once: the system that is running
#        takes it, starts the machine again to try it, and the old one is
#        there until the new one has come to its prompt (lisp/system.lisp).)
#        FRESH=1 (a new disk for the machine all the same, as if it had never
#        run: the one that was there is kept, under another name, which is said)
#        SIZE=1024 (how many MiB the machine's own disk has. A world is saved
#        on it, and the one that was saved before is there until the new one
#        is whole, so the disk has room for the largest world that a machine
#        of 512 MiB can save, twice, and for the user's files beside them. Most
#        of such a disk is nothing, and takes no room on this computer. A disk
#        that is smaller, as every disk was that the tools made up to 0.0.54,
#        is made again that large with every file that it holds, by
#        tools/mkdisk.py, and the disk that was there is kept, under another
#        name, which is said. SIZE= leaves a disk as it is, and makes a new
#        one as small as they were, 35 MiB.)
#        INPUT="-device virtio-keyboard-pci ..." (the keyboard and the pointers the
#        machine gets; the default is a virtio keyboard, mouse and tablet, and
#        INPUT= gives a machine with none of them)
#        UTM=1 (the keyboard, the pointers and the sound card that UTM gives a
#        machine which is not told otherwise, in place of virtio's: a USB
#        controller with a tablet, a mouse and a keyboard at its ports, and
#        Intel's sound card. INPUT= and SOUND= still say something else, each
#        for its own part)
#        NET="-netdev user,id=net -device virtio-net-pci,netdev=net" (the network
#        card the machine gets, and what is at the other end of it; the default
#        is a virtio card on a network that QEMU makes up, on which the machine
#        is 10.0.2.15, this computer is 10.0.2.2, and whatever this computer
#        reaches is reached through it. NET= gives a machine with no card)
#        FORWARD=8007:7 (on that network nothing reaches the machine by itself.
#        This hands on what connects to the port 8007 of this computer, from
#        this computer and from nowhere else, to the port 7 of the machine, for
#        a machine that takes connections there: `nc 127.0.0.1 8007`)
#        RNG="-device virtio-rng-pci" (the device that makes numbers which nobody
#        can guess, of the host's own making: the default. Nothing is fetched
#        by HTTPS without one. RNG= gives a machine with none)
#        SOUND="-audiodev coreaudio,id=sound -device virtio-sound-pci,audiodev=sound,streams=1"
#        (the sound card the machine gets, and where what it plays goes: the
#        default is a virtio card whose sound comes out of this computer, by
#        the first way of QEMU's that there is here, CoreAudio on a Mac,
#        PipeWire, PulseAudio or ALSA elsewhere, and into nothing when QEMU
#        has none of them. SOUND= gives a machine with no card, which plays
#        nothing; and
#        SOUND="-audiodev wav,id=sound,path=heard.wav -device virtio-sound-pci,audiodev=sound,streams=1"
#        writes what is played into a file, and nothing is heard)
#        WORK=~/clara-work.img (a second disk, the user's own: a raw image with a
#        FAT volume, for files that are to be apart from the machine's disk, and
#        to outlive it. A .dmg that macOS made is such an image too, when it is
#        a plain read/write one. Nothing here makes that file or makes it
#        again; the kernel finds its volume after the boot volume, and the
#        manual says how to make one and how to reach it, under "A disk of
#        your own".)
#        Either disk that is still open on the Mac, in the Finder, is ejected
#        there first, which is said: QEMU does not start with one that is.
set -eu
arch=${1:?usage: tools/run.sh <x86_64|aarch64> [qemu args]}
shift
esp=${ESP:-build/esp}
share=${QEMU_SHARE:-/opt/homebrew/share/qemu}
serial=${SERIAL:-mon:stdio}
mem=${MEM:-512M}
size=${SIZE-1024}
case "$size" in
*[!0-9]*)
    echo "tools/run.sh: SIZE is how many MiB the machine's disk has, a number, and not \"$size\"" >&2
    exit 1 ;;
esac
if [ -n "${UTM:-}" ]; then
    input=${INPUT--device nec-usb-xhci,id=usb-bus -device usb-tablet,bus=usb-bus.0 -device usb-mouse,bus=usb-bus.0 -device usb-kbd,bus=usb-bus.0}
    card="-device intel-hda -device hda-duplex,audiodev=sound"
else
    input=${INPUT--device virtio-keyboard-pci -device virtio-mouse-pci -device virtio-tablet-pci}
    card="-device virtio-sound-pci,audiodev=sound,streams=1"
fi
forward=${FORWARD:+,hostfwd=tcp:127.0.0.1:${FORWARD%%:*}-:${FORWARD##*:}}
net=${NET--netdev user,id=net$forward -device virtio-net-pci,netdev=net}
random=${RNG--device virtio-rng-pci}
# What the machine plays goes out by the first of these that QEMU has
# here; one stream, the one that plays, since nothing here records.
if [ -z "${SOUND+set}" ]; then
    out=none
    for way in coreaudio pipewire pa alsa; do
        if "qemu-system-$arch" -audiodev help 2> /dev/null | grep -qx "$way"; then
            out=$way
            break
        fi
    done
    SOUND="-audiodev $out,id=sound $card"
fi
sound=$SOUND
# Left to itself QEMU gives some machines a card of its own choosing, so no
# card has to be said.
[ -n "$net" ] || net="-nic none"
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

# A disk that is put aside is kept: under the first name of its kind that
# is not taken yet.
aside() {
    kept=${1%.img}-$2.img
    n=2
    while [ -e "$kept" ]; do
        kept=${1%.img}-$2-$n.img
        n=$((n + 1))
    done
    mv "$1" "$kept"
}

# A machine that is running from a disk has it, and a second one cannot:
# QEMU says only that it failed to get a lock. Where the host can say who
# has a file open, that is asked first.
in_use() {
    command -v lsof > /dev/null 2>&1 || return 1
    holder=$(lsof -t -- "$1" 2> /dev/null | head -1)
    [ -n "$holder" ] || return 1
    case "$(ps -o comm= -p "$holder" 2> /dev/null)" in
    *qemu*) return 0 ;;
    *) return 1 ;;
    esac
}

if [ -n "${DISK:-}" ]; then
    disk=$DISK
    release "$disk"
else
    disk=build/disk-$arch.img
    release "$disk"
    if [ -f "$disk" ] && in_use "$disk"; then
        echo "tools/run.sh: a machine is running from $disk already (process $holder), and there is one machine to a disk." >&2
        echo "    Shut that one down first: (clara.system:shut-down) at its prompt." >&2
        exit 1
    fi
    want=$(ls "$esp/clara" 2> /dev/null | head -1)
    # A run that was stopped between putting the smaller disk aside and
    # giving the larger one its name left the machine's disk under this one.
    larger=${disk%.img}-larger.img
    if [ ! -f "$disk" ] && [ -f "$larger" ]; then
        mv "$larger" "$disk"
    fi
    if [ -f "$disk" ] && [ -n "${FRESH:-}" ]; then
        aside "$disk" before
        echo "tools/run.sh: a new disk for this machine, as FRESH asks; the one that was there is kept as $kept" >&2
    fi
    if [ -f "$disk" ]; then
        have=$(python3 -I tools/mkdisk.py --systems "$disk" | tr '\n' ' ' | sed 's/ *$//')
        if [ -z "$have" ]; then
            # A disk from before a system had a directory of its own: what is on it
            # cannot take a newer system, and the kernel of this build would not
            # find its files there.
            aside "$disk" old
            echo "tools/run.sh: $disk held a ClaraOS from before one could take a newer one in place (0.0.25 or older)." >&2
            echo "    It is kept as $kept, and the machine starts from a new disk. Files that were written on" >&2
            echo "    the old one can be carried across on this computer: both are FAT volumes, and open here." >&2
        else
            # A disk that is smaller than a machine's disk is made now holds a
            # world twice only while the world is small, and a world that
            # has been worked in is not (issue #140): its files go onto a disk of
            # the size that is wanted, each held against the old disk once it
            # is written, and the old disk is kept as it is. When that does not
            # work the machine has the disk that it had.
            had=$(($(wc -c < "$disk") / 1048576))
            if [ -n "$size" ] && [ "$had" -lt "$size" ]; then
                rm -f "$larger"
                if python3 -I tools/mkdisk.py --size "$size" --grow "$disk" "$larger"; then
                    aside "$disk" small
                    mv "$larger" "$disk"
                    echo "tools/run.sh: the disk of this machine had $had MiB, and is to have $size: every file of it is on a disk of that size now," >&2
                    echo "    $disk, and the disk that was there is kept as $kept" >&2
                else
                    rm -f "$larger"
                    echo "tools/run.sh: the files of $disk could not be put on a larger disk, so the machine starts from it as it is" >&2
                fi
            fi
            if [ "$have" != "$want" ]; then
                # Another system than the one that was built: the build goes to the
                # machine as a second disk, which says that it is to be taken at once.
                upgrade=build/upgrade-$arch.img
                if [ ! -f "$upgrade" ] || [ -n "$(find "$esp" -newer "$upgrade" -print | head -1)" ]; then
                    rm -rf build/upgrade-esp
                    cp -R "$esp" build/upgrade-esp
                    : > build/upgrade-esp/clara/at-once
                    python3 -I tools/mkdisk.py build/upgrade-esp "$upgrade"
                fi
                echo "tools/run.sh: $disk holds ClaraOS $have, and the build is $want: the machine is given the build" >&2
                echo "    as a second disk, takes it, and starts again by itself to try it." >&2
                set -- "$@" -drive "if=none,id=upgrade,format=raw,readonly=on,file=$upgrade" -device virtio-blk-pci,drive=upgrade
            fi
        fi
    fi
    if [ ! -f "$disk" ]; then
        # shellcheck disable=SC2086
        python3 -I tools/mkdisk.py ${size:+--size $size} "$esp" "$disk"
    fi
fi

case "$arch" in
x86_64)
    firmware "$share/edk2-x86_64-code.fd" "$share/edk2-i386-vars.fd" \
             /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd
    exec qemu-system-x86_64 -machine q35 -m "$mem" \
        -drive if=pflash,format=raw,readonly=on,file="$code" \
        -drive if=pflash,format=raw,file="$vars" \
        -drive if=none,id=esp,format=raw,file="$disk" -device virtio-blk-pci,drive=esp,bootindex=0 $input $net \
        -serial "$serial" "$@" $random $sound
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
        -drive if=none,id=esp,format=raw,file="$disk" -device virtio-blk-pci,drive=esp,bootindex=0 $input $net \
        -device ramfb -serial "$serial" "$@" $random $sound
    ;;
*)
    echo "unknown arch: $arch" >&2
    exit 2
    ;;
esac
