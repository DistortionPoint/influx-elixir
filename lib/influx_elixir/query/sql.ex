defmodule InfluxElixir.Query.SQL do
  @moduledoc """
  v3 SQL query builder and executor.

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
    * `:csv` — comma-separated values
    * `:parquet` — Apache Parquet binary

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
    InfluxElixir.Client.impl().query_sql(connection, sql, opts)
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
    InfluxElixir.Client.impl().query_sql_stream(
      connection,
      sql,
      opts
    )
  end

  @doc """
  Executes a non-SELECT SQL statement (DELETE, INSERT INTO ... SELECT).

  ## Options

    * `:params` - parameter map for `$param` substitution
    * `:database` - override the default database
  """
  @spec execute(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def execute(connection, sql, opts \\ []) do
    InfluxElixir.Client.impl().execute_sql(connection, sql, opts)
  end
end
