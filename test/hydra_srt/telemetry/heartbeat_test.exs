defmodule HydraSrt.Telemetry.HeartbeatTest do
  use HydraSrt.DataCase, async: false

  alias HydraSrt.DbFixtures
  alias HydraSrt.Telemetry.{Heartbeat, HeartbeatEvent, Queue, Settings, StartedEvent}

  test "builds the allowlisted aggregate payload from seeded routes" do
    route =
      DbFixtures.route_fixture(%{"backup_mode" => "active", "schema_status" => "processing"})

    DbFixtures.source_fixture(route, %{"schema" => "SRT", "position" => 0})
    DbFixtures.source_fixture(route, %{"schema" => "SRT", "position" => 1})
    DbFixtures.destination_fixture(route, %{"schema" => "UDP"})

    DbFixtures.destination_fixture(route, %{"schema" => "RTMP", "location" => "rtmp.example/live"})

    snapshot = HydraSrt.Db.telemetry_route_snapshot()

    event =
      Heartbeat.build_heartbeat(%{
        snapshot: snapshot,
        installation_id: Ecto.UUID.generate(),
        session_id: Ecto.UUID.generate()
      })

    assert %HeartbeatEvent{} = event
    assert event.route_count_total == 1
    assert event.routes_active_count == 1
    assert event.route_counts_by_source_transport[:srt] == 2
    assert event.route_counts_by_destination_transport[:udp] == 1
    assert event.route_counts_by_destination_transport[:rtmp] == 1
    assert event.failover_configured_count == 1
    assert event.mcp_enabled == true
    assert event.ndi_enabled in [true, false]
    assert event.youtube_enabled in [true, false]
    assert event.telegram_enabled == false
    assert event.victoria_configured == false
    assert event.interfaces_count == 0
    assert event.version == HydraSrt.Telemetry.Config.version()
    assert event.distribution in [:docker, :release, :source]

    assert Map.keys(event) |> Enum.sort() ==
             [
               :__struct__,
               :arch,
               :distribution,
               :event,
               :failover_configured_count,
               :installation_id,
               :interfaces_count,
               :mcp_enabled,
               :ndi_enabled,
               :os_family,
               :route_count_total,
               :route_counts_by_destination_transport,
               :route_counts_by_source_transport,
               :routes_active_count,
               :session_id,
               :telegram_enabled,
               :uptime_bucket,
               :version,
               :victoria_configured,
               :youtube_enabled
             ]
  end

  test "creates one stable installation identity and one per-boot session identity" do
    start_supervised!(Settings)
    start_supervised!(Queue)

    assert HydraSrt.Db.get_telemetry_installation() == nil
    {:noreply, _state} = Heartbeat.handle_info(:started, %{boot_started_at: 0, timer: nil})
    [started] = Queue.take_batch(1)

    assert %StartedEvent{installation_id: installation_id, session_id: session_id} = started
    assert {:ok, ^installation_id} = Settings.ensure_identity(true)
    assert Settings.installation_id() == installation_id
    assert Settings.session_id() == session_id
    assert HydraSrt.Db.get_telemetry_installation().installation_id == installation_id

    heartbeat = Heartbeat.build_heartbeat()
    assert heartbeat.installation_id == installation_id
    assert heartbeat.session_id == session_id
  end

  test "started event carries the previously sent version" do
    installation_id = Ecto.UUID.generate()

    assert {:ok, _row} =
             HydraSrt.Db.upsert_telemetry_installation(%{
               installation_id: installation_id,
               last_seen_version: "0.6.8"
             })

    start_supervised!(Settings)
    start_supervised!(Queue)
    {:noreply, _state} = Heartbeat.handle_info(:started, %{boot_started_at: 0, timer: nil})
    [started] = Queue.take_batch(1)

    assert %StartedEvent{previous_version: "0.6.8", installation_id: ^installation_id} = started
  end

  test "uses the documented uptime buckets" do
    assert Heartbeat.uptime_bucket(0) == :under_5m
    assert Heartbeat.uptime_bucket(:timer.minutes(5)) == :five_minutes_to_1h
    assert Heartbeat.uptime_bucket(:timer.hours(1)) == :one_to_24h
    assert Heartbeat.uptime_bucket(:timer.hours(24 * 7)) == :over_7d
  end
end
