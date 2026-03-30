defmodule Sesame.Hub.FwupWriter do
  @behaviour NervesHubLinkAVM.FwupWriter

  @impl true
  def fwup_begin(size, _meta) do
    :io.format(~c"[OTA] starting update, size=~p\n", [size])

    case Sesame.Partition.erase(size) do
      :ok ->
        :io.format(~c"[OTA] partition erased, ready to write\n")
        {:ok, %{written: 0, size: size}}

      {:error, reason} ->
        :io.format(~c"[OTA] partition erase failed: ~p\n", [reason])
        {:error, reason}
    end
  end

  @impl true
  def fwup_chunk(data, state) do
    case Sesame.Partition.write_chunk(state.written, data) do
      :ok ->
        new_written = state.written + byte_size(data)
        {:ok, %{state | written: new_written}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def fwup_finish(state) do
    :io.format(~c"[OTA] update complete, wrote ~p bytes. Rebooting...\n", [state.written])
    Sesame.BootEnv.swap()
    :esp.restart()
    :ok
  end

  @impl true
  def fwup_abort(_state) do
    :io.format(~c"[OTA] update aborted\n")
    :ok
  end
end
