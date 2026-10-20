defmodule Firefly.Lights.Animations.Blink do
  @moduledoc """
  Every LED blinking a color on and off.

  Options: `:color`, `:interval` (milliseconds on, then the same off).
  """

  @behaviour Firefly.Lights.Animation

  alias Firefly.Lights.{Color, Frame}

  @impl true
  def init(opts) do
    %{
      color: Keyword.get(opts, :color, {30, 0, 0}),
      interval: Keyword.get(opts, :interval, 800),
      on: true
    }
  end

  @impl true
  def next_frame(state) do
    color = if state.on, do: state.color, else: Color.black()
    {Frame.fill(color), state.interval, %{state | on: not state.on}}
  end
end
