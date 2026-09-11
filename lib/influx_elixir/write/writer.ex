defmodule InfluxElixir.Write.Writer do
  @moduledoc """
  Direct single-request write to InfluxDB.

  Accepts pre-encoded line protocol binary and forwards it to the configured
  client implementation. Automatically applies gzip compression for payloads
  larger than 1 KB, and wraps every write in an
  `[:influx_elixir, :write, ...]` telemetry span (see `InfluxElixir.Telemetry`).
  """

  alias InfluxElixir.Telemetry

  @gzip_threshold 1024

  @doc """
  Writes line protocol binary to InfluxDB via the configured client.

  Automatically gzips payloads larger than #{@gzip_threshold} bytes by
  prepending `{:gzip, true}` to opts so that the HTTP client can set
  the appropriate `Content-Encoding: gzip` header.

  ## Parameters

    * `connection` - connection term (opaque, passed to client)
    * `line_protocol` - encoded line protocol binary
    * `opts` - keyword options forwarded to the client, plus:
      * `:client` - client module to use instead of the configured one
        (`InfluxElixir.Client.impl/0`). Not forwarded to the client.

  ## Returns

    * `{:ok, :written}` on success
    * `{:error, reason}` on failure

  ## Examples

      iex> {:ok, conn} = InfluxElixir.Client.Local.start()
      iex> InfluxElixir.Write.Writer.write(conn, "cpu value=1.0")
      {:ok, :written}
  """
  @spec write(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.write_result()
  def write(connection, line_protocol, opts \\ []) do
    {client, opts} = Keyword.pop(opts, :client, InfluxElixir.Client.impl())
    {payload, write_opts} = maybe_gzip(line_protocol, opts)

    metadata = %{
      database: Keyword.get(opts, :database) || connection_database(connection),
      bytes: byte_size(line_protocol),
      point_count: line_count(line_protocol)
    }

    Telemetry.span_write(metadata, fn ->
      client.write(connection, payload, write_opts)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec maybe_gzip(binary(), keyword()) :: {binary(), keyword()}
  defp maybe_gzip(payload, opts) when byte_size(payload) > @gzip_threshold do
    compressed = :zlib.gzip(payload)
    {compressed, Keyword.put(opts, :gzip, true)}
  end

  defp maybe_gzip(payload, opts), do: {payload, opts}

  # The connection is a keyword list (HTTP) or a map (Local); Access reads
  # the connection-level default database from either.
  @spec connection_database(term()) :: binary() | nil
  defp connection_database(connection), do: connection[:database]

  @spec line_count(binary()) :: non_neg_integer()
  defp line_count(line_protocol) do
    line_protocol
    |> String.split("\n", trim: true)
    |> length()
  end
end
