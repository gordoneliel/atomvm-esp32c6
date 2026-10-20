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

  Endpoints:
    - 0: Root Node (mandatory, handled by SDK)
    - 1: Occupancy Sensor
    - 2: LED matrix, as an Extended Color Light: on/off, brightness and color
      (see `Firefly.Matter.LightControl`)
    - 3: "Next animation" switch: turning it on plays the next animation,
      then it turns itself back off

  Until the device is commissioned, the LED matrix scrolls its manual pairing
  code.
  """

  alias Firefly.Lights
  alias Firefly.Lights.Animations.Text
  alias Firefly.Matter.LightControl

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
  @occupancy_endpoint 1
  @occupancy_cluster_id 0x0406
  @occupancy_attr_id 0x0000
  @occupancy_sensor_type_attr_id 0x0001
  @sensor_type_ultrasonic 0x01

  @extended_color_light 0x010D
  @on_off_plug_in_unit 0x010A
  @on_off_cluster_id 0x0006
  @on_off_attr_id 0x0000
  @level_control_cluster_id 0x0008
  @current_level_attr_id 0x0000
  @initial_level 64

  # How long the "next animation" switch stays on in the Home app
  @next_switch_reset_ms 500

  def start_link do
    :gen_server.start_link({:local, :matter_device}, __MODULE__, [], [])
  end

  def set_occupancy(occupied?) do
    :gen_server.cast(:matter_device, {:set_occupancy, occupied?})
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

        {commissioned, setup_code} =
          case :matter_nif.start() do
            :ok ->
              :io.format(~c"[Matter] started\n")
              sync_lights(endpoints)
              {:matter_nif.commissioned(), setup_code()}

            {:error, reason} ->
              :io.format(~c"[Matter] start failed: ~p\n", [reason])
              {false, nil}
          end

        state =
          Map.merge(endpoints, %{
            commissioned: commissioned,
            fabric_id: nil,
            setup_code: setup_code,
            occupancy: false,
            hue_saturation: LightControl.initial(),
            # nil, or {callers, networks found so far} while scanning
            thread_scan: nil
          })

        :io.format(~c"[Matter] commissioned: ~p\n", [commissioned])
        if not commissioned, do: show_setup_code(state)

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
    :matter_nif.factory_reset()
    state = %{state | commissioned: false, fabric_id: nil}
    show_setup_code(state)
    {:reply, :ok, state}
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

  # Occupancy update
  def handle_cast({:set_occupancy, occupied?}, state) do
    value = if occupied?, do: 1, else: 0

    if state.commissioned do
      :matter_nif.set_attribute(
        @occupancy_endpoint,
        @occupancy_cluster_id,
        @occupancy_attr_id,
        value
      )

      :matter_nif.report(@occupancy_endpoint, @occupancy_cluster_id, @occupancy_attr_id)
    end

    {:noreply, %{state | occupancy: occupied?}}
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

    Lights.play(:idle)
    {:noreply, %{state | commissioned: true, fabric_id: fabric_id}}
  end

  def handle_info(:matter_decommissioned, state) do
    :io.format(~c"[Matter] device removed from fabric\n")
    state = %{state | commissioned: false, fabric_id: nil}
    show_setup_code(state)
    {:noreply, state}
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

  # --- Lights ---

  defp handle_write(endpoint, cluster, attr, value, %{light: endpoint} = state) do
    {action, hue_saturation} =
      LightControl.handle_write(cluster, attr, value, state.hue_saturation)

    case action do
      {:power, on?} -> Lights.set_power(on?)
      {:brightness, level} -> Lights.set_brightness(level)
      {:color, color} -> Lights.set_color(color)
      :ignore -> :ok
    end

    %{state | hue_saturation: hue_saturation}
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

  # Matter keeps attribute values across reboots, but the matrix always
  # starts on at the default brightness: make the Home app match it
  defp sync_lights(endpoints) do
    :matter_nif.set_attribute(endpoints.light, @on_off_cluster_id, @on_off_attr_id, true)

    :matter_nif.set_attribute(
      endpoints.light,
      @level_control_cluster_id,
      @current_level_attr_id,
      @initial_level
    )

    :matter_nif.set_attribute(endpoints.next_switch, @on_off_cluster_id, @on_off_attr_id, false)
  end

  # --- Endpoint setup ---

  defp setup_endpoints do
    :io.format(~c"[Matter] adding occupancy sensor endpoint\n")

    {:ok, @occupancy_endpoint} =
      :matter_nif.add_endpoint(@occupancy_endpoint, 0x0107, [
        {:cluster, @occupancy_cluster_id, :server,
         [
           {:attribute, @occupancy_attr_id, :u8, 0},
           {:attribute, @occupancy_sensor_type_attr_id, :u8, @sensor_type_ultrasonic}
         ]}
      ])

    :io.format(~c"[Matter] adding LED matrix light and next-animation switch endpoints\n")
    {:ok, light} = :matter_nif.add_endpoint(0, @extended_color_light, [])
    {:ok, next_switch} = :matter_nif.add_endpoint(0, @on_off_plug_in_unit, [])

    %{light: light, next_switch: next_switch}
  end

  defp handle_attribute_read(
         @occupancy_endpoint,
         @occupancy_cluster_id,
         @occupancy_attr_id,
         state
       ) do
    if state.occupancy, do: 1, else: 0
  end

  defp handle_attribute_read(
         @occupancy_endpoint,
         @occupancy_cluster_id,
         @occupancy_sensor_type_attr_id,
         _state
       ) do
    @sensor_type_ultrasonic
  end

  defp handle_attribute_read(_endpoint, _cluster, _attr, _state) do
    nil
  end

  # Prints the setup codes, returning the manual pairing code (nil if they
  # aren't available)
  defp setup_code do
    case :matter_nif.get_setup_codes() do
      {:ok, codes} ->
        qr = :proplists.get_value(:qr_code, codes, "")
        manual = :proplists.get_value(:manual_code, codes, "")
        :io.format(~c"[Matter] QR Code:      ~s\n", [qr])
        :io.format(~c"[Matter] Manual code:  ~s\n", [manual])
        if manual != "", do: manual

      {:error, reason} ->
        :io.format(~c"[Matter] Failed to get setup codes: ~p\n", [reason])
        nil
    end
  end

  defp show_setup_code(%{setup_code: nil}), do: :ok
  defp show_setup_code(%{setup_code: code}), do: Lights.play(Text, text: format_code(code))

  # 11-digit manual codes read more easily grouped as the Home app shows
  # them, with spaces as they're narrower than dashes: 1234 567 8901
  defp format_code(<<a::binary-size(4), b::binary-size(3), c::binary-size(4)>>),
    do: <<a::binary, ?\s, b::binary, ?\s, c::binary>>

  defp format_code(code), do: code
end
