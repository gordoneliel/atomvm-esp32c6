defmodule Firefly.Lights.Server do
  @moduledoc """
  Runs the current animation on the LED matrix: asks it for each frame, draws
  the frame and schedules the next one. Use the `Firefly.Lights` API rather
  than calling this process directly.
  """

  alias Firefly.Lights
  alias Firefly.Lights.{Color, Frame, Strip}

  @default_brightness 64

  def start_link(name) do
    :gen_server.start_link({:local, :lights}, __MODULE__, name, [])
  end

  # --- GenServer callbacks ---

  def init(name) do
    case Strip.init() do
      :ok ->
        :io.format(~c"[Lights] matrix ready\n")
        state = %{brightness: @default_brightness, power: true, color: nil, frame: nil}
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
    if state.power and state.frame, do: Strip.show(state.frame, state.brightness)
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

    if state.power, do: render(state), else: blank(state)
  end

  # Starts the current animation again, e.g. after power or color changes
  defp restart(%{playing: {module, opts}} = state), do: start(state, state.name, module, opts)

  defp blank(state) do
    Strip.show(Frame.fill(Color.black()), 0)
    state
  end

  defp render(%{animation: {module, anim_state}} = state) do
    {frame, delay, anim_state} = module.next_frame(anim_state)
    Strip.show(frame, state.brightness)
    schedule(delay, state.tick)
    %{state | animation: {module, anim_state}, frame: frame}
  end

  defp schedule(:infinity, _ref), do: :ok
  defp schedule(delay, ref), do: :erlang.send_after(delay, self(), {:tick, ref})
end
