defmodule InfluxElixir.Client.Local.InfluxQLNested do
  @moduledoc false
  # Classifies a comparison with a boolean of its own as an operand, as the engine plans it
  # (verified over every operator and every type of the other side). It only classifies: the
  # SQL of a classification is written by `InfluxQLWhere`.
  #
  #   * a condition in parentheses (`v > (w > 1)`, `ok = (n > 1 AND u > 1)`, `(w > 1) = (u >
  #     1)`, `true = (w > 1)`), a boolean operand like `true`
  #   * the false of arithmetic of a column the measurement lacks and text, a boolean, a
  #     duration or the time (`nosuch + 'x'`, `s * nosuch`, `nosuch + 1h`, `-nosuch + 'x'`,
  #     `nosuch + nosuch2 + 'x'`; see `InfluxQLArithType`): the engine reads it as `false`, a
  #     boolean
  #     that is no null (`nosuch + 'x' = ok` keeps the points `ok` is false for, `nosuch + 'x'
  #     <> true` all of them)
  #   * a comparison chained with another, `a = b = c`, which is `(a = b) = c` (verified): the
  #     comparisons before the last are a condition in parentheses
  #
  # The engine does not coerce the other side to a boolean first, so the arithmetic of the other
  # side is no error here (`'x' + v > (w > 1)` keeps no row, where `'x' + v > 1` is the
  # coercion error); the planner's coercion errors of arithmetic are raised all the same
  # (`host + 'a' = (w > 1)` is `Dictionary(Int32, Utf8) + Utf8`):
  #
  #   * a column or expression that is no boolean never equals the boolean nor orders against it:
  #     no row is true (a tag, a string, a number, a column the measurement lacks, arithmetic of
  #     them)
  #   * an unsigned column is the planner's error naming `UInt64` and `Boolean` in the order
  #     written (without the `type_coercion` prefix)
  #   * a boolean (a boolean column, `true`, `false`, another of these) is ordered against it as
  #     no row is true, and compared for equality as the two evaluate
  #
  # `classify/3` says which of these a comparison is, over data (`classification()`); the SQL is
  # written by `InfluxQLWhere`, which plans the conditions inside the groups. What the double
  # cannot tell from the engine is refused by name: arithmetic with an unsigned column in it
  # that has no column the measurement lacks, a group beside a duration, an equality of two
  # booleans beside a comparison of the time.

  alias InfluxElixir.Client.Local.{
    InfluxQLArithType,
    InfluxQLError,
    InfluxQLText,
    InfluxQLTokens
  }

  @ordering_ops ["<", "<=", ">", ">="]
  @equality_ops ["=", "!=", "<>"]
  @connectives ["AND", "OR"]

  # The operator a comparison has when its sides are turned round.
  @flipped %{
    "=" => "=",
    "!=" => "!=",
    "<>" => "<>",
    "<" => ">",
    "<=" => ">=",
    ">" => "<",
    ">=" => "<="
  }

  @typedoc "A boolean of its own: the tokens inside a condition in parentheses, or the false."
  @type operand :: {:group, list()} | {:node, tuple()} | false

  @typedoc """
  What a comparison with a boolean of its own comes to: no row is true (`:never`); two booleans
  that are equal or not (`:same`, `:different`); a boolean column against one (`{:column,
  operand, operator, column_name}`: `ok = (w > 1)`); one against `true` or `false`
  (`{:constant, operand, wanted}`: the operand itself, or its negation).
  """
  @type classification ::
          :never
          | {:same | :different, operand(), operand()}
          | {:column, operand(), binary(), binary()}
          | {:constant, operand(), boolean()}

  @typep ctx :: {MapSet.t(binary()), map()}
  @typep side :: {list(), :group | false | :other, term()}

  @doc """
  What the comparison `tokens` come to when a boolean of its own is an operand of it, or when
  arithmetic with a column the measurement lacks in it decides it (a null; a null number with
  an unsigned one, which is the planner's error beside a boolean), or `:unplaced` when the
  double does not place it (no such operand; with `time` in a condition in parentheses or in
  an operand that is no false, the SQL of the time). The errors of the engine are thrown as
  `{:deferred, body}` or `{:refused, {:engine, 400, body}}`, the refusals as `{:refused,
  message}`. `timed` says whether an equality of two booleans stands behind a comparison of the
  time in the statement.
  """
  @spec classify(list(), ctx(), %{timed: boolean(), alone: boolean()}) ::
          classification() | :unplaced
  def classify(tokens, ctx, flags) do
    with {left, op, right} <- operands(tokens),
         {left, right} = clash_before_division(side(left, ctx), side(right, ctx), ctx, flags),
         false <- time_comparison?(left, right),
         :ok <- InfluxQLArithType.raise_first_error([elem(left, 2), elem(right, 2)]) do
      cond do
        timed_side?(left, right) -> timed_group(left, right, ctx)
        own_boolean?(left, right) -> against(left, op, right, ctx, flags)
        true -> arithmetic(left, op, right, ctx)
      end
    else
      _unplaced -> :unplaced
    end
  end

  # An unsigned number that waits for the error of a division (`u + u / s`, `u / u / b`) beside a
  # boolean is the comparison's error, where the comparison is not the whole condition: the
  # planner finds `UInt64 = Boolean` before the coercion of the division (verified: `u + u / s =
  # b OR n > 1`, in either order, and `u + u / s = b AND ...`; on its own the division's error is
  # the engine's).
  defp clash_before_division(
         {lt, lk, lf} = left,
         {rt, rk, rf} = right,
         {_tags, types} = ctx,
         flags
       ) do
    if flags.alone do
      {left, right}
    else
      {
        if(pending_beside_boolean?(lf, lt, rt, ctx, types),
          do: {lt, lk, {:ok, :unsigned}},
          else: left
        ),
        if(pending_beside_boolean?(rf, rt, lt, ctx, types),
          do: {rt, rk, {:ok, :unsigned}},
          else: right
        )
      }
    end
  end

  defp pending_beside_boolean?({:late, class, _body}, tokens, other, ctx, types)
       when class in [:division, :comparison],
       do: boolean_operand?(other, types) and InfluxQLArithType.pending_unsigned?(tokens, ctx)

  defp pending_beside_boolean?(_fold, _tokens, _other, _ctx, _types), do: false

  # A comparison with the `time` itself on a side is read by the split of the time out of the
  # condition (its comparand is a time, `now()` or a duration, whatever else it holds), not by
  # the types of its arithmetic (verified: `time > 1 + time` is "found symbol", not a coercion).
  defp time_comparison?({left, _lk, _lf}, {right, _rk, _rf}),
    do: Enum.any?([left, right], &(unwrap(&1) |> bare_time?()))

  defp bare_time?([token]), do: InfluxQLTokens.time?(token)
  defp bare_time?(_tokens), do: false

  # The two sides of the comparison, split at the last operator outside every parenthesis: a
  # chain `a = b = c` is `(a = b) = c` (verified), so what is before the last operator is a
  # condition in parentheses. `nil` for a text with no operator.
  defp operands(tokens) do
    case InfluxQLTokens.at_top_level(tokens, &match?({:op, _op}, &1)) do
      [] ->
        nil

      [{at, {:op, op}}] ->
        {Enum.take(tokens, at), op, Enum.drop(tokens, at + 1)}

      operators ->
        {at, {:op, op}} = List.last(operators)
        {[{:raw, "("}] ++ Enum.take(tokens, at) ++ [{:raw, ")"}], op, Enum.drop(tokens, at + 1)}
    end
  end

  # A side with what the engine makes of it: a condition in parentheses, the false of arithmetic
  # (see `InfluxQLArithType`), or neither, with the arithmetic it comes to.
  @spec side(list(), ctx()) :: side()
  defp side(tokens, ctx) do
    if boolean_group?(tokens) do
      {tokens, :group, :unread}
    else
      case InfluxQLArithType.kind(tokens, ctx) do
        {:ok, :false_constant} = fold -> {tokens, false, fold}
        fold -> {tokens, :other, fold}
      end
    end
  end

  # A condition in parentheses, or an operand that is no false, with the time in it: the SQL of
  # the time reads the comparison.
  defp timed_side?(left, right) do
    Enum.any?([left, right], fn {tokens, kind, fold} ->
      kind != false and fold != {:ok, :unsigned} and Enum.any?(tokens, &InfluxQLTokens.time?/1)
    end)
  end

  # The SQL of the time reads a condition in parentheses that has the time in it (the engine
  # does not split the time out of it, and plans its comparisons by their types: `time > 0` there
  # is a type error). A column the measurement lacks in it makes the SQL engine answer nothing
  # before it types the time: refused by name.
  defp timed_group(left, right, {tags, types}) do
    if Enum.any?([left, right], fn {tokens, kind, _fold} ->
         kind == :group and InfluxQLTokens.absent_columns(tokens, tags, types) != []
       end),
       do:
         InfluxQLError.refuse(
           "a column the measurement lacks beside a time in a condition in parentheses"
         ),
       else: :unplaced
  end

  defp own_boolean?({_l, left, _lf}, {_r, right, _rf}), do: [left, right] != [:other, :other]

  # Neither side is a boolean of its own: arithmetic may still decide the comparison. A null
  # (`nosuch + 1h`, `'x' + 1`) keeps no row; an unsigned number (what an unsigned column and a
  # division by text make, or a null integer beside an unsigned column) is the planner's error
  # beside a boolean. (The rest is the caller's.) A null that a division by text made of an
  # unsigned number (`f + u / s`) is null beside a boolean only: beside anything else it is the
  # coercion error of the division, the caller's.
  defp arithmetic({left, _lk, left_fold}, op, {right, _rk, right_fold}, {tags, types} = ctx) do
    cond do
      nullish?(left_fold) or nullish?(right_fold) ->
        cond do
          pending?(left, left_fold, right_fold, ctx) or
              pending?(right, right_fold, left_fold, ctx) ->
            :unplaced

          unsigned_column?(left ++ right, tags, types) ->
            :never

          true ->
            :unplaced
        end

      left_fold == {:ok, :unsigned} ->
        unsigned_beside(right, op, :right, {left, ctx})

      right_fold == {:ok, :unsigned} ->
        unsigned_beside(left, op, :left, {right, ctx})

      true ->
        :unplaced
    end
  end

  defp nullish?({:ok, kind}), do: InfluxQLArithType.null?(kind)
  defp nullish?(_fold), do: false

  # Whether a side is null only because a division is pending, and the other side is a number.
  defp pending?(tokens, fold, other_fold, ctx) do
    nullish?(fold) and numeric?(other_fold) and
      match?({:late, _class, _body}, InfluxQLArithType.kind(tokens, ctx, mode: :strict))
  end

  defp numeric?({:ok, kind}), do: kind in [:integer, :float, :unsigned]
  defp numeric?(_fold), do: false

  defp unsigned_column?(tokens, tags, types) do
    {columns, _calls} = InfluxQLTokens.split_names(tokens)
    Enum.any?(columns, &(Map.get(types, &1) == :unsigned and not MapSet.member?(tags, &1)))
  end

  # An unsigned number made of a column the measurement lacks and an unsigned one (`nosuch + 1 +
  # u`).
  defp unsigned_null?(tokens, {tags, types}),
    do: InfluxQLTokens.absent_columns(tokens, tags, types) != []

  # The unsigned side against `other`: the planner's error when that is a boolean standing on
  # side `side` of the comparison. Against anything else no row is true when the unsigned number
  # has a column the measurement lacks in it, else the comparison is the caller's.
  defp unsigned_beside(other, op, side, {unsigned, {tags, types}}) do
    cond do
      boolean_operand?(other, types) -> clash(op, side)
      unsigned_null?(unsigned, {tags, types}) -> :never
      true -> :unplaced
    end
  end

  defp boolean_operand?(tokens, types) do
    case unwrap(tokens) do
      [{:ident, name}] -> Map.get(types, name) == :boolean
      [{:raw, word}] -> InfluxQLTokens.boolean_word?(word)
      _expression -> false
    end
  end

  @doc """
  A comparison with a group on its left and none on its right, turned round (`(w > 1) = x` is
  `x = (w > 1)`): the SQL engine reads a comparison that starts with a parenthesis around a
  condition only as the condition, so a comparison it answers itself (one of the `time`) has
  the group last.
  """
  @spec group_last(list()) :: list()
  def group_last(tokens) do
    with [{at, {:op, op}}] <- InfluxQLTokens.at_top_level(tokens, &match?({:op, _op}, &1)),
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

  @spec against(side(), binary(), side(), ctx(), map()) :: classification()
  defp against({_l, left_kind, _lf} = left, op, {_r, right_kind, _rf} = right, ctx, flags)
       when left_kind != :other and right_kind != :other,
       do: pair(left, op, right, ctx, flags)

  defp against(left, op, {_r, :other, _rf} = right, ctx, flags),
    do: with_boolean(left, op, right, :left, ctx, flags)

  defp against({_l, :other, _lf} = left, op, right, ctx, flags),
    do: with_boolean(right, op, left, :right, ctx, flags)

  # Two booleans of their own: no row is true for an ordering, the two evaluate for equality.
  # (The operator is one of the comparisons: `=~` and `!~` take a regular expression, which is
  # no boolean of its own, so a pair is never set by them.)
  defp pair({left, left_kind, _lf}, op, {right, right_kind, _rf}, ctx, flags) do
    cond do
      op in @ordering_ops ->
        :never

      absent_group?(left, left_kind, ctx) or absent_group?(right, right_kind, ctx) ->
        :never

      flags.timed and :group in [left_kind, right_kind] ->
        refuse_timed()

      true ->
        {if(op == "=", do: :same, else: :different), operand(left, left_kind),
         operand(right, right_kind)}
    end
  end

  # The boolean of its own and the other side, which `side` says stood where.
  defp with_boolean({tokens, kind, _fold}, op, {other, :other, fold}, side, ctx, flags) do
    if absent_group?(tokens, kind, ctx) do
      :never
    else
      case other_operand(other, fold, ctx) do
        {:column, _name, :unsigned} ->
          clash(op, side)

        :unsigned ->
          clash(op, side)

        {:column, name, :boolean} when op in @equality_ops ->
          column_equal(tokens, kind, op, name, flags)

        {:boolean, value} when op in @equality_ops ->
          constant_equal(tokens, kind, op, value)

        _never_true ->
          :never
      end
    end
  end

  # `ok = (w > 1)`: the SQL reads the column first, the boolean second.
  defp column_equal(_tokens, :group, _op, _name, %{timed: true}), do: refuse_timed()

  defp column_equal(tokens, kind, op, name, _flags),
    do: {:column, operand(tokens, kind), op, name}

  # `(w > 1) = true` is the group, `(w > 1) = false` its negation, `!=` the other way.
  defp constant_equal(tokens, kind, op, value),
    do: {:constant, operand(tokens, kind), if(op == "=", do: value, else: not value)}

  # A condition with a duration in it is no condition the SQL engine reads as the engine does
  # (a number against a duration is false there, the SQL raises its own error).
  defp operand([{:cond_group, node, _item}], :group), do: {:node, node}

  defp operand(tokens, :group) do
    inner = unwrap(tokens)

    if Enum.any?(inner, &match?({:duration, _total, _text}, &1)),
      do: InfluxQLError.refuse("a duration beside a condition in parentheses"),
      else: {:group, inner}
  end

  defp operand(_tokens, false), do: false

  # With a comparison of the `time` in the condition the engine splits the time out and rebuilds
  # the rest, and an equality of two booleans behind another condition of the statement does not
  # survive it (verified: `ok = (w > 1) AND time > 0` is read as written, `time > 0 AND ok =
  # (w > 1)` keeps the points both are true for, `time > 0 AND ok != (w > 2)` none).
  @spec refuse_timed() :: no_return()
  defp refuse_timed,
    do: InfluxQLError.refuse("an equality of two booleans beside a comparison of the time")

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

  # What the side that is no boolean of its own is: `{:column, name, type}`, `{:boolean, value}`
  # for `true` or `false`, `:constant` for a number, a string or a regular expression,
  # `:unsigned` for arithmetic of an unsigned number and a null integer, `:expression` for
  # arithmetic the engine reads as no boolean. (The columns of the measurement are `tags` and
  # `types`: the caller always knows them.)
  defp other_operand(tokens, fold, ctx) do
    case unwrap(tokens) do
      [{:ident, name}] ->
        column(name, ctx)

      # The only word that stands alone as an operand is `true` or `false` (the lexer makes a
      # word of nothing else a `:raw` token but `now()`, which the engine's "not implemented"
      # answers before the condition is planned, and the connectives, which are no operand).
      [{:raw, word}] ->
        {:boolean, String.downcase(word) == "true"}

      [{:number, text}] ->
        number(text, 1)

      [{kind, _value}] when kind in [:regex, :str] ->
        :constant

      [{:raw, sign}, {:number, text}] when sign in ["-", "+"] ->
        number(text, if(sign == "-", do: -1, else: 1))

      expression ->
        expression(expression, fold, ctx)
    end
  end

  # A number written past the signed range is an unsigned constant (`9223372036854775808 =
  # (n > 1)` is the planner's `UInt64 = Boolean`).
  defp number(text, sign),
    do: if(InfluxQLArithType.number_kind(text, sign) == :unsigned, do: :unsigned, else: :constant)

  defp column(name, {tags, types}) do
    case {MapSet.member?(tags, name), Map.fetch(types, name)} do
      {true, _type} -> {:column, name, :tag}
      {false, {:ok, type}} -> {:column, name, type}
      {false, :error} -> {:column, name, :absent}
    end
  end

  # Arithmetic of numbers, strings, columns and the math functions. One that comes to a null
  # (a column the measurement lacks in it, see `InfluxQLArithType`) keeps no row; one with an
  # unsigned column in it is refused (the planner's error differs by the other operand), and
  # so is arithmetic with any other operand, a duration or a boolean constant, when no column
  # the measurement lacks is in it (verified: its answer is no row or the planner's coercion
  # error, by operands the double does not tell).
  defp expression(tokens, {:ok, :unsigned}, {tags, types} = ctx) do
    cond do
      # An unsigned number made of a column the measurement lacks and an unsigned one is typed
      # as an unsigned column is (verified: `(w > 1) = nosuch + 1 + u` is the planner's
      # `Boolean = UInt64`), and so is one made of constants alone, an integer past the signed
      # range in it (`9223372036854775808 + 1`, `-(9223372036854775808)`, `1 *
      # 18446744073709551615`, `abs(9223372036854775808)`).
      unsigned_null?(tokens, ctx) or constant?(tokens) -> :unsigned
      # One made of no unsigned column (an integer past the signed range beside a tag, a
      # quotient by text) is unsigned all the same; one with an unsigned column is refused.
      not unsigned_column?(tokens, tags, types) -> :unsigned
      true -> arithmetic_expression(tokens, tags, types)
    end
  end

  defp expression(tokens, fold, {tags, types}) do
    if nullish?(fold), do: :expression, else: arithmetic_expression(tokens, tags, types)
  end

  # Whether no column is read (the names of calls are no column).
  defp constant?(tokens), do: match?({[], _calls}, InfluxQLTokens.split_names(tokens))

  defp arithmetic_expression(tokens, tags, types) do
    {columns, calls} = InfluxQLTokens.split_names(tokens)

    cond do
      not Enum.all?(tokens, &arithmetic_token?/1) or
          not Enum.all?(calls, &InfluxQLText.math_function?/1) ->
        refuse_expression()

      InfluxQLTokens.absent_columns(tokens, tags, types) != [] ->
        :expression

      Enum.any?(columns, &(Map.get(types, &1) == :unsigned and not MapSet.member?(tags, &1))) ->
        refuse_expression()

      true ->
        :expression
    end
  end

  defp arithmetic_token?({kind, _value}) when kind in [:number, :str, :ident], do: true
  defp arithmetic_token?({:raw, op}), do: op in ["+", "-", "*", "/", "%", "(", ")", ","]
  defp arithmetic_token?(_token), do: false

  @spec refuse_expression() :: no_return()
  defp refuse_expression,
    do: InfluxQLError.refuse("an expression compared with a condition in parentheses")

  # A group that is one comparison of a column the measurement lacks (`(nosuch > 1)`) is a null
  # (verified: `ok = (nosuch > 1)` keeps no point), where in `AND` or `OR` such a comparison is
  # false (`(nosuch > 1 OR ok) = ok` keeps every point): the condition of the group is planned
  # as it is anywhere else then.
  defp absent_group?(tokens, :group, {tags, types}) do
    InfluxQLTokens.absent_columns(tokens, tags, types) != [] and
      not connective_inside?(unwrap(tokens), false)
  end

  defp absent_group?(_tokens, _kind, _ctx), do: false

  # ---------------------------------------------------------------------------
  # Groups
  # ---------------------------------------------------------------------------

  @doc """
  Whether tokens are one parenthesised group, however many layers deep, that holds a
  comparison, an `AND`, an `OR` or a boolean constant.
  """
  @spec boolean_group?(list()) :: boolean()
  def boolean_group?([{:cond_group, _node, _item}]), do: true

  def boolean_group?(tokens) do
    case strip_group(tokens) do
      {:ok, [{:raw, word}]} when is_binary(word) -> String.downcase(word) in ["true", "false"]
      {:ok, inner} -> connective_inside?(inner, true)
      nil -> false
    end
  end

  defp unwrap(tokens) do
    case strip_group(tokens) do
      {:ok, inner} -> inner
      nil -> tokens
    end
  end

  # Whether an `AND` or an `OR` stands at the top of the tokens, outside every parenthesis; with
  # `operators?` a comparison operator makes a condition as well.
  defp connective_inside?(tokens, operators?) do
    tokens
    |> InfluxQLTokens.at_top_level(fn
      {:op, _op} -> operators?
      {:raw, word} -> String.upcase(word) in @connectives
      _token -> false
    end)
    |> Enum.any?()
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
