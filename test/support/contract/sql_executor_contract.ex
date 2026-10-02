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
      unquote(numeric_helpers())
      unquote(planning_tests())
      unquote(null_between_tests())
      unquote(plan_order_tests())
      unquote(boolean_tests(client))
      unquote(result_tests())
      unquote(integer_tests())
      unquote(division_tests())
      unquote(infinity_tests())
      unquote(infinity_edge_tests(client))
      unquote(unsigned_tests())
      unquote(unsigned_decimal_tests())
      unquote(unsigned_function_tests())
      unquote(unsigned_cte_tests(client))
      unquote(wording_tests())
      unquote(join_tests(profile))
      unquote(qualified_join_tests(client))
      unquote(bounds_helpers())
      unquote(bounds_error_tests())
      unquote(bounds_answer_tests())
      unquote(bounds_order_tests(client))
      unquote(cast_helpers())
      unquote(cast_width_tests())
      unquote(cast_arithmetic_tests())
      unquote(cast_aggregate_tests(client))
      unquote(cast_unwrap_tests())
      unquote(cast_fold_tests(client))
      unquote(negation_overflow_tests(client))
      unquote(plan_cut_tests())
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
            if unquote(client) === InfluxElixir.Client.Local do
              {:error,
               %{
                 status: 400,
                 body:
                   "Client.Local: a boolean on the left of a comparison is outside the " <>
                     "double's subset; write the column first: true = b"
               }}
            else
              {:ok, [%{"v" => 2}, %{"v" => 3}]}
            end

          assert sxc_query(ctx, sql) === expected
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

          assert sxc_rows(ctx, "SELECT f FROM #{m} WHERE f >= 1.5 AND f <= 1.5") === [
                   %{"f" => 1.5}
                 ]
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

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v > 1 AND v < 1 OR v = 2") === [
                   %{"v" => 2}
                 ]

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
                 ) ===
                   {:ok, []}
        end
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
        "Internal error: Only intervals with the same data type are #{kind}, #{sides}.
