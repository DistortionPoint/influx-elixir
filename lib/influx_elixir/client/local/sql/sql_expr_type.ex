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

  alias InfluxElixir.Client.Local.{SQLCommonType, SQLExpr, SQLFunctions, SQLTyped}

  @booleans [:cmp, :and, :or, :not, :is_null, :is_bool, :is_distinct, :in, :between, :like]

  @typedoc "An Arrow type name, `nil` when not known, `:mixed` for a mix that has no type."
  @type type :: binary() | nil | :mixed

  @doc "The type of an expression."
  @spec type_of(SQLExpr.t(), %{binary() => binary()}) :: type()
  def type_of(expr, columns), do: type_of(expr, columns, [])

  @doc """
  The type of an expression, the nodes `known` to be typed already (see
  `InfluxElixir.Client.Local.SQLTyped`) taken as they are.
  """
  @spec type_of(SQLExpr.t(), %{binary() => binary()}, SQLTyped.t()) :: type()
  def type_of(expr, columns, known)
      when known != [] and is_tuple(expr) and tuple_size(expr) > 0 do
    if recallable?(expr) do
      case SQLTyped.recall(known, expr) do
        {:ok, type} -> type
        :error -> node_type(expr, columns, known)
      end
    else
      node_type(expr, columns, known)
    end
  end

  def type_of(expr, columns, known), do: node_type(expr, columns, known)

  # The nodes typed from the types of the nodes under them.
  @spec recallable?(tuple()) :: boolean()
  defp recallable?({:concat, _left, _right}), do: true
  defp recallable?({:case, _operand, _whens, _otherwise}), do: true
  defp recallable?({:call, _name, _args}), do: true
  defp recallable?({kind, _inner}) when kind in [:neg, :pos], do: true
  defp recallable?({:op, _op, _left, _right}), do: true
  defp recallable?(_other), do: false

  @doc """
  The type of the node from the types of its parts, without looking for the node itself.
  """
  @spec node_type(SQLExpr.t(), %{binary() => binary()}, SQLTyped.t()) :: type()
  def node_type(expr, _columns, _known) when is_tuple(expr) and elem(expr, 0) in @booleans,
    do: "Boolean"

  def node_type({:concat, left, right}, columns, known) do
    if "Utf8View" in [type_of(left, columns, known), type_of(right, columns, known)],
      do: "Utf8View",
      else: "Utf8"
  end

  def node_type({:case, _operand, whens, otherwise}, columns, known) do
    results = Enum.map(whens, &elem(&1, 1)) ++ List.wrap(otherwise)
    common(Enum.map(results, &type_of(&1, columns, known)), :case)
  end

  def node_type({:call, :coalesce, args}, columns, known),
    do: common(Enum.map(args, &type_of(&1, columns, known)), :coalesce)

  def node_type({:call, name, args}, columns, known) when name in [:greatest, :least],
    do: common(Enum.map(args, &type_of(&1, columns, known)), :coalesce)

  def node_type({:call, :nullif, [left, right]}, columns, known),
    do: common([type_of(left, columns, known), type_of(right, columns, known)], :coalesce)

  def node_type({:cast, inner, type}, columns, _known),
    do: SQLFunctions.type_of({:cast, inner, type}, columns)

  def node_type(expr, columns, known), do: SQLFunctions.node_type(expr, columns, known)

  @doc "See `InfluxElixir.Client.Local.SQLCommonType.common/2`."
  @spec common([type()], :case | :coalesce) :: type()
  defdelegate common(types, mode), to: SQLCommonType
end
