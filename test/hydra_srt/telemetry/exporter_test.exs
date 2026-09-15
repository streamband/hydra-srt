defmodule HydraSrt.Telemetry.ExporterTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Telemetry.{Exporter, Queue, StartedEvent}

  setup do
    original_telemetry = Application.get_env(:hydra_srt, :telemetry)
    original_request = Application.get_env(:hydra_srt, :telemetry_http_request)

    on_exit(fn ->
      Application.put_env(:hydra_srt, :telemetry, original_telemetry)
      Application.put_env(:hydra_srt, :telemetry_http_request, original_request)
    end)

    Application.put_env(:hydra_srt, :telemetry,
      posthog_host: "https://eu.i.posthog.com",
      posthog_key: "phc_test",
      export_interval_ms: :timer.hours(1),
      connect_timeout_ms: :timer.seconds(2),
      request_timeout_ms: :timer.seconds(5),
      shutdown_deadline_ms: 100
    )

    :ok
  end

  test "flush sends a PostHog batch with bounded request timeouts" do
    parent = self()

    Application.put_env(:hydra_srt, :telemetry_http_request, fn method,
                                                                url,
                                                                body,
                                                                headers,
                                                                opts ->
      send(parent, {:request, method, url, body, headers, opts})
      {:ok, 200, [], "{}"}
    end)

    start_supervised!(Queue)
    start_supervised!({Task.Supervisor, name: HydraSrt.Telemetry.TaskSupervisor})
    exporter = start_supervised!(Exporter)
    Queue.enqueue(started_event("0.6.9"))
    send(exporter, :flush)

    assert_receive {:request, :post, "https://eu.i.posthog.com/batch/", body, headers, opts}, 500
    assert {"content-type", "application/json"} in headers
    assert opts[:connect_timeout_ms] == 2_000
    assert opts[:request_timeout_ms] == 5_000
    assert {:ok, payload} = Jason.decode(body)
    assert payload["api_key"] == "phc_test"
    [event] = payload["batch"]
    assert event["timestamp"]
    assert event["properties"]["$process_person_profile"] == false
    assert event["properties"]["$lib"] == "hydra-srt"

    _state = :sys.get_state(exporter)
    assert Queue.size() == %{count: 0, bytes: 0}
  end

  test "failed sends requeue events, grow backoff, and open then close the circuit" do
    parent = self()

    Application.put_env(:hydra_srt, :telemetry,
      posthog_host: "https://eu.i.posthog.com",
      posthog_key: "phc_test",
      export_interval_ms: :timer.hours(1),
      circuit_window_ms: 10_000
    )

    Application.put_env(:hydra_srt, :telemetry_http_request, fn _method,
                                                                _url,
                                                                _body,
                                                                _headers,
                                                                _opts ->
      send(parent, :failed_request)
      {:error, :offline}
    end)

    start_supervised!(Queue)
    start_supervised!({Task.Supervisor, name: HydraSrt.Telemetry.TaskSupervisor})
    exporter = start_supervised!(Exporter)
    event = started_event("0.6.9")

    Enum.each(1..5, fn _attempt ->
      Queue.enqueue(event)
      send(exporter, :flush)
      assert_receive :failed_request, 500
      state = :sys.get_state(exporter)
      assert state.failures >= 1

      if state.circuit == :closed,
        do: :sys.replace_state(exporter, fn value -> %{value | retry_at: 0} end)
    end)

    assert %{circuit: :open, failures: 5, retry_at: retry_at} = :sys.get_state(exporter)
    assert retry_at > Exporter.now_ms()

    Application.put_env(:hydra_srt, :telemetry_http_request, fn _method,
                                                                _url,
                                                                _body,
                                                                _headers,
                                                                _opts ->
      send(parent, :successful_request)
      {:ok, 202, [], "{}"}
    end)

    :sys.replace_state(exporter, fn value -> %{value | retry_at: Exporter.now_ms() - 1} end)
    send(exporter, :flush)
    assert_receive :successful_request, 500
    assert %{circuit: :closed, failures: 0} = :sys.get_state(exporter)
  end

  test "shutdown flush uses the configured hard deadline" do
    parent = self()

    Application.put_env(:hydra_srt, :telemetry_http_request, fn _method,
                                                                _url,
                                                                _body,
                                                                _headers,
                                                                opts ->
      send(parent, {:shutdown_request, opts})
      {:ok, 200, [], "{}"}
    end)

    start_supervised!(Queue)
    Queue.enqueue(started_event("0.6.9"))
    exporter = start_supervised!(Exporter)

    assert :ok = GenServer.stop(exporter, :normal, 500)
    assert_receive {:shutdown_request, []}, 500
  end

  def started_event(version) do
    %StartedEvent{
      version: version,
      distribution: :source,
      installation_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate()
    }
  end
end