" <>
          "This issue was likely caused by a bug in DataFusion's code. Please help us to " <>
          "resolve this by filing a bug report in our issue tracker: " <>
          "https://github.com/apache/datafusion/issues"
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

          # An expression is printed as the planner prints it.
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
                   ) ===
                     failure,
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

          engine = fn sides, kind -> {:error, %{status: 500, body: sxc_interval(sides, kind)}} end

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
            if local? do
              assert sxc_query(ctx, sql) === refused, sql
            else
              assert sxc_query(ctx, sql) === answer, sql
            end
          end
        end
      end
    end
  end

  defp division_tests do
    quote location: :keep do
      describe "SQL executor — contract: division by zero" do
        test "dividing an integer by the integer zero closes the connection", ctx do
          m = sxc_mixed(ctx)
          assert sxc_query(ctx, "SELECT v / 0 AS x FROM #{m}") === @sxc_closed
          assert sxc_query(ctx, "SELECT v % 0 AS x FROM #{m}") === @sxc_closed
          assert sxc_query(ctx, "SELECT sum(v / 0) AS x FROM #{m}") === @sxc_closed
          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v / 0 > 1") === @sxc_closed
          assert {:ok, []} = sxc_query(ctx, "SELECT v / 0 AS x FROM #{m} WHERE v > 100")
        end
      end
    end
  end

  defp helpers(client) do
    quote location: :keep do
      @sxc_closed {:error, {:connection_error, %Mint.TransportError{reason: :closed}}}
      defp sxc_name(prefix) do
        "#{prefix}_#{100_000_000 + System.unique_integer([:positive])}"
      end

      defp sxc_write(ctx, lines) do
        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, Enum.join(lines, "\n"), database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)
      end

      defp sxc_query(ctx, sql, opts \\ []) do
        unquote(client).query_sql(ctx.conn, sql, [database: ctx.database] ++ opts)
      end

      defp sxc_planning(message) do
        "Error during planning: " <> message
      end

      defp sxc_coercion(message) do
        "type_coercion\ncaused by\nError during planning: " <> message
      end

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

  defp infinity_edge_tests(client) do
    quote location: :keep do
      describe "SQL executor — contract: infinity and NaN, the edges" do
        test "a float divided by zero is infinity or NaN, null in the response", ctx do
          m = sxc_name("sxc_fz")
          sxc_write(ctx, ["#{m} v=1i 1000000000", "#{m} v=2i 2000000000"])
          nulls = %{"x" => nil, "y" => nil, "z" => nil, "w" => nil, "q" => nil}

          # A non-finite double is present as JSON null, unlike a null
          # column, which is absent from the row.
          assert sxc_rows(
                   ctx,
                   "SELECT v / 0.0 AS x, 1.5 / 0 AS y, v % 0.0 AS z, 1.5 % 0 AS w, " <>
                     "0.0 / 0.0 AS q FROM #{m}"
                 ) === [nulls, nulls]

          # An infinity is greater than a number.
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v / 0.0 > 1 ORDER BY v") === [
                   %{"v" => 1},
                   %{"v" => 2}
                 ]

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE -v / 0.0 < 1 ORDER BY v") === [
                   %{"v" => 1},
                   %{"v" => 2}
                 ]
        end

        test "floats compare as a total order: -0.0 is below 0.0", ctx do
          m = sxc_name("sxc_zero")
          sxc_write(ctx, ["#{m} f=0.0,g=5.0 1000000000"])
          assert sxc_rows(ctx, "SELECT g FROM #{m} WHERE f = -f") === []
          assert sxc_rows(ctx, "SELECT g FROM #{m} WHERE f > -f") === [%{"g" => 5.0}]
          assert sxc_rows(ctx, "SELECT g FROM #{m} WHERE -f < f") === [%{"g" => 5.0}]

          assert [row] =
                   sxc_rows(
                     ctx,
                     "SELECT min(-f) AS a, max(-f) AS b, min(f) AS c, sum(-f) AS d FROM #{m}"
                   )

          assert {sxc_negative_zero?(row["a"]), sxc_negative_zero?(row["b"])} === {true, true}
          assert {row["c"], row["d"]} === {0.0, 0.0}
          refute sxc_negative_zero?(row["d"])
        end

        # The engine's infinity and NaN show as null in a response but
        # compare as numbers; the double, which cannot hold them, refuses.
        @tag local_divergence:
               "the engine orders a NaN by its sign, which its CPU chooses; Local refuses a comparison of one by name"
        test "a comparison of a NaN is the engine's or refused by name", ctx do
          m = sxc_big(ctx)

          for sql <- [
                "SELECT k FROM #{m} WHERE f * f - f * f > 1 ORDER BY k",
                "SELECT k FROM #{m} ORDER BY f * f - f * f",
                "SELECT max(f * f - f * f) AS x FROM #{m}"
              ] do
            result = sxc_query(ctx, sql)

            if unquote(client) === InfluxElixir.Client.Local do
              assert result ===
                       {:error,
                        %{
                          status: 400,
                          body:
                            "Client.Local: a comparison or ordering of a NaN: the engine orders " <>
                              "a NaN by its sign bit, which the CPU that computed it chooses"
                        }},
                     sql
            else
              assert {:ok, _rows} = result, sql
            end
          end
        end
      end
    end
  end

  defp infinity_tests do
    quote location: :keep do
      describe "SQL executor — contract: infinity and NaN" do
        test "a float computation that overflows is a null that is there", ctx do
          m = sxc_big(ctx)
          nulls = Map.new(~w(a b c d e g h i j l), &{&1, nil})

          assert sxc_rows(
                   ctx,
                   "SELECT k, f * f AS a, -(f * f) AS b, f + f AS c, -f - f AS d, " <>
                     "f / 0.1 AS e, f * f - f * f AS g, f * f / (f * f) AS h, f * f * 0 AS i, " <>
                     "f * 1e308 * 1e308 AS j, f * f % 5 AS l FROM #{m} ORDER BY k"
                 ) === [Map.put(nulls, "k", "a"), Map.put(nulls, "k", "b")]

          assert sxc_rows(
                   ctx,
                   "SELECT 5 % (f * f) AS a, 5 / (f * f) AS b, 5.0 / (f * f) AS c, " <>
                     "0.0 / (f * f) AS d, -5.0 / 0.0 AS e FROM #{m} ORDER BY k LIMIT 1"
                 ) === [%{"a" => 5.0, "b" => 0.0, "c" => 0.0, "d" => 0.0, "e" => nil}]

          assert sxc_query(ctx, "SELECT $a * 10 AS x, f * $a AS y FROM #{m} ORDER BY k LIMIT 1",
                   params: %{a: 1.0e308}
                 ) === {:ok, [%{"x" => nil, "y" => nil}]}
        end

        test "an aggregate that overflows is null, and the count still counts", ctx do
          m = sxc_big(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT sum(f) AS a, avg(f) AS b, stddev(f) AS c, median(f) AS d, " <>
                     "var_pop(f) AS e, sum(f * 1e308) AS g, max(f * f) AS h, " <>
                     "min(-(f * f)) AS l, count(f * f) AS n FROM #{m}"
                 ) === [
                   %{
                     "a" => nil,
                     "b" => nil,
                     "c" => nil,
                     "d" => nil,
                     "e" => nil,
                     "g" => nil,
                     "h" => nil,
                     "l" => nil,
                     "n" => 2
                   }
                 ]
        end

        test "an integer aggregate wraps as its type does", ctx do
          m = sxc_big(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT sum(i) AS a, avg(i) AS b, median(i) AS c, stddev(i) AS d, " <>
                     "sum(j) AS e, sum(i * 1) AS g, sum(i + 1) AS h, sum(u) AS l FROM #{m}"
                 ) === [
                   %{
                     "a" => -2,
                     "b" => 9.223_372_036_854_776e18,
                     "c" => -1,
                     "d" => 0.0,
                     "e" => 0,
                     "g" => -2,
                     "h" => 0,
                     "l" => 12
                   }
                 ]
        end

        test "an infinity compares as a number", ctx do
          m = sxc_big(ctx)
          both = [%{"k" => "a"}, %{"k" => "b"}]

          for {where, rows} <- [
                {"f * f > 1", both},
                {"f * f = 1e400", both},
                {"-(f * f) = -1e400", both},
                {"f * f >= 1e400", both},
                {"f * f BETWEEN 1 AND 1e400", both},
                {"f * f IN (1e400)", both},
                {"-(f * f) < -1e308", both},
                {"f * f <> 1e400", []},
                {"f * f > 1e400", []},
                {"f * f > f * f", []}
              ] do
            assert sxc_rows(ctx, "SELECT k FROM #{m} WHERE #{where} ORDER BY k") === rows, where
          end

          assert sxc_rows(ctx, "SELECT min(f) AS x FROM #{m} WHERE f * f > 1e308") === [
                   %{"x" => 1.7e308}
                 ]
        end

        test "an infinity sorts beyond every finite value", ctx do
          m = sxc_name("sxc_inf_order")

          sxc_write(ctx, [
            "#{m},k=a f=1.7e308,s=1.0 1000000000",
            "#{m},k=b f=1.7e308,s=-1.0 2000000000",
            "#{m},k=c f=1.0,s=1.0 3000000000"
          ])

          assert sxc_rows(ctx, "SELECT k FROM #{m} ORDER BY f * s * 10") === [
                   %{"k" => "b"},
                   %{"k" => "c"},
                   %{"k" => "a"}
                 ]

          assert sxc_rows(ctx, "SELECT k FROM #{m} ORDER BY f * s * 10 DESC") === [
                   %{"k" => "a"},
                   %{"k" => "c"},
                   %{"k" => "b"}
                 ]

          assert sxc_rows(ctx, "SELECT k, f * s * 10 AS x FROM #{m} ORDER BY x") === [
                   %{"k" => "b", "x" => nil},
                   %{"k" => "c", "x" => 10.0},
                   %{"k" => "a", "x" => nil}
                 ]

          assert sxc_rows(ctx, "SELECT max(f * s * 10) AS hi, min(f * s * 10) AS lo FROM #{m}") ===
                   [
                     %{"hi" => nil, "lo" => nil}
                   ]
        end

        test "a function of an infinity is null, a cast of one is its text or a failure", ctx do
          m = sxc_big(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT abs(-(f * f)) AS a, round(f * f) AS b, floor(f * f) AS c, " <>
                     "ceil(-(f * f)) AS d, round(f * f, 2) AS e, trunc(f * f) AS g, " <>
                     "cast(f * f AS DOUBLE) AS h FROM #{m} ORDER BY k LIMIT 1"
                 ) === [Map.new(~w(a b c d e g h), &{&1, nil})]

          assert sxc_rows(
                   ctx,
                   "SELECT cast(f * f AS VARCHAR) AS a, cast(-(f * f) AS VARCHAR) AS b, " <>
                     "cast(f * f - f * f AS VARCHAR) AS c, cast(1e400 AS VARCHAR) AS d " <>
                     "FROM #{m} ORDER BY k LIMIT 1"
                 ) === [%{"a" => "inf", "b" => "-inf", "c" => "NaN", "d" => "inf"}]

          assert sxc_query(ctx, "SELECT cast(f * f AS INTEGER) AS a FROM #{m}") === @sxc_closed

          assert sxc_query(ctx, "SELECT cast(f * f - f * f AS INTEGER) AS a FROM #{m}") ===
                   @sxc_closed
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
                   [
                     %{"y" => 1}
                   ]
        end

        test "the minimum divided by -1 closes the connection; its remainder is 0", ctx do
          m = sxc_name("sxc_wrap_div")
          sxc_write(ctx, ["#{m} y=#{@int64_min}i 1000000000"])
          assert sxc_query(ctx, "SELECT y / -1 AS a FROM #{m}") === @sxc_closed
          assert sxc_rows(ctx, "SELECT y % -1 AS a FROM #{m}") === [%{"a" => 0}]

          assert sxc_rows(ctx, "SELECT y / 1 AS a, y / 2 AS b FROM #{m}") === [
                   %{"a" => @int64_min, "b" => -4_611_686_018_427_387_904}
                 ]
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
                 ) ===
                   {500, "Schema error: Ambiguous reference to unqualified field price"}

          assert sxc_error(ctx, "SELECT qty FROM #{left} CROSS JOIN #{right} WHERE symbol = 'a'") ===
                   {500, "Schema error: Ambiguous reference to unqualified field symbol"}
        end

        test "columns that are not shared join", ctx do
          left = sxc_name("sxc_px")
          right = sxc_name("sxc_ref")

          sxc_write(ctx, [
            "#{left},symbol=AAA price=10.5,qty=3i 1000000000",
            "#{left},symbol=BBB price=20.5,qty=4i 2000000000",
            "#{right},zz=1 only2=5i 1000000000"
          ])

          assert sxc_rows(ctx, "SELECT qty, only2 FROM #{left} CROSS JOIN #{right} ORDER BY qty") ===
                   [
                     %{"qty" => 3, "only2" => 5},
                     %{"qty" => 4, "only2" => 5}
                   ]
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
                 ) ===
                   {400, ungrouped.("price", "#{m}.symbol, count(Int64(1))")}

          assert sxc_error(
                   ctx,
                   "SELECT exch, price, count(*) AS n FROM #{m} GROUP BY symbol, exch"
                 ) ===
                   {400, ungrouped.("price", "#{m}.symbol, #{m}.exch, count(Int64(1))")}

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
            assert {:error, %{status: 400, body: body}} = sxc_query(ctx, "SELECT 1", format: :xml)

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

  defp numeric_helpers do
    quote location: :keep do
      defp sxc_negative_zero?(value) do
        is_float(value) and <<value::float>> === <<-0.0::float>>
      end

      # Two rows of the largest finite float and the extreme integers: their
      # squares overflow and their sums wrap.
      defp sxc_big(ctx) do
        m = sxc_name("sxc_big")

        sxc_write(ctx, [
          "#{m},k=a f=1.7e308,i=9223372036854775807i,j=-9223372036854775808i,u=5u 1000000000",
          "#{m},k=b f=1.7e308,i=9223372036854775807i,j=-9223372036854775808i,u=7u 2000000000"
        ])

        m
      end

      # An unsigned, a signed and a float column.
      defp sxc_unsigned(ctx) do
        m = sxc_name("sxc_u")
        sxc_write(ctx, ["#{m} u=5u,v=3i,f=2.5 1000000000", "#{m} u=7u,v=-4i,f=-1.5 2000000000"])
        m
      end

      # The largest UInt64 twice.
      defp sxc_unsigned_max(ctx) do
        m = sxc_name("sxc_umax")

        sxc_write(ctx, [
          "#{m} u=18446744073709551615u 1000000000",
          "#{m} u=18446744073709551615u 2000000000"
        ])

        m
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
          abs = "Function 'abs' expects NativeType::Numeric but received NativeType::String"

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

          assert sxc_rows(ctx, "SELECT abs(v) AS x FROM #{m} ORDER BY time LIMIT 1") === [
                   %{"x" => 1}
                 ]
        end
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

          assert sxc_rows(ctx, "SELECT min(b) AS lo, max(b) AS hi, count(b) AS n FROM #{m}") === [
                   %{"lo" => false, "hi" => true, "n" => 3}
                 ]

          assert sxc_rows(ctx, "SELECT min(s) AS lo, max(s) AS hi, count(s) AS n FROM #{m}") === [
                   %{"lo" => "a", "hi" => "b", "n" => 2}
                 ]

          assert sxc_rows(ctx, "SELECT min(k) AS lo, max(k) AS hi FROM #{m}") === [
                   %{"lo" => "a", "hi" => "c"}
                 ]
        end

        test "sum, avg and median take numbers and answer in the number's type", ctx do
          m = sxc_mixed(ctx)

          assert sxc_rows(ctx, "SELECT sum(v) AS s, avg(f) AS a, median(v) AS m FROM #{m}") === [
                   %{"s" => 6, "a" => 168.0, "m" => 2}
                 ]
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

  defp qualified_join_tests(client) do
    quote location: :keep do
      describe "SQL executor — contract: qualified columns of a CROSS JOIN" do
        @tag local_divergence:
               "the engine resolves a qualified column of a CROSS JOIN to its side; Local refuses by name"
        test "a qualified column that both sides of a CROSS JOIN have", ctx do
          m = sxc_name("sxc_qj")
          sxc_write(ctx, ["#{m} v=1i,w=10i 1000000000", "#{m} v=2i,w=20i 2000000000"])
          join = "FROM #{m} a CROSS JOIN #{m} b"

          for {sql, rows} <- [
                {"SELECT a.v #{join} ORDER BY a.v LIMIT 2", [%{"v" => 1}, %{"v" => 1}]},
                {"SELECT a.v #{join} WHERE a.v > 1", [%{"v" => 2}, %{"v" => 2}]},
                {"SELECT a.v #{join} WHERE a.v > 1 AND b.v < 1", []},
                {"SELECT a.w #{join} ORDER BY a.w LIMIT 2", [%{"w" => 10}, %{"w" => 10}]},
                {"SELECT a.v #{join} WHERE a.v = b.v ORDER BY a.v", [%{"v" => 1}, %{"v" => 2}]},
                {"SELECT a.v AS x, b.v AS y #{join} ORDER BY x, y",
                 [
                   %{"x" => 1, "y" => 1},
                   %{"x" => 1, "y" => 2},
                   %{"x" => 2, "y" => 1},
                   %{"x" => 2, "y" => 2}
                 ]}
              ] do
            result = sxc_query(ctx, sql)

            if unquote(client) === InfluxElixir.Client.Local do
              assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} = result, sql
            else
              assert result === {:ok, rows}, sql
            end
          end

          sql = "SELECT a.w #{join} WHERE zz.w > 1"
          result = sxc_query(ctx, sql)
          fields = "a.time, a.v, a.w, b.time, b.v, b.w"

          if unquote(client) === InfluxElixir.Client.Local do
            assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} = result
          else
            assert result ===
                     {:error,
                      %{
                        status: 500,
                        body: "Schema error: No field named zz.w. Valid fields are #{fields}."
                      }}
          end
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
                 |> Enum.map(& &1["x"]) ===
                   [2.5, 4.5, 503.0]
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

        test "a CTE column named time can hold text, and null columns stay in its schema", ctx do
          m = sxc_mixed(ctx)

          assert ctx
                 |> sxc_rows("WITH c AS (SELECT s AS time FROM #{m}) SELECT * FROM c")
                 |> Enum.sort_by(&Map.get(&1, "time", "~")) === [
                   %{"time" => "a"},
                   %{"time" => "b"},
                   %{}
                 ]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT s AS time FROM #{m}) SELECT time FROM c ORDER BY time"
                 ) === [%{"time" => "a"}, %{"time" => "b"}, %{}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT time, v FROM #{m}) SELECT max(time) AS t FROM c"
                 ) ===
                   [%{"t" => ~U[1970-01-01 00:00:03.000000Z]}]

          assert sxc_rows(ctx, "WITH c AS (SELECT * FROM #{m} WHERE k = 'c') SELECT s FROM c") ===
                   [%{}]

          assert sxc_error(
                   ctx,
                   "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') SELECT zz FROM c"
                 ) ===
                   {500, "Schema error: No field named zz. Valid fields are c.k, c.s."}

          assert sxc_rows(ctx, "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') SELECT s FROM c") ===
                   [
                     %{}
                   ]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') " <>
                     "SELECT count(s) AS n, count(*) AS m FROM c"
                 ) === [%{"n" => 0, "m" => 1}]
        end
      end
    end
  end

  defp unsigned_cte_tests(client) do
    quote location: :keep do
      describe "SQL executor — contract: UInt64 columns through a CTE, and what is refused" do
        test "a CTE passes the type of a UInt64 column on", ctx do
          m = sxc_unsigned(ctx)

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT u FROM #{m}) SELECT u / 2 AS h FROM c ORDER BY h"
                 ) ===
                   [%{"h" => 2.5}, %{"h" => 3.5}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT * FROM #{m}) SELECT u / 2 AS h, u + u AS w FROM c " <>
                     "ORDER BY h"
                 ) === [%{"h" => 2.5, "w" => 10}, %{"h" => 3.5, "w" => 14}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT u / 2 AS h FROM #{m}) SELECT h / 2 AS q FROM c ORDER BY q"
                 ) === [%{"q" => 1.25}, %{"q" => 1.75}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT u + 1 AS h FROM #{m}) SELECT h / 2 AS q FROM c ORDER BY q"
                 ) === [%{"q" => 3.0}, %{"q" => 4.0}]

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT sum(u) AS s FROM #{m}) SELECT s / 2 AS q FROM c"
                 ) ===
                   [%{"q" => 6.0}]

          assert sxc_rows(ctx, "WITH c AS (SELECT u FROM #{m}) SELECT u FROM c ORDER BY u DESC") ===
                   [
                     %{"u" => 7},
                     %{"u" => 5}
                   ]
        end

        @tag local_divergence:
               "the engine rescales a decimal past 38 digits and halves the places of a mean; Local refuses by name"
        test "a decimal the double does not model is the engine's or refused by name", ctx do
          big = sxc_unsigned_max(ctx)
          m = sxc_unsigned(ctx)

          for {sql, answer} <- [
                {"SELECT u * 9223372036854775807 AS a FROM #{big} LIMIT 1",
                 [%{"a" => 17_014_118_346_046_923_170_401_718_760_531_977_830}]},
                {"SELECT avg(u / 2) AS a FROM #{m}", [%{"a" => 3.0}]}
              ] do
            result = sxc_query(ctx, sql)

            if unquote(client) === InfluxElixir.Client.Local do
              assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} = result, sql
            else
              assert result === {:ok, answer}, sql
            end
          end
        end
      end
    end
  end

  defp unsigned_decimal_tests do
    quote location: :keep do
      describe "SQL executor — contract: UInt64 columns, negation and decimals" do
        test "a UInt64 cannot be negated", ctx do
          m = sxc_unsigned(ctx)

          negation =
            {400, sxc_planning("Negation only supports numeric, interval and timestamp types")}

          for sql <- [
                "SELECT -u FROM #{m}",
                "SELECT - u + 1 FROM #{m}",
                "SELECT u FROM #{m} WHERE -u < 0",
                "WITH c AS (SELECT u FROM #{m}) SELECT -u AS n FROM c"
              ] do
            assert sxc_error(ctx, sql) === negation, sql
          end

          assert sxc_rows(
                   ctx,
                   "SELECT -(-u) AS a, - - u AS b, -(-(-(-u))) AS c, -(-(-(u + 1))) AS d, " <>
                     "-(-u) + 1 AS e FROM #{m} ORDER BY time"
                 ) === [
                   %{"a" => 5, "b" => 5, "c" => 5, "d" => -6, "e" => 6},
                   %{"a" => 7, "b" => 7, "c" => 7, "d" => -8, "e" => 8}
                 ]

          assert sxc_rows(ctx, "SELECT u FROM #{m} WHERE -(-u) > 5 ORDER BY time") === [
                   %{"u" => 7}
                 ]

          assert sxc_error(ctx, "SELECT -(-(-u)) AS a FROM #{m}") === negation

          assert sxc_rows(ctx, "SELECT -(u + 1) AS a, -(u / 2) AS b FROM #{m} ORDER BY time") ===
                   [
                     %{"a" => -6, "b" => -2.5},
                     %{"a" => -8, "b" => -3.5}
                   ]
        end

        test "a decimal keeps its places through arithmetic", ctx do
          m = sxc_unsigned(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT (u / 2) / 2 AS a, ((u / 2) / 2) / 2 AS b, (u / 2) * 2 AS c, " <>
                     "(u / 2) + 1 AS d, (u / 2) % 2 AS e, 2 / (u / 2) AS f2, " <>
                     "(u / 2) * (u / 2) AS g, (u / 2) + 1.5 AS h, (u / 2) / f AS i " <>
                     "FROM #{m} ORDER BY time"
                 ) === [
                   %{
                     "a" => 1.25,
                     "b" => 0.625,
                     "c" => 5.0,
                     "d" => 3.5,
                     "e" => 0.5,
                     "f2" => 0.8,
                     "g" => 6.25,
                     "h" => 4.0,
                     "i" => 1.0
                   },
                   %{
                     "a" => 1.75,
                     "b" => 0.875,
                     "c" => 7.0,
                     "d" => 4.5,
                     "e" => 1.5,
                     "f2" => 0.5714,
                     "g" => 12.25,
                     "h" => 5.0,
                     "i" => -2.3333333333333335
                   }
                 ]
        end
      end
    end
  end

  defp unsigned_function_tests do
    quote location: :keep do
      describe "SQL executor — contract: UInt64 columns, functions and aggregates" do
        test "a function, a cast, a filter or an order over a decimal", ctx do
          m = sxc_unsigned(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT abs(u / 2) AS a, round(u / 2) AS b, floor(u / 2) AS c, " <>
                     "ceil(u / 2) AS d, abs(u) AS e, abs(u + 1) AS f, " <>
                     "cast(u / 2 AS INTEGER) AS g, cast(u / 2 AS DOUBLE) AS h, " <>
                     "cast(u / 2 AS VARCHAR) AS i, cast(u + 1 AS VARCHAR) AS j " <>
                     "FROM #{m} ORDER BY time"
                 ) === [
                   %{
                     "a" => 2.5,
                     "b" => 3.0,
                     "c" => 2.0,
                     "d" => 3.0,
                     "e" => 5,
                     "f" => 6,
                     "g" => 2,
                     "h" => 2.5,
                     "i" => "2.5000",
                     "j" => "6"
                   },
                   %{
                     "a" => 3.5,
                     "b" => 4.0,
                     "c" => 3.0,
                     "d" => 4.0,
                     "e" => 7,
                     "f" => 8,
                     "g" => 3,
                     "h" => 3.5,
                     "i" => "3.5000",
                     "j" => "8"
                   }
                 ]

          for {where, rows} <- [
                {"u / 2 > 2.6", ~c"\a"},
                {"u / 2 = 2.5", [5]},
                {"u / 2 IN (2.5, 3)", [5]},
                {"u / 2 BETWEEN 2 AND 3", [5]}
              ] do
            assert sxc_rows(ctx, "SELECT u FROM #{m} WHERE #{where} ORDER BY time") ===
                     Enum.map(rows, &%{"u" => &1}),
                   where
          end

          assert sxc_rows(ctx, "SELECT u FROM #{m} WHERE u / 2 > 2 ORDER BY u / 2 DESC") === [
                   %{"u" => 7},
                   %{"u" => 5}
                 ]
        end

        test "an aggregate of a UInt64 column is a UInt64, of a decimal a decimal", ctx do
          big = sxc_unsigned_max(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT sum(u) AS a, avg(u) AS b, median(u) AS c, stddev(u) AS d, " <>
                     "max(u) AS e, min(u) AS f FROM #{big}"
                 ) === [
                   %{
                     "a" => 18_446_744_073_709_551_614,
                     "b" => 1.8_446_744_073_709_552e19,
                     "c" => 9_223_372_036_854_775_807,
                     "d" => 0.0,
                     "e" => 18_446_744_073_709_551_615,
                     "f" => 18_446_744_073_709_551_615
                   }
                 ]

          assert sxc_rows(
                   ctx,
                   "SELECT cast(u / 3 AS DOUBLE) AS a, u / 3 AS b, cast(u / 3 AS VARCHAR) AS c " <>
                     "FROM #{big} LIMIT 1"
                 ) === [
                   %{
                     "a" => 6.148_914_691_236_518e18,
                     "b" => 6.148_914_691_236_517e18,
                     "c" => "6148914691236517205.0000"
                   }
                 ]

          assert sxc_rows(ctx, "SELECT sum(u + 0) AS a FROM #{big}") === [
                   %{"a" => 36_893_488_147_419_103_230}
                 ]

          m = sxc_unsigned(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT sum(u / 1) AS a, min(u / 2) AS b, max(u / 2) AS c, " <>
                     "median(u / 2) AS d, count(u / 2) AS e, stddev(u / 2) AS f FROM #{m}"
                 ) === [
                   %{
                     "a" => 12.0,
                     "b" => 2.5,
                     "c" => 3.5,
                     "d" => 3.0,
                     "e" => 2,
                     "f" => 0.7071067811865476
                   }
                 ]
        end
      end
    end
  end

  defp unsigned_tests do
    quote location: :keep do
      describe "SQL executor — contract: UInt64 columns" do
        test "a UInt64 divided by an Int64, or the other way, is a decimal of four places", ctx do
          m = sxc_unsigned(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT u / 2 AS a, u / v AS b, 100 / u AS c, (u + 1) / 2 AS d, " <>
                     "u / u AS e, u / f AS g, u % v AS h FROM #{m} ORDER BY time"
                 ) === [
                   %{
                     "a" => 2.5,
                     "b" => 1.6666,
                     "c" => 20.0,
                     "d" => 3.0,
                     "e" => 1,
                     "g" => 2.0,
                     "h" => 2
                   },
                   %{
                     "a" => 3.5,
                     "b" => -1.75,
                     "c" => 14.2857,
                     "d" => 4.0,
                     "e" => 1,
                     "g" => -4.666666666666667,
                     "h" => 3
                   }
                 ]

          assert sxc_query(ctx, "SELECT u / $a AS x FROM #{m} ORDER BY time", params: %{a: 3}) ===
                   {:ok, [%{"x" => 1}, %{"x" => 2}]}
        end

        test "a UInt64 with an Int64 is a decimal, with a UInt64 it wraps", ctx do
          m = sxc_unsigned(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT u + 1 AS a, u - 1 AS b, u * 2 AS c, u % 2 AS d, u + v AS e, " <>
                     "u - v AS f2, u * v AS g, u + u AS h, u * u AS i, u + f AS j, " <>
                     "100 - u AS k, u - 10 AS l FROM #{m} ORDER BY time"
                 ) === [
                   %{
                     "a" => 6,
                     "b" => 4,
                     "c" => 10,
                     "d" => 1,
                     "e" => 8,
                     "f2" => 2,
                     "g" => 15,
                     "h" => 10,
                     "i" => 25,
                     "j" => 7.5,
                     "k" => 95,
                     "l" => -5
                   },
                   %{
                     "a" => 8,
                     "b" => 6,
                     "c" => 14,
                     "d" => 1,
                     "e" => 3,
                     "f2" => 11,
                     "g" => -28,
                     "h" => 14,
                     "i" => 49,
                     "j" => 5.5,
                     "k" => 93,
                     "l" => -3
                   }
                 ]

          assert sxc_rows(
                   ctx,
                   "SELECT u + 18446744073709551615 AS a, u + 9223372036854775807 AS b, " <>
                     "u * 4611686018427387904 AS c, u - 18446744073709551615 AS d, " <>
                     "u * 18446744073709551615 AS e FROM #{m} ORDER BY time"
                 ) === [
                   %{
                     "a" => 4,
                     "b" => 9_223_372_036_854_775_812,
                     "c" => 23_058_430_092_136_939_520,
                     "d" => 6,
                     "e" => 18_446_744_073_709_551_611
                   },
                   %{
                     "a" => 6,
                     "b" => 9_223_372_036_854_775_814,
                     "c" => 32_281_802_128_991_715_328,
                     "d" => 8,
                     "e" => 18_446_744_073_709_551_609
                   }
                 ]
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

  # Four integer rows: values past the `Int32` range, at its ends, and well
  # inside it; an unsigned, a float, a string and a boolean column.
  defp cast_helpers do
    quote location: :keep do
      defp sxc_cast_data(ctx) do
        m = sxc_name("sxc_cast")

        sxc_write(ctx, [
          ~s|#{m} v=5i,big=3000000000i,neg=-3000000000i,f=2.7,u=7u,s="12",t=true 1000000000|,
          ~s|#{m} v=100000i,big=2147483648i,neg=-2147483649i,f=-2.7,u=4000000000u,s="x",t=false 2000000000|,
          ~s|#{m} v=-7i,big=2147483647i,neg=-2147483648i,f=3000000000.5,u=0u,s="-3",t=true 3000000000|,
          ~s|#{m} v=300i,big=100i,neg=-100i,f=40000.2,u=70u,s="7",t=true 4000000000|
        ])

        m
      end

      defp sxc_cast_one(ctx, m, expr, where) do
        sxc_query(ctx, "SELECT #{expr} AS c FROM #{m} WHERE #{where}")
      end

      defp sxc_vs(rows), do: Enum.map(rows, &%{"v" => &1})
    end
  end

  defp cast_width_tests do
    quote location: :keep do
      describe "SQL executor — contract: CAST to an integer width" do
        test "INTEGER and INT are Int32, SMALLINT Int16, TINYINT Int8 and BIGINT Int64", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_rows(ctx, "SELECT cast(v AS INT) AS c FROM #{m} ORDER BY time") ===
                   Enum.map([5, 100_000, -7, 300], &%{"c" => &1})

          # A value outside the target's range closes the connection.
          assert sxc_cast_one(ctx, m, "cast(big AS INT)", "v = 5") === @sxc_closed
          assert sxc_cast_one(ctx, m, "cast(big AS INTEGER)", "v = 100000") === @sxc_closed

          assert sxc_cast_one(ctx, m, "cast(big AS INT)", "v = -7") ===
                   {:ok, [%{"c" => 2_147_483_647}]}

          assert sxc_cast_one(ctx, m, "cast(neg AS INT)", "v = -7") ===
                   {:ok, [%{"c" => -2_147_483_648}]}

          assert sxc_cast_one(ctx, m, "cast(neg AS INT)", "v = 100000") === @sxc_closed
          assert sxc_cast_one(ctx, m, "cast(v AS SMALLINT)", "v = 100000") === @sxc_closed
          assert sxc_cast_one(ctx, m, "cast(v AS SMALLINT)", "v = 300") === {:ok, [%{"c" => 300}]}
          assert sxc_cast_one(ctx, m, "cast(v AS TINYINT)", "v = 300") === @sxc_closed
          assert sxc_cast_one(ctx, m, "cast(v AS TINYINT)", "v = 5") === {:ok, [%{"c" => 5}]}

          assert sxc_cast_one(ctx, m, "cast(big AS BIGINT)", "v = 5") ===
                   {:ok, [%{"c" => 3_000_000_000}]}

          assert sxc_cast_one(ctx, m, "big::INTEGER", "v = 5") === @sxc_closed
          assert sxc_cast_one(ctx, m, "cast(u AS INT)", "v = 100000") === @sxc_closed

          assert sxc_cast_one(ctx, m, "cast(u AS BIGINT)", "v = 100000") ===
                   {:ok, [%{"c" => 4_000_000_000}]}
        end

        test "a float is truncated into the range, a string must be a number in it", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_cast_one(ctx, m, "cast(f AS INT)", "v = 5") === {:ok, [%{"c" => 2}]}
          assert sxc_cast_one(ctx, m, "cast(f AS INT)", "v = 100000") === {:ok, [%{"c" => -2}]}
          assert sxc_cast_one(ctx, m, "cast(f AS INT)", "v = -7") === @sxc_closed

          assert sxc_cast_one(ctx, m, "cast(f AS BIGINT)", "v = -7") ===
                   {:ok, [%{"c" => 3_000_000_000}]}

          assert sxc_cast_one(ctx, m, "cast(f AS SMALLINT)", "v = 5") === {:ok, [%{"c" => 2}]}
          assert sxc_cast_one(ctx, m, "cast(s AS INT)", "v = 5") === {:ok, [%{"c" => 12}]}
          assert sxc_cast_one(ctx, m, "cast(s AS INT)", "v = 100000") === @sxc_closed
          assert sxc_cast_one(ctx, m, "cast(s AS BIGINT)", "v = -7") === {:ok, [%{"c" => -3}]}
          assert sxc_cast_one(ctx, m, "cast(s AS DOUBLE)", "v = 300") === {:ok, [%{"c" => 7.0}]}
          assert sxc_cast_one(ctx, m, "cast(t AS INT)", "v = 5") === {:ok, [%{"c" => 1}]}

          assert sxc_cast_one(ctx, m, "cast(t AS SMALLINT)", "v = 100000") ===
                   {:ok, [%{"c" => 0}]}
        end

        test "text that is not a whole number is no number, spaces included", ctx do
          m = sxc_name("sxc_text")

          sxc_write(ctx, [
            ~s|#{m} k=1i,s=" 7 " 1000000000|,
            ~s|#{m} k=2i,s="+7" 2000000000|,
            ~s|#{m} k=3i,s="007" 3000000000|,
            ~s|#{m} k=4i,s="7.0" 4000000000|,
            ~s|#{m} k=5i,s=".5" 5000000000|,
            ~s|#{m} k=6i,s="5." 6000000000|,
            ~s|#{m} k=7i,s="1E3" 7000000000|,
            ~s|#{m} k=8i,s="-Infinity" 8000000000|,
            ~s|#{m} k=9i,s="nan" 9000000000|,
            ~s|#{m} k=10i,s="1e400" 10000000000|,
            ~s|#{m} k=11i,s="-0" 11000000000|
          ])

          for {k, as_int, as_double} <- [
                {1, :closed, :closed},
                {2, 7, 7.0},
                {3, 7, 7.0},
                {4, :closed, 7.0},
                {5, :closed, 0.5},
                {6, :closed, 5.0},
                {7, :closed, 1000.0},
                {8, :closed, nil},
                {9, :closed, nil},
                {10, :closed, nil},
                {11, 0, -0.0}
              ] do
            for {type, expected} <- [{"BIGINT", as_int}, {"DOUBLE", as_double}] do
              expected =
                if expected == :closed, do: @sxc_closed, else: {:ok, [%{"c" => expected}]}

              assert sxc_cast_one(ctx, m, "cast(s AS #{type})", "k = #{k}") === expected,
                     "#{type} #{k}"
            end
          end
        end
      end
    end
  end

  defp cast_arithmetic_tests do
    quote location: :keep do
      describe "SQL executor — contract: arithmetic over a CAST to an integer width" do
        test "integers of one width wrap at it, with a wider type they widen", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT cast(v AS INT) * cast(v AS INT) AS p, cast(v AS INT) + cast(v AS INT) AS s " <>
                     "FROM #{m} ORDER BY time"
                 ) ===
                   [
                     %{"p" => 25, "s" => 10},
                     %{"p" => 1_410_065_408, "s" => 200_000},
                     %{"p" => 49, "s" => -14},
                     %{"p" => 90_000, "s" => 600}
                   ]

          # An Int64 (a literal, a column) widens the result.
          assert sxc_rows(
                   ctx,
                   "SELECT cast(v AS INT) * v AS a, cast(v AS INT) * 2 AS b FROM #{m} WHERE v = 100000"
                 ) === [%{"a" => 10_000_000_000, "b" => 200_000}]

          assert sxc_cast_one(ctx, m, "cast(big AS INT) * 2", "v = -7") ===
                   {:ok, [%{"c" => 4_294_967_294}]}

          # The wider of two narrow types is the result's.
          assert sxc_cast_one(ctx, m, "cast(v AS SMALLINT) * cast(v AS SMALLINT)", "v = 300") ===
                   {:ok, [%{"c" => 24_464}]}

          assert sxc_cast_one(ctx, m, "cast(v AS TINYINT) * cast(v AS SMALLINT)", "v = 300") ===
                   @sxc_closed

          assert sxc_cast_one(ctx, m, "cast(v AS SMALLINT) * cast(v AS INT)", "v = 300") ===
                   {:ok, [%{"c" => 90_000}]}

          assert sxc_rows(
                   ctx,
                   "SELECT cast(2147483647 AS INT) + cast(1 AS INT) AS a, " <>
                     "cast(32767 AS SMALLINT) + cast(1 AS SMALLINT) AS b, " <>
                     "cast(127 AS TINYINT) + cast(1 AS TINYINT) AS c, " <>
                     "cast(-2147483648 AS INT) - cast(1 AS INT) AS d, " <>
                     "cast(2147483647 AS INT) * cast(2 AS INT) AS e FROM #{m} LIMIT 1"
                 ) === [
                   %{
                     "a" => -2_147_483_648,
                     "b" => -32_768,
                     "c" => -128,
                     "d" => 2_147_483_647,
                     "e" => -2
                   }
                 ]

          # A float stays a float.
          assert sxc_cast_one(ctx, m, "cast(v AS INT) * 2.5", "v = 300") ===
                   {:ok, [%{"c" => 750.0}]}

          assert sxc_cast_one(ctx, m, "cast(v AS INT) / 7", "v = 100000") ===
                   {:ok, [%{"c" => 14_285}]}
        end

        test "division, negation and abs at the end of a narrow type", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_cast_one(ctx, m, "cast(v AS INT) / cast(0 AS INT)", "v = 5") === @sxc_closed
          assert sxc_cast_one(ctx, m, "cast(v AS INT) % cast(0 AS INT)", "v = 5") === @sxc_closed

          assert sxc_cast_one(ctx, m, "cast(neg AS INT) / cast(-1 AS INT)", "v = -7") ===
                   @sxc_closed

          assert sxc_cast_one(ctx, m, "cast(neg AS INT) % cast(-1 AS INT)", "v = -7") ===
                   {:ok, [%{"c" => 0}]}

          assert sxc_cast_one(ctx, m, "cast(neg AS INT) / 1000", "v = -7") ===
                   {:ok, [%{"c" => -2_147_483}]}

          # Over a column the minimum is its own negation; a folded constant fails.
          assert sxc_cast_one(ctx, m, "-cast(neg AS INT)", "v = -7") ===
                   {:ok, [%{"c" => -2_147_483_648}]}

          assert sxc_cast_one(ctx, m, "-cast(-2147483648 AS INT)", "v = -7") === @sxc_closed
          assert sxc_cast_one(ctx, m, "abs(cast(neg AS INT))", "v = -7") === @sxc_closed
          assert sxc_cast_one(ctx, m, "abs(cast(v AS TINYINT))", "v = 5") === {:ok, [%{"c" => 5}]}
          assert sxc_cast_one(ctx, m, "abs(cast(v AS INT))", "v = -7") === {:ok, [%{"c" => 7}]}

          assert sxc_cast_one(ctx, m, "round(2.567, cast(v AS TINYINT))", "v = 5") ===
                   {:ok, [%{"c" => 2.567}]}

          assert sxc_cast_one(ctx, m, "round(cast(v AS INT))", "v = 5") === {:ok, [%{"c" => 5.0}]}
        end
      end
    end
  end

  defp cast_aggregate_tests(client) do
    quote location: :keep do
      describe "SQL executor — contract: aggregates and names over a CAST to an integer width" do
        test "aggregates of a narrow type: a sum widens, a median wraps, the rest keep it", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT sum(cast(v AS INT) * cast(v AS INT)) AS s, min(cast(v AS INT)) AS lo, " <>
                     "max(cast(v AS INT)) AS hi, avg(cast(v AS INT)) AS a, count(cast(v AS INT)) AS n, " <>
                     "median(cast(v AS INT)) AS m FROM #{m}"
                 ) ===
                   [
                     %{
                       "s" => 1_410_155_482,
                       "lo" => -7,
                       "hi" => 100_000,
                       "a" => 25_074.5,
                       "n" => 4,
                       "m" => 152
                     }
                   ]

          assert sxc_rows(
                   ctx,
                   "SELECT sum(cast(big AS INT)) AS s, median(cast(big AS INT)) AS m FROM #{m} " <>
                     "WHERE v = -7 OR v = 300"
                 ) === [%{"s" => 2_147_483_747, "m" => -1_073_741_774}]

          assert sxc_query(ctx, "SELECT sum(cast(big AS INT)) AS s FROM #{m}") === @sxc_closed
        end

        test "an unaliased cast is named for the column it casts", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_rows(ctx, "SELECT cast(v AS SMALLINT) FROM #{m} WHERE v = 5") ===
                   [%{"#{m}.v" => 5}]

          assert sxc_rows(ctx, "SELECT cast(v AS INT) + 1 FROM #{m} WHERE v = 5") ===
                   [%{"#{m}.v + Int64(1)" => 6}]
        end

        @tag local_divergence: "Local refuses what it cannot pin down by name"
        test "a narrow integer with a UInt64, FLOAT and a timestamp are refused by name", ctx do
          m = sxc_cast_data(ctx)
          local? = unquote(client) === InfluxElixir.Client.Local

          narrow =
            {:error,
             %{
               status: 400,
               body:
                 "Client.Local: arithmetic of a narrow integer (CAST AS INT, SMALLINT or TINYINT) " <>
                   "with a UInt64 or a decimal: the engine's result type for it is not modelled"
             }}

          for {sql, engine} <- [
                {"SELECT cast(v AS INT) + u AS c FROM #{m} WHERE v = 5", {:ok, [%{"c" => 12}]}},
                {"SELECT u * cast(v AS SMALLINT) AS c FROM #{m} WHERE v = 5",
                 {:ok, [%{"c" => 35}]}}
              ] do
            if local?,
              do: assert(sxc_query(ctx, sql) === narrow, sql),
              else: assert(sxc_query(ctx, sql) === engine, sql)
          end

          # FLOAT and REAL are Float32; the rows are the engine's alone.
          for type <- ["FLOAT", "REAL"] do
            result = sxc_query(ctx, "SELECT cast(f AS #{type}) AS c FROM #{m} WHERE v = 5")

            if local?,
              do: assert({:error, %{status: 400, body: "Client.Local: " <> _reason}} = result),
              else: assert(result === {:ok, [%{"c" => 2.7}]})
          end

          # The unsigned widths are the engine's too.
          for type <- ["INT UNSIGNED", "BIGINT UNSIGNED", "SMALLINT UNSIGNED"] do
            result = sxc_query(ctx, "SELECT cast(v AS #{type}) AS c FROM #{m} WHERE v = 5")

            if local?,
              do:
                assert(
                  {:error, %{status: 400, body: "Client.Local: unsupported column" <> _more}} =
                    result
                ),
              else: assert(result === {:ok, [%{"c" => 5}]})
          end

          # An ORDER BY the double cannot read is not a column named so.
          result = sxc_query(ctx, "SELECT v FROM #{m} ORDER BY cast(f AS FLOAT)")

          if local?,
            do:
              assert(
                result ===
                  {:error,
                   %{status: 400, body: "Client.Local: unsupported ORDER BY: cast(f as float)"}}
              ),
            else: assert(result === {:ok, sxc_vs([100_000, 5, 300, -7])})

          # The nanoseconds of a timestamp.
          result = sxc_query(ctx, "SELECT cast(time AS BIGINT) AS c FROM #{m} WHERE v = 5")

          if local?,
            do:
              assert(
                {:error, %{status: 400, body: "Client.Local: a CAST of a timestamp" <> _more}} =
                  result
              ),
            else: assert(result === {:ok, [%{"c" => 1_000_000_000}]})
        end
      end
    end
  end

  defp cast_unwrap_tests do
    quote location: :keep do
      describe "SQL executor — contract: a CAST under a comparison" do
        test "the cast goes when the literals fit its type and its operand's", ctx do
          m = sxc_cast_data(ctx)
          all = sxc_vs([5, 100_000, -7, 300])

          # `big` is past Int32 in two rows, and nothing is cast.
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE cast(big AS INT) > 1 ORDER BY time") ===
                   all

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(big AS INT) = 2147483647 ORDER BY time"
                 ) ===
                   sxc_vs([-7])

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE cast(v AS TINYINT) = 5 ORDER BY time") ===
                   sxc_vs([5])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(v AS TINYINT) IN (5, 6) ORDER BY time"
                 ) ===
                   sxc_vs([5])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(v AS TINYINT) BETWEEN 1 AND 100 ORDER BY time"
                 ) === sxc_vs([5])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(v AS TINYINT) NOT BETWEEN 1 AND 100 ORDER BY time"
                 ) === sxc_vs([100_000, -7, 300])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(big AS SMALLINT) = 100 ORDER BY time"
                 ) ===
                   sxc_vs([300])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(cast(big AS INT) AS SMALLINT) = 100 ORDER BY time"
                 ) === sxc_vs([300])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(cast(v AS SMALLINT) AS INT) > 1000 ORDER BY time"
                 ) === sxc_vs([100_000])

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE cast(u AS INT) > 1 ORDER BY time") ===
                   sxc_vs([5, 100_000, 300])

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE cast(v AS BIGINT) > 6 ORDER BY time") ===
                   sxc_vs([100_000, 300])
        end

        test "a literal past the type, a float, a negative one over an unsigned: the cast stays",
             ctx do
          m = sxc_cast_data(ctx)

          for where <- [
                "cast(big AS INT) > 3000000000",
                "cast(v AS TINYINT) = 300",
                "cast(v AS TINYINT) > 300.5",
                "cast(v AS TINYINT) IN (5, 300)",
                "cast(v AS TINYINT) BETWEEN 1 AND 300",
                "cast(u AS INT) > -1",
                "cast(cast(big AS INT) AS SMALLINT) > 100000",
                "cast(f AS INT) > 1",
                "cast(s AS INT) > 1",
                "cast(big AS INT) + 1 > 1"
              ] do
            assert sxc_query(ctx, "SELECT v FROM #{m} WHERE #{where}") === @sxc_closed, where
          end

          # The cast succeeds for every row it meets, and the comparison widens.
          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(v AS INT) > 1 AND cast(v AS INT) < 400 ORDER BY time"
                 ) === sxc_vs([5, 300])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(v AS INT) * cast(v AS INT) > 1000000 ORDER BY time"
                 ) === sxc_vs([100_000])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(v AS INT) * cast(v AS INT) = 1410065408 ORDER BY time"
                 ) === sxc_vs([100_000])
        end
      end
    end
  end

  defp cast_fold_tests(client) do
    quote location: :keep do
      describe "SQL executor — contract: constants the optimizer folds" do
        test "a constant cast that cannot be performed fails before a row is read", ctx do
          m = sxc_cast_data(ctx)

          fold = fn message ->
            {500,
             "Optimizer rule 'simplify_expressions' failed\ncaused by\nArrow error: Cast error: " <>
               message}
          end

          for {expr, message} <- [
                {"cast(3000000000 AS INT)", "Can't cast value 3000000000 to type Int32"},
                {"cast(-3000000000 AS INTEGER)", "Can't cast value -3000000000 to type Int32"},
                {"cast(9223372036854775807 AS TINYINT)",
                 "Can't cast value 9223372036854775807 to type Int8"},
                {"cast(300 AS TINYINT)", "Can't cast value 300 to type Int8"},
                {"cast(-129 AS TINYINT)", "Can't cast value -129 to type Int8"},
                {"cast(32768 AS SMALLINT)", "Can't cast value 32768 to type Int16"},
                {"cast(cast(300 AS SMALLINT) AS TINYINT)", "Can't cast value 300 to type Int8"},
                {"cast(300 AS TINYINT) + 1", "Can't cast value 300 to type Int8"},
                {"cast(9223372036854775808 AS BIGINT)",
                 "Can't cast value 9223372036854775808 to type Int64"},
                {"cast(1e400 AS INT)", "Can't cast value inf to type Int32"},
                {"cast(-1e400 AS BIGINT)", "Can't cast value -inf to type Int64"},
                {"cast(3000000000.5 AS INT)", "Can't cast value 3000000000.5 to type Int32"},
                {"cast(300.7 AS TINYINT)", "Can't cast value 300.7 to type Int8"},
                {"cast(1e15 AS INT)", "Can't cast value 1000000000000000.0 to type Int32"},
                {"cast(1e16 AS INT)", "Can't cast value 1e16 to type Int32"},
                {"cast(1.5e16 AS INT)", "Can't cast value 1.5e16 to type Int32"},
                {"cast(1.0e300 AS BIGINT)", "Can't cast value 1e300 to type Int64"}
              ] do
            assert sxc_error(ctx, "SELECT #{expr} AS c FROM #{m}") === fold.(message), expr
          end

          # Wherever it stands, and whether or not a row would reach it.
          failing = fold.("Can't cast value 3000000000 to type Int32")

          for sql <- [
                "SELECT v FROM #{m} WHERE v > cast(3000000000 AS INT)",
                "SELECT v FROM #{m} WHERE cast(3000000000 AS INT) = cast(3000000000 AS INT)",
                "SELECT v FROM #{m} WHERE v = 999999 AND v > cast(3000000000 AS INT)",
                "SELECT v FROM #{m} WHERE v = 5 OR v > cast(3000000000 AS INT)",
                "SELECT cast(3000000000 AS INT) AS c FROM #{m} WHERE v = 999999",
                "SELECT cast(3000000000 AS INT) AS c FROM #{m} LIMIT 0",
                "SELECT max(cast(3000000000 AS INT)) AS c FROM #{m}"
              ] do
            assert sxc_error(ctx, sql) === failing, sql
          end

          # Folded, a cast that can be performed is a value.
          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE v > cast(2.5 AS INT) AND v < cast(1 AS INT) + 400 ORDER BY time"
                 ) ===
                   sxc_vs([5, 300])

          assert sxc_rows(
                   ctx,
                   "SELECT cast(1e-7 AS INT) AS a, cast(2.5 AS TINYINT) AS b, cast(true AS INT) AS c FROM #{m} LIMIT 1"
                 ) ===
                   [%{"a" => 0, "b" => 2, "c" => 1}]

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(3000000000 AS BIGINT) > 1 ORDER BY time"
                 ) ===
                   sxc_vs([5, 100_000, -7, 300])

          if unquote(client) === InfluxElixir.Client.Local, do: :ok
        end

        test "a LIMIT 0 reads no row, so no row fails", ctx do
          m = sxc_cast_data(ctx)

          for where <- [
                "v > 1 / 0",
                "cast(s AS INT) > 1",
                "v > -(-9223372036854775807 - 1)",
                "cast(v AS TINYINT) > 1"
              ] do
            assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE #{where} LIMIT 0") === [], where
          end

          assert sxc_rows(ctx, "SELECT cast(s AS INT) AS c FROM #{m} LIMIT 0") === []
          assert sxc_rows(ctx, "SELECT count(*) AS c FROM #{m} WHERE v > 1 / 0 LIMIT 0") === []
          assert sxc_query(ctx, "SELECT cast(s AS INT) AS c FROM #{m}") === @sxc_closed
        end
      end
    end
  end

  defp negation_overflow_tests(client) do
    quote location: :keep do
      describe "SQL executor — contract: a negated minimum in a WHERE" do
        test "the interval analysis fails on it when it takes every conjunct", ctx do
          m = sxc_cast_data(ctx)
          min = "-(-9223372036854775807 - 1)"

          failure =
            {500,
             "Arrow error: Arithmetic overflow: Overflow happened on: - -9223372036854775808"}

          for where <- [
                "v > #{min}",
                "v >= #{min}",
                "v < #{min}",
                "v = #{min}",
                "#{min} < v",
                "v BETWEEN 1 AND #{min}",
                "v IN (#{min})",
                "NOT (v > #{min})",
                "v = 5 AND v > #{min}",
                "v > #{min} AND v = 5",
                "v > 0 AND (v > #{min})",
                "v + 1 > #{min}",
                "v > #{min} + 1",
                "#{min} > 1",
                "v > 1 AND #{min} > 1",
                "f > #{min}",
                "u > #{min}"
              ] do
            assert sxc_error(ctx, "SELECT v FROM #{m} WHERE #{where}") === failure, where
          end

          assert sxc_error(ctx, "SELECT v FROM #{m} WHERE v > #{min} GROUP BY v") === failure
        end

        test "a narrow type's minimum names its own value", ctx do
          m = sxc_cast_data(ctx)

          for {expr, value} <- [
                {"cast(-2147483648 AS INT)", "-2147483648"},
                {"cast(-32768 AS SMALLINT)", "-32768"},
                {"cast(-128 AS TINYINT)", "-128"}
              ] do
            assert sxc_error(ctx, "SELECT v FROM #{m} WHERE v > -#{expr}") ===
                     {500, "Arrow error: Arithmetic overflow: Overflow happened on: - #{value}"},
                   expr
          end

          # Not the minimum, or two negations that cancel before it is read.
          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v > -(cast(-2147483647 AS INT) - 1)") ===
                   []

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE v > -(-(-9223372036854775807 - 1)) ORDER BY time"
                 ) ===
                   sxc_vs([5, 100_000, -7, 300])
        end

        test "with a conjunct it cannot take, the constant is read per row", ctx do
          m = sxc_cast_data(ctx)
          min = "-(-9223372036854775807 - 1)"

          for where <- [
                "v <> #{min}",
                "v NOT BETWEEN 1 AND #{min}",
                "v IN (1, #{min})",
                "v NOT IN (1, #{min})",
                "v > #{min} OR v = 5",
                "v = 5 OR v > #{min}",
                "v IS NOT NULL AND v > #{min}",
                "s = #{min}",
                "v > #{min} AND s = 'a'",
                "v > #{min} AND t",
                "v > #{min} AND v <> 5",
                "v > #{min} AND v IN (1, 2)",
                "v > #{min} AND v IS NULL"
              ] do
            assert sxc_query(ctx, "SELECT v FROM #{m} WHERE #{where}") === @sxc_closed, where
          end

          assert sxc_error(ctx, "SELECT v FROM #{m} WHERE v > #{min} AND time > 5") ===
                   {400,
                    sxc_coercion(
                      "Cannot infer common argument type for comparison operation Timestamp(ns) > Int64"
                    )}

          assert sxc_query(ctx, "SELECT -(-9223372036854775807 - 1) AS a FROM #{m}") ===
                   @sxc_closed

          assert sxc_query(ctx, "SELECT v, -(-9223372036854775807 - 1) AS a FROM #{m}") ===
                   @sxc_closed

          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v > 1 / 0") === @sxc_closed
          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v > 5 % 0") === @sxc_closed

          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v > abs(-9223372036854775807 - 1)") ===
                   @sxc_closed

          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v = 5 OR v > 1 / 0") === @sxc_closed
        end

        test "an addition or a product that overflows wraps, a division by zero closes", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE v > 9223372036854775807 + 1 ORDER BY time"
                 ) ===
                   sxc_vs([5, 100_000, -7, 300])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE v > 9223372036854775807 * 2 ORDER BY time"
                 ) ===
                   sxc_vs([5, 100_000, 300])

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v > -9223372036854775807 - 2") === []

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v > cast(2147483647 AS INT) + 1") === []
        end

        @tag local_divergence: "Local refuses what it cannot pin down by name"
        test "a minimum divided by -1 beside another comparison is the engine's own bug", ctx do
          m = sxc_cast_data(ctx)
          local? = unquote(client) === InfluxElixir.Client.Local
          division = "(-9223372036854775807 - 1) / -1"

          # Alone it is read per row.
          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v > #{division}") === @sxc_closed

          result = sxc_query(ctx, "SELECT v FROM #{m} WHERE v > #{division} AND v = 5")

          if local?,
            do:
              assert(
                result ===
                  {:error,
                   %{
                     status: 400,
                     body:
                       "Client.Local: a WHERE with a constant that divides a minimum by -1 beside " <>
                         "another comparison: the engine fails it in its interval analysis with an " <>
                         "internal error that is not modelled"
                   }}
              ),
            else:
              assert(
                result === {:error, %{status: 500, body: sxc_interval("lhs:Null, rhs:Int64")}}
              )
        end
      end
    end
  end

  defp plan_cut_tests do
    quote location: :keep do
      describe "SQL executor — contract: where a function error loses its tail" do
        test "a call under a CAST, IS NULL, BETWEEN, IN, LIKE or NOT is worded by its first sentence",
             ctx do
          m = sxc_cast_data(ctx)
          head = "Function 'abs' expects NativeType::Numeric but received NativeType::String"

          tail =
            " No function matches the given name and argument types 'abs(Utf8)'. You might need " <>
              "to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"

          for {where, wording} <- [
                {"abs(s) > 1", :tail},
                {"abs(s) = 1", :tail},
                {"abs(s) + 1 = 2", :tail},
                {"abs(abs(s)) > 1", :tail},
                {"-abs(s) > 1", :tail},
                {"abs(cast(abs(s) AS INT)) > 1", :tail},
                {"round(cast(abs(s) AS INT)) > 1", :tail},
                {"abs(s) > 1 OR cast(abs(s) AS INT) > 1", :tail},
                {"cast(abs(s) AS INT) > 1", :head},
                {"cast(abs(s) AS DOUBLE) > 1", :head},
                {"cast(abs(s) AS INT) = 1", :head},
                {"cast(abs(s) AS INT) + 1 > 1", :head},
                {"1 + cast(abs(s) AS INT) > 1", :head},
                {"-cast(abs(s) AS INT) > 1", :head},
                {"cast(abs(abs(s)) AS INT) > 1", :head},
                {"cast(1 + abs(s) AS INT) > 1", :head},
                {"abs(s) IS NULL", :head},
                {"abs(s) IS NOT NULL", :head},
                {"abs(abs(s)) IS NULL", :head},
                {"abs(cast(abs(s) AS INT)) IS NULL", :head},
                {"abs(s) BETWEEN 1 AND 2", :head},
                {"abs(s) IN (1)", :head},
                {"abs(s) NOT IN (1)", :head},
                {"abs(s) LIKE 'a'", :head},
                {"NOT abs(s) > 1", :head},
                {"NOT (abs(s) > 1)", :head},
                {"NOT (abs(s) > 1 AND abs(s) > 2)", :head},
                {"v = 5 AND NOT abs(s) > 1", :head}
              ] do
            expected = {400, sxc_coercion(if wording == :tail, do: head <> tail, else: head)}
            assert sxc_error(ctx, "SELECT v FROM #{m} WHERE #{where}") === expected, where
          end

          assert sxc_error(ctx, "SELECT v FROM #{m} ORDER BY abs(s)") ===
                   {400, sxc_coercion(head)}

          assert sxc_error(ctx, "SELECT cast(abs(s) AS INT) AS c FROM #{m}") ===
                   {400, sxc_planning(head <> tail)}
        end

        test "the plain errors come first, then the cut ones and the lists, as written", ctx do
          m = sxc_cast_data(ctx)
          head = "Function 'abs' expects NativeType::Numeric but received NativeType::String"

          tail =
            " No function matches the given name and argument types 'abs(Utf8)'. You might need " <>
              "to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"

          plain = {400, sxc_coercion(head <> tail)}
          cut = {400, sxc_coercion(head)}

          boolean =
            {400,
             sxc_coercion(
               "Cannot infer common argument type for comparison operation Boolean > Int64"
             )}

          in_list =
            {400, sxc_coercion("Can not find compatible types to compare Boolean with [Int64]")}

          like =
            {400,
             sxc_coercion("There isn't a common type to coerce Int64 and Utf8 in LIKE expression")}

          sum =
            {400, sxc_coercion("Cannot coerce arithmetic expression Utf8 + Int64 to valid types")}

          for {where, expected} <- [
                {"abs(s) > 1 AND cast(abs(s) AS INT) > 1", plain},
                {"cast(abs(s) AS INT) > 1 AND abs(s) > 1", plain},
                {"abs(s) IS NULL AND abs(s) > 1", plain},
                {"t IN (1) AND abs(s) > 1", plain},
                {"cast(abs(s) AS INT) > 1 AND t > 1", boolean},
                {"cast(abs(s) AS INT) > 1 AND s + 1 > 1", sum},
                {"NOT (t > 1) AND abs(s) > 1", plain},
                {"cast(s + 1 AS INT) > 1 AND abs(s) > 1", plain},
                {"cast(s + 1 AS INT) > 1 AND t > 1", boolean},
                {"cast(s + 1 AS INT) > 1 AND t IN (1)", sum},
                {"t IN (1) AND cast(s + 1 AS INT) > 1", in_list},
                {"NOT (s + 1 > 1) AND t > 1", boolean},
                {"cast(abs(s) AS INT) > 1 AND t IN (1)", cut},
                {"t IN (1) AND cast(abs(s) AS INT) > 1", in_list},
                {"cast(abs(s) AS INT) > 1 AND v LIKE 'a'", cut},
                {"v LIKE 'a' AND cast(abs(s) AS INT) > 1", like},
                {"abs(s) IS NULL AND v LIKE 'a'", cut},
                {"v LIKE 'a' AND abs(s) IS NULL", like}
              ] do
            assert sxc_error(ctx, "SELECT v FROM #{m} WHERE #{where}") === expected, where
          end
        end
      end
    end
  end
end
