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
  #   * `UPDATE name [[AS] alias] SET ...` over a table that is not there; over one that is,
  #     when every column the statement reads is one it has
  #   * the parser's own errors for a statement that stops short (`UPDATE name`,
  #     `INSERT INTO name (a)`, `INSERT INTO name VALUES`) or goes on with a word it does
  #     not read
  #
  # The schema of the name decides little: `iox` is the database, any other schema has no
  # table.

  alias InfluxElixir.Client.Local.{SQLDdl, SQLError, SQLTokenizer}

  @sources ~w(VALUES SELECT WITH)
  @update_words ~w(SET WHERE AND OR NOT NULL TRUE FALSE IS IN BETWEEN LIKE ILIKE AS)
  @query_body "SELECT, VALUES, or a subquery in the query body"

  @typep token :: SQLTokenizer.token()
  @typep columns_of :: (binary() -> [binary()])

  @doc """
  The planner's error for an `INSERT` or an `UPDATE`, given the names of the database's
  tables and a function giving a table's columns (sorted, `time` among them), or a refusal
  by name for a shape that was not verified.
  """
  @spec error(:insert | :update, binary(), [binary()], columns_of()) :: SQLError.t() | map()
  def error(kind, statement, tables, columns_of) do
    case SQLTokenizer.tokenize(statement) do
      {:ok, tokens} -> answer(kind, split_end(tokens), tables, columns_of)
      :bail -> not_modelled(kind, "a statement the tokenizer does not read")
    end
  end

  # The statement's tokens and the token that ends it (its `;`, or the end of the text).
  @spec split_end([token()]) :: {[token()], token()}
  defp split_end(tokens) do
    case Enum.reverse(tokens) do
      [_eof, {:symbol, ";", _u, _l, _c} = semicolon | before] -> {Enum.reverse(before), semicolon}
      [eof | before] -> {Enum.reverse(before), eof}
    end
  end

  @spec answer(:insert | :update, {[token()], token()}, [binary()], columns_of()) ::
          SQLError.t() | map()
  defp answer(:insert, {[_insert, {:word, _p, "INTO", _l, _c} | rest], stop}, tables, cols),
    do: insert(rest, stop, tables, cols)

  defp answer(:insert, {[_insert | rest], stop}, tables, cols),
    do: insert(rest, stop, tables, cols)

  defp answer(:update, {[_update | rest], stop}, tables, cols),
    do: update(rest, stop, tables, cols)

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
    cond do
      error = source_error(source) -> error
      table not in tables -> not_found(table)
      listed == nil -> inserted_values(table, source, columns_of.(table))
      true -> known_columns(listed, columns_of.(table))
    end
  end

  # An insert with no column list is read by the length of its rows.
  @spec inserted_values(binary(), [token()], [binary()]) :: SQLError.t() | map()
  defp inserted_values(_table, [{:word, _p, "VALUES", _l, _c} | rows], columns) do
    case row_lengths(rows) do
      {:ok, lengths} ->
        case Enum.find_index(lengths, &(&1 != length(columns))) do
          nil ->
            dml(:insert)

          row ->
            SQLError.planning(
              "Inconsistent data length across values list: got #{Enum.at(lengths, row)} " <>
                "values in row #{row} but expected #{length(columns)}"
            )
        end

      :error ->
        not_modelled(
          :insert,
          "values that are not numbers or strings into a table with no column list"
        )
    end
  end

  defp inserted_values(_table, _source, _columns),
    do: not_modelled(:insert, "no column list over a query into a table")

  # The number of values of each `VALUES` row, when every value is a number.
  @spec row_lengths([token()]) :: {:ok, [pos_integer()]} | :error
  defp row_lengths(tokens), do: row_lengths(tokens, [])

  defp row_lengths([], found), do: {:ok, Enum.reverse(found)}

  defp row_lengths([{:symbol, "(", _u, _l, _c} | rest], found) do
    case Enum.split_while(rest, &(not match?({:symbol, ")", _u, _l, _c}, &1))) do
      {inside, [_close | more]} -> row(inside, more, found)
      {_inside, []} -> :error
    end
  end

  defp row_lengths(_tokens, _found), do: :error

  @spec row([token()], [token()], [pos_integer()]) :: {:ok, [pos_integer()]} | :error
  defp row(inside, more, found) do
    values = Enum.reject(inside, &match?({:symbol, ",", _u, _l, _c}, &1))

    if inside != [] and Enum.all?(values, &(elem(&1, 0) in [:number, :string])) and
         length(inside) == 2 * length(values) - 1 do
      case more do
        [{:symbol, ",", _u, _l, _c} | next] -> row_lengths(next, [length(values) | found])
        [] -> row_lengths([], [length(values) | found])
        _other -> :error
      end
    else
      :error
    end
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

  @spec update([token()], token(), [binary()], columns_of()) :: SQLError.t() | map()
  defp update(tokens, stop, tables, columns_of) do
    with {:ok, reference, rest} <- reference(tokens),
         {:ok, alias_name, rest} <- alias_name(rest, stop),
         {:ok, assignments} <- set(rest, stop),
         {:ok, table} <- resolve(reference, tables) do
      updated(table, alias_name, assignments, tables, columns_of)
    else
      {:error, error} -> error
      {:refuse, why} -> not_modelled(:update, why)
    end
  end

  # `[AS] alias` before `SET`.
  @spec alias_name([token()], token()) ::
          {:ok, binary() | nil, [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp alias_name([{:word, _p, "SET", _l, _c} | _rest] = tokens, _stop), do: {:ok, nil, tokens}

  defp alias_name([{:word, _p, "AS", _l, _c}, {:word, printed, _u, _l2, _c2} | rest], _stop),
    do: {:ok, String.downcase(printed), rest}

  defp alias_name([{:word, printed, _u, _l, _c} | rest], _stop),
    do: {:ok, String.downcase(printed), rest}

  defp alias_name([token | _rest], _stop), do: {:error, SQLDdl.expected("SET", token)}
  defp alias_name([], stop), do: {:error, SQLDdl.expected("SET", stop)}

  @spec set([token()], token()) :: {:ok, [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp set([{:word, _p, "SET", _l, _c}], stop), do: {:error, SQLDdl.expected("identifier", stop)}
  defp set([{:word, _p, "SET", _l, _c} | assignments], _stop), do: {:ok, assignments}
  defp set([token | _rest], _stop), do: {:error, SQLDdl.expected("SET", token)}
  defp set([], stop), do: {:error, SQLDdl.expected("SET", stop)}

  @spec updated(
          {:found, binary()} | {:missing, binary()},
          binary() | nil,
          [token()],
          [binary()],
          columns_of()
        ) :: SQLError.t() | map()
  defp updated({:missing, name}, _alias, _assignments, _tables, _columns_of), do: not_found(name)

  defp updated({:found, table}, alias_name, assignments, tables, columns_of) do
    if table in tables,
      do: updated_columns(table, alias_name, assignments, columns_of.(table)),
      else: not_found(table)
  end

  # An update of a table that is there: the columns it assigns and the words it reads must be
  # the table's. An assignment's target is its last name (`main.v` and `zzz.v` assign `v`).
  @spec updated_columns(binary(), binary() | nil, [token()], [binary()]) :: SQLError.t() | map()
  defp updated_columns(table, alias_name, assignments, columns) do
    qualifiers = Enum.reject([table, alias_name], &is_nil/1)
    {set_part, where_part} = split_where(assignments)

    with :ok <- plain_names(assignments),
         {:ok, targets, values} <- targets(set_part),
         {:ok, read} <- reads(values ++ where_part, qualifiers) do
      unknown = Enum.find(targets ++ read, fn {name, _qualified} -> name not in columns end)

      case unknown do
        nil -> dml(:update)
        {name, false} when alias_name == nil -> no_field(name, table, columns)
        _qualified_or_aliased -> not_modelled(:update, "a column the table lacks, through a name")
      end
    else
      {:refuse, why} -> not_modelled(:update, why)
    end
  end

  @spec plain_names([token()]) :: :ok | {:refuse, binary()}
  defp plain_names(tokens) do
    if Enum.any?(tokens, &(elem(&1, 0) in [:quoted, :placeholder])),
      do: {:refuse, "an update naming a quoted column"},
      else: :ok
  end

  # The tokens before a top-level `WHERE` and after it.
  @spec split_where([token()]) :: {[token()], [token()]}
  defp split_where(tokens), do: split_where(tokens, 0, [])

  defp split_where([], _depth, before), do: {Enum.reverse(before), []}

  defp split_where([{:word, _p, "WHERE", _l, _c} | rest], 0, before),
    do: {Enum.reverse(before), rest}

  defp split_where([{:symbol, "(", _u, _l, _c} = token | rest], depth, before),
    do: split_where(rest, depth + 1, [token | before])

  defp split_where([{:symbol, ")", _u, _l, _c} = token | rest], depth, before),
    do: split_where(rest, max(depth - 1, 0), [token | before])

  defp split_where([token | rest], depth, before), do: split_where(rest, depth, [token | before])

  # `target = value, target = value`: the target columns (their last name) and the value tokens.
  @spec targets([token()]) ::
          {:ok, [{binary(), boolean()}], [token()]} | {:refuse, binary()}
  defp targets(tokens), do: targets(split_assignments(tokens, 0, [], []), [], [])

  defp targets([], names, values), do: {:ok, Enum.reverse(names), values}

  defp targets([assignment | rest], names, values) do
    case Enum.split_while(assignment, &(not match?({:symbol, "=", _u, _l, _c}, &1))) do
      {target, [_equals | value]} ->
        case Enum.reverse(target) do
          [{:word, printed, _u, _l, _c} | _before] ->
            targets(rest, [{String.downcase(printed), false} | names], values ++ value)

          _other ->
            {:refuse, "an assignment to anything but a column"}
        end

      {_target, []} ->
        {:refuse, "an assignment with no value"}
    end
  end

  # Assignments are separated by the commas outside any parenthesis.
  @spec split_assignments([token()], non_neg_integer(), [token()], [[token()]]) :: [[token()]]
  defp split_assignments([], _depth, [], found), do: Enum.reverse(found)

  defp split_assignments([], _depth, current, found),
    do: Enum.reverse([Enum.reverse(current) | found])

  defp split_assignments([{:symbol, ",", _u, _l, _c} | rest], 0, current, found),
    do: split_assignments(rest, 0, [], [Enum.reverse(current) | found])

  defp split_assignments([{:symbol, "(", _u, _l, _c} = token | rest], depth, current, found),
    do: split_assignments(rest, depth + 1, [token | current], found)

  defp split_assignments([{:symbol, ")", _u, _l, _c} = token | rest], depth, current, found),
    do: split_assignments(rest, max(depth - 1, 0), [token | current], found)

  defp split_assignments([token | rest], depth, current, found),
    do: split_assignments(rest, depth, [token | current], found)

  # The columns an expression reads, each with whether it was written through a relation: a
  # name before a `.` is that relation, which must be the table or its alias.
  @spec reads([token()], [binary()]) ::
          {:ok, [{binary(), boolean()}]} | {:refuse, binary()}
  defp reads(tokens, qualifiers) do
    following = Enum.drop(tokens, 1) ++ [nil]
    previous = [nil | tokens]

    Enum.zip([tokens, following, previous])
    |> Enum.reduce_while({:ok, []}, fn {token, next, before}, {:ok, found} ->
      case read(token, next, before, qualifiers) do
        :skip -> {:cont, {:ok, found}}
        {:column, name} -> {:cont, {:ok, [name | found]}}
        {:refuse, why} -> {:halt, {:refuse, why}}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.reverse(found)}
      refusal -> refusal
    end
  end

  @spec read(token(), token() | nil, token() | nil, [binary()]) ::
          :skip | {:column, {binary(), boolean()}} | {:refuse, binary()}
  defp read({:word, printed, upper, _l, _c}, next, before, qualifiers) do
    name = String.downcase(printed)
    dotted_before? = match?({:symbol, ".", _u, _l2, _c2}, before)

    cond do
      match?({:symbol, "(", _u, _l2, _c2}, next) -> :skip
      match?({:symbol, ".", _u, _l2, _c2}, next) -> relation(name, qualifiers)
      dotted_before? -> {:column, {name, true}}
      upper in @update_words -> :skip
      true -> {:column, {name, false}}
    end
  end

  defp read(_token, _next, _before, _qualifiers), do: :skip

  @spec relation(binary(), [binary()]) :: :skip | {:refuse, binary()}
  defp relation(name, qualifiers) do
    if name in qualifiers,
      do: :skip,
      else: {:refuse, "a column read through a relation that is not the table"}
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
          {:ok, {:found, binary()} | {:missing, binary()}} | {:refuse, binary()}
  defp resolve([table], _tables), do: {:ok, {:found, table}}
  defp resolve(["iox", table], _tables), do: {:ok, {:found, table}}
  defp resolve(["public", "iox", table], _tables), do: {:ok, {:found, table}}

  defp resolve([schema, table], _tables) when schema not in ["information_schema", "system"],
    do: {:ok, {:missing, "public.#{schema}.#{table}"}}

  defp resolve([catalog, schema, table], _tables) when catalog != "public",
    do: {:ok, {:missing, "#{catalog}.#{schema}.#{table}"}}

  defp resolve(_parts, _tables),
    do: {:refuse, "a table named in a schema the double does not model"}

  # ---------------------------------------------------------------------------
  # The answers
  # ---------------------------------------------------------------------------

  # The columns an insert lists must be the table's.
  @spec known_columns([binary()], [binary()]) :: SQLError.t() | map()
  defp known_columns(named, columns) do
    case Enum.find(named, &(&1 not in columns)) do
      nil -> dml(:insert)
      unknown -> no_field(unknown, nil, columns)
    end
  end

  @spec dml(:insert | :update) :: map()
  defp dml(:insert), do: SQLError.planning("DML not supported: Insert Into")
  defp dml(:update), do: SQLError.planning("DML not supported: Update")

  # An update names the fields with their table (`main.v`), an insert without (verified).
  @spec no_field(binary(), binary() | nil, [binary()]) :: map()
  defp no_field(name, table, columns) do
    valid = Enum.map_join(columns, ", ", &if(table, do: "#{table}.#{&1}", else: &1))

    %{status: 500, body: "Schema error: No field named #{name}. Valid fields are #{valid}."}
  end

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
