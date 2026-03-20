defmodule Sesame.Led do
  @led_pin 15

  def start_link do
    pid = spawn_link(__MODULE__, :init, [])
    :erlang.register(:led, pid)
    {:ok, pid}
  end

  def init do
    :gpio.set_pin_mode(@led_pin, :output)
    :io.format(~c"[Led] GPIO ~p, blinking until WiFi\n", [@led_pin])
    blink_loop()
  end

  # Blink until we get :wifi_connected
  defp blink_loop do
    :gpio.digital_write(@led_pin, :high)

    receive do
      :wifi_connected -> solid_on()
    after
      500 -> :ok
    end

    :gpio.digital_write(@led_pin, :low)

    receive do
      :wifi_connected -> solid_on()
    after
      500 -> :ok
    end

    blink_loop()
  end

  # Solid on, wait for disconnect
  defp solid_on do
    :io.format(~c"[Led] WiFi connected, LED solid\n")
    :gpio.digital_write(@led_pin, :low)
    solid_loop()
  end

  defp solid_loop do
    receive do
      :wifi_disconnected ->
        :io.format(~c"[Led] WiFi lost, blinking\n")
        blink_loop()
    after
      2000 -> solid_loop()
    end
  end
end
