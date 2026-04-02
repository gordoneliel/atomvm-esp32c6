defmodule Mix.Tasks.Capsule.Build do
  @moduledoc """
  Build a .cap firmware capsule from the current project.

  Compiles the Elixir app, packages the AVM, and bundles it with the
  AtomVM firmware binary into a .cap file.

  ## Usage

      mix capsule.build [--output sesame-0.1.0.cap] [--firmware path/to/atomvm-esp32.bin]

  ## Options

    * `--output` / `-o` - Output .cap file path (default: <app>-<version>.cap)
    * `--firmware` - Path to firmware binary (default: auto-detect from AtomVM build)
    * `--sign` - Path to Ed25519 private key for signing
  """

  use Mix.Task

  @capsule_cli Path.expand("~/Development/libcapsule/build/capsule")

  def run(args) do
    {opts, _rest, _} =
      OptionParser.parse(args,
        switches: [output: :string, firmware: :string, sign: :string],
        aliases: [o: :output]
      )

    app = Mix.Project.config()[:app]
    version = Mix.Project.config()[:version]

    # 1. Compile
    IO.puts("Compiling...")
    Mix.Task.run("compile", ["--force"])

    # 2. Packbeam
    IO.puts("Packaging AVM...")
    Mix.Task.run("atomvm.packbeam")

    # 3. Build combined AVM
    IO.puts("Building combined AVM...")
    sesame_avm = Path.expand("#{app}.avm")
    atomvmlib = Path.expand("../AtomVM/build/libs/atomvmlib.avm")
    esp32_avm = Path.expand("../AtomVM/build/libs/avm_esp32/src/avm_esp32.avm")
    combined = Path.join(System.tmp_dir!(), "combined.avm")

    Code.eval_string("""
    ExAtomVM.PackBEAM.make_avm(
      [{#{inspect(sesame_avm)}, []}, {#{inspect(atomvmlib)}, []}, {#{inspect(esp32_avm)}, []}],
      #{inspect(combined)}
    )
    """)

    # 4. Find firmware
    firmware =
      opts[:firmware] ||
        Path.expand("../AtomVM/src/platforms/esp32/build/atomvm-esp32.bin")

    unless File.exists?(firmware), do: raise("Firmware not found: #{firmware}")
    unless File.exists?(combined), do: raise("Combined AVM not found: #{combined}")

    IO.puts("Firmware: #{firmware} (#{div(File.stat!(firmware).size, 1024)}KB)")
    IO.puts("AVM: #{combined} (#{div(File.stat!(combined).size, 1024)}KB)")

    # 5. Build .cap
    output = opts[:output] || "#{app}-#{version}.cap"

    hub_config = Application.get_env(:sesame, :nerveshub, [])
    fw_meta = Keyword.get(hub_config, :firmware_meta, %{})

    product = Map.get(fw_meta, "product", to_string(app))
    platform = Map.get(fw_meta, "platform", "unknown")
    architecture = Map.get(fw_meta, "architecture", "unknown")
    uuid = Map.get(fw_meta, "uuid", "")

    capsule_args = [
      "build", "-o", output,
      "-e", "app:#{firmware}",
      "-e", "avm:#{combined}",
      "-m", "product=#{product}",
      "-m", "version=#{version}",
      "-m", "platform=#{platform}",
      "-m", "architecture=#{architecture}",
      "-m", "uuid=#{uuid}",
      "-m", "author=#{Map.get(fw_meta, "author", "Density")}"
    ]

    capsule_args =
      if opts[:sign] do
        capsule_args ++ ["--sign", opts[:sign]]
      else
        capsule_args
      end

    IO.puts("Building capsule...")

    case System.cmd(@capsule_cli, capsule_args, stderr_to_stdout: true) do
      {output_str, 0} ->
        IO.puts(output_str)
        size = File.stat!(output).size
        IO.puts("Built: #{output} (#{div(size, 1024)}KB)")

      {output_str, code} ->
        IO.puts(output_str)
        raise "capsule build failed with exit code #{code}"
    end
  end
end
