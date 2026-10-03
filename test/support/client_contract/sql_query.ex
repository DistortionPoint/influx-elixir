defmodule InfluxElixir.ClientContract.SqlQuery do
  @moduledoc """
  The `:sql_query` part of `InfluxElixir.ClientContract`:
  SQL queries: basic SELECT, round trips, streams, aggregates, statistics, time
  filters, CTEs, WHERE, casts (the InfluxDB 3 profiles).
  """

  @doc false
  @spec blocks(Macro.t(), atom()) :: [Macro.t()]
  def blocks(client, profile) when profile in [:v3_core, :v3_enterprise] do
    [
      sql_tests(client),
      roundtrip_tests(client),
      stream_tests(client),
      aggregate_tests(client),
      stats_tests(client),
      time_filter_tests(client),
      cte_tests(client),
      where_tests(client),
      cast_tests(client),
      cast_spelling_tests(client)
    ]
  end

  def blocks(_client, _profile), do: []

  defp sql_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — basic SELECT contract" do
        test "a line without a timestamp is stamped with the server's current time", ctx do
          # The context's `time_slack` (seconds) is how far the server's clock may be from ours.
          slack = Map.get(ctx, :time_slack, 5)
          before_write = DateTime.add(DateTime.utc_now(), -slack, :second)

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "auto_ts_sql,host=a value=1i",
              database: ctx.database
            )

          after_write = DateTime.add(DateTime.utc_now(), slack, :second)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [row]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM auto_ts_sql",
                     database: ctx.database
                   )

          assert %{"host" => "a", "value" => 1, "time" => %DateTime{} = time} = row
          assert DateTime.compare(time, before_write) === :gt
          assert DateTime.compare(time, after_write) === :lt
        end

        test "LIMIT restricts the number of returned rows", ctx do
          Enum.each(1..5, fn i ->
            assert {:ok, :written} =
                     unquote(client).write(
                       ctx.conn,
                       "contract_limited value=#{i}i #{i * 1_000_000_000}",
                       database: ctx.database
                     )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [
                    %{"value" => 1, "time" => ~U[1970-01-01 00:00:01.000000Z]},
                    %{"value" => 2, "time" => ~U[1970-01-01 00:00:02.000000Z]}
                  ]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_limited ORDER BY time LIMIT 2",
                     database: ctx.database
                   )
        end

        test "ORDER BY time DESC returns most-recent rows first", ctx do
          # Written out of order, so the result can only be ordered by the query.
          Enum.each([2, 3, 1], fn s ->
            assert {:ok, :written} =
                     unquote(client).write(
                       ctx.conn,
                       "contract_ordered value=#{s * 100}i #{s * 1_000_000_000}",
                       database: ctx.database
                     )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [
                    %{"value" => 300, "time" => ~U[1970-01-01 00:00:03.000000Z]},
                    %{"value" => 200, "time" => ~U[1970-01-01 00:00:02.000000Z]},
                    %{"value" => 100, "time" => ~U[1970-01-01 00:00:01.000000Z]}
                  ]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_ordered ORDER BY time DESC",
                     database: ctx.database
                   )
        end

        test "ORDER BY time ASC returns oldest rows first", ctx do
          Enum.each([2, 3, 1], fn s ->
            assert {:ok, :written} =
                     unquote(client).write(
                       ctx.conn,
                       "contract_ordered value=#{s * 100}i #{s * 1_000_000_000}",
                       database: ctx.database
                     )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, ascending} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT value FROM contract_ordered ORDER BY time ASC",
                     database: ctx.database
                   )

          assert Enum.map(ascending, & &1["value"]) === [100, 200, 300]
        end

        test "WHERE clause filters by tag value", ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_tagged,host=alpha value=1i 1000000000",
                     database: ctx.database
                   )

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_tagged,host=beta value=2i 2000000000",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [%{"host" => "alpha", "value" => 1, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_tagged WHERE host = 'alpha'",
                     database: ctx.database
                   )
        end
      end

      unquote(multi_measurement_tests(client))
    end
  end

  defp multi_measurement_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — multiple measurements contract" do
        test "querying one measurement does not return rows from another",
             ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_a value=1i 1000000000",
                     database: ctx.database
                   )

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_b value=2i 2000000000",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"value" => 1, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_a",
                     database: ctx.database
                   )

          assert {:ok, [%{"value" => 2, "time" => ~U[1970-01-01 00:00:02.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_b",
                     database: ctx.database
                   )
        end
      end
    end
  end

  defp roundtrip_tests(client) do
    quote location: :keep do
      describe "field type round-trips — contract" do
        test "integer field survives write/query cycle", ctx do
          ts = System.os_time(:nanosecond)
          lp = "contract_rt,type=int count=#{ts}i #{ts}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'int' LIMIT 1",
              database: ctx.database
            )

          assert [%{"count" => ^ts}] = rows
        end

        test "float field survives write/query cycle", ctx do
          lp = "contract_rt,type=float ratio=3.14"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'float' LIMIT 1",
              database: ctx.database
            )

          assert [%{"ratio" => 3.14}] = rows
        end

        test "string field survives write/query cycle", ctx do
          lp = ~s(contract_rt,type=string label="hello world")

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'string' LIMIT 1",
              database: ctx.database
            )

          assert [%{"label" => "hello world"}] = rows
        end

        test "boolean field survives write/query cycle", ctx do
          lp = "contract_rt,type=bool active=true"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'bool' LIMIT 1",
              database: ctx.database
            )

          assert [%{"active" => true}] = rows
        end

        test "tags and every field kind come back as written, the time in microseconds",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_rtall")

          lp =
            ~s|#{m},host=s1,region=us-east a=1i,b=2.0,c="hi",d=false,e=-42i,f=-3.14,g=1.5e10 | <>
              "1630424257123456789"

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).query_sql(ctx.conn, "SELECT * FROM #{m}", database: ctx.database) ===
                   {:ok,
                    [
                      %{
                        "host" => "s1",
                        "region" => "us-east",
                        "a" => 1,
                        "b" => 2.0,
                        "c" => "hi",
                        "d" => false,
                        "e" => -42,
                        "f" => -3.14,
                        "g" => 15_000_000_000.0,
                        "time" => ~U[2021-08-31 15:37:37.123456Z]
                      }
                    ]}
        end

        test "comments and blank lines between lines are skipped", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_rtcmt")
          lp = "# This is a comment\n\n#{m} value=1i 1\n\n# Another comment\n#{m} value=2i 2\n"

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).query_sql(
                   ctx.conn,
                   "SELECT value FROM #{m} ORDER BY time",
                   database: ctx.database
                 ) === {:ok, [%{"value" => 1}, %{"value" => 2}]}
        end
      end
    end
  end

  defp stream_tests(client) do
    quote location: :keep do
      describe "query_sql_stream/3 — contract" do
        test "streams every row written, as maps with a DateTime time and integer values", ctx do
          Enum.each(1..5, fn i ->
            {:ok, :written} =
              unquote(client).write(
                ctx.conn,
                "contract_stream value=#{i}i #{i * 1_000_000}",
                database: ctx.database
              )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          stream =
            unquote(client).query_sql_stream(
              ctx.conn,
              "SELECT * FROM contract_stream",
              database: ctx.database
            )

          rows = Enum.to_list(stream)

          assert Enum.sort(Enum.map(rows, & &1["value"])) === [1, 2, 3, 4, 5]
          assert Enum.all?(rows, &is_struct(&1["time"], DateTime))
          assert Enum.all?(rows, &(Enum.sort(Map.keys(&1)) === ["time", "value"]))

          times = rows |> Enum.sort_by(& &1["value"]) |> Enum.map(& &1["time"])
          assert times === Enum.map(1..5, &DateTime.from_unix!(&1 * 1_000_000, :nanosecond))
        end
      end
    end
  end

  defp aggregate_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — aggregate contract" do
        setup ctx do
          # Known timestamps, written out of order
          base_ts = 1_700_000_000_000_000_000

          Enum.each([3, 0, 5, 1, 4, 2], fn i ->
            ts = base_ts + i * 60_000_000_000
            val = (i + 1) * 10

            {:ok, :written} =
              unquote(client).write(
                ctx.conn,
                "contract_agg value=#{val}i #{ts}",
                database: ctx.database
              )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, agg_base_ts: base_ts}
        end

        test "AVG aggregate with GROUP BY DATE_BIN", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '2 minutes', time) AS time,
            AVG(value) AS avg_val
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '2 minutes', time)
          ORDER BY time ASC
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert rows === [
                   %{"time" => ~U[2023-11-14 22:12:00.000000Z], "avg_val" => 10.0},
                   %{"time" => ~U[2023-11-14 22:14:00.000000Z], "avg_val" => 25.0},
                   %{"time" => ~U[2023-11-14 22:16:00.000000Z], "avg_val" => 45.0},
                   %{"time" => ~U[2023-11-14 22:18:00.000000Z], "avg_val" => 60.0}
                 ]
        end

        test "SUM aggregate returns total", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            SUM(value) AS total
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          # All six points fall in the 22:00 hour: 10+20+30+40+50+60.
          assert [%{"total" => 210}] = rows
        end

        test "COUNT aggregate returns row count", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            COUNT(value) AS cnt
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert [%{"cnt" => 6}] = rows
        end

        test "MIN and MAX aggregates", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            MIN(value) AS min_val,
            MAX(value) AS max_val
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert [%{"min_val" => 10, "max_val" => 60}] = rows
        end
      end
    end
  end

  defp stats_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — statistics and selectors contract" do
        setup ctx do
          # Same six points as the aggregate contract: 10..60 one minute apart.
          base_ts = 1_700_000_000_000_000_000

          Enum.each([3, 0, 5, 1, 4, 2], fn i ->
            ts = base_ts + i * 60_000_000_000
            val = (i + 1) * 10

            {:ok, :written} =
              unquote(client).write(
                ctx.conn,
                "contract_agg value=#{val}i #{ts}",
                database: ctx.database
              )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, agg_base_ts: base_ts}
        end

        test "STDDEV / VAR family and aggregates over expression arguments (#16)", ctx do
          sql = """
          SELECT
            COUNT(value) AS n,
            STDDEV(value) AS sd,
            STDDEV_POP(value) AS sd_pop,
            VAR(value) AS v,
            VAR_POP(value) AS v_pop,
            SUM(value * value) AS sum_sq,
            AVG(value / 2) AS half_avg,
            MAX(value - 1) AS max_less_one
          FROM contract_agg
          """

          {:ok, [row]} =
            unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          # values 10..60 step 10
          assert row["n"] === 6

          InfluxElixir.TestSupport.Check.assert_rows_close(
            Map.take(row, ["sd", "sd_pop", "v", "v_pop"]),
            %{
              "sd" => 18.708286933869708,
              "sd_pop" => 17.07825127659933,
              "v" => 350.0,
              "v_pop" => 291.6666666666667
            }
          )

          assert row["sum_sq"] === 9100
          assert row["half_avg"] === 17.5
          assert row["max_less_one"] === 59
        end

        test "a sample statistic over one row is null, absent from the row (#16)", ctx do
          sql_one = """
          SELECT STDDEV(value) AS sd, COUNT(value) AS n
          FROM contract_agg
          WHERE value = 10
          """

          {:ok, [one]} =
            unquote(client).query_sql(ctx.conn, sql_one, database: ctx.database)

          assert one["n"] === 1
          refute Map.has_key?(one, "sd")
        end

        test "selector functions and ORDER BY the DATE_BIN alias (#17)", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '3 minutes', time) AS bucket,
            selector_first(value, time)['value'] AS open,
            selector_max(value, time)['value'] AS high,
            selector_min(value, time)['time'] AS low_at,
            selector_last(value, time)['value'] AS close
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '3 minutes', time)
          ORDER BY bucket DESC
          """

          {:ok, [late, mid, early]} =
            unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          # base_ts is 22:13:20, so 3-minute bins hold [10,20], [30,40,50], [60].
          assert DateTime.compare(late["bucket"], mid["bucket"]) === :gt
          assert DateTime.compare(mid["bucket"], early["bucket"]) === :gt
          assert early["open"] === 10 and early["high"] === 20 and early["close"] === 20
          assert mid["open"] === 30 and mid["high"] === 50 and mid["close"] === 50
          assert late["open"] === 60 and late["high"] === 60 and late["close"] === 60

          # selector_*['time'] is a DateTime on every transport.
          assert early["low_at"] ==
                   ctx.agg_base_ts
                   |> DateTime.from_unix!(:nanosecond)
                   |> DateTime.truncate(:microsecond)
        end

        test "ORDER BY a projected aggregate alias", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '3 minutes', time) AS bucket,
            SUM(value) AS total
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '3 minutes', time)
          ORDER BY total DESC
          """

          {:ok, rows} =
            unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          assert Enum.map(rows, & &1["total"]) === [120, 60, 30]
        end
      end
    end
  end

  defp time_filter_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — time comparand, null check and COUNT DISTINCT contract" do
        setup ctx do
          now_ns = System.os_time(:nanosecond)

          lp =
            Enum.join(
              [
                "contract_tf,provider=a,symbol=X price=1.0,bid=1.0 #{now_ns - 60_000_000_000}",
                "contract_tf,provider=a,symbol=X price=2.0 #{now_ns - 600_000_000_000}",
                "contract_tf,provider=b,symbol=Y price=3.0,bid=3.0 #{now_ns - 3_600_000_000_000}",
                "contract_tf,provider=c,symbol=Z price=4.0 #{now_ns - 7_200_000_000_000}"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)
          {:ok, now_ns: now_ns}
        end

        test "now() - INTERVAL filters relative to the query time", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT price FROM contract_tf WHERE time >= now() - INTERVAL '2 minutes'",
              database: ctx.database
            )

          assert Enum.map(rows, & &1["price"]) === [1.0]
        end

        test "a DateTime param against time selects by instant", ctx do
          start = DateTime.add(DateTime.utc_now(), -120, :second)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT price FROM contract_tf WHERE time >= $start",
              database: ctx.database,
              params: %{start: start}
            )

          assert Enum.map(rows, & &1["price"]) === [1.0]
        end

        test "IS NULL and IS NOT NULL", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT price FROM contract_tf WHERE bid IS NOT NULL ORDER BY price",
              database: ctx.database
            )

          assert Enum.map(rows, & &1["price"]) === [1.0, 3.0]

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT price FROM contract_tf WHERE bid IS NULL ORDER BY price",
              database: ctx.database
            )

          assert Enum.map(rows, & &1["price"]) === [2.0, 4.0]
        end

        unquote(time_filter_distinct_tests(client))
      end
    end
  end

  defp time_filter_distinct_tests(client) do
    quote location: :keep do
      test "MAX(time), MIN(time) and COUNT(time) answer DateTimes and a count", ctx do
        {:ok, [row]} =
          unquote(client).query_sql(
            ctx.conn,
            "SELECT MAX(time) AS mx, MIN(time) AS mn, COUNT(time) AS n FROM contract_tf",
            database: ctx.database
          )

        # The newest point is a minute old, the oldest two hours (written in
        # nanoseconds, read back in microseconds).
        newest = DateTime.from_unix!(div(ctx.now_ns - 60_000_000_000, 1000), :microsecond)
        oldest = DateTime.from_unix!(div(ctx.now_ns - 7_200_000_000_000, 1000), :microsecond)

        assert DateTime.compare(row["mx"], newest) === :eq
        assert DateTime.compare(row["mn"], oldest) === :eq
        assert row["n"] === 4
      end

      test "arithmetic on time inside an aggregate fails planning", ctx do
        assert {:error,
                %{
                  status: 400,
                  body:
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Timestamp(ns) - Int64 to valid types"
                }} =
                 unquote(client).query_sql(
                   ctx.conn,
                   "SELECT MAX(time - 1) AS s FROM contract_tf",
                   database: ctx.database
                 )
      end

      test "SELECT DISTINCT honours ORDER BY DESC and LIMIT", ctx do
        {:ok, rows} =
          unquote(client).query_sql(
            ctx.conn,
            "SELECT DISTINCT provider, symbol FROM contract_tf ORDER BY symbol DESC LIMIT 2",
            database: ctx.database
          )

        assert rows === [
                 %{"provider" => "c", "symbol" => "Z"},
                 %{"provider" => "b", "symbol" => "Y"}
               ]
      end
    end
  end

  defp cte_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — projected expression and CTE contract" do
        setup ctx do
          lp =
            Enum.join(
              [
                "contract_cte,provider=a bid=1.0,ask=3.0 1700000000000000000",
                "contract_cte,provider=a bid=2.0,ask=4.0 1700000060000000000",
                "contract_cte,provider=b bid=5.0,ask=7.0 1700000121000000000",
                "contract_cte,provider=b bid=10.0 1700000120000000000"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)
          :ok
        end

        test "arithmetic in a projected column, null omitted, ORDER BY alias", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT (bid + ask) / 2 AS mid, time FROM contract_cte ORDER BY time",
              database: ctx.database
            )

          assert Enum.map(rows, &Map.get(&1, "mid")) === [2.0, 3.0, nil, 6.0]
          refute Map.has_key?(Enum.at(rows, 2), "mid")

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT (bid + ask) / 2 AS mid FROM contract_cte ORDER BY mid DESC",
              database: ctx.database
            )

          assert Enum.map(rows, &Map.get(&1, "mid")) === [nil, 6.0, 3.0, 2.0]
        end

        test "a CTE with a qualified DATE_BIN GROUP BY", ctx do
          sql = """
          WITH w AS (SELECT bid, time FROM contract_cte)
          SELECT DATE_BIN(INTERVAL '1 minute', w.time) AS time, MAX(w.bid) AS hi
          FROM w GROUP BY DATE_BIN(INTERVAL '1 minute', w.time) ORDER BY time
          """

          {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          assert Enum.map(rows, &{&1["time"], &1["hi"]}) === [
                   {~U[2023-11-14 22:13:00.000000Z], 1.0},
                   {~U[2023-11-14 22:14:00.000000Z], 2.0},
                   {~U[2023-11-14 22:15:00.000000Z], 10.0}
                 ]
        end

        test "the candle shape: derived mid in a CTE, selectors over it", ctx do
          sql = """
          WITH w AS (SELECT (bid + ask) / 2 AS mid, time FROM contract_cte WHERE ask IS NOT NULL)
          SELECT
            DATE_BIN(INTERVAL '1 minute', time) AS time,
            selector_first(mid, time)['value'] AS open,
            MAX(mid) AS high,
            selector_last(mid, time)['value'] AS close
          FROM w
          GROUP BY DATE_BIN(INTERVAL '1 minute', time)
          ORDER BY time
          """

          {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          assert Enum.map(rows, &{&1["open"], &1["high"], &1["close"]}) ==
                   [{2.0, 2.0, 2.0}, {3.0, 3.0, 3.0}, {6.0, 6.0, 6.0}]
        end

        test "chained CTEs and table aliases", ctx do
          sql = """
          WITH w AS (SELECT bid, provider, time FROM contract_cte),
               x AS (SELECT provider, MAX(bid) AS mb FROM w GROUP BY provider)
          SELECT * FROM x ORDER BY provider
          """

          {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)
          assert rows === [%{"provider" => "a", "mb" => 2.0}, %{"provider" => "b", "mb" => 10.0}]

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT t.bid FROM contract_cte t WHERE t.provider = 'b' ORDER BY t.bid",
              database: ctx.database
            )

          assert rows === [%{"bid" => 5.0}, %{"bid" => 10.0}]
        end
      end
    end
  end

  defp where_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — WHERE boolean logic contract" do
        setup ctx do
          lp =
            Enum.join(
              [
                "contract_wh,host=a,rack=1 v=1.0 1700000001000000000",
                "contract_wh,host=c v=3.0 1700000003000000000",
                "contract_wh,host=d,rack=4 v=4.0 1700000004000000000",
                "contract_wh,host=e,rack=10 v=5.0 1700000005000000000",
                "contract_wh,host=b,rack=2 v=2.5 1700000002000000000"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)
          :ok
        end

        test "OR, NOT, parentheses and precedence", ctx do
          assert InfluxElixir.ClientContract.column(
                   unquote(client),
                   ctx,
                   "host",
                   "SELECT host FROM contract_wh WHERE v > 3 OR v < 2 ORDER BY host"
                 ) ==
                   ["a", "d", "e"]

          assert InfluxElixir.ClientContract.column(
                   unquote(client),
                   ctx,
                   "host",
                   "SELECT host FROM contract_wh WHERE host = 'a' OR host = 'b' AND v > 2 ORDER BY host"
                 ) ==
                   ["a", "b"]

          assert InfluxElixir.ClientContract.column(
                   unquote(client),
                   ctx,
                   "host",
                   "SELECT host FROM contract_wh WHERE (host = 'a' OR host = 'b') AND v > 2"
                 ) ==
                   ["b"]

          assert InfluxElixir.ClientContract.column(
                   unquote(client),
                   ctx,
                   "host",
                   "SELECT host FROM contract_wh WHERE NOT (host = 'a' OR host = 'b') ORDER BY host"
                 ) ==
                   ["c", "d", "e"]

          assert InfluxElixir.ClientContract.column(
                   unquote(client),
                   ctx,
                   "host",
                   "SELECT host FROM contract_wh WHERE v <> 1.0 ORDER BY host"
                 ) ==
                   ["b", "c", "d", "e"]
        end

        unquote(where_pattern_tests(client))
      end
    end
  end

  defp where_pattern_tests(client) do
    quote location: :keep do
      test "BETWEEN, LIKE, ILIKE and string-vs-number comparison", ctx do
        assert InfluxElixir.ClientContract.column(
                 unquote(client),
                 ctx,
                 "host",
                 "SELECT host FROM contract_wh WHERE v BETWEEN 2 AND 3 ORDER BY host"
               ) ==
                 ["b", "c"]

        assert InfluxElixir.ClientContract.column(
                 unquote(client),
                 ctx,
                 "host",
                 "SELECT host FROM contract_wh WHERE v NOT BETWEEN 2 AND 3 ORDER BY host"
               ) ==
                 ["a", "d", "e"]

        assert InfluxElixir.ClientContract.column(
                 unquote(client),
                 ctx,
                 "host",
                 "SELECT host FROM contract_wh WHERE time BETWEEN '2023-11-14T22:13:22Z' AND '2023-11-14T22:13:23Z' ORDER BY host"
               ) ==
                 ["b", "c"]

        assert InfluxElixir.ClientContract.column(
                 unquote(client),
                 ctx,
                 "host",
                 "SELECT host FROM contract_wh WHERE host LIKE 'a%'"
               ) === ["a"]

        assert InfluxElixir.ClientContract.column(
                 unquote(client),
                 ctx,
                 "host",
                 "SELECT host FROM contract_wh WHERE host LIKE 'A%'"
               ) === []

        assert InfluxElixir.ClientContract.column(
                 unquote(client),
                 ctx,
                 "host",
                 "SELECT host FROM contract_wh WHERE host ILIKE 'A%'"
               ) === ["a"]

        assert InfluxElixir.ClientContract.column(
                 unquote(client),
                 ctx,
                 "host",
                 "SELECT host FROM contract_wh WHERE host NOT LIKE 'a%' ORDER BY host"
               ) ==
                 ["b", "c", "d", "e"]

        assert InfluxElixir.ClientContract.column(
                 unquote(client),
                 ctx,
                 "host",
                 "SELECT host FROM contract_wh WHERE rack = 2"
               ) === ["b"]

        assert InfluxElixir.ClientContract.column(
                 unquote(client),
                 ctx,
                 "host",
                 "SELECT host FROM contract_wh WHERE rack > 3 ORDER BY host"
               ) === ["d"]

        assert InfluxElixir.ClientContract.column(
                 unquote(client),
                 ctx,
                 "host",
                 "SELECT host FROM contract_wh WHERE rack >= 10 ORDER BY host"
               ) ==
                 ["b", "d", "e"]

        assert {:error,
                %{
                  status: 400,
                  body:
                    "type_coercion\ncaused by\nError during planning: There isn't a common " <>
                      "type to coerce Float64 and Utf8 in LIKE expression"
                }} =
                 unquote(client).query_sql(
                   ctx.conn,
                   "SELECT host FROM contract_wh WHERE v LIKE '1%'",
                   database: ctx.database
                 )
      end

      test "LIMIT 0 returns no rows", ctx do
        assert {:ok, []} =
                 unquote(client).query_sql(ctx.conn, "SELECT host FROM contract_wh LIMIT 0",
                   database: ctx.database
                 )
      end
    end
  end

  defp cast_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — CAST and ORDER BY contract" do
        setup ctx do
          InfluxElixir.ClientContract.SqlQuery.write_cast_fixture(unquote(client), ctx)
          :ok
        end

        test "CAST(tag AS INTEGER) compares numerically in WHERE, ORDER BY and an aggregate",
             ctx do
          assert InfluxElixir.ClientContract.column(
                   unquote(client),
                   ctx,
                   "level",
                   "SELECT level FROM contract_cast WHERE CAST(level AS INTEGER) <= 20 AND symbol = 'X' ORDER BY time"
                 ) ==
                   ["5", "20"]

          assert InfluxElixir.ClientContract.column(
                   unquote(client),
                   ctx,
                   "level",
                   "SELECT level FROM contract_cast WHERE level::INTEGER <= 20 AND symbol = 'X' ORDER BY time"
                 ) ==
                   ["5", "20"]

          assert InfluxElixir.ClientContract.column(
                   unquote(client),
                   ctx,
                   "level",
                   "SELECT level FROM contract_cast WHERE symbol = 'X' ORDER BY CAST(level AS INTEGER) DESC"
                 ) ==
                   ["100", "20", "5"]

          {:ok, [row]} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT MAX(CAST(level AS INTEGER)) AS m, MAX(CAST(price AS INTEGER)) AS p FROM contract_cast",
              database: ctx.database
            )

          assert row === %{"m" => 100, "p" => 9}

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT symbol, level FROM contract_cast ORDER BY symbol DESC, CAST(level AS INTEGER) ASC",
              database: ctx.database
            )

          assert Enum.map(rows, &{&1["symbol"], &1["level"]}) ==
                   [{"Y", "20"}, {"X", "5"}, {"X", "20"}, {"X", "100"}]
        end

        test "a cast that cannot be performed is a transport-level failure", ctx do
          # InfluxDB 3 Core closes the connection mid-response instead of
          # sending an error body; both clients report it as a closed transport.
          assert {:error, {:connection_error, %Mint.TransportError{reason: :closed}}} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT level FROM contract_cast_bad WHERE CAST(level AS INTEGER) <= 20",
                     database: ctx.database
                   )

          assert {:error, {:connection_error, %Mint.TransportError{reason: :closed}}} ===
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT CAST(time AS INTEGER) AS t FROM contract_cast LIMIT 1",
                     database: ctx.database
                   )
        end
      end
    end
  end

  defp cast_spelling_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — CAST spellings and ORDER BY terms contract" do
        setup ctx do
          InfluxElixir.ClientContract.SqlQuery.write_cast_fixture(unquote(client), ctx)
          :ok
        end

        test "CAST spellings and targets, in WHERE, as parameters and uncast", ctx do
          for sql <- [
                "CAST(level AS INTEGER) <= 20",
                "CAST(level AS BIGINT) <= 20",
                "CAST(level AS INT) <= 20",
                "level::INTEGER <= 20",
                "CAST(level AS DOUBLE) <= 20.5",
                "CAST(level AS INTEGER) * 2 <= 40",
                "CAST(level AS INTEGER) BETWEEN 5 AND 20"
              ] do
            assert {sql,
                    InfluxElixir.ClientContract.column(
                      unquote(client),
                      ctx,
                      "level",
                      "SELECT level FROM contract_cast WHERE #{sql} AND symbol = 'X' ORDER BY time"
                    )} === {sql, ["5", "20"]}
          end

          for {where, expected} <- [
                {"CAST(qty AS VARCHAR) = '2'", ["20"]},
                {"CAST(qty AS VARCHAR) LIKE '2%'", ["20"]},
                # The uncast comparison is the lexical one: "100" sorts before "20".
                {"level <= '20'", ["20", "100", "20"]}
              ] do
            assert {where,
                    InfluxElixir.ClientContract.column(
                      unquote(client),
                      ctx,
                      "level",
                      "SELECT level FROM contract_cast WHERE #{where} ORDER BY time"
                    )} === {where, expected}
          end

          assert {:ok, [%{"level" => "20"}, %{"level" => "5"}]} ===
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT level FROM contract_cast WHERE time >= $start AND symbol = $symbol " <>
                       "AND CAST(level AS INTEGER) <= $depth ORDER BY time DESC LIMIT $row_limit",
                     database: ctx.database,
                     params: %{
                       start: ~U[2023-01-01 00:00:00Z],
                       symbol: "X",
                       depth: 20,
                       row_limit: 10
                     }
                   )
        end

        test "CAST in a projection, an aggregate and arithmetic", ctx do
          for {sql, expected} <- [
                {"SELECT CAST(level AS INTEGER) AS r FROM contract_cast ORDER BY r",
                 [5, 20, 20, 100]},
                {"SELECT MAX(CAST(level AS INTEGER)) AS r FROM contract_cast", [100]},
                # A float truncates to an integer; an integer widens to a double.
                {"SELECT CAST(price AS INTEGER) AS r FROM contract_cast ORDER BY r",
                 [1, 2, 3, 9]},
                {"SELECT CAST(qty AS DOUBLE) AS r FROM contract_cast ORDER BY r",
                 [1.0, 2.0, 3.0, 9.0]},
                {"SELECT CAST(level AS INTEGER) + qty AS r FROM contract_cast ORDER BY r",
                 [6, 22, 29, 103]},
                # A whole-string float is a DOUBLE, not an INTEGER.
                {"SELECT CAST(level AS DOUBLE) AS r FROM contract_cast_bad WHERE level = '2.5'",
                 [2.5]}
              ] do
            assert {sql, InfluxElixir.ClientContract.column(unquote(client), ctx, "r", sql)} ===
                     {sql, expected}
          end
        end

        test "ORDER BY several terms, each with its own direction", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT symbol, level FROM contract_cast ORDER BY level, symbol DESC",
              database: ctx.database
            )

          assert Enum.map(rows, &{&1["symbol"], &1["level"]}) === [
                   {"X", "100"},
                   {"Y", "20"},
                   {"X", "20"},
                   {"X", "5"}
                 ]

          assert {:ok, [%{"m" => 9.9, "symbol" => "X"}, %{"m" => 1.1, "symbol" => "Y"}]} ===
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT symbol, MAX(price) AS m FROM contract_cast " <>
                       "GROUP BY symbol ORDER BY m DESC, symbol",
                     database: ctx.database
                   )
        end
      end
    end
  end

  @doc false
  # The tables the CAST tests read.
  @spec write_cast_fixture(module(), map()) :: :ok
  def write_cast_fixture(client, ctx) do
    lp =
      Enum.join(
        [
          "contract_cast,symbol=X,level=5 price=2.7,qty=1i 1700000000000000000",
          "contract_cast,symbol=X,level=20 price=3.2,qty=2i 1700000001000000000",
          "contract_cast,symbol=X,level=100 price=9.9,qty=3i 1700000002000000000",
          "contract_cast,symbol=Y,level=20 price=1.1,qty=9i 1700000003000000000",
          "contract_cast_bad,level=abc price=1.0 1700000000000000000",
          "contract_cast_bad,level=2.5 price=1.0 1700000001000000000"
        ],
        "\n"
      )

    {:ok, :written} = client.write(ctx.conn, lp, database: ctx.database)
    InfluxElixir.ClientContract.settle(ctx)
    :ok
  end
end
