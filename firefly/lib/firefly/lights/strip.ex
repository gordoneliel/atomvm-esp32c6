defmodule Firefly.Lights.Strip do
  @moduledoc """
  The WS2812B strip behind the matrix, on GPIO0. The only module that talks
  to the hardware (`:led_strip_nif`, wrapping ESP-IDF's RMT `led_strip`).
  """

  alias Firefly.Lights.{Frame, Matrix}

  @gpio_pin 0

  def init, do: :led_strip_nif.init(@gpio_pin, Matrix.size())

  @doc """
  Draws `frame` at `brightness` (`0..255`), in one NIF call: the NIF scales
  the colors and maps each pixel to its LED, with the wiring
  `Matrix.index/2` describes.
  """
  def show(%Frame{background: background, pixels: pixels}, brightness),
    do: :led_strip_nif.show(background, pixels, brightness, Matrix.rows())
end
