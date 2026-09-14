defmodule HydraSrt.Stats.MetricSelector do
  @moduledoc false

  @source_srt_metrics [
    {"srt_rtt_ms", "rtt-ms"},
    {"srt_negotiated_latency_ms", "negotiated-latency-ms"},
    {"srt_bandwidth_mbps", "bandwidth-mbps"},
    {"srt_rate_mbps", "receive-rate-mbps"},
    {"srt_packet_loss", "packets-received-lost"},
    {"srt_packet_loss_percent", "packet-loss-percent"},
    {"srt_retransmitted_packets_per_sec", "retransmitted-packets-per-sec"},
    {"srt_dropped_packets_per_sec", "dropped-packets-per-sec"},
    {"srt_nack_packets_per_sec", "nack-packets-per-sec"},
    {"srt_packets_total", "packets-received"},
    {"srt_packets_lost_total", "packets-received-lost"},
    {"srt_packets_retransmitted_total", "packets-received-retransmitted"},
    {"srt_packets_dropped_total", "packets-received-dropped"},
    {"srt_nack_total", "packet-nack-sent"},
    {"srt_bytes_total", "bytes-received"}
  ]

  @destination_srt_metrics [
    {"srt_rtt_ms", "rtt-ms"},
    {"srt_negotiated_latency_ms", "negotiated-latency-ms"},
    {"srt_bandwidth_mbps", "bandwidth-mbps"},
    {"srt_rate_mbps", "send-rate-mbps"},
    {"srt_packet_loss", "packets-sent-lost"},
    {"srt_packet_loss_percent", "packet-loss-percent"},
    {"srt_retransmitted_packets_per_sec", "retransmitted-packets-per-sec"},
    {"srt_dropped_packets_per_sec", "dropped-packets-per-sec"},
    {"srt_nack_packets_per_sec", "nack-packets-per-sec"},
    {"srt_packets_total", "packets-sent"},
    {"srt_packets_lost_total", "packets-sent-lost"},
    {"srt_packets_retransmitted_total", "packets-retransmitted"},
    {"srt_packets_dropped_total", "packets-sent-dropped"},
    {"srt_nack_total", "packet-nack-received"},
    {"srt_bytes_total", "bytes-sent"}
  ]

  @doc false
  @spec source_srt_metrics() :: [{String.t(), String.t()}]
  def source_srt_metrics, do: @source_srt_metrics

  @doc false
  @spec destination_srt_metrics() :: [{String.t(), String.t()}]
  def destination_srt_metrics, do: @destination_srt_metrics

  @spec select_rows(%{
          required(:route_id) => binary(),
          required(:stats) => map(),
          optional(:metadata) => map(),
          optional(:ts) => NaiveDateTime.t() | DateTime.t()
        }) :: [map()]
  def select_rows(%{route_id: route_id, stats: stats} = envelope)
      when is_binary(route_id) and is_map(stats) do
    ts = Map.get(envelope, :ts, DateTime.utc_now())
    metadata = Map.get(envelope, :metadata, %{})
    active_source_id = Map.get(metadata, :active_source_id)
    active_source_position = Map.get(metadata, :active_source_position)

    source_rows = source_rows(route_id, active_source_id, active_source_position, stats, ts)
    destination_rows = destination_rows(route_id, stats, ts)
    source_rows ++ destination_rows
  end

  def select_rows(_), do: []

  @spec source_rows(
          binary(),
          binary() | nil,
          integer() | nil,
          map(),
          NaiveDateTime.t() | DateTime.t()
        ) ::
          [map()]
  def source_rows(route_id, active_source_id, active_source_position, stats, ts)
      when is_binary(route_id) and is_map(stats) do
    rows =
      []
      |> maybe_add_double_row(
        route_id,
        "route",
        route_id,
        "active_source_position",
        active_source_position,
        ts
      )
      |> maybe_add_double_row(
        route_id,
        "source",
        active_source_id,
        "bytes_in_per_sec",
        get_in(stats, ["source", "bytes_in_per_sec"]),
        ts
      )
      |> maybe_add_double_row(
        route_id,
        "source",
        active_source_id,
        "bytes_in_total",
        get_in(stats, ["source", "bytes_in_total"]),
        ts
      )

    add_srt_rows(
      rows,
      route_id,
      "source",
      active_source_id,
      get_in(stats, ["source", "srt"]) || %{},
      @source_srt_metrics,
      ts
    )
  end

  @spec destination_rows(binary(), map(), NaiveDateTime.t() | DateTime.t()) :: [map()]
  def destination_rows(route_id, stats, ts)
      when is_binary(route_id) and is_map(stats) do
    stats
    |> Map.get("destinations", [])
    |> Enum.flat_map(fn
      %{"id" => destination_id} = destination when is_binary(destination_id) ->
        []
        |> maybe_add_double_row(
          route_id,
          "destination",
          destination_id,
          "bytes_out_per_sec",
          Map.get(destination, "bytes_out_per_sec"),
          ts
        )
        |> maybe_add_double_row(
          route_id,
          "destination",
          destination_id,
          "bytes_out_total",
          Map.get(destination, "bytes_out_total"),
          ts
        )
        |> add_srt_rows(
          route_id,
          "destination",
          destination_id,
          Map.get(destination, "srt", %{}),
          @destination_srt_metrics,
          ts
        )

      _ ->
        []
    end)
  end

  def add_srt_rows(rows, route_id, entity_type, entity_id, srt, metrics, ts)
      when is_list(rows) and is_map(srt) and is_list(metrics) do
    Enum.reduce(metrics, rows, fn {metric_key, srt_key}, acc ->
      maybe_add_double_row(
        acc,
        route_id,
        entity_type,
        entity_id,
        metric_key,
        Map.get(srt, srt_key),
        ts
      )
    end)
  end

  defp maybe_add_double_row(rows, _route_id, _entity_type, _entity_id, _metric_key, value, _ts)
       when not is_number(value),
       do: rows

  defp maybe_add_double_row(rows, route_id, entity_type, entity_id, metric_key, value, ts)
       when is_binary(route_id) and is_binary(entity_type) and is_binary(metric_key) and
              is_number(value) do
    [
      %{
        ts: ts,
        route_id: route_id,
        entity_type: entity_type,
        entity_id: entity_id,
        metric_key: metric_key,
        value_type: "double",
        value_double: value * 1.0,
        value_bigint: nil,
        value_text: nil
      }
      | rows
    ]
  end
end
