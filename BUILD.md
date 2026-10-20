# Building AtomVM firmware from source

The custom AtomVM firmware includes NIF components for Matter and the LED strip. Rebuild after modifying any C/C++ code in `components/`.

## Prerequisites

### 1. Install ESP-IDF v5.5

```bash
mkdir -p ~/esp
cd ~/esp
git clone -b v5.5.5 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh esp32c6
source export.sh
```

## Build

```bash
git submodule update --init
source ~/esp/esp-idf/export.sh

firmware/idf.sh build
```

`AtomVM/` is stock upstream AtomVM, pinned as a submodule. `firmware/idf.sh` wraps `idf.py` to build its ESP32 port with Firefly's additions, without modifying the AtomVM tree:

- `components/` is added via `EXTRA_COMPONENT_DIRS`
- `firmware/sdkconfig.defaults` is layered on top of AtomVM's defaults
- `firmware/partitions.csv` is referenced from there
- AtomVM's Erlang/Elixir libraries (`elixir_esp32boot.avm`) are built from the same checkout in `build/atomvm-host/`, and `components/boot_avm/` adds them to `flash`
- build output and `sdkconfig` go to `build/firmware/`; `sdkconfig` is regenerated whenever `firmware/sdkconfig.defaults` changes, so make config changes there rather than with `menuconfig`
- the component lockfile is tracked as `firmware/dependencies.lock` (esp-matter is pinned to `~1.6.0` in `components/atomvm_matter/idf_component.yml`)

`AtomVM/` is pinned to a commit on upstream's `release-0.7` branch, which carries fixes not yet tagged after v0.7.0-beta.0. To upgrade AtomVM, check out a newer commit or tag in `AtomVM/` and rebuild. The firmware and libraries always come from the same checkout.

## Flash

```bash
# Erase flash (recommended for first flash or after config changes)
firmware/idf.sh -p /dev/cu.usbmodem1101 erase-flash

# Flash firmware and AtomVM libraries (boot.avm)
firmware/idf.sh -p /dev/cu.usbmodem1101 flash

# Then flash the Elixir app (main.avm)
cd firefly
mix atomvm.esp32.flash --port /dev/cu.usbmodem1101
```

## NIF components

| Component | Description |
|-----------|-------------|
| `atomvm_matter` | Matter device stack (esp_matter / CHIP SDK wrapper) |
| `atomvm_led_strip` | LED strip driver |

## Key sdkconfig settings

The ESP32-C6 defaults are in `firmware/sdkconfig.defaults`:

- BLE enabled (NimBLE) for Matter commissioning
- IPv6 enabled for Thread/Matter, with lwIP autoconfiguration off (OpenThread assigns the Thread addresses) and 8 addresses per interface
- OpenThread FTD with SRP client and DNS client
- Matter over Thread enabled, advertising through SRP to the border router (`CONFIG_USE_MINIMAL_MDNS=n`)
- Test DAC provider with discriminator `0xF00` and PIN `20202021`
