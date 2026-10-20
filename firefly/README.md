# Firefly

Elixir application for the Firefly Matter occupancy sensor, running on AtomVM.

## Build and flash

```bash
mix atomvm.esp32.flash --port /dev/cu.usbmodem1101
```

## Configuration

Chip, port, and baud are configured in `mix.exs` (the app is flashed to the board's `main.avm` partition, read from its partition table):

```elixir
[
  chip: "esp32c6",
  port: "/dev/cu.usbmodem1101",
  baud: "921600"
]
```
