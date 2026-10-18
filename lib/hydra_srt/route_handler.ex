defmodule HydraSrt.RouteHandler do
  @moduledoc false

  require Logger
  @behaviour :gen_statem

  @youtube_refresh_lead_seconds div(:timer.minutes(10), 1_000)

  # Operator stops shut down the handler through its supervisor. A live port
  # exit therefore always means process loss and must use the retry path.
  @normal_port_exit_reasons []

  # Hard-retry backoff: exponential with decorrelated jitter, a ceiling, and a
  # circuit breaker after the maximum attempts. The retry budget is re-derived on
  # boot recovery and is not persisted across restarts.
  @retry_base_ms :timer.seconds(1)
  @retry_ceiling_ms :timer.seconds(30)
  @retry_max_attempts 5

  # A route's hard-retry budget (attempt counter + backoff) resets to zero
  # only once the route has proven itself by staying continuously healthy -
  # actual data flowing - for at least this long. A freshly spawned OS
  # process is NOT "healthy": plenty of retryable failures (a wrong SRT
  # passphrase, for example) let the process spawn and even accept its
  # initial command before dying on the real handshake a few hundred
  # milliseconds later. Resetting the budget at spawn time - the old
  # behaviour - let that class of failure spawn/die forever at the ~1-3s
  # starting backoff: the 30s ceiling and the "reconnecting" visibility this
  # whole retry design exists to provide were never reached. Reusing the
  # ceiling itself as the health bar means a route is never trusted as
  # "recovered" faster than the worst case it would already have been
  # waiting between attempts. This is the one place the reset happens; see
  # `note_healthy_tick/1`.
  @retry_budget_reset_after_healthy_ms @retry_ceiling_ms

  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Db
  alias HydraSrt.Helpers
  alias HydraSrt.LogSanitizer
  alias HydraSrt.Ndi.FeaturePolicy
  alias HydraSrt.Stats.EventLogger
  alias HydraSrt.SystemInterfaces
  alias HydraSrt.Youtube
  alias HydraSrt.Youtube.Cache, as: YoutubeCache
  alias HydraSrt.Youtube.FeaturePolicy, as: YoutubeFeaturePolicy
  alias HydraSrt.Youtube.Url, as: YoutubeUrl
  import Ecto.Query, only: [from: 2]
  import Bitwise

  @ndi_default_media_policy "video_and_audio_required"
  @ndi_default_bandwidth "highest"
  @ndi_default_color_format "uyvy-bgra"
  @ndi_default_connect_timeout_ms 10_000
  @ndi_default_receive_timeout_ms 5_000
  @ndi_default_track_discovery_timeout_ms 10_000
  @ndi_default_max_queue_length 4

  @type source_loss_signal :: :reconnecting | :zero_bitrate

  @type json_map :: %{optional(String.t()) => term()}

  @type route_terminal_t :: %{
          reason_code: String.t() | nil,
          retryable: boolean() | nil,
          retry_domain: String.t() | nil,
          detail: String.t() | nil,
          observed_at_ms: integer() | nil,
          sequence: integer() | nil
        }

  @type endpoint_health_payload :: json_map()
  @type route_terminal_payload :: json_map()

  @type data_t :: %{
          required(:id) => String.t(),
          required(:port) => port() | nil,
          required(:route) => json_map(),
          required(:port_buffer) => String.t(),
          required(:shutdown_reason) => term() | nil,
          required(:active_source_id) => String.t() | nil,
          required(:last_manual_source_id) => String.t() | nil,
          required(:process_instance_id) => String.t() | nil,
          required(:endpoint_health) => %{optional(String.t()) => endpoint_health_payload()},
          required(:route_terminal) => route_terminal_t() | nil,
          required(:source_loss_since_ms) => integer() | nil,
          required(:source_loss_signal) => source_loss_signal() | nil,
          required(:source_data_seen?) => boolean(),
          required(:healthy_since_ms) => integer() | nil,
          required(:cooldown_until) => integer() | nil,
          required(:primary_stable_since_ms) => integer() | nil,
          required(:last_primary_probe_ms) => integer() | nil,
          required(:primary_probe_inflight?) => boolean(),
          required(:retry_scheduled?) => boolean(),
          required(:retry_attempt) => non_neg_integer(),
          required(:retry_prev_backoff_ms) => non_neg_integer() | nil,
          required(:retry_last_logged_ms) => integer() | nil,
          required(:retry_circuit_open?) => boolean(),
          required(:recovery_blocked?) => boolean(),
          required(:recovering?) => boolean(),
          optional(:stats_baseline) => map() | nil,
          optional(:stats_reset_at) => DateTime.t() | nil,
          optional(:stats_rebased_at) => DateTime.t() | nil,
          optional(:last_stats) => map() | nil,
          optional(:youtube_resolution_inflight?) => boolean(),
          optional(:youtube_failover_inflight?) => boolean(),
          optional(:now_ms) => integer(),
          optional(:source_loss_elapsed_ms) => non_neg_integer()
        }

  @type typed_endpoint :: json_map()
  @type native_config :: json_map()

  @type native_json_parse_result ::
          {:pipeline_status, String.t(), String.t() | nil}
          | {:srt_access, json_map()}
          | {:pipeline_log, json_map()}
          | {:endpoint_health, endpoint_health_payload()}
          | {:media_info, json_map()}
          | {:route_terminal, route_terminal_payload()}
          | {:stats, json_map()}
          | :unknown

  @type endpoint_health_identity :: %{
          process_instance_id: String.t() | nil,
          config_revision: String.t() | nil,
          last_sequence: non_neg_integer(),
          endpoint_health: %{optional(String.t()) => endpoint_health_payload()}
        }

  @endpoint_health_call_timeout_ms :timer.seconds(5)

  @spec start_link(map()) :: {:ok, pid()} | {:error, term()}
  def start_link(args), do: :gen_statem.start_link(__MODULE__, args, [])

  @spec switch_source(pid(), String.t()) :: :ok
  @spec switch_source(pid(), String.t(), String.t()) :: :ok
  def switch_source(pid, source_id, reason \\ "manual"),
    do: :gen_statem.cast(pid, {:switch_source, source_id, reason})

  @spec switch_source_sync(pid(), String.t()) :: term()
  @spec switch_source_sync(pid(), String.t(), String.t()) :: term()
  @spec switch_source_sync(pid(), String.t(), String.t(), timeout()) :: term()
  def switch_source_sync(pid, source_id, reason \\ "manual", timeout \\ 15_000),
    do: :gen_statem.call(pid, {:switch_source, source_id, reason}, timeout)

  @doc """
  Returns the live endpoint-health map plus process identity from a RouteHandler.

  Uses a bounded `:gen_statem.call` timeout so HTTP snapshot handlers cannot hang.
  """
  @spec get_endpoint_health(pid()) :: {:ok, endpoint_health_identity()} | {:error, term()}
  def get_endpoint_health(pid) when is_pid(pid),
    do: get_endpoint_health(pid, @endpoint_health_call_timeout_ms)

  @spec get_endpoint_health(pid(), timeout()) ::
          {:ok, endpoint_health_identity()} | {:error, term()}
  def get_endpoint_health(pid, timeout) when is_pid(pid) do
    try do
      :gen_statem.call(pid, :get_endpoint_health, timeout)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @doc false
  @spec reset_stats(pid(), timeout()) :: {:ok, DateTime.t()} | {:error, term()}
  def reset_stats(pid, timeout) when is_pid(pid) do
    try do
      :gen_statem.call(pid, :reset_stats, timeout)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @doc false
  @spec clear_stats_reset(pid(), timeout()) :: {:ok, nil} | {:error, term()}
  def clear_stats_reset(pid, timeout) when is_pid(pid) do
    try do
      :gen_statem.call(pid, :clear_stats_reset, timeout)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @doc false
  @spec clear_stats_baseline(data_t()) :: data_t()
  def clear_stats_baseline(data) when is_map(data) do
    %{data | stats_baseline: nil, stats_reset_at: nil, stats_rebased_at: nil, last_stats: nil}
  end

  @doc false
  @spec counter_fields() :: [binary()]
  def counter_fields do
    [
      "packets-sent",
      "packets-sent-lost",
      "packets-retransmitted",
      "packets-sent-dropped",
      "packets-received",
      "packets-received-lost",
      "packets-received-retransmitted",
      "packets-received-dropped",
      "packet-ack-sent",
      "packet-ack-received",
      "packet-nack-sent",
      "packet-nack-received",
      "bytes-sent",
      "bytes-received",
      "bytes-retransmitted",
      "bytes-sent-dropped",
      "send-duration-us"
    ]
  end

  @doc false
  @spec stats_counters(map()) :: map()
  def stats_counters(stats) when is_map(stats) do
    counters =
      case stats["source"] do
        source when is_map(source) ->
          source_counters =
            %{}
            |> maybe_put_numeric("bytes_in_total", source["bytes_in_total"])
            |> maybe_put_srt_counters(source["srt"])

          %{{:source, nil} => source_counters}

        _ ->
          %{}
      end

    counters =
      case stats["destinations"] do
        destinations when is_list(destinations) ->
          Enum.reduce(destinations, counters, fn
            %{"id" => id} = destination, acc when is_binary(id) ->
              destination_counters =
                %{}
                |> maybe_put_numeric("bytes_out_total", destination["bytes_out_total"])
                |> maybe_put_numeric("drops", destination["drops"])
                |> maybe_put_srt_counters(destination["srt"])

              Map.put(acc, {:destination, id}, destination_counters)

            _destination, acc ->
              acc
          end)

        _ ->
          counters
      end

    maybe_put_numeric(counters, "total-bytes-received", stats["total-bytes-received"])
  end

  @doc false
  @spec since_reset(map(), map(), DateTime.t(), DateTime.t() | nil) :: map()
  def since_reset(stats, baseline, reset_at, rebased_at)
      when is_map(stats) and is_map(baseline) and is_struct(reset_at, DateTime) do
    current = stats_counters(stats)

    diff = fn current_entity, baseline_entity ->
      Enum.reduce(current_entity, %{}, fn
        {"srt", current_srt}, acc when is_map(current_srt) ->
          srt_deltas =
            Enum.reduce(current_srt, %{}, fn {field, current_value}, srt_acc ->
              case baseline_entity["srt"] do
                baseline_srt when is_map(baseline_srt) ->
                  case baseline_srt[field] do
                    baseline_value when is_number(baseline_value) and is_number(current_value) ->
                      Map.put(srt_acc, field, current_value - baseline_value)

                    _ ->
                      srt_acc
                  end

                _ ->
                  srt_acc
              end
            end)

          if map_size(srt_deltas) == 0, do: acc, else: Map.put(acc, "srt", srt_deltas)

        {field, current_value}, acc when is_number(current_value) ->
          case baseline_entity[field] do
            baseline_value when is_number(baseline_value) ->
              Map.put(acc, field, current_value - baseline_value)

            _ ->
              acc
          end

        _entry, acc ->
          acc
      end)
    end

    source_delta = diff.(current[{:source, nil}] || %{}, baseline[{:source, nil}] || %{})

    destinations =
      Enum.flat_map(current, fn
        {{:destination, id}, current_destination} when is_binary(id) ->
          case baseline[{:destination, id}] do
            baseline_destination when is_map(baseline_destination) ->
              [Map.put(diff.(current_destination, baseline_destination), "id", id)]

            _ ->
              []
          end

        _entry ->
          []
      end)

    result = %{
      "reset_at" => DateTime.to_iso8601(reset_at),
      "rebased_at" => if(is_nil(rebased_at), do: nil, else: DateTime.to_iso8601(rebased_at)),
      "source" => source_delta,
      "destinations" => destinations
    }

    case {current["total-bytes-received"], baseline["total-bytes-received"]} do
      {current_value, baseline_value}
      when is_number(current_value) and is_number(baseline_value) ->
        Map.put(result, "total-bytes-received", current_value - baseline_value)

      _ ->
        result
    end
  end

  @doc false
  @spec counters_regressed?(map(), map()) :: boolean()
  def counters_regressed?(current, baseline) when is_map(current) and is_map(baseline) do
    Enum.any?(baseline, fn
      {field, baseline_value} when is_map(baseline_value) ->
        case current[field] do
          current_value when is_map(current_value) ->
            counters_regressed?(current_value, baseline_value)

          _ ->
            false
        end

      {field, baseline_value} when is_number(baseline_value) ->
        case current[field] do
          current_value when is_number(current_value) -> current_value < baseline_value
          _ -> false
        end

      _entry ->
        false
    end)
  end

  @spec maybe_put_numeric(map(), binary(), term()) :: map()
  def maybe_put_numeric(map, key, value) when is_map(map) and is_binary(key) and is_number(value),
    do: Map.put(map, key, value)

  def maybe_put_numeric(map, _key, _value) when is_map(map), do: map

  @spec maybe_put_srt_counters(map(), term()) :: map()
  def maybe_put_srt_counters(map, srt) when is_map(map) and is_map(srt) do
    counters =
      Enum.reduce(counter_fields(), %{}, fn field, acc ->
        case srt[field] do
          value when is_number(value) -> Map.put(acc, field, value)
          _ -> acc
        end
      end)

    if map_size(counters) == 0, do: map, else: Map.put(map, "srt", counters)
  end

  def maybe_put_srt_counters(map, _srt) when is_map(map), do: map

  @spec endpoint_health_identity(data_t()) :: endpoint_health_identity()
  def endpoint_health_identity(data) when is_map(data) do
    health = data[:endpoint_health] || %{}

    %{
      process_instance_id: data[:process_instance_id],
      config_revision: config_revision_from_health(health),
      last_sequence: last_sequence_from_health(health),
      endpoint_health: health
    }
  end

  @spec config_revision_from_health(%{optional(String.t()) => endpoint_health_payload()}) ::
          String.t() | nil
  def config_revision_from_health(health) when is_map(health) do
    health
    |> Map.values()
    |> Enum.find_value(fn
      %{"config_revision" => revision} when is_binary(revision) and revision != "" -> revision
      _ -> nil
    end)
  end

  @spec last_sequence_from_health(%{optional(String.t()) => endpoint_health_payload()}) ::
          non_neg_integer()
  def last_sequence_from_health(health) when is_map(health) do
    Enum.reduce(Map.values(health), 0, fn
      %{"sequence" => sequence}, acc when is_integer(sequence) and sequence > acc ->
        sequence

      _payload, acc ->
        acc
    end)
  end

  @impl true
  def callback_mode, do: [:handle_event_function]

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    Logger.info("RouteHandler: init: #{inspect(args)}")

    {:ok, route} = Db.get_route(args.id, true)
    subscribe_youtube_refresh(route)

    data = %{
      id: args.id,
      port: nil,
      route: route,
      port_buffer: "",
      shutdown_reason: nil,
      active_source_id: route["active_source_id"],
      last_manual_source_id: nil,
      process_instance_id: nil,
      endpoint_health: %{},
      route_terminal: nil,
      # Soft source-loss window (merged triggers B+C): one debounce clock.
      source_loss_since_ms: nil,
      source_loss_signal: nil,
      source_data_seen?: false,
      healthy_since_ms: nil,
      cooldown_until: nil,
      primary_stable_since_ms: nil,
      last_primary_probe_ms: nil,
      primary_probe_inflight?: false,
      retry_scheduled?: false,
      retry_attempt: 0,
      retry_prev_backoff_ms: nil,
      retry_last_logged_ms: nil,
      retry_circuit_open?: false,
      recovery_blocked?: false,
      recovering?: false,
      stats_baseline: nil,
      stats_reset_at: nil,
      stats_rebased_at: nil,
      last_stats: nil,
      youtube_resolution_inflight?: false,
      youtube_failover_inflight?: false
    }

    {:ok, :start, data, {:next_event, :internal, :start}}
  end

  @impl true
  def handle_event(:internal, :start, _state, data) do
    Logger.info("RouteHandler: starting route #{data.id}")

    case maybe_start_youtube_resolution(data) do
      {:waiting, next_data} ->
        {:keep_state, next_data}

      :ready ->
        start_native_route(data)
    end
  end

  def handle_event(:info, {:youtube_resolved, source_id, result}, _state, data)
      when is_binary(source_id) and is_map(data) do
    if source_id == data.active_source_id do
      next_data = Map.put(data, :youtube_resolution_inflight?, false)

      case result do
        {:ok, media} ->
          schedule_youtube_refresh(data, media)
          resolved_data = persist_resolved_media(next_data, media)

          next_data =
            if is_port(resolved_data.port) do
              close_existing_port(resolved_data.port)
              kill_stale_pipeline_processes(resolved_data.id, "youtube_refresh")

              %{clear_stats_baseline(resolved_data) | port: nil}
            else
              resolved_data
            end

          {:keep_state, next_data, [{:next_event, :internal, :start}]}

        {:error, reason} ->
          Logger.warning(
            "RouteHandler: YouTube resolution failed route_id=#{data.id} reason=#{inspect(reason)}"
          )

          next_data
          |> mark_restarting_runtime()
          |> schedule_retry_restart()
          |> then(&{:keep_state, &1})
      end
    else
      {:keep_state, Map.put(data, :youtube_resolution_inflight?, false)}
    end
  end

  def handle_event(:info, {:youtube_failover_resolved, source_id, reason, result}, _state, data)
      when is_binary(source_id) and is_binary(reason) and is_map(data) do
    next_data = Map.put(data, :youtube_failover_inflight?, false)

    case result do
      {:ok, media} ->
        case source_record_from_route(next_data.route, source_id) do
          {:ok, %{"schema" => "YOUTUBE"} = source} ->
            schedule_youtube_refresh_for_source(source, media)

            next_data = persist_resolved_media_for_source(next_data, source_id, media)

            case failover_to_source(next_data, source_id, reason) do
              {:ok, switched} -> {:keep_state, switched}
              {:error, _reason, failed} -> {:keep_state, failed}
              {:error, _reason} -> {:keep_state, next_data}
            end

          _ ->
            {:keep_state, next_data}
        end

      {:error, resolution_reason} ->
        Logger.warning(
          "RouteHandler: YouTube failover resolution failed route_id=#{data.id} source_id=#{source_id} reason=#{inspect(resolution_reason)}"
        )

        {:keep_state, next_data |> mark_restarting_runtime() |> schedule_retry_restart()}
    end
  end

  def handle_event(:info, {:youtube_refresh, canonical_url}, _state, data)
      when is_binary(canonical_url) and is_map(data) do
    case source_record_from_route(data.route, data.active_source_id) do
      {:ok, %{"schema" => "YOUTUBE", "youtube_url" => url} = source} ->
        if url == canonical_url and not data[:youtube_resolution_inflight?] and
             is_nil(YoutubeFeaturePolicy.deny_reason(:enabled)) do
          :ok = Youtube.invalidate(url)
          route_handler = self()
          opts = youtube_resolution_options(source)
          source_id = source["id"]

          {:ok, _pid} =
            Task.Supervisor.start_child(HydraSrt.TaskSupervisor, fn ->
              result = Youtube.resolve(url, opts)
              send(route_handler, {:youtube_resolved, source_id, result})
            end)

          {:keep_state, Map.put(data, :youtube_resolution_inflight?, true)}
        else
          {:keep_state, data}
        end

      _ ->
        {:keep_state, data}
    end
  end

  def handle_event(:info, {port, {:data, info}}, _state, %{port: port} = data)
      when is_binary(info) do
    new_data = consume_port_output(info, data)
    {:keep_state, new_data}
  end

  def handle_event(:info, {port, {:data, {:eol, info}}}, _state, %{port: port} = data)
      when is_binary(info) do
    new_data = consume_port_output(info <> "\n", data)
    {:keep_state, new_data}
  end

  def handle_event(:info, {port, {:data, {:noeol, info}}}, _state, %{port: port} = data)
      when is_binary(info) do
    new_data = consume_port_output(info, data)
    {:keep_state, new_data}
  end

  # Ignore stale port data after a source switch; old processes may still flush output.
  def handle_event(:info, {_stale_port, {:data, _info}}, _state, data) do
    {:keep_state, data}
  end

  def handle_event(:info, {port, {:exit_status, status}}, _state, %{port: port} = data) do
    log_fun = if status == 0, do: &Logger.info/1, else: &Logger.error/1
    log_fun.("RouteHandler: native pipeline exited with status #{status}")

    next_data =
      maybe_schedule_hard_retry_after_process_loss(%{clear_stats_baseline(data) | port: nil})

    {:keep_state, next_data}
  end

  def handle_event(:info, {_stale_port, {:exit_status, _status}}, _state, data) do
    {:keep_state, data}
  end

  def handle_event(:info, {:EXIT, port, reason}, _state, %{port: port} = data) do
    Logger.info("RouteHandler: port exit #{inspect(reason)}")

    if reason == :epipe do
      kill_stale_pipeline_processes(data.id, "epipe")
    end

    if Enum.member?(@normal_port_exit_reasons, reason) do
      {:stop, :normal, %{clear_stats_baseline(data) | shutdown_reason: {:port_exit, reason}}}
    else
      next_data =
        maybe_schedule_hard_retry_after_process_loss(%{clear_stats_baseline(data) | port: nil})

      {:keep_state, next_data}
    end
  end

  def handle_event(:info, {:EXIT, _stale_port, _reason}, _state, data) do
    {:keep_state, data}
  end

  def handle_event(:info, :retry_start, _state, data) do
    next_data =
      if Map.get(data, :recovery_blocked?, false) or Map.get(data, :retry_circuit_open?, false) do
        %{data | retry_scheduled?: false}
      else
        data = Map.put(data, :retry_scheduled?, false)

        case maybe_start_youtube_resolution(data) do
          {:waiting, next_data} -> next_data
          :ready -> retry_pipeline_start(data)
        end
      end

    {:keep_state, next_data}
  end

  def handle_event(:cast, {:switch_source, source_id, reason}, _state, data)
      when is_binary(source_id) and is_binary(reason) do
    case failover_to_source(data, source_id, reason) do
      {:ok, next_data} -> {:keep_state, next_data}
      {:error, _reason, next_data} -> {:keep_state, next_data}
      {:error, _reason} -> {:keep_state, data}
    end
  end

  def handle_event({:call, from}, :get_endpoint_health, _state, data) do
    {:keep_state, data, [{:reply, from, {:ok, endpoint_health_identity(data)}}]}
  end

  def handle_event({:call, from}, :reset_stats, _state, data) do
    case data[:last_stats] do
      stats when is_map(stats) ->
        reset_at = DateTime.utc_now()
        EventLogger.log_stats_reset(data.id, "set")

        {:keep_state,
         %{
           data
           | stats_baseline: stats_counters(stats),
             stats_reset_at: reset_at,
             stats_rebased_at: nil
         }, [{:reply, from, {:ok, reset_at}}]}

      _ ->
        {:keep_state, data, [{:reply, from, {:error, :no_stats_yet}}]}
    end
  end

  def handle_event({:call, from}, :clear_stats_reset, _state, data) do
    # Clearing is idempotent, but only an actual baseline removal is an event.
    # Logging unconditionally would put reset markers on the health charts for
    # resets that never happened.
    if data[:stats_baseline] do
      EventLogger.log_stats_reset(data.id, "cleared")
    end

    {:keep_state, %{data | stats_baseline: nil, stats_reset_at: nil, stats_rebased_at: nil},
     [{:reply, from, {:ok, nil}}]}
  end

  def handle_event({:call, from}, {:switch_source, source_id, reason}, _state, data)
      when is_binary(source_id) and is_binary(reason) do
    case failover_to_source(data, source_id, reason) do
      {:ok, next_data} -> {:keep_state, next_data, [{:reply, from, :ok}]}
      {:error, reason, next_data} -> {:keep_state, next_data, [{:reply, from, {:error, reason}}]}
      {:error, reason} -> {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event(
        :info,
        {:primary_probe_result, probed_source_id, result, probe_now},
        _state,
        data
      )
      when is_binary(probed_source_id) do
    mode = backup_mode(data.route)
    sources = get_in(data, [:route, "sources"]) || []
    primary = Enum.find(sources, &(&1["position"] == 0))
    primary_stable_ms = backup_primary_stable_ms(data.route)

    cond do
      mode != "active" or is_nil(primary) ->
        {:keep_state, %{data | primary_probe_inflight?: false}}

      primary["id"] != probed_source_id or data.active_source_id == primary["id"] ->
        {:keep_state, %{data | primary_probe_inflight?: false}}

      true ->
        next_data =
          case result do
            {:ok, _} ->
              stable_since = data.primary_stable_since_ms || probe_now

              if max(probe_now - stable_since, 0) >= primary_stable_ms do
                case failover_to_source(data, primary["id"], "primary_recovered") do
                  {:ok, switched} ->
                    %{switched | primary_stable_since_ms: nil, last_primary_probe_ms: probe_now}

                  {:error, _} ->
                    %{
                      data
                      | primary_stable_since_ms: stable_since,
                        last_primary_probe_ms: probe_now
                    }
                end
              else
                %{data | primary_stable_since_ms: stable_since, last_primary_probe_ms: probe_now}
              end

            {:error, reason} ->
              EventLogger.log_source_probe_failed(data.id, primary["id"], reason)
              %{data | primary_stable_since_ms: nil, last_primary_probe_ms: probe_now}
          end

        {:keep_state, %{next_data | primary_probe_inflight?: false}}
    end
  end

  def handle_event(type, content, state, data) do
    Logger.error(
      "RouteHandler: Undefined msg: #{inspect([{"type", type}, {"content", content}, {"state", state}, {"data", data}],
      pretty: true)}"
    )

    :keep_state_and_data
  end

  @spec start_native_route(data_t()) :: :gen_statem.event_handler_result(atom())
  def start_native_route(data) when is_map(data) do
    port =
      open_and_initialize_native_pipeline(data.route, data.id, data.active_source_id)

    case port do
      {:ok, port, process_instance_id} ->
        HydraSrt.mark_route_started(data.id)

        {:next_state, :started,
         %{
           data
           | port: port,
             process_instance_id: process_instance_id,
             endpoint_health: %{},
             route_terminal: nil,
             stats_baseline: nil,
             stats_reset_at: nil,
             stats_rebased_at: nil,
             last_stats: nil,
             source_loss_since_ms: nil,
             source_loss_signal: nil,
             source_data_seen?: false,
             retry_attempt: 0,
             retry_prev_backoff_ms: nil,
             retry_circuit_open?: false,
             recovery_blocked?: false
         }}

      {:error, reason} ->
        Logger.error("RouteHandler: Failed to start: #{inspect(reason)}")

        next_data =
          if policy_deny_reason?(reason) do
            mark_terminal_failure(clear_stats_baseline(data), reason)
          else
            data
            |> clear_stats_baseline()
            |> mark_restarting_runtime()
            |> schedule_retry_restart()
          end

        {:keep_state, next_data}
    end
  end

  @spec subscribe_youtube_refresh(json_map()) :: :ok
  def subscribe_youtube_refresh(route) when is_map(route) do
    if Enum.any?(route["sources"] || [], &(&1["schema"] == "YOUTUBE")) do
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "youtube:refresh")
    end

    :ok
  end

  @spec maybe_start_youtube_resolution(data_t()) :: :ready | {:waiting, data_t()}
  def maybe_start_youtube_resolution(data) when is_map(data) do
    case source_record_from_route(data.route, data.active_source_id) do
      {:ok, %{"schema" => "YOUTUBE"} = source} ->
        if YoutubeFeaturePolicy.deny_reason(:enabled) do
          :ready
        else
          maybe_start_enabled_youtube_resolution(data, source)
        end

      _ ->
        :ready
    end
  end

  @spec maybe_start_enabled_youtube_resolution(data_t(), json_map()) ::
          :ready | {:waiting, data_t()}
  def maybe_start_enabled_youtube_resolution(data, source)
      when is_map(data) and is_map(source) do
    if data[:youtube_resolution_inflight?] do
      {:waiting, data}
    else
      opts = youtube_resolution_options(source)

      case youtube_cached_resolve(source["youtube_url"], opts) do
        {:ok, _media} ->
          :ready

        {:error, _reason} ->
          :ready

        :miss ->
          route_handler = self()
          source_id = source["id"]

          {:ok, _pid} =
            Task.Supervisor.start_child(HydraSrt.TaskSupervisor, fn ->
              result = Youtube.resolve(source["youtube_url"], opts)
              send(route_handler, {:youtube_resolved, source_id, result})
            end)

          {:waiting, Map.put(data, :youtube_resolution_inflight?, true)}
      end
    end
  end

  @spec youtube_resolution_options(json_map()) :: keyword()
  def youtube_resolution_options(source) when is_map(source) do
    [
      format_id: source["youtube_format_id"],
      quality_policy: source["youtube_quality_policy"] || "best[height<=1080]"
    ]
  end

  @spec youtube_cached_resolve(String.t(), keyword()) :: {:ok, map()} | {:error, term()} | :miss
  def youtube_cached_resolve(url, opts) when is_binary(url) and is_list(opts) do
    with {:ok, canonical_url} <- YoutubeUrl.canonicalize(url),
         {:ok, video_id} <- YoutubeUrl.video_id(canonical_url) do
      case YoutubeCache.get(video_id, opts) do
        {:hit, result} -> cached_resolve_result(result)
        {:blocked, result} -> cached_resolve_result(result)
        :miss -> :miss
      end
    else
      _ -> {:error, :invalid_url}
    end
  end

  @spec cached_resolve_result(term()) :: {:ok, map()} | {:error, term()}
  def cached_resolve_result({:ok, media}) when is_map(media), do: {:ok, media}
  def cached_resolve_result({:error, reason}), do: {:error, reason}
  def cached_resolve_result(_result), do: {:error, :invalid_output}

  @spec schedule_youtube_refresh(data_t(), map()) :: :ok
  def schedule_youtube_refresh(data, media) when is_map(data) and is_map(media) do
    with {:ok, %{"schema" => "YOUTUBE", "youtube_url" => url}} <-
           source_record_from_route(data.route, data.active_source_id),
         uri when is_binary(uri) <- media[:uri] || media["uri"] do
      _ =
        HydraSrt.Youtube.RefreshScheduler.schedule(url,
          uri: uri,
          expires_at: youtube_uri_expires_at(uri)
        )
    else
      _ -> :ok
    end

    :ok
  end

  @spec schedule_youtube_refresh_for_source(json_map(), map()) :: :ok
  def schedule_youtube_refresh_for_source(source, media)
      when is_map(source) and is_map(media) do
    with %{"schema" => "YOUTUBE", "youtube_url" => url} <- source,
         uri when is_binary(uri) <- resolved_media_value(media, :uri) do
      _ =
        HydraSrt.Youtube.RefreshScheduler.schedule(url,
          uri: uri,
          expires_at: youtube_uri_expires_at(uri)
        )
    else
      _ -> :ok
    end

    :ok
  end

  @spec persist_resolved_media(data_t(), map()) :: data_t()
  def persist_resolved_media(data, media) when is_map(data) and is_map(media) do
    case source_record_from_route(data.route, data.active_source_id) do
      {:ok, %{"schema" => "YOUTUBE", "id" => endpoint_id}} when is_binary(endpoint_id) ->
        persist_resolved_media_for_source(data, endpoint_id, media)

      _ ->
        data
    end
  end

  @spec persist_resolved_media_for_source(data_t(), String.t(), map()) :: data_t()
  def persist_resolved_media_for_source(data, endpoint_id, media)
      when is_map(data) and is_binary(endpoint_id) and is_map(media) do
    live = resolved_media_value(media, :live)
    media_info = resolved_media_value(media, :media_info)

    if is_boolean(live) and is_map(media_info) do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      media_info = add_refresh_times(media_info, media, observed_at)

      persist_youtube_media_info(
        data.id,
        endpoint_id,
        live,
        media_info,
        observed_at,
        :announced
      )

      %{data | route: put_source_live_mode(data.route, endpoint_id, live)}
    else
      data
    end
  end

  @impl true
  def terminate(reason, _state, %{id: id, shutdown_reason: shutdown_reason})
      when not is_nil(shutdown_reason) do
    Logger.info("RouteHandler: reason: #{inspect(reason)}")
    mark_route_terminated(id, shutdown_reason)
    :ok
  end

  def terminate(reason, _state, %{port: port, id: id} = data) when is_port(port) do
    Logger.info("RouteHandler: reason: #{inspect(reason)} Closing port #{inspect(port)}")
    close_port(port)
    mark_route_terminated(id, reason, data)
    :ok
  end

  def terminate(reason, _state, data) do
    Logger.info("RouteHandler: reason: #{inspect(reason)}")
    mark_route_terminated(data.id, reason, data)
    :ok
  end

  defp open_and_initialize_native_pipeline(route, route_id, source_id) do
    with {:ok, params} <- route_data_to_params(route_id, source_id) do
      route
      |> start_native_pipeline(params["process_instance_id"])
      |> initialize_native_pipeline(route_id, source_id, params, true)
    end
  end

  @spec mark_route_terminated(String.t(), term(), data_t()) :: :ok
  def mark_route_terminated(route_id, _reason, data) when is_binary(route_id) and is_map(data) do
    if completed_terminal?(data[:route_terminal], data.route) do
      _ = HydraSrt.mark_route_completed(route_id)
    else
      _ = HydraSrt.mark_route_terminated(route_id)
    end

    :ok
  end

  defp initialize_native_pipeline(port, route_id, source_id, params, retry_on_closed?) do
    Logger.info("RouteHandler: Started port: #{inspect(port)}")

    case send_initial_command(port, params) do
      :ok ->
        {:ok, port, params["process_instance_id"]}

      {:error, :closed} when retry_on_closed? ->
        kill_stale_pipeline_processes(route_id, "failed_start_closed")

        route_id
        |> Db.get_route(true)
        |> case do
          {:ok, route} ->
            with {:ok, retry_params} <- route_data_to_params(route_id, source_id) do
              route
              |> start_native_pipeline(retry_params["process_instance_id"])
              |> initialize_native_pipeline(route_id, source_id, retry_params, false)
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("RouteHandler: Failed to start: #{inspect(reason)}")
        kill_stale_pipeline_processes(route_id, "failed_start")
        {:error, reason}
    end
  end

  @spec start_native_pipeline(map(), String.t()) :: port()
  def start_native_pipeline(route, process_instance_id) do
    binary_path = get_binary_path()
    args = native_route_args(to_string(route["id"]), process_instance_id)

    base_opts = [
      :stderr_to_stdout,
      :use_stdio,
      :binary,
      :exit_status,
      :stream,
      args: Enum.map(args, &String.to_charlist/1)
    ]

    env_opts = [env: native_pipeline_port_env(route["gstDebug"])]

    Logger.info(
      "RouteHandler: start_native_pipeline: #{binary_path} #{Enum.join(args, " ")}: #{inspect(route["gstDebug"])}"
    )

    Port.open({:spawn_executable, String.to_charlist(binary_path)}, base_opts ++ env_opts)
  end

  @doc """
  Port env for the native pipeline process.

  Always sets `GST_DEBUG` / `GST_DEBUG_NO_COLOR`. When `HYDRA_NDI_RUNTIME_DIR` is
  set, also exports `NDI_RUNTIME_DIR_V6` so `gst-plugin-ndi` can dlopen `libndi`.
  """
  @spec native_pipeline_port_env(term()) :: [{charlist(), charlist()}]
  def native_pipeline_port_env(gst_debug) do
    gst =
      case gst_debug do
        debug when is_binary(debug) and debug != "" ->
          [{~c"GST_DEBUG", String.to_charlist(debug)}, {~c"GST_DEBUG_NO_COLOR", ~c"1"}]

        _ ->
          [{~c"GST_DEBUG", ~c"0"}, {~c"GST_DEBUG_NO_COLOR", ~c"1"}]
      end

    gst ++ ndi_runtime_port_env()
  end

  @doc """
  Maps product knob `HYDRA_NDI_RUNTIME_DIR` to the NDI SDK env `NDI_RUNTIME_DIR_V6`.

  Returns an empty list when the product knob is unset or blank.
  """
  @spec ndi_runtime_port_env() :: [{charlist(), charlist()}]
  def ndi_runtime_port_env do
    case System.get_env("HYDRA_NDI_RUNTIME_DIR") do
      dir when is_binary(dir) and dir != "" ->
        [{~c"NDI_RUNTIME_DIR_V6", String.to_charlist(dir)}]

      _ ->
        []
    end
  end

  @spec native_route_args(String.t(), String.t()) :: [String.t()]
  def native_route_args(route_id, process_instance_id) do
    ["route", "--route-id", route_id, "--process-instance-id", process_instance_id]
  end

  defp get_binary_path do
    Path.join([:code.priv_dir(:hydra_srt), "native", "hydra_srt_pipeline"])
  end

  defp send_initial_command(port, params) do
    with {:ok, params} <- Jason.encode(params),
         payload = params <> "\n",
         _ =
           Logger.info(
             "RouteHandler: initial command payload: #{LogSanitizer.sanitize_payload(params)}"
           ),
         :ok <- command_port(port, payload) do
      Logger.info("RouteHandler: sent initial command")
      :ok
    else
      {:error, reason} ->
        Logger.error("RouteHandler: send_initial_command failed: #{inspect(reason)}")
        {:error, reason}

      error ->
        Logger.error("RouteHandler: send_initial_command failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp command_port(port, payload) when is_port(port) and is_binary(payload) do
    case Port.info(port) do
      nil ->
        {:error, :closed}

      _info ->
        try do
          Port.command(port, payload)
          :ok
        rescue
          ArgumentError -> {:error, :closed}
        end
    end
  end

  defp command_port(_port, _payload), do: {:error, :invalid_port}

  defp close_port(port) do
    try do
      if not is_port(port) or is_nil(Port.info(port)) do
        :ok
      else
        case Port.info(port, :os_pid) do
          {:os_pid, pid} when is_integer(pid) ->
            Logger.info("RouteHandler: Killing external process with PID #{pid}")
            Helpers.sys_kill(pid)

          _ ->
            Logger.warning("RouteHandler: Could not get OS PID, relying on Port.close/1")
        end

        Port.close(port)
      end
    rescue
      ArgumentError ->
        :ok

      error ->
        Logger.error("RouteHandler: Error closing port: #{inspect(error)}")
    end
  end

  @spec consume_port_output(binary(), data_t()) :: data_t()
  def consume_port_output(chunk, data) when is_binary(chunk) and is_map(data) do
    [buffer | completed_lines] =
      (data.port_buffer <> chunk)
      |> String.split("\n")
      |> Enum.reverse()

    completed_lines
    |> Enum.reverse()
    |> Enum.reduce(%{data | port_buffer: buffer}, fn line, acc ->
      process_port_line(String.trim_trailing(line, "\r"), acc)
    end)
  end

  @spec process_port_line(String.t(), data_t()) :: data_t()
  def process_port_line("", data), do: data

  def process_port_line("route_id:" <> route_id, data) do
    if route_id != data.id do
      Logger.warning("RouteHandler: route_id mismatch from native pipeline: #{inspect(route_id)}")
    end

    data
  end

  def process_port_line("stats_source_stream_id:" <> _stream_id, data), do: data

  def process_port_line("{" <> _ = json, data) do
    case parse_native_json_line(json) do
      {:pipeline_status, status, reason} ->
        Logger.info("RouteHandler: pipeline_status=#{status} reason=#{inspect(reason)}")

        data =
          case status do
            "reconnecting" ->
              if listener_source_waiting?(data) do
                data
              else
                EventLogger.log_pipeline_reconnecting(data.id, data.active_source_id)
                observe_source_loss(data, :reconnecting)
              end

            "processing" ->
              %{data | recovering?: false}
              |> clear_source_loss_window()
              |> note_healthy_tick()

            "failed" ->
              # `reason` here is the legacy pipeline_status payload's own
              # field, which native always fills with a generic bucket
              # ("runtime_error") - it is not the specific cause. The real
              # cause, when this failure has one, already arrived on the wire
              # as a route_terminal event (health.rs always emits it before
              # this line) and is on record in `data.route_terminal`. Prefer
              # that so the operator-visible event carries the actual reason
              # (e.g. "SRT_AUTH_FAILED") instead of the generic bucket.
              event_reason = terminal_reason_code(data[:route_terminal]) || reason || "failed"

              EventLogger.log_pipeline_failed(
                data.id,
                data.active_source_id,
                event_reason,
                "Pipeline reported failed status"
              )

              # Prefer route_terminal when present; otherwise hard-retry (A).
              if Map.get(data, :recovery_blocked?, false) or
                   non_retryable_terminal?(data[:route_terminal]) do
                data
              else
                schedule_retry_restart(data)
              end

            _ ->
              data
          end

        case normalize_runtime_status(status, reason, data) do
          {:update, normalized_status} ->
            HydraSrt.set_route_runtime_status(data.id, normalized_status)
            data

          :ignore ->
            data
        end

      {:stats, stats} ->
        # Logger.info("RouteHandler: pipeline stats: #{json}")
        next_data = %{data | last_stats: stats}

        next_data =
          case data[:stats_baseline] do
            nil ->
              publish_stats(data.id, stats, %{
                active_source_id: data.active_source_id,
                active_source_position: active_source_position(data.route, data.active_source_id)
              })

              next_data

            baseline ->
              current_counters = stats_counters(stats)

              {baseline, rebased_at} =
                if counters_regressed?(current_counters, baseline) do
                  {current_counters, DateTime.utc_now()}
                else
                  {baseline, data[:stats_rebased_at]}
                end

              published_stats =
                Map.put(
                  stats,
                  "since_reset",
                  since_reset(stats, baseline, data[:stats_reset_at], rebased_at)
                )

              publish_stats(data.id, published_stats, %{
                active_source_id: data.active_source_id,
                active_source_position: active_source_position(data.route, data.active_source_id)
              })

              %{next_data | stats_baseline: baseline, stats_rebased_at: rebased_at}
          end

        next_data
        |> maybe_handle_zero_bitrate(stats)
        |> maybe_probe_primary_recovery()

      {:srt_access, access_event} ->
        publish_srt_access_log(data.id, access_event)
        data

      {:pipeline_log, log} ->
        publish_native_pipeline_log(data, log)
        data

      {:endpoint_health, payload} ->
        apply_endpoint_health_event(data, payload)

      {:media_info, payload} ->
        apply_media_info_event(data, payload)

      {:route_terminal, payload} ->
        apply_route_terminal_event(data, payload)

      :unknown ->
        Logger.warning("RouteHandler: unknown native json line: #{inspect(json)}")
        data
    end
  end

  def process_port_line(line, data) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)

    if len < 500 do
      Logger.debug("RouteHandler: pipeline: #{inspect(line)}")

      case HydraSrt.Stats.PipelineLogParser.parse(line) do
        {:ok, log} ->
          log = Map.put(log, :route_id, data.id)

          Phoenix.PubSub.broadcast(
            HydraSrt.PubSub,
            "pipeline_logs",
            {:pipeline_log, log}
          )

        :error ->
          :ok = HydraSrt.PipelineLogTelemetry.emit_unparsed(data.id)
      end
    end

    data
  end

  @spec maybe_handle_zero_bitrate(data_t(), json_map()) :: data_t()
  def maybe_handle_zero_bitrate(data, stats) when is_map(data) and is_map(stats) do
    bytes_in = get_in(stats, ["source", "bytes_in_per_sec"])

    cond do
      is_number(bytes_in) and bytes_in > 0 ->
        data
        |> Map.put(:source_data_seen?, true)
        |> clear_source_loss_on_bitrate_recovery()

      is_number(bytes_in) and bytes_in == 0 and listener_source_waiting?(data) ->
        data

      is_number(bytes_in) and bytes_in == 0 ->
        observe_source_loss(data, :zero_bitrate)

      true ->
        clear_source_loss_on_bitrate_recovery(data)
    end
  end

  @doc false
  @spec listener_source_waiting?(data_t()) :: boolean()
  def listener_source_waiting?(data) when is_map(data) do
    sources = data.route["sources"]
    active_source_id = data.active_source_id

    if is_list(sources) and is_binary(active_source_id) and data.source_data_seen? == false do
      case Enum.find(sources, &(&1["id"] == active_source_id)) do
        %{"schema" => "SRT", "mode" => "listener"} -> true
        _ -> false
      end
    else
      false
    end
  end

  @spec clear_source_loss_on_bitrate_recovery(data_t()) :: data_t()
  def clear_source_loss_on_bitrate_recovery(data) when is_map(data) do
    data =
      if data.recovering? do
        HydraSrt.set_route_runtime_status(data.id, "processing")
        clear_source_loss_window(%{data | recovering?: false})
      else
        clear_source_loss_window(data)
      end

    note_healthy_tick(data)
  end

  @spec clear_source_loss_window(data_t()) :: data_t()
  def clear_source_loss_window(data) when is_map(data) do
    %{data | source_loss_since_ms: nil, source_loss_signal: nil}
  end

  # See @retry_budget_reset_after_healthy_ms: this is the one place the
  # hard-retry budget resets, and it only does so once data has actually been
  # observed flowing continuously for that long. Idempotent once the budget
  # is already at zero, so a route that stays healthy for hours does not
  # keep touching retry_attempt/retry_prev_backoff_ms on every tick.
  @spec note_healthy_tick(data_t()) :: data_t()
  defp note_healthy_tick(data) do
    now = now_ms()
    healthy_since = data[:healthy_since_ms] || now
    data = Map.put(data, :healthy_since_ms, healthy_since)

    cond do
      data.retry_attempt == 0 and is_nil(data.retry_prev_backoff_ms) ->
        data

      now - healthy_since < @retry_budget_reset_after_healthy_ms ->
        data

      true ->
        Logger.info(
          "RouteHandler: retry budget reset after sustained health route_id=#{data.id} healthy_ms=#{now - healthy_since}"
        )

        %{data | retry_attempt: 0, retry_prev_backoff_ms: nil}
    end
  end

  @spec observe_source_loss(data_t(), source_loss_signal()) :: data_t()
  def observe_source_loss(data, signal)
      when is_map(data) and signal in [:reconnecting, :zero_bitrate] do
    # Data has stopped flowing - any in-progress "healthy" streak is over,
    # regardless of the guards below; see @retry_budget_reset_after_healthy_ms.
    data = Map.put(data, :healthy_since_ms, nil)

    # Single soft owner: do not race hard-retry / circuit / non-retryable terminal.
    if Map.get(data, :retry_scheduled?, false) or Map.get(data, :retry_circuit_open?, false) or
         Map.get(data, :recovery_blocked?, false) do
      data
    else
      now = now_ms()
      since = data[:source_loss_since_ms] || now

      data = %{
        data
        | source_loss_since_ms: since,
          source_loss_signal: signal
      }

      eval_data = Map.merge(data, %{now_ms: now, source_loss_elapsed_ms: max(now - since, 0)})

      if should_trigger_source_loss_failover?(eval_data) do
        trigger_source_loss_failover(data)
      else
        data
      end
    end
  end

  @spec trigger_source_loss_failover(data_t()) :: data_t()
  def trigger_source_loss_failover(data) when is_map(data) do
    reason = "source_loss"

    case next_source_for_failover(data) do
      nil ->
        mark_source_loss_without_failover_target(data, reason)

      next_source ->
        case failover_to_source(data, next_source["id"], reason) do
          {:ok, next_data} -> next_data
          {:error, _reason, next_data} -> next_data
          {:error, _} -> data
        end
    end
  end

  # No backup source configured (or none eligible): the pipeline process itself
  # is still running, so there is nothing to restart and no failover to drive -
  # but the source has stopped delivering data and that must not read as
  # healthy. Flip the runtime status to "reconnecting" once, on the transition
  # into this condition; `clear_source_loss_on_bitrate_recovery/1` flips it back
  # to "processing" by itself as soon as data resumes, and until then this is a
  # no-op on every later stats tick so it doesn't re-log/re-write every second.
  @spec mark_source_loss_without_failover_target(data_t(), String.t()) :: data_t()
  defp mark_source_loss_without_failover_target(data, reason) do
    if data.recovering? do
      data
    else
      Logger.warning(
        "RouteHandler: source loss with no failover target route_id=#{data.id} signal=#{inspect(data[:source_loss_signal])} reason=#{reason}"
      )

      EventLogger.log_pipeline_reconnecting(data.id, data.active_source_id, reason)

      case HydraSrt.set_route_runtime_status(data.id, "reconnecting") do
        {:ok, _route} ->
          :ok

        {:error, set_reason} ->
          Logger.warning(
            "RouteHandler: failed to mark route reconnecting: #{inspect(set_reason)}"
          )
      end

      %{data | recovering?: true}
    end
  end

  @spec maybe_probe_primary_recovery(data_t()) :: data_t()
  def maybe_probe_primary_recovery(data) when is_map(data) do
    mode = backup_mode(data.route)

    with true <- mode == "active",
         false <- in_cooldown?(data.cooldown_until, now_ms()),
         sources when is_list(sources) <- get_in(data, [:route, "sources"]),
         %{} = primary <- Enum.find(sources, &(&1["position"] == 0)),
         true <- is_binary(primary["id"]) and data.active_source_id != primary["id"] do
      probe_interval_ms = backup_probe_interval_ms(data.route)
      now = now_ms()

      should_probe? =
        is_nil(data.last_primary_probe_ms) or
          max(now - data.last_primary_probe_ms, 0) >= probe_interval_ms

      if should_probe? and not data.primary_probe_inflight? do
        probe_module = Application.get_env(:hydra_srt, :source_probe_module, HydraSrt.SourceProbe)
        route_handler = self()
        primary_id = primary["id"]

        Task.start(fn ->
          result = probe_module.probe(primary)
          send(route_handler, {:primary_probe_result, primary_id, result, now})
        end)

        %{data | primary_probe_inflight?: true}
      else
        data
      end
    else
      _ -> data
    end
  end

  @spec next_source_for_failover(data_t()) :: json_map() | nil
  def next_source_for_failover(data) when is_map(data) do
    mode = backup_mode(data.route)
    sources = get_in(data, [:route, "sources"]) || []

    failover_target_source(sources, data.active_source_id, mode)
  end

  @spec failover_to_source(data_t(), String.t(), String.t()) ::
          {:ok, data_t()} | {:error, term()} | {:error, term(), data_t()}
  def failover_to_source(data, source_id, reason)
      when is_map(data) and is_binary(source_id) and is_binary(reason) do
    route_id = data.id

    with {:ok, route} <- Db.get_route(route_id, true),
         {:ok, source_record} <- source_record_from_route(route, source_id),
         true <- source_record["enabled"] == true or {:error, :disabled_source} do
      case maybe_prepare_youtube_failover(data, source_record, reason) do
        {:waiting, next_data} ->
          {:error, :youtube_resolution_pending, next_data}

        {:error, fail_reason, next_data} ->
          {:error, fail_reason, next_data}

        {:ready, next_data} ->
          persist_reason = switch_reason_for_persist(route, source_id, reason, next_data)
          next_data = maybe_mark_restarting_before_switch(next_data, reason)

          with :ok <- close_existing_port(next_data.port) do
            case open_and_initialize_native_pipeline(route, route_id, source_id) do
              {:ok, port, process_instance_id} ->
                case Db.set_route_active_source(route_id, source_id, persist_reason) do
                  {:ok, _route} ->
                    cooldown_ms = backup_cooldown_ms(route)

                    last_manual_source_id =
                      if reason == "manual" do
                        source_id
                      else
                        data[:last_manual_source_id]
                      end

                    {:ok,
                     %{
                       next_data
                       | route: route,
                         port: port,
                         process_instance_id: process_instance_id,
                         endpoint_health: %{},
                         route_terminal: nil,
                         stats_baseline: nil,
                         stats_reset_at: nil,
                         stats_rebased_at: nil,
                         last_stats: nil,
                         active_source_id: source_id,
                         last_manual_source_id: last_manual_source_id,
                         source_loss_since_ms: nil,
                         source_loss_signal: nil,
                         source_data_seen?: false,
                         healthy_since_ms: nil,
                         cooldown_until: now_ms() + cooldown_ms,
                         primary_stable_since_ms: nil,
                         primary_probe_inflight?: false,
                         retry_circuit_open?: false,
                         recovery_blocked?: false,
                         recovering?: true
                     }}

                  {:error, db_reason} ->
                    close_existing_port(port)

                    failed_data =
                      next_data
                      |> clear_stats_baseline()
                      |> Map.put(:port, nil)
                      |> schedule_retry_restart()

                    {:error, db_reason, failed_data}
                end

              {:error, start_reason} ->
                failed_data =
                  if policy_deny_reason?(start_reason) do
                    mark_terminal_failure(
                      %{clear_stats_baseline(next_data) | port: nil},
                      start_reason
                    )
                  else
                    next_data
                    |> clear_stats_baseline()
                    |> Map.put(:port, nil)
                    |> schedule_retry_restart()
                  end

                {:error, start_reason, failed_data}
            end
          end
      end
    else
      {:error, fail_reason} ->
        Logger.warning(
          "RouteHandler: failover failed route_id=#{route_id} reason=#{inspect(fail_reason)}"
        )

        {:error, fail_reason}

      false ->
        {:error, :invalid_source}
    end
  end

  @spec maybe_prepare_youtube_failover(data_t(), json_map(), String.t()) ::
          {:ready, data_t()} | {:waiting, data_t()} | {:error, term(), data_t()}
  def maybe_prepare_youtube_failover(data, source, reason)
      when is_map(data) and is_map(source) and is_binary(reason) do
    if source["schema"] != "YOUTUBE" or YoutubeFeaturePolicy.deny_reason(:enabled) do
      {:ready, data}
    else
      opts = youtube_resolution_options(source)

      case youtube_cached_resolve(source["youtube_url"], opts) do
        {:ok, _media} ->
          {:ready, data}

        {:error, fail_reason} ->
          {:error, fail_reason, data}

        :miss ->
          if data[:youtube_failover_inflight?] do
            {:waiting, data}
          else
            route_handler = self()
            source_id = source["id"]

            {:ok, _pid} =
              Task.Supervisor.start_child(HydraSrt.TaskSupervisor, fn ->
                result = Youtube.resolve(source["youtube_url"], opts)
                send(route_handler, {:youtube_failover_resolved, source_id, reason, result})
              end)

            {:waiting, Map.put(data, :youtube_failover_inflight?, true)}
          end
      end
    end
  end

  # Keep operator intent in `last_switch_reason` when automatic failovers bounce the pipeline
  # (same source, or return to a source the operator last chose via API "manual").
  @spec switch_reason_for_persist(json_map(), String.t(), String.t(), data_t()) :: String.t()
  def switch_reason_for_persist(route, source_id, reason, data)
      when is_map(route) and is_map(data) and is_binary(source_id) and is_binary(reason) do
    current_active_id = Map.get(route, "active_source_id")
    prior = Map.get(route, "last_switch_reason")
    manual_id = data[:last_manual_source_id]

    cond do
      reason in ["manual", "primary_recovered"] ->
        reason

      reason in ["source_loss", "zero_bitrate", "reconnecting"] and is_binary(manual_id) and
          source_id == manual_id ->
        "manual"

      reason in ["source_loss", "zero_bitrate", "reconnecting"] and source_id == current_active_id and
          prior == "manual" ->
        "manual"

      true ->
        reason
    end
  end

  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)

  @spec close_existing_port(port() | nil | term()) :: :ok
  def close_existing_port(port) when is_port(port) do
    close_port(port)
    :ok
  end

  def close_existing_port(_), do: :ok

  @spec maybe_schedule_hard_retry_after_process_loss(data_t()) :: data_t()
  def maybe_schedule_hard_retry_after_process_loss(%{retry_scheduled?: true} = data), do: data

  def maybe_schedule_hard_retry_after_process_loss(data) when is_map(data) do
    if Map.get(data, :recovery_blocked?, false) or Map.get(data, :retry_circuit_open?, false) or
         non_retryable_terminal?(data[:route_terminal]) do
      data
    else
      data
      |> mark_restarting_runtime()
      |> schedule_retry_restart()
    end
  end

  # A route must never latch dead: once the far side comes back, however long
  # that takes, the pipeline has to reconnect on its own with nobody touching
  # it. So there is no attempt cap here - only a backoff cap. Attempts
  # 1..@retry_max_attempts behave exactly as before (status "restarting",
  # logged every time); once that budget is exhausted the backoff is already
  # pinned at the ceiling and retries simply keep firing forever. That
  # indefinite phase still has to be visible without flooding the logs, so it
  # switches the runtime status to "reconnecting" and rate-limits its own
  # logging/event to once per @retry_log_interval_ms instead of once per
  # attempt.
  @retry_log_interval_ms :timer.minutes(5)

  @spec schedule_retry_restart(data_t()) :: data_t()
  def schedule_retry_restart(%{retry_scheduled?: true} = data), do: data

  def schedule_retry_restart(%{retry_circuit_open?: true} = data), do: data

  def schedule_retry_restart(%{recovery_blocked?: true} = data), do: data

  def schedule_retry_restart(data) when is_map(data) do
    attempt = Map.get(data, :retry_attempt, 0) + 1
    delay_ms = next_retry_backoff_ms(Map.get(data, :retry_prev_backoff_ms), attempt)

    data =
      if attempt > @retry_max_attempts do
        note_prolonged_retry(data, attempt, delay_ms)
      else
        Logger.info(
          "RouteHandler: scheduling hard-retry attempt=#{attempt}/#{@retry_max_attempts} backoff_ms=#{delay_ms} route_id=#{data.id}"
        )

        data
      end

    Process.send_after(self(), :retry_start, delay_ms)

    %{
      data
      | retry_scheduled?: true,
        retry_attempt: attempt,
        retry_prev_backoff_ms: delay_ms
    }
  end

  # Past the old attempt budget: mark the route "reconnecting" (a status the UI
  # already renders) on every attempt so it never reads as healthy or as
  # permanently dead, but only *log*/record the reason on a slow cadence so a
  # route that stays down all night doesn't write one line per ~30s attempt.
  @spec note_prolonged_retry(data_t(), pos_integer(), pos_integer()) :: data_t()
  defp note_prolonged_retry(data, attempt, delay_ms) do
    reason_code = terminal_reason_code(data[:route_terminal])
    now = now_ms()
    last_logged_ms = Map.get(data, :retry_last_logged_ms)
    due_to_log? = is_nil(last_logged_ms) or now - last_logged_ms >= @retry_log_interval_ms

    if due_to_log? do
      Logger.warning(
        "RouteHandler: still reconnecting route_id=#{data.id} attempt=#{attempt} backoff_ms=#{delay_ms} reason=#{inspect(reason_code)}"
      )

      EventLogger.log_pipeline_reconnecting(data.id, data.active_source_id, reason_code)

      if youtube_source?(data.route, data.active_source_id) do
        EventLogger.log_youtube_unrecoverable(data.id, data.active_source_id, reason_code)
      end
    end

    case HydraSrt.set_route_runtime_status(data.id, "reconnecting") do
      {:ok, _route} ->
        :ok

      {:error, reason} ->
        Logger.warning("RouteHandler: failed to mark route reconnecting: #{inspect(reason)}")
    end

    %{
      data
      | recovering?: true,
        retry_last_logged_ms: if(due_to_log?, do: now, else: last_logged_ms)
    }
  end

  @spec terminal_reason_code(route_terminal_t() | nil) :: String.t() | nil
  defp terminal_reason_code(%{reason_code: reason_code}) when is_binary(reason_code),
    do: reason_code

  defp terminal_reason_code(_), do: nil

  # The YouTube checks run on every terminal and every retry, including for route
  # payloads that carry no sources at all. The strict lookup raises in that case
  # by design, so these callers need a tolerant variant instead.
  @spec optional_source_record(json_map(), String.t() | nil) ::
          {:ok, json_map()} | {:error, term()}
  defp optional_source_record(route, source_id) when is_map(route) do
    if is_list(route["sources"]) do
      source_record_from_route(route, source_id)
    else
      {:error, :invalid_source}
    end
  end

  @spec youtube_source?(json_map(), String.t() | nil) :: boolean()
  def youtube_source?(route, source_id) when is_map(route) do
    case optional_source_record(route, source_id) do
      {:ok, %{"schema" => "YOUTUBE"}} -> true
      _ -> false
    end
  end

  def youtube_source?(_route, _source_id), do: false

  @doc """
  Exponential backoff (base 1s, ×2, ceiling 30s) with AWS-style decorrelated jitter:

      min(ceiling, random_between(base, max(exp_base, previous) * 3))
  """
  @spec next_retry_backoff_ms(nil | non_neg_integer()) :: pos_integer()
  def next_retry_backoff_ms(previous_ms), do: next_retry_backoff_ms(previous_ms, 1)

  @spec next_retry_backoff_ms(nil | non_neg_integer(), pos_integer()) :: pos_integer()
  def next_retry_backoff_ms(previous_ms, attempt)
      when (is_nil(previous_ms) or (is_integer(previous_ms) and previous_ms >= 0)) and
             is_integer(attempt) and attempt >= 1 do
    shift = min(attempt - 1, 5)
    exp_base = min(@retry_ceiling_ms, @retry_base_ms * Integer.pow(2, shift))
    prev = previous_ms || @retry_base_ms
    seed = max(exp_base, prev)
    upper = min(@retry_ceiling_ms, seed * 3)
    lower = @retry_base_ms

    if upper <= lower do
      lower
    else
      :rand.uniform(upper - lower + 1) + lower - 1
    end
  end

  @spec policy_deny_reason?(term()) :: boolean()
  def policy_deny_reason?(reason) when is_binary(reason),
    do: reason in ["NDI_DISABLED", "YOUTUBE_DISABLED"]

  def policy_deny_reason?(_), do: false

  @spec non_retryable_terminal?(route_terminal_t() | route_terminal_payload() | nil) :: boolean()
  def non_retryable_terminal?(%{retryable: false}), do: true
  def non_retryable_terminal?(%{"retryable" => false}), do: true
  def non_retryable_terminal?(_), do: false

  @spec mark_terminal_failure(data_t(), String.t() | atom() | term(), String.t() | nil) ::
          data_t()
  def mark_terminal_failure(data, reason, detail \\ nil) when is_map(data) do
    reason_code =
      cond do
        is_binary(reason) -> reason
        is_atom(reason) -> Atom.to_string(reason)
        true -> "ROUTE_TERMINAL"
      end

    Logger.error(
      "RouteHandler: terminal failure (no retry) route_id=#{data.id} reason=#{inspect(reason_code)} detail=#{inspect(detail)}"
    )

    EventLogger.log_pipeline_failed(
      data.id,
      data.active_source_id,
      reason_code,
      terminal_failure_message(detail)
    )

    _ = HydraSrt.mark_route_failed(data.id)

    %{
      data
      | recovery_blocked?: true,
        retry_scheduled?: false,
        recovering?: false,
        source_loss_since_ms: nil,
        source_loss_signal: nil
    }
  end

  @spec terminal_failure_message(String.t() | nil) :: String.t()
  def terminal_failure_message(detail) when is_binary(detail) and detail != "" do
    "Terminal failure; auto-retry suppressed: #{detail}"
  end

  def terminal_failure_message(_), do: "Terminal failure; auto-retry suppressed"

  @spec mark_restarting_runtime(data_t()) :: data_t()
  def mark_restarting_runtime(data) when is_map(data) do
    case HydraSrt.set_route_runtime_status(data.id, "restarting") do
      {:ok, _route} ->
        :ok

      {:error, reason} ->
        Logger.warning("RouteHandler: failed to mark route restarting: #{inspect(reason)}")
    end

    %{data | recovering?: true}
  end

  @spec retry_pipeline_start(data_t()) :: data_t()
  def retry_pipeline_start(data) when is_map(data) do
    with {:ok, route} <- Db.get_route(data.id, true),
         {:ok, source_id} <- retry_source_id(route, data.active_source_id),
         :ok <- close_existing_port(data.port),
         {:ok, port, process_instance_id} <-
           open_and_initialize_native_pipeline(route, data.id, source_id) do
      _ = Db.set_route_active_source(data.id, source_id, "failed")

      # retry_attempt/retry_prev_backoff_ms are deliberately NOT reset here.
      # This is a process *spawn*, not proof the route is fixed - see
      # @retry_budget_reset_after_healthy_ms / `note_healthy_tick/1`, which is
      # the one place that budget resets, once real data has flowed for a
      # sustained period. Resetting on spawn let a cause that kills the
      # process moments after every restart (e.g. a wrong SRT passphrase)
      # pin the attempt counter at 1 forever, so the 30s backoff ceiling and
      # the "reconnecting" visibility were never reached.
      %{
        data
        | route: route,
          port: port,
          process_instance_id: process_instance_id,
          endpoint_health: %{},
          route_terminal: nil,
          stats_baseline: nil,
          stats_reset_at: nil,
          stats_rebased_at: nil,
          last_stats: nil,
          active_source_id: source_id,
          source_loss_since_ms: nil,
          source_loss_signal: nil,
          source_data_seen?: false,
          healthy_since_ms: nil,
          cooldown_until: nil,
          primary_stable_since_ms: nil,
          primary_probe_inflight?: false,
          retry_circuit_open?: false,
          recovery_blocked?: false,
          recovering?: true
      }
    else
      {:error, reason} ->
        Logger.warning(
          "RouteHandler: retry start failed route_id=#{data.id} reason=#{inspect(reason)}"
        )

        if policy_deny_reason?(reason) do
          mark_terminal_failure(%{clear_stats_baseline(data) | port: nil}, reason)
        else
          data
          |> clear_stats_baseline()
          |> Map.put(:port, nil)
          |> mark_restarting_runtime()
          |> schedule_retry_restart()
        end
    end
  end

  @spec retry_source_id(json_map(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def retry_source_id(route, active_source_id)
      when is_map(route) and is_binary(active_source_id) do
    sources = Map.get(route, "sources", [])

    source_id =
      case next_enabled_source(sources, active_source_id, "active") do
        %{"id" => id} when is_binary(id) -> id
        _ -> active_source_id
      end

    case source_record_from_route(route, source_id) do
      {:ok, %{"enabled" => true}} -> {:ok, source_id}
      _ -> source_record_from_route(route, nil) |> map_source_record_to_id()
    end
  end

  def retry_source_id(route, _active_source_id) when is_map(route) do
    source_record_from_route(route, nil) |> map_source_record_to_id()
  end

  @spec map_source_record_to_id({:ok, json_map()} | {:error, term()}) ::
          {:ok, String.t()} | {:error, term()}
  def map_source_record_to_id({:ok, %{"id" => id, "enabled" => true}}) when is_binary(id),
    do: {:ok, id}

  def map_source_record_to_id(_), do: {:error, :no_enabled_source}

  @spec maybe_mark_restarting_before_switch(data_t(), String.t()) :: data_t()
  def maybe_mark_restarting_before_switch(data, reason)
      when reason in [
             "source_loss",
             "zero_bitrate",
             "reconnecting",
             "failed",
             "manual",
             "primary_recovered"
           ] do
    mark_restarting_runtime(data)
  end

  def maybe_mark_restarting_before_switch(data, _reason), do: data

  @spec backup_mode(json_map()) :: String.t() | term()
  def backup_mode(route), do: backup_value(route, "backup_mode", "passive")

  @spec backup_switch_after_ms(json_map()) :: integer()
  def backup_switch_after_ms(route),
    do: backup_value(route, "backup_switch_after_ms", 3000)

  @spec backup_cooldown_ms(json_map()) :: integer()
  def backup_cooldown_ms(route),
    do: backup_value(route, "backup_cooldown_ms", 10_000)

  @spec backup_primary_stable_ms(json_map()) :: integer()
  def backup_primary_stable_ms(route),
    do: backup_value(route, "backup_primary_stable_ms", 15_000)

  @spec backup_probe_interval_ms(json_map()) :: integer()
  def backup_probe_interval_ms(route),
    do: backup_value(route, "backup_probe_interval_ms", 5000)

  @spec backup_value(json_map(), String.t(), term()) :: term()
  def backup_value(route, flat_key, default) when is_map(route) do
    Map.get(route, flat_key) || default
  end

  @doc false
  @spec parse_native_json_line(String.t()) :: native_json_parse_result()
  def parse_native_json_line(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"event" => "pipeline_status", "status" => status} = payload}
      when is_binary(status) ->
        {:pipeline_status, status, Map.get(payload, "reason")}

      {:ok, %{"event" => "srt_access"} = payload} ->
        {:srt_access, payload}

      {:ok, %{"event" => "pipeline_log"} = payload} ->
        {:pipeline_log, payload}

      {:ok, %{"event" => "endpoint_health"} = payload} ->
        {:endpoint_health, payload}

      {:ok, %{"event" => "media_info"} = payload} ->
        {:media_info, payload}

      {:ok, %{"event" => "route_terminal"} = payload} ->
        {:route_terminal, payload}

      {:ok, %{"event" => _event}} ->
        :unknown

      {:ok, %{} = stats} ->
        {:stats, stats}

      _ ->
        :unknown
    end
  end

  @spec matching_process_event?(data_t(), json_map()) :: boolean()
  def matching_process_event?(data, payload) when is_map(data) and is_map(payload) do
    process_instance_id = data[:process_instance_id]

    is_binary(process_instance_id) and
      payload["route_id"] == data.id and
      payload["process_instance_id"] == process_instance_id
  end

  @spec apply_endpoint_health_event(data_t(), endpoint_health_payload()) :: data_t()
  def apply_endpoint_health_event(data, payload) when is_map(data) and is_map(payload) do
    if matching_process_event?(data, payload) do
      endpoint_id = payload["endpoint_id"]

      next_health =
        (data[:endpoint_health] || %{})
        |> Map.put(endpoint_id, payload)

      publish_endpoint_health(data.id, payload)

      data = %{data | endpoint_health: next_health}

      if endpoint_id == data.active_source_id and payload["direction"] == "source" and
           payload["state"] == "streaming" do
        Map.put(data, :source_data_seen?, true)
      else
        data
      end
    else
      Logger.debug(
        "RouteHandler: dropping stale/unknown endpoint_health route_id=#{inspect(payload["route_id"])} process_instance_id=#{inspect(payload["process_instance_id"])}"
      )

      data
    end
  end

  @spec apply_media_info_event(data_t(), json_map()) :: data_t()
  def apply_media_info_event(data, payload) when is_map(data) and is_map(payload) do
    if matching_process_event?(data, payload) and youtube_media_info_event?(data, payload) do
      endpoint_id = payload["endpoint_id"]
      media_info = payload["media_info"]
      observed_at = observed_datetime(payload["observed_at_ms"])

      merged_media_info =
        persist_youtube_media_info(
          data.id,
          endpoint_id,
          payload["live"],
          media_info,
          observed_at,
          :observed
        )

      media_info =
        case merged_media_info do
          {:ok, value} -> value
          :not_found -> media_info
        end

      enriched_payload =
        payload
        |> Map.put("youtube_media_info", media_info)
        |> Map.put("youtube_info_updated_at", observed_at)

      publish_endpoint_health(data.id, enriched_payload)

      next_health =
        (data[:endpoint_health] || %{})
        |> Map.put(endpoint_id, enriched_payload)

      route = put_source_live_mode(data.route, endpoint_id, payload["live"])

      %{data | endpoint_health: next_health, route: route}
    else
      Logger.debug(
        "RouteHandler: dropping stale/unknown media_info route_id=#{inspect(payload["route_id"])} process_instance_id=#{inspect(payload["process_instance_id"])}"
      )

      data
    end
  end

  @spec youtube_media_info_event?(data_t(), json_map()) :: boolean()
  def youtube_media_info_event?(data, payload) when is_map(data) and is_map(payload) do
    endpoint_id = payload["endpoint_id"]
    media_info = payload["media_info"]

    endpoint_id == data.active_source_id and
      youtube_source?(data.route, endpoint_id) and
      payload["transport"] == "hls" and
      is_binary(endpoint_id) and is_map(media_info) and is_boolean(payload["live"])
  end

  @spec observed_datetime(term()) :: DateTime.t()
  def observed_datetime(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      {:error, _reason} -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  def observed_datetime(_value), do: DateTime.utc_now() |> DateTime.truncate(:second)

  @spec persist_youtube_media_info(String.t(), String.t(), boolean(), map(), DateTime.t()) :: :ok
  def persist_youtube_media_info(route_id, endpoint_id, live, media_info, observed_at)
      when is_binary(route_id) and is_binary(endpoint_id) and is_boolean(live) and
             is_map(media_info) and is_struct(observed_at, DateTime) do
    _ =
      persist_youtube_media_info(
        route_id,
        endpoint_id,
        live,
        media_info,
        observed_at,
        :announced
      )

    :ok
  end

  @spec persist_youtube_media_info(
          String.t(),
          String.t(),
          boolean(),
          map(),
          DateTime.t(),
          :announced | :observed
        ) :: {:ok, json_map()} | :not_found
  def persist_youtube_media_info(route_id, endpoint_id, live, media_info, observed_at, producer)
      when is_binary(route_id) and is_binary(endpoint_id) and is_boolean(live) and
             is_map(media_info) and is_struct(observed_at, DateTime) and
             producer in [:announced, :observed] do
    query =
      from(e in Endpoint,
        where: e.route_id == ^route_id and e.id == ^endpoint_id and e.schema == "YOUTUBE"
      )

    case HydraSrt.Repo.one(query) do
      nil ->
        :not_found

      endpoint ->
        current_media_info = endpoint.youtube_media_info || %{}
        merged_media_info = merge_youtube_media_info(current_media_info, media_info, producer)

        HydraSrt.Repo.update_all(
          query,
          set: [
            youtube_live_mode: live,
            youtube_media_info: merged_media_info,
            youtube_info_updated_at: observed_at,
            updated_at: DateTime.utc_now(:microsecond)
          ]
        )

        {:ok, merged_media_info}
    end
  end

  @spec merge_youtube_media_info(json_map(), json_map(), :announced | :observed) :: json_map()
  def merge_youtube_media_info(existing, incoming, :announced)
      when is_map(existing) and is_map(incoming) do
    merged = Map.merge(existing, Map.drop(incoming, ["video", "audio"]))

    Enum.reduce(["video", "audio"], merged, fn lane, acc ->
      case incoming[lane] do
        value when is_map(value) and map_size(value) > 0 -> Map.put(acc, lane, value)
        _ -> acc
      end
    end)
  end

  def merge_youtube_media_info(existing, incoming, :observed)
      when is_map(existing) and is_map(incoming) do
    Enum.reduce(["video", "audio"], existing, fn lane, acc ->
      case incoming[lane] do
        value when is_map(value) ->
          existing_lane = existing[lane]

          value =
            if is_map(existing_lane) and is_number(existing_lane["declared_bitrate_kbps"]) do
              Map.put(value, "declared_bitrate_kbps", existing_lane["declared_bitrate_kbps"])
            else
              value
            end

          Map.put(acc, lane, value)

        _ ->
          acc
      end
    end)
  end

  def merge_youtube_media_info(_existing, incoming, _producer) when is_map(incoming),
    do: incoming

  def merge_youtube_media_info(_existing, _incoming, _producer), do: %{}

  @spec put_source_live_mode(json_map(), String.t(), boolean()) :: json_map()
  def put_source_live_mode(route, endpoint_id, live)
      when is_map(route) and is_binary(endpoint_id) and is_boolean(live) do
    sources =
      Enum.map(route["sources"] || [], fn
        %{"id" => ^endpoint_id} = source -> Map.put(source, "youtube_live_mode", live)
        source -> source
      end)

    Map.put(route, "sources", sources)
  end

  @spec apply_route_terminal_event(data_t(), route_terminal_payload()) :: data_t()
  def apply_route_terminal_event(data, payload) when is_map(data) and is_map(payload) do
    if matching_process_event?(data, payload) do
      terminal = %{
        reason_code: payload["reason_code"],
        retryable: payload["retryable"],
        retry_domain: payload["retry_domain"],
        detail: payload["detail"],
        observed_at_ms: payload["observed_at_ms"],
        sequence: payload["sequence"]
      }

      Logger.info(
        "RouteHandler: route_terminal reason_code=#{inspect(terminal.reason_code)} retryable=#{inspect(terminal.retryable)} retry_domain=#{inspect(terminal.retry_domain)}"
      )

      data =
        data
        |> Map.put(:route_terminal, terminal)
        |> clear_source_loss_window()

      consume_route_terminal(data, terminal)
    else
      Logger.debug(
        "RouteHandler: dropping stale/unknown route_terminal route_id=#{inspect(payload["route_id"])} process_instance_id=#{inspect(payload["process_instance_id"])}"
      )

      data
    end
  end

  @spec consume_route_terminal(data_t(), route_terminal_t()) :: data_t()
  def consume_route_terminal(data, terminal) when is_map(data) and is_map(terminal) do
    cond do
      completed_terminal?(terminal, data.route) ->
        mark_terminal_completed(data, terminal)

      terminal.retryable == false ->
        mark_terminal_failure(data, terminal.reason_code || "ROUTE_TERMINAL", terminal.detail)

      terminal.retryable == true ->
        drive_retryable_terminal_recovery(data, terminal)

      true ->
        # Unclassified retryable → fail closed (no auto-retry storm).
        mark_terminal_failure(
          data,
          terminal.reason_code || "ROUTE_TERMINAL_UNCLASSIFIED",
          terminal.detail
        )
    end
  end

  @spec completed_terminal?(route_terminal_t() | nil, json_map()) :: boolean()
  def completed_terminal?(terminal, route) when is_map(route) do
    source = optional_source_record(route, route["active_source_id"])
    reason_code = terminal_reason_code(terminal)

    match?({:ok, %{"schema" => "YOUTUBE", "youtube_live_mode" => false}}, source) and
      (terminal[:retryable] == false or reason_code in ["SOURCE_COMPLETED", "HLS_COMPLETED"])
  end

  def completed_terminal?(_terminal, _route), do: false

  @spec mark_terminal_completed(data_t(), route_terminal_t()) :: data_t()
  def mark_terminal_completed(data, terminal) when is_map(data) and is_map(terminal) do
    Logger.info(
      "RouteHandler: source completed route_id=#{data.id} reason=#{inspect(terminal.reason_code)}"
    )

    _ = HydraSrt.mark_route_completed(data.id)

    %{
      data
      | route_terminal: terminal,
        retry_scheduled?: false,
        recovering?: false,
        recovery_blocked?: false,
        source_loss_since_ms: nil,
        source_loss_signal: nil
    }
  end

  @spec drive_retryable_terminal_recovery(data_t(), route_terminal_t()) :: data_t()
  def drive_retryable_terminal_recovery(data, terminal)
      when is_map(data) and is_map(terminal) do
    domain = terminal.retry_domain

    Logger.info(
      "RouteHandler: retryable terminal recovery route_id=#{data.id} domain=#{inspect(domain)} reason_code=#{inspect(terminal.reason_code)}"
    )

    case domain do
      "source" ->
        case next_source_for_failover(data) do
          %{"id" => id} when is_binary(id) and id != data.active_source_id ->
            case failover_to_source(data, id, "source_loss") do
              {:ok, next_data} ->
                next_data

              {:error, _reason, next_data} ->
                next_data

              {:error, _} ->
                data
                |> mark_restarting_runtime()
                |> schedule_retry_restart()
            end

          _ ->
            data
            |> mark_restarting_runtime()
            |> schedule_retry_restart()
        end

      _ ->
        # "route", "none" with retryable true, or unknown → sole hard-retry owner (A).
        data
        |> mark_restarting_runtime()
        |> schedule_retry_restart()
    end
  end

  @spec publish_endpoint_health(String.t(), endpoint_health_payload()) :: :ok
  def publish_endpoint_health(route_id, payload) when is_binary(route_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      HydraSrt.PubSub,
      "item:" <> route_id,
      {:endpoint_health, payload}
    )

    :ok
  end

  @doc false
  def normalize_runtime_status(status, reason), do: normalize_runtime_status(status, reason, %{})
  def normalize_runtime_status("stopped", "failure", _data), do: :ignore
  def normalize_runtime_status("starting", _reason, _data), do: :ignore

  def normalize_runtime_status("reconnecting", _reason, data) when is_map(data) do
    if listener_source_waiting?(data) do
      :ignore
    else
      {:update, "reconnecting"}
    end
  end

  # A hard retry already in flight has already written the truthful
  # "restarting"/"reconnecting" status for this cycle (`mark_restarting_runtime/1`
  # or `note_prolonged_retry/3`, both called before this line runs). The
  # native pipeline's own legacy `pipeline_status "failed"` line - emitted on
  # every dying attempt regardless of whether Elixir has already decided to
  # keep retrying - must not clobber that with a status the operator would
  # read as permanently dead. Without this, a route mid hard-retry visibly
  # flip-flopped restarting -> failed -> restarting on every single cycle and
  # wrote an extra route_status_change row each time. `retry_scheduled?`
  # unset/false (no retry in flight - a genuinely terminal or unclassified
  # failure) still writes the truthful "failed".
  def normalize_runtime_status("failed", _reason, data) when is_map(data) do
    if Map.get(data, :retry_scheduled?, false) do
      :ignore
    else
      {:update, "failed"}
    end
  end

  def normalize_runtime_status(status, _reason, _data) when is_binary(status),
    do: {:update, status}

  @doc false
  def publish_stats(route_id, %{} = stats, metadata \\ %{}) when is_binary(route_id) do
    stats
    |> stats_events(route_id)
    |> Enum.each(fn event ->
      Phoenix.PubSub.broadcast(HydraSrt.PubSub, "stats", {:stats, event})
    end)

    HydraSrt.Stats.Collector.ingest(route_id, stats, metadata)

    :ok
  end

  @doc false
  def publish_srt_access_log(route_id, %{} = access_event) when is_binary(route_id) do
    allowed? = access_event["allowed"] == true
    reason = access_event["reason"] || "unknown"
    ip = access_event["ip"] || "unknown"
    stream_id = access_event["stream_id"]

    log = %{
      route_id: route_id,
      gst_ts: nil,
      pid: nil,
      thread_id: nil,
      level: if(allowed?, do: "INFO", else: "WARN"),
      category: "srt_access",
      file: nil,
      line: nil,
      function: nil,
      element: "srtsrc",
      message: srt_access_message(ip, allowed?, reason, stream_id),
      dropped_count: nil
    }

    Phoenix.PubSub.broadcast(
      HydraSrt.PubSub,
      "pipeline_logs",
      {:pipeline_log, log}
    )
  end

  # `level`/`category`/`message` are always sent by the native emitter for a
  # real pipeline_log event; a payload missing one is malformed, not a payload
  # that merely omitted an optional field, so it is rejected loudly instead of
  # being patched up with an invented level or message. `element` genuinely is
  # optional on the wire and stays nil when absent. `sequence`/`observed_at_ms`
  # are carried through so the stored row can be dated by when the native side
  # actually observed the event, not by when this process happens to flush.
  @doc false
  @spec publish_native_pipeline_log(data_t(), json_map()) :: :ok
  def publish_native_pipeline_log(data, %{} = payload) when is_map(data) do
    cond do
      not matching_process_event?(data, payload) ->
        Logger.debug(
          "RouteHandler: dropping stale/unknown pipeline_log route_id=#{inspect(payload["route_id"])} process_instance_id=#{inspect(payload["process_instance_id"])}"
        )

        :ok

      not valid_pipeline_log_payload?(payload) ->
        Logger.error(
          "RouteHandler: malformed native pipeline_log payload route_id=#{data.id} payload=#{inspect(payload)}"
        )

        :ok

      true ->
        log = %{
          route_id: data.id,
          gst_ts: nil,
          pid: nil,
          thread_id: nil,
          level: payload["level"],
          category: payload["category"],
          file: payload["file"],
          line: payload["line"],
          function: payload["function"],
          element: payload["element"],
          message: payload["message"],
          sequence: payload["sequence"],
          observed_at_ms: payload["observed_at_ms"],
          dropped_count: nil
        }

        Phoenix.PubSub.broadcast(HydraSrt.PubSub, "pipeline_logs", {:pipeline_log, log})
        :ok
    end
  end

  @spec valid_pipeline_log_payload?(json_map()) :: boolean()
  defp valid_pipeline_log_payload?(payload) do
    non_empty_binary?(payload["level"]) and non_empty_binary?(payload["category"]) and
      non_empty_binary?(payload["message"])
  end

  @spec non_empty_binary?(term()) :: boolean()
  defp non_empty_binary?(value), do: is_binary(value) and value != ""

  @doc false
  def srt_access_message(ip, allowed?, reason, nil) do
    "SRT caller ip=#{ip} allowed=#{allowed?} reason=#{reason}"
  end

  def srt_access_message(ip, allowed?, reason, stream_id) do
    "SRT caller ip=#{ip} stream_id=#{stream_id} allowed=#{allowed?} reason=#{reason}"
  end

  @doc false
  def stats_events(%{} = stats, route_id) when is_binary(route_id) do
    snapshot_events = [
      %{
        route_id: route_id,
        metric: "snapshot",
        stats: stats
      }
    ]

    in_events =
      case get_in(stats, ["source", "bytes_in_per_sec"]) do
        value when is_number(value) ->
          [
            %{
              route_id: route_id,
              direction: "in",
              metric: "bytes_per_sec",
              value: value
            }
          ]

        _ ->
          []
      end

    out_events =
      stats
      |> Map.get("destinations", [])
      |> Enum.flat_map(fn
        %{"id" => destination_id, "bytes_out_per_sec" => value}
        when is_binary(destination_id) and is_number(value) ->
          [
            %{
              route_id: route_id,
              destination_id: destination_id,
              direction: "out",
              metric: "bytes_per_sec",
              value: value
            }
          ]

        _ ->
          []
      end)

    snapshot_events ++ in_events ++ out_events
  end

  defp active_source_position(route, active_source_id)
       when is_map(route) and is_binary(active_source_id) do
    sources = Map.get(route, "sources", [])

    case Enum.find(sources, &(&1["id"] == active_source_id)) do
      %{"position" => position} when is_integer(position) -> position
      _ -> nil
    end
  end

  defp active_source_position(_route, _active_source_id), do: nil

  defp mark_route_terminated(route_id, {:port_exit, status}) when status not in [0, :normal] do
    HydraSrt.mark_route_terminated(route_id)
  end

  defp mark_route_terminated(route_id, reason)
       when reason in [
              :normal,
              :shutdown,
              {:port_exit, 0},
              {:port_exit, :normal}
            ] do
    HydraSrt.mark_route_stopped(route_id)
  end

  defp mark_route_terminated(route_id, {:startup_failed, _reason}) do
    HydraSrt.mark_route_failed(route_id)
  end

  defp mark_route_terminated(route_id, {:shutdown, _reason}) do
    HydraSrt.mark_route_stopped(route_id)
  end

  defp mark_route_terminated(route_id, _reason) do
    HydraSrt.mark_route_terminated(route_id)
  end

  defp kill_stale_pipeline_processes(route_id, context) do
    case HydraSrt.ProcessMonitor.kill_pipeline_processes_for_route(route_id) do
      {:ok, _results} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "RouteHandler: failed to kill stale pipeline processes route_id=#{route_id} context=#{context} reason=#{inspect(reason)}"
        )
    end
  end

  @spec route_data_to_params(String.t()) :: {:ok, native_config()} | {:error, term()}
  def route_data_to_params(route_id), do: route_data_to_params(route_id, nil)

  @spec route_data_to_params(String.t(), String.t() | nil) ::
          {:ok, native_config()} | {:error, term()}
  def route_data_to_params(route_id, source_id) do
    with {:ok, route} <- Db.get_route(route_id, true),
         {:ok, source_record} <- source_record_from_route(route, source_id),
         :ok <- ensure_ndi_start_allowed(route, source_record),
         {:ok, source} <- source_from_record(source_record, route),
         {:ok, sinks} <- sinks_from_record(route) do
      notify_youtube_quality_fallback(route_id, source_record, source)
      {:ok, build_config(route_id, source_record, source, sinks)}
    end
  end

  @spec ensure_ndi_start_allowed(json_map(), json_map()) :: :ok | {:error, String.t()}
  def ensure_ndi_start_allowed(route, source_record)
      when is_map(route) and is_map(source_record) do
    actions = ndi_policy_actions(route, source_record)

    Enum.reduce_while(actions, :ok, fn action, :ok ->
      case policy_deny_reason(action) do
        nil -> {:cont, :ok}
        reason -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec ndi_policy_actions(json_map(), json_map()) :: [:receive | :send | :youtube]
  def ndi_policy_actions(route, source_record) when is_map(route) and is_map(source_record) do
    actions =
      case source_record["schema"] do
        "NDI" -> [:receive]
        "YOUTUBE" -> [:youtube]
        _ -> []
      end

    destinations = Map.get(route, "destinations", [])

    if Enum.any?(destinations, &ndi_enabled_destination?/1) do
      actions ++ [:send]
    else
      actions
    end
  end

  @spec policy_deny_reason(:receive | :send | :youtube) :: String.t() | nil
  def policy_deny_reason(:youtube), do: YoutubeFeaturePolicy.deny_reason(:enabled)
  def policy_deny_reason(action), do: FeaturePolicy.deny_reason(action)

  @spec ndi_enabled_destination?(json_map() | term()) :: boolean()
  def ndi_enabled_destination?(destination) when is_map(destination) do
    destination_enabled?(destination) and destination["schema"] == "NDI"
  end

  def ndi_enabled_destination?(_), do: false

  @spec build_config(String.t(), json_map(), typed_endpoint(), [typed_endpoint()]) ::
          native_config()
  def build_config(route_id, source_record, source, sinks) do
    kind = source["kind"]

    %{
      "route_id" => route_id,
      "config_revision" => "boot-" <> Ecto.UUID.generate(),
      "process_instance_id" => Ecto.UUID.generate(),
      "source" => %{
        "id" => source_record["id"],
        "name" => endpoint_display_name(source_record),
        "kind" => kind,
        kind => source[kind]
      },
      "destinations" => Enum.map(sinks, &typed_destination_endpoint/1)
    }
  end

  @spec typed_destination_endpoint(typed_endpoint()) :: typed_endpoint()
  def typed_destination_endpoint(sink) when is_map(sink) do
    kind = sink["kind"]

    %{
      "id" => sink["id"],
      "name" => sink["name"],
      "kind" => kind,
      kind => sink[kind]
    }
  end

  @spec endpoint_display_name(json_map()) :: String.t()
  def endpoint_display_name(record) when is_map(record) do
    # A stored record carries an explicit `nil` name, so `Map.get/3` defaults are
    # not enough: the wire contract needs a string here, never `null`.
    case Map.get(record, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> endpoint_display_id(record)
    end
  end

  @spec endpoint_display_id(json_map()) :: String.t()
  defp endpoint_display_id(record) do
    case Map.get(record, "id") do
      id when is_binary(id) -> id
      _ -> ""
    end
  end

  @doc false
  @spec source_record_from_route(json_map(), String.t() | nil) ::
          {:ok, json_map()} | {:error, term()}
  def source_record_from_route(%{"sources" => sources}, source_id)
      when is_list(sources) and is_binary(source_id) do
    case Enum.find(sources, &(&1["id"] == source_id)) do
      nil -> {:error, :invalid_source}
      source -> {:ok, source}
    end
  end

  def source_record_from_route(%{"sources" => sources} = route, _source_id)
      when is_list(sources) do
    active_source_id = route["active_source_id"]

    source =
      Enum.find(sources, &(&1["id"] == active_source_id)) ||
        Enum.find(sources, &(&1["position"] == 0))

    case source do
      nil -> {:error, :invalid_source}
      source -> {:ok, source}
    end
  end

  def source_record_from_route(route, _source_id) when is_map(route) do
    raise ArgumentError,
          "route payload without \"sources\" is not supported after sources migration: #{inspect(route)}"
  end

  @spec sinks_from_record(json_map()) ::
          {:ok, [typed_endpoint()]} | {:error, {:invalid_destinations, [term()]} | term()}
  def sinks_from_record(%{"destinations" => destinations})
      when is_list(destinations) and destinations != [] do
    enabled = Enum.filter(destinations, &destination_enabled?/1)

    {sinks, failing_ids} =
      Enum.reduce(enabled, {[], []}, fn destination, {ok_acc, err_acc} ->
        case sink_from_record(destination) do
          {:ok, sink} ->
            {[sink | ok_acc], err_acc}

          {:error, error} ->
            failing_id = destination["id"] || destination[:id] || "unknown"

            Logger.error(
              "RouteHandler: sink_from_record error: #{inspect(error)}, destination_id=#{inspect(failing_id)}"
            )

            {ok_acc, [failing_id | err_acc]}
        end
      end)

    case Enum.reverse(failing_ids) do
      [] ->
        {:ok, Enum.reverse(sinks)}

      ids ->
        {:error, {:invalid_destinations, ids}}
    end
  end

  def sinks_from_record(_) do
    Logger.debug("RouteHandler: sinks_from_record: no destinations")
    {:ok, []}
  end

  @spec destination_enabled?(json_map() | term()) :: boolean()
  def destination_enabled?(destination) when is_map(destination) do
    destination["enabled"] == true or destination[:enabled] == true
  end

  def destination_enabled?(_), do: false

  @doc false
  @spec build_srt_uri(json_map()) :: String.t()
  def build_srt_uri(opts) when is_map(opts) do
    mode = Map.get(opts, "mode")

    localaddress =
      Map.get(
        opts,
        "localaddress",
        Application.get_env(:hydra_srt, :default_bind_ip, "127.0.0.1")
      )

    remote_address = srt_remote_address(opts)
    localport = Map.get(opts, "localport")
    remote_port = srt_remote_port(opts)

    query_params =
      %{}
      |> maybe_add_param(opts, "mode")
      |> maybe_add_param(opts, "passphrase")
      |> maybe_add_param(opts, "pbkeylen")
      |> maybe_add_param(opts, "poll-timeout")

    query_params =
      if mode in ["caller", "rendezvous"] do
        maybe_add_param(query_params, opts, "streamid")
      else
        query_params
      end

    {host, port} =
      case mode do
        "caller" ->
          {remote_address || localaddress, remote_port || localport}

        "rendezvous" ->
          {remote_address || localaddress, remote_port || localport}

        _ ->
          {localaddress || remote_address, localport || remote_port}
      end

    URI.to_string(%URI{
      scheme: "srt",
      host: host,
      port: port,
      query: encode_srt_query(query_params)
    })
  end

  @doc false
  @spec build_srt_uri(term()) :: nil
  def build_srt_uri(_), do: nil

  # RFC 3986 percent-encoding, not `application/x-www-form-urlencoded`.
  # `URI.encode_query/1` would emit `+` for a space; GStreamer's `srtsrc`/`srtsink`
  # only percent-decode the query, so a `+` reaches SRT verbatim and corrupts any
  # `passphrase` or `streamid` that contains a space.
  @spec encode_srt_query(json_map()) :: String.t()
  defp encode_srt_query(params) when is_map(params) do
    Enum.map_join(params, "&", fn {key, value} ->
      "#{percent_encode(key)}=#{percent_encode(value)}"
    end)
  end

  defp percent_encode(value) do
    value
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  @doc false
  @spec srt_remote_address(json_map()) :: String.t() | nil
  def srt_remote_address(opts) when is_map(opts) do
    Map.get(opts, "address") || Map.get(opts, "host")
  end

  @doc false
  @spec srt_remote_port(json_map()) :: integer() | nil
  def srt_remote_port(opts) when is_map(opts), do: Map.get(opts, "port")

  @doc """
  Local bind (`localaddress`, `localport`) the SRT element should use.

  In caller/rendezvous mode `build_srt_uri/1` falls back to `localaddress` /
  `localport` for the peer, so those only describe a local bind when an explicit
  peer address/port is configured; otherwise the element would try to bind the
  port it is supposed to dial.
  """
  @spec srt_local_bind(json_map()) :: {String.t() | nil, integer() | nil}
  def srt_local_bind(opts) when is_map(opts) do
    bind_address = Map.get(opts, "bind-address")
    localaddress = Map.get(opts, "localaddress")
    localport = Map.get(opts, "localport")

    if Map.get(opts, "mode") in ["caller", "rendezvous"] do
      {bind_address || peer_scoped(srt_remote_address(opts), localaddress),
       peer_scoped(srt_remote_port(opts), localport)}
    else
      {localaddress || bind_address, localport}
    end
  end

  defp peer_scoped(nil, _local), do: nil
  defp peer_scoped(_peer, local), do: local

  @doc false
  @spec maybe_add_param(json_map(), json_map(), String.t()) :: json_map()
  def maybe_add_param(params, opts, key) when is_map(params) and is_map(opts) do
    case Map.get(opts, key) do
      nil -> params
      "" -> params
      value -> Map.put(params, key, value)
    end
  end

  @spec sink_from_record(json_map()) :: {:ok, typed_endpoint()} | {:error, term()}
  def sink_from_record(%{"id" => id, "schema" => "SRT"} = destination) do
    opts = endpoint_options_from_record(destination)

    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      name = endpoint_display_name(destination)
      uri = build_srt_uri(resolved_opts)

      {:ok,
       %{
         "id" => id,
         "name" => name,
         "kind" => "srt",
         "srt" => srt_destination_payload(resolved_opts, uri)
       }}
    end
  end

  def sink_from_record(%{"id" => id, "schema" => "UDP"} = destination) do
    opts = endpoint_options_from_record(destination)

    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      name = endpoint_display_name(destination)

      # Native pipeline expects `address` and `port` (it maps `address` -> udpsink host property).
      address = Map.get(resolved_opts, "address") || Map.get(resolved_opts, "host")
      port = Map.get(resolved_opts, "port")

      bind_address =
        Map.get(resolved_opts, "bind-address") || Map.get(resolved_opts, "localaddress")

      bind_address =
        if ipv6_address?(address) and link_local_ipv6?(bind_address) do
          nil
        else
          bind_address
        end

      multicast_iface =
        Map.get(resolved_opts, "multicast-iface") ||
          Map.get(resolved_opts, "interface_sys_name")

      {:ok,
       %{
         "id" => id,
         "name" => name,
         "kind" => "udp",
         "udp" =>
           %{
             "address" => address,
             "port" => port,
             "bind_address" => bind_address,
             "multicast_iface" => multicast_iface
           }
           |> drop_nil_values()
       }}
    end
  end

  def sink_from_record(%{"schema" => "RTMP"} = destination) do
    opts = endpoint_options_from_record(destination)

    with false <- map_size(opts) == 0,
         {:ok, resolved_opts} <- resolve_interface_options(opts) do
      id = Map.get(destination, "id")
      name = endpoint_display_name(destination)
      location = Map.get(resolved_opts, "location")

      if is_nil(location) or location == "" do
        {:error, :invalid_destination}
      else
        {:ok,
         %{
           "id" => id,
           "name" => name,
           "kind" => "rtmp",
           "rtmp" => %{"location" => location}
         }}
      end
    else
      true -> {:error, :invalid_destination}
      {:error, _} = error -> error
    end
  end

  def sink_from_record(%{"id" => id, "schema" => "NDI"} = destination) do
    case ndi_destination_payload(destination) do
      {:ok, ndi} ->
        name = endpoint_display_name(destination)

        {:ok,
         %{
           "id" => id,
           "name" => name,
           "kind" => "ndi",
           "ndi" => ndi
         }}

      {:error, _} = error ->
        error
    end
  end

  def sink_from_record(_), do: {:error, :invalid_destination}

  @spec source_from_record(json_map()) :: {:ok, typed_endpoint()} | {:error, term()}
  def source_from_record(record) when is_map(record), do: source_from_record(record, %{})

  @spec source_from_record(json_map(), json_map()) :: {:ok, typed_endpoint()} | {:error, term()}
  def source_from_record(%{"schema" => "SRT"} = source, _route) do
    opts = endpoint_options_from_record(source)

    with false <- map_size(opts) == 0,
         {:ok, resolved_opts} <- resolve_interface_options(opts) do
      uri = build_srt_uri(resolved_opts)

      {:ok, %{"kind" => "srt", "srt" => srt_source_payload(resolved_opts, uri)}}
    else
      true -> {:error, :invalid_source}
    end
  end

  def source_from_record(%{"schema" => "UDP"} = source, _route) do
    opts = endpoint_options_from_record(source)

    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      {:ok, %{"kind" => "udp", "udp" => udp_source_config(resolved_opts)}}
    end
  end

  def source_from_record(%{"schema" => "RTP"} = source, _route) do
    opts = endpoint_options_from_record(source)

    with {:ok, resolved_opts} <- resolve_interface_options(opts) do
      # TS over RTP source uses udpsrc + rtpmp2tdepay in native pipeline.
      {:ok, %{"kind" => "rtp", "rtp" => udp_source_config(resolved_opts)}}
    end
  end

  def source_from_record(%{"schema" => "RTMP"} = source, _route) do
    opts = endpoint_options_from_record(source)

    case HydraSrt.Api.Endpoint.normalize_rtmp_path(Map.get(opts, "path")) do
      path when is_binary(path) and path != "" ->
        {:ok,
         %{
           "kind" => "rtmp",
           "rtmp" => %{"location" => build_rtmp_proxy_uri(path)}
         }}

      _ ->
        {:error, :invalid_source}
    end
  end

  def source_from_record(%{"schema" => "NDI"} = source, route) when is_map(route) do
    case ndi_source_payload(source, route) do
      {:ok, ndi} ->
        {:ok, %{"kind" => "ndi", "ndi" => ndi}}

      {:error, _} = error ->
        error
    end
  end

  def source_from_record(%{"schema" => "YOUTUBE"} = source, _route) do
    url = source["youtube_url"]
    opts = youtube_resolution_options(source)

    with true <- is_binary(url) and url != "",
         {:ok, media} <- youtube_cached_resolve(url, opts),
         {:ok, hls} <- youtube_hls_payload(media, source) do
      {:ok, %{"kind" => "hls", "hls" => hls}}
    else
      false -> {:error, :invalid_source}
      :miss -> {:error, :resolver_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  def source_from_record(_, _), do: {:error, :invalid_source}

  @spec youtube_hls_payload(map(), json_map()) :: {:ok, json_map()} | {:error, term()}
  def youtube_hls_payload(media, source) when is_map(media) and is_map(source) do
    uri = resolved_media_value(media, :uri)
    live = resolved_media_value(media, :live)
    end_action = source["youtube_end_action"] || "stop"
    media_info = resolved_media_value(media, :media_info) || %{}
    target_duration_ms = media_info["target_duration_ms"] || media_info[:target_duration_ms]

    cond do
      not (is_binary(uri) and uri != "") ->
        {:error, :invalid_output}

      not is_boolean(live) ->
        {:error, :invalid_output}

      end_action not in ["stop", "hold", "loop"] ->
        {:error, :invalid_source}

      true ->
        {:ok,
         %{
           "uri" => uri,
           "live" => live,
           "target_duration_ms" => target_duration_ms,
           "end_action" => end_action
         }
         |> drop_nil_values()}
    end
  end

  @spec resolved_media_value(map(), atom()) :: term()
  def resolved_media_value(media, key) when is_map(media) and is_atom(key) do
    Map.get(media, key, Map.get(media, Atom.to_string(key)))
  end

  @spec youtube_uri_expires_at(String.t()) :: integer() | nil
  def youtube_uri_expires_at(uri) when is_binary(uri) do
    YoutubeCache.expires_at(uri) ||
      case Regex.run(~r{(?:^|/)expire/(\d+)(?:/|$)}, uri, capture: :all_but_first) do
        [value] ->
          case Integer.parse(value) do
            {expires_at, ""} -> expires_at
            _ -> nil
          end

        _ ->
          nil
      end
  end

  def youtube_uri_expires_at(_uri), do: nil

  @spec add_refresh_times(map(), map(), DateTime.t()) :: map()
  def add_refresh_times(media_info, media, observed_at)
      when is_map(media_info) and is_map(media) and is_struct(observed_at, DateTime) do
    media_info =
      media_info
      |> Map.delete("next_refresh_at")
      |> Map.put("last_refresh_at", DateTime.to_iso8601(observed_at))

    case youtube_uri_expires_at(resolved_media_value(media, :uri)) do
      expires_at when is_integer(expires_at) ->
        case DateTime.from_unix(expires_at - @youtube_refresh_lead_seconds, :second) do
          {:ok, next_refresh_at} ->
            if DateTime.compare(next_refresh_at, observed_at) == :gt do
              Map.put(media_info, "next_refresh_at", DateTime.to_iso8601(next_refresh_at))
            else
              media_info
            end

          _ ->
            media_info
        end

      _ ->
        media_info
    end
  end

  @spec notify_youtube_quality_fallback(String.t(), json_map(), typed_endpoint()) :: :ok
  def notify_youtube_quality_fallback(route_id, source_record, source)
      when is_binary(route_id) and is_map(source_record) and is_map(source) do
    selected = source_record["youtube_format_id"]

    if source_record["schema"] == "YOUTUBE" and is_binary(selected) do
      opts = youtube_resolution_options(source_record) |> Keyword.put(:format_id, selected)

      case youtube_cached_resolve(source_record["youtube_url"], opts) do
        {:ok, %{format_id: resolved_format_id}} when is_binary(resolved_format_id) ->
          if resolved_format_id != selected do
            EventLogger.ingest(%{
              route_id: route_id,
              event_type: "youtube_quality_fallback",
              severity: "warning",
              source_id: source_record["id"],
              message: "YouTube quality selection fell back",
              details_json:
                Jason.encode!(%{
                  "selected_format_id" => selected,
                  "resolved_format_id" => resolved_format_id
                })
            })
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  @spec ndi_source_payload(json_map(), json_map()) :: {:ok, json_map()} | {:error, term()}
  def ndi_source_payload(source, route) when is_map(source) and is_map(route) do
    mode = source["ndi_selection_mode"]

    locator =
      case mode do
        "discovery_name" ->
          case source["ndi_source_name"] do
            name when is_binary(name) and name != "" ->
              {:ok, %{"source_name" => name}}

            _ ->
              {:error, :invalid_source}
          end

        "direct_address" ->
          case source["ndi_source_address"] do
            address when is_binary(address) and address != "" ->
              {:ok, %{"url_address" => address}}

            _ ->
              {:error, :invalid_source}
          end

        _ ->
          {:error, :invalid_source}
      end

    with {:ok, locator_fields} <- locator do
      ndi =
        locator_fields
        |> Map.merge(%{
          "receiver_name" => ndi_receiver_name(source, route),
          "bandwidth" => source["ndi_bandwidth"] || @ndi_default_bandwidth,
          "color_format" => source["ndi_color_format"] || @ndi_default_color_format,
          "timestamp_mode" => source["ndi_timestamp_mode"],
          "media_policy" => source["ndi_media_policy"] || @ndi_default_media_policy,
          "connect_timeout_ms" =>
            source["ndi_connect_timeout_ms"] || @ndi_default_connect_timeout_ms,
          "receive_timeout_ms" =>
            source["ndi_receive_timeout_ms"] || @ndi_default_receive_timeout_ms,
          "track_discovery_timeout_ms" =>
            source["ndi_track_discovery_timeout_ms"] ||
              @ndi_default_track_discovery_timeout_ms,
          "max_queue_length" => source["ndi_max_queue_length"] || @ndi_default_max_queue_length
        })
        |> drop_nil_values()

      {:ok, ndi}
    end
  end

  @spec ndi_destination_payload(json_map()) :: {:ok, json_map()} | {:error, term()}
  def ndi_destination_payload(destination) when is_map(destination) do
    case destination["ndi_sender_name"] do
      name when is_binary(name) and name != "" ->
        {:ok,
         %{
           "sender_name" => name,
           "media_policy" => destination["ndi_media_policy"] || @ndi_default_media_policy
         }}

      _ ->
        {:error, :invalid_destination}
    end
  end

  @spec ndi_receiver_name(json_map(), json_map()) :: String.t()
  def ndi_receiver_name(source, route) when is_map(source) and is_map(route) do
    case source["ndi_receiver_name"] do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        route_name =
          case route["name"] do
            name when is_binary(name) and name != "" -> name
            _ -> route["id"] || ""
          end

        "Hydra #{route_name}"
    end
  end

  @doc false
  @spec build_rtmp_proxy_uri(String.t()) :: String.t()
  def build_rtmp_proxy_uri(path) when is_binary(path) do
    normalized_path = HydraSrt.Api.Endpoint.normalize_rtmp_path(path)
    rtmp_port = Application.fetch_env!(:hydra_srt, :rtmp_port)
    "rtmp://127.0.0.1:#{rtmp_port}#{normalized_path}"
  end

  @doc false
  @spec udp_source_config(json_map()) :: json_map()
  def udp_source_config(opts) when is_map(opts) do
    address = Map.get(opts, "address") || Map.get(opts, "host") || Map.get(opts, "localaddress")
    port = Map.get(opts, "port") || Map.get(opts, "localport")
    multicast? = multicast_source?(opts, address)

    multicast_iface =
      Map.get(opts, "multicast-iface") ||
        Map.get(opts, "multicast_iface") ||
        Map.get(opts, "interface_sys_name")

    %{
      "address" => address,
      "port" => port,
      "program_number" => opts["program_number"],
      "auto_multicast" => if(multicast?, do: true, else: nil),
      "multicast_iface" => if(multicast?, do: multicast_iface, else: nil)
    }
    |> drop_nil_values()
  end

  @spec srt_source_payload(json_map(), String.t()) :: json_map()
  def srt_source_payload(opts, uri) when is_map(opts) and is_binary(uri) do
    srt_payload(opts, uri, _source? = true)
  end

  @spec srt_destination_payload(json_map(), String.t()) :: json_map()
  def srt_destination_payload(opts, uri) when is_map(opts) and is_binary(uri) do
    srt_payload(opts, uri, _source? = false)
  end

  @spec srt_payload(json_map(), String.t(), boolean()) :: json_map()
  def srt_payload(opts, uri, source?)
      when is_map(opts) and is_binary(uri) and is_boolean(source?) do
    mode = Map.get(opts, "mode")

    streamid =
      if mode in ["caller", "rendezvous"] do
        case Map.get(opts, "streamid") do
          value when is_binary(value) and value != "" -> value
          _ -> nil
        end
      else
        nil
      end

    access =
      if source? and Map.get(opts, "hydra_limit_access") == true do
        %{
          "limit" => true,
          "allowed" => Map.get(opts, "hydra_allowed_list", []),
          "denied" => Map.get(opts, "hydra_denied_list", [])
        }
      else
        nil
      end

    {localaddress, localport} = srt_local_bind(opts)

    # SRT carries the peer host/port in the URI and binds through
    # `localaddress`/`localport`; `srtsrc`/`srtsink` have no `address`, `port`,
    # `bind-address` or `multicast-iface` property, so those never go on the wire.
    %{
      "uri" => uri,
      "mode" => mode,
      "latency" => Map.get(opts, "latency"),
      "auto_reconnect" => Map.get(opts, "auto-reconnect"),
      "keep_listening" => Map.get(opts, "keep-listening"),
      "poll_timeout" => Map.get(opts, "poll-timeout"),
      "passphrase" => Map.get(opts, "passphrase"),
      "pbkeylen" => Map.get(opts, "pbkeylen"),
      "streamid" => streamid,
      "localaddress" => localaddress,
      "localport" => localport,
      "authentication" => Map.get(opts, "authentication"),
      "program_number" => if(source?, do: opts["program_number"], else: nil),
      "access" => access
    }
    |> drop_nil_values()
  end

  @doc false
  @spec maybe_put_multicast_options(json_map(), boolean() | term(), term()) :: json_map()
  def maybe_put_multicast_options(opts, true, multicast_iface) when is_map(opts) do
    opts
    |> Map.put("auto-multicast", true)
    |> Map.put("multicast-iface", multicast_iface)
  end

  def maybe_put_multicast_options(opts, _, _), do: opts

  @doc false
  @spec multicast_source?(json_map(), String.t() | term()) :: boolean()
  def multicast_source?(opts, address) when is_map(opts) do
    Map.get(opts, "multicast") == true or multicast_address?(address)
  end

  @doc false
  @spec multicast_address?(String.t() | term()) :: boolean()
  def multicast_address?(address) when is_binary(address) do
    cond do
      String.starts_with?(address, "ff") ->
        true

      true ->
        case :inet.parse_ipv4_address(String.to_charlist(address)) do
          {:ok, {first, _, _, _}} -> first >= 224 and first <= 239
          _ -> false
        end
    end
  end

  def multicast_address?(_), do: false

  @doc false
  @spec failover_target_source([json_map()], String.t() | nil, String.t()) :: json_map() | nil
  def failover_target_source(sources, active_source_id, mode)
      when is_list(sources) and mode in ["active", "passive", "disabled"] do
    case next_enabled_source(sources, active_source_id, mode) do
      %{"id" => id} when is_binary(id) and id == active_source_id -> nil
      %{"id" => _} = source -> source
      _ -> nil
    end
  end

  def failover_target_source(_sources, _active_source_id, _mode), do: nil

  @doc false
  @spec next_enabled_source([json_map()], String.t() | nil, String.t()) :: json_map() | nil
  def next_enabled_source(sources, current_id, mode)
      when is_list(sources) and mode in ["active", "passive", "disabled"] do
    if mode == "disabled" do
      nil
    else
      enabled_sources = Enum.filter(sources, &(Map.get(&1, "enabled") == true))

      case enabled_sources do
        [] ->
          nil

        _ ->
          current_index =
            Enum.find_index(enabled_sources, fn source -> Map.get(source, "id") == current_id end)

          case current_index do
            nil ->
              List.first(enabled_sources)

            index ->
              next_index = index + 1

              cond do
                next_index < length(enabled_sources) ->
                  Enum.at(enabled_sources, next_index)

                mode in ["active", "passive"] ->
                  List.first(enabled_sources)

                true ->
                  nil
              end
          end
      end
    end
  end

  @doc false
  @spec in_cooldown?(integer() | nil | term(), integer() | term()) :: boolean()
  def in_cooldown?(cooldown_until_ms, now_ms)
      when is_integer(cooldown_until_ms) and is_integer(now_ms),
      do: cooldown_until_ms > now_ms

  def in_cooldown?(_, _), do: false

  # Whether the debounced source-loss window is old enough to act on. "Act on"
  # does NOT mean "fail over" - `trigger_source_loss_failover/1` (the caller)
  # still separately asks `next_source_for_failover/1` for an actual target,
  # which is `nil` in "disabled" mode by construction
  # (`next_enabled_source/3`). backup_mode must never gate this debounce
  # itself: the visible "reconnecting" state a dead source produces
  # (`mark_source_loss_without_failover_target/2`) is not a failover feature,
  # it is the baseline truthful-status contract every route gets regardless
  # of whether backup switching is configured. Gating it on backup_mode used
  # to mean a "disabled"-mode route with a dead source reported "processing"
  # all night with zero events, for as long as the dead source stayed dead -
  # the exact silent-lie failure mode this whole retry/visibility rework
  # exists to eliminate.
  @doc false
  @spec should_trigger_source_loss_failover?(data_t()) :: boolean()
  def should_trigger_source_loss_failover?(data) when is_map(data) do
    switch_after_ms = backup_switch_after_ms(data.route)
    cooldown_until = Map.get(data, :cooldown_until)
    now_ms = Map.get(data, :now_ms, 0)
    elapsed_ms = Map.get(data, :source_loss_elapsed_ms, 0)

    cond do
      in_cooldown?(cooldown_until, now_ms) ->
        false

      true ->
        elapsed_ms >= switch_after_ms
    end
  end

  @doc false
  @spec resolve_interface_options(json_map()) :: {:ok, json_map()} | {:error, term()}
  def resolve_interface_options(opts) when is_map(opts) do
    case Map.get(opts, "interface_sys_name") do
      nil ->
        {:ok, opts}

      "" ->
        {:ok, opts}

      sys_name when is_binary(sys_name) ->
        with {:ok, bind_ip} <- resolve_interface_bind_ip(sys_name) do
          {:ok,
           opts
           |> Map.put("localaddress", bind_ip)
           |> Map.put("bind-address", bind_ip)
           |> Map.put("multicast-iface", sys_name)}
        else
          {:error, _reason} -> {:ok, opts}
          _ -> {:ok, opts}
        end
    end
  end

  def resolve_interface_options(_), do: {:error, :invalid_options}

  @doc false
  @spec drop_srt_uri_options(json_map()) :: json_map()
  def drop_srt_uri_options(opts), do: Map.delete(opts, "streamid")

  defp endpoint_options_from_record(record) when is_map(record) do
    %{}
    |> put_opt(record, "mode")
    |> put_opt(record, "interface_sys_name")
    |> put_opt(record, "localaddress")
    |> put_opt(record, "localport")
    |> put_opt(record, "address")
    |> put_opt(record, "port")
    |> put_opt(record, "host")
    |> put_opt(record, "latency")
    |> put_opt(record, "authentication")
    |> put_opt(record, "streamid")
    |> put_opt(record, "passphrase")
    |> put_opt(record, "pbkeylen")
    |> put_opt(record, "poll-timeout", "poll_timeout")
    |> put_opt(record, "auto-reconnect", "auto_reconnect")
    |> put_opt(record, "keep-listening", "keep_listening")
    |> put_opt(record, "multicast")
    |> put_opt(record, "multicast-iface", "multicast_iface")
    |> put_opt(record, "bind-address", "bind_address_option")
    |> put_opt(record, "path")
    |> put_opt(record, "location")
    |> put_opt(record, "program_number")
    |> put_opt(record, "buffer-size")
    |> put_opt(record, "buffer-size", "buffer_size")
    |> put_opt(record, "mtu")
    |> put_srt_access_opts(record)
  end

  defp put_opt(opts, record, key), do: put_opt(opts, record, key, key)

  defp put_opt(opts, record, key, source_key) do
    case Map.get(record, source_key) do
      nil -> opts
      value -> Map.put(opts, key, value)
    end
  end

  @doc false
  @spec put_srt_access_opts(json_map(), json_map()) :: json_map()
  def put_srt_access_opts(opts, record) when is_map(opts) and is_map(record) do
    if record["limit_access"] == true do
      opts
      |> Map.put("hydra_limit_access", true)
      |> Map.put("hydra_allowed_list", normalize_access_list(record["allowed_list"]))
      |> Map.put("hydra_denied_list", normalize_access_list(record["denied_list"]))
    else
      opts
    end
  end

  @doc false
  @spec normalize_access_list(term()) :: [String.t()]
  def normalize_access_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def normalize_access_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> normalize_access_list(list)
      _ -> []
    end
  end

  def normalize_access_list(_), do: []

  @doc false
  def resolve_interface_bind_ip(sys_name) when is_binary(sys_name) do
    with {:error, _reason} <- resolve_interface_bind_ip_from_system(sys_name),
         {:error, _reason} <- resolve_interface_bind_ip_from_db(sys_name) do
      {:error, :not_found}
    end
  end

  @doc false
  def resolve_interface_bind_ip_from_system(sys_name) when is_binary(sys_name) do
    system_interfaces_module =
      Application.get_env(:hydra_srt, :system_interfaces_module, SystemInterfaces)

    with {:ok, interfaces} <- system_interfaces_module.discover(),
         %{} = interface <- Enum.find(interfaces, &(&1["sys_name"] == sys_name)),
         ip when is_binary(ip) and ip != "" and ip != "-" <- Map.get(interface, "ip"),
         bind_ip when is_binary(bind_ip) and bind_ip != "" <- strip_cidr_suffix(ip) do
      {:ok, bind_ip}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def resolve_interface_bind_ip_from_db(sys_name) when is_binary(sys_name) do
    db_module = Application.get_env(:hydra_srt, :db_module, Db)

    with {:ok, interface} <- db_module.get_interface_by_sys_name(sys_name),
         ip when is_binary(ip) and ip != "" and ip != "-" <- Map.get(interface, "ip"),
         bind_ip when is_binary(bind_ip) and bind_ip != "" <- strip_cidr_suffix(ip) do
      {:ok, bind_ip}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  @spec drop_nil_values(json_map()) :: json_map()
  def drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc false
  def strip_cidr_suffix(ip) when is_binary(ip) do
    ip
    |> String.split("/", parts: 2)
    |> List.first()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp ipv6_address?(value) when is_binary(value) do
    case :inet.parse_address(to_charlist(value)) do
      {:ok, {_, _, _, _, _, _, _, _}} -> true
      _ -> false
    end
  end

  defp ipv6_address?(_), do: false

  defp link_local_ipv6?(value) when is_binary(value) do
    case :inet.parse_address(to_charlist(value)) do
      {:ok, {word0, _, _, _, _, _, _, _}} when is_integer(word0) ->
        (word0 &&& 0xFFC0) == 0xFE80

      _ ->
        false
    end
  end

  defp link_local_ipv6?(_), do: false

  @spec dummy_params() :: String.t()
  def dummy_params do
    build_config(
      "dummy-route",
      %{"id" => "dummy-source", "name" => "Dummy source", "schema" => "SRT"},
      %{
        "kind" => "srt",
        "srt" => %{
          "uri" => "srt://127.0.0.1:4201?mode=listener",
          "mode" => "listener"
        }
      },
      [
        %{
          "id" => "dummy-destination",
          "name" => "Dummy destination",
          "kind" => "srt",
          "srt" => %{
            "uri" => "srt://127.0.0.1:4205?mode=listener",
            "mode" => "listener"
          }
        }
      ]
    )
    |> Jason.encode!()
  end
end
