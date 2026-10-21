defmodule Firefly.Lights.Animation do
  @moduledoc """
  Behaviour for LED matrix animations.

  Animations are pure: they never touch the hardware. `init/1` builds the
  animation's state from its options, and `next_frame/1` returns the frame to
  show, how long to show it in milliseconds (`:infinity` for a still image),
  and the state for the following frame. `Firefly.Lights.Server` runs the
  animation and draws its frames.

      defmodule MyAnimation do
        @behaviour Firefly.Lights.Animation

        def init(opts), do: %{color: Keyword.get(opts, :color, {0, 0, 40})}

        def next_frame(state), do: {Firefly.Lights.Frame.fill(state.color), :infinity, state}
      end

      Firefly.Lights.play(MyAnimation, color: {40, 0, 0})

  An animation that takes a `:color` option should keep it in its state as a
  map's `:color` and read it each frame: `Firefly.Lights.set_color/1` then
  recolors the animation as it plays, rather than restarting it.
  """

  alias Firefly.Lights.Frame

  @type state :: term()
  @type delay :: pos_integer() | :infinity

  @callback init(opts :: keyword()) :: state()
  @callback next_frame(state()) :: {Frame.t(), delay(), state()}
end
