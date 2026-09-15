defmodule HydraSrtWeb.Telemetry.SentryTunnel do
  @moduledoc "Validates and scrubs browser Sentry envelopes before forwarding them."

  @content_type "application/x-sentry-envelope"
  @dsn_default HydraSrt.Telemetry.Config.default_sentry_dsn()

  @spec prepare(binary()) :: {:ok, map()} | {:drop, atom()}
  def prepare(body) when is_binary(body) do
    with {:ok, configured} <- normalize_dsn(@dsn_default),
         {:ok, header_line, item_lines} <- split_envelope(body),
         {:ok, header} <- decode_map(header_line),
         {:ok, envelope_dsn} <- normalize_header_dsn(header),
         true <- same_dsn?(configured, envelope_dsn),
         {:ok, items} <- parse_items(item_lines),
         {:ok, scrubbed_items} <- scrub_items(items) do
      scrubbed_body = rebuild_envelope(header, scrubbed_items)

      {:ok,
       %{
         body: scrubbed_body,
         target_url: target_url(configured),
         headers: forwarding_headers(configured.key)
       }}
    else
      false -> {:drop, :wrong_dsn}
      {:drop, reason} -> {:drop, reason}
      {:error, :unsupported_item} -> {:drop, :unsupported_item}
      {:error, _reason} -> {:drop, :malformed}
    end
  rescue
    _error -> {:drop, :malformed}
  end

  @spec normalize_dsn(binary()) :: {:ok, map()} | {:error, atom()}
  def normalize_dsn(dsn) when is_binary(dsn) do
    uri = URI.parse(String.trim(dsn))
    project_id = uri.path |> to_string() |> String.trim("/")

    if uri.scheme == "https" and is_binary(uri.host) and uri.userinfo not in [nil, ""] and
         project_id != "" and uri.query == nil and uri.fragment == nil do
      {:ok, %{host: String.downcase(uri.host), key: uri.userinfo, project_id: project_id}}
    else
      {:error, :invalid_dsn}
    end
  rescue
    _error -> {:error, :invalid_dsn}
  end

  @spec split_envelope(binary()) :: {:ok, binary(), [binary()]} | {:error, atom()}
  def split_envelope(body) do
    lines = String.split(body, "\n", trim: false)
    lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines

    case lines do
      [header | item_lines] when item_lines != [] -> {:ok, header, item_lines}
      _ -> {:error, :malformed_envelope}
    end
  end

  @spec decode_map(binary()) :: {:ok, map()} | {:error, atom()}
  def decode_map(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_json}
    end
  end

  @spec normalize_header_dsn(map()) :: {:ok, map()} | {:error, atom()}
  def normalize_header_dsn(header) do
    case header["dsn"] do
      dsn when is_binary(dsn) -> normalize_dsn(dsn)
      _ -> {:error, :missing_dsn}
    end
  end

  @spec same_dsn?(map(), map()) :: boolean()
  def same_dsn?(left, right),
    do: left.host == right.host and left.key == right.key and left.project_id == right.project_id

  @spec parse_items([binary()]) :: {:ok, [{map(), map()}]} | {:error, atom()}
  def parse_items(lines) do
    if rem(length(lines), 2) != 0 do
      {:error, :malformed_items}
    else
      lines
      |> Enum.chunk_every(2)
      |> Enum.reduce_while({:ok, []}, fn [item_header_line, payload_line], {:ok, items} ->
        with {:ok, item_header} <- decode_map(item_header_line),
             {:ok, payload} <- decode_map(payload_line),
             "event" <- item_header["type"] do
          {:cont, {:ok, [{item_header, payload} | items]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
          _unsupported -> {:halt, {:error, :unsupported_item}}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    end
  end

  @spec scrub_items([{map(), map()}]) :: {:ok, [{map(), map()}]} | {:error, atom()}
  def scrub_items(items) do
    {:ok,
     Enum.map(items, fn {headers, payload} ->
       {Map.put(headers, "type", "event") |> Map.delete("length"), scrub_event(payload)}
     end)}
  end

  @spec scrub_event(map()) :: map()
  def scrub_event(event) do
    event
    |> Map.drop(["request", "user", "contexts", "extra", "breadcrumbs", "sdkProcessingMetadata"])
    |> scrub_message()
    |> scrub_exception()
    |> scrub_logentry()
  end

  @spec scrub_message(map()) :: map()
  def scrub_message(event) do
    case event["message"] do
      message when is_binary(message) ->
        Map.put(event, "message", HydraSrt.Telemetry.Crash.scrub_text(message))

      message when is_map(message) ->
        Map.put(event, "message", scrub_logentry_map(message))

      _ ->
        event
    end
  end

  @spec scrub_exception(map()) :: map()
  def scrub_exception(event) do
    case event["exception"] do
      %{"values" => values} when is_list(values) ->
        scrubbed_values = Enum.map(values, &scrub_exception_value/1)
        put_in(event, ["exception", "values"], scrubbed_values)

      _ ->
        event
    end
  end

  @spec scrub_exception_value(term()) :: map()
  def scrub_exception_value(value) when is_map(value) do
    value
    |> Map.update("value", nil, fn text -> scrub_text_value(text) end)
    |> scrub_stacktrace()
  end

  def scrub_exception_value(_value), do: %{"value" => "Unknown application error"}

  @spec scrub_stacktrace(map()) :: map()
  def scrub_stacktrace(value) do
    case value["stacktrace"] do
      %{"frames" => frames} when is_list(frames) ->
        frames = Enum.take(frames, 30) |> Enum.map(&scrub_frame/1)
        put_in(value, ["stacktrace", "frames"], frames)

      _ ->
        value
    end
  end

  @spec scrub_frame(term()) :: map()
  def scrub_frame(frame) when is_map(frame) do
    frame
    |> Map.update("filename", nil, &scrub_filename/1)
    |> Map.update("function", nil, &scrub_text_value/1)
  end

  def scrub_frame(_frame), do: %{}

  @spec scrub_filename(term()) :: binary() | nil
  def scrub_filename(value) when is_binary(value) do
    value
    |> String.split(~r/[?#]/u, parts: 2)
    |> List.first()
    |> String.split(~r{[/\\]}u)
    |> Enum.take(-2)
    |> Enum.join("/")
    |> HydraSrt.Telemetry.Crash.scrub_text()
  end

  def scrub_filename(_value), do: nil

  @spec scrub_logentry(map()) :: map()
  def scrub_logentry(event) do
    case event["logentry"] do
      logentry when is_binary(logentry) ->
        Map.put(event, "logentry", HydraSrt.Telemetry.Crash.scrub_text(logentry))

      logentry when is_map(logentry) ->
        Map.put(event, "logentry", scrub_logentry_map(logentry))

      _ ->
        event
    end
  end

  @spec scrub_logentry_map(map()) :: map()
  def scrub_logentry_map(logentry) do
    logentry
    |> Map.update("message", nil, &scrub_text_value/1)
    |> Map.update("formatted", nil, &scrub_text_value/1)
    |> Map.put("params", [])
  end

  @spec scrub_text_value(term()) :: binary()
  def scrub_text_value(value) when is_binary(value),
    do: HydraSrt.Telemetry.Crash.scrub_text(value)

  def scrub_text_value(_value), do: ""

  @spec rebuild_envelope(map(), [{map(), map()}]) :: binary()
  def rebuild_envelope(header, items) do
    [
      Jason.encode!(header)
      | Enum.flat_map(items, fn {item_header, payload} ->
          [Jason.encode!(item_header), Jason.encode!(payload)]
        end)
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @spec target_url(map()) :: binary()
  def target_url(%{host: host, project_id: project_id}),
    do: "https://#{host}/api/#{project_id}/envelope/"

  @spec forwarding_headers(binary()) :: [{binary(), binary()}]
  def forwarding_headers(public_key) do
    [
      {"content-type", @content_type},
      {"x-sentry-auth",
       "Sentry sentry_version=7, sentry_client=hydra-srt/#{HydraSrt.Telemetry.Config.version()}, sentry_key=#{public_key}"}
    ]
  end
end
