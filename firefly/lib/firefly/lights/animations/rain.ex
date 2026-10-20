defmodule Firefly.Lights.Animations.Rain do
  @moduledoc """
  Digital rain: drops falling down the columns, each with a bright head and a
  fading tail. Some drops fall at half speed.

  Options:
    * `:color`
    * `:density` - percent chance of a new drop each step (default 45)
    * `:tail` - LEDs in a drop's tail (default 3)
    * `:interval` - milliseconds per step
    * `:seed` - random seed, see `Firefly.Lights.Random`
  """

  @behaviour Firefly.Lights.Animation

  alias Firefly.Lights.{Color, Frame, Matrix, Random}

  @white {255, 255, 255}

  @impl true
  def init(opts) do
    %{
      color: Keyword.get(opts, :color, {0, 255, 70}),
      density: Keyword.get(opts, :density, 45),
      tail: Keyword.get(opts, :tail, 3),
      interval: Keyword.get(opts, :interval, 70),
      seed: Keyword.get_lazy(opts, :seed, &Random.seed/0),
      # {col, row of the head, slow?}
      drops: [],
      step: 0
    }
  end

  @impl true
  def next_frame(state) do
    frame = Frame.pixels(pixels(state))
    state = state |> fall() |> new_drop()
    {frame, state.interval, %{state | step: state.step + 1}}
  end

  defp pixels(%{color: color, tail: tail, drops: drops}) do
    head = Color.blend(color, @white, 1, 3)

    for {col, row, _slow} <- drops, i <- :lists.seq(0, tail) do
      if i == 0,
        do: {row, col, head},
        else: {row - i, col, Color.scale(color, tail + 1 - i, tail + 1)}
    end
  end

  # Moves every drop down, slow ones every other step, dropping those whose
  # tail has left the bottom
  defp fall(%{drops: drops, step: step, tail: tail} = state) do
    drops =
      for {col, row, slow} <- drops,
          row = if(slow and rem(step, 2) == 1, do: row, else: row + 1),
          row - tail < Matrix.rows(),
          do: {col, row, slow}

    %{state | drops: drops}
  end

  # Maybe starts a drop at the top of a random column, unless the column's
  # last drop is still close enough to the top to run into
  defp new_drop(state) do
    {spawn?, seed} = Random.chance(state.seed, state.density)
    {col, seed} = Random.uniform(seed, Matrix.cols())
    {slow, seed} = Random.chance(seed, 50)
    crowded = Enum.any?(state.drops, fn {c, row, _} -> c == col and row <= state.tail end)

    drops = if spawn? and not crowded, do: [{col, 0, slow} | state.drops], else: state.drops
    %{state | drops: drops, seed: seed}
  end
end
