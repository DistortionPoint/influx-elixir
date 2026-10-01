defmodule InfluxElixir.Contract.SQLExecutor do
  @moduledoc """
  SQL executor contract tests, run against `InfluxElixir.Client.Local` and
  against a real InfluxDB 3 Core: the answers the double must give exactly
  as the engine does (rows, error status and body). Every expectation here
  was read from a Core.

      use InfluxElixir.Contract.SQLExecutor, client: InfluxElixir.Client.Local, profile: :v3_core

  The `setup` callback must return `conn`, `database` and `query_delay`, as
  for the shared contract. A real server is shared between runs, so every
  measurement name is unique.
  """

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)

    quote do
      unquote(helpers(client))
      unquote(planning_tests())
      unquote(null_between_tests())
      unquote(plan_order_tests())
      unquote(boolean_tests(client))
      unquote(result_tests())
      unquote(division_tests(client))
      unquote(wording_tests())
      unquote(join_tests(profile))
    end
  end

  defp helpers(client) do
    quote do
      @sxc_closed {:error, {:connection_error, %Mint.TransportError{reason: :closed}}}

      defp sxc_name(prefix), do: "#{prefix}_#{100_000_000 + System.unique_integer([:positive])}"

      defp sxc_write(ctx, lines) do
        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, Enum.join(lines, "\n"), database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)
      end

      defp sxc_query(ctx, sql, opts \\ []),
        do: unquote(client).query_sql(ctx.conn, sql, [database: ctx.database] ++ opts)

      defp sxc_planning(message), do: "Error during planning: " <> message

      defp sxc_coercion(message),
        do: "type_coercion\ncaused by\nError during planning: " <> message

      defp sxc_rows(ctx, sql) do
        assert {:ok, rows} = sxc_query(ctx, sql)
        rows
      end

      defp sxc_error(ctx, sql) do
        assert {:error, %{status: status, body: body}} = sxc_query(ctx, sql)
        {status, body}
      end

      # Three rows: a boolean that starts false, a string that is missing
      # from the last row, and a float that is not a whole number.
      defp sxc_mixed(ctx) do
        m = sxc_name("sxc_mix")

        sxc_write(ctx, [
          ~s|#{m},k=a v=1i,s="b",b=false,f=1.5 1000000000|,
          ~s|#{m},k=b v=2i,s="a",b=true,f=2.5 2000000000|,
          "#{m},k=c v=3i,b=true,f=500.0 3000000000"
        ])

        m
      end
    end
  end

  defp planning_tests do
    quote do
      describe "SQL executor — contract: nulls and planning" do
        test "a null in an IN list makes a miss unknown", ctx do
          m = sxc_mixed(ctx)

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v NOT IN (1, NULL)") == []
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v NOT IN (NULL)") == []
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v IN (NULL)") == []
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v IN (1, NULL)") == [%{"v" => 1}]
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE s IN ('a', NULL)") == [%{"v" => 2}]
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE s NOT IN ('zz', NULL)") == []

          assert {:ok, []} =
                   sxc_query(ctx, "SELECT v FROM #{m} WHERE v NOT IN (1, $x)",
                     params: %{"x" => nil}
                   )
        end

        test "an aggregate over a column it cannot take is a planning error", ctx do
          m = sxc_mixed(ctx)
          tail = " You might need to add explicit type casts.\n\tCandidate functions:\n\t"

          assert sxc_error(ctx, "SELECT sum(s) AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Execution error: Function 'sum' user-defined " <>
                      "coercion failed with \"Execution error: Sum not supported for Utf8\" " <>
                      "No function matches the given name and argument types 'sum(Utf8)'." <>
                      tail <> "sum(UserDefined)"}

          assert sxc_error(ctx, "SELECT avg(b) AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Execution error: Function 'avg' user-defined " <>
                      "coercion failed with \"Error during planning: Avg does not support " <>
                      "inputs of type Boolean.\" No function matches the given name and " <>
                      "argument types 'avg(Boolean)'." <> tail <> "avg(UserDefined)"}

          assert sxc_error(ctx, "SELECT median(s) AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Function 'median' expects NativeType::Numeric " <>
                      "but received NativeType::String No function matches the given name " <>
                      "and argument types 'median(Utf8)'." <> tail <> "median(Numeric(1))"}

          assert sxc_error(ctx, "SELECT stddev(k) AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Function 'stddev' expects NativeType::Numeric " <>
                      "but received NativeType::String No function matches the given name " <>
                      "and argument types 'stddev(Dictionary(Int32, Utf8))'." <>
                      tail <> "stddev(Numeric(1))"}

          for {call, name, column, native, type} <- [
                {"var_samp", "var", "s", "String", "Utf8"},
                {"var_pop", "var_pop", "b", "Boolean", "Boolean"},
                {"stddev_pop", "stddev_pop", "s", "String", "Utf8"}
              ] do
            assert sxc_error(ctx, "SELECT #{call}(#{column}) AS x FROM #{m}") ==
                     {400,
                      "Error during planning: Function '#{name}' expects NativeType::Numeric " <>
                        "but received NativeType::#{native} No function matches the given " <>
                        "name and argument types '#{name}(#{type})'." <>
                        tail <> "#{name}(Numeric(1))"},
                   call
          end

          assert sxc_error(ctx, "SELECT sum(k) AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Execution error: Function 'sum' user-defined " <>
                      "coercion failed with \"Execution error: Sum not supported for Utf8\" " <>
                      "No function matches the given name and argument types " <>
                      "'sum(Dictionary(Int32, Utf8))'." <> tail <> "sum(UserDefined)"}

          # Planning, not execution: no row is needed to fail.
          assert {400, "Error during planning: Function 'median' expects" <> _rest} =
                   sxc_error(ctx, "SELECT median(s) AS x FROM #{m} WHERE v > 100")
        end

        test "min, max and count take any type", ctx do
          m = sxc_mixed(ctx)

          assert sxc_rows(ctx, "SELECT min(b) AS lo, max(b) AS hi, count(b) AS n FROM #{m}") ==
                   [%{"lo" => false, "hi" => true, "n" => 3}]

          assert sxc_rows(ctx, "SELECT min(s) AS lo, max(s) AS hi, count(s) AS n FROM #{m}") ==
                   [%{"lo" => "a", "hi" => "b", "n" => 2}]

          assert sxc_rows(ctx, "SELECT min(k) AS lo, max(k) AS hi FROM #{m}") ==
                   [%{"lo" => "a", "hi" => "c"}]

          assert sxc_rows(ctx, "SELECT sum(v) AS s, avg(f) AS a, median(v) AS m FROM #{m}") ==
                   [%{"s" => 6, "a" => 168.0, "m" => 2}]
        end

        test "DATE_BIN: an interval of zero closes the connection, a time before 1970 floors",
             ctx do
          m = sxc_mixed(ctx)
          neg = sxc_name("sxc_neg")
          sxc_write(ctx, ["#{neg} v=1i -5", "#{neg} v=2i -15"])

          assert sxc_query(
                   ctx,
                   "SELECT DATE_BIN(INTERVAL '0 seconds', time) AS t, count(*) AS n " <>
                     "FROM #{m} GROUP BY 1"
                 ) == @sxc_closed

          assert sxc_rows(
                   ctx,
                   "SELECT DATE_BIN(INTERVAL '10 seconds', time) AS t, count(*) AS n " <>
                     "FROM #{neg} GROUP BY 1"
                 ) == [%{"t" => ~U[1969-12-31 23:59:50.000000Z], "n" => 2}]

          assert sxc_rows(
                   ctx,
                   "SELECT DATE_BIN(INTERVAL '0 seconds', time) AS t, count(*) AS n " <>
                     "FROM #{m} WHERE v > 100 GROUP BY 1"
                 ) == []
        end
      end
    end
  end

  defp result_tests do
    quote do
      describe "SQL executor — contract: results" do
        test "GROUP BY time is a row per distinct time", ctx do
          m = sxc_mixed(ctx)

          assert ctx
                 |> sxc_rows("SELECT time, count(*) AS n FROM #{m} GROUP BY time")
                 |> Enum.sort_by(& &1["time"], DateTime) == [
                   %{"time" => ~U[1970-01-01 00:00:01.000000Z], "n" => 1},
                   %{"time" => ~U[1970-01-01 00:00:02.000000Z], "n" => 1},
                   %{"time" => ~U[1970-01-01 00:00:03.000000Z], "n" => 1}
                 ]
        end

        test "a boolean column groups by its value, false included", ctx do
          m = sxc_mixed(ctx)

          assert ctx
                 |> sxc_rows("SELECT b, count(*) AS n FROM #{m} GROUP BY b")
                 |> Enum.sort_by(& &1["b"]) == [
                   %{"b" => false, "n" => 1},
                   %{"b" => true, "n" => 2}
                 ]
        end

        test "first_value of false is false; a null ordering value sorts last", ctx do
          m = sxc_mixed(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT first_value(b ORDER BY time) AS a, last_value(b ORDER BY time) AS z " <>
                     "FROM #{m}"
                 ) == [%{"a" => false, "z" => true}]

          assert sxc_rows(
                   ctx,
                   "SELECT first_value(v ORDER BY s) AS a, first_value(v ORDER BY s DESC) AS b, " <>
                     "last_value(v ORDER BY s) AS c, last_value(v ORDER BY s DESC) AS d " <>
                     "FROM #{m}"
                 ) == [%{"a" => 2, "b" => 3, "c" => 3, "d" => 2}]
        end

        test "arithmetic over text is a planning error naming the types", ctx do
          m = sxc_mixed(ctx)

          assert sxc_error(ctx, "SELECT s + 1 AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Utf8 + Int64 to valid types"}

          assert sxc_error(ctx, "SELECT k + 1 AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Dictionary(Int32, Utf8) + Int64 to valid types"}

          assert sxc_error(ctx, "SELECT v FROM #{m} WHERE s + 1 > 3") ==
                   {400,
                    "type_coercion\ncaused by\nError during planning: Cannot coerce " <>
                      "arithmetic expression Utf8 + Int64 to valid types"}

          assert sxc_error(ctx, "SELECT sum(s + 1) AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Utf8 + Int64 to valid types"}

          assert sxc_error(ctx, "SELECT 1 + s AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Int64 + Utf8 to valid types"}

          assert sxc_error(ctx, "SELECT b * 2 AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Boolean * Int64 to valid types"}

          # No row is needed to fail, and ORDER BY carries the wrapper like WHERE.
          assert sxc_error(ctx, "SELECT k + 1 AS x FROM #{m} WHERE v > 100") ==
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Dictionary(Int32, Utf8) + Int64 to valid types"}

          assert sxc_error(ctx, "SELECT v FROM #{m} ORDER BY s + 1") ==
                   {400,
                    "type_coercion\ncaused by\nError during planning: Cannot coerce " <>
                      "arithmetic expression Utf8 + Int64 to valid types"}

          assert ctx
                 |> sxc_rows("SELECT v + f AS x FROM #{m} ORDER BY time")
                 |> Enum.map(& &1["x"]) == [2.5, 4.5, 503.0]
        end

        test "a boolean casts to text and to numbers", ctx do
          m = sxc_mixed(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT CAST(b AS VARCHAR) AS t, CAST(b AS INTEGER) AS i, " <>
                     "CAST(b AS DOUBLE) AS d FROM #{m} ORDER BY time"
                 ) == [
                   %{"t" => "false", "i" => 0, "d" => 0.0},
                   %{"t" => "true", "i" => 1, "d" => 1.0},
                   %{"t" => "true", "i" => 1, "d" => 1.0}
                 ]
        end

        test "a CTE column named time can hold text, and null columns stay in its schema",
             ctx do
          m = sxc_mixed(ctx)

          assert ctx
                 |> sxc_rows("WITH c AS (SELECT s AS time FROM #{m}) SELECT * FROM c")
                 |> Enum.sort_by(&Map.get(&1, "time", "~")) ==
                   [%{"time" => "a"}, %{"time" => "b"}, %{}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT s AS time FROM #{m}) SELECT time FROM c ORDER BY time"
                 ) == [%{"time" => "a"}, %{"time" => "b"}, %{}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT time, v FROM #{m}) SELECT max(time) AS t FROM c"
                 ) == [%{"t" => ~U[1970-01-01 00:00:03.000000Z]}]

          assert sxc_rows(ctx, "WITH c AS (SELECT * FROM #{m} WHERE k = 'c') SELECT s FROM c") ==
                   [%{}]

          # The engine lists the CTE's columns, qualified; the double its own.
          assert {500, "Schema error: No field named zz. Valid fields are " <> _fields} =
                   sxc_error(
                     ctx,
                     "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') SELECT zz FROM c"
                   )

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') SELECT s FROM c"
                 ) == [%{}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') " <>
                     "SELECT count(s) AS n, count(*) AS m FROM c"
                 ) == [%{"n" => 0, "m" => 1}]
        end
      end
    end
  end

  defp division_tests(client) do
    quote do
      describe "SQL executor — contract: division by zero" do
        test "dividing an integer by the integer zero closes the connection", ctx do
          m = sxc_mixed(ctx)

          assert sxc_query(ctx, "SELECT v / 0 AS x FROM #{m}") == @sxc_closed
          assert sxc_query(ctx, "SELECT v % 0 AS x FROM #{m}") == @sxc_closed
          assert sxc_query(ctx, "SELECT sum(v / 0) AS x FROM #{m}") == @sxc_closed
          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v / 0 > 1") == @sxc_closed
          assert {:ok, []} = sxc_query(ctx, "SELECT v / 0 AS x FROM #{m} WHERE v > 100")
        end

        # The engine's infinity and NaN show as null in a response but
        # compare as numbers; the double, which cannot hold them, refuses.
        test "a float divided by zero is infinity on the engine; the double refuses it", ctx do
          m = sxc_name("sxc_fz")
          sxc_write(ctx, ["#{m} v=1i 1000000000", "#{m} v=2i 2000000000"])

          if unquote(client) == InfluxElixir.Client.Local do
            refusal =
              {:error,
               %{
                 status: 400,
                 body:
                   "Client.Local: a float divided by zero is IEEE infinity or NaN on the " <>
                     "engine, which the double cannot hold"
               }}

            for sql <- [
                  "SELECT v / 0.0 AS x FROM #{m}",
                  "SELECT 1.5 / 0 AS y FROM #{m}",
                  "SELECT v % 0.0 AS z FROM #{m}",
                  "SELECT 1.5 % 0 AS y FROM #{m}",
                  "SELECT v FROM #{m} WHERE v / 0.0 > 1"
                ] do
              assert sxc_query(ctx, sql) == refusal, sql
            end
          else
            # Present as JSON null, unlike a null column, which is absent.
            assert sxc_rows(ctx, "SELECT v / 0.0 AS x, 1.5 / 0 AS y FROM #{m}") ==
                     [%{"x" => nil, "y" => nil}, %{"x" => nil, "y" => nil}]

            assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v / 0.0 > 1 ORDER BY v") ==
                     [%{"v" => 1}, %{"v" => 2}]
          end
        end
      end
    end
  end

  defp wording_tests do
    quote do
      describe "SQL executor — contract: the planner's wording" do
        test "a float compared with a string is compared as the text the engine writes", ctx do
          m = sxc_name("sxc_fl")

          sxc_write(ctx, [
            "#{m},k=a amount=5000.0 1000000000",
            "#{m},k=b amount=500.0 2000000000",
            "#{m},k=c amount=12000.0 3000000000",
            "#{m},k=d amount=1e16 4000000000",
            "#{m},k=e amount=1e-5 5000000000",
            "#{m},k=f amount=1.5e-7 6000000000",
            "#{m},k=g amount=123456789.5 7000000000",
            "#{m},k=h amount=-2.5 8000000000",
            "#{m},k=i amount=1e15 9000000000"
          ])

          for {where, expected} <- [
                {"amount = '5000.0'", ["a"]},
                {"amount >= '1000.00'", ["a", "b", "c", "d", "g", "i"]},
                {"amount > '2e3'", ["a", "b"]},
                {"amount = '1e16'", ["d"]},
                {"amount = '1.0e16'", []},
                {"amount = '0.00001'", ["e"]},
                {"amount = '1e-5'", []},
                {"amount = '1.5e-7'", ["f"]},
                {"amount = '1000000000000000.0'", ["i"]},
                {"amount = '-2.5'", ["h"]}
              ] do
            assert ctx
                   |> sxc_rows("SELECT k FROM #{m} WHERE #{where} ORDER BY time")
                   |> Enum.map(& &1["k"]) == expected,
                   where
          end

          assert sxc_rows(ctx, "SELECT CAST(amount AS VARCHAR) AS x FROM #{m} ORDER BY time")
                 |> Enum.map(& &1["x"]) == [
                   "5000.0",
                   "500.0",
                   "12000.0",
                   "1e16",
                   "0.00001",
                   "1.5e-7",
                   "123456789.5",
                   "-2.5",
                   "1000000000000000.0"
                 ]
        end

        test "LIKE over a number names the column's type", ctx do
          m = sxc_mixed(ctx)
          prefix = "type_coercion\ncaused by\nError during planning: There isn't a common type to"

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE f LIKE '1%'") ==
                   {400, prefix <> " coerce Float64 and Utf8 in LIKE expression"}

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE v LIKE '1%'") ==
                   {400, prefix <> " coerce Int64 and Utf8 in LIKE expression"}

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE f LIKE '1%' AND k = 'zz'") ==
                   {400, prefix <> " coerce Float64 and Utf8 in LIKE expression"}

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE b NOT LIKE 't%'") ==
                   {400, prefix <> " coerce Boolean and Utf8 in LIKE expression"}
        end
      end
    end
  end

  defp join_tests(profile) do
    quote do
      describe "SQL executor — contract: joins, groups and formats" do
        test "an unqualified column on both sides of a CROSS JOIN is ambiguous", ctx do
          left = sxc_name("sxc_px")
          right = sxc_name("sxc_ref")

          sxc_write(ctx, [
            "#{left},symbol=AAA price=10.5,qty=3i 1000000000",
            "#{right},symbol=AAA price=1.0 1000000000"
          ])

          assert sxc_error(ctx, "SELECT price, symbol FROM #{left} CROSS JOIN #{right}") ==
                   {500, "Schema error: Ambiguous reference to unqualified field price"}

          assert sxc_error(
                   ctx,
                   "SELECT qty, time FROM #{left} CROSS JOIN #{right} WHERE price > 1"
                 ) == {500, "Schema error: Ambiguous reference to unqualified field price"}

          assert sxc_error(
                   ctx,
                   "SELECT qty FROM #{left} CROSS JOIN #{right} WHERE symbol = 'a'"
                 ) == {500, "Schema error: Ambiguous reference to unqualified field symbol"}
        end

        test "columns that are not shared join", ctx do
          left = sxc_name("sxc_px")
          right = sxc_name("sxc_ref")

          sxc_write(ctx, [
            "#{left},symbol=AAA price=10.5,qty=3i 1000000000",
            "#{left},symbol=BBB price=20.5,qty=4i 2000000000",
            "#{right},zz=1 only2=5i 1000000000"
          ])

          assert sxc_rows(
                   ctx,
                   "SELECT qty, only2 FROM #{left} CROSS JOIN #{right} ORDER BY qty"
                 ) == [%{"qty" => 3, "only2" => 5}, %{"qty" => 4, "only2" => 5}]
        end

        test "an ungrouped column names itself and what satisfies the requirement", ctx do
          m = sxc_name("sxc_grp")
          sxc_write(ctx, ["#{m},symbol=AAA,exch=X price=10.5,qty=3i 1000000000"])

          ungrouped = fn column, satisfying ->
            "Error during planning: Column in SELECT must be in GROUP BY or an aggregate " <>
              "function: While expanding wildcard, column \"#{m}.#{column}\" must appear in " <>
              "the GROUP BY clause or must be part of an aggregate function, currently " <>
              "only \"#{satisfying}\" appears in the SELECT clause satisfies this requirement"
          end

          assert sxc_error(ctx, "SELECT symbol, price, count(*) AS n FROM #{m}") ==
                   {400, ungrouped.("symbol", "count(Int64(1))")}

          assert sxc_error(
                   ctx,
                   "SELECT symbol, price, qty, count(*) AS n FROM #{m} GROUP BY symbol"
                 ) == {400, ungrouped.("price", "#{m}.symbol, count(Int64(1))")}

          assert sxc_error(
                   ctx,
                   "SELECT exch, price, count(*) AS n FROM #{m} GROUP BY symbol, exch"
                 ) == {400, ungrouped.("price", "#{m}.symbol, #{m}.exch, count(Int64(1))")}

          assert sxc_error(
                   ctx,
                   "SELECT exch, count(*) AS a, sum(price) AS b, avg(qty) AS c, " <>
                     "min(price) AS d FROM #{m} GROUP BY symbol"
                 ) ==
                   {400,
                    ungrouped.(
                      "exch",
                      "#{m}.symbol, count(Int64(1)), sum(#{m}.price), avg(#{m}.qty), " <>
                        "min(#{m}.price)"
                    )}

          # An expression is printed as the planner prints it.
          assert sxc_error(
                   ctx,
                   "SELECT exch, sum(price * 2.5) AS a, count(DISTINCT qty) AS b, " <>
                     "sum(abs(price) - 1) AS c FROM #{m} GROUP BY symbol"
                 ) ==
                   {400,
                    ungrouped.(
                      "exch",
                      "#{m}.symbol, sum(#{m}.price * Float64(2.5)), " <>
                        "count(DISTINCT #{m}.qty), sum(abs(#{m}.price) - Int64(1))"
                    )}

          # A DATE_BIN is printed by its interval in nanoseconds.
          assert sxc_error(
                   ctx,
                   "SELECT price, DATE_BIN(INTERVAL '10 seconds', time) AS t, count(*) AS n " <>
                     "FROM #{m} GROUP BY 2"
                 ) ==
                   {400,
                    ungrouped.(
                      "price",
                      ~s|date_bin(IntervalMonthDayNano("IntervalMonthDayNano { months: 0, | <>
                        ~s|days: 0, nanoseconds: 10000000000 }"),#{m}.time), count(Int64(1))|
                    )}
        end

        if unquote(profile) == :v3_core do
          test "an unknown format ends with its position in the request body", ctx do
            assert {:error, %{status: 400, body: body}} =
                     sxc_query(ctx, "SELECT 1", format: :xml)

            assert body ==
                     "serde json error: unknown variant `xml`, expected one of `parquet`, " <>
                       "`csv`, `pretty`, `json`, `json_lines`, `jsonl` at line 1 column " <>
                       Integer.to_string(20 + byte_size(ctx.database) + byte_size("xml"))
          end
        end
      end
    end
  end

  defp null_between_tests do
    quote do
      describe "SQL executor — contract: NULL bounds" do
        test "a null bound makes BETWEEN unknown, with three-valued AND", ctx do
          m = sxc_name("sxc_between")
          sxc_write(ctx, ["#{m} v=3i 1000000000", "#{m} v=2i 2000000000", "#{m} v=0i 3000000000"])

          for {where, values} <- [
                {"v NOT BETWEEN NULL AND 2", [3]},
                {"v BETWEEN NULL AND 5", []},
                {"v NOT BETWEEN 1 AND NULL", [0]},
                {"v BETWEEN 1 AND NULL", []},
                {"v BETWEEN NULL AND NULL", []},
                {"v NOT BETWEEN NULL AND NULL", []}
              ] do
            assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE #{where} ORDER BY time") ==
                     Enum.map(values, &%{"v" => &1}),
                   where
          end
        end
      end
    end
  end

  defp plan_order_tests do
    quote do
      describe "SQL executor — contract: which planning error comes first" do
        test "the select list's calls, operators and aggregates, then WHERE, then ORDER BY",
             ctx do
          m = sxc_mixed(ctx)
          tail = " You might need to add explicit type casts.\n\tCandidate functions:\n\t"
          sum = "Execution error: Function 'sum' user-defined coercion failed with "

          abs =
            "Function 'abs' expects NativeType::Numeric but received NativeType::String No " <>
              "function matches the given name and argument types 'abs(Utf8)'." <>
              tail <> "abs(Numeric(1))"

          op = "Cannot coerce arithmetic expression Utf8 + Int64 to valid types"

          for {sql, error} <- [
                {"SELECT abs(s) AS a FROM #{m} WHERE abs(k) > 1 ORDER BY abs(s)",
                 sxc_planning(abs)},
                {"SELECT v + s AS x FROM #{m} WHERE abs(s) > 1",
                 sxc_planning("Cannot coerce arithmetic expression Int64 + Utf8 to valid types")},
                {"SELECT sum(s) AS t FROM #{m} WHERE abs(k) > 1",
                 sxc_planning(
                   sum <>
                     "\"Execution error: Sum not supported for Utf8\" No function matches " <>
                     "the given name and argument types 'sum(Utf8)'." <>
                     tail <> "sum(UserDefined)"
                 )},
                {"SELECT abs(s) AS a, s + 1 AS b FROM #{m}", sxc_planning(abs)},
                {"SELECT s + 1 AS a, abs(s) AS b FROM #{m}", sxc_planning(op)},
                {"SELECT v FROM #{m} WHERE abs(s) > 1 ORDER BY s + 1", sxc_coercion(abs)},
                {"SELECT v FROM #{m} WHERE s + 1 > 1 ORDER BY abs(s)", sxc_coercion(op)}
              ] do
            assert sxc_error(ctx, sql) == {400, error}, sql
          end
        end

        test "within WHERE the calls, operators and regexes go as written, the LIKEs after",
             ctx do
          m = sxc_mixed(ctx)
          tail = " You might need to add explicit type casts.\n\tCandidate functions:\n\t"

          abs =
            "Function 'abs' expects NativeType::Numeric but received NativeType::String No " <>
              "function matches the given name and argument types 'abs(Utf8)'." <>
              tail <> "abs(Numeric(1))"

          op = "Cannot coerce arithmetic expression Utf8 + Int64 to valid types"
          like = "There isn't a common type to coerce Int64 and Utf8 in LIKE expression"
          regex = "Cannot infer common argument type for regex operation Int64 ~ Utf8"
          cmp = "Cannot infer common argument type for comparison operation Int64 = Boolean"

          for {where, message} <- [
                {"abs(s) > 1 AND s + 1 > 1", abs},
                {"s + 1 > 1 AND abs(s) > 1", op},
                {"v LIKE 'a' AND s + 1 > 1", op},
                {"v LIKE 'a' AND abs(s) > 1", abs},
                {"v ~ 'a' AND abs(s) > 1", regex},
                {"abs(s) > 1 AND v ~ 'a'", abs},
                {"v = true AND abs(s) > 1", cmp},
                {"abs(s) > 1 AND v = true", abs},
                {"v LIKE 'a' AND v = true", cmp},
                {"-s > 1 AND v LIKE 'a'", like}
              ] do
            assert sxc_error(ctx, "SELECT v FROM #{m} WHERE #{where}") ==
                     {400, "type_coercion\ncaused by\nError during planning: " <> message},
                   where
          end
        end

        test "a LIKE comes before ORDER BY, which comes before a negation", ctx do
          m = sxc_mixed(ctx)
          prefix = "type_coercion\ncaused by\nError during planning: "

          # ORDER BY's message is cut after its first sentence.
          abs =
            "Function 'abs' expects NativeType::Numeric but received NativeType::String"

          for {sql, message} <- [
                {"SELECT v FROM #{m} WHERE v LIKE 'a' ORDER BY abs(s)",
                 "There isn't a common type to coerce Int64 and Utf8 in LIKE expression"},
                {"SELECT -s AS a FROM #{m} ORDER BY abs(s)", abs},
                {"SELECT v FROM #{m} WHERE -s > 1 ORDER BY s + 1",
                 "Cannot coerce arithmetic expression Utf8 + Int64 to valid types"}
              ] do
            assert sxc_error(ctx, sql) == {400, prefix <> message}, sql
          end

          assert sxc_error(ctx, "SELECT -s AS a FROM #{m}") ==
                   {400,
                    "Error during planning: Negation only supports numeric, interval and " <>
                      "timestamp types"}
        end

        test "a call is typed from the first row that has the column", ctx do
          m = sxc_name("sxc_typed")

          sxc_write(ctx, [
            "#{m} v=1i 1000000000",
            "#{m} v=2i 2000000000",
            ~s|#{m} v=3i,s="x" 3000000000|
          ])

          assert sxc_error(ctx, "SELECT abs(s) AS x FROM #{m}") ==
                   {400,
                    "Error during planning: Function 'abs' expects NativeType::Numeric but " <>
                      "received NativeType::String No function matches the given name and " <>
                      "argument types 'abs(Utf8)'. You might need to add explicit type " <>
                      "casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}

          assert sxc_rows(ctx, "SELECT abs(v) AS x FROM #{m} ORDER BY time LIMIT 1") ==
                   [%{"x" => 1}]
        end
      end
    end
  end

  defp boolean_tests(client) do
    quote do
      describe "SQL executor — contract: a boolean is comparable with a boolean" do
        test "a comparison, an IN list and a BETWEEN name the types", ctx do
          m = sxc_mixed(ctx)
          cmp = "Cannot infer common argument type for comparison operation "
          list = "Can not find compatible types to compare "

          between =
            "type_coercion\ncaused by\nInternal error: Failed to coerce types Int64 and " <>
              "Boolean in BETWEEN expression.\n" <>
              "This issue was likely caused by a bug in DataFusion's code. Please help us to " <>
              "resolve this by filing a bug report in our issue tracker: " <>
              "https://github.com/apache/datafusion/issues"

          for {where, status, body} <- [
                {"v = true", 400, sxc_coercion(cmp <> "Int64 = Boolean")},
                {"v > false", 400, sxc_coercion(cmp <> "Int64 > Boolean")},
                {"v <> true", 400, sxc_coercion(cmp <> "Int64 != Boolean")},
                {"f = true", 400, sxc_coercion(cmp <> "Float64 = Boolean")},
                {"k = true", 400, sxc_coercion(cmp <> "Dictionary(Int32, Utf8) = Boolean")},
                {"b = 1", 400, sxc_coercion(cmp <> "Boolean = Int64")},
                {"b = 'true'", 400, sxc_coercion(cmp <> "Boolean = Utf8")},
                {"v + 1 = true", 400, sxc_coercion(cmp <> "Int64 = Boolean")},
                {"v IN (1, true)", 400, sxc_coercion(list <> "Int64 with [Int64, Boolean]")},
                {"v IN (1, true, NULL)", 400,
                 sxc_coercion(list <> "Int64 with [Int64, Boolean, Null]")},
                {"k IN ('a', true)", 400,
                 sxc_coercion(list <> "Dictionary(Int32, Utf8) with [Utf8, Boolean]")},
                {"s NOT IN (1, true)", 400, sxc_coercion(list <> "Utf8 with [Int64, Boolean]")},
                {"b IN (1)", 400, sxc_coercion(list <> "Boolean with [Int64]")},
                {"v BETWEEN 1 AND true", 500, between},
                {"v NOT BETWEEN false AND 1", 500, between}
              ] do
            assert sxc_error(ctx, "SELECT v FROM #{m} WHERE #{where}") == {status, body}, where
          end
        end

        test "a boolean column takes a boolean", ctx do
          m = sxc_mixed(ctx)

          for {where, values} <- [
                {"b = true", [2, 3]},
                {"b = false", [1]},
                {"b IN (true, false)", [1, 2, 3]},
                {"b BETWEEN true AND false", []},
                {"v IN (1, NULL)", [1]}
              ] do
            assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE #{where} ORDER BY time") ==
                     Enum.map(values, &%{"v" => &1}),
                   where
          end
        end

        test "a boolean parameter has the same types", ctx do
          m = sxc_mixed(ctx)
          cmp = "Cannot infer common argument type for comparison operation "

          for {where, params, message} <- [
                {"v = $p", %{p: true}, cmp <> "Int64 = Boolean"},
                {"f = $p", %{p: true}, cmp <> "Float64 = Boolean"},
                {"k = $p", %{p: true}, cmp <> "Dictionary(Int32, Utf8) = Boolean"},
                {"b = $p", %{p: 1}, cmp <> "Boolean = UInt64"},
                {"b = $p", %{p: -1}, cmp <> "Boolean = Int64"},
                {"b = $p", %{p: "true"}, cmp <> "Boolean = Utf8"}
              ] do
            assert sxc_query(ctx, "SELECT v FROM #{m} WHERE #{where}", params: params) ==
                     {:error,
                      %{
                        status: 400,
                        body: "type_coercion\ncaused by\nError during planning: " <> message
                      }},
                   where
          end

          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE b = $p ORDER BY time",
                   params: %{p: true}
                 ) ==
                   {:ok, [%{"v" => 2}, %{"v" => 3}]}

          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE b = $p", params: %{p: nil}) == {:ok, []}
        end

        test "a boolean written first is the engine's or refused by name", ctx do
          m = sxc_mixed(ctx)
          sql = "SELECT v FROM #{m} WHERE true = b ORDER BY time"

          expected =
            if unquote(client) == InfluxElixir.Client.Local,
              do:
                {:error,
                 %{
                   status: 400,
                   body:
                     "Client.Local: a boolean on the left of a comparison is outside the " <>
                       "double's subset; write the column first: true = b"
                 }},
              else: {:ok, [%{"v" => 2}, %{"v" => 3}]}

          assert sxc_query(ctx, sql) == expected
        end
      end
    end
  end
end
