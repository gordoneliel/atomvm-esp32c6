defmodule Sesame.Application do
  def start do
    :io.format(~c"Sesame starting...\n")

    child_specs = [
      {Sesame.Wifi, {Sesame.Wifi, :start_link, []}, :permanent, :brutal_kill, :worker,
       [Sesame.Wifi]},
      {Sesame.Led, {Sesame.Led, :start_link, []}, :permanent, :brutal_kill, :worker,
       [Sesame.Led]},
      {Sesame.Ble, {Sesame.Ble, :start_link, []}, :permanent, :brutal_kill, :supervisor,
       [Sesame.Ble]},
      {Sesame.Heart, {Sesame.Heart, :start_link, []}, :temporary, :brutal_kill, :worker,
       [Sesame.Heart]},
      {Sesame.Hub.Supervisor, {Sesame.Hub.Supervisor, :start_link, []}, :permanent, :brutal_kill,
       :supervisor, [Sesame.Hub.Supervisor]}
    ]

    case :supervisor.start_link({:local, :sesame_sup}, __MODULE__, child_specs) do
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
