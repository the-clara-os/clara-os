#!/bin/sh
# Headless boot check: boot one arch under QEMU, from a disk made for the
# purpose; when the kernel starts to read, type a session at it, on the
# serial port and on the keyboard; wait for the kernel's last line; compare
# what it answered with what the session says it must; save what the
# screen shows as a PNG; and have the host look at the volume that the
# kernel booted from, and wrote to.
# usage: tools/boottest.sh <x86_64|aarch64> [extra qemu args...]
#        such as: -smp 4, -cpu max, -machine gic-version=2
# env:   TIMEOUT=90   MARKER="text to wait for" (the kernel's last line, which
#                 is "clara: nothing more to do" unless this says another. A
#                 session that ends by shutting the machine down has
#                 "clara: turning the machine off" for it: the machine then has
#                 to go by itself, and there is no screen left to save.)
#        SESSION=tools/session.txt (what is typed and what has to come back;
#                 empty: only Ctrl-D is typed. {{system}} in it is the name of
#                 the system that was built, and {{version}} its version.)
#        PANICS=1 (how many times the kernel is to stop with a report on the
#                 way, a panic or an exception: 0 unless this says otherwise,
#                 and one more than that ends the boot at once)
#        NAME=aarch64-gic2 (what the files in build/ are called; default: the arch)
#        MKDISK="--fat 16 --table mbr" (the kind of disk that is made of the ESP
#                 directory for the machine to boot from: tools/mkdisk.py)
#        DISK=build/boot-aarch64.img (boot a copy of that disk instead, with
#                 whatever is on it: the world that another boot saved, or the
#                 image that `make image` makes for UTM)
#        SPOIL=1 (and change a byte of the world that was saved on it first)
#        EXPECT="pattern" (a line that the boot report has to have; several
#                 patterns with ;; between them are a line each)
#        WORK=build/work.img (give the machine a copy of that disk as well, the
#                 way tools/run.sh gives a user's machine a disk of the user's
#                 own; afterwards the host looks at the volume on it too)
#        SERVE=directory (the machine has somewhere to fetch from: the
#                 directory, by HTTP, and a name server that knows every name
#                 which ends in .test, both on this computer and on one port
#                 (tools/serve.py). {{port}} in the session is that port,
#                 which the machine reaches at 10.0.2.2, and {{key}} is what
#                 KEY= says, the public half of the key that a release there
#                 is signed with. And the machine can be spoken to: what
#                 connects to another port of this computer is handed on to
#                 the port 7007 of the machine, and the web server does that
#                 when it is asked for /knock/<text>, and answers with what
#                 the machine said)
#        CERTS=directory (and the same directory by HTTPS, on another port,
#                 which is {{secure}} in the session: the certificates that
#                 the server shows are the ones in that directory, which
#                 tools/certs.py makes)
#        SOUND=capture (what the machine plays is written into
#                 build/sound-<name>.wav and nothing is heard: the default.
#                 Where the session says what is to be heard, in lines that
#                 begin with ^H, that file has to hold it, by tools/heard.py.
#                 Anything else is for tools/run.sh, as it stands: SOUND= is a
#                 machine with no sound card)
#        plus what tools/run.sh reads
set -eu
arch=${1:?usage: tools/boottest.sh <arch> [qemu args]}
shift
name=${NAME:-$arch}
marker=${MARKER:-clara: nothing more to do}
timeout=${TIMEOUT:-90}
# Does the session end with the machine turning itself off?
case "$marker" in
*"turning the machine off"*) goes=1 ;;
*) goes= ;;
esac
session=${SESSION-tools/session.txt}
log=build/boot-$name.log
shot=build/screen-$name.png
sock=build/monitor-$name.sock
keys=build/serial-$name.in
orders=build/monitor-$name.in
typing=build/typing-$name
heard=build/session-$name.txt
scratch=build/scratch-$name.img
boot=build/boot-$name.img
wav=build/sound-$name.wav
mkdir -p build
rm -f "$shot" "$sock" "$keys" "$orders" "$heard" "$typing".* "$scratch" "$wav"

# What the machine plays goes into a file, at the pace that its card plays
# at, so that the file has the numbers that the machine sent and no others.
case "${SOUND-capture}" in
capture) SOUND="-audiodev wav,id=sound,path=$wav,out.frequency=48000 -device virtio-sound-pci,audiodev=sound,streams=1" ;;
esac
export SOUND
: > "$log"

