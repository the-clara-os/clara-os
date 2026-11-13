#!/bin/sh
# Headless boot check: boot one arch under QEMU, wait for the kernel's last
# line on the serial port, then save what the screen shows as a PNG.
# usage: tools/boottest.sh <x86_64|aarch64> [extra qemu args...]
#        such as: -smp 4, -cpu max, -machine gic-version=2
# env:   TIMEOUT=90   MARKER="text to wait for"
#        NAME=aarch64-gic2 (what the files in build/ are called; default: the arch)
#        plus what tools/run.sh reads
set -eu
arch=${1:?usage: tools/boottest.sh <arch> [qemu args]}
shift
name=${NAME:-$arch}
marker=${MARKER:-clara: nothing more to do}
timeout=${TIMEOUT:-90}
log=build/boot-$name.log
shot=build/screen-$name.png
sock=build/monitor-$name.sock
mkdir -p build
rm -f "$shot" "$sock"
: > "$log"

SERIAL="file:$log" tools/run.sh "$arch" -display none -monitor "unix:$sock,server=on,wait=off" "$@" \
    > "build/qemu-$name.log" 2>&1 < /dev/null &
pid=$!

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
while [ "$i" -lt "$timeout" ]; do
    if grep -q "$marker" "$log"; then
        screenshot_and_quit
        stop_qemu
        [ -s "$shot" ] && screen="screen saved to $shot" || screen="no screenshot"
        echo "boottest $name: ok after ${i}s, $screen"
        exit 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    i=$((i + 1))
done
stop_qemu
echo "boottest $name: FAILED, no '$marker' within ${timeout}s"
echo "--- qemu ---"; cat "build/qemu-$name.log"
echo "--- serial ---"; tail -40 "$log"
exit 1
