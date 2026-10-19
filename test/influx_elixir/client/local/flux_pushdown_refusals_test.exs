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

  defp message(conn, tail), do: refusal(conn, @head <> tail)

  # The message of a 400 the double answers, whose body holds nothing else.
  defp refusal(conn, flux) do
    {:error, %{status: 400, body: body} = error} = Local.query_flux(conn, flux)
    assert Map.delete(error, :body) === %{status: 400}
    %{"code" => "invalid", "message" => message} = Jason.decode!(body)
    message
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

    for filter <- [~S[r._field == "u" and r._value > 1], ~S[r._field == "u" or r._value > 1]] do
      assert message(conn, " |> filter(fn: (r) => #{filter})") ===
               "Client.Local: a comparison of the _value of an unsigned field is not modelled"
    end

    # A filter that leaves the unsigned series out compares none of its values.
    assert values(conn, ~S[ |> filter(fn: (r) => r._field == "n" and r._value > 0)]) === [1, 2]
  end

  # 2.7 takes the literal as an infinity (`r._value > 1<400 digits>.5` answers no rows),
  # which the BEAM has no float for. It raised.
  test "a float literal past the float range is refused", %{conn: conn} do
    huge = "1" <> String.duplicate("0", 400) <> ".5"

    assert message(conn, " |> filter(fn: (r) => r._value > #{huge})") ===
             "Client.Local: unsupported filter predicate: r._value > #{huge}"
  end

  test "a bucket name reads its escapes", %{conn: conn} do
    :ok = Local.create_bucket(conn, ~S[a\b])
    {:ok, :written} = Local.write(conn, "m v=1i 1000000000", database: ~S[a\b])

    assert Local.query_flux(conn, ~S[from(bucket: "a\\b") |> range(start: 0, stop: 100)]) ===
             {:ok,
              [
                %{
                  "result" => "_result",
                  "table" => 0,
                  "_start" => ~U[1970-01-01 00:00:00.000000Z],
                  "_stop" => ~U[1970-01-01 00:01:40.000000Z],
                  "_time" => ~U[1970-01-01 00:00:01.000000Z],
                  "_measurement" => "m",
                  "_field" => "v",
                  "_value" => 1
                }
              ]}

    # An escape the engine has no meaning for, or a quote left open, is no bucket name.
    for {flux, args} <- [
          {~S[from(bucket: "a\qb") |> range(start: 0)], ~S[bucket: "a\qb"]},
          {~S[from(bucket: "x\") |> range(start: 0)], ~S[bucket: "x\") |> range(start: 0]}
        ] do
      assert refusal(conn, flux) === "Client.Local: unsupported from(): #{args}"
    end
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
      assert refusal(conn, ~s[from(bucket: "b") |> range(#{range})]) ===
               "Client.Local: " <> refusal
    end

    # 2.7 refuses these offsets and the comma with positioned compile errors. The double
    # refused only the comma, which splits the arguments; `DateTime.from_iso8601/1` took the
    # offsets.
    for {time, refusal} <- [
          {"1970-01-01T00:00:00+0200", "unsupported range() time: 1970-01-01T00:00:00+0200"},
          {"1970-01-01T00:00:00+02", "unsupported range() time: 1970-01-01T00:00:00+02"},
          {"1970-01-01T00:00:00,5Z", "unsupported range(): unexpected argument 5Z"}
        ] do
      assert refusal(conn, ~s[from(bucket: "b") |> range(start: #{time})]) ===
               "Client.Local: " <> refusal
    end
  end
end
