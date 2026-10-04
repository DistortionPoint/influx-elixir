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
  #   * `UPDATE name [[AS] alias] SET column = operand [, ...] [WHERE operand = operand]`
  #     (an operand is a number, a string, a name, or `abs` of a number or a numeric column)
  #     over a table that is not there; over one that is, when every column the statement
  #     reads is one it has. Any other update (a subquery, `CASE`, `CAST`, an operator, a
  #     clause after the assignments) is refused by name
  #   * the parser's own errors for a statement that stops short (`UPDATE name`,
  #     `INSERT INTO name (a)`, `INSERT INTO name VALUES`) or goes on with a word it does
  #     not read
  #
  # The schema of the name decides little: `iox` is the database, any other schema has no
  # table.

  alias InfluxElixir.Client.Local.{SQLDdl, SQLError, SQLTokenizer}

  @sources ~w(VALUES SELECT WITH)
  # Words the update's shape never reads as a name or a function (the double has not seen
  # what the engine makes of one there).
  @reserved ~w(SET WHERE AND OR NOT NULL TRUE FALSE IS IN BETWEEN LIKE ILIKE AS SELECT FROM CASE
               WHEN THEN ELSE END CAST TRY_CAST INTERVAL RETURNING LIMIT OFFSET ORDER GROUP BY
               HAVING FOR UNION EXCEPT INTERSECT JOIN ON USING WITH VALUES DISTINCT ALL ANY SOME
               EXISTS DEFAULT UPDATE INSERT DELETE INTO CROSS INNER LEFT RIGHT FULL NATURAL
               OUTER LATERAL WINDOW OVER FILTER ESCAPE SIMILAR ASC DESC NULLS TABLE ARRAY ROW
               UNNEST CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP EXTRACT
               POSITION SUBSTRING TRIM OVERLAY COLLATE AT ZONE)

  @typep assigned :: {[binary()], [read()]}
  @typep read :: [binary()] | {:numeric, [binary()]}
  @query_body "SELECT, VALUES, or a subquery in the query body"

  @typep token :: SQLTokenizer.token()
  @typep columns_of :: (binary() | {:numeric, binary()} -> [binary()])

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
         {:ok, assigned} <- assigned(assignments),
         {:ok, table} <- resolve(reference, tables) do
      updated(table, alias_name, assigned, tables, columns_of)
    else
      {:error, error} -> error
      {:refuse, why} -> not_modelled(:update, why)
    end
  end

  # `[AS] alias` before `SET`.
  @spec alias_name([token()], token()) ::
          {:ok, binary() | nil, [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp alias_name([{:word, _p, "SET", _l, _c} | _rest] = tokens, _stop), do: {:ok, nil, tokens}

  defp alias_name([{:word, _p, "AS", _l, _c}, {:word, printed, upper, _l2, _c2} | rest], _stop)
       when upper not in @reserved,
       do: {:ok, String.downcase(printed), rest}

  defp alias_name([{:word, printed, upper, _l, _c} | rest], _stop) when upper not in @reserved,
    do: {:ok, String.downcase(printed), rest}

  defp alias_name([{:word, _p, _upper, _l, _c} | _rest], _stop),
    do: {:refuse, "an alias that is one of SQL's own words"}

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
          assigned(),
          [binary()],
          columns_of()
        ) :: SQLError.t() | map()
  defp updated({:missing, name}, _alias, _assigned, _tables, _columns_of), do: not_found(name)

  defp updated({:found, table}, alias_name, assigned, tables, columns_of) do
    if table in tables,
      do: updated_columns(table, alias_name, assigned, columns_of),
      else: not_found(table)
  end

  # An update of a table that is there: the columns it assigns and the names it reads must
  # be the table's. An assignment's target is its last name (`main.v` and `zzz.v` assign `v`).
  @spec updated_columns(binary(), binary() | nil, assigned(), columns_of()) ::
          SQLError.t() | map()
  defp updated_columns(table, alias_name, {targets, reads}, columns_of) do
    qualifiers = Enum.reject([table, alias_name], &is_nil/1)

    case read_columns(reads, qualifiers) do
      {:ok, read} -> unknown_column(read, targets, table, alias_name, columns_of)
      {:refuse, why} -> not_modelled(:update, why)
    end
  end

  @spec unknown_column(
          [{binary(), boolean(), boolean()}],
          [binary()],
          binary(),
          binary() | nil,
          columns_of()
        ) :: SQLError.t() | map()
  defp unknown_column(read, targets, table, alias_name, columns_of) do
    columns = columns_of.(table)

    unknown =
      Enum.find(Enum.map(targets, &{&1, false, false}) ++ read, fn {name, _qualified, _num} ->
        name not in columns
      end)

    case unknown do
      nil -> numbers(read, table, columns_of)
      {name, false, _num} when alias_name == nil -> no_field(name, table, columns)
      _qualified_or_aliased -> not_modelled(:update, "a column the table lacks, through a name")
    end
  end

  # `abs` is verified on a number; of a column that is not one the engine says so in words
  # the double has not read.
  @spec numbers([{binary(), boolean(), boolean()}], binary(), columns_of()) ::
          SQLError.t() | map()
  defp numbers(read, table, columns_of) do
    numeric = columns_of.({:numeric, table})

    if Enum.all?(read, fn {name, _qualified, must} -> not must or name in numeric end),
      do: dml(:update),
      else: not_modelled(:update, "abs of a column that is not a number")
  end

  defp read_parts({:numeric, parts}), do: parts
  defp read_parts(parts), do: parts

  defp numeric?({:numeric, _parts}), do: true
  defp numeric?(_parts), do: false

  # The columns a statement reads, each with whether it was written through a relation: a
  # name before a `.` is that relation, which must be the table or its alias.
  @spec read_columns([read()], [binary()]) ::
          {:ok, [{binary(), boolean(), boolean()}]} | {:refuse, binary()}
  defp read_columns(reads, qualifiers) do
    Enum.reduce_while(reads, {:ok, []}, fn read, {:ok, found} ->
      {relations, [name]} = read |> read_parts() |> Enum.split(-1)

      if Enum.all?(relations, &(&1 in qualifiers)),
        do: {:cont, {:ok, [{name, relations != [], numeric?(read)} | found]}},
        else: {:halt, {:refuse, "a column read through a relation that is not the table"}}
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.reverse(found)}
      refusal -> refusal
    end
  end

  # The assignments of an update, of the one shape that was verified:
  #
  #     name[.name[.name]] = operand [, ...] [WHERE operand = operand]
  #
  # where an operand is a number, a string, a name of up to three parts, or a call of a
  # function on such operands. Anything else (a subquery, `CASE`, `CAST`, `::`, an
  # interval, an operator, `FROM`, `RETURNING`, a clause after the `WHERE`) is refused by
  # name: it was not verified, and a word the shape does not read is not a column.
  @spec assigned([token()]) :: {:ok, assigned()} | {:refuse, binary()}
  defp assigned(tokens), do: assignments(tokens, [], [])

  @spec assignments([token()], [binary()], [read()]) ::
          {:ok, assigned()} | {:refuse, binary()}
  defp assignments(tokens, targets, reads) do
    with {:ok, target, rest} <- name_parts(tokens),
         [{:symbol, "=", _u, _l, _c} | rest] <- rest,
         {:ok, found, rest} <- operand(rest) do
      targets = [List.last(target) | targets]
      reads = Enum.reverse(found, reads)

      case rest do
        [] -> {:ok, {Enum.reverse(targets), Enum.reverse(reads)}}
        [{:symbol, ",", _u, _l, _c} | more] -> assignments(more, targets, reads)
        [{:word, _p, "WHERE", _l, _c} | condition] -> where(condition, targets, reads)
        _other -> {:refuse, "an update with more than assignments and one equality"}
      end
    else
      {:refuse, _why} = refusal -> refusal
      _other -> {:refuse, "an assignment of anything but `column = operand`"}
    end
  end

  @spec where([token()], [binary()], [read()]) :: {:ok, assigned()} | {:refuse, binary()}
  defp where(tokens, targets, reads) do
    with {:ok, left, rest} <- operand(tokens),
         [{:symbol, "=", _u, _l, _c} | rest] <- rest,
         {:ok, right, []} <- operand(rest) do
      {:ok, {Enum.reverse(targets), Enum.reverse(reads, left ++ right)}}
    else
      {:refuse, _why} = refusal -> refusal
      _other -> {:refuse, "a WHERE of anything but one equality of operands"}
    end
  end

  # An operand: the names it reads (each as its parts), and the tokens after it.
  @spec operand([token()]) ::
          {:ok, [read()], [token()]} | {:refuse, binary()}
  defp operand([{kind, _p, _u, _l, _c} | rest]) when kind in [:number, :string],
    do: {:ok, [], rest}

  # The one call that was verified: `abs` of a number, or of a column (which must be a number).
  defp operand([{:word, _p, "ABS", _l, _c}, {:symbol, "(", _u, _l2, _c2} | rest]) do
    case rest do
      [{:number, _p2, _u2, _l3, _c3}, {:symbol, ")", _u3, _l4, _c4} | more] ->
        {:ok, [], more}

      _name ->
        case name_parts(rest) do
          {:ok, parts, [{:symbol, ")", _u2, _l3, _c3} | more]} -> {:ok, [{:numeric, parts}], more}
          _other -> {:refuse, "abs of anything but a number or a column"}
        end
    end
  end

  defp operand([{:word, _p, _upper, _l, _c}, {:symbol, "(", _u, _l2, _c2} | _rest]),
    do: {:refuse, "a call of a function other than abs"}

  defp operand(tokens) do
    with {:ok, parts, rest} <- name_parts(tokens), do: {:ok, [parts], rest}
  end

  # `name`, `name.name` or `name.name.name`: bare words that are not SQL's own.
  @spec name_parts([token()]) :: {:ok, [binary()], [token()]} | {:refuse, binary()}
  defp name_parts([{:word, printed, upper, _l, _c} | rest]) when upper not in @reserved do
    part = String.downcase(printed)

    case rest do
      [{:symbol, ".", _u, _l2, _c2} | more] ->
        with {:ok, parts, rest} <- name_parts(more),
             true <- length(parts) < 3 do
          {:ok, [part | parts], rest}
        else
          _other -> {:refuse, "a name of more than three parts"}
        end

      _end_of_name ->
        {:ok, [part], rest}
    end
  end

  defp name_parts(_tokens), do: {:refuse, "an update reading anything but plain names"}

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
