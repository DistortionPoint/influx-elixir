defmodule InfluxElixir.Contract.SQLExpressions do
  @moduledoc """
  SQL expression contract tests, run against `InfluxElixir.Client.Local` and
  against a real InfluxDB 3 Core: WHERE boolean logic, ORDER BY and OFFSET,
  projected expressions, CTEs and schema errors, answered by the double exactly
  as by the engine (rows, error status and body). Every expectation here was
  read from a Core.

      use InfluxElixir.Contract.SQLExpressions, client: InfluxElixir.Client.Local, profile: :v3_core

  The `setup` callback must return `conn` and `database`, as
  for the shared contract. Every test writes its own table into the database
  the context gives it.

  ## Parts

  A module that generates the whole contract is slow to compile, so `part: part`
  generates one slice of it, for a module of its own that compiles and runs in
  parallel with its siblings. Without `:part` everything is generated.

    * `:where` — OR, NOT, LIKE, ILIKE, booleans, `%`, unary minus, comparands
    * `:order` — ORDER BY keys, nulls, positions, GROUP BY references, OFFSET
    * `:cte` — projected expressions, CTEs, InfluxQL NOT
  """

  @parts [:where, :order, :cte]

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    part = Keyword.get(opts, :part, :all)

    unless part == :all or part in @parts do
      raise ArgumentError,
            "unknown :part #{inspect(part)}, expected :all or one of #{inspect(@parts)}"
    end

    tests =
      for {test_part, block} <- test_blocks(client),
          part == :all or part == test_part,
          do: block

    quote location: :keep do
      (unquote_splicing([helpers(client) | tests]))
    end
  end

  # Every block of tests with the part it belongs to, in order.
  @spec test_blocks(Macro.t()) :: [{atom(), Macro.t()}]
  defp test_blocks(client) do
    [
      {:where, boolean_logic_tests(client)},
      {:where, comparand_tests(client)},
      {:where, operator_tests(client)},
      {:order, order_key_tests(client)},
      {:order, reference_tests(client)},
      {:order, offset_tests(client)},
      {:order, grouped_tests(client)},
      {:cte, projection_tests(client)},
      {:cte, influxql_tests(client)}
    ]
  end

  defp helpers(client) do
    quote location: :keep do
      # The tests of a part use some of these; none may warn when unused.
      def sxe_write(ctx, lines) do
        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, Enum.join(lines, "\n"),
                   database: ctx.database,
                   precision: :nanosecond
                 )

        InfluxElixir.ClientContract.settle(ctx)
      end

      def sxe_query(ctx, sql, opts \\ []) do
        unquote(client).query_sql(ctx.conn, sql, [database: ctx.database] ++ opts)
      end

      def sxe_rows(ctx, sql) do
        assert {:ok, rows} = sxe_query(ctx, sql)
        rows
      end

      def sxe_col(ctx, sql, key), do: ctx |> sxe_rows(sql) |> Enum.map(& &1[key])

      def sxe_error(ctx, sql) do
        assert {:error, %{status: status, body: body}} = sxe_query(ctx, sql)
        {status, body}
      end
    end
  end

  # Five hosts, two of them without a rack, for the WHERE logic.
  defp boolean_logic_tests(_client) do
    quote location: :keep do
      describe "SQL expressions — contract: WHERE OR, NOT, parentheses, LIKE" do
        setup ctx do
          sxe_write(ctx, [
            "m,host=a,rack=1 v=1.0,n=1i 1000000000",
            "m,host=b,rack=2 v=2.5,n=2i 2000000000",
            "m,host=c v=3.0,n=3i 3000000000",
            "m,host=d,rack=4 v=4.0,n=4i 4000000000",
            "m,host=e,rack=10 v=5.0,n=5i 5000000000"
          ])
        end

        test "AND binds tighter than OR, also beside IN", ctx do
          assert sxe_col(
                   ctx,
                   "SELECT host FROM m WHERE v > 3 OR v < 2 AND host = 'a' ORDER BY host",
                   "host"
                 ) === ["a", "d", "e"]

          assert sxe_col(
                   ctx,
                   "SELECT host FROM m WHERE host IN ('a', 'c') OR v = 4.0 ORDER BY host",
                   "host"
                 ) === ["a", "c", "d"]
        end

        test "NOT negates a predicate, an IS NULL test or an IN list", ctx do
          assert sxe_col(ctx, "SELECT host FROM m WHERE NOT host = 'a' ORDER BY host", "host") ===
                   ["b", "c", "d", "e"]

          assert sxe_col(ctx, "SELECT host FROM m WHERE NOT rack IS NULL ORDER BY host", "host") ===
                   ["a", "b", "d", "e"]

          assert sxe_col(
                   ctx,
                   "SELECT host FROM m WHERE host NOT IN ('a', 'b') AND v > 3 ORDER BY host",
                   "host"
                 ) === ["d", "e"]
        end

        test "_ in LIKE is one character", ctx do
          assert sxe_col(ctx, "SELECT host FROM m WHERE host LIKE '_' ORDER BY host", "host") ===
                   ["a", "b", "c", "d", "e"]

          assert sxe_col(ctx, "SELECT host FROM m WHERE rack LIKE '1%' ORDER BY host", "host") ===
                   ["a", "e"]
        end

        # Host c has no rack: LIKE '%' matches every text, and still not a null.
        test "a null never matches LIKE, not even '%'", ctx do
          assert sxe_col(ctx, "SELECT host FROM m WHERE rack LIKE '%' ORDER BY host", "host") ===
                   ["a", "b", "d", "e"]

          assert sxe_col(ctx, "SELECT host FROM m WHERE rack NOT LIKE '1%' ORDER BY host", "host") ===
                   ["b", "d"]
        end

        # rack is a tag: "1", "2", "4", "10". DataFusion keeps the column Utf8 and
        # renders the literal, so "10" sorts before "3" and "2" >= "10".
        test "a string column against a numeric literal compares the literal's text", ctx do
          assert sxe_col(
                   ctx,
                   "SELECT host FROM m WHERE rack BETWEEN 1 AND 3 ORDER BY host",
                   "host"
                 ) === ["a", "b", "e"]

          assert sxe_col(ctx, "SELECT host FROM m WHERE host > 1 ORDER BY host", "host") ===
                   ["a", "b", "c", "d", "e"]

          assert sxe_rows(ctx, "SELECT host FROM m WHERE host = 2") === []
        end

        test "keywords inside string literals are text", ctx do
          assert sxe_rows(ctx, "SELECT host FROM m WHERE host = 'x AND y' OR host = 'a'") ===
                   [%{"host" => "a"}]
        end
      end
    end
  end

  # Columns named like keywords, bare words in an IN list, arithmetic comparands.
  defp comparand_tests(_client) do
    quote location: :keep do
      describe "SQL expressions — contract: comparands and keyword-like names" do
        test "columns named offset and over are selectable; keywords in a literal are text",
             ctx do
          sxe_write(ctx, [
            ~s|m,tag=x offset=1i,over=2i,note="select from join" 1000000000|,
            ~s|m,tag=y offset=3i,over=4i,note="plain" 2000000000|
          ])

          assert sxe_rows(ctx, "SELECT offset, over FROM m ORDER BY time") ===
                   [%{"offset" => 1, "over" => 2}, %{"offset" => 3, "over" => 4}]

          assert sxe_rows(ctx, "SELECT tag FROM m WHERE note = 'select from join'") ===
                   [%{"tag" => "x"}]
        end

        test "a bare word in an IN list is a column reference", ctx do
          sxe_write(ctx, [
            "p,host=a,rack=2 v=1.0,other=1.0 1700000000000000000",
            "p,host=b,rack=4 v=2.0,other=5.0 1700000001000000000"
          ])

          assert sxe_error(ctx, "SELECT host FROM p WHERE host IN (a, b)") ===
                   {500,
                    "Schema error: No field named a. " <>
                      "Valid fields are p.host, p.other, p.rack, p.time, p.v."}

          assert sxe_col(ctx, "SELECT host FROM p WHERE v IN (1, other) ORDER BY host", "host") ===
                   ["a"]

          assert sxe_rows(ctx, "SELECT host FROM p WHERE v IN (other * 2)") === []

          assert sxe_col(ctx, "SELECT host FROM p WHERE rack IN (2, 4) ORDER BY host", "host") ===
                   ["a", "b"]

          assert sxe_col(ctx, "SELECT host FROM p WHERE host NOT IN ('a') ORDER BY host", "host") ===
                   ["b"]
        end

        test "constants with an alias in projections and aggregates", ctx do
          sxe_write(ctx, [
            "p,host=a v=1.0 1700000000000000000",
            "p,host=b v=2.0 1700000001000000000"
          ])

          assert sxe_rows(ctx, "SELECT 1 AS one FROM p LIMIT 1") === [%{"one" => 1}]

          assert sxe_rows(ctx, "SELECT host, 'x' AS label FROM p ORDER BY host") ===
                   [%{"host" => "a", "label" => "x"}, %{"host" => "b", "label" => "x"}]

          assert sxe_rows(ctx, "SELECT host, 0.0 AS volume FROM p GROUP BY host ORDER BY host") ===
                   [%{"host" => "a", "volume" => +0.0}, %{"host" => "b", "volume" => +0.0}]

          assert sxe_rows(ctx, "SELECT 0.0 AS volume, MAX(v) AS m FROM p") ===
                   [%{"volume" => +0.0, "m" => 2.0}]

          assert sxe_rows(
                   ctx,
                   "SELECT DATE_BIN(INTERVAL '1 minute', time) AS t, 0.0 AS volume, " <>
                     "MAX(v) AS m FROM p GROUP BY DATE_BIN(INTERVAL '1 minute', time)"
                 ) ===
                   [%{"volume" => +0.0, "m" => 2.0, "t" => ~U[2023-11-14 22:13:00.000000Z]}]
        end

        test "arithmetic on the left side of a WHERE comparison", ctx do
          sxe_write(ctx, [
            "p price=1.0,volume=10.0 1700000000000000000",
            "p price=2.5,volume=20.0 1700000010000000000",
            "p price=100.0,volume=1.0 1700000090000000000"
          ])

          assert sxe_rows(ctx, "SELECT price FROM p WHERE 2 * price > volume") ===
                   [%{"price" => 100.0}]
        end

        test "arithmetic on the right side of a WHERE comparison", ctx do
          sxe_write(ctx, [
            "p price=1.0,volume=10.0 1700000000000000000",
            "p price=2.5,volume=20.0 1700000010000000000",
            "p price=100.0,volume=1.0 1700000090000000000"
          ])

          assert sxe_col(
                   ctx,
                   "SELECT price FROM p WHERE price <= volume * 0.2 ORDER BY price",
                   "price"
                 ) ===
                   [1.0, 2.5]
        end
      end
    end
  end

  # NULL semantics, LIKE escapes, bare booleans, % and unary minus.
  defp operator_tests(_client) do
    quote location: :keep do
      describe "SQL expressions — contract: nulls and operators" do
        setup ctx do
          sxe_write(ctx, [
            ~s|t,host=a,rack=1 v=1.5,n=2i,s="alpha",b=true 1700000000000000000|,
            ~s|t,host=a,rack=2 v=-3.25,n=7i,s="Beta",b=false 1700000060000000000|,
            ~s|t,host=b,rack=1 v=10.0,n=-4i,s="gamma" 1700000120000000000|,
            "t,host=b n=0i,b=true 1700000180000000000",
            ~s|t,host=c,rack=3 v=0.5,s="al%pha" 1700000240000000000|
          ])
        end

        test "NOT over a comparison, NOT IN and NOT BETWEEN over a null drop the row", ctx do
          assert sxe_col(ctx, "SELECT host FROM t WHERE NOT (v > 0) ORDER BY time", "host") ===
                   ["a"]

          assert sxe_col(
                   ctx,
                   "SELECT host FROM t WHERE rack NOT IN ('1') ORDER BY time",
                   "host"
                 ) === ["a", "c"]

          assert sxe_col(
                   ctx,
                   "SELECT host FROM t WHERE v NOT BETWEEN 0 AND 2 ORDER BY time",
                   "host"
                 ) === ["a", "b"]

          assert sxe_col(
                   ctx,
                   "SELECT host FROM t WHERE v > 0 OR rack = '3' ORDER BY time",
                   "host"
                 ) === ["a", "b", "c"]
        end

        test "a backslash makes % and _ literal in ILIKE and in a pattern with no match", ctx do
          assert sxe_rows(ctx, ~S"SELECT s FROM t WHERE s ILIKE 'AL\%%'") === [%{"s" => "al%pha"}]
          assert sxe_rows(ctx, ~S"SELECT s FROM t WHERE s LIKE 'al\_ha'") === []
        end

        test "a bare boolean column is a predicate, alone and under AND", ctx do
          assert sxe_col(ctx, "SELECT host FROM t WHERE b ORDER BY time", "host") === ["a", "b"]
          assert sxe_rows(ctx, "SELECT host FROM t WHERE b AND n > 0") === [%{"host" => "a"}]
        end

        test "% keeps the dividend's sign and works on floats; unary minus negates", ctx do
          assert sxe_col(ctx, "SELECT n % 3 AS m FROM t ORDER BY time", "m") ===
                   [2, 1, -1, 0, nil]

          assert sxe_col(ctx, "SELECT v % 2 AS m FROM t ORDER BY time", "m") ===
                   [1.5, -1.25, 0.0, nil, 0.5]

          assert sxe_col(ctx, "SELECT -n AS x FROM t ORDER BY time", "x") === [-2, -7, 4, 0, nil]
          assert sxe_rows(ctx, "SELECT host FROM t WHERE -n > 0") === [%{"host" => "b"}]
        end
      end
    end
  end

  # Multi-key ORDER BY with nulls, and the order of sub-microsecond times.
  defp order_key_tests(_client) do
    quote location: :keep do
      describe "SQL expressions — contract: ORDER BY keys and nulls" do
        test "each key in turn, nulls per direction", ctx do
          sxe_write(ctx, [
            "sk,rack=b,host=h1 n=1i 1",
            "sk,rack=a,host=h2 n=2i 2",
            "sk,host=h3 n=3i 3",
            "sk,rack=a,host=h4 n=4i 4",
            "sk,rack=b,host=h9 n=5i 5",
            "sk,rack=a,host=h1 n=6i 6"
          ])

          order = fn sql -> sxe_col(ctx, sql, "n") end

          # rack ascending (nulls last), then host descending.
          assert order.("SELECT n FROM sk ORDER BY rack, host DESC") === [4, 2, 6, 5, 1, 3]

          # rack descending puts nulls first; NULLS LAST overrides it.
          assert order.("SELECT n FROM sk ORDER BY rack DESC, host") === [3, 1, 5, 6, 2, 4]

          assert order.("SELECT n FROM sk ORDER BY rack DESC NULLS LAST, host") ===
                   [1, 5, 6, 2, 4, 3]
        end

        test "NULLS LAST puts nulls last descending, and a null group sorts last", ctx do
          sxe_write(ctx, [
            "t,host=a,rack=1 v=1.5 1700000000000000000",
            "t,host=a,rack=2 v=2.5 1700000060000000000",
            "t,host=b,rack=1 v=3.5 1700000120000000000",
            "t,host=b v=4.5 1700000180000000000",
            "t,host=c,rack=3 v=5.5 1700000240000000000"
          ])

          assert sxe_col(ctx, "SELECT rack FROM t ORDER BY rack DESC NULLS LAST, time", "rack") ===
                   ["3", "2", "1", "1", nil]

          assert sxe_col(
                   ctx,
                   "SELECT rack, COUNT(*) AS c FROM t GROUP BY rack ORDER BY rack",
                   "rack"
                 ) === ["1", "2", "3", nil]
        end

        test "an output alias is an ORDER BY target and a source column need not be projected",
             ctx do
          sxe_write(ctx, [
            "p,host=a v=1.0 1700000000000000000",
            "p,host=b v=2.0 1700000001000000000"
          ])

          assert sxe_rows(ctx, "SELECT host AS h FROM p ORDER BY h DESC") ===
                   [%{"h" => "b"}, %{"h" => "a"}]

          assert sxe_rows(ctx, "SELECT host FROM p ORDER BY v DESC") ===
                   [%{"host" => "b"}, %{"host" => "a"}]

          assert sxe_rows(ctx, "SELECT COUNT(*) AS n FROM p ORDER BY n") === [%{"n" => 2}]
        end

        test "ORDER BY time DESC and an aliased time order points under a microsecond apart",
             ctx do
          sxe_write(ctx, [
            "o v=3i 1700000000000000300",
            "o v=1i 1700000000000000100",
            "o v=2i 1700000000000000200"
          ])

          assert sxe_col(ctx, "SELECT * FROM o ORDER BY time DESC", "v") === [3, 2, 1]
          assert sxe_col(ctx, "SELECT time AS t, v FROM o ORDER BY t", "v") === [1, 2, 3]
        end
      end
    end
  end

  # GROUP BY and ORDER BY by position and alias; DATE_BIN with grouping columns.
  defp reference_tests(_client) do
    quote location: :keep do
      describe "SQL expressions — contract: GROUP BY and ORDER BY references" do
        setup ctx do
          sxe_write(ctx, [
            "m,h=a v=1.5,n=2i 1700000000000000000",
            "m,h=b v=2.5,n=4i 1700000000123456789",
            "m,h=a v=3.5,n=6i 1700000090000000000"
          ])
        end

        test "DATE_BIN with a grouping column gives a row per bucket per value", ctx do
          expected = [
            %{"bucket" => ~U[2023-11-14 22:13:00.000000Z], "h" => "a", "c" => 1},
            %{"bucket" => ~U[2023-11-14 22:13:00.000000Z], "h" => "b", "c" => 1},
            %{"bucket" => ~U[2023-11-14 22:14:00.000000Z], "h" => "a", "c" => 1}
          ]

          select = "SELECT DATE_BIN(INTERVAL '1 minute', time) AS bucket, h, COUNT(v) AS c FROM m"

          InfluxElixir.TestSupport.Check.each_case(
            ["DATE_BIN(INTERVAL '1 minute', time), h", "bucket, h", "1, 2"],
            fn group ->
              assert sxe_rows(ctx, "#{select} GROUP BY #{group} ORDER BY bucket, h") === expected,
                     group
            end
          )
        end

        test "a select alias or a position names the grouping column", ctx do
          expected = [%{"host" => "a", "s" => 8}, %{"host" => "b", "s" => 4}]

          assert sxe_rows(ctx, "SELECT h AS host, SUM(n) AS s FROM m GROUP BY host ORDER BY host") ===
                   expected

          assert sxe_rows(ctx, "SELECT h AS host, SUM(n) AS s FROM m GROUP BY 1 ORDER BY 1") ===
                   expected
        end

        test "ORDER BY a position sorts by that select item", ctx do
          assert sxe_col(ctx, "SELECT h, v FROM m ORDER BY 2 DESC", "v") === [3.5, 2.5, 1.5]

          assert sxe_rows(ctx, "SELECT h, COUNT(v) AS c FROM m GROUP BY h ORDER BY 2 DESC") ===
                   [%{"h" => "a", "c" => 2}, %{"h" => "b", "c" => 1}]
        end
      end
    end
  end

  defp offset_tests(_client) do
    quote location: :keep do
      describe "SQL expressions — contract: LIMIT and OFFSET" do
        setup ctx do
          sxe_write(
            ctx,
            for {host, i} <- Enum.with_index(~w(a b c d e)) do
              "p,host=#{host} v=#{i + 1}i #{1_700_000_000_000_000_000 + i * 1_000_000_000}"
            end
          )
        end

        test "OFFSET 0 skips nothing; OFFSET skips the first rows of the order", ctx do
          assert sxe_col(ctx, "SELECT host FROM p ORDER BY time LIMIT 2 OFFSET 0", "host") ===
                   ["a", "b"]

          assert sxe_col(ctx, "SELECT host FROM p ORDER BY time LIMIT 2 OFFSET 1", "host") ===
                   ["b", "c"]
        end

        test "OFFSET applies to whole grouped rows and projected rows", ctx do
          assert sxe_rows(
                   ctx,
                   "SELECT host, COUNT(*) AS n FROM p GROUP BY host ORDER BY host " <>
                     "LIMIT 2 OFFSET 1"
                 ) === [%{"host" => "b", "n" => 1}, %{"host" => "c", "n" => 1}]

          assert sxe_rows(ctx, "SELECT v * 2 AS twice FROM p ORDER BY v LIMIT 2 OFFSET 2") ===
                   [%{"twice" => 6}, %{"twice" => 8}]
        end

        test "a short last page is what remains; past the last row is empty", ctx do
          assert sxe_col(ctx, "SELECT host FROM p ORDER BY time LIMIT 2 OFFSET 4", "host") ===
                   ["e"]

          assert sxe_col(ctx, "SELECT host FROM p ORDER BY time LIMIT 2 OFFSET 10", "host") === []
        end

        test "OFFSET needs no LIMIT and may come before it", ctx do
          assert sxe_col(ctx, "SELECT host FROM p ORDER BY time OFFSET 3", "host") === ["d", "e"]

          assert sxe_col(ctx, "SELECT host FROM p ORDER BY time OFFSET 3 LIMIT 1", "host") ===
                   ["d"]
        end

        test "OFFSET applies to DISTINCT rows", ctx do
          assert sxe_col(
                   ctx,
                   "SELECT DISTINCT host FROM p ORDER BY host LIMIT 2 OFFSET 2",
                   "host"
                 ) === ["c", "d"]
        end

        test "a negative OFFSET is the optimizer's planning error", ctx do
          assert sxe_error(ctx, "SELECT host FROM p LIMIT 2 OFFSET -1") ===
                   {400,
                    "Optimizer rule 'push_down_limit' failed\ncaused by\nError during " <>
                      "planning: OFFSET must be >=0, '-1' was provided"}
        end

        test "the reported pagination query", ctx do
          sql = """
          SELECT *
          FROM p
          WHERE time >= '2023-11-14T00:00:00Z'
            AND time < '2023-11-15T00:00:00Z'

          ORDER BY time DESC
          LIMIT 100
          OFFSET 1
          """

          assert sxe_col(ctx, sql, "host") === ["d", "c", "b", "a"]
        end
      end
    end
  end

  defp grouped_tests(_client) do
    quote location: :keep do
      describe "SQL expressions — contract: GROUP BY without an aggregate" do
        setup ctx do
          sxe_write(ctx, [
            "p,host=a v=1.0 1700000000000000000",
            "p,host=b v=2.0 1700000001000000000",
            "p,host=b v=5.0 1700000002000000000"
          ])
        end

        test "GROUP BY without an aggregate yields one row per group", ctx do
          assert sxe_rows(ctx, "SELECT host FROM p GROUP BY host ORDER BY host") ===
                   [%{"host" => "a"}, %{"host" => "b"}]

          assert sxe_rows(ctx, "SELECT host AS h FROM p GROUP BY host ORDER BY h DESC") ===
                   [%{"h" => "b"}, %{"h" => "a"}]
        end

        test "a projected column neither grouped nor aggregated is the planning error", ctx do
          date_bin =
            ~S|date_bin(IntervalMonthDayNano("IntervalMonthDayNano { months: 0, days: 0, | <>
              ~S|nanoseconds: 60000000000 }"),p.time), max(p.v)|

          InfluxElixir.TestSupport.Check.each_case(
            [
              {"SELECT host, v FROM p GROUP BY host", "v", "p.host"},
              {"SELECT host, MAX(v) AS m FROM p", "host", "max(p.v)"},
              {"SELECT host, DATE_BIN(INTERVAL '1 minute', time) AS t, MAX(v) AS m FROM p " <>
                 "GROUP BY DATE_BIN(INTERVAL '1 minute', time)", "host", date_bin}
            ],
            fn {sql, column, appears} ->
              assert sxe_error(ctx, sql) ===
                       {400,
                        "Error during planning: Column in SELECT must be in GROUP BY or an " <>
                          "aggregate function: While expanding wildcard, column \"p.#{column}\" " <>
                          "must appear in the GROUP BY clause or must be part of an aggregate " <>
                          "function, currently only \"#{appears}\" appears in the SELECT " <>
                          "clause satisfies this requirement"},
                     sql
            end
          )
        end

        test "ORDER BY is honoured on GROUP BY column aggregates", ctx do
          assert sxe_rows(ctx, "SELECT host, SUM(v) AS t FROM p GROUP BY host ORDER BY t DESC") ===
                   [%{"host" => "b", "t" => 7.0}, %{"host" => "a", "t" => 1.0}]

          assert sxe_rows(ctx, "SELECT COUNT(*) AS n FROM p GROUP BY host ORDER BY n") ===
                   [%{"n" => 1}, %{"n" => 2}]
        end
      end
    end
  end

  defp projection_tests(_client) do
    quote location: :keep do
      describe "SQL expressions — contract: projected expressions and CTEs" do
        setup ctx do
          sxe_write(ctx, [
            "q,provider=a bid=1.0,ask=3.0 1000000000",
            "q,provider=a bid=2.0,ask=4.0 61000000000",
            "q,provider=b bid=10.0 121000000000",
            "q,provider=b bid=5.0,ask=7.0 122000000000"
          ])
        end

        test "arithmetic in a projected column; a null operand omits the column", ctx do
          assert sxe_rows(ctx, "SELECT (bid + ask) / 2 AS mid, time FROM q ORDER BY time") ===
                   [
                     %{"mid" => 2.0, "time" => ~U[1970-01-01 00:00:01.000000Z]},
                     %{"mid" => 3.0, "time" => ~U[1970-01-01 00:01:01.000000Z]},
                     %{"time" => ~U[1970-01-01 00:02:01.000000Z]},
                     %{"mid" => 6.0, "time" => ~U[1970-01-01 00:02:02.000000Z]}
                   ]
        end

        test "an expression without AS alias is named as the engine names it", ctx do
          assert ctx
                 |> sxe_rows("SELECT bid * 2 FROM q")
                 |> Enum.sort_by(& &1["q.bid * Int64(2)"]) ===
                   [
                     %{"q.bid * Int64(2)" => 2.0},
                     %{"q.bid * Int64(2)" => 4.0},
                     %{"q.bid * Int64(2)" => 10.0},
                     %{"q.bid * Int64(2)" => 20.0}
                   ]
        end

        test "a CTE shadows nothing it does not name", ctx do
          sql = "WITH w AS (SELECT bid FROM q) SELECT * FROM q"
          assert ctx |> sxe_col(sql, "bid") |> Enum.sort() === [1.0, 2.0, 5.0, 10.0]

          assert sxe_rows(ctx, "WITH w AS (SELECT bid FROM q) SELECT COUNT(*) AS n FROM w") ===
                   [%{"n" => 4}]
        end

        test "table aliases and qualified columns are accepted in every clause", ctx do
          assert sxe_rows(ctx, "SELECT q.bid, q.time FROM q AS q ORDER BY q.time LIMIT 1") ===
                   [%{"bid" => 1.0, "time" => ~U[1970-01-01 00:00:01.000000Z]}]

          assert sxe_rows(
                   ctx,
                   "SELECT DATE_BIN(INTERVAL '1 minute', q.time) AS b, COUNT(*) AS n FROM q " <>
                     "GROUP BY DATE_BIN(INTERVAL '1 minute', q.time) ORDER BY b"
                 ) ===
                   [
                     %{"b" => ~U[1970-01-01 00:00:00.000000Z], "n" => 1},
                     %{"b" => ~U[1970-01-01 00:01:00.000000Z], "n" => 1},
                     %{"b" => ~U[1970-01-01 00:02:00.000000Z], "n" => 2}
                   ]

          # A qualifier-looking string literal is untouched.
          assert sxe_rows(ctx, "SELECT provider FROM q WHERE provider = 'q.x'") === []
        end
      end
    end
  end

  # NOT is no InfluxQL keyword.
  defp influxql_tests(client) do
    quote location: :keep do
      describe "SQL expressions — contract: InfluxQL WHERE NOT" do
        test "NOT is no InfluxQL keyword: the engine's parse error, with its position", ctx do
          sxe_write(ctx, ["o,h=x v=3i 1700000000000003000"])

          assert {:error,
                  %{
                    status: 400,
                    body:
                      "error in InfluxQL statement: parsing error: invalid InfluxQL " <>
                        "statement at pos 26. Parsing Error: Nom(\"h = 'x'\", Tag)"
                  }} =
                   unquote(client).query_influxql(ctx.conn, "SELECT v FROM o WHERE NOT h = 'x'",
                     database: ctx.database
                   )
        end
      end
    end
  end
end
