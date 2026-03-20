defmodule Sesame.Wifi do
  @ssid "REDACTED_SSID"
  @psk "REDACTED_PSK"
  # @ssid "REDACTED_SSID"
  # @psk "REDACTED_PSK"

  def start_link do
    :gen_server.start_link({:local, :wifi}, __MODULE__, [], [])
  end

  def scan do
    :gen_server.call(:wifi, :scan, 15_000)
  end

  def connect(ssid, psk) do
    :gen_server.call(:wifi, {:connect, ssid, psk}, 30_000)
  end

  def init([]) do
    start_network(@ssid, @psk)
    {:ok, %{}}
  end

  def handle_call(:scan, _from, state) do
    result = :wifi_scan_nif.scan()
    {:reply, result, state}
  end

  def handle_call({:connect, ssid, psk}, _from, state) do
    :io.format(~c"[WiFi] reconnecting to ~s...\n", [ssid])
    :network.stop()
    :timer.sleep(500)
    result = start_network(ssid, psk)
    {:reply, result, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp start_network(ssid, psk) do
    :io.format(~c"Connecting to WiFi (~s)...\n", [ssid])

    config = [
      sta: [
        ssid: ssid,
        psk: psk,
        dhcp_hostname: "sesame",
        connected: fn ->
          :io.format(~c"WiFi connected\n")
          send(:led, :wifi_connected)
        end,
        got_ip: fn {addr, _, _} ->
          :io.format(~c"Got IP: ~p\n", [addr])
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
        :ok

      {:error, reason} ->
        :io.format(~c"Network start failed: ~p\n", [reason])
        {:error, reason}
    end
  end
end
