defmodule Firefly.Lights.Supervisor do
  @moduledoc """
  Supervises the status LED, the LED matrix and the button.
  """

  alias Firefly.Lights.{Button, Server, StatusLed}

  def start_link do
    child_specs = [
      {StatusLed, {StatusLed, :start_link, [:off]}, :permanent, :brutal_kill, :worker,
       [StatusLed]},
      {Server, {Server, :start_link, [:idle]}, :permanent, :brutal_kill, :worker, [Server]},
      {Button, {Button, :start_link, []}, :permanent, :brutal_kill, :worker, [Button]}
    ]

    :supervisor.start_link({:local, :lights_sup}, __MODULE__, child_specs)
  end

  def init(child_specs) do
    {:ok, {{:one_for_one, 5, 60}, child_specs}}
  end
end
