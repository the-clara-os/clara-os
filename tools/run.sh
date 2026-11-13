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
    esp_drive="-drive format=raw,file=$DISK"
else
    esp_drive="-drive format=raw,file=fat:rw:$esp"
fi

case "$arch" in
x86_64)
    firmware "$share/edk2-x86_64-code.fd" "$share/edk2-i386-vars.fd" \
             /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd
    exec qemu-system-x86_64 -machine q35 -m "$mem" \
        -drive if=pflash,format=raw,readonly=on,file="$code" \
        -drive if=pflash,format=raw,file="$vars" \
        $esp_drive \
        -serial "$serial" -no-reboot "$@"
    ;;
aarch64)
    firmware "$share/edk2-aarch64-code.fd" "$share/edk2-arm-vars.fd" \
             /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/AAVMF/AAVMF_VARS.fd
    accel=tcg cpu=cortex-a72
    if [ "$(uname -m)" = arm64 ] && [ -z "${NO_HVF:-}" ]; then
        accel=hvf cpu=host
    fi
    exec qemu-system-aarch64 -machine virt -accel "$accel" -cpu "$cpu" -m "$mem" \
        -drive if=pflash,format=raw,readonly=on,file="$code" \
        -drive if=pflash,format=raw,file="$vars" \
        $esp_drive \
        -device ramfb -serial "$serial" -no-reboot "$@"
    ;;
*)
    echo "unknown arch: $arch" >&2
    exit 2
    ;;
esac
