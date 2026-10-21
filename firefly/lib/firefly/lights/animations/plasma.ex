defmodule Firefly.Lights.Animations.Plasma do
  @moduledoc """
  Plasma: overlapping sine waves drifting across the matrix, colored around
  the color wheel, which itself slowly turns.

  Options: `:speed` (how far the waves move per step, out of 256 for a full
  cycle, default 6), `:interval` (milliseconds per step). Every LED changes
  every step, so this is the most expensive animation to draw: keep the
  interval long.
  """

  @behaviour Firefly.Lights.Animation

  import Bitwise

  alias Firefly.Lights.{Color, Frame, Matrix}

  @impl true
  def init(opts) do
    %{
      speed: Keyword.get(opts, :speed, 6),
      interval: Keyword.get(opts, :interval, 120),
      sine: sine(),
      waves: waves(),
      time: 0
    }
  end

  @impl true
  def next_frame(%{sine: sine, time: t} = state) do
    # Each wave drifts at its own speed and direction. Their sum (0..1020)
    # picks the color, shifted by time so the palette cycles too.
    pixels =
      for {row, col, across, down, diagonal, ring} <- state.waves do
        # Lookups inlined, as this runs for every LED every step
        value =
          elem(sine, band(across + t, 255)) + elem(sine, band(down - 2 * t, 255)) +
            elem(sine, band(diagonal + 3 * t, 255)) + elem(sine, band(ring - t, 255))

        {row, col, Color.wheel(div(value, 4) + t)}
      end

    {Frame.pixels(pixels), state.interval, %{state | time: band(t + state.speed, 255)}}
  end

  # One cycle of a sine wave in 256 steps, scaled to 0..255, so frames need
  # only integer math
  defp sine do
    List.to_tuple(for i <- 0..255, do: round(127.5 + 127.5 * :math.sin(i * :math.pi() / 128)))
  end

  # Each LED's phase in the four waves: across the matrix, down it, along the
  # diagonal and in rings around a point off the top-left corner. Each wave
  # spans most of a cycle over the matrix.
  defp waves do
    for row <- Matrix.row_indices(), col <- Matrix.col_indices() do
      dr = row + 2
      dc = col + 3
      ring = round(:math.sqrt(dr * dr + dc * dc) * 24)
      {row, col, col * 24, row * 36, (row + col) * 16, ring}
    end
  end
end
