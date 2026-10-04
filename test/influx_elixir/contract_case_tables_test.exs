defmodule InfluxElixir.ContractCaseTablesTest do
  @moduledoc """
  Keeps the contracts' case tables (`InfluxElixir.Contract.*Cases`) free of a case
  written twice.

  A case is run once per table per tier, so a repeat adds a second run of the same
  statement and no assertion: it reads as coverage and is none. A case is identified
  by what it asks, which is its text, and for the SQL tables the kind of place the
  text stands in as well (`{kind, text}`). Two cases with the same identity and
  different expectations are worse: one of them is wrong on the engine.

  The identity of a SQL case is its text with the letter case and the spacing of the SQL
  taken out (`select starts_with(NULL,1)` is `SELECT starts_with(NULL, 1)`): the engine
  folds the case of a keyword, a function and an unquoted name, and reads the blanks
  between tokens as one. Nothing inside a quoted string or a quoted name is touched, and
  neither is a blank between a name and its parenthesis (`count (*)`).

  A case that pins the spelling itself, because the engine's answer depends on it (an error that
  prints the word as written or the column it stands at, a name it folds to lower case, a
  keyword it reads in any case), is a spelling pin: it keeps its own identity, and is listed in
  `@spelling_pins` with the reason. A pin that no other case spells alike is stale, and a spelling
  no pin names is a case written twice.

  The tables are found by name: every public function without arguments, in every
  module of the application whose name ends in `Cases`, that returns a list.
  The SQL tables (cases of `{kind, text, ...}`) all run over the same fixture, so
  there a case is also unique across tables: a text in two of them is run twice
  against the same rows. The InfluxQL tables (`{text, ...}`) each bring a fixture
  of their own, so there the same text in two tables is two different questions.

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

  # The cases that pin a spelling, as `{kind, text}`, each group with the reason the engine's
  # answer depends on it.
  @spelling_pins [
    # An error that prints where the parser stopped: the blanks and lines before it count.
    {:raw, ";; SELECT x y z"},
    {:raw, ";\n;\nSELECT x y z"},
    {:raw, "grant x"},
    {:raw, "grant   x"},
    {:raw, "SELECT n FROM main WHERE n = 1 foo"},
    {:raw, "  SELECT n FROM main WHERE n = 1 foo"},
    {:raw, "\n\nSELECT n FROM main WHERE n = 1 foo"},
    # The word the parser read, printed as written.
    {:raw, "SELECT 5 div 2"},
    {:raw, "SELECT 5 DIV 2"},
    {:raw, "SELECT 0X10 AS r FROM main LIMIT 1"},
    {:raw, "SELECT 0x10 AS r FROM main LIMIT 1"},
    # A keyword, a table, a function and a name the engine reads in any case.
    {:raw, "GRANT all on m to u"},
    {:raw, "grant all on m to u"},
    {:raw, "GRANT SELECT"},
    {:raw, "grant select"},
    {:raw, "drop schema s"},
    {:raw, "DROP SCHEMA S"},
    {:raw, "INSERT INTO m VALUES (1)"},
    {:raw, "insert into m values (1)"},
    {:raw, "merge into m using t on true when matched then delete"},
    {:raw, "MERGE INTO m USING t ON TRUE WHEN MATCHED THEN DELETE"},
    {:raw, "MERGE INTO main USING main ON true WHEN MATCHED THEN DELETE"},
    {:raw, "merge into main using main on true when matched then delete"},
    {:raw, "USE rv_lib"},
    {:raw, "use rv_lib"},
    {:raw, "Use rv_lib"},
    {:raw, "SHOW COLUMNS FROM main"},
    {:raw, "show columns from MAIN"},
    {:raw, "  SHOW   COLUMNS   FROM   main"},
    {:raw, "SELECT zz.host FROM main"},
    {:raw, "SELECT zz.Host FROM main"},
    {:raw, "SELECT host AS having FROM main ORDER BY time LIMIT 2"},
    {:raw, "SELECT host AS HAVING FROM main ORDER BY time LIMIT 2"},
    {:raw, "SELECT host, count(*) AS c FROM main GROUP BY host HAVING c > 3 ORDER BY host"},
    {:raw, "SELECT host, count(*) AS C FROM main GROUP BY host HAVING C > 3 ORDER BY host"},
    {:sel, "right(s, 1)"},
    {:sel, "Right(s, 1)"},
    {:raw, "SELECT 1e1 AS r FROM main LIMIT 1"},
    {:raw, "SELECT 1E1 AS r FROM main LIMIT 1"},
    # The blanks the parser reads between tokens, with and without.
    {:raw, "; SELECT n FROM main WHERE"},
    {:raw, ";SELECT n FROM main WHERE"},
    {:raw, "insert into main  (  v  ) values (1)"},
    {:raw, "insert into main (v) values (1)"},
    {:raw, "SELECT n FROM main WHERE n = 1;"},
    {:raw, "SELECT n FROM main WHERE n = 1 ;"},
    {:raw, "SELECT n FROM (main) ORDER BY time"},
    {:raw, "SELECT n FROM ( main ) ORDER BY time"}
  ]

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

  test "no case is written twice in its table" do
    repeated =
      for {module, name} <- @tables ++ @refusal_tables,
          {identity, count} <-
            apply(module, name, []) |> Enum.frequencies_by(&identity(module, name, &1)),
          count > 1,
          do: "#{inspect(module)}.#{name}/0 x#{count}: #{inspect(identity)}"

    assert repeated === []
  end

  test "a line is the same case whatever the name of its measurement" do
    assert @lines.measurement_free("zz,t=1 v=1 5") === @lines.measurement_free("~m,t=1 v=1 5")
    assert @lines.measurement_free("m v=1\nzz v=2") === @lines.measurement_free("zz v=1\nzz v=2")
    refute @lines.measurement_free("zz,t=1 v=1") === @lines.measurement_free("zz,t=2 v=1")
    refute @lines.measurement_free("zz v=1") === @lines.measurement_free("zz v=1 5")
  end

  test "no SQL case is written in two tables" do
    in_tables =
      for {module, name} <- @tables,
          case_ <- apply(module, name, []),
          {kind, _text} = identity <- [identity(module, name, case_)],
          is_atom(kind),
          uniq: true,
          do: {identity, {module, name}}

    repeated =
      for {identity, tables} <- Enum.group_by(in_tables, &elem(&1, 0), &elem(&1, 1)),
          length(tables) > 1,
          do: "#{inspect(identity)} is in #{inspect(Enum.sort(tables))}"

    assert Enum.sort(repeated) === []
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

  test "a spelling pin names a case that another case spells alike, and every such case is a pin" do
    groups =
      for {module, name} <- @tables,
          case_ <- apply(module, name, []),
          {kind, text} <- [spelled(case_)],
          is_atom(kind),
          is_binary(text),
          reduce: %{} do
        groups ->
          Map.update(
            groups,
            {kind, normalise(text)},
            MapSet.new([{kind, text}]),
            &MapSet.put(&1, {kind, text})
          )
      end

    collisions = for {_identity, spellings} <- groups, MapSet.size(spellings) > 1, do: spellings
    colliding = collisions |> Enum.flat_map(&MapSet.to_list/1) |> MapSet.new()
    pins = MapSet.new(@spelling_pins)

    stale = pins |> MapSet.difference(colliding) |> MapSet.to_list() |> Enum.sort()
    twice = colliding |> MapSet.difference(pins) |> MapSet.to_list() |> Enum.sort()

    assert stale === [], "these pins have no case that spells them alike: #{inspect(stale)}"

    assert twice === [],
           "these cases are written twice (differing in letter case or spacing): #{inspect(twice)}"
  end

  test "the identity of a SQL case ignores the letter case and the blanks of the SQL only" do
    assert normalise("select  starts_with(NULL,1)\n from main") ===
             normalise("SELECT starts_with( NULL, 1 ) FROM main")

    refute normalise("SELECT 'A'") === normalise("select 'a'")
    refute normalise(~s(SELECT "Host")) === normalise("select host")
    refute normalise("SELECT 'a  b'") === normalise("select 'a b'")
    refute normalise("SELECT count (*)") === normalise("SELECT count(*)")
    assert normalise("SELECT 'it''s'") === normalise("select 'it''s'")
    assert normalise("a ~ 'S[01]'") === normalise("A  ~  'S[01]'")
    refute normalise("a ~ 'S[01]'") === normalise("a ~ 's[01]'")
  end

  # `{kind, text}` of a SQL case as it is spelled, or `nil`.
  defp spelled({kind, text, _expectation}) when is_atom(kind), do: {kind, text}
  defp spelled({kind, text, _tag, _answer}) when is_atom(kind), do: {kind, text}
  defp spelled({kind, text, _tag, _status, _body}) when is_atom(kind), do: {kind, text}
  defp spelled({kind, text}) when is_atom(kind) and is_binary(text), do: {kind, text}
  defp spelled(_other), do: nil

  # `{kind, text, ...}` where the first element is the kind of place (an atom),
  # `{text, ...}` where it is the text, or the case itself. A line is identified by
  # the line without the name of its measurement. A SQL text is identified without its
  # letter case and blanks, unless the case pins its spelling.
  defp identity(@lines, name, {text, _expectation}) when name in @line_tables,
    do: @lines.measurement_free(text)

  defp identity(_module, _name, case_), do: identity(case_)

  defp identity({kind, text, _expectation} = case_) when is_atom(kind), do: sql(case_, kind, text)

  defp identity({kind, text, _tag, _answer} = case_) when is_atom(kind),
    do: sql(case_, kind, text)

  defp identity({kind, text, _tag, _status, _body} = case_) when is_atom(kind),
    do: sql(case_, kind, text)

  defp identity({kind, text} = case_) when is_atom(kind) and is_binary(text),
    do: sql(case_, kind, text)

  defp identity({text, _expectation}), do: text
  defp identity(other), do: other

  defp sql(_case, kind, text) do
    if {kind, text} in @spelling_pins, do: {kind, {:spelled, text}}, else: {kind, normalise(text)}
  end

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
