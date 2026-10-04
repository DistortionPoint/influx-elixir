defmodule InfluxElixir.Client.Local.SQLDml do
  @moduledoc false
  # The planner's answer to an `INSERT` or an `UPDATE`, which it never runs (verified against
  # InfluxDB 3 Core): the table it names is looked up first, so a table that is not there is
  # `table 'public.iox.<name>' not found`, whatever else the statement says; a table that is
  # there is `DML not supported: Insert Into` (or `Update`), once its columns are found.
  #
  # The double words the shapes it verified and refuses the rest by name:
  #
  #   * `INSERT INTO name [(column, ...)] VALUES | SELECT | WITH | (` over a table that is not
  #     there; over one that is, with a column list of columns it has (the first that it has
  #     not is `Schema error: No field named <column>`), or with no list and `VALUES` rows of
  #     numbers (a row of the wrong length is `Inconsistent data length across values list`)
  #   * `UPDATE name [[AS] alias] SET column = operand [, ...] [WHERE operand] [RETURNING ..]
  #     [LIMIT ..]`: the parser reads it (`SQLDmlExpr`) and the planner's steps are followed
  #     in their order (see UPDATE below): the targets, the names and calls of the `WHERE`,
  #     each value's names, types and conversion to its column's type. A shape of operand
  #     that was not verified (a subquery, `CASE`, an interval, a function the double does
  #     not know) is refused by name
  #   * a leading `;` is read as the engine reads it: an empty statement before the one
  #     that follows
  #   * the parser's own errors for a statement that stops short (`UPDATE name`,
  #     `INSERT INTO name (a)`, `INSERT INTO name VALUES`) or goes on with a word it does
  #     not read
  #
  # The schema of the name decides little: `iox` is the database, any other schema has no
  # table.

  alias InfluxElixir.Client.Local.{
    SQLDdl,
    SQLDmlExpr,
    SQLDmlName,
    SQLDmlOperand,
    SQLError,
    SQLTokenizer
  }

  @sources ~w(VALUES SELECT WITH)
  @query_body "SELECT, VALUES, or a subquery in the query body"

  @typep token :: SQLTokenizer.token()

  @typedoc """
  Gives a table's columns (sorted, `time` among them), `{:types, table}` their Arrow types.
  """
  @type columns_of :: (binary() | {:types, binary()} -> [binary()] | [{binary(), binary()}])

  @typedoc "Plans an operand as a select item of the table, the errors it has there."
  @type planner :: (binary(), binary() -> :ok | {:error, term()} | {:refuse, binary()})

  @typep env :: %{columns_of: columns_of(), planner: planner()}

  @doc """
  The planner's error for an `INSERT` or an `UPDATE`, given the names of the database's
  tables, a function giving a table's columns and a function planning an operand as a select
  item, or a refusal by name for a shape that was not verified.
  """
  @spec error(:insert | :update, binary(), [binary()], columns_of(), planner()) ::
          SQLError.t() | map()
  def error(kind, statement, tables, columns_of, planner) do
    env = %{columns_of: columns_of, planner: planner}

    case SQLTokenizer.tokenize(without_leading_semicolons(statement)) do
      {:ok, tokens} -> answer(kind, split_end(tokens), tables, env)
      :bail -> not_modelled(kind, "a statement the tokenizer does not read")
    end
  end

  # The empty statements before the statement are blanked, so that the line and column of
  # what it says stay those of the text (the tokenizer ends a text at its first `;`).
  @spec without_leading_semicolons(binary()) :: binary()
  defp without_leading_semicolons(statement) do
    [leading] = Regex.run(~r/\A[\s;]*/u, statement)
    size = byte_size(leading)
    String.replace(leading, ";", " ") <> binary_part(statement, size, byte_size(statement) - size)
  end

  # The statement's tokens and the token that ends it (its `;`, or the end of the text).
  @spec split_end([token()]) :: {[token()], token()}
  defp split_end(tokens) do
    case Enum.reverse(tokens) do
      [_eof, {:symbol, ";", _u, _l, _c} = semicolon | before] -> {Enum.reverse(before), semicolon}
      [eof | before] -> {Enum.reverse(before), eof}
    end
  end

  @spec answer(:insert | :update, {[token()], token()}, [binary()], env()) ::
          SQLError.t() | map()
  defp answer(:insert, {[_insert, {:word, _p, "INTO", _l, _c} | rest], stop}, tables, env),
    do: insert(rest, stop, tables, env.columns_of)

  defp answer(:insert, {[_insert | rest], stop}, tables, env),
    do: insert(rest, stop, tables, env.columns_of)

  defp answer(:update, {[_update | rest], stop}, tables, env),
    do: update(rest, stop, tables, env)

  # ---------------------------------------------------------------------------
  # INSERT
  # ---------------------------------------------------------------------------

  @spec insert([token()], token(), [binary()], columns_of()) :: SQLError.t() | map()
  defp insert([{:word, _p, upper, _l, _c} | _rest], _stop, _tables, _columns_of)
       when upper in ["OVERWRITE", "OR", "IGNORE"],
       do: not_modelled(:insert, "that spelling")

  defp insert(tokens, stop, tables, columns_of) do
    with {:ok, reference, rest} <- reference(tokens),
         {:ok, listed, source} <- column_list(rest),
         :ok <- source_read(source, stop),
         {:ok, table} <- resolve(reference, tables) do
      inserted(table, listed, source, tables, columns_of)
    else
      {:error, error} -> error
      {:refuse, why} -> not_modelled(:insert, why)
    end
  end

  @spec inserted(
          {:found, binary()} | {:missing, binary()},
          [binary()] | nil,
          [token()],
          [binary()],
          columns_of()
        ) :: SQLError.t() | map()
  defp inserted({:missing, name}, _listed, source, _tables, _columns_of),
    do: source_error(source) || not_found(name)

  defp inserted({:found, table}, listed, source, tables, columns_of) do
    columns = columns_of.(table)

    cond do
      error = source_error(source) -> error
      table not in tables -> not_found(table)
      listed == nil -> inserted_values(source, length(columns), false)
      true -> unknown_column(listed, columns) || inserted_values(source, length(listed), true)
    end
  end

  # The rows of a `VALUES` are counted against the columns listed, or against the table's when
  # none are; a query as the source is not read (a table with a list takes it, one without is
  # not modelled).
  @spec inserted_values([token()], non_neg_integer(), boolean()) :: SQLError.t() | map()
  defp inserted_values([{:word, _p, "VALUES", _l, _c} | rows], expected, _listed?) do
    case row_lengths(rows, []) do
      {:ok, lengths} ->
        case Enum.find_index(lengths, &(&1 != expected)) do
          nil ->
            dml(:insert)

          row ->
            SQLError.planning(
              "Inconsistent data length across values list: got #{Enum.at(lengths, row)} " <>
                "values in row #{row} but expected #{expected}"
            )
        end

      :error ->
        not_modelled(:insert, "values the double cannot count")
    end
  end

  defp inserted_values(_source, _expected, true), do: dml(:insert)

  defp inserted_values(_source, _expected, false),
    do: not_modelled(:insert, "no column list over a query into a table")

  # The number of values of each `VALUES` row (the commas of its top level, plus one).
  @spec row_lengths([token()], [pos_integer()]) :: {:ok, [pos_integer()]} | :error
  defp row_lengths([], found), do: {:ok, Enum.reverse(found)}

  defp row_lengths([{:symbol, "(", _u, _l, _c} | rest], found) do
    with {:ok, inside, more} <- group(rest, 0, []),
         {:ok, count} <- value_count(inside) do
      case more do
        [{:symbol, ",", _u2, _l2, _c2} | next] -> row_lengths(next, [count | found])
        [] -> row_lengths([], [count | found])
        _other -> :error
      end
    end
  end

  defp row_lengths(_tokens, _found), do: :error

  # The tokens up to the parenthesis that closes a group, and those after it.
  @spec group([token()], non_neg_integer(), [token()]) :: {:ok, [token()], [token()]} | :error
  defp group([], _depth, _found), do: :error
  defp group([{:symbol, ")", _u, _l, _c} | rest], 0, found), do: {:ok, Enum.reverse(found), rest}

  defp group([{:symbol, ")", _u, _l, _c} = token | rest], depth, found),
    do: group(rest, depth - 1, [token | found])

  defp group([{:symbol, "(", _u, _l, _c} = token | rest], depth, found),
    do: group(rest, depth + 1, [token | found])

  defp group([token | rest], depth, found), do: group(rest, depth, [token | found])

  # The values of a row: split at the commas outside parentheses, none of them empty.
  @spec value_count([token()]) :: {:ok, pos_integer()} | :error
  defp value_count(inside) do
    {values, last, _depth} =
      Enum.reduce(inside, {[], [], 0}, fn
        {:symbol, "(", _u, _l, _c} = token, {values, current, depth} ->
          {values, [token | current], depth + 1}

        {:symbol, ")", _u, _l, _c} = token, {values, current, depth} ->
          {values, [token | current], depth - 1}

        {:symbol, ",", _u, _l, _c}, {values, current, 0} ->
          {[current | values], [], 0}

        token, {values, current, depth} ->
          {values, [token | current], depth}
      end)

    all = [last | values]
    if Enum.any?(all, &(&1 == [])), do: :error, else: {:ok, length(all)}
  end

  # The columns an insert lists: `nil` for none, and the tokens after them. A parenthesis
  # that opens a query is the source, not a list.
  @spec column_list([token()]) :: {:ok, [binary()] | nil, [token()]} | {:refuse, binary()}
  defp column_list([{:symbol, "(", _u, _l, _c}, {:word, _p, word, _l2, _c2} | _rest] = source)
       when word in @sources,
       do: {:ok, nil, source}

  defp column_list([{:symbol, "(", _u, _l, _c} | rest]) do
    case Enum.split_while(rest, &(not match?({:symbol, ")", _u, _l, _c}, &1))) do
      {inside, [_close | source]} -> columns_inside(inside, source)
      {_inside, []} -> {:refuse, "an unclosed column list"}
    end
  end

  defp column_list(source), do: {:ok, nil, source}

  # `(a, b)`: bare words, as the table names them (in lower case).
  @spec columns_inside([token()], [token()]) ::
          {:ok, [binary()], [token()]} | {:refuse, binary()}
  defp columns_inside(inside, source) do
    names = for {:word, printed, _upper, _l, _c} <- inside, do: String.downcase(printed)
    commas = Enum.count(inside, &match?({:symbol, ",", _u, _l, _c}, &1))

    if names != [] and length(names) + commas == length(inside) and commas == length(names) - 1,
      do: {:ok, names, source},
      else: {:refuse, "a column list of anything but bare names"}
  end

  # What the parser says of the text after the table and its column list.
  @spec source_read([token()], token()) :: :ok | {:error, SQLError.t()} | {:refuse, binary()}
  defp source_read([], stop), do: {:error, SQLDdl.expected(@query_body, stop)}

  defp source_read([{:word, _p, "VALUES", _l, _c}], stop),
    do: {:error, SQLDdl.expected("(", stop)}

  # A comma that nothing follows wants another row.
  defp source_read([{:word, _p, "VALUES", _l, _c} | rows], stop) do
    case List.last(rows) do
      {:symbol, ",", _u, _l2, _c2} -> {:error, SQLDdl.expected("(", stop)}
      _row -> :ok
    end
  end

  defp source_read([{:word, _p, upper, _l, _c} | _rest], _stop) when upper in @sources, do: :ok
  defp source_read([{:symbol, "(", _u, _l, _c} | _rest], _stop), do: :ok

  defp source_read([{:word, _p, "DEFAULT", _l, _c}, {:word, _p2, "VALUES", _l2, _c2}], _stop),
    do: {:error, SQLError.planning("Inserts without a source not supported")}

  defp source_read([{kind, _printed, _u, _l, _c} = token | _rest], _stop)
       when kind in [:word, :number, :string],
       do: {:error, SQLDdl.expected(@query_body, token)}

  defp source_read(_tokens, _stop),
    do: {:refuse, "an insert whose source the double does not read"}

  # A `RETURNING` clause is refused whether the table is there or not.
  @spec source_error([token()]) :: map() | nil
  defp source_error(source) do
    if Enum.any?(source, &match?({:word, _p, "RETURNING", _l, _c}, &1)),
      do: SQLError.planning("Insert-returning clause not supported")
  end

  # ---------------------------------------------------------------------------
  # UPDATE
  # ---------------------------------------------------------------------------

  # What the planner does with `UPDATE table [alias] SET target = operand, ... [WHERE operand]`
  # (verified against InfluxDB 3 Core, in this order):
  #
  #   1. the parser reads the statement (`SQLDmlExpr`); a `RETURNING` clause and then a `LIMIT`
  #      clause are refused, before the table is looked up
  #   2. the table is looked up (a name of more than three parts is an error of its own)
  #   3. every target is checked, in order, against the table's columns by its last name
  #      (`a.b.c.d.n` assigns `n`), spelled exactly as written: `USAGE` is not `usage`. The
  #      fields it lists are qualified by the table as written, not by the alias
  #   4. the `WHERE` is planned (`SQLDmlOperand`)
  #   5. the value of each column that is assigned, in the order of the table's columns (the last
  #      of two assignments to a column wins) is planned, and converted to the column's type
  #
  # and then `DML not supported: Update`.

  @spec update([token()], token(), [binary()], env()) :: SQLError.t() | map()
  defp update(
         [{:word, _p, "OR", _l, _c}, {:word, _p2, conflict, _l2, _c2} | rest],
         stop,
         tables,
         env
       )
       when conflict in ~w(REPLACE IGNORE ABORT ROLLBACK FAIL),
       do: update(rest, stop, tables, env, true)

  defp update(tokens, stop, tables, env), do: update(tokens, stop, tables, env, false)

  @spec update([token()], token(), [binary()], env(), boolean()) :: SQLError.t() | map()
  defp update(tokens, stop, tables, env, conflict?) do
    with {:ok, reference, rest} <- reference(tokens),
         {:ok, clauses} <- SQLDmlExpr.clauses(rest ++ [stop]) do
      cond do
        clauses.returning -> SQLError.planning("Update-returning clause not yet supported")
        conflict? -> SQLError.planning("ON conflict not supported")
        clauses.limit -> limit_error()
        true -> updated(reference, clauses, tables, env)
      end
    else
      {:error, error} -> error
      {:refuse, why} -> not_modelled(:update, why)
    end
  end

  @spec limit_error() :: map()
  defp limit_error,
    do: %{status: 405, body: "This feature is not implemented: Update-limit clause not supported"}

  @spec updated([binary()], SQLDmlExpr.clauses(), [binary()], env()) :: SQLError.t() | map()
  defp updated(reference, clauses, tables, env) do
    case resolve(reference, tables) do
      {:ok, {:missing, name}} ->
        not_found(name)

      {:ok, {:found, table}} ->
        cond do
          table not in tables -> not_found(table)
          clauses.from -> not_modelled(:update, "an update with a FROM clause")
          true -> updated_table(table, reference, clauses, env)
        end

      {:error, error} ->
        error

      {:refuse, why} ->
        not_modelled(:update, why)
    end
  end

  @spec updated_table(binary(), [binary()], SQLDmlExpr.clauses(), env()) :: SQLError.t() | map()
  defp updated_table(table, reference, clauses, env) do
    columns = env.columns_of.(table)
    relation = if clauses.alias, do: [clauses.alias], else: reference

    ctx = %{
      table: table,
      columns: columns,
      types: Map.new(env.columns_of.({:types, table})),
      relation: relation,
      relation_text: Enum.map_join(relation, ".", &SQLDmlName.quote_name/1),
      planner: env.planner
    }

    with :ok <- targets(clauses.assignments, reference, columns),
         :ok <- where(clauses.where, ctx),
         :ok <- values(clauses.assignments, ctx) do
      dml(:update)
    else
      {:error, error} -> error
      {:refuse, why} -> not_modelled(:update, why)
    end
  end

  # The target of each assignment, by the last name it is written with.
  @spec targets([{[SQLDmlExpr.name()] | :tuple, SQLDmlExpr.ast()}], [binary()], [binary()]) ::
          SQLDmlOperand.check()
  defp targets(assignments, reference, columns) do
    qualifier = Enum.map_join(reference, ".", &SQLDmlName.quote_name/1)

    Enum.reduce_while(assignments, :ok, fn
      {:tuple, _value}, :ok ->
        {:halt, {:error, SQLError.planning("Tuples are not supported")}}

      {names, _value}, :ok ->
        {name, _quoted} = List.last(names)

        if name in columns,
          do: {:cont, :ok},
          else: {:halt, {:error, no_target(name, qualifier, columns)}}
    end)
  end

  @spec no_target(binary(), binary(), [binary()]) :: map()
  defp no_target(name, qualifier, columns),
    do: SQLDmlName.no_field(SQLDmlName.quote_ident(name), name, qualifier, columns)

  @spec where(SQLDmlExpr.ast() | nil, SQLDmlOperand.ctx()) :: SQLDmlOperand.check()
  defp where(nil, _ctx), do: :ok

  defp where(predicate, ctx) do
    with :ok <- SQLDmlOperand.eager(predicate, ctx),
         :ok <- SQLDmlOperand.lazy(predicate, ctx),
         do: SQLDmlOperand.predicate(predicate, ctx)
  end

  # The value assigned to each column, in the order of the table's columns.
  @spec values([{[SQLDmlExpr.name()] | :tuple, SQLDmlExpr.ast()}], SQLDmlOperand.ctx()) ::
          SQLDmlOperand.check()
  defp values(assignments, ctx) do
    assigned =
      Map.new(assignments, fn {names, value} -> {names |> List.last() |> elem(0), value} end)

    columns = Enum.filter(ctx.columns, &is_map_key(assigned, &1))

    columns
    |> Enum.reduce_while(:ok, fn column, :ok ->
      value = Map.fetch!(assigned, column)

      with :ok <- SQLDmlOperand.eager(value, ctx),
           :ok <- SQLDmlOperand.lazy(value, ctx),
           :ok <- SQLDmlOperand.value(value, column, ctx) do
        {:cont, :ok}
      else
        failure -> {:halt, failure}
      end
    end)
    |> case do
      :ok -> deep_values(columns, assigned, ctx)
      failure -> failure
    end
  end

  # What typing the top of each value did not reach, as the projection of the update finds it.
  @spec deep_values([binary()], map(), SQLDmlOperand.ctx()) :: SQLDmlOperand.check()
  defp deep_values(columns, assigned, ctx) do
    Enum.reduce_while(columns, :ok, fn column, :ok ->
      case SQLDmlOperand.deep(Map.fetch!(assigned, column), ctx) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # The table
  # ---------------------------------------------------------------------------

  # A table name: one to three parts, each a word (read in lower case), a quoted name or a
  # string.
  @spec reference([token()]) :: {:ok, [binary()], [token()]} | {:refuse, binary()}
  defp reference([{kind, printed, _u, _l, _c} | rest]) when kind in [:word, :quoted, :string] do
    part = part(kind, printed)

    case rest do
      [{:symbol, ".", _u2, _l2, _c2} | more] ->
        with {:ok, parts, rest} <- reference(more), do: {:ok, [part | parts], rest}

      _end_of_name ->
        {:ok, [part], rest}
    end
  end

  defp reference(_tokens), do: {:refuse, "that spelling"}

  @spec part(atom(), binary()) :: binary()
  defp part(:word, printed), do: String.downcase(printed)

  defp part(:quoted, printed),
    do: printed |> String.slice(1..-2//1) |> String.replace("\"\"", "\"")

  defp part(:string, printed), do: printed |> String.slice(1..-2//1) |> String.replace("''", "'")

  # Where the name points: a table of the database (`iox` is its schema), or one that cannot be
  # there. The planner prints the name it looked for with its catalog and schema.
  @spec resolve([binary()], [binary()]) ::
          {:ok, {:found, binary()} | {:missing, binary()}}
          | {:error, SQLError.t()}
          | {:refuse, binary()}
  defp resolve([table], _tables), do: {:ok, {:found, table}}
  defp resolve(["iox", table], _tables), do: {:ok, {:found, table}}
  defp resolve(["public", "iox", table], _tables), do: {:ok, {:found, table}}

  defp resolve([schema, table], _tables) when schema not in ["information_schema", "system"],
    do: {:ok, {:missing, "public.#{schema}.#{table}"}}

  defp resolve([catalog, schema, table], _tables) when catalog != "public",
    do: {:ok, {:missing, "#{catalog}.#{schema}.#{table}"}}

  defp resolve(parts, _tables) when length(parts) > 3 do
    {:error,
     SQLError.planning(
       "Unsupported compound identifier '#{Enum.join(parts, ".")}'. " <>
         "Expected 1, 2 or 3 parts, got #{length(parts)}"
     )}
  end

  defp resolve(_parts, _tables),
    do: {:refuse, "a table named in a schema the double does not model"}

  # ---------------------------------------------------------------------------
  # The answers
  # ---------------------------------------------------------------------------

  # The columns an insert lists must be the table's.
  @spec unknown_column([binary()], [binary()]) :: map() | nil
  defp unknown_column(named, columns) do
    case Enum.find(named, &(&1 not in columns)) do
      nil -> nil
      unknown -> SQLDmlName.no_field(unknown, unknown, nil, columns)
    end
  end

  @spec dml(:insert | :update) :: map()
  defp dml(:insert), do: SQLError.planning("DML not supported: Insert Into")
  defp dml(:update), do: SQLError.planning("DML not supported: Update")

  # A table the planner did not find: a name of the database's schema is printed with it.
  @spec not_found(binary()) :: map()
  defp not_found(name) do
    if String.contains?(name, "."),
      do: SQLError.planning("table '#{name}' not found"),
      else: SQLError.planning("table 'public.iox.#{name}' not found")
  end

  @spec not_modelled(:insert | :update, binary()) :: SQLError.t()
  defp not_modelled(kind, why) do
    SQLError.refusal(
      "#{kind |> Atom.to_string() |> String.upcase()} with #{why}: the engine's answer for it " <>
        "is not modelled"
    )
  end
end
