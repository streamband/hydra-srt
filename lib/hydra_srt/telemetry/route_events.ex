defmodule HydraSrt.Telemetry.RouteEvents do
  @moduledoc "Converts selected route transitions into enum-only usage events."

  alias HydraSrt.Telemetry.{RouteEvent, Settings}

  @state_table :hydra_srt_telemetry_route_state

  @spec handle([atom()], map(), map(), term()) :: :ok
  def handle(_event, _measurements, metadata, _config) do
    transition = transition_name(metadata[:to])

    if Settings.usage_enabled?() and transition in ["started", "stopped", "failed", "restarting"] do
      case Task.Supervisor.start_child(HydraSrt.Telemetry.TaskSupervisor, fn ->
             emit(metadata[:route_id], metadata[:to], metadata)
           end) do
        {:ok, _pid} -> :ok
        {:error, _reason} -> :ok
      end
    end

    :ok
  end

  @spec route_started(map()) :: RouteEvent.t()
  def route_started(route) when is_map(route), do: elem(build(:started, route, nil, nil), 1)

  @spec route_stopped(map(), atom()) :: RouteEvent.t()
  def route_stopped(route, reason) when is_map(route),
    do: elem(build(:stopped, route, reason, route[:duration_bucket]), 1)

  @spec emit(binary() | nil, binary() | atom() | nil, map()) :: :ok
  def emit(nil, _transition, _metadata), do: :ok

  def emit(route_id, transition, _metadata) when is_binary(route_id) do
    case transition_name(transition) do
      "started" ->
        now = now_ms()
        put_state(route_id, now, 0)
        enqueue(route_event(route_id, :started, nil, nil))

      transition when transition in ["stopped", "failed", "restarting"] ->
        {started_at_ms, restarts} = state_for_transition(route_id, transition)
        duration = duration_bucket(started_at_ms, now_ms())
        restart_bucket = restart_count_bucket(restarts)

        enqueue(
          route_event(
            route_id,
            :stopped,
            transition_reason(transition),
            {duration, restart_bucket}
          )
        )

        if transition in ["stopped", "failed"], do: :ets.delete(state_table(), route_id)

      _other ->
        :ok
    end

    :ok
  end

  @spec emit(term(), term(), term()) :: :ok
  def emit(_route_id, _transition, _metadata), do: :ok

  @spec build(:started | :stopped, map(), atom() | nil, atom() | nil) ::
          {:ok, RouteEvent.t()} | {:error, term()}
  def build(kind, route, reason, duration_bucket) do
    sources = route[:sources] || route["sources"] || []
    destinations = route[:destinations] || route["destinations"] || []
    source = List.first(sources) || %{}

    event = %RouteEvent{
      event: if(kind == :started, do: "hydra.route.started", else: "hydra.route.stopped"),
      source_transport: transport(source),
      destination_transports: Enum.map(destinations, &transport/1),
      destination_count: length(destinations),
      failover_enabled:
        route[:backup_mode] in ["active", "passive"] or
          route["backup_mode"] in ["active", "passive"],
      has_passphrase: endpoint_has?(sources ++ destinations, [:passphrase, "passphrase"]),
      has_stream_id: endpoint_has?(sources ++ destinations, [:stream_id, "stream_id"]),
      reason: reason,
      duration_bucket: duration_bucket,
      restart_count_bucket: route[:restart_count_bucket] || route["restart_count_bucket"]
    }

    {:ok, event}
  end

  @spec transport(map()) :: atom()
  def transport(endpoint) do
    value = endpoint[:schema] || endpoint["schema"] || endpoint[:type] || endpoint["type"]

    case value |> to_string() |> String.downcase() do
      "srt" -> :srt
      "udp" -> :udp
      "rtmp" -> :rtmp
      "rtp" -> :rtp
      "ndi" -> :ndi
      "youtube" -> :youtube
      _ -> :unknown
    end
  end

  @spec endpoint_has?(list(), [atom() | binary()]) :: boolean()
  def endpoint_has?(endpoints, keys),
    do:
      Enum.any?(endpoints, fn endpoint ->
        Enum.any?(keys, &(endpoint[&1] not in [nil, "", false]))
      end)

  @spec duration_bucket(integer() | nil, integer()) :: atom() | nil
  def duration_bucket(nil, _now_ms), do: nil

  def duration_bucket(started_at_ms, now_ms) when now_ms >= started_at_ms do
    elapsed = now_ms - started_at_ms

    cond do
      elapsed < :timer.minutes(1) -> :lt_1m
      elapsed < :timer.minutes(10) -> :lt_10m
      elapsed < :timer.hours(1) -> :lt_1h
      elapsed < :timer.hours(24) -> :lt_1d
      true -> :ge_1d
    end
  end

  def duration_bucket(_started_at_ms, _now_ms), do: :lt_1m

  @spec restart_count_bucket(non_neg_integer()) :: atom()
  def restart_count_bucket(0), do: :"0"
  def restart_count_bucket(1), do: :"1"
  def restart_count_bucket(count) when count in 2..5, do: :"2_5"
  def restart_count_bucket(count) when count in 6..20, do: :"6_20"
  def restart_count_bucket(_count), do: :gt_20

  @spec transition_name(binary() | atom() | nil) :: binary() | nil
  def transition_name(value) when is_atom(value), do: Atom.to_string(value)
  def transition_name(value) when is_binary(value), do: String.downcase(value)
  def transition_name(_value), do: nil

  @spec transition_reason(binary()) :: :manual | :error | :restart
  def transition_reason("stopped"), do: :manual
  def transition_reason("failed"), do: :error
  def transition_reason("restarting"), do: :restart

  @spec state_table() :: atom()
  def state_table do
    case :ets.whereis(@state_table) do
      :undefined ->
        try do
          :ets.new(@state_table, [:named_table, :public, :set])
        catch
          :error, :already_exists -> @state_table
        end

      _table ->
        @state_table
    end
  end

  @spec put_state(binary(), integer(), non_neg_integer()) :: true
  def put_state(route_id, started_at_ms, restarts),
    do: :ets.insert(state_table(), {route_id, started_at_ms, restarts})

  @spec state_for_transition(binary(), binary()) :: {integer() | nil, non_neg_integer()}
  def state_for_transition(route_id, "restarting") do
    restarts = :ets.update_counter(state_table(), route_id, {3, 1}, {route_id, nil, 0})

    case :ets.lookup(state_table(), route_id) do
      [{^route_id, started_at_ms, ^restarts}] -> {started_at_ms, restarts}
      _ -> {nil, restarts}
    end
  end

  def state_for_transition(route_id, _transition) do
    case :ets.lookup(state_table(), route_id) do
      [{^route_id, started_at_ms, restarts}] -> {started_at_ms, restarts}
      _ -> {nil, 0}
    end
  end

  @spec route_event(binary(), :started | :stopped, atom() | nil, {atom() | nil, atom()} | nil) ::
          RouteEvent.t()
  def route_event(route_id, kind, reason, buckets) do
    route = HydraSrt.Db.get_route_map(route_id, true) || %{}
    {duration, restart_bucket} = buckets || {nil, nil}
    {:ok, event} = build(kind, route, reason, duration)
    %{event | restart_count_bucket: restart_bucket}
  end

  @spec enqueue(RouteEvent.t()) :: :ok
  def enqueue(event) do
    case Settings.ensure_identity(true) do
      {:ok, installation_id} ->
        HydraSrt.Telemetry.Queue.enqueue(%{
          event
          | installation_id: installation_id,
            session_id: Settings.session_id()
        })

      {:error, _reason} ->
        :ok
    end
  end

  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)
end
