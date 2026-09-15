defmodule HydraSrt.Telemetry.EventTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Telemetry.{Event, HeartbeatEvent, RouteEvent, StartedEvent}

  test "encodes the allowlisted heartbeat shape" do
    id = Ecto.UUID.generate()

    event = %HeartbeatEvent{
      version: "0.6.9",
      os_family: :linux,
      arch: :x86_64,
      distribution: :source,
      uptime_bucket: :under_5m,
      route_count_total: 1,
      routes_active_count: 1,
      route_counts_by_source_transport: %{srt: 1},
      route_counts_by_destination_transport: %{udp: 1},
      installation_id: id,
      session_id: Ecto.UUID.generate()
    }

    assert {:ok, encoded} = Event.encode_batch([event])
    assert {:ok, payload} = Jason.decode(encoded)
    assert payload["api_key"] == "phc_Caj6HJgJnjm2vf3ZS9Wd9KYUF7fqxCWnK7nFEXrvENkK"
    [item] = payload["batch"]
    assert item["event"] == "hydra.heartbeat"
    assert item["distinct_id"] == id
    assert item["properties"]["$process_person_profile"] == false
    assert item["properties"]["$lib"] == "hydra-srt"

    assert Map.keys(item["properties"]["route_counts_by_source_transport"]) |> Enum.sort() ==
             ["ndi", "rtmp", "rtp", "srt", "udp", "youtube"]
  end

  test "rejects invalid identity and unknown event structs" do
    event = %StartedEvent{
      version: "0.6.9",
      distribution: :source,
      installation_id: "not-a-uuid",
      session_id: Ecto.UUID.generate()
    }

    assert {:error, :invalid_identity_or_version} = Event.encode(event)
    assert {:error, :unknown_event} = Event.to_posthog_event(%{event: "hydra.heartbeat"})
  end

  test "rejects unknown keys, oversized values, and invalid enums" do
    event = %StartedEvent{
      version: "0.6.9",
      distribution: :source,
      installation_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate()
    }

    assert {:error, :unknown_keys} = Event.to_posthog_event(Map.put(event, :unexpected, true))

    oversized = %{event | version: String.duplicate("x", 65)}
    assert {:error, :invalid_identity_or_version} = Event.encode(oversized)

    heartbeat = %HeartbeatEvent{
      version: "0.6.9",
      os_family: :plan9,
      arch: :x86_64,
      distribution: :source,
      uptime_bucket: :under_5m,
      installation_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate()
    }

    assert {:error, :invalid_enum} = Event.to_posthog_event(heartbeat)

    route = %RouteEvent{
      event: "hydra.route.stopped",
      source_transport: :srt,
      destination_transports: [:udp],
      destination_count: 1,
      reason: :manual,
      duration_bucket: :not_a_bucket,
      installation_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate()
    }

    assert {:error, :invalid_route_event} = Event.to_posthog_event(route)
  end

  test "route events encode only aggregate enums and booleans" do
    event = %RouteEvent{
      event: "hydra.route.started",
      source_transport: :srt,
      destination_transports: [:udp, :rtmp],
      destination_count: 2,
      failover_enabled: true,
      has_passphrase: true,
      has_stream_id: false,
      installation_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate()
    }

    assert {:ok, payload} = Event.to_posthog_event(event)
    refute inspect(payload) =~ "route-name"
    refute inspect(payload) =~ "srt://"
    assert payload.properties.destination_count == 2
    assert payload.properties.has_passphrase == true
  end
end
