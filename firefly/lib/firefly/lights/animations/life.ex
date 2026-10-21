defmodule Firefly.Lights.Animations.Life do
  @moduledoc """
  Conway's Game of Life on the matrix, wrapping around at the edges. Cells
  that have just died linger dimly for a generation.

  Starts from a random board, and starts over once the board dies out,
  settles into a still or blinking pattern, or reaches `:generations`.

  Options:
    * `:color`
    * `:density` - percent of cells alive on a new board (default 35)
    * `:generations` - most generations before starting over (default 120)
    * `:interval` - milliseconds per generation
    * `:seed` - random seed, see `Firefly.Lights.Random`
  """

  @behaviour Firefly.Lights.Animation

  alias Firefly.Lights.{Color, Frame, Matrix, Random}

  @impl true
  def init(opts) do
    state = %{
      color: Keyword.get(opts, :color, {40, 255, 0}),
      density: Keyword.get(opts, :density, 35),
      generations: Keyword.get(opts, :generations, 120),
      interval: Keyword.get(opts, :interval, 400),
      seed: Keyword.get_lazy(opts, :seed, &Random.seed/0),
      neighbors: neighbors(),
      # Boards are tuples of booleans (alive?) indexed by row * cols + col.
      # `previous` is the generation before, for the dying cells.
      board: nil,
      previous: nil,
      generation: 0
    }

    reseed(state)
  end

  @impl true
  def next_frame(state) do
    {Frame.pixels(pixels(state)), state.interval, evolve(state)}
  end

  defp pixels(%{board: board, previous: previous, color: color}) do
    dying = Color.scale(color, 1, 8)

    for row <- Matrix.row_indices(),
        col <- Matrix.col_indices(),
        i = row * Matrix.cols() + col,
        elem(board, i) or (previous != nil and elem(previous, i)),
        do: {row, col, if(elem(board, i), do: color, else: dying)}
  end

  defp evolve(%{board: board} = state) do
    next = next_generation(board, state.neighbors)

    stuck =
      next == board or next == state.previous or not alive?(next) or
        state.generation >= state.generations

    if stuck,
      do: reseed(%{state | previous: board}),
      else: %{state | board: next, previous: board, generation: state.generation + 1}
  end

  defp next_generation(board, neighbors), do: List.to_tuple(next_cells(board, neighbors, 0))

  # Recursive loops: this is the bulk of the work each generation, and much
  # faster on AtomVM than comprehensions
  defp next_cells(board, [cell_neighbors | rest], i) do
    count = count_alive(board, cell_neighbors, 0)
    [count == 3 or (count == 2 and elem(board, i)) | next_cells(board, rest, i + 1)]
  end

  defp next_cells(_board, [], _i), do: []

  defp count_alive(board, [i | rest], count),
    do: count_alive(board, rest, if(elem(board, i), do: count + 1, else: count))

  defp count_alive(_board, [], count), do: count

  defp alive?(board), do: :lists.member(true, :erlang.tuple_to_list(board))

  defp reseed(state) do
    {cells, seed} =
      :lists.mapfoldl(
        fn _i, seed -> Random.chance(seed, state.density) end,
        state.seed,
        :lists.seq(1, Matrix.size())
      )

    %{state | board: List.to_tuple(cells), seed: seed, generation: 0}
  end

  # For each cell in board order, the indices of its eight neighbors,
  # wrapping around the edges
  defp neighbors do
    rows = Matrix.rows()
    cols = Matrix.cols()

    for row <- Matrix.row_indices(), col <- Matrix.col_indices() do
      for dr <- [-1, 0, 1], dc <- [-1, 0, 1], {dr, dc} != {0, 0} do
        rem(row + dr + rows, rows) * cols + rem(col + dc + cols, cols)
      end
    end
  end
end
