defmodule Sesame.Ble do
  @moduledoc """
  BLE supervisor.

  Starts GATT service handlers first, then the peripheral manager
  which registers their services with the NIF and begins advertising.

  Service handlers implement:
    - service/0 — returns service definition keyword list
    - start_link/0 — starts the handler GenServer
    - handle_cast({:ble_write, char_id, data}, state)
  """

  @handlers [Sesame.Ble.Gatt.NetworkService]

  def start_link do
    child_specs =
      handler_child_specs(@handlers) ++
        [
          {Sesame.Ble.Peripheral, {Sesame.Ble.Peripheral, :start_link, [@handlers]},
           :permanent, :brutal_kill, :worker, [Sesame.Ble.Peripheral]}
        ]

    :supervisor.start_link({:local, :ble_sup}, __MODULE__, child_specs)
  end

  def init(child_specs) do
    {:ok, {{:one_for_all, 3, 60}, child_specs}}
  end

  # Public API — delegates to peripheral manager
  def notify(char_id, data) when is_atom(char_id) and is_binary(data) do
    :gen_server.cast(:ble, {:notify, char_id, data})
  end

  defp handler_child_specs(handlers) do
    Enum.map(handlers, fn handler ->
      name = handler.registered_name()
      {name, {handler, :start_link, []}, :permanent, :brutal_kill, :worker, [handler]}
    end)
  end
end
