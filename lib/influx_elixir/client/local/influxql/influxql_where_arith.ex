defmodule InfluxElixir.Client.Local.InfluxQLWhereArith do
  @moduledoc false
  # The arithmetic of an InfluxQL `WHERE` over tags, strings and booleans, and the type of
  # arithmetic that stands alone as a condition (verified against InfluxDB 3 Core):
  #
  #   * a tag, a string or a boolean under an arithmetic operator or a minus sign makes the
  #     expression null (`- host`, `host * 2`, `usage + host`, `s + 1`, `s - s`, `-b`,
  #     `b + 1`, `'a' * 'a'`): a comparison of it, or the expression alone, keeps no point,
  #     and beside `OR` the other operand decides; a plus sign is no operation, so `+ host`
  #     is a bare tag
  #   * one exception is the `+` of two strings (fields or constants), which is
  #     concatenation: `s + s = 'xx'`, `'a' + 'a' = 'aa'`. The result compares for equality
  #     only (an ordering or a regular expression keeps no point), and a tag beside a
  #     string under `+` is the engine's coercion error, left to the SQL engine to word
  #   * a minus sign before a string or a boolean constant, and a second one before a
  #     name, are parse errors (see `InfluxQLTokens`)
  #   * arithmetic that stands alone as a condition is the planning error that names its type:
  #     an integer when both operands are, a float otherwise and for every division, a
  #     string for a concatenation
  #   * `abs()` takes one number; anything else is the engine's planning error, worded in
  #     `InfluxQLCalls`
  #
  # The types of the arithmetic are `InfluxQLFold`'s; this module asks it and shapes the answer
  # for the checks below.

  alias InfluxElixir.Client.Local.{InfluxQLCalls, InfluxQLFold, InfluxQLTokens}

  @comparison ["=", "!=", "<>", "<", "<=", ">", ">=", "=~", "!~"]
  @equality ["=", "!=", "<>"]

  @typedoc "The type of an expression: a number, a tag, a string, a boolean, a regular expression, or null."
  @type kind ::
          :integer | :float | :unsigned | :tag | :string | :boolean | :regex | :null

  @doc """
  Whether a comparison, or an expression alone, is null because a tag, a string or a boolean is
  under arithmetic.
  """
  @spec null?(list(), MapSet.t(binary()), map()) :: boolean()
  def null?(tokens, tags, types) do
    case sides(tokens) do
      {:ok, parts, op} ->
        kinds = Enum.map(parts, &side_kind(&1, tags, types))
        {:ok, :null} in kinds or (ordered?(op) and concatenation?(parts, kinds))

      :error ->
        false
    end
  end

  @doc """
  Whether a comparison sets two kinds that cannot be compared against each other (verified:
  a number against a string, a boolean or a tag, a string or a tag against a boolean, and a
  regular expression against a number or a boolean, keep no point for any operator, whatever
  the sides are: columns, constants, arithmetic or `abs()`). A side the double cannot type
  (an unsigned field, a column the measurement lacks) decides nothing.
  """
  @spec incompatible?(list(), MapSet.t(binary()), map()) :: boolean()
  def incompatible?(tokens, tags, types) do
    case sides(tokens) do
      {:ok, [left, right], op} ->
        with {:ok, left_kind} <- side_kind(left, tags, types),
             {:ok, right_kind} <- side_kind(right, tags, types) do
          clash?(op, left_kind, right_kind)
        else
          :error -> false
        end

      _single_or_unreadable ->
        false
    end
  end

  @doc """
  What an unsigned operand does to a comparison the double does not compute (verified): against
  a string that is concatenated that it is below (`u < 'a' + 'b'`, `'a' + 'b' > u`) it is not
  null as for the other numbers but the engine's comparison of text (`:text`, refused by the
  caller). `nil` for anything else. (An unsigned number against a boolean is the planning
  error `InfluxQLNested` raises before a comparison gets here, whatever the number is made of:
  its kind is `InfluxQLFold`'s.)
  """
  @spec unsigned_clash(list(), MapSet.t(binary()), map()) :: :text | nil
  def unsigned_clash(tokens, tags, types) do
    case sides(tokens) do
      {:ok, [left, right], op} -> text_clash(op, left, right, tags, types)
      _single -> nil
    end
  end

  @doc """
  A comparison of a tag over an unsigned number (`host > u`, `host >= u + 1`) written the other
  way round (`u < host`), which the SQL engine reads as the engine of InfluxQL does: the
  tag as text, so every point that has the unsigned value is kept (verified: the SQL reads the
  first order as no point at all). Any other comparison is returned as it is.
  """
  @spec tag_over_unsigned(list(), MapSet.t(binary()), map()) :: list()
  def tag_over_unsigned(tokens, tags, types) do
    with {:ok, [[{:ident, name}] = left, right], op} when op in [">", ">="] <- sides(tokens),
         true <- MapSet.member?(tags, name),
         true <- unsigned_valued?(right, types) do
      right ++ [{:op, flipped(op)}] ++ left
    else
      _other -> tokens
    end
  end

  defp flipped(">"), do: "<"
  defp flipped(">="), do: "<="

  defp text_clash(op, left, right, tags, types) do
    cond do
      op in ["<", "<="] and concatenated_text?(right, tags, types) and
          unsigned_valued?(left, types) ->
        :text

      op in [">", ">="] and concatenated_text?(left, tags, types) and
          unsigned_valued?(right, types) ->
        :text

      true ->
        nil
    end
  end

  defp concatenated_text?(tokens, tags, types),
    do: side_kind(tokens, tags, types) == {:ok, :string} and binary_plus?(tokens)

  # Whether a side is an unsigned number: it has an unsigned field in it and nothing makes it
  # a float.
  defp unsigned_valued?(tokens, types) do
    Enum.any?(tokens, &field_type?(&1, types, :unsigned)) and
      not Enum.any?(tokens, &(field_type?(&1, types, :float) or fraction?(&1)))
  end

  defp field_type?({:ident, name}, types, type), do: Map.get(types, name) == type
  defp field_type?(_token, _types, _type), do: false

  defp fraction?({:number, text}), do: not match?({_n, ""}, Integer.parse(text))
  defp fraction?(_token), do: false

  # The kinds that compare with one another.
  defp group(kind) when kind in [:integer, :float], do: :number
  defp group(kind) when kind in [:string, :tag], do: :text
  defp group(kind), do: kind

  defp clash?(op, left, right) when op in ["=~", "!~"],
    do: right == :regex and group(left) in [:number, :boolean]

  # An unsigned number is left to the engine's own errors (see `unsigned_clash/3`).
  defp clash?(_op, left, right) when :unsigned in [left, right], do: false

  # Two tags are never equal and strings and booleans have equality only (verified, in
  # parentheses and arithmetic too): an ordering of them keeps no point.
  defp clash?(_op, :tag, :tag), do: true

  defp clash?(op, left, right) when op in ["<", "<=", ">", ">="] and left == right,
    do: group(left) in [:text, :boolean]

  defp clash?(op, left, right) when op in ["<", "<=", ">", ">="],
    do: group(left) != group(right) or group(left) in [:text, :boolean]

  defp clash?(_op, left, right), do: group(left) != group(right)

  @doc """
  The tokens of a comparison with the `+` of each concatenation written `||` for the SQL, when it
  has one that compares for equality; `:none` otherwise.
  """
  @spec concatenation(list(), MapSet.t(binary()), map()) :: {:ok, list()} | :none
  def concatenation(tokens, tags, types) do
    with {:ok, parts, op} <- sides(tokens),
         true <- op in [nil | @equality],
         kinds = Enum.map(parts, &side_kind(&1, tags, types)),
         true <- concatenation?(parts, kinds) do
      {:ok, join_sides(tokens, kinds)}
    else
      _other -> :none
    end
  end

  # Whether a side that is a string has a binary `+` in it.
  defp concatenation?(parts, kinds) do
    parts
    |> Enum.zip(kinds)
    |> Enum.any?(fn {part, kind} -> kind == {:ok, :string} and binary_plus?(part) end)
  end

  # The comparison with the `+` of each side that is a string written `||`.
  defp join_sides(tokens, [kind]), do: join_side(tokens, kind)

  defp join_sides(tokens, [left_kind, right_kind]) do
    {left, [op | right]} = Enum.split_while(tokens, &(not comparison?(&1)))
    join_side(left, left_kind) ++ [op] ++ join_side(right, right_kind)
  end

  defp join_side(tokens, {:ok, :string}), do: join_plus(tokens, nil, [])
  defp join_side(tokens, _kind), do: tokens

  # A `+` between two operands is concatenation; one in front of an operand is a sign.
  defp join_plus([], _previous, acc), do: Enum.reverse(acc)

  defp join_plus([{:raw, "+"} | rest], previous, acc) do
    if operand_end?(previous),
      do: join_plus(rest, {:raw, "+"}, [{:raw, "||"} | acc]),
      else: join_plus(rest, {:raw, "+"}, acc)
  end

  defp join_plus([token | rest], _previous, acc), do: join_plus(rest, token, [token | acc])

  defp binary_plus?(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [previous, token] -> token == {:raw, "+"} and operand_end?(previous) end)
  end

  defp operand_end?({kind, _value}) when kind in [:ident, :str, :number], do: true
  defp operand_end?({:raw, word}), do: word == ")" or String.upcase(word) in ["TRUE", "FALSE"]
  defp operand_end?(_token), do: false

  defp ordered?(op), do: op in ["<", "<=", ">", ">=", "=~", "!~"]

  @doc """
  The type of an expression that stands alone as a condition and is more than one operand
  (arithmetic, signs, parentheses, `abs()`), or `nil` when it is null, the engine cannot type
  it or the double does not (a column the measurement lacks decides nothing here: an unsigned
  number made of one and a null is unsigned all the same, `InfluxQLFold`). The quotient of an
  unsigned number and text is unsigned beside a connective, and the coercion error of the
  division when it is the whole condition (`alone`).
  """
  @spec standalone(list(), MapSet.t(binary()), map(), boolean()) ::
          :integer | :unsigned | :float | :tag | :string | nil
  def standalone(tokens, tags, types, alone) do
    with false <- Enum.any?(tokens, &match?({:op, _op}, &1)),
         # A call the planner refuses is that error, before the type of a condition.
         :ok <- InfluxQLCalls.problem(tokens, {tags, types}),
         {:ok, kind} when kind in [:integer, :unsigned, :float, :tag, :string] <-
           InfluxQLFold.kind(tokens, {tags, types}, mode: if(alone, do: :alone, else: :loose)) do
      kind
    else
      _undecided -> nil
    end
  end

  # The sides of a comparison, or the whole as one side, with the operator. (A comparison with a
  # side missing never gets here: the parser of the statement fails it first.) Two comparisons
  # in a row (`n > 1 = true`) are decided by `InfluxQLNested`, not here.
  @spec sides(list()) :: {:ok, [list()], binary() | nil} | :error
  defp sides(tokens) do
    case Enum.split_while(tokens, &(not comparison?(&1))) do
      {left, [{:op, op} | right]} ->
        if Enum.any?(right, &comparison?/1), do: :error, else: {:ok, [left, right], op}

      {_whole, []} ->
        {:ok, [tokens], nil}
    end
  end

  defp comparison?({:op, op}), do: op in @comparison
  defp comparison?(_token), do: false

  # What a side comes to for the checks above, from `InfluxQLFold`: a null (a string, a tag or
  # a boolean under arithmetic) is `:null`, a regular expression `:regex`. A side the double
  # does not decide is `:error`: one with the time or a column the measurement lacks in it (the
  # planner's, `coercion_error/3`'s, and `InfluxQLNested`'s), an error of the engine, a duration.
  @spec side_kind(list(), MapSet.t(binary()), map()) :: {:ok, kind()} | :error
  defp side_kind([{:regex, _pattern}], _tags, _types), do: {:ok, :regex}

  defp side_kind(tokens, tags, types) do
    with [] <- InfluxQLTokens.absent_columns(tokens, tags, types),
         false <- Enum.any?(tokens, &InfluxQLTokens.time?/1),
         {:ok, kind} <- InfluxQLFold.kind(tokens, {tags, types}) do
      shaped(kind)
    else
      _undecided -> :error
    end
  end

  defp shaped(kind) when kind in [:integer, :float, :unsigned, :string, :tag, :boolean],
    do: {:ok, kind}

  defp shaped(kind) when kind in [:unknown, :nn, :nnf, :nz, false], do: {:ok, :null}
  defp shaped(_duration_or_time), do: :error

  @doc """
  Raises the planning error of arithmetic the engine cannot coerce (verified): an unsigned
  number beside a string, a boolean, a tag or the time under an arithmetic operator, in either
  order, worded with the Arrow type of each operand as written (`UInt64 + Utf8`), the time
  beside anything but a duration, two times, and the other errors of `InfluxQLFold`, on the
  left side first. `:ok` when nothing is wrong.
  """
  @spec check_coercion(list(), MapSet.t(binary()), map(), boolean()) :: :ok
  def check_coercion(tokens, tags, types, alone) do
    # (A comparison with the bare time on a side is split by the planner, not typed.)
    case if(InfluxQLTokens.time_comparison?(tokens), do: :error, else: sides(tokens)) do
      {:ok, [_part] = parts, nil} ->
        parts
        |> Enum.map(
          &InfluxQLFold.kind(&1, {tags, types}, mode: if(alone, do: :alone, else: :loose))
        )
        |> InfluxQLFold.raise_coercion()

      {:ok, parts, _op} ->
        ctx = {tags, types}
        loose = Enum.map(parts, &InfluxQLFold.kind(&1, ctx))

        parts
        |> Enum.zip(Enum.reverse(loose))
        |> Enum.map(fn {part, other} -> InfluxQLFold.kind(part, ctx, mode: against(other)) end)
        |> InfluxQLFold.raise_coercion()

      :error ->
        :ok
    end
  end

  # A comparison reads the quotient of an unsigned number and text as a comparison with a number
  # does when the other side is a number, as one with a boolean does beside a boolean, and as one
  # with text does beside anything else; an operand of a connective as the one with a boolean,
  # the whole condition on its own as itself (see `InfluxQLFold`).
  defp against({:ok, kind}) when kind in [:integer, :float, :unsigned], do: :strict
  defp against({:ok, :boolean}), do: :loose
  defp against(_other), do: :text
end
