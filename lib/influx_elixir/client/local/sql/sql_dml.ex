defmodule InfluxElixir.Client.Local.SQLDml do
  @moduledoc false
  # The planner's answer to an `INSERT`, an `UPDATE` or a `DELETE`, which it never runs
  # (verified against InfluxDB 3 Core 3.10.1): the planner's steps are followed in their order,
  # and the answer is the first error of them, else `DML not supported: <kind>`. A statement is
  # read by the module of its kind (`SQLDmlInsert`, `SQLDmlDelete`, and `UPDATE` below); all
  # three look their table up by `SQLDmlName.lookup/2` (which is `SQLTable.locate/1`, the
  # resolver a query uses too), read their operands with `SQLDmlExpr` and plan them with
  # `SQLDmlOperand`. What the reader declines to read it asks `SQLSyntax` to read, and
  # `parse_error/1` is what `SQLSyntax` asks of it for a statement followed by another.
  #
  # The double answers the shapes it verified and refuses the rest by name:
  #
  #   * `INSERT`: see `SQLDmlInsert`
  #   * `UPDATE name [[AS] alias] SET column = operand [, ...] [WHERE operand] [RETURNING ..]
  #     [LIMIT ..]`: the parser reads it (`SQLDmlExpr`) and the planner's steps are followed
  #     in their order (see UPDATE below): the targets, the names and calls of the `WHERE`,
  #     each value's names, types and conversion to its column's type. A shape of operand
  #     that was not verified (a subquery, `CASE`, an interval, a function the double does
  #     not know) is refused by name
  #   * `DELETE`: see `SQLDmlDelete`
  #   * a leading `;` is read as the engine reads it: an empty statement before the one
  #     that follows
  #   * the parser's own errors for a statement that stops short or goes on with a word it
  #     does not read
  #
  # The schema of the name decides little: `iox` is the database, any other schema has no
  # table.

  alias InfluxElixir.Client.Local.{
    SQLDmlDelete,
    SQLDmlExpr,
    SQLDmlInsert,
    SQLDmlName,
    SQLDmlOperand,
    SQLError,
    SQLSyntax,
    SQLTable,
    SQLTokenizer
  }

  @typep token :: SQLTokenizer.token()

  @typedoc """
  Gives a table's columns (sorted, `time` among them), `{:types, table}` their Arrow types.
  """
  @type columns_of :: (binary() | {:types, binary()} -> [binary()] | [{binary(), binary()}])

  @typedoc """
  Plans an operand as a select item of the table (of no table for `nil`), the errors it has
  there.
  """
  @type planner :: (binary() | nil, binary() -> :ok | {:error, term()} | {:refuse, reason()})

  @typedoc "What a statement is planned against: the tables, their columns and the planner."
  @type env :: %{tables: [binary()], columns_of: columns_of(), planner: planner()}

  @doc """
  The planner's error for an `INSERT`, an `UPDATE` or a `DELETE`, given the names of the
  database's tables, a function giving a table's columns and a function planning an operand
  as a select item, or a refusal by name for a shape that was not verified.
  """
  @spec error(:insert | :update | :delete, binary(), [binary()], columns_of(), planner()) ::
          SQLError.t() | map()
  def error(kind, statement, tables, columns_of, planner) do
    env = %{tables: tables, columns_of: columns_of, planner: planner}

    case SQLTokenizer.tokenize(without_leading_semicolons(statement)) do
      {:ok, tokens} -> kind |> answer(split_end(tokens), env) |> or_syntax(statement)
      :bail -> not_modelled(kind, "a statement the tokenizer does not read")
    end
  end

  # What this reader declines to read, the syntax reader may (`DELETE FROM`, with no table, is the
  # parser's error): it is asked only then, as it reads the whole text again.
  @spec or_syntax(SQLError.t() | map(), binary()) :: SQLError.t() | map()
  defp or_syntax(%{body: "Client.Local: " <> _reason} = refusal, statement) do
    case SQLSyntax.check_statements(statement) do
      {:error, error} -> error
      :ok -> refusal
    end
  end

  defp or_syntax(answer, _statement), do: answer

  @doc """
  The parser's error for the tokens of an `INSERT`, an `UPDATE` or a `DELETE` (the token that
  ends the text last), `nil` when it reads them or this reader does not say. The parser reads a
  statement whole before it reads the next one of the same text, so its error for the first is
  that of the text.
  """
  @spec parse_error([token()]) :: SQLError.t() | map() | nil
  def parse_error([{:word, _p, word, _l, _c} | _rest] = tokens) do
    case parsed(split_end(tokens)) do
      {:error, %{body: "SQL error: ParserError" <> _rest} = error} -> error
      {:refuse, why} -> if SQLDmlExpr.cut_off?(why), do: not_modelled(kind_of(word), why)
      _other -> nil
    end
  end

  @spec kind_of(binary()) :: :insert | :update | :delete
  defp kind_of("INSERT"), do: :insert
  defp kind_of("UPDATE"), do: :update
  defp kind_of("DELETE"), do: :delete

  @spec parsed({[token()], token()}) :: term()
  defp parsed({[{:word, _p, "INSERT", _l, _c} | rest], stop}), do: SQLDmlInsert.parse(rest, stop)
  defp parsed({[{:word, _p, "UPDATE", _l, _c} | rest], stop}), do: parse_update(rest, stop)
  defp parsed({[{:word, _p, "DELETE", _l, _c} | rest], stop}), do: SQLDmlDelete.parse(rest, stop)

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

  @spec answer(:insert | :update | :delete, {[token()], token()}, env()) ::
          SQLError.t() | map()
  defp answer(:insert, {[_insert | rest], stop}, env), do: SQLDmlInsert.error(rest, stop, env)
  defp answer(:update, {[_update | rest], stop}, env), do: update(rest, stop, env)
  defp answer(:delete, {[_delete | rest], stop}, env), do: SQLDmlDelete.error(rest, stop, env)

  # ---------------------------------------------------------------------------
  # What the statements share
  # ---------------------------------------------------------------------------

  @doc false
  @spec dml(:insert | :update | :delete) :: map()
  def dml(:insert), do: SQLError.planning("DML not supported: Insert Into")
  def dml(:update), do: SQLError.planning("DML not supported: Update")
  def dml(:delete), do: SQLError.planning("DML not supported: Delete")

  @typedoc """
  Why a statement is refused: the words that finish "an INSERT with ...", or one of the causes
  the callers tell apart, which are tags and not words they search for in a message:
  `{:cut_off, why}` for a statement that ends (at its `;`) inside a value the double cannot read,
  and `{:unknown_function, name}` for a call of a function the double does not know.
  """
  @type reason :: binary() | {:cut_off, binary()} | {:unknown_function, binary()}

  @doc false
  @spec not_modelled(:insert | :update | :delete, reason()) :: SQLError.t()
  def not_modelled(kind, why) do
    SQLError.refusal(
      "#{kind |> Atom.to_string() |> String.upcase()} with #{reason_text(why)}: the engine's " <>
        "answer for it is not modelled"
    )
  end

  @spec reason_text(reason()) :: binary()
  defp reason_text({:cut_off, why}),
    do: "a statement that ends inside a value the double cannot read: " <> why

  defp reason_text({:unknown_function, name}),
    do: "a call to #{name}, a function the double does not know"

  defp reason_text(why), do: why

  @doc false
  @type table :: binary() | {:catalog, [SQLTable.column()]}

  @spec context(table(), [binary()], env()) :: SQLDmlOperand.ctx()
  def context(table, relation, env) do
    {columns, types} = table_schema(table, env)

    %{
      table: if(is_binary(table), do: table),
      columns: columns,
      types: types,
      relation: relation,
      relation_text: Enum.map_join(relation, ".", &SQLDmlName.quote_name/1),
      planner: if(is_binary(table), do: env.planner, else: catalog_planner(env.planner))
    }
  end

  # A table's columns in the order the engine lists them, and their Arrow types by name.
  @doc false
  @spec table_schema(table(), env()) :: {[binary()], %{binary() => binary()}}
  def table_schema({:catalog, columns}, _env),
    do:
      {Enum.map(columns, &elem(&1, 0)),
       Map.new(columns, fn {name, type, _nullable} -> {name, type} end)}

  def table_schema(table, env),
    do: {env.columns_of.(table), Map.new(env.columns_of.({:types, table}))}

  # The double has no rows for the engine's own tables: an operand over their columns is not
  # planned, and one over constants is planned as a select of none.
  @spec catalog_planner(planner()) :: planner()
  defp catalog_planner(planner) do
    fn
      _table, text ->
        if String.contains?(text, ~s|"|),
          do: {:refuse, "an operand over a column of a table of the engine"},
          else: planner.(nil, text)
    end
  end

  # What operands are read against where there is no table (the cells of a `VALUES`).
  @doc false
  @spec empty_context(env()) :: SQLDmlOperand.ctx()
  def empty_context(env) do
    %{
      table: nil,
      columns: [],
      types: %{},
      relation: [],
      relation_text: "",
      planner: env.planner
    }
  end

  # The `WHERE` of an `UPDATE` or a `DELETE`: its calls and names, then that it is a boolean.
  @doc false
  @spec where(SQLDmlExpr.ast() | nil, SQLDmlOperand.ctx()) :: SQLDmlOperand.check()
  def where(nil, _ctx), do: :ok

  def where(predicate, ctx) do
    with :ok <- SQLDmlOperand.eager(predicate, ctx),
         :ok <- SQLDmlOperand.lazy(predicate, ctx),
         do: SQLDmlOperand.predicate(predicate, ctx)
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
  @spec update([token()], token(), env()) :: SQLError.t() | map()
  defp update(tokens, stop, env) do
    with {:ok, reference, clauses, conflict?} <- parse_update(tokens, stop),
         :ok <- SQLDmlName.arity(reference) do
      cond do
        clauses.returning -> SQLError.planning("Update-returning clause not yet supported")
        conflict? -> SQLError.planning("ON conflict not supported")
        clauses.limit -> limit_error()
        true -> updated(reference, clauses, env)
      end
    else
      {:error, error} -> error
      {:refuse, why} -> not_modelled(:update, why)
    end
  end

  # What the parser reads of an `UPDATE`: the table, the clauses, and whether an `OR REPLACE`
  # (or the like) came before the table.
  @spec parse_update([token()], token()) ::
          {:ok, [binary()], SQLDmlExpr.clauses(), boolean()}
          | {:error, SQLError.t() | map()}
          | {:refuse, reason()}
  defp parse_update(
         [{:word, _p, "OR", _l, _c}, {:word, _p2, conflict, _l2, _c2} | rest],
         stop
       )
       when conflict in ~w(REPLACE IGNORE ABORT ROLLBACK FAIL),
       do: parse_update(rest, stop, true)

  defp parse_update(tokens, stop), do: parse_update(tokens, stop, false)

  defp parse_update(tokens, stop, conflict?) do
    with {:ok, reference, rest} <- SQLDmlName.reference(tokens),
         {:ok, clauses} <- SQLDmlExpr.clauses(rest ++ [stop]),
         do: {:ok, reference, clauses, conflict?}
  end

  @spec limit_error() :: map()
  defp limit_error,
    do: %{status: 405, body: "This feature is not implemented: Update-limit clause not supported"}

  @spec updated([binary()], SQLDmlExpr.clauses(), env()) :: SQLError.t() | map()
  defp updated(reference, clauses, env) do
    case SQLDmlName.lookup(reference, env.tables) do
      {:ok, _table} when clauses.function ->
        not_modelled(:update, "an update of a table function")

      {:ok, _table} when clauses.from ->
        not_modelled(:update, "an update with a FROM clause")

      {:ok, table} ->
        updated_table(table, reference, clauses, env)

      {:error, error} ->
        error
    end
  end

  @spec updated_table(table(), [binary()], SQLDmlExpr.clauses(), env()) ::
          SQLError.t() | map()
  defp updated_table(table, reference, clauses, env) do
    relation = if clauses.alias, do: [clauses.alias], else: reference
    ctx = context(table, relation, env)

    with :ok <- alias_columns(clauses.alias_columns, ctx.columns),
         :ok <- targets(clauses.assignments, reference, ctx.columns),
         :ok <- where(clauses.where, ctx),
         :ok <- values(clauses.assignments, ctx) do
      dml(:update)
    else
      {:error, error} -> error
      {:refuse, why} -> not_modelled(:update, why)
    end
  end

  # An alias that names the columns names all of them (and then renames the fields, which the
  # double does not model).
  @spec alias_columns(non_neg_integer() | nil, [binary()]) ::
          :ok | {:error, map()} | {:refuse, reason()}
  defp alias_columns(nil, _columns), do: :ok

  defp alias_columns(count, columns) when count == length(columns),
    do: {:refuse, "an alias that names the columns"}

  defp alias_columns(count, columns) do
    {:error,
     SQLError.planning(
       "Source table contains #{length(columns)} columns but only #{count} names given as " <>
         "column alias"
     )}
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
      value = Map.fetch!(assigned, column)

      with :ok <- SQLDmlOperand.deep(value, ctx), :ok <- SQLDmlOperand.late(value, ctx) do
        {:cont, :ok}
      else
        failure -> {:halt, failure}
      end
    end)
  end
end
