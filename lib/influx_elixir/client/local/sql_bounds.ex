defmodule InfluxElixir.Client.Local.SQLBounds do
  @moduledoc """
  The engine's failure on a `WHERE` that leaves a numeric column no value
  (verified against InfluxDB 3 Core).

  When every top-level conjunct of the `WHERE` is one its interval analysis
  can take, and the comparisons of a bare `Int64`, `UInt64` or `Float64`
  column with literals leave that column an empty interval, the query fails
  with status 500 instead of answering `[]`. The analysis reads:

    * `<`, `<=`, `>`, `>=`, `=`, either way round, `BETWEEN`, a one-element
      `IN`, and a `NOT` of those, against a number or a `$param` that is one
    * an integer column's exclusive bound as the next integer (`v > 1 AND
      v < 2` is empty), a float column's as the next double
    * a bound at the end of the type's range as that end (`v > 9223372036854775807`
      alone is not empty), except `u < 0` on an unsigned column, which is

  Any conjunct the analysis cannot take makes it give up, and the answer is
  the rows: `!=`, `NOT IN`, `NOT BETWEEN`, a longer `IN`, `IS [NOT] NULL`
  of a column, a null or text comparand, a string, tag or boolean column, a
  comparison of `time`, an `OR`, a constant false, two different `=` of one
  column, a negative literal against an unsigned column. An integer column
  compared with a float literal is cast by the engine and does not take
  part.

  The same analysis evaluates the constants of the conjuncts it takes, and one
  that overflows (the negation of the smallest integer of a type) fails the
  query before any row is read: status 500, `Arrow error: Arithmetic overflow:
  Overflow happened on: - -9223372036854775808`. It does so only when the
  analysis takes every conjunct; with one it cannot take (or in a select
  list) the constant is read per row, and the connection is closed
  (`SQLNumber.negate/2`).

  The body names the first conjunct, in the order written (`BETWEEN` is
  `>= low` then `<= high`): a lower bound or `>=` reads `lhs:Null,
  rhs:<type>`, an upper bound `lhs:<type>, rhs:Null`, an `=` is the
  `intersectable` variant reading `lhs:Null, rhs:<type>`; the type is that
  conjunct's column's.

  What this does not pin down is refused by name: a column with two bounds
  one of which implies the other (the engine's choice of conjunct then
  changes with the set), an integer column bounded by both an integer and a
  float literal, a conjunct whose analysis is not known (an arithmetic
  expression, a comparison of two columns), and a filter over a CTE.
  """

  import Bitwise

  alias InfluxElixir.Client.Local.{SQLError, SQLExpr, SQLFold, SQLLimits, SQLPredicates}

  require SQLLimits

  @typedoc "What the engine's analysis reads a numeric column as; `:other` is any other column."
  @type column_type :: :int64 | :uint64 | :float64 | :other

  @typedoc "Looks up a column's type, or `nil` for a column that is not there."
  @type type_of :: (binary() -> column_type() | nil)

  @int64_min SQLLimits.int64_min()
  @int64_max SQLLimits.int64_max()
  @uint64_max SQLLimits.uint64_max()
  @float_max SQLLimits.float_max()

  @bounds [:gt, :gte, :lt, :lte, :eq]

  @mixed "an integer column bounded by an integer and a float literal"

  @typep leaf ::
           {:disabler, [binary() | :any]}
           | {:unknown, binary()}
           | {:bound, binary(), column_type(), atom(), number()}
           | {:cast, binary(), column_type(), atom(), float()}
           | {:overflow, binary()}
           | :division

  @doc """
  Whether the engine fails the `WHERE`: `:ok`, or the engine's error, or the
  refusal of a shape that is not pinned down. `opts` may carry `cte: true`
  when the query filters a CTE, whose filter the engine may or may not push
  to the table: the failure is refused rather than answered.
  """
  @spec check([term()], type_of(), keyword()) :: :ok | {:error, SQLError.t()}
  def check(where, type_of, opts \\ []) do
    leaves = where |> SQLPredicates.flatten(false, leaf_spec(type_of)) |> fold_disablers()

    cte? = Keyword.get(opts, :cte, false)

    cond do
      Enum.any?(leaves, &match?({:disabler, _columns}, &1)) ->
        :ok

      overflow = Enum.find(leaves, &match?({:overflow, _text}, &1)) ->
        overflow(leaves, overflow, cte?)

      :division in leaves ->
        division(leaves)

      true ->
        leaves |> analyse() |> answer(cte?)
    end
  end

  # A constant that divides a minimum by -1 makes the analysis' intervals
  # disagree in type when another comparison meets it, an internal error whose
  # wording the double does not model; alone, it is read per row and closes
  # the connection.
  @spec division([leaf()]) :: :ok | {:error, SQLError.t()}
  defp division(leaves) do
    taken = Enum.reject(leaves, &match?({:unknown, _what}, &1))

    if match?([_, _ | _], leaves) and taken != [],
      do:
        {:error,
         SQLError.refusal(
           "a WHERE with a constant that divides a minimum by -1 beside another comparison: " <>
             "the engine fails it in its interval analysis with an internal error that is " <>
             "not modelled"
         )},
      else: :ok
  end

  # The analysis meets a constant that overflows: it fails the query, unless
  # a conjunct it cannot take is there, whose effect on it is not pinned down.
  @spec overflow([leaf()], {:overflow, binary()}, boolean()) :: :ok | {:error, SQLError.t()}
  defp overflow(leaves, {:overflow, text}, cte?) do
    case Enum.find(leaves, &match?({:unknown, _what}, &1)) do
      {:unknown, what} ->
        {:error,
         SQLError.refusal(
           "a WHERE with a constant that overflows (a negated minimum) beside #{what}: the " <>
             "engine's answer is not pinned down"
         )}

      nil when cte? ->
        {:error,
         SQLError.refusal(
           "a WHERE over a CTE with a constant that overflows (a negated minimum): the " <>
             "engine's answer depends on where it pushes the filter"
         )}

      nil ->
        {:error, SQLError.overflow(text)}
    end
  end

  # A predicate that stops the analysis stops it only if the optimizer
  # keeps it: it may fold one that an equality of the same column decides
  # (`v = 2 AND v IN (1, 2)`), which is not pinned down.
  @spec fold_disablers([leaf()]) :: [leaf()]
  defp fold_disablers(leaves) do
    equal = for {:bound, column, _type, :eq, _value} <- leaves, do: column

    Enum.map(leaves, fn
      {:disabler, columns} = disabler ->
        if equal != [] and (:any in columns or Enum.any?(columns, &(&1 in equal))),
          do: {:unknown, "a predicate an equality of the same column may decide"},
          else: disabler

      other ->
        other
    end)
  end

  # ---------------------------------------------------------------------------
  # The conjuncts
  # ---------------------------------------------------------------------------

  # What `SQLPredicates.flatten/3` puts for each kind of conjunct: a constant
  # false or a conjunct that hides its columns stops the analysis.
  @spec leaf_spec(type_of()) :: SQLPredicates.leaves()
  defp leaf_spec(type_of) do
    %{
      never: {:disabler, []},
      opaque: &{:disabler, columns_of(&1)},
      clause: &clause_leaves(&1, &2, type_of)
    }
  end

  @spec clause_leaves(term(), boolean(), type_of()) :: [leaf()]
  defp clause_leaves({:truthy, column, _nil}, _negated, _type_of), do: [{:disabler, [column]}]

  defp clause_leaves({op, operand, rhs}, negated, type_of) do
    op = if negated, do: SQLPredicates.negate_op(op), else: op

    case overflowing(operand, rhs) do
      nil -> clause(op, operand, rhs, type_of)
      leaf -> overflow_leaves(op, operand, rhs, leaf, type_of)
    end
  end

  defp clause_leaves(_other, _negated, _type_of), do: [{:unknown, "an unrecognised predicate"}]

  # The leaf for the first constant overflow in a conjunct's operands: a
  # negation, or a division.
  @spec overflowing(term(), term()) :: {:overflow, binary()} | :division | nil
  defp overflowing(operand, rhs) do
    exprs = Enum.flat_map([operand, rhs], &operand_exprs/1)

    case Enum.find_value(exprs, &SQLFold.negation_overflow/1) do
      nil -> if Enum.any?(exprs, &SQLFold.division_overflow?/1), do: :division
      text -> {:overflow, text}
    end
  end

  @spec operand_exprs(term()) :: [SQLExpr.t()]
  defp operand_exprs({:expr, expr}), do: [expr]
  defp operand_exprs(list) when is_list(list), do: Enum.flat_map(list, &operand_exprs/1)
  defp operand_exprs({low, high}), do: operand_exprs(low) ++ operand_exprs(high)
  defp operand_exprs(_other), do: []

  # What a conjunct with an overflowing constant is to the analysis: the
  # comparisons it reads take it to the constant; the rest it cannot take.
  @spec overflow_leaves(atom(), term(), term(), {:overflow, binary()} | :division, type_of()) ::
          [leaf()]
  defp overflow_leaves(op, operand, rhs, leaf, type_of) do
    cond do
      op in [:ne, :not_in, :not_between, :is_null, :is_not_null] -> [{:disabler, [:any]}]
      op == :in and length(List.wrap(rhs)) > 1 -> [{:disabler, [:any]}]
      op not in [:in, :between | @bounds] -> [{:unknown, "a predicate the analysis may not take"}]
      is_binary(operand) -> overflow_column(operand, leaf, type_of)
      true -> overflow_expression(operand, leaf, type_of)
    end
  end

  @spec overflow_column(binary(), leaf(), type_of()) :: [leaf()]
  defp overflow_column("time", _leaf, _type_of), do: [{:unknown, "a comparison of time"}]

  defp overflow_column(column, leaf, type_of) do
    case type_of.(column) do
      nil -> [{:unknown, "a column the double does not know"}]
      :other -> [{:disabler, [column]}]
      _numeric -> [leaf]
    end
  end

  @spec overflow_expression(term(), leaf(), type_of()) :: [leaf()]
  defp overflow_expression({:expr, expr}, leaf, type_of) do
    types = for column <- SQLExpr.columns(expr), is_binary(column), do: type_of.(column)

    if Enum.all?(types, &(&1 in [:int64, :uint64, :float64])),
      do: [leaf],
      else: [{:unknown, "an expression over a column the double does not read as a number"}]
  end

  @spec clause(atom(), term(), term(), type_of()) :: [leaf()]
  defp clause(_op, {:expr, _expr}, _rhs, _type_of),
    do: [{:unknown, "an arithmetic expression compared"}]

  defp clause(:is_not_null, "time", _rhs, _type_of), do: []
  defp clause(_op, "time", _rhs, _type_of), do: [{:disabler, ["time"]}]

  defp clause(op, column, rhs, type_of) when is_binary(column) do
    case type_of.(column) do
      nil -> [{:unknown, "a column the double does not know"}]
      :other -> [{:disabler, [column]}]
      type -> numeric(op, column, type, rhs)
    end
  end

  @spec numeric(atom(), binary(), column_type(), term()) :: [leaf()]
  defp numeric(op, column, _type, _rhs)
       when op in [:ne, :not_in, :not_between, :is_null, :is_not_null],
       do: [{:disabler, [column]}]

  defp numeric(:in, column, type, [value]), do: bound(:eq, column, type, value)
  defp numeric(:in, column, _type, [_one, _two | _more]), do: [{:disabler, [column]}]

  defp numeric(:between, column, type, {low, high}) when type != :float64 do
    case {unwrap(low), unwrap(high)} do
      {l, h} when is_number(l) and is_number(h) and (is_float(l) or is_float(h)) ->
        [{:cast, column, type, :gte, l * 1.0}, {:cast, column, type, :lte, h * 1.0}]

      {l, h} ->
        bound(:gte, column, type, l) ++ bound(:lte, column, type, h)
    end
  end

  defp numeric(:between, column, type, {low, high}),
    do: bound(:gte, column, type, low) ++ bound(:lte, column, type, high)

  defp numeric(op, column, type, rhs) when op in @bounds, do: bound(op, column, type, rhs)
  defp numeric(_op, _column, _type, _rhs), do: [{:unknown, "a predicate on a number"}]

  @spec bound(atom(), binary(), column_type(), term()) :: [leaf()]
  defp bound(_op, column, _type, nil), do: [{:disabler, [column]}]
  defp bound(_op, column, _type, text) when is_binary(text), do: [{:disabler, [column]}]

  defp bound(_op, _column, _type, {:expr, _expr}),
    do: [{:unknown, "a column or expression compared"}]

  defp bound(op, column, type, {:uint, n}), do: bound(op, column, type, n)

  defp bound(op, column, type, n) when is_integer(n) do
    case {type, n} do
      {:uint64, n} when n < 0 -> [{:disabler, [column]}]
      {:float64, n} -> float_bound(op, column, n)
      {_integer, n} -> integer_bound(op, column, type, n)
    end
  end

  defp bound(op, column, :float64, x) when is_float(x), do: [{:bound, column, :float64, op, x}]
  defp bound(op, column, type, x) when is_float(x), do: [{:cast, column, type, op, x}]
  defp bound(_op, _column, _type, _other), do: [{:unknown, "a comparand of an unknown type"}]

  @spec unwrap(term()) :: term()
  defp unwrap({:uint, n}), do: n
  defp unwrap(other), do: other

  # The columns a predicate tree names; `:any` for what names none.
  @spec columns_of(term()) :: [binary() | :any]
  defp columns_of(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &columns_of/1)
  defp columns_of({:or, branches}), do: Enum.flat_map(branches, &columns_of/1)
  defp columns_of({:not, nodes}), do: columns_of(nodes)
  defp columns_of({:truthy, column, _nil}), do: [column]
  defp columns_of({_op, {:expr, _expr}, _rhs}), do: [:any]
  defp columns_of({_op, column, _rhs}) when is_binary(column), do: [column]
  defp columns_of(_other), do: [:any]

  @spec integer_bound(atom(), binary(), column_type(), integer()) :: [leaf()]
  defp integer_bound(op, column, :int64, n) when SQLLimits.is_int64(n),
    do: [{:bound, column, :int64, op, n}]

  defp integer_bound(op, column, :uint64, n) when SQLLimits.is_uint64(n),
    do: [{:bound, column, :uint64, op, n}]

  defp integer_bound(_op, _column, _type, _n),
    do: [{:unknown, "an integer past the column's range"}]

  @spec float_bound(atom(), binary(), integer()) :: [leaf()]
  defp float_bound(op, column, n) do
    [{:bound, column, :float64, op, n * 1.0}]
  rescue
    ArithmeticError -> [{:unknown, "an integer past the range of a double"}]
  end

  # ---------------------------------------------------------------------------
  # The analysis
  # ---------------------------------------------------------------------------

  @spec analyse([leaf()]) :: :ok | {:fail, leaf()} | {:refuse, binary()}
  defp analyse(leaves) do
    bounds = for {:bound, _column, _type, _op, _value} = leaf <- leaves, do: leaf
    casts = for {:cast, _column, _type, _op, _value} = leaf <- leaves, do: leaf
    by_column = Enum.group_by(bounds, &elem(&1, 1))
    cast_columns = Enum.group_by(Enum.map(casts, &as_float/1), &elem(&1, 1))
    groups = Map.values(Map.merge(by_column, cast_columns, fn _c, a, b -> a ++ b end))

    cond do
      Enum.any?(Map.values(by_column), &equal_conflict?/1) ->
        :ok

      bounds == [] ->
        :ok

      Enum.any?(Map.values(by_column) ++ Map.values(cast_columns), &empty?/1) ->
        failure(leaves, groups, bounds, by_column, casts)

      mixed_empty?(by_column, casts) ->
        {:refuse, @mixed}

      true ->
        :ok
    end
  end

  # Some column is left no value: the engine fails unless what decides how
  # is not known.
  @spec failure([leaf()], [[leaf()]], [leaf()], %{binary() => [leaf()]}, [leaf()]) ::
          {:fail, leaf()} | {:refuse, binary()}
  defp failure(leaves, groups, bounds, by_column, casts) do
    cond do
      mixed_empty?(by_column, casts) ->
        {:refuse, @mixed}

      unknown = Enum.find(leaves, &match?({:unknown, _what}, &1)) ->
        {:refuse, elem(unknown, 1)}

      Enum.any?(groups, &redundant?/1) ->
        {:refuse, "two bounds on one column, one implying the other"}

      true ->
        {:fail, hd(bounds)}
    end
  end

  # A float literal against an integer column is a bound of the column cast
  # to a double.
  @spec as_float(leaf()) :: leaf()
  defp as_float({:cast, column, _type, op, x}), do: {:bound, column, :float64, op, x}

  @spec mixed_empty?(%{binary() => [leaf()]}, [leaf()]) :: boolean()
  defp mixed_empty?(by_column, casts) do
    Enum.any?(casts, fn {:cast, column, _type, _op, _x} ->
      case Map.fetch(by_column, column) do
        {:ok, group} ->
          floats = for {:cast, ^column, _t, _o, _x} = cast <- casts, do: as_float(cast)
          not empty?(group) and not empty?(floats) and empty?(group ++ rounded(column, casts))

        :error ->
          false
      end
    end)
  end

  # The float-literal bounds of an integer column as the integer bounds they
  # act as.
  @spec rounded(binary(), [leaf()]) :: [leaf()]
  defp rounded(column, casts) do
    for {:cast, ^column, type, op, x} <- casts,
        bound <- round_cast(column, type, op, x),
        do: bound
  end

  @spec round_cast(binary(), column_type(), atom(), float()) :: [leaf()]
  defp round_cast(column, type, :gt, x), do: [{:bound, column, type, :gte, floor(x) + 1}]
  defp round_cast(column, type, :gte, x), do: [{:bound, column, type, :gte, ceil(x)}]
  defp round_cast(column, type, :lt, x), do: [{:bound, column, type, :lte, ceil(x) - 1}]
  defp round_cast(column, type, :lte, x), do: [{:bound, column, type, :lte, floor(x)}]

  defp round_cast(column, type, :eq, x),
    do: [{:bound, column, type, :gte, ceil(x)}, {:bound, column, type, :lte, floor(x)}]

  @spec equal_conflict?([leaf()]) :: boolean()
  defp equal_conflict?(group) do
    group
    |> Enum.filter(&match?({:bound, _c, _t, :eq, _v}, &1))
    |> Enum.map(&elem(&1, 4))
    |> Enum.uniq()
    |> length() > 1
  end

  @spec empty?([leaf()]) :: boolean()
  defp empty?(group) do
    {low, high} = interval(group)
    low > high
  end

  # The intersection of the bounds' intervals, inside the type's range.
  @spec interval([leaf()]) :: {number(), number()}
  defp interval([{:bound, _column, type, _op, _value} | _rest] = group) do
    {type_min(type), type_max(type)}
    |> then(fn start -> Enum.reduce(group, start, &narrow/2) end)
  end

  @spec narrow(leaf(), {number(), number()}) :: {number(), number()}
  defp narrow(leaf, {low, high}) do
    {l, h} = single(leaf)
    {max(low, l), min(high, h)}
  end

  @spec single(leaf()) :: {number(), number()}
  defp single({:bound, _column, type, op, x}) do
    {low, high} = {type_min(type), type_max(type)}

    case op do
      :gt -> {up(type, x), high}
      :gte -> {x, high}
      :lt -> {low, down(type, x)}
      :lte -> {low, x}
      :eq -> {x, x}
    end
  end

  @spec up(column_type(), number()) :: number()
  defp up(:float64, x), do: next_up(x)
  defp up(type, x), do: min(x + 1, type_max(type))

  @spec down(column_type(), number()) :: number()
  defp down(:float64, x), do: -next_up(-x)
  defp down(:int64, x), do: max(x - 1, @int64_min)
  defp down(:uint64, x), do: x - 1

  @spec type_min(column_type()) :: number()
  defp type_min(:int64), do: @int64_min
  defp type_min(:uint64), do: 0
  defp type_min(:float64), do: -@float_max

  @spec type_max(column_type()) :: number()
  defp type_max(:int64), do: @int64_max
  defp type_max(:uint64), do: @uint64_max
  defp type_max(:float64), do: @float_max

  # The next double above `x`, `x` itself at the largest finite one.
  @spec next_up(float()) :: float()
  defp next_up(x) when x >= @float_max, do: x

  defp next_up(x) do
    <<bits::unsigned-64>> = <<x::float-64>>
    sign = bits >>> 63
    magnitude = bits &&& 0x7FFF_FFFF_FFFF_FFFF

    next =
      cond do
        sign == 0 -> magnitude + 1
        magnitude == 0 -> 1
        true -> 1 <<< 63 ||| magnitude - 1
      end

    <<up::float-64>> = <<next::unsigned-64>>
    up
  end

  # One of two bounds of a column holds everywhere the other does.
  @spec redundant?([leaf()]) :: boolean()
  defp redundant?(group) do
    indexed = Enum.with_index(group)

    Enum.any?(indexed, fn {a, i} ->
      {al, ah} = single(a)

      Enum.any?(indexed, fn {b, j} ->
        {bl, bh} = single(b)
        i != j and al >= bl and ah <= bh
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # The answer
  # ---------------------------------------------------------------------------

  @spec answer(:ok | {:fail, leaf()} | {:refuse, binary()}, boolean()) ::
          :ok | {:error, SQLError.t()}
  defp answer(:ok, _cte), do: :ok

  defp answer({:refuse, what}, _cte),
    do:
      {:error,
       SQLError.refusal(
         "a WHERE that may leave a numeric column no value, with #{what}: the engine's answer is not pinned down"
       )}

  defp answer({:fail, _leaf}, true),
    do:
      {:error,
       SQLError.refusal(
         "a WHERE over a CTE that leaves a numeric column no value: the engine's answer " <>
           "depends on where it pushes the filter"
       )}

  defp answer({:fail, {:bound, _column, type, op, _value}}, false),
    do: {:error, SQLError.interval(op, type)}
end
