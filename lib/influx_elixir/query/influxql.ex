defmodule InfluxElixir.Query.InfluxQL do
  @moduledoc """
  v3 InfluxQL query executor for legacy query compatibility.

  InfluxQL is supported in InfluxDB v3 for backwards compatibility
  with v1/v2 query patterns.

  ## Usage

      InfluxElixir.Query.InfluxQL.query(conn,
        "SELECT mean(value) FROM cpu WHERE time > now() - 1h GROUP BY time(5m)"
      )
  """

  @doc """
  Executes an InfluxQL query and returns parsed results.

  ## Options

    * `:database` - override the default database
  """
  @spec query(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query(connection, influxql, opts \\ []) do
    InfluxElixir.Client.impl().query_influxql(
      connection,
      influxql,
      opts
    )
  end
end
