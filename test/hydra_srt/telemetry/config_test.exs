defmodule HydraSrt.Telemetry.ConfigTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Telemetry.Config

  setup do
    original = System.get_env("HYDRA_DISTRIBUTION")

    on_exit(fn ->
      if original,
        do: System.put_env("HYDRA_DISTRIBUTION", original),
        else: System.delete_env("HYDRA_DISTRIBUTION")
    end)

    :ok
  end

  test "exposes the public ingest credentials" do
    dsn = Config.default_sentry_dsn()
    uri = URI.parse(dsn)

    assert uri.scheme == "https"
    assert uri.host == "o4512091677851648.ingest.de.sentry.io"
    assert uri.path == "/4512091690565712"
    assert uri.userinfo == "ed635a0a0de91a059eb36d2b4140012a"
    assert Config.default_posthog_host() == "https://eu.i.posthog.com"
    assert Config.default_posthog_key() == "phc_Caj6HJgJnjm2vf3ZS9Wd9KYUF7fqxCWnK7nFEXrvENkK"
  end

  test "maps the explicit distribution values and defaults to source" do
    System.delete_env("HYDRA_DISTRIBUTION")
    assert Config.distribution() == :source

    for {value, expected} <- [{"docker", :docker}, {"release", :release}, {"source", :source}] do
      System.put_env("HYDRA_DISTRIBUTION", value)
      assert Config.distribution() == expected
    end
  end

  test "rejects an invalid distribution" do
    System.put_env("HYDRA_DISTRIBUTION", "staging")

    assert_raise ArgumentError, ~r/invalid HYDRA_DISTRIBUTION/, fn -> Config.distribution() end
  end

  test "normalizes operating system and architecture to the allowlisted enums" do
    assert Config.os_family() in [:linux, :darwin, :windows, :freebsd, :other]
    assert Config.arch() in [:x86_64, :aarch64, :armv7, :other]
  end
end
