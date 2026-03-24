defmodule Sesame.Application do
  def start do
    :timer.sleep(8000)
    :io.format(~c"Sesame starting...\n")

    child_specs = [
      {Sesame.Wifi, {Sesame.Wifi, :start_link, []}, :permanent, :brutal_kill, :worker, [Sesame.Wifi]},
      {Sesame.Led, {Sesame.Led, :start_link, []}, :permanent, :brutal_kill, :worker, [Sesame.Led]},
      {Sesame.Cluster, {Sesame.Cluster, :start_link, []}, :permanent, :brutal_kill, :worker, [Sesame.Cluster]},
      {Sesame.Radar, {Sesame.Radar, :start_link, []}, :permanent, :brutal_kill, :worker, [Sesame.Radar]},
      {Sesame.Ble, {Sesame.Ble, :start_link, []}, :permanent, :brutal_kill, :supervisor, [Sesame.Ble]},
      {Sesame.OtaServer, {Sesame.OtaServer, :start_link, []}, :permanent, :brutal_kill, :worker, [Sesame.OtaServer]},
      {Sesame.Heart, {Sesame.Heart, :start_link, []}, :temporary, :brutal_kill, :worker, [Sesame.Heart]},
      # OTA updater disabled — NervesHub handles OTA now
      # {Sesame.Ota.Updater, {Sesame.Ota.Updater, :start_link, [[manifest_url: "https://example.com/firmware/manifest.txt", poll_interval: 300_000]]}, :permanent, :brutal_kill, :worker, [Sesame.Ota.Updater]},
      {Sesame.Channel.Supervisor, {Sesame.Channel.Supervisor, :start_link, []}, :permanent, :brutal_kill, :worker, [Sesame.Channel.Supervisor]}
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
