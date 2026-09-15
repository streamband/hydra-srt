defmodule HydraSrtWeb.Plugs.RawBodyReader do
  @moduledoc false

  @telemetry_path "/api/telemetry/envelope"

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    read_opts =
      if conn.request_path == @telemetry_path do
        Keyword.put(opts, :length, 200_000)
      else
        opts
      end

    case Plug.Conn.read_body(conn, read_opts) do
      {:ok, body, conn} -> {:ok, body, maybe_assign(conn, body)}
      {:more, body, conn} -> {:more, body, maybe_assign(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec maybe_assign(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def maybe_assign(conn, body) do
    if conn.request_path == @telemetry_path,
      do: Plug.Conn.assign(conn, :raw_body, body),
      else: conn
  end
end
