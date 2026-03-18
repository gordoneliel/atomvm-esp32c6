defmodule Mix.Tasks.Ota.Push do
  use Mix.Task

  @shortdoc "Push AVM update to device over WiFi"

  @port 8266

  def run(args) do
    host = List.first(args) || "sesame.local"

    # Build the Elixir app (creates Sesame.avm)
    Mix.Task.run("atomvm.packbeam")

    # Create combined AVM using exatomvm's PackBEAM (avoids external packbeam escript)
    sesame_root = File.cwd!()
    project_root = Path.expand("..", sesame_root)
    avm_out = "/tmp/combined.avm"

    avm_files = [
      {Path.join(sesame_root, "Sesame.avm"), :avm},
      {Path.join(project_root, "AtomVM/build/libs/atomvmlib.avm"), :avm},
      {Path.join(project_root, "AtomVM/build/libs/avm_esp32/src/avm_esp32.avm"), :avm}
    ]

    case ExAtomVM.PackBEAM.make_avm(avm_files, avm_out) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("PackBEAM failed: #{inspect(reason)}")
    end

    data = File.read!(avm_out)
    size = byte_size(data)
    Mix.shell().info("Uploading #{size} bytes to #{host}:#{@port}...")

    {:ok, sock} = :gen_tcp.connect(to_charlist(host), @port, [:binary, {:active, false}], 5000)
    :ok = :gen_tcp.send(sock, <<size::32>>)
    :ok = :gen_tcp.send(sock, data)

    case :gen_tcp.recv(sock, 0, 60_000) do
      {:ok, "OK"} ->
        Mix.shell().info("Upload complete! Device is rebooting.")

      {:ok, "ERR"} ->
        Mix.shell().error("Device reported write error.")

      {:error, :closed} ->
        Mix.shell().info("Connection closed (device may be rebooting).")

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
    end

    :gen_tcp.close(sock)
  end
end
