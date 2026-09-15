defmodule HydraSrtWeb.TelemetryEnvelopeControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  alias HydraSrt.Telemetry.Config
  alias HydraSrtWeb.Telemetry.EnvelopeRateLimiter

  setup do
    EnvelopeRateLimiter.reset()
    request_pid = self()
    previous_request_fun = Application.get_env(:hydra_srt, :sentry_tunnel_request_fun)

    Application.put_env(:hydra_srt, :sentry_tunnel_request_fun, fn method,
                                                                   url,
                                                                   body,
                                                                   headers,
                                                                   opts ->
      send(request_pid, {:sentry_request, method, url, body, headers, opts})
      {:ok, 204, [], ""}
    end)

    on_exit(fn ->
      EnvelopeRateLimiter.reset()

      if previous_request_fun do
        Application.put_env(:hydra_srt, :sentry_tunnel_request_fun, previous_request_fun)
      else
        Application.delete_env(:hydra_srt, :sentry_tunnel_request_fun)
      end
    end)

    :ok
  end

  test "requires authentication with 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/x-sentry-envelope")
      |> post(~p"/api/telemetry/envelope", "ignored")

    assert response(conn, 401)
  end

  test "drops envelopes when crash reporting is off", %{conn: conn} do
    conn = post_envelope(conn, valid_envelope())

    assert response(conn, 204) == ""
    refute_receive {:sentry_request, _, _, _, _, _}
  end

  test "forwards a valid scrubbed event", %{conn: conn} do
    :ok = :meck.new(HydraSrt.Telemetry.Settings, [:passthrough])
    :meck.expect(HydraSrt.Telemetry.Settings, :crash_enabled?, fn -> true end)
    on_exit(fn -> :meck.unload() end)

    conn = post_envelope(conn, valid_envelope(%{"message" => "passphrase=secret"}))

    assert response(conn, 204) == ""

    assert_receive {:sentry_request, :post, url, body, headers, opts}
    assert url == "https://o4512091677851648.ingest.de.sentry.io/api/4512091690565712/envelope/"
    assert {"content-type", "application/x-sentry-envelope"} in headers
    assert {"x-sentry-auth", auth_header()} in headers
    assert opts[:connect_timeout_ms] == 2_000
    assert opts[:request_timeout_ms] == 5_000
    refute body =~ "secret"
  end

  test "drops envelopes with a wrong DSN or unsupported item", %{conn: conn} do
    :ok = :meck.new(HydraSrt.Telemetry.Settings, [:passthrough])
    :meck.expect(HydraSrt.Telemetry.Settings, :crash_enabled?, fn -> true end)
    on_exit(fn -> :meck.unload() end)

    wrong_dsn = post_envelope(conn, valid_envelope(%{}, "https://example.com/key/1"))

    unsupported =
      post_envelope(conn, valid_envelope(%{}, Config.default_sentry_dsn(), "attachment"))

    assert response(wrong_dsn, 204) == ""
    assert response(unsupported, 204) == ""
    refute_receive {:sentry_request, _, _, _, _, _}
  end

  test "returns 413 for oversized envelopes", %{conn: conn} do
    :ok = :meck.new(HydraSrt.Telemetry.Settings, [:passthrough])
    :meck.expect(HydraSrt.Telemetry.Settings, :crash_enabled?, fn -> true end)
    on_exit(fn -> :meck.unload() end)

    conn = post_envelope(conn, valid_envelope(%{"message" => String.duplicate("x", 201_000)}))

    assert response(conn, 413) == ""
    refute_receive {:sentry_request, _, _, _, _, _}
  end

  test "allows twenty accepted envelopes per session per minute", %{conn: conn} do
    :ok = :meck.new(HydraSrt.Telemetry.Settings, [:passthrough])
    :meck.expect(HydraSrt.Telemetry.Settings, :crash_enabled?, fn -> true end)
    on_exit(fn -> :meck.unload() end)

    token = "rate_limit_#{System.unique_integer([:positive])}"
    {:ok, _session} = HydraSrt.Auth.create_session(token, "admin")

    Enum.each(1..20, fn _ ->
      assert response(post_envelope(conn, valid_envelope(), token), 204) == ""
    end)

    assert response(post_envelope(conn, valid_envelope(), token), 429) == ""

    for _ <- 1..20 do
      assert_receive {:sentry_request, _, _, _, _, _}
    end
  end

  def post_envelope(conn, body, token \\ nil) do
    conn =
      if token,
        do: put_req_header(conn, "authorization", "Bearer " <> token),
        else: log_in_user(conn)

    conn
    |> put_req_header("content-type", "application/x-sentry-envelope")
    |> post(~p"/api/telemetry/envelope", body)
  end

  def valid_envelope(payload \\ %{}, dsn \\ Config.default_sentry_dsn(), type \\ "event") do
    Jason.encode!(%{"dsn" => dsn}) <>
      "\n" <>
      Jason.encode!(%{"type" => type}) <>
      "\n" <>
      Jason.encode!(payload) <>
      "\n"
  end

  def auth_header do
    "Sentry sentry_version=7, sentry_client=hydra-srt/0.6.10, sentry_key=ed635a0a0de91a059eb36d2b4140012a"
  end
end
