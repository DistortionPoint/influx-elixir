defmodule InfluxElixir.Contract.InfluxQLPlanner do
  @moduledoc """
  Contract tests for what the InfluxQL planner does with a statement, run
  against `InfluxElixir.Client.Local` and against a real InfluxDB 3 Core: the
  answers (rows, error status and body) the double must give exactly. Every
  expectation was read from InfluxDB 3 Core.

      use InfluxElixir.Contract.InfluxQLPlanner,
        client: InfluxElixir.Client.Local

  It covers comparisons of unsigned fields inside `OR`, regular expressions
  on string fields, the forms a `time` is compared with, `GROUP BY time` with
  `fill()`, `median`, `spread`, `stddev`, `count(distinct())` and arithmetic
  in the select list. A real server is shared between runs, so every
  measurement name is unique and every line is given a timestamp.
  """

  alias InfluxElixir.Contract.{
    InfluxQLAggregateCases,
    InfluxQLArithmeticCases,
    InfluxQLBucketCases,
    InfluxQLCallCases,
    InfluxQLDefectCases,
    InfluxQLFixCases,
    InfluxQLGlueCases,
    InfluxQLOrderCases,
    InfluxQLProjectionCases,
    InfluxQLShapeCases,
    InfluxQLShowCases,
    InfluxQLWhereCases
  }

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)

    quote location: :keep do
      import InfluxElixir.Contract.InfluxQLPlanner, only: [fixture: 2, raw: 3, outcome: 3]

      unquote(conditions(client))
      unquote(buckets(client))
      unquote(calls(client))
      unquote(shows(client))
      unquote(fixes(client))
      unquote(shapes(client))
      unquote(projections(client))
      unquote(orders(client))
      unquote(defects(client))
      unquote(glue(client))
      unquote(show_helpers(client))
      unquote(fix_helpers(client))
      unquote(helpers(client))
    end
  end

  defp conditions(client) do
    quote location: :keep do
      describe "InfluxQL conditions — contract" do
        setup ctx do
          names = %{
            "or" => InfluxElixir.IntegrationHelper.unique_name("ipl_or"),
            "re" => InfluxElixir.IntegrationHelper.unique_name("ipl_re"),
            "t" => InfluxElixir.IntegrationHelper.unique_name("ipl_t")
          }

          write(ctx, unquote(client), fixture(:where, names))
          {:ok, names: names}
        end

        test "an unsigned comparison combines with the rest of an OR", ctx do
          check_ids(ctx, "or", "i", InfluxQLWhereCases.unsigned_or())
        end

        test "a regular expression is matched against a string field", ctx do
          check_ids(ctx, "re", "n", InfluxQLWhereCases.string_regex())
        end

        test "a time is compared in the forms the planner reads", ctx do
          check_ids(ctx, "t", "v", InfluxQLWhereCases.times())
        end
      end
    end
  end

  defp buckets(client) do
    quote location: :keep do
      describe "InfluxQL GROUP BY time and the select list — contract" do
        setup ctx do
          names =
            for key <- ~w(m1 m2 m3 m4), into: %{} do
              {key, InfluxElixir.IntegrationHelper.unique_name("ipl_" <> key)}
            end

          write(ctx, unquote(client), fixture(:buckets, names))
          {:ok, names: names}
        end

        test "windows, bounds, offsets, series and fills of floats and integers", ctx do
          check_rows(ctx, InfluxQLBucketCases.buckets())
        end

        test "fills across buckets with no data", ctx do
          check_rows(ctx, InfluxQLBucketCases.gaps())
        end

        test "fills of integer, unsigned and string columns", ctx do
          check_rows(ctx, InfluxQLBucketCases.types())
        end

        test "fills of columns that are null in a bucket with other values", ctx do
          check_rows(ctx, InfluxQLBucketCases.partial())
        end

        test "median, spread, stddev, count(distinct()) and mixed select lists", ctx do
          check_rows(ctx, InfluxQLAggregateCases.aggregates())
        end

        test "arithmetic in the select list", ctx do
          check_rows(ctx, InfluxQLArithmeticCases.arithmetic())
        end

        test "a fill option the parser cannot read is its error at the option", ctx do
          for option <- ["foo", "", ~s("x"), "true"] do
            statement = bucket_statement(ctx, "fill(#{option})")
            at = String.length(String.replace(statement, ~r/fill\(.*$/, "fill("))

            assert outcome(unquote(client), ctx, statement) ===
                     {:error, 400,
                      "error in InfluxQL statement: parsing error: invalid FILL option, " <>
                        "expected NULL, NONE, PREVIOUS, LINEAR, or a number at pos #{at}"},
                   statement
          end
        end

        test "a fill that is more than an option leaves the statement from fill", ctx do
          for clause <- ["GROUP BY time(1m) fill(1,2)", "GROUP BY time(1m) fill(1e3)"] do
            statement = bucket_statement(ctx, clause)
            [before, _rest] = String.split(statement, "fill(", parts: 2)
            rest = String.slice(statement, String.length(before)..-1//1)

            assert outcome(unquote(client), ctx, statement) ===
                     {:error, 400,
                      "error in InfluxQL statement: parsing error: invalid InfluxQL " <>
                        "statement at pos #{String.length(before)}. Parsing Error: " <>
                        "Nom(#{inspect(rest)}, Tag)"},
                   statement
          end
        end

        test "a fill after LIMIT, or a second fill, is left over", ctx do
          for clause <- ["LIMIT 1 fill(0)", "fill(0) fill(1)"] do
            statement = "SELECT mean(usage) FROM #{ctx.names["m1"]} #{clause}"
            [before, _rest] = String.split(statement, "fill(0)", parts: 2)
            at = String.length(before) + if(String.ends_with?(clause, "fill(1)"), do: 8, else: 0)
            rest = String.slice(statement, at..-1//1)

            assert outcome(unquote(client), ctx, statement) ===
                     {:error, 400,
                      "error in InfluxQL statement: parsing error: invalid InfluxQL " <>
                        "statement at pos #{at}. Parsing Error: Nom(#{inspect(rest)}, Tag)"},
                   statement
          end
        end

        test "without a lower bound the buckets start at the first point and end now", ctx do
          # The server's clock decides which day it is: the days of the bounds of the
          # slack between this clock and the server's, taken round the query.
          slack = Map.get(ctx, :time_slack, 5)
          lowest = days_since_2024(-slack)

          assert {:ok, [first | rest]} =
                   InfluxElixir.Contract.InfluxQLPlanner.raw(
                     unquote(client),
                     ctx,
                     "SELECT mean(usage) FROM #{ctx.names["m2"]} GROUP BY time(1d)"
                   )

          highest = days_since_2024(slack)
          assert first["time"] === ~U[2024-01-01 00:00:00.000000Z]
          assert first["mean"] === 5.25
          assert Enum.all?(rest, &(map_size(Map.drop(&1, ["time", "iox::measurement"])) === 0))
          assert (length(rest) + 1) in lowest..highest
        end

        test "each series starts at its own first point, and LIMIT reads only what it keeps",
             ctx do
          statement =
            "SELECT mean(usage) FROM #{ctx.names["m2"]} GROUP BY time(1m), host LIMIT 2"

          assert outcome(unquote(client), ctx, statement) ===
                   [
                     {"2024-01-01 00:00:00", %{"host" => "a", "mean" => 1.0}},
                     {"2024-01-01 00:01:00", %{"host" => "a"}},
                     {"2024-01-01 00:07:00", %{"host" => "b", "mean" => 10.0}},
                     {"2024-01-01 00:08:00", %{"host" => "b"}}
                   ]
        end
      end
    end
  end

  defp calls(client) do
    quote location: :keep do
      describe "InfluxQL dimensions, transforms, selectors and wildcards — contract" do
        setup ctx do
          names = InfluxQLCallCases.names(InfluxElixir.IntegrationHelper.unique_name("ipc"))
          write(ctx, unquote(client), InfluxQLCallCases.fixture(names))
          {:ok, names: names}
        end

        test "GROUP BY dimensions, fill options, comments, SLIMIT and regular expressions", ctx do
          check_rows(ctx, InfluxQLCallCases.dimensions())
        end

        test "fill() over empty buckets and ranges of millions of buckets", ctx do
          check_rows(ctx, InfluxQLCallCases.fills())
        end

        test "derivative, difference, cumulative_sum, moving_average, elapsed and integral",
             ctx do
          check_rows(ctx, InfluxQLCallCases.transforms())
        end

        test "percentile, mode, top, bottom and the selectors of booleans", ctx do
          check_rows(ctx, InfluxQLCallCases.calls())
        end

        test "math functions of fields and aggregates", ctx do
          check_rows(ctx, InfluxQLCallCases.math())
        end

        test "a column the measurement lacks is null in a comparison, and false", ctx do
          check_rows(ctx, InfluxQLCallCases.where())
        end

        test "wildcards in the select list and measurements in FROM", ctx do
          check_rows(ctx, InfluxQLCallCases.wildcards())
        end

        test "a GROUP BY the parser cannot read is its error at its position", ctx do
          for {clause, error} <- InfluxQLCallCases.parse_errors() do
            prefix =
              "SELECT count(v) FROM #{ctx.names["k1"]} WHERE time >= '2024-01-01T00:00:00Z' "

            assert outcome(unquote(client), ctx, prefix <> clause) ===
                     {:error, 400,
                      InfluxQLCallCases.parse_error_body(byte_size(prefix), clause, error)},
                   clause
          end
        end

        @tag engine_bug: "closed connection"
        @tag local_divergence:
               "the engine breaks the connection of a fill that has no value to carry; Local refuses by name"
        test "what the engine answers by closing the connection", ctx do
          assert Enum.sort(Map.keys(InfluxQLCallCases.closed_reasons())) ===
                   Enum.sort(InfluxQLCallCases.closed())

          for template <- InfluxQLCallCases.closed() do
            statement = InfluxElixir.Contract.InfluxQLPlanner.statement(template, ctx.names)
            result = InfluxElixir.Contract.InfluxQLPlanner.raw(unquote(client), ctx, statement)

            if unquote(client) === InfluxElixir.Client.Local,
              do:
                assert(
                  InfluxElixir.Contract.InfluxQLPlanner.refused_as?(
                    result,
                    statement,
                    Map.fetch!(InfluxQLCallCases.closed_reasons(), template)
                  ),
                  statement
                ),
              else:
                assert(
                  result === {:error, {:connection_error, %Mint.TransportError{reason: :closed}}},
                  statement
                )
          end
        end
      end
    end
  end

  defp shows(client) do
    quote location: :keep do
      describe "InfluxQL SHOW statements — contract" do
        setup ctx do
          names =
            "ips"
            |> InfluxElixir.IntegrationHelper.unique_name()
            |> InfluxQLShowCases.names()
            |> Map.put("db", ctx.database)

          write(ctx, unquote(client), InfluxQLShowCases.fixture(names))
          {:ok, names: names}
        end

        test "SHOW MEASUREMENTS with WITH MEASUREMENT, WHERE, LIMIT, OFFSET and ON", ctx do
          check_show(ctx, InfluxQLShowCases.measurements())
        end

        test "SHOW TAG KEYS with FROM, WHERE, LIMIT, OFFSET and ON", ctx do
          check_show(ctx, InfluxQLShowCases.tag_keys())
        end

        test "SHOW FIELD KEYS with FROM, LIMIT, OFFSET and ON", ctx do
          check_show(ctx, InfluxQLShowCases.field_keys())
        end

        test "SHOW TAG VALUES with WITH KEY, WHERE, LIMIT, OFFSET and ON", ctx do
          check_show(ctx, InfluxQLShowCases.tag_values())
        end

        test "SHOW RETENTION POLICIES", ctx do
          check_show(ctx, InfluxQLShowCases.retention())
        end

        test "a SHOW statement the parser cannot read is its error at its position", ctx do
          check_show(ctx, InfluxQLShowCases.errors())
        end
      end
    end
  end

  defp fixes(client) do
    quote location: :keep do
      describe "InfluxQL arguments, overflow, wildcards, errors and SHOW conditions — contract" do
        setup ctx do
          names = InfluxQLFixCases.names(InfluxElixir.IntegrationHelper.unique_name("ipx"))
          write(ctx, unquote(client), InfluxQLFixCases.fixture(names))
          write(ctx, unquote(client), InfluxQLFixCases.show_fixture(names))
          {:ok, names: names}
        end

        test "durations and windows the planner refuses, and the order it refuses them in", ctx do
          check_fix(ctx, InfluxQLFixCases.planning_arguments())
        end

        test "floats that overflow are null, integers wrap, areas and spreads follow", ctx do
          check_fix(ctx, InfluxQLFixCases.overflow())
        end

        test "count, mode and elapsed over wildcards, regular expressions and *::tag", ctx do
          check_fix(ctx, InfluxQLFixCases.wildcards())
        end

        test "conditions the parser refuses, bare constants and top() of a tag", ctx do
          check_fix(ctx, InfluxQLFixCases.conditions())
        end

        test "a truncated GROUP, the offset of GROUP BY time() and count(distinct f)", ctx do
          check_fix(ctx, InfluxQLFixCases.parse_errors())
        end

        test "aggregates stamped with a time that holds a nanosecond", ctx do
          check_fix(ctx, InfluxQLFixCases.nanosecond_stamps())
        end

        @tag engine_bug: "closed connection"
        test "the percentile of an integer field with no value breaks the connection", ctx do
          check_fix(ctx, InfluxQLFixCases.closed_or_empty())
        end

        test "SHOW over a column the measurement lacks, and a condition that is no boolean",
             ctx do
          check_show_fix(ctx, InfluxQLFixCases.shows())
        end
      end
    end
  end

  defp shapes(client) do
    quote location: :keep do
      describe "InfluxQL times, arithmetic, wildcards, regular expressions and conditions — contract" do
        setup ctx do
          names = InfluxQLShapeCases.names(InfluxElixir.IntegrationHelper.unique_name("ipg"))
          write(ctx, unquote(client), InfluxQLShapeCases.fixture(names))
          {:ok, names: names}
        end

        test "aggregates of time beside fields, count() of nothing and fills of times", ctx do
          check_fix(ctx, InfluxQLShapeCases.aggregates())
        end

        test "the select list: time and string arithmetic, wildcards, aliases and arguments",
             ctx do
          check_fix(ctx, InfluxQLShapeCases.select())
        end

        test "conditions: strings that add, divisions by zero, abs(), signs and comments", ctx do
          check_fix(ctx, InfluxQLShapeCases.conditions())
        end

        test "SHOW over a measurement with no tag and a condition on time", ctx do
          check_fix(ctx, InfluxQLShapeCases.shows())
        end

        test "statements the double refused by name and now answers (shape)", ctx do
          check_fix(ctx, InfluxQLShapeCases.exact_answers())
        end

        @tag local_divergence:
               "what the engine answers and the double does not compute is refused by name"
        test "statements the double refuses by name, each for its own reason", ctx do
          check_refusals(
            ctx,
            InfluxQLShapeCases.refusals(),
            InfluxQLShapeCases.refusal_reasons()
          )
        end
      end
    end
  end

  defp projections(client) do
    quote location: :keep do
      describe "InfluxQL projections: names, windows and coercions — contract" do
        setup ctx do
          names =
            InfluxQLProjectionCases.names(InfluxElixir.IntegrationHelper.unique_name("ipj"))

          write(ctx, unquote(client), InfluxQLProjectionCases.fixture(names))
          {:ok, names: names}
        end

        test "an unsigned number beside a string, a boolean, a tag or the time", ctx do
          check_fix(ctx, InfluxQLProjectionCases.coercions())
        end

        test "a math function of a time beside an operand or a field", ctx do
          check_fix(ctx, InfluxQLProjectionCases.time_functions())
        end

        test "LIMIT and OFFSET count per selected column, under its name", ctx do
          check_fix(ctx, InfluxQLProjectionCases.windows())
        end

        test "the names of the columns, in the order of the select list", ctx do
          check_fix(ctx, InfluxQLProjectionCases.column_names())
        end

        test "the time in parentheses is a column of its own", ctx do
          check_fix(ctx, InfluxQLProjectionCases.parenthesised_time())
        end

        test "a column the measurement lacks beside a tag, a string or a boolean", ctx do
          check_fix(ctx, InfluxQLProjectionCases.absent_columns())
        end

        test "a tie of top() and bottom() in descending order goes to the later point", ctx do
          check_fix(ctx, InfluxQLProjectionCases.descending())
        end

        test "top() and bottom() beside arithmetic, and a function before a selector", ctx do
          check_fix(ctx, InfluxQLProjectionCases.selectors())
        end

        @tag local_divergence:
               "what the engine answers and the double does not compute is refused by name"
        test "statements the double refuses by name, each for its own reason", ctx do
          check_refusals(
            ctx,
            InfluxQLProjectionCases.refusals(),
            InfluxQLProjectionCases.refusal_reasons()
          )
        end
      end
    end
  end

  defp orders(client) do
    quote location: :keep do
      describe "InfluxQL ties, unsigned booleans, conditions that are no boolean and the order of errors — contract" do
        setup ctx do
          names = InfluxQLOrderCases.names(InfluxElixir.IntegrationHelper.unique_name("ipo"))
          write(ctx, unquote(client), InfluxQLOrderCases.fixture(names))
          {:ok, names: names}
        end

        test "a tie of top() and bottom() of a tag goes to the point whose own time is first",
             ctx do
          check_fix(ctx, InfluxQLOrderCases.ties())
        end

        test "an unsigned field against a boolean, and a tag over an unsigned field", ctx do
          check_fix(ctx, InfluxQLOrderCases.unsigned_booleans())
        end

        test "a condition that is no boolean, with and without tz() and beside a time", ctx do
          check_fix(ctx, InfluxQLOrderCases.non_boolean_conditions())
        end

        test "the errors of the projection come before those of the condition and the list",
             ctx do
          check_fix(ctx, InfluxQLOrderCases.expansion_order())
        end

        test "LIMIT and OFFSET of a column that is a quotient skip the null buckets", ctx do
          check_fix(ctx, InfluxQLOrderCases.quotient_windows())
        end

        @tag local_divergence:
               "what the engine answers and the double does not compute is refused by name"
        test "statements the double refuses by name, each for its own reason", ctx do
          check_refusals(
            ctx,
            InfluxQLOrderCases.refusals(),
            InfluxQLOrderCases.refusal_reasons()
          )
        end
      end
    end
  end

  defp defects(client) do
    quote location: :keep do
      describe "InfluxQL clauses in order, the planner's order of errors and the operands of AND and OR — contract" do
        setup ctx do
          names = InfluxQLDefectCases.names(InfluxElixir.IntegrationHelper.unique_name("ipd"))
          write(ctx, unquote(client), InfluxQLDefectCases.fixture(names))
          {:ok, names: names}
        end

        test "clauses are read in their order, and the first that does not read is the error",
             ctx do
          check_fix(ctx, InfluxQLDefectCases.clause_order())
        end

        test "the errors of rewriting the statement come before those of the planner", ctx do
          check_fix(ctx, InfluxQLDefectCases.rewriting())
        end

        test "the planner's errors of the condition and of the select list, in its order", ctx do
          check_fix(ctx, InfluxQLDefectCases.planner_order())
        end

        test "a select list that reads no field is answered empty, whatever the condition", ctx do
          check_fix(ctx, InfluxQLDefectCases.no_field())
        end

        test "the aggregates of a tag, alone, in arithmetic and beside fields", ctx do
          check_fix(ctx, InfluxQLDefectCases.tag_aggregates())
        end

        test "fill() with a number, of a text column, a selector and a raw select", ctx do
          check_fix(ctx, InfluxQLDefectCases.fills())
        end

        test "fill() in or behind a condition, GROUP BY beside one, constants beside bare operands",
             ctx do
          check_fix(ctx, InfluxQLDefectCases.clause_tail())
        end

        test "every pair of kinds of operand of AND and OR, and chains and groups of three",
             ctx do
          check_fix(ctx, InfluxQLDefectCases.connectives())
        end

        test "an operand or a call's arguments that do not read fail where the parser stops",
             ctx do
          check_fix(ctx, InfluxQLDefectCases.parse_errors())
        end

        test "lexer errors, blanks, dotted names and operand characters: the leftmost error",
             ctx do
          check_fix(ctx, InfluxQLDefectCases.lexing())
        end

        test "keywords against non-blank characters, SHOW words, AND and OR as names, and what follows tz() or a dot",
             ctx do
          check_fix(ctx, InfluxQLDefectCases.blanks())
        end

        test "the pattern .* is answered as the expression reads, not rewritten", ctx do
          check_fix(ctx, InfluxQLDefectCases.any_regex())
        end

        test "statements the double refused by name and now answers (defects)", ctx do
          check_fix(ctx, InfluxQLDefectCases.exact_answers())
        end

        @tag local_divergence:
               "what the engine answers and the double does not compute is refused by name"
        test "statements the double refuses by name, each for its own reason", ctx do
          check_refusals(
            ctx,
            InfluxQLDefectCases.refusals(),
            InfluxQLDefectCases.refusal_reasons()
          )
        end
      end
    end
  end

  defp glue(client) do
    quote location: :keep do
      describe "InfluxQL keywords against the next character, and strings never closed — contract" do
        setup ctx do
          names = InfluxQLGlueCases.names(InfluxElixir.IntegrationHelper.unique_name("ipq"))
          write(ctx, unquote(client), InfluxQLGlueCases.fixture(names))
          {:ok, names: names}
        end

        test "a keyword directly against a parenthesis, sign, slash, quote or `*`, a quote never closed where no token is read, and tz() where an operand is wanted",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.forms())
        end

        test "a clause keyword, AS or ON directly against the next character, and parentheses of a WHERE nested",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.keyword_glue())
        end

        test "a regular expression for columns directly against FROM, AS or an operator", ctx do
          check_fix(ctx, InfluxQLGlueCases.regex_columns())
        end

        test "a :: with a type the engine does not know, glued to FROM or not", ctx do
          check_fix(ctx, InfluxQLGlueCases.casts())
        end

        test "a text that starts with no statement keyword, SELECT and SHOW against a character, and a text with no statement",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.statement_start())
        end

        test "SHOW directly against a character that is no blank",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.show_glue())
        end

        test "the list of sources after FROM: names, commas, dots, and a measurement named twice",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.sources())
        end

        test "text no clause starts at, before a clause or between two, and a keyword with a blank and no number after it",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.clause_junk())
        end

        test "time against a character, dotted dimensions, and the boundary of a type",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.group_by_names())
        end

        test "junk in the select list: operators with no operand, characters that start none, reserved words against a character, junk after an alias",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.select_junk())
        end

        test "a column compared with a condition in parentheses",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.nested_conditions())
        end

        test "a column the measurement lacks with fill(number), beside the time, over a measurement that does not exist, and in the name of a column",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.absent_columns())
        end

        test "a time the planner cannot read before the stack of a bare operand breaks",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.timestamps())
        end

        test "GROUP BY time() of an expression, or that does not close",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.time_calls())
        end

        test "an aggregate of a column the measurement lacks, in buckets or a window, and the statements the double refuses by name for it",
             ctx do
          check_fix(ctx, InfluxQLGlueCases.window_absent())
        end

        test "statements the double refused by name and now answers (glue)", ctx do
          check_fix(ctx, InfluxQLGlueCases.exact_answers())
        end

        @tag local_divergence:
               "what the engine answers and the double does not compute is refused by name"
        test "statements the double refuses by name, each for its own reason", ctx do
          check_refusals(
            ctx,
            InfluxQLGlueCases.refusals(),
            InfluxQLGlueCases.refusal_reasons()
          )
        end
      end
    end
  end

  defp show_helpers(client) do
    quote location: :keep do
      defp check_show_fix(ctx, cases) do
        InfluxElixir.TestSupport.Check.check_cases(cases, fn {template, expected} ->
          statement = InfluxElixir.Contract.InfluxQLPlanner.statement(template, ctx.names)

          actual =
            case InfluxElixir.Contract.InfluxQLPlanner.raw(unquote(client), ctx, statement) do
              {:ok, rows} ->
                rows

              {:error, %{status: status, body: body}} ->
                {:error, status,
                 InfluxElixir.Contract.InfluxQLPlanner.template_positions(
                   body,
                   statement,
                   ctx.names
                 )}
            end

          expected = InfluxElixir.Contract.InfluxQLPlanner.fill_names(expected, ctx.names)

          if actual === expected,
            do: :ok,
            else: {:mismatch, %{expected: expected, actual: actual}}
        end)
      end

      defp check_show(ctx, cases) do
        for {template, expected} <- cases do
          statement = InfluxElixir.Contract.InfluxQLPlanner.statement(template, ctx.names)

          actual =
            case InfluxElixir.Contract.InfluxQLPlanner.raw(unquote(client), ctx, statement) do
              {:ok, rows} -> rows
              {:error, %{status: status, body: body}} -> {:error, status, body}
            end

          assert actual === InfluxElixir.Contract.InfluxQLPlanner.fill_names(expected, ctx.names),
                 statement
        end
      end
    end
  end

  defp fix_helpers(client) do
    quote location: :keep do
      # The statements the double refuses by name: the engine answers each as the table says;
      # the double refuses it for the reason pinned (a statement with no pinned reason, one
      # refused for another reason and one now answered all fail naming the statement), and a
      # reason pinned for a statement the table does not hold fails as well.
      defp check_refusals(ctx, cases, reasons) do
        templates = Enum.map(cases, &elem(&1, 0))

        assert Enum.sort(Map.keys(reasons)) === Enum.sort(templates),
               "the pinned reasons and the refusals are not the same statements"

        InfluxElixir.TestSupport.Check.check_cases(cases, fn {template, expected} ->
          statement = InfluxElixir.Contract.InfluxQLPlanner.statement(template, ctx.names)

          actual =
            InfluxElixir.Contract.InfluxQLPlanner.fix_outcome(unquote(client), ctx, statement)

          expected = InfluxElixir.Contract.InfluxQLPlanner.fill_names(expected, ctx.names)
          reason = Map.fetch!(reasons, template)

          cond do
            unquote(client) !== InfluxElixir.Client.Local and actual === expected ->
              :ok

            unquote(client) === InfluxElixir.Client.Local and
                InfluxElixir.Contract.InfluxQLPlanner.refused_as?(actual, statement, reason) ->
              :ok

            true ->
              {:mismatch, %{expected: expected, actual: actual, refused_as: reason}}
          end
        end)
      end

      defp check_fix(ctx, cases) do
        InfluxElixir.TestSupport.Check.check_cases(cases, fn {template, expected} ->
          statement = InfluxElixir.Contract.InfluxQLPlanner.statement(template, ctx.names)

          actual =
            InfluxElixir.Contract.InfluxQLPlanner.fix_outcome(unquote(client), ctx, statement)

          expected = InfluxElixir.Contract.InfluxQLPlanner.fill_names(expected, ctx.names)

          if actual === expected,
            do: :ok,
            else: {:mismatch, %{expected: expected, actual: actual}}
        end)
      end
    end
  end

  defp helpers(client) do
    quote location: :keep do
      defp write(ctx, client, lines) do
        assert {:ok, :written} =
                 client.write(ctx.conn, Enum.join(lines, "\n"), database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)
      end

      defp check_ids(ctx, key, field, cases) do
        InfluxElixir.TestSupport.Check.check_cases(cases, fn {condition, expected} ->
          statement = "SELECT #{field} FROM #{ctx.names[key]} WHERE " <> condition

          actual =
            case raw(unquote(client), ctx, statement) do
              {:ok, rows} -> Enum.map(rows, & &1[field])
              {:error, %{status: status, body: body}} -> {:error, status, body}
            end

          if actual === expected,
            do: :ok,
            else: {:mismatch, %{expected: expected, actual: actual}}
        end)
      end

      defp check_rows(ctx, cases) do
        InfluxElixir.TestSupport.Check.check_cases(cases, fn {template, expected} ->
          statement = InfluxElixir.Contract.InfluxQLPlanner.statement(template, ctx.names)
          actual = outcome(unquote(client), ctx, statement)

          if actual === expected,
            do: :ok,
            else: {:mismatch, %{expected: expected, actual: actual}}
        end)
      end

      defp bucket_statement(ctx, clause) do
        "SELECT mean(usage) FROM #{ctx.names["m1"]} " <>
          "WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' " <>
          if(String.starts_with?(clause, "GROUP"),
            do: clause,
            else: "GROUP BY time(1m) " <> clause
          )
      end

      # The number of days from 2024-01-01 to the day it is `seconds` from now, both counted.
      defp days_since_2024(seconds) do
        DateTime.utc_now()
        |> DateTime.add(seconds, :second)
        |> DateTime.to_date()
        |> Date.diff(~D[2024-01-01])
        |> Kernel.+(1)
      end
    end
  end

  @doc false
  @spec statement(binary(), %{binary() => binary()}) :: binary()
  def statement(template, names) do
    Enum.reduce(names, template, fn {key, name}, acc -> String.replace(acc, "~" <> key, name) end)
  end

  @doc false
  @spec fill_names(term(), %{binary() => binary()}) :: term()
  def fill_names(text, names) when is_binary(text), do: statement(text, names)
  def fill_names(%DateTime{} = time, _names), do: time
  def fill_names(list, names) when is_list(list), do: Enum.map(list, &fill_names(&1, names))
  def fill_names(%{} = map, names), do: Map.new(map, fn {k, v} -> {k, fill_names(v, names)} end)

  def fill_names(tuple, names) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&fill_names(&1, names)) |> List.to_tuple()

  def fill_names(other, _names), do: other

  @doc false
  @spec raw(module(), map(), binary()) :: InfluxElixir.Client.query_result()
  def raw(client, ctx, statement),
    do: client.query_influxql(ctx.conn, statement, database: ctx.database)

  @doc """
  The answer of a statement as the cases write it: the rows as `{time,
  columns}` with the time as `YYYY-MM-DD HH:MM:SS`, or `{:error, status,
  body}`.
  """
  @spec outcome(module(), map(), binary()) ::
          [{binary(), map()}] | {:error, pos_integer(), binary()}
  def outcome(client, ctx, statement), do: client |> raw(ctx, statement) |> answered()

  defp answered({:ok, rows}) do
    for row <- rows do
      {time_text(row["time"]), row |> Map.delete("time") |> Map.delete("iox::measurement")}
    end
  end

  defp answered({:error, %{status: status, body: body}}), do: {:error, status, body}

  # A row whose time column is renamed (`time AS t`) has none under `time`: its time is
  # in the columns, and the row is stamped `nil`.
  defp time_text(nil), do: nil
  defp time_text(time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M:%S")

  @doc """
  Whether an answer is the double's refusal by name for `reason`: `Client.Local: <reason>`,
  with the statement after it when it is the parser that refuses.
  """
  @spec refused_as?(term(), binary(), binary()) :: boolean()
  def refused_as?({:error, %{status: 400, body: body}}, statement, reason),
    do: refused_as?({:error, 400, body}, statement, reason)

  def refused_as?({:error, 400, body}, statement, reason),
    do: body in ["Client.Local: " <> reason, "Client.Local: " <> reason <> ": " <> statement]

  def refused_as?(_answer, _statement, _reason), do: false

  @doc """
  `outcome/3`, or `:closed` for the connection the engine breaks mid-response.
  """
  @spec fix_outcome(module(), map(), binary()) ::
          [{binary(), map()}] | {:error, pos_integer(), binary()} | :closed
  def fix_outcome(client, ctx, statement) do
    case raw(client, ctx, statement) do
      {:error, {:connection_error, %Mint.TransportError{reason: :closed}}} ->
        :closed

      answer ->
        case answered(answer) do
          {:error, status, body} ->
            {:error, status, template_positions(body, statement, ctx.names)}

          rows ->
            rows
        end
    end
  end

  @doc """
  The positions of a parse error body (`at pos N`) counted as if every measurement name
  in the statement were its template placeholder (`~f1`, three characters): the
  measurements of a run have names of their own length, the cases are written once.

  The map from a position to the template's is not injective for a position inside a
  name, which is no position of the template: a wrong position there could be read as
  a right one. Such a position is reported as `within ~key`, which no case expects, so
  that it fails with the engine's own position in the message of the mismatch.
  """
  @spec template_positions(binary(), binary(), %{binary() => binary()}) :: binary()
  def template_positions(body, statement, names) do
    spans = name_spans(statement, names)

    Regex.replace(~r/ at pos (\d+)/, body, fn _all, digits ->
      pos = String.to_integer(digits)

      case Enum.find(spans, fn {start, length, _placeholder} ->
             pos > start and pos < start + length
           end) do
        {_start, _length, placeholder} ->
          " at pos within #{placeholder} (#{pos})"

        nil ->
          shift =
            for {start, length, placeholder} <- spans, start + length <= pos, reduce: 0 do
              shift -> shift + length - byte_size(placeholder)
            end

          " at pos #{pos - shift}"
      end
    end)
  end

  # Where each name stands in the statement, as `{start, length, placeholder}`, in
  # order. A name that is the start of another (the prefix a family of names shares)
  # is not read inside the longer one.
  defp name_spans(statement, names) do
    by_name = Map.new(names, fn {key, name} -> {name, "~" <> key} end)

    pattern =
      by_name
      |> Map.keys()
      |> Enum.sort_by(&{-byte_size(&1), &1})
      |> Enum.map_join("|", &Regex.escape/1)
      |> Regex.compile!()

    for [{start, length}] <- Regex.scan(pattern, statement, return: :index) do
      {start, length, Map.fetch!(by_name, binary_part(statement, start, length))}
    end
  end

  @doc false
  @spec fixture(:where | :buckets, %{binary() => binary()}) :: [binary()]
  def fixture(:where, names) do
    [or_m, re_m, t_m] = [names["or"], names["re"], names["t"]]

    [
      "#{or_m},h=a i=1i,j=-5i,u=3u 1000000000",
      "#{or_m},h=b i=2i,u=18446744073709551615u 2000000000",
      "#{or_m},h=c i=3i,u=0u 3000000000",
      "#{or_m},h=a i=-4i,u=9223372036854775808u 4000000000",
      ~s(#{re_m},h=a msg="m0",n=1i 1000000000),
      ~s(#{re_m},h=b msg="m1",n=2i 2000000000),
      ~s(#{re_m},h=c msg="m3",n=3i 3000000000),
      ~s(#{re_m},h=a msg="M3x",n=4i 4000000000),
      ~s(#{re_m},h=b n=5i 5000000000),
      ~s(#{re_m},h=c msg="a.b",n=6i 6000000000),
      ~s(#{re_m},h=c msg="",n=7i 7000000000),
      ~s(#{re_m},h=c msg="ab\\nc",n=8i 8000000000)
    ] ++
      for {iso, v} <-
            Enum.with_index(
              ~w(2023-12-31T23:00:00Z 2024-01-01T00:00:00Z 2024-01-01T00:00:05Z
                 2024-01-01T01:30:00Z 2024-01-01T02:00:00Z 2024-01-08T00:00:00Z),
              1
            ) do
        "#{t_m} v=#{v}i #{ns(iso)}"
      end
  end

  def fixture(:buckets, names) do
    [m1, m2, m3, m4] = [names["m1"], names["m2"], names["m3"], names["m4"]]

    [
      "#{m1},host=a usage=1.0,n=1i #{ns("2024-01-01T00:00:00Z")}",
      "#{m1},host=a usage=2.0,n=2i #{ns("2024-01-01T00:00:10Z")}",
      "#{m1},host=b usage=10.0,n=10i #{ns("2024-01-01T00:00:20Z")}",
      "#{m1},host=a usage=4.0,n=4i #{ns("2024-01-01T00:01:05Z")}",
      "#{m1},host=b usage=20.0,n=20i #{ns("2024-01-01T00:02:10Z")}",
      "#{m1},host=a usage=8.0,n=8i #{ns("2024-01-01T00:03:30Z")}",
      "#{m2},host=a usage=1.0,n=1i #{ns("2024-01-01T00:00:10Z")}",
      "#{m2},host=a usage=4.0,n=4i #{ns("2024-01-01T00:03:10Z")}",
      "#{m2},host=a usage=6.0,n=6i #{ns("2024-01-01T00:03:40Z")}",
      "#{m2},host=b usage=10.0,n=10i #{ns("2024-01-01T00:07:30Z")}",
      ~s(#{m3},host=a usage=1.0,n=1i,u=1u,s="x" #{ns("2024-01-01T00:00:10Z")}),
      ~s(#{m3},host=a usage=2.0,n=2i,u=2u,s="y" #{ns("2024-01-01T00:03:10Z")}),
      ~s(#{m3},host=a usage=9.0,n=-9i,u=9u,s="z" #{ns("2024-01-01T00:05:10Z")}),
      "#{m4},host=a a=1.0,b=10.0 #{ns("2024-01-01T00:00:10Z")}",
      "#{m4},host=a a=2.0 #{ns("2024-01-01T00:01:10Z")}",
      "#{m4},host=a b=30.0 #{ns("2024-01-01T00:03:10Z")}",
      "#{m4},host=a a=5.0,b=50.0 #{ns("2024-01-01T00:05:10Z")}"
    ]
  end

  @spec ns(binary()) :: integer()
  defp ns(iso) do
    {:ok, time, 0} = DateTime.from_iso8601(iso)
    DateTime.to_unix(time, :nanosecond)
  end
end
