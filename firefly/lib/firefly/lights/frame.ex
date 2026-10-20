defmodule Firefly.Lights.Frame do
  @moduledoc """
  One frame of the LED matrix: a background color filling every LED, plus
  individually lit pixels drawn on top. Pixels outside the matrix are ignored.
  """

  alias Firefly.Lights.Color

  @type pixel :: {row :: integer(), col :: integer(), Color.t()}
  @type t :: %__MODULE__{background: Color.t(), pixels: [pixel()]}

  defstruct background: {0, 0, 0}, pixels: []

  @doc "A frame with every LED set to `color`."
  def fill(color), do: %__MODULE__{background: color}

  @doc "A frame with `pixels` lit on a black background."
  def pixels(pixels), do: %__MODULE__{pixels: pixels}
end