# A machine that is to fetch something gets somewhere to fetch it from,
# which lasts as long as this script does.
port=0 secure=0 knock=0
if [ -n "${SERVE:-}" ]; then
    rm -f "build/serve-$name.port"
    python3 -I tools/serve.py "$SERVE" "build/serve-$name.port" ${CERTS:+"$CERTS"} > "build/serve-$name.log" 2>&1 &
    server=$!
    trap 'kill "$server" 2> /dev/null || true' EXIT
    n=0
    while [ ! -s "build/serve-$name.port" ] && [ "$n" -lt 100 ]; do
        sleep 0.1
        n=$((n + 1))
    done
    read -r port secure knock < "build/serve-$name.port" 2> /dev/null || port=0
    if [ "$port" = 0 ]; then
        echo "boottest $name: FAILED, tools/serve.py did not start"
        cat "build/serve-$name.log"
        exit 1
    fi
    # the port of this computer that leads to the machine's port 7007, which the web server found free
    FORWARD=$knock:7007
    export FORWARD
fi

# A session can name the system that was built and its version, which are
# different for every build: they are written into a copy of it. And the
# ports that it fetches from, the key that what it fetches is signed
# with, how many certificates the system's list has ({{roots}}), and what
# time it is on this computer as the machine is started, in seconds since
# 1900 began, which is how the machine counts it too ({{now}}).
if [ -n "$session" ]; then
    system=$(ls "${ESP:-build/esp}/clara" 2> /dev/null | head -1)
    version=$(sed -n 's/^#define CLARA_VERSION "\(.*\)"/\1/p' kernel/kernel.h)
    sed -e "s/{{system}}/$system/g" -e "s/{{version}}/$version/g" -e "s/{{port}}/$port/g" -e "s/{{secure}}/$secure/g" \
        -e "s/{{key}}/${KEY:-}/g" -e "s/{{roots}}/$(grep -c 'BEGIN CERTIFICATE' lisp/roots.pem)/g" \
        -e "s/{{now}}/$(($(date +%s) + 2208988800))/g" \
        "$session" > "build/typed-$name.txt"
    session=build/typed-$name.txt
fi

# The disk that the machine boots from, and that its kernel writes to: a
# new one, or a copy of the one that was asked for, so that a disk is only
# ever written to by the boot it was made for.
if [ -z "${DISK:-}" ]; then
    # shellcheck disable=SC2086
    python3 -I tools/mkdisk.py ${MKDISK:-} build/esp "$boot"
elif [ ! "$DISK" -ef "$boot" ]; then
    rm -f "$boot"
    cp -c "$DISK" "$boot" 2> /dev/null || cp "$DISK" "$boot"
fi
[ -z "${SPOIL:-}" ] || python3 -I tools/mkdisk.py --spoil "$boot"

# A disk of the user's own, when the machine is to have one: a copy of it
# as well, so that the disk that was named is never written to, and the
# copy is what the next boot of the same machine can be given.
work=
if [ -n "${WORK:-}" ]; then
    work=build/work-$name.img
    if [ ! "$WORK" -ef "$work" ]; then
        rm -f "$work"
        cp -c "$WORK" "$work" 2> /dev/null || cp "$WORK" "$work"
    fi
fi

# A second disk, a mebibyte of zeroes, for a session to write sectors to
# that are nobody's: the boot volume has files on it. It comes after every
# other device of the machine.
dd if=/dev/zero of="$scratch" bs=1024 count=1024 2> /dev/null

