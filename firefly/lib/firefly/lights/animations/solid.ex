defmodule Firefly.Lights.Animations.Solid do
  @moduledoc """
  Every LED set to one color.

  Options: `:color` (default black, i.e. off).
  """

  @behaviour Firefly.Lights.Animation

  alias Firefly.Lights.{Color, Frame}

  @impl true
  def init(opts), do: %{color: Keyword.get(opts, :color, Color.black())}

  @impl true
  def next_frame(state), do: {Frame.fill(state.color), :infinity, state}
end
