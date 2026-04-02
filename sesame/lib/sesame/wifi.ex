defmodule Sesame.Wifi do
  @nvs_namespace :sesame
  @nvs_ssid :wifi_ssid
  @nvs_psk :wifi_psk

  def start_link do
    :gen_server.start_link({:local, :wifi}, __MODULE__, [], [])
  end

  def scan do
    :gen_server.call(:wifi, :scan, 60_000)
  end

  def connect(ssid, psk) do
    :gen_server.call(:wifi, {:connect, ssid, psk}, 30_000)
  end

  def init([]) do
    case load_credentials() do
      {ssid, psk} ->
        :io.format(~c"[WiFi] saved credentials found for ~s, auto-connecting\n", [ssid])
        # Schedule BLE shutdown — C5 coex can't handle WiFi auth + BLE
        :erlang.send_after(3000, self(), {:shutdown_ble_and_connect, ssid, psk})
        init_wifi_driver()

      nil ->
        init_wifi_driver()
        :io.format(~c"[WiFi] no saved credentials, use BLE to connect\n")
    end

    {:ok, %{}}
  end

  def handle_call(:scan, _from, state) do
    result = :wifi_scan_nif.scan()
    {:reply, result, state}
  end

  def handle_call({:connect, ssid, psk}, _from, state) do
    :io.format(~c"[WiFi] connecting to ~s...\n", [ssid])
    :network.stop()
    :timer.sleep(500)
    result = start_network(ssid, psk)

    case result do
      :ok ->
        save_credentials(ssid, psk)
        :io.format(~c"[WiFi] credentials saved for ~s\n", [ssid])

      _ ->
        :ok
    end

    {:reply, result, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  def handle_info({:shutdown_ble_and_connect, ssid, psk}, state) do
    :io.format(~c"[WiFi] shutting down BLE for coex, then connecting...\n")
    try do
      send(:ble, :shutdown)
    catch
      _, _ -> :ok
    end
    :timer.sleep(1000)
    # Stop the idle WiFi driver before starting with credentials
    try do
      :network.stop()
      :timer.sleep(500)
    catch
      _, _ -> :ok
    end
    start_network(ssid, psk)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- NVS persistence ---

  defp save_credentials(ssid, psk) do
    :esp.nvs_set_binary(@nvs_namespace, @nvs_ssid, ssid)
    :esp.nvs_set_binary(@nvs_namespace, @nvs_psk, psk)
  end

  defp load_credentials do
    try do
      case :esp.nvs_get_binary(@nvs_namespace, @nvs_ssid) do
        ssid when is_binary(ssid) and ssid != <<>> ->
          psk = :esp.nvs_get_binary(@nvs_namespace, @nvs_psk)
          psk = if is_binary(psk), do: psk, else: <<>>
          {ssid, psk}

        _ ->
          nil
      end
    catch
      _, _ -> nil
    end
  end

  # --- Network ---

  defp init_wifi_driver do
    config = [
      sta: [
        ssid: "",
        psk: ""
      ]
    ]

    case :network.start(config) do
      {:ok, _pid} ->
        :io.format(~c"[WiFi] driver initialized\n")

      {:error, reason} ->
        :io.format(~c"[WiFi] driver init failed: ~p\n", [reason])
    end
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
          send(:ble, :shutdown)
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
          send(:hub_sup, :sntp_synced)
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
