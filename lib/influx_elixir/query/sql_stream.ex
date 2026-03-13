defmodule InfluxElixir.Query.SQLStream do
  @moduledoc """
  Streaming JSONL query results as a lazy Elixir Stream.

  Uses Finch's streaming response support to parse JSONL
  line-by-line as chunks arrive from the HTTP response body.
  Provides constant-memory processing regardless of result size.

  ## Usage

      stream = InfluxElixir.Query.SQLStream.stream(conn,
        "SELECT * FROM candles ORDER BY time ASC",
        database: "candles"
      )

      stream
      |> Stream.each(&process_candle/1)
      |> Stream.run()
  """

  @doc """
  Creates a lazy Stream of query results.

  Each element in the stream is a parsed map representing one row.

  ## Options

    * `:params` - parameter map for `$param` substitution
    * `:database` - override the default database
  """
  @spec stream(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: Enumerable.t()
  def stream(connection, sql, opts \\ []) do
    InfluxElixir.Client.impl().query_sql_stream(
      connection,
      sql,
      opts
    )
  end
end
