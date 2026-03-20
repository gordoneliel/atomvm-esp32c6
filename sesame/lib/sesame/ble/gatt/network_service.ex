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
        Sesame.Ble.notify(:network_result, format_scan_results(networks))

      _error ->
        Sesame.Ble.notify(:network_result, <<"error">>)
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
