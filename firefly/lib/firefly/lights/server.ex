defmodule Firefly.Lights.Server do
  @moduledoc """
  Runs the current animation on the LED matrix: asks it for each frame, draws
  the frame and schedules the next one. Use the `Firefly.Lights` API rather
  than calling this process directly.

  Switching animations dips through black: the matrix fades out, then the
  new animation fades in. Turning the power off fades out and stays dark.
  Fading only changes the brightness frames are drawn at, so it costs no more
  than drawing them.
  """

  alias Firefly.Lights
  alias Firefly.Lights.Strip

  @default_brightness 64

  # Fading out or in takes @fade_steps steps of @fade_interval ms
  @fade_steps 6
  @fade_interval 25

  def start_link(name) do
    :gen_server.start_link({:local, :lights}, __MODULE__, name, [])
  end

  # --- GenServer callbacks ---

  def init(name) do
    case Strip.init() do
      :ok ->
        :io.format(~c"[Lights] matrix ready\n")
        # `frame` is the frame on the matrix, drawn at `level` (0..@fade_steps)
        # of the brightness. `fade` is :out, :in or nil.
        state = %{
          brightness: @default_brightness,
          power: true,
          color: nil,
          frame: nil,
          level: 0,
          fade: nil
        }

        {:ok, start_named(state, name)}

      {:error, reason} ->
        :io.format(~c"[Lights] matrix init failed: ~p\n", [reason])
        {:stop, reason}
    end
  end

  def handle_cast({:play, name}, state) do
    {:noreply, start_named(state, name)}
  end

  def handle_cast({:play, animation, opts}, state) do
    {:noreply, start(state, nil, animation, opts)}
  end

  def handle_cast(:cycle, state) do
    {:noreply, start_named(state, Lights.next(state.name))}
  end

  def handle_cast({:power, on?}, state) do
    {:noreply, restart(%{state | power: on?})}
  end

  def handle_cast({:color, color}, state) do
    {:noreply, restart(%{state | color: color})}
  end

  def handle_cast({:brightness, level}, state) do
    state = %{state | brightness: min(255, max(0, level))}
    state = if state.power and state.frame, do: draw(state, state.frame), else: state
    {:noreply, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  # Ticks carry the ref of the animation that scheduled them, so a tick
  # already queued when a new animation starts is dropped
  def handle_info({:tick, ref}, %{tick: ref} = state) do
    {:noreply, render(state)}
  end

  def handle_info({:fade, ref}, %{tick: ref, fade: :out} = state) do
    state = draw(%{state | level: state.level - 1}, state.frame)

    cond do
      state.level > 0 -> {:noreply, fade(state, :out)}
      state.power -> {:noreply, state |> fade(:in) |> render()}
      true -> {:noreply, %{state | fade: nil}}
    end
  end

  def handle_info({:fade, ref}, %{tick: ref, fade: :in} = state) do
    state = draw(%{state | level: state.level + 1}, state.frame)

    if state.level < @fade_steps,
      do: {:noreply, fade(state, :in)},
      else: {:noreply, %{state | fade: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Animation loop ---

  defp start_named(state, name) do
    {module, opts} = Lights.animation(name)
    start(state, name, module, opts)
  end

  # `name` is the named animation being played, or nil for an animation module.
  # A color set with `Lights.set_color/1` replaces the animation's own.
  defp start(state, name, module, opts) do
    animation_opts = if state.color, do: Keyword.put(opts, :color, state.color), else: opts

    state =
      state
      |> Map.put(:name, name)
      |> Map.put(:playing, {module, opts})
      |> Map.put(:animation, {module, module.init(animation_opts)})
      |> Map.put(:tick, :erlang.make_ref())

    # Fade out whatever is showing (mid-fade, from its current level), then
    # the new animation starts as it fades in
    cond do
      state.level > 0 -> fade(state, :out)
      state.power -> state |> fade(:in) |> render()
      true -> %{state | fade: nil}
    end
  end

  # Starts the current animation again, e.g. after power or color changes
  defp restart(%{playing: {module, opts}} = state), do: start(state, state.name, module, opts)

  # Moves the animation on a frame and schedules the next one
  defp render(%{animation: {module, anim_state}} = state) do
    {frame, delay, anim_state} = module.next_frame(anim_state)
    schedule(delay, {:tick, state.tick})
    draw(%{state | animation: {module, anim_state}}, frame)
  end

  # Schedules the next step of fading `direction` (:out or :in)
  defp fade(state, direction) do
    schedule(@fade_interval, {:fade, state.tick})
    %{state | fade: direction}
  end

  defp draw(state, frame) do
    Strip.show(frame, div(state.brightness * state.level, @fade_steps))
    %{state | frame: frame}
  end

  defp schedule(:infinity, _msg), do: :ok
  defp schedule(delay, msg), do: :erlang.send_after(delay, self(), msg)
end
