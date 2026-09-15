defmodule HydraSrt.Telemetry.Heartbeat do
  @moduledoc "Schedules aggregate usage events."

  use GenServer
  alias HydraSrt.Telemetry.{HeartbeatEvent, Settings, StartedEvent}

  @five_minutes_ms 300_000
  @one_hour_ms 3_600_000
  @one_day_ms 86_400_000
  @one_week_ms 604_800_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    state = %{boot_started_at: System.monotonic_time(:millisecond), timer: nil}
    send(self(), :started)
    {:ok, state}
  end

  @impl true
  @spec handle_info(:started | :heartbeat_tick, map()) :: {:noreply, map()}
  def handle_info(:started, state) do
    with {:ok, installation_id} <- Settings.ensure_identity(true) do
      previous_version = Settings.snapshot()[:last_seen_version]

      event =
        build_started(%{
          installation_id: installation_id,
          session_id: Settings.session_id(),
          previous_version: previous_version
        })

      HydraSrt.Telemetry.Queue.enqueue(event)
      {:noreply, schedule_first(state, first_delay())}
    else
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_info(:heartbeat_tick, state), do: handle_tick(state)

  @spec build_started(map()) :: StartedEvent.t()
  def build_started(attrs) when is_map(attrs) do
    %StartedEvent{
      version: HydraSrt.Telemetry.Config.version(),
      distribution: HydraSrt.Telemetry.Config.distribution(),
      previous_version: attrs[:previous_version],
      installation_id: attrs[:installation_id],
      session_id: attrs[:session_id]
    }
  end

  @spec build_heartbeat(map()) :: HeartbeatEvent.t()
  def build_heartbeat(attrs \\ %{}) when is_map(attrs) do
    snapshot =
      cond do
        is_map(attrs[:snapshot]) -> attrs[:snapshot]
        HydraSrt.Telemetry.Settings.usage_enabled?() -> HydraSrt.Db.telemetry_route_snapshot()
        true -> %{}
      end

    boot_started_at = attrs[:boot_started_at] || System.monotonic_time(:millisecond)
    uptime = System.monotonic_time(:millisecond) - boot_started_at

    %HeartbeatEvent{
      version: HydraSrt.Telemetry.Config.version(),
      os_family: HydraSrt.Telemetry.Config.os_family(),
      arch: HydraSrt.Telemetry.Config.arch(),
      distribution: HydraSrt.Telemetry.Config.distribution(),
      uptime_bucket: uptime_bucket(uptime),
      route_count_total: snapshot[:route_count_total] || 0,
      routes_active_count: snapshot[:routes_active_count] || 0,
      route_counts_by_source_transport: snapshot[:route_counts_by_source_transport] || %{},
      route_counts_by_destination_transport:
        snapshot[:route_counts_by_destination_transport] || %{},
      failover_configured_count: snapshot[:failover_configured_count] || 0,
      mcp_enabled: snapshot[:mcp_enabled] == true,
      ndi_enabled: snapshot[:ndi_enabled] == true,
      youtube_enabled: snapshot[:youtube_enabled] == true,
      telegram_enabled: snapshot[:telegram_enabled] == true,
      victoria_configured: snapshot[:victoria_configured] == true,
      interfaces_count: snapshot[:interfaces_count] || 0,
      installation_id: attrs[:installation_id] || Settings.installation_id(),
      session_id: attrs[:session_id] || Settings.session_id()
    }
  end

  @spec build_preview(map()) :: {:ok, binary()} | {:error, term()}
  def build_preview(attrs \\ %{}) do
    with {:ok, id} <- Settings.ensure_identity(true) do
      attrs = Map.merge(attrs, %{installation_id: id, session_id: Settings.session_id()})
      HydraSrt.Telemetry.Event.encode(build_heartbeat(attrs))
    end
  end

  @spec schedule_first(map(), non_neg_integer()) :: map()
  def schedule_first(state, delay_ms),
    do: %{state | timer: Process.send_after(self(), :heartbeat_tick, max(delay_ms + jitter(), 0))}

  @spec schedule_next(map(), non_neg_integer()) :: map()
  def schedule_next(state, interval_ms),
    do: %{
      state
      | timer: Process.send_after(self(), :heartbeat_tick, max(interval_ms + jitter(), 0))
    }

  @spec handle_tick(map()) :: {:noreply, map()}
  def handle_tick(state) do
    with {:ok, installation_id} <- Settings.ensure_identity(true) do
      event =
        build_heartbeat(%{
          installation_id: installation_id,
          session_id: Settings.session_id(),
          boot_started_at: state.boot_started_at
        })

      HydraSrt.Telemetry.Queue.enqueue(event)
      {:noreply, schedule_next(state, interval())}
    else
      {:error, _reason} -> {:noreply, state}
    end
  end

  @spec uptime_bucket(integer()) :: atom()
  def uptime_bucket(milliseconds) when milliseconds < @five_minutes_ms, do: :under_5m
  def uptime_bucket(milliseconds) when milliseconds < @one_hour_ms, do: :five_minutes_to_1h
  def uptime_bucket(milliseconds) when milliseconds < @one_day_ms, do: :one_to_24h
  def uptime_bucket(milliseconds) when milliseconds < @one_week_ms, do: :one_to_7d
  def uptime_bucket(_milliseconds), do: :over_7d

  @spec first_delay() :: non_neg_integer()
  def first_delay,
    do:
      Application.get_env(:hydra_srt, :telemetry, [])[:first_heartbeat_delay_ms] ||
        :timer.minutes(5)

  @spec interval() :: non_neg_integer()
  def interval,
    do:
      Application.get_env(:hydra_srt, :telemetry, [])[:heartbeat_interval_ms] || :timer.hours(24)

  @spec jitter() :: integer()
  def jitter do
    max_jitter = Application.get_env(:hydra_srt, :telemetry, [])[:heartbeat_jitter_ms] || 0
    if max_jitter > 0, do: :rand.uniform(max_jitter * 2 + 1) - max_jitter - 1, else: 0
  end
end
