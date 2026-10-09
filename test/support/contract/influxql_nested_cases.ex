defmodule InfluxElixir.Contract.InfluxQLNestedCases do
  @moduledoc "Statements over the `~p1` fixture of `InfluxElixir.Contract.InfluxQLProjectionCases` (and `~p2`, two points whose field is named with a double quote) with the answers InfluxDB 3 Core 3.10.1 gave when a condition in parentheses stands beside arithmetic or as an operand of a comparison, when a field is compared with a constant the engine folds, when the sources of a FROM are dotted or qualified, when a select list repeats a name or needs one quoted, and when a clause keyword comes where the clauses before it end the statement. `~db` is the database the statement is run in. The statements the double refuses by name, with the reason pinned, are `refusals/0`."

  alias InfluxElixir.Contract.InfluxQLProjectionCases

  @doc "The names the cases use, from one unique `prefix`: `~p1` and `~p2` (the database, `~db`, is the run's own)."
  @spec names(binary()) :: %{binary() => binary()}
  def names(prefix), do: %{"p1" => prefix <> "_p1", "p2" => prefix <> "_p2"}

  @doc "The fixture, as line protocol, with `names/1` substituted: `~p1` as in `InfluxElixir.Contract.InfluxQLProjectionCases`, `~p2` two points with the fields `x\"y`, `k` and `j`."
  @spec fixture(%{binary() => binary()}) :: [binary()]
  def fixture(names) do
    InfluxQLProjectionCases.fixture(names) ++
      Enum.map(
        [
          ~S|~p2 x"y=1.5,k=2.0,j=3i 1696118400000000000|,
          ~S|~p2 x"y=2.5,k=4.0,j=1i 1696118460000000000|
        ],
        &String.replace(&1, "~p2", names["p2"])
      )
  end

  @doc "A parenthesised condition beside arithmetic. The engine reads the group as a complete operand of a comparison: an operator behind it is left over from the operator (`Nom`), as the operand of an operator or a sign the parse fails as it does for a word it cannot read there (`Failure` after `+`/`-`, the operator left over after `*`/`/`, the operand missing after a comparison, the condition left unparsed at its start), and inside the arguments of a call it is another error of its own. A boolean constant in parentheses is an operand of arithmetic."
  @spec group_arithmetic() :: [{binary(), term()}]
  def group_arithmetic do
    [
      {"select usage from ~p1 where usage > (n > 1) + 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 44. Parsing Error: Nom(\"+ 1\", Tag)"}},
      {"select usage from ~p1 where usage > (n > 1) + (u > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 44. Parsing Error: Nom(\"+ (u > 1)\", Tag)"}},
      {"select usage from ~p1 where usage > (n > 1 and u > 1) + 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 54. Parsing Error: Nom(\"+ 1\", Tag)"}},
      {"select usage from ~p1 where usage > (n > 1 or u > 1) + 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 53. Parsing Error: Nom(\"+ 1\", Tag)"}},
      {"select usage from ~p1 where usage > ((n > 1)) + 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 46. Parsing Error: Nom(\"+ 1\", Tag)"}},
      {"select usage from ~p1 where usage > (n > 1) - 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 44. Parsing Error: Nom(\"- 1\", Tag)"}},
      {"select usage from ~p1 where usage > (n > 1) * 2 limit 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 44. Parsing Error: Nom(\"* 2 limit 1\", Tag)"}},
      {"select usage from ~p1 where usage > (n > 1) / 2",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 44. Parsing Error: Nom(\"/ 2\", Tag)"}},
      {"select usage from ~p1 where (n > 1) + 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 36. Parsing Error: Nom(\"+ 1\", Tag)"}},
      {"select usage from ~p1 where (n > 1) + 1 > usage",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 36. Parsing Error: Nom(\"+ 1 > usage\", Tag)"}},
      {"select usage from ~p1 where (n > 1) + 1 and usage > 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 36. Parsing Error: Nom(\"+ 1 and usage > 1\", Tag)"}},
      {"select usage from ~p1 where usage > 1 + (n > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"(n > 1)\", Char)"}},
      {"select usage from ~p1 where usage > 1 + (n > 1 and u > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"(n > 1 and u > 1)\", Char)"}},
      {"select usage from ~p1 where usage > 1 - (n > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"(n > 1)\", Char)"}},
      {"select usage from ~p1 where usage > 1 + (n > 1) + 2",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"(n > 1) + 2\", Char)"}},
      {"select usage from ~p1 where usage > 2 * (n > 1) limit 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 38. Parsing Error: Nom(\"* (n > 1) limit 1\", Tag)"}},
      {"select usage from ~p1 where usage > 1 / (n > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 38. Parsing Error: Nom(\"/ (n > 1)\", Tag)"}},
      {"select usage from ~p1 where usage > 1 + 2 * (n > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 42. Parsing Error: Nom(\"* (n > 1)\", Tag)"}},
      {"select usage from ~p1 where usage > 1 * 2 + (n > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"(n > 1)\", Char)"}},
      {"select usage from ~p1 where usage > -(n > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid conditional expression at pos 35"}},
      {"select usage from ~p1 where usage > +(n > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid conditional expression at pos 35"}},
      {"select usage from ~p1 where -(n > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 22. Parsing Error: Nom(\"where -(n > 1)\", Tag)"}},
      {"select usage from ~p1 where usage + -(n > 1) > 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"-(n > 1) > 1\", Char)"}},
      {"select usage from ~p1 where usage > (-(n > 1))",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid conditional expression at pos 35"}},
      {"select usage from ~p1 where usage > (1 + -(n > 1))",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"-(n > 1))\", Char)"}},
      {"select usage from ~p1 where usage > ((n > 1) + n)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid conditional expression at pos 35"}},
      {"select usage from ~p1 where ((n > 1) + 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 22. Parsing Error: Nom(\"where ((n > 1) + 1)\", Tag)"}},
      {"select usage from ~p1 where usage > (n + (n > 1))",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"(n > 1))\", Char)"}},
      {"select usage from ~p1 where (n > 1) + 1 limit x",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 36. Parsing Error: Nom(\"+ 1 limit x\", Tag)"}},
      {"select usage from ~p1 where usage > 1 + (n > 1) limit x",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"(n > 1) limit x\", Char)"}},
      {"select usage from ~p1 where (n > 1) + 1 group by host",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 36. Parsing Error: Nom(\"+ 1 group by host\", Tag)"}},
      {"select usage from ~p1 where (n > 1) + 1 tz('UTC')",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 36. Parsing Error: Nom(\"+ 1 tz('UTC')\", Tag)"}},
      {"select usage from ~p1 where usage > ((n > 1) and (u > 1)) * 2",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 58. Parsing Error: Nom(\"* 2\", Tag)"}},
      {"select usage from ~p1 where (usage > (n > 1)) + 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 46. Parsing Error: Nom(\"+ 1\", Tag)"}},
      {"select usage from ~p1 where usage > (true) + 1", []},
      {"select usage from ~p1 where abs((n > 1) + 1) > 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"(n > 1) + 1) > 1\", Char)"}},
      {"select usage from ~p1 where abs(1 + (n > 1)) > 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 0. Parsing Failure: Nom(\"(n > 1)) > 1\", Char)"}}
    ]
  end

  @doc "A comparison with a boolean of its own as an operand: a condition in parentheses (equal, unequal or ordered against a boolean column, `true`, `false` or another group, at any depth), arithmetic of a column the measurement lacks with text (the engine reads it as `false`), and the other side's arithmetic, which the engine does not coerce beside a group. Next to a comparison of the `time` an equality of two booleans is refused (`refusals/0`)."
  @spec group_operands() :: [{binary(), term()}]
  def group_operands do
    [
      {"select usage from ~p1 where (n > 1) = ok",
       [
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}}
       ]},
      {"select usage from ~p1 where ((n > 1)) = ok",
       [
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}}
       ]},
      {"select usage from ~p1 where (n > 1) = (u > 2)",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:04:00", %{"usage" => 6.25}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:16:00", %{"usage" => 24.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:19:00", %{"usage" => 28.75}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:28:00", %{"usage" => 42.25}}
       ]},
      {"select usage from ~p1 where (n > 1) and (u > 1) = ok",
       [
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}}
       ]},
      {"select usage from ~p1 where true = (n > 1)",
       [
         {"2023-10-01 00:04:00", %{"usage" => 6.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:13:00", %{"usage" => 19.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:16:00", %{"usage" => 24.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:19:00", %{"usage" => 28.75}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:25:00", %{"usage" => 37.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:28:00", %{"usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where false = (n > 1)",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select usage from ~p1 where true != (n > 1)",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select usage from ~p1 where (n > 1) <> false",
       [
         {"2023-10-01 00:04:00", %{"usage" => 6.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:13:00", %{"usage" => 19.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:16:00", %{"usage" => 24.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:19:00", %{"usage" => 28.75}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:25:00", %{"usage" => 37.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:28:00", %{"usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where (n > 1) != ok",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where ok != (n > 1)",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where (n > 1) < ok", []},
      {"select usage from ~p1 where true < (n > 1)", []},
      {"select usage from ~p1 where (n > 1) = (true)",
       [
         {"2023-10-01 00:04:00", %{"usage" => 6.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:13:00", %{"usage" => 19.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:16:00", %{"usage" => 24.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:19:00", %{"usage" => 28.75}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:25:00", %{"usage" => 37.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:28:00", %{"usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where (host = 'a') = ok",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:12:00", %{"usage" => 18.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where (host = 'a' or ok) != ok",
       [
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:27:00", %{"usage" => 40.75}}
       ]},
      {"select usage from ~p1 where (usage > 'a') = (n > 1)",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select usage from ~p1 where ok = (usage > 'a')",
       [
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:27:00", %{"usage" => 40.75}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where ((n > 1) = ok) = ok",
       [
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where (n > 1) = ok and usage > 1",
       [
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}}
       ]},
      {"select usage from ~p1 where (n > 1) = ok or usage > 40",
       [
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:27:00", %{"usage" => 40.75}},
         {"2023-10-01 00:28:00", %{"usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where usage > ((n > 1) and (u > 1))", []},
      {"select usage from ~p1 where usage > ((n > 1) or (u > 1))", []},
      {"select usage from ~p1 where ok = ((n > 1) and (u > 1))",
       [
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}}
       ]},
      {"select usage from ~p1 where ok = ((n > 1) or ok)",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:02:00", %{"usage" => 3.25}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:12:00", %{"usage" => 18.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}}
       ]},
      {"select usage from ~p1 where ok > ((n > 1) and (u > 1))", []},
      {"select usage from ~p1 where usage > ((((n > 1))))", []},
      {"select usage from ~p1 where usage > (((((true)))))", []},
      {"select usage from ~p1 where 'x' + usage > (n > 1)", []},
      {"select usage from ~p1 where usage + 'x' = (n > 1)", []},
      {"select usage from ~p1 where 'x' + 'y' <> (n > 1)", []},
      {"select usage from ~p1 where s + 1 = (n > 1)", []},
      {"select usage from ~p1 where host + 1 <> (n > 1)", []},
      {"select usage from ~p1 where usage + ok > (n > 1)", []},
      {"select usage from ~p1 where ok + 1 = (n > 1)", []},
      {"select usage from ~p1 where -s = (n > 1)", []},
      {"select usage from ~p1 where usage * 'x' = (n > 1)", []},
      {"select usage from ~p1 where abs(usage) + 'x' > (n > 1)", []},
      {"select usage from ~p1 where (n > 1) = 'x' + usage", []},
      {"select usage from ~p1 where nosuch + 1 = (n > 1)", []},
      {"select usage from ~p1 where nosuch + 'x' = (n > 1)",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select usage from ~p1 where nosuch + 'x' <> (n > 1)",
       [
         {"2023-10-01 00:04:00", %{"usage" => 6.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:13:00", %{"usage" => 19.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:16:00", %{"usage" => 24.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:19:00", %{"usage" => 28.75}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:25:00", %{"usage" => 37.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:28:00", %{"usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where 's' + nosuch = ok",
       [
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:27:00", %{"usage" => 40.75}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where nosuch + s <> true",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"usage" => 1.75}},
         {"2023-10-01 00:02:00", %{"usage" => 3.25}},
         {"2023-10-01 00:04:00", %{"usage" => 6.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:07:00", %{"usage" => 10.75}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:12:00", %{"usage" => 18.25}},
         {"2023-10-01 00:13:00", %{"usage" => 19.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:16:00", %{"usage" => 24.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:19:00", %{"usage" => 28.75}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:22:00", %{"usage" => 33.25}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:25:00", %{"usage" => 37.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:27:00", %{"usage" => 40.75}},
         {"2023-10-01 00:28:00", %{"usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where nosuch + 'x' = nosuch + 'y'",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"usage" => 1.75}},
         {"2023-10-01 00:02:00", %{"usage" => 3.25}},
         {"2023-10-01 00:04:00", %{"usage" => 6.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:07:00", %{"usage" => 10.75}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:12:00", %{"usage" => 18.25}},
         {"2023-10-01 00:13:00", %{"usage" => 19.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:16:00", %{"usage" => 24.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:19:00", %{"usage" => 28.75}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:22:00", %{"usage" => 33.25}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:25:00", %{"usage" => 37.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:27:00", %{"usage" => 40.75}},
         {"2023-10-01 00:28:00", %{"usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where nosuch + 'x' > (n > 1)", []},
      {"select usage from ~p1 where nosuch + 'x' + 1 = (n > 1)", []},
      {"select usage from ~p1 where nosuch + 'x' = true", []},
      {"select usage from ~p1 where nosuch + 'x' <> ok",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:02:00", %{"usage" => 3.25}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:12:00", %{"usage" => 18.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}}
       ]},
      {"select usage from ~p1 where usage + time = (n > 1)",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Float64 + Timestamp(ns) to valid types"}},
      {"select usage from ~p1 where (n > 1) = usage + time",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Float64 + Timestamp(ns) to valid types"}},
      {"select usage from ~p1 where (n > 1) < time + 1",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Timestamp(ns) + Int64 to valid types"}},
      {"select usage from ~p1 where time > 0 and usage > (n > 1)", []},
      {"select usage from ~p1 where (n > 1) = true and time > 0",
       [
         {"2023-10-01 00:04:00", %{"usage" => 6.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:13:00", %{"usage" => 19.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:16:00", %{"usage" => 24.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:19:00", %{"usage" => 28.75}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:25:00", %{"usage" => 37.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:28:00", %{"usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where (n > 1) = ok and time > 0",
       [
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}}
       ]},
      {"select usage from ~p1 where nosuch + 'x' = ok and time > 0",
       [
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:27:00", %{"usage" => 40.75}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where (n > 1) = (u > 1) = ok",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}}
       ]},
      {"select usage from ~p1 where (n > 1) = ok = ok",
       [
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:09:00", %{"usage" => 13.75}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:21:00", %{"usage" => 31.75}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where usage < n != (n > 1)",
       [
         {"2023-10-01 00:04:00", %{"usage" => 6.25}},
         {"2023-10-01 00:05:00", %{"usage" => 7.75}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}}
       ]},
      {"select usage from ~p1 where usage > ( > 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid conditional expression at pos 35"}},
      {"select usage from ~p1 where ok = (= 1)",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid conditional expression at pos 32"}},
      {"select usage from ~p1 where (nosuch > 1) = (n > 1)", []},
      {"select usage from ~p1 where ok = (nosuch > 1)", []},
      {"select usage from ~p1 where ((nosuch > 1) or ok) != ok", []}
    ]
  end

  @doc "A field compared with a constant of numbers, `+`, `*` and signs, which the engine folds before it compares (a fraction without its integer part included), and a string or a tag compared with the lowest 64-bit integer, which keeps no point."
  @spec constants() :: [{binary(), term()}]
  def constants do
    [
      {"select usage from ~p1 where usage > .5 + 42",
       [{"2023-10-01 00:29:00", %{"usage" => 43.75}}]},
      {"select usage from ~p1 where n >= 37 * 2",
       [
         {"2023-10-01 00:28:00", %{"usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where n >= +37 * 2",
       [
         {"2023-10-01 00:28:00", %{"usage" => 42.25}},
         {"2023-10-01 00:29:00", %{"usage" => 43.75}}
       ]},
      {"select usage from ~p1 where s = -9223372036854775808", []}
    ]
  end

  @doc "The names of the columns of a select list: a name that needs quoting is quoted with its backslash and double quote escaped, a repeated name is numbered past every name the list writes (a column the measurement lacks included), and a column the measurement lacks with `fill(number)` is the number wherever it is read."
  @spec column_names() :: [{binary(), term()}]
  def column_names do
    [
      {"select \"x\\\"y\" / k from ~p2",
       [
         {"2023-10-01 00:00:00", %{"\"x\\\"y\"_k" => 0.75}},
         {"2023-10-01 00:01:00", %{"\"x\\\"y\"_k" => 0.625}}
       ]},
      {"select k / \"x\\\"y\" from ~p2",
       [
         {"2023-10-01 00:00:00", %{"k_\"x\\\"y\"" => 1.3333333333333333}},
         {"2023-10-01 00:01:00", %{"k_\"x\\\"y\"" => 1.6}}
       ]},
      {"select \"x\\\"y\" + k from ~p2",
       [
         {"2023-10-01 00:00:00", %{"\"x\\\"y\"_k" => 3.5}},
         {"2023-10-01 00:01:00", %{"\"x\\\"y\"_k" => 6.5}}
       ]},
      {"select \"x\\\"y\" * j from ~p2",
       [
         {"2023-10-01 00:00:00", %{"\"x\\\"y\"_j" => 4.5}},
         {"2023-10-01 00:01:00", %{"\"x\\\"y\"_j" => 2.5}}
       ]},
      {"select usage, usage, usage, usage_1 from ~p1 limit 1",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25, "usage_2" => 0.25, "usage_3" => 0.25}}]},
      {"select usage_1, usage, usage from ~p1 limit 1",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25, "usage_2" => 0.25}}]},
      {"select usage, usage_1, usage from ~p1 limit 1",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25, "usage_2" => 0.25}}]},
      {"select usage, usage, usage_1, usage_1 from ~p1 limit 1",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25, "usage_2" => 0.25}}]},
      {"select usage, usage, usage as usage_1 from ~p1 limit 1",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25, "usage_1" => 0.25, "usage_2" => 0.25}}]},
      {"select usage as usage_1, usage, usage from ~p1 limit 1",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25, "usage_1" => 0.25, "usage_2" => 0.25}}]},
      {"select usage, usage, usage_2, usage from ~p1 limit 1",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25, "usage_1" => 0.25, "usage_3" => 0.25}}]},
      {"select usage, usage, usage, usage_1, usage_1 from ~p1 limit 1",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25, "usage_2" => 0.25, "usage_3" => 0.25}}]},
      {"select usage + n, usage + n, usage + n as usage_n_1 from ~p1 limit 1",
       [
         {"2023-10-01 00:00:00",
          %{"usage_n" => -9.75, "usage_n_1" => -9.75, "usage_n_2" => -9.75}}
       ]},
      {"select nosuch + n, usage from ~p1 fill(7) limit 3",
       [
         {"2023-10-01 00:00:00", %{"nosuch_n" => -3, "usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"nosuch_n" => 0, "usage" => 1.75}},
         {"2023-10-01 00:02:00", %{"nosuch_n" => 7, "usage" => 3.25}},
         {"2023-10-01 00:03:00", %{"nosuch_n" => 6, "usage" => 7.0}}
       ]},
      {"select nosuch, usage + nosuch from ~p1 fill(7) limit 3",
       [
         {"2023-10-01 00:00:00", %{"nosuch" => 7, "usage_nosuch" => 7.25}},
         {"2023-10-01 00:01:00", %{"nosuch" => 7, "usage_nosuch" => 8.75}},
         {"2023-10-01 00:02:00", %{"nosuch" => 7, "usage_nosuch" => 10.25}}
       ]},
      {"select nosuch + 1 from ~p1 fill(7) limit 3", []}
    ]
  end

  @doc "The list of sources after FROM: a source with no name after its dot ends the list at the comma before it, a qualified name (`rp.m`, `db.rp.m`, `db..m`) names the database it is run in (the retention policy `autogen` or none is the database, another is `db/rp`) and the sources of one list must be qualified alike."
  @spec sources_dots() :: [{binary(), term()}]
  def sources_dots do
    [
      {"select usage from ~p1, ~p1.",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 21. Parsing Error: Nom(\", ~p1.\", Tag)"}},
      {"select usage from ~p1, a.",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 21. Parsing Error: Nom(\", a.\", Tag)"}},
      {"select usage from a, ~p1.",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 19. Parsing Error: Nom(\", ~p1.\", Tag)"}},
      {"select usage from ~p1, ~p1. limit 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 21. Parsing Error: Nom(\", ~p1. limit 1\", Tag)"}},
      {"select usage from ~p1, \"~p1\".",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 21. Parsing Error: Nom(\", \\\"~p1\\\".\", Tag)"}},
      {"select usage from ~p1..x",
       {:error, 400,
        "provided a database in both the parameters (~db) and query string (~p1) that do not match, if providing a query that specifies the database, you can omit the 'database' parameter from your request"}},
      {"select usage from ~p1..",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid FROM clause, expected identifier, regular expression or subquery at pos 18"}},
      {"select usage from ~p1.. limit 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid FROM clause, expected identifier, regular expression or subquery at pos 18"}},
      {"select usage from ~p1.. x",
       {:error, 400,
        "provided a database in both the parameters (~db) and query string (~p1) that do not match, if providing a query that specifies the database, you can omit the 'database' parameter from your request"}},
      {"select usage from ~p1.x.",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid FROM clause, expected identifier, regular expression or subquery at pos 18"}},
      {"select usage from ~p1.x.limit",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid FROM clause, expected identifier, regular expression or subquery at pos 18"}},
      {"select usage from ~p1..limit",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid FROM clause, expected identifier, regular expression or subquery at pos 18"}},
      {"select usage from ~p1.x.y.z limit 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 25. Parsing Error: Nom(\".z limit 1\", Tag)"}},
      {"select usage from ~db..~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select usage from ~db.autogen.~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select usage from autogen.~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select usage from foo.~p1 limit 2",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select usage from ~db.foo.~p1",
       {:error, 400,
        "provided a database in both the parameters (~db) and query string (~db/foo) that do not match, if providing a query that specifies the database, you can omit the 'database' parameter from your request"}},
      {"select usage from other..~p1",
       {:error, 400,
        "provided a database in both the parameters (~db) and query string (other) that do not match, if providing a query that specifies the database, you can omit the 'database' parameter from your request"}},
      {"select usage from ~db..~p1, ~db..~p1 limit 3",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"usage" => 1.75}}
       ]},
      {"select usage from ~p1, foo.~p1",
       {:error, 400, "error in InfluxQL statement: can only perform queries on a single database"}},
      {"select usage from foo.~p1, ~p1",
       {:error, 400, "error in InfluxQL statement: can only perform queries on a single database"}},
      {"select usage from foo.~p1, bar.~p1",
       {:error, 400, "error in InfluxQL statement: can only perform queries on a single database"}},
      {"select usage from foo.~p1, foo.~p1 limit 3",
       [
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:00:00", %{"usage" => 0.25}},
         {"2023-10-01 00:01:00", %{"usage" => 1.75}}
       ]},
      {"select usage from ~db..~p1, ~db.autogen.~p1",
       {:error, 400, "error in InfluxQL statement: can only perform queries on a single database"}},
      {"select usage from nosuchdb..~p1",
       {:error, 400,
        "provided a database in both the parameters (~db) and query string (nosuchdb) that do not match, if providing a query that specifies the database, you can omit the 'database' parameter from your request"}}
    ]
  end

  @doc "A clause keyword where the clauses before it end the statement (`WHERE` after `LIMIT`, `ORDER BY`, `tz()`, `GROUP BY`, `SLIMIT`)."
  @spec clause_ends() :: [{binary(), term()}]
  def clause_ends do
    [
      {"select usage from ~p1 limit 1 where",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 30. Parsing Error: Nom(\"where\", Tag)"}},
      {"select usage from ~p1 order by time where",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 36. Parsing Error: Nom(\"where\", Tag)"}},
      {"select usage from ~p1 tz('UTC') where",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 32. Parsing Error: Nom(\"where\", Tag)"}},
      {"select usage from ~p1 group by host where",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 36. Parsing Error: Nom(\"where\", Tag)"}},
      {"select usage from ~p1 slimit 1 where",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 31. Parsing Error: Nom(\"where\", Tag)"}},
      {"select usage from ~p1 where",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 22. Parsing Error: Nom(\"where\", Tag)"}}
    ]
  end

  @doc "Statements the engine answers (or rejects with a body the double does not give) and the double refuses by name, with the engine's answer."
  @spec refusals() :: [{binary(), term()}]
  def refusals do
    [
      {"select usage from ~p1 where (n > 1) = ok = 1", []},
      {"select usage from ~p1 where abs(n) < usage = 1", []},
      {"select usage from ~p1 where abs((n)) < usage = 1", []},
      {"select usage from ~p1 where time > 0 and (n > 1) = (u > 1)",
       [
         {"2023-10-01 00:04:00", %{"usage" => 6.25}},
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:11:00", %{"usage" => 16.75}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:15:00", %{"usage" => 22.75}},
         {"2023-10-01 00:16:00", %{"usage" => 24.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:19:00", %{"usage" => 28.75}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:23:00", %{"usage" => 34.75}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}},
         {"2023-10-01 00:28:00", %{"usage" => 42.25}}
       ]},
      {"select usage from ~p1 where usage + 1h > (n > 1)", []},
      {"select usage from ~p1 where (n > 1) = nosuch + 1h",
       [{"2023-10-01 00:00:00", %{"usage" => 0.25}}, {"2023-10-01 00:01:00", %{"usage" => 1.75}}]},
      {"select usage from ~p1 where u = 'a'", []},
      {"select usage from ~p1 where u > -9223372036854775808", :closed},
      {"select usage from ~p1 where s = 9223372036854775808", []},
      {"select usage from ~p1 where host = 9223372036854775808", []},
      {"select usage from ~p1 where n > 150 / 2", [{"2023-10-01 00:29:00", %{"usage" => 43.75}}]},
      {"select usage from ~p1 where n > 74 + (4 / 2)",
       [{"2023-10-01 00:29:00", %{"usage" => 43.75}}]},
      {"select usage from ~p1 where usage > 85 / 2",
       [{"2023-10-01 00:29:00", %{"usage" => 43.75}}]},
      {"select usage from ~p1 where n > + +",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid conditional expression at pos 31"}},
      {"select usage from ~p1 where usage > 1 * " <> String.duplicate("9", 330) <> ".5", []},
      {"select usage from ~p1 where usage > " <>
         String.duplicate("9", 300) <> ".5 * " <> String.duplicate("9", 300) <> ".5", []},
      {"select n from ~p1 where -(n + 1) tz('UTC')",
       {:error, 400,
        "Error during planning: Cannot create filter with non-boolean predicate 'Int64(-1) * (~p1.n + Int64(1))' returning Int64"}},
      {"select n from ~p1 where 'a\"b' tz('UTC')",
       {:error, 400,
        "Error during planning: Cannot create filter with non-boolean predicate 'Utf8(\"a\"b\")' returning Utf8"}},
      {"select k from ~p2 where \"x\\\"y\" tz('UTC')",
       {:error, 400,
        "Error during planning: Cannot create filter with non-boolean predicate '~p2.x\"y' returning Float64"}},
      {"select usage from ~p1 where time > 0 and ok = (n > 1)",
       [
         {"2023-10-01 00:06:00", %{"usage" => 9.25}},
         {"2023-10-01 00:08:00", %{"usage" => 12.25}},
         {"2023-10-01 00:14:00", %{"usage" => 21.25}},
         {"2023-10-01 00:18:00", %{"usage" => 27.25}},
         {"2023-10-01 00:20:00", %{"usage" => 30.25}},
         {"2023-10-01 00:26:00", %{"usage" => 39.25}}
       ]},
      {"select usage from ~p1 where u + 1 = (n > 1)",
       {:error, 400,
        "Error during planning: Cannot infer common argument type for comparison operation UInt64 = Boolean"}},
      {"select usage from ~p1 where abs(u) > (n > 1)",
       {:error, 400,
        "Error during planning: Cannot infer common argument type for comparison operation UInt64 > Boolean"}},
      {"select usage from ~p1 where u + usage = (n > 1)", []},
      {"select usage from ~p1 where nosuch + 'x' = host + 'a'",
       {:error, 400,
        "Error during planning: Cannot coerce arithmetic expression Dictionary(Int32, Utf8) + Utf8 to valid types"}},
      {"select usage from ~p1 where usage > (n > 1) % 2",
       {:error, 400,
        "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 44. Parsing Error: Nom(\"% 2\", Tag)"}},
      {"select usage from ~p1 where date_part('year', time) = (n > 1)", []},
      {"select usage from ~p1 where (n > 1) = date_part('year', time)", []},
      {"select usage from ~p1 tz('utc') limit 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: unable to find timezone at pos 30"}},
      {"select usage from ~p1 tz('Nowhere') limit 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: unable to find timezone at pos 34"}},
      {"select usage from ~p1 tz('') limit 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: unable to find timezone at pos 27"}},
      {"select usage from ~p1 where n > 1 tz('utc') limit 1",
       {:error, 400,
        "error in InfluxQL statement: parsing error: unable to find timezone at pos 42"}}
    ]
  end

  @doc "The reason the double gives for each statement of `refusals/0` (`Client.Local: <reason>`, with the statement after it when the parser refuses)."
  @spec refusal_reasons() :: %{binary() => binary()}
  def refusal_reasons do
    %{
      "select usage from ~p1 where abs(n) < usage = 1" => "unsupported WHERE clause: usage = 1",
      "select usage from ~p1 where abs((n)) < usage = 1" => "unsupported WHERE clause: usage = 1",
      "select usage from ~p1 where time > 0 and (n > 1) = (u > 1)" =>
        "unsupported InfluxQL (an equality of two booleans beside a comparison of the time)",
      "select usage from ~p1 where usage + 1h > (n > 1)" =>
        "unsupported InfluxQL (an expression compared with a condition in parentheses)",
      "select usage from ~p1 where (n > 1) = nosuch + 1h" =>
        "unsupported InfluxQL (an expression compared with a condition in parentheses)",
      "select usage from ~p1 where u = 'a'" =>
        "unsupported InfluxQL (an unsigned field compared with a string)",
      "select usage from ~p1 where u > -9223372036854775808" =>
        "unsupported InfluxQL (an unsigned field compared with the lowest 64-bit integer)",
      "select usage from ~p1 where s = 9223372036854775808" =>
        "unsupported InfluxQL (a string compared with an integer beyond 64 bits signed)",
      "select usage from ~p1 where host = 9223372036854775808" =>
        "unsupported InfluxQL (a string compared with an integer beyond 64 bits signed)",
      "select usage from ~p1 where n > 150 / 2" =>
        "unsupported InfluxQL (a field compared with a constant expression)",
      "select usage from ~p1 where n > 74 + (4 / 2)" =>
        "unsupported InfluxQL (a field compared with a constant expression)",
      "select usage from ~p1 where usage > 85 / 2" =>
        "unsupported InfluxQL (a field compared with a constant expression)",
      "select usage from ~p1 where n > + +" =>
        "unsupported InfluxQL (a field compared with a constant expression)",
      ("select usage from ~p1 where usage > 1 * " <> String.duplicate("9", 330) <> ".5") =>
        "unsupported InfluxQL (a field compared with a constant expression)",
      ("select usage from ~p1 where usage > " <>
         String.duplicate("9", 300) <> ".5 * " <> String.duplicate("9", 300) <> ".5") =>
        "unsupported InfluxQL (a field compared with a constant expression)",
      "select n from ~p1 where -(n + 1) tz('UTC')" =>
        "unsupported InfluxQL (a condition that is no boolean beside tz())",
      "select n from ~p1 where 'a\"b' tz('UTC')" =>
        "unsupported InfluxQL (a condition that is no boolean beside tz())",
      "select k from ~p2 where \"x\\\"y\" tz('UTC')" =>
        "unsupported InfluxQL (a condition that is no boolean beside tz())",
      "select usage from ~p1 tz('utc') limit 1" =>
        "unsupported InfluxQL (a tz() zone other than UTC with a clause behind it)",
      "select usage from ~p1 tz('Nowhere') limit 1" =>
        "unsupported InfluxQL (a tz() zone other than UTC with a clause behind it)",
      "select usage from ~p1 tz('') limit 1" =>
        "unsupported InfluxQL (a tz() zone other than UTC with a clause behind it)",
      "select usage from ~p1 where n > 1 tz('utc') limit 1" =>
        "unsupported InfluxQL (a tz() zone other than UTC with a clause behind it)",
      "select usage from ~p1 where (n > 1) = ok = 1" =>
        "unsupported InfluxQL (a comparison chained with another)",
      "select usage from ~p1 where time > 0 and ok = (n > 1)" =>
        "unsupported InfluxQL (an equality of two booleans beside a comparison of the time)",
      "select usage from ~p1 where u + 1 = (n > 1)" =>
        "unsupported InfluxQL (an expression compared with a condition in parentheses)",
      "select usage from ~p1 where abs(u) > (n > 1)" =>
        "unsupported InfluxQL (an expression compared with a condition in parentheses)",
      "select usage from ~p1 where u + usage = (n > 1)" =>
        "unsupported InfluxQL (an expression compared with a condition in parentheses)",
      "select usage from ~p1 where nosuch + 'x' = host + 'a'" =>
        "unsupported InfluxQL (an expression compared with a condition in parentheses)",
      "select usage from ~p1 where usage > (n > 1) % 2" => "unsupported InfluxQL WHERE: % 2",
      "select usage from ~p1 where date_part('year', time) = (n > 1)" =>
        "unsupported InfluxQL (date_part() in a WHERE)",
      "select usage from ~p1 where (n > 1) = date_part('year', time)" =>
        "unsupported InfluxQL (date_part() in a WHERE)"
    }
  end
end
