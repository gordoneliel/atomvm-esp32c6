defmodule Firefly.Matter.LightControl do
  @moduledoc """
  Maps the Matter light endpoint (the LED matrix, an Extended Color Light) to
  `Firefly.Lights` actions: attribute writes as they come, and the light's
  whole state when the device starts (`restore/2`).

  Pure. Hue and saturation, and the XY color's x and y, arrive as separate
  attribute writes: the color state keeps the latest of each to combine them
  into one color.
  """

  alias Firefly.Lights.Color

  @on_off 0x0006
  @level_control 0x0008
  @color_control 0x0300

  @on_off_attr 0x0000
  @current_level 0x0000
  @current_hue 0x0000
  @current_saturation 0x0001
  @current_x 0x0003
  @current_y 0x0004
  @color_temperature 0x0007
  @color_mode 0x0008

  # ColorMode values
  @hue_saturation_mode 0
  @xy_mode 1
  @temperature_mode 2

  @type color_state :: %{hue: 0..254, saturation: 0..254, x: 0..65279, y: 0..65279}
  @type action ::
          {:power, boolean()} | {:brightness, 0..255} | {:color, Color.t()} | :ignore

  @doc "The color state before any write: Matter's defaults."
  def initial, do: %{hue: 0, saturation: 0, x: 24939, y: 24701}

  @doc "The attributes `restore/2` uses, as `{key, cluster, attribute}`."
  def attributes do
    [
      {:on_off, @on_off, @on_off_attr},
      {:level, @level_control, @current_level},
      {:color_mode, @color_control, @color_mode},
      {:hue, @color_control, @current_hue},
      {:saturation, @color_control, @current_saturation},
      {:x, @color_control, @current_x},
      {:y, @color_control, @current_y},
      {:mireds, @color_control, @color_temperature}
    ]
  end

  @doc """
  The actions that bring the lights to the light's state, from a map of
  `attributes/0` keys to values (missing ones are left alone), and the color
  state. The color is included only if `color?`: until a controller sets it,
  the color attributes are just Matter's defaults.
  """
  @spec restore(map(), boolean()) :: {[action()], color_state()}
  def restore(values, color?) do
    defaults = initial()

    color_state = %{
      hue: Map.get(values, :hue, defaults.hue),
      saturation: Map.get(values, :saturation, defaults.saturation),
      x: Map.get(values, :x, defaults.x),
      y: Map.get(values, :y, defaults.y)
    }

    power =
      case Map.fetch(values, :on_off) do
        {:ok, value} -> [{:power, value != 0}]
        :error -> []
      end

    # A null (255) or missing level leaves the brightness as it is
    brightness =
      case Map.get(values, :level) do
        level when is_integer(level) and level in 1..254 -> [{:brightness, brightness(level)}]
        _ -> []
      end

    color =
      case color? and mode_color(Map.get(values, :color_mode), color_state, values) do
        {_r, _g, _b} = rgb -> [{:color, rgb}]
        _ -> []
      end

    {power ++ brightness ++ color, color_state}
  end

  @doc "The action for a write of `value` to `cluster`/`attribute`."
  @spec handle_write(integer(), integer(), integer(), color_state()) ::
          {action(), color_state()}
  def handle_write(@on_off, @on_off_attr, value, cs), do: {{:power, value != 0}, cs}

  def handle_write(@level_control, @current_level, level, cs),
    do: {{:brightness, brightness(level)}, cs}

  def handle_write(@color_control, @current_hue, hue, cs),
    do: hue_saturation(%{cs | hue: hue})

  def handle_write(@color_control, @current_saturation, saturation, cs),
    do: hue_saturation(%{cs | saturation: saturation})

  def handle_write(@color_control, @current_x, x, cs), do: xy(%{cs | x: x})
  def handle_write(@color_control, @current_y, y, cs), do: xy(%{cs | y: y})

  def handle_write(@color_control, @color_temperature, mireds, cs),
    do: {{:color, Color.from_mireds(mireds)}, cs}

  def handle_write(_cluster, _attribute, _value, cs), do: {:ignore, cs}

  # Matter levels run 1..254
  defp brightness(level), do: div(level * 255, 254)

  defp hue_saturation(cs), do: {{:color, Color.from_hue_saturation(cs.hue, cs.saturation)}, cs}
  defp xy(cs), do: {{:color, Color.from_xy(cs.x, cs.y)}, cs}

  defp mode_color(@hue_saturation_mode, cs, _values),
    do: Color.from_hue_saturation(cs.hue, cs.saturation)

  defp mode_color(@xy_mode, cs, _values), do: Color.from_xy(cs.x, cs.y)

  defp mode_color(@temperature_mode, _cs, values) do
    case Map.get(values, :mireds) do
      mireds when is_integer(mireds) -> Color.from_mireds(mireds)
      _ -> nil
    end
  end

  defp mode_color(_mode, _cs, _values), do: nil
end
