defmodule Firefly.Matter.Device do
  @moduledoc """
  Matter device manager (GenServer).

  Manages the Matter application stack lifecycle: initialization,
  commissioning, endpoint registration, and attribute reporting.

  Matter SDK handles all networking internally:
    - BLE commissioning (phone scans QR code → provisions Thread/WiFi creds)
    - Thread mesh networking (802.15.4 radio)
    - WiFi (fallback transport)

  NIF: :matter_nif (wraps esp_matter / connectedhomeip APIs)

  Endpoints (controllers such as Apple Home pick the accessory's kind from
  the first, so Firefly shows up as a light):
    - 0: Root Node (mandatory, handled by SDK)
    - 1: LED matrix, as an Extended Color Light: on/off, brightness and color
      (see `Firefly.Matter.LightControl`)
    - 2: "Next animation" switch: turning it on plays the next animation,
      then it turns itself back off
  """

  alias Firefly.Lights
  alias Firefly.Matter.{LightControl, Status}

  # Matter device identity (test VID/PID — replace with certified IDs)
  @vendor_id 0xFFF1
  @vendor_name "Firefly"
  @product_id 0x8001
  @product_name "Firefly Sensor"
  @hardware_version 1
  @software_version 1

  # The radio's antenna, see :matter_nif.set_antenna/1: Seeed's 2.4 GHz
  # antenna on the XIAO's U.FL connector. (The built-in ceramic antenna,
  # :internal, hears next to no Thread traffic in the enclosure.)
  @antenna :external

  # Endpoint / cluster constants
  @extended_color_light 0x010D
  @on_off_plug_in_unit 0x010A
  @on_off_cluster_id 0x0006
  @on_off_attr_id 0x0000

  # How long the "next animation" switch stays on in the Home app
  @next_switch_reset_ms 500

  # How often to check the device's state for the matrix (see Status)
  @status_check_ms 3_000

  def start_link do
    :gen_server.start_link({:local, :matter_device}, __MODULE__, [], [])
  end

  def get_status do
    :gen_server.call(:matter_device, :get_status)
  end

  def open_commissioning_window(timeout \\ 900) do
    :gen_server.call(:matter_device, {:open_commissioning_window, timeout})
  end

  def factory_reset do
    :gen_server.call(:matter_device, :factory_reset)
  end

  @doc """
  Scans every channel for Thread networks in range, without joining any.
  Returns `{:ok, networks}`, each a map of `:name`, `:ext_pan_id` (hex),
  `:pan_id`, `:channel` and `:rssi` (dBm), also printed to the console.
  """
  def thread_scan do
    :gen_server.call(:matter_device, :thread_scan, 30_000)
  end

  def init([]) do
    :io.format(~c"[Matter] initializing device stack\n")

    config = [
      vendor_id: @vendor_id,
      vendor_name: @vendor_name,
      product_id: @product_id,
      product_name: @product_name,
      hardware_version: @hardware_version,
      software_version: @software_version
    ]

    case :matter_nif.init(config) do
      :ok ->
        :io.format(~c"[Matter] stack initialized\n")
        :matter_nif.set_antenna(@antenna)
        endpoints = setup_endpoints()

        color_set = color_set?()

        {commissioned, color_state} =
          case :matter_nif.start() do
            :ok ->
              :io.format(~c"[Matter] started\n")
              color_state = restore_lights(endpoints, color_set)
              print_setup_codes()
              {:matter_nif.commissioned(), color_state}

            {:error, reason} ->
              :io.format(~c"[Matter] start failed: ~p\n", [reason])
              {false, LightControl.initial()}
          end

        state =
          Map.merge(endpoints, %{
            commissioned: commissioned,
            fabric_id: nil,
            color_state: color_state,
            # Whether a controller has ever set the light's color, see
            # restore_lights/2
            color_set: color_set,
            # nil, or {callers, networks found so far} while scanning
            thread_scan: nil,
            # The status the matrix shows, and since when the Thread
            # connection has been down (see Status)
            status: nil,
            down_since: nil
          })

        :io.format(~c"[Matter] commissioned: ~p\n", [commissioned])
        :erlang.send_after(@status_check_ms, self(), :check_status)
        state = update_status(state)
        {:ok, state}

      {:error, reason} ->
        :io.format(~c"[Matter] init failed: ~p\n", [reason])
        {:stop, reason}
    end
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:open_commissioning_window, timeout}, _from, state) do
    :io.format(~c"[Matter] opening commissioning window (~p seconds)\n", [timeout])
    result = :matter_nif.open_commissioning_window(timeout)
    {:reply, result, state}
  end

  def handle_call(:factory_reset, _from, state) do
    :io.format(~c"[Matter] factory reset — erasing all credentials\n")
    state = forget_color(state)
    :matter_nif.factory_reset()
    {:reply, :ok, update_status(%{state | commissioned: false, fabric_id: nil})}
  end

  def handle_call(:thread_scan, from, state) do
    case start_thread_scan(state, from) do
      {:error, reason} -> {:reply, {:error, reason}, state}
      state -> {:noreply, state}
    end
  end

  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  # Matter SDK callbacks
  def handle_info(:matter_commissioned, state) do
    :io.format(~c"[Matter] device commissioned!\n")

    fabric_id =
      case :matter_nif.get_fabric_info() do
        {:ok, info} ->
          :io.format(~c"[Matter] fabric: ~p\n", [info[:fabric_id]])
          info[:fabric_id]

        _ ->
          nil
      end

    {:noreply, update_status(%{state | commissioned: true, fabric_id: fabric_id})}
  end

  def handle_info(:matter_decommissioned, state) do
    :io.format(~c"[Matter] device removed from fabric\n")
    {:noreply, update_status(%{forget_color(state) | commissioned: false, fabric_id: nil})}
  end

  # Attribute write from controller (also sent for our own updates)
  def handle_info({:matter_write, endpoint, cluster, attr, value}, state) do
    :io.format(~c"[Matter] write ep=~p cl=~p attr=~p val=~p\n", [endpoint, cluster, attr, value])
    {:noreply, handle_write(endpoint, cluster, attr, value, state)}
  end

  def handle_info(
        {:thread_network, name, ext_pan_id, pan_id, channel, rssi},
        %{thread_scan: {callers, networks}} = state
      ) do
    network = %{
      name: name,
      ext_pan_id: Base.encode16(ext_pan_id),
      pan_id: pan_id,
      channel: channel,
      rssi: rssi
    }

    {:noreply, %{state | thread_scan: {callers, [network | networks]}}}
  end

  def handle_info(:thread_scan_done, %{thread_scan: {callers, networks}} = state) do
    networks = :lists.reverse(networks)
    :io.format(~c"[Matter] Thread scan found ~p network(s)\n", [length(networks)])

    for network <- networks do
      :io.format(~c"[Matter]   ~s  ext_pan_id=~s pan_id=0x~.16B channel=~p rssi=~p dBm\n", [
        network.name,
        network.ext_pan_id,
        network.pan_id,
        network.channel,
        network.rssi
      ])
    end

    for caller <- callers, do: :gen_server.reply(caller, {:ok, networks})
    {:noreply, %{state | thread_scan: nil}}
  end

  # Identify on the light: blink the matrix while the controller's
  # IdentifyTime runs, or for a moment for a one-off effect
  def handle_info({:matter_identify, endpoint, type, effect}, %{light: endpoint} = state) do
    case type do
      :start -> Lights.identify(true)
      :stop -> Lights.identify(false)
      :effect -> identify_effect(effect)
    end

    {:noreply, state}
  end

  def handle_info({:matter_identify, _endpoint, _type, _effect}, state) do
    {:noreply, state}
  end

  def handle_info(:check_status, state) do
    :erlang.send_after(@status_check_ms, self(), :check_status)
    {:noreply, update_status(state)}
  end

  def handle_info(:reset_next_switch, state) do
    :matter_nif.set_attribute(state.next_switch, @on_off_cluster_id, @on_off_attr_id, false)
    {:noreply, state}
  end

  # Attribute read from controller
  def handle_info({:matter_read, endpoint, cluster, attr}, state) do
    value = handle_attribute_read(endpoint, cluster, attr, state)
    :matter_nif.respond_read(endpoint, cluster, attr, value)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Thread scan ---

  # Starts a scan, or joins the one in progress. `caller` is nil for a scan
  # that only prints its results. Returns the state, or {:error, reason} if
  # the scan couldn't start.
  defp start_thread_scan(%{thread_scan: {callers, networks}} = state, caller),
    do: %{state | thread_scan: {add_caller(callers, caller), networks}}

  defp start_thread_scan(state, caller) do
    case :matter_nif.thread_scan() do
      :ok ->
        :io.format(~c"[Matter] scanning for Thread networks\n")
        %{state | thread_scan: {add_caller([], caller), []}}

      {:error, reason} ->
        :io.format(~c"[Matter] Thread scan failed: ~p\n", [reason])
        if caller, do: {:error, reason}, else: state
    end
  end

  defp add_caller(callers, nil), do: callers
  defp add_caller(callers, caller), do: [caller | callers]

  # --- Device state on the matrix ---

  # Shows the device's state on the matrix as a Lights status: waiting to be
  # commissioned, or commissioned but offline; nothing while connected, when
  # Matter drives the light. Lights hears only of changes, so a status the
  # button has dismissed stays dismissed until the state changes again.
  defp update_status(state) do
    connected = state.commissioned and Status.connected?(:matter_nif.thread_status())
    now = :erlang.monotonic_time(:millisecond)
    {status, down_since} = Status.status(state.commissioned, connected, state.down_since, now)

    if status != state.status do
      :io.format(~c"[Matter] status: ~p\n", [status])
      Lights.set_status(status)
    end

    %{state | status: status, down_since: down_since}
  end

  # --- Lights ---

  defp handle_write(endpoint, cluster, attr, value, %{light: endpoint} = state) do
    {action, color_state} = LightControl.handle_write(cluster, attr, value, state.color_state)
    apply_light_action(action)
    state = %{state | color_state: color_state}

    case action do
      {:color, _color} -> remember_color(state)
      _ -> state
    end
  end

  defp handle_write(
         endpoint,
         @on_off_cluster_id,
         @on_off_attr_id,
         1,
         %{next_switch: endpoint} = state
       ) do
    Lights.cycle()
    :erlang.send_after(@next_switch_reset_ms, self(), :reset_next_switch)
    state
  end

  defp handle_write(_endpoint, _cluster, _attr, _value, state), do: state

  defp apply_light_action({:power, on?}), do: Lights.set_power(on?)
  defp apply_light_action({:brightness, level}), do: Lights.set_brightness(level)
  defp apply_light_action({:color, color}), do: Lights.set_color(color)
  defp apply_light_action(:ignore), do: :ok

  # Brings the lights to the light endpoint's state as Matter restored it
  # (per its StartUp* attributes: by default, as it was), and turns the
  # next-animation switch off. The color is restored only once a controller
  # has set one: a new device's color attributes are just Matter's defaults,
  # and the animations keep their own colors. Returns the color state.
  defp restore_lights(endpoints, color_set) do
    drop_startup_writes()

    values =
      :maps.from_list(
        for {key, cluster, attr} <- LightControl.attributes(),
            {:ok, value} <- [:matter_nif.get_attribute(endpoints.light, cluster, attr)],
            do: {key, value}
      )

    {actions, color_state} = LightControl.restore(values, color_set)
    :io.format(~c"[Matter] restoring light: ~p\n", [actions])
    for action <- actions, do: apply_light_action(action)

    :matter_nif.set_attribute(endpoints.next_switch, @on_off_cluster_id, @on_off_attr_id, false)
    color_state
  end

  # While starting, the SDK writes the attributes it restores, which arrive
  # as {:matter_write, ...}: restore_lights/2 applies the restored state as a
  # whole instead
  defp drop_startup_writes do
    receive do
      {:matter_write, _endpoint, _cluster, _attr, _value} -> drop_startup_writes()
    after
      0 -> :ok
    end
  end

  defp color_set?, do: :esp.nvs_get_binary(:firefly, :color_set, "") == "1"

  defp remember_color(%{color_set: true} = state), do: state

  defp remember_color(state) do
    :esp.nvs_set_binary(:firefly, :color_set, "1")
    %{state | color_set: true}
  end

  # Back to the animations' own colors, as on a new device
  defp forget_color(state) do
    :esp.nvs_erase_key(:firefly, :color_set)
    Lights.set_color(nil)
    %{state | color_set: false}
  end

  # Matter's identify effects: blink, breathe, okay and channel change, then
  # finish (end after the current one) and stop (end now)
  defp identify_effect(0x00), do: Lights.identify(1_000)
  defp identify_effect(0x01), do: Lights.identify(15_000)
  defp identify_effect(0x02), do: Lights.identify(2_000)
  defp identify_effect(0x0B), do: Lights.identify(8_000)
  defp identify_effect(_finish_or_stop), do: Lights.identify(false)

  # --- Endpoint setup ---

  # The light first: it's the accessory's main endpoint
  defp setup_endpoints do
    :io.format(~c"[Matter] adding LED matrix light and next-animation switch endpoints\n")
    {:ok, light} = :matter_nif.add_endpoint(0, @extended_color_light, [])
    {:ok, next_switch} = :matter_nif.add_endpoint(0, @on_off_plug_in_unit, [])

    %{light: light, next_switch: next_switch}
  end

  # No attributes are served from Elixir: the SDK holds them all
  defp handle_attribute_read(_endpoint, _cluster, _attr, _state) do
    nil
  end

  defp print_setup_codes do
    case :matter_nif.get_setup_codes() do
      {:ok, codes} ->
        qr = :proplists.get_value(:qr_code, codes, "")
        manual = :proplists.get_value(:manual_code, codes, "")
        :io.format(~c"[Matter] QR Code:      ~s\n", [qr])
        :io.format(~c"[Matter] Manual code:  ~s\n", [manual])

      {:error, reason} ->
        :io.format(~c"[Matter] Failed to get setup codes: ~p\n", [reason])
    end
  end
end
