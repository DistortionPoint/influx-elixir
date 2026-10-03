defmodule InfluxElixir.ClientContract.LineProtocol do
  @moduledoc """
  The line protocol grammar of both engines, asked through `write/3` (run by the
  `:write_admin` part of `InfluxElixir.ClientContract`): what each engine refuses
  and the words it says so in, what it accepts and stores, how a quote, an
  escape, a tab or a carriage return is read, and which line an error is
  numbered and echoed as.

  Every expectation was read from InfluxDB 3 Core (3.10.1) or InfluxDB 2.7 and is
  run against `Client.Local` and the real server of the profile. The case tables
  are those of `InfluxElixir.ClientContract.LineProtocolCases`:

    * `{line, message}`: the line is refused, with this message.
    * `{template, columns}`: the line is stored, and read back as these columns
      (`~m` in a template is a measurement name unique to the case; a `"time"`
      column is compared when a case names it and left out otherwise).
    * `{payload, [{line_number, message, echo}]}`: the lines of a payload that are
      refused, numbered and echoed as the engine does (`:any` where a case does not
      care for the message).

  Beside the tables, payloads of 10,001 to 20,001 lines are written to every
  client: `Client.Local` parses 10,000 lines at a time, and the engines have no
  such seam, so the numbers and echoes must not depend on where one falls. Two
  lines that the engine stores and `Client.Local` refuses by name (a float that is
  infinity, a tag key given twice) are pinned with the engine's answer.

  The grammar of the InfluxDB 3 profiles is spelled `v3`, InfluxDB 2's `v2`.
  """

  alias InfluxElixir.ClientContract.LineProtocolCases

  @need_space "Expected at least one space character, got end of input"

  @doc false
  @spec blocks(Macro.t(), atom()) :: [Macro.t()]
  def blocks(client, profile) when profile in [:v3_core, :v3_enterprise] do
    [
      v3_error_tests(client),
      v3_stored_tests(client),
      v3_numbering_tests(client),
      v3_engine_fact_tests(client),
      v3_chunk_tests(client)
    ]
  end

  def blocks(client, :v2),
    do: [v2_error_tests(client), v2_stored_tests(client), v2_chunk_tests(client)]

  def blocks(_client, _profile), do: []

  # ---------------------------------------------------------------------------
  # Outcomes
  # ---------------------------------------------------------------------------

  @doc false
  # What an InfluxDB 3 write of `payload` answered: `:written`, the lines it
  # refused as `{line_number, message, echo}`, or any other answer as it came.
  @spec v3_outcome(module(), map(), binary()) :: term()
  def v3_outcome(client, ctx, payload) do
    case client.write(ctx.conn, payload, database: ctx.database) do
      {:ok, :written} ->
        :written

      {:error, %{status: 400, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"error" => "partial write of line protocol occurred", "data" => data}} ->
            {:refused,
             for(e <- data, do: {e["line_number"], e["error_message"], e["original_line"]})}

          _other ->
            {:error, 400, body}
        end

      other ->
        other
    end
  end

  @doc false
  # What an InfluxDB 2 write of `payload` answered: `:written`, the 400 message,
  # or any other answer as it came.
  @spec v2_outcome(module(), map(), binary()) :: term()
  def v2_outcome(client, ctx, payload) do
    case client.write(ctx.conn, payload, database: ctx.database) do
      {:ok, :written} ->
        :written

      {:error, %{status: 400, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"code" => "invalid", "message" => message}} -> {:invalid, message}
          _other -> {:error, 400, body}
        end

      other ->
        other
    end
  end

  @doc false
  # A name for a case's measurement, short enough for the engine's echo.
  @spec name(binary()) :: binary()
  def name(prefix), do: InfluxElixir.IntegrationHelper.unique_name(prefix)

  @doc false
  # The measurement placeholder of a template, filled.
  @spec fill(binary(), binary()) :: binary()
  def fill(template, measurement), do: String.replace(template, "~m", measurement)

  @doc false
  # An InfluxQL read of everything a measurement holds, without its name and,
  # unless `keep_time?`, its time.
  @spec v3_columns(module(), map(), binary(), boolean()) :: term()
  def v3_columns(client, ctx, measurement, keep_time? \\ false) do
    dropped = if keep_time?, do: ["iox::measurement"], else: ["time", "iox::measurement"]

    case client.query_influxql(ctx.conn, ~s|SELECT * FROM "#{measurement}"|,
           database: ctx.database
         ) do
      {:ok, rows} -> {:ok, Enum.map(rows, &Map.drop(&1, dropped))}
      other -> other
    end
  end

  @doc false
  # The lines of a payload of `count` lines: `m v=<i>i <i>`, and `BAD<i>` (a
  # measurement with nothing after it) for the numbers in `bad`.
  @spec many_lines(pos_integer(), [pos_integer()], binary()) :: binary()
  def many_lines(count, bad, measurement) do
    Enum.map_join(1..count, "\n", fn i ->
      if i in bad, do: "BAD#{i}", else: "#{measurement} v=#{i}i #{i}"
    end)
  end

  @doc false
  # A Flux read of what a measurement holds: its `{field, value}` pairs, sorted.
  @spec v2_fields(module(), map(), binary()) :: term()
  def v2_fields(client, ctx, measurement) do
    case flux(client, ctx, measurement) do
      {:ok, rows} -> {:ok, rows |> Enum.map(&{&1["_field"], &1["_value"]}) |> Enum.sort()}
      other -> other
    end
  end

  @doc false
  @spec flux(module(), map(), binary()) :: term()
  def flux(client, ctx, measurement) do
    client.query_flux(
      ctx.conn,
      ~s[from(bucket: "#{ctx.database}") |> range(start: 0, stop: 4102444800) ] <>
        ~s[|> filter(fn: (r) => r._measurement == "#{measurement}")]
    )
  end

  # ---------------------------------------------------------------------------
  # InfluxDB 3
  # ---------------------------------------------------------------------------
  defp v3_error_tests(client) do
    quote location: :keep do
      describe "line protocol grammar — InfluxDB 3 errors, in the engine's words" do
        test "a line the engine refuses is a 400 that numbers it and says why", ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            unquote(Macro.escape(LineProtocolCases.v3_errors())),
            fn {line, message} ->
              case InfluxElixir.ClientContract.LineProtocol.v3_outcome(
                     unquote(client),
                     ctx,
                     line
                   ) do
                {:refused, [{1, ^message, _echo}]} -> :ok
                other -> {:mismatch, other}
              end
            end
          )
        end

        test "a payload of nothing but comments and blanks is empty", ctx do
          for payload <- [" # only a comment", "\n\n# a\n  \n"] do
            assert {:error, %{status: 400, body: "incoming write was empty"}} =
                     unquote(client).write(ctx.conn, payload, database: ctx.database)
          end
        end
      end
    end
  end

  defp v3_stored_tests(client) do
    quote location: :keep do
      describe "line protocol grammar — InfluxDB 3 accepted lines" do
        test "what the grammar lets through is stored as the columns it names", ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            unquote(Macro.escape(LineProtocolCases.v3_stored())),
            fn {template, expected} ->
              alias InfluxElixir.ClientContract.LineProtocol, as: LP
              m = LP.name("lpg")
              payload = LP.fill(template, m)

              keep_time? = Enum.any?(expected, &Map.has_key?(&1, "time"))

              case {LP.v3_outcome(unquote(client), ctx, payload),
                    LP.v3_columns(unquote(client), ctx, m, keep_time?)} do
                {:written, {:ok, rows}} ->
                  if Enum.sort(rows) === Enum.sort(expected),
                    do: :ok,
                    else: {:mismatch, %{read: rows}}

                other ->
                  {:mismatch, other}
              end
            end
          )
        end

        test "\\\\, \\, and \\<space> are undone everywhere, \\= outside a measurement", ctx do
          alias InfluxElixir.ClientContract.LineProtocol, as: LP
          escapes = unquote(Macro.escape(LineProtocolCases.v3_escapes()))
          prefix = LP.name("lpe")

          lines =
            escapes
            |> Enum.with_index(1)
            |> Enum.flat_map(fn {{suffix, _tag, _name}, i} ->
              ["#{prefix}t,k=a#{suffix} v=1i #{i}", "#{prefix}#{i}#{suffix} v=1i #{i}"]
            end)

          # A measurement in quotes keeps its quotes; a carriage return is a name's byte.
          lines = lines ++ [~s("#{prefix}q" f=1i 1), "#{prefix}c\rx f=1i 1"]

          assert LP.v3_outcome(unquote(client), ctx, Enum.join(lines, "\n")) === :written

          assert {:ok, rows} =
                   unquote(client).query_influxql(
                     ctx.conn,
                     "SELECT k, v FROM #{prefix}t",
                     database: ctx.database
                   )

          assert Enum.map(rows, & &1["k"]) === Enum.map(escapes, &elem(&1, 1))

          assert {:ok, measurements} =
                   unquote(client).query_influxql(ctx.conn, "SHOW MEASUREMENTS",
                     database: ctx.database
                   )

          expected =
            escapes
            |> Enum.with_index(1)
            |> Enum.map(fn {{_suffix, _tag, name}, i} -> "#{prefix}#{i}#{name}" end)

          assert measurements |> Enum.map(& &1["name"]) |> Enum.sort() ===
                   Enum.sort(["#{prefix}t", ~s("#{prefix}q"), "#{prefix}c\rx" | expected])
        end
      end
    end
  end

  defp v3_numbering_tests(client) do
    quote location: :keep do
      describe "line protocol grammar — InfluxDB 3 line numbers and echoes" do
        test "an error is numbered among the lines that count and echoes its line", ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            unquote(Macro.escape(LineProtocolCases.v3_numbered())),
            fn {payload, expected} ->
              outcome =
                InfluxElixir.ClientContract.LineProtocol.v3_outcome(
                  unquote(client),
                  ctx,
                  payload
                )

              with {:refused, found} <- outcome,
                   true <- length(found) === length(expected),
                   true <-
                     Enum.all?(Enum.zip(found, expected), fn {a, e} ->
                       InfluxElixir.ClientContract.LineProtocol.same_error?(a, e)
                     end) do
                :ok
              else
                _other -> {:mismatch, outcome}
              end
            end
          )
        end
      end
    end
  end

  defp v3_engine_fact_tests(client) do
    quote location: :keep do
      describe "line protocol — InfluxDB 3 lines the engine stores and Local refuses" do
        @tag local_divergence:
               "the engine stores a float beyond 64 bits as infinity, Local refuses the line"
        test "a float too large for 64 bits is infinity", ctx do
          alias InfluxElixir.ClientContract.LineProtocol, as: LP

          InfluxElixir.TestSupport.Check.each_case(
            [{"1e999", "v > 1e300"}, {"-2.5e999", "v < -1e300"}],
            fn {literal, bound} ->
              m = LP.name("lpinf")

              result =
                unquote(client).write(ctx.conn, "#{m} v=#{literal} 1000", database: ctx.database)

              if unquote(client) === InfluxElixir.Client.Local do
                assert {:error, %{status: 400, body: body}} = result

                assert %{"data" => [%{"error_message" => message}]} = Jason.decode!(body)

                assert message ===
                         "Client.Local: the float #{literal} is infinity on InfluxDB 3 Core, " <>
                           "which the double cannot hold"
              else
                assert result === {:ok, :written}

                # Infinity is past every bound, and has no JSON form: it is read as null.
                assert unquote(client).query_sql(
                         ctx.conn,
                         ~s|SELECT v FROM "#{m}" WHERE #{bound}|,
                         database: ctx.database
                       ) === {:ok, [%{"v" => nil}]}
              end
            end
          )
        end

        @tag local_divergence:
               "the engine stores a tag key given twice and then fails every query, Local " <>
                 "refuses the line"
        test "a tag key given twice is stored and fails every query of the table", ctx do
          alias InfluxElixir.ClientContract.LineProtocol, as: LP

          InfluxElixir.TestSupport.Check.each_case(
            [{"~m,t=1,t=1 v=1 1000", "t"}, {~S"~m,t\ x=1,t\ x=2 v=1 1000", "t x"}],
            fn {template, key} ->
              m = LP.name("lpdup")

              result =
                unquote(client).write(ctx.conn, LP.fill(template, m), database: ctx.database)

              if unquote(client) === InfluxElixir.Client.Local do
                assert {:error, %{status: 400, body: body}} = result

                assert %{"data" => [%{"error_message" => message}]} = Jason.decode!(body)

                assert message ===
                         "Client.Local: the tag key #{key} is given twice; InfluxDB 3 Core " <>
                           "stores such a line and then answers every query of the table " <>
                           "with a 500"
              else
                assert result === {:ok, :written}

                broken =
                  "Execution error: error getting batches Error creating record batch: " <>
                    "Invalid argument error: all columns in a record batch must have the " <>
                    "same length"

                assert {:error, %{status: 500, body: ^broken}} =
                         unquote(client).query_sql(ctx.conn, ~s|SELECT * FROM "#{m}"|,
                           database: ctx.database
                         )

                assert {:error, %{status: 500, body: ^broken}} =
                         unquote(client).query_influxql(ctx.conn, ~s|SELECT * FROM "#{m}"|,
                           database: ctx.database
                         )
              end
            end
          )
        end
      end
    end
  end

  # A payload is parsed by `Client.Local` 10,000 lines at a time, so a payload has
  # to exceed 10,000 lines for a boundary to be crossed. The bad lines fall on
  # either side of the first boundary and, where the payload is long enough,
  # of the second.
  defp v3_chunk_tests(client) do
    quote location: :keep do
      describe "line protocol — InfluxDB 3 payloads of many lines" do
        test "an error is numbered and echoed wherever it is, and the other lines written",
             ctx do
          alias InfluxElixir.ClientContract.LineProtocol, as: LP
          need_space = unquote(@need_space)
          bad = [9_999, 10_000, 10_001, 19_999, 20_000, 20_001]

          assert {:refused, found} =
                   LP.v3_outcome(unquote(client), ctx, LP.many_lines(20_001, bad, "m"))

          assert found === for(i <- bad, do: {i, need_space, "BAD#{i}"})

          assert {:ok, rows} =
                   unquote(client).query_influxql(ctx.conn, "SELECT count(v) FROM m",
                     database: ctx.database
                   )

          assert Enum.map(rows, & &1["count"]) === [20_001 - length(bad)]
        end

        test "comments and blank lines are not numbered, wherever the boundaries fall", ctx do
          alias InfluxElixir.ClientContract.LineProtocol, as: LP

          # Every third line is a comment, so physical line i is line i - div(i, 3).
          bad = [14_999, 15_001]

          payload =
            Enum.map_join(1..15_002, "\n", fn i ->
              cond do
                rem(i, 3) === 0 -> "# c#{i}"
                i in bad -> "BAD#{i}"
                true -> "m v=1i #{i}"
              end
            end)

          # The engine echoes the physical line that has the error's number.
          assert LP.v3_outcome(unquote(client), ctx, payload) ===
                   {:refused,
                    [
                      {10_000, unquote(@need_space), "m v=1i 10000"},
                      {10_001, unquote(@need_space), "m v=1i 10001"}
                    ]}
        end

        test "a payload of only comments is empty, however long", ctx do
          text = Enum.map_join(1..10_001, "\n", &"# c#{&1}")

          assert {:error, %{status: 400, body: "incoming write was empty"}} =
                   unquote(client).write(ctx.conn, text, database: ctx.database)
        end
      end
    end
  end

  @doc false
  @spec same_error?(tuple(), tuple()) :: boolean()
  def same_error?({n, message, echo}, {n, expected_message, expected_echo}),
    do: matches?(message, expected_message) and matches?(echo, expected_echo)

  def same_error?(_found, _expected), do: false

  defp matches?(_found, :any), do: true
  defp matches?(found, expected), do: found === expected

  # ---------------------------------------------------------------------------
  # InfluxDB 2
  # ---------------------------------------------------------------------------

  defp v2_error_tests(client) do
    quote location: :keep do
      describe "line protocol grammar — InfluxDB 2 errors, in the Go parser's words" do
        test "a line that does not parse is a 400 that quotes it and says why", ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            unquote(Macro.escape(LineProtocolCases.v2_errors())),
            fn {line, reason} ->
              expected = "unable to parse '#{line}': #{reason}"

              case InfluxElixir.ClientContract.LineProtocol.v2_outcome(
                     unquote(client),
                     ctx,
                     line
                   ) do
                {:invalid, ^expected} -> :ok
                other -> {:mismatch, other}
              end
            end
          )
        end

        test "every line of a payload that fails is quoted, in order", ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            unquote(Macro.escape(LineProtocolCases.v2_payloads())),
            fn {payload, failures} ->
              expected =
                Enum.map_join(failures, "\n", fn {quoted, reason} ->
                  "unable to parse '#{quoted}': #{reason}"
                end)

              case InfluxElixir.ClientContract.LineProtocol.v2_outcome(
                     unquote(client),
                     ctx,
                     payload
                   ) do
                {:invalid, ^expected} -> :ok
                other -> {:mismatch, other}
              end
            end
          )
        end
      end
    end
  end

  defp v2_stored_tests(client) do
    quote location: :keep do
      describe "line protocol grammar — InfluxDB 2 accepted lines" do
        test "what the grammar lets through is stored as the fields it names", ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            unquote(Macro.escape(LineProtocolCases.v2_stored())),
            fn {template, expected} ->
              alias InfluxElixir.ClientContract.LineProtocol, as: LP
              m = LP.name("lpg")

              case {LP.v2_outcome(unquote(client), ctx, LP.fill(template, m)),
                    LP.v2_fields(unquote(client), ctx, m)} do
                {:written, {:ok, fields}} ->
                  if fields === Enum.sort(expected),
                    do: :ok,
                    else: {:mismatch, %{read: fields}}

                other ->
                  {:mismatch, other}
              end
            end
          )
        end

        test "InfluxDB 2 undoes only an escape of its set and keeps every other backslash",
             ctx do
          alias InfluxElixir.ClientContract.LineProtocol, as: LP

          escapes = unquote(Macro.escape(LineProtocolCases.v2_escapes()))

          m = LP.name("lpe")

          lines =
            escapes
            |> Enum.with_index(1)
            |> Enum.map_join("\n", fn {{suffix, _tag}, i} ->
              "#{m},k=a#{suffix} v=1i #{i}"
            end)

          assert LP.v2_outcome(unquote(client), ctx, lines) === :written
          assert {:ok, rows} = LP.flux(unquote(client), ctx, m)

          assert rows |> Enum.map(& &1["k"]) |> Enum.sort() ===
                   escapes |> Enum.map(&elem(&1, 1)) |> Enum.sort()
        end
      end
    end
  end

  # See `v3_chunk_tests/1`: the lines that fail are quoted, in order, wherever they are.
  defp v2_chunk_tests(client) do
    quote location: :keep do
      describe "line protocol — InfluxDB 2 payloads of many lines" do
        test "the line of an error is quoted wherever it is, in order", ctx do
          alias InfluxElixir.ClientContract.LineProtocol, as: LP
          bad = [9_999, 10_000, 10_001]
          m = LP.name("lpmany")

          assert LP.v2_outcome(unquote(client), ctx, LP.many_lines(10_001, bad, m)) ===
                   {:invalid,
                    Enum.map_join(bad, "\n", &"unable to parse 'BAD#{&1}': missing fields")}
        end
      end
    end
  end
end
