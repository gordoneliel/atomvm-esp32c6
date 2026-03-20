defmodule Sesame.Ble.Gatt.NetworkService do
  @moduledoc """
  GATT service handler for network operations.

  Characteristics:
    - :network_result (notify) — scan results
    - :network_command (write) — inbound commands

  Commands:
    "scan_networks" — scan WiFi and notify back with results
  """

  def service do
    [
      id: :network,
      type: :primary,
      uuid:
        <<0xDF, 0xB8, 0x3B, 0x12, 0x01, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B,
          0x34, 0xFB>>,
      characteristics: [
        [
          id: :network_result,
          uuid:
            <<0xDF, 0xB8, 0x3B, 0x13, 0x01, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B,
              0x34, 0xFB>>,
          properties: [:read, :notify]
        ],
        [
          id: :network_command,
          uuid:
            <<0xDF, 0xB8, 0x3B, 0x14, 0x01, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B,
              0x34, 0xFB>>,
          properties: [:write_no_rsp]
        ]
      ]
    ]
  end

  def registered_name, do: :network_service

  def start_link do
    :gen_server.start_link({:local, registered_name()}, __MODULE__, [], [])
  end

  def init([]) do
    {:ok, %{}}
  end

  def handle_cast({:ble_write, :network_command, <<"scan_networks">>}, state) do
    :io.format(~c"[NetworkService] scanning WiFi networks...\n")

    case Sesame.Wifi.scan() do
      networks when is_list(networks) ->
        data = format_scan_results(networks)
        # Send in chunks to fit within BLE MTU (~500 bytes with 512 MTU, minus 3 ATT overhead)
        send_chunked(:network_result, data, 490)

      _error ->
        Sesame.Ble.notify(:network_result, <<"error">>)
    end

    {:noreply, state}
  end

  def handle_cast({:ble_write, :network_command, <<"connect:", rest::binary>>}, state) do
    case :binary.split(rest, <<":">>) do
      [ssid, psk] ->
        :io.format(~c"[NetworkService] connecting to ~s...\n", [ssid])

        case Sesame.Wifi.connect(ssid, psk) do
          :ok ->
            Sesame.Ble.notify(:network_result, <<"{\"status\":\"connected\",\"ssid\":\"", ssid::binary, "\"}">>)

          {:error, reason} ->
            msg = :erlang.iolist_to_binary(:io_lib.format(~c"{\"status\":\"error\",\"reason\":\"~p\"}", [reason]))
            Sesame.Ble.notify(:network_result, msg)
        end

      _ ->
        :io.format(~c"[NetworkService] invalid connect format, expected connect:SSID:PSK\n")
        Sesame.Ble.notify(:network_result, <<"{\"status\":\"error\",\"reason\":\"invalid format\"}">>)
    end

    {:noreply, state}
  end

  def handle_cast({:ble_write, :network_command, unknown}, state) do
    :io.format(~c"[NetworkService] unknown command: ~p\n", [unknown])
    {:noreply, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp send_chunked(char_id, <<>>, _chunk_size), do: :ok

  defp send_chunked(char_id, data, chunk_size) when byte_size(data) <= chunk_size do
    Sesame.Ble.notify(char_id, data)
  end

  defp send_chunked(char_id, data, chunk_size) do
    <<chunk::binary-size(chunk_size), rest::binary>> = data
    Sesame.Ble.notify(char_id, chunk)
    # Small delay between chunks so the BLE stack can flush
    :timer.sleep(50)
    send_chunked(char_id, rest, chunk_size)
  end

  defp format_scan_results(networks) do
    networks
    |> Enum.map(fn net ->
      [
        {:ssid, :proplists.get_value(:ssid, net, <<"?">>)},
        {:rssi, :proplists.get_value(:rssi, net, 0)}
      ]
    end)
    |> :json_encoder.encode()
    |> :erlang.iolist_to_binary()
  end
end
