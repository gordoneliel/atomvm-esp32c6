defmodule Firefly.Matter.LightControl do
  @moduledoc """
  Maps attribute writes on the Matter light endpoint (the LED matrix, an
  Extended Color Light) to `Firefly.Lights` actions.

  Pure: returns the action and the updated hue/saturation, which arrive as
  separate attribute writes and are combined into one color.
  """

  alias Firefly.Lights.Color

  @on_off 0x0006
  @level_control 0x0008
  @color_control 0x0300

  @on_off_attr 0x0000
  @current_level 0x0000
  @current_hue 0x0000
  @current_saturation 0x0001
  @color_temperature 0x0007

  @type hue_saturation :: {hue :: 0..254, saturation :: 0..254}
  @type action ::
          {:power, boolean()} | {:brightness, 0..255} | {:color, Color.t()} | :ignore

  @doc "Hue and saturation before any write (white)."
  def initial, do: {0, 0}

  @doc "The action for a write of `value` to `cluster`/`attribute`."
  @spec handle_write(integer(), integer(), integer(), hue_saturation()) ::
          {action(), hue_saturation()}
  def handle_write(@on_off, @on_off_attr, value, hs), do: {{:power, value != 0}, hs}

  # Matter levels run 1..254
  def handle_write(@level_control, @current_level, level, hs),
    do: {{:brightness, div(level * 255, 254)}, hs}

  def handle_write(@color_control, @current_hue, hue, {_hue, saturation}),
    do: color({hue, saturation})

  def handle_write(@color_control, @current_saturation, saturation, {hue, _saturation}),
    do: color({hue, saturation})

  def handle_write(@color_control, @color_temperature, mireds, hs),
    do: {{:color, Color.from_mireds(mireds)}, hs}

  def handle_write(_cluster, _attribute, _value, hs), do: {:ignore, hs}

  defp color({hue, saturation} = hs),
    do: {{:color, Color.from_hue_saturation(hue, saturation)}, hs}
end
