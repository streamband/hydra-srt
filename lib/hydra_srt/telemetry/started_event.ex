defmodule HydraSrt.Telemetry.StartedEvent do
  @moduledoc false

  @enforce_keys [:installation_id, :session_id]
  defstruct event: "hydra.started",
            version: nil,
            distribution: nil,
            previous_version: nil,
            installation_id: nil,
            session_id: nil

  @type t :: %__MODULE__{}
end
