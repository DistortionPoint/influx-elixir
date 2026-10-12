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
      limit, mean, yield, 64-bit sums, string escapes and repeated arguments
    * `:ranges` — ranges relative to now, predicates and range units
    * `:pushdown` — which filters storage evaluates and what a key it lacks is,
      one result per `yield`, the aggregates of string and boolean fields, and the
      order of the tables
  """

  @parts [:pipeline, :ranges, :pushdown]

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
      {:pipeline, literal_tests(client)},
      {:ranges, predicate_tests(client)},
      {:ranges, range_unit_tests(client)},
      {:pushdown, pushdown_helpers(client)},
      {:pushdown, pushdown_tests(client)},
      {:pushdown, flux_semantics_tests(client)},
      {:pushdown, result_tests(client)},
      {:pushdown, type_aggregate_tests(client)},
      {:pushdown, table_order_tests(client)}
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

  defp literal_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — 64-bit sums, string literals and arguments" do
        test "an integer or unsigned sum wraps in 64 bits, and a mean divides the wrapped sum",
             ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxw")

          lp = """
          #{m},h=a i=9223372036854775807i,u=18446744073709551615u 1000000000
          #{m},h=a i=9223372036854775807i,u=18446744073709551615u 2000000000
          #{m},h=a i=5i,u=5u 3000000000
          #{m},h=b i=-9223372036854775807i 1000000000
          #{m},h=b i=-9223372036854775807i 2000000000
          """

          {:ok, :written} =
            unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)
          head = InfluxElixir.Contract.Flux.head(ctx, m, "start: 0, stop: 100")

          values = fn tail ->
            {:ok, rows} = unquote(client).query_flux(ctx.conn, head <> tail)
            Enum.map(rows, &{&1["table"], &1["h"], &1["_field"], &1["_value"]})
          end

          # storage reads the series in order; after limit, Flux sorts by group key
          assert values.(" |> sum()") === [{0, "a", "i", 3}, {1, "a", "u", 3}, {2, "b", "i", 2}]

          assert values.(" |> limit(n: 3) |> sum()") ===
                   [{0, "a", "i", 3}, {1, "b", "i", 2}, {2, "a", "u", 3}]

          assert values.(" |> mean()") ===
                   [{0, "a", "i", 1.0}, {1, "a", "u", 1.0}, {2, "b", "i", 1.0}]
        end

        test "a string literal reads its escapes, in a filter and in a result's name", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxe")

          {:ok, :written} =
            unquote(client).write(ctx.conn, ~s|#{m},t=a\\b v=1i 1000000000|,
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)
          head = InfluxElixir.Contract.Flux.head(ctx, m, "start: 0, stop: 100")

          names = fn tail ->
            {:ok, rows} = unquote(client).query_flux(ctx.conn, head <> tail)
            Enum.map(rows, &{&1["result"], &1["t"]})
          end

          assert names.(~S[ |> filter(fn: (r) => r.t == "a\\b")]) === [{"_result", "a\\b"}]
          assert names.(~S{ |> filter(fn: (r) => r["t"] == "a\\b")}) === [{"_result", "a\\b"}]
          assert names.(~S[ |> yield(name: "x\ty\\z")]) === [{"x\ty\\z", "a\\b"}]
          assert names.(~S[ |> yield(name: "\"q\"")]) === [{~S("q"), "a\\b"}]
        end

        test "an argument given twice is a 400 that names it", ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxa")

          for {range, tail, key} <- [
                {"start: 0, start: 1, stop: 100", "", "start"},
                {"start: 0, stop: 100", " |> limit(n: 1, n: 2)", "n"}
              ] do
            flux = InfluxElixir.Contract.Flux.head(ctx, m, range) <> tail

            assert InfluxElixir.Contract.Flux.error_of(unquote(client).query_flux(ctx.conn, flux)) ===
                     {400, ~s(duplicate keyword parameter specified: "#{key}")}
          end
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

  # ---------------------------------------------------------------------------
  # Pushdown, results, aggregates of non-numeric fields
  # ---------------------------------------------------------------------------

  @doc false
  # `{status, message}` of an error answer.
  @spec error_of(term()) :: {pos_integer(), binary()}
  def error_of({:error, %{status: status, body: body}}),
    do: {status, Jason.decode!(body)["message"]}

  @doc false
  # A multi-result answer as `%{result => [{table, host, value}]}`: the engine
  # returns the results in no fixed order, so a test compares them by name.
  @spec by_result({:ok, [map()]}) :: %{binary() => [{non_neg_integer(), binary(), term()}]}
  def by_result({:ok, rows}) do
    rows
    |> Enum.group_by(& &1["result"], &{&1["table"], &1["h"], &1["_value"]})
  end

  # Three points of one measurement, two series, and the helpers that read them:
  # `rows.(tail)` is the `{result, table, host, value}` of each row of the
  # measurement's head followed by `tail`, or the error.
  defp pushdown_setup(client) do
    quote location: :keep do
      setup ctx do
        m = InfluxElixir.IntegrationHelper.unique_name("contract_fxd")

        lp = """
        #{m},h=a i=1i 1000000000
        #{m},h=a i=3i 2000000000
        #{m},h=b i=2i 3000000000
        """

        {:ok, :written} =
          unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)
        head = InfluxElixir.Contract.Flux.head(ctx, m, "start: 0, stop: 100")

        rows = fn tail ->
          case unquote(client).query_flux(ctx.conn, head <> tail) do
            {:ok, rows} -> Enum.map(rows, &{&1["result"], &1["table"], &1["h"], &1["_value"]})
            error -> error
          end
        end

        all = [{"_result", 0, "a", 1}, {"_result", 0, "a", 3}, {"_result", 1, "b", 2}]

        {:ok, m: m, head: head, rows: rows, all: all}
      end
    end
  end

  defp pushdown_helpers(client) do
    quote location: :keep do
      def fxd_local?, do: unquote(client) === InfluxElixir.Client.Local
    end
  end

  defp pushdown_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — storage pushdown of a filter" do
        unquote(pushdown_setup(client))

        test "pushed to storage, a key no series has is the empty string for !=", ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            [
              {~s| \|> filter(fn: (r) => r.nosuch != "a")|, ctx.all},
              {~s| \|> filter(fn: (r) => r.nosuch != "a" or r.h == "zzz")|, ctx.all},
              {~s| \|> filter(fn: (r) => r["nosuch"] != "a")|, ctx.all},
              {~s| \|> filter(fn: (r) => r.nosuch != "a") \|> filter(fn: (r) => r.other != "b")|,
               ctx.all},
              {~s| \|> yield(name: "_result")|, ctx.all},
              {~s| \|> filter(fn: (r) => r.nosuch != "a" and r.h == "a")|, Enum.take(ctx.all, 2)},
              {~s| \|> filter(fn: (r) => r.nosuch != "a" and r._value > 1)|,
               [{"_result", 0, "a", 3}, {"_result", 1, "b", 2}]},
              {~s| \|> filter(fn: (r) => r.nosuch == "a" or r.h == "b")|,
               [{"_result", 0, "b", 2}]},
              # An `and` inside an `or` storage takes whole
              {~s| \|> filter(fn: (r) => (r.h == "a" and r._value > 1) or r.h == "b")|,
               [{"_result", 0, "a", 3}, {"_result", 1, "b", 2}]},
              {~s| \|> filter(fn: (r) => (r.nosuch != "a" and r.h == "a") or r.h == "zzz")|,
               Enum.take(ctx.all, 2)},
              {~s| \|> filter(fn: (r) => r.nosuch != "")|, []},
              {~s| \|> filter(fn: (r) => r.nosuch == "")|, []},
              {~s| \|> filter(fn: (r) => r.nosuch == "a")|, []}
            ],
            fn {tail, expected} ->
              case ctx.rows.(tail) do
                ^expected -> :ok
                other -> {:mismatch, other}
              end
            end
          )
        end

        test "the conjuncts storage cannot take stay in Flux, where a missing key is null", ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            [
              {~s| \|> filter(fn: (r) => r.nosuch != "a" and r.h < "z")|, ctx.all},
              {~s| \|> filter(fn: (r) => r.h < "z" and r.nosuch != "a")|, ctx.all},
              {~s| \|> filter(fn: (r) => r.nosuch != "a" and r.h > "a")|,
               [{"_result", 0, "b", 2}]},
              {~s| \|> filter(fn: (r) => r.nosuch != "a" and not (r.h == "a"))|,
               [{"_result", 0, "b", 2}]},
              {~s| \|> filter(fn: (r) => (r.nosuch != "a" and r.h < "z") or r.h == "b")|,
               [{"_result", 0, "b", 2}]}
            ],
            fn {tail, expected} ->
              case ctx.rows.(tail) do
                ^expected -> :ok
                other -> {:mismatch, other}
              end
            end
          )
        end

        test "a filter not pushed whole, or after another stage, reads a missing key as null",
             ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            [
              {~s| \|> limit(n: 10) \|> filter(fn: (r) => r.nosuch != "a")|, []},
              {~s| \|> first() \|> filter(fn: (r) => r.nosuch != "a")|, []},
              {~s| \|> sum() \|> filter(fn: (r) => r.nosuch != "a")|, []},
              {~s| \|> filter(fn: (r) => r.h < "z") \|> filter(fn: (r) => r.nosuch != "a")|, []},
              {~s| \|> filter(fn: (r) => r.nosuch != "a" or r.h < "z")|, ctx.all},
              {~s| \|> filter(fn: (r) => r.nosuch != "a" or r.h > "z")|, []},
              {~s| \|> filter(fn: (r) => not (r.nosuch == "a"))|, []},
              {~s| \|> filter(fn: (r) => r.nosuch == "" or r.nosuch != "a")|, []},
              {~s| \|> filter(fn: (r) => r.h != "")|, ctx.all}
            ],
            fn {tail, expected} ->
              case ctx.rows.(tail) do
                ^expected -> :ok
                other -> {:mismatch, other}
              end
            end
          )
        end
      end
    end
  end

  defp flux_semantics_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — what Flux reads where storage does not" do
        unquote(pushdown_setup(client))

        test "and and or are not three-valued: a left side that is not true counts as false",
             ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            [
              # null or false is false, so its negation holds; null or null is null
              {~s| \|> limit(n: 10) \|> filter(fn: (r) => not (r.nosuch == "a" or r.h == "q"))|,
               ctx.all},
              {~s| \|> limit(n: 10) \|> filter(fn: (r) => not (r.nosuch == "a" or r.nosuch2 == "a"))|,
               []},
              # null and anything is false; true and null is null (so a row whose left
              # side is false is kept by the negation, one whose left side is true is not)
              {~s| \|> limit(n: 10) \|> filter(fn: (r) => not (r.nosuch == "a" and r.h == "a"))|,
               ctx.all},
              {~s| \|> limit(n: 10) \|> filter(fn: (r) => not (r.h == "a" and r.nosuch == "a"))|,
               [{"_result", 0, "b", 2}]},
              {~s| \|> limit(n: 10) \|> filter(fn: (r) => r.nosuch == "a" or r.h == "b")|,
               [{"_result", 0, "b", 2}]}
            ],
            fn {tail, expected} ->
              case ctx.rows.(tail) do
                ^expected -> :ok
                other -> {:mismatch, other}
              end
            end
          )
        end

        test "in storage a literal of another type matches nothing, and so does a time column",
             ctx do
          InfluxElixir.TestSupport.Check.check_cases(
            [
              {~s| \|> filter(fn: (r) => r.h != 1)|, []},
              {~s| \|> filter(fn: (r) => r.h == true)|, []},
              {~s| \|> filter(fn: (r) => r._field == 1.5)|, []},
              {~s| \|> filter(fn: (r) => r._value == "x")|, []},
              {~s| \|> filter(fn: (r) => r._value != "x")|, []},
              {~s| \|> filter(fn: (r) => r._value == 3.0)|, [{"_result", 0, "a", 3}]},
              {~s| \|> filter(fn: (r) => r._time != "x")|, ctx.all},
              {~s| \|> filter(fn: (r) => r._time == "x")|, []}
            ],
            fn {tail, expected} ->
              case ctx.rows.(tail) do
                ^expected -> :ok
                other -> {:mismatch, other}
              end
            end
          )
        end

        @tag local_divergence:
               "Local names the type error of Flux, whose message holds a position in the query"
        test "in Flux a column compared with a literal of another type is an error", ctx do
          for tail <- [
                ~s| \|> limit(n: 10) \|> filter(fn: (r) => r.h != 1)|,
                ~s| \|> filter(fn: (r) => r.h < 1)|,
                ~s| \|> filter(fn: (r) => r.h != -1)|,
                ~s| \|> filter(fn: (r) => r.h != -0)|,
                ~s| \|> filter(fn: (r) => r.h == "" or r.h != 1)|,
                ~s| \|> filter(fn: (r) => r._time > 1)|,
                ~s| \|> filter(fn: (r) => r._time < "x")|,
                ~s| \|> limit(n: 10) \|> filter(fn: (r) => r._value == "x")|,
                ~s| \|> filter(fn: (r) => r._value > false)|
              ] do
            {status, message} = InfluxElixir.Contract.Flux.error_of(ctx.rows.(tail))
            assert status === 400, tail

            if fxd_local?(),
              do: assert(message =~ ~r/^Client\.Local: (comparing|ordering)/, tail),
              else: assert(message =~ ~r/unsupported binary expression|is not Comparable/, tail)
          end
        end

        test "a range that is not the first stage is an unbounded read", ctx do
          flux =
            ~s|from(bucket: "#{ctx.database}") \|> filter(fn: (r) => r._measurement == "#{ctx.m}") | <>
              ~s|\|> range(start: 0, stop: 100)|

          assert InfluxElixir.Contract.Flux.error_of(unquote(client).query_flux(ctx.conn, flux)) ===
                   {400,
                    "error in building plan while starting program: cannot submit unbounded " <>
                      ~s|read to "#{ctx.database}"; try bounding 'from' with a call to 'range'|}
        end
      end
    end
  end

  defp result_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — every yield is a result" do
        unquote(pushdown_setup(client))

        test "two yields return two results, each numbering its tables from 0", ctx do
          flux = ctx.head <> ~s| \|> yield(name: "a") \|> yield(name: "b")|
          rows = [{0, "a", 1}, {0, "a", 3}, {1, "b", 2}]

          assert InfluxElixir.Contract.Flux.by_result(unquote(client).query_flux(ctx.conn, flux)) ===
                   %{"a" => rows, "b" => rows}
        end

        test "a yield that is not the last stage keeps the rest as _result", ctx do
          flux = ctx.head <> ~s| \|> yield(name: "a") \|> sum()|

          assert InfluxElixir.Contract.Flux.by_result(unquote(client).query_flux(ctx.conn, flux)) ===
                   %{
                     "a" => [{0, "a", 1}, {0, "a", 3}, {1, "b", 2}],
                     "_result" => [{0, "a", 4}, {1, "b", 2}]
                   }

          flux =
            ctx.head <>
              ~s| \|> filter(fn: (r) => r.h == "a") \|> yield(name: "a") \|> filter(fn: (r) => r._value > 1)|

          assert InfluxElixir.Contract.Flux.by_result(unquote(client).query_flux(ctx.conn, flux)) ===
                   %{"a" => [{0, "a", 1}, {0, "a", 3}], "_result" => [{0, "a", 3}]}
        end

        test "a yield ends the pushdown, and a last yield leaves no _result", ctx do
          flux = ctx.head <> ~s| \|> yield(name: "y") \|> filter(fn: (r) => r.nosuch != "a")|

          assert InfluxElixir.Contract.Flux.by_result(unquote(client).query_flux(ctx.conn, flux)) ===
                   %{"y" => [{0, "a", 1}, {0, "a", 3}, {1, "b", 2}]}

          flux = ctx.head <> ~s| \|> sum() \|> yield(name: "s")|

          assert InfluxElixir.Contract.Flux.by_result(unquote(client).query_flux(ctx.conn, flux)) ===
                   %{"s" => [{0, "a", 4}, {1, "b", 2}]}

          flux = ctx.head <> ~s| \|> filter(fn: (r) => r._value > 100) \|> yield(name: "none")|
          assert unquote(client).query_flux(ctx.conn, flux) === {:ok, []}
        end

        test "two results of one name are a 400, and so is a yield named _result before a last stage",
             ctx do
          plan = "error in building plan while starting program: found more than one call to "
          state = "failed to initialize execute state: tried to produce more than one result "

          for {tail, message} <- [
                {~s| \|> yield(name: "a") \|> yield(name: "a")|,
                 plan <> ~s|yield() with the name "a"|},
                {~s| \|> yield(name: "a") \|> sum() \|> yield(name: "a")|,
                 plan <> ~s|yield() with the name "a"|},
                {~s| \|> yield() \|> yield()|, plan <> ~s|yield() with the name "_result"|},
                {~s| \|> yield() \|> sum()|, state <> ~s|with the name "_result"|},
                {~s| \|> yield(name: "_result") \|> filter(fn: (r) => r._value > 100)|,
                 state <> ~s|with the name "_result"|}
              ] do
            assert InfluxElixir.Contract.Flux.error_of(
                     unquote(client).query_flux(ctx.conn, ctx.head <> tail)
                   ) === {400, message}
          end
        end

        @tag local_divergence:
               "Local refuses a result with no name; the client drops the empty result column"
        test "a result with no name", ctx do
          result = unquote(client).query_flux(ctx.conn, ctx.head <> ~s| \|> yield(name: "")|)

          if fxd_local?() do
            assert InfluxElixir.Contract.Flux.error_of(result) ===
                     {400, "Client.Local: unsupported yield(): a result with no name"}
          else
            assert {:ok, [_one, _two, _three] = rows} = result
            refute Enum.any?(rows, &Map.has_key?(&1, "result"))
          end
        end
      end
    end
  end

  defp type_aggregate_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — aggregates of a string or boolean field" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxt")

          lp = """
          #{m},h=a s="x",b=true 1000000000
          #{m},h=a s="y",b=false 2000000000
          #{m},h=b s="z",b=true 3000000000
          """

          {:ok, :written} =
            unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)
          head = InfluxElixir.Contract.Flux.head(ctx, m, "start: 0, stop: 100")

          # `{table, host, value}` of each row of the field `field`
          rows = fn field, tail ->
            flux = head <> ~s| \|> filter(fn: (r) => r._field == "#{field}")| <> tail

            case unquote(client).query_flux(ctx.conn, flux) do
              {:ok, rows} -> Enum.map(rows, &{&1["table"], &1["h"], &1["_value"]})
              error -> error
            end
          end

          {:ok, m: m, head: head, rows: rows}
        end

        test "first, last and count take any type", ctx do
          assert ctx.rows.("s", " |> first()") === [{0, "a", "x"}, {1, "b", "z"}]
          assert ctx.rows.("s", " |> last()") === [{0, "a", "y"}, {1, "b", "z"}]
          assert ctx.rows.("s", " |> count()") === [{0, "a", 2}, {1, "b", 1}]
          assert ctx.rows.("b", " |> first()") === [{0, "a", true}, {1, "b", true}]
          assert ctx.rows.("b", " |> last()") === [{0, "a", false}, {1, "b", true}]
          assert ctx.rows.("b", " |> count()") === [{0, "a", 2}, {1, "b", 1}]
          assert ctx.rows.("s", " |> limit(n: 9) |> count()") === [{0, "a", 2}, {1, "b", 1}]
        end

        test "sum and mean read by storage name the type", ctx do
          for {field, type} <- [{"s", "string"}, {"b", "boolean"}], kind <- ["sum", "mean"] do
            assert InfluxElixir.Contract.Flux.error_of(ctx.rows.(field, " |> #{kind}()")) ===
                     {400, "unsupported input type for #{kind} aggregate: #{type}"}
          end

          # a string and a boolean field together: storage names the boolean
          assert InfluxElixir.Contract.Flux.error_of(
                   unquote(client).query_flux(ctx.conn, ctx.head <> " |> sum()")
                 ) === {400, "unsupported input type for sum aggregate: boolean"}

          # a series storage has dropped is not there to be refused
          assert ctx.rows.("s", ~s| \|> filter(fn: (r) => r.h == "zzz") \|> sum()|) === []
          assert ctx.rows.("s", ~s| \|> filter(fn: (r) => r.h == "zzz") \|> mean()|) === []
          # and Flux takes no notice of a table with no row
          assert ctx.rows.("s", ~s| \|> filter(fn: (r) => r.h < "a") \|> sum()|) === []

          assert ctx.rows.("s", ~s| \|> limit(n: 9) \|> filter(fn: (r) => r.h < "a") \|> mean()|) ===
                   []
        end

        @tag local_divergence: "Local refuses the errors whose form depends on the plan"
        test "sum and mean in Flux, or of a series storage dropped the rows of, are refused",
             ctx do
          for {field, kind, tail} <- [
                {"s", "sum", " |> limit(n: 9) |> sum()"},
                {"b", "mean", " |> limit(n: 9) |> mean()"},
                {"s", "sum", " |> first() |> sum()"},
                {"s", "sum", ~s| \|> filter(fn: (r) => r._value == "q") \|> sum()|}
              ] do
            {status, message} = InfluxElixir.Contract.Flux.error_of(ctx.rows.(field, tail))
            assert status === 400, tail

            if fxd_local?(),
              do:
                assert(
                  message ===
                    "Client.Local: #{kind}() of a string or boolean field: the engine's error " <>
                      "depends on the plan (and on which series storage has dropped)",
                  tail
                ),
              else: assert(message =~ ~r/unsupported (input type|aggregate column type)/, tail)
          end
        end

        @tag local_divergence:
               "Local refuses what the engine answers by a panic or a positioned error"
        @tag engine_bug: "min and max of a string or boolean field panic in storage (500)"
        test "min and max of a string or boolean field are the engine's own bug (Local refuses it by name)",
             ctx do
          for {field, cursor} <- [{"s", "string"}, {"b", "boolean"}], kind <- ["min", "max"] do
            result = ctx.rows.(field, " |> #{kind}()")

            if fxd_local?() do
              assert InfluxElixir.Contract.Flux.error_of(result) ===
                       {400,
                        "Client.Local: #{kind}() of a string or boolean field is an engine " <>
                          "error whose form depends on the plan (a 500 \"panic: unsupported " <>
                          "for aggregate #{kind}\" when storage reads it, a positioned 400 " <>
                          "otherwise)"}
            else
              assert InfluxElixir.Contract.Flux.error_of(result) ===
                       {500,
                        "panic: unsupported for aggregate #{kind}: " <>
                          "*reads.#{cursor}MultiShardArrayCursor"}
            end
          end

          # Flux runs it when something stands between the read and the selector
          {status, message} =
            InfluxElixir.Contract.Flux.error_of(ctx.rows.("s", " |> limit(n: 9) |> max()"))

          assert status === 400

          if fxd_local?(),
            do: assert(message =~ "Client.Local: max() of a string or boolean field"),
            else: assert(message =~ "MaxSelector has no implementation for type string")
        end
      end
    end
  end

  defp table_order_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — the order of the tables" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxo")

          lp = """
          #{m},h=a x=1i,y=2i 1000000000
          #{m},h=b x=3i,y=4i 1000000000
          """

          {:ok, :written} =
            unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)
          head = InfluxElixir.Contract.Flux.head(ctx, m, "start: 0, stop: 100")

          tables = fn tail ->
            {:ok, rows} = unquote(client).query_flux(ctx.conn, head <> tail)
            Enum.map(rows, &{&1["table"], &1["_field"], &1["h"]})
          end

          {:ok, tables: tables}
        end

        test "storage reads series in tag then field order; Flux sorts what it aggregates by group key",
             ctx do
          series = [{0, "x", "a"}, {1, "y", "a"}, {2, "x", "b"}, {3, "y", "b"}]
          grouped = [{0, "x", "a"}, {1, "x", "b"}, {2, "y", "a"}, {3, "y", "b"}]

          assert ctx.tables.("") === series
          assert ctx.tables.(" |> first()") === series
          assert ctx.tables.(" |> count()") === series
          assert ctx.tables.(" |> limit(n: 9)") === series
          assert ctx.tables.(" |> limit(n: 9) |> first()") === grouped
          assert ctx.tables.(" |> limit(n: 9) |> sum()") === grouped
          assert ctx.tables.(" |> first() |> first()") === grouped
        end
      end
    end
  end
end
