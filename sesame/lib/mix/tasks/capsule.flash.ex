defmodule Mix.Tasks.Capsule.Flash do
  @moduledoc """
  Flash a .cap file to the device via USB serial.

  Uses the capsule CLI to extract entries, then flashes them with esptool.

  ## Usage

      mix capsule.flash sesame-0.1.0.cap [options]

  ## Options

    * `--port` - Serial port (default: auto-detect /dev/cu.usbmodem*)
    * `--chip` - Chip type (default: esp32c5)
    * `--baud` - Baud rate (default: 460800)
    * `--slot` - Target slot 0 or 1 (default: 0)
    * `--erase` - Erase entire flash first
    * `--full` - Also flash bootloader, partition table, and OTA data
  """

  use Mix.Task

  @capsule_cli Path.expand("~/Development/libcapsule/build/capsule")

  @partition_offsets %{
    {"app", 0} => 0x20000,
    {"avm", 0} => 0x5E0000,
    {"app", 1} => 0x300000,
    {"avm", 1} => 0x670000
  }

  @build_dir Path.expand("../AtomVM/src/platforms/esp32/build", File.cwd!())
  @bootloader_offset 0x2000
  @partition_table_offset 0x8000
  @otadata_offset 0xF000

  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        switches: [
          port: :string, chip: :string, baud: :integer,
          slot: :integer, erase: :boolean, full: :boolean
        ],
        aliases: [p: :port, c: :chip, s: :slot]
      )

    cap_path = List.first(rest) || raise "Usage: mix capsule.flash <file.cap> [options]"
    unless File.exists?(cap_path), do: raise("File not found: #{cap_path}")

    port = opts[:port] || detect_port()
    chip = opts[:chip] || "esp32c5"
    baud = opts[:baud] || 460800
    slot = opts[:slot] || 0
    full = opts[:full] || false

    IO.puts("Capsule: #{cap_path}")
    IO.puts("Port: #{port}  Chip: #{chip}  Slot: #{slot}#{if full, do: "  (full install)", else: ""}")

    # Inspect capsule
    IO.puts("")
    {output, 0} = System.cmd(@capsule_cli, ["inspect", cap_path])
    IO.puts(output)

    # Extract to temp dir
    tmp_dir = Path.join(System.tmp_dir!(), "capsule_flash_#{:os.system_time(:millisecond)}")
    File.mkdir_p!(tmp_dir)

    {_, 0} = System.cmd(@capsule_cli, ["extract", cap_path, "--output-dir", tmp_dir])

    # Erase if requested
    if opts[:erase] do
      IO.puts("Erasing flash...")
      run_esptool(chip, port, baud, ["erase_flash"])
    end

    # Build flash args
    flash_args = []

    # System files if --full
    flash_args =
      if full do
        bootloader = Path.join(@build_dir, "bootloader/bootloader.bin")
        partition_table = Path.join(@build_dir, "partition_table/partition-table.bin")
        otadata = Path.join(@build_dir, "ota_data_initial.bin")

        for {name, path} <- [{"bootloader", bootloader}, {"partition table", partition_table}, {"OTA data", otadata}] do
          unless File.exists?(path), do: raise("#{name} not found: #{path}")
        end

        IO.puts("Full install: including bootloader, partition table, OTA data")

        flash_args ++ [
          "0x#{hex(@bootloader_offset)}", bootloader,
          "0x#{hex(@partition_table_offset)}", partition_table,
          "0x#{hex(@otadata_offset)}", otadata
        ]
      else
        flash_args
      end

    # Add extracted entries
    flash_args =
      flash_args ++
        Enum.flat_map(["app", "avm"], fn name ->
          path = Path.join(tmp_dir, name)

          if File.exists?(path) do
            case Map.get(@partition_offsets, {name, slot}) do
              nil -> []
              offset ->
                size = File.stat!(path).size
                IO.puts("  #{name}: #{fmt_size(size)} → 0x#{hex(offset)}")
                ["0x#{hex(offset)}", path]
            end
          else
            []
          end
        end)

    if flash_args == [] do
      IO.puts("Nothing to flash")
    else
      IO.puts("\nFlashing#{if full, do: " (full)", else: ""} to slot #{slot}...")
      run_esptool(chip, port, baud, [
        "write_flash", "--flash_mode", "dio", "--flash_size", "8MB", "--flash_freq", "80m"
        | flash_args
      ])
      IO.puts("Done!")
    end

    # Clean up
    File.rm_rf!(tmp_dir)
  end

  defp detect_port do
    case Path.wildcard("/dev/cu.usbmodem*") do
      [port | _] -> port
      [] -> raise "No USB serial port found."
    end
  end

  defp run_esptool(chip, port, baud, args) do
    cmd_args = ["--chip", chip, "-p", port, "-b", "#{baud}" | args]
    IO.puts("$ esptool.py #{Enum.join(cmd_args, " ")}")

    case System.cmd("esptool.py", cmd_args, stderr_to_stdout: true) do
      {output, 0} -> IO.puts(output)
      {output, code} ->
        IO.puts(output)
        raise "esptool.py failed with exit code #{code}"
    end
  end

  defp hex(n), do: Integer.to_string(n, 16)

  defp fmt_size(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)}MB"
  defp fmt_size(bytes) when bytes >= 1024, do: "#{div(bytes, 1024)}KB"
  defp fmt_size(bytes), do: "#{bytes}B"
end
