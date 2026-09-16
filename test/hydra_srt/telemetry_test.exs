defmodule HydraSrt.TelemetryTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.Telemetry

  setup do
    Application.put_env(:hydra_srt, :telemetry_http_test_pid, self())
    dir = Path.join(System.tmp_dir!(), "hydra-telemetry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Application.delete_env(:hydra_srt, :telemetry_http_test_pid)
      File.chmod(dir, 0o755)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "posts started on boot and a heartbeat on schedule", %{dir: dir} do
    name = :"telemetry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Telemetry, name: name, data_dir: dir, first_heartbeat_after: 10, heartbeat_every: 10}
    )

    assert_receive {:telemetry_http_request, :post, url, started, headers, opts}, 1_000
    assert url == "https://eu.i.posthog.com/batch/"
    assert {"content-type", "application/json"} in headers
    assert opts == [connect_timeout_ms: 2_000, request_timeout_ms: 5_000]

    assert %{"api_key" => "phc_" <> _, "batch" => [event]} = Jason.decode!(started)
    assert event["event"] == "hydra.started"
    assert event["distinct_id"] == dir |> Path.join("telemetry_id") |> File.read!()

    assert %{"version" => _, "distribution" => "source", "$process_person_profile" => false} =
             event["properties"]

    assert_receive {:telemetry_http_request, :post, _url, heartbeat, _headers, _opts}, 1_000

    assert %{"batch" => [%{"event" => "hydra.heartbeat", "properties" => props}]} =
             Jason.decode!(heartbeat)

    assert %{"routes" => 0, "sources_by_type" => %{}, "uptime_hours" => 0} = props
  end

  test "reuses a stored id and replaces an invalid one", %{dir: dir} do
    id = Telemetry.load_installation_id(dir)
    assert Telemetry.load_installation_id(dir) == id

    File.write!(Path.join(dir, "telemetry_id"), "garbage")
    replaced = Telemetry.load_installation_id(dir)
    assert replaced != id and {:ok, replaced} == Ecto.UUID.cast(replaced)
  end

  test "keeps running without an id when the file cannot be written", %{dir: dir} do
    File.chmod!(dir, 0o555)
    assert Telemetry.load_installation_id(dir) == nil
  end

  test "a failed post is dropped without raising" do
    state = %{installation_id: nil, session_id: Ecto.UUID.generate()}

    Application.put_env(:hydra_srt, :telemetry_http_request, fn _, _, _, _, _ ->
      {:error, :nxdomain}
    end)

    on_exit(fn ->
      Application.put_env(
        :hydra_srt,
        :telemetry_http_request,
        &HydraSrt.TestSupport.TelemetryHttpClient.request/5
      )
    end)

    assert :error = Telemetry.post(state, "hydra.started", %{})
  end
end
