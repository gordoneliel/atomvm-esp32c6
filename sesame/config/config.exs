import Config

config :sesame, :nerveshub,
  port: 443,
  identifier: "SESAME-00000000",
  firmware_meta: %{
    "uuid" => "bff0a78f-d669-47dd-85c4-8ed2d1eeb752",
    "product" => "WorkplaceOS",
    "architecture" => "riscv32",
    "version" => "0.1.0",
    "platform" => "Sesame"
  },
  fwup_writer: Sesame.Hub.FwupWriter,
  client: Sesame.Hub.Client,
  extensions: [health: Sesame.Hub.HealthProvider]

import_config "#{config_env()}.exs"
