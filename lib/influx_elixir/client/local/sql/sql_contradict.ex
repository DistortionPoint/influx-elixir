defmodule InfluxElixir.Client.Local.SQLContradict do
  @moduledoc false
  # The equalities of a `WHERE` that the engine's optimizer proves contradictory, so that it
  # replaces the plan with an empty relation (verified against InfluxDB 3 Core, each rule below
  # on integers, unsigned integers, floats, text, tags and `time`).
  #
  # Two rules fold, and only these:
  #
  #   * two `IN` lists that are the two sides of one `AND` become the `IN` list of the values
  #     they share, or `false` when they share none (`n IN (1, 2) AND n IN (3, 4)`). A one-element
  #     list is an `IN` list here, so `n IN (1) AND n IN (2, 3)` folds; the two must be
  #     adjacent in the tree (`n IN (1, 2) AND v > 0 AND n IN (3, 4)` does not fold), and
  #     `NULL` shares nothing
  #   * among all the top-level conjuncts of what is left, two equalities of one operand to
  #     different values (`n = 1 AND v > 0 AND n = 2`); a one-element `IN` counts as an equality
  #     here, but a longer one never does (`n = 1 AND n IN (2, 3)` does not fold), and no `OR`
  #     or `NOT` is looked into (`(n = 1 AND n = 2) OR (n = 3 AND n = 4)` does not fold)
  #
  # The operand is any expression, compared by its text (`n + 1 = 1 AND n + 1 = 2`), the
  # literal any constant expression, and the two fold only when they are compared in the same
  # form, the form the engine's coercion gives the comparison: `n = 1.5` casts the column to
  # `Float64`, so `n = 1 AND n = 2.5` does not fold. A string beside an integer column is read
  # as the integer only when it is that integer's own text (`'1'` but not `'01'`, `'+1'` or
  # `' 1'`), else the column is compared as text; a string beside a float column is always text;
  # a number beside a text column is its text. A boolean never folds (`b = true AND b = false`).
  #
  # What this does not know it says so (`unknown?/2`) instead of guessing: the caller refuses
  # by name a query whose answer depends on it.

  alias InfluxElixir.Client.Local.{SQLExpr, SQLExprType, SQLFold}

  @typep types :: %{binary() => binary()}
  @typep clause :: tuple()
  @typep operand :: binary() | {:expr, SQLExpr.t()}
  @typep form :: atom()
  @typep keyed :: {form(), term()} | :null | :unknown | :skip

  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807
  @u64_max 18_446_744_073_709_551_615
  @text_types ["Utf8", "Utf8View", "Dictionary(Int32, Utf8)"]

  @doc """
  The two `IN` clauses of one `AND`, folded: `:none` when they do not fold, `:empty` when they
  share no value, `{:ok, clause}` for the list of the values they share.
  """
  @spec intersect(clause(), clause(), types()) :: :none | :empty | {:ok, clause()}
  def intersect({:in, left, xs}, {:in, other, ys}, types) when is_list(xs) and is_list(ys) do
    cond do
      not same_operand?(left, other) -> :none
      nulls?(xs) or nulls?(ys) -> :empty
      true -> fold(left, xs, ys, types)
    end
  end

  def intersect(_left, _right, _types), do: :none

  @spec fold(operand(), [term()], [term()], types()) :: :none | :empty | {:ok, clause()}
  defp fold(operand, xs, ys, types) do
    class = class(operand, types)

    with false <- texts?(class, xs) or texts?(class, ys),
         {form, left_values} <- list_keys(class, xs),
         {^form, right_values} <- list_keys(class, ys) do
      shared = for {value, original} <- left_values, member?(right_values, value), do: original
      if shared == [], do: :empty, else: {:ok, {:in, operand, shared}}
    else
      _no_fold -> :none
    end
  end

  @doc "Whether two equalities of the clauses (top-level conjuncts) are to different values."
  @spec conflict?([clause()], types()) :: boolean()
  def conflict?(clauses, types) do
    clauses
    |> Enum.flat_map(&equality(&1, types))
    |> Enum.group_by(fn {operand, form, _value} -> {operand, form} end, &elem(&1, 2))
    |> Enum.any?(fn {_group, values} -> not Enum.all?(values, &(&1 == hd(values))) end)
  end

  @doc """
  Whether the clauses compare one operand to two or more literals of which one is of a kind
  that is not modelled, so that whether they fold is not known.
  """
  @spec unknown?([clause()], types()) :: boolean()
  def unknown?(clauses, types) do
    clauses
    |> Enum.flat_map(&compared/1)
    |> Enum.group_by(&operand_key(elem(&1, 0)), & &1)
    |> Enum.any?(fn {_operand, members} ->
      match?([_, _ | _], members) and Enum.any?(members, &unmodelled?(&1, types))
    end)
  end

  # ---------------------------------------------------------------------------
  # The clauses
  # ---------------------------------------------------------------------------

  # The equalities a clause stands for, `{operand, form, value}`.
  @spec equality(clause(), types()) :: [{term(), form(), term()}]
  defp equality({:eq, operand, literal}, types) when literal != nil do
    case key(class(operand, types), literal) do
      {form, value} -> [{operand_key(operand), form, value}]
      _other -> []
    end
  end

  defp equality({:in, operand, literals}, types) when is_list(literals) do
    case list_keys(class(operand, types), literals) do
      {form, [{value, _original}]} -> [{operand_key(operand), form, value}]
      _other -> []
    end
  end

  defp equality(_clause, _types), do: []

  # The clauses that compare an operand to literals: `{operand, kind, literals}`.
  @spec compared(clause()) :: [{operand(), :eq | :in, [term()]}]
  defp compared({:eq, operand, literal}) when literal != nil, do: [{operand, :eq, [literal]}]
  defp compared({:in, operand, literals}) when is_list(literals), do: [{operand, :in, literals}]
  defp compared(_clause), do: []

  @spec unmodelled?({operand(), :eq | :in, [term()]}, types()) :: boolean()
  defp unmodelled?({operand, kind, literals}, types) do
    class = class(operand, types)

    class != :bool and
      case kind do
        :eq ->
          Enum.any?(literals, &(key(class, &1) == :unknown))

        :in ->
          list_keys(class, literals) == :unknown and Enum.any?(literals, &(&1 != nil)) and
            not texts?(class, literals)
      end
  end

  # A list of several values beside a number column, with strings that are all numbers: the
  # engine casts them to the column's type after it has looked for what folds, so it does not
  # fold them (`u IN ('1', '2') AND u IN (3, 4)` stays, where a list of one string is an
  # equality, and a string that is not a number makes the comparison one of text, which folds).
  @spec texts?(atom(), [term()]) :: boolean()
  defp texts?(class, literals) do
    values = Enum.reject(literals, &is_nil/1)
    strings = Enum.filter(values, &is_binary/1)

    class in [:i64, :u64, :f64] and match?([_, _ | _], values) and strings != [] and
      Enum.all?(strings, &match?({_number, ""}, Float.parse(&1)))
  end

  # A list of nothing but `NULL`, which shares no value with any list.
  @spec nulls?([term()]) :: boolean()
  defp nulls?(literals), do: literals != [] and Enum.all?(literals, &is_nil/1)

  @spec same_operand?(operand(), operand()) :: boolean()
  defp same_operand?(left, right), do: operand_key(left) == operand_key(right)

  # A column is the same operand however it is written (`n`, `m.n`).
  @spec operand_key(operand()) :: term()
  defp operand_key({:expr, {:field, name}}) when is_binary(name), do: name
  defp operand_key({:expr, expr}), do: {:expr, expr}
  defp operand_key(column), do: column

  # ---------------------------------------------------------------------------
  # The form a literal is compared in
  # ---------------------------------------------------------------------------

  @spec class(operand(), types()) :: atom()
  defp class(operand, types) do
    case operand_type(operand, types) do
      "Int64" -> :i64
      "UInt64" -> :u64
      "Float64" -> :f64
      "Boolean" -> :bool
      "Timestamp(ns)" -> :ts
      type when type in @text_types -> :text
      _other -> :other
    end
  end

  @spec operand_type(operand(), types()) :: term()
  defp operand_type({:expr, expr}, types) do
    SQLExprType.known_type(expr, types)
  rescue
    _error -> nil
  end

  defp operand_type(column, types), do: Map.get(types, column)

  # The elements of a list in the form of the whole list: one form for all of them, or integers
  # and floats together, which the engine compares as floats. `NULL` shares nothing and is left
  # out. `:unknown` for a list that mixes other kinds.
  @spec list_keys(atom(), [term()]) :: {form(), [{term(), term()}]} | :unknown
  defp list_keys(class, literals) do
    class = if textual?(class, literals), do: :text, else: class
    keyed = for literal <- literals, (k = key(class, literal)) != :null, do: {k, literal}
    forms = keyed |> Enum.map(fn {k, _literal} -> form_of(k) end) |> Enum.uniq()

    cond do
      Enum.any?(keyed, fn {k, _literal} -> k in [:unknown, :skip] end) ->
        :unknown

      keyed == [] ->
        :unknown

      match?([_one], forms) ->
        {hd(forms), dedupe(for {{_form, v}, original} <- keyed, do: {v, original})}

      Enum.sort(forms) == [:f64, :i64] ->
        {:f64, promote(keyed)}

      true ->
        :unknown
    end
  end

  # A list beside a number column with a string that is not a number: the engine compares the
  # column as text, every value of the list as its text.
  @spec textual?(atom(), [term()]) :: boolean()
  defp textual?(class, literals) do
    class in [:i64, :u64, :f64] and
      Enum.any?(literals, &(is_binary(&1) and not match?({_number, ""}, Float.parse(&1))))
  end

  @spec form_of(keyed()) :: form() | keyed()
  defp form_of({form, _value}), do: form
  defp form_of(other), do: other

  @spec promote([{keyed(), term()}]) :: [{term(), term()}]
  defp promote(keyed) do
    keyed
    |> Enum.map(fn
      {{:i64, v}, original} -> {v * 1.0, original}
      {{:f64, v}, original} -> {v, original}
    end)
    |> dedupe()
  end

  @spec dedupe([{term(), term()}]) :: [{term(), term()}]
  defp dedupe(pairs), do: Enum.uniq_by(pairs, fn {value, _original} -> value end)

  @spec member?([{term(), term()}], term()) :: boolean()
  defp member?(pairs, value), do: Enum.any?(pairs, fn {other, _original} -> other == value end)

  # One literal against an operand of a class: the form it is compared in and its value there.
  @spec key(atom(), term()) :: keyed()
  defp key(_class, nil), do: :null
  defp key(:bool, _literal), do: :skip
  defp key(:other, _literal), do: :unknown
  defp key(class, {:uint, value}), do: key(class, value)

  defp key(:i64, value) when is_integer(value) and value in @i64_min..@i64_max,
    do: {:i64, value}

  defp key(:i64, value) when is_integer(value), do: {:wide, value}
  defp key(:i64, value) when is_float(value), do: {:f64, value}
  defp key(:i64, text) when is_binary(text), do: integer_text(text, @i64_min, @i64_max, :i64)

  defp key(:u64, value) when is_integer(value) and value in 0..@u64_max, do: {:u64, value}
  defp key(:u64, value) when is_integer(value) and value < 0, do: {:negative, value}
  defp key(:u64, value) when is_integer(value), do: {:wide, value}
  defp key(:u64, value) when is_float(value), do: {:f64, value}
  defp key(:u64, text) when is_binary(text), do: integer_text(text, 0, @u64_max, :u64)

  defp key(:f64, value) when is_integer(value), do: {:f64, value * 1.0}
  defp key(:f64, value) when is_float(value), do: {:f64, value}
  defp key(:f64, text) when is_binary(text), do: {:text, text}

  defp key(:text, text) when is_binary(text), do: {:text, text}
  defp key(:text, value) when is_integer(value), do: {:text, Integer.to_string(value)}
  defp key(:text, value) when is_float(value), do: float_text(value)

  defp key(:ts, value) when is_integer(value), do: {:ts, value}

  # An expression of the literal's place: its value when it reads no column, and no equality
  # to a constant when it does (`n = v`).
  defp key(class, {:expr, expr}) do
    if SQLExpr.columns(expr) == [],
      do: constant_key(class, SQLFold.constant(expr)),
      else: :skip
  end

  defp key(_class, _literal), do: :unknown

  @spec constant_key(atom(), {:ok, term()} | :error) :: keyed()
  defp constant_key(class, {:ok, value}) when is_number(value) or is_binary(value),
    do: key(class, value)

  defp constant_key(_class, _folded), do: :unknown

  # A string is the integer it spells only when it is that integer's own text; any other string
  # leaves the column compared as text.
  @spec integer_text(binary(), integer(), integer(), atom()) :: keyed()
  defp integer_text(text, low, high, form) do
    case Integer.parse(text) do
      {value, ""} when value >= low and value <= high ->
        if Integer.to_string(value) == text, do: {form, value}, else: {:text, text}

      _text ->
        {:text, text}
    end
  end

  # A float as the engine writes it as text, for the plain numbers only.
  @spec float_text(float()) :: keyed()
  defp float_text(value) when abs(value) >= 1.0e-4 and abs(value) < 1.0e15,
    do: {:text, Float.to_string(value)}

  defp float_text(value) when value == 0.0, do: {:text, "0.0"}
  defp float_text(_value), do: :unknown
end
