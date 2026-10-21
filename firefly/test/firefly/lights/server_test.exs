# Stands in for the LED strip NIF: draws each frame as the NIF does, and
# sends the LEDs (indexed as on the strip) to the test
defmodule :led_strip_nif do
  alias Firefly.Lights.{Color, Matrix}

  def init(_pin, _size), do: :ok

  def show(background, pixels, brightness, _rows) do
    leds = :erlang.make_tuple(Matrix.size(), Color.scale(background, brightness))

    leds =
      Enum.reduce(pixels, leds, fn {row, col, color}, leds ->
        if Matrix.in_bounds?(row, col),
          do: put_elem(leds, Matrix.index(row, col), Color.scale(color, brightness)),
          else: leds
      end)

    send(:persistent_term.get(:led_strip_test), {:refresh, leds})
    :ok
  end
end

defmodule Firefly.Lights.ServerTest do
  use ExUnit.Case, async: false

  alias Firefly.Lights
  alias Firefly.Lights.Animations.{Pulse, Solid}

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

  # The first LED's color on each refresh for `ms` milliseconds
  defp refreshes_for(ms) do
    deadline = :erlang.monotonic_time(:millisecond) + ms
    collect_until(deadline)
  end

  defp collect_until(deadline) do
    receive do
      {:refresh, leds} -> [elem(leds, 0) | collect_until(deadline)]
    after
      max(0, deadline - :erlang.monotonic_time(:millisecond)) -> []
    end
  end

  test "changing the color recolors a still animation in place" do
    Lights.play(Solid, color: {0, 200, 0})
    refreshes()

    Lights.set_color({0, 0, 200})
    assert refreshes() == [{0, 0, 200}]
  end

  test "changing the color recolors a moving animation without a dip to black" do
    Lights.play(Pulse, color: {0, 200, 0})
    refreshes_for(300)

    Lights.set_color({200, 0, 0})
    colors = refreshes_for(300)

    assert {0, 0, 0} not in colors
    assert {r, 0, 0} = List.last(colors)
    assert r > 0
  end

  test "identifying blinks over the animation, then it comes back" do
    Lights.play(Solid, color: {0, 200, 0})
    refreshes()

    Lights.identify(600)
    colors = refreshes_for(1_000)

    assert {255, 255, 255} in colors
    assert List.last(colors) == {0, 200, 0}
  end

  test "identifying shows even when the light is off" do
    Lights.play(Solid, color: {0, 200, 0})
    refreshes()
    Lights.set_power(false)
    refreshes()

    Lights.identify(true)
    assert {255, 255, 255} in refreshes_for(600)

    Lights.identify(false)
    assert List.last(refreshes()) == {0, 0, 0}
  end

  test "power and color changes while identifying apply when it ends" do
    Lights.play(Solid, color: {0, 200, 0})
    refreshes()

    Lights.identify(true)
    Lights.set_color({0, 0, 200})
    refreshes_for(300)

    Lights.identify(false)
    assert List.last(refreshes()) == {0, 0, 200}
  end

  test "a burst of brightness changes draws only the latest" do
    Lights.play(Solid, color: {0, 200, 0})
    refreshes()

    for level <- 1..100, do: Lights.set_brightness(level)
    colors = refreshes()

    assert length(colors) < 100
    assert List.last(colors) == {0, div(200 * 100, 255), 0}
  end

  test "a status shows over the animation, which comes back after" do
    Lights.play(Solid, color: {0, 200, 0})
    refreshes()

    Lights.set_status(:offline)
    {r, g, 0} = List.last(refreshes_for(300))
    assert r > g and g > 0

    Lights.set_status(nil)
    assert List.last(refreshes()) == {0, 200, 0}
  end

  test "a status keeps its colors, and the light's color applies after" do
    Lights.play(Solid, color: {0, 200, 0})
    Lights.set_status(:offline)
    refreshes_for(300)

    Lights.set_color({0, 0, 200})
    {r, _g, 0} = List.last(refreshes_for(300))
    assert r > 0

    Lights.set_status(nil)
    assert List.last(refreshes()) == {0, 0, 200}
  end

  test "a status shows only while the power is on" do
    Lights.play(Solid, color: {0, 200, 0})
    Lights.set_power(false)
    refreshes()

    Lights.set_status(:offline)
    assert Enum.all?(refreshes_for(300), &(&1 == {0, 0, 0}))
  end

  test "playing an animation dismisses the status" do
    Lights.play(Solid, color: {0, 200, 0})
    Lights.set_status(:offline)
    refreshes_for(300)

    Lights.play(Solid, color: {0, 0, 200})
    assert List.last(refreshes()) == {0, 0, 200}
  end
end
