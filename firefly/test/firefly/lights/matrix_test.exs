defmodule Firefly.Lights.MatrixTest do
  use ExUnit.Case, async: true

  alias Firefly.Lights.{Color, Matrix}

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
end
