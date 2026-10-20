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

  test "on/off and level writes become power and brightness" do
    hs = LightControl.initial()
    assert LightControl.handle_write(0x0006, 0x0000, 1, hs) == {{:power, true}, hs}
    assert LightControl.handle_write(0x0006, 0x0000, 0, hs) == {{:power, false}, hs}
    assert LightControl.handle_write(0x0008, 0x0000, 254, hs) == {{:brightness, 255}, hs}
    assert LightControl.handle_write(0x0008, 0x0000, 1, hs) == {{:brightness, 1}, hs}
  end

  test "hue and saturation writes combine into one color" do
    {{:color, _}, hs} = LightControl.handle_write(0x0300, 0x0000, 85, LightControl.initial())
    assert hs == {85, 0}

    {{:color, color}, hs} = LightControl.handle_write(0x0300, 0x0001, 254, hs)
    assert hs == {85, 254}
    assert color == Color.from_hue_saturation(85, 254)
  end

  test "color temperature writes become a white" do
    assert {{:color, {255, 137, 14}}, _} =
             LightControl.handle_write(0x0300, 0x0007, 500, LightControl.initial())
  end

  test "other attributes are ignored" do
    hs = LightControl.initial()
    assert LightControl.handle_write(0x0300, 0x0003, 1000, hs) == {:ignore, hs}
    assert LightControl.handle_write(0x0003, 0x0000, 5, hs) == {:ignore, hs}
  end
end
