defmodule InfluxElixir.Contract.WriteRules do
  @moduledoc """
  Write-rule and database-lifecycle contract tests, run against
  `InfluxElixir.Client.Local` and against a real InfluxDB 3: the answers the
  double must give exactly as the engine does (status and body of every
  refusal, what a rejected line leaves behind, what survives a database
  delete). Every expectation here was read from a Core with `curl` first.

      use InfluxElixir.Contract.WriteRules, client: InfluxElixir.Client.Local, profile: :v3_core

  The `setup` callback must return `conn`, `database` and `query_delay`, as for
  the shared contract. Each test has a database of its own, so the measurements
  are short fixed names: the engine cuts `original_line` to 20 bytes, and a
  long unique name would cut the rest of the line away.

  ## Parts

    * `:schema` — column types fixed by the first write, parse errors, the
      reserved `time`, integer extremes, repeated points
    * `:atomic` — `accept_partial: false`, `no_sync`, the engine's rendering of
      a line in an error
    * `:lifecycle` — databases that do not exist, names, the Core limit, a
      deleted database's schema
  """

  @parts [:schema, :atomic, :lifecycle]

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)
    part = Keyword.get(opts, :part, :all)

    unless part == :all or part in @parts do
      raise ArgumentError,
            "unknown :part #{inspect(part)}, expected :all or one of #{inspect(@parts)}"
    end

    tests =
      for {test_part, block} <- test_blocks(client, profile),
          block != nil,
          part == :all or part == test_part,
          do: block

    quote location: :keep do
      (unquote_splicing(tests))
    end
  end

  # Every block of tests with the part it belongs to, in order.
  @spec test_blocks(Macro.t(), atom()) :: [{atom(), Macro.t()}]
  defp test_blocks(client, profile) do
    [
      {:schema, conflict_tests(client)},
      {:schema, parse_error_tests(client)},
      {:schema, time_column_tests(client)},
      {:schema, value_range_tests(client)},
      {:schema, repeated_point_tests(client)},
      {:atomic, atomic_tests(client)},
      {:atomic, rendering_tests(client)},
      {:lifecycle, missing_database_tests(client)},
      {:lifecycle, name_tests(client)},
      {:lifecycle, delete_tests(client)},
      {:lifecycle, limit_tests(client, profile)}
    ]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc false
  # The engine's message for a column written as a kind it does not have.
  @spec conflict(binary(), binary(), binary()) :: binary()
  def conflict(column, expected, got) do
    "invalid column type for column '#{column}', expected iox::column_type::#{expected}, " <>
      "got iox::column_type::#{got}"
  end

  @doc false
  # The body of a partial write that refused one line, `original_line` as the
  # engine renders it and cuts it.
  @spec partial(integer(), binary(), binary()) :: map()
  def partial(line_number, message, original_line) do
    %{
      "error" => "partial write of line protocol occurred",
      "data" => [
        %{
          "error_message" => message,
          "line_number" => line_number,
          "original_line" => original_line
        }
      ]
    }
  end

  @doc false
  # `{line_number, error_message}` of each line a partial write refused.
  @spec partial_errors(binary()) :: [{integer(), binary()}]
  def partial_errors(body) do
    %{"error" => "partial write of line protocol occurred", "data" => data} = Jason.decode!(body)
    Enum.map(data, &{&1["line_number"], &1["error_message"]})
  end

  @doc false
  # The body of an `accept_partial: false` refusal.
  @spec atomic(integer(), binary(), binary()) :: map()
  def atomic(line_number, message, original_line) do
    %{
      "error" => "line protocol parsing error",
      "data" => %{
        "error_message" => message,
        "line_number" => line_number,
        "original_line" => original_line
      }
    }
  end

  @doc false
  # The engine's answer to a database beyond its limit.
  @spec limit_body() :: binary()
  def limit_body, do: ~s({"error":"Adding a new database would exceed limit of 5 databases"})

  # ---------------------------------------------------------------------------
  # Schema
  # ---------------------------------------------------------------------------

  defp conflict_tests(client) do
    quote location: :keep do
      describe "write/3 — a column's type is fixed by its first write" do
        test "across tags, strings, floats and booleans; a new column and database are fine",
             ctx do
          {:ok, :written} =
            unquote(client).write(ctx.conn, "c v=1i 1700000000000000000", database: ctx.database)

          # tag then field, field then tag, string then float, boolean then integer
          for {first, second, column, expected, got, rendered} <- [
                {"t,host=a v=1i", ~s|t host="b",v=2i|, "host", "tag", "field::string",
                 "t host=b,v=2i"},
                {~s|f host="a",v=1i|, "f,host=b v=2i", "host", "field::string", "tag",
                 "f,host=b v=2i"},
                {~s|s s="x"|, "s s=1.0", "s", "field::string", "field::float", "s s=1"},
                {"b b=true", "b b=1i", "b", "field::boolean", "field::integer", "b b=1i"}
              ] do
            {:ok, :written} = unquote(client).write(ctx.conn, first, database: ctx.database)

            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, second, database: ctx.database),
                   second

            assert Jason.decode!(body) ===
                     InfluxElixir.Contract.WriteRules.partial(
                       1,
                       InfluxElixir.Contract.WriteRules.conflict(column, expected, got),
                       rendered
                     ),
                   second
          end

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "c w=1.0 1700000000000000002",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :database,
            "contract_wr_other",
            fn other ->
              assert {:ok, :written} =
                       unquote(client).write(ctx.conn, "c v=2.0 1700000000000000000",
                         database: other
                       )
            end
          )
        end

        # The single conflicting line is pinned by the shared contract; this is
        # a syntax error and a conflict together, with every bad line listed.
        test "every bad line is reported; the other lines are stored", ctx do
          conflict =
            InfluxElixir.Contract.WriteRules.conflict(
              "v",
              "field::integer",
              "field::float"
            )

          lp =
            "q v=1i 1700000000000000000\nq v=\nq v=2.0 1700000000000000002\n" <>
              "q v=3i 1700000000000000003"

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, lp, database: ctx.database)

          assert InfluxElixir.Contract.WriteRules.partial_errors(body) ===
                   [{2, "No fields were provided"}, {3, conflict}]

          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).query_sql(ctx.conn, ~s|SELECT v FROM "q" ORDER BY time|,
                   database: ctx.database
                 ) === {:ok, [%{"v" => 1}, %{"v" => 3}]}
        end
      end
    end
  end

  defp parse_error_tests(client) do
    quote location: :keep do
      describe "write/3 — lines the engine cannot parse" do
        test "no field, an empty tag value, an empty tag key and trailing content", ctx do
          for {lp, message} <- [
                {"cpu value=notanumber", "No fields were provided"},
                {"cpu value=abci", "No fields were provided"},
                {"m =1i", "No fields were provided"},
                {"m,host= v=1i", "Expected tag value, got ` v=1i`"},
                {"m,=a v=1i", "Expected tag key, got `=a v=1i`"},
                {"cpu value=1i badtimestamp",
                 "Could not parse entire line. Found trailing content: ` badtimest...`"}
              ] do
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, lp, database: ctx.database),
                   lp

            assert InfluxElixir.Contract.WriteRules.partial_errors(body) === [{1, message}], lp
          end
        end
      end
    end
  end

  defp time_column_tests(client) do
    quote location: :keep do
      describe "write/3 — the time column and rejected lines" do
        test "on an existing table, time as a tag or field conflicts with the timestamp",
             ctx do
          {:ok, :written} =
            unquote(client).write(ctx.conn, "e,host=a v=1i 1700000000000000000",
              database: ctx.database
            )

          for {lp, got} <- [
                {"e,time=x v=1i", "tag"},
                {"e time=5i,v=1i", "field::integer"}
              ] do
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, lp, database: ctx.database),
                   lp

            assert InfluxElixir.Contract.WriteRules.partial_errors(body) ===
                     [
                       {1, InfluxElixir.Contract.WriteRules.conflict("time", "timestamp", got)}
                     ],
                   lp
          end
        end

        # A line that is rejected still registers the new columns it names: `n`
        # became a tag on the line that failed on `v`.
        test "a rejected line still registers its new columns", ctx do
          {:ok, :written} =
            unquote(client).write(ctx.conn, "e,host=a v=1i 1700000000000000000",
              database: ctx.database
            )

          assert {:error, %{status: 400, body: first}} =
                   unquote(client).write(ctx.conn, "e,n=x v=2.0", database: ctx.database)

          assert InfluxElixir.Contract.WriteRules.partial_errors(first) ===
                   [
                     {1,
                      InfluxElixir.Contract.WriteRules.conflict(
                        "v",
                        "field::integer",
                        "field::float"
                      )}
                   ]

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, "e n=1i", database: ctx.database)

          assert InfluxElixir.Contract.WriteRules.partial_errors(body) ===
                   [
                     {1, InfluxElixir.Contract.WriteRules.conflict("n", "tag", "field::integer")}
                   ]
        end
      end
    end
  end

  defp value_range_tests(client) do
    quote location: :keep do
      describe "write/3 — integer extremes" do
        test "int64 and uint64 extremes read back exactly", ctx do
          lp =
            "n big=9223372036854775807i,small=-9223372036854775808i," <>
              "u=18446744073709551615u 1700000000000000000"

          assert {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).query_sql(ctx.conn, ~s|SELECT big, small, u FROM "n"|,
                   database: ctx.database
                 ) ===
                   {:ok,
                    [
                      %{
                        "big" => 9_223_372_036_854_775_807,
                        "small" => -9_223_372_036_854_775_808,
                        "u" => 18_446_744_073_709_551_615
                      }
                    ]}
        end
      end
    end
  end

  defp repeated_point_tests(client) do
    quote location: :keep do
      describe "write/3 — a point repeated within one payload" do
        test "the last line wins; aggregates see one point", ctx do
          t = "1700000000000000000"

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "e,h=x v=1i #{t}\ne,h=x v=2i #{t}\ne v=5i #{t}\ne v=6i #{t}",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).query_sql(
                   ctx.conn,
                   "SELECT COUNT(v) AS n, SUM(v) AS s FROM e",
                   database: ctx.database
                 ) === {:ok, [%{"n" => 2, "s" => 8}]}

          assert unquote(client).query_sql(ctx.conn, "SELECT v FROM e WHERE h IS NULL",
                   database: ctx.database
                 ) === {:ok, [%{"v" => 6}]}
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # accept_partial: false and no_sync
  # ---------------------------------------------------------------------------

  defp atomic_tests(client) do
    quote location: :keep do
      describe "write/3 — accept_partial: false" do
        test "the first bad line in line order rejects the whole payload", ctx do
          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, "m1 v=1i 1\nm1 v=\nm1 x=\nm1 v=3i 3",
                     database: ctx.database,
                     accept_partial: false
                   )

          assert Jason.decode!(body) ===
                   InfluxElixir.Contract.WriteRules.atomic(2, "No fields were provided", "m1 v=")

          InfluxElixir.ClientContract.settle(ctx)

          assert {:error,
                  %{status: 400, body: "Error during planning: table 'public.iox.m1' not found"}} =
                   unquote(client).query_sql(ctx.conn, "SELECT * FROM m1", database: ctx.database)
        end

        # The rejection body itself is pinned by the shared contract; a rejected
        # payload leaves no schema behind, which no query can show on its own.
        test "a conflict with an earlier line of the payload registers no schema", ctx do
          assert {:error, %{status: 400}} =
                   unquote(client).write(ctx.conn, "m2 v=1i 1\nm2 v=2.0 2",
                     database: ctx.database,
                     accept_partial: false
                   )

          # Nothing was registered: a float is now the first kind of `v`.
          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "m2 v=3.5 3", database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).query_sql(ctx.conn, "SELECT v FROM m2", database: ctx.database) ===
                   {:ok, [%{"v" => 3.5}]}
        end

        test "time as a tag on a new table is the reserved-column error", ctx do
          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, "m4,time=x v=1i 1",
                     database: ctx.database,
                     accept_partial: false
                   )

          assert Jason.decode!(body) ===
                   InfluxElixir.Contract.WriteRules.atomic(
                     1,
                     "'time' is a reserved column",
                     "m4,time=x v=1i 1"
                   )

          # Nothing was stored: the table does not exist.
          InfluxElixir.ClientContract.settle(ctx)

          assert {:error,
                  %{status: 400, body: "Error during planning: table 'public.iox.m4' not found"}} =
                   unquote(client).query_sql(ctx.conn, "SELECT * FROM m4", database: ctx.database)
        end

        test "a flag that is not a boolean is the engine's 400", ctx do
          for key <- [:accept_partial, :no_sync] do
            assert {:error,
                    %{status: 400, body: "serde error: provided string was not `true` or `false`"}} =
                     unquote(client).write(ctx.conn, "m5 v=1i 1", [
                       {:database, ctx.database},
                       {key, "yes"}
                     ]),
                   inspect(key)
          end
        end
      end
    end
  end

  defp rendering_tests(client) do
    quote location: :keep do
      describe "write/3 — the line in a schema error is rendered as the engine does" do
        test "numbers and strings are re-printed, spacing is normalised", ctx do
          {:ok, :written} =
            unquote(client).write(ctx.conn, "r v=1i,a=1i 1", database: ctx.database)

          for {lp, rendered} <- [
                {"r    v=2.50,a=3i   2", "r v=2.5,a=3i 2"},
                {"r,t=x v=1e3 4", "r,t=x v=1000 4"},
                {~s(r v="s" 6), "r v=s 6"},
                {"r v=1.5e-7 8", "r v=0.00000015 8"}
              ] do
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, lp, database: ctx.database),
                   lp

            assert [%{"original_line" => ^rendered} = entry] = Jason.decode!(body)["data"], lp
            assert Map.keys(entry) === ["error_message", "line_number", "original_line"], lp
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Database lifecycle
  # ---------------------------------------------------------------------------

  defp missing_database_tests(client) do
    quote location: :keep do
      describe "queries against a database that does not exist" do
        test "every SQL statement is the engine's 404 before it is parsed; InfluxQL too",
             ctx do
          db = InfluxElixir.IntegrationHelper.unique_name("contract_nodb")
          body = ~s({"error":"query error: database not found: #{db}"})

          for sql <- ["SELECT * FROM m", "SELECT 1", "DELETE FROM m", "SELEC 1"] do
            assert {:error, %{status: 404, body: ^body}} =
                     unquote(client).query_sql(ctx.conn, sql, database: db),
                   sql
          end

          for influxql <- ["SELECT value FROM m", "SHOW MEASUREMENTS"] do
            assert {:error, %{status: 404, body: ^body}} =
                     unquote(client).query_influxql(ctx.conn, influxql, database: db),
                   influxql
          end
        end

        test "InfluxQL with no database anywhere is the engine's 400", ctx do
          conn = InfluxElixir.ClientContract.with_database(ctx.conn, nil)

          assert {:error,
                  %{
                    status: 400,
                    body:
                      "must specify a 'db' parameter, or provide the database in the " <>
                        "InfluxQL query"
                  }} = unquote(client).query_influxql(conn, "SHOW MEASUREMENTS")
        end
      end
    end
  end

  defp name_tests(client) do
    quote location: :keep do
      describe "database names" do
        test "more names the engine refuses, with the first rule each breaks", ctx do
          invalid =
            "invalid character in database or rp name: must be ASCII, containing only " <>
              "letters, numbers, underscores, or hyphens"

          retention =
            "db name with invalid retention policy, if providing a retention policy name, " <>
              "must be of form '<db_name>/<rp_name>'"

          start = "db name did not start with a number or letter"

          for {name, message} <- [
                {"-", start},
                {"_a/b/c", start},
                {"a.b", invalid},
                {"héllo", invalid},
                {"a b", invalid},
                {"a.b/", invalid},
                {"x/", retention},
                {"a//b", retention},
                {"a/b/c", retention}
              ] do
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).create_database(ctx.conn, name, []),
                   inspect(name)

            assert Jason.decode!(body) === %{"error" => message}, inspect(name)
          end
        end

        test "names the engine accepts, a retention policy and 200 characters included",
             ctx do
          base = InfluxElixir.IntegrationHelper.unique_name("contract_nm")

          for name <- [
                base,
                "1" <> base,
                String.upcase(base) <> "-b",
                base <> "_b",
                base <> "/_b",
                base <> "/B",
                "c" <> String.duplicate("c", 199)
              ] do
            assert :ok = unquote(client).create_database(ctx.conn, name, []), inspect(name)
            assert :ok = unquote(client).delete_database(ctx.conn, name), inspect(name)
          end
        end
      end
    end
  end

  defp delete_tests(client) do
    quote location: :keep do
      describe "delete_database/2 — the database's schema goes with it" do
        test "deleting a database drops its points and its schema", ctx do
          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :database,
            "contract_recreate",
            fn db ->
              {:ok, :written} =
                unquote(client).write(ctx.conn, "d v=1i 1700000000000000000", database: db)

              :ok = unquote(client).delete_database(ctx.conn, db)
              :ok = unquote(client).create_database(ctx.conn, db, [])
              InfluxElixir.ClientContract.settle(ctx)

              assert {:error,
                      %{
                        status: 400,
                        body: "Error during planning: table 'public.iox.d' not found"
                      }} =
                       unquote(client).query_sql(ctx.conn, ~s|SELECT v FROM "d"|, database: db)

              # The old integer schema is gone: a float is the first writer now.
              assert {:ok, :written} =
                       unquote(client).write(ctx.conn, "d v=2.0 1700000000000000000",
                         database: db
                       )
            end
          )
        end
      end
    end
  end

  # Core holds 5 databases besides `_internal`; Enterprise's limit was not read.
  defp limit_tests(client, :v3_core) do
    quote location: :keep do
      describe "databases — the Core limit" do
        test "a sixth database is the engine's 422, created or written to", ctx do
          unique = InfluxElixir.IntegrationHelper.unique_name("contract_lim")
          names = for i <- 1..6, do: "#{unique}_#{i}"

          try do
            # Create until the engine refuses; the server and this test already
            # hold some of the five, so fewer than six fit.
            {created, refused} =
              Enum.reduce_while(names, {[], nil}, fn name, {created, _refused} ->
                case unquote(client).create_database(ctx.conn, name, []) do
                  :ok -> {:cont, {[name | created], nil}}
                  error -> {:halt, {created, {name, error}}}
                end
              end)

            assert {name, {:error, %{status: 422, body: body}}} = refused
            assert body === InfluxElixir.Contract.WriteRules.limit_body()

            assert {:error, %{status: 422, body: ^body}} =
                     unquote(client).write(ctx.conn, "m v=1i 1", database: name)

            # Re-creating one that exists is fine at the limit; dropping one frees a slot.
            [existing | _rest] = created
            assert :ok = unquote(client).create_database(ctx.conn, existing, [])
            assert :ok = unquote(client).delete_database(ctx.conn, existing)
            assert :ok = unquote(client).create_database(ctx.conn, name, [])

            # A bad name is still its 400 at the limit.
            assert {:error, %{status: 400}} =
                     unquote(client).create_database(ctx.conn, "_#{name}", [])
          after
            Enum.each(names, fn name ->
              _result = unquote(client).delete_database(ctx.conn, name)
            end)
          end
        end
      end
    end
  end

  defp limit_tests(_client, _profile), do: nil
end
