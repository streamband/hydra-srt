defmodule HydraSrt.TestSupport.E2EHelpers do
  @moduledoc false

  require Logger

  @default_host "127.0.0.1"
  @default_port 4002

  @doc false
  def e2e_timeout_ms(ms) when is_integer(ms) and ms > 0 do
    if System.get_env("CI") == "true" do
      # GitHub-hosted runners are often CPU-starved; libx264 + SRT handshakes exceed laptop timings.
      cond do
        ms >= 8_000 -> min(ms * 4, 120_000)
        ms >= 3_000 -> min(ms * 4, 90_000)
        true -> min(ms * 3, 25_000)
      end
    else
      ms
    end
  end

  @doc false
  def e2e_startup_sleep_ms do
    if System.get_env("CI") == "true", do: 2_000, else: 750
  end

  @doc false
  # The RTMP proxy chain (SRT -> parsebin -> flvmux -> rtmpsink -> publish) has a
  # variable warm-up latency (mpegts demux, first keyframe at g=60, flvmux aggregator
  # waiting for buffers on every pad). The source must keep streaming for the whole
  # ffprobe probe window, otherwise the publisher may never come up and the play side
  # times out forever. Keep this comfortably above `await_rtmp_av_streams/2` timeouts.
  def e2e_ffmpeg_stream_duration_sec do
    if System.get_env("CI") == "true", do: 150, else: 45
  end

  @doc false
  def ffmpeg_srt_test_pattern_args(source_port, opts \\ []) when is_integer(source_port) do
    duration_sec = Keyword.get(opts, :duration_sec, e2e_ffmpeg_stream_duration_sec())
    # On CI, -re throttles to wall clock: slow runners can spend the whole -t budget
    # before the RTMP remux branch connects, so ffprobe never sees a live stream.
    realtime? = Keyword.get(opts, :realtime, System.get_env("CI") != "true")

    [
      "-hide_banner",
      "-loglevel",
      "error"
    ] ++
      if(realtime?, do: ["-re"], else: []) ++
      [
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=1280x720:rate=30",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:sample_rate=48000",
        "-t",
        Integer.to_string(duration_sec),
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-tune",
        "zerolatency",
        "-pix_fmt",
        "yuv420p",
        "-g",
        "60",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-ar",
        "48000",
        "-ac",
        "2",
        "-f",
        "mpegts",
        "srt://127.0.0.1:#{source_port}?mode=caller"
      ]
  end

  def ensure_e2e_prereqs! do
    kill_all_pipelines!()
    ensure_executables!()
    ensure_native_built!()
    ensure_api_auth_config!()
    ensure_repo_config_for_e2e!()
    ensure_repo_migrated_for_e2e!()
    ensure_app_started!()
    ensure_cachex_started!()
    ensure_endpoint_server_started!()
    :ok
  end

  def ensure_e2e_mcp_prereqs! do
    kill_all_pipelines!()
    ensure_native_built!()
    ensure_api_auth_config!()
    ensure_repo_config_for_e2e!()
    ensure_repo_migrated_for_e2e!()
    ensure_app_started!()
    ensure_cachex_started!()
    ensure_endpoint_server_started!()
    :ok
  end

  def ensure_app_started! do
    if is_pid(Process.whereis(HydraSrt.Supervisor)) and not repo_started_with_e2e_config?() do
      :ok = Application.stop(:hydra_srt)
    end

    case Application.ensure_all_started(:hydra_srt) do
      {:ok, _} -> :ok
      {:error, {:already_started, :hydra_srt}} -> :ok
      other -> raise "Failed to start :hydra_srt application for E2E: #{inspect(other)}"
    end
  end

  def ensure_executables! do
    for exe <- ["ffmpeg", "srt-live-transmit", "lsof"] do
      case System.find_executable(exe) do
        nil -> raise ExUnit.AssertionError, message: "E2E requires #{exe} in PATH"
        _path -> :ok
      end
    end

    :ok
  end

  @spec pipeline_udp_sockets!() :: [%{os_pid: integer(), address: String.t(), port: integer()}]
  def pipeline_udp_sockets! do
    case System.find_executable("lsof") do
      nil -> raise "E2E pipeline UDP socket inspection requires lsof in PATH"
      _path -> :ok
    end

    # Linux truncates the command name to 15 characters and lsof -c matches by
    # prefix, so the short form finds the pipeline on both Linux and macOS.
    # -w drops the stat warnings lsof prints on Linux CI runners, and stderr
    # stays separate so nothing but the socket table reaches the parser.
    {output, status} = System.cmd("lsof", ["-w", "-nP", "-iUDP", "-a", "-c", "hydra_srt_pipel"])

    cond do
      status == 1 and String.trim(output) == "" ->
        []

      status != 0 ->
        raise "lsof UDP socket inspection failed with status #{status}: #{String.trim(output)}"

      String.trim(output) == "" ->
        []

      true ->
        [_header | lines] = String.split(output, "\n", trim: true)
        Enum.map(lines, &parse_lsof_udp_line/1)
    end
  end

  @spec parse_lsof_udp_line(String.t()) :: %{
          os_pid: integer(),
          address: String.t(),
          port: integer()
        }
  def parse_lsof_udp_line(line) when is_binary(line) do
    columns = String.split(String.trim(line))

    case columns do
      [_, pid | _] when length(columns) >= 9 ->
        name = List.last(columns)

        with {os_pid, ""} <- Integer.parse(pid),
             [_, address, port_text] <- Regex.run(~r/\A(\*|\[[^\]]+\]|[^\s:]+):([0-9]+)\z/, name),
             {port, ""} <- Integer.parse(port_text) do
          %{os_pid: os_pid, address: address, port: port}
        else
          _ -> raise "Unable to parse lsof UDP line: #{inspect(line)}"
        end

      _ ->
        raise "Unable to parse lsof UDP line: #{inspect(line)}"
    end
  end

  def ensure_ffprobe_executable! do
    case System.find_executable("ffprobe") do
      nil ->
        raise ExUnit.AssertionError, message: "E2E RTMP tests require ffprobe in PATH"

      _path ->
        :ok
    end
  end

  def rtmp_port do
    Application.fetch_env!(:hydra_srt, :rtmp_port)
  end

  def rtmp_play_url(path) when is_binary(path) do
    normalized_path =
      if String.starts_with?(path, "/"), do: path, else: "/#{path}"

    "rtmp://127.0.0.1:#{rtmp_port()}#{normalized_path}"
  end

  def ffprobe_streams(url, timeout_ms \\ 3_500, opts \\ []) when is_binary(url) do
    scale_timeout? = Keyword.get(opts, :scale_timeout, true)

    effective_timeout_ms =
      if scale_timeout? do
        e2e_timeout_ms(timeout_ms)
      else
        timeout_ms
      end

    with {:ok, raw} <-
           HydraSrt.SourceProbe.run_ffprobe(:ffprobe, url, effective_timeout_ms),
         {:ok, decoded} <- HydraSrt.SourceProbe.decode_output(raw) do
      {:ok, Map.get(decoded, "streams", [])}
    end
  end

  def rtmp_streams_include_av?(streams) when is_list(streams) do
    has_video =
      Enum.any?(streams, fn stream ->
        stream["codec_type"] == "video" and stream["codec_name"] in ["h264", "hevc"]
      end)

    has_audio =
      Enum.any?(streams, fn stream ->
        stream["codec_type"] == "audio" and stream["codec_name"] == "aac"
      end)

    has_video and has_audio
  end

  def await_rtmp_av_streams(url, opts \\ []) when is_binary(url) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 25_000)
    interval_ms = Keyword.get(opts, :interval_ms, 750)
    probe_timeout_ms = Keyword.get(opts, :probe_timeout_ms, 3_500)

    # The per-probe timeout has to scale with the environment like every other
    # wait here. Pinning it while the surrounding budget scales means a runner
    # slow enough to need the larger budget cannot finish an RTMP handshake and
    # stream detection inside a single probe, so every attempt times out and the
    # extra budget buys nothing.
    wait_until(
      fn ->
        case ffprobe_streams(url, probe_timeout_ms) do
          {:ok, streams} -> rtmp_streams_include_av?(streams)
          _ -> false
        end
      end,
      timeout_ms,
      interval_ms
    )

    case ffprobe_streams(url, probe_timeout_ms) do
      {:ok, streams} ->
        if rtmp_streams_include_av?(streams) do
          {:ok, %{streams: streams}}
        else
          {:error, {:missing_av_streams, streams}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    RuntimeError -> {:error, :timeout}
  end

  def ffmpeg_supports_srt_encryption? do
    # Some ffmpeg/libsrt builds accept the passphrase options syntactically but
    # fail only when an encrypted connection is actually attempted.
    #
    # Probe by doing a tiny loopback transfer over SRT with passphrase enabled.
    # If either side exits non-zero, we consider encryption unsupported.
    port = tcp_free_port!()
    sink_file = tmp_file!("ffmpeg_enc_probe_sink", "ts")

    rx =
      start_port!(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-y",
          "-i",
          "srt://127.0.0.1:#{port}?mode=listener&passphrase=probe_pass&pbkeylen=16",
          "-t",
          "1",
          "-c",
          "copy",
          "-f",
          "mpegts",
          sink_file
        ]
      )

    # Give listener a moment to bind.
    Process.sleep(250)

    tx =
      start_port!(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-re",
          "-f",
          "lavfi",
          "-i",
          "testsrc2=size=320x240:rate=15",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=48000",
          "-t",
          "1",
          "-c:v",
          "libx264",
          "-preset",
          "veryfast",
          "-tune",
          "zerolatency",
          "-pix_fmt",
          "yuv420p",
          "-g",
          "30",
          "-c:a",
          "aac",
          "-b:a",
          "96k",
          "-ar",
          "48000",
          "-ac",
          "2",
          "-f",
          "mpegts",
          "srt://127.0.0.1:#{port}?mode=caller&passphrase=probe_pass&pbkeylen=16"
        ]
      )

    tx_status = await_exit_status!(tx, 15_000)
    rx_status = await_exit_status!(rx, 15_000)

    if is_integer(tx_status) and tx_status != 0, do: kill_port(tx)
    if is_integer(rx_status) and rx_status != 0, do: kill_port(rx)

    tx_status == 0 and rx_status == 0
  end

  def ensure_native_built! do
    binary = Path.join([:code.priv_dir(:hydra_srt), "native", "hydra_srt_pipeline"])

    if File.exists?(binary),
      do: :ok,
      else: raise("Native binary not found at #{binary} after build")
  end

  def ensure_api_auth_config! do
    Application.put_env(:hydra_srt, :api_auth_username, "admin")
    Application.put_env(:hydra_srt, :api_auth_password, "password123")
    :ok
  end

  def ensure_cachex_started! do
    # In `HydraSrt.Application` Cachex is started only for distributed nodes.
    # E2E tests run on `:nonode@nohost`, but API auth still depends on `HydraSrt.Cache`.
    case Process.whereis(HydraSrt.Cache) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case Cachex.start_link(name: HydraSrt.Cache) do
          {:ok, _pid} -> :ok
          {:already_started, _pid} -> :ok
          other -> raise "Failed to start Cachex for E2E: #{inspect(other)}"
        end
    end
  end

  defp repo_started_with_e2e_config? do
    repo_pid = Process.whereis(HydraSrt.Repo)

    if is_pid(repo_pid) do
      repo_config = HydraSrt.Repo.config()
      expected_db_path = System.get_env("E2E_DATABASE_PATH")

      repo_config[:pool] == DBConnection.ConnectionPool and
        repo_config[:database] == expected_db_path
    else
      false
    end
  end

  def ensure_repo_config_for_e2e! do
    db_path =
      System.get_env("E2E_DATABASE_PATH") ||
        Application.get_env(:hydra_srt, HydraSrt.Repo, [])
        |> Keyword.get(:database) ||
        Path.join(System.tmp_dir!(), "hydra_srt_e2e_#{System.unique_integer([:positive])}.db")

    System.put_env("E2E_DATABASE_PATH", db_path)

    current = Application.get_env(:hydra_srt, HydraSrt.Repo, [])

    updated =
      current
      |> Keyword.put(:database, db_path)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 5)
      |> Keyword.put(:journal_mode, :wal)
      |> Keyword.put(:busy_timeout, 15_000)

    Application.put_env(:hydra_srt, HydraSrt.Repo, updated)

    :ok
  end

  def ensure_repo_migrated_for_e2e! do
    migrations_path = Application.app_dir(:hydra_srt, "priv/repo/migrations")

    Ecto.Migrator.with_repo(HydraSrt.Repo, fn repo ->
      _ = Ecto.Migrator.run(repo, migrations_path, :up, all: true)
    end)

    :ok
  end

  def kill_all_pipelines! do
    pipelines = HydraSrt.ProcessMonitor.list_pipeline_processes()

    Enum.each(pipelines, fn %{pid: pid} ->
      System.cmd("kill", ["-9", Integer.to_string(pid)])
    end)

    # Best-effort sweep in case ps parsing missed anything.
    System.cmd("pkill", ["-9", "-f", "hydra_srt_pipeline"])

    :ok
  end

  def ensure_endpoint_server_started! do
    current = Application.get_env(:hydra_srt, HydraSrtWeb.Endpoint, [])
    updated = Keyword.put(current, :server, true)
    Application.put_env(:hydra_srt, HydraSrtWeb.Endpoint, updated)

    pid = Process.whereis(HydraSrtWeb.Endpoint)

    if is_pid(pid) do
      # Restart endpoint so it picks up server=true and boots Cowboy listener.
      # We must use the supervision tree to restart it properly.
      Supervisor.terminate_child(HydraSrt.Supervisor, HydraSrtWeb.Endpoint)
      {:ok, _} = Supervisor.restart_child(HydraSrt.Supervisor, HydraSrtWeb.Endpoint)
    end

    wait_until(fn -> is_pid(Process.whereis(HydraSrtWeb.Endpoint)) end, 5_000, 50)
    wait_for_healthcheck!(base_url(), 10_000)
    :ok
  end

  def base_url do
    host = System.get_env("E2E_HOST", @default_host)
    port = System.get_env("E2E_PORT", "#{@default_port}") |> String.to_integer()
    "http://#{host}:#{port}"
  end

  def wait_for_healthcheck!(base_url, timeout_ms) do
    wait_until(
      fn ->
        case http_raw(:get, base_url <> "/health/", [], "") do
          {:ok, 200, _headers, _body} -> true
          _ -> false
        end
      end,
      timeout_ms,
      100
    )

    :ok
  end

  def api_login!(base_url, user, password) do
    body = Jason.encode!(%{"login" => %{"user" => user, "password" => password}})

    {:ok, 200, _headers, resp} =
      http_raw(:post, base_url <> "/api/login", [{"content-type", "application/json"}], body)

    token = Jason.decode!(resp) |> Map.fetch!("token")
    token
  end

  def api_create_route!(base_url, token, route_params) when is_map(route_params) do
    # API schema defaults routes to disabled; E2E expects an active pipeline unless a test opts out.
    route_params = Map.put_new(route_params, "enabled", true)

    schema = Map.get(route_params, "schema")

    route_for_post =
      route_params
      |> Map.drop(["schema"])

    body = Jason.encode!(%{"route" => route_for_post})

    {:ok, 201, _headers, resp} =
      http_raw(:post, base_url <> "/api/routes", auth_headers(token), body)

    route_id = Jason.decode!(resp) |> get_in(["data", "id"])

    if is_binary(schema) and schema != "" do
      source =
        %{
          "enabled" => true,
          "name" => Map.get(route_params, "source_name", "Primary"),
          "schema" => schema,
          "mode" => Map.get(route_params, "mode"),
          "interface_sys_name" => Map.get(route_params, "interface_sys_name"),
          "localaddress" => Map.get(route_params, "localaddress"),
          "localport" => Map.get(route_params, "localport"),
          "address" => Map.get(route_params, "address"),
          "port" => Map.get(route_params, "port"),
          "host" => Map.get(route_params, "host"),
          "latency" => Map.get(route_params, "latency"),
          "authentication" => Map.get(route_params, "authentication"),
          "passphrase" => Map.get(route_params, "passphrase"),
          "pbkeylen" => Map.get(route_params, "pbkeylen"),
          "poll_timeout" => Map.get(route_params, "poll_timeout"),
          "auto_reconnect" => Map.get(route_params, "auto_reconnect"),
          "keep_listening" => Map.get(route_params, "keep_listening"),
          "bind_address_option" => Map.get(route_params, "bind_address_option"),
          "position" => 0
        }
        |> Map.merge(
          route_params
          |> Map.take(["multicast", "multicast_iface"])
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()
        )

      _ = api_create_source!(base_url, token, route_id, source)
    end

    route_id
  end

  def api_create_source!(base_url, token, route_id, source_params) when is_map(source_params) do
    source_params =
      source_params
      |> Map.put_new("enabled", true)
      |> then(fn m ->
        if Map.has_key?(m, "position"), do: m, else: Map.put(m, "position", 0)
      end)

    body = Jason.encode!(%{"source" => source_params})

    {:ok, 201, _headers, resp} =
      http_raw(
        :post,
        base_url <> "/api/routes/#{route_id}/sources",
        auth_headers(token),
        body
      )

    Jason.decode!(resp) |> get_in(["data", "id"])
  end

  def api_create_destination!(base_url, token, route_id, dest_params) when is_map(dest_params) do
    # Destinations default to disabled; the native pipeline only loads enabled sinks.
    dest_params = Map.put_new(dest_params, "enabled", true)

    body = Jason.encode!(%{"destination" => dest_params})

    {:ok, 201, _headers, _resp} =
      http_raw(
        :post,
        base_url <> "/api/routes/#{route_id}/destinations",
        auth_headers(token),
        body
      )

    :ok
  end

  def api_create_interface!(base_url, token, interface_params) when is_map(interface_params) do
    interface_params = Map.put_new(interface_params, "enabled", true)

    body = Jason.encode!(%{"interface" => interface_params})

    {:ok, 201, _headers, resp} =
      http_raw(:post, base_url <> "/api/interfaces", auth_headers(token), body)

    Jason.decode!(resp) |> get_in(["data", "id"])
  end

  def api_delete_interface(base_url, token, interface_id)
      when is_binary(base_url) and is_binary(token) and is_binary(interface_id) do
    http_raw(:delete, base_url <> "/api/interfaces/#{interface_id}", auth_headers(token), "")
  end

  def api_start_route!(base_url, token, route_id) do
    {:ok, 200, _headers, _resp} =
      http_raw(:get, base_url <> "/api/routes/#{route_id}/start", auth_headers(token), "")

    :ok
  end

  def api_get_route!(base_url, token, route_id) do
    {:ok, 200, _headers, resp} =
      http_raw(:get, base_url <> "/api/routes/#{route_id}", auth_headers(token), "")

    Jason.decode!(resp) |> get_in(["data"])
  end

  def api_get_route(base_url, token, route_id) do
    case http_raw(:get, base_url <> "/api/routes/#{route_id}", auth_headers(token), "") do
      {:ok, 200, _headers, resp} ->
        {:ok, Jason.decode!(resp) |> get_in(["data"])}

      {:ok, status, _headers, resp} ->
        {:error, {status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def wait_for_route_processing!(base_url, token, route_id, opts \\ [])
      when is_binary(base_url) and is_binary(token) and is_binary(route_id) do
    expected_dest_count = Keyword.get(opts, :expected_destination_count)
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    interval_ms = Keyword.get(opts, :interval_ms, 250)

    wait_until(
      fn ->
        case api_get_route(base_url, token, route_id) do
          {:ok, route} ->
            schema_ok = route["schema_status"] == "processing"
            dests = Map.get(route, "destinations") || []

            dest_ok =
              cond do
                is_integer(expected_dest_count) ->
                  length(dests) == expected_dest_count and
                    Enum.all?(dests, fn d -> d["status"] == "processing" end)

                true ->
                  dests != [] and
                    Enum.all?(dests, fn d -> d["status"] == "processing" end)
              end

            schema_ok and dest_ok

          _ ->
            false
        end
      end,
      timeout_ms,
      interval_ms
    )
  end

  def api_stop_route(base_url, token, route_id) do
    http_raw(:get, base_url <> "/api/routes/#{route_id}/stop", auth_headers(token), "")
  end

  def api_delete_route(base_url, token, route_id) do
    http_raw(:delete, base_url <> "/api/routes/#{route_id}", auth_headers(token), "")
  end

  def auth_headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"content-type", "application/json"}
    ]
  end

  def http_raw(method, url, headers, body) do
    :inets.start()
    :ssl.start()

    request =
      case method do
        :get -> {String.to_charlist(url), headers_to_charlist(headers)}
        :delete -> {String.to_charlist(url), headers_to_charlist(headers)}
        _ -> {String.to_charlist(url), headers_to_charlist(headers), ~c"application/json", body}
      end

    opts = [timeout: 20_000, connect_timeout: 5_000]

    case :httpc.request(method, request, opts, body_format: :binary) do
      {:ok, {{_http, status, _reason}, resp_headers, resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:ok, {{_http, status}, resp_headers, resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def headers_to_charlist(headers) do
    Enum.map(headers, fn {k, v} ->
      {String.to_charlist(k), String.to_charlist(v)}
    end)
  end

  def udp_free_port! do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_udp.close(socket)
    port
  end

  def tcp_free_port! do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  def tmp_file!(prefix, ext) do
    name = "#{prefix}_#{System.unique_integer([:positive])}.#{ext}"
    Path.join(System.tmp_dir!(), name)
  end

  def start_port!(exe, args) when is_binary(exe) and is_list(args) do
    exec = System.find_executable(exe) || raise "Executable not found: #{exe}"

    port =
      Port.open({:spawn_executable, String.to_charlist(exec)}, [
        :binary,
        :exit_status,
        :stream,
        :stderr_to_stdout,
        :hide,
        args: args
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _ -> nil
      end

    %{port: port, os_pid: os_pid, exe: exe, args: args}
  end

  def start_port_logged!(exe, args, tag) when is_binary(tag) do
    owner = self()
    proc = start_port!(exe, args)
    logger_pid = spawn_link(__MODULE__, :port_log_loop, [proc.port, tag, owner])
    true = Port.connect(proc.port, logger_pid)
    Map.put(proc, :tag, tag)
  end

  def port_log_loop(port, tag, owner) when is_port(port) and is_binary(tag) and is_pid(owner) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        String.split(data, "\n")
        |> Enum.each(fn line ->
          if line != "" do
            maybe_emit_srt_stats(tag, line, owner)
            maybe_log_e2e_port_line(tag, line)
          end
        end)

        port_log_loop(port, tag, owner)

      {^port, {:exit_status, status}} ->
        maybe_log_e2e_port_exit_status(tag, status)
        send(owner, {:port_exit_status, tag, status})
        :ok

      {:EXIT, ^port, reason} ->
        maybe_log_e2e_port_exit_reason(tag, reason)
        send(owner, {:port_exit_status, tag, reason})
        :ok
    end
  end

  def maybe_emit_srt_stats(tag, line, owner)
      when is_binary(tag) and is_binary(line) and is_pid(owner) do
    # srt-live-transmit default stats (varies by srt-tools version / locale), e.g.:
    # "PACKETS     SENT:           0  RECEIVED:          1053"
    if String.contains?(tag, "srt-live-transmit") and Regex.match?(~r/(?i)received:\s*\d+/, line) do
      case Regex.run(~r/(?i)received:\s*(\d+)/, line) do
        [_, received_str] ->
          case Integer.parse(received_str) do
            {received, _} ->
              send(owner, {:srt_packets_received, received})

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  defp maybe_log_e2e_port_line(tag, line) do
    if e2e_port_logs_enabled?() do
      Logger.warning("#{tag}: #{line}")
    end
  end

  defp maybe_log_e2e_port_exit_status(_tag, 0), do: :ok

  defp maybe_log_e2e_port_exit_status(tag, status) do
    Logger.warning("#{tag}: exit_status=#{status}")
  end

  defp maybe_log_e2e_port_exit_reason(_tag, :normal), do: :ok

  defp maybe_log_e2e_port_exit_reason(tag, reason) do
    Logger.warning("#{tag}: port_exit=#{inspect(reason)}")
  end

  defp e2e_port_logs_enabled? do
    System.get_env("E2E_DEBUG_LOGS") == "true"
  end

  def await_srt_packets_received(min_packets, timeout_ms)
      when is_integer(min_packets) and is_integer(timeout_ms) do
    start = System.monotonic_time(:millisecond)
    do_await_srt_packets_received(min_packets, start, e2e_timeout_ms(timeout_ms))
  end

  def do_await_srt_packets_received(min_packets, start_ms, timeout_ms) do
    remaining = timeout_ms - (System.monotonic_time(:millisecond) - start_ms)

    if remaining <= 0 do
      nil
    else
      receive do
        {:srt_packets_received, received} when received >= min_packets ->
          received

        {:srt_packets_received, _received} ->
          do_await_srt_packets_received(min_packets, start_ms, timeout_ms)
      after
        min(250, remaining) ->
          do_await_srt_packets_received(min_packets, start_ms, timeout_ms)
      end
    end
  end

  @doc false
  def await_tag_exit_status(tag, timeout_ms) when is_binary(tag) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + subprocess_exit_wait_ms(timeout_ms)
    do_await_tag_exit_status(tag, deadline)
  end

  # Bounded subprocess (e.g. ffmpeg `-t`); avoid `e2e_timeout_ms/1` so one wait stays within ExUnit defaults.
  defp subprocess_exit_wait_ms(requested_ms) when is_integer(requested_ms) and requested_ms > 0 do
    if System.get_env("CI") == "true" do
      # Small slack for CPU-starved runners; keep total under typical ExUnit 60s budgets.
      requested_ms + 12_000
    else
      requested_ms
    end
  end

  defp do_await_tag_exit_status(tag, deadline_ms) do
    receive do
      {:port_exit_status, ^tag, status} ->
        status
    after
      200 ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          nil
        else
          do_await_tag_exit_status(tag, deadline_ms)
        end
    end
  end

  def await_exit_status!(%{port: port}, timeout_ms)
      when is_port(port) and is_integer(timeout_ms) do
    effective_ms = e2e_timeout_ms(timeout_ms)

    receive do
      {^port, {:exit_status, status}} -> status
    after
      effective_ms -> nil
    end
  end

  def kill_port(%{port: port} = proc) when is_port(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _ -> proc.os_pid
      end

    if is_integer(os_pid) and process_alive?(os_pid) do
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    :ok
  end

  def process_alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  def start_udp_counter!(port) when is_integer(port) do
    {:ok, sock} = :gen_udp.open(port, [:binary, active: true, ip: {0, 0, 0, 0}])
    parent = self()
    pid = spawn_link(__MODULE__, :udp_counter_loop, [sock, 0, parent])
    :ok = :gen_udp.controlling_process(sock, pid)
    %{pid: pid, sock: sock, port: port}
  end

  def start_multicast_udp_counter!(group_ip, iface_ip, port)
      when is_binary(group_ip) and is_binary(iface_ip) and is_integer(port) do
    group_tuple = ipv4_tuple!(group_ip)
    iface_tuple = ipv4_tuple!(iface_ip)

    {:ok, sock} =
      :gen_udp.open(port, [
        :binary,
        active: true,
        reuseaddr: true,
        ip: {0, 0, 0, 0},
        add_membership: {group_tuple, iface_tuple}
      ])

    parent = self()
    pid = spawn_link(__MODULE__, :udp_counter_loop, [sock, 0, parent])
    :ok = :gen_udp.controlling_process(sock, pid)
    %{pid: pid, sock: sock, port: port, group_ip: group_ip, iface_ip: iface_ip}
  end

  def send_udp_burst!(host_ip, port, opts \\ [])
      when is_binary(host_ip) and is_integer(port) and is_list(opts) do
    packet_count = Keyword.get(opts, :packet_count, 250)
    packet_size = Keyword.get(opts, :packet_size, 1316)
    payload = :binary.copy(<<0x47>>, packet_size)

    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    host_tuple = ipv4_tuple!(host_ip)

    Enum.each(1..packet_count, fn _ ->
      :ok = :gen_udp.send(sock, host_tuple, port, payload)
    end)

    :ok = :gen_udp.close(sock)
    :ok
  end

  @doc """
  Feeds the source with repeated UDP bursts until stopped.

  `send_udp_burst!/3` writes its whole burst in one unthrottled loop, so the
  receiver's socket buffer absorbs it or drops it: UDP applies no flow control
  and nothing is retransmitted. A single burst therefore delivers however much
  the pipeline happened to be ready for, which on a loaded runner can sit below
  an assertion's byte threshold with no way to recover -- the burst is over in
  milliseconds, so waiting longer never helps. Repeating the burst on an
  interval keeps the source producing for as long as the assertion waits.
  """
  def start_udp_burst_feeder!(host_ip, port, opts \\ [])
      when is_binary(host_ip) and is_integer(port) and is_list(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, 200)
    burst_opts = Keyword.delete(opts, :interval_ms)
    pid = spawn_link(fn -> udp_burst_feeder_loop(host_ip, port, burst_opts, interval_ms) end)
    %{pid: pid}
  end

  def udp_burst_feeder_loop(host_ip, port, burst_opts, interval_ms) do
    :ok = send_udp_burst!(host_ip, port, burst_opts)

    receive do
      :stop -> :ok
    after
      interval_ms -> udp_burst_feeder_loop(host_ip, port, burst_opts, interval_ms)
    end
  end

  def stop_udp_burst_feeder!(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
    :ok
  end

  def send_multicast_udp_burst!(group_ip, port, iface_ip, opts \\ [])
      when is_binary(group_ip) and is_integer(port) and is_binary(iface_ip) and is_list(opts) do
    packet_count = Keyword.get(opts, :packet_count, 250)
    packet_size = Keyword.get(opts, :packet_size, 1316)
    payload = :binary.copy(<<0x47>>, packet_size)
    group_tuple = ipv4_tuple!(group_ip)
    iface_tuple = ipv4_tuple!(iface_ip)

    {:ok, sock} =
      :gen_udp.open(0, [
        :binary,
        active: false,
        multicast_if: iface_tuple,
        multicast_ttl: 1,
        multicast_loop: true
      ])

    Enum.each(1..packet_count, fn _ ->
      :ok = :gen_udp.send(sock, group_tuple, port, payload)
    end)

    :ok = :gen_udp.close(sock)
    :ok
  end

  def udp_counter_loop(sock, bytes, parent) do
    receive do
      {:udp, ^sock, _ip, _port, data} when is_binary(data) ->
        udp_counter_loop(sock, bytes + byte_size(data), parent)

      {:get_bytes, from} when is_pid(from) ->
        send(from, {:udp_bytes, bytes})
        udp_counter_loop(sock, bytes, parent)

      :stop ->
        :gen_udp.close(sock)
        send(parent, {:udp_bytes_final, bytes})
        :ok
    after
      30_000 ->
        :gen_udp.close(sock)
        send(parent, {:udp_bytes_final, bytes})
        :ok
    end
  end

  def get_udp_bytes!(%{pid: pid}) when is_pid(pid) do
    send(pid, {:get_bytes, self()})

    receive do
      {:udp_bytes, bytes} -> bytes
    after
      1_000 -> 0
    end
  end

  def await_udp_bytes(counter, min_bytes, timeout_ms)
      when is_map(counter) and is_integer(min_bytes) and is_integer(timeout_ms) do
    wait_until(fn -> get_udp_bytes!(counter) >= min_bytes end, timeout_ms, 50)
    {:ok, %{bytes: get_udp_bytes!(counter)}}
  rescue
    RuntimeError -> {:error, %{bytes: get_udp_bytes!(counter)}}
  end

  def stop_udp_counter!(%{pid: pid} = counter) when is_pid(pid) do
    send(pid, :stop)

    receive do
      {:udp_bytes_final, bytes} ->
        Map.put(counter, :bytes, bytes)
    after
      2_000 ->
        Map.put(counter, :bytes, 0)
    end
  end

  def local_multicast_roundtrip_supported?(iface_ip) when is_binary(iface_ip) do
    group_ip = "239.255.20.20"
    port = udp_free_port!()
    counter = start_multicast_udp_counter!(group_ip, iface_ip, port)

    result =
      try do
        :ok =
          send_multicast_udp_burst!(group_ip, port, iface_ip, packet_count: 32, packet_size: 188)

        match?({:ok, %{bytes: bytes}} when bytes > 0, await_udp_bytes(counter, 188, 2_000))
      rescue
        _ -> false
      catch
        _, _ -> false
      end

    stop_udp_counter!(counter)
    result
  end

  def discover_ipv4_system_interface!(opts \\ []) do
    prefer_non_loopback? = Keyword.get(opts, :prefer_non_loopback, true)
    prefer_loopback? = Keyword.get(opts, :prefer_loopback, false)
    require_multicast? = Keyword.get(opts, :require_multicast, true)

    {:ok, interfaces} = HydraSrt.SystemInterfaces.discover()

    ipv4_interfaces =
      interfaces
      |> Enum.filter(fn interface ->
        ip = Map.get(interface, "ip", "")
        is_binary(ip) and ip != "-" and String.contains?(ip, ".")
      end)
      |> Enum.map(fn interface ->
        bind_ip = strip_cidr_suffix(Map.fetch!(interface, "ip"))

        Map.merge(interface, %{
          "bind_ip" => bind_ip,
          "is_loopback" => loopback_ip?(bind_ip)
        })
      end)

    selected =
      ipv4_interfaces
      |> maybe_filter_multicast(require_multicast?)
      |> maybe_sort_loopback_first(prefer_loopback?)
      |> maybe_sort_non_loopback_first(prefer_non_loopback?)
      |> List.first()

    selected ||
      raise "No suitable IPv4 system interface found. interfaces=#{inspect(ipv4_interfaces)}"
  end

  def strip_cidr_suffix(ip) when is_binary(ip) do
    ip
    |> String.split("/", parts: 2)
    |> List.first()
  end

  def ipv4_tuple!(ip) when is_binary(ip) do
    ip
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
    |> case do
      {a, b, c, d} -> {a, b, c, d}
      _ -> raise "Invalid IPv4 address: #{inspect(ip)}"
    end
  end

  defp maybe_filter_multicast(interfaces, false), do: interfaces

  defp maybe_filter_multicast(interfaces, true) do
    filtered = Enum.filter(interfaces, &(&1["multicast_supported"] == true))
    if filtered == [], do: interfaces, else: filtered
  end

  defp maybe_sort_non_loopback_first(interfaces, false), do: interfaces

  defp maybe_sort_non_loopback_first(interfaces, true) do
    Enum.sort_by(interfaces, fn interface -> interface["is_loopback"] == true end)
  end

  defp maybe_sort_loopback_first(interfaces, false), do: interfaces

  defp maybe_sort_loopback_first(interfaces, true) do
    Enum.sort_by(interfaces, fn interface -> interface["is_loopback"] == false end)
  end

  defp loopback_ip?(ip) when is_binary(ip) do
    String.starts_with?(ip, "127.")
  end

  def wait_until(fun, timeout_ms, interval_ms) when is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    effective_ms = e2e_timeout_ms(timeout_ms)
    do_wait_until(fun, start, effective_ms, interval_ms)
  end

  def do_wait_until(fun, start_ms, timeout_ms, interval_ms) do
    if fun.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now - start_ms > timeout_ms do
        raise "Timeout after #{timeout_ms}ms"
      else
        Process.sleep(interval_ms)
        do_wait_until(fun, start_ms, timeout_ms, interval_ms)
      end
    end
  end

  def wait_for_file_size!(path, min_bytes, timeout_ms) do
    wait_until(
      fn ->
        case File.stat(path) do
          {:ok, stat} -> stat.size >= min_bytes
          _ -> false
        end
      end,
      timeout_ms,
      100
    )
  end

  def file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end
end
