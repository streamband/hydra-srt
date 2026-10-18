defmodule HydraSrtWeb.Plugs.SecureBrowserHeaders do
  @moduledoc false

  import Phoenix.Controller, only: [put_secure_browser_headers: 2]

  @headers %{
    "content-security-policy" =>
      "default-src 'self'; connect-src 'self' ws: wss: https://o4512091677851648.ingest.de.sentry.io; img-src 'self' data:; script-src 'self'; style-src 'self' 'unsafe-inline'"
  }

  def init(opts), do: opts

  def call(conn, _opts), do: put_secure_browser_headers(conn, @headers)
end
