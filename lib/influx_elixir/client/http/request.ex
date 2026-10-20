defmodule InfluxElixir.Client.HTTP.Request do
  @moduledoc false
  # What every `InfluxElixir.Client.HTTP` request shares: the URL, the headers, the Finch call
  # and its three outcomes, the timeouts, and the two shapes most admin calls take (POST a
  # JSON body, DELETE a named thing). `Client.HTTP`, `Client.HTTP.Buckets` and
  # `Client.HTTP.Stream` build on it.

  alias InfluxElixir.Client.Options
  alias InfluxElixir.{Config, ConnectionSupervisor}

  # Default `Finch.request/3` receive timeout, mirroring
  # `InfluxElixir.Flight.Client`'s default so HTTP and Flight transports
  # have parity. Finch's own default is 15s, which is too short for many
  # production queries. Override with the `:timeout` opt on a per-call
  # basis, or via a `:timeout` key on the connection config.
  @default_timeout 30_000

  # Finch's own default for waiting on a pool checkout. Kept as the default
  # so behaviour is unchanged unless configured; see `:pool_timeout`.
  @default_pool_timeout 5_000

  @type outcome :: {:ok, Finch.Response.t()} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Requests
  # ---------------------------------------------------------------------------

  # Runs a request and normalises the outcome: `{:ok, response}` when the
  # status is one of `ok_statuses`, `{:error, %{status, body}}` for any other
  # status, and `{:error, {:connection_error, reason}}` for a transport
  # failure. Every public function shares this three-clause case.
  @spec request(
          :get | :post | :delete,
          binary(),
          [{binary(), binary()}],
          binary() | nil,
          keyword(),
          keyword(),
          [non_neg_integer()]
        ) :: outcome()
  def request(method, url, headers, body, connection, opts, ok_statuses) do
    case do_request(method, url, headers, body, connection, opts) do
      {:ok, %Finch.Response{status: status} = response} ->
        if status in ok_statuses do
          {:ok, response}
        else
          {:error, %{status: status, body: response.body}}
        end

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  # POSTs JSON to `path` (which carries its own query string): `body` is a map to encode or
  # the JSON already encoded. A map Jason cannot write is `{:unencodable_body, message}`.
  @spec post_json(keyword(), binary(), map() | binary(), keyword(), [non_neg_integer()]) ::
          outcome()
  def post_json(connection, path, body, opts, ok_statuses) do
    with {:ok, encoded} <- encode_body(body) do
      request(
        :post,
        base_url(connection) <> path,
        json_headers(connection),
        encoded,
        connection,
        opts,
        ok_statuses
      )
    end
  end

  # GETs `path` (with its query string) as the connection's token.
  @spec get(keyword(), binary(), [non_neg_integer()]) :: outcome()
  def get(connection, path, ok_statuses) do
    request(
      :get,
      base_url(connection) <> path,
      auth_headers(connection),
      nil,
      connection,
      [],
      ok_statuses
    )
  end

  # DELETEs `path` as `?param=name`; `name` is written into the URL, so it must be text.
  @spec delete_named(keyword(), binary(), binary(), term()) :: :ok | {:error, term()}
  def delete_named(connection, path, param, name) do
    with :ok <- url_values(name: name),
         {:ok, _response} <-
           request(
             :delete,
             base_url(connection) <> path <> "?" <> param <> "=" <> query_value(name),
             auth_headers(connection),
             nil,
             connection,
             [],
             [200, 204]
           ) do
      :ok
    end
  end

  @spec encode_body(map() | binary()) :: {:ok, binary()} | {:error, term()}
  defp encode_body(body) when is_binary(body), do: {:ok, body}
  defp encode_body(map), do: json_body(map)

  @spec do_request(
          :get | :post | :delete,
          binary(),
          [{binary(), binary()}],
          binary() | nil,
          keyword(),
          keyword()
        ) :: outcome()
  defp do_request(method, url, headers, body, connection, opts) do
    with {:ok, finch_name} <- resolve_finch(connection) do
      request = Finch.build(method, url, headers, body)
      Finch.request(request, finch_name, finch_opts(opts, connection))
    end
  rescue
    # Finch does not return an error tuple when no connection can be checked
    # out within :pool_timeout — it converts NimblePool's exit into a
    # RuntimeError — nor when no pool of that name is running (`ArgumentError: unknown
    # registry`). Map both back into the library's tagged-tuple contract.
    error in [RuntimeError, ArgumentError] -> {:error, classify_finch_error(error)}
  end

  @pool_timeout_message "Finch was unable to provide a connection within the timeout"

  @spec classify_finch_error(Exception.t()) :: :pool_timeout | :no_pool | Exception.t()
  def classify_finch_error(%RuntimeError{message: @pool_timeout_message <> _rest}),
    do: :pool_timeout

  def classify_finch_error(%ArgumentError{message: "unknown registry" <> _rest}), do: :no_pool

  def classify_finch_error(error), do: error

  # ---------------------------------------------------------------------------
  # Timeouts and the pool
  # ---------------------------------------------------------------------------

  # Both Finch timeouts, resolved with the same precedence. Without an
  # explicit `pool_timeout` Finch waits at most 5 s to check a connection out
  # of the pool, regardless of how generous `receive_timeout` is (#14).
  @spec finch_opts(keyword(), keyword()) :: keyword()
  def finch_opts(opts, connection) do
    [
      receive_timeout: resolve_timeout(opts, connection),
      pool_timeout: resolve_pool_timeout(opts, connection)
    ]
  end

  # The receive timeout in milliseconds. Precedence:
  #   opts[:timeout] → connection[:timeout] → @default_timeout
  @spec resolve_timeout(keyword(), keyword()) :: non_neg_integer()
  def resolve_timeout(opts, connection) do
    Keyword.get(opts, :timeout) ||
      Keyword.get(connection, :timeout) ||
      @default_timeout
  end

  # The pool checkout timeout in milliseconds. Precedence:
  #   opts[:pool_timeout] → connection[:pool_timeout] → @default_pool_timeout
  @spec resolve_pool_timeout(keyword(), keyword()) :: non_neg_integer()
  def resolve_pool_timeout(opts, connection) do
    Keyword.get(opts, :pool_timeout) ||
      Keyword.get(connection, :pool_timeout) ||
      @default_pool_timeout
  end

  # The pool of a connection: its `:finch_name`, else the pool the supervisor started for its
  # `:name`. A keyword config with neither has no pool to name.
  @spec resolve_finch(keyword()) :: {:ok, atom()} | {:error, :no_pool_name}
  def resolve_finch(connection) do
    case {Keyword.get(connection, :finch_name), Keyword.get(connection, :name)} do
      {finch_name, _name}
      when is_atom(finch_name) and finch_name not in [nil, true, false] ->
        {:ok, finch_name}

      {nil, name} when is_atom(name) and name not in [nil, true, false] ->
        {:ok, ConnectionSupervisor.finch_name(name)}

      _other ->
        {:error, :no_pool_name}
    end
  end

  # ---------------------------------------------------------------------------
  # URLs, headers and bodies
  # ---------------------------------------------------------------------------

  @spec base_url(keyword()) :: binary()
  def base_url(connection), do: Config.base_url(connection)

  @spec auth_headers(keyword()) :: [{binary(), binary()}]
  def auth_headers(connection) do
    case conn_val(connection, :token) do
      nil -> []
      "" -> []
      token -> [{"authorization", "Bearer #{token}"}]
    end
  end

  @spec json_headers(keyword()) :: [{binary(), binary()}]
  def json_headers(connection) do
    [{"content-type", "application/json"} | auth_headers(connection)]
  end

  @spec conn_val(keyword(), atom(), term()) :: term()
  def conn_val(connection, key, default \\ nil) do
    Keyword.get(connection, key, default)
  end

  # A value in a query string. `URI.encode_www_form/1` encodes `&`, `+`, `=` and `#`,
  # which `URI.encode/1` leaves alone: a v2 bucket named `a&b` would be written to
  # bucket `a` (verified against InfluxDB 2.7).
  @spec query_value(term()) :: binary()
  def query_value(value), do: value |> to_string() |> URI.encode_www_form()

  # A path segment: everything but the unreserved characters is encoded.
  @spec path_segment(term()) :: binary()
  def path_segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  # A value written into a URL is text (an atom or a number is written as its text); a map,
  # a tuple or a list has no form there: the caller's error, never a raise.
  @spec url_values(keyword()) :: :ok | {:error, {:invalid_value, atom(), term()}}
  def url_values(values) do
    case Enum.find(values, fn {_key, value} -> not url_text?(value) end) do
      nil -> :ok
      {key, value} -> {:error, {:invalid_value, key, value}}
    end
  end

  defp url_text?(value), do: is_binary(value) or is_atom(value) or is_number(value)

  # A connection for `Client.HTTP` is a keyword list; anything else (a `Client.Local` map, a
  # host name, a number) has no config keys to read: the caller's error, never a raise.
  @spec connection(term()) :: :ok | {:error, {:invalid_connection, term()}}
  def connection(conn) do
    if Options.keyword?(conn), do: :ok, else: {:error, {:invalid_connection, conn}}
  end

  # Options that are not a keyword list have nothing a request could be built from: the
  # caller's error, never a raise.
  @spec options(term()) :: :ok | {:error, {:invalid_options, term()}}
  def options(opts) do
    if Options.keyword?(opts), do: :ok, else: {:error, {:invalid_options, opts}}
  end

  # A request body is JSON, which holds only UTF-8 text: text that is not is
  # the caller's error, returned as one, never a `Jason.EncodeError` raised.
  @spec json_body(map()) :: {:ok, binary()} | {:error, {:unencodable_body, binary()}}
  def json_body(map) do
    case Jason.encode(map) do
      {:ok, body} -> {:ok, body}
      {:error, error} -> {:error, {:unencodable_body, Exception.message(error)}}
    end
  rescue
    # Jason raises instead of returning for an improper list or a map key it cannot write.
    error in [FunctionClauseError, Protocol.UndefinedError, Jason.EncodeError] ->
      {:error, {:unencodable_body, Exception.message(error)}}
  end

  # A body that is not JSON (a proxy's HTML page, say) is the same error
  # ResponseParser gives, not a bare Jason.DecodeError.
  @spec decode_json(binary()) :: {:ok, term()} | {:error, {:json_parse_error, term()}}
  def decode_json(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end
end
