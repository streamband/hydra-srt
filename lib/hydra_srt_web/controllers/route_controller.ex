defmodule HydraSrtWeb.RouteController do
  use HydraSrtWeb, :controller

  alias HydraSrt.EndpointHealth
  alias HydraSrt.RouteAnalytics
  alias HydraSrt.RouteControl
  alias HydraSrt.Routes
  alias HydraSrt.Tags

  action_fallback HydraSrtWeb.FallbackController

  def index(conn, params) do
    case Routes.list_page(params) do
      {:ok, payload} ->
        conn
        |> json(%{
          data: payload.routes,
          meta: %{
            page: payload.page,
            limit: payload.limit,
            total: payload.total
          }
        })

      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch routes: #{inspect(error)}"})
    end
  end

  def list_tags(conn, _params) do
    data(conn, Tags.list())
  end

  def create_tag(conn, %{"tag" => tag_params}) do
    with {:ok, tag} <- Tags.create(tag_params) do
      conn
      |> put_status(:created)
      |> data(tag)
    end
  end

  def update_tag(conn, %{"id" => id, "tag" => tag_params}) do
    with {:ok, tag} <- Tags.update(id, tag_params) do
      data(conn, tag)
    end
  end

  def delete_tag(conn, %{"id" => id}) do
    with {:ok, _tag} <- Tags.delete(id) do
      send_resp(conn, :no_content, "")
    end
  end

  def create(conn, %{"route" => route_params}) do
    with {:ok, route} <- Routes.create(route_params) do
      conn
      |> put_status(:created)
      |> data(route)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, route} <- Routes.get(id) do
      data(conn, route)
    end
  end

  def update(conn, %{"id" => id, "route" => route_params}) do
    with {:ok, route} <- Routes.update(id, route_params) do
      data(conn, route)
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Routes.delete(id) do
      send_resp(conn, :no_content, "")
    end
  end

  def start(conn, %{"route_id" => route_id}) do
    case Routes.start(route_id) do
      {:ok, payload} ->
        conn
        |> put_status(:ok)
        |> data(payload)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def stop(conn, %{"route_id" => route_id}) do
    case Routes.stop(route_id) do
      {:ok, payload} ->
        conn
        |> put_status(:ok)
        |> data(payload)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def restart(conn, %{"route_id" => route_id}) do
    case Routes.restart(route_id) do
      {:ok, payload} ->
        conn
        |> put_status(:ok)
        |> data(payload)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  @spec reset_stats(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset_stats(conn, %{"route_id" => route_id}) do
    case RouteControl.reset_route_stats(route_id) do
      {:ok, reset_at} ->
        data(conn, %{route_id: route_id, stats_reset_at: DateTime.to_iso8601(reset_at)})

      {:error, :route_handler_unavailable} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Route is not running"})

      {:error, :no_stats_yet} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "No statistics received yet"})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to reset route statistics"})
    end
  end

  @spec clear_stats_reset(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def clear_stats_reset(conn, %{"route_id" => route_id}) do
    case RouteControl.clear_route_stats_reset(route_id) do
      {:ok, nil} ->
        data(conn, %{route_id: route_id, stats_reset_at: nil})

      {:error, :route_handler_unavailable} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Route is not running"})

      {:error, :no_stats_yet} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "No statistics received yet"})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to reset route statistics"})
    end
  end

  @doc """
  Endpoint-health snapshot for a route, consumed by the NDI Health tab.
  """
  @spec endpoint_health(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, :not_found}
  def endpoint_health(conn, %{"route_id" => route_id}) when is_binary(route_id) do
    case EndpointHealth.snapshot(route_id) do
      {:ok, snapshot} ->
        data(conn, snapshot)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def switch_source(conn, %{"id" => route_id, "source_id" => source_id}) do
    case Routes.switch_source(route_id, source_id) do
      {:ok, route} -> data(conn, route)
      {:error, reason} -> {:error, reason}
    end
  end

  def switch_source(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required 'source_id' parameter"})
  end

  def analytics(conn, %{"route_id" => route_id} = params) do
    case RouteAnalytics.route_timeseries(route_id, params) do
      {:ok, analytics_data} ->
        data(conn, analytics_data)

      {:error, {:bad_request, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch analytics"})
    end
  end

  def statuses_analytics(conn, params) do
    case RouteAnalytics.routes_status_timeseries(params) do
      {:ok, payload} ->
        data(conn, payload)

      {:error, {:bad_request, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch route status analytics"})
    end
  end

  def statuses_history(conn, params) do
    case RouteAnalytics.routes_status_history(params) do
      {:ok, payload} ->
        data(conn, payload)

      {:error, {:bad_request, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch route status history"})
    end
  end

  def events(conn, %{"route_id" => route_id} = params) do
    case RouteAnalytics.route_events(route_id, params) do
      {:ok, payload} ->
        data(conn, payload)

      {:error, {:bad_request, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch events"})
    end
  end

  def pipeline_logs(conn, %{"route_id" => route_id} = params) do
    case RouteAnalytics.route_pipeline_logs(route_id, params) do
      {:ok, payload} ->
        data(conn, payload)

      {:error, {:bad_request, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch pipeline logs"})
    end
  end

  def pipeline_logs_distinct(conn, %{"route_id" => route_id, "column" => column}) do
    case RouteAnalytics.route_pipeline_log_distinct(route_id, column) do
      {:ok, values} ->
        data(conn, values)

      {:error, {:bad_request, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch distinct values"})
    end
  end

  def pipeline_logs_distinct(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required 'column' parameter"})
  end

  def test_source(conn, %{"route" => route_params}) do
    case Routes.test_source_config(route_params) do
      {:ok, result} ->
        conn
        |> put_status(:ok)
        |> data(result)

      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})
    end
  end

  def test_source(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required 'route' parameter"})
  end

  @spec data(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def data(conn, data), do: json(conn, %{data: data})
end
