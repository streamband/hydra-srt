defmodule HydraSrt.Telemetry.Config do
  @moduledoc "Compile-time telemetry posture and safe build metadata."

  @transports [:srt, :udp, :rtmp, :rtp, :ndi, :youtube]
  @sentry_dsn "https://ed635a0a0de91a059eb36d2b4140012a@o4512091677851648.ingest.de.sentry.io/4512091690565712"
  @posthog_host "https://eu.i.posthog.com"
  @posthog_key "phc_Caj6HJgJnjm2vf3ZS9Wd9KYUF7fqxCWnK7nFEXrvENkK"

  @spec sentry_dsn() :: binary() | nil
  def sentry_dsn do
    if HydraSrt.Telemetry.Settings.crash_enabled?(), do: @sentry_dsn, else: nil
  end

  @spec default_sentry_dsn() :: String.t()
  def default_sentry_dsn, do: @sentry_dsn

  @spec default_posthog_host() :: String.t()
  def default_posthog_host, do: @posthog_host

  @spec default_posthog_key() :: String.t()
  def default_posthog_key, do: @posthog_key

  @spec distribution() :: :docker | :release | :source
  def distribution do
    case System.get_env("HYDRA_DISTRIBUTION") do
      "docker" ->
        :docker

      "release" ->
        :release

      "source" ->
        :source

      nil ->
        :source

      value ->
        raise ArgumentError, "invalid HYDRA_DISTRIBUTION: #{inspect(value)}"
    end
  end

  @spec version() :: binary()
  def version do
    :hydra_srt
    |> Application.spec(:vsn)
    |> List.to_string()
  end

  @spec os_family() :: :linux | :darwin | :windows | :freebsd | :other
  def os_family do
    case :os.type() do
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :darwin
      {:win32, _} -> :windows
      {:unix, :freebsd} -> :freebsd
      _ -> :other
    end
  end

  @spec arch() :: :x86_64 | :aarch64 | :armv7 | :other
  def arch do
    value = :erlang.system_info(:system_architecture) |> List.to_string() |> String.downcase()

    cond do
      String.starts_with?(value, "x86_64") or String.starts_with?(value, "amd64") -> :x86_64
      String.starts_with?(value, "aarch64") or String.starts_with?(value, "arm64") -> :aarch64
      String.starts_with?(value, "armv7") or String.starts_with?(value, "armv7l") -> :armv7
      true -> :other
    end
  end

  @spec posthog_config() :: keyword()
  def posthog_config do
    Application.get_env(:hydra_srt, :telemetry, [])
    |> Keyword.take([:posthog_key, :posthog_host, :connect_timeout_ms, :request_timeout_ms])
  end

  @spec sentry_config() :: keyword()
  def sentry_config, do: Application.get_all_env(:sentry)

  @spec transports() :: [atom()]
  def transports, do: @transports
end
