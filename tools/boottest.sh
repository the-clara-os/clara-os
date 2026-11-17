#!/bin/sh
# Headless boot check: boot one arch under QEMU; when the kernel starts to
# read, type a session at it, on the serial port and on the keyboard; wait
# for the kernel's last line; compare what it answered with what the
# session says it must; then save what the screen shows as a PNG.
# usage: tools/boottest.sh <x86_64|aarch64> [extra qemu args...]
#        such as: -smp 4, -cpu max, -machine gic-version=2
# env:   TIMEOUT=90   MARKER="text to wait for"
#        SESSION=tools/session.txt (what is typed and what has to come back;
#                 empty: only Ctrl-D is typed)
#        NAME=aarch64-gic2 (what the files in build/ are called; default: the arch)
#        plus what tools/run.sh reads
set -eu
arch=${1:?usage: tools/boottest.sh <arch> [qemu args]}
shift
name=${NAME:-$arch}
marker=${MARKER:-clara: nothing more to do}
timeout=${TIMEOUT:-90}
session=${SESSION-tools/session.txt}
log=build/boot-$name.log
shot=build/screen-$name.png
sock=build/monitor-$name.sock
keys=build/serial-$name.in
orders=build/monitor-$name.in
typing=build/typing-$name
heard=build/session-$name.txt
scratch=build/scratch-$name.img
mkdir -p build
rm -f "$shot" "$sock" "$keys" "$orders" "$heard" "$typing".* "$scratch"
: > "$log"

# A second disk, a mebibyte of zeroes, for a session to write to: the boot
# volume is a directory of the host's that QEMU shows as a disk, and not
# for writing sectors to. It comes after every other device of the machine.
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
# So the session is typed in parts, and a part waits for a line of the
# kernel's: a Ctrl-C or a command, and what follows them, until the kernel
# has echoed the line before, which it is evaluating by then; a line for
# the keyboard until the kernel has printed the line before the ^K, since
# what is typed on the keyboard is read ahead of what the serial port still
# holds; and what follows such a line until that line has been echoed. A
# line that is waited for must not come earlier in the session as well.
#   $typing.N          what part N types on the serial port
#   $typing.N.monitor  the commands it sends to the monitor first
#   $typing.N.after    the line that the kernel has to have printed
LC_ALL=C awk -v out="$typing" '
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
    /^\^K$/     { begin_part(before); keyboard = 1; next }
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
    END         { if (commands) {
                      print "tools/boottest.sh: a session cannot end with a ^M line: Ctrl-D would not wait for it" > "/dev/stderr"
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
SERIAL=stdio tools/run.sh "$arch" -display none -monitor "unix:$sock,server=on,wait=off" "$@" \
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
    [ -f "$typing.$part.after" ] &&
        { LC_ALL=C tr -d '\r' < "$log"; printf '\001'; } | LC_ALL=C grep -qxF -- "$(cat "$typing.$part.after")"
}

# The kernel echoes what is typed after its prompt, so what it printed
# between its invitation and its last line has to be the transcript, and
# after it the prompt at which Ctrl-D arrived. A Ctrl-C that stops a form
# is not echoed, and the other lines that begin with ^ are for this script.
check_session() {
    [ -n "$session" ] || return 0
    LC_ALL=C tr -d '\r' < "$log" | LC_ALL=C sed -n '/^clara: reading/,/^clara: nothing/p' \
        | sed '1d;$d' > "$heard"
    { grep -v '^^' "$session"; echo '> '; } | diff -u - "$heard"
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

i=0
while [ "$i" -lt $((timeout * 4)) ]; do
    if grep -q "$marker" "$log"; then
        screenshot_and_quit
        stop_qemu
        if [ "$part" -gt 0 ] && ! check_session; then
            echo "boottest $name: FAILED, the kernel did not answer $session as written (above: -expected, +heard)"
            exit 1
        fi
        [ -s "$shot" ] && screen="screen saved to $shot" || screen="no screenshot"
        echo "boottest $name: ok after $((i / 4))s, $screen"
        exit 0
    fi
    if [ "$part" -eq 0 ]; then
        ! grep -q '^clara: reading' "$log" || type_part
    elif echoed; then
        type_part
    fi
    # A kernel that has stopped with a report is not going to say more.
    if grep -q '^panic: \|^exception: ' "$log"; then
        break
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
done
stop_qemu
echo "boottest $name: FAILED, no '$marker' after $((i / 4))s of ${timeout}s"
echo "--- qemu ---"; cat "build/qemu-$name.log"
echo "--- serial ---"; tail -40 "$log"
exit 1
