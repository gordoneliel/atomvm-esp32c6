defmodule Firefly.MixProject do
  use Mix.Project

  def project do
    [
      app: :firefly,
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
      {:atomvm, "~> 0.7.0-beta.0", runtime: false}
    ]
  end

  defp atomvm do
    [
      start: Firefly.Application,
      chip: "esp32c6",
      port: "/dev/cu.usbmodem1101",
      baud: "921600"
    ]
  end
end
