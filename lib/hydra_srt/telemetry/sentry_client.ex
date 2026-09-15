defmodule HydraSrt.Telemetry.SentryClient do
  @moduledoc "Hackney-backed Sentry client with bounded request timeouts."

  @behaviour Sentry.HTTPClient

  @impl true
  @spec post(String.t(), Sentry.HTTPClient.headers(), Sentry.HTTPClient.body()) ::
          {:ok, Sentry.HTTPClient.status(), Sentry.HTTPClient.headers(), Sentry.HTTPClient.body()}
          | {:error, term()}
  def post(url, headers, body) do
    opts = Application.get_env(:hydra_srt, :telemetry, [])

    hackney_opts = [
      {:connect_timeout, opts[:connect_timeout_ms] || :timer.seconds(2)},
      {:recv_timeout, opts[:request_timeout_ms] || :timer.seconds(5)},
      {:follow_redirect, false}
    ]

    case :hackney.request(:post, url, headers, body, [:with_body | hackney_opts]) do
      {:ok, status, response_headers, response_body} ->
        {:ok, status, response_headers, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end
end
