defmodule HydraSrt.Telemetry.RuntimeTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Telemetry.Runtime

  setup do
    Runtime.remove_handler()
    :ok = :meck.new(HydraSrt.Telemetry.Settings, [:passthrough])

    on_exit(fn ->
      Runtime.remove_handler()
      :meck.unload()
    end)

    :ok
  end

  test "enabled runtime installs a crash-only Sentry logger handler" do
    :meck.expect(HydraSrt.Telemetry.Settings, :crash_enabled?, fn -> true end)

    assert {:ok, state} = Runtime.init([])
    assert state.installed == true
    assert {:ok, config} = :logger.get_handler_config(:hydra_srt_sentry_handler)
    assert config.module == Sentry.LoggerHandler
    assert config.config.capture_log_messages == false

    assert :ok = Runtime.terminate(:normal, state)

    assert {:error, {:not_found, :hydra_srt_sentry_handler}} =
             :logger.get_handler_config(:hydra_srt_sentry_handler)
  end

  test "disabled runtime does not install a logger handler" do
    :meck.expect(HydraSrt.Telemetry.Settings, :crash_enabled?, fn -> false end)

    assert {:ok, state} = Runtime.init([])
    assert state.installed == false

    assert {:error, {:not_found, :hydra_srt_sentry_handler}} =
             :logger.get_handler_config(:hydra_srt_sentry_handler)
  end
end
