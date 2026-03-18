defmodule App do
  def start do
    :timer.sleep(8000)
    :io.format(~c"Sesame starting...\n")

    child_specs = [
      {Wifi, {Wifi, :start_link, []}, :permanent, :brutal_kill, :worker, [Wifi]},
      {Led, {Led, :start_link, []}, :permanent, :brutal_kill, :worker, [Led]},
      {Dist, {Dist, :start_link, []}, :permanent, :brutal_kill, :worker, [Dist]},
      {Radar, {Radar, :start_link, []}, :permanent, :brutal_kill, :worker, [Radar]},
      {Ble, {Ble, :start_link, []}, :permanent, :brutal_kill, :worker, [Ble]},
      {OtaServer, {OtaServer, :start_link, []}, :permanent, :brutal_kill, :worker, [OtaServer]},
      {Heart, {Heart, :start_link, []}, :temporary, :brutal_kill, :worker, [Heart]}
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
