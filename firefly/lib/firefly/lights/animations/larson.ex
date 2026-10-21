defmodule Firefly.Lights.Animations.Larson do
  @moduledoc """
  A Larson scanner (KITT's or a Cylon's eye): a lit column bouncing between
  the edges of the matrix, leaving a fading trail.

  Options:
    * `:color`
    * `:fade` - percent of its brightness each column keeps per step, so
      higher leaves a longer trail (default 50)
    * `:interval` - milliseconds per step
  """

  @behaviour Firefly.Lights.Animation

  alias Firefly.Lights.{Color, Frame, Matrix}

  @impl true
  def init(opts) do
    %{
      color: Keyword.get(opts, :color, {255, 0, 0}),
      fade: Keyword.get(opts, :fade, 50),
      interval: Keyword.get(opts, :interval, 100),
      # Brightness of each column, 0..255
      levels: :erlang.make_tuple(Matrix.cols(), 0),
      step: 0
    }
  end

  @impl true
  def next_frame(state) do
    head = head(state.step)

    levels =
      List.to_tuple(
        for col <- Matrix.col_indices() do
          if col == head, do: 255, else: div(elem(state.levels, col) * state.fade, 100)
        end
      )

    pixels =
      for col <- Matrix.col_indices(),
          level = elem(levels, col),
          level > 0,
          color = Color.scale(state.color, level),
          row <- Matrix.row_indices(),
          do: {row, col, color}

    {Frame.pixels(pixels), state.interval, %{state | levels: levels, step: state.step + 1}}
  end

  # Column of the bright head: out to the right edge and back, without
  # lingering on either edge
  defp head(step) do
    last = Matrix.cols() - 1
    position = rem(step, 2 * last)
    if position <= last, do: position, else: 2 * last - position
  end
end
