defmodule InfluxElixir.Query.SQL do
  @moduledoc """
  v3 SQL query builder and executor.

  Each function is the `InfluxElixir` facade function of the same operation:
  it takes a connection or a connection name, and queries emit the same
  telemetry span.

  Supports parameterized queries with `$param` placeholders
  and multiple response formats (JSON, JSONL, CSV, Parquet).

  ## Parameterized Queries

  Always use `$param` placeholders to prevent injection:

      InfluxElixir.Query.SQL.query(conn,
        "SELECT * FROM prices WHERE symbol = $symbol",
        params: %{symbol: "BTC-USD"}
      )

  ## Response Formats

  Supported via the `:format` option:

    * `:json` — default, returns parsed list of maps
    * `:jsonl` — newline-delimited JSON
    * `:csv` — rows whose values are the engine's CSV strings (`"1.5"`,
      `"1e16"`, `"true"`); timestamps are still `DateTime`s and an empty
      cell is absent, as a null column is in JSON. A nested value
      (`array_agg`, a `selector_*` struct) cannot be written as CSV: the
      server closes the connection, `{:error, {:connection_error, _}}`
    * `:parquet` — Apache Parquet binary (`Client.Local` refuses it by name)

  ## Transport

  Use `:transport` option to select query transport:

    * `:http` — default, via Finch HTTP client
    * `:flight` — via Arrow Flight gRPC
  """

  @type format :: :json | :jsonl | :csv | :parquet
  @type transport :: :http | :flight

  @doc """
  Executes a SQL query and returns parsed results.

  ## Options

    * `:params` - parameter map for `$param` substitution
    * `:database` - override the default database
    * `:format` - response format (default: `:json`)
    * `:transport` - query transport (default: `:http`)
  """
  @spec query(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query(connection, sql, opts \\ []) do
    InfluxElixir.query_sql(connection, sql, opts)
  end

  @doc """
  Executes a SQL query and returns a lazy Stream.

  For large result sets to avoid loading all rows into memory.

  ## Options

  Same as `query/3`.
  """
  @spec query_stream(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: Enumerable.t()
  def query_stream(connection, sql, opts \\ []) do
    InfluxElixir.query_sql_stream(
      connection,
      sql,
      opts
    )
  end

  @doc """
  Sends a SQL statement as it is; see `InfluxElixir.execute_sql/3` for what
  InfluxDB 3 accepts (Core refuses DML and DDL).

  ## Options

    * `:params` - parameter map for `$param` substitution
    * `:database` - override the default database
  """
  @spec execute(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map() | [map()]} | {:error, term()}
  def execute(connection, sql, opts \\ []) do
    InfluxElixir.execute_sql(connection, sql, opts)
  end
end
