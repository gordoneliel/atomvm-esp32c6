defmodule Firefly.Matter do
  @moduledoc """
  Matter supervisor.

  Starts the Matter device manager which handles the Matter application
  layer over Thread (or WiFi). Waits for Thread to be available before
  initializing the Matter stack.
  """

  def start_link do
    child_specs = [
      {Firefly.Matter.Device, {Firefly.Matter.Device, :start_link, []},
       :permanent, :brutal_kill, :worker, [Firefly.Matter.Device]}
    ]

    :supervisor.start_link({:local, :matter_sup}, __MODULE__, child_specs)
  end

  def init(child_specs) do
    {:ok, {{:one_for_one, 3, 60}, child_specs}}
  end
end
