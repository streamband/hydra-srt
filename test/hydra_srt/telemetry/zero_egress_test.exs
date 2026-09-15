defmodule HydraSrt.Telemetry.ZeroEgressTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.Telemetry.{Crash, Heartbeat, RouteEvents, Settings, Supervisor}

  test "disabled test builds start no telemetry children and never call HTTP" do
    assert Settings.usage_enabled?() == false
    assert Settings.crash_enabled?() == false
    assert Elixir.Supervisor.which_children(Supervisor) == []
    assert HydraSrt.Db.get_telemetry_installation() == nil

    parent = self()
    original = Application.get_env(:hydra_srt, :telemetry_http_request)

    Application.put_env(:hydra_srt, :telemetry_http_request, fn _method,
                                                                _url,
                                                                _body,
                                                                _headers,
                                                                _opts ->
      send(parent, :unexpected_telemetry_http)
      raise "telemetry egress is disabled"
    end)

    on_exit(fn -> Application.put_env(:hydra_srt, :telemetry_http_request, original) end)

    assert %HydraSrt.Telemetry.RouteEvent{} =
             RouteEvents.route_started(%{"sources" => [], "destinations" => []})

    assert {:noreply, _state} = Heartbeat.handle_tick(%{boot_started_at: 0, timer: nil})

    metadata = %{
      version: HydraSrt.Telemetry.Config.version(),
      distribution: :source,
      os_family: HydraSrt.Telemetry.Config.os_family(),
      arch: HydraSrt.Telemetry.Config.arch(),
      session_id: Ecto.UUID.generate()
    }

    payload = %{
      component: :rust_pipeline,
      kind: :fatal,
      exit_status: 1,
      error_class: "PipelineError",
      message: "pipeline failed",
      frames: [%{crate: "hydra_srt", function: "run", file: nil, line: 1}],
      source_transport: :srt,
      destination_transports: [:udp]
    }

    assert :ok = Crash.report_native(payload, metadata)
    assert :ok = Crash.report(RuntimeError.exception("disabled"))
    assert {:error, :invalid_native_payload} = Crash.report_native(%{unexpected: true}, metadata)
    refute_receive :unexpected_telemetry_http, 50

    assert {:error, {:not_found, :hydra_srt_sentry_handler}} =
             :logger.get_handler_config(:hydra_srt_sentry_handler)
  end
end
