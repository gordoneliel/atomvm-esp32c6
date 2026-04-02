# atomvm-esp32c6

Custom [AtomVM](https://github.com/atomvm/AtomVM) firmware for Seeed Studio XIAO ESP32-C5/C6, with BLE provisioning, NervesHub fleet management, A/B OTA updates, and health monitoring.

## Overview

This project builds a custom AtomVM firmware with additional NIF components and runs an Elixir application ("sesame") on XIAO ESP32 boards. Updates are delivered over-the-air via [NervesHub](https://www.nerves-hub.org/) using the [Capsule (.cap)](https://github.com/gordoneliel/libcapsule) firmware packaging format, which bundles both the C firmware and the Elixir AVM into a single streamable archive with per-entry SHA256 verification.

### Custom firmware features

- **A/B OTA updates** — Dual firmware slots (ota_0/ota_1) and dual AVM slots (main_a/main_b) on 8MB flash. [Capsule](https://github.com/gordoneliel/libcapsule) `.cap` files bundle firmware + AVM into a single archive. NervesHub pushes to inactive slots, device reboots and validates. Auto-rollback after 3 failed boots
- **BLE (NimBLE)** — GATT server with advertising, notifications, and event callbacks. Used for WiFi provisioning via mobile app. Auto-disables after WiFi connects to free RAM
- **NervesHub integration** — Fleet management via [nerves_hub_link_avm](https://github.com/gordoneliel/nerves_hub_link_avm). Shared secret auth, health reporting, remote reboot/identify
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
| `Hub.Supervisor` | Waits for SNTP sync, starts NervesHub, loads firmware metadata from NVS |
| `Hub.FwupWriter` | Capsule (.cap) parser — streams entries to partitions with SHA256 verification |
| `Hub.Client` | NervesHub lifecycle callbacks (reboot, identify, connect/disconnect) |
| `Hub.HealthProvider` | Reports memory, CPU, and process metrics to NervesHub |

## Project structure

```
atomvm-esp32c6/
├── AtomVM/                       # AtomVM source (custom build, sesame-custom branch)
├── components/
│   ├── atomvm_ble/               # BLE NIF (NimBLE GATT server + deinit)
│   ├── atomvm_boot_env/          # Boot environment NIF (activate, active_slot, mark_valid)
│   ├── atomvm_partition/          # Partition NIF (erase/write by partition name)
│   ├── atomvm_sys_info/          # CPU usage NIF (FreeRTOS runtime stats)
│   └── atomvm_wifi_scan/         # WiFi scan NIF
├── sesame/                       # Elixir application
│   ├── config/config.exs         # NervesHub config (secrets from env vars)
│   ├── lib/
│   │   ├── app.ex                # Main supervisor
│   │   ├── mix/tasks/            # capsule.build and capsule.flash mix tasks
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
- [libcapsule](https://github.com/gordoneliel/libcapsule) CLI (build from source, `capsule` binary on PATH)
- [direnv](https://direnv.net/) (optional, auto-loads `.envrc`)

### Environment setup

```bash
# Create .envrc with your NervesHub credentials
cat > sesame/.envrc << 'EOF'
export NERVES_HUB_HOST="your-nerveshub-host"
export NERVES_HUB_PORT="443"
export NERVES_HUB_SSL="true"
export NERVES_HUB_KEY="your-product-key"
export NERVES_HUB_SECRET="your-product-secret"
EOF

# Load env vars (or use direnv)
source sesame/.envrc
```

### Build firmware (first time)

```bash
cd AtomVM/src/platforms/esp32
source /path/to/esp-idf/export.sh
idf.py set-target esp32c5  # or esp32c6
idf.py build
```

### Build and flash with Capsule

The `mix capsule.build` task compiles the Elixir app, packages the AVM, and bundles everything into a `.cap` file:

```bash
cd sesame
source .envrc

# Build a .cap file (firmware + AVM + metadata)
mix capsule.build
# → sesame-0.1.12.cap (2742KB)

# Flash to device via USB (full install with bootloader + partition table)
mix capsule.flash sesame-0.1.12.cap --full

# Flash to a specific slot
mix capsule.flash sesame-0.1.12.cap --slot 0

# Flash with full erase
mix capsule.flash sesame-0.1.12.cap --full --erase
```

### First boot

1. Device boots and starts BLE advertising as "sesame"
2. Connect via the web tool (`tools/web/index.html`) or BLE test script
3. Scan networks and send connect command: `connect:SSID:PASSWORD`
4. WiFi connects, credentials saved to NVS, BLE disabled to free RAM
5. SNTP syncs, NervesHub channel connects
6. Health metrics appear on NervesHub dashboard

### OTA updates via NervesHub

Once connected to NervesHub, firmware updates are managed through the NervesHub dashboard:

1. Build a new `.cap`: `mix capsule.build`
2. Upload the `.cap` to NervesHub as a firmware archive
3. Create a deployment targeting the device
4. Device receives update notification on the device channel
5. Downloads `.cap` with progress reporting to NervesHub
6. `FwupWriter` parses the `.cap` header, streams entries to inactive partitions (ota_X + main_X)
7. Verifies SHA256 of each entry
8. Activates the new slot (writes otadata + NVS), reboots
9. `Heart` module validates the new firmware after 30s
10. If the firmware crashes 3 times, auto-rolls back to the previous slot

Firmware metadata (version, UUID, product) is saved to NVS during OTA, so the device reports the correct version after rebooting.

### Partition layout (8MB flash)

| Partition | Offset | Size | Purpose |
|-----------|--------|------|---------|
| nvs | 0x9000 | 24KB | Non-volatile storage (WiFi creds, boot slot, firmware meta) |
| otadata | 0xF000 | 8KB | ESP-IDF A/B boot selection |
| phy_init | 0x11000 | 4KB | PHY calibration data |
| ota_0 | 0x20000 | 2.875MB | Firmware slot A (AtomVM + NIFs) |
| ota_1 | 0x300000 | 2.875MB | Firmware slot B |
| main_a | 0x5E0000 | 576KB | AVM slot A (Elixir app + stdlib) |
| main_b | 0x670000 | 576KB | AVM slot B |
| storage | 0x700000 | 1MB | General storage |

## Capsule (.cap) format

The [Capsule](https://github.com/gordoneliel/libcapsule) format bundles multiple partition images into a single streamable archive:

```
┌──────────────────────────────────┐
│ "CAP1" magic + flags + header    │
│ Entry table (name, size, SHA256) │
│ Metadata (key=value pairs)       │
│ Optional Ed25519 signature       │
├──────────────────────────────────┤
│ Entry 0 data (firmware binary)   │
│ Entry 1 data (AVM binary)        │
└──────────────────────────────────┘
```

- **Streamable** — header first, then data in order. No seeking required.
- **Verifiable** — SHA256 per entry, checked after streaming
- **Signable** — optional Ed25519 signature over the header
- **Extensible** — any number of named entries

The device-side `FwupWriter` parses the header in Elixir and maps entry names to partition pairs:
- `"app"` → `ota_0` / `ota_1` (firmware)
- `"avm"` → `main_a` / `main_b` (Elixir application)

## NervesHub setup

The device connects to NervesHub using shared secret authentication. Configure your credentials:

```bash
# In sesame/.envrc (not committed to git)
export NERVES_HUB_HOST="your-nerveshub-host"
export NERVES_HUB_PORT="443"
export NERVES_HUB_SSL="true"
export NERVES_HUB_KEY="nhp_your_product_key"
export NERVES_HUB_SECRET="your_product_secret"
```

Device settings are in `sesame/config/config.exs`:
- `host` — NervesHub server hostname
- `identifier` — unique device ID
- `firmware_meta` — product, version, architecture, platform, UUID
- `fwup_writer` — `Sesame.Hub.FwupWriter` (Capsule-aware)
- `extensions` — `[health: Sesame.Hub.HealthProvider]`

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