# A session is a transcript. The lines that begin with a prompt, "> " or
# the two spaces of a form that goes on, are what gets typed, without the
# prompt, and Ctrl-D after the last one ends the kernel's reading. The
# lines that begin with ^ are not part of what the kernel says:
#   ^C          Ctrl-C on the serial port, for the form in the line before
#               it, which never ends by itself.
#   ^M command  a command for the QEMU monitor, sent while the kernel
#               evaluates the form in the line before it: "sendkey ctrl-c",
#               "mouse_move 30 20".
#   ^K          the line after it is typed on the keyboard, by sendkey, and
#               not on the serial port. Such a line is short: a key is four
#               events, with Shift eight, and the 64 that the keyboard's
#               queue holds are all that is sure to arrive on a slow machine.
#   ^T text     the text is typed on the keyboard as well, and Enter after
#               it, while the kernel evaluates the form in the line before
#               it: for a window, which echoes what is typed on the screen
#               and not on the serial port, so nothing waits for an echo.
#               As short as a line after ^K.
#   ^R          the machine starts again here, by the form in the line before
#               it: what follows is typed at the kernel that comes up then,
#               once it reads.
#   ^W pattern  wait until the kernel has printed a line that the pattern
#               fits, grep's kind of pattern, before what follows: a ^M that
#               is for a kernel which says nothing more by itself.
#   ^H words    what the machine is to have played by the end, a line for
#               every stretch of sound in the order they were played, as
#               tools/heard.py says it: "500 ms, 220 turns, 8192 left, 8192
#               right". Nothing is typed for it.
# So the session is typed in parts, and a part waits for a line of the
# kernel's: a Ctrl-C or a command, and what follows them, until the kernel
# has echoed the line before, which it is evaluating by then; a line for
# the keyboard until the kernel has printed the line before the ^K, since
# what is typed on the keyboard is read ahead of what the serial port still
# holds; and what follows such a line until that line has been echoed. A
# line that is waited for must not come earlier in the session as well.
# What follows a ^R waits until the kernel has said as often that it reads
# as the machine has been started by then.
#   $typing.N          what part N types on the serial port
#   $typing.N.monitor  the commands it sends to the monitor first
#   $typing.N.after    the line that the kernel has to have printed
#   $typing.N.boots    or how many times it has to have said that it reads
#   $typing.N.grep     or a pattern that a line of what it printed has to fit
LC_ALL=C awk -v out="$typing" -v goes="$goes" '
    function keyname(c,    i) {
        if (c ~ /^[a-z0-9]$/) return c
        if (c ~ /^[A-Z]$/) return "shift-" tolower(c)
        if (c == " ") return "spc"
        if ((i = index(")!@#$%^&*(", c))) return "shift-" (i - 1)
        if ((i = index(plain, c))) return names[i]
        if ((i = index(shifted, c))) return "shift-" names[i]
        printf "tools/boottest.sh: no key types \"%s\"\n", c > "/dev/stderr"
        exit 2
    }
    function begin_part(after) { part++; print after > (out "." part ".after"); commands = 0 }
    BEGIN       { part = 0; printf "" > (out "." part)
                  plain = "-=[];\047`\\,./"; shifted = "_+{}:\"~|<>?"
                  split("minus equal bracket_left bracket_right semicolon apostrophe grave_accent backslash comma dot slash",
                        names, " ") }
    /^\^C$/     { begin_part(last); printf "\003" > (out "." part); next }
    /^\^M /     { if (!commands) begin_part(last)
                  print substr($0, 4) > (out "." part ".monitor"); commands = 1; next }
    /^\^T /     { if (!commands) begin_part(last)
                  for (i = 4; i <= length($0); i++)
                      print "sendkey " keyname(substr($0, i, 1)) > (out "." part ".monitor")
                  print "sendkey ret" > (out "." part ".monitor"); commands = 1; next }
    /^\^K$/     { begin_part(before); keyboard = 1; next }
    /^\^R$/     { part++; boots++; print boots + 1 > (out "." part ".boots"); commands = 0; next }
    /^\^W /     { part++; print substr($0, 4) > (out "." part ".grep"); commands = 0; next }
    /^\^H /     { next }
    /^[> ] /    { if (keyboard) {
                      for (i = 3; i <= length($0); i++)
                          print "sendkey " keyname(substr($0, i, 1)) > (out "." part ".monitor")
                      print "sendkey ret" > (out "." part ".monitor")
                      keyboard = 0; begin_part($0)
                  } else {
                      if (commands) begin_part(last)
                      print substr($0, 3) > (out "." part)
                  }
                  last = $0 }
                { before = $0 }
    END         { if (goes) exit 0 # the machine turns itself off, and nothing ends the reading
                  if (commands) {
                      print "tools/boottest.sh: a session cannot end with a ^M or a ^T line: Ctrl-D would not wait for it" > "/dev/stderr"
                      exit 2
                  }
                  printf "\004" > (out "." part) }' "${session:-/dev/null}"

