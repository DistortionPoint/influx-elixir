defmodule InfluxElixir.Contract.Retention do
  @moduledoc """
  Database-retention contract tests, run against `InfluxElixir.Client.Local` and
  against a real InfluxDB 3: a database created with `retention:` accepts a
  point of any age and hides the expired ones from every read, a 10-minute
  chunk at a time, and `SHOW RETENTION POLICIES` prints the period. Every
  expectation here was read from a Core with `curl` first.

      use InfluxElixir.Contract.Retention, client: InfluxElixir.Client.Local, profile: :v3_core

  The `setup` callback must return `conn` and `database`, as for
  the shared contract. A server holds only a few databases, so a test does not
  create one beside its own: it drops the database it was given and creates it
  again with the retention under test (the module's `on_exit` drops that one).

  Every point is an hour or more from the cut-off, so the server's clock
  cannot move one across it, except in the chunk tests, which put the cut-off
  in the middle of a chunk (see `straddle/0`) and keep two minutes either side.
  """

  @hour 3_600_000_000_000
  @second 1_000_000_000

  # `retention:` as written, and what `SHOW RETENTION POLICIES` prints.
  @durations [
    {"1h", "1h0m0s"},
    {"90m", "1h30m0s"},
    {"1d", "24h0m0s"},
    {"7d", "168h0m0s"},
    {"1.5h", "1h30m0s"},
    {"30s", "30s"},
    {"1M", "730h33m36s"},
    {"1y", "8766h0m0s"},
    {"1w", "168h0m0s"},
    {"1h30m", "1h30m0s"},
    {"1h 30m", "1h30m0s"},
    {"61m", "1h1m0s"},
    {"45m", "45m0s"},
    {"10min", "10m0s"},
    {"2y", "17532h0m0s"},
    {"3months", "2191h40m48s"},
    {"1500ms", "1s"},
    {"1m500ms", "1m0s"},
    {"100ms", "0s"},
    {"0", "0s"},
    {"0h", "0s"}
  ]

  # `retention:` texts the engine refuses.
  @refused ["", "1", "h", "1H", "1mo", "-1h", "1.h", "1 hour ago", "0.5", "zz"]

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    _profile = Keyword.fetch!(opts, :profile)

    tests = [
      expiry_tests(client),
      read_tests(client),
      schema_tests(client),
      chunk_tests(client),
      zero_tests(client),
      refusal_tests(client),
      policy_tests(client)
    ]

    quote location: :keep do
      alias InfluxElixir.ClientContract
      alias InfluxElixir.Contract.Retention

      (unquote_splicing(tests))
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc false
  # The test's database, dropped and created again with `retention`.
  @spec fresh(module(), map(), binary() | nil) :: :ok
  def fresh(client, ctx, retention) do
    :ok = client.delete_database(ctx.conn, ctx.database)
    :ok = client.create_database(ctx.conn, ctx.database, retention: retention)
  end

  @doc false
  @spec now_ns() :: integer()
  def now_ns, do: System.os_time(:nanosecond)

  @doc false
  # `hours` hours (a number) before now, in nanoseconds.
  @spec ago(number()) :: integer()
  def ago(hours), do: now_ns() - round(hours * @hour)

  @doc false
  # The start of a chunk (a multiple of 600 s since the epoch) between 100 and
  # 110 minutes ago, and the retention in seconds that puts the cut-off in its
  # middle: a point 120 s before the middle is expired, one 120 s after is not,
  # and both are in this chunk.
  @spec straddle() :: %{start: integer(), retention: binary()}
  def straddle do
    now = System.os_time(:second)
    start = div(now, 600) * 600 - 6000
    %{start: start, retention: "#{now - (start + 300)}s"}
  end

  @doc false
  # A line of measurement `m` with field `v` at `seconds` since the epoch.
  @spec line(binary(), binary(), integer()) :: binary()
  def line(m, v, seconds), do: "#{m} #{v} #{seconds * @second}"

  @doc false
  @spec rows(module(), map(), binary()) :: term()
  def rows(client, ctx, sql), do: client.query_sql(ctx.conn, sql, database: ctx.database)

  @doc false
  @spec influxql(module(), map(), binary()) :: term()
  def influxql(client, ctx, statement),
    do: client.query_influxql(ctx.conn, statement, database: ctx.database)

  @doc false
  @spec policies(binary(), binary()) :: [map()]
  def policies(database, duration),
    do: [%{"iox::database" => database, "name" => "autogen", "duration" => duration}]

  @doc false
  @spec durations() :: [{binary(), binary()}]
  def durations, do: @durations

  @doc false
  @spec refused() :: [binary()]
  def refused, do: @refused

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  defp expiry_tests(client) do
    quote location: :keep do
      describe "retention — a write is accepted, a read hides what expired" do
        test "an expired point is written and hidden from SQL", ctx do
          Retention.fresh(unquote(client), ctx, "1h")

          assert {:ok, :written} ===
                   unquote(client).write(
                     ctx.conn,
                     "m v=1i #{Retention.ago(2)}\nm v=2i #{Retention.ago(0.01)}",
                     database: ctx.database
                   )

          ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 2}]} ===
                   Retention.rows(unquote(client), ctx, "SELECT v FROM m ORDER BY time")

          assert {:ok, [%{"count(*)" => 1}]} ===
                   Retention.rows(unquote(client), ctx, "SELECT count(*) FROM m")
        end

        test "accept_partial does not make an expired point an error", ctx do
          Retention.fresh(unquote(client), ctx, "1h")

          for {accept, m} <- [{false, "a"}, {true, "b"}] do
            assert {:ok, :written} ===
                     unquote(client).write(ctx.conn, "#{m} v=1i #{Retention.ago(3)}",
                       database: ctx.database,
                       accept_partial: accept
                     )
          end

          ClientContract.settle(ctx)
          assert {:ok, []} === Retention.rows(unquote(client), ctx, "SELECT v FROM a")
          assert {:ok, []} === Retention.rows(unquote(client), ctx, "SELECT v FROM b")
        end

        test "the cut-off is now minus the retention, hours either side", ctx do
          Retention.fresh(unquote(client), ctx, "2h")

          lines =
            for {m, v, hours} <- [{"old", 1, 2.5}, {"inside", 2, 1.5}, {"fresh", 3, 0}] do
              "#{m} v=#{v}i #{Retention.ago(hours)}"
            end

          future = "future v=4i #{Retention.ago(-1)}"

          assert {:ok, :written} ===
                   unquote(client).write(ctx.conn, Enum.join(lines ++ [future], "\n"),
                     database: ctx.database
                   )

          ClientContract.settle(ctx)

          for {m, expected} <- [
                {"old", []},
                {"inside", [%{"v" => 2}]},
                {"fresh", [%{"v" => 3}]},
                {"future", [%{"v" => 4}]}
              ] do
            assert {:ok, expected} === Retention.rows(unquote(client), ctx, "SELECT v FROM #{m}")
          end
        end
      end
    end
  end

  defp read_tests(client) do
    quote location: :keep do
      describe "retention — InfluxQL and SHOW TAG VALUES read as SQL does" do
        test "InfluxQL hides what SQL hides", ctx do
          Retention.fresh(unquote(client), ctx, "1h")

          assert {:ok, :written} ===
                   unquote(client).write(
                     ctx.conn,
                     "m v=1i #{Retention.ago(2)}\nm v=2i #{Retention.ago(0.01)}",
                     database: ctx.database
                   )

          ClientContract.settle(ctx)

          assert {:ok, rows} = Retention.influxql(unquote(client), ctx, "SELECT v FROM m")
          assert Enum.map(rows, & &1["v"]) === [2]
        end

        test "SHOW TAG VALUES lists only the values a read still sees", ctx do
          Retention.fresh(unquote(client), ctx, "1h")

          assert {:ok, :written} ===
                   unquote(client).write(
                     ctx.conn,
                     "m,host=h1 v=1i #{Retention.ago(2)}\nm,host=h2 v=2i #{Retention.ago(0.01)}",
                     database: ctx.database
                   )

          ClientContract.settle(ctx)

          assert {:ok,
                  [
                    %{"iox::measurement" => "m", "key" => "host", "value" => "h2"}
                  ]} ===
                   Retention.influxql(unquote(client), ctx, "SHOW TAG VALUES WITH KEY = host")
        end
      end
    end
  end

  defp schema_tests(client) do
    quote location: :keep do
      describe "retention — expiry leaves the schema" do
        test "a table of expired points keeps its schema and answers no rows", ctx do
          Retention.fresh(unquote(client), ctx, "1h")

          assert {:ok, :written} ===
                   unquote(client).write(
                     ctx.conn,
                     "old,host=a,extra=z f=1i,g=2i #{Retention.ago(3)}\n" <>
                       "live v=1i #{Retention.ago(0.01)}",
                     database: ctx.database
                   )

          ClientContract.settle(ctx)

          assert {:ok, []} === Retention.rows(unquote(client), ctx, "SELECT * FROM old")

          assert {:ok, [%{"count(*)" => 0}]} ===
                   Retention.rows(unquote(client), ctx, "SELECT count(*) FROM old")

          assert {:ok, [%{"table_name" => "live"}, %{"table_name" => "old"}]} ===
                   Retention.rows(
                     unquote(client),
                     ctx,
                     "SELECT table_name FROM information_schema.tables " <>
                       "WHERE table_schema = 'iox' ORDER BY table_name"
                   )

          assert {:ok,
                  [
                    %{"table_name" => "old", "column_name" => "extra"},
                    %{"table_name" => "old", "column_name" => "f"},
                    %{"table_name" => "old", "column_name" => "g"},
                    %{"table_name" => "old", "column_name" => "host"},
                    %{"table_name" => "old", "column_name" => "time"}
                  ]} ===
                   Retention.rows(
                     unquote(client),
                     ctx,
                     "SELECT table_name, column_name FROM information_schema.columns " <>
                       "WHERE table_schema = 'iox' AND table_name = 'old' ORDER BY column_name"
                   )

          assert {:ok,
                  [
                    %{"iox::measurement" => "measurements", "name" => "live"},
                    %{"iox::measurement" => "measurements", "name" => "old"}
                  ]} ===
                   Retention.influxql(unquote(client), ctx, "SHOW MEASUREMENTS")

          assert {:ok, []} ===
                   Retention.influxql(
                     unquote(client),
                     ctx,
                     "SHOW TAG VALUES FROM old WITH KEY = host"
                   )
        end

        test "a database without a retention shows every point", ctx do
          Retention.fresh(unquote(client), ctx, nil)

          assert {:ok, :written} ===
                   unquote(client).write(
                     ctx.conn,
                     "m v=1i 1000000000000000000\nm v=2i #{Retention.ago(24 * 365)}\n" <>
                       "m v=3i #{Retention.ago(0.01)}",
                     database: ctx.database
                   )

          ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 1}, %{"v" => 2}, %{"v" => 3}]} ===
                   Retention.rows(unquote(client), ctx, "SELECT v FROM m ORDER BY time")
        end
      end
    end
  end

  defp chunk_tests(client) do
    quote location: :keep do
      describe "retention — a chunk of 10 minutes expires, not a point" do
        test "an expired point lives as long as the newest point of its chunk", ctx do
          %{start: start, retention: retention} = Retention.straddle()
          Retention.fresh(unquote(client), ctx, retention)

          # `same`: both points in the chunk, one 120 s before the cut-off and
          # one 120 s after. `apart`: the expired point has a chunk to itself.
          lines = [
            Retention.line("same", "v=1i", start + 180),
            Retention.line("same", "v=2i", start + 420),
            Retention.line("apart", "v=1i", start - 300),
            Retention.line("apart", "v=2i", start + 420)
          ]

          assert {:ok, :written} ===
                   unquote(client).write(ctx.conn, Enum.join(lines, "\n"), database: ctx.database)

          ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 1}, %{"v" => 2}]} ===
                   Retention.rows(unquote(client), ctx, "SELECT v FROM same ORDER BY time")

          assert {:ok, [%{"v" => 2}]} ===
                   Retention.rows(unquote(client), ctx, "SELECT v FROM apart ORDER BY time")
        end

        test "a chunk of expired points only is hidden whole", ctx do
          %{start: start, retention: retention} = Retention.straddle()
          Retention.fresh(unquote(client), ctx, retention)

          lines = [
            Retention.line("gone", "v=1i", start + 20),
            Retention.line("gone", "v=2i", start + 180)
          ]

          assert {:ok, :written} ===
                   unquote(client).write(ctx.conn, Enum.join(lines, "\n"), database: ctx.database)

          ClientContract.settle(ctx)
          assert {:ok, []} === Retention.rows(unquote(client), ctx, "SELECT v FROM gone")
        end
      end
    end
  end

  defp zero_tests(client) do
    quote location: :keep do
      describe "retention — zero is a period, not none" do
        test "0, 0h and under a second hide every point before now", ctx do
          InfluxElixir.TestSupport.Check.check_cases(["0", "0h", "100ms"], fn retention ->
            Retention.fresh(unquote(client), ctx, retention)

            lines = "m v=1i #{Retention.ago(1)}\nm v=2i #{Retention.ago(-1)}"

            written = unquote(client).write(ctx.conn, lines, database: ctx.database)
            ClientContract.settle(ctx)
            rows = Retention.rows(unquote(client), ctx, "SELECT v FROM m ORDER BY time")

            if {written, rows} === {{:ok, :written}, {:ok, [%{"v" => 2}]}},
              do: :ok,
              else: {:mismatch, %{written: written, rows: rows}}
          end)
        end
      end
    end
  end

  defp refusal_tests(client) do
    quote location: :keep do
      describe "retention — create_database" do
        test "a retention the engine refuses is a 400 and creates nothing", ctx do
          :ok = unquote(client).delete_database(ctx.conn, ctx.database)

          InfluxElixir.TestSupport.Check.check_cases(Retention.refused(), fn text ->
            case unquote(client).create_database(ctx.conn, ctx.database, retention: text) do
              {:error, %{status: 400}} ->
                :ok

              other ->
                _dropped = unquote(client).delete_database(ctx.conn, ctx.database)
                {:mismatch, other}
            end
          end)

          assert {:ok, names} = unquote(client).list_databases(ctx.conn)
          assert Enum.filter(names, &(&1["name"] === ctx.database)) === []

          # The module's `on_exit` drops the database it was given.
          :ok = unquote(client).create_database(ctx.conn, ctx.database)
        end

        test "an expired point that is rewritten stays hidden and a live one is merged", ctx do
          Retention.fresh(unquote(client), ctx, "1h")
          now = Retention.now_ns()

          for line <- [
                "m v=1i #{Retention.ago(3)}",
                "m,host=a v=2i #{now}",
                "m,host=a w=3i #{now}"
              ] do
            assert {:ok, :written} ===
                     unquote(client).write(ctx.conn, line, database: ctx.database)
          end

          ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 2, "w" => 3}]} ===
                   Retention.rows(unquote(client), ctx, "SELECT v, w FROM m")
        end
      end
    end
  end

  defp policy_tests(client) do
    quote location: :keep do
      describe "retention — SHOW RETENTION POLICIES" do
        test "prints the retention of a database in the engine's format", ctx do
          for {retention, printed} <- Retention.durations() do
            Retention.fresh(unquote(client), ctx, retention)

            assert {retention, {:ok, Retention.policies(ctx.database, printed)}} ===
                     {retention,
                      Retention.influxql(unquote(client), ctx, "SHOW RETENTION POLICIES")}
          end
        end

        test "ON names the database, and none is 0s", ctx do
          Retention.fresh(unquote(client), ctx, "1h")

          assert {:ok, Retention.policies(ctx.database, "1h0m0s")} ===
                   Retention.influxql(
                     unquote(client),
                     ctx,
                     "SHOW RETENTION POLICIES ON #{ctx.database}"
                   )

          Retention.fresh(unquote(client), ctx, nil)

          assert {:ok, Retention.policies(ctx.database, "0s")} ===
                   Retention.influxql(unquote(client), ctx, "SHOW RETENTION POLICIES")
        end

        test "creating a database that exists keeps its retention", ctx do
          Retention.fresh(unquote(client), ctx, "1h")
          assert :ok === unquote(client).create_database(ctx.conn, ctx.database, retention: "2h")

          assert {:ok, Retention.policies(ctx.database, "1h0m0s")} ===
                   Retention.influxql(unquote(client), ctx, "SHOW RETENTION POLICIES")

          assert :ok === unquote(client).create_database(ctx.conn, ctx.database)

          assert {:ok, Retention.policies(ctx.database, "1h0m0s")} ===
                   Retention.influxql(unquote(client), ctx, "SHOW RETENTION POLICIES")
        end

        test "a deleted database takes its retention with it", ctx do
          Retention.fresh(unquote(client), ctx, "1h")
          :ok = unquote(client).delete_database(ctx.conn, ctx.database)
          :ok = unquote(client).create_database(ctx.conn, ctx.database)

          assert {:ok, Retention.policies(ctx.database, "0s")} ===
                   Retention.influxql(unquote(client), ctx, "SHOW RETENTION POLICIES")
        end
      end
    end
  end
end
