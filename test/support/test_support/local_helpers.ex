defmodule InfluxElixir.TestSupport.LocalHelpers do
  @moduledoc """
  Query and write helpers shared by the `Client.Local` test files under
  `test/influx_elixir/client/local/`.

  Each helper wraps one `Client.Local` call and unwraps the `{:ok, _}` the
  test expects, so a test reads as the fact it pins. Every function is pure
  over the connection it is given, which keeps the files that import it
  `async: true`.
  """

  alias InfluxElixir.Client.Local

  # The `stop` of every `flux_b` query.
  @flux_b_stop 1_800_000_000

  @doc "Host tags of the rows a query returns, in order."
  @spec hosts(term(), String.t(), String.t()) :: [term()]
  def hosts(conn, db, sql), do: column_values(conn, db, sql, "host")

  @doc "Level tags of the rows a query returns, in order."
  @spec levels(term(), String.t(), String.t()) :: [term()]
  def levels(conn, db, sql), do: column_values(conn, db, sql, "level")

  @doc "A Flux query over bucket \"metrics\" selecting one measurement."
  @spec v2_flux(String.t()) :: String.t()
  def v2_flux(measurement) do
    ~s'from(bucket: "metrics") |> range(start: 0) |> filter(fn: (r) => r._measurement == "#{measurement}")'
  end

  @doc "The rows a SQL query returns."
  @spec sql_rows(term(), String.t(), String.t()) :: [map()]
  def sql_rows(conn, db, sql) do
    {:ok, rows} = Local.query_sql(conn, sql, database: db)
    rows
  end

  @doc "The value of `key` in each row a query returns, in order."
  @spec column_values(term(), String.t(), String.t(), String.t()) :: [term()]
  def column_values(conn, db, sql, key) do
    conn |> sql_rows(db, sql) |> Enum.map(& &1[key])
  end

  @doc "The tickers a WHERE clause over `holdings` selects, in time order."
  @spec holding_tickers(term(), String.t(), String.t()) :: [term()]
  def holding_tickers(conn, db, where) do
    column_values(conn, db, "SELECT * FROM holdings WHERE #{where} ORDER BY time", "ticker")
  end

  @doc "The sorted `{host, usage}` pairs a parameterised query selects."
  @spec param_rows(term(), String.t(), String.t(), map()) :: [{term(), term()}]
  def param_rows(conn, db, sql, params) do
    {:ok, rows} = Local.query_sql(conn, sql, params: params, database: db)
    rows |> Enum.map(&{&1["host"], &1["usage"]}) |> Enum.sort()
  end

  @doc "The start of the `hour`-th hour since the epoch."
  @spec hour_start(integer()) :: DateTime.t()
  def hour_start(hour), do: DateTime.from_unix!(hour * 3_600_000_000, :microsecond)

  @doc "InfluxQL against the \"iq\" database of the InfluxQL fixture."
  @spec iq_query(term(), String.t()) :: term()
  def iq_query(conn, statement), do: Local.query_influxql(conn, statement, database: "iq")

  @doc "The instant `us` microseconds past 1_700_000_000 s."
  @spec iq_time(integer()) :: DateTime.t()
  def iq_time(us), do: DateTime.from_unix!(1_700_000_000_000_000 + us, :microsecond)

  @doc "Flux over bucket \"b\" of the Flux pipeline fixture, with `tail` appended."
  @spec flux_b(term(), String.t()) :: term()
  def flux_b(conn, tail) do
    Local.query_flux(
      conn,
      ~s|from(bucket: "b") \|> range(start: 0, stop: #{@flux_b_stop})| <> tail
    )
  end
end
