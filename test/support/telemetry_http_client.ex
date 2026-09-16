defmodule HydraSrt.TestSupport.TelemetryHttpClient do
  @moduledoc false

  @spec request(atom(), binary(), binary(), list(), keyword()) ::
          {:ok, 202, [], binary()}
  def request(method, url, body, headers, opts) do
    if pid = Application.get_env(:hydra_srt, :telemetry_http_test_pid) do
      send(pid, {:telemetry_http_request, method, url, body, headers, opts})
    end

    {:ok, 202, [], ""}
  end
end
