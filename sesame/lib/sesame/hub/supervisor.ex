defmodule Sesame.Hub.Supervisor do
  @retry_interval 5_000
  @hub_opts Application.compile_env!(:sesame, :nerveshub)

  def start_link do
    :gen_server.start_link({:local, :hub_sup}, __MODULE__, [], [])
  end

  def init([]) do
    :io.format(~c"[ChannelSup] waiting for SNTP sync...\n")
    {:ok, %{started: false, synced: false}}
  end

  def handle_info(:sntp_synced, %{started: true} = state) do
    {:noreply, state}
  end

  def handle_info(:sntp_synced, state) do
    :io.format(~c"[ChannelSup] SNTP synced, starting channels...\n")
    start_channels(%{state | synced: true})
  end

  def handle_info(:retry, %{synced: true} = state) do
    start_channels(state)
  end

  def handle_info(:retry, state) do
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

  defp start_channels(state) do
    try do
      default_meta = Keyword.get(@hub_opts, :firmware_meta, %{})
      fw_meta = load_firmware_meta(default_meta)
      opts = Keyword.put(@hub_opts, :firmware_meta, fw_meta)

      :io.format(~c"[ChannelSup] firmware_meta: version=~s uuid=~s product=~s\n", [
        Map.get(fw_meta, "version", "?"),
        Map.get(fw_meta, "uuid", "?"),
        Map.get(fw_meta, "product", "?")
      ])

      case NervesHubLinkAVM.start_link(opts) do
        {:ok, _pid} ->
          :io.format(~c"[ChannelSup] NervesHub channel started\n")
          {:noreply, %{state | started: true}}

        {:error, reason} ->
          :io.format(~c"[ChannelSup] NervesHub start failed: ~p, retrying...\n", [reason])
          :erlang.send_after(@retry_interval, self(), :retry)
          {:noreply, state}
      end
    catch
      kind, err ->
        :io.format(~c"[ChannelSup] NervesHub crash: ~p ~p\n", [kind, err])
        :erlang.send_after(@retry_interval, self(), :retry)
        {:noreply, state}
    end
  end

  # Read firmware metadata from NVS (written during OTA), falling back to compile-time config
  defp load_firmware_meta(default_meta) do
    :maps.fold(fn key, default_value, acc ->
      value =
        try do
          case :esp.nvs_get_binary(:firmware_meta, key) do
            val when is_binary(val) and byte_size(val) > 0 -> val
            _ -> default_value
          end
        catch
          _, _ -> default_value
        end

      Map.put(acc, key, value)
    end, %{}, default_meta)
  end
end
