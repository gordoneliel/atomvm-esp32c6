defmodule Firefly.Lights.Color do
  @moduledoc """
  RGB colors as `{r, g, b}` tuples with components in `0..255`.
  """

  @type t :: {0..255, 0..255, 0..255}

  @black {0, 0, 0}

  def black, do: @black

  @doc "Scales a color by `brightness` (`0..255`, where 255 is full brightness)."
  def scale({r, g, b}, brightness) do
    {div(r * brightness, 255), div(g * brightness, 255), div(b * brightness, 255)}
  end

  @doc """
  Full-intensity color for a hue and saturation on Matter's scale (`0..254`
  for both, hue going around the color wheel from red).
  """
  def from_hue_saturation(hue, saturation) do
    s = div(saturation * 255, 254)
    # Six 255-step sectors around the wheel
    position = div(hue * 6 * 255, 254)
    sector = rem(div(position, 255), 6)
    f = rem(position, 255)

    p = 255 - s
    q = 255 - div(s * f, 255)
    t = 255 - div(s * (255 - f), 255)

    case sector do
      0 -> {255, t, p}
      1 -> {q, 255, p}
      2 -> {p, 255, t}
      3 -> {p, q, 255}
      4 -> {t, p, 255}
      5 -> {255, p, q}
    end
  end

  # White points by color temperature in mireds (1_000_000 / kelvin):
  # 6500K, 4000K, 2700K, 2000K
  @whites [
    {153, {255, 249, 253}},
    {250, {255, 209, 163}},
    {370, {255, 169, 87}},
    {500, {255, 137, 14}}
  ]

  @doc "Approximate white for a color temperature in mireds (warm is higher)."
  def from_mireds(mireds), do: interpolate(@whites, mireds)

  defp interpolate([{m, color} | _], mireds) when mireds <= m, do: color

  defp interpolate([{m1, c1}, {m2, c2} | _], mireds) when mireds <= m2,
    do: blend(c1, c2, mireds - m1, m2 - m1)

  defp interpolate([_ | rest], mireds) when rest != [], do: interpolate(rest, mireds)
  defp interpolate([{_m, color}], _mireds), do: color

  @doc "Scales a color by the fraction `numerator / denominator`."
  def scale({r, g, b}, numerator, denominator) do
    {div(r * numerator, denominator), div(g * numerator, denominator),
     div(b * numerator, denominator)}
  end

  @doc """
  Mixes `numerator / denominator` of color `b` into color `a`: all `a` at 0,
  all `b` at `denominator`.
  """
  def blend({r1, g1, b1}, {r2, g2, b2}, numerator, denominator) do
    rest = denominator - numerator

    {div(r1 * rest + r2 * numerator, denominator), div(g1 * rest + g2 * numerator, denominator),
     div(b1 * rest + b2 * numerator, denominator)}
  end

  @doc """
  The fully saturated color at `position` around the color wheel: red at 0,
  green at 85, blue at 170, back to red at 256. Positions wrap around.
  """
  def wheel(position) do
    case Bitwise.band(position, 255) do
      p when p < 85 -> {255 - p * 3, p * 3, 0}
      p when p < 170 -> {0, 255 - (p - 85) * 3, (p - 85) * 3}
      p -> {(p - 170) * 3, 0, 255 - (p - 170) * 3}
    end
  end
end
