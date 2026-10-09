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
  spells that statement), with the letter case, the spacing and the comments of the SQL
  taken out (`select starts_with(NULL,1)` is `SELECT starts_with(NULL, 1)`, and `1+1` is
  `1 + 1`): the engine folds the case of a keyword, a function and an unquoted name, reads
  the blanks between tokens as one, none beside an operator, and a comment as a blank.
  Nothing inside a quoted string or a quoted name is touched, nor is a blank between a name
  and its parenthesis (`count (*)`) or between two operator characters (`a - -1` is not
  `a--1`, which starts a comment). The InfluxQL tables (`{text, expectation}`) are
  identified by their text, normalised the same way, but for the comments (kept: they are
  not SQL's) and for the regular expressions between slashes, which are not touched at all:
  a regular expression is case sensitive, so `/a/` and `/A/` are two cases.

  A group of cases that differ only in spelling, because the engine's answer depends on it
  (an error that prints the word as written or the column it stands at, a name it folds to
  lower case, a keyword it reads in any case), is listed in `@spelling_pins` with the reason.
  A pinned group must hold cases with different expectations, each spelling once: otherwise
  it is a case written twice behind a pin, unless the group is `:same_answer` with the
  reason that the spellings are answered alike and the spelling is what is tested. A
  `:same_answer` pin also says what the spellings differ in, and the group is checked for
  it: the members of a `:blanks` group are equal once their blanks are removed and for
  nothing else, the members of a `:case` group once their letter case is folded and for
  nothing else, so a third spelling cannot hide in a group pinned for another. A pin that
  no cases share is stale, and a spelling no pin names is a case written twice.

  Every pin also says how many cases its group holds, so that a spelling added to a pinned
  group is a failure and not absorbed by the pin. A `:position` pin (the SQL parser's
  errors, which name `Line: 1, Column: 7`) says that the members differ in the place they
  name and in nothing else: once the places are taken out their expectations are equal, so
  a mistyped word in one of them fails.

  The SQL tables are not this file's to edit: a spelling of a statement that a SQL table
  repeats is listed in `@sql_duplicates_awaiting_removal` until its owner takes it out, and
  the test fails when a listed spelling is gone, so the list only ever shrinks.

  The tables are found by name: every public function without arguments, in every module of
  the application whose name ends in `Cases`, that returns a list. The SQL tables (cases of
  `{kind, text, ...}`) all run over the same fixture, so there a case is also unique across
  tables: a statement in two of them is run twice against the same rows. The InfluxQL tables
  each bring a fixture of their own, so there the same text in two tables is two different
  questions.

  The pins of the double's refusals (`InfluxElixir.Contract.SQLScalarRefusals`, `{kind,
  text, reason}`) are scanned as well: none is written twice in its list, and each is a case
  of the table of refusable cases it belongs to.

  The line protocol tables (`InfluxElixir.ClientContract.LineProtocolCases`) are
  identified by their line or payload without the name of its measurement: `zz v=1`
  and `m v=1` are one case.
  """

  use ExUnit.Case, async: true

  defmodule Normaliser do
    @moduledoc false
    # The text of a SQL (`:sql`) or InfluxQL (`:influxql`) case without what the engine does
    # not read. Outside a quoted string or a quoted name:
    #
    # - `:case`: it is lower case;
    # - `:blanks`: a run of blanks is one blank, and no blank stands beside a comma, a
    #   semicolon, a parenthesis or an operator character, except before an opening
    #   parenthesis that a name precedes (so that `count (*)` stays itself) and between two
    #   operator characters (so that `a - -1` stays apart from `a--1`);
    # - `:comments`: SQL's comments are a blank (InfluxQL's are kept).
    #
    # The regular expressions of InfluxQL, between slashes where an operand is not, are
    # copied as written. `normalise/3` takes the list of what to fold: all of it by default.

    @operators ~c"+-*/%=<>!|&^~:"

    # The words after which an InfluxQL `/` opens a regular expression and is no division.
    @before_regex ~w(select from by where and or not in key measurement on with as)

    @spec normalise(binary(), :sql | :influxql, [:case | :blanks | :comments]) :: binary()
    def normalise(text, dialect, fold \\ [:case, :blanks, :comments]) do
      env = %{
        dialect: dialect,
        case: :case in fold,
        blanks: :blanks in fold,
        comments: :comments in fold and dialect === :sql
      }

      text |> scan([], :plain, false, nil, env) |> Enum.reverse() |> IO.iodata_to_binary()
    end

    defp scan(<<>>, acc, _mode, _pending, _prev, _env), do: acc

    defp scan(<<"''", rest::binary>>, acc, :single, _pending, _prev, env),
      do: scan(rest, ["''" | acc], :single, false, "'", env)

    defp scan(<<"'", rest::binary>>, acc, :single, _pending, _prev, env),
      do: scan(rest, ["'" | acc], :plain, false, "'", env)

    defp scan(<<"\"\"", rest::binary>>, acc, :double, _pending, _prev, env),
      do: scan(rest, ["\"\"" | acc], :double, false, "\"", env)

    defp scan(<<"\"", rest::binary>>, acc, :double, _pending, _prev, env),
      do: scan(rest, ["\"" | acc], :plain, false, "\"", env)

    defp scan(<<"\\", char::utf8, rest::binary>>, acc, :regex, _pending, _prev, env),
      do: scan(rest, [<<"\\", char::utf8>> | acc], :regex, false, "\\", env)

    defp scan(<<"/", rest::binary>>, acc, :regex, _pending, _prev, env),
      do: scan(rest, ["/" | acc], :plain, false, "/", env)

    defp scan(<<"--", rest::binary>>, acc, :plain, _pending, prev, %{comments: true} = env),
      do: scan(after_first(rest, "\n"), acc, :plain, true, prev, env)

    defp scan(<<"/*", rest::binary>>, acc, :plain, _pending, prev, %{comments: true} = env),
      do: scan(after_first(rest, "*/"), acc, :plain, true, prev, env)

    defp scan(<<char::utf8, rest::binary>>, acc, :plain, _pending, prev, env)
         when char in [?\s, ?\t, ?\n, ?\r],
         do: scan(rest, acc, :plain, true, prev, env)

    defp scan(<<char::utf8, rest::binary>>, acc, :plain, pending, prev, env) do
      here = if env.case, do: String.downcase(<<char::utf8>>), else: <<char::utf8>>
      mode = opens(here, acc, prev, env.dialect)
      kind = if mode === :regex, do: "r", else: here
      scan(rest, [here, blank(pending, prev, kind, env.blanks) | acc], mode, false, here, env)
    end

    defp scan(<<char::utf8, rest::binary>>, acc, mode, _pending, _prev, env),
      do: scan(rest, [<<char::utf8>> | acc], mode, false, <<char::utf8>>, env)

    # The text after the first `marker`, or none when there is none.
    defp after_first(text, marker) do
      case :binary.split(text, marker) do
        [_comment, rest] -> rest
        [_comment] -> ""
      end
    end

    defp opens("'", _acc, _prev, _dialect), do: :single
    defp opens("\"", _acc, _prev, _dialect), do: :double

    defp opens("/", acc, prev, :influxql),
      do: if(regex_start?(prev, acc), do: :regex, else: :plain)

    defp opens(_here, _acc, _prev, _dialect), do: :plain

    defp regex_start?(nil, _acc), do: true
    defp regex_start?(prev, _acc) when prev in ["(", ","], do: true

    defp regex_start?(prev, acc) do
      cond do
        operator?(prev) -> true
        word_char?(prev) -> last_word(acc) in @before_regex
        true -> false
      end
    end

    # The word that ends the text so far (a dropped blank is an empty placeholder, which is
    # skipped, and the first real blank ends the word).
    defp last_word(acc) do
      acc
      |> Enum.reject(&(&1 === ""))
      |> Enum.take_while(&word_char?/1)
      |> Enum.reverse()
      |> Enum.join()
    end

    defp word_char?(<<char>>) when char in ?a..?z or char in ?0..?9 or char === ?_, do: true
    defp word_char?(_other), do: false

    defp operator?(<<char>>), do: char in @operators
    defp operator?(_other), do: false

    # The blank before a character, if there is to be one.
    defp blank(false, _prev, _here, _fold), do: ""
    defp blank(true, nil, _here, _fold), do: ""
    defp blank(true, _prev, _here, false), do: " "

    defp blank(true, prev, here, true) do
      cond do
        prev in [",", ";", "("] or here in [",", ";", ")"] -> ""
        operator?(prev) and operator?(here) -> " "
        operator?(prev) or operator?(here) -> ""
        true -> " "
      end
    end
  end

  alias InfluxElixir.ContractCaseTablesTest.Normaliser

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
    catalog: {@catalog, :catalog_refusable},
    catalog_core: {@catalog, :catalog_core_refusable}
  }

  # Every pin is `{kind, members}`: the number of cases the group holds, so that a spelling
  # added to a pinned group is seen and not absorbed.
  #
  # Why a group is kept: `{:differs, reason}` when its members are answered differently
  # (the spelling is what the answer depends on), `{:same_answer, relations, reason}` when
  # they are answered alike and the spelling is what a contract pins (a lexer fact); the
  # relations (`:case`, `:blanks`, `:comments`) are all the members differ in.
  #
  # The error of a parser names the place it stopped at, and a blank or a line before or
  # after the text moves it; and it prints the word it read as written:
  #
  # `{:position, reason}` is a group whose errors differ only in the place they name
  # (`Line: 1, Column: 7`, `at pos 12`) and in the text quoted from there on: its members are
  # equal once those are taken out, so a mistyped word in one of them fails.
  @stop_place {:position,
               "the blanks around the text move where the parser says it stopped, so the " <>
                 "errors name another place"}
  # An InfluxQL parse error has a message of its own for where the text ends (`Nom(...)`
  # for the end of the text, `invalid LIMIT clause` for a blank after the keyword): a
  # blank at the end is another error, not only another place.
  @parse_stop {:differs,
               "the blanks around the text move where the parser says it stopped, and a " <>
                 "blank at the end is another error from the one at the end of the text"}
  @word_as_written {:differs,
                    "the error prints the word as written, so the spellings are answered " <>
                      "differently"}
  @key_case {:differs, "a tag key is case sensitive: `Host` and `host` are two keys"}
  # What the engine reads in any case, or folds, or skips, with the same answer:
  @keyword_case {:same_answer, [:case],
                 "a keyword (and an unquoted name) is read in any case; the contracts pin " <>
                   "that the answer is the same whichever is written"}
  @name_case {:same_answer, [:case],
              "an unquoted name or function is folded to lower case; the contracts pin that " <>
                "the answer is the same whichever is written"}
  @comment_place {:differs,
                  "a comment is a blank to the parser, but the error names the place the parser " <>
                    "stopped at, which a comment moves"}
  @comment_end {:differs,
                "a comment that is closed is a blank, one that is not swallows the rest of the text, " <>
                  "and the error says so"}
  @case_and_blanks {:same_answer, [:case, :blanks],
                    "a keyword is read in any case and a run of blanks (or none) between tokens " <>
                      "as one; the contracts pin both, in one spelling each"}
  @rest_as_written {:differs,
                    "the error prints the text from where the parser stopped as written, so " <>
                      "a blank after that place shows"}
  @blanks {:same_answer, [:blanks],
           "the parser reads a run of blanks (or none) between tokens as one; the " <>
             "contracts pin that the answer is the same with and without"}

  # The groups of cases whose texts differ only in letter case or spacing, and that are
  # kept apart on purpose, each with the reason the engine's answer depends on the
  # spelling. The key is the identity of the group: `{:sql, statement}` for a SQL case
  # (the normalised full statement, so a `:sel` case and the `:raw` case that spells the
  # same statement are one), `{:influxql, text}` for an InfluxQL case (the normalised
  # text), written as the text itself: they are normalised below, as the cases are. Every
  # member of a pinned group has an expectation of its own: a pin cannot hide a case
  # written twice. A group whose members are answered alike is `:same_answer`.
  @spelling_pins %{
    # Different answers: the spelling is what the engine's answer depends on.
    {:sql, "create;"} => {@stop_place, 2},
    {:sql, "delete from main where;"} => {@stop_place, 2},
    {:sql, "delete from;"} => {@stop_place, 2},
    {:sql, "delete;"} => {@stop_place, 2},
    {:sql, "drop;"} => {@stop_place, 2},
    {:sql, "explain;"} => {@stop_place, 2},
    {:sql, "insert into;"} => {@stop_place, 2},
    {:sql, "select 1+;"} => {@stop_place, 2},
    {:sql, "select i from mext limit;"} => {@stop_place, 2},
    {:sql, "select i from mext order by i,;"} => {@stop_place, 2},
    {:sql, "select i from mext where;"} => {@stop_place, 2},
    {:sql, "select i from;"} => {@stop_place, 2},
    {:sql, "select;"} => {@stop_place, 2},
    {:sql, "update main set;"} => {@stop_place, 2},
    {:sql, "update;"} => {@stop_place, 2},
    {:sql, "use;"} => {@stop_place, 2},
    {:sql, "values;"} => {@stop_place, 2},
    {:sql, "with;"} => {@stop_place, 2},
    {:sql, ";;select x y z"} => {@stop_place, 2},
    {:sql, "grant x"} => {@stop_place, 2},
    {:sql, "select 1 x y"} => {@comment_place, 2},
    {:sql, "select n from main where n=1"} => {@comment_end, 3},
    {:sql, "select n from main where s='é' foo"} => {@comment_place, 2},
    {:sql, "select n from main where n = 1 foo"} => {@stop_place, 8},
    {:sql, "select 5 div 2"} => {@word_as_written, 2},
    {:sql, "select 0x10 as r from main limit 1"} =>
      {{:differs, "the hex prefix is read in lower case only"}, 2},
    {:influxql, "select usage from ~p1 group by host"} =>
      {{:differs,
        "a carriage return right after GROUP leaves the statement over from it; after BY it is the missing BY"},
       2},
    {:influxql, "select usage from~p1 where now() (fill(1)"} => {@stop_place, 2},
    {:influxql, "show\vmeasurements"} => {@stop_place, 2},
    {:influxql, "'x"} => {@stop_place, 2},
    {:influxql, "select usage from~p1 where n>1"} => {@word_as_written, 2},
    {:influxql, "select usage from ~p1 group by host fill(null)"} =>
      {{:same_answer, [:blanks],
        "a carriage return anywhere inside the parentheses of fill() is the FILL option error " <>
          "at the place right after the opening parenthesis"}, 3},
    {:influxql, "select usage from ~p1 order by time"} =>
      {{:differs,
        "the error quotes the statement as written, from the ORDER, carriage return and all"}, 2},
    {:influxql, "select usage from ~p1"} =>
      {{:differs,
        "the error quotes the statement as written, so the carriage return after SELECT and after FROM differ"},
       2},
    {:influxql, "select usage from ~p1 where n > 1 and n < 5"} =>
      {{:differs,
        "a carriage return right after AND is left over (quoted as written, \\r or \\r\\n); after a blank it is a blank and the rows are answered"},
       3},
    {:influxql, "show"} => {@parse_stop, 3},
    {:influxql, "show;"} => {@parse_stop, 2},
    {:influxql, "show tag"} => {@parse_stop, 2},
    {:influxql, "show tag keys from"} => {@parse_stop, 2},
    {:influxql, "show tag keys from \"m\" where"} => {@parse_stop, 2},
    {:influxql, "show tag keys from \"m\","} => {@parse_stop, 2},
    {:influxql, "show tag keys from \"m\" limit 1 offset"} => {@parse_stop, 2},
    {:influxql, "show tag values from \"m\" with"} => {@parse_stop, 2},
    {:influxql, "show measurements extra"} => {@parse_stop, 2},
    {:influxql, "show measurements limit"} => {@parse_stop, 2},
    {:influxql, "show measurements on"} => {@parse_stop, 2},
    {:influxql, "show measurements with"} => {@parse_stop, 2},
    {:influxql, "select mean(()) from ~g1"} => {@word_as_written, 2},
    {:influxql,
     "select count(v) from ~f1 where time >= '1970-01-01T00:00:00Z' and " <>
       "time < '1970-01-01T01:00:00Z' group"} => {@parse_stop, 4},
    {:influxql,
     "select count(v) from ~f1 where time >= '1970-01-01T00:00:00Z' and " <>
       "time < '1970-01-01T01:00:00Z' group by"} => {@parse_stop, 2},
    {:influxql, "show tag values from \"~m6\" with key = host"} => {@key_case, 2},
    {:influxql, "show measurements with measurement =~ /^~p/ where host = 'h1'"} =>
      {@key_case, 2},
    # The same answer: both spellings are kept for the lexer fact they pin.
    {:sql, ";select n from main where"} => {@blanks, 2},
    {:sql, "drop schema s"} => {@keyword_case, 2},
    {:sql, "grant all on m to u"} => {@keyword_case, 2},
    {:sql, "grant select"} => {@keyword_case, 2},
    {:sql, "insert into main (v) values (1)"} => {@blanks, 2},
    {:sql, "merge into m using t on true when matched then delete"} => {@keyword_case, 2},
    {:sql, "merge into main using main on true when matched then delete"} => {@keyword_case, 2},
    {:sql, "show columns from main"} => {@case_and_blanks, 3},
    {:sql, "select host,count(*) as c from main group by host having c > 3 order by host"} =>
      {@name_case, 2},
    {:sql, "select host as having from main order by time limit 2"} => {@keyword_case, 2},
    {:sql, "select right(s,1) as r from main order by time"} => {@name_case, 2},
    {:sql, "select zz.host from main"} => {@name_case, 2},
    {:influxql, "select v + true from ~g1"} => {@keyword_case, 2},
    {:influxql, "show tag keys from \"~m3\""} => {@keyword_case, 2},
    {:influxql, "show tag keys from \"~m3\",\"~m4\""} => {@blanks, 2},
    {:influxql, "show tag keys on"} => {@blanks, 2},
    {:influxql, "group by time(2m,x)"} => {@blanks, 2},
    {:influxql, "show tag values from \"~m3\" with key = host"} => {@case_and_blanks, 3},
    {:influxql, "show tag values from \"~m3\" with key in (host,region)"} => {@blanks, 2},
    {:influxql, "show tag values from \"m\""} => {@blanks, 2},
    {:influxql, "show tag values"} => {@blanks, 2},
    {:influxql, "show measurements with measurement =~ /^~p/"} => {@blanks, 3},
    {:influxql, "show retention policies"} => {@keyword_case, 2},
    {:influxql, "select count(distinct v) from ~f1"} => {@case_and_blanks, 3},
    {:influxql, "select percentile(/./,99.5) from ~f3"} => {@rest_as_written, 2},
    {:influxql,
     "select mean(usage) from ~m1 where time >= '2024-01-01T00:00:00Z' and " <>
       "time < '2024-01-01T00:05:00Z' group by time(1m) fill(none)"} => {@keyword_case, 2},
    {:influxql, "select n from ~g1 where abs(v) = 1"} => {@name_case, 2}
  }

  @pins for {{dialect, text}, pin} <- @spelling_pins,
            into: %{},
            do: {{dialect, Normaliser.normalise(text, dialect)}, pin}

  # SQL cases that a table spells twice in a way the answer cannot tell from the first, found
  # when the comments and the blanks beside operators were folded into the identity. They are
  # not for this file to take out of the SQL tables: each entry lists the spellings of a
  # statement to take out (the statement stays in its other spellings), and the test below
  # fails when one is gone, so that its entry goes with it. The map is empty when the SQL
  # tables hold nothing written twice.
  @sql_duplicates_awaiting_removal %{}

  @awaiting for {{dialect, text}, spellings} <- @sql_duplicates_awaiting_removal,
                into: %{},
                do: {{dialect, Normaliser.normalise(text, dialect)}, spellings}

  @tables for {:ok, modules} <-
                [:application.get_key(:influx_elixir, :modules)],
              module <- modules,
              String.ends_with?(Atom.to_string(module), "Cases"),
              {name, 0} <- module.__info__(:functions),
              do: {module, name}

  @refusal_tables for {name, 0} <- @refusals.__info__(:functions), do: {@refusals, name}

  # The cases modules by their sources: a table is a public function of no arguments that a
  # file `*_cases.ex` of the test support defines, found here without loading the module, so
  # that a table the scan above misses (or one it takes for a table that is none) is seen.
  @case_files Path.wildcard(Path.expand("../support/**/*_cases.ex", __DIR__))
  @refusal_file Path.expand("../support/contract/sql_scalar_refusals.ex", __DIR__)

  test "the scan finds exactly the case tables the sources of the cases modules define" do
    assert Enum.any?(@case_files)

    from_sources =
      for file <- @case_files,
          {module, name} <- source_tables(file),
          into: MapSet.new(),
          do: {module, name}

    assert MapSet.new(@tables) === from_sources
    assert length(@tables) === MapSet.size(from_sources)
    assert @tables |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() === length(@case_files)

    assert MapSet.new(@refusal_tables) === MapSet.new(source_tables(@refusal_file))
    assert Enum.any?(@refusal_tables)
  end

  # `{module, name}` of every public function of no arguments a source file defines
  # (`def name do`, `def name, do:`).
  defp source_tables(file) do
    source = File.read!(file)
    [_all, module] = Regex.run(~r/^defmodule ([\w.]+) do/m, source)
    module = Module.concat([module])

    ~r/^  def ([a-z_]\w*[?!]?)(?:\(\))?(?: do\b|,\s*do:)/m
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&{module, String.to_atom(&1)})
  end

  test "no case is written twice, in its table or (for SQL) in another" do
    repeated =
      for {{_scope, identity}, group} <- groups(),
          length(group) > 1,
          not Map.has_key?(@pins, identity),
          do: "#{inspect(identity)} is written #{length(group)} times: #{describe(group)}"

    assert Enum.sort(repeated) === []
  end

  test "a pinned group holds each spelling once, and is the kind of group its pin says" do
    flawed =
      for {{_scope, identity}, group} <- groups(),
          length(group) > 1,
          {pin, members} <- [Map.get(@pins, identity)],
          problem = pin_problem(pin, members, group),
          do: "#{inspect(identity)} #{problem}: #{describe(group)}"

    assert Enum.sort(flawed) === []
  end

  test "a spelling pin names a group of cases that differ only in spelling" do
    colliding =
      for {{_scope, identity}, group} <- groups(),
          length(group) > 1,
          into: MapSet.new(),
          do: identity

    stale = for {identity, _pin} <- @pins, identity not in colliding, do: identity

    assert Enum.sort(stale) === [], "these pins have no cases that spell them alike"
  end

  test "a SQL case awaiting removal is still in a table (when it is gone, take its entry out)" do
    present = MapSet.new(entries(), &{&1.identity, &1.spelling})

    gone =
      for {identity, spellings} <- @awaiting,
          spelling <- spellings,
          not MapSet.member?(present, {identity, spelling}),
          do: {identity, spelling}

    assert gone === []
  end

  test "every pin is of a known kind and has a reason" do
    for {identity, {pin, members}} <- @pins do
      reason =
        case pin do
          {:differs, reason} -> reason
          {:position, reason} -> reason
          {:same_answer, relations, reason} when is_list(relations) -> reason
        end

      assert is_binary(reason) and String.length(reason) >= 10,
             "no reason for #{inspect(identity)}"

      assert is_integer(members) and members >= 2,
             "a pinned group holds at least two cases: #{inspect(identity)}"
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
          {kind, text, _reason} <- apply(@refusals, name, []),
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

  test "the identity of a SQL text ignores its letter case, blanks and comments only" do
    assert sql("select  starts_with(NULL,1)\n from main") ===
             sql("SELECT starts_with( NULL, 1 ) FROM main")

    assert sql("select 1+1") === sql("select 1 + 1")
    assert sql("select a<=b,-c from t") === sql("select a <= b , - c from t")
    assert sql("select 1 -- one\n from t") === sql("select 1 from t")
    assert sql("select /* one */ 1 from t") === sql("select 1 from t")
    assert sql("select 1/*a*/+/*b*/1") === sql("select 1 + 1")

    refute sql("SELECT 'A'") === sql("select 'a'")
    refute sql(~s(SELECT "Host")) === sql("select host")
    refute sql("SELECT 'a  b'") === sql("select 'a b'")
    refute sql("SELECT 'a -- b'") === sql("select 'a '")
    refute sql("SELECT 'a /* b */'") === sql("select 'a '")
    refute sql("SELECT count (*)") === sql("SELECT count(*)")
    refute sql("where abs (v) = 1") === sql("where abs(v) = 1")
    refute sql("select a - -1") === sql("select a--1")
    assert sql("SELECT 'it''s'") === sql("select 'it''s'")
    assert sql("a ~ 'S[01]'") === sql("A  ~  'S[01]'")
    refute sql("a ~ 'S[01]'") === sql("a ~ 's[01]'")
  end

  test "the identity of an InfluxQL text ignores its letter case and blanks, not its regular expressions" do
    assert influxql("SELECT  mean(v) FROM m WHERE host =~ /a/") ===
             influxql("select mean( v ) from m where host=~/a/")

    assert influxql("select v+1 from m") === influxql("select v + 1 from m")
    assert influxql("group by /host/") === influxql("GROUP BY /host/")
    refute influxql("group by /host/") === influxql("group by /HOST/")
    refute influxql("where host =~ /a b/") === influxql("where host =~ /a  b/")
    refute influxql("where host =~ /\\bm/") === influxql("where host =~ /\\Bm/")
    refute influxql("select /^v/ from m") === influxql("select /^V/ from m")

    refute influxql("select percentile(/./, 9) from m") ===
             influxql("select percentile(/./, 9)/*a*/ from m")

    # A slash after an operand is a division, folded like any operator.
    assert influxql("select v / W from m") === influxql("select V/w from m")
    # Its comments are not SQL's: a text that differs in one is another case.
    refute influxql("select/*c*/mean(v) from m") === influxql("select mean(v) from m")
  end

  defp sql(text), do: Normaliser.normalise(text, :sql)
  defp influxql(text), do: Normaliser.normalise(text, :influxql)

  # The cases of every table as entries, in the scope they must be unique in, grouped by
  # identity: `{{scope, identity}, [entry]}`. The SQL tables share a scope (one fixture),
  # every other table is a scope of its own.
  defp groups do
    entries()
    |> Enum.reject(&(&1.spelling in Map.get(@awaiting, &1.identity, [])))
    |> Enum.group_by(&{&1.scope, &1.identity})
  end

  defp entries do
    for {module, name} <- @tables ++ @refusal_tables,
        case_ <- apply(module, name, []) do
      entry(module, name, case_)
    end
  end

  defp entry(@lines = module, name, {text, _expectation} = case_) when name in @line_tables,
    do: entry(module, name, {:line, @lines.measurement_free(text)}, case_, text)

  defp entry(@refusals = module, name, {kind, text, _reason} = case_),
    do: entry(module, name, sql_identity(kind, text), case_, text, :refused)

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
      do:
        entry(
          module,
          name,
          {:influxql, Normaliser.normalise(text, :influxql)},
          case_,
          text,
          expectation
        ),
      else: entry(module, name, {:case, case_}, case_, text, expectation)
  end

  defp entry(module, name, case_), do: entry(module, name, {:case, case_}, case_, case_)

  defp entry(module, name, identity, case_, spelling, expectation \\ nil)

  defp entry(module, name, {:sql, _statement} = identity, case_, spelling, expectation) do
    scope = if module === @refusals, do: {module, name}, else: :sql

    %{
      scope: scope,
      table: table_name(module, name),
      identity: identity,
      spelling: spelling,
      statement: statement(case_, spelling),
      expectation: expectation
    }
  end

  defp entry(module, name, identity, _case, spelling, expectation) do
    %{
      scope: {module, name},
      table: table_name(module, name),
      identity: identity,
      spelling: spelling,
      statement: spelling,
      expectation: expectation
    }
  end

  # The text a SQL case runs, which is what its spelling is compared on: a `:sel` case's
  # text is a part of its statement.
  defp statement(case_, spelling) do
    case Tuple.to_list(case_) do
      [kind, ^spelling | _rest] when kind in [:sel, :where, :order, :raw] ->
        {statement, _key} = @statements.statement(kind, spelling)
        statement

      _other ->
        spelling
    end
  end

  defp influxql?(module), do: module |> Atom.to_string() |> String.contains?("InfluxQL")

  # A SQL case's identity: the normalised statement it runs. A kind the contracts do not
  # expand keeps its kind.
  defp sql_identity(kind, text) when kind in [:sel, :where, :order, :raw] do
    {statement, _key} = @statements.statement(kind, text)
    {:sql, Normaliser.normalise(statement, :sql)}
  end

  defp sql_identity(kind, text), do: {:sql, {kind, Normaliser.normalise(text, :sql)}}

  # Why a pinned group is not what its pin says, or `nil`.
  defp pin_problem(pin, members, group) do
    spellings = Enum.map(group, & &1.spelling)

    cond do
      length(group) !== members ->
        "holds #{length(group)} cases and its pin says #{members}: a spelling was added or " <>
          "taken out"

      length(Enum.uniq(spellings)) < length(spellings) ->
        "has a spelling twice"

      match?({:differs, _reason}, pin) and not distinct?(group) ->
        "has cases with the same expectation: a case written twice, or a :same_answer"

      match?({:position, _reason}, pin) ->
        position_problem(group)

      match?({:same_answer, _relations, _reason}, pin) ->
        same_answer_problem(pin, group)

      true ->
        nil
    end
  end

  # A `:position` group is answered differently by every member, and the answers are one
  # once the place they name and the text quoted from it are taken out.
  defp position_problem(group) do
    folded = group |> Enum.map(&fold_position(&1.expectation)) |> Enum.uniq()

    cond do
      not distinct?(group) ->
        "has cases with the same expectation as written: a case written twice, or a :same_answer"

      length(folded) > 1 ->
        "has expectations that differ in more than the place the parser stopped at: " <>
          inspect(folded, limit: :infinity)

      true ->
        nil
    end
  end

  # An expectation without the place an error names (`Line: 1, Column: 7`, `at pos 12`) and
  # without the text quoted from where the parser stopped (`Nom("rest", Tag)`).
  defp fold_position(expectation) do
    expectation
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> String.replace(~r/Line: \d+, Column: \d+/, "Line: _, Column: _")
    |> String.replace(~r/at pos \d+/, "at pos _")
    |> String.replace(~r/Nom\(\\".*?\\", (Tag|Char)\)/, "Nom(_, \\1)")
  end

  # A `:same_answer` group is answered alike by every member, and its members differ in the
  # one thing its pin names: a third spelling does not hide in it.
  defp same_answer_problem({:same_answer, relations, _reason}, group) do
    cond do
      distinct?(group) ->
        "has cases with different expectations: it is :differs"

      length(Enum.uniq(Enum.map(group, & &1.expectation))) > 1 ->
        "has cases with expectations that are not all the same: it is :differs, and a case " <>
          "written twice hides in it"

      not alike?(group, relations) ->
        "has spellings that differ in more than #{inspect(relations)}"

      Enum.any?(relations, &alike?(group, relations -- [&1])) ->
        "has spellings that do not differ in #{inspect(relations)}: a relation it does not need"

      true ->
        nil
    end
  end

  # Whether every member of the group is the same text once what `relations` says the
  # spellings differ in is removed, and nothing else.
  defp alike?(group, relations),
    do: group |> Enum.uniq_by(&folded(relations, &1.statement)) |> length() === 1

  defp folded(relations, statement) do
    text =
      if :comments in relations,
        do: Normaliser.normalise(statement, :sql, [:comments]),
        else: statement

    text = if :blanks in relations, do: String.replace(text, ~r/\s+/u, ""), else: text
    if :case in relations, do: String.downcase(text), else: text
  end

  # Whether no two members of a group have the same expectation.
  defp distinct?(group) do
    expectations = Enum.map(group, & &1.expectation)
    length(Enum.uniq(expectations)) === length(expectations)
  end

  # The spellings of a group, each with its table and a tag that two members share when
  # their expectations are the same.
  defp describe(group) do
    group
    |> Enum.map(&{&1.spelling, &1.table, :erlang.phash2(&1.expectation, 1000)})
    |> inspect(limit: :infinity)
  end

  defp table_name(module, name),
    do: "#{inspect(module)}.#{name}" |> String.replace("InfluxElixir.Contract.", "")

  # `{kind, text}` of a SQL case as it is spelled, or `nil`.
  defp spelled({kind, text, _expectation}) when is_atom(kind), do: {kind, text}
  defp spelled({kind, text, _tag, _answer}) when is_atom(kind), do: {kind, text}
  defp spelled({kind, text, _tag, _status, _body}) when is_atom(kind), do: {kind, text}
  defp spelled({kind, text}) when is_atom(kind) and is_binary(text), do: {kind, text}
  defp spelled(_other), do: nil
end
