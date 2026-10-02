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

  @doc false
  # The fields the engine lists in `Schema error: No field named ...`, each
  # `table.column` with a name that is not a lower case word quoted, a quote
  # doubled.
  @spec fields(binary(), [binary()]) :: [binary()]
  def fields(table, columns), do: Enum.map(columns, &(render(table) <> "." <> render(&1)))

  @doc false
  # The engine's message for a column it cannot find, exactly. `printed` is the
  # name as the engine prints it; `fields` the fields it lists, in its order:
  # for ORDER BY and GROUP BY the select list's own fields come first.
  @spec no_field(binary(), [binary()]) :: binary()
  def no_field(printed, fields),
    do: "Schema error: No field named #{printed}. Valid fields are #{Enum.join(fields, ", ")}."

  defp render(name) do
    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name),
      do: name,
      else: ~s("#{String.replace(name, "\"", "\"\"")}")
  end

  defp sql_parser_tests(client) do
    quote location: :keep do
      unquote(helpers(client))
      unquote(error_helpers())
      unquote(literal_tests())
      unquote(constant_tests())
      unquote(time_number_tests())
      unquote(time_string_tests())
      unquote(time_error_tests())
      unquote(time_aggregate_tests())
      unquote(limit_tests())
      unquote(function_tests())
      unquote(date_bin_tests())
      unquote(text_tests())
      unquote(escape_tests())
      unquote(identifier_tests())
      unquote(unaliased_tests())
      unquote(grouped_name_tests())
      unquote(time_range_tests())
      unquote(literal_type_tests())
      unquote(quoted_select_tests())
      unquote(valid_fields_tests())
      unquote(valid_fields_context_tests())
      unquote(time_zone_tests())
      unquote(leap_second_tests())
      unquote(small_fidelity_tests())
      unquote(parameter_tests())
      unquote(parameter_kind_tests())
      unquote(parameter_type_tests())
      unquote(request_param_tests())
    end
  end

  defp helpers(client) do
    quote location: :keep do
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

      defp sp_raw(ctx, sql, opts),
        do: unquote(client).query_sql(ctx.conn, sql, [database: ctx.database] ++ opts)

      defp sp_execute(ctx, sql, params),
        do: unquote(client).execute_sql(ctx.conn, sql, database: ctx.database, params: params)

      defp sp_local?, do: unquote(client) === InfluxElixir.Client.Local

      @sp_closed {:error, {:connection_error, %Mint.TransportError{reason: :closed}}}

      # The byte of the request body `Client.HTTP` sends at which the text of the
      # parameters up to `problem` ends, and whether `problem` is the last one.
      defp sp_params_read(ctx, sql, params, problem, format) do
        {:ok, normalized} = InfluxElixir.Client.QueryParams.normalize(params)

        body =
          InfluxElixir.Client.QueryParams.request_body(ctx.database, sql, normalized, format)

        keys = normalized |> Map.keys() |> Enum.sort()
        kept = Enum.take_while(keys, &(&1 <= problem))
        text = normalized |> Map.take(kept) |> Jason.encode!()
        {at, length} = :binary.match(body, binary_part(text, 1, byte_size(text) - 2))
        {at + length, problem === List.last(keys)}
      end
    end
  end

  # The words in which the engine refuses what it cannot plan.
  defp error_helpers do
    quote location: :keep do
      defp sp_coercion(message),
        do: "type_coercion\ncaused by\nError during planning: " <> message

      # Rust's Debug format escapes `"` and `\` inside the message.
      defp sp_tokenizer(message, line, column) do
        debug = message |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
        ~s|SQL error: TokenizerError("#{debug} at Line: #{line}, Column: #{column}")|
      end

      # What the optimizer's `simplify_expressions` pass says when it folds
      # a constant that Arrow cannot read.
      defp sp_optimizer(message),
        do: "Optimizer rule 'simplify_expressions' failed\ncaused by\nArrow error: " <> message

      defp sp_timestamp_error(text, reason),
        do: sp_optimizer("Parser error: Error parsing timestamp from '#{text}': #{reason}")

      defp sp_negative_zero?(value), do: is_float(value) and <<value::float>> === <<-0.0::float>>

      defp sp_fields(table, columns), do: InfluxElixir.Contract.SQLParser.fields(table, columns)

      defp sp_no_field(printed, fields),
        do: InfluxElixir.Contract.SQLParser.no_field(printed, fields)

      # What the engine says of a `WHERE` that leaves no instant of time.
      defp sp_boundaries,
        do:
          "External error: unexpected: provided filters on time column did not produce " <>
            "a valid set of boundaries"

      # The rows of the fixture most tests read: three points two minutes apart
      # in a tag, an integer, a float, a string and a boolean field.
      defp sp_fixture(ctx) do
        m = sp_measurement("sp_fix")

        sp_write(ctx, [
          ~s|#{m},h=a v=1i,f=1.5,s="x",b=true #{sp_ns(0)}|,
          ~s|#{m},h=b v=2i,f=2.5,s="y",b=false #{sp_ns(60)}|,
          ~s|#{m},h=a v=3i,f=3.5,s="z",b=true #{sp_ns(120)}|
        ])

        m
      end
    end
  end

  defp literal_tests do
    quote location: :keep do
      describe "SQL parsing — contract: string literals" do
        test "a doubled quote is one quote; a bound string is data, never SQL", ctx do
          m = sp_measurement("sp_quote")

          sp_write(ctx, [
            "#{m},name=O'Brien v=1 #{sp_ns(0)}",
            "#{m},name=Doe v=2 #{sp_ns(1)}",
            "#{m},name=q v=4 #{sp_ns(2)}"
          ])

          obrien = {:ok, [%{"name" => "O'Brien"}]}

          assert obrien === sp_query(ctx, "SELECT name FROM #{m} WHERE name = 'O''Brien'")
          assert obrien === sp_query(ctx, "SELECT name FROM #{m} WHERE name LIKE 'O''B%'")

          assert obrien ===
                   sp_query(ctx, "SELECT name FROM #{m} WHERE name = $n", %{n: "O'Brien"})

          hostile = "zzz' OR v > 0 OR name = 'q"

          assert {:ok, []} ===
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
    quote location: :keep do
      describe "SQL parsing — contract: constant predicates" do
        test "a comparison of literals, TRUE and FALSE", ctx do
          m = sp_measurement("sp_const")

          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}", "#{m} v=2 #{sp_ns(1)}"])

          all = {:ok, [%{"v" => 1.0}, %{"v" => 2.0}]}

          for where <- ["1 = 1", "true", "'a' = 'a'", "1 < 2.5", "NOT false"] do
            assert all === sp_query(ctx, "SELECT v FROM #{m} WHERE #{where} ORDER BY time"),
                   where
          end

          for where <- ["false", "1 = 2", "NOT true", "'a' > 'b'"] do
            assert {:ok, []} === sp_query(ctx, "SELECT v FROM #{m} WHERE #{where}"), where
          end
        end

        test "a lone literal that is not a boolean is a planning error", ctx do
          m = sp_measurement("sp_nonbool")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          for {where, shown, type} <- [
                {"1", "Int64(1)", "Int64"},
                {"1.5", "Float64(1.5)", "Float64"},
                {"1.0", "Float64(1)", "Float64"},
                {"0.0", "Float64(0)", "Float64"},
                {"-1.5", "Float64(-1.5)", "Float64"},
                {"1e20", "Float64(100000000000000000000)", "Float64"},
                {"1e-7", "Float64(0.0000001)", "Float64"},
                {"12345678.9", "Float64(12345678.9)", "Float64"},
                {"'a'", ~s|Utf8("a")|, "Utf8"}
              ] do
            assert sp_query(ctx, "SELECT v FROM #{m} WHERE #{where}") ===
                     {:error,
                      %{
                        status: 400,
                        body:
                          "Error during planning: Cannot create filter with non-boolean " <>
                            "predicate '#{shown}' returning #{type}"
                      }},
                   where
          end

          assert sp_query(ctx, "SELECT v FROM #{m} WHERE true AND v > 0") ===
                   {:ok, [%{"v" => 1.0}]}
        end
      end
    end
  end

  defp time_number_tests do
    quote location: :keep do
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
                {"time >= 1773748800000000000", "Timestamp(ns) >= Int64"},
                {"5 < time", "Int64 < Timestamp(ns)"}
              ] do
            expected =
              sp_coercion("Cannot infer common argument type for comparison operation " <> pair)

            assert sp_query(ctx, "SELECT v FROM #{m} WHERE #{where}") ===
                     {:error, %{status: 400, body: expected}},
                   where
          end

          assert sp_query(ctx, "SELECT v FROM #{m} WHERE time > '2023-11-14T22:13:19Z'") ===
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

            assert sp_query(ctx, sql, %{t: value}) ===
                     {:error, %{status: 400, body: expected}},
                   sql
          end
        end

        @tag local_divergence: "Local refuses a comparison in the select list by name"
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

          assert sp_query(ctx, "select time > $t as x from #{m}", %{t: 0}) ===
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
            assert sp_query(ctx, sql, params) === {:error, error}, sql
          end
        end
      end
    end
  end

  defp time_string_tests do
    quote location: :keep do
      describe "SQL parsing — contract: a string against time" do
        test "a parameter that is a timestamp string is an instant", ctx do
          m = sp_measurement("sp_timestr")
          sp_write(ctx, for(i <- 0..3, do: "#{m} v=#{i}i #{sp_ns(i)}"))
          at = fn n -> "2023-11-14T22:13:#{20 + n}Z" end
          select = "SELECT v FROM #{m} WHERE "

          assert sp_query(ctx, select <> "time >= $a AND time < $b ORDER BY time", %{
                   a: at.(1),
                   b: at.(3)
                 }) ===
                   {:ok, [%{"v" => 1}, %{"v" => 2}]}

          assert sp_query(ctx, select <> "time BETWEEN $a AND $b ORDER BY time", %{
                   a: at.(1),
                   b: at.(2)
                 }) ===
                   {:ok, [%{"v" => 1}, %{"v" => 2}]}

          assert sp_query(ctx, select <> "time IN ($a, $b) ORDER BY time", %{a: at.(1), b: at.(3)}) ===
                   {:ok, [%{"v" => 1}, %{"v" => 3}]}

          assert sp_query(ctx, select <> "$a < time", %{a: at.(2)}) === {:ok, [%{"v" => 3}]}
        end

        test "a null is unknown: no row, and NOT of it no row either", ctx do
          m = sp_measurement("sp_timenull")
          sp_write(ctx, for(i <- 0..2, do: "#{m} v=#{i}i #{sp_ns(i)}"))
          select = "SELECT v FROM #{m} WHERE "
          all = {:ok, [%{"v" => 0}, %{"v" => 1}, %{"v" => 2}]}
          old = "'2020-01-01'"

          for {where, params} <- [
                {"time = $a", %{a: nil}},
                {"time > $a", %{a: nil}},
                {"$a < time", %{a: nil}},
                {"time = NULL", nil},
                {"time IN (NULL)", nil},
                {"time IN ($a, #{old})", %{a: nil}},
                {"time NOT IN ($a, #{old})", %{a: nil}},
                {"time BETWEEN $a AND #{old}", %{a: nil}},
                {"time BETWEEN #{old} AND $a", %{a: nil}},
                {"time BETWEEN NULL AND NULL", nil},
                {"time NOT BETWEEN #{old} AND $a", %{a: nil}}
              ] do
            assert sp_query(ctx, select <> where, params) === {:ok, []}, where
          end

          # Unknown AND false is false, so the NOT of it keeps every row.
          assert sp_query(ctx, select <> "time NOT BETWEEN $a AND #{old} ORDER BY time", %{
                   a: nil
                 }) === all
        end

        test "an offset, a space, a lower case separator and UTC are timestamps", ctx do
          m = sp_measurement("sp_timezone")
          sp_write(ctx, for(i <- 0..1, do: "#{m} v=#{i}i #{sp_ns(i)}"))
          select = "SELECT v FROM #{m} WHERE time = "

          for text <- [
                "2023-11-14T23:13:20 +01:00",
                "2023-11-14T23:13:20+0100",
                "2023-11-14T23:13:20+01",
                "2023-11-14T21:13:20-01:00",
                "2023-11-14T22:13:20 UTC",
                "2023-11-14T22:13:20 GMT",
                "2023-11-14t22:13:20z",
                "2023-11-14 22:13:20",
                "2023-11-14T22:13:20.0000000009999Z",
                "2023-11-14T22:13:20.000000000999999999999Z"
              ] do
            assert sp_query(ctx, select <> "'#{text}'") === {:ok, [%{"v" => 0}]}, text
          end

          assert sp_query(ctx, "SELECT v FROM #{m} WHERE time > '2023-11-14T22:13:20.5Z'") ===
                   {:ok, [%{"v" => 1}]}
        end
      end
    end
  end

  defp time_error_tests do
    quote location: :keep do
      describe "SQL parsing — contract: a string that is not a timestamp" do
        test "a string that is not a timestamp is the optimizer's error, in Arrow's words",
             ctx do
          m = sp_measurement("sp_timebad")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])
          select = "SELECT v FROM #{m} WHERE "

          short = "timestamp must contain at least 10 characters"

          for {text, reason} <- [
                {"abc", short},
                {"", short},
                {"2024", short},
                {"2024-01-0", short},
                {"now()", short},
                {"2024-01-01x", "invalid timestamp separator"},
                {"2024-13-01", "error parsing date"},
                {"2024-02-30", "error parsing date"},
                {"abcdefghijkl", "error parsing date"},
                {"  2024-01-01  ", "error parsing date"},
                {"1700000000", "error parsing date"},
                {"2024-1-01T00:00:00", "error parsing date"},
                {"2024-01-01 25:00:00", "error parsing time"},
                {"2024-01-01T00:00", "error parsing time"},
                {"2024-01-01T00:00:00.", "error parsing time"},
                {"2024-01-01T0:00:00", "error parsing time"},
                {"2024-01-01T00:60:00", "error parsing time"}
              ] do
            assert sp_query(ctx, select <> "time > '#{text}'") ===
                     {:error, %{status: 500, body: sp_timestamp_error(text, reason)}},
                   text
          end

          for {text, zone} <- [
                {"2024-01-01T00:00:00Zjunk", "Zjunk"},
                {"2024-01-01T00:00:00+25:00", "+25:00"},
                {"2024-01-01T00:00:00+24:00", "+24:00"},
                {"2024-01-01T00:00:00 ", ""},
                {"2024-01-01T00:00:00 Z", "Z"},
                {"2024-01-01T00:00:00 +01:00 ", "+01:00 "}
              ] do
            assert sp_query(ctx, select <> "time > '#{text}'") ===
                     {:error,
                      %{
                        status: 500,
                        body:
                          sp_optimizer(
                            "Parser error: Invalid timezone \"#{zone}\": failed to parse timezone"
                          )
                      }},
                   text
          end
        end

        test "an instant outside the nanosecond range overflows, shown in UTC", ctx do
          m = sp_measurement("sp_timeover")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])
          select = "SELECT v FROM #{m} WHERE "

          overflow = fn shown ->
            sp_optimizer(
              "Cast error: Overflow converting #{shown} to Nanosecond. The dates that can be " <>
                "represented as nanoseconds have to be between 1677-09-21T00:12:44.0 and " <>
                "2262-04-11T23:47:16.854775804"
            )
          end

          for {text, shown} <- [
                {"9999-01-01", "9999-01-01 00:00:00"},
                {"1000-01-01", "1000-01-01 00:00:00"},
                {"0000-01-01", "0000-01-01 00:00:00"},
                {"1677-09-21", "1677-09-21 00:00:00"},
                {"2262-04-12", "2262-04-12 00:00:00"},
                {"9999-01-01T10:20:30.123456789+01:00", "9999-01-01 09:20:30.123456789"},
                {"2262-04-11T23:47:16.854775808Z", "2262-04-11 23:47:16.854775808"},
                {"1677-09-21T00:12:43.145224192Z", "1677-09-21 00:12:43.145224192"},
                {"1000-01-01T00:00:00.100Z", "1000-01-01 00:00:00.100"},
                {"1000-01-01T00:00:00.100123Z", "1000-01-01 00:00:00.100123"}
              ] do
            assert sp_query(ctx, select <> "time > '#{text}'") ===
                     {:error, %{status: 500, body: overflow.(shown)}},
                   text
          end

          assert sp_query(ctx, select <> "time > '2262-04-11T23:47:16.854775807Z'") ===
                   {:ok, []}

          assert sp_query(ctx, select <> "time > '1677-09-22'") === {:ok, [%{"v" => 1.0}]}
        end

        test "the same string is the same error in BETWEEN, IN, a parameter and on the left",
             ctx do
          m = sp_measurement("sp_timebad_where")
          sp_write(ctx, ["#{m},host=a v=1 #{sp_ns(0)}"])
          select = "SELECT v FROM #{m} WHERE "

          bad = fn text ->
            {:error,
             %{
               status: 500,
               body: sp_timestamp_error(text, "timestamp must contain at least 10 characters")
             }}
          end

          for {where, params, text} <- [
                {"time BETWEEN 'xyz' AND '2025-01-01'", nil, "xyz"},
                {"time BETWEEN '2020-01-01' AND $a", %{a: "abc"}, "abc"},
                {"time BETWEEN $b AND $a", %{a: "abc", b: "2020-01-01"}, "abc"},
                {"time IN ('2020-01-01', $a)", %{a: "abc"}, "abc"},
                {"time IN ('qq', $a)", %{a: "abc"}, "qq"},
                {"time NOT IN ('qq')", nil, "qq"},
                {"'qq' < time", nil, "qq"},
                {"$a < time", %{a: ""}, ""},
                {"time = $a", %{a: ""}, ""},
                {"time = $a AND time > 'qq'", %{a: "abc"}, "abc"},
                {"time > 'qq' OR time > $a", %{a: "abc"}, "qq"},
                {"NOT time > 'qq'", nil, "qq"},
                {"host = 'a' AND (time > 'qq')", nil, "qq"}
              ] do
            assert sp_query(ctx, select <> where, params) === bad.(text), where
          end
        end

        test "a type error or a missing column comes before an unreadable string", ctx do
          m = sp_measurement("sp_timebad_order")
          sp_write(ctx, ["#{m},host=a v=1 #{sp_ns(0)}"])
          select = "SELECT v FROM #{m} WHERE "

          coercion =
            sp_coercion(
              "Cannot infer common argument type for comparison operation Timestamp(ns) = Int64"
            )

          assert sp_query(ctx, select <> "time = 5 AND time > 'qq'") ===
                   {:error, %{status: 400, body: coercion}}

          assert sp_query(ctx, select <> "time > 'qq' AND time = 5") ===
                   {:error, %{status: 400, body: coercion}}

          assert {:error, %{status: 500, body: "Schema error: No field named zz." <> _fields}} =
                   sp_query(ctx, select <> "zz = 1 AND time > 'abc'")
        end
      end
    end
  end

  defp time_aggregate_tests do
    quote location: :keep do
      describe "SQL parsing — contract: aggregates over time" do
        test "AVG and SUM fail planning in their own words", ctx do
          m = sp_measurement("sp_timeagg")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          assert {:error, %{status: 400, body: avg}} =
                   sp_query(ctx, "SELECT AVG(time) AS a FROM #{m}")

          assert avg ===
                   "Error during planning: Execution error: Function 'avg' user-defined " <>
                     "coercion failed with \"Error during planning: Avg does not support " <>
                     "inputs of type Timestamp(ns).\" No function matches the given name and " <>
                     "argument types 'avg(Timestamp(ns))'. You might need to add explicit " <>
                     "type casts.\n\tCandidate functions:\n\tavg(UserDefined)"

          assert {:error, %{status: 400, body: sum}} =
                   sp_query(ctx, "SELECT SUM(time) AS a FROM #{m}")

          assert sum ===
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
                 ) ===
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
    quote location: :keep do
      describe "SQL parsing — contract: DISTINCT, LIMIT and OFFSET" do
        test "DISTINCT over no columns is one empty row", ctx do
          m = sp_measurement("sp_distinct")
          sp_write(ctx, ["#{m} price=1.5 #{sp_ns(0)}", "#{m} price=2.5 #{sp_ns(1)}"])

          assert sp_query(ctx, "SELECT DISTINCT FROM #{m}") === {:ok, [%{}]}
          assert sp_query(ctx, "SELECT DISTINCT FROM #{m} WHERE price > 100") === {:ok, []}
        end

        test "DISTINCT cannot ORDER BY a column it does not select", ctx do
          m = sp_measurement("sp_distinct_order")
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
            assert sp_query(ctx, sql) === error.(names), sql
          end

          assert sp_query(ctx, "SELECT DISTINCT v FROM #{m} ORDER BY v DESC") ===
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
            assert sp_query(ctx, "SELECT v FROM #{m} #{tail}") ===
                     {:error, %{status: 500, body: "Schema error: No field named abc."}},
                   tail
          end

          expected = sp_coercion("Expected LIMIT to be an integer or null, but got Float64")

          assert {:error, %{status: 400, body: ^expected}} =
                   sp_query(ctx, "SELECT v FROM #{m} LIMIT 1.5")

          expected = sp_coercion("Expected OFFSET to be an integer or null, but got Float64")

          assert {:error, %{status: 400, body: ^expected}} =
                   sp_query(ctx, "SELECT v FROM #{m} LIMIT 1 OFFSET 1.5")

          assert sp_query(ctx, "SELECT v FROM #{m} ORDER BY time LIMIT NULL") ===
                   {:ok, [%{"v" => 1.0}, %{"v" => 2.0}]}

          assert sp_query(ctx, "SELECT v FROM #{m} ORDER BY time LIMIT NULL OFFSET NULL") ===
                   {:ok, [%{"v" => 1.0}, %{"v" => 2.0}]}
        end

        test "a column called offset is still a column", ctx do
          m = sp_measurement("sp_limit_column")

          sp_write(ctx, [
            "#{m} offset=5i,v=1i #{sp_ns(0)}",
            "#{m} offset=1i,v=2i #{sp_ns(1)}",
            "#{m} offset=9i,v=3i #{sp_ns(2)}"
          ])

          assert sp_query(ctx, "SELECT v FROM #{m} WHERE offset > 3 ORDER BY time LIMIT 2") ===
                   {:ok, [%{"v" => 1}, %{"v" => 3}]}
        end
      end
    end
  end

  defp function_tests do
    quote location: :keep do
      describe "SQL parsing — contract: functions" do
        @tag local_divergence:
               "the engine suggests a different function from run to run; Local always names one"
        test "FIRST and LAST are not SQL functions", ctx do
          m = sp_measurement("sp_first")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          # The engine suggests a different function from run to run; the
          # double always names the same one.
          for {name, suggestion} <- [{"first", "cbrt"}, {"last", "least"}],
              args <- ["v", "v, time"] do
            prefix = "Error during planning: Invalid function '#{name}'.\nDid you mean '"

            assert {:error, %{status: 400, body: body}} =
                     sp_query(ctx, "SELECT #{name}(#{args}) AS a FROM #{m}")

            if sp_local?() do
              assert body === prefix <> suggestion <> "'?", args
            else
              assert String.starts_with?(body, prefix), body
              assert String.replace_prefix(body, prefix, "") =~ ~r/\A[a-z_0-9]+'\?\z/, body
            end
          end
        end

        @tag local_divergence: "the engine answers a null that is there; Local refuses by name"
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
              assert result ===
                       {:error,
                        %{
                          status: 400,
                          body:
                            "Client.Local: round(x, #{scale}) leaves the range of a double: " <>
                              "InfluxDB answers null (a NaN or infinity as JSON), which a " <>
                              "result row here cannot hold"
                        }}
            else
              assert result === {:ok, [%{"r" => nil}]}
            end
          end

          assert {:ok, [%{"r" => 1200.0}]} =
                   sp_query(ctx, "SELECT round(1234.5678, -2) AS r FROM #{m}")
        end

        test "a zero that rounding leaves keeps the sign of the number", ctx do
          m = sp_measurement("sp_round_zero")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          assert {:ok, [row]} =
                   sp_query(
                     ctx,
                     "SELECT round(-0.3) AS a, round(-0.0) AS b, round(-0.04, 1) AS c, " <>
                       "round(-0.3, 0) AS d, round(-1500.0, -4) AS e, round(-0.3 * v) AS f, " <>
                       "ceil(-0.5) AS g, floor(-0.0) AS h, round(0.3) AS i, round(-v, -3) AS j " <>
                       "FROM #{m}"
                   )

          for key <- ~w(a b c d e f g h j) do
            assert sp_negative_zero?(row[key]), key
          end

          assert row["i"] === 0.0
          refute sp_negative_zero?(row["i"])

          assert sp_query(ctx, "SELECT round(-0.5) AS a, round(-0.49, 1) AS b FROM #{m}") ===
                   {:ok, [%{"a" => -1.0, "b" => -0.5}]}
        end

        test "round keeps what a double holds", ctx do
          m = sp_measurement("sp_round_ok")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          assert sp_query(
                   ctx,
                   "SELECT round(2.345, 2) AS a, round(-2.5) AS b, round(v, 300) AS c, " <>
                     "round(v, -308) AS d FROM #{m}"
                 ) === {:ok, [%{"a" => 2.35, "b" => -3.0, "c" => 1.0, "d" => 0.0}]}
        end
      end
    end
  end

  defp date_bin_tests do
    quote location: :keep do
      describe "SQL parsing — contract: DATE_BIN" do
        test "an interval is compared by value, not by spelling", ctx do
          m = sp_measurement("sp_datebin")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}", "#{m} v=3 #{sp_ns(10)}"])

          assert sp_query(
                   ctx,
                   "SELECT DATE_BIN(INTERVAL '60 seconds', time) AS t, MAX(v) AS m " <>
                     "FROM #{m} GROUP BY DATE_BIN(INTERVAL '1 minute', time)"
                 ) === {:ok, [%{"t" => ~U[2023-11-14 22:13:00.000000Z], "m" => 3.0}]}
        end

        test "a position or an alias in GROUP BY is the select item", ctx do
          m = sp_measurement("sp_datebin_ref")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}", "#{m} v=3 #{sp_ns(10)}"])

          for group <- ["1", "t"] do
            assert sp_query(
                     ctx,
                     "SELECT DATE_BIN(INTERVAL '1 minute', time) AS t, MAX(v) AS m " <>
                       "FROM #{m} GROUP BY #{group}"
                   ) === {:ok, [%{"t" => ~U[2023-11-14 22:13:00.000000Z], "m" => 3.0}]},
                   group
          end
        end

        @tag local_divergence:
               "the engine words its planning error; Local refuses the query by name"
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
            assert sp_query(ctx, sql) === {:error, %{status: 400, body: body}}
          end
        end
      end
    end
  end

  defp text_tests do
    quote location: :keep do
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
            assert sp_query(ctx, sql) === {:ok, [%{"v" => 2.0}]}, sql
          end

          assert sp_query(ctx, "select v from #{m} where s = 'a -- b /* c'") ===
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
            assert sp_query(ctx, sql) === {:ok, rows}, sql
          end
        end

        test "a text with no statement or with two is the engine's refusal", ctx do
          m = sp_measurement("sp_statements")
          sp_write(ctx, ["#{m} v=1 #{sp_ns(0)}"])

          none = "Error during planning: No SQL statements were provided in the query string"

          for sql <- ["", "  ", ";", ";;", "-- only a comment", "/* c */"] do
            assert sp_query(ctx, sql) === {:error, %{status: 400, body: none}}, sql
          end

          two =
            "This feature is not implemented: " <>
              "The context currently only supports a single SQL statement"

          for sql <- ["select 1; select 2", "select 1;select v from #{m};"] do
            assert sp_query(ctx, sql) === {:error, %{status: 405, body: two}}, sql
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

            assert sp_query(ctx, head <> tail) ===
                     {:error, %{status: 400, body: sp_tokenizer(message, 1, column)}},
                   tail
          end

          assert sp_query(ctx, "select *\nfrom #{m}\nwhere host = 'a") ===
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
            assert sp_query(ctx, sql) ===
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
            assert sp_query(ctx, sql) === {:ok, [%{"v" => v}]}, sql
          end
        end

        test "a literal that starts with a combining mark is compared whole", ctx do
          m = sp_measurement("sp_combining")
          mark = <<0x0301::utf8>>
          sp_write(ctx, ["#{m},k=#{mark}x v=1 #{sp_ns(0)}", "#{m},k=x v=2 #{sp_ns(1)}"])

          assert sp_query(ctx, "select v from #{m} where k = '#{mark}x'") ===
                   {:ok, [%{"v" => 1.0}]}

          assert sp_query(ctx, "select v from #{m} where k in ('#{mark}x', 'zz')") ===
                   {:ok, [%{"v" => 1.0}]}
        end
      end
    end
  end

  defp escape_tests do
    quote location: :keep do
      describe "SQL parsing — contract: escape strings" do
        test "E'...' is a string with backslash escapes", ctx do
          m = sp_measurement("sp_escape")
          sp_write(ctx, ["#{m},host=it's v=1 #{sp_ns(0)}", "#{m},host=b v=2 #{sp_ns(1)}"])

          for {where, v} <- [
                {~S[host = E'it\'s'], 1.0},
                {~S[host = e'it\x27s'], 1.0},
                {~S[host = E'it''s'], 1.0},
                {~S[host = E'\x62'], 2.0},
                {~S[host IN (E'\142', E'zz')], 2.0},
                {"host = E'b\\\\' OR host = E'\\u0062'", 2.0}
              ] do
            sql = "select v from #{m} where #{where}"
            assert sp_query(ctx, sql) === {:ok, [%{"v" => v}]}, sql
          end

          # `\b \f \n \r \t`, `\x` with one or two hex digits (none is an x),
          # an octal of one to three digits, `\u` and `\U` of exactly four and
          # eight, and any other escaped character as itself.
          for {text, value} <- [
                {~S[a\nb], "a\nb"},
                {~S[\t|\r|\b|\f|\\|\q], "\t|\r|\b|\f|\\|q"},
                {~S[\x41], "A"},
                {~S[\x4z], <<4, ?z>>},
                {~S[\xzz], "xzz"},
                {~S[\x7F], <<127>>},
                {"\\u00e9\\u00E9", "éé"},
                {~S[\U0001F600], "😀"},
                {~S[\101], "A"},
                {~S[\18], <<1, ?8>>},
                {~S[\0127], "\n7"},
                {~S[\8], "8"},
                {~S[\177], <<127>>},
                {~S[\'\"], "'\""},
                {~S[é\é], "éé"},
                {~S[''], "'"}
              ] do
            sql = "select E'#{text}' as x from #{m} limit 1"
            assert sp_query(ctx, sql) === {:ok, [%{"x" => value}]}, sql
          end

          assert sp_query(ctx, "select E'a' as x, e'b' as y, 'E''z' as z from #{m} limit 1") ===
                   {:ok, [%{"x" => "a", "y" => "b", "z" => "E'z"}]}
        end

        test "an escape the engine cannot read leaves the string unterminated", ctx do
          m = sp_measurement("sp_escape_bad")
          sp_write(ctx, ["#{m},host=a v=1 #{sp_ns(0)}"])
          head = "select "

          # Zero and anything above 127 in `\x` or an octal, a `\u` or `\U` that
          # is short, zero, a surrogate or beyond U+10FFFF, a lone backslash.
          for text <- [
                ~S[\0],
                ~S[\000],
                ~S[\x0],
                ~S[\x80],
                ~S[\xFF],
                ~S[\200],
                ~S[\377],
                ~S[\400],
                ~S[\777],
                "\\u00",
                "\\u00zz",
                "\\u0000",
                "\\ud83d",
                ~S[\U0001F60],
                ~S[\U00110000],
                "abc\\"
              ] do
            sql = head <> "E'#{text}' as x from #{m}"

            assert sp_query(ctx, sql) ===
                     {:error,
                      %{
                        status: 400,
                        body:
                          sp_tokenizer(
                            "Unterminated encoded string literal",
                            1,
                            String.length(head) + 1
                          )
                      }},
                   text
          end

          sql = "select 1 as a,\n  E'abc as x from #{m}"

          assert sp_query(ctx, sql) ===
                   {:error,
                    %{
                      status: 400,
                      body: sp_tokenizer("Unterminated encoded string literal", 2, 3)
                    }}
        end
      end
    end
  end

  defp identifier_tests do
    quote location: :keep do
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
            assert sp_query(ctx, sql) === {:ok, [row]}, sql
          end

          assert sp_query(ctx, ~s|select * from #{m} where "é" > 0|) ===
                   {:ok, [%{"fé" => "x", "é" => 1, "time" => ~U[2023-11-14 22:13:20.000000Z]}]}
        end

        test "only ASCII letters fold to lower case", ctx do
          m = sp_measurement("sp_unicode_fold")
          sp_write(ctx, ["#{m},fé=x v=1i #{sp_ns(0)}"])

          # `FÉ` is `fÉ`, a column that does not exist, and a name with a
          # letter outside ASCII is quoted when the engine prints it.
          assert sp_query(ctx, "select FÉ from #{m}") ===
                   {:error,
                    %{
                      status: 500,
                      body: sp_no_field(~s|"fÉ"|, sp_fields(m, ["fé", "time", "v"]))
                    }}
        end

        test "a name that needs its quotes is printed quoted, a quote doubled", ctx do
          m = sp_measurement("sp_quoted_name")
          sp_write(ctx, ["#{m},host=a v=1i #{sp_ns(0)}"])

          for {name, shown} <- [
                {~s|"Host"|, ~s|"Host"|},
                {~s|"a b"|, ~s|"a b"|},
                {~s|"é"|, ~s|"é"|},
                {~s|"ho""st"|, ~s|"ho""st"|},
                {~s|"a.b"|, ~s|"a.b"|},
                {~s|"1a"|, ~s|"1a"|},
                {~s|"$h"|, ~s|"$h"|},
                {~s|"a'b"|, ~s|"a'b"|},
                {~s|"_a"|, "_a"},
                {~s|"a1"|, "a1"},
                {~s|"order"|, "order"},
                {~s|""|, ""},
                {"Zz", "zz"}
              ] do
            for sql <- [
                  "select v from #{m} where #{name} = 'a'",
                  "select v from #{m} where 'a' = #{name}",
                  "select v from #{m} where host = #{name}",
                  "select v from #{m} where host in (#{name}, 'a')"
                ] do
              assert sp_query(ctx, sql) ===
                       {:error,
                        %{
                          status: 500,
                          body: sp_no_field(shown, sp_fields(m, ["host", "time", "v"]))
                        }},
                     sql
            end
          end

          # Wherever else a column may stand.
          table = sp_fields(m, ["host", "time", "v"])

          # ORDER BY lists the select list's fields before the table's.
          for name <- [~s|"Host"|, ~s|"a b"|, ~s|"ho""st"|],
              {sql, listed} <- [
                {"select v from #{m} where #{name}", table},
                {"select v from #{m} where not #{name}", table},
                {"select v from #{m} where #{name} is null", table},
                {"select v from #{m} where #{name} like 'a'", table},
                {"select v from #{m} where #{name} between 'a' and 'z'", table},
                {"select v from #{m} where host between #{name} and 'z'", table},
                {"select v from #{m} where host not between 'a' and #{name}", table},
                {"select v from #{m} order by #{name}", sp_fields(m, ["v"]) ++ table},
                {"select v from #{m} order by host, #{name} desc", sp_fields(m, ["v"]) ++ table}
              ] do
            assert sp_query(ctx, sql) ===
                     {:error, %{status: 500, body: sp_no_field(name, listed)}},
                   sql
          end

          # The same column by a quoted name, and a double quote is never a string.
          assert sp_query(ctx, ~s|select v from #{m} where "host" = 'a'|) === {:ok, [%{"v" => 1}]}

          assert sp_query(ctx, ~s|select v from #{m} where host = "host"|) ===
                   {:ok, [%{"v" => 1}]}

          assert sp_query(ctx, ~s|select v from #{m} where host = "$h"|, %{h: "a"}) ===
                   {:error,
                    %{
                      status: 500,
                      body: sp_no_field(~s|"$h"|, sp_fields(m, ["host", "time", "v"]))
                    }}
        end
      end
    end
  end

  defp parameter_tests do
    quote location: :keep do
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
            assert sp_query(ctx, "select v from #{m} where s = $p", %{p: value}) ===
                     {:ok, [%{"v" => i}]},
                   value
          end

          # A placeholder inside a literal is the literal's text.
          assert sp_query(
                   ctx,
                   "select v from #{m} where s = '$x' or v = $p order by time",
                   %{p: 0}
                 ) === {:ok, [%{"v" => 0}, %{"v" => 3}]}
        end

        test "a string of 200 KB is bound as it is", ctx do
          m = sp_measurement("sp_param_big")
          big = String.duplicate("a", 200_000)
          sp_write(ctx, [~s|#{m} v=1i,s="#{big}" #{sp_ns(0)}|, ~s|#{m} v=2i,s="b" #{sp_ns(1)}|])

          assert sp_query(ctx, "select v from #{m} where s = $p", %{p: big}) ===
                   {:ok, [%{"v" => 1}]}
        end

        test "names are word characters in any script; the key is the name without the $",
             ctx do
          m = sp_measurement("sp_param_names")
          sp_write(ctx, ["#{m} v=1i #{sp_ns(0)}", "#{m} v=2i #{sp_ns(1)}"])
          rows = {:ok, [%{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where v = $é", %{"é" => 2}) === rows
          assert sp_query(ctx, "select v from #{m} where v = $1", %{"1" => 2}) === rows

          assert sp_query(ctx, "select v from #{m} where v = $a or v = $b order by time", %{
                   a: 1,
                   b: 2
                 }) === {:ok, [%{"v" => 1}, %{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where v = $ab", %{a: 1, ab: 2}) === rows

          # `$a$b` opens a dollar-quoted string, so the tokenizer refuses it.
          sql = "select v from #{m} where v = $a$b"

          assert sp_query(ctx, sql, %{a: 1, b: 2}) ===
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

          assert sp_query(ctx, "select v from #{m} where v = $zz") === unbound.("zz")
          assert sp_query(ctx, "select v from #{m} where v = $zz", %{a: 1}) === unbound.("zz")
          assert sp_query(ctx, "select v from #{m} where v = $a", %{"$a" => 1}) === unbound.("a")
          assert sp_query(ctx, "select v from #{m} where v = $1", %{a: 1}) === unbound.("1")

          # The missing table is found first.
          missing = "#{m}_missing"

          assert sp_query(ctx, "select v from #{missing} where v = $zz") ===
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
    quote location: :keep do
      describe "SQL parsing — contract: the types of parameters" do
        test "keyword-list, null and very large parameters", ctx do
          m = sp_measurement("sp_param_kinds")

          sp_write(ctx, [
            "#{m},host=a v=1i,f=1.5 #{sp_ns(0)}",
            "#{m},host=b v=2i,f=2.5 #{sp_ns(1)}"
          ])

          assert sp_query(ctx, "select v from #{m} where host = $host", host: "b") ===
                   {:ok, [%{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where v = $p", %{p: nil}) === {:ok, []}

          assert sp_query(ctx, "select v from #{m} where v in ($a, $b) order by time", %{
                   a: nil,
                   b: 1
                 }) === {:ok, [%{"v" => 1}]}

          assert sp_query(ctx, "select v from #{m} where f < $p order by time", %{p: 1.0e20}) ===
                   {:ok, [%{"v" => 1}, %{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where v < $p order by time", %{
                   p: 18_446_744_073_709_551_616
                 }) === {:ok, [%{"v" => 1}, %{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where v between $a and $b", %{a: nil, b: 2}) ===
                   {:ok, []}

          assert sp_query(ctx, "select v from #{m} where v between $a and $b order by time", %{
                   a: 1,
                   b: 2
                 }) === {:ok, [%{"v" => 1}, %{"v" => 2}]}
        end

        test "LIMIT and OFFSET take a parameter as they take a literal", ctx do
          m = sp_measurement("sp_param_limit")
          sp_write(ctx, for(i <- 1..3, do: "#{m} v=#{i}i #{sp_ns(i)}"))
          order = "select v from #{m} order by time"

          assert sp_query(ctx, order <> " limit $n offset $o", %{n: 2, o: 1}) ===
                   {:ok, [%{"v" => 2}, %{"v" => 3}]}

          assert sp_query(ctx, order <> " limit $n", %{n: nil}) ===
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
            assert sp_query(ctx, order <> tail, params) ===
                     {:error, %{status: 400, body: body}},
                   tail
          end
        end

        @tag local_divergence:
               "the engine words the error with the column's type; Local refuses by name"
        test "a LIKE pattern is a string parameter", ctx do
          m = sp_measurement("sp_param_like")

          sp_write(ctx, [
            ~s|#{m} v=1i,s="apple" #{sp_ns(0)}|,
            ~s|#{m} v=2i,s="Banana" #{sp_ns(1)}|
          ])

          assert sp_query(ctx, "select v from #{m} where s like $p", %{p: "a%"}) ===
                   {:ok, [%{"v" => 1}]}

          assert sp_query(ctx, "select v from #{m} where s ilike $p", %{p: "b%"}) ===
                   {:ok, [%{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where s not like $p", %{p: "a%"}) ===
                   {:ok, [%{"v" => 2}]}

          assert sp_query(ctx, "select v from #{m} where s ~ $p", %{p: "^B"}) ===
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

          assert result === {:error, %{status: 400, body: expected}}
        end
      end
    end
  end

  defp parameter_type_tests do
    quote location: :keep do
      describe "SQL parsing — contract: parameters in an expression" do
        test "a Decimal is sent as a number, a date as ISO-8601 text and an atom as its name",
             ctx do
          m = sp_measurement("sp_param_types")

          sp_write(ctx, [
            ~s|#{m},k=name n=500i,s="name" #{sp_ns(0)}|,
            ~s|#{m},k=other n=2000i,s="other" #{sp_ns(1)}|
          ])

          select = "select n from #{m} where "
          first = {:ok, [%{"n" => 500}]}

          # As text "500" would sort after "1000.00", so a Decimal sent as a
          # string would match no row.
          assert sp_query(ctx, select <> "n < $p", %{p: Decimal.new("1000.00")}) === first
          assert sp_query(ctx, select <> "n < $p", %{p: Decimal.new("1.2E+3")}) === first
          assert sp_query(ctx, select <> "n < $p", %{p: "1000.00"}) === {:ok, []}

          for {where, value} <- [
                {"time = $p", ~U[2023-11-14 22:13:20.000000Z]},
                {"time = $p", ~N[2023-11-14 22:13:20]},
                {"time < $p", ~D[2023-11-15]},
                {"s = $p", :name},
                {"s = $p", "name"}
              ] do
            assert sp_query(ctx, select <> "(" <> where <> ") AND n < 1000", %{p: value}) ===
                     first,
                   where <> " " <> inspect(value)
          end

          assert sp_query(ctx, select <> "time >= $p ORDER BY time", %{p: ~D[2023-11-14]}) ===
                   {:ok, [%{"n" => 500}, %{"n" => 2000}]}
        end

        test "a parameter is a constant of the select list and an operand of an expression",
             ctx do
          m = sp_measurement("sp_param_expr")
          sp_write(ctx, for(i <- 1..3, do: "#{m} v=#{i}i,f=#{i}.5 #{sp_ns(i)}"))

          assert sp_query(
                   ctx,
                   "select $a as x, v + $b as y, f - $c as z from #{m} order by time limit 1",
                   %{a: "s", b: 2, c: -2}
                 ) === {:ok, [%{"x" => "s", "y" => 3, "z" => 3.5}]}

          assert sp_query(ctx, "select $p as x, count(*) as n from #{m}", %{p: 7}) ===
                   {:ok, [%{"x" => 7, "n" => 3}]}

          assert sp_query(ctx, "select $q as x, v - $p as y from #{m} order by time limit 1", %{
                   q: 1.5,
                   p: 7
                 }) === {:ok, [%{"x" => 1.5, "y" => -6}]}

          assert sp_query(ctx, "select sum(v * $b) as t from #{m}", %{b: 2}) ===
                   {:ok, [%{"t" => 12}]}

          assert sp_query(ctx, "select v from #{m} where v * $b > $c order by time", %{
                   b: 2,
                   c: 3
                 }) === {:ok, [%{"v" => 2}, %{"v" => 3}]}
        end

        test "a parameter is bound inside a CTE", ctx do
          m = sp_measurement("sp_param_cte")
          sp_write(ctx, for(i <- 1..3, do: "#{m} v=#{i}i #{sp_ns(i)}"))

          assert sp_query(ctx, "with c as (select v from #{m} where v > $b) select v from c", %{
                   b: 2
                 }) === {:ok, [%{"v" => 3}]}

          assert sp_query(
                   ctx,
                   "with c as (select v, $a as s from #{m}) select v, s from c order by v",
                   %{a: "s"}
                 ) ===
                   {:ok,
                    [%{"v" => 1, "s" => "s"}, %{"v" => 2, "s" => "s"}, %{"v" => 3, "s" => "s"}]}
        end
      end
    end
  end

  defp unaliased_tests do
    quote location: :keep do
      describe "SQL parsing — contract: select items without an alias" do
        test "an aggregate is named as the engine names it", ctx do
          m = sp_fixture(ctx)
          first = ~U[2023-11-14 22:13:20.000000Z]

          for {select, row} <- [
                {"count(*)", %{"count(*)" => 3}},
                {"COUNT(1)", %{"count(Int64(1))" => 3}},
                {"Count(V)", %{"count(#{m}.v)" => 3}},
                {"count(DISTINCT h)", %{"count(DISTINCT #{m}.h)" => 2}},
                {"sum(v), avg(v), min(v), max(v), median(v)",
                 %{
                   "sum(#{m}.v)" => 6,
                   "avg(#{m}.v)" => 2.0,
                   "min(#{m}.v)" => 1,
                   "max(#{m}.v)" => 3,
                   "median(#{m}.v)" => 2
                 }},
                {"stddev(v), STDDEV_SAMP(v), stddev_pop(v)",
                 %{
                   "stddev(#{m}.v)" => 1.0,
                   "stddev_samp(#{m}.v)" => 1.0,
                   "stddev_pop(#{m}.v)" => 0.816496580927726
                 }},
                {"var(v), var_samp(v), var_pop(v)",
                 %{
                   "var(#{m}.v)" => 1.0,
                   "var_samp(#{m}.v)" => 1.0,
                   "var_pop(#{m}.v)" => 0.6666666666666666
                 }},
                {"max(time), count(time)",
                 %{"max(#{m}.time)" => ~U[2023-11-14 22:15:20.000000Z], "count(#{m}.time)" => 3}},
                {"sum(v * 2)", %{"sum(#{m}.v * Int64(2))" => 12}},
                {"sum((v + 1) * 2)", %{"sum(#{m}.v + Int64(1) * Int64(2))" => 18}},
                {"avg(-v)", %{"avg((- #{m}.v))" => -2.0}},
                {"sum(abs(v))", %{"sum(abs(#{m}.v))" => 6}},
                {"sum(round(f, 1))", %{"sum(round(#{m}.f,Int64(1)))" => 7.5}},
                {"sum(1.5 * v)", %{"sum(Float64(1.5) * #{m}.v)" => 9.0}},
                {"sum(v / 2), sum(v % 2)",
                 %{"sum(#{m}.v / Int64(2))" => 2, "sum(#{m}.v % Int64(2))" => 2}},
                # A cast is not part of the name.
                {"sum(CAST(v AS DOUBLE))", %{"sum(#{m}.v)" => 6.0}},
                {"sum(v::DOUBLE)", %{"sum(#{m}.v)" => 6.0}},
                {"first_value(v ORDER BY time)",
                 %{"first_value(#{m}.v) ORDER BY [#{m}.time ASC NULLS LAST]" => 1}},
                {"first_value(v ORDER BY time DESC)",
                 %{"first_value(#{m}.v) ORDER BY [#{m}.time DESC NULLS FIRST]" => 3}},
                {"last_value(v ORDER BY time ASC)",
                 %{"last_value(#{m}.v) ORDER BY [#{m}.time ASC NULLS LAST]" => 3}},
                {"selector_first(v, time)",
                 %{"selector_first(#{m}.v,#{m}.time)" => %{"value" => 1, "time" => first}}},
                {"selector_last(v, time)['value']",
                 %{"selector_last(#{m}.v,#{m}.time)[value]" => 3}},
                {"selector_min(v, time)['time']",
                 %{"selector_min(#{m}.v,#{m}.time)[time]" => first}}
              ] do
            assert sp_query(ctx, "SELECT #{select} FROM #{m}") === {:ok, [row]}, select
          end
        end

        test "a column, a constant or an expression is named as the engine names it", ctx do
          m = sp_fixture(ctx)

          for {select, row} <- [
                {"v", %{"v" => 1}},
                {"#{m}.v", %{"v" => 1}},
                {"1", %{"Int64(1)" => 1}},
                {"-1", %{"Int64(-1)" => -1}},
                {"1.5", %{"Float64(1.5)" => 1.5}},
                {"1.0", %{"Float64(1)" => 1.0}},
                {"1e20", %{"Float64(100000000000000000000)" => 1.0e20}},
                {"1e-7", %{"Float64(0.0000001)" => 1.0e-7}},
                {".5", %{"Float64(0.5)" => 0.5}},
                {"'x'", %{~s|Utf8("x")| => "x"}},
                {"'it''s'", %{~s|Utf8("it's")| => "it's"}},
                {"true", %{"Boolean(true)" => true}},
                {"NULL", %{}},
                {"-v", %{"(- #{m}.v)" => -1}},
                {"abs(v)", %{"abs(#{m}.v)" => 1}},
                {"ABS(-v)", %{"abs((- #{m}.v))" => 1}},
                {"round(f, 1)", %{"round(#{m}.f,Int64(1))" => 1.5}},
                {"round(f)", %{"round(#{m}.f)" => 2.0}},
                {"floor(f), ceil(f)", %{"floor(#{m}.f)" => 1.0, "ceil(#{m}.f)" => 2.0}},
                {"(v + 1) * 2", %{"#{m}.v + Int64(1) * Int64(2)" => 4}},
                {"v / 2", %{"#{m}.v / Int64(2)" => 0}},
                {"v % 2", %{"#{m}.v % Int64(2)" => 1}},
                {"v * -2", %{"#{m}.v * Int64(-2)" => -2}},
                {"2 * -v", %{"Int64(2) * (- #{m}.v)" => -2}},
                {"v - -1", %{"#{m}.v - Int64(-1)" => 2}},
                {"- -v", %{"(- (- #{m}.v))" => 1}},
                {"v + f", %{"#{m}.v + #{m}.f" => 2.5}},
                {"#{m}.v + 1", %{"#{m}.v + Int64(1)" => 2}},
                {"abs(v) + 1", %{"abs(#{m}.v) + Int64(1)" => 2}},
                {"round(v * 1.5, 2)", %{"round(#{m}.v * Float64(1.5),Int64(2))" => 1.5}},
                {"CAST(v AS DOUBLE)", %{"#{m}.v" => 1.0}},
                {"v::DOUBLE", %{"#{m}.v" => 1.0}},
                {"CAST(f AS INTEGER)", %{"#{m}.f" => 1}},
                {"CAST(v AS VARCHAR)", %{"#{m}.v" => "1"}},
                {"CAST(v AS DOUBLE) * 2", %{"#{m}.v * Int64(2)" => 2.0}},
                {"h, v * 2", %{"h" => "a", "#{m}.v * Int64(2)" => 2}}
              ] do
            sql = "SELECT #{select} FROM #{m} ORDER BY time LIMIT 1"
            assert sp_query(ctx, sql) === {:ok, [row]}, select
          end
        end
      end
    end
  end

  defp grouped_name_tests do
    quote location: :keep do
      describe "SQL parsing — contract: select items without an alias, grouped and aliased" do
        test "a grouped query names its items, and ORDER BY finds them by name or position",
             ctx do
          m = sp_fixture(ctx)

          bucket = fn interval ->
            "date_bin(IntervalMonthDayNano(\"IntervalMonthDayNano { months: 0, days: #{elem(interval, 0)}, " <>
              "nanoseconds: #{elem(interval, 1)} }\"),#{m}.time)"
          end

          assert sp_query(ctx, "SELECT h, count(*) FROM #{m} GROUP BY h ORDER BY h") ===
                   {:ok, [%{"h" => "a", "count(*)" => 2}, %{"h" => "b", "count(*)" => 1}]}

          hour = bucket.({0, 3_600_000_000_000})
          two_days = bucket.({2, 0})
          thirty_six_hours = bucket.({0, 129_600_000_000_000})

          for {interval, key, start} <- [
                {"1 hour", hour, ~U[2023-11-14 22:00:00.000000Z]},
                {"2 days", two_days, ~U[2023-11-13 00:00:00.000000Z]},
                {"36 hours", thirty_six_hours, ~U[2023-11-14 12:00:00.000000Z]}
              ] do
            assert sp_query(
                     ctx,
                     "SELECT date_bin(INTERVAL '#{interval}', time), count(*) FROM #{m} GROUP BY 1"
                   ) === {:ok, [%{key => start, "count(*)" => 3}]},
                   interval
          end

          by_sum = {:ok, [%{"h" => "b", "sum(#{m}.v)" => 2}, %{"h" => "a", "sum(#{m}.v)" => 4}]}

          for order <- ["2", "sum(v)", ~s|"sum(#{m}.v)"|, "SUM( v )"] do
            assert sp_query(
                     ctx,
                     "SELECT h, sum(v) FROM #{m} GROUP BY h ORDER BY #{order}"
                   ) === by_sum,
                   order
          end

          assert sp_query(ctx, "SELECT h, sum(v) AS s FROM #{m} GROUP BY h ORDER BY sum(v) DESC") ===
                   {:ok, [%{"h" => "a", "s" => 4}, %{"h" => "b", "s" => 2}]}

          assert sp_query(ctx, "SELECT v * 2 FROM #{m} ORDER BY 1 DESC LIMIT 1") ===
                   {:ok, [%{"#{m}.v * Int64(2)" => 6}]}

          assert sp_query(ctx, ~s|SELECT v * 2 FROM #{m} ORDER BY "#{m}.v * Int64(2)" LIMIT 1|) ===
                   {:ok, [%{"#{m}.v * Int64(2)" => 2}]}
        end

        test "a table alias is the qualifier in the name", ctx do
          m = sp_fixture(ctx)

          for from <- ["#{m} AS t", "#{m} t"] do
            assert sp_query(ctx, "SELECT t.v * 2, t.v FROM #{from} ORDER BY time LIMIT 1") ===
                     {:ok, [%{"t.v * Int64(2)" => 2, "v" => 1}]}

            assert sp_query(ctx, "SELECT sum(v) FROM #{from}") === {:ok, [%{"sum(t.v)" => 6}]}
          end
        end

        test "a parameter is named by its placeholder", ctx do
          m = sp_fixture(ctx)

          assert sp_query(
                   ctx,
                   "SELECT $p, $p + 1 AS q, v + $p FROM #{m} ORDER BY time LIMIT 1",
                   %{p: 5}
                 ) === {:ok, [%{"$p" => 5, "q" => 6, "#{m}.v + $p" => 6}]}
        end

        @tag local_divergence:
               "the engine words its planning error; Local refuses the list by name"
        test "two items with the same name are refused", ctx do
          m = sp_fixture(ctx)

          for {select, shown} <- [
                {"v, v", ["#{m}.v", "#{m}.v"]},
                {"v * 2, v * 2", ["#{m}.v * Int64(2)", "#{m}.v * Int64(2)"]},
                {"1, 1", ["Int64(1)", "Int64(1)"]},
                {"sum(v), sum(v)", ["sum(#{m}.v)", "sum(#{m}.v)"]},
                {"v AS a, h AS a", ["#{m}.v AS a", "#{m}.h AS a"]}
              ] do
            [first, second] = shown

            expected =
              ~s|Error during planning: Projections require unique expression names but the | <>
                ~s|expression "#{first}" at position 0 and "#{second}" at position 1 have | <>
                ~s|the same name. Consider aliasing ("AS") one of them.|

            assert {:error, %{status: 400, body: body}} =
                     sp_query(ctx, "SELECT #{select} FROM #{m}")

            if sp_local?(),
              do: assert(String.starts_with?(body, "Client.Local: "), body),
              else: assert(body === expected, select)
          end
        end
      end
    end
  end

  defp time_range_tests do
    quote location: :keep do
      describe "SQL parsing — contract: a WHERE that leaves no instant of time" do
        test "the conjuncts on time that are empty together are the planner's error", ctx do
          m = sp_fixture(ctx)
          t1 = "'2023-11-14T22:13:20'"
          t2 = "'2023-11-14T22:14:20'"
          t3 = "'2023-11-14T22:15:20'"
          boundaries = {:error, %{status: 500, body: sp_boundaries()}}

          for where <- [
                "time > #{t1} AND time < #{t1}",
                "time >= #{t1} AND time < #{t1}",
                "time > #{t1} AND time <= #{t1}",
                "time >= #{t3} AND time <= #{t1}",
                "time BETWEEN #{t3} AND #{t1}",
                "time BETWEEN #{t1} AND #{t2} AND time > #{t2}",
                "time > '2023-11-15' AND time = '2023-11-14'",
                "time = #{t2} AND time < #{t1}",
                "time = #{t2} AND time < #{t2}",
                "time IN (#{t1}) AND time > #{t3}",
                "time > '2023-11-14T22:13:20.000000000' AND time < '2023-11-14T22:13:20.000000001'",
                "time > now() AND time < now()",
                "time > now() + INTERVAL '1 hour' AND time < now()",
                "time > now() - INTERVAL '1 hour' AND time < now() - INTERVAL '2 hours'",
                "(time > #{t1} AND time < #{t1}) AND v = 1",
                "v = 1 AND time > #{t1} AND time < #{t1}",
                "time > #{t1} AND (time < #{t1} AND v > 0)",
                "(time > #{t1} OR v = 1) AND time < #{t1} AND time > #{t3}",
                "NOT (time <= #{t1} OR time >= #{t1})",
                "NOT (time <= #{t1}) AND NOT (time >= #{t1})",
                "time > #{t1} AND NOT (time >= #{t1})",
                "NOT (NOT (time > #{t1} AND time < #{t1}))",
                "NOT (time = #{t2}) AND time > #{t2} AND time < #{t2}",
                "time > #{t1} AND time < #{t1} AND time IS NOT NULL",
                "time > NULL AND time > #{t3} AND time < #{t1}",
                "time > #{t1} AND time < #{t1} AND true",
                "time IN (#{t1}, #{t2}) AND time > #{t2} AND time < #{t2}"
              ] do
            assert sp_query(ctx, "SELECT v FROM #{m} WHERE #{where}") === boundaries, where
          end

          for sql <- [
                "SELECT count(*) AS n FROM #{m} WHERE time > #{t1} AND time < #{t1}",
                "SELECT DISTINCT v FROM #{m} WHERE time > #{t1} AND time < #{t1}",
                "SELECT 1 AS a FROM #{m} WHERE time > #{t1} AND time < #{t1}",
                "WITH w AS (SELECT * FROM #{m}) SELECT v FROM w WHERE time > #{t1} AND time < #{t1}",
                "WITH w AS (SELECT * FROM #{m} WHERE time > #{t1} AND time < #{t1}) SELECT v FROM w",
                "SELECT v FROM #{m} WHERE time > #{t1} AND time < #{t1} AND v / 0 > 1"
              ] do
            assert sp_query(ctx, sql) === boundaries, sql
          end
        end

        test "what the optimizer settles first, or what hides the conjuncts, is no error", ctx do
          m = sp_fixture(ctx)
          t1 = "'2023-11-14T22:13:20'"
          t2 = "'2023-11-14T22:14:20'"
          t3 = "'2023-11-14T22:15:20'"
          all = {:ok, [%{"v" => 1}, %{"v" => 2}, %{"v" => 3}]}

          for {where, rows} <- [
                {"time >= #{t1} AND time <= #{t1}", {:ok, [%{"v" => 1}]}},
                {"time > #{t1} AND time < '2023-11-14T22:13:20.000000002'", {:ok, []}},
                {"time > #{t1} AND time < #{t1} OR v = 1", {:ok, [%{"v" => 1}]}},
                {"NOT (time > #{t1} AND time < #{t1})", all},
                {"time NOT BETWEEN #{t3} AND #{t1}", all},
                {"time = #{t1} AND time = #{t2}", {:ok, []}},
                {"time = #{t1} AND time != #{t1}", {:ok, []}},
                {"time = #{t1} AND time = #{t2} AND time > #{t3}", {:ok, []}},
                {"time IS NULL AND time > #{t3} AND time < #{t1}", {:ok, []}},
                {"time IN (#{t1}, #{t2}) AND time > #{t3}", {:ok, []}},
                {"time > #{t1} AND time < #{t1} AND false", {:ok, []}},
                {"time > #{t1} AND time < #{t1} AND 1 = 2", {:ok, []}},
                {"NOT (time < #{t2} OR time > #{t2})", {:ok, [%{"v" => 2}]}}
              ] do
            sql = "SELECT v FROM #{m} WHERE #{where} ORDER BY time"
            assert sp_query(ctx, sql) === rows, where
          end

          assert sp_query(
                   ctx,
                   "SELECT v FROM #{m} WHERE time > #{t1} AND time < #{t1} LIMIT 0"
                 ) === {:ok, []}

          # A filter on a CTE that aggregates does not reach the table.
          assert sp_query(
                   ctx,
                   "WITH w AS (SELECT max(time) AS time FROM #{m}) " <>
                     "SELECT * FROM w WHERE time > #{t2} AND time < #{t2}"
                 ) === {:ok, []}
        end

        test "the planner's other errors come first", ctx do
          m = sp_fixture(ctx)
          range = "time > '2023-11-14T22:13:20' AND time < '2023-11-14T22:13:20'"

          assert {:error, %{status: 500, body: "Schema error: No field named nosuch." <> _fields}} =
                   sp_query(ctx, "SELECT nosuch FROM #{m} WHERE #{range}")

          assert {:error, %{status: 500, body: "Schema error: No field named nosuch." <> _fields}} =
                   sp_query(ctx, "SELECT v FROM #{m} WHERE #{range} AND nosuch = 1")

          assert {:error, %{status: 500, body: "Schema error: No field named nosuch." <> _fields}} =
                   sp_query(ctx, "SELECT v FROM #{m} WHERE #{range} ORDER BY nosuch")

          assert sp_query(ctx, "SELECT v FROM #{m} WHERE #{range} AND time > 'abc'") ===
                   {:error,
                    %{
                      status: 500,
                      body:
                        sp_timestamp_error("abc", "timestamp must contain at least 10 characters")
                    }}

          assert sp_query(ctx, "SELECT v FROM #{m} WHERE #{range} LIMIT -1") ===
                   {:error,
                    %{
                      status: 400,
                      body:
                        "Optimizer rule 'eliminate_limit' failed\ncaused by\n" <>
                          "Error during planning: LIMIT must be >= 0, '-1' was provided"
                    }}
        end

        test "an unreadable time string comes before a negative LIMIT or OFFSET", ctx do
          m = sp_fixture(ctx)
          unreadable = sp_timestamp_error("abc", "timestamp must contain at least 10 characters")

          for tail <- ["LIMIT -1", "OFFSET -1", "LIMIT 1 OFFSET -1"] do
            assert sp_query(ctx, "SELECT v FROM #{m} WHERE time > 'abc' #{tail}") ===
                     {:error, %{status: 500, body: unreadable}},
                   tail
          end

          assert {:error, %{status: 500, body: "Schema error: No field named nosuch." <> _fields}} =
                   sp_query(ctx, "SELECT v FROM #{m} WHERE nosuch = 1 LIMIT -1")
        end
      end
    end
  end

  defp literal_type_tests do
    quote location: :keep do
      describe "SQL parsing — contract: the type of a number" do
        test "an integer is Int64, then UInt64, then a double", ctx do
          m = sp_fixture(ctx)

          for {literal, value} <- [
                {"9223372036854775807", 9_223_372_036_854_775_807},
                {"9223372036854775808", 9_223_372_036_854_775_808},
                {"18446744073709551615", 18_446_744_073_709_551_615},
                {"18446744073709551616", 1.844_674_407_370_955_2e19},
                {"99999999999999999999999999", 1.0e26},
                {"18446744073709551616.0", 1.844_674_407_370_955_2e19},
                {"123456789012345678901234567890.5", 1.234_567_890_123_456_8e29},
                {"-9223372036854775808", -9_223_372_036_854_775_808},
                {"-9223372036854775809", -9.223_372_036_854_776e18},
                {"-18446744073709551615", -1.844_674_407_370_955_2e19},
                {"-18446744073709551616", -1.844_674_407_370_955_2e19},
                {"1e308", 1.0e308},
                {"1.7976931348623157e308", 1.797_693_134_862_315_7e308},
                {"1e-400", 0.0},
                {"abs(9223372036854775808)", 9_223_372_036_854_775_808},
                {"abs(-9223372036854775807)", 9_223_372_036_854_775_807},
                {"abs(18446744073709551615)", 18_446_744_073_709_551_615},
                {"9223372036854775808 + 1", 9_223_372_036_854_775_809},
                {"9223372036854775807 + 1", -9_223_372_036_854_775_808},
                {"18446744073709551615 + 1", 18_446_744_073_709_551_616},
                {"18446744073709551616 + 1", 1.844_674_407_370_955_2e19},
                {"9223372036854775808 - 1", 9_223_372_036_854_775_807},
                {"9223372036854775808 * 2", 18_446_744_073_709_551_616},
                {"9223372036854775808 % 10", 8},
                {"9223372036854775808 + 1.5", 9.223_372_036_854_776e18},
                {"9223372036854775808 + (-1)", 9_223_372_036_854_775_807},
                {"-9223372036854775807 - 1", -9_223_372_036_854_775_808},
                {"-(9223372036854775807)", -9_223_372_036_854_775_807},
                {"0.1 + 0.2", 0.30000000000000004},
                {"CAST(9223372036854775808 AS DOUBLE)", 9.223_372_036_854_776e18}
              ] do
            assert sp_query(ctx, "SELECT #{literal} AS a FROM #{m} LIMIT 1") ===
                     {:ok, [%{"a" => value}]},
                   literal
          end
        end

        test "a number past the double range is a null that is there", ctx do
          m = sp_fixture(ctx)

          for literal <- ["1e400", "-1e400", "1e309"] do
            assert sp_query(ctx, "SELECT #{literal} AS a FROM #{m} LIMIT 1") ===
                     {:ok, [%{"a" => nil}]},
                   literal
          end
        end

        @tag local_divergence:
               "the engine closes the connection mid-response; Local returns the transport error"
        test "an Int64 by a UInt64 divides as a decimal of four places", ctx do
          m = sp_fixture(ctx)
          order = " FROM #{m} ORDER BY time"

          assert sp_query(ctx, "SELECT v / $p AS a" <> order, %{p: 3}) ===
                   {:ok, [%{"a" => 0.3333}, %{"a" => 0.6666}, %{"a" => 1.0}]}

          assert sp_query(ctx, "SELECT $p / v AS a" <> order, %{p: 10}) ===
                   {:ok, [%{"a" => 10.0}, %{"a" => 5.0}, %{"a" => 3.3333}]}

          assert sp_query(ctx, "SELECT -v / $p AS a" <> order <> " LIMIT 1", %{p: 7}) ===
                   {:ok, [%{"a" => -0.1428}]}

          assert sp_query(ctx, "SELECT 9223372036854775808 / 3 AS a" <> order <> " LIMIT 1") ===
                   {:ok, [%{"a" => 3.074_457_345_618_258_6e18}]}

          # Two UInt64s, and an Int64 by an Int64 parameter, divide as integers.
          assert sp_query(ctx, "SELECT $p / $q AS a, v / $n AS b" <> order <> " LIMIT 1", %{
                   p: 7,
                   q: 2,
                   n: -2
                 }) === {:ok, [%{"a" => 3, "b" => 0}]}

          assert sp_query(ctx, "SELECT v / $z AS a" <> order, %{z: 0}) === @sp_closed
        end

        test "a UInt64 cannot be negated", ctx do
          m = sp_fixture(ctx)

          negation =
            {:error,
             %{
               status: 400,
               body:
                 "Error during planning: Negation only supports numeric, interval and timestamp types"
             }}

          for literal <- ["-(9223372036854775808)", "-(18446744073709551615)"] do
            assert sp_query(ctx, "SELECT #{literal} AS a FROM #{m}") === negation, literal
          end

          for p <- [5, 0] do
            assert sp_query(ctx, "SELECT -$p AS a FROM #{m}", %{p: p}) === negation, "#{p}"
          end

          assert sp_query(ctx, "SELECT -$p AS a, abs($p) AS b FROM #{m} LIMIT 1", %{p: -5}) ===
                   {:ok, [%{"a" => 5, "b" => 5}]}
        end

        @tag local_divergence:
               "the engine closes the connection mid-response; Local returns the transport error"
        test "the magnitude or the negation of the Int64 minimum overflows", ctx do
          m = sp_measurement("sp_min")

          sp_write(ctx, [
            "#{m} y=-9223372036854775808i,w=5i #{sp_ns(0)}",
            "#{m} y=-9223372036854775807i,w=0i #{sp_ns(1)}"
          ])

          # Folded as a constant, or read from a column, `abs` overflows; a
          # negation overflows only when it is folded.
          for sql <- [
                "SELECT -(-9223372036854775807 - 1) AS a FROM #{m}",
                "SELECT abs(-9223372036854775807 - 1) AS a FROM #{m}",
                "SELECT abs(-9223372036854775808) AS a FROM #{m}",
                "SELECT abs(y) AS a FROM #{m}",
                "SELECT abs(y) AS a FROM #{m} WHERE w = 5",
                "SELECT sum(abs(y)) AS a FROM #{m}"
              ] do
            assert sp_query(ctx, sql) === @sp_closed, sql
          end

          assert sp_query(ctx, "SELECT -y AS a FROM #{m} ORDER BY time") ===
                   {:ok,
                    [%{"a" => -9_223_372_036_854_775_808}, %{"a" => 9_223_372_036_854_775_807}]}

          assert sp_query(ctx, "SELECT abs(y) AS a FROM #{m} WHERE y > -9223372036854775808") ===
                   {:ok, [%{"a" => 9_223_372_036_854_775_807}]}
        end
      end
    end
  end

  defp quoted_select_tests do
    quote location: :keep do
      describe "SQL parsing — contract: quoted names in the select list" do
        test "a quoted name is a column, wherever it stands in the select list", ctx do
          m = sp_fixture(ctx)
          fields = sp_fields(m, ["b", "f", "h", "s", "time", "v"])

          for {sql, shown} <- [
                {~s|SELECT "a b" FROM #{m}|, ~s|"a b"|},
                {~s|SELECT "ho""st" FROM #{m}|, ~s|"ho""st"|},
                {~s|SELECT "" FROM #{m}|, ""},
                {~s|SELECT count("a b") AS n FROM #{m}|, ~s|"a b"|},
                {~s|SELECT sum("a b" * 2) AS n FROM #{m}|, ~s|"a b"|},
                {~s|SELECT "a b" * 2 AS n FROM #{m}|, ~s|"a b"|},
                {~s|SELECT "a b" AS n FROM #{m}|, ~s|"a b"|},
                {~s|SELECT v, "V" FROM #{m}|, ~s|"V"|}
              ] do
            assert sp_query(ctx, sql) ===
                     {:error, %{status: 500, body: sp_no_field(shown, fields)}},
                   sql
          end

          assert sp_query(ctx, ~s|SELECT "v", "h" FROM #{m} ORDER BY time LIMIT 1|) ===
                   {:ok, [%{"v" => 1, "h" => "a"}]}

          assert sp_query(
                   ctx,
                   ~s|SELECT count("v") AS n, "h" FROM #{m} GROUP BY "h" ORDER BY "h"|
                 ) ===
                   {:ok, [%{"n" => 2, "h" => "a"}, %{"n" => 1, "h" => "b"}]}
        end

        test "a column with a name that needs its quotes is read and named", ctx do
          m = sp_measurement("sp_quoted_columns")
          sp_write(ctx, [~s|#{m},Host=A a\\ b=1i,Zed=2i,alpha=3i #{sp_ns(0)}|])

          assert sp_query(ctx, ~s|SELECT "Host", "a b", "Zed" FROM #{m}|) ===
                   {:ok, [%{"Host" => "A", "a b" => 1, "Zed" => 2}]}

          assert sp_query(ctx, ~s|SELECT "a b" * 2, "Zed" + 1 FROM #{m}|) ===
                   {:ok, [%{"#{m}.a b * Int64(2)" => 2, "#{m}.Zed + Int64(1)" => 3}]}

          assert sp_query(ctx, ~s|SELECT sum("a b"), sum("Zed" * 2) FROM #{m}|) ===
                   {:ok, [%{"sum(#{m}.a b)" => 1, "sum(#{m}.Zed * Int64(2))" => 4}]}

          assert sp_query(ctx, ~s|SELECT "a b" AS x FROM #{m} ORDER BY nosuch|) ===
                   {:error,
                    %{
                      status: 500,
                      body:
                        sp_no_field(
                          "nosuch",
                          ["x" | sp_fields(m, ["Host", "Zed", "a b", "alpha", "time"])]
                        )
                    }}
        end

        test "a relation the query does not have is named as written, with the engine's hint",
             ctx do
          m = sp_fixture(ctx)
          fields = sp_fields(m, ["b", "f", "h", "s", "time", "v"])
          upper = String.upcase(m)

          hint = fn printed ->
            " Column names are case sensitive. You can use double quotes to refer to the " <>
              "\"#{printed}\" column or set the datafusion.sql_parser.enable_ident_normalization " <>
              "configuration."
          end

          upper_v = ~s|"#{upper}".v|

          for sql <- [
                ~s|SELECT "#{upper}".v FROM #{m}|,
                ~s|SELECT v FROM #{m} WHERE "#{upper}".v = 1|,
                ~s|SELECT count("#{upper}".v) AS c FROM #{m}|
              ] do
            assert {:error, %{status: 500, body: body}} = sp_query(ctx, sql)

            assert body ===
                     "Schema error: No field named #{upper_v}." <>
                       hint.(upper_v) <> " Valid fields are " <> Enum.join(fields, ", ") <> ".",
                   sql
          end

          # Without a name that differs only in case there is no hint.
          assert sp_query(ctx, ~s|SELECT "Foo".v FROM #{m}|) ===
                   {:error, %{status: 500, body: sp_no_field(~s|"Foo".v|, fields)}}

          assert sp_query(ctx, "SELECT foo.v FROM #{m}") ===
                   {:error, %{status: 500, body: sp_no_field("foo.v", fields)}}

          assert sp_query(ctx, ~s|SELECT "#{m}".v FROM #{m} ORDER BY time LIMIT 1|) ===
                   {:ok, [%{"v" => 1}]}

          assert sp_query(ctx, "SELECT v FROM #{m} AS t WHERE #{m}.v = 1") ===
                   {:error,
                    %{
                      status: 500,
                      body:
                        sp_no_field("#{m}.v", sp_fields("t", ["b", "f", "h", "s", "time", "v"]))
                    }}
        end
      end
    end
  end

  defp valid_fields_tests do
    quote location: :keep do
      describe "SQL parsing — contract: the fields an unknown column lists" do
        test "WHERE and the select list list the table's fields, qualified and sorted", ctx do
          m = sp_fixture(ctx)
          fields = sp_fields(m, ["b", "f", "h", "s", "time", "v"])

          for sql <- [
                "SELECT nosuch FROM #{m}",
                "SELECT v, nosuch FROM #{m}",
                "SELECT nosuch, v FROM #{m}",
                "SELECT * FROM #{m} WHERE nosuch = 1",
                "SELECT h, v FROM #{m} WHERE nosuch = 1 ORDER BY other",
                "SELECT count(*) AS c FROM #{m} WHERE nosuch = 1",
                "SELECT count(nosuch) AS c FROM #{m}",
                "SELECT sum(v * nosuch) AS c FROM #{m}",
                "SELECT DISTINCT nosuch FROM #{m}",
                "SELECT DISTINCT h FROM #{m} WHERE nosuch = 1",
                "SELECT nosuch, count(*) AS n FROM #{m} GROUP BY nosuch",
                "SELECT n1 FROM #{m} WHERE nosuch = 1 AND other = 2",
                "SELECT v FROM #{m} WHERE v IN (1, nosuch)",
                "SELECT v FROM #{m} WHERE nosuch BETWEEN other AND 1",
                "SELECT nosuch FROM #{m} LIMIT other",
                "SELECT first_value(nosuch ORDER BY time) AS f FROM #{m}",
                "SELECT selector_first(v, nosuch)['value'] AS f FROM #{m}"
              ] do
            assert sp_query(ctx, sql) ===
                     {:error, %{status: 500, body: sp_no_field("nosuch", fields)}},
                   sql
          end
        end

        test "the clauses are resolved in the order WHERE, select list, ORDER BY, GROUP BY",
             ctx do
          m = sp_fixture(ctx)
          fields = sp_fields(m, ["b", "f", "h", "s", "time", "v"])
          projection = sp_fields(m, ["h"]) ++ ["c"]

          for {sql, name, listed} <- [
                {"SELECT n1 FROM #{m} WHERE n2 = 1", "n2", fields},
                {"SELECT n1 FROM #{m} WHERE n2 = 1 ORDER BY n3", "n2", fields},
                {"SELECT n1, n2 FROM #{m}", "n1", fields},
                {"SELECT n2, n1 FROM #{m}", "n2", fields},
                {"SELECT n1, count(n4) AS c FROM #{m} GROUP BY n2 ORDER BY n3", "n1", fields},
                {"SELECT count(n4) AS c FROM #{m} GROUP BY n2 ORDER BY n3", "n4", fields},
                {"SELECT h, count(*) AS c FROM #{m} GROUP BY n2 ORDER BY n3", "n3",
                 projection ++ fields},
                {"SELECT h, count(*) AS c FROM #{m} GROUP BY n2", "n2", projection ++ fields},
                {"SELECT DISTINCT n1 FROM #{m} ORDER BY n3", "n1", fields},
                {"SELECT DISTINCT ON (n2) n1 FROM #{m} ORDER BY n3", "n1", fields}
              ] do
            assert sp_query(ctx, sql) ===
                     {:error, %{status: 500, body: sp_no_field(name, listed)}},
                   sql
          end
        end

        test "ORDER BY and GROUP BY list the select list's fields first, repeats included",
             ctx do
          m = sp_fixture(ctx)
          fields = sp_fields(m, ["b", "f", "h", "s", "time", "v"])

          for {select, projection} <- [
                {"h, v", sp_fields(m, ["h", "v"])},
                {"v AS a, h", ["a" | sp_fields(m, ["h"])]},
                {"v * 2 AS a", ["a"]},
                {"v, v AS w", sp_fields(m, ["v"]) ++ ["w"]},
                {"time, v", sp_fields(m, ["time", "v"])},
                {"v * 2", [~s|"#{m}.v * Int64(2)"|]},
                {"*", fields},
                {"DISTINCT h", sp_fields(m, ["h"])},
                {"DISTINCT ON (h) h, v", sp_fields(m, ["h", "v"])},
                {"DISTINCT ON (h) v", sp_fields(m, ["v"])},
                {"DISTINCT ON (h) *", fields}
              ] do
            sql = "SELECT #{select} FROM #{m} ORDER BY nosuch"

            assert sp_query(ctx, sql) ===
                     {:error, %{status: 500, body: sp_no_field("nosuch", projection ++ fields)}},
                   sql
          end

          for {sql, projection} <- [
                {"SELECT h, v FROM #{m} GROUP BY nosuch", sp_fields(m, ["h", "v"])},
                {"SELECT h, count(*) AS c FROM #{m} GROUP BY h ORDER BY nosuch",
                 sp_fields(m, ["h"]) ++ ["c"]},
                {"SELECT count(*) FROM #{m} ORDER BY nosuch", [~s|"count(*)"|]},
                {"SELECT date_bin(INTERVAL '1 minute', time) AS b, count(*) AS c FROM #{m} GROUP BY 1 ORDER BY nosuch",
                 ["b", "c"]}
              ] do
            assert sp_query(ctx, sql) ===
                     {:error, %{status: 500, body: sp_no_field("nosuch", projection ++ fields)}},
                   sql
          end
        end

        test "a select name in a DISTINCT ON's ORDER BY lists the table alone", ctx do
          m = sp_fixture(ctx)
          fields = sp_fields(m, ["b", "f", "h", "s", "time", "v"])

          for {name, select} <- [{"hh", "h AS hh, v"}, {"w", "h, v * 2 AS w"}] do
            sql = "SELECT DISTINCT ON (h) #{select} FROM #{m} ORDER BY #{name}, time DESC"

            assert sp_query(ctx, sql) ===
                     {:error, %{status: 500, body: sp_no_field(name, fields)}},
                   sql
          end
        end
      end
    end
  end

  defp valid_fields_context_tests do
    quote location: :keep do
      describe "SQL parsing — contract: the fields an unknown column lists, by relation" do
        test "a CTE lists its columns in the order it selects them", ctx do
          m = sp_fixture(ctx)

          for {sql, listed} <- [
                {"WITH w AS (SELECT v, h FROM #{m}) SELECT v FROM w WHERE nosuch = 1",
                 sp_fields("w", ["v", "h"])},
                {"WITH w AS (SELECT v, h FROM #{m}) SELECT v FROM w ORDER BY nosuch",
                 sp_fields("w", ["v"]) ++ sp_fields("w", ["v", "h"])},
                {"WITH w AS (SELECT v AS a FROM #{m}) SELECT nosuch FROM w",
                 sp_fields("w", ["a"])},
                {"WITH w AS (SELECT h FROM #{m} WHERE v > 100) SELECT nosuch FROM w",
                 sp_fields("w", ["h"])},
                {"WITH w AS (SELECT * FROM #{m}) SELECT nosuch FROM w",
                 sp_fields("w", ["b", "f", "h", "s", "time", "v"])}
              ] do
            assert sp_query(ctx, sql) ===
                     {:error, %{status: 500, body: sp_no_field("nosuch", listed)}},
                   sql
          end

          # A CTE without time has no time to ask for.
          assert sp_query(ctx, "WITH w AS (SELECT v FROM #{m}) SELECT time FROM w") ===
                   {:error, %{status: 500, body: sp_no_field("time", sp_fields("w", ["v"]))}}
        end

        test "an alias is the qualifier, and a column written with its relation keeps it", ctx do
          m = sp_fixture(ctx)
          fields = ["b", "f", "h", "s", "time", "v"]

          for {from, qualifier} <- [{"#{m} AS t", "t"}, {"#{m} t", "t"}, {"#{m} AS T", "t"}] do
            assert sp_query(ctx, "SELECT nosuch FROM #{from}") ===
                     {:error,
                      %{status: 500, body: sp_no_field("nosuch", sp_fields(qualifier, fields))}},
                   from

            assert sp_query(ctx, "SELECT v FROM #{from} ORDER BY nosuch") ===
                     {:error,
                      %{
                        status: 500,
                        body:
                          sp_no_field(
                            "nosuch",
                            sp_fields(qualifier, ["v"]) ++ sp_fields(qualifier, fields)
                          )
                      }},
                   from
          end

          assert sp_query(ctx, "SELECT v FROM #{m} t WHERE t.nosuch = 1") ===
                   {:error, %{status: 500, body: sp_no_field("t.nosuch", sp_fields("t", fields))}}

          assert sp_query(ctx, "SELECT v FROM #{m} WHERE #{m}.nosuch = 1") ===
                   {:error,
                    %{status: 500, body: sp_no_field("#{m}.nosuch", sp_fields(m, fields))}}
        end

        test "names that need quotes are quoted and sorted by their bytes", ctx do
          m = sp_measurement("sp_sorted_columns")

          sp_write(ctx, [
            ~s|#{m},Host=A,host=b,t1=x a\\ b=1i,Zed=2i,alpha=3i,_u=4i,é=5i,ZZ=1i,zz=2i #{sp_ns(0)}|
          ])

          fields =
            sp_fields(m, [
              "Host",
              "ZZ",
              "Zed",
              "_u",
              "a b",
              "alpha",
              "host",
              "t1",
              "time",
              "zz",
              "é"
            ])

          assert sp_query(ctx, "SELECT nosuch FROM #{m}") ===
                   {:error, %{status: 500, body: sp_no_field("nosuch", fields)}}

          assert sp_query(ctx, "SELECT Zed FROM #{m}") ===
                   {:error, %{status: 500, body: sp_no_field("zed", fields)}}

          assert sp_query(ctx, ~s|SELECT "Zed" FROM #{m}|) === {:ok, [%{"Zed" => 2}]}
        end

        test "the fields of both sides of a CROSS JOIN are listed, each qualified", ctx do
          left = sp_measurement("sp_left")
          right = sp_measurement("sp_right")
          sp_write(ctx, ["#{left},h=a v=1i #{sp_ns(0)}", "#{right} w=2i #{sp_ns(0)}"])

          assert sp_query(ctx, "SELECT h FROM #{left} CROSS JOIN #{right} WHERE nosuch = 1") ===
                   {:error,
                    %{
                      status: 500,
                      body:
                        sp_no_field(
                          "nosuch",
                          sp_fields(left, ["h", "time", "v"]) ++ sp_fields(right, ["time", "w"])
                        )
                    }}
        end

        test "a missing table is named as written", ctx do
          for {sql, name} <- [
                {~s|SELECT * FROM "r""vt"|, ~s|r"vt|},
                {~s|SELECT * FROM "XQA"|, "XQA"},
                {"SELECT * FROM Xq", "xq"},
                {~s|SELECT * FROM "a b"|, "a b"}
              ] do
            assert sp_query(ctx, sql) ===
                     {:error,
                      %{
                        status: 400,
                        body: "Error during planning: table 'public.iox.#{name}' not found"
                      }},
                   sql
          end
        end
      end
    end
  end

  defp time_zone_tests do
    quote location: :keep do
      describe "SQL parsing — contract: the zone of a time string" do
        test "the names of UTC, the fixed offsets and Etc/GMT are zones", ctx do
          m = sp_measurement("sp_zone")
          summer = "#{m} v=9i 1689372780000000000"
          sp_write(ctx, [summer | for(i <- 0..1, do: "#{m} v=#{i}i #{sp_ns(i)}")])
          select = "SELECT v FROM #{m} WHERE time = "

          # 22:13:20 UTC; `Etc/GMT+1` is an hour behind UTC, `Etc/GMT-1` ahead.
          for text <- [
                "2023-11-14T22:13:20 UTC",
                "2023-11-14T22:13:20 GMT",
                "2023-11-14T22:13:20 Zulu",
                "2023-11-14T22:13:20 UCT",
                "2023-11-14T22:13:20 Universal",
                "2023-11-14T22:13:20 Greenwich",
                "2023-11-14T22:13:20 GMT0",
                "2023-11-14T22:13:20 GMT+0",
                "2023-11-14T22:13:20 GMT-0",
                "2023-11-14T22:13:20Zulu",
                "2023-11-14T22:13:20  Zulu",
                "2023-11-14T22:13:20 Etc/UTC",
                "2023-11-14T22:13:20 Etc/GMT",
                "2023-11-14T22:13:20 Etc/UCT",
                "2023-11-14T22:13:20 Etc/Zulu",
                "2023-11-14T22:13:20 Etc/Universal",
                "2023-11-14T22:13:20 Etc/Greenwich",
                "2023-11-14T22:13:20 Etc/GMT0",
                "2023-11-14T22:13:20 Etc/GMT+0",
                "2023-11-14T22:13:20 Etc/GMT-0",
                "2023-11-14T21:13:20 Etc/GMT+1",
                "2023-11-14T23:13:20 Etc/GMT-1",
                "2023-11-14T10:13:20 Etc/GMT+12",
                "2023-11-15T12:13:20 Etc/GMT-14",
                "2023-11-14T17:13:20 EST",
                "2023-11-14T15:13:20 MST",
                "2023-11-14T12:13:20 HST"
              ] do
            assert sp_query(ctx, select <> "'#{text}'") === {:ok, [%{"v" => 0}]}, text
          end

          # The offset does not change with the date.
          for text <- [
                "2023-07-14T17:13:00 EST",
                "2023-07-14T15:13:00 MST",
                "2023-07-14T12:13:00 HST"
              ] do
            assert sp_query(ctx, select <> "'#{text}'") === {:ok, [%{"v" => 9}]}, text
          end
        end

        test "a name that is not a zone, or is spelled wrongly, is the engine's error", ctx do
          m = sp_measurement("sp_zone_bad")
          sp_write(ctx, ["#{m} v=0i #{sp_ns(0)}"])

          for zone <- [
                "zulu",
                "utc",
                "gmt",
                "est",
                "Z",
                "xyz",
                "Factory",
                "GMT+1",
                "GMT-1",
                "UTC+0",
                "UTC0",
                "Etc/GMT+13",
                "Etc/GMT+14",
                "Etc/GMT-15",
                "Etc/GMT+01",
                "Etc/GMT-01",
                "Etc/GMT+00",
                "Zulu "
              ] do
            assert sp_query(ctx, "SELECT v FROM #{m} WHERE time = '2023-11-14T22:13:20 #{zone}'") ===
                     {:error,
                      %{
                        status: 500,
                        body:
                          sp_optimizer(
                            "Parser error: Invalid timezone \"#{zone}\": failed to parse timezone"
                          )
                      }},
                   zone
          end
        end

        @tag local_divergence:
               "Local holds no time zone database and refuses a zone whose offset changes by name"
        test "a zone of the time zone database is read by the engine", ctx do
          m = sp_measurement("sp_zone_db")
          sp_write(ctx, ["#{m} v=0i #{sp_ns(0)}"])

          for zone <- ["Europe/Paris", "America/New_York", "CET", "Japan", "PST8PDT", "EST5EDT"] do
            result =
              sp_query(ctx, "SELECT v FROM #{m} WHERE time > '2023-11-14T00:00:00 #{zone}'")

            if sp_local?() do
              assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} = result, zone
            else
              assert {:ok, _rows} = result, zone
            end
          end
        end
      end
    end
  end

  defp leap_second_tests do
    quote location: :keep do
      describe "SQL parsing — contract: a leap second in a time string" do
        test "a leap second is the start of the next minute", ctx do
          m = sp_measurement("sp_leap")

          sp_write(ctx, [
            "#{m} v=1i 1699999979000000000",
            "#{m} v=2i 1699999980000000000",
            "#{m} v=3i 1699999980500000000",
            "#{m} v=4i 1700006400000000000",
            "#{m} v=6i 1700000040000000000"
          ])

          select = "SELECT v FROM #{m} WHERE time = "

          for {text, rows} <- [
                {"2023-11-14T22:12:60Z", [2]},
                {"2023-11-14T22:12:60.5Z", [3]},
                {"2023-11-14 22:12:60", [2]},
                {"2023-11-14T23:12:60+01:00", [2]},
                {"2023-11-14T22:12:60 Zulu", [2]},
                {"2023-11-14T22:13:60Z", [6]},
                {"2023-11-14T23:59:60Z", [4]},
                {"2023-11-14T22:12:60.000000001Z", []},
                {"2023-11-14T22:12:59.999999999Z", []}
              ] do
            assert sp_query(ctx, select <> "'#{text}' ORDER BY time") ===
                     {:ok, Enum.map(rows, &%{"v" => &1})},
                   text
          end

          assert sp_query(
                   ctx,
                   "SELECT v FROM #{m} WHERE time >= '2023-11-14T22:12:60Z' AND " <>
                     "time < '2023-11-14T22:13:01Z' ORDER BY time"
                 ) === {:ok, [%{"v" => 2}, %{"v" => 3}]}

          # Past :60 it is not a time; past the range the overflow shows the :60.
          assert sp_query(ctx, select <> "'2023-11-14T22:12:61Z'") ===
                   {:error,
                    %{
                      status: 500,
                      body: sp_timestamp_error("2023-11-14T22:12:61Z", "error parsing time")
                    }}

          assert sp_query(ctx, select <> "'2262-04-11T23:47:60Z'") ===
                   {:error,
                    %{
                      status: 500,
                      body:
                        sp_optimizer(
                          "Cast error: Overflow converting 2262-04-11 23:47:60 to Nanosecond. " <>
                            "The dates that can be represented as nanoseconds have to be " <>
                            "between 1677-09-21T00:12:44.0 and 2262-04-11T23:47:16.854775804"
                        )
                    }}
        end
      end
    end
  end

  defp small_fidelity_tests do
    quote location: :keep do
      describe "SQL parsing — contract: smaller answers" do
        test "NULL compared with anything is unknown", ctx do
          m = sp_fixture(ctx)

          for where <- [
                "NULL = time",
                "NULL < time",
                "NULL <> time",
                "NULL >= time",
                "time = NULL",
                "NULL = v",
                "NULL = h",
                "NULL = NULL",
                "NULL = 1",
                "NOT (NULL = time)"
              ] do
            assert sp_query(ctx, "SELECT v FROM #{m} WHERE #{where}") === {:ok, []}, where
          end
        end

        @tag local_divergence: "Local refuses a function it does not model by name"
        test "a function the double does not model is refused by name, or answered", ctx do
          m = sp_fixture(ctx)

          result = sp_query(ctx, "SELECT trunc(f) FROM #{m} ORDER BY time LIMIT 1")

          if sp_local?(),
            do: assert({:error, %{status: 400, body: "Client.Local: " <> _reason}} = result),
            else: assert(result === {:ok, [%{"trunc(#{m}.f)" => 1.0}]})
        end

        @tag local_divergence: "Local refuses a binary value by name"
        test "a hexadecimal string is a binary value, which the double does not model", ctx do
          m = sp_fixture(ctx)
          result = sp_query(ctx, "SELECT v FROM #{m} WHERE h = X'61' ORDER BY time")

          if sp_local?(),
            do: assert({:error, %{status: 400, body: "Client.Local: " <> _reason}} = result),
            else: assert(result === {:ok, [%{"v" => 1}, %{"v" => 3}]})
        end
      end
    end
  end

  defp request_param_tests do
    quote location: :keep do
      describe "SQL parsing — contract: what a parameter may be" do
        test "an object or an array is the engine's JSON error, at the byte it stops", ctx do
          m = sp_measurement("sp_param_json")
          sp_write(ctx, ["#{m} v=1i #{sp_ns(0)}"])
          sql = "select v from #{m} where v = $p"

          object =
            "serde json error: JSON objects are not supported as query parameters. " <>
              "Expected null, boolean, number, or string at line 1 column "

          array =
            "serde json error: JSON arrays are not supported as query parameters. " <>
              "Expected null, boolean, number, or string. at line 1 column "

          # The parser stops at the end of the value; the last parameter is
          # read with the brace that closes the object.
          for {params, text} <- [
                {%{p: %{a: 1}}, object},
                {%{p: %{}}, object},
                {%{a: 1, p: %{}}, object},
                {%{p: [1, 2]}, array},
                {%{p: []}, array},
                {%{p: %{a: %{b: [1]}}}, object},
                {%{p: [1, %{a: 2}]}, array}
              ] do
            {read, true} = sp_params_read(ctx, sql, params, "p", "json")

            assert sp_query(ctx, sql, params) ===
                     {:error, %{status: 400, body: text <> Integer.to_string(read + 1)}},
                   inspect(params)
          end

          # Another parameter follows, so its comma is not read.
          params = %{a: 1, p: [1, 2], z: 1}
          {read, false} = sp_params_read(ctx, sql, params, "p", "json")

          assert sp_query(ctx, sql, params) ===
                   {:error, %{status: 400, body: array <> Integer.to_string(read)}}
        end

        test "a number the engine's JSON parser cannot read stops it where the number ends",
             ctx do
          m = sp_measurement("sp_param_range")
          sp_write(ctx, ["#{m} v=1i #{sp_ns(0)}"])
          sql = "select v from #{m} where v = $p"
          big = Integer.pow(10, 400)

          out_of_range = fn read ->
            {:error,
             %{
               status: 400,
               body: "serde json error: number out of range at line 1 column #{read}"
             }}
          end

          # Past the float range, however it is written; the column is the byte
          # where the number ends, last parameter or not.
          for params <- [
                %{p: big},
                %{p: -big},
                %{p: Decimal.new("1e400")},
                %{p: Decimal.new("-1e400")},
                %{p: Integer.pow(2, 1024)},
                %{p: 2 * Integer.pow(10, 308)},
                %{a: 1, p: big, z: "x"},
                %{a: 1.5, p: big, z: big}
              ] do
            {read, _last} = sp_params_read(ctx, sql, params, "p", "json")
            assert sp_query(ctx, sql, params) === out_of_range.(read), inspect(params)
          end

          # A statement run with `execute_sql` carries no `format` in its body.
          params = %{a: 1, p: big}
          {read, _last} = sp_params_read(ctx, sql, params, "p", nil)
          assert sp_execute(ctx, sql, params) === out_of_range.(read)

          # serde_json multiplies the digits it keeps by a power of ten, so
          # the largest double is in and the one above it is out.
          for value <- [
                Integer.pow(10, 308),
                -Integer.pow(10, 308),
                1.797_693_134_862_315_7e308,
                Decimal.new("1.5e-400"),
                18_446_744_073_709_551_616
              ] do
            assert sp_query(ctx, sql, %{p: value}) === {:ok, []}, inspect(value)
          end
        end

        test "nil and [] are no parameters; a key or a params value that makes no sense is refused",
             ctx do
          m = sp_measurement("sp_param_shape")
          sp_write(ctx, ["#{m} v=1i #{sp_ns(0)}"])
          sql = "select v from #{m}"

          assert sp_raw(ctx, sql, params: nil) ===
                   {:ok, [%{"v" => 1}]}

          assert sp_raw(ctx, sql, params: []) ===
                   {:ok, [%{"v" => 1}]}

          assert sp_query(ctx, sql, %{{1, 2} => 1}) ===
                   {:error, {:invalid_param, "{1, 2}", :unsupported_key}}

          assert sp_query(ctx, sql, [{{:a, :b}, 1}]) ===
                   {:error, {:invalid_param, "{:a, :b}", :unsupported_key}}

          assert sp_query(ctx, sql, [1]) === {:error, {:invalid_param, "1", :unsupported_key}}
          assert sp_query(ctx, sql, 5) === {:error, {:invalid_param, "5", :unsupported_params}}

          assert sp_query(ctx, sql, "p") ===
                   {:error, {:invalid_param, ~s|"p"|, :unsupported_params}}
        end

        test "a Decimal without a number, and a value with no JSON form, are refused", ctx do
          for value <- ["NaN", "Infinity", "-Infinity"] do
            assert sp_query(ctx, "select 1", %{p: Decimal.new(value)}) ===
                     {:error, {:invalid_param, "p", :non_finite_decimal}},
                   value
          end

          assert sp_query(ctx, "select 1", %{p: {:a, :tuple}}) ===
                   {:error, {:invalid_param, "p", :unsupported_type}}

          assert sp_query(ctx, "select 1", p: self()) ===
                   {:error, {:invalid_param, "p", :unsupported_type}}
        end
      end
    end
  end
end
