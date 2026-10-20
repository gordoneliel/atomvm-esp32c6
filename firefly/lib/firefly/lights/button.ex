defmodule Firefly.Lights.Button do
  @moduledoc """
  The XIAO's BOOT button (GPIO9, active-low with an external pull-up):
  each press plays the next named animation, see `Firefly.Lights.cycle/0`.

  A falling edge is confirmed by reading the pin again after `@debounce` ms.
  While the button is held the pin is polled until release, so bounces and
  long presses count once.
  """

  @pin 9
  @debounce 30
  @release_poll 50

  def start_link do
    :gen_server.start_link({:local, :lights_button}, __MODULE__, [], [])
  end

  # --- GenServer callbacks ---

  def init([]) do
    gpio = :gpio.start()
    :gpio.set_direction(gpio, @pin, :input)
    :ok = :gpio.set_int(gpio, @pin, :falling)
    {:ok, %{armed: true, checking: false}}
  end

  def handle_info({:gpio_interrupt, @pin}, %{armed: true, checking: false} = state) do
    :erlang.send_after(@debounce, self(), :check)
    {:noreply, %{state | checking: true}}
  end

  def handle_info(:check, state) do
    case :gpio.digital_read(@pin) do
      :low ->
        if state.armed, do: Firefly.Lights.cycle()
        :erlang.send_after(@release_poll, self(), :check)
        {:noreply, %{state | armed: false}}

      _released ->
        {:noreply, %{state | armed: true, checking: false}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end
end
