import Config

# The battery runs only under :test (`mix platform_battery` pins the env).
# A dev config exists so an accidental MIX_ENV=dev fails with a clear
# config, not a missing file.

config :logger, level: :info
