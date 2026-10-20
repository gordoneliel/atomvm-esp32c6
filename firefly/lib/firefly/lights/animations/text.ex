defmodule Firefly.Lights.Animations.Text do
  @moduledoc """
  Text in a 3x5 pixel font. Text wider than the matrix scrolls right to left
  in a loop, pausing each time a character reaches the left edge so it can
  be read standing still; shorter text is shown still, centered.

  Covers digits, letters (lowercase is shown as uppercase), space and
  `- . : ! ? /`; anything else is shown as `?`.

  Options:
    * `:text` - a string or charlist
    * `:color`
    * `:interval` - milliseconds per column scrolled (default 120)
    * `:pause` - milliseconds to hold each character at the left edge
      (default 600, 0 to scroll without stopping)
  """

  @behaviour Firefly.Lights.Animation

  import Bitwise

  alias Firefly.Lights.{Frame, Matrix}

  # Rows top to bottom, # for lit
  @glyphs %{
    ?0 => ~w(### #.# #.# #.# ###),
    ?1 => ~w(.#. ##. .#. .#. ###),
    ?2 => ~w(### ..# ### #.. ###),
    ?3 => ~w(### ..# .## ..# ###),
    ?4 => ~w(#.# #.# ### ..# ..#),
    ?5 => ~w(### #.. ### ..# ###),
    ?6 => ~w(### #.. ### #.# ###),
    ?7 => ~w(### ..# ..# .#. .#.),
    ?8 => ~w(### #.# ### #.# ###),
    ?9 => ~w(### #.# ### ..# ###),
    ?A => ~w(.#. #.# ### #.# #.#),
    ?B => ~w(##. #.# ##. #.# ##.),
    ?C => ~w(.## #.. #.. #.. .##),
    ?D => ~w(##. #.# #.# #.# ##.),
    ?E => ~w(### #.. ##. #.. ###),
    ?F => ~w(### #.. ##. #.. #..),
    ?G => ~w(.## #.. #.# #.# .##),
    ?H => ~w(#.# #.# ### #.# #.#),
    ?I => ~w(### .#. .#. .#. ###),
    ?J => ~w(..# ..# ..# #.# .#.),
    ?K => ~w(#.# #.# ##. #.# #.#),
    ?L => ~w(#.. #.. #.. #.. ###),
    ?M => ~w(#.# ### ### #.# #.#),
    ?N => ~w(##. #.# #.# #.# #.#),
    ?O => ~w(.#. #.# #.# #.# .#.),
    ?P => ~w(##. #.# ##. #.. #..),
    ?Q => ~w(.#. #.# #.# ##. .##),
    ?R => ~w(##. #.# ##. #.# #.#),
    ?S => ~w(.## #.. .#. ..# ##.),
    ?T => ~w(### .#. .#. .#. .#.),
    ?U => ~w(#.# #.# #.# #.# ###),
    ?V => ~w(#.# #.# #.# #.# .#.),
    ?W => ~w(#.# #.# ### ### #.#),
    ?X => ~w(#.# #.# .#. #.# #.#),
    ?Y => ~w(#.# #.# .#. .#. .#.),
    ?Z => ~w(### ..# .#. #.. ###),
    ?\s => ~w(.. .. .. .. ..),
    ?- => ~w(... ... ### ... ...),
    ?. => ~w(. . . . #),
    ?: => ~w(. # . # .),
    ?! => ~w(# # # . #),
    ?? => ~w(### ..# .## ... .#.),
    ?/ => ~w(..# ..# .#. #.. #..)
  }

  # Each glyph as a list of columns, left to right, each a bitmask of its lit
  # rows (bit 0 the top row), worked out at compile time
  @font (for {char, rows} <- @glyphs, into: %{} do
           columns =
             for x <- 0..(String.length(hd(rows)) - 1) do
               rows
               |> Enum.with_index()
               |> Enum.reduce(0, fn {line, y}, mask ->
                 if String.at(line, x) == "#", do: mask ||| 1 <<< y, else: mask
               end)
             end

           {char, columns}
         end)

  @font_rows [0, 1, 2, 3, 4]

  # Blank columns between the end of scrolling text and its next repeat
  @gap 5

  @impl true
  def init(opts) do
    text = Keyword.get(opts, :text, "")
    text = if is_binary(text), do: :erlang.binary_to_list(text), else: text
    {columns, stops} = columns(text)
    # Without the blank column after the last glyph
    width = length(columns) - 1

    {columns, stops, offset} =
      if width <= Matrix.cols(),
        do: {columns, stops, -div(Matrix.cols() - width, 2)},
        else: {columns ++ :lists.duplicate(@gap, 0), stops ++ :lists.duplicate(@gap, false), nil}

    %{
      color: Keyword.get(opts, :color, {255, 255, 255}),
      interval: Keyword.get(opts, :interval, 120),
      pause: Keyword.get(opts, :pause, 600),
      columns: List.to_tuple(columns),
      # Whether each column is the first of a character to pause on
      stops: List.to_tuple(stops),
      # Still text: where it starts, relative to the left edge
      offset: offset,
      # Scrolling text: the text column at the left edge, starting a screen
      # before the text so it enters from the right
      position: -Matrix.cols()
    }
  end

  @impl true
  def next_frame(%{offset: nil, columns: columns, position: position} = state) do
    length = tuple_size(columns)

    column = fn x ->
      i = position + x
      if i >= 0, do: elem(columns, rem(i, length)), else: 0
    end

    # Pause with a character starting one column in, so two whole characters
    # show (columns 1-7) and only one column of the next
    delay =
      if position + 1 >= 0 and state.pause > 0 and elem(state.stops, rem(position + 1, length)),
        do: state.pause,
        else: state.interval

    next = if position + 1 == length, do: 0, else: position + 1
    {Frame.pixels(pixels(column, state.color)), delay, %{state | position: next}}
  end

  def next_frame(%{offset: offset, columns: columns} = state) do
    column = fn x ->
      i = x + offset
      if i >= 0 and i < tuple_size(columns), do: elem(columns, i), else: 0
    end

    {Frame.pixels(pixels(column, state.color)), :infinity, state}
  end

  # The lit pixels, given the column bitmask at each screen column
  defp pixels(column, color) do
    for x <- Matrix.col_indices(),
        mask = column.(x),
        mask != 0,
        y <- @font_rows,
        band(mask, 1 <<< y) != 0,
        do: {y, x, color}
  end

  # All of the text's columns, a blank one after each glyph, and whether
  # each is the first column of a character (other than a space)
  defp columns(text) do
    font = @font
    unknown = Map.fetch!(font, ??)

    columns =
      :lists.flatmap(
        fn char ->
          [first | rest] = Map.get(font, upcase(char), unknown)
          [{first, char != ?\s} | for(column <- rest ++ [0], do: {column, false})]
        end,
        text
      )

    {for({column, _stop} <- columns, do: column), for({_column, stop} <- columns, do: stop)}
  end

  defp upcase(char) when char >= ?a and char <= ?z, do: char - ?a + ?A
  defp upcase(char), do: char
end
