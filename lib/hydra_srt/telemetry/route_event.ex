defmodule HydraSrt.Telemetry.RouteEvent do
  @moduledoc false

  defstruct event: nil,
            source_transport: :unknown,
            destination_transports: [],
            destination_count: 0,
            failover_enabled: false,
            has_passphrase: false,
            has_stream_id: false,
            reason: nil,
            duration_bucket: nil,
            restart_count_bucket: nil,
            installation_id: nil,
            session_id: nil

  @type t :: %__MODULE__{}
end
