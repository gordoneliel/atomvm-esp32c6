defmodule Wifi do
  # @ssid "REDACTED_SSID"
  # @psk "REDACTED_PSK"
  @ssid "REDACTED_SSID"
  @psk  "REDACTED_PSK"

  def start_link do
    pid = spawn_link(__MODULE__, :init, [])
    {:ok, pid}
  end

  def init do
    # Note: external antenna switch (GPIO3/14) disabled — GPIO3 is used by radar UART TX
    :io.format(~c"Connecting to WiFi (~s)...\n", [@ssid])

    config = [
      sta: [
        ssid: @ssid,
        psk: @psk,
        dhcp_hostname: "sesame",
        connected: fn ->
          :io.format(~c"WiFi connected\n")
          send(:led, :wifi_connected)
        end,
        got_ip: fn {addr, _, _} ->
          :io.format(~c"Got IP: ~p\n", [addr])
          send(:dist, {:got_ip, addr})
        end,
        disconnected: fn ->
          :io.format(~c"WiFi disconnected\n")
          send(:led, :wifi_disconnected)
        end
      ],
      mdns: [
        hostname: "sesame"
      ],
      sntp: [
        host: "pool.ntp.org",
        synchronized: fn {s, _us} ->
          :io.format(~c"SNTP synchronized: ~p\n", [s])
        end
      ]
    ]

    case :network.start(config) do
      {:ok, _pid} ->
        :io.format(~c"Network started, waiting for IP...\n")

      {:error, reason} ->
        :io.format(~c"Network start failed: ~p\n", [reason])
    end

    # Keep process alive to maintain callbacks
    idle_loop()
  end

  defp idle_loop do
    :timer.sleep(60000)
    idle_loop()
  end
end
