defmodule Firefly.Application do
  def start do
    :timer.sleep(4000)
    :io.format(~c"Firefly starting...\n")

    child_specs = [
      {Firefly.Lights.Supervisor, {Firefly.Lights.Supervisor, :start_link, []}, :permanent,
       :brutal_kill, :supervisor, [Firefly.Lights.Supervisor]},
      # Matter handles BLE commissioning, Thread, and WiFi networking
      {Firefly.Matter, {Firefly.Matter, :start_link, []}, :permanent, :brutal_kill, :supervisor,
       [Firefly.Matter]}
    ]

    case :supervisor.start_link({:local, :firefly_sup}, __MODULE__, child_specs) do
      {:ok, pid} ->
        :io.format(~c"Supervisor started: ~p\n", [pid])
        idle_loop()

      {:error, reason} ->
        :io.format(~c"Supervisor failed: ~p\n", [reason])
    end
  end

  def init(child_specs) do
    {:ok, {{:one_for_one, 5, 60}, child_specs}}
  end

  defp idle_loop do
    :timer.sleep(60000)
    idle_loop()
  end
end
