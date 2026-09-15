defmodule HydraSrtWeb.InitControllerTest do
  use HydraSrtWeb.ConnCase, async: false

  test "show returns init payload with version", %{conn: conn} do
    conn = get(conn, ~p"/api/init")
    payload = json_response(conn, 200)

    assert is_binary(payload["version"])
    assert payload["version"] != ""
    assert is_binary(payload["built_at"])
    assert payload["built_at"] != ""
    assert {:ok, _built_at, 0} = DateTime.from_iso8601(payload["built_at"])
    assert is_binary(payload["system_version"])
    assert payload["system_version"] != ""
    assert is_binary(payload["elixir_version"])
    assert payload["elixir_version"] != ""
    assert is_binary(payload["erlang_version"])
    assert payload["erlang_version"] != ""
    assert is_binary(payload["rust_version"])
    assert payload["rust_version"] != ""
    assert payload["demo_data"] in [true, false]

    assert payload["sentry_dsn"] == nil
  end
end
