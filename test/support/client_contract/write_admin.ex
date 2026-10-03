defmodule InfluxElixir.ClientContract.WriteAdmin do
  @moduledoc """
  The `:write_admin` part of `InfluxElixir.ClientContract`:
  Health, writes, write rules, line protocol, precision, gzip, escaping,
  databases and their names, timestamp range (all profiles for health and write; the
  InfluxDB 3 profiles for the rest), and the line protocol grammar of both engines
  (`InfluxElixir.ClientContract.LineProtocol`).
  """

  @doc false
  @spec blocks(Macro.t(), atom()) :: [Macro.t()]
  def blocks(client, profile) do
    version = if profile == :v2, do: :v2, else: :v3

    v3 =
      if profile in [:v3_core, :v3_enterprise] do
        [
          write_rule_tests(client),
          duplicate_tests(client),
          precision_tests(client),
          gzip_tests(client),
          escaping_tests(client),
          atomic_write_tests(client),
          db_admin_tests(client),
          database_rule_tests(client),
          identifier_tests(client)
        ]
      else
        []
      end

    [health_tests(client, version), write_tests(client, profile)] ++
      v3 ++
      InfluxElixir.ClientContract.LineProtocol.blocks(client, profile) ++
      [timestamp_range_tests(client, version)]
  end

  defp health_tests(client, version) do
    quote location: :keep do
      describe "health/1" do
        test "reports a passing status in the server's shape", ctx do
          {:ok, health} = unquote(client).health(ctx.conn)

          case unquote(version) do
            # InfluxDB 3's /health is a plain "OK".
            :v3 ->
              assert health === %{"status" => "pass"}

            :v2 ->
              assert %{
                       "name" => "influxdb",
                       "message" => "ready for queries and writes",
                       "status" => "pass",
                       "checks" => [],
                       "version" => version,
                       "commit" => commit
                     } = health

              assert is_binary(version) and is_binary(commit)
          end
        end
      end
    end
  end

  defp write_tests(client, profile) do
    ghost_db_test =
      if profile in [:v3_core, :v3_enterprise] do
        quote location: :keep do
          test "a write to a database that does not exist creates it", ctx do
            InfluxElixir.ClientContract.with_scratch(
              unquote(client),
              ctx,
              :database,
              "ghost_db_contract",
              fn ghost ->
                assert {:ok, :written} =
                         unquote(client).write(ctx.conn, "cpu value=1.0", database: ghost)

                {:ok, dbs} = unquote(client).list_databases(ctx.conn)
                assert Enum.filter(dbs, &(&1["name"] === ghost)) === [%{"name" => ghost}]
              end
            )
          end
        end
      else
        quote location: :keep do
          test "a write to a bucket that does not exist is the engine's 404", ctx do
            name = InfluxElixir.IntegrationHelper.unique_name("contract_nowrite")

            assert {:error, %{status: 404, body: body}} =
                     unquote(client).write(ctx.conn, "m v=1i", database: name)

            assert Jason.decode!(body) === %{
                     "code" => "not found",
                     "message" => ~s|bucket "#{name}" not found|
                   }
          end
        end
      end

    quote location: :keep do
      describe "write/3 — contract" do
        test "accepts valid line protocol and returns {:ok, :written}",
             ctx do
          lp = "cpu,host=server01 value=0.64 1630424257000000000"

          assert {:ok, :written} ==
                   unquote(client).write(
                     ctx.conn,
                     lp,
                     database: ctx.database
                   )
        end

        unquote(ghost_db_test)
      end
    end
  end

  defp db_admin_tests(client) do
    quote location: :keep do
      describe "create_database/3 — contract" do
        test "returns :ok for a new database name", ctx do
          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :database,
            "contract_new_db",
            fn name -> assert :ok == unquote(client).create_database(ctx.conn, name, []) end
          )
        end

        test "is idempotent — creating a duplicate returns :ok", ctx do
          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :database,
            "contract_dup",
            fn name ->
              assert :ok === unquote(client).create_database(ctx.conn, name, [])
              assert :ok === unquote(client).create_database(ctx.conn, name, [])

              {:ok, dbs} = unquote(client).list_databases(ctx.conn)
              assert Enum.filter(dbs, &(&1["name"] === name)) === [%{"name" => name}]
            end
          )
        end
      end

      describe "list_databases/1 — contract" do
        test "lists the test database once, as a name", ctx do
          {:ok, dbs} = unquote(client).list_databases(ctx.conn)
          assert Enum.filter(dbs, &(&1["name"] === ctx.database)) === [%{"name" => ctx.database}]
        end

        test "lists a newly created database once, as a name", ctx do
          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :database,
            "contract_extra_db",
            fn name ->
              :ok = unquote(client).create_database(ctx.conn, name, [])

              {:ok, dbs} = unquote(client).list_databases(ctx.conn)
              assert Enum.filter(dbs, &(&1["name"] === name)) === [%{"name" => name}]
            end
          )
        end
      end

      describe "delete_database/2 — contract" do
        test "returns :ok for an existing database", ctx do
          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :database,
            "contract_to_delete",
            fn name ->
              :ok = unquote(client).create_database(ctx.conn, name, [])

              assert :ok === unquote(client).delete_database(ctx.conn, name)
            end
          )
        end

        test "a deleted database is no longer listed", ctx do
          InfluxElixir.ClientContract.with_scratch(
            unquote(client),
            ctx,
            :database,
            "contract_gone_db",
            fn name ->
              :ok = unquote(client).create_database(ctx.conn, name, [])
              :ok = unquote(client).delete_database(ctx.conn, name)

              {:ok, dbs} = unquote(client).list_databases(ctx.conn)
              assert Enum.filter(dbs, &(&1["name"] === name)) === []
            end
          )
        end

        test "deleting a database that does not exist is the engine's 404", ctx do
          name = InfluxElixir.IntegrationHelper.unique_name("contract_nodb")

          assert {:error, %{status: 404, body: "the requested resource was not found: " <> ^name}} =
                   unquote(client).delete_database(ctx.conn, name)
        end
      end
    end
  end

  defp write_rule_tests(client) do
    quote location: :keep do
      describe "write/3 — schema and partial-write contract" do
        test "an empty payload is 400", ctx do
          assert {:error, %{status: 400, body: "incoming write was empty"}} =
                   unquote(client).write(ctx.conn, "", database: ctx.database)
        end

        test "a payload of only a comment holds no line and is 400 as empty", ctx do
          assert {:error, %{status: 400, body: "incoming write was empty"}} =
                   unquote(client).write(ctx.conn, "# only a comment\n", database: ctx.database)
        end

        unquote(untimed_and_escape_tests(client))
      end
    end
  end

  defp untimed_and_escape_tests(client) do
    quote location: :keep do
      # The engine stamps every untimed line of one write with the same
      # time (verified): lines of one series are one point, fields merged,
      # the last write winning.
      test "untimed lines of one write are one point per series", ctx do
        m = InfluxElixir.IntegrationHelper.unique_name("contract_untimed")

        assert {:ok, :written} =
                 unquote(client).write(
                   ctx.conn,
                   "#{m},k=a v=1i\n#{m},k=a v=2i,w=9i\n#{m},k=b v=3i",
                   database: ctx.database
                 )

        InfluxElixir.ClientContract.settle(ctx)

        assert {:ok,
                [
                  %{"k" => "a", "v" => 2, "w" => 9, "time" => time},
                  %{"k" => "b", "v" => 3, "time" => time}
                ]} =
                 unquote(client).query_sql(
                   ctx.conn,
                   ~s|SELECT k, v, w, time FROM "#{m}" ORDER BY k|,
                   database: ctx.database
                 )

        assert %DateTime{} = time

        # One shared time is one hour bucket: both series fall in it.
        assert {:ok, [%{"total" => 5, "time" => bucket}]} =
                 unquote(client).query_sql(
                   ctx.conn,
                   "SELECT DATE_BIN(INTERVAL '1 hour', time) AS time, SUM(v) AS total " <>
                     ~s|FROM "#{m}" GROUP BY DATE_BIN(INTERVAL '1 hour', time)|,
                   database: ctx.database
                 )

        assert bucket === %{time | minute: 0, second: 0, microsecond: {0, 6}}
      end

      test "a newline inside a quoted string value is part of the value", ctx do
        {:ok, :written} =
          unquote(client).write(ctx.conn, ~s|contract_nl s="a\nb" 1700000000000000000|,
            database: ctx.database
          )

        InfluxElixir.ClientContract.settle(ctx)

        {:ok, [row]} =
          unquote(client).query_sql(ctx.conn, "SELECT s FROM contract_nl", database: ctx.database)

        assert row["s"] === "a\nb"
      end

      test "a tag key ending in a backslash is refused with the engine's partial-write body",
           ctx do
        assert {:error, %{status: 400, body: body}} =
                 unquote(client).write(ctx.conn, ~S"contract_bs,k\\=a v=1i 1",
                   database: ctx.database
                 )

        assert Jason.decode!(body) === %{
                 "error" => "partial write of line protocol occurred",
                 "data" => [
                   %{
                     "error_message" =>
                       "Measurements, tag keys and values, and field keys may not end " <>
                         "with a backslash",
                     "line_number" => 1,
                     "original_line" => ~S"contract_bs,k\\=a v="
                   }
                 ]
               }
      end

      test "a measurement, tag key, tag value or field key ending in a backslash is refused",
           ctx do
        InfluxElixir.TestSupport.Check.each_case(
          [
            ~S"bs\\,t=a v=1i 1",
            ~S"bt,k\\=a v=2i 1",
            ~S"bv,t=a\\ v=1i 1",
            ~S"bf k\\=1i 1"
          ],
          fn lp ->
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, lp, database: ctx.database)

            assert %{"data" => [%{"line_number" => 1, "error_message" => message}]} =
                     Jason.decode!(body)

            assert message ==
                     "Measurements, tag keys and values, and field keys may not end " <>
                       "with a backslash",
                   lp
          end
        )
      end

      test "an escaped backslash at the end of a string value is kept", ctx do
        m = InfluxElixir.IntegrationHelper.unique_name("contract_bsok")

        {:ok, :written} =
          unquote(client).write(ctx.conn, ~s(#{m} s="x\\\\",v=1i 1700000000000000000),
            database: ctx.database
          )

        InfluxElixir.ClientContract.settle(ctx)

        assert {:ok, [%{"s" => "x\\", "v" => 1}]} =
                 unquote(client).query_sql(ctx.conn, "SELECT s, v FROM #{m}",
                   database: ctx.database
                 )
      end
    end
  end

  defp duplicate_tests(client) do
    quote location: :keep do
      describe "write/3 — duplicate point contract" do
        test "a point rewritten at the same tags and time merges, the later write winning",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_dup")

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},h=x v=1i,w=1i 1700000000000000000",
              database: ctx.database
            )

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "#{m},h=x v=2i 1700000000000000000\n#{m},h=y v=3i 1700000000000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(ctx.conn, "SELECT h, v, w FROM #{m} ORDER BY h",
              database: ctx.database
            )

          assert rows === [%{"h" => "x", "v" => 2, "w" => 1}, %{"h" => "y", "v" => 3}]
        end

        test "a different tag value is another point; the same series at another time too",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_dup2")
          t = "1700000000000000000"

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},h=x v=1i #{t}\n#{m},h=y v=2i #{t}",
              database: ctx.database
            )

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},h=x v=3i 1700000000000000001",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).query_sql(ctx.conn, "SELECT h, v FROM #{m} ORDER BY v",
                   database: ctx.database
                 ) ===
                   {:ok,
                    [%{"h" => "x", "v" => 1}, %{"h" => "y", "v" => 2}, %{"h" => "x", "v" => 3}]}
        end
      end
    end
  end

  defp atomic_write_tests(client) do
    quote location: :keep do
      describe "write/3 — accept_partial and no_sync contract" do
        test "accept_partial: false rejects the payload at its first bad line", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_atomic")

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, "#{m} v=1i 1\n#{m} v=2.0 2",
                     database: ctx.database,
                     accept_partial: false
                   )

          # `original_line` is the engine's rendering of the line (2.0 is 2),
          # cut to 20 bytes.
          assert Jason.decode!(body) === %{
                   "error" => "line protocol parsing error",
                   "data" => %{
                     "error_message" =>
                       "invalid column type for column 'v', expected " <>
                         "iox::column_type::field::integer, got iox::column_type::field::float",
                     "line_number" => 2,
                     "original_line" => binary_part("#{m} v=2 2", 0, 20)
                   }
                 }

          InfluxElixir.ClientContract.settle(ctx)

          expected = "Error during planning: table 'public.iox.#{m}' not found"

          assert {:error, %{status: 400, body: ^expected}} =
                   unquote(client).query_sql(ctx.conn, "SELECT * FROM #{m}",
                     database: ctx.database
                   )
        end

        test "no_sync: true and a clean atomic payload are accepted", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_nosync")

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "#{m} v=1i 1\n#{m} v=2i 2",
                     database: ctx.database,
                     accept_partial: false,
                     no_sync: true
                   )
        end
      end
    end
  end

  defp database_rule_tests(client) do
    quote location: :keep do
      describe "database rules contract" do
        test "a database/retention-policy name is written, queried and dropped", ctx do
          name = "#{InfluxElixir.IntegrationHelper.unique_name("contract_rp")}/autogen"

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "enc v=1i 1",
                     database: name,
                     precision: :second
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 1}]} =
                   unquote(client).query_sql(ctx.conn, "SELECT v FROM enc", database: name)

          assert :ok = unquote(client).delete_database(ctx.conn, name)
        end

        # retention: is a duration string; the double used to accept any
        # value, so `retention: 3600` (a v2 bucket's seconds) passed in tests
        # and was the engine's 400 in production.
        test "retention: takes the engine's duration strings and refuses the rest", ctx do
          InfluxElixir.TestSupport.Check.each_case(
            ["30d", "1h 30m", "1.5h", "2 weeks", "1M", "0"],
            fn retention ->
              name = InfluxElixir.IntegrationHelper.unique_name("contract_ret")
              assert :ok = unquote(client).create_database(ctx.conn, name, retention: retention)
              assert :ok = unquote(client).delete_database(ctx.conn, name)
            end
          )

          # The position is the byte before the closing brace of the body
          # {"db":<name>,"retention_period":<retention>}, so it follows the
          # length of the name.
          InfluxElixir.TestSupport.Check.each_case(
            [
              {3600, "invalid type: integer `3600`"},
              {"1H", ~s|invalid value: string "1H"|},
              {"1", ~s|invalid value: string "1"|},
              {"-1h", ~s|invalid value: string "-1h"|}
            ],
            fn {retention, what} ->
              name = InfluxElixir.IntegrationHelper.unique_name("contract_ret")
              body = ~s|{"db":"#{name}","retention_period":#{Jason.encode!(retention)}}|
              column = byte_size(body) - 1

              expected =
                "serde json error: #{what}, expected a duration at line 1 column #{column}"

              assert {:error, %{status: 400, body: ^expected}} =
                       unquote(client).create_database(ctx.conn, name, retention: retention),
                     inspect(retention)
            end
          )
        end

        test "the engine's _internal is listed and cannot be dropped", ctx do
          {:ok, dbs} = unquote(client).list_databases(ctx.conn)
          assert "_internal" in Enum.map(dbs, & &1["name"])

          assert {:ok, rows} = unquote(client).query_influxql(ctx.conn, "SHOW DATABASES")
          assert %{"iox::database" => "_internal", "deleted" => false} in rows

          assert {:error, %{status: 500, body: "cannot delete internal db"}} =
                   unquote(client).delete_database(ctx.conn, "_internal")
        end
      end
    end
  end

  defp identifier_tests(client) do
    quote location: :keep do
      describe "SQL identifier contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("Contract_Ident")

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},Host=h1,k=a Val=1i,v=2i 1",
              database: ctx.database,
              precision: :second
            )

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "an unquoted identifier is folded to lower case, a quoted one is exact", ctx do
          assert {:ok, [%{"k" => "a", "Host" => "h1", "Val" => 1}]} =
                   InfluxElixir.ClientContract.ident(
                     unquote(client),
                     ctx,
                     ~s|SELECT K, "Host", "Val" FROM __M__|
                   )

          InfluxElixir.TestSupport.Check.each_case(
            ["SELECT Host FROM __M__", ~s|SELECT * FROM __M__ WHERE Host = 'h1'|],
            fn sql ->
              assert {:error, %{status: 500, body: body}} =
                       InfluxElixir.ClientContract.ident(unquote(client), ctx, sql)

              assert body ===
                       InfluxElixir.ClientContract.no_field("host", ctx.m, [
                         "Host",
                         "Val",
                         "k",
                         "time",
                         "v"
                       ])
            end
          )

          assert {:ok, [%{"Host" => "h1"}]} =
                   InfluxElixir.ClientContract.ident(
                     unquote(client),
                     ctx,
                     ~s|SELECT * FROM __M__ WHERE "Host" = 'h1' ORDER BY "Val"|
                   )
        end

        test "aliases fold too unless quoted", ctx do
          assert {:ok, [%{"v" => 2, "V2" => 2, "Mixed Case" => 1, "avg_v" => 2.0}]} =
                   InfluxElixir.ClientContract.ident(
                     unquote(client),
                     ctx,
                     ~s|SELECT v AS V, v AS "V2", "Val" AS "Mixed Case", v * 1.0 AS Avg_V FROM __M__|
                   )
        end

        test "a double-quoted operand is a column, not a string", ctx do
          assert {:error, %{status: 500, body: body}} =
                   InfluxElixir.ClientContract.ident(
                     unquote(client),
                     ctx,
                     ~s|SELECT * FROM __M__ WHERE k = "hello"|
                   )

          assert body ===
                   InfluxElixir.ClientContract.no_field("hello", ctx.m, [
                     "Host",
                     "Val",
                     "k",
                     "time",
                     "v"
                   ])

          assert {:ok, [_row]} =
                   InfluxElixir.ClientContract.ident(
                     unquote(client),
                     ctx,
                     ~s|SELECT * FROM __M__ WHERE k = "k"|
                   )
        end
      end
    end
  end

  # A timestamp must fit in a signed 64-bit count of nanoseconds once scaled
  # by the precision; each version refuses the rest in its own words.
  defp timestamp_range_tests(client, version) do
    quote location: :keep do
      describe "write/3 — timestamp range contract" do
        test "the largest timestamp per precision is stored; one more is refused", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_ts")
          v2? = unquote(version) == :v2

          InfluxElixir.TestSupport.Check.each_case(
            [
              {9_223_372_036, 9_223_372_037, :second, "Second"},
              {9_223_372_036_854, 9_223_372_036_855, :millisecond, "Millisecond"},
              {9_223_372_036_854_775, 9_223_372_036_854_776, :microsecond, "Microsecond"}
            ],
            fn {ok, over, precision, unit} ->
              assert {:ok, :written} =
                       unquote(client).write(ctx.conn, "#{m} v=1i #{ok}",
                         database: ctx.database,
                         precision: precision
                       )

              assert {:error, %{status: 400, body: body}} =
                       unquote(client).write(ctx.conn, "#{m} v=1i #{over}",
                         database: ctx.database,
                         precision: precision
                       )

              if v2? do
                assert %{"message" => message} = Jason.decode!(body)

                assert message ==
                         "unable to parse '#{m} v=1i #{over}': time outside range " <>
                           "-9223372036854775806 - 9223372036854775806"
              else
                assert %{"data" => [%{"error_message" => message}]} = Jason.decode!(body)
                assert message === "timestamp, #{over}, out of range for precision: #{unit}"
              end
            end
          )
        end
      end
    end
  end

  defp precision_tests(client) do
    quote location: :keep do
      describe "write/3 — timestamp precision contract" do
        test "second precision writes and queries correctly", ctx do
          # Write with second precision — InfluxDB converts to nanoseconds
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_prec_s value=1i 1700000000",
                     database: ctx.database,
                     precision: :second
                   )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_prec_s",
              database: ctx.database
            )

          # 1700000000 s → the same instant on every client and transport
          assert [%{"time" => ~U[2023-11-14 22:13:20.000000Z]}] = rows
        end

        test "millisecond precision writes correctly", ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_prec_ms value=1i 1700000000000",
                     database: ctx.database,
                     precision: :millisecond
                   )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_prec_ms",
              database: ctx.database
            )

          assert [%{"time" => ~U[2023-11-14 22:13:20.000000Z]}] = rows
        end

        test "microsecond precision writes correctly", ctx do
          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_prec_us value=1i 1700000000000000",
                     database: ctx.database,
                     precision: :microsecond
                   )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_prec_us",
              database: ctx.database
            )

          assert [%{"time" => ~U[2023-11-14 22:13:20.000000Z]}] = rows
        end

        test "every spelling of a unit, as an atom or a string, is the same unit", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_prec2")

          spellings = [
            {:ns, 1_000_000_000},
            {"n", 1_000_000_000},
            {"nanosecond", 1_000_000_000},
            {:us, 1_000_000},
            {:u, 1_000_000},
            {"microsecond", 1_000_000},
            {:ms, 1_000},
            {"millisecond", 1_000},
            {:s, 1},
            {"second", 1}
          ]

          InfluxElixir.TestSupport.Check.each_case(Enum.with_index(spellings), fn
            {{precision, ts}, i} ->
              assert {:ok, :written} =
                       unquote(client).write(ctx.conn, "#{m},s=#{i} value=1i #{ts}",
                         database: ctx.database,
                         precision: precision
                       )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).query_sql(
                   ctx.conn,
                   "SELECT COUNT(value) AS n FROM #{m} WHERE time = '1970-01-01T00:00:01'",
                   database: ctx.database
                 ) === {:ok, [%{"n" => 10}]}
        end

        test "auto reads a number below 5e9 as seconds, then milliseconds, microseconds, ns",
             ctx do
          InfluxElixir.TestSupport.Check.each_case(
            [
              {4_999_999_999, ~U[2128-06-11 08:53:19.000000Z]},
              {5_000_000_000, ~U[1970-02-27 20:53:20.000000Z]},
              {4_999_999_999_999, ~U[2128-06-11 08:53:19.999000Z]},
              {5_000_000_000_000, ~U[1970-02-27 20:53:20.000000Z]},
              {4_999_999_999_999_999, ~U[2128-06-11 08:53:19.999999Z]},
              {5_000_000_000_000_000, ~U[1970-02-27 20:53:20.000000Z]},
              {-9_999_999_999, ~U[1969-09-07 06:13:20.001000Z]},
              {1_700_000_000, ~U[2023-11-14 22:13:20.000000Z]}
            ],
            fn {ts, expected} ->
              m = InfluxElixir.IntegrationHelper.unique_name("contract_auto")

              assert {:ok, :written} =
                       unquote(client).write(ctx.conn, "#{m} value=1i #{ts}",
                         database: ctx.database,
                         precision: :auto
                       )

              InfluxElixir.ClientContract.settle(ctx)

              assert unquote(client).query_sql(ctx.conn, "SELECT time FROM #{m}",
                       database: ctx.database
                     ) === {:ok, [%{"time" => expected}]},
                     inspect(ts)
            end
          )
        end

        test "an unknown precision is the engine's 400, case-sensitively", ctx do
          InfluxElixir.TestSupport.Check.each_case([:bogus, "NS", "nanoseconds"], fn precision ->
            expected = InfluxElixir.ClientContract.bad_precision("#{precision}")

            assert {:error, %{status: 400, body: ^expected}} =
                     unquote(client).write(ctx.conn, "bad_prec value=1i 1",
                       database: ctx.database,
                       precision: precision
                     )
          end)
        end
      end
    end
  end

  defp gzip_tests(client) do
    quote location: :keep do
      describe "write/3 — gzip contract" do
        test "gzip-compressed payload is accepted and queryable", ctx do
          lp = "contract_gz value=42i 1700000000000000000"
          compressed = :zlib.gzip(lp)

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              compressed,
              database: ctx.database,
              gzip: true
            )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_gz",
              database: ctx.database
            )

          assert [%{"value" => 42}] = rows
        end

        # `gzip: true` is the Content-Encoding header: it, not the bytes,
        # decides. Each body below is the engine's own reason (verified).
        test "a body gzip: true cannot decompress is the engine's 400, and nothing is stored",
             ctx do
          db = InfluxElixir.IntegrationHelper.unique_name("contract_gzbad")
          good = :zlib.gzip("contract_gzbad v=1i 1")
          size = byte_size(good)
          <<body::binary-size(size - 8), _crc::binary-size(4), isize::binary-size(4)>> = good

          cases = [
            {"x", "unexpected end of file"},
            {"contract_gzbad v=1i 1", "invalid gzip header"},
            {binary_part(good, 0, size - 4), "unexpected end of file"},
            {<<0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3>> <> "garbagegarbage",
             "corrupt deflate stream"},
            {body <> <<0, 0, 0, 0>> <> isize,
             "corrupt gzip stream does not have a matching checksum"}
          ]

          InfluxElixir.TestSupport.Check.each_case(cases, fn {payload, reason} ->
            assert {:error, %{status: 400, body: "error decoding gzip stream: " <> ^reason}} =
                     unquote(client).write(ctx.conn, payload, database: db, gzip: true)
          end)

          # The body is read before the database is created.
          assert {:ok, databases} = unquote(client).list_databases(ctx.conn)
          refute Enum.any?(databases, &(&1["name"] == db))
        end

        test "the request's parameters are read before its body", ctx do
          expected = InfluxElixir.ClientContract.bad_precision("zz")

          assert {:error, %{status: 400, body: ^expected}} =
                   unquote(client).write(ctx.conn, "x",
                     database: ctx.database,
                     gzip: true,
                     precision: "zz"
                   )
        end

        test "concatenated gzip members are one body", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_gzcat")
          payload = :zlib.gzip("#{m} v=1i 1\n") <> :zlib.gzip("#{m} v=2i 2")

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, payload, database: ctx.database, gzip: true)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 1}, %{"v" => 2}]} =
                   unquote(client).query_sql(ctx.conn, "SELECT v FROM #{m} ORDER BY time",
                     database: ctx.database
                   )
        end

        test "gzip bytes without gzip: true are not UTF-8 to the engine", ctx do
          # 0x1F is ASCII; 0x8B cannot start a character.
          assert {:error,
                  %{
                    status: 400,
                    body:
                      "body content is not valid utf8: invalid utf-8 sequence of 1 bytes " <>
                        "from index 1"
                  }} =
                   unquote(client).write(ctx.conn, :zlib.gzip("m v=1i 1"), database: ctx.database)
        end

        test "a body that is not UTF-8 names the first bad byte as the engine does", ctx do
          cases = [
            {"u v=1i \xFF", "invalid utf-8 sequence of 1 bytes from index 7"},
            {"u v=1i 1\xE2\x82", "incomplete utf-8 byte sequence from index 8"},
            {"u v=\xF0\x9F\x98x", "invalid utf-8 sequence of 3 bytes from index 4"},
            {"u v=\xE0\x80\x80", "invalid utf-8 sequence of 1 bytes from index 4"},
            {"u v=\xED\xA0\x80", "invalid utf-8 sequence of 1 bytes from index 4"}
          ]

          InfluxElixir.TestSupport.Check.each_case(cases, fn {payload, reason} ->
            assert {:error, %{status: 400, body: "body content is not valid utf8: " <> ^reason}} =
                     unquote(client).write(ctx.conn, payload, database: ctx.database)
          end)
        end
      end
    end
  end

  defp escaping_tests(client) do
    quote location: :keep do
      describe "write/3 — line protocol escaping contract" do
        test "escaped space in measurement name round-trips", ctx do
          lp = "my\\ measurement value=1i 1700000000000000000"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              ~s(SELECT * FROM "my measurement"),
              database: ctx.database
            )

          assert rows === [%{"value" => 1, "time" => ~U[2023-11-14 22:13:20.000000Z]}]
        end

        test "tag with special characters round-trips", ctx do
          # Escaped comma in tag value
          lp = "contract_esc,region=us\\,east value=1i 1700000000000000000"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_esc",
              database: ctx.database
            )

          assert rows === [
                   %{
                     "region" => "us,east",
                     "value" => 1,
                     "time" => ~U[2023-11-14 22:13:20.000000Z]
                   }
                 ]
        end

        test "an escaped equals sign is part of a tag key or a tag value", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_escq")
          lp = "#{m},a\\=b=x,k=v\\=1 f=1i 1700000000000000000"

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).query_sql(ctx.conn, ~s|SELECT * FROM "#{m}"|,
                   database: ctx.database
                 ) ===
                   {:ok,
                    [
                      %{
                        "a=b" => "x",
                        "k" => "v=1",
                        "f" => 1,
                        "time" => ~U[2023-11-14 22:13:20.000000Z]
                      }
                    ]}
        end

        test "an escaped comma is part of a measurement name", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_escc")

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m}\\,x field=1i", database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          assert unquote(client).query_sql(ctx.conn, ~s|SELECT field FROM "#{m},x"|,
                   database: ctx.database
                 ) === {:ok, [%{"field" => 1}]}
        end

        test "an escaped backslash in a tag value is stored as one backslash", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_escb")

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},host=web\\\\01 value=1i",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"host" => "web\\01"}]} =
                   unquote(client).query_sql(ctx.conn, "SELECT host FROM #{m}",
                     database: ctx.database
                   )
        end

        test "string field with escaped quotes round-trips", ctx do
          lp = ~s(contract_esc_str label="say \\"hi\\"" 1700000000000000000)

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_esc_str",
              database: ctx.database
            )

          assert rows === [%{"label" => ~s(say "hi"), "time" => ~U[2023-11-14 22:13:20.000000Z]}]
        end
      end
    end
  end
end
