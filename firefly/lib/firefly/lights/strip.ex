defmodule Firefly.Lights.Strip do
  @moduledoc """
  The WS2812B strip behind the matrix, on GPIO0. The only module that talks
  to the hardware (`:led_strip_nif`, wrapping ESP-IDF's RMT `led_strip`).
  """

  alias Firefly.Lights.{Color, Frame, Matrix}

  @gpio_pin 0

  def init, do: :led_strip_nif.init(@gpio_pin, Matrix.size())

  @doc "Draws `frame` at `brightness` (`0..255`)."
  def show(%Frame{background: background, pixels: pixels}, brightness) do
    {r, g, b} = Color.scale(background, brightness)
    :led_strip_nif.fill(r, g, b)

    for {row, col, color} <- pixels, Matrix.in_bounds?(row, col) do
      {r, g, b} = Color.scale(color, brightness)
      :led_strip_nif.set_pixel(Matrix.index(row, col), r, g, b)
    end

    :led_strip_nif.refresh()
  end
end
