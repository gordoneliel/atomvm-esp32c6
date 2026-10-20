defmodule Firefly.Lights.Animations.Ripple do
  @moduledoc """
  Rings rippling out from the center of the matrix, like a drop in water.

  Options (distances in tenths of an LED):
    * `:color`
    * `:speed` - how far the rings move out per step (default 5, half an LED)
    * `:spacing` - distance between rings (default 30)
    * `:width` - how far from a ring's crest the light fades out (default 12)
    * `:interval` - milliseconds per step
  """

  @behaviour Firefly.Lights.Animation

  alias Firefly.Lights.{Color, Frame, Matrix}

  @impl true
  def init(opts) do
    %{
      color: Keyword.get(opts, :color, {0, 120, 255}),
      speed: Keyword.get(opts, :speed, 5),
      spacing: Keyword.get(opts, :spacing, 30),
      width: Keyword.get(opts, :width, 12),
      interval: Keyword.get(opts, :interval, 80),
      distances: distances(),
      phase: 0
    }
  end

  @impl true
  def next_frame(%{color: color, phase: phase, spacing: spacing, width: width} = state) do
    # Fields are read once up front: map lookups per LED are slow on AtomVM
    pixels =
      for {row, col, distance} <- state.distances,
          level = level(distance, phase, spacing, width),
          level > 0,
          do: {row, col, Color.scale(color, level, width)}

    phase = rem(state.phase + state.speed, state.spacing)
    {Frame.pixels(pixels), state.interval, %{state | phase: phase}}
  end

  # Brightness (0..width) of an LED at `distance`: full on a ring's crest,
  # fading to nothing `width` away from it. Crests sit at `phase` plus
  # multiples of `spacing`, so they move outward as the phase grows.
  defp level(distance, phase, spacing, width) do
    offset = rem(rem(distance - phase, spacing) + spacing, spacing)
    from_crest = min(offset, spacing - offset)
    max(0, width - from_crest)
  end

  # Each LED's distance from the matrix center, in tenths of an LED
  defp distances do
    center_row = (Matrix.rows() - 1) / 2
    center_col = (Matrix.cols() - 1) / 2

    for row <- Matrix.row_indices(), col <- Matrix.col_indices() do
      dr = row - center_row
      dc = col - center_col
      {row, col, round(:math.sqrt(dr * dr + dc * dc) * 10)}
    end
  end
end
