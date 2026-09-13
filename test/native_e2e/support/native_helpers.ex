defmodule HydraSrt.E2E.Native.Helpers do
  @moduledoc false

  alias HydraSrt.E2E.Native.ProcessRegistry
  alias HydraSrt.TestSupport.E2EHelpers

  @ndi_media_policies ~w(
    video_and_audio_required
    video_required_audio_optional
    video_only
    audio_only
  )

  def ensure_prereqs! do
    ensure_ffmpeg!()
    ensure_rs_native_binary_present!()
    ProcessRegistry.ensure_table!()
    :ok
  end

  def ensure_ndi_prereqs! do
    ensure_rs_native_binary_present!()
    ProcessRegistry.ensure_table!()
    :ok
  end

  def ensure_ffmpeg! do
    case System.find_executable("ffmpeg") do
      nil -> raise ExUnit.AssertionError, message: "Native E2E requires ffmpeg in PATH"
      _ -> :ok
    end
  end

  def ensure_rs_native_binary_present! do
    binary = rs_native_binary_path()

    if File.exists?(binary),
      do: :ok,
      else:
        raise(
          "native binary not found at #{binary}. Build it first with `make test_rs_native_e2e`."
        )
  end

  def rs_native_binary_path do
    Path.join([:code.priv_dir(:hydra_srt), "native", "hydra_srt_pipeline"])
  end

  @validate_config_timeout_ms 30_000

  @doc """
  Runs the native `validate-config` dry run: parse, plan and build the graph
  without starting it, so a config can be checked without media or sockets.

  Returns `{exit_status, decoded_result}`; `exit_status` is `:timeout` when the
  child never exits.
  """
  def validate_native_config(config) when is_map(config) do
    port =
      Port.open({:spawn_executable, String.to_charlist(rs_native_binary_path())}, [
        :binary,
        :exit_status,
        :stream,
        :stderr_to_stdout,
        :hide,
        args: ["validate-config"],
        env: native_port_env()
      ])

    Port.command(port, Jason.encode!(config) <> "\n")
    {status, output} = collect_validate_config(port, [])
    {status, decode_validate_config_result(output)}
  end

  defp collect_validate_config(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_validate_config(port, [data | acc])

      {^port, {:exit_status, status}} ->
        {status, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      @validate_config_timeout_ms ->
        Port.close(port)
        {:timeout, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp decode_validate_config_result(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(%{"event" => "no_result", "raw" => output}, fn line ->
      case Jason.decode(line) do
        {:ok, %{"event" => _} = result} -> result
        _ -> nil
      end
    end)
  end

  @doc """
  Port env for native E2E children: quiet GStreamer plus optional NDI runtime path.
  """
  def native_port_env do
    base = [{~c"GST_DEBUG", ~c"0"}, {~c"GST_DEBUG_NO_COLOR", ~c"1"}]

    case System.get_env("HYDRA_NDI_RUNTIME_DIR") do
      dir when is_binary(dir) and dir != "" ->
        base ++ [{~c"NDI_RUNTIME_DIR_V6", String.to_charlist(dir)}]

      _ ->
        base
    end
  end

  @doc """
  Port/System env that forces the runtime-absent branch.

  `gst-plugin-ndi` resolves libndi from `NDI_RUNTIME_DIR_V6`, then
  `NDI_RUNTIME_DIR_V5`, then the bare sonames through the platform loader
  search path, so all of the runtime dir variables have to go. The loader
  fallback cannot be cleared from here: a host that ships libndi on its default
  search path still loads it, which is why callers must confirm the child env
  really is runtime-less with `ndi_capability_status/1` instead of assuming it.
  """
  def native_port_env_without_runtime do
    [
      {~c"GST_DEBUG", ~c"0"},
      {~c"GST_DEBUG_NO_COLOR", ~c"1"},
      {~c"NDI_RUNTIME_DIR_V6", false},
      {~c"NDI_RUNTIME_DIR_V5", false},
      {~c"HYDRA_NDI_RUNTIME_DIR", false}
    ]
  end

  # Port.open/2 spells "remove this variable from the child" as `false`, while
  # System.cmd/3 spells it as `nil` and rejects anything that is not a binary.
  def system_env_from_port_env(env) do
    Enum.map(env, fn
      {k, false} -> {List.to_string(k), nil}
      {k, v} when is_list(v) -> {List.to_string(k), List.to_string(v)}
    end)
  end

  def free_srt_port!, do: E2EHelpers.tcp_free_port!()
  def free_udp_port!, do: E2EHelpers.udp_free_port!()

  def srt_to_udp_config(source_port, udp_port, opts \\ []) do
    source_uri = build_srt_uri("127.0.0.1", source_port, "listener", opts)
    route_id = Keyword.get(opts, :route_id, Ecto.UUID.generate())

    %{
      "route_id" => route_id,
      "config_revision" => "boot-" <> Ecto.UUID.generate(),
      "process_instance_id" => Ecto.UUID.generate(),
      "source" => %{
        "id" => "source_demo",
        "name" => "source_demo",
        "kind" => "srt",
        "srt" =>
          %{
            "uri" => source_uri,
            "mode" => "listener",
            "localaddress" => "127.0.0.1",
            "localport" => source_port,
            "auto_reconnect" => true,
            "keep_listening" => Keyword.get(opts, :keep_listening, true)
          }
          |> maybe_put_passphrase(opts)
      },
      "destinations" => [
        %{
          "id" => "udp_demo",
          "name" => "udp_demo",
          "kind" => "udp",
          "udp" => %{
            "address" => "127.0.0.1",
            "port" => udp_port
          }
        }
      ]
    }
  end

  @doc """
  Caller-mode SRT source route config: the native pipeline dials out to
  `srt_host:srt_port` instead of listening. Used against a real peer started
  separately with `start_gst_srt_listener!/2` - including with `no_data: true`,
  which accepts the SRT handshake but never emits media, to exercise the
  caller-mode no-data/auth-failure paths deterministically.
  """
  def srt_caller_source_config(srt_port, udp_port, opts \\ []) do
    srt_host = Keyword.get(opts, :srt_host, "127.0.0.1")
    source_uri = build_srt_uri(srt_host, srt_port, "caller", opts)
    route_id = Keyword.get(opts, :route_id, Ecto.UUID.generate())

    %{
      "route_id" => route_id,
      "config_revision" => "boot-" <> Ecto.UUID.generate(),
      "process_instance_id" => Ecto.UUID.generate(),
      "source" => %{
        "id" => "source_demo",
        "name" => "source_demo",
        "kind" => "srt",
        "srt" =>
          %{"uri" => source_uri, "mode" => "caller"}
          |> maybe_put("localaddress", Keyword.get(opts, :localaddress))
          |> maybe_put("localport", Keyword.get(opts, :localport))
          |> maybe_put_passphrase(opts)
      },
      "destinations" => [
        %{
          "id" => "udp_demo",
          "name" => "udp_demo",
          "kind" => "udp",
          "udp" => %{
            "address" => "127.0.0.1",
            "port" => udp_port
          }
        }
      ]
    }
  end

  @doc """
  Typed NDI→NDI route config (no legacy `element_type`/`props`).
  """
  def ndi_to_ndi_config(opts \\ []) do
    route_id = Keyword.get(opts, :route_id, "ndi_" <> Ecto.UUID.generate())
    media_policy = Keyword.get(opts, :media_policy, "video_and_audio_required")
    source_name = Keyword.get(opts, :source_name)
    url_address = Keyword.get(opts, :url_address)

    sender_name =
      Keyword.get(opts, :sender_name, "Hydra NDI E2E Out #{System.unique_integer([:positive])}")

    receiver_name = Keyword.get(opts, :receiver_name, "Hydra NDI E2E Recv")

    unless media_policy in @ndi_media_policies do
      raise ArgumentError, "unsupported media_policy: #{inspect(media_policy)}"
    end

    locator =
      cond do
        is_binary(source_name) and source_name != "" and is_nil(url_address) ->
          %{"source_name" => source_name, "url_address" => nil}

        is_binary(url_address) and url_address != "" and is_nil(source_name) ->
          %{"source_name" => nil, "url_address" => url_address}

        true ->
          raise ArgumentError, "exactly one of :source_name or :url_address is required"
      end

    %{
      "route_id" => route_id,
      "config_revision" => "ndi-e2e-" <> Ecto.UUID.generate(),
      "process_instance_id" => Ecto.UUID.generate(),
      "source" => %{
        "id" => Keyword.get(opts, :source_id, "ndi_source"),
        "name" => Keyword.get(opts, :source_label, "ndi_source"),
        "kind" => "ndi",
        "ndi" =>
          Map.merge(locator, %{
            "receiver_name" => receiver_name,
            "bandwidth" => Keyword.get(opts, :bandwidth, "highest"),
            "color_format" => Keyword.get(opts, :color_format, "uyvy-bgra"),
            "timestamp_mode" => Keyword.get(opts, :timestamp_mode, "receive-time-vs-timestamp"),
            "media_policy" => media_policy,
            "connect_timeout_ms" => Keyword.get(opts, :connect_timeout_ms, 10_000),
            "receive_timeout_ms" => Keyword.get(opts, :receive_timeout_ms, 5_000),
            "track_discovery_timeout_ms" =>
              Keyword.get(opts, :track_discovery_timeout_ms, 10_000),
            "max_queue_length" => Keyword.get(opts, :max_queue_length, 4)
          })
      },
      "destinations" => [
        %{
          "id" => Keyword.get(opts, :dest_id, "ndi_dest"),
          "name" => Keyword.get(opts, :dest_label, "ndi_dest"),
          "kind" => "ndi",
          "ndi" => %{
            "sender_name" => sender_name,
            "media_policy" => media_policy
          }
        }
      ]
    }
  end

  @doc """
  Probe stdin payload: a single typed NDI source endpoint.
  """
  def ndi_probe_input(opts \\ []) do
    source_name = Keyword.get(opts, :source_name, "Absent NDI Source")
    url_address = Keyword.get(opts, :url_address)
    media_policy = Keyword.get(opts, :media_policy, "video_only")

    locator =
      cond do
        is_binary(url_address) and url_address != "" ->
          %{"source_name" => nil, "url_address" => url_address}

        true ->
          %{"source_name" => source_name, "url_address" => nil}
      end

    %{
      "source" => %{
        "id" => Keyword.get(opts, :source_id, "ndi_probe_source"),
        "name" => "ndi_probe_source",
        "kind" => "ndi",
        "ndi" =>
          Map.merge(locator, %{
            "receiver_name" => Keyword.get(opts, :receiver_name, "Hydra NDI Probe"),
            "bandwidth" => "highest",
            "color_format" => "uyvy-bgra",
            "timestamp_mode" => "receive-time-vs-timestamp",
            "media_policy" => media_policy,
            "connect_timeout_ms" => Keyword.get(opts, :connect_timeout_ms, 2_000),
            "receive_timeout_ms" => Keyword.get(opts, :receive_timeout_ms, 2_000),
            "track_discovery_timeout_ms" => Keyword.get(opts, :track_discovery_timeout_ms, 2_000),
            "max_queue_length" => 4
          })
      }
    }
  end

  @doc """
  True when `HYDRA_NDI_RUNTIME_DIR` points at a directory with a loadable libndi.
  """
  def ndi_runtime_available? do
    case System.get_env("HYDRA_NDI_RUNTIME_DIR") do
      dir when is_binary(dir) and dir != "" ->
        File.dir?(dir) and libndi_present?(dir)

      _ ->
        false
    end
  end

  def libndi_present?(dir) when is_binary(dir) do
    patterns = [
      "libndi.so.6",
      "libndi.so",
      "libndi.dylib",
      "libndi*.dylib",
      "Processing.NDI.Lib*.dylib"
    ]

    Enum.any?(patterns, fn pattern ->
      Path.wildcard(Path.join(dir, pattern)) != []
    end)
  end

  @doc """
  Runs `ndi-discovery` with stdin closed; returns `{exit_status, decoded_json_events}`.
  """
  def run_ndi_discovery!(opts \\ []) do
    helper_id = Keyword.get(opts, :helper_instance_id, Ecto.UUID.generate())
    timeout_ms = Keyword.get(opts, :timeout_ms, 15_000)
    env = Keyword.get(opts, :env, native_port_env())

    run_helper_collect!(
      ["ndi-discovery", "--helper-instance-id", helper_id],
      "",
      env,
      timeout_ms,
      close_stdin?: false
    )
  end

  @doc """
  Runs `ndi-probe` with one JSON line on stdin; returns `{exit_status, decoded_json_events}`.
  """
  def run_ndi_probe!(input, opts \\ []) when is_map(input) do
    probe_id = Keyword.get(opts, :probe_instance_id, Ecto.UUID.generate())
    timeout_ms = Keyword.get(opts, :timeout_ms, 20_000)
    env = Keyword.get(opts, :env, native_port_env())

    run_helper_collect!(
      ["ndi-probe", "--probe-instance-id", probe_id],
      Jason.encode!(input) <> "\n",
      env,
      timeout_ms,
      close_stdin?: false
    )
  end

  @doc """
  Classifies NDI capability via a one-shot discovery run.

  Pass `:env` to classify the capability of a specific child environment rather
  than the suite default.

  Returns `{:plugin_missing | :runtime_missing | :available, events}`.
  """
  def ndi_capability_status(opts \\ []) do
    {_status, events} =
      run_ndi_discovery!(Keyword.merge([timeout_ms: 10_000], opts))

    cond do
      Enum.any?(
        events,
        &match?(%{"event" => "ndi_capability", "reason_code" => "NDI_PLUGIN_MISSING"}, &1)
      ) ->
        {:plugin_missing, events}

      Enum.any?(
        events,
        &match?(%{"event" => "ndi_capability", "reason_code" => "NDI_RUNTIME_MISSING"}, &1)
      ) ->
        {:runtime_missing, events}

      Enum.any?(events, &match?(%{"event" => "ndi_device_snapshot"}, &1)) ->
        {:available, events}

      true ->
        {:plugin_missing, events}
    end
  end

  @doc """
  Starts an upstream `gst-launch-1.0` NDI sender fixture. Returns
  `%{port, os_pid, tag, name, log_path}`.

  The sender's stdout+stderr are redirected to `log_path` (not left to pile up
  unread in this process's mailbox), and the process is verified alive after a
  short settle window: a sender that dies immediately raises here, with its
  captured output, instead of silently masquerading as a discovery timeout
  30-120s later.
  """
  def start_gst_ndi_sender!(opts \\ []) do
    name = Keyword.get(opts, :name, "Hydra CI Source #{System.unique_integer([:positive])}")
    media_policy = Keyword.get(opts, :media_policy, "video_and_audio_required")
    duration_s = Keyword.get(opts, :duration_s, 30)
    tag = "gst_ndi_sender_#{System.unique_integer([:positive])}"

    pipeline =
      case media_policy do
        "video_and_audio_required" ->
          [
            "ndisinkcombiner",
            "name=c",
            "!",
            "ndisink",
            "ndi-name=#{name}",
            "videotestsrc",
            "is-live=true",
            "num-buffers=#{duration_s * 30}",
            "!",
            "video/x-raw,format=UYVY,width=640,height=360,framerate=30/1",
            "!",
            "c.video",
            "audiotestsrc",
            "is-live=true",
            "num-buffers=#{duration_s * 50}",
            "!",
            "audio/x-raw,format=F32LE,rate=48000,channels=2",
            "!",
            "c.audio"
          ]

        "video_only" ->
          [
            "videotestsrc",
            "is-live=true",
            "num-buffers=#{duration_s * 30}",
            "!",
            "video/x-raw,format=UYVY,width=640,height=360,framerate=30/1",
            "!",
            "ndisink",
            "ndi-name=#{name}"
          ]

        "audio_only" ->
          [
            "audiotestsrc",
            "is-live=true",
            "num-buffers=#{duration_s * 50}",
            "!",
            "audio/x-raw,format=F32LE,rate=48000,channels=2",
            "!",
            "ndisink",
            "ndi-name=#{name}"
          ]

        other ->
          raise ArgumentError, "unsupported sender media_policy: #{inspect(other)}"
      end

    case System.find_executable("gst-launch-1.0") do
      nil ->
        raise ExUnit.AssertionError, message: "gst-launch-1.0 required for NDI sender fixtures"

      gst_launch ->
        log_path = Path.join(System.tmp_dir!(), "hydra_ndi_sender_#{tag}.log")

        # Route through a shell so stdout+stderr can be redirected to a file we
        # can read back later. Port.open/2 already runs this as `sh -c "exec ..."`,
        # so the shell is replaced by gst-launch-1.0 and Port.info(:os_pid) (plus
        # stop_os_process!/ProcessRegistry) still target it rather than a wrapper
        # shell. Prepending another `exec` here would make sh look for a binary
        # literally named "exec".
        shell_cmd =
          Enum.map_join([gst_launch | pipeline], " ", &shell_escape/1) <>
            " > " <> shell_escape(log_path) <> " 2>&1"

        port =
          Port.open(
            {:spawn, shell_cmd},
            [
              :binary,
              :exit_status,
              :stream,
              :hide,
              env: native_port_env()
            ]
          )

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} when is_integer(pid) -> pid
            _ -> nil
          end

        :ok =
          ProcessRegistry.register!(make_ref(), %{
            kind: :gst_ndi_sender,
            tag: tag,
            os_pid: os_pid,
            port: port
          })

        sender = %{port: port, os_pid: os_pid, tag: tag, name: name, log_path: log_path}

        # Settle, then verify the process didn't die on the spot (bad args,
        # missing plugin, NDI runtime load failure, etc). Never let that be
        # indistinguishable from "discovery didn't see it".
        Process.sleep(1_000)

        unless sender_alive?(sender) do
          raise ExUnit.AssertionError,
            message: """
            NDI sender fixture #{inspect(name)} (tag=#{tag}) exited immediately \
            after launch (os_pid=#{inspect(os_pid)}). It cannot be discovered \
            because it is not running.

            --- captured sender output (#{log_path}) ---
            #{read_sender_output(sender)}
            """
        end

        sender
    end
  end

  @doc """
  True when a sender fixture's OS process is still running.
  """
  def sender_alive?(%{os_pid: os_pid}) when is_integer(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      {_out, _} -> false
    end
  end

  def sender_alive?(_), do: false

  @doc """
  Reads back a sender fixture's captured stdout+stderr.
  """
  def read_sender_output(%{log_path: log_path}) when is_binary(log_path) do
    case File.read(log_path) do
      {:ok, content} when content != "" -> content
      {:ok, ""} -> "(empty: sender produced no output)"
      {:error, reason} -> "(no output captured: #{log_path} unreadable: #{inspect(reason)})"
    end
  end

  def read_sender_output(_), do: "(sender fixture has no captured log path)"

  def stop_os_process!(%{os_pid: os_pid, port: port}) when is_integer(os_pid) do
    if Port.info(port) != nil, do: Port.close(port)
    _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  def stop_os_process!(_), do: :ok

  @doc """
  Asserts proprietary NDI artifacts are absent from the repository checkout.
  """
  def assert_no_prohibited_ndi_artifacts!(root \\ File.cwd!()) do
    patterns = [
      "**/libndi.so*",
      "**/libndi.dylib*",
      "**/Processing.NDI.Lib*",
      "**/Install_NDI_SDK*",
      "**/NDI SDK*",
      "**/*NDI*Tools*",
      "**/NDILib*"
    ]

    hits =
      patterns
      |> Enum.flat_map(fn pattern ->
        Path.wildcard(Path.join(root, pattern))
      end)
      |> Enum.reject(fn path ->
        String.contains?(path, "/.fleet/") or
          String.contains?(path, "/refs/") or
          String.contains?(path, "/docs/") or
          String.ends_with?(path, ".md") or
          String.ends_with?(path, ".exs") or
          String.ends_with?(path, ".ex") or
          String.ends_with?(path, ".yml")
      end)

    if hits != [] do
      raise ExUnit.AssertionError,
        message: "prohibited NDI artifacts present in checkout: #{inspect(hits)}"
    end

    :ok
  end

  def wait_until(fun, timeout_ms, interval_ms \\ 50) do
    E2EHelpers.wait_until(fun, timeout_ms, interval_ms)
  end

  @doc """
  Returns diagnostics for the most recent `run_helper_collect!` call made by
  this process: `%{args:, exit_status:, timed_out?:, raw:}`. Scoped to the
  calling process (the ExUnit test process), via the process dictionary, so
  concurrent tests never see each other's output.
  """
  def last_helper_output do
    Process.get(:hydra_ndi_last_helper_output, %{
      args: nil,
      exit_status: nil,
      timed_out?: nil,
      raw: "(no helper invocation recorded yet)"
    })
  end

  def run_helper_collect!(args, stdin_payload, env, timeout_ms, opts \\ []) do
    binary = rs_native_binary_path()
    env_strings = system_env_from_port_env(env)
    # Whether the helper should observe stdin EOF as soon as the payload is
    # consumed (discovery: no input expected) vs kept open a beat longer.
    close_stdin? = Keyword.get(opts, :close_stdin?, true)

    stdin_path =
      Path.join(System.tmp_dir!(), "hydra_ndi_stdin_#{System.unique_integer([:positive])}")

    stdout_path =
      Path.join(System.tmp_dir!(), "hydra_ndi_stdout_#{System.unique_integer([:positive])}")

    File.write!(stdin_path, stdin_payload)

    cmd_str = Enum.map_join([binary | args], " ", &shell_escape/1)

    # Output is redirected to a file (not captured only via System.cmd's
    # return value) so that if the Task has to be brutally killed on timeout,
    # whatever the helper had already written is still readable afterward —
    # a hung helper must be diagnosable, not silently discarded.
    redirect_out = " > " <> shell_escape(stdout_path) <> " 2>&1"

    # `ndi-probe` reads one stdin line synchronously and exits on its own, so EOF
    # timing is irrelevant to it and a plain redirect is right.
    #
    # `ndi-discovery` quits its glib MainLoop the moment stdin reaches EOF. With a
    # plain `< file` redirect that is instantaneous, so it reports only whatever
    # `monitor.devices()` happened to hold at t=0 and exits before the NDI device
    # provider has finished a discovery cycle and posted its DeviceAdded messages.
    # Holding stdin open for a bounded window (a POSIX pipe — `sh` here is dash,
    # which has no process substitution) gives the provider time to report, while
    # the eventual EOF still stops the helper inside the collection timeout.
    shell =
      if close_stdin? do
        cmd_str <> " < " <> shell_escape(stdin_path) <> redirect_out
      else
        window_s = Float.round(max(timeout_ms - 1_000, 500) / 1_000, 1)

        "( cat " <>
          shell_escape(stdin_path) <>
          "; sleep " <> to_string(window_s) <> " ) | " <> cmd_str <> redirect_out
      end

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", shell], env: env_strings)
      end)

    {exit_status, timed_out?} =
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {_output, status}} -> {status, false}
        {:ok, _other} -> {-1, false}
        nil -> {-1, true}
      end

    raw_output =
      case File.read(stdout_path) do
        {:ok, content} -> content
        {:error, _} -> ""
      end

    events =
      raw_output
      |> String.split("\n", trim: true)
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(line) do
          {:ok, map} when is_map(map) -> [map | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    Process.put(:hydra_ndi_last_helper_output, %{
      args: args,
      exit_status: exit_status,
      timed_out?: timed_out?,
      raw: raw_output
    })

    _ = File.rm(stdin_path)
    _ = File.rm(stdout_path)
    {exit_status, events}
  end

  def shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  def start_ffmpeg_sender!(source_port, opts \\ []) do
    passphrase = Keyword.get(opts, :passphrase)
    pbkeylen = Keyword.get(opts, :pbkeylen, 16)
    duration = Keyword.get(opts, :duration, 20)

    srt_url =
      if is_binary(passphrase) do
        "srt://127.0.0.1:#{source_port}?mode=caller&streamid=test1&passphrase=#{passphrase}&pbkeylen=#{pbkeylen}"
      else
        stream_id_query =
          case Keyword.get(opts, :streamid) do
            value when is_binary(value) and value != "" -> "&streamid=#{value}"
            _ -> ""
          end

        "srt://127.0.0.1:#{source_port}?mode=caller&pkt_size=1316#{stream_id_query}"
      end

    tag = "ffmpeg_rs_native_#{System.unique_integer([:positive])}"

    proc =
      E2EHelpers.start_port_logged!(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-re",
          "-f",
          "lavfi",
          "-i",
          "testsrc2=size=1280x720:rate=30",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=48000",
          "-t",
          Integer.to_string(duration),
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
          srt_url
        ],
        tag
      )

    :ok =
      ProcessRegistry.register!(make_ref(), %{
        kind: :ffmpeg_sender,
        tag: tag,
        os_pid: proc.os_pid,
        port: proc.port
      })

    proc
  end

  @doc """
  Starts a real `gst-launch-1.0` SRT listener fixture: a live encoded audio test
  tone served over `srtsink` in listener mode on `port`, optionally protected by
  a passphrase. Used to be the "far side" peer for tests that exercise a native
  route's SRT *caller*-mode source against a real SRT connection, without depending
  on a second copy of the pipeline under test.

  Audio-only (not video): this fixture only has to prove out a valid MPEG-TS
  byte stream reaching `srtsrc` - the source/destination adapters and the health
  monitors below key off buffer/byte arrival, never codec or media kind, and
  `avenc_aac` is far cheaper than an H.264 encode on a CI runner (it also drops
  the `gstreamer1.0-plugins-ugly` dependency that `x264enc` needed).

  Pass `no_data: true` to keep the listener accepting SRT connections while never
  emitting any media: a `valve` sits right after the test source with
  `drop-mode=forward-sticky-events`, so caps/segment/stream-start still reach
  `srtsink` (letting it start and listen normally - the pipeline is still `is-live`,
  so it reaches PLAYING without waiting on preroll data) while every buffer is
  dropped before it gets there. This is the peer for tests that need a caller's SRT
  handshake to genuinely complete with zero data ever arriving - the "connected, but
  no media has ever arrived" case the no-data health monitor exists for - without
  depending on OS-level socket/ICMP behaviour, which differs between Linux and macOS
  for a port nothing is listening on at all and so cannot be used to make that case
  deterministic.

  Pass `data_after_ms: n` instead to keep the *same connection* alive the whole
  time but start sending real media only after `n` milliseconds of wall-clock
  silence: a `concat` feeds `srtsink` from two `audiotestsrc` branches requested
  in order - the first is gated by the same drop-all `valve` as `no_data: true`
  and capped at the number of `is-live` buffers that take `n` milliseconds to
  produce, the second is a plain, ungated `audiotestsrc`. `concat` only moves on
  to its next requested pad once the current one reports EOS, so the first branch
  running out of buffers is what flips the switch - no bus watch, timer, or
  external property toggle touches the pipeline after launch. This is the peer
  for tests that need one still-connected caller to observe silence and then
  real throughput in sequence (e.g. recovering from `SRT_NO_DATA_SINCE_START`
  once its already-connected peer starts sending), as opposed to `no_data: true`
  or a dropped/replaced connection.

  `no_data: true` and `data_after_ms` are mutually exclusive.

  Returns `%{port, os_pid, log_path}`; verified alive after a short settle window,
  the same way `start_gst_ndi_sender!/1` is - a listener that fails to bind (e.g. the
  port is already taken) must not be indistinguishable from "the caller just hasn't
  connected yet".
  """
  @srt_listener_rate 48_000
  # 480 samples @ 48kHz = exactly 10ms/buffer, so ms-to-buffer-count math below is exact.
  @srt_listener_samples_per_buffer 480
  @srt_listener_ms_per_buffer div(@srt_listener_samples_per_buffer * 1000, @srt_listener_rate)
  @srt_listener_caps "audio/x-raw,rate=#{@srt_listener_rate},channels=2"
  @srt_listener_source [
    "audiotestsrc",
    "is-live=true",
    "samplesperbuffer=#{@srt_listener_samples_per_buffer}"
  ]

  def start_gst_srt_listener!(srt_port, opts \\ []) do
    passphrase = Keyword.get(opts, :passphrase)
    pbkeylen = Keyword.get(opts, :pbkeylen, 16)
    no_data? = Keyword.get(opts, :no_data, false)
    data_after_ms = Keyword.get(opts, :data_after_ms)
    tag = "gst_srt_listener_#{System.unique_integer([:positive])}"

    if no_data? and data_after_ms do
      raise ArgumentError, "no_data: true and data_after_ms are mutually exclusive"
    end

    uri_query =
      if is_binary(passphrase) do
        "mode=listener&passphrase=#{passphrase}&pbkeylen=#{pbkeylen}"
      else
        "mode=listener"
      end

    encode_and_send = [
      "!",
      "avenc_aac",
      "!",
      "aacparse",
      "!",
      "mpegtsmux",
      "!",
      "srtsink",
      "uri=srt://0.0.0.0:#{srt_port}?#{uri_query}",
      "wait-for-connection=false"
    ]

    pipeline =
      cond do
        data_after_ms ->
          # `n` milliseconds of `is-live` buffers, rounded up so the gated branch
          # never runs *short* of the requested silence window.
          gated_buffers =
            div(data_after_ms + @srt_listener_ms_per_buffer - 1, @srt_listener_ms_per_buffer)

          [
            "concat",
            "name=c",
            "!",
            @srt_listener_caps
          ] ++
            encode_and_send ++
            @srt_listener_source ++
            [
              "num-buffers=#{gated_buffers}",
              "!",
              "valve",
              "drop=true",
              "drop-mode=forward-sticky-events",
              "!",
              @srt_listener_caps,
              "!",
              "c."
            ] ++
            @srt_listener_source ++
            [
              "!",
              @srt_listener_caps,
              "!",
              "c."
            ]

        no_data? ->
          @srt_listener_source ++
            [
              "!",
              "valve",
              "drop=true",
              "drop-mode=forward-sticky-events",
              "!",
              @srt_listener_caps
            ] ++ encode_and_send

        true ->
          @srt_listener_source ++
            [
              "!",
              @srt_listener_caps
            ] ++ encode_and_send
      end

    case System.find_executable("gst-launch-1.0") do
      nil ->
        raise ExUnit.AssertionError, message: "gst-launch-1.0 required for SRT listener fixtures"

      gst_launch ->
        log_path = Path.join(System.tmp_dir!(), "hydra_srt_listener_#{tag}.log")

        shell_cmd =
          Enum.map_join([gst_launch, "-q" | pipeline], " ", &shell_escape/1) <>
            " > " <> shell_escape(log_path) <> " 2>&1"

        port =
          Port.open(
            {:spawn, shell_cmd},
            [:binary, :exit_status, :stream, :hide, env: native_port_env()]
          )

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} when is_integer(pid) -> pid
            _ -> nil
          end

        :ok =
          ProcessRegistry.register!(make_ref(), %{
            kind: :gst_srt_listener,
            tag: tag,
            os_pid: os_pid,
            port: port
          })

        fixture = %{port: port, os_pid: os_pid, tag: tag, log_path: log_path}

        Process.sleep(500)

        unless sender_alive?(fixture) do
          raise ExUnit.AssertionError,
            message: """
            SRT listener fixture on port #{srt_port} (tag=#{tag}) exited immediately \
            after launch (os_pid=#{inspect(os_pid)}).

            --- captured listener output (#{log_path}) ---
            #{read_sender_output(fixture)}
            """
        end

        fixture
    end
  end

  defp build_srt_uri(host, port, mode, opts) do
    query =
      [{"mode", mode}]
      |> maybe_add_query("passphrase", Keyword.get(opts, :passphrase))
      |> maybe_add_query("pbkeylen", Keyword.get(opts, :pbkeylen))
      |> URI.encode_query()

    "srt://#{host}:#{port}?#{query}"
  end

  defp maybe_add_query(items, _key, nil), do: items
  defp maybe_add_query(items, _key, ""), do: items
  defp maybe_add_query(items, key, value), do: [{key, value} | items]

  defp maybe_put_passphrase(config, opts) do
    config
    |> maybe_put("passphrase", Keyword.get(opts, :passphrase))
    |> maybe_put("pbkeylen", Keyword.get(opts, :pbkeylen))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
