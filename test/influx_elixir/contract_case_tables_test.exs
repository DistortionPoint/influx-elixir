defmodule InfluxElixir.ContractCaseTablesTest do
  @moduledoc """
  Keeps the contracts' case tables (`InfluxElixir.Contract.*Cases`) free of a case
  written twice.

  A case is run once per table per tier, so a repeat adds a second run of the same
  question and no assertion: it reads as coverage and is none. A case is identified by
  what it asks. Two cases with the same identity and different expectations are worse:
  one of them is wrong on the engine.

  The identity of a SQL case is its whole statement, as the contracts run it
  (`InfluxElixir.Contract.SQLScalar.statement/2`: a `:sel`, `:where` or `:order` case is
  expanded into the statement it stands in, so it collides with the `:raw` case that
  spells that statement), with the letter case and the spacing of the SQL taken out
  (`select starts_with(NULL,1)` is `SELECT starts_with(NULL, 1)`): the engine folds the case
  of a keyword, a function and an unquoted name, and reads the blanks between tokens as
  one. Nothing inside a quoted string or a quoted name is touched, and neither is a blank
  between a name and its parenthesis (`count (*)`). The InfluxQL tables (`{text,
  expectation}`) are identified by their text, normalised the same way.

  A group of cases that differ only in spelling, because the engine's answer depends on it
  (an error that prints the word as written or the column it stands at, a name it folds to
  lower case, a keyword it reads in any case, a regular expression that is case sensitive),
  is listed in `@spelling_pins` with the reason. A pinned group must hold cases with
  different expectations, each spelling once: otherwise it is a case written twice behind a
  pin, unless the group is `:same_answer` with the reason that both spellings are
  answered alike and the spelling is what is tested. A pin that no cases share is stale, and
  a spelling no pin names is a case written twice. A real duplicate that is waiting to be
  taken out of a table is pinned `:duplicate`, which goes stale (and fails) with the
  duplicate: take the pin out then.

  The tables are found by name: every public function without arguments, in every module of
  the application whose name ends in `Cases`, that returns a list. The SQL tables (cases of
  `{kind, text, ...}`) all run over the same fixture, so there a case is also unique across
  tables: a statement in two of them is run twice against the same rows. The InfluxQL tables
  each bring a fixture of their own, so there the same text in two tables is two different
  questions.

  The pins of the double's refusals (`InfluxElixir.Contract.SQLScalarRefusals`, `{kind,
  text}`) are scanned as well: none is written twice in its list, and each is a case of the
  table of refusable cases it belongs to.

  The line protocol tables (`InfluxElixir.ClientContract.LineProtocolCases`) are
  identified by their line or payload without the name of its measurement: `zz v=1`
  and `m v=1` are one case.
  """

  use ExUnit.Case, async: true

  # The line protocol tables whose case begins with a line or a payload.
  @line_tables [:v3_errors, :v3_stored, :v3_numbered, :v2_errors, :v2_payloads, :v2_stored]
  @lines InfluxElixir.ClientContract.LineProtocolCases
  @refusals InfluxElixir.Contract.SQLScalarRefusals
  @scalar InfluxElixir.Contract.SQLScalarCases
  @catalog InfluxElixir.Contract.SQLCatalogCases
  @statements InfluxElixir.Contract.SQLScalar

  # The table of refusable cases each list of refusals names.
  @refusable %{
    expressions_values: {@scalar, :expressions_values_refusable},
    expressions_names: {@scalar, :expressions_names_refusable},
    functions_values: {@scalar, :functions_values_refusable},
    errors: {@scalar, :errors_refusable},
    aggregates: {@catalog, :aggregates_refusable},
    syntax: {@catalog, :syntax_refusable},
    catalog: {@catalog, :catalog_refusable}
  }

  # Why a group is kept: `{:differs, reason}` when its members are answered differently
  # (the spelling is what the answer depends on), `{:same_answer, reason}` when they are
  # answered alike and the spelling is what a contract pins (a lexer fact), and
  # `{:duplicate, reason}` for a real duplicate that is waiting to be taken out.
  #
  # The error of a parser names the place it stopped at, and a blank or a line before or
  # after the text moves it; and it prints the word it read as written:
  @stop_place {:differs,
               "the blanks around the text move where the parser says it stopped, so the " <>
                 "errors differ"}
  @word_as_written {:differs,
                    "the error prints the word as written, so the spellings are answered " <>
                      "differently"}
  @regex_case {:differs,
               "a regular expression is case sensitive: the spellings match different things"}
  @key_case {:differs, "a tag key is case sensitive: `Host` and `host` are two keys"}
  # What the engine reads in any case, or folds, or skips, with the same answer:
  @keyword_case {:same_answer,
                 "a keyword (and an unquoted name) is read in any case; the contracts pin " <>
                   "that the answer is the same whichever is written"}
  @name_case {:same_answer,
              "an unquoted name or function is folded to lower case; the contracts pin that " <>
                "the answer is the same whichever is written"}
  @blanks {:same_answer,
           "the parser reads a run of blanks (or none) between tokens as one; the " <>
             "contracts pin that the answer is the same with and without"}

  # The groups of cases whose texts differ only in letter case or spacing, and that are
  # kept apart on purpose, each with the reason the engine's answer depends on the
  # spelling. The key is the identity of the group: `{:sql, statement}` for a SQL case
  # (the normalised full statement, so a `:sel` case and the `:raw` case that spells the
  # same statement are one), `{:influxql, text}` for an InfluxQL case (the normalised
  # text), both as `normalise/1` leaves them. Every member of a pinned group has an
  # expectation of its own: a pin cannot hide a case written twice. A group whose members
  # are answered alike is `:same_answer`.
  @spelling_pins %{
    # Different answers: the spelling is what the engine's answer depends on.
    {:sql, ";;select x y z"} => @stop_place,
    {:sql, "grant x"} => @stop_place,
    {:sql, "select n from main where n = 1 foo"} => @stop_place,
    {:sql, "select 5 div 2"} => @word_as_written,
    {:sql, "select 0x10 as r from main limit 1"} =>
      {:differs, "the hex prefix is read in lower case only"},
    {:influxql, "show"} => @stop_place,
    {:influxql, "show;"} => @stop_place,
    {:influxql, "show tag"} => @stop_place,
    {:influxql, "show tag keys from"} => @stop_place,
    {:influxql, "show tag keys from \"m\" where"} => @stop_place,
    {:influxql, "show tag keys from \"m\","} => @stop_place,
    {:influxql, "show tag keys from \"m\" limit 1 offset"} => @stop_place,
    {:influxql, "show tag values from \"m\" with"} => @stop_place,
    {:influxql, "show measurements extra"} => @stop_place,
    {:influxql, "show measurements limit"} => @stop_place,
    {:influxql, "show measurements on"} => @stop_place,
    {:influxql, "show measurements with"} => @stop_place,
    {:influxql, "select mean(()) from ~g1"} => @stop_place,
    {:influxql,
     "select count(v) from ~f1 where time >= '1970-01-01T00:00:00Z' and " <>
       "time < '1970-01-01T01:00:00Z' group"} => @stop_place,
    {:influxql,
     "select count(v) from ~f1 where time >= '1970-01-01T00:00:00Z' and " <>
       "time < '1970-01-01T01:00:00Z' group by"} => @stop_place,
    {:influxql, "msg =~ /m/"} => @regex_case,
    {:influxql, "select * from ~g1 group by /host/"} => @regex_case,
    {:influxql, "show tag values from \"~m6\" with key = host"} => @key_case,
    {:influxql, "show measurements with measurement =~ /^~p/ where host = 'h1'"} => @key_case,
    # The same answer: both spellings are kept for the lexer fact they pin.
    {:sql, ";select n from main where"} => @blanks,
    {:sql, "drop schema s"} => @keyword_case,
    {:sql, "grant all on m to u"} => @keyword_case,
    {:sql, "grant select"} => @keyword_case,
    {:sql, "insert into main (v) values (1)"} => @blanks,
    {:sql, "merge into m using t on true when matched then delete"} => @keyword_case,
    {:sql, "merge into main using main on true when matched then delete"} => @keyword_case,
    {:sql, "show columns from main"} => @keyword_case,
    {:sql, "select host,count(*) as c from main group by host having c > 3 order by host"} =>
      @name_case,
    {:sql, "select host as having from main order by time limit 2"} => @keyword_case,
    {:sql, "select right(s,1) as r from main order by time"} => @name_case,
    {:sql, "select zz.host from main"} => @name_case,
    {:influxql, "select v + true from ~g1"} => @keyword_case,
    {:influxql, "show tag keys from \"~m3\""} => @keyword_case,
    {:influxql, "show tag keys from \"~m3\",\"~m4\""} => @blanks,
    {:influxql, "show tag keys on"} => @blanks,
    {:influxql, "group by time(2m,x)"} => @blanks,
    {:influxql, "show tag values from \"~m3\" with key = host"} => @keyword_case,
    {:influxql, "show tag values from \"~m3\" with key in (host,region)"} => @blanks,
    {:influxql, "show tag values from \"m\""} => @blanks,
    {:influxql, "show tag values"} => @blanks,
    {:influxql, "show measurements with measurement =~ /^~p/"} => @blanks,
    {:influxql, "show retention policies"} => @keyword_case,
    {:influxql, "select count(distinct v) from ~f1"} => @keyword_case,
    {:influxql, "select percentile(/./,99.5) from ~f3"} => @blanks,
    {:influxql,
     "select mean(usage) from ~m1 where time >= '2024-01-01T00:00:00Z' and " <>
       "time < '2024-01-01T00:05:00Z' group by time(1m) fill(none)"} => @keyword_case,
    {:influxql, "select n from ~g1 where abs(v) = 1"} => @name_case,
    {:influxql, "msg =~ /\\bm/"} =>
      {:same_answer,
       "`\\b` and `\\B` are two regular expressions (a word boundary and its negation); " <>
         "the fixture has no word that tells them apart"}
  }

  @tables for {:ok, modules} <- [:application.get_key(:influx_elixir, :modules)],
              module <- modules,
              String.ends_with?(Atom.to_string(module), "Cases"),
              {name, 0} <- module.__info__(:functions),
              do: {module, name}

  @refusal_tables for {name, 0} <- @refusals.__info__(:functions), do: {@refusals, name}

  test "the scan finds the case tables of every cases module" do
    modules = @tables |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    assert length(modules) >= 11
    assert length(@tables) >= 59
    assert length(@refusal_tables) >= 7
  end

  test "no case is written twice, in its table or (for SQL) in another" do
    repeated =
      for {{_scope, identity}, group} <- groups(),
          length(group) > 1,
          not Map.has_key?(@spelling_pins, identity),
          do: "#{inspect(identity)} is written #{length(group)} times: #{describe(group)}"

    assert Enum.sort(repeated) === []
  end

  test "a pinned group holds each spelling once, and is the kind of group its pin says" do
    flawed =
      for {{_scope, identity}, group} <- groups(),
          length(group) > 1,
          {kind, _reason} <- [Map.get(@spelling_pins, identity)],
          problem = pin_problem(kind, group),
          do: "#{inspect(identity)} #{problem}: #{describe(group)}"

    assert Enum.sort(flawed) === []
  end

  test "a spelling pin names a group of cases that differ only in spelling" do
    colliding =
      for {{_scope, identity}, group} <- groups(),
          length(group) > 1,
          into: MapSet.new(),
          do: identity

    stale = for {identity, _pin} <- @spelling_pins, identity not in colliding, do: identity

    assert Enum.sort(stale) === [], "these pins have no cases that spell them alike"
  end

  test "every pin is of a known kind and has a reason" do
    for {identity, pin} <- @spelling_pins do
      assert {kind, reason} = pin, "#{inspect(identity)} is no {kind, reason}"
      assert kind in [:differs, :same_answer, :duplicate]

      assert is_binary(reason) and String.length(reason) >= 10,
             "no reason for #{inspect(identity)}"
    end
  end

  test "a line is the same case whatever the name of its measurement" do
    assert @lines.measurement_free("zz,t=1 v=1 5") === @lines.measurement_free("~m,t=1 v=1 5")
    assert @lines.measurement_free("m v=1\nzz v=2") === @lines.measurement_free("zz v=1\nzz v=2")
    refute @lines.measurement_free("zz,t=1 v=1") === @lines.measurement_free("zz,t=2 v=1")
    refute @lines.measurement_free("zz v=1") === @lines.measurement_free("zz v=1 5")
  end

  test "each refusal is a case of the table of refusable cases it belongs to" do
    missing =
      for {_module, name} <- @refusal_tables,
          {refusable_module, refusable} = Map.fetch!(@refusable, name),
          known = MapSet.new(apply(refusable_module, refusable, []), &spelled/1),
          {kind, text} <- apply(@refusals, name, []),
          not MapSet.member?(known, {kind, text}),
          do: "#{name}: #{inspect({kind, text})} is no case of #{refusable}/0"

    assert missing === []
  end

  test "a :sel, :where or :order case is the same case as the :raw statement it stands in" do
    assert sql_identity(:sel, "1+1") ===
             sql_identity(:raw, "select 1+1 AS r from main order by time")

    assert sql_identity(:where, "v > 1") ===
             sql_identity(:raw, "SELECT v FROM main WHERE v > 1 ORDER BY time")

    assert sql_identity(:order, "v DESC") ===
             sql_identity(:raw, "select v from main order by v desc, time")

    refute sql_identity(:sel, "1") === sql_identity(:where, "1")
  end

  test "the identity of a SQL or InfluxQL text ignores the letter case and the blanks of the SQL only" do
    assert normalise("select  starts_with(NULL,1)\n from main") ===
             normalise("SELECT starts_with( NULL, 1 ) FROM main")

    refute normalise("SELECT 'A'") === normalise("select 'a'")
    refute normalise(~s(SELECT "Host")) === normalise("select host")
    refute normalise("SELECT 'a  b'") === normalise("select 'a b'")
    refute normalise("SELECT count (*)") === normalise("SELECT count(*)")
    refute normalise("where abs (v) = 1") === normalise("where abs(v) = 1")
    # A regular expression is not told from the rest: its case is folded, and the pairs that
    # differ only there are pinned with the reason.
    assert normalise("group by /host/") === normalise("group by /HOST/")
    assert normalise("SELECT 'it''s'") === normalise("select 'it''s'")
    assert normalise("a ~ 'S[01]'") === normalise("A  ~  'S[01]'")
    refute normalise("a ~ 'S[01]'") === normalise("a ~ 's[01]'")
  end

  # The cases of every table as entries, in the scope they must be unique in, grouped by
  # identity: `{{scope, identity}, [entry]}`. The SQL tables share a scope (one fixture),
  # every other table is a scope of its own.
  defp groups do
    for {module, name} <- @tables ++ @refusal_tables,
        case_ <- apply(module, name, []) do
      entry(module, name, case_)
    end
    |> Enum.group_by(&{&1.scope, &1.identity})
  end

  defp entry(@lines = module, name, {text, _expectation} = case_) when name in @line_tables,
    do: entry(module, name, {:line, @lines.measurement_free(text)}, case_, text)

  defp entry(@refusals = module, name, {kind, text} = case_),
    do: entry(module, name, sql_identity(kind, text), case_, text, {:refused, text})

  defp entry(module, name, case_) when is_tuple(case_) and tuple_size(case_) in 3..5 do
    case Tuple.to_list(case_) do
      [kind, text | expectation] when is_atom(kind) and is_binary(text) ->
        entry(module, name, sql_identity(kind, text), case_, text, expectation)

      _other ->
        entry(module, name, {:case, case_}, case_, case_)
    end
  end

  defp entry(module, name, {text, expectation} = case_) when is_binary(text) do
    if influxql?(module),
      do: entry(module, name, {:influxql, normalise(text)}, case_, text, expectation),
      else: entry(module, name, {:case, case_}, case_, text, expectation)
  end

  defp entry(module, name, case_), do: entry(module, name, {:case, case_}, case_, case_)

  defp entry(module, name, identity, case_, spelling, expectation \\ nil)

  defp entry(module, name, {:sql, _statement} = identity, _case, spelling, expectation) do
    scope = if module === @refusals, do: {module, name}, else: :sql
    %{scope: scope, identity: identity, spelling: spelling, expectation: expectation}
  end

  defp entry(module, name, identity, _case, spelling, expectation),
    do: %{scope: {module, name}, identity: identity, spelling: spelling, expectation: expectation}

  defp influxql?(module), do: module |> Atom.to_string() |> String.contains?("InfluxQL")

  # A SQL case's identity: the normalised statement it runs. A kind the contracts do not
  # expand keeps its kind.
  defp sql_identity(kind, text) when kind in [:sel, :where, :order, :raw] do
    {statement, _key} = @statements.statement(kind, text)
    {:sql, normalise(statement)}
  end

  defp sql_identity(kind, text), do: {:sql, {kind, normalise(text)}}

  # Why a pinned group is not what its pin says, or `nil`.
  defp pin_problem(kind, group) do
    spellings = Enum.map(group, & &1.spelling)

    cond do
      length(Enum.uniq(spellings)) < length(spellings) ->
        "has a spelling twice"

      kind === :differs and not distinct?(group) ->
        "has cases with the same expectation: a case written twice, or a :same_answer"

      kind === :same_answer and distinct?(group) ->
        "has cases with different expectations: it is :differs"

      true ->
        nil
    end
  end

  # Whether no two members of a group have the same expectation.
  defp distinct?(group) do
    expectations = Enum.map(group, & &1.expectation)
    length(Enum.uniq(expectations)) === length(expectations)
  end

  defp describe(group), do: group |> Enum.map(& &1.spelling) |> inspect(limit: :infinity)

  # `{kind, text}` of a SQL case as it is spelled, or `nil`.
  defp spelled({kind, text, _expectation}) when is_atom(kind), do: {kind, text}
  defp spelled({kind, text, _tag, _answer}) when is_atom(kind), do: {kind, text}
  defp spelled({kind, text, _tag, _status, _body}) when is_atom(kind), do: {kind, text}
  defp spelled({kind, text}) when is_atom(kind) and is_binary(text), do: {kind, text}
  defp spelled(_other), do: nil

  # The text without the letter case and the blanks of the SQL: outside a quoted string or a
  # quoted name it is lower case and a run of blanks is one blank, and no blank stands beside a
  # comma, a semicolon or a parenthesis, except before an opening one that a name precedes
  # (so that `count (*)` stays itself).
  defp normalise(text),
    do: text |> scan([], :plain, false, nil) |> Enum.reverse() |> IO.iodata_to_binary()

  defp scan(<<>>, acc, _mode, _pending, _prev), do: acc

  defp scan(<<"''", rest::binary>>, acc, :single, _pending, _prev),
    do: scan(rest, ["''" | acc], :single, false, "'")

  defp scan(<<"'", rest::binary>>, acc, :single, _pending, _prev),
    do: scan(rest, ["'" | acc], :plain, false, "'")

  defp scan(<<"\"\"", rest::binary>>, acc, :double, _pending, _prev),
    do: scan(rest, ["\"\"" | acc], :double, false, "\"")

  defp scan(<<"\"", rest::binary>>, acc, :double, _pending, _prev),
    do: scan(rest, ["\"" | acc], :plain, false, "\"")

  defp scan(<<char::utf8, rest::binary>>, acc, :plain, _pending, prev)
       when char in [?\s, ?\t, ?\n, ?\r],
       do: scan(rest, acc, :plain, true, prev)

  defp scan(<<char::utf8, rest::binary>>, acc, :plain, pending, prev) do
    here = String.downcase(<<char::utf8>>)
    mode = if here == "'", do: :single, else: if(here == "\"", do: :double, else: :plain)
    scan(rest, [here, blank(pending, prev, here) | acc], mode, false, here)
  end

  defp scan(<<char::utf8, rest::binary>>, acc, mode, _pending, _prev),
    do: scan(rest, [<<char::utf8>> | acc], mode, false, <<char::utf8>>)

  # The blank before a character, if there is to be one.
  defp blank(false, _prev, _here), do: ""
  defp blank(true, nil, _here), do: ""
  defp blank(true, prev, _here) when prev in [",", ";", "("], do: ""
  defp blank(true, _prev, here) when here in [",", ";", ")"], do: ""
  defp blank(true, _prev, _here), do: " "
end
