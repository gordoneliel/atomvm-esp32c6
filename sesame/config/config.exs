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
    "uuid" => "ca59866b-163e-45f2-a0b3-67bb12f8d28a",
    "product" => "WorkplaceOS",
    "architecture" => "riscv32",
    "version" => Mix.Project.config()[:version],
    "platform" => "Sesame"
  },
  fwup_writer: Sesame.Hub.FwupWriter,
  client: Sesame.Hub.Client,
  extensions: [health: Sesame.Hub.HealthProvider]
