import Config

config :sesame, :nerveshub,
  host: System.get_env("NERVES_HUB_HOST") || raise("NERVES_HUB_HOST not set"),
  product_key: System.get_env("NERVES_HUB_KEY") || raise("NERVES_HUB_KEY not set"),
  product_secret: System.get_env("NERVES_HUB_SECRET") || raise("NERVES_HUB_SECRET not set")
