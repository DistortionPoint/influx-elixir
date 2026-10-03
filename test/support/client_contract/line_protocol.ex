defmodule InfluxElixir.ClientContract.LineProtocol do
  @moduledoc """
  The line protocol grammar of both engines, asked through `write/3` (run by the
  `:write_admin` part of `InfluxElixir.ClientContract`): what each engine refuses
  and the words it says so in, what it accepts and stores, how a quote, an
  escape, a tab or a carriage return is read, and which line an error is
  numbered and echoed as.

  Every expectation was read from InfluxDB 3 Core (3.10.1) or InfluxDB 2.7 and is
  run against `Client.Local` and the real server of the profile. The case tables
  are module attributes of the tests:

    * `{line, message}`: the line is refused, with this message.
    * `{template, columns}`: the line is stored, and read back as these columns
      (`~m` in a template is a measurement name unique to the case).
    * `{payload, [{line_number, message, echo}]}`: the lines of a payload that are
      refused, numbered and echoed as the engine does (`:any` where a case does not
      care for the message).

  The grammar of the InfluxDB 3 profiles is spelled `v3`, InfluxDB 2's `v2`.
  """

  @trailing "Could not parse entire line. Found trailing content: "
  @no_fields "No fields were provided"
  @need_space "Expected at least one space character, got end of input"

  @doc false
  @spec blocks(Macro.t(), atom()) :: [Macro.t()]
  def blocks(client, profile) when profile in [:v3_core, :v3_enterprise] do
    [v3_error_tests(client), v3_stored_tests(client), v3_numbering_tests(client)]
  end

  def blocks(client, :v2), do: [v2_error_tests(client), v2_stored_tests(client)]
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
  # An InfluxQL read of everything a measurement holds, without time and name.
  @spec v3_columns(module(), map(), binary()) :: term()
  def v3_columns(client, ctx, measurement) do
    case client.query_influxql(ctx.conn, ~s|SELECT * FROM "#{measurement}"|,
           database: ctx.database
         ) do
      {:ok, rows} -> {:ok, Enum.map(rows, &Map.drop(&1, ["time", "iox::measurement"]))}
      other -> other
    end
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

  defp v3_errors do
    [
      # Most errors quote ten characters of what is left, and dots for the rest.
      {"zz v=1 abcdefghi", @trailing <> "` abcdefghi`"},
      {"zz v=1 abcdefghij", @trailing <> "` abcdefghi...`"},
      {"zz v=1 5 abcdefghijklmnop", @trailing <> "`abcdefghij...`"},
      {"zz v=1,w=abcdefghijklmnop", @trailing <> "`w=abcdefgh...`"},
      {"zz v=1,wwwwwwwwww", @trailing <> "`wwwwwwwwww`"},
      {"zz v=1,wwwwwwwwwwwwwww", @trailing <> "`wwwwwwwwww...`"},
      {"zz v=1 ééééééééééé", @trailing <> "` ééééééééé...`"},
      {"zz,t= abcdefghijklmnop v=1 5", "Expected tag value, got ` abcdefghi...`"},
      {"zz,=abcdefghijklmnop v=1 5", "Expected tag key, got `=abcdefghi...`"},
      {"zz,t=1,uuuuuuuuuuuuuuuuuuuuu v=1",
       "Tag set malformed: could not find equals sign in `t=1,uuuuuu...`"},
      # "Expected at least one space character" quotes all of what is left.
      {"zz\tabcdefghijklmnop v=1",
       "Expected at least one space character, got `\tabcdefghijklmnop v=1`"},
      # A number is the longest match; what follows is trailing content.
      {"zz v=5.", @trailing <> "`.`"},
      {"zz v=1e", @trailing <> "`e`"},
      {"zz v=0x10", @trailing <> "`x10`"},
      {"zz v=1_000", @trailing <> "`_000`"},
      {"zz v=1.5.5", @trailing <> "`.5`"},
      {"zz v=1i2", @trailing <> "`2`"},
      {"zz v=1ii", @trailing <> "`i`"},
      {"zz v=5.i", @trailing <> "`.i`"},
      {"zz v=1.0i", @trailing <> "`i`"},
      {"zz v=1e3i", @trailing <> "`i`"},
      {"zz v=1.e3", @trailing <> "`.e3`"},
      {"zz v=-5.", @trailing <> "`.`"},
      {"zz v=5.e1", @trailing <> "`.e1`"},
      {"zz v=-7u", @trailing <> "`u`"},
      {"zz v=5.u", @trailing <> "`.u`"},
      {"zz v=1.5u", @trailing <> "`u`"},
      {"zz v=1x", @trailing <> "`x`"},
      # A boolean is the longest of true, True, TRUE, t, T and the false forms.
      {"zz v=true1", @trailing <> "`1`"},
      {"zz v=tRUE", @trailing <> "`RUE`"},
      {"zz v=TrUe", @trailing <> "`rUe`"},
      {"zz v=tru", @trailing <> "`ru`"},
      # A string value ends at its closing quote.
      {~s|zz v="a"b"|, @trailing <> ~s|`b"`|},
      # After the fields: whitespace and a timestamp, then nothing.
      {"zz v=1 abc", @trailing <> "` abc`"},
      {"zz v=1 1.5", @trailing <> "`.5`"},
      {"zz v=1 +5", @trailing <> "` +5`"},
      {"zz v=1 1e3", @trailing <> "`e3`"},
      {"zz v=1 0x1", @trailing <> "`x1`"},
      {"zz v=1  ", @trailing <> "`  `"},
      {"zz v=1 5 6 7", @trailing <> "`6 7`"},
      {"zz v=1 5abc", @trailing <> "`abc`"},
      {"zz v=1 5,6", @trailing <> "`,6`"},
      {"zz v=1 -", @trailing <> "` -`"},
      {"zz v=1 99999999999999999999", "Unable to parse timestamp value `99999999999999999999`"},
      # The second field that fails leaves the line after its comma, later ones at it.
      {"zz v=1,w=", @trailing <> "`w=`"},
      {"zz v=1,w", @trailing <> "`w`"},
      {"zz v=1,=2", @trailing <> "`=2`"},
      {"zz v=1, w=2", @trailing <> "` w=2`"},
      {"zz v=1,w=2,x=", @trailing <> "`,x=`"},
      {"zz v=1,w=2,x", @trailing <> "`,x`"},
      {"zz v=1,w=2,", @trailing <> "`,`"},
      {"zz v=1,w=2,=3", @trailing <> "`,=3`"},
      {"zz v=1,w=2,x=3,y= 5", @trailing <> "`,y= 5`"},
      {"zz v=1,, ", @trailing <> "`, `"},
      {"zz v=1 ,w=2", @trailing <> "` ,w=2`"},
      {~s|zz a=1,"b c"=2|, @trailing <> ~S|`"b c"=2`|},
      # A tag set is read to its end, and quotes mean nothing in a name.
      {"zz,t v=1", "Tag set malformed: could not find equals sign in `t v=1`"},
      {"zz,t=1,u v=1", "Tag set malformed: could not find equals sign in `t=1,u v=1`"},
      {"zz,t", "Tag set malformed: could not find equals sign in `t`"},
      {"zz,t=1,u=2,w v=1", "Tag set malformed: could not find equals sign in `t=1,u=2,w ...`"},
      {"zz,t=1,u=2,, v=1", "Tag set malformed: could not find equals sign in `t=1,u=2,, ...`"},
      {"zz,,", "Tag set malformed: could not find equals sign in `,`"},
      {"zz,t= v=1", "Expected tag value, got ` v=1`"},
      {"zz,t=1,u= v=1", "Expected tag value, got ` v=1`"},
      {"zz,t=", "Expected tag value, got end of input"},
      {"zz,=1 v=1", "Expected tag key, got `=1 v=1`"},
      {"zz,t=1,=2 v=1", "Expected tag key, got `=2 v=1`"},
      {"zz, v=1", "Expected tag key, got ` v=1`"},
      {"zz,t=1,u=2, v=1", "Expected tag key, got ` v=1`"},
      {"zz,", "Expected tag key, got end of input"},
      {"zz,t=1,", "Expected tag key, got end of input"},
      {"zz,t=1", @need_space},
      {"zz,t=1,u=2", @need_space},
      {"justmeasurement", @need_space},
      {"zz,t=1 ", @no_fields},
      {",t=1 v=1", "Invalid measurement was provided"},
      {",", "Invalid measurement was provided"},
      {~s|m"x y" v=1|, @no_fields},
      {~s|zz,t="a b" v=1|, @no_fields},
      # A tab ends a name as a space does, but a space alone separates the sections.
      {"zz\tv=1 5", "Expected at least one space character, got `\tv=1 5`"},
      {"zz,t=a\tb v=1", "Expected at least one space character, got `\tb v=1`"},
      {"zz,t\tx=1 v=1", "Tag set malformed: could not find equals sign in `t\tx=1 v=1`"},
      {"zz,\tt=1 v=1", "Expected tag key, got `\tt=1 v=1`"},
      {"zz,t=\t1 v=1", "Expected tag value, got `\t1 v=1`"},
      {"zz\tv=1", "Expected at least one space character, got `\tv=1`"},
      {"zz v\t=1", @no_fields},
      {"zz v=1,w\t=2", @trailing <> "`w\t=2`"},
      {"zz v=1\t5", @trailing <> "`\t5`"},
      {"zz v=1 5\t", @trailing <> "`\t`"},
      {"zz v=1,w=2,x\t=3", @trailing <> "`,x\t=3`"},
      {"zz v=2\",g=\t\"q \" 7", @trailing <> "`\",g=\t\"q \" ...`"},
      # A carriage return ends a value or a timestamp.
      {"zz v=1i\r", @trailing <> "`\r`"},
      {"zz v=1i 5\r", @trailing <> "`\r`"},
      # A number outside what its type holds is its own error.
      {"zz v=9223372036854775808i", "Unable to parse integer value `9223372036854775808`"},
      {"zz v=18446744073709551616u",
       "Unable to parse unsigned integer value `18446744073709551616`"},
      # A field named twice, or also a tag: the first the line meets wins.
      {"zz,t=1 a=1,a=2,t=3", "invalid line protocol - multiple instances of 'a' field found"},
      {"zz,t=1 t=3,a=1,a=2",
       "invalid column type for column 't', expected iox::column_type::tag, " <>
         "got iox::column_type::field::float"},
      # A parse error comes before either.
      {"zz v=1,v=2 abc", @trailing <> "` abc`"}
    ] ++
      for(
        value <-
          ~w(.5 -.5 +5 +1i .5i e1 NaN inf -inf Infinity --1 .e3 .5u x) ++ ["\"abc", "abc\""],
        do: {"zz v=#{value}", @no_fields}
      ) ++
      for(
        line <- ["zz =1", "zz v", "zz v= 1", "zz v =1", "zz ", "zz   ", "zz 5"],
        do: {line, @no_fields}
      ) ++ [{~s|zz "a b"=1|, @no_fields}]
  end

  defp v3_stored do
    [
      # a comma in a tag key or a field key, an `=` in a tag value, a trailing comma
      {"~m,t=1,,u=2 v=1", [%{",u" => "2", "t" => "1", "v" => 1.0}]},
      {"~m,t==b v=1", [%{"t" => "=b", "v" => 1.0}]},
      {"~m v=1,w,x=2 5", [%{"w,x" => 2.0, "v" => 1.0}]},
      {~s|~m "k"=1 5|, [%{~s|"k"| => 1.0}]},
      {"~m v=1,,w=2", [%{"v" => 1.0, ",w" => 2.0}]},
      {~S|~m a\ b=1|, [%{"a b" => 1.0}]},
      # the forms of a number, and a boolean
      {"~m v=1E+3", [%{"v" => 1000.0}]},
      {"~m v=1.5E-3", [%{"v" => 0.0015}]},
      {"~m v=007", [%{"v" => 7.0}]},
      {"~m v=9223372036854775807i", [%{"v" => 9_223_372_036_854_775_807}]},
      {"~m v=1u", [%{"v" => 1}]},
      {"~m a=T,b=f,c=True,d=FALSE", [%{"a" => true, "b" => false, "c" => true, "d" => false}]},
      # a string, a tab inside one
      {~S|~m v="a\"b"|, [%{"v" => ~s|a"b|}]},
      {"~m v=\"a\tb\" 5", [%{"v" => "a\tb"}]},
      # whitespace around the timestamp
      {"~m v=1 5 ", [%{"v" => 1.0}]},
      {"~m v=1 5  ", [%{"v" => 1.0}]},
      {"~m v=1  5", [%{"v" => 1.0}]},
      # leading blanks, comments and blank lines are skipped
      {"\n  # a comment\n\t \n  ~m v=1\n", [%{"v" => 1.0}]},
      # a carriage return is a tag value's byte
      {"~m,t=a\rb v=1i 5", [%{"t" => "a\rb", "v" => 1}]},
      # a newline inside a string value is part of the value
      {~s|~m f="a\nb" 1\n~m g=2i 2|, [%{"f" => "a\nb"}, %{"g" => 2}]},
      # a quote means nothing in a tag key, a tag value or a field key
      {~s|~m,"k"="v" "f"=1i 1|, [%{~s|"k"| => ~s|"v"|, ~s|"f"| => 1}]}
    ]
  end

  # `{suffix, tag value, measurement}`: what `m,k=a<suffix>` and `m<suffix>` hold.
  defp v3_escapes do
    [
      {~S|\,x|, "a,x", ",x"},
      {~S|\ x|, "a x", " x"},
      {~S|\=x|, "a=x", ~S|\=x|},
      {~S|\"x|, ~S|a\"x|, ~S|\"x|},
      {~S|\\x|, ~S|a\x|, ~S|\x|},
      {~S|\\=x|, ~S|a\=x|, ~S|\=x|},
      {~S|\\\,x|, ~S|a\,x|, ~S|\,x|},
      {~S|\\\\x|, ~S|a\\x|, ~S|\\x|},
      {~S|\x|, ~S|a\x|, ~S|\x|}
    ]
  end

  # `{payload, [{line_number, message, echo}]}`.
  defp v3_numbered do
    [
      # An error is numbered among the lines that count and echoes the physical
      # line with that number; blank lines and comments are not counted.
      {"#c\nBAD1\nBAD2\nBAD3",
       [{1, @need_space, "#c"}, {2, @need_space, "BAD1"}, {3, @need_space, "BAD2"}]},
      {"\nBAD", [{1, @need_space, ""}]},
      {"BAD1\n#c\n\nBAD2\nBAD3",
       [{1, @need_space, "BAD1"}, {2, @need_space, "#c"}, {3, @need_space, ""}]},
      # The echo is cut to 20 characters and loses a carriage return.
      {"zz v=1i\r\nBAD", [{1, @trailing <> "`\r`", "zz v=1i"}, {2, @need_space, "BAD"}]},
      {"zz v=1i\r", [{1, @trailing <> "`\r`", "zz v=1i\r"}]},
      {"abcdefghijklmnopqrstuvwxyz", [{1, @need_space, "abcdefghijklmnopqrst"}]},
      # A quote in a measurement, a tag key or a field key means nothing.
      {~s|m"a f=1i 1\nBAD|, [{2, @need_space, :any}]},
      {~s|m,k"x=1 f=1i 1\nBAD|, [{2, @need_space, :any}]},
      {~s|m f"x=1i 1\nBAD|, [{2, @need_space, :any}]},
      # A quote in the timestamp opens a string that takes the next line.
      {~s|m f=1i 1 "\nBAD|, [{1, @trailing <> ~s|`"\nBAD`|, ~s|m f=1i 1 "|}]},
      # A quote after a comma that closes the = opens nothing.
      {~s|m f=1i,"\nBAD|, [{1, :any, :any}, {2, @need_space, :any}]},
      {~s|m f=1i, "g\nBAD|, [{1, :any, :any}, {2, @need_space, :any}]},
      {~s|m f="a,b",g,"\nBAD|, [{1, :any, :any}, {2, @need_space, :any}]},
      # A backslash takes the next byte with it, a newline too.
      {"BAD1\\\nBAD2\nBAD3", [{1, @need_space, "BAD1\\"}, {2, @need_space, "BAD2"}]},
      # The engine skips a comment through its physical line.
      {~s|# a=1 "x\nBAD|, [{1, @need_space, ~s|# a=1 "x|}]}
    ]
  end

  defp v3_error_tests(client) do
    quote location: :keep do
      describe "line protocol grammar — InfluxDB 3 errors, in the engine's words" do
        test "a line the engine refuses is a 400 that numbers it and says why", ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            unquote(Macro.escape(v3_errors())),
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
            unquote(Macro.escape(v3_stored())),
            fn {template, expected} ->
              alias InfluxElixir.ClientContract.LineProtocol, as: LP
              m = LP.name("lpg")
              payload = LP.fill(template, m)

              case {LP.v3_outcome(unquote(client), ctx, payload),
                    LP.v3_columns(unquote(client), ctx, m)} do
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
          escapes = unquote(Macro.escape(v3_escapes()))
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
            unquote(Macro.escape(v3_numbered())),
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

  # `{line, reason}`: the Go parser's words, as the line is quoted.
  defp v2_errors do
    [
      # the key block
      {"zz", "missing fields"},
      {"zz,t=1", "missing fields"},
      {"zz,t=a\\", "missing fields"},
      {",", "missing measurement"},
      {"zz,t=1,u v=1", "missing tag value"},
      {"zz,t= v=1", "missing tag value"},
      {"zz,t", "missing tag value"},
      {"zz,t=", "missing tag value"},
      {"zz,=1 v=1", "missing tag key"},
      {"zz, v=1", "missing tag key"},
      {"zz,,t=1 v=1", "missing tag key"},
      {"zz,", "missing tag key"},
      {"zz,t=1,t=2 v=", "duplicate tags"},
      {"zz,t=a\\,b,t=a\\,b v=1", "duplicate tags"},
      # an escape is judged by the byte before it
      {~S"zq\\ v=1i 5", "invalid field format"},
      {~S"zq,t=a\\ v=1i 5", "invalid tag format"},
      {~S"zq,t\\ v=1i 5", "invalid field format"},
      {~S"zq,t\\=1 v=1i", "missing tag value"},
      {~S"zq,t=\\ v=1i", "invalid tag format"},
      {~S"zq,t\\", "missing tag value"},
      {~S"zq\\", "missing fields"},
      # the fields block
      {"zz v=1,=2", "missing field key"},
      {"zz v=,w=1", "missing field value"},
      {"zz v=1,w=", "missing field value"},
      {"zz v", "invalid field format"},
      {"zz 5", "invalid field format"},
      {"zz ", "invalid field format"},
      {"zz v=1,w", "invalid field format"},
      {"zz v=1,,w=2", "invalid field format"},
      {"zz v=1,", "invalid field format"},
      {~S"zz a\=1", "invalid field format"},
      {~S"zz v\\ =1i 5", "invalid field format"},
      {~S|zz "a b"=1|, "invalid field format"},
      {~S|zz v="abc|, "unbalanced quotes"},
      {~S|zz v="a"b"|, "unbalanced quotes"},
      {"zz v=1_000", "invalid number"},
      {"zz v=1.5.5", "invalid number"},
      {"zz v=1i2", "invalid number"},
      {"zz v=-", "invalid number"},
      {"zz v=-i", "invalid number"},
      {"zz v=NaN", "invalid number"},
      {"zz v=nan", "invalid number"},
      {"zz v=-inf", "invalid number"},
      {"zz v=-7u", "invalid number"},
      {"zz v=1e3i", "invalid number"},
      {"zz v=1=2", "invalid number"},
      {"zz v=..", "invalid number"},
      {"zz v=-.", "invalid number"},
      {"zz v=1e", "invalid float"},
      {"zz v=1e5e5", "invalid float"},
      {"zz v=1e+", "invalid float"},
      {"zz v=e1", "invalid boolean"},
      {"zz v=inf", "invalid boolean"},
      {"zz v=true1", "invalid boolean"},
      {"zz v=tr", "invalid boolean"},
      {"zz v==1", "invalid boolean"},
      {"zz v=x", "invalid boolean"},
      # the time block, and what may follow it
      {"zz v=1 1.5", "bad timestamp"},
      {"zz v=1 +5", "bad timestamp"},
      {"zz v=1 1e3", "bad timestamp"},
      {"zz v=1 5\t", "bad timestamp"},
      {"zz v=1 5\r", "bad timestamp"},
      {"zz v=1 99999999999999999999",
       ~S|strconv.ParseInt: parsing "99999999999999999999": value out of range|},
      {"zz v=1 9223372036854775807",
       "time outside range -9223372036854775806 - 9223372036854775806"},
      {"zz v=1 5 #x", "point is invalid"},
      {"zz v=1 100 200", "point is invalid"},
      # numbers outside what their type holds
      {"zz v=-9223372036854775809i",
       "unable to parse integer -9223372036854775809: " <>
         ~S|strconv.ParseInt: parsing "-9223372036854775809": value out of range|}
    ]
  end

  # `{payload, [{quoted, reason}]}`: every line that fails, in order.
  defp v2_payloads do
    [
      # a quote in a measurement, a tag key or a field key means nothing
      {~s|m"a f=1i 1\nBAD|, [{"BAD", "missing fields"}]},
      {~s|m,k"x=1 f=1i 1\nBAD|, [{"BAD", "missing fields"}]},
      {~s|m f"x=1i 1\nBAD|, [{"BAD", "missing fields"}]},
      # a quote after a field value is part of the number's line
      {~s|m f=1"i 1\nBAD|, [{~s|m f=1"i 1\nBAD|, "invalid number"}]},
      # a backslash takes the newline with it
      {"BAD1\\\nBAD2\nBAD3", [{"BAD1\\\nBAD2", "missing fields"}, {"BAD3", "missing fields"}]},
      # the line is quoted without its leading whitespace
      {" \t zz v=", [{"zz v=", "missing field value"}]}
    ]
  end

  defp v2_stored do
    [
      {"~m v=5.", [{"v", 5.0}]},
      {"~m v=.5", [{"v", 0.5}]},
      {"~m v=-.5", [{"v", -0.5}]},
      {"~m v=1.e1", [{"v", 10.0}]},
      {"~m v=5.e1", [{"v", 50.0}]},
      {~S|~m v="x"|, [{"v", "x"}]},
      {~S|~m v="a\"b"|, [{"v", ~s|a"b|}]},
      {~S|~m a\ b=1|, [{"a b", 1.0}]},
      {~s|~m "k"=1|, [{~s|"k"|, 1.0}]},
      {"~m v=T,w=false", [{"v", true}, {"w", false}]},
      {"~m v=1", [{"v", 1.0}]},
      {"~m v=1 5", [{"v", 1.0}]},
      {"~m v=1  5", [{"v", 1.0}]},
      {"~m v=1 5 ", [{"v", 1.0}]},
      {"~m v=1 5   ", [{"v", 1.0}]},
      {"\t ~m v=1", [{"v", 1.0}]},
      # a comment is skipped through the whole line a quote leaves open
      {~s|# a=1 "x\n~m v=1 5|, []}
    ]
  end

  defp v2_error_tests(client) do
    quote location: :keep do
      describe "line protocol grammar — InfluxDB 2 errors, in the Go parser's words" do
        test "a line that does not parse is a 400 that quotes it and says why", ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            unquote(Macro.escape(v2_errors())),
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
            unquote(Macro.escape(v2_payloads())),
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
            unquote(Macro.escape(v2_stored())),
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

          escapes = [
            {~S|\,x|, "a,x"},
            {~S|\ x|, "a x"},
            {~S|\=x|, "a=x"},
            {~S|\"x|, ~S|a\"x|},
            {~S|\\x|, ~S|a\\x|},
            {~S|\\,x|, ~S|a\,x|},
            {~S|\\ x|, ~S|a\ x|},
            {~S|\\=x|, ~S|a\=x|},
            {~S|\\\,x|, ~S|a\\,x|},
            {~S|\\\\x|, ~S|a\\\\x|},
            {~S|\x|, ~S|a\x|}
          ]

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
end
