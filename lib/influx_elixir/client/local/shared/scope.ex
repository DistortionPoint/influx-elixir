defmodule InfluxElixir.Client.Local.Scope do
  @moduledoc false
  # What every path of `InfluxElixir.Client.Local` asks first: whether the
  # connection's profile has the operation, which database the call is for, and
  # whether the engine has it.

  alias InfluxElixir.Client.Local.{DatabaseRules, LineProtocolParser, Retention, Store}
  alias InfluxElixir.Client.Options

  # Operations supported by each profile.
  # An operation not in the list returns {:error, :unsupported_operation}. The two InfluxDB 3
  # editions have the same operations; Enterprise's resource tokens are an option of
  # `create_token/3`, refused on Core by the engine's own answer.
  @v3_capabilities [
    :health,
    :write,
    :query_sql,
    :query_sql_stream,
    :execute_sql,
    :query_influxql,
    :create_database,
    :list_databases,
    :delete_database,
    :create_token,
    :delete_token
  ]

  @profile_capabilities %{
    v3_core: @v3_capabilities,
    v3_enterprise: @v3_capabilities,
    v2: [
      :health,
      :write,
      :query_flux,
      :create_bucket,
      :list_buckets,
      :delete_bucket
    ]
  }

  @doc "Whether `profile` is one `Client.Local` emulates."
  @spec profile?(term()) :: boolean()
  def profile?(profile), do: Map.has_key?(@profile_capabilities, profile)

  @doc "Whether the connection's profile has `operation`."
  @spec supports?(%{required(:profile) => atom(), optional(atom()) => term()}, atom()) ::
          boolean()
  def supports?(%{profile: profile}, operation) do
    operation in Map.fetch!(@profile_capabilities, profile)
  end

  @doc "`:ok`, or `{:error, :unsupported_operation}` when the profile lacks `operation`."
  @spec require_capability(%{required(:profile) => atom(), optional(atom()) => term()}, atom()) ::
          :ok | {:error, :unsupported_operation}
  def require_capability(conn, operation) do
    if supports?(conn, operation), do: :ok, else: {:error, :unsupported_operation}
  end

  @doc "Checks that a resource name is a valid UTF-8 string."
  @spec utf8_name(term(), binary()) :: :ok | {:error, map()}
  def utf8_name(name, kind) when is_binary(name) do
    if String.valid?(name),
      do: :ok,
      else: {:error, %{status: 400, body: "Client.Local: the #{kind} name is not valid UTF-8"}}
  end

  # No engine answer exists for a name that is not text: refused by name, never raised.
  def utf8_name(_name, kind),
    do: {:error, %{status: 400, body: "Client.Local: the #{kind} name is not a string"}}

  @doc """
  The database of a call, as `Client.HTTP.resolve_database/2` has it:
  `opts[:database]`, then the connection-level default; neither is the HTTP
  client's error.
  """
  @spec resolve_database(keyword(), map()) ::
          {:ok, binary()} | {:error, :no_database_specified | map()}
  def resolve_database(opts, conn) do
    case Options.database(opts, conn) do
      nil -> {:error, :no_database_specified}
      database -> with :ok <- utf8_name(database, "database"), do: {:ok, database}
    end
  end

  @doc """
  `:ok` when the engine has `database` (verified: SQL of any kind and
  InfluxQL other than `SHOW DATABASES` answer 404 otherwise). `_internal`
  exists on the engine, but its system tables are not modelled.
  """
  @spec database_exists(Store.t(), binary()) :: :ok | {:error, map()}
  def database_exists(table, database) do
    cond do
      Store.database?(table, database) ->
        :ok

      database == DatabaseRules.internal() ->
        {:error,
         %{
           status: 400,
           body: "Client.Local: the _internal database's system tables are not modelled"
         }}

      not String.valid?(database) ->
        utf8_name(database, "database")

      true ->
        {:error,
         %{
           status: 404,
           body: Jason.encode!(%{"error" => "query error: database not found: #{database}"})
         }}
    end
  end

  @doc """
  The SQL executor's view of the store: a table's points, or `:error` for
  one the catalog does not have (the engine's "table not found"). A table
  exists once a write registered its columns, not while it holds points:
  an Enterprise DELETE of every row leaves an empty table, which answers
  no rows as a DataFusion table does.
  """
  @spec point_source(Store.t(), binary(), binary()) ::
          {:ok, [LineProtocolParser.point()]} | :error
  def point_source(table, database, measurement) do
    if Store.table?(table, database, measurement),
      do: {:ok, Store.points(table, database, measurement)},
      else: :error
  end

  @doc "The databases the engine lists, its own `_internal` among them (sorted)."
  @spec database_names(Store.t()) :: [binary()]
  def database_names(table) do
    table |> Store.databases() |> MapSet.put(DatabaseRules.internal()) |> Enum.sort()
  end

  @doc """
  A database's retention in whole seconds, or `nil` for none: `_internal`
  keeps seven days (verified), a database its `retention_period`.
  """
  @spec retention(Store.t(), binary()) :: Retention.t()
  def retention(_table, "_internal"), do: 7 * 86_400
  def retention(table, database), do: Store.retention(table, database)

  @doc "`format:` as `Client.HTTP` sends it; see `InfluxElixir.Client.Local.Format`."
  @spec query_format(keyword()) :: term()
  defdelegate query_format(opts), to: Options
end
