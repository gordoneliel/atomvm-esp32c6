defmodule Sesame.OtaServer do
  @port 8266
  @chunk_size 4096

  def start_link do
    pid = spawn_link(__MODULE__, :init, [])
    {:ok, pid}
  end

  def init do
    {:ok, lsock} = :gen_tcp.listen(@port, [{:active, false}, :binary])
    :io.format(~c"[OTA] listening on port ~p\n", [@port])
    accept_loop(lsock)
  end

  defp accept_loop(lsock) do
    {:ok, sock} = :gen_tcp.accept(lsock)
    :io.format(~c"[OTA] client connected\n")
    handle(sock)
    :gen_tcp.close(sock)
    accept_loop(lsock)
  end

  defp handle(sock) do
    {:ok, <<len::32>>} = :gen_tcp.recv(sock, 4)
    :io.format(~c"[OTA] receiving ~p bytes (streaming to flash)\n", [len])

    with :ok <- Sesame.Partition.erase(len),
         :io.format(~c"[OTA] partition erased, receiving chunks...\n"),
         :ok <- recv_and_write(sock, len, 0),
         :io.format(~c"[OTA] flash write complete\n"),
         :ok <- :gen_tcp.send(sock, "OK") do
      :io.format(~c"[OTA] swapping slot and rebooting...\n")
      Sesame.BootEnv.swap()
    else
      {:error, reason} ->
        :gen_tcp.send(sock, "ERR")
        :io.format(~c"[OTA] failed: ~p\n", [reason])
    end
  end

  defp recv_and_write(_sock, 0, _offset), do: :ok

  defp recv_and_write(sock, remaining, offset) do
    chunk_size = min(remaining, @chunk_size)
    {:ok, chunk} = :gen_tcp.recv(sock, chunk_size)
    received = byte_size(chunk)

    case Sesame.Partition.write_chunk(offset, chunk) do
      :ok ->
        new_offset = offset + received

        if rem(new_offset, 102_400) < received do
          :io.format(~c"[OTA] ~p/~p bytes\n", [new_offset, new_offset + remaining - received])
        end

        recv_and_write(sock, remaining - received, new_offset)

      {:error, _reason} = err ->
        err
    end
  end
end
