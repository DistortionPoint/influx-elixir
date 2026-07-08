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

  On the HTTP transport the response is decoded incrementally, so memory stays
  constant regardless of result size. Error classes (missing database, non-2xx
  status, transport failure) are raised as an `InfluxElixir.StreamError` when
  the stream is enumerated rather than surfacing as an empty result.

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
