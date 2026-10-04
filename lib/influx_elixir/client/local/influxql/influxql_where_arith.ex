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
  #   * `abs()` takes one number; anything else is the engine's planning error, worded here
  #     (`call_error/3`)

  @comparison ["=", "!=", "<>", "<", "<=", ">", ">=", "=~", "!~"]
  @equality ["=", "!=", "<>"]

  @typedoc "The type of an expression: a number, a tag, a string, a boolean, a regular expression, or null."
  @type kind :: :integer | :float | :tag | :string | :boolean | :regex | :null

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
  (arithmetic, signs, parentheses), or `nil` when it is null or the double cannot type it.
  """
  @spec standalone(list(), MapSet.t(binary()), map()) :: :integer | :float | :tag | :string | nil
  def standalone(tokens, tags, types) do
    cond do
      Enum.any?(tokens, &match?({:op, _op}, &1)) ->
        nil

      abs_call(tokens) != nil ->
        number_type(argument_type(abs_call(tokens), tags, types))

      true ->
        case side_kind(tokens, tags, types) do
          {:ok, kind} when kind in [:integer, :float, :tag, :string] -> kind
          _other -> nil
        end
    end
  end

  # The argument of a condition that is `abs(argument)` and nothing else.
  defp abs_call([{:ident, name}, {:raw, "("} | rest]) do
    with true <- String.downcase(name) == "abs",
         {inside, []} <- take_call(rest, 1, []),
         [argument] <- split_arguments(inside) do
      argument
    else
      _other -> nil
    end
  end

  defp abs_call(_tokens), do: nil

  # `abs` keeps the type of a number; of a column the measurement lacks it is a float.
  defp number_type(type) when type in [:integer, :float], do: type
  defp number_type(:null), do: :float
  defp number_type(_other), do: nil

  # The sides of a comparison, or the whole as one side, with the operator.
  @spec sides(list()) :: {:ok, [list()], binary() | nil} | :error
  defp sides(tokens) do
    case Enum.split_while(tokens, &(not comparison?(&1))) do
      {left, [{:op, op} | right]} when left != [] and right != [] ->
        if Enum.any?(right, &comparison?/1), do: :error, else: {:ok, [left, right], op}

      {_whole, []} ->
        {:ok, [tokens], nil}

      _other ->
        :error
    end
  end

  defp comparison?({:op, op}), do: op in @comparison
  defp comparison?(_token), do: false

  @spec side_kind(list(), MapSet.t(binary()), map()) :: {:ok, kind()} | :error
  defp side_kind(tokens, tags, types) do
    case expression(tokens, tags, types) do
      {:ok, kind, []} -> {:ok, kind}
      _other -> :error
    end
  end

  # sum := product (("+" | "-") product)*
  defp expression(tokens, tags, types) do
    with {:ok, left, rest} <- product(tokens, tags, types),
         do: more(rest, left, ["+", "-"], &product(&1, tags, types))
  end

  # product := factor (("*" | "/") factor)*
  defp product(tokens, tags, types) do
    with {:ok, left, rest} <- factor(tokens, tags, types),
         do: more(rest, left, ["*", "/"], &factor(&1, tags, types))
  end

  defp more([{:raw, op} | rest] = tokens, left, ops, next) do
    if op in ops do
      with {:ok, right, after_right} <- next.(rest),
           {:ok, kind} <- combine(op, left, right),
           do: more(after_right, kind, ops, next)
    else
      {:ok, left, tokens}
    end
  end

  defp more(tokens, left, _ops, _next), do: {:ok, left, tokens}

  defp factor([{:raw, "-"} | rest], tags, types) do
    with {:ok, kind, after_operand} <- factor(rest, tags, types),
         do: {:ok, negate(kind), after_operand}
  end

  defp factor([{:raw, "+"} | rest], tags, types), do: factor(rest, tags, types)

  defp factor([{:raw, "("} | rest], tags, types) do
    case expression(rest, tags, types) do
      {:ok, kind, [{:raw, ")"} | after_group]} -> {:ok, kind, after_group}
      _other -> :error
    end
  end

  defp factor([{:number, text} | rest], _tags, _types) do
    case Integer.parse(text) do
      {n, ""} when n <= 9_223_372_036_854_775_807 -> {:ok, :integer, rest}
      {_n, ""} -> :error
      _fraction -> {:ok, :float, rest}
    end
  end

  defp factor([{:str, _content} | rest], _tags, _types), do: {:ok, :string, rest}
  defp factor([{:regex, _pattern} | rest], _tags, _types), do: {:ok, :regex, rest}

  defp factor([{:raw, word} | rest], _tags, _types) do
    if String.upcase(word) in ["TRUE", "FALSE"], do: {:ok, :boolean, rest}, else: :error
  end

  defp factor([{:ident, name} | rest], tags, types) do
    cond do
      MapSet.member?(tags, name) -> {:ok, :tag, rest}
      Map.get(types, name) in [:integer, :float, :string, :boolean] -> {:ok, types[name], rest}
      true -> :error
    end
  end

  defp factor(_tokens, _tags, _types), do: :error

  defp negate(kind) when kind in [:integer, :float], do: kind
  defp negate(_non_numeric), do: :null

  # A tag beside a string under `+` is the engine's coercion error, not a null.
  defp combine("+", :tag, :string), do: :error
  defp combine("+", :string, :tag), do: :error
  defp combine("+", :string, :string), do: {:ok, :string}

  defp combine(_op, left, right)
       when left not in [:integer, :float] or right not in [:integer, :float],
       do: {:ok, :null}

  defp combine("/", _left, _right), do: {:ok, :float}
  defp combine(_op, :integer, :integer), do: {:ok, :integer}
  defp combine(_op, _left, _right), do: {:ok, :float}

  # ---------------------------------------------------------------------------
  # Calls
  # ---------------------------------------------------------------------------

  @arrow %{
    integer: "Int64",
    float: "Float64",
    string: "Utf8",
    boolean: "Boolean",
    tag: "Dictionary(Int32, Utf8)",
    timestamp: "Timestamp(ns)",
    null: "Float64"
  }

  @native %{
    string: "String",
    boolean: "Boolean",
    tag: "String",
    timestamp: "Timestamp(Nanosecond, None)"
  }

  @signature "You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"

  @doc """
  The calls of a condition (a name followed by a parenthesis): the engine's planning error
  for an `abs()` that does not take one number, as `{:engine, body}`, or a refusal by name
  for any other call (the engine takes a library of math functions the double does not
  compute); `:ok` when the calls are all `abs()` of numbers.
  """
  @spec call_error(list(), MapSet.t(binary()), map()) ::
          :ok | {:engine, binary()} | {:refuse, binary()}
  def call_error(tokens, tags, types) do
    bare? = not Enum.any?(tokens, &comparison?/1)

    tokens
    |> calls([])
    |> Enum.find_value(:ok, &call_problem(&1, bare?, tags, types))
  end

  # The calls in order of appearance, each with the tokens of its arguments.
  defp calls([{:ident, name}, {:raw, "("} | rest], acc) do
    {inside, after_call} = take_call(rest, 1, [])
    calls(inside ++ after_call, [{name, split_arguments(inside)} | acc])
  end

  defp calls([_token | rest], acc), do: calls(rest, acc)
  defp calls([], acc), do: Enum.reverse(acc)

  defp take_call([], _depth, acc), do: {Enum.reverse(acc), []}
  defp take_call([{:raw, ")"} | rest], 1, acc), do: {Enum.reverse(acc), rest}

  defp take_call([{:raw, ")"} = token | rest], depth, acc),
    do: take_call(rest, depth - 1, [token | acc])

  defp take_call([{:raw, "("} = token | rest], depth, acc),
    do: take_call(rest, depth + 1, [token | acc])

  defp take_call([token | rest], depth, acc), do: take_call(rest, depth, [token | acc])

  defp split_arguments([]), do: []

  defp split_arguments(tokens) do
    {arguments, current, _depth} =
      Enum.reduce(tokens, {[], [], 0}, fn
        {:raw, ","}, {done, current, 0} -> {[Enum.reverse(current) | done], [], 0}
        {:raw, "("} = token, {done, current, depth} -> {done, [token | current], depth + 1}
        {:raw, ")"} = token, {done, current, depth} -> {done, [token | current], depth - 1}
        token, {done, current, depth} -> {done, [token | current], depth}
      end)

    Enum.reverse([Enum.reverse(current) | arguments])
  end

  defp call_problem({name, arguments}, bare?, tags, types) do
    if String.downcase(name) == "abs" do
      if [] in arguments and length(arguments) > 1,
        do: {:refuse, "unsupported InfluxQL (abs() with an empty argument)"},
        else: abs_problem(arguments, bare?, tags, types)
    else
      {:refuse, "unsupported InfluxQL (#{String.downcase(name)}() in a WHERE)"}
    end
  end

  defp abs_problem([], _bare, _tags, _types) do
    {:engine,
     "Error during planning: 'abs' does not support zero arguments No function matches the " <>
       "given name and argument types 'abs()'. " <> @signature}
  end

  defp abs_problem([argument], bare?, tags, types) do
    case argument_type(argument, tags, types) do
      type when type in [:integer, :float, :null] ->
        nil

      type ->
        {:engine,
         "Error during planning: Function 'abs' expects NativeType::Numeric but received " <>
           "NativeType::#{Map.fetch!(@native, type)}" <>
           if(bare?,
             do: "",
             else:
               " No function matches the given name and argument types " <>
                 "'abs(#{Map.fetch!(@arrow, type)})'. " <> @signature
           )}
    end
  end

  defp abs_problem(arguments, _bare, tags, types) do
    names = Enum.map_join(arguments, ", ", &Map.fetch!(@arrow, argument_type(&1, tags, types)))

    {:engine,
     "Error during planning: Function 'abs' expects 1 arguments but received " <>
       "#{length(arguments)} No function matches the given name and argument types " <>
       "'abs(#{names})'. " <> @signature}
  end

  # What an argument comes to; a column the measurement lacks, or an expression the double does
  # not type, is a number as far as the call is concerned.
  defp argument_type(tokens, tags, types) do
    case {tokens, side_kind(tokens, tags, types)} do
      {[{:ident, name}], _kind} when is_binary(name) and name in ["time", "TIME", "Time"] ->
        :timestamp

      {_tokens, {:ok, kind}} when kind in [:integer, :float, :tag, :string, :boolean] ->
        kind

      _other ->
        :null
    end
  end
end
