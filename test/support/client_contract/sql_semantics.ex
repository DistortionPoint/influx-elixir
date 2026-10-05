defmodule InfluxElixir.ClientContract.SqlSemantics do
  @moduledoc """
  The `:sql_semantics` part of `InfluxElixir.ClientContract`:
  SQL semantics: first/last and DISTINCT, parameters, literals, statements and
  execute_sql, references, NULLs, DISTINCT ON (the InfluxDB 3 profiles).
  """

  @doc false
  @spec blocks(Macro.t(), atom()) :: [Macro.t()]
  def blocks(client, profile) when profile in [:v3_core, :v3_enterprise] do
    execute_tests =
      if profile === :v3_enterprise,
        do: execute_tests_enterprise(client),
        else: execute_tests_core(client)

    [
      ordered_agg_tests(client),
      distinct_tests(client),
      param_tests(client),
      literal_tests(client),
      execute_tests,
      statement_tests(client),
      reference_tests(client),
      null_semantics_tests(client),
      distinct_on_tests(client)
    ]
  end

  def blocks(_client, _profile), do: []

  defp statement_tests(client) do
    quote location: :keep do
      describe "execute_sql/3 — contract: a text that is no statement" do
        test "a text that starts no statement is the parser's error, at its position", ctx do
          query = &unquote(client).query_sql(ctx.conn, &1, database: ctx.database)
          exec = &unquote(client).execute_sql(ctx.conn, &1, database: ctx.database)
          found = &~s|SQL error: ParserError("Expected: an SQL statement, found: #{&1}")|

          InfluxElixir.TestSupport.Check.each_case(
            [
              {"FOO bar", "FOO", "Line: 1, Column: 1"},
              {"SELEC 1", "SELEC", "Line: 1, Column: 1"},
              {"1", "1", "Line: 1, Column: 1"},
              {"42 + 1", "42", "Line: 1, Column: 1"},
              {"1.5", "1.5", "Line: 1, Column: 1"},
              {"123abc", "123", "Line: 1, Column: 1"},
              {"foo.bar", "foo", "Line: 1, Column: 1"},
              {"FOO;", "FOO", "Line: 1, Column: 1"},
              {"'abc'", "'abc'", "Line: 1, Column: 1"},
              {"* from t", "*", "Line: 1, Column: 1"},
              {", select", ",", "Line: 1, Column: 1"},
              {"@@", "@@", "Line: 1, Column: 1"},
              {"ünï", "ünï", "Line: 1, Column: 1"},
              {"  FOO bar", "FOO", "Line: 1, Column: 3"},
              {"\n  FOO bar", "FOO", "Line: 2, Column: 3"},
              {"LOCK TABLE t", "LOCK", "Line: 1, Column: 1"},
              {"RESET x", "RESET", "Line: 1, Column: 1"},
              {"LISTEN x", "LISTEN", "Line: 1, Column: 1"},
              {"@@x", "@@x", "Line: 1, Column: 1"},
              {"@x y", "@x", "Line: 1, Column: 1"},
              {"1e5", "1e5", "Line: 1, Column: 1"},
              {"1.e5", "1.e5", "Line: 1, Column: 1"},
              {".5", ".5", "Line: 1, Column: 1"},
              {"1e", "1", "Line: 1, Column: 1"},
              {"0x1f", "X'1f'", "Line: 1, Column: 1"},
              {"0x", "X''", "Line: 1, Column: 1"},
              {"0X1F", "0", "Line: 1, Column: 1"},
              {"'a''b'", "'a'b'", "Line: 1, Column: 1"},
              {~S|"a""b"|, ~S|\"a\"b\"|, "Line: 1, Column: 1"},
              {"N'x'", "N'x'", "Line: 1, Column: 1"},
              {"n'x'", "N'x'", "Line: 1, Column: 1"},
              {"b'1'", "B'1'", "Line: 1, Column: 1"},
              {"E'x'", "E'x'", "Line: 1, Column: 1"},
              {"r'x'", "R'x'", "Line: 1, Column: 1"},
              {"U&'x'", "U&'x'", "Line: 1, Column: 1"},
              {"u&'x'", "U&'x'", "Line: 1, Column: 1"},
              {"X'1f'", "X'1f'", "Line: 1, Column: 1"},
              {"x'zz'", "X'zz'", "Line: 1, Column: 1"},
              {"Q'x'", "Q", "Line: 1, Column: 1"},
              {"$a", "$a", "Line: 1, Column: 1"},
              {"$$x$$", "$$x$$", "Line: 1, Column: 1"},
              {"`a b`", "`a b`", "Line: 1, Column: 1"},
              {"#a", "#a", "Line: 1, Column: 1"},
              {"!= x", "<>", "Line: 1, Column: 1"},
              {"|| x", "||", "Line: 1, Column: 1"},
              {"/* c */ foo", "foo", "Line: 1, Column: 9"},
              {"/* /* n */ */ foo", "foo", "Line: 1, Column: 15"},
              {"-- c\nfoo", "foo", "Line: 2, Column: 1"}
            ],
            fn {text, token, position} ->
              expected = {:error, %{status: 400, body: found.("#{token} at #{position}")}}
              assert query.(text) === expected, text
              assert exec.(text) === expected, text
            end
          )
        end

        test "a statement word alone is what the parser needs next, or the engine's answer",
             ctx do
          query = &unquote(client).query_sql(ctx.conn, &1, database: ctx.database)
          exec = &unquote(client).execute_sql(ctx.conn, &1, database: ctx.database)
          parser = &{400, ~s|SQL error: ParserError("Expected: #{&1}")|}
          not_implemented = &{405, "This feature is not implemented: " <> &1}

          # Why this list: a statement word that needs a name, one that needs an expression
          # or a keyword, a `;` after one (its position is the error's), a lower case word,
          # leading space, and the words the engine answers with a 405 or a planning error.
          InfluxElixir.TestSupport.Check.each_case(
            [
              {"update", parser.("identifier, found: EOF")},
              {"UPDATE", parser.("identifier, found: EOF")},
              {"UPDATE;", parser.("identifier, found: ; at Line: 1, Column: 7")},
              {" update ;", parser.("identifier, found: ; at Line: 1, Column: 9")},
              {"delete", parser.("identifier, found: EOF")},
              {"insert", parser.("identifier, found: EOF")},
              {"grant", parser.("a privilege keyword, found: EOF")},
              {"revoke", parser.("a privilege keyword, found: EOF")},
              {"create", parser.("an object type after CREATE, found: EOF")},
              {"select", parser.("an expression, found: EOF")},
              {"explain", parser.("an SQL statement, found: EOF")},
              {"values", parser.("(, found: EOF")},
              {"start", parser.("TRANSACTION, found: EOF")},
              {"truncate", parser.("identifier, found: EOF")},
              {"set", parser.("identifier, found: EOF")},
              {"begin", not_implemented.("Unsupported SQL statement: BEGIN")},
              {"END", not_implemented.("COMMIT AND END not supported")},
              {"vacuum;", not_implemented.("Unsupported SQL statement: VACUUM")},
              {"commit", {400, "Error during planning: Statement not supported: TransactionEnd"}},
              {"show",
               {400,
                "Error during planning: '' is not a variable which can be viewed with 'SHOW'"}}
            ],
            fn {text, expected} ->
              expected = {:error, %{status: elem(expected, 0), body: elem(expected, 1)}}
              assert query.(text) === expected, text
              assert exec.(text) === expected, text
            end
          )
        end
      end
    end
  end

  defp execute_tests_core(client) do
    quote location: :keep do
      describe "execute_sql/3 — contract" do
        test "a statement the engine reads and does not run is its planning error", ctx do
          exec = &unquote(client).execute_sql(ctx.conn, &1, database: ctx.database)

          InfluxElixir.TestSupport.Check.each_case(
            [
              {"COMMIT", "TransactionEnd"},
              {"ROLLBACK", "TransactionEnd"},
              {"START TRANSACTION", "TransactionStart"},
              {"SET x = 1", "SetVariable"},
              {"SET x TO 1", "SetVariable"},
              {"SET datafusion.execution.batch_size = 1", "SetVariable"},
              {"PREPARE x AS select 1", "Prepare"},
              {"DEALLOCATE x", "Deallocate"},
              {"EXEC x", "Execute"},
              {"EXECUTE x(1)", "Execute"}
            ],
            fn {text, kind} ->
              assert exec.(text) ===
                       {:error,
                        %{
                          status: 400,
                          body: "Error during planning: Statement not supported: " <> kind
                        }},
                     text
            end
          )
        end

        # Client.HTTP dropped `params`, so the placeholder was the engine's
        # 400 "No value found for placeholder with name $host" (verified).
        test "binds params as query_sql/3 does", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_exparams")

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},host=a v=1i 1\n#{m},host=b v=2i 2",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 2}]} =
                   unquote(client).execute_sql(ctx.conn, "SELECT v FROM #{m} WHERE host = $host",
                     database: ctx.database,
                     params: %{host: "b"}
                   )
        end

        # Client.HTTP read `database: nil` as the database; Client.Local
        # and the facade's telemetry as no database given.
        test "database: nil is no database given: the connection's default is used", ctx do
          conn = InfluxElixir.ClientContract.with_database(ctx.conn, ctx.database)
          m = InfluxElixir.IntegrationHelper.unique_name("contract_nildb")

          assert {:ok, :written} = unquote(client).write(conn, "#{m} v=1i 1", database: nil)
          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 1}]} =
                   unquote(client).query_sql(conn, "SELECT v FROM #{m}", database: nil)

          assert {:ok, [%{"v" => 1}]} =
                   unquote(client).execute_sql(conn, "SELECT v FROM #{m}", database: nil)
        end
      end
    end
  end

  # UNVERIFIED ON ENTERPRISE: no licensed server was available. The `DELETE
  # FROM` expectations below (a `rows_affected` of 1, then `{:ok, []}`) were
  # read from Core's behaviour and the docs, and only `Client.Local` has run
  # them as the Enterprise profile. The same holds for every other
  # `:v3_enterprise` expectation in this contract that is not also run, and
  # passing, on Core.
  defp execute_tests_enterprise(client) do
    quote location: :keep do
      describe "execute_sql/3 — contract" do
        test "DELETE FROM removes written data", ctx do
          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "contract_del value=1i 1700000000000000000",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, %{"rows_affected" => 1}} =
                   unquote(client).execute_sql(
                     ctx.conn,
                     "DELETE FROM contract_del",
                     database: ctx.database
                   )

          assert {:ok, []} =
                   unquote(client).query_sql(ctx.conn, "SELECT * FROM contract_del",
                     database: ctx.database
                   )
        end

        test "DELETE FROM with WHERE removes the matching points only", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_delw")

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "#{m},host=web01 value=10i 1\n#{m},host=web02 value=20i 2\n" <>
                       "#{m},host=web01 value=30i 3",
                     database: ctx.database,
                     precision: :nanosecond
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).execute_sql(
                   ctx.conn,
                   "DELETE FROM #{m} WHERE host = 'web01'",
                   database: ctx.database
                 ) === {:ok, %{"rows_affected" => 2}}

          assert unquote(client).query_sql(ctx.conn, "SELECT * FROM #{m}", database: ctx.database) ===
                   {:ok,
                    [
                      %{
                        "host" => "web02",
                        "time" => ~U[1970-01-01 00:00:00.000000Z],
                        "value" => 20
                      }
                    ]}
        end

        test "DELETE follows SQL's identifier rules, as SELECT does", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("Contract_Delid")

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     ~s|#{m},Host=a v=1i 1\n#{m},Host=b v=2i 2|,
                     database: ctx.database,
                     precision: :nanosecond
                   )

          InfluxElixir.ClientContract.settle(ctx)

          # A quoted name is exact: `"Host"` is the tag `Host`.
          assert unquote(client).execute_sql(
                   ctx.conn,
                   ~s|DELETE FROM "#{m}" WHERE "Host" = 'a'|,
                   database: ctx.database
                 ) === {:ok, %{"rows_affected" => 1}}

          assert unquote(client).query_sql(ctx.conn, ~s|SELECT * FROM "#{m}"|,
                   database: ctx.database
                 ) ===
                   {:ok, [%{"Host" => "b", "time" => ~U[1970-01-01 00:00:00.000000Z], "v" => 2}]}
        end
      end
    end
  end

  defp reference_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — GROUP BY and ORDER BY references contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_ref")

          lp = """
          #{m},h=b v=2.5,n=4i 1700000000123456789
          #{m},h=a v=3.5,n=6i 1700000090000000000
          #{m},h=a v=1.5,n=2i 1700000000000000000
          """

          {:ok, :written} =
            unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "GROUP BY an alias, a position, or DATE_BIN with a column", ctx do
          select =
            "SELECT DATE_BIN(INTERVAL '1 minute', time) AS bucket, h, COUNT(v) AS c FROM #{ctx.m}"

          InfluxElixir.TestSupport.Check.each_case(
            ["DATE_BIN(INTERVAL '1 minute', time), h", "bucket, h", "1, 2"],
            fn group ->
              {:ok, rows} =
                unquote(client).query_sql(ctx.conn, "#{select} GROUP BY #{group} ORDER BY 1, 2",
                  database: ctx.database
                )

              assert Enum.map(rows, &{&1["h"], &1["c"]}) === [{"a", 1}, {"b", 1}, {"a", 1}], group
            end
          )

          assert {:error,
                  %{
                    status: 400,
                    body:
                      "Error during planning: Cannot find column with position 3 in SELECT " <>
                        "clause. Valid columns: 1 to 2"
                  }} =
                   unquote(client).query_sql(ctx.conn, "SELECT h, v FROM #{ctx.m} GROUP BY 3",
                     database: ctx.database
                   )
        end

        test "a streamed row is the same map as the queried row", ctx do
          sql = "SELECT * FROM #{ctx.m} ORDER BY time"
          {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          streamed =
            ctx.conn
            |> unquote(client).query_sql_stream(sql, database: ctx.database)
            |> Enum.to_list()

          assert streamed === rows
          assert Enum.all?(streamed, &match?(%DateTime{}, &1["time"]))
        end
      end
    end
  end

  defp null_semantics_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — nulls and operators contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_nl")

          lp = """
          #{m},host=b n=-4i,b=false 1700000060000000000
          #{m},host=c,rack=2 v=-3.25,n=7i 1700000120000000000
          #{m},host=a,rack=1 v=1.5,n=2i,s="al%pha",b=true 1700000000000000000
          """

          {:ok, :written} =
            unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "null ordering, three-valued NOT and the DISTINCT null row", ctx do
          assert Enum.map(
                   InfluxElixir.ClientContract.rows(
                     unquote(client),
                     ctx,
                     "SELECT rack FROM #{ctx.m} ORDER BY rack"
                   ),
                   & &1["rack"]
                 ) === [
                   "1",
                   "2",
                   nil
                 ]

          assert Enum.map(
                   InfluxElixir.ClientContract.rows(
                     unquote(client),
                     ctx,
                     "SELECT rack FROM #{ctx.m} ORDER BY rack DESC"
                   ),
                   & &1["rack"]
                 ) === [
                   nil,
                   "2",
                   "1"
                 ]

          assert Enum.map(
                   InfluxElixir.ClientContract.rows(
                     unquote(client),
                     ctx,
                     "SELECT rack FROM #{ctx.m} ORDER BY rack NULLS FIRST"
                   ),
                   & &1["rack"]
                 ) ===
                   [nil, "1", "2"]

          assert Enum.map(
                   InfluxElixir.ClientContract.rows(
                     unquote(client),
                     ctx,
                     "SELECT host FROM #{ctx.m} WHERE NOT (rack = '1') ORDER BY time"
                   ),
                   & &1["host"]
                 ) === ["c"]

          assert InfluxElixir.ClientContract.rows(
                   unquote(client),
                   ctx,
                   "SELECT DISTINCT rack FROM #{ctx.m} ORDER BY rack"
                 ) === [
                   %{"rack" => "1"},
                   %{"rack" => "2"},
                   %{}
                 ]
        end

        test "LIKE escapes, a boolean predicate, % and unary minus", ctx do
          assert [%{"host" => "a"}] =
                   InfluxElixir.ClientContract.rows(
                     unquote(client),
                     ctx,
                     ~s(SELECT host FROM #{ctx.m} WHERE s LIKE 'al\\%%')
                   )

          assert Enum.map(
                   InfluxElixir.ClientContract.rows(
                     unquote(client),
                     ctx,
                     "SELECT host FROM #{ctx.m} WHERE NOT b ORDER BY time"
                   ),
                   & &1["host"]
                 ) ===
                   ["b"]

          assert Enum.map(
                   InfluxElixir.ClientContract.rows(
                     unquote(client),
                     ctx,
                     "SELECT n % 3 AS r FROM #{ctx.m} ORDER BY time"
                   ),
                   & &1["r"]
                 ) === [
                   2,
                   -1,
                   1
                 ]

          assert Enum.map(
                   InfluxElixir.ClientContract.rows(
                     unquote(client),
                     ctx,
                     "SELECT -v AS x FROM #{ctx.m} ORDER BY time"
                   ),
                   & &1["x"]
                 ) === [
                   -1.5,
                   nil,
                   3.25
                 ]

          expected =
            "Error during planning: Cannot create filter with non-boolean " <>
              "predicate '#{ctx.m}.n' returning Int64"

          assert {:error, %{status: 400, body: ^expected}} =
                   unquote(client).query_sql(ctx.conn, "SELECT host FROM #{ctx.m} WHERE n",
                     database: ctx.database
                   )
        end

        test "a selector without a subscript is the time/value struct", ctx do
          assert [%{"sl" => %{"time" => %DateTime{} = struct_time, "value" => -3.25}}] =
                   InfluxElixir.ClientContract.rows(
                     unquote(client),
                     ctx,
                     "SELECT selector_last(v, time) AS sl FROM #{ctx.m}"
                   )

          # The struct's time is the time the subscript form returns for the same query.
          assert [%{"t" => subscript_time}] =
                   InfluxElixir.ClientContract.rows(
                     unquote(client),
                     ctx,
                     "SELECT selector_last(v, time)['time'] AS t FROM #{ctx.m}"
                   )

          assert struct_time === subscript_time
        end
      end
    end
  end

  defp distinct_on_tests(client) do
    quote location: :keep do
      describe "SELECT DISTINCT ON contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_don")

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              Enum.join(
                [
                  "#{m},k=a v=1i,w=10i 1",
                  "#{m},k=a v=2i 2",
                  "#{m},k=b v=3i,w=30i 3",
                  "#{m},k=b v=4i 4",
                  "#{m},k=c v=5i 5",
                  "#{m},k=a,j=x v=6i 6"
                ],
                "\n"
              ),
              database: ctx.database,
              precision: :second
            )

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "keeps the first row per key after ORDER BY: the latest per key", ctx do
          assert {:ok,
                  [
                    %{"k" => "a", "v" => 6, "time" => ~U[1970-01-01 00:00:06.000000Z]},
                    %{"k" => "b", "v" => 4},
                    %{"k" => "c", "v" => 5}
                  ]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k, v, time FROM __M__ ORDER BY k, time DESC"
                   )

          # A null column of the kept row is absent, as on any row.
          assert {:ok, [%{"k" => "a"} = a, _b, _c]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k, w FROM __M__ ORDER BY k, time DESC"
                   )

          refute Map.has_key?(a, "w")
        end

        test "composes with WHERE, LIMIT and OFFSET, which apply after it", ctx do
          assert {:ok, [%{"k" => "a", "v" => 6}, %{"k" => "b", "v" => 4}]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k, v FROM __M__ WHERE v > 1 ORDER BY k, time DESC LIMIT 2"
                   )

          assert {:ok, [%{"k" => "b", "v" => 4}]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k, v FROM __M__ ORDER BY k, v DESC LIMIT 1 OFFSET 1"
                   )
        end

        test "several keys, a key that is not selected, a null key, SELECT *", ctx do
          assert {:ok, [%{"k" => "a", "j" => "x", "v" => 6}, %{"k" => "a", "v" => 2}, _b, _c]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k, j) k, j, v FROM __M__ ORDER BY k, j, time DESC"
                   )

          assert {:ok, [%{"v" => 6}, %{"v" => 4}, %{"v" => 5}]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) v FROM __M__ ORDER BY k, time DESC"
                   )

          assert {:ok, [%{"v" => 5} = null_key, %{"j" => "x", "v" => 6}]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (j) j, v FROM __M__ ORDER BY j NULLS FIRST, time DESC"
                   )

          refute Map.has_key?(null_key, "j")

          assert {:ok, [%{"k" => "c", "v" => 5}, %{"k" => "b"}, %{"k" => "a"}]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) * FROM __M__ ORDER BY k DESC, time DESC"
                   )
        end

        test "the engine's refusals", ctx do
          mismatch =
            "Error during planning: SELECT DISTINCT ON expressions must match initial " <>
              "ORDER BY expressions"

          InfluxElixir.TestSupport.Check.each_case(
            [
              "SELECT DISTINCT ON (k) k, v FROM __M__ ORDER BY time DESC",
              "SELECT DISTINCT ON (k, j) k, j, v FROM __M__ ORDER BY j, k"
            ],
            fn sql ->
              assert {:error, %{status: 400, body: ^mismatch}} =
                       InfluxElixir.ClientContract.don(unquote(client), ctx, sql)
            end
          )

          # The engine's message ends with a space.
          assert {:error,
                  %{
                    status: 405,
                    body:
                      "This feature is not implemented: DISTINCT ON expressions with GROUP BY, " <>
                        "aggregation or window functions are not supported "
                  }} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k, max(v) FROM __M__ GROUP BY k ORDER BY k"
                   )

          assert {:error,
                  %{status: 400, body: "Error during planning: No `ON` expressions provided"}} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON () k FROM __M__"
                   )

          # ORDER BY is resolved against the table, not the select list.
          assert {:error, %{status: 500, body: body}} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k AS kk, v FROM __M__ ORDER BY kk, time DESC"
                   )

          assert body ===
                   InfluxElixir.ClientContract.no_field("kk", ctx.m, ["j", "k", "time", "v", "w"])
        end
      end
    end
  end

  defp param_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — parameterized query contract" do
        test "filters by string parameter", ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_params,host=alpha value=1i 1000000000\ncontract_params,host=beta value=2i 2000000000",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [%{"host" => "alpha", "value" => 1, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_params WHERE host = $host",
                     database: ctx.database,
                     params: %{host: "alpha"}
                   )
        end

        # Jason encodes a Decimal as a JSON string, which the engine compared
        # as text: 500.0 passed `>= 1000.00` ("500.0" >= "1000.00") over HTTP
        # while Client.Local compared numbers (verified). Both now compare
        # numbers.
        test "a Decimal param compares as a number", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_params_dec")

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "#{m} amount=500.0 1000000000\n#{m} amount=5000.0 2000000000\n" <>
                "#{m} amount=12000.0 3000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          InfluxElixir.TestSupport.Check.each_case(
            [
              {"1000.00", [5000.0, 12_000.0]},
              {"-1", [500.0, 5000.0, 12_000.0]},
              {"1.2E+4", [12_000.0]}
            ],
            fn {decimal, expected} ->
              assert {:ok, rows} =
                       unquote(client).query_sql(
                         ctx.conn,
                         "SELECT amount FROM #{m} WHERE amount >= $p ORDER BY amount",
                         database: ctx.database,
                         params: %{p: Decimal.new(decimal)}
                       )

              assert Enum.map(rows, & &1["amount"]) === expected, decimal
            end
          )
        end

        test "accepts params as a keyword list as well as a map", ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_params_kw,host=alpha value=1i 1000000000\ncontract_params_kw,host=beta value=2i 2000000000",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          # Jason cannot encode tuples, so a keyword list used to raise in
          # Client.HTTP while Client.Local accepted it.
          assert {:ok,
                  [%{"host" => "beta", "value" => 2, "time" => ~U[1970-01-01 00:00:02.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_params_kw WHERE host = $host",
                     database: ctx.database,
                     params: [host: "beta"]
                   )
        end

        test "filters by integer parameter", ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_params_int value=100i 1000000000\ncontract_params_int value=200i 2000000000",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"value" => 100, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_params_int WHERE value = $val",
                     database: ctx.database,
                     params: %{val: 100}
                   )
        end
      end
    end
  end

  defp literal_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — WHERE literal typing contract" do
        setup ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_lit,repcode=08338636 amount=500.0 1700000000000000000\n" <>
                       "contract_lit,repcode=12345678 amount=5000.0 1700000100000000000",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          :ok
        end

        test "a zero-padded quoted literal matches a string tag", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_lit WHERE repcode = '08338636'",
              database: ctx.database
            )

          assert [%{"repcode" => "08338636"}] = rows
        end

        test "IN with a bound string param keeps the leading zero", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_lit WHERE repcode IN ($rc)",
              database: ctx.database,
              params: %{rc: "08338636"}
            )

          assert [%{"repcode" => "08338636"}] = rows
        end

        test "a bare numeric literal does not match a string tag", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_lit WHERE repcode = 08338636",
              database: ctx.database
            )

          assert rows === []
        end

        test "a string literal against a float field compares as text", ctx do
          # '500.0' >= '1000.00' lexically — both rows match. Bind a number
          # (or write a bare literal) to get a numeric comparison.
          assert {:ok,
                  [
                    %{
                      "repcode" => "08338636",
                      "amount" => 500.0,
                      "time" => ~U[2023-11-14 22:13:20.000000Z]
                    },
                    %{
                      "repcode" => "12345678",
                      "amount" => 5000.0,
                      "time" => ~U[2023-11-14 22:15:00.000000Z]
                    }
                  ]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_lit WHERE amount >= '1000.00' ORDER BY time",
                     database: ctx.database
                   )

          {:ok, numeric} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_lit WHERE amount >= $min",
              database: ctx.database,
              params: %{min: 1000.0}
            )

          assert [%{"amount" => 5000.0}] = numeric
        end
      end
    end
  end

  defp ordered_agg_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — first_value/last_value aggregate contract" do
        setup ctx do
          base_ts = 1_700_000_000_000_000_000

          Enum.each([{20, 200}, {30, 300}, {10, 100}], fn {val, ts_offset} ->
            ts = base_ts + ts_offset * 1_000_000_000

            {:ok, :written} =
              unquote(client).write(
                ctx.conn,
                "contract_fl value=#{val}i #{ts}",
                database: ctx.database
              )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          :ok
        end

        test "first_value(ORDER BY time) returns the earliest value", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            first_value(value ORDER BY time) AS first_val
          FROM contract_fl
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert rows === [%{"time" => ~U[2023-11-14 22:00:00.000000Z], "first_val" => 10}]
        end

        test "last_value(ORDER BY time) returns the latest value", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            last_value(value ORDER BY time) AS last_val
          FROM contract_fl
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert rows === [%{"time" => ~U[2023-11-14 22:00:00.000000Z], "last_val" => 30}]
        end

        test "first_value(ORDER BY time DESC) returns the latest value", ctx do
          sql = """
          SELECT first_value(value ORDER BY time DESC) AS latest
          FROM contract_fl
          """

          {:ok, [row]} =
            unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          assert row === %{"latest" => 30}
        end

        test "latest value per group (the #13 shape)", ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_latest,symbol=BTC price=1.0 1700000000000000000\n" <>
                       "contract_latest,symbol=BTC price=2.0 1700000100000000000\n" <>
                       "contract_latest,symbol=ETH price=9.0 1700000200000000000\n" <>
                       "contract_latest,symbol=ETH price=8.0 1700000050000000000",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          sql = """
          SELECT symbol, last_value(price ORDER BY time) AS price
          FROM contract_latest
          GROUP BY symbol
          """

          {:ok, rows} =
            unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          assert Enum.sort_by(rows, & &1["symbol"]) === [
                   %{"symbol" => "BTC", "price" => 2.0},
                   %{"symbol" => "ETH", "price" => 9.0}
                 ]
        end
      end
    end
  end

  defp distinct_tests(client) do
    quote location: :keep do
      describe "query_sql/3 — DISTINCT contract" do
        # Every line has its own time: untimed lines of one series in one
        # write are one point, so they could never repeat a value.
        test "SELECT DISTINCT returns each value once", ctx do
          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "contract_dist,host=a value=1i 1000000000\n" <>
                "contract_dist,host=b value=2i 2000000000\n" <>
                "contract_dist,host=a value=3i 3000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"host" => "a"}, %{"host" => "b"}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT DISTINCT host FROM contract_dist ORDER BY host",
                     database: ctx.database
                   )

          assert {:ok, rows} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT host FROM contract_dist ORDER BY host, value",
                     database: ctx.database
                   )

          # Without DISTINCT the repeated value is there.
          assert Enum.map(rows, & &1["host"]) === ["a", "a", "b"]
        end

        test "SELECT DISTINCT over two columns returns unique combinations", ctx do
          lp =
            Enum.join(
              [
                "contract_dist2,provider=p1,symbol=A value=1i 1000000000",
                "contract_dist2,provider=p1,symbol=A value=2i 2000000000",
                "contract_dist2,provider=p2,symbol=B value=3i 3000000000"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [
                    %{"provider" => "p1", "symbol" => "A"},
                    %{"provider" => "p2", "symbol" => "B"}
                  ]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT DISTINCT provider, symbol FROM contract_dist2 ORDER BY provider",
                     database: ctx.database
                   )

          assert {:ok, [%{"n" => 3}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT COUNT(*) AS n FROM contract_dist2",
                     database: ctx.database
                   )
        end
      end
    end
  end
end
