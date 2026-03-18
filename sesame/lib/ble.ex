defmodule Ble do
  @moduledoc """
  BLE peripheral interface for AtomVM.
  Requires custom AtomVM firmware with atomvm_ble component.

  Usage:
    Ble.start("sesame")
    # Once connected, other processes can call:
    Ble.notify(data)
  """

  @device_name "sesame"

  def start_link do
    pid = spawn_link(__MODULE__, :start, [])
    {:ok, pid}
  end

  def start do
    :erlang.register(:ble, self())
    name = @device_name
    :io.format(~c"[BLE] initializing as '~s'\n", [name])

    # Initialize NimBLE stack
    case :ble_nif.init(name) do
      :ok ->
        :io.format(~c"[BLE] stack initialized\n")

      {:error, reason} ->
        :io.format(~c"[BLE] init failed: ~p\n", [reason])
        exit(reason)
    end

    # Register GATT services
    :ble_nif.add_service(
      # Radar data service (custom UUID)
      <<0xDF, 0xB8, 0x3A, 0x12, 0x01, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34,
        0xFB>>,
      [
        # Radar status characteristic (notify)
        {:characteristic,
         <<0xDF, 0xB8, 0x3A, 0x13, 0x01, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B,
           0x34, 0xFB>>, [:read, :notify]}
      ]
    )

    # Start advertising
    :ble_nif.advertise()
    :io.format(~c"[BLE] advertising started\n")

    loop(nil)
  end

  defp loop(conn_handle) do
    receive do
      # NIF callbacks
      {:ble_connected, handle} ->
        :io.format(~c"[BLE] client connected (handle: ~p)\n", [handle])
        loop(handle)

      {:ble_disconnected, _reason} ->
        :io.format(~c"[BLE] client disconnected, re-advertising\n")
        :ble_nif.advertise()
        loop(nil)

      {:ble_subscribed, char_handle} ->
        :io.format(~c"[BLE] client subscribed to char ~p\n", [char_handle])
        loop(conn_handle)

      {:ble_write, _char_handle, data} ->
        :io.format(~c"[BLE] received write: ~p\n", [data])
        loop(conn_handle)

      # Messages from other processes (e.g., Radar)
      {:notify, data} when conn_handle != nil ->
        :ble_nif.notify(conn_handle, 0, data)
        loop(conn_handle)

      {:notify, _data} ->
        # No client connected, drop
        loop(conn_handle)
    end
  end

  # Public API for other processes to send notifications
  def notify(data) when is_binary(data) do
    send(:ble, {:notify, data})
  end
end
