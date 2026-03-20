defmodule Sesame.Ota.Updater do
  @moduledoc """
  HTTPS OTA polling updater.

  Periodically fetches a manifest file from a remote server and checks if a
  newer firmware version is available. If so, downloads and flashes it using
  the existing A/B OTA infrastructure.

  Manifest format (plain text, one field per line):
      version:1.2.0
      url:https://example.com/firmware/sesame.avm
      size:245760
  """

  @version "0.1.0"
  @default_poll_interval 300_000
  @chunk_recv_size 4096

  def start_link(opts \\ []) do
    :gen_server.start_link({:local, :ota_updater}, __MODULE__, opts, [])
  end

  def init(opts) do
    manifest_url = :proplists.get_value(:manifest_url, opts, nil)
    poll_interval = :proplists.get_value(:poll_interval, opts, @default_poll_interval)

    state = %{
      manifest_url: manifest_url,
      poll_interval: poll_interval,
      version: @version
    }

    if manifest_url do
      :erlang.send_after(poll_interval, self(), :check)
      :io.format(~c"[OTA Updater] started, polling every ~pms\n", [poll_interval])
    else
      :io.format(~c"[OTA Updater] no manifest_url configured, disabled\n")
    end

    {:ok, state}
  end

  def handle_info(:check, state) do
    :io.format(~c"[OTA Updater] checking for updates...\n")

    case check_and_update(state.manifest_url, state.version) do
      :up_to_date ->
        :io.format(~c"[OTA Updater] firmware is up to date\n")

      {:updating, version} ->
        # download_and_flash calls BootEnv.swap() which reboots — we won't reach here
        :io.format(~c"[OTA Updater] updating to ~s...\n", [version])

      {:error, reason} ->
        :io.format(~c"[OTA Updater] check failed: ~p\n", [reason])
    end

    :erlang.send_after(state.poll_interval, self(), :check)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  defp check_and_update(manifest_url, current_version) do
    case fetch_manifest(manifest_url) do
      {:ok, manifest} ->
        remote_version = :proplists.get_value(:version, manifest)

        if remote_version != nil and remote_version != current_version do
          url = :proplists.get_value(:url, manifest)
          size = :proplists.get_value(:size, manifest)

          if url != nil and size != nil do
            case download_and_flash(url, size) do
              :ok -> {:updating, remote_version}
              {:error, _} = err -> err
            end
          else
            {:error, :incomplete_manifest}
          end
        else
          :up_to_date
        end

      {:error, _} = err ->
        err
    end
  end

  defp fetch_manifest(url) do
    case parse_url(url) do
      {:ok, protocol, host, port, path} ->
        case :ahttp_client.connect(protocol, host, port, [{:active, false}, {:verify, :verify_none}]) do
          {:ok, conn} ->
            case :ahttp_client.request(conn, "GET", path, [], nil) do
              {:ok, conn2, _ref} ->
                result = recv_full_response(conn2, <<>>)
                :ahttp_client.close(conn2)
                result

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  defp recv_full_response(conn, body_acc) do
    case :ahttp_client.recv(conn, 0) do
      {:ok, conn2, responses} ->
        {new_acc, done?} = process_responses(responses, body_acc)

        if done? do
          parse_manifest(new_acc)
        else
          recv_full_response(conn2, new_acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_responses([], acc), do: {acc, false}

  defp process_responses([response | rest], acc) do
    case response do
      {:data, _ref, chunk} ->
        process_responses(rest, <<acc::binary, chunk::binary>>)

      {:done, _ref} ->
        {acc, true}

      _other ->
        process_responses(rest, acc)
    end
  end

  defp parse_manifest(body) do
    lines = :binary.split(body, <<"\n">>, [:global])

    manifest =
      Enum.reduce(lines, [], fn line, acc ->
        case :binary.split(line, <<":">>, []) do
          [<<"version">>, value] ->
            [{:version, trim(value)} | acc]

          [<<"size">>, value] ->
            size = :erlang.binary_to_integer(trim(value))
            [{:size, size} | acc]

          [<<"url">> | _rest] ->
            # URL contains colons, so rejoin everything after "url:"
            <<"url:", url_rest::binary>> = line
            [{:url, trim(url_rest)} | acc]

          _ ->
            acc
        end
      end)

    {:ok, manifest}
  end

  defp download_and_flash(url, size) do
    :io.format(~c"[OTA Updater] downloading ~p bytes from ~s\n", [size, url])

    case parse_url(url) do
      {:ok, protocol, host, port, path} ->
        case :ahttp_client.connect(protocol, host, port, [{:active, false}, {:verify, :verify_none}]) do
          {:ok, conn} ->
            case :ahttp_client.request(conn, "GET", path, [], nil) do
              {:ok, conn2, _ref} ->
                with :ok <- Sesame.Partition.erase(size) do
                  :io.format(~c"[OTA Updater] partition erased, downloading...\n")

                  case recv_and_write(conn2, 0, size) do
                    {:ok, conn3} ->
                      :ahttp_client.close(conn3)
                      :io.format(~c"[OTA Updater] flash write complete, swapping...\n")
                      Sesame.BootEnv.swap()
                      :ok

                    {:error, reason} ->
                      :ahttp_client.close(conn2)
                      {:error, reason}
                  end
                end

              {:error, reason} ->
                :ahttp_client.close(conn)
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  defp recv_and_write(conn, offset, total_size) do
    case :ahttp_client.recv(conn, 0) do
      {:ok, conn2, responses} ->
        case write_responses(responses, offset) do
          {:ok, new_offset, :done} ->
            :io.format(~c"[OTA Updater] download complete: ~p/~p bytes\n", [new_offset, total_size])
            {:ok, conn2}

          {:ok, new_offset, :continue} ->
            if rem(new_offset, 102_400) < (new_offset - offset) do
              :io.format(~c"[OTA Updater] ~p/~p bytes\n", [new_offset, total_size])
            end

            recv_and_write(conn2, new_offset, total_size)

          {:error, _} = err ->
            err
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_responses([], offset), do: {:ok, offset, :continue}

  defp write_responses([response | rest], offset) do
    case response do
      {:data, _ref, chunk} ->
        case Sesame.Partition.write_chunk(offset, chunk) do
          :ok ->
            write_responses(rest, offset + byte_size(chunk))

          {:error, _} = err ->
            err
        end

      {:done, _ref} ->
        {:ok, offset, :done}

      _other ->
        write_responses(rest, offset)
    end
  end

  defp parse_url(url) when is_binary(url) do
    case url do
      <<"https://", rest::binary>> ->
        parse_host_path(rest, :https, 443)

      <<"http://", rest::binary>> ->
        parse_host_path(rest, :http, 80)

      _ ->
        {:error, :invalid_url}
    end
  end

  defp parse_host_path(rest, protocol, default_port) do
    case :binary.split(rest, <<"/">>) do
      [host_port, path_rest] ->
        {host, port} = parse_host_port(host_port, default_port)
        {:ok, protocol, host, port, <<"/", path_rest::binary>>}

      [host_port] ->
        {host, port} = parse_host_port(host_port, default_port)
        {:ok, protocol, host, port, <<"/">>}
    end
  end

  defp parse_host_port(host_port, default_port) do
    case :binary.split(host_port, <<":">>) do
      [host, port_bin] -> {host, :erlang.binary_to_integer(port_bin)}
      [host] -> {host, default_port}
    end
  end

  defp trim(bin) when is_binary(bin) do
    # Strip leading/trailing whitespace and CR
    trim_right(trim_left(bin))
  end

  defp trim_left(<<c, rest::binary>>) when c == ?\s or c == ?\r or c == ?\t, do: trim_left(rest)
  defp trim_left(bin), do: bin

  defp trim_right(<<>>), do: <<>>

  defp trim_right(bin) do
    size = byte_size(bin) - 1
    <<prefix::binary-size(size), c>> = bin

    if c == ?\s or c == ?\r or c == ?\t do
      trim_right(prefix)
    else
      bin
    end
  end
end
