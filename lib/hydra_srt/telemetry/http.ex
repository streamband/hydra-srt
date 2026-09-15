defmodule HydraSrt.Telemetry.Http do
  @moduledoc "Small injectable HTTP boundary for PostHog telemetry."

  @spec post_json(String.t(), binary(), keyword()) ::
          {:ok, integer(), list(), binary()} | {:error, term()}
  def post_json(url, body, opts \\ []) do
    request = Application.get_env(:hydra_srt, :telemetry_http_request, &default_request/5)
    request.(:post, url, body, [{"content-type", "application/json"}], opts)
  rescue
    error -> {:error, error}
  end

  @spec default_request(atom(), String.t(), binary(), list(), keyword()) ::
          {:ok, integer(), list(), binary()} | {:error, term()}
  def default_request(method, url, body, headers, opts) do
    hackney_opts = [
      {:connect_timeout, opts[:connect_timeout_ms] || :timer.seconds(2)},
      {:recv_timeout, opts[:request_timeout_ms] || :timer.seconds(5)},
      {:follow_redirect, false}
    ]

    case :hackney.request(method, url, headers, body, [:with_body | hackney_opts]) do
      {:ok, status, response_headers, response_body} ->
        {:ok, status, response_headers, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end
end
