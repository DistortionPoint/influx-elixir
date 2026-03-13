defmodule InfluxElixir.Config do
  @moduledoc """
  Connection configuration validation and defaults.

  Uses `NimbleOptions` to validate connection options passed to
  `InfluxElixir.ConnectionSupervisor` and consumed by client
  implementations.

  ## Options

    * `:host` - InfluxDB host (e.g., `"localhost"` or `"us-east-1.influxdb.io"`)
      Required.
    * `:token` - Authentication token. Required.
    * `:org` - Organization name (default: `""`)
    * `:database` - Default database name (default: `nil`)
    * `:port` - Port number (default: `8086`)
    * `:scheme` - `:http` or `:https` (default: `:https`)
    * `:pool_size` - Finch connection pool size (default: `10`)

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
      type: :string,
      required: true,
      doc: "InfluxDB host (hostname or IP, no scheme)"
    ],
    token: [
      type: :string,
      required: true,
      doc: "Authentication token"
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
    port: [
      type: :pos_integer,
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
    NimbleOptions.validate(opts, @schema)
  end

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
    NimbleOptions.validate!(opts, @schema)
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
