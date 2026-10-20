# Firefly

A Matter-over-Thread occupancy sensor running Elixir on the ESP32-C6, built on [AtomVM](https://github.com/atomvm/AtomVM).

## Overview

Firefly is a presence sensor that exposes an occupancy sensing cluster over the Matter smart home protocol. It runs on a XIAO ESP32-C6, using Thread (802.15.4) mesh networking and BLE for commissioning.

The application logic is written entirely in Elixir, running on AtomVM with custom C NIF components for Matter and the LED strip. AtomVM itself is unmodified upstream.

## Hardware

- **Board**: Seeed Studio XIAO ESP32-C6 (4MB flash, WiFi 6, BLE 5, IEEE 802.15.4)
- **LED**: GPIO15, active-low (off by default)
- **Button**: BOOT button on GPIO9, cycles the LED matrix animations

## Matter commissioning

To add the device to Apple Home (or any Matter controller):

1. Ensure you have a **Thread border router** on your network (HomePod mini or Apple TV 4K)
2. Open Apple Home, tap **+** > **Add Accessory** > **More options...**
3. The device should appear as "Firefly Sensor"
4. If prompted for a setup code, enter the manual pairing code

**Test commissioning credentials:**

| Field | Value |
|-------|-------|
| Manual pairing code | `34970112332` |
| Setup PIN | `20202021` |
| Discriminator | `0xF00` |
| Vendor ID | `0xFFF1` (test) |
| Product ID | `0x8001` (test) |

The CHIP stack also prints a `SetupQRCode:` line to serial on boot that can be scanned directly.

To re-commission after a previous pairing, erase the NVS partition (see Factory reset below).

## Architecture

```
firefly/
├── AtomVM/                        # Stock AtomVM (submodule, release-0.7 branch)
├── firmware/                      # ESP32-C6 sdkconfig, partition table, idf.py wrapper
├── components/
│   ├── atomvm_matter/             # Matter NIF (wraps esp_matter / CHIP SDK)
│   ├── atomvm_led_strip/          # LED strip NIF
│   └── boot_avm/                  # Flashes AtomVM's libraries to boot.avm
├── firefly/                       # Elixir application
│   ├── lib/
│   │   ├── app.ex                 # Application supervisor
│   │   └── firefly/
│   │       ├── matter/            # Matter device manager
│   │       ├── lights.ex          # LED control API (matrix + status LED)
│   │       └── lights/            # Animations, matrix geometry, drivers
│   └── mix.exs
└── README.md
```

### Supervised processes

| Module | Role |
|--------|------|
| `Firefly.Lights.StatusLed` | Status LED on GPIO15: blink, on or off |
| `Firefly.Lights.Server` | Runs the current LED matrix animation |
| `Firefly.Lights.Button` | BOOT button: each press plays the next animation |
| `Firefly.Matter.Device` | Matter stack lifecycle, occupancy sensor endpoint |

### LED control

`Firefly.Lights` is the API for both LEDs:

```elixir
Firefly.Lights.play(:commissioning)          # named: idle, commissioning, connected, error, arrow_left, arrow_right, ripple
Firefly.Lights.play(Firefly.Lights.Animations.Pulse, color: {0, 0, 40})
Firefly.Lights.fill({20, 0, 20})
Firefly.Lights.set_brightness(128)
Firefly.Lights.cycle()                       # next named animation, also bound to the BOOT button
Firefly.Lights.status_led(:on)
```

An animation is a module implementing `Firefly.Lights.Animation`: `init/1` turns options into state, and `next_frame/1` returns the next frame, how long to show it, and the new state. Animations are pure (no hardware access), so they're tested on the host with `mix test`. Add one under `lib/firefly/lights/animations/` and, optionally, give it a name in `Firefly.Lights`.

### Matter endpoints

| Endpoint | Device type | Clusters | In Apple Home |
|----------|-------------|----------|---------------|
| 0 | Root Node | (managed by SDK) | |
| 1 | Occupancy Sensor (0x0107) | Occupancy Sensing (0x0406) | Occupancy sensor |
| 2 | Extended Color Light (0x010D) | On/Off, Level Control, Color Control (hue/saturation, color temperature) | LED matrix: on/off, brightness and color of the current animation |
| 3 | On/Off Plug-in Unit (0x010A) | On/Off | "Next animation" switch: turning it on plays the next animation (like the BOOT button), then it switches back off |

Writes from the controller arrive in `Firefly.Matter.Device` and are mapped to `Firefly.Lights` by `Firefly.Matter.LightControl`. A color set from Home replaces the animations' own colors until the device restarts.

## Quick start

### Prerequisites

- ESP-IDF v5.5 (`source ~/esp/esp-idf/export.sh`), see [BUILD.md](BUILD.md)
- Erlang/OTP and Elixir, versions in `.tool-versions` (asdf)

### Build and flash firmware (first time or after C changes)

```bash
firmware/idf.sh build
firmware/idf.sh -p /dev/cu.usbmodem1101 flash   # firmware + AtomVM libraries
```

### Flash the Elixir app

```bash
cd firefly
mix atomvm.esp32.flash --port /dev/cu.usbmodem1101
```

### Factory reset

To clear all Matter and Thread credentials and re-commission:

```bash
# Erase NVS partition (requires USB)
esptool.py --chip esp32c6 -p /dev/cu.usbmodem1101 erase_region 0x9000 0xC000
```

### Partition layout (4MB flash)

| Partition | Offset | Size |
|-----------|--------|------|
| nvs | 0x9000 | 48KB |
| phy_init | 0x15000 | 4KB |
| factory | 0x20000 | 3.25MB |
| boot.avm | 0x360000 | 512KB (AtomVM Erlang/Elixir libraries) |
| main.avm | 0x3E0000 | 128KB (Firefly app) |
