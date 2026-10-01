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

  The `setup` callback must return `conn`, `database` and `query_delay`, as
  for the shared contract. A real server is shared between runs, so every
  measurement name is unique and every line is given a timestamp.
  """

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)

    blocks =
      case profile do
        :v3_core -> [helpers(client), v3_line_protocol_tests(client), v3_influxql_tests(client)]
        :v2 -> [helpers(client), v2_line_protocol_tests(client), v2_flux_tests(client)]
        _other -> []
      end

    quote do
      (unquote_splicing(blocks))
    end
  end

  defp helpers(client) do
    quote do
      defp ifl_name(prefix),
        do: "#{prefix}_#{100_000_000 + System.unique_integer([:positive])}"

      defp ifl_write(ctx, lines) do
        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, Enum.join(lines, "\n"), database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)
      end

      # A real server outlives the test, so its bucket is deleted after it;
      # the double may be gone by then.
      defp ifl_delete_after(ctx, name) do
        on_exit(fn ->
          try do
            unquote(client).delete_bucket(ctx.conn, name)
          rescue
            ArgumentError -> :ok
          end
        end)
      end

      # The engine's 400 for InfluxDB 3: one entry per bad line.
      defp ifl_partial_errors(body) do
        assert %{"error" => "partial write of line protocol occurred", "data" => data} =
                 Jason.decode!(body)

        for %{"error_message" => message, "line_number" => number} <- data,
            do: {number, message}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxDB 3 line protocol
  # ---------------------------------------------------------------------------

  defp v3_line_protocol_tests(client) do
    quote do
      describe "line protocol grammar — InfluxDB 3 contract" do
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
          {"~m,=a v=1 5", "Expected tag key, got `=a v=1 5`"}
        ]

        test "a line that does not parse is the engine's 400, in the engine's words", ctx do
          for {template, message} <- @ifl_v3_errors do
            line = String.replace(template, "~m", ifl_name("ifl_lp"))

            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, line, database: ctx.database)

            assert [{1, ^message}] = ifl_partial_errors(body), line
          end
        end

        test "what the engine's grammar lets through is written", ctx do
          for template <- [
                # a trailing comma, a comma in a field key, a tag key that
                # starts with one or holds one, an `=` inside a tag value
                "~m v=1, 5",
                "~m a,b=1 5",
                "~m,,t=1 v=1 5",
                "~m,t,u=1 v=1 5",
                "~m,t=a=b v=1 5",
                "~m v=1.5e3 5"
              ] do
            line = String.replace(template, "~m", ifl_name("ifl_ok"))

            assert {:ok, :written} =
                     unquote(client).write(ctx.conn, line, database: ctx.database),
                   line
          end
        end

        test "good lines around a bad one are written, the bad one is numbered", ctx do
          m = ifl_name("ifl_mix")

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

          assert Enum.map(rows, & &1["v"]) == [1.0, 3.0]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxQL
  # ---------------------------------------------------------------------------

  defp v3_influxql_tests(client) do
    quote do
      describe "InfluxQL WHERE, time and LIMIT — contract" do
        # Times are whole microseconds, which a query result carries.
        setup ctx do
          m = ifl_name("ifl_iq")

          ifl_write(ctx, [
            "#{m},k=a v=1,w=10 1000",
            "#{m},k=b v=2,w=20 2000",
            "#{m},k=a v=3,w=30 3000",
            "#{m},k=into v=4,w=40 4000",
            "#{m},k=c x=7i 5000"
          ])

          {:ok, m: m}
        end

        defp ifl_iq(ctx, statement) do
          unquote(client).query_influxql(ctx.conn, statement, database: ctx.database)
        end

        defp ifl_iq_values(ctx, statement, column \\ "v") do
          assert {:ok, rows} = ifl_iq(ctx, statement)
          Enum.map(rows, & &1[column])
        end

        defp ifl_us(microseconds), do: DateTime.from_unix!(microseconds, :microsecond)

        test "a keyword inside a quoted string is a string, not a keyword", ctx do
          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE k = 'into'") == [4.0]
          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE k = 'fill('") == []
          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE k = 'group by x'") == []
          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE k =~ /into/") == [4.0]
          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE k =~ /fill\\(/") == []
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
            assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} WHERE #{where}") == expected,
                   where
          end
        end

        test "time != and time <> are a planning error", ctx do
          body =
            "rewriting statement\ncaused by\nsplit condition\ncaused by\n" <>
              "Error during planning: invalid time comparison operator: !="

          for operator <- ["!=", "<>"] do
            assert {:error, %{status: 400, body: ^body}} =
                     ifl_iq(ctx, "SELECT v FROM #{ctx.m} WHERE time #{operator} 2000")
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

          assert Enum.map(rows, &{&1["k"], &1["mean"], &1["time"]}) == [
                   {"a", 3.0, two},
                   {"b", 2.0, two},
                   {"into", 4.0, two}
                 ]
        end

        test "LIMIT and OFFSET count per selected field, not per row", ctx do
          assert {:ok, rows} = ifl_iq(ctx, "SELECT v, x FROM #{ctx.m} LIMIT 2")

          assert Enum.map(rows, &{&1["time"], &1["v"], &1["x"]}) == [
                   {ifl_us(1), 1.0, nil},
                   {ifl_us(2), 2.0, nil},
                   {ifl_us(5), nil, 7}
                 ]

          assert {:ok, rows} = ifl_iq(ctx, "SELECT * FROM #{ctx.m} LIMIT 1")

          assert Enum.map(rows, &{&1["time"], &1["k"], &1["v"], &1["w"], &1["x"]}) == [
                   {ifl_us(1), "a", 1.0, 10.0, nil},
                   {ifl_us(5), "c", nil, nil, 7}
                 ]

          assert ifl_iq_values(ctx, "SELECT v FROM #{ctx.m} LIMIT 1 OFFSET 1") == [2.0]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxDB 2 line protocol
  # ---------------------------------------------------------------------------

  defp v2_line_protocol_tests(client) do
    quote do
      describe "line protocol grammar — InfluxDB 2 contract" do
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
             ~S|strconv.ParseUint: parsing "18446744073709551616": value out of range|}
        ]

        defp ifl_v2_invalid(message),
          do: %{"code" => "invalid", "message" => message}

        test "a line that does not parse is a 400 in the Go parser's words", ctx do
          for {template, reason} <- @ifl_v2_errors do
            line = String.replace(template, "~m", ifl_name("ifl_lp"))

            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, line, database: ctx.database)

            assert Jason.decode!(body) == ifl_v2_invalid("unable to parse '#{line}': #{reason}"),
                   line
          end
        end

        test "a carriage return ends a number, and stays in the quoted line", ctx do
          m = ifl_name("ifl_cr")

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, "#{m} n=1i\r\n", database: ctx.database)

          assert Jason.decode!(body) ==
                   ifl_v2_invalid("unable to parse '#{m} n=1i\r': invalid number")
        end

        test "every line that fails is reported, joined by newlines", ctx do
          m = ifl_name("ifl_many")

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(
                     ctx.conn,
                     "#{m} v=1 5\nbad line\n#{m} v=\n  #{m} w=2 5",
                     database: ctx.database
                   )

          assert Jason.decode!(body) ==
                   ifl_v2_invalid(
                     "unable to parse 'bad line': invalid field format\n" <>
                       "unable to parse '#{m} v=': missing field value"
                   )
        end

        test "leading whitespace, comments and blank lines are skipped", ctx do
          m = ifl_name("ifl_ws")

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "\n  # a comment\n   \n\t#{m} v=1 5\n",
                     database: ctx.database
                   )
        end

        test "a field named time is dropped; a point with nothing else is not written", ctx do
          m = ifl_name("ifl_time")

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "#{m} time=1,v=2 5", database: ctx.database)

          assert {:error, %{status: 422, body: body}} =
                   unquote(client).write(ctx.conn, "#{m} time=1 5", database: ctx.database)

          assert Jason.decode!(body) == %{
                   "code" => "unprocessable entity",
                   "message" =>
                     "failure writing points to database: partial write: invalid field name: " <>
                       ~s|input field "time" on measurement "#{m}" is invalid dropped=1|
                 }
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Flux and buckets
  # ---------------------------------------------------------------------------

  defp v2_flux_tests(client) do
    quote do
      describe "Flux range and bucket listing — InfluxDB 2 contract" do
        setup ctx do
          m = ifl_name("ifl_fx")
          ifl_write(ctx, ["#{m} v=1 5", "#{m} v=2 1000000000"])

          head =
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0, stop: STOP) | <>
              ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|

          {:ok, m: m, head: head}
        end

        defp ifl_range(ctx, stop), do: String.replace(ctx.head, "STOP", stop)

        test "integer seconds become int64 nanoseconds, and wrap when they do not fit", ctx do
          assert {:ok, rows} =
                   unquote(client).query_flux(ctx.conn, ifl_range(ctx, "99999999999999"))

          assert Enum.map(rows, & &1["_value"]) == [1.0, 2.0]
          assert Enum.all?(rows, &(&1["_stop"] == ~U[1976-05-08 04:06:59.520689Z]))

          assert {:ok, rows} =
                   unquote(client).query_flux(ctx.conn, ifl_range(ctx, "9223372036"))

          assert Enum.all?(rows, &(&1["_stop"] == ~U[2262-04-11 23:47:16.000000Z]))

          # The stop wraps below the start, but a range is judged on the
          # seconds: nothing is read, and there is no error.
          assert {:ok, []} = unquote(client).query_flux(ctx.conn, ifl_range(ctx, "18446744073"))
        end

        test "a range with no time in it is the engine's 400", ctx do
          for stop <- ["0", "-1", "9223372036854775807", "1970-01-01T00:00:00Z"] do
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).query_flux(ctx.conn, ifl_range(ctx, stop))

            assert Jason.decode!(body) == %{
                     "code" => "invalid",
                     "message" =>
                       "error in building plan while starting program: " <>
                         "cannot query an empty range"
                   },
                   stop
          end
        end

        test "a listed bucket carries the engine's fields", ctx do
          name = ifl_name("ifl_bkt")
          :ok = unquote(client).create_bucket(ctx.conn, name, [])
          ifl_delete_after(ctx, name)

          assert {:ok, buckets} = unquote(client).list_buckets(ctx.conn)

          assert %{"id" => id, "orgID" => org_id} =
                   bucket = Enum.find(buckets, &(&1["name"] == name))

          assert bucket |> Map.keys() |> Enum.sort() ==
                   ~w(createdAt id labels links name orgID retentionRules type updatedAt)

          assert id =~ ~r/\A[0-9a-f]{16}\z/
          assert org_id =~ ~r/\A[0-9a-f]{16}\z/
          assert bucket["type"] == "user"
          assert bucket["labels"] == []

          for stamp <- [bucket["createdAt"], bucket["updatedAt"]],
              do: assert(stamp =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z\z/)

          assert bucket["retentionRules"] == [
                   %{
                     "type" => "expire",
                     "everySeconds" => 0,
                     "shardGroupDurationSeconds" => 604_800
                   }
                 ]

          assert bucket["links"] == %{
                   "labels" => "/api/v2/buckets/#{id}/labels",
                   "members" => "/api/v2/buckets/#{id}/members",
                   "org" => "/api/v2/orgs/#{org_id}",
                   "owners" => "/api/v2/buckets/#{id}/owners",
                   "self" => "/api/v2/buckets/#{id}",
                   "write" => "/api/v2/write?org=#{org_id}&bucket=#{id}"
                 }

          assert Enum.all?(buckets, &(&1["orgID"] == org_id or &1["type"] == "system"))
        end

        test "the shard group of a bucket follows its retention", ctx do
          name = ifl_name("ifl_ret")
          :ok = unquote(client).create_bucket(ctx.conn, name, retention: 7200)
          ifl_delete_after(ctx, name)

          assert {:ok, buckets} = unquote(client).list_buckets(ctx.conn)

          assert %{
                   "retentionRules" => [
                     %{"everySeconds" => 7200, "shardGroupDurationSeconds" => 3600}
                   ]
                 } = Enum.find(buckets, &(&1["name"] == name))
        end
      end
    end
  end
end
