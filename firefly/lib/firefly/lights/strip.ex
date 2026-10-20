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

    set_pixels(pixels, brightness)
    :led_strip_nif.refresh()
  end

  # A recursive loop with the scaling inlined: drawing runs every frame, and
  # this is much faster on AtomVM than a comprehension
  defp set_pixels([{row, col, {r, g, b}} | rest], brightness) do
    if Matrix.in_bounds?(row, col) do
      :led_strip_nif.set_pixel(
        Matrix.index(row, col),
        div(r * brightness, 255),
        div(g * brightness, 255),
        div(b * brightness, 255)
      )
    end

    set_pixels(rest, brightness)
  end

  defp set_pixels([], _brightness), do: :ok
end
