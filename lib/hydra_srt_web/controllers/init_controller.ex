defmodule HydraSrtWeb.InitController do
  use HydraSrtWeb, :controller

  @built_at DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  def show(conn, _params) do
    json(conn, %{
      version: app_version(),
      built_at: @built_at,
      system_version: system_version(),
      elixir_version: System.version(),
      erlang_version: erlang_version(),
      rust_version: rust_version(),
      app_started_at: app_started_at(),
      demo_data: Application.get_env(:hydra_srt, :demo_data, false),
      sentry_dsn: sentry_dsn()
    })
  end

  defp app_version do
    :hydra_srt
    |> Application.spec(:vsn)
    |> List.to_string()
  end

  defp system_version do
    case System.cmd("uname", ["-srm"], stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      _ ->
        {os_family, os_name} = :os.type()
        "#{os_family}/#{os_name} (#{:erlang.system_info(:system_architecture)})"
    end
  end

  defp erlang_version do
    otp_release = :erlang.system_info(:otp_release) |> List.to_string()
    erts_version = :erlang.system_info(:version) |> List.to_string()
    "OTP #{otp_release} (ERTS #{erts_version})"
  end

  defp rust_version do
    case System.find_executable("rustc") do
      nil ->
        "unavailable"

      _rustc_path ->
        case System.cmd("rustc", ["--version"], stderr_to_stdout: true) do
          {output, 0} -> String.trim(output)
          _ -> "unavailable"
        end
    end
  end

  def app_started_at do
    Application.get_env(:hydra_srt, :app_started_at, nil)
  end

  @spec sentry_dsn() :: binary() | nil
  def sentry_dsn do
    if Application.get_env(:hydra_srt, :env) == :prod,
      do: HydraSrt.Telemetry.Config.sentry_dsn(),
      else: nil
  end
end
