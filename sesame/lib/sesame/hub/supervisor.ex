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
      case NervesHubLinkAVM.start_link(@hub_opts) do
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
end
