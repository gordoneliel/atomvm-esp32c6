defmodule Firefly.Lights.Matrix do
  @moduledoc """
  Geometry of the 6x10 WS2812B matrix (60 LEDs).

  The LEDs are wired column-major in a serpentine: column 0 runs top to
  bottom (indices 0..5), column 1 bottom to top (6..11), and so on.
  """

  @rows 6
  @cols 10

  def rows, do: @rows
  def cols, do: @cols
  def size, do: @rows * @cols

  @row_indices Enum.to_list(0..(@rows - 1))
  @col_indices Enum.to_list(0..(@cols - 1))

  @doc """
  The row numbers as a list. Loop over this rather than a range: on AtomVM,
  comprehensions over ranges go through the `Enumerable` protocol and run
  several times slower than over lists.
  """
  def row_indices, do: @row_indices

  @doc "The column numbers as a list, see `row_indices/0`."
  def col_indices, do: @col_indices

  def in_bounds?(row, col), do: row >= 0 and row < @rows and col >= 0 and col < @cols

  @doc "Strip index of the LED at `row`, `col`."
  def index(row, col) do
    if rem(col, 2) == 0 do
      col * @rows + row
    else
      col * @rows + (@rows - 1 - row)
    end
  end
end
