defmodule Firefly.Lights.Server do
  @moduledoc """
  Runs the current animation on the LED matrix: asks it for each frame, draws
  the frame and schedules the next one. Use the `Firefly.Lights` API rather
  than calling this process directly.

  Switching animations dips through black: the matrix fades out, then the
  new animation fades in. Turning the power off fades out and stays dark.
  Fading only changes the brightness frames are drawn at, so it costs no more
  than drawing them.

  Color changes recolor the running animation rather than restarting it, so
  a controller stepping through a color transition doesn't interrupt it.

  A status animation shows over the one playing, and identifying over both;
  each carries on after.
  """

  alias Firefly.Lights
  alias Firefly.Lights.Animations.Blink
  alias Firefly.Lights.Strip

  @default_brightness 64

  # The identify animation, drawn at least at the default brightness
  @identify {Blink, [color: {255, 255, 255}, interval: 250]}

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
        # of the brightness. `fade` is :out, :in or nil. `still` is whether
        # the animation's last frame is a still one. `status` is nil, or the
        # name of the status animation shown over `playing`. `identify` is
        # nil, or a ref while identifying (over both).
        state = %{
          brightness: @default_brightness,
          power: true,
          color: nil,
          frame: nil,
          level: 0,
          fade: nil,
          still: false,
          status: nil,
          identify: nil
        }

        {:ok, start_named(state, name)}

      {:error, reason} ->
        :io.format(~c"[Lights] matrix init failed: ~p\n", [reason])
        {:stop, reason}
    end
  end

  # Playing an animation dismisses the status
  def handle_cast({:play, name}, state) do
    {:noreply, start_named(%{state | status: nil}, name)}
  end

  def handle_cast({:play, animation, opts}, state) do
    {:noreply, start(%{state | status: nil}, nil, animation, opts)}
  end

  def handle_cast(:cycle, state) do
    {:noreply, start_named(%{state | status: nil}, Lights.next(state.name))}
  end

  def handle_cast({:status, status}, %{status: status} = state), do: {:noreply, state}

  def handle_cast({:status, status}, state) do
    state = %{state | status: status}
    {:noreply, if(state.identify, do: state, else: restart(state))}
  end

  # While identifying, power and color changes wait for it to end
  def handle_cast({:power, on?}, state) do
    state = %{state | power: on?}
    {:noreply, if(state.identify, do: state, else: restart(state))}
  end

  def handle_cast({:color, color}, state) do
    state = %{state | color: color}

    cond do
      # The identify and status animations keep their own colors
      state.identify || state.status -> {:noreply, state}
      # Back to the animations' own colors
      color == nil -> {:noreply, restart(state)}
      true -> {:noreply, recolor(state, color)}
    end
  end

  def handle_cast({:brightness, level}, state) do
    state = %{state | brightness: min(255, max(0, latest_brightness(level)))}
    state = if visible?(state) and state.frame, do: draw(state, state.frame), else: state
    {:noreply, state}
  end

  def handle_cast({:identify, true}, state) do
    {:noreply, if(state.identify, do: state, else: start_identify(state))}
  end

  def handle_cast({:identify, false}, state) do
    {:noreply, if(state.identify, do: restart(state), else: state)}
  end

  def handle_cast({:identify, ms}, state) when is_integer(ms) do
    state = if state.identify, do: state, else: start_identify(state)
    :erlang.send_after(ms, self(), {:identify_end, state.identify})
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
      visible?(state) -> {:noreply, state |> fade(:in) |> render()}
      true -> {:noreply, %{state | fade: nil}}
    end
  end

  def handle_info({:fade, ref}, %{tick: ref, fade: :in} = state) do
    state = draw(%{state | level: state.level + 1}, state.frame)

    if state.level < @fade_steps,
      do: {:noreply, fade(state, :in)},
      else: {:noreply, %{state | fade: nil}}
  end

  # Identifying for a time is over (unless identifying started again since)
  def handle_info({:identify_end, ref}, %{identify: ref} = state) do
    {:noreply, restart(state)}
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
  # Shows the status over it if there is one. Ends identifying.
  defp start(state, name, module, opts) do
    state =
      state
      |> Map.put(:name, name)
      |> Map.put(:playing, {module, opts})
      |> Map.put(:identify, nil)

    case state.status do
      nil ->
        show(
          state,
          module,
          if(state.color, do: Keyword.put(opts, :color, state.color), else: opts)
        )

      status ->
        {status_module, status_opts} = Lights.animation(status)
        show(state, status_module, status_opts)
    end
  end

  # Starts the current animation again, e.g. after power or color changes
  defp restart(%{playing: {module, opts}} = state), do: start(state, state.name, module, opts)

  # Plays the identify animation over whatever is playing, keeping `name`
  # and `playing` to go back to
  defp start_identify(state) do
    {module, opts} = @identify
    show(%{state | identify: :erlang.make_ref()}, module, opts)
  end

  # Shows `module`: fades out whatever is showing (mid-fade, from its
  # current level), then the new animation starts as it fades in
  defp show(state, module, opts) do
    state =
      state
      |> Map.put(:animation, {module, module.init(opts)})
      |> Map.put(:tick, :erlang.make_ref())
      |> Map.put(:still, false)

    cond do
      state.level > 0 -> fade(state, :out)
      visible?(state) -> state |> fade(:in) |> render()
      true -> %{state | fade: nil}
    end
  end

  # A controller's brightness transition sends a step every few ms, faster
  # than the matrix can be drawn: skip to the latest one waiting
  defp latest_brightness(level) do
    receive do
      {:"$gen_cast", {:brightness, newer}} -> latest_brightness(newer)
    after
      0 -> level
    end
  end

  # Identifying shows even when the power is off
  defp visible?(state), do: state.power or state.identify != nil

  # Recolors the running animation in place. Animations keep their color in
  # their state's :color; one that doesn't (Plasma) is left as it is. A
  # still frame is redrawn now, a moving one picks the color up next frame.
  # (Not while fading out: the new animation hasn't started drawing yet.)
  defp recolor(%{animation: {module, %{color: _} = anim_state}} = state, color) do
    state = %{state | animation: {module, %{anim_state | color: color}}}

    if state.still and state.fade != :out and visible?(state),
      do: render(state),
      else: state
  end

  defp recolor(state, _color), do: state

  # Moves the animation on a frame and schedules the next one
  defp render(%{animation: {module, anim_state}} = state) do
    {frame, delay, anim_state} = module.next_frame(anim_state)
    schedule(delay, {:tick, state.tick})
    draw(%{state | animation: {module, anim_state}, still: delay == :infinity}, frame)
  end

  # Schedules the next step of fading `direction` (:out or :in)
  defp fade(state, direction) do
    schedule(@fade_interval, {:fade, state.tick})
    %{state | fade: direction}
  end

  defp draw(state, frame) do
    brightness =
      if state.identify, do: max(state.brightness, @default_brightness), else: state.brightness

    Strip.show(frame, div(brightness * state.level, @fade_steps))
    %{state | frame: frame}
  end

  defp schedule(:infinity, _msg), do: :ok
  defp schedule(delay, msg), do: :erlang.send_after(delay, self(), msg)
end