# The serial port is QEMU's standard input and output. What the kernel
# prints goes to the log. What it reads comes from a FIFO, which this
# script keeps open at both ends so that QEMU never sees it end, and
# writes to once the kernel is listening: typed any earlier, the firmware
# would take it for keys pressed at its own console.
mkfifo "$keys"
exec 3<> "$keys"
DISK="$boot" WORK="$work" SERIAL=stdio tools/run.sh "$arch" -display none -monitor "unix:$sock,server=on,wait=off" "$@" \
    -drive "if=none,id=scratch,format=raw,file=$scratch" -device virtio-blk-pci,drive=scratch \
    < "$keys" > "$log" 2> "build/qemu-$name.log" 3>&- &
pid=$!

# The QEMU monitor is a socket, and one connection to it stays open for the
# whole boot, fed from a second FIFO: keys for the keyboard, moves of the
# mouse, and at the end the order for a screenshot.
mkfifo "$orders"
exec 4<> "$orders"
n=0
while [ ! -S "$sock" ] && [ "$n" -lt 50 ]; do
    sleep 0.1
    n=$((n + 1))
done
nc -U "$sock" < "$orders" > /dev/null 2>&1 3>&- 4>&- &

part=0 # the next one to type

type_part() {
    [ ! -f "$typing.$part.monitor" ] || cat "$typing.$part.monitor" >&4
    [ ! -f "$typing.$part" ] || cat "$typing.$part" >&3
    part=$((part + 1))
}

# Has the kernel printed the line that the next part waits for? All of it,
# with its end: a line typed on the keyboard is echoed key by key, and it
# is not over before Enter is. So the log gets a byte at its end that no
# line has, which only a line that has not ended runs into.
echoed() {
    if [ -f "$typing.$part.boots" ]; then
        [ "$(grep -c '^clara: reading' "$log")" -ge "$(cat "$typing.$part.boots")" ]
    elif [ -f "$typing.$part.grep" ]; then
        grep -q -- "$(cat "$typing.$part.grep")" "$log"
    else
        [ -f "$typing.$part.after" ] &&
            { LC_ALL=C tr -d '\r' < "$log"; printf '\001'; } | LC_ALL=C grep -qxF -- "$(cat "$typing.$part.after")"
    fi
}

# The kernel echoes what is typed after its prompt, so what it printed
# between its invitation and its last line has to be the transcript, and
# after it the prompt at which Ctrl-D arrived, when that is how the session
# ended. A Ctrl-C that stops a form is not echoed, and the other lines that
# begin with ^ are for this script. Where the machine was started again,
# what the firmware and the kernel said until the kernel read once more is
# no part of the session.
check_session() {
    [ -n "$session" ] || return 0
    last=$(LC_ALL=C tr -d '\r' < "$log" | LC_ALL=C grep -n -m 1 -- "$marker" | cut -d: -f1)
    LC_ALL=C tr -d '\r' < "$log" | head -n "$((last - 1))" | LC_ALL=C awk '
        /^clara: reading/ { reading = 1; next }
        !reading          { next }
                          { print }
        /^clara: starting the machine again/ { reading = 0 }' > "$heard"
    { grep -v '^^' "$session"; [ -n "$goes" ] || echo '> '; } | diff -u - "$heard"
}

# Give the last line time to reach the screen, then ask the QEMU monitor for
# a screenshot and to quit, and wait up to five seconds for it to do so.
screenshot_and_quit() {
    sleep 0.5
    printf 'screendump %s -f png\nquit\n' "$PWD/$shot" >&4
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 50 ]; do
        sleep 0.1
        n=$((n + 1))
    done
}

stop_qemu() {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# A machine that has said it is turning itself off has to be gone a moment
# later, without anybody having stopped it.
gone_by_itself() {
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 100 ]; do
        sleep 0.1
        n=$((n + 1))
    done
    ! kill -0 "$pid" 2>/dev/null
}

