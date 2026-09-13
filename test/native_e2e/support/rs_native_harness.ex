defmodule HydraSrt.E2E.Native.Harness do
  @moduledoc false

  use GenServer

  alias HydraSrt.E2E.Native.Helpers
  alias HydraSrt.E2E.Native.ProcessRegistry

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def latest_stats(pid), do: GenServer.call(pid, :latest_stats)
  def state(pid), do: GenServer.call(pid, :state)

  @spec os_pid(pid()) :: non_neg_integer() | nil
  def os_pid(pid), do: GenServer.call(pid, :os_pid)

  def await_stats(pid, fun, timeout_ms) when is_function(fun, 1) do
    start_ms = System.monotonic_time(:millisecond)
    do_await_stats(pid, start_ms, timeout_ms, fun)
  end

  def stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  end

  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    route_id = Keyword.get(opts, :route_id, "rs_native_#{System.unique_integer([:positive])}")
    config = Keyword.fetch!(opts, :config)
    binary = Helpers.rs_native_binary_path()

    process_instance_id = Ecto.UUID.generate()
    port_env = Keyword.get(opts, :env, Helpers.native_port_env())

    port =
      Port.open({:spawn_executable, String.to_charlist(binary)}, [
        :binary,
        :exit_status,
        :stream,
        :stderr_to_stdout,
        :hide,
        args: ["route", "--route-id", route_id, "--process-instance-id", process_instance_id],
        env: port_env
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _ -> nil
      end

    registry_key = make_ref()

    :ok =
      ProcessRegistry.register!(registry_key, %{
        kind: :rs_native,
        route_id: route_id,
        os_pid: os_pid,
        port: port
      })

    true = Port.command(port, Jason.encode!(config) <> "\n")

    state = %{
      test_pid: test_pid,
      route_id: route_id,
      port: port,
      os_pid: os_pid,
      registry_key: registry_key,
      buffer: "",
      latest_stats: nil,
      source_stream_id: nil,
      lines: []
    }

    {:ok, state}
  end

  def handle_call(:latest_stats, _from, state) do
    {:reply, state.latest_stats, state}
  end

  def handle_call(:state, _from, state) do
    reply =
      Map.take(state, [:route_id, :latest_stats, :source_stream_id, :lines, :os_pid])

    {:reply, reply, state}
  end

  def handle_call(:os_pid, _from, state) do
    {:reply, state.os_pid, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    {buffer, lines} = split_lines(state.buffer <> data)

    next_state =
      Enum.reduce(lines, %{state | buffer: buffer}, fn line, acc ->
        handle_line(String.trim(line), acc)
      end)

    {:noreply, next_state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    ProcessRegistry.unregister!(state.registry_key)
    send(state.test_pid, {:rs_native_exit_status, state.route_id, status})
    {:stop, :normal, state}
  end

  def terminate(_reason, %{registry_key: registry_key} = state) do
    ProcessRegistry.cleanup_entry(registry_key, %{
      os_pid: state.os_pid,
      port: state.port
    })

    :ok
  end

  defp handle_line("", state), do: state

  defp handle_line("route_id:" <> route_id, state) do
    send(state.test_pid, {:rs_native_route_id, route_id})
    put_in(state.route_id, route_id)
  end

  defp handle_line("stats_source_stream_id:" <> stream_id, state) do
    send(state.test_pid, {:rs_native_stream_id, stream_id})
    %{state | source_stream_id: stream_id}
  end

  defp handle_line("{" <> _ = json, state) do
    case Jason.decode(json) do
      {:ok, %{"event" => _event} = event} ->
        send(state.test_pid, {:rs_native_event, event})
        %{state | lines: [json | Enum.take(state.lines, 99)]}

      {:ok, stats} ->
        send(state.test_pid, {:rs_native_stats, stats})
        %{state | latest_stats: stats, lines: [json | Enum.take(state.lines, 99)]}

      _ ->
        send(state.test_pid, {:rs_native_line, json})
        %{state | lines: [json | Enum.take(state.lines, 99)]}
    end
  end

  defp handle_line(line, state) do
    send(state.test_pid, {:rs_native_line, line})
    %{state | lines: [line | Enum.take(state.lines, 99)]}
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n", trim: false) do
      [last] ->
        {last, []}

      parts ->
        {new_buffer, lines} = List.pop_at(parts, -1)
        {new_buffer || "", lines}
    end
  end

  defp do_await_stats(pid, start_ms, timeout_ms, fun) do
    latest = latest_stats(pid)

    if fun.(latest) do
      {:ok, latest}
    else
      now = System.monotonic_time(:millisecond)

      if now - start_ms > timeout_ms do
        {:error, latest}
      else
        Process.sleep(50)
        do_await_stats(pid, start_ms, timeout_ms, fun)
      end
    end
  end
end
