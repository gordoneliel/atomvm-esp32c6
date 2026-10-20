defmodule Firefly.Lights.Animations.Chevron do
  @moduledoc """
  A chevron arrow scrolling across the matrix.

  Options: `:direction` (`:right` or `:left`, default `:right`), `:color`,
  `:interval` (milliseconds per step).
  """

  @behaviour Firefly.Lights.Animation

  alias Firefly.Lights.{Frame, Matrix}

  # Right-pointing chevron, 6 rows by 3 columns:
  #   X . .
  #   . X .
  #   . . X
  #   . . X
  #   . X .
  #   X . .
  @shape [{0, 0}, {1, 1}, {2, 2}, {3, 2}, {4, 1}, {5, 0}]
  @width 3

  @impl true
  def init(opts) do
    %{
      direction: Keyword.get(opts, :direction, :right),
      color: Keyword.get(opts, :color, {0, 180, 255}),
      interval: Keyword.get(opts, :interval, 80),
      step: 0
    }
  end

  @impl true
  def next_frame(state) do
    # One position per column, plus room to scroll in and out at the edges
    span = Matrix.cols() + @width + 1
    position = rem(state.step, span)

    pixels =
      for {row, col} <- @shape do
        case state.direction do
          :right -> {row, col + position - 2, state.color}
          :left -> {row, @width - 1 - col + Matrix.cols() + 2 - position, state.color}
        end
      end

    {Frame.pixels(pixels), state.interval, %{state | step: state.step + 1}}
  end
end
