defmodule HydraSrt.RouteHandlerTest do
  use ExUnit.Case
  alias HydraSrt.Api.Endpoint
  alias HydraSrt.RouteHandler
  import HydraSrt.ApiFixtures

  defmodule TestSystemInterfaces do
    def discover do
      {:ok,
       [
         %{"sys_name" => "en0", "ip" => "172.20.20.12/24"},
         %{"sys_name" => "en1", "ip" => "10.10.0.4"}
       ]}
    end
  end

  defmodule EmptySystemInterfaces do
    def discover, do: {:ok, []}
  end

  defmodule FailingSystemInterfaces do
    def discover, do: {:error, :ifconfig_failed}
  end

  defmodule TestDb do
    def get_interface_by_sys_name("en0"), do: {:ok, %{"sys_name" => "en0", "ip" => "10.0.0.2/24"}}
    def get_interface_by_sys_name("en9"), do: {:ok, %{"sys_name" => "en9", "ip" => "192.0.2.10"}}
    def get_interface_by_sys_name(_), do: {:error, :not_found}
  end

  defmodule MissingTestDb do
    def get_interface_by_sys_name(_), do: {:error, :not_found}
  end

  # Full RouteHandler data map matching init/1 (including W3b recovery keys).
  @spec base_route_data(map()) :: map()
  def base_route_data(overrides \\ %{}) when is_map(overrides) do
    Map.merge(
      %{
        id: "route-base",
        port: nil,
        route: %{},
        port_buffer: "",
        shutdown_reason: nil,
        active_source_id: nil,
        last_manual_source_id: nil,
        process_instance_id: nil,
        endpoint_health: %{},
        route_terminal: nil,
        source_loss_since_ms: nil,
        source_loss_signal: nil,
        source_data_seen?: false,
        healthy_since_ms: nil,
        cooldown_until: nil,
        primary_stable_since_ms: nil,
        last_primary_probe_ms: nil,
        primary_probe_inflight?: false,
        retry_scheduled?: false,
        retry_attempt: 0,
        retry_prev_backoff_ms: nil,
        retry_last_logged_ms: nil,
        retry_circuit_open?: false,
        recovery_blocked?: false,
        recovering?: false,
        stats_baseline: nil,
        stats_reset_at: nil,
        stats_rebased_at: nil,
        last_stats: nil
      },
      overrides
    )
  end

  describe "stats reset counters" do
    test "extracts numeric source and destination counters" do
      stats = %{
        "total-bytes-received" => 1000,
        "source" => %{
          "bytes_in_total" => 900,
          "bytes_in_per_sec" => 10,
          "srt" => %{
            "packets-received" => 20,
            "packets-received-lost" => 2,
            "rtt-ms" => 5.0
          }
        },
        "destinations" => [
          %{
            "id" => "dest-1",
            "bytes_out_total" => 800,
            "drops" => 3,
            "srt" => %{
              "packets-sent" => 19,
              "packets-sent-lost" => 1,
              "rtt-ms" => 6.0
            }
          },
          %{"bytes_out_total" => 500}
        ]
      }

      assert RouteHandler.stats_counters(stats) == %{
               "total-bytes-received" => 1000,
               {:source, nil} => %{
                 "bytes_in_total" => 900,
                 "srt" => %{
                   "packets-received" => 20,
                   "packets-received-lost" => 2
                 }
               },
               {:destination, "dest-1"} => %{
                 "bytes_out_total" => 800,
                 "drops" => 3,
                 "srt" => %{"packets-sent" => 19, "packets-sent-lost" => 1}
               }
             }
    end

    test "since_reset omits missing and non-counter fields" do
      baseline_stats = %{
        "total-bytes-received" => 100,
        "source" => %{
          "bytes_in_total" => 90,
          "srt" => %{"packets-received" => 10, "packets-received-lost" => 1}
        },
        "destinations" => [
          %{
            "id" => "dest-1",
            "bytes_out_total" => 80,
            "drops" => 2,
            "srt" => %{"packets-sent" => 8}
          }
        ]
      }

      current_stats = %{
        "total-bytes-received" => 140,
        "source" => %{
          "bytes_in_total" => 120,
          "srt" => %{"packets-received" => 15, "rtt-ms" => 20.0}
        },
        "destinations" => [
          %{"id" => "dest-1", "bytes_out_total" => 95, "srt" => %{"packets-sent" => 10}}
        ]
      }

      reset_at = ~U[2026-09-03 10:00:00.000000Z]

      assert RouteHandler.since_reset(
               current_stats,
               RouteHandler.stats_counters(baseline_stats),
               reset_at,
               nil
             ) == %{
               "reset_at" => "2026-09-03T10:00:00.000000Z",
               "rebased_at" => nil,
               "total-bytes-received" => 40,
               "source" => %{
                 "bytes_in_total" => 30,
                 "srt" => %{"packets-received" => 5}
               },
               "destinations" => [
                 %{"id" => "dest-1", "bytes_out_total" => 15, "srt" => %{"packets-sent" => 2}}
               ]
             }
    end

    test "clearing without an active baseline logs no reset event" do
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:all")
      data = base_route_data(%{id: "route-clear-noop"})

      assert {:keep_state, next_data, [{:reply, :from, {:ok, nil}}]} =
               RouteHandler.handle_event({:call, :from}, :clear_stats_reset, :running, data)

      assert next_data.stats_baseline == nil
      assert next_data.stats_reset_at == nil
      refute_receive {:event, %{"event_type" => "stats_reset"}}, 100
    end

    test "clearing an active baseline logs a cleared event" do
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "events:all")

      data =
        base_route_data(%{
          id: "route-clear-active",
          stats_baseline: %{{:source, nil} => %{"bytes_in_total" => 10}},
          stats_reset_at: ~U[2026-09-03 10:00:00.000000Z]
        })

      assert {:keep_state, next_data, [{:reply, :from, {:ok, nil}}]} =
               RouteHandler.handle_event({:call, :from}, :clear_stats_reset, :running, data)

      assert next_data.stats_baseline == nil
      assert next_data.stats_reset_at == nil
      assert_receive {:event, %{"event_type" => "stats_reset", "reason" => "cleared"}}, 500
    end

    test "detects counter decreases but not equal or increased values" do
      baseline = %{
        {:source, nil} => %{"srt" => %{"packets-received" => 10}},
        "total-bytes-received" => 20
      }

      assert RouteHandler.counters_regressed?(
               %{
                 {:source, nil} => %{"srt" => %{"packets-received" => 9}},
                 "total-bytes-received" => 20
               },
               baseline
             )

      refute RouteHandler.counters_regressed?(
               %{
                 {:source, nil} => %{"srt" => %{"packets-received" => 10}},
                 "total-bytes-received" => 21
               },
               baseline
             )
    end
  end

  @spec youtube_context() :: {map(), Endpoint.t()}
  def youtube_context do
    route = route_fixture()
    source = youtube_source_fixture(route)

    data =
      base_route_data(%{
        id: route.id,
        route: %{"sources" => [%{"id" => source.id, "schema" => "YOUTUBE"}]},
        active_source_id: source.id,
        process_instance_id: "youtube-process"
      })

    {data, source}
  end

  @spec youtube_event(map(), map(), integer()) :: map()
  def youtube_event(data, media_info, observed_at_ms) do
    %{
      "event" => "media_info",
      "route_id" => data.id,
      "process_instance_id" => data.process_instance_id,
      "endpoint_id" => data.active_source_id,
      "transport" => "hls",
      "live" => true,
      "observed_at_ms" => observed_at_ms,
      "media_info" => media_info
    }
  end

  test "source_from_record with valid SRT schema" do
    record = %{
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4201,
      "mode" => "listener",
      "latency" => 200,
      "auto_reconnect" => true,
      "keep_listening" => true,
      "limit_access" => true,
      "allowed_list" => ["127.0.0.1", "10.10.0.0/16"],
      "denied_list" => ["192.0.2.10"]
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "srt"
    srt = source["srt"]
    assert srt["uri"] =~ "srt://127.0.0.1:4201"
    assert srt["uri"] =~ "mode=listener"
    assert srt["mode"] == "listener"
    assert srt["latency"] == 200
    assert srt["auto_reconnect"] == true
    assert srt["keep_listening"] == true
    assert srt["localaddress"] == "127.0.0.1"
    assert srt["localport"] == 4201

    assert srt["access"] == %{
             "limit" => true,
             "allowed" => ["127.0.0.1", "10.10.0.0/16"],
             "denied" => ["192.0.2.10"]
           }

    refute Map.has_key?(srt, "streamid")
  end

  test "source_from_record does not pass access ranges when limit_access is false" do
    record = %{
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4201,
      "mode" => "listener",
      "limit_access" => false,
      "allowed_list" => ["127.0.0.1"],
      "denied_list" => ["192.0.2.10"]
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    refute Map.has_key?(source["srt"], "access")
  end

  test "source_from_record with SRT schema and passphrase" do
    record = %{
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4201,
      "mode" => "listener",
      "passphrase" => "secret",
      "pbkeylen" => 16
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "srt"
    srt = source["srt"]
    assert srt["uri"] =~ "srt://127.0.0.1:4201"
    assert srt["uri"] =~ "mode=listener"
    assert srt["uri"] =~ "passphrase=secret"
    assert srt["uri"] =~ "pbkeylen=16"
    assert srt["passphrase"] == "secret"
    assert srt["pbkeylen"] == 16
  end

  test "build_srt_uri uses remote address and port in caller mode" do
    opts = %{
      "mode" => "caller",
      "address" => "198.51.100.20",
      "port" => 4209,
      "localaddress" => "10.0.0.10",
      "localport" => 4201
    }

    assert RouteHandler.build_srt_uri(opts) == "srt://198.51.100.20:4209?mode=caller"
  end

  test "build_srt_uri encodes streamid with SRT authentication options" do
    opts = %{
      "mode" => "caller",
      "address" => "198.51.100.20",
      "port" => 4209,
      "streamid" => "#!::r=channel",
      "passphrase" => "some_pass_1",
      "pbkeylen" => 16
    }

    uri = RouteHandler.build_srt_uri(opts)
    query = URI.parse(uri).query |> URI.decode_query()

    assert URI.parse(uri).host == "198.51.100.20"
    assert URI.parse(uri).port == 4209

    assert query == %{
             "mode" => "caller",
             "streamid" => "#!::r=channel",
             "passphrase" => "some_pass_1",
             "pbkeylen" => "16"
           }
  end

  test "build_srt_uri percent-encodes spaces instead of emitting '+'" do
    opts = %{
      "mode" => "caller",
      "address" => "198.51.100.20",
      "port" => 4209,
      "streamid" => "live feed",
      "passphrase" => "my secret pass 42",
      "pbkeylen" => 16
    }

    uri = RouteHandler.build_srt_uri(opts)
    query = URI.parse(uri).query

    # GStreamer only percent-decodes the SRT query, so a `+` would reach SRT verbatim.
    refute query =~ "+"
    assert query =~ "passphrase=my%20secret%20pass%2042"
    assert query =~ "streamid=live%20feed"

    assert URI.decode_query(query) == %{
             "mode" => "caller",
             "streamid" => "live feed",
             "passphrase" => "my secret pass 42",
             "pbkeylen" => "16"
           }
  end

  test "build_srt_uri percent-encodes reserved characters in the passphrase" do
    uri =
      RouteHandler.build_srt_uri(%{
        "mode" => "caller",
        "address" => "198.51.100.20",
        "port" => 4209,
        "passphrase" => "^Aa1Bb2Cc3Dd4Ee5^FG&H",
        "pbkeylen" => 16
      })

    assert URI.parse(uri).query =~ "passphrase=%5EAa1Bb2Cc3Dd4Ee5%5EFG%26H"
    assert URI.decode_query(URI.parse(uri).query)["passphrase"] == "^Aa1Bb2Cc3Dd4Ee5^FG&H"
  end

  test "build_srt_uri supports streamid in rendezvous mode" do
    uri =
      RouteHandler.build_srt_uri(%{
        "mode" => "rendezvous",
        "address" => "198.51.100.20",
        "port" => 4209,
        "streamid" => "channel"
      })

    assert URI.decode_query(URI.parse(uri).query) == %{
             "mode" => "rendezvous",
             "streamid" => "channel"
           }
  end

  test "build_srt_uri omits nil and empty streamid" do
    base = %{"mode" => "caller", "address" => "198.51.100.20", "port" => 4209}

    for streamid <- [nil, ""] do
      uri = RouteHandler.build_srt_uri(Map.put(base, "streamid", streamid))
      refute URI.decode_query(URI.parse(uri).query) |> Map.has_key?("streamid")
    end
  end

  test "build_srt_uri omits preserved streamid in listener mode" do
    uri =
      RouteHandler.build_srt_uri(%{
        "mode" => "listener",
        "localaddress" => "127.0.0.1",
        "localport" => 4201,
        "streamid" => "#!::r=preserved"
      })

    refute URI.decode_query(URI.parse(uri).query) |> Map.has_key?("streamid")
  end

  test "source_from_record does not send preserved streamid to a listener pipeline" do
    record = %{
      "schema" => "SRT",
      "mode" => "listener",
      "localaddress" => "127.0.0.1",
      "localport" => 4201,
      "streamid" => "#!::r=preserved"
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    refute Map.has_key?(source["srt"], "streamid")
    refute URI.decode_query(URI.parse(source["srt"]["uri"]).query) |> Map.has_key?("streamid")
  end

  test "source_from_record sends caller streamid through URI and typed payload" do
    record = %{
      "schema" => "SRT",
      "mode" => "caller",
      "address" => "198.51.100.20",
      "port" => 4209,
      "streamid" => "#!::r=channel"
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["srt"]["streamid"] == "#!::r=channel"
    assert URI.decode_query(URI.parse(source["srt"]["uri"]).query)["streamid"] == "#!::r=channel"
  end

  test "source payloads carry program number only when configured" do
    records = [
      {"UDP", "udp", %{"schema" => "UDP", "address" => "127.0.0.1", "port" => 4210}},
      {"RTP", "rtp", %{"schema" => "RTP", "address" => "127.0.0.1", "port" => 4211}},
      {"SRT", "srt", %{"schema" => "SRT", "mode" => "listener", "localport" => 4212}}
    ]

    for {_schema, kind, record} <- records do
      assert {:ok, source} =
               RouteHandler.source_from_record(Map.put(record, "program_number", 12))

      assert source[kind]["program_number"] == 12

      assert {:ok, source_without_program} = RouteHandler.source_from_record(record)
      refute Map.has_key?(source_without_program[kind], "program_number")
    end

    refute Map.has_key?(
             RouteHandler.srt_destination_payload(%{"program_number" => 12}, "srt://example:1"),
             "program_number"
           )
  end

  test "a failover source keeps its own program number" do
    sources = [
      %{
        "id" => "primary",
        "enabled" => true,
        "schema" => "UDP",
        "address" => "127.0.0.1",
        "port" => 4213,
        "program_number" => 11
      },
      %{
        "id" => "backup",
        "enabled" => true,
        "schema" => "UDP",
        "address" => "127.0.0.1",
        "port" => 4214,
        "program_number" => 12
      }
    ]

    backup = RouteHandler.failover_target_source(sources, "primary", "passive")
    assert backup["id"] == "backup"

    assert {:ok, %{"udp" => %{"program_number" => 12}}} =
             RouteHandler.source_from_record(backup)
  end

  test "strip_cidr_suffix removes netmask from discovered interface ip" do
    assert RouteHandler.strip_cidr_suffix("172.20.20.12/24") == "172.20.20.12"
    assert RouteHandler.strip_cidr_suffix("fe80::1%en0/64") == "fe80::1%en0"
    assert RouteHandler.strip_cidr_suffix("10.0.0.5") == "10.0.0.5"
  end

  test "resolve_interface_bind_ip prefers live system interface ip over DB value" do
    Application.put_env(:hydra_srt, :system_interfaces_module, TestSystemInterfaces)
    Application.put_env(:hydra_srt, :db_module, TestDb)

    on_exit(fn ->
      Application.delete_env(:hydra_srt, :system_interfaces_module)
      Application.delete_env(:hydra_srt, :db_module)
    end)

    assert {:ok, "172.20.20.12"} = RouteHandler.resolve_interface_bind_ip("en0")
  end

  test "resolve_interface_bind_ip falls back to DB when system lookup misses interface" do
    Application.put_env(:hydra_srt, :system_interfaces_module, EmptySystemInterfaces)
    Application.put_env(:hydra_srt, :db_module, TestDb)

    on_exit(fn ->
      Application.delete_env(:hydra_srt, :system_interfaces_module)
      Application.delete_env(:hydra_srt, :db_module)
    end)

    assert {:ok, "192.0.2.10"} = RouteHandler.resolve_interface_bind_ip("en9")
  end

  test "resolve_interface_bind_ip falls back to DB when system discovery fails" do
    Application.put_env(:hydra_srt, :system_interfaces_module, FailingSystemInterfaces)
    Application.put_env(:hydra_srt, :db_module, TestDb)

    on_exit(fn ->
      Application.delete_env(:hydra_srt, :system_interfaces_module)
      Application.delete_env(:hydra_srt, :db_module)
    end)

    assert {:ok, "10.0.0.2"} = RouteHandler.resolve_interface_bind_ip("en0")
  end

  test "source_from_record with valid UDP schema" do
    record = %{
      "schema" => "UDP",
      "address" => "127.0.0.1",
      "port" => 4201,
      "buffer-size" => 65_536,
      "mtu" => 1500
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "udp"
    assert source["udp"] == %{"address" => "127.0.0.1", "port" => 4201}
    refute Map.has_key?(source["udp"], "buffer-size")
    refute Map.has_key?(source["udp"], "mtu")
  end

  test "source_from_record with UDP schema and minimal options" do
    record = %{
      "schema" => "UDP",
      "address" => "127.0.0.1",
      "port" => 4201
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "udp"
    assert source["udp"]["address"] == "127.0.0.1"
    assert source["udp"]["port"] == 4201
  end

  test "source_from_record normalizes UDP host to udpsrc address" do
    record = %{
      "schema" => "UDP",
      "host" => "127.0.0.1",
      "port" => 4201
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "udp"
    assert source["udp"]["address"] == "127.0.0.1"
    refute Map.has_key?(source["udp"], "host")
  end

  test "source_from_record emits explicit UDP multicast options" do
    record = %{
      "schema" => "UDP",
      "address" => "239.1.1.1",
      "port" => 5000,
      "multicast" => true,
      "multicast_iface" => "eno2"
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "udp"

    assert source["udp"] == %{
             "address" => "239.1.1.1",
             "port" => 5000,
             "auto_multicast" => true,
             "multicast_iface" => "eno2"
           }
  end

  test "source_from_record with RTP schema" do
    record = %{
      "schema" => "RTP",
      "address" => "127.0.0.1",
      "port" => 5004
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "rtp"
    assert source["rtp"] == %{"address" => "127.0.0.1", "port" => 5004}
    refute Map.has_key?(source, "hydra_source_schema")
  end

  test "source_from_record keeps RTP depay marker with multicast options" do
    Application.put_env(:hydra_srt, :system_interfaces_module, EmptySystemInterfaces)
    Application.put_env(:hydra_srt, :db_module, MissingTestDb)

    on_exit(fn ->
      Application.delete_env(:hydra_srt, :system_interfaces_module)
      Application.delete_env(:hydra_srt, :db_module)
    end)

    record = %{
      "schema" => "RTP",
      "host" => "239.1.1.2",
      "port" => 5004,
      "multicast" => true,
      "interface_sys_name" => "en0"
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["kind"] == "rtp"

    assert source["rtp"] == %{
             "address" => "239.1.1.2",
             "port" => 5004,
             "auto_multicast" => true,
             "multicast_iface" => "en0"
           }

    refute Map.has_key?(source["rtp"], "host")
    refute Map.has_key?(source["rtp"], "interface_sys_name")
  end

  test "source_from_record with invalid schema" do
    record = %{
      "schema" => "INVALID"
    }

    assert {:error, :invalid_source} = RouteHandler.source_from_record(record)
  end

  test "youtube_hls_payload preserves a false live flag for VOD" do
    media = %{
      live: false,
      media_info: %{"video" => %{"height" => 360}},
      uri: "http://127.0.0.1:4567/playlist.m3u8"
    }

    assert {:ok, payload} =
             RouteHandler.youtube_hls_payload(media, %{"youtube_end_action" => "stop"})

    assert payload["live"] == false
    assert payload["end_action"] == "stop"
  end

  test "youtube_uri_expires_at reads googlevideo path expiry without retaining the URI" do
    uri =
      "https://rr3---sn-example.googlevideo.com/videoplayback/id/video-1/itag/95/expire/1750000000/" <>
        "range/0-999999/file/playlist.m3u8?sig=secret&n=123456"

    assert RouteHandler.youtube_uri_expires_at(uri) == 1_750_000_000
  end

  test "source_from_record with missing options" do
    record = %{"schema" => "SRT"}
    assert {:error, :invalid_source} = RouteHandler.source_from_record(record)
  end

  test "parse_native_json_line accepts structured pipeline log events" do
    line =
      Jason.encode!(%{
        "event" => "pipeline_log",
        "level" => "WARN",
        "category" => "native_config",
        "element" => "udpsrc",
        "message" => "ignored unsupported property host on udpsrc"
      })

    assert {:pipeline_log, log} = RouteHandler.parse_native_json_line(line)
    assert log["level"] == "WARN"
    assert log["category"] == "native_config"
    assert log["element"] == "udpsrc"
  end

  test "parse_native_json_line accepts a bus-error pipeline log with no element" do
    # Mirrors what native/crates/hydra-media/src/health.rs's bus watch now emits for a
    # gst bus Error message whose source object could not be attributed (element key
    # omitted rather than sent as null/"unknown").
    line =
      Jason.encode!(%{
        "event" => "pipeline_log",
        "level" => "ERROR",
        "category" => "gst_bus",
        "message" => "Failed to authenticate: Incorrect passphrase (10)"
      })

    assert {:pipeline_log, log} = RouteHandler.parse_native_json_line(line)
    assert log["level"] == "ERROR"
    assert log["category"] == "gst_bus"
    refute Map.has_key?(log, "element")
    assert log["message"] == "Failed to authenticate: Incorrect passphrase (10)"
  end

  describe "publish_native_pipeline_log/2" do
    setup do
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "pipeline_logs")
      :ok
    end

    test "broadcasts the native SRT bus-error payload with the route id attached" do
      route_id = "route-srt-auth"

      data = base_route_data(%{id: route_id, process_instance_id: "piid-1"})

      payload = %{
        "event" => "pipeline_log",
        "route_id" => route_id,
        "process_instance_id" => "piid-1",
        "level" => "ERROR",
        "category" => "gst_bus",
        "element" => "srtsrc0",
        "message" =>
          "Failed to authenticate: Incorrect passphrase (10) | debug: gstsrtsrc.c:206:gst_srt_src_fill",
        "sequence" => 7,
        "observed_at_ms" => 1_700_000_000_000
      }

      RouteHandler.publish_native_pipeline_log(data, payload)

      assert_receive {:pipeline_log, log}
      assert log.route_id == route_id
      assert log.level == "ERROR"
      assert log.category == "gst_bus"
      assert log.element == "srtsrc0"
      assert log.sequence == 7
      assert log.observed_at_ms == 1_700_000_000_000

      assert log.message ==
               "Failed to authenticate: Incorrect passphrase (10) | debug: gstsrtsrc.c:206:gst_srt_src_fill"
    end

    test "broadcasts a native bus-warning payload with a nil element when absent" do
      route_id = "route-srt-warn"
      data = base_route_data(%{id: route_id, process_instance_id: "piid-2"})

      payload = %{
        "event" => "pipeline_log",
        "route_id" => route_id,
        "process_instance_id" => "piid-2",
        "level" => "WARN",
        "category" => "gst_bus",
        "message" => "streaming stopped, reason error (-5)"
      }

      RouteHandler.publish_native_pipeline_log(data, payload)

      assert_receive {:pipeline_log, log}
      assert log.route_id == route_id
      assert log.level == "WARN"
      assert log.category == "gst_bus"
      assert log.element == nil
      assert log.message == "streaming stopped, reason error (-5)"
    end

    test "drops a pipeline_log from a stale process instance without broadcasting" do
      route_id = "route-srt-stale"
      data = base_route_data(%{id: route_id, process_instance_id: "piid-current"})

      payload = %{
        "event" => "pipeline_log",
        "route_id" => route_id,
        "process_instance_id" => "piid-old",
        "level" => "WARN",
        "category" => "gst_bus",
        "message" => "stale process warning"
      }

      RouteHandler.publish_native_pipeline_log(data, payload)

      refute_receive {:pipeline_log, _}, 50
    end

    test "rejects a malformed payload instead of inventing a level or message" do
      route_id = "route-srt-malformed"
      data = base_route_data(%{id: route_id, process_instance_id: "piid-3"})

      payload = %{
        "event" => "pipeline_log",
        "route_id" => route_id,
        "process_instance_id" => "piid-3",
        "category" => "gst_bus"
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          RouteHandler.publish_native_pipeline_log(data, payload)
        end)

      assert log =~ "malformed native pipeline_log payload"
      refute_receive {:pipeline_log, _}, 50
    end

    test "consume_port_output threads a pipeline_log event through process_port_line" do
      data = base_route_data(%{id: "route-srt-e2e", process_instance_id: "piid-e2e"})

      line =
        Jason.encode!(%{
          "event" => "pipeline_log",
          "route_id" => "route-srt-e2e",
          "process_instance_id" => "piid-e2e",
          "level" => "ERROR",
          "category" => "gst_bus",
          "message" => "Could not read from resource.",
          "sequence" => 1,
          "observed_at_ms" => 1_700_000_000_000
        })

      _next = RouteHandler.consume_port_output(line <> "\n", data)

      assert_receive {:pipeline_log, log}
      assert log.route_id == "route-srt-e2e"
      assert log.message == "Could not read from resource."
      assert log.sequence == 1
      assert log.observed_at_ms == 1_700_000_000_000
    end
  end

  test "source_record_from_route picks active source id when present" do
    route = %{
      "active_source_id" => "s2",
      "sources" => [
        %{"id" => "s1", "position" => 0, "schema" => "UDP"},
        %{"id" => "s2", "position" => 1, "schema" => "SRT"}
      ]
    }

    assert {:ok, source} = RouteHandler.source_record_from_route(route, nil)
    assert source["id"] == "s2"
  end

  test "source_record_from_route falls back to position zero when active source missing" do
    route = %{
      "active_source_id" => "missing",
      "sources" => [
        %{"id" => "s1", "position" => 0, "schema" => "UDP"},
        %{"id" => "s2", "position" => 1, "schema" => "SRT"}
      ]
    }

    assert {:ok, source} = RouteHandler.source_record_from_route(route, nil)
    assert source["id"] == "s1"
  end

  test "source_record_from_route uses explicit source id argument" do
    route = %{
      "active_source_id" => "s1",
      "sources" => [
        %{"id" => "s1", "position" => 0, "schema" => "UDP"},
        %{"id" => "s2", "position" => 1, "schema" => "SRT"}
      ]
    }

    assert {:ok, source} = RouteHandler.source_record_from_route(route, "s2")
    assert source["id"] == "s2"
  end

  test "source_record_from_route returns invalid_source when explicit source id missing" do
    route = %{
      "active_source_id" => "s1",
      "sources" => [
        %{"id" => "s1", "position" => 0, "schema" => "UDP"}
      ]
    }

    assert {:error, :invalid_source} = RouteHandler.source_record_from_route(route, "s2")
  end

  test "next_enabled_source in active mode wraps around" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => true},
      %{"id" => "b2", "position" => 2, "enabled" => true}
    ]

    assert RouteHandler.next_enabled_source(sources, "p", "active")["id"] == "b1"
    assert RouteHandler.next_enabled_source(sources, "b1", "active")["id"] == "b2"
    assert RouteHandler.next_enabled_source(sources, "b2", "active")["id"] == "p"
  end

  test "next_enabled_source in passive mode wraps around" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => true}
    ]

    assert RouteHandler.next_enabled_source(sources, "p", "passive")["id"] == "b1"
    assert RouteHandler.next_enabled_source(sources, "b1", "passive")["id"] == "p"
  end

  test "next_enabled_source disabled mode always nil" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => true}
    ]

    assert RouteHandler.next_enabled_source(sources, "p", "disabled") == nil
  end

  test "next_enabled_source skips disabled entries" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => false},
      %{"id" => "b2", "position" => 2, "enabled" => true}
    ]

    assert RouteHandler.next_enabled_source(sources, "p", "passive")["id"] == "b2"
  end

  test "failover_target_source is nil when only one enabled source would wrap to itself" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => false}
    ]

    assert RouteHandler.failover_target_source(sources, "p", "passive") == nil
    assert RouteHandler.failover_target_source(sources, "p", "active") == nil
  end

  test "failover_target_source returns alternate source when backup is available" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => true}
    ]

    assert RouteHandler.failover_target_source(sources, "p", "passive")["id"] == "b1"
    assert RouteHandler.failover_target_source(sources, "b1", "passive")["id"] == "p"
    assert RouteHandler.failover_target_source(sources, "p", "active")["id"] == "b1"
  end

  test "failover_target_source is nil in disabled backup mode" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => true}
    ]

    assert RouteHandler.failover_target_source(sources, "p", "disabled") == nil
  end

  test "next_enabled_source returns current source when it is the only enabled source" do
    sources = [
      %{"id" => "p", "position" => 0, "enabled" => true},
      %{"id" => "b1", "position" => 1, "enabled" => false}
    ]

    assert RouteHandler.next_enabled_source(sources, "p", "active")["id"] == "p"
  end

  test "in_cooldown? boundary behavior" do
    refute RouteHandler.in_cooldown?(nil, 1000)
    refute RouteHandler.in_cooldown?(1000, 1000)
    refute RouteHandler.in_cooldown?(900, 1000)
    assert RouteHandler.in_cooldown?(1001, 1000)
  end

  test "should_trigger_source_loss_failover? uses single debounce window and cooldown" do
    data = %{
      route: %{"backup_mode" => "passive", "backup_switch_after_ms" => 3000},
      source_loss_elapsed_ms: 2500,
      cooldown_until: nil,
      now_ms: 1000
    }

    refute RouteHandler.should_trigger_source_loss_failover?(data)

    assert RouteHandler.should_trigger_source_loss_failover?(%{
             data
             | source_loss_elapsed_ms: 3000
           })

    refute RouteHandler.should_trigger_source_loss_failover?(%{
             data
             | source_loss_elapsed_ms: 3000,
               cooldown_until: 2000
           })
  end

  test "should_trigger_source_loss_failover? still acts (visibility) once debounced in disabled mode" do
    # backup_mode "disabled" must not suppress the debounced source-loss
    # action entirely - only the actual failover target lookup
    # (next_source_for_failover/next_enabled_source, tested elsewhere) is nil
    # for "disabled" mode. The visible "reconnecting" state a dead source
    # produces is not conditioned on backup switching being configured.
    data = %{
      route: %{"backup_mode" => "disabled", "backup_switch_after_ms" => 1000},
      source_loss_elapsed_ms: 5000,
      now_ms: 1000
    }

    assert RouteHandler.should_trigger_source_loss_failover?(data)

    refute RouteHandler.should_trigger_source_loss_failover?(%{
             data
             | source_loss_elapsed_ms: 500
           })
  end

  test "observe_source_loss merges reconnecting and zero_bitrate into one window" do
    base = %{
      id: "route-soft-1",
      active_source_id: "s1",
      route: %{"backup_mode" => "passive", "backup_switch_after_ms" => 60_000},
      source_loss_since_ms: nil,
      source_loss_signal: nil,
      cooldown_until: nil,
      retry_scheduled?: false,
      retry_circuit_open?: false,
      recovery_blocked?: false
    }

    after_reconnect = RouteHandler.observe_source_loss(base, :reconnecting)
    assert is_integer(after_reconnect.source_loss_since_ms)
    assert after_reconnect.source_loss_signal == :reconnecting

    after_zero = RouteHandler.observe_source_loss(after_reconnect, :zero_bitrate)
    # Same soft budget — do not restart the debounce clock.
    assert after_zero.source_loss_since_ms == after_reconnect.source_loss_since_ms
    assert after_zero.source_loss_signal == :zero_bitrate
    refute after_zero[:retry_scheduled?]
  end

  test "observe_source_loss is suppressed when hard-retry already owns recovery" do
    data = %{
      id: "route-soft-2",
      active_source_id: "s1",
      route: %{"backup_mode" => "passive", "backup_switch_after_ms" => 1},
      source_loss_since_ms: nil,
      source_loss_signal: nil,
      cooldown_until: nil,
      retry_scheduled?: true,
      retry_circuit_open?: false,
      recovery_blocked?: false
    }

    next = RouteHandler.observe_source_loss(data, :zero_bitrate)
    assert next.source_loss_since_ms == nil
    assert next.retry_scheduled? == true
  end

  describe "source loss with no failover target becomes visible instead of a silent no-op (stubbed runtime status)" do
    setup do
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

      :meck.expect(HydraSrt, :set_route_runtime_status, fn _id, _status -> {:ok, %{}} end)

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    test "idle listener source does not turn zero bitrate into reconnecting" do
      data =
        base_route_data(%{
          id: "route-idle-listener",
          active_source_id: "listener-1",
          route: %{
            "backup_mode" => "disabled",
            "backup_switch_after_ms" => 0,
            "sources" => [
              %{
                "id" => "listener-1",
                "enabled" => true,
                "schema" => "SRT",
                "mode" => "listener"
              }
            ]
          }
        })

      assert RouteHandler.listener_source_waiting?(data)
      assert RouteHandler.normalize_runtime_status("reconnecting", nil, data) == :ignore

      assert RouteHandler.maybe_handle_zero_bitrate(data, %{
               "source" => %{"bytes_in_per_sec" => 0}
             }) == data

      refute_receive {:log_pipeline_reconnecting, _, _, _}, 50
    end

    test "listener source that delivered data still becomes reconnecting when it stops" do
      route_id = "route-listener-loss"
      test_pid = self()

      :meck.expect(HydraSrt, :set_route_runtime_status, fn id, status ->
        send(test_pid, {:set_route_runtime_status, id, status})
        {:ok, %{}}
      end)

      :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_reconnecting, fn id,
                                                                              source_id,
                                                                              reason ->
        send(test_pid, {:log_pipeline_reconnecting, id, source_id, reason})
        :ok
      end)

      data =
        base_route_data(%{
          id: route_id,
          active_source_id: "listener-1",
          source_data_seen?: true,
          route: %{
            "backup_mode" => "disabled",
            "backup_switch_after_ms" => 0,
            "sources" => [
              %{
                "id" => "listener-1",
                "enabled" => true,
                "schema" => "SRT",
                "mode" => "listener"
              }
            ]
          }
        })

      refute RouteHandler.listener_source_waiting?(data)

      next =
        RouteHandler.maybe_handle_zero_bitrate(data, %{
          "source" => %{"bytes_in_per_sec" => 0}
        })

      assert next.recovering? == true
      assert_receive {:set_route_runtime_status, ^route_id, "reconnecting"}
      assert_receive {:log_pipeline_reconnecting, ^route_id, "listener-1", "source_loss"}
    end

    test "single-source route in zero-bitrate marks the route reconnecting instead of doing nothing" do
      route_id = "route-no-target-1"
      test_pid = self()

      :meck.expect(HydraSrt, :set_route_runtime_status, fn id, status ->
        send(test_pid, {:set_route_runtime_status, id, status})
        {:ok, %{}}
      end)

      :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_reconnecting, fn id,
                                                                              source_id,
                                                                              reason ->
        send(test_pid, {:log_pipeline_reconnecting, id, source_id, reason})
        :ok
      end)

      data =
        base_route_data(%{
          id: route_id,
          active_source_id: "s1",
          route: %{
            "backup_mode" => "passive",
            "backup_switch_after_ms" => 0,
            "sources" => [%{"id" => "s1", "position" => 0, "enabled" => true}]
          }
        })

      next = RouteHandler.observe_source_loss(data, :zero_bitrate)

      # Visible: status flips, the reason is recorded - and it never stops the
      # route or touches the retry machinery (the pipeline process is fine,
      # only its source stopped delivering data).
      assert next.recovering? == true
      assert next.retry_scheduled? == false
      assert_receive {:set_route_runtime_status, ^route_id, "reconnecting"}
      assert_receive {:log_pipeline_reconnecting, ^route_id, "s1", "source_loss"}
    end

    test "no-target source loss does not repeat the log/status write on every later tick" do
      route_id = "route-no-target-2"
      test_pid = self()

      :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_reconnecting, fn id,
                                                                              source_id,
                                                                              reason ->
        send(test_pid, {:log_pipeline_reconnecting, id, source_id, reason})
        :ok
      end)

      data =
        base_route_data(%{
          id: route_id,
          active_source_id: "s1",
          route: %{
            "backup_mode" => "passive",
            "backup_switch_after_ms" => 0,
            "sources" => [%{"id" => "s1", "position" => 0, "enabled" => true}]
          }
        })

      once = RouteHandler.observe_source_loss(data, :zero_bitrate)
      assert once.recovering? == true
      assert_receive {:log_pipeline_reconnecting, ^route_id, "s1", "source_loss"}

      # Every stats tick re-observes the same ongoing loss (zero-bitrate fires
      # every second) - it must not log/write again while still down.
      twice = RouteHandler.observe_source_loss(once, :zero_bitrate)
      assert twice.recovering? == true
      refute_receive {:log_pipeline_reconnecting, _, _, _}, 50
    end

    test "backup_mode disabled still surfaces the visible reconnecting state instead of reporting healthy" do
      route_id = "route-backup-disabled"
      test_pid = self()

      :meck.expect(HydraSrt, :set_route_runtime_status, fn id, status ->
        send(test_pid, {:set_route_runtime_status, id, status})
        {:ok, %{}}
      end)

      :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_reconnecting, fn id,
                                                                              source_id,
                                                                              reason ->
        send(test_pid, {:log_pipeline_reconnecting, id, source_id, reason})
        :ok
      end)

      # A backup source IS configured, but backup_mode "disabled" means it must
      # never be switched to automatically - the fix is only about visibility,
      # not about silently reinstating auto-failover for disabled routes.
      data =
        base_route_data(%{
          id: route_id,
          active_source_id: "s1",
          route: %{
            "backup_mode" => "disabled",
            "backup_switch_after_ms" => 0,
            "sources" => [
              %{"id" => "s1", "position" => 0, "enabled" => true},
              %{"id" => "s2", "position" => 1, "enabled" => true}
            ]
          }
        })

      next = RouteHandler.observe_source_loss(data, :zero_bitrate)

      # Visible and truthful, exactly like the no-backup-configured case above...
      assert next.recovering? == true
      assert_receive {:set_route_runtime_status, ^route_id, "reconnecting"}
      assert_receive {:log_pipeline_reconnecting, ^route_id, "s1", "source_loss"}

      # ...but "disabled" still means no automatic source switch happened.
      assert next.active_source_id == "s1"
      assert next.port == data.port
    end
  end

  test "next_retry_backoff_ms stays within base..ceiling and grows with attempt" do
    base_ms = :timer.seconds(1)
    ceiling_ms = :timer.seconds(30)

    for attempt <- 1..6, _ <- 1..20 do
      delay = RouteHandler.next_retry_backoff_ms(nil, attempt)
      assert delay >= base_ms
      assert delay <= ceiling_ms
    end

    # Attempt 1 exp floor 1s → upper 3s; attempt 5 exp floor 16s → upper 30s.
    # Sample many draws; max observed for attempt 5 should exceed max for attempt 1.
    max_a1 =
      1..40
      |> Enum.map(fn _ -> RouteHandler.next_retry_backoff_ms(base_ms, 1) end)
      |> Enum.max()

    max_a5 =
      1..40
      |> Enum.map(fn _ -> RouteHandler.next_retry_backoff_ms(base_ms, 5) end)
      |> Enum.max()

    assert max_a1 <= :timer.seconds(3)
    assert max_a5 > max_a1
  end

  describe "hard-retry budget only resets after sustained health, never on a bare spawn" do
    test "resets once data has flowed continuously for the full reset window" do
      now = RouteHandler.now_ms()

      data =
        base_route_data(%{
          recovering?: false,
          retry_attempt: 4,
          retry_prev_backoff_ms: :timer.seconds(16),
          healthy_since_ms: now - :timer.seconds(31)
        })

      next = RouteHandler.clear_source_loss_on_bitrate_recovery(data)

      assert next.retry_attempt == 0
      assert next.retry_prev_backoff_ms == nil
    end

    test "a fresh healthy tick only starts the clock - it does not reset the budget by itself" do
      data =
        base_route_data(%{
          recovering?: false,
          retry_attempt: 4,
          retry_prev_backoff_ms: :timer.seconds(16),
          healthy_since_ms: nil
        })

      next = RouteHandler.clear_source_loss_on_bitrate_recovery(data)

      assert next.retry_attempt == 4
      assert next.retry_prev_backoff_ms == :timer.seconds(16)
      assert is_integer(next.healthy_since_ms)
    end

    test "a subsequent zero-bitrate tick clears the in-progress healthy clock" do
      now = RouteHandler.now_ms()

      data =
        base_route_data(%{
          route: %{"backup_mode" => "passive", "backup_switch_after_ms" => 60_000},
          retry_attempt: 4,
          retry_prev_backoff_ms: :timer.seconds(16),
          healthy_since_ms: now - :timer.seconds(20)
        })

      next = RouteHandler.observe_source_loss(data, :zero_bitrate)

      assert next.healthy_since_ms == nil
      # Not yet long enough to have reset while it was ticking, and the loss
      # itself must not trigger a reset either.
      assert next.retry_attempt == 4
    end
  end

  describe "retry circuit and terminal failure (stubbed runtime status)" do
    # These paths call HydraSrt.mark_route_failed/1; unit tests assert in-memory
    # recovery state only — stub the DB boundary like route_handler_failover_test.
    setup do
      :meck.new(HydraSrt.Db, [:passthrough])
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

      :meck.expect(HydraSrt, :mark_route_failed, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_started, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_stopped, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_terminated, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :set_route_runtime_status, fn _id, _status -> {:ok, %{}} end)
      :meck.expect(HydraSrt.Db, :update_route_runtime_status, fn _id, _status -> {:ok, %{}} end)

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    # A live stream must never latch dead: once the old 5-attempt budget is
    # exhausted the route keeps retrying forever with backoff pinned at the
    # ceiling, instead of giving up and marking the route "failed". These two
    # tests replace the old "circuit opens and gives up" behaviour.
    test "schedule_retry_restart keeps retrying past the old attempt budget instead of latching" do
      route_id = "route-circuit-1"
      test_pid = self()

      :meck.expect(HydraSrt, :set_route_runtime_status, fn id, status ->
        send(test_pid, {:set_route_runtime_status, id, status})
        {:ok, %{}}
      end)

      :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_reconnecting, fn id,
                                                                              source_id,
                                                                              reason ->
        send(test_pid, {:log_pipeline_reconnecting, id, source_id, reason})
        :ok
      end)

      data =
        base_route_data(%{
          id: route_id,
          active_source_id: "s1",
          retry_scheduled?: false,
          retry_attempt: 5,
          retry_prev_backoff_ms: :timer.seconds(30),
          route_terminal: %{
            reason_code: "SRT_CONNECT_TIMEOUT",
            retryable: true,
            retry_domain: "route",
            detail: nil,
            observed_at_ms: nil,
            sequence: nil
          }
        })

      next = RouteHandler.schedule_retry_restart(data)

      # No latch: a timer is still scheduled and the budget fields never flip.
      assert next.retry_scheduled? == true
      assert next.retry_attempt == 6
      assert next.retry_circuit_open? == false
      assert next.recovery_blocked? == false
      assert next.retry_prev_backoff_ms >= :timer.seconds(1)
      assert next.retry_prev_backoff_ms <= :timer.seconds(30)
      assert is_integer(next.retry_last_logged_ms)

      # But it is not silent either: status flips to "reconnecting" (not
      # "failed") and the reason code carried on the route_terminal is visible.
      assert_receive {:set_route_runtime_status, ^route_id, "reconnecting"}
      assert_receive {:log_pipeline_reconnecting, ^route_id, "s1", "SRT_CONNECT_TIMEOUT"}
    end

    test "schedule_retry_restart never latches across many attempts and rate-limits its own logging" do
      route_id = "route-circuit-2"
      test_pid = self()

      :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_reconnecting, fn id,
                                                                              source_id,
                                                                              reason ->
        send(test_pid, {:log_pipeline_reconnecting, id, source_id, reason})
        :ok
      end)

      data =
        base_route_data(%{
          id: route_id,
          active_source_id: "s1",
          retry_attempt: 5,
          retry_prev_backoff_ms: :timer.seconds(30)
        })

      final =
        Enum.reduce(1..30, data, fn _i, acc ->
          scheduled = RouteHandler.schedule_retry_restart(%{acc | retry_scheduled?: false})
          assert scheduled.retry_scheduled? == true
          assert scheduled.retry_circuit_open? == false
          assert scheduled.recovery_blocked? == false
          assert scheduled.retry_prev_backoff_ms >= :timer.seconds(1)
          assert scheduled.retry_prev_backoff_ms <= :timer.seconds(30)
          scheduled
        end)

      assert final.retry_attempt == 35

      # All 30 calls land inside the same rate-limit window in test time, so
      # exactly one reconnecting event is emitted - not thirty, and not zero.
      assert_receive {:log_pipeline_reconnecting, ^route_id, "s1", nil}
      refute_receive {:log_pipeline_reconnecting, _, _, _}, 50
    end

    test "mark_terminal_failure blocks further retry scheduling" do
      data =
        base_route_data(%{
          id: "route-term-fail-1",
          active_source_id: "s1",
          retry_scheduled?: false,
          retry_attempt: 0,
          retry_prev_backoff_ms: nil,
          retry_circuit_open?: false,
          recovery_blocked?: false,
          source_loss_since_ms: 100,
          source_loss_signal: :reconnecting
        })

      next = RouteHandler.mark_terminal_failure(data, "NDI_DISABLED")

      assert next.recovery_blocked? == true
      assert next.retry_scheduled? == false
      assert next.source_loss_since_ms == nil

      assert RouteHandler.schedule_retry_restart(next) == next
      refute_receive :retry_start, 50
    end
  end

  describe "exit_status precision: the route_terminal's retryable flag decides, not the exit code (stubbed runtime status)" do
    setup do
      :meck.new(HydraSrt.Db, [:passthrough])
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

      :meck.expect(HydraSrt, :mark_route_failed, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_started, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_stopped, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_terminated, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :set_route_runtime_status, fn _id, _status -> {:ok, %{}} end)
      :meck.expect(HydraSrt.Db, :update_route_runtime_status, fn _id, _status -> {:ok, %{}} end)

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    test "exit status 0 with no route_terminal on record schedules a retry" do
      port = make_ref()
      data = base_route_data(%{id: "route-exit-zero-retry", port: port, route_terminal: nil})

      assert {:keep_state, next} =
               RouteHandler.handle_event(:info, {port, {:exit_status, 0}}, :started, data)

      assert next.port == nil
      assert next.retry_scheduled? == true
      assert next.retry_attempt == 1
      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end

    test "live statem remains alive after exit status 0 without a route_terminal" do
      route_id = "route-exit-zero-process-#{System.unique_integer([:positive])}"

      route = %{
        "id" => route_id,
        "active_source_id" => nil,
        "sources" => [],
        "destinations" => []
      }

      :meck.expect(HydraSrt.Db, :get_route, fn ^route_id, true -> {:ok, route} end)
      {:ok, pid} = RouteHandler.start_link(%{id: route_id})
      port = make_ref()
      :sys.get_state(pid)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.unlink(pid)
          Process.exit(pid, :kill)
        end
      end)

      :sys.replace_state(pid, fn {_state, data} ->
        {:started,
         %{
           data
           | port: port,
             route: route,
             retry_scheduled?: false,
             retry_attempt: 0,
             retry_prev_backoff_ms: nil
         }}
      end)

      send(pid, {port, {:exit_status, 0}})
      {state, next} = :sys.get_state(pid)

      assert state == :started
      assert Process.alive?(pid)
      assert next.port == nil
      assert next.retry_scheduled? == true
    end

    test "exit status 0 with a retryable route_terminal on record keeps retrying instead of stopping" do
      # Reproduces the wrong-passphrase bug: the native binary emits a
      # RETRYABLE route_terminal and then exits 0 (main.rs returns Ok(()) once
      # route_terminal_emitted() is true). Exit code 0 must not be read as "a
      # normal stop" here - the GenServer has to stay alive and keep retrying.
      port = make_ref()

      data =
        base_route_data(%{
          id: "route-exit-retryable",
          active_source_id: "s1",
          port: port,
          route_terminal: %{
            reason_code: "SRT_AUTH_FAILED",
            retryable: true,
            retry_domain: "route",
            detail: "wrong passphrase",
            observed_at_ms: 1,
            sequence: 1
          }
        })

      assert {:keep_state, next} =
               RouteHandler.handle_event(:info, {port, {:exit_status, 0}}, :started, data)

      assert next.port == nil
      assert next.retry_scheduled? == true
      assert next.retry_attempt == 1
      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end

    test "exit status 0 with a non-retryable route_terminal on record does not schedule a retry" do
      port = make_ref()

      data =
        base_route_data(%{
          id: "route-exit-nonretryable",
          active_source_id: "s1",
          port: port,
          route_terminal: %{
            reason_code: "SRT_CONNECT_REFUSED",
            retryable: false,
            retry_domain: nil,
            detail: "refused",
            observed_at_ms: 1,
            sequence: 1
          }
        })

      assert {:keep_state, next} =
               RouteHandler.handle_event(:info, {port, {:exit_status, 0}}, :started, data)

      assert next.port == nil
      assert next.retry_scheduled? == false
      assert next.recovery_blocked? == false
      refute_receive :retry_start, 50
    end

    test "exit status non-zero still drives the hard-retry path exactly as before" do
      port = make_ref()
      data = base_route_data(%{id: "route-exit-nonzero", active_source_id: "s1", port: port})

      assert {:keep_state, next} =
               RouteHandler.handle_event(:info, {port, {:exit_status, 1}}, :started, data)

      assert next.port == nil
      assert next.retry_scheduled? == true
      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end

    test "port EXIT with :epipe hard-retries instead of latching the route stopped" do
      # A broken pipe on our own write side (the far end of the port's stdin
      # already closed under us) is not "the stream ended by design" the way
      # a clean `:normal` exit is - it is this process losing its native
      # pipeline out from under a route whose source may still be perfectly
      # alive, so it must never park the route "stopped" with no retry.
      port = make_ref()
      data = base_route_data(%{id: "route-epipe", active_source_id: "s1", port: port})

      assert {:keep_state, next} =
               RouteHandler.handle_event(:info, {:EXIT, port, :epipe}, :started, data)

      assert next.port == nil
      assert next.retry_scheduled? == true
      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end

    test "port EXIT with :normal schedules a retry" do
      port = make_ref()
      data = base_route_data(%{id: "route-normal-exit-retry", active_source_id: "s1", port: port})

      assert {:keep_state, next} =
               RouteHandler.handle_event(:info, {:EXIT, port, :normal}, :started, data)

      assert next.port == nil
      assert next.retry_scheduled? == true
      assert next.retry_attempt == 1
      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end
  end

  test "schedule_retry_restart uses backoff and sets single retry timer" do
    data = %{
      id: "route-retry-1",
      active_source_id: "s1",
      retry_scheduled?: false,
      retry_attempt: 0,
      retry_prev_backoff_ms: nil,
      retry_circuit_open?: false,
      recovery_blocked?: false
    }

    next = RouteHandler.schedule_retry_restart(data)

    assert next.retry_scheduled? == true
    assert next.retry_attempt == 1
    assert is_integer(next.retry_prev_backoff_ms)
    assert next.retry_prev_backoff_ms >= :timer.seconds(1)
    assert next.retry_prev_backoff_ms <= :timer.seconds(30)

    # Second call while scheduled is a no-op (single-owner).
    assert RouteHandler.schedule_retry_restart(next) == next

    assert_receive :retry_start, next.retry_prev_backoff_ms + 100
  end

  test "policy_deny_reason? recognizes NDI_DISABLED" do
    assert RouteHandler.policy_deny_reason?("NDI_DISABLED")
    refute RouteHandler.policy_deny_reason?("other")
    refute RouteHandler.policy_deny_reason?(:enoent)
  end

  test "sink_from_record includes destination id and name for SRT" do
    record = %{
      "id" => "dest1",
      "name" => "Destination 1",
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4202,
      "mode" => "caller",
      "streamid" => "#!::r=destination"
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    assert sink["id"] == "dest1"
    assert sink["name"] == "Destination 1"
    assert sink["kind"] == "srt"
    assert sink["srt"]["mode"] == "caller"
    assert sink["srt"]["streamid"] == "#!::r=destination"

    assert URI.decode_query(URI.parse(sink["srt"]["uri"]).query)["streamid"] ==
             "#!::r=destination"

    refute Map.has_key?(sink["srt"], "access")
  end

  test "sink_from_record does not send preserved streamid to a listener pipeline" do
    record = %{
      "id" => "dest-listener",
      "schema" => "SRT",
      "localaddress" => "127.0.0.1",
      "localport" => 4202,
      "mode" => "listener",
      "streamid" => "#!::r=preserved"
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    refute Map.has_key?(sink["srt"], "streamid")
    refute URI.decode_query(URI.parse(sink["srt"]["uri"]).query) |> Map.has_key?("streamid")
  end

  test "sink_from_record includes destination id and name for UDP" do
    record = %{
      "id" => "dest2",
      "name" => "Destination 2",
      "schema" => "UDP",
      "host" => "127.0.0.1",
      "port" => 4203
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    assert sink["id"] == "dest2"
    assert sink["name"] == "Destination 2"
    assert sink["kind"] == "udp"
    assert sink["udp"] == %{"address" => "127.0.0.1", "port" => 4203}
  end

  test "sink_from_record returns error for RTMP destination without location" do
    record = %{
      "id" => "dest-rtmp",
      "enabled" => true,
      "name" => "RTMP destination",
      "schema" => "RTMP"
    }

    assert {:error, :invalid_destination} = RouteHandler.sink_from_record(record)
  end

  test "sink_from_record includes destination id and name for RTMP" do
    record = %{
      "id" => "dest-rtmp",
      "enabled" => true,
      "name" => "RTMP destination",
      "schema" => "RTMP",
      "location" => "rtmp://127.0.0.1:1935/live/stream"
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)

    assert sink == %{
             "id" => "dest-rtmp",
             "name" => "RTMP destination",
             "kind" => "rtmp",
             "rtmp" => %{"location" => "rtmp://127.0.0.1:1935/live/stream"}
           }
  end

  test "sink_from_record keeps udp bind and multicast interface properties" do
    record = %{
      "id" => "dest3",
      "name" => "Destination 3",
      "schema" => "UDP",
      "host" => "239.1.1.1",
      "port" => 5004,
      "bind_address_option" => "10.10.0.2",
      "multicast_iface" => "eno2"
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    assert sink["kind"] == "udp"

    assert sink["udp"] == %{
             "address" => "239.1.1.1",
             "port" => 5004,
             "bind_address" => "10.10.0.2",
             "multicast_iface" => "eno2"
           }
  end

  test "sink_from_record drops bind-address for IPv6 multicast with link-local interface ip" do
    record = %{
      "id" => "dest4",
      "name" => "Destination 4",
      "schema" => "UDP",
      "host" => "ff15::1234",
      "port" => 5000,
      "bind_address_option" => "fe80::ae1f:6bff:febd:5295",
      "multicast_iface" => "eno2"
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)

    assert sink == %{
             "id" => "dest4",
             "name" => "Destination 4",
             "kind" => "udp",
             "udp" => %{
               "address" => "ff15::1234",
               "port" => 5000,
               "multicast_iface" => "eno2"
             }
           }
  end

  test "sinks_from_record skips disabled destinations" do
    record = %{
      "destinations" => [
        %{
          "id" => "dest-enabled",
          "enabled" => true,
          "name" => "Enabled destination",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4203
        },
        %{
          "id" => "dest-disabled",
          "enabled" => false,
          "name" => "Disabled destination",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4204
        }
      ]
    }

    assert {:ok, [sink]} = RouteHandler.sinks_from_record(record)
    assert sink["id"] == "dest-enabled"
  end

  test "sinks_from_record includes only explicitly enabled destinations" do
    record = %{
      "destinations" => [
        %{
          "id" => "dest-enabled",
          "enabled" => true,
          "name" => "Enabled destination",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4203
        },
        %{
          "id" => "dest-missing-enabled",
          "name" => "Missing enabled flag",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4204
        },
        %{
          "id" => "dest-nil-enabled",
          "enabled" => nil,
          "name" => "Nil enabled flag",
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4205
        }
      ]
    }

    assert {:ok, [sink]} = RouteHandler.sinks_from_record(record)
    assert sink["id"] == "dest-enabled"
  end

  test "sinks_from_record preserves declared destination order" do
    record = %{
      "destinations" => [
        %{
          "id" => "dest-first",
          "enabled" => true,
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4203
        },
        %{
          "id" => "dest-second",
          "enabled" => true,
          "schema" => "UDP",
          "host" => "127.0.0.1",
          "port" => 4204
        }
      ]
    }

    assert {:ok, sinks} = RouteHandler.sinks_from_record(record)

    assert Enum.map(sinks, & &1["id"]) == [
             "dest-first",
             "dest-second"
           ]
  end

  test "build_config emits typed per-kind endpoints" do
    source_record = %{"id" => "source-1", "name" => "Source One", "schema" => "SRT"}

    source = %{
      "kind" => "srt",
      "srt" => %{
        "uri" => "srt://127.0.0.1:4201?mode=listener",
        "mode" => "listener",
        "latency" => 200,
        "localaddress" => "127.0.0.1",
        "localport" => 4201
      }
    }

    first_sink = %{
      "id" => "dest-first",
      "name" => "First",
      "kind" => "srt",
      "srt" => %{
        "uri" => "srt://127.0.0.1:4202?mode=caller",
        "mode" => "caller"
      }
    }

    second_sink = %{
      "id" => "dest-second",
      "name" => "Second",
      "kind" => "udp",
      "udp" => %{"address" => "127.0.0.1", "port" => 4203}
    }

    config =
      RouteHandler.build_config(
        "route-1",
        source_record,
        source,
        [first_sink, second_sink]
      )

    assert config["route_id"] == "route-1"
    refute Map.has_key?(config, "processing_profiles")
    assert "boot-" <> revision = config["config_revision"]
    assert {:ok, _} = Ecto.UUID.cast(revision)
    assert {:ok, _} = Ecto.UUID.cast(config["process_instance_id"])

    assert config["source"] == %{
             "id" => "source-1",
             "name" => "Source One",
             "kind" => "srt",
             "srt" => source["srt"]
           }

    refute Map.has_key?(config["source"], "legacy")
    refute Map.has_key?(config["source"], "element_type")

    assert Enum.map(config["destinations"], & &1["id"]) == ["dest-first", "dest-second"]

    assert config["destinations"] == [
             %{
               "id" => "dest-first",
               "name" => "First",
               "kind" => "srt",
               "srt" => first_sink["srt"]
             },
             %{
               "id" => "dest-second",
               "name" => "Second",
               "kind" => "udp",
               "udp" => second_sink["udp"]
             }
           ]
  end

  test "native_route_args emits the route CLI contract" do
    assert RouteHandler.native_route_args("route-1", "piid-1") == [
             "route",
             "--route-id",
             "route-1",
             "--process-instance-id",
             "piid-1"
           ]
  end

  test "build_config creates fresh spawn identities" do
    source_record = %{"id" => "source-1", "schema" => "UDP"}
    source = %{"kind" => "udp", "udp" => %{"address" => "127.0.0.1", "port" => 4201}}

    first = RouteHandler.build_config("route-1", source_record, source, [])
    second = RouteHandler.build_config("route-1", source_record, source, [])

    refute first["config_revision"] == second["config_revision"]
    refute first["process_instance_id"] == second["process_instance_id"]
  end

  test "callback_mode returns handle_event_function" do
    assert RouteHandler.callback_mode() == [:handle_event_function]
  end

  test "parse_native_json_line detects pipeline status events" do
    assert {:pipeline_status, "processing", nil} =
             RouteHandler.parse_native_json_line(
               ~s({"event":"pipeline_status","status":"processing"})
             )
  end

  test "parse_native_json_line keeps stats payloads separate" do
    assert {:stats, %{"source" => %{"bytes_in_per_sec" => 123}, "destinations" => []}} =
             RouteHandler.parse_native_json_line(
               ~s({"source":{"bytes_in_per_sec":123},"destinations":[]})
             )
  end

  test "stats_events includes snapshot and extracts input and destination output bytes per second" do
    stats = %{
      "source" => %{"bytes_in_per_sec" => 191_572},
      "destinations" => [
        %{"id" => "dest-1", "bytes_out_per_sec" => 186_684},
        %{"id" => "dest-2", "bytes_out_per_sec" => 92_000},
        %{"id" => "dest-ignored"},
        %{"bytes_out_per_sec" => 1_000}
      ]
    }

    assert RouteHandler.stats_events(stats, "route-1") == [
             %{
               route_id: "route-1",
               metric: "snapshot",
               stats: stats
             },
             %{
               route_id: "route-1",
               direction: "in",
               metric: "bytes_per_sec",
               value: 191_572
             },
             %{
               route_id: "route-1",
               destination_id: "dest-1",
               direction: "out",
               metric: "bytes_per_sec",
               value: 186_684
             },
             %{
               route_id: "route-1",
               destination_id: "dest-2",
               direction: "out",
               metric: "bytes_per_sec",
               value: 92_000
             }
           ]
  end

  test "publish_stats broadcasts snapshot and bytes per second on stats topics" do
    Phoenix.PubSub.subscribe(HydraSrt.PubSub, "stats")

    stats = %{
      "source" => %{"bytes_in_per_sec" => 191_572},
      "destinations" => [%{"id" => "dest-1", "bytes_out_per_sec" => 186_684}]
    }

    assert :ok =
             RouteHandler.publish_stats("route-1", stats)

    assert_receive {:stats,
                    %{
                      route_id: "route-1",
                      metric: "snapshot",
                      stats: ^stats
                    }}

    assert_receive {:stats,
                    %{
                      route_id: "route-1",
                      direction: "in",
                      metric: "bytes_per_sec",
                      value: 191_572
                    }}

    assert_receive {:stats,
                    %{
                      route_id: "route-1",
                      destination_id: "dest-1",
                      direction: "out",
                      metric: "bytes_per_sec",
                      value: 186_684
                    }}
  end

  test "parse_native_json_line keeps status reason when present" do
    assert {:pipeline_status, "stopped", "failure"} =
             RouteHandler.parse_native_json_line(
               ~s({"event":"pipeline_status","status":"stopped","reason":"failure"})
             )
  end

  test "normalize_runtime_status ignores stopped failure event to preserve failed state" do
    assert :ignore = RouteHandler.normalize_runtime_status("stopped", "failure")
    assert {:update, "failed"} = RouteHandler.normalize_runtime_status("failed", "runtime_error")
    assert {:update, "processing"} = RouteHandler.normalize_runtime_status("processing", nil)

    assert {:update, "processing"} =
             RouteHandler.normalize_runtime_status("processing", nil, %{recovering?: true})
  end

  test "failed runtime status is preserved when binary exits with non-zero code" do
    # Rust emits `failed` then immediately `stopped/failure` before the OS process dies.
    # The two parse steps produce distinct tuples...
    assert {:pipeline_status, "failed", "runtime_error"} =
             RouteHandler.parse_native_json_line(
               ~s({"event":"pipeline_status","status":"failed","reason":"runtime_error"})
             )

    assert {:pipeline_status, "stopped", "failure"} =
             RouteHandler.parse_native_json_line(
               ~s({"event":"pipeline_status","status":"stopped","reason":"failure"})
             )

    # ...and the normalization layer updates on the first event but ignores the second,
    # so the DB value stays "failed" rather than being overwritten with "stopped".
    assert {:update, "failed"} = RouteHandler.normalize_runtime_status("failed", "runtime_error")
    assert :ignore = RouteHandler.normalize_runtime_status("stopped", "failure")
  end

  test "normalize_runtime_status ignores a legacy 'failed' status while a hard retry is armed" do
    # A hard retry already schedules and writes the truthful
    # "restarting"/"reconnecting" status before the native pipeline's own
    # legacy `pipeline_status \"failed\"` line for the same cycle is
    # processed. Without this, the route flip-flopped
    # restarting -> failed -> restarting on every single retry cycle and
    # wrote an extra route_status_change row each time.
    assert :ignore =
             RouteHandler.normalize_runtime_status("failed", "runtime_error", %{
               retry_scheduled?: true
             })

    # No retry in flight (genuinely terminal, or unclassified) - the truthful
    # "failed" status is written, exactly like the arity-2 (no `data`) form.
    assert {:update, "failed"} =
             RouteHandler.normalize_runtime_status("failed", "runtime_error", %{
               retry_scheduled?: false
             })
  end

  test "a legacy 'failed' pipeline_status carries the real route_terminal reason, not the generic bucket" do
    :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

    test_pid = self()

    :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_failed, fn route_id,
                                                                      source_id,
                                                                      reason,
                                                                      message ->
      send(test_pid, {:log_pipeline_failed, route_id, source_id, reason, message})
      :ok
    end)

    on_exit(fn -> :meck.unload() end)

    data =
      base_route_data(%{
        id: "route-legacy-failed",
        active_source_id: "s1",
        retry_scheduled?: true,
        route_terminal: %{
          reason_code: "SRT_AUTH_FAILED",
          retryable: true,
          retry_domain: "none",
          detail: "Failed to authenticate: Incorrect passphrase",
          observed_at_ms: nil,
          sequence: nil
        }
      })

    line = ~s({"event":"pipeline_status","status":"failed","reason":"runtime_error"})
    _ = RouteHandler.process_port_line(line, data)

    assert_receive {:log_pipeline_failed, "route-legacy-failed", "s1", "SRT_AUTH_FAILED", _}
  end

  describe "process_port_line pipeline logs" do
    @valid_gstreamer_line "0:00:00.123456789 1234 0x7f8b9c000b70 WARN srt src/srt.c:123:srt_connect:<srt-src> connection failed"

    setup do
      test_pid = self()
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "pipeline_logs")

      unparsed_handler = "route-handler-unparsed-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          unparsed_handler,
          HydraSrt.PipelineLogTelemetry.unparsed_event(),
          fn event, measurements, metadata, receiver ->
            send(receiver, {:telemetry_unparsed, event, measurements, metadata})
          end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(unparsed_handler) end)

      {:ok, data: %{id: "route-handler-pl-1", port_buffer: ""}}
    end

    test "broadcasts parsed GStreamer line on pipeline_logs pubsub", %{data: data} do
      RouteHandler.consume_port_output(@valid_gstreamer_line <> "\n", data)

      assert_receive {:pipeline_log, log}
      assert log.route_id == "route-handler-pl-1"
      assert log.level == "WARN"
      assert log.category == "srt"
      assert log.message == "connection failed"
    end

    test "emits unparsed telemetry for non-GStreamer lines", %{data: data} do
      RouteHandler.consume_port_output("not a gstreamer log line\n", data)

      refute_receive {:pipeline_log, _}, 50

      assert_receive {:telemetry_unparsed, _event, %{count: 1}, %{route_id: "route-handler-pl-1"}}
    end

    test "broadcasts native SRT access events on pipeline_logs pubsub", %{data: data} do
      RouteHandler.consume_port_output(
        ~s({"event":"srt_access","ip":"127.0.0.1","stream_id":"test","allowed":false,"reason":"denied_list"}) <>
          "\n",
        data
      )

      assert_receive {:pipeline_log, log}
      assert log.route_id == "route-handler-pl-1"
      assert log.level == "WARN"
      assert log.category == "srt_access"
      assert log.element == "srtsrc"
      assert log.message =~ "ip=127.0.0.1"
      assert log.message =~ "stream_id=test"
      assert log.message =~ "allowed=false"
      assert log.message =~ "reason=denied_list"
    end
  end

  describe "NDI source and destination mapping" do
    test "source_from_record maps discovery_name mode with W1 defaults" do
      route = %{"id" => "route-ndi", "name" => "Studio A"}

      record = %{
        "id" => "src-ndi",
        "schema" => "NDI",
        "ndi_selection_mode" => "discovery_name",
        "ndi_source_name" => "MACHINE (CHANNEL)"
      }

      assert {:ok, source} = RouteHandler.source_from_record(record, route)
      assert source["kind"] == "ndi"

      assert source["ndi"] == %{
               "source_name" => "MACHINE (CHANNEL)",
               "receiver_name" => "Hydra Studio A",
               "bandwidth" => "highest",
               "color_format" => "uyvy-bgra",
               "media_policy" => "video_and_audio_required",
               "connect_timeout_ms" => 10_000,
               "receive_timeout_ms" => 5_000,
               "track_discovery_timeout_ms" => 10_000,
               "max_queue_length" => 4
             }

      refute Map.has_key?(source["ndi"], "url_address")
      refute Map.has_key?(source["ndi"], "timestamp_mode")
    end

    test "source_from_record maps direct_address mode and preserves explicit options" do
      route = %{"id" => "route-ndi", "name" => "Studio B"}

      record = %{
        "id" => "src-ndi",
        "schema" => "NDI",
        "ndi_selection_mode" => "direct_address",
        "ndi_source_address" => "192.0.2.10:5960",
        "ndi_receiver_name" => "Custom Receiver",
        "ndi_bandwidth" => "audio_only",
        "ndi_color_format" => "best",
        "ndi_timestamp_mode" => "receive-time-vs-timestamp",
        "ndi_media_policy" => "audio_only",
        "ndi_connect_timeout_ms" => 2000,
        "ndi_receive_timeout_ms" => 3000,
        "ndi_track_discovery_timeout_ms" => 4000,
        "ndi_max_queue_length" => 8
      }

      assert {:ok, source} = RouteHandler.source_from_record(record, route)
      assert source["kind"] == "ndi"

      assert source["ndi"] == %{
               "url_address" => "192.0.2.10:5960",
               "receiver_name" => "Custom Receiver",
               "bandwidth" => "audio_only",
               "color_format" => "best",
               "timestamp_mode" => "receive-time-vs-timestamp",
               "media_policy" => "audio_only",
               "connect_timeout_ms" => 2000,
               "receive_timeout_ms" => 3000,
               "track_discovery_timeout_ms" => 4000,
               "max_queue_length" => 8
             }

      refute Map.has_key?(source["ndi"], "source_name")
    end

    test "sink_from_record maps NDI destination sender_name and media_policy default" do
      record = %{
        "id" => "dest-ndi",
        "name" => "NDI Out",
        "schema" => "NDI",
        "ndi_sender_name" => "Hydra (Route Output)"
      }

      assert {:ok, sink} = RouteHandler.sink_from_record(record)

      assert sink == %{
               "id" => "dest-ndi",
               "name" => "NDI Out",
               "kind" => "ndi",
               "ndi" => %{
                 "sender_name" => "Hydra (Route Output)",
                 "media_policy" => "video_and_audio_required"
               }
             }
    end

    test "build_config emits typed NDI source and destinations" do
      source_record = %{"id" => "src-ndi", "name" => "NDI In", "schema" => "NDI"}

      source = %{
        "kind" => "ndi",
        "ndi" => %{
          "source_name" => "MACHINE (CHANNEL)",
          "receiver_name" => "Hydra Studio A",
          "bandwidth" => "highest",
          "color_format" => "uyvy-bgra",
          "media_policy" => "video_and_audio_required",
          "connect_timeout_ms" => 10_000,
          "receive_timeout_ms" => 5_000,
          "track_discovery_timeout_ms" => 10_000,
          "max_queue_length" => 4
        }
      }

      sink = %{
        "id" => "dest-ndi",
        "name" => "NDI Out",
        "kind" => "ndi",
        "ndi" => %{
          "sender_name" => "Hydra (Route Output)",
          "media_policy" => "video_and_audio_required"
        }
      }

      config = RouteHandler.build_config("route-ndi", source_record, source, [sink])

      assert config["source"] == %{
               "id" => "src-ndi",
               "name" => "NDI In",
               "kind" => "ndi",
               "ndi" => source["ndi"]
             }

      assert config["destinations"] == [
               %{
                 "id" => "dest-ndi",
                 "name" => "NDI Out",
                 "kind" => "ndi",
                 "ndi" => sink["ndi"]
               }
             ]
    end
  end

  describe "NDI feature policy start gate" do
    setup do
      previous = Application.get_env(:hydra_srt, :ndi)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:hydra_srt, :ndi)
        else
          Application.put_env(:hydra_srt, :ndi, previous)
        end
      end)

      :ok
    end

    test "ensure_ndi_start_allowed denies NDI source when receive is disabled" do
      Application.put_env(:hydra_srt, :ndi, enabled: true, receive: false, send: true)

      route = %{
        "destinations" => [
          %{
            "id" => "dest-ndi",
            "enabled" => true,
            "schema" => "NDI",
            "ndi_sender_name" => "Out"
          }
        ]
      }

      source = %{"schema" => "NDI"}

      assert {:error, "NDI_DISABLED"} = RouteHandler.ensure_ndi_start_allowed(route, source)
    end

    test "ensure_ndi_start_allowed denies NDI destination when send is disabled" do
      Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: false)

      route = %{
        "destinations" => [
          %{
            "id" => "dest-ndi",
            "enabled" => true,
            "schema" => "NDI",
            "ndi_sender_name" => "Out"
          }
        ]
      }

      source = %{"schema" => "SRT"}

      assert {:error, "NDI_DISABLED"} = RouteHandler.ensure_ndi_start_allowed(route, source)
    end

    test "ensure_ndi_start_allowed allows non-NDI routes regardless of flags" do
      Application.put_env(:hydra_srt, :ndi, enabled: false, receive: false, send: false)

      route = %{
        "destinations" => [
          %{"id" => "dest-udp", "enabled" => true, "schema" => "UDP"}
        ]
      }

      source = %{"schema" => "SRT"}

      assert :ok = RouteHandler.ensure_ndi_start_allowed(route, source)
    end

    test "ensure_ndi_start_allowed allows NDI when enabled receive and send match" do
      Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: true)

      route = %{
        "destinations" => [
          %{
            "id" => "dest-ndi",
            "enabled" => true,
            "schema" => "NDI",
            "ndi_sender_name" => "Out"
          }
        ]
      }

      source = %{"schema" => "NDI"}

      assert :ok = RouteHandler.ensure_ndi_start_allowed(route, source)
    end
  end

  describe "strict destination validation" do
    test "sinks_from_record aggregates every failing enabled destination id" do
      record = %{
        "destinations" => [
          %{
            "id" => "dest-ok",
            "enabled" => true,
            "schema" => "UDP",
            "host" => "127.0.0.1",
            "port" => 4203
          },
          %{
            "id" => "dest-bad-rtmp",
            "enabled" => true,
            "schema" => "RTMP"
          },
          %{
            "id" => "dest-bad-ndi",
            "enabled" => true,
            "schema" => "NDI"
          },
          %{
            "id" => "dest-disabled-bad",
            "enabled" => false,
            "schema" => "RTMP"
          }
        ]
      }

      assert {:error, {:invalid_destinations, ["dest-bad-rtmp", "dest-bad-ndi"]}} =
               RouteHandler.sinks_from_record(record)
    end
  end

  describe "endpoint_health and route_terminal events" do
    test "parse_native_json_line recognizes endpoint_health and route_terminal" do
      health =
        Jason.encode!(%{
          "event" => "endpoint_health",
          "route_id" => "route-1",
          "process_instance_id" => "piid-1",
          "endpoint_id" => "ep-1",
          "state" => "connecting"
        })

      terminal =
        Jason.encode!(%{
          "event" => "route_terminal",
          "route_id" => "route-1",
          "process_instance_id" => "piid-1",
          "reason_code" => "NDI_RECEIVE_TIMEOUT",
          "retryable" => true,
          "retry_domain" => "route"
        })

      assert {:endpoint_health, %{"endpoint_id" => "ep-1"}} =
               RouteHandler.parse_native_json_line(health)

      assert {:route_terminal, %{"reason_code" => "NDI_RECEIVE_TIMEOUT", "retryable" => true}} =
               RouteHandler.parse_native_json_line(terminal)
    end

    test "consume_port_output stores matching endpoint_health and broadcasts on item topic" do
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "item:route-health-1")

      data = %{
        id: "route-health-1",
        process_instance_id: "piid-live",
        active_source_id: "ep-src",
        source_data_seen?: false,
        endpoint_health: %{},
        route_terminal: nil,
        port_buffer: ""
      }

      payload = %{
        "event" => "endpoint_health",
        "route_id" => "route-health-1",
        "process_instance_id" => "piid-live",
        "endpoint_id" => "ep-src",
        "direction" => "source",
        "state" => "streaming",
        "sequence" => 3
      }

      next = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert next.endpoint_health["ep-src"]["state"] == "streaming"
      assert next.source_data_seen?
      assert_receive {:endpoint_health, ^payload}
    end

    test "consume_port_output drops stale endpoint_health without broadcasting" do
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "item:route-health-2")

      data = %{
        id: "route-health-2",
        process_instance_id: "piid-live",
        endpoint_health: %{},
        route_terminal: nil,
        port_buffer: ""
      }

      payload = %{
        "event" => "endpoint_health",
        "route_id" => "route-health-2",
        "process_instance_id" => "piid-stale",
        "endpoint_id" => "ep-src",
        "state" => "failed"
      }

      next = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert next.endpoint_health == %{}
      refute_receive {:endpoint_health, _}, 50
    end
  end

  describe "YouTube media info persistence" do
    setup do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(HydraSrt.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
      :ok
    end

    test "keeps resolver metadata when a pipeline media info event arrives" do
      {data, source} = youtube_context()

      announced = %{
        "video" => %{"codec" => "announced", "height" => 360, "width" => 640},
        "audio" => %{"codec" => "announced-audio", "channels" => 2},
        "title" => "fixture title",
        "uploader" => "fixture uploader",
        "duration" => 125,
        "format_id" => "22"
      }

      data =
        RouteHandler.persist_resolved_media_for_source(data, source.id, %{
          live: true,
          uri: "https://example.test/fixture.m3u8",
          media_info: announced
        })

      pipeline_info = %{
        "video" => %{"codec" => "H.264", "fps" => 30.0, "height" => 720, "width" => 1280},
        "audio" => %{"codec" => "AAC", "channels" => 2, "rate" => 44_100}
      }

      RouteHandler.apply_media_info_event(
        data,
        youtube_event(data, pipeline_info, 1_700_000_000_000)
      )

      stored = HydraSrt.Repo.get!(Endpoint, source.id)
      media_info = stored.youtube_media_info

      assert media_info["title"] == "fixture title"
      assert media_info["uploader"] == "fixture uploader"
      assert media_info["format_id"] == "22"
      assert is_binary(media_info["last_refresh_at"])
      assert media_info["video"] == pipeline_info["video"]
      assert media_info["audio"] == pipeline_info["audio"]
    end

    test "keeps observed lanes when a resolver refresh has no lane data" do
      {data, source} = youtube_context()

      observed = %{
        "video" => %{"codec" => "H.264", "height" => 1080, "width" => 1920},
        "audio" => %{"codec" => "AAC", "channels" => 2}
      }

      RouteHandler.apply_media_info_event(data, youtube_event(data, observed, 1_700_000_001_000))

      RouteHandler.persist_resolved_media_for_source(data, source.id, %{
        live: true,
        uri: "https://example.test/refresh.m3u8",
        media_info: %{"title" => "refreshed title", "video" => nil, "audio" => %{}}
      })

      stored = HydraSrt.Repo.get!(Endpoint, source.id)

      assert stored.youtube_media_info["title"] == "refreshed title"
      assert stored.youtube_media_info["video"] == observed["video"]
      assert stored.youtube_media_info["audio"] == observed["audio"]
    end

    test "replaces a changed pipeline video lane instead of merging its fields" do
      {data, source} = youtube_context()

      first = %{
        "video" => %{"codec" => "H.264", "height" => 720, "width" => 1280},
        "audio" => %{"codec" => "AAC", "channels" => 2}
      }

      second = %{
        "video" => %{"codec" => "H.265", "width" => 1920},
        "audio" => %{"codec" => "AAC", "channels" => 2}
      }

      RouteHandler.apply_media_info_event(data, youtube_event(data, first, 1_700_000_002_000))
      RouteHandler.apply_media_info_event(data, youtube_event(data, second, 1_700_000_003_000))

      stored = HydraSrt.Repo.get!(Endpoint, source.id)

      assert stored.youtube_media_info["video"] == second["video"]
      refute Map.has_key?(stored.youtube_media_info["video"], "height")
    end

    test "broadcasts the merged media info with pipeline health" do
      {data, source} = youtube_context()

      announced = %{
        "video" => %{"codec" => "announced", "height" => 360, "declared_bitrate_kbps" => 2969},
        "audio" => %{"codec" => "announced-audio", "declared_bitrate_kbps" => 130},
        "title" => "broadcast title",
        "uploader" => "broadcast uploader",
        "format_id" => "18"
      }

      RouteHandler.persist_resolved_media_for_source(data, source.id, %{
        live: true,
        uri: "https://example.test/broadcast.m3u8",
        media_info: announced
      })

      before_event = HydraSrt.Repo.get!(Endpoint, source.id).youtube_media_info

      pipeline_info = %{
        "video" => %{"codec" => "H.264", "height" => 720, "width" => 1280},
        "audio" => %{"codec" => "AAC", "channels" => 2}
      }

      expected_media_info =
        before_event
        |> Map.put("video", Map.put(pipeline_info["video"], "declared_bitrate_kbps", 2969))
        |> Map.put("audio", Map.put(pipeline_info["audio"], "declared_bitrate_kbps", 130))

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "item:" <> data.id)

      next =
        RouteHandler.apply_media_info_event(
          data,
          youtube_event(data, pipeline_info, 1_700_000_004_000)
        )

      assert next.endpoint_health[source.id]["youtube_media_info"] == expected_media_info
      assert_receive {:endpoint_health, %{"youtube_media_info" => ^expected_media_info}}
    end

    test "observed metadata preserves declared lane bitrates" do
      existing = %{
        "video" => %{"codec" => "announced video", "declared_bitrate_kbps" => 2969},
        "audio" => %{"codec" => "announced audio", "declared_bitrate_kbps" => 130}
      }

      incoming = %{
        "video" => %{"codec" => "measured video", "bitrate_kbps" => 948},
        "audio" => %{"codec" => "measured audio", "bitrate_kbps" => 130}
      }

      assert RouteHandler.merge_youtube_media_info(existing, incoming, :observed) == %{
               "video" => %{
                 "codec" => "measured video",
                 "bitrate_kbps" => 948,
                 "declared_bitrate_kbps" => 2969
               },
               "audio" => %{
                 "codec" => "measured audio",
                 "bitrate_kbps" => 130,
                 "declared_bitrate_kbps" => 130
               }
             }
    end

    test "announced metadata replaces non-empty lanes but preserves empty or invalid lanes" do
      existing = %{
        "title" => "old title",
        "video" => %{"codec" => "old video"},
        "audio" => %{"codec" => "old audio"}
      }

      incoming = %{
        "title" => "new title",
        "video" => %{},
        "audio" => "not a lane",
        "format_id" => "22"
      }

      assert RouteHandler.merge_youtube_media_info(existing, incoming, :announced) == %{
               "title" => "new title",
               "video" => %{"codec" => "old video"},
               "audio" => %{"codec" => "old audio"},
               "format_id" => "22"
             }
    end

    test "observed metadata replaces known lanes while preserving announced fields and unknown keys" do
      existing = %{
        "title" => "announced title",
        "format_id" => "22",
        "video" => %{"codec" => "old video"},
        "audio" => %{"codec" => "old audio"},
        "resolver_only" => "keep me"
      }

      incoming = %{
        "title" => "pipeline title",
        "video" => %{"codec" => "new video"},
        "audio" => nil
      }

      assert RouteHandler.merge_youtube_media_info(existing, incoming, :observed) == %{
               "title" => "announced title",
               "format_id" => "22",
               "video" => %{"codec" => "new video"},
               "audio" => %{"codec" => "old audio"},
               "resolver_only" => "keep me"
             }
    end

    test "returns not_found without a matching YouTube endpoint" do
      observed_at = ~U[2025-03-01 00:00:00Z]

      assert :not_found =
               RouteHandler.persist_youtube_media_info(
                 "missing-route",
                 "missing-endpoint",
                 true,
                 %{"title" => "ignored"},
                 observed_at,
                 :observed
               )
    end

    test "does not write a non-YouTube endpoint" do
      route = route_fixture()
      source = source_fixture(route)
      before = HydraSrt.Repo.get!(Endpoint, source.id)

      assert :not_found =
               RouteHandler.persist_youtube_media_info(
                 route.id,
                 source.id,
                 true,
                 %{"title" => "must not persist"},
                 ~U[2025-03-01 00:00:00Z],
                 :observed
               )

      after_write = HydraSrt.Repo.get!(Endpoint, source.id)
      assert after_write.youtube_media_info == before.youtube_media_info
      assert after_write.youtube_live_mode == before.youtube_live_mode
    end

    test "drops media info with a mismatched process instance without persistence or broadcast" do
      {data, source} = youtube_context()
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "item:" <> data.id)
      before = HydraSrt.Repo.get!(Endpoint, source.id)
      payload = youtube_event(data, %{"video" => %{"codec" => "stale"}}, 1_700_000_005_000)
      payload = Map.put(payload, "process_instance_id", "stale-process")

      assert RouteHandler.apply_media_info_event(data, payload) == data

      assert HydraSrt.Repo.get!(Endpoint, source.id).youtube_media_info ==
               before.youtube_media_info

      refute_receive {:endpoint_health, _}, 50
    end

    test "drops media info with a mismatched route without persistence or broadcast" do
      {data, source} = youtube_context()
      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "item:" <> data.id)
      before = HydraSrt.Repo.get!(Endpoint, source.id)
      payload = youtube_event(data, %{"video" => %{"codec" => "stale"}}, 1_700_000_006_000)
      payload = Map.put(payload, "route_id", "stale-route")

      assert RouteHandler.apply_media_info_event(data, payload) == data

      assert HydraSrt.Repo.get!(Endpoint, source.id).youtube_media_info ==
               before.youtube_media_info

      refute_receive {:endpoint_health, _}, 50
    end

    test "drops media info for a non-YouTube active source without persistence or broadcast" do
      route = route_fixture()
      source = source_fixture(route)

      data =
        base_route_data(%{
          id: route.id,
          route: %{"sources" => [%{"id" => source.id, "schema" => "UDP"}]},
          active_source_id: source.id,
          process_instance_id: "udp-process"
        })

      Phoenix.PubSub.subscribe(HydraSrt.PubSub, "item:" <> data.id)
      before = HydraSrt.Repo.get!(Endpoint, source.id)
      payload = youtube_event(data, %{"video" => %{"codec" => "not YouTube"}}, 1_700_000_007_000)

      assert RouteHandler.apply_media_info_event(data, payload) == data

      assert HydraSrt.Repo.get!(Endpoint, source.id).youtube_media_info ==
               before.youtube_media_info

      refute_receive {:endpoint_health, _}, 50
    end
  end

  describe "YouTube refresh scheduling" do
    setup do
      :meck.new(HydraSrt.Youtube.RefreshScheduler, [:passthrough])

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    test "adds a refresh time from a URI expiry" do
      observed_at = ~U[2025-03-01 00:00:00Z]
      expires_at = 1_750_000_000

      media_info =
        RouteHandler.add_refresh_times(
          %{"title" => "video"},
          %{
            uri: "https://googlevideo.test/stream?expire=#{expires_at}"
          },
          observed_at
        )

      assert media_info["last_refresh_at"] == "2025-03-01T00:00:00Z"

      assert media_info["next_refresh_at"] ==
               DateTime.to_iso8601(DateTime.from_unix!(expires_at - 10 * 60, :second))
    end

    test "adds only the last refresh time when URI expiry is absent or invalid" do
      observed_at = ~U[2025-03-01 00:00:00Z]

      for uri <- [
            nil,
            "https://googlevideo.test/stream?expire=not-a-number",
            "https://googlevideo.test/videoplayback/12345/file/playlist.m3u8?sig=98765"
          ] do
        media_info =
          RouteHandler.add_refresh_times(
            %{"next_refresh_at" => "stale"},
            %{uri: uri},
            observed_at
          )

        assert media_info == %{"last_refresh_at" => "2025-03-01T00:00:00Z"}
      end
    end

    test "rejects a parsed expiry whose refresh time is already in the past" do
      observed_at = ~U[2025-03-01 00:00:00Z]
      expires_at = DateTime.to_unix(observed_at, :second) + 10 * 60

      media_info =
        RouteHandler.add_refresh_times(
          %{},
          %{uri: "https://googlevideo.test/videoplayback/expire/#{expires_at}/playlist.m3u8"},
          observed_at
        )

      assert media_info == %{"last_refresh_at" => "2025-03-01T00:00:00Z"}
    end

    test "does not schedule refresh for a non-YouTube source" do
      test_pid = self()

      :meck.expect(HydraSrt.Youtube.RefreshScheduler, :schedule, fn url, opts ->
        send(test_pid, {:scheduled, url, opts})
        :ok
      end)

      RouteHandler.schedule_youtube_refresh_for_source(
        %{"schema" => "UDP", "youtube_url" => "https://www.youtube.com/watch?v=fixture"},
        %{uri: "https://example.test/stream.m3u8"}
      )

      refute_receive {:scheduled, _, _}, 50
    end

    test "does not schedule refresh when resolved media has no URI" do
      test_pid = self()

      :meck.expect(HydraSrt.Youtube.RefreshScheduler, :schedule, fn url, opts ->
        send(test_pid, {:scheduled, url, opts})
        :ok
      end)

      RouteHandler.schedule_youtube_refresh_for_source(
        %{"schema" => "YOUTUBE", "youtube_url" => "https://www.youtube.com/watch?v=fixture"},
        %{live: true}
      )

      refute_receive {:scheduled, _, _}, 50
    end
  end

  describe "YouTube event results" do
    setup do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(HydraSrt.Repo, shared: true)
      :meck.new(HydraSrt.Youtube.RefreshScheduler, [:passthrough])
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Db, [:passthrough])
      :meck.new(HydraSrt.Youtube.Cache, [:passthrough])

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
        :meck.unload()
      end)

      :ok
    end

    test "refresh success persists media and requests a route restart" do
      {data, source} = youtube_context()

      data =
        put_in(data.route["sources"], [
          %{"id" => source.id, "schema" => "YOUTUBE", "youtube_url" => source.youtube_url}
        ])

      test_pid = self()

      :meck.expect(HydraSrt.Youtube.RefreshScheduler, :schedule, fn url, opts ->
        send(test_pid, {:scheduled, url, opts})
        :ok
      end)

      media = %{
        live: true,
        uri: "https://example.test/resolved.m3u8",
        media_info: %{"title" => "resolved title"}
      }

      assert {:keep_state, next, [{:next_event, :internal, :start}]} =
               RouteHandler.handle_event(
                 :info,
                 {:youtube_resolved, source.id, {:ok, media}},
                 :started,
                 data
               )

      refute next.youtube_resolution_inflight?
      assert next.route["sources"] |> hd() |> Map.fetch!("youtube_live_mode")

      assert HydraSrt.Repo.get!(Endpoint, source.id).youtube_media_info["title"] ==
               "resolved title"

      assert_receive {:scheduled, "https://www.youtube.com/watch?v=fixture", _}
    end

    test "refresh failure clears inflight state and schedules retry" do
      test_pid = self()

      :meck.expect(HydraSrt, :set_route_runtime_status, fn route_id, status ->
        send(test_pid, {:runtime_status, route_id, status})
        {:ok, %{}}
      end)

      data =
        base_route_data(%{
          id: "youtube-refresh-error",
          active_source_id: "source",
          youtube_resolution_inflight?: true
        })

      assert {:keep_state, next} =
               RouteHandler.handle_event(
                 :info,
                 {:youtube_resolved, "source", {:error, :resolver_down}},
                 :started,
                 data
               )

      refute next.youtube_resolution_inflight?
      assert next.recovering?
      assert next.retry_scheduled?
      assert_receive {:runtime_status, "youtube-refresh-error", "restarting"}
      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end

    test "failover resolution success persists media before an unsuccessful switch" do
      route = route_fixture()
      source = youtube_source_fixture(route, %{position: 1, name: "backup"})
      route_id = route.id
      source_url = source.youtube_url

      data =
        base_route_data(%{
          id: route_id,
          route: %{
            "sources" => [
              %{"id" => "primary", "schema" => "UDP"},
              %{
                "id" => source.id,
                "schema" => "YOUTUBE",
                "youtube_url" => source.youtube_url,
                "enabled" => true,
                "position" => 1
              }
            ]
          },
          active_source_id: "primary",
          process_instance_id: "failover-process"
        })

      test_pid = self()

      :meck.expect(HydraSrt.Youtube.RefreshScheduler, :schedule, fn url, opts ->
        send(test_pid, {:scheduled, url, opts})
        :ok
      end)

      :meck.expect(HydraSrt.Youtube.Cache, :get, fn _video_id, _opts ->
        {:hit, {:ok, %{uri: "https://example.test/cached.m3u8", live: true, media_info: %{}}}}
      end)

      :meck.expect(HydraSrt.Db, :get_route, fn ^route_id, true -> {:error, :not_found} end)

      media = %{
        live: true,
        uri: "https://example.test/failover.m3u8",
        media_info: %{"title" => "backup title"}
      }

      assert {:keep_state, next} =
               RouteHandler.handle_event(
                 :info,
                 {:youtube_failover_resolved, source.id, "source_loss", {:ok, media}},
                 :started,
                 data
               )

      refute next.youtube_failover_inflight?
      assert next.active_source_id == "primary"
      assert HydraSrt.Repo.get!(Endpoint, source.id).youtube_media_info["title"] == "backup title"
      assert_receive {:scheduled, ^source_url, _}
    end

    test "failover resolution failure clears inflight state and schedules retry" do
      test_pid = self()

      :meck.expect(HydraSrt, :set_route_runtime_status, fn route_id, status ->
        send(test_pid, {:runtime_status, route_id, status})
        {:ok, %{}}
      end)

      data = base_route_data(%{id: "youtube-failover-error", youtube_failover_inflight?: true})

      assert {:keep_state, next} =
               RouteHandler.handle_event(
                 :info,
                 {:youtube_failover_resolved, "source", "source_loss", {:error, :resolver_down}},
                 :started,
                 data
               )

      refute next.youtube_failover_inflight?
      assert next.recovering?
      assert next.retry_scheduled?
      assert_receive {:runtime_status, "youtube-failover-error", "restarting"}
      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end
  end

  describe "YouTube terminal policy" do
    setup do
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    test "live YouTube end of stream fails without marking the route completed" do
      test_pid = self()

      :meck.expect(HydraSrt, :mark_route_failed, fn route_id ->
        send(test_pid, {:failed, route_id})
        {:ok, %{}}
      end)

      :meck.expect(HydraSrt, :mark_route_completed, fn route_id ->
        send(test_pid, {:completed, route_id})
        {:ok, %{}}
      end)

      :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_failed, fn _, _, _, _ -> :ok end)

      data =
        base_route_data(%{
          id: "youtube-live-eos",
          active_source_id: "source",
          route: %{
            "active_source_id" => "source",
            "sources" => [%{"id" => "source", "schema" => "YOUTUBE", "youtube_live_mode" => true}]
          }
        })

      next =
        RouteHandler.consume_route_terminal(data, %{
          reason_code: "HLS_COMPLETED",
          retryable: false,
          detail: "end of stream"
        })

      assert next.recovery_blocked?
      assert_receive {:failed, "youtube-live-eos"}
      refute_receive {:completed, _}, 50
    end

    test "VOD YouTube end of stream marks the route completed" do
      test_pid = self()

      :meck.expect(HydraSrt, :mark_route_failed, fn route_id ->
        send(test_pid, {:failed, route_id})
        {:ok, %{}}
      end)

      :meck.expect(HydraSrt, :mark_route_completed, fn route_id ->
        send(test_pid, {:completed, route_id})
        {:ok, %{}}
      end)

      data =
        base_route_data(%{
          id: "youtube-vod-eos",
          active_source_id: "source",
          route: %{
            "active_source_id" => "source",
            "sources" => [
              %{"id" => "source", "schema" => "YOUTUBE", "youtube_live_mode" => false}
            ]
          }
        })

      next =
        RouteHandler.consume_route_terminal(data, %{
          reason_code: "HLS_COMPLETED",
          retryable: false,
          detail: "end of stream"
        })

      assert next.recovery_blocked? == false
      assert next.recovering? == false
      assert_receive {:completed, "youtube-vod-eos"}
      refute_receive {:failed, _}, 50
    end

    test "YouTube checks tolerate a route payload without sources" do
      terminal = %{reason_code: "HLS_COMPLETED", retryable: false}

      refute RouteHandler.youtube_source?(%{"active_source_id" => "source"}, "source")
      refute RouteHandler.completed_terminal?(terminal, %{"active_source_id" => "source"})
    end
  end

  describe "route_terminal recovery paths (stubbed runtime status)" do
    # mark_terminal_failure / mark_restarting_runtime touch HydraSrt + Db + EventLogger;
    # stub the full boundary exactly like route_handler_failover_test — assertions
    # are in-memory only.
    setup do
      :meck.new(HydraSrt.Db, [:passthrough])
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

      :meck.expect(HydraSrt, :mark_route_failed, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_started, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_stopped, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_terminated, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :set_route_runtime_status, fn _id, _status -> {:ok, %{}} end)
      :meck.expect(HydraSrt.Db, :update_route_runtime_status, fn _id, _status -> {:ok, %{}} end)

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    test "consume_port_output stores matching route_terminal for W3b without retrying" do
      data =
        base_route_data(%{
          id: "route-term-1",
          process_instance_id: "piid-live",
          active_source_id: "s1",
          source_loss_since_ms: 42,
          source_loss_signal: :reconnecting
        })

      payload = %{
        "event" => "route_terminal",
        "route_id" => "route-term-1",
        "process_instance_id" => "piid-live",
        "reason_code" => "NDI_SOURCE_EOS",
        "retryable" => false,
        "retry_domain" => "none",
        "detail" => "eos",
        "observed_at_ms" => 1,
        "sequence" => 9
      }

      next = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert next.route_terminal == %{
               reason_code: "NDI_SOURCE_EOS",
               retryable: false,
               retry_domain: "none",
               detail: "eos",
               observed_at_ms: 1,
               sequence: 9
             }

      assert next.recovery_blocked? == true
      assert next.retry_scheduled? == false
      assert next.source_loss_since_ms == nil
      refute_receive :retry_start, 50
    end

    test "retryable route_terminal drives exactly one hard-retry timer" do
      data =
        base_route_data(%{
          id: "route-term-2",
          process_instance_id: "piid-live",
          active_source_id: "s1",
          route: %{"backup_mode" => "passive"},
          source_loss_since_ms: 99,
          source_loss_signal: :zero_bitrate
        })

      payload = %{
        "event" => "route_terminal",
        "route_id" => "route-term-2",
        "process_instance_id" => "piid-live",
        "reason_code" => "NDI_RECEIVE_TIMEOUT",
        "retryable" => true,
        "retry_domain" => "route",
        "detail" => "timeout",
        "observed_at_ms" => 2,
        "sequence" => 10
      }

      next = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert next.route_terminal.reason_code == "NDI_RECEIVE_TIMEOUT"
      assert next.retry_scheduled? == true
      assert next.retry_attempt == 1
      assert next.source_loss_since_ms == nil
      assert next.recovery_blocked? == false

      # Soft path must not also arm while hard-retry owns recovery.
      soft = RouteHandler.observe_source_loss(next, :reconnecting)
      assert soft.source_loss_since_ms == nil
      assert soft.retry_scheduled? == true

      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end

    test "retryable SRT_CONNECT_TIMEOUT route_terminal lands in the hard-retry path" do
      # Regression for the caller-mode SRT connect deadline: a route pointed at
      # an unreachable peer must not sit in "starting" forever. It surfaces as a
      # retryable route_terminal with reason_code "SRT_CONNECT_TIMEOUT" from the
      # native side, and RouteHandler treats it exactly like any other retryable
      # reason code (opaque string) - same hard-retry path as NDI_RECEIVE_TIMEOUT
      # above.
      data =
        base_route_data(%{
          id: "route-term-srt-timeout",
          process_instance_id: "piid-live",
          active_source_id: "s1",
          route: %{"backup_mode" => "passive"},
          source_loss_since_ms: 99,
          source_loss_signal: :zero_bitrate
        })

      payload = %{
        "event" => "route_terminal",
        "route_id" => "route-term-srt-timeout",
        "process_instance_id" => "piid-live",
        "reason_code" => "SRT_CONNECT_TIMEOUT",
        "retryable" => true,
        "retry_domain" => "route",
        "detail" => "SRT caller did not establish a connection before the connect deadline",
        "observed_at_ms" => 3,
        "sequence" => 11
      }

      next = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert next.route_terminal.reason_code == "SRT_CONNECT_TIMEOUT"
      assert next.retry_scheduled? == true
      assert next.retry_attempt == 1
      assert next.source_loss_since_ms == nil
      assert next.recovery_blocked? == false

      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end

    test "single-owner: soft source-loss and hard-retry never double-fire" do
      data =
        base_route_data(%{
          id: "route-owner-1",
          active_source_id: "s1",
          route: %{"backup_mode" => "passive", "backup_switch_after_ms" => 1}
        })

      # Hard-retry arms first.
      hard = RouteHandler.schedule_retry_restart(data)
      assert hard.retry_scheduled? == true

      soft = RouteHandler.observe_source_loss(hard, :zero_bitrate)
      assert soft.source_loss_since_ms == nil
      assert soft.retry_scheduled? == true
      assert soft.retry_attempt == 1

      # Only one :retry_start message.
      assert_receive :retry_start, hard.retry_prev_backoff_ms + 100
      refute_receive :retry_start, 50
    end
  end

  describe "maybe_schedule_hard_retry_after_process_loss idempotency (stubbed runtime status)" do
    # The route_terminal line and the OS exit/EXIT message are two independent
    # reports of the same process death, processed back-to-back in the same
    # retry cycle. Before the idempotency guard, the second one unconditionally
    # re-ran mark_restarting_runtime and clobbered whatever status the
    # route_terminal path had already written (e.g. "reconnecting" once past
    # the retry budget), so the route always rested on "restarting" instead.
    setup do
      :meck.new(HydraSrt.Db, [:passthrough])
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

      :meck.expect(HydraSrt, :mark_route_failed, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_started, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_stopped, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt, :mark_route_terminated, fn _id -> {:ok, %{}} end)
      :meck.expect(HydraSrt.Db, :update_route_runtime_status, fn _id, _status -> {:ok, %{}} end)

      :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_reconnecting, fn _id,
                                                                              _source_id,
                                                                              _reason ->
        :ok
      end)

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    test "retry_scheduled?: true makes the redundant process-loss call a pure no-op" do
      test_pid = self()

      :meck.expect(HydraSrt, :set_route_runtime_status, fn id, status ->
        send(test_pid, {:set_route_runtime_status, id, status})
        {:ok, %{}}
      end)

      data =
        base_route_data(%{
          id: "route-idempotent-1",
          active_source_id: "s1",
          retry_scheduled?: true,
          retry_attempt: 3
        })

      next = RouteHandler.maybe_schedule_hard_retry_after_process_loss(data)

      assert next == data
      refute_receive {:set_route_runtime_status, _, _}, 50
    end

    test "a full retry cycle rests on reconnecting, not restarting, once past the retry budget" do
      test_pid = self()

      :meck.expect(HydraSrt, :set_route_runtime_status, fn id, status ->
        send(test_pid, {:set_route_runtime_status, id, status})
        {:ok, %{}}
      end)

      port = make_ref()

      data =
        base_route_data(%{
          id: "route-idempotent-2",
          process_instance_id: "piid-idempotent-2",
          active_source_id: "s1",
          port: port,
          retry_attempt: 5,
          retry_prev_backoff_ms: :timer.seconds(30)
        })

      payload = %{
        "event" => "route_terminal",
        "route_id" => "route-idempotent-2",
        "process_instance_id" => "piid-idempotent-2",
        "reason_code" => "SRT_CONNECT_TIMEOUT",
        "retryable" => true,
        "retry_domain" => "route",
        "detail" => "deadline",
        "observed_at_ms" => 1,
        "sequence" => 1
      }

      # Step 1: the native route_terminal line arrives first, exactly as it
      # does live - past the attempt budget this writes "restarting" then
      # "reconnecting" (mark_restarting_runtime, then note_prolonged_retry).
      after_terminal = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert after_terminal.retry_scheduled? == true

      # Step 2: the OS reports the same process exiting, one port line later,
      # exactly as it does live.
      assert {:keep_state, after_exit} =
               RouteHandler.handle_event(
                 :info,
                 {port, {:exit_status, 1}},
                 :started,
                 after_terminal
               )

      # Exactly two status writes for the whole cycle - not three - and the
      # cycle rests on the second one, "reconnecting", instead of being
      # clobbered back to "restarting" by the redundant exit_status call.
      assert_receive {:set_route_runtime_status, "route-idempotent-2", "restarting"}
      assert_receive {:set_route_runtime_status, "route-idempotent-2", "reconnecting"}
      refute_receive {:set_route_runtime_status, _, _}, 50

      assert after_exit.port == nil
      assert after_exit.retry_scheduled? == true
    end

    test "a retry cycle within the attempt budget writes status exactly once, not twice" do
      test_pid = self()

      :meck.expect(HydraSrt, :set_route_runtime_status, fn id, status ->
        send(test_pid, {:set_route_runtime_status, id, status})
        {:ok, %{}}
      end)

      port = make_ref()

      data =
        base_route_data(%{
          id: "route-idempotent-3",
          process_instance_id: "piid-idempotent-3",
          active_source_id: "s1",
          port: port,
          retry_attempt: 0,
          retry_prev_backoff_ms: nil
        })

      payload = %{
        "event" => "route_terminal",
        "route_id" => "route-idempotent-3",
        "process_instance_id" => "piid-idempotent-3",
        "reason_code" => "SRT_CONNECT_TIMEOUT",
        "retryable" => true,
        "retry_domain" => "route",
        "detail" => "deadline",
        "observed_at_ms" => 1,
        "sequence" => 1
      }

      after_terminal = RouteHandler.consume_port_output(Jason.encode!(payload) <> "\n", data)

      assert {:keep_state, _after_exit} =
               RouteHandler.handle_event(
                 :info,
                 {port, {:exit_status, 1}},
                 :started,
                 after_terminal
               )

      # Below the attempt budget, mark_restarting_runtime is the only write in
      # the whole cycle - one transition, not the two it took before the
      # guard (a redundant second "restarting" write from the exit_status
      # message).
      assert_receive {:set_route_runtime_status, "route-idempotent-3", "restarting"}
      refute_receive {:set_route_runtime_status, _, _}, 50
    end

    test "a process that dies without ever emitting a route_terminal still schedules a retry" do
      test_pid = self()

      :meck.expect(HydraSrt, :set_route_runtime_status, fn id, status ->
        send(test_pid, {:set_route_runtime_status, id, status})
        {:ok, %{}}
      end)

      port = make_ref()

      data =
        base_route_data(%{
          id: "route-idempotent-4",
          active_source_id: "s1",
          port: port,
          route_terminal: nil,
          retry_scheduled?: false
        })

      assert {:keep_state, next} =
               RouteHandler.handle_event(:info, {port, {:exit_status, 1}}, :started, data)

      assert next.port == nil
      assert next.retry_scheduled? == true
      assert next.retry_attempt == 1
      assert_receive {:set_route_runtime_status, "route-idempotent-4", "restarting"}
      assert_receive :retry_start, next.retry_prev_backoff_ms + 100
    end
  end

  describe "get_endpoint_health/1" do
    # Spawns a real RouteHandler (:gen_statem). Start failure → mark_restarting_runtime
    # and terminate → mark_route_stopped both reach HydraSrt → Db.*_with_previous → Repo.
    # Stub the Db write path the real HydraSrt helpers use (not only update_route_runtime_status/2),
    # same boundary pattern as route_handler_failover_test.
    setup do
      :meck.new(HydraSrt.Db, [:passthrough])
      :meck.new(HydraSrt, [:passthrough])
      :meck.new(HydraSrt.Stats.EventLogger, [:passthrough])

      stub_route = %{"id" => "stub-route", "status" => "stopped", "schema_status" => "stopped"}
      stub_prev = {:ok, %{route: stub_route, previous_status: nil}}

      :meck.expect(HydraSrt, :mark_route_failed, fn _id -> {:ok, stub_route} end)
      :meck.expect(HydraSrt, :mark_route_started, fn _id -> {:ok, stub_route} end)
      :meck.expect(HydraSrt, :mark_route_stopped, fn _id -> {:ok, stub_route} end)
      :meck.expect(HydraSrt, :mark_route_terminated, fn _id -> {:ok, stub_route} end)
      :meck.expect(HydraSrt, :set_route_runtime_status, fn _id, _status -> {:ok, stub_route} end)

      :meck.expect(HydraSrt.Db, :update_route_runtime_status, fn _id, _status ->
        {:ok, stub_route}
      end)

      :meck.expect(HydraSrt.Db, :update_route_runtime_status_with_previous, fn _id, _status ->
        stub_prev
      end)

      :meck.expect(
        HydraSrt.Db,
        :transition_route_runtime_status_with_previous,
        fn _id, _attrs, _dest_status, _src_status -> stub_prev end
      )

      :meck.expect(HydraSrt.Db, :update_route_status_with_previous, fn _id, _attrs ->
        stub_prev
      end)

      :meck.expect(HydraSrt.Db, :set_route_active_source, fn _id, _source_id, _reason ->
        {:ok, stub_route}
      end)

      :meck.expect(HydraSrt.Stats.EventLogger, :log_pipeline_failed, fn _, _, _, _ -> :ok end)
      :meck.expect(HydraSrt.Stats.EventLogger, :log_route_status_change, fn _, _, _ -> :ok end)

      on_exit(fn -> :meck.unload() end)
      :ok
    end

    test "call returns stored endpoint_health map and process identity" do
      route_id = "route-health-call-#{System.unique_integer([:positive])}"

      empty_route = %{
        "id" => route_id,
        "active_source_id" => nil,
        "sources" => [],
        "destinations" => []
      }

      :meck.expect(HydraSrt.Db, :get_route, fn
        ^route_id, true -> {:ok, empty_route}
        _id, _include_dest -> {:error, :not_found}
      end)

      {:ok, pid} = RouteHandler.start_link(%{id: route_id})

      on_exit(fn ->
        if Process.alive?(pid), do: :gen_statem.stop(pid, :normal, 1000)
      end)

      :sys.replace_state(pid, fn {state, data} ->
        {state,
         %{
           data
           | process_instance_id: "piid-call",
             endpoint_health: %{
               "ep-1" => %{
                 "endpoint_id" => "ep-1",
                 "state" => "streaming",
                 "sequence" => 4,
                 "config_revision" => "rev-call"
               }
             }
         }}
      end)

      assert {:ok, identity} = RouteHandler.get_endpoint_health(pid)
      assert identity.process_instance_id == "piid-call"
      assert identity.config_revision == "rev-call"
      assert identity.last_sequence == 4
      assert identity.endpoint_health["ep-1"]["state"] == "streaming"

      :gen_statem.stop(pid, :normal, 1000)
    end
  end
end
