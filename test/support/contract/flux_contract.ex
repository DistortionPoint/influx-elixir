defmodule InfluxElixir.Contract.Flux do
  @moduledoc """
  Flux contract tests, run against `InfluxElixir.Client.Local` and against a
  real InfluxDB 2.7: the rows the double must return exactly as the engine
  does. Every expectation here was read from InfluxDB 2.7.

      use InfluxElixir.Contract.Flux, client: InfluxElixir.Client.Local, profile: :v2

  The `setup` callback must return `conn` and `database` (the bucket),
  as for the shared contract. A real server keeps its data
  between runs and the tests share one bucket, so every measurement name is
  unique and every query filters on it.

  ## Parts

  `part: part` generates one slice of the contract, for a module of its own
  that compiles and runs in parallel with its siblings. Without `:part`
  everything is generated.

    * `:pipeline` — absolute ranges and the stages: filter grammar, selectors,
      limit, mean, yield
    * `:ranges` — ranges relative to now, predicates and range units
  """

  @parts [:pipeline, :ranges]

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    :v2 = Keyword.fetch!(opts, :profile)
    part = Keyword.get(opts, :part, :all)

    unless part == :all or part in @parts do
      raise ArgumentError,
            "unknown :part #{inspect(part)}, expected :all or one of #{inspect(@parts)}"
    end

    tests =
      for {test_part, block} <- test_blocks(client),
          part == :all or part == test_part,
          do: block

    quote location: :keep do
      (unquote_splicing(tests))
    end
  end

  @doc false
  # The instant five seconds ago, in nanoseconds: where a test writes a point
  # that its relative range must hold. Writing at exactly now would lose the
  # point to a server clock a moment behind this one, and a range barely wider
  # than the point's age would lose it to a stall.
  @spec recent_ns() :: integer()
  def recent_ns, do: (System.os_time(:second) - 5) * 1_000_000_000

  @doc false
  # Runs `flux`, a query whose range ends at now, and returns its rows without
  # `_start` and `_stop`. Every row must carry both: `_stop` lies within
  # `slack` seconds of this clock and `_stop - _start` is `width` seconds.
  @spec rows_until_now(module(), map(), binary(), pos_integer()) :: [map()]
  def rows_until_now(client, ctx, flux, width) do
    case rows_until_now_result(client, ctx, flux, width) do
      {:ok, rows} -> rows
      {:error, why} -> raise why
    end
  end

  @doc false
  # `rows_until_now/4` as `{:ok, rows}`, or `{:error, message}` for a row whose
  # range is not the one asked for, so that a test over several ranges can
  # report every one that failed.
  @spec rows_until_now_result(module(), map(), binary(), pos_integer()) ::
          {:ok, [map()]} | {:error, binary()}
  def rows_until_now_result(client, ctx, flux, width) do
    {:ok, rows} = client.query_flux(ctx.conn, flux)
    now = System.os_time(:second)
    slack = Map.get(ctx, :time_slack, 5)

    Enum.reduce_while(rows, {:ok, []}, fn %{"_start" => start, "_stop" => stop} = row,
                                          {:ok, acc} ->
      cond do
        abs(DateTime.to_unix(stop) - now) > slack ->
          {:halt, {:error, "_stop is #{stop}"}}

        DateTime.diff(stop, start) !== width ->
          {:halt, {:error, "range is #{start} to #{stop}"}}

        true ->
          {:cont, {:ok, [Map.drop(row, ["_start", "_stop"]) | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc false
  # The Flux head selecting the measurement `m` of the bucket, over `range`.
  @spec head(map(), binary(), binary()) :: binary()
  def head(ctx, m, range) do
    ~s|from(bucket: "#{ctx.database}") \|> range(#{range}) | <>
      ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|
  end

  # Every block of tests with the part it belongs to, in order.
  @spec test_blocks(Macro.t()) :: [{atom(), Macro.t()}]
  defp test_blocks(client) do
    [
      {:pipeline, absolute_range_tests(client)},
      {:pipeline, shape_tests(client)},
      {:pipeline, filter_tests(client)},
      {:pipeline, selector_tests(client)},
      {:pipeline, range_bound_tests(client)},
      {:ranges, predicate_tests(client)},
      {:ranges, range_unit_tests(client)}
    ]
  end

  defp absolute_range_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — absolute ranges contract" do
        test "a row carries its range, series and measurement", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxr")

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m} value=1.0 1700000000000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          flux = InfluxElixir.Contract.Flux.head(ctx, m, "start: 0, stop: 1700000001")

          assert {:ok, [row]} = unquote(client).query_flux(ctx.conn, flux)

          assert row ===
                   %{
                     "result" => "_result",
                     "table" => 0,
                     "_start" => ~U[1970-01-01 00:00:00.000000Z],
                     "_stop" => ~U[2023-11-14 22:13:21.000000Z],
                     "_time" => ~U[2023-11-14 22:13:20.000000Z],
                     "_measurement" => m,
                     "_field" => "value",
                     "_value" => 1.0
                   }
        end
      end
    end
  end

  # The dataset the stage tests share: three series of two fields, written once per
  # test, and the helpers that read it.
  defp stage_setup(client) do
    quote location: :keep do
      setup ctx do
        m = InfluxElixir.IntegrationHelper.unique_name("contract_fxp")

        lp = """
        #{m},host=a v=1.0,n=1i 1700000000000000000
        #{m},host=a v=3.0,n=2i 1700000060000000000
        #{m},host=b v=5.0,n=3i 1700000000000000000
        """

        {:ok, :written} =
          unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)

        head = InfluxElixir.Contract.Flux.head(ctx, m, "start: 0, stop: 1800000000")
        v = ~s| \|> filter(fn: (r) => r._field == "v")|
        n = ~s| \|> filter(fn: (r) => r._field == "n")|

        # The row of the field `v` of `host`, as a range from the epoch to
        # 2027-01-15T08:00:00Z returns it.
        row = fn table, host, time, value ->
          %{
            "result" => "_result",
            "table" => table,
            "_measurement" => m,
            "_field" => "v",
            "_start" => ~U[1970-01-01 00:00:00.000000Z],
            "_stop" => ~U[2027-01-15 08:00:00.000000Z],
            "_time" => time,
            "_value" => value,
            "host" => host
          }
        end

        # `{table, host, value}` of each row a query returns, the tail
        # appended to the measurement's head.
        values = fn tail ->
          {:ok, rows} = unquote(client).query_flux(ctx.conn, head <> tail)
          Enum.map(rows, &{&1["table"], &1["host"], &1["_value"]})
        end

        {:ok, m: m, head: head, v: v, n: n, row: row, values: values}
      end
    end
  end

  defp shape_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — the shape of the tables" do
        unquote(stage_setup(client))

        test "tables are series in tag then field order", ctx do
          {:ok, rows} = unquote(client).query_flux(ctx.conn, ctx.head)

          assert Enum.map(rows, &{&1["table"], &1["host"], &1["_field"]}) === [
                   {0, "a", "n"},
                   {0, "a", "n"},
                   {1, "a", "v"},
                   {1, "a", "v"},
                   {2, "b", "n"},
                   {3, "b", "v"}
                 ]
        end

        test "every row carries the range's _start and _stop", ctx do
          {:ok, rows} = unquote(client).query_flux(ctx.conn, ctx.head)

          assert Enum.map(rows, &{&1["_start"], &1["_stop"]}) ===
                   List.duplicate(
                     {~U[1970-01-01 00:00:00.000000Z], ~U[2027-01-15 08:00:00.000000Z]},
                     6
                   )
        end
      end
    end
  end

  defp filter_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — the filter grammar" do
        unquote(stage_setup(client))

        test "filter: or", ctx do
          assert ctx.values.(ctx.v <> ~s| \|> filter(fn: (r) => r.host == "a" or r.host == "b")|) ===
                   [{0, "a", 1.0}, {0, "a", 3.0}, {1, "b", 5.0}]
        end

        test "filter: != returns the whole row", ctx do
          assert unquote(client).query_flux(
                   ctx.conn,
                   ctx.head <> ctx.v <> ~s| \|> filter(fn: (r) => r.host != "a")|
                 ) === {:ok, [ctx.row.(0, "b", ~U[2023-11-14 22:13:20.000000Z], 5.0)]}
        end

        test "filter: a numeric _value compares across integer and float fields", ctx do
          assert ctx.values.(~s| \|> filter(fn: (r) => r._value > 2.0)|) ===
                   [{0, "a", 3.0}, {1, "b", 3}, {2, "b", 5.0}]
        end

        test "filter: not", ctx do
          assert ctx.values.(~s| \|> filter(fn: (r) => not (r.host == "a"))|) ===
                   [{0, "b", 3}, {1, "b", 5.0}]
        end

        test "filter: r[\"key\"] reads a tag like r.key", ctx do
          assert ctx.values.(~s| \|> filter(fn: (r) => r["host"] == "b")|) ===
                   [{0, "b", 3}, {1, "b", 5.0}]
        end

        test "filter: a key no row has matches nothing", ctx do
          assert ctx.values.(~s| \|> filter(fn: (r) => r.nosuch == "x")|) === []
        end

        test "filter: and with a parenthesised or", ctx do
          filter =
            ~s| \|> filter(fn: (r) => r._field == "v" and (r.host != "a" or r._value > 2.0))|

          assert Enum.map(ctx.values.(filter), &elem(&1, 2)) === [3.0, 5.0]
        end
      end
    end
  end

  defp selector_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — selectors, limit, mean and yield" do
        unquote(stage_setup(client))

        test "last keeps the newest row of each table", ctx do
          {:ok, rows} = unquote(client).query_flux(ctx.conn, ctx.head <> ctx.v <> " |> last()")

          assert Enum.map(rows, &{&1["table"], &1["host"], &1["_value"], &1["_time"]}) === [
                   {0, "a", 3.0, ~U[2023-11-14 22:14:20.000000Z]},
                   {1, "b", 5.0, ~U[2023-11-14 22:13:20.000000Z]}
                 ]
        end

        test "max keeps the row of the largest value", ctx do
          assert ctx.values.(ctx.v <> " |> max()") === [{0, "a", 3.0}, {1, "b", 5.0}]
        end

        test "sum totals each table and drops _time", ctx do
          {:ok, rows} = unquote(client).query_flux(ctx.conn, ctx.head <> ctx.n <> " |> sum()")

          assert Enum.map(rows, &{&1["table"], &1["host"], &1["_value"]}) ===
                   [{0, "a", 3}, {1, "b", 3}]

          refute Enum.any?(rows, &Map.has_key?(&1, "_time"))
        end

        test "count counts each table and drops _time", ctx do
          {:ok, rows} = unquote(client).query_flux(ctx.conn, ctx.head <> ctx.v <> " |> count()")

          assert Enum.map(rows, &{&1["table"], &1["host"], &1["_value"]}) ===
                   [{0, "a", 2}, {1, "b", 1}]

          refute Enum.any?(rows, &Map.has_key?(&1, "_time"))
        end

        test "limit is per table", ctx do
          assert ctx.values.(ctx.v <> " |> limit(n: 1)") === [{0, "a", 1.0}, {1, "b", 5.0}]
        end

        test "limit takes an offset", ctx do
          assert unquote(client).query_flux(
                   ctx.conn,
                   ctx.head <> ctx.v <> " |> limit(n: 1, offset: 1)"
                 ) === {:ok, [ctx.row.(0, "a", ~U[2023-11-14 22:14:20.000000Z], 3.0)]}
        end

        test "mean averages each table and drops _time", ctx do
          {:ok, rows} = unquote(client).query_flux(ctx.conn, ctx.head <> ctx.v <> " |> mean()")

          assert Enum.map(rows, &{&1["host"], &1["_value"]}) === [{"a", 2.0}, {"b", 5.0}]
          refute Enum.any?(rows, &Map.has_key?(&1, "_time"))
        end

        test "a mean can be filtered", ctx do
          assert unquote(client).query_flux(
                   ctx.conn,
                   ctx.head <> ctx.v <> " |> mean() |> filter(fn: (r) => r._value > 2.0)"
                 ) === {:ok, [Map.delete(ctx.row.(0, "b", nil, 5.0), "_time")]}
        end

        test "yield names the result", ctx do
          {:ok, rows} =
            unquote(client).query_flux(ctx.conn, ctx.head <> ctx.v <> ~s| \|> yield(name: "x")|)

          assert Enum.map(rows, &{&1["result"], &1["_value"]}) === [
                   {"x", 1.0},
                   {"x", 3.0},
                   {"x", 5.0}
                 ]
        end
      end
    end
  end

  defp range_bound_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — absolute bounds and stored values" do
        unquote(stage_setup(client))

        test "range(stop:) bounds the rows", ctx do
          flux =
            InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: 0, stop: 1700000030") <> ctx.v

          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)

          assert Enum.map(rows, & &1["_value"]) === [1.0, 5.0]
        end

        test "an RFC3339 start bounds the rows, and with no stop the range ends at now", ctx do
          flux =
            InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: 2023-11-14T22:14:00Z") <>
              ctx.v

          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)

          assert Enum.map(rows, &{&1["_start"], &1["_time"], &1["_value"]}) ===
                   [{~U[2023-11-14 22:14:00.000000Z], ~U[2023-11-14 22:14:20.000000Z], 3.0}]
        end

        test "a string field with a newline reads back as stored", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxnl")

          {:ok, :written} =
            unquote(client).write(ctx.conn, ~s|#{m} s="l1\nl2" 1700000000000000000|,
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          flux = InfluxElixir.Contract.Flux.head(ctx, m, "start: 0, stop: 1800000000")

          assert {:ok, [%{"_value" => "l1\nl2"}]} = unquote(client).query_flux(ctx.conn, flux)
        end
      end
    end
  end

  defp predicate_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — predicates contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxq")
          # Written well inside every range below, so that a stall or a server
          # clock a few seconds behind this one cannot move it out of range.
          recent = InfluxElixir.Contract.Flux.recent_ns()
          old = recent - 7_200_000_000_000

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "#{m},host=web01 value=10i #{recent}\n#{m},host=web02 value=20i #{old}",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          web01 = %{
            "result" => "_result",
            "table" => 0,
            "_measurement" => m,
            "_field" => "value",
            "_time" => DateTime.from_unix!(recent, :nanosecond),
            "_value" => 10,
            "host" => "web01"
          }

          {:ok, m: m, web01: web01}
        end

        test "filter by tag equality", ctx do
          flux = InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: -24h")
          flux = flux <> ~s| \|> filter(fn: (r) => r.host == "web01")|

          assert InfluxElixir.Contract.Flux.rows_until_now(unquote(client), ctx, flux, 86_400) ===
                   [ctx.web01]
        end

        test "range(start: -1h) leaves out the old point", ctx do
          flux = InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: -1h")

          assert InfluxElixir.Contract.Flux.rows_until_now(unquote(client), ctx, flux, 3_600) ===
                   [ctx.web01]
        end

        test "rows are long-format with one table per series", ctx do
          flux = InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: -24h")
          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)

          assert Enum.map(rows, &{&1["table"], &1["host"], &1["result"]}) ===
                   [{0, "web01", "_result"}, {1, "web02", "_result"}]

          assert Enum.map(rows, & &1["_measurement"]) === [ctx.m, ctx.m]
          assert hd(rows)["_time"] === ctx.web01["_time"]
        end

        test "a _field filter keeps only that field", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxf")
          recent = InfluxElixir.Contract.Flux.recent_ns()

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},host=web01 used=5i,free=7i #{recent}",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          flux =
            InfluxElixir.Contract.Flux.head(ctx, m, "start: -1h") <>
              ~s| \|> filter(fn: (r) => r._field == "free")|

          assert InfluxElixir.Contract.Flux.rows_until_now(unquote(client), ctx, flux, 3_600) ===
                   [
                     %{
                       "result" => "_result",
                       "table" => 0,
                       "_time" => DateTime.from_unix!(recent, :nanosecond),
                       "_measurement" => m,
                       "_field" => "free",
                       "_value" => 7,
                       "host" => "web01"
                     }
                   ]
        end
      end
    end
  end

  defp range_unit_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — range units contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxu")
          recent = InfluxElixir.Contract.Flux.recent_ns()
          old = recent - 7_200_000_000_000

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "#{m},host=new value=1i #{recent}\n#{m},host=old value=2i #{old}",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          new = %{
            "result" => "_result",
            "table" => 0,
            "_measurement" => m,
            "_field" => "value",
            "_time" => DateTime.from_unix!(recent, :nanosecond),
            "_value" => 1,
            "host" => "new"
          }

          {:ok, m: m, new: new}
        end

        test "minutes bound the range", ctx do
          InfluxElixir.TestSupport.Check.check_cases([{"-5m", 300}, {"-90m", 5_400}], fn
            {range, width} ->
              flux = InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: #{range}")

              case InfluxElixir.Contract.Flux.rows_until_now_result(
                     unquote(client),
                     ctx,
                     flux,
                     width
                   ) do
                {:ok, rows} when rows === [ctx.new] -> :ok
                {:ok, rows} -> {:mismatch, rows}
                {:error, why} -> {:mismatch, why}
              end
          end)
        end

        test "seconds bound the range to their width", ctx do
          # A point of its own, written just before the query, so that the 30
          # second range holds it however long the setup took.
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxs")
          recent = InfluxElixir.Contract.Flux.recent_ns()

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m} value=1i #{recent}", database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)
          flux = InfluxElixir.Contract.Flux.head(ctx, m, "start: -30s")

          assert [%{"_value" => 1}] =
                   InfluxElixir.Contract.Flux.rows_until_now(unquote(client), ctx, flux, 30)
        end

        test "days include every recent point", ctx do
          flux = InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: -1d")
          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)

          assert Enum.map(rows, &{&1["host"], &1["_value"]}) === [{"new", 1}, {"old", 2}]
        end

        test "a tag filter narrows a day's points", ctx do
          flux =
            InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: -1d") <>
              ~s| \|> filter(fn: (r) => r.host == "new")|

          assert InfluxElixir.Contract.Flux.rows_until_now(unquote(client), ctx, flux, 86_400) ===
                   [ctx.new]
        end
      end
    end
  end
end
