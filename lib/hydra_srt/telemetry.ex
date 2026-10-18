defmodule HydraSrt.Telemetry do
  use GenServer
  import Ecto.Query, only: [from: 2]
  require Logger

  alias HydraSrt.Api.{Endpoint, Route}
  alias HydraSrt.Repo

  @posthog_host "https://eu.i.posthog.com"
  @posthog_key "phc_Caj6HJgJnjm2vf3ZS9Wd9KYUF7fqxCWnK7nFEXrvENkK"
  @first_heartbeat_after :timer.minutes(5)
  @heartbeat_every :timer.hours(24)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(opts) do
    Logger.info("HydraSRT telemetry: distribution=#{distribution()}")

    state = %{
      installation_id: load_installation_id(opts[:data_dir] || database_dir()),
      session_id: Ecto.UUID.generate(),
      booted_at: System.monotonic_time(:millisecond),
      heartbeat_every: opts[:heartbeat_every] || @heartbeat_every
    }

    send_async(state, "hydra.started", &build_facts/0)
    Process.send_after(self(), :heartbeat, opts[:first_heartbeat_after] || @first_heartbeat_after)
    {:ok, state}
  end

  @impl true
  @spec handle_info(:heartbeat, map()) :: {:noreply, map()}
  def handle_info(:heartbeat, state) do
    uptime_hours = div(System.monotonic_time(:millisecond) - state.booted_at, :timer.hours(1))

    send_async(state, "hydra.heartbeat", fn ->
      build_facts() |> Map.merge(route_facts()) |> Map.put(:uptime_hours, uptime_hours)
    end)

    Process.send_after(self(), :heartbeat, state.heartbeat_every)
    {:noreply, state}
  end

  @spec send_async(map(), String.t(), (-> map())) :: {:ok, pid()}
  def send_async(state, event, build_properties),
    do: Task.start(fn -> post(state, event, build_properties.()) end)

  @spec post(map(), String.t(), map()) :: :ok | :error
  def post(state, event, properties) do
    payload =
      Jason.encode!(%{
        api_key: @posthog_key,
        batch: [
          %{
            event: event,
            distinct_id: state.installation_id || state.session_id,
            properties:
              Map.merge(properties, %{
                "$process_person_profile" => false,
                "$lib" => "hydra-srt",
                session_id: state.session_id
              }),
            timestamp: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
          }
        ]
      })

    request = Application.get_env(:hydra_srt, :telemetry_http_request, &default_request/5)
    headers = [{"content-type", "application/json"}]
    opts = [connect_timeout_ms: :timer.seconds(2), request_timeout_ms: :timer.seconds(5)]

    case request.(:post, @posthog_host <> "/batch/", payload, headers, opts) do
      {:ok, status, _headers, _body} when status in 200..299 ->
        :ok

      other ->
        Logger.debug("HydraSRT telemetry send failed: #{inspect(other)}")
        :error
    end
  end

  @spec default_request(atom(), String.t(), binary(), list(), keyword()) :: tuple()
  def default_request(method, url, body, headers, opts) do
    :hackney.request(method, url, headers, body, [
      :with_body,
      {:connect_timeout, opts[:connect_timeout_ms]},
      {:recv_timeout, opts[:request_timeout_ms]},
      {:follow_redirect, false}
    ])
  end

  @spec build_facts() :: map()
  def build_facts do
    %{
      version: :hydra_srt |> Application.spec(:vsn) |> List.to_string(),
      distribution: distribution(),
      os: :os.type() |> elem(1),
      arch: :erlang.system_info(:system_architecture) |> List.to_string()
    }
  end

  @spec route_facts() :: map()
  def route_facts do
    routes = Repo.all(Route)
    endpoints = Repo.all(from(e in Endpoint, where: e.enabled == true))
    sources = Enum.filter(endpoints, &(&1.type == Endpoint.source_type()))
    destinations = Enum.filter(endpoints, &(&1.type == Endpoint.destination_type()))

    %{
      routes: length(routes),
      routes_active:
        Enum.count(routes, &HydraSrt.live_route_status?(&1.schema_status || &1.status)),
      sources: length(sources),
      destinations: length(destinations),
      sources_by_type: Enum.frequencies_by(sources, & &1.schema),
      destinations_by_type: Enum.frequencies_by(destinations, & &1.schema)
    }
  end

  @spec distribution() :: String.t()
  def distribution, do: System.get_env("HYDRA_DISTRIBUTION", "source")

  @spec database_dir() :: String.t()
  def database_dir, do: Path.dirname(Application.fetch_env!(:hydra_srt, HydraSrt.Repo)[:database])

  # sobelow_skip ["Traversal.FileModule"]
  @spec load_installation_id(String.t()) :: String.t() | nil
  def load_installation_id(dir) do
    path = Path.join(dir, "telemetry_id")

    with {:ok, contents} <- File.read(path),
         {:ok, id} <- Ecto.UUID.cast(String.trim(contents)) do
      id
    else
      _missing_or_invalid ->
        id = Ecto.UUID.generate()

        case File.write(path, id) do
          :ok ->
            id

          {:error, reason} ->
            Logger.warning("HydraSRT telemetry id not persisted: #{inspect(reason)}")
            nil
        end
    end
  end
end
