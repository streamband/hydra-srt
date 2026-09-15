defmodule HydraSrt.DbTelemetryInstallationTest do
  use HydraSrt.DataCase, async: true

  test "does not create an installation row until identity is requested" do
    assert HydraSrt.Db.get_telemetry_installation() == nil
    assert {:ok, id} = HydraSrt.Db.ensure_telemetry_installation_id(true)
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert HydraSrt.Db.get_telemetry_installation().installation_id == id
  end
end
