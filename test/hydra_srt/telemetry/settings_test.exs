defmodule HydraSrt.Telemetry.SettingsTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Telemetry.Settings

  test "test builds keep both signals off" do
    assert Settings.usage_enabled?() == false
    assert Settings.crash_enabled?() == false
  end
end
