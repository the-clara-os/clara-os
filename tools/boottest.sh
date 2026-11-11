#!/bin/sh
# Headless boot check: boot one arch under QEMU and wait for the kernel's last line.
# usage: tools/boottest.sh <x86_64|aarch64>     env: TIMEOUT=90
set -eu
arch=${1:?usage: tools/boottest.sh <arch>}
marker="clara: nothing more to do"
timeout=${TIMEOUT:-90}
log=build/boot-$arch.log
: > "$log"

SERIAL="file:$log" tools/run.sh "$arch" -display none -monitor none \
    > "build/qemu-$arch.log" 2>&1 < /dev/null &
pid=$!
i=0
while [ "$i" -lt "$timeout" ]; do
    if grep -q "$marker" "$log"; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        echo "boottest $arch: ok after ${i}s"
        exit 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    i=$((i + 1))
done
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
echo "boottest $arch: FAILED, no '$marker' within ${timeout}s"
echo "--- qemu ---"; cat "build/qemu-$arch.log"
echo "--- serial ---"; tail -40 "$log"
exit 1
