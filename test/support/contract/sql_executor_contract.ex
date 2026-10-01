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
      unquote(planning_tests(client))
      unquote(result_tests(client))
      unquote(wording_tests(client, profile))
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

  defp planning_tests(client) do
    quote do
      describe "SQL executor — contract: nulls and planning" do
        test "a null in an IN list makes a miss unknown", ctx do
          m = sxc_mixed(ctx)

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v NOT IN (1, NULL)") == []
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v IN (1, NULL)") == [%{"v" => 1}]
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE s IN ('a', NULL)") == [%{"v" => 2}]
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE s NOT IN ('zz', NULL)") == []
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v BETWEEN NULL AND 5") == []

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
        end
      end
    end
  end

  defp result_tests(client) do
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
        end

        test "a boolean casts to text and to numbers", ctx do
          m = sxc_mixed(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT CAST(b AS VARCHAR) AS t, CAST(b AS INTEGER) AS i FROM #{m} " <>
                     "ORDER BY time"
                 ) == [
                   %{"t" => "false", "i" => 0},
                   %{"t" => "true", "i" => 1},
                   %{"t" => "true", "i" => 1}
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
                   "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') SELECT s FROM c"
                 ) == [%{}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') " <>
                     "SELECT count(s) AS n, count(*) AS m FROM c"
                 ) == [%{"n" => 0, "m" => 1}]
        end

        test "dividing an integer by the integer zero closes the connection", ctx do
          m = sxc_mixed(ctx)

          assert sxc_query(ctx, "SELECT v / 0 AS x FROM #{m}") == @sxc_closed
          assert sxc_query(ctx, "SELECT v % 0 AS x FROM #{m}") == @sxc_closed
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

            assert sxc_query(ctx, "SELECT v / 0.0 AS x FROM #{m}") == refusal
            assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v / 0.0 > 1") == refusal
            assert sxc_query(ctx, "SELECT 1.5 % 0 AS y FROM #{m}") == refusal
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

  defp wording_tests(client, profile) do
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
            "#{m},k=f amount=1.5e-7 6000000000"
          ])

          keys = fn where ->
            ctx
            |> sxc_rows("SELECT k FROM #{m} WHERE #{where} ORDER BY time")
            |> Enum.map(& &1["k"])
          end

          assert keys.("amount = '5000.0'") == ["a"]
          assert keys.("amount >= '1000.00'") == ["a", "b", "c", "d"]
          assert keys.("amount > '2e3'") == ["a", "b"]
          assert keys.("amount = '1e16'") == ["d"]
          assert keys.("amount = '0.00001'") == ["e"]
          assert keys.("amount = '1.5e-7'") == ["f"]

          assert sxc_rows(ctx, "SELECT CAST(amount AS VARCHAR) AS x FROM #{m} ORDER BY time")
                 |> Enum.map(& &1["x"]) == [
                   "5000.0",
                   "500.0",
                   "12000.0",
                   "1e16",
                   "0.00001",
                   "1.5e-7"
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
        end

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
                   "SELECT exch, sum(price) AS a, avg(qty) AS b FROM #{m} GROUP BY symbol"
                 ) ==
                   {400,
                    ungrouped.(
                      "exch",
                      "#{m}.symbol, sum(#{m}.price), avg(#{m}.qty)"
                    )}
        end

        if unquote(profile) == :v3_core do
          test "an unknown format ends with its position in the request body", ctx do
            assert {:error, %{status: 400, body: body}} =
                     sxc_query(ctx, "SELECT 1", format: :xml)

            assert body =~ ~r/ at line 1 column \d+\z/
          end
        end
      end
    end
  end
end
