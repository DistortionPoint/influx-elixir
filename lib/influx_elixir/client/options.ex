defmodule InfluxElixir.Client.Options do
  @moduledoc false
  # The reads of caller-supplied terms that every client and the write path share: options
  # are a keyword list or the caller's error, a write body is iodata or the caller's error, a
  # connection holds a default database or does not. None of them raises.

  @unencodable_errors [
    FunctionClauseError,
    Protocol.UndefinedError,
    Jason.EncodeError,
    ArgumentError,
    BadFunctionError,
    BadArityError
  ]

  @doc false
  # A named connection or module atom: any atom other than `nil`, `true`, or `false`.
  defguard is_name_atom(value) when is_atom(value) and value not in [nil, true, false]

  @doc false
  # A scalar value that can be rendered directly in a URL piece or query string.
  defguard is_url_text(value) when is_binary(value) or is_atom(value) or is_number(value)

  @doc false
  # A keyword list: the only form options can take.
  @spec keyword?(term()) :: boolean()
  def keyword?(opts), do: is_list(opts) and Keyword.keyword?(opts)

  @doc false
  # A timeout value: a non-negative integer of milliseconds or `:infinity`.
  @spec timeout?(term()) :: boolean()
  def timeout?(timeout), do: timeout == :infinity or (is_integer(timeout) and timeout >= 0)

  @doc false
  # An optional timeout value in a keyword list: `nil` (unset) or a valid timeout.
  @spec timeout_opt?(term()) :: boolean()
  def timeout_opt?(timeout), do: is_nil(timeout) or timeout?(timeout)

  @doc false
  # An optional boolean value in a keyword list: `nil` (unset) or a boolean.
  @spec boolean_opt?(term()) :: boolean()
  def boolean_opt?(flag), do: is_nil(flag) or is_boolean(flag)

  @doc false
  # Encodes `payload` as JSON, returning `{:error, {:unencodable_body, message}}` instead of
  # raising when `payload` holds non-UTF-8 binaries, tuples, functions or improper lists.
  @spec json_body(term()) :: {:ok, binary()} | {:error, {:unencodable_body, binary()}}
  def json_body(payload) do
    case Jason.encode(payload) do
      {:ok, body} -> {:ok, body}
      {:error, error} -> {:error, {:unencodable_body, Exception.message(error)}}
    end
  rescue
    error in @unencodable_errors ->
      {:error, {:unencodable_body, Exception.message(error)}}
  end

  @doc false
  # The text that iodata stands for (a binary is itself); anything that is not iodata is
  # `:error`, for the caller to name.
  @spec iodata(term()) :: {:ok, binary()} | :error
  def iodata(body) when is_binary(body), do: {:ok, body}

  def iodata(body) when is_list(body) do
    {:ok, IO.iodata_to_binary(body)}
  rescue
    ArgumentError -> :error
  end

  def iodata(_body), do: :error

  @doc false
  # The connection-level default database of a keyword (`Client.HTTP`) or map (`Client.Local`)
  # connection: the callers refuse any other term first.
  @spec database(keyword() | map()) :: term()
  def database(connection) when is_map(connection), do: Map.get(connection, :database)

  def database(connection) when is_list(connection) do
    if keyword?(connection), do: Keyword.get(connection, :database)
  end

  def database(_connection), do: nil

  @doc false
  # The database of a call: `opts[:database]` when given and non-nil, else the connection's
  # default. A non-nil `opts[:database]` (such as `database: false`) is kept as-is rather than
  # falling back via `||`.
  @spec database(term(), keyword() | map()) :: term()
  def database(opts, connection) do
    if keyword?(opts) do
      case Keyword.get(opts, :database) do
        nil -> database(connection)
        db -> db
      end
    else
      database(connection)
    end
  end

  @doc false
  # The response format of a query: `opts[:format]` when given and non-nil, else `:json`.
  @spec query_format(keyword()) :: term()
  def query_format(opts) do
    case Keyword.get(opts, :format) do
      nil -> :json
      format -> format
    end
  end

  @doc false
  # The lines of a write body: its newlines, one more for the last line, none for a trailing
  # newline. One scan for each newline, holding nothing but the count: the write path and the
  # batch writer count every payload.
  @spec line_count(binary()) :: non_neg_integer()
  def line_count(""), do: 0

  def line_count(text) when is_binary(text) do
    newlines = newlines(text, 0, 0)
    if :binary.last(text) == ?\n, do: newlines, else: newlines + 1
  end

  @spec newlines(binary(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp newlines(text, from, count) do
    case :binary.match(text, "\n", scope: {from, byte_size(text) - from}) do
      {at, 1} -> newlines(text, at + 1, count + 1)
      :nomatch -> count
    end
  end
end
