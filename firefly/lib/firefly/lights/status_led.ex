defmodule Firefly.Lights.StatusLed do
  @moduledoc """
  The single status LED on GPIO15 (active-low): `:blink`, `:on` or `:off`.
  Use `Firefly.Lights.status_led/1` rather than calling this process directly.
  """

  @pin 15
  @blink_interval 500

  def start_link(mode) do
    :gen_server.start_link({:local, :status_led}, __MODULE__, mode, [])
  end

  # --- GenServer callbacks ---

  def init(mode) do
    :gpio.set_pin_mode(@pin, :output)
    :io.format(~c"[StatusLed] GPIO ~p, ~p\n", [@pin, mode])
    {:ok, set_mode(%{mode: nil, lit: false, tick: nil}, mode)}
  end

  def handle_cast({:mode, mode}, state) do
    {:noreply, set_mode(state, mode)}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  def handle_info({:toggle, ref}, %{mode: :blink, tick: ref} = state) do
    {:noreply, blink(%{state | lit: not state.lit})}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Modes ---

  defp set_mode(state, :blink),
    do: blink(%{state | mode: :blink, lit: true, tick: :erlang.make_ref()})

  defp set_mode(state, :on), do: write(%{state | mode: :on, lit: true, tick: nil})
  defp set_mode(state, :off), do: write(%{state | mode: :off, lit: false, tick: nil})

  defp blink(state) do
    :erlang.send_after(@blink_interval, self(), {:toggle, state.tick})
    write(state)
  end

  defp write(state) do
    :gpio.digital_write(@pin, if(state.lit, do: :low, else: :high))
    state
  end
end
