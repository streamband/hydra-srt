import Config

alias HydraSrt.Env

# config/runtime.exs runs for every environment (including releases), after
# config/config.exs and config/<env>.exs. Use it for values that come from the
# host (env vars, files), not for compile-time-only options.
#
# Environment variables (non-exhaustive):
# - PHX_SERVER: set to enable the Phoenix endpoint server (releases)
# - SECRET_KEY_BASE: required in prod; optional in dev/test (defaults exist)
# - API_AUTH_USERNAME / API_AUTH_PASSWORD: required in prod; optional in dev
# - DATABASE_PATH: required in prod; optional in dev (overrides dev DB path)
# - VICTORIA_METRICS_URL / VICTORIA_LOGS_URL: optional analytics backends
# - POOL_SIZE: Ecto pool size (prod default 5)
# - PORT / PHX_HOST: HTTP listen port and URL host
# - RTMP_PORT: RTMP ingest server listen port (default 1935)
# - PHX_CHECK_ORIGIN: WebSocket origin checks (prod default: disabled)
# - NDI_FEATURE: enables the NDI feature (default false)
# - YOUTUBE_ENABLED: enables YouTube source resolution (default true)
# - YOUTUBE_COOKIES_PATH: optional yt-dlp cookies file
# - YT_DLP_PATH: optional yt-dlp executable path

if System.get_env("PHX_SERVER") do
  config :hydra_srt, HydraSrtWeb.Endpoint, server: true
end

config :hydra_srt, demo_data: Env.get_boolean("DEMO_DATA", false)
config :hydra_srt, rtmp_port: Env.get_integer("RTMP_PORT", 1935)

telemetry_config = Application.get_env(:hydra_srt, :telemetry, [])

config :hydra_srt,
       :telemetry,
       Keyword.merge(telemetry_config,
         sentry_dsn: HydraSrt.Telemetry.Config.sentry_dsn(),
         posthog_key: HydraSrt.Telemetry.Config.default_posthog_key(),
         posthog_host: HydraSrt.Telemetry.Config.default_posthog_host(),
         first_heartbeat_delay_ms: :timer.minutes(5),
         heartbeat_interval_ms: :timer.hours(24),
         heartbeat_jitter_ms: :timer.minutes(15),
         queue_max_events: 100,
         queue_max_bytes: 1_048_576,
         crash_max_events_per_fingerprint_hour: 3,
         connect_timeout_ms: :timer.seconds(2),
         request_timeout_ms: :timer.seconds(5),
         shutdown_deadline_ms: :timer.seconds(3)
       )

config :hydra_srt,
  telemetry_http_request: &HydraSrt.Telemetry.Http.default_request/5

config :sentry,
  dsn: HydraSrt.Telemetry.Config.sentry_dsn(),
  environment_name: to_string(config_env()),
  release: HydraSrt.Telemetry.Config.version(),
  send_default_pii: false,
  before_send: {HydraSrt.Telemetry.Crash, :before_send},
  in_app_module_allow_list: [HydraSrt, HydraSrtWeb],
  enable_source_code_context: false,
  dedup_events: true,
  send_result: :none,
  sample_rate: 1.0,
  send_client_reports: false,
  report_deps: false,
  enable_logs: false,
  enable_metrics: false,
  traces_sample_rate: nil,
  max_breadcrumbs: 0,
  tags: %{component: "beam"},
  client: HydraSrt.Telemetry.SentryClient

# NDI stays off unless NDI_FEATURE is set. Parsed to booleans here so
# HydraSrt.Ndi.FeaturePolicy only ever reads already-typed flags.
ndi_feature? = Env.get_boolean("NDI_FEATURE", false)
youtube_enabled? = Env.get_boolean("YOUTUBE_ENABLED", true)
youtube_cookies_path = Env.get_binary("YOUTUBE_COOKIES_PATH", nil)
yt_dlp_path = Env.get_binary("YT_DLP_PATH", nil)

config :hydra_srt, :ndi,
  enabled: ndi_feature?,
  receive: ndi_feature?,
  send: ndi_feature?

# The resolver is swappable: yt-dlp is the current way to get an HLS URL out of
# YouTube, not a permanent one. Set :resolver to any module implementing
# HydraSrt.Youtube.Resolver to replace it without touching the control plane.
config :hydra_srt, :youtube,
  enabled: youtube_enabled?,
  cookies_path: youtube_cookies_path,
  yt_dlp_path: yt_dlp_path

