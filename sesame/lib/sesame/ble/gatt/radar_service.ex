defmodule Sesame.Ble.Gatt.RadarService do
  @moduledoc """
  GATT service handler for radar sensor data.

  Characteristics:
    - :radar_status (notify) — outbound radar/sensor data
    - :radar_command (write) — inbound radar commands
  """

  def service do
    [
      id: :radar,
      type: :primary,
      uuid:
        <<0xDF, 0xB8, 0x3A, 0x12, 0x01, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B,
          0x34, 0xFB>>,
      characteristics: [
        [
          id: :radar_status,
          uuid:
            <<0xDF, 0xB8, 0x3A, 0x13, 0x01, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B,
              0x34, 0xFB>>,
          properties: [:read, :notify]
        ],
        [
          id: :radar_command,
          uuid:
            <<0xDF, 0xB8, 0x3A, 0x14, 0x01, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B,
              0x34, 0xFB>>,
          properties: [:write_no_rsp]
        ]
      ]
    ]
  end

  def registered_name, do: :radar_service

  def start_link do
    :gen_server.start_link({:local, registered_name()}, __MODULE__, [], [])
  end

  def init([]) do
    :erlang.process_flag(:trap_exit, true)
    {:ok, %{streaming: false}}
  end

  def handle_cast({:ble_write, :radar_command, <<"start_streaming">>}, state) do
    :io.format(~c"[RadarService] start streaming\n")
    send_to_radar(:start_streaming)
    {:noreply, %{state | streaming: true}}
  end

  def handle_cast({:ble_write, :radar_command, <<"stop_streaming">>}, state) do
    :io.format(~c"[RadarService] stop streaming\n")
    send_to_radar(:stop_streaming)
    {:noreply, %{state | streaming: false}}
  end

  def handle_cast({:ble_write, :radar_command, data}, state) do
    :io.format(~c"[RadarService] unknown command: ~p\n", [data])
    {:noreply, state}
  end

  def handle_cast(:stop_streaming, state) do
    if state.streaming do
      :io.format(~c"[RadarService] stopping streaming (disconnect)\n")
      send_to_radar(:stop_streaming)
    end
    {:noreply, %{state | streaming: false}}
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

  def terminate(_reason, state) do
    if state.streaming do
      send_to_radar(:stop_streaming)
    end
    :ok
  end

  defp send_to_radar(msg) do
    case :erlang.whereis(:radar) do
      pid when is_pid(pid) -> send(pid, msg)
      :undefined -> :ok
    end
  end
end
