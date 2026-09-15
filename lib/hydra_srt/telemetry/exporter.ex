defmodule HydraSrt.Telemetry.Exporter do
  @moduledoc "Flushes the bounded usage queue without blocking product paths."

  use GenServer
  require Logger

  alias HydraSrt.Telemetry.{HeartbeatEvent, StartedEvent}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    interval =
      Application.get_env(:hydra_srt, :telemetry, [])[:export_interval_ms] || :timer.seconds(1)

    {:ok,
     %{
       timer: Process.send_after(self(), :flush, interval),
       interval: interval,
       in_flight: nil,
       failures: 0,
       circuit: :closed,
       retry_at: 0
     }}
  end

  @impl true
  @spec handle_info(:flush | {:telemetry_send_result, reference(), [struct()], term()}, map()) ::
          {:noreply, map()}
  def handle_info(:flush, state) do
    next = %{state | timer: Process.send_after(self(), :flush, state.interval)}
    now = now_ms()

    cond do
      next.in_flight != nil ->
        {:noreply, next}

      next.circuit == :open and now < next.retry_at ->
        {:noreply, next}

      next.circuit == :open ->
        start_flush(%{next | circuit: :closed, failures: 0})

      true ->
        start_flush(next)
    end
  end

  def handle_info(
        {:telemetry_send_result, reference, events, result},
        %{in_flight: reference} = state
      ) do
    case result do
      :ok ->
        mark_success_metadata(events)

        {:noreply, %{state | in_flight: nil, failures: 0, circuit: :closed}}

      {:error, reason} ->
        Logger.debug("HydraSRT telemetry batch dropped: #{inspect(reason)}")
        HydraSrt.Telemetry.Queue.requeue(events)
        failures = state.failures + 1
        circuit = if failures >= 5, do: :open, else: :closed

        retry_at =
          if circuit == :open,
            do: now_ms() + circuit_window_ms(),
            else: now_ms() + backoff(failures)

        {:noreply,
         %{state | in_flight: nil, failures: failures, circuit: circuit, retry_at: retry_at}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec start_flush(map()) :: {:noreply, map()}
  def start_flush(state) do
    events =
      if Process.whereis(HydraSrt.Telemetry.Queue),
        do: HydraSrt.Telemetry.Queue.take_batch(25),
        else: []

    if events == [] do
      {:noreply, state}
    else
      reference = make_ref()
      parent = self()
      telemetry_opts = Application.get_env(:hydra_srt, :telemetry, [])

      opts = [
        connect_timeout_ms: telemetry_opts[:connect_timeout_ms] || :timer.seconds(2),
        request_timeout_ms: telemetry_opts[:request_timeout_ms] || :timer.seconds(5)
      ]

      case Task.Supervisor.start_child(HydraSrt.Telemetry.TaskSupervisor, fn ->
             result = HydraSrt.Telemetry.PostHogClient.post_batch(events, opts)
             send(parent, {:telemetry_send_result, reference, events, result})
           end) do
        {:ok, _pid} ->
          {:noreply, %{state | in_flight: reference}}

        {:error, reason} ->
          HydraSrt.Telemetry.Queue.requeue(events)
          Logger.debug("HydraSRT telemetry task unavailable: #{inspect(reason)}")
          {:noreply, state}
      end
    end
  end

  @spec backoff(pos_integer()) :: non_neg_integer()
  def backoff(failures) do
    min(:timer.minutes(15), :timer.seconds(1) * Integer.pow(2, failures - 1))
  end

  @spec now_ms() :: integer()
  def now_ms do
    clock = Application.get_env(:hydra_srt, :telemetry_clock, &:erlang.monotonic_time/1)
    clock.(:millisecond)
  end

  @spec circuit_window_ms() :: non_neg_integer()
  def circuit_window_ms,
    do:
      Application.get_env(:hydra_srt, :telemetry, [])[:circuit_window_ms] ||
        :timer.minutes(15)

  @spec mark_success_metadata([struct()]) :: :ok
  def mark_success_metadata(events) do
    if Enum.any?(events, &match?(%HeartbeatEvent{}, &1)) do
      _ =
        HydraSrt.Db.mark_telemetry_heartbeat(
          DateTime.utc_now(),
          HydraSrt.Telemetry.Config.version()
        )
    end

    if Enum.any?(events, &match?(%StartedEvent{}, &1)) do
      _ = HydraSrt.Db.mark_telemetry_version(HydraSrt.Telemetry.Config.version())
    end

    :ok
  rescue
    error ->
      Logger.debug("HydraSRT telemetry metadata update dropped: #{inspect(error)}")
      :ok
  end

  @impl true
  @spec terminate(term(), map()) :: :ok
  def terminate(_reason, state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)

    events = HydraSrt.Telemetry.Queue.take_batch(25)

    deadline =
      Application.get_env(:hydra_srt, :telemetry, [])[:shutdown_deadline_ms] || :timer.seconds(3)

    if events != [] do
      task = Task.async(fn -> HydraSrt.Telemetry.PostHogClient.post_batch(events, []) end)
      _ = Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill)
    end

    :ok
  end
end
