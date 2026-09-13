defmodule HydraSrt.E2E.SrtCallerInterfaceBindE2ETest do
  use ExUnit.Case, async: false

  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :e2e

  setup_all do
    E2EHelpers.ensure_e2e_prereqs!()
    {:ok, base_url: E2EHelpers.base_url()}
  end

  test "SRT caller source bound to the selected interface", %{base_url: base_url} do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    interface = %{
      "sys_name" => "e2e_loopback_srt_caller_source",
      "ip" => "127.0.0.1/8",
      "bind_ip" => "127.0.0.1"
    }

    interface_id = create_interface_record!(base_url, token, interface)

    source_port = E2EHelpers.udp_free_port!()
    source_udp_port = E2EHelpers.udp_free_port!()
    udp_dest_port = E2EHelpers.udp_free_port!()
    udp_counter = E2EHelpers.start_udp_counter!(udp_dest_port)

    on_exit(fn ->
      E2EHelpers.stop_udp_counter!(udp_counter)
      E2EHelpers.api_delete_interface(base_url, token, interface_id)
    end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_srt_caller_source_interface_bind",
        "schema" => "SRT",
        "mode" => "caller",
        "address" => interface["bind_ip"],
        "port" => source_port,
        "interface_sys_name" => interface["sys_name"]
      })

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "UDP",
        "name" => "udp_srt_caller_source_interface_bind",
        "host" => "127.0.0.1",
        "port" => udp_dest_port
      })

    source_peer =
      start_udp_to_srt_listener!("srt-caller-source-peer", source_udp_port, source_port)

    on_exit(fn -> E2EHelpers.kill_port(source_peer) end)

    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())
    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    sender = start_ffmpeg_udp_sender!("ffmpeg-srt-caller-source", source_udp_port)
    on_exit(fn -> E2EHelpers.kill_port(sender) end)

    E2EHelpers.wait_for_route_processing!(base_url, token, route_id,
      expected_destination_count: 1
    )

    assert {:ok, %{bytes: bytes}} = E2EHelpers.await_udp_bytes(udp_counter, 20_000, 20_000)
    assert bytes >= 20_000

    await_pipeline_udp_sockets!(
      fn sockets ->
        one_pipeline? = sockets |> Enum.map(& &1.os_pid) |> Enum.uniq() |> length() == 1

        one_pipeline? and
          Enum.any?(sockets, &(&1.address == interface["bind_ip"] and &1.port > 0))
      end,
      "expected the SRT caller source socket to bind to the selected interface"
    )
  end

  test "SRT caller destination bound to the selected interface", %{base_url: base_url} do
    token = E2EHelpers.api_login!(base_url, "admin", "password123")

    interface = %{
      "sys_name" => "e2e_loopback_srt_caller_destination",
      "ip" => "127.0.0.1/8",
      "bind_ip" => "127.0.0.1"
    }

    interface_id = create_interface_record!(base_url, token, interface)

    source_port = E2EHelpers.udp_free_port!()
    source_udp_port = E2EHelpers.udp_free_port!()
    destination_port = E2EHelpers.udp_free_port!()
    udp_dest_port = E2EHelpers.udp_free_port!()
    udp_counter = E2EHelpers.start_udp_counter!(udp_dest_port)

    on_exit(fn ->
      E2EHelpers.stop_udp_counter!(udp_counter)
      E2EHelpers.api_delete_interface(base_url, token, interface_id)
    end)

    route_id =
      E2EHelpers.api_create_route!(base_url, token, %{
        "name" => "e2e_srt_caller_destination_interface_bind",
        "schema" => "SRT",
        "mode" => "listener",
        "localaddress" => "127.0.0.1",
        "localport" => source_port
      })

    on_exit(fn ->
      E2EHelpers.api_stop_route(base_url, token, route_id)
      E2EHelpers.api_delete_route(base_url, token, route_id)
    end)

    :ok =
      E2EHelpers.api_create_destination!(base_url, token, route_id, %{
        "schema" => "SRT",
        "name" => "srt_caller_destination_interface_bind",
        "mode" => "caller",
        "address" => interface["bind_ip"],
        "port" => destination_port,
        "interface_sys_name" => interface["sys_name"]
      })

    destination_peer =
      start_srt_to_udp_listener!("srt-caller-destination-peer", destination_port, udp_dest_port)

    on_exit(fn -> E2EHelpers.kill_port(destination_peer) end)

    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())
    :ok = E2EHelpers.api_start_route!(base_url, token, route_id)
    Process.sleep(E2EHelpers.e2e_startup_sleep_ms())

    # The route source is the listener here, so its peer has to dial in.
    source_peer =
      start_udp_to_srt_caller!("srt-caller-destination-source-peer", source_udp_port, source_port)

    sender = start_ffmpeg_udp_sender!("ffmpeg-srt-caller-destination", source_udp_port)

    on_exit(fn ->
      E2EHelpers.kill_port(sender)
      E2EHelpers.kill_port(source_peer)
    end)

    E2EHelpers.wait_for_route_processing!(base_url, token, route_id,
      expected_destination_count: 1
    )

    assert {:ok, %{bytes: bytes}} = E2EHelpers.await_udp_bytes(udp_counter, 20_000, 20_000)
    assert bytes >= 20_000

    # The listener source already sits on bind_ip:source_port, so the caller
    # destination has to show up as a second socket on that address.
    await_pipeline_udp_sockets!(
      fn sockets ->
        one_pipeline? = sockets |> Enum.map(& &1.os_pid) |> Enum.uniq() |> length() == 1

        one_pipeline? and
          Enum.any?(sockets, fn socket ->
            socket.address == interface["bind_ip"] and socket.port > 0 and
              socket.port != source_port
          end)
      end,
      "expected the SRT caller destination socket to bind to the selected interface"
    )
  end

  @spec create_interface_record!(String.t(), String.t(), map()) :: String.t()
  def create_interface_record!(base_url, token, interface) do
    E2EHelpers.api_create_interface!(base_url, token, %{
      "name" => "#{interface["sys_name"]}-record",
      "sys_name" => interface["sys_name"],
      "ip" => interface["ip"]
    })
  end

  @spec start_udp_to_srt_listener!(String.t(), integer(), integer()) :: map()
  def start_udp_to_srt_listener!(tag, udp_port, srt_port) do
    E2EHelpers.start_port_logged!(
      "srt-live-transmit",
      [
        "-v",
        "-stats",
        "1000",
        "-statspf",
        "default",
        "udp://127.0.0.1:#{udp_port}",
        "srt://127.0.0.1:#{srt_port}?mode=listener"
      ],
      tag
    )
  end

  @spec start_udp_to_srt_caller!(String.t(), integer(), integer()) :: map()
  def start_udp_to_srt_caller!(tag, udp_port, srt_port) do
    E2EHelpers.start_port_logged!(
      "srt-live-transmit",
      [
        "-v",
        "-stats",
        "1000",
        "-statspf",
        "default",
        "udp://127.0.0.1:#{udp_port}",
        "srt://127.0.0.1:#{srt_port}?mode=caller"
      ],
      tag
    )
  end

  @spec start_srt_to_udp_listener!(String.t(), integer(), integer()) :: map()
  def start_srt_to_udp_listener!(tag, srt_port, udp_port) do
    E2EHelpers.start_port_logged!(
      "srt-live-transmit",
      [
        "-v",
        "-stats",
        "1000",
        "-statspf",
        "default",
        "srt://127.0.0.1:#{srt_port}?mode=listener",
        "udp://127.0.0.1:#{udp_port}"
      ],
      tag
    )
  end

  @spec start_ffmpeg_udp_sender!(String.t(), integer()) :: map()
  def start_ffmpeg_udp_sender!(tag, udp_port) do
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
        "8",
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
        "udp://127.0.0.1:#{udp_port}?pkt_size=1316"
      ],
      tag
    )
  end

  @spec await_pipeline_udp_sockets!((list() -> boolean()), String.t()) :: list()
  def await_pipeline_udp_sockets!(predicate, description) do
    deadline_ms = System.monotonic_time(:millisecond) + 10_000
    do_await_pipeline_udp_sockets!(predicate, description, deadline_ms)
  end

  def do_await_pipeline_udp_sockets!(predicate, description, deadline_ms) do
    sockets = E2EHelpers.pipeline_udp_sockets!()

    cond do
      predicate.(sockets) ->
        sockets

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("#{description}; pipeline UDP sockets=#{inspect(sockets)}")

      true ->
        Process.sleep(100)
        do_await_pipeline_udp_sockets!(predicate, description, deadline_ms)
    end
  end
end
