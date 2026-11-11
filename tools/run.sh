#!/bin/sh
# Boot the built ESP directory under QEMU with EDK2 firmware.
# usage: tools/run.sh <x86_64|aarch64> [extra qemu args...]
# env:   SERIAL=stdio|file:path   MEM=512M   NO_HVF=1 (force TCG on aarch64)
#        DISK=build/claraos.img (boot the raw image instead of the ESP directory)
set -eu
arch=${1:?usage: tools/run.sh <x86_64|aarch64> [qemu args]}
shift
esp=${ESP:-build/esp}
share=${QEMU_SHARE:-/opt/homebrew/share/qemu}
serial=${SERIAL:-stdio}
mem=${MEM:-512M}
mkdir -p build
if [ -n "${DISK:-}" ]; then
    esp_drive="-drive format=raw,file=$DISK"
else
    esp_drive="-drive format=raw,file=fat:rw:$esp"
fi

case "$arch" in
x86_64)
    vars=build/vars-x86_64.fd
    [ -f "$vars" ] || cp "$share/edk2-i386-vars.fd" "$vars"
    exec qemu-system-x86_64 -machine q35 -m "$mem" \
        -drive if=pflash,format=raw,readonly=on,file="$share/edk2-x86_64-code.fd" \
        -drive if=pflash,format=raw,file="$vars" \
        $esp_drive \
        -serial "$serial" -no-reboot "$@"
    ;;
aarch64)
    vars=build/vars-aarch64.fd
    [ -f "$vars" ] || cp "$share/edk2-arm-vars.fd" "$vars"
    accel=tcg cpu=cortex-a72
    if [ "$(uname -m)" = arm64 ] && [ -z "${NO_HVF:-}" ]; then
        accel=hvf cpu=host
    fi
    exec qemu-system-aarch64 -machine virt -accel "$accel" -cpu "$cpu" -m "$mem" \
        -drive if=pflash,format=raw,readonly=on,file="$share/edk2-aarch64-code.fd" \
        -drive if=pflash,format=raw,file="$vars" \
        $esp_drive \
        -device ramfb -serial "$serial" -no-reboot "$@"
    ;;
*)
    echo "unknown arch: $arch" >&2
    exit 2
    ;;
esac
