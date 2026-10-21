defmodule Firefly.Lights.Animations.Pulse do
  @moduledoc """
  Every LED breathing between half and full intensity of a color.

  Options: `:color`, `:period` (steps per full cycle), `:interval`
  (milliseconds per step).
  """

  @behaviour Firefly.Lights.Animation

  alias Firefly.Lights.{Color, Frame}

  @impl true
  def init(opts) do
    %{
      color: Keyword.get(opts, :color, {0, 20, 0}),
      period: Keyword.get(opts, :period, 20),
      interval: Keyword.get(opts, :interval, 120),
      step: 0
    }
  end

  @impl true
  def next_frame(state) do
    half = div(state.period, 2)
    level = half + abs(rem(state.step, state.period) - half)
    color = Color.scale(state.color, level, state.period)

    {Frame.fill(color), state.interval, %{state | step: state.step + 1}}
  end
end
