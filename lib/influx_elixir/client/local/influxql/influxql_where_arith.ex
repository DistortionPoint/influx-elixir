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
  # The types of the arithmetic are `InfluxQLArithType`'s; this module asks it and shapes the
  # answer
  # for the checks below.

  alias InfluxElixir.Client.Local.{InfluxQLArithType, InfluxQLTokens}

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
  its kind is `InfluxQLArithType`'s.)
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
  defp operand_end?({:raw, word}), do: word == ")" or InfluxQLTokens.boolean_word?(word)
  defp operand_end?(_token), do: false

  defp ordered?(op), do: op in ["<", "<=", ">", ">=", "=~", "!~"]

  @doc """
  The type of an expression that stands alone as a condition and is more than one operand
  (arithmetic, signs, parentheses, `abs()`), or `nil` when it is null, the engine cannot type
  it or the double does not (a column the measurement lacks decides nothing here: an unsigned
  number made of one and a null is unsigned all the same, `InfluxQLArithType`). The quotient of an
  unsigned number and text is unsigned beside a connective, and the coercion error of the
  division when it is the whole condition (`alone`). A call or an operation the planner refuses
  is that error, before the type of a condition.
  """
  @spec standalone(list(), MapSet.t(binary()), map(), boolean()) ::
          :integer | :unsigned | :float | :tag | :string | nil
  def standalone(tokens, tags, types, alone) do
    mode = if(alone, do: :alone, else: :loose)

    with false <- Enum.any?(tokens, &match?({:op, _op}, &1)),
         {:ok, value} <-
           InfluxQLArithType.value(
             tokens,
             {tags, types},
             [mode: mode] ++ InfluxQLArithType.call_options(tokens, true)
           ),
         {:ok, value} <- InfluxQLArithType.flush(value),
         {:ok, kind} when kind in [:integer, :unsigned, :float, :tag, :string] <-
           InfluxQLArithType.settled(value, mode) do
      kind
    else
      _undecided -> nil
    end
  end

  @doc """
  Whether a side of a comparison (or the condition on its own) that has the time in its
  arithmetic comes to a null: the planner reads a boolean, a string or a tag under arithmetic as
  a null, and a null beside the time is a null (verified: `n + b + time + 1 > b`, `(s + b) +
  time + 1 > 1` and `(n + 's') + time - 1 > 1` keep no point, where `n + time + 1 > b` is the
  coercion error of `Int64 + Timestamp(ns)`).
  """
  @spec timed_null?(list(), MapSet.t(binary()), map()) :: boolean()
  def timed_null?(tokens, tags, types) do
    case sides(tokens) do
      {:ok, parts, _op} ->
        Enum.any?(parts, fn part ->
          match?({:ok, :null}, part |> InfluxQLArithType.kind({tags, types}) |> shape())
        end)

      :error ->
        false
    end
  end

  defp shape({:ok, kind}), do: shaped(kind)
  defp shape(_other), do: :error

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

  # What a side comes to for the checks above, from `InfluxQLArithType`: a null (a string, a tag
  # or
  # a boolean under arithmetic) is `:null`, a regular expression `:regex`. A side the double
  # does not decide is `:error`: one with the time or a column the measurement lacks in it (the
  # planner's, `coercion_error/3`'s, and `InfluxQLNested`'s), an error of the engine, a duration.
  @spec side_kind(list(), MapSet.t(binary()), map()) :: {:ok, kind()} | :error
  defp side_kind([{:regex, _pattern}], _tags, _types), do: {:ok, :regex}

  defp side_kind(tokens, tags, types) do
    with [] <- InfluxQLTokens.absent_columns(tokens, tags, types),
         false <- Enum.any?(tokens, &InfluxQLTokens.time?/1),
         {:ok, kind} <- InfluxQLArithType.kind(tokens, {tags, types}) do
      shaped(kind)
    else
      _undecided -> :error
    end
  end

  defp shaped(kind) when kind in [:integer, :float, :unsigned, :string, :tag, :boolean],
    do: {:ok, kind}

  defp shaped(kind) when kind in [:unknown, :nn, :nnf, :nz, :abs_null, false], do: {:ok, :null}
  defp shaped(_duration_or_time), do: :error

  @doc """
  Raises the first problem of the operands of a comparison, or of the condition on its own: the
  planning error of arithmetic the engine cannot coerce (verified: an unsigned number beside a
  string, a boolean, a tag or the time under an arithmetic operator, in either order, worded
  with the Arrow type of each operand as written, `UInt64 + Utf8`; the time beside anything but
  a duration; two times; an integer expression beside the quotient of an unsigned number and
  text), the planning error of a call (`abs()` of a boolean, with the wrong number of arguments),
  or the refusal of a call the double does not compute. The problems come in the order they are
  written, the left side of a comparison first, calls and arithmetic alike (`u + b > abs(s)` is
  the coercion, `abs(s) > u + b` the call). A condition on its own that comes to the error of a
  quotient raises it as well (thrown as `{:late, body}`). The calls of a comparison the double
  does not type (with the time on a side, chained) are checked on their own. `:ok` when nothing
  is wrong.
  """
  @spec check_operands(list(), MapSet.t(binary()), map(), boolean()) :: :ok
  def check_operands(tokens, tags, types, alone) do
    ctx = {tags, types}
    options = InfluxQLArithType.call_options(tokens, alone)

    # (A comparison with the bare time on a side is split by the planner, not typed.)
    case if(InfluxQLTokens.time_comparison?(tokens), do: :error, else: sides(tokens)) do
      {:ok, [part], nil} ->
        mode = if(alone, do: :alone, else: :loose)

        with {:ok, value} <- operand_value(part, ctx, [mode: mode] ++ options),
             do:
               InfluxQLArithType.raise_first_error([
                 value |> flushed() |> InfluxQLArithType.settled(mode)
               ])

      {:ok, [left, right], op} ->
        # The comparison reads both sides, then asks for the type of each in turn: the error of
        # the last operation of the left side comes before that of the right, and after every
        # error inside the right.
        sides = [operand_value(left, ctx, []), operand_value(right, ctx, [])]

        with [{:ok, left_value}, {:ok, right_value}] <- sides,
             do: InfluxQLArithType.check_pair(left_value, right_value, op)

        for {:ok, value} <- sides, do: flushed(value)
        :ok

      :error ->
        scan_calls(tokens, ctx, options)
    end
  end

  # The value, raising the planning error it carries.
  defp flushed(value) do
    case InfluxQLArithType.flush(value) do
      {:ok, value} -> value
      {:error, problem} -> raise_problem(problem)
    end
  end

  # The value of a side, raising its problem; the side the double cannot type has its calls
  # checked on their own.
  defp operand_value(tokens, ctx, options) do
    case InfluxQLArithType.value(tokens, ctx, options) do
      {:ok, _value} = typed ->
        typed

      {:error, problem} ->
        raise_problem(problem)

      :unread ->
        scan_calls(tokens, ctx, options)
        :unread
    end
  end

  # Each call is read by the walker from its name to its closing parenthesis, and the tokens
  # behind it go on being scanned. A call whose arguments are no arithmetic (`abs(n > 1)`) is
  # passed over: the calls inside it are met on their own.
  defp scan_calls([{:ident, _name}, {:raw, "("} | rest] = tokens, ctx, options) do
    case InfluxQLArithType.operand(tokens, ctx, options) do
      {:ok, value, after_call} ->
        flushed(value)
        scan_calls(after_call, ctx, options)

      {:error, problem} ->
        raise_problem(problem)

      :unread ->
        scan_calls(rest, ctx, options)
    end
  end

  defp scan_calls([_token | rest], ctx, options), do: scan_calls(rest, ctx, options)
  defp scan_calls([], _ctx, _options), do: :ok

  @spec raise_problem(InfluxQLArithType.problem()) :: no_return()
  defp raise_problem({:engine, body}), do: throw({:refused, {:engine, 400, body}})
  defp raise_problem({:refuse, message}), do: throw({:refused, message})

  @doc """
  Raises the error of a quotient that waits for the comparisons around it, as the two sides of a
  comparison read it (`InfluxQLArithType`): a comparison reads the quotient of an unsigned number and
  text as a comparison with a number does when the other side is a number, as one with a boolean
  does beside a boolean, and as one with text does beside anything else. Only a division has
  such an error, so a comparison with none is not read again. `:ok` when nothing is wrong.
  """
  @spec check_coercion(list(), MapSet.t(binary()), map(), boolean()) :: :ok
  def check_coercion(tokens, tags, types, _alone) do
    ctx = {tags, types}

    case if(InfluxQLTokens.time_comparison?(tokens), do: :error, else: sides(tokens)) do
      {:ok, [_left, _right] = parts, _op} ->
        if {:raw, "/"} in tokens, do: read_against(parts, ctx), else: :ok

      _single_or_unreadable ->
        :ok
    end
  end

  defp read_against(parts, ctx) do
    loose = Enum.map(parts, &InfluxQLArithType.kind(&1, ctx))

    parts
    |> Enum.zip(Enum.reverse(loose))
    |> Enum.map(fn {part, other} -> InfluxQLArithType.kind(part, ctx, mode: against(other)) end)
    |> InfluxQLArithType.raise_first_error()
  end

  defp against({:ok, kind}) when kind in [:integer, :float, :unsigned], do: :strict
  defp against({:ok, :boolean}), do: :loose
  defp against(_other), do: :text
end
