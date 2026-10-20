defmodule Firefly.Lights.AnimationsTest do
  use ExUnit.Case, async: true

  alias Firefly.Lights
  alias Firefly.Lights.{Frame, Matrix}

  alias Firefly.Lights.Animations.{
    Blink,
    Chevron,
    Larson,
    Life,
    Plasma,
    Pulse,
    Rain,
    Ripple,
    Scan,
    Solid,
    Text
  }

  # Runs an animation for `count` frames, returning [{frame, delay}]
  defp frames(module, opts, count) do
    {frames, _state} =
      Enum.map_reduce(1..count, module.init(opts), fn _, state ->
        {frame, delay, state} = module.next_frame(state)
        {{frame, delay}, state}
      end)

    frames
  end

  defp lit(%Frame{pixels: pixels}),
    do: Enum.sort(for {row, col, _color} <- pixels, do: {row, col})

  test "solid is a still frame" do
    assert [{%Frame{background: {1, 2, 3}, pixels: []}, :infinity}] =
             frames(Solid, [color: {1, 2, 3}], 1)

    assert [{%Frame{background: {0, 0, 0}}, :infinity}] = frames(Solid, [], 1)
  end

  test "chevron scrolls right, entering from the left edge" do
    [{first, 80}, _, {third, 80}] = frames(Chevron, [direction: :right], 3)

    assert lit(first) == [{0, -2}, {1, -1}, {2, 0}, {3, 0}, {4, -1}, {5, -2}]
    assert lit(third) == [{0, 0}, {1, 1}, {2, 2}, {3, 2}, {4, 1}, {5, 0}]
  end

  test "chevron scrolls left as a left-pointing arrow" do
    {frame, _delay} = frames(Chevron, [direction: :left], 13) |> List.last()

    assert lit(frame) == [{0, 2}, {1, 1}, {2, 0}, {3, 0}, {4, 1}, {5, 2}]
  end

  test "chevron loops after scrolling across" do
    frames = frames(Chevron, [], 15)
    assert Enum.at(frames, 0) == Enum.at(frames, 14)
  end

  test "scan lights one column at a time and wraps" do
    frames = frames(Scan, [color: {0, 0, 40}], 11)

    {first, 80} = Enum.at(frames, 0)
    assert lit(first) == for(row <- 0..5, do: {row, 0})
    assert {_, _, {0, 0, 40}} = hd(first.pixels)

    {second, _} = Enum.at(frames, 1)
    assert lit(second) == for(row <- 0..5, do: {row, 1})

    assert Enum.at(frames, 10) == Enum.at(frames, 0)
  end

  test "pulse breathes between full and half intensity" do
    colors = for {frame, 80} <- frames(Pulse, [color: {0, 20, 0}], 21), do: frame.background

    assert Enum.at(colors, 0) == {0, 20, 0}
    assert Enum.at(colors, 10) == {0, 10, 0}
    assert Enum.at(colors, 20) == {0, 20, 0}
  end

  test "blink alternates the color and black" do
    assert [
             {%Frame{background: {30, 0, 0}}, 800},
             {%Frame{background: {0, 0, 0}}, 800},
             {%Frame{background: {30, 0, 0}}, 800}
           ] = frames(Blink, [color: {30, 0, 0}], 3)
  end

  # Blue level of the LED at row, col in a frame (0 when dark)
  defp level(%Frame{pixels: pixels}, row, col) do
    Enum.find_value(pixels, 0, fn
      {^row, ^col, {_r, _g, b}} -> b
      _ -> nil
    end)
  end

  test "ripple rings reach LEDs further from the center later" do
    frames = for {frame, 80} <- frames(Ripple, [color: {0, 0, 120}], 6), do: frame

    peak_step = fn row, col ->
      levels = Enum.map(frames, &level(&1, row, col))
      Enum.find_index(levels, &(&1 == Enum.max(levels)))
    end

    # 0.7, 1.6 and 2.5 LEDs from the center
    assert peak_step.(2, 4) < peak_step.(2, 6)
    assert peak_step.(2, 6) < peak_step.(2, 7)
  end

  test "ripple leaves LEDs between rings dark" do
    [{frame, _}] = frames(Ripple, [color: {0, 0, 120}], 1)

    # 1.6 LEDs out, halfway between the crests at 0 and 3 LEDs
    assert level(frame, 2, 6) == 0
    assert level(frame, 2, 3) == 0
    # 0.7 LEDs out, near the first crest
    assert level(frame, 2, 4) > 0
  end

  test "ripple loops once the rings have moved one spacing" do
    frames = frames(Ripple, [speed: 5, spacing: 30], 7)
    assert Enum.at(frames, 0) == Enum.at(frames, 6)
  end

  test "named animations resolve to animation modules" do
    for name <- Lights.animations() do
      {module, opts} = Lights.animation(name)
      assert {%Frame{}, _delay, _state} = module.next_frame(module.init(opts))
    end

    assert Lights.animation(:commissioning) == {Scan, [color: {0, 0, 40}]}
  end

  test "cycle visits every named animation in order and wraps" do
    names = Enum.scan(1..8, :idle, fn _, name -> Lights.next(name) end)

    assert names == [
             :commissioning,
             :arrow_left,
             :ripple,
             :scanner,
             :plasma,
             :rain,
             :life,
             :idle
           ]
  end

  test "cycle starts from the first animation after an unnamed one" do
    assert Lights.next(nil) == :idle
    assert Lights.next(:arrow_right) == :idle
  end

  # Red level of every lit column in a frame of full-height columns
  defp column_levels(%Frame{pixels: pixels}) do
    pixels |> Enum.map(fn {_row, col, {r, _g, _b}} -> {col, r} end) |> Enum.uniq() |> Enum.sort()
  end

  test "larson scanner bounces between the edges" do
    heads =
      for {frame, 70} <- frames(Larson, [], 20) do
        {col, 255} = Enum.find(column_levels(frame), fn {_col, level} -> level == 255 end)
        col
      end

    assert heads == Enum.to_list(0..9) ++ Enum.to_list(8..1//-1) ++ [0, 1]
  end

  test "larson scanner leaves a fading trail" do
    {frame, _} = frames(Larson, [color: {255, 0, 0}, fade: 50], 3) |> List.last()
    assert column_levels(frame) == [{0, 63}, {1, 127}, {2, 255}]

    # Back from the right edge, the trail on both sides of the head
    {frame, _} = frames(Larson, [color: {255, 0, 0}, fade: 50], 12) |> List.last()
    assert column_levels(frame) == [{4, 1}, {5, 3}, {6, 7}, {7, 255}, {8, 127}, {9, 63}]
  end

  test "plasma colors every LED and loops" do
    frames = for {frame, 80} <- frames(Plasma, [speed: 4], 65), do: frame

    assert length(lit(hd(frames))) == Matrix.size()
    assert Enum.at(frames, 0) != Enum.at(frames, 1)
    assert Enum.at(frames, 0) == Enum.at(frames, 64)
  end

  # Positions of drop heads, the brightest LEDs of the rain
  defp heads(%Frame{pixels: pixels}),
    do: Enum.sort(for {row, col, {r, _, _}} <- pixels, r > 0, do: {row, col})

  test "rain drops fall down their column, one row or none per step" do
    heads = for {frame, 70} <- frames(Rain, [seed: 42, density: 60], 40), do: heads(frame)

    for {before, later} <- Enum.zip(heads, tl(heads)), {row, col} <- later, row > 0 do
      assert {row, col} in before or {row - 1, col} in before
    end

    assert Enum.any?(heads, &(length(&1) > 2))
  end

  test "rain is the same for the same seed" do
    assert frames(Rain, [seed: 7], 30) == frames(Rain, [seed: 7], 30)
    assert frames(Rain, [seed: 7], 30) != frames(Rain, [seed: 8], 30)
  end

  test "rain drops are gone once their tails leave the bottom" do
    state = Enum.reduce(1..10, Rain.init(seed: 1, density: 100), &step/2)
    assert state.drops != []

    # Slow drops take 2 steps a row
    state = Enum.reduce(1..18, %{state | density: 0}, &step/2)
    assert state.drops == []
    assert {%Frame{pixels: []}, _, _} = Rain.next_frame(state)
  end

  defp step(_, state), do: state |> Rain.next_frame() |> elem(2)

  defp board(cells),
    do: List.to_tuple(for i <- 0..59, do: {div(i, 10), rem(i, 10)} in cells)

  defp life(board), do: %{Life.init(seed: 1) | board: board, previous: nil}

  defp generations(state, count) do
    Enum.reduce(1..count, state, fn _, state -> state |> Life.next_frame() |> elem(2) end)
  end

  test "life moves a glider, wrapping at the edges" do
    glider = [{0, 1}, {1, 2}, {2, 0}, {2, 1}, {2, 2}]
    moved = for {row, col} <- glider, do: {row + 1, col + 1}
    assert generations(life(board(glider)), 4).board == board(moved)

    # Over the bottom right corner
    corner = for {row, col} <- glider, do: {rem(row + 4, 6), rem(col + 8, 10)}
    wrapped = for {row, col} <- glider, do: {rem(row + 5, 6), rem(col + 9, 10)}
    assert generations(life(board(corner)), 4).board == board(wrapped)
  end

  test "life shows dying cells dimly for a generation" do
    glider = [{0, 1}, {1, 2}, {2, 0}, {2, 1}, {2, 2}]
    state = generations(%{life(board(glider)) | color: {0, 240, 0}}, 1)
    {frame, 250, _} = Life.next_frame(state)

    # (0, 1) and (2, 0) died, (1, 0) and (3, 1) were born
    assert {0, 1, {0, 30, 0}} in frame.pixels
    assert {1, 0, {0, 240, 0}} in frame.pixels
  end

  test "life starts over once the board settles" do
    block = board([{1, 1}, {1, 2}, {2, 1}, {2, 2}])
    state = generations(life(block), 1)

    assert state.board != block
    assert state.generation == 0
  end

  test "life starts over after the most generations" do
    glider = board([{0, 1}, {1, 2}, {2, 0}, {2, 1}, {2, 2}])
    state = generations(%{life(glider) | generations: 3}, 4)
    assert state.generation == 0
  end

  test "short text is shown still, centered" do
    [{frame, :infinity}] = frames(Text, [text: "1"], 1)

    # .#.
    # ##.
    # .#.
    # .#.
    # ###
    assert lit(frame) ==
             Enum.sort([{0, 4}, {1, 3}, {1, 4}, {2, 4}, {3, 4}, {4, 3}, {4, 4}, {4, 5}])
  end

  test "text shows lowercase as uppercase, and unknown characters as ?" do
    assert frames(Text, [text: "ok"], 1) == frames(Text, [text: ~c"OK"], 1)
    assert frames(Text, [text: "~"], 1) == frames(Text, [text: "?"], 1)
  end

  test "long text scrolls in from the right and loops" do
    # 11 glyphs, each 3 columns and a blank one, then a gap of 5
    loop = 11 * 4 + 5
    opts = [text: "34970112332", pause: 0]
    frames = for {frame, 120} <- frames(Text, opts, 10 + loop + 1), do: frame

    assert hd(frames) == Frame.pixels([])
    # Entering: the 3's left column (top and bottom lit) at the right edge
    assert lit(Enum.at(frames, 1)) == [{0, 9}, {4, 9}]
    # Reaching the left edge, then again a loop later
    assert {0, 0} in lit(Enum.at(frames, 10))
    assert Enum.at(frames, 10 + loop) == Enum.at(frames, 10)
  end

  test "scrolling text pauses as each character reaches the left edge" do
    delays = for {_frame, delay} <- frames(Text, [text: "12 3456789"], 10 + 16), do: delay

    # Entering, then 1 and 2 a column in from the left edge, 4 columns apart,
    # then the space (3 columns) without a pause, then 3
    pauses = for {600, i} <- Enum.with_index(delays), do: i
    assert Enum.take(pauses, 3) == [9, 13, 20]
    assert Enum.all?(delays, &(&1 in [120, 600]))
  end
end
