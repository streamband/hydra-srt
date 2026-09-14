defmodule HydraSrt.Stats.MetricSelectorTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Stats.MetricSelector

  # Real GStreamer/Rust stats keys, captured from a live srtsrc (receive
  # direction) loopback session, plus the 4 keys computed by
  # native/crates/hydra-media/src/stats.rs's add_interval_metrics. Only keys
  # in this set may legitimately appear as the RHS of
  # @source_srt_metrics.
  @valid_source_srt_keys ~w(
    packets-sent packets-sent-lost packets-retransmitted packet-ack-received
    packet-nack-received send-duration-us bytes-sent bytes-retransmitted
    bytes-sent-dropped packets-sent-dropped send-rate-mbps
    negotiated-latency-ms packets-received packets-received-lost
    packets-received-retransmitted packets-received-dropped packet-ack-sent
    packet-nack-sent bytes-received bytes-received-lost receive-rate-mbps
    bandwidth-mbps rtt-ms bytes-received-total
    packet-loss-percent retransmitted-packets-per-sec dropped-packets-per-sec
    nack-packets-per-sec
  )

  # Same capture, but for a single srtsink caller entry (send direction):
  # identical field set minus bytes-received-total, plus caller-address.
  @valid_destination_srt_keys ~w(
    packets-sent packets-sent-lost packets-retransmitted packet-ack-received
    packet-nack-received send-duration-us bytes-sent bytes-retransmitted
    bytes-sent-dropped packets-sent-dropped send-rate-mbps
    negotiated-latency-ms packets-received packets-received-lost
    packets-received-retransmitted packets-received-dropped packet-ack-sent
    packet-nack-sent bytes-received bytes-received-lost receive-rate-mbps
    bandwidth-mbps rtt-ms caller-address
    packet-loss-percent retransmitted-packets-per-sec dropped-packets-per-sec
    nack-packets-per-sec
  )

  test "every source metric maps to a key the Rust stats pipeline actually emits" do
    for {metric_key, srt_key} <- MetricSelector.source_srt_metrics() do
      assert srt_key in @valid_source_srt_keys,
             "#{metric_key} maps to #{inspect(srt_key)}, which is not a real srtsrc " <>
               "stats field captured from a live GStreamer stats structure"
    end
  end

  test "every destination metric maps to a key the Rust stats pipeline actually emits" do
    for {metric_key, srt_key} <- MetricSelector.destination_srt_metrics() do
      assert srt_key in @valid_destination_srt_keys,
             "#{metric_key} maps to #{inspect(srt_key)}, which is not a real srtsink " <>
               "caller stats field captured from a live GStreamer stats structure"
    end
  end

  test "select_rows extracts source bytes_in_per_sec and destination bytes_out_per_sec" do
    envelope = %{
      route_id: "route-1",
      ts: ~U[2026-01-01 00:00:00Z],
      metadata: %{active_source_id: "source-1", active_source_position: 1},
      stats: %{
        "source" => %{
          "bytes_in_per_sec" => 191_572,
          "bytes_in_total" => 39_622_128,
          # Realistic srtsrc (receive-direction) payload, captured from a live
          # GStreamer 1.26.7 stats structure, plus the 4 computed interval
          # metrics stats.rs adds on top.
          "srt" => %{
            "packets-sent" => 0,
            "packets-sent-lost" => 0,
            "packets-retransmitted" => 0,
            "packet-ack-received" => 0,
            "packet-nack-received" => 0,
            "send-duration-us" => 0,
            "bytes-sent" => 0,
            "bytes-retransmitted" => 0,
            "bytes-sent-dropped" => 0,
            "packets-sent-dropped" => 0,
            "send-rate-mbps" => 0.0,
            "negotiated-latency-ms" => 125,
            "packets-received" => 855,
            "packets-received-lost" => 42,
            "packets-received-retransmitted" => 0,
            "packets-received-dropped" => 0,
            "packet-ack-sent" => 301,
            "packet-nack-sent" => 0,
            "bytes-received" => 198_360,
            "bytes-received-lost" => 0,
            "receive-rate-mbps" => 1.2,
            "bandwidth-mbps" => 8.5,
            "rtt-ms" => 12.5,
            "bytes-received-total" => 157_732,
            "packet-loss-percent" => 0.01,
            "retransmitted-packets-per-sec" => 4,
            "dropped-packets-per-sec" => 1,
            "nack-packets-per-sec" => 2
          }
        },
        "destinations" => [
          %{
            "id" => "dest-1",
            "bytes_out_per_sec" => 186_684,
            "bytes_out_total" => 39_622_128,
            # Realistic srtsink caller entry (send-direction) payload.
            "srt" => %{
              "packets-sent" => 855,
              "packets-sent-lost" => 7,
              "packets-retransmitted" => 8,
              "packet-ack-received" => 301,
              "packet-nack-received" => 9,
              "send-duration-us" => 3_103_678,
              "bytes-sent" => 198_360,
              "bytes-retransmitted" => 0,
              "bytes-sent-dropped" => 0,
              "packets-sent-dropped" => 0,
              "send-rate-mbps" => 1.1,
              "negotiated-latency-ms" => 125,
              "caller-address" => "127.0.0.1:52341",
              "rtt-ms" => 20.0,
              "bandwidth-mbps" => 77.172,
              "packet-loss-percent" => 0.5,
              "retransmitted-packets-per-sec" => 3
            }
          },
          %{"id" => "dest-2", "bytes_out_per_sec" => 92_000},
          %{"id" => "dest-ignored"},
          %{"bytes_out_per_sec" => 11_111}
        ],
        "total-bytes-received" => 39_622_128
      }
    }

    rows = MetricSelector.select_rows(envelope)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "route" and row.entity_id == "route-1" and
               row.metric_key == "active_source_position" and row.value_double == 1.0
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "source" and row.entity_id == "source-1" and
               row.metric_key == "bytes_in_per_sec" and row.value_double == 191_572.0
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "source" and row.entity_id == "source-1" and
               row.metric_key == "srt_packet_loss" and row.value_double == 42.0
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "source" and row.entity_id == "source-1" and
               row.metric_key == "srt_packet_loss_percent" and row.value_double == 0.01
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "source" and row.entity_id == "source-1" and
               row.metric_key == "srt_rtt_ms" and row.value_double == 12.5
           end)

    for {metric_key, value} <- [
          {"srt_packets_total", 855.0},
          {"srt_packets_lost_total", 42.0},
          {"srt_packets_retransmitted_total", 0.0},
          {"srt_packets_dropped_total", 0.0},
          {"srt_nack_total", 0.0},
          {"srt_bytes_total", 198_360.0}
        ] do
      assert Enum.any?(rows, fn row ->
               row.entity_type == "source" and row.entity_id == "source-1" and
                 row.metric_key == metric_key and row.value_double == value
             end)
    end

    assert Enum.any?(rows, fn row ->
             row.entity_type == "source" and row.entity_id == "source-1" and
               row.metric_key == "bytes_in_total" and row.value_double == 39_622_128.0
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "destination" and row.entity_id == "dest-1" and
               row.metric_key == "bytes_out_per_sec" and row.value_double == 186_684.0
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "destination" and row.entity_id == "dest-2" and
               row.metric_key == "bytes_out_per_sec" and row.value_double == 92_000.0
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "destination" and row.entity_id == "dest-1" and
               row.metric_key == "srt_packet_loss" and row.value_double == 7.0
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "destination" and row.entity_id == "dest-1" and
               row.metric_key == "srt_packet_loss_percent" and row.value_double == 0.5
           end)

    assert Enum.any?(rows, fn row ->
             row.entity_type == "destination" and row.entity_id == "dest-1" and
               row.metric_key == "srt_retransmitted_packets_per_sec" and row.value_double == 3.0
           end)

    for {metric_key, value} <- [
          {"srt_packets_total", 855.0},
          {"srt_packets_lost_total", 7.0},
          {"srt_packets_retransmitted_total", 8.0},
          {"srt_packets_dropped_total", 0.0},
          {"srt_nack_total", 9.0},
          {"srt_bytes_total", 198_360.0}
        ] do
      assert Enum.any?(rows, fn row ->
               row.entity_type == "destination" and row.entity_id == "dest-1" and
                 row.metric_key == metric_key and row.value_double == value
             end)
    end

    assert Enum.any?(rows, fn row ->
             row.entity_type == "destination" and row.entity_id == "dest-1" and
               row.metric_key == "bytes_out_total" and row.value_double == 39_622_128.0
           end)
  end

  test "select_rows omits source counter rows when counter fields are missing" do
    rows =
      MetricSelector.select_rows(%{
        route_id: "route-1",
        stats: %{
          "source" => %{
            "srt" => %{
              "rtt-ms" => 12.5
            }
          }
        },
        metadata: %{active_source_id: "source-1"}
      })

    refute Enum.any?(rows, fn row -> String.ends_with?(row.metric_key, "_total") end)
  end

  test "select_rows returns empty list for invalid envelope" do
    assert MetricSelector.select_rows(%{}) == []
  end
end
