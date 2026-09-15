import Config

test_args = System.argv()

cli_only_or_include? = fn tag ->
  Enum.chunk_every(test_args, 2, 1, :discard)
  |> Enum.any?(fn
    ["--only", candidate] -> candidate == tag
    ["--include", candidate] -> candidate == tag
    _ -> false
  end)
end

e2e_mcp_mode_enabled? =
  System.get_env("E2E_MCP") == "true" or
    cli_only_or_include?.("e2e_mcp") or cli_only_or_include?.("mcp_probe")

e2e_route_mode_enabled? =
  System.get_env("E2E") == "true" or
    cli_only_or_include?.("e2e") or cli_only_or_include?.("encrypted")

shared_http_e2e_mode? = e2e_route_mode_enabled? or e2e_mcp_mode_enabled?

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
test_database_path =
  if shared_http_e2e_mode? do
    System.get_env("E2E_DATABASE_PATH") ||
      Path.join(System.tmp_dir!(), "hydra_srt_e2e_#{System.unique_integer([:positive])}.db")
  else
    System.get_env("UNIT_DATABASE_PATH") ||
      Path.join(
        System.tmp_dir!(),
        "hydra_srt_unit_test_#{System.get_env("MIX_TEST_PARTITION") || "0"}_#{System.unique_integer([:positive])}.db"
      )
  end

if shared_http_e2e_mode? do
  System.put_env("E2E_DATABASE_PATH", test_database_path)
end

config :hydra_srt, HydraSrt.Repo,
  # Use an isolated per-run SQLite DB file to prevent leaked state from previous runs
  # (including E2E runs) from breaking unit tests.
  #
  # Note: `mix test` alias runs `ecto.create` and `ecto.migrate`, so a fresh DB path
  # per run is safe and keeps the suite deterministic.
  database: test_database_path,
  pool_size: if(shared_http_e2e_mode?, do: 2, else: 5),
  pool:
    if(shared_http_e2e_mode?, do: DBConnection.ConnectionPool, else: Ecto.Adapters.SQL.Sandbox),
  queue_target: if(shared_http_e2e_mode?, do: 5_000, else: 50),
  queue_interval: if(shared_http_e2e_mode?, do: 5_000, else: 1_000),
  journal_mode: :wal,
  # E2E shares one DB across HTTP + Repo; longer busy wait reduces `database is locked`
  # under load (see test_helper E2E max_cases: 1 as well).
  busy_timeout: if(shared_http_e2e_mode?, do: 15_000, else: 2_000)

config :hydra_srt,
  victoria_metrics_url: "http://127.0.0.1:8428",
  victoria_logs_url: "http://127.0.0.1:9428",
  telemetry: [enabled?: false],
  system_metrics_history: [enabled: false],
  stats_collector: [
    flush_interval_ms: 86_400_000,
    insert_rows_fun: {HydraSrt.Stats.Collector, :noop_insert, []}
  ],
  event_logger: [
    flush_interval_ms: 86_400_000,
    insert_events_fun: {HydraSrt.Stats.EventLogger, :noop_insert, []}
  ],
  pipeline_logger: [
    flush_interval_ms: 86_400_000,
    insert_logs_fun: {HydraSrt.Stats.PipelineLogger, :noop_insert, []}
  ]

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hydra_srt, HydraSrtWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "o4JBd+wOK5JJIHHOZ/WMk00xrG9dN0//FF1MIBkDPzM+nRTN+5+L9hvMVX+805L0",
  server: false

# Defaults for automated UI/E2E tests (Playwright, ExUnit E2E helpers)
config :hydra_srt,
  api_auth_username: "admin",
  api_auth_password: "password123",
  default_bind_ip: "127.0.0.1"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
