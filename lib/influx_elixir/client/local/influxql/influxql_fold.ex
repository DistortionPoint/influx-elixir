defmodule InfluxElixir.Client.Local.InfluxQLFold do
  @moduledoc false
  # The type of the arithmetic on one side of a comparison, as the engine types it when a
  # column the measurement lacks is in it (verified over every pair of operands and 3,000 chains
  # of three, against InfluxDB 3 Core). A column the measurement lacks is `:unknown`; the rules
  # are about the types of the two operands, whatever the operator (`+ - * /`):
  #
  #   * `:unknown` beside a number is a null number (`:nn`), beside the time, a string, a tag,
  #     a boolean or a duration the constant `:false` (`nosuch + 'x' = ok` keeps the points `ok`
  #     is false for), beside an unknown a null number
  #   * a null number and `:false` keep to that: a number leaves them null, text, a boolean, a
  #     duration or the time make them `:false` again; two operands that are no numbers and no
  #     column or not (`:false` beside text, `'x' + 1`, `s * n`) are a null of their own (`:nz`)
  #     that behaves as the null number but for an unsigned number
  #   * the engine's coercion errors come from the types: the time beside anything but a
  #     duration or an unknown, an unsigned number beside text, a boolean, a tag or a duration,
  #     a tag beside a string under `+` (`Dictionary(Int32, Utf8) + Utf8`), in the order written
  #   * a math function is a float (an `abs()` of an integer an integer)
  #
  # What the rules above do not tell (an unsigned number beside a null number, a
  # sign before the false) is `:unread`: the caller answers as it did before, or refuses.

  alias InfluxElixir.Client.Local.{
    InfluxQLError,
    InfluxQLText,
    InfluxQLTokens,
    InfluxQLWhereArith
  }

  @typedoc "What arithmetic comes to."
  @type kind ::
          :unknown
          | :nn
          | :nnf
          | :nz
          | false
          | :integer
          | :float
          | :unsigned
          | :string
          | :tag
          | :boolean
          | :duration
          | :timestamp
          | {:udiv, kind(), kind()}

  @typep ctx :: {MapSet.t(binary()), map()}

  # An operand: its kind, and whether it is a constant (no column of the measurement in it).
  @typep operand :: {kind(), boolean()}

  @numbers [:integer, :float, :unsigned]
  @nulls [:unknown, :nn, :nnf, :nz]
  @text [:string, :tag, :boolean, :duration, false]

  @doc """
  The kind of the arithmetic `tokens` make, `{:ok, kind}`, `:unread`, or `{:error, body}`, the
  planner's error for arithmetic the engine cannot coerce or type.
  """
  @spec kind(list(), ctx()) :: {:ok, kind()} | :unread | {:error, binary()}
  def kind(tokens, ctx) do
    case sum(tokens, ctx) do
      {:ok, {{:udiv, _left, _right}, _constant}, []} -> {:ok, :unsigned}
      {:ok, {kind, _constant}, []} -> {:ok, kind}
      {:error, _body} = error -> error
      _unread -> :unread
    end
  end

  # sum := product (("+" | "-") product)*
  defp sum(tokens, ctx) do
    with {:ok, left, rest} <- product(tokens, ctx),
         do: more(rest, left, ["+", "-"], &product(&1, ctx))
  end

  # product := factor (("*" | "/") factor)*
  defp product(tokens, ctx) do
    with {:ok, left, rest} <- factor(tokens, ctx),
         do: more(rest, left, ["*", "/"], &factor(&1, ctx))
  end

  defp more([{:raw, op} | rest] = tokens, left, ops, next) do
    if op in ops do
      with {:ok, right, after_right} <- next.(rest),
           {:ok, operand} <- combine(op, left, right),
           do: more(after_right, operand, ops, next)
    else
      {:ok, left, tokens}
    end
  end

  defp more(tokens, left, _ops, _next), do: {:ok, left, tokens}

  defp factor([{:raw, "-"} | rest], ctx) do
    with {:ok, operand, after_operand} <- factor(rest, ctx),
         {:ok, negated} <- negate(operand),
         do: {:ok, negated, after_operand}
  end

  defp factor([{:raw, "+"} | rest], ctx), do: factor(rest, ctx)

  defp factor([{:raw, "("} | rest], ctx) do
    case sum(rest, ctx) do
      {:ok, operand, [{:raw, ")"} | after_group]} -> {:ok, operand, after_group}
      {:error, _body} = error -> error
      _unread -> :unread
    end
  end

  defp factor([{:number, text} | rest], _ctx) do
    case Integer.parse(text) do
      {n, ""} when n <= 9_223_372_036_854_775_807 -> {:ok, {:integer, true}, rest}
      {_n, ""} -> :unread
      _fraction -> {:ok, {:float, true}, rest}
    end
  end

  defp factor([{:str, _content} | rest], _ctx), do: {:ok, {:string, true}, rest}
  defp factor([{:duration, _total, _text} | rest], _ctx), do: {:ok, {:duration, true}, rest}

  defp factor([{:raw, word} | rest], _ctx) do
    if String.upcase(word) in ["TRUE", "FALSE"], do: {:ok, {:boolean, true}, rest}, else: :unread
  end

  defp factor([{:ident, name}, {:raw, "("} | rest], ctx) do
    with true <- InfluxQLText.math_function?(name),
         {inside, after_call} <- InfluxQLTokens.take_call(rest) do
      {:ok, {call_kind(name, inside, ctx), constant?(inside)}, after_call}
    else
      _not_a_math_call -> :unread
    end
  end

  defp factor([{:ident, name} = token | rest], {tags, types}) do
    cond do
      InfluxQLTokens.time?(token) -> {:ok, {:timestamp, false}, rest}
      MapSet.member?(tags, name) -> {:ok, {:tag, false}, rest}
      Map.has_key?(types, name) -> {:ok, {Map.fetch!(types, name), false}, rest}
      true -> {:ok, {:unknown, true}, rest}
    end
  end

  defp factor(_tokens, _ctx), do: :unread

  # `abs()` of a number keeps its type, any other call is a float.
  defp call_kind(name, inside, ctx) do
    with "abs" <- String.downcase(name),
         {:ok, kind} when kind in @numbers <- kind(inside, ctx) do
      kind
    else
      _float -> :float
    end
  end

  # (An absent column among the tokens is a column the engine replaces by a null.)
  defp constant?(tokens), do: not Enum.any?(tokens, &match?({:ident, _name}, &1))

  @spec negate(operand()) :: {:ok, operand()} | :unread
  defp negate({kind, constant})
       when kind in @numbers or kind in [:nn, :nnf, :nz, :duration],
       do: {:ok, {kind, constant}}

  # A column the measurement lacks, negated, is a null integer (verified: `-nosuch * u` is the
  # planner's error beside a boolean, where `nosuch * u` is a null).
  defp negate({:unknown, constant}), do: {:ok, {:nn, constant}}

  # The engine cannot negate a string, a tag or a boolean column: `-s` is a null as a column the
  # measurement lacks is (verified: `'x' * -s` is `false` beside `ok`, `1 * -s` a null), though
  # one that depends on a column. (A constant of these is a parse error.)
  defp negate({kind, _constant}) when kind in [:string, :tag, :boolean],
    do: {:ok, {:unknown, false}}

  defp negate({{:udiv, left, right}, _constant}), do: coerce(left, "/", right)

  defp negate(_false_or_time), do: :unread

  # ---------------------------------------------------------------------------
  # Two operands
  # ---------------------------------------------------------------------------

  @spec combine(binary(), operand(), operand()) ::
          {:ok, operand()} | :unread | {:error, binary()}
  # The quotient of an unsigned number and text is unsigned alone (the comparison's error beside
  # a boolean) and the coercion error of the division in any arithmetic after it.
  defp combine(op, {{:udiv, _left, _right}, constant}, {kind, _kept} = second)
       when kind in @nulls,
       do: combine(op, {:unsigned, constant}, second)

  defp combine(op, {kind, _kept} = first, {{:udiv, _left, _right}, constant}) when kind in @nulls,
    do: combine(op, first, {:unsigned, constant})

  defp combine(_op, {{:udiv, left, right}, _constant}, _second), do: coerce(left, "/", right)
  defp combine(_op, _first, {{:udiv, left, right}, _constant}), do: coerce(left, "/", right)

  defp combine(op, {left, left_constant} = first, {right, right_constant} = second) do
    constant = left_constant and right_constant

    cond do
      left in @nulls and right in @nulls -> nulls(op, left, right, constant)
      left in @nulls -> with_null(op, left, second, constant)
      right in @nulls -> with_null(op, right, first, constant)
      true -> known(op, first, second, constant)
    end
  end

  # The kinds that are a null beside one another: a null number of the type a float makes
  # (`:nnf`) or of an integer (`:nn`), a null of its own (`:nz`).
  defp nulls(_op, :nz, :nn, _constant), do: :unread
  defp nulls(_op, :nn, :nz, _constant), do: :unread
  defp nulls(_op, :nz, :nnf, _constant), do: :unread
  defp nulls(_op, :nnf, :nz, _constant), do: :unread
  defp nulls(_op, left, right, constant) when :nz in [left, right], do: {:ok, {:nz, constant}}
  defp nulls(_op, left, right, constant), do: {:ok, {null_number([left, right]), constant}}

  # A null number is a float when a float or a float null makes it. (A division does not: the
  # quotient of a null and an integer is a null integer, unsigned beside an unsigned number;
  # verified: `(nosuch / 1) + u = ok` is the planner's error, `(nosuch * 1.5) + u = ok` no row.)
  defp null_number(kinds), do: if(:float in kinds or :nnf in kinds, do: :nnf, else: :nn)

  # A null beside a known operand. (An unsigned number beside a column the measurement lacks
  # stays that column and beside a null of its own leaves it so; beside a null integer it is an
  # unsigned null, the planner's error beside a boolean, and beside a float null a float null.)
  defp with_null(_op, :unknown, {:unsigned, _kept}, constant), do: {:ok, {:unknown, constant}}
  defp with_null(_op, :nz, {:unsigned, _kept}, constant), do: {:ok, {:nz, constant}}
  defp with_null(_op, :nn, {:unsigned, _kept}, constant), do: {:ok, {:unsigned, constant}}
  defp with_null(_op, :nnf, {:unsigned, _kept}, constant), do: {:ok, {:nz, constant}}

  defp with_null(_op, :nz, {kind, _kept}, constant) when kind in @numbers,
    do: {:ok, {:nz, constant}}

  defp with_null(_op, null, {kind, _kept}, constant) when kind in @numbers,
    do: {:ok, {null_number([null, kind]), constant}}

  defp with_null(_op, _null, {kind, _kept}, constant) when kind in @text or kind == :timestamp,
    do: {:ok, {false, constant}}

  defp known(op, {left, _left_constant} = first, {right, _right_constant} = second, constant) do
    cond do
      left == :timestamp or right == :timestamp -> with_time(op, left, right)
      left == :duration and right == :duration -> durations(op, constant)
      left in @numbers and right in @numbers -> {:ok, {number(op, left, right), constant}}
      uncoercible?(left, right) -> uncoercible(op, first, second, constant)
      true -> text(op, left, right, constant)
    end
  end

  # Two operands that are text, booleans, durations or numbers beside them: a tag beside a string
  # under `+` is the planner's error, a string beside a string is concatenated, any other pair
  # makes a null.
  defp text("+", :tag, :string, _constant), do: coerce(:tag, "+", :string)
  defp text("+", :string, :tag, _constant), do: coerce(:string, "+", :tag)
  defp text("+", :string, :string, constant), do: {:ok, {:string, constant}}
  defp text(_op, _left, _right, constant), do: {:ok, {:nz, constant}}

  # Two durations are summed or subtracted; the engine has no product or quotient of them.
  defp durations(op, constant) when op in ["+", "-"], do: {:ok, {:duration, constant}}
  defp durations(op, _constant), do: temporal(:duration, op)

  # A time and a duration are summed (in either order) or subtracted (the time first) to a time.
  # The difference of two times is a duration of its own (`Duration(ns)`) that the double does not
  # model: refused by name. The sum, product or quotient of two times is the engine's error, and
  # a time beside anything else is one the engine cannot coerce.
  defp with_time(op, :timestamp, :duration) when op in ["+", "-"], do: {:ok, {:timestamp, false}}
  defp with_time("+", :duration, :timestamp), do: {:ok, {:timestamp, false}}

  defp with_time("-", :timestamp, :timestamp),
    do: InfluxQLError.refuse("the difference of two timestamps")

  defp with_time(op, :timestamp, :timestamp), do: temporal(:timestamp, op)
  defp with_time(op, left, right), do: coerce(left, op, right)

  # The coercion error of an unsigned number beside text, a boolean, a tag, a duration or the
  # false of a column the measurement lacks, in the order written (verified for `+ - *`). A
  # division of them is another error, the comparison's: left unread.
  defp uncoercible("/", {left, _lc}, {right, _rc}, constant),
    do: {:ok, {{:udiv, left, right}, constant}}

  defp uncoercible(op, {left, _lc}, {right, _rc}, _constant), do: coerce(left, op, right)

  # An unsigned number beside text, a boolean, a tag, a duration or the false.
  defp uncoercible?(left, right),
    do: (left == :unsigned and right in @text) or (right == :unsigned and left in @text)

  # A division of integers is a float, but not beside an unsigned number (verified: `1 / u` and
  # `u / u` are unsigned, `u / 2.5` a float).
  defp number(op, left, right) do
    cond do
      left == :float or right == :float -> :float
      left == :unsigned or right == :unsigned -> :unsigned
      op == "/" -> :float
      true -> :integer
    end
  end

  defp coerce(left, op, right), do: {:error, InfluxQLWhereArith.coercion_body(left, op, right)}

  # The planner's error for the sum, product or quotient of two times or two durations.
  defp temporal(kind, op) do
    type = InfluxQLWhereArith.arrow(kind)
    word = if kind == :timestamp, do: "timestamp", else: "interval"

    {:error,
     "Error during planning: Cannot get result type for temporal operation " <>
       "#{type} #{op} #{type}: Invalid argument error: Invalid #{word} arithmetic " <>
       "operation: #{type} #{op} #{type}"}
  end
end