# The volume that the kernel booted from, and wrote to, as the host's own
# program for mending FAT volumes sees it: fsck_msdos on macOS, fsck.fat
# of the dosfstools elsewhere. It is asked to change nothing, and has to
# find nothing that it would change. The same for the volume of the user's
# own disk, when the machine had one.
check_volume() {
    if [ -x /sbin/fsck_msdos ]; then
        fsck=/sbin/fsck_msdos
    else
        fsck=$(PATH="$PATH:/usr/sbin:/sbin" command -v fsck.fat || true)
    fi
    [ -n "$fsck" ] || { volume="its volume was not looked at: the host has no fsck for FAT"; return 0; }
    for checked in "$boot" ${work:+"$work"}; do
        python3 -I tools/mkdisk.py --volume "$checked" "build/volume-$name.img"
        "$fsck" -n "build/volume-$name.img" > "build/fsck-$name.log" 2>&1 || return 1
        rm -f "build/volume-$name.img"
    done
    volume="its volume is in order"
    [ -z "$work" ] || volume="its volumes are in order"
}

# What the machine played, when the session says what that was to be: the
# file that QEMU wrote of it, as tools/heard.py describes it, against the
# lines of the session that begin with ^H.
check_sound() {
    [ -n "$session" ] && grep -q '^^H ' "$session" || return 0
    sed -n 's/^^H //p' "$session" > "build/hear-$name.txt"
    python3 -I tools/heard.py "$wav" > "build/heard-$name.txt" 2>&1 || true
    diff -u "build/hear-$name.txt" "build/heard-$name.txt"
}

# The lines that the boot report has to have, when some were asked for.
expected() {
    [ -n "${EXPECT:-}" ] || return 0
    # From the environment, and not with -v, which would take the backslashes of a pattern for its own.
    EXPECT="$EXPECT" awk 'BEGIN { n = split(ENVIRON["EXPECT"], pattern, ";;"); for (i = 1; i <= n; i++) print pattern[i] }' |
        while IFS= read -r pattern; do
            if ! grep -q "$pattern" "$log"; then
                echo "boottest $name: FAILED, the boot report has no line '$pattern'"
                exit 1
            fi
        done
}

i=0
while [ "$i" -lt $((timeout * 4)) ]; do
    if grep -q "$marker" "$log"; then
        if [ -n "$goes" ]; then
            if ! gone_by_itself; then
                stop_qemu
                echo "boottest $name: FAILED, the machine said that it was turning itself off, and was still there ten seconds later"
                exit 1
            fi
        else
            screenshot_and_quit
        fi
        stop_qemu
        if [ "$part" -gt 0 ] && ! check_session; then
            echo "boottest $name: FAILED, the kernel did not answer $session as written (above: -expected, +heard)"
            exit 1
        fi
        expected || exit 1
        if ! check_sound; then
            echo "boottest $name: FAILED, the machine did not play what $session says (above: -to be heard, +heard, by tools/heard.py $wav)"
            exit 1
        fi
        if ! check_volume; then
            echo "boottest $name: FAILED, the volume on $checked that the kernel wrote to is not in order, by $fsck:"
            cat "build/fsck-$name.log"
            exit 1
        fi
        [ -s "$shot" ] && screen="screen saved to $shot" || screen="no screenshot"
        echo "boottest $name: ok after $((i / 4))s, $volume, $screen"
        exit 0
    fi
    if [ "$part" -eq 0 ]; then
        ! grep -q '^clara: reading' "$log" || type_part
    elif echoed; then
        type_part
    fi
    # A kernel that has stopped with a report is not going to say more,
    # unless the session is one that starts the machine again after it.
    if [ "$(grep -c '^panic: \|^exception: ' "$log")" -gt "${PANICS:-0}" ]; then
        break
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
done
# The machine did not get there. What its screen shows goes with the logs,
# when the machine is still there to be asked: the serial port has no more
# to say of one that stands still, and the screen tells a firmware that
# did not start the system from a system that reported a fault, and both
# from a machine that was told to start again and did not.
if kill -0 "$pid" 2>/dev/null; then
    screenshot_and_quit || true
fi
stop_qemu
[ -s "$shot" ] && echo "boottest $name: the screen as it was is in $shot"
echo "boottest $name: FAILED, no '$marker' after $((i / 4))s of ${timeout}s"
echo "--- qemu ---"; cat "build/qemu-$name.log"
echo "--- serial ---"; tail -40 "$log"
exit 1
