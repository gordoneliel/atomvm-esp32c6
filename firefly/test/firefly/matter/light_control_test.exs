defmodule Firefly.Matter.LightControlTest do
  use ExUnit.Case, async: true

  alias Firefly.Lights.Color
  alias Firefly.Matter.LightControl

  test "hue and saturation on Matter's scale map around the color wheel" do
    assert Color.from_hue_saturation(0, 254) == {255, 0, 0}
    assert Color.from_hue_saturation(85, 254) == {0, 255, 2}
    assert Color.from_hue_saturation(169, 254) == {0, 3, 255}
    assert Color.from_hue_saturation(254, 254) == {255, 0, 0}
    # No saturation is white whatever the hue
    assert Color.from_hue_saturation(120, 0) == {255, 255, 255}
  end

  test "color temperatures map from cool to warm white" do
    assert Color.from_mireds(153) == {255, 249, 253}
    assert Color.from_mireds(500) == {255, 137, 14}
    assert Color.from_mireds(100) == {255, 249, 253}
    assert Color.from_mireds(600) == {255, 137, 14}

    {255, g, b} = Color.from_mireds(310)
    assert g in 169..209 and b in 87..163
  end

  test "xy chromaticities on Matter's scale map through sRGB" do
    # D65 white, then the sRGB primaries
    {r, g, b} = Color.from_xy(round(0.3127 * 65536), round(0.3290 * 65536))
    assert Enum.all?([r, g, b], &(&1 >= 250))

    assert {255, g, b} = Color.from_xy(round(0.64 * 65536), round(0.33 * 65536))
    assert g < 10 and b < 10

    assert {r, 255, b} = Color.from_xy(round(0.30 * 65536), round(0.60 * 65536))
    assert r < 10 and b < 10

    assert {r, g, 255} = Color.from_xy(round(0.15 * 65536), round(0.06 * 65536))
    assert r < 10 and g < 10

    assert Color.from_xy(1000, 0) == {255, 255, 255}
  end

  test "on/off and level writes become power and brightness" do
    cs = LightControl.initial()
    assert LightControl.handle_write(0x0006, 0x0000, 1, cs) == {{:power, true}, cs}
    assert LightControl.handle_write(0x0006, 0x0000, 0, cs) == {{:power, false}, cs}
    assert LightControl.handle_write(0x0008, 0x0000, 254, cs) == {{:brightness, 255}, cs}
    assert LightControl.handle_write(0x0008, 0x0000, 1, cs) == {{:brightness, 1}, cs}
  end

  test "hue and saturation writes combine into one color" do
    {{:color, _}, cs} = LightControl.handle_write(0x0300, 0x0000, 85, LightControl.initial())
    assert cs.hue == 85

    {{:color, color}, cs} = LightControl.handle_write(0x0300, 0x0001, 254, cs)
    assert {cs.hue, cs.saturation} == {85, 254}
    assert color == Color.from_hue_saturation(85, 254)
  end

  test "x and y writes combine into one color" do
    {{:color, _}, cs} = LightControl.handle_write(0x0300, 0x0003, 41_943, LightControl.initial())
    {{:color, color}, cs} = LightControl.handle_write(0x0300, 0x0004, 21_627, cs)

    assert {cs.x, cs.y} == {41_943, 21_627}
    assert color == Color.from_xy(41_943, 21_627)
  end

  test "color temperature writes become a white" do
    assert {{:color, {255, 137, 14}}, _} =
             LightControl.handle_write(0x0300, 0x0007, 500, LightControl.initial())
  end

  test "other attributes are ignored" do
    cs = LightControl.initial()
    assert LightControl.handle_write(0x0300, 0x0008, 2, cs) == {:ignore, cs}
    assert LightControl.handle_write(0x0003, 0x0000, 5, cs) == {:ignore, cs}
  end

  defp restored(values, color? \\ true) do
    {actions, _cs} = LightControl.restore(values, color?)
    actions
  end

  test "restoring brings back power, brightness and the color of the color mode" do
    values = %{on_off: 1, level: 254, color_mode: 0, hue: 85, saturation: 254, mireds: 500}

    assert restored(values) == [
             {:power, true},
             {:brightness, 255},
             {:color, Color.from_hue_saturation(85, 254)}
           ]

    assert {:color, {255, 137, 14}} in restored(%{values | color_mode: 2})

    assert {:color, Color.from_xy(41_943, 21_627)} in restored(%{
             color_mode: 1,
             x: 41_943,
             y: 21_627
           })

    assert restored(%{on_off: 0}) == [{:power, false}]
  end

  test "restoring keeps the animations' colors until a color has been set" do
    values = %{on_off: 1, level: 64, color_mode: 2, mireds: 250}
    assert restored(values, false) == [{:power, true}, {:brightness, 64}]
  end

  test "restoring leaves alone what it doesn't know" do
    assert restored(%{}) == []
    # A null level, and a color temperature mode with no temperature
    assert restored(%{level: 255, color_mode: 2}) == []
  end

  test "restoring keeps the color state for later writes" do
    {_actions, cs} = LightControl.restore(%{hue: 10, saturation: 20}, true)
    assert {{:color, color}, _} = LightControl.handle_write(0x0300, 0x0000, 30, cs)
    assert color == Color.from_hue_saturation(30, 20)
  end
end
