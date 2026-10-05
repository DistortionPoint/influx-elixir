defmodule InfluxElixir.Client.Local.SQLExprType do
  @moduledoc false
  # The Arrow type an expression of `InfluxElixir.Client.Local.SQLExpr` has, given the
  # types of the columns (`InfluxElixir.Client.Local.SQLPlan` reads them from the rows), as
  # the engine types it (verified against InfluxDB 3 Core with `arrow_typeof`).
  #
  # This is the one table of types: every module that needs the type of an expression asks
  # `type_of/4` (or `known_type/4`), and none keeps a table of its own.
  #
  #   * a column has the type of the column; a literal its own (`NULL` is `Null`); a cast the
  #     type it casts to
  #   * a comparison, `AND`, `OR`, `NOT`, `IS ...`, `IN`, `BETWEEN` and `LIKE` are `Boolean`;
  #     `||` is `Utf8` (`Utf8View` beside a view)
  #   * a negation and a unary plus have the type of their operand (`-NULL` is `Null`)
  #   * an arithmetic operator on two numbers is the type `SQLNumber.result_type/2` gives
  #     them; with a `Null` on one side it is the type of the other, and `Int64` when both
  #     are `Null`
  #   * `CASE`, `COALESCE`, `GREATEST`, `LEAST` and `NULLIF` have the common type of their
  #     results (see `InfluxElixir.Client.Local.SQLCommonType`); `NULLIF(NULL, NULL)` is
  #     `Utf8View`
  #   * `abs` has the type of its argument (`Float64` for `NULL`); the other functions of
  #     numbers are `Float64`, and those of `InfluxElixir.Client.Local.SQLScalar` the type
  #     it gives them
  #
  # A type that is not known (a column no row has) is `nil`, which is never refused; a mix
  # of results that share no type is `:mixed`, which the checks refuse by name. `Null` is a
  # type of its own for the planner's checks; `known_type/4` is the same table with `Null`
  # read as not known, for the checks that never refuse a null.
  #
  # The engine types an expression twice. The planner types it as it builds the plan, before
  # any operand is coerced, and a `CASE` then has the type of its first result that is not
  # the null (the error of an operator over it, and the type a `WHERE` predicate is refused
  # with, name that type). The type coercion then gives the `CASE` the type its results
  # share (what `arrow_typeof` says), and finds the errors that wrap as `type_coercion`.
  # `:plan` asks for the first, `:coerced` (the default) for the second; they differ only
  # for a `CASE`, and for what is made of one.

  alias InfluxElixir.Client.Local.{
    SQLAggType,
    SQLCast,
    SQLCommonType,
    SQLExpr,
    SQLNumber,
    SQLScalar
  }

  alias InfluxElixir.Client.Local.SQLTyped

  @booleans [:cmp, :and, :or, :not, :is_null, :is_bool, :is_distinct, :in, :between, :like]

  @typedoc "An Arrow type name, `nil` when not known, `:mixed` for a mix that has no type."
  @type type :: binary() | nil | :mixed

  @typedoc "The Arrow types of the columns an expression reads."
  @type columns :: %{binary() => binary()}

  @typedoc "Which of the two typings of the engine: before or after the coercion."
  @type phase :: :plan | :coerced

  @doc """
  Whether an Arrow type name is a decimal: `Decimal128(?)` stands for one whose precision is
  not tracked (the result of an arithmetic operator on an `Int64` and a `UInt64`), the other
  two for those the engine's fold of a mix of numbers gives (see
  `InfluxElixir.Client.Local.SQLCommonType.planned/2`).
  """
  defguard is_decimal_type(type)
           when type in ["Decimal128(?)", "Decimal128(20, 0)", "Decimal128(35, 15)"]

  @doc "Whether an Arrow type name is one of the engine's numeric types."
  defguard is_numeric_type(type)
           when type in ["Int64", "UInt64", "Float64", "Int32", "Int16", "Int8"] or
                  is_decimal_type(type)

  @doc "Whether a type is one of the engine's numeric types (`is_numeric_type/1` outside a guard)."
  @spec numeric?(type()) :: boolean()
  def numeric?(type), do: is_numeric_type(type)

  @doc """
  The type of an expression, `Null` where the engine types it so. The nodes already typed in
  `memo` (see `InfluxElixir.Client.Local.SQLTyped`) are taken as they are.
  """
  @spec type_of(SQLExpr.t(), columns(), SQLTyped.t(), phase()) :: type()
  def type_of(expr, columns, memo \\ [], phase \\ :coerced)

  def type_of(expr, columns, memo, phase) when memo != [] and is_tuple(expr) do
    case SQLTyped.recall(memo, expr) do
      {:ok, {coerced, _planned}} when phase == :coerced -> coerced
      {:ok, {_coerced, planned}} -> planned
      :error -> node_type(expr, columns, memo, phase)
    end
  end

  def type_of(expr, columns, memo, phase), do: node_type(expr, columns, memo, phase)

  @doc """
  The two types of an expression, `{coerced, planned}`, found in the memo with one look, or
  from the types of its parts.
  """
  @spec pair(SQLExpr.t(), columns(), SQLTyped.t()) :: {type(), type()}
  def pair(expr, columns, memo) when memo != [] and is_tuple(expr) do
    case SQLTyped.recall(memo, expr) do
      {:ok, pair} -> pair
      :error -> types_of(expr, columns, memo)
    end
  end

  def pair(expr, columns, memo), do: types_of(expr, columns, memo)

  @doc """
  The two types of a node, `{coerced, planned}`, from the types of its parts: what a memo
  keeps for a node (see `InfluxElixir.Client.Local.SQLTyped`).
  """
  @spec types_of(SQLExpr.t(), columns(), SQLTyped.t()) :: {type(), type()}
  def types_of(node, columns, memo),
    do: {node_type(node, columns, memo, :coerced), node_type(node, columns, memo, :plan)}

  @doc "The type of an expression, with a `Null` read as a type not known (`nil`)."
  @spec known_type(SQLExpr.t(), columns(), SQLTyped.t(), phase()) :: type()
  def known_type(expr, columns, memo \\ [], phase \\ :coerced),
    do: known(type_of(expr, columns, memo, phase))

  @doc "A type with `Null` read as not known."
  @spec known(type()) :: type()
  def known("Null"), do: nil
  def known(type), do: type

  @doc """
  The type of an expression that reads no column, `:unknown` where it has none the table
  knows.
  """
  @spec constant_type(SQLExpr.t()) :: binary() | :unknown
  def constant_type(expr) do
    case type_of(expr, %{}) do
      type when is_binary(type) -> type
      _unknown_or_mixed -> :unknown
    end
  end

  @doc """
  The type of the node from the types of its parts, without looking for the node itself.
  """
  @spec node_type(SQLExpr.t(), columns(), SQLTyped.t(), phase()) :: type()
  def node_type(expr, _columns, _memo, _phase)
      when is_tuple(expr) and elem(expr, 0) in @booleans,
      do: "Boolean"

  # An aggregate the planner types differently from the coercion has its planner type under
  # the key `SQLAggType.plan_key/1` gives.
  def node_type({:field, ref}, columns, _memo, :plan) when is_binary(ref),
    do: Map.get(columns, SQLAggType.plan_key(ref)) || Map.get(columns, ref)

  def node_type({:field, ref}, columns, _memo, _phase), do: Map.get(columns, ref)
  def node_type({:lit, nil}, _columns, _memo, _phase), do: "Null"
  def node_type({:lit, value}, _columns, _memo, _phase) when is_integer(value), do: "Int64"
  def node_type({:lit, value}, _columns, _memo, _phase) when is_float(value), do: "Float64"

  def node_type({:lit, value}, _columns, _memo, _phase) when value in [:inf, :neg_inf],
    do: "Float64"

  def node_type({:lit, value}, _columns, _memo, _phase) when is_binary(value), do: "Utf8"
  def node_type({:lit, value}, _columns, _memo, _phase) when is_boolean(value), do: "Boolean"
  def node_type({:uint, _value}, _columns, _memo, _phase), do: "UInt64"
  def node_type({:uint_col, _name}, _columns, _memo, _phase), do: "UInt64"
  def node_type({:cast, _inner, type}, _columns, _memo, _phase), do: SQLCast.arrow_type(type)

  def node_type({kind, inner}, columns, memo, phase) when kind in [:neg, :pos],
    do: type_of(inner, columns, memo, phase)

  def node_type({:concat, left, right}, columns, memo, phase) do
    if "Utf8View" in [type_of(left, columns, memo, phase), type_of(right, columns, memo, phase)],
      do: "Utf8View",
      else: "Utf8"
  end

  def node_type({:op, _op, left, right}, columns, memo, phase),
    do: arithmetic(type_of(left, columns, memo, phase), type_of(right, columns, memo, phase))

  def node_type({:case, _operand, whens, otherwise}, columns, memo, phase) do
    thens = Enum.map(whens, &type_of(elem(&1, 1), columns, memo, phase))
    others = Enum.map(List.wrap(otherwise), &type_of(&1, columns, memo, phase))

    case phase do
      # The engine folds the types of the results from the `ELSE`.
      :coerced -> case_type(thens ++ others, others ++ thens)
      :plan -> first_result(thens ++ others)
    end
  end

  def node_type({:call, :nullif, [left, right]}, columns, memo, phase) do
    case {type_of(left, columns, memo, phase), type_of(right, columns, memo, phase)} do
      {"Null", "Null"} -> "Utf8View"
      types -> SQLCommonType.planned(Tuple.to_list(types), :nullif)
    end
  end

  def node_type({:call, name, args}, columns, memo, phase)
      when name in [:coalesce, :greatest, :least],
      do: SQLCommonType.planned(Enum.map(args, &type_of(&1, columns, memo, phase)), :coalesce)

  def node_type({:call, :abs, [arg]}, columns, memo, phase) do
    case type_of(arg, columns, memo, phase) do
      "Null" -> "Float64"
      type -> type
    end
  end

  def node_type({:call, name, args}, columns, memo, phase) do
    arguments = Enum.map(args, &type_of(&1, columns, memo, phase))

    cond do
      # The type of a function of a tag of numbers is not one the table knows.
      Enum.any?(arguments, &SQLCommonType.tag_numbers?/1) -> nil
      SQLScalar.function?(name) -> SQLScalar.type_of(name, arguments)
      true -> "Float64"
    end
  end

  def node_type(_other, _columns, _memo, _phase), do: nil

  # The type of a `CASE` once coerced: the type its results share. Results that share none are
  # the error of the `CASE` (found after the errors of what stands around it), so what stands
  # around it sees the type the planner gave it.
  @spec case_type([type()], [type()]) :: type()
  defp case_type(types, folded) do
    case SQLCommonType.common(types, :case) do
      :mixed -> mixed_case_type(types, folded)
      type -> type
    end
  end

  # Results that share no type the double models: numbers of the engine's own (an `Int64` with
  # a `UInt64` is a decimal), text beside a timestamp (a timestamp), else the first result.
  @spec mixed_case_type([type()], [type()]) :: type()
  defp mixed_case_type(types, folded) do
    cond do
      time_with_text?(types) -> "Timestamp(ns)"
      (planned = SQLCommonType.planned(folded, :case)) != :mixed -> planned
      true -> first_result(types)
    end
  end

  # Text beside a timestamp is read as a timestamp (verified: `CASE WHEN n THEN region ELSE
  # time END` is a `Timestamp(ns)` once coerced).
  @spec time_with_text?([type()]) :: boolean()
  defp time_with_text?(types) do
    typed = Enum.reject(types, &(is_nil(&1) or &1 == "Null"))

    "Timestamp(ns)" in typed and
      Enum.all?(typed, &(&1 in ["Timestamp(ns)", "Utf8", "Utf8View", "Dictionary(Int32, Utf8)"]))
  end

  # The planner's type of a `CASE`: the first of its results that is not the null.
  @spec first_result([type()]) :: type()
  defp first_result(types) do
    case Enum.reject(types, &(&1 == "Null")) do
      [] -> if types == [], do: nil, else: "Null"
      [first | _rest] -> first
    end
  end

  # The type of `left op right`: numbers take the type of the engine's arithmetic, a `Null`
  # beside a number is typed as the number (the engine coerces it), and `Null` beside `Null`
  # is an `Int64`. Anything else has no type here (a timestamp, text, or a type not known).
  @spec arithmetic(type(), type()) :: type()
  defp arithmetic(left, right) when is_numeric_type(left) and is_numeric_type(right),
    do: SQLNumber.result_type(left, right)

  defp arithmetic("Null", "Null"), do: "Int64"
  defp arithmetic("Null", type) when is_numeric_type(type), do: type
  defp arithmetic(type, "Null") when is_numeric_type(type), do: type
  defp arithmetic(_left, _right), do: nil

  @doc "See `InfluxElixir.Client.Local.SQLCommonType.common/2`."
  @spec common([type()], :case | :coalesce | :nullif) :: type()
  defdelegate common(types, mode), to: SQLCommonType
end
