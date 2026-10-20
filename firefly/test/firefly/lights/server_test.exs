# Stands in for the LED strip NIF: keeps the LEDs in the drawing process's
# dictionary and sends them to the test on each refresh
defmodule :led_strip_nif do
  def init(_pin, size) do
    Process.put(:leds, :erlang.make_tuple(size, {0, 0, 0}))
    :ok
  end

  def fill(r, g, b), do: Process.put(:leds, :erlang.make_tuple(60, {r, g, b}))
  def set_pixel(i, r, g, b), do: Process.put(:leds, put_elem(Process.get(:leds), i, {r, g, b}))
  def refresh, do: send(:persistent_term.get(:led_strip_test), {:refresh, Process.get(:leds)})
end

defmodule Firefly.Lights.ServerTest do
  use ExUnit.Case, async: false

  alias Firefly.Lights
  alias Firefly.Lights.Animations.Solid

  setup do
    :persistent_term.put(:led_strip_test, self())
    {:ok, pid} = Lights.Server.start_link(:error)
    on_exit(fn -> Process.exit(pid, :kill) end)

    Lights.set_brightness(255)
    flush()
    :ok
  end

  defp flush do
    receive do
      {:refresh, _} -> flush()
    after
      50 -> :ok
    end
  end

  # The first LED's color on each refresh until they stop
  defp refreshes do
    receive do
      {:refresh, leds} -> [elem(leds, 0) | refreshes()]
    after
      100 -> []
    end
  end

  defp brightest({r, g, b}), do: max(r, max(g, b))

  # Splits the colors at the first black one, checking they dim down to it
  defp dims_to_black(colors) do
    {out, [{0, 0, 0} | rest]} = Enum.split_while(colors, &(&1 != {0, 0, 0}))
    levels = Enum.map(out, &brightest/1)
    assert levels == Enum.sort(levels, :desc)
    rest
  end

  test "switching animations fades out, then fades the new one in" do
    Lights.play(Solid, color: {0, 200, 0})
    fade_in = dims_to_black(refreshes())

    assert List.last(fade_in) == {0, 200, 0}
    assert Enum.all?(fade_in, fn {r, _g, b} -> r == 0 and b == 0 end)
    greens = for {_r, g, _b} <- fade_in, do: g
    assert greens == Enum.sort(greens)
  end

  test "power off fades out and stays dark, power on fades back in" do
    Lights.play(Solid, color: {0, 200, 0})
    refreshes()

    Lights.set_power(false)
    assert dims_to_black(refreshes()) == []

    Lights.set_power(true)
    assert List.last(refreshes()) == {0, 200, 0}
  end

  test "switching mid-fade fades out from where it is" do
    Lights.play(Solid, color: {0, 200, 0})
    Process.sleep(60)
    Lights.play(Solid, color: {0, 0, 200})

    # Still fading out the error animation's red, with no jump back up
    assert List.last(dims_to_black(refreshes())) == {0, 0, 200}
  end
end
