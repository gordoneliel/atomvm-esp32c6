defmodule Sesame.Ble.Peripheral do
  @moduledoc """
  BLE peripheral manager (GenServer).

  Manages the NimBLE NIF lifecycle, connection state, advertising,
  and routes BLE events to registered service handler GenServers.
  """

  @device_name "sesame"

  def start_link(handlers) do
    :gen_server.start_link({:local, :ble}, __MODULE__, handlers, [])
  end

  def init(handlers) do
    :io.format(~c"[BLE] initializing as '~s'\n", [@device_name])

    case :ble_nif.init(@device_name) do
      :ok ->
        :io.format(~c"[BLE] stack initialized\n")

      {:error, reason} ->
        :io.format(~c"[BLE] init failed: ~p\n", [reason])
        {:stop, reason}
    end

    {chr_map, char_index} = register_handlers(handlers)

    :ble_nif.advertise()
    :io.format(~c"[BLE] advertising started\n")

    {:ok, %{conn_handle: nil, mtu: 23, subscribed: [], chr_map: chr_map, char_index: char_index}}
  end

  def handle_info({:ble_connected, handle}, state) do
    :io.format(~c"[BLE] client connected (handle: ~p)\n", [handle])
    {:noreply, %{state | conn_handle: handle}}
  end

  def handle_info({:ble_disconnected, _reason}, %{shutdown: true} = state) do
    :io.format(~c"[BLE] client disconnected (BLE shutting down)\n")
    {:noreply, %{state | conn_handle: nil, subscribed: []}}
  end

  def handle_info({:ble_disconnected, _reason}, state) do
    :io.format(~c"[BLE] client disconnected, re-advertising\n")
    :gen_server.cast(:radar_service, :stop_streaming)
    :ble_nif.advertise()
    {:noreply, %{state | conn_handle: nil, subscribed: []}}
  end

  def handle_info(:shutdown, state) do
    :io.format(~c"[BLE] shutting down\n")
    :ble_nif.deinit()
    {:noreply, Map.put(state, :shutdown, true)}
  end

  def handle_info({:ble_mtu, mtu}, state) do
    :io.format(~c"[BLE] MTU negotiated: ~p\n", [mtu])
    {:noreply, %{state | mtu: mtu}}
  end

  def handle_info({:ble_subscribed, chr_idx}, state) do
    :io.format(~c"[BLE] client subscribed to chr ~p\n", [chr_idx])
    {:noreply, %{state | subscribed: [chr_idx | state.subscribed]}}
  end

  def handle_info({:ble_unsubscribed, chr_idx}, state) do
    :io.format(~c"[BLE] client unsubscribed from chr ~p\n", [chr_idx])
    {:noreply, %{state | subscribed: state.subscribed -- [chr_idx]}}
  end

  def handle_info({:ble_write, chr_idx, data}, state) do
    case :proplists.get_value(chr_idx, state.chr_map) do
      :undefined ->
        :io.format(~c"[BLE] write to unknown chr index ~p\n", [chr_idx])

      {handler_name, char_id} ->
        :io.format(~c"[BLE] routing write to ~p:~p\n", [handler_name, char_id])
        :gen_server.cast(handler_name, {:ble_write, char_id, data})
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def handle_cast({:notify, char_id, data}, state) do
    case state.conn_handle do
      nil ->
        :ok

      conn_handle ->
        case :proplists.get_value(char_id, state.char_index) do
          :undefined ->
            :ok

          idx ->
            if :lists.member(idx, state.subscribed) do
              :ble_nif.notify(conn_handle, idx, data)
            end
        end
    end

    {:noreply, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  defp register_handlers(handlers) do
    {chr_map, char_index, _offset} =
      Enum.reduce(handlers, {[], [], 0}, fn handler, {chr_map_acc, char_index_acc, offset} ->
        service = handler.service()
        chars = service[:characteristics]

        nif_chars =
          Enum.map(chars, fn char ->
            {:characteristic, char[:uuid], char[:properties]}
          end)

        :ble_nif.add_service(service[:uuid], nif_chars)

        handler_name = handler.registered_name()
        {new_chr_map, new_char_index, _} =
          Enum.reduce(chars, {chr_map_acc, char_index_acc, 0}, fn char, {cm, ci, i} ->
            idx = offset + i
            char_id = char[:id]
            {[{idx, {handler_name, char_id}} | cm], [{char_id, idx} | ci], i + 1}
          end)

        {new_chr_map, new_char_index, offset + length(chars)}
      end)

    {chr_map, char_index}
  end
end
