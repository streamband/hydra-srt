defmodule HydraSrtWeb.Router do
  use HydraSrtWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :auth do
    plug :check_auth
  end

  pipeline :mcp do
    plug HydraSrtWeb.Plugs.McpAuth
  end

  scope "/health", HydraSrtWeb do
    get "/", HealthController, :index
  end

  scope "/metrics", HydraSrtWeb do
    get "/", MetricsController, :index
  end

  scope "/api", HydraSrtWeb do
    pipe_through :api

    post "/login", AuthController, :login
    get "/init", InitController, :show
  end

  scope "/api", HydraSrtWeb do
    pipe_through [:api, :auth]
    get "/dashboard", DashboardController, :show
    post "/routes/test-source", RouteController, :test_source
    get "/tags", RouteController, :list_tags
    post "/tags", RouteController, :create_tag
    put "/tags/:id", RouteController, :update_tag
    delete "/tags/:id", RouteController, :delete_tag
    get "/tokens", TokenController, :index
    post "/tokens", TokenController, :create
    put "/tokens/:id", TokenController, :update
    delete "/tokens/:id", TokenController, :delete
    resources "/routes", RouteController, except: [:new, :edit]
    get "/routes/statuses/analytics", RouteController, :statuses_analytics
    get "/routes/statuses/history", RouteController, :statuses_history
    get "/routes/:route_id/analytics", RouteController, :analytics
    get "/routes/:route_id/events", RouteController, :events
    get "/routes/:route_id/pipeline-logs", RouteController, :pipeline_logs
    get "/routes/:route_id/pipeline-logs/distinct", RouteController, :pipeline_logs_distinct
    get "/routes/:route_id/start", RouteController, :start
    get "/routes/:route_id/stop", RouteController, :stop
    get "/routes/:route_id/restart", RouteController, :restart
    post "/routes/:route_id/stats/reset", RouteController, :reset_stats
    delete "/routes/:route_id/stats/reset", RouteController, :clear_stats_reset
    get "/routes/:route_id/endpoint-health", RouteController, :endpoint_health
    post "/routes/:id/switch-source", RouteController, :switch_source
    get "/routes/:route_id/destinations", DestinationController, :index
    post "/routes/:route_id/destinations", DestinationController, :create
    get "/routes/:route_id/destinations/:dest_id", DestinationController, :show
    put "/routes/:route_id/destinations/:dest_id", DestinationController, :update
    delete "/routes/:route_id/destinations/:dest_id", DestinationController, :delete
    get "/routes/:route_id/sources", SourceController, :index
    post "/routes/:route_id/sources", SourceController, :create
    get "/routes/:route_id/sources/:id", SourceController, :show
    patch "/routes/:route_id/sources/:id", SourceController, :update
    delete "/routes/:route_id/sources/:id", SourceController, :delete
    post "/routes/:route_id/sources-reorder", SourceController, :reorder
    post "/routes/:route_id/sources/reorder", SourceController, :reorder
    post "/routes/:route_id/sources/:id/test", SourceController, :test
    get "/interfaces/system", InterfaceController, :system
    get "/interfaces/system/raw", InterfaceController, :system_raw
    resources "/interfaces", InterfaceController, except: [:new, :edit]

    get "/notifications/telegram", NotificationController, :show_telegram
    put "/notifications/telegram", NotificationController, :update_telegram
    post "/notifications/telegram/test", NotificationController, :test_telegram

    get "/system/pipelines", SystemController, :list_pipelines
    get "/system/pipelines/detailed", SystemController, :list_pipelines_detailed
    post "/system/pipelines/:pid/kill", SystemController, :kill_pipeline
    get "/system/signal-generation", SystemController, :signal_generation_status
    put "/system/signal-generation", SystemController, :signal_generation_configure
    post "/system/signal-generation/start", SystemController, :signal_generation_start
    post "/system/signal-generation/stop", SystemController, :signal_generation_stop
    get "/system/ndi/capabilities", NdiCapabilitiesController, :show

    get "/ndi/sources", NdiSourcesController, :index
    post "/ndi/discovery/refresh", NdiSourcesController, :refresh
    post "/ndi/probes", NdiProbesController, :create

    post "/youtube/inspect", YoutubeController, :inspect
    get "/youtube/formats", YoutubeController, :formats
    post "/youtube/refresh", YoutubeController, :refresh

    get "/nodes", NodeController, :index
    get "/nodes/:id", NodeController, :show
    get "/nodes/:id/analytics", NodeController, :analytics
  end

  scope "/api/backup", HydraSrtWeb do
    pipe_through [:auth]
    get "/routes", BackupController, :export_routes
    post "/routes", BackupController, :import_routes
    get "/full", BackupController, :download_backup
    post "/full/restore", BackupController, :restore
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", Hermes.Server.Transport.StreamableHTTP.Plug, server: HydraSrt.Mcp.Server
  end

  scope "/", HydraSrtWeb do
    pipe_through(:browser)

    get "/", PageController, :index
    get "/*path", PageController, :index
  end

  defp check_auth(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        if HydraSrt.Auth.authenticate_session(token) do
          conn
        else
          conn
          |> put_status(403)
          |> Phoenix.Controller.json(%{error: "Unauthorized"})
          |> halt()
        end

      _ ->
        conn
        |> put_status(403)
        |> Phoenix.Controller.json(%{error: "Authorization header missing"})
        |> halt()
    end
  end
end
