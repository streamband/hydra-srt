defmodule HydraSrtWeb.Telemetry.EnvelopeRateLimiter do
  @moduledoc false

  @table :hydra_srt_telemetry_envelope_rate_limiter
  @limit 20
  @window_seconds 60

  @spec allow?(binary()) :: boolean()
  def allow?(session_hash) when is_binary(session_hash) do
    ensure_table()
    window = div(System.system_time(:second), @window_seconds)
    key = {session_hash, window}
    _ = :ets.insert_new(@table, {key, 0})
    count = :ets.update_counter(@table, key, {2, 1})
    count <= @limit
  end

  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _table ->
        :ok
    end
  end

  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _table -> :ets.delete_all_objects(@table) && :ok
    end
  end
end
