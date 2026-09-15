defmodule HydraSrt.Telemetry.Runtime do
  @moduledoc "Installs Sentry's crash-only Logger handler."

  use GenServer
  require Logger

  @handler_id :hydra_srt_sentry_handler

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    state = %{installed: false}

    case start_sentry() do
      :ok ->
        {:ok, %{state | installed: true}}

      :disabled ->
        {:ok, state}

      {:error, reason} ->
        Logger.warning("HydraSRT Sentry initialization failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  @spec terminate(term(), map()) :: :ok
  def terminate(_reason, %{installed: true}), do: remove_handler()
  def terminate(_reason, _state), do: :ok

  @spec start_sentry() :: :ok | :disabled | {:error, term()}
  def start_sentry do
    if HydraSrt.Telemetry.Settings.crash_enabled?() do
      case Application.ensure_all_started(:sentry) do
        {:ok, _started} -> install_handler()
        {:error, reason} -> {:error, reason}
      end
    else
      :disabled
    end
  rescue
    error -> {:error, error}
  end

  @spec install_handler() :: :ok | {:error, term()}
  def install_handler do
    case :logger.add_handler(@handler_id, Sentry.LoggerHandler, %{
           config: %{
             capture_level: :error,
             capture_log_messages: false,
             capture_metadata: [:request_id],
             capture_excluded_domains: [:cowboy, :hydra_telemetry],
             sync_threshold: nil,
             discard_threshold: 100
           }
         }) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      other -> other
    end
  rescue
    error -> {:error, error}
  end

  @spec remove_handler() :: :ok
  def remove_handler do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      _ -> :ok
    end
  end
end
