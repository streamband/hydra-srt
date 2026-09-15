defmodule HydraSrt.Telemetry.Event do
  @moduledoc "Strict allowlist for the PostHog event envelope."

  alias HydraSrt.Telemetry.{HeartbeatEvent, RouteEvent, StartedEvent}

  @transports [:srt, :udp, :rtmp, :rtp, :ndi, :youtube]
  @duration_buckets [:lt_1m, :lt_10m, :lt_1h, :lt_1d, :ge_1d]
  @restart_count_buckets [:"0", :"1", :"2_5", :"6_20", :gt_20]
  @max_count 100_000
  @max_body_bytes 64 * 1024

  @spec to_posthog_event(struct()) :: {:ok, map()} | {:error, term()}
  def to_posthog_event(%HeartbeatEvent{} = event) do
    if valid_struct_keys?(event, [
         :event,
         :version,
         :os_family,
         :arch,
         :distribution,
         :uptime_bucket,
         :route_count_total,
         :routes_active_count,
         :route_counts_by_source_transport,
         :route_counts_by_destination_transport,
         :failover_configured_count,
         :mcp_enabled,
         :ndi_enabled,
         :youtube_enabled,
         :telegram_enabled,
         :victoria_configured,
         :interfaces_count,
         :installation_id,
         :session_id
       ]),
       do: heartbeat(event),
       else: {:error, :unknown_keys}
  end

  def to_posthog_event(%StartedEvent{} = event) do
    if valid_struct_keys?(event, [
         :event,
         :version,
         :distribution,
         :previous_version,
         :installation_id,
         :session_id
       ]),
       do: started(event),
       else: {:error, :unknown_keys}
  end

  def to_posthog_event(%RouteEvent{} = event) do
    if valid_struct_keys?(event, [
         :event,
         :source_transport,
         :destination_transports,
         :destination_count,
         :failover_enabled,
         :has_passphrase,
         :has_stream_id,
         :reason,
         :duration_bucket,
         :restart_count_bucket,
         :installation_id,
         :session_id
       ]),
       do: route(event),
       else: {:error, :unknown_keys}
  end

  def to_posthog_event(_event), do: {:error, :unknown_event}

  @spec encode(struct()) :: {:ok, binary()} | {:error, term()}
  def encode(event) do
    with {:ok, payload} <- to_posthog_event(event),
         {:ok, encoded} <- Jason.encode(payload) do
      validate_size(encoded)
    end
  end

  @spec encode_batch([struct()]) :: {:ok, binary()} | {:error, term()}
  def encode_batch(events) when is_list(events) do
    with {:ok, payloads} <- encode_payloads(events),
         {:ok, encoded} <- Jason.encode(%{api_key: posthog_key(), batch: payloads}) do
      validate_size(encoded)
    end
  end

  @spec encode_payloads([struct()]) :: {:ok, [map()]} | {:error, term()}
  def encode_payloads(events) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
      case to_posthog_event(event) do
        {:ok, payload} -> {:cont, {:ok, [payload | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      error -> error
    end
  end

  @spec heartbeat(HeartbeatEvent.t()) :: {:ok, map()} | {:error, term()}
  def heartbeat(event) do
    with true <- event.event == "hydra.heartbeat",
         :ok <- validate_common(event),
         :ok <- validate_enum(event.os_family, [:linux, :darwin, :windows, :freebsd, :other]),
         :ok <- validate_enum(event.arch, [:x86_64, :aarch64, :armv7, :other]),
         :ok <- validate_enum(event.distribution, [:docker, :release, :source]),
         :ok <-
           validate_enum(event.uptime_bucket, [
             :under_5m,
             :five_minutes_to_1h,
             :one_to_24h,
             :one_to_7d,
             :over_7d
           ]),
         :ok <- validate_count(event.route_count_total),
         :ok <- validate_count(event.routes_active_count),
         :ok <- validate_count(event.failover_configured_count),
         :ok <- validate_count(event.interfaces_count),
         :ok <- validate_transport_map(event.route_counts_by_source_transport),
         :ok <- validate_transport_map(event.route_counts_by_destination_transport),
         :ok <- validate_boolean_fields(event) do
      {:ok,
       envelope(event.event, event.installation_id, %{
         version: event.version,
         os_family: Atom.to_string(event.os_family),
         arch: Atom.to_string(event.arch),
         distribution: Atom.to_string(event.distribution),
         uptime_bucket: Atom.to_string(event.uptime_bucket),
         route_count_total: event.route_count_total,
         routes_active_count: event.routes_active_count,
         route_counts_by_source_transport:
           fixed_transport_map(event.route_counts_by_source_transport),
         route_counts_by_destination_transport:
           fixed_transport_map(event.route_counts_by_destination_transport),
         failover_configured_count: event.failover_configured_count,
         mcp_enabled: event.mcp_enabled,
         ndi_enabled: event.ndi_enabled,
         youtube_enabled: event.youtube_enabled,
         telegram_enabled: event.telegram_enabled,
         victoria_configured: event.victoria_configured,
         interfaces_count: event.interfaces_count,
         installation_id: event.installation_id,
         session_id: event.session_id
       })}
    else
      false -> {:error, :invalid_event}
      error -> error
    end
  end

  @spec started(StartedEvent.t()) :: {:ok, map()} | {:error, term()}
  def started(event) do
    with true <- event.event == "hydra.started",
         :ok <- validate_common(event),
         :ok <- validate_enum(event.distribution, [:docker, :release, :source]),
         :ok <- validate_optional_version(event.previous_version) do
      {:ok,
       envelope(event.event, event.installation_id, %{
         version: event.version,
         distribution: Atom.to_string(event.distribution),
         previous_version: event.previous_version,
         installation_id: event.installation_id,
         session_id: event.session_id
       })}
    else
      false -> {:error, :invalid_event}
      error -> error
    end
  end

  @spec route(RouteEvent.t()) :: {:ok, map()} | {:error, term()}
  def route(event) do
    with true <- event.event in ["hydra.route.started", "hydra.route.stopped"],
         :ok <- validate_enum(event.source_transport, @transports ++ [:unknown]),
         :ok <- validate_destination_transports(event.destination_transports),
         :ok <- validate_count(event.destination_count),
         true <- is_boolean(event.failover_enabled),
         true <- is_boolean(event.has_passphrase),
         true <- is_boolean(event.has_stream_id),
         true <- event.destination_count == length(event.destination_transports),
         :ok <- validate_route_optional_fields(event) do
      {:ok,
       envelope(event.event, event.installation_id, %{
         source_transport: Atom.to_string(event.source_transport),
         destination_transports: Enum.map(event.destination_transports, &Atom.to_string/1),
         destination_count: event.destination_count,
         failover_enabled: event.failover_enabled,
         has_passphrase: event.has_passphrase,
         has_stream_id: event.has_stream_id,
         reason: event.reason && Atom.to_string(event.reason),
         duration_bucket: event.duration_bucket && Atom.to_string(event.duration_bucket),
         restart_count_bucket:
           event.restart_count_bucket && Atom.to_string(event.restart_count_bucket),
         session_id: event.session_id
       })}
    else
      false -> {:error, :invalid_route_event}
      _ -> {:error, :invalid_route_event}
    end
  end

  @spec validate_common(struct()) :: :ok | {:error, term()}
  def validate_common(event) do
    if is_binary(event.event) and is_binary(event.version) and byte_size(event.version) <= 64 and
         valid_uuid?(event.installation_id) and valid_uuid?(event.session_id) do
      :ok
    else
      {:error, :invalid_identity_or_version}
    end
  end

  @spec valid_struct_keys?(struct(), [atom()]) :: boolean()
  def valid_struct_keys?(event, allowed) do
    Map.keys(event) |> Enum.sort() == [:__struct__ | Enum.sort(allowed)]
  end

  @spec validate_count(term()) :: :ok | {:error, term()}
  def validate_count(value) when is_integer(value) and value >= 0 and value <= @max_count, do: :ok
  def validate_count(_value), do: {:error, :invalid_count}

  @spec validate_transport_map(term()) :: :ok | {:error, term()}
  def validate_transport_map(value) when is_map(value) do
    if Enum.all?(value, fn {key, count} -> key in @transports and validate_count(count) == :ok end),
       do: :ok,
       else: {:error, :invalid_transport_map}
  end

  def validate_transport_map(_value), do: {:error, :invalid_transport_map}

  @spec fixed_transport_map(map()) :: map()
  def fixed_transport_map(value), do: Map.new(@transports, &{&1, value[&1] || 0})

  @spec validate_destination_transports(term()) :: :ok | {:error, term()}
  def validate_destination_transports(value) when is_list(value) do
    if Enum.all?(value, &(&1 in (@transports ++ [:unknown]))),
      do: :ok,
      else: {:error, :invalid_transport}
  end

  def validate_destination_transports(_value), do: {:error, :invalid_transport}

  @spec validate_route_optional_fields(RouteEvent.t()) :: :ok | {:error, term()}
  def validate_route_optional_fields(event) do
    valid_reason = is_nil(event.reason) or event.reason in [:manual, :error, :restart]
    valid_duration = is_nil(event.duration_bucket) or event.duration_bucket in @duration_buckets

    valid_restart =
      is_nil(event.restart_count_bucket) or event.restart_count_bucket in @restart_count_buckets

    if valid_reason and valid_duration and valid_restart,
      do: :ok,
      else: {:error, :invalid_route_event}
  end

  @spec validate_enum(term(), [atom()]) :: :ok | {:error, term()}
  def validate_enum(value, allowed),
    do: if(value in allowed, do: :ok, else: {:error, :invalid_enum})

  @spec validate_boolean_fields(HeartbeatEvent.t()) :: :ok | {:error, term()}
  def validate_boolean_fields(event) do
    values = [
      event.mcp_enabled,
      event.ndi_enabled,
      event.youtube_enabled,
      event.telegram_enabled,
      event.victoria_configured
    ]

    if Enum.all?(values, &is_boolean/1), do: :ok, else: {:error, :invalid_boolean}
  end

  @spec validate_optional_version(binary() | nil) :: :ok | {:error, term()}
  def validate_optional_version(nil), do: :ok
  def validate_optional_version(value) when is_binary(value) and byte_size(value) <= 64, do: :ok
  def validate_optional_version(_value), do: {:error, :invalid_version}

  @spec valid_uuid?(term()) :: boolean()
  def valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  def valid_uuid?(_value), do: false

  @spec envelope(String.t(), String.t(), map()) :: map()
  def envelope(event, distinct_id, properties) do
    %{
      event: event,
      distinct_id: distinct_id,
      properties:
        Map.merge(
          %{
            "$process_person_profile" => false,
            "$lib" => "hydra-srt",
            "$lib_version" => HydraSrt.Telemetry.Config.version()
          },
          properties
        ),
      timestamp: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  @spec posthog_key() :: String.t()
  def posthog_key, do: Application.get_env(:hydra_srt, :telemetry, [])[:posthog_key] || ""

  @spec validate_size(binary()) :: {:ok, binary()} | {:error, :event_too_large}
  def validate_size(encoded) when byte_size(encoded) <= @max_body_bytes, do: {:ok, encoded}
  def validate_size(_encoded), do: {:error, :event_too_large}
end
