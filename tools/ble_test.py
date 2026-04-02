import asyncio
import sys
from bleak import BleakClient, BleakScanner

NETWORK_COMMAND = "dfb83b14-0100-1000-8000-00805f9b34fb"
NETWORK_RESULT  = "dfb83b13-0100-1000-8000-00805f9b34fb"

DEVICE_NAME = "sesame"

async def find_device(timeout=10):
    """Find device by advertising local_name."""
    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)
    for addr, (device, adv_data) in devices.items():
        if adv_data.local_name and adv_data.local_name.lower() == DEVICE_NAME.lower():
            return device
    return None

async def cmd_scan():
    print(f"Scanning for '{DEVICE_NAME}'...")
    device = await find_device()
    if not device:
        print("Device not found")
        return

    print(f"Found: {device.name} ({device.address})")

    async with BleakClient(device) as client:
        print(f"Connected, MTU: {client.mtu_size}")

        result_event = asyncio.Event()

        def on_notify(_, data):
            print(f"Scan result:\n{data.decode()}")
            result_event.set()

        await client.start_notify(NETWORK_RESULT, on_notify)
        print("Subscribed to network_result")

        print("Sending scan_networks command...")
        await client.write_gatt_char(NETWORK_COMMAND, b"scan_networks", response=False)

        try:
            await asyncio.wait_for(result_event.wait(), timeout=60)
        except asyncio.TimeoutError:
            print("Timed out waiting for scan results")

async def cmd_connect(ssid, psk):
    print(f"Scanning for '{DEVICE_NAME}'...")
    device = await find_device()
    if not device:
        print("Device not found")
        return

    print(f"Found: {device.name} ({device.address})")

    async with BleakClient(device) as client:
        print(f"Connected, MTU: {client.mtu_size}")

        result_event = asyncio.Event()

        def on_notify(_, data):
            print(f"Response: {data.decode()}")
            result_event.set()

        await client.start_notify(NETWORK_RESULT, on_notify)

        cmd = f"connect:{ssid}:{psk}".encode()
        print(f"Sending connect command for '{ssid}'...")
        await client.write_gatt_char(NETWORK_COMMAND, cmd, response=False)

        try:
            await asyncio.wait_for(result_event.wait(), timeout=30)
        except asyncio.TimeoutError:
            print("Timed out waiting for response")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python ble_test.py scan")
        print("  python ble_test.py connect <ssid> <psk>")
        sys.exit(1)

    command = sys.argv[1]

    if command == "scan":
        asyncio.run(cmd_scan())
    elif command == "connect" and len(sys.argv) >= 4:
        asyncio.run(cmd_connect(sys.argv[2], sys.argv[3]))
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)