config :hydra_srt,
  rtmp_bootstrap_ttl_ms: Env.get_integer("RTMP_BOOTSTRAP_TTL_MS", :timer.seconds(30)),
  rtmp_codec_check_ms: Env.get_integer("RTMP_CODEC_CHECK_MS", :timer.seconds(5)),
  rtmp_publish_inactivity_ms: Env.get_integer("RTMP_PUBLISH_INACTIVITY_MS", :timer.seconds(10))

secret_key_base =
  cond do
    config_env() == :dev ->
      Env.get_binary("SECRET_KEY_BASE", nil) ||
        "9re8gLwrcmLnNcUbxe8xgKSCNfm8gIpgoBBiCXhV0dVfJMB8DVFB3QQJwOye0iIo"

    config_env() == :test ->
      Env.get_binary("SECRET_KEY_BASE", nil) ||
        "o4JBd+wOK5JJIHHOZ/WMk00xrG9dN0//FF1MIBkDPzM+nRTN+5+L9hvMVX+805L0"

    true ->
      Env.get_binary("SECRET_KEY_BASE", nil) ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """
  end

config :hydra_srt, HydraSrtWeb.Endpoint, secret_key_base: secret_key_base

unless config_env() == :test do
  system_metrics_history_enabled = Env.get_boolean("SYSTEM_METRICS_HISTORY_ENABLED", true)

  system_metrics_history_interval_ms = Env.get_integer("SYSTEM_METRICS_HISTORY_INTERVAL_MS", 5000)

  config :hydra_srt,
    default_bind_ip: Env.get_binary("HYDRA_DEFAULT_BIND_IP", "127.0.0.1"),
    prom_poll_rate: Env.get_integer("PROM_POLL_RATE", 5000),
    metrics_secret: Env.get_binary("METRICS_SECRET", nil),
    system_metrics_history: [
      enabled: system_metrics_history_enabled,
      flush_interval_ms: system_metrics_history_interval_ms
    ]
end

case config_env() do
  :prod ->
    config :hydra_srt,
      api_auth_username:
        Env.get_binary("API_AUTH_USERNAME", nil) || raise("API_AUTH_USERNAME is not set"),
      api_auth_password:
        Env.get_binary("API_AUTH_PASSWORD", nil) || raise("API_AUTH_PASSWORD is not set")

    database_path =
      Env.get_binary("DATABASE_PATH", nil) ||
        raise """
        environment variable DATABASE_PATH is missing.
        For example: /etc/hydra_srt/hydra_srt.db
        """

    config :hydra_srt, HydraSrt.Repo,
      database: database_path,
      pool_size: Env.get_integer("POOL_SIZE", 5),
      journal_mode: :wal

    config :hydra_srt,
      victoria_metrics_url: Env.get_binary("VICTORIA_METRICS_URL", "http://127.0.0.1:8428"),
      victoria_logs_url: Env.get_binary("VICTORIA_LOGS_URL", "http://127.0.0.1:9428")

    host = Env.get_binary("PHX_HOST", "example.com")
    port = Env.get_integer("PORT", 4000)
    check_origin = Env.get_check_origin("PHX_CHECK_ORIGIN")

    config :hydra_srt, HydraSrtWeb.Endpoint,
      url: [host: host, port: port, scheme: "http"],
      http: [
        ip: {0, 0, 0, 0},
        port: port
      ],
      check_origin: check_origin

  :dev ->
    port = Env.get_integer("PORT", 4000)
    host = Env.get_binary("PHX_HOST", "localhost")

    config :hydra_srt, HydraSrtWeb.Endpoint,
      url: [host: host, port: port, scheme: "http"],
      http: [ip: {127, 0, 0, 1}, port: port]

    if path = Env.get_binary("DATABASE_PATH", nil) do
      config :hydra_srt, HydraSrt.Repo,
        database: path,
        pool_size: Env.get_integer("POOL_SIZE", 5)
    end

    config :hydra_srt,
      victoria_metrics_url: Env.get_binary("VICTORIA_METRICS_URL", "http://127.0.0.1:8428"),
      victoria_logs_url: Env.get_binary("VICTORIA_LOGS_URL", "http://127.0.0.1:9428")

    if u = Env.get_binary("API_AUTH_USERNAME", nil) do
      config :hydra_srt, api_auth_username: u
    end

    if p = Env.get_binary("API_AUTH_PASSWORD", nil) do
      config :hydra_srt, api_auth_password: p
    end

  _ ->
    :ok
end

if config_env() == :test and System.get_env("E2E_UI") == "true" do
  port = Env.get_integer("E2E_PORT", 4000)

  config :hydra_srt, HydraSrtWeb.Endpoint,
    server: true,
    http: [ip: {127, 0, 0, 1}, port: port]
end
