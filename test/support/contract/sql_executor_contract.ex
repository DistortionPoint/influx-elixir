defmodule InfluxElixir.Contract.SQLExecutor do
  @moduledoc """
  SQL executor contract tests, run against `InfluxElixir.Client.Local` and
  against a real InfluxDB 3 Core: the answers the double must give exactly
  as the engine does (rows, error status and body). Every expectation here
  was read from a Core.

      use InfluxElixir.Contract.SQLExecutor, client: InfluxElixir.Client.Local, profile: :v3_core

  The `setup` callback must return `conn` and `database`, as
  for the shared contract. A real server is shared between runs, so every
  measurement name is unique.

  ## Parts

  A module that generates the whole contract is slow to compile, so `part: part`
  generates one slice of it, for a module of its own that compiles and runs in
  parallel with its siblings. Without `:part` everything is generated.

    * `:planning` — planning order, booleans, results, infinities, joins
    * `:unsigned_bounds` — unsigned columns, bounds
    * `:casts` — casts, overflow, plan cuts
    * `:folding` — the simplifier, batches, ranges, decimals, scales
  """

  @parts [:planning, :unsigned_bounds, :casts, :folding]

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)
    part = Keyword.get(opts, :part, :all)

    unless part == :all or part in @parts do
      raise ArgumentError,
            "unknown :part #{inspect(part)}, expected :all or one of #{inspect(@parts)}"
    end

    # The helpers are public functions: a part that does not call one of them
    # must not warn about it.
    helpers = [
      helpers(client),
      message_helpers(),
      table_helpers(),
      numeric_helpers(),
      bounds_helpers(),
      cast_helpers(),
      ijf_helpers(),
      batch_helpers(),
      guard_helpers(),
      cast_range_helpers()
    ]

    tests =
      for {test_part, block} <- test_blocks(client, profile),
          part == :all or part == test_part,
          do: block

    quote location: :keep do
      (unquote_splicing(helpers))
      (unquote_splicing(tests))
    end
  end

  # Every block of tests with the part it belongs to, in order.
  @spec test_blocks(Macro.t(), atom()) :: [{atom(), Macro.t()}]
  defp test_blocks(client, profile) do
    [
      {:planning, planning_tests()},
      {:planning, null_between_tests()},
      {:planning, plan_order_tests()},
      {:planning, boolean_tests()},
      {:planning, result_tests()},
      {:planning, text_result_tests()},
      {:planning, integer_tests()},
      {:planning, division_tests()},
      {:planning, infinity_tests()},
      {:planning, infinity_edge_tests()},
      {:unsigned_bounds, unsigned_tests()},
      {:unsigned_bounds, unsigned_decimal_tests()},
      {:unsigned_bounds, unsigned_function_tests()},
      {:unsigned_bounds, unsigned_cte_tests()},
      {:planning, wording_tests()},
      {:planning, join_tests(profile)},
      {:planning, qualified_join_tests()},
      {:unsigned_bounds, bounds_error_tests()},
      {:unsigned_bounds, bounds_answer_tests()},
      {:unsigned_bounds, bounds_order_tests(client)},
      {:casts, cast_width_tests()},
      {:casts, cast_arithmetic_tests()},
      {:casts, cast_aggregate_tests()},
      {:casts, cast_unwrap_tests()},
      {:casts, cast_fold_tests()},
      {:casts, negation_overflow_tests()},
      {:casts, overflow_arithmetic_tests()},
      {:casts, plan_cut_tests()},
      {:folding, simplifier_tests()},
      {:folding, simplifier_null_tests()},
      {:folding, batch_tests()},
      {:folding, guard_float_tests()},
      {:folding, guard_integer_tests()},
      {:folding, cast_range_tests()},
      {:folding, division_range_tests()},
      {:folding, bounds_arithmetic_tests()},
      {:folding, division_force_tests()},
      {:folding, decimal_literal_tests()},
      {:folding, decimal_refusal_tests()},
      {:folding, wide_literal_tests()},
      {:folding, order_alias_tests()},
      {:folding, linear_bounds_tests()},
      {:folding, scale_tests()}
    ]
  end

  defp helpers(client) do
    quote location: :keep do
      @sxc_closed {:error, {:connection_error, %Mint.TransportError{reason: :closed}}}

      # Whether the client under test is the double, which refuses some shapes by name.
      def sxc_local?, do: unquote(client) === InfluxElixir.Client.Local

      def sxc_write(ctx, lines) do
        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, Enum.join(lines, "\n"), database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)
      end

      def sxc_query(ctx, sql, opts \\ []) do
        unquote(client).query_sql(ctx.conn, sql, [database: ctx.database] ++ opts)
      end
    end
  end

  # What the tests say about names, bodies and the error shapes.
  defp message_helpers do
    quote location: :keep do
      # The ends of Int64, and the smallest written as the engine's parser reads it
      # (the number alone, `-9223372036854775808`, is a different literal).
      @sxc_int64_max 9_223_372_036_854_775_807
      @sxc_int64_min -9_223_372_036_854_775_808
      @sxc_int64_min_expr "(-9223372036854775807 - 1)"
      @sxc_negated_min "-(-9223372036854775807 - 1)"

      # The nanosecond timestamp of the `seconds`th second after the epoch.
      def sxc_ns(seconds), do: seconds * 1_000_000_000

      # The 500 body of a bug in DataFusion's code that the engine reports as `message`.
      def sxc_internal(message) do
        "Internal error: " <>
          message <>
          ".\n" <>
          "This issue was likely caused by a bug in DataFusion's code. Please help us to " <>
          "resolve this by filing a bug report in our issue tracker: " <>
          "https://github.com/apache/datafusion/issues"
      end

      def sxc_name(prefix) do
        "#{prefix}_#{100_000_000 + System.unique_integer([:positive])}"
      end

      def sxc_planning(message) do
        "Error during planning: " <> message
      end

      def sxc_coercion(message) do
        "type_coercion\ncaused by\nError during planning: " <> message
      end

      def sxc_rows(ctx, sql) do
        assert {:ok, rows} = sxc_query(ctx, sql)
        rows
      end

      def sxc_error(ctx, sql) do
        assert {:error, %{status: status, body: body}} = sxc_query(ctx, sql)
        {status, body}
      end

      # The planning error for `column` of table `m` left out of the GROUP BY, when
      # `satisfying` is all the select list has that satisfies the requirement.
      def sxc_ungrouped(m, column, satisfying) do
        "Error during planning: Column in SELECT must be in GROUP BY or an aggregate " <>
          "function: While expanding wildcard, column \"#{m}.#{column}\" must appear in " <>
          "the GROUP BY clause or must be part of an aggregate function, currently " <>
          "only \"#{satisfying}\" appears in the SELECT clause satisfies this requirement"
      end
    end
  end

  # Tables the tests write.
  defp table_helpers do
    quote location: :keep do
      # One row of a table with two tags, a float and an integer field.
      def sxc_grouped(ctx) do
        m = sxc_name("sxc_grp")
        sxc_write(ctx, ["#{m},symbol=AAA,exch=X price=10.5,qty=3i #{sxc_ns(1)}"])
        m
      end

      # Three rows: a boolean that starts false, a string that is missing
      # from the last row, and a float that is not a whole number.
      def sxc_mixed(ctx) do
        m = sxc_name("sxc_mix")

        sxc_write(ctx, [
          ~s|#{m},k=a v=1i,s="b",b=false,f=1.5 #{sxc_ns(1)}|,
          ~s|#{m},k=b v=2i,s="a",b=true,f=2.5 #{sxc_ns(2)}|,
          "#{m},k=c v=3i,b=true,f=500.0 #{sxc_ns(3)}"
        ])

        m
      end
    end
  end

  defp numeric_helpers do
    quote location: :keep do
      def sxc_negative_zero?(value) do
        is_float(value) and <<value::float>> === <<-0.0::float>>
      end

      # Two rows of the largest finite float and the extreme integers: their
      # squares overflow and their sums wrap.
      def sxc_big(ctx) do
        m = sxc_name("sxc_big")

        sxc_write(ctx, [
          "#{m},k=a f=1.7e308,i=9223372036854775807i,j=-9223372036854775808i,u=5u #{sxc_ns(1)}",
          "#{m},k=b f=1.7e308,i=9223372036854775807i,j=-9223372036854775808i,u=7u #{sxc_ns(2)}"
        ])

        m
      end

      # An unsigned, a signed and a float column.
      def sxc_unsigned(ctx) do
        m = sxc_name("sxc_u")

        sxc_write(ctx, [
          "#{m} u=5u,v=3i,f=2.5 #{sxc_ns(1)}",
          "#{m} u=7u,v=-4i,f=-1.5 #{sxc_ns(2)}"
        ])

        m
      end

      # The largest UInt64 twice.
      def sxc_unsigned_max(ctx) do
        m = sxc_name("sxc_umax")

        sxc_write(ctx, [
          "#{m} u=18446744073709551615u #{sxc_ns(1)}",
          "#{m} u=18446744073709551615u #{sxc_ns(2)}"
        ])

        m
      end
    end
  end

  defp bounds_helpers do
    quote location: :keep do
      # Two integer rows, then one row with a float, a string and a boolean.
      def sxc_bounds(ctx) do
        m = sxc_name("sxc_bnd")

        sxc_write(ctx, [
          "#{m} v=1i #{sxc_ns(1)}",
          "#{m} v=2i #{sxc_ns(2)}",
          ~s|#{m} f=1.5,s="a",b=true #{sxc_ns(3)}|
        ])

        m
      end

      def sxc_interval(sides, kind \\ "comparable") do
        sxc_internal("Only intervals with the same data type are #{kind}, #{sides}")
      end
    end
  end

  # Four integer rows: values past the `Int32` range, at its ends, and well
  # inside it; an unsigned, a float, a string and a boolean column.
  defp cast_helpers do
    quote location: :keep do
      def sxc_cast_data(ctx) do
        m = sxc_name("sxc_cast")

        sxc_write(ctx, [
          ~s|#{m} v=5i,big=3000000000i,neg=-3000000000i,f=2.7,u=7u,s="12",t=true #{sxc_ns(1)}|,
          ~s|#{m} v=100000i,big=2147483648i,neg=-2147483649i,f=-2.7,u=4000000000u,| <>
            ~s|s="x",t=false #{sxc_ns(2)}|,
          ~s|#{m} v=-7i,big=2147483647i,neg=-2147483648i,f=3000000000.5,u=0u,| <>
            ~s|s="-3",t=true #{sxc_ns(3)}|,
          ~s|#{m} v=300i,big=100i,neg=-100i,f=40000.2,u=70u,s="7",t=true #{sxc_ns(4)}|
        ])

        m
      end

      def sxc_cast_one(ctx, m, expr, where) do
        sxc_query(ctx, "SELECT #{expr} AS c FROM #{m} WHERE #{where}")
      end

      def sxc_vs(rows), do: Enum.map(rows, &%{"v" => &1})

      # The body of an error the optimizer's simplifier raises as an Arrow error.
      def sxc_simplify(message) do
        "Optimizer rule 'simplify_expressions' failed\ncaused by\nArrow error: " <> message
      end

      # The 500 for a constant cast that cannot be performed, folded by the optimizer.
      def sxc_fold(message) do
        {500,
         "Optimizer rule 'simplify_expressions' failed\ncaused by\nArrow error: Cast error: " <>
           message}
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

        @tag engine_bug: "closed connection"
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

  defp null_between_tests do
    quote location: :keep do
      describe "SQL executor — contract: NULL bounds" do
        test "a null bound makes BETWEEN unknown, with three-valued AND", ctx do
          m = sxc_name("sxc_between")

          sxc_write(ctx, [
            "#{m} v=3i #{sxc_ns(1)}",
            "#{m} v=2i #{sxc_ns(2)}",
            "#{m} v=0i #{sxc_ns(3)}"
          ])

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
            "#{m} v=1i #{sxc_ns(1)}",
            "#{m} v=2i #{sxc_ns(2)}",
            ~s|#{m} v=3i,s="x" #{sxc_ns(3)}|
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

  defp boolean_tests do
    quote location: :keep do
      describe "SQL executor — contract: a boolean is comparable with a boolean" do
        @tag engine_bug: "DataFusion internal error"
        test "a comparison, an IN list and a BETWEEN name the types", ctx do
          m = sxc_mixed(ctx)
          cmp = "Cannot infer common argument type for comparison operation "
          list = "Can not find compatible types to compare "

          between =
            "type_coercion\ncaused by\n" <>
              sxc_internal("Failed to coerce types Int64 and Boolean in BETWEEN expression")

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
            if sxc_local?() do
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
                   "SELECT first_value(b ORDER BY time) AS a, last_value(b ORDER BY time) AS " <>
                     "z " <>
                     "FROM #{m}"
                 ) === [%{"a" => false, "z" => true}]

          assert sxc_rows(
                   ctx,
                   "SELECT first_value(v ORDER BY s) AS a, first_value(v ORDER BY s DESC) AS " <>
                     "b, " <>
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
      end
    end
  end

  defp text_result_tests do
    quote location: :keep do
      describe "SQL executor — contract: results, text and nulls" do
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

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT k, s FROM #{m} WHERE k = 'c') SELECT s FROM c"
                 ) ===
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

  defp integer_tests do
    quote location: :keep do
      describe "SQL executor — contract: Int64 arithmetic" do
        test "+, -, * and negation wrap in two's complement", ctx do
          m = sxc_name("sxc_wrap")

          sxc_write(ctx, [
            "#{m} y=1i #{sxc_ns(1)}",
            "#{m} y=2i #{sxc_ns(2)}",
            "#{m} y=#{@sxc_int64_min}i #{sxc_ns(3)}"
          ])

          select =
            "SELECT y + #{@sxc_int64_max} AS a, y - #{@sxc_int64_max} AS b, y * " <>
              "#{@sxc_int64_max} AS c, " <>
              "-y AS d, y * 2 AS e, y - 1 AS f, y * -1 AS g FROM #{m} ORDER BY time"

          assert sxc_rows(ctx, select) === [
                   %{
                     "a" => @sxc_int64_min,
                     "b" => -@sxc_int64_max + 1,
                     "c" => @sxc_int64_max,
                     "d" => -1,
                     "e" => 2,
                     "f" => 0,
                     "g" => -1
                   },
                   %{
                     "a" => @sxc_int64_min + 1,
                     "b" => -@sxc_int64_max + 2,
                     "c" => -2,
                     "d" => -2,
                     "e" => 4,
                     "f" => 1,
                     "g" => -2
                   },
                   %{
                     "a" => -1,
                     "b" => 1,
                     "c" => @sxc_int64_min,
                     "d" => @sxc_int64_min,
                     "e" => 0,
                     "f" => @sxc_int64_max,
                     "g" => @sxc_int64_min
                   }
                 ]
        end

        test "a constant and a WHERE wrap as a column does", ctx do
          m = sxc_name("sxc_wrap_where")
          sxc_write(ctx, ["#{m} y=1i #{sxc_ns(1)}", "#{m} y=-5i #{sxc_ns(2)}"])

          assert sxc_rows(
                   ctx,
                   "SELECT #{@sxc_int64_max} * 2 AS a, -#{@sxc_int64_max} - 2 AS b FROM #{m} " <>
                     "LIMIT 1"
                 ) === [%{"a" => -2, "b" => @sxc_int64_max}]

          assert sxc_rows(
                   ctx,
                   "SELECT y FROM #{m} WHERE y + #{@sxc_int64_max} < 0 ORDER BY time"
                 ) ===
                   [
                     %{"y" => 1}
                   ]
        end

        @tag engine_bug: "closed connection"
        test "the minimum divided by -1 closes the connection; its remainder is 0", ctx do
          m = sxc_name("sxc_wrap_div")
          sxc_write(ctx, ["#{m} y=#{@sxc_int64_min}i #{sxc_ns(1)}"])
          assert sxc_query(ctx, "SELECT y / -1 AS a FROM #{m}") === @sxc_closed
          assert sxc_rows(ctx, "SELECT y % -1 AS a FROM #{m}") === [%{"a" => 0}]

          assert sxc_rows(ctx, "SELECT y / 1 AS a, y / 2 AS b FROM #{m}") === [
                   %{"a" => @sxc_int64_min, "b" => -4_611_686_018_427_387_904}
                 ]
        end
      end
    end
  end

  defp division_tests do
    quote location: :keep do
      describe "SQL executor — contract: division by zero" do
        @tag engine_bug: "closed connection"
        test "dividing an integer by the integer zero closes the connection", ctx do
          m = sxc_mixed(ctx)
          assert sxc_query(ctx, "SELECT v / 0 AS x FROM #{m}") === @sxc_closed
          assert sxc_query(ctx, "SELECT v % 0 AS x FROM #{m}") === @sxc_closed
          assert sxc_query(ctx, "SELECT sum(v / 0) AS x FROM #{m}") === @sxc_closed
          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v / 0 > 1") === @sxc_closed
          assert {:ok, []} = sxc_query(ctx, "SELECT v / 0 AS x FROM #{m} WHERE v > 100")
        end

        test "a float divided by zero inside an aggregate sums to null and still counts", ctx do
          m = sxc_big(ctx)

          # A float over zero is infinity: COUNT counts it (it is not null) and
          # SUM turns to a non-finite double, which is sent as null.
          assert sxc_query(ctx, "SELECT SUM(f / 0) AS s, COUNT(f / 0) AS n FROM #{m}") ===
                   {:ok, [%{"s" => nil, "n" => 2}]}
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

        @tag engine_bug: "median of a narrow type wraps"
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
            "#{m},k=a f=1.7e308,s=1.0 #{sxc_ns(1)}",
            "#{m},k=b f=1.7e308,s=-1.0 #{sxc_ns(2)}",
            "#{m},k=c f=1.0,s=1.0 #{sxc_ns(3)}"
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

          assert sxc_rows(
                   ctx,
                   "SELECT max(f * s * 10) AS hi, min(f * s * 10) AS lo FROM #{m}"
                 ) ===
                   [
                     %{"hi" => nil, "lo" => nil}
                   ]
        end

        @tag engine_bug: "closed connection"
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

  defp infinity_edge_tests do
    quote location: :keep do
      describe "SQL executor — contract: infinity and NaN, the edges" do
        test "a float divided by zero is infinity or NaN, null in the response", ctx do
          m = sxc_name("sxc_fz")
          sxc_write(ctx, ["#{m} v=1i #{sxc_ns(1)}", "#{m} v=2i #{sxc_ns(2)}"])
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
          sxc_write(ctx, ["#{m} f=0.0,g=5.0 #{sxc_ns(1)}"])
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
               "the engine orders a NaN by its sign, which its CPU chooses; Local refuses a " <>
                 "comparison of one by name"
        test "a comparison of a NaN is the engine's or refused by name", ctx do
          m = sxc_big(ctx)

          for sql <- [
                "SELECT k FROM #{m} WHERE f * f - f * f > 1 ORDER BY k",
                "SELECT k FROM #{m} ORDER BY f * f - f * f",
                "SELECT max(f * f - f * f) AS x FROM #{m}"
              ] do
            result = sxc_query(ctx, sql)

            if sxc_local?() do
              assert result ===
                       {:error,
                        %{
                          status: 400,
                          body:
                            "Client.Local: a comparison or ordering of a NaN: the engine " <>
                              "orders " <>
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

        test "a UInt64 with an Int64 is a decimal, with another UInt64 it wraps", ctx do
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
        end

        test "a UInt64 with a literal past Int64 wraps in UInt64", ctx do
          m = sxc_unsigned(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT u + 18446744073709551615 AS a, u + #{@sxc_int64_max} AS b, " <>
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
                   "SELECT cast(u / 3 AS DOUBLE) AS a, u / 3 AS b, cast(u / 3 AS VARCHAR) AS " <>
                     "c " <>
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

  defp unsigned_cte_tests do
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

          assert sxc_rows(
                   ctx,
                   "WITH c AS (SELECT u FROM #{m}) SELECT u FROM c ORDER BY u DESC"
                 ) ===
                   [
                     %{"u" => 7},
                     %{"u" => 5}
                   ]
        end

        @tag local_divergence:
               "the engine rescales a decimal past 38 digits and halves the places of a mean; " <>
                 "Local refuses by name"
        test "a decimal the double does not model is the engine's or refused by name", ctx do
          big = sxc_unsigned_max(ctx)
          m = sxc_unsigned(ctx)

          for {sql, answer} <- [
                {"SELECT u * #{@sxc_int64_max} AS a FROM #{big} LIMIT 1",
                 [%{"a" => 17_014_118_346_046_923_170_401_718_760_531_977_830}]},
                {"SELECT avg(u / 2) AS a FROM #{m}", [%{"a" => 3.0}]}
              ] do
            result = sxc_query(ctx, sql)

            if sxc_local?() do
              assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} = result, sql
            else
              assert result === {:ok, answer}, sql
            end
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
            "#{m},k=a amount=5000.0 #{sxc_ns(1)}",
            "#{m},k=b amount=500.0 #{sxc_ns(2)}",
            "#{m},k=c amount=12000.0 #{sxc_ns(3)}",
            "#{m},k=d amount=1e16 #{sxc_ns(4)}",
            "#{m},k=e amount=1e-5 #{sxc_ns(5)}",
            "#{m},k=f amount=1.5e-7 #{sxc_ns(6)}",
            "#{m},k=g amount=123456789.5 #{sxc_ns(7)}",
            "#{m},k=h amount=-2.5 #{sxc_ns(8)}",
            "#{m},k=i amount=1e15 #{sxc_ns(9)}"
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
            "#{left},symbol=AAA price=10.5,qty=3i #{sxc_ns(1)}",
            "#{right},symbol=AAA price=1.0 #{sxc_ns(1)}"
          ])

          assert sxc_error(ctx, "SELECT price, symbol FROM #{left} CROSS JOIN #{right}") ===
                   {500, "Schema error: Ambiguous reference to unqualified field price"}

          assert sxc_error(
                   ctx,
                   "SELECT qty, time FROM #{left} CROSS JOIN #{right} WHERE price > 1"
                 ) ===
                   {500, "Schema error: Ambiguous reference to unqualified field price"}

          assert sxc_error(
                   ctx,
                   "SELECT qty FROM #{left} CROSS JOIN #{right} WHERE symbol = 'a'"
                 ) ===
                   {500, "Schema error: Ambiguous reference to unqualified field symbol"}
        end

        test "columns that are not shared join", ctx do
          left = sxc_name("sxc_px")
          right = sxc_name("sxc_ref")

          sxc_write(ctx, [
            "#{left},symbol=AAA price=10.5,qty=3i #{sxc_ns(1)}",
            "#{left},symbol=BBB price=20.5,qty=4i #{sxc_ns(2)}",
            "#{right},zz=1 only2=5i #{sxc_ns(1)}"
          ])

          assert sxc_rows(
                   ctx,
                   "SELECT qty, only2 FROM #{left} CROSS JOIN #{right} ORDER BY qty"
                 ) ===
                   [
                     %{"qty" => 3, "only2" => 5},
                     %{"qty" => 4, "only2" => 5}
                   ]
        end

        test "an ungrouped column names itself and the grouping that is there", ctx do
          m = sxc_grouped(ctx)
          ungrouped = &sxc_ungrouped(m, &1, &2)

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
        end

        test "what satisfies the requirement lists the aggregates as the engine prints them",
             ctx do
          m = sxc_grouped(ctx)
          ungrouped = &sxc_ungrouped(m, &1, &2)

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
        end

        test "a DATE_BIN is printed by its interval in nanoseconds", ctx do
          m = sxc_grouped(ctx)
          ungrouped = &sxc_ungrouped(m, &1, &2)

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

  defp qualified_join_tests do
    quote location: :keep do
      describe "SQL executor — contract: qualified columns of a CROSS JOIN" do
        @tag local_divergence:
               "the engine resolves a qualified column of a CROSS JOIN to its side; Local " <>
                 "refuses by name"
        test "a qualified column that both sides of a CROSS JOIN have", ctx do
          m = sxc_name("sxc_qj")
          sxc_write(ctx, ["#{m} v=1i,w=10i #{sxc_ns(1)}", "#{m} v=2i,w=20i #{sxc_ns(2)}"])
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

            if sxc_local?() do
              assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} = result, sql
            else
              assert result === {:ok, rows}, sql
            end
          end

          sql = "SELECT a.w #{join} WHERE zz.w > 1"
          result = sxc_query(ctx, sql)
          fields = "a.time, a.v, a.w, b.time, b.v, b.w"

          if sxc_local?() do
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

  defp bounds_error_tests do
    quote location: :keep do
      describe "SQL executor — contract: the interval error of an empty numeric range" do
        @tag engine_bug: "DataFusion internal error in the interval analysis"
        test "an empty interval on an integer column is the engine's internal error", ctx do
          m = sxc_bounds(ctx)
          failure = {500, sxc_interval("lhs:Null, rhs:Int64")}

          # Why this list: every way to write an empty range of one integer column that the
          # analysis takes: comparisons either way round, BETWEEN, NOT, a bound at a type end.
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
                "v > #{@sxc_int64_max} AND v < 5",
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
        @tag engine_bug: "DataFusion internal error in the interval analysis"
        test "an empty interval on an unsigned column names UInt64", ctx do
          m = sxc_name("sxc_uint")
          sxc_write(ctx, ["#{m} u=5u #{sxc_ns(1)}"])

          assert sxc_error(ctx, "SELECT u FROM #{m} WHERE u > 5 AND u < 1") ===
                   {500, sxc_interval("lhs:Null, rhs:UInt64")}

          assert sxc_error(ctx, "SELECT u FROM #{m} WHERE u < 0") ===
                   {500, sxc_interval("lhs:UInt64, rhs:Null")}

          assert sxc_rows(ctx, "SELECT u FROM #{m} WHERE u > -1 AND u < 1") === []
        end

        @tag engine_bug: "DataFusion internal error in the interval analysis"
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

        @tag engine_bug: "DataFusion internal error in the interval analysis"
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

        @tag engine_bug: "DataFusion internal error in the interval analysis"
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
                {"v > #{@sxc_int64_max}", []},
                {"v < #{@sxc_int64_min}", []},
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

          # Why this list: an empty range beside each kind of conjunct the analysis gives up on
          # (or two different equalities) leaves the rows, not the error.
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

        @tag engine_bug: "DataFusion internal error in the interval analysis"
        test "a parameter bounds as a literal does", ctx do
          m = sxc_bounds(ctx)
          failure = {:error, %{status: 500, body: sxc_interval("lhs:Null, rhs:Int64")}}

          for params <- [%{a: 5, b: 1}, %{a: 5, b: -1}, %{a: -1, b: -5}] do
            assert sxc_query(
                     ctx,
                     "SELECT * FROM #{m} WHERE v > $a AND v < $b",
                     params: params
                   ) ===
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

        @tag engine_bug: "DataFusion internal error in the interval analysis"
        test "a CROSS JOIN's filter fails on either side's column", ctx do
          left = sxc_name("sxc_bl")
          right = sxc_name("sxc_br")
          sxc_write(ctx, ["#{left} qty=3i #{sxc_ns(1)}", "#{right} only2=5i #{sxc_ns(1)}"])
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
        @tag engine_bug: "DataFusion internal error in the interval analysis"
        test "a shape the double cannot pin down is the engine's or refused by name", ctx do
          m = sxc_bounds(ctx)
          local? = sxc_local?()

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
                 engine.("lhs:Null, rhs:Int64", "comparable"),
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

  defp cast_width_tests do
    quote location: :keep do
      describe "SQL executor — contract: CAST to an integer width" do
        @tag engine_bug: "closed connection"
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

        @tag engine_bug: "closed connection"
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

        @tag engine_bug: "closed connection"
        test "text that is not a whole number is no number, spaces included", ctx do
          m = sxc_name("sxc_text")

          sxc_write(ctx, [
            ~s|#{m} k=1i,s=" 7 " #{sxc_ns(1)}|,
            ~s|#{m} k=2i,s="+7" #{sxc_ns(2)}|,
            ~s|#{m} k=3i,s="007" #{sxc_ns(3)}|,
            ~s|#{m} k=4i,s="7.0" #{sxc_ns(4)}|,
            ~s|#{m} k=5i,s=".5" #{sxc_ns(5)}|,
            ~s|#{m} k=6i,s="5." #{sxc_ns(6)}|,
            ~s|#{m} k=7i,s="1E3" #{sxc_ns(7)}|,
            ~s|#{m} k=8i,s="-Infinity" #{sxc_ns(8)}|,
            ~s|#{m} k=9i,s="nan" #{sxc_ns(9)}|,
            ~s|#{m} k=10i,s="1e400" #{sxc_ns(10)}|,
            ~s|#{m} k=11i,s="-0" #{sxc_ns(11)}|
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
        test "integers of one width wrap at it", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT cast(v AS INT) * cast(v AS INT) AS p, cast(v AS INT) + cast(v AS " <>
                     "INT) AS s " <>
                     "FROM #{m} ORDER BY time"
                 ) ===
                   [
                     %{"p" => 25, "s" => 10},
                     %{"p" => 1_410_065_408, "s" => 200_000},
                     %{"p" => 49, "s" => -14},
                     %{"p" => 90_000, "s" => 600}
                   ]
        end

        test "an Int64 (a literal, a column) widens the result", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT cast(v AS INT) * v AS a, cast(v AS INT) * 2 AS b FROM #{m} WHERE v " <>
                     "= 100000"
                 ) === [%{"a" => 10_000_000_000, "b" => 200_000}]

          assert sxc_cast_one(ctx, m, "cast(big AS INT) * 2", "v = -7") ===
                   {:ok, [%{"c" => 4_294_967_294}]}
        end

        test "the wider of two narrow types is the result's", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_cast_one(ctx, m, "cast(v AS SMALLINT) * cast(v AS SMALLINT)", "v = 300") ===
                   {:ok, [%{"c" => 24_464}]}

          assert sxc_cast_one(ctx, m, "cast(v AS SMALLINT) * cast(v AS INT)", "v = 300") ===
                   {:ok, [%{"c" => 90_000}]}
        end

        @tag engine_bug: "a TINYINT times a SMALLINT closes the connection"
        test "a TINYINT times a SMALLINT closes the connection", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_cast_one(ctx, m, "cast(v AS TINYINT) * cast(v AS SMALLINT)", "v = 300") ===
                   @sxc_closed
        end

        test "constants of one width wrap at its ends", ctx do
          m = sxc_cast_data(ctx)

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
        end

        test "a float stays a float, an integer division truncates", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_cast_one(ctx, m, "cast(v AS INT) * 2.5", "v = 300") ===
                   {:ok, [%{"c" => 750.0}]}

          assert sxc_cast_one(ctx, m, "cast(v AS INT) / 7", "v = 100000") ===
                   {:ok, [%{"c" => 14_285}]}
        end

        @tag engine_bug: "closed connection"
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

  defp cast_aggregate_tests do
    quote location: :keep do
      describe "SQL executor — contract: aggregates and names over a CAST to an int" do
        @tag engine_bug: "closed connection; median of a narrow type wraps"
        test "aggregates of a narrow type: a sum widens, a median wraps, the rest keep it", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT sum(cast(v AS INT) * cast(v AS INT)) AS s, min(cast(v AS INT)) AS " <>
                     "lo, " <>
                     "max(cast(v AS INT)) AS hi, avg(cast(v AS INT)) AS a, count(cast(v AS " <>
                     "INT)) AS n, " <>
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
                   "SELECT sum(cast(big AS INT)) AS s, median(cast(big AS INT)) AS m FROM " <>
                     "#{m} " <>
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
        test "a narrow integer with a UInt64 or a decimal is refused by name", ctx do
          m = sxc_cast_data(ctx)
          local? = sxc_local?()

          narrow =
            {:error,
             %{
               status: 400,
               body:
                 "Client.Local: arithmetic of a narrow integer (CAST AS INT, SMALLINT or " <>
                   "TINYINT) " <>
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
        end

        @tag local_divergence: "Local refuses what it cannot pin down by name"
        test "FLOAT and REAL are Float32, and the rows are the engine's alone", ctx do
          m = sxc_cast_data(ctx)
          local? = sxc_local?()

          for type <- ["FLOAT", "REAL"] do
            result = sxc_query(ctx, "SELECT cast(f AS #{type}) AS c FROM #{m} WHERE v = 5")

            if local?,
              do: assert({:error, %{status: 400, body: "Client.Local: " <> _reason}} = result),
              else: assert(result === {:ok, [%{"c" => 2.7}]})
          end
        end

        @tag local_divergence: "Local refuses what it cannot pin down by name"
        test "the unsigned widths are the engine's too", ctx do
          m = sxc_cast_data(ctx)
          local? = sxc_local?()

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
        end

        @tag local_divergence: "Local refuses what it cannot pin down by name"
        test "an ORDER BY the double cannot read is not a column named so", ctx do
          m = sxc_cast_data(ctx)
          local? = sxc_local?()

          result = sxc_query(ctx, "SELECT v FROM #{m} ORDER BY cast(f AS FLOAT)")

          if local?,
            do:
              assert(
                result ===
                  {:error,
                   %{status: 400, body: "Client.Local: unsupported ORDER BY: cast(f as float)"}}
              ),
            else: assert(result === {:ok, sxc_vs([100_000, 5, 300, -7])})
        end

        @tag local_divergence: "Local refuses what it cannot pin down by name"
        test "the nanoseconds of a timestamp are the engine's alone", ctx do
          m = sxc_cast_data(ctx)
          local? = sxc_local?()

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

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(v AS TINYINT) = 5 ORDER BY time"
                 ) ===
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
                   "SELECT v FROM #{m} WHERE cast(v AS TINYINT) NOT BETWEEN 1 AND 100 ORDER " <>
                     "BY time"
                 ) === sxc_vs([100_000, -7, 300])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(big AS SMALLINT) = 100 ORDER BY time"
                 ) ===
                   sxc_vs([300])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(cast(big AS INT) AS SMALLINT) = 100 ORDER " <>
                     "BY time"
                 ) === sxc_vs([300])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(cast(v AS SMALLINT) AS INT) > 1000 ORDER BY " <>
                     "time"
                 ) === sxc_vs([100_000])

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE cast(u AS INT) > 1 ORDER BY time") ===
                   sxc_vs([5, 100_000, 300])

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE cast(v AS BIGINT) > 6 ORDER BY time") ===
                   sxc_vs([100_000, 300])
        end

        @tag engine_bug: "closed connection"
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
                   "SELECT v FROM #{m} WHERE cast(v AS INT) > 1 AND cast(v AS INT) < 400 " <>
                     "ORDER BY time"
                 ) === sxc_vs([5, 300])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(v AS INT) * cast(v AS INT) > 1000000 ORDER " <>
                     "BY time"
                 ) === sxc_vs([100_000])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(v AS INT) * cast(v AS INT) = 1410065408 " <>
                     "ORDER BY time"
                 ) === sxc_vs([100_000])
        end
      end
    end
  end

  defp cast_fold_tests do
    quote location: :keep do
      describe "SQL executor — contract: constants the optimizer folds" do
        test "a constant cast that cannot be performed fails before a row is read", ctx do
          m = sxc_cast_data(ctx)

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
            assert sxc_error(ctx, "SELECT #{expr} AS c FROM #{m}") === sxc_fold(message), expr
          end
        end

        test "it fails wherever it stands, and whether or not a row would reach it", ctx do
          m = sxc_cast_data(ctx)
          failing = sxc_fold("Can't cast value 3000000000 to type Int32")

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
        end

        test "folded, a cast that can be performed is a value", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE v > cast(2.5 AS INT) AND v < cast(1 AS INT) + " <>
                     "400 ORDER BY time"
                 ) ===
                   sxc_vs([5, 300])

          assert sxc_rows(
                   ctx,
                   "SELECT cast(1e-7 AS INT) AS a, cast(2.5 AS TINYINT) AS b, cast(true AS " <>
                     "INT) AS c FROM #{m} LIMIT 1"
                 ) ===
                   [%{"a" => 0, "b" => 2, "c" => 1}]

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE cast(3000000000 AS BIGINT) > 1 ORDER BY time"
                 ) ===
                   sxc_vs([5, 100_000, -7, 300])
        end

        @tag engine_bug: "closed connection"
        test "a LIMIT 0 reads no row, so no row fails", ctx do
          m = sxc_cast_data(ctx)

          for where <- [
                "v > 1 / 0",
                "cast(s AS INT) > 1",
                "v > #{@sxc_negated_min}",
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

  defp negation_overflow_tests do
    quote location: :keep do
      describe "SQL executor — contract: a negated minimum in a WHERE" do
        test "the interval analysis fails on it when it takes every conjunct", ctx do
          m = sxc_cast_data(ctx)
          min = @sxc_negated_min

          failure =
            {500,
             "Arrow error: Arithmetic overflow: Overflow happened on: - -9223372036854775808"}

          # Why this list: each shape is one the analysis takes whole, in every position a
          # comparison, range or set can hold the constant.
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
                   "SELECT v FROM #{m} WHERE v > -(#{@sxc_negated_min}) ORDER BY time"
                 ) ===
                   sxc_vs([5, 100_000, -7, 300])
        end

        @tag local_divergence: "Local refuses what the engine answers by how a table is stored"
        @tag engine_bug: "closed connection"
        test "with a conjunct it cannot take, the constant is read per row (Local refuses one shape by name)",
             ctx do
          m = sxc_cast_data(ctx)
          min = @sxc_negated_min

          # Why this list: each shape leaves the analysis a conjunct it cannot take, so the
          # constant is read per row.
          for where <- [
                "v <> #{min}",
                "v NOT BETWEEN 1 AND #{min}",
                "v IN (1, #{min})",
                "v NOT IN (1, #{min})",
                "v > #{min} OR v = 5",
                "v = 5 OR v > #{min}",
                "v IS NOT NULL AND v > #{min}",
                "s = #{min}",
                "v > #{min} AND t",
                "v > #{min} AND v <> 5",
                "v > #{min} AND v IN (1, 2)",
                "v > #{min} AND v IS NULL"
              ] do
            assert sxc_query(ctx, "SELECT v FROM #{m} WHERE #{where}") === @sxc_closed, where
          end

          # A conjunct over another column: the engine may run it first (a persisted table
          # reads the cheaper column first), and then no row reaches the constant.
          refused = "SELECT v FROM #{m} WHERE v > #{min} AND s = 'a'"

          if sxc_local?() do
            assert sxc_error(ctx, refused) === sxc_batch_refusal()
          else
            assert sxc_query(ctx, refused) === @sxc_closed
          end

          assert sxc_error(ctx, "SELECT v FROM #{m} WHERE v > #{min} AND time > 5") ===
                   {400,
                    sxc_coercion(
                      "Cannot infer common argument type for comparison operation " <>
                        "Timestamp(ns) > Int64"
                    )}

          assert sxc_query(ctx, "SELECT #{@sxc_negated_min} AS a FROM #{m}") ===
                   @sxc_closed

          assert sxc_query(ctx, "SELECT v, #{@sxc_negated_min} AS a FROM #{m}") ===
                   @sxc_closed

          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v > 1 / 0") === @sxc_closed
          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v > 5 % 0") === @sxc_closed

          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v > abs(-#{@sxc_int64_max} - 1)") ===
                   @sxc_closed

          assert sxc_query(ctx, "SELECT v FROM #{m} WHERE v = 5 OR v > 1 / 0") === @sxc_closed
        end
      end
    end
  end

  defp overflow_arithmetic_tests do
    quote location: :keep do
      describe "SQL executor — contract: arithmetic that overflows in a WHERE" do
        test "an addition or a product that overflows wraps, a division by zero closes", ctx do
          m = sxc_cast_data(ctx)

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE v > #{@sxc_int64_max} + 1 ORDER BY time"
                 ) ===
                   sxc_vs([5, 100_000, -7, 300])

          assert sxc_rows(
                   ctx,
                   "SELECT v FROM #{m} WHERE v > #{@sxc_int64_max} * 2 ORDER BY time"
                 ) ===
                   sxc_vs([5, 100_000, 300])

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v > -#{@sxc_int64_max} - 2") === []

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE v > cast(2147483647 AS INT) + 1") === []
        end

        @tag local_divergence: "Local refuses what it cannot pin down by name"
        @tag engine_bug: "closed connection; DataFusion internal error in the interval analysis"
        test "a minimum divided by -1 beside another comparison is the engine's own bug (Local refuses it by name)",
             ctx do
          m = sxc_cast_data(ctx)
          local? = sxc_local?()
          division = "#{@sxc_int64_min_expr} / -1"

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
                       "Client.Local: a WHERE with a constant that divides a minimum by -1 " <>
                         "beside " <>
                         "another comparison: the engine fails it in its interval analysis " <>
                         "with an " <>
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
        test "a call under CAST, IS NULL, BETWEEN, IN, LIKE or NOT is cut after a sentence",
             ctx do
          m = sxc_cast_data(ctx)
          head = "Function 'abs' expects NativeType::Numeric but received NativeType::String"

          tail =
            " No function matches the given name and argument types 'abs(Utf8)'. You might " <>
              "need " <>
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
            " No function matches the given name and argument types 'abs(Utf8)'. You might " <>
              "need " <>
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

          like_message = "There isn't a common type to coerce Int64 and Utf8 in LIKE expression"
          like = {400, sxc_coercion(like_message)}

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

  # Three rows with two integers and a float: `i` is 1, 2, 3; `j` is 0, 50, 7.
  defp ijf_helpers do
    quote location: :keep do
      def sxc_ijf(ctx) do
        m = sxc_name("sxc_ijf")

        sxc_write(ctx, [
          "#{m} i=1i,j=0i,f=1.5 #{sxc_ns(1)}",
          "#{m} i=2i,j=50i,f=2.5 #{sxc_ns(2)}",
          "#{m} i=3i,j=7i,f=-1.5 #{sxc_ns(3)}"
        ])

        m
      end

      def sxc_is(rows), do: Enum.map(rows, &%{"i" => &1})

      def sxc_refused(what), do: {400, "Client.Local: " <> what}

      def sxc_batch_refusal do
        sxc_refused(
          "a WHERE whose AND or OR runs an operand that fails over a row the other operand " <>
            "leaves out: whether the engine fails the query depends on how the table is " <>
            "stored (freshly written or persisted) and on how it batches the rows"
        )
      end
    end
  end

  defp simplifier_tests do
    quote location: :keep do
      describe "SQL executor — contract: what the simplifier removes" do
        test "x AND false and x OR true never run x, in either order", ctx do
          m = sxc_ijf(ctx)

          for where <- ["j/0 = 1 AND false", "false AND j/0 = 1"] do
            assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE #{where}") === [], where
          end

          for where <- ["j/0 = 1 OR true", "true OR j/0 = 1"] do
            assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE #{where} ORDER BY i") ===
                     sxc_is([1, 2, 3]),
                   where
          end
        end

        test "an AND or an OR beside an OR or an AND that holds it as a side is that side",
             ctx do
          m = sxc_ijf(ctx)

          # Why this list: the pair A AND (A OR B) and A OR (A AND B), A on either side of
          # either node, with B a constant that cannot be computed, and the pair inside a
          # larger AND.
          for where <- [
                "j = 7 AND (j = 7 OR 1/0 > 1)",
                "(j = 7 OR 1/0 > 1) AND j = 7",
                "j = 7 AND (1/0 > 1 OR j = 7)",
                "j = 7 OR (j = 7 AND 1/0 > 1)",
                "j = 7 OR (1/0 > 1 AND j = 7)",
                "(j = 7 AND 1/0 > 1) OR j = 7",
                "j = 7 AND (j = 7 OR 1/0 > 1) AND i > 0",
                "i > 0 AND (j = 7 AND (j = 7 OR 1/0 > 1))"
              ] do
            assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE #{where}") === sxc_is([3]), where
          end

          assert sxc_rows(
                   ctx,
                   "SELECT i FROM #{m} WHERE (j = 7 AND (j = 7 OR 1/0 > 1)) OR i > 0 ORDER BY i"
                 ) === sxc_is([1, 2, 3])
        end

        @tag engine_bug: "closed connection"
        test "an AND or an OR that is not one of those leaves the constant to fail", ctx do
          m = sxc_ijf(ctx)

          # Why this list: a row the left side keeps reaches the constant, in an AND of a
          # row-free conjunct and in an OR whose first side fails: the query fails however
          # the engine batches the rows.
          for where <- [
                "j = 7 OR (j = 7 OR 1/0 > 1)",
                "j = 7 AND (j = 7 AND 1/0 > 1)",
                "j = 7 AND i > 0 AND (1/0 > 1 OR j = 7)"
              ] do
            assert sxc_query(ctx, "SELECT i FROM #{m} WHERE #{where}") === @sxc_closed, where
          end
        end

        @tag local_divergence: "Local refuses what the engine answers by how it batches rows"
        test "an OR that holds the constant as its second side is run over the whole batch",
             ctx do
          m = sxc_ijf(ctx)
          sql = "SELECT i FROM #{m} WHERE j = 7 AND i > 0 AND (j = 7 OR 1/0 > 1)"

          if sxc_local?() do
            assert sxc_error(ctx, sql) === sxc_batch_refusal()
          else
            assert sxc_query(ctx, sql) === {:ok, sxc_is([3])}
          end
        end

        test "a constant folds through NOT, true and false", ctx do
          m = sxc_ijf(ctx)

          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE NOT (j/0 = 1 AND false) ORDER BY i") ===
                   sxc_is([1, 2, 3])

          for {where, expected} <- [
                {"NOT (j/0 = 1 OR true)", []},
                {"j/0 = 1 AND true AND false", []},
                {"true AND j = 7", sxc_is([3])},
                {"j = 7 OR false", sxc_is([3])},
                {"j = 7 AND 1/0 IS NOT NULL", sxc_is([3])},
                {"j = 7 AND 1/0 IS NULL", []},
                {"null > 1", []}
              ] do
            assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE #{where}") === expected, where
          end
        end

        @tag engine_bug: "closed connection"
        test "what is left of an OR or a pair that absorbs nothing still runs", ctx do
          m = sxc_ijf(ctx)

          for where <- [
                "j/0 = 1 OR false OR j = 7",
                "(j = 7 OR 1/0 > 1) AND (j = 7 OR 1/0 > 1)",
                "j/0 NOT BETWEEN null AND 1",
                "j IN (null, 1/0)"
              ] do
            assert sxc_query(ctx, "SELECT i FROM #{m} WHERE #{where}") === @sxc_closed, where
          end
        end

        test "x = x is true, and x IS NULL is false, for an x with no column", ctx do
          m = sxc_ijf(ctx)

          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE 1/0 = 1/0 ORDER BY i") ===
                   sxc_is([1, 2, 3])

          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE 1/0 IS NULL") === []

          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE 1/0 IS NOT NULL ORDER BY i") ===
                   sxc_is([1, 2, 3])
        end
      end
    end
  end

  defp simplifier_null_tests do
    quote location: :keep do
      describe "SQL executor — contract: what a NULL removes" do
        test "a comparison with a NULL literal is NULL and its other operand never runs", ctx do
          m = sxc_ijf(ctx)

          for where <- [
                "j/0 > null",
                "j/0 IN (null)",
                "j/0 NOT IN (null)",
                "j BETWEEN null AND 1/0",
                "j/0 BETWEEN null AND 1",
                "null",
                "NOT null"
              ] do
            assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE #{where}") === [], where
          end

          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE null OR true ORDER BY i") ===
                   sxc_is([1, 2, 3])

          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE j = 7 OR null") === sxc_is([3])

          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE NOT (j = 7 AND null) ORDER BY i") ===
                   sxc_is([1, 2])
        end

        test "a NULL conjunct makes the filter false before the others read a column", ctx do
          m = sxc_ijf(ctx)

          for where <- [
                "j/0 > 1 AND (j = null)",
                "j/0 > 1 AND null",
                "j/0 = 1 AND NOT null",
                "i = 1 AND j/0 > 1 AND (j = null)",
                "j/0 > 1 AND (j IN (null))",
                "j/0 > 1 AND (j NOT IN (null))",
                "j/0 > 1 AND (j BETWEEN null AND 5)",
                "i > 3 AND i < 2 AND null"
              ] do
            assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE #{where}") === [], where
          end

          # The scan still takes its range from the comparisons of `time`.
          empty =
            {500,
             "External error: unexpected: provided filters on time column did not produce " <>
               "a valid set of boundaries"}

          range = "time > '2023-01-02T00:00:00Z' AND time < '2023-01-01T00:00:00Z'"

          for where <- ["j/0 > 1 AND time > null AND " <> range, "time > null AND " <> range] do
            assert sxc_error(ctx, "SELECT i FROM #{m} WHERE #{where}") === empty, where
          end
        end

        @tag engine_bug: "closed connection"
        test "a NULL that is not a conjunct hides nothing", ctx do
          m = sxc_ijf(ctx)

          for where <- ["j/0 = 1 OR null", "(j/0 = 1 AND null) OR j = 7"] do
            assert sxc_query(ctx, "SELECT i FROM #{m} WHERE #{where}") === @sxc_closed, where
          end
        end

        test "an operation with a NULL operand is NULL in a select list", ctx do
          m = sxc_ijf(ctx)

          assert sxc_rows(ctx, "SELECT i/0 + null AS x FROM #{m}") === [%{}, %{}, %{}]
          assert sxc_rows(ctx, "SELECT null + i/0 AS x FROM #{m}") === [%{}, %{}, %{}]

          assert sxc_rows(ctx, "SELECT i, j/0 * null AS x FROM #{m} ORDER BY i") ===
                   sxc_is([1, 2, 3])
        end

        @tag engine_bug: "closed connection"
        test "a constant that cannot be computed fails the query unless it is not planned",
             ctx do
          m = sxc_ijf(ctx)
          assert sxc_query(ctx, "SELECT i FROM #{m} WHERE 1/0 > 1") === @sxc_closed
          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE 1/0 > 1 LIMIT 0") === []
        end
      end
    end
  end

  # Two thousand rows of `i` from 1 and `j` from 0 to 99, which is 0 for every hundredth.
  defp batch_helpers do
    quote location: :keep do
      def sxc_batch(ctx) do
        m = sxc_name("sxc_batch")

        sxc_write(
          ctx,
          for(row <- 1..2000, do: "#{m} i=#{row}i,j=#{rem(row, 100)}i #{sxc_ns(row)}")
        )

        m
      end
    end
  end

  defp batch_tests do
    quote location: :keep do
      describe "SQL executor — contract: an AND or an OR over a batch of rows" do
        @tag local_divergence: "Local refuses what the engine answers by how a table is stored"
        @tag engine_bug: "closed connection"
        test "a right operand that fails for a row the left one leaves out (Local refuses it by name)",
             ctx do
          m = sxc_batch(ctx)

          for where <- [
                "j > 0 AND 100 / j > 1",
                "j <> 0 AND 100 / j > 1",
                "j = 0 OR 100 / j > 1"
              ] do
            sql = "SELECT count(*) AS c FROM #{m} WHERE #{where}"

            if sxc_local?() do
              assert sxc_error(ctx, sql) === sxc_batch_refusal(), where
            else
              assert sxc_query(ctx, sql) === @sxc_closed, where
            end
          end
        end

        @tag local_divergence: "Local refuses what the engine answers by how a table is stored"
        test "the engine answers when the left operand selects few rows", ctx do
          m = sxc_batch(ctx)
          sql = "SELECT count(*) AS c FROM #{m} WHERE j = 7 AND 100 / j > 1"

          if sxc_local?() do
            assert sxc_error(ctx, sql) === sxc_batch_refusal()
          else
            assert sxc_rows(ctx, sql) === [%{"c" => 20}]
          end
        end

        @tag engine_bug: "closed connection"
        test "a row the left operand selects, and the right one fails for, fails the query",
             ctx do
          m = sxc_batch(ctx)

          assert sxc_query(
                   ctx,
                   "SELECT count(*) AS c FROM #{m} WHERE j < 5 AND 100 / j > 1"
                 ) === @sxc_closed
        end
      end
    end
  end

  # Twenty rows, `k` from 0 to 19, host `h<k mod 4>` and region `r<k mod 2>` as tags; `total`
  # and `used` as floats, `ti` and `ui` as integers and `n` an integer. Rows 0 and 8 have a zero
  # `total`, `used`, `ti`, `ui` and `n`: they are two of the five rows of host h0 and of
  # region r0.
  # The ratio `used / total` of the others is `(k mod 4) / 4`.
  defp guard_helpers do
    quote location: :keep do
      def sxc_guard_rows do
        for k <- 0..19 do
          zero? = k in [0, 8]
          total = if zero?, do: 0.0, else: 100.0 * (1 + rem(k, 3))
          used = if zero?, do: 0.0, else: total * rem(k, 4) / 4

          %{
            k: k,
            host: "h#{rem(k, 4)}",
            region: "r#{rem(k, 2)}",
            total: total,
            used: used,
            n: if(zero?, do: 0, else: 1 + rem(k, 7))
          }
        end
      end

      def sxc_guard(ctx) do
        m = sxc_name("sxc_guard")
        float = &:erlang.float_to_binary(&1, decimals: 1)

        sxc_write(
          ctx,
          for row <- sxc_guard_rows() do
            "#{m},host=#{row.host},region=#{row.region} k=#{row.k}i,total=#{float.(row.total)}," <>
              "used=#{float.(row.used)},ti=#{trunc(row.total)}i,ui=#{trunc(row.used)}i," <>
              "n=#{row.n}i #{sxc_ns(row.k + 1)}"
          end
        )

        m
      end

      # The query for the `k` of the rows `where` keeps, and the response for the `k` in `ks`.
      def sxc_guard_sql(m, where), do: "SELECT k FROM #{m} WHERE #{where} ORDER BY k"
      def sxc_ks(ks), do: Enum.map(ks, &%{"k" => &1})
    end
  end

  defp guard_float_tests do
    quote location: :keep do
      describe "SQL executor — contract: a ratio a guard keeps the zero rows out of" do
        test "a division of floats by a total that is zero on two rows answers", ctx do
          m = sxc_guard(ctx)
          above = [3, 7, 11, 15, 19]
          positive = [1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15, 17, 18, 19]

          # Why this list: the guard idioms of a ratio (`<>`, `!=`, `IS NOT NULL`, `NOT`,
          # parentheses, a tag, a second guard), each with the rows 0 and 8, whose 0.0 / 0.0 is
          # a NaN, left out by `total`, in every shape the ratio can stand in: a comparison, a
          # product, `abs`, `round`, `ceil`, `floor`, `BETWEEN`, `IN`, `NOT IN`, `%`, `OR`, `NOT`.
          for {where, ks} <- [
                {"total > 0 AND used / total > 0.5", above},
                {"total <> 0 AND used / total > 0.5", above},
                {"total != 0 AND used / total * 100 > 50", above},
                {"total > 0 AND abs(used / total) > 0.5", above},
                {"total > 0 AND round(used / total, 2) > 0.5", above},
                {"total > 0 AND used / total BETWEEN 0.2 AND 0.8", positive},
                {"total > 0 AND used / total IN (0.5, 0.25)",
                 [1, 2, 5, 6, 9, 10, 13, 14, 17, 18]},
                {"total > 0 AND used / total NOT IN (0.5, 0.25)", [3, 4, 7, 11, 12, 15, 16, 19]},
                {"total > 0 AND used % total = 0", [4, 12, 16]},
                {"host = 'h1' AND used / total > 0.5", []},
                {"total IS NOT NULL AND total > 0 AND used / total > 0.5", above},
                {"total > 0 AND (used / total > 0.5 OR host = 'h0')",
                 [3, 4, 7, 11, 12, 15, 16, 19]},
                {"total > 0 AND NOT (used / total > 0.5)",
                 [1, 2, 4, 5, 6, 9, 10, 12, 13, 14, 16, 17, 18]},
                {"used > 0 AND used / total > 0.5", above},
                {"(total > 0) AND (used / total > 0.5)", above},
                {"total > 0.0 AND ceil(used / total) = 1", positive},
                {"NOT (total = 0) AND used / total > 0.5", above},
                {"total > 0 AND used / total * 100 BETWEEN 20 AND 80", positive},
                {"total > 0 AND floor(used / total * 10) = 5", [2, 6, 10, 14, 18]},
                {"host = 'h3' AND total > 0 AND used / total > 0.5", above},
                {"used / total > 0.5 AND host = 'h1'", []}
              ] do
            assert sxc_rows(ctx, sxc_guard_sql(m, where)) === sxc_ks(ks), where
          end
        end

        test "a NaN in a row the guard leaves out is not a failure", ctx do
          m = sxc_name("sxc_nan")

          sxc_write(ctx, [
            "#{m},host=h1 used=0.0,total=0i #{sxc_ns(1)}",
            "#{m},host=h1 used=5.0,total=2i #{sxc_ns(2)}",
            "#{m},host=h2 used=9.0,total=3i #{sxc_ns(3)}"
          ])

          # Why this list: the idioms of a ratio of a float by an integer that is zero on the
          # first row (0.0 / 0 is a NaN), each beside the guard that leaves that row out.
          for {where, used} <- [
                {"total > 0 AND used / total > 0.5", [5.0, 9.0]},
                {"total > 0 AND used / total * 100 > 50", [5.0, 9.0]},
                {"total > 0 AND host = 'h1'", [5.0]},
                {"total > 0 AND abs(used / total) > 0.5", [5.0, 9.0]},
                {"total > 0 AND round(used / total) > 0", [5.0, 9.0]},
                {"total > 0 AND used / total BETWEEN 0.5 AND 5", [5.0, 9.0]},
                {"total > 0 AND used / total IN (2.5, 3.0)", [5.0, 9.0]},
                {"total > 0 AND used % total = 0", [9.0]}
              ] do
            assert sxc_rows(ctx, "SELECT used FROM #{m} WHERE #{where} ORDER BY used") ===
                     Enum.map(used, &%{"used" => &1}),
                   where
          end
        end
      end
    end
  end

  defp guard_integer_tests do
    quote location: :keep do
      describe "SQL executor — contract: an integer division a guard keeps the zero rows out of" do
        test "a conjunct over tags keeps the zero rows out, wherever it stands", ctx do
          m = sxc_guard(ctx)
          h1 = [1, 5, 9, 13, 17]
          not_h0 = [1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15, 17, 18, 19]

          # Why this list: a tag compared, set, matched and ranged, in either order and beside
          # other conjuncts, with every zero row on a host or region the tag conjunct leaves out
          # (a conjunct over tags is applied by the scan, before the others, in a fresh write and
          # in a persisted table alike); a NULL in the set leaves every row out.
          for {where, ks} <- [
                {"host = 'h1' AND 100 / n > 1", h1},
                {"100 / n > 1 AND host = 'h1'", h1},
                {"host <> 'h0' AND 100 / n > 1", not_h0},
                {"100 / n > 1 AND host <> 'h0'", not_h0},
                {"host IN ('h1', 'h2') AND 100 / n > 1", [1, 2, 5, 6, 9, 10, 13, 14, 17, 18]},
                {"(host = 'h1' OR host = 'h3') AND 100 / n > 1",
                 [1, 3, 5, 7, 9, 11, 13, 15, 17, 19]},
                {"host LIKE 'h1%' AND 100 / n > 1", h1},
                {"region = 'r1' AND 100 / n > 1", [1, 3, 5, 7, 9, 11, 13, 15, 17, 19]},
                {"n > 0 AND host = 'h1' AND 100 / n > 1", h1},
                {"host = 'h1' AND n > 0 AND 100 / n > 1", h1},
                {"host = 'h1' AND ui * 100 / ti > 20", h1},
                {"host IN ('a', NULL) AND 100 / n > 1", []},
                {"host = 'zz' AND 100 / n > 1", []}
              ] do
            assert sxc_rows(ctx, sxc_guard_sql(m, where)) === sxc_ks(ks), where
          end
        end

        test "a guard on the divisor's own column that keeps no row leaves the division unrun",
             ctx do
          m = sxc_guard(ctx)

          for where <- ["n IS NULL AND 100 / n > 1", "n IS NULL AND 100 / n > 1 AND host = 'h1'"] do
            assert sxc_rows(ctx, sxc_guard_sql(m, where)) === [], where
          end
        end

        @tag engine_bug: "closed connection"
        test "a row the guard keeps, and the division fails for, fails the query", ctx do
          m = sxc_guard(ctx)

          # Why this list: the zero rows reach the division in every shape of guard.
          for where <- [
                "n < 5 AND 100 / n > 1",
                "n <= 0 AND 100 / n > 1",
                "host = 'h0' AND 100 / n > 1",
                "100 / n > 1 AND n < 5",
                "100 / n > 1 AND host = 'h0'",
                "100 / n > 1"
              ] do
            assert sxc_query(ctx, sxc_guard_sql(m, where)) === @sxc_closed, where
          end
        end

        @tag local_divergence: "Local refuses what the engine answers by how a table is stored"
        @tag engine_bug: "closed connection"
        test "a guard that leaves the zero rows out only by the order the engine runs them in (Local refuses it by name)",
             ctx do
          m = sxc_guard(ctx)

          # Why this list: a guard on a number, in every shape that keeps most rows, and the
          # other order. A fresh write runs the division over the whole batch when the guard
          # keeps over a fifth of it, and a persisted table runs the guard first when it reads
          # no more of the columns: so the same data fails freshly written and answers later.
          for where <- [
                "n > 0 AND 100 / n > 1",
                "n <> 0 AND 100 / n > 1",
                "n >= 1 AND 100 / n > 1",
                "NOT (n = 0) AND 100 / n > 1",
                "total > 0 AND ui * 100 / ti > 20",
                "ti >= 1 AND 1000 / ti > 0",
                "ti > 0 AND ui * 100 / ti > 20",
                "ui * 100 / ti > 20 AND ti > 0"
              ] do
            sql = sxc_guard_sql(m, where)

            if sxc_local?() do
              assert sxc_error(ctx, sql) === sxc_batch_refusal(), where
            else
              assert sxc_query(ctx, sql) === @sxc_closed, where
            end
          end
        end

        @tag local_divergence: "Local refuses what the engine answers by how a table is stored"
        @tag engine_bug: "closed connection"
        test "a NULL left of a division the engine may run over the zero rows closes the connection (Local refuses it by name)",
             ctx do
          m = sxc_guard(ctx)

          for where <- [
                "n NOT BETWEEN NULL AND 5 AND 100 / n > 1",
                "host = 'h1' AND NULL AND 100 / 0 > 1",
                "n = NULL AND 100 / 0 > 1"
              ] do
            sql = sxc_guard_sql(m, where)

            if sxc_local?() do
              assert sxc_error(ctx, sql) === sxc_batch_refusal(), where
            else
              assert sxc_query(ctx, sql) === @sxc_closed, where
            end
          end
        end
      end
    end
  end

  # Three rows of an integer, an unsigned integer and a float, the last with the largest unsigned.
  defp cast_range_helpers do
    quote location: :keep do
      def sxc_cast_range(ctx) do
        m = sxc_name("sxc_cr")

        sxc_write(ctx, [
          "#{m} v=1i,u=5u,f=1.5,i=1i #{sxc_ns(1)}",
          "#{m} v=2i,u=7u,f=2.5,i=2i #{sxc_ns(2)}",
          "#{m} v=3i,u=18446744073709551615u,f=3.5,i=3i #{sxc_ns(3)}"
        ])

        m
      end

      def sxc_engine_interval(sides, kind \\ "comparable"),
        do: {500, sxc_interval(sides, kind)}
    end
  end

  defp cast_range_tests do
    quote location: :keep do
      describe "SQL executor — contract: casts in the interval analysis" do
        @tag engine_bug: "DataFusion internal error"
        test "a cast of an integer column is removed when the literals fit its type", ctx do
          m = sxc_cast_range(ctx)

          for {where, sides} <- [
                {"CAST(v AS TINYINT) > 5 AND CAST(v AS TINYINT) < 3", "lhs:Null, rhs:Int64"},
                {"CAST(v AS TINYINT) < 3 AND CAST(v AS TINYINT) > 5", "lhs:Int64, rhs:Null"},
                {"CAST(v AS INT) > 5 AND v < 3", "lhs:Null, rhs:Int64"},
                {"v < 3 AND CAST(v AS INT) > 5", "lhs:Int64, rhs:Null"},
                {"CAST(CAST(v AS BIGINT) AS INT) > 5 AND v < 3", "lhs:Null, rhs:Int64"},
                {"CAST(v AS INT) BETWEEN 5 AND 3", "lhs:Null, rhs:Int64"},
                {"CAST(v AS INT) > 5 AND CAST(v AS SMALLINT) < 3", "lhs:Null, rhs:Int64"},
                {"CAST(v AS TINYINT) <= 5 AND v > 7", "lhs:Int64, rhs:Null"},
                {"CAST(v AS TINYINT) >= 7 AND CAST(v AS TINYINT) <= 5", "lhs:Null, rhs:Int64"},
                {"CAST(u AS BIGINT) > 5 AND CAST(u AS BIGINT) < 3", "lhs:Null, rhs:UInt64"},
                {"CAST(u AS TINYINT) > 5 AND CAST(u AS TINYINT) < 3", "lhs:Null, rhs:UInt64"}
              ] do
            assert sxc_error(ctx, "SELECT i FROM #{m} WHERE #{where}") ===
                     sxc_engine_interval(sides),
                   where
          end
        end

        test "a cast that stays says nothing", ctx do
          m = sxc_cast_range(ctx)

          # Why this list: each cast the optimizer keeps (a literal past its type, a float
          # column, a double, a float literal) or a pair of equalities, beside an empty range.
          for where <- [
                "CAST(v AS TINYINT) > 300 AND CAST(v AS TINYINT) < 3",
                "CAST(f AS INT) > 5 AND CAST(f AS INT) < 3",
                "CAST(v AS DOUBLE) > 5 AND CAST(v AS DOUBLE) < 3",
                "CAST(v AS INT) > 5.5 AND v < 3",
                "CAST(v AS INT) = 5 AND CAST(v AS INT) = 6",
                "CAST(v AS INT) > 5 AND CAST(v AS INT) < 3 AND i <> 4"
              ] do
            assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE #{where}") === [], where
          end

          assert sxc_rows(
                   ctx,
                   "SELECT i FROM #{m} WHERE CAST(v AS TINYINT) > 0 AND " <>
                     "CAST(v AS TINYINT) < 300 ORDER BY i"
                 ) === sxc_is([1, 2, 3])
        end

        test "an unsigned column's cast against a negative number is the Arrow kernel's error",
             ctx do
          m = sxc_cast_range(ctx)

          cast_null = fn type ->
            {500, "Arrow error: Cast error: Casting from #{type} to Null not supported"}
          end

          for {where, type} <- [
                {"CAST(u AS BIGINT) = -5", "Int64"},
                {"CAST(u AS BIGINT) <= -5", "Int64"},
                {"CAST(u AS BIGINT) < -5", "Int64"},
                {"CAST(u AS BIGINT) IN (-5)", "Int64"},
                {"CAST(u AS BIGINT) = -5.0", "Int64"},
                {"-5 = CAST(u AS BIGINT)", "Int64"},
                {"CAST(u AS INT) = -5", "Int32"},
                {"CAST(u AS TINYINT) = -5", "Int8"},
                {"CAST(u AS TINYINT) = -129", "Int8"}
              ] do
            assert sxc_error(ctx, "SELECT i FROM #{m} WHERE #{where}") === cast_null.(type), where
          end

          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE CAST(v AS TINYINT) = -5") === []
          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE CAST(u AS BIGINT) = -5 LIMIT 0") === []
          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE CAST(u AS BIGINT) = -5 AND false") === []
        end

        @tag engine_bug: "closed connection"
        test "the other comparisons of it close the connection", ctx do
          m = sxc_cast_range(ctx)

          for where <- [
                "CAST(u AS BIGINT) >= -5",
                "CAST(u AS BIGINT) > -5",
                "CAST(u AS BIGINT) BETWEEN -5 AND 3",
                "CAST(u AS BIGINT) NOT IN (-5)",
                "CAST(u AS BIGINT) = -5 OR i = 1"
              ] do
            assert sxc_query(ctx, "SELECT i FROM #{m} WHERE #{where}") === @sxc_closed, where
          end
        end

        @tag engine_bug: "DataFusion internal error"
        @tag local_divergence: "Local refuses by name what the engine fails in its analysis"
        test "beside another comparison the engine's analysis fails in its own way (Local refuses it by name)",
             ctx do
          m = sxc_cast_range(ctx)
          sql = "SELECT i FROM #{m} WHERE CAST(u AS BIGINT) = -5 AND i = 1"

          if sxc_local?() do
            assert sxc_error(ctx, sql) ===
                     sxc_refused(
                       "a negative number compared with a CAST of an unsigned column beside " <>
                         "another comparison, or over a CTE: the engine's answer is not " <>
                         "pinned down"
                     )
          else
            assert sxc_error(ctx, sql) ===
                     {500, sxc_interval("lhs:Null, rhs:Int64", "intersectable")}
          end
        end
      end
    end
  end

  defp division_range_tests do
    quote location: :keep do
      describe "SQL executor — contract: a division by zero in the interval analysis" do
        @tag engine_bug: "DataFusion internal error"
        test "an equality that divides an integer by zero fails the analysis", ctx do
          m = sxc_cast_range(ctx)

          for {where, sides, kind} <- [
                {"i = 1 AND 1/0 = 1", "lhs:Null, rhs:Int64", "intersectable"},
                {"i > 0 AND i < 5 AND 1/0 = 1", "lhs:Null, rhs:Int64", "comparable"},
                {"i < 5 AND i > 0 AND 1/0 = 1", "lhs:Int64, rhs:Null", "comparable"},
                {"i < 5 AND v > 0 AND 1/0 = 1", "lhs:Int64, rhs:Null", "comparable"},
                {"1/0 = 1 AND v > 0 AND i < 5", "lhs:Null, rhs:Int64", "comparable"},
                {"i > 0 AND i/0 = 1", "lhs:Null, rhs:Int64", "comparable"},
                {"i > 0 AND 1/0 IN (1)", "lhs:Null, rhs:Int64", "comparable"},
                {"i > 0 AND 1/0 = 1.5", "lhs:Null, rhs:Int64", "comparable"},
                {"i > 0 AND 1/(1-1) = 1", "lhs:Null, rhs:Int64", "comparable"},
                {"i > 0 AND 1/0 = 1 AND 2/0 = 2", "lhs:Null, rhs:Int64", "comparable"},
                {"f > 0 AND 1/0 = 1", "lhs:Null, rhs:Float64", "comparable"},
                {"u > 0 AND 1/0 = 1", "lhs:Null, rhs:UInt64", "comparable"}
              ] do
            assert sxc_error(ctx, "SELECT i FROM #{m} WHERE #{where}") ===
                     {500, sxc_interval(sides, kind)},
                   where
          end

          assert sxc_error(
                   ctx,
                   "SELECT i FROM #{m} WHERE i > 0 AND 1/0 = 1 ORDER BY i LIMIT 5"
                 ) === {500, sxc_interval("lhs:Null, rhs:Int64")}
        end

        @tag engine_bug: "closed connection"
        test "a comparison it cannot take, or a column it does not bound, closes it", ctx do
          m = sxc_cast_range(ctx)

          for where <- [
                "i > 0 AND v/0 = 1",
                "i > 0 AND i/0 + v = 1",
                "i > 0 AND 1/0 = 1 AND v <> 3",
                "i > 0 AND abs(1/0) = 1",
                "i > 0 AND 1/0 = 1 OR v = 3"
              ] do
            assert sxc_query(ctx, "SELECT i FROM #{m} WHERE #{where}") === @sxc_closed, where
          end

          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE i > 0 AND 1/0.0 = 1") === []
        end
      end
    end
  end

  defp bounds_arithmetic_tests do
    quote location: :keep do
      describe "SQL executor — contract: arithmetic on a column the analysis does not solve" do
        test "an unsigned column's arithmetic, or an integer's with a float, is no bound", ctx do
          m = sxc_cast_range(ctx)

          # Why this list: every operation on an unsigned column (a sum and a difference of
          # either order, a product, a quotient, the comparison operators and a float
          # literal) is a decimal's and is not solved; an integer column's with a float
          # constant is a float's. Beside a bound that leaves the column no value the
          # answer is the rows, none.
          for where <- [
                "u + 1 > 5 AND u < 3",
                "u - 1 > 5 AND u < 3",
                "1 + u > 5 AND u < 3",
                "u + 1 >= 5 AND u < 3",
                "u + 1 = 5 AND u < 3",
                "u + 1.5 > 5 AND u < 3",
                "u + 1 > 5.5 AND u < 3",
                "u * 2 > 100 AND u < 3",
                "u / 2 > 100 AND u < 3",
                "u + 0 > 100 AND u < 3",
                "u * 1 > 100.5 AND u < 3",
                "v + 1.5 > 5 AND v < 3",
                "v - 1.5 > 5 AND v < 3",
                "1.5 + v > 5 AND v < 3",
                "v * 2.5 > 100 AND v < 3",
                "v / 2.5 > 100 AND v < 3",
                "v * 1 > 100.5 AND v < 3"
              ] do
            assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE #{where}") === [], where
          end
        end

        @tag engine_bug: "DataFusion internal error"
        test "what the optimizer removes before the analysis leaves the bare column", ctx do
          m = sxc_cast_range(ctx)

          # Why this list: a product or quotient with the integer one (either order), a double
          # negation and parentheses, on each type; a float column's product with the float one.
          for {where, sides} <- [
                {"u * 1 > 100 AND u < 3", "lhs:Null, rhs:UInt64"},
                {"u / 1 > 100 AND u < 3", "lhs:Null, rhs:UInt64"},
                {"-(-u) > 100 AND u < 3", "lhs:Null, rhs:UInt64"},
                {"(u) > 100 AND u < 3", "lhs:Null, rhs:UInt64"},
                {"1 * v > 100 AND v < 3", "lhs:Null, rhs:Int64"},
                {"v * 1 > 100 AND v < 3", "lhs:Null, rhs:Int64"},
                {"v / 1 > 100 AND v < 3", "lhs:Null, rhs:Int64"},
                {"-(-v) > 100 AND v < 3", "lhs:Null, rhs:Int64"},
                {"(v) > 100 AND v < 3", "lhs:Null, rhs:Int64"},
                {"f * 1 > 100 AND f < 3", "lhs:Null, rhs:Float64"},
                {"f * 1.0 > 100 AND f < 3", "lhs:Null, rhs:Float64"},
                {"CAST(v AS BIGINT) + 1 > 100 AND v < 3", "lhs:Int64, rhs:Null"}
              ] do
            assert sxc_error(ctx, "SELECT i FROM #{m} WHERE #{where}") ===
                     {500, sxc_interval(sides)},
                   where
          end
        end
      end
    end
  end

  defp division_force_tests do
    quote location: :keep do
      describe "SQL executor — contract: a division by zero that forces a column" do
        @tag engine_bug: "DataFusion internal error"
        test "a column divided by zero is forced to zero: the bounds leave it out or not", ctx do
          m = sxc_cast_range(ctx)

          division =
            &{500, sxc_internal("Intervals must have the same data type for division, #{&1}")}

          # Why this list: the division before every comparison, with the comparisons that
          # leave 0 out (above it, below it, a bound that is exclusive at it, an equality, a
          # range, a set of one) and the types of the column; a comparison of another column
          # before the column's own; the body is the division's.
          for {where, sides} <- [
                {"v / 0 = 1 AND v > 0", "lhs:Null, rhs:Int64"},
                {"v / 0 = 1 AND v >= 1", "lhs:Null, rhs:Int64"},
                {"v / 0 = 1 AND v < 0", "lhs:Null, rhs:Int64"},
                {"v / 0 = 1 AND v <= -1", "lhs:Null, rhs:Int64"},
                {"v / 0 = 1 AND v = 3", "lhs:Null, rhs:Int64"},
                {"v / 0 IN (1) AND v > 0", "lhs:Null, rhs:Int64"},
                {"v / 0 = 5 AND v > 0", "lhs:Null, rhs:Int64"},
                {"v / 0 = 1 AND v > 0 AND v < 9", "lhs:Null, rhs:Int64"},
                {"v / 0 = 1 AND v BETWEEN 1 AND 5", "lhs:Null, rhs:Int64"},
                {"v / 0 = 1 AND u > 0 AND v > 0", "lhs:Null, rhs:Int64"},
                {"v / 0 = 1 AND NOT (v < 1)", "lhs:Null, rhs:Int64"},
                {"1 / 0 = 1 AND v / 0 = 1 AND v > 0", "lhs:Null, rhs:Int64"},
                {"CAST(v AS BIGINT) / 0 = 1 AND v > 0", "lhs:Null, rhs:Int64"},
                {"f / 0 = 1 AND f > 0", "lhs:Null, rhs:Float64"},
                {"f / 0.0 = 1 AND f > 0", "lhs:Null, rhs:Float64"}
              ] do
            assert sxc_error(ctx, "SELECT i FROM #{m} WHERE #{where}") === division.(sides),
                   where
          end
        end

        @tag engine_bug: "DataFusion internal error"
        test "a comparison before the division names its own interval", ctx do
          m = sxc_cast_range(ctx)

          # Why this list: the comparison first, of the column or of another; a sum with a
          # constant forces the column to another value (`(v + 1) / 0` to -1), and its body
          # is the first comparison's whichever stands first.
          for {where, sides} <- [
                {"v > 0 AND v / 0 = 1", "lhs:Null, rhs:Int64"},
                {"v < 9 AND v / 0 = 1 AND v > 0", "lhs:Int64, rhs:Null"},
                {"u > 0 AND v / 0 = 1 AND v > 0", "lhs:Null, rhs:UInt64"},
                {"f > 0 AND v / 0 = 1 AND v > 0", "lhs:Null, rhs:Float64"},
                {"(v + 1) / 0 = 1 AND v > 0", "lhs:Null, rhs:Int64"},
                {"(v + 1) / 0 = 1 AND v < -1", "lhs:Int64, rhs:Null"},
                {"(v + 1) / 0 = 1 AND v > -1", "lhs:Null, rhs:Int64"},
                {"(v - 1) / 0 = 1 AND v > 1", "lhs:Null, rhs:Int64"},
                {"(1 + v) / 0 = 1 AND v > 100", "lhs:Null, rhs:Int64"},
                {"f > 0 AND f / 0 = 1", "lhs:Null, rhs:Float64"}
              ] do
            assert sxc_error(ctx, "SELECT i FROM #{m} WHERE #{where}") ===
                     {500, sxc_interval(sides)},
                   where
          end
        end

        @tag engine_bug: "closed connection"
        test "a bound that leaves the forced value in is no failure of the analysis", ctx do
          m = sxc_cast_range(ctx)

          # Why this list: bounds that hold 0 (or -1 for a sum), in either order, a set of two,
          # a float literal that is no bound of an integer column, an unsigned column and a
          # bound of the integer column the analysis does not take.
          for where <- [
                "v / 0 = 1 AND v < 5",
                "v / 0 = 1 AND v >= 0",
                "v / 0 = 1 AND v <= 0",
                "v / 0 = 1 AND v > -1",
                "v / 0 = 1 AND v = 0",
                "v / 0 = 1 AND v BETWEEN -5 AND 5",
                "v / 0 = 1 AND v IN (1, 2)",
                "v / 0 = 1 AND v > 0.5",
                "v / 0 = 1 AND v > 0 AND v < 10 AND v <> 5",
                "v / 0 = 1 AND v * 2 > 0",
                "v / 0 = 1 AND i > 0 AND i < 5",
                "v >= 0 AND v / 0 = 1",
                "v < 5 AND v / 0 = 1",
                "v > -1 AND v / 0 = 1",
                "u / 0 = 1 AND u > 0",
                "u / 0 = 1 AND u >= 0",
                "(v + 1) / 0 = 1 AND v < 5",
                "(v + 1) / 0 = 1 AND v >= -1",
                "(v + 1) / 0 = 1 AND v > -2",
                "(v * 2) / 0 = 1 AND v < 100",
                "v % 0 = 1 AND v > 0",
                "v / 0 > 1 AND v > 0",
                "v / 0 + 1 > 1 AND v > 0"
              ] do
            assert sxc_query(ctx, "SELECT i FROM #{m} WHERE #{where}") === @sxc_closed, where
          end
        end

        test "a float column divided by zero, or an integer by a float zero, answers", ctx do
          m = sxc_cast_range(ctx)

          for where <- [
                "f / 0 = 1 AND f >= 0",
                "f / 0 = 1 AND f < 5",
                "f / 0 = 1",
                "f / 0 = 1 AND f > -1",
                "f >= 0 AND f / 0 = 1",
                "v / 0.0 = 1 AND v > 0",
                "v / 0.0 = 1 AND v >= 0",
                "v = 0 AND v / 0 = 1"
              ] do
            assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE #{where}") === [], where
          end
        end

        @tag local_divergence: "Local refuses what the engine fails in words it does not model"
        @tag engine_bug: "DataFusion internal error"
        test "a dividend of another shape, or an operation of the interval it does not model (Local refuses it by name)",
             ctx do
          m = sxc_cast_range(ctx)

          dividend =
            "a WHERE with an expression that divides by zero beside a dividend of a shape " <>
              "the analysis solves in its own words: the engine's answer is not pinned down"

          propagated =
            "a WHERE that may leave a numeric column no value, with an arithmetic comparison " <>
              "of a column that, with the other comparisons of it, leaves it no value: the " <>
              "engine's answer is not pinned down"

          for {where, local, engine} <- [
                {"2 * v / 0 = 1 AND v > 0", dividend,
                 "Intervals must have the same data type for multiplication, lhs:Int64, rhs:Null"},
                {"(v * 2) / 0 = 1 AND v > 100", dividend,
                 "Intervals must have the same data type for multiplication, lhs:Null, rhs:Int64"},
                {"-v / 0 = 1 AND v > 0", dividend,
                 "Can not run arithmetic negative on scalar value NULL"},
                {"v / 0 + 1 = 1 AND v > 0", dividend,
                 "Intervals must have the same data type for division, lhs:Null, rhs:Int64"},
                {"-v > 100 AND v > 0", propagated,
                 "Can not run arithmetic negative on scalar value NULL"},
                {"v * 2 > 100 AND v < 0", propagated,
                 "Intervals must have the same data type for multiplication, lhs:Null, rhs:Int64"},
                {"v < 3 AND v * 2 > 100", propagated,
                 "Only intervals with the same data type are comparable, lhs:Int64, rhs:Null"}
              ] do
            sql = "SELECT i FROM #{m} WHERE #{where}"

            if sxc_local?() do
              assert sxc_error(ctx, sql) === sxc_refused(local), where
            else
              assert sxc_error(ctx, sql) === {500, sxc_internal(engine)}, where
            end
          end
        end
      end
    end
  end

  defp decimal_literal_tests do
    quote location: :keep do
      describe "SQL executor — contract: a decimal compared with a float past what it holds" do
        test "a float that does not fit the decimal's type is the optimizer's error", ctx do
          m = sxc_unsigned(ctx)
          too_large = "is too large to store in a Decimal128 of precision"
          max35 = "Max is 99999999999999999999.999999999999999"
          max36 = "Max is 999999999999999999999.999999999999999"

          fit = fn digits, precision, max ->
            sxc_simplify("Invalid argument error: #{digits} #{too_large} #{precision}. #{max}")
          end

          for {where, expected} <- [
                {"u / 2 > 1.1e20", fit.("109999999999999992860.353903967862784", 35, max35)},
                {"u / 2 > 1e21", fit.("1000000000000000042420.637374017961984", 35, max35)},
                {"u / 2 > 1.7e23", fit.("169999999999999998061923.293023115935744", 35, max35)},
                {"1e21 < u / 2", fit.("1000000000000000042420.637374017961984", 35, max35)},
                {"u / 2 = 1e21", fit.("1000000000000000042420.637374017961984", 35, max35)},
                {"u / 2 <> 1e21", fit.("1000000000000000042420.637374017961984", 35, max35)},
                {"u / 2 BETWEEN 0 AND 1e21",
                 fit.("1000000000000000042420.637374017961984", 35, max35)},
                {"u / 2 IN (1, 1e21)", fit.("1000000000000000042420.637374017961984", 35, max35)},
                {"u / 2 > 1e21 AND false",
                 fit.("1000000000000000042420.637374017961984", 35, max35)},
                {"u / 2 > 1.0000000000000002e20",
                 fit.("100000000000000015310.110181627527168", 35, max35)},
                {"u % 3 > 1e21", fit.("1000000000000000042420.637374017961984", 35, max35)},
                {"u + 1 > 1e21", fit.("1000000000000000042420.637374017961984", 36, max36)},
                {"u - 1 > 1e21", fit.("1000000000000000042420.637374017961984", 36, max36)},
                {"u + 1 > 2e22", fit.("19999999999999999077525.316404242284544", 36, max36)},
                {"u / 2 < -1e21",
                 sxc_simplify(
                   "Invalid argument error: -1000000000000000042420.637374017961984 is too " <>
                     "small to store in a Decimal128 of precision 35. " <>
                     "Min is -99999999999999999999.999999999999999"
                 )},
                {"u + 1 < -1e21",
                 sxc_simplify(
                   "Invalid argument error: -1000000000000000042420.637374017961984 is too " <>
                     "small to store in a Decimal128 of precision 36. " <>
                     "Min is -999999999999999999999.999999999999999"
                 )}
              ] do
            assert sxc_error(ctx, "SELECT v FROM #{m} WHERE #{where}") === {500, expected}, where
          end

          assert sxc_error(ctx, "SELECT v FROM #{m} WHERE u / 2 > 1e21 LIMIT 0") ===
                   {500, fit.("1000000000000000042420.637374017961984", 35, max35)}
        end

        test "a float past the 127 bits of the decimal is the cast's error, named as written",
             ctx do
          m = sxc_unsigned(ctx)

          overflow = fn precision, text ->
            {500,
             sxc_simplify(
               "Cast error: Cannot cast to Decimal128(#{precision}, 15). Overflowing on #{text}"
             )}
          end

          for {where, expected} <- [
                {"u / 2 > 1.8e23", overflow.(35, "1.8e23")},
                {"u / 2 > 1.80e23", overflow.(35, "1.8e23")},
                {"u / 2 > 180000000000000000000000.0", overflow.(35, "1.8e23")},
                {"u / 2 > 1.7014118346046923e23", overflow.(35, "1.7014118346046924e23")},
                {"u / 2 > 1e300", overflow.(35, "1e300")},
                {"u / 2 > 1.7976931348623157e308", overflow.(35, "1.7976931348623157e308")},
                {"u / 2 < -1e300", overflow.(35, "-1e300")},
                {"u / 2 < -1.8e23", overflow.(35, "-1.8e23")},
                {"u / 2 > 1e400", overflow.(35, "inf")},
                {"u / 2 < -1e400", overflow.(35, "-inf")},
                {"u + 1 > 1e300", overflow.(36, "1e300")},
                {"u - 1 > 1e300", overflow.(36, "1e300")},
                {"u % 3 > 1e300", overflow.(35, "1e300")},
                {"u * 2 > 1e300", overflow.(38, "1e300")},
                {"u * 1 > 1e300", overflow.(38, "1e300")},
                {"u + 1 > 2e23", overflow.(36, "2e23")}
              ] do
            assert sxc_error(ctx, "SELECT v FROM #{m} WHERE #{where}") === expected, where
          end
        end

        test "a float the decimal holds, or a column that is not a decimal, compares", ctx do
          m = sxc_unsigned(ctx)

          for where <- [
                "u / 2 > 1e20",
                "u / 2 < -1e20",
                "u / 2 > 9.999999999999e19",
                "u / 2 > 100000000000000000001.0",
                "u + 1 > 5e20",
                "u + 1 > 9.99e20",
                "u * 1 > 1e21",
                "u / 2.0 > 1e21",
                "v / 2 > 1e21",
                "u > 1e21",
                "u > 1e300"
              ] do
            assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE #{where}") === [], where
          end

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE u / 2 > 1e-300 ORDER BY time") ===
                   [%{"v" => 3}, %{"v" => -4}]

          assert sxc_rows(ctx, "SELECT v FROM #{m} WHERE u / 2 > f ORDER BY time") ===
                   [%{"v" => -4}]
        end
      end
    end
  end

  defp decimal_refusal_tests do
    quote location: :keep do
      describe "SQL executor — contract: a decimal whose type the double does not know" do
        @tag local_divergence: "Local refuses a decimal whose precision it does not model"
        test "an expression whose precision the double does not know is refused", ctx do
          m = sxc_unsigned(ctx)

          for {where, precision} <- [
                {"u / 2 + 1 > 1e21", 36},
                {"-(u / 2) > 1e21", 35},
                {"abs(u / 2) > 1e21", 35}
              ] do
            sql = "SELECT v FROM #{m} WHERE #{where}"

            if sxc_local?() do
              assert sxc_error(ctx, sql) ===
                       sxc_refused(
                         "a decimal expression compared with a float past 1e20: the engine " <>
                           "fails its cast of the float to the expression's decimal type, " <>
                           "whose precision is modelled only for a plain `+`, `-`, `*`, `/` " <>
                           "or `%` of two columns or integers"
                       ),
                     where
            else
              max = if precision == 35, do: "99999999999999999999", else: "999999999999999999999"

              assert sxc_error(ctx, sql) ===
                       {500,
                        sxc_simplify(
                          "Invalid argument error: 1000000000000000042420.637374017961984 is " <>
                            "too large to store in a Decimal128 of precision #{precision}. " <>
                            "Max is #{max}.999999999999999"
                        )},
                     where
            end
          end
        end

        @tag engine_bug: "closed connection"
        @tag local_divergence: "Local refuses what the engine answers by closing the connection"
        test "a float column past what the decimal holds closes the connection (Local refuses it by name)",
             ctx do
          m = sxc_name("sxc_decf")
          sxc_write(ctx, ["#{m} u=5u,f=1.0e21 #{sxc_ns(1)}"])
          sql = "SELECT u FROM #{m} WHERE u / 2 > f"

          if sxc_local?() do
            assert sxc_error(ctx, sql) ===
                     sxc_refused(
                       "a decimal expression compared with a float past 1e20 in a column: " <>
                         "the engine fails its cast of the float to the decimal's type, past " <>
                         "a size that depends on the decimal's precision, which is not modelled"
                     )
          else
            assert sxc_query(ctx, sql) === @sxc_closed
          end
        end
      end
    end
  end

  defp wide_literal_tests do
    quote location: :keep do
      describe "SQL executor — contract: an integer past UInt64 is a double" do
        test "a UInt64 column compares with it as a Float64", ctx do
          m = sxc_name("sxc_wide")

          sxc_write(ctx, [
            "#{m} u=18446744073709551615u,n=1i #{sxc_ns(1)}",
            "#{m} u=18446744073709551614u,n=2i #{sxc_ns(2)}",
            "#{m} u=5u,n=3i #{sxc_ns(3)}"
          ])

          past = "18446744073709551616"
          big = [%{"n" => 1}, %{"n" => 2}]
          small = [%{"n" => 3}]

          for {where, expected} <- [
                {"u >= #{past}", big},
                {"u = #{past}", big},
                {"u IN (#{past})", big},
                {"u BETWEEN #{past} AND #{past}", big},
                {"#{past} <= u", big},
                {"#{past} = u", big},
                {"u > #{past}", []},
                {"u < #{past}", small},
                {"u <> #{past}", small},
                {"u NOT IN (#{past})", small},
                {"#{past} <> u", small},
                {"u <= #{past}", big ++ small},
                {"u BETWEEN 0 AND #{past}", big ++ small},
                {"u NOT BETWEEN 0 AND #{past}", []},
                {"u >= 18446744073709551617", big},
                {"u >= 18446744073709553664", big},
                {"u = 99999999999999999999999", []},
                {"u = 18446744073709551614.0", big},
                {"u = 18446744073709551615", [%{"n" => 1}]},
                {"u > 18446744073709551615", []}
              ] do
            assert sxc_rows(ctx, "SELECT n FROM #{m} WHERE #{where} ORDER BY n") === expected,
                   where
          end
        end
      end
    end
  end

  defp order_alias_tests do
    quote location: :keep do
      describe "SQL executor — contract: ORDER BY and the select list" do
        test "an expression in ORDER BY reads a select item's name as that item", ctx do
          m = sxc_ijf(ctx)
          a = fn rows -> Enum.map(rows, &%{"a" => &1}) end

          for {sql, expected} <- [
                {"SELECT i AS a FROM #{m} ORDER BY a+1", a.([1, 2, 3])},
                {"SELECT i AS a FROM #{m} ORDER BY -a", a.([3, 2, 1])},
                {"SELECT i AS a FROM #{m} ORDER BY abs(a)", a.([1, 2, 3])},
                {"SELECT i AS a FROM #{m} ORDER BY a*a DESC", a.([3, 2, 1])},
                {"SELECT i AS a FROM #{m} ORDER BY a+1 DESC", a.([3, 2, 1])},
                {"SELECT i AS a FROM #{m} ORDER BY i+1 DESC", a.([3, 2, 1])},
                {"SELECT i AS a FROM #{m} ORDER BY (a+1)*2", a.([1, 2, 3])},
                {"SELECT i AS a FROM #{m} ORDER BY CAST(a AS DOUBLE)", a.([1, 2, 3])},
                {"SELECT i + 1 AS a FROM #{m} ORDER BY a*2 DESC", a.([4, 3, 2])},
                {"SELECT i AS a FROM #{m} ORDER BY a+1, a DESC", a.([1, 2, 3])},
                {"SELECT i AS a, f FROM #{m} ORDER BY a+f",
                 [%{"a" => 3, "f" => -1.5}, %{"a" => 1, "f" => 1.5}, %{"a" => 2, "f" => 2.5}]},
                {"SELECT i AS a, f AS b FROM #{m} ORDER BY a+b DESC",
                 [%{"a" => 2, "b" => 2.5}, %{"a" => 1, "b" => 1.5}, %{"a" => 3, "b" => -1.5}]}
              ] do
            assert sxc_rows(ctx, sql) === expected, sql
          end
        end

        test "an output name beats a column of the same name in ORDER BY", ctx do
          m = sxc_ijf(ctx)

          assert sxc_rows(ctx, "SELECT i AS j FROM #{m} ORDER BY j+1") ===
                   [%{"j" => 1}, %{"j" => 2}, %{"j" => 3}]

          assert sxc_rows(ctx, "SELECT j AS i, i AS j FROM #{m} ORDER BY i+1") ===
                   [%{"i" => 0, "j" => 1}, %{"i" => 7, "j" => 3}, %{"i" => 50, "j" => 2}]
        end

        test "a name that is neither is the schema error, listing the output names first",
             ctx do
          m = sxc_ijf(ctx)

          assert sxc_error(ctx, "SELECT i AS a FROM #{m} ORDER BY a+b") ===
                   {500,
                    "Schema error: No field named b. Valid fields are a, #{m}.f, #{m}.i, " <>
                      "#{m}.j, #{m}.time."}
        end

        @tag local_divergence: "Local refuses a * beside other select items by name"
        test "a * beside other select items is refused, not counted as one item", ctx do
          m = sxc_ijf(ctx)

          dup = fn name, first, second ->
            {400,
             sxc_planning(
               ~s|Projections require unique expression names but the expression | <>
                 ~s|"#{m}.#{name}" at position #{first} and "#{m}.#{name}" at position | <>
                 ~s|#{second} have the same name. Consider aliasing ("AS") one of them.|
             )}
          end

          for {sql, expected} <- [
                {"SELECT *, i FROM #{m}", dup.("i", 1, 4)},
                {"SELECT *, i FROM #{m} ORDER BY 9", dup.("i", 1, 4)},
                {"SELECT i, * FROM #{m}", dup.("i", 0, 2)}
              ] do
            if sxc_local?() do
              assert sxc_error(ctx, sql) === sxc_refused("unsupported column: *"), sql
            else
              assert sxc_error(ctx, sql) === expected, sql
            end
          end
        end
      end
    end
  end

  defp linear_bounds_tests do
    quote location: :keep do
      describe "SQL executor — contract: arithmetic on a column in the interval analysis" do
        @tag engine_bug: "DataFusion internal error"
        test "an addition is read as a bound that comes after the others", ctx do
          m = sxc_ijf(ctx)

          for {where, sides} <- [
                {"f + 1 > 10 AND f < 3", "lhs:Float64, rhs:Null"},
                {"f - 1 > 10 AND f < 3", "lhs:Float64, rhs:Null"},
                {"i + 1 > 10 AND i < 3", "lhs:Int64, rhs:Null"}
              ] do
            assert sxc_error(ctx, "SELECT i FROM #{m} WHERE #{where}") ===
                     {500, sxc_interval(sides)},
                   where
          end
        end

        test "arithmetic that leaves a value, or no bound to meet, answers", ctx do
          m = sxc_ijf(ctx)

          for where <- [
                "f * 2 > 10 AND f < 100",
                "-f > 10 AND f < 3",
                "f * 2 > 10 AND j < 3",
                "f * 2 > 10 AND f * f < 3",
                "f * 2 > 10 AND f < 3 AND j <> 1"
              ] do
            assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE #{where}") === [], where
          end

          assert sxc_rows(
                   ctx,
                   "SELECT i FROM #{m} WHERE f * 1e308 * 1e308 > 1 AND f > 0 ORDER BY i"
                 ) ===
                   sxc_is([1, 2])

          assert sxc_rows(ctx, "SELECT i FROM #{m} WHERE f + j > 10 AND f < 3") === sxc_is([2])
        end

        @tag engine_bug: "DataFusion internal error"
        @tag local_divergence: "Local refuses what the engine fails in its interval analysis"
        test "a product, a quotient or a negation that leaves no value is the engine's own error (Local refuses it by name)",
             ctx do
          m = sxc_ijf(ctx)

          product = fn sides, kind ->
            sxc_internal("Intervals must have the same data type for #{kind}, #{sides}")
          end

          refusal =
            sxc_refused(
              "a WHERE that may leave a numeric column no value, with an arithmetic " <>
                "comparison of a column that, with the other comparisons of it, leaves it no " <>
                "value: the engine's answer is not pinned down"
            )

          for {where, body} <- [
                {"f * 2 > 10 AND f < 3", product.("lhs:Null, rhs:Float64", "multiplication")},
                {"f * 1e308 * 1e308 > 1 AND f < 0",
                 product.("lhs:Null, rhs:Float64", "multiplication")},
                {"i * 2 > 10 AND i < 3", product.("lhs:Null, rhs:Int64", "multiplication")},
                {"2 * f > 10 AND f < 3", product.("lhs:Float64, rhs:Null", "multiplication")},
                {"f / 2 > 10 AND f < 3", product.("lhs:Null, rhs:Float64", "division")},
                {"i / 2 > 10 AND i < 3", product.("lhs:Null, rhs:Int64", "division")},
                {"f * 2 > 10 AND f * 3 < 3", product.("lhs:Null, rhs:Float64", "multiplication")},
                {"-f > 10 AND f > 3",
                 sxc_internal("Can not run arithmetic negative on scalar value NULL")}
              ] do
            sql = "SELECT i FROM #{m} WHERE #{where}"

            if sxc_local?() do
              assert sxc_error(ctx, sql) === refusal, where
            else
              assert sxc_error(ctx, sql) === {500, body}, where
            end
          end
        end
      end
    end
  end

  defp scale_tests do
    quote location: :keep do
      describe "SQL executor — contract: the scale of round and trunc" do
        test "trunc reads its scale as an Int32, wrapping what does not fit", ctx do
          m = sxc_name("sxc_scale")
          sxc_write(ctx, ["#{m} f=3.25 #{sxc_ns(1)}"])

          for {scale, expected} <- [
                {"9223372036854775807", %{"r" => 0.0}},
                {"4294967296", %{"r" => 3.0}},
                {"2147483648", %{"r" => nil}},
                {"2147483647", %{"r" => nil}},
                {"308", %{"r" => nil}},
                {"100", %{"r" => 3.25}},
                {"-2147483648", %{"r" => nil}},
                {"-2147483649", %{"r" => nil}},
                {"-4294967296", %{"r" => 3.0}},
                {"-400", %{"r" => nil}}
              ] do
            assert sxc_rows(ctx, "SELECT trunc(f, #{scale}) AS r FROM #{m}") === [expected],
                   scale
          end
        end

        test "round keeps the scale and scales in doubles", ctx do
          m = sxc_name("sxc_round")
          sxc_write(ctx, ["#{m} f=3.25 #{sxc_ns(1)}"])

          for {scale, expected} <- [
                {"2147483647", %{"r" => nil}},
                {"-2147483648", %{"r" => nil}},
                {"308", %{"r" => nil}},
                {"100", %{"r" => 3.25}},
                {"290", %{"r" => 3.2500000000000004}},
                {"306", %{"r" => 3.2500000000000004}},
                {"303", %{"r" => 3.2499999999999996}},
                {"295", %{"r" => 3.25}},
                {"300", %{"r" => 3.25}},
                {"307", %{"r" => 3.25}}
              ] do
            assert sxc_rows(ctx, "SELECT round(f, #{scale}) AS r FROM #{m}") === [expected],
                   scale
          end
        end

        @tag engine_bug: "closed connection"
        test "round closes the connection for a scale past Int32", ctx do
          m = sxc_name("sxc_roundx")
          sxc_write(ctx, ["#{m} f=3.25 #{sxc_ns(1)}"])

          for scale <- [
                "9223372036854775807",
                "4294967296",
                "2147483648",
                "-2147483649",
                "-4294967296"
              ] do
            assert sxc_query(ctx, "SELECT round(f, #{scale}) AS r FROM #{m}") === @sxc_closed,
                   scale
          end
        end

        @tag engine_bug: "closed connection"
        test "a scale in a column is read the same way", ctx do
          m = sxc_name("sxc_colscale")

          sxc_write(ctx, [
            "#{m} f=3.25,i=2i #{sxc_ns(1)}",
            "#{m} f=3.25,i=4294967296i #{sxc_ns(2)}"
          ])

          assert sxc_rows(ctx, "SELECT trunc(f, i) AS r FROM #{m} ORDER BY time") ===
                   [%{"r" => 3.25}, %{"r" => 3.0}]

          assert sxc_query(ctx, "SELECT round(f, i) AS r FROM #{m}") === @sxc_closed
        end
      end
    end
  end
end
