defmodule InfluxElixir.Client.Local.InfluxQLTimeComparand do
  @moduledoc false
  # The error of the planner when it splits the bare `time` out of a condition and the other side
  # of the comparison is no time (verified over every kind of comparand, alone and beside
  # `AND`/`OR`, in either order of the sides): the split is the first thing the planner does with
  # a condition, so this error comes before every other one of the statement, and before the
  # `invalid expr stack` that a bare operand beside the split gives.
  #
  #   * a column, a tag, the time or a name the measurement lacks: `found symbol 'n::integer',
  #     expected now() or a literal duration, float, integer and timestamp string` (the type
  #     after `::` is the column's: `integer`, `float`, `string`, `boolean`, `unsigned`, `tag`,
  #     `timestamp` for the time itself, none for a name the measurement lacks)
  #   * a boolean: `found literal 'true', expected duration, float, integer, or timestamp string`
  #   * a function: `invalid function call 'abs'`, whatever it is given
  #   * arithmetic with one of these in it: `invalid expression "n::integer + 1": ` and the error
  #     of the first of them (`-n` is written `-1 * n::integer`, a group keeps its parentheses,
  #     the error of a group in a group is the error of the one inside)
  #   * the operator `!=`/`<>`: `invalid time comparison operator: !=`, before the comparand
  #   * a chain (`time > 0 < 1`): the comparison of the first two, which the planner types as
  #     it stands: `Timestamp(ns) > Int64` for an integer literal; when the last operand is the
  #     bare time (`time > 5 < time`, `1 < time > time`) the error of the first comparison, if
  #     it has one, else a 500 `InfluxQL internal error: expected Expr`
  #
  # What is not verified (the arithmetic of strings, durations, floats and signed numbers, which
  # the planner prints in a form the double does not tell) is `:unclear`, and the caller refuses.

  alias InfluxElixir.Client.Local.{InfluxQLError, InfluxQLTokens}

  @expected "expected now() or a literal duration, float, integer and timestamp string"
  @expected_literal "expected duration, float, integer, or timestamp string"

  @typedoc "What a comparison with the bare time comes to: nothing wrong, the error of the split (the body to raise), or what the double cannot word."
  @type answer :: :ok | {:error, binary()} | {:error, pos_integer(), binary()} | :unclear

  @doc """
  The error of the split for the comparison `tokens` (the tokens of one comparison of a
  condition), `:ok` when it is none or the comparison has no bare `time`, `{:error, body}`, or
  `:unclear`. `{:error, 500, body}` is a chain whose last operand is the bare time, which the
  engine fails with `expected Expr`.
  """
  @spec check(list(), {MapSet.t(binary()), map()}) :: answer()
  def check(tokens, ctx) do
    if InfluxQLTokens.time_comparison?(tokens),
      do: tokens |> operator_positions() |> comparison(tokens, ctx),
      else: :ok
  end

  defp operator_positions(tokens) do
    for {{:op, op}, at} <- Enum.with_index(tokens), do: {at, op}
  end

  # One comparison.
  defp comparison([{at, op}], tokens, ctx) do
    {left, [_op | right]} = Enum.split(tokens, at)
    sides(left, op, right, ctx)
  end

  # A chain: the first two operands are the comparison the planner types as it stands, unless
  # the last operand is the bare time, which it cannot place at all.
  defp comparison([{at, op}, {next, _op2} | _more], tokens, ctx) do
    {left, [_op | rest]} = Enum.split(tokens, at)
    right = Enum.take(rest, next - at - 1)

    case sides(left, op, right, ctx) do
      :ok ->
        if time_last?(tokens), do: expected_expr(), else: chain(left, op, right)

      other ->
        other
    end
  end

  defp time_last?(tokens) do
    case Enum.take(tokens, -2) do
      [{:op, _op}, last] -> InfluxQLTokens.time?(last)
      _other -> false
    end
  end

  defp expected_expr do
    {:error, 500,
     InfluxQLError.split_error("External error: InfluxQL internal error: expected Expr")}
  end

  defp sides(_left, op, _right, _ctx) when op in ["!=", "<>"],
    do:
      {:error,
       InfluxQLError.split_error("Error during planning: invalid time comparison operator: !=")}

  defp sides(_left, op, _right, _ctx) when op in ["=~", "!~"], do: :ok

  defp sides(left, _op, right, ctx) do
    comparand = if bare_time?(left), do: right, else: left

    case comparand |> InfluxQLTokens.strip_parens() |> parse(ctx) do
      :valid ->
        :ok

      :unclear ->
        :unclear

      {:invalid, message} ->
        {:error, InfluxQLError.split_error("Error during planning: " <> message)}
    end
  end

  defp bare_time?([token]), do: InfluxQLTokens.time?(token)
  defp bare_time?(_tokens), do: false

  # `time > 0 < 1`: the comparison of the time with an integer literal, whose error the planner
  # raises as the type error it is. The comparand that is no integer literal is left to the
  # caller.
  defp chain([time], op, [{:number, text}]) do
    if InfluxQLTokens.time?(time) and integer_text?(text),
      do: cannot_infer("Timestamp(ns) #{op} Int64"),
      else: :ok
  end

  defp chain(_left, _op, _right), do: :ok

  defp integer_text?(text), do: Regex.match?(~r/\A\d+\z/, text)

  defp cannot_infer(operation) do
    {:error,
     "Error during planning: Cannot infer common argument type for comparison operation " <>
       operation}
  end

  # ---------------------------------------------------------------------------
  # The comparand
  # ---------------------------------------------------------------------------

  # A node of the comparand as the planner prints it: the text, the error it raises (`nil` when
  # it is a valid time) and whether the text is one the double knows how the planner prints.
  @typep part :: {binary(), nil | :unclear | binary(), boolean()}

  defp parse(tokens, ctx) do
    case sum(tokens, ctx) do
      {:ok, {_text, nil, _clear}, []} -> :valid
      {:ok, {_text, :unclear, _clear}, []} -> :unclear
      {:ok, {_text, error, _clear}, []} -> {:invalid, error}
      _unclear -> :unclear
    end
  end

  @spec sum(list(), {MapSet.t(binary()), map()}) :: {:ok, part(), list()} | :unclear
  defp sum(tokens, ctx) do
    with {:ok, left, rest} <- product(tokens, ctx),
         do: more(rest, left, ["+", "-"], &product/2, ctx)
  end

  defp product(tokens, ctx) do
    with {:ok, left, rest} <- factor(tokens, ctx),
         do: more(rest, left, ["*", "/"], &factor/2, ctx)
  end

  defp more([{:raw, op} | rest] = tokens, left, ops, next, ctx) do
    if op in ops do
      with {:ok, right, after_right} <- next.(rest, ctx),
           do: more(after_right, binary(left, op, right), ops, next, ctx)
    else
      {:ok, left, tokens}
    end
  end

  defp more(tokens, left, _ops, _next, _ctx), do: {:ok, left, tokens}

  # An expression that holds an error is that error, with the expression it is in.
  defp binary({left_text, left_error, left_clear}, op, {right_text, right_error, right_clear}) do
    text = left_text <> " " <> op <> " " <> right_text
    clear = left_clear and right_clear

    case left_error || right_error do
      nil -> {text, nil, clear}
      :unclear -> {text, :unclear, clear}
      error when clear -> {text, "invalid expression \"#{text}\": #{error}", clear}
      _unwordable -> {text, :unclear, clear}
    end
  end

  # A sign before a number is not verified; before anything else it is the product with -1.
  defp factor([{:raw, sign}, {:number, _text} | rest], _ctx) when sign in ["-", "+"],
    do: {:ok, {"?", nil, false}, rest}

  defp factor([{:raw, "+"} | rest], ctx), do: factor(rest, ctx)

  defp factor([{:raw, "-"} | rest], ctx) do
    with {:ok, operand, after_operand} <- factor(rest, ctx),
         do: {:ok, binary({"-1", nil, true}, "*", operand), after_operand}
  end

  defp factor([{:raw, "("} | rest], ctx) do
    case sum(rest, ctx) do
      {:ok, {text, error, clear}, [{:raw, ")"} | after_group]} ->
        {:ok, {"(" <> text <> ")", error, clear and not String.starts_with?(text, "(")},
         after_group}

      _unclear ->
        :unclear
    end
  end

  defp factor([{:number, text} | rest], _ctx) do
    {:ok, {text, nil, Regex.match?(~r/\A\d+\z/, text)}, rest}
  end

  defp factor([{:ident, name}, {:raw, "("} | rest], ctx) do
    with {:ok, arguments, after_call} <- arguments(rest, ctx, []) do
      text = String.downcase(name) <> "(" <> Enum.map_join(arguments, ", ", &elem(&1, 0)) <> ")"
      clear = Enum.all?(arguments, &elem(&1, 2))

      {:ok, {text, "invalid function call '#{String.downcase(name)}'", clear}, after_call}
    end
  end

  defp factor([{:ident, name} = token | rest], {tags, types}) do
    shown =
      cond do
        InfluxQLTokens.time?(token) -> "time::timestamp"
        MapSet.member?(tags, name) -> name <> "::tag"
        Map.has_key?(types, name) -> name <> "::" <> Atom.to_string(Map.fetch!(types, name))
        true -> name
      end

    {:ok, {shown, "found symbol '#{shown}', #{@expected}", true}, rest}
  end

  defp factor([{:raw, "now()"} | rest], _ctx), do: {:ok, {"now()", nil, true}, rest}

  defp factor([{:raw, word} | rest], _ctx) do
    if InfluxQLTokens.boolean_word?(word) do
      shown = String.downcase(word)
      {:ok, {shown, "found literal '#{shown}', #{@expected_literal}", false}, rest}
    else
      :unclear
    end
  end

  # (A string or a duration is a time or another error of the planner's, its text unverified.)
  defp factor([{kind, _value} | rest], _ctx) when kind in [:str, :param, :regex],
    do: {:ok, {"?", nil, false}, rest}

  defp factor([{:duration, _total, _text} | rest], _ctx), do: {:ok, {"?", nil, false}, rest}

  defp arguments([{:raw, ")"} | rest], _ctx, []), do: {:ok, [], rest}

  defp arguments(tokens, ctx, acc) do
    with {:ok, argument, rest} <- sum(tokens, ctx) do
      case rest do
        [{:raw, ","} | more] -> arguments(more, ctx, [argument | acc])
        [{:raw, ")"} | more] -> {:ok, Enum.reverse([argument | acc]), more}
      end
    end
  end
end
