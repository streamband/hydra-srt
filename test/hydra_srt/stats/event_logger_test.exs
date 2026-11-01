defmodule HydraSrt.Stats.EventLoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias HydraSrt.Stats.EventLogger

  test "flush_events preserves insertion order" do
    events = [
      %{route_id: "route-1", event_type: "pipeline_reconnecting", ts: ~U[2026-01-01 00:00:01Z]},
      %{route_id: "route-1", event_type: "pipeline_failed", ts: ~U[2026-01-01 00:00:02Z]}
    ]

    assert {[], :ok} =
             EventLogger.flush_events(Enum.reverse(events), fn rows ->
               send(self(), {:inserted_rows, rows})
               :ok
             end)

    assert_receive {:inserted_rows, inserted}
    assert Enum.map(inserted, & &1.event_type) == ["pipeline_reconnecting", "pipeline_failed"]
  end

  test "flush_events keeps events when insert fails" do
    events = [%{route_id: "route-1", event_type: "pipeline_failed", ts: ~U[2026-01-01 00:00:01Z]}]

    assert {^events, {:error, :victoria_metrics_down}} =
             EventLogger.flush_events(events, fn _rows -> {:error, :victoria_metrics_down} end)
  end

  test "enforces max_buffer_size by dropping oldest events" do
    name = :"event_logger_limit_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {EventLogger,
         %{
           name: name,
           flush_interval_ms: 100_000,
           max_batch_size: 100,
           max_buffer_size: 5,
           insert_events_fun: fn _rows -> {:error, :victoria_metrics_down} end
         }}
      )

    log =
      capture_log(fn ->
        for i <- 1..10 do
          GenServer.cast(name, {
            :ingest_event,
            %{
              route_id: "route-1",
              event_type: "event_#{i}",
              ts: DateTime.add(~U[2026-01-01 00:00:00Z], i, :second)
            }
          })
        end

        _ = :sys.get_state(pid)
      end)

    assert log =~ "dropped"
    assert log =~ "max_buffer_size"

    state = :sys.get_state(pid)
    assert length(state.events) == 5

    assert Enum.map(state.events, & &1.event_type) == [
             "event_10",
             "event_9",
             "event_8",
             "event_7",
             "event_6"
           ]
  end

  test "broadcast_event publishes to route-specific topic" do
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:route-1")

    :ok =
      EventLogger.broadcast_event(%{
        route_id: "route-1",
        event_type: "source_switch",
        ts: ~U[2026-01-01 00:00:01Z]
      })

    assert_receive {:event, %{"route_id" => "route-1", "event_type" => "source_switch"}}
  end

  test "broadcast_event publishes to global events topic" do
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:all")

    :ok =
      EventLogger.broadcast_event(%{
        route_id: "route-2",
        event_type: "route_status_change",
        ts: ~U[2026-01-01 00:00:02Z]
      })

    assert_receive {:event, %{"route_id" => "route-2", "event_type" => "route_status_change"}}
  end

  test "log_stats_reset broadcasts the reset event shape" do
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:route-reset")

    :ok = EventLogger.log_stats_reset("route-reset", "set")

    assert_receive {:event,
                    %{
                      "route_id" => "route-reset",
                      "event_type" => "stats_reset",
                      "severity" => "info",
                      "reason" => "set",
                      "message" => "Route statistics reset",
                      "details_json" => "{\"action\":\"set\"}"
                    }}
  end

  describe "RTMP publisher events" do
    setup do
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:route-rtmp")
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:all")
      :ok
    end

    test "log_publisher_connected/3 broadcasts publisher_connected" do
      :ok =
        EventLogger.log_publisher_connected("route-rtmp", "/live/prochid", {{127, 0, 0, 1}, 9})

      assert_receive {:event,
                      %{"route_id" => "route-rtmp", "event_type" => "publisher_connected"}}

      assert_receive {:event,
                      %{"event_type" => "publisher_connected", "details_json" => details_json}}

      assert Jason.decode!(details_json)["path"] == "/live/prochid"
    end

    test "log_publisher_disconnected/3 broadcasts publisher_disconnected" do
      :ok =
        EventLogger.log_publisher_disconnected("route-rtmp", "/live/prochid", {{127, 0, 0, 1}, 9})

      assert_receive {:event, %{"event_type" => "publisher_disconnected"}}
    end

    test "log_publish_rejected/3 carries the rejection reason" do
      :ok = EventLogger.log_publish_rejected("route-rtmp", "/live/prochid", "route_not_live")

      assert_receive {:event,
                      %{
                        "event_type" => "publish_rejected",
                        "severity" => "warning",
                        "reason" => "route_not_live"
                      }}
    end

    test "log_publish_conflict/2 broadcasts publish_conflict" do
      :ok = EventLogger.log_publish_conflict("route-rtmp", "/live/prochid", self())

      assert_receive {:event, %{"event_type" => "publish_conflict", "severity" => "warning"}}
    end

    test "log_publish_audio_only/2 broadcasts a warning" do
      :ok = EventLogger.log_publish_audio_only("route-rtmp", "/live/prochid")

      assert_receive {:event, %{"event_type" => "publish_audio_only", "severity" => "warning"}}
    end

    test "log_publish_video_only/2 broadcasts a warning" do
      :ok = EventLogger.log_publish_video_only("route-rtmp", "/live/prochid")

      assert_receive {:event, %{"event_type" => "publish_video_only", "severity" => "warning"}}
    end

    test "log_publish_caps_changed/2 broadcasts a warning" do
      :ok = EventLogger.log_publish_caps_changed("route-rtmp", "/live/prochid")

      assert_receive {:event, %{"event_type" => "publish_caps_changed", "severity" => "warning"}}
    end

    test "log_publish_no_codecs/2 broadcasts an error" do
      :ok = EventLogger.log_publish_no_codecs("route-rtmp", "/live/prochid")

      assert_receive {:event, %{"event_type" => "publish_no_codecs", "severity" => "error"}}
    end

    test "log_publish_inactivity/2 broadcasts a warning" do
      :ok = EventLogger.log_publish_inactivity("route-rtmp", "/live/prochid")

      assert_receive {:event, %{"event_type" => "publish_inactivity", "severity" => "warning"}}
    end

    test "publish_rejected with nil route_id still reaches events:all" do
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:all")

      :ok = EventLogger.log_publish_rejected(nil, "/live/prochid", "route_not_live")

      assert_receive {:event, %{"route_id" => nil, "event_type" => "publish_rejected"}}
    end
  end
end
