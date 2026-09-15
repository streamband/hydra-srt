defmodule HydraSrtWeb.Plugs.TelemetryRequestContext do
  @moduledoc "Adds only request method, route pattern, and request ID to Sentry."

  @behaviour Plug

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if HydraSrt.Telemetry.Settings.crash_enabled?() do
      request_id = List.first(Plug.Conn.get_resp_header(conn, "x-request-id"))
      route = conn.private[:phoenix_route] || conn.private[:phoenix_action] || "unknown"

      Sentry.Context.set_request_context(%{
        method: conn.method,
        data: %{route: to_string(route)},
        query_string: "",
        cookies: %{},
        headers: %{},
        env: %{"REQUEST_ID" => request_id}
      })
    end

    conn
  rescue
    _error -> conn
  end
end
