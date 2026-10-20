#!/usr/bin/env bash
# Build stock AtomVM for the ESP32-C6 with Firefly's components and config.
#
#   firmware/idf.sh build
#   firmware/idf.sh -p /dev/cu.usbmodem101 flash monitor
#
# `flash` writes the firmware and AtomVM's libraries (boot.avm). Flash the
# app itself with `mix atomvm.esp32.flash` from firefly/.
#
# Requires ESP-IDF in the environment (source ~/esp/esp-idf/export.sh).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
atomvm="$root/AtomVM/src/platforms/esp32"
build="$root/build/firmware"
host="$root/build/atomvm-host"

# AtomVM's Erlang and Elixir libraries (elixir_esp32boot.avm) are built from the same AtomVM
# checkout on the host, so they always match the firmware.
if [ ! -f "$host/CMakeCache.txt" ]; then
    cmake -S "$root/AtomVM" -B "$host" > /dev/null
fi
cmake --build "$host" --target elixir_esp32boot > /dev/null

# firmware/sdkconfig.defaults is the source of truth: ESP-IDF only applies
# defaults when generating sdkconfig, so regenerate it when they change.
if [ "$root/firmware/sdkconfig.defaults" -nt "$build/sdkconfig" ]; then
    rm -f "$build/sdkconfig"
fi

# ESP-IDF keeps the component lockfile in the project directory, which is
# inside the AtomVM checkout (and ignored there). Track it in firmware/ instead.
lock="$root/firmware/dependencies.lock"
[ -f "$lock" ] && cp "$lock" "$atomvm/dependencies.lock"

status=0
idf.py -C "$atomvm" -B "$build" \
    -DIDF_TARGET=esp32c6 \
    -DSDKCONFIG="$build/sdkconfig" \
    -DEXTRA_COMPONENT_DIRS="$root/components" \
    -DSDKCONFIG_DEFAULTS="$atomvm/sdkconfig.defaults;$root/firmware/sdkconfig.defaults" \
    -DFIREFLY_BOOT_AVM="$host/libs/esp32boot/elixir_esp32boot.avm" \
    "$@" || status=$?

[ -f "$atomvm/dependencies.lock" ] && cp "$atomvm/dependencies.lock" "$lock"
exit $status
