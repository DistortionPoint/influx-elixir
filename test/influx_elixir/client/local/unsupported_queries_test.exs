defmodule InfluxElixir.Client.Local.UnsupportedQueriesTest do
  @moduledoc """
  The InfluxQL and Flux constructs `Client.Local` does not model and refuses by
  name instead of answering wrongly. What the engines answer to the constructs the
  double does model is pinned for the double and for the real servers by the
  contracts in `test/support`.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  describe "Client.Local: InfluxQL it does not model" do
    setup do
      {:ok, conn} = Local.start(databases: ["iq"])
      {:ok, :written} = Local.write(conn, "o,h=x v=3i 1700000000000003000", database: "iq")
      {:ok, conn: conn}
    end

    test "is refused by name", %{conn: conn} do
      InfluxElixir.TestSupport.Check.each_case(
        [
          {"SELECT INTEGRAL(v) FROM o GROUP BY time(1m)",
           "Client.Local: unsupported InfluxQL (integral() in a GROUP BY time)"},
          {"SELECT ELAPSED(MEAN(v)) FROM o GROUP BY time(1m)",
           "Client.Local: unsupported InfluxQL (elapsed() of an aggregate)"},
          {"SELECT DISTINCT(v) FROM o",
           "Client.Local: unsupported InfluxQL (distinct(): the values come in the engine's " <>
             "order)"}
        ],
        fn {statement, body} ->
          assert {:error, %{status: 400, body: ^body}} =
                   Local.query_influxql(conn, statement, database: "iq")
        end
      )
    end
  end

  describe "Client.Local: Flux it does not model" do
    setup do
      {:ok, conn} = Local.start(profile: :v2)
      :ok = Local.create_bucket(conn, "b")
      {:ok, :written} = Local.write(conn, "cpu,host=a v=1.0 1700000000000000000", database: "b")
      {:ok, conn: conn}
    end

    test "a stage is refused by name, never skipped", %{conn: conn} do
      InfluxElixir.TestSupport.Check.each_case(
        [
          {" |> aggregateWindow(every: 1m, fn: mean)",
           "Client.Local: unsupported Flux function: aggregateWindow()"},
          {~s| \|> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")|,
           "Client.Local: unsupported Flux function: pivot()"},
          {" |> group()", "Client.Local: unsupported Flux function: group()"},
          {" |> sort()", "Client.Local: unsupported Flux function: sort()"},
          {~s| \|> filter(fn: (r) => r.host =~ /a/)|,
           "Client.Local: unsupported filter predicate: r.host =~ /a/"}
        ],
        fn {tail, message} ->
          flux = ~s|from(bucket: "b") \|> range(start: 0, stop: 1800000000)| <> tail

          assert {:error, %{status: 400, body: body}} = Local.query_flux(conn, flux)
          assert Jason.decode!(body) === %{"code" => "invalid", "message" => message}
        end
      )
    end
  end
end
