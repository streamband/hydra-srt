defmodule HydraSrt.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    Application.put_env(
      :hydra_srt,
      :app_started_at,
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    )

    demo_enabled? = Application.get_env(:hydra_srt, :demo_data, false)
    HydraSrt.Demo.ensure_requirements!(demo_enabled?)

    :ok =
      :gen_event.swap_sup_handler(
        :erl_signal_server,
        {:erl_signal_handler, []},
        {HydraSrt.SignalHandler, []}
      )

    :syn.add_node_to_scopes([:routes])
    runtime_schedulers = System.schedulers_online()
    rtmp_port = Application.fetch_env!(:hydra_srt, :rtmp_port)

    rtmp_server_listener =
      :ranch.child_spec(
        :rtmp_server,
        :ranch_tcp,
        %{
          max_connections: 1_000,
          num_acceptors: 10,
          socket_opts: [port: rtmp_port, keepalive: true]
        },
        HydraSrt.RtmpServer,
        []
      )

    children = [
      HydraSrtWeb.Telemetry,
      HydraSrt.PromEx,
      HydraSrt.ErlSysMon,
      {PartitionSupervisor,
       child_spec: DynamicSupervisor, strategy: :one_for_one, name: HydraSrt.DynamicSupervisor},
      {Registry,
       keys: :unique, name: HydraSrt.Registry.MsgHandlers, partitions: runtime_schedulers},
      {Registry,
       keys: :unique, name: HydraSrt.Rtmp.PublisherRegistry, partitions: runtime_schedulers},
      HydraSrt.BackupLock,
      HydraSrt.Repo,
      HydraSrt.Telemetry.Supervisor,
      HydraSrt.AuthCleanup,
      HydraSrt.SignalGenerator,
      {Task.Supervisor, name: HydraSrt.TaskSupervisor},
      {HydraSrt.Stats.Collector, stats_collector_opts()},
      {HydraSrt.Stats.SystemTelemetryCollector,
       Application.get_env(:hydra_srt, :system_metrics_history, [])},
      {HydraSrt.Stats.EventLogger, event_logger_opts()},
      HydraSrt.Stats.Cleaner,
      # {Ecto.Migrator,
      #  repos: Application.fetch_env!(:hydra_srt, :ecto_repos), skip: skip_migrations?()},
      {Phoenix.PubSub, name: HydraSrt.PubSub, partitions: runtime_schedulers},
      Hermes.Server.Registry,
      {HydraSrt.Mcp.Server, transport: {:streamable_http, start: true}, request_timeout: 20_000},
      {HydraSrt.Stats.PipelineLogger, pipeline_logger_opts()},
      {HydraSrt.Notifications.Telegram, %{}},
      rtmp_server_listener,
      HydraSrtWeb.Endpoint
    ]

    # Start the NDI discovery coordinator only when NDI is enabled.
    children =
      if HydraSrt.Ndi.FeaturePolicy.enabled?() do
        children ++ [HydraSrt.Ndi.Discovery]
      else
        children
      end

    # The refresh scheduler only has work when YouTube sources can run at all.
    children =
      if HydraSrt.Youtube.FeaturePolicy.enabled?() do
        children ++ [HydraSrt.Youtube.RefreshScheduler]
      else
        children
      end

    # Cachex is used by API auth and RTMP stream bootstrap cache; keep them always available.
    rtmp_cache_child = %{
      id: HydraSrt.RtmpCache,
      start: {Cachex, :start_link, [[name: HydraSrt.RtmpCache]]}
    }

    children = [
      {Cachex, name: HydraSrt.Cache},
      rtmp_cache_child | children
    ]

    opts = [strategy: :one_for_one, name: HydraSrt.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)
    :ok = HydraSrt.Auth.startup_cleanup()
    :ok = HydraSrt.Demo.bootstrap(demo_enabled?)
    :ok = recover_routes_after_startup()

    {:ok, pid}
  end

  @impl true
  def config_change(changed, _new, removed) do
    HydraSrtWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @impl true
  def stop(_state) do
    Logger.info("Stopping application")
  end

  @doc false
  def recover_routes_after_startup do
    log_stale_runtime_statuses()
    kill_stale_pipeline_processes()

    reset_counts = HydraSrt.Db.reset_runtime_statuses_to_stopped()

    Logger.info(
      "Startup route recovery reset #{reset_counts.routes} routes and #{reset_counts.destinations} destinations to stopped"
    )

    :ok = HydraSrt.Notifications.Telegram.suspend_notifications()

    try do
      HydraSrt.Db.list_enabled_routes()
      |> Enum.each(&start_enabled_route/1)
    after
      :ok = HydraSrt.Notifications.Telegram.resume_notifications()
    end

    :ok
  end

  defp log_stale_runtime_statuses do
    HydraSrt.Db.list_routes_with_stale_runtime_status()
    |> Enum.each(fn route ->
      Logger.error(
        "Startup route recovery found stale route status route_id=#{route.id} status=#{inspect(route.status)}"
      )
    end)

    HydraSrt.Db.list_destinations_with_stale_runtime_status()
    |> Enum.each(fn destination ->
      Logger.error(
        "Startup route recovery found stale destination status destination_id=#{destination.id} route_id=#{destination.route_id} status=#{inspect(destination.status)}"
      )
    end)
  end

  defp kill_stale_pipeline_processes do
    {:ok, routes} = HydraSrt.Db.get_all_routes(false)

    Enum.each(routes, fn %{"id" => route_id} ->
      case HydraSrt.ProcessMonitor.kill_pipeline_processes_for_route(route_id) do
        {:ok, _results} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Startup route recovery failed to kill stale pipeline processes route_id=#{route_id} reason=#{inspect(reason)}"
          )
      end
    end)
  end

  defp start_enabled_route(route) do
    Logger.info("Startup route recovery starting enabled route route_id=#{route.id}")

    case HydraSrt.start_route(route.id) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Startup route recovery failed to start enabled route route_id=#{route.id} reason=#{inspect(reason)}"
        )
    end
  end

  @test_sink_override_keys [
    :insert_rows_fun,
    :insert_events_fun,
    :insert_logs_fun,
    :flush_interval_ms
  ]

  defp stats_collector_opts do
    :hydra_srt
    |> Application.get_env(:stats_collector, [])
    |> maybe_drop_test_sink_overrides()
    |> Enum.into(%{})
  end

  defp event_logger_opts do
    :hydra_srt
    |> Application.get_env(:event_logger, [])
    |> maybe_drop_test_sink_overrides()
    |> Enum.into(%{})
  end

  defp pipeline_logger_opts do
    :hydra_srt
    |> Application.get_env(:pipeline_logger, [])
    |> maybe_drop_test_sink_overrides()
    |> Enum.into(%{})
  end

  defp maybe_drop_test_sink_overrides(opts) when is_list(opts) do
    if e2e_mode?() do
      Keyword.drop(opts, @test_sink_override_keys)
    else
      opts
    end
  end

  defp e2e_mode? do
    System.get_env("E2E") == "true" or System.get_env("E2E_MCP") == "true"
  end
end
