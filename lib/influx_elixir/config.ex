defmodule InfluxElixir.Config do
  @moduledoc """
  Connection configuration validation and defaults.

  Uses `NimbleOptions` to validate connection options passed to
  `InfluxElixir.ConnectionSupervisor` and consumed by client
  implementations.

  ## Options

    * `:host` - InfluxDB host (e.g., `"localhost"` or `"us-east-1.influxdb.io"`)
      Required.
    * `:token` - Authentication token (default: `""`; omit it for an
      unauthenticated instance, and no `Authorization` header is sent)
    * `:org` - Organization name (default: `""`)
    * `:database` - Default database name (default: `nil`)
    * `:databases` - List of database names (LocalClient pre-creates them;
      both clients default `:database` to the first item if `:database` is
      not set). Default: `[]`
    * `:port` - Port number (default: `8086`)
    * `:scheme` - `:http` or `:https` (default: `:https`)
    * `:pool_size` - Finch connection pool size (default: `10`)
    * `:api_version` - `:v3` (default) or `:v2`. Selects the write endpoint
      in `InfluxElixir.Client.HTTP`; a v2 server accepts the v3 write path
      with `200` but stores nothing, so declare `:v2` for InfluxDB 2.x.
    * `:timeout` - connection-level receive timeout in milliseconds
    * `:pool_timeout` - connection-level Finch pool checkout timeout in
      milliseconds (default `5_000`, Finch's own); applies before `:timeout`
    * `:flight_port` - Arrow Flight gRPC port for `transport: :flight` queries
      (default: `443`; InfluxDB 3 Core serves Flight on its HTTP port, 8181)
    * `:batch_writer` - `InfluxElixir.Write.BatchWriter` options; when given,
      `InfluxElixir.ConnectionSupervisor` starts a writer for the connection
    * `:finch_name` - use an existing Finch pool instead of a per-connection one

  `InfluxElixir.ConnectionSupervisor` validates the config with this schema
  when the client is `InfluxElixir.Client.HTTP`; unknown keys are errors.

  ## Example

      iex> InfluxElixir.Config.validate!(
      ...>   host: "localhost",
      ...>   token: "my-token",
      ...>   scheme: :http,
      ...>   port: 8086
      ...> )
  """

  @schema [
    host: [
      type: {:custom, __MODULE__, :host, []},
      required: true,
      doc: "InfluxDB host (hostname or IP, no scheme)"
    ],
    token: [
      type: :string,
      required: false,
      default: "",
      doc: "Authentication token (omit for unauthenticated instances)"
    ],
    org: [
      type: :string,
      default: "",
      doc: "Organization name"
    ],
    database: [
      type: :string,
      doc: "Default database name"
    ],
    databases: [
      type: {:list, :string},
      default: [],
      doc:
        "List of database names. LocalClient pre-creates each; " <>
          "both clients default :database to the first item if :database is unset."
    ],
    port: [
      type: {:in, 1..65_535},
      default: 8086,
      doc: "Port number"
    ],
    scheme: [
      type: {:in, [:http, :https]},
      default: :https,
      doc: "URL scheme (:http or :https)"
    ],
    pool_size: [
      type: :pos_integer,
      default: 10,
      doc: "Finch connection pool size"
    ],
    api_version: [
      type: {:in, [:v2, :v3]},
      default: :v3,
      doc: "InfluxDB API generation: :v3 (default) or :v2"
    ],
    timeout: [
      type: :pos_integer,
      doc: "Connection-level receive timeout in ms (default: 30_000 in the HTTP client)"
    ],
    pool_timeout: [
      type: :pos_integer,
      doc: "Connection-level Finch pool checkout timeout in ms (default: 5_000)"
    ],
    flight_port: [
      type: {:in, 1..65_535},
      doc: "Arrow Flight gRPC port used by `transport: :flight` queries (default: 443)"
    ],
    batch_writer: [
      type: :keyword_list,
      doc: "InfluxElixir.Write.BatchWriter options; starts a writer under the connection"
    ],
    finch_name: [
      type: :atom,
      doc: "Finch pool to use instead of the one ConnectionSupervisor starts"
    ],
    name: [
      type: :atom,
      doc: "Connection name (set internally by ConnectionSupervisor)"
    ]
  ]

  @doc """
  Validates connection options and returns a normalized keyword list.

  Returns `{:ok, validated_opts}` or `{:error, %NimbleOptions.ValidationError{}}`.

  ## Examples

      iex> {:ok, opts} = InfluxElixir.Config.validate(
      ...>   host: "localhost",
      ...>   token: "my-token"
      ...> )
      iex> opts[:scheme]
      :https
  """
  @spec validate(keyword()) ::
          {:ok, keyword()} | {:error, NimbleOptions.ValidationError.t()}
  def validate(opts) do
    if is_list(opts) and Keyword.keyword?(opts) do
      NimbleOptions.validate(opts, @schema)
    else
      {:error,
       %NimbleOptions.ValidationError{
         message: "expected the options to be a keyword list, got: #{inspect(opts)}"
       }}
    end
  end

  # A host is written into every request's URL: an empty one, or one with a
  # blank or control character, cannot be (Mint refuses it at the request,
  # far from the option that caused it).
  @doc false
  @spec host(term()) :: {:ok, binary()} | {:error, binary()}
  # The host is what the URL the client builds (`scheme://host:port`) reads back as its host:
  # a name (non-ASCII names in their punycode `xn--` form), an IPv4 address, or an IPv6
  # address in brackets. Anything else is read differently (`host:8086` drops the port,
  # `x/y` and `h?x` move the rest into the path or query, `user@h` is user info, an IPv6
  # zone `[fe80::1%en0]` is not a host) and would send the request somewhere else.
  def host(host) when is_binary(host) and host != "" do
    with true <- String.valid?(host) and not String.match?(host, ~r/[\s[:cntrl:]]/),
         {:ok, %URI{host: parsed, port: 1, userinfo: nil, path: nil, query: nil, fragment: nil}}
         when parsed == host or "[" <> parsed <> "]" == host <- URI.new("http://#{host}:1") do
      {:ok, host}
    else
      _not_a_host ->
        {:error,
         "expected :host to be a host name or an IP address (IPv6 in brackets), " <>
           "got: #{inspect(host)}"}
    end
  end

  def host(host), do: {:error, "expected :host to be a non-empty string, got: #{inspect(host)}"}

  @doc """
  Validates connection options, raising on error.

  Returns the validated keyword list or raises
  `NimbleOptions.ValidationError`.

  ## Examples

      iex> opts = InfluxElixir.Config.validate!(
      ...>   host: "localhost",
      ...>   token: "my-token"
      ...> )
      iex> opts[:port]
      8086
  """
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) do
    case validate(opts) do
      {:ok, validated} -> validated
      {:error, error} -> raise error
    end
  end

  @doc """
  Builds the base URL from validated config options.

  ## Examples

      iex> InfluxElixir.Config.base_url(scheme: :https, host: "example.com", port: 443)
      "https://example.com:443"
  """
  @spec base_url(keyword()) :: binary()
  def base_url(opts) do
    scheme = Keyword.fetch!(opts, :scheme)
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    "#{scheme}://#{host}:#{port}"
  end
end
