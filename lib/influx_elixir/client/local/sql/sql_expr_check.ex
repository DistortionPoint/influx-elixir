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

  alias InfluxElixir.Client.Local.{
    SQLCast,
    SQLCommonType,
    SQLError,
    SQLExpr,
    SQLExprType,
    SQLNativeType,
    SQLNullType,
    SQLTime,
    SQLTyped
  }

  @type context :: :select | :where | :order_by

  # What the types of an operand are read with: the columns' types, the nodes typed already,
  # and the typing of the engine that is asked (see `InfluxElixir.Client.Local.SQLExprType`).
  @typep scope :: {%{binary() => binary()}, SQLTyped.t(), SQLExprType.phase()}

  # The operators the planner itself finds the errors of in the select list, from the types
  # of their operands as written; the type coercion types them again once coerced.
  @planned [:cmp, :and, :or, :concat, :is_distinct]

  @tag "Dictionary(Int32, Utf8)"
  @numbers ["Int64", "UInt64", "Float64", "Int32", "Int16", "Int8"]

  # What `AND` and `OR` accept: a boolean, or the null literal (typed `Null`).
  @logical ["Boolean", "Null"]

  # What a timestamp has no common type with, as the engine's `CASE` finds it.
  @not_time ["Boolean", "Int64", "UInt64", "Float64", "Int32", "Int16", "Int8"]

  @doc """
  `:ok`, or the error for the operator at the top of `node` (its operands were checked).
  `known` are the nodes already typed (see `InfluxElixir.Client.Local.SQLTyped`), which the
  operands are not typed again from.
  """
  @spec check(SQLExpr.t(), %{binary() => binary()}, context(), SQLTyped.t()) ::
          :ok | {:error, map()}
  def check(node, columns, :select, known)
      when elem(node, 0) in @planned or
             (elem(node, 0) == :call and
                elem(node, 1) in [:coalesce, :nullif]) do
    with :ok <- check_node(node, {columns, known, :plan}, :select),
         do: check_node(node, {columns, known, :coerced}, :where)
  end

  # A `WHERE` types the same operators by the types as written first (its errors are the
  # coercion's whatever pass finds them).
  def check(node, columns, :where, known)
      when elem(node, 0) in @planned or
             (elem(node, 0) == :call and
                elem(node, 1) in [:coalesce, :nullif]) do
    with :ok <- check_node(node, {columns, known, :plan}, :where),
         do: check_node(node, {columns, known, :coerced}, :where)
  end

  def check(node, columns, context, known),
    do: check_node(node, {columns, known, :coerced}, context)

  @doc """
  `:ok`, or the error for the operator at the top of `node` as the planner finds it, from the
  types of its operands as written.
  """
  @spec check_planned(SQLExpr.t(), %{binary() => binary()}, SQLTyped.t()) ::
          :ok | {:error, map()}
  def check_planned(node, columns, known), do: check_node(node, {columns, known, :plan}, :select)

  @spec check(SQLExpr.t(), %{binary() => binary()}, context()) :: :ok | {:error, map()}
  def check(node, columns, context), do: check(node, columns, context, SQLTyped.new())

  @spec check_node(SQLExpr.t(), scope(), context()) :: :ok | {:error, map()}
  defp check_node({:cmp, op, left, right}, columns, context),
    do: comparison(op, type(left, columns), type(right, columns), context, param?(left, right))

  defp check_node({kind, left, right}, columns, context) when kind in [:and, :or],
    do: check_logical(kind, left, right, columns, context)

  defp check_node({:not, inner}, columns, _context), do: boolean_operand(type(inner, columns))

  defp check_node({:is_bool, inner, _value, _negated}, columns, _context),
    do: boolean_operand(type(inner, columns))

  defp check_node({:is_distinct, left, right, negated}, columns, context),
    do: check_distinct(left, right, negated, columns, context)

  defp check_node({:like, inner, pattern, _negated, ilike, _regex}, columns, _context),
    do: check_like(inner, pattern, ilike, columns)

  defp check_node({:in, inner, items, _negated}, columns, _context),
    do: check_in(inner, items, columns)

  defp check_node({:between, inner, low, high, _negated}, columns, _context),
    do: check_between(inner, low, high, columns)

  defp check_node({:concat, left, right}, columns, context),
    do: check_concat(left, right, columns, context)

  defp check_node({:cast, inner, target}, columns, _context),
    do: check_cast(type(inner, columns), target)

  defp check_node({:case, operand, whens, otherwise}, columns, _context),
    do: check_case(operand, whens, otherwise, columns)

  defp check_node({:call, :coalesce, args}, columns, context),
    do: check_coalesce(args, columns, context)

  defp check_node({:call, :nullif, args}, columns, context),
    do: check_nullif(args, columns, context)

  defp check_node(_other, _columns, _context), do: :ok

  @spec check_logical(:and | :or, SQLExpr.t(), SQLExpr.t(), scope(), context()) ::
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

  @spec check_distinct(SQLExpr.t(), SQLExpr.t(), boolean(), scope(), context()) ::
          :ok | {:error, map()}
  defp check_distinct(left, right, negated, columns, context) do
    operation = if negated, do: "IS NOT DISTINCT FROM", else: "IS DISTINCT FROM"

    case {type(left, columns), type(right, columns)} do
      {l, r} when is_binary(l) and is_binary(r) ->
        cond do
          incompatible?(l, r) ->
            planner(
              "Cannot infer common argument type for comparison operation #{l} #{operation} #{r}",
              context
            )

          "Timestamp(ns)" in [l, r] and (text?(l) or text?(r)) ->
            time_with_text(left, right, negated)

          true ->
            :ok
        end

      _comparable ->
        :ok
    end
  end

  # The engine reads the text beside a time as a timestamp (verified: `time IS DISTINCT FROM
  # '2023-10-01'` is true of every instant but that midnight). A text it cannot read is the
  # optimizer's error for it, a text the double cannot read as a timestamp (a column, an
  # expression) is refused by name.
  @spec time_with_text(SQLExpr.t(), SQLExpr.t(), boolean()) :: :ok | {:error, map()}
  defp time_with_text({:field, "time"}, {:lit, text}, _negated) when is_binary(text),
    do: timestamp_text(text)

  defp time_with_text({:lit, text}, {:field, "time"}, _negated) when is_binary(text),
    do: timestamp_text(text)

  defp time_with_text(_left, _right, negated) do
    kind = if negated, do: :not_distinct, else: :distinct
    {:error, SQLError.late_refusal({:distinct_time_text, kind})}
  end

  @spec timestamp_text(binary()) :: :ok | {:error, map()}
  defp timestamp_text(text) do
    case SQLTime.timestamp_ns(text) do
      {:ok, _nanoseconds} -> :ok
      {:error, _error} = error -> error
    end
  end

  @spec check_like(SQLExpr.t(), SQLExpr.t(), boolean(), scope()) ::
          :ok | {:error, map()}
  defp check_like(inner, pattern, ilike, columns) do
    word = if ilike, do: "ILIKE", else: "LIKE"
    kind = if ilike, do: :ilike, else: :like

    case {type(inner, columns), type(pattern, columns)} do
      {l, r} when is_binary(l) and is_binary(r) ->
        nulls? = SQLNullType.null_valued?(inner) or SQLNullType.null_valued?(pattern)
        like_types(l, r, {word, kind}, nulls?)

      {l, r} ->
        null_like(l, r, null?(inner, columns), null?(pattern, columns))
    end
  end

  # A text with a text is matched. A tag beside a number the engine matches as text, beside a
  # timestamp it closes the connection (verified); any other pair has no common type.
  @spec like_types(binary(), binary(), {binary(), :like | :ilike}, boolean()) ::
          :ok | {:error, map()}
  defp like_types(left, right, {word, kind}, nulls?) do
    cond do
      text?(left) and text?(right) ->
        :ok

      @tag in [left, right] and "Timestamp(ns)" in [left, right] ->
        {:error, SQLError.closed()}

      nulls? and tag_number_order(left, right) != nil ->
        :ok

      order = tag_number_order(left, right) ->
        {:error, SQLError.late_refusal({:pattern_number, kind, order})}

      true ->
        coercion("There isn't a common type to coerce #{left} and #{right} in #{word} expression")
    end
  end

  # Which way round a tag and a number stand (a tag of numbers counts as a tag).
  @spec tag_number_order(binary(), binary()) :: :tag_number | :number_tag | nil
  defp tag_number_order(left, right) do
    cond do
      tag_beside_number?(left, right) -> :tag_number
      tag_beside_number?(right, left) -> :number_tag
      true -> nil
    end
  end

  @spec tag_beside_number?(binary(), binary()) :: boolean()
  defp tag_beside_number?(tag, other) do
    (tag == @tag and other in @numbers) or
      (SQLCommonType.tag_numbers?(tag) and
         (other in @numbers or text?(other) or SQLCommonType.tag_numbers?(other)))
  end

  # The untyped `NULL` beside a number, a boolean or a timestamp closes the connection (verified);
  # beside text it is null.
  @spec null_like(SQLExprType.type(), SQLExprType.type(), boolean(), boolean()) ::
          :ok | {:error, map()}
  defp null_like(left, right, left_null?, right_null?) do
    cond do
      left_null? and typed_non_text?(right) -> {:error, SQLError.closed()}
      right_null? and typed_non_text?(left) -> {:error, SQLError.closed()}
      true -> :ok
    end
  end

  @spec typed_non_text?(SQLExprType.type()) :: boolean()
  defp typed_non_text?(type), do: is_binary(type) and not text?(type)

  @spec null?(SQLExpr.t(), scope()) :: boolean()
  defp null?(expr, scope), do: raw_type(expr, scope) == "Null"

  @spec check_in(SQLExpr.t(), [SQLExpr.t()], scope()) :: :ok | {:error, map()}
  defp check_in(inner, items, columns),
    do: in_types(raw_type(inner, columns), Enum.map(items, &raw_type(&1, columns)))

  @doc """
  The engine's error for an `IN` list, or `:ok`, from the types of the operand and of the
  items (`"Null"` for the null literal, anything that is no type name for a type not known,
  which is never refused). The null is compatible with every type: `b IN (NULL, NULL)` and
  `b IN (NULL, b)` plan, `b IN (NULL, 1)` does not; and the null operand beside a list whose
  own types clash has no common type (verified: `NULL IN (true, 1)`).
  """
  @spec in_types(SQLExprType.type(), [SQLExprType.type()]) :: :ok | {:error, map()}
  def in_types(operand, types) do
    cond do
      not Enum.all?(types, &is_binary/1) ->
        :ok

      is_binary(operand) and operand != "Null" and Enum.any?(types, &incompatible?(&1, operand)) ->
        in_error(operand, types)

      operand == "Null" and clash?(types) ->
        in_error("Null", types)

      true ->
        :ok
    end
  end

  @spec in_error(binary(), [binary()]) :: {:error, map()}
  defp in_error(operand, types) do
    coercion(
      "Can not find compatible types to compare #{operand} with [#{Enum.join(types, ", ")}]"
    )
  end

  # Whether two of the types, the null apart, have no common type.
  @spec clash?([binary()]) :: boolean()
  defp clash?(types) do
    typed = types |> Enum.reject(&(&1 == "Null")) |> Enum.uniq()
    Enum.any?(typed, fn left -> Enum.any?(typed, &incompatible?(left, &1)) end)
  end

  @spec check_between(SQLExpr.t(), SQLExpr.t(), SQLExpr.t(), scope()) ::
          :ok | {:error, map()}
  defp check_between(inner, low, high, columns),
    do: between_types(raw_type(inner, columns), raw_type(low, columns), raw_type(high, columns))

  @doc """
  The engine's error for a `BETWEEN`, or `:ok`, from the types of the operand and of the two
  bounds (see `in_types/2`). The engine coerces the operand with the low bound and that with
  the high bound, and the error names the operand and the bound it failed at (verified:
  `b BETWEEN NULL AND 1` fails at `Boolean` and `Int64`, `NULL BETWEEN true AND 5` at `Null`
  and `Int64`, since the null took the type of the low bound).
  """
  @spec between_types(SQLExprType.type(), SQLExprType.type(), SQLExprType.type()) ::
          :ok | {:error, map()}
  def between_types(operand, low, high) do
    [low, high]
    |> Enum.reduce_while(operand, fn bound, common ->
      cond do
        not (is_binary(common) and is_binary(bound)) ->
          {:cont, common}

        incompatible?(bound, common) ->
          {:halt, {:error, SQLError.between_coercion(operand, bound)}}

        true ->
          {:cont, if(common == "Null", do: bound, else: common)}
      end
    end)
    |> case do
      {:error, _error} = error -> error
      _common -> :ok
    end
  end

  @spec check_concat(SQLExpr.t(), SQLExpr.t(), scope(), context()) ::
          :ok | {:error, map()}
  defp check_concat(left, right, columns, context) do
    case {concat_type(left, columns), concat_type(right, columns)} do
      {l, r} when is_binary(l) and is_binary(r) ->
        cond do
          not concatenable?(l, r) ->
            concat_error(l, r, context)

          "Timestamp(ns)" in [l, r] ->
            {:error, SQLError.late_refusal(:timestamp_concat)}

          true ->
            :ok
        end

      _text_or_unknown ->
        :ok
    end
  end

  # What the engine joins (verified over every pair of a text, a tag, a number, a boolean,
  # a timestamp and the null): anything beside plain text, and a tag beside a tag or the
  # null (the null beside plain text too). A struct beside anything is no text.
  @spec concatenable?(binary(), binary()) :: boolean()
  defp concatenable?(left, right) do
    cond do
      SQLNativeType.struct?(left) or SQLNativeType.struct?(right) -> false
      plain_text?(left) or plain_text?(right) -> true
      left == @tag -> right in [@tag, "Null"]
      left == "Null" -> right == @tag
      true -> false
    end
  end

  @spec plain_text?(binary()) :: boolean()
  defp plain_text?(type), do: type in ["Utf8", "Utf8View", "LargeUtf8"]

  # The type of a `||` operand, where the engine types the null as `Null`.
  @spec concat_type(SQLExpr.t(), scope()) :: SQLExprType.type()
  defp concat_type(expr, columns), do: raw_type(expr, columns)

  @spec concat_error(binary(), binary(), context()) :: {:error, map()}
  defp concat_error(left, right, context) do
    planner(
      "Cannot infer common string type for string concat operation #{left} || #{right}",
      context
    )
  end

  # A struct (the result of a selector) cannot be cast to anything.
  @spec check_cast(SQLExprType.type(), SQLExpr.cast_type()) :: :ok | {:error, map()}
  defp check_cast(type, target) do
    if SQLNativeType.struct?(type),
      do:
        {:error,
         %{
           status: 405,
           body:
             "This feature is not implemented: Unsupported CAST from #{type} to " <>
               SQLCast.arrow_type(target)
         }},
      else: :ok
  end

  # The type of an operand, the null read as a type not known (which is never refused).
  @spec type(SQLExpr.t(), scope()) :: SQLExprType.type()
  defp type(expr, scope), do: SQLExprType.known(raw_type(expr, scope))

  # The type of an operand, where the engine types the null as `Null`.
  @spec raw_type(SQLExpr.t(), scope()) :: SQLExprType.type()
  defp raw_type(expr, {columns, known, phase}),
    do: SQLExprType.type_of(expr, columns, known, phase)

  # The type of an operand of `AND` or `OR`, where the engine types the null as `Null`.
  @spec logical_type(SQLExpr.t(), scope()) :: SQLExprType.type()
  defp logical_type(expr, columns), do: raw_type(expr, columns)

  @spec text?(binary()) :: boolean()
  defp text?(type), do: type in ["Utf8", "Utf8View", "Dictionary(Int32, Utf8)"]

  # Two types the engine finds no common type for in an `IN`, a `BETWEEN` or an
  # `IS DISTINCT FROM`: a boolean with anything else, a timestamp with a number. The null
  # has a common type with every type (verified: `b IN (NULL, NULL)` and `b IN (NULL, b)` plan).
  @spec incompatible?(binary(), binary()) :: boolean()
  defp incompatible?("Null", _right), do: false
  defp incompatible?(_left, "Null"), do: false

  defp incompatible?(left, right) do
    left == "Boolean" != (right == "Boolean") or
      SQLNativeType.struct?(left) != SQLNativeType.struct?(right) or
      ("Timestamp(ns)" in [left, right] and
         Enum.any?([left, right], &SQLExprType.numeric?/1))
  end

  @spec word(:and | :or) :: binary()
  defp word(:and), do: "AND"
  defp word(:or), do: "OR"

  # Whether either side of a comparison is a bound `$name`: a non-negative integer one is a
  # `{:uint, n}`, which no literal is unless it is past `Int64` (taken for a literal).
  @spec param?(SQLExpr.t(), SQLExpr.t()) :: boolean()
  defp param?(left, right), do: bound?(left) or bound?(right)

  @spec bound?(SQLExpr.t()) :: boolean()
  defp bound?({:uint, number}), do: number <= 9_223_372_036_854_775_807
  defp bound?(_expr), do: false

  @spec comparison(
          SQLExpr.comparison(),
          SQLExprType.type(),
          SQLExprType.type(),
          context(),
          boolean()
        ) :: :ok | {:error, map()}
  defp comparison(op, left, right, context, param?) do
    cond do
      not (is_binary(left) and is_binary(right)) ->
        :ok

      "Timestamp(ns)" in [left, right] ->
        timestamp_comparison(op, left, right, context, param?)

      left == "Boolean" != (right == "Boolean") or
          SQLNativeType.struct?(left) != SQLNativeType.struct?(right) ->
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
  # literal or a column, the type coercion's for a parameter (a non-negative integer one
  # is a `UInt64`; verified: `time > $t` and `time > u` differ in the wrapper). A comparison of
  # timestamps, or with text or a null, is not modelled.
  @spec timestamp_comparison(SQLExpr.comparison(), binary(), binary(), context(), boolean()) ::
          {:error, map()}
  defp timestamp_comparison(op, left, right, context, param?) do
    message =
      "Cannot infer common argument type for comparison operation #{left} #{SQLExpr.symbol(op)} #{right}"

    cond do
      param? and "UInt64" in [left, right] and left != right ->
        coercion(message)

      Enum.any?([left, right], &(&1 in ["Int64", "UInt64", "Float64", "Boolean"])) and
          left != right ->
        planner(message, context)

      true ->
        {:error, SQLError.late_refusal(:compare_time_text)}
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
          scope()
        ) :: :ok | {:error, map()}
  defp check_case(operand, whens, otherwise, columns) do
    conditions = Enum.map(whens, &type(elem(&1, 0), columns))

    results =
      (Enum.map(whens, &type(elem(&1, 1), columns)) ++
         List.wrap(otherwise && [type(otherwise, columns)]))
      |> List.flatten()

    operand_type = operand && type(operand, columns)

    cond do
      uncomparable?(operand_type, conditions) ->
        coercion(
          "Failed to coerce case (#{operand_type}) and when (#{Enum.join(conditions, ", ")}) " <>
            "to common types in CASE WHEN expression"
        )

      timestamp_with_text?(operand_type, conditions) ->
        {:error, SQLError.late_refusal(:case_time_text)}

      SQLExprType.common(results, :case) == :mixed ->
        mixed_results(results)

      is_nil(operand) and Enum.any?(conditions, &uncastable_condition?/1) ->
        uncastable_error(Enum.find(conditions, &uncastable_condition?/1))

      is_nil(operand) and Enum.any?(conditions, &(is_binary(&1) and &1 != "Boolean")) ->
        {:error, SQLError.late_refusal(:case_condition)}

      true ->
        :ok
    end
  end

  @spec uncastable_error(binary()) :: {:error, map()}
  defp uncastable_error(type) do
    {:error,
     %{
       status: 400,
       body:
         "type_coercion\ncaused by\nWHEN expressions in CASE couldn't be converted to common " <>
           "type (Boolean)\ncaused by\nError during planning: Cannot automatically convert " <>
           "#{type} to Boolean"
     }}
  end

  # The types a `CASE` condition cannot be cast to a boolean from (a number or text can).
  @spec uncastable_condition?(SQLExprType.type()) :: boolean()
  defp uncastable_condition?(type),
    do: type == "Timestamp(ns)" or (is_binary(type) and SQLNativeType.struct?(type))

  # A `CASE operand WHEN ...` whose operand and `WHEN` values, all typed, are a
  # boolean beside something that is not, or a timestamp beside a number or a
  # boolean.
  @spec uncomparable?(SQLExprType.type() | nil, [SQLExprType.type()]) :: boolean()
  defp uncomparable?(operand_type, conditions) when is_binary(operand_type) do
    types = [operand_type | conditions]

    Enum.all?(types, &is_binary/1) and
      (("Boolean" in types and Enum.any?(types, &(&1 != "Boolean"))) or
         ("Timestamp(ns)" in types and Enum.any?(types, &(&1 in @not_time))) or
         (Enum.any?(types, &SQLNativeType.struct?/1) and
            not Enum.all?(types, &SQLNativeType.struct?/1)))
  end

  defp uncomparable?(_operand_type, _conditions), do: false

  # A timestamp compared with text, which the engine parses as a timestamp.
  @spec timestamp_with_text?(SQLExprType.type() | nil, [SQLExprType.type()]) :: boolean()
  defp timestamp_with_text?(operand_type, conditions) do
    types = [operand_type | conditions]
    "Timestamp(ns)" in types and Enum.any?(types, &(is_binary(&1) and text?(&1)))
  end

  @case_numbers ["Int64", "UInt64", "Float64"]

  @spec mixed_results([SQLExprType.type()]) :: {:error, map()}
  defp mixed_results(results) do
    cond do
      Enum.all?(results, &(&1 in @case_numbers)) ->
        {:error, SQLError.late_refusal(:case_numbers)}

      match?([a, b] when is_binary(a) and is_binary(b), results) ->
        mixed_pair(results)

      true ->
        {:error, SQLError.refusal("a CASE whose results have no common type the double models")}
    end
  end

  @spec mixed_pair([SQLExprType.type()]) :: {:error, map()}
  defp mixed_pair([then_type, else_type]) do
    if "Boolean" in [then_type, else_type],
      do:
        coercion(
          "Failed to coerce then (#{then_type}) and else (#{else_type}) to common types in " <>
            "CASE WHEN expression"
        ),
      else:
        {:error, SQLError.refusal("a CASE whose results have no common type the double models")}
  end

  @spec check_coalesce([SQLExpr.t()], scope(), context()) ::
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
      common -> text_cast(:coalesce, args, types, common)
    end
  end

  # A number with text: the engine casts the text to the number (so the result is the number)
  # and fails when it runs the plan, with the cast's error when the text is a literal that
  # reads as no number (it folds the constant), with a closed connection when a value of a
  # column does not cast. The double does not cast text, so it refuses what could cast.
  @spec text_cast(:coalesce | :nullif, [SQLExpr.t()], [SQLExprType.type()], SQLExprType.type()) ::
          :ok | {:error, map()}
  defp text_cast(name, args, types, common) do
    if SQLCommonType.number_with_text?(types) do
      number = String.replace(common, ~r/\ADictionary\(Int32, (.+)\)\z/, "\\1")

      case Enum.find(args, &unreadable_number?/1) do
        {:lit, text} ->
          {:error,
           SQLError.simplify(
             "Arrow error: Cast error: Cannot cast string '#{text}' to value of #{number} type"
           )}

        nil ->
          {:error, SQLError.late_refusal({:no_common_type, name, number_family(types)})}
      end
    else
      :ok
    end
  end

  # A text literal with a character no number is written with.
  @spec unreadable_number?(SQLExpr.t()) :: boolean()
  defp unreadable_number?({:lit, text}) when is_binary(text),
    do: Regex.match?(~r/[^0-9+\-.eE \t\r\n]/u, text)

  defp unreadable_number?(_expr), do: false

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
      mixed_refusal(:coalesce, types)
    end
  end

  defp mixed_coalesce(types, _context), do: mixed_refusal(:coalesce, types)

  @spec check_nullif([SQLExpr.t()], scope(), context()) ::
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
        with :ok <- nullif_types(types, context),
             do: text_cast(:nullif, args, types, SQLExprType.common(types, :nullif))
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

      SQLExprType.common(types, :nullif) == :mixed ->
        mixed_refusal(:nullif, types)

      true ->
        :ok
    end
  end

  defp nullif_types(_types, _context), do: :ok

  # Numbers with text the engine casts to one another when it runs the plan (the connection
  # closes where a value does not cast); any other mix is its planning error, not worded here.
  @spec mixed_refusal(:coalesce | :nullif, [SQLExprType.type()]) :: {:error, map()}
  defp mixed_refusal(name, types) do
    if SQLCommonType.number_with_text?(types) do
      {:error, SQLError.late_refusal({:no_common_type, name, number_family(types)})}
    else
      mixed_numbers(name, types)
    end
  end

  # Numbers the double does not combine are computed by the engine, with no planning error.
  @spec mixed_numbers(:coalesce | :nullif, [SQLExprType.type()]) :: {:error, map()}
  defp mixed_numbers(name, types) do
    if SQLCommonType.numbers?(types) do
      {:error, SQLError.late_refusal({:numbers_not_combined, name})}
    else
      shown = types |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.join(", ")

      {:error,
       SQLError.refusal(
         "#{call_word(name)} of #{shown}: they have no common type the double models (it models " <>
           "Int64, Float64, text and Boolean, each beside its own kind)"
       )}
    end
  end

  # The kind of number a mix of a number with text holds.
  @spec number_family([SQLExprType.type()]) :: :integer | :float | :decimal
  defp number_family(types) do
    cond do
      "Float64" in types -> :float
      Enum.any?(types, &(is_binary(&1) and String.starts_with?(&1, "Decimal128"))) -> :decimal
      true -> :integer
    end
  end

  @spec call_word(:coalesce | :nullif) :: binary()

  defp call_word(:coalesce), do: "COALESCE"
  defp call_word(:nullif), do: "NULLIF"

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
