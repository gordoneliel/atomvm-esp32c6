defmodule Sesame.MixProject do
  use Mix.Project

  def project do
    [
      app: :sesame,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      atomvm: atomvm()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:exatomvm, github: "atomvm/ExAtomVM", runtime: false},
      {:nerves_hub_link_avm, path: "../../nerves_hub_link_avm"}
    ]
  end

  defp atomvm do
    [
      start: Sesame.Application,
      flash_offset: 0x210000,
      chip: "esp32c6",
      port: "/dev/cu.usbmodem101",
      baud: 921_600
    ]
  end
end
