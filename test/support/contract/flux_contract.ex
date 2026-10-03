defmodule InfluxElixir.Contract.Flux do
  @moduledoc """
  Flux contract tests, run against `InfluxElixir.Client.Local` and against a
  real InfluxDB 2.7: the rows the double must return exactly as the engine
  does. Every expectation here was read from InfluxDB 2.7.

      use InfluxElixir.Contract.Flux, client: InfluxElixir.Client.Local, profile: :v2

  The `setup` callback must return `conn`, `database` (the bucket) and
  `query_delay`, as for the shared contract. A real server keeps its data
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
  # Runs `flux`, a query whose range ends at now, and returns its rows without
  # `_start` and `_stop`. Every row must carry both: `_stop` lies within
  # `slack` seconds of this clock and `_stop - _start` is `width` seconds.
  @spec rows_until_now(module(), map(), binary(), pos_integer()) :: [map()]
  def rows_until_now(client, ctx, flux, width) do
    {:ok, rows} = client.query_flux(ctx.conn, flux)
    now = System.os_time(:second)
    slack = Map.get(ctx, :time_slack, 5)

    Enum.map(rows, fn %{"_start" => start, "_stop" => stop} = row ->
      unless abs(DateTime.to_unix(stop) - now) <= slack, do: raise("_stop is #{stop}")
      unless DateTime.diff(stop, start) === width, do: raise("range is #{start} to #{stop}")
      Map.drop(row, ["_start", "_stop"])
    end)
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
      {:pipeline, stage_tests(client)},
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

  defp stage_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — stages contract" do
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

          {:ok, m: m, head: head, v: v, row: row}
        end

        test "tables are series in tag order; rows carry the range's _start", ctx do
          {:ok, rows} = unquote(client).query_flux(ctx.conn, ctx.head)

          assert Enum.map(rows, &{&1["table"], &1["host"]}) === [
                   {0, "a"},
                   {0, "a"},
                   {1, "a"},
                   {1, "a"},
                   {2, "b"},
                   {3, "b"}
                 ]

          assert Enum.all?(rows, &(&1["_start"] === ~U[1970-01-01 00:00:00.000000Z]))
        end

        test "filter predicates: or, !=, not, numeric _value, r[\"key\"], a missing key", ctx do
          values = fn tail ->
            {:ok, rows} = unquote(client).query_flux(ctx.conn, ctx.head <> tail)
            Enum.map(rows, &{&1["table"], &1["host"], &1["_value"]})
          end

          assert values.(ctx.v <> ~s| \|> filter(fn: (r) => r.host == "a" or r.host == "b")|) ===
                   [{0, "a", 1.0}, {0, "a", 3.0}, {1, "b", 5.0}]

          assert unquote(client).query_flux(
                   ctx.conn,
                   ctx.head <> ctx.v <> ~s| \|> filter(fn: (r) => r.host != "a")|
                 ) === {:ok, [ctx.row.(0, "b", ~U[2023-11-14 22:13:20.000000Z], 5.0)]}

          assert values.(~s| \|> filter(fn: (r) => r._value > 2.0)|) ===
                   [{0, "a", 3.0}, {1, "b", 3}, {2, "b", 5.0}]

          assert values.(~s| \|> filter(fn: (r) => not (r.host == "a"))|) ===
                   [{0, "b", 3}, {1, "b", 5.0}]

          assert values.(~s| \|> filter(fn: (r) => r["host"] == "b")|) ===
                   [{0, "b", 3}, {1, "b", 5.0}]

          assert values.(~s| \|> filter(fn: (r) => r.nosuch == "x")|) === []
        end

        test "selectors keep their row; sum and count drop _time", ctx do
          flux = fn tail ->
            {:ok, rows} = unquote(client).query_flux(ctx.conn, ctx.head <> tail)
            rows
          end

          values = fn rows -> Enum.map(rows, &{&1["table"], &1["host"], &1["_value"]}) end

          rows = flux.(ctx.v <> " |> last()")
          assert values.(rows) === [{0, "a", 3.0}, {1, "b", 5.0}]

          assert Enum.map(rows, & &1["_time"]) === [
                   ~U[2023-11-14 22:14:20.000000Z],
                   ~U[2023-11-14 22:13:20.000000Z]
                 ]

          assert values.(flux.(ctx.v <> " |> max()")) === [{0, "a", 3.0}, {1, "b", 5.0}]

          n = ~s| \|> filter(fn: (r) => r._field == "n")|
          assert values.(flux.(n <> " |> sum()")) === [{0, "a", 3}, {1, "b", 3}]
          assert values.(flux.(ctx.v <> " |> count()")) === [{0, "a", 2}, {1, "b", 1}]

          assert Enum.all?(flux.(ctx.v <> " |> count()"), &(not Map.has_key?(&1, "_time")))
          assert Enum.all?(flux.(n <> " |> sum()"), &(not Map.has_key?(&1, "_time")))
        end

        test "limit takes an offset; mean drops _time and can be filtered", ctx do
          assert unquote(client).query_flux(
                   ctx.conn,
                   ctx.head <> ctx.v <> " |> limit(n: 1, offset: 1)"
                 ) === {:ok, [ctx.row.(0, "a", ~U[2023-11-14 22:14:20.000000Z], 3.0)]}

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

        test "range(stop:) and an RFC3339 start bound the rows", ctx do
          {:ok, rows} =
            unquote(client).query_flux(
              ctx.conn,
              InfluxElixir.Contract.Flux.head(
                ctx,
                ctx.m,
                "start: 0, stop: 1700000030"
              ) <> ctx.v
            )

          assert Enum.map(rows, & &1["_value"]) === [1.0, 5.0]

          # With no `stop` the range ends at now.
          flux =
            InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: 2023-11-14T22:14:00Z") <>
              ctx.v

          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)

          assert Enum.map(rows, &{&1["_start"], &1["_time"], &1["_value"]}) ===
                   [{~U[2023-11-14 22:14:00.000000Z], ~U[2023-11-14 22:14:20.000000Z], 3.0}]
        end
      end
    end
  end

  defp predicate_tests(client) do
    quote location: :keep do
      describe "query_flux/3 — predicates contract" do
        setup ctx do
          m = InfluxElixir.IntegrationHelper.unique_name("contract_fxq")
          now = System.os_time(:second) * 1_000_000_000
          old = now - 7_200_000_000_000

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "#{m},host=web01 value=10i #{now}\n#{m},host=web02 value=20i #{old}",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          web01 = %{
            "result" => "_result",
            "table" => 0,
            "_measurement" => m,
            "_field" => "value",
            "_time" => DateTime.from_unix!(now, :nanosecond),
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
          now = System.os_time(:second) * 1_000_000_000

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},host=web01 used=5i,free=7i #{now}",
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
                       "_time" => DateTime.from_unix!(now, :nanosecond),
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
          now = System.os_time(:second) * 1_000_000_000
          recent = now - 10_000_000_000
          old = now - 7_200_000_000_000

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

        test "seconds and minutes bound the range", ctx do
          for {range, width} <- [{"-30s", 30}, {"-1m", 60}] do
            flux = InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: #{range}")

            rows =
              InfluxElixir.Contract.Flux.rows_until_now(unquote(client), ctx, flux, width)

            assert rows === [ctx.new], range
          end
        end

        test "days include every recent point; a tag filter narrows them", ctx do
          flux = InfluxElixir.Contract.Flux.head(ctx, ctx.m, "start: -1d")
          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)
          assert Enum.map(rows, &{&1["host"], &1["_value"]}) === [{"new", 1}, {"old", 2}]

          narrowed = flux <> ~s| \|> filter(fn: (r) => r.host == "new")|

          assert InfluxElixir.Contract.Flux.rows_until_now(
                   unquote(client),
                   ctx,
                   narrowed,
                   86_400
                 ) === [ctx.new]
        end
      end
    end
  end
end
