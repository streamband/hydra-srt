defmodule HydraSrt.Stats.Analytics do
  @moduledoc false
  require Logger

  alias HydraSrt.Db
  alias HydraSrt.Monitoring.OsMon
  alias HydraSrt.Stats.VictoriaLogs
  alias HydraSrt.Stats.VictoriaMetrics

  @window_to_seconds %{
    "last_30_min" => 30 * 60,
    "last_hour" => 60 * 60,
    "last_6_hour" => 6 * 60 * 60,
    "last_24_hour" => 24 * 60 * 60
  }

  @bucket_10_seconds_ms 10_000
  @bucket_30_seconds_ms 30_000
  @bucket_1_minute_ms 60_000
  @bucket_5_minutes_ms 300_000
  @bucket_15_minutes_ms 900_000
  @bucket_30_minutes_ms 1_800_000
  @bucket_1_hour_ms 3_600_000
  @default_max_points 300
  @min_max_points 50
  @max_max_points 2_000
  @default_history_limit 50
  @max_history_limit 200

  @type query_params :: %{
          required(:from) => DateTime.t(),
          required(:to) => DateTime.t(),
          required(:window) => binary(),
          required(:bucket_ms) => pos_integer()
        }

  @spec build_query_params(map()) :: {:ok, query_params()} | {:error, {:bad_request, binary()}}
  def build_query_params(params) when is_map(params) do
    max_points = parse_max_points(Map.get(params, "max_points"), @default_max_points)

    with {:ok, range} <- parse_range(params),
         {:ok, bucket_ms} <- bucket_ms_for_range(range.from, range.to, max_points) do
      {:ok,
       %{
         from: range.from,
         to: range.to,
         window: range.window,
         bucket_ms: bucket_ms
       }}
    end
  end

  @spec fetch_route_timeseries(binary(), query_params(), module()) ::
          {:ok, map()} | {:error, term()}
  def fetch_route_timeseries(route_id, query_params, client \\ VictoriaMetrics)
      when is_binary(route_id) and is_map(query_params) do
    with {:ok, rows} <-
           fetch_stats_rows(
             client,
             %{"route_id" => route_id},
             ["bytes_in_per_sec", "bytes_out_per_sec"],
             query_params
           ) do
      switches = fetch_route_switches(route_id, query_params, client)
      initial_source_id = fetch_last_source_before_window(route_id, query_params, client)
      srt_quality = fetch_route_srt_quality(route_id, query_params, client)
      srt_health = fetch_route_srt_health(route_id, query_params, client)
      srt_totals = fetch_route_srt_totals(route_id, query_params, client)
      stats_resets = fetch_route_stats_resets(route_id, query_params, client)

      {:ok,
       %{
         points: points_from_rows(rows),
         switches: switches,
         source_timeline:
           source_timeline_from_switches(switches, query_params, initial_source_id),
         srt_quality: srt_quality,
         srt_health: srt_health,
         srt_totals: srt_totals,
         stats_resets: stats_resets,
         meta: analytics_meta(query_params)
       }}
    end
  end

  @spec fetch_node_timeseries(binary(), query_params(), module()) ::
          {:ok, map()} | {:error, term()}
  def fetch_node_timeseries(node_id, query_params, client \\ VictoriaMetrics)
      when is_binary(node_id) and is_map(query_params) do
    node_entity_prefix = "#{node_id}:"

    metric_keys =
      ~w(cpu_util ram_usage swap_usage cpu_la_avg1 cpu_la_avg5 cpu_la_avg15 net_rx_bytes_per_sec net_tx_bytes_per_sec storage_total_bytes storage_used_bytes storage_free_bytes storage_used_percent database_size_bytes)

    with {:ok, rows} <- fetch_stats_rows(client, %{"route_id" => ""}, metric_keys, query_params) do
      filtered_rows =
        Enum.filter(rows, fn row ->
          cond do
            row.entity_type == "node" ->
              row.entity_id == node_id

            row.entity_type in ["net_if", "storage", "database"] ->
              String.starts_with?(to_string(row.entity_id), node_entity_prefix)

            true ->
              false
          end
        end)

      {:ok,
       %{
         points: node_points_from_rows(filtered_rows),
         meta:
           Map.merge(analytics_meta(query_params), %{
             storages: storage_meta_from_rows(filtered_rows),
             databases: database_meta_from_rows(filtered_rows),
             default_storage_id: default_storage_id(filtered_rows)
           })
       }}
    end
  end

  @spec fetch_route_events(binary(), map(), module()) :: {:ok, map()} | {:error, term()}
  def fetch_route_events(route_id, params, client \\ VictoriaMetrics)
      when is_binary(route_id) and is_map(params) do
    limit = parse_int_param(Map.get(params, "limit"), 100)
    offset = parse_int_param(Map.get(params, "offset"), 0)
    type_filter = Map.get(params, "type")

    with {:ok, range} <- parse_range(params),
         {:ok, events} <- fetch_events_result(route_id, range.from, range.to, client) do
      rows =
        events
        |> filter_event_type(type_filter)
        |> Enum.sort_by(& &1["ts"], :desc)

      {:ok,
       %{
         events: rows |> Enum.drop(offset) |> Enum.take(limit),
         meta: %{
           from: DateTime.to_iso8601(range.from),
           to: DateTime.to_iso8601(range.to),
           window: range.window,
           limit: limit,
           offset: offset,
           type: type_filter,
           total: length(rows)
         }
       }}
    end
  end

  @allowed_distinct_columns ~w(level category)

  @spec fetch_route_pipeline_log_distinct(binary(), binary(), module()) ::
          {:ok, [binary()]} | {:error, term()}
  def fetch_route_pipeline_log_distinct(route_id, column, client \\ VictoriaLogs)

  def fetch_route_pipeline_log_distinct(route_id, column, client)
      when is_binary(route_id) and column in @allowed_distinct_columns do
    client.distinct_route_values(route_id, column)
  end

  def fetch_route_pipeline_log_distinct(_route_id, _column, _client),
    do: {:error, {:bad_request, "Invalid column"}}

  @spec fetch_route_pipeline_logs(binary(), map(), module()) ::
          {:ok, map()} | {:error, term()}
  def fetch_route_pipeline_logs(route_id, params, client \\ VictoriaLogs)
      when is_binary(route_id) and is_map(params) do
    limit = parse_limit_param(Map.get(params, "limit"), @default_history_limit)
    offset = parse_int_param(Map.get(params, "offset"), 0)

    level_filters = parse_csv_param(Map.get(params, "levels", ""))
    category_filters = parse_csv_param(Map.get(params, "categories", ""))

    with {:ok, range} <- parse_range(params) do
      with {:ok, %{logs: rows, total: total}} <-
             client.query_route_logs(route_id, %{
               from: range.from,
               to: range.to,
               limit: limit,
               offset: offset,
               levels: level_filters,
               categories: category_filters
             }) do
        {:ok,
         %{
           logs: rows,
           meta: %{
             from: DateTime.to_iso8601(range.from),
             to: DateTime.to_iso8601(range.to),
             window: range.window,
             limit: limit,
             offset: offset,
             levels: level_filters,
             categories: category_filters,
             total: total
           }
         }}
      end
    end
  end

  @spec fetch_routes_status_timeseries(query_params(), module()) ::
          {:ok, map()} | {:error, term()}
  def fetch_routes_status_timeseries(query_params, client \\ VictoriaMetrics)
      when is_map(query_params) do
    with {:ok, routes} <- Db.get_all_routes(false),
         {:ok, seed_rows} <- fetch_route_status_seed_rows(query_params, client),
         {:ok, event_rows} <- fetch_route_status_event_rows(query_params, client) do
      route_statuses = initial_route_statuses(routes, seed_rows)
      allowed_route_ids = MapSet.new(routes, & &1["id"])

      points =
        build_route_status_points(
          route_statuses,
          event_rows,
          query_params.from,
          query_params.to,
          query_params.bucket_ms,
          allowed_route_ids
        )

      {:ok,
       %{
         points: points,
         meta: %{
           from: DateTime.to_iso8601(query_params.from),
           to: DateTime.to_iso8601(query_params.to),
           window: query_params.window,
           bucket_ms: query_params.bucket_ms
         }
       }}
    end
  end

  @spec fetch_routes_status_history(query_params(), map(), module()) ::
          {:ok, map()} | {:error, term()}
  def fetch_routes_status_history(query_params, params, client \\ VictoriaMetrics)
      when is_map(query_params) and is_map(params) do
    limit = parse_limit_param(Map.get(params, "limit"), @default_history_limit)
    offset = parse_int_param(Map.get(params, "offset"), 0)
    route_id_filter = Map.get(params, "route_id")
    status_filter = Map.get(params, "status")
    # Push a concrete route filter into the export matcher so VictoriaMetrics
    # returns only that route's status changes instead of every route's.
    route_matcher = if is_binary(route_id_filter), do: route_id_filter, else: nil

    with {:ok, routes} <- Db.get_all_routes(false),
         {:ok, raw_rows} <-
           fetch_events_by_type(
             route_matcher,
             "route_status_change",
             query_params.from,
             query_params.to,
             client
           ) do
      route_name_by_id =
        Enum.reduce(routes, %{}, fn route, acc ->
          route_id = route["id"]
          route_name = route["name"]

          if is_binary(route_id) do
            Map.put(acc, route_id, route_name)
          else
            acc
          end
        end)

      rows =
        raw_rows
        |> Enum.filter(fn row ->
          (is_nil(route_id_filter) or row["route_id"] == route_id_filter) and
            (is_nil(status_filter) or row["new_status"] == status_filter)
        end)
        |> Enum.sort_by(& &1["ts"], :desc)

      events =
        rows
        |> Enum.drop(offset)
        |> Enum.take(limit)
        |> Enum.map(fn row ->
          route_id = row["route_id"]

          %{
            "ts" => row["ts"],
            "route_id" => route_id,
            "route_name" => Map.get(route_name_by_id, route_id),
            "old_status" => row["old_status"],
            "new_status" => row["new_status"]
          }
        end)

      {:ok,
       %{
         events: events,
         meta: %{
           from: DateTime.to_iso8601(query_params.from),
           to: DateTime.to_iso8601(query_params.to),
           window: query_params.window,
           limit: limit,
           offset: offset,
           route_id: route_id_filter,
           status: status_filter,
           total: length(rows)
         }
       }}
    end
  end

  @spec parse_range(map()) ::
          {:ok, %{from: DateTime.t(), to: DateTime.t(), window: binary()}}
          | {:error, {:bad_request, binary()}}
  def parse_range(params) when is_map(params) do
    from_raw = Map.get(params, "from")
    to_raw = Map.get(params, "to")

    cond do
      is_binary(from_raw) and is_binary(to_raw) ->
        with {:ok, from_dt} <- parse_datetime(from_raw),
             {:ok, to_dt} <- parse_datetime(to_raw),
             :ok <- validate_range_order(from_dt, to_dt) do
          {:ok, %{from: from_dt, to: to_dt, window: "custom"}}
        end

      true ->
        window = Map.get(params, "window", "last_hour")

        case Map.fetch(@window_to_seconds, window) do
          {:ok, seconds} ->
            to_dt = DateTime.utc_now()
            from_dt = DateTime.add(to_dt, -seconds, :second)
            {:ok, %{from: from_dt, to: to_dt, window: window}}

          :error ->
            {:error,
             {:bad_request,
              "Invalid window. Allowed: last_30_min, last_hour, last_6_hour, last_24_hour"}}
        end
    end
  end

  @spec parse_datetime(binary()) :: {:ok, DateTime.t()} | {:error, {:bad_request, binary()}}
  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _reason} ->
        {:error, {:bad_request, "Invalid datetime format. Use ISO8601"}}
    end
  end

  @spec validate_range_order(DateTime.t(), DateTime.t()) ::
          :ok | {:error, {:bad_request, binary()}}
  def validate_range_order(from_dt, to_dt) do
    if DateTime.compare(from_dt, to_dt) == :lt do
      :ok
    else
      {:error, {:bad_request, "Invalid range: from must be earlier than to"}}
    end
  end

  @spec bucket_ms_for_range(DateTime.t(), DateTime.t(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, {:bad_request, binary()}}
  def bucket_ms_for_range(from_dt, to_dt, max_points \\ @default_max_points) do
    range_seconds = DateTime.diff(to_dt, from_dt, :second)

    if range_seconds <= 0 do
      {:error, {:bad_request, "Invalid range: from must be earlier than to"}}
    else
      normalized_max_points = parse_max_points(max_points, @default_max_points)
      range_ms = range_seconds * 1_000
      raw_bucket_ms = ceil(range_ms / normalized_max_points)
      {:ok, normalize_bucket_ms(raw_bucket_ms)}
    end
  end

  defp normalize_bucket_ms(raw_bucket_ms) when is_integer(raw_bucket_ms) and raw_bucket_ms > 0 do
    [
      @bucket_10_seconds_ms,
      @bucket_30_seconds_ms,
      @bucket_1_minute_ms,
      @bucket_5_minutes_ms,
      @bucket_15_minutes_ms,
      @bucket_30_minutes_ms,
      @bucket_1_hour_ms
    ]
    |> Enum.find(@bucket_1_hour_ms, fn bucket -> bucket >= raw_bucket_ms end)
  end

  defp parse_max_points(nil, default), do: default

  defp parse_max_points(value, _default) when is_integer(value) do
    value
    |> max(@min_max_points)
    |> min(@max_max_points)
  end

  defp parse_max_points(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} ->
        parse_max_points(parsed, default)

      _ ->
        default
    end
  end

  defp parse_max_points(_value, default), do: default

  @spec value_at(map(), binary(), integer()) :: term()
  def value_at(columns, key, index)
      when is_map(columns) and is_binary(key) and is_integer(index) do
    columns
    |> Map.get(key, [])
    |> Enum.at(index)
  end

  @spec points_from_rows([map()]) :: [map()]
  def points_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      timestamp = normalize_timestamp(row.bucket_ts)
      current = Map.get(acc, timestamp, %{timestamp: timestamp, source: nil, destinations: %{}})
      metric_value = number_or_nil(row.metric_value)

      updated =
        case row.entity_type do
          "source" ->
            %{current | source: metric_value}

          "destination" ->
            destination_id = row.entity_id

            if is_binary(destination_id) and destination_id != "" do
              %{
                current
                | destinations: Map.put(current.destinations, destination_id, metric_value)
              }
            else
              current
            end

          _ ->
            current
        end

      Map.put(acc, timestamp, updated)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.timestamp)
  end

  @spec normalize_timestamp(term()) :: binary()
  def normalize_timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def normalize_timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  def normalize_timestamp(value), do: to_string(value)

  @spec number_or_nil(term()) :: float() | nil
  def number_or_nil(value) when is_integer(value), do: value * 1.0
  def number_or_nil(value) when is_float(value), do: value
  def number_or_nil(_value), do: nil

  @spec analytics_meta(query_params()) :: map()
  def analytics_meta(query_params) when is_map(query_params) do
    %{
      from: DateTime.to_iso8601(query_params.from),
      to: DateTime.to_iso8601(query_params.to),
      window: query_params.window,
      bucket_ms: query_params.bucket_ms
    }
  end

  @spec fetch_stats_rows(module(), map(), [binary()], query_params()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_stats_rows(client, labels, metric_keys, query_params)
      when is_atom(client) and is_map(labels) and is_list(metric_keys) and is_map(query_params) do
    fetch_stats_rows(client, labels, metric_keys, query_params, :avg)
  end

  @spec fetch_stats_rows(module(), map(), [binary()], query_params(), :avg | :max | :last) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_stats_rows(client, labels, metric_keys, query_params, aggregation)
      when is_atom(client) and is_map(labels) and is_list(metric_keys) and is_map(query_params) and
             aggregation in [:avg, :max, :last] do
    bucket_seconds = max(div(query_params.bucket_ms, 1_000), 1)
    selector = stats_selector(labels, metric_keys)
    query = "#{aggregation_function(aggregation)}(#{selector}[#{bucket_seconds}s])"

    case client.query_range(query, query_params.from, query_params.to, bucket_seconds) do
      {:ok, series} -> {:ok, stats_rows_from_series(series)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec aggregation_function(:avg | :max | :last) :: binary()
  defp aggregation_function(:avg), do: "avg_over_time"
  defp aggregation_function(:max), do: "max_over_time"
  defp aggregation_function(:last), do: "last_over_time"

  @spec stats_selector(map(), [binary()]) :: binary()
  def stats_selector(labels, metric_keys) when is_map(labels) and is_list(metric_keys) do
    matchers =
      labels
      |> Enum.map(fn {key, value} -> "#{key}=#{VictoriaMetrics.inspect_label_value(value)}" end)
      |> Kernel.++([metric_key_matcher(metric_keys)])
      |> Enum.reject(&is_nil/1)
      |> Enum.join(",")

    "#{VictoriaMetrics.stats_metric()}{#{matchers}}"
  end

  @spec metric_key_matcher([binary()]) :: binary() | nil
  def metric_key_matcher([]), do: nil
  def metric_key_matcher([key]), do: "metric_key=#{VictoriaMetrics.inspect_label_value(key)}"

  def metric_key_matcher(keys) when is_list(keys) do
    escaped = Enum.map_join(keys, "|", &Regex.escape/1)
    "metric_key=~#{VictoriaMetrics.inspect_label_value(escaped)}"
  end

  @spec stats_rows_from_series([map()]) :: [map()]
  def stats_rows_from_series(series) when is_list(series) do
    Enum.flat_map(series, fn %{"metric" => labels, "values" => values} ->
      Enum.map(values || [], fn [unix_ts, value] ->
        %{
          bucket_ts: unix_to_datetime(unix_ts),
          entity_type: Map.get(labels, "entity_type"),
          entity_id: Map.get(labels, "entity_id"),
          metric_key: Map.get(labels, "metric_key"),
          metric_value: parse_float(value)
        }
      end)
    end)
  end

  @spec unix_to_datetime(number()) :: DateTime.t()
  def unix_to_datetime(value) when is_integer(value), do: DateTime.from_unix!(value, :second)
  def unix_to_datetime(value) when is_float(value), do: DateTime.from_unix!(trunc(value), :second)

  @spec parse_float(term()) :: float() | nil
  def parse_float(value) when is_float(value), do: value
  def parse_float(value) when is_integer(value), do: value * 1.0

  def parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  def parse_float(_value), do: nil

  @spec fetch_events_result(binary() | nil, DateTime.t(), DateTime.t(), module()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_events_result(route_id, from, to, client \\ VictoriaMetrics) do
    fetch_events_with_labels(event_labels(route_id), from, to, client)
  end

  # Exports events for a specific set of route ids in a single HTTP call using a
  # regex-alternation matcher (route_id=~"^(id1|id2|...)$"). Callers with a small,
  # bounded route set use this to avoid exporting every route's events.
  @spec fetch_events_for_route_ids([binary()], DateTime.t(), DateTime.t(), module()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_events_for_route_ids(route_ids, from, to, client \\ VictoriaMetrics)
      when is_list(route_ids) do
    match_expr = VictoriaMetrics.event_selector_for_route_ids(route_ids)

    case client.export_series(match_expr, from, to) do
      {:ok, series} -> {:ok, event_rows_from_export(series)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Legacy wrapper: returns [] on backend errors. Callers that need to
  # distinguish "no events" from "backend down" should use fetch_events_result/4.
  @spec fetch_events(binary() | nil, DateTime.t(), DateTime.t(), module()) :: [map()]
  def fetch_events(route_id, from, to, client \\ VictoriaMetrics) do
    case fetch_events_result(route_id, from, to, client) do
      {:ok, events} -> events
      {:error, _reason} -> []
    end
  end

  # Returns {:ok, events} | {:error, reason}. Callers that feed Dashboard
  # availability (status seed/event rows, status history) must propagate the
  # error so a backend outage cannot masquerade as an empty result. Callers that
  # only decorate an already-guarded payload (route timeseries switches/initial
  # source) may collapse errors to their empty value locally.
  @spec fetch_events_by_type(binary() | nil, binary(), DateTime.t(), DateTime.t(), module()) ::
          {:ok, [map()]} | {:error, term()}
  defp fetch_events_by_type(route_id, event_type, from, to, client) do
    labels = route_id |> event_labels() |> Map.put("event_type", event_type)
    fetch_events_with_labels(labels, from, to, client)
  end

  defp fetch_events_with_labels(labels, from, to, client) when is_map(labels) do
    match_expr = VictoriaMetrics.selector(VictoriaMetrics.event_metric(), labels)

    case client.export_series(match_expr, from, to) do
      {:ok, series} -> {:ok, event_rows_from_export(series)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_labels(nil), do: %{}
  defp event_labels(route_id), do: %{"route_id" => route_id}

  @spec event_rows_from_export([map()]) :: [map()]
  def event_rows_from_export(series) when is_list(series) do
    Enum.flat_map(series, fn %{"metric" => labels, "timestamps" => timestamps} ->
      Enum.map(timestamps || [], fn ts_ms ->
        event_row_from_labels(labels, normalize_export_ts_ms(ts_ms))
      end)
    end)
  end

  @spec normalize_export_ts_ms(term()) :: integer()
  def normalize_export_ts_ms(value) when is_integer(value), do: value
  def normalize_export_ts_ms(value) when is_float(value), do: trunc(value)

  def normalize_export_ts_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    end
  end

  def normalize_export_ts_ms(_value), do: DateTime.utc_now() |> DateTime.to_unix(:millisecond)

  @spec event_row_from_labels(map(), integer()) :: map()
  def event_row_from_labels(labels, ts_ms) when is_map(labels) do
    old_status = empty_to_nil(Map.get(labels, "old_status"))
    new_status = empty_to_nil(Map.get(labels, "new_status"))

    # Prefer the full details_json label written on the event path. Fall back to
    # reconstructing it from old_status/new_status for events stored before the
    # details_json label existed.
    details_json =
      empty_to_nil(Map.get(labels, "details_json")) ||
        status_details_json(old_status, new_status)

    %{
      "ts" => ms_to_iso8601(ts_ms),
      "route_id" => empty_to_nil(Map.get(labels, "route_id")),
      "event_type" => empty_to_nil(Map.get(labels, "event_type")) || "unknown",
      "severity" => empty_to_nil(Map.get(labels, "severity")) || "info",
      "source_id" => empty_to_nil(Map.get(labels, "source_id")),
      "from_source_id" => empty_to_nil(Map.get(labels, "from_source_id")),
      "to_source_id" => empty_to_nil(Map.get(labels, "to_source_id")),
      "reason" => empty_to_nil(Map.get(labels, "reason")),
      "message" => empty_to_nil(Map.get(labels, "message")),
      "details_json" => details_json,
      "old_status" => old_status,
      "new_status" => new_status
    }
  end

  @spec status_details_json(binary() | nil, binary() | nil) :: binary() | nil
  def status_details_json(old_status, new_status)
      when is_binary(old_status) or is_binary(new_status) do
    Jason.encode!(%{"old_status" => old_status, "new_status" => new_status})
  end

  def status_details_json(_old_status, _new_status), do: nil

  @spec empty_to_nil(term()) :: term() | nil
  def empty_to_nil(""), do: nil
  def empty_to_nil(value), do: value

  @spec filter_event_type([map()], binary() | nil) :: [map()]
  def filter_event_type(rows, nil), do: rows
  def filter_event_type(rows, ""), do: rows

  def filter_event_type(rows, type_filter) when is_list(rows) and is_binary(type_filter) do
    Enum.filter(rows, &(&1["event_type"] == type_filter))
  end

  @spec fetch_route_switches(binary(), query_params(), module()) :: [map()]
  def fetch_route_switches(route_id, query_params, client)
      when is_binary(route_id) and is_map(query_params) do
    case fetch_events_by_type(
           route_id,
           "source_switch",
           query_params.from,
           query_params.to,
           client
         ) do
      {:ok, events} ->
        events
        |> Enum.map(fn row ->
          %{
            "ts" => row["ts"],
            "from_source_id" => row["from_source_id"],
            "to_source_id" => row["to_source_id"],
            "reason" => row["reason"]
          }
        end)
        |> Enum.sort_by(& &1["ts"])

      {:error, _reason} ->
        []
    end
  end

  @spec source_timeline_from_switches([map()], query_params()) :: [map()]
  def source_timeline_from_switches(switches, query_params),
    do: source_timeline_from_switches(switches, query_params, nil)

  @spec source_timeline_from_switches([map()], query_params(), binary() | nil) :: [map()]
  def source_timeline_from_switches([], query_params, initial_source_id)
      when is_map(query_params) and is_binary(initial_source_id) do
    [
      %{
        "from" => normalize_timestamp(query_params.from),
        "to" => DateTime.to_iso8601(query_params.to),
        "source_id" => initial_source_id
      }
    ]
  end

  def source_timeline_from_switches([], _query_params, _initial_source_id), do: []

  def source_timeline_from_switches(switches, query_params, initial_source_id)
      when is_list(switches) and is_map(query_params) do
    inferred_from =
      case List.first(switches) do
        %{"ts" => ts} -> ts
        _ -> query_params.to
      end

    from_ts = Map.get(query_params, :from, inferred_from) |> normalize_timestamp()
    to_ts = DateTime.to_iso8601(query_params.to)
    first_switch = List.first(switches) || %{}

    first_source =
      initial_source_id || Map.get(first_switch, "from_source_id") ||
        Map.get(first_switch, "to_source_id")

    {segments, _current_from, _current_source} =
      Enum.reduce(switches, {[], from_ts, first_source}, fn switch,
                                                            {segments, current_from,
                                                             current_source} ->
        ts = Map.get(switch, "ts") |> normalize_timestamp()
        to_source = Map.get(switch, "to_source_id")

        cond do
          is_nil(current_source) ->
            {segments, ts, to_source}

          current_source != to_source ->
            next_segment = %{"from" => current_from, "to" => ts, "source_id" => current_source}
            {[next_segment | segments], ts, to_source}

          true ->
            {segments, current_from, current_source}
        end
      end)

    last_switch = List.last(switches) || %{}

    end_segment =
      case last_switch do
        %{"to_source_id" => source_id} when is_binary(source_id) ->
          [
            %{
              "from" => normalize_timestamp(Map.get(last_switch, "ts")),
              "to" => to_ts,
              "source_id" => source_id
            }
          ]

        _ ->
          []
      end

    (Enum.reverse(segments) ++ end_segment)
    |> Enum.reject(fn segment -> is_nil(segment["source_id"]) end)
  end

  defp fetch_last_source_before_window(route_id, query_params, client) do
    case fetch_events_by_type(
           route_id,
           "source_switch",
           seed_start_before(query_params.from),
           query_params.from,
           client
         ) do
      {:ok, events} ->
        events
        |> Enum.sort_by(& &1["ts"], :desc)
        |> List.first(%{})
        |> Map.get("to_source_id")

      {:error, _reason} ->
        nil
    end
  end

  defp parse_int_param(nil, default), do: default

  defp parse_int_param(value, _default) when is_integer(value) and value >= 0, do: value

  defp parse_int_param(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp parse_int_param(_value, default), do: default

  defp parse_limit_param(nil, default), do: default

  defp parse_limit_param(value, default) when is_integer(value) do
    if value > 0, do: min(value, @max_history_limit), else: default
  end

  defp parse_limit_param(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> min(parsed, @max_history_limit)
      _ -> default
    end
  end

  defp parse_limit_param(_value, default), do: default

  defp parse_csv_param(nil), do: []
  defp parse_csv_param(""), do: []

  defp parse_csv_param(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp fetch_route_status_seed_rows(query_params, client) do
    case fetch_events_by_type(
           nil,
           "route_status_change",
           seed_start_before(query_params.from),
           query_params.from,
           client
         ) do
      {:ok, events} ->
        rows =
          events
          |> Enum.reject(&is_nil(&1["new_status"]))
          |> Enum.group_by(& &1["route_id"])
          |> Enum.map(fn {_route_id, grouped_events} ->
            grouped_events
            |> Enum.sort_by(& &1["ts"], :desc)
            |> List.first()
            |> route_status_row_from_event()
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, rows}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seed_start_before(%DateTime{} = window_start) do
    retention_start =
      DateTime.utc_now()
      |> DateTime.add(-analytics_retention_seconds(), :second)

    case DateTime.compare(retention_start, window_start) do
      :lt -> retention_start
      _ -> window_start
    end
  end

  defp analytics_retention_seconds do
    Application.get_env(:hydra_srt, :analytics_retention_seconds, 3 * 24 * 60 * 60)
  end

  defp fetch_route_status_event_rows(query_params, client) do
    case fetch_events_by_type(
           nil,
           "route_status_change",
           query_params.from,
           query_params.to,
           client
         ) do
      {:ok, events} ->
        rows =
          events
          |> Enum.map(&route_status_row_from_event/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(fn row -> {row["ts_ms"], row["route_id"]} end)

        {:ok, rows}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_status_row_from_event(nil), do: nil

  defp route_status_row_from_event(event) when is_map(event) do
    route_id = event["route_id"]
    ts_ms = timestamp_to_ms(event["ts"])
    status = event["new_status"] || extract_new_status_from_details(event["details_json"])

    if is_binary(route_id) and is_integer(ts_ms) and is_binary(status) do
      %{"route_id" => route_id, "ts_ms" => ts_ms, "status" => status}
    end
  end

  defp initial_route_statuses(routes, seed_rows) when is_list(routes) and is_list(seed_rows) do
    base =
      Enum.reduce(routes, %{}, fn route, acc ->
        route_id = route["id"]
        status = normalize_route_status(route["schema_status"] || route["status"] || "stopped")
        Map.put(acc, route_id, status)
      end)

    Enum.reduce(seed_rows, base, fn %{"route_id" => route_id, "status" => status}, acc ->
      case Map.fetch(acc, route_id) do
        :error -> acc
        {:ok, _} -> Map.put(acc, route_id, normalize_route_status(status))
      end
    end)
  end

  @doc false
  @spec route_status_point_series(
          map(),
          [map()],
          DateTime.t(),
          DateTime.t(),
          pos_integer(),
          MapSet.t()
        ) ::
          [map()]
  def route_status_point_series(
        route_statuses,
        event_rows,
        from_dt,
        to_dt,
        bucket_ms,
        allowed_route_ids
      )
      when is_map(route_statuses) and is_list(event_rows) and is_integer(bucket_ms) and
             bucket_ms > 0 and is_struct(allowed_route_ids, MapSet) do
    build_route_status_points(
      route_statuses,
      event_rows,
      from_dt,
      to_dt,
      bucket_ms,
      allowed_route_ids
    )
  end

  defp build_route_status_points(
         route_statuses,
         event_rows,
         from_dt,
         to_dt,
         bucket_ms,
         allowed_route_ids
       )
       when is_map(route_statuses) and is_list(event_rows) and is_integer(bucket_ms) and
              bucket_ms > 0 and is_struct(allowed_route_ids, MapSet) do
    from_ms = DateTime.to_unix(from_dt, :millisecond)
    to_ms = DateTime.to_unix(to_dt, :millisecond)
    start_ms = ceil_ts_to_bucket(from_ms, bucket_ms)
    end_ms = ceil_ts_to_bucket(to_ms, bucket_ms)
    sorted_events = Enum.sort_by(event_rows, & &1["ts_ms"])

    if start_ms > end_ms do
      []
    else
      {points_reversed, _statuses, _events_left} =
        Enum.reduce(
          start_ms..end_ms//bucket_ms,
          {[], route_statuses, sorted_events},
          fn bucket_ts_ms, {points, statuses, events_left} ->
            apply_until_ms = min(bucket_ts_ms, to_ms)

            {updated_statuses, remaining_events} =
              apply_events_until_bucket(statuses, events_left, apply_until_ms, allowed_route_ids)

            point =
              updated_statuses
              |> status_counts()
              |> Map.put(:timestamp, ms_to_iso8601(apply_until_ms))

            {[point | points], updated_statuses, remaining_events}
          end
        )

      Enum.reverse(points_reversed)
    end
  end

  defp apply_events_until_bucket(statuses, events, bucket_ts_ms, allowed_route_ids) do
    do_apply_events_until_bucket(statuses, events, bucket_ts_ms, allowed_route_ids)
  end

  defp do_apply_events_until_bucket(statuses, [], _bucket_ts_ms, _allowed_route_ids),
    do: {statuses, []}

  defp do_apply_events_until_bucket(statuses, [event | rest], bucket_ts_ms, allowed_route_ids) do
    if event["ts_ms"] <= bucket_ts_ms do
      next_statuses =
        if MapSet.member?(allowed_route_ids, event["route_id"]) do
          Map.put(statuses, event["route_id"], normalize_route_status(event["status"]))
        else
          statuses
        end

      do_apply_events_until_bucket(next_statuses, rest, bucket_ts_ms, allowed_route_ids)
    else
      {statuses, [event | rest]}
    end
  end

  defp status_counts(statuses) when is_map(statuses) do
    Enum.reduce(
      statuses,
      %{
        processing: 0,
        starting: 0,
        reconnecting: 0,
        restarting: 0,
        failed: 0,
        stopped: 0,
        other: 0
      },
      fn
        {_route_id, "processing"}, acc -> Map.update!(acc, :processing, &(&1 + 1))
        {_route_id, "starting"}, acc -> Map.update!(acc, :starting, &(&1 + 1))
        {_route_id, "reconnecting"}, acc -> Map.update!(acc, :reconnecting, &(&1 + 1))
        {_route_id, "restarting"}, acc -> Map.update!(acc, :restarting, &(&1 + 1))
        {_route_id, "failed"}, acc -> Map.update!(acc, :failed, &(&1 + 1))
        {_route_id, "stopped"}, acc -> Map.update!(acc, :stopped, &(&1 + 1))
        {_route_id, _status}, acc -> Map.update!(acc, :other, &(&1 + 1))
      end
    )
  end

  defp extract_new_status_from_details(details_json) when is_binary(details_json) do
    case Jason.decode(details_json) do
      {:ok, %{"new_status" => status}} when is_binary(status) -> status
      _ -> nil
    end
  end

  defp extract_new_status_from_details(_value), do: nil

  defp timestamp_to_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

  defp timestamp_to_ms(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp timestamp_to_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp timestamp_to_ms(_value), do: nil

  defp align_ts_to_bucket(ts_ms, bucket_ms)
       when is_integer(ts_ms) and is_integer(bucket_ms) and bucket_ms > 0 do
    div(ts_ms, bucket_ms) * bucket_ms
  end

  defp ceil_ts_to_bucket(ts_ms, bucket_ms)
       when is_integer(ts_ms) and is_integer(bucket_ms) and bucket_ms > 0 do
    aligned = align_ts_to_bucket(ts_ms, bucket_ms)
    if aligned == ts_ms, do: aligned, else: aligned + bucket_ms
  end

  defp ms_to_iso8601(ts_ms) when is_integer(ts_ms) do
    ts_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp normalize_route_status(status) when is_binary(status) do
    case String.downcase(status) do
      "started" -> "processing"
      "stopping" -> "stopped"
      value -> value
    end
  end

  defp normalize_route_status(_status), do: "other"

  defp fetch_route_srt_quality(route_id, query_params, client) do
    case fetch_stats_rows(
           client,
           %{"route_id" => route_id, "entity_type" => "source"},
           ["srt_packet_loss", "srt_rtt_ms"],
           query_params
         ) do
      {:ok, rows} ->
        rows
        |> Enum.map(fn row ->
          %{
            "timestamp" => normalize_timestamp(row.bucket_ts),
            "source_id" => row.entity_id,
            "metric_key" => row.metric_key,
            "value" => number_or_nil(row.metric_value)
          }
        end)
        |> Enum.reject(fn row ->
          is_nil(row["timestamp"]) or is_nil(row["source_id"]) or is_nil(row["metric_key"])
        end)

      {:error, _reason} ->
        []
    end
  end

  @spec fetch_route_srt_health(binary(), query_params(), module()) :: [map()]
  def fetch_route_srt_health(route_id, query_params, client \\ VictoriaMetrics) do
    avg_metric_keys =
      ~w(srt_rtt_ms srt_negotiated_latency_ms srt_bandwidth_mbps srt_rate_mbps srt_packet_loss srt_packet_loss_percent srt_retransmitted_packets_per_sec srt_dropped_packets_per_sec srt_nack_packets_per_sec)

    max_metric_keys =
      ~w(srt_rtt_ms_max srt_packet_loss_percent_max srt_retransmitted_packets_per_sec_max srt_dropped_packets_per_sec_max srt_nack_packets_per_sec_max)

    with {:ok, avg_rows} <-
           fetch_stats_rows(client, %{"route_id" => route_id}, avg_metric_keys, query_params),
         rows = health_rows(avg_rows),
         max_rows <- fetch_health_max_rows(client, route_id, max_metric_keys, query_params) do
      (rows ++ max_rows)
      |> srt_health_points_from_rows()
    else
      {:error, _reason} -> []
    end
  end

  @spec health_rows([map()]) :: [map()]
  defp health_rows(rows) when is_list(rows) do
    rows
    |> Enum.filter(&(&1.entity_type in ["source", "destination"]))
    |> Enum.map(fn row ->
      %{
        timestamp: normalize_timestamp(row.bucket_ts),
        entity_type: row.entity_type,
        entity_id: row.entity_id,
        metric_key: row.metric_key,
        value: number_or_nil(row.metric_value)
      }
    end)
  end

  @spec fetch_health_max_rows(module(), binary(), [binary()], query_params()) :: [map()]
  defp fetch_health_max_rows(client, route_id, metric_keys, query_params) do
    case fetch_stats_rows(
           client,
           %{"route_id" => route_id},
           metric_keys,
           query_params,
           :max
         ) do
      {:ok, rows} ->
        health_rows(rows)

      {:error, reason} ->
        Logger.warning("Failed to fetch route SRT health maxima: #{inspect(reason)}")
        []
    end
  end

  @spec fetch_route_srt_totals(binary(), query_params(), module()) :: [map()]
  def fetch_route_srt_totals(route_id, query_params, client \\ VictoriaMetrics)
      when is_binary(route_id) and is_map(query_params) do
    metric_keys =
      ~w(srt_packets_total srt_packets_lost_total srt_packets_retransmitted_total srt_packets_dropped_total srt_nack_total srt_bytes_total)

    case fetch_stats_rows(
           client,
           %{"route_id" => route_id},
           metric_keys,
           query_params,
           :last
         ) do
      {:ok, rows} -> srt_totals_from_rows(rows)
      {:error, _reason} -> []
    end
  end

  @spec positive_increase([number()]) :: number()
  def positive_increase([]), do: 0
  def positive_increase([_value]), do: 0

  def positive_increase([first | rest]) when is_number(first) do
    {_last, increase} =
      Enum.reduce(rest, {first, 0}, fn value, {previous, increase} when is_number(value) ->
        if value > previous do
          {value, increase + value - previous}
        else
          {value, increase}
        end
      end)

    increase
  end

  @spec srt_totals_from_rows([map()]) :: [map()]
  defp srt_totals_from_rows(rows) when is_list(rows) do
    metric_fields = %{
      "srt_packets_total" => :packets_total,
      "srt_packets_lost_total" => :packets_lost_total,
      "srt_packets_retransmitted_total" => :packets_retransmitted_total,
      "srt_packets_dropped_total" => :packets_dropped_total,
      "srt_nack_total" => :nack_total,
      "srt_bytes_total" => :bytes_total
    }

    rows =
      Enum.filter(rows, fn row ->
        row.entity_type in ["source", "destination"] and
          Map.has_key?(metric_fields, row.metric_key)
      end)

    grouped_rows =
      Enum.group_by(rows, fn row -> {row.entity_type, row.entity_id, row.metric_key} end)

    rows
    |> Enum.map(fn row -> {row.entity_type, row.entity_id} end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {entity_type, entity_id} ->
      totals =
        Enum.reduce(metric_fields, %{}, fn {metric_key, field}, acc ->
          value =
            case Map.fetch(grouped_rows, {entity_type, entity_id, metric_key}) do
              {:ok, metric_rows} -> metric_increase(metric_rows)
              :error -> nil
            end

          Map.put(acc, field, value)
        end)

      Map.merge(
        %{entity_type: entity_type, entity_id: entity_id},
        Map.put(totals, :loss_percent, loss_percent(entity_type, totals))
      )
    end)
  end

  @spec metric_increase([map()]) :: number() | nil
  defp metric_increase(rows) when is_list(rows) do
    values =
      rows
      |> Enum.sort_by(fn row -> DateTime.to_unix(row.bucket_ts, :microsecond) end)
      |> Enum.map(& &1.metric_value)

    if Enum.all?(values, &is_number/1), do: positive_increase(values), else: nil
  end

  @spec loss_percent(binary(), map()) :: float() | nil
  defp loss_percent("source", totals) when is_map(totals) do
    calculate_loss_percent(totals[:packets_total], totals[:packets_lost_total], fn total, lost ->
      total + lost
    end)
  end

  defp loss_percent("destination", totals) when is_map(totals) do
    calculate_loss_percent(totals[:packets_total], totals[:packets_lost_total], fn total, _lost ->
      total
    end)
  end

  @spec calculate_loss_percent(number() | nil, number() | nil, (number(), number() -> number())) ::
          float() | nil
  defp calculate_loss_percent(total, lost, denominator_fun)
       when is_function(denominator_fun, 2) do
    if is_number(total) and is_number(lost) do
      denominator = denominator_fun.(total, lost)
      if denominator == 0, do: nil, else: lost / denominator * 100
    end
  end

  @spec fetch_route_stats_resets(binary(), query_params(), module()) :: [map()]
  def fetch_route_stats_resets(route_id, query_params, client \\ VictoriaMetrics)
      when is_binary(route_id) and is_map(query_params) do
    case fetch_events_by_type(
           route_id,
           "stats_reset",
           query_params.from,
           query_params.to,
           client
         ) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1["event_type"] == "stats_reset"))
        |> Enum.map(fn row ->
          %{
            "timestamp" => row["ts"],
            "reason" => stats_reset_reason(row)
          }
        end)
        |> Enum.sort_by(& &1["timestamp"])

      {:error, _reason} ->
        []
    end
  end

  @spec stats_reset_reason(map()) :: binary() | nil
  defp stats_reset_reason(row) when is_map(row) do
    row["reason"] || row["action"] || stats_reset_reason_from_details(row["details_json"])
  end

  @spec stats_reset_reason_from_details(term()) :: binary() | nil
  defp stats_reset_reason_from_details(details_json) when is_binary(details_json) do
    case Jason.decode(details_json) do
      {:ok, details} when is_map(details) -> details["action"] || details["reason"]
      _ -> nil
    end
  end

  defp stats_reset_reason_from_details(_details_json), do: nil

  def srt_health_points_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      key = {row.timestamp, row.entity_type, row.entity_id}

      point =
        Map.get(acc, key, %{
          timestamp: row.timestamp,
          entity_type: row.entity_type,
          entity_id: row.entity_id
        })

      field =
        case row.metric_key do
          "srt_packet_loss" -> "packets_lost_total"
          "srt_packet_loss_percent" -> "packet_loss_percent"
          metric_key -> String.replace_prefix(metric_key, "srt_", "")
        end

      Map.put(acc, key, Map.put(point, field, row.value))
    end)
    |> Map.values()
    |> Enum.sort_by(fn point -> {point.timestamp, point.entity_type, point.entity_id} end)
  end

  defp node_points_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      timestamp = normalize_timestamp(row.bucket_ts)

      current =
        Map.get(acc, timestamp, %{
          timestamp: timestamp,
          cpu: nil,
          ram: nil,
          swap: nil,
          la_avg1: nil,
          la_avg5: nil,
          la_avg15: nil
        })

      value = number_or_nil(row.metric_value)

      updated =
        cond do
          row.entity_type == "node" and row.metric_key == "cpu_util" ->
            Map.put(current, :cpu, value)

          row.entity_type == "node" and row.metric_key == "ram_usage" ->
            Map.put(current, :ram, value)

          row.entity_type == "node" and row.metric_key == "swap_usage" ->
            Map.put(current, :swap, value)

          row.entity_type == "node" and row.metric_key == "cpu_la_avg1" ->
            Map.put(current, :la_avg1, value)

          row.entity_type == "node" and row.metric_key == "cpu_la_avg5" ->
            Map.put(current, :la_avg5, value)

          row.entity_type == "node" and row.metric_key == "cpu_la_avg15" ->
            Map.put(current, :la_avg15, value)

          row.entity_type == "net_if" and row.metric_key == "net_rx_bytes_per_sec" ->
            case net_interface_name(row.entity_id) do
              nil -> current
              interface_name -> Map.put(current, "net_in_#{interface_name}", value)
            end

          row.entity_type == "net_if" and row.metric_key == "net_tx_bytes_per_sec" ->
            case net_interface_name(row.entity_id) do
              nil -> current
              interface_name -> Map.put(current, "net_out_#{interface_name}", value)
            end

          row.entity_type == "storage" ->
            case storage_point_key(row.entity_id, row.metric_key) do
              nil -> current
              key -> Map.put(current, key, value)
            end

          row.entity_type == "database" and row.metric_key == "database_size_bytes" ->
            case database_name(row.entity_id) do
              nil ->
                current

              database ->
                storage_id = OsMon.database_id(database)

                current
                |> Map.put("storage_total_#{storage_id}", value)
                |> Map.put("storage_used_#{storage_id}", value)
                |> Map.put("storage_free_#{storage_id}", 0.0)
                |> Map.put("storage_used_percent_#{storage_id}", 100.0)
            end

          true ->
            current
        end

      Map.put(acc, timestamp, updated)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.timestamp)
  end

  defp net_interface_name(entity_id) when is_binary(entity_id) do
    case String.split(entity_id, ":", parts: 2) do
      [_node, interface_name] when interface_name != "" -> interface_name
      _ -> entity_id
    end
  end

  defp net_interface_name(_entity_id), do: nil

  def storage_point_key(entity_id, metric_key)
      when is_binary(entity_id) and is_binary(metric_key) do
    with mountpoint when is_binary(mountpoint) <- storage_mountpoint(entity_id),
         field_prefix when is_binary(field_prefix) <- storage_field_prefix(metric_key) do
      "#{field_prefix}_#{OsMon.storage_id(mountpoint)}"
    else
      _ -> nil
    end
  end

  def storage_point_key(_entity_id, _metric_key), do: nil

  def storage_field_prefix("storage_total_bytes"), do: "storage_total"
  def storage_field_prefix("storage_used_bytes"), do: "storage_used"
  def storage_field_prefix("storage_free_bytes"), do: "storage_free"
  def storage_field_prefix("storage_used_percent"), do: "storage_used_percent"
  def storage_field_prefix(_metric_key), do: nil

  def storage_meta_from_rows(rows) when is_list(rows) do
    storage_rows =
      rows
      |> Enum.filter(&(&1.entity_type == "storage"))
      |> Enum.map(&storage_mountpoint(&1.entity_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn mountpoint ->
        %{id: OsMon.storage_id(mountpoint), mountpoint: mountpoint, type: "mountpoint"}
      end)

    storage_rows ++ database_meta_from_rows(rows)
  end

  def database_meta_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.filter(&(&1.entity_type == "database"))
    |> Enum.map(&database_name(&1.entity_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn database ->
      %{
        id: OsMon.database_id(database),
        mountpoint: database_display_name(database),
        name: database_display_name(database),
        type: "database"
      }
    end)
  end

  def default_storage_id(rows, anchor_paths \\ nil)

  def default_storage_id(rows, anchor_paths) when is_list(rows) do
    storages = Enum.reject(storage_meta_from_rows(rows), &(&1[:type] == "database"))

    anchor_paths =
      case anchor_paths do
        nil -> default_storage_anchor_paths()
        paths -> expand_anchor_paths(paths)
      end

    chosen =
      anchor_paths
      |> Enum.flat_map(fn anchor_path ->
        storages
        |> Enum.filter(fn storage -> path_within_mountpoint?(anchor_path, storage.mountpoint) end)
        |> Enum.map(fn storage -> {String.length(storage.mountpoint), storage} end)
      end)
      |> Enum.max_by(fn {length, _storage} -> length end, fn -> nil end)
      |> case do
        {_, storage} -> storage
        nil -> nil
      end

    cond do
      is_map(chosen) ->
        chosen.id

      root = Enum.find(storages, &(&1.mountpoint == "/")) ->
        root.id

      first = List.first(storages) ->
        first.id

      true ->
        nil
    end
  end

  def default_storage_anchor_paths do
    expand_anchor_paths([OsMon.repo_database_path()])
  end

  def expand_anchor_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  def storage_mountpoint(entity_id) when is_binary(entity_id) do
    case String.split(entity_id, ":", parts: 2) do
      [_node, mountpoint] when mountpoint != "" -> mountpoint
      _ -> nil
    end
  end

  def storage_mountpoint(_entity_id), do: nil

  def database_name(entity_id) when is_binary(entity_id) do
    case String.split(entity_id, ":", parts: 2) do
      [_node, database] when database != "" -> database
      _ -> nil
    end
  end

  def database_name(_entity_id), do: nil

  def database_display_name("metadata_database"), do: "Metadata Database"
  def database_display_name(database) when is_binary(database), do: database

  def path_within_mountpoint?(path, "/") when is_binary(path), do: String.starts_with?(path, "/")

  def path_within_mountpoint?(path, mountpoint)
      when is_binary(path) and is_binary(mountpoint) do
    path == mountpoint or String.starts_with?(path, mountpoint <> "/")
  end

  def path_within_mountpoint?(_path, _mountpoint), do: false
end
