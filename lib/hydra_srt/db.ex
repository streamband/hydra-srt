defmodule HydraSrt.Db do
  @moduledoc false
  require Logger
  import Ecto.Query, warn: false

  alias HydraSrt.Api.Endpoint
  alias HydraSrt.Api.Interface
  alias HydraSrt.Api.Notification
  alias HydraSrt.Api.Route
  alias HydraSrt.Api.Tag
  alias HydraSrt.Api.TelemetryInstallation
  alias HydraSrt.Api.Token
  alias HydraSrt.Auth
  alias HydraSrt.Repo
  alias HydraSrt.Stats.EventLogger

  @status_stopped "stopped"

  @telemetry_transport_names [:srt, :udp, :rtp, :rtmp, :ndi, :youtube]

  @spec get_telemetry_installation() :: %TelemetryInstallation{} | nil
  def get_telemetry_installation do
    Repo.get(TelemetryInstallation, 1)
  end

  @spec upsert_telemetry_installation(map()) ::
          {:ok, %TelemetryInstallation{}} | {:error, Ecto.Changeset.t()}
  def upsert_telemetry_installation(attrs) when is_map(attrs) do
    row = get_telemetry_installation() || %TelemetryInstallation{id: 1}

    attrs
    |> Map.put_new(:id, 1)
    |> then(&TelemetryInstallation.changeset(row, &1))
    |> Repo.insert_or_update()
  end

  @spec ensure_telemetry_installation_id(boolean()) :: {:ok, String.t()} | {:error, term()}
  def ensure_telemetry_installation_id(enabled?) when is_boolean(enabled?) do
    if enabled? do
      row = get_telemetry_installation() || %TelemetryInstallation{id: 1}

      case row.installation_id do
        id when is_binary(id) and id != "" ->
          {:ok, id}

        _ ->
          id = Ecto.UUID.generate()

          case upsert_telemetry_installation(%{installation_id: id}) do
            {:ok, _row} -> {:ok, id}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:error, :disabled}
    end
  end

  @spec mark_telemetry_heartbeat(DateTime.t(), String.t()) :: :ok | {:error, term()}
  def mark_telemetry_heartbeat(timestamp, version) do
    case upsert_telemetry_installation(%{
           last_heartbeat_at: timestamp,
           last_seen_version: version
         }) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec mark_telemetry_version(String.t()) :: :ok | {:error, term()}
  def mark_telemetry_version(version) when is_binary(version) do
    case upsert_telemetry_installation(%{last_seen_version: version}) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec telemetry_route_snapshot() :: map()
  def telemetry_route_snapshot do
    routes = Repo.all(Route)
    endpoints = Repo.all(Endpoint)
    enabled_endpoints = Enum.filter(endpoints, &(&1.enabled == true))
    sources = Enum.filter(enabled_endpoints, &(&1.type == Endpoint.source_type()))
    destinations = Enum.filter(enabled_endpoints, &(&1.type == Endpoint.destination_type()))

    source_counts = telemetry_transport_counts(sources)
    destination_counts = telemetry_transport_counts(destinations)

    failover_count =
      routes
      |> Enum.count(fn route ->
        source_count = Enum.count(sources, &(&1.route_id == route.id))
        source_count >= 2 and route.backup_mode in ["active", "passive"]
      end)

    notification = get_notification_by_type(Notification.telegram_type())
    telegram_enabled = telegram_notification_enabled?(notification)
    status_values = Enum.map(routes, &(&1.schema_status || &1.status))

    %{
      route_count_total: length(routes),
      routes_active_count: Enum.count(status_values, &HydraSrt.live_route_status?/1),
      route_counts_by_source_transport: source_counts,
      route_counts_by_destination_transport: destination_counts,
      failover_configured_count: failover_count,
      interfaces_count: Repo.aggregate(Interface, :count, :id),
      mcp_enabled: true,
      ndi_enabled: HydraSrt.Ndi.FeaturePolicy.enabled?(),
      youtube_enabled: Application.get_env(:hydra_srt, :youtube, [])[:enabled] == true,
      telegram_enabled: telegram_enabled,
      victoria_configured: victoria_configured?()
    }
  end

  @spec telemetry_transport_counts(list(%Endpoint{})) :: map()
  def telemetry_transport_counts(endpoints) do
    counts = Map.new(@telemetry_transport_names, &{&1, 0})

    Enum.reduce(endpoints, counts, fn endpoint, acc ->
      key = String.downcase(to_string(endpoint.schema))

      case Enum.find(@telemetry_transport_names, &(Atom.to_string(&1) == key)) do
        nil -> acc
        transport -> Map.update!(acc, transport, &(&1 + 1))
      end
    end)
  end

  @spec telegram_notification_enabled?(%Notification{} | nil) :: boolean()
  def telegram_notification_enabled?(%Notification{enabled: true, config: config})
      when is_map(config) do
    is_binary(notification_param(config, "bot_token", "")) and
      notification_param(config, "bot_token", "") != "" and
      is_binary(notification_param(config, "chat_id", "")) and
      notification_param(config, "chat_id", "") != ""
  end

  def telegram_notification_enabled?(_notification), do: false

  @spec victoria_configured?() :: boolean()
  def victoria_configured? do
    Enum.any?(["VICTORIA_METRICS_URL", "VICTORIA_LOGS_URL"], fn key ->
      case System.get_env(key) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end)
  end

  @spec create_route(map, binary | nil) :: {:ok, map} | {:error, any}
  def create_route(data, id \\ nil) when is_map(data) do
    {tag_names, route_data} = pop_tags(data)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:tags, fn repo, _changes ->
      upsert_tags_by_name(repo, tag_names || [])
    end)
    |> Ecto.Multi.insert(:route, fn %{tags: tags} ->
      %Route{}
      |> Route.changeset(route_data)
      |> maybe_put_changeset_id(id)
      |> Ecto.Changeset.put_assoc(:tags, tags)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{route: route}} ->
        # Preload sources for the map, route already has tags from put_assoc
        {:ok, route_to_map(Repo.preload(route, :sources))}

      {:error, :route, %Ecto.Changeset{} = changeset, _} ->
        {:error, changeset}

      {:error, :tags, reason, _} ->
        {:error, add_tags_error(%Route{}, route_data, reason)}

      {:error, _, reason, _} ->
        {:error, reason}
    end
  end

  @spec get_route(String.t(), boolean) :: {:ok, map} | {:error, any}
  def get_route(id, include_dest? \\ false) when is_binary(id) do
    get_route(id, include_dest?, true)
  end

  @doc """
  Fresh, single-row read of a route's live-ness for the RTMP publish gate.

  Used after subscribing to the route's status topic so the gate can re-verify the
  route is still live: a stop before this read is caught here, a stop after it is
  caught by the subscription just established. Mirrors the liveness rule used by
  `find_live_routes_by_rtmp_path/1` (`schema_status || status` in the live set).
  """
  @spec route_live?(String.t()) :: boolean()
  def route_live?(route_id) when is_binary(route_id) do
    case Repo.get(Route, route_id) do
      %Route{schema_status: schema_status, status: status} ->
        HydraSrt.live_route_status?(schema_status || status)

      nil ->
        false
    end
  end

  @spec get_route_map(String.t(), boolean(), boolean()) :: map() | nil
  def get_route_map(id, include_dest? \\ false, include_sources? \\ true) when is_binary(id) do
    case get_route(id, include_dest?, include_sources?) do
      {:ok, map} -> map
      _ -> nil
    end
  end

  @spec get_route(String.t(), boolean, boolean) :: {:ok, map} | {:error, any}
  def get_route(id, include_dest?, include_sources?) when is_binary(id) do
    case Repo.get(Route, id) do
      nil ->
        {:error, :not_found}

      %Route{} = route ->
        route = Repo.preload(route, :tags)

        destinations =
          if include_dest? do
            list_destinations_for_route(id)
          else
            []
          end

        sources = if include_sources?, do: list_sources_for_route(id), else: []
        route_map = route_to_map(route, include_dest?, destinations, sources)

        {:ok, route_map}
    end
  end

  @spec update_route(String.t(), map) :: {:ok, map} | {:error, any}
  def update_route(id, data) when is_binary(id) and is_map(data) do
    case Repo.get(Route, id) do
      nil ->
        {:error, :not_found}

      %Route{} = route ->
        {tag_names, route_data} = pop_tags(data)

        Ecto.Multi.new()
        |> Ecto.Multi.run(:tags, fn repo, _changes ->
          if is_list(tag_names) do
            upsert_tags_by_name(repo, tag_names)
          else
            {:ok, nil}
          end
        end)
        |> Ecto.Multi.update(
          :route,
          fn %{tags: tags} ->
            route
            |> Repo.preload(:tags)
            |> Route.changeset(route_data)
            |> then(fn cs ->
              if is_list(tag_names), do: Ecto.Changeset.put_assoc(cs, :tags, tags), else: cs
            end)
          end,
          stale_error_field: :lock_version
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{route: updated}} ->
            # route_to_map needs sources; we preload them to avoid redundant get_route call
            {:ok, route_to_map(Repo.preload(updated, :sources))}

          {:error, :route, %Ecto.Changeset{} = changeset, _} ->
            {:error, changeset}

          {:error, :tags, reason, _} ->
            {:error, add_tags_error(route, route_data, reason)}

          {:error, _, reason, _} ->
            {:error, reason}
        end
    end
  end

  defp add_tags_error(route, route_data, reason) do
    route
    |> Route.changeset(route_data)
    |> Ecto.Changeset.add_error(:tags, to_string(reason))
  end

  @spec update_route_schema_status(String.t(), String.t() | nil) :: {:ok, map()} | {:error, any()}
  def update_route_schema_status(id, schema_status) when is_binary(id) do
    update_route(id, %{"schema_status" => schema_status})
  end

  @spec update_destinations_status(String.t(), String.t() | nil) :: :ok
  def update_destinations_status(route_id, status) when is_binary(route_id) do
    from(d in Endpoint,
      where:
        d.route_id == ^route_id and d.enabled == true and d.type == ^Endpoint.destination_type()
    )
    |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now(:microsecond)])

    :ok
  end

  @spec update_sources_status(String.t(), String.t() | nil, String.t() | nil) :: :ok
  def update_sources_status(route_id, status, active_source_id \\ nil) when is_binary(route_id) do
    now = DateTime.utc_now(:microsecond)

    active_source_id =
      if is_binary(active_source_id) do
        active_source_id
      else
        case Repo.get(Route, route_id) do
          %Route{} = route -> route.active_source_id
          _ -> nil
        end
      end

    # Sources are cold-standby. Only active source should mirror runtime status.
    from(s in Endpoint,
      where: s.route_id == ^route_id and s.type == ^Endpoint.source_type()
    )
    |> Repo.update_all(set: [status: "stopped", updated_at: now])

    :ok = update_active_source_status(route_id, active_source_id, status, now)

    :ok
  end

  @spec update_active_source_status(String.t(), String.t() | nil, String.t() | nil, DateTime.t()) ::
          :ok
  def update_active_source_status(route_id, active_source_id, status, now)
      when is_binary(route_id) and is_struct(now, DateTime) do
    if is_binary(active_source_id) do
      from(s in Endpoint,
        where:
          s.route_id == ^route_id and s.type == ^Endpoint.source_type() and
            s.id == ^active_source_id
      )
      |> Repo.update_all(set: [status: status, updated_at: now])
    end

    :ok
  end

  @spec list_routes_with_stale_runtime_status() :: list(%Route{})
  def list_routes_with_stale_runtime_status do
    from(r in Route, where: r.status != "stopped" or is_nil(r.status))
    |> Repo.all()
  end

  @spec list_destinations_with_stale_runtime_status() :: list(%Endpoint{})
  def list_destinations_with_stale_runtime_status do
    from(d in Endpoint,
      where:
        (d.status != "stopped" or is_nil(d.status)) and d.type == ^Endpoint.destination_type()
    )
    |> Repo.all()
  end

  @spec list_enabled_routes() :: list(%Route{})
  def list_enabled_routes do
    from(r in Route, where: r.enabled == true, order_by: [asc: r.inserted_at])
    |> Repo.all()
  end

  @doc """
  Returns live routes whose RTMP source `path` matches the given path.

  Used by the RTMP publish gate to decide whether to accept a publisher: a publish
  is accepted only when at least one route consuming that RTMP path is live
  (`schema_status || status` in `HydraSrt.live_route_statuses/0`). Path is
  normalized with `HydraSrt.Api.Endpoint.normalize_rtmp_path/1` before matching.
  Returns a list of `%{id: route_id, status: runtime_status}` maps.
  """
  @spec find_live_routes_by_rtmp_path(String.t()) :: [%{id: String.t(), status: String.t()}]
  def find_live_routes_by_rtmp_path(path) when is_binary(path) do
    normalized = HydraSrt.Api.Endpoint.normalize_rtmp_path(path)
    live = MapSet.new(HydraSrt.live_route_statuses())
    source_type = Endpoint.source_type()
    destination_type = Endpoint.destination_type()

    # A publish to a local RTMP path is owned by a live route in two shapes:
    #   - an enabled RTMP *source* whose `path` matches and that is the route's active
    #     source (cold-standby backup sources with a different path must not gate-publish
    #     unless they are the active one); when no active source is recorded the route is
    #     treated as single-source and any matching enabled source is accepted.
    #   - an enabled RTMP *destination* whose `location` URL path matches (the native
    #     rtmpsink publishes back into the local RtmpServer for play fan-out).
    from(e in Endpoint,
      join: r in Route,
      on: r.id == e.route_id,
      where:
        e.schema == "RTMP" and
          e.enabled == true and
          (e.type == ^source_type or e.type == ^destination_type),
      order_by: [asc: r.inserted_at, asc: r.id],
      select: %{
        id: r.id,
        schema_status: r.schema_status,
        status: r.status,
        type: e.type,
        path: e.path,
        location: e.location,
        endpoint_id: e.id,
        active_source_id: r.active_source_id
      }
    )
    |> Repo.all()
    |> Enum.filter(fn %{type: type, path: ep_path, location: location} ->
      case type do
        ^source_type -> ep_path == normalized
        ^destination_type -> rtmp_location_path_matches?(location, normalized)
        _ -> false
      end
    end)
    |> Enum.filter(fn %{
                        type: type,
                        endpoint_id: endpoint_id,
                        active_source_id: active_source_id
                      } ->
      # Only the route's active source may gate-publish once failover has selected one;
      # destinations are always eligible (no active-source concept applies to them).
      case type do
        ^source_type -> is_nil(active_source_id) or active_source_id == endpoint_id
        _ -> true
      end
    end)
    |> Enum.filter(fn %{schema_status: schema_status, status: status} ->
      MapSet.member?(live, schema_status || status)
    end)
    |> Enum.map(fn %{id: id, schema_status: schema_status, status: status} ->
      %{id: id, status: schema_status || status}
    end)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Human-readable detail for RTMP publish gate `route_not_live` logging.

  Pass `stale_matches` when `find_live_routes_by_rtmp_path/1` returned candidates but a
  fresh `route_live?/1` check rejected them all (lookup race).
  """
  @spec describe_rtmp_publish_gate_rejection(String.t(), keyword()) :: String.t()
  def describe_rtmp_publish_gate_rejection(path, opts \\ []) when is_binary(path) do
    case Keyword.get(opts, :stale_matches) do
      matches when is_list(matches) and matches != [] ->
        ids = Enum.map(matches, & &1.id)
        statuses = Enum.map(matches, & &1.status)

        "detail=stale_live_verify route_ids=#{inspect(ids)} statuses=#{inspect(statuses)} " <>
          "hint=\"Route stopped between lookup and publish admission\""

      _ ->
        describe_rtmp_publish_gate_no_live_match(path)
    end
  end

  defp describe_rtmp_publish_gate_no_live_match(path) when is_binary(path) do
    normalized = HydraSrt.Api.Endpoint.normalize_rtmp_path(path)
    live = MapSet.new(HydraSrt.live_route_statuses())
    source_type = Endpoint.source_type()
    destination_type = Endpoint.destination_type()
    rows = rtmp_publish_gate_candidate_rows(source_type, destination_type)

    hint_start =
      "hint=\"Start a route with an enabled RTMP source on this path\""

    cond do
      rows == [] ->
        "detail=no_rtmp_endpoints normalized_path=#{inspect(normalized)} #{hint_start}"

      true ->
        matching =
          Enum.filter(rows, fn row ->
            rtmp_publish_gate_path_matches?(row, normalized, source_type, destination_type)
          end)

        if matching == [] do
          configured =
            rows
            |> Enum.map(fn row ->
              case row.endpoint_type do
                ^source_type -> row.path
                ^destination_type -> row.location
                _ -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          obs_hint =
            "hint=\"Publish with OBS Server=rtmp://HOST:1935/live and Stream Key=<name>; " <>
              "do not put the full path in Server with an empty Stream Key\""

          "detail=no_path_match normalized_path=#{inspect(normalized)} " <>
            "configured_rtmp_paths=#{inspect(configured)} #{obs_hint}"
        else
          summaries =
            Enum.map(matching, fn row ->
              runtime = row.schema_status || row.route_status

              excluded =
                cond do
                  row.endpoint_enabled != true ->
                    "endpoint_disabled"

                  row.endpoint_type == source_type and row.active_source_id != nil and
                      row.active_source_id != row.endpoint_id ->
                    "inactive_backup_source"

                  not MapSet.member?(live, runtime) ->
                    "status_not_live(#{runtime})"

                  true ->
                    "eligible"
                end

              name = row.route_name || row.route_id

              "route=#{inspect(name)} id=#{row.route_id} runtime_status=#{inspect(runtime)} excluded=#{excluded}"
            end)

          live_list = HydraSrt.live_route_statuses() |> Enum.join(",")

          "detail=no_live_route normalized_path=#{inspect(normalized)} " <>
            "candidates=[#{Enum.join(summaries, "; ")}] live_statuses=[#{live_list}] #{hint_start}"
        end
    end
  end

  defp rtmp_publish_gate_candidate_rows(source_type, destination_type) do
    from(e in Endpoint,
      join: r in Route,
      on: r.id == e.route_id,
      where:
        e.schema == "RTMP" and
          (e.type == ^source_type or e.type == ^destination_type),
      order_by: [asc: r.inserted_at, asc: r.id],
      select: %{
        route_id: r.id,
        route_name: r.name,
        route_status: r.status,
        schema_status: r.schema_status,
        active_source_id: r.active_source_id,
        endpoint_id: e.id,
        endpoint_enabled: e.enabled,
        endpoint_type: e.type,
        path: e.path,
        location: e.location
      }
    )
    |> Repo.all()
  end

  defp rtmp_publish_gate_path_matches?(row, normalized, source_type, destination_type) do
    case row.endpoint_type do
      ^source_type -> row.path == normalized
      ^destination_type -> rtmp_location_path_matches?(row.location, normalized)
      _ -> false
    end
  end

  defp rtmp_location_path_matches?(location, normalized) when is_binary(location) do
    # Only an RTMP destination whose `location` points back at the *local* RtmpServer
    # unlocks the publish gate (the native rtmpsink publishes into the local server for
    # play fan-out). An external sink (e.g. YouTube) that merely shares a path suffix
    # must not open the gate for local publishing.
    case URI.parse(location) do
      %URI{scheme: "rtmp", host: host, port: port, path: uri_path}
      when is_binary(host) and host != "" and is_binary(uri_path) and uri_path != "" ->
        local_rtmp_host?(host) and local_rtmp_port?(port) and
          HydraSrt.Api.Endpoint.normalize_rtmp_path(uri_path) == normalized

      _ ->
        false
    end
  end

  defp rtmp_location_path_matches?(_location, _normalized), do: false

  defp local_rtmp_host?(host) when is_binary(host) do
    host in ["127.0.0.1", "localhost", "::1", "[::1]"]
  end

  defp local_rtmp_port?(nil), do: local_rtmp_port?(1935)

  defp local_rtmp_port?(port) when is_integer(port) do
    rtmp_port = Application.get_env(:hydra_srt, :rtmp_port, 1935)
    port == rtmp_port
  end

  @spec list_all_tags() :: list(String.t())
  def list_all_tags do
    from(t in Tag, select: t.name, order_by: [asc: t.name])
    |> Repo.all()
  end

  @spec list_tags() :: list(%Tag{})
  def list_tags do
    from(t in Tag, order_by: [asc: t.name])
    |> Repo.all()
  end

  @spec create_tag(map()) :: {:ok, %Tag{}} | {:error, %Ecto.Changeset{}}
  def create_tag(attrs) when is_map(attrs) do
    name =
      attrs
      |> Map.get("name", Map.get(attrs, :name))
      |> to_string()
      |> String.trim()

    case upsert_tags_by_name([name]) do
      {:ok, [tag | _]} -> {:ok, tag}
      {:ok, []} -> {:error, Tag.changeset(%Tag{}, %{name: ""})}
    end
  end

  @spec update_tag(String.t(), map()) :: {:ok, %Tag{}} | {:error, :not_found | %Ecto.Changeset{}}
  def update_tag(id, attrs) when is_binary(id) and is_map(attrs) do
    case Repo.get(Tag, id) do
      nil ->
        {:error, :not_found}

      %Tag{} = tag ->
        tag
        |> Tag.changeset(attrs)
        |> Repo.update()
    end
  end

  @spec delete_tag(String.t()) :: {:ok, %Tag{}} | {:error, :not_found | %Ecto.Changeset{}}
  def delete_tag(id) when is_binary(id) do
    case Repo.get(Tag, id) do
      nil ->
        {:error, :not_found}

      %Tag{} = tag ->
        Repo.delete(tag)
    end
  end

  @spec list_tokens() :: list(%Token{})
  def list_tokens do
    from(t in Token, order_by: [asc: t.name])
    |> Repo.all()
  end

  @create_token_max_attempts 3

  @spec create_token(map()) ::
          {:ok, %Token{}, String.t()} | {:error, %Ecto.Changeset{}}
  def create_token(attrs) when is_map(attrs) do
    name =
      attrs
      |> Map.get("name", Map.get(attrs, :name))
      |> to_string()
      |> String.trim()

    insert_token_with_generated_secret(name, @create_token_max_attempts)
  end

  def insert_token_with_generated_secret(name, attempts_left) when attempts_left > 0 do
    raw_token = generate_mcp_token()
    hashed_token = Auth.hash_token(raw_token)

    %Token{}
    |> Token.changeset(%{name: name, hash: hashed_token})
    |> Repo.insert()
    |> case do
      {:ok, token} ->
        {:ok, token, raw_token}

      {:error, %Ecto.Changeset{} = changeset} ->
        if hash_collision?(changeset) and attempts_left > 1 do
          insert_token_with_generated_secret(name, attempts_left - 1)
        else
          {:error, changeset}
        end
    end
  end

  def hash_collision?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:hash, {_message, _opts}} -> true
      _ -> false
    end)
  end

  @spec update_token(String.t(), map()) ::
          {:ok, %Token{}} | {:error, :not_found | %Ecto.Changeset{}}
  def update_token(id, attrs) when is_binary(id) and is_map(attrs) do
    name =
      attrs
      |> Map.get("name", Map.get(attrs, :name))
      |> to_string()
      |> String.trim()

    case Repo.get(Token, id) do
      nil ->
        {:error, :not_found}

      %Token{} = token ->
        token
        |> Token.changeset(%{name: name, hash: token.hash})
        |> Repo.update()
    end
  end

  @spec delete_token(String.t()) :: {:ok, %Token{}} | {:error, :not_found | %Ecto.Changeset{}}
  def delete_token(id) when is_binary(id) do
    case Repo.get(Token, id) do
      nil ->
        {:error, :not_found}

      %Token{} = token ->
        Repo.delete(token)
    end
  end

  @spec authenticate_mcp_token(String.t()) :: boolean()
  def authenticate_mcp_token(token) when is_binary(token) do
    hashed_token = Auth.hash_token(token)

    Repo.exists?(from(t in Token, where: t.hash == ^hashed_token))
  end

  @spec generate_mcp_token() :: String.t()
  def generate_mcp_token do
    :crypto.strong_rand_bytes(30)
    |> Base.url_encode64(padding: false)
  end

  @spec get_notification_by_type(String.t()) :: %Notification{} | nil
  def get_notification_by_type(type) when is_binary(type) do
    Repo.get_by(Notification, type: type)
  end

  @spec upsert_telegram_notification(map()) ::
          {:ok, %Notification{}} | {:error, %Ecto.Changeset{}}
  def upsert_telegram_notification(attrs) when is_map(attrs) do
    type = Notification.telegram_type()
    incoming_config = notification_config_params(attrs)

    notification =
      case get_notification_by_type(type) do
        %Notification{} = row -> row
        nil -> %Notification{type: type, enabled: false, config: %{}}
      end

    enabled =
      case Map.fetch(attrs, "enabled") do
        {:ok, _} ->
          notification_param(attrs, "enabled", false)

        :error ->
          case Map.fetch(attrs, :enabled) do
            {:ok, _} -> notification_param(attrs, "enabled", false)
            :error -> notification.enabled
          end
      end

    merged_config = merge_telegram_config(notification.config || %{}, incoming_config)

    notification
    |> Notification.changeset(%{
      type: type,
      enabled: enabled,
      config: merged_config
    })
    |> Repo.insert_or_update()
  end

  def merge_telegram_config(existing_config, incoming_config) when is_map(incoming_config) do
    existing = stringify_config_keys(existing_config)

    incoming_config
    |> Enum.reduce(existing, fn
      {"bot_token", ""}, acc ->
        acc

      {"bot_token", token}, acc when is_binary(token) ->
        Map.put(acc, "bot_token", String.trim(token))

      {"chat_id", chat_id}, acc when not is_nil(chat_id) ->
        Map.put(acc, "chat_id", to_string(chat_id) |> String.trim())

      _, acc ->
        acc
    end)
  end

  def stringify_config_keys(config) when is_map(config) do
    Map.new(config, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  def notification_param(attrs, key, default) do
    value = HydraSrt.Helpers.get_by_string_key(attrs, key, default)

    case value do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      1 -> true
      0 -> false
      _ -> default
    end
  end

  def notification_config_params(attrs) do
    config =
      Map.get(attrs, "config") ||
        Map.get(attrs, :config) ||
        %{}

    bot_token =
      notification_param_string(attrs, "bot_token") ||
        notification_param_string(config, "bot_token")

    chat_id =
      notification_param_string(attrs, "chat_id") ||
        notification_param_string(config, "chat_id")

    %{}
    |> maybe_put_config("bot_token", bot_token)
    |> maybe_put_config("chat_id", chat_id)
  end

  def notification_param_string(attrs, key) when is_map(attrs) do
    value = HydraSrt.Helpers.get_by_string_key(attrs, key)

    case value do
      nil -> nil
      value when is_binary(value) -> String.trim(value)
      value -> value |> to_string() |> String.trim()
    end
  end

  def maybe_put_config(config, _key, nil), do: config
  def maybe_put_config(config, _key, ""), do: config
  def maybe_put_config(config, key, value), do: Map.put(config, key, value)

  @spec upsert_tags_by_name(list(String.t())) :: {:ok, list(%Tag{})} | {:error, any()}
  def upsert_tags_by_name(names) when is_list(names) do
    upsert_tags_by_name(Repo, names)
  end

  @spec upsert_tags_by_name(module(), list(String.t())) :: {:ok, list(%Tag{})} | {:error, any()}
  def upsert_tags_by_name(repo, names) when is_list(names) do
    names =
      names
      |> Enum.map(&(to_string(&1) |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if names == [] do
      {:ok, []}
    else
      now = DateTime.utc_now(:microsecond)

      rows =
        Enum.map(names, fn name ->
          %{
            id: Ecto.UUID.generate(),
            name: name,
            inserted_at: now,
            updated_at: now
          }
        end)

      repo.insert_all(Tag, rows, on_conflict: :nothing, conflict_target: [:name])

      tags =
        from(t in Tag, where: t.name in ^names)
        |> repo.all()

      if length(tags) == length(names) do
        {:ok, tags}
      else
        # This could happen if names are somehow invalid or if someone deleted a tag
        # between insert and select, but it's very unlikely.
        # We try to recover by returning what we found if it's acceptable.
        {:ok, tags}
      end
    end
  end

  @spec reset_runtime_statuses_to_stopped() :: %{
          routes: non_neg_integer(),
          destinations: non_neg_integer(),
          sources: non_neg_integer()
        }
  def reset_runtime_statuses_to_stopped do
    now = DateTime.utc_now(:microsecond)

    {routes_count, _} =
      from(r in Route)
      |> Repo.update_all(
        set: [
          status: "stopped",
          schema_status: "stopped",
          stopped_at: now,
          updated_at: now
        ]
      )

    {destinations_count, _} =
      from(d in Endpoint, where: d.type == ^Endpoint.destination_type())
      |> Repo.update_all(
        set: [
          status: "stopped",
          stopped_at: now,
          updated_at: now
        ]
      )

    {sources_count, _} =
      from(s in Endpoint, where: s.type == ^Endpoint.source_type())
      |> Repo.update_all(
        set: [
          status: "stopped",
          stopped_at: now,
          updated_at: now
        ]
      )

    %{routes: routes_count, destinations: destinations_count, sources: sources_count}
  end

  @spec update_route_runtime_status(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, any()}
  def update_route_runtime_status(route_id, status) when is_binary(route_id) do
    :ok = update_destinations_status(route_id, status)
    :ok = update_sources_status(route_id, status)
    update_route_schema_status(route_id, status)
  end

  @spec update_route_status_with_previous(String.t(), map()) ::
          {:ok, %{route: map(), previous_status: String.t() | nil}} | {:error, any()}
  def update_route_status_with_previous(route_id, route_attrs)
      when is_binary(route_id) and is_map(route_attrs) do
    case Repo.transaction(fn ->
           route =
             case Repo.get(Route, route_id, lock: "FOR UPDATE") do
               nil -> Repo.rollback(:not_found)
               %Route{} = current -> current
             end

           previous_status = route.schema_status || route.status

           updated_route = update_route_in_transaction(route, route_attrs)

           %{route: get_route_map(updated_route.id), previous_status: previous_status}
         end) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @spec update_route_runtime_status_with_previous(String.t(), String.t() | nil) ::
          {:ok, %{route: map(), previous_status: String.t() | nil}} | {:error, any()}
  def update_route_runtime_status_with_previous(route_id, status) when is_binary(route_id) do
    transition_route_runtime_status_in_transaction(
      route_id,
      %{"schema_status" => status},
      status,
      @status_stopped,
      lock: true,
      include_previous: true,
      map_in_transaction: true,
      active_source: :original
    )
  end

  @spec transition_route_runtime_status(
          String.t(),
          map(),
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, map()} | {:error, any()}
  def transition_route_runtime_status(route_id, route_attrs, destinations_status, sources_status)
      when is_binary(route_id) and is_map(route_attrs) do
    case Repo.get(Route, route_id) do
      nil ->
        {:error, :not_found}

      %Route{} = route ->
        case transition_route_runtime_status_in_transaction(
               route_id,
               route_attrs,
               destinations_status,
               sources_status,
               route: route,
               active_source: :updated
             ) do
          {:ok, %Route{} = updated_route} ->
            {:ok, get_route_map(updated_route.id)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error, changeset}
        end
    end
  end

  @spec transition_route_runtime_status_with_previous(
          String.t(),
          map(),
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, %{route: map(), previous_status: String.t() | nil}} | {:error, any()}
  def transition_route_runtime_status_with_previous(
        route_id,
        route_attrs,
        destinations_status,
        sources_status
      )
      when is_binary(route_id) and is_map(route_attrs) do
    transition_route_runtime_status_in_transaction(
      route_id,
      route_attrs,
      destinations_status,
      sources_status,
      lock: true,
      include_previous: true,
      map_in_transaction: true,
      include_destinations: true,
      active_source: :updated
    )
  end

  @spec transition_route_runtime_status_in_transaction(
          String.t(),
          map(),
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) ::
          {:ok, %Route{} | %{route: map(), previous_status: String.t() | nil}}
          | {:error, any()}
  def transition_route_runtime_status_in_transaction(
        route_id,
        route_attrs,
        destinations_status,
        sources_status,
        opts \\ []
      )
      when is_binary(route_id) and is_map(route_attrs) and is_list(opts) do
    lock? = Keyword.get(opts, :lock, false)
    include_previous? = Keyword.get(opts, :include_previous, false)
    map_in_transaction? = Keyword.get(opts, :map_in_transaction, false)
    include_destinations? = Keyword.get(opts, :include_destinations, false)
    active_source = Keyword.get(opts, :active_source, :updated)
    loaded_route = Keyword.get(opts, :route)

    Repo.transaction(fn ->
      route =
        case loaded_route do
          %Route{} = current ->
            current

          nil ->
            lock_opts = if lock?, do: [lock: "FOR UPDATE"], else: []

            case Repo.get(Route, route_id, lock_opts) do
              nil -> Repo.rollback(:not_found)
              %Route{} = current -> current
            end
        end

      previous_status = route.schema_status || route.status
      updated_route = update_route_in_transaction(route, route_attrs)

      active_source_id =
        case active_source do
          :original -> route.active_source_id
          :updated -> updated_route.active_source_id
        end

      :ok =
        update_route_endpoints(
          route_id,
          destinations_status,
          sources_status,
          active_source_id
        )

      result_route =
        if map_in_transaction? do
          get_route_map(updated_route.id, include_destinations?)
        else
          updated_route
        end

      if include_previous? do
        %{route: result_route, previous_status: previous_status}
      else
        result_route
      end
    end)
  end

  @spec update_route_in_transaction(%Route{}, map()) :: %Route{}
  def update_route_in_transaction(%Route{} = route, route_attrs) when is_map(route_attrs) do
    route
    |> Route.changeset(route_attrs)
    |> Repo.update(stale_error_field: :lock_version)
    |> case do
      {:ok, updated} -> updated
      {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
    end
  end

  @spec update_route_endpoints(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) :: :ok
  def update_route_endpoints(route_id, destinations_status, sources_status, active_source_id)
      when is_binary(route_id) do
    now = DateTime.utc_now(:microsecond)

    from(d in Endpoint,
      where:
        d.route_id == ^route_id and d.enabled == true and
          d.type == ^Endpoint.destination_type()
    )
    |> Repo.update_all(set: [status: destinations_status, updated_at: now])

    from(s in Endpoint,
      where: s.route_id == ^route_id and s.type == ^Endpoint.source_type()
    )
    |> Repo.update_all(set: [status: @status_stopped, updated_at: now])

    :ok = update_active_source_status(route_id, active_source_id, sources_status, now)

    :ok
  end

  @spec delete_route(String.t()) :: [:ok] | [{:error, any}]
  def delete_route(id) when is_binary(id) do
    case Repo.get(Route, id) do
      nil ->
        [{:error, :not_found}]

      %Route{} = route ->
        case Repo.delete(route) do
          {:ok, _} -> [:ok, :ok]
          {:error, %Ecto.Changeset{} = changeset} -> [{:error, changeset}]
        end
    end
  end

  @spec create_interface(map(), binary() | nil) :: {:ok, map()} | {:error, any()}
  def create_interface(data, id \\ nil) when is_map(data) do
    changeset =
      %Interface{}
      |> Interface.changeset(data)
      |> maybe_put_changeset_id(id)

    case Repo.insert(changeset) do
      {:ok, interface} ->
        {:ok, interface_to_map(interface)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @spec get_interface(String.t()) :: {:ok, map()} | {:error, any()}
  def get_interface(id) when is_binary(id) do
    case Repo.get(Interface, id) do
      nil -> {:error, :not_found}
      %Interface{} = interface -> {:ok, interface_to_map(interface)}
    end
  end

  @spec get_interface_by_sys_name(String.t()) :: {:ok, map()} | {:error, any()}
  def get_interface_by_sys_name(sys_name) when is_binary(sys_name) do
    case Repo.get_by(Interface, sys_name: sys_name) do
      nil -> {:error, :not_found}
      %Interface{} = interface -> {:ok, interface_to_map(interface)}
    end
  end

  @spec update_interface(String.t(), map()) :: {:ok, map()} | {:error, any()}
  def update_interface(id, data) when is_binary(id) and is_map(data) do
    case Repo.get(Interface, id) do
      nil ->
        {:error, :not_found}

      %Interface{} = interface ->
        interface
        |> Interface.changeset(data)
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, interface_to_map(updated)}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  @spec delete_interface(String.t()) :: :ok | {:error, any()}
  def delete_interface(id) when is_binary(id) do
    case Repo.get(Interface, id) do
      nil ->
        {:error, :not_found}

      %Interface{} = interface ->
        case Repo.delete(interface) do
          {:ok, _} -> :ok
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  @spec get_all_interfaces() :: {:ok, list(map())}
  def get_all_interfaces do
    interfaces =
      from(i in Interface, order_by: [desc: i.inserted_at])
      |> Repo.all()
      |> Enum.map(&interface_to_map/1)

    {:ok, interfaces}
  end

  @spec create_destination(String.t(), map, binary | nil) :: {:ok, map} | {:error, any}
  def create_destination(route_id, data, id \\ nil)
      when is_binary(route_id) and is_map(data) do
    data =
      data
      |> Map.put_new("route_id", route_id)
      |> ensure_destination_position_for_insert()

    changeset =
      %Endpoint{}
      |> Endpoint.destination_changeset(data)
      |> maybe_put_changeset_id(id)

    case Repo.insert(changeset) do
      {:ok, destination} ->
        {:ok, destination_to_map(destination)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp ensure_destination_position_for_insert(data) when is_map(data) do
    case Map.fetch(data, "position") do
      {:ok, _} ->
        data

      :error ->
        case Map.fetch(data, :position) do
          {:ok, _} ->
            data

          :error ->
            rid = Map.get(data, "route_id") || Map.get(data, :route_id)

            if is_binary(rid) do
              Map.put(data, "position", next_destination_position(rid))
            else
              data
            end
        end
    end
  end

  defp next_destination_position(route_id) when is_binary(route_id) do
    from(e in Endpoint,
      where: e.route_id == ^route_id and e.type == ^Endpoint.destination_type(),
      select: max(e.position)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      n when is_integer(n) -> n + 1
    end
  end

  @spec get_destination(String.t(), String.t()) :: {:ok, map} | {:error, any}
  def get_destination(route_id, id) when is_binary(route_id) and is_binary(id) do
    case get_endpoint_record(route_id, id, Endpoint.destination_type()) do
      nil -> {:error, :not_found}
      %Endpoint{} = destination -> {:ok, destination_to_map(destination)}
    end
  end

  @spec update_destination(String.t(), String.t(), map) :: {:ok, map} | {:error, any}
  def update_destination(route_id, id, data)
      when is_binary(route_id) and is_binary(id) and is_map(data) do
    case get_endpoint_record(route_id, id, Endpoint.destination_type()) do
      nil ->
        {:error, :not_found}

      %Endpoint{} = destination ->
        destination
        |> Endpoint.destination_changeset(data)
        |> Repo.update(stale_error_field: :lock_version)
        |> case do
          {:ok, updated} -> {:ok, destination_to_map(updated)}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  def del_destination(route_id, id) when is_binary(route_id) and is_binary(id) do
    case get_endpoint_record(route_id, id, Endpoint.destination_type()) do
      nil ->
        {:error, :not_found}

      %Endpoint{} = destination ->
        case Repo.delete(destination) do
          {:ok, _} -> :ok
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  @spec get_all_routes(boolean, binary) :: {:ok, list(map)} | {:error, any}
  def get_all_routes(with_destinations \\ false, sort_by \\ "created_at") do
    order_field =
      case sort_by do
        "updated_at" -> :updated_at
        _ -> :inserted_at
      end

    routes =
      from(r in Route, order_by: [desc: field(r, ^order_field)])
      |> Repo.all()
      |> Repo.preload(:tags)

    source_map = list_sources_for_routes(routes)

    destination_map =
      if with_destinations do
        list_destinations_for_routes(routes)
      else
        %{}
      end

    routes =
      Enum.map(routes, fn route ->
        sources = Map.get(source_map, route.id, [])
        destinations = Map.get(destination_map, route.id, [])
        route_to_map(route, with_destinations, destinations, sources)
      end)

    {:ok, routes}
  end

  @spec get_routes_page(boolean, binary, pos_integer(), pos_integer()) ::
          {:ok,
           %{
             routes: list(map()),
             total: non_neg_integer(),
             page: pos_integer(),
             limit: pos_integer()
           }}
          | {:error, any()}
  def get_routes_page(with_destinations \\ false, sort_by \\ "created_at", page \\ 1, limit \\ 50)
      when is_integer(page) and page > 0 and is_integer(limit) and limit > 0 do
    order_field =
      case sort_by do
        "updated_at" -> :updated_at
        _ -> :inserted_at
      end

    offset = (page - 1) * limit
    total = Repo.aggregate(Route, :count, :id)

    routes =
      from(r in Route, order_by: [desc: field(r, ^order_field)], limit: ^limit, offset: ^offset)
      |> Repo.all()
      |> Repo.preload(:tags)

    source_map = list_sources_for_routes(routes)

    destination_map =
      if with_destinations do
        list_destinations_for_routes(routes)
      else
        %{}
      end

    routes =
      Enum.map(routes, fn route ->
        sources = Map.get(source_map, route.id, [])
        destinations = Map.get(destination_map, route.id, [])
        route_to_map(route, with_destinations, destinations, sources)
      end)

    {:ok, %{routes: routes, total: total, page: page, limit: limit}}
  end

  def get_all_destinations(route_id) when is_binary(route_id) do
    {:ok, Enum.map(list_destinations_for_route(route_id), &destination_to_map/1)}
  end

  @spec create_source(String.t(), map, binary | nil) :: {:ok, map} | {:error, any}
  def create_source(route_id, data, id \\ nil)
      when is_binary(route_id) and is_map(data) do
    data = Map.put_new(data, "route_id", route_id)

    changeset =
      %Endpoint{}
      |> Endpoint.source_changeset(data)
      |> maybe_put_changeset_id(id)

    case Repo.insert(changeset) do
      {:ok, source} ->
        {:ok, source_to_map(source)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @spec get_source(String.t(), String.t()) :: {:ok, map} | {:error, any}
  def get_source(route_id, id) when is_binary(route_id) and is_binary(id) do
    case get_endpoint_record(route_id, id, Endpoint.source_type()) do
      nil -> {:error, :not_found}
      %Endpoint{} = source -> {:ok, source_to_map(source)}
    end
  end

  @spec update_source(String.t(), String.t(), map) :: {:ok, map} | {:error, any}
  def update_source(route_id, id, data)
      when is_binary(route_id) and is_binary(id) and is_map(data) do
    case get_endpoint_record(route_id, id, Endpoint.source_type()) do
      nil ->
        {:error, :not_found}

      %Endpoint{} = source ->
        source
        |> Endpoint.source_changeset(data)
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, source_to_map(updated)}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  def del_source(route_id, id) when is_binary(route_id) and is_binary(id) do
    route = Repo.get(Route, route_id)

    case get_endpoint_record(route_id, id, Endpoint.source_type()) do
      nil ->
        {:error, :not_found}

      %Endpoint{} = source ->
        if route && route.active_source_id == source.id do
          {:error, :active_source_cannot_be_deleted}
        else
          case Repo.delete(source) do
            {:ok, _} -> :ok
            {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
          end
        end
    end
  end

  def get_all_sources(route_id) when is_binary(route_id) do
    {:ok, Enum.map(list_sources_for_route(route_id), &source_to_map/1)}
  end

  @spec reorder_sources(String.t(), list(String.t())) :: {:ok, list(map())} | {:error, any()}
  def reorder_sources(route_id, source_ids)
      when is_binary(route_id) and is_list(source_ids) do
    sources = list_sources_for_route(route_id)
    existing_ids = MapSet.new(Enum.map(sources, & &1.id))
    requested_ids = MapSet.new(source_ids)

    cond do
      source_ids == [] ->
        {:error, :invalid_source_order}

      existing_ids != requested_ids ->
        {:error, :invalid_source_order}

      true ->
        case Repo.transaction(fn ->
               # Two-step update to avoid unique conflicts on (route_id, position).
               from(s in Endpoint,
                 where: s.route_id == ^route_id and s.type == ^Endpoint.source_type()
               )
               |> Repo.update_all(
                 inc: [position: 1000],
                 set: [updated_at: DateTime.utc_now(:microsecond)]
               )

               source_ids
               |> Enum.with_index()
               |> Enum.each(fn {id, position} ->
                 from(s in Endpoint,
                   where:
                     s.id == ^id and s.route_id == ^route_id and
                       s.type == ^Endpoint.source_type()
                 )
                 |> Repo.update_all(
                   set: [position: position, updated_at: DateTime.utc_now(:microsecond)]
                 )
               end)
             end) do
          {:ok, _} ->
            {:ok, Enum.map(list_sources_for_route(route_id), &source_to_map/1)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec set_route_active_source(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, any()}
  def set_route_active_source(route_id, source_id, reason)
      when is_binary(route_id) and is_binary(source_id) and is_binary(reason) do
    with %Route{} = route <- Repo.get(Route, route_id),
         %Endpoint{} = source <- get_endpoint_record(route_id, source_id, Endpoint.source_type()),
         {:ok, updated} <-
           route
           |> Route.changeset(%{
             "active_source_id" => source.id,
             "last_switch_reason" => reason,
             "last_switch_at" => DateTime.utc_now(:microsecond)
           })
           |> Repo.update() do
      map = get_route_map(updated.id)

      EventLogger.log_source_switch(
        route_id,
        route.active_source_id,
        source.id,
        reason,
        %{
          active_source_id: source.id
        }
      )

      Phoenix.PubSub.broadcast(
        HydraSrt.PubSub,
        "item:#{route_id}",
        {:item_source,
         %{
           item_id: route_id,
           active_source_id: source.id,
           last_switch_reason: reason,
           last_switch_at: map["last_switch_at"]
         }}
      )

      {:ok, map}
    else
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @spec backup() :: {:ok, binary} | {:error, any}
  def backup do
    HydraSrt.Backup.backup_db_file()
  end

  @spec restore_backup(binary) :: :ok | {:error, any}
  def restore_backup(binary_data) when is_binary(binary_data) do
    HydraSrt.Backup.restore_db_file(binary_data)
  end

  @doc false
  def list_destinations_for_route(route_id) when is_binary(route_id) do
    from(d in Endpoint,
      where: d.route_id == ^route_id and d.type == ^Endpoint.destination_type(),
      order_by: [desc: d.inserted_at]
    )
    |> Repo.all()
  end

  @doc false
  def list_sources_for_route(route_id) when is_binary(route_id) do
    from(s in Endpoint,
      where: s.route_id == ^route_id and s.type == ^Endpoint.source_type(),
      order_by: [asc: s.position]
    )
    |> Repo.all()
  end

  defp list_sources_for_routes(routes) when is_list(routes) do
    route_ids = Enum.map(routes, & &1.id)

    from(s in Endpoint,
      where: s.route_id in ^route_ids and s.type == ^Endpoint.source_type(),
      order_by: [asc: s.position]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_id)
  end

  defp list_destinations_for_routes(routes) when is_list(routes) do
    route_ids = Enum.map(routes, & &1.id)

    from(d in Endpoint,
      where: d.route_id in ^route_ids and d.type == ^Endpoint.destination_type(),
      order_by: [desc: d.inserted_at]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_id)
  end

  defp get_endpoint_record(route_id, endpoint_id, endpoint_type)
       when is_binary(route_id) and is_binary(endpoint_id) and is_binary(endpoint_type) do
    from(e in Endpoint,
      where: e.id == ^endpoint_id and e.route_id == ^route_id and e.type == ^endpoint_type
    )
    |> Repo.one()
  end

  @doc false
  def route_to_map(%Route{} = route, include_destinations \\ false) do
    route_to_map(route, include_destinations, [], list_sources_for_route(route.id))
  end

  def route_to_map(%Route{} = route, true, destinations, sources)
      when is_list(destinations) and is_list(sources) do
    Map.put(
      route_to_map(route, false, [], sources),
      "destinations",
      Enum.map(destinations, &destination_to_map/1)
    )
  end

  def route_to_map(%Route{} = route, false, _destinations, sources) when is_list(sources) do
    {sources_maps, active_source_id, fallback_source_id} =
      Enum.reduce(sources, {[], nil, nil}, fn source, {mapped, active_id, fallback_id} ->
        source_map = source_to_map(source)

        next_active_id =
          if source.id == route.active_source_id do
            source.id
          else
            active_id
          end

        next_fallback_id =
          if is_nil(fallback_id) and source.position == 0 do
            source.id
          else
            fallback_id
          end

        {[source_map | mapped], next_active_id, next_fallback_id}
      end)

    %{
      "id" => route.id,
      "enabled" => route.enabled,
      "name" => route.name,
      "alias" => route.alias,
      "status" => route.status,
      "schema_status" => route.schema_status,
      "sources" => Enum.reverse(sources_maps),
      "active_source_id" => route.active_source_id || active_source_id || fallback_source_id,
      "backup_mode" => route.backup_mode || "passive",
      "backup_switch_after_ms" => route.backup_switch_after_ms || 3000,
      "backup_cooldown_ms" => route.backup_cooldown_ms || 10_000,
      "backup_primary_stable_ms" => route.backup_primary_stable_ms || 15_000,
      "backup_probe_interval_ms" => route.backup_probe_interval_ms || 5000,
      "last_switch_reason" => route.last_switch_reason,
      "last_switch_at" => route.last_switch_at,
      "node" => route.node,
      "gstDebug" => route.gst_debug,
      "tags" =>
        case route.tags do
          %Ecto.Association.NotLoaded{} ->
            # Returning empty list is better than crashing, but we avoid side-effects here.
            []

          tags when is_list(tags) ->
            Enum.map(tags, & &1.name)
        end,
      "source" => route.source,
      "started_at" => route.started_at,
      "stopped_at" => route.stopped_at,
      "created_at" => route.inserted_at,
      "updated_at" => route.updated_at,
      "destinations" => []
    }
  end

  @doc false
  def destination_to_map(%Endpoint{} = destination) do
    endpoint_base_map(destination)
    |> Map.merge(%{
      "id" => destination.id,
      "route_id" => destination.route_id,
      "lock_version" => destination.lock_version,
      "position" => destination.position,
      "alias" => destination.alias,
      "node" => destination.node,
      "started_at" => destination.started_at,
      "stopped_at" => destination.stopped_at
    })
  end

  @doc false
  def source_to_map(%Endpoint{} = source) do
    endpoint_base_map(source)
    |> Map.merge(%{
      "id" => source.id,
      "route_id" => source.route_id,
      "lock_version" => source.lock_version,
      "position" => source.position,
      "last_probe_at" => source.last_probe_at,
      "last_failure_at" => source.last_failure_at
    })
  end

  @spec endpoint_base_map(%Endpoint{}) :: %{String.t() => term()}
  def endpoint_base_map(%Endpoint{} = endpoint) do
    %{
      "enabled" => endpoint.enabled,
      "name" => endpoint.name,
      "schema" => endpoint.schema,
      "mode" => endpoint.mode,
      "interface_sys_name" => endpoint.interface_sys_name,
      "localaddress" => endpoint.localaddress,
      "localport" => endpoint.localport,
      "address" => endpoint.address,
      "port" => endpoint.port,
      "host" => endpoint.host,
      "latency" => endpoint.latency,
      "authentication" => endpoint.authentication,
      "streamid" => endpoint.streamid,
      "passphrase" => endpoint.passphrase,
      "pbkeylen" => endpoint.pbkeylen,
      "poll_timeout" => endpoint.poll_timeout,
      "auto_reconnect" => endpoint.auto_reconnect,
      "keep_listening" => endpoint.keep_listening,
      "multicast" => endpoint.multicast || false,
      "multicast_iface" => endpoint.multicast_iface,
      "bind_address_option" => endpoint.bind_address_option,
      "path" => endpoint.path,
      "location" => endpoint.location,
      "allowed_list" => Endpoint.decode_ip_access_list(endpoint.allowed_list),
      "denied_list" => Endpoint.decode_ip_access_list(endpoint.denied_list),
      "limit_access" => endpoint.limit_access || false,
      "program_number" => endpoint.program_number,
      "ndi_source_name" => endpoint.ndi_source_name,
      "ndi_source_address" => endpoint.ndi_source_address,
      "ndi_selection_mode" => endpoint.ndi_selection_mode,
      "ndi_observed_address_snapshot" => endpoint.ndi_observed_address_snapshot,
      "ndi_observed_name_snapshot" => endpoint.ndi_observed_name_snapshot,
      "ndi_selection_observed_at" => endpoint.ndi_selection_observed_at,
      "ndi_receiver_name" => endpoint.ndi_receiver_name,
      "ndi_media_policy" => endpoint.ndi_media_policy,
      "ndi_bandwidth" => endpoint.ndi_bandwidth,
      "ndi_color_format" => endpoint.ndi_color_format,
      "ndi_timestamp_mode" => endpoint.ndi_timestamp_mode,
      "ndi_connect_timeout_ms" => endpoint.ndi_connect_timeout_ms,
      "ndi_receive_timeout_ms" => endpoint.ndi_receive_timeout_ms,
      "ndi_track_discovery_timeout_ms" => endpoint.ndi_track_discovery_timeout_ms,
      "ndi_max_queue_length" => endpoint.ndi_max_queue_length,
      "ndi_sender_name" => endpoint.ndi_sender_name,
      "youtube_url" => endpoint.youtube_url,
      "youtube_format_id" => endpoint.youtube_format_id,
      "youtube_quality_policy" => endpoint.youtube_quality_policy,
      "youtube_live_mode" => endpoint.youtube_live_mode,
      "youtube_media_info" => endpoint.youtube_media_info,
      "youtube_info_updated_at" => endpoint.youtube_info_updated_at,
      "youtube_end_action" => endpoint.youtube_end_action,
      "status" => endpoint.status,
      "created_at" => endpoint.inserted_at,
      "updated_at" => endpoint.updated_at
    }
  end

  @doc false
  def interface_to_map(%Interface{} = interface) do
    %{
      "id" => interface.id,
      "name" => interface.name,
      "sys_name" => interface.sys_name,
      "ip" => interface.ip,
      "enabled" => interface.enabled,
      "created_at" => interface.inserted_at,
      "updated_at" => interface.updated_at
    }
  end

  def maybe_put_changeset_id(%Ecto.Changeset{} = changeset, nil), do: changeset

  def maybe_put_changeset_id(%Ecto.Changeset{} = changeset, id) when is_binary(id) do
    Ecto.Changeset.put_change(changeset, :id, id)
  end

  defp pop_tags(data) when is_map(data) do
    case Map.pop(data, "tags") do
      {nil, data} -> Map.pop(data, :tags)
      {tags, data} -> {tags, data}
    end
  end
end
