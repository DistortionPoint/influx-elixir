defmodule InfluxElixir.Contract.InfluxQLProjectionCases do
  @moduledoc "Statements over the `cpu` fixture of this module with the answers InfluxDB 3 Core 3.10.1 gave: arithmetic of an unsigned field beside a string, a boolean, a tag or the time (the planner's coercion error, where the other numbers make a null), a math function of a time beside an operand, the names of the columns of a projection (the select list in order, then the time, the dimensions and the tags `top()` chooses by, and the planning error of two columns with one name), the windows of `LIMIT` and `OFFSET` (counted per selected column, `top()` and `bottom()` beside fields too), the time in parentheses, and a column the measurement lacks beside a tag, a string or a boolean (a constant false). A row is `{time, columns}`, the time `YYYY-MM-DD HH:MM:SS`; a row whose time column is renamed has `nil`."

  @doc "The names the cases use, from one unique `prefix`: `~p1`."
  @spec names(binary()) :: %{binary() => binary()}
  def names(prefix), do: %{"p1" => prefix <> "_p1"}

  @doc """
  The fixture, as line protocol, with `names/1` substituted: `~p1` thirty points a minute apart
  over two tags (`host` of three values, `region` of two) and five fields, none of them in
  every point: an integer `n`, an unsigned `u`, a float `usage`, a string `s` and a boolean `ok`.
  """
  @spec fixture(%{binary() => binary()}) :: [binary()]
  def fixture(names),
    do:
      substitute(
        [
          ~S|~p1,host=a,region=us n=-10i,u=1u,usage=0.25,ok=true 1696118400000000000|,
          ~S|~p1,host=b,region=eu n=-7i,usage=1.75,s="str1" 1696118460000000000|,
          ~S|~p1,host=c,region=us u=3u,usage=3.25,s="str2",ok=true 1696118520000000000|,
          ~S|~p1,host=a,region=eu n=-1i,u=4u,s="str3",ok=false 1696118580000000000|,
          ~S|~p1,host=b,region=us n=2i,u=5u,usage=6.25,s="str0" 1696118640000000000|,
          ~S|~p1,host=c,region=eu n=5i,usage=7.75,s="str1",ok=false 1696118700000000000|,
          ~S|~p1,host=a,region=us n=8i,u=7u,usage=9.25,ok=true 1696118760000000000|,
          ~S|~p1,host=b,region=eu u=8u,usage=10.75,s="str3" 1696118820000000000|,
          ~S|~p1,host=c,region=us n=14i,u=9u,usage=12.25,s="str0",ok=true 1696118880000000000|,
          ~S|~p1,host=a,region=eu n=17i,usage=13.75,s="str1",ok=false 1696118940000000000|,
          ~S|~p1,host=b,region=us n=20i,u=11u,s="str2" 1696119000000000000|,
          ~S|~p1,host=c,region=eu n=23i,u=12u,usage=16.75,s="str3",ok=false 1696119060000000000|,
          ~S|~p1,host=a,region=us u=13u,usage=18.25,ok=true 1696119120000000000|,
          ~S|~p1,host=b,region=eu n=29i,usage=19.75,s="str1" 1696119180000000000|,
          ~S|~p1,host=c,region=us n=32i,u=15u,usage=21.25,s="str2",ok=true 1696119240000000000|,
          ~S|~p1,host=a,region=eu n=35i,u=16u,usage=22.75,s="str3",ok=false 1696119300000000000|,
          ~S|~p1,host=b,region=us n=38i,u=17u,usage=24.25,s="str0" 1696119360000000000|,
          ~S|~p1,host=c,region=eu s="str1",ok=false 1696119420000000000|,
          ~S|~p1,host=a,region=us n=44i,u=19u,usage=27.25,ok=true 1696119480000000000|,
          ~S|~p1,host=b,region=eu n=47i,u=20u,usage=28.75,s="str3" 1696119540000000000|,
          ~S|~p1,host=c,region=us n=50i,u=21u,usage=30.25,s="str0",ok=true 1696119600000000000|,
          ~S|~p1,host=a,region=eu n=53i,usage=31.75,s="str1",ok=false 1696119660000000000|,
          ~S|~p1,host=b,region=us u=23u,usage=33.25,s="str2" 1696119720000000000|,
          ~S|~p1,host=c,region=eu n=59i,u=24u,usage=34.75,s="str3",ok=false 1696119780000000000|,
          ~S|~p1,host=a,region=us n=62i,u=25u,ok=true 1696119840000000000|,
          ~S|~p1,host=b,region=eu n=65i,usage=37.75,s="str1" 1696119900000000000|,
          ~S|~p1,host=c,region=us n=68i,u=27u,usage=39.25,s="str2",ok=true 1696119960000000000|,
          ~S|~p1,host=a,region=eu u=28u,usage=40.75,s="str3",ok=false 1696120020000000000|,
          ~S|~p1,host=b,region=us n=74i,u=29u,usage=42.25,s="str0" 1696120080000000000|,
          ~S|~p1,host=c,region=eu n=77i,usage=43.75,s="str1",ok=false 1696120140000000000|
        ],
        names
      )

  defp substitute(lines, names) do
    Enum.map(lines, fn line ->
      Enum.reduce(names, line, fn {key, name}, acc -> String.replace(acc, "~" <> key, name) end)
    end)
  end

  @doc "An unsigned number under arithmetic with a string, a boolean, a tag or the time in a `WHERE` is the planner's coercion error, worded with the type of each operand as written; the other numbers make a null."
  @spec coercions() :: [{binary(), term()}]
  def coercions do
    [
      {"select n from ~p1 where u + s = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where u + 'x' = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where u + ok = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Boolean to valid types"}},
      {"select n from ~p1 where u + host = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Dictionary(Int32, Utf8) to valid types"}},
      {"select n from ~p1 where u * true = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 * Boolean to valid types"}},
      {"select n from ~p1 where s - u = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Utf8 - UInt64 to valid types"}},
      {"select n from ~p1 where abs(u) + s = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where (u + s) > 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where 2.5 != u / s",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 / Utf8 to valid types"}},
      {"select n from ~p1 where ok != u + s",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where u + time = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Timestamp(ns) to valid types"}},
      {"select n from ~p1 where time + u = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Timestamp(ns) + UInt64 to valid types"}},
      {"select n from ~p1 where u - time = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 - Timestamp(ns) to valid types"}},
      {"select n from ~p1 where u + n + s = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where (u + n) + s = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where u + (n + s) = 1", []},
      {"select n from ~p1 where s + (u + n) = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Utf8 + UInt64 to valid types"}},
      {"select n from ~p1 where (n + s) + u = 1", []},
      {"select n from ~p1 where u + usage + s = 1", []},
      {"select n from ~p1 where (u + usage) + s = 1", []},
      {"select n from ~p1 where s + u * 2 = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Utf8 + UInt64 to valid types"}},
      {"select n from ~p1 where u * 2 + s = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where -u + s = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where u + 'x' + 'y' = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where u + 's' = 'q'",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where s = u + s",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where u + s = 1 or n = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where n = 1 or u + s = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where u + abs(s) = 1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::String No function matches the given name and argument types 'abs(Utf8)'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select n from ~p1 where u + 1 = 2 and u + s = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where u + u = 4", []},
      {"select n from ~p1 where u + n = 4", []},
      {"select n from ~p1 where u + 1 + s = 4",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where 1 + u + s = 4",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Utf8 to valid types"}},
      {"select n from ~p1 where 1 + s + u = 4", []},
      {"select n from ~p1 where u + n + ok = 4",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 + Boolean to valid types"}},
      {"select n from ~p1 where u / host = 4",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 / Dictionary(Int32, Utf8) to valid types"}},
      {"select n from ~p1 where host + u = 4",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Dictionary(Int32, Utf8) + UInt64 to valid types"}},
      {"select n from ~p1 where ok + u = 4",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Boolean + UInt64 to valid types"}},
      {"select n from ~p1 where 'x' + u = 4",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Utf8 + UInt64 to valid types"}},
      {"select n from ~p1 where 1.5 + u + 'x' = 4", []},
      {"select n from ~p1 where nosuch + u + s = 4", []},
      {"select n from ~p1 where u + nosuch = 4", []}
    ]
  end

  @doc "A math function of a time: the operation around it is rejected when the projection is rewritten, the function itself only when a field is selected beside it."
  @spec time_functions() :: [{binary(), term()}]
  def time_functions do
    [
      {"select true / abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: boolean and timestamp"}},
      {"select abs(n), true / abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: boolean and timestamp"}},
      {"select 1 / abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: integer and timestamp"}},
      {"select abs(-abs(time)) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator *: integer and timestamp"}},
      {"select abs(time) from ~p1", []},
      {"select abs(time), n from ~p1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select abs(time) + 1 from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: timestamp and integer"}},
      {"select 1 + abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: integer and timestamp"}},
      {"select abs(time) + true from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: timestamp and boolean"}},
      {"select true + abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: boolean and timestamp"}},
      {"select abs(time) + 'x' from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: timestamp and string"}},
      {"select 'x' + abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: string and timestamp"}},
      {"select abs(time) + host from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: timestamp and tag"}},
      {"select host + abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: tag and timestamp"}},
      {"select abs(time) + abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: timestamp and timestamp"}},
      {"select abs(abs(time)) from ~p1", []},
      {"select -abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator *: integer and timestamp"}},
      {"select abs(time) * n from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator *: timestamp and integer"}},
      {"select n * abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator *: integer and timestamp"}},
      {"select abs(time) + u from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: timestamp and unsigned"}},
      {"select u / abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: unsigned and timestamp"}},
      {"select true / abs(time) from ~p1 limit 1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: boolean and timestamp"}},
      {"select abs(time) / true from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: timestamp and boolean"}},
      {"select n, true + n from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: boolean and integer"}},
      {"select true + n from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: boolean and integer"}},
      {"select sqrt(time) + true from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: timestamp and boolean"}},
      {"select true + sqrt(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: boolean and timestamp"}},
      {"select true * floor(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator *: boolean and timestamp"}},
      {"select 'a' * abs(time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator *: string and timestamp"}},
      {"select 2 * abs(-time) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator *: integer and timestamp"}},
      {"select sqrt(abs(time)) from ~p1", []},
      {"select abs(sqrt(time)) from ~p1", []},
      {"select abs(time) from ~p1 where n > 0", []},
      {"select 1 / abs(time) from ~p1 where n > 100",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: integer and timestamp"}},
      {"select abs(time), host from ~p1", []},
      {"select abs(time), time from ~p1", []},
      {"select abs(time), n * 2 from ~p1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select abs(time), abs(n) from ~p1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select n, abs(time) from ~p1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select abs(time), nosuch from ~p1", []},
      {"select abs(time), n from ~p1 where n > 1000",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select abs(time), n from ~p1 limit 1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select abs(time), s from ~p1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select abs(time), ok from ~p1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select abs(time), u from ~p1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select abs(time), host, region from ~p1", []}
    ]
  end

  @doc "`LIMIT` and `OFFSET` count per selected column, `*` and `top()` / `bottom()` beside fields included, under the names the columns have."
  @spec windows() :: [{binary(), term()}]
  def windows do
    [
      {"select time as n, * from ~p1 limit 1",
       [
         nil: %{
           "host" => "a",
           "n" => ~U[2023-10-01 00:00:00.000000Z],
           "n_1" => -10,
           "ok" => true,
           "region" => "us",
           "u" => 1,
           "usage" => 0.25
         },
         nil: %{
           "host" => "b",
           "n" => ~U[2023-10-01 00:01:00.000000Z],
           "region" => "eu",
           "s" => "str1"
         }
       ]},
      {"select time as usage, * from ~p1 limit 1",
       [
         nil: %{
           "host" => "a",
           "n" => -10,
           "ok" => true,
           "region" => "us",
           "u" => 1,
           "usage" => ~U[2023-10-01 00:00:00.000000Z],
           "usage_1" => 0.25
         },
         nil: %{
           "host" => "b",
           "region" => "eu",
           "s" => "str1",
           "usage" => ~U[2023-10-01 00:01:00.000000Z]
         }
       ]},
      {"select time as n, * from ~p1 group by host limit 1",
       [
         nil: %{
           "host" => "a",
           "n" => ~U[2023-10-01 00:00:00.000000Z],
           "n_1" => -10,
           "ok" => true,
           "region" => "us",
           "u" => 1,
           "usage" => 0.25
         },
         nil: %{
           "host" => "a",
           "n" => ~U[2023-10-01 00:03:00.000000Z],
           "region" => "eu",
           "s" => "str3"
         },
         nil: %{
           "host" => "b",
           "n" => ~U[2023-10-01 00:01:00.000000Z],
           "n_1" => -7,
           "region" => "eu",
           "s" => "str1",
           "usage" => 1.75
         },
         nil: %{"host" => "b", "n" => ~U[2023-10-01 00:04:00.000000Z], "region" => "us", "u" => 5},
         nil: %{
           "host" => "c",
           "n" => ~U[2023-10-01 00:02:00.000000Z],
           "ok" => true,
           "region" => "us",
           "s" => "str2",
           "u" => 3,
           "usage" => 3.25
         },
         nil: %{
           "host" => "c",
           "n" => ~U[2023-10-01 00:05:00.000000Z],
           "n_1" => 5,
           "region" => "eu"
         }
       ]},
      {"select time as usage, * from ~p1 group by host limit 1",
       [
         nil: %{
           "host" => "a",
           "n" => -10,
           "ok" => true,
           "region" => "us",
           "u" => 1,
           "usage" => ~U[2023-10-01 00:00:00.000000Z],
           "usage_1" => 0.25
         },
         nil: %{
           "host" => "a",
           "region" => "eu",
           "s" => "str3",
           "usage" => ~U[2023-10-01 00:03:00.000000Z]
         },
         nil: %{
           "host" => "b",
           "n" => -7,
           "region" => "eu",
           "s" => "str1",
           "usage" => ~U[2023-10-01 00:01:00.000000Z],
           "usage_1" => 1.75
         },
         nil: %{
           "host" => "b",
           "region" => "us",
           "u" => 5,
           "usage" => ~U[2023-10-01 00:04:00.000000Z]
         },
         nil: %{
           "host" => "c",
           "ok" => true,
           "region" => "us",
           "s" => "str2",
           "u" => 3,
           "usage" => ~U[2023-10-01 00:02:00.000000Z],
           "usage_1" => 3.25
         },
         nil: %{
           "host" => "c",
           "n" => 5,
           "region" => "eu",
           "usage" => ~U[2023-10-01 00:05:00.000000Z]
         }
       ]},
      {"select time as n, * from ~p1 limit 2 offset 1",
       [
         nil: %{
           "host" => "b",
           "n" => ~U[2023-10-01 00:01:00.000000Z],
           "n_1" => -7,
           "region" => "eu",
           "usage" => 1.75
         },
         nil: %{
           "host" => "c",
           "n" => ~U[2023-10-01 00:02:00.000000Z],
           "ok" => true,
           "region" => "us",
           "s" => "str2",
           "u" => 3,
           "usage" => 3.25
         },
         nil: %{
           "host" => "a",
           "n" => ~U[2023-10-01 00:03:00.000000Z],
           "n_1" => -1,
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 4
         }
       ]},
      {"select *, time as n from ~p1 limit 1",
       [
         nil: %{
           "host" => "a",
           "n" => -10,
           "n_1" => ~U[2023-10-01 00:00:00.000000Z],
           "ok" => true,
           "region" => "us",
           "u" => 1,
           "usage" => 0.25
         },
         nil: %{
           "host" => "b",
           "n_1" => ~U[2023-10-01 00:01:00.000000Z],
           "region" => "eu",
           "s" => "str1"
         }
       ]},
      {"select time as n, n from ~p1 limit 1",
       [nil: %{"n" => ~U[2023-10-01 00:00:00.000000Z], "n_1" => -10}]},
      {"select n, time as n from ~p1 limit 1",
       [nil: %{"n" => -10, "n_1" => ~U[2023-10-01 00:00:00.000000Z]}]},
      {"select usage as host, top(n, host, 2) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"host" => 42.25, "host_1" => "b", "top" => 74}},
         {"2023-10-01 00:29:00", %{"host" => 43.75, "host_1" => "c", "top" => 77}}
       ]},
      {"select usage as host, bottom(n, host, 2) from ~p1",
       [
         {"2023-10-01 00:00:00", %{"bottom" => -10, "host" => 0.25, "host_1" => "a"}},
         {"2023-10-01 00:01:00", %{"bottom" => -7, "host" => 1.75, "host_1" => "b"}}
       ]},
      {"select ok, bottom(n, host, region, 40) as host, u as region_1 from ~p1 group by region",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.region AS region_1\" at position 5 and \"~p1.u AS region_1\" at position 6 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select ok, bottom(n, host, region, 40) as host, u as region_1 from ~p1",
       [
         {"2023-10-01 00:00:00",
          %{"host" => -10, "host_1" => "a", "ok" => true, "region" => "us", "region_1" => 1}},
         {"2023-10-01 00:01:00", %{"host" => -7, "host_1" => "b", "region" => "eu"}},
         {"2023-10-01 00:03:00",
          %{"host" => -1, "host_1" => "a", "ok" => false, "region" => "eu", "region_1" => 4}},
         {"2023-10-01 00:04:00",
          %{"host" => 2, "host_1" => "b", "region" => "us", "region_1" => 5}},
         {"2023-10-01 00:05:00",
          %{"host" => 5, "host_1" => "c", "ok" => false, "region" => "eu"}},
         {"2023-10-01 00:08:00",
          %{"host" => 14, "host_1" => "c", "ok" => true, "region" => "us", "region_1" => 9}}
       ]},
      {"select ok, bottom(n, host, region, 40) as host from ~p1 group by region",
       [
         {"2023-10-01 00:01:00",
          %{"host" => -7, "host_1" => "b", "region" => "eu", "region_1" => "eu"}},
         {"2023-10-01 00:03:00",
          %{"host" => -1, "host_1" => "a", "ok" => false, "region" => "eu", "region_1" => "eu"}},
         {"2023-10-01 00:05:00",
          %{"host" => 5, "host_1" => "c", "ok" => false, "region" => "eu", "region_1" => "eu"}},
         {"2023-10-01 00:00:00",
          %{"host" => -10, "host_1" => "a", "ok" => true, "region" => "us", "region_1" => "us"}},
         {"2023-10-01 00:04:00",
          %{"host" => 2, "host_1" => "b", "region" => "us", "region_1" => "us"}},
         {"2023-10-01 00:08:00",
          %{"host" => 14, "host_1" => "c", "ok" => true, "region" => "us", "region_1" => "us"}}
       ]},
      {"select s, u, bottom(ok, 40) as x from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m) limit 1",
       [
         {"2023-10-01 00:00:00", %{"u" => 1, "x" => true}},
         {"2023-10-01 00:01:00", %{"s" => "str1"}}
       ]},
      {"select ((usage)), ((time)) from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"time_1" => ~U[2023-10-01 00:00:00.000000Z], "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"time_1" => ~U[2023-10-01 00:01:00.000000Z], "usage" => 1.75}}
       ]},
      {"select -u, +nosuch / host from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"nosuch_host" => false, "u" => 18_446_744_073_709_551_614}},
         {"2023-10-01 00:02:00", %{"nosuch_host" => false, "u" => 18_446_744_073_709_551_610}}
       ]},
      {"select s, u, bottom(ok, 40) as x from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m) limit 1 offset 1",
       [{"2023-10-01 00:02:00", %{"s" => "str2", "u" => 3, "x" => true}}]},
      {"select s, u, bottom(ok, 40) as x from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m) limit 2 offset 1",
       [
         {"2023-10-01 00:02:00", %{"s" => "str2", "u" => 3, "x" => true}},
         {"2023-10-01 00:03:00", %{"s" => "str3", "u" => 4, "x" => false}}
       ]},
      {"select top(n, 3), usage from ~p1 limit 2",
       [
         {"2023-10-01 00:26:00", %{"top" => 68, "usage" => 39.25}},
         {"2023-10-01 00:28:00", %{"top" => 74, "usage" => 42.25}}
       ]},
      {"select top(n, 3), usage, u from ~p1 limit 2 offset 1",
       [
         {"2023-10-01 00:28:00", %{"top" => 74, "u" => 29, "usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"top" => 77, "usage" => 43.75}}
       ]},
      {"select bottom(usage, host, region, 4), n, s from ~p1 limit 2 offset 1",
       [
         {"2023-10-01 00:01:00", %{"bottom" => 1.75, "host" => "b", "n" => -7, "region" => "eu"}},
         {"2023-10-01 00:02:00",
          %{"bottom" => 3.25, "host" => "c", "region" => "us", "s" => "str2"}},
         {"2023-10-01 00:04:00", %{"host" => "b", "n" => 2, "region" => "us", "s" => "str0"}}
       ]},
      {"select top(n, 3), usage from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(15m) limit 1",
       [{"2023-10-01 00:11:00", %{"top" => 23, "usage" => 16.75}}]},
      {"select bottom(ok, 5), s, u from ~p1 limit 2",
       [
         {"2023-10-01 00:03:00", %{"bottom" => false, "s" => "str3", "u" => 4}},
         {"2023-10-01 00:05:00", %{"bottom" => false, "s" => "str1"}},
         {"2023-10-01 00:11:00", %{"u" => 12}}
       ]},
      {"select top(u, 3), ok from ~p1 limit 2",
       [
         {"2023-10-01 00:26:00", %{"ok" => true, "top" => 27}},
         {"2023-10-01 00:27:00", %{"ok" => false, "top" => 28}}
       ]},
      {"select top(n, 3) as host, host from ~p1 limit 2",
       [
         {"2023-10-01 00:26:00", %{"host" => 68, "host_1" => "c"}},
         {"2023-10-01 00:28:00", %{"host" => 74, "host_1" => "b"}}
       ]},
      {"select time as n, * from ~p1 limit 3 offset 2",
       [
         nil: %{
           "host" => "c",
           "n" => ~U[2023-10-01 00:02:00.000000Z],
           "region" => "us",
           "usage" => 3.25
         },
         nil: %{
           "host" => "a",
           "n" => ~U[2023-10-01 00:03:00.000000Z],
           "n_1" => -1,
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 4
         },
         nil: %{
           "host" => "b",
           "n" => ~U[2023-10-01 00:04:00.000000Z],
           "n_1" => 2,
           "region" => "us",
           "s" => "str0",
           "u" => 5,
           "usage" => 6.25
         },
         nil: %{
           "host" => "c",
           "n" => ~U[2023-10-01 00:05:00.000000Z],
           "n_1" => 5,
           "ok" => false,
           "region" => "eu",
           "s" => "str1",
           "usage" => 7.75
         },
         nil: %{
           "host" => "a",
           "n" => ~U[2023-10-01 00:06:00.000000Z],
           "ok" => true,
           "region" => "us",
           "u" => 7
         }
       ]},
      {"select time as n, * from ~p1 group by host limit 1 offset 1",
       [
         nil: %{
           "host" => "a",
           "n" => ~U[2023-10-01 00:03:00.000000Z],
           "n_1" => -1,
           "ok" => false,
           "region" => "eu",
           "u" => 4
         },
         nil: %{
           "host" => "a",
           "n" => ~U[2023-10-01 00:06:00.000000Z],
           "region" => "us",
           "usage" => 9.25
         },
         nil: %{
           "host" => "a",
           "n" => ~U[2023-10-01 00:09:00.000000Z],
           "region" => "eu",
           "s" => "str1"
         },
         nil: %{
           "host" => "b",
           "n" => ~U[2023-10-01 00:04:00.000000Z],
           "n_1" => 2,
           "region" => "us",
           "s" => "str0",
           "usage" => 6.25
         },
         nil: %{"host" => "b", "n" => ~U[2023-10-01 00:07:00.000000Z], "region" => "eu", "u" => 8},
         nil: %{
           "host" => "c",
           "n" => ~U[2023-10-01 00:05:00.000000Z],
           "ok" => false,
           "region" => "eu",
           "s" => "str1",
           "usage" => 7.75
         },
         nil: %{
           "host" => "c",
           "n" => ~U[2023-10-01 00:08:00.000000Z],
           "n_1" => 14,
           "region" => "us",
           "u" => 9
         }
       ]},
      {"select *, time as usage from ~p1 limit 2",
       [
         nil: %{
           "host" => "a",
           "n" => -10,
           "ok" => true,
           "region" => "us",
           "u" => 1,
           "usage" => 0.25,
           "usage_1" => ~U[2023-10-01 00:00:00.000000Z]
         },
         nil: %{
           "host" => "b",
           "n" => -7,
           "region" => "eu",
           "s" => "str1",
           "usage" => 1.75,
           "usage_1" => ~U[2023-10-01 00:01:00.000000Z]
         },
         nil: %{
           "host" => "c",
           "ok" => true,
           "region" => "us",
           "s" => "str2",
           "u" => 3,
           "usage_1" => ~U[2023-10-01 00:02:00.000000Z]
         }
       ]},
      {"select time as time, * from ~p1 limit 1",
       [
         {"2023-10-01 00:00:00",
          %{"host" => "a", "n" => -10, "ok" => true, "region" => "us", "u" => 1, "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"host" => "b", "region" => "eu", "s" => "str1"}}
       ]},
      {"select *, time from ~p1 limit 1",
       [
         {"2023-10-01 00:00:00",
          %{"host" => "a", "n" => -10, "ok" => true, "region" => "us", "u" => 1, "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"host" => "b", "region" => "eu", "s" => "str1"}}
       ]},
      {"select *, time as usage, time as n from ~p1 limit 1",
       [
         nil: %{
           "host" => "a",
           "n" => -10,
           "n_1" => ~U[2023-10-01 00:00:00.000000Z],
           "ok" => true,
           "region" => "us",
           "u" => 1,
           "usage" => 0.25,
           "usage_1" => ~U[2023-10-01 00:00:00.000000Z]
         },
         nil: %{
           "host" => "b",
           "n_1" => ~U[2023-10-01 00:01:00.000000Z],
           "region" => "eu",
           "s" => "str1",
           "usage_1" => ~U[2023-10-01 00:01:00.000000Z]
         }
       ]}
    ]
  end

  @doc "The names of the columns: the select list in order, a name taken twice numbered, the dimensions and the tags `top()` chooses by, and the planning error of two columns with one name."
  @spec column_names() :: [{binary(), term()}]
  def column_names do
    [
      {"select usage as host from ~p1 group by host limit 2",
       [
         {"2023-10-01 00:00:00", %{"host" => "a", "host_1" => 0.25}},
         {"2023-10-01 00:06:00", %{"host" => "a", "host_1" => 9.25}},
         {"2023-10-01 00:01:00", %{"host" => "b", "host_1" => 1.75}},
         {"2023-10-01 00:04:00", %{"host" => "b", "host_1" => 6.25}},
         {"2023-10-01 00:02:00", %{"host" => "c", "host_1" => 3.25}},
         {"2023-10-01 00:05:00", %{"host" => "c", "host_1" => 7.75}}
       ]},
      {"select host from ~p1 group by host limit 2", []},
      {"select n as region from ~p1 group by region limit 2",
       [
         {"2023-10-01 00:01:00", %{"region" => "eu", "region_1" => -7}},
         {"2023-10-01 00:03:00", %{"region" => "eu", "region_1" => -1}},
         {"2023-10-01 00:00:00", %{"region" => "us", "region_1" => -10}},
         {"2023-10-01 00:04:00", %{"region" => "us", "region_1" => 2}}
       ]},
      {"select host, usage as host from ~p1 group by host limit 2",
       [
         {"2023-10-01 00:00:00", %{"host" => "a", "host_1" => 0.25}},
         {"2023-10-01 00:06:00", %{"host" => "a", "host_1" => 9.25}},
         {"2023-10-01 00:01:00", %{"host" => "b", "host_1" => 1.75}},
         {"2023-10-01 00:04:00", %{"host" => "b", "host_1" => 6.25}},
         {"2023-10-01 00:02:00", %{"host" => "c", "host_1" => 3.25}},
         {"2023-10-01 00:05:00", %{"host" => "c", "host_1" => 7.75}}
       ]},
      {"select usage as time from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"time_1" => 0.25}},
         {"2023-10-01 00:01:00", %{"time_1" => 1.75}}
       ]},
      {"select usage as host, host from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"host" => 0.25, "host_1" => "a"}},
         {"2023-10-01 00:01:00", %{"host" => 1.75, "host_1" => "b"}}
       ]},
      {"select usage as host_1, host, host from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"host" => "a", "host_1" => 0.25, "host_2" => "a"}},
         {"2023-10-01 00:01:00", %{"host" => "b", "host_1" => 1.75, "host_2" => "b"}}
       ]},
      {"select max(n) as host from ~p1 group by host",
       [
         {"2023-10-01 00:24:00", %{"host" => "a", "host_1" => 62}},
         {"2023-10-01 00:28:00", %{"host" => "b", "host_1" => 74}},
         {"2023-10-01 00:29:00", %{"host" => "c", "host_1" => 77}}
       ]},
      {"select max(n), host from ~p1 group by host",
       [
         {"2023-10-01 00:24:00", %{"host" => "a", "max" => 62}},
         {"2023-10-01 00:28:00", %{"host" => "b", "max" => 74}},
         {"2023-10-01 00:29:00", %{"host" => "c", "max" => 77}}
       ]},
      {"select top(n, 2) as host from ~p1 group by host",
       [
         {"2023-10-01 00:21:00", %{"host" => "a", "host_1" => 53}},
         {"2023-10-01 00:24:00", %{"host" => "a", "host_1" => 62}},
         {"2023-10-01 00:25:00", %{"host" => "b", "host_1" => 65}},
         {"2023-10-01 00:28:00", %{"host" => "b", "host_1" => 74}},
         {"2023-10-01 00:26:00", %{"host" => "c", "host_1" => 68}},
         {"2023-10-01 00:29:00", %{"host" => "c", "host_1" => 77}}
       ]},
      {"select top(n, host, 2) as region from ~p1 group by region",
       [
         {"2023-10-01 00:25:00", %{"host" => "b", "region" => "eu", "region_1" => 65}},
         {"2023-10-01 00:29:00", %{"host" => "c", "region" => "eu", "region_1" => 77}},
         {"2023-10-01 00:26:00", %{"host" => "c", "region" => "us", "region_1" => 68}},
         {"2023-10-01 00:28:00", %{"host" => "b", "region" => "us", "region_1" => 74}}
       ]},
      {"select top(n, host, 2), region from ~p1 group by region",
       [
         {"2023-10-01 00:25:00", %{"host" => "b", "region" => "eu", "top" => 65}},
         {"2023-10-01 00:29:00", %{"host" => "c", "region" => "eu", "top" => 77}},
         {"2023-10-01 00:26:00", %{"host" => "c", "region" => "us", "top" => 68}},
         {"2023-10-01 00:28:00", %{"host" => "b", "region" => "us", "top" => 74}}
       ]},
      {"select top(n, host, 2), host from ~p1",
       [
         {"2023-10-01 00:28:00", %{"host" => "b", "host_1" => "b", "top" => 74}},
         {"2023-10-01 00:29:00", %{"host" => "c", "host_1" => "c", "top" => 77}}
       ]},
      {"select top(n, host, 2) as host_1, host from ~p1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.n AS host_1\" at position 1 and \"~p1.host AS host_1\" at position 3 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select top(n, host, 2) as x, host as x_1, region as x from ~p1",
       [
         {"2023-10-01 00:28:00", %{"host" => "b", "x" => 74, "x_1" => "b", "x_2" => "us"}},
         {"2023-10-01 00:29:00", %{"host" => "c", "x" => 77, "x_1" => "c", "x_2" => "eu"}}
       ]},
      {"select usage as x, top(n, host, 2) as x from ~p1",
       [
         {"2023-10-01 00:28:00", %{"host" => "b", "x" => 42.25, "x_1" => 74}},
         {"2023-10-01 00:29:00", %{"host" => "c", "x" => 43.75, "x_1" => 77}}
       ]},
      {"select top(n, host, 2) as host, host from ~p1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.host AS host_1\" at position 2 and \"~p1.host AS host_1\" at position 3 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select host, top(n, host, 2) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"host" => "b", "host_1" => "b", "top" => 74}},
         {"2023-10-01 00:29:00", %{"host" => "c", "host_1" => "c", "top" => 77}}
       ]},
      {"select top(n, host, 2), usage as host_2 from ~p1",
       [
         {"2023-10-01 00:28:00", %{"host" => "b", "host_2" => 42.25, "top" => 74}},
         {"2023-10-01 00:29:00", %{"host" => "c", "host_2" => 43.75, "top" => 77}}
       ]},
      {"select top(n, host, 2) as host_1, usage as host from ~p1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.n AS host_1\" at position 1 and \"~p1.usage AS host_1\" at position 3 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select usage as host, top(n, host, 2) as host from ~p1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.n AS host_1\" at position 2 and \"~p1.host AS host_1\" at position 3 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select usage as host, time from ~p1 group by host limit 1",
       [
         {"2023-10-01 00:00:00", %{"host" => "a", "host_1" => 0.25}},
         {"2023-10-01 00:01:00", %{"host" => "b", "host_1" => 1.75}},
         {"2023-10-01 00:02:00", %{"host" => "c", "host_1" => 3.25}}
       ]},
      {"select time, usage as time from ~p1 limit 1",
       [{"2023-10-01 00:00:00", %{"time_1" => 0.25}}]},
      {"select usage as host, time as host from ~p1 group by host limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.time AS host_1\" at position 0 and \"~p1.usage AS host_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select usage as time from ~p1 group by host limit 1",
       [
         {"2023-10-01 00:00:00", %{"host" => "a", "time_1" => 0.25}},
         {"2023-10-01 00:01:00", %{"host" => "b", "time_1" => 1.75}},
         {"2023-10-01 00:02:00", %{"host" => "c", "time_1" => 3.25}}
       ]},
      {"select * from ~p1 group by host limit 1",
       [
         {"2023-10-01 00:00:00",
          %{"host" => "a", "n" => -10, "ok" => true, "region" => "us", "u" => 1, "usage" => 0.25}},
         {"2023-10-01 00:03:00", %{"host" => "a", "region" => "eu", "s" => "str3"}},
         {"2023-10-01 00:01:00",
          %{"host" => "b", "n" => -7, "region" => "eu", "s" => "str1", "usage" => 1.75}},
         {"2023-10-01 00:04:00", %{"host" => "b", "region" => "us", "u" => 5}},
         {"2023-10-01 00:02:00",
          %{
            "host" => "c",
            "ok" => true,
            "region" => "us",
            "s" => "str2",
            "u" => 3,
            "usage" => 3.25
          }},
         {"2023-10-01 00:05:00", %{"host" => "c", "n" => 5, "region" => "eu"}}
       ]},
      {"select time as region, * from ~p1 group by host limit 1",
       [
         nil: %{
           "host" => "a",
           "n" => -10,
           "ok" => true,
           "region" => ~U[2023-10-01 00:00:00.000000Z],
           "region_1" => "us",
           "u" => 1,
           "usage" => 0.25
         },
         nil: %{
           "host" => "a",
           "region" => ~U[2023-10-01 00:03:00.000000Z],
           "region_1" => "eu",
           "s" => "str3"
         },
         nil: %{
           "host" => "b",
           "n" => -7,
           "region" => ~U[2023-10-01 00:01:00.000000Z],
           "region_1" => "eu",
           "s" => "str1",
           "usage" => 1.75
         },
         nil: %{
           "host" => "b",
           "region" => ~U[2023-10-01 00:04:00.000000Z],
           "region_1" => "us",
           "u" => 5
         },
         nil: %{
           "host" => "c",
           "ok" => true,
           "region" => ~U[2023-10-01 00:02:00.000000Z],
           "region_1" => "us",
           "s" => "str2",
           "u" => 3,
           "usage" => 3.25
         },
         nil: %{
           "host" => "c",
           "n" => 5,
           "region" => ~U[2023-10-01 00:05:00.000000Z],
           "region_1" => "eu"
         }
       ]},
      {"select * from ~p1 group by region limit 1",
       [
         {"2023-10-01 00:01:00",
          %{"host" => "b", "n" => -7, "region" => "eu", "s" => "str1", "usage" => 1.75}},
         {"2023-10-01 00:03:00", %{"host" => "a", "ok" => false, "region" => "eu", "u" => 4}},
         {"2023-10-01 00:00:00",
          %{"host" => "a", "n" => -10, "ok" => true, "region" => "us", "u" => 1, "usage" => 0.25}},
         {"2023-10-01 00:02:00", %{"host" => "c", "region" => "us", "s" => "str2"}}
       ]},
      {"select u as host, n as host_1 from ~p1 group by host limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.u AS host_1\" at position 2 and \"~p1.n AS host_1\" at position 3 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select u as host_1, n as host from ~p1 group by host limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.u AS host_1\" at position 2 and \"~p1.n AS host_1\" at position 3 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select u as region_1, n as region from ~p1 group by region limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.u AS region_1\" at position 2 and \"~p1.n AS region_1\" at position 3 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select mean(n) as host from ~p1 group by host",
       [
         {"1970-01-01 00:00:00", %{"host" => "a", "host_1" => 26.0}},
         {"1970-01-01 00:00:00", %{"host" => "b", "host_1" => 33.5}},
         {"1970-01-01 00:00:00", %{"host" => "c", "host_1" => 41.0}}
       ]},
      {"select mean(n) as host from ~p1 group by time(10m), host limit 1",
       [
         {"2023-10-01 00:00:00", %{"host" => "a", "host_1" => 3.5}},
         {"2023-10-01 00:00:00", %{"host" => "b", "host_1" => -2.5}},
         {"2023-10-01 00:00:00", %{"host" => "c", "host_1" => 9.5}}
       ]},
      {"select usage as time, n as time_1 from ~p1 limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.usage AS time_1\" at position 1 and \"~p1.n AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select n as time_1, usage as time from ~p1 limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.n AS time_1\" at position 1 and \"~p1.usage AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select (time), (time), usage from ~p1 limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.time AS time_1\" at position 1 and \"~p1.time AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select (time), usage as time, n from ~p1 limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.time AS time_1\" at position 1 and \"~p1.usage AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select usage as time, (time), n from ~p1 limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.usage AS time_1\" at position 1 and \"~p1.time AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select ((time)) as time, usage from ~p1 limit 1",
       [{"2023-10-01 00:00:00", %{"time_1" => ~U[2023-10-01 00:00:00.000000Z], "usage" => 0.25}}]},
      {"select (time) as time_1, (time), usage from ~p1 limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.time AS time_1\" at position 1 and \"~p1.time AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select usage as time, n as time from ~p1 limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.usage AS time_1\" at position 1 and \"~p1.n AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select usage as time, n as time, u as time from ~p1 limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.usage AS time_1\" at position 1 and \"~p1.n AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select usage as time, n as time_1, u as time from ~p1 limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.usage AS time_1\" at position 1 and \"~p1.n AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select first(n) as time from ~p1", [{"2023-10-01 00:00:00", %{"time_1" => -10}}]},
      {"select first(n) as x, last(n) as x from ~p1",
       [{"1970-01-01 00:00:00", %{"x" => -10, "x_1" => 77}}]},
      {"select usage as nosuch from ~p1 group by nosuch limit 1",
       [{"2023-10-01 00:00:00", %{"nosuch_1" => 0.25}}]},
      {"select top(n, 2) as nosuch from ~p1 group by nosuch",
       [
         {"2023-10-01 00:28:00", %{"nosuch_1" => 74}},
         {"2023-10-01 00:29:00", %{"nosuch_1" => 77}}
       ]},
      {"select top(n, region, host, 2) from ~p1 group by region",
       [
         {"2023-10-01 00:25:00",
          %{"host" => "b", "region" => "eu", "region_1" => "eu", "top" => 65}},
         {"2023-10-01 00:29:00",
          %{"host" => "c", "region" => "eu", "region_1" => "eu", "top" => 77}},
         {"2023-10-01 00:26:00",
          %{"host" => "c", "region" => "us", "region_1" => "us", "top" => 68}},
         {"2023-10-01 00:28:00",
          %{"host" => "b", "region" => "us", "region_1" => "us", "top" => 74}}
       ]},
      {"select top(n, host, region, 2) from ~p1 group by region",
       [
         {"2023-10-01 00:25:00",
          %{"host" => "b", "region" => "eu", "region_1" => "eu", "top" => 65}},
         {"2023-10-01 00:29:00",
          %{"host" => "c", "region" => "eu", "region_1" => "eu", "top" => 77}},
         {"2023-10-01 00:26:00",
          %{"host" => "c", "region" => "us", "region_1" => "us", "top" => 68}},
         {"2023-10-01 00:28:00",
          %{"host" => "b", "region" => "us", "region_1" => "us", "top" => 74}}
       ]},
      {"select top(n, region, host, 2), host as region from ~p1",
       [
         {"2023-10-01 00:28:00",
          %{"host" => "b", "region" => "us", "region_1" => "b", "top" => 74}},
         {"2023-10-01 00:29:00",
          %{"host" => "c", "region" => "eu", "region_1" => "c", "top" => 77}}
       ]},
      {"select top(n, region, host, 2), host as x from ~p1 group by region",
       [
         {"2023-10-01 00:25:00",
          %{"host" => "b", "region" => "eu", "region_1" => "eu", "top" => 65, "x" => "b"}},
         {"2023-10-01 00:29:00",
          %{"host" => "c", "region" => "eu", "region_1" => "eu", "top" => 77, "x" => "c"}},
         {"2023-10-01 00:26:00",
          %{"host" => "c", "region" => "us", "region_1" => "us", "top" => 68, "x" => "c"}},
         {"2023-10-01 00:28:00",
          %{"host" => "b", "region" => "us", "region_1" => "us", "top" => 74, "x" => "b"}}
       ]},
      {"select top(n, host, 2), host as host from ~p1 group by host",
       [
         {"2023-10-01 00:24:00", %{"host" => "a", "host_1" => "a", "top" => 62}},
         {"2023-10-01 00:28:00", %{"host" => "b", "host_1" => "b", "top" => 74}},
         {"2023-10-01 00:29:00", %{"host" => "c", "host_1" => "c", "top" => 77}}
       ]},
      {"select host as region from ~p1 group by region limit 2", []},
      {"select region as region, usage from ~p1 group by region limit 2",
       [
         {"2023-10-01 00:01:00", %{"region" => "eu", "usage" => 1.75}},
         {"2023-10-01 00:05:00", %{"region" => "eu", "usage" => 7.75}},
         {"2023-10-01 00:00:00", %{"region" => "us", "usage" => 0.25}},
         {"2023-10-01 00:02:00", %{"region" => "us", "usage" => 3.25}}
       ]},
      {"select region as host, usage from ~p1 group by region limit 2",
       [
         {"2023-10-01 00:01:00", %{"host" => "eu", "region" => "eu", "usage" => 1.75}},
         {"2023-10-01 00:05:00", %{"host" => "eu", "region" => "eu", "usage" => 7.75}},
         {"2023-10-01 00:00:00", %{"host" => "us", "region" => "us", "usage" => 0.25}},
         {"2023-10-01 00:02:00", %{"host" => "us", "region" => "us", "usage" => 3.25}}
       ]},
      {"select region, usage from ~p1 group by region limit 2",
       [
         {"2023-10-01 00:01:00", %{"region" => "eu", "usage" => 1.75}},
         {"2023-10-01 00:05:00", %{"region" => "eu", "usage" => 7.75}},
         {"2023-10-01 00:00:00", %{"region" => "us", "usage" => 0.25}},
         {"2023-10-01 00:02:00", %{"region" => "us", "usage" => 3.25}}
       ]},
      {"select top(n, host, 2), host as x from ~p1 group by region",
       [
         {"2023-10-01 00:25:00", %{"host" => "b", "region" => "eu", "top" => 65, "x" => "b"}},
         {"2023-10-01 00:29:00", %{"host" => "c", "region" => "eu", "top" => 77, "x" => "c"}},
         {"2023-10-01 00:26:00", %{"host" => "c", "region" => "us", "top" => 68, "x" => "c"}},
         {"2023-10-01 00:28:00", %{"host" => "b", "region" => "us", "top" => 74, "x" => "b"}}
       ]},
      {"select top(n, 2), region as host from ~p1 group by region",
       [
         {"2023-10-01 00:25:00", %{"host" => "eu", "region" => "eu", "top" => 65}},
         {"2023-10-01 00:29:00", %{"host" => "eu", "region" => "eu", "top" => 77}},
         {"2023-10-01 00:26:00", %{"host" => "us", "region" => "us", "top" => 68}},
         {"2023-10-01 00:28:00", %{"host" => "us", "region" => "us", "top" => 74}}
       ]},
      {"select top(n, 2), usage as region from ~p1 group by region",
       [
         {"2023-10-01 00:25:00", %{"region" => "eu", "region_1" => 37.75, "top" => 65}},
         {"2023-10-01 00:29:00", %{"region" => "eu", "region_1" => 43.75, "top" => 77}},
         {"2023-10-01 00:26:00", %{"region" => "us", "region_1" => 39.25, "top" => 68}},
         {"2023-10-01 00:28:00", %{"region" => "us", "region_1" => 42.25, "top" => 74}}
       ]},
      {"select host as x, usage from ~p1 group by region limit 1 offset 1",
       [
         {"2023-10-01 00:05:00", %{"region" => "eu", "usage" => 7.75, "x" => "c"}},
         {"2023-10-01 00:02:00", %{"region" => "us", "usage" => 3.25, "x" => "c"}}
       ]},
      {"select host, usage from ~p1 group by host limit 1 offset 1",
       [
         {"2023-10-01 00:06:00", %{"host" => "a", "usage" => 9.25}},
         {"2023-10-01 00:04:00", %{"host" => "b", "usage" => 6.25}},
         {"2023-10-01 00:05:00", %{"host" => "c", "usage" => 7.75}}
       ]},
      {"select host as x, u from ~p1 group by region limit 1 offset 1",
       [
         {"2023-10-01 00:07:00", %{"region" => "eu", "u" => 8, "x" => "b"}},
         {"2023-10-01 00:02:00", %{"region" => "us", "u" => 3, "x" => "c"}}
       ]},
      {"select host as x, u from ~p1 group by host limit 1 offset 1",
       [
         {"2023-10-01 00:03:00", %{"host" => "a", "u" => 4, "x" => "a"}},
         {"2023-10-01 00:07:00", %{"host" => "b", "u" => 8, "x" => "b"}},
         {"2023-10-01 00:08:00", %{"host" => "c", "u" => 9, "x" => "c"}}
       ]},
      {"select region as x, u from ~p1 group by host limit 1 offset 1",
       [
         {"2023-10-01 00:03:00", %{"host" => "a", "u" => 4, "x" => "eu"}},
         {"2023-10-01 00:07:00", %{"host" => "b", "u" => 8, "x" => "eu"}},
         {"2023-10-01 00:08:00", %{"host" => "c", "u" => 9, "x" => "us"}}
       ]},
      {"select region as x, u from ~p1 group by region limit 1 offset 1",
       [
         {"2023-10-01 00:07:00", %{"region" => "eu", "u" => 8, "x" => "eu"}},
         {"2023-10-01 00:02:00", %{"region" => "us", "u" => 3, "x" => "us"}}
       ]},
      {"select region, u from ~p1 group by host limit 1 offset 1",
       [
         {"2023-10-01 00:03:00", %{"host" => "a", "region" => "eu", "u" => 4}},
         {"2023-10-01 00:07:00", %{"host" => "b", "region" => "eu", "u" => 8}},
         {"2023-10-01 00:08:00", %{"host" => "c", "region" => "us", "u" => 9}}
       ]},
      {"select region, u from ~p1 group by region, host limit 1 offset 1",
       [
         {"2023-10-01 00:15:00", %{"host" => "a", "region" => "eu", "u" => 16}},
         {"2023-10-01 00:06:00", %{"host" => "a", "region" => "us", "u" => 7}},
         {"2023-10-01 00:19:00", %{"host" => "b", "region" => "eu", "u" => 20}},
         {"2023-10-01 00:10:00", %{"host" => "b", "region" => "us", "u" => 11}},
         {"2023-10-01 00:23:00", %{"host" => "c", "region" => "eu", "u" => 24}},
         {"2023-10-01 00:08:00", %{"host" => "c", "region" => "us", "u" => 9}}
       ]},
      {"select usage as u1, u from ~p1 group by region, host limit 1 offset 1",
       [
         {"2023-10-01 00:15:00", %{"host" => "a", "region" => "eu", "u" => 16, "u1" => 22.75}},
         {"2023-10-01 00:06:00", %{"host" => "a", "region" => "us", "u" => 7, "u1" => 9.25}},
         {"2023-10-01 00:07:00", %{"host" => "b", "region" => "eu", "u1" => 10.75}},
         {"2023-10-01 00:19:00", %{"host" => "b", "region" => "eu", "u" => 20}},
         {"2023-10-01 00:10:00", %{"host" => "b", "region" => "us", "u" => 11}},
         {"2023-10-01 00:16:00", %{"host" => "b", "region" => "us", "u1" => 24.25}},
         {"2023-10-01 00:11:00", %{"host" => "c", "region" => "eu", "u1" => 16.75}},
         {"2023-10-01 00:23:00", %{"host" => "c", "region" => "eu", "u" => 24}},
         {"2023-10-01 00:08:00", %{"host" => "c", "region" => "us", "u" => 9, "u1" => 12.25}}
       ]},
      {"select host as x, u from ~p1 limit 1 offset 1",
       [{"2023-10-01 00:02:00", %{"u" => 3, "x" => "c"}}]},
      {"select host as x, u from ~p1 group by region limit 2 offset 2",
       [
         {"2023-10-01 00:11:00", %{"region" => "eu", "u" => 12, "x" => "c"}},
         {"2023-10-01 00:15:00", %{"region" => "eu", "u" => 16, "x" => "a"}},
         {"2023-10-01 00:04:00", %{"region" => "us", "u" => 5, "x" => "b"}},
         {"2023-10-01 00:06:00", %{"region" => "us", "u" => 7, "x" => "a"}}
       ]},
      {"select host as x, u, n from ~p1 group by region limit 1 offset 1",
       [
         {"2023-10-01 00:03:00", %{"n" => -1, "region" => "eu", "x" => "a"}},
         {"2023-10-01 00:07:00", %{"region" => "eu", "u" => 8, "x" => "b"}},
         {"2023-10-01 00:02:00", %{"region" => "us", "u" => 3, "x" => "c"}},
         {"2023-10-01 00:04:00", %{"n" => 2, "region" => "us", "x" => "b"}}
       ]},
      {"select usage, host as x from ~p1 group by region limit 1 offset 1",
       [
         {"2023-10-01 00:05:00", %{"region" => "eu", "usage" => 7.75, "x" => "c"}},
         {"2023-10-01 00:02:00", %{"region" => "us", "usage" => 3.25, "x" => "c"}}
       ]},
      {"select usage, host from ~p1 group by region limit 1 offset 1",
       [
         {"2023-10-01 00:05:00", %{"host" => "c", "region" => "eu", "usage" => 7.75}},
         {"2023-10-01 00:02:00", %{"host" => "c", "region" => "us", "usage" => 3.25}}
       ]},
      {"select host, usage from ~p1 group by region, host limit 1 offset 1",
       [
         {"2023-10-01 00:15:00", %{"host" => "a", "region" => "eu", "usage" => 22.75}},
         {"2023-10-01 00:06:00", %{"host" => "a", "region" => "us", "usage" => 9.25}},
         {"2023-10-01 00:07:00", %{"host" => "b", "region" => "eu", "usage" => 10.75}},
         {"2023-10-01 00:16:00", %{"host" => "b", "region" => "us", "usage" => 24.25}},
         {"2023-10-01 00:11:00", %{"host" => "c", "region" => "eu", "usage" => 16.75}},
         {"2023-10-01 00:08:00", %{"host" => "c", "region" => "us", "usage" => 12.25}}
       ]},
      {"select host, region, usage from ~p1 group by host, region limit 1 offset 1",
       [
         {"2023-10-01 00:15:00", %{"host" => "a", "region" => "eu", "usage" => 22.75}},
         {"2023-10-01 00:06:00", %{"host" => "a", "region" => "us", "usage" => 9.25}},
         {"2023-10-01 00:07:00", %{"host" => "b", "region" => "eu", "usage" => 10.75}},
         {"2023-10-01 00:16:00", %{"host" => "b", "region" => "us", "usage" => 24.25}},
         {"2023-10-01 00:11:00", %{"host" => "c", "region" => "eu", "usage" => 16.75}},
         {"2023-10-01 00:08:00", %{"host" => "c", "region" => "us", "usage" => 12.25}}
       ]},
      {"select * from ~p1 group by region, host limit 1 offset 1",
       [
         {"2023-10-01 00:09:00",
          %{"host" => "a", "n" => 17, "ok" => false, "region" => "eu", "s" => "str1"}},
         {"2023-10-01 00:15:00", %{"host" => "a", "region" => "eu", "u" => 16, "usage" => 22.75}},
         {"2023-10-01 00:06:00",
          %{"host" => "a", "n" => 8, "ok" => true, "region" => "us", "u" => 7, "usage" => 9.25}},
         {"2023-10-01 00:07:00",
          %{"host" => "b", "region" => "eu", "s" => "str3", "usage" => 10.75}},
         {"2023-10-01 00:13:00", %{"host" => "b", "n" => 29, "region" => "eu"}},
         {"2023-10-01 00:19:00", %{"host" => "b", "region" => "eu", "u" => 20}},
         {"2023-10-01 00:10:00",
          %{"host" => "b", "n" => 20, "region" => "us", "s" => "str2", "u" => 11}},
         {"2023-10-01 00:16:00", %{"host" => "b", "region" => "us", "usage" => 24.25}},
         {"2023-10-01 00:11:00",
          %{
            "host" => "c",
            "n" => 23,
            "ok" => false,
            "region" => "eu",
            "s" => "str3",
            "usage" => 16.75
          }},
         {"2023-10-01 00:23:00", %{"host" => "c", "region" => "eu", "u" => 24}},
         {"2023-10-01 00:08:00",
          %{
            "host" => "c",
            "ok" => true,
            "region" => "us",
            "s" => "str0",
            "u" => 9,
            "usage" => 12.25
          }},
         {"2023-10-01 00:14:00", %{"host" => "c", "n" => 32, "region" => "us"}}
       ]},
      {"select host as x, top(n, 2) from ~p1 group by region, host",
       [
         {"2023-10-01 00:15:00", %{"host" => "a", "region" => "eu", "top" => 35, "x" => "a"}},
         {"2023-10-01 00:21:00", %{"host" => "a", "region" => "eu", "top" => 53, "x" => "a"}},
         {"2023-10-01 00:18:00", %{"host" => "a", "region" => "us", "top" => 44, "x" => "a"}},
         {"2023-10-01 00:24:00", %{"host" => "a", "region" => "us", "top" => 62, "x" => "a"}},
         {"2023-10-01 00:19:00", %{"host" => "b", "region" => "eu", "top" => 47, "x" => "b"}},
         {"2023-10-01 00:25:00", %{"host" => "b", "region" => "eu", "top" => 65, "x" => "b"}},
         {"2023-10-01 00:16:00", %{"host" => "b", "region" => "us", "top" => 38, "x" => "b"}},
         {"2023-10-01 00:28:00", %{"host" => "b", "region" => "us", "top" => 74, "x" => "b"}},
         {"2023-10-01 00:23:00", %{"host" => "c", "region" => "eu", "top" => 59, "x" => "c"}},
         {"2023-10-01 00:29:00", %{"host" => "c", "region" => "eu", "top" => 77, "x" => "c"}},
         {"2023-10-01 00:20:00", %{"host" => "c", "region" => "us", "top" => 50, "x" => "c"}},
         {"2023-10-01 00:26:00", %{"host" => "c", "region" => "us", "top" => 68, "x" => "c"}}
       ]},
      {"select host as x, max(n) from ~p1 group by region, host",
       [
         {"2023-10-01 00:21:00", %{"host" => "a", "max" => 53, "region" => "eu", "x" => "a"}},
         {"2023-10-01 00:24:00", %{"host" => "a", "max" => 62, "region" => "us", "x" => "a"}},
         {"2023-10-01 00:25:00", %{"host" => "b", "max" => 65, "region" => "eu", "x" => "b"}},
         {"2023-10-01 00:28:00", %{"host" => "b", "max" => 74, "region" => "us", "x" => "b"}},
         {"2023-10-01 00:29:00", %{"host" => "c", "max" => 77, "region" => "eu", "x" => "c"}},
         {"2023-10-01 00:26:00", %{"host" => "c", "max" => 68, "region" => "us", "x" => "c"}}
       ]},
      {"select host as x from ~p1 group by region, host", []},
      {"select host as host, u from ~p1 group by region, host limit 1",
       [
         {"2023-10-01 00:03:00", %{"host" => "a", "region" => "eu", "u" => 4}},
         {"2023-10-01 00:00:00", %{"host" => "a", "region" => "us", "u" => 1}},
         {"2023-10-01 00:07:00", %{"host" => "b", "region" => "eu", "u" => 8}},
         {"2023-10-01 00:04:00", %{"host" => "b", "region" => "us", "u" => 5}},
         {"2023-10-01 00:11:00", %{"host" => "c", "region" => "eu", "u" => 12}},
         {"2023-10-01 00:02:00", %{"host" => "c", "region" => "us", "u" => 3}}
       ]}
    ]
  end

  @doc "The time in parentheses is a column of its own, named `time_1` beside the time that leads, and no field."
  @spec parenthesised_time() :: [{binary(), term()}]
  def parenthesised_time do
    [
      {"select (time) from ~p1 limit 2", []},
      {"select (time), usage from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"time_1" => ~U[2023-10-01 00:00:00.000000Z], "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"time_1" => ~U[2023-10-01 00:01:00.000000Z], "usage" => 1.75}}
       ]},
      {"select ((time)) from ~p1 limit 2", []},
      {"select ((time)) as t from ~p1 limit 2", []},
      {"select (time) as t, usage from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"t" => ~U[2023-10-01 00:00:00.000000Z], "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"t" => ~U[2023-10-01 00:01:00.000000Z], "usage" => 1.75}}
       ]},
      {"select time, ((time)) from ~p1 limit 2", []},
      {"select ((time)), time from ~p1 limit 2", []},
      {"select (time), (time) from ~p1 limit 2", []},
      {"select ((time)), * from ~p1 limit 1",
       [
         {"2023-10-01 00:00:00",
          %{
            "host" => "a",
            "n" => -10,
            "ok" => true,
            "region" => "us",
            "time_1" => ~U[2023-10-01 00:00:00.000000Z],
            "u" => 1,
            "usage" => 0.25
          }},
         {"2023-10-01 00:01:00",
          %{
            "host" => "b",
            "region" => "eu",
            "s" => "str1",
            "time_1" => ~U[2023-10-01 00:01:00.000000Z]
          }}
       ]},
      {"select ((time)), n from ~p1 where n > 1 limit 2",
       [
         {"2023-10-01 00:04:00", %{"n" => 2, "time_1" => ~U[2023-10-01 00:04:00.000000Z]}},
         {"2023-10-01 00:05:00", %{"n" => 5, "time_1" => ~U[2023-10-01 00:05:00.000000Z]}}
       ]},
      {"select (usage) from ~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select ((usage)) as x, time from ~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"x" => 0.25}}, {"2023-10-01 00:01:00", %{"x" => 1.75}}]},
      {"select (host), usage from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"host" => "a", "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"host" => "b", "usage" => 1.75}}
       ]},
      {"select ((host)) from ~p1 limit 2", []},
      {"select time, (time) as t from ~p1 limit 2", []}
    ]
  end

  @doc "A column the measurement lacks beside a tag, a string or a boolean is a constant false; beside a number it is null."
  @spec absent_columns() :: [{binary(), term()}]
  def absent_columns do
    [
      {"select mean(n) from ~p1 group by nosuch", [{"1970-01-01 00:00:00", %{"mean" => 33.5}}]},
      {"select n from ~p1 group by nosuch limit 1", [{"2023-10-01 00:00:00", %{"n" => -10}}]},
      {"select nosuch / host from ~p1 limit 2", []},
      {"select +nosuch / host from ~p1 limit 2", []},
      {"select nosuch + host from ~p1 limit 2", []},
      {"select host / nosuch from ~p1 limit 2", []},
      {"select nosuch * n from ~p1 limit 2", []},
      {"select nosuch / n from ~p1 limit 2", []},
      {"select n / nosuch from ~p1 limit 2", []},
      {"select -u, nosuch / host from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"nosuch_host" => false, "u" => 18_446_744_073_709_551_614}},
         {"2023-10-01 00:02:00", %{"nosuch_host" => false, "u" => 18_446_744_073_709_551_610}}
       ]},
      {"select u, nosuch / host from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"nosuch_host" => false, "u" => 1}},
         {"2023-10-01 00:02:00", %{"nosuch_host" => false, "u" => 3}}
       ]},
      {"select n, nosuch / host from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"n" => -10, "nosuch_host" => false}},
         {"2023-10-01 00:01:00", %{"n" => -7, "nosuch_host" => false}}
       ]},
      {"select nosuch / host, n from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"n" => -10, "nosuch_host" => false}},
         {"2023-10-01 00:01:00", %{"n" => -7, "nosuch_host" => false}}
       ]},
      {"select nosuch / region, n from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"n" => -10, "nosuch_region" => false}},
         {"2023-10-01 00:01:00", %{"n" => -7, "nosuch_region" => false}}
       ]},
      {"select nosuch - host, n from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"n" => -10, "nosuch_host" => false}},
         {"2023-10-01 00:01:00", %{"n" => -7, "nosuch_host" => false}}
       ]},
      {"select nosuch * host, n from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"n" => -10, "nosuch_host" => false}},
         {"2023-10-01 00:01:00", %{"n" => -7, "nosuch_host" => false}}
       ]},
      {"select nosuch + region as x, n from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"n" => -10, "x" => false}},
         {"2023-10-01 00:01:00", %{"n" => -7, "x" => false}}
       ]},
      {"select nosuch / s, n from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"n" => -10, "nosuch_s" => false}},
         {"2023-10-01 00:01:00", %{"n" => -7, "nosuch_s" => false}}
       ]},
      {"select nosuch / ok, n from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"n" => -10, "nosuch_ok" => false}},
         {"2023-10-01 00:01:00", %{"n" => -7, "nosuch_ok" => false}}
       ]},
      {"select nosuch / nosuch2, n from ~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"n" => -10}}, {"2023-10-01 00:01:00", %{"n" => -7}}]},
      {"select nosuch + 1, n from ~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"n" => -10}}, {"2023-10-01 00:01:00", %{"n" => -7}}]},
      {"select nosuch, n from ~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"n" => -10}}, {"2023-10-01 00:01:00", %{"n" => -7}}]},
      {"select -nosuch, n from ~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"n" => -10}}, {"2023-10-01 00:01:00", %{"n" => -7}}]},
      {"select nosuch / host from ~p1 where n > 1000", []},
      {"select +nosuch / host from ~p1 limit 1", []},
      {"select nosuch / s from ~p1 limit 3",
       [
         {"2023-10-01 00:01:00", %{"nosuch_s" => false}},
         {"2023-10-01 00:02:00", %{"nosuch_s" => false}},
         {"2023-10-01 00:03:00", %{"nosuch_s" => false}}
       ]},
      {"select nosuch / ok from ~p1 limit 3",
       [
         {"2023-10-01 00:00:00", %{"nosuch_ok" => false}},
         {"2023-10-01 00:02:00", %{"nosuch_ok" => false}},
         {"2023-10-01 00:03:00", %{"nosuch_ok" => false}}
       ]},
      {"select nosuch / u from ~p1 limit 3", []},
      {"select nosuch / n, nosuch / host from ~p1 limit 3",
       [
         {"2023-10-01 00:00:00", %{"nosuch_host" => false}},
         {"2023-10-01 00:01:00", %{"nosuch_host" => false}},
         {"2023-10-01 00:03:00", %{"nosuch_host" => false}}
       ]},
      {"select nosuch / host from ~p1 limit 3", []},
      {"select nosuch / host, host from ~p1 limit 3", []},
      {"select nosuch / host, usage from ~p1 limit 3",
       [
         {"2023-10-01 00:00:00", %{"nosuch_host" => false, "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"nosuch_host" => false, "usage" => 1.75}},
         {"2023-10-01 00:02:00", %{"nosuch_host" => false, "usage" => 3.25}}
       ]},
      {"select (nosuch / host) + 1, usage from ~p1 limit 3",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: tag and integer"}},
      {"select nosuch / host as t, n from ~p1 limit 3 offset 1",
       [
         {"2023-10-01 00:01:00", %{"n" => -7, "t" => false}},
         {"2023-10-01 00:03:00", %{"n" => -1, "t" => false}},
         {"2023-10-01 00:04:00", %{"n" => 2, "t" => false}}
       ]},
      {"select nosuch / 'x', usage from ~p1 limit 3",
       [
         {"2023-10-01 00:00:00", %{"nosuch" => false, "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"nosuch" => false, "usage" => 1.75}},
         {"2023-10-01 00:02:00", %{"nosuch" => false, "usage" => 3.25}}
       ]},
      {"select nosuch / true, usage from ~p1 limit 3",
       [
         {"2023-10-01 00:00:00", %{"nosuch" => false, "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"nosuch" => false, "usage" => 1.75}},
         {"2023-10-01 00:02:00", %{"nosuch" => false, "usage" => 3.25}}
       ]},
      {"select 'x' / nosuch, usage from ~p1 limit 3",
       [
         {"2023-10-01 00:00:00", %{"nosuch" => false, "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"nosuch" => false, "usage" => 1.75}},
         {"2023-10-01 00:02:00", %{"nosuch" => false, "usage" => 3.25}}
       ]},
      {"select nosuch / host, nosuch % host, usage from ~p1 limit 3",
       [
         {"2023-10-01 00:00:00",
          %{"nosuch_host" => false, "nosuch_host_1" => false, "usage" => 0.25}},
         {"2023-10-01 00:01:00",
          %{"nosuch_host" => false, "nosuch_host_1" => false, "usage" => 1.75}},
         {"2023-10-01 00:02:00",
          %{"nosuch_host" => false, "nosuch_host_1" => false, "usage" => 3.25}}
       ]},
      {"select -(nosuch / host), usage from ~p1 limit 3",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator *: integer and tag"}},
      {"select n * (nosuch / host), usage from ~p1 limit 3",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator *: integer and tag"}},
      {"select nosuch / host from ~p1 group by host limit 2", []},
      {"select nosuch / host, mean(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"select mean(nosuch / host) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: expected field argument in mean(), got Binary(Binary { lhs: VarRef(VarRef { name: Identifier(\"nosuch\"), data_type: None }), op: Div, rhs: VarRef(VarRef { name: Identifier(\"host\"), data_type: Some(Tag) }) })"}},
      {"select nosuch + host, n from ~p1 group by time(5m) limit 2",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: GROUP BY requires at least one aggregate function"}},
      {"select (nosuch + 1) / host, usage from ~p1 limit 2",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: integer and tag"}},
      {"select (nosuch * n) / host, usage from ~p1 limit 2",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: integer and tag"}},
      {"select (nosuch) / host, usage from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"nosuch_host" => false, "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"nosuch_host" => false, "usage" => 1.75}}
       ]},
      {"select -nosuch / host, usage from ~p1 limit 2",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: integer and tag"}},
      {"select nosuch / -host, usage from ~p1 limit 2",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator *: integer and tag"}},
      {"select nosuch / (host), usage from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"nosuch_host" => false, "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"nosuch_host" => false, "usage" => 1.75}}
       ]},
      {"select nosuch / abs(n), usage from ~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select nosuch / (n / host), usage from ~p1 limit 2",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: integer and tag"}},
      {"select nosuch / host / n, usage from ~p1 limit 2",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: tag and integer"}},
      {"select n / host, usage from ~p1 limit 2",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator /: integer and tag"}},
      {"select nosuch / nosuch2 / host, usage from ~p1 limit 2",
       [
         {"2023-10-01 00:00:00", %{"nosuch_nosuch2_host" => false, "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"nosuch_nosuch2_host" => false, "usage" => 1.75}}
       ]}
    ]
  end

  @doc "In descending order a tie of `top()` and `bottom()` goes to the later point, the one the scan meets first."
  @spec descending() :: [{binary(), term()}]
  def descending do
    [
      {"select bottom(ok, 5) from ~p1 order by time desc",
       [
         {"2023-10-01 00:29:00", %{"bottom" => false}},
         {"2023-10-01 00:27:00", %{"bottom" => false}},
         {"2023-10-01 00:23:00", %{"bottom" => false}},
         {"2023-10-01 00:21:00", %{"bottom" => false}},
         {"2023-10-01 00:17:00", %{"bottom" => false}}
       ]},
      {"select bottom(ok, 5) from ~p1 order by time desc limit 2",
       [
         {"2023-10-01 00:29:00", %{"bottom" => false}},
         {"2023-10-01 00:27:00", %{"bottom" => false}}
       ]},
      {"select top(ok, 3) from ~p1 order by time desc",
       [
         {"2023-10-01 00:26:00", %{"top" => true}},
         {"2023-10-01 00:24:00", %{"top" => true}},
         {"2023-10-01 00:20:00", %{"top" => true}}
       ]},
      {"select bottom(ok, 5), s from ~p1 order by time desc limit 2",
       [
         {"2023-10-01 00:29:00", %{"bottom" => false, "s" => "str1"}},
         {"2023-10-01 00:27:00", %{"bottom" => false, "s" => "str3"}}
       ]},
      {"select bottom(ok, 5), s, u from ~p1 order by time desc limit 2",
       [
         {"2023-10-01 00:29:00", %{"bottom" => false, "s" => "str1"}},
         {"2023-10-01 00:27:00", %{"bottom" => false, "s" => "str3", "u" => 28}},
         {"2023-10-01 00:23:00", %{"u" => 24}}
       ]},
      {"select top(ok, 3), usage from ~p1 order by time desc limit 3",
       [
         {"2023-10-01 00:26:00", %{"top" => true, "usage" => 39.25}},
         {"2023-10-01 00:24:00", %{"top" => true}},
         {"2023-10-01 00:20:00", %{"top" => true, "usage" => 30.25}}
       ]},
      {"select bottom(ok, 2) from ~p1 group by host order by time desc",
       [
         {"2023-10-01 00:27:00", %{"bottom" => false, "host" => "a"}},
         {"2023-10-01 00:21:00", %{"bottom" => false, "host" => "a"}},
         {"2023-10-01 00:29:00", %{"bottom" => false, "host" => "c"}},
         {"2023-10-01 00:23:00", %{"bottom" => false, "host" => "c"}}
       ]},
      {"select bottom(ok, region, 2) from ~p1 order by time desc",
       [
         {"2023-10-01 00:29:00", %{"bottom" => false, "region" => "eu"}},
         {"2023-10-01 00:26:00", %{"bottom" => true, "region" => "us"}}
       ]},
      {"select top(ok, region, 2) from ~p1 order by time desc",
       [
         {"2023-10-01 00:29:00", %{"region" => "eu", "top" => false}},
         {"2023-10-01 00:26:00", %{"region" => "us", "top" => true}}
       ]},
      {"select top(u, 4) from ~p1 order by time desc",
       [
         {"2023-10-01 00:28:00", %{"top" => 29}},
         {"2023-10-01 00:27:00", %{"top" => 28}},
         {"2023-10-01 00:26:00", %{"top" => 27}},
         {"2023-10-01 00:24:00", %{"top" => 25}}
       ]},
      {"select top(n, 4) from ~p1 order by time desc",
       [
         {"2023-10-01 00:29:00", %{"top" => 77}},
         {"2023-10-01 00:28:00", %{"top" => 74}},
         {"2023-10-01 00:26:00", %{"top" => 68}},
         {"2023-10-01 00:25:00", %{"top" => 65}}
       ]},
      {"select bottom(s, 3) from ~p1 order by time desc",
       [
         {"2023-10-01 00:28:00", %{"bottom" => "str0"}},
         {"2023-10-01 00:20:00", %{"bottom" => "str0"}},
         {"2023-10-01 00:16:00", %{"bottom" => "str0"}}
       ]},
      {"select top(s, 3) from ~p1 order by time desc",
       [
         {"2023-10-01 00:27:00", %{"top" => "str3"}},
         {"2023-10-01 00:23:00", %{"top" => "str3"}},
         {"2023-10-01 00:19:00", %{"top" => "str3"}}
       ]},
      {"select bottom(ok, 5) from ~p1 group by region order by time desc",
       [
         {"2023-10-01 00:29:00", %{"bottom" => false, "region" => "eu"}},
         {"2023-10-01 00:27:00", %{"bottom" => false, "region" => "eu"}},
         {"2023-10-01 00:23:00", %{"bottom" => false, "region" => "eu"}},
         {"2023-10-01 00:21:00", %{"bottom" => false, "region" => "eu"}},
         {"2023-10-01 00:17:00", %{"bottom" => false, "region" => "eu"}},
         {"2023-10-01 00:26:00", %{"bottom" => true, "region" => "us"}},
         {"2023-10-01 00:24:00", %{"bottom" => true, "region" => "us"}},
         {"2023-10-01 00:20:00", %{"bottom" => true, "region" => "us"}},
         {"2023-10-01 00:18:00", %{"bottom" => true, "region" => "us"}},
         {"2023-10-01 00:14:00", %{"bottom" => true, "region" => "us"}}
       ]},
      {"select bottom(ok, 5) from ~p1 order by time asc",
       [
         {"2023-10-01 00:03:00", %{"bottom" => false}},
         {"2023-10-01 00:05:00", %{"bottom" => false}},
         {"2023-10-01 00:09:00", %{"bottom" => false}},
         {"2023-10-01 00:11:00", %{"bottom" => false}},
         {"2023-10-01 00:15:00", %{"bottom" => false}}
       ]},
      {"select top(n, 2) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(15m) order by time desc",
       [
         {"2023-10-01 00:29:00", %{"top" => 77}},
         {"2023-10-01 00:28:00", %{"top" => 74}},
         {"2023-10-01 00:14:00", %{"top" => 32}},
         {"2023-10-01 00:13:00", %{"top" => 29}}
       ]},
      {"select bottom(ok, 2) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(15m) order by time desc limit 3",
       [
         {"2023-10-01 00:29:00", %{"bottom" => false}},
         {"2023-10-01 00:27:00", %{"bottom" => false}},
         {"2023-10-01 00:11:00", %{"bottom" => false}}
       ]},
      {"select top(ok, host, 2) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m) order by time desc",
       [
         {"2023-10-01 00:26:00", %{"host" => "c", "top" => true}},
         {"2023-10-01 00:24:00", %{"host" => "a", "top" => true}}
       ]},
      {"select bottom(ok, 3), s from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(10m) order by time desc limit 2 offset 1",
       [
         {"2023-10-01 00:27:00", %{"bottom" => false, "s" => "str3"}},
         {"2023-10-01 00:23:00", %{"bottom" => false, "s" => "str3"}}
       ]},
      {"select bottom(ok, 3), s, u from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(10m), host order by time desc limit 1",
       [
         {"2023-10-01 00:27:00", %{"bottom" => false, "host" => "a", "s" => "str3", "u" => 28}},
         {"2023-10-01 00:28:00", %{"host" => "b", "s" => "str0", "u" => 29}},
         {"2023-10-01 00:29:00", %{"bottom" => false, "host" => "c", "s" => "str1"}},
         {"2023-10-01 00:26:00", %{"host" => "c", "u" => 27}}
       ]},
      {"select top(usage, 2), n from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(10m) order by time desc",
       [
         {"2023-10-01 00:29:00", %{"n" => 77, "top" => 43.75}},
         {"2023-10-01 00:28:00", %{"n" => 74, "top" => 42.25}},
         {"2023-10-01 00:19:00", %{"n" => 47, "top" => 28.75}},
         {"2023-10-01 00:18:00", %{"n" => 44, "top" => 27.25}},
         {"2023-10-01 00:09:00", %{"n" => 17, "top" => 13.75}},
         {"2023-10-01 00:08:00", %{"n" => 14, "top" => 12.25}}
       ]},
      {"select top(ok, 2) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(10m) order by time asc",
       [
         {"2023-10-01 00:00:00", %{"top" => true}},
         {"2023-10-01 00:02:00", %{"top" => true}},
         {"2023-10-01 00:12:00", %{"top" => true}},
         {"2023-10-01 00:14:00", %{"top" => true}},
         {"2023-10-01 00:20:00", %{"top" => true}},
         {"2023-10-01 00:24:00", %{"top" => true}}
       ]}
    ]
  end

  @doc "`top()` and `bottom()` beside arithmetic and functions of the columns of the point they chose (windowed per column), and a function written before a selector, which is the engine's internal error naming the first function."
  @spec selectors() :: [{binary(), term()}]
  def selectors do
    [
      {"select top(n, 3), usage * 2 from ~p1",
       [
         {"2023-10-01 00:26:00", %{"top" => 68, "usage" => 78.5}},
         {"2023-10-01 00:28:00", %{"top" => 74, "usage" => 84.5}},
         {"2023-10-01 00:29:00", %{"top" => 77, "usage" => 87.5}}
       ]},
      {"select top(n, 3), usage * 2 as d, usage from ~p1",
       [
         {"2023-10-01 00:26:00", %{"d" => 78.5, "top" => 68, "usage" => 39.25}},
         {"2023-10-01 00:28:00", %{"d" => 84.5, "top" => 74, "usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"d" => 87.5, "top" => 77, "usage" => 43.75}}
       ]},
      {"select top(n, host, 3), -u from ~p1",
       [
         {"2023-10-01 00:24:00",
          %{"host" => "a", "top" => 62, "u" => 18_446_744_073_709_551_566}},
         {"2023-10-01 00:28:00",
          %{"host" => "b", "top" => 74, "u" => 18_446_744_073_709_551_558}},
         {"2023-10-01 00:29:00", %{"host" => "c", "top" => 77}}
       ]},
      {"select top(n, 3), abs(n) from ~p1",
       [
         {"2023-10-01 00:26:00", %{"abs" => 68, "top" => 68}},
         {"2023-10-01 00:28:00", %{"abs" => 74, "top" => 74}},
         {"2023-10-01 00:29:00", %{"abs" => 77, "top" => 77}}
       ]},
      {"select top(n, 3), n + 1 from ~p1",
       [
         {"2023-10-01 00:26:00", %{"n" => 69, "top" => 68}},
         {"2023-10-01 00:28:00", %{"n" => 75, "top" => 74}},
         {"2023-10-01 00:29:00", %{"n" => 78, "top" => 77}}
       ]},
      {"select top(n, 3), ok + 1 from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: boolean and integer"}},
      {"select top(usage, 2), u + 1 from ~p1",
       [
         {"2023-10-01 00:28:00", %{"top" => 42.25, "u" => 30}},
         {"2023-10-01 00:29:00", %{"top" => 43.75}}
       ]},
      {"select top(n, 2), nosuch + 1 from ~p1",
       [{"2023-10-01 00:28:00", %{"top" => 74}}, {"2023-10-01 00:29:00", %{"top" => 77}}]},
      {"select top(n, 2), n * 2 from ~p1 limit 1",
       [{"2023-10-01 00:28:00", %{"n" => 148, "top" => 74}}]},
      {"select top(n, 2), n * 2 from ~p1 limit 1 offset 1",
       [{"2023-10-01 00:29:00", %{"n" => 154, "top" => 77}}]},
      {"select usage * 2, top(n, 2) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"top" => 74, "usage" => 84.5}},
         {"2023-10-01 00:29:00", %{"top" => 77, "usage" => 87.5}}
       ]},
      {"select top(n, 2), sqrt(n) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"sqrt" => 8.602325267042627, "top" => 74}},
         {"2023-10-01 00:29:00", %{"sqrt" => 8.774964387392123, "top" => 77}}
       ]},
      {"select top(n, 2), n + abs(n) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"n_abs" => 148, "top" => 74}},
         {"2023-10-01 00:29:00", %{"n_abs" => 154, "top" => 77}}
       ]},
      {"select top(n, 2), abs(n) + 1 from ~p1",
       [
         {"2023-10-01 00:28:00", %{"abs" => 75, "top" => 74}},
         {"2023-10-01 00:29:00", %{"abs" => 78, "top" => 77}}
       ]},
      {"select top(n, 2), -abs(n) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"abs" => -74, "top" => 74}},
         {"2023-10-01 00:29:00", %{"abs" => -77, "top" => 77}}
       ]},
      {"select top(n, 2), round(usage) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"round" => 42.0, "top" => 74}},
         {"2023-10-01 00:29:00", %{"round" => 44.0, "top" => 77}}
       ]},
      {"select top(n, 2), pow(n, 2) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"pow" => 5476, "top" => 74}},
         {"2023-10-01 00:29:00", %{"pow" => 5929, "top" => 77}}
       ]},
      {"select top(n, 2), floor(usage) + sqrt(n) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"floor_sqrt" => 50.60232526704263, "top" => 74}},
         {"2023-10-01 00:29:00", %{"floor_sqrt" => 51.774964387392124, "top" => 77}}
       ]},
      {"select top(n, 2), abs(n), sqrt(n) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"abs" => 74, "sqrt" => 8.602325267042627, "top" => 74}},
         {"2023-10-01 00:29:00", %{"abs" => 77, "sqrt" => 8.774964387392123, "top" => 77}}
       ]},
      {"select top(n, 2), abs(nosuch) from ~p1",
       [{"2023-10-01 00:28:00", %{"top" => 74}}, {"2023-10-01 00:29:00", %{"top" => 77}}]},
      {"select bottom(n, 2), ln(usage) from ~p1",
       [
         {"2023-10-01 00:00:00", %{"bottom" => -10, "ln" => -1.3862943611198906}},
         {"2023-10-01 00:01:00", %{"bottom" => -7, "ln" => 0.5596157879354227}}
       ]},
      {"select bottom(n, 2), log(usage, 2) from ~p1",
       [
         {"2023-10-01 00:00:00", %{"bottom" => -10, "log" => -2.0}},
         {"2023-10-01 00:01:00", %{"bottom" => -7, "log" => 0.8073549220576041}}
       ]},
      {"select bottom(n, 2), ceil(n) as c from ~p1",
       [
         {"2023-10-01 00:00:00", %{"bottom" => -10, "c" => -10.0}},
         {"2023-10-01 00:01:00", %{"bottom" => -7, "c" => -7.0}}
       ]},
      {"select top(n, 2), n + 1, abs(n) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"abs" => 74, "n" => 75, "top" => 74}},
         {"2023-10-01 00:29:00", %{"abs" => 77, "n" => 78, "top" => 77}}
       ]},
      {"select top(n, 2), abs(n), n + 1 from ~p1",
       [
         {"2023-10-01 00:28:00", %{"abs" => 74, "n" => 75, "top" => 74}},
         {"2023-10-01 00:29:00", %{"abs" => 77, "n" => 78, "top" => 77}}
       ]},
      {"select top(n, 2), usage * 2 from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m)",
       [
         {"2023-10-01 00:28:00", %{"top" => 74, "usage" => 84.5}},
         {"2023-10-01 00:29:00", %{"top" => 77, "usage" => 87.5}}
       ]},
      {"select top(n, 2), abs(n) from ~p1 limit 1",
       [{"2023-10-01 00:28:00", %{"abs" => 74, "top" => 74}}]},
      {"select top(n, 2), abs(n) from ~p1 offset 1",
       [{"2023-10-01 00:29:00", %{"abs" => 77, "top" => 77}}]},
      {"select top(n, 2), abs(n) from ~p1 order by time desc",
       [
         {"2023-10-01 00:29:00", %{"abs" => 77, "top" => 77}},
         {"2023-10-01 00:28:00", %{"abs" => 74, "top" => 74}}
       ]},
      {"select top(n, 2), abs(n) from ~p1 group by host",
       [
         {"2023-10-01 00:21:00", %{"abs" => 53, "host" => "a", "top" => 53}},
         {"2023-10-01 00:24:00", %{"abs" => 62, "host" => "a", "top" => 62}},
         {"2023-10-01 00:25:00", %{"abs" => 65, "host" => "b", "top" => 65}},
         {"2023-10-01 00:28:00", %{"abs" => 74, "host" => "b", "top" => 74}},
         {"2023-10-01 00:26:00", %{"abs" => 68, "host" => "c", "top" => 68}},
         {"2023-10-01 00:29:00", %{"abs" => 77, "host" => "c", "top" => 77}}
       ]},
      {"select top(n, 2), abs(n) from ~p1 where n > 0",
       [
         {"2023-10-01 00:28:00", %{"abs" => 74, "top" => 74}},
         {"2023-10-01 00:29:00", %{"abs" => 77, "top" => 77}}
       ]},
      {"select top(n, host, 2), abs(n) from ~p1",
       [
         {"2023-10-01 00:28:00", %{"abs" => 74, "host" => "b", "top" => 74}},
         {"2023-10-01 00:29:00", %{"abs" => 77, "host" => "c", "top" => 77}}
       ]},
      {"select top(n, 2), n + 1 from ~p1 limit 1",
       [{"2023-10-01 00:28:00", %{"n" => 75, "top" => 74}}]},
      {"select top(n, 2), n + 1 from ~p1 order by time desc",
       [
         {"2023-10-01 00:29:00", %{"n" => 78, "top" => 77}},
         {"2023-10-01 00:28:00", %{"n" => 75, "top" => 74}}
       ]},
      {"select top(n, 2), sqrt(n) from ~p1 limit 1",
       [{"2023-10-01 00:28:00", %{"sqrt" => 8.602325267042627, "top" => 74}}]},
      {"select top(n, 2), pow(n, 2) from ~p1 limit 1",
       [{"2023-10-01 00:28:00", %{"pow" => 5476, "top" => 74}}]},
      {"select top(n, 2), abs(n) + 1 from ~p1 limit 1",
       [{"2023-10-01 00:28:00", %{"abs" => 75, "top" => 74}}]},
      {"select top(n, 2), n + abs(n) from ~p1 limit 1",
       [{"2023-10-01 00:28:00", %{"n_abs" => 148, "top" => 74}}]},
      {"select top(n, 2), abs(n) from ~p1 limit 5",
       [
         {"2023-10-01 00:28:00", %{"abs" => 74, "top" => 74}},
         {"2023-10-01 00:29:00", %{"abs" => 77, "top" => 77}}
       ]},
      {"select top(n, 2), abs(n) from ~p1 where n > 0 limit 3",
       [
         {"2023-10-01 00:28:00", %{"abs" => 74, "top" => 74}},
         {"2023-10-01 00:29:00", %{"abs" => 77, "top" => 77}}
       ]},
      {"select top(n, 2), abs(n) from ~p1 where n > 0 limit 3 offset 1",
       [{"2023-10-01 00:29:00", %{"abs" => 77, "top" => 77}}]},
      {"select bottom(usage, region, 2), abs(n) from ~p1",
       [
         {"2023-10-01 00:00:00", %{"abs" => 10, "bottom" => 0.25, "region" => "us"}},
         {"2023-10-01 00:01:00", %{"abs" => 7, "bottom" => 1.75, "region" => "eu"}}
       ]},
      {"select bottom(usage, region, 2), abs(n) from ~p1 limit 3",
       [
         {"2023-10-01 00:00:00", %{"abs" => 10, "bottom" => 0.25, "region" => "us"}},
         {"2023-10-01 00:01:00", %{"abs" => 7, "bottom" => 1.75, "region" => "eu"}}
       ]},
      {"select abs(n), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select sqrt(n), top(n, 2) from ~p1",
       {:error, 500,
        "External error: InfluxQL internal error: unexpected selector function: sqrt"}},
      {"select host, abs(n), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select n, abs(n), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select n + 1, abs(n), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select top(n, 2), abs(n), usage from ~p1",
       [
         {"2023-10-01 00:28:00", %{"abs" => 74, "top" => 74, "usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"abs" => 77, "top" => 77, "usage" => 43.75}}
       ]},
      {"select usage, abs(n), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n) + 1, top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select n + abs(n), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select round(usage), bottom(usage, 2) from ~p1",
       {:error, 500,
        "External error: InfluxQL internal error: unexpected selector function: round"}},
      {"select abs(n), max(usage) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), first(usage) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), top(n, host, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select -abs(n), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), max(n) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(nosuch), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), abs(usage), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), min(n) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), last(n) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), percentile(n, 50) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), mode(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"select abs(n), median(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"select abs(n), mean(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"select abs(n), count(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"select abs(n), sum(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"select abs(n), spread(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"select sqrt(n), abs(n), top(n, 2) from ~p1",
       {:error, 500,
        "External error: InfluxQL internal error: unexpected selector function: sqrt"}},
      {"select abs(n), sqrt(n), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select sqrt(abs(n)), top(n, 2) from ~p1",
       {:error, 500,
        "External error: InfluxQL internal error: unexpected selector function: sqrt"}},
      {"select abs(sqrt(n)), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), top(n, 2), sqrt(n) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), top(n, 2) from ~p1 group by host",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), top(n, 2) from ~p1 limit 1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), max(n) from ~p1 where n < 0",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), max(nosuch) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), top(nosuch, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), top(n, 2) from nosuch", []},
      {"select pow(n, 2), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: pow"}},
      {"select log(usage, 2), top(n, 2) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: log"}},
      {"select abs(n), max(time) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), first(time) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), max(n), min(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing multiple selector functions with tags or fields is not supported"}},
      {"select abs(n), top(n, 2), max(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: selector functions top and bottom cannot be combined with other functions"}},
      {"select abs(n), max(n), mean(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing aggregate and non-aggregate columns is not supported"}},
      {"select abs(n), top(n, 2), mean(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: selector functions top and bottom cannot be combined with other functions"}},
      {"select max(n), abs(n), min(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: mixing multiple selector functions with tags or fields is not supported"}},
      {"select abs(n), max(n) as x, usage from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select usage, abs(n), max(n) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), max(u) from ~p1 group by host",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(max(n)), max(u) from ~p1",
       [{"1970-01-01 00:00:00", %{"abs" => 77, "max" => 29}}]},
      {"select abs(n), distinct(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: aggregate function distinct() cannot be combined with other functions or fields"}},
      {"select abs(n), top(n, 2) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m)",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), top(n, 2) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m), host",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), top(n, 2), usage from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m)",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select host, abs(n), bottom(usage, region, 2) from ~p1 where n > 0 limit 3 offset 1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), time, bottom(usage, region, 2) from ~p1 where n > 0 limit 3 offset 1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select derivative(mean(n)), time from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T00:30:00Z' group by time(10m)",
       [
         {"2023-10-01 00:10:00", %{"derivative" => 30.0}},
         {"2023-10-01 00:20:00", %{"derivative" => 30.0}}
       ]},
      {"select abs(n), host, bottom(n, 2) as x, u as x from ~p1 order by time desc limit 2",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select time, derivative(mean(n)) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T00:30:00Z' group by time(10m)",
       [
         {"2023-10-01 00:10:00", %{"derivative" => 30.0}},
         {"2023-10-01 00:20:00", %{"derivative" => 30.0}}
       ]},
      {"select cumulative_sum(mean(n)), time from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T00:30:00Z' group by time(10m)",
       [
         {"2023-10-01 00:00:00", %{"cumulative_sum" => 3.5}},
         {"2023-10-01 00:10:00", %{"cumulative_sum" => 37.0}},
         {"2023-10-01 00:20:00", %{"cumulative_sum" => 100.5}}
       ]},
      {"select moving_average(mean(n), 2), time from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T00:30:00Z' group by time(10m)",
       [
         {"2023-10-01 00:10:00", %{"moving_average" => 18.5}},
         {"2023-10-01 00:20:00", %{"moving_average" => 48.5}}
       ]},
      {"select derivative(mean(n)), mean(u), time from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T00:30:00Z' group by time(10m)",
       [
         {"2023-10-01 00:00:00", %{"mean" => 5.285714285714286}},
         {"2023-10-01 00:10:00", %{"derivative" => 30.0, "mean" => 15.375}},
         {"2023-10-01 00:20:00", %{"derivative" => 30.0, "mean" => 25.285714285714285}}
       ]},
      {"select derivative(mean(n)) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T00:30:00Z' group by time(10m)",
       [
         {"2023-10-01 00:10:00", %{"derivative" => 30.0}},
         {"2023-10-01 00:20:00", %{"derivative" => 30.0}}
       ]}
    ]
  end

  @doc "Statements the engine answers and the double refuses by name, with the engine's answer. Each is pinned to its reason in `refusal_reasons/0`."
  @spec refusals() :: [{binary(), term()}]
  def refusals do
    [
      {"select n from ~p1 where u % s = 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression UInt64 % Utf8 to valid types"}},
      {"select n, true + 1 from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\nexpand projection\ncaused by\nError during planning: incompatible operands for operator +: boolean and integer"}},
      {"select abs(time), * from ~p1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select abs(time), max(n) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(time), count(n) from ~p1",
       {:error, 500, "Schema error: No field named ~p1.time. Valid fields are \"count(~p1.n)\"."}},
      {"select sqrt(time), n from ~p1",
       {:error, 400,
        "Error during planning: Failed to coerce arguments to satisfy a call to 'sqrt' function: coercion from Timestamp(ns) to the signature Uniform(1, [Float64, Float32]) failed No function matches the given name and argument types 'sqrt(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tsqrt(Float64/Float32)"}},
      {"select usage, time as host from ~p1 group by host limit 1",
       [
         nil: %{"host" => ~U[2023-10-01 00:00:00.000000Z], "host_1" => "a", "usage" => 0.25},
         nil: %{"host" => ~U[2023-10-01 00:01:00.000000Z], "host_1" => "b", "usage" => 1.75},
         nil: %{"host" => ~U[2023-10-01 00:02:00.000000Z], "host_1" => "c", "usage" => 3.25},
         nil: %{"host" => ~U[2023-10-01 00:04:00.000000Z], "host_1" => "b", "usage" => 6.25},
         nil: %{"host" => ~U[2023-10-01 00:05:00.000000Z], "host_1" => "c", "usage" => 7.75},
         nil: %{"host" => ~U[2023-10-01 00:06:00.000000Z], "host_1" => "a", "usage" => 9.25},
         nil: %{"host" => ~U[2023-10-01 00:07:00.000000Z], "host_1" => "b", "usage" => 10.75},
         nil: %{"host" => ~U[2023-10-01 00:08:00.000000Z], "host_1" => "c", "usage" => 12.25},
         nil: %{"host" => ~U[2023-10-01 00:09:00.000000Z], "host_1" => "a", "usage" => 13.75},
         nil: %{"host" => ~U[2023-10-01 00:11:00.000000Z], "host_1" => "c", "usage" => 16.75},
         nil: %{"host" => ~U[2023-10-01 00:12:00.000000Z], "host_1" => "a", "usage" => 18.25},
         nil: %{"host" => ~U[2023-10-01 00:13:00.000000Z], "host_1" => "b", "usage" => 19.75},
         nil: %{"host" => ~U[2023-10-01 00:14:00.000000Z], "host_1" => "c", "usage" => 21.25},
         nil: %{"host" => ~U[2023-10-01 00:15:00.000000Z], "host_1" => "a", "usage" => 22.75},
         nil: %{"host" => ~U[2023-10-01 00:16:00.000000Z], "host_1" => "b", "usage" => 24.25},
         nil: %{"host" => ~U[2023-10-01 00:18:00.000000Z], "host_1" => "a", "usage" => 27.25},
         nil: %{"host" => ~U[2023-10-01 00:19:00.000000Z], "host_1" => "b", "usage" => 28.75},
         nil: %{"host" => ~U[2023-10-01 00:20:00.000000Z], "host_1" => "c", "usage" => 30.25},
         nil: %{"host" => ~U[2023-10-01 00:21:00.000000Z], "host_1" => "a", "usage" => 31.75},
         nil: %{"host" => ~U[2023-10-01 00:22:00.000000Z], "host_1" => "b", "usage" => 33.25},
         nil: %{"host" => ~U[2023-10-01 00:23:00.000000Z], "host_1" => "c", "usage" => 34.75},
         nil: %{"host" => ~U[2023-10-01 00:25:00.000000Z], "host_1" => "b", "usage" => 37.75},
         nil: %{"host" => ~U[2023-10-01 00:26:00.000000Z], "host_1" => "c", "usage" => 39.25},
         nil: %{"host" => ~U[2023-10-01 00:27:00.000000Z], "host_1" => "a", "usage" => 40.75},
         nil: %{"host" => ~U[2023-10-01 00:28:00.000000Z], "host_1" => "b", "usage" => 42.25},
         nil: %{"host" => ~U[2023-10-01 00:29:00.000000Z], "host_1" => "c", "usage" => 43.75}
       ]},
      {"select time as host, usage from ~p1 group by host limit 1",
       [
         nil: %{"host" => ~U[2023-10-01 00:00:00.000000Z], "host_1" => "a", "usage" => 0.25},
         nil: %{"host" => ~U[2023-10-01 00:01:00.000000Z], "host_1" => "b", "usage" => 1.75},
         nil: %{"host" => ~U[2023-10-01 00:02:00.000000Z], "host_1" => "c", "usage" => 3.25},
         nil: %{"host" => ~U[2023-10-01 00:04:00.000000Z], "host_1" => "b", "usage" => 6.25},
         nil: %{"host" => ~U[2023-10-01 00:05:00.000000Z], "host_1" => "c", "usage" => 7.75},
         nil: %{"host" => ~U[2023-10-01 00:06:00.000000Z], "host_1" => "a", "usage" => 9.25},
         nil: %{"host" => ~U[2023-10-01 00:07:00.000000Z], "host_1" => "b", "usage" => 10.75},
         nil: %{"host" => ~U[2023-10-01 00:08:00.000000Z], "host_1" => "c", "usage" => 12.25},
         nil: %{"host" => ~U[2023-10-01 00:09:00.000000Z], "host_1" => "a", "usage" => 13.75},
         nil: %{"host" => ~U[2023-10-01 00:11:00.000000Z], "host_1" => "c", "usage" => 16.75},
         nil: %{"host" => ~U[2023-10-01 00:12:00.000000Z], "host_1" => "a", "usage" => 18.25},
         nil: %{"host" => ~U[2023-10-01 00:13:00.000000Z], "host_1" => "b", "usage" => 19.75},
         nil: %{"host" => ~U[2023-10-01 00:14:00.000000Z], "host_1" => "c", "usage" => 21.25},
         nil: %{"host" => ~U[2023-10-01 00:15:00.000000Z], "host_1" => "a", "usage" => 22.75},
         nil: %{"host" => ~U[2023-10-01 00:16:00.000000Z], "host_1" => "b", "usage" => 24.25},
         nil: %{"host" => ~U[2023-10-01 00:18:00.000000Z], "host_1" => "a", "usage" => 27.25},
         nil: %{"host" => ~U[2023-10-01 00:19:00.000000Z], "host_1" => "b", "usage" => 28.75},
         nil: %{"host" => ~U[2023-10-01 00:20:00.000000Z], "host_1" => "c", "usage" => 30.25},
         nil: %{"host" => ~U[2023-10-01 00:21:00.000000Z], "host_1" => "a", "usage" => 31.75},
         nil: %{"host" => ~U[2023-10-01 00:22:00.000000Z], "host_1" => "b", "usage" => 33.25},
         nil: %{"host" => ~U[2023-10-01 00:23:00.000000Z], "host_1" => "c", "usage" => 34.75},
         nil: %{"host" => ~U[2023-10-01 00:25:00.000000Z], "host_1" => "b", "usage" => 37.75},
         nil: %{"host" => ~U[2023-10-01 00:26:00.000000Z], "host_1" => "c", "usage" => 39.25},
         nil: %{"host" => ~U[2023-10-01 00:27:00.000000Z], "host_1" => "a", "usage" => 40.75},
         nil: %{"host" => ~U[2023-10-01 00:28:00.000000Z], "host_1" => "b", "usage" => 42.25},
         nil: %{"host" => ~U[2023-10-01 00:29:00.000000Z], "host_1" => "c", "usage" => 43.75}
       ]},
      {"select time as host, usage as host from ~p1 group by host limit 1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"~p1.host AS host_1\" at position 1 and \"~p1.usage AS host_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select *, time as host from ~p1 group by host limit 1",
       [
         nil: %{
           "host" => ~U[2023-10-01 00:00:00.000000Z],
           "host_1" => "a",
           "n" => -10,
           "ok" => true,
           "region" => "us",
           "u" => 1,
           "usage" => 0.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:01:00.000000Z],
           "host_1" => "b",
           "n" => -7,
           "region" => "eu",
           "s" => "str1",
           "usage" => 1.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:02:00.000000Z],
           "host_1" => "c",
           "ok" => true,
           "region" => "us",
           "s" => "str2",
           "u" => 3,
           "usage" => 3.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:03:00.000000Z],
           "host_1" => "a",
           "n" => -1,
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 4
         },
         nil: %{
           "host" => ~U[2023-10-01 00:04:00.000000Z],
           "host_1" => "b",
           "n" => 2,
           "region" => "us",
           "s" => "str0",
           "u" => 5,
           "usage" => 6.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:05:00.000000Z],
           "host_1" => "c",
           "n" => 5,
           "ok" => false,
           "region" => "eu",
           "s" => "str1",
           "usage" => 7.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:06:00.000000Z],
           "host_1" => "a",
           "n" => 8,
           "ok" => true,
           "region" => "us",
           "u" => 7,
           "usage" => 9.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:07:00.000000Z],
           "host_1" => "b",
           "region" => "eu",
           "s" => "str3",
           "u" => 8,
           "usage" => 10.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:08:00.000000Z],
           "host_1" => "c",
           "n" => 14,
           "ok" => true,
           "region" => "us",
           "s" => "str0",
           "u" => 9,
           "usage" => 12.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:09:00.000000Z],
           "host_1" => "a",
           "n" => 17,
           "ok" => false,
           "region" => "eu",
           "s" => "str1",
           "usage" => 13.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:10:00.000000Z],
           "host_1" => "b",
           "n" => 20,
           "region" => "us",
           "s" => "str2",
           "u" => 11
         },
         nil: %{
           "host" => ~U[2023-10-01 00:11:00.000000Z],
           "host_1" => "c",
           "n" => 23,
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 12,
           "usage" => 16.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:12:00.000000Z],
           "host_1" => "a",
           "ok" => true,
           "region" => "us",
           "u" => 13,
           "usage" => 18.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:13:00.000000Z],
           "host_1" => "b",
           "n" => 29,
           "region" => "eu",
           "s" => "str1",
           "usage" => 19.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:14:00.000000Z],
           "host_1" => "c",
           "n" => 32,
           "ok" => true,
           "region" => "us",
           "s" => "str2",
           "u" => 15,
           "usage" => 21.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:15:00.000000Z],
           "host_1" => "a",
           "n" => 35,
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 16,
           "usage" => 22.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:16:00.000000Z],
           "host_1" => "b",
           "n" => 38,
           "region" => "us",
           "s" => "str0",
           "u" => 17,
           "usage" => 24.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:17:00.000000Z],
           "host_1" => "c",
           "ok" => false,
           "region" => "eu",
           "s" => "str1"
         },
         nil: %{
           "host" => ~U[2023-10-01 00:18:00.000000Z],
           "host_1" => "a",
           "n" => 44,
           "ok" => true,
           "region" => "us",
           "u" => 19,
           "usage" => 27.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:19:00.000000Z],
           "host_1" => "b",
           "n" => 47,
           "region" => "eu",
           "s" => "str3",
           "u" => 20,
           "usage" => 28.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:20:00.000000Z],
           "host_1" => "c",
           "n" => 50,
           "ok" => true,
           "region" => "us",
           "s" => "str0",
           "u" => 21,
           "usage" => 30.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:21:00.000000Z],
           "host_1" => "a",
           "n" => 53,
           "ok" => false,
           "region" => "eu",
           "s" => "str1",
           "usage" => 31.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:22:00.000000Z],
           "host_1" => "b",
           "region" => "us",
           "s" => "str2",
           "u" => 23,
           "usage" => 33.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:23:00.000000Z],
           "host_1" => "c",
           "n" => 59,
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 24,
           "usage" => 34.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:24:00.000000Z],
           "host_1" => "a",
           "n" => 62,
           "ok" => true,
           "region" => "us",
           "u" => 25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:25:00.000000Z],
           "host_1" => "b",
           "n" => 65,
           "region" => "eu",
           "s" => "str1",
           "usage" => 37.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:26:00.000000Z],
           "host_1" => "c",
           "n" => 68,
           "ok" => true,
           "region" => "us",
           "s" => "str2",
           "u" => 27,
           "usage" => 39.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:27:00.000000Z],
           "host_1" => "a",
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 28,
           "usage" => 40.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:28:00.000000Z],
           "host_1" => "b",
           "n" => 74,
           "region" => "us",
           "s" => "str0",
           "u" => 29,
           "usage" => 42.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:29:00.000000Z],
           "host_1" => "c",
           "n" => 77,
           "ok" => false,
           "region" => "eu",
           "s" => "str1",
           "usage" => 43.75
         }
       ]},
      {"select time as host, * from ~p1 group by host limit 1",
       [
         nil: %{
           "host" => ~U[2023-10-01 00:00:00.000000Z],
           "host_1" => "a",
           "n" => -10,
           "ok" => true,
           "region" => "us",
           "u" => 1,
           "usage" => 0.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:01:00.000000Z],
           "host_1" => "b",
           "n" => -7,
           "region" => "eu",
           "s" => "str1",
           "usage" => 1.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:02:00.000000Z],
           "host_1" => "c",
           "ok" => true,
           "region" => "us",
           "s" => "str2",
           "u" => 3,
           "usage" => 3.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:03:00.000000Z],
           "host_1" => "a",
           "n" => -1,
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 4
         },
         nil: %{
           "host" => ~U[2023-10-01 00:04:00.000000Z],
           "host_1" => "b",
           "n" => 2,
           "region" => "us",
           "s" => "str0",
           "u" => 5,
           "usage" => 6.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:05:00.000000Z],
           "host_1" => "c",
           "n" => 5,
           "ok" => false,
           "region" => "eu",
           "s" => "str1",
           "usage" => 7.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:06:00.000000Z],
           "host_1" => "a",
           "n" => 8,
           "ok" => true,
           "region" => "us",
           "u" => 7,
           "usage" => 9.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:07:00.000000Z],
           "host_1" => "b",
           "region" => "eu",
           "s" => "str3",
           "u" => 8,
           "usage" => 10.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:08:00.000000Z],
           "host_1" => "c",
           "n" => 14,
           "ok" => true,
           "region" => "us",
           "s" => "str0",
           "u" => 9,
           "usage" => 12.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:09:00.000000Z],
           "host_1" => "a",
           "n" => 17,
           "ok" => false,
           "region" => "eu",
           "s" => "str1",
           "usage" => 13.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:10:00.000000Z],
           "host_1" => "b",
           "n" => 20,
           "region" => "us",
           "s" => "str2",
           "u" => 11
         },
         nil: %{
           "host" => ~U[2023-10-01 00:11:00.000000Z],
           "host_1" => "c",
           "n" => 23,
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 12,
           "usage" => 16.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:12:00.000000Z],
           "host_1" => "a",
           "ok" => true,
           "region" => "us",
           "u" => 13,
           "usage" => 18.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:13:00.000000Z],
           "host_1" => "b",
           "n" => 29,
           "region" => "eu",
           "s" => "str1",
           "usage" => 19.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:14:00.000000Z],
           "host_1" => "c",
           "n" => 32,
           "ok" => true,
           "region" => "us",
           "s" => "str2",
           "u" => 15,
           "usage" => 21.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:15:00.000000Z],
           "host_1" => "a",
           "n" => 35,
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 16,
           "usage" => 22.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:16:00.000000Z],
           "host_1" => "b",
           "n" => 38,
           "region" => "us",
           "s" => "str0",
           "u" => 17,
           "usage" => 24.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:17:00.000000Z],
           "host_1" => "c",
           "ok" => false,
           "region" => "eu",
           "s" => "str1"
         },
         nil: %{
           "host" => ~U[2023-10-01 00:18:00.000000Z],
           "host_1" => "a",
           "n" => 44,
           "ok" => true,
           "region" => "us",
           "u" => 19,
           "usage" => 27.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:19:00.000000Z],
           "host_1" => "b",
           "n" => 47,
           "region" => "eu",
           "s" => "str3",
           "u" => 20,
           "usage" => 28.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:20:00.000000Z],
           "host_1" => "c",
           "n" => 50,
           "ok" => true,
           "region" => "us",
           "s" => "str0",
           "u" => 21,
           "usage" => 30.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:21:00.000000Z],
           "host_1" => "a",
           "n" => 53,
           "ok" => false,
           "region" => "eu",
           "s" => "str1",
           "usage" => 31.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:22:00.000000Z],
           "host_1" => "b",
           "region" => "us",
           "s" => "str2",
           "u" => 23,
           "usage" => 33.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:23:00.000000Z],
           "host_1" => "c",
           "n" => 59,
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 24,
           "usage" => 34.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:24:00.000000Z],
           "host_1" => "a",
           "n" => 62,
           "ok" => true,
           "region" => "us",
           "u" => 25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:25:00.000000Z],
           "host_1" => "b",
           "n" => 65,
           "region" => "eu",
           "s" => "str1",
           "usage" => 37.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:26:00.000000Z],
           "host_1" => "c",
           "n" => 68,
           "ok" => true,
           "region" => "us",
           "s" => "str2",
           "u" => 27,
           "usage" => 39.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:27:00.000000Z],
           "host_1" => "a",
           "ok" => false,
           "region" => "eu",
           "s" => "str3",
           "u" => 28,
           "usage" => 40.75
         },
         nil: %{
           "host" => ~U[2023-10-01 00:28:00.000000Z],
           "host_1" => "b",
           "n" => 74,
           "region" => "us",
           "s" => "str0",
           "u" => 29,
           "usage" => 42.25
         },
         nil: %{
           "host" => ~U[2023-10-01 00:29:00.000000Z],
           "host_1" => "c",
           "n" => 77,
           "ok" => false,
           "region" => "eu",
           "s" => "str1",
           "usage" => 43.75
         }
       ]},
      {"select mean(n) as host_1, mean(u) as host from ~p1 group by host",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"avg(~p1.n) AS host_1\" at position 2 and \"avg(~p1.u) AS host_1\" at position 3 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select first(n) as time, last(n) as time from ~p1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"get_field(selector_first(~p1.n,~p1.time), Utf8(\"value\")) AS time_1\" at position 1 and \"get_field(selector_last(~p1.n,~p1.time), Utf8(\"value\")) AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select mean(n) as time, max(n) as time_1 from ~p1",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"avg(~p1.n) AS time_1\" at position 1 and \"get_field(selector_max(~p1.n,~p1.time), Utf8(\"value\")) AS time_1\" at position 2 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select mean(n) as host, mean(u) as host_1 from ~p1 group by host",
       {:error, 400,
        "Error during planning: Projections require unique expression names but the expression \"avg(~p1.n) AS host_1\" at position 2 and \"avg(~p1.u) AS host_1\" at position 3 have the same name. Consider aliasing (\"AS\") one of them."}},
      {"select top(n, region, host, 2), host as region from ~p1 group by region",
       [
         {"2023-10-01 00:25:00",
          %{"host" => "b", "region" => "eu", "region_1" => "b", "top" => 65}},
         {"2023-10-01 00:29:00",
          %{"host" => "c", "region" => "eu", "region_1" => "c", "top" => 77}},
         {"2023-10-01 00:26:00",
          %{"host" => "c", "region" => "us", "region_1" => "c", "top" => 68}},
         {"2023-10-01 00:28:00",
          %{"host" => "b", "region" => "us", "region_1" => "b", "top" => 74}}
       ]},
      {"select top(n, host, 2), host as region from ~p1 group by region",
       [
         {"2023-10-01 00:25:00", %{"host" => "b", "region" => "b", "top" => 65}},
         {"2023-10-01 00:28:00", %{"host" => "b", "region" => "b", "top" => 74}},
         {"2023-10-01 00:26:00", %{"host" => "c", "region" => "c", "top" => 68}},
         {"2023-10-01 00:29:00", %{"host" => "c", "region" => "c", "top" => 77}}
       ]},
      {"select host as region, usage from ~p1 group by region limit 2",
       [
         {"2023-10-01 00:00:00", %{"region" => "a", "usage" => 0.25}},
         {"2023-10-01 00:06:00", %{"region" => "a", "usage" => 9.25}},
         {"2023-10-01 00:01:00", %{"region" => "b", "usage" => 1.75}},
         {"2023-10-01 00:04:00", %{"region" => "b", "usage" => 6.25}},
         {"2023-10-01 00:02:00", %{"region" => "c", "usage" => 3.25}},
         {"2023-10-01 00:05:00", %{"region" => "c", "usage" => 7.75}}
       ]},
      {"select host as region, usage from ~p1 group by region, host limit 2",
       [
         {"2023-10-01 00:00:00", %{"host" => "a", "region" => "a", "usage" => 0.25}},
         {"2023-10-01 00:06:00", %{"host" => "a", "region" => "a", "usage" => 9.25}},
         {"2023-10-01 00:01:00", %{"host" => "b", "region" => "b", "usage" => 1.75}},
         {"2023-10-01 00:04:00", %{"host" => "b", "region" => "b", "usage" => 6.25}},
         {"2023-10-01 00:02:00", %{"host" => "c", "region" => "c", "usage" => 3.25}},
         {"2023-10-01 00:05:00", %{"host" => "c", "region" => "c", "usage" => 7.75}}
       ]},
      {"select top(n, 2), host as region from ~p1 group by region",
       [
         {"2023-10-01 00:25:00", %{"region" => "b", "top" => 65}},
         {"2023-10-01 00:28:00", %{"region" => "b", "top" => 74}},
         {"2023-10-01 00:26:00", %{"region" => "c", "top" => 68}},
         {"2023-10-01 00:29:00", %{"region" => "c", "top" => 77}}
       ]},
      {"select max(n), host as region from ~p1 group by region",
       {:error, 500,
        "Schema error: No field named ~p1.host. Valid fields are ~p1.region, \"selector_max(~p1.n,~p1.time)\"."}},
      {"select host as x, u from ~p1 group by region, host limit 1 offset 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[u@4 IGNORE NULLS (default: NULL)], skip=1, fetch=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select host as x, u from ~p1 group by region, host limit 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[u@4 IGNORE NULLS (default: NULL)], fetch=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select host as x, u from ~p1 group by region, host offset 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[u@4 IGNORE NULLS (default: NULL)], skip=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select host as x, usage from ~p1 group by region, host limit 2 offset 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[usage@4 IGNORE NULLS (default: NULL)], skip=1, fetch=2\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: usage@4 IS NOT NULL AND usage@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, usage@7 as usage]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: usage@4 IS NOT NULL AND usage@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, usage@7 as usage]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: usage@4 IS NOT NULL AND usage@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, usage@7 as usage]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select region as x, u from ~p1 group by region, host limit 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[u@4 IGNORE NULLS (default: NULL)], fetch=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, region@3 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, region@3 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, region@3 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select host as x, region as y, u from ~p1 group by region, host limit 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST, y@4 ASC NULLS LAST], limit_expr=[u@5 IGNORE NULLS (default: NULL)], fetch=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@5 IS NOT NULL AND u@5 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, region@3 as y, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@5 IS NOT NULL AND u@5 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, region@3 as y, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@5 IS NOT NULL AND u@5 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, region@3 as y, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST, y@4 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select host as x, u from ~p1 group by host, region limit 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[u@4 IGNORE NULLS (default: NULL)], fetch=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select host as x, u from ~p1 group by /host|region/ limit 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[u@4 IGNORE NULLS (default: NULL)], fetch=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select host as x, u from ~p1 group by * limit 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[u@4 IGNORE NULLS (default: NULL)], fetch=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select host as x, u from ~p1 group by region, host limit 1 offset 0",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[u@4 IGNORE NULLS (default: NULL)], fetch=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: u@4 IS NOT NULL AND u@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select host as x, u, n from ~p1 group by region, host limit 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[u@4 IGNORE NULLS (default: NULL), n@5 IGNORE NULLS (default: NULL)], fetch=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: (n@5 IS NOT NULL OR u@4 IS NOT NULL) AND (n@5 IS NOT NULL OR u@4 IS NOT NULL)\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u, n@1 as n]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: (n@5 IS NOT NULL OR u@4 IS NOT NULL) AND (n@5 IS NOT NULL OR u@4 IS NOT NULL)\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u, n@1 as n]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: (n@5 IS NOT NULL OR u@4 IS NOT NULL) AND (n@5 IS NOT NULL OR u@4 IS NOT NULL)\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as u, n@1 as n]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select abs(nosuch / host), usage from ~p1 limit 3",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Boolean No function matches the given name and argument types 'abs(Boolean)'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select sqrt(nosuch / host), usage from ~p1 limit 3",
       {:error, 400,
        "Error during planning: Failed to coerce arguments to satisfy a call to 'sqrt' function: coercion from Boolean to the signature Uniform(1, [Float64, Float32]) failed No function matches the given name and argument types 'sqrt(Boolean)'. You might need to add explicit type casts.\n\tCandidate functions:\n\tsqrt(Float64/Float32)"}},
      {"select max(nosuch) / host from ~p1", []},
      {"select top(n, 2), abs(time) from ~p1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None) No function matches the given name and argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select top(n, 2), abs(s) from ~p1",
       {:error, 400,
        "Error during planning: Function 'abs' expects NativeType::Numeric but received NativeType::String No function matches the given name and argument types 'abs(Utf8)'. You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"}},
      {"select max(n), abs(n) from ~p1", [{"2023-10-01 00:29:00", %{"abs" => 77, "max" => 77}}]},
      {"select abs(true), max(n) from ~p1",
       {:error, 400,
        "rewriting statement\ncaused by\ngather information about select statement\ncaused by\nError during planning: field must contain at least one variable"}},
      {"select abs(s), max(n) from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), max(u) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m)",
       [{"2023-10-01 00:00:00", %{"abs" => 74, "max" => 29}}, {"2023-10-01 00:30:00", %{}}]},
      {"select abs(n), max(n) + 1 from ~p1",
       {:error, 500, "External error: InfluxQL internal error: unexpected selector function: abs"}},
      {"select abs(n), max(n) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m)",
       [{"2023-10-01 00:00:00", %{"abs" => 77, "max" => 77}}, {"2023-10-01 00:30:00", %{}}]},
      {"select usage, abs(n), min(n) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m)",
       [
         {"2023-10-01 00:00:00", %{"abs" => 10, "min" => -10, "usage" => 0.25}},
         {"2023-10-01 00:30:00", %{}}
       ]},
      {"select abs(n), max(n) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m), host",
       [
         {"2023-10-01 00:00:00", %{"abs" => 62, "host" => "a", "max" => 62}},
         {"2023-10-01 00:30:00", %{"host" => "a"}},
         {"2023-10-01 00:00:00", %{"abs" => 74, "host" => "b", "max" => 74}},
         {"2023-10-01 00:30:00", %{"host" => "b"}},
         {"2023-10-01 00:00:00", %{"abs" => 77, "host" => "c", "max" => 77}},
         {"2023-10-01 00:30:00", %{"host" => "c"}}
       ]},
      {"select host as x, u as host_1 from ~p1 group by region, host limit 1 offset 1",
       {:error, 400,
        "SanityCheckPlan\ncaused by\nError during planning: Plan: [\"SeriesLimitExec: series=[host@1, region@2], order=[time@0 ASC NULLS LAST, x@3 ASC NULLS LAST], limit_expr=[host_1@4 IGNORE NULLS (default: NULL)], skip=1, fetch=1\", \"  CoalesceBatchesExec: target_batch_size=8192\", \"    RepartitionExec: partitioning=Hash([host@1, region@2], 10), input_partitions=30, preserve_order=true, sort_exprs=host@1 ASC, region@2 ASC, time@0 ASC\", \"      UnionExec\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: host_1@4 IS NOT NULL AND host_1@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as host_1]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: host_1@4 IS NOT NULL AND host_1@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as host_1]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\", \"        CoalesceBatchesExec: target_batch_size=8192\", \"          FilterExec: host_1@4 IS NOT NULL AND host_1@4 IS NOT NULL\", \"            RepartitionExec: partitioning=RoundRobinBatch(10), input_partitions=1\", \"              ProjectionExec: expr=[time@5 as time, host@0 as host, region@3 as region, host@0 as x, u@6 as host_1]\", \"                DeduplicateExec: [host@0 ASC,region@3 ASC,time@5 ASC]\", \"                  SortExec: expr=[host@0 ASC, region@3 ASC, time@5 ASC, __chunk_order@8 ASC], preserve_partitioning=[false]\", \"                    RecordBatchesExec: chunks=1, projection=[host, n, ok, region, s, time, u, usage, __chunk_order]\"] does not satisfy order requirements: [host@1 NA, region@2 NA, time@0 ASC NULLS LAST, x@3 ASC NULLS LAST]. Child-0 order: [[host@1 ASC, region@2 ASC, time@0 ASC]]"}},
      {"select difference(mean(n)), time as t from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T00:30:00Z' group by time(10m)",
       [
         nil: %{"difference" => 30.0, "t" => ~U[2023-10-01 00:10:00.000000Z]},
         nil: %{"difference" => 30.0, "t" => ~U[2023-10-01 00:20:00.000000Z]}
       ]}
    ]
  end

  @doc "The reason the double gives for each statement of `refusals/0` (`Client.Local: <reason>`, with the statement after it when the parser refuses)."
  @spec refusal_reasons() :: %{binary() => binary()}
  def refusal_reasons do
    %{
      "select n from ~p1 where u % s = 1" => "unsupported InfluxQL WHERE: % s = 1",
      "select n, true + 1 from ~p1" => "unsupported InfluxQL (an expression of constants)",
      "select abs(time), * from ~p1" => "unsupported InfluxQL (* beside other select items)",
      "select abs(time), max(n) from ~p1" =>
        "unsupported InfluxQL (a function of time beside an aggregate)",
      "select abs(time), count(n) from ~p1" =>
        "unsupported InfluxQL (a function of time beside an aggregate)",
      "select sqrt(time), n from ~p1" => "unsupported InfluxQL (sqrt() of a timestamp)",
      "select usage, time as host from ~p1 group by host limit 1" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select time as host, usage from ~p1 group by host limit 1" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select time as host, usage as host from ~p1 group by host limit 1" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select *, time as host from ~p1 group by host limit 1" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select time as host, * from ~p1 group by host limit 1" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select mean(n) as host_1, mean(u) as host from ~p1 group by host" =>
        "unsupported InfluxQL (select items that end up with the same name)",
      "select first(n) as time, last(n) as time from ~p1" =>
        "unsupported InfluxQL (select items that end up with the same name)",
      "select mean(n) as time, max(n) as time_1 from ~p1" =>
        "unsupported InfluxQL (select items that end up with the same name)",
      "select mean(n) as host, mean(u) as host_1 from ~p1 group by host" =>
        "unsupported InfluxQL (select items that end up with the same name)",
      "select top(n, region, host, 2), host as region from ~p1 group by region" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select top(n, host, 2), host as region from ~p1 group by region" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select host as region, usage from ~p1 group by region limit 2" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select host as region, usage from ~p1 group by region, host limit 2" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select top(n, 2), host as region from ~p1 group by region" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select max(n), host as region from ~p1 group by region" =>
        "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)",
      "select host as x, u from ~p1 group by region, host limit 1 offset 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select host as x, u from ~p1 group by region, host limit 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select host as x, u from ~p1 group by region, host offset 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select host as x, usage from ~p1 group by region, host limit 2 offset 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select region as x, u from ~p1 group by region, host limit 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select host as x, region as y, u from ~p1 group by region, host limit 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select host as x, u from ~p1 group by host, region limit 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select host as x, u from ~p1 group by /host|region/ limit 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select host as x, u from ~p1 group by * limit 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select host as x, u from ~p1 group by region, host limit 1 offset 0" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select host as x, u, n from ~p1 group by region, host limit 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select abs(nosuch / host), usage from ~p1 limit 3" =>
        "unsupported InfluxQL (abs() of a tag)",
      "select sqrt(nosuch / host), usage from ~p1 limit 3" =>
        "unsupported InfluxQL (sqrt() of a tag)",
      "select max(nosuch) / host from ~p1" =>
        "unsupported InfluxQL (an expression of aggregates and fields)",
      "select top(n, 2), abs(time) from ~p1" =>
        "unsupported InfluxQL (a function of time beside an aggregate)",
      "select top(n, 2), abs(s) from ~p1" => "unsupported InfluxQL (abs() of a string)",
      "select max(n), abs(n) from ~p1" =>
        "unsupported InfluxQL (a function over a selector in that shape)",
      "select abs(true), max(n) from ~p1" => "unsupported InfluxQL (an expression of constants)",
      "select abs(s), max(n) from ~p1" => "unsupported InfluxQL (abs() of a string)",
      "select abs(n), max(u) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m)" =>
        "unsupported InfluxQL (columns beside a selector in GROUP BY time)",
      "select abs(n), max(n) + 1 from ~p1" =>
        "unsupported InfluxQL (arithmetic on a selector beside columns)",
      "select abs(n), max(n) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m)" =>
        "unsupported InfluxQL (columns beside a selector in GROUP BY time)",
      "select usage, abs(n), min(n) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m)" =>
        "unsupported InfluxQL (columns beside a selector in GROUP BY time)",
      "select abs(n), max(n) from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T01:00:00Z' group by time(30m), host" =>
        "unsupported InfluxQL (columns beside a selector in GROUP BY time)",
      "select host as x, u as host_1 from ~p1 group by region, host limit 1 offset 1" =>
        "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second dimension, with LIMIT or OFFSET)",
      "select difference(mean(n)), time as t from ~p1 where time >= '2023-10-01T00:00:00Z' and time < '2023-10-01T00:30:00Z' group by time(10m)" =>
        "unsupported InfluxQL (a renamed time column beside an aggregate)"
    }
  end
end
