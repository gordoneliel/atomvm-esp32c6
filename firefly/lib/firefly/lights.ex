defmodule Firefly.Lights do
  @moduledoc """
  LED control: the 6x10 LED matrix and the status LED.

  The matrix always runs one animation, a module implementing
  `Firefly.Lights.Animation`. Play one of the named device states:

      Firefly.Lights.play(:commissioning)

  or any animation module with its options:

      Firefly.Lights.play(Firefly.Lights.Animations.Pulse, color: {0, 0, 40})

  Colors are `{r, g, b}` tuples (`0..255`), drawn at the matrix brightness.
  """

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
    Solid
  }

  @animations %{
    idle: {Chevron, [direction: :right]},
    arrow_right: {Chevron, [direction: :right]},
    arrow_left: {Chevron, [direction: :left]},
    commissioning: {Scan, [color: {0, 80, 255}]},
    offline: {Pulse, [color: {255, 90, 0}, period: 40, interval: 75]},
    connected: {Pulse, [color: {0, 20, 0}]},
    error: {Blink, [color: {30, 0, 0}]},
    ripple: {Ripple, []},
    scanner: {Larson, []},
    plasma: {Plasma, []},
    rain: {Rain, []},
    life: {Life, []}
  }

  # Order of the named animations for `cycle/0`: all but the still-looking
  # connected and error states (arrow_right is the same as idle)
  @cycle [
    :idle,
    :commissioning,
    :arrow_left,
    :ripple,
    :scanner,
    :plasma,
    :rain,
    :life
  ]

  @doc "Names accepted by `play/1`."
  def animations, do: Map.keys(@animations)

  @doc "The animation module and options behind a named state."
  def animation(name), do: Map.fetch!(@animations, name)

  @doc "The named animation after `name` in the cycle, wrapping around (the first for any other name)."
  def next(name), do: next_in(@cycle, name)

  defp next_in([name, next | _rest], name), do: next
  defp next_in([_ | rest], name), do: next_in(rest, name)
  defp next_in([], _name), do: hd(@cycle)

  @doc "Plays a named animation, see `animations/0`."
  def play(name) when is_map_key(@animations, name) do
    :gen_server.cast(:lights, {:play, name})
  end

  @doc "Plays an animation module with `opts`."
  def play(module, opts) when is_atom(module) and is_list(opts) do
    :gen_server.cast(:lights, {:play, module, opts})
  end

  @doc "Plays the next named animation in the cycle."
  def cycle, do: :gen_server.cast(:lights, :cycle)

  @doc "Sets every LED of the matrix to `color`."
  def fill(color), do: play(Solid, color: color)

  @doc "Turns the matrix off."
  def off, do: play(Solid, [])

  @doc "Turns the matrix on (resuming its animation) or off."
  def set_power(on?) when is_boolean(on?), do: :gen_server.cast(:lights, {:power, on?})

  @doc """
  Sets the color of every animation, replacing their own colors, or `nil` to
  go back to each animation's colors. The running animation is recolored as
  it plays, without restarting.
  """
  def set_color(color), do: :gen_server.cast(:lights, {:color, color})

  @doc """
  Shows a named animation (see `animations/0`) over the current one as a
  status, e.g. the device's state, until `set_status(nil)`; the current
  animation carries on after. A status keeps its own colors, and like any
  animation shows only while the power is on. Playing or cycling an
  animation dismisses it.
  """
  def set_status(name) when name == nil or is_map_key(@animations, name),
    do: :gen_server.cast(:lights, {:status, name})

  @doc """
  Identifies the device, e.g. when a controller asks which one it is: blinks
  the matrix over the current animation, visibly even if it's off, until
  `identify(false)` or for `ms` milliseconds. The animation carries on after.
  """
  def identify(on_or_ms) when is_boolean(on_or_ms) or is_integer(on_or_ms),
    do: :gen_server.cast(:lights, {:identify, on_or_ms})

  @doc "Sets the matrix brightness (`0..255`)."
  def set_brightness(level), do: :gen_server.cast(:lights, {:brightness, level})

  @doc "Sets the status LED to `:blink`, `:on` or `:off`."
  def status_led(mode) when mode in [:blink, :on, :off] do
    :gen_server.cast(:status_led, {:mode, mode})
  end
end
