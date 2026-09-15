defmodule HydraSrt.Telemetry.Settings do
  @moduledoc "Owns the persisted production installation identity."

  use GenServer
  require Logger

  alias HydraSrt.Db

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @spec usage_enabled?() :: boolean()
  def usage_enabled?, do: Application.get_env(:hydra_srt, :telemetry, [])[:enabled?] == true

  @spec crash_enabled?() :: boolean()
  def crash_enabled?, do: Application.get_env(:hydra_srt, :telemetry, [])[:enabled?] == true

  @spec session_id() :: String.t() | nil
  def session_id do
    if Process.whereis(@name), do: GenServer.call(@name, :session_id), else: nil
  end

  @spec installation_id() :: String.t() | nil
  def installation_id do
    if Process.whereis(@name), do: GenServer.call(@name, :installation_id), else: nil
  end

  @spec snapshot() :: map()
  def snapshot do
    if Process.whereis(@name),
      do: GenServer.call(@name, :snapshot),
      else: %{installation_id: nil, last_seen_version: nil}
  end

  @spec ensure_identity(boolean()) :: {:ok, String.t()} | {:error, term()}
  def ensure_identity(enabled?) when is_boolean(enabled?) do
    if Process.whereis(@name),
      do: GenServer.call(@name, {:ensure_identity, enabled?}),
      else: {:error, :disabled}
  end

  @spec refresh() :: :ok
  def refresh do
    if Process.whereis(@name), do: GenServer.call(@name, :refresh), else: :ok
  end

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    session_id = Ecto.UUID.generate()
    boot_started_at = System.monotonic_time(:millisecond)
    _ = HydraSrt.Telemetry.RouteEvents.state_table()

    case read_installation() do
      {:ok, row} ->
        {:ok, state_from_row(row, session_id, boot_started_at)}

      {:error, reason} ->
        Logger.warning("HydraSRT telemetry installation state unavailable: #{inspect(reason)}")
        {:ok, state_from_row(nil, session_id, boot_started_at)}
    end
  end

  @impl true
  @spec handle_call(atom() | tuple(), GenServer.from(), map()) :: {:reply, term(), map()}
  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}
  def handle_call(:installation_id, _from, state), do: {:reply, state.installation_id, state}
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call({:ensure_identity, false}, _from, state),
    do: {:reply, {:error, :disabled}, state}

  def handle_call({:ensure_identity, true}, _from, %{installation_id: id} = state)
      when is_binary(id),
      do: {:reply, {:ok, id}, state}

  def handle_call({:ensure_identity, true}, _from, state) do
    case Db.ensure_telemetry_installation_id(true) do
      {:ok, id} -> {:reply, {:ok, id}, %{state | installation_id: id}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call(:refresh, _from, state) do
    case read_installation() do
      {:ok, row} ->
        {:reply, :ok, state_from_row(row, state.session_id, state.boot_started_at)}

      {:error, _reason} ->
        {:reply, :ok, state_from_row(nil, state.session_id, state.boot_started_at)}
    end
  end

  @spec read_installation() :: {:ok, map() | nil} | {:error, term()}
  def read_installation do
    {:ok, Db.get_telemetry_installation()}
  rescue
    error -> {:error, error}
  end

  @spec state_from_row(map() | nil, String.t(), integer()) :: map()
  def state_from_row(row, session_id, boot_started_at) do
    %{
      installation_id: row && row.installation_id,
      last_heartbeat_at: row && row.last_heartbeat_at,
      last_seen_version: row && row.last_seen_version,
      session_id: session_id,
      boot_started_at: boot_started_at,
      row_present: not is_nil(row)
    }
  end
end
