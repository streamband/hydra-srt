defmodule HydraSrtWeb.Plugs.TelemetryRequestContextTest do
  use ExUnit.Case, async: false

  alias HydraSrtWeb.Plugs.TelemetryRequestContext

  setup do
    Sentry.Context.clear_all()
    on_exit(fn -> Sentry.Context.clear_all() end)
    :ok
  end

  test "enabled requests expose only method, route pattern, and request ID" do
    :ok = :meck.new(HydraSrt.Telemetry.Settings, [:passthrough])
    :meck.expect(HydraSrt.Telemetry.Settings, :crash_enabled?, fn -> true end)
    on_exit(fn -> :meck.unload() end)

    conn =
      Plug.Test.conn(:get, "/api/routes/secret-id?token=secret")
      |> Plug.Conn.put_private(:phoenix_route, "/api/routes/:id")
      |> Plug.Conn.put_resp_header("x-request-id", "request-123")
      |> Plug.Conn.put_req_header("authorization", "Bearer secret")

    conn = TelemetryRequestContext.call(conn, [])
    request = Sentry.Context.get_all()[:request]

    assert request.method == "GET"
    assert request.data == %{route: "/api/routes/:id"}
    assert request.env == %{"REQUEST_ID" => "request-123"}
    assert request.query_string == ""
    assert request.cookies == %{}
    assert request.headers == %{}
    refute inspect(request) =~ "secret-id"
    refute inspect(request) =~ "authorization"
    assert conn.method == "GET"
  end

  test "disabled requests do not set Sentry context" do
    conn = Plug.Test.conn(:get, "/api/routes/secret-id")
    assert ^conn = TelemetryRequestContext.call(conn, [])
    assert Sentry.Context.get_all()[:request] == %{}
  end
end
