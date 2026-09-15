defmodule HydraSrt.Telemetry.Supervisor do
  @moduledoc "Supervises the isolated production telemetry subtree."

  use Supervisor
  require Logger

  @route_event_id {__MODULE__, :route_events}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(_opts) do
    usage = HydraSrt.Telemetry.Settings.usage_enabled?()
    crash = HydraSrt.Telemetry.Settings.crash_enabled?()

    mode = if usage or crash, do: "all", else: "off"

    Logger.info(
      "HydraSRT telemetry: mode=#{mode} distribution=#{HydraSrt.Telemetry.Config.distribution()}"
    )

    if usage or crash do
      children = [
        HydraSrt.Telemetry.Settings,
        {Task.Supervisor, name: HydraSrt.Telemetry.TaskSupervisor}
      ]

      children =
        if usage,
          do:
            children ++
              [
                HydraSrt.Telemetry.Queue,
                HydraSrt.Telemetry.Exporter,
                HydraSrt.Telemetry.Heartbeat
              ],
          else: children

      children =
        if crash,
          do: children ++ [HydraSrt.Telemetry.Crash, HydraSrt.Telemetry.Runtime],
          else: children

      if usage do
        _ = :telemetry.detach(@route_event_id)

        :telemetry.attach(
          @route_event_id,
          [:hydra, :route, :status, :transition],
          &HydraSrt.Telemetry.RouteEvents.handle/4,
          nil
        )
      end

      Supervisor.init(children, strategy: :one_for_one, max_seconds: :timer.seconds(3))
    else
      Supervisor.init([], strategy: :one_for_one, max_seconds: :timer.seconds(3))
    end
  end

  @spec terminate(term()) :: :ok
  def terminate(_reason) do
    _ = :telemetry.detach(@route_event_id)
    :ok
  end
end
