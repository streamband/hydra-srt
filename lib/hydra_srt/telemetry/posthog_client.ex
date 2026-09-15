defmodule HydraSrt.Telemetry.PostHogClient do
  @moduledoc "Posts validated event batches to the configured PostHog host."

  @spec post_batch([struct()], keyword()) :: :ok | {:error, term()}
  def post_batch(events, opts \\ []) when is_list(events) do
    with {:ok, body} <- HydraSrt.Telemetry.Event.encode_batch(events),
         host when is_binary(host) <- posthog_host(),
         {:ok, status, _headers, _response} <-
           HydraSrt.Telemetry.Http.post_json(host <> "/batch/", body, opts),
         true <- status in 200..299 do
      :ok
    else
      false -> {:error, :unexpected_status}
      nil -> {:error, :posthog_not_configured}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @spec posthog_host() :: String.t() | nil
  def posthog_host do
    case Application.get_env(:hydra_srt, :telemetry, [])[:posthog_host] do
      value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
      _ -> nil
    end
  end
end
