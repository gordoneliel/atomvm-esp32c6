# atomvm-esp32c6

Custom [AtomVM](https://github.com/atomvm/AtomVM) firmware for Seeed Studio XIAO ESP32-C5/C6, with BLE provisioning, NervesHub fleet management, A/B OTA updates, and health monitoring.

## Overview

This project builds a custom AtomVM firmware with additional NIF components and runs an Elixir application ("sesame") on XIAO ESP32 boards.

### Custom firmware features

- **BLE (NimBLE)** — GATT server with advertising, notifications, and event callbacks. Used for WiFi provisioning via mobile app. Auto-disables after WiFi connects to free RAM
- **A/B OTA updates** — Two AVM partition slots. NervesHub pushes firmware to the inactive slot, device reboots and validates. Auto-rollback after 3 failed boots
- **NervesHub integration** — Fleet management via [nerves_hub_link_avm](https://github.com/gordoneliel/nerves_hub_link_avm). Shared secret auth, health reporting, remote reboot/identify
- **WebSocket NIF** — ESP-IDF `esp_websocket_client` wrapper with custom HTTP header support for NervesHub auth
- **WiFi scan NIF** — Native WiFi scanning exposed to Erlang for BLE-based network selection
- **CPU usage NIF** — FreeRTOS runtime stats for real-time CPU utilization reporting
- **PSRAM support** — 8MB PSRAM on C5 for comfortable WiFi + BLE + TLS coexistence

### Sesame application

The `sesame/` directory contains the Elixir application:

| Module | Role |
|--------|------|
| `Wifi` | WiFi driver, BLE-based provisioning, NVS credential persistence, auto-connect on reboot |
| `Led` | Status LED (blinks during WiFi connect, solid when connected) |
| `Radar` | Reads mmWave radar sensor over UART (256000 baud) |
| `Ble` | BLE GATT server with network provisioning and radar streaming services |
| `Heart` | Marks the current OTA slot as valid after 30s of stable boot |
| `Hub.Supervisor` | Waits for SNTP sync, then starts NervesHub connection |
| `Hub.FwupWriter` | Handles firmware partition writes during OTA updates |
| `Hub.Client` | NervesHub lifecycle callbacks (reboot, identify, connect/disconnect) |
| `Hub.HealthProvider` | Reports memory, CPU, and process metrics to NervesHub |

## Project structure

```
atomvm-esp32c6/
├── AtomVM/                       # AtomVM source (v0.7.0-dev, custom build)
├── components/
│   ├── atomvm_ble/               # BLE NIF (NimBLE GATT server + deinit)
│   ├── atomvm_boot_env/          # Boot environment NIF (A/B slot management)
│   ├── atomvm_partition/          # Partition write NIF (OTA flash writes)
│   ├── atomvm_sys_info/          # CPU usage NIF (FreeRTOS runtime stats)
│   ├── atomvm_websocket/         # WebSocket NIF (ESP-IDF client + custom headers)
│   └── atomvm_wifi_scan/         # WiFi scan NIF
├── sesame/                       # Elixir application
│   ├── lib/
│   │   ├── app.ex                # Main supervisor
│   │   └── sesame/
│   │       ├── hub/              # NervesHub integration
│   │       ├── ble/              # BLE GATT services
│   │       ├── wifi.ex           # WiFi management
│   │       ├── led.ex            # Status LED
│   │       ├── radar.ex          # mmWave sensor
│   │       └── heart.ex          # OTA boot validation
│   ├── mix.exs
│   └── .envrc                    # NervesHub credentials (not committed)
├── tools/
│   ├── ble_test.py               # BLE scan/connect test script
│   └── web/                      # Web Bluetooth debug UI
└── README.md
```

## Hardware

- **Board**: Seeed Studio XIAO ESP32-C5 (384KB SRAM, 8MB PSRAM, 8MB flash, WiFi 6, BLE 5, dual-band)
- **Also supports**: XIAO ESP32-C6 (4MB flash, WiFi 6, BLE 5)
- **Radar**: mmWave presence sensor on UART (GPIO2 RX, GPIO3 TX)
- **LED**: GPIO27 (C5) / GPIO15 (C6)
- **Antenna**: External antenna required on C5 (u.FL connector)

## Quick start

### Prerequisites

- ESP-IDF v5.5+ (v5.5.4 recommended for C5 support; v5.4 works for C6 only)
- Erlang/OTP and Elixir
- [direnv](https://direnv.net/) (optional, auto-loads `.envrc`)

### Environment setup

```bash
# Create .envrc with your NervesHub credentials
cat > sesame/.envrc << 'EOF'
export NERVES_HUB_KEY="your-product-key"
export NERVES_HUB_SECRET="your-product-secret"
EOF

# Load env vars (or use direnv)
source sesame/.envrc
```

### Build firmware (first time)

```bash
# Set target chip
cd AtomVM/src/platforms/esp32
source /path/to/esp-idf/export.sh
idf.py set-target esp32c5  # or esp32c6
idf.py build

# Flash firmware + bootloader + partition table
esptool.py --chip esp32c5 -p /dev/cu.usbmodem2101 -b 460800 \
  write_flash --flash_mode dio --flash_size 4MB --flash_freq 80m \
  0x2000 build/bootloader/bootloader.bin \
  0x8000 build/partition_table/partition-table.bin \
  0x10000 build/atomvm-esp32.bin
```

### Build and flash the Elixir app

```bash
cd sesame
source .envrc

# Compile and package
MIX_ENV=default mix compile --force
MIX_ENV=default mix atomvm.packbeam

# Combine with AtomVM standard libraries
mix run -e '
ExAtomVM.PackBEAM.make_avm([
  {Path.expand("sesame.avm"), []},
  {Path.expand("../AtomVM/build/libs/atomvmlib.avm"), []},
  {Path.expand("../AtomVM/build/libs/avm_esp32/src/avm_esp32.avm"), []}
], "/tmp/combined.avm")
'

# Flash to both A/B partitions
esptool.py --chip esp32c5 -p /dev/cu.usbmodem2101 -b 460800 \
  write_flash 0x260000 /tmp/combined.avm 0x2F0000 /tmp/combined.avm
```

### First boot

1. Device boots and starts BLE advertising as "sesame"
2. Connect via the web tool (`tools/web/index.html`) or BLE test script
3. Scan networks and send connect command: `connect:SSID:PASSWORD`
4. WiFi connects, credentials saved to NVS, BLE disabled to free RAM
5. SNTP syncs, NervesHub channel connects
6. Health metrics appear on NervesHub dashboard

### OTA updates via NervesHub

Once connected to NervesHub, firmware updates are managed through the NervesHub dashboard. The device:

1. Receives update notification on the device channel
2. Downloads firmware with streaming SHA256 verification
3. Writes to the inactive AVM partition
4. Swaps boot slot and reboots
5. `Heart` module validates the new firmware after 30s
6. If the firmware crashes 3 times, the bootloader auto-rolls back

### Partition layout (4MB flash)

| Partition | Offset | Size | Purpose |
|-----------|--------|------|---------|
| nvs | 0x9000 | 24KB | Non-volatile storage (WiFi credentials, etc.) |
| phy_init | 0xF000 | 4KB | PHY calibration data |
| factory | 0x10000 | 2.3MB | AtomVM firmware (C runtime + VM + NIFs) |
| avm_a | 0x260000 | 576KB | AVM slot A (Elixir app + stdlib) |
| avm_b | 0x2F0000 | 576KB | AVM slot B (inactive, for OTA) |

## NervesHub setup

The device connects to NervesHub using shared secret authentication. Configure your credentials:

```bash
# In sesame/.envrc (not committed to git)
export NERVES_HUB_KEY="nhp_your_product_key"
export NERVES_HUB_SECRET="your_product_secret"
```

Device settings are in `sesame/lib/sesame/hub/supervisor.ex`:
- `host` — NervesHub server hostname
- `identifier` — unique device ID
- `firmware_meta` — product, version, architecture, platform, UUID

## Memory considerations

### ESP32-C5 (384KB SRAM + 8MB PSRAM)
- PSRAM enabled, WiFi/LWIP buffers directed to PSRAM
- mbedTLS uses external (PSRAM) allocation
- BLE disabled after WiFi connects to free ~27KB internal RAM
- Typical usage: ~495KB used, ~8MB free

### ESP32-C6 (307KB SRAM, no PSRAM)
- More constrained, may need reduced WiFi/BLE buffer sizes in sdkconfig
- Consider disabling unnecessary features to fit TLS + WiFi + BLE

## Building the custom firmware from source

See [BUILD_BLE.md](BUILD_BLE.md) for detailed instructions on building the AtomVM firmware with all custom NIF components.
