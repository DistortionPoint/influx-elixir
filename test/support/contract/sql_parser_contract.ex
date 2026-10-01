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
      unquote(literal_tests())
      unquote(constant_tests())
      unquote(time_number_tests())
      unquote(time_aggregate_tests())
      unquote(limit_tests())
      unquote(function_tests())
      unquote(date_bin_tests())
      unquote(text_tests())
      unquote(identifier_tests())
      unquote(parameter_tests())
      unquote(parameter_kind_tests())
      unquote(request_param_tests())
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

      # Rust's Debug format escapes `"` and `\` inside the message.
      defp sp_tokenizer(message, line, column) do
        debug = message |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
        ~s|SQL error: TokenizerError("#{debug} at Line: #{line}, Column: #{column}")|
      end
    end
  end

  defp literal_tests do
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

  defp constant_tests do
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

        test "a lone literal that is not a boolean is a planning error", ctx do
          m = sp_measurement("sp_nonbool")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          for {where, shown, type} <- [
                {"1", "Int64(1)", "Int64"},
                {"1.5", "Float64(1.5)", "Float64"},
                {"'a'", ~s|Utf8("a")|, "Utf8"}
              ] do
            assert sp_query(ctx, "SELECT v FROM #{m} WHERE #{where}") ==
                     {:error,
                      %{
                        status: 400,
                        body:
                          "Error during planning: Cannot create filter with non-boolean " <>
                            "predicate '#{shown}' returning #{type}"
                      }},
                   where
          end

          assert sp_query(ctx, "SELECT v FROM #{m} WHERE true AND v > 0") ==
                   {:ok, [%{"v" => 1.0}]}
        end
      end
    end
  end

  defp time_number_tests do
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
                {"time <= 1.5", "Timestamp(ns) <= Float64"},
                {"5 < time", "Int64 < Timestamp(ns)"}
              ] do
            expected =
              sp_coercion("Cannot infer common argument type for comparison operation " <> pair)

            assert sp_query(ctx, "SELECT v FROM #{m} WHERE #{where}") ==
                     {:error, %{status: 400, body: expected}},
                   where
          end

          assert sp_query(ctx, "SELECT v FROM #{m} WHERE time > '2023-11-14T22:13:19Z'") ==
                   {:ok, [%{"v" => 1.0}]}
        end

        test "a parameter is UInt64 when it is not negative, and the quoting of time is moot",
             ctx do
          m = sp_measurement("sp_timeparam")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])
          where = "SELECT v FROM #{m} WHERE "

          for {sql, value, pair} <- [
                {where <> "time > $t", 5, "Timestamp(ns) > UInt64"},
                {where <> "time < $t", 5, "Timestamp(ns) < UInt64"},
                {where <> "time = $t", 0, "Timestamp(ns) = UInt64"},
                {where <> "time != $t", 5, "Timestamp(ns) != UInt64"},
                {where <> ~s|"time" > $t|, 0, "Timestamp(ns) > UInt64"},
                {where <> "$t < time", 5, "UInt64 < Timestamp(ns)"},
                {where <> "$t < time", -5, "Int64 < Timestamp(ns)"},
                {where <> "time > $t", -5, "Timestamp(ns) > Int64"},
                {where <> "time > $t", 1.5, "Timestamp(ns) > Float64"},
                {where <> "time = $t", true, "Timestamp(ns) = Boolean"}
              ] do
            expected =
              sp_coercion("Cannot infer common argument type for comparison operation " <> pair)

            assert sp_query(ctx, sql, %{t: value}) ==
                     {:error, %{status: 400, body: expected}},
                   sql
          end
        end

        test "a comparison in the select list is the same error, or refused by name", ctx do
          m = sp_measurement("sp_timeselect")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          expected =
            if sp_local?(),
              do: "Client.Local: unsupported column: time > $t as x",
              else:
                sp_coercion(
                  "Cannot infer common argument type for comparison operation " <>
                    "Timestamp(ns) > UInt64"
                )

          assert sp_query(ctx, "select time > $t as x from #{m}", %{t: 0}) ==
                   {:error, %{status: 400, body: expected}}
        end

        test "IN lists the types; BETWEEN is the engine's internal error", ctx do
          m = sp_measurement("sp_timein")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])
          where = "SELECT v FROM #{m} WHERE "

          between = fn type ->
            %{
              status: 500,
              body:
                "type_coercion\ncaused by\nInternal error: Failed to coerce types " <>
                  "Timestamp(ns) and #{type} in BETWEEN expression.\nThis issue was likely " <>
                  "caused by a bug in DataFusion's code. Please help us to resolve this " <>
                  "by filing a bug report in our issue tracker: " <>
                  "https://github.com/apache/datafusion/issues"
            }
          end

          in_list = fn types ->
            %{
              status: 400,
              body:
                sp_coercion(
                  "Can not find compatible types to compare Timestamp(ns) with [#{types}]"
                )
            }
          end

          for {sql, params, error} <- [
                {where <> "time IN (1, 'a')", nil, in_list.("Int64, Utf8")},
                {where <> "time IN ($t)", %{t: 5}, in_list.("UInt64")},
                {where <> "time IN ($a, $b)", %{a: 1, b: "x"}, in_list.("UInt64, Utf8")},
                {where <> "time BETWEEN 1 AND 2", nil, between.("Int64")},
                {where <> "time BETWEEN $a AND $b", %{a: 0, b: 5}, between.("UInt64")},
                {where <> "time BETWEEN 1 AND $b", %{b: 5}, between.("Int64")},
                {where <> "time BETWEEN $a AND 5", %{a: 1}, between.("UInt64")},
                {where <> "time BETWEEN $a AND $b", %{a: -1, b: -5}, between.("Int64")},
                {where <> "time BETWEEN '2023-11-14' AND $b", %{b: 5}, between.("UInt64")},
                {where <> "time BETWEEN $a AND 5", %{a: "2023-11-14"}, between.("Int64")}
              ] do
            assert sp_query(ctx, sql, params) == {:error, error}, sql
          end
        end

        test "a parameter that is a timestamp string is an instant", ctx do
          m = sp_measurement("sp_timestr")
          sp_write(ctx, for(i <- 0..3, do: "#{m} v=#{i}i #{sp_ns(i)}"))
          at = fn n -> "2023-11-14T22:13:#{20 + n}Z" end
          select = "SELECT v FROM #{m} WHERE "

          assert sp_query(ctx, select <> "time >= $a AND time < $b", %{a: at.(1), b: at.(3)}) ==
                   {:ok, [%{"v" => 1}, %{"v" => 2}]}

          assert sp_query(ctx, select <> "time BETWEEN $a AND $b", %{a: at.(1), b: at.(2)}) ==
                   {:ok, [%{"v" => 1}, %{"v" => 2}]}

          assert sp_query(ctx, select <> "time IN ($a, $b)", %{a: at.(1), b: at.(3)}) ==
                   {:ok, [%{"v" => 1}, %{"v" => 3}]}

          assert sp_query(ctx, select <> "$a < time", %{a: at.(2)}) == {:ok, [%{"v" => 3}]}

          # A null is no row on the engine; the double refuses it by name.
          expected =
            if sp_local?(),
              do:
                {:error,
                 %{
                   status: 400,
                   body:
                     "Client.Local: InfluxDB rejects this `time` comparand (a Timestamp " <>
                       "compares only with an ISO-8601 string or now() +/- INTERVAL 'N unit', " <>
                       "never a bare integer): NULL"
                 }},
              else: {:ok, []}

          assert sp_query(ctx, select <> "time = $a", %{a: nil}) == expected
        end
      end
    end
  end

  defp time_aggregate_tests do
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

        test "the alias is not needed; MIN, MAX and COUNT are fine", ctx do
          m = sp_measurement("sp_timealias")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          assert {:error, %{status: 400, body: body}} =
                   sp_query(ctx, "SELECT AVG(time) FROM #{m}")

          assert {:error, %{status: 400, body: ^body}} =
                   sp_query(ctx, "SELECT AVG(time) AS a FROM #{m}")

          assert sp_query(
                   ctx,
                   "SELECT MIN(time) AS lo, MAX(time) AS hi, COUNT(time) AS n FROM #{m}"
                 ) ==
                   {:ok,
                    [
                      %{
                        "lo" => ~U[2023-11-14 22:13:20.000000Z],
                        "hi" => ~U[2023-11-14 22:13:20.000000Z],
                        "n" => 1
                      }
                    ]}
        end

        test "the statistics share a wording and name themselves canonically", ctx do
          m = sp_measurement("sp_timestat")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          for {call, name} <- [
                {"median", "median"},
                {"stddev", "stddev"},
                {"stddev_samp", "stddev"},
                {"stddev_pop", "stddev_pop"},
                {"var", "var"},
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

  defp limit_tests do
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

          sp_write(ctx, ["#{m},k=a v=1,price=2.5,name=3 #{sp_ns(0)}"])

          error = fn names ->
            {:error,
             %{
               status: 400,
               body:
                 "Error during planning: For SELECT DISTINCT, ORDER BY expressions " <>
                   "#{names} must appear in select list"
             }}
          end

          # Several are listed run together, an expression as the columns it reads.
          for {sql, names} <- [
                {"SELECT DISTINCT v FROM #{m} ORDER BY price", "#{m}.price"},
                {"SELECT DISTINCT v FROM #{m} ORDER BY price, name", "#{m}.price#{m}.name"},
                {"SELECT DISTINCT v FROM #{m} ORDER BY price + 1", "#{m}.price"},
                {"SELECT DISTINCT FROM #{m} ORDER BY price", "#{m}.price"}
              ] do
            assert sp_query(ctx, sql) == error.(names), sql
          end

          assert sp_query(ctx, "SELECT DISTINCT v FROM #{m} ORDER BY v DESC") ==
                   {:ok, [%{"v" => 1.0}]}
        end

        test "a negative LIMIT or OFFSET fails in the optimizer", ctx do
          m = sp_measurement("sp_limit")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}", "#{m} v=2 #{sp_ns(1)}"])

          for {tail, rule, message} <- [
                {"LIMIT -1", "eliminate_limit", "LIMIT must be >= 0, '-1' was provided"},
                {"OFFSET -1", "eliminate_limit", "OFFSET must be >=0, '-1' was provided"},
                {"LIMIT 1 OFFSET -1", "push_down_limit", "OFFSET must be >=0, '-1' was provided"},
                {"LIMIT -1 OFFSET 1", "eliminate_limit", "LIMIT must be >= 0, '-1' was provided"},
                {"LIMIT -1 OFFSET -1", "eliminate_limit", "LIMIT must be >= 0, '-1' was provided"}
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

          for tail <- ["LIMIT abc", "LIMIT 1 OFFSET abc"] do
            assert sp_query(ctx, "SELECT v FROM #{m} #{tail}") ==
                     {:error, %{status: 500, body: "Schema error: No field named abc."}},
                   tail
          end

          expected = sp_coercion("Expected LIMIT to be an integer or null, but got Float64")

          assert {:error, %{status: 400, body: ^expected}} =
                   sp_query(ctx, "SELECT v FROM #{m} LIMIT 1.5")

          expected = sp_coercion("Expected OFFSET to be an integer or null, but got Float64")

          assert {:error, %{status: 400, body: ^expected}} =
                   sp_query(ctx, "SELECT v FROM #{m} LIMIT 1 OFFSET 1.5")

          assert sp_query(ctx, "SELECT v FROM #{m} ORDER BY time LIMIT NULL") ==
                   {:ok, [%{"v" => 1.0}, %{"v" => 2.0}]}

          assert sp_query(ctx, "SELECT v FROM #{m} ORDER BY time LIMIT NULL OFFSET NULL") ==
                   {:ok, [%{"v" => 1.0}, %{"v" => 2.0}]}
        end

        test "a column called offset is still a column", ctx do
          m = sp_measurement("sp_limit_column")

          sp_write(ctx, [
            "#{m} offset=5i,v=1i #{sp_ns(0)}",
            "#{m} offset=1i,v=2i #{sp_ns(1)}",
            "#{m} offset=9i,v=3i #{sp_ns(2)}"
          ])

          assert sp_query(ctx, "SELECT v FROM #{m} WHERE offset > 3 ORDER BY time LIMIT 2") ==
                   {:ok, [%{"v" => 1}, %{"v" => 3}]}
        end
      end
    end
  end

  defp function_tests do
    quote do
      describe "SQL parsing — contract: functions" do
        test "FIRST and LAST are not SQL functions", ctx do
          m = sp_measurement("sp_first")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          # The engine suggests a different function from run to run; the
          # double always names the same one.
          for {name, suggestion} <- [{"first", "cbrt"}, {"last", "least"}] do
            prefix = "Error during planning: Invalid function '#{name}'.\nDid you mean '"

            assert {:error, %{status: 400, body: body}} =
                     sp_query(ctx, "SELECT #{name}(v) AS a FROM #{m}")

            if sp_local?() do
              assert body == prefix <> suggestion <> "'?"
            else
              assert String.starts_with?(body, prefix), body
              assert String.replace_prefix(body, prefix, "") =~ ~r/\A[a-z_0-9]+'\?\z/, body
            end
          end
        end

        test "round to a scale outside a double is null on the engine", ctx do
          m = sp_measurement("sp_round")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          # 10^308 holds, but 2.5 * 10^308 does not.
          for {call, scale} <- [
                {"round(v, 309)", 309},
                {"round(v, 400)", 400},
                {"round(v, -309)", -309},
                {"round(v, -400)", -400},
                {"round(2.5, 308)", 308}
              ] do
            result = sp_query(ctx, "SELECT #{call} AS r FROM #{m}")

            if sp_local?() do
              # A row cannot say "null, not missing", so the double refuses by name.
              assert result ==
                       {:error,
                        %{
                          status: 400,
                          body:
                            "Client.Local: round(x, #{scale}) leaves the range of a double: " <>
                              "InfluxDB answers null (a NaN or infinity as JSON), which a " <>
                              "result row here cannot hold"
                        }}
            else
              assert result == {:ok, [%{"r" => nil}]}
            end
          end

          assert {:ok, [%{"r" => 1200.0}]} =
                   sp_query(ctx, "SELECT round(1234.5678, -2) AS r FROM #{m}")
        end

        test "round keeps what a double holds", ctx do
          m = sp_measurement("sp_round_ok")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          assert sp_query(
                   ctx,
                   "SELECT round(2.345, 2) AS a, round(-2.5) AS b, round(v, 300) AS c, " <>
                     "round(v, -308) AS d FROM #{m}"
                 ) == {:ok, [%{"a" => 2.35, "b" => -3.0, "c" => 1.0, "d" => 0.0}]}
        end
      end
    end
  end

  defp date_bin_tests do
    quote do
      describe "SQL parsing — contract: DATE_BIN" do
        test "an interval is compared by value, not by spelling", ctx do
          m = sp_measurement("sp_datebin")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}", "#{m} v=3 #{sp_ns(10)}"])

          assert sp_query(
                   ctx,
                   "SELECT DATE_BIN(INTERVAL '60 seconds', time) AS t, MAX(v) AS m " <>
                     "FROM #{m} GROUP BY DATE_BIN(INTERVAL '1 minute', time)"
                 ) == {:ok, [%{"t" => ~U[2023-11-14 22:13:00.000000Z], "m" => 3.0}]}
        end

        test "a position or an alias in GROUP BY is the select item", ctx do
          m = sp_measurement("sp_datebin_ref")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}", "#{m} v=3 #{sp_ns(10)}"])

          for group <- ["1", "t"] do
            assert sp_query(
                     ctx,
                     "SELECT DATE_BIN(INTERVAL '1 minute', time) AS t, MAX(v) AS m " <>
                       "FROM #{m} GROUP BY #{group}"
                   ) == {:ok, [%{"t" => ~U[2023-11-14 22:13:00.000000Z], "m" => 3.0}]},
                   group
          end
        end

        test "a select-list bucket needs the GROUP BY's", ctx do
          m = sp_measurement("sp_datebin_group")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          select = "SELECT DATE_BIN(INTERVAL '1 second', time) AS t, MAX(v) AS m FROM #{m}"
          other = " GROUP BY DATE_BIN(INTERVAL '2 second', time)"

          # What the double names back is the folded select list.
          local =
            "Client.Local: a DATE_BIN in the select list needs a GROUP BY DATE_BIN with the " <>
              "same interval (InfluxDB otherwise fails planning with \"Column in SELECT must " <>
              "be in GROUP BY or an aggregate function\", or answers a plain projection, " <>
              "which this double does not model): " <>
              "date_bin(interval '1 second', time) as t, max(v) as m"

          engine = fn terms ->
            "Error during planning: Column in SELECT must be in GROUP BY or an aggregate " <>
              "function: While expanding wildcard, column \"#{m}.time\" must appear in the " <>
              "GROUP BY clause or must be part of an aggregate function, currently only " <>
              "\"#{terms}\" appears in the SELECT clause satisfies this requirement"
          end

          for {sql, terms} <- [
                {select, "max(#{m}.v)"},
                {select <> other,
                 "date_bin(IntervalMonthDayNano(\"IntervalMonthDayNano { months: 0, days: 0, " <>
                   "nanoseconds: 2000000000 }\"),#{m}.time), max(#{m}.v)"}
              ] do
            body = if sp_local?(), do: local, else: engine.(terms)
            assert sp_query(ctx, sql) == {:error, %{status: 400, body: body}}
          end
        end
      end
    end
  end

  defp text_tests do
    quote do
      describe "SQL parsing — contract: comments, statements and the tokenizer" do
        test "a comment hides what is inside it; a literal hides a comment", ctx do
          m = sp_measurement("sp_comment")

          sp_write(ctx, [
            "#{m},host=a v=1 #{sp_ns(0)}",
            "#{m},host=b v=2 #{sp_ns(1)}",
            ~s|#{m},host=c s="a -- b /* c",v=3 #{sp_ns(2)}|
          ])

          for sql <- [
                "select v from #{m} /* c 'x */ where host='b'",
                "select v from #{m} -- it's a comment\nwhere host='b'",
                "select v from #{m} where host='b' -- trailing ' quote",
                "select v from #{m} /* a /* nested */ still */ where /* \"x */ host = 'b'",
                "select v from #{m} where host = /* 'a' */ 'b'",
                "select v from #{m} where host = 'b' /* ; */ ;"
              ] do
            assert sp_query(ctx, sql) == {:ok, [%{"v" => 2.0}]}, sql
          end

          assert sp_query(ctx, "select v from #{m} where s = 'a -- b /* c'") ==
                   {:ok, [%{"v" => 3.0}]}
        end

        test "a trailing semicolon ends the statement", ctx do
          m = sp_measurement("sp_semicolon")
          sp_write(ctx, ["#{m},host=a v=1 #{sp_ns(0)}", "#{m},host=b v=2 #{sp_ns(1)}"])

          for {sql, rows} <- [
                {"select v from #{m} order by time;", [%{"v" => 1.0}, %{"v" => 2.0}]},
                {"select v from #{m} where host='a';", [%{"v" => 1.0}]},
                {"select v from #{m} order by time limit 1;", [%{"v" => 1.0}]},
                {"select v from #{m} where host='b';;", [%{"v" => 2.0}]},
                {"; select v from #{m} where host='b' ; ;", [%{"v" => 2.0}]},
                {"select v from #{m} where host='b';-- done", [%{"v" => 2.0}]},
                {"select ';' as x from #{m} limit 1", [%{"x" => ";"}]}
              ] do
            assert sp_query(ctx, sql) == {:ok, rows}, sql
          end
        end

        test "a text with no statement or with two is the engine's refusal", ctx do
          m = sp_measurement("sp_statements")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          none = "Error during planning: No SQL statements were provided in the query string"

          for sql <- ["", "  ", ";", ";;", "-- only a comment", "/* c */"] do
            assert sp_query(ctx, sql) == {:error, %{status: 400, body: none}}, sql
          end

          two =
            "This feature is not implemented: " <>
              "The context currently only supports a single SQL statement"

          for sql <- ["select 1; select 2", "select 1;select v from #{m};"] do
            assert sp_query(ctx, sql) == {:error, %{status: 405, body: two}}, sql
          end
        end

        test "an unterminated string or quoted identifier names where it began", ctx do
          m = sp_measurement("sp_tokenizer")
          sp_write(ctx, ["#{m},host=a v=1 #{sp_ns(0)}"])
          head = "select * from #{m} where "
          string = "Unterminated string literal"
          identifier = ~s|Expected close delimiter '"' before EOF.|

          for {tail, message, offset} <- [
                {"host = 'a''", string, String.length("host = ")},
                {~s|"host" = 'a|, string, String.length(~s|"host" = |)},
                {~s|"host = 'a'|, identifier, 0},
                {"host = 'é' or host = 'a", string, String.length("host = 'é' or host = ")}
              ] do
            column = String.length(head) + offset + 1

            assert sp_query(ctx, head <> tail) ==
                     {:error, %{status: 400, body: sp_tokenizer(message, 1, column)}},
                   tail
          end

          assert sp_query(ctx, "select *\nfrom #{m}\nwhere host = 'a") ==
                   {:error,
                    %{
                      status: 400,
                      body: sp_tokenizer(string, 3, String.length("where host = ") + 1)
                    }}
        end

        test "an unterminated comment or dollar-quoted string ends where the text ends", ctx do
          m = sp_measurement("sp_tokenizer_end")
          sp_write(ctx, ["#{m},host=a v=1 #{sp_ns(0)}"])
          head = "select * from #{m} where host = "

          for {sql, message} <- [
                {"select * from #{m} /* open", "Unexpected EOF while in a multi-line comment"},
                {"select * from #{m} /* a /* b */",
                 "Unexpected EOF while in a multi-line comment"},
                {head <> "$$a", "Unterminated dollar-quoted string"},
                {head <> "$a$b", "Unterminated dollar-quoted, expected $"},
                {head <> "$a$b$", "Unterminated dollar-quoted, expected $"}
              ] do
            assert sp_query(ctx, sql) ==
                     {:error,
                      %{status: 400, body: sp_tokenizer(message, 1, String.length(sql) + 1)}},
                   sql
          end
        end

        test "a dollar-quoted string is a string literal", ctx do
          m = sp_measurement("sp_dollar")
          sp_write(ctx, ["#{m},host=it's v=1 #{sp_ns(0)}", "#{m},host=b v=2 #{sp_ns(1)}"])

          for {where, v} <- [
                {"host = $$b$$", 2.0},
                {"host = $tag$b$tag$", 2.0},
                {"host = $$it's$$", 1.0},
                {"host = $x$ $$ it's $$ $x$ or host = 'b'", 2.0}
              ] do
            sql = "select v from #{m} where #{where}"
            assert sp_query(ctx, sql) == {:ok, [%{"v" => v}]}, sql
          end
        end

        test "a literal that starts with a combining mark is compared whole", ctx do
          m = sp_measurement("sp_combining")
          mark = <<0x0301::utf8>>
          sp_write(ctx, ["#{m},k=#{mark}x v=1 #{sp_ns(0)}", "#{m},k=x v=2 #{sp_ns(1)}"])

          assert sp_query(ctx, "select v from #{m} where k = '#{mark}x'") ==
                   {:ok, [%{"v" => 1.0}]}

          assert sp_query(ctx, "select v from #{m} where k in ('#{mark}x', 'zz')") ==
                   {:ok, [%{"v" => 1.0}]}
        end
      end
    end
  end

  defp identifier_tests do
    quote do
      describe "SQL parsing — contract: identifiers in any script" do
        test "a quoted or bare name with accents is a column", ctx do
          m = sp_measurement("sp_unicode_id")
          sp_write(ctx, ["#{m},fé=x é=1i #{sp_ns(0)}"])

          for {sql, row} <- [
                {~s|select "fé" from #{m}|, %{"fé" => "x"}},
                {"select fé from #{m}", %{"fé" => "x"}},
                {"select Fé from #{m}", %{"fé" => "x"}},
                {"select é as é2 from #{m}", %{"é2" => 1}},
                {~s|select "é" as é from #{m}|, %{"é" => 1}},
                {~s|select count("é") as n from #{m}|, %{"n" => 1}},
                {"select count(é) as n from #{m}", %{"n" => 1}},
                {"select é + 1 as x from #{m}", %{"x" => 2}},
                {~s|select "fé" from #{m} where é = 1 order by é|, %{"fé" => "x"}},
                {"select fé from #{m} where fé = 'x'", %{"fé" => "x"}}
              ] do
            assert sp_query(ctx, sql) == {:ok, [row]}, sql
          end

          assert sp_query(ctx, ~s|select * from #{m} where "é" > 0|) ==
                   {:ok, [%{"fé" => "x", "é" => 1, "time" => ~U[2023-11-14 22:13:20.000000Z]}]}
        end

        test "only ASCII letters fold to lower case", ctx do
          m = sp_measurement("sp_unicode_fold")
          sp_write(ctx, ["#{m},fé=x v=1i #{sp_ns(0)}"])

          assert {:error, %{status: 500, body: "Schema error: No field named " <> _rest}} =
                   sp_query(ctx, "select FÉ from #{m}")
        end
      end
    end
  end

  defp parameter_tests do
    quote do
      describe "SQL parsing — contract: parameters" do
        test "a bound value is data, whatever it holds", ctx do
          m = sp_measurement("sp_param_data")

          values = [
            "it's",
            "a -- b",
            "$x",
            "/* c */",
            "; select 1",
            "x' OR 1=1 --",
            "$$ $a$ \"q\""
          ]

          sp_write(
            ctx,
            [~s|#{m} v=0i,s="plain" #{sp_ns(0)}|] ++
              for {value, i} <- Enum.with_index(values, 1) do
                escaped = String.replace(value, "\"", "\\\"")
                ~s|#{m} v=#{i}i,s="#{escaped}" #{sp_ns(i)}|
              end
          )

          for {value, i} <- Enum.with_index(values, 1) do
            assert sp_query(ctx, "select v from #{m} where s = $p", %{p: value}) ==
                     {:ok, [%{"v" => i}]},
                   value
          end

          # A placeholder inside a literal is the literal's text.
          assert sp_query(
                   ctx,
                   "select v from #{m} where s = '$x' or v = $p order by time",
                   %{p: 0}
                 ) == {:ok, [%{"v" => 0}, %{"v" => 3}]}
        end

        test "a string of 200 KB is bound as it is", ctx do
          m = sp_measurement("sp_param_big")
          big = String.duplicate("a", 200_000)
          sp_write(ctx, [~s|#{m} v=1i,s="#{big}" #{sp_ns(0)}|, ~s|#{m} v=2i,s="b" #{sp_ns(1)}|])

          assert sp_query(ctx, "select v from #{m} where s = $p", %{p: big}) ==
                   {:ok, [%{"v" => 1}]}
        end

        test "names are word characters in any script; the key is the name without the $",
             ctx do
          m = sp_measurement("sp_param_names")
          sp_write(ctx, ["#{m} v=1i #{sp_ns(0)}", "#{m} v=2i #{sp_ns(1)}"])
          rows = {:ok, [%{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where v = $é", %{"é" => 2}) == rows
          assert sp_query(ctx, "select v from #{m} where v = $1", %{"1" => 2}) == rows

          assert sp_query(ctx, "select v from #{m} where v = $a or v = $b order by time", %{
                   a: 1,
                   b: 2
                 }) == {:ok, [%{"v" => 1}, %{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where v = $ab", %{a: 1, ab: 2}) == rows

          # `$a$b` opens a dollar-quoted string, so the tokenizer refuses it.
          sql = "select v from #{m} where v = $a$b"

          assert sp_query(ctx, sql, %{a: 1, b: 2}) ==
                   {:error,
                    %{
                      status: 400,
                      body:
                        sp_tokenizer(
                          "Unterminated dollar-quoted, expected $",
                          1,
                          String.length(sql) + 1
                        )
                    }}
        end

        test "a placeholder with no value is the planner's error", ctx do
          m = sp_measurement("sp_param_unbound")
          sp_write(ctx, ["#{m} v=1i #{sp_ns(0)}"])

          unbound = fn name ->
            {:error,
             %{
               status: 400,
               body: "Error during planning: No value found for placeholder with name $#{name}"
             }}
          end

          assert sp_query(ctx, "select v from #{m} where v = $zz") == unbound.("zz")
          assert sp_query(ctx, "select v from #{m} where v = $zz", %{a: 1}) == unbound.("zz")
          assert sp_query(ctx, "select v from #{m} where v = $a", %{"$a" => 1}) == unbound.("a")
          assert sp_query(ctx, "select v from #{m} where v = $1", %{a: 1}) == unbound.("1")

          # The missing table is found first.
          missing = "#{m}_missing"

          assert sp_query(ctx, "select v from #{missing} where v = $zz") ==
                   {:error,
                    %{
                      status: 400,
                      body: "Error during planning: table 'public.iox.#{missing}' not found"
                    }}
        end
      end
    end
  end

  defp parameter_kind_tests do
    quote do
      describe "SQL parsing — contract: the types of parameters" do
        test "keyword-list, null and very large parameters", ctx do
          m = sp_measurement("sp_param_kinds")

          sp_write(ctx, [
            "#{m},host=a v=1i,f=1.5 #{sp_ns(0)}",
            "#{m},host=b v=2i,f=2.5 #{sp_ns(1)}"
          ])

          assert sp_query(ctx, "select v from #{m} where host = $host", host: "b") ==
                   {:ok, [%{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where v = $p", %{p: nil}) == {:ok, []}

          assert sp_query(ctx, "select v from #{m} where v in ($a, $b) order by time", %{
                   a: nil,
                   b: 1
                 }) == {:ok, [%{"v" => 1}]}

          assert sp_query(ctx, "select v from #{m} where f < $p order by time", %{p: 1.0e20}) ==
                   {:ok, [%{"v" => 1}, %{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where v < $p order by time", %{
                   p: 18_446_744_073_709_551_616
                 }) == {:ok, [%{"v" => 1}, %{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where v between $a and $b", %{a: nil, b: 2}) ==
                   {:ok, []}

          assert sp_query(ctx, "select v from #{m} where v between $a and $b order by time", %{
                   a: 1,
                   b: 2
                 }) == {:ok, [%{"v" => 1}, %{"v" => 2}]}
        end

        test "LIMIT and OFFSET take a parameter as they take a literal", ctx do
          m = sp_measurement("sp_param_limit")
          sp_write(ctx, for(i <- 1..3, do: "#{m} v=#{i}i #{sp_ns(i)}"))
          order = "select v from #{m} order by time"

          assert sp_query(ctx, order <> " limit $n offset $o", %{n: 2, o: 1}) ==
                   {:ok, [%{"v" => 2}, %{"v" => 3}]}

          assert sp_query(ctx, order <> " limit $n", %{n: nil}) ==
                   {:ok, [%{"v" => 1}, %{"v" => 2}, %{"v" => 3}]}

          optimizer = fn rule, message ->
            "Optimizer rule '#{rule}' failed\ncaused by\nError during planning: #{message}"
          end

          for {tail, params, body} <- [
                {" limit $n", %{n: "2"},
                 sp_coercion("Expected LIMIT to be an integer or null, but got Utf8")},
                {" limit $n", %{n: 1.5},
                 sp_coercion("Expected LIMIT to be an integer or null, but got Float64")},
                {" limit $n", %{n: true},
                 sp_coercion("Expected LIMIT to be an integer or null, but got Boolean")},
                {" offset $o", %{o: "1"},
                 sp_coercion("Expected OFFSET to be an integer or null, but got Utf8")},
                {" limit $n", %{n: -1},
                 optimizer.("eliminate_limit", "LIMIT must be >= 0, '-1' was provided")},
                {" limit 1 offset $o", %{o: -1},
                 optimizer.("push_down_limit", "OFFSET must be >=0, '-1' was provided")},
                {" limit $n offset $o", %{n: -1, o: -1},
                 optimizer.("eliminate_limit", "LIMIT must be >= 0, '-1' was provided")}
              ] do
            assert sp_query(ctx, order <> tail, params) ==
                     {:error, %{status: 400, body: body}},
                   tail
          end
        end

        test "a LIKE pattern is a string parameter", ctx do
          m = sp_measurement("sp_param_like")

          sp_write(ctx, [
            ~s|#{m} v=1i,s="apple" #{sp_ns(0)}|,
            ~s|#{m} v=2i,s="Banana" #{sp_ns(1)}|
          ])

          assert sp_query(ctx, "select v from #{m} where s like $p", %{p: "a%"}) ==
                   {:ok, [%{"v" => 1}]}

          assert sp_query(ctx, "select v from #{m} where s ilike $p", %{p: "b%"}) ==
                   {:ok, [%{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where s not like $p", %{p: "a%"}) ==
                   {:ok, [%{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where s ~ $p", %{p: "^B"}) ==
                   {:ok, [%{"v" => 2}]}

          result = sp_query(ctx, "select v from #{m} where s like $p", %{p: 5})

          # The engine words it with the column's type; the double refuses by name.
          expected =
            if sp_local?(),
              do: "Client.Local: a LIKE pattern parameter must be a string",
              else:
                sp_coercion(
                  "There isn't a common type to coerce Utf8 and UInt64 in LIKE expression"
                )

          assert result == {:error, %{status: 400, body: expected}}
        end
      end
    end
  end

  defp request_param_tests do
    quote do
      describe "SQL parsing — contract: what a parameter may be" do
        test "an object or an array is the engine's JSON error, at the byte it stops", ctx do
          m = sp_measurement("sp_param_json")
          sp_write(ctx, ["#{m} v=1i #{sp_ns(0)}"])
          sql = "select v from #{m} where v = $p"
          head = ~s|{"db":#{Jason.encode!(ctx.database)},"format":"json","params":{|

          object =
            "serde json error: JSON objects are not supported as query parameters. " <>
              "Expected null, boolean, number, or string at line 1 column "

          array =
            "serde json error: JSON arrays are not supported as query parameters. " <>
              "Expected null, boolean, number, or string. at line 1 column "

          # The last parameter is read with the brace that closes the object.
          for {params, text, read} <- [
                {%{p: %{a: 1}}, object, ~s|"p":{"a":1}|},
                {%{p: [1, 2]}, array, ~s|"p":[1,2]|},
                {%{p: []}, array, ~s|"p":[]|},
                {%{p: %{a: %{b: [1]}}}, object, ~s|"p":{"a":{"b":[1]}}|},
                {%{p: [1, %{a: 2}]}, array, ~s|"p":[1,{"a":2}]|}
              ] do
            column = byte_size(head <> read) + 1

            assert sp_query(ctx, sql, params) ==
                     {:error, %{status: 400, body: text <> Integer.to_string(column)}},
                   inspect(params)
          end

          # Another parameter follows, so its comma is not read.
          assert sp_query(ctx, sql, %{a: 1, p: [1, 2], z: 1}) ==
                   {:error,
                    %{
                      status: 400,
                      body: array <> Integer.to_string(byte_size(head <> ~s|"a":1,"p":[1,2]|))
                    }}
        end

        test "a Decimal without a number, and a value with no JSON form, are refused", ctx do
          for value <- ["NaN", "Infinity", "-Infinity"] do
            assert sp_query(ctx, "select 1", %{p: Decimal.new(value)}) ==
                     {:error, {:invalid_param, "p", :non_finite_decimal}},
                   value
          end

          assert sp_query(ctx, "select 1", %{p: {:a, :tuple}}) ==
                   {:error, {:invalid_param, "p", :unsupported_type}}

          assert sp_query(ctx, "select 1", p: self()) ==
                   {:error, {:invalid_param, "p", :unsupported_type}}
        end
      end
    end
  end
end
