defmodule InfluxElixir.Client.Local.FluxPushdownRefusalsTest do
  @moduledoc """
  What `Client.Local.query_flux/3` refuses by name where InfluxDB 2.7 answers with
  an error that holds a position in the query, depends on the plan, or was not
  verified (an unsigned field's comparisons). What the engine answers to the
  constructs the double does model is pinned for both by the `:pushdown` part of
  `InfluxElixir.Contract.Flux`.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  @head ~S[from(bucket: "b") |> range(start: 0, stop: 100) |> filter(fn: (r) => r._measurement == "m")]

  setup do
    {:ok, conn} = Local.start(profile: :v2)
    :ok = Local.create_bucket(conn, "b")

    lp =
      ~s|m,h=a u=5u,n=1i,s="x" 1000000000\nm,h=a u=6u,n=2i,s="y" 2000000000|

    {:ok, :written} = Local.write(conn, lp, database: "b")
    {:ok, conn: conn}
  end

  defp message(conn, tail) do
    assert {:error, %{status: 400, body: body}} = Local.query_flux(conn, @head <> tail)
    Jason.decode!(body)["message"]
  end

  defp values(conn, tail) do
    {:ok, rows} = Local.query_flux(conn, @head <> tail)
    Enum.map(rows, & &1["_value"])
  end

  test "an unsigned field is read, summed and counted, but not compared", %{conn: conn} do
    field = ~S[ |> filter(fn: (r) => r._field == "u")]

    assert values(conn, field) === [5, 6]
    assert values(conn, field <> " |> sum()") === [11]
    assert values(conn, field <> " |> count()") === [2]

    assert message(conn, ~S[ |> filter(fn: (r) => r._field == "u" and r._value > 1)]) ===
             "Client.Local: a comparison of the _value of an unsigned field is not modelled"
  end

  test "ordering against a boolean or `_value` against a string is refused", %{conn: conn} do
    assert message(conn, ~S[ |> filter(fn: (r) => r.h > true)]) ===
             "Client.Local: ordering against a boolean is an error on the engine " <>
               "(bool is not Comparable)"

    assert message(conn, ~S[ |> filter(fn: (r) => r._value >= "x")]) ===
             "Client.Local: ordering _value against a string is not modelled"
  end

  test "Flux compares a column with a literal of its own type only", %{conn: conn} do
    assert message(conn, ~S[ |> limit(n: 9) |> filter(fn: (r) => r._measurement == 5)]) ===
             "Client.Local: comparing the string column _measurement with a number (==) is an " <>
               "error on the engine (unsupported binary expression)"

    assert message(conn, ~S[ |> limit(n: 9) |> filter(fn: (r) => r._time > 5)]) ===
             "Client.Local: comparing the time column _time with a number (>) is an error on " <>
               "the engine (unsupported binary expression)"

    assert message(
             conn,
             ~S[ |> filter(fn: (r) => r._field == "n") |> limit(n: 9) |> filter(fn: (r) => r._value == "x")]
           ) ===
             "Client.Local: comparing the number column _value with a string (==) is an error " <>
               "on the engine (unsupported binary expression)"
  end

  test "a string field's min, max and unpinned sum and mean are refused", %{conn: conn} do
    field = ~S[ |> filter(fn: (r) => r._field == "s")]

    for kind <- ["min", "max"] do
      assert message(conn, field <> " |> #{kind}()") ===
               "Client.Local: #{kind}() of a string or boolean field is an engine error whose " <>
                 "form depends on the plan (a 500 \"panic: unsupported for aggregate #{kind}\" " <>
                 "when storage reads it, a positioned 400 otherwise)"
    end

    assert message(conn, field <> " |> sum()") ===
             "unsupported input type for sum aggregate: string"

    assert message(conn, field <> " |> limit(n: 9) |> mean()") ===
             "Client.Local: mean() of a string or boolean field: the engine's error depends " <>
               "on the plan (and on which series storage has dropped)"
  end

  test "a result with no name, or named by an expression, is refused", %{conn: conn} do
    assert message(conn, ~S[ |> yield(name: "")]) ===
             "Client.Local: unsupported yield(): a result with no name"

    assert message(conn, ~S[ |> yield(name: "a" + "b")]) ===
             ~S[Client.Local: unsupported yield(): name: "a" + "b"]
  end

  test "a comparison with a negative number, -0 among them, is not pushed", %{conn: conn} do
    assert message(conn, ~S[ |> filter(fn: (r) => r._field == "s" and r._value > -0)]) ===
             "Client.Local: comparing the string column _value with a number (>) is an error " <>
               "on the engine (unsupported binary expression)"

    assert values(conn, ~S[ |> filter(fn: (r) => r._field == "n" and r._value > -0.0)]) ===
             [1, 2]
  end

  test "syntax the engine refuses with a position is refused by name", %{conn: conn} do
    for {tail, refusal} <- [
          {~S[ |> filter(fn: (r) => r._value > 1e5)],
           ~S[unsupported filter predicate: r._value > 1e5]},
          {~S[ |> filter(fn: (r) => r.h == "a\qb")],
           ~S[unsupported filter predicate: r.h == "a\qb"]},
          {~S[ |> filter(fn: (r) => r.h == "${x}")],
           ~S[unsupported filter predicate: r.h == "${x}"]},
          {" |> limit(n: 1, junk: 2)", "unsupported limit(): unexpected argument junk"},
          {~S[ |> yield(name: "x", x: 1)], "unsupported yield(): unexpected argument x"}
        ] do
      assert message(conn, tail) === "Client.Local: " <> refusal
    end

    for {range, refusal} <- [
          {"", "range() needs start"},
          {"-1h", "unsupported range(): unexpected argument -1h"},
          {"start: 0, foo: 1", "unsupported range(): unexpected argument foo"},
          {"start: 1970-01-01 00:00:00Z", "unsupported range() time: 1970-01-01 00:00:00Z"}
        ] do
      assert {:error, %{status: 400, body: body}} =
               Local.query_flux(conn, ~s[from(bucket: "b") |> range(#{range})])

      assert Jason.decode!(body) === %{
               "code" => "invalid",
               "message" => "Client.Local: " <> refusal
             }
    end
  end
end
