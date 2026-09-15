defmodule HydraSrt.Telemetry.Scrubber do
  @moduledoc "The final, stricter privacy boundary for telemetry text."

  @spec scrub_text(binary()) :: binary()
  def scrub_text(text) when is_binary(text) do
    text
    |> HydraSrt.LogSanitizer.sanitize_payload()
    |> String.replace(~r/(passphrase|streamid)=([^&\s]*)/iu, "\\1=[REDACTED]")
    |> String.replace(
      ~r/(?:https?|srt|udp|rtmp|rtp|ndi|youtube):\/\/[^\s"']+/iu,
      "[REDACTED_URL]"
    )
    |> String.replace(~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/u, "[REDACTED_IP]")
    |> String.replace(
      ~r/(?<![A-Za-z0-9])(?:[0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f]{0,4}(?![A-Za-z0-9:])/u,
      "[REDACTED_IP]"
    )
    |> String.replace(
      ~r/(?:^|\s)(?:\/[A-Za-z0-9._-]+){2,}(?:\.[A-Za-z0-9._-]+)?/u,
      " [REDACTED_PATH]"
    )
    |> String.replace(
      ~r/(route(?:_name| name)?\s*[:=]\s*)[^\s,;]+/iu,
      "\\1[REDACTED_ROUTE]"
    )
    |> String.replace(
      ~r/\b[A-Za-z0-9][A-Za-z0-9_-]*\.(?:local|lan|internal|com|net|org|io|de)\b/iu,
      "[REDACTED_HOST]"
    )
  end

  @spec scrub_text(term()) :: binary()
  def scrub_text(value), do: value |> inspect(limit: 20, printable_limit: 1_024) |> scrub_text()

  @spec scrub_event(Sentry.Event.t()) :: Sentry.Event.t()
  def scrub_event(%Sentry.Event{} = event) do
    exception = Enum.map(event.exception || [], &scrub_exception/1)
    message = scrub_message(event.message)

    %Sentry.Event{
      event
      | message: message,
        exception: exception,
        request: request_context(event.request),
        user: %{},
        breadcrumbs: [],
        contexts: %{},
        tags: scrub_tags(event.tags),
        extra: scrub_extra(event.extra),
        threads: scrub_threads(event.threads),
        original_exception: nil,
        attachments: []
    }
  end

  @spec scrub_exception(Sentry.Interfaces.Exception.t()) :: Sentry.Interfaces.Exception.t()
  def scrub_exception(%Sentry.Interfaces.Exception{} = exception) do
    %Sentry.Interfaces.Exception{
      exception
      | value: scrub_text(exception.value),
        stacktrace: nil,
        mechanism: nil
    }
  end

  @spec scrub_message(Sentry.Interfaces.Message.t() | nil) :: Sentry.Interfaces.Message.t() | nil
  def scrub_message(nil), do: nil

  def scrub_message(%Sentry.Interfaces.Message{} = message) do
    %Sentry.Interfaces.Message{
      message
      | message: scrub_text(message.message || ""),
        formatted: scrub_text(message.formatted || ""),
        params: []
    }
  end

  @spec scrub_extra(map()) :: map()
  def scrub_extra(extra) when is_map(extra) do
    Map.new(extra, fn {key, value} -> {to_string(key), scrub_text(value)} end)
  end

  @spec scrub_extra(term()) :: map()
  def scrub_extra(_extra), do: %{}

  @spec scrub_tags(map()) :: map()
  def scrub_tags(tags) when is_map(tags),
    do: Map.new(tags, fn {key, value} -> {to_string(key), scrub_text(value)} end)

  def scrub_tags(_tags), do: %{}

  @spec scrub_threads(list() | nil) :: list() | nil
  def scrub_threads(nil), do: nil

  def scrub_threads(threads) when is_list(threads) do
    Enum.map(threads, fn
      %Sentry.Interfaces.Thread{stacktrace: stacktrace} = thread ->
        %Sentry.Interfaces.Thread{thread | stacktrace: scrub_stacktrace(stacktrace)}

      thread ->
        thread
    end)
  end

  def scrub_threads(_threads), do: nil

  @spec scrub_stacktrace(Sentry.Interfaces.Stacktrace.t() | nil) ::
          Sentry.Interfaces.Stacktrace.t() | nil
  def scrub_stacktrace(nil), do: nil

  def scrub_stacktrace(%Sentry.Interfaces.Stacktrace{frames: frames} = stacktrace)
      when is_list(frames) do
    %Sentry.Interfaces.Stacktrace{
      stacktrace
      | frames:
          Enum.map(frames, fn %Sentry.Interfaces.Stacktrace.Frame{} = frame ->
            %Sentry.Interfaces.Stacktrace.Frame{
              frame
              | filename: scrub_text(frame.filename || ""),
                function: scrub_text(frame.function || "")
            }
          end)
    }
  end

  def scrub_stacktrace(stacktrace), do: stacktrace

  @spec request_method(Sentry.Interfaces.Request.t() | nil) :: binary() | nil
  def request_method(%Sentry.Interfaces.Request{method: method}) when is_binary(method),
    do: method

  def request_method(_request), do: nil

  @spec request_context(Sentry.Interfaces.Request.t() | nil) :: Sentry.Interfaces.Request.t()
  def request_context(%Sentry.Interfaces.Request{} = request) do
    route = if is_map(request.data), do: request.data[:route] || request.data["route"], else: nil
    request_id = if is_map(request.env), do: request.env["REQUEST_ID"], else: nil

    %Sentry.Interfaces.Request{
      method: request_method(request),
      data: if(is_binary(route), do: %{route: scrub_text(route)}, else: %{}),
      env: if(is_binary(request_id), do: %{"REQUEST_ID" => request_id}, else: %{})
    }
  end

  def request_context(_request), do: %Sentry.Interfaces.Request{}
end
