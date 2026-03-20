import asyncio
from bleak import BleakClient, BleakScanner

NETWORK_COMMAND = "dfb83b14-0100-1000-8000-00805f9b34fb"
NETWORK_RESULT  = "dfb83b13-0100-1000-8000-00805f9b34fb"

async def main():
    print("Scanning for 'sesame'...")
    device = await BleakScanner.find_device_by_name("sesame", timeout=10)
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
            await asyncio.wait_for(result_event.wait(), timeout=15)
        except asyncio.TimeoutError:
            print("Timed out waiting for scan results")

asyncio.run(main())
