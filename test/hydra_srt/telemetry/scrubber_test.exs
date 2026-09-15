defmodule HydraSrt.Telemetry.ScrubberTest do
  use ExUnit.Case, async: true

  alias HydraSrt.Telemetry.Scrubber

  test "removes URLs, addresses, hosts, credentials, and paths" do
    input =
      "srt://host:9000?passphrase=secret&streamid=secret https://example.com/path 192.0.2.10 10.0.0.4 operator-hostname.local /Users/operator/project/route.json"

    output = Scrubber.scrub_text(input)

    refute output =~ "secret"
    refute output =~ "https://"
    refute output =~ "srt://"
    refute output =~ "192.0.2.10"
    refute output =~ "10.0.0.4"
    refute output =~ "operator-hostname.local"
    refute output =~ "/Users/operator"
  end

  test "scrubs the documented URI, IPv4, IPv6, path, and route-name cases" do
    output =
      Scrubber.scrub_text(
        "srt://host:9000?passphrase=abc&streamid=x rtmp://a.b/live/KEY " <>
          "8.8.8.8:1234 192.168.1.10 [2001:db8::1]:9000 ::1 " <>
          "/Users/foo/project /app/releases/current passphrase=free-text route_name=secret-route"
      )

    refute output =~ "srt://host:9000"
    refute output =~ "rtmp://a.b/live/KEY"
    refute output =~ "8.8.8.8"
    refute output =~ "192.168.1.10"
    refute output =~ "2001:db8::1"
    refute output =~ "::1"
    refute output =~ "/Users/foo"
    refute output =~ "/app/releases"
    refute output =~ "passphrase=free-text"
    refute output =~ "secret-route"
  end

  test "scrubs route names and poisoned fields in Sentry events" do
    event = %Sentry.Event{
      event_id: String.duplicate("a", 32),
      timestamp: "2026-09-15T00:00:00Z",
      message: %Sentry.Interfaces.Message{
        message: "route_name=secret srt://host:9000?passphrase=abc",
        formatted: "8.8.8.8 /Users/foo"
      },
      tags: %{"route" => "rtmp://a.b/live/KEY"},
      extra: %{context: "passphrase=abc"}
    }

    scrubbed = Scrubber.scrub_event(event)
    refute inspect(scrubbed) =~ "secret"
    refute inspect(scrubbed) =~ "srt://"
    refute inspect(scrubbed) =~ "8.8.8.8"
    refute inspect(scrubbed) =~ "passphrase=abc"
  end
end
