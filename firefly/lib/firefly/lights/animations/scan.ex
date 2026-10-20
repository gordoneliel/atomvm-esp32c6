defmodule Firefly.Lights.Animations.Scan do
  @moduledoc """
  A single lit column sweeping left to right.

  Options: `:color`, `:interval` (milliseconds per column).
  """

  @behaviour Firefly.Lights.Animation

  alias Firefly.Lights.{Frame, Matrix}

  @impl true
  def init(opts) do
    %{
      color: Keyword.get(opts, :color, {0, 0, 40}),
      interval: Keyword.get(opts, :interval, 80),
      step: 0
    }
  end

  @impl true
  def next_frame(state) do
    col = rem(state.step, Matrix.cols())
    pixels = for row <- 0..(Matrix.rows() - 1), do: {row, col, state.color}

    {Frame.pixels(pixels), state.interval, %{state | step: state.step + 1}}
  end
end
