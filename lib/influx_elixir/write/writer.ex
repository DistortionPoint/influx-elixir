defmodule InfluxElixir.Write.Writer do
  @moduledoc """
  Direct single-request write to InfluxDB.

  Accepts pre-encoded line protocol binary and forwards it to the configured
  client implementation. Automatically applies gzip compression for payloads
  larger than 1 KB.
  """

  @gzip_threshold 1024

  @doc """
  Writes line protocol binary to InfluxDB via the configured client.

  Automatically gzips payloads larger than #{@gzip_threshold} bytes by
  prepending `{:gzip, true}` to opts so that the HTTP client can set
  the appropriate `Content-Encoding: gzip` header.

  ## Parameters

    * `connection` - connection term (opaque, passed to client)
    * `line_protocol` - encoded line protocol binary
    * `opts` - keyword options forwarded to the client

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
    {payload, write_opts} = maybe_gzip(line_protocol, opts)
    InfluxElixir.Client.impl().write(connection, payload, write_opts)
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
end
