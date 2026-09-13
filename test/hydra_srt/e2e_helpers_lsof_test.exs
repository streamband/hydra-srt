defmodule HydraSrt.E2EHelpersLsofTest do
  use ExUnit.Case, async: true

  alias HydraSrt.TestSupport.E2EHelpers

  test "parse_lsof_udp_line parses IPv4, wildcard, and bracketed IPv6 names" do
    assert E2EHelpers.parse_lsof_udp_line(
             "hydra_srt_pipeline 123 user 10u IPv4 0x1 0t0 12345 127.0.0.1:59409"
           ) == %{os_pid: 123, address: "127.0.0.1", port: 59_409}

    assert E2EHelpers.parse_lsof_udp_line(
             "hydra_srt_pipeline 124 user 10u IPv4 0x1 0t0 12345 *:64002"
           ) == %{os_pid: 124, address: "*", port: 64_002}

    assert E2EHelpers.parse_lsof_udp_line(
             "hydra_srt_pipeline 125 user 10u IPv6 0x1 0t0 12345 [::1]:5000"
           ) == %{os_pid: 125, address: "[::1]", port: 5000}

    assert E2EHelpers.parse_lsof_udp_line(
             "hydra_srt_pipeline 126 user 10u IPv6 0x1 0t0 12345 [::]:5001"
           ) == %{os_pid: 126, address: "[::]", port: 5001}
  end

  test "parse_lsof_udp_line raises for malformed output" do
    assert_raise RuntimeError, ~r/Unable to parse lsof UDP line/, fn ->
      E2EHelpers.parse_lsof_udp_line("hydra_srt_pipeline not-a-pid malformed")
    end
  end
end
