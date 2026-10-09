defmodule InfluxElixir.Client.Local.InfluxQLNested do
  @moduledoc false
  # A comparison with a boolean of its own as an operand, as the engine plans it (verified over
  # every operator and every type of the other side):
  #
  #   * a condition in parentheses (`v > (w > 1)`, `ok = (n > 1 AND u > 1)`, `(w > 1) = (u >
  #     1)`, `true = (w > 1)`), a boolean operand like `true`
  #   * arithmetic of a column the measurement lacks and a text operand, a column or a string
  #     (`nosuch + 'x'`, `s * nosuch`): the engine reads it as `false`, a boolean that is no
  #     null (`nosuch + 'x' = ok` keeps the points `ok` is false for, `nosuch + 'x' <> true`
  #     all of them)
  #
  # The engine does not coerce the other side to a boolean first, so the arithmetic of the other
  # side is no error here (`'x' + v > (w > 1)` keeps no row, where `'x' + v > 1` is the
  # coercion error):
  #
  #   * a column or expression that is no boolean never equals the boolean nor orders against it:
  #     no row is true (a tag, a string, a number, a column the measurement lacks, arithmetic of
  #     them)
  #   * an unsigned column is the planner's error naming `UInt64` and `Boolean` in the order
  #     written (without the `type_coercion` prefix)
  #   * a boolean (a boolean column, `true`, `false`, another of these) is ordered against it as
  #     no row is true, and compared for equality as the two evaluate
  #
  # What the double cannot tell from the engine is refused by name: arithmetic with an unsigned
  # column in it that has no column the measurement lacks, arithmetic of a tag with text
  # beside a boolean, and a comparison chained with another.
  #
  # The scan that finds the layers of parentheses around a group is one pass, whatever their
  # depth (`InfluxQLTokens.unwrap_group/1`).

  alias InfluxElixir.Client.Local.{InfluxQLExpr, InfluxQLText, InfluxQLTokens, InfluxQLTyped}

  @ordering_ops ["<", "<=", ">", ">="]
  @equality_ops ["=", "!=", "<>"]
  @connectives ["AND", "OR"]
  @arithmetic_ops ["+", "-", "*", "/"]

  # What the double reads as `false`, the boolean of arithmetic of a column the measurement
  # lacks with text.
  @false_sql "(1 = 0)"

  @typedoc "What an operand is: a condition in parentheses, the `false` above, or neither."
  @type kind :: :group | :weird | :other

  @doc """
  The comparison `tokens` make when a boolean of its own is an operand of it, as SQL with the
  checks it needs, or `:unplaced` when the double does not place it (no such operand, a
  comparison of the `time`). The errors
  of the engine are thrown as `{:deferred, body}`, the refusals as `{:refused, message}`.
  `inner` plans the condition inside a group (`tokens -> {sql, checks}`), so that its
  comparisons are typed as they are anywhere else.
  """
  @spec plan(
          list(),
          {MapSet.t(binary()), map()},
          %{timed: boolean()},
          (list() -> {binary(), list()})
        ) :: {:planned, binary(), list()} | :unplaced
  def plan(tokens, ctx, %{timed: timed}, inner) do
    env = %{ctx: ctx, timed: timed, inner: inner}

    case sides(tokens, env) do
      {left, op, right} -> against(left, op, right, env)
      nil -> :unplaced
    end
  end

  # `{{tokens, kind}, operator, {tokens, kind}}` when exactly one comparison operator stands
  # outside every parenthesis and a boolean of its own stands on one side of it; `nil` for a
  # comparison with none. A comparison chained with another (`a = b = c`) is `(a = b) = c`
  # (verified): the comparisons before the last make a group, compared with a boolean (`ok`,
  # `true`, another group); with any other operand the engine's answer is not verified and a
  # chain with a group in it is refused.
  defp sides(tokens, env) do
    case top_level_operators(tokens, 0, 0, []) do
      [{at, op}] ->
        left = kinded(Enum.take(tokens, at), env)
        right = kinded(Enum.drop(tokens, at + 1), env)
        if elem(left, 1) != :other or elem(right, 1) != :other, do: {left, op, right}

      [_first, _second | _more] = operators ->
        chain(tokens, List.last(operators), env)

      [] ->
        nil
    end
  end

  defp chain(tokens, {at, op}, env) do
    prefix = Enum.take(tokens, at)
    right = kinded(Enum.drop(tokens, at + 1), env)

    cond do
      elem(right, 1) != :other or boolean_operand?(elem(right, 0), env) ->
        {{[{:raw, "("}] ++ prefix ++ [{:raw, ")"}], :group}, op, right}

      Enum.any?(top_level_groups(tokens), &boolean_group?/1) and not absent_in?(tokens, env) ->
        chained()

      true ->
        nil
    end
  end

  defp boolean_operand?(tokens, env) do
    match?({:column, :boolean}, operand(tokens, :other, env)) or
      match?({:boolean, _value}, operand(tokens, :other, env))
  end

  defp kinded(tokens, env), do: {tokens, kind(tokens, env)}

  @spec kind(list(), map()) :: kind()
  defp kind(tokens, env) do
    cond do
      boolean_group?(tokens) -> :group
      false_arithmetic?(tokens, env) -> :weird
      true -> :other
    end
  end

  @spec chained() :: no_return()
  defp chained,
    do: throw({:refused, "unsupported InfluxQL (a comparison chained with another)"})

  defp top_level_operators([], _depth, _at, acc), do: Enum.reverse(acc)

  defp top_level_operators([{:raw, "("} | rest], depth, at, acc),
    do: top_level_operators(rest, depth + 1, at + 1, acc)

  defp top_level_operators([{:raw, ")"} | rest], depth, at, acc),
    do: top_level_operators(rest, max(depth - 1, 0), at + 1, acc)

  defp top_level_operators([{:op, op} | rest], 0, at, acc),
    do: top_level_operators(rest, 0, at + 1, [{at, op} | acc])

  defp top_level_operators([_token | rest], depth, at, acc),
    do: top_level_operators(rest, depth, at + 1, acc)

  # The parenthesised groups that stand outside every parenthesis, each as its tokens (a
  # parenthesis after a name is a call, not a group).
  defp top_level_groups(tokens), do: top_level_groups(tokens, nil, 0, [], [])

  defp top_level_groups([], _previous, _depth, _group, acc), do: Enum.reverse(acc)

  defp top_level_groups([{:raw, "("} = token | rest], previous, 0, _group, acc) do
    if match?({:ident, _name}, previous),
      do: top_level_groups(rest, token, 1, :call, acc),
      else: top_level_groups(rest, token, 1, [token], acc)
  end

  defp top_level_groups([{:raw, "("} = token | rest], _previous, depth, group, acc),
    do: top_level_groups(rest, token, depth + 1, push(group, token), acc)

  defp top_level_groups([{:raw, ")"} = token | rest], _previous, 1, group, acc) do
    case group do
      :call -> top_level_groups(rest, token, 0, [], acc)
      _group -> top_level_groups(rest, token, 0, [], [Enum.reverse([token | group]) | acc])
    end
  end

  defp top_level_groups([{:raw, ")"} = token | rest], _previous, depth, group, acc),
    do: top_level_groups(rest, token, max(depth - 1, 0), push(group, token), acc)

  defp top_level_groups([token | rest], _previous, depth, group, acc),
    do: top_level_groups(rest, token, depth, push(group, token), acc)

  defp push(:call, _token), do: :call
  defp push(group, token), do: [token | group]

  @flipped %{
    "=" => "=",
    "!=" => "!=",
    "<>" => "<>",
    "<" => ">",
    "<=" => ">=",
    ">" => "<",
    ">=" => "<="
  }

  @doc """
  A comparison with a group on its left and none on its right, turned round (`(w > 1) = x` is
  `x = (w > 1)`): the SQL engine reads a comparison that starts with a parenthesis around a
  condition only as the condition, so a comparison it answers itself (one of the `time`) has
  the group last.
  """
  @spec group_last(list()) :: list()
  def group_last(tokens) do
    with [{at, op}] <- top_level_operators(tokens, 0, 0, []),
         {:ok, flipped} <- Map.fetch(@flipped, op),
         {left, right} = {Enum.take(tokens, at), Enum.drop(tokens, at + 1)},
         true <- boolean_group?(left) and not boolean_group?(right) do
      right ++ [{:op, flipped}] ++ left
    else
      _no_group_first -> tokens
    end
  end

  # ---------------------------------------------------------------------------
  # What the comparison comes to
  # ---------------------------------------------------------------------------

  defp against({left, left_kind}, op, {right, right_kind}, env)
       when left_kind != :other and right_kind != :other,
       do: pair({left, left_kind}, op, {right, right_kind}, env)

  defp against({left, left_kind}, op, {right, :other}, env),
    do: against_boolean({left, left_kind}, op, right, :left, env)

  defp against({left, :other}, op, {right, right_kind}, env),
    do: against_boolean({right, right_kind}, op, left, :right, env)

  # Two booleans of their own: no row is true for an ordering, the two evaluate for equality.
  # (The operator is one of the comparisons: `=~` and `!~` take a regular expression, which is
  # no boolean of its own, so a pair is never set by them.)
  defp pair({left, left_kind}, op, {right, right_kind}, env) do
    cond do
      op in @ordering_ops ->
        never()

      absent_group?(left, left_kind, env) or absent_group?(right, right_kind, env) ->
        never()

      env.timed and :group in [left_kind, right_kind] ->
        refuse_timed()

      op == "=" ->
        same(sql_of(left, left_kind, env), sql_of(right, right_kind, env))

      true ->
        different(sql_of(left, left_kind, env), sql_of(right, right_kind, env))
    end
  end

  defp same({a, a_checks}, {b, b_checks}),
    do: {:planned, "((#{a} AND #{b}) OR (NOT #{a} AND NOT #{b}))", a_checks ++ b_checks}

  defp different({a, a_checks}, {b, b_checks}),
    do: {:planned, "((#{a} AND NOT #{b}) OR (NOT #{a} AND #{b}))", a_checks ++ b_checks}

  defp never, do: {:planned, @false_sql, []}

  # The SQL of a boolean of its own: the condition inside a group, planned as the condition it
  # is, in parentheses; the false.
  defp sql_of(group, :group, env) do
    {sql, checks} = env.inner.(unwrap(group))
    {"(" <> sql <> ")", checks}
  end

  defp sql_of(_tokens, :weird, _env), do: {@false_sql, []}

  # A boolean of its own and the other side, which `side` says stood where.
  defp against_boolean({tokens, kind}, op, other, side, env) do
    if absent_group?(tokens, kind, env) do
      never()
    else
      case operand(other, kind, env) do
        {:column, :unsigned} -> clash(op, side)
        {:column, :boolean} when op in @equality_ops -> column_equal(tokens, kind, op, other, env)
        {:boolean, value} when op in @equality_ops -> constant_equal(tokens, kind, op, value, env)
        _never_true -> never()
      end
    end
  end

  # `ok = (w > 1)`: the SQL reads the column first, the boolean second.
  defp column_equal(_tokens, :group, _op, _column, %{timed: true}), do: refuse_timed()

  defp column_equal(tokens, kind, op, column, %{ctx: {tags, types}} = env) do
    {sql, checks} = sql_of(tokens, kind, env)
    {:planned, "#{InfluxQLTyped.plain(unwrap(column), tags, types)} #{op} #{sql}", checks}
  end

  # `(w > 1) = true` is the group, `(w > 1) = false` its negation, `!=` the other way.
  defp constant_equal(tokens, kind, op, value, env) do
    {sql, checks} = sql_of(tokens, kind, env)
    wanted = if op == "=", do: value, else: not value
    {:planned, if(wanted, do: sql, else: "NOT " <> sql), checks}
  end

  # With a comparison of the `time` in the condition the engine splits the time out and rebuilds
  # the rest, and an equality of two booleans behind another condition of the statement does not
  # survive it (verified: `ok = (w > 1) AND time > 0` is read as written, `time > 0 AND ok =
  # (w > 1)` keeps the points both are true for, `time > 0 AND ok != (w > 2)` none).
  @spec refuse_timed() :: no_return()
  defp refuse_timed,
    do:
      throw(
        {:refused,
         "unsupported InfluxQL (an equality of two booleans beside a comparison of the time)"}
      )

  @spec clash(binary(), :left | :right) :: no_return()
  defp clash(op, side) do
    {left, right} = if side == :left, do: {"Boolean", "UInt64"}, else: {"UInt64", "Boolean"}
    op = if op == "<>", do: "!=", else: op

    throw(
      {:deferred,
       "Error during planning: Cannot infer common argument type for comparison " <>
         "operation #{left} #{op} #{right}"}
    )
  end

  # ---------------------------------------------------------------------------
  # The other side
  # ---------------------------------------------------------------------------

  # What the side that is no boolean of its own is: `{:column, type}`, `{:boolean, value}` for
  # `true` or `false`, `:constant` for a number, a string or a regular expression,
  # `:expression` for arithmetic the engine reads as no boolean. (The columns of the
  # measurement are `tags` and `types`: the caller always knows them.)
  defp operand(tokens, kind, %{ctx: {tags, types}} = env) do
    tokens = unwrap(tokens)

    case tokens do
      [{:ident, name}] ->
        cond do
          MapSet.member?(tags, name) -> {:column, :tag}
          Map.has_key?(types, name) -> {:column, Map.fetch!(types, name)}
          true -> {:column, :absent}
        end

      [{:raw, word}] ->
        boolean_word(word)

      [{kind_of_constant, _value}] when kind_of_constant in [:number, :regex, :str] ->
        :constant

      [{:raw, sign}, {:number, _text}] when sign in ["-", "+"] ->
        :constant

      _expression ->
        expression(tokens, kind, env)
    end
  end

  # The only word that stands alone as an operand is `true` or `false` (the lexer makes a word
  # of nothing else a `:raw` token but `now()`, which the engine's "not implemented" answers
  # before the condition is planned, and the connectives, which are no operand).
  defp boolean_word(word), do: {:boolean, String.downcase(word) == "true"}

  # Arithmetic of numbers, strings, columns and the math functions. One with a column the
  # measurement lacks is null (no row), one with an unsigned column in it is refused (the
  # planner's error differs by the other operand), and so is a tag with text beside the false
  # of arithmetic (the planner coerces it). So is arithmetic with any other operand, a duration
  # or a boolean constant (verified: its answer is no row, the planner's coercion error or, with
  # a column the measurement lacks, the false above, by operands the double does not tell).
  defp expression(tokens, kind, %{ctx: {tags, types}}) do
    {columns, calls} = InfluxQLTokens.split_names(tokens)

    cond do
      not Enum.all?(tokens, &arithmetic_token?/1) or
          not Enum.all?(calls, &InfluxQLText.math_function?/1) ->
        refuse()

      Enum.any?(columns, &InfluxQLExpr.absent?(&1, types, tags)) ->
        :expression

      Enum.any?(columns, &(Map.get(types, &1) == :unsigned and not MapSet.member?(tags, &1))) ->
        refuse()

      kind == :weird and Enum.any?(columns, &MapSet.member?(tags, &1)) ->
        refuse()

      true ->
        :expression
    end
  end

  defp arithmetic_token?({kind, _value}) when kind in [:number, :str, :ident], do: true
  defp arithmetic_token?({:raw, op}), do: op in ["+", "-", "*", "/", "%", "(", ")", ","]
  defp arithmetic_token?(_token), do: false

  @spec refuse() :: no_return()
  defp refuse,
    do:
      throw(
        {:refused,
         "unsupported InfluxQL (an expression compared with a condition in parentheses)"}
      )

  # A group that is one comparison of a column the measurement lacks (`(nosuch > 1)`) is a null
  # (verified: `ok = (nosuch > 1)` keeps no point), where in `AND` or `OR` such a comparison is
  # false (`(nosuch > 1 OR ok) = ok` keeps every point): the condition of the group is planned
  # as it is anywhere else then.
  defp absent_group?(tokens, :group, env) do
    absent_in?(tokens, env) and not connective_word_inside?(unwrap(tokens))
  end

  defp absent_group?(_tokens, _kind, _env), do: false

  # Whether tokens use a column the measurement lacks.
  defp absent_in?(tokens, %{ctx: {tags, types}}) do
    {columns, _calls} = InfluxQLTokens.split_names(tokens)
    Enum.any?(columns, &InfluxQLExpr.absent?(&1, types, tags))
  end

  # Whether tokens are arithmetic of exactly a column the measurement lacks and a text operand:
  # a string, or a column that is a string, a tag or a boolean (`nosuch + 'x'`, `s * nosuch`).
  defp false_arithmetic?(tokens, %{ctx: {tags, types}}) do
    case unwrap(tokens) do
      [left, {:raw, op}, right] when op in @arithmetic_ops ->
        (absent?(left, tags, types) and text?(right, tags, types)) or
          (text?(left, tags, types) and absent?(right, tags, types))

      _not_two_operands ->
        false
    end
  end

  defp absent?({:ident, name} = token, tags, types),
    do: not InfluxQLTokens.time?(token) and InfluxQLExpr.absent?(name, types, tags)

  defp absent?(_token, _tags, _types), do: false

  defp text?({:str, _content}, _tags, _types), do: true

  defp text?({:ident, name}, tags, types),
    do: MapSet.member?(tags, name) or Map.get(types, name) in [:string, :boolean]

  defp text?(_token, _tags, _types), do: false

  # ---------------------------------------------------------------------------
  # Groups
  # ---------------------------------------------------------------------------

  @doc """
  Whether tokens are one parenthesised group, however many layers deep, that holds a
  comparison, an `AND`, an `OR` or a boolean constant.
  """
  @spec boolean_group?(list()) :: boolean()
  def boolean_group?(tokens) do
    case strip_group(tokens) do
      {:ok, inner} -> boolean_inside?(inner)
      nil -> false
    end
  end

  defp unwrap(tokens) do
    case strip_group(tokens) do
      {:ok, inner} -> inner
      nil -> tokens
    end
  end

  defp boolean_inside?([{:raw, word}]) when is_binary(word),
    do: String.downcase(word) in ["true", "false"]

  defp boolean_inside?(inner), do: connective_inside?(inner)

  # Whether an `AND` or an `OR` stands at the top of the tokens, outside every parenthesis.
  defp connective_word_inside?(tokens) do
    tokens
    |> Enum.reduce({0, false}, fn
      {:raw, "("}, {depth, found} -> {depth + 1, found}
      {:raw, ")"}, {depth, found} -> {depth - 1, found}
      {:raw, word}, {0, found} -> {0, found or String.upcase(word) in @connectives}
      _token, state -> state
    end)
    |> elem(1)
  end

  # Whether an operator or a connective stands at the top of the tokens, outside every
  # parenthesis.
  defp connective_inside?(inner) do
    inner
    |> Enum.reduce({0, false}, fn
      {:raw, "("}, {depth, found} ->
        {depth + 1, found}

      {:raw, ")"}, {depth, found} ->
        {depth - 1, found}

      {:op, _op}, {0, _found} ->
        {0, true}

      {:raw, word}, {0, found} when is_binary(word) ->
        {0, found or String.upcase(word) in @connectives}

      _token, state ->
        state
    end)
    |> elem(1)
  end

  @doc """
  The tokens inside the layers of parentheses that wrap all of `tokens` (`((a))` is `a`),
  `{:ok, inner}`, or `nil` when they are not one group (`(a) AND (b)`, `(a) + 1`, an unbalanced
  list).
  """
  @spec strip_group(list()) :: {:ok, list()} | nil
  def strip_group(tokens) do
    case InfluxQLTokens.unwrap_group(tokens) do
      {_tokens, 0} -> nil
      {inner, _layers} -> {:ok, inner}
    end
  end
end
