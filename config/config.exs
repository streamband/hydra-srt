# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :hydra_srt,
  env: config_env(),
  ecto_repos: [HydraSrt.Repo],
  telemetry: [enabled?: true],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  # Hermes streamable-http transport uses a 5s GenServer.call timeout on tool requests.
  mcp_probe_timeout_ms: 3_500,
  victoria_metrics_url: "http://127.0.0.1:8428",
  victoria_logs_url: "http://127.0.0.1:9428"

# Configures the endpoint
config :hydra_srt, HydraSrtWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: HydraSrtWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HydraSrt.PubSub,
  live_view: [signing_salt: "+CT93K1p"],
  server: true

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :prom_ex, storage_adapter: PromEx.Storage.Peep

config :tesla, adapter: {Tesla.Adapter.Hackney, [recv_timeout: 40_000]}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
