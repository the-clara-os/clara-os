#!/bin/sh
# Headless boot check: boot one arch under QEMU; when the kernel starts to
# read from the serial port, type a session at it; wait for the kernel's
# last line; compare what it answered with what the session says it must;
# then save what the screen shows as a PNG.
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
typing=build/typing-$name
heard=build/session-$name.txt
mkdir -p build
rm -f "$shot" "$sock" "$keys" "$heard" "$typing".*
: > "$log"

# The serial port is QEMU's standard input and output. What the kernel
# prints goes to the log. What it reads comes from a FIFO, which this
# script keeps open at both ends so that QEMU never sees it end, and
# writes to once the kernel is listening: typed any earlier, the firmware
# would take it for keys pressed at its own console.
mkfifo "$keys"
exec 3<> "$keys"
SERIAL=stdio tools/run.sh "$arch" -display none -monitor "unix:$sock,server=on,wait=off" "$@" \
    < "$keys" > "$log" 2> "build/qemu-$name.log" 3>&- &
pid=$!

# A session is a transcript. The lines that begin with a prompt, "> " or
# the two spaces of a form that goes on, are what gets typed, without the
# prompt, and Ctrl-D after the last one ends the kernel's reading. A line
# that is ^C and nothing else is Ctrl-C, for the form in the line before
# it, which never ends by itself. Typed along with the rest it would stop
# whatever the kernel was evaluating when it arrived, so the session is
# typed in parts: a Ctrl-C and what follows it wait until the kernel has
# echoed the line before, which it is evaluating by then. That line must
# not come earlier in the session as well.
#   $typing.N        part N, with the Ctrl-C it begins with
#   $typing.N.after  the line that the kernel has to have echoed first
LC_ALL=C awk -v out="$typing" '
    BEGIN       { part = 0; printf "" > (out "." part) }
    /^\^C$/     { part++; print last > (out "." part ".after"); printf "\003" > (out "." part); next }
    /^[> ] /    { print substr($0, 3) > (out "." part); last = $0 }
    END         { printf "\004" > (out "." part) }' "${session:-/dev/null}"
part=0 # the next one to type

type_part() {
    cat "$typing.$part" >&3
    part=$((part + 1))
}

# Has the kernel echoed the line that the next part waits for?
echoed() {
    [ -f "$typing.$part.after" ] &&
        LC_ALL=C tr -d '\r' < "$log" | grep -qxF -- "$(cat "$typing.$part.after")"
}

# The kernel echoes what is typed after its prompt, so what it printed
# between its invitation and its last line has to be the transcript, and
# after it the prompt at which Ctrl-D arrived. A Ctrl-C that stops a form
# is not echoed.
check_session() {
    [ -n "$session" ] || return 0
    LC_ALL=C tr -d '\r' < "$log" | LC_ALL=C sed -n '/^clara: reading/,/^clara: nothing/p' \
        | sed '1d;$d' > "$heard"
    { grep -v '^^C$' "$session"; echo '> '; } | diff -u - "$heard"
}

# Give the last line time to reach the screen, then ask the QEMU monitor for
# a screenshot and to quit, and wait up to five seconds for it to do so.
screenshot_and_quit() {
    { sleep 0.5; printf 'screendump %s -f png\nquit\n' "$PWD/$shot"; } \
        | nc -w 5 -U "$sock" > /dev/null 2>&1 || true
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
