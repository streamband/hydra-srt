defmodule HydraSrt.Telemetry.Encoder do
  @moduledoc "Compatibility facade for the strict telemetry event encoder."

  @spec encode(struct()) :: {:ok, binary()} | {:error, term()}
  def encode(event), do: HydraSrt.Telemetry.Event.encode(event)

  @spec encode_batch([struct()]) :: {:ok, binary()} | {:error, term()}
  def encode_batch(events), do: HydraSrt.Telemetry.Event.encode_batch(events)
end
