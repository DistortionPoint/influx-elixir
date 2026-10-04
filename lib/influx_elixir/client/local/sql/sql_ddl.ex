defmodule InfluxElixir.Client.Local.SQLDdl do
  @moduledoc false
  # What the engine's parser says of the `CREATE`, `DROP`, `DESC` and `ATTACH` statements
  # it reads only as far as a keyword it wants next (verified against InfluxDB 3 Core):
  #
  #     create trigger t  ->  ParserError("Expected: one of FOR or BEFORE or AFTER or ...")
  #     drop table a, b   ->  ParserError("Multiple objects not supported")
  #     drop index i      ->  405 Only `DROP TABLE/VIEW/SCHEMA  ...` is supported currently
  #     desc 1            ->  ParserError("Expected: identifier, found: 1 at Line: 1, Column: 6")
  #
  # Each family is the shapes that were verified; any other shape of the same statement is
  # refused by name (or left to the rest of the double when it is one it already words).

  alias InfluxElixir.Client.Local.{SQLError, SQLTokenizer}

  @drop_kinds "CONNECTOR, DATABASE, EXTENSION, FUNCTION, INDEX, POLICY, PROCEDURE, ROLE, SCHEMA, " <>
                "SECRET, SEQUENCE, STAGE, TABLE, TRIGGER, TYPE, VIEW, MATERIALIZED VIEW or USER " <>
                "after DROP"
  @replaced "[EXTERNAL] TABLE or [MATERIALIZED] VIEW or FUNCTION after CREATE OR REPLACE"
  @create_kind "an object type after CREATE"

  # The words after `CREATE` that start no statement, `DROP` words likewise.
  @unknown_create ~w(BUCKET OPERATOR COLLATION TAG WAREHOUSE PIPE STREAM TASK SHARE INTEGRATION
                     STAGE)
  @unknown_drop ~w(MACRO OPERATOR)

  # After `CREATE OR REPLACE` these are not read (the rest are `TABLE`, `VIEW` and `FUNCTION`
  # and what the parser takes beside them).
  @not_replaced ~w(SCHEMA DATABASE STAGE SEQUENCE ROLE PROCEDURE SERVER VIRTUAL)

  # What `CREATE <kind> name` wants next, and the words that go on from there.
  @wants %{
    "TRIGGER" => {"one of FOR or BEFORE or AFTER or INSTEAD", ~w(FOR BEFORE AFTER INSTEAD)},
    "MACRO" => {"(", ["("]},
    "FUNCTION" => {"(", ["("]},
    "PROCEDURE" => {"AS", ["AS"]},
    "DOMAIN" => {"AS", ["AS"]},
    "TYPE" => {"AS", ["AS"]},
    "SECRET" => {"(", ["("]},
    "SERVER" => {"FOREIGN", ["FOREIGN"]},
    "POLICY" => {"ON", ["ON"]}
  }
  @with_replace ~w(TRIGGER MACRO FUNCTION)

  # The statements that go on from the wanted word are ones the engine does not run and
  # names (`CREATE POLICY p ON m`), which `InfluxElixir.Client.Local.SQLStatement` words.
  @worded ~w(POLICY SERVER VIRTUAL)

  # The kinds that take a name and nothing else of the double's concern.
  @named ~w(SEQUENCE ROLE USER EXTENSION)

  # `DROP` of these is the planner's "only TABLE/VIEW/SCHEMA" refusal.
  @only_drop ~w(INDEX ROLE USER TYPE SEQUENCE STAGE DATABASE)
  @named_drop ~w(EXTENSION TRIGGER PROCEDURE SECRET CONNECTOR DOMAIN FUNCTION)
  @only_message "This feature is not implemented: Only `DROP TABLE/VIEW/SCHEMA  ...` " <>
                  "statement is supported currently"

  @doc """
  The parser's error for a verified shape of these statements, a refusal for a shape of the
  same statement that was not, `nil` for any other text.
  """
  @spec error(binary()) :: SQLError.t() | nil
  def error(sql) do
    case SQLTokenizer.tokenize(sql) do
      {:ok, tokens} -> tokens |> single_statement() |> classify()
      :bail -> nil
    end
  end

  # The tokens of one statement without its closing `;` and end, or `:many`.
  @spec single_statement(SQLTokenizer.tokens()) :: [SQLTokenizer.token()] | :many
  defp single_statement(tokens) do
    semicolons = Enum.count(tokens, &match?({:symbol, ";", _upper, _line, _col}, &1))

    closing? =
      match?([{:symbol, ";", _u, _l, _c}, {:eof, _p, _u2, _l2, _c2}], Enum.take(tokens, -2))

    if semicolons == 0 or (semicolons == 1 and closing?), do: tokens, else: :many
  end

  @spec classify([SQLTokenizer.token()] | :many) :: SQLError.t() | nil
  defp classify(:many), do: nil
  defp classify([{:word, _p, "CREATE", _l, _c} | rest]), do: create(rest)
  defp classify([{:word, _p, "DROP", _l, _c} | rest]), do: drop(rest)

  defp classify([{:word, _p, describe, _l, _c} | rest]) when describe in ["DESC", "DESCRIBE"],
    do: describe(rest)

  defp classify([{:word, _p, "ATTACH", _l, _c}, {:word, _p2, "DATABASE", _l2, _c2} | rest]),
    do: attach(rest)

  defp classify([{:word, _p, "MSCK", _l, _c} | rest]), do: msck(rest)
  defp classify([{:word, _p, "MERGE", _l, _c} | rest]), do: merge(rest)
  defp classify(_tokens), do: nil

  # `MSCK [REPAIR] TABLE name`.
  @spec msck([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp msck([{:word, _p, "REPAIR", _l, _c}, {:word, _p2, "TABLE", _l2, _c2}, end_token | _rest]) do
    if end_of?(end_token), do: expected("identifier", end_token)
  end

  defp msck([{:word, _p, "REPAIR", _l, _c}, end_token | _rest]) do
    if end_of?(end_token), do: expected("TABLE", end_token)
  end

  defp msck([{:word, _p, "TABLE", _l, _c}, end_token | _rest]) do
    if end_of?(end_token), do: expected("identifier", end_token)
  end

  defp msck(_tokens), do: nil

  # `MERGE INTO` with no target, and `MERGE INTO a USING b` with no `ON`.
  @spec merge([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp merge([{:word, _p, "INTO", _l, _c}, end_token | _rest] = tokens) do
    if end_of?(end_token), do: expected("identifier", end_token), else: merge_using(tokens)
  end

  defp merge(_tokens), do: nil

  defp merge_using([_into | rest]) do
    with {:ok, [{:word, _p, "USING", _l, _c} | after_using]} <- name(rest),
         {:ok, [end_token | _rest]} <- name(after_using),
         true <- end_of?(end_token) do
      expected("ON", end_token)
    else
      _other -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # CREATE
  # ---------------------------------------------------------------------------

  @spec create([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp create([
         {:word, _p, "OR", _l, _c},
         {:word, _p2, "REPLACE", _l2, _c2},
         {:word, _p3, kind, _l3, _c3} = token | rest
       ]) do
    cond do
      kind in @with_replace -> named_kind(kind, rest)
      kind in @not_replaced -> expected(@replaced, token)
      true -> nil
    end
  end

  defp create([{:word, _p, "OR", _l, _c}, {:word, _p2, "REPLACE", _l2, _c2}, end_token | _rest]) do
    if end_of?(end_token), do: expected(@replaced, end_token)
  end

  defp create([{:word, _p, "OR", _l, _c} = token, end_token | _rest]) do
    if end_of?(end_token), do: expected(@create_kind, token)
  end

  defp create([{:word, _printed, kind, _l, _c} = token | rest]) do
    cond do
      kind in @unknown_create -> expected(@create_kind, token)
      kind == "VIRTUAL" -> virtual(rest)
      Map.has_key?(@wants, kind) or kind in @named -> named_kind(kind, rest)
      true -> nil
    end
  end

  defp create(_tokens), do: nil

  @spec virtual([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp virtual([{:word, _p, "TABLE", _l, _c} | rest]) do
    rest =
      case rest do
        [
          {:word, _p1, "IF", _l1, _c1},
          {:word, _p2, "NOT", _l2, _c2},
          {:word, _p3, "EXISTS", _l3, _c3} | after_exists
        ] ->
          after_exists

        _no_condition ->
          rest
      end

    after_name("VIRTUAL", "USING", ["USING"], rest)
  end

  defp virtual(_tokens), do: nil

  # `CREATE kind name ...`: the name, then what the kind wants.
  @spec named_kind(binary(), [SQLTokenizer.token()]) :: SQLError.t() | nil
  defp named_kind(kind, rest) do
    case Map.fetch(@wants, kind) do
      {:ok, {what, goes_on}} -> after_name(kind, what, goes_on, rest)
      :error -> bare_name(rest)
    end
  end

  # A kind with no name is `Expected: identifier`; with one the double words it itself.
  @spec bare_name([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp bare_name([end_token]) do
    if end_of?(end_token), do: expected("identifier", end_token)
  end

  defp bare_name([end_token, _eof]) do
    if end_of?(end_token), do: expected("identifier", end_token)
  end

  defp bare_name(_tokens), do: nil

  # The name, then a token that is not the one wanted: that token is where the parser stops.
  @spec after_name(binary(), binary(), [binary()], [SQLTokenizer.token()]) ::
          SQLError.t() | nil
  defp after_name(kind, what, goes_on, tokens) do
    case name(tokens) do
      {:ok, [next | _rest]} ->
        cond do
          not continues?(next, goes_on) -> expected(what, next)
          kind in @worded -> nil
          true -> refusal(what)
        end

      :none ->
        case tokens do
          [end_token | _rest] -> if end_of?(end_token), do: expected("identifier", end_token)
          [] -> nil
        end
    end
  end

  @spec continues?(SQLTokenizer.token(), [binary()]) :: boolean()
  defp continues?({_kind, _printed, upper, _line, _col}, goes_on), do: upper in goes_on

  # ---------------------------------------------------------------------------
  # DROP
  # ---------------------------------------------------------------------------

  @spec drop([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp drop([{:word, _p, kind, _l, _c} = token | rest]) do
    cond do
      kind in @unknown_drop ->
        expected(@drop_kinds, token)

      kind in @only_drop ->
        drop_object(rest, :only)

      kind == "MATERIALIZED" ->
        case rest do
          [{:word, _p2, "VIEW", _l2, _c2} | after_view] -> drop_object(after_view, :only)
          _other -> nil
        end

      kind in ["TABLE", "VIEW", "SCHEMA"] ->
        drop_object(rest, :single_is_known)

      kind == "POLICY" ->
        drop_policy(rest)

      kind in @named_drop ->
        bare_drop(rest)

      true ->
        nil
    end
  end

  defp drop(_tokens), do: nil

  # `DROP kind [IF EXISTS] name [, name ...]`.
  @spec drop_object([SQLTokenizer.token()], :only | :single_is_known) :: SQLError.t() | nil
  defp drop_object(tokens, handling) do
    tokens = skip_if_exists(tokens)

    case names(tokens) do
      {:ok, 1, rest} ->
        if handling == :only, do: only_tail(rest)

      {:ok, count, rest} when count > 1 ->
        if cascade_end?(rest), do: SQLError.parser("Multiple objects not supported")

      :none ->
        bare_drop(tokens)
    end
  end

  # What may follow the one name of `DROP index`, `DROP role`... before the end.
  @spec only_tail([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp only_tail(rest) do
    rest =
      case rest do
        [{:word, _p, "ON", _l, _c} | after_on] ->
          case name(after_on) do
            {:ok, after_name} -> after_name
            :none -> :bad
          end

        _no_on ->
          rest
      end

    cond do
      rest == :bad -> nil
      cascade_end?(rest) -> %{status: 405, body: @only_message}
      true -> nil
    end
  end

  @spec drop_policy([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp drop_policy(tokens),
    do: tokens |> skip_if_exists() |> then(&after_name("POLICY", "ON", ["ON"], &1))

  @spec bare_drop([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp bare_drop(tokens), do: tokens |> skip_if_exists() |> bare_name()

  @spec skip_if_exists([SQLTokenizer.token()]) :: [SQLTokenizer.token()]
  defp skip_if_exists([{:word, _p, "IF", _l, _c}, {:word, _p2, "EXISTS", _l2, _c2} | rest]),
    do: rest

  defp skip_if_exists(tokens), do: tokens

  # The end, with `CASCADE` or `RESTRICT` before it or not.
  @spec cascade_end?([SQLTokenizer.token()]) :: boolean()
  defp cascade_end?([{:word, _p, option, _l, _c} | rest]) when option in ["CASCADE", "RESTRICT"],
    do: cascade_end?(rest)

  defp cascade_end?([token]), do: end_of?(token)
  defp cascade_end?([token, {:eof, _p, _u, _l, _c}]), do: end_of?(token)
  defp cascade_end?(_tokens), do: false

  # ---------------------------------------------------------------------------
  # DESC, ATTACH
  # ---------------------------------------------------------------------------

  @spec describe([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp describe([{:number, _p, _u, _l, _c} = number | _rest]), do: expected("identifier", number)

  defp describe(tokens) do
    case name(tokens) do
      {:ok, [next | _rest]} ->
        unless end_of?(next), do: expected("end of statement", next)

      :none ->
        case tokens do
          [end_token | _rest] -> if end_of?(end_token), do: expected("identifier", end_token)
          [] -> nil
        end
    end
  end

  @spec attach([SQLTokenizer.token()]) :: SQLError.t() | nil
  defp attach([end_token | _rest]) do
    if end_of?(end_token), do: expected("an expression", end_token)
  end

  defp attach(_tokens), do: nil

  # ---------------------------------------------------------------------------
  # Tokens
  # ---------------------------------------------------------------------------

  # A dotted name: the tokens after it, or `:none` when no name starts the tokens.
  @spec name([SQLTokenizer.token()]) :: {:ok, [SQLTokenizer.token()]} | :none
  defp name([{kind, _p, _u, _l, _c} | rest]) when kind in [:word, :quoted],
    do: {:ok, dotted(rest)}

  defp name(_tokens), do: :none

  @spec dotted([SQLTokenizer.token()]) :: [SQLTokenizer.token()]
  defp dotted([{:symbol, ".", _p, _l, _c}, {kind, _p2, _u2, _l2, _c2} | more])
       when kind in [:word, :quoted],
       do: dotted(more)

  defp dotted(rest), do: rest

  # Names separated by commas: how many, and the tokens after them.
  @spec names([SQLTokenizer.token()]) :: {:ok, pos_integer(), [SQLTokenizer.token()]} | :none
  defp names(tokens) do
    case name(tokens) do
      {:ok, [{:symbol, ",", _p, _l, _c} | rest]} ->
        case names(rest) do
          {:ok, count, after_names} -> {:ok, count + 1, after_names}
          :none -> :none
        end

      {:ok, rest} ->
        {:ok, 1, rest}

      :none ->
        :none
    end
  end

  @spec end_of?(SQLTokenizer.token()) :: boolean()
  defp end_of?({:eof, _p, _u, _l, _c}), do: true
  defp end_of?({:symbol, ";", _u, _l, _c}), do: true
  defp end_of?(_token), do: false

  @doc """
  The parser's `Expected: <what>, found: <token>` for a token, at its line and column.
  """
  @spec expected(binary(), SQLTokenizer.token()) :: SQLError.t()
  def expected(what, {:eof, _printed, _upper, _line, _col}),
    do: SQLError.parser("Expected: #{what}, found: EOF")

  def expected(what, {_kind, printed, _upper, line, col}),
    do: SQLError.parser("Expected: #{what}, found: #{printed} at Line: #{line}, Column: #{col}")

  @spec refusal(binary()) :: SQLError.t()
  defp refusal(what) do
    SQLError.refusal(
      "a statement that goes on where the parser wants #{what}: the engine's answer for it " <>
        "is not modelled"
    )
  end
end
