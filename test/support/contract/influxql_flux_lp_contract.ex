defmodule InfluxElixir.Contract.InfluxQLFluxLP do
  @moduledoc """
  Contract tests for the line protocol grammar of both engines, InfluxQL's
  `WHERE` and time, Flux's `range` and InfluxDB 2's bucket listing, run
  against `InfluxElixir.Client.Local` and against the real engines: the
  answers the double must give exactly as they do (rows, error status and
  body). Every expectation was read from InfluxDB 3 Core or InfluxDB 2.7.

      use InfluxElixir.Contract.InfluxQLFluxLP,
        client: InfluxElixir.Client.Local,
        profile: :v3_core

  `profile: :v3_core` adds the InfluxDB 3 tests (line protocol, InfluxQL),
  `profile: :v2` the InfluxDB 2 ones (line protocol, Flux, buckets).

  The `setup` callback must return `conn` and `database`, as
  for the shared contract. A real server is shared between runs, so every
  measurement name is unique and every line is given a timestamp.

  ## Parts

  A module that generates the whole contract is slow to compile, so `part: part`
  generates one slice of the `:v3_core` tests, for a module of its own that
  compiles and runs in parallel with its siblings: `:line_protocol`,
  `:influxql_basics`, `:influxql_typed` or `:influxql_time`. Without `:part`
  everything is generated, as it always is for `:v2`.
  """

  @parts [:line_protocol, :influxql_basics, :influxql_typed, :influxql_time]

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)
    part = Keyword.get(opts, :part, :all)

    unless part == :all or part in @parts do
      raise ArgumentError,
            "unknown :part #{inspect(part)}, expected :all or one of #{inspect(@parts)}"
    end

    blocks =
      for {block_part, block} <- profile_blocks(client, profile),
          part == :all or block_part in [:always, part],
          do: block

    quote location: :keep do
      (unquote_splicing(blocks))
    end
  end

  # The blocks of a profile, in order, each with the part it belongs to. `:always`
  # blocks hold helpers and are generated in every part: they are public functions,
  # so a part that does not call one of them does not warn about it.
  @spec profile_blocks(Macro.t(), atom()) :: [{atom(), Macro.t()}]
  defp profile_blocks(client, :v3_core) do
    [
      {:always, helpers(client)},
      {:always, v3_influxql_helpers(client)},
      {:always, v3_influxql_reserved_helpers(client)},
      {:always, v3_influxql_planner_helpers(client)},
      {:line_protocol, v3_line_protocol_tests(client)},
      {:line_protocol, v3_line_protocol_name_tests(client)},
      {:influxql_basics, v3_influxql_tests(client)},
      {:influxql_basics, v3_influxql_group_tests(client)},
      {:influxql_basics, v3_influxql_parse_tests(client)},
      {:influxql_basics, v3_influxql_reserved_where_tests(client)},
      {:influxql_basics, v3_influxql_reserved_select_tests(client)},
      {:influxql_basics, v3_influxql_clause_tests(client)},
      {:influxql_typed, v3_influxql_typed_tests(client)},
      {:influxql_typed, v3_influxql_typed_edge_tests(client)},
      {:influxql_typed, v3_influxql_unsigned_tests(client)},
      {:influxql_typed, v3_influxql_names_tests(client)},
      {:influxql_typed, v3_influxql_not_tests(client)},
      {:influxql_time, v3_influxql_quoted_time_tests(client)},
      {:influxql_time, v3_influxql_bare_time_tests(client)},
      {:influxql_time, v3_influxql_group_time_tests(client)},
      {:influxql_time, v3_influxql_constant_tests(client)},
      {:influxql_time, v3_influxql_operator_tests(client)},
      {:influxql_time, v3_influxql_paren_tests(client)},
      {:influxql_time, v3_influxql_show_tests(client)},
      {:influxql_time, v3_influxql_tag_tests(client)},
      {:influxql_time, v3_influxql_literal_syntax_tests(client)}
    ]
  end

  # The InfluxDB 2 tests are few and form one part: `:all`, the default.
  defp profile_blocks(client, :v2) do
    [
      {:v2, helpers(client)},
      {:v2, v2_line_protocol_helpers(client)},
      {:v2, v2_line_protocol_tests(client)},
      {:v2, v2_retention_tests(client)},
      {:v2, v2_flux_helpers(client)},
      {:v2, v2_flux_range_tests(client)},
      {:v2, v2_flux_data_tests(client)},
      {:v2, v2_flux_name_tests(client)},
      {:v2, v2_flux_type_tests(client)},
      {:v2, v2_bucket_tests(client)}
    ]
  end

  defp profile_blocks(_client, _other), do: []

  defp helpers(client) do
    quote location: :keep do
      def ifl_write(ctx, lines) do
        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, Enum.join(lines, "\n"), database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)
      end

      def ifl_us(microseconds), do: DateTime.from_unix!(microseconds, :microsecond)
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxDB 3 line protocol
  # ---------------------------------------------------------------------------

  defp v3_line_protocol_tests(client) do
    quote location: :keep do
      # `~m` is the measurement. After the first field that parses, what
      # does not is trailing content: from the comma when it is the
      # third field or later, after it for the second.
      @ifl_v3_errors [
        {"~m v=1 100 200", "Could not parse entire line. Found trailing content: `200`"},
        {"~m v=.5 1", "No fields were provided"},
        {"~m v=5. 2", "Could not parse entire line. Found trailing content: `. 2`"},
        {"~m v=1e 5", "Could not parse entire line. Found trailing content: `e 5`"},
        {"~m v=tRUE 5", "Could not parse entire line. Found trailing content: `RUE 5`"},
        {"~m v=+5 5", "No fields were provided"},
        {"~m v=1 5 6", "Could not parse entire line. Found trailing content: `6`"},
        {"~m v=1 abcdefghijklmnop",
         "Could not parse entire line. Found trailing content: ` abcdefghi...`"},
        {"~m v=1,w= 5", "Could not parse entire line. Found trailing content: `w= 5`"},
        {"~m v=1,w=2,x=3,y= 5", "Could not parse entire line. Found trailing content: `,y= 5`"},
        {"~m v=1,v=2 5", "invalid line protocol - multiple instances of 'v' field found"},
        {"~m,t v=1 5", "Tag set malformed: could not find equals sign in `t v=1 5`"},
        {"~m,t= v=1 5", "Expected tag value, got ` v=1 5`"},
        {"~m,=a v=1 5", "Expected tag key, got `=a v=1 5`"},
        {"~m\tv=1 5", "Expected at least one space character, got `\tv=1 5`"},
        {"~m v=1\t5", "Could not parse entire line. Found trailing content: `\t5`"}
      ]

      def ifl_partial_errors(body) do
        assert %{"error" => "partial write of line protocol occurred", "data" => data} =
                 Jason.decode!(body)

        for %{"error_message" => message, "line_number" => number} <- data,
            do: {number, message}
      end

      describe "line protocol grammar — InfluxDB 3 contract" do
        test "a line that does not parse is the engine's 400, in the engine's words", ctx do
          for {template, message} <- @ifl_v3_errors do
            line =
              String.replace(template, "~m", InfluxElixir.IntegrationHelper.unique_name("ifl_lp"))

            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, line, database: ctx.database)

            assert [{1, ^message}] = ifl_partial_errors(body), line
          end
        end

        test "what the engine's grammar lets through is stored as the columns it names", ctx do
          for {template, columns} <- [
                # a trailing comma, a comma in a field key, a tag key that
                # starts with one or holds one, an `=` inside a tag value
                {"~m v=1, 1000", %{"v" => 1.0}},
                {"~m a,b=1 1000", %{"a,b" => 1.0}},
                {"~m,,t=1 v=1 1000", %{",t" => "1", "v" => 1.0}},
                {"~m,t,u=1 v=1 1000", %{"t,u" => "1", "v" => 1.0}},
                {"~m,t=a=b v=1 1000", %{"t" => "a=b", "v" => 1.0}},
                {"~m v=1.5e3 1000", %{"v" => 1500.0}}
              ] do
            m = InfluxElixir.IntegrationHelper.unique_name("ifl_ok")
            ifl_write(ctx, [String.replace(template, "~m", m)])

            assert {:ok, [row]} =
                     unquote(client).query_influxql(ctx.conn, "SELECT * FROM #{m}",
                       database: ctx.database
                     )

            assert row["time"] === ifl_us(1), template
            assert Map.drop(row, ["time", "iox::measurement"]) === columns, template
          end
        end

        test "good lines around a bad one are written, the bad one is numbered", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_mix")

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(
                     ctx.conn,
                     "#{m} v=1 1000\n#{m} v=1 5 6\n#{m} v=3 3000",
                     database: ctx.database
                   )

          assert [{2, "Could not parse entire line. Found trailing content: `6`"}] =
                   ifl_partial_errors(body)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, rows} =
                   unquote(client).query_influxql(ctx.conn, "SELECT v FROM #{m}",
                     database: ctx.database
                   )

          assert Enum.map(rows, & &1["v"]) === [1.0, 3.0]
        end

        test "a quote in a tag value does not join the next line to it", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_quote")

          ifl_write(ctx, [~s|#{m},t=a"b f=1i 1000|, "#{m} f=2i 2000"])

          assert {:ok, rows} =
                   unquote(client).query_influxql(ctx.conn, "SELECT f, t FROM #{m}",
                     database: ctx.database
                   )

          assert Enum.map(rows, &{&1["time"], &1["f"], &1["t"]}) === [
                   {ifl_us(1), 1, ~s|a"b|},
                   {ifl_us(2), 2, nil}
                 ]
        end

        test "a quote after a field value opens a string that swallows the newline", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_swallow")

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, ~s|#{m} f=1"i 1\nBAD|, database: ctx.database)

          assert [{1, "Could not parse entire line. Found trailing content: `\"i 1\nBAD`"}] =
                   ifl_partial_errors(body)
        end

        test "an error is numbered among the lines that count and echoes the physical line",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_number")

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, "#c\n\n#{m} v=1 5 6", database: ctx.database)

          assert %{"data" => [entry]} = Jason.decode!(body)

          assert entry === %{
                   "error_message" => "Could not parse entire line. Found trailing content: `6`",
                   "line_number" => 1,
                   "original_line" => "#c"
                 }
        end
      end
    end
  end

  defp v3_line_protocol_name_tests(client) do
    quote location: :keep do
      # A name that ends in a backslash, wherever it ends; `~m` is the measurement.
      @ifl_v3_backslash [
        ~S"~m\\ v=1i 5",
        ~S"~m\\",
        ~S"~m,t\\ v=1i 5",
        ~S"~m,t\\",
        ~S"~m,t=a\\",
        ~S"~m,t=a\\ ",
        ~S"~m,t=a\\ v=1i 5",
        ~S"~m,t\\=1 v=1i",
        ~S"~m,t=\\ v=1i",
        ~S"~m v\\ =1i 5",
        ~S"~m v\\",
        ~S"~m v=1i,w\\ x=1i",
        ~S"~m v=1i,w\\=1i",
        ~S"~m v\\=1i 5"
      ]

      describe "line protocol names — InfluxDB 3 contract" do
        test "a name that ends in a backslash is refused wherever it ends", ctx do
          message =
            "Measurements, tag keys and values, and field keys may not end with a backslash"

          for template <- @ifl_v3_backslash do
            line =
              String.replace(template, "~m", InfluxElixir.IntegrationHelper.unique_name("ifl_bs"))

            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, line, database: ctx.database)

            assert [{1, ^message}] = ifl_partial_errors(body), line
          end
        end

        test "an escaped separator is part of the name", ctx do
          for {template, name, columns} <- [
                {~S"~m,t\,u=1 v=1i 1000", "~m", %{"t,u" => "1", "v" => 1}},
                {~S"~m\ z v=1i 1000", "~m z", %{"v" => 1}},
                {~S"~m\,z v=1i 1000", "~m,z", %{"v" => 1}}
              ] do
            m = InfluxElixir.IntegrationHelper.unique_name("ifl_sep")
            ifl_write(ctx, [String.replace(template, "~m", m)])

            measurement = String.replace(name, "~m", m)

            assert {:ok, [row]} =
                     unquote(client).query_influxql(
                       ctx.conn,
                       ~s|SELECT * FROM "#{measurement}"|,
                       database: ctx.database
                     )

            assert row["iox::measurement"] === measurement
            assert Map.drop(row, ["time", "iox::measurement"]) === columns, template
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxQL
  # ---------------------------------------------------------------------------

  defp v3_influxql_helpers(client) do
    quote location: :keep do
      def ifl_iq(ctx, statement) do
        unquote(client).query_influxql(ctx.conn, statement, database: ctx.database)
      end

      def ifl_iq_values(ctx, statement, column \\ "v") do
        assert {:ok, rows} = ifl_iq(ctx, statement)
        Enum.map(rows, & &1[column])
      end
    end
  end

  defp v3_influxql_tests(_client) do
    quote location: :keep do
      @ifl_time_not_equal "rewriting statement\ncaused by\nsplit condition\ncaused by\n" <>
                            "Error during planning: invalid time comparison operator: !="

      describe "InfluxQL WHERE, time and LIMIT — contract" do
        # Times are whole microseconds, which a query result carries.
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_iq")

          ifl_write(ctx, [
            "#{m},k=a v=1,w=10 1000",
            "#{m},k=b v=2,w=20 2000",
            "#{m},k=a v=3,w=30 3000",
            "#{m},k=into v=4,w=40 4000",
            "#{m},k=c x=7i 5000"
          ])

          {:ok, m: m}
        end

        test "a keyword inside a quoted string is a string, not a keyword", ctx do
          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE k = 'into'") === [4.0]
          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE k = 'fill('") === []
          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE k = 'group by x'") === []
          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE k =~ /into/") === [4.0]
          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE k =~ /fill\\(/") === []
        end

        test "next to time, an integer or a duration is nanoseconds since the epoch", ctx do
          for {where, expected} <- [
                {"time > 0s", [1.0, 2.0, 3.0, 4.0]},
                {"time >= 2000", [2.0, 3.0, 4.0]},
                {"2000 <= time", [2.0, 3.0, 4.0]},
                {"time > 2000ns", [3.0, 4.0]},
                {"time = 2000", [2.0]},
                {"time > 1u", [2.0, 3.0, 4.0]},
                {"time > -1", [1.0, 2.0, 3.0, 4.0]},
                {"time > 1s", []},
                {"time < 1s", [1.0, 2.0, 3.0, 4.0]},
                {"time >= 2000 AND time < 4000", [2.0, 3.0]},
                {"time > 1000 + 1000", [3.0, 4.0]},
                {"time > 1s - 999999000ns", [2.0, 3.0, 4.0]},
                {"k != 'a' AND time >= 2000", [2.0, 4.0]}
              ] do
            assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE #{where}") === expected,
                   where
          end
        end

        test "time != and time <> are a planning error, whatever the comparand", ctx do
          for where <- [
                "time != 2000",
                "time <> 2000",
                "time <> 2s",
                "2000 != time",
                "time != '2026-01-01'",
                "time != now()"
              ] do
            assert {:error, %{status: 400, body: @ifl_time_not_equal}} =
                     ifl_iq(ctx, "SELECT v FROM #{ctx.m} WHERE #{where}"),
                   where
          end
        end

        test "an aggregate is stamped with the lower bound of time, else the epoch", ctx do
          for {where, mean, time} <- [
                {"", 2.5, ifl_us(0)},
                {"WHERE time >= 2000", 3.0, ifl_us(2)},
                {"WHERE time > 2000", 3.5, ifl_us(2)},
                {"WHERE time = 2000", 2.0, ifl_us(2)},
                {"WHERE time >= 2000 AND time <= 3000", 2.5, ifl_us(2)},
                {"WHERE time > 2000 AND time >= 3000", 3.5, ifl_us(3)},
                {"WHERE time < 3000", 1.5, ifl_us(0)},
                {"WHERE time <= 3000", 2.0, ifl_us(0)},
                {"WHERE (time >= 2000) AND k != 'b'", 3.5, ifl_us(2)}
              ] do
            assert {:ok, [%{"mean" => ^mean, "time" => ^time}]} =
                     ifl_iq(ctx, "SELECT mean(v) FROM #{ctx.m} #{where}"),
                   where
          end

          two = ifl_us(2)

          assert {:ok, rows} =
                   ifl_iq(ctx, "SELECT mean(v) FROM #{ctx.m} WHERE time >= 2000 GROUP BY k")

          assert Enum.map(rows, &{&1["k"], &1["mean"], &1["time"]}) === [
                   {"a", 3.0, two},
                   {"b", 2.0, two},
                   {"into", 4.0, two}
                 ]
        end

        test "LIMIT and OFFSET count per selected field, not per row", ctx do
          assert {:ok, rows} = ifl_iq(ctx, "SELECT v, x FROM #{ctx.m} LIMIT 2")

          assert Enum.map(rows, &{&1["time"], &1["v"], &1["x"]}) === [
                   {ifl_us(1), 1.0, nil},
                   {ifl_us(2), 2.0, nil},
                   {ifl_us(5), nil, 7}
                 ]

          assert {:ok, rows} = ifl_iq(ctx, "SELECT * FROM #{ctx.m} LIMIT 1")

          assert Enum.map(rows, &{&1["time"], &1["k"], &1["v"], &1["w"], &1["x"]}) === [
                   {ifl_us(1), "a", 1.0, 10.0, nil},
                   {ifl_us(5), "c", nil, nil, 7}
                 ]

          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} LIMIT 1 OFFSET 1") === [2.0]
        end
      end
    end
  end

  defp v3_influxql_group_tests(_client) do
    quote location: :keep do
      describe "InfluxQL GROUP BY order — contract" do
        test "series are ordered by tag key whatever GROUP BY's order, a missing tag last",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_grp")

          ifl_write(ctx, [
            "#{m},h=a,r=2 v=1 1000",
            "#{m},h=b,r=1 v=2 2000",
            "#{m},h=a,r=1 v=3 3000",
            "#{m},h=c v=4 4000",
            "#{m},r=0 v=5 5000"
          ])

          expected = [
            {"a", "1", 3.0},
            {"a", "2", 1.0},
            {"b", "1", 2.0},
            {"c", nil, 4.0},
            {nil, "0", 5.0}
          ]

          for select <- ["mean(v)", "v"], by <- ["h, r", "r, h"] do
            assert {:ok, rows} = ifl_iq(ctx, "SELECT #{select} FROM #{m} GROUP BY #{by}")

            assert Enum.map(rows, &{&1["h"], &1["r"], &1["mean"] || &1["v"]}) === expected,
                   "SELECT #{select} GROUP BY #{by}"
          end
        end
      end
    end
  end

  defp v3_influxql_parse_tests(_client) do
    quote location: :keep do
      describe "InfluxQL parse errors — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_pe")
          ifl_write(ctx, ["#{m},k=a v=1 1000", "#{m},k=--1 v=2 2000"])
          {:ok, m: m, prefix: "SELECT v FROM #{m} WHERE "}
        end

        @ifl_parse "error in InfluxQL statement: parsing error: "

        test "an operand that is missing or cannot start is an invalid conditional expression",
             %{prefix: prefix} = ctx do
          # `--` starts a comment, so `v > --1` has no operand. The position
          # is the end of the operator that wants one.
          for {where, at} <- [
                {"v > --1", 3},
                {"v >--1", 3},
                {"v>--1", 2},
                {"v > .", 3},
                {"v > -.", 3},
                {"v >.", 3},
                {"v >", 3},
                {"v > ) ", 3},
                {"v > AND k = 1", 3},
                {"v > 1 AND", 9},
                {"v > 1 AND v > --1", 13},
                {"v > 1 AND v > .", 13}
              ] do
            expected =
              @ifl_parse <> "invalid conditional expression at pos #{byte_size(prefix) + at}"

            assert {:error, %{status: 400, body: ^expected}} = ifl_iq(ctx, prefix <> where),
                   where
          end

          expected = @ifl_parse <> "invalid conditional, expected regular expression at pos "

          assert {:error, %{status: 400, body: body}} = ifl_iq(ctx, prefix <> "v =~ ")
          assert body === expected <> "#{byte_size(prefix) + 4}"
        end

        test "a comment ends at its line; a quoted -- is text", %{prefix: prefix} = ctx do
          for {where, expected} <- [
                {"v > 1 -- trailing", [2.0]},
                {"v > 1 -- c\n AND v < 5", [2.0]},
                {"v > 0 --c LIMIT 1", [1.0, 2.0]},
                {"v > 1;", [2.0]},
                {"v > 1; ; -- c", [2.0]},
                {"k = '--1' OR v > 5", [2.0]}
              ] do
            assert {:ok, rows} = ifl_iq(ctx, prefix <> where), where
            assert Enum.map(rows, & &1["v"]) === expected, where
          end
        end

        test "an integer beyond 64 bits is an overflow at the end of its digits",
             %{prefix: prefix} = ctx do
          for {literal, text} <- [
                {"99999999999999999999999", "unable to parse integer due to overflow"},
                {"18446744073709551616", "unable to parse integer due to overflow"},
                {"-99999999999999999999999", "unable to parse integer due to overflow"},
                {"1 + 99999999999999999999999", "unable to parse integer due to overflow"},
                {"99999999999999999999999s", "unable to parse integer due to overflow"},
                {"-9223372036854775809", "constant overflows signed integer"}
              ] do
            where = "v > " <> literal
            # a duration's unit is not part of the number it overflows
            unit = if String.ends_with?(where, "s"), do: 1, else: 0
            pos = byte_size(prefix) + byte_size(where) - unit
            expected = @ifl_parse <> text <> " at pos #{pos}"

            assert {:error, %{status: 400, body: ^expected}} = ifl_iq(ctx, prefix <> where),
                   where
          end

          assert {:error, %{status: 400, body: body}} =
                   ifl_iq(ctx, prefix <> "v > 9223372036854775808s")

          pos = byte_size(prefix) + byte_size("v > 9223372036854775808")

          assert body ===
                   @ifl_parse <>
                     "invalid InfluxQL statement at pos #{pos}. Parsing Error: Nom(\"s\", Tag)"
        end

        test "the largest 64-bit integers and a float of any size are numbers",
             %{prefix: prefix} = ctx do
          for {literal, expected} <- [
                {"18446744073709551615", []},
                {"-9223372036854775808", [1.0, 2.0]},
                {"99999999999999999999999.5", []},
                {"-99999999999999999999999.5", [1.0, 2.0]}
              ] do
            assert {:ok, rows} = ifl_iq(ctx, prefix <> "v > " <> literal), literal
            assert Enum.map(rows, & &1["v"]) === expected, literal
          end
        end

        test "after a ;, another statement is the engine's error and nothing else is read",
             %{prefix: prefix, m: m} = ctx do
          # The position is where the second statement starts, and the rest
          # of the text is shown from there.
          for {tail, next} <- [
                {"v > 1; SELECT 2", "SELECT 2"},
                {"v = 'a'; DROP", "DROP"},
                {"v > 1 ; SELECT 2", "SELECT 2"},
                {"v > 1;SELECT 2", "SELECT 2"},
                {"v > 1;   SELECT 2", "SELECT 2"},
                {"v > 1;; DROP", "DROP"},
                {"v > 1; ; DROP", "DROP"},
                {"v > 1 GROUP BY k; SELECT 2", "SELECT 2"},
                {"v > 1 LIMIT 1; DROP", "DROP"},
                {"v > 1; x", "x"}
              ] do
            statement = prefix <> tail
            pos = byte_size(statement) - byte_size(next)

            expected =
              @ifl_parse <>
                "invalid InfluxQL statement at pos #{pos}. Parsing Error: Nom(#{inspect(next)}, Tag)"

            assert {:error, %{status: 400, body: ^expected}} = ifl_iq(ctx, statement), tail
          end

          one = "must provide only one InfluxQl statement per query"

          for tail <- ["v > 1; SELECT v FROM #{m}", "v > 1; SHOW DATABASES"] do
            assert {:error, %{status: 400, body: ^one}} = ifl_iq(ctx, prefix <> tail), tail
          end

          # The second statement is read, and its own error is positioned in the text.
          statement = prefix <> "v > 1; SELECT v FROM #{m} WHERE v >"
          expected = @ifl_parse <> "invalid conditional expression at pos #{byte_size(statement)}"
          assert {:error, %{status: 400, body: ^expected}} = ifl_iq(ctx, statement)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxDB 3 InfluxQL: reserved words, clauses, typed comparisons
  # ---------------------------------------------------------------------------

  defp v3_influxql_reserved_helpers(_client) do
    quote location: :keep do
      def ifl_rw_setup(ctx) do
        m = InfluxElixir.IntegrationHelper.unique_name("ifl_rw")

        ifl_write(ctx, [
          ~s|#{m},tag=a,host=h1 v=1i,f=1.5,b=true,u=5u,s="x" 1000|,
          "#{m},tag=b v=-4i,f=2.5,b=false,u=0u 2000",
          "#{m},host=h2 v=7i,f=3.5,b=true,u=9u 3000"
        ])

        {:ok, m: m, sel: "SELECT v FROM #{m}"}
      end

      @ifl_parse "error in InfluxQL statement: parsing error: "
      @ifl_words ~w(tag key name values measurement field series all default limit in inf
                      group from select as by on to user write)

      def ifl_nom(statement, pos) do
        leftover = binary_part(statement, pos, byte_size(statement) - pos)

        @ifl_parse <>
          "invalid InfluxQL statement at pos #{pos}. Parsing Error: Nom(#{inspect(leftover)}, Tag)"
      end

      def ifl_failure(statement, word_at) do
        leftover = binary_part(statement, word_at, byte_size(statement) - word_at)

        @ifl_parse <>
          "invalid InfluxQL statement at pos 0. Parsing Failure: Nom(#{inspect(leftover)}, Char)"
      end

      # the position just after the first `text` at or after `from`
      def ifl_after(statement, text, from \\ 0) do
        rest = binary_part(statement, from, byte_size(statement) - from)
        {at, size} = :binary.match(rest, text)
        from + at + size
      end

      def ifl_err(ctx, statement, body) do
        assert {:error, %{status: 400, body: ^body}} = ifl_iq(ctx, statement), statement
      end
    end
  end

  defp v3_influxql_reserved_where_tests(_client) do
    quote location: :keep do
      describe "InfluxQL reserved words in WHERE — contract" do
        setup ctx do
          ifl_rw_setup(ctx)
        end

        test "a reserved word as a bare name leaves the WHERE unparsed, in any case",
             %{sel: sel} = ctx do
          where_at = byte_size(sel) + 1

          for word <- @ifl_words, word <- [word, String.upcase(word)] do
            statement = "#{sel} WHERE #{word} = 'a'"
            ifl_err(ctx, statement, ifl_nom(statement, where_at))
          end

          for word <- ["fill", "now", "not", "null", "nan"] do
            assert {:ok, []} = ifl_iq(ctx, "#{sel} WHERE #{word} = 1"), word
          end

          assert ifl_iq_values(ctx, "#{sel} WHERE \"tag\" = 'a'") === [1]
        end

        test "a reserved word where an operand belongs is the missing operand",
             %{sel: sel} = ctx do
          operand = @ifl_parse <> "invalid conditional expression at pos "

          for {where, end_of} <- [
                {"v = 1 AND tag = 2", "AND"},
                {"v = 1 OR tag = 2", "OR"},
                {"v = tag", "v ="},
                {"1 = tag", "1 ="},
                {"v = -tag", "v ="},
                {"v = +tag", "v ="},
                {"v = ( tag )", "v ="},
                {"(v = 1) AND tag = 1", "AND"},
                {"(v = 1 AND tag = 2)", "AND"},
                {"v = 1 AND (tag = 'a')", "AND"},
                {"v = 1 AND where = 2", "AND"},
                {"v = 1 OR and = 2", "OR"}
              ] do
            statement = "#{sel} WHERE #{where}"
            ifl_err(ctx, statement, operand <> "#{ifl_after(statement, end_of, byte_size(sel))}")
          end
        end

        test "after an operand, a reserved word is what cannot be read", %{sel: sel} = ctx do
          for {where, word} <- [{"v tag = 1", "tag"}, {"v = 1 tag", "tag"}, {"v in (1)", "in"}] do
            statement = "#{sel} WHERE #{where}"
            {at, _size} = :binary.match(statement, word)
            ifl_err(ctx, statement, ifl_nom(statement, at))
          end

          # after `*` or `/` it is the operator
          for op <- ["*", "/"] do
            statement = "#{sel} WHERE v = 1 #{op} tag"
            {at, _size} = :binary.match(statement, op)
            ifl_err(ctx, statement, ifl_nom(statement, at))
          end

          # after a binary `+` or `-` the engine fails from the word, at position 0
          for where <- ["v + tag = 1", "v = 1 + tag", "v = 1 - tag", "v = (1 + tag)"] do
            statement = "#{sel} WHERE #{where}; SELECT 2"
            {at, _size} = :binary.match(statement, "tag")
            ifl_err(ctx, statement, ifl_failure(statement, at))
          end
        end

        test "a WHERE with nothing in it, or a reserved word first, is unparsed",
             %{sel: sel} = ctx do
          where_at = byte_size(sel) + 1

          for tail <- [
                "WHERE",
                "WHERE where",
                "WHERE tag",
                "WHERE tag(v) = 1",
                "WHERE (tag = 'a')",
                "WHERE tag + v = 1",
                "WHERE tag = 1 GROUP BY host",
                "WHERE tag = 'a'; SELECT 2"
              ] do
            statement = "#{sel} #{tail}"
            ifl_err(ctx, statement, ifl_nom(statement, where_at))
          end

          # the text counts as sent, blanks included
          statement = "  #{sel} WHERE tag = 1  "
          ifl_err(ctx, statement, ifl_nom(statement, byte_size(sel) + 3))
        end
      end
    end
  end

  defp v3_influxql_reserved_select_tests(_client) do
    quote location: :keep do
      describe "InfluxQL reserved words in the select list and GROUP BY — contract" do
        setup ctx do
          ifl_rw_setup(ctx)
        end

        test "the select list, FROM and aliases name reserved words", %{m: m} = ctx do
          field = @ifl_parse <> "invalid SELECT statement, expected field at pos "

          for {statement, pos} <- [
                {"SELECT tag FROM #{m}", 7},
                {"SELECT  key FROM #{m}", 8},
                {"SELECT NAME FROM #{m}", 7},
                {"SELECT FROM #{m}", 7},
                {"SELECT", 6}
              ] do
            ifl_err(ctx, statement, field <> "#{pos}")
          end

          # a later item that is reserved leaves the whole statement unparsed
          for statement <- ["SELECT v, tag FROM #{m}", "SELECT v,  key FROM #{m}", "SELECT v"] do
            ifl_err(ctx, statement, ifl_nom(statement, 0))
          end

          ifl_err(ctx, "SELECT sum(tag) FROM #{m}", ifl_failure("SELECT sum(tag) FROM #{m}", 11))

          ifl_err(
            ctx,
            "SELECT v, mean(tag) FROM #{m}",
            ifl_failure("SELECT v, mean(tag) FROM #{m}", 15)
          )

          alias_error = @ifl_parse <> "invalid field alias, expected identifier at pos "

          for {statement, pos} <- [
                {"SELECT v AS tag FROM #{m}", 11},
                {"SELECT v AS  key FROM #{m}", 11},
                {"SELECT mean(v) AS tag FROM #{m}", 17},
                {"SELECT v, v AS tag FROM #{m}", 14}
              ] do
            ifl_err(ctx, statement, alias_error <> "#{pos}")
          end

          from_error =
            @ifl_parse <>
              "invalid FROM clause, expected identifier, regular expression or subquery at pos "

          for {statement, pos} <- [
                {"SELECT v FROM", 13},
                {"SELECT v FROM tag", 14},
                {"SELECT v FROM 1", 14},
                {"SELECT v FROM ,x", 14},
                {"SELECT v FROM  WHERE", 15}
              ] do
            ifl_err(ctx, statement, from_error <> "#{pos}")
          end

          distinct = @ifl_parse <> "invalid DISTINCT expression, expected identifier at pos "
          ifl_err(ctx, "SELECT DISTINCT FROM #{m}", distinct <> "16")
          ifl_err(ctx, "SELECT v, DISTINCT FROM #{m}", distinct <> "19")

          assert ifl_iq_values(ctx, "SELECT v AS \"tag\" FROM #{m}", "tag") === [1, -4, 7]
        end

        test "GROUP BY names a reserved word", %{sel: sel} = ctx do
          group =
            @ifl_parse <>
              "invalid GROUP BY clause, expected wildcard, TIME, identifier or regular " <>
              "expression at pos "

          for {tail, pos} <- [
                {"GROUP BY tag", 9},
                {"GROUP BY  key", 10},
                {"GROUP BY TAG, host", 9},
                {"WHERE v = 1 GROUP BY tag", 21}
              ] do
            ifl_err(ctx, "#{sel} #{tail}", group <> "#{byte_size(sel) + 1 + pos}")
          end

          for tail <- ["GROUP BY host, tag", "GROUP BY host,tag", "GROUP BY host,  key; SELECT"] do
            statement = "#{sel} #{tail}"
            {comma, _size} = :binary.match(statement, ",")
            ifl_err(ctx, statement, ifl_nom(statement, comma))
          end

          statement = "#{sel} WHERE tag = 1 GROUP BY tag"
          ifl_err(ctx, statement, ifl_nom(statement, byte_size(sel) + 1))
        end
      end
    end
  end

  defp v3_influxql_clause_tests(_client) do
    quote location: :keep do
      describe "InfluxQL clauses and statements after a ; — contract" do
        setup ctx do
          ifl_rw_setup(ctx)
        end

        test "a clause the WHERE runs into is read for its own error", %{sel: sel} = ctx do
          order_time = @ifl_parse <> "invalid ORDER BY, expected TIME column at pos "
          order = @ifl_parse <> "invalid ORDER BY, expected ASC, DESC or TIME at pos "

          for {tail, prefix, marker} <- [
                {"WHERE v = 1 ORDER BY tag", order, "ORDER BY"},
                {"WHERE v = 1 ORDER BY tag LIMIT 1", order, "ORDER BY"},
                {"GROUP BY host ORDER BY tag", order, "ORDER BY"},
                {"WHERE v = 1 ORDER BY 1", order, "ORDER BY"},
                {"WHERE v = 1 ORDER BY v", order_time, "ORDER BY "},
                {"GROUP BY host ORDER BY v", order_time, "ORDER BY "}
              ] do
            statement = "#{sel} #{tail}"
            ifl_err(ctx, statement, prefix <> "#{ifl_after(statement, marker)}")
          end

          limit = @ifl_parse <> "invalid LIMIT clause, expected unsigned integer at pos "
          offset = @ifl_parse <> "invalid OFFSET clause, expected unsigned integer at pos "

          for {tail, prefix, argument} <- [
                {"WHERE v = 1 LIMIT x", limit, "x"},
                {"WHERE v = 1 LIMIT -1", limit, "-1"},
                {"WHERE v = 1 OFFSET x", offset, "x"}
              ] do
            statement = "#{sel} #{tail}"
            ifl_err(ctx, statement, prefix <> "#{byte_size(statement) - byte_size(argument)}")
          end

          statement = "#{sel} WHERE v = 1 GROUP x"

          ifl_err(
            ctx,
            statement,
            @ifl_parse <>
              "invalid GROUP BY clause, expected BY at pos #{byte_size(statement) - 1}"
          )

          assert ifl_iq_values(ctx, "#{sel} ORDER BY DESC") === [7, -4, 1]
          assert ifl_iq_values(ctx, "#{sel} WHERE v > 0 ORDER BY ASC") === [1, 7]
          assert ifl_iq_values(ctx, "#{sel} ORDER BY TIME DESC") === [7, -4, 1]
        end

        test "after a ;, the next statement is parsed on its own, positioned in the text",
             %{m: m} = ctx do
          first = "SELECT v FROM #{m}"

          for {next, kind} <- [
                {"SELECT", {:field, 6}},
                {"SELECT v FROM", {:from, 13}},
                {"SELECT tag FROM #{m}", {:field, 7}},
                {"SELECT v AS tag FROM #{m}", {:alias, 11}},
                {"SELECT v FROM tag", {:from, 14}},
                {"SELECT v FROM #{m} WHERE", {:nom, "WHERE"}},
                {"SELECT v FROM #{m} WHERE tag = 1", {:nom, "WHERE tag = 1"}},
                {"SELECT 2", {:nom, "SELECT 2"}},
                {"x", {:nom, "x"}},
                {"DROP", {:nom, "DROP"}}
              ],
              glue <- ["; ", ";", " ;  "] do
            statement = first <> glue <> next
            start = byte_size(first <> glue)
            ifl_err(ctx, statement, ifl_second(kind, start, statement))
          end

          assert {:error,
                  %{status: 400, body: "must provide only one InfluxQl statement per query"}} =
                   ifl_iq(ctx, first <> "; " <> first <> " LIMIT 9223372036854775808")
        end

        defp ifl_second({:field, offset}, start, _statement),
          do: @ifl_parse <> "invalid SELECT statement, expected field at pos #{start + offset}"

        defp ifl_second({:from, offset}, start, _statement) do
          @ifl_parse <>
            "invalid FROM clause, expected identifier, regular expression or subquery at pos " <>
            "#{start + offset}"
        end

        defp ifl_second({:alias, offset}, start, _statement),
          do: @ifl_parse <> "invalid field alias, expected identifier at pos #{start + offset}"

        defp ifl_second({:nom, text}, start, statement) do
          {at, _size} =
            :binary.match(binary_part(statement, start, byte_size(statement) - start), text)

          ifl_nom(statement, start + at)
        end

        test "LIMIT and OFFSET past the signed range are a planning error",
             %{sel: sel, m: m} = ctx do
          assert ifl_iq_values(ctx, "#{sel} LIMIT 9223372036854775807") === [1, -4, 7]
          assert ifl_iq_values(ctx, "#{sel} OFFSET 9223372036854775807") === []
          assert ifl_iq_values(ctx, "#{sel} LIMIT 0") === []

          for {tail, which} <- [
                {"LIMIT 9223372036854775808", "limit"},
                {"LIMIT 18446744073709551615", "limit"},
                {"OFFSET 9223372036854775808", "offset"},
                {"OFFSET 18446744073709551615", "offset"},
                {"LIMIT 9223372036854775808 OFFSET 9223372036854775808", "limit"},
                {"LIMIT 1 OFFSET 9223372036854775808", "offset"},
                {"WHERE nope = 1 LIMIT 9223372036854775808", "limit"},
                {"GROUP BY host LIMIT 9223372036854775808", "limit"}
              ] do
            assert {:error, %{status: 400, body: body}} = ifl_iq(ctx, "#{sel} #{tail}"), tail
            assert body === "Error during planning: #{which} out of range", tail
          end

          assert {:error, %{status: 400, body: "Error during planning: limit out of range"}} =
                   ifl_iq(ctx, "SELECT mean(v) FROM #{m} LIMIT 9223372036854775808")

          # an unsigned past 64 bits is a parse error at the end of its digits
          for {tail, digits} <- [
                {"LIMIT 18446744073709551616", "18446744073709551616"},
                {"OFFSET 18446744073709551616", "18446744073709551616"},
                {"LIMIT 99999999999999999999999", "99999999999999999999999"},
                {"LIMIT 99999999999999999999 OFFSET 9223372036854775808", "99999999999999999999"},
                {"LIMIT 1 OFFSET 99999999999999999999", "99999999999999999999"}
              ] do
            statement = "#{sel} #{tail}"

            expected =
              @ifl_parse <>
                "unable to parse unsigned integer at pos #{ifl_after(statement, digits)}"

            ifl_err(ctx, statement, expected)
          end

          # a measurement that does not exist is no planning error
          assert {:ok, []} = ifl_iq(ctx, "SELECT v FROM #{m}_none LIMIT 9223372036854775808")

          # a bare field's type is checked after LIMIT; a comparison's before it
          assert {:error, %{status: 400, body: "Error during planning: limit out of range"}} =
                   ifl_iq(ctx, "#{sel} WHERE v LIMIT 9223372036854775808")

          assert {:error, %{status: 400, body: body}} =
                   ifl_iq(ctx, "#{sel} WHERE b = 9223372036854775808 LIMIT 9223372036854775808")

          assert body ===
                   "Error during planning: Cannot infer common argument type for comparison " <>
                     "operation Boolean = UInt64"
        end
      end
    end
  end

  defp v3_influxql_typed_tests(_client) do
    quote location: :keep do
      describe "InfluxQL typed comparisons — contract" do
        setup ctx do
          ifl_rw_setup(ctx)
        end

        test "a field is compared with a literal by the two types", %{sel: sel} = ctx do
          # a literal of another kind is false for every row, whatever the operator
          for where <- [
                "b = 1",
                "b != 1",
                "b > 1",
                "b = -1",
                "b = 1.5",
                "b = 'x'",
                "v = true",
                "v != true",
                "v > true",
                "v = 'x'",
                "v != 'x'",
                "f = true",
                "f = 'x'",
                "s = 1",
                "s != 1",
                "s = true",
                "1 = b",
                "true = v",
                "b > false",
                "b < true",
                "b >= true",
                "b <= false",
                "s > 'x'",
                "s >= 'x'",
                "s < 'x'"
              ] do
            assert ifl_iq_values(ctx, "#{sel} WHERE #{where}") === [], where
          end

          assert ifl_iq_values(ctx, "#{sel} WHERE b = true") === [1, 7]
          assert ifl_iq_values(ctx, "#{sel} WHERE b = FALSE") === [-4]
          assert ifl_iq_values(ctx, "#{sel} WHERE b") === [1, 7]
          assert ifl_iq_values(ctx, "#{sel} WHERE s = 'x'") === [1]

          # a negative integer against an unsigned field wraps to 2^64 + n
          for {where, expected} <- [
                {"u > -1", []},
                {"u >= -1", []},
                {"u = -1", []},
                {"u < -1", [1, -4, 7]},
                {"u <= -1", [1, -4, 7]},
                {"u != -1", [1, -4, 7]},
                {"u > -2", []},
                {"-1 < u", []},
                {"-4 > u", [1, -4, 7]},
                {"u > (-1)", []},
                {"u > 1 - 2", []},
                {"u > -1.5", [1, -4, 7]},
                {"u < -1.5", []},
                {"u = -0", [-4]},
                {"u > 0", [1, 7]},
                {"u > 1.5", [1, 7]}
              ] do
            assert ifl_iq_values(ctx, "#{sel} WHERE #{where}") === expected, where
          end

          # an integer past the signed range is unsigned: an integer field wraps
          for {where, expected} <- [
                {"v > 9223372036854775807", []},
                {"v > 9223372036854775808", [-4]},
                {"v >= 9223372036854775808", [-4]},
                {"v < 9223372036854775808", [1, 7]},
                {"v <= 9223372036854775808", [1, 7]},
                {"v = 9223372036854775808", []},
                {"v != 9223372036854775808", [1, -4, 7]},
                {"9223372036854775808 < v", [-4]},
                {"9223372036854775808 > v", [1, 7]},
                {"v > 18446744073709551615", []},
                {"v < 18446744073709551615", [1, -4, 7]},
                {"v = 18446744073709551611", [-4]},
                {"v > 18446744073709551610", [-4]},
                {"v > 18446744073709551611", []},
                {"f > 9223372036854775808", []},
                {"f < 9223372036854775808", [1, -4, 7]},
                {"u > 9223372036854775808", []},
                {"u < 9223372036854775808", [1, -4, 7]}
              ] do
            assert ifl_iq_values(ctx, "#{sel} WHERE #{where}") === expected, where
          end

          # a boolean against an unsigned is the planning error, in the written order
          cannot =
            "Error during planning: Cannot infer common argument type for comparison operation "

          for {where, types} <- [
                {"b = 9223372036854775808", "Boolean = UInt64"},
                {"b > 9223372036854775808", "Boolean > UInt64"},
                {"b <> 9223372036854775808", "Boolean != UInt64"},
                {"b <= 18446744073709551615", "Boolean <= UInt64"},
                {"9223372036854775808 = b", "UInt64 = Boolean"},
                {"u = true", "UInt64 = Boolean"},
                {"u != false", "UInt64 != Boolean"},
                {"true < u", "Boolean < UInt64"}
              ] do
            assert {:error, %{status: 400, body: body}} = ifl_iq(ctx, "#{sel} WHERE #{where}"),
                   where

            assert body === cannot <> types, where
          end
        end
      end
    end
  end

  defp v3_influxql_typed_edge_tests(_client) do
    quote location: :keep do
      describe "InfluxQL typed comparisons at the edges — contract" do
        setup ctx do
          ifl_rw_setup(ctx)
        end

        test "the wrap of a negative integer is 2^64 + n - 1, and the lowest integer is null",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_rw_edge")

          ifl_write(ctx, [
            "#{m} v=-1i,u=18446744073709551615u 1000",
            "#{m} v=-9223372036854775808i,u=18446744073709551614u 2000",
            "#{m} v=-9223372036854775807i,u=18446744073709551613u 3000",
            "#{m} v=0i,u=9223372036854775808u 4000"
          ])

          low = -9_223_372_036_854_775_808

          # an integer field against an unsigned literal
          for {where, expected} <- [
                {"v = 9223372036854775808", [low + 1]},
                {"v = 18446744073709551614", [-1]},
                {"v = 18446744073709551615", []},
                {"v > 18446744073709551613", [-1]},
                {"v > 18446744073709551614", []},
                {"v >= 18446744073709551614", [-1]},
                {"v < 9223372036854775808", [0]},
                {"v <= 9223372036854775808", [low + 1, 0]},
                {"v != 9223372036854775808", [-1, 0]},
                {"v <= 18446744073709551615", [-1, low + 1, 0]}
              ] do
            assert ifl_iq_values(ctx, "SELECT v FROM #{m} WHERE #{where}") === expected, where
          end

          # an unsigned field against a negative literal
          for {where, expected} <- [
                {"u = -1", [low]},
                {"u = -2", [low + 1]},
                {"u = -3", []},
                {"u > -1", [-1]},
                {"u > -2", [-1, low]},
                {"u < -2", [0]},
                {"u = -9223372036854775807", [0]},
                {"u > -9223372036854775807", [-1, low, low + 1]}
              ] do
            assert ifl_iq_values(ctx, "SELECT v FROM #{m} WHERE #{where}") === expected, where
          end
        end

        test "a bare field as the whole condition is a planning error naming its type",
             %{sel: sel} = ctx do
          for {field, type} <- [
                {"v", "Int64"},
                {"f", "Float64"},
                {"u", "UInt64"},
                {"s", "Utf8"},
                {"host", "Dictionary(Int32, Utf8)"},
                {"(f)", "Float64"}
              ] do
            assert {:error, %{status: 400, body: body}} = ifl_iq(ctx, "#{sel} WHERE #{field}"),
                   field

            assert body ===
                     "type_coercion\ncaused by\nError during planning: Cannot infer common " <>
                       "argument type for logical boolean operation Boolean AND #{type}",
                   field
          end

          assert ifl_iq_values(ctx, "#{sel} WHERE nothere") === []
          assert ifl_iq_values(ctx, "#{sel} WHERE true") === [1, -4, 7]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxQL as the planner reads it: arithmetic, names, times, constants
  # ---------------------------------------------------------------------------

  defp v3_influxql_planner_helpers(_client) do
    quote location: :keep do
      @ifl_split "rewriting statement\ncaused by\nsplit condition\ncaused by\n"
      @ifl_gather "rewriting statement\ncaused by\ngather information about select statement\n" <>
                    "caused by\nError during planning: "

      def ifl_ids(ctx, statement), do: ifl_iq_values(ctx, statement, "i")

      # the rows of an answer without the measurement every row carries
      def ifl_rows(ctx, statement) do
        assert {:ok, rows} = ifl_iq(ctx, statement), statement
        Enum.map(rows, &Map.delete(&1, "iox::measurement"))
      end

      def ifl_after_downcased(statement, text, from),
        do: ifl_after(String.downcase(statement), text, from)

      def ifl_plan_err(ctx, statement, status, body) do
        assert {:error, %{status: ^status, body: ^body}} = ifl_iq(ctx, statement), statement
      end
    end
  end

  defp v3_influxql_unsigned_tests(_client) do
    quote location: :keep do
      describe "InfluxQL unsigned arithmetic — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_un")

          ifl_write(ctx, [
            "#{m} i=1i,j=5i,u=3u 1000",
            "#{m} i=2i,j=-5i,u=18446744073709551615u 2000",
            "#{m} i=3i,u=0u 3000",
            "#{m} i=4i,j=-9223372036854775808i,u=9223372036854775808u 4000",
            "#{m},t=x i=5i,j=-1i,u=18446744073709551614u 5000"
          ])

          {:ok, m: m}
        end

        # An unsigned field makes the arithmetic around it unsigned: both
        # sides are cast, a negative one as 2^64 + n - 1, and `+ - *` wrap.
        # `-x` is `x * -1`, not a negation.
        test "an unsigned field in arithmetic wraps; a negative constant next to it is 2^64 + n - 1",
             %{m: m} = ctx do
          for {where, expected} <- [
                {"u * -1 < 0", []},
                {"-u < 0", []},
                {"u * -1 > 0", [1, 2, 5]},
                {"u * -1 = 2", [2]},
                {"u * -1 = 0", [3, 4]},
                {"-(u) > 0", [1, 2, 5]},
                {"u * 2 > 4", [1, 2, 5]},
                {"u + 1 = 0", [2]},
                {"u + 1 > 1", [1, 4, 5]},
                {"u - 1 > 0", [1, 2, 3, 4, 5]},
                {"0 - u < 1", [3]},
                {"u - -1 = 4", []},
                {"u + -1 = 1", [1]},
                {"u * u = 9", [1]},
                {"(u + 1) * 2 = 8", [1]},
                {"u / 2 > 1", [2, 4, 5]},
                {"u / 0 > 1", []},
                {"u + 1.5 > 4", [1, 2, 4, 5]}
              ] do
            assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE #{where}") === expected, where
          end
        end

        test "an integer field and an unsigned field compare as unsigned", %{m: m} = ctx do
          for {where, expected} <- [
                {"j > u", [1]},
                {"j < u", [2]},
                {"j = u", [5]},
                {"j >= u", [1, 5]},
                {"u > j", [2]},
                {"u = j", [5]},
                {"u + j > 0", [1, 2, 5]},
                {"j * 9223372036854775807 > 0", [1]}
              ] do
            assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE #{where}") === expected, where
          end

          assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE j > u AND i > 0") === [1]
          assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE (u * -1 = 2) AND t = 'x'") === []
        end

        test "SUM wraps at the range of its field's type", %{m: m} = ctx do
          assert {:ok, [%{"sum" => 9_223_372_036_854_775_808, "time" => time}]} =
                   ifl_iq(ctx, "SELECT sum(u) FROM #{m}")

          assert time === ifl_us(0)
        end

        test "SUM, MEAN and overflow", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_un")

          ifl_write(ctx, [
            "#{m} i=9223372036854775807i,u=18446744073709551615u,f=1.5 1000",
            "#{m} i=9223372036854775807i,u=18446744073709551615u,f=2.5 2000",
            "#{m} i=5i,u=2u,f=1e308 3000",
            "#{m} f=1e308 4000"
          ])

          assert ifl_rows(ctx, "SELECT sum(i), sum(u), sum(f), mean(f) FROM #{m}") === [
                   %{"time" => ifl_us(0), "sum" => 3, "sum_1" => 0, "sum_2" => nil, "mean" => nil}
                 ]

          assert ifl_rows(ctx, "SELECT mean(i), mean(u) FROM #{m}") === [
                   %{
                     "time" => ifl_us(0),
                     "mean" => 6_148_914_691_236_517_000.0,
                     "mean_1" => 12_297_829_382_473_034_000.0
                   }
                 ]

          assert ifl_rows(ctx, "SELECT sum(i), sum(u), sum(f) FROM #{m} WHERE time < 3000") === [
                   %{
                     "time" => ifl_us(0),
                     "sum" => -2,
                     "sum_1" => 18_446_744_073_709_551_614,
                     "sum_2" => 4.0
                   }
                 ]

          assert ifl_rows(ctx, "SELECT sum(f), mean(f) FROM #{m} WHERE time <= 3000") === [
                   %{
                     "time" => ifl_us(0),
                     "sum" => 1.0e308,
                     "mean" => String.to_float("3.333333333333333e307")
                   }
                 ]
        end
      end
    end
  end

  defp v3_influxql_names_tests(_client) do
    quote location: :keep do
      describe "InfluxQL names and the time column — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_nm")
          ifl_write(ctx, ["#{m},k=a i=1i,j=5i 1000", "#{m},k=b i=2i,j=-5i 2000"])
          {:ok, m: m}
        end

        test "a name taken twice is numbered, skipping the names taken", %{m: m} = ctx do
          [one, two] = [ifl_us(1), ifl_us(2)]

          assert ifl_rows(ctx, "SELECT i, i, i FROM #{m}") === [
                   %{"time" => one, "i" => 1, "i_1" => 1, "i_2" => 1},
                   %{"time" => two, "i" => 2, "i_1" => 2, "i_2" => 2}
                 ]

          assert ifl_rows(ctx, "SELECT i AS j, j FROM #{m}") === [
                   %{"time" => one, "j" => 1, "j_1" => 5},
                   %{"time" => two, "j" => 2, "j_1" => -5}
                 ]

          assert ifl_rows(ctx, "SELECT i AS k, k FROM #{m}") === [
                   %{"time" => one, "k" => 1, "k_1" => "a"},
                   %{"time" => two, "k" => 2, "k_1" => "b"}
                 ]

          assert ifl_rows(ctx, "SELECT i AS i_1, i, i FROM #{m} LIMIT 1") === [
                   %{"time" => one, "i_1" => 1, "i" => 1, "i_2" => 1}
                 ]
        end

        test "an item named time is time_1 beside the time column that leads the answer",
             %{m: m} = ctx do
          [one, two] = [ifl_us(1), ifl_us(2)]

          assert ifl_rows(ctx, "SELECT i AS time FROM #{m}") === [
                   %{"time" => one, "time_1" => 1},
                   %{"time" => two, "time_1" => 2}
                 ]

          assert ifl_rows(ctx, "SELECT mean(i) AS time FROM #{m}") === [
                   %{"time" => ifl_us(0), "time_1" => 1.5}
                 ]

          assert ifl_rows(ctx, "SELECT count(i) AS time FROM #{m}") === [
                   %{"time" => ifl_us(0), "time_1" => 2}
                 ]

          assert ifl_rows(ctx, "SELECT max(i) AS time FROM #{m}") === [
                   %{"time" => two, "time_1" => 2}
                 ]

          assert ifl_rows(ctx, "SELECT i AS TIME FROM #{m} LIMIT 1") === [
                   %{"time" => one, "TIME" => 1}
                 ]

          assert ifl_rows(ctx, "SELECT count(*) AS time FROM #{m}") === [
                   %{"time" => ifl_us(0), "time_i" => 2, "time_j" => 2}
                 ]
        end

        test "a selected time column is the leading one, and its alias names it", %{m: m} = ctx do
          [one, two] = [ifl_us(1), ifl_us(2)]

          for select <- ["time, i", "i, time", "TIME, i", "time AS time, i", "\"time\", i"] do
            assert ifl_rows(ctx, "SELECT #{select} FROM #{m}") === [
                     %{"time" => one, "i" => 1},
                     %{"time" => two, "i" => 2}
                   ],
                   select
          end

          for select <- ["time AS x, i", "i, time AS x"] do
            assert ifl_rows(ctx, "SELECT #{select} FROM #{m}") === [
                     %{"x" => one, "i" => 1},
                     %{"x" => two, "i" => 2}
                   ],
                   select
          end

          assert ifl_rows(ctx, "SELECT i AS time, time FROM #{m}") === [
                   %{"time_1" => one, "time" => 1},
                   %{"time_1" => two, "time" => 2}
                 ]

          assert ifl_rows(ctx, "SELECT time, i AS time FROM #{m}") === [
                   %{"time" => one, "time_1" => 1},
                   %{"time" => two, "time_1" => 2}
                 ]

          assert ifl_rows(ctx, "SELECT time, i, time FROM #{m}") === [
                   %{"time" => one, "i" => 1, "time_1" => one},
                   %{"time" => two, "i" => 2, "time_1" => two}
                 ]
        end

        test "time is no field: a list of nothing else is an empty answer", %{m: m} = ctx do
          for select <- ["time", "time, time", "\"time\"", "TIME AS x"] do
            assert ifl_rows(ctx, "SELECT #{select} FROM #{m}") === [], select
          end

          assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE TIME > 1000") === [2]
          assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE \"time\" > 1000") === [2]
          assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE Time >= 2000") === [2]
        end
      end
    end
  end

  defp v3_influxql_not_tests(_client) do
    quote location: :keep do
      describe "InfluxQL NOT is a name — contract" do
        setup ctx do
          field = InfluxElixir.IntegrationHelper.unique_name("ifl_nf")
          tag = InfluxElixir.IntegrationHelper.unique_name("ifl_nt")
          ifl_write(ctx, ["#{field} not=7i,i=1i 1000", "#{field} not=8i,i=2i 2000"])
          ifl_write(ctx, ["#{tag},not=a i=1i 1000", "#{tag},not=b i=2i 2000"])
          {:ok, field: field, tag: tag}
        end

        test "it is read as any other name", %{field: field, tag: tag} = ctx do
          for {where, expected} <- [
                {"not = 7", [1]},
                {"not > 7", [2]},
                {"7 = not", [1]},
                {"\"not\" = 7", [1]},
                {"NOT = 7", []},
                {"NOT", []}
              ] do
            assert ifl_ids(ctx, "SELECT i FROM #{field} WHERE #{where}") === expected, where
          end

          assert ifl_ids(ctx, "SELECT i FROM #{tag} WHERE not = 'a'") === [1]
          assert ifl_ids(ctx, "SELECT i FROM #{tag} WHERE i > 0 AND not = 'b'") === [2]
          assert ifl_ids(ctx, "SELECT i FROM #{tag} WHERE NOT") === []

          assert ifl_rows(ctx, "SELECT not FROM #{field}") === [
                   %{"time" => ifl_us(1), "not" => 7},
                   %{"time" => ifl_us(2), "not" => 8}
                 ]

          assert ifl_rows(ctx, "SELECT i FROM #{tag} GROUP BY not") === [
                   %{"time" => ifl_us(1), "not" => "a", "i" => 1},
                   %{"time" => ifl_us(2), "not" => "b", "i" => 2}
                 ]
        end

        test "alone it is a bare field, as any other", %{field: field, tag: tag} = ctx do
          for {measurement, type} <- [{field, "Int64"}, {tag, "Dictionary(Int32, Utf8)"}],
              where <- ["not", "(not)"] do
            ifl_plan_err(
              ctx,
              "SELECT i FROM #{measurement} WHERE #{where}",
              400,
              "type_coercion\ncaused by\nError during planning: Cannot infer common " <>
                "argument type for logical boolean operation Boolean AND #{type}"
            )
          end
        end

        test "another operand right after it is left over", %{field: field} = ctx do
          for {where, left} <- [{"not k", "k"}, {"not 1", "1"}, {"not not", "not"}] do
            statement = "SELECT i FROM #{field} WHERE #{where}"
            ifl_err(ctx, statement, ifl_nom(statement, byte_size(statement) - byte_size(left)))
          end
        end
      end
    end
  end

  defp v3_influxql_quoted_time_tests(_client) do
    quote location: :keep do
      describe "InfluxQL quoted times — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_qt")
          ifl_write(ctx, ["#{m} i=1i 1000", "#{m} i=2i 2000"])
          {:ok, m: m, sel: "SELECT i FROM #{m}"}
        end

        test "a time the planner cannot read is not a valid timestamp", %{sel: sel} = ctx do
          for content <- [
                "a",
                "abc",
                "",
                " ",
                "now",
                "now()",
                "1970",
                "1970-01",
                "1970-01-01T00:00:00",
                "1970-01-01T00:00:00.000002",
                "1970-01-01T00:00",
                "1970-01-01 00:00",
                "1970-01-01T25:00:00Z",
                "1970-01-01T24:00:00Z",
                "1970-01-01T00:60:00Z",
                "2020-13-45",
                "2020-02-30",
                "1970-02-29",
                "1970-00-01",
                "1970-01-00",
                "1000000000",
                "10000-01-01",
                "1970-01-01T00:00:00Z "
              ] do
            body =
              @ifl_split <>
                "Error during planning: invalid expression \"'#{content}'\": " <>
                "'#{content}' is not a valid timestamp"

            for where <- [
                  "time = '#{content}'",
                  "time > '#{content}'",
                  "'#{content}' < time",
                  "\"time\" = '#{content}'",
                  "time = '#{content}' AND i > 1",
                  "i > 1 AND time = '#{content}'",
                  "time = '#{content}' OR i > 1"
                ] do
              ifl_plan_err(ctx, "#{sel} WHERE #{where}", 400, body)
            end
          end
        end

        test "a time in a form it reads that does not fit 64-bit nanoseconds is out of range",
             %{sel: sel} = ctx do
          for {content, shown} <- [
                {"2262-04-12", "2262-04-12 00:00:00 +00:00"},
                {"1677-09-20", "1677-09-20 00:00:00 +00:00"},
                {"0000-01-01", "0000-01-01 00:00:00 +00:00"},
                {"9999-12-31", "9999-12-31 00:00:00 +00:00"},
                {"2262-04-11T23:47:16.854775808Z", "2262-04-11 23:47:16.854775808 +00:00"},
                {"1677-09-21T00:12:43.145224191Z", "1677-09-21 00:12:43.145224191 +00:00"}
              ] do
            ifl_plan_err(
              ctx,
              "#{sel} WHERE time >= '#{content}'",
              400,
              @ifl_split <> "Error during planning: timestamp out of range: " <> shown
            )
          end
        end

        test "the forms it reads are answered", %{sel: sel} = ctx do
          for {content, expected} <- [
                {"1970-01-01", [1, 2]},
                {"1970-01-01T00:00:00Z", [1, 2]},
                {"1970-01-01t00:00:00z", [1, 2]},
                {"1970-01-01 00:00:00", [1, 2]},
                {"1970-01-01 00:00:00Z", [1, 2]},
                {"1970-01-01T00:00:00+00:00", [1, 2]},
                {"1970-01-01T00:00:00.000002Z", [2]},
                {"1970-01-01 00:00:00.000002", [2]},
                {"1970-01-01T00:00:00.123456789012Z", []},
                {"1970-01-01T00:00:60Z", []},
                {"1972-02-29", []},
                {"2262-04-11T23:47:16.854775807Z", []},
                {"1677-09-21T00:12:44Z", [1, 2]},
                {"2262-04-12T00:00:00+01:00", []}
              ] do
            assert ifl_ids(ctx, "#{sel} WHERE time >= '#{content}'") === expected, content
          end
        end

        test "the time is read before the select list is planned", %{m: m} = ctx do
          ifl_plan_err(
            ctx,
            "SELECT mean(true) FROM #{m} WHERE time >= 'a'",
            400,
            @ifl_split <>
              "Error during planning: invalid expression \"'a'\": 'a' is not a valid timestamp"
          )
        end
      end
    end
  end

  defp v3_influxql_bare_time_tests(_client) do
    quote location: :keep do
      describe "InfluxQL time as a condition — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_bt")
          ifl_write(ctx, ["#{m} i=1i 1000", "#{m} i=2i 2000"])
          {:ok, sel: "SELECT i FROM #{m}"}
        end

        test "alone it breaks the planner's stack", %{sel: sel} = ctx do
          for where <- ["time", "\"time\"", "TIME"] do
            ifl_plan_err(
              ctx,
              "#{sel} WHERE #{where}",
              500,
              @ifl_split <>
                "External error: InfluxQL internal error: expected an element on stack"
            )
          end

          for where <- [
                "time AND i > 1",
                "i > 1 AND time",
                "time OR i > 1",
                "i > 1 OR time",
                "time AND time",
                "time > 0 AND time",
                "time AND time > 0",
                "(time AND i > 1)",
                "i > 1 AND (time OR i < 3)",
                "time < 1s AND (i > 1 OR time)",
                "time > now() - 1d AND (time)",
                "i > 1 AND time AND i < 4"
              ] do
            ifl_plan_err(
              ctx,
              "#{sel} WHERE #{where}",
              500,
              @ifl_split <> "External error: InfluxQL internal error: invalid expr stack"
            )
          end
        end

        test "in parentheses it is a timestamp where a boolean is wanted", %{sel: sel} = ctx do
          for where <- ["(time)", "((time))"] do
            ifl_plan_err(
              ctx,
              "#{sel} WHERE #{where}",
              400,
              "type_coercion\ncaused by\nError during planning: Cannot infer common " <>
                "argument type for logical boolean operation Boolean AND Timestamp(ns)"
            )
          end

          for {where, types} <- [
                {"(time) AND i > 1", "Timestamp(ns) AND Boolean"},
                {"i > 1 AND (time)", "Boolean AND Timestamp(ns)"},
                {"(time) OR (i > 1)", "Timestamp(ns) OR Boolean"}
              ] do
            ifl_plan_err(
              ctx,
              "#{sel} WHERE #{where}",
              400,
              "Error during planning: Cannot infer common argument type for logical " <>
                "boolean operation " <> types
            )
          end
        end
      end
    end
  end

  defp v3_influxql_group_time_tests(_client) do
    quote location: :keep do
      describe "InfluxQL GROUP BY time — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_gt")
          ifl_write(ctx, ["#{m},k=a i=1i 1000", "#{m},k=b i=2i 2000"])
          {:ok, m: m}
        end

        test "time without a call is an invalid TIME call, at the end of the word",
             %{m: m} = ctx do
          for tail <- [
                "GROUP BY time",
                "GROUP BY TIME",
                "GROUP BY  time",
                "GROUP BY time, k",
                "GROUP BY time ,k",
                "GROUP BY k, time",
                "GROUP BY k,time,t",
                "GROUP BY time ORDER BY time DESC",
                "GROUP BY time LIMIT 1",
                "WHERE i > 1 GROUP BY time"
              ] do
            statement = "SELECT i FROM #{m} #{tail}"
            at = ifl_after_downcased(statement, "time", ifl_after(statement, "GROUP BY"))

            ifl_err(
              ctx,
              statement,
              @ifl_parse <> "invalid TIME call, expected 1 or 2 arguments at pos #{at}"
            )
          end

          statement = "SELECT mean(i) FROM #{m} GROUP BY time"

          ifl_err(
            ctx,
            statement,
            @ifl_parse <>
              "invalid TIME call, expected 1 or 2 arguments at pos #{byte_size(statement)}"
          )
        end
      end
    end
  end

  defp v3_influxql_constant_tests(_client) do
    quote location: :keep do
      describe "InfluxQL constants in the select list — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_cl")
          ifl_write(ctx, ["#{m} i=1i,j=5i 1000", "#{m} i=2i,j=-5i 2000"])
          {:ok, m: m}
        end

        test "a constant item has no variable in it", %{m: m} = ctx do
          for select <- [
                "true",
                "false",
                "TRUE",
                "1",
                "1.5",
                ".5",
                "'a'",
                "''",
                "'a b'",
                "-1",
                "+1",
                "-1.5",
                "5s",
                "1, 2",
                "i, 1",
                "i, 'a'",
                "i, true",
                "mean(i), true",
                "true, i",
                "true AS x",
                "i, 1 AS x",
                "i AS x, true",
                "*, true",
                "true, *",
                "true, mean(true)"
              ] do
            for statement <- [
                  "SELECT #{select} FROM #{m}",
                  "SELECT #{select} FROM nothere_#{m}",
                  "SELECT #{select} FROM #{m} WHERE i > 100",
                  "SELECT #{select} FROM #{m} GROUP BY k LIMIT 1",
                  "SELECT #{select} FROM #{m} LIMIT 9223372036854775808"
                ] do
              ifl_plan_err(
                ctx,
                statement,
                400,
                @ifl_gather <> "field must contain at least one variable"
              )
            end
          end

          assert ifl_rows(ctx, "SELECT \"true\" FROM #{m}") === []
        end

        test "a function of a constant expects a field, and names the constant", %{m: m} = ctx do
          for {call, name, debug} <- [
                {"mean(true)", "mean", "Boolean(true)"},
                {"mean(FALSE)", "mean", "Boolean(false)"},
                {"mean(1)", "mean", "Integer(1)"},
                {"mean(-1)", "mean", "Integer(-1)"},
                {"mean(1.5)", "mean", "Float(1.5)"},
                {"mean('a')", "mean", "String(\"a\")"},
                {"mean('a b')", "mean", "String(\"a b\")"},
                {"mean('')", "mean", "String(\"\")"},
                {"mean('a\"b')", "mean", "String(\"a\\\"b\")"},
                {"mean(5s)", "mean", "Duration(Duration(5000000000))"},
                {"sum(true)", "sum", "Boolean(true)"},
                {"count(true)", "count", "Boolean(true)"},
                {"count(1.5)", "count", "Float(1.5)"},
                {"max(1)", "max", "Integer(1)"},
                {"min(TRUE)", "min", "Boolean(true)"},
                {"first(true)", "first", "Boolean(true)"},
                {"last('x')", "last", "String(\"x\")"},
                {"mean(1) AS x", "mean", "Integer(1)"},
                {"mean(1), i", "mean", "Integer(1)"},
                {"i, mean(true)", "mean", "Boolean(true)"},
                {"mean(true), true", "mean", "Boolean(true)"}
              ] do
            for statement <- [
                  "SELECT #{call} FROM #{m}",
                  "SELECT #{call} FROM nothere_#{m}"
                ] do
              ifl_plan_err(
                ctx,
                statement,
                400,
                @ifl_gather <> "expected field argument in #{name}(), got Literal(#{debug})"
              )
            end
          end
        end
      end
    end
  end

  defp v3_influxql_operator_tests(_client) do
    quote location: :keep do
      describe "InfluxQL a reserved word after an operator — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_ro")
          ifl_write(ctx, ["#{m} i=1i,j=5i 1000"])
          {:ok, m: m}
        end

        # after `+` or `-` the engine fails from the operand on, at position 0
        test "after a binary + or - the parser fails from the operand", %{m: m} = ctx do
          for {select, marker} <- [
                {"i + as FROM #{m}", "as FROM"},
                {"i - as FROM #{m}", "as FROM"},
                {"i + AS FROM #{m}", "AS FROM"},
                {"i +as FROM #{m}", "as FROM"},
                {"i + from FROM #{m}", "from FROM"},
                {"i + where FROM #{m}", "where FROM"},
                {"i + select FROM #{m}", "select FROM"},
                {"i + group FROM #{m}", "group FROM"},
                {"i + FROM #{m}", "FROM #{m}"},
                {"i, j + as FROM #{m}", "as FROM"},
                {"i + (as) FROM #{m}", "(as) FROM"},
                {"i + sum(as) FROM #{m}", "as) FROM"},
                {"sum(i) + as FROM #{m}", "as FROM"},
                {"i + -as FROM #{m}", "-as FROM"},
                {"i + 1 + as FROM #{m}", "as FROM"},
                {"i + as", "as"},
                {"i + from", "from"}
              ] do
            statement = "SELECT " <> select
            {at, _size} = :binary.match(statement, marker)
            ifl_err(ctx, statement, ifl_failure(statement, at))
          end
        end

        test "after another operator the statement is left unparsed", %{m: m} = ctx do
          for operator <- ["*", "/", "%", "&"], word <- ["as", "from"] do
            statement = "SELECT i #{operator} #{word} FROM #{m}"
            ifl_err(ctx, statement, ifl_nom(statement, 0))
          end
        end

        test "a sign before a reserved word first in the list is an expected field",
             %{m: m} = ctx do
          for word <- ["as", "from"] do
            ifl_err(
              ctx,
              "SELECT -#{word} FROM #{m}",
              @ifl_parse <> "invalid SELECT statement, expected field at pos 7"
            )
          end
        end

        test "in a statement after a ; the position is the statement's", %{m: m} = ctx do
          first = "SELECT i FROM #{m}; "
          second = "SELECT i + as FROM #{m}"
          statement = first <> second
          {at, _size} = :binary.match(statement, "as FROM")
          leftover = binary_part(statement, at, byte_size(statement) - at)

          ifl_err(
            ctx,
            statement,
            @ifl_parse <>
              "invalid InfluxQL statement at pos #{byte_size(first)}. " <>
              "Parsing Failure: Nom(#{inspect(leftover)}, Char)"
          )
        end
      end
    end
  end

  defp v3_influxql_paren_tests(_client) do
    quote location: :keep do
      describe "InfluxQL parentheses of a WHERE — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_pa")
          ifl_write(ctx, ["#{m},k=a i=1i 1000", "#{m},k=b i=2i 2000"])
          {:ok, m: m, prefix: "SELECT i FROM #{m} "}
        end

        test "a parenthesis left open, or with nothing in it, leaves the WHERE unparsed",
             %{prefix: prefix} = ctx do
          for where <- [
                "(",
                "()",
                "(  )",
                "(i",
                "(i > 1",
                "((i > 1)",
                "((((i > 1",
                "(i + 1 > 1",
                "((i > 1) AND i < 3",
                "(i > 1 LIMIT 1",
                "(i > 1 GROUP BY k"
              ] do
            statement = prefix <> "WHERE " <> where
            ifl_err(ctx, statement, ifl_nom(statement, byte_size(prefix)))
          end
        end

        test "a parenthesis that closes nothing is left over from itself",
             %{prefix: prefix} = ctx do
          for {where, at} <- [
                {"i > 1)", 5},
                {"(i > 1))", 7},
                {"i > 1 AND i < 3)", 15},
                {"i + 1) > 1", 5},
                {"i > 1 ) AND i < 3", 6},
                {"(i > 1)) AND (", 7},
                {"(i > 1) ) (", 8},
                {"(i > 1) (", 8},
                {"i)", 1}
              ] do
            statement = prefix <> "WHERE " <> where
            ifl_err(ctx, statement, ifl_nom(statement, byte_size(prefix) + 6 + at))
          end
        end

        test "after an operator or a connective the operand is missing",
             %{prefix: prefix} = ctx do
          for {where, at} <- [
                {"i > (", 3},
                {"i > (i", 3},
                {"i > (1 + 2", 3},
                {"i > 1 AND (", 9},
                {"i > 1 AND (i > 1", 9},
                {"(i > 1) AND (i > 1", 11},
                {"(i > 1 OR (i < 3", 9}
              ] do
            expected =
              @ifl_parse <>
                "invalid conditional expression at pos #{byte_size(prefix) + 6 + at}"

            ifl_err(ctx, prefix <> "WHERE " <> where, expected)
          end
        end

        test "after a binary + the parser fails from the parenthesis", %{prefix: prefix} = ctx do
          statement = prefix <> "WHERE i + (1 > 1"
          {at, _size} = :binary.match(statement, "(1 > 1")
          ifl_err(ctx, statement, ifl_failure(statement, at))
        end

        test "in a statement after a ; the position is the statement's", %{m: m} = ctx do
          first = "SELECT i FROM #{m}; "
          statement = first <> "SELECT i FROM #{m} WHERE ("
          {at, _size} = :binary.match(statement, "WHERE (")
          ifl_err(ctx, statement, ifl_nom(statement, at))
        end

        test "a GROUP BY dimension cannot start with a parenthesis", %{prefix: prefix} = ctx do
          for tail <- ["GROUP BY (", "WHERE i > 1 GROUP BY ("] do
            statement = prefix <> tail
            {at, _size} = :binary.match(statement, "(")

            ifl_err(
              ctx,
              statement,
              @ifl_parse <>
                "invalid GROUP BY clause, expected wildcard, TIME, identifier or regular " <>
                "expression at pos #{at}"
            )
          end
        end
      end
    end
  end

  defp v3_influxql_show_tests(_client) do
    quote location: :keep do
      describe "InfluxQL SHOW TAG VALUES — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_sh")

          ifl_write(ctx, [
            "#{m},k=a,x=p i=1i 1000",
            "#{m},k=b i=2i 2000",
            "#{m},k=c,x=q i=3i 3000"
          ])

          {:ok, m: m}
        end

        # a row without `value` stands for the points that lack the key
        test "lists the values of the keys it names, over the last day unless time is bounded",
             %{m: m} = ctx do
          assert ifl_rows(ctx, "SHOW TAG VALUES FROM #{m} WITH KEY = k") === []

          bounded = fn spec, where ->
            ifl_rows(ctx, "SHOW TAG VALUES FROM #{m} WITH KEY #{spec} WHERE #{where}")
          end

          values = fn key, values -> Enum.map(values, &%{"key" => key, "value" => &1}) end
          k = values.("k", ["a", "b", "c"])
          x = values.("x", ["p", "q"]) ++ [%{"key" => "x"}]

          for {spec, expected} <- [
                {"= k", k},
                {"= x", x},
                {"!= k", x},
                {"IN (k, x)", k ++ x},
                {"=~ /./", k ++ x},
                {"!~ /k/", x},
                {"= nothere", []}
              ] do
            assert bounded.(spec, "time >= 0") === expected, spec
          end

          assert bounded.("= k", "time >= 0 AND i > 1") === values.("k", ["b", "c"])
          assert bounded.("= k", "time >= 0 AND x = 'p'") === values.("k", ["a"])
        end

        test "reads its WHERE as a SELECT does", %{m: m} = ctx do
          prefix = "SHOW TAG VALUES FROM #{m} WITH KEY = k WHERE "

          for where <- ["(", "()"] do
            statement = prefix <> where
            ifl_err(ctx, statement, ifl_nom(statement, byte_size(prefix) - 6))
          end

          statement = prefix <> "i >"

          ifl_err(
            ctx,
            statement,
            @ifl_parse <> "invalid conditional expression at pos #{byte_size(statement)}"
          )

          ifl_plan_err(
            ctx,
            prefix <> "time",
            500,
            "External error: InfluxQL internal error: expected an element on stack"
          )

          ifl_plan_err(
            ctx,
            prefix <> "time = 'a'",
            400,
            "Error during planning: invalid expression \"'a'\": 'a' is not a valid timestamp"
          )
        end
      end
    end
  end

  defp v3_influxql_tag_tests(_client) do
    quote location: :keep do
      describe "InfluxQL two tags compared — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_tt")

          ifl_write(ctx, [
            "#{m},k=a,x=a i=1i,s=\"a\",t=\"a\" 1000",
            "#{m},k=a,x=b i=2i,s=\"a\",t=\"b\" 2000"
          ])

          {:ok, m: m}
        end

        # the engine compares two tags as it compares nothing else: never equal,
        # never different
        test "is false for every row, whichever the operator", %{m: m} = ctx do
          for where <- [
                "k = x",
                "x = k",
                "k != x",
                "k <> x",
                "k = k",
                "x = x",
                "(k = x)",
                "k = x AND i > 0",
                "k = x OR k != x"
              ] do
            assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE #{where}") === [], where
          end

          assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE k = x OR i > 1") === [2]
        end

        test "a tag and a string field compare as strings", %{m: m} = ctx do
          for {where, expected} <- [
                {"k = s", [1, 2]},
                {"k != s", []},
                {"s = t", [1]},
                {"s != t", [2]},
                {"s = s", [1, 2]}
              ] do
            assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE #{where}") === expected, where
          end
        end
      end
    end
  end

  defp v3_influxql_literal_syntax_tests(_client) do
    quote location: :keep do
      describe "InfluxQL literals that are not closed, and =~ without a regex — contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_ls")
          ifl_write(ctx, ["#{m},k=a,x=a i=1i 1000", "#{m},k=a,x=b i=2i 2000"])
          {:ok, m: m}
        end

        test "a string or quoted identifier never closed is an error at the end of the text",
             %{m: m} = ctx do
          for statement <- [
                "SELECT i FROM #{m} WHERE k = 'a",
                "SELECT i FROM #{m} WHERE \"k = 1",
                "SELECT i FROM #{m} WHERE k = 'a' AND x = 'b",
                "SELECT i FROM #{m} WHERE k = 'a LIMIT 1",
                "SELECT i FROM #{m} WHERE k = 'a\\'",
                "SELECT \"i FROM #{m}",
                "SELECT i FROM \"#{m}",
                "SELECT i FROM #{m} GROUP BY \"k"
              ] do
            ifl_err(
              ctx,
              statement,
              @ifl_parse <> "unterminated string literal at pos #{byte_size(statement)}"
            )
          end
        end

        test "a regular expression never closed is an error at the end of the text",
             %{m: m} = ctx do
          for where <- ["k =~ /a", "k =~ /a/ AND x =~ /b", "k =~ /a LIMIT 1", "k !~ /a"] do
            statement = "SELECT i FROM #{m} WHERE #{where}"

            ifl_err(
              ctx,
              statement,
              @ifl_parse <> "unterminated regex literal at pos #{byte_size(statement)}"
            )
          end
        end

        test "=~ and !~ want a regular expression, at the end of the operator", %{m: m} = ctx do
          for {where, operator} <- [
                {"k =~ k", "=~"},
                {"k =~ 'a'", "=~"},
                {"k =~ 1", "=~"},
                {"k =~ \"a\"", "=~"},
                {"k =~ -1", "=~"},
                {"k =~ (a)", "=~"},
                {"k =~ AND i > 1", "=~"},
                {"k !~ k", "!~"},
                {"k !~ 'a'", "!~"},
                {"i > 1 AND k =~ 'a'", "=~"}
              ] do
            statement = "SELECT i FROM #{m} WHERE #{where}"

            ifl_err(
              ctx,
              statement,
              @ifl_parse <>
                "invalid conditional, expected regular expression at pos " <>
                "#{ifl_after(statement, operator)}"
            )
          end

          assert ifl_ids(ctx, "SELECT i FROM #{m} WHERE k =~ /a/  AND x =~  /b/") === [2]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxDB 2 line protocol
  # ---------------------------------------------------------------------------

  defp v2_line_protocol_helpers(_client) do
    quote location: :keep do
      # The Go parser's words; `~m` is the measurement.
      @ifl_v2_errors [
        {"this is not line protocol!!", "invalid field format"},
        {"~m v=", "missing field value"},
        {"~m v=.e3", "invalid float"},
        {"~m v=1e999", "invalid float"},
        {"~m v=tRUE", "invalid boolean"},
        {"~m v=+5", "invalid boolean"},
        {"~m v=1ii", "invalid number"},
        {"~m v=1 abc", "bad timestamp"},
        {"~m v=1 -", ~S|strconv.ParseInt: parsing "-": invalid syntax|},
        {"~m v=1 5 6", "point is invalid"},
        {"~m,t=1,t=2 v=1", "duplicate tags"},
        {"~m", "missing fields"},
        {"~m,t v=1", "missing tag value"},
        {"~m,=1 v=1", "missing tag key"},
        {"~m,t=a=b v=1", "invalid tag format"},
        {",t=1 v=1", "missing measurement"},
        {"~m =1", "missing field key"},
        {"~m v=1,w", "invalid field format"},
        {"~m v=1,,w=2", "invalid field format"},
        {~S|~m v="abc|, "unbalanced quotes"},
        {"~m v=9223372036854775808i",
         "unable to parse integer 9223372036854775808: " <>
           ~S|strconv.ParseInt: parsing "9223372036854775808": value out of range|},
        {"~m v=18446744073709551616u",
         "unable to parse unsigned 18446744073709551616: " <>
           ~S|strconv.ParseUint: parsing "18446744073709551616": value out of range|},
        # a name that ends in a backslash is judged where the line scans on
        {~S"~m\\ v=1i 5", "invalid field format"},
        {~S"~m\\", "missing fields"},
        {~S"~m,t\\ v=1i 5", "invalid field format"},
        {~S"~m,t\\", "missing tag value"},
        {~S"~m,t=a\\", "missing fields"},
        {~S"~m,t=a\\ ", "missing fields"},
        {~S"~m,t=a\\ v=1i 5", "invalid tag format"},
        {~S"~m,t\\=1 v=1i", "missing tag value"},
        {~S"~m,t=\\ v=1i", "invalid tag format"},
        {~S"~m v\\ =1i 5", "invalid field format"},
        {~S"~m v\\", "invalid field format"},
        {~S"~m v=1i,w\\ x=1i", "invalid field format"},
        {~S"~m v=1i,w\\=1i", ~S"invalid value: field-key=w\\=1i"},
        {~S"~m v\\=1i 5", ~S"invalid value: field-key=v\\=1i"}
      ]

      # The drops of one payload against a measurement that holds `v` as a
      # float: `~m` and `~n` are two measurements. An untimed point lands in
      # today's shard group and a timed one in its own week; the message is
      # the first drop of the earliest group that dropped any, and `dropped`
      # counts that group's drops.
      # Each payload with every drop the engine may report. When more than one
      # shard group fails, the engine reports one of them, and identical
      # writes were answered with different groups' (verified); the double
      # always reports the earliest group's, listed first.
      @ifl_v2_drops [
        {"~m time=1 5\n~m v=1i 6", [{:invalid, "~m", 2}]},
        {"~m v=1i 6\n~m time=1 5", [{:conflict, "~m", 2}]},
        {"~m v=1i 6\n~m v=2i 6\n~m time=1 5\n~m time=1 6", [{:conflict, "~m", 4}]},
        {"~m time=1\n~m v=1i 5", [{:conflict, "~m", 1}, {:invalid, "~m", 1}]},
        {"~m v=1i 5\n~m time=1", [{:conflict, "~m", 1}, {:invalid, "~m", 1}]},
        {"~m time=1\n~m time=2 5\n~n time=3", [{:invalid, "~m", 1}, {:invalid, "~m", 2}]},
        {"~n time=3\n~m time=3", [{:invalid, "~n", 2}]},
        {"~m v=1i 1000000000000000\n~m v=2i 1\n~m time=1 2", [{:conflict, "~m", 2}]},
        {"~m time=1 5\n~m v=1i 1000000000000000", [{:invalid, "~m", 1}]},
        {"~m v=1i 1000000000000000\n~m time=1 5", [{:invalid, "~m", 1}]},
        {"~m time=1 1000000000000000\n~m v=1i 5", [{:conflict, "~m", 1}, {:invalid, "~m", 1}]},
        {"~m v=1i 5\n~m time=1 1000000000000000\n~m time=1 3000000000000000",
         [{:conflict, "~m", 1}, {:invalid, "~m", 1}]}
      ]

      def ifl_v2_invalid(message),
        do: %{"code" => "invalid", "message" => message}

      # A bucket that keeps two hours; the engine's id and clock are masked.
      def ifl_with_retention_bucket(ctx, fun),
        do: ifl_with_bucket(ctx, "ifl_rb", [retention: 7200], fun)

      def ifl_masked(body) do
        update_in(Jason.decode!(body)["message"], fn message ->
          message
          |> String.replace(~r/Lower Bound at \d{4}-[-\d:.TZ]+/, "Lower Bound at BOUND")
          |> String.replace(~r/for database: [0-9a-f]{16} /, "for database: ID ")
        end)
      end

      def ifl_retention_message(count, oldest, oldest_time, newest, newest_time) do
        drop = fn which, key, time ->
          "#{which} point #{key} at #{time} dropped because it violates a " <>
            "Retention Policy Lower Bound at BOUND"
        end

        "failure writing points to database: partial write: dropped #{count} points outside " <>
          "retention policy of duration 2h0m0s - #{drop.("oldest", oldest, oldest_time)}, " <>
          "#{drop.("newest", newest, newest_time)} dropped=#{count} " <>
          "for database: ID for retention policy: autogen"
      end

      def ifl_v2_drop_message(:invalid, measurement, dropped) do
        "failure writing points to database: partial write: invalid field name: " <>
          ~s|input field "time" on measurement "#{measurement}" is invalid dropped=#{dropped}|
      end

      def ifl_v2_drop_message(:conflict, measurement, dropped) do
        "failure writing points to database: partial write: field type conflict: " <>
          ~s|input field "v" on measurement "#{measurement}" is type integer, | <>
          "already exists as type float dropped=#{dropped}"
      end
    end
  end

  defp v2_line_protocol_tests(client) do
    quote location: :keep do
      describe "line protocol grammar — InfluxDB 2 contract" do
        test "a line that does not parse is a 400 in the Go parser's words", ctx do
          for {template, reason} <- @ifl_v2_errors do
            line =
              String.replace(template, "~m", InfluxElixir.IntegrationHelper.unique_name("ifl_lp"))

            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, line, database: ctx.database)

            assert Jason.decode!(body) === ifl_v2_invalid("unable to parse '#{line}': #{reason}"),
                   line
          end
        end

        test "a carriage return ends a number, and stays in the quoted line", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_cr")

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, "#{m} n=1i\r\n", database: ctx.database)

          assert Jason.decode!(body) ===
                   ifl_v2_invalid("unable to parse '#{m} n=1i\r': invalid number")
        end

        test "every line that fails is reported, joined by newlines", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_many")

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(
                     ctx.conn,
                     "#{m} v=1 5\nbad line\n#{m} v=\n  #{m} w=2 5",
                     database: ctx.database
                   )

          assert Jason.decode!(body) ===
                   ifl_v2_invalid(
                     "unable to parse 'bad line': invalid field format\n" <>
                       "unable to parse '#{m} v=': missing field value"
                   )
        end

        test "leading whitespace, comments and blank lines are skipped, the point is stored",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_ws")
          ifl_write(ctx, ["", "  # a comment", "   ", "\t#{m} v=1 5", ""])

          assert {:ok, [row]} = ifl_flux(ctx, ifl_measurement_query(ctx, m, 100))
          assert {row["_measurement"], row["_field"], row["_value"]} === {m, "v", 1.0}
        end

        test "a line left open by a quote is quoted without the payload's final newline",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_open")

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, ~s|#{m} f="a\nBAD\n|, database: ctx.database)

          assert Jason.decode!(body) ===
                   ifl_v2_invalid(~s|unable to parse '#{m} f="a\nBAD': unbalanced quotes|)
        end

        test "a field named time is dropped; a point with nothing else is not written", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_time")

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "#{m} time=1,v=2 5", database: ctx.database)

          assert {:error, %{status: 422, body: body}} =
                   unquote(client).write(ctx.conn, "#{m} time=1 5", database: ctx.database)

          assert Jason.decode!(body) === %{
                   "code" => "unprocessable entity",
                   "message" => ifl_v2_drop_message(:invalid, m, 1)
                 }
        end

        @tag local_divergence:
               "the engine reports any failing shard group; Local always the earliest"
        test "dropped points are counted per shard group, the earliest group's first drop speaks",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_drop")
          n = InfluxElixir.IntegrationHelper.unique_name("ifl_dropn")
          ifl_write(ctx, ["#{m} v=1.5 5"])

          for {template, drops} <- @ifl_v2_drops do
            payload = template |> String.replace("~m", m) |> String.replace("~n", n)

            messages =
              for {kind, name, dropped} <- drops do
                speaker = name |> String.replace("~m", m) |> String.replace("~n", n)

                %{
                  "code" => "unprocessable entity",
                  "message" => ifl_v2_drop_message(kind, speaker, dropped)
                }
              end

            assert {:error, %{status: 422, body: body}} =
                     unquote(client).write(ctx.conn, payload, database: ctx.database)

            # The double's answer is the first; the engine's is any of them.
            if unquote(client) === InfluxElixir.Client.Local,
              do: assert(Jason.decode!(body) === hd(messages), template),
              else: assert(Jason.decode!(body) in messages, template)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Flux and buckets
  # ---------------------------------------------------------------------------

  defp v2_flux_helpers(client) do
    quote location: :keep do
      # Runs `fun` with a bucket the test creates. A real server outlives the
      # test, so the bucket is deleted when `fun` returns or raises, in the
      # test's own process (the double's store dies with it).
      def ifl_with_bucket(ctx, prefix, opts, fun) do
        InfluxElixir.ClientContract.with_scratch(unquote(client), ctx, :bucket, prefix, fn name ->
          :ok = unquote(client).create_bucket(ctx.conn, name, opts)
          fun.(name)
        end)
      end

      def ifl_range(ctx, stop), do: String.replace(ctx.head, "STOP", stop)

      def ifl_flux(ctx, query), do: unquote(client).query_flux(ctx.conn, query)

      # Everything of one measurement from the epoch to `stop` seconds.
      def ifl_measurement_query(ctx, measurement, stop) do
        ~s|from(bucket: "#{ctx.database}") \|> range(start: 0, stop: #{stop}) | <>
          ~s|\|> filter(fn: (r) => r._measurement == "#{measurement}")|
      end
    end
  end

  defp v2_flux_range_tests(_client) do
    quote location: :keep do
      describe "Flux range — InfluxDB 2 contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_fx")
          ifl_write(ctx, ["#{m} v=1 5", "#{m} v=2 1000000000"])

          head =
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0, stop: STOP) | <>
              ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|

          {:ok, m: m, head: head}
        end

        test "integer seconds become int64 nanoseconds, and wrap when they do not fit", ctx do
          assert {:ok, rows} = ifl_flux(ctx, ifl_range(ctx, "99999999999999"))

          assert Enum.map(rows, & &1["_value"]) === [1.0, 2.0]
          assert Enum.all?(rows, &(&1["_stop"] === ~U[1976-05-08 04:06:59.520689Z]))

          assert {:ok, rows} = ifl_flux(ctx, ifl_range(ctx, "9223372036"))

          assert Enum.all?(rows, &(&1["_stop"] === ~U[2262-04-11 23:47:16.000000Z]))

          # The stop wraps below the start, but a range is judged on the
          # seconds: nothing is read, and there is no error.
          assert {:ok, []} = ifl_flux(ctx, ifl_range(ctx, "18446744073"))
        end

        test "a range with no time in it is the engine's 400", ctx do
          for stop <- ["0", "-1", "9223372036854775807", "1970-01-01T00:00:00Z"] do
            assert {:error, %{status: 400, body: body}} = ifl_flux(ctx, ifl_range(ctx, stop))

            assert Jason.decode!(body) === %{
                     "code" => "invalid",
                     "message" =>
                       "error in building plan while starting program: " <>
                         "cannot query an empty range"
                   },
                   stop
          end
        end
      end
    end
  end

  defp v2_flux_data_tests(_client) do
    quote location: :keep do
      # A time in the nth week from 2023-01-04, in nanoseconds: every week is
      # a shard group of a bucket that keeps everything.
      def ifl_week(n), do: (1_672_790_400 + n * 604_800) * 1_000_000_000

      # What a read of the measurement over all of 2023 returns, as
      # `{field, tag t, value}` sorted.
      def ifl_weeks(ctx, m) do
        assert {:ok, rows} =
                 ifl_flux(
                   ctx,
                   ~s|from(bucket: "#{ctx.database}") \|> range(start: 1672531200, stop: 1704067200) | <>
                     ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|
                 )

        rows |> Enum.map(&{&1["_field"], &1["t"], &1["_value"]}) |> Enum.sort()
      end

      def ifl_filter_base(ctx),
        do: ~s|from(bucket: "#{ctx.database}") \|> range(start: 0, stop: 100) |

      def ifl_filter_fixture(ctx) do
        [a, b, c] =
          for p <- ["ifl_fa", "ifl_fb", "ifl_fc"],
              do: InfluxElixir.IntegrationHelper.unique_name(p)

        ifl_write(ctx, [
          "#{a},h=x v=1 1000000000",
          "#{b},h=x v=2 1000000000",
          "#{c},h=x v=3 1000000000",
          "#{a},h=y v=4 2000000000"
        ])

        %{a: a, b: b, c: c}
      end

      describe "Flux data and bucket listing — InfluxDB 2 contract" do
        test "first and last choose by the stored nanoseconds, not the microsecond shown",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_ns")
          ifl_write(ctx, ["#{m},t=a v=1i 1001", "#{m},t=a v=2i 1000"])

          base =
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0, stop: 100) | <>
              ~s|\|> filter(fn: (r) => r._measurement == "#{m}") |

          for {stage, value} <- [{"first()", 2}, {"last()", 1}, {"limit(n: 1)", 2}] do
            assert {:ok, [row]} = ifl_flux(ctx, base <> "|> " <> stage)
            assert row["_value"] === value, stage
          end
        end

        test "a filter on two measurements reads only those, numbering the tables across them",
             ctx do
          %{a: a, c: c} = ifl_filter_fixture(ctx)
          either = ~s/|> filter(fn: (r) => r._measurement == "#{a}" or r._measurement == "#{c}")/

          assert {:ok, rows} = ifl_flux(ctx, ifl_filter_base(ctx) <> either)

          assert Enum.map(rows, &{&1["table"], &1["_measurement"], &1["h"], &1["_value"]}) ===
                   [{0, a, "x", 1.0}, {1, a, "y", 4.0}, {2, c, "x", 3.0}]
        end

        test "a filter on one measurement numbers its first table 0", ctx do
          %{b: b} = ifl_filter_fixture(ctx)

          assert {:ok, [%{"table" => 0, "_value" => 2.0}]} =
                   ifl_flux(
                     ctx,
                     ifl_filter_base(ctx) <> ~s/|> filter(fn: (r) => r._measurement == "#{b}")/
                   )
        end

        test "a filter on a measurement that does not exist reads nothing", ctx do
          ifl_filter_fixture(ctx)

          assert {:ok, []} =
                   ifl_flux(
                     ctx,
                     ifl_filter_base(ctx) <>
                       ~s/|> filter(fn: (r) => r._measurement == "nope")/
                   )
        end

        test "a filter on a measurement and a tag reads that series only", ctx do
          %{a: a} = ifl_filter_fixture(ctx)

          assert {:ok, [%{"table" => 0, "_value" => 4.0}]} =
                   ifl_flux(
                     ctx,
                     ifl_filter_base(ctx) <>
                       ~s/|> filter(fn: (r) => r._measurement == "#{a}" and r.h == "y")/
                   )
        end
      end
    end
  end

  defp v2_flux_name_tests(_client) do
    quote location: :keep do
      describe "Flux names and quotes — InfluxDB 2 contract" do
        test "a quote in a tag value does not join the next line to it", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_fq")
          ifl_write(ctx, [~s|#{m},t=a"b f=1i 1000000000|, "#{m} f=2i 2000000000"])

          assert {:ok, rows} =
                   ifl_flux(
                     ctx,
                     ~s|from(bucket: "#{ctx.database}") \|> range(start: 0, stop: 100) | <>
                       ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|
                   )

          assert rows |> Enum.map(&{&1["t"], &1["_value"]}) |> Enum.sort() ===
                   [{nil, 2}, {~s|a"b|, 1}]
        end

        test "a measurement with a single escaped comma is readable under its unescaped name",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_esc")
          ifl_write(ctx, ["#{m}\\,t=a v=1i 1000000000"])

          assert {:ok, [%{"_measurement" => name, "_value" => 1}]} =
                   ifl_flux(
                     ctx,
                     ~s|from(bucket: "#{ctx.database}") \|> range(start: 0, stop: 100) | <>
                       ~s|\|> filter(fn: (r) => r._measurement == "#{m},t=a")|
                   )

          assert name === "#{m},t=a"
        end

        test "an escaped separator is part of a name, and Flux returns the unescaped one", ctx do
          for {template, name, columns} <- [
                {~S"~m,t\,u=1 v=1i 1000000000", "~m", %{"t,u" => "1"}},
                {~S"~m\ z v=1i 1000000000", "~m z", %{}},
                {~S"~m\,z v=1i 1000000000", "~m,z", %{}}
              ] do
            m = InfluxElixir.IntegrationHelper.unique_name("ifl_sep")
            ifl_write(ctx, [String.replace(template, "~m", m)])

            measurement = String.replace(name, "~m", m)
            assert {:ok, [row]} = ifl_flux(ctx, ifl_measurement_query(ctx, measurement, 100))

            assert row["_measurement"] === measurement
            assert row["_value"] === 1
            assert Map.take(row, Map.keys(columns)) === columns, template
          end
        end

        test "a measurement whose escapes the index and the data read differently is not read",
             ctx do
          field = InfluxElixir.IntegrationHelper.unique_name("ifl_gone_f")
          sentinel = InfluxElixir.IntegrationHelper.unique_name("ifl_here")

          gone =
            for suffix <- [~S|\\,x|, ~S|\\ x|, ~S|\=x|, ~S|\"x|, ~S|\\=x|],
                do:
                  "#{InfluxElixir.IntegrationHelper.unique_name("ifl_gone")}#{suffix} #{field}=1i 1000000000"

          ifl_write(ctx, gone ++ ["#{sentinel} #{field}=2i 1000000000"])

          assert {:ok, rows} =
                   ifl_flux(
                     ctx,
                     ~s|from(bucket: "#{ctx.database}") \|> range(start: 0, stop: 100) | <>
                       ~s|\|> filter(fn: (r) => r._field == "#{field}")|
                   )

          assert Enum.map(rows, &{&1["_measurement"], &1["_value"]}) === [{sentinel, 2}]
        end
      end
    end
  end

  defp v2_retention_tests(client) do
    quote location: :keep do
      describe "line protocol retention — InfluxDB 2 contract" do
        test "a point older than the bucket's retention is dropped, the others are written",
             ctx do
          ifl_with_retention_bucket(ctx, fn bucket ->
            m = InfluxElixir.IntegrationHelper.unique_name("ifl_old")
            fresh = System.os_time(:nanosecond) - 60_000_000_000

            payload =
              "#{m},t=b,u=c v=1i 1672790400000000001\n" <>
                "#{m},t=a v=2i 1672790400123456789\n#{m} v=3i #{fresh}"

            assert {:error, %{status: 422, body: body}} =
                     unquote(client).write(ctx.conn, payload, database: bucket)

            assert ifl_masked(body) ===
                     %{
                       "code" => "unprocessable entity",
                       "message" =>
                         ifl_retention_message(
                           2,
                           "#{m},t=b,u=c",
                           "2023-01-04T00:00:00.000000001Z",
                           "#{m},t=a",
                           "2023-01-04T00:00:00.123456789Z"
                         )
                     }

            assert {:ok, rows} =
                     ifl_flux(
                       ctx,
                       ~s|from(bucket: "#{bucket}") \|> range(start: -1h) | <>
                         ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|
                     )

            assert Enum.map(rows, & &1["_value"]) === [3]
          end)
        end

        test "a series key in a retention drop is sorted by tag and escaped", ctx do
          ifl_with_retention_bucket(ctx, fn bucket ->
            m = InfluxElixir.IntegrationHelper.unique_name("ifl_oldkey")

            payload = ~s|#{m}\\ x\\,y,b\\ k\\=1=v\\,2\\ 3,a=z v=1i 1672790400000000000|

            assert {:error, %{status: 422, body: body}} =
                     unquote(client).write(ctx.conn, payload, database: bucket)

            key = ~s|#{m}\\ x\\,y,a=z,b\\ k\\=1=v\\,2\\ 3|

            assert ifl_masked(body)["message"] ===
                     ifl_retention_message(
                       1,
                       key,
                       "2023-01-04T00:00:00Z",
                       key,
                       "2023-01-04T00:00:00Z"
                     )
          end)
        end

        test "a point older than the retention registers no field and is dropped whatever it is",
             ctx do
          ifl_with_retention_bucket(ctx, fn bucket ->
            m = InfluxElixir.IntegrationHelper.unique_name("ifl_oldtype")
            now = System.os_time(:nanosecond)

            for payload <- [
                  "#{m} v=2.5 1672790400000000000\n#{m} v=1i #{now}",
                  "#{m} time=1 1672790400000000000\n#{m} v=1i #{now + 1}"
                ] do
              assert {:error, %{status: 422, body: body}} =
                       unquote(client).write(ctx.conn, payload, database: bucket)

              assert Jason.decode!(body)["message"] =~
                       "partial write: dropped 1 points outside retention policy of duration 2h0m0s"
            end

            assert {:ok, :written} =
                     unquote(client).write(ctx.conn, "#{m} v=3i #{now + 2}", database: bucket)
          end)
        end

        test "a type conflict in a group is reported instead of the retention drops", ctx do
          ifl_with_retention_bucket(ctx, fn bucket ->
            m = InfluxElixir.IntegrationHelper.unique_name("ifl_oldconf")
            now = System.os_time(:nanosecond)

            assert {:ok, :written} =
                     unquote(client).write(ctx.conn, "#{m} v=1i #{now}", database: bucket)

            assert {:error, %{status: 422, body: body}} =
                     unquote(client).write(
                       ctx.conn,
                       "#{m} v=1i 1672790400000000000\n#{m} v=2.5 #{now + 1}",
                       database: bucket
                     )

            assert Jason.decode!(body)["message"] ===
                     "failure writing points to database: partial write: field type conflict: " <>
                       ~s|input field "v" on measurement "#{m}" is type float, | <>
                       "already exists as type integer dropped=1"
          end)
        end
      end
    end
  end

  defp v2_flux_type_tests(client) do
    quote location: :keep do
      describe "Flux field types per shard group — InfluxDB 2 contract" do
        test "a field of another type in a later shard group is not read after the first one",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_type")

          # The first point is in the week of the epoch, the others a week later.
          ifl_write(ctx, [
            "#{m} v=1.5 5",
            "#{m} v=1i 1000000000000000",
            "#{m} v=2i 1000000000000001"
          ])

          assert {:error, %{status: 422, body: body}} =
                   unquote(client).write(ctx.conn, "#{m} v=3i 6", database: ctx.database)

          assert Jason.decode!(body) === %{
                   "code" => "unprocessable entity",
                   "message" => ifl_v2_drop_message(:conflict, m, 1)
                 }

          read = fn start ->
            assert {:ok, rows} =
                     ifl_flux(
                       ctx,
                       ~s|from(bucket: "#{ctx.database}") \|> range(start: #{start}, stop: 2000000) | <>
                         ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|
                     )

            Enum.map(rows, & &1["_value"])
          end

          assert read.(0) === [1.5]
          assert read.(1_000_000) === [1, 2]
        end

        test "after the first group of another type, no later group of the field is read", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_cut")

          ifl_write(ctx, [
            "#{m} f=1i #{ifl_week(0)}",
            "#{m} f=2i #{ifl_week(1)}",
            "#{m} f=3.5 #{ifl_week(2)}",
            "#{m} f=4i #{ifl_week(3)}"
          ])

          assert ifl_weeks(ctx, m) === [{"f", nil, 1}, {"f", nil, 2}]
        end

        test "a group that differs from the first hides the rest, even of the first's type",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_cutfloat")

          ifl_write(ctx, [
            "#{m} f=1i #{ifl_week(0)}",
            "#{m} f=2.5 #{ifl_week(1)}",
            "#{m} f=3.5 #{ifl_week(2)}",
            "#{m} f=4i #{ifl_week(3)}"
          ])

          assert ifl_weeks(ctx, m) === [{"f", nil, 1}]
        end

        test "the cut is per measurement and field, across the tag sets", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_cuttags")

          ifl_write(ctx, [
            "#{m},t=a f=1i #{ifl_week(0)}",
            "#{m},t=b f=1i #{ifl_week(0)}",
            "#{m},t=a f=2.5 #{ifl_week(1)}",
            "#{m},t=b f=3i #{ifl_week(2)}"
          ])

          assert ifl_weeks(ctx, m) === [{"f", "a", 1}, {"f", "b", 1}]
        end

        test "a field that conflicts in a group does not cut the other fields", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("ifl_cutfield")

          ifl_write(ctx, [
            "#{m} f=1i,g=1i #{ifl_week(0)}",
            "#{m} f=2.5,g=2i #{ifl_week(1)}",
            "#{m} f=3i,g=3i #{ifl_week(2)}"
          ])

          assert ifl_weeks(ctx, m) === [
                   {"f", nil, 1},
                   {"g", nil, 1},
                   {"g", nil, 2},
                   {"g", nil, 3}
                 ]
        end
      end
    end
  end

  defp v2_bucket_tests(client) do
    quote location: :keep do
      describe "Bucket listing — InfluxDB 2 contract" do
        test "a listed bucket carries the engine's fields", ctx do
          ifl_with_bucket(ctx, "ifl_bkt", [], fn name ->
            assert {:ok, buckets} = unquote(client).list_buckets(ctx.conn)

            assert %{"id" => id, "orgID" => org_id} =
                     bucket = Enum.find(buckets, &(&1["name"] === name))

            assert bucket |> Map.keys() |> Enum.sort() ===
                     ~w(createdAt id labels links name orgID retentionRules type updatedAt)

            assert id =~ ~r/\A[0-9a-f]{16}\z/
            assert org_id =~ ~r/\A[0-9a-f]{16}\z/
            assert bucket["type"] === "user"
            assert bucket["labels"] === []

            for stamp <- [bucket["createdAt"], bucket["updatedAt"]],
                do: assert(stamp =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z\z/)

            assert bucket["retentionRules"] === [
                     %{
                       "type" => "expire",
                       "everySeconds" => 0,
                       "shardGroupDurationSeconds" => 604_800
                     }
                   ]

            assert bucket["links"] === %{
                     "labels" => "/api/v2/buckets/#{id}/labels",
                     "members" => "/api/v2/buckets/#{id}/members",
                     "org" => "/api/v2/orgs/#{org_id}",
                     "owners" => "/api/v2/buckets/#{id}/owners",
                     "self" => "/api/v2/buckets/#{id}",
                     "write" => "/api/v2/write?org=#{org_id}&bucket=#{id}"
                   }

            assert Enum.all?(buckets, &(&1["orgID"] === org_id or &1["type"] === "system"))
          end)
        end

        test "a bucket deleted and created again starts empty and takes any field type", ctx do
          ifl_with_bucket(ctx, "ifl_again", [], fn name ->
            assert {:ok, :written} = unquote(client).write(ctx.conn, "m v=1i 5", database: name)
            assert :ok = unquote(client).delete_bucket(ctx.conn, name)
            assert :ok = unquote(client).create_bucket(ctx.conn, name, [])
            assert {:ok, :written} = unquote(client).write(ctx.conn, "m v=1.5 6", database: name)

            assert {:ok, rows} =
                     ifl_flux(ctx, ~s|from(bucket: "#{name}") \|> range(start: 0, stop: 100)|)

            assert Enum.map(rows, & &1["_value"]) === [1.5]
          end)
        end

        test "the shard group of a bucket follows its retention", ctx do
          ifl_with_bucket(ctx, "ifl_ret", [retention: 7200], fn name ->
            assert {:ok, buckets} = unquote(client).list_buckets(ctx.conn)

            assert %{
                     "retentionRules" => [
                       %{"everySeconds" => 7200, "shardGroupDurationSeconds" => 3600}
                     ]
                   } = Enum.find(buckets, &(&1["name"] === name))
          end)
        end
      end
    end
  end
end
