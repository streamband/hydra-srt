defmodule HydraSrt.Telemetry.CrashTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Telemetry.Crash

  setup do
    original_capture = Application.get_env(:hydra_srt, :telemetry_sentry_capture)
    original_telemetry = Application.get_env(:hydra_srt, :telemetry)
    :ok = :meck.new(HydraSrt.Telemetry.Settings, [:passthrough])
    :meck.expect(HydraSrt.Telemetry.Settings, :crash_enabled?, fn -> true end)

    on_exit(fn ->
      if is_nil(original_capture),
        do: Application.delete_env(:hydra_srt, :telemetry_sentry_capture),
        else: Application.put_env(:hydra_srt, :telemetry_sentry_capture, original_capture)

      Application.put_env(:hydra_srt, :telemetry, original_telemetry)
      :meck.unload()
    end)

    :ok
  end

  test "report_native accepts the E2a contract, synthesizes a stack, and scrubs the message" do
    parent = self()

    Application.put_env(:hydra_srt, :telemetry_sentry_capture, fn message, opts ->
      send(parent, {:captured, message, opts})
      :ok
    end)

    start_supervised!(Crash)

    payload = native_payload("srt://host:9000?passphrase=secret", "NativeError")
    assert :ok = Crash.report_native(payload, metadata())
    assert_receive {:captured, message, opts}, 500
    refute message =~ "passphrase=secret"
    assert opts[:fingerprint] == ["rust", "NativeError", "hydra_srt:run"]
    assert is_list(opts[:stacktrace])
    assert opts[:stacktrace] != []
  end

  test "invalid native maps return an error without raising" do
    assert {:error, _reason} = Crash.report_native(%{component: :rust_pipeline}, metadata())
    assert {:error, _reason} = Crash.report_native(%{unexpected: true}, metadata())
    assert {:error, _reason} = Crash.report_native(%{}, %{})
  end

  test "rate limits each fingerprint locally" do
    parent = self()

    Application.put_env(:hydra_srt, :telemetry_sentry_capture, fn _message, _opts ->
      send(parent, :captured)
      :ok
    end)

    Application.put_env(:hydra_srt, :telemetry, crash_max_events_per_fingerprint_hour: 2)
    start_supervised!(Crash)

    Enum.each(1..3, fn _ ->
      assert :ok = Crash.report_native(native_payload("same", "SameError"), metadata())
    end)

    assert_receive :captured, 500
    assert_receive :captured, 500
    refute_receive :captured, 100
  end

  test "before_send drops expected noise and passes a real crash" do
    no_route = event_with_exception("Phoenix.Router.NoRouteError", "not found")
    assert Crash.before_send(no_route) == nil

    wrapper = %Plug.Conn.WrapperError{
      reason: %Plug.BadRequestError{},
      kind: :error,
      stack: [],
      conn: nil
    }

    assert Crash.before_send(event_with_original(wrapper)) == nil

    busy = event_with_exception("Exqlite.Error", "database is locked")
    assert Crash.before_send(busy) == nil

    real = event_with_exception("RuntimeError", "srt://host:9000?passphrase=secret 8.8.8.8")
    scrubbed = Crash.before_send(real)
    assert %Sentry.Event{} = scrubbed
    refute inspect(scrubbed) =~ "srt://"
    refute inspect(scrubbed) =~ "passphrase=secret"
    refute inspect(scrubbed) =~ "8.8.8.8"
  end

  def native_payload(message, error_class) do
    %{
      component: :rust_pipeline,
      kind: :fatal,
      exit_status: 1,
      error_class: error_class,
      message: message,
      frames: [%{crate: "hydra_srt", function: "run", file: "/app/src/main.rs", line: 10}],
      gst_element: nil,
      source_transport: :srt,
      destination_transports: [:udp]
    }
  end

  def metadata do
    %{
      version: HydraSrt.Telemetry.Config.version(),
      distribution: :source,
      os_family: HydraSrt.Telemetry.Config.os_family(),
      arch: HydraSrt.Telemetry.Config.arch(),
      session_id: Ecto.UUID.generate()
    }
  end

  def event_with_exception(type, value) do
    %Sentry.Event{
      event_id: String.duplicate("a", 32),
      timestamp: "2026-09-15T00:00:00Z",
      exception: [%Sentry.Interfaces.Exception{type: type, value: value}],
      message: %Sentry.Interfaces.Message{formatted: value, message: value}
    }
  end

  def event_with_original(exception) do
    %Sentry.Event{
      event_id: String.duplicate("b", 32),
      timestamp: "2026-09-15T00:00:00Z",
      original_exception: exception,
      exception: [
        %Sentry.Interfaces.Exception{type: "Plug.Conn.WrapperError", value: "bad request"}
      ]
    }
  end
end
