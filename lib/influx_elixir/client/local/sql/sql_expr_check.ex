defmodule InfluxElixir.Client.Local.SQLExprCheck do
  @moduledoc false
  # The type errors the engine finds in the operators of
  # `InfluxElixir.Client.Local.SQLExpr` when it plans a query, whether or not a
  # row would reach them (verified against InfluxDB 3 Core). The planner words
  # some of them itself, which the select list carries as they are
  # (`Error during planning: ...`), and some are found by its type coercion,
  # which wraps them (`type_coercion\ncaused by\n...`) wherever they stand.
  #
  #   * a comparison of a boolean with another type, `AND` and `OR` of a
  #     non-boolean, and `||` of two non-strings are the planner's own
  #   * `NOT` and `IS [NOT] TRUE` of a non-boolean, `LIKE` of a non-string,
  #     `IN` and `BETWEEN` of a boolean with another type, a `CASE` whose
  #     results have no common type, and the calls of `COALESCE` and
  #     `NULLIF` are the coercion's
  #
  # A type the double cannot word (the mix of a number with text in a
  # `COALESCE`, a comparison of `time`, a `CASE` condition that is not a
  # boolean) is refused by name. A type not known is never refused.

  alias InfluxElixir.Client.Local.{SQLError, SQLExpr, SQLExprType}

  @type context :: :select | :where | :order_by

  # What `AND` and `OR` accept: a boolean, or the null literal (typed `Null`).
  @logical ["Boolean", "Null"]

  # What a timestamp has no common type with, as the engine's `CASE` finds it.
  @not_time ["Boolean", "Int64", "UInt64", "Float64", "Int32", "Int16", "Int8"]

  @doc "`:ok`, or the error for the operator at the top of `node` (its operands were checked)."
  @spec check(SQLExpr.t(), %{binary() => binary()}, context()) :: :ok | {:error, map()}
  def check({:cmp, op, left, right}, columns, context),
    do: comparison(op, type(left, columns), type(right, columns), context)

  def check({kind, left, right}, columns, context) when kind in [:and, :or],
    do: check_logical(kind, left, right, columns, context)

  def check({:not, inner}, columns, _context), do: boolean_operand(type(inner, columns))

  def check({:is_bool, inner, _value, _negated}, columns, _context),
    do: boolean_operand(type(inner, columns))

  def check({:is_distinct, left, right, negated}, columns, context),
    do: check_distinct(left, right, negated, columns, context)

  def check({:like, inner, pattern, _negated, ilike, _regex}, columns, _context),
    do: check_like(inner, pattern, ilike, columns)

  def check({:in, inner, items, _negated}, columns, _context),
    do: check_in(inner, items, columns)

  def check({:between, inner, low, high, _negated}, columns, _context),
    do: check_between(inner, low, high, columns)

  def check({:concat, left, right}, columns, context),
    do: check_concat(left, right, columns, context)

  def check({:case, operand, whens, otherwise}, columns, _context),
    do: check_case(operand, whens, otherwise, columns)

  def check({:call, :coalesce, args}, columns, context),
    do: check_coalesce(args, columns, context)

  def check({:call, :nullif, args}, columns, context), do: check_nullif(args, columns, context)
  def check(_other, _columns, _context), do: :ok

  @spec check_logical(:and | :or, SQLExpr.t(), SQLExpr.t(), %{binary() => binary()}, context()) ::
          :ok | {:error, map()}
  defp check_logical(kind, left, right, columns, context) do
    case {logical_type(left, columns), logical_type(right, columns)} do
      {l, r} when is_binary(l) and is_binary(r) and (l not in @logical or r not in @logical) ->
        planner(
          "Cannot infer common argument type for logical boolean operation #{l} #{word(kind)} #{r}",
          context
        )

      _boolean_or_unknown ->
        :ok
    end
  end

  @spec check_distinct(SQLExpr.t(), SQLExpr.t(), boolean(), %{binary() => binary()}, context()) ::
          :ok | {:error, map()}
  defp check_distinct(left, right, negated, columns, context) do
    operation = if negated, do: "IS NOT DISTINCT FROM", else: "IS DISTINCT FROM"

    case {type(left, columns), type(right, columns)} do
      {l, r} when is_binary(l) and is_binary(r) ->
        if incompatible?(l, r),
          do:
            planner(
              "Cannot infer common argument type for comparison operation #{l} #{operation} #{r}",
              context
            ),
          else: :ok

      _comparable ->
        :ok
    end
  end

  @spec check_like(SQLExpr.t(), SQLExpr.t(), boolean(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_like(inner, pattern, ilike, columns) do
    word = if ilike, do: "ILIKE", else: "LIKE"

    case {type(inner, columns), type(pattern, columns)} do
      {l, r} when is_binary(l) and is_binary(r) ->
        if text?(l) and text?(r),
          do: :ok,
          else:
            coercion("There isn't a common type to coerce #{l} and #{r} in #{word} expression")

      _text_or_unknown ->
        :ok
    end
  end

  @spec check_in(SQLExpr.t(), [SQLExpr.t()], %{binary() => binary()}) :: :ok | {:error, map()}
  defp check_in(inner, items, columns) do
    types = Enum.map(items, &type(&1, columns))
    operand = type(inner, columns)

    if is_binary(operand) and Enum.all?(types, &is_binary/1) and
         Enum.any?(types, &incompatible?(&1, operand)) do
      coercion(
        "Can not find compatible types to compare #{operand} with [#{Enum.join(types, ", ")}]"
      )
    else
      :ok
    end
  end

  @spec check_between(SQLExpr.t(), SQLExpr.t(), SQLExpr.t(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_between(inner, low, high, columns) do
    operand = type(inner, columns)

    bound =
      Enum.find([type(low, columns), type(high, columns)], fn bound ->
        is_binary(operand) and is_binary(bound) and incompatible?(bound, operand)
      end)

    if bound, do: {:error, SQLError.between_coercion(operand, bound)}, else: :ok
  end

  @spec check_concat(SQLExpr.t(), SQLExpr.t(), %{binary() => binary()}, context()) ::
          :ok | {:error, map()}
  defp check_concat(left, right, columns, context) do
    case {type(left, columns), type(right, columns)} do
      {l, r} when is_binary(l) and is_binary(r) ->
        cond do
          "Timestamp(ns)" in [l, r] and (text?(l) or text?(r)) ->
            {:error,
             SQLError.refusal(
               "a timestamp concatenated as text: the engine writes its nanoseconds, which " <>
                 "the double keeps only to the microsecond"
             )}

          text?(l) or text?(r) ->
            :ok

          true ->
            planner(
              "Cannot infer common string type for string concat operation #{l} || #{r}",
              context
            )
        end

      _text_or_unknown ->
        :ok
    end
  end

  @spec type(SQLExpr.t(), %{binary() => binary()}) :: SQLExprType.type()
  defp type(expr, columns), do: SQLExprType.type_of(expr, columns)

  # The type of an operand of `AND` or `OR`, where the engine types the null
  # literal as `Null`.
  @spec logical_type(SQLExpr.t(), %{binary() => binary()}) :: SQLExprType.type()
  defp logical_type({:lit, nil}, _columns), do: "Null"
  defp logical_type(expr, columns), do: type(expr, columns)

  @spec text?(binary()) :: boolean()
  defp text?(type), do: type in ["Utf8", "Utf8View", "Dictionary(Int32, Utf8)"]

  # Two types the engine finds no common type for in an `IN`, a `BETWEEN` or an
  # `IS DISTINCT FROM`: a boolean with anything else, a timestamp with a number.
  @spec incompatible?(binary(), binary()) :: boolean()
  defp incompatible?(left, right) do
    left == "Boolean" != (right == "Boolean") or
      ("Timestamp(ns)" in [left, right] and
         Enum.any?([left, right], &(&1 in ["Int64", "UInt64", "Float64"])))
  end

  @spec word(:and | :or) :: binary()
  defp word(:and), do: "AND"
  defp word(:or), do: "OR"

  @spec comparison(SQLExpr.comparison(), SQLExprType.type(), SQLExprType.type(), context()) ::
          :ok | {:error, map()}
  defp comparison(op, left, right, context) do
    cond do
      not (is_binary(left) and is_binary(right)) ->
        :ok

      "Timestamp(ns)" in [left, right] ->
        timestamp_comparison(op, left, right, context)

      left == "Boolean" != (right == "Boolean") ->
        planner(
          "Cannot infer common argument type for comparison operation #{left} " <>
            "#{SQLExpr.symbol(op)} #{right}",
          context
        )

      true ->
        :ok
    end
  end

  # A number has no order against a timestamp: the planner's error for a
  # literal, the type coercion's for a parameter (a non-negative integer one
  # is a `UInt64`). A comparison of timestamps, or with text or a null, is
  # not modelled.
  @spec timestamp_comparison(SQLExpr.comparison(), binary(), binary(), context()) ::
          {:error, map()}
  defp timestamp_comparison(op, left, right, context) do
    message =
      "Cannot infer common argument type for comparison operation #{left} #{SQLExpr.symbol(op)} #{right}"

    cond do
      "UInt64" in [left, right] and "Timestamp(ns)" in [left, right] and left != right ->
        coercion(message)

      Enum.any?([left, right], &(&1 in ["Int64", "Float64"])) and left != right ->
        planner(message, context)

      true ->
        {:error,
         SQLError.refusal(
           "a comparison of time with text or another time in the select list: the engine " <>
             "reads the other side as a timestamp, which is not modelled"
         )}
    end
  end

  @spec boolean_operand(SQLExprType.type()) :: :ok | {:error, map()}
  defp boolean_operand(type) when is_binary(type) and type != "Boolean",
    do:
      coercion(
        "Cannot infer common argument type for comparison operation #{type} IS DISTINCT FROM Boolean"
      )

  defp boolean_operand(_type), do: :ok

  # A `CASE` whose results share no type, or whose conditions are not
  # booleans, in the words the double can write.
  @spec check_case(
          SQLExpr.t() | nil,
          [{SQLExpr.t(), SQLExpr.t()}],
          SQLExpr.t() | nil,
          %{binary() => binary()}
        ) :: :ok | {:error, map()}
  defp check_case(operand, whens, otherwise, columns) do
    conditions = Enum.map(whens, &type(elem(&1, 0), columns))

    results =
      (Enum.map(whens, &type(elem(&1, 1), columns)) ++
         List.wrap(otherwise && [type(otherwise, columns)]))
      |> List.flatten()

    operand_type = operand && type(operand, columns)

    cond do
      is_nil(operand) and Enum.any?(conditions, &(is_binary(&1) and &1 != "Boolean")) ->
        {:error, SQLError.refusal("a CASE condition that is not a boolean: the engine casts it")}

      uncomparable?(operand_type, conditions) ->
        coercion(
          "Failed to coerce case (#{operand_type}) and when (#{Enum.join(conditions, ", ")}) " <>
            "to common types in CASE WHEN expression"
        )

      timestamp_with_text?(operand_type, conditions) ->
        {:error,
         SQLError.refusal(
           "a CASE comparing time with text: the engine reads the text as a timestamp, " <>
             "which is not modelled"
         )}

      SQLExprType.common(results, :case) == :mixed ->
        mixed_results(results)

      true ->
        :ok
    end
  end

  # A `CASE operand WHEN ...` whose operand and `WHEN` values, all typed, are a
  # boolean beside something that is not, or a timestamp beside a number or a
  # boolean.
  @spec uncomparable?(SQLExprType.type() | nil, [SQLExprType.type()]) :: boolean()
  defp uncomparable?(operand_type, conditions) when is_binary(operand_type) do
    types = [operand_type | conditions]

    Enum.all?(types, &is_binary/1) and
      (("Boolean" in types and Enum.any?(types, &(&1 != "Boolean"))) or
         ("Timestamp(ns)" in types and Enum.any?(types, &(&1 in @not_time))))
  end

  defp uncomparable?(_operand_type, _conditions), do: false

  # A timestamp compared with text, which the engine parses as a timestamp.
  @spec timestamp_with_text?(SQLExprType.type() | nil, [SQLExprType.type()]) :: boolean()
  defp timestamp_with_text?(operand_type, conditions) do
    types = [operand_type | conditions]
    "Timestamp(ns)" in types and Enum.any?(types, &(is_binary(&1) and text?(&1)))
  end

  @spec mixed_results([SQLExprType.type()]) :: {:error, map()}
  defp mixed_results([then_type, else_type]) when is_binary(then_type) and is_binary(else_type) do
    if "Boolean" in [then_type, else_type],
      do:
        coercion(
          "Failed to coerce then (#{then_type}) and else (#{else_type}) to common types in " <>
            "CASE WHEN expression"
        ),
      else:
        {:error, SQLError.refusal("a CASE whose results have no common type the double models")}
  end

  defp mixed_results(_results),
    do: {:error, SQLError.refusal("a CASE whose results have no common type the double models")}

  @spec check_coalesce([SQLExpr.t()], %{binary() => binary()}, context()) ::
          :ok | {:error, map()}
  defp check_coalesce([], _columns, context) do
    planner(
      "Execution error: Function 'coalesce' user-defined coercion failed with \"Execution error: " <>
        "coalesce must have at least one argument\" No function matches the given name and " <>
        "argument types 'coalesce()'. You might need to add explicit type casts.\n" <>
        "\tCandidate functions:\n\tcoalesce(UserDefined)",
      context
    )
  end

  defp check_coalesce(args, columns, context) do
    types = Enum.map(args, &type(&1, columns))

    case SQLExprType.common(types, :coalesce) do
      :mixed -> mixed_coalesce(types, context)
      _common -> :ok
    end
  end

  @spec mixed_coalesce([SQLExprType.type()], context()) :: :ok | {:error, map()}
  defp mixed_coalesce([first, second] = types, context)
       when is_binary(first) and is_binary(second) and first != second do
    if "Boolean" in types and not (first == "Boolean" and second == "Boolean") do
      planner(
        "Execution error: Function 'coalesce' user-defined coercion failed with " <>
          "\"Execution error: Fail to find the coerced type, errors: Some(Execution(" <>
          "\\\"Expect to get struct but got #{first}\\\"))\" No function matches the given " <>
          "name and argument types 'coalesce(#{first}, #{second})'. You might need to add " <>
          "explicit type casts.\n\tCandidate functions:\n\tcoalesce(UserDefined)",
        context
      )
    else
      mixed_refusal("COALESCE")
    end
  end

  defp mixed_coalesce(_types, _context), do: mixed_refusal("COALESCE")

  @spec check_nullif([SQLExpr.t()], %{binary() => binary()}, context()) ::
          :ok | {:error, map()}
  defp check_nullif(args, columns, context) do
    types = Enum.map(args, &type(&1, columns))
    names = Enum.join(types, ", ")

    cond do
      args == [] ->
        planner(nullif_arity("'nullif' does not support zero arguments", names), context)

      length(args) != 2 and Enum.all?(types, &is_binary/1) ->
        planner(
          nullif_arity(
            "Function 'nullif' expects 2 arguments but received #{length(args)}",
            names
          ),
          context
        )

      length(args) != 2 ->
        {:error, SQLError.refusal("NULLIF of #{length(args)} arguments, one of unknown type")}

      true ->
        nullif_types(types, context)
    end
  end

  @spec nullif_arity(binary(), binary()) :: binary()
  defp nullif_arity(head, names) do
    head <>
      " No function matches the given name and argument types 'nullif(#{names})'. " <>
      "You might need to add explicit type casts.\n\tCandidate functions:\n\tnullif(Comparable(2))"
  end

  @spec nullif_types([SQLExprType.type()], context()) :: :ok | {:error, map()}
  defp nullif_types([first, second] = types, context)
       when is_binary(first) and is_binary(second) do
    cond do
      first == "Boolean" != (second == "Boolean") ->
        planner(
          nullif_arity(
            "For function 'nullif' #{first} and #{second} is not comparable",
            Enum.join(types, ", ")
          ),
          context
        )

      SQLExprType.common(types, :coalesce) == :mixed ->
        mixed_refusal("NULLIF")

      true ->
        :ok
    end
  end

  defp nullif_types(_types, _context), do: :ok

  @spec mixed_refusal(binary()) :: {:error, map()}
  defp mixed_refusal(name) do
    {:error,
     SQLError.refusal(
       "#{name} of arguments with no common type the double models (a number with text, " <>
         "or a type other than Int64, Float64, text and Boolean)"
     )}
  end

  # The planner's own error carries no prefix in the select list; elsewhere it
  # is found by the type coercion.
  @spec planner(binary(), context()) :: {:error, map()}
  defp planner(message, :select), do: {:error, SQLError.planning(message)}
  defp planner(message, :order_by), do: order_by_error(message)
  defp planner(message, _context), do: coercion(message)

  # `ORDER BY` words an error by its first sentence, without the candidate
  # signatures. A call with no argument fails the plan itself (a `COALESCE()` is
  # an execution error, a 500, with nothing around it); one the type coercion
  # finds, by an execution error, is a 500 inside its wrapper.
  @spec order_by_error(binary()) :: {:error, map()}
  defp order_by_error(message) do
    head = message |> String.split(" No function matches", parts: 2) |> hd()

    cond do
      String.contains?(head, "coalesce must have at least one argument") ->
        {:error, %{status: 500, body: head}}

      String.starts_with?(head, "'") ->
        {:error, SQLError.planning(head)}

      String.starts_with?(head, "Execution error: ") ->
        {:error, %{status: 500, body: "type_coercion\ncaused by\n" <> head}}

      true ->
        coercion(head)
    end
  end

  @spec coercion(binary()) :: {:error, map()}
  defp coercion(message), do: {:error, SQLError.coercion(message)}
end
