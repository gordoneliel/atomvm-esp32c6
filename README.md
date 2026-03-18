# atomvm-esp32c6

Custom [AtomVM](https://github.com/atomvm/AtomVM) firmware for the XIAO ESP32-C6, with BLE support, A/B OTA updates, and Erlang distribution.

## Overview

This project builds a custom AtomVM firmware with additional NIF components (BLE, OTA) and runs an Elixir application ("sesame") on the XIAO ESP32-C6.

### Custom firmware features

- **BLE (NimBLE)** — GATT server with advertising, notifications, and event callbacks to Erlang processes
- **A/B OTA updates** — Custom partition layout with two AVM slots. New firmware is streamed over TCP, written to the inactive slot, and swapped on reboot. A boot counter auto-rolls back if the new firmware crashes 3 times without calling `mark_valid`
- **Erlang distribution** — The device runs as a named Erlang node on the local network, discoverable via EPMD

### Sesame application

The `sesame/` directory contains the Elixir application with these supervised processes:

| Module | Role |
|--------|------|
| `Wifi` | Connects to WiFi, posts IP to other processes |
| `Led` | Status LED on GPIO15 (blinks during WiFi connect, solid when connected) |
| `Dist` | Starts EPMD and Erlang distribution |
| `Radar` | Reads mmWave radar sensor over UART1 (256000 baud) |
| `Ble` | BLE GATT server, streams radar data as notifications |
| `OtaServer` | Listens on TCP port 8266 for OTA firmware pushes |
| `Heart` | Marks the current OTA slot as valid after 30s of stable boot |

## Project structure

```
atomvm-esp32c6/
├── AtomVM/                  # AtomVM source (v0.7.0-dev, custom build)
├── components/
│   └── atomvm_ble/          # Custom BLE NIF component (NimBLE)
├── sesame/                  # Elixir application
│   ├── lib/                 # Application source
│   └── mix.exs
├── BUILD_BLE.md             # How to build the BLE firmware from scratch
└── README.md
```

## Hardware

- **Board**: Seeed Studio XIAO ESP32-C6 (4MB flash, WiFi 6, BLE 5)
- **Radar**: mmWave presence sensor on UART1 (GPIO2 RX, GPIO3 TX)
- **LED**: GPIO15, active-low

## Quick start

### Prerequisites

- ESP-IDF v5.3 (only needed for building firmware from source)
- Erlang/OTP and Elixir

### Build and flash

```bash
cd sesame

# Build and flash the app
mix atomvm.esp32.flash
```

That's it. ExAtomVM handles packing the AVM and flashing via esptool. The flash offset, chip type, and serial port are configured in `mix.exs`.

To install the AtomVM firmware itself (first time only):

```bash
mix atomvm.esp32.install
```

### OTA update (over the network)

Once the device is running and connected to WiFi, you can push updates over the network without a USB cable:

```bash
cd sesame

# Push to device (defaults to sesame.local)
mix ota.push

# Or specify a host/IP
mix ota.push 192.168.1.46
```

This builds the app, packs it with the standard libraries into a combined AVM, streams it to the device over TCP port 8266, and the device reboots into the new firmware. If the new firmware boots successfully for 30 seconds, the `Heart` module marks it as valid. If it crashes 3 times before that, the bootloader automatically rolls back to the previous version.

### Partition layout (4MB flash)

| Partition | Offset | Size |
|-----------|--------|------|
| factory | 0x10000 | 2MB |
| boot.avm | 0x210000 | 512KB |
| main.avm | 0x290000 | 1.4MB |

See [BUILD_BLE.md](BUILD_BLE.md) for building the custom firmware from source.
