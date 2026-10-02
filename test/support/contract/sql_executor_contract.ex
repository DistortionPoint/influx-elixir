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

    quote location: :keep do
      unquote(helpers(client))
      unquote(planning_tests())
      unquote(null_between_tests())
      unquote(plan_order_tests())
      unquote(boolean_tests(client))
      unquote(result_tests())
      unquote(integer_tests())
      unquote(division_tests(client))
      unquote(wording_tests())
      unquote(join_tests(profile))
      unquote(bounds_helpers())
      unquote(bounds_error_tests())
      unquote(bounds_answer_tests())
      unquote(bounds_order_tests(client))
    end
  end

  defp helpers(client) do
    quote location: :keep do
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
    quote location: :keep do
      describe "SQL executor — contract: nulls and planning" do
        test "a null in an IN list makes a miss unknown", ctx do
          m = sxc_mixed(ctx)

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v NOT IN (1, NULL)") === []
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v NOT IN (NULL)") === []
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v IN (NULL)") === []
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v IN (1, NULL)") === [%{"v" => 1}]
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE s IN ('a', NULL)") === [%{"v" => 2}]
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE s NOT IN ('zz', NULL)") === []

          assert {:ok, []} =
                   sxc_query(ctx, "SELECT v FROM #{m} WHERE v NOT IN (1, $x)",
                     params: %{"x" => nil}
                   )
        end

        test "an aggregate over a column it cannot take is a planning error", ctx do
          m = sxc_mixed(ctx)
          tail = " You might need to add explicit type casts.\n\tCandidate functions:\n\t"

          assert sxc_error(ctx, "SELECT sum(s) AS x FROM #{m}") ===
                   {400,
                    "Error during planning: Execution error: Function 'sum' user-defined " <>
                      "coercion failed with \"Execution error: Sum not supported for Utf8\" " <>
                      "No function matches the given name and argument types 'sum(Utf8)'." <>
                      tail <> "sum(UserDefined)"}

          assert sxc_error(ctx, "SELECT avg(b) AS x FROM #{m}") ===
                   {400,
                    "Error during planning: Execution error: Function 'avg' user-defined " <>
                      "coercion failed with \"Error during planning: Avg does not support " <>
                      "inputs of type Boolean.\" No function matches the given name and " <>
                      "argument types 'avg(Boolean)'." <> tail <> "avg(UserDefined)"}

          assert sxc_error(ctx, "SELECT median(s) AS x FROM #{m}") ===
                   {400,
                    "Error during planning: Function 'median' expects NativeType::Numeric " <>
                      "but received NativeType::String No function matches the given name " <>
                      "and argument types 'median(Utf8)'." <> tail <> "median(Numeric(1))"}

          assert sxc_error(ctx, "SELECT stddev(k) AS x FROM #{m}") ===
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
            assert sxc_error(ctx, "SELECT #{call}(#{column}) AS x FROM #{m}") ===
                     {400,
                      "Error during planning: Function '#{name}' expects NativeType::Numeric " <>
                        "but received NativeType::#{native} No function matches the given " <>
                        "name and argument types '#{name}(#{type})'." <>
                        tail <> "#{name}(Numeric(1))"},
                   call
          end

          assert sxc_error(ctx, "SELECT sum(k) AS x FROM #{m}") ===
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

          assert sxc_rows(ctx, "SELECT min(b) AS lo, max(b) AS hi, count(b) AS n FROM #{m}") ===
                   [%{"lo" => false, "hi" => true, "n" => 3}]

          assert sxc_rows(ctx, "SELECT min(s) AS lo, max(s) AS hi, count(s) AS n FROM #{m}") ===
                   [%{"lo" => "a", "hi" => "b", "n" => 2}]

          assert sxc_rows(ctx, "SELECT min(k) AS lo, max(k) AS hi FROM #{m}") ===
                   [%{"lo" => "a", "hi" => "c"}]
        end

        test "sum, avg and median take numbers and answer in the number's type", ctx do
          m = sxc_mixed(ctx)

          assert sxc_rows(ctx, "SELECT sum(v) AS s, avg(f) AS a, median(v) AS m FROM #{m}") ===
                   [%{"s" => 6, "a" => 168.0, "m" => 2}]
        end

        @tag local_divergence:
               "the engine closes the connection mid-response; Local returns the transport error"
        test "DATE_BIN: an interval of zero closes the connection, a time before 1970 floors",
             ctx do
          m = sxc_mixed(ctx)
          neg = sxc_name("sxc_neg")
          sxc_write(ctx, ["#{neg} v=1i -5", "#{neg} v=2i -15"])

          assert sxc_query(
                   ctx,
                   "SELECT DATE_BIN(INTERVAL '0 seconds', time) AS t, count(*) AS n " <>
                     "FROM #{m} GROUP BY 1"
                 ) === @sxc_closed

          assert sxc_rows(
                   ctx,
                   "SELECT DATE_BIN(INTERVAL '10 seconds', time) AS t, count(*) AS n " <>
                     "FROM #{neg} GROUP BY 1"
                 ) === [%{"t" => ~U[1969-12-31 23:59:50.000000Z], "n" => 2}]

          assert sxc_rows(
                   ctx,
                   "SELECT DATE_BIN(INTERVAL '0 seconds', time) AS t, count(*) AS n " <>
                     "FROM #{m} WHERE v > 100 GROUP BY 1"
                 ) === []
        end
      end
    end
  end

  defp result_tests do
    quote location: :keep do
      describe "SQL executor — contract: results" do
        test "GROUP BY time is a row per distinct time", ctx do
          m = sxc_mixed(ctx)

          assert ctx
                 |> sxc_rows("SELECT time, count(*) AS n FROM #{m} GROUP BY time")
                 |> Enum.sort_by(& &1["time"], DateTime) === [
                   %{"time" => ~U[1970-01-01 00:00:01.000000Z], "n" => 1},
                   %{"time" => ~U[1970-01-01 00:00:02.000000Z], "n" => 1},
                   %{"time" => ~U[1970-01-01 00:00:03.000000Z], "n" => 1}
                 ]
        end

        test "a boolean column groups by its value, false included", ctx do
          m = sxc_mixed(ctx)

          assert ctx
                 |> sxc_rows("SELECT b, count(*) AS n FROM #{m} GROUP BY b")
                 |> Enum.sort_by(& &1["b"]) === [
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
                 ) === [%{"a" => false, "z" => true}]

          assert sxc_rows(
                   ctx,
                   "SELECT first_value(v ORDER BY s) AS a, first_value(v ORDER BY s DESC) AS b, " <>
                     "last_value(v ORDER BY s) AS c, last_value(v ORDER BY s DESC) AS d " <>
                     "FROM #{m}"
                 ) === [%{"a" => 2, "b" => 3, "c" => 3, "d" => 2}]
        end

        test "arithmetic over text is a planning error naming the types", ctx do
          m = sxc_mixed(ctx)

          assert sxc_error(ctx, "SELECT s + 1 AS x FROM #{m}") ===
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Utf8 + Int64 to valid types"}

          assert sxc_error(ctx, "SELECT k + 1 AS x FROM #{m}") ===
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Dictionary(Int32, Utf8) + Int64 to valid types"}

          assert sxc_error(ctx, "SELECT v FROM #{m} WHERE s + 1 > 3") ===
                   {400,
                    "type_coercion\ncaused by\nError during planning: Cannot coerce " <>
                      "arithmetic expression Utf8 + Int64 to valid types"}

          assert sxc_error(ctx, "SELECT sum(s + 1) AS x FROM #{m}") ===
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Utf8 + Int64 to valid types"}

          assert sxc_error(ctx, "SELECT 1 + s AS x FROM #{m}") ===
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Int64 + Utf8 to valid types"}

          assert sxc_error(ctx, "SELECT b * 2 AS x FROM #{m}") ===
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Boolean * Int64 to valid types"}

          # No row is needed to fail, and ORDER BY carries the wrapper like WHERE.
          assert sxc_error(ctx, "SELECT k + 1 AS x FROM #{m} WHERE v > 100") ===
                   {400,
                    "Error during planning: Cannot coerce arithmetic expression " <>
                      "Dictionary(Int32, Utf8) + Int64 to valid types"}

          assert sxc_error(ctx, "SELECT v FROM #{m} ORDER BY s + 1") ===
                   {400,
                    "type_coercion\ncaused by\nError during planning: Cannot coerce " <>
                      "arithmetic expression Utf8 + Int64 to valid types"}

          assert ctx
                 |> sxc_rows("SELECT v + f AS x FROM #{m} ORDER BY time")
                 |> Enum.map(& &1["x"]) === [2.5, 4.5, 503.0]
        end

        test "a boolean casts to text and to numbers", ctx do
          m = sxc_mixed(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT CAST(b AS VARCHAR) AS t, CAST(b AS INTEGER) AS i, " <>
                     "CAST(b AS DOUBLE) AS d FROM #{m} ORDER BY time"
                 ) === [
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
                 |> Enum.sort_by(&Map.get(&1, "time", "~")) ===
                   [%{"time" => "a"}, %{"time" => "b"}, %{}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT s AS time FROM #{m}) SELECT time FROM c ORDER BY time"
                 ) === [%{"time" => "a"}, %{"time" => "b"}, %{}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT time, v FROM #{m}) SELECT max(time) AS t FROM c"
                 ) === [%{"t" => ~U[1970-01-01 00:00:03.000000Z]}]

          assert sxc_rows(ctx, "WITH c AS (SELECT * FROM #{m} WHERE k = 'c') SELECT s FROM c") ===
                   [%{}]

          assert sxc_error(
                   ctx,
                   "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') SELECT zz FROM c"
                 ) === {500, "Schema error: No field named zz. Valid fields are c.k, c.s."}

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') SELECT s FROM c"
                 ) === [%{}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') " <>
                     "SELECT count(s) AS n, count(*) AS m FROM c"
                 ) === [%{"n" => 0, "m" => 1}]
        end
      end
    end
  end

  defp integer_tests do
    quote location: :keep do
      describe "SQL executor — contract: Int64 arithmetic" do
        @int64_max 9_223_372_036_854_775_807
        @int64_min -9_223_372_036_854_775_808

        test "+, -, * and negation wrap in two's complement", ctx do
          m = sxc_name("sxc_wrap")

          sxc_write(ctx, [
            "#{m} y=1i 1000000000",
            "#{m} y=2i 2000000000",
            "#{m} y=#{@int64_min}i 3000000000"
          ])

          select =
            "SELECT y + #{@int64_max} AS a, y - #{@int64_max} AS b, y * #{@int64_max} AS c, " <>
              "-y AS d, y * 2 AS e, y - 1 AS f, y * -1 AS g FROM #{m} ORDER BY time"

          assert sxc_rows(ctx, select) === [
                   %{
                     "a" => @int64_min,
                     "b" => -@int64_max + 1,
                     "c" => @int64_max,
                     "d" => -1,
                     "e" => 2,
                     "f" => 0,
                     "g" => -1
                   },
                   %{
                     "a" => @int64_min + 1,
                     "b" => -@int64_max + 2,
                     "c" => -2,
                     "d" => -2,
                     "e" => 4,
                     "f" => 1,
                     "g" => -2
                   },
                   %{
                     "a" => -1,
                     "b" => 1,
                     "c" => @int64_min,
                     "d" => @int64_min,
                     "e" => 0,
                     "f" => @int64_max,
                     "g" => @int64_min
                   }
                 ]
        end

        test "a constant and a WHERE wrap as a column does", ctx do
          m = sxc_name("sxc_wrap_where")
          sxc_write(ctx, ["#{m} y=1i 1000000000", "#{m} y=-5i 2000000000"])

          assert sxc_rows(
                   ctx,
                   "SELECT #{@int64_max} * 2 AS a, -#{@int64_max} - 2 AS b FROM #{m} LIMIT 1"
                 ) === [%{"a" => -2, "b" => @int64_max}]

          assert sxc_rows(ctx, "SELECT y FROM #{m} WHERE y + #{@int64_max} < 0 ORDER BY time") ===
                   [%{"y" => 1}]
        end

        @tag local_divergence:
               "the engine closes the connection mid-response; Local returns the transport error"
        test "the minimum divided by -1 closes the connection; its remainder is 0", ctx do
          m = sxc_name("sxc_wrap_div")
          sxc_write(ctx, ["#{m} y=#{@int64_min}i 1000000000"])

          assert sxc_query(ctx, "SELECT y / -1 AS a FROM #{m}") === @sxc_closed
          assert sxc_rows(ctx, "SELECT y % -1 AS a FROM #{m}") === [%{"a" => 0}]

          assert sxc_rows(ctx, "SELECT y / 1 AS a, y / 2 AS b FROM #{m}") ===
                   [%{"a" => @int64_min, "b" => -4_611_686_018_427_387_904}]
        end
      end
    end
  end

  defp division_tests(client) do
    quote location: :keep do
      describe "SQL executor — contract: division by zero" do
        @tag local_divergence:
               "the engine closes the connection mid-response; Local returns the transport error"
        test "dividing an integer by the integer zero closes the connection", ctx do
          m = sxc_mixed(ctx)

          assert sxc_query(ctx, "SELECT v / 0 AS x FROM #{m}") === @sxc_closed
          assert sxc_query(ctx, "SELECT v % 0 AS x FROM #{m}") === @sxc_closed
          assert sxc_query(ctx, "SELECT sum(v / 0) AS x FROM #{m}") === @sxc_closed
          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v / 0 > 1") === @sxc_closed
          assert {:ok, []} = sxc_query(ctx, "SELECT v / 0 AS x FROM #{m} WHERE v > 100")
        end

        # The engine's infinity and NaN show as null in a response but
        # compare as numbers; the double, which cannot hold them, refuses.
        @tag local_divergence:
               "the engine's infinity and NaN compare as numbers; Local, which cannot hold them, refuses by name"
        test "a float divided by zero is infinity on the engine; the double refuses it", ctx do
          m = sxc_name("sxc_fz")
          sxc_write(ctx, ["#{m} v=1i 1000000000", "#{m} v=2i 2000000000"])

          if unquote(client) === InfluxElixir.Client.Local do
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
              assert sxc_query(ctx, sql) === refusal, sql
            end
          else
            # Present as JSON null, unlike a null column, which is absent.
            assert sxc_rows(ctx, "SELECT v / 0.0 AS x, 1.5 / 0 AS y FROM #{m}") ===
                     [%{"x" => nil, "y" => nil}, %{"x" => nil, "y" => nil}]

            assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v / 0.0 > 1 ORDER BY v") ===
                     [%{"v" => 1}, %{"v" => 2}]
          end
        end
      end
    end
  end

  defp wording_tests do
    quote location: :keep do
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
                {"amount = '500.0'", ["b"]},
                {"amount = '500'", []},
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
                   |> Enum.map(& &1["k"]) === expected,
                   where
          end

          assert sxc_rows(ctx, "SELECT CAST(amount AS VARCHAR) AS x FROM #{m} ORDER BY time")
                 |> Enum.map(& &1["x"]) === [
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

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE f LIKE '1%'") ===
                   {400, prefix <> " coerce Float64 and Utf8 in LIKE expression"}

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE v LIKE '1%'") ===
                   {400, prefix <> " coerce Int64 and Utf8 in LIKE expression"}

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE f LIKE '1%' AND k = 'zz'") ===
                   {400, prefix <> " coerce Float64 and Utf8 in LIKE expression"}

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE b NOT LIKE 't%'") ===
                   {400, prefix <> " coerce Boolean and Utf8 in LIKE expression"}
        end
      end
    end
  end

  defp join_tests(profile) do
    quote location: :keep do
      describe "SQL executor — contract: joins, groups and formats" do
        test "an unqualified column on both sides of a CROSS JOIN is ambiguous", ctx do
          left = sxc_name("sxc_px")
          right = sxc_name("sxc_ref")

          sxc_write(ctx, [
            "#{left},symbol=AAA price=10.5,qty=3i 1000000000",
            "#{right},symbol=AAA price=1.0 1000000000"
          ])

          assert sxc_error(ctx, "SELECT price, symbol FROM #{left} CROSS JOIN #{right}") ===
                   {500, "Schema error: Ambiguous reference to unqualified field price"}

          assert sxc_error(
                   ctx,
                   "SELECT qty, time FROM #{left} CROSS JOIN #{right} WHERE price > 1"
                 ) === {500, "Schema error: Ambiguous reference to unqualified field price"}

          assert sxc_error(
                   ctx,
                   "SELECT qty FROM #{left} CROSS JOIN #{right} WHERE symbol = 'a'"
                 ) === {500, "Schema error: Ambiguous reference to unqualified field symbol"}
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
                 ) === [%{"qty" => 3, "only2" => 5}, %{"qty" => 4, "only2" => 5}]
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

          assert sxc_error(ctx, "SELECT symbol, price, count(*) AS n FROM #{m}") ===
                   {400, ungrouped.("symbol", "count(Int64(1))")}

          assert sxc_error(
                   ctx,
                   "SELECT symbol, price, qty, count(*) AS n FROM #{m} GROUP BY symbol"
                 ) === {400, ungrouped.("price", "#{m}.symbol, count(Int64(1))")}

          assert sxc_error(
                   ctx,
                   "SELECT exch, price, count(*) AS n FROM #{m} GROUP BY symbol, exch"
                 ) === {400, ungrouped.("price", "#{m}.symbol, #{m}.exch, count(Int64(1))")}

          assert sxc_error(
                   ctx,
                   "SELECT exch, count(*) AS a, sum(price) AS b, avg(qty) AS c, " <>
                     "min(price) AS d FROM #{m} GROUP BY symbol"
                 ) ===
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
                 ) ===
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
                 ) ===
                   {400,
                    ungrouped.(
                      "price",
                      ~s|date_bin(IntervalMonthDayNano("IntervalMonthDayNano { months: 0, | <>
                        ~s|days: 0, nanoseconds: 10000000000 }"),#{m}.time), count(Int64(1))|
                    )}
        end

        if unquote(profile) === :v3_core do
          test "an unknown format ends with its position in the request body", ctx do
            assert {:error, %{status: 400, body: body}} =
                     sxc_query(ctx, "SELECT 1", format: :xml)

            # The parser stops where the format's string ends in the body
            # `Client.HTTP` sends.
            request =
              InfluxElixir.Client.QueryParams.request_body(ctx.database, "SELECT 1", %{}, :xml)

            {at, length} = :binary.match(request, ~s("format":"xml"))

            assert body ===
                     "serde json error: unknown variant `xml`, expected one of `parquet`, " <>
                       "`csv`, `pretty`, `json`, `json_lines`, `jsonl` at line 1 column " <>
                       Integer.to_string(at + length)
          end
        end
      end
    end
  end

  defp null_between_tests do
    quote location: :keep do
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
            assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE #{where} ORDER BY time") ===
                     Enum.map(values, &%{"v" => &1}),
                   where
          end
        end
      end
    end
  end

  defp plan_order_tests do
    quote location: :keep do
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
            assert sxc_error(ctx, sql) === {400, error}, sql
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
            assert sxc_error(ctx, "SELECT v FROM #{m} WHERE #{where}") ===
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
            assert sxc_error(ctx, sql) === {400, prefix <> message}, sql
          end

          assert sxc_error(ctx, "SELECT -s AS a FROM #{m}") ===
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

          assert sxc_error(ctx, "SELECT abs(s) AS x FROM #{m}") ===
                   {400,
                    "Error during planning: Function 'abs' expects NativeType::Numeric but " <>
                      "received NativeType::String No function matches the given name and " <>
                      "argument types 'abs(Utf8)'. You might need to add explicit type " <>
                      "casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}

          assert sxc_rows(ctx, "SELECT abs(v) AS x FROM #{m} ORDER BY time LIMIT 1") ===
                   [%{"x" => 1}]
        end
      end
    end
  end

  defp boolean_tests(client) do
    quote location: :keep do
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
            assert sxc_error(ctx, "SELECT v FROM #{m} WHERE #{where}") === {status, body}, where
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
            assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE #{where} ORDER BY time") ===
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
            assert sxc_query(ctx, "SELECT v FROM #{m} WHERE #{where}", params: params) ===
                     {:error,
                      %{
                        status: 400,
                        body: "type_coercion\ncaused by\nError during planning: " <> message
                      }},
                   where
          end

          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE b = $p ORDER BY time",
                   params: %{p: true}
                 ) ===
                   {:ok, [%{"v" => 2}, %{"v" => 3}]}

          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE b = $p", params: %{p: nil}) ===
                   {:ok, []}
        end

        @tag local_divergence: "Local refuses a boolean written first by name"
        test "a boolean written first is the engine's or refused by name", ctx do
          m = sxc_mixed(ctx)
          sql = "SELECT v FROM #{m} WHERE true = b ORDER BY time"

          expected =
            if unquote(client) === InfluxElixir.Client.Local,
              do:
                {:error,
                 %{
                   status: 400,
                   body:
                     "Client.Local: a boolean on the left of a comparison is outside the " <>
                       "double's subset; write the column first: true = b"
                 }},
              else: {:ok, [%{"v" => 2}, %{"v" => 3}]}

          assert sxc_query(ctx, sql) === expected
        end
      end
    end
  end

  defp bounds_helpers do
    quote location: :keep do
      # Two integer rows, then one row with a float, a string and a boolean.
      defp sxc_bounds(ctx) do
        m = sxc_name("sxc_bnd")

        sxc_write(ctx, [
          "#{m} v=1i 1000000000",
          "#{m} v=2i 2000000000",
          ~s|#{m} f=1.5,s="a",b=true 3000000000|
        ])

        m
      end

      defp sxc_interval(sides, kind \\ "comparable") do
        "Internal error: Only intervals with the same data type are #{kind}, #{sides}.\n" <>
          "This issue was likely caused by a bug in DataFusion's code. Please help us to " <>
          "resolve this by filing a bug report in our issue tracker: " <>
          "https://github.com/apache/datafusion/issues"
      end
    end
  end

  defp bounds_error_tests do
    quote location: :keep do
      describe "SQL executor — contract: the interval error of an empty numeric range" do
        test "an empty interval on an integer column is the engine's internal error", ctx do
          m = sxc_bounds(ctx)
          failure = {500, sxc_interval("lhs:Null, rhs:Int64")}

          for where <- [
                "v > 1 AND v < 1",
                "v >= 2 AND v <= 1",
                "v > 1 AND v <= 1",
                "v >= 1 AND v < 1",
                "v > 1 AND v < 2",
                "v > 5 AND v < 1",
                "v BETWEEN 2 AND 1",
                "v > 1 AND 1 > v",
                "5 < v AND 1 > v",
                "NOT (v <= 1) AND v < 1",
                "(v > 1 AND v < 1)",
                "v > 9223372036854775807 AND v < 5",
                "v > -1 AND v < -5"
              ] do
            assert sxc_error(ctx, "SELECT * FROM #{m} WHERE #{where}") === failure, where
          end

          for sql <- [
                "SELECT count(*) AS n FROM #{m} WHERE v > 1 AND v < 1",
                "SELECT v FROM #{m} WHERE v > 1 AND v < 1 ORDER BY v LIMIT 1 OFFSET 1",
                "SELECT DISTINCT v FROM #{m} WHERE v > 1 AND v < 1",
                "SELECT v + 1 AS w FROM #{m} WHERE v > 1 AND v < 1"
              ] do
            assert sxc_error(ctx, sql) === failure, sql
          end
        end

        # An unsigned field: the error names UInt64, `u < 0` is empty by
        # itself, and a negative literal keeps the engine from failing.
        test "an empty interval on an unsigned column names UInt64", ctx do
          m = sxc_name("sxc_uint")
          sxc_write(ctx, ["#{m} u=5u 1000000000"])

          assert sxc_error(ctx, "SELECT u FROM #{m} WHERE u > 5 AND u < 1") ===
                   {500, sxc_interval("lhs:Null, rhs:UInt64")}

          assert sxc_error(ctx, "SELECT u FROM #{m} WHERE u < 0") ===
                   {500, sxc_interval("lhs:UInt64, rhs:Null")}

          assert sxc_rows(ctx, "SELECT u FROM #{m} WHERE u > -1 AND u < 1") === []
        end

        test "the first comparison written sets which side of the error is null", ctx do
          m = sxc_bounds(ctx)
          lower = {500, sxc_interval("lhs:Null, rhs:Int64")}
          upper = {500, sxc_interval("lhs:Int64, rhs:Null")}
          equal = {500, sxc_interval("lhs:Null, rhs:Int64", "intersectable")}

          for {where, failure} <- [
                {"v > 5 AND v < 1", lower},
                {"v >= 5 AND v <= 1", lower},
                {"v < 1 AND v > 5", upper},
                {"v <= 1 AND v >= 5", upper},
                {"1 > v AND v > 5", upper},
                {"v > 5 AND 1 > v", lower},
                {"v = 5 AND v < 1", equal},
                {"v IN (5) AND v < 1", equal},
                {"v = 1 AND v > 1", equal},
                {"v < 1 AND v = 5", upper},
                {"v > 7 AND v = 5", lower},
                {"v < 1 AND v > 5 AND v = 4", upper},
                {"v = 4 AND v < 1 AND v > 5", equal}
              ] do
            assert sxc_error(ctx, "SELECT * FROM #{m} WHERE #{where}") === failure, where
          end
        end

        test "the first comparison written sets the type, whatever column is empty", ctx do
          m = sxc_bounds(ctx)
          float = fn sides, kind -> {500, sxc_interval(sides, kind)} end

          for {where, failure} <- [
                {"f > 2.0 AND f < 1.0", float.("lhs:Null, rhs:Float64", "comparable")},
                {"f > 2 AND f < 1", float.("lhs:Null, rhs:Float64", "comparable")},
                {"f < 1 AND f > 2", float.("lhs:Float64, rhs:Null", "comparable")},
                {"f = 5 AND f < 1", float.("lhs:Null, rhs:Float64", "intersectable")},
                {"f BETWEEN 2 AND 1", float.("lhs:Null, rhs:Float64", "comparable")},
                {"f > 1.5 AND f < 1.5", float.("lhs:Null, rhs:Float64", "comparable")},
                {"f > 1.5 AND f <= 1.5", float.("lhs:Null, rhs:Float64", "comparable")},
                {"f > 1.0 AND f < 1.0000000000000002",
                 float.("lhs:Null, rhs:Float64", "comparable")},
                {"v > 1 AND v < 1 AND f = 1", {500, sxc_interval("lhs:Null, rhs:Int64")}},
                {"f = 1 AND v > 1 AND v < 1", float.("lhs:Null, rhs:Float64", "intersectable")},
                {"f > 0 AND v > 5 AND v < 1", float.("lhs:Null, rhs:Float64", "comparable")},
                {"v < 1 AND f < 9 AND v > 5", {500, sxc_interval("lhs:Int64, rhs:Null")}},
                {"f < 1 AND f > 5 AND v < 1 AND v > 5",
                 float.("lhs:Float64, rhs:Null", "comparable")}
              ] do
            assert sxc_error(ctx, "SELECT * FROM #{m} WHERE #{where}") === failure, where
          end
        end

        test "an integer column compared with float literals is cast and sits out", ctx do
          m = sxc_bounds(ctx)
          failure = {500, sxc_interval("lhs:Null, rhs:Float64")}

          for where <- [
                "v > 1.5 AND f > 2 AND f < 1",
                "v >= 1.0 AND f > 2 AND f < 1",
                "v BETWEEN 1.5 AND 3 AND f > 2 AND f < 1"
              ] do
            assert sxc_error(ctx, "SELECT * FROM #{m} WHERE #{where}") === failure, where
          end

          for where <- ["v > 1.5 AND v < 1.7", "v > 2.0 AND v < 1.0", "v = 1.5 AND f = 2"] do
            assert sxc_rows(ctx, "SELECT * FROM #{m} WHERE #{where}") === [], where
          end

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE v > 2.0 AND v < 1.0 AND f = 1") ===
                   {500, sxc_interval("lhs:Null, rhs:Float64", "intersectable")}

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE v > 2.0 AND v < 1.0 AND v < 5") ===
                   {500, sxc_interval("lhs:Int64, rhs:Null")}
        end
      end
    end
  end

  defp bounds_answer_tests do
    quote location: :keep do
      describe "SQL executor — contract: what a numeric range still answers" do
        test "a range that holds a value, or an end of the type's range, answers", ctx do
          m = sxc_bounds(ctx)
          one = [%{"v" => 1}]

          for {where, rows} <- [
                {"v >= 1 AND v <= 1", one},
                {"v > 0 AND v < 2", one},
                {"v = 1 AND v < 5", one},
                {"v > 1 AND v < 3", [%{"v" => 2}]},
                {"v > 9223372036854775807", []},
                {"v < -9223372036854775808", []},
                {"v > 1.5", [%{"v" => 2}]},
                {"f > 1.5 AND f < 1.6", []},
                {"f >= 1.0 AND f <= 1.0", []}
              ] do
            assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE #{where} ORDER BY time") === rows,
                   where
          end

          assert sxc_rows(ctx, "SELECT f FROM #{m} WHERE f >= 1.5 AND f <= 1.5") ===
                   [%{"f" => 1.5}]
        end

        test "two different equalities, or a condition the analysis cannot take, answer", ctx do
          m = sxc_bounds(ctx)

          for where <- [
                "v = 1 AND v = 2",
                "v = 4 AND v = 7 AND v < 3",
                "v > 1 AND v < 1 AND v != 5",
                "v > 1 AND v < 1 AND v NOT IN (3)",
                "v > 1 AND v < 1 AND v IN (1, 2)",
                "v > 1 AND v < 1 AND v NOT BETWEEN 0 AND 9",
                "v > 1 AND v < 1 AND v IS NULL",
                "v > 1 AND v < 1 AND v IS NOT NULL",
                "v > 1 AND v < 1 AND f IS NOT NULL",
                "v > 1 AND v < 1 AND s = 'a'",
                "v > 1 AND v < 1 AND s > 'a'",
                "v > 1 AND v < 1 AND b",
                "v > 1 AND v < 1 AND NOT b",
                "v > 1 AND v < 1 AND time > '2000-01-01T00:00:00Z'",
                "v > 1 AND v < 1 AND time = '1970-01-01T00:00:01Z'",
                "v > 1 AND v < 1 AND (v > 1 OR v < 1)",
                "v > 1 AND v < 1 AND NOT (v = 3 AND v = 4)",
                "v > 1 AND v < 1 AND v > NULL",
                "v > NULL AND v < 1",
                "v > '5' AND v < 1",
                "v NOT BETWEEN 1 AND 3 AND v > 5",
                "s > 'b' AND s < 'a'",
                "v + 1 > 2 AND v + 1 < 2",
                "cast(v AS DOUBLE) > 1 AND cast(v AS DOUBLE) < 1",
                "v > 1 AND v < 1 AND false"
              ] do
            assert sxc_rows(ctx, "SELECT * FROM #{m} WHERE #{where}") === [], where
          end

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v > 1 AND v < 1 OR v = 2") ===
                   [%{"v" => 2}]

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v > 1 AND v < 1 LIMIT 0") === []
        end

        test "a parameter bounds as a literal does", ctx do
          m = sxc_bounds(ctx)
          failure = {:error, %{status: 500, body: sxc_interval("lhs:Null, rhs:Int64")}}

          for params <- [%{a: 5, b: 1}, %{a: 5, b: -1}, %{a: -1, b: -5}] do
            assert sxc_query(ctx, "SELECT * FROM #{m} WHERE v > $a AND v < $b", params: params) ===
                     failure,
                   inspect(params)
          end

          assert sxc_query(ctx, "SELECT * FROM #{m} WHERE v > $a AND v < $a", params: %{a: 1}) ===
                   failure

          assert sxc_query(ctx, "SELECT * FROM #{m} WHERE v > $a AND v < $b",
                   params: %{a: nil, b: 1}
                 ) === {:ok, []}
        end
      end
    end
  end

  defp bounds_order_tests(client) do
    quote location: :keep do
      describe "SQL executor — contract: the interval error among the others" do
        test "the planner's errors come before the interval's", ctx do
          m = sxc_bounds(ctx)
          schema = "Schema error: No field named nope. Valid fields are "

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE nope > 1 AND nope < 1") ===
                   {500, schema <> "#{m}.b, #{m}.f, #{m}.s, #{m}.time, #{m}.v."}

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE v > 1 AND v < 1 AND nope = 1") ===
                   {500, schema <> "#{m}.b, #{m}.f, #{m}.s, #{m}.time, #{m}.v."}

          assert sxc_error(
                   ctx,
                   "SELECT * FROM #{m} WHERE time > '2100-01-01T00:00:00Z' AND " <>
                     "time < '2000-01-01T00:00:00Z' AND v > 1 AND v < 1"
                 ) ===
                   {500,
                    "External error: unexpected: provided filters on time column did not " <>
                      "produce a valid set of boundaries"}

          assert sxc_error(ctx, "SELECT * FROM #{m} WHERE v > 1 AND v < 1 LIMIT -1") ===
                   {400,
                    "Optimizer rule 'eliminate_limit' failed\ncaused by\nError during " <>
                      "planning: LIMIT must be >= 0, '-1' was provided"}
        end

        test "InfluxQL answers an empty range with no rows", ctx do
          m = sxc_bounds(ctx)

          assert unquote(client).query_influxql(
                   ctx.conn,
                   "SELECT v FROM #{m} WHERE v > 1 AND v < 1",
                   database: ctx.database
                 ) === {:ok, []}
        end

        test "a CROSS JOIN's filter fails on either side's column", ctx do
          left = sxc_name("sxc_bl")
          right = sxc_name("sxc_br")
          sxc_write(ctx, ["#{left} qty=3i 1000000000", "#{right} only2=5i 1000000000"])
          failure = {500, sxc_interval("lhs:Null, rhs:Int64")}

          for where <- ["qty > 5 AND qty < 1", "only2 > 5 AND only2 < 1"] do
            assert sxc_error(
                     ctx,
                     "SELECT qty, only2 FROM #{left} CROSS JOIN #{right} WHERE #{where}"
                   ) === failure,
                   where
          end
        end

        @tag local_divergence: "Local refuses what it cannot pin down by name"
        test "a shape the double cannot pin down is the engine's or refused by name", ctx do
          m = sxc_bounds(ctx)
          local? = unquote(client) === InfluxElixir.Client.Local

          refusal = fn what ->
            {:error,
             %{
               status: 400,
               body:
                 "Client.Local: a WHERE that may leave a numeric column no value, with " <>
                   what <> ": the engine's answer is not pinned down"
             }}
          end

          cte =
            {:error,
             %{
               status: 400,
               body:
                 "Client.Local: a WHERE over a CTE that leaves a numeric column no value: " <>
                   "the engine's answer depends on where it pushes the filter"
             }}

          engine = fn sides, kind ->
            {:error, %{status: 500, body: sxc_interval(sides, kind)}}
          end

          for {sql, refused, answer} <- [
                {"WITH c AS (SELECT * FROM #{m}) SELECT * FROM c WHERE v > 1 AND v < 1", cte,
                 engine.("lhs:Null, rhs:Int64", "comparable")},
                {"SELECT * FROM #{m} WHERE v > 1 AND v < 1 AND v > 0",
                 refusal.("two bounds on one column, one implying the other"),
                 engine.("lhs:Null, rhs:Int64", "comparable")},
                {"SELECT * FROM #{m} WHERE v < 3 AND v < 9 AND v = 4",
                 refusal.("two bounds on one column, one implying the other"),
                 engine.("lhs:Null, rhs:Int64", "intersectable")},
                {"SELECT * FROM #{m} WHERE v > 1 AND v < 1.5",
                 refusal.("an integer column bounded by an integer and a float literal"),
                 {:error,
                  %{
                    status: 500,
                    body: "FilterPushdown\ncaused by\n" <> sxc_interval("lhs:Null, rhs:Int64")
                  }}},
                {"SELECT * FROM #{m} WHERE v > 1 AND v < 1 AND v + 1 > 0",
                 refusal.("an arithmetic expression compared"),
                 engine.("lhs:Null, rhs:Int64", "comparable")},
                {"SELECT * FROM #{m} WHERE v = 2 AND v IN (1, 2) AND v < 1",
                 refusal.("a predicate an equality of the same column may decide"), {:ok, []}}
              ] do
            if local?,
              do: assert(sxc_query(ctx, sql) === refused, sql),
              else: assert(sxc_query(ctx, sql) === answer, sql)
          end
        end
      end
    end
  end
end
