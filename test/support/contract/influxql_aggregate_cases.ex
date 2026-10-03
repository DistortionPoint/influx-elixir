defmodule InfluxElixir.Contract.InfluxQLAggregateCases do
  @moduledoc "Statements over the bucket fixtures of `InfluxElixir.Contract.InfluxQLPlanner` with the answers InfluxDB 3 Core gave: `median`, `spread`, `stddev`, `count(distinct())`, aggregates of text and tags, mixed select lists."

  @doc "The aggregates and the planning errors of their select lists."
  @spec aggregates() :: [{binary(), [{binary(), map()}] | {:error, pos_integer(), binary()}}]
  def aggregates do
    [
      {"SELECT median(usage) FROM ~m1",
       [
         {"1970-01-01 00:00:00", %{"median" => 6.0}}
       ]},
      {"SELECT median(n) FROM ~m1",
       [
         {"1970-01-01 00:00:00", %{"median" => 6}}
       ]},
      {"SELECT median(n) FROM ~m1 WHERE time < '2024-01-01T00:00:30Z'",
       [
         {"1970-01-01 00:00:00", %{"median" => 2}}
       ]},
      {"SELECT spread(usage) FROM ~m1",
       [
         {"1970-01-01 00:00:00", %{"spread" => 19.0}}
       ]},
      {"SELECT spread(n) FROM ~m1",
       [
         {"1970-01-01 00:00:00", %{"spread" => 19}}
       ]},
      {"SELECT stddev(usage) FROM ~m1",
       [
         {"1970-01-01 00:00:00", %{"stddev" => 7.035623639735144}}
       ]},
      {"SELECT stddev(n) FROM ~m1",
       [
         {"1970-01-01 00:00:00", %{"stddev" => 7.035623639735144}}
       ]},
      {"SELECT stddev(usage) FROM ~m1 WHERE time < '2024-01-01T00:00:05Z'",
       [
         {"1970-01-01 00:00:00", %{}}
       ]},
      {"SELECT distinct(host) FROM ~m1", []},
      {"SELECT count(distinct(host)) FROM ~m1", []},
      {"SELECT count(distinct(usage)) FROM ~m1",
       [
         {"1970-01-01 00:00:00", %{"count" => 6}}
       ]},
      {"SELECT count(distinct(n)) FROM ~m1",
       [
         {"1970-01-01 00:00:00", %{"count" => 6}}
       ]},
      {"SELECT median(usage), mean(usage) FROM ~m1",
       [
         {"1970-01-01 00:00:00", %{"mean" => 7.5, "median" => 6.0}}
       ]},
      {"SELECT median(usage) FROM ~m1 GROUP BY host",
       [
         {"1970-01-01 00:00:00", %{"host" => "a", "median" => 3.0}},
         {"1970-01-01 00:00:00", %{"host" => "b", "median" => 15.0}}
       ]},
      {"SELECT median(host) FROM ~m1", []},
      {"SELECT median(n), median(u), median(usage) FROM ~m3 WHERE time < '2024-01-01T00:04:00Z'",
       [
         {"1970-01-01 00:00:00", %{"median" => 1, "median_1" => 1, "median_2" => 1.5}}
       ]},
      {"SELECT median(n), median(u), median(usage) FROM ~m3",
       [
         {"1970-01-01 00:00:00", %{"median" => 1, "median_1" => 2, "median_2" => 2.0}}
       ]},
      {"SELECT spread(n), spread(u), spread(usage) FROM ~m3",
       [
         {"1970-01-01 00:00:00", %{"spread" => 11, "spread_1" => 8, "spread_2" => 8.0}}
       ]},
      {"SELECT stddev(n), stddev(u), stddev(usage) FROM ~m3",
       [
         {"1970-01-01 00:00:00",
          %{
            "stddev" => 6.082762530298219,
            "stddev_1" => 4.358898943540674,
            "stddev_2" => 4.358898943540674
          }}
       ]},
      {"SELECT median(s) FROM ~m3",
       {:error, 400,
        "Error during planning: Function 'median' expects NativeType::Numeric but received NativeType::String No function matches the given name and argument types 'median(Utf8)'. You might need to add explicit type casts.\n\tCandidate functions:\n\tmedian(Numeric(1))"}},
      {"SELECT mean(s) FROM ~m3",
       {:error, 400,
        "Error during planning: Execution error: Function 'avg' user-defined coercion failed with \"Error during planning: Avg does not support inputs of type Utf8.\" No function matches the given name and argument types 'avg(Utf8)'. You might need to add explicit type casts.\n\tCandidate functions:\n\tavg(UserDefined)"}},
      {"SELECT sum(s) FROM ~m3",
       {:error, 400,
        "Error during planning: Execution error: Function 'sum' user-defined coercion failed with \"Execution error: Sum not supported for Utf8\" No function matches the given name and argument types 'sum(Utf8)'. You might need to add explicit type casts.\n\tCandidate functions:\n\tsum(UserDefined)"}},
      {"SELECT spread(s) FROM ~m3",
       {:error, 400,
        "Error during planning: Failed to coerce arguments to satisfy a call to 'spread' function: coercion from Utf8 to the signature OneOf([Exact([Int64]), Exact([UInt64]), Exact([Float64])]) failed No function matches the given name and argument types 'spread(Utf8)'. You might need to add explicit type casts.\n\tCandidate functions:\n\tspread(Int64)\n\tspread(UInt64)\n\tspread(Float64)"}},
      {"SELECT stddev(s) FROM ~m3",
       {:error, 400,
        "Error during planning: Function 'stddev' expects NativeType::Numeric but received NativeType::String No function matches the given name and argument types 'stddev(Utf8)'. You might need to add explicit type casts.\n\tCandidate functions:\n\tstddev(Numeric(1))"}},
      {"SELECT max(s) FROM ~m3",
       [
         {"2024-01-01 00:05:10", %{"max" => "z"}}
       ]},
      {"SELECT min(s) FROM ~m3",
       [
         {"2024-01-01 00:00:10", %{"min" => "x"}}
       ]},
      {"SELECT first(s) FROM ~m3",
       [
         {"2024-01-01 00:00:10", %{"first" => "x"}}
       ]},
      {"SELECT count(s) FROM ~m3",
       [
         {"1970-01-01 00:00:00", %{"count" => 3}}
       ]},
      {"SELECT median(n) FROM ~m3 WHERE time < '2024-01-01T00:00:05Z'", []},
      {"SELECT stddev(n) FROM ~m3 WHERE time < '2024-01-01T00:00:50Z'",
       [
         {"1970-01-01 00:00:00", %{}}
       ]},
      {"SELECT median(u), count(u) FROM ~m3 WHERE time < '2024-01-01T00:04:00Z'",
       [
         {"1970-01-01 00:00:00", %{"count" => 2, "median" => 1}}
       ]},
      {"SELECT sum(n), median(n) FROM ~m3",
       [
         {"1970-01-01 00:00:00", %{"median" => 1, "sum" => -6}}
       ]},
      {"SELECT mean(b) FROM ~m4 WHERE time >= '2024-01-01T00:01:00Z' AND time < '2024-01-01T00:02:00Z'",
       []},
      {"SELECT mean(b), mean(a) FROM ~m4 WHERE time >= '2024-01-01T00:01:00Z' AND time < '2024-01-01T00:02:00Z'",
       [
         {"2024-01-01 00:01:00", %{"mean_1" => 2.0}}
       ]},
      {"SELECT stddev(a) FROM ~m4 WHERE time >= '2024-01-01T00:01:00Z' AND time < '2024-01-01T00:02:00Z'",
       [
         {"2024-01-01 00:01:00", %{}}
       ]},
      {"SELECT stddev(a), count(a) FROM ~m4 WHERE time >= '2024-01-01T00:01:00Z' AND time < '2024-01-01T00:02:00Z'",
       [
         {"2024-01-01 00:01:00", %{"count" => 1}}
       ]},
      {"SELECT stddev(a), stddev(b) FROM ~m4",
       [
         {"1970-01-01 00:00:00", %{"stddev" => 2.0816659994661326, "stddev_1" => 20.0}}
       ]},
      {"SELECT first(host) FROM ~m1", []},
      {"SELECT count(host) FROM ~m1", []},
      {"SELECT max(host) FROM ~m1", []},
      {"SELECT mean(host) FROM ~m1", []},
      {"SELECT usage, mean(usage) FROM ~m1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"SELECT mean(usage), usage FROM ~m1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"SELECT max(usage), usage FROM ~m1",
       [
         {"2024-01-01 00:02:10", %{"max" => 20.0, "usage" => 20.0}}
       ]},
      {"SELECT max(usage), n FROM ~m1",
       [
         {"2024-01-01 00:02:10", %{"max" => 20.0, "n" => 20}}
       ]},
      {"SELECT max(usage), mean(usage), n FROM ~m1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"SELECT mean(usage), host FROM ~m1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"SELECT median(1) FROM ~m1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: expected field argument in median(), got Literal(Integer(1))"}},
      {"SELECT spread(true) FROM ~m1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: expected field argument in spread(), got Literal(Boolean(true))"}},
      {"SELECT stddev('a') FROM ~m1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: expected field argument in stddev(), got Literal(String(\"a\"))"}},
      {"SELECT distinct(1) FROM ~m1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: expected field argument in distinct()"}},
      {"SELECT median(usage), n FROM ~m1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"SELECT first(usage), n FROM ~m1",
       [
         {"2024-01-01 00:00:00", %{"first" => 1.0, "n" => 1}}
       ]},
      {"SELECT first(usage), last(usage), n FROM ~m1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing multiple selector functions with tags or fields is not supported"}},
      {"SELECT median(a), spread(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.5, "spread" => 1.0}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:04:00", %{"median" => 5.0, "spread" => 0.0}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT stddev(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m)",
       [
         {"2024-01-01 00:00:00", %{"stddev" => 0.7071067811865476}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:04:00", %{}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT count(distinct(a)) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m)",
       [
         {"2024-01-01 00:00:00", %{"count" => 2}},
         {"2024-01-01 00:02:00", %{"count" => 0}},
         {"2024-01-01 00:04:00", %{"count" => 1}},
         {"2024-01-01 00:06:00", %{"count" => 0}}
       ]},
      {"SELECT median(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.5}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:04:00", %{"median" => 5.0}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT spread(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m)",
       [
         {"2024-01-01 00:00:00", %{"spread" => 1.0}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:04:00", %{"spread" => 0.0}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT median(a), spread(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.5, "spread" => 1.0}},
         {"2024-01-01 00:04:00", %{"median" => 5.0, "spread" => 0.0}}
       ]},
      {"SELECT stddev(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"stddev" => 0.7071067811865476}},
         {"2024-01-01 00:04:00", %{}}
       ]},
      {"SELECT count(distinct(a)) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"count" => 2}},
         {"2024-01-01 00:04:00", %{"count" => 1}}
       ]},
      {"SELECT median(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.5}},
         {"2024-01-01 00:04:00", %{"median" => 5.0}}
       ]},
      {"SELECT spread(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"spread" => 1.0}},
         {"2024-01-01 00:04:00", %{"spread" => 0.0}}
       ]},
      {"SELECT median(a), spread(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.5, "spread" => 1.0}},
         {"2024-01-01 00:02:00", %{"median" => 0.0, "spread" => 0.0}},
         {"2024-01-01 00:04:00", %{"median" => 5.0, "spread" => 0.0}},
         {"2024-01-01 00:06:00", %{"median" => 0.0, "spread" => 0.0}}
       ]},
      {"SELECT stddev(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"stddev" => 0.7071067811865476}},
         {"2024-01-01 00:02:00", %{"stddev" => 0.0}},
         {"2024-01-01 00:04:00", %{"stddev" => 0.0}},
         {"2024-01-01 00:06:00", %{"stddev" => 0.0}}
       ]},
      {"SELECT count(distinct(a)) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"count" => 2}},
         {"2024-01-01 00:02:00", %{"count" => 0}},
         {"2024-01-01 00:04:00", %{"count" => 1}},
         {"2024-01-01 00:06:00", %{"count" => 0}}
       ]},
      {"SELECT median(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.5}},
         {"2024-01-01 00:02:00", %{"median" => 0.0}},
         {"2024-01-01 00:04:00", %{"median" => 5.0}},
         {"2024-01-01 00:06:00", %{"median" => 0.0}}
       ]},
      {"SELECT spread(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"spread" => 1.0}},
         {"2024-01-01 00:02:00", %{"spread" => 0.0}},
         {"2024-01-01 00:04:00", %{"spread" => 0.0}},
         {"2024-01-01 00:06:00", %{"spread" => 0.0}}
       ]},
      {"SELECT median(a), spread(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.5, "spread" => 1.0}},
         {"2024-01-01 00:02:00", %{"median" => 1.5, "spread" => 1.0}},
         {"2024-01-01 00:04:00", %{"median" => 5.0, "spread" => 0.0}},
         {"2024-01-01 00:06:00", %{"median" => 5.0, "spread" => 0.0}}
       ]},
      {"SELECT stddev(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"stddev" => 0.7071067811865476}},
         {"2024-01-01 00:02:00", %{"stddev" => 0.7071067811865476}},
         {"2024-01-01 00:04:00", %{"stddev" => 0.7071067811865476}},
         {"2024-01-01 00:06:00", %{"stddev" => 0.7071067811865476}}
       ]},
      {"SELECT count(distinct(a)) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"count" => 2}},
         {"2024-01-01 00:02:00", %{"count" => 2}},
         {"2024-01-01 00:04:00", %{"count" => 1}},
         {"2024-01-01 00:06:00", %{"count" => 1}}
       ]},
      {"SELECT median(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.5}},
         {"2024-01-01 00:02:00", %{"median" => 1.5}},
         {"2024-01-01 00:04:00", %{"median" => 5.0}},
         {"2024-01-01 00:06:00", %{"median" => 5.0}}
       ]},
      {"SELECT spread(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"spread" => 1.0}},
         {"2024-01-01 00:02:00", %{"spread" => 1.0}},
         {"2024-01-01 00:04:00", %{"spread" => 0.0}},
         {"2024-01-01 00:06:00", %{"spread" => 0.0}}
       ]},
      {"SELECT median(a), spread(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(linear)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.5, "spread" => 1.0}},
         {"2024-01-01 00:02:00", %{"median" => 3.25, "spread" => 0.5}},
         {"2024-01-01 00:04:00", %{"median" => 5.0, "spread" => 0.0}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT stddev(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(linear)",
       [
         {"2024-01-01 00:00:00", %{"stddev" => 0.7071067811865476}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:04:00", %{}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT median(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(linear)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.5}},
         {"2024-01-01 00:02:00", %{"median" => 3.25}},
         {"2024-01-01 00:04:00", %{"median" => 5.0}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT spread(a) FROM ~m4 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(2m) fill(linear)",
       [
         {"2024-01-01 00:00:00", %{"spread" => 1.0}},
         {"2024-01-01 00:02:00", %{"spread" => 0.5}},
         {"2024-01-01 00:04:00", %{"spread" => 0.0}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT median(usage) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.0}},
         {"2024-01-01 00:01:00", %{}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{"median" => 2.0}},
         {"2024-01-01 00:04:00", %{}},
         {"2024-01-01 00:05:00", %{"median" => 9.0}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT spread(n) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"spread" => 0}},
         {"2024-01-01 00:01:00", %{}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{"spread" => 0}},
         {"2024-01-01 00:04:00", %{}},
         {"2024-01-01 00:05:00", %{"spread" => 9}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT stddev(usage) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{}},
         {"2024-01-01 00:01:00", %{}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:04:00", %{}},
         {"2024-01-01 00:05:00", %{}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT count(distinct(n)) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"count" => 1}},
         {"2024-01-01 00:01:00", %{"count" => 0}},
         {"2024-01-01 00:02:00", %{"count" => 0}},
         {"2024-01-01 00:03:00", %{"count" => 1}},
         {"2024-01-01 00:04:00", %{"count" => 0}},
         {"2024-01-01 00:05:00", %{"count" => 1}},
         {"2024-01-01 00:06:00", %{"count" => 0}}
       ]},
      {"SELECT median(n) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1}},
         {"2024-01-01 00:01:00", %{}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{"median" => 2}},
         {"2024-01-01 00:04:00", %{}},
         {"2024-01-01 00:05:00", %{"median" => -9}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT median(u) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1}},
         {"2024-01-01 00:01:00", %{}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{"median" => 2}},
         {"2024-01-01 00:04:00", %{}},
         {"2024-01-01 00:05:00", %{"median" => 9}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT median(usage) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.0}},
         {"2024-01-01 00:03:00", %{"median" => 2.0}},
         {"2024-01-01 00:05:00", %{"median" => 9.0}}
       ]},
      {"SELECT spread(n) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"spread" => 0}},
         {"2024-01-01 00:03:00", %{"spread" => 0}},
         {"2024-01-01 00:05:00", %{"spread" => 9}}
       ]},
      {"SELECT stddev(usage) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:05:00", %{}}
       ]},
      {"SELECT count(distinct(n)) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"count" => 1}},
         {"2024-01-01 00:03:00", %{"count" => 1}},
         {"2024-01-01 00:05:00", %{"count" => 1}}
       ]},
      {"SELECT median(n) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1}},
         {"2024-01-01 00:03:00", %{"median" => 2}},
         {"2024-01-01 00:05:00", %{"median" => -9}}
       ]},
      {"SELECT median(u) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(none)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1}},
         {"2024-01-01 00:03:00", %{"median" => 2}},
         {"2024-01-01 00:05:00", %{"median" => 9}}
       ]},
      {"SELECT median(usage) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.0}},
         {"2024-01-01 00:01:00", %{"median" => 0.0}},
         {"2024-01-01 00:02:00", %{"median" => 0.0}},
         {"2024-01-01 00:03:00", %{"median" => 2.0}},
         {"2024-01-01 00:04:00", %{"median" => 0.0}},
         {"2024-01-01 00:05:00", %{"median" => 9.0}},
         {"2024-01-01 00:06:00", %{"median" => 0.0}}
       ]},
      {"SELECT spread(n) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"spread" => 0}},
         {"2024-01-01 00:01:00", %{"spread" => 0}},
         {"2024-01-01 00:02:00", %{"spread" => 0}},
         {"2024-01-01 00:03:00", %{"spread" => 0}},
         {"2024-01-01 00:04:00", %{"spread" => 0}},
         {"2024-01-01 00:05:00", %{"spread" => 9}},
         {"2024-01-01 00:06:00", %{"spread" => 0}}
       ]},
      {"SELECT stddev(usage) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"stddev" => 0.0}},
         {"2024-01-01 00:01:00", %{"stddev" => 0.0}},
         {"2024-01-01 00:02:00", %{"stddev" => 0.0}},
         {"2024-01-01 00:03:00", %{"stddev" => 0.0}},
         {"2024-01-01 00:04:00", %{"stddev" => 0.0}},
         {"2024-01-01 00:05:00", %{"stddev" => 0.0}},
         {"2024-01-01 00:06:00", %{"stddev" => 0.0}}
       ]},
      {"SELECT count(distinct(n)) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"count" => 1}},
         {"2024-01-01 00:01:00", %{"count" => 0}},
         {"2024-01-01 00:02:00", %{"count" => 0}},
         {"2024-01-01 00:03:00", %{"count" => 1}},
         {"2024-01-01 00:04:00", %{"count" => 0}},
         {"2024-01-01 00:05:00", %{"count" => 1}},
         {"2024-01-01 00:06:00", %{"count" => 0}}
       ]},
      {"SELECT median(n) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1}},
         {"2024-01-01 00:01:00", %{"median" => 0}},
         {"2024-01-01 00:02:00", %{"median" => 0}},
         {"2024-01-01 00:03:00", %{"median" => 2}},
         {"2024-01-01 00:04:00", %{"median" => 0}},
         {"2024-01-01 00:05:00", %{"median" => -9}},
         {"2024-01-01 00:06:00", %{"median" => 0}}
       ]},
      {"SELECT median(u) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(0)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1}},
         {"2024-01-01 00:01:00", %{"median" => 0}},
         {"2024-01-01 00:02:00", %{"median" => 0}},
         {"2024-01-01 00:03:00", %{"median" => 2}},
         {"2024-01-01 00:04:00", %{"median" => 0}},
         {"2024-01-01 00:05:00", %{"median" => 9}},
         {"2024-01-01 00:06:00", %{"median" => 0}}
       ]},
      {"SELECT median(usage) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.0}},
         {"2024-01-01 00:01:00", %{"median" => 1.0}},
         {"2024-01-01 00:02:00", %{"median" => 1.0}},
         {"2024-01-01 00:03:00", %{"median" => 2.0}},
         {"2024-01-01 00:04:00", %{"median" => 2.0}},
         {"2024-01-01 00:05:00", %{"median" => 9.0}},
         {"2024-01-01 00:06:00", %{"median" => 9.0}}
       ]},
      {"SELECT spread(n) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"spread" => 0}},
         {"2024-01-01 00:01:00", %{"spread" => 0}},
         {"2024-01-01 00:02:00", %{"spread" => 0}},
         {"2024-01-01 00:03:00", %{"spread" => 0}},
         {"2024-01-01 00:04:00", %{"spread" => 0}},
         {"2024-01-01 00:05:00", %{"spread" => 9}},
         {"2024-01-01 00:06:00", %{"spread" => 9}}
       ]},
      {"SELECT stddev(usage) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{}},
         {"2024-01-01 00:01:00", %{}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:04:00", %{}},
         {"2024-01-01 00:05:00", %{}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT count(distinct(n)) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"count" => 1}},
         {"2024-01-01 00:01:00", %{"count" => 1}},
         {"2024-01-01 00:02:00", %{"count" => 1}},
         {"2024-01-01 00:03:00", %{"count" => 1}},
         {"2024-01-01 00:04:00", %{"count" => 1}},
         {"2024-01-01 00:05:00", %{"count" => 1}},
         {"2024-01-01 00:06:00", %{"count" => 1}}
       ]},
      {"SELECT median(n) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1}},
         {"2024-01-01 00:01:00", %{"median" => 1}},
         {"2024-01-01 00:02:00", %{"median" => 1}},
         {"2024-01-01 00:03:00", %{"median" => 2}},
         {"2024-01-01 00:04:00", %{"median" => 2}},
         {"2024-01-01 00:05:00", %{"median" => -9}},
         {"2024-01-01 00:06:00", %{"median" => -9}}
       ]},
      {"SELECT median(u) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(previous)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1}},
         {"2024-01-01 00:01:00", %{"median" => 1}},
         {"2024-01-01 00:02:00", %{"median" => 1}},
         {"2024-01-01 00:03:00", %{"median" => 2}},
         {"2024-01-01 00:04:00", %{"median" => 2}},
         {"2024-01-01 00:05:00", %{"median" => 9}},
         {"2024-01-01 00:06:00", %{"median" => 9}}
       ]},
      {"SELECT median(usage) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(linear)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1.0}},
         {"2024-01-01 00:01:00", %{"median" => 1.3333333333333333}},
         {"2024-01-01 00:02:00", %{"median" => 1.6666666666666665}},
         {"2024-01-01 00:03:00", %{"median" => 2.0}},
         {"2024-01-01 00:04:00", %{"median" => 5.5}},
         {"2024-01-01 00:05:00", %{"median" => 9.0}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT spread(n) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(linear)",
       [
         {"2024-01-01 00:00:00", %{"spread" => 0}},
         {"2024-01-01 00:01:00", %{"spread" => 0}},
         {"2024-01-01 00:02:00", %{"spread" => 0}},
         {"2024-01-01 00:03:00", %{"spread" => 0}},
         {"2024-01-01 00:04:00", %{"spread" => 4}},
         {"2024-01-01 00:05:00", %{"spread" => 9}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT stddev(usage) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(linear)",
       [
         {"2024-01-01 00:00:00", %{}},
         {"2024-01-01 00:01:00", %{}},
         {"2024-01-01 00:02:00", %{}},
         {"2024-01-01 00:03:00", %{}},
         {"2024-01-01 00:04:00", %{}},
         {"2024-01-01 00:05:00", %{}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT median(n) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(linear)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1}},
         {"2024-01-01 00:01:00", %{"median" => 1}},
         {"2024-01-01 00:02:00", %{"median" => 1}},
         {"2024-01-01 00:03:00", %{"median" => 2}},
         {"2024-01-01 00:04:00", %{"median" => -3}},
         {"2024-01-01 00:05:00", %{"median" => -9}},
         {"2024-01-01 00:06:00", %{}}
       ]},
      {"SELECT median(u) FROM ~m3 WHERE time >= '2024-01-01T00:00:00Z' AND time < '2024-01-01T00:07:00Z' GROUP BY time(1m) fill(linear)",
       [
         {"2024-01-01 00:00:00", %{"median" => 1}},
         {"2024-01-01 00:01:00", %{"median" => 1}},
         {"2024-01-01 00:02:00", %{"median" => 1}},
         {"2024-01-01 00:03:00", %{"median" => 2}},
         {"2024-01-01 00:04:00", %{"median" => 5}},
         {"2024-01-01 00:05:00", %{"median" => 9}},
         {"2024-01-01 00:06:00", %{}}
       ]}
    ]
  end
end
