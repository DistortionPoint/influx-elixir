defmodule InfluxElixir.Client.Local.SQLExprType do
  @moduledoc false
  # The Arrow type an expression of `InfluxElixir.Client.Local.SQLExpr` has,
  # given the types of the columns (`InfluxElixir.Client.Local.SQLPlan` reads
  # them from the rows), as the engine types it (verified against InfluxDB 3
  # Core):
  #
  #   * a comparison, `AND`, `OR`, `NOT`, `IS ...`, `IN`, `BETWEEN` and `LIKE`
  #     are `Boolean`; `||` is `Utf8`
  #   * `CASE`, `COALESCE` and `NULLIF` have the common type of their results:
  #     the one type they share, `Float64` for an `Int64` with a `Float64`
  #     and, in a `CASE` only, `Utf8` for a number with text. Any other mix
  #     has no type here (`:mixed`), and the double refuses it by name
  #
  # A type that is not known (a column no row has, a `NULL`) is `nil`, which
  # is never refused.

  alias InfluxElixir.Client.Local.{SQLCommonType, SQLExpr, SQLFunctions}

  @booleans [:cmp, :and, :or, :not, :is_null, :is_bool, :is_distinct, :in, :between, :like]

  @typedoc "An Arrow type name, `nil` when not known, `:mixed` for a mix that has no type."
  @type type :: binary() | nil | :mixed

  @doc "The type of an expression."
  @spec type_of(SQLExpr.t(), %{binary() => binary()}) :: type()
  def type_of(expr, _columns) when is_tuple(expr) and elem(expr, 0) in @booleans, do: "Boolean"

  def type_of({:concat, left, right}, columns) do
    if "Utf8View" in [type_of(left, columns), type_of(right, columns)],
      do: "Utf8View",
      else: "Utf8"
  end

  def type_of({:case, _operand, whens, otherwise}, columns) do
    results = Enum.map(whens, &elem(&1, 1)) ++ List.wrap(otherwise)
    common(Enum.map(results, &type_of(&1, columns)), :case)
  end

  def type_of({:call, :coalesce, args}, columns),
    do: common(Enum.map(args, &type_of(&1, columns)), :coalesce)

  def type_of({:call, name, args}, columns) when name in [:greatest, :least],
    do: common(Enum.map(args, &type_of(&1, columns)), :coalesce)

  def type_of({:call, :nullif, [left, right]}, columns),
    do: common([type_of(left, columns), type_of(right, columns)], :coalesce)

  def type_of({:cast, inner, type}, columns),
    do: SQLFunctions.type_of({:cast, inner, type}, columns)

  def type_of(expr, columns), do: SQLFunctions.type_of(expr, columns)

  @doc "See `InfluxElixir.Client.Local.SQLCommonType.common/2`."
  @spec common([type()], :case | :coalesce) :: type()
  defdelegate common(types, mode), to: SQLCommonType
end
