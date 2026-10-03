defmodule InfluxElixir.Contract.SQLAggregates do
  @moduledoc """
  SQL aggregate and statement contract tests, run against
  `InfluxElixir.Client.Local` and against a real InfluxDB 3: the answers the
  double must give exactly as the engine does (rows, error status and body).
  Every expectation here was read from a Core.

      use InfluxElixir.Contract.SQLAggregates,
        client: InfluxElixir.Client.Local,
        profile: :v3_core

  The `setup` callback must return `conn` and `database`, as for
  the shared contract. Each test has a database of its own, so the measurement
  names are fixed. Every timestamp is explicit and in nanoseconds, so that the
  `DATE_BIN` buckets are known.

  ## Parts

  `part: part` generates one slice of the contract, for a module of its own that
  compiles and runs in parallel with its siblings. Without `:part` everything is
  generated.

    * `:buckets` — DISTINCT, bucketed and scalar aggregates, COUNT
    * `:candles` — first_value/last_value, OHLCV candles, median
    * `:statements` — CROSS JOIN, a failed stream, a quoted operand, DML and DDL
  """

  @parts [:buckets, :candles, :statements]

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)
    part = Keyword.get(opts, :part, :all)

    unless part == :all or part in @parts do
      raise ArgumentError,
            "unknown :part #{inspect(part)}, expected :all or one of #{inspect(@parts)}"
    end

    tests =
      for {test_part, block} <- test_blocks(client, profile),
          part == :all or part == test_part,
          do: block

    quote location: :keep do
      (unquote_splicing([helpers(client) | tests]))
    end
  end

  # Every block of tests with the part it belongs to, in order.
  @spec test_blocks(Macro.t(), atom()) :: [{atom(), Macro.t()}]
  defp test_blocks(client, profile) do
    [
      {:buckets, distinct_tests()},
      {:buckets, bucket_tests()},
      {:buckets, count_tests()},
      {:buckets, omission_tests()},
      {:candles, candle_tests()},
      {:candles, ordered_tests()},
      {:candles, median_tests()},
      {:statements, join_tests()},
      {:statements, stream_tests(client)},
      {:statements, column_tests()},
      {:statements, statement_tests(profile)}
    ]
  end

  defp helpers(client) do
    quote location: :keep do
      # 2023-11-14T00:00:00Z, and one hour, in nanoseconds.
      def sa_midnight, do: 1_699_920_000_000_000_000
      def sa_hour, do: 3_600_000_000_000

      def sa_write(ctx, lines) do
        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, Enum.join(lines, "\n"), database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)
      end

      def sa_query(ctx, sql, opts \\ []) do
        unquote(client).query_sql(ctx.conn, sql, [database: ctx.database] ++ opts)
      end

      def sa_execute(ctx, sql) do
        unquote(client).execute_sql(ctx.conn, sql, database: ctx.database)
      end

      def sa_rows(ctx, sql, opts \\ []) do
        assert {:ok, rows} = sa_query(ctx, sql, opts)
        rows
      end
    end
  end

  # ---------------------------------------------------------------------------
  # DISTINCT, bucketed and scalar aggregates
  # ---------------------------------------------------------------------------

  defp distinct_tests do
    quote location: :keep do
      describe "query_sql/3 — SELECT DISTINCT of a quoted table contract" do
        setup ctx do
          t = 1_700_000_000_000_000_000

          sa_write(ctx, [
            ~s(prices,symbol=AAPL price=150.0 #{t + 1_000_000_000}),
            ~s(prices,symbol=GOOG price=2800.0 #{t + 2_000_000_000}),
            ~s(prices,symbol=AAPL price=151.0 #{t + 3_000_000_000}),
            ~s(prices,symbol=MSFT price=300.0 #{t + 4_000_000_000}),
            ~s(prices,symbol=GOOG price=2810.0 #{t + 5_000_000_000})
          ])
        end

        test "unique values of a tag column", ctx do
          assert sa_rows(ctx, ~s(SELECT DISTINCT symbol FROM "prices" ORDER BY symbol)) === [
                   %{"symbol" => "AAPL"},
                   %{"symbol" => "GOOG"},
                   %{"symbol" => "MSFT"}
                 ]
        end

        test "unique values of a field column", ctx do
          assert sa_rows(ctx, ~s(SELECT DISTINCT price FROM "prices" ORDER BY price)) ===
                   Enum.map([150.0, 151.0, 300.0, 2800.0, 2810.0], &%{"price" => &1})
        end

        test "applies the WHERE filter", ctx do
          sql = ~s(SELECT DISTINCT symbol FROM "prices" WHERE price > 200 ORDER BY symbol)

          assert sa_rows(ctx, sql) === [%{"symbol" => "GOOG"}, %{"symbol" => "MSFT"}]
        end
      end
    end
  end

  defp bucket_tests do
    quote location: :keep do
      describe "query_sql/3 — bucketed and scalar aggregates contract" do
        setup ctx do
          # Six points at half-hour offsets from midnight: 0.5h, 1.5h, ... 5.5h.
          lines =
            for {i, host} <- [
                  {0, "web01"},
                  {1, "web01"},
                  {2, "web01"},
                  {3, "web02"},
                  {4, "web02"},
                  {5, "web02"}
                ] do
              ts = sa_midnight() + i * sa_hour() + div(sa_hour(), 2)
              ~s(cpu,host=#{host} usage=#{(i + 1) * 10}i,idle=#{100 - (i + 1) * 10}i #{ts})
            end

          sa_write(ctx, lines)
        end

        test "AVG over two-hour buckets", ctx do
          sql = """
          SELECT DATE_BIN(INTERVAL '2 hours', time) AS time, AVG(usage) AS avg_usage
          FROM "cpu"
          GROUP BY DATE_BIN(INTERVAL '2 hours', time)
          ORDER BY time ASC
          """

          assert sa_rows(ctx, sql) === [
                   %{"time" => ~U[2023-11-14 00:00:00.000000Z], "avg_usage" => 15.0},
                   %{"time" => ~U[2023-11-14 02:00:00.000000Z], "avg_usage" => 35.0},
                   %{"time" => ~U[2023-11-14 04:00:00.000000Z], "avg_usage" => 55.0}
                 ]
        end

        test "hour, minutes and seconds all name the same one-hour bucket", ctx do
          hour_us = div(sa_hour(), 1000)
          start_us = div(sa_midnight(), 1000)

          # One point half an hour into each hour: one point per bucket.
          expected =
            for hour <- 0..5 do
              %{
                "time" => DateTime.from_unix!(start_us + hour * hour_us, :microsecond),
                "cnt" => 1
              }
            end

          InfluxElixir.TestSupport.Check.each_case(
            ["1 hour", "60 minutes", "3600 seconds"],
            fn interval ->
              sql = """
              SELECT DATE_BIN(INTERVAL '#{interval}', time) AS time, COUNT(usage) AS cnt
              FROM "cpu"
              GROUP BY DATE_BIN(INTERVAL '#{interval}', time)
              ORDER BY time ASC
              """

              assert sa_rows(ctx, sql) === expected
            end
          )
        end

        test "ORDER BY the bucket DESC lists the newest first, and LIMIT keeps the newest", ctx do
          sql = """
          SELECT DATE_BIN(INTERVAL '2 hours', time) AS time, COUNT(usage) AS cnt
          FROM "cpu"
          GROUP BY DATE_BIN(INTERVAL '2 hours', time)
          ORDER BY time DESC
          LIMIT 2
          """

          assert sa_rows(ctx, sql) === [
                   %{"time" => ~U[2023-11-14 04:00:00.000000Z], "cnt" => 2},
                   %{"time" => ~U[2023-11-14 02:00:00.000000Z], "cnt" => 2}
                 ]
        end

        test "a scalar aggregate honours WHERE; over no rows COUNT is 0 and AVG is omitted",
             ctx do
          assert sa_rows(
                   ctx,
                   ~s|SELECT SUM(usage) AS total_usage, COUNT(usage) AS row_count | <>
                     ~s|FROM "cpu" WHERE host = 'web01'|
                 ) === [%{"total_usage" => 60, "row_count" => 3}]

          assert sa_rows(
                   ctx,
                   ~s|SELECT COUNT(usage) AS row_count FROM "cpu" WHERE host = 'none'|
                 ) === [%{"row_count" => 0}]

          sql = ~s|SELECT AVG(usage) AS avg_usage FROM "cpu" WHERE host = 'none'|

          assert sa_rows(ctx, sql) ===
                   [%{}]
        end

        test "buckets of a WHERE that keeps no point are no rows", ctx do
          sql = """
          SELECT DATE_BIN(INTERVAL '1 hour', time) AS time, AVG(usage) AS avg_usage
          FROM "cpu"
          WHERE usage > 9999
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          assert sa_rows(ctx, sql) === []
        end
      end
    end
  end

  defp omission_tests do
    quote location: :keep do
      describe "query_sql/3 — omitted nulls, integer arithmetic and now() contract" do
        test "SELECT * and a column list leave out a column that is null for the row", ctx do
          sa_write(ctx, [
            "m,provider=a,symbol=X value=1.0 1000000000",
            "m,provider=b,symbol=Y value=3.0 3000000000",
            "m,provider=b,symbol=Y other=4.0 4000000000"
          ])

          assert sa_rows(ctx, ~s|SELECT * FROM "m" WHERE provider = 'b' ORDER BY time|) === [
                   %{
                     "provider" => "b",
                     "symbol" => "Y",
                     "value" => 3.0,
                     "time" => ~U[1970-01-01 00:00:03.000000Z]
                   },
                   %{
                     "provider" => "b",
                     "symbol" => "Y",
                     "other" => 4.0,
                     "time" => ~U[1970-01-01 00:00:04.000000Z]
                   }
                 ]

          assert sa_rows(ctx, ~s|SELECT provider, other FROM "m" WHERE provider = 'a'|) ===
                   [%{"provider" => "a"}]
        end

        test "a selector over no rows leaves the column out", ctx do
          sa_write(ctx, ["m,symbol=X value=1.0 1000000000"])

          assert sa_rows(
                   ctx,
                   ~s|SELECT selector_last(value, time)['value'] AS v FROM "m" | <>
                     ~s|WHERE symbol = 'nope'|
                 ) === [%{}]
        end

        test "integer operands divide as integers", ctx do
          sa_write(ctx, ["ints n=3i 1000000000", "ints n=5i 2000000000"])

          assert sa_rows(
                   ctx,
                   ~s|SELECT SUM(n / 2) AS halves, SUM(n * n) AS squares, AVG(n) AS a FROM "ints"|
                 ) === [%{"halves" => 3, "squares" => 34, "a" => 4.0}]
        end

        test "now() arithmetic chains intervals and is case-insensitive", ctx do
          now_ns = System.os_time(:nanosecond)

          sa_write(ctx, [
            "q price=1.0 #{now_ns - 60_000_000_000}",
            "q price=2.0 #{now_ns - 600_000_000_000}",
            "q price=3.0 #{now_ns - 3_600_000_000_000}",
            "q price=4.0 #{now_ns - 7_200_000_000_000}"
          ])

          sql =
            ~s|SELECT price FROM "q" WHERE time >= now() - INTERVAL '1 hour' - INTERVAL '30 minutes' | <>
              ~s|AND time < NOW() + INTERVAL '1 day' ORDER BY price|

          assert sa_rows(ctx, sql) === [%{"price" => 1.0}, %{"price" => 2.0}, %{"price" => 3.0}]
        end
      end
    end
  end

  defp count_tests do
    quote location: :keep do
      describe "query_sql/3 — COUNT contract" do
        setup ctx do
          # Three rows on the first day and two on the second.
          day = 24 * sa_hour()

          sa_write(ctx, [
            ~s(traces,strategy_id=s1 prob=0.1 #{sa_midnight()}),
            ~s(traces,strategy_id=s1 prob=0.2 #{sa_midnight() + sa_hour()}),
            ~s(traces,strategy_id=s1 prob=0.3 #{sa_midnight() + 2 * sa_hour()}),
            ~s(traces,strategy_id=s1 prob=0.4 #{sa_midnight() + day}),
            ~s(traces,strategy_id=s1 prob=0.5 #{sa_midnight() + day + sa_hour()}),
            ~s(quotes,provider=a,symbol=X price=1.0,bid=1.0 #{sa_midnight()}),
            ~s(quotes,provider=a,symbol=X price=2.0 #{sa_midnight() + sa_hour()}),
            ~s(quotes,provider=b,symbol=Y price=3.0,bid=3.0 #{sa_midnight() + 2 * sa_hour()}),
            ~s(quotes,provider=c,symbol=Z price=4.0 #{sa_midnight() + 3 * sa_hour()})
          ])
        end

        test "COUNT(*) is the row count, per day bucket too", ctx do
          assert sa_rows(ctx, ~s|SELECT COUNT(*) AS n FROM "traces"|) === [%{"n" => 5}]

          sql = """
          SELECT DATE_BIN(INTERVAL '1 day', time) AS day, COUNT(*) AS n
          FROM "traces"
          GROUP BY DATE_BIN(INTERVAL '1 day', time)
          ORDER BY day ASC
          """

          assert sa_rows(ctx, sql) === [
                   %{"day" => ~U[2023-11-14 00:00:00.000000Z], "n" => 3},
                   %{"day" => ~U[2023-11-15 00:00:00.000000Z], "n" => 2}
                 ]
        end

        test "COUNT(*) counts a row that lacks the field COUNT(field) counts", ctx do
          sa_write(ctx, [
            ~s(traces,strategy_id=s1 other_field=1i #{sa_midnight() + 5 * sa_hour()})
          ])

          assert sa_rows(ctx, ~s|SELECT COUNT(*) AS n, COUNT(prob) AS p FROM "traces"|) ===
                   [%{"n" => 6, "p" => 5}]
        end

        test "COUNT(DISTINCT col) counts distinct non-null values", ctx do
          assert sa_rows(
                   ctx,
                   ~s|SELECT COUNT(DISTINCT provider) AS n, COUNT(DISTINCT bid) AS b FROM "quotes"|
                 ) === [%{"n" => 3, "b" => 2}]
        end

        test "COUNT(DISTINCT col) is 0 over no rows", ctx do
          assert sa_rows(
                   ctx,
                   ~s|SELECT COUNT(DISTINCT provider) AS n FROM "quotes" WHERE provider = 'zzz'|
                 ) === [%{"n" => 0}]
        end

        test "COUNT(DISTINCT col) counts per group", ctx do
          assert sa_rows(
                   ctx,
                   ~s|SELECT provider, COUNT(DISTINCT symbol) AS n FROM "quotes" | <>
                     ~s|GROUP BY provider ORDER BY provider|
                 ) === [
                   %{"provider" => "a", "n" => 1},
                   %{"provider" => "b", "n" => 1},
                   %{"provider" => "c", "n" => 1}
                 ]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Candles, ordered aggregates, median
  # ---------------------------------------------------------------------------

  defp candle_tests do
    quote location: :keep do
      describe "query_sql/3 — OHLCV candle contract" do
        setup ctx do
          # Two hours of trades, at the 10th, 30th and 50th minute of each. The
          # hour starts at 22:00 on 2023-11-14.
          start = sa_midnight() + 22 * sa_hour()
          minute = 60_000_000_000

          sa_write(ctx, [
            ~s(trades price=100.0,volume=10i #{start + 10 * minute}),
            ~s(trades price=105.0,volume=20i #{start + 30 * minute}),
            ~s(trades price=102.0,volume=15i #{start + 50 * minute}),
            ~s(trades price=110.0,volume=5i #{start + 70 * minute}),
            ~s(trades price=108.0,volume=25i #{start + 90 * minute}),
            ~s(trades price=112.0,volume=30i #{start + 110 * minute})
          ])
        end

        test "first_value, MAX, MIN, last_value and SUM per hour", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            first_value(price ORDER BY time) AS open,
            MAX(price) AS high,
            MIN(price) AS low,
            last_value(price ORDER BY time) AS close,
            SUM(volume) AS volume
          FROM "trades"
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          ORDER BY time ASC
          """

          assert sa_rows(ctx, sql) === [
                   %{
                     "time" => ~U[2023-11-14 22:00:00.000000Z],
                     "open" => 100.0,
                     "high" => 105.0,
                     "low" => 100.0,
                     "close" => 102.0,
                     "volume" => 45
                   },
                   %{
                     "time" => ~U[2023-11-14 23:00:00.000000Z],
                     "open" => 110.0,
                     "high" => 112.0,
                     "low" => 108.0,
                     "close" => 112.0,
                     "volume" => 60
                   }
                 ]
        end

        test "last_value(ORDER BY time DESC) is the value at the earliest time", ctx do
          sql = """
          SELECT DATE_BIN(INTERVAL '1 hour', time) AS time,
                 last_value(price ORDER BY time DESC) AS earliest
          FROM "trades"
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          ORDER BY time ASC
          """

          assert sa_rows(ctx, sql) === [
                   %{"time" => ~U[2023-11-14 22:00:00.000000Z], "earliest" => 100.0},
                   %{"time" => ~U[2023-11-14 23:00:00.000000Z], "earliest" => 110.0}
                 ]
        end

        test "first_value and last_value see only the rows WHERE keeps", ctx do
          sql = """
          SELECT DATE_BIN(INTERVAL '2 hours', time) AS time,
                 first_value(price ORDER BY time) AS open,
                 last_value(price ORDER BY time) AS close
          FROM "trades"
          WHERE price > 104
          GROUP BY DATE_BIN(INTERVAL '2 hours', time)
          ORDER BY time ASC
          """

          assert sa_rows(ctx, sql) === [
                   %{"time" => ~U[2023-11-14 22:00:00.000000Z], "open" => 105.0, "close" => 112.0}
                 ]
        end
      end
    end
  end

  defp ordered_tests do
    quote location: :keep do
      describe "query_sql/3 — first_value/last_value ordered by a field contract" do
        setup ctx do
          start = sa_midnight() + 22 * sa_hour()
          quarter = div(sa_hour(), 4)

          sa_write(ctx, [
            ~s(events,type=a value=100i,priority=3i #{start + quarter}),
            ~s(events,type=b value=200i,priority=1i #{start + 2 * quarter}),
            ~s(events,type=c value=300i,priority=2i #{start + 3 * quarter})
          ])
        end

        test "the value at the lowest and at the highest priority", ctx do
          sql = """
          SELECT DATE_BIN(INTERVAL '1 hour', time) AS time,
                 first_value(value ORDER BY priority) AS first_val,
                 last_value(value ORDER BY priority) AS last_val
          FROM events
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          assert sa_rows(ctx, sql) === [
                   %{
                     "time" => ~U[2023-11-14 22:00:00.000000Z],
                     "first_val" => 200,
                     "last_val" => 100
                   }
                 ]
        end
      end
    end
  end

  defp median_tests do
    quote location: :keep do
      describe "query_sql/3 — median per bucket contract" do
        setup ctx do
          sa_write(ctx, [
            "p,symbol=X,provider=a price=1.0,volume=10.0 1700000000000000000",
            "p,symbol=X,provider=a price=2.5,volume=20.0 1700000010000000000",
            "p,symbol=X,provider=a price=3.0,volume=30.0 1700000070000000000",
            "p,symbol=X,provider=a price=4.0,volume=40.0 1700000080000000000",
            "p,symbol=X,provider=a price=100.0,volume=1.0 1700000090000000000",
            "q n=1i 1700000000000000000",
            "q n=2i 1700000001000000000",
            "q n=3i 1700000002000000000",
            "q n=4i 1700000003000000000"
          ])
        end

        test "median over a float field and over an expression", ctx do
          assert sa_rows(
                   ctx,
                   ~s|SELECT median(price) AS med, median(volume) AS mv, | <>
                     ~s|median(price * 2) AS twice FROM "p"|
                 ) === [%{"med" => 3.0, "mv" => 20.0, "twice" => 6.0}]
        end

        test "median of integers is an integer", ctx do
          assert sa_rows(ctx, ~s|SELECT median(n) AS med FROM "q"|) === [%{"med" => 2}]
        end

        test "median over no rows leaves the column out", ctx do
          assert sa_rows(ctx, ~s|SELECT median(price) AS med FROM "p" WHERE price > 1000|) ===
                   [%{}]
        end

        test "a median screens the outlier out of a candle", ctx do
          sql = """
          WITH w AS (SELECT price, volume, time FROM p WHERE symbol = 'X'),
          ref AS (SELECT median(price) AS med FROM w)
          SELECT
            DATE_BIN(INTERVAL '1 minute', w.time) AS time,
            selector_first(w.price, w.time)['value'] AS open,
            max(w.price) AS high,
            min(w.price) AS low,
            selector_last(w.price, w.time)['value'] AS close,
            sum(w.volume) AS volume
          FROM w CROSS JOIN ref
          WHERE ref.med <= 0 OR (w.price <= ref.med * 3 AND w.price >= ref.med / 3)
          GROUP BY DATE_BIN(INTERVAL '1 minute', w.time)
          ORDER BY time ASC
          """

          # The 100.0 outlier (median 3.0, bound 9.0) is screened out of the second
          # candle; the bins are the minutes the points fall in.
          assert sa_rows(ctx, sql) === [
                   %{
                     "time" => ~U[2023-11-14 22:13:00.000000Z],
                     "open" => 1.0,
                     "high" => 2.5,
                     "low" => 1.0,
                     "close" => 2.5,
                     "volume" => 30.0
                   },
                   %{
                     "time" => ~U[2023-11-14 22:14:00.000000Z],
                     "open" => 3.0,
                     "high" => 4.0,
                     "low" => 3.0,
                     "close" => 4.0,
                     "volume" => 70.0
                   }
                 ]
        end

        test "the mean of the two middles, over a filter and per minute", ctx do
          assert sa_rows(ctx, ~s|SELECT median(price) AS med FROM "p" WHERE price < 4|) ===
                   [%{"med" => 2.5}]

          sql = """
          SELECT DATE_BIN(INTERVAL '1 minute', time) AS t, median(price) AS med
          FROM "p"
          GROUP BY DATE_BIN(INTERVAL '1 minute', time)
          ORDER BY t
          """

          assert sa_rows(ctx, sql) === [
                   %{"t" => ~U[2023-11-14 22:13:00.000000Z], "med" => 1.75},
                   %{"t" => ~U[2023-11-14 22:14:00.000000Z], "med" => 4.0}
                 ]
        end

        test "median of time is the engine's planning error", ctx do
          assert sa_query(ctx, ~s|SELECT median(time) AS med FROM "q"|) ===
                   {:error,
                    %{
                      status: 400,
                      body:
                        "Error during planning: Function 'median' expects NativeType::Numeric " <>
                          "but received NativeType::Timestamp(Nanosecond, None) No function " <>
                          "matches the given name and argument types " <>
                          "'median(Timestamp(ns))'. You might need to add explicit type " <>
                          "casts.\n\tCandidate functions:\n\tmedian(Numeric(1))"
                    }}
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Joins, streams, columns, statements
  # ---------------------------------------------------------------------------

  defp join_tests do
    quote location: :keep do
      describe "query_sql/3 — CROSS JOIN contract" do
        setup ctx do
          sa_write(ctx, [
            "p price=1.0 1700000000000000000",
            "p price=2.5 1700000010000000000",
            "p price=3.0 1700000070000000000",
            "q n=1i 1700000000000000000",
            "q n=2i 1700000001000000000"
          ])
        end

        test "a column only one side has resolves, and the product has every pair", ctx do
          rows = sa_rows(ctx, ~s|SELECT price FROM "p" CROSS JOIN "q"|)

          assert rows |> Enum.map(& &1["price"]) |> Enum.frequencies() ===
                   %{1.0 => 2, 2.5 => 2, 3.0 => 2}
        end
      end
    end
  end

  defp stream_tests(client) do
    quote location: :keep do
      describe "query_sql_stream/3 — a failed query contract" do
        test "raises StreamError on enumeration, with the engine's status and body", ctx do
          sa_write(ctx, ["cpu v=1i 1700000000000000000"])

          # Building the stream does not run the query.
          stream =
            unquote(client).query_sql_stream(ctx.conn, "SELECT * FROM cpu WHERE nosuch = 1",
              database: ctx.database
            )

          body = InfluxElixir.ClientContract.no_field("nosuch", "cpu", ["time", "v"])

          error = assert_raise InfluxElixir.StreamError, fn -> Enum.to_list(stream) end

          assert {error.kind, error.status, error.body, error.message} ===
                   {:http_status, 500, body,
                    "streaming query failed with HTTP status 500: " <> body}
        end
      end
    end
  end

  defp column_tests do
    quote location: :keep do
      describe "query_sql/3 — a double-quoted operand contract" do
        test "is a column, not a string; a single-quoted one is the string", ctx do
          sa_write(ctx, ["m,tag=hello val=1i 1700000000000000000"])

          assert sa_query(ctx, ~s(SELECT * FROM m WHERE tag = "hello")) ===
                   {:error,
                    %{
                      status: 500,
                      body:
                        InfluxElixir.ClientContract.no_field("hello", "m", ["tag", "time", "val"])
                    }}

          assert sa_rows(ctx, ~s(SELECT * FROM m WHERE tag = 'hello')) ===
                   [%{"tag" => "hello", "time" => ~U[2023-11-14 22:13:20.000000Z], "val" => 1}]
        end
      end
    end
  end

  # Statements the engine reads and does not run. InfluxDB 3 Core refuses DML
  # (Enterprise runs DELETE), so the refusals are Core's.
  defp statement_tests(profile) do
    refusals =
      if profile == :v3_core do
        quote location: :keep do
          test "DML is the engine's planning error, whatever the kind", ctx do
            sa_write(ctx, ["cpu v=1i 1700000000000000000"])

            InfluxElixir.TestSupport.Check.each_case(
              [
                {"DELETE FROM cpu", "Delete"},
                {"delete from cpu where v = 1", "Delete"},
                {"INSERT INTO cpu (time, v) VALUES ('2023-11-14T22:13:20Z', 5)", "Insert Into"},
                {"UPDATE cpu SET v = 2", "Update"}
              ],
              fn {sql, kind} ->
                assert sa_execute(ctx, sql) ===
                         {:error,
                          %{
                            status: 400,
                            body: "Error during planning: DML not supported: " <> kind
                          }},
                       sql
              end
            )
          end

          test "DDL is the engine's planning error; anything else is its 405", ctx do
            sa_write(ctx, ["cpu v=1i 1700000000000000000"])

            InfluxElixir.TestSupport.Check.each_case(
              [
                {"CREATE TABLE foo (id INT)", "CreateMemoryTable"},
                {"CREATE VIEW vv AS SELECT * FROM cpu", "CreateView"},
                {"CREATE DATABASE x", "CreateCatalog"},
                {"DROP TABLE cpu", "DropTable"},
                {"DROP VIEW vv", "DropView"}
              ],
              fn {sql, kind} ->
                assert sa_execute(ctx, sql) ===
                         {:error,
                          %{
                            status: 400,
                            body: "Error during planning: DDL not supported: " <> kind
                          }},
                       sql
              end
            )

            InfluxElixir.TestSupport.Check.each_case(
              ["ALTER TABLE cpu ADD COLUMN y INT", "TRUNCATE cpu"],
              fn sql ->
                assert sa_execute(ctx, sql) ===
                         {:error,
                          %{
                            status: 405,
                            body:
                              "This feature is not implemented: Unsupported SQL statement: " <>
                                sql
                          }},
                       sql
              end
            )
          end
        end
      end

    quote location: :keep do
      describe "execute_sql/3 — statements contract" do
        unquote(refusals)

        test "a SELECT or a WITH runs as a query", ctx do
          sa_write(ctx, ["sel v=1i 1700000000000000000"])

          assert sa_execute(ctx, "SELECT v FROM sel") === {:ok, [%{"v" => 1}]}

          assert sa_execute(ctx, "WITH w AS (SELECT v FROM sel) SELECT v FROM w") ===
                   {:ok, [%{"v" => 1}]}
        end
      end
    end
  end
end
