defmodule HydraSrtWeb.RouteControllerTest do
  use HydraSrtWeb.ConnCase

  import HydraSrt.ApiFixtures

  @create_attrs %{
    "alias" => "some alias",
    "enabled" => true,
    "name" => "some name",
    "schema_status" => "processing",
    "status" => "some status",
    "started_at" => ~U[2025-02-18 14:51:00Z],
    "source" => %{},
    "stopped_at" => ~U[2025-02-18 14:51:00Z]
  }
  @update_attrs %{
    "alias" => "some updated alias",
    "enabled" => false,
    "name" => "some updated name",
    "schema_status" => "failed",
    "status" => "some updated status",
    "started_at" => ~U[2025-02-19 14:51:00Z],
    "source" => %{},
    "stopped_at" => ~U[2025-02-19 14:51:00Z]
  }
  @invalid_attrs %{
    "alias" => nil,
    "enabled" => nil,
    "name" => nil,
    "schema_status" => nil,
    "status" => nil,
    "started_at" => nil,
    "source" => nil,
    "stopped_at" => nil
  }

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> log_in_user()

    {:ok, conn: conn}
  end

  describe "index" do
    test "lists all routes", %{conn: conn} do
      conn = get(conn, ~p"/api/routes")
      response = json_response(conn, 200)
      assert response["data"] == []
      assert response["meta"] == %{"limit" => 50, "page" => 1, "total" => 0}
    end

    test "supports server pagination", %{conn: conn} do
      route_attrs1 = Map.put(@create_attrs, "name", "route 1")
      route_attrs2 = Map.put(@create_attrs, "name", "route 2")
      route_attrs3 = Map.put(@create_attrs, "name", "route 3")

      post(conn, ~p"/api/routes", route: route_attrs1)
      post(conn, ~p"/api/routes", route: route_attrs2)
      post(conn, ~p"/api/routes", route: route_attrs3)

      conn = get(conn, ~p"/api/routes?page=2&limit=2")
      response = json_response(conn, 200)

      assert length(response["data"]) == 1
      assert response["meta"] == %{"limit" => 2, "page" => 2, "total" => 3}
    end

    test "uses defaults for invalid pagination params", %{conn: conn} do
      conn = get(conn, ~p"/api/routes?page=0&limit=abc")
      response = json_response(conn, 200)
      assert response["meta"] == %{"limit" => 50, "page" => 1, "total" => 0}
    end

    test "rejects request without bearer token", %{conn: conn} do
      conn = delete_req_header(conn, "authorization")
      conn = get(conn, ~p"/api/routes")
      assert json_response(conn, 403)["error"] in ["Unauthorized", "Authorization header missing"]
    end
  end

  describe "create route" do
    test "renders route when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/api/routes", route: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/routes/#{id}")

      assert %{
               "id" => ^id,
               "alias" => "some alias",
               "destinations" => [],
               "enabled" => true,
               "name" => "some name",
               "schema_status" => "processing",
               "source" => %{},
               "started_at" => "2025-02-18T14:51:00Z",
               "status" => "some status",
               "stopped_at" => "2025-02-18T14:51:00Z"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/routes", route: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update route" do
    setup [:create_route]

    test "renders route when data is valid", %{conn: conn, route: %{id: id}} do
      before = (get(conn, ~p"/api/routes/#{id}") |> json_response(200))["data"]

      conn = put(conn, ~p"/api/routes/#{id}", route: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/routes/#{id}")

      updated = json_response(conn, 200)["data"]

      assert %{
               "id" => ^id,
               "alias" => "some updated alias",
               "destinations" => [],
               "enabled" => false,
               "name" => "some updated name",
               "source" => %{},
               "started_at" => "2025-02-19T14:51:00Z",
               "stopped_at" => "2025-02-19T14:51:00Z"
             } = updated

      assert updated["schema_status"] == before["schema_status"]
      assert updated["status"] == before["status"]
    end

    test "renders errors when data is invalid", %{conn: conn, route: %{id: id}} do
      conn = put(conn, ~p"/api/routes/#{id}", route: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete route" do
    setup [:create_route]

    test "deletes chosen route", %{conn: conn, route: %{id: id}} do
      conn = delete(conn, ~p"/api/routes/#{id}")
      assert response(conn, 204)

      conn = get(conn, ~p"/api/routes/#{id}")
      assert json_response(conn, 404)
    end
  end

  describe "route statistics reset" do
    setup [:create_route]

    test "POST returns conflict when route is not running", %{conn: conn, route: %{id: id}} do
      conn = post(conn, ~p"/api/routes/#{id}/stats/reset")

      assert json_response(conn, 409) == %{"error" => "Route is not running"}
    end

    test "DELETE returns conflict when route is not running", %{conn: conn, route: %{id: id}} do
      conn = delete(conn, ~p"/api/routes/#{id}/stats/reset")

      assert json_response(conn, 409) == %{"error" => "Route is not running"}
    end
  end

  describe "tags" do
    test "GET /api/tags returns empty list when no routes exist", %{conn: conn} do
      conn = get(conn, ~p"/api/tags")
      assert json_response(conn, 200)["data"] == []
    end

    test "GET /api/tags returns unique sorted tags from all routes", %{conn: conn} do
      route1_attrs = @create_attrs |> Map.put("tags", ["sport", "news"])

      route2_attrs =
        @create_attrs |> Map.put("name", "route 2") |> Map.put("tags", ["news", "live"])

      post(conn, ~p"/api/routes", route: route1_attrs)
      post(conn, ~p"/api/routes", route: route2_attrs)

      conn = get(conn, ~p"/api/tags")

      tag_names =
        conn
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(&Map.fetch!(&1, "name"))
        |> Enum.sort()

      assert tag_names == ["live", "news", "sport"]
    end

    test "create route with tags returns tags in response", %{conn: conn} do
      conn = post(conn, ~p"/api/routes", route: Map.put(@create_attrs, "tags", ["sport", "live"]))
      assert Enum.sort(json_response(conn, 201)["data"]["tags"]) == ["live", "sport"]
    end

    test "update route tags replaces previous tags", %{conn: conn} do
      create_conn = post(conn, ~p"/api/routes", route: Map.put(@create_attrs, "tags", ["sport"]))
      %{"id" => id} = json_response(create_conn, 201)["data"]

      conn = put(conn, ~p"/api/routes/#{id}", route: %{"tags" => ["news", "live"]})
      assert Enum.sort(json_response(conn, 200)["data"]["tags"]) == ["live", "news"]
    end
  end

  describe "test source" do
    test "returns probe validation error for invalid udp source", %{conn: conn} do
      conn =
        post(conn, ~p"/api/routes/test-source",
          route: %{
            "schema" => "UDP"
          }
        )

      assert json_response(conn, 422)["error"] == "UDP source is missing a valid port"
    end

    test "returns probe validation error for invalid srt source", %{conn: conn} do
      conn =
        post(conn, ~p"/api/routes/test-source",
          route: %{
            "schema" => "SRT",
            "localaddress" => "127.0.0.1",
            "mode" => "listener"
          }
        )

      assert json_response(conn, 422)["error"] == "SRT source is missing a valid port"
    end

    test "returns discovered programs from the source probe", %{conn: conn} do
      :ok = :meck.new(HydraSrt.SourceProbe, [:passthrough])

      :meck.expect(HydraSrt.SourceProbe, :probe, fn _source, _opts ->
        {:ok,
         %{
           "probe_uri" => "udp://127.0.0.1:5000",
           "streams" => [],
           "format" => %{"format_name" => "mpegts"},
           "programs" => [
             %{
               "program_number" => 11,
               "pmt_pid" => 4096,
               "pcr_pid" => 256,
               "name" => nil,
               "streams" => [%{"codec_type" => "audio", "codec_name" => "aac"}]
             }
           ],
           "raw" => %{}
         }}
      end)

      try do
        conn =
          post(conn, ~p"/api/routes/test-source",
            route: %{"schema" => "UDP", "address" => "127.0.0.1", "port" => 5000}
          )

        assert %{"programs" => [%{"program_number" => 11, "name" => nil}]} =
                 json_response(conn, 200)["data"]
      after
        :meck.unload(HydraSrt.SourceProbe)
      end
    end

    test "returns bad request when route parameter is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/routes/test-source", %{})

      assert json_response(conn, 400)["error"] == "Missing required 'route' parameter"
    end
  end

  describe "analytics" do
    setup [:create_route]

    test "returns route analytics from VictoriaMetrics", %{conn: conn, route: %{id: id}} do
      :ok = :meck.new(HydraSrt.Stats.VictoriaMetrics, [:passthrough])

      :meck.expect(HydraSrt.Stats.VictoriaMetrics, :query_range, fn _query, _from, _to, _step ->
        {:ok,
         [
           %{
             "metric" => %{
               "route_id" => id,
               "entity_type" => "destination",
               "entity_id" => "destination-1",
               "metric_key" => "srt_rtt_ms"
             },
             "values" => [[DateTime.utc_now() |> DateTime.to_unix(:second), "18.5"]]
           }
         ]}
      end)

      :meck.expect(HydraSrt.Stats.VictoriaMetrics, :export_series, fn _match, _from, _to ->
        {:ok, []}
      end)

      try do
        conn = get(conn, "/api/routes/#{id}/analytics?window=last_hour")
        response = json_response(conn, 200)

        assert %{"data" => %{"meta" => meta, "points" => points}} = response
        assert meta["window"] == "last_hour"
        assert is_integer(meta["bucket_ms"])
        assert is_list(points)
        assert is_list(response["data"]["switches"])
        assert is_list(response["data"]["source_timeline"])
        assert is_list(response["data"]["srt_quality"])
        assert is_list(response["data"]["srt_health"])

        assert [
                 %{
                   "entity_type" => "destination",
                   "entity_id" => "destination-1",
                   "rtt_ms" => 18.5
                 }
               ] = response["data"]["srt_health"]

        assert Enum.all?(points, fn point ->
                 is_binary(point["timestamp"]) and is_map(point["destinations"])
               end)
      after
        :meck.unload(HydraSrt.Stats.VictoriaMetrics)
      end
    end
  end

  describe "statuses analytics" do
    test "returns route status analytics payload", %{conn: conn} do
      :ok = :meck.new(HydraSrt.Stats.VictoriaMetrics, [:passthrough])

      :meck.expect(HydraSrt.Stats.VictoriaMetrics, :export_series, fn _match, _from, _to ->
        {:ok, []}
      end)

      :meck.expect(HydraSrt.Stats.VictoriaMetrics, :export_series, fn _match, _from, _to ->
        {:ok, []}
      end)

      try do
        conn = get(conn, "/api/routes/statuses/analytics?window=last_hour")
        response = json_response(conn, 200)

        assert %{"data" => %{"meta" => meta, "points" => points}} = response
        assert meta["window"] == "last_hour"
        assert is_integer(meta["bucket_ms"])
        assert is_binary(meta["from"])
        assert is_binary(meta["to"])
        assert is_list(points)
      after
        :meck.unload(HydraSrt.Stats.VictoriaMetrics)
      end
    end
  end

  describe "events" do
    setup [:create_route]

    test "returns route events payload", %{conn: conn, route: %{id: id}} do
      :ok = :meck.new(HydraSrt.Stats.VictoriaMetrics, [:passthrough])

      :meck.expect(HydraSrt.Stats.VictoriaMetrics, :export_series, fn _match, _from, _to ->
        {:ok, []}
      end)

      try do
        conn = get(conn, "/api/routes/#{id}/events?window=last_hour&limit=10&offset=0")
        response = json_response(conn, 200)

        assert %{"data" => %{"events" => events, "meta" => meta}} = response
        assert is_list(events)
        assert meta["window"] == "last_hour"
        assert meta["limit"] == 10
        assert meta["offset"] == 0
        assert is_integer(meta["total"])
      after
        :meck.unload(HydraSrt.Stats.VictoriaMetrics)
      end
    end

    test "returns an error status when the metrics backend fails", %{conn: conn, route: %{id: id}} do
      :ok = :meck.new(HydraSrt.Stats.VictoriaMetrics, [:passthrough])

      :meck.expect(HydraSrt.Stats.VictoriaMetrics, :export_series, fn _match, _from, _to ->
        {:error, :backend_down}
      end)

      try do
        conn = get(conn, "/api/routes/#{id}/events?window=last_hour&limit=10&offset=0")

        # A backend outage must surface as a server error, not an empty success page.
        assert json_response(conn, 500)["error"] == "Failed to fetch events"
      after
        :meck.unload(HydraSrt.Stats.VictoriaMetrics)
      end
    end
  end

  describe "pipeline_logs" do
    setup [:create_route]

    test "returns route pipeline logs payload", %{conn: conn, route: %{id: id}} do
      :ok = :meck.new(HydraSrt.Stats.VictoriaLogs, [:passthrough])

      :meck.expect(HydraSrt.Stats.VictoriaLogs, :query_route_logs, fn _route_id, _params ->
        {:ok, %{logs: [], total: 0}}
      end)

      try do
        conn = get(conn, "/api/routes/#{id}/pipeline-logs?window=last_hour&limit=10&offset=0")
        response = json_response(conn, 200)

        assert %{"data" => %{"logs" => logs, "meta" => meta}} = response
        assert is_list(logs)
        assert meta["window"] == "last_hour"
        assert meta["limit"] == 10
        assert meta["offset"] == 0
        assert is_integer(meta["total"])
      after
        :meck.unload(HydraSrt.Stats.VictoriaLogs)
      end
    end

    test "returns distinct pipeline log values for column=level", %{conn: conn, route: %{id: id}} do
      :ok = :meck.new(HydraSrt.Stats.VictoriaLogs, [:passthrough])

      :meck.expect(HydraSrt.Stats.VictoriaLogs, :distinct_route_values, fn _route_id, "level" ->
        {:ok, ["ERROR", "WARN"]}
      end)

      try do
        conn = get(conn, "/api/routes/#{id}/pipeline-logs/distinct?column=level")
        response = json_response(conn, 200)

        assert %{"data" => values} = response
        assert values == ["ERROR", "WARN"]
      after
        :meck.unload(HydraSrt.Stats.VictoriaLogs)
      end
    end

    test "returns 400 when distinct column is missing", %{conn: conn, route: %{id: id}} do
      conn = get(conn, "/api/routes/#{id}/pipeline-logs/distinct")
      response = json_response(conn, 400)

      assert response["error"] == "Missing required 'column' parameter"
    end
  end

  describe "switch source" do
    setup [:create_route_with_sources]

    test "switches active source when source belongs to route", %{
      conn: conn,
      route: route,
      secondary_source: secondary_source
    } do
      conn = post(conn, ~p"/api/routes/#{route.id}/switch-source", source_id: secondary_source.id)
      response = json_response(conn, 200)["data"]

      assert response["active_source_id"] == secondary_source.id
      assert response["last_switch_reason"] == "manual"
    end

    test "returns 404 for source from another route", %{conn: conn, route: route} do
      another_route = route_fixture()
      other_source = source_fixture(another_route, %{position: 0})

      conn = post(conn, ~p"/api/routes/#{route.id}/switch-source", source_id: other_source.id)
      assert json_response(conn, 404)
    end

    test "returns 422 for disabled source", %{
      conn: conn,
      route: route,
      secondary_source: secondary_source
    } do
      _ = HydraSrt.Db.update_source(route.id, secondary_source.id, %{"enabled" => false})

      conn = post(conn, ~p"/api/routes/#{route.id}/switch-source", source_id: secondary_source.id)
      assert json_response(conn, 422)["error"] == "Source is disabled"
    end
  end

  def create_route(_) do
    route = route_fixture()
    %{route: route}
  end

  def create_route_with_sources(_) do
    route = route_fixture()
    {:ok, _updated_route} = HydraSrt.Db.update_route(route.id, %{"status" => "stopped"})
    primary_source = source_fixture(route, %{position: 0, name: "primary"})
    secondary_source = source_fixture(route, %{position: 1, name: "backup"})
    {:ok, _route} = HydraSrt.Db.set_route_active_source(route.id, primary_source.id, "manual")

    %{route: route, primary_source: primary_source, secondary_source: secondary_source}
  end
end
