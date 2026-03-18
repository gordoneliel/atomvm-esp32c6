# Building AtomVM with BLE support for ESP32-C6

## Prerequisites

### 1. Install ESP-IDF v5.1+ (required for ESP32-C6)
```bash
mkdir -p ~/esp
cd ~/esp
git clone -b v5.3 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh esp32c6
source export.sh
```

### 2. Clone AtomVM
```bash
cd ~/Development/atomvm-esp32c6
git clone --recursive https://github.com/atomvm/AtomVM.git
```

## Build Steps

### 3. Copy BLE component into AtomVM
```bash
cp -r components/atomvm_ble AtomVM/src/platforms/esp32/components/
```

### 4. Configure and build AtomVM for ESP32-C6
```bash
cd AtomVM/src/platforms/esp32
source ~/esp/esp-idf/export.sh

idf.py set-target esp32c6
idf.py menuconfig
# Navigate to: Component config -> Bluetooth -> Enable
# Select: NimBLE (not Bluedroid)
# Save and exit

# Register the BLE NIF component
echo "atomvm_ble" >> main/component_nifs.txt

idf.py build
```

### 5. Flash the custom AtomVM firmware
```bash
idf.py -p /dev/cu.usbmodem101 flash

# Then flash the Elixir app as before:
cd ~/Development/atomvm-esp32c6/hello
mix atomvm.packbeam
esptool --chip esp32c6 --port /dev/cu.usbmodem101 --baud 921600 \
    write_flash 0x250000 Hello.avm
```

## Architecture

```
components/atomvm_ble/
├── CMakeLists.txt          # ESP-IDF component build config
└── src/
    ├── atomvm_ble.h        # NIF header
    └── atomvm_ble.c        # NIF implementation
        ├── NimBLE init, GATT server, advertising
        ├── GAP event handler → Erlang messages
        └── NIF registration (init, advertise, notify, add_service)

hello/lib/
├── ble.ex                  # Elixir BLE process (calls :ble_nif NIFs)
├── radar.ex                # Sends radar data to BLE via Ble.notify/1
└── ...
```

## NIF API

| Elixir                              | C Function          | Description                |
|--------------------------------------|---------------------|----------------------------|
| `:ble_nif.init(name)`               | `nif_ble_init`      | Init NimBLE + GATT server  |
| `:ble_nif.add_service(uuid, chars)` | `nif_ble_add_service`| Register GATT service     |
| `:ble_nif.advertise()`              | `nif_ble_advertise` | Start BLE advertising      |
| `:ble_nif.notify(conn, idx, data)`  | `nif_ble_notify`    | Send GATT notification     |

## Events (sent to owner process)

| Message                              | When                              |
|--------------------------------------|-----------------------------------|
| `{:ble_connected, conn_handle}`      | Client connects                   |
| `{:ble_disconnected, reason}`        | Client disconnects                |
| `{:ble_subscribed, char_handle}`     | Client subscribes to notifications|
| `{:ble_write, char_handle, data}`    | Client writes to characteristic   |

## TODO
- [ ] Install ESP-IDF
- [ ] Clone AtomVM source
- [ ] Build with BLE component
- [ ] Test basic advertising (phone sees "xiao-radar")
- [ ] Wire up event messages to Erlang process
- [ ] Connect Radar → BLE notification pipeline
- [ ] Dynamic service registration from Erlang
