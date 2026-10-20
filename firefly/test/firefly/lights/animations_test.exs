defmodule Firefly.Lights.AnimationsTest do
  use ExUnit.Case, async: true

  alias Firefly.Lights
  alias Firefly.Lights.Frame
  alias Firefly.Lights.Animations.{Blink, Chevron, Pulse, Ripple, Scan, Solid}

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
    names = Enum.scan(1..6, :idle, fn _, name -> Lights.next(name) end)
    assert names == [:commissioning, :connected, :error, :arrow_left, :ripple, :idle]
  end

  test "cycle starts from the first animation after an unnamed one" do
    assert Lights.next(nil) == :idle
    assert Lights.next(:arrow_right) == :idle
  end
end
