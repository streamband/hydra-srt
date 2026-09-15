defmodule HydraSrt.Telemetry.Crash do
  @moduledoc "Best-effort, sanitized crash reporting through Sentry."

  use GenServer
  require Logger

  @name __MODULE__
  @limiter :hydra_srt_telemetry_crash_limiter
  @kinds [:panic, :fatal, :exit]
  @ui_kinds [:error, :unhandled_rejection, :renderer_crash]
  @transports [:srt, :udp, :rtmp, :rtp, :ndi, :youtube, :unknown]
  @ignored_exception_types [
    "Phoenix.Router.NoRouteError",
    "Phoenix.NotAcceptableError",
    "Plug.Conn.InvalidQueryError",
    "Plug.Parsers.BadEncodingError",
    "Plug.Parsers.ParseError",
    "Plug.Parsers.RequestTooLargeError",
    "Plug.Parsers.UnsupportedMediaTypeError",
    "Plug.Static.InvalidPathError"
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @spec report_native(map(), map()) :: :ok | {:error, term()}
  def report_native(payload, metadata) when is_map(payload) and is_map(metadata) do
    with {:ok, normalized} <- allowlisted_native_payload(payload),
         :ok <- validate_metadata(metadata) do
      if HydraSrt.Telemetry.Settings.crash_enabled?() and Process.whereis(@name) do
        GenServer.cast(@name, {:native, normalized, metadata})
      end

      :ok
    end
  rescue
    error -> {:error, error}
  end

  @spec report_ui(map(), map()) :: :ok | {:error, term()}
  def report_ui(payload, metadata) when is_map(payload) and is_map(metadata) do
    with {:ok, normalized} <- allowlisted_ui_payload(payload),
         :ok <- validate_metadata(metadata) do
      if HydraSrt.Telemetry.Settings.crash_enabled?() and Process.whereis(@name) do
        GenServer.cast(@name, {:ui, normalized, metadata})
      end

      :ok
    end
  rescue
    error -> {:error, error}
  end

  @spec report(Exception.t(), map()) :: :ok | {:error, term()}
  def report(exception, metadata) when is_exception(exception) and is_map(metadata) do
    with :ok <- validate_metadata(metadata) do
      if HydraSrt.Telemetry.Settings.crash_enabled?() and Process.whereis(@name) do
        GenServer.cast(@name, {:exception, exception, metadata})
      end

      :ok
    end
  rescue
    error -> {:error, error}
  end

  @spec report(Exception.t()) :: :ok | {:error, term()}
  def report(exception) when is_exception(exception) do
    report(exception, %{
      version: HydraSrt.Telemetry.Config.version(),
      distribution: HydraSrt.Telemetry.Config.distribution(),
      os_family: HydraSrt.Telemetry.Config.os_family(),
      arch: HydraSrt.Telemetry.Config.arch(),
      session_id: HydraSrt.Telemetry.Settings.session_id() || Ecto.UUID.generate()
    })
  end

  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t() | nil
  def before_send(%Sentry.Event{} = event) do
    if HydraSrt.Telemetry.Settings.crash_enabled?() and not ignored_event?(event) do
      sanitized = HydraSrt.Telemetry.Scrubber.scrub_event(event)

      safe_tags = %{
        "version" => HydraSrt.Telemetry.Config.version(),
        "distribution" => Atom.to_string(HydraSrt.Telemetry.Config.distribution()),
        "os_family" => Atom.to_string(HydraSrt.Telemetry.Config.os_family()),
        "arch" => Atom.to_string(HydraSrt.Telemetry.Config.arch()),
        "component" => "beam"
      }

      %Sentry.Event{sanitized | tags: safe_tags}
    else
      nil
    end
  rescue
    _error -> nil
  end

  @spec scrub_event(Sentry.Event.t()) :: Sentry.Event.t() | nil
  def scrub_event(event), do: before_send(event)

  @spec scrub_text(binary()) :: binary()
  def scrub_text(text) when is_binary(text), do: HydraSrt.Telemetry.Scrubber.scrub_text(text)

  @spec fingerprint_native(map()) :: [binary()]
  def fingerprint_native(payload) when is_map(payload) do
    ["rust", normalize_text(payload[:error_class], 256), top_frame(payload[:frames])]
  end

  @spec allowlisted_native_payload(map()) :: {:ok, map()} | {:error, term()}
  def allowlisted_native_payload(payload) when is_map(payload) do
    allowed = [
      :component,
      :kind,
      :exit_status,
      :error_class,
      :message,
      :frames,
      :gst_element,
      :source_transport,
      :destination_transports
    ]

    if Enum.all?(Map.keys(payload), &(&1 in allowed)) and payload[:component] == :rust_pipeline and
         payload[:kind] in @kinds and valid_exit_status?(payload[:exit_status]) and
         is_binary(payload[:error_class]) and is_binary(payload[:message]) and
         is_list(payload[:frames]) and
         payload[:source_transport] in @transports and is_list(payload[:destination_transports]) and
         Enum.all?(payload[:destination_transports], &(&1 in @transports)) and
         Enum.all?(payload[:frames], &valid_native_frame?/1) do
      {:ok,
       payload
       |> Map.put(:error_class, normalize_text(payload[:error_class], 256))
       |> Map.put(:message, scrub_text(String.slice(payload[:message], 0, 1_024)))
       |> Map.put(:frames, normalize_native_frames(payload[:frames]))
       |> Map.put(:gst_element, normalize_optional(payload[:gst_element], 256))}
    else
      {:error, :invalid_native_payload}
    end
  end

  @spec allowlisted_ui_payload(map()) :: {:ok, map()} | {:error, term()}
  def allowlisted_ui_payload(payload) when is_map(payload) do
    allowed = [:component, :kind, :error_class, :message, :frames]

    if Enum.all?(Map.keys(payload), &(&1 in allowed)) and payload[:component] == :web_ui and
         payload[:kind] in @ui_kinds and is_binary(payload[:error_class]) and
         is_binary(payload[:message]) and
         is_list(payload[:frames]) and Enum.all?(payload[:frames], &valid_ui_frame?/1) do
      {:ok,
       %{
         payload
         | error_class: normalize_text(payload[:error_class], 256),
           message: scrub_text(String.slice(payload[:message], 0, 1_024)),
           frames: normalize_ui_frames(payload[:frames])
       }}
    else
      {:error, :invalid_ui_payload}
    end
  end

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    :ets.new(@limiter, [:named_table, :public, :set])
    {:ok, %{session_count: 0}}
  end

  @impl true
  @spec handle_cast(
          {:native, map(), map()} | {:ui, map(), map()} | {:exception, Exception.t(), map()},
          map()
        ) :: {:noreply, map()}
  def handle_cast({kind, payload, metadata}, state) do
    fingerprint =
      case kind do
        :native -> fingerprint_native(payload)
        :ui -> ["ui", payload[:error_class]]
        :exception -> ["beam", inspect(payload.__struct__)]
      end

    payload =
      if kind == :exception do
        %{component: :beam, message: Exception.message(payload), frames: []}
      else
        payload
      end

    if allow_event?(fingerprint, state) do
      capture(payload, metadata, fingerprint)
      {:noreply, %{state | session_count: state.session_count + 1}}
    else
      {:noreply, state}
    end
  rescue
    error ->
      Logger.debug("HydraSRT telemetry crash report dropped: #{inspect(error)}")
      {:noreply, state}
  end

  @spec capture(map(), map(), [binary()]) :: :ok
  def capture(payload, metadata, fingerprint) do
    message = scrub_text(payload[:message] || payload[:error_class])

    opts = [
      result: :none,
      fingerprint: fingerprint,
      tags: %{"component" => Atom.to_string(payload[:component])},
      extra: safe_metadata(metadata),
      stacktrace: synthetic_stacktrace(payload[:frames])
    ]

    capture_fun =
      Application.get_env(:hydra_srt, :telemetry_sentry_capture, &Sentry.capture_message/2)

    _ = capture_fun.(message, opts)
    :ok
  rescue
    error ->
      Logger.debug("HydraSRT telemetry crash send failed: #{inspect(error)}")
      :ok
  end

  @spec allow_event?([binary()], map()) :: boolean()
  def allow_event?(fingerprint, state) do
    hour = div(System.system_time(:second), div(:timer.hours(1), 1_000))
    key = {fingerprint, hour}

    limit =
      Application.get_env(:hydra_srt, :telemetry, [])[:crash_max_events_per_fingerprint_hour] || 3

    count =
      case :ets.lookup(@limiter, key) do
        [{^key, existing}] -> existing
        [] -> 0
      end

    if count < limit and state.session_count < 100 do
      :ets.insert(@limiter, {key, count + 1})
      true
    else
      false
    end
  end

  @spec validate_metadata(map()) :: :ok | {:error, term()}
  def validate_metadata(metadata) do
    allowed = [:version, :distribution, :os_family, :arch, :session_id]

    valid =
      Enum.all?(Map.keys(metadata), &(&1 in allowed)) and
        is_binary(metadata[:version]) and byte_size(metadata[:version]) <= 64 and
        metadata[:distribution] in [:docker, :release, :source] and
        is_atom(metadata[:os_family]) and is_atom(metadata[:arch]) and
        HydraSrt.Telemetry.Event.valid_uuid?(metadata[:session_id])

    if valid, do: :ok, else: {:error, :invalid_metadata}
  end

  @spec valid_exit_status?(term()) :: boolean()
  def valid_exit_status?(nil), do: true
  def valid_exit_status?(value), do: is_integer(value) and value >= 0

  @spec normalize_native_frames(list()) :: list()
  def normalize_native_frames(frames) do
    frames
    |> Enum.take(20)
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn frame ->
      native_frame(
        normalize_text(frame[:crate], 256),
        normalize_text(frame[:function], 256),
        normalize_optional(frame[:file], 256),
        normalize_line(frame[:line])
      )
    end)
  end

  @spec native_frame(binary(), binary(), binary() | nil, non_neg_integer() | nil) :: map()
  def native_frame(crate, function, file, line),
    do: %{crate: crate, function: function, file: file, line: line}

  @spec normalize_ui_frames(list()) :: list()
  def normalize_ui_frames(frames) do
    frames
    |> Enum.take(20)
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn frame ->
      %{
        module: normalize_optional(frame[:module], 256),
        function: normalize_optional(frame[:function], 256),
        file: normalize_optional(frame[:file], 256),
        line: normalize_line(frame[:line])
      }
    end)
  end

  @spec valid_native_frame?(term()) :: boolean()
  def valid_native_frame?(frame) when is_map(frame) do
    Enum.all?(Map.keys(frame), &(&1 in [:crate, :function, :file, :line])) and
      is_binary(frame[:crate]) and is_binary(frame[:function]) and
      (is_nil(frame[:file]) or is_binary(frame[:file])) and valid_exit_status?(frame[:line])
  end

  def valid_native_frame?(_frame), do: false

  @spec valid_ui_frame?(term()) :: boolean()
  def valid_ui_frame?(frame) when is_map(frame) do
    Enum.all?(Map.keys(frame), &(&1 in [:module, :function, :file, :line])) and
      (is_nil(frame[:module]) or is_binary(frame[:module])) and
      (is_nil(frame[:function]) or is_binary(frame[:function])) and
      (is_nil(frame[:file]) or is_binary(frame[:file])) and valid_exit_status?(frame[:line])
  end

  def valid_ui_frame?(_frame), do: false

  @spec normalize_line(term()) :: non_neg_integer() | nil
  def normalize_line(value) when is_integer(value) and value >= 0, do: value
  def normalize_line(_value), do: nil

  @spec normalize_text(binary() | term(), non_neg_integer()) :: binary()
  def normalize_text(value, limit) when is_binary(value),
    do: value |> String.slice(0, limit) |> scrub_text()

  def normalize_text(value, _limit), do: value |> inspect(limit: 5) |> scrub_text()

  @spec normalize_optional(binary() | nil, non_neg_integer()) :: binary() | nil
  def normalize_optional(nil, _limit), do: nil
  def normalize_optional(value, limit), do: normalize_text(value, limit)

  @spec top_frame(list()) :: binary()
  def top_frame([%{crate: crate, function: function} | _]), do: "#{crate}:#{function}"
  def top_frame(_frames), do: "unknown"

  @spec safe_metadata(map()) :: map()
  def safe_metadata(metadata),
    do: Map.take(metadata, [:version, :distribution, :os_family, :arch, :session_id])

  @spec synthetic_stacktrace(list()) :: list()
  def synthetic_stacktrace(frames) when is_list(frames) do
    frames
    |> Enum.take(20)
    |> Enum.map(fn frame ->
      {__MODULE__, :native_frame, 0, line_location(frame[:line])}
    end)
    |> case do
      [] -> [{__MODULE__, :native_frame, 0, []}]
      stacktrace -> stacktrace
    end
  end

  @spec line_location(term()) :: keyword()
  def line_location(line) when is_integer(line) and line >= 0, do: [line: line]
  def line_location(_line), do: []

  @spec ignored_event?(Sentry.Event.t()) :: boolean()
  def ignored_event?(%Sentry.Event{} = event) do
    exception_type_ignored?(event) or wrapper_client_error?(event) or database_busy?(event)
  end

  @spec exception_type_ignored?(Sentry.Event.t()) :: boolean()
  def exception_type_ignored?(%Sentry.Event{exception: exceptions}) do
    Enum.any?(exceptions || [], fn exception -> exception.type in @ignored_exception_types end)
  end

  @spec wrapper_client_error?(Sentry.Event.t()) :: boolean()
  def wrapper_client_error?(%Sentry.Event{
        original_exception: %Plug.Conn.WrapperError{reason: reason}
      }),
      do: Plug.Exception.status(reason) in 400..499

  def wrapper_client_error?(_event), do: false

  @spec database_busy?(Sentry.Event.t()) :: boolean()
  def database_busy?(%Sentry.Event{exception: exceptions, message: message}) do
    values =
      (exceptions || [])
      |> Enum.map(& &1.value)
      |> Kernel.++(message_values(message))

    Enum.any?(values, fn value ->
      text = String.downcase(to_string(value || ""))

      String.contains?(text, "database is locked") or String.contains?(text, "database busy") or
        String.contains?(text, "sqlite_busy")
    end)
  end

  def message_values(%Sentry.Interfaces.Message{} = message),
    do: [message.message, message.formatted]

  def message_values(_message), do: []
end
