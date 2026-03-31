import Config

config :sesame, :nerveshub,
  host: System.get_env("NERVES_HUB_HOST") || raise("NERVES_HUB_HOST not set — source .envrc"),
  product_key:
    System.get_env("NERVES_HUB_KEY") || raise("NERVES_HUB_KEY not set — source .envrc"),
  product_secret:
    System.get_env("NERVES_HUB_SECRET") || raise("NERVES_HUB_SECRET not set — source .envrc"),
  port: 443,
  identifier: "SESAME-00000001",
  firmware_meta: %{
    "uuid" => "b4903e05-4dd6-4cb0-a076-15e6dae476cf",
    "product" => "WorkplaceOS",
    "architecture" => "riscv32",
    "version" => "0.0.0-alpha-0",
    "platform" => "Sesame"
  },
  fwup_writer: Sesame.Hub.FwupWriter,
  client: Sesame.Hub.Client,
  extensions: [health: Sesame.Hub.HealthProvider]
