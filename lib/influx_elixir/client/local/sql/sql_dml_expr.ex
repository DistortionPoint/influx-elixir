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

  alias InfluxElixir.Client.Local.{SQLDdl, SQLError, SQLTokenizer}

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
          | {:cast, ast(), binary(), boolean()}
          | {:tuple, [ast()]}

  @typedoc "The clauses of an update after its table."
  @type clauses :: %{
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
    with {:ok, alias_name, rest} <- alias_name(tokens),
         {:ok, nil, rest} <- set_next(rest),
         {:ok, assignments, rest} <- set(rest),
         {:ok, from, rest} <- from(rest),
         {:ok, where, rest} <- optional(rest, "WHERE"),
         {:ok, returning, rest} <- returning(rest),
         {:ok, limit, rest} <- limit(rest),
         :ok <- finished(rest) do
      {:ok,
       %{
         alias: alias_name,
         assignments: assignments,
         from: from,
         where: where,
         returning: returning,
         limit: limit
       }}
    end
  end

  @spec alias_name([token()]) :: parsed(binary() | nil)
  defp alias_name([{:word, _p, "AS", _l, _c}, {:word, printed, _u, _l2, _c2} | rest]),
    do: {:ok, String.downcase(printed), rest}

  defp alias_name([{:word, _p, "AS", _l, _c}, {:quoted, printed, _u, _l2, _c2} | rest]),
    do: quoted_alias(printed, rest)

  defp alias_name([{:word, _p, "AS", _l, _c}, token | _rest]),
    do: {:error, SQLDdl.expected("an identifier after AS", token)}

  defp alias_name([{:word, _p, upper, _l, _c} | _rest] = tokens) when upper in @alias_reserved,
    do: {:ok, nil, tokens}

  defp alias_name([{:word, _p, upper, _l, _c} | _rest]) when upper in @join_words,
    do: {:refuse, "an update that goes on with #{String.downcase(upper)}"}

  defp alias_name([{:word, printed, _u, _l, _c} | rest]),
    do: {:ok, String.downcase(printed), rest}

  defp alias_name([{:quoted, printed, _u, _l, _c} | rest]), do: quoted_alias(printed, rest)

  # A string beside the table is read as its alias (verified: `UPDATE main 'a' SET v = 1`).
  defp alias_name([{:string, printed, _u, _l, _c} | rest]), do: quoted_alias(printed, rest)
  defp alias_name(tokens), do: {:ok, nil, tokens}

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
    with {:ok, type, rest} <- type_name(rest), do: {:ok, {:cast, left, type, false}, rest}
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

  # A type name: one word, with a size in parentheses at most.
  @spec type_name([token()]) :: parsed(binary())
  defp type_name([{:word, printed, _u, _l, _c}, {:symbol, "(", _u2, _l2, _c2} | rest]) do
    case rest do
      [{:number, size, _u3, _l3, _c3}, {:symbol, ")", _u4, _l4, _c4} | more] ->
        {:ok, "#{printed}(#{size})", more}

      _other ->
        {:refuse, "a type with more than a size"}
    end
  end

  defp type_name([{:word, printed, "DOUBLE", _l, _c}, {:word, _p, "PRECISION", _l2, _c2} | rest]),
    do: {:ok, printed, rest}

  defp type_name([{:word, _printed, upper, _l, _c} | _rest])
       when upper in ~w(INTERVAL CHARACTER NATIONAL BIT),
       do: {:refuse, "a type of several words"}

  defp type_name([{:word, _printed, upper, _l, _c}, {:word, _p, with, _l2, _c2} | _rest])
       when upper in ~w(TIMESTAMP TIME) and with in ["WITH", "WITHOUT"],
       do: {:refuse, "a type of several words"}

  defp type_name([{:word, printed, _upper, _l, _c} | rest]), do: {:ok, printed, rest}

  defp type_name([token | _rest]), do: {:error, SQLDdl.expected("a data type name", token)}

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
         {:ok, rest} <- expect_word(rest, "AS"),
         {:ok, type, rest} <- type_name(rest),
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
    do: if(try?, do: "TRY_CAST(", else: "CAST(") <> unparse(inner, names) <> " AS " <> type <> ")"

  @spec sql_operator(binary()) :: binary()
  defp sql_operator("=="), do: "="
  defp sql_operator("!="), do: "<>"
  defp sql_operator("<=>"), do: "IS NOT DISTINCT FROM"
  defp sql_operator(op), do: op
end
