defmodule InfluxElixir.Client.Local.SQLDmlExpr do
  @moduledoc false
  # The parser of the part of an `UPDATE` after its table, for
  # `InfluxElixir.Client.Local.SQLDml`: an optional alias, `SET target = operand [, ...]`, and
  # the clauses `WHERE`, `RETURNING` and `LIMIT`, read as the engine's SQL parser reads them
  # (verified against InfluxDB 3 Core), so that its parse errors are the parser's own
  # (`Expected: an expression, found: )`, `Expected: end of statement, found: foo`).
  #
  # An operand is a small expression, parsed by precedence climbing with the engine's
  # precedences: literals, names of up to five parts, calls, `( )`, unary `+` `-` `NOT`, the
  # arithmetic, comparison, `AND`, `OR` and `||` operators, `IS`, `IN`, `BETWEEN`, `LIKE`,
  # `CAST` and `::`. Anything else the engine reads (a subquery, `CASE`, an interval, an
  # array, a window, a typed string, a placeholder) is a refusal by name: its answer was not
  # verified. The tree is typed and checked by `InfluxElixir.Client.Local.SQLDml`.

  alias InfluxElixir.Client.Local.{SQLDdl, SQLDmlName, SQLDmlType, SQLError, SQLTokenizer}

  @typedoc "A name written in a statement: its text (lower case when unquoted) and whether quoted."
  @type name :: {binary(), boolean()}

  @typedoc "An operand."
  @type ast ::
          {:num, binary()}
          | {:str, binary()}
          | {:bool, boolean()}
          | :null
          | :param
          | {:ref, [name()]}
          | {:call, binary(), [ast()] | :star}
          | {:neg | :pos | :not, ast()}
          | {:bin, binary(), ast(), ast()}
          | {:is, ast(), :null | true | false | :unknown | {:distinct, ast()}, boolean()}
          | {:in, ast(), [ast()], boolean()}
          | {:between, ast(), ast(), ast(), boolean()}
          | {:like, ast(), ast(), boolean(), binary(), binary() | nil}
          | {:cast, ast(), SQLDmlType.t(), boolean()}
          | {:tuple, [ast()]}

  @typedoc "The clauses of an update after its table."
  @type clauses :: %{
          alias_columns: non_neg_integer() | nil,
          function: boolean(),
          alias: binary() | nil,
          assignments: [{[name()] | :tuple, ast()}],
          from: boolean(),
          where: ast() | nil,
          returning: boolean(),
          limit: boolean()
        }

  @typep token :: SQLTokenizer.token()
  @typep parsed(t) :: {:ok, t, [token()]} | {:error, SQLError.t()} | {:refuse, binary()}

  # A word that begins no alias, so that what follows it is read as the clause it opens.
  @alias_reserved ~w(WITH SELECT WHERE GROUP ORDER UNION EXCEPT INTERSECT LIMIT OFFSET FETCH
                     VALUES HAVING ON USING SET RETURNING WINDOW QUALIFY)
  # A word that opens a join or a `FROM` where the engine reads more of the table.
  @join_words ~w(FROM JOIN INNER CROSS LEFT RIGHT FULL OUTER NATURAL)

  # Words that begin an expression the double does not read.
  @refused_words ~w(CASE EXISTS INTERVAL ARRAY ROW EXTRACT POSITION SUBSTRING TRIM OVERLAY
                    CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP
                    UNNEST MAP STRUCT LATERAL SELECT WITH VALUES FROM WHERE SET RETURNING
                    LIMIT DEFAULT ANY SOME COLLATE GROUP ORDER HAVING JOIN ON USING UNION
                    EXCEPT INTERSECT AS)
  @typed_strings ~w(DATE TIME TIMESTAMP DATETIME)
  # Words after an operand that the engine reads as an operator the double does not read.
  @refused_operators ~w(XOR DIV MOD OVERLAPS RLIKE REGEXP SIMILAR ISNULL NOTNULL AT COLLATE
                        MATCH OPERATOR)
  @call_suffixes ~w(FILTER OVER WITHIN IGNORE RESPECT)

  @comparisons ~w(= == <> != < > <= >= <=> ~ ~* !~ !~* ~~ ~~* !~~ !~~*)

  # ---------------------------------------------------------------------------
  # The clauses
  # ---------------------------------------------------------------------------

  @doc """
  The clauses of an update from the tokens after its table, the token that ends the
  statement last.
  """
  @spec clauses([token()]) :: {:ok, clauses()} | {:error, SQLError.t()} | {:refuse, binary()}
  def clauses(tokens) do
    with {:ok, function, tokens} <- table_args(tokens),
         {:ok, alias_name, alias_columns, rest} <- alias_with_columns(tokens),
         {:ok, nil, rest} <- set_next(rest),
         {:ok, assignments, rest} <- set(rest),
         {:ok, from, rest} <- from(rest),
         {:ok, where, rest} <- optional(rest, "WHERE"),
         {:ok, returning, rest} <- returning(rest),
         {:ok, limit, rest} <- limit(rest),
         :ok <- finished(rest) do
      {:ok,
       %{
         function: function,
         alias: alias_name,
         alias_columns: alias_columns,
         assignments: assignments,
         from: from,
         where: where,
         returning: returning,
         limit: limit
       }}
    end
  end

  # `[AS] alias [(column, ...)]`.
  @spec alias_name([token()]) :: parsed(binary() | nil)
  defp alias_name(tokens) do
    with {:ok, name, _columns, rest} <- alias_with_columns(tokens), do: {:ok, name, rest}
  end

  # The same, with the number of columns the alias gives names to (`nil` for none).
  @spec alias_with_columns([token()]) ::
          {:ok, binary() | nil, non_neg_integer() | nil, [token()]}
          | {:error, SQLError.t()}
          | {:refuse, binary()}
  defp alias_with_columns(tokens) do
    with {:ok, name, rest} <- alias_word(tokens), do: alias_columns(name, rest)
  end

  @spec alias_columns(binary() | nil, [token()]) ::
          {:ok, binary() | nil, non_neg_integer() | nil, [token()]} | {:error, SQLError.t()}
  defp alias_columns(name, [{:symbol, "(", _u, _l, _c} | rest]) when name != nil do
    with {:ok, count, rest} <- alias_column_list(rest, 1), do: {:ok, name, count, rest}
  end

  defp alias_columns(name, rest), do: {:ok, name, nil, rest}

  @spec alias_column_list([token()], pos_integer()) ::
          {:ok, pos_integer(), [token()]} | {:error, SQLError.t()}
  defp alias_column_list([{kind, _p, _u, _l, _c} | rest], count)
       when kind in [:word, :quoted, :string] do
    case rest do
      [{:symbol, ",", _u2, _l2, _c2} | more] -> alias_column_list(more, count + 1)
      [{:symbol, ")", _u2, _l2, _c2} | more] -> {:ok, count, more}
      [token | _more] -> {:error, SQLDdl.expected(")", token)}
    end
  end

  defp alias_column_list([token | _rest], _count),
    do: {:error, SQLDdl.expected("identifier", token)}

  @doc """
  The arguments of a table that is a function (`DELETE FROM name(args)`), read as the
  operands they are, and the tokens after them.
  """
  @spec table_args([token()]) :: parsed(boolean())
  def table_args([{:symbol, "(", _u, _l, _c} | rest]) do
    with {:ok, _args, rest} <- call_args(rest), do: {:ok, true, rest}
  end

  def table_args(tokens), do: {:ok, false, tokens}

  @spec call_args([token()]) :: parsed([ast()])
  defp call_args([{:symbol, ")", _u, _l, _c} | rest]), do: {:ok, [], rest}

  defp call_args(tokens) do
    with {:ok, args, rest} <- expr_list(tokens),
         {:ok, rest} <- expect_symbol(rest, ")"),
         do: {:ok, args, rest}
  end

  @spec alias_word([token()]) :: parsed(binary() | nil)
  defp alias_word([{:word, _p, "AS", _l, _c}, {:word, printed, _u, _l2, _c2} | rest]),
    do: {:ok, String.downcase(printed), rest}

  defp alias_word([{:word, _p, "AS", _l, _c}, {:quoted, printed, _u, _l2, _c2} | rest]),
    do: quoted_alias(printed, rest)

  defp alias_word([{:word, _p, "AS", _l, _c}, token | _rest]),
    do: {:error, SQLDdl.expected("an identifier after AS", token)}

  defp alias_word([{:word, _p, upper, _l, _c} | _rest] = tokens) when upper in @alias_reserved,
    do: {:ok, nil, tokens}

  defp alias_word([{:word, _p, upper, _l, _c} | _rest]) when upper in @join_words,
    do: {:refuse, "an update that goes on with #{String.downcase(upper)}"}

  defp alias_word([{:word, printed, _u, _l, _c} | rest]),
    do: {:ok, String.downcase(printed), rest}

  defp alias_word([{:quoted, printed, _u, _l, _c} | rest]), do: quoted_alias(printed, rest)

  # A string beside the table is read as its alias (verified: `UPDATE main 'a' SET v = 1`).
  defp alias_word([{:string, printed, _u, _l, _c} | rest]), do: quoted_alias(printed, rest)
  defp alias_word(tokens), do: {:ok, nil, tokens}

  # A quoted alias in lower case is the alias unquoted; one with capitals has other rules.
  @spec quoted_alias(binary(), [token()]) :: parsed(binary())
  defp quoted_alias(printed, rest) do
    alias_name = String.slice(printed, 1..-2//1)

    if alias_name == String.downcase(alias_name) and alias_name != "",
      do: {:ok, alias_name, rest},
      else: {:refuse, "a quoted alias with capitals"}
  end

  # What follows the table and its alias must be `SET`.

  @spec set_next([token()]) :: parsed(nil)
  defp set_next([{:word, _p, "SET", _l, _c} | _rest] = tokens), do: {:ok, nil, tokens}

  defp set_next([{:word, _p, upper, _l, _c} | _rest]) when upper in @join_words,
    do: {:refuse, "an update that goes on with #{String.downcase(upper)}"}

  defp set_next([token | _rest]), do: {:error, SQLDdl.expected("SET", token)}

  @spec set([token()]) :: parsed([{[name()] | :tuple, ast()}])
  defp set([{:word, _p, "SET", _l, _c} | rest]), do: assignments(rest, [])

  @spec assignments([token()], [{[name()] | :tuple, ast()}]) ::
          parsed([{[name()] | :tuple, ast()}])
  defp assignments(tokens, found) do
    with {:ok, target, rest} <- target(tokens),
         {:ok, rest} <- expect_symbol(rest, "="),
         {:ok, value, rest} <- expr(rest) do
      found = [{target, value} | found]

      case rest do
        [{:symbol, ",", _u, _l, _c} | more] -> assignments(more, found)
        _other -> {:ok, Enum.reverse(found), rest}
      end
    end
  end

  @spec target([token()]) :: parsed([name()] | :tuple)
  defp target([{:symbol, "(", _u, _l, _c} | rest]), do: tuple(rest)

  defp target([{kind, _p, _u, _l, _c} | _rest] = tokens) when kind in [:word, :quoted],
    do: name_chain(tokens, false)

  defp target([{:string, _p, _u, _l, _c} | _rest]), do: {:refuse, "a string as a target"}
  defp target([token | _rest]), do: {:error, SQLDdl.expected("identifier", token)}

  # `(a, b) = ...`: a tuple, which the planner refuses when it reaches it.
  @spec tuple([token()]) :: parsed(:tuple)
  defp tuple(tokens) do
    with {:ok, _names, rest} <- name_chain(tokens, false) do
      case rest do
        [{:symbol, ",", _u, _l, _c} | more] -> tuple(more)
        [{:symbol, ")", _u, _l, _c} | more] -> {:ok, :tuple, more}
        [token | _more] -> {:error, SQLDdl.expected(")", token)}
      end
    end
  end

  # `FROM table [[AS] alias] [, ...]`: read to find where it ends. What it holds is the planner's
  # business once the table is found, which the double does not model.
  @spec from([token()]) :: parsed(boolean())
  defp from([{:word, _p, "FROM", _l, _c} | rest]), do: from_tables(rest)
  defp from(tokens), do: {:ok, false, tokens}

  @spec from_tables([token()]) :: parsed(true)
  defp from_tables([{kind, _p, _u, _l, _c} | _rest] = tokens) when kind in [:word, :quoted] do
    with {:ok, _name, rest} <- name_chain(tokens) do
      rest = from_alias(rest)

      case rest do
        [{:symbol, ",", _u2, _l2, _c2} | more] ->
          from_tables(more)

        [{:word, _p2, upper, _l2, _c2} | _more]
        when upper in @join_words or upper in ~w(ON USING) ->
          {:refuse, "an update whose FROM clause joins"}

        _end ->
          {:ok, true, rest}
      end
    end
  end

  defp from_tables([{:symbol, "(", _u, _l, _c} | _rest]),
    do: {:refuse, "an update whose FROM clause is a subquery"}

  defp from_tables([token | _rest]), do: {:error, SQLDdl.expected("identifier", token)}

  @spec from_alias([token()]) :: [token()]
  defp from_alias([{:word, _p, "AS", _l, _c}, {kind, _p2, _u, _l2, _c2} | rest])
       when kind in [:word, :quoted],
       do: rest

  defp from_alias([{:word, _p, upper, _l, _c} | _rest] = tokens)
       when upper in @alias_reserved or upper in @join_words,
       do: tokens

  defp from_alias([{:word, _p, _upper, _l, _c} | rest]), do: rest
  defp from_alias(tokens), do: tokens

  @spec optional([token()], binary()) :: parsed(ast() | nil)
  defp optional([{:word, _p, keyword, _l, _c} | rest], keyword), do: expr(rest)
  defp optional(tokens, _keyword), do: {:ok, nil, tokens}

  # `RETURNING` takes select items, which the planner refuses wherever they are.
  @spec returning([token()]) :: parsed(boolean())
  defp returning([{:word, _p, "RETURNING", _l, _c} | rest]), do: returning_items(rest)
  defp returning(tokens), do: {:ok, false, tokens}

  @spec returning_items([token()]) :: parsed(true)
  defp returning_items([{:symbol, "*", _u, _l, _c} | rest]), do: returning_more(rest)

  defp returning_items(tokens) do
    with {:ok, _item, rest} <- expr(tokens) do
      case rest do
        [{:word, _p, "AS", _l, _c}, {kind, _p2, _u2, _l2, _c2} | more]
        when kind in [:word, :quoted] ->
          returning_more(more)

        _no_alias ->
          returning_more(rest)
      end
    end
  end

  @spec returning_more([token()]) :: parsed(true)
  defp returning_more([{:symbol, ",", _u, _l, _c} | rest]), do: returning_items(rest)
  defp returning_more(rest), do: {:ok, true, rest}

  @spec limit([token()]) :: parsed(boolean())
  defp limit([{:word, _p, "LIMIT", _l, _c}, {:word, _p2, "ALL", _l2, _c2} | rest]),
    do: {:ok, true, rest}

  defp limit([{:word, _p, "LIMIT", _l, _c} | rest]) do
    with {:ok, _limit, rest} <- expr(rest), do: {:ok, true, rest}
  end

  defp limit(tokens), do: {:ok, false, tokens}

  @spec finished([token()]) :: :ok | {:error, SQLError.t()}
  defp finished([{:eof, _p, _u, _l, _c}]), do: :ok
  defp finished([{:symbol, ";", _u, _l, _c}]), do: :ok
  defp finished([token | _rest]), do: {:error, SQLDdl.expected("end of statement", token)}

  @spec expect_symbol([token()], binary()) :: {:ok, [token()]} | {:error, SQLError.t()}
  defp expect_symbol([{:symbol, symbol, _u, _l, _c} | rest], symbol), do: {:ok, rest}
  defp expect_symbol([token | _rest], symbol), do: {:error, SQLDdl.expected(symbol, token)}

  # ---------------------------------------------------------------------------
  # The clauses of a DELETE
  # ---------------------------------------------------------------------------

  @typedoc "The clauses of a delete after its table."
  @type delete_clauses :: %{
          several: boolean(),
          function: boolean(),
          using: boolean(),
          where: ast() | nil,
          returning: boolean(),
          order_by: boolean(),
          limit: boolean()
        }

  @doc """
  The clauses of a delete from the tokens after its table, the token that ends the statement
  last: `[[AS] alias] [USING tables] [WHERE operand] [RETURNING items] [ORDER BY terms]
  [LIMIT operand]`. The alias is read and dropped: the planner names the table's fields by
  the table as written.
  """
  @spec delete_clauses([token()]) ::
          {:ok, delete_clauses()} | {:error, SQLError.t()} | {:refuse, binary()}
  def delete_clauses([{:word, _p, upper, _l, _c} | _rest]) when upper in @join_words,
    do: {:refuse, "a delete that goes on with #{String.downcase(upper)}"}

  def delete_clauses(tokens) do
    with {:ok, function, tokens} <- table_args(tokens),
         {:ok, _alias, rest} <- delete_alias(plain_alias(tokens)),
         {:ok, several, rest} <- several(rest),
         {:ok, using, rest} <- using(rest),
         {:ok, where, rest} <- optional(rest, "WHERE"),
         {:ok, returning, rest} <- returning(rest),
         {:ok, order_by, rest} <- order_by(rest),
         {:ok, limit, rest} <- limit(rest),
         :ok <- finished(rest) do
      {:ok,
       %{
         function: function,
         several: several,
         using: using,
         where: where,
         returning: returning,
         order_by: order_by,
         limit: limit
       }}
    end
  end

  # `FROM a, b`: more tables, read to find where they end.
  @spec several([token()]) :: parsed(boolean())
  defp several([{:symbol, ",", _u, _l, _c} | rest]), do: from_tables(rest)
  defp several(tokens), do: {:ok, false, tokens}

  # The alias of a delete is dropped, and a list of names after it is not read (the engine
  # accepts what stands in the parentheses).
  @spec delete_alias([token()]) :: parsed(binary() | nil)
  defp delete_alias(tokens) do
    with {:ok, name, rest} <- alias_word(tokens) do
      case rest do
        [{:symbol, "(", _u, _l, _c} | more] when name != nil ->
          skip_parenthesis(more, 0, name)

        _no_columns ->
          {:ok, name, rest}
      end
    end
  end

  @spec skip_parenthesis([token()], non_neg_integer(), binary()) :: parsed(binary())
  defp skip_parenthesis([{:symbol, ")", _u, _l, _c} | rest], 0, name), do: {:ok, name, rest}

  defp skip_parenthesis([{:symbol, ")", _u, _l, _c} | rest], depth, name),
    do: skip_parenthesis(rest, depth - 1, name)

  defp skip_parenthesis([{:symbol, "(", _u, _l, _c} | rest], depth, name),
    do: skip_parenthesis(rest, depth + 1, name)

  defp skip_parenthesis([{:eof, _p, _u, _l, _c} = token | _rest], _depth, _name),
    do: {:error, SQLDdl.expected(")", token)}

  defp skip_parenthesis([_token | rest], depth, name), do: skip_parenthesis(rest, depth, name)

  # A delete drops its alias, so any quoted one is read as a word.
  @spec plain_alias([token()]) :: [token()]
  defp plain_alias([{:word, _p, "AS", _l, _c} = as, token | rest]),
    do: [as, plain_word(token) | rest]

  defp plain_alias([token | rest]), do: [plain_word(token) | rest]

  @spec plain_word(token()) :: token()
  defp plain_word({kind, printed, _u, line, col} = token) when kind in [:quoted, :string] do
    name = String.slice(printed, 1..-2//1)

    if name == "",
      do: token,
      else: {:word, name, String.upcase(name), line, col}
  end

  defp plain_word(token), do: token

  @doc """
  The tokens after the `LIMIT` and `OFFSET` clauses that close a query (their values are not
  planned by an insert), in either order.
  """
  @spec query_suffix([token()]) ::
          {:ok, [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  def query_suffix(tokens), do: query_suffix(tokens, [])

  @spec query_suffix([token()], [binary()]) ::
          {:ok, [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp query_suffix([{:word, _p, word, _l, _c} | more] = tokens, seen)
       when word in ["LIMIT", "OFFSET"] do
    if word in seen do
      {:ok, tokens}
    else
      with {:ok, value, rest} <- suffix_value(word, more) do
        if match?({:num, _}, value) or match?({:neg, {:num, _}}, value),
          do: query_suffix(rest, [word | seen]),
          else: {:refuse, "a #{String.downcase(word)} that is not a number"}
      end
    end
  end

  defp query_suffix(tokens, _seen), do: {:ok, tokens}

  @spec suffix_value(binary(), [token()]) :: parsed(ast())
  defp suffix_value("LIMIT", tokens), do: expr(tokens)

  defp suffix_value("OFFSET", tokens) do
    with {:ok, value, rest} <- expr(tokens) do
      case rest do
        [{:word, _p, rows, _l, _c} | after_rows] when rows in ["ROW", "ROWS"] ->
          {:ok, value, after_rows}

        _no_rows ->
          {:ok, value, rest}
      end
    end
  end

  @spec using([token()]) :: parsed(boolean())
  defp using([{:word, _p, "USING", _l, _c} | rest]), do: from_tables(rest)
  defp using(tokens), do: {:ok, false, tokens}

  @spec order_by([token()]) :: parsed(boolean())
  defp order_by([{:word, _p, "ORDER", _l, _c}, {:word, _p2, "BY", _l2, _c2} | rest]),
    do: order_terms(rest)

  defp order_by(tokens), do: {:ok, false, tokens}

  @spec order_terms([token()]) :: parsed(true)
  defp order_terms(tokens) do
    with {:ok, _term, rest} <- expr(tokens) do
      case direction(rest) do
        [{:symbol, ",", _u, _l, _c} | more] -> order_terms(more)
        other -> {:ok, true, other}
      end
    end
  end

  @spec direction([token()]) :: [token()]
  defp direction([{:word, _p, dir, _l, _c} | rest]) when dir in ["ASC", "DESC"],
    do: direction_nulls(rest)

  defp direction(rest), do: direction_nulls(rest)

  @spec direction_nulls([token()]) :: [token()]
  defp direction_nulls([{:word, _p, "NULLS", _l, _c}, {:word, _p2, nulls, _l2, _c2} | rest])
       when nulls in ["FIRST", "LAST"],
       do: rest

  defp direction_nulls(rest), do: rest

  # ---------------------------------------------------------------------------
  # The source of an INSERT
  # ---------------------------------------------------------------------------

  @typedoc "A cell of a `VALUES` row: an operand, or a placeholder that is no number."
  @type cell :: ast() | {:bare_placeholder, binary()} | {:opaque, binary()}

  @doc """
  The rows of a `VALUES` list from the tokens after the keyword, and the tokens after them.
  """
  @spec rows([token()]) :: parsed([[cell()]])
  def rows(tokens), do: rows(tokens, [])

  @spec rows([token()], [[cell()]]) :: parsed([[cell()]])
  defp rows(tokens, found) do
    with {:ok, rest} <- expect_symbol(tokens, "("),
         {:ok, cells, rest} <- cells(rest, []) do
      found = [cells | found]

      case rest do
        [{:symbol, ",", _u, _l, _c} | more] -> rows(more, found)
        _end -> {:ok, Enum.reverse(found), rest}
      end
    end
  end

  @spec cells([token()], [cell()]) :: parsed([cell()])
  defp cells(tokens, found) do
    with {:ok, cell, rest} <- cell_or_opaque(tokens) do
      case rest do
        [{:symbol, ",", _u, _l, _c} | more] ->
          cells(more, [cell | found])

        [{:symbol, ")", _u, _l, _c} | more] ->
          {:ok, Enum.reverse([cell | found]), more}

        [token | _more] ->
          {:error, SQLDdl.expected(")", token)}
      end
    end
  end

  # A cell the double cannot read is skipped to its end, so that what the planner finds
  # before it (and the rows' lengths) is still answered; planning reaches it as a refusal.
  @spec cell_or_opaque([token()]) :: parsed(cell())
  defp cell_or_opaque(tokens) do
    case cell(tokens) do
      {:refuse, why} -> skip_cell(tokens, 0, why)
      other -> other
    end
  end

  @spec skip_cell([token()], non_neg_integer(), binary()) :: parsed(cell())
  defp skip_cell([{:symbol, sep, _u, _l, _c} | _rest] = tokens, 0, why) when sep in [",", ")"],
    do: {:ok, {:opaque, why}, tokens}

  defp skip_cell([{:symbol, "(", _u, _l, _c} | rest], depth, why),
    do: skip_cell(rest, depth + 1, why)

  defp skip_cell([{:symbol, ")", _u, _l, _c} | rest], depth, why),
    do: skip_cell(rest, depth - 1, why)

  defp skip_cell([{:eof, _p, _u, _l, _c} | _rest], _depth, why), do: {:refuse, why}
  defp skip_cell([_token | rest], depth, why), do: skip_cell(rest, depth, why)
  defp skip_cell([], _depth, why), do: {:refuse, why}

  # A placeholder that stands alone in a cell is read by its name before the row is planned.
  @spec cell([token()]) :: parsed(cell())
  defp cell([{:placeholder, text, _u, _l, _c}, {:symbol, sep, _u2, _l2, _c2} | _rest] = tokens)
       when sep in [",", ")"],
       do: {:ok, {:bare_placeholder, text}, tl(tokens)}

  defp cell(
         [
           {:symbol, ":", _u, _l, _c},
           {:word, name, _u2, _l2, _c2},
           {:symbol, sep, _u3, _l3, _c3} | _rest
         ] = tokens
       )
       when sep in [",", ")"],
       do: {:ok, {:bare_placeholder, ":" <> name}, Enum.drop(tokens, 2)}

  defp cell(tokens), do: expr(tokens)

  @typedoc "A `SELECT` source: its items, the table it reads and the tokens after it."
  @type select :: %{
          items: [{:expr, ast()} | :star],
          from: {[binary()], binary() | nil} | nil,
          rest: [token()]
        }

  @doc """
  The items and the table of a plain `SELECT items [FROM table [[AS] alias]]` from the tokens
  after the keyword.
  """
  @spec select([token()]) :: {:ok, select()} | {:error, SQLError.t()} | {:refuse, binary()}
  def select([{:word, _p, upper, _l, _c} | _rest]) when upper in ["DISTINCT", "ALL", "TOP"],
    do: {:refuse, "a select with #{String.downcase(upper)}"}

  def select([{:word, _p, "FROM", _l, _c} | _rest] = tokens), do: select_from(tokens, [])

  def select(tokens) do
    with {:ok, items, rest} <- select_items(tokens, []), do: select_from(rest, items)
  end

  @spec select_items([token()], [term()]) :: parsed([term()])
  defp select_items([{:symbol, "*", _u, _l, _c} | rest], found),
    do: select_more(rest, [:star | found])

  defp select_items(tokens, found) do
    with {:ok, item, rest} <- expr(tokens) do
      select_more(select_alias(rest), [{:expr, item} | found])
    end
  end

  @spec select_alias([token()]) :: [token()]
  defp select_alias([{:word, _p, "AS", _l, _c}, {kind, _p2, _u, _l2, _c2} | rest])
       when kind in [:word, :quoted],
       do: rest

  defp select_alias([{:word, _p, upper, _l, _c} | _rest] = tokens)
       when upper in @alias_reserved or upper in @join_words,
       do: tokens

  defp select_alias([{:word, _p, _upper, _l, _c} | rest]), do: rest
  defp select_alias([{:string, _p, _upper, _l, _c} | rest]), do: rest
  defp select_alias(tokens), do: tokens

  @spec select_more([token()], [term()]) :: parsed([term()])
  defp select_more([{:symbol, ",", _u, _l, _c} | rest], found) do
    case rest do
      [{:word, _p, "FROM", _l2, _c2} | _more] ->
        {:ok, Enum.reverse(found), rest}

      [{kind, _p, upper, _l2, _c2}] when kind == :eof or upper == ";" ->
        {:ok, Enum.reverse(found), rest}

      _items ->
        select_items(rest, found)
    end
  end

  defp select_more(rest, found), do: {:ok, Enum.reverse(found), rest}

  @spec select_from([token()], [term()]) ::
          {:ok, select()} | {:error, SQLError.t()} | {:refuse, binary()}
  defp select_from([{:word, _p, "FROM", _l, _c} | rest], items) do
    with {:ok, parts, rest} <- SQLDmlName.reference(rest),
         {:ok, alias_name, rest} <- alias_name(rest) do
      {:ok, %{items: items, from: {parts, alias_name}, rest: rest}}
    end
  end

  defp select_from(rest, items), do: {:ok, %{items: items, from: nil, rest: rest}}

  # ---------------------------------------------------------------------------
  # Operands
  # ---------------------------------------------------------------------------

  @doc "One operand from the tokens, and the tokens after it."
  @spec expr([token()]) :: parsed(ast())
  def expr(tokens), do: subexpr(tokens, 0)

  @spec subexpr([token()], non_neg_integer()) :: parsed(ast())
  defp subexpr(tokens, precedence) do
    with {:ok, left, rest} <- prefix(tokens), do: infix(left, rest, precedence)
  end

  @spec infix(ast(), [token()], non_neg_integer()) :: parsed(ast())
  defp infix(left, tokens, precedence) do
    case operator(tokens) do
      :none ->
        {:ok, left, tokens}

      {:refuse, _why} = refusal ->
        refusal

      {next, kind} when next > precedence ->
        with {:ok, node, rest} <- apply_infix(kind, left, tokens, next),
             do: infix(node, rest, precedence)

      {_next, _kind} ->
        {:ok, left, tokens}
    end
  end

  # The precedence of the operator the tokens begin with, and which it is.
  @spec operator([token()]) :: :none | {non_neg_integer(), term()} | {:refuse, binary()}
  defp operator([{:word, _p, "OR", _l, _c} | _rest]), do: {5, :or}
  defp operator([{:word, _p, "AND", _l, _c} | _rest]), do: {10, :and}
  defp operator([{:word, _p, "IS", _l, _c} | _rest]), do: {17, :is}
  defp operator([{:word, _p, "IN", _l, _c} | _rest]), do: {20, {:in, false}}
  defp operator([{:word, _p, "BETWEEN", _l, _c} | _rest]), do: {20, {:between, false}}

  defp operator([{:word, _p, like, _l, _c} | _rest]) when like in ["LIKE", "ILIKE"],
    do: {19, {:like, false}}

  defp operator([{:word, _p, "NOT", _l, _c}, {:word, _p2, next, _l2, _c2} | _rest]) do
    case next do
      "IN" ->
        {20, {:in, true}}

      "BETWEEN" ->
        {20, {:between, true}}

      like when like in ["LIKE", "ILIKE"] ->
        {19, {:like, true}}

      refused when refused in @refused_operators ->
        {:refuse, "an operator the double does not read"}

      _other ->
        :none
    end
  end

  defp operator([{:word, _p, upper, _l, _c} | _rest]) when upper in @refused_operators,
    do: {:refuse, "#{String.downcase(upper)} as an operator"}

  defp operator([{:symbol, "(", _u, _l, _c} | _rest]),
    do: {:refuse, "a parenthesis after an operand"}

  defp operator([{:symbol, "::", _u, _l, _c} | _rest]), do: {50, :cast}
  # `||` binds as `*` does (verified: `1.5 / 1e3 || ''` is `(1.5 / 1e3) || ''`).
  defp operator([{:symbol, "||", _u, _l, _c} | _rest]), do: {40, {:bin, "||"}}

  defp operator([{:symbol, symbol, upper, _l, _c} | _rest]) do
    cond do
      upper in @comparisons -> {20, {:bin, upper}}
      symbol in ["+", "-"] -> {30, {:bin, symbol}}
      symbol in ["*", "/", "%"] -> {40, {:bin, symbol}}
      symbol in ["|", "^", "&", "<<", ">>"] -> {22, {:bin, symbol}}
      symbol in ["//", "->", "->>", ":", "["] -> {:refuse, "the operator #{symbol}"}
      true -> :none
    end
  end

  defp operator(_tokens), do: :none

  @spec apply_infix(term(), ast(), [token()], non_neg_integer()) :: parsed(ast())
  defp apply_infix(:or, left, [_or | rest], precedence), do: binary("OR", left, rest, precedence)

  defp apply_infix(:and, left, [_and | rest], precedence),
    do: binary("AND", left, rest, precedence)

  defp apply_infix({:bin, op}, left, [_op | rest], precedence),
    do: binary(op, left, rest, precedence)

  defp apply_infix(:cast, left, [_colons | rest], _precedence) do
    with {:ok, type, rest} <- SQLDmlType.parse(rest), do: {:ok, {:cast, left, type, false}, rest}
  end

  defp apply_infix(:is, left, [_is | rest], _precedence), do: is(left, rest)
  defp apply_infix({:in, negated}, left, tokens, _precedence), do: in_list(left, tokens, negated)

  defp apply_infix({:between, negated}, left, tokens, precedence),
    do: between(left, drop_not(tokens), negated, precedence)

  defp apply_infix({:like, negated}, left, tokens, precedence),
    do: like(left, drop_not(tokens), negated, precedence)

  @spec binary(binary(), ast(), [token()], non_neg_integer()) :: parsed(ast())
  defp binary(op, left, tokens, precedence) do
    with {:ok, right, rest} <- subexpr(tokens, precedence),
         do: {:ok, {:bin, op, left, right}, rest}
  end

  # The tokens from the operator word, past a `NOT` before it.
  @spec drop_not([token()]) :: [token()]
  defp drop_not([{:word, _p, "NOT", _l, _c} | rest]), do: rest
  defp drop_not(tokens), do: tokens

  @spec is(ast(), [token()]) :: parsed(ast())
  defp is(left, [{:word, _p, "NOT", _l, _c} | rest]) do
    with {:ok, {:is, inner, what, _negated}, rest} <- is(left, rest),
         do: {:ok, {:is, inner, what, true}, rest}
  end

  defp is(left, [{:word, _p, "NULL", _l, _c} | rest]), do: {:ok, {:is, left, :null, false}, rest}
  defp is(left, [{:word, _p, "TRUE", _l, _c} | rest]), do: {:ok, {:is, left, true, false}, rest}
  defp is(left, [{:word, _p, "FALSE", _l, _c} | rest]), do: {:ok, {:is, left, false, false}, rest}

  defp is(left, [{:word, _p, "UNKNOWN", _l, _c} | rest]),
    do: {:ok, {:is, left, :unknown, false}, rest}

  defp is(left, [{:word, _p, "DISTINCT", _l, _c}, {:word, _p2, "FROM", _l2, _c2} | rest]) do
    with {:ok, right, rest} <- expr(rest), do: {:ok, {:is, left, {:distinct, right}, false}, rest}
  end

  defp is(_left, _tokens), do: {:refuse, "an IS the double does not read"}

  @spec in_list(ast(), [token()], boolean()) :: parsed(ast())
  defp in_list(left, tokens, negated) do
    case drop_not(tokens) do
      [_in, {:symbol, "(", _u, _l, _c}, {:word, _p, query, _l2, _c2} | _rest]
      when query in ["SELECT", "WITH", "VALUES"] ->
        {:refuse, "an IN of a subquery"}

      [_in, {:symbol, "(", _u, _l, _c} | rest] ->
        with {:ok, items, rest} <- expr_list(rest),
             {:ok, rest} <- expect_symbol(rest, ")"),
             do: {:ok, {:in, left, items, negated}, rest}

      [_in, token | _rest] ->
        {:error, SQLDdl.expected("(", token)}
    end
  end

  @spec between(ast(), [token()], boolean(), non_neg_integer()) :: parsed(ast())
  defp between(left, [_between | rest], negated, precedence) do
    with {:ok, low, rest} <- subexpr(rest, precedence),
         {:ok, rest} <- expect_word(rest, "AND"),
         {:ok, high, rest} <- subexpr(rest, precedence),
         do: {:ok, {:between, left, low, high, negated}, rest}
  end

  @spec like(ast(), [token()], boolean(), non_neg_integer()) :: parsed(ast())
  defp like(left, [{:word, _p, keyword, _l, _c} | rest], negated, precedence) do
    with {:ok, pattern, rest} <- subexpr(rest, precedence) do
      case rest do
        [{:word, _p2, "ESCAPE", _l2, _c2}, {:string, escape, _u, _l3, _c3} | more] ->
          {:ok, {:like, left, pattern, negated, keyword, String.slice(escape, 1..-2//1)}, more}

        [{:word, _p2, "ESCAPE", _l2, _c2}, {:eof, _p3, _u3, _l3, _c3} = eof | _more] ->
          {:error, SQLDdl.expected("a value", eof)}

        [{:word, _p2, "ESCAPE", _l2, _c2} | _more] ->
          {:refuse, "an ESCAPE that is not a string"}

        _no_escape ->
          {:ok, {:like, left, pattern, negated, keyword, nil}, rest}
      end
    end
  end

  @spec expect_word([token()], binary()) :: {:ok, [token()]} | {:error, SQLError.t()}
  defp expect_word([{:word, _p, word, _l, _c} | rest], word), do: {:ok, rest}
  defp expect_word([token | _rest], word), do: {:error, SQLDdl.expected(word, token)}

  # `CAST(x)` without `AS` is read by the engine as a call of a function named `cast`.
  @spec as_word([token()]) :: {:ok, [token()]} | {:error, SQLError.t()} | {:refuse, binary()}
  defp as_word([{:word, _p, "AS", _l, _c} | rest]), do: {:ok, rest}
  defp as_word([{:symbol, ")", _u, _l, _c} | _rest]), do: {:refuse, "a CAST without AS"}
  defp as_word([token | _rest]), do: {:error, SQLDdl.expected("AS", token)}

  @spec expr_list([token()]) :: parsed([ast()])
  defp expr_list(tokens) do
    with {:ok, item, rest} <- expr(tokens) do
      case rest do
        [{:symbol, ",", _u, _l, _c} | more] ->
          with {:ok, items, rest} <- expr_list(more), do: {:ok, [item | items], rest}

        _end ->
          {:ok, [item], rest}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # What begins an operand
  # ---------------------------------------------------------------------------

  @spec prefix([token()]) :: parsed(ast())
  defp prefix([{:number, printed, _u, _l, _c} | rest]), do: {:ok, {:num, printed}, rest}

  defp prefix([{:string, printed, _u, _l, _c} | rest]),
    do: {:ok, {:str, String.slice(printed, 1..-2//1)}, rest}

  defp prefix([{:literal, "X'" <> _digits, _u, _l, _c} | _rest]),
    do: {:refuse, "a hexadecimal string"}

  defp prefix([{:literal, _printed, _u, _l, _c} | rest]), do: {:ok, {:str, "x"}, rest}
  # A placeholder has the type of what stands beside it, or none, as the null has none.
  defp prefix([{:placeholder, "$" <> name = text, _u, _l, _c} | rest])
       when name != "" and binary_part(name, 0, 1) == "0" do
    if Regex.match?(~r/\A0+\z/, name),
      do: {:ok, {:zero_param, text}, rest},
      else: {:ok, :param, rest}
  end

  defp prefix([{:placeholder, "$" <> name, _u, _l, _c} | rest]) when name != "",
    do: {:ok, :param, rest}

  defp prefix([{:placeholder, _p, _u, _l, _c} | _rest]), do: {:refuse, "a placeholder"}

  defp prefix([{:word, _p, "CURRENT_TIMESTAMP", _l, _c} | rest]),
    do: {:ok, {:call, "now", []}, rest}

  defp prefix([{:quoted, _p, _u, _l, _c} | _rest] = tokens), do: reference(tokens)

  defp prefix([{:word, _p, "TRUE", _l, _c} | rest]), do: {:ok, {:bool, true}, rest}
  defp prefix([{:word, _p, "FALSE", _l, _c} | rest]), do: {:ok, {:bool, false}, rest}
  defp prefix([{:word, _p, "NULL", _l, _c} | rest]), do: {:ok, :null, rest}

  defp prefix([{:word, _p, "NOT", _l, _c} | rest]) do
    with {:ok, inner, rest} <- subexpr(rest, 15), do: {:ok, {:not, inner}, rest}
  end

  defp prefix([{:word, _p, cast, _l, _c}, {:symbol, "(", _u, _l2, _c2} | rest])
       when cast in ["CAST", "TRY_CAST"] do
    with {:ok, inner, rest} <- expr(rest),
         {:ok, rest} <- as_word(rest),
         {:ok, type, rest} <- SQLDmlType.parse(rest),
         {:ok, rest} <- expect_symbol(rest, ")"),
         do: {:ok, {:cast, inner, type, cast == "TRY_CAST"}, rest}
  end

  defp prefix([{:word, _p, upper, _l, _c}, {:string, _p2, _u, _l2, _c2} | _rest])
       when upper in @typed_strings,
       do: {:refuse, "a typed string"}

  defp prefix([{:word, _p, upper, _l, _c} | _rest]) when upper in @refused_words,
    do: {:refuse, "#{String.downcase(upper)} in an operand"}

  defp prefix([{:word, _p, _upper, _l, _c} | _rest] = tokens), do: reference(tokens)

  defp prefix([{:symbol, sign, _u, _l, _c} | rest]) when sign in ["-", "+"] do
    with {:ok, inner, rest} <- subexpr(rest, 40),
         do: {:ok, {if(sign == "-", do: :neg, else: :pos), inner}, rest}
  end

  defp prefix([{:symbol, "(", _u, _l, _c}, {:word, _p, query, _l2, _c2} | _rest])
       when query in ["SELECT", "WITH", "VALUES"],
       do: {:refuse, "a subquery"}

  defp prefix([{:symbol, "(", _u, _l, _c} | rest]) do
    with {:ok, inner, rest} <- expr(rest) do
      case rest do
        [{:symbol, ")", _u2, _l2, _c2} | more] -> {:ok, inner, more}
        [{:symbol, ",", _u2, _l2, _c2} | more] -> tuple_rest(inner, more)
        [token | _more] -> {:error, SQLDdl.expected(")", token)}
      end
    end
  end

  # `:name` is a placeholder as `$name` is.
  defp prefix([{:symbol, ":", _u, _l, _c}, {:word, _p, _upper, _l2, _c2} | rest]),
    do: {:ok, :param, rest}

  defp prefix([{:symbol, symbol, _u, _l, _c} | _rest]) when symbol in ["[", "{", "@", ":", "?"],
    do: {:refuse, "#{symbol} in an operand"}

  defp prefix([token | _rest]), do: {:error, SQLDdl.expected("an expression", token)}

  # The rest of `(a, b, ...)` after its first operand: a row, which only a tuple target takes.
  @spec tuple_rest(ast(), [token()]) :: parsed(ast())
  defp tuple_rest(first, tokens) do
    with {:ok, items, rest} <- expr_list(tokens),
         {:ok, rest} <- expect_symbol(rest, ")"),
         do: {:ok, {:tuple, [first | items]}, rest}
  end

  # A name, or the call of a function it is.
  @spec reference([token()]) :: parsed(ast())
  defp reference(tokens) do
    with {:ok, parts, rest} <- name_chain(tokens) do
      case {parts, rest} do
        {[{name, false}], [{:symbol, "(", _u, _l, _c} | args]} ->
          call(name, args)

        {_parts, [{:symbol, "(", _u, _l, _c} | _args]} ->
          {:refuse, "a call of a quoted or compound name"}

        _no_call ->
          {:ok, {:ref, parts}, rest}
      end
    end
  end

  @spec call(binary(), [token()]) :: parsed(ast())
  defp call(name, [{:symbol, ")", _u, _l, _c} | rest]), do: suffix({:call, name, []}, rest)

  defp call(name, [{:symbol, "*", _u, _l, _c}, {:symbol, ")", _u2, _l2, _c2} | rest]),
    do: suffix({:call, name, :star}, rest)

  defp call(_name, [{:word, _p, modifier, _l, _c} | _rest]) when modifier in ["DISTINCT", "ALL"],
    do: {:refuse, "a call with #{String.downcase(modifier)}"}

  defp call(name, tokens) do
    with {:ok, args, rest} <- expr_list(tokens),
         {:ok, rest} <- expect_symbol(rest, ")"),
         do: suffix({:call, name, args}, rest)
  end

  @spec suffix(ast(), [token()]) :: parsed(ast())
  defp suffix(_call, [{:word, _p, word, _l, _c} | _rest]) when word in @call_suffixes,
    do: {:refuse, "a call with #{String.downcase(word)}"}

  defp suffix(call, rest), do: {:ok, call, rest}

  # `name[.name ...]`: unquoted names in lower case (the engine folds the names of an operand,
  # but not the target of an assignment, `fold?`), quoted ones as written.
  @spec name_chain([token()], boolean()) :: parsed([name()])
  defp name_chain(tokens, fold? \\ true)

  defp name_chain([first | rest], fold?) do
    case ident(first, fold?) do
      {:ok, name} -> name_more(rest, [name], fold?)
      :error -> {:error, SQLDdl.expected("identifier", first)}
    end
  end

  @spec name_more([token()], [name()], boolean()) :: parsed([name()])
  defp name_more(
         [{:symbol, ".", _u, _l, _c}, {:word, _p, keyword, _l2, _c2} | _rest],
         _found,
         _fold?
       )
       when keyword in ["TRUE", "FALSE", "NULL"],
       do: {:refuse, "a keyword after a dot"}

  defp name_more([{:symbol, ".", _u, _l, _c}, next | rest], found, fold?) do
    case ident(next, fold?) do
      {:ok, name} -> name_more(rest, [name | found], fold?)
      :error -> name_end(next, found, rest)
    end
  end

  defp name_more(rest, found, _fold?), do: {:ok, Enum.reverse(found), rest}

  defp name_end({:symbol, "*", _u, _l, _c}, _found, _rest), do: {:refuse, "a wildcard name"}

  defp name_end({:eof, _p, _u, _l, _c} = eof, _found, _rest),
    do: {:error, SQLDdl.expected("an expression", eof)}

  # What the engine says of a dot that nothing follows depends on where the name stands (an
  # expression, a call's arguments), and on what comes after it: not modelled.
  defp name_end(_token, _found, _rest), do: {:refuse, "a name that ends in a dot"}

  @spec ident(token(), boolean()) :: {:ok, name()} | :error
  defp ident({:word, printed, _upper, _l, _c}, fold?),
    do: {:ok, {if(fold?, do: String.downcase(printed), else: printed), false}}

  defp ident({:quoted, printed, _upper, _l, _c}, _fold?),
    do: {:ok, {String.slice(printed, 1..-2//1), true}}

  defp ident(_token, _fold?), do: :error

  # ---------------------------------------------------------------------------
  # Reading an operand
  # ---------------------------------------------------------------------------

  @doc "The operands directly under an operand, in the order the engine reads them."
  @spec children(ast()) :: [ast()]
  def children({:call, _name, args}) when is_list(args), do: args
  def children({kind, inner}) when kind in [:neg, :pos, :not], do: [inner]
  def children({:bin, _op, left, right}), do: [left, right]
  def children({:is, inner, {:distinct, other}, _negated}), do: [inner, other]
  def children({:is, inner, _what, _negated}), do: [inner]
  def children({:in, inner, items, _negated}), do: [inner | items]
  def children({:between, inner, low, high, _negated}), do: [inner, low, high]
  def children({:like, inner, pattern, _negated, _word, _escape}), do: [inner, pattern]
  def children({:cast, inner, _type, _try}), do: [inner]
  def children({:tuple, items}), do: items
  def children(_leaf), do: []

  # ---------------------------------------------------------------------------
  # Writing an operand as a query's select item, for the double's planner
  # ---------------------------------------------------------------------------

  @doc """
  The operand written as SQL, every operator in parentheses; a name is written by `name_text`.
  """
  @spec unparse(ast(), ([name()] -> binary())) :: binary()
  def unparse({:num, printed}, _names), do: printed
  def unparse({:str, body}, _names), do: "'" <> String.replace(body, "'", "''") <> "'"
  def unparse({:bool, value}, _names), do: Atom.to_string(value)
  def unparse(:null, _names), do: "NULL"
  def unparse(:param, _names), do: "NULL"
  def unparse({:ref, parts}, names), do: names.(parts)
  def unparse({:call, name, :star}, _names), do: name <> "(*)"

  def unparse({:call, name, args}, names),
    do: name <> "(" <> Enum.map_join(args, ", ", &unparse(&1, names)) <> ")"

  def unparse({:tuple, items}, names),
    do: "(" <> Enum.map_join(items, ", ", &unparse(&1, names)) <> ")"

  def unparse({:neg, inner}, names), do: "(- " <> unparse(inner, names) <> ")"
  # The planner types a unary plus as its operand and finds fault with it only late.
  def unparse({:pos, inner}, names), do: unparse(inner, names)

  def unparse({:bin, op, left, right}, names),
    do:
      "(" <>
        unparse(left, names) <> " " <> sql_operator(op) <> " " <> unparse(right, names) <> ")"

  # A test of a value, a `NOT`, an `IN`, a `BETWEEN` and a `LIKE` are lowered to a stand-in
  # before they are printed; only `IS [NOT] DISTINCT FROM` is printed as it is.
  def unparse({:is, inner, {:distinct, other}, negated}, names) do
    "(" <>
      unparse(inner, names) <>
      " IS " <>
      if(negated, do: "NOT ", else: "") <> "DISTINCT FROM " <> unparse(other, names) <> ")"
  end

  def unparse({:cast, inner, type, try?}, names),
    do:
      if(try?, do: "TRY_CAST(", else: "CAST(") <>
        unparse(inner, names) <> " AS " <> SQLDmlType.local_sql(type) <> ")"

  @spec sql_operator(binary()) :: binary()
  defp sql_operator("=="), do: "="
  defp sql_operator("!="), do: "<>"
  defp sql_operator("<=>"), do: "IS NOT DISTINCT FROM"
  defp sql_operator(op), do: op
end
