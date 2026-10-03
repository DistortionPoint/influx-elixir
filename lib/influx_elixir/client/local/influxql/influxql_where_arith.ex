defmodule InfluxElixir.Client.Local.InfluxQLWhereArith do
  @moduledoc false
  # The arithmetic of an InfluxQL `WHERE` over a tag, and the type of arithmetic that stands
  # alone as a condition (verified against InfluxDB 3 Core):
  #
  #   * a tag under an arithmetic operator or a minus sign makes the expression null
  #     (`- host`, `host * 2`, `usage + host`): a comparison of it, or the expression alone,
  #     keeps no point, and beside `OR` the other operand decides; a plus sign is no
  #     operation, so `+ host` is a bare tag
  #   * so is arithmetic over a string or a boolean constant (`usage + 'a' > 1`)
  #   * arithmetic that stands alone as a condition is the planning error that names its type:
  #     an integer when both operands are, a float otherwise and for every division

  @comparison ["=", "!=", "<>", "<", "<=", ">", ">="]

  @typedoc "The type of an expression: a number, a tag, or null."
  @type kind :: :integer | :float | :tag | :null | :constant

  @doc """
  Whether a comparison, or an expression alone, is null because a tag is under arithmetic.
  """
  @spec null?(list(), MapSet.t(binary()), map()) :: boolean()
  def null?(tokens, tags, types) do
    case sides(tokens) do
      {:ok, parts} -> Enum.any?(parts, &(side_kind(&1, tags, types) == {:ok, :null}))
      :error -> false
    end
  end

  @doc """
  The type of an expression that stands alone as a condition and is more than one operand
  (arithmetic, signs, parentheses), or `nil` when it is null or the double cannot type it.
  """
  @spec standalone(list(), MapSet.t(binary()), map()) :: :integer | :float | :tag | nil
  def standalone(tokens, tags, types) do
    if Enum.any?(tokens, &match?({:op, _op}, &1)) do
      nil
    else
      case side_kind(tokens, tags, types) do
        {:ok, kind} when kind in [:integer, :float, :tag] -> kind
        _other -> nil
      end
    end
  end

  # The sides of a comparison, or the whole as one side.
  @spec sides(list()) :: {:ok, [list()]} | :error
  defp sides(tokens) do
    case Enum.split_while(tokens, &(not comparison?(&1))) do
      {left, [_op | right]} when left != [] and right != [] ->
        if Enum.any?(right, &comparison?/1), do: :error, else: {:ok, [left, right]}

      {_whole, []} ->
        {:ok, [tokens]}

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
         {:ok, negated} <- negate(kind),
         do: {:ok, negated, after_operand}
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

  defp factor([{:str, _content} | rest], _tags, _types), do: {:ok, :constant, rest}

  defp factor([{:raw, word} | rest], _tags, _types) do
    if String.upcase(word) in ["TRUE", "FALSE"], do: {:ok, :constant, rest}, else: :error
  end

  defp factor([{:ident, name} | rest], tags, types) do
    cond do
      MapSet.member?(tags, name) -> {:ok, :tag, rest}
      Map.get(types, name) in [:integer, :float] -> {:ok, Map.fetch!(types, name), rest}
      true -> :error
    end
  end

  defp factor(_tokens, _tags, _types), do: :error

  defp negate(kind) when kind in [:tag, :null], do: {:ok, :null}
  defp negate(:constant), do: :error
  defp negate(kind), do: {:ok, kind}

  # A tag beside a string constant is the engine's coercion error, not a null.
  defp combine(_op, :tag, :constant), do: :error
  defp combine(_op, :constant, :tag), do: :error

  defp combine(_op, left, right)
       when left in [:tag, :null, :constant] or right in [:tag, :null, :constant],
       do: {:ok, :null}

  defp combine("/", _left, _right), do: {:ok, :float}
  defp combine(_op, :integer, :integer), do: {:ok, :integer}
  defp combine(_op, _left, _right), do: {:ok, :float}
end
