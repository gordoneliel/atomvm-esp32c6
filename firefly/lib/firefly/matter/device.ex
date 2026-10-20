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
  """

  alias Firefly.Lights
  alias Firefly.Matter.LightControl

  # Matter device identity (test VID/PID — replace with certified IDs)
  @vendor_id 0xFFF1
  @vendor_name "Firefly"
  @product_id 0x8001
  @product_name "Firefly Sensor"
  @node_label "Firefly Sensor"
  @hardware_version 1
  @software_version 1

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

  def init([]) do
    :io.format(~c"[Matter] initializing device stack\n")

    config = [
      node_label: @node_label,
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
        endpoints = setup_endpoints()

        case :matter_nif.start() do
          :ok ->
            :io.format(~c"[Matter] started\n")
            sync_lights(endpoints)
            print_setup_codes()

          {:error, reason} ->
            :io.format(~c"[Matter] start failed: ~p\n", [reason])
        end

        {:ok,
         Map.merge(endpoints, %{
           commissioned: false,
           fabric_id: nil,
           occupancy: false,
           hue_saturation: LightControl.initial()
         })}

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
    {:reply, :ok, %{state | commissioned: false, fabric_id: nil}}
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

    {:noreply, %{state | commissioned: true, fabric_id: fabric_id}}
  end

  def handle_info(:matter_decommissioned, state) do
    :io.format(~c"[Matter] device removed from fabric\n")
    {:noreply, %{state | commissioned: false, fabric_id: nil}}
  end

  # Attribute write from controller (also sent for our own updates)
  def handle_info({:matter_write, endpoint, cluster, attr, value}, state) do
    :io.format(~c"[Matter] write ep=~p cl=~p attr=~p val=~p\n", [endpoint, cluster, attr, value])
    {:noreply, handle_write(endpoint, cluster, attr, value, state)}
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
