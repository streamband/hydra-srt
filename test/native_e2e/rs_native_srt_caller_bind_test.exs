defmodule HydraSrt.E2E.Native.RsNativeSrtCallerBindTest do
  use ExUnit.Case, async: false

  alias HydraSrt.E2E.Native.Harness
  alias HydraSrt.E2E.Native.Helpers
  alias HydraSrt.E2E.Native.ProcessRegistry
  alias HydraSrt.E2E.Native.UdpListener
  alias HydraSrt.TestSupport.E2EHelpers

  @moduletag :native_e2e
  @local_address "127.0.0.1"

  setup_all do
    Helpers.ensure_prereqs!()
    :ok
  end

  setup do
    ProcessRegistry.cleanup_all!()
    source_port = Helpers.free_srt_port!()
    udp_port = Helpers.free_udp_port!()
    route_id = "rs_srt_bind_#{System.unique_integer([:positive])}"
    peer = Helpers.start_gst_srt_listener!(source_port)
    {:ok, udp_listener} = UdpListener.start_link(port: udp_port, test_pid: self())

    on_exit(fn ->
      ProcessRegistry.cleanup_all!()
      if Process.alive?(udp_listener), do: GenServer.stop(udp_listener, :normal, 5_000)
      Helpers.stop_os_process!(peer)
    end)

    {:ok,
     source_port: source_port, udp_port: udp_port, route_id: route_id, udp_listener: udp_listener}
  end

  test "caller source with localaddress binds the SRT socket to that address", %{
    source_port: source_port,
    udp_port: udp_port,
    route_id: route_id,
    udp_listener: udp_listener
  } do
    config =
      Helpers.srt_caller_source_config(source_port, udp_port,
        route_id: route_id,
        localaddress: @local_address
      )

    {:ok, harness} = Harness.start_link(test_pid: self(), route_id: route_id, config: config)
    on_exit(fn -> if Process.alive?(harness), do: Harness.stop(harness) end)

    assert_receive {:rs_native_route_id, ^route_id}, 5_000
    assert_media_flows!(harness, udp_listener)
    os_pid = Harness.os_pid(harness)

    assert :ok =
             Helpers.wait_until(
               fn -> socket_bound?(os_pid, @local_address, fn port -> port > 0 end) end,
               5_000
             )
  end

  test "caller source with localaddress and localport binds exactly that port", %{
    source_port: source_port,
    udp_port: udp_port,
    route_id: route_id,
    udp_listener: udp_listener
  } do
    local_port = distinct_srt_port!([source_port, udp_port])

    config =
      Helpers.srt_caller_source_config(source_port, udp_port,
        route_id: route_id,
        localaddress: @local_address,
        localport: local_port
      )

    {:ok, harness} = Harness.start_link(test_pid: self(), route_id: route_id, config: config)
    on_exit(fn -> if Process.alive?(harness), do: Harness.stop(harness) end)

    assert_receive {:rs_native_route_id, ^route_id}, 5_000
    assert_media_flows!(harness, udp_listener)
    os_pid = Harness.os_pid(harness)

    assert :ok =
             Helpers.wait_until(
               fn -> socket_bound?(os_pid, @local_address, &(&1 == local_port)) end,
               5_000
             )
  end

  test "caller source without localaddress does not bind a specific address", %{
    source_port: source_port,
    udp_port: udp_port,
    route_id: route_id,
    udp_listener: udp_listener
  } do
    config = Helpers.srt_caller_source_config(source_port, udp_port, route_id: route_id)

    {:ok, harness} = Harness.start_link(test_pid: self(), route_id: route_id, config: config)
    on_exit(fn -> if Process.alive?(harness), do: Harness.stop(harness) end)

    assert_receive {:rs_native_route_id, ^route_id}, 5_000
    assert_media_flows!(harness, udp_listener)
    os_pid = Harness.os_pid(harness)

    sockets = E2EHelpers.pipeline_udp_sockets!()

    refute Enum.any?(sockets, fn socket ->
             socket.os_pid == os_pid and socket.address == @local_address
           end),
           "pipeline UDP sockets=#{inspect(sockets)}"
  end

  test "caller source with an unusable localaddress fails the route explicitly", %{
    source_port: source_port,
    udp_port: udp_port,
    route_id: route_id
  } do
    # TEST-NET-3 is not assigned on this host, so its local bind must fail.
    unusable_address = "203.0.113.1"

    config =
      Helpers.srt_caller_source_config(source_port, udp_port,
        route_id: route_id,
        localaddress: unusable_address
      )

    {:ok, harness} = Harness.start_link(test_pid: self(), route_id: route_id, config: config)
    on_exit(fn -> if Process.alive?(harness), do: Harness.stop(harness) end)

    assert_receive {:rs_native_route_id, ^route_id}, 5_000

    assert_receive {:rs_native_event,
                    %{
                      "event" => "route_terminal",
                      "reason_code" => "CONFIG_INVALID",
                      "detail" => detail
                    }},
                   10_000

    assert detail =~ unusable_address
    assert_receive {:rs_native_exit_status, ^route_id, status}, 5_000
    assert status != 0
  end

  @spec assert_media_flows!(pid(), pid()) :: :ok
  def assert_media_flows!(harness, udp_listener) do
    assert {:ok, stats} =
             Harness.await_stats(
               harness,
               fn
                 %{"source" => %{"bytes_in_per_sec" => bytes_in_per_sec}}
                 when is_number(bytes_in_per_sec) and bytes_in_per_sec > 0 ->
                   true

                 _ ->
                   false
               end,
               15_000
             )

    assert stats["source"]["type"] == "GstSRTSrc"
    assert {:ok, udp_stats} = UdpListener.await_packets(udp_listener, 5, 10_000)
    assert udp_stats.bytes > 0
    :ok
  end

  @spec socket_bound?(non_neg_integer(), String.t(), (integer() -> boolean())) :: boolean()
  def socket_bound?(os_pid, address, port_predicate)
      when is_integer(os_pid) and is_binary(address) and is_function(port_predicate, 1) do
    Enum.any?(E2EHelpers.pipeline_udp_sockets!(), fn socket ->
      socket.os_pid == os_pid and socket.address == address and port_predicate.(socket.port)
    end)
  end

  @spec distinct_srt_port!([integer()]) :: integer()
  def distinct_srt_port!(used_ports) when is_list(used_ports) do
    port = Helpers.free_srt_port!()
    if port in used_ports, do: distinct_srt_port!(used_ports), else: port
  end
end
