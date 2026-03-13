import Config

config :influx_elixir, :client, InfluxElixir.Client.HTTP

import_config "#{config_env()}.exs"
