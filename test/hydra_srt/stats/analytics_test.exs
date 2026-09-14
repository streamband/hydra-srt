defmodule HydraSrt.Stats.AnalyticsTest do
  # DataCase (SQL sandbox) is needed because a few functions under test call
  # Db.get_all_routes/1 before touching the metrics backend.
  use HydraSrt.DataCase, async: true

  alias HydraSrt.Monitoring.OsMon
  alias HydraSrt.Stats.Analytics
  alias HydraSrt.Stats.VictoriaMetrics

  defmodule FakeVictoriaMetrics do
    def query_range(_query, _from, _to, _step) do
      node_id = "storage-test-node"
      mountpoint = "/tmp/hydra-storage-test"
      unix_ts = DateTime.to_unix(~U[2026-06-16 12:00:00Z], :second)

      series =
        [
          {"storage", "#{node_id}:#{mountpoint}", "storage_total_bytes", "1000.0"},
          {"storage", "#{node_id}:#{mountpoint}", "storage_used_bytes", "400.0"},
          {"storage", "#{node_id}:#{mountpoint}", "storage_free_bytes", "600.0"},
          {"storage", "#{node_id}:#{mountpoint}", "storage_used_percent", "40.0"},
          {"database", "#{node_id}:metadata_database", "database_size_bytes", "2048.0"}
        ]
        |> Enum.map(fn {entity_type, entity_id, metric_key, value} ->
          %{
            "metric" => %{
              "route_id" => "",
              "entity_type" => entity_type,
              "entity_id" => entity_id,
              "metric_key" => metric_key
            },
            "values" => [[unix_ts, value]]
          }
        end)

      {:ok, series}
    end
  end

  defmodule MatchCapture do
    def export_series(match_expr, _from, _to) do
      send(self(), {:match_expr, match_expr})

      {:ok,
       [
         %{
           "metric" => %{
             "route_id" => "route-1",
             "event_type" => "source_switch",
             "to_source_id" => "s2"
           },
           "timestamps" => [1_767_225_600_000]
         }
       ]}
    end
  end

  defmodule FakeExportDown do
    def export_series(_match_expr, _from, _to), do: {:error, :backend_down}
  end

  defmodule QueryCapture do
    def query_range(query, _from, _to, _step) do
      send(self(), {:query_range_query, query})
      {:ok, []}
    end
  end

  defmodule SrtTotalsClient do
    def query_range(_query, _from, _to, _step) do
      first_ts = DateTime.to_unix(~U[2026-01-01 00:00:00Z], :second)
      second_ts = DateTime.to_unix(~U[2026-01-01 00:00:10Z], :second)

      {:ok,
       [
         series("source", "source-1", "srt_packets_total", ["100", "150"], first_ts),
         series("source", "source-1", "srt_packets_lost_total", ["10", "20"], first_ts),
         series("source", "source-1", "srt_bytes_total", ["1000", "2000"], first_ts),
         series("source", "source-2", "srt_packets_total", ["0", "0"], first_ts),
         series("source", "source-2", "srt_packets_lost_total", ["0", "0"], first_ts),
         series("destination", "destination-1", "srt_packets_total", ["200", "250"], first_ts),
         series(
           "destination",
           "destination-1",
           "srt_packets_lost_total",
           ["10", "20"],
           first_ts
         ),
         series("destination", "destination-1", "srt_bytes_total", ["3000", "4000"], first_ts)
       ]
       |> Enum.map(fn series ->
         put_in(series["values"], [
           [first_ts, hd(series["values"])],
           [second_ts, List.last(series["values"])]
         ])
       end)}
    end

    defp series(entity_type, entity_id, metric_key, values, _timestamp) do
      %{
        "metric" => %{
          "entity_type" => entity_type,
          "entity_id" => entity_id,
          "metric_key" => metric_key
        },
        "values" => values
      }
    end
  end

  defmodule StatsResetCapture do
    def export_series(_match_expr, _from, _to) do
      {:ok,
       [
         %{
           "metric" => %{
             "route_id" => "route-1",
             "event_type" => "source_switch",
             "reason" => "manual"
           },
           "timestamps" => [1_767_225_610_000]
         },
         %{
           "metric" => %{
             "route_id" => "route-1",
             "event_type" => "stats_reset",
             "details_json" => Jason.encode!(%{"action" => "cleared"})
           },
           "timestamps" => [1_767_225_600_000]
         },
         %{
           "metric" => %{
             "route_id" => "route-1",
             "event_type" => "stats_reset",
             "reason" => "set"
           },
           "timestamps" => [1_767_225_620_000]
         }
       ]}
    end
  end

  test "fetch_events_result propagates backend errors as tagged tuples" do
    from = ~U[2026-01-01 00:00:00Z]
    to = ~U[2026-01-01 01:00:00Z]

    assert {:error, :backend_down} =
             Analytics.fetch_events_result(nil, from, to, FakeExportDown)

    assert {:error, :backend_down} =
             Analytics.fetch_events_result("route-1", from, to, FakeExportDown)
  end

  test "fetch_events legacy wrapper swallows backend errors as an empty list" do
    from = ~U[2026-01-01 00:00:00Z]
    to = ~U[2026-01-01 01:00:00Z]

    assert Analytics.fetch_events("route-1", from, to, FakeExportDown) == []
  end

  test "fetch_events_result returns parsed rows on success" do
    from = ~U[2026-01-01 00:00:00Z]
    to = ~U[2026-01-01 01:00:00Z]

    assert {:ok, [event]} = Analytics.fetch_events_result("route-1", from, to, MatchCapture)
    assert event["route_id"] == "route-1"
    assert event["event_type"] == "source_switch"
  end

  test "fetch_route_switches pushes event_type into the export match expression" do
    query_params = %{from: ~U[2026-01-01 00:00:00Z], to: ~U[2026-01-01 01:00:00Z]}

    Analytics.fetch_route_switches("route-1", query_params, MatchCapture)

    assert_received {:match_expr, match_expr}
    assert match_expr =~ ~s(event_type="source_switch")
    assert match_expr =~ ~s(route_id="route-1")
  end

  test "fetch_route_switches swallows backend export errors as an empty list" do
    query_params = %{from: ~U[2026-01-01 00:00:00Z], to: ~U[2026-01-01 01:00:00Z]}

    assert Analytics.fetch_route_switches("route-1", query_params, FakeExportDown) == []
  end

  test "fetch_stats_rows builds the requested aggregation query" do
    query_params = %{
      from: ~U[2026-01-01 00:00:00Z],
      to: ~U[2026-01-01 00:01:00Z],
      bucket_ms: 30_000
    }

    for {aggregation, function} <- [
          {:avg, "avg_over_time"},
          {:max, "max_over_time"},
          {:last, "last_over_time"}
        ] do
      assert {:ok, []} =
               Analytics.fetch_stats_rows(
                 QueryCapture,
                 %{"route_id" => "route-1"},
                 ["srt_rtt_ms"],
                 query_params,
                 aggregation
               )

      assert_received {:query_range_query, query}
      assert query =~ "#{function}("
      assert query =~ "[30s])"
    end
  end

  test "fetch_routes_status_timeseries propagates backend export errors" do
    {:ok, query_params} = Analytics.build_query_params(%{"window" => "last_hour"})

    # A backend outage must surface as {:error, _} so Dashboard availability is
    # false rather than being masked as an empty (but successful) timeseries.
    assert {:error, :backend_down} =
             Analytics.fetch_routes_status_timeseries(query_params, FakeExportDown)
  end

  test "fetch_routes_status_history propagates backend export errors" do
    {:ok, query_params} = Analytics.build_query_params(%{"window" => "last_hour"})

    assert {:error, :backend_down} =
             Analytics.fetch_routes_status_history(query_params, %{}, FakeExportDown)
  end

  test "fetch_routes_status_history pushes route_id filter into the export match expression" do
    {:ok, query_params} = Analytics.build_query_params(%{"window" => "last_hour"})

    assert {:ok, _payload} =
             Analytics.fetch_routes_status_history(
               query_params,
               %{"route_id" => "route-1"},
               MatchCapture
             )

    assert_received {:match_expr, match_expr}
    assert match_expr =~ ~s(event_type="route_status_change")
    assert match_expr =~ ~s(route_id="route-1")
  end

  test "fetch_routes_status_history omits route_id matcher when no filter is given" do
    {:ok, query_params} = Analytics.build_query_params(%{"window" => "last_hour"})

    assert {:ok, _payload} =
             Analytics.fetch_routes_status_history(query_params, %{}, MatchCapture)

    assert_received {:match_expr, match_expr}
    assert match_expr =~ ~s(event_type="route_status_change")
    refute match_expr =~ "route_id="
  end

  test "fetch_route_events propagates backend export errors instead of an empty page" do
    assert {:error, :backend_down} =
             Analytics.fetch_route_events("route-1", %{"window" => "last_hour"}, FakeExportDown)
  end

  test "fetch_route_events returns a successful page on backend success" do
    assert {:ok, %{events: events, meta: meta}} =
             Analytics.fetch_route_events("route-1", %{"window" => "last_hour"}, MatchCapture)

    assert [%{"route_id" => "route-1", "event_type" => "source_switch"}] = events
    assert meta.total == 1
  end

  test "fetch_events_for_route_ids builds a regex selector and returns parsed rows" do
    from = ~U[2026-01-01 00:00:00Z]
    to = ~U[2026-01-01 01:00:00Z]

    assert {:ok, [event]} =
             Analytics.fetch_events_for_route_ids(["route-1", "route-2"], from, to, MatchCapture)

    assert event["route_id"] == "route-1"

    assert_received {:match_expr, match_expr}
    assert match_expr == VictoriaMetrics.event_selector_for_route_ids(["route-1", "route-2"])
  end

  test "fetch_events_for_route_ids propagates backend export errors" do
    from = ~U[2026-01-01 00:00:00Z]
    to = ~U[2026-01-01 01:00:00Z]

    assert {:error, :backend_down} =
             Analytics.fetch_events_for_route_ids(["route-1"], from, to, FakeExportDown)
  end

  test "event_row_from_labels prefers the stored details_json label verbatim" do
    details = Jason.encode!(%{"reason" => "publish_rejected", "peer" => "10.0.0.5"})

    labels = %{
      "route_id" => "route-1",
      "event_type" => "publisher_rejected",
      "details_json" => details,
      "old_status" => "",
      "new_status" => ""
    }

    row = Analytics.event_row_from_labels(labels, 1_767_225_600_000)
    assert row["details_json"] == details
  end

  test "event_row_from_labels reconstructs details_json from status labels when absent" do
    labels = %{
      "route_id" => "route-1",
      "event_type" => "route_status_change",
      "old_status" => "starting",
      "new_status" => "processing"
    }

    row = Analytics.event_row_from_labels(labels, 1_767_225_600_000)

    assert Jason.decode!(row["details_json"]) == %{
             "old_status" => "starting",
             "new_status" => "processing"
           }
  end

  test "build_query_params resolves known window" do
    assert {:ok, params} = Analytics.build_query_params(%{"window" => "last_hour"})
    assert params.window == "last_hour"
    assert params.bucket_ms == 30_000
    assert DateTime.compare(params.from, params.to) == :lt
  end

  test "build_query_params downsamples 24h window with default max_points" do
    assert {:ok, params} = Analytics.build_query_params(%{"window" => "last_24_hour"})
    assert params.bucket_ms == 300_000
  end

  test "build_query_params honors max_points override" do
    assert {:ok, params} =
             Analytics.build_query_params(%{"window" => "last_24_hour", "max_points" => "120"})

    assert params.bucket_ms == 900_000
  end

  test "route_status_point_series ignores events for deleted routes" do
    from_dt = ~U[2026-06-23 09:00:00Z]
    to_dt = ~U[2026-06-23 09:01:00Z]
    bucket_ms = 60_000
    allowed_route_ids = MapSet.new(["route-1"])

    route_statuses = %{"route-1" => "processing"}

    event_rows = [
      %{
        "route_id" => "route-deleted",
        "ts_ms" => DateTime.to_unix(~U[2026-06-23 09:00:30Z], :millisecond),
        "status" => "processing"
      },
      %{
        "route_id" => "route-1",
        "ts_ms" => DateTime.to_unix(~U[2026-06-23 09:00:30Z], :millisecond),
        "status" => "stopped"
      }
    ]

    assert [
             %{processing: 1, stopped: 0},
             %{processing: 0, stopped: 1}
           ] =
             Analytics.route_status_point_series(
               route_statuses,
               event_rows,
               from_dt,
               to_dt,
               bucket_ms,
               allowed_route_ids
             )
             |> Enum.map(fn point ->
               Map.take(point, [:processing, :stopped])
             end)
  end

  test "fetch_node_timeseries returns storage and database points and metadata" do
    node_id = "storage-test-node"
    mountpoint = "/tmp/hydra-storage-test"
    storage_id = HydraSrt.Monitoring.OsMon.storage_id(mountpoint)
    ts = ~U[2026-06-16 12:00:00Z]

    assert {:ok, payload} =
             Analytics.fetch_node_timeseries(
               node_id,
               %{
                 from: DateTime.add(ts, -60, :second),
                 to: DateTime.add(ts, 60, :second),
                 window: "custom",
                 bucket_ms: 10_000
               },
               FakeVictoriaMetrics
             )

    assert %{
             id: "metadata_database",
             mountpoint: "Metadata Database",
             name: "Metadata Database",
             type: "database"
           } in payload.meta.databases

    assert Enum.any?(payload.meta.storages, fn storage ->
             storage.id == storage_id and storage.mountpoint == mountpoint and
               storage.type == "mountpoint"
           end)

    assert %{id: "metadata_database", mountpoint: "Metadata Database", type: "database"} =
             Enum.find(payload.meta.storages, &(&1.id == "metadata_database"))

    assert payload.meta.default_storage_id == storage_id

    assert Enum.any?(payload.points, fn point ->
             point["storage_total_#{storage_id}"] == 1000.0 and
               point["storage_used_#{storage_id}"] == 400.0 and
               point["storage_free_#{storage_id}"] == 600.0 and
               point["storage_used_percent_#{storage_id}"] == 40.0
           end)

    assert Enum.any?(payload.points, fn point ->
             point["storage_total_metadata_database"] == 2048.0 and
               point["storage_used_metadata_database"] == 2048.0 and
               point["storage_free_metadata_database"] == 0.0 and
               point["storage_used_percent_metadata_database"] == 100.0
           end)
  end

  test "default_storage_id falls back without anchor paths" do
    rows = [
      %{
        entity_type: "storage",
        entity_id: "node@host:/",
        metric_key: "storage_total_bytes"
      }
    ]

    assert Analytics.default_storage_id(rows, []) == "root"
  end

  test "default_storage_id prefers mountpoint containing database paths" do
    rows = [
      %{
        entity_type: "storage",
        entity_id: "node@host:/",
        metric_key: "storage_total_bytes"
      },
      %{
        entity_type: "storage",
        entity_id: "node@host:/data",
        metric_key: "storage_total_bytes"
      }
    ]

    assert Analytics.default_storage_id(rows, ["/data/hydra_srt/hydra_srt.db"]) ==
             OsMon.storage_id("/data")
  end

  test "default_storage_id expands relative anchor paths before matching" do
    relative_db = "relative/hydra_srt.db"
    mountpoint = Path.dirname(Path.expand(relative_db))

    rows = [
      %{
        entity_type: "storage",
        entity_id: "node@host:/",
        metric_key: "storage_total_bytes"
      },
      %{
        entity_type: "storage",
        entity_id: "node@host:#{mountpoint}",
        metric_key: "storage_total_bytes"
      }
    ]

    assert Analytics.default_storage_id(rows, [relative_db]) == OsMon.storage_id(mountpoint)
  end

  test "source_timeline_from_switches builds contiguous segments" do
    query = %{to: ~U[2026-05-01 12:30:00Z]}

    switches = [
      %{"ts" => ~U[2026-05-01 12:00:00Z], "to_source_id" => "s1"},
      %{"ts" => ~U[2026-05-01 12:05:00Z], "to_source_id" => "s2"},
      %{"ts" => ~U[2026-05-01 12:10:00Z], "to_source_id" => "s2"},
      %{"ts" => ~U[2026-05-01 12:20:00Z], "to_source_id" => "s3"}
    ]

    assert [
             %{
               "from" => "2026-05-01T12:00:00Z",
               "to" => "2026-05-01T12:05:00Z",
               "source_id" => "s1"
             },
             %{
               "from" => "2026-05-01T12:05:00Z",
               "to" => "2026-05-01T12:20:00Z",
               "source_id" => "s2"
             },
             %{
               "from" => "2026-05-01T12:20:00Z",
               "to" => "2026-05-01T12:30:00Z",
               "source_id" => "s3"
             }
           ] = Analytics.source_timeline_from_switches(switches, query)
  end

  test "srt_health_points_from_rows keeps packet loss count separate from percent" do
    rows = [
      %{
        timestamp: "2026-05-01T12:00:00Z",
        entity_type: "source",
        entity_id: "s1",
        metric_key: "srt_packet_loss",
        value: 0.25
      },
      %{
        timestamp: "2026-05-01T12:00:00Z",
        entity_type: "source",
        entity_id: "s1",
        metric_key: "srt_packet_loss_percent",
        value: 0.5
      }
    ]

    assert [point] = Analytics.srt_health_points_from_rows(rows)
    assert point.timestamp == "2026-05-01T12:00:00Z"
    assert point.entity_type == "source"
    assert point.entity_id == "s1"
    assert Map.get(point, "packet_loss_percent") == 0.5
    assert Map.get(point, "packets_lost_total") == 0.25
  end

  test "srt_health_points_from_rows merges maximum rows onto average points" do
    rows = [
      %{
        timestamp: "2026-05-01T12:00:00Z",
        entity_type: "source",
        entity_id: "s1",
        metric_key: "srt_rtt_ms",
        value: 10.0
      },
      %{
        timestamp: "2026-05-01T12:00:00Z",
        entity_type: "source",
        entity_id: "s1",
        metric_key: "srt_rtt_ms_max",
        value: 20.0
      }
    ]

    assert [point] = Analytics.srt_health_points_from_rows(rows)
    assert point["rtt_ms"] == 10.0
    assert point["rtt_ms_max"] == 20.0
  end

  test "positive_increase sums only positive deltas" do
    assert Analytics.positive_increase([10, 15, 22]) == 12
    assert Analytics.positive_increase([100, 120, 10, 20]) == 30
    assert Analytics.positive_increase([42]) == 0
    assert Analytics.positive_increase([]) == 0
  end

  test "fetch_route_srt_totals calculates endpoint formulas and preserves nil metrics" do
    query_params = %{
      from: ~U[2026-01-01 00:00:00Z],
      to: ~U[2026-01-01 00:01:00Z],
      bucket_ms: 10_000
    }

    assert [destination, source, source_zero] =
             Analytics.fetch_route_srt_totals("route-1", query_params, SrtTotalsClient)

    assert source.entity_type == "source"
    assert source.entity_id == "source-1"
    assert source.packets_total == 50.0
    assert source.packets_lost_total == 10.0
    assert source.packets_retransmitted_total == nil
    assert_in_delta source.loss_percent, 10 / 60 * 100, 0.0001

    assert source_zero.entity_id == "source-2"
    assert source_zero.loss_percent == nil

    assert destination.entity_type == "destination"
    assert destination.entity_id == "destination-1"
    assert destination.packets_total == 50.0
    assert destination.packets_lost_total == 10.0
    assert_in_delta destination.loss_percent, 10 / 50 * 100, 0.0001
  end

  test "fetch_route_stats_resets filters and sorts reset events" do
    query_params = %{
      from: ~U[2026-01-01 00:00:00Z],
      to: ~U[2026-01-01 00:01:00Z]
    }

    assert [cleared, set] =
             Analytics.fetch_route_stats_resets("route-1", query_params, StatsResetCapture)

    assert cleared == %{
             "timestamp" => "2026-01-01T00:00:00.000Z",
             "reason" => "cleared"
           }

    assert set == %{
             "timestamp" => "2026-01-01T00:00:20.000Z",
             "reason" => "set"
           }
  end
end
