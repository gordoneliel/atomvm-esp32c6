defmodule Firefly.Lights.MatrixTest do
  use ExUnit.Case, async: true

  alias Firefly.Lights.{Color, Matrix, Random}

  test "maps coordinates to the column-major serpentine wiring" do
    assert Matrix.index(0, 0) == 0
    assert Matrix.index(5, 0) == 5
    assert Matrix.index(5, 1) == 6
    assert Matrix.index(0, 1) == 11
    assert Matrix.index(0, 2) == 12
    assert Matrix.index(0, 9) == 59
  end

  test "every LED has exactly one coordinate" do
    indices = for row <- 0..5, col <- 0..9, do: Matrix.index(row, col)
    assert Enum.sort(indices) == Enum.to_list(0..(Matrix.size() - 1))
  end

  test "bounds" do
    assert Matrix.in_bounds?(5, 9)
    refute Matrix.in_bounds?(6, 0)
    refute Matrix.in_bounds?(0, -1)
  end

  test "scales colors by brightness" do
    assert Color.scale({255, 128, 0}, 255) == {255, 128, 0}
    assert Color.scale({255, 128, 0}, 64) == {64, 32, 0}
    assert Color.scale({0, 20, 0}, 10, 20) == {0, 10, 0}
  end

  test "blends colors" do
    assert Color.blend({200, 0, 40}, {0, 100, 40}, 0, 4) == {200, 0, 40}
    assert Color.blend({200, 0, 40}, {0, 100, 40}, 1, 4) == {150, 25, 40}
    assert Color.blend({200, 0, 40}, {0, 100, 40}, 4, 4) == {0, 100, 40}
  end

  test "color wheel goes red, green, blue and wraps" do
    assert Color.wheel(0) == {255, 0, 0}
    assert Color.wheel(85) == {0, 255, 0}
    assert Color.wheel(170) == {0, 0, 255}
    assert Color.wheel(256) == Color.wheel(0)
    assert Color.wheel(-1) == Color.wheel(255)
  end

  test "random numbers are in range and repeat for a seed" do
    numbers = fn seed ->
      {numbers, _seed} =
        :lists.mapfoldl(fn _, seed -> Random.uniform(seed, 10) end, seed, Enum.to_list(1..1000))

      numbers
    end

    assert Enum.uniq(numbers.(5)) |> Enum.sort() == Enum.to_list(0..9)
    assert numbers.(5) == numbers.(5)
    assert numbers.(5) != numbers.(6)
    assert is_integer(Random.seed())
  end
end
