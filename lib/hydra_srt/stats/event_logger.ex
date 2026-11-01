defmodule HydraSrt.Stats.EventLogger do
  @moduledoc false
  use GenServer
  require Logger

  alias HydraSrt.Stats.VictoriaMetrics

  @default_flush_interval_ms 5_000
  @default_max_batch_size 1_000
  @default_max_buffer_size 5_000

  def start_link(opts \\ %{}) when is_map(opts) do
    name = Map.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def noop_insert(_rows), do: :ok

  def log_source_switch(route_id, from_source_id, to_source_id, reason, details \\ %{}) do
    severity =
      case reason do
        "manual" -> "info"
        "primary_recovered" -> "info"
        _ -> "warning"
      end

    ingest(%{
      route_id: route_id,
      event_type: "source_switch",
      severity: severity,
      source_id: to_source_id,
      from_source_id: from_source_id,
      to_source_id: to_source_id,
      reason: reason,
      message: "Source switched",
      details_json: Jason.encode!(details || %{})
    })
  end

  @spec log_stats_reset(binary(), binary()) :: :ok
  def log_stats_reset(route_id, action) when action in ["set", "cleared"] do
    message =
      case action do
        "set" -> "Route statistics reset"
        "cleared" -> "Route statistics reset cleared"
      end

    ingest(%{
      route_id: route_id,
      event_type: "stats_reset",
      severity: "info",
      reason: action,
      message: message,
      details_json: Jason.encode!(%{action: action})
    })
  end

  def log_pipeline_failed(route_id, source_id, reason, message) do
    log_source_event(route_id, source_id, "pipeline_failed", "error", reason, message)
  end

  def log_pipeline_reconnecting(route_id, source_id, reason \\ nil) do
    log_source_event(
      route_id,
      source_id,
      "pipeline_reconnecting",
      "warning",
      reason,
      "Pipeline reconnecting"
    )
  end

  def log_youtube_unrecoverable(route_id, source_id, reason) do
    log_source_event(
      route_id,
      source_id,
      "youtube_unrecoverable",
      "error",
      reason,
      "YouTube source remains unrecoverable"
    )
  end

  # One shape for every event that is about a source failing on a route.
  defp log_source_event(route_id, source_id, event_type, severity, reason, message) do
    ingest(%{
      route_id: route_id,
      event_type: event_type,
      severity: severity,
      source_id: source_id,
      reason: reason,
      message: message
    })
  end

  def log_source_probe_failed(route_id, source_id, error) do
    ingest(%{
      route_id: route_id,
      event_type: "source_probe_failed",
      severity: "warning",
      source_id: source_id,
      message: to_string(error)
    })
  end

  def log_source_status_change(route_id, source_id, old_status, new_status) do
    ingest(%{
      route_id: route_id,
      event_type: "source_status_change",
      severity: "info",
      source_id: source_id,
      message: "Source status changed",
      details_json: Jason.encode!(%{"old_status" => old_status, "new_status" => new_status})
    })
  end

  def log_route_status_change(route_id, old_status, new_status) do
    ingest(%{
      route_id: route_id,
      event_type: "route_status_change",
      severity: "info",
      message: "Route status changed",
      details_json: Jason.encode!(%{"old_status" => old_status, "new_status" => new_status})
    })
  end

  def log_publisher_connected(route_id, path, peer) do
    ingest(%{
      route_id: route_id,
      event_type: "publisher_connected",
      severity: "info",
      message: "RTMP publisher connected",
      details_json: Jason.encode!(%{"path" => path, "peer" => inspect(peer)})
    })
  end

  def log_publisher_disconnected(route_id, path, peer) do
    ingest(%{
      route_id: route_id,
      event_type: "publisher_disconnected",
      severity: "info",
      message: "RTMP publisher disconnected",
      details_json: Jason.encode!(%{"path" => path, "peer" => inspect(peer)})
    })
  end

  def log_publish_rejected(route_id, path, reason) do
    ingest(%{
      route_id: route_id,
      event_type: "publish_rejected",
      severity: "warning",
      reason: reason,
      message: "RTMP publish rejected",
      details_json: Jason.encode!(%{"path" => path, "reason" => reason})
    })
  end

  def log_publish_conflict(route_id, path, owner_pid) do
    ingest(%{
      route_id: route_id,
      event_type: "publish_conflict",
      severity: "warning",
      message: "RTMP publish rejected: another publisher is active",
      details_json: Jason.encode!(%{"path" => path, "owner_pid" => inspect(owner_pid)})
    })
  end

  def log_publish_audio_only(route_id, path) do
    ingest(%{
      route_id: route_id,
      event_type: "publish_audio_only",
      severity: "warning",
      message: "RTMP publish has audio but no video track",
      details_json: Jason.encode!(%{"path" => path})
    })
  end

  def log_publish_video_only(route_id, path) do
    ingest(%{
      route_id: route_id,
      event_type: "publish_video_only",
      severity: "warning",
      message: "RTMP publish has video but no audio track",
      details_json: Jason.encode!(%{"path" => path})
    })
  end

  def log_publish_caps_changed(route_id, path) do
    ingest(%{
      route_id: route_id,
      event_type: "publish_caps_changed",
      severity: "warning",
      message: "RTMP publisher changed codec configuration mid-stream",
      details_json: Jason.encode!(%{"path" => path})
    })
  end

  def log_publish_no_codecs(route_id, path) do
    ingest(%{
      route_id: route_id,
      event_type: "publish_no_codecs",
      severity: "error",
      message: "RTMP publish delivered no codec sequence headers",
      details_json: Jason.encode!(%{"path" => path})
    })
  end

  def log_publish_inactivity(route_id, path) do
    ingest(%{
      route_id: route_id,
      event_type: "publish_inactivity",
      severity: "warning",
      message: "RTMP publisher timed out due to inactivity",
      details_json: Jason.encode!(%{"path" => path})
    })
  end

  def ingest(event) when is_map(event) do
    enriched = enrich(event)
    broadcast_event(enriched)

    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:ingest_event, enriched})
    end

    :ok
  end

  def broadcast_event(event) when is_map(event) do
    route_id = Map.get(event, :route_id) || Map.get(event, "route_id")

    payload = event_to_payload(event)

    if is_binary(route_id) and route_id != "" do
      Phoenix.PubSub.broadcast(
        HydraSrt.PubSub,
        "events:" <> route_id,
        {:event, payload}
      )
    end

    Phoenix.PubSub.broadcast(HydraSrt.PubSub, "events:all", {:event, payload})

    :ok
  end

  @impl true
  def init(opts) when is_map(opts) do
    flush_interval_ms = opts[:flush_interval_ms] || @default_flush_interval_ms
    max_batch_size = opts[:max_batch_size] || @default_max_batch_size
    max_buffer_size = opts[:max_buffer_size] || @default_max_buffer_size
    insert_events_fun = resolve_insert_events_fun(opts[:insert_events_fun])
    schedule_flush(flush_interval_ms)

    {:ok,
     %{
       events: [],
       flush_interval_ms: flush_interval_ms,
       max_batch_size: max_batch_size,
       max_buffer_size: max_buffer_size,
       insert_events_fun: insert_events_fun
     }}
  end

  @impl true
  def handle_info({:ingest_event, event}, state), do: ingest_event(event, state)

  def handle_info(:flush, state) do
    {events_after_flush, result} = flush_events(state.events, state.insert_events_fun)
    events_after_flush = enforce_max_buffer(events_after_flush, state)
    log_flush_error(result)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | events: events_after_flush}}
  end

  @impl true
  def handle_cast({:ingest_event, event}, state), do: ingest_event(event, state)

  @spec ingest_event(map(), map()) :: {:noreply, map()}
  def ingest_event(event, state) when is_map(event) and is_map(state) do
    events = enforce_max_buffer([event | state.events], state)

    if length(events) >= state.max_batch_size do
      {events_after_flush, result} = flush_events(events, state.insert_events_fun)
      events_after_flush = enforce_max_buffer(events_after_flush, state)
      log_flush_error(result)
      {:noreply, %{state | events: events_after_flush}}
    else
      {:noreply, %{state | events: events}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    {_events, result} = flush_events(state.events, state.insert_events_fun)
    log_flush_error(result)
    :ok
  end

  def flush_events(events, insert_fun \\ &VictoriaMetrics.insert_events/1)
  def flush_events([], _insert_fun), do: {[], :ok}

  def flush_events(events, insert_fun) when is_list(events) and is_function(insert_fun, 1) do
    rows = Enum.reverse(events)

    case insert_fun.(rows) do
      :ok -> {[], :ok}
      {:error, reason} -> {events, {:error, reason}}
    end
  end

  def schedule_flush(flush_interval_ms)
      when is_integer(flush_interval_ms) and flush_interval_ms > 0 do
    Process.send_after(self(), :flush, flush_interval_ms)
  end

  def enforce_max_buffer(events, %{max_buffer_size: max_buffer_size})
      when is_list(events) and is_integer(max_buffer_size) and max_buffer_size > 0 do
    # Count once and branch on it. Testing the size in the guard and again in
    # the body walked the whole buffer twice on every flush.
    count = length(events)

    if count > max_buffer_size do
      dropped = count - max_buffer_size

      Logger.warning("Event logger dropped #{dropped} buffered events due to max_buffer_size")

      Enum.take(events, max_buffer_size)
    else
      events
    end
  end

  def enforce_max_buffer(events, _state) when is_list(events), do: events

  def resolve_insert_events_fun(fun) when is_function(fun, 1), do: fun

  def resolve_insert_events_fun({module, function, args})
      when is_atom(module) and is_atom(function) and is_list(args) do
    fn rows -> apply(module, function, [rows | args]) end
  end

  def resolve_insert_events_fun(_), do: &VictoriaMetrics.insert_events/1

  defp enrich(event) do
    Map.merge(
      %{
        ts: DateTime.utc_now(),
        route_id: nil,
        event_type: "unknown",
        severity: "info",
        source_id: nil,
        from_source_id: nil,
        to_source_id: nil,
        reason: nil,
        message: nil,
        details_json: nil
      },
      event
    )
  end

  defp log_flush_error(:ok), do: :ok

  defp log_flush_error({:error, reason}) do
    Logger.error("Event logger flush failed reason=#{inspect(reason)}")
    :ok
  end

  defp event_to_payload(event) do
    %{
      "ts" => event |> Map.get(:ts) |> normalize_ts(),
      "route_id" => Map.get(event, :route_id),
      "event_type" => Map.get(event, :event_type),
      "severity" => Map.get(event, :severity),
      "source_id" => Map.get(event, :source_id),
      "from_source_id" => Map.get(event, :from_source_id),
      "to_source_id" => Map.get(event, :to_source_id),
      "reason" => Map.get(event, :reason),
      "message" => Map.get(event, :message),
      "details_json" => Map.get(event, :details_json)
    }
  end

  defp normalize_ts(%DateTime{} = ts), do: DateTime.to_iso8601(ts)

  defp normalize_ts(%NaiveDateTime{} = ts),
    do: ts |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp normalize_ts(ts), do: ts
end
