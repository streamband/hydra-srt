defmodule HydraSrt.Telemetry.Queue do
  @moduledoc "Bounded, non-blocking usage event queue."

  use GenServer

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @spec enqueue(struct()) :: :ok
  def enqueue(event), do: GenServer.cast(@name, {:enqueue, event})

  @spec take_batch(pos_integer()) :: [struct()]
  def take_batch(limit) when is_integer(limit) and limit > 0,
    do: GenServer.call(@name, {:take_batch, limit})

  @spec requeue([struct()]) :: :ok
  def requeue(events) when is_list(events), do: GenServer.cast(@name, {:requeue, events})

  @spec discard_signal(:usage | :crash) :: :ok
  def discard_signal(signal) when signal in [:usage, :crash],
    do: GenServer.cast(@name, {:discard_signal, signal})

  @spec discard_all() :: :ok
  def discard_all, do: GenServer.cast(@name, :discard_all)

  @spec size() :: %{count: non_neg_integer(), bytes: non_neg_integer()}
  def size, do: GenServer.call(@name, :size)

  @spec flush_now(timeout()) :: :ok
  def flush_now(timeout \\ :timer.seconds(3)) do
    if Process.whereis(@name) do
      _ = GenServer.call(@name, :flush_now, timeout)
    end

    :ok
  end

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts), do: {:ok, %{usage: [], crash: [], bytes: 0}}

  @impl true
  @spec handle_cast(tuple() | atom(), map()) :: {:noreply, map()}
  def handle_cast({:enqueue, event}, state) do
    case HydraSrt.Telemetry.Event.encode(event) do
      {:ok, encoded} -> {:noreply, insert_event(event, byte_size(encoded), state)}
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_cast({:requeue, events}, state) do
    next =
      Enum.reduce(events, state, fn event, acc ->
        case HydraSrt.Telemetry.Event.encode(event) do
          {:ok, encoded} -> insert_event(event, byte_size(encoded), acc)
          {:error, _reason} -> acc
        end
      end)

    {:noreply, next}
  end

  def handle_cast({:discard_signal, signal}, state), do: {:noreply, discard_lane(signal, state)}
  def handle_cast(:discard_all, _state), do: {:noreply, %{usage: [], crash: [], bytes: 0}}

  @impl true
  @spec handle_call({:take_batch, pos_integer()} | :size | :flush_now, GenServer.from(), map()) ::
          {:reply, term(), map()}
  def handle_call({:take_batch, limit}, _from, state) do
    {events, rest} = take_events(state.usage ++ state.crash, limit)
    bytes = Enum.reduce(rest, 0, &event_bytes/2)

    {:reply, events,
     %{
       state
       | usage: Enum.filter(rest, &usage_event?/1),
         crash: Enum.filter(rest, &crash_event?/1),
         bytes: bytes
     }}
  end

  def handle_call(:size, _from, state),
    do: {:reply, %{count: length(state.usage) + length(state.crash), bytes: state.bytes}, state}

  def handle_call(:flush_now, _from, state), do: {:reply, :ok, state}

  @spec insert_event(struct(), non_neg_integer(), map()) :: map()
  def insert_event(event, bytes, state) do
    signal = if crash_event?(event), do: :crash, else: :usage
    lane = state[signal] ++ [event]
    next = %{state | signal => lane, bytes: state.bytes + bytes}
    trim_to_bounds(next, signal)
  end

  @spec trim_to_bounds(map(), :usage | :crash) :: map()
  def trim_to_bounds(state, signal) do
    max_events = Application.get_env(:hydra_srt, :telemetry, [])[:queue_max_events] || 100
    max_bytes = Application.get_env(:hydra_srt, :telemetry, [])[:queue_max_bytes] || 1_048_576

    cond do
      state.bytes <= max_bytes and length(state.usage) + length(state.crash) <= max_events ->
        state

      signal == :usage and state.usage != [] ->
        state |> then(&remove_oldest(:usage, &1)) |> trim_to_bounds(signal)

      state.crash != [] ->
        state |> then(&remove_oldest(:crash, &1)) |> trim_to_bounds(signal)

      true ->
        state
    end
  end

  @spec remove_oldest(:usage | :crash, map()) :: map()
  def remove_oldest(signal, state) do
    [event | rest] = state[signal]
    bytes = event_bytes(event, 0)
    %{state | signal => rest, bytes: max(state.bytes - bytes, 0)}
  end

  @spec discard_lane(:usage | :crash, map()) :: map()
  def discard_lane(signal, state),
    do: %{
      state
      | signal => [],
        bytes: state.bytes - Enum.reduce(state[signal], 0, &event_bytes/2)
    }

  @spec take_events([struct()], pos_integer()) :: {[struct()], [struct()]}
  def take_events(events, limit), do: Enum.split(events, limit)

  @spec event_bytes(struct(), non_neg_integer()) :: non_neg_integer()
  def event_bytes(event, _acc) do
    case HydraSrt.Telemetry.Event.encode(event) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> 0
    end
  end

  @spec crash_event?(struct()) :: boolean()
  def crash_event?(%{event: event}) when is_binary(event),
    do: String.starts_with?(event, "hydra.crash")

  def crash_event?(_event), do: false

  @spec usage_event?(struct()) :: boolean()
  def usage_event?(event), do: not crash_event?(event)
end
