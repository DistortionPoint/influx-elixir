defmodule InfluxElixir.Contract.InfluxQLCallCases do
  @moduledoc "Statements over the fixture of `InfluxElixir.Contract.InfluxQLPlanner` with the answers InfluxDB 3 Core gave: `GROUP BY` dimensions, `fill()`, transforms, math, selectors, wildcards and `FROM` lists. A row is `{time, columns}`; the time is `YYYY-MM-DD HH:MM:SS`."

  @base 1_704_067_200

  @doc "The fixture's measurements for the names `k1` to `k3` and the prefix `kp` of `k2` and `k3`."
  @spec names(binary()) :: %{binary() => binary()}
  def names(prefix) do
    %{
      "k1" => prefix <> "_one",
      "k2" => prefix <> "_wa",
      "k3" => prefix <> "_wb",
      "kp" => prefix <> "_w"
    }
  end

  @doc """
  The fixture, as line protocol: `k1` has four hosts whose points never share a
  time (`a` ten points half a minute apart with a string and a boolean, `b`
  five, `c` five with a gap, `d` four with negative numbers); `k2` and `k3` are
  two measurements with fields and tags of their own.
  """
  @spec fixture(%{binary() => binary()}) :: [binary()]
  def fixture(names) do
    [k1, k2, k3] = [names["k1"], names["k2"], names["k3"]]

    va = [1.0, 3.0, 2.0, 5.0, 5.0, 4.0, 9.0, 1.0, 2.0, 8.0]
    ca = [0, 10, 20, 35, 35, 50, 70, 5, 15, 40]

    a =
      for {{v, c}, i} <- Enum.with_index(Enum.zip(va, ca)) do
        ~s(#{k1},host=a,region=east v=#{v},c=#{c}i,s="s#{rem(i, 3)}",b=#{rem(i, 2) == 0} #{at(i * 30)})
      end

    b =
      for {v, i} <- Enum.with_index([10.0, 20.0, 15.0, 15.0, 40.0]) do
        "#{k1},host=b,region=east v=#{v},c=#{i * 100}i #{at(5 + i * 30)}"
      end

    c =
      for {{v, n}, s} <-
            Enum.zip(
              [{1.0, 1}, {2.0, 4}, {4.0, 9}, {10.0, 5}, {20.0, 50}],
              [0, 30, 60, 210, 240]
            ) do
        "#{k1},host=c,region=west v=#{v},c=#{n}i #{at(10 + s)}"
      end

    d =
      for {{v, n}, i} <- Enum.with_index([{-2.5, -3}, {0.0, 0}, {2.25, 4}, {16.0, 16}]) do
        "#{k1},host=d,region=west v=#{v},c=#{n}i #{at(15 + i * 30)}"
      end

    wa =
      for {v, i} <- Enum.with_index([1.5, 2.5, 4.0, 8.0]),
          {host, off, add} <- [{"x", 0, 0}, {"y", 7, 10}] do
        ~s(#{k2},host=#{host},region=r#{rem(i, 2)} v=#{v + add},c=#{i * 3}i,s="s#{i}",b=#{rem(i, 2) == 0} #{at(i * 30 + off)})
      end

    wb =
      for {v, i} <- Enum.with_index([5.0, 6.0, 7.0]) do
        "#{k3},host=x,zone=z1 v=#{v},n=#{i * 7}i #{at(i * 30 + 3)}"
      end

    a ++ b ++ c ++ d ++ wa ++ wb
  end

  @prefix "error in InfluxQL statement: parsing error: "
  @time_close "invalid TIME call, expected ')'"
  @time_interval "invalid TIME call, expected a duration for the interval"
  @time_call "invalid TIME call, expected 1 or 2 arguments"
  @fill "invalid FILL option, expected NULL, NONE, PREVIOUS, LINEAR, or a number"
  @group "invalid GROUP BY clause, expected wildcard, TIME, identifier or regular expression"
  @data_type "invalid data type for tag or field reference, " <>
               "expected float, integer, unsigned, string, boolean, field, tag"
  @wildcard "invalid wildcard type specifier, expected TAG or FIELD"

  @doc """
  The clauses the engine's parser fails on after a `WHERE`, each with the
  error it gives: `{clause, {:message, text, offset}}` is `text at pos N` with
  `N` the offset in the clause added to where the clause starts, `{clause, {:left,
  offset}}` the statement left over from that offset (`invalid InfluxQL statement at
  pos N. Parsing Error: Nom(rest, Tag)`).
  """
  @spec parse_errors() :: [
          {binary(), {:message, binary(), non_neg_integer()} | {:left, non_neg_integer()}}
        ]
  def parse_errors do
    [
      {"GROUP BY time(", {:message, @time_interval, 14}},
      {"GROUP BY time(5m, ", {:message, @time_close, 16}},
      {"GROUP BY time 5m", {:message, @time_call, 13}},
      {"GROUP BY time", {:message, @time_call, 13}},
      {"GROUP BY host, time", {:message, @time_call, 19}},
      {"GROUP BY time()", {:message, @time_interval, 14}},
      {"GROUP BY time( x)", {:message, @time_interval, 14}},
      {"GROUP BY time(5m,)", {:message, @time_close, 16}},
      {"GROUP BY time(5m fill(previous)", {:message, @time_close, 16}},
      {"GROUP BY time(2m , x)", {:message, @time_close, 16}},
      {"GROUP BY time(2m x)", {:message, @time_close, 16}},
      {"GROUP BY time(2m, x)", {:message, @time_close, 16}},
      {"GROUP BY time(2m, 1m x)", {:message, @time_close, 20}},
      {"GROUP BY time(5m, 1m, 2m)", {:message, @time_close, 20}},
      {"GROUP BY time(1.5m)", {:message, @time_close, 15}},
      {"GROUP BY time(5m) fill(", {:message, @fill, 23}},
      {"GROUP BY time(5m) fill()", {:message, @fill, 23}},
      {"GROUP BY time(5m) fill(--1)", {:message, @fill, 23}},
      {"GROUP BY time(5m) fill(-)", {:message, @fill, 23}},
      {"GROUP BY time(5m) fill( +)", {:message, @fill, 23}},
      {"GROUP BY time(5m) fill( x)", {:message, @fill, 23}},
      {"GROUP BY time(5m) fill(99999999999999999999)", {:message, @fill, 23}},
      {"GROUP BY time(5m) fill(9223372036854775808)", {:message, @fill, 23}},
      {"GROUP BY time(5m) fill(-9223372036854775808)", {:message, @fill, 23}},
      {"GROUP BY time(5m) fill", {:left, 18}},
      {"GROUP BY time(5m) fill(previous", {:left, 18}},
      {"GROUP BY time(5m) fill(null", {:left, 18}},
      {"GROUP BY time(5m) fill(1 2)", {:left, 18}},
      {"GROUP BY time(5m) fill(1.)", {:left, 18}},
      {"GROUP BY time(5m) fill(1e3)", {:left, 18}},
      {"GROUP BY time(5m) fill(1,)", {:left, 18}},
      {"GROUP BY time(5m) fill(null))", {:left, 28}},
      {"GROUP BY time(5m) fill(1) extra", {:left, 26}},
      {"GROUP BY time(5m) fill(null) fill(none)", {:left, 29}},
      {"GROUP BY time(5m) fill(null) LIMIT 1 fill(1)", {:left, 37}},
      {"GROUP BY time(5m) time(5m)", {:left, 18}},
      {"GROUP BY time(5m),", {:left, 17}},
      {"GROUP BY host,", {:left, 13}},
      {"GROUP BY host,,x", {:left, 13}},
      {"GROUP BY host host", {:left, 14}},
      {"GROUP BY host, limit", {:left, 13}},
      {"GROUP BY host, (x)", {:left, 13}},
      {"GROUP BY host, 5", {:left, 13}},
      {"GROUP BY host, 'x'", {:left, 13}},
      {"GROUP BY time(5m), 'host'", {:left, 17}},
      {"GROUP BY host(5m)", {:left, 13}},
      {"GROUP BY fill(none)", {:left, 13}},
      {"GROUP BY host ::tag", {:left, 14}},
      {"GROUP BY host::tag x", {:left, 19}},
      {"GROUP BY /ho/i", {:left, 13}},
      {"GROUP BY /ho/::tag", {:left, 13}},
      {"GROUP BY ,", {:message, @group, 9}},
      {"GROUP BY 'host'", {:message, @group, 9}},
      {"GROUP BY 5", {:message, @group, 9}},
      {"GROUP BY (host)", {:message, @group, 9}},
      {"GROUP BY limit", {:message, @group, 9}},
      {"GROUP BY host::", {:message, @data_type, 15}},
      {"GROUP BY host::foo", {:message, @data_type, 15}},
      {"GROUP BY host::tag::tag", {:message, @data_type, 15}},
      {"GROUP BY host::tagx", {:message, @data_type, 15}},
      {"GROUP BY *::foo", {:message, @wildcard, 12}},
      {"GROUP BY *::float", {:message, @wildcard, 12}},
      {"GROUP BY *::tag::tag", {:message, @wildcard, 12}},
      {"GROUP BY /ho", {:message, "unterminated regex literal", 12}}
    ]
  end

  @doc "The body the engine answers a clause of `parse_errors/0` with, for a statement of `prefix` bytes before it."
  @spec parse_error_body(non_neg_integer(), binary(), term()) :: binary()
  def parse_error_body(start, _clause, {:message, text, offset}),
    do: @prefix <> "#{text} at pos #{start + offset}"

  def parse_error_body(start, clause, {:left, offset}) do
    rest = binary_part(clause, offset, byte_size(clause) - offset)

    @prefix <>
      "invalid InfluxQL statement at pos #{start + offset}. " <>
      "Parsing Error: Nom(#{inspect(rest)}, Tag)"
  end

  @doc false
  @spec dimensions() :: [{binary(), term()}]
  def dimensions do
    [
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY *",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c", "region" => "west"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d", "region" => "west"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(2m), *",
       [
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "a", "region" => "east"}},
         {"2024-01-01 00:02:00", %{"count" => 4, "host" => "a", "region" => "east"}},
         {"2024-01-01 00:04:00", %{"count" => 2, "host" => "a", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "b", "region" => "east"}},
         {"2024-01-01 00:02:00", %{"count" => 1, "host" => "b", "region" => "east"}},
         {"2024-01-01 00:04:00", %{"count" => 0, "host" => "b", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 3, "host" => "c", "region" => "west"}},
         {"2024-01-01 00:02:00", %{"count" => 1, "host" => "c", "region" => "west"}},
         {"2024-01-01 00:04:00", %{"count" => 1, "host" => "c", "region" => "west"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d", "region" => "west"}},
         {"2024-01-01 00:02:00", %{"count" => 0, "host" => "d", "region" => "west"}},
         {"2024-01-01 00:04:00", %{"count" => 0, "host" => "d", "region" => "west"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY /^h/",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY /o/",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c", "region" => "west"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d", "region" => "west"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY /zzz/",
       [{"2024-01-01 00:00:00", %{"count" => 24}}]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY /HOST/",
       [{"2024-01-01 00:00:00", %{"count" => 24}}]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY /^(h|r)/",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c", "region" => "west"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d", "region" => "west"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(2m), /^h/ fill(none)",
       [
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "a"}},
         {"2024-01-01 00:02:00", %{"count" => 4, "host" => "a"}},
         {"2024-01-01 00:04:00", %{"count" => 2, "host" => "a"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "b"}},
         {"2024-01-01 00:02:00", %{"count" => 1, "host" => "b"}},
         {"2024-01-01 00:00:00", %{"count" => 3, "host" => "c"}},
         {"2024-01-01 00:02:00", %{"count" => 1, "host" => "c"}},
         {"2024-01-01 00:04:00", %{"count" => 1, "host" => "c"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY *::tag",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c", "region" => "west"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d", "region" => "west"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY *::field",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c", "region" => "west"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d", "region" => "west"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host::tag",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY region::field",
       [
         {"2024-01-01 00:00:00", %{"count" => 15, "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 9, "region" => "west"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host, *",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c", "region" => "west"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d", "region" => "west"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host, host",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY region, host",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b", "region" => "east"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c", "region" => "west"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d", "region" => "west"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(2m), time(1m)",
       [
         {"2024-01-01 00:00:00", %{"count" => 15}},
         {"2024-01-01 00:02:00", %{"count" => 6}},
         {"2024-01-01 00:04:00", %{"count" => 3}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m), time(2m)",
       [
         {"2024-01-01 00:00:00", %{"count" => 8}},
         {"2024-01-01 00:01:00", %{"count" => 7}},
         {"2024-01-01 00:02:00", %{"count" => 3}},
         {"2024-01-01 00:03:00", %{"count" => 3}},
         {"2024-01-01 00:04:00", %{"count" => 3}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(2m), time(0s)",
       [
         {"2024-01-01 00:00:00", %{"count" => 15}},
         {"2024-01-01 00:02:00", %{"count" => 6}},
         {"2024-01-01 00:04:00", %{"count" => 3}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(2m) , host",
       [
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "a"}},
         {"2024-01-01 00:02:00", %{"count" => 4, "host" => "a"}},
         {"2024-01-01 00:04:00", %{"count" => 2, "host" => "a"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "b"}},
         {"2024-01-01 00:02:00", %{"count" => 1, "host" => "b"}},
         {"2024-01-01 00:04:00", %{"count" => 0, "host" => "b"}},
         {"2024-01-01 00:00:00", %{"count" => 3, "host" => "c"}},
         {"2024-01-01 00:02:00", %{"count" => 1, "host" => "c"}},
         {"2024-01-01 00:04:00", %{"count" => 1, "host" => "c"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d"}},
         {"2024-01-01 00:02:00", %{"count" => 0, "host" => "d"}},
         {"2024-01-01 00:04:00", %{"count" => 0, "host" => "d"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY \"host\"",
       [
         {"2024-01-01 00:00:00", %{"count" => 10, "host" => "a"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d"}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY nosuch",
       [{"2024-01-01 00:00:00", %{"count" => 24}}]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY s",
       [
         {"2024-01-01 00:00:00", %{"count" => 4, "s" => "s0"}},
         {"2024-01-01 00:00:00", %{"count" => 3, "s" => "s1"}},
         {"2024-01-01 00:00:00", %{"count" => 3, "s" => "s2"}},
         {"2024-01-01 00:00:00", %{"count" => 14}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY b",
       [
         {"2024-01-01 00:00:00", %{"b" => false, "count" => 5}},
         {"2024-01-01 00:00:00", %{"b" => true, "count" => 5}},
         {"2024-01-01 00:00:00", %{"count" => 14}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(2m), s",
       [
         {"2024-01-01 00:00:00", %{"count" => 2, "s" => "s0"}},
         {"2024-01-01 00:02:00", %{"count" => 1, "s" => "s0"}},
         {"2024-01-01 00:04:00", %{"count" => 1, "s" => "s0"}},
         {"2024-01-01 00:00:00", %{"count" => 1, "s" => "s1"}},
         {"2024-01-01 00:02:00", %{"count" => 2, "s" => "s1"}},
         {"2024-01-01 00:04:00", %{"count" => 0, "s" => "s1"}},
         {"2024-01-01 00:00:00", %{"count" => 1, "s" => "s2"}},
         {"2024-01-01 00:02:00", %{"count" => 1, "s" => "s2"}},
         {"2024-01-01 00:04:00", %{"count" => 1, "s" => "s2"}},
         {"2024-01-01 00:00:00", %{"count" => 11}},
         {"2024-01-01 00:02:00", %{"count" => 2}},
         {"2024-01-01 00:04:00", %{"count" => 1}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY b, host",
       [
         {"2024-01-01 00:00:00", %{"b" => false, "count" => 5, "host" => "a"}},
         {"2024-01-01 00:00:00", %{"b" => true, "count" => 5, "host" => "a"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "b"}},
         {"2024-01-01 00:00:00", %{"count" => 5, "host" => "c"}},
         {"2024-01-01 00:00:00", %{"count" => 4, "host" => "d"}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(2m), host fill(0)",
       [
         {"2024-01-01 00:00:00", %{"host" => "a", "mean" => 2.75}},
         {"2024-01-01 00:02:00", %{"host" => "a", "mean" => 4.75}},
         {"2024-01-01 00:04:00", %{"host" => "a", "mean" => 5.0}},
         {"2024-01-01 00:00:00", %{"host" => "b", "mean" => 15.0}},
         {"2024-01-01 00:02:00", %{"host" => "b", "mean" => 40.0}},
         {"2024-01-01 00:04:00", %{"host" => "b", "mean" => 0.0}},
         {"2024-01-01 00:00:00", %{"host" => "c", "mean" => 2.3333333333333335}},
         {"2024-01-01 00:02:00", %{"host" => "c", "mean" => 10.0}},
         {"2024-01-01 00:04:00", %{"host" => "c", "mean" => 20.0}},
         {"2024-01-01 00:00:00", %{"host" => "d", "mean" => 3.9375}},
         {"2024-01-01 00:02:00", %{"host" => "d", "mean" => 0.0}},
         {"2024-01-01 00:04:00", %{"host" => "d", "mean" => 0.0}}
       ]},
      {"SELECT count(c) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY v",
       [
         {"2024-01-01 00:00:00", %{"count" => 1, "v" => -2.5}},
         {"2024-01-01 00:00:00", %{"count" => 1, "v" => 0.0}},
         {"2024-01-01 00:00:00", %{"count" => 3, "v" => 1.0}},
         {"2024-01-01 00:00:00", %{"count" => 3, "v" => 2.0}},
         {"2024-01-01 00:00:00", %{"count" => 1, "v" => 2.25}},
         {"2024-01-01 00:00:00", %{"count" => 1, "v" => 3.0}},
         {"2024-01-01 00:00:00", %{"count" => 2, "v" => 4.0}},
         {"2024-01-01 00:00:00", %{"count" => 2, "v" => 5.0}},
         {"2024-01-01 00:00:00", %{"count" => 1, "v" => 8.0}},
         {"2024-01-01 00:00:00", %{"count" => 1, "v" => 9.0}},
         {"2024-01-01 00:00:00", %{"count" => 2, "v" => 10.0}},
         {"2024-01-01 00:00:00", %{"count" => 2, "v" => 15.0}},
         {"2024-01-01 00:00:00", %{"count" => 1, "v" => 16.0}},
         {"2024-01-01 00:00:00", %{"count" => 2, "v" => 20.0}},
         {"2024-01-01 00:00:00", %{"count" => 1, "v" => 40.0}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(2m, 1m)",
       [
         {"2023-12-31 23:59:00", %{"count" => 8}},
         {"2024-01-01 00:01:00", %{"count" => 10}},
         {"2024-01-01 00:03:00", %{"count" => 6}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(2m, -1m)",
       [
         {"2023-12-31 23:59:00", %{"count" => 8}},
         {"2024-01-01 00:01:00", %{"count" => 10}},
         {"2024-01-01 00:03:00", %{"count" => 6}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1h30m)",
       [{"2024-01-01 00:00:00", %{"count" => 24}}]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill( previous )",
       [
         {"2024-01-01 00:00:00", %{"mean" => 4.3125}},
         {"2024-01-01 00:01:00", %{"mean" => 8.464285714285714}},
         {"2024-01-01 00:02:00", %{"mean" => 16.333333333333332}},
         {"2024-01-01 00:03:00", %{"mean" => 6.666666666666667}},
         {"2024-01-01 00:04:00", %{"mean" => 10.0}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) FILL(NONE)",
       [
         {"2024-01-01 00:00:00", %{"mean" => 4.3125}},
         {"2024-01-01 00:01:00", %{"mean" => 8.464285714285714}},
         {"2024-01-01 00:02:00", %{"mean" => 16.333333333333332}},
         {"2024-01-01 00:03:00", %{"mean" => 6.666666666666667}},
         {"2024-01-01 00:04:00", %{"mean" => 10.0}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(+1)",
       [
         {"2024-01-01 00:00:00", %{"mean" => 4.3125}},
         {"2024-01-01 00:01:00", %{"mean" => 8.464285714285714}},
         {"2024-01-01 00:02:00", %{"mean" => 16.333333333333332}},
         {"2024-01-01 00:03:00", %{"mean" => 6.666666666666667}},
         {"2024-01-01 00:04:00", %{"mean" => 10.0}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(-.5)",
       [
         {"2024-01-01 00:00:00", %{"mean" => 4.3125}},
         {"2024-01-01 00:01:00", %{"mean" => 8.464285714285714}},
         {"2024-01-01 00:02:00", %{"mean" => 16.333333333333332}},
         {"2024-01-01 00:03:00", %{"mean" => 6.666666666666667}},
         {"2024-01-01 00:04:00", %{"mean" => 10.0}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host fill(none)",
       [
         {"2024-01-01 00:00:00", %{"host" => "a", "mean" => 4.0}},
         {"2024-01-01 00:00:00", %{"host" => "b", "mean" => 20.0}},
         {"2024-01-01 00:00:00", %{"host" => "c", "mean" => 7.4}},
         {"2024-01-01 00:00:00", %{"host" => "d", "mean" => 3.9375}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' fill(none)",
       [{"2024-01-01 00:00:00", %{"mean" => 8.03125}}]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(9223372036854775807)",
       [
         {"2024-01-01 00:00:00", %{"mean" => 4.3125}},
         {"2024-01-01 00:01:00", %{"mean" => 8.464285714285714}},
         {"2024-01-01 00:02:00", %{"mean" => 16.333333333333332}},
         {"2024-01-01 00:03:00", %{"mean" => 6.666666666666667}},
         {"2024-01-01 00:04:00", %{"mean" => 10.0}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(99999999999999999999.5)",
       [
         {"2024-01-01 00:00:00", %{"mean" => 4.3125}},
         {"2024-01-01 00:01:00", %{"mean" => 8.464285714285714}},
         {"2024-01-01 00:02:00", %{"mean" => 16.333333333333332}},
         {"2024-01-01 00:03:00", %{"mean" => 6.666666666666667}},
         {"2024-01-01 00:04:00", %{"mean" => 10.0}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2025-01-01T00:00:00Z' AND time < '2025-01-01T00:00:00.000001Z' GROUP BY time(1ns)",
       []},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2025-01-01T00:00:00Z' AND time < '2025-01-01T00:00:01Z' GROUP BY time(-5m)",
       []},
      {"SELECT mean(v) FROM nosuch GROUP BY time(1u)", []},
      {"SELECT mean(v) FROM ~k1 /* a comment */ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"mean" => 8.03125}}]},
      {"SELECT/*c*/mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"mean" => 8.03125}}]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' /* x -- */ GROUP BY host",
       [
         {"2024-01-01 00:00:00", %{"host" => "a", "mean" => 4.0}},
         {"2024-01-01 00:00:00", %{"host" => "b", "mean" => 20.0}},
         {"2024-01-01 00:00:00", %{"host" => "c", "mean" => 7.4}},
         {"2024-01-01 00:00:00", %{"host" => "d", "mean" => 3.9375}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' -- x /* y\n GROUP BY host",
       [
         {"2024-01-01 00:00:00", %{"host" => "a", "mean" => 4.0}},
         {"2024-01-01 00:00:00", %{"host" => "b", "mean" => 20.0}},
         {"2024-01-01 00:00:00", %{"host" => "c", "mean" => 7.4}},
         {"2024-01-01 00:00:00", %{"host" => "d", "mean" => 3.9375}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE host =~ /a/ AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"mean" => 4.0}}]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' tz('UTC')",
       [{"2024-01-01 00:00:00", %{"mean" => 8.03125}}]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host LIMIT 1 tz('UTC')",
       [
         {"2024-01-01 00:00:00", %{"host" => "a", "mean" => 4.0}},
         {"2024-01-01 00:00:00", %{"host" => "b", "mean" => 20.0}},
         {"2024-01-01 00:00:00", %{"host" => "c", "mean" => 7.4}},
         {"2024-01-01 00:00:00", %{"host" => "d", "mean" => 3.9375}}
       ]},
      {"SELECT v FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' SLIMIT 1",
       {:error, 405,
        "rewriting statement\ncaused by\nThis feature is not implemented: SLIMIT or SOFFSET"}},
      {"SELECT v FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' LIMIT 1 SOFFSET 1",
       {:error, 405,
        "rewriting statement\ncaused by\nThis feature is not implemented: SLIMIT or SOFFSET"}},
      {"SELECT v FROM ~k1 WHERE host =~ /(?=a)a/ AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 500,
        "Invalid regex\ncaused by\nExternal error: regex parse error:\n    (?=a)a\n    ^^^\nerror: look-around, including look-ahead and look-behind, is not supported"}},
      {"SELECT v FROM ~k1 WHERE host =~ /xy(?<!a)b/ AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 500,
        "Invalid regex\ncaused by\nExternal error: regex parse error:\n    xy(?<!a)b\n      ^^^^\nerror: look-around, including look-ahead and look-behind, is not supported"}},
      {"SELECT v FROM ~k1 WHERE host =~ /a(?>b)c/ AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 500,
        "Invalid regex\ncaused by\nExternal error: regex parse error:\n    a(?>b)c\n       ^\nerror: unrecognized flag"}},
      {"SELECT v FROM ~k1 WHERE host !~ /(?!a)/ AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 500,
        "Invalid regex\ncaused by\nExternal error: regex parse error:\n    (?!a)\n    ^^^\nerror: look-around, including look-ahead and look-behind, is not supported"}},
      {"SELECT v FROM ~k1 WHERE host =~ /a\\\\b(?=c)/ AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 500,
        "Invalid regex\ncaused by\nExternal error: regex parse error:\n    a\\\\b(?=c)\n        ^^^\nerror: look-around, including look-ahead and look-behind, is not supported"}}
    ]
  end

  @doc false
  @spec fills() :: [{binary(), term()}]
  def fills do
    [
      {"SELECT count(c) FROM ~k1 WHERE time >= '2024-01-01T00:02:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:02:00", %{"count" => 3}},
         {"2024-01-01 00:03:00", %{"count" => 3}},
         {"2024-01-01 00:04:00", %{"count" => 3}}
       ]},
      {"SELECT count(s) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"count" => 2}},
         {"2024-01-01 00:01:00", %{"count" => 2}},
         {"2024-01-01 00:02:00", %{"count" => 2}},
         {"2024-01-01 00:03:00", %{"count" => 2}},
         {"2024-01-01 00:04:00", %{"count" => 2}}
       ]},
      {"SELECT mean(c), count(c) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"count" => 8, "mean" => 14.0}},
         {"2024-01-01 00:01:00", %{"count" => 7, "mean" => 83.42857142857143}},
         {"2024-01-01 00:02:00", %{"count" => 3, "mean" => 161.66666666666666}},
         {"2024-01-01 00:03:00", %{"count" => 3, "mean" => 26.666666666666668}},
         {"2024-01-01 00:04:00", %{"count" => 3, "mean" => 35.0}}
       ]},
      {"SELECT mean(c) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:01:30Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(previous)",
       [
         {"2024-01-01 00:01:30", %{}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:02:30", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:03:30", %{"mean" => 5.0}},
         {"2024-01-01 00:04:00", %{"mean" => 50.0}},
         {"2024-01-01 00:04:30", %{"mean" => 50.0}}
       ]},
      {"SELECT last(s) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"last" => "s1"}},
         {"2024-01-01 00:01:00", %{"last" => "s0"}},
         {"2024-01-01 00:02:00", %{"last" => "s2"}},
         {"2024-01-01 00:03:00", %{"last" => "s1"}},
         {"2024-01-01 00:04:00", %{"last" => "s0"}}
       ]},
      {"SELECT last(b) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"last" => false}},
         {"2024-01-01 00:01:00", %{"last" => false}},
         {"2024-01-01 00:02:00", %{"last" => false}},
         {"2024-01-01 00:03:00", %{"last" => false}},
         {"2024-01-01 00:04:00", %{"last" => false}}
       ]},
      {"SELECT last(b) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"last" => false}},
         {"2024-01-01 00:01:00", %{"last" => false}},
         {"2024-01-01 00:02:00", %{"last" => false}},
         {"2024-01-01 00:03:00", %{"last" => false}},
         {"2024-01-01 00:04:00", %{"last" => false}}
       ]},
      {"SELECT last(b) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(0)",
       {:error, 500, "External error: InfluxQL internal error: no conversion from 0 to Boolean"}},
      {"SELECT last(b) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(2.0)",
       {:error, 500, "External error: InfluxQL internal error: no conversion from 2 to Boolean"}},
      {"SELECT last(s) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(-0.25)",
       {:error, 500, "External error: InfluxQL internal error: no conversion from -0.25 to Utf8"}},
      {"SELECT count(s) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(linear)",
       [
         {"2024-01-01 00:00:00", %{"count" => 2}},
         {"2024-01-01 00:01:00", %{"count" => 2}},
         {"2024-01-01 00:02:00", %{"count" => 2}},
         {"2024-01-01 00:03:00", %{"count" => 2}},
         {"2024-01-01 00:04:00", %{"count" => 2}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2000-01-01T00:00:00Z' AND time < '2024-01-01T00:02:00Z' GROUP BY time(1s) fill(none) LIMIT 3",
       [
         {"2024-01-01 00:00:00", %{"mean" => 1.0}},
         {"2024-01-01 00:00:05", %{"mean" => 10.0}},
         {"2024-01-01 00:00:10", %{"mean" => 1.0}}
       ]},
      {"SELECT mean(v) FROM ~k1 WHERE time >= '2000-01-01T00:00:00Z' AND time < '2024-01-01T00:02:00Z' GROUP BY time(1s) fill(none) ORDER BY time DESC LIMIT 2",
       [{"2024-01-01 00:01:45", %{"mean" => 16.0}}, {"2024-01-01 00:01:35", %{"mean" => 15.0}}]}
    ]
  end

  @doc false
  @spec transforms() :: [{binary(), term()}]
  def transforms do
    [
      {"SELECT derivative(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 0.06666666666666667}},
         {"2024-01-01 00:01:00", %{"derivative" => -0.03333333333333333}},
         {"2024-01-01 00:01:30", %{"derivative" => 0.1}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"derivative" => -0.03333333333333333}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.16666666666666666}},
         {"2024-01-01 00:03:30", %{"derivative" => -0.26666666666666666}},
         {"2024-01-01 00:04:00", %{"derivative" => 0.03333333333333333}},
         {"2024-01-01 00:04:30", %{"derivative" => 0.2}}
       ]},
      {"SELECT derivative(v, 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 4.0}},
         {"2024-01-01 00:01:00", %{"derivative" => -2.0}},
         {"2024-01-01 00:01:30", %{"derivative" => 6.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"derivative" => -2.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 10.0}},
         {"2024-01-01 00:03:30", %{"derivative" => -16.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 2.0}},
         {"2024-01-01 00:04:30", %{"derivative" => 12.0}}
       ]},
      {"SELECT derivative(v, 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' ORDER BY time DESC",
       [
         {"2024-01-01 00:04:00", %{"derivative" => 12.0}},
         {"2024-01-01 00:03:30", %{"derivative" => 2.0}},
         {"2024-01-01 00:03:00", %{"derivative" => -16.0}},
         {"2024-01-01 00:02:30", %{"derivative" => 10.0}},
         {"2024-01-01 00:02:00", %{"derivative" => -2.0}},
         {"2024-01-01 00:01:30", %{"derivative" => -0.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 6.0}},
         {"2024-01-01 00:00:30", %{"derivative" => -2.0}},
         {"2024-01-01 00:00:00", %{"derivative" => 4.0}}
       ]},
      {"SELECT derivative(v, 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' LIMIT 2",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 4.0}},
         {"2024-01-01 00:01:00", %{"derivative" => -2.0}}
       ]},
      {"SELECT derivative(v, 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' LIMIT 2 OFFSET 2",
       [
         {"2024-01-01 00:01:30", %{"derivative" => 6.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}}
       ]},
      {"SELECT derivative(c) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 0.3333333333333333, "host" => "a"}},
         {"2024-01-01 00:01:00", %{"derivative" => 0.3333333333333333, "host" => "a"}},
         {"2024-01-01 00:01:30", %{"derivative" => 0.5, "host" => "a"}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0, "host" => "a"}},
         {"2024-01-01 00:02:30", %{"derivative" => 0.5, "host" => "a"}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.6666666666666666, "host" => "a"}},
         {"2024-01-01 00:03:30", %{"derivative" => -2.1666666666666665, "host" => "a"}},
         {"2024-01-01 00:04:00", %{"derivative" => 0.3333333333333333, "host" => "a"}},
         {"2024-01-01 00:04:30", %{"derivative" => 0.8333333333333334, "host" => "a"}},
         {"2024-01-01 00:00:35", %{"derivative" => 3.3333333333333335, "host" => "b"}},
         {"2024-01-01 00:01:05", %{"derivative" => 3.3333333333333335, "host" => "b"}},
         {"2024-01-01 00:01:35", %{"derivative" => 3.3333333333333335, "host" => "b"}},
         {"2024-01-01 00:02:05", %{"derivative" => 3.3333333333333335, "host" => "b"}},
         {"2024-01-01 00:00:40", %{"derivative" => 0.1, "host" => "c"}},
         {"2024-01-01 00:01:10", %{"derivative" => 0.16666666666666666, "host" => "c"}},
         {"2024-01-01 00:03:40", %{"derivative" => -0.02666666666666667, "host" => "c"}},
         {"2024-01-01 00:04:10", %{"derivative" => 1.5, "host" => "c"}},
         {"2024-01-01 00:00:45", %{"derivative" => 0.1, "host" => "d"}},
         {"2024-01-01 00:01:15", %{"derivative" => 0.13333333333333333, "host" => "d"}},
         {"2024-01-01 00:01:45", %{"derivative" => 0.4, "host" => "d"}}
       ]},
      {"SELECT non_negative_derivative(c, 1s) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:30", %{"non_negative_derivative" => 0.3333333333333333}},
         {"2024-01-01 00:01:00", %{"non_negative_derivative" => 0.3333333333333333}},
         {"2024-01-01 00:01:30", %{"non_negative_derivative" => 0.5}},
         {"2024-01-01 00:02:00", %{"non_negative_derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"non_negative_derivative" => 0.5}},
         {"2024-01-01 00:03:00", %{"non_negative_derivative" => 0.6666666666666666}},
         {"2024-01-01 00:04:00", %{"non_negative_derivative" => 0.3333333333333333}},
         {"2024-01-01 00:04:30", %{"non_negative_derivative" => 0.8333333333333334}}
       ]},
      {"SELECT non_negative_derivative(c, 1m) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host",
       [
         {"2024-01-01 00:00:30", %{"host" => "a", "non_negative_derivative" => 20.0}},
         {"2024-01-01 00:01:00", %{"host" => "a", "non_negative_derivative" => 20.0}},
         {"2024-01-01 00:01:30", %{"host" => "a", "non_negative_derivative" => 30.0}},
         {"2024-01-01 00:02:00", %{"host" => "a", "non_negative_derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"host" => "a", "non_negative_derivative" => 30.0}},
         {"2024-01-01 00:03:00", %{"host" => "a", "non_negative_derivative" => 40.0}},
         {"2024-01-01 00:04:00", %{"host" => "a", "non_negative_derivative" => 20.0}},
         {"2024-01-01 00:04:30", %{"host" => "a", "non_negative_derivative" => 50.0}},
         {"2024-01-01 00:00:35", %{"host" => "b", "non_negative_derivative" => 200.0}},
         {"2024-01-01 00:01:05", %{"host" => "b", "non_negative_derivative" => 200.0}},
         {"2024-01-01 00:01:35", %{"host" => "b", "non_negative_derivative" => 200.0}},
         {"2024-01-01 00:02:05", %{"host" => "b", "non_negative_derivative" => 200.0}},
         {"2024-01-01 00:00:40", %{"host" => "c", "non_negative_derivative" => 6.0}},
         {"2024-01-01 00:01:10", %{"host" => "c", "non_negative_derivative" => 10.0}},
         {"2024-01-01 00:04:10", %{"host" => "c", "non_negative_derivative" => 90.0}},
         {"2024-01-01 00:00:45", %{"host" => "d", "non_negative_derivative" => 6.0}},
         {"2024-01-01 00:01:15", %{"host" => "d", "non_negative_derivative" => 8.0}},
         {"2024-01-01 00:01:45", %{"host" => "d", "non_negative_derivative" => 24.0}}
       ]},
      {"SELECT difference(c) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:30", %{"difference" => 10}},
         {"2024-01-01 00:01:00", %{"difference" => 10}},
         {"2024-01-01 00:01:30", %{"difference" => 15}},
         {"2024-01-01 00:02:00", %{"difference" => 0}},
         {"2024-01-01 00:02:30", %{"difference" => 15}},
         {"2024-01-01 00:03:00", %{"difference" => 20}},
         {"2024-01-01 00:03:30", %{"difference" => -65}},
         {"2024-01-01 00:04:00", %{"difference" => 10}},
         {"2024-01-01 00:04:30", %{"difference" => 25}}
       ]},
      {"SELECT difference(v) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:45", %{"difference" => 2.5}},
         {"2024-01-01 00:01:15", %{"difference" => 2.25}},
         {"2024-01-01 00:01:45", %{"difference" => 13.75}}
       ]},
      {"SELECT non_negative_difference(c) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:30", %{"non_negative_difference" => 10}},
         {"2024-01-01 00:01:00", %{"non_negative_difference" => 10}},
         {"2024-01-01 00:01:30", %{"non_negative_difference" => 15}},
         {"2024-01-01 00:02:00", %{"non_negative_difference" => 0}},
         {"2024-01-01 00:02:30", %{"non_negative_difference" => 15}},
         {"2024-01-01 00:03:00", %{"non_negative_difference" => 20}},
         {"2024-01-01 00:04:00", %{"non_negative_difference" => 10}},
         {"2024-01-01 00:04:30", %{"non_negative_difference" => 25}}
       ]},
      {"SELECT cumulative_sum(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"cumulative_sum" => 1.0}},
         {"2024-01-01 00:00:30", %{"cumulative_sum" => 4.0}},
         {"2024-01-01 00:01:00", %{"cumulative_sum" => 6.0}},
         {"2024-01-01 00:01:30", %{"cumulative_sum" => 11.0}},
         {"2024-01-01 00:02:00", %{"cumulative_sum" => 16.0}},
         {"2024-01-01 00:02:30", %{"cumulative_sum" => 20.0}},
         {"2024-01-01 00:03:00", %{"cumulative_sum" => 29.0}},
         {"2024-01-01 00:03:30", %{"cumulative_sum" => 30.0}},
         {"2024-01-01 00:04:00", %{"cumulative_sum" => 32.0}},
         {"2024-01-01 00:04:30", %{"cumulative_sum" => 40.0}}
       ]},
      {"SELECT cumulative_sum(c) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:10", %{"cumulative_sum" => 1}},
         {"2024-01-01 00:00:40", %{"cumulative_sum" => 5}},
         {"2024-01-01 00:01:10", %{"cumulative_sum" => 14}},
         {"2024-01-01 00:03:40", %{"cumulative_sum" => 19}},
         {"2024-01-01 00:04:10", %{"cumulative_sum" => 69}}
       ]},
      {"SELECT moving_average(v, 3) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:01:00", %{"moving_average" => 2.0}},
         {"2024-01-01 00:01:30", %{"moving_average" => 3.3333333333333335}},
         {"2024-01-01 00:02:00", %{"moving_average" => 4.0}},
         {"2024-01-01 00:02:30", %{"moving_average" => 4.666666666666667}},
         {"2024-01-01 00:03:00", %{"moving_average" => 6.0}},
         {"2024-01-01 00:03:30", %{"moving_average" => 4.666666666666667}},
         {"2024-01-01 00:04:00", %{"moving_average" => 4.0}},
         {"2024-01-01 00:04:30", %{"moving_average" => 3.6666666666666665}}
       ]},
      {"SELECT moving_average(c, 2) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:40", %{"moving_average" => 2.5}},
         {"2024-01-01 00:01:10", %{"moving_average" => 6.5}},
         {"2024-01-01 00:03:40", %{"moving_average" => 7.0}},
         {"2024-01-01 00:04:10", %{"moving_average" => 27.5}}
       ]},
      {"SELECT moving_average(v, 20) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT elapsed(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"elapsed" => 0}},
         {"2024-01-01 00:00:30", %{"elapsed" => 30_000_000_000}},
         {"2024-01-01 00:01:00", %{"elapsed" => 30_000_000_000}},
         {"2024-01-01 00:01:30", %{"elapsed" => 30_000_000_000}},
         {"2024-01-01 00:02:00", %{"elapsed" => 30_000_000_000}},
         {"2024-01-01 00:02:30", %{"elapsed" => 30_000_000_000}},
         {"2024-01-01 00:03:00", %{"elapsed" => 30_000_000_000}},
         {"2024-01-01 00:03:30", %{"elapsed" => 30_000_000_000}},
         {"2024-01-01 00:04:00", %{"elapsed" => 30_000_000_000}},
         {"2024-01-01 00:04:30", %{"elapsed" => 30_000_000_000}}
       ]},
      {"SELECT elapsed(v, 1s) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:10", %{"elapsed" => 0}},
         {"2024-01-01 00:00:40", %{"elapsed" => 30}},
         {"2024-01-01 00:01:10", %{"elapsed" => 30}},
         {"2024-01-01 00:03:40", %{"elapsed" => 150}},
         {"2024-01-01 00:04:10", %{"elapsed" => 30}}
       ]},
      {"SELECT elapsed(v, 1m) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:10", %{"elapsed" => 0}},
         {"2024-01-01 00:00:40", %{"elapsed" => 0}},
         {"2024-01-01 00:01:10", %{"elapsed" => 0}},
         {"2024-01-01 00:03:40", %{"elapsed" => 2}},
         {"2024-01-01 00:04:10", %{"elapsed" => 0}}
       ]},
      {"SELECT difference(v), cumulative_sum(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"cumulative_sum" => 1.0}},
         {"2024-01-01 00:00:30", %{"cumulative_sum" => 4.0, "difference" => 2.0}},
         {"2024-01-01 00:01:00", %{"cumulative_sum" => 6.0, "difference" => -1.0}},
         {"2024-01-01 00:01:30", %{"cumulative_sum" => 11.0, "difference" => 3.0}},
         {"2024-01-01 00:02:00", %{"cumulative_sum" => 16.0, "difference" => 0.0}},
         {"2024-01-01 00:02:30", %{"cumulative_sum" => 20.0, "difference" => -1.0}},
         {"2024-01-01 00:03:00", %{"cumulative_sum" => 29.0, "difference" => 5.0}},
         {"2024-01-01 00:03:30", %{"cumulative_sum" => 30.0, "difference" => -8.0}},
         {"2024-01-01 00:04:00", %{"cumulative_sum" => 32.0, "difference" => 1.0}},
         {"2024-01-01 00:04:30", %{"cumulative_sum" => 40.0, "difference" => 6.0}}
       ]},
      {"SELECT difference(v), derivative(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' LIMIT 3",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 0.06666666666666667, "difference" => 2.0}},
         {"2024-01-01 00:01:00", %{"derivative" => -0.03333333333333333, "difference" => -1.0}},
         {"2024-01-01 00:01:30", %{"derivative" => 0.1, "difference" => 3.0}}
       ]},
      {"SELECT difference(v), difference(c) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' LIMIT 3",
       [
         {"2024-01-01 00:00:30", %{"difference" => 2.0, "difference_1" => 10}},
         {"2024-01-01 00:01:00", %{"difference" => -1.0, "difference_1" => 10}},
         {"2024-01-01 00:01:30", %{"difference" => 3.0, "difference_1" => 15}}
       ]},
      {"SELECT abs(difference(v)) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:30", %{"abs" => 2.0}},
         {"2024-01-01 00:01:00", %{"abs" => 1.0}},
         {"2024-01-01 00:01:30", %{"abs" => 3.0}},
         {"2024-01-01 00:02:00", %{"abs" => 0.0}},
         {"2024-01-01 00:02:30", %{"abs" => 1.0}},
         {"2024-01-01 00:03:00", %{"abs" => 5.0}},
         {"2024-01-01 00:03:30", %{"abs" => 8.0}},
         {"2024-01-01 00:04:00", %{"abs" => 1.0}},
         {"2024-01-01 00:04:30", %{"abs" => 6.0}}
       ]},
      {"SELECT difference(c) * 2 FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:30", %{"difference" => 20}},
         {"2024-01-01 00:01:00", %{"difference" => 20}},
         {"2024-01-01 00:01:30", %{"difference" => 30}},
         {"2024-01-01 00:02:00", %{"difference" => 0}},
         {"2024-01-01 00:02:30", %{"difference" => 30}},
         {"2024-01-01 00:03:00", %{"difference" => 40}},
         {"2024-01-01 00:03:30", %{"difference" => -130}},
         {"2024-01-01 00:04:00", %{"difference" => 20}},
         {"2024-01-01 00:04:30", %{"difference" => 50}}
       ]},
      {"SELECT derivative(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:05", %{"derivative" => 1.8}},
         {"2024-01-01 00:00:10", %{"derivative" => -1.8}},
         {"2024-01-01 00:00:15", %{"derivative" => -0.7}},
         {"2024-01-01 00:00:30", %{"derivative" => 0.36666666666666664}},
         {"2024-01-01 00:00:35", %{"derivative" => 3.4}},
         {"2024-01-01 00:00:40", %{"derivative" => -3.6}},
         {"2024-01-01 00:00:45", %{"derivative" => -0.4}},
         {"2024-01-01 00:01:00", %{"derivative" => 0.13333333333333333}},
         {"2024-01-01 00:01:05", %{"derivative" => 2.6}},
         {"2024-01-01 00:01:10", %{"derivative" => -2.2}},
         {"2024-01-01 00:01:15", %{"derivative" => -0.35}},
         {"2024-01-01 00:01:30", %{"derivative" => 0.18333333333333332}},
         {"2024-01-01 00:01:35", %{"derivative" => 2.0}},
         {"2024-01-01 00:01:45", %{"derivative" => 0.1}},
         {"2024-01-01 00:02:00", %{"derivative" => -0.7333333333333333}},
         {"2024-01-01 00:02:05", %{"derivative" => 7.0}},
         {"2024-01-01 00:02:30", %{"derivative" => -1.44}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.16666666666666666}},
         {"2024-01-01 00:03:30", %{"derivative" => -0.26666666666666666}},
         {"2024-01-01 00:03:40", %{"derivative" => 0.9}},
         {"2024-01-01 00:04:00", %{"derivative" => -0.4}},
         {"2024-01-01 00:04:10", %{"derivative" => 1.8}},
         {"2024-01-01 00:04:30", %{"derivative" => -0.6}}
       ]},
      {"SELECT derivative(nosuch) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT derivative(v), v FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:01:00", %{"derivative" => 1.5}},
         {"2024-01-01 00:02:00", %{"derivative" => 1.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.5}},
         {"2024-01-01 00:04:00", %{"derivative" => 0.0}}
       ]},
      {"SELECT derivative(mean(v)) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:01:00", %{"derivative" => 1.5}},
         {"2024-01-01 00:02:00", %{"derivative" => 1.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.5}},
         {"2024-01-01 00:04:00", %{"derivative" => 0.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) ORDER BY time DESC",
       [
         {"2024-01-01 00:03:00", %{"derivative" => -0.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.5}},
         {"2024-01-01 00:01:00", %{"derivative" => 1.0}},
         {"2024-01-01 00:00:00", %{"derivative" => 1.5}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) LIMIT 2",
       [
         {"2024-01-01 00:01:00", %{"derivative" => 1.5}},
         {"2024-01-01 00:02:00", %{"derivative" => 1.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"derivative" => 2.0}},
         {"2024-01-01 00:00:30", %{"derivative" => 4.0}},
         {"2024-01-01 00:01:00", %{"derivative" => -2.0}},
         {"2024-01-01 00:01:30", %{"derivative" => 6.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"derivative" => -2.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 10.0}},
         {"2024-01-01 00:03:30", %{"derivative" => -16.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 2.0}},
         {"2024-01-01 00:04:30", %{"derivative" => 12.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(previous)",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 4.0}},
         {"2024-01-01 00:01:00", %{"derivative" => -2.0}},
         {"2024-01-01 00:01:30", %{"derivative" => 6.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"derivative" => -2.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 10.0}},
         {"2024-01-01 00:03:30", %{"derivative" => -16.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 2.0}},
         {"2024-01-01 00:04:30", %{"derivative" => 12.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(none)",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 4.0}},
         {"2024-01-01 00:01:00", %{"derivative" => -2.0}},
         {"2024-01-01 00:01:30", %{"derivative" => 6.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"derivative" => -2.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 10.0}},
         {"2024-01-01 00:03:30", %{"derivative" => -16.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 2.0}},
         {"2024-01-01 00:04:30", %{"derivative" => 12.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 2.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 4.0}},
         {"2024-01-01 00:03:30", %{"derivative" => 2.4}},
         {"2024-01-01 00:04:00", %{"derivative" => 20.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(5)",
       [
         {"2024-01-01 00:00:00", %{"derivative" => -8.0}},
         {"2024-01-01 00:00:30", %{"derivative" => 2.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 4.0}},
         {"2024-01-01 00:01:30", %{"derivative" => 2.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"derivative" => 0.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:03:30", %{"derivative" => 10.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 20.0}},
         {"2024-01-01 00:04:30", %{"derivative" => -30.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(previous)",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 2.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 4.0}},
         {"2024-01-01 00:01:30", %{"derivative" => 0.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"derivative" => 0.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:03:30", %{"derivative" => 12.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 20.0}},
         {"2024-01-01 00:04:30", %{"derivative" => 0.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(linear)",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 2.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 4.0}},
         {"2024-01-01 00:01:30", %{"derivative" => 2.4000000000000004}},
         {"2024-01-01 00:02:00", %{"derivative" => 2.4000000000000004}},
         {"2024-01-01 00:02:30", %{"derivative" => 2.3999999999999986}},
         {"2024-01-01 00:03:00", %{"derivative" => 2.400000000000002}},
         {"2024-01-01 00:03:30", %{"derivative" => 2.3999999999999986}},
         {"2024-01-01 00:04:00", %{"derivative" => 20.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(none)",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 2.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 4.0}},
         {"2024-01-01 00:03:30", %{"derivative" => 2.4}},
         {"2024-01-01 00:04:00", %{"derivative" => 20.0}}
       ]},
      {"SELECT derivative(mean(v), 30s) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:10Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(100)",
       [
         {"2024-01-01 00:00:00", %{"derivative" => -99.0}},
         {"2024-01-01 00:00:30", %{"derivative" => 1.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 2.0}},
         {"2024-01-01 00:01:30", %{"derivative" => 96.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"derivative" => 0.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:03:30", %{"derivative" => -90.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 10.0}},
         {"2024-01-01 00:04:30", %{"derivative" => 80.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m), host",
       [
         {"2024-01-01 00:01:00", %{"derivative" => 1.5, "host" => "a"}},
         {"2024-01-01 00:02:00", %{"derivative" => 1.0, "host" => "a"}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.5, "host" => "a"}},
         {"2024-01-01 00:04:00", %{"derivative" => 0.0, "host" => "a"}},
         {"2024-01-01 00:01:00", %{"derivative" => 0.0, "host" => "b"}},
         {"2024-01-01 00:02:00", %{"derivative" => 25.0, "host" => "b"}},
         {"2024-01-01 00:01:00", %{"derivative" => 2.5, "host" => "c"}},
         {"2024-01-01 00:03:00", %{"derivative" => 3.0, "host" => "c"}},
         {"2024-01-01 00:04:00", %{"derivative" => 10.0, "host" => "c"}},
         {"2024-01-01 00:01:00", %{"derivative" => 10.375, "host" => "d"}}
       ]},
      {"SELECT derivative(sum(c), 1m) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m), host",
       [
         {"2024-01-01 00:01:00", %{"derivative" => 45.0, "host" => "a"}},
         {"2024-01-01 00:02:00", %{"derivative" => 30.0, "host" => "a"}},
         {"2024-01-01 00:03:00", %{"derivative" => -10.0, "host" => "a"}},
         {"2024-01-01 00:04:00", %{"derivative" => -20.0, "host" => "a"}},
         {"2024-01-01 00:01:00", %{"derivative" => 400.0, "host" => "b"}},
         {"2024-01-01 00:02:00", %{"derivative" => -100.0, "host" => "b"}},
         {"2024-01-01 00:01:00", %{"derivative" => 4.0, "host" => "c"}},
         {"2024-01-01 00:03:00", %{"derivative" => -2.0, "host" => "c"}},
         {"2024-01-01 00:04:00", %{"derivative" => 45.0, "host" => "c"}},
         {"2024-01-01 00:01:00", %{"derivative" => 23.0, "host" => "d"}}
       ]},
      {"SELECT derivative(max(v), 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:01:00", %{"derivative" => 2.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 4.0}},
         {"2024-01-01 00:04:00", %{"derivative" => -1.0}}
       ]},
      {"SELECT derivative(count(v), 1m) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:00", %{"derivative" => 2.0}},
         {"2024-01-01 00:00:30", %{"derivative" => 0.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:01:30", %{"derivative" => -2.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"derivative" => 0.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:03:30", %{"derivative" => 2.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 0.0}},
         {"2024-01-01 00:04:30", %{"derivative" => -2.0}}
       ]},
      {"SELECT derivative(mean(v), 1m), mean(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"mean" => 2.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 1.5, "mean" => 3.5}},
         {"2024-01-01 00:02:00", %{"derivative" => 1.0, "mean" => 4.5}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.5, "mean" => 5.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 0.0, "mean" => 5.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) * 8 FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:01:00", %{"derivative" => 12.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 8.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 4.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 0.0}}
       ]},
      {"SELECT derivative(mean(v), 1m) AS d FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:01:00", %{"d" => 1.5}},
         {"2024-01-01 00:02:00", %{"d" => 1.0}},
         {"2024-01-01 00:03:00", %{"d" => 0.5}},
         {"2024-01-01 00:04:00", %{"d" => 0.0}}
       ]},
      {"SELECT derivative(mean(v), 1m), derivative(max(v), 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:01:00", %{"derivative" => 1.5, "derivative_1" => 2.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 1.0, "derivative_1" => 0.0}},
         {"2024-01-01 00:03:00", %{"derivative" => 0.5, "derivative_1" => 4.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 0.0, "derivative_1" => -1.0}}
       ]},
      {"SELECT abs(derivative(mean(v), 1m)) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:01:00", %{"abs" => 1.5}},
         {"2024-01-01 00:02:00", %{"abs" => 1.0}},
         {"2024-01-01 00:03:00", %{"abs" => 0.5}},
         {"2024-01-01 00:04:00", %{"abs" => 0.0}}
       ]},
      {"SELECT non_negative_derivative(mean(c), 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:30", %{"non_negative_derivative" => 20.0}},
         {"2024-01-01 00:01:00", %{"non_negative_derivative" => 20.0}},
         {"2024-01-01 00:01:30", %{"non_negative_derivative" => 30.0}},
         {"2024-01-01 00:02:00", %{"non_negative_derivative" => 0.0}},
         {"2024-01-01 00:02:30", %{"non_negative_derivative" => 30.0}},
         {"2024-01-01 00:03:00", %{"non_negative_derivative" => 40.0}},
         {"2024-01-01 00:04:00", %{"non_negative_derivative" => 20.0}},
         {"2024-01-01 00:04:30", %{"non_negative_derivative" => 50.0}}
       ]},
      {"SELECT difference(mean(c)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:30", %{"difference" => 3.0}},
         {"2024-01-01 00:01:00", %{"difference" => 5.0}},
         {"2024-01-01 00:03:30", %{"difference" => -4.0}},
         {"2024-01-01 00:04:00", %{"difference" => 45.0}}
       ]},
      {"SELECT difference(mean(c)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"difference" => 1.0}},
         {"2024-01-01 00:00:30", %{"difference" => 3.0}},
         {"2024-01-01 00:01:00", %{"difference" => 5.0}},
         {"2024-01-01 00:01:30", %{"difference" => -9.0}},
         {"2024-01-01 00:02:00", %{"difference" => 0.0}},
         {"2024-01-01 00:02:30", %{"difference" => 0.0}},
         {"2024-01-01 00:03:00", %{"difference" => 0.0}},
         {"2024-01-01 00:03:30", %{"difference" => 5.0}},
         {"2024-01-01 00:04:00", %{"difference" => 45.0}},
         {"2024-01-01 00:04:30", %{"difference" => -50.0}}
       ]},
      {"SELECT difference(count(v)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:00", %{"difference" => 1}},
         {"2024-01-01 00:00:30", %{"difference" => 0}},
         {"2024-01-01 00:01:00", %{"difference" => 0}},
         {"2024-01-01 00:01:30", %{"difference" => -1}},
         {"2024-01-01 00:02:00", %{"difference" => 0}},
         {"2024-01-01 00:02:30", %{"difference" => 0}},
         {"2024-01-01 00:03:00", %{"difference" => 0}},
         {"2024-01-01 00:03:30", %{"difference" => 1}},
         {"2024-01-01 00:04:00", %{"difference" => 0}},
         {"2024-01-01 00:04:30", %{"difference" => -1}}
       ]},
      {"SELECT difference(count(v)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(none)",
       [
         {"2024-01-01 00:00:30", %{"difference" => 0}},
         {"2024-01-01 00:01:00", %{"difference" => 0}},
         {"2024-01-01 00:03:30", %{"difference" => 0}},
         {"2024-01-01 00:04:00", %{"difference" => 0}}
       ]},
      {"SELECT difference(max(c)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(previous)",
       [
         {"2024-01-01 00:00:30", %{"difference" => 3}},
         {"2024-01-01 00:01:00", %{"difference" => 5}},
         {"2024-01-01 00:01:30", %{"difference" => 0}},
         {"2024-01-01 00:02:00", %{"difference" => 0}},
         {"2024-01-01 00:02:30", %{"difference" => 0}},
         {"2024-01-01 00:03:00", %{"difference" => 0}},
         {"2024-01-01 00:03:30", %{"difference" => -4}},
         {"2024-01-01 00:04:00", %{"difference" => 45}},
         {"2024-01-01 00:04:30", %{"difference" => 0}}
       ]},
      {"SELECT non_negative_difference(sum(c)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:30", %{"non_negative_difference" => 3}},
         {"2024-01-01 00:01:00", %{"non_negative_difference" => 5}},
         {"2024-01-01 00:04:00", %{"non_negative_difference" => 45}}
       ]},
      {"SELECT cumulative_sum(sum(c)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:00", %{"cumulative_sum" => 1}},
         {"2024-01-01 00:00:30", %{"cumulative_sum" => 5}},
         {"2024-01-01 00:01:00", %{"cumulative_sum" => 14}},
         {"2024-01-01 00:03:30", %{"cumulative_sum" => 19}},
         {"2024-01-01 00:04:00", %{"cumulative_sum" => 69}}
       ]},
      {"SELECT cumulative_sum(sum(c)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"cumulative_sum" => 1}},
         {"2024-01-01 00:00:30", %{"cumulative_sum" => 5}},
         {"2024-01-01 00:01:00", %{"cumulative_sum" => 14}},
         {"2024-01-01 00:01:30", %{"cumulative_sum" => 14}},
         {"2024-01-01 00:02:00", %{"cumulative_sum" => 14}},
         {"2024-01-01 00:02:30", %{"cumulative_sum" => 14}},
         {"2024-01-01 00:03:00", %{"cumulative_sum" => 14}},
         {"2024-01-01 00:03:30", %{"cumulative_sum" => 19}},
         {"2024-01-01 00:04:00", %{"cumulative_sum" => 69}},
         {"2024-01-01 00:04:30", %{"cumulative_sum" => 69}}
       ]},
      {"SELECT cumulative_sum(count(v)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(100)",
       [
         {"2024-01-01 00:00:00", %{"cumulative_sum" => 1}},
         {"2024-01-01 00:00:30", %{"cumulative_sum" => 2}},
         {"2024-01-01 00:01:00", %{"cumulative_sum" => 3}},
         {"2024-01-01 00:01:30", %{"cumulative_sum" => 103}},
         {"2024-01-01 00:02:00", %{"cumulative_sum" => 203}},
         {"2024-01-01 00:02:30", %{"cumulative_sum" => 303}},
         {"2024-01-01 00:03:00", %{"cumulative_sum" => 403}},
         {"2024-01-01 00:03:30", %{"cumulative_sum" => 404}},
         {"2024-01-01 00:04:00", %{"cumulative_sum" => 405}},
         {"2024-01-01 00:04:30", %{"cumulative_sum" => 505}}
       ]},
      {"SELECT cumulative_sum(count(v)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:00", %{"cumulative_sum" => 1}},
         {"2024-01-01 00:00:30", %{"cumulative_sum" => 2}},
         {"2024-01-01 00:01:00", %{"cumulative_sum" => 3}},
         {"2024-01-01 00:01:30", %{"cumulative_sum" => 3}},
         {"2024-01-01 00:02:00", %{"cumulative_sum" => 3}},
         {"2024-01-01 00:02:30", %{"cumulative_sum" => 3}},
         {"2024-01-01 00:03:00", %{"cumulative_sum" => 3}},
         {"2024-01-01 00:03:30", %{"cumulative_sum" => 4}},
         {"2024-01-01 00:04:00", %{"cumulative_sum" => 5}},
         {"2024-01-01 00:04:30", %{"cumulative_sum" => 5}}
       ]},
      {"SELECT moving_average(mean(v), 2) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:30", %{"moving_average" => 1.5}},
         {"2024-01-01 00:01:00", %{"moving_average" => 3.0}},
         {"2024-01-01 00:03:30", %{"moving_average" => 7.0}},
         {"2024-01-01 00:04:00", %{"moving_average" => 15.0}}
       ]},
      {"SELECT moving_average(mean(v), 3) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(0)",
       [
         {"2024-01-01 00:00:30", %{"moving_average" => 1.3333333333333333}},
         {"2024-01-01 00:01:00", %{"moving_average" => 2.0}},
         {"2024-01-01 00:01:30", %{"moving_average" => 3.3333333333333335}},
         {"2024-01-01 00:02:00", %{"moving_average" => 4.0}},
         {"2024-01-01 00:02:30", %{"moving_average" => 4.666666666666667}},
         {"2024-01-01 00:03:00", %{"moving_average" => 6.0}},
         {"2024-01-01 00:03:30", %{"moving_average" => 4.666666666666667}},
         {"2024-01-01 00:04:00", %{"moving_average" => 4.0}},
         {"2024-01-01 00:04:30", %{"moving_average" => 3.6666666666666665}}
       ]},
      {"SELECT moving_average(mean(v), 4) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(100)",
       [
         {"2024-01-01 00:01:00", %{"moving_average" => 26.5}},
         {"2024-01-01 00:01:30", %{"moving_average" => 2.75}},
         {"2024-01-01 00:02:00", %{"moving_average" => 3.75}},
         {"2024-01-01 00:02:30", %{"moving_average" => 4.0}},
         {"2024-01-01 00:03:00", %{"moving_average" => 5.75}},
         {"2024-01-01 00:03:30", %{"moving_average" => 4.75}},
         {"2024-01-01 00:04:00", %{"moving_average" => 4.0}},
         {"2024-01-01 00:04:30", %{"moving_average" => 5.0}}
       ]},
      {"SELECT moving_average(count(v), 2) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:00", %{"moving_average" => 0.5}},
         {"2024-01-01 00:00:30", %{"moving_average" => 1.0}},
         {"2024-01-01 00:01:00", %{"moving_average" => 1.0}},
         {"2024-01-01 00:01:30", %{"moving_average" => 0.5}},
         {"2024-01-01 00:02:00", %{"moving_average" => 0.0}},
         {"2024-01-01 00:02:30", %{"moving_average" => 0.0}},
         {"2024-01-01 00:03:00", %{"moving_average" => 0.0}},
         {"2024-01-01 00:03:30", %{"moving_average" => 0.5}},
         {"2024-01-01 00:04:00", %{"moving_average" => 1.0}},
         {"2024-01-01 00:04:30", %{"moving_average" => 0.5}}
       ]},
      {"SELECT derivative(percentile(v, 50), 1m) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:01:00", %{"derivative" => 1.0}},
         {"2024-01-01 00:02:00", %{"derivative" => 2.0}},
         {"2024-01-01 00:03:00", %{"derivative" => -3.0}},
         {"2024-01-01 00:04:00", %{"derivative" => 1.0}}
       ]},
      {"SELECT derivative(first(v), 30s) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 1.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 2.0}},
         {"2024-01-01 00:03:30", %{"derivative" => 1.2}},
         {"2024-01-01 00:04:00", %{"derivative" => 10.0}}
       ]},
      {"SELECT derivative(mean(v), 30s) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:20Z' AND time < '2024-01-01T00:01:30Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 1.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 2.0}}
       ]},
      {"SELECT derivative(mean(v), 30s) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:35Z' AND time < '2024-01-01T00:01:30Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:30", %{"derivative" => 1.0}},
         {"2024-01-01 00:01:00", %{"derivative" => 2.0}}
       ]},
      {"SELECT difference(count(v)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:20Z' AND time < '2024-01-01T00:01:30Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:00", %{"difference" => 1}},
         {"2024-01-01 00:00:30", %{"difference" => 0}},
         {"2024-01-01 00:01:00", %{"difference" => 0}}
       ]},
      {"SELECT cumulative_sum(count(v)) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:20Z' AND time < '2024-01-01T00:01:30Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:00", %{"cumulative_sum" => 0}},
         {"2024-01-01 00:00:30", %{"cumulative_sum" => 1}},
         {"2024-01-01 00:01:00", %{"cumulative_sum" => 2}}
       ]},
      {"SELECT moving_average(mean(v), 3) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:20Z' AND time < '2024-01-01T00:04:30Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:01:00", %{"moving_average" => 2.3333333333333335}},
         {"2024-01-01 00:03:30", %{"moving_average" => 5.333333333333333}},
         {"2024-01-01 00:04:00", %{"moving_average" => 11.333333333333334}}
       ]},
      {"SELECT integral(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"integral" => 1065.0}}]},
      {"SELECT integral(v, 1m) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"integral" => 4.5}}]},
      {"SELECT integral(c, 1ms) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"integral" => 2_145_000.0}}]},
      {"SELECT integral(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:00:01Z'",
       [{"2024-01-01 00:00:00", %{"integral" => 0.0}}]},
      {"SELECT integral(v), mean(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"integral" => 1065.0, "mean" => 4.0}}]},
      {"SELECT integral(v) / 2 FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"integral" => 532.5}}]},
      {"SELECT integral(v) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host",
       [
         {"2024-01-01 00:00:00", %{"host" => "a", "integral" => 1065.0}},
         {"2024-01-01 00:00:00", %{"host" => "b", "integral" => 2250.0}},
         {"2024-01-01 00:00:00", %{"host" => "c", "integral" => 1635.0}},
         {"2024-01-01 00:00:00", %{"host" => "d", "integral" => 270.0}}
       ]}
    ]
  end

  @doc false
  @spec calls() :: [{binary(), term()}]
  def calls do
    [
      {"SELECT percentile(v, 50) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:30", %{"percentile" => 3.0}}]},
      {"SELECT percentile(v, 25) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:01:00", %{"percentile" => 2.0}}]},
      {"SELECT percentile(v, 75) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:02:00", %{"percentile" => 5.0}}]},
      {"SELECT percentile(v, 90) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:04:30", %{"percentile" => 8.0}}]},
      {"SELECT percentile(v, 95) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT percentile(v, 99.9) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT percentile(v, 100) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT percentile(v, 0) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT percentile(v, 33.3) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:01:00", %{"percentile" => 2.0}}]},
      {"SELECT percentile(c, 50) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:01:00", %{"percentile" => 20}}]},
      {"SELECT percentile(s, 50) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:30", %{"percentile" => "s1"}}]},
      {"SELECT percentile(b, 50) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:04:30", %{"percentile" => false}}]},
      {"SELECT percentile(v, 50) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:45", %{"percentile" => 0.0}}]},
      {"SELECT percentile(v, 50) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host",
       [
         {"2024-01-01 00:00:30", %{"host" => "a", "percentile" => 3.0}},
         {"2024-01-01 00:01:35", %{"host" => "b", "percentile" => 15.0}},
         {"2024-01-01 00:01:10", %{"host" => "c", "percentile" => 4.0}},
         {"2024-01-01 00:00:45", %{"host" => "d", "percentile" => 0.0}}
       ]},
      {"SELECT percentile(v, 50) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"percentile" => 1.0}},
         {"2024-01-01 00:01:00", %{"percentile" => 2.0}},
         {"2024-01-01 00:02:00", %{"percentile" => 4.0}},
         {"2024-01-01 00:03:00", %{"percentile" => 1.0}},
         {"2024-01-01 00:04:00", %{"percentile" => 2.0}}
       ]},
      {"SELECT percentile(v, 99) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"percentile" => 3.0}},
         {"2024-01-01 00:01:00", %{"percentile" => 5.0}},
         {"2024-01-01 00:02:00", %{"percentile" => 5.0}},
         {"2024-01-01 00:03:00", %{"percentile" => 9.0}},
         {"2024-01-01 00:04:00", %{"percentile" => 8.0}}
       ]},
      {"SELECT percentile(v, 100) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s)",
       [
         {"2024-01-01 00:00:00", %{"percentile" => 1.0}},
         {"2024-01-01 00:00:30", %{"percentile" => 3.0}},
         {"2024-01-01 00:01:00", %{"percentile" => 2.0}},
         {"2024-01-01 00:01:30", %{"percentile" => 5.0}},
         {"2024-01-01 00:02:00", %{"percentile" => 5.0}},
         {"2024-01-01 00:02:30", %{"percentile" => 4.0}},
         {"2024-01-01 00:03:00", %{"percentile" => 9.0}},
         {"2024-01-01 00:03:30", %{"percentile" => 1.0}},
         {"2024-01-01 00:04:00", %{"percentile" => 2.0}},
         {"2024-01-01 00:04:30", %{"percentile" => 8.0}}
       ]},
      {"SELECT percentile(v, 50) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"percentile" => 1.0}},
         {"2024-01-01 00:01:00", %{"percentile" => 2.0}},
         {"2024-01-01 00:02:00", %{"percentile" => 4.0}},
         {"2024-01-01 00:03:00", %{"percentile" => 1.0}},
         {"2024-01-01 00:04:00", %{"percentile" => 2.0}}
       ]},
      {"SELECT percentile(v, 50) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"percentile" => 1.0}},
         {"2024-01-01 00:01:00", %{"percentile" => 2.0}},
         {"2024-01-01 00:02:00", %{"percentile" => 4.0}},
         {"2024-01-01 00:03:00", %{"percentile" => 1.0}},
         {"2024-01-01 00:04:00", %{"percentile" => 2.0}}
       ]},
      {"SELECT percentile(v, 50), host FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:30", %{"host" => "a", "percentile" => 3.0}}]},
      {"SELECT percentile(v, 50), mean(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"mean" => 4.0, "percentile" => 3.0}}]},
      {"SELECT percentile(v, 50), percentile(v, 90) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"percentile" => 3.0, "percentile_1" => 8.0}}]},
      {"SELECT percentile(v, 50) AS p FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:30", %{"p" => 3.0}}]},
      {"SELECT percentile(v, 50) - min(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"percentile_min" => 2.0}}]},
      {"SELECT percentile(v, 50) FROM nosuch", []},
      {"SELECT mode(c) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"mode" => 35}}]},
      {"SELECT mode(s) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT top(v, 3) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:01:30", %{"top" => 5.0}},
         {"2024-01-01 00:03:00", %{"top" => 9.0}},
         {"2024-01-01 00:04:30", %{"top" => 8.0}}
       ]},
      {"SELECT top(v, 1) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:03:00", %{"top" => 9.0}}]},
      {"SELECT top(v, 20) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"top" => 1.0}},
         {"2024-01-01 00:00:30", %{"top" => 3.0}},
         {"2024-01-01 00:01:00", %{"top" => 2.0}},
         {"2024-01-01 00:01:30", %{"top" => 5.0}},
         {"2024-01-01 00:02:00", %{"top" => 5.0}},
         {"2024-01-01 00:02:30", %{"top" => 4.0}},
         {"2024-01-01 00:03:00", %{"top" => 9.0}},
         {"2024-01-01 00:03:30", %{"top" => 1.0}},
         {"2024-01-01 00:04:00", %{"top" => 2.0}},
         {"2024-01-01 00:04:30", %{"top" => 8.0}}
       ]},
      {"SELECT bottom(v, 3) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"bottom" => 1.0}},
         {"2024-01-01 00:01:00", %{"bottom" => 2.0}},
         {"2024-01-01 00:03:30", %{"bottom" => 1.0}}
       ]},
      {"SELECT top(v, 2) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"top" => 1.0}},
         {"2024-01-01 00:00:30", %{"top" => 3.0}},
         {"2024-01-01 00:01:00", %{"top" => 2.0}},
         {"2024-01-01 00:01:30", %{"top" => 5.0}},
         {"2024-01-01 00:02:00", %{"top" => 5.0}},
         {"2024-01-01 00:02:30", %{"top" => 4.0}},
         {"2024-01-01 00:03:00", %{"top" => 9.0}},
         {"2024-01-01 00:03:30", %{"top" => 1.0}},
         {"2024-01-01 00:04:00", %{"top" => 2.0}},
         {"2024-01-01 00:04:30", %{"top" => 8.0}}
       ]},
      {"SELECT top(v, 2) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"top" => 1.0}},
         {"2024-01-01 00:00:30", %{"top" => 3.0}},
         {"2024-01-01 00:01:00", %{"top" => 2.0}},
         {"2024-01-01 00:01:30", %{"top" => 5.0}},
         {"2024-01-01 00:02:00", %{"top" => 5.0}},
         {"2024-01-01 00:02:30", %{"top" => 4.0}},
         {"2024-01-01 00:03:00", %{"top" => 9.0}},
         {"2024-01-01 00:03:30", %{"top" => 1.0}},
         {"2024-01-01 00:04:00", %{"top" => 2.0}},
         {"2024-01-01 00:04:30", %{"top" => 8.0}}
       ]},
      {"SELECT top(v, 2) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) ORDER BY time DESC",
       [
         {"2024-01-01 00:04:30", %{"top" => 8.0}},
         {"2024-01-01 00:04:00", %{"top" => 2.0}},
         {"2024-01-01 00:03:30", %{"top" => 1.0}},
         {"2024-01-01 00:03:00", %{"top" => 9.0}},
         {"2024-01-01 00:02:30", %{"top" => 4.0}},
         {"2024-01-01 00:02:00", %{"top" => 5.0}},
         {"2024-01-01 00:01:30", %{"top" => 5.0}},
         {"2024-01-01 00:01:00", %{"top" => 2.0}},
         {"2024-01-01 00:00:30", %{"top" => 3.0}},
         {"2024-01-01 00:00:00", %{"top" => 1.0}}
       ]},
      {"SELECT top(v, 3) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' LIMIT 2",
       [{"2024-01-01 00:01:30", %{"top" => 5.0}}, {"2024-01-01 00:03:00", %{"top" => 9.0}}]},
      {"SELECT top(v, 3) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' LIMIT 2 OFFSET 1",
       [{"2024-01-01 00:03:00", %{"top" => 9.0}}, {"2024-01-01 00:04:30", %{"top" => 8.0}}]},
      {"SELECT top(v, 2) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host",
       [
         {"2024-01-01 00:03:00", %{"host" => "a", "top" => 9.0}},
         {"2024-01-01 00:04:30", %{"host" => "a", "top" => 8.0}},
         {"2024-01-01 00:00:35", %{"host" => "b", "top" => 20.0}},
         {"2024-01-01 00:02:05", %{"host" => "b", "top" => 40.0}},
         {"2024-01-01 00:03:40", %{"host" => "c", "top" => 10.0}},
         {"2024-01-01 00:04:10", %{"host" => "c", "top" => 20.0}},
         {"2024-01-01 00:01:15", %{"host" => "d", "top" => 2.25}},
         {"2024-01-01 00:01:45", %{"host" => "d", "top" => 16.0}}
       ]},
      {"SELECT top(v, 2) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host LIMIT 1",
       [
         {"2024-01-01 00:03:00", %{"host" => "a", "top" => 9.0}},
         {"2024-01-01 00:00:35", %{"host" => "b", "top" => 20.0}},
         {"2024-01-01 00:03:40", %{"host" => "c", "top" => 10.0}},
         {"2024-01-01 00:01:15", %{"host" => "d", "top" => 2.25}}
       ]},
      {"SELECT top(v, host, 2) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:02:05", %{"host" => "b", "top" => 40.0}},
         {"2024-01-01 00:04:10", %{"host" => "c", "top" => 20.0}}
       ]},
      {"SELECT top(v, host, 10) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:01:45", %{"host" => "d", "top" => 16.0}},
         {"2024-01-01 00:02:05", %{"host" => "b", "top" => 40.0}},
         {"2024-01-01 00:03:00", %{"host" => "a", "top" => 9.0}},
         {"2024-01-01 00:04:10", %{"host" => "c", "top" => 20.0}}
       ]},
      {"SELECT top(v, host, 2), c FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:30", %{"c" => 10, "host" => "a", "top" => 3.0}},
         {"2024-01-01 00:00:35", %{"c" => 100, "host" => "b", "top" => 20.0}},
         {"2024-01-01 00:01:05", %{"c" => 200, "host" => "b", "top" => 15.0}},
         {"2024-01-01 00:01:45", %{"c" => 16, "host" => "d", "top" => 16.0}},
         {"2024-01-01 00:02:00", %{"c" => 35, "host" => "a", "top" => 5.0}},
         {"2024-01-01 00:02:05", %{"c" => 400, "host" => "b", "top" => 40.0}},
         {"2024-01-01 00:03:00", %{"c" => 70, "host" => "a", "top" => 9.0}},
         {"2024-01-01 00:03:40", %{"c" => 5, "host" => "c", "top" => 10.0}},
         {"2024-01-01 00:04:10", %{"c" => 50, "host" => "c", "top" => 20.0}},
         {"2024-01-01 00:04:30", %{"c" => 40, "host" => "a", "top" => 8.0}}
       ]},
      {"SELECT bottom(v, host, 2) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"bottom" => 1.0, "host" => "a"}},
         {"2024-01-01 00:00:15", %{"bottom" => -2.5, "host" => "d"}}
       ]},
      {"SELECT bottom(c, 2) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"bottom" => 0}},
         {"2024-01-01 00:00:15", %{"bottom" => -3}},
         {"2024-01-01 00:01:10", %{"bottom" => 9}},
         {"2024-01-01 00:01:15", %{"bottom" => 4}},
         {"2024-01-01 00:02:00", %{"bottom" => 35}},
         {"2024-01-01 00:02:30", %{"bottom" => 50}},
         {"2024-01-01 00:03:30", %{"bottom" => 5}},
         {"2024-01-01 00:03:40", %{"bottom" => 5}},
         {"2024-01-01 00:04:00", %{"bottom" => 15}},
         {"2024-01-01 00:04:30", %{"bottom" => 40}}
       ]},
      {"SELECT top(v, 2), c FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:03:00", %{"c" => 70, "top" => 9.0}},
         {"2024-01-01 00:04:30", %{"c" => 40, "top" => 8.0}}
       ]},
      {"SELECT top(v, 2), host, c FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:35", %{"c" => 100, "host" => "b", "top" => 20.0}},
         {"2024-01-01 00:02:05", %{"c" => 400, "host" => "b", "top" => 40.0}}
       ]},
      {"SELECT top(v, 2) AS t FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:03:00", %{"t" => 9.0}}, {"2024-01-01 00:04:30", %{"t" => 8.0}}]},
      {"SELECT top(s, 2) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:01:00", %{"top" => "s2"}}, {"2024-01-01 00:02:30", %{"top" => "s2"}}]},
      {"SELECT top(b, 2) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"top" => true}}, {"2024-01-01 00:01:00", %{"top" => true}}]},
      {"SELECT top(v, 2) FROM ~k1 WHERE host='nosuch'", []},
      {"SELECT top(v, 3), mean(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: selector functions top and bottom cannot be combined with other functions"}},
      {"SELECT top(v, 3), max(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: selector functions top and bottom cannot be combined with other functions"}},
      {"SELECT top(v, 3), bottom(v, 1) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: selector function bottom() cannot be combined with other functions"}},
      {"SELECT top(v, 0) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: limit (0) for top must be greater than 0"}},
      {"SELECT top(v, -1) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: limit (-1) for top must be greater than 0"}},
      {"SELECT top(v, 2.5) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: expected integer as last argument for top, got Literal(Float(2.5))"}},
      {"SELECT top(v, 'x') FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: expected integer as last argument for top, got Literal(String(\"x\"))"}},
      {"SELECT top(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: invalid number of arguments for top, expected at least 2, got 1"}},
      {"SELECT max(v) * 2 FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:03:00", %{"max" => 18.0}}]},
      {"SELECT first(v) + 1 FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"first" => 2.0}}]},
      {"SELECT max(v) - min(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"max_min" => 8.0}}]},
      {"SELECT abs(max(v)) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"SELECT round(first(v)) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 500,
        "External error: InfluxQL internal error: unexpected selector function: round"}},
      {"SELECT pow(last(c), 2) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: pow"}},
      {"SELECT abs(max(v)), min(v) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"abs" => 9.0, "min" => 1.0}}]},
      {"SELECT abs(max(v) - min(v)) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"abs" => 8.0}}]},
      {"SELECT first(b) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"first" => true}}]},
      {"SELECT last(b) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:04:30", %{"last" => false}}]},
      {"SELECT max(b) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"max" => true}}]},
      {"SELECT min(b) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:30", %{"min" => false}}]},
      {"SELECT first(b), last(b) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"first" => true, "last" => false}}]},
      {"SELECT last(b) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"last" => false}},
         {"2024-01-01 00:01:00", %{"last" => false}},
         {"2024-01-01 00:02:00", %{"last" => false}},
         {"2024-01-01 00:03:00", %{"last" => false}},
         {"2024-01-01 00:04:00", %{"last" => false}}
       ]},
      {"SELECT max(b) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"max" => true}},
         {"2024-01-01 00:01:00", %{"max" => true}},
         {"2024-01-01 00:02:00", %{"max" => true}},
         {"2024-01-01 00:03:00", %{"max" => true}},
         {"2024-01-01 00:04:00", %{"max" => true}}
       ]},
      {"SELECT last(b), host FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:04:30", %{"host" => "a", "last" => false}}]}
    ]
  end

  @doc false
  @spec math() :: [{binary(), term()}]
  def math do
    [
      {"SELECT abs(c) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"abs" => 3}},
         {"2024-01-01 00:00:45", %{"abs" => 0}},
         {"2024-01-01 00:01:15", %{"abs" => 4}},
         {"2024-01-01 00:01:45", %{"abs" => 16}}
       ]},
      {"SELECT abs(v) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"abs" => 2.5}},
         {"2024-01-01 00:00:45", %{"abs" => 0.0}},
         {"2024-01-01 00:01:15", %{"abs" => 2.25}},
         {"2024-01-01 00:01:45", %{"abs" => 16.0}}
       ]},
      {"SELECT round(v) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"round" => -3.0}},
         {"2024-01-01 00:00:45", %{"round" => 0.0}},
         {"2024-01-01 00:01:15", %{"round" => 2.0}},
         {"2024-01-01 00:01:45", %{"round" => 16.0}}
       ]},
      {"SELECT round(c) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"round" => -3.0}},
         {"2024-01-01 00:00:45", %{"round" => 0.0}},
         {"2024-01-01 00:01:15", %{"round" => 4.0}},
         {"2024-01-01 00:01:45", %{"round" => 16.0}}
       ]},
      {"SELECT sqrt(v) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"sqrt" => nil}},
         {"2024-01-01 00:00:45", %{"sqrt" => 0.0}},
         {"2024-01-01 00:01:15", %{"sqrt" => 1.5}},
         {"2024-01-01 00:01:45", %{"sqrt" => 4.0}}
       ]},
      {"SELECT sqrt(c) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"sqrt" => nil}},
         {"2024-01-01 00:00:45", %{"sqrt" => 0.0}},
         {"2024-01-01 00:01:15", %{"sqrt" => 2.0}},
         {"2024-01-01 00:01:45", %{"sqrt" => 4.0}}
       ]},
      {"SELECT floor(v) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"floor" => -3.0}},
         {"2024-01-01 00:00:45", %{"floor" => 0.0}},
         {"2024-01-01 00:01:15", %{"floor" => 2.0}},
         {"2024-01-01 00:01:45", %{"floor" => 16.0}}
       ]},
      {"SELECT ceil(v) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"ceil" => -2.0}},
         {"2024-01-01 00:00:45", %{"ceil" => 0.0}},
         {"2024-01-01 00:01:15", %{"ceil" => 3.0}},
         {"2024-01-01 00:01:45", %{"ceil" => 16.0}}
       ]},
      {"SELECT floor(c) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"floor" => -3.0}},
         {"2024-01-01 00:00:45", %{"floor" => 0.0}},
         {"2024-01-01 00:01:15", %{"floor" => 4.0}},
         {"2024-01-01 00:01:45", %{"floor" => 16.0}}
       ]},
      {"SELECT ln(v) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"ln" => nil}},
         {"2024-01-01 00:00:45", %{"ln" => nil}},
         {"2024-01-01 00:01:15", %{"ln" => 0.8109302162163288}},
         {"2024-01-01 00:01:45", %{"ln" => 2.772588722239781}}
       ]},
      {"SELECT ln(c) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"ln" => nil}},
         {"2024-01-01 00:00:45", %{"ln" => nil}},
         {"2024-01-01 00:01:15", %{"ln" => 1.3862943611198906}},
         {"2024-01-01 00:01:45", %{"ln" => 2.772588722239781}}
       ]},
      {"SELECT log(v, 2) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"log" => nil}},
         {"2024-01-01 00:00:45", %{"log" => nil}},
         {"2024-01-01 00:01:15", %{"log" => 1.1699250014423124}},
         {"2024-01-01 00:01:45", %{"log" => 4.0}}
       ]},
      {"SELECT log(c, 10) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"log" => nil}},
         {"2024-01-01 00:00:45", %{"log" => nil}},
         {"2024-01-01 00:01:15", %{"log" => 0.6020599913279623}},
         {"2024-01-01 00:01:45", %{"log" => 1.2041199826559246}}
       ]},
      {"SELECT pow(v, 2) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"pow" => 6.25}},
         {"2024-01-01 00:00:45", %{"pow" => 0.0}},
         {"2024-01-01 00:01:15", %{"pow" => 5.0625}},
         {"2024-01-01 00:01:45", %{"pow" => 256.0}}
       ]},
      {"SELECT pow(c, 2) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"pow" => 9}},
         {"2024-01-01 00:00:45", %{"pow" => 0}},
         {"2024-01-01 00:01:15", %{"pow" => 16}},
         {"2024-01-01 00:01:45", %{"pow" => 256}}
       ]},
      {"SELECT pow(c, 0.5) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"pow" => nil}},
         {"2024-01-01 00:00:45", %{"pow" => 0.0}},
         {"2024-01-01 00:01:15", %{"pow" => 2.0}},
         {"2024-01-01 00:01:45", %{"pow" => 4.0}}
       ]},
      {"SELECT abs(c), round(v) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"abs" => 3, "round" => -3.0}},
         {"2024-01-01 00:00:45", %{"abs" => 0, "round" => 0.0}},
         {"2024-01-01 00:01:15", %{"abs" => 4, "round" => 2.0}},
         {"2024-01-01 00:01:45", %{"abs" => 16, "round" => 16.0}}
       ]},
      {"SELECT abs(c) + 1 FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"abs" => 4}},
         {"2024-01-01 00:00:45", %{"abs" => 1}},
         {"2024-01-01 00:01:15", %{"abs" => 5}},
         {"2024-01-01 00:01:45", %{"abs" => 17}}
       ]},
      {"SELECT abs(c * 2) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"abs" => 6}},
         {"2024-01-01 00:00:45", %{"abs" => 0}},
         {"2024-01-01 00:01:15", %{"abs" => 8}},
         {"2024-01-01 00:01:45", %{"abs" => 32}}
       ]},
      {"SELECT abs(abs(c)) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"abs" => 3}},
         {"2024-01-01 00:00:45", %{"abs" => 0}},
         {"2024-01-01 00:01:15", %{"abs" => 4}},
         {"2024-01-01 00:01:45", %{"abs" => 16}}
       ]},
      {"SELECT abs(c) AS x FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"x" => 3}},
         {"2024-01-01 00:00:45", %{"x" => 0}},
         {"2024-01-01 00:01:15", %{"x" => 4}},
         {"2024-01-01 00:01:45", %{"x" => 16}}
       ]},
      {"SELECT abs(v), v FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"abs" => 2.5, "v" => -2.5}},
         {"2024-01-01 00:00:45", %{"abs" => 0.0, "v" => 0.0}},
         {"2024-01-01 00:01:15", %{"abs" => 2.25, "v" => 2.25}},
         {"2024-01-01 00:01:45", %{"abs" => 16.0, "v" => 16.0}}
       ]},
      {"SELECT abs(mean(v)) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"abs" => 3.9375}}]},
      {"SELECT abs(mean(c)) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"abs" => 4.25}}]},
      {"SELECT round(mean(v)) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"round" => -1.0}},
         {"2024-01-01 00:01:00", %{"round" => 9.0}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:04:00", %{}}
       ]},
      {"SELECT round(sum(c)) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"round" => 17.0}}]},
      {"SELECT sqrt(sum(c)) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"sqrt" => 4.123105625617661}}]},
      {"SELECT abs(sum(c)) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"abs" => 17}}]},
      {"SELECT abs(nosuch) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT sqrt(mean(v)) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"sqrt" => nil}},
         {"2024-01-01 00:01:00", %{"sqrt" => 3.020761493398643}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:04:00", %{}}
       ]},
      {"SELECT ln(sum(c)) FROM ~k1 WHERE host='a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"ln" => 2.302585092994046}},
         {"2024-01-01 00:01:00", %{"ln" => 4.007333185232471}},
         {"2024-01-01 00:02:00", %{"ln" => 4.442651256490317}},
         {"2024-01-01 00:03:00", %{"ln" => 4.31748811353631}},
         {"2024-01-01 00:04:00", %{"ln" => 4.007333185232471}}
       ]},
      {"SELECT abs(*) FROM ~k1 WHERE host='d' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:15", %{"abs_c" => 3, "abs_v" => 2.5}},
         {"2024-01-01 00:00:45", %{"abs_c" => 0, "abs_v" => 0.0}},
         {"2024-01-01 00:01:15", %{"abs_c" => 4, "abs_v" => 2.25}},
         {"2024-01-01 00:01:45", %{"abs_c" => 16, "abs_v" => 16.0}}
       ]}
    ]
  end

  @doc false
  @spec where() :: [{binary(), term()}]
  def where do
    [
      {"SELECT count(v) FROM ~k1 WHERE 'a' = host AND host = 'a'",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' AND 'a' = host AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE 'a' = host OR host = 'b'",
       [{"1970-01-01 00:00:00", %{"count" => 15}}]},
      {"SELECT v FROM ~k1 WHERE 'a' = host AND host = 'a' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"v" => 1.0}},
         {"2024-01-01 00:00:30", %{"v" => 3.0}},
         {"2024-01-01 00:01:00", %{"v" => 2.0}},
         {"2024-01-01 00:01:30", %{"v" => 5.0}},
         {"2024-01-01 00:02:00", %{"v" => 5.0}},
         {"2024-01-01 00:02:30", %{"v" => 4.0}},
         {"2024-01-01 00:03:00", %{"v" => 9.0}},
         {"2024-01-01 00:03:30", %{"v" => 1.0}},
         {"2024-01-01 00:04:00", %{"v" => 2.0}},
         {"2024-01-01 00:04:30", %{"v" => 8.0}}
       ]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' OR zone = 'z'",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE zone = 'z' OR host = 'a'",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' AND zone = 'z'", []},
      {"SELECT count(v) FROM ~k1 WHERE zone = 'z'", []},
      {"SELECT count(v) FROM ~k1 WHERE zone != 'z'", []},
      {"SELECT count(v) FROM ~k1 WHERE zone = ''", []},
      {"SELECT count(v) FROM ~k1 WHERE zone != ''", []},
      {"SELECT count(v) FROM ~k1 WHERE zone =~ /z/", []},
      {"SELECT count(v) FROM ~k1 WHERE zone !~ /z/", []},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' OR zone != 'z'",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' AND zone != 'z'", []},
      {"SELECT count(v) FROM ~k1 WHERE (host = 'a' OR zone = 'z') AND v > 1",
       [{"1970-01-01 00:00:00", %{"count" => 8}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' OR nofield = 1",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' OR nofield > 1",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' AND nofield > 1", []},
      {"SELECT count(v) FROM ~k1 WHERE host = 'b' OR (nofield = 1 AND host = 'a')",
       [{"1970-01-01 00:00:00", %{"count" => 5}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' OR zone =~ /z/",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' OR zone !~ /z/",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' OR c > 10 OR zone = 'z'",
       [{"1970-01-01 00:00:00", %{"count" => 16}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' OR 'z' = zone",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' OR zone = host",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE host = 'a' OR \"zone\" = 'z'",
       [{"1970-01-01 00:00:00", %{"count" => 10}}]},
      {"SELECT count(v) FROM ~k1 WHERE zone = host", []},
      {"SELECT v FROM /^~kp/ WHERE host = 'x' OR zone = 'z1'",
       [
         {"2024-01-01 00:00:00", %{"v" => 1.5}},
         {"2024-01-01 00:00:30", %{"v" => 2.5}},
         {"2024-01-01 00:01:00", %{"v" => 4.0}},
         {"2024-01-01 00:01:30", %{"v" => 8.0}},
         {"2024-01-01 00:00:03", %{"v" => 5.0}},
         {"2024-01-01 00:00:33", %{"v" => 6.0}},
         {"2024-01-01 00:01:03", %{"v" => 7.0}}
       ]}
    ]
  end

  @doc false
  @spec wildcards() :: [{binary(), term()}]
  def wildcards do
    [
      {"SELECT *::field FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"b" => true, "c" => 0, "s" => "s0", "v" => 1.5}},
         {"2024-01-01 00:00:07", %{"b" => true, "c" => 0, "s" => "s0", "v" => 11.5}},
         {"2024-01-01 00:00:30", %{"b" => false, "c" => 3, "s" => "s1", "v" => 2.5}},
         {"2024-01-01 00:00:37", %{"b" => false, "c" => 3, "s" => "s1", "v" => 12.5}},
         {"2024-01-01 00:01:00", %{"b" => true, "c" => 6, "s" => "s2", "v" => 4.0}},
         {"2024-01-01 00:01:07", %{"b" => true, "c" => 6, "s" => "s2", "v" => 14.0}},
         {"2024-01-01 00:01:30", %{"b" => false, "c" => 9, "s" => "s3", "v" => 8.0}},
         {"2024-01-01 00:01:37", %{"b" => false, "c" => 9, "s" => "s3", "v" => 18.0}}
       ]},
      {"SELECT *::tag FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT *::tag, *::field FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"b" => true, "c" => 0, "host" => "x", "region" => "r0", "s" => "s0", "v" => 1.5}},
         {"2024-01-01 00:00:07",
          %{"b" => true, "c" => 0, "host" => "y", "region" => "r0", "s" => "s0", "v" => 11.5}},
         {"2024-01-01 00:00:30",
          %{"b" => false, "c" => 3, "host" => "x", "region" => "r1", "s" => "s1", "v" => 2.5}},
         {"2024-01-01 00:00:37",
          %{"b" => false, "c" => 3, "host" => "y", "region" => "r1", "s" => "s1", "v" => 12.5}},
         {"2024-01-01 00:01:00",
          %{"b" => true, "c" => 6, "host" => "x", "region" => "r0", "s" => "s2", "v" => 4.0}},
         {"2024-01-01 00:01:07",
          %{"b" => true, "c" => 6, "host" => "y", "region" => "r0", "s" => "s2", "v" => 14.0}},
         {"2024-01-01 00:01:30",
          %{"b" => false, "c" => 9, "host" => "x", "region" => "r1", "s" => "s3", "v" => 8.0}},
         {"2024-01-01 00:01:37",
          %{"b" => false, "c" => 9, "host" => "y", "region" => "r1", "s" => "s3", "v" => 18.0}}
       ]},
      {"SELECT host, *::field FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"b" => true, "c" => 0, "host" => "x", "s" => "s0", "v" => 1.5}},
         {"2024-01-01 00:00:07",
          %{"b" => true, "c" => 0, "host" => "y", "s" => "s0", "v" => 11.5}},
         {"2024-01-01 00:00:30",
          %{"b" => false, "c" => 3, "host" => "x", "s" => "s1", "v" => 2.5}},
         {"2024-01-01 00:00:37",
          %{"b" => false, "c" => 3, "host" => "y", "s" => "s1", "v" => 12.5}},
         {"2024-01-01 00:01:00",
          %{"b" => true, "c" => 6, "host" => "x", "s" => "s2", "v" => 4.0}},
         {"2024-01-01 00:01:07",
          %{"b" => true, "c" => 6, "host" => "y", "s" => "s2", "v" => 14.0}},
         {"2024-01-01 00:01:30",
          %{"b" => false, "c" => 9, "host" => "x", "s" => "s3", "v" => 8.0}},
         {"2024-01-01 00:01:37",
          %{"b" => false, "c" => 9, "host" => "y", "s" => "s3", "v" => 18.0}}
       ]},
      {"SELECT * FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"b" => true, "c" => 0, "host" => "x", "region" => "r0", "s" => "s0", "v" => 1.5}},
         {"2024-01-01 00:00:07",
          %{"b" => true, "c" => 0, "host" => "y", "region" => "r0", "s" => "s0", "v" => 11.5}},
         {"2024-01-01 00:00:30",
          %{"b" => false, "c" => 3, "host" => "x", "region" => "r1", "s" => "s1", "v" => 2.5}},
         {"2024-01-01 00:00:37",
          %{"b" => false, "c" => 3, "host" => "y", "region" => "r1", "s" => "s1", "v" => 12.5}},
         {"2024-01-01 00:01:00",
          %{"b" => true, "c" => 6, "host" => "x", "region" => "r0", "s" => "s2", "v" => 4.0}},
         {"2024-01-01 00:01:07",
          %{"b" => true, "c" => 6, "host" => "y", "region" => "r0", "s" => "s2", "v" => 14.0}},
         {"2024-01-01 00:01:30",
          %{"b" => false, "c" => 9, "host" => "x", "region" => "r1", "s" => "s3", "v" => 8.0}},
         {"2024-01-01 00:01:37",
          %{"b" => false, "c" => 9, "host" => "y", "region" => "r1", "s" => "s3", "v" => 18.0}}
       ]},
      {"SELECT /^[vc]/ FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"c" => 0, "v" => 1.5}},
         {"2024-01-01 00:00:07", %{"c" => 0, "v" => 11.5}},
         {"2024-01-01 00:00:30", %{"c" => 3, "v" => 2.5}},
         {"2024-01-01 00:00:37", %{"c" => 3, "v" => 12.5}},
         {"2024-01-01 00:01:00", %{"c" => 6, "v" => 4.0}},
         {"2024-01-01 00:01:07", %{"c" => 6, "v" => 14.0}},
         {"2024-01-01 00:01:30", %{"c" => 9, "v" => 8.0}},
         {"2024-01-01 00:01:37", %{"c" => 9, "v" => 18.0}}
       ]},
      {"SELECT /^[vc]/, host FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"c" => 0, "host" => "x", "v" => 1.5}},
         {"2024-01-01 00:00:07", %{"c" => 0, "host" => "y", "v" => 11.5}},
         {"2024-01-01 00:00:30", %{"c" => 3, "host" => "x", "v" => 2.5}},
         {"2024-01-01 00:00:37", %{"c" => 3, "host" => "y", "v" => 12.5}},
         {"2024-01-01 00:01:00", %{"c" => 6, "host" => "x", "v" => 4.0}},
         {"2024-01-01 00:01:07", %{"c" => 6, "host" => "y", "v" => 14.0}},
         {"2024-01-01 00:01:30", %{"c" => 9, "host" => "x", "v" => 8.0}},
         {"2024-01-01 00:01:37", %{"c" => 9, "host" => "y", "v" => 18.0}}
       ]},
      {"SELECT /host/ FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT /./ FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"b" => true, "c" => 0, "host" => "x", "region" => "r0", "s" => "s0", "v" => 1.5}},
         {"2024-01-01 00:00:07",
          %{"b" => true, "c" => 0, "host" => "y", "region" => "r0", "s" => "s0", "v" => 11.5}},
         {"2024-01-01 00:00:30",
          %{"b" => false, "c" => 3, "host" => "x", "region" => "r1", "s" => "s1", "v" => 2.5}},
         {"2024-01-01 00:00:37",
          %{"b" => false, "c" => 3, "host" => "y", "region" => "r1", "s" => "s1", "v" => 12.5}},
         {"2024-01-01 00:01:00",
          %{"b" => true, "c" => 6, "host" => "x", "region" => "r0", "s" => "s2", "v" => 4.0}},
         {"2024-01-01 00:01:07",
          %{"b" => true, "c" => 6, "host" => "y", "region" => "r0", "s" => "s2", "v" => 14.0}},
         {"2024-01-01 00:01:30",
          %{"b" => false, "c" => 9, "host" => "x", "region" => "r1", "s" => "s3", "v" => 8.0}},
         {"2024-01-01 00:01:37",
          %{"b" => false, "c" => 9, "host" => "y", "region" => "r1", "s" => "s3", "v" => 18.0}}
       ]},
      {"SELECT /zzz/ FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT /^v/, /^c/ FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"c" => 0, "v" => 1.5}},
         {"2024-01-01 00:00:07", %{"c" => 0, "v" => 11.5}},
         {"2024-01-01 00:00:30", %{"c" => 3, "v" => 2.5}},
         {"2024-01-01 00:00:37", %{"c" => 3, "v" => 12.5}},
         {"2024-01-01 00:01:00", %{"c" => 6, "v" => 4.0}},
         {"2024-01-01 00:01:07", %{"c" => 6, "v" => 14.0}},
         {"2024-01-01 00:01:30", %{"c" => 9, "v" => 8.0}},
         {"2024-01-01 00:01:37", %{"c" => 9, "v" => 18.0}}
       ]},
      {"SELECT /^v/ AS x FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"v" => 1.5}},
         {"2024-01-01 00:00:07", %{"v" => 11.5}},
         {"2024-01-01 00:00:30", %{"v" => 2.5}},
         {"2024-01-01 00:00:37", %{"v" => 12.5}},
         {"2024-01-01 00:01:00", %{"v" => 4.0}},
         {"2024-01-01 00:01:07", %{"v" => 14.0}},
         {"2024-01-01 00:01:30", %{"v" => 8.0}},
         {"2024-01-01 00:01:37", %{"v" => 18.0}}
       ]},
      {"SELECT /^v/, v FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"v" => 1.5, "v_1" => 1.5}},
         {"2024-01-01 00:00:07", %{"v" => 11.5, "v_1" => 11.5}},
         {"2024-01-01 00:00:30", %{"v" => 2.5, "v_1" => 2.5}},
         {"2024-01-01 00:00:37", %{"v" => 12.5, "v_1" => 12.5}},
         {"2024-01-01 00:01:00", %{"v" => 4.0, "v_1" => 4.0}},
         {"2024-01-01 00:01:07", %{"v" => 14.0, "v_1" => 14.0}},
         {"2024-01-01 00:01:30", %{"v" => 8.0, "v_1" => 8.0}},
         {"2024-01-01 00:01:37", %{"v" => 18.0, "v_1" => 18.0}}
       ]},
      {"SELECT /^us/ FROM nosuch", []},
      {"SELECT mean(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"mean_c" => 4.5, "mean_v" => 9.0}}]},
      {"SELECT mean(/^[vc]/) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"mean_c" => 4.5, "mean_v" => 9.0}}]},
      {"SELECT max(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"max_b" => true, "max_c" => 9, "max_v" => 18.0}}]},
      {"SELECT min(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"min_b" => false, "min_c" => 0, "min_v" => 1.5}}]},
      {"SELECT sum(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"sum_c" => 36, "sum_v" => 72.0}}]},
      {"SELECT first(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"first_b" => true, "first_c" => 0, "first_s" => "s0", "first_v" => 1.5}}
       ]},
      {"SELECT last(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"last_b" => false, "last_c" => 9, "last_s" => "s3", "last_v" => 18.0}}
       ]},
      {"SELECT median(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"median_c" => 4, "median_v" => 9.75}}]},
      {"SELECT spread(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"spread_c" => 9, "spread_v" => 16.5}}]},
      {"SELECT stddev(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"stddev_c" => 3.585685828003181, "stddev_v" => 5.96417878432803}}
       ]},
      {"SELECT count(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"count_b" => 8, "count_c" => 8, "count_s" => 8, "count_v" => 8}}
       ]},
      {"SELECT mean(*) AS m FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"m_c" => 4.5, "m_v" => 9.0}}]},
      {"SELECT mean(*), host FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"SELECT mean(*), max(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"max_b" => true, "max_c" => 9, "max_v" => 18.0, "mean_c" => 4.5, "mean_v" => 9.0}}
       ]},
      {"SELECT mean(*), max(v) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"max" => 18.0, "mean_c" => 4.5, "mean_v" => 9.0}}]},
      {"SELECT mean(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"mean_c" => 1.5, "mean_v" => 7.0}},
         {"2024-01-01 00:01:00", %{"mean_c" => 7.5, "mean_v" => 11.0}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:04:00", %{}}
       ]},
      {"SELECT mean(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host",
       [
         {"2024-01-01 00:00:00", %{"host" => "x", "mean_c" => 4.5, "mean_v" => 4.0}},
         {"2024-01-01 00:00:00", %{"host" => "y", "mean_c" => 4.5, "mean_v" => 14.0}}
       ]},
      {"SELECT mean(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"mean_c" => 1.5, "mean_v" => 7.0}},
         {"2024-01-01 00:01:00", %{"mean_c" => 7.5, "mean_v" => 11.0}},
         {"2024-01-01 00:02:00", %{"mean_c" => 0.0, "mean_v" => 0.0}},
         {"2024-01-01 00:03:00", %{"mean_c" => 0.0, "mean_v" => 0.0}},
         {"2024-01-01 00:04:00", %{"mean_c" => 0.0, "mean_v" => 0.0}}
       ]},
      {"SELECT max(*) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"max_b" => true, "max_c" => 3, "max_v" => 12.5}},
         {"2024-01-01 00:01:00", %{"max_b" => true, "max_c" => 9, "max_v" => 18.0}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:04:00", %{}}
       ]},
      {"SELECT mean(*) + 1 FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: unsupported binary expression: contains a wildcard or regular expression"}},
      {"SELECT percentile(*, 50) FROM ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"percentile_c" => 3, "percentile_v" => 8.0}}]},
      {"SELECT integral(*) FROM ~k2 WHERE host='x' AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"integral_c" => 405.0, "integral_v" => 337.5}}]},
      {"SELECT mean(*) FROM nosuch", []},
      {"SELECT mean(v) FROM /^~kp/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"mean" => 9.0}}, {"2024-01-01 00:00:00", %{"mean" => 6.0}}]},
      {"SELECT v FROM /^~kp/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"v" => 1.5}},
         {"2024-01-01 00:00:07", %{"v" => 11.5}},
         {"2024-01-01 00:00:30", %{"v" => 2.5}},
         {"2024-01-01 00:00:37", %{"v" => 12.5}},
         {"2024-01-01 00:01:00", %{"v" => 4.0}},
         {"2024-01-01 00:01:07", %{"v" => 14.0}},
         {"2024-01-01 00:01:30", %{"v" => 8.0}},
         {"2024-01-01 00:01:37", %{"v" => 18.0}},
         {"2024-01-01 00:00:03", %{"v" => 5.0}},
         {"2024-01-01 00:00:33", %{"v" => 6.0}},
         {"2024-01-01 00:01:03", %{"v" => 7.0}}
       ]},
      {"SELECT * FROM /^~kp/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"b" => true, "c" => 0, "host" => "x", "region" => "r0", "s" => "s0", "v" => 1.5}},
         {"2024-01-01 00:00:07",
          %{"b" => true, "c" => 0, "host" => "y", "region" => "r0", "s" => "s0", "v" => 11.5}},
         {"2024-01-01 00:00:30",
          %{"b" => false, "c" => 3, "host" => "x", "region" => "r1", "s" => "s1", "v" => 2.5}},
         {"2024-01-01 00:00:37",
          %{"b" => false, "c" => 3, "host" => "y", "region" => "r1", "s" => "s1", "v" => 12.5}},
         {"2024-01-01 00:01:00",
          %{"b" => true, "c" => 6, "host" => "x", "region" => "r0", "s" => "s2", "v" => 4.0}},
         {"2024-01-01 00:01:07",
          %{"b" => true, "c" => 6, "host" => "y", "region" => "r0", "s" => "s2", "v" => 14.0}},
         {"2024-01-01 00:01:30",
          %{"b" => false, "c" => 9, "host" => "x", "region" => "r1", "s" => "s3", "v" => 8.0}},
         {"2024-01-01 00:01:37",
          %{"b" => false, "c" => 9, "host" => "y", "region" => "r1", "s" => "s3", "v" => 18.0}},
         {"2024-01-01 00:00:03", %{"host" => "x", "n" => 0, "v" => 5.0, "zone" => "z1"}},
         {"2024-01-01 00:00:33", %{"host" => "x", "n" => 7, "v" => 6.0, "zone" => "z1"}},
         {"2024-01-01 00:01:03", %{"host" => "x", "n" => 14, "v" => 7.0, "zone" => "z1"}}
       ]},
      {"SELECT count(*) FROM /^~kp/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00",
          %{"count_b" => 8, "count_c" => 8, "count_s" => 8, "count_v" => 8}},
         {"2024-01-01 00:00:00", %{"count_n" => 3, "count_v" => 3}}
       ]},
      {"SELECT mean(v) FROM /^~kp/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY host",
       [
         {"2024-01-01 00:00:00", %{"host" => "x", "mean" => 4.0}},
         {"2024-01-01 00:00:00", %{"host" => "y", "mean" => 14.0}},
         {"2024-01-01 00:00:00", %{"host" => "x", "mean" => 6.0}}
       ]},
      {"SELECT mean(v) FROM /^~kp/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"mean" => 7.0}},
         {"2024-01-01 00:01:00", %{"mean" => 11.0}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:04:00", %{}},
         {"2024-01-01 00:00:00", %{"mean" => 5.5}},
         {"2024-01-01 00:01:00", %{"mean" => 7.0}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:04:00", %{}}
       ]},
      {"SELECT mean(v) FROM /^~kp/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY *",
       [
         {"2024-01-01 00:00:00", %{"host" => "x", "mean" => 2.75, "region" => "r0"}},
         {"2024-01-01 00:00:00", %{"host" => "x", "mean" => 5.25, "region" => "r1"}},
         {"2024-01-01 00:00:00", %{"host" => "y", "mean" => 12.75, "region" => "r0"}},
         {"2024-01-01 00:00:00", %{"host" => "y", "mean" => 15.25, "region" => "r1"}},
         {"2024-01-01 00:00:00", %{"host" => "x", "mean" => 6.0, "zone" => "z1"}}
       ]},
      {"SELECT mean(v) FROM /zzzz/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       []},
      {"SELECT mean(v) FROM /^~kp/, ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"mean" => 9.0}}, {"2024-01-01 00:00:00", %{"mean" => 6.0}}]},
      {"SELECT mean(v) FROM ~k2, ~k3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [{"2024-01-01 00:00:00", %{"mean" => 9.0}}, {"2024-01-01 00:00:00", %{"mean" => 6.0}}]},
      {"SELECT v FROM ~k3, ~k2 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' LIMIT 2",
       [
         {"2024-01-01 00:00:00", %{"v" => 1.5}},
         {"2024-01-01 00:00:07", %{"v" => 11.5}},
         {"2024-01-01 00:00:03", %{"v" => 5.0}},
         {"2024-01-01 00:00:33", %{"v" => 6.0}}
       ]},
      {"SELECT mean(v) FROM /^~kp/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' ORDER BY time DESC",
       [{"2024-01-01 00:00:00", %{"mean" => 9.0}}, {"2024-01-01 00:00:00", %{"mean" => 6.0}}]},
      {"SELECT v FROM /^~kp/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' LIMIT 2",
       [
         {"2024-01-01 00:00:00", %{"v" => 1.5}},
         {"2024-01-01 00:00:07", %{"v" => 11.5}},
         {"2024-01-01 00:00:03", %{"v" => 5.0}},
         {"2024-01-01 00:00:33", %{"v" => 6.0}}
       ]},
      {"SELECT v FROM /^~kp/ WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' LIMIT 2 OFFSET 1",
       [
         {"2024-01-01 00:00:07", %{"v" => 11.5}},
         {"2024-01-01 00:00:30", %{"v" => 2.5}},
         {"2024-01-01 00:00:33", %{"v" => 6.0}},
         {"2024-01-01 00:01:03", %{"v" => 7.0}}
       ]},
      {"SELECT v FROM /^~kp/ WHERE host =~ /x/ AND time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z'",
       [
         {"2024-01-01 00:00:00", %{"v" => 1.5}},
         {"2024-01-01 00:00:30", %{"v" => 2.5}},
         {"2024-01-01 00:01:00", %{"v" => 4.0}},
         {"2024-01-01 00:01:30", %{"v" => 8.0}},
         {"2024-01-01 00:00:03", %{"v" => 5.0}},
         {"2024-01-01 00:00:33", %{"v" => 6.0}},
         {"2024-01-01 00:01:03", %{"v" => 7.0}}
       ]}
    ]
  end

  @doc false
  @spec closed() :: [binary()]
  def closed do
    [
      "SELECT last(s) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(linear)",
      "SELECT count(c) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:01:30Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(previous)",
      "SELECT mean(c), count(c) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:01:30Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(previous)",
      "SELECT last(b) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(linear)"
    ]
  end

  @doc "The reason the double gives for each statement of `closed/0` (`Client.Local: <reason>`), where the engine breaks the connection."
  @spec closed_reasons() :: %{binary() => binary()}
  def closed_reasons do
    %{
      "SELECT last(s) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(linear)" =>
        "unsupported InfluxQL (fill(linear) on a string, boolean or time column)",
      "SELECT count(c) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:01:30Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(previous)" =>
        "unsupported InfluxQL (fill(previous) with count() when the first bucket is empty)",
      "SELECT mean(c), count(c) FROM ~k1 WHERE host='c' AND time >= '2024-01-01T00:01:30Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(30s) fill(previous)" =>
        "unsupported InfluxQL (fill(previous) with count() when the first bucket is empty)",
      "SELECT last(b) FROM ~k1 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:05:00Z' GROUP BY time(1m) fill(linear)" =>
        "unsupported InfluxQL (fill(linear) on a string, boolean or time column)"
    }
  end

  @spec at(integer()) :: integer()
  defp at(seconds), do: (@base + seconds) * 1_000_000_000
end
