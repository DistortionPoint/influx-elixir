defmodule InfluxElixir.ClientContract.InfluxqlScalar do
  @moduledoc """
  The `:influxql_scalar` part of `InfluxElixir.ClientContract`:
  InfluxQL, scalar functions and query formats (the InfluxDB 3 profiles).
  """

  @doc false
  @spec blocks(Macro.t(), atom()) :: [Macro.t()]
  def blocks(client, profile) when profile in [:v3_core, :v3_enterprise] do
    [
      scalar_function_tests(client),
      scalar_function_error_tests(client),
      influxql_tests(client),
      influxql_select_tests(client),
      format_tests(client),
      influxql_where_tests(client)
    ]
  end

  def blocks(_client, _profile), do: []

  defp influxql_tests(client) do
    quote location: :keep do
      describe "query_influxql/3 — contract" do
        test "SHOW DATABASES lists the test database once", ctx do
          {:ok, dbs} =
            unquote(client).query_influxql(ctx.conn, "SHOW DATABASES")

          names = Enum.map(dbs, & &1["iox::database"])
          assert Enum.filter(names, &(&1 === ctx.database)) === [ctx.database]
        end

        test "SHOW MEASUREMENTS lists the database's measurements and nothing else", ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_iql_m value=1i 1000000000",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, measurements} =
                   unquote(client).query_influxql(
                     ctx.conn,
                     "SHOW MEASUREMENTS",
                     database: ctx.database
                   )

          assert measurements === [
                   %{"iox::measurement" => "measurements", "name" => "contract_iql_m"}
                 ]
        end

        test "SHOW TAG KEYS FROM lists the measurement's tag keys in order", ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_iql_tags,host=web01,region=us value=1i 1000000000",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, tag_keys} =
                   unquote(client).query_influxql(
                     ctx.conn,
                     "SHOW TAG KEYS FROM contract_iql_tags",
                     database: ctx.database
                   )

          assert tag_keys === [
                   %{"iox::measurement" => "contract_iql_tags", "tagKey" => "host"},
                   %{"iox::measurement" => "contract_iql_tags", "tagKey" => "region"}
                 ]
        end
      end
    end
  end

  # InfluxQL's WHERE and SHOW TAG VALUES, verified against InfluxDB 3: a
  # missing tag is the empty string, regexes match tags only, ordering a
  # tag is false, durations work with now(), NOT does not exist.
  defp influxql_where_tests(client) do
    quote location: :keep do
      describe "query_influxql/3 — WHERE and SHOW TAG VALUES contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_iqw")
          now = System.os_time(:second)

          lp =
            Enum.join(
              [
                "#{m},host=h1 v=1i #{now - 7200}",
                "#{m},host=h2 v=2i #{now - 1800}",
                "#{m},host=h12 v=3i #{now - 600}",
                "#{m} v=4i #{now - 330}",
                "#{m},host=H1 v=5i #{now - 60}",
                "#{m},host=old v=6i #{now - 90_000}"
              ],
              "\n"
            )

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database, precision: :second)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, m: m}
        end

        test "a missing tag is the empty string; regexes are unanchored", ctx do
          assert InfluxElixir.ClientContract.where_values(unquote(client), ctx, "host =~ /h1/") ==
                   [1, 3]

          assert InfluxElixir.ClientContract.where_values(unquote(client), ctx, "host =~ /^h1$/") ==
                   [1]

          assert InfluxElixir.ClientContract.where_values(
                   unquote(client),
                   ctx,
                   "host =~ /(?i)h1/"
                 ) === [1, 3, 5]

          assert InfluxElixir.ClientContract.where_values(unquote(client), ctx, "host !~ /h1/") ==
                   [6, 2, 4, 5]

          assert InfluxElixir.ClientContract.where_values(unquote(client), ctx, "host != 'h1'") ==
                   [6, 2, 3, 4, 5]

          assert InfluxElixir.ClientContract.where_values(unquote(client), ctx, "host = ''") === [
                   4
                 ]
        end

        test "ordering a tag, or a regex on a field, is false", ctx do
          assert InfluxElixir.ClientContract.where_values(unquote(client), ctx, "host > 'h0'") ==
                   []

          assert InfluxElixir.ClientContract.where_values(
                   unquote(client),
                   ctx,
                   "host >= 'h1' OR v = 4"
                 ) === [4]

          assert InfluxElixir.ClientContract.where_values(unquote(client), ctx, "v =~ /1/") === []
        end

        test "durations with now(), and quoted identifiers", ctx do
          assert InfluxElixir.ClientContract.where_values(
                   unquote(client),
                   ctx,
                   "time > now() - 40m"
                 ) === [2, 3, 4, 5]

          assert InfluxElixir.ClientContract.where_values(
                   unquote(client),
                   ctx,
                   "time > now() - 1h AND time < now() - 5m"
                 ) === [2, 3, 4]

          assert InfluxElixir.ClientContract.where_values(unquote(client), ctx, "\"host\" = 'h2'") ==
                   [2]
        end

        test "NOT is the engine's parse error", ctx do
          # The position is where the operand after NOT starts.
          prefix = "SELECT v FROM #{ctx.m} WHERE NOT "
          pos = String.length(prefix)

          expected =
            "error in InfluxQL statement: parsing error: invalid InfluxQL statement at " <>
              "pos #{pos}. Parsing Error: Nom(\"host = 'h1'\", Tag)"

          assert {:error, %{status: 400, body: ^expected}} =
                   unquote(client).query_influxql(
                     ctx.conn,
                     prefix <> "host = 'h1'",
                     database: ctx.database
                   )
        end

        unquote(influxql_number_tests(client))

        test "SHOW TAG VALUES: sorted values, a row for the missing key, the last 24 hours",
             ctx do
          assert {:ok, rows} =
                   unquote(client).query_influxql(
                     ctx.conn,
                     "SHOW TAG VALUES FROM #{ctx.m} WITH KEY = host",
                     database: ctx.database
                   )

          base = %{"iox::measurement" => ctx.m, "key" => "host"}
          values = for v <- ["H1", "h1", "h12", "h2"], do: Map.put(base, "value", v)
          assert rows === values ++ [base]
        end
      end
    end
  end

  defp influxql_number_tests(client) do
    quote location: :keep do
      test "a number is digits with an optional fraction, signed or led by a dot", ctx do
        assert InfluxElixir.ClientContract.where_values(
                 unquote(client),
                 ctx,
                 "v > .5 AND v < 2"
               ) === [1]

        assert InfluxElixir.ClientContract.where_values(
                 unquote(client),
                 ctx,
                 "v > -.5 AND v < +2.0"
               ) === [1]

        assert InfluxElixir.ClientContract.where_values(unquote(client), ctx, "v >= 004") ==
                 [6, 4, 5]
      end

      test "an exponent, a trailing dot, a hex or an underscore is the engine's parse error",
           ctx do
        prefix = "SELECT v FROM #{ctx.m} WHERE v > "

        for {literal, number, left} <- [
              {"5e20", "5", "e20"},
              {"1.5e3", "1.5", "e3"},
              {"5.", "5", "."},
              {"0x10", "0", "x10"},
              {"1_000", "1", "_000"}
            ],
            tail <- ["", " GROUP BY host LIMIT 1", ";"] do
          pos = String.length(prefix) + String.length(number)

          assert {:error,
                  %{
                    status: 400,
                    body:
                      "error in InfluxQL statement: parsing error: invalid InfluxQL " <>
                        "statement at pos " <> rest
                  }} =
                   unquote(client).query_influxql(ctx.conn, prefix <> literal <> tail,
                     database: ctx.database
                   )

          assert rest === "#{pos}. Parsing Error: Nom(#{inspect(left <> tail)}, Tag)",
                 literal <> tail
        end
      end
    end
  end

  defp influxql_select_tests(client) do
    quote location: :keep do
      describe "query_influxql/3 — SELECT shape contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_iqs")

          lp = """
          #{m},h=x v=3i 1700000000000003000
          #{m},h=y v=1i 1700000000000001000
          #{m},h=x v=2i 1700000000000002000
          #{m},h=y w=9i,s="x" 1700000000000004000
          """

          {:ok, :written} =
            unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "rows carry iox::measurement and time, in time order", ctx do
          {:ok, rows} =
            unquote(client).query_influxql(ctx.conn, "SELECT v FROM #{ctx.m}",
              database: ctx.database
            )

          assert Enum.map(rows, &{&1["iox::measurement"], &1["v"], &1["time"]}) === [
                   {ctx.m, 1, ~U[2023-11-14 22:13:20.000001Z]},
                   {ctx.m, 2, ~U[2023-11-14 22:13:20.000002Z]},
                   {ctx.m, 3, ~U[2023-11-14 22:13:20.000003Z]}
                 ]
        end

        test "aggregates are named after the function, a lone selector keeps its point", ctx do
          epoch = DateTime.from_unix!(0, :microsecond)

          {:ok, [row]} =
            unquote(client).query_influxql(
              ctx.conn,
              "SELECT SUM(v), MEAN(v), COUNT(*) FROM #{ctx.m}",
              database: ctx.database
            )

          assert %{"time" => ^epoch, "sum" => 6, "mean" => 2.0, "count_v" => 3, "count_w" => 1} =
                   row

          {:ok, [max]} =
            unquote(client).query_influxql(ctx.conn, "SELECT MAX(v), h FROM #{ctx.m}",
              database: ctx.database
            )

          assert %{"max" => 3, "h" => "x"} = max
          assert max["time"] === DateTime.from_unix!(1_700_000_000_000_003, :microsecond)
        end

        test "GROUP BY lists the series without the tag after the series that have it", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_iqo")

          lp =
            Enum.join(
              [
                "#{m},g=b x=2i 1700000000000000000",
                "#{m} x=9i 1700000010000000000",
                "#{m},g=a x=1i 1700000020000000000",
                "#{m},g=a x=3i 1700000030000000000"
              ],
              "\n"
            )

          assert {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, means} =
                   unquote(client).query_influxql(ctx.conn, "SELECT MEAN(x) FROM #{m} GROUP BY g",
                     database: ctx.database
                   )

          assert Enum.map(means, &{&1["g"], &1["mean"]}) === [{"a", 2.0}, {"b", 2.0}, {nil, 9.0}]

          assert {:ok, rows} =
                   unquote(client).query_influxql(ctx.conn, "SELECT x FROM #{m} GROUP BY g",
                     database: ctx.database
                   )

          assert Enum.map(rows, &{&1["g"], &1["x"]}) === [{"a", 1}, {"a", 3}, {"b", 2}, {nil, 9}]
        end

        test "GROUP BY with a per-series LIMIT; unknown names are empty; field keys", ctx do
          {:ok, rows} =
            unquote(client).query_influxql(ctx.conn, "SELECT v FROM #{ctx.m} GROUP BY h LIMIT 1",
              database: ctx.database
            )

          assert Enum.map(rows, &{&1["h"], &1["v"]}) === [{"x", 2}, {"y", 1}]

          InfluxElixir.TestSupport.Check.each_case(
            ["SELECT nothere FROM #{ctx.m}", "SELECT v FROM #{ctx.m}_missing"],
            fn statement ->
              assert {:ok, []} =
                       unquote(client).query_influxql(ctx.conn, statement, database: ctx.database)
            end
          )

          {:ok, keys} =
            unquote(client).query_influxql(ctx.conn, "SHOW FIELD KEYS FROM #{ctx.m}",
              database: ctx.database
            )

          assert Enum.map(keys, &{&1["fieldKey"], &1["fieldType"]}) ==
                   [{"s", "string"}, {"v", "integer"}, {"w", "integer"}]
        end
      end

      describe "query_sql/3 — sub-microsecond time contract" do
        test "ORDER BY time and a time literal use the nanoseconds", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_ns")

          lp =
            "#{m} v=3i 1700000000000000300\n#{m} v=1i 1700000000000000100\n#{m} v=2i 1700000000000000200"

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)

          {:ok, ordered} =
            unquote(client).query_sql(ctx.conn, "SELECT * FROM #{m} ORDER BY time",
              database: ctx.database
            )

          assert Enum.map(ordered, & &1["v"]) === [1, 2, 3]

          {:ok, later} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT v FROM #{m} WHERE time >= '2023-11-14T22:13:20.0000002Z' ORDER BY v",
              database: ctx.database
            )

          assert Enum.map(later, & &1["v"]) === [2, 3]
        end
      end
    end
  end

  defp format_tests(client) do
    quote location: :keep do
      describe "query formats contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fmt")

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "#{m},host=b v=1e15 2\n" <>
                "#{m},host=a v=1.5,big=9007199254740993i,tiny=1.5e-7,huge=1e16,b=true,s=\"\" 1",
              database: ctx.database,
              precision: :second
            )

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "format: :csv answers every value as the engine's CSV string", ctx do
          assert {:ok, [first, second]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM #{ctx.m} ORDER BY time",
                     database: ctx.database,
                     format: :csv
                   )

          assert first === %{
                   "time" => ~U[1970-01-01 00:00:01.000000Z],
                   "host" => "a",
                   "v" => "1.5",
                   "big" => "9007199254740993",
                   "tiny" => "1.5e-7",
                   "huge" => "1e16",
                   "b" => "true"
                 }

          assert second === %{
                   "time" => ~U[1970-01-01 00:00:02.000000Z],
                   "host" => "b",
                   "v" => "1000000000000000.0"
                 }
        end

        test "format: :csv writes each float as the engine's CSV does", ctx do
          # Every pair was read back from InfluxDB 3 Core's `format: "csv"`.
          pairs = [
            {0.5, "0.5"},
            {2.0, "2.0"},
            {100.0, "100.0"},
            {12_345_678.9, "12345678.9"},
            {0.001, "0.001"},
            {0.0001, "0.0001"},
            {0.00001, "0.00001"},
            {1.5e-5, "0.000015"},
            {9.5e-6, "9.5e-6"},
            {1.0e-6, "1e-6"},
            {1.5e-7, "1.5e-7"},
            {5.0e-324, "5e-324"},
            {1.0e15, "1000000000000000.0"},
            {9.999e15, "9999000000000000.0"},
            {1.0e16, "1e16"},
            {1.0e20, "1e20"},
            {123_456_789_012_345_678.0, "1.2345678901234568e17"},
            {1.797_693_134_862_315_7e308, "1.7976931348623157e308"},
            {-12.25, "-12.25"},
            {-2.5e-6, "-2.5e-6"},
            {-1.0e16, "-1e16"},
            {0.0, "0.0"}
          ]

          lines =
            pairs
            |> Enum.with_index(1)
            |> Enum.map_join("\n", fn {{value, _csv}, second} ->
              "#{ctx.m}_csv_float f=#{Float.to_string(value)} #{second}"
            end)

          assert {:ok, :written} ===
                   unquote(client).write(ctx.conn, lines,
                     database: ctx.database,
                     precision: :second
                   )

          assert {:ok, rows} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT f FROM #{ctx.m}_csv_float ORDER BY time",
                     database: ctx.database,
                     format: :csv
                   )

          assert Enum.map(rows, & &1["f"]) === Enum.map(pairs, &elem(&1, 1))
        end

        test "format: :csv keeps a one-column row whose value is null or empty", ctx do
          # The engine writes such a row as `""`; the parser took it for a
          # table separator, dropped it and read the next row as a header.
          # `b` is null on the second row; `s` is "" on the first, null on the second.
          InfluxElixir.TestSupport.Check.each_case(
            [{"b", [%{"b" => "true"}, %{}]}, {"s", [%{}, %{}]}],
            fn {column, expected} ->
              assert {:ok, ^expected} =
                       unquote(client).query_sql(
                         ctx.conn,
                         "SELECT #{column} FROM #{ctx.m} ORDER BY time",
                         database: ctx.database,
                         format: :csv
                       )
            end
          )
        end

        test "query_influxql format: :csv answers strings too", ctx do
          assert {:ok, [%{"iox::measurement" => m, "v" => "1.5", "b" => "true"}, second]} =
                   unquote(client).query_influxql(ctx.conn, "SELECT v, b FROM #{ctx.m}",
                     database: ctx.database,
                     format: :csv
                   )

          assert m === ctx.m
          refute Map.has_key?(second, "b")
        end

        test "a nested value cannot be written as CSV: the connection closes", ctx do
          assert {:error, {:connection_error, %Mint.TransportError{reason: :closed}}} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT selector_last(v, time) AS s FROM #{ctx.m}",
                     database: ctx.database,
                     format: :csv
                   )
        end

        test "query_sql_stream answers typed rows whatever format: says", ctx do
          rows =
            ctx.conn
            |> unquote(client).query_sql_stream("SELECT v FROM #{ctx.m} ORDER BY time",
              database: ctx.database,
              format: :csv
            )
            |> Enum.to_list()

          assert rows === [%{"v" => 1.5}, %{"v" => 1.0e15}]
        end
      end
    end
  end

  defp scalar_function_tests(client) do
    quote location: :keep do
      describe "scalar functions — contract" do
        unquote(scalar_function_setup(client))

        # Issue #25: a transaction's magnitude against a threshold. The
        # double refused the clause by name (and before that read it as a
        # column named `abs(amount)`, returning no rows).
        test "abs() in WHERE compares a magnitude against a parameter", ctx do
          assert {:ok,
                  [%{"amount" => -80_000_000_000, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT amount, time FROM #{ctx.m} WHERE firm = $firm " <>
                       "AND time >= $start AND time <= $end AND abs(amount) >= $threshold",
                     database: ctx.database,
                     params: %{
                       firm: "f1",
                       start: "1970-01-01T00:00:00Z",
                       end: "1970-01-01T00:00:05Z",
                       threshold: 5_000_000_000
                     }
                   )
        end

        test "abs, round, floor and ceil answer as the engine does, null in, null out", ctx do
          assert {:ok, rows} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT abs(amount) AS a, abs(f) AS af, round(f) AS r, round(f, 1) AS r1, " <>
                       "round(1234.5678, -2) AS rn, floor(f) AS fl, ceil(f) AS c, " <>
                       "ROUND(amount) AS ra FROM #{ctx.m} ORDER BY time"
                   )

          assert rows === [
                   %{
                     "a" => 80_000_000_000,
                     "af" => 2.5,
                     "r" => -3.0,
                     "r1" => -2.5,
                     "rn" => 1200.0,
                     "fl" => -3.0,
                     "c" => -2.0,
                     "ra" => -80_000_000_000.0
                   },
                   %{
                     "a" => 100_000_000,
                     "af" => 2.5,
                     "r" => 3.0,
                     "r1" => 2.5,
                     "rn" => 1200.0,
                     "fl" => 2.0,
                     "c" => 3.0,
                     "ra" => 100_000_000.0
                   },
                   %{
                     "af" => 0.4,
                     "r" => 0.0,
                     "r1" => 0.4,
                     "rn" => 1200.0,
                     "fl" => 0.0,
                     "c" => 1.0
                   },
                   %{"a" => 90_000_000_000, "rn" => 1200.0, "ra" => -90_000_000_000.0}
                 ]
        end

        test "a call stands wherever an expression does", ctx do
          assert InfluxElixir.ClientContract.unix_times(unquote(client), ctx, "abs(f) > 1") === [
                   1,
                   2
                 ]

          assert InfluxElixir.ClientContract.unix_times(unquote(client), ctx, "1 < abs(f)") === [
                   1,
                   2
                 ]

          assert InfluxElixir.ClientContract.unix_times(
                   unquote(client),
                   ctx,
                   "abs(f) BETWEEN 1 AND 3"
                 ) === [1, 2]

          assert InfluxElixir.ClientContract.unix_times(unquote(client), ctx, "abs(f) IN (2.5)") ==
                   [1, 2]

          assert InfluxElixir.ClientContract.unix_times(
                   unquote(client),
                   ctx,
                   "abs(f) NOT IN (2.5)"
                 ) === [3]

          assert InfluxElixir.ClientContract.unix_times(unquote(client), ctx, "abs(f) IS NULL") ==
                   [4]

          assert InfluxElixir.ClientContract.unix_times(unquote(client), ctx, "abs(f * 2) = 5") ==
                   [1, 2]

          assert InfluxElixir.ClientContract.unix_times(
                   unquote(client),
                   ctx,
                   "round(f) = 0 OR ceil(f) = 3"
                 ) === [2, 3]

          assert InfluxElixir.ClientContract.unix_times(
                   unquote(client),
                   ctx,
                   "'1970-01-01T00:00:02Z' < time"
                 ) === [3, 4]

          assert {:ok, [%{"a" => 2.5}, %{"a" => 2.5}, %{"a" => 0.4}]} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT abs(f) AS a FROM #{ctx.m} WHERE f IS NOT NULL " <>
                       "ORDER BY abs(f) DESC, time"
                   )

          assert {:ok, [%{"s" => 170_100_000_000}]} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT sum(abs(amount)) AS s FROM #{ctx.m}"
                   )
        end
      end
    end
  end

  defp scalar_function_error_tests(client) do
    quote location: :keep do
      describe "scalar function errors — contract" do
        unquote(scalar_function_setup(client))

        # The engine types a call's arguments when it plans the query: a
        # wrong one fails it though no row reaches the call (`f = 99`), with
        # the message shaped by where the call stands.
        test "a wrong argument is the engine's planning error, worded per clause", ctx do
          suggestion =
            " No function matches the given name and argument types 'abs(Utf8)'. You might " <>
              "need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"

          head =
            "Error during planning: Function 'abs' expects NativeType::Numeric but received " <>
              "NativeType::String"

          assert {:error, %{status: 400, body: body}} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT f FROM #{ctx.m} WHERE abs(s) > 1 AND f = 99"
                   )

          assert body === "type_coercion\ncaused by\n" <> head <> suggestion

          assert {:error, %{status: 400, body: body}} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT abs(s) AS a FROM #{ctx.m} WHERE f = 99"
                   )

          assert body === head <> suggestion

          assert {:error, %{status: 400, body: body}} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT f FROM #{ctx.m} ORDER BY abs(s)"
                   )

          assert body === "type_coercion\ncaused by\n" <> head

          assert {:error, %{status: 400, body: body}} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT f FROM #{ctx.m} WHERE abs(firm) > 1"
                   )

          assert body ==
                   "type_coercion\ncaused by\n" <>
                     head <>
                     " No function matches the given name and argument types " <>
                     "'abs(Dictionary(Int32, Utf8))'. You might need to add explicit type " <>
                     "casts.\n\tCandidate functions:\n\tabs(Numeric(1))"

          assert {:error, %{status: 400, body: body}} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT f FROM #{ctx.m} WHERE floor(b) > 1"
                   )

          assert body ==
                   "type_coercion\ncaused by\nError during planning: Failed to coerce arguments " <>
                     "to satisfy a call to 'floor' function: coercion from Boolean to the " <>
                     "signature Uniform(1, [Float64, Float32]) failed No function matches the " <>
                     "given name and argument types 'floor(Boolean)'. You might need to add " <>
                     "explicit type casts.\n\tCandidate functions:\n\tfloor(Float64/Float32)"

          assert {:error, %{status: 400, body: body}} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT f FROM #{ctx.m} ORDER BY abs(time)"
                   )

          assert body ==
                   "type_coercion\ncaused by\nError during planning: Function 'abs' expects " <>
                     "NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None)"
        end

        test "a wrong argument count is the engine's error", ctx do
          assert {:error, %{status: 400, body: body}} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT f FROM #{ctx.m} WHERE abs(f, 1) > 1"
                   )

          assert body ==
                   "type_coercion\ncaused by\nError during planning: Function 'abs' expects 1 " <>
                     "arguments but received 2 No function matches the given name and " <>
                     "argument types 'abs(Float64, Int64)'. You might need to add explicit " <>
                     "type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"

          round_candidates =
            "\n\tCandidate functions:\n\tround(Float64, Int64)\n\tround(Float32, Int64)\n" <>
              "\tround(Float64)\n\tround(Float32)"

          assert {:error, %{status: 400, body: body}} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT round() AS r FROM #{ctx.m}"
                   )

          assert body ==
                   "Error during planning: 'round' does not support zero arguments No " <>
                     "function matches the given name and argument types 'round()'. You " <>
                     "might need to add explicit type casts." <> round_candidates

          assert {:error, %{status: 400, body: body}} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT round(f, 1.5) AS r FROM #{ctx.m}"
                   )

          assert body ==
                   "Error during planning: Failed to coerce arguments to satisfy a call to " <>
                     "'round' function: coercion from Float64, Float64 to the signature " <>
                     "OneOf([Exact([Float64, Int64]), Exact([Float32, Int64]), " <>
                     "Exact([Float64]), Exact([Float32])]) failed No function matches the " <>
                     "given name and argument types 'round(Float64, Float64)'. You might " <>
                     "need to add explicit type casts." <> round_candidates

          assert {:error,
                  %{
                    status: 405,
                    body: "This feature is not implemented: CEIL with scale is not supported"
                  }} =
                   InfluxElixir.ClientContract.run(
                     unquote(client),
                     ctx,
                     "SELECT f FROM #{ctx.m} WHERE ceil(f, 1) > 1"
                   )
        end
      end
    end
  end

  defp scalar_function_setup(client) do
    quote location: :keep do
      setup ctx do
        m = InfluxElixir.IntegrationHelper.unique_name("contract_fn")

        {:ok, :written} =
          unquote(client).write(
            ctx.conn,
            "#{m},firm=f1 amount=-80000000000i,f=-2.5,s=\"x\" 1000000000\n" <>
              "#{m},firm=f1 amount=100000000i,f=2.5 2000000000\n" <>
              "#{m},firm=f1 f=0.4 3000000000\n" <>
              "#{m},firm=f2 amount=-90000000000i,b=true 4000000000",
            database: ctx.database
          )

        InfluxElixir.ClientContract.settle(ctx)
        {:ok, m: m}
      end
    end
  end
end
