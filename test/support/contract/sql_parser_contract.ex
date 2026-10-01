defmodule InfluxElixir.Contract.SQLParser do
  @moduledoc """
  SQL parsing contract tests, run against `InfluxElixir.Client.Local` and
  against a real InfluxDB 3: what a query's text means (string literals,
  constant predicates, `LIKE`, `time` against a number, `LIMIT`/`OFFSET`,
  `DISTINCT`, `DATE_BIN`) and the words in which the engine refuses what it
  cannot plan.

      use InfluxElixir.Contract.SQLParser, client: InfluxElixir.Client.Local, profile: :v3_core

  The `setup` callback must return `conn`, `database` and `query_delay`, as
  for `InfluxElixir.ClientContract`. Every measurement has a unique name and
  every line a timestamp, so a server that outlives the test run does not
  mix one test's rows with another's.

  Where the double refuses by name (a `Client.Local:` 400) what the engine
  plans another way, the test says which of the two is acceptable.
  """

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)

    # SQL is the v3 profiles' query language; v2 has none of it.
    if profile in [:v3_core, :v3_enterprise] do
      sql_parser_tests(client)
    end
  end

  defp sql_parser_tests(client) do
    quote do
      unquote(helpers(client))
      unquote(literal_tests(client))
      unquote(constant_tests(client))
      unquote(time_number_tests(client))
      unquote(time_aggregate_tests(client))
      unquote(limit_tests(client))
      unquote(function_tests(client))
      unquote(date_bin_tests(client))
    end
  end

  defp helpers(client) do
    quote do
      # Nanoseconds for second `n` after 2023-11-14T22:13:20Z.
      defp sp_ns(n), do: (1_700_000_000 + n) * 1_000_000_000

      defp sp_measurement(prefix),
        do: "#{prefix}_#{100_000_000 + System.unique_integer([:positive])}"

      defp sp_write(ctx, lines) do
        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, Enum.join(lines, "\n"), database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)
      end

      defp sp_query(ctx, sql, params \\ nil) do
        opts = [database: ctx.database]
        opts = if params, do: Keyword.put(opts, :params, params), else: opts
        unquote(client).query_sql(ctx.conn, sql, opts)
      end

      defp sp_local?, do: unquote(client) == InfluxElixir.Client.Local

      defp sp_coercion(message),
        do: "type_coercion\ncaused by\nError during planning: " <> message
    end
  end

  defp literal_tests(client) do
    quote do
      describe "SQL parsing — contract: string literals" do
        test "a doubled quote is one quote; a bound string is data, never SQL", ctx do
          m = sp_measurement("sp_quote")

          sp_write(ctx, [
            "#{m},name=O'Brien v=1 #{sp_ns(0)}",
            "#{m},name=Doe v=2 #{sp_ns(1)}",
            "#{m},name=q v=4 #{sp_ns(2)}"
          ])

          obrien = {:ok, [%{"name" => "O'Brien"}]}

          assert obrien == sp_query(ctx, "SELECT name FROM #{m} WHERE name = 'O''Brien'")
          assert obrien == sp_query(ctx, "SELECT name FROM #{m} WHERE name LIKE 'O''B%'")

          assert obrien ==
                   sp_query(ctx, "SELECT name FROM #{m} WHERE name = $n", %{n: "O'Brien"})

          hostile = "zzz' OR v > 0 OR name = 'q"

          assert {:ok, []} ==
                   sp_query(ctx, "SELECT name FROM #{m} WHERE name = $n", %{n: hostile})
        end

        test "SQL syntax inside a literal is text", ctx do
          m = sp_measurement("sp_syntax")

          sp_write(ctx, [
            ~s|#{m},city=Smith\\,\\ John v=1,s="a>b" #{sp_ns(0)}|,
            ~s|#{m},city=Doe v=2,s="note limit 5" #{sp_ns(1)}|
          ])

          assert {:ok, [%{"city" => "Smith, John"}, %{"city" => "Doe"}]} =
                   sp_query(
                     ctx,
                     "SELECT city FROM #{m} WHERE city IN ('Smith, John', 'Doe') ORDER BY time"
                   )

          assert {:ok, [%{"s" => "a>b"}]} = sp_query(ctx, "SELECT s FROM #{m} WHERE s = 'a>b'")

          assert {:ok, [%{"s" => "note limit 5"}]} =
                   sp_query(ctx, "SELECT s FROM #{m} WHERE s = 'note limit 5'")

          assert {:ok, [%{"x" => "a,b"}]} = sp_query(ctx, "SELECT 'a,b' AS x FROM #{m} LIMIT 1")
        end

        test "LIKE counts characters, not bytes", ctx do
          m = sp_measurement("sp_unicode")

          sp_write(ctx, [
            ~s|#{m},k=a s="café" #{sp_ns(0)}|,
            ~s|#{m},k=b s="Éa" #{sp_ns(1)}|
          ])

          assert {:ok, [%{"s" => "café"}]} =
                   sp_query(ctx, "SELECT s FROM #{m} WHERE s LIKE 'caf_'")

          assert {:ok, [%{"s" => "Éa"}]} =
                   sp_query(ctx, "SELECT s FROM #{m} WHERE s ILIKE 'éa'")
        end
      end
    end
  end

  defp constant_tests(client) do
    quote do
      describe "SQL parsing — contract: constant predicates" do
        test "a comparison of literals, TRUE and FALSE", ctx do
          m = sp_measurement("sp_const")

          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}", "#{m} v=2 #{sp_ns(1)}"])

          all = {:ok, [%{"v" => 1.0}, %{"v" => 2.0}]}

          for where <- ["1 = 1", "true", "'a' = 'a'", "1 < 2.5", "NOT false"] do
            assert all == sp_query(ctx, "SELECT v FROM #{m} WHERE #{where} ORDER BY time"),
                   where
          end

          for where <- ["false", "1 = 2", "NOT true", "'a' > 'b'"] do
            assert {:ok, []} == sp_query(ctx, "SELECT v FROM #{m} WHERE #{where}"), where
          end
        end

        test "a lone number is not a boolean", ctx do
          m = sp_measurement("sp_nonbool")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          assert {:error,
                  %{
                    status: 400,
                    body:
                      "Error during planning: Cannot create filter with non-boolean " <>
                        "predicate 'Int64(1)' returning Int64"
                  }} = sp_query(ctx, "SELECT v FROM #{m} WHERE 1")
        end
      end
    end
  end

  defp time_number_tests(client) do
    quote do
      describe "SQL parsing — contract: a number against time" do
        test "is a planning error naming the operator and the type", ctx do
          m = sp_measurement("sp_timenum")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          for {where, pair} <- [
                {"time > 5", "Timestamp(ns) > Int64"},
                {"time >= -5", "Timestamp(ns) >= Int64"},
                {"time = 5", "Timestamp(ns) = Int64"},
                {"time <> 5", "Timestamp(ns) != Int64"},
                {"time < 1.5", "Timestamp(ns) < Float64"},
                {"5 < time", "Int64 < Timestamp(ns)"}
              ] do
            expected =
              sp_coercion("Cannot infer common argument type for comparison operation " <> pair)

            assert {:error, %{status: 400, body: ^expected}} =
                     sp_query(ctx, "SELECT v FROM #{m} WHERE #{where}"),
                   where
          end
        end

        test "a parameter is UInt64 when it is not negative", ctx do
          m = sp_measurement("sp_timeparam")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          for {sql, value, pair} <- [
                {"time > $t", 5, "Timestamp(ns) > UInt64"},
                {"time < $t", 5, "Timestamp(ns) < UInt64"},
                {"$t < time", 5, "UInt64 < Timestamp(ns)"},
                {"time > $t", -5, "Timestamp(ns) > Int64"}
              ] do
            expected =
              sp_coercion("Cannot infer common argument type for comparison operation " <> pair)

            assert {:error, %{status: 400, body: ^expected}} =
                     sp_query(ctx, "SELECT v FROM #{m} WHERE #{sql}", %{t: value}),
                   sql
          end
        end

        test "IN lists the types; BETWEEN is the engine's internal error", ctx do
          m = sp_measurement("sp_timein")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          expected =
            sp_coercion(
              "Can not find compatible types to compare Timestamp(ns) with [Int64, Utf8]"
            )

          assert {:error, %{status: 400, body: ^expected}} =
                   sp_query(ctx, "SELECT v FROM #{m} WHERE time IN (1, 'a')")

          assert {:error, %{status: 500, body: body}} =
                   sp_query(ctx, "SELECT v FROM #{m} WHERE time BETWEEN 1 AND 2")

          assert body ==
                   "type_coercion\ncaused by\nInternal error: Failed to coerce types " <>
                     "Timestamp(ns) and Int64 in BETWEEN expression.\nThis issue was likely " <>
                     "caused by a bug in DataFusion's code. Please help us to resolve this " <>
                     "by filing a bug report in our issue tracker: " <>
                     "https://github.com/apache/datafusion/issues"
        end
      end
    end
  end

  defp time_aggregate_tests(client) do
    quote do
      describe "SQL parsing — contract: aggregates over time" do
        test "AVG and SUM fail planning in their own words", ctx do
          m = sp_measurement("sp_timeagg")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          assert {:error, %{status: 400, body: avg}} =
                   sp_query(ctx, "SELECT AVG(time) AS a FROM #{m}")

          assert avg ==
                   "Error during planning: Execution error: Function 'avg' user-defined " <>
                     "coercion failed with \"Error during planning: Avg does not support " <>
                     "inputs of type Timestamp(ns).\" No function matches the given name and " <>
                     "argument types 'avg(Timestamp(ns))'. You might need to add explicit " <>
                     "type casts.\n\tCandidate functions:\n\tavg(UserDefined)"

          assert {:error, %{status: 400, body: sum}} =
                   sp_query(ctx, "SELECT SUM(time) AS a FROM #{m}")

          assert sum ==
                   "Error during planning: Execution error: Function 'sum' user-defined " <>
                     "coercion failed with \"Execution error: Sum not supported for " <>
                     "Timestamp(ns)\" No function matches the given name and argument types " <>
                     "'sum(Timestamp(ns))'. You might need to add explicit type casts.\n" <>
                     "\tCandidate functions:\n\tsum(UserDefined)"
        end

        test "the statistics share a wording and name themselves canonically", ctx do
          m = sp_measurement("sp_timestat")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          for {call, name} <- [
                {"median", "median"},
                {"stddev_samp", "stddev"},
                {"stddev_pop", "stddev_pop"},
                {"var_samp", "var"},
                {"var_pop", "var_pop"}
              ] do
            expected =
              "Error during planning: Function '#{name}' expects NativeType::Numeric but " <>
                "received NativeType::Timestamp(Nanosecond, None) No function matches the " <>
                "given name and argument types '#{name}(Timestamp(ns))'. You might need to " <>
                "add explicit type casts.\n\tCandidate functions:\n\t#{name}(Numeric(1))"

            assert {:error, %{status: 400, body: ^expected}} =
                     sp_query(ctx, "SELECT #{call}(time) AS a FROM #{m}"),
                   call
          end
        end
      end
    end
  end

  defp limit_tests(client) do
    quote do
      describe "SQL parsing — contract: DISTINCT, LIMIT and OFFSET" do
        test "DISTINCT over no columns is one empty row", ctx do
          m = sp_measurement("sp_distinct")
          sp_write(ctx, ["#{m} price=1.5 #{sp_ns(0)}", "#{m} price=2.5 #{sp_ns(1)}"])

          assert {:ok, [%{}]} = sp_query(ctx, "SELECT DISTINCT FROM #{m}")
          assert {:ok, []} = sp_query(ctx, "SELECT DISTINCT FROM #{m} WHERE price > 100")
        end

        test "DISTINCT cannot ORDER BY a column it does not select", ctx do
          m = sp_measurement("sp_distinct_order")
          sp_write(ctx, ["#{m},k=a v=1,price=2.5 #{sp_ns(0)}"])

          expected =
            "Error during planning: For SELECT DISTINCT, ORDER BY expressions " <>
              "#{m}.price must appear in select list"

          assert {:error, %{status: 400, body: ^expected}} =
                   sp_query(ctx, "SELECT DISTINCT v FROM #{m} ORDER BY price")
        end

        test "a negative LIMIT or OFFSET fails in the optimizer", ctx do
          m = sp_measurement("sp_limit")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}", "#{m} v=2 #{sp_ns(1)}"])

          for {tail, rule, message} <- [
                {"LIMIT -1", "eliminate_limit", "LIMIT must be >= 0, '-1' was provided"},
                {"OFFSET -1", "eliminate_limit", "OFFSET must be >=0, '-1' was provided"},
                {"LIMIT 1 OFFSET -1", "push_down_limit", "OFFSET must be >=0, '-1' was provided"},
                {"LIMIT -1 OFFSET 1", "eliminate_limit", "LIMIT must be >= 0, '-1' was provided"}
              ] do
            expected =
              "Optimizer rule '#{rule}' failed\ncaused by\nError during planning: #{message}"

            assert {:error, %{status: 400, body: ^expected}} =
                     sp_query(ctx, "SELECT v FROM #{m} #{tail}"),
                   tail
          end
        end

        test "a name is a schema error, a fraction a type error, NULL no limit", ctx do
          m = sp_measurement("sp_limit_kind")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}", "#{m} v=2 #{sp_ns(1)}"])

          assert {:error, %{status: 500, body: "Schema error: No field named abc."}} =
                   sp_query(ctx, "SELECT v FROM #{m} LIMIT abc")

          expected = sp_coercion("Expected LIMIT to be an integer or null, but got Float64")

          assert {:error, %{status: 400, body: ^expected}} =
                   sp_query(ctx, "SELECT v FROM #{m} LIMIT 1.5")

          expected = sp_coercion("Expected OFFSET to be an integer or null, but got Float64")

          assert {:error, %{status: 400, body: ^expected}} =
                   sp_query(ctx, "SELECT v FROM #{m} LIMIT 1 OFFSET 1.5")

          assert {:ok, [%{"v" => 1.0}, %{"v" => 2.0}]} =
                   sp_query(ctx, "SELECT v FROM #{m} ORDER BY time LIMIT NULL")
        end
      end
    end
  end

  defp function_tests(client) do
    quote do
      describe "SQL parsing — contract: functions" do
        test "FIRST and LAST are not SQL functions", ctx do
          m = sp_measurement("sp_first")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          for name <- ["first", "last"] do
            prefix = "Error during planning: Invalid function '#{name}'.\nDid you mean '"

            assert {:error, %{status: 400, body: body}} =
                     sp_query(ctx, "SELECT #{name}(v) AS a FROM #{m}")

            # The engine's suggestion varies from run to run.
            assert String.starts_with?(body, prefix), body
            tail = String.replace_prefix(body, prefix, "")
            assert tail =~ ~r/\A[a-z_0-9]+'\?\z/, body
          end
        end

        test "round to a scale outside a double is null on the engine", ctx do
          m = sp_measurement("sp_round")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          for scale <- [400, -400] do
            result = sp_query(ctx, "SELECT round(v, #{scale}) AS r FROM #{m}")

            if sp_local?() do
              # A row cannot say "null, not missing", so the double refuses by name.
              assert {:error, %{status: 400, body: "Client.Local: round(x, " <> _rest}} = result
            else
              assert {:ok, [%{"r" => nil}]} = result
            end
          end

          assert {:ok, [%{"r" => 1200.0}]} =
                   sp_query(ctx, "SELECT round(1234.5678, -2) AS r FROM #{m}")
        end
      end
    end
  end

  defp date_bin_tests(client) do
    quote do
      describe "SQL parsing — contract: DATE_BIN" do
        test "an interval is compared by value, not by spelling", ctx do
          m = sp_measurement("sp_datebin")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}", "#{m} v=3 #{sp_ns(10)}"])

          assert {:ok, [%{"t" => %DateTime{} = t, "m" => 3.0}]} =
                   sp_query(
                     ctx,
                     "SELECT DATE_BIN(INTERVAL '60 seconds', time) AS t, MAX(v) AS m " <>
                       "FROM #{m} GROUP BY DATE_BIN(INTERVAL '1 minute', time)"
                   )

          assert t == ~U[2023-11-14 22:13:00.000000Z]
        end

        test "a select-list bucket needs the GROUP BY's", ctx do
          m = sp_measurement("sp_datebin_group")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          for sql <- [
                "SELECT DATE_BIN(INTERVAL '1 second', time) AS t, MAX(v) AS m FROM #{m}",
                "SELECT DATE_BIN(INTERVAL '1 second', time) AS t, MAX(v) AS m FROM #{m} " <>
                  "GROUP BY DATE_BIN(INTERVAL '2 second', time)"
              ] do
            assert {:error, %{status: 400, body: body}} = sp_query(ctx, sql)

            if sp_local?() do
              assert String.starts_with?(body, "Client.Local: "), body
            else
              assert String.starts_with?(
                       body,
                       "Error during planning: Column in SELECT must be in GROUP BY or an " <>
                         "aggregate function: "
                     ),
                     body
            end
          end
        end
      end
    end
  end
end
