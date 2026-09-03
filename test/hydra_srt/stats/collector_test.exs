defmodule HydraSrt.Stats.CollectorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias HydraSrt.Stats.Collector

  @interval_ms 10_000

  test "flush_rows averages samples for the same avg series in one bucket" do
    row_1 = sample_row(~U[2026-01-01 00:00:01Z], "dest-1", 100.0)
    row_2 = sample_row(~U[2026-01-01 00:00:09Z], "dest-1", 200.0)

    rows_by_bucket_and_series =
      %{}
      |> Collector.merge_rows([row_1], @interval_ms)
      |> Collector.merge_rows([row_2], @interval_ms)

    assert map_size(rows_by_bucket_and_series) == 1

    assert {_, _, :ok} =
             Collector.flush_rows(
               rows_by_bucket_and_series,
               map_size(rows_by_bucket_and_series),
               fn rows ->
                 assert [%{value_double: 150.0}] = rows
                 :ok
               end
             )
  end

  test "flush_rows keeps the latest value for total counters" do
    row_1 = sample_row(~U[2026-01-01 00:00:01Z], "dest-1", 100.0, "srt_packets_total")
    row_2 = sample_row(~U[2026-01-01 00:00:09Z], "dest-1", 200.0, "srt_packets_total")

    rows_by_bucket_and_series = Collector.merge_rows(%{}, [row_1, row_2], @interval_ms)

    assert {_, _, :ok} =
             Collector.flush_rows(
               rows_by_bucket_and_series,
               map_size(rows_by_bucket_and_series),
               fn rows ->
                 assert [%{value_double: 200.0}] = rows
                 :ok
               end
             )
  end

  test "flush_rows keeps the latest value for the legacy cumulative loss counter" do
    row_1 = sample_row(~U[2026-01-01 00:00:01Z], "source-1", 10.0, "srt_packet_loss")
    row_2 = sample_row(~U[2026-01-01 00:00:09Z], "source-1", 30.0, "srt_packet_loss")

    rows_by_bucket_and_series = Collector.merge_rows(%{}, [row_1, row_2], @interval_ms)

    assert {_, _, :ok} =
             Collector.flush_rows(
               rows_by_bucket_and_series,
               map_size(rows_by_bucket_and_series),
               fn rows ->
                 assert [%{value_double: 30.0}] = rows
                 :ok
               end
             )
  end

  test "flush_rows keeps the latest active source position" do
    row_1 = sample_row(~U[2026-01-01 00:00:01Z], "source-1", 1.0, "active_source_position")
    row_2 = sample_row(~U[2026-01-01 00:00:09Z], "source-1", 2.0, "active_source_position")

    rows_by_bucket_and_series = Collector.merge_rows(%{}, [row_1, row_2], @interval_ms)

    assert {_, _, :ok} =
             Collector.flush_rows(
               rows_by_bucket_and_series,
               map_size(rows_by_bucket_and_series),
               fn rows ->
                 assert [%{value_double: 2.0}] = rows
                 :ok
               end
             )
  end

  test "flush_rows emits the average and maximum for burst metrics" do
    metric_key = "srt_packet_loss_percent"
    row_1 = sample_row(~U[2026-01-01 00:00:01Z], "dest-1", 1.0, metric_key)
    row_2 = sample_row(~U[2026-01-01 00:00:09Z], "dest-1", 9.0, metric_key)

    rows_by_bucket_and_series = Collector.merge_rows(%{}, [row_1, row_2], @interval_ms)

    assert {_, _, :ok} =
             Collector.flush_rows(
               rows_by_bucket_and_series,
               map_size(rows_by_bucket_and_series),
               fn rows ->
                 assert length(rows) == 2
                 assert Enum.any?(rows, &(&1.metric_key == metric_key and &1.value_double == 5.0))

                 assert Enum.any?(rows, fn row ->
                          row.metric_key == "#{metric_key}_max" and row.value_double == 9.0
                        end)

                 :ok
               end
             )
  end

  test "merge_rows keeps separate entries for different 10s windows" do
    row_1 = sample_row(~U[2026-01-01 00:00:09Z], "dest-1", 100.0)
    row_2 = sample_row(~U[2026-01-01 00:00:10Z], "dest-1", 200.0)

    rows_by_bucket_and_series =
      %{}
      |> Collector.merge_rows([row_1], @interval_ms)
      |> Collector.merge_rows([row_2], @interval_ms)

    assert map_size(rows_by_bucket_and_series) == 2
  end

  test "merge_rows keeps separate entries for different destinations in same window" do
    row_1 = sample_row(~U[2026-01-01 00:00:05Z], "dest-1", 100.0)
    row_2 = sample_row(~U[2026-01-01 00:00:06Z], "dest-2", 200.0)

    rows_by_bucket_and_series =
      %{}
      |> Collector.merge_rows([row_1, row_2], @interval_ms)

    assert map_size(rows_by_bucket_and_series) == 2
  end

  test "flush_rows inserts one aggregated row per series per bucket" do
    row_1 = sample_row(~U[2026-01-01 00:00:01Z], "dest-1", 100.0)
    row_2 = sample_row(~U[2026-01-01 00:00:09Z], "dest-1", 200.0)
    row_3 = sample_row(~U[2026-01-01 00:00:06Z], "dest-2", 300.0)

    rows_by_bucket_and_series =
      %{}
      |> Collector.merge_rows([row_1], @interval_ms)
      |> Collector.merge_rows([row_2], @interval_ms)
      |> Collector.merge_rows([row_3], @interval_ms)

    assert map_size(rows_by_bucket_and_series) == 2

    assert {rows_after_flush, row_count_after_flush, :ok} =
             Collector.flush_rows(
               rows_by_bucket_and_series,
               map_size(rows_by_bucket_and_series),
               fn rows ->
                 send(self(), {:inserted_rows, rows})
                 :ok
               end
             )

    assert rows_after_flush == %{}
    assert row_count_after_flush == 0

    assert_receive {:inserted_rows, rows}
    assert length(rows) == 2
    assert Enum.any?(rows, &(&1.entity_id == "dest-1" and &1.value_double == 150.0))
    assert Enum.any?(rows, &(&1.entity_id == "dest-2" and &1.value_double == 300.0))
  end

  test "enforce_max_buffer keeps newest rows by timestamp" do
    state = %{max_buffer_size: 5, downsample_interval_ms: @interval_ms}

    rows_by_bucket_and_series =
      Enum.reduce(1..10, %{}, fn i, acc ->
        row =
          sample_row(
            DateTime.add(~U[2026-01-01 00:00:00Z], i, :second),
            "dest-#{i}",
            i * 1.0
          )

        Collector.merge_rows(acc, [row], @interval_ms)
      end)

    log =
      capture_log(fn ->
        {kept, count} = Collector.enforce_max_buffer(rows_by_bucket_and_series, 10, state)
        assert count == 5

        kept_ids =
          kept |> Map.values() |> Enum.map(& &1.row.entity_id) |> Enum.sort()

        assert kept_ids == ["dest-10", "dest-6", "dest-7", "dest-8", "dest-9"]
      end)

    assert log =~ "Stats collector dropped 5 buffered rows due to max_buffer_size"
  end

  test "failed flush keeps accumulators for the next flush retry" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    rows_by_bucket_and_series =
      Collector.merge_rows(
        %{},
        [sample_row(~U[2026-01-01 00:00:01Z], "dest-1", 100.0)],
        @interval_ms
      )

    insert_rows_fun = fn rows ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)

      if attempt == 1 do
        assert [%{value_double: 100.0}] = rows
        {:error, :victoria_metrics_down}
      else
        send(self(), {:retried_rows, rows})
        :ok
      end
    end

    assert {kept, 1, {:error, :victoria_metrics_down}} =
             Collector.flush_rows(rows_by_bucket_and_series, 1, insert_rows_fun)

    assert kept == rows_by_bucket_and_series
    assert {%{}, 0, :ok} = Collector.flush_rows(kept, 1, insert_rows_fun)
    assert_receive {:retried_rows, [%{value_double: 100.0}]}
  end

  test "caps buffer after failed flush in GenServer" do
    name = :"collector_limit_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Collector,
         %{
           name: name,
           flush_interval_ms: 100_000,
           max_batch_size: 100,
           max_buffer_size: 5,
           insert_rows_fun: fn _rows -> {:error, :victoria_metrics_down} end,
           downsample_interval_ms: @interval_ms
         }}
      )

    log =
      capture_log(fn ->
        for i <- 1..10 do
          send(name, {
            :ingest_route_stats,
            "route-1",
            %{
              "destinations" => [
                %{"id" => "dest-#{i}", "bytes_out_per_sec" => i * 1.0}
              ]
            },
            %{}
          })
        end

        _ = :sys.get_state(pid)
      end)

    assert log =~ "dropped"
    assert log =~ "max_buffer_size"

    state = :sys.get_state(pid)
    assert state.row_count == 5
  end

  def sample_row(ts, entity_id, value, metric_key \\ "bytes_out_per_sec") do
    %{
      ts: ts,
      route_id: "route-1",
      entity_type: if(metric_key == "active_source_position", do: "route", else: "destination"),
      entity_id: entity_id,
      metric_key: metric_key,
      value_type: "double",
      value_double: value,
      value_bigint: nil,
      value_text: nil
    }
  end
end
