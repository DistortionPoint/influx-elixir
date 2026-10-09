defmodule InfluxElixir.Client.Local.SQLWhere do
  @moduledoc false
  # The `WHERE` clause of a SQL text: a boolean expression over predicates
  # (verified against InfluxDB 3 Core).
  #
  #     expr   := term (OR term)*
  #     term   := factor (AND factor)*
  #     factor := NOT factor | '(' expr ')' | predicate
  #
  # AND binds tighter than OR, as in SQL. The result is a conjunction list; OR
  # and NOT appear as nodes inside it, so a plain `a AND b` is still the flat
  # list every executor path already understands. A predicate is a comparison,
  # `IN`, `BETWEEN`, `LIKE` / `ILIKE`, a regular-expression match, `IS [NOT]
  # NULL` or a bare boolean column; a `$name` is kept as a node for
  # `InfluxElixir.Client.Local.SQLBind`.

  alias InfluxElixir.Client.Local.{SQLError, SQLExpr, SQLLimit, SQLMask, SQLPredicate}

  @typedoc "A predicate: operator, left operand, right side."
  @type clause :: SQLPredicate.clause()

  @typedoc """
  A WHERE conjunction is a list of nodes: a predicate, an `{:or, branches}`
  node whose branches are conjunctions, or a `{:not, conjunction}` node.
  """
  @type node_t :: clause() | {:or, [[node_t()]]} | {:not, [node_t()]}

  @typedoc """
  A `WHERE` as written, in binary nodes: `AND` and `OR` of two, a `NOT`, a
  predicate, or a constant `true` or `false`.
  """
  @type tree ::
          {:and, tree(), tree()}
          | {:or, tree(), tree()}
          | {:not, tree()}
          | {:leaf, clause()}
          | {:const, boolean()}

  @limit_start SQLLimit.start_source()

  @doc """
  Parses the `WHERE ...` clause (if any) out of the text after `FROM <table>`.
  """
  @spec nodes(binary()) :: {:ok, [node_t()]} | {:error, SQLError.t()}
  def nodes(rest) do
    with {:ok, conj, _tree} <- parse(rest), do: {:ok, conj}
  end

  @doc """
  Both readings of the `WHERE ...` clause out of one parse: the conjunction list of `nodes/1` and
  the tree of `tree/1`.
  """
  @spec parsed(binary()) :: {:ok, [node_t()], tree() | nil} | {:error, SQLError.t()}
  def parsed(rest), do: parse(rest)

  @doc """
  The `WHERE ...` clause as written: the same predicates in binary `AND` and
  `OR` nodes, left to right, parentheses kept as the grouping they make, which
  the conjunction list of `nodes/1` does not keep. `nil` when there is no
  `WHERE` or it does not parse.
  """
  @spec tree(binary()) :: tree() | nil
  def tree(rest) do
    case parse(rest) do
      {:ok, _conj, tree} -> tree
      {:error, _reason} -> nil
    end
  end

  @spec parse(binary()) :: {:ok, [node_t()], tree() | nil} | {:error, map()}
  defp parse(rest) do
    case SQLMask.run(
           ~r/(?i)WHERE\s+(.+?)(?:\s+GROUP\b|\s+HAVING\b|\s+ORDER\b|\s+#{@limit_start}|$)/su,
           rest
         ) do
      [_full_match, clauses_str] -> parse_clauses(clauses_str)
      _no_match -> {:ok, [], nil}
    end
  end

  @spec parse_clauses(binary()) :: {:ok, [node_t()], tree()} | {:error, map()}
  defp parse_clauses(str) do
    with {:ok, tokens} <- tokenize_where(str),
         {:ok, conj, tree, []} <- where_or(tokens),
         :ok <- lone_literal(tree) do
      {:ok, conj, tree}
    else
      {:ok, _conj, _tree, leftover} ->
        {:error, SQLError.refusal("unsupported WHERE clause: #{str} (#{stray(leftover)})")}

      {:error, _reason} = error ->
        error
    end
  end

  # A `WHERE` that is one literal which is no boolean is the planner's error.
  @spec lone_literal(tree()) :: :ok | {:error, SQLError.t()}
  defp lone_literal({:leaf, {:non_boolean, _operand, {expression, type}}}),
    do: {:error, SQLPredicate.non_boolean_error(expression, type)}

  defp lone_literal(_tree), do: :ok

  @typep where_token :: :lparen | :rparen | :and | :or | :not | {:pred, binary()}

  # Scans the clause text into grouping parentheses, the three keywords and
  # predicate text. Parentheses that belong to a predicate (`IN (...)`,
  # `now()`) and keywords that belong to one (`NOT IN`, `NOT LIKE`, the AND of
  # `BETWEEN a AND b`) stay inside its text; string literals are opaque.
  @spec tokenize_where(binary()) :: {:ok, [where_token()]} | {:error, map()}
  defp tokenize_where(str) do
    scan_where(str, %{buf: "", tail: "", depth: 0, between: false, distinct: false, tokens: []})
  end

  @spec scan_where(binary(), map()) :: {:ok, [where_token()]} | {:error, map()}
  defp scan_where(<<>>, state),
    do: {:ok, state |> flush_pred() |> Map.fetch!(:tokens) |> Enum.reverse()}

  defp scan_where(<<q, rest::binary>>, state) when q in [?', ?"] do
    case take_literal(rest, q, []) do
      {:ok, literal, after_quote} -> scan_where(after_quote, append(state, <<q>> <> literal))
      :error -> {:error, SQLError.refusal("unterminated string literal in WHERE: #{rest}")}
    end
  end

  defp scan_where(<<"(", rest::binary>>, %{depth: 0} = state) do
    if String.trim(state.buf) == "" and grouping?(rest),
      do: scan_where(rest, emit(state, :lparen)),
      else: scan_where(rest, %{append(state, "(") | depth: 1})
  end

  defp scan_where(<<"(", rest::binary>>, state),
    do: scan_where(rest, %{append(state, "(") | depth: state.depth + 1})

  defp scan_where(<<")", rest::binary>>, %{depth: 0} = state),
    do: scan_where(rest, state |> flush_pred() |> emit(:rparen))

  defp scan_where(<<")", rest::binary>>, state),
    do: scan_where(rest, %{append(state, ")") | depth: state.depth - 1})

  defp scan_where(str, %{depth: 0} = state) do
    case {word_boundary?(state.buf), keyword_prefix(str)} do
      {true, {keyword, rest}} ->
        scan_keyword(keyword, rest, state)

      _not_a_keyword ->
        <<c::utf8, rest::binary>> = str
        scan_where(rest, append(state, <<c::utf8>>))
    end
  end

  defp scan_where(<<c::utf8, rest::binary>>, state),
    do: scan_where(rest, append(state, <<c::utf8>>))

  # The `AND`, `OR` or `NOT` (any case) the text starts with, as `{keyword, rest}`, when a
  # blank, a parenthesis or the end follows it. Read from the first bytes only: a pattern run
  # on the whole of the rest would check all of it for UTF-8 each time, which is quadratic.
  @spec keyword_prefix(binary()) :: {binary(), binary()} | nil
  defp keyword_prefix(str) do
    Enum.find_value(["AND", "OR", "NOT"], fn word ->
      size = byte_size(word)

      with <<head::binary-size(size), rest::binary>> <- str,
           true <- String.upcase(head, :ascii) == word,
           true <- keyword_end?(rest) do
        {word, rest}
      else
        _no_keyword -> nil
      end
    end)
  end

  defp keyword_end?(<<>>), do: true
  defp keyword_end?(<<c, _rest::binary>>), do: c in [?\s, ?\t, ?\n, ?\r, ?\v, ?\f, ?(]

  # A parenthesis that opens a predicate groups conditions when what follows
  # its closing one is the end, another closing parenthesis, `AND` or `OR`;
  # otherwise it is part of the predicate's text (`(n + 1) > 5`, `(n) IS NULL`).
  @spec grouping?(binary()) :: boolean()
  defp grouping?(rest) do
    case after_group(rest, 1) do
      :unbalanced -> true
      tail -> Regex.match?(~r/\A\s*(?:\z|\)|(?:AND|OR)(?=\s|\(|\z))/iu, tail)
    end
  end

  @spec after_group(binary(), pos_integer()) :: binary() | :unbalanced
  defp after_group(<<>>, _depth), do: :unbalanced

  defp after_group(<<q, rest::binary>>, depth) when q in [?', ?"] do
    case take_literal(rest, q, []) do
      {:ok, _literal, after_quote} -> after_group(after_quote, depth)
      :error -> :unbalanced
    end
  end

  defp after_group(<<"(", rest::binary>>, depth), do: after_group(rest, depth + 1)
  defp after_group(<<")", rest::binary>>, 1), do: rest
  defp after_group(<<")", rest::binary>>, depth), do: after_group(rest, depth - 1)
  defp after_group(<<_byte, rest::binary>>, depth), do: after_group(rest, depth)

  # The rest of a quoted literal, through its closing quote; a doubled quote
  # does not close it.
  @spec take_literal(binary(), char(), iodata()) :: {:ok, binary(), binary()} | :error
  defp take_literal(<<q, q, rest::binary>>, q, acc), do: take_literal(rest, q, [q, q | acc])

  defp take_literal(<<q, rest::binary>>, q, acc),
    do: {:ok, [q | acc] |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_literal(<<byte, rest::binary>>, q, acc), do: take_literal(rest, q, [byte | acc])
  defp take_literal(<<>>, _q, _acc), do: :error

  @spec scan_keyword(binary(), binary(), map()) :: {:ok, [where_token()]} | {:error, map()}
  defp scan_keyword("AND", rest, %{between: true} = state),
    do: scan_where(rest, %{append(state, "AND") | between: false})

  # The right side of `IS [NOT] DISTINCT FROM` takes whatever follows it at
  # its depth, `AND` and `OR` included (verified: `n IS DISTINCT FROM 4 AND b`
  # is `n IS DISTINCT FROM (4 AND b)`).
  defp scan_keyword(word, rest, %{distinct: true} = state) when word in ["AND", "OR"],
    do: scan_where(rest, append(state, word))

  defp scan_keyword("AND", rest, state), do: scan_where(rest, state |> flush_pred() |> emit(:and))
  defp scan_keyword("OR", rest, state), do: scan_where(rest, state |> flush_pred() |> emit(:or))

  # A leading NOT negates; one inside a predicate is `NOT IN` / `NOT LIKE` /
  # `NOT BETWEEN`.
  defp scan_keyword("NOT", rest, state) do
    if String.trim(state.buf) == "",
      do: scan_where(rest, emit(state, :not)),
      else: scan_where(rest, append(state, "NOT"))
  end

  @spec word_boundary?(binary()) :: boolean()
  defp word_boundary?(""), do: true
  defp word_boundary?(buf), do: String.ends_with?(buf, [" ", "\n", "\t", "("])

  # The keywords that change how the text after them is read are looked for at the end of the
  # predicate so far, and only in its last characters (`tail`): reading the whole of a long
  # predicate for every character added to it would be quadratic in its length.
  @tail_length 120

  @spec append(map(), binary()) :: map()
  defp append(state, text) do
    buf = state.buf <> text
    tail = tail_of(state.tail <> text)

    # Only the end of a keyword, or a blank after it, can complete one of them.
    if closes_keyword?(text) do
      between = state.between or Regex.match?(~r/\bBETWEEN\s*$/iu, tail)
      distinct = state.distinct or Regex.match?(~r/\bIS\s+(?:NOT\s+)?DISTINCT\s+FROM\s*$/iu, tail)
      %{state | buf: buf, tail: tail, between: between, distinct: distinct}
    else
      %{state | buf: buf, tail: tail}
    end
  end

  # `BETWEEN` ends in an `N`, `FROM` in an `M`.
  @spec closes_keyword?(binary()) :: boolean()
  defp closes_keyword?(text), do: text in ["n", "N", "m", "M", " ", "\n", "\t", "\r"]

  # The last characters of a text, cut at a character.
  @spec tail_of(binary()) :: binary()
  defp tail_of(text) when byte_size(text) <= 2 * @tail_length, do: text

  defp tail_of(text) do
    cut = byte_size(text) - @tail_length
    <<_head::binary-size(^cut), rest::binary>> = text
    drop_partial(rest)
  end

  # A cut can land inside a multibyte character: its bytes are dropped.
  @spec drop_partial(binary()) :: binary()
  defp drop_partial(<<byte, rest::binary>>) when Bitwise.band(byte, 0xC0) == 0x80,
    do: drop_partial(rest)

  defp drop_partial(text), do: text

  @spec emit(map(), where_token()) :: map()
  defp emit(state, token), do: %{state | tokens: [token | state.tokens]}

  @spec flush_pred(map()) :: map()
  defp flush_pred(state) do
    case String.trim(state.buf) do
      "" ->
        %{state | buf: "", tail: "", between: false, distinct: false}

      text ->
        %{
          state
          | buf: "",
            tail: "",
            between: false,
            distinct: false,
            tokens: [{:pred, text} | state.tokens]
        }
    end
  end

  @typep parsed :: {:ok, [node_t()], tree(), [where_token()]} | {:error, map()}

  @spec where_or([where_token()]) :: parsed()
  defp where_or(tokens) do
    with {:ok, first, tree, rest} <- where_and(tokens) do
      where_collect_or(rest, [first], tree)
    end
  end

  defp where_collect_or([:or | rest], branches, tree) do
    with {:ok, branch, branch_tree, rest} <- where_and(rest),
         do: where_collect_or(rest, [branch | branches], {:or, tree, branch_tree})
  end

  defp where_collect_or(rest, [single], tree), do: {:ok, single, tree, rest}

  defp where_collect_or(rest, branches, tree),
    do: {:ok, [{:or, Enum.reverse(branches)}], tree, rest}

  @spec where_and([where_token()]) :: parsed()
  defp where_and(tokens) do
    with {:ok, first, tree, rest} <- where_factor(tokens) do
      where_collect_and(rest, first, tree)
    end
  end

  defp where_collect_and([:and | rest], conj, tree) do
    with {:ok, next, next_tree, rest} <- where_factor(rest),
         do: where_collect_and(rest, conj ++ next, {:and, tree, next_tree})
  end

  defp where_collect_and(rest, conj, tree), do: {:ok, conj, tree, rest}

  @spec where_factor([where_token()]) :: parsed()
  defp where_factor([:not | rest]) do
    with {:ok, conj, tree, rest} <- where_factor(rest),
         do: {:ok, [{:not, conj}], {:not, tree}, rest}
  end

  defp where_factor([:lparen | rest]) do
    case where_or(rest) do
      {:ok, conj, tree, [:rparen | rest]} -> {:ok, conj, tree, rest}
      {:ok, _conj, _tree, _rest} -> {:error, SQLError.refusal("unbalanced parenthesis in WHERE")}
      {:error, _reason} = error -> error
    end
  end

  # A constant predicate is no condition (`[]`, true for every row) or one no
  # row meets (an OR of nothing).
  defp where_factor([{:pred, text} | rest]) do
    case SQLPredicate.parse(text) do
      {:ok, :always} -> {:ok, [], {:const, true}, rest}
      {:ok, :never} -> {:ok, [{:or, []}], {:const, false}, rest}
      {:ok, clause} -> {:ok, [clause], {:leaf, clause}, rest}
      {:error, _reason} = error -> error
    end
  end

  defp where_factor(tokens),
    do: {:error, SQLError.refusal("unsupported WHERE clause (#{wanted(tokens)})")}

  # What stands where a condition is wanted, or after the last one.
  @spec wanted([where_token()]) :: binary()
  defp wanted([]), do: "the clause ends where a condition is expected"
  defp wanted([token | _rest]), do: "#{token_name(token)} stands where a condition is expected"

  @spec stray([where_token()]) :: binary()
  defp stray([token | _rest]), do: "#{token_name(token)} follows a complete condition"

  @spec token_name(where_token()) :: binary()
  defp token_name(:and), do: "AND"
  defp token_name(:or), do: "OR"
  defp token_name(:not), do: "NOT"
  defp token_name(:lparen), do: "("
  defp token_name(:rparen), do: ")"
  defp token_name({:pred, text}), do: text

  # ---------------------------------------------------------------------------
  # What a node reads
  # ---------------------------------------------------------------------------

  @doc "The columns a `WHERE` tree uses as a condition on their own (`WHERE b AND n > 1`)."
  @spec truthy_columns(tree()) :: [binary()]
  def truthy_columns({:leaf, {:truthy, column, _nil}}), do: [column]

  def truthy_columns({kind, left, right}) when kind in [:and, :or],
    do: truthy_columns(left) ++ truthy_columns(right)

  def truthy_columns({:not, inner}), do: truthy_columns(inner)
  def truthy_columns(_leaf), do: []

  @doc """
  The arithmetic expressions a node holds, in the order written: the operands
  of a predicate that are expressions, and those of every predicate inside an
  `OR` or a `NOT`.
  """
  @spec exprs(node_t()) :: [SQLExpr.t()]
  def exprs({:or, branches}), do: Enum.flat_map(branches, &conjunction_exprs/1)
  def exprs({:not, conjunction}), do: conjunction_exprs(conjunction)

  def exprs({op, left, right}),
    do: operand_exprs(left) ++ right_exprs(op, right)

  @doc "The same as `exprs/1` for each node of a conjunction."
  @spec conjunction_exprs([node_t()]) :: [SQLExpr.t()]
  def conjunction_exprs(conjunction), do: Enum.flat_map(conjunction, &exprs/1)

  @doc """
  The names of the columns a node reads: a predicate's column operands and the
  columns inside its expressions. A reference to a relation the query does
  not have is not one.
  """
  @spec columns(node_t()) :: [binary()]
  def columns({:or, branches}), do: Enum.flat_map(branches, &conjunction_columns/1)
  def columns({:not, conjunction}), do: conjunction_columns(conjunction)

  # The `NULL` literal read as a condition (`NULL = NULL`, `HAVING NULL`) never holds and reads
  # no column (not even `time`, which a table made by a `WITH` may not have).
  def columns({:eq, :null, nil}), do: []

  def columns({_op, left, _right} = clause) do
    own = if is_binary(left), do: [left], else: []
    own ++ for(expr <- exprs(clause), name <- SQLExpr.columns(expr), is_binary(name), do: name)
  end

  @doc "The same as `columns/1` for each node of a conjunction."
  @spec conjunction_columns([node_t()]) :: [binary()]
  def conjunction_columns(conjunction), do: Enum.flat_map(conjunction, &columns/1)

  @spec operand_exprs(term()) :: [SQLExpr.t()]
  defp operand_exprs({:expr, expr}), do: [expr]
  defp operand_exprs(_literal_or_column), do: []

  # The right side of a predicate: a pair for `BETWEEN`, a list for `IN`, one
  # operand for anything else.
  @spec right_operands(atom(), term()) :: [term()]
  defp right_operands(op, {low, high}) when op in [:between, :not_between], do: [low, high]
  defp right_operands(op, values) when op in [:in, :not_in], do: values
  defp right_operands(_op, operand), do: [operand]

  @spec right_exprs(atom(), term()) :: [SQLExpr.t()]
  defp right_exprs(op, right),
    do: op |> right_operands(right) |> Enum.flat_map(&operand_exprs/1)
end
