import Config

config :sesame, :nerveshub,
  host: System.get_env("NERVES_HUB_HOST") || raise("NERVES_HUB_HOST not set — source .envrc"),
  product_key:
    System.get_env("NERVES_HUB_KEY") || raise("NERVES_HUB_KEY not set — source .envrc"),
  product_secret:
    System.get_env("NERVES_HUB_SECRET") || raise("NERVES_HUB_SECRET not set — source .envrc"),
  port: String.to_integer(System.get_env("NERVES_HUB_PORT") || "443"),
  ssl: System.get_env("NERVES_HUB_SSL") != "false",
  identifier: "SESAME-00000001",
  firmware_meta: %{
    "uuid" => "5583c2e3-feed-41c4-9ead-a4c80fc1619a",
    "product" => "WorkplaceOS",
    "architecture" => "riscv32",
    "version" => Mix.Project.config()[:version],
    "platform" => "Sesame"
  },
  firmware_writer: Sesame.Hub.FwupWriter,
  client: Sesame.Hub.Client,
  extensions: [health: Sesame.Hub.HealthProvider, logging: true]
