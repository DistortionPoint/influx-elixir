defmodule InfluxElixir.Write.Writer do
  @moduledoc """
  Direct single-request write to InfluxDB.

  Accepts line protocol (a binary or iodata) or `InfluxElixir.Write.Point`s and forwards
  them to the configured client implementation. Automatically applies gzip compression for
  payloads larger than 1 KB, and wraps every write in an
  `[:influx_elixir, :write, ...]` telemetry span (see `InfluxElixir.Telemetry`).
  """

  alias InfluxElixir.Client.Options
  alias InfluxElixir.{Connection, Telemetry}
  alias InfluxElixir.Write.{LineProtocol, Point}

  @gzip_threshold 1024

  @doc """
  Writes line protocol, or Points, to InfluxDB via the configured client.

  Gzips payloads larger than #{@gzip_threshold} bytes, and passes
  `gzip: true` to the client exactly when it has compressed the payload,
  so the HTTP client's `Content-Encoding: gzip` header always matches the
  body.

  ## Parameters

    * `connection` - connection term (opaque, passed to client), or the name of a
      connection registered with `InfluxElixir.Connection` (a name that is not registered
      is `{:error, {:invalid_connection, name}}`)
    * `payload` - encoded line protocol (a binary or iodata), a `InfluxElixir.Write.Point`
      or a list of them. Points are encoded with `InfluxElixir.Write.LineProtocol.encode/2`
      for the call's `:precision` and the connection's `api_version`; a point that cannot
      be encoded is that function's `{:error, reason}`, and nothing is sent.
    * `opts` - keyword options forwarded to the client, plus:
      * `:client` - client module to use instead of the configured one
        (`InfluxElixir.Client.impl/0`). Not forwarded to the client.
      * `:gzip` - `true` compresses the payload whatever its size, `false`
        never does; by default only payloads over #{@gzip_threshold} bytes
        are. An explicit `true` used to reach the client with the payload
        uncompressed, and the server refused the header
        (`error decoding gzip stream`, verified).

  ## Returns

    * `{:ok, :written}` on success
    * `{:error, reason}` on failure

  ## Examples

      iex> {:ok, conn} = InfluxElixir.Client.Local.start(database: "mydb")
      iex> InfluxElixir.Write.Writer.write(conn, "cpu value=1.0")
      {:ok, :written}
  """
  @spec write(
          InfluxElixir.Client.connection() | atom(),
          iodata() | Point.t() | [Point.t()],
          keyword()
        ) :: InfluxElixir.Client.write_result()
  def write(connection, payload, opts \\ []) do
    with {:ok, connection} <- resolve(connection) do
      write_resolved(connection, payload, opts)
    end
  end

  @spec write_resolved(InfluxElixir.Client.connection(), term(), term()) ::
          InfluxElixir.Client.write_result()
  defp write_resolved(connection, payload, opts) do
    if Options.keyword?(opts) do
      with {:ok, body} <- body(connection, payload, opts) do
        write_body(connection, body, opts)
      end
    else
      # Options that are not a keyword list are the client's error to name, never a raise
      # here: each client answers them its own way.
      metadata = %{database: Options.database(connection), bytes: 0, point_count: 0}
      client = InfluxElixir.Client.impl()
      Telemetry.span_write(metadata, fn -> client.write(connection, payload, opts) end)
    end
  end

  @spec write_body(InfluxElixir.Client.connection(), term(), keyword()) ::
          InfluxElixir.Client.write_result()
  defp write_body(connection, line_protocol, opts) do
    {client, opts} = Keyword.pop(opts, :client, InfluxElixir.Client.impl())
    {gzip, opts} = Keyword.pop(opts, :gzip)
    {payload, write_opts} = maybe_gzip(line_protocol, gzip, opts)

    metadata = %{
      database: Options.database(opts, connection),
      bytes: if(is_binary(line_protocol), do: byte_size(line_protocol), else: 0),
      point_count: line_count(line_protocol)
    }

    Telemetry.span_write(metadata, fn ->
      client.write(connection, payload, write_opts)
    end)
  end

  @doc false
  # Whether a payload is a Point, or a list holding one: the forms `write/3` encodes.
  @spec points?(term()) :: boolean()
  def points?(%Point{}), do: true
  def points?([%Point{} | _rest]), do: true
  def points?([_other | rest]), do: points?(rest)
  def points?(_other), do: false

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # A registered connection's name is the connection: the same term `InfluxElixir.write/3`
  # resolves, so a `BatchWriter` started with `connection: :name` writes through it.
  @spec resolve(term()) :: {:ok, term()} | {:error, {:invalid_connection, atom()}}
  defp resolve(name) when is_atom(name) and name not in [nil, true, false] do
    case Connection.get(name) do
      {:ok, connection} -> {:ok, connection}
      {:error, :not_found} -> {:error, {:invalid_connection, name}}
    end
  end

  # A connection is a keyword list (`Client.HTTP`) or a map (`Client.Local`); anything else (a
  # host name, a charlist, a number) is the caller's error, never a raise.
  defp resolve(connection) when is_map(connection), do: {:ok, connection}

  defp resolve(connection) when is_list(connection) do
    if Options.keyword?(connection),
      do: {:ok, connection},
      else: {:error, {:invalid_connection, connection}}
  end

  defp resolve(other), do: {:error, {:invalid_connection, other}}

  # The body to send: Points are encoded for this call and connection; iodata is the text it
  # stands for; a body that is neither goes to the client as given, which names it.
  @spec body(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp body(connection, payload, opts) do
    if points?(payload) do
      encode_opts =
        opts
        |> Keyword.take([:precision])
        |> Keyword.put(:api_version, Connection.api_version(connection))

      LineProtocol.encode(payload, encode_opts)
    else
      case Options.iodata(payload) do
        {:ok, text} -> {:ok, text}
        :error -> {:ok, payload}
      end
    end
  end

  @spec maybe_gzip(term(), term(), keyword()) :: {term(), keyword()}
  defp maybe_gzip(payload, gzip, opts)
       when is_binary(payload) and
              (gzip == true or (gzip == nil and byte_size(payload) > @gzip_threshold)),
       do: {:zlib.gzip(payload), Keyword.put(opts, :gzip, true)}

  defp maybe_gzip(payload, _gzip, opts), do: {payload, opts}

  # The lines of a body (see `Options.line_count/1`); a body that is not text has none.
  @spec line_count(term()) :: non_neg_integer()
  defp line_count(line_protocol) when is_binary(line_protocol),
    do: Options.line_count(line_protocol)

  defp line_count(_not_text), do: 0
end
