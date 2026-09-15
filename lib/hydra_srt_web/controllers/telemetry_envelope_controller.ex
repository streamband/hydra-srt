defmodule HydraSrtWeb.TelemetryEnvelopeController do
  use HydraSrtWeb, :controller

  require Logger

  alias HydraSrtWeb.Telemetry.EnvelopeRateLimiter
  alias HydraSrtWeb.Telemetry.SentryTunnel

  @max_body_size 200_000
  @test_env Mix.env()

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    if HydraSrt.Telemetry.Settings.crash_enabled?() do
      process_enabled(conn)
    else
      drop(conn, :disabled)
    end
  end

  @spec process_enabled(Plug.Conn.t()) :: Plug.Conn.t()
  def process_enabled(conn) do
    case read_raw_body(conn) do
      {:ok, body} -> process_body(conn, body)
      {:too_large, _body} -> drop(conn, :oversized, 413)
      {:error, _reason} -> drop(conn, :malformed)
    end
  end

  @spec read_raw_body(Plug.Conn.t()) ::
          {:ok, binary()} | {:too_large, binary()} | {:error, term()}
  def read_raw_body(%Plug.Conn{assigns: %{raw_body: body}}) when is_binary(body), do: {:ok, body}

  def read_raw_body(conn) do
    case HydraSrtWeb.Plugs.RawBodyReader.read_body(conn, length: @max_body_size) do
      {:ok, body, _conn} -> {:ok, body}
      {:more, body, _conn} -> {:too_large, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec process_body(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def process_body(conn, body) when byte_size(body) > @max_body_size,
    do: drop(conn, :oversized, 413)

  def process_body(conn, body) do
    case SentryTunnel.prepare(body) do
      {:ok, prepared} ->
        if EnvelopeRateLimiter.allow?(session_hash(conn)) do
          forward_async(prepared)
          send_resp(conn, 204, "")
        else
          drop(conn, :rate_limited, 429)
        end

      {:drop, reason} ->
        drop(conn, reason)
    end
  end

  @spec session_hash(Plug.Conn.t()) :: binary()
  def session_hash(conn) do
    token = conn |> Plug.Conn.get_req_header("authorization") |> List.first() |> to_string()
    :crypto.hash(:sha256, token)
  end

  @spec forward_async(map()) :: :ok
  def forward_async(%{target_url: target_url, headers: headers, body: body}) do
    request_fun =
      Application.get_env(
        :hydra_srt,
        :sentry_tunnel_request_fun,
        &HydraSrt.Telemetry.Http.default_request/5
      )

    task = fn -> forward(request_fun, target_url, headers, body) end

    supervisor =
      Application.get_env(
        :hydra_srt,
        :sentry_tunnel_task_supervisor,
        HydraSrt.Telemetry.TaskSupervisor
      )

    case start_forward_task(supervisor, task) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.debug("HydraSRT telemetry envelope forwarding unavailable: #{inspect(reason)}")
        :ok

      :unavailable ->
        if @test_env == :test do
          _ = Task.start(task)
        else
          Logger.debug("HydraSRT telemetry envelope forwarding unavailable")
        end

        :ok
    end
  end

  @spec start_forward_task(atom() | pid(), (-> term())) ::
          {:ok, pid()} | {:error, term()} | :unavailable
  def start_forward_task(supervisor, task) do
    available? =
      (is_atom(supervisor) and is_pid(Process.whereis(supervisor))) or
        (is_pid(supervisor) and Process.alive?(supervisor))

    if available? do
      try do
        Task.Supervisor.start_child(supervisor, task)
      catch
        :exit, reason -> {:error, reason}
      end
    else
      :unavailable
    end
  end

  @spec forward(
          (atom(), binary(), binary(), list(), keyword() -> term()),
          binary(),
          list(),
          binary()
        ) :: :ok
  def forward(request_fun, target_url, headers, body) do
    result =
      request_fun.(:post, target_url, body, headers,
        connect_timeout_ms: :timer.seconds(2),
        request_timeout_ms: :timer.seconds(5)
      )

    case result do
      {:ok, status, _response_headers, _response_body} when status in 200..299 ->
        :ok

      {:ok, status, _response_headers, _response_body} ->
        Logger.debug("HydraSRT telemetry envelope forwarding returned status=#{status}")

      {:error, _reason} ->
        Logger.debug("HydraSRT telemetry envelope forwarding failed")

      _other ->
        Logger.debug("HydraSRT telemetry envelope forwarding failed")
    end

    :ok
  rescue
    error ->
      Logger.debug("HydraSRT telemetry envelope forwarding failed: #{inspect(error.__struct__)}")
      :ok
  end

  @spec drop(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def drop(conn, reason), do: drop(conn, reason, 204)

  @spec drop(Plug.Conn.t(), atom(), non_neg_integer()) :: Plug.Conn.t()
  def drop(conn, reason, status) do
    :telemetry.execute([:hydra, :telemetry, :envelope, :dropped], %{count: 1}, %{reason: reason})
    send_resp(conn, status, "")
  end
end
