defmodule HydraSrt.Telemetry.HeartbeatEvent do
  @moduledoc false

  @enforce_keys [:installation_id, :session_id]
  defstruct event: "hydra.heartbeat",
            version: nil,
            os_family: nil,
            arch: nil,
            distribution: nil,
            uptime_bucket: nil,
            route_count_total: 0,
            routes_active_count: 0,
            route_counts_by_source_transport: %{},
            route_counts_by_destination_transport: %{},
            failover_configured_count: 0,
            mcp_enabled: false,
            ndi_enabled: false,
            youtube_enabled: false,
            telegram_enabled: false,
            victoria_configured: false,
            interfaces_count: 0,
            installation_id: nil,
            session_id: nil

  @type t :: %__MODULE__{}
end
