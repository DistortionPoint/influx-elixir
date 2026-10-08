defmodule InfluxElixir.Client.Local.SQLDmlItem do
  @moduledoc false
  # The names of the items of the `SELECT` that an `INSERT ... SELECT` reads, for
  # `InfluxElixir.Client.Local.SQLDmlInsert` (verified against InfluxDB 3 Core 3.10.1): the
  # planner refuses a list in which two items have the same name,
  #
  #     Projections require unique expression names but the expression "Int64(0)" at position 0
  #     and "Int64(0)" at position 1 have the same name. Consider aliasing ("AS") one of them.
  #
  # after it has found the names and calls of every item and before it types any of them. An
  # item is named by its alias (an unquoted one in lower case), else by its expression as the
  # planner names it: the expression printed, with a cast taken off (`CAST(n AS BIGINT)` and
  # `n` have the name `main.n`). The error prints the expressions, casts and ` AS alias`
  # included. The position is that of the item once `*` is expanded; the error is that of the
  # first item that has the name of one before it.
  #
  # An expression is printed as the planner prints it: `Int64(0)`, `Float64(1.5)`, `Utf8("a")`,
  # `Boolean(true)`, `NULL`, `$1`, a column qualified by the relation as the `FROM` wrote it
  # (`main.n`), an operator between its operands (an operand that is an operator of a lower
  # precedence in parentheses; the planner leaves an operand of the same precedence bare),
  # `(- x)`, `NOT x`, `x IS [NOT] NULL|TRUE|FALSE|UNKNOWN`, `x [NOT] IN ([a, b])`,
  # `x [NOT] BETWEEN a AND b`, `x [NOT] LIKE|ILIKE p`, `CAST(x AS Int32)`, `abs(x)`, `now()`,
  # `CURRENT_TIMESTAMP` (`now() AS current_timestamp()`, named `current_timestamp()`). A unary
  # plus is not printed. What the double does not print (a timestamp cast, which the planner
  # writes as two, a function it does not know the name of) is compared by its shape: two such
  # items of one shape have the same name, and the error is refused by name, as its words cannot
  # be printed. Items of different shapes are taken to have different names.

  alias InfluxElixir.Client.Local.{SQLDml, SQLDmlExpr, SQLDmlOperand, SQLError}

  @typep item :: {SQLDmlExpr.ast(), SQLDmlExpr.item_alias()}
  @typep mode :: :display | :name

  # The precedence the planner prints an operator's operands by.
  @precedence %{
    "OR" => 5,
    "AND" => 10,
    "=" => 20,
    "==" => 20,
    "<>" => 20,
    "!=" => 20,
    "<" => 20,
    "<=" => 20,
    ">" => 20,
    ">=" => 20,
    "||" => 25,
    "+" => 30,
    "-" => 30,
    "*" => 40,
    "/" => 40,
    "%" => 40
  }
  @printed %{"==" => "=", "<>" => "!="}
  @printed_functions ~w(abs coalesce)

  @doc """
  `:ok` when no two items have the same name, else the planner's error, or a refusal by name
  when the words of the error cannot be printed.
  """
  @spec unique([item()], SQLDmlOperand.ctx()) :: SQLDmlOperand.check()
  def unique(items, ctx) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {{operand, alias_name}, position}, seen ->
      {key, shown} = describe(operand, alias_name, ctx)

      case seen do
        %{^key => {first_position, first_shown, first_operand}} ->
          {:halt,
           {:duplicate, {first_position, first_shown, first_operand}, {position, shown, operand}}}

        _unseen ->
          {:cont, Map.put(seen, key, {position, shown, operand})}
      end
    end)
    |> verdict(ctx)
  end

  # The output has a column of the table (qualified by it) and an item named as a column of it
  # (qualified by none): the schema of the projection cannot tell them apart. The planner names
  # the first such column, in the order of the names.
  @doc """
  `:ok`, or the planner's error for a projection that has a column of the table and an item named
  as one (found when the projection has been typed).
  """
  @spec ambiguous([item()], SQLDmlOperand.ctx()) :: SQLDmlOperand.check()
  def ambiguous(items, ctx) do
    named =
      for {operand, {alias_name, _quoted}} <- items,
          not own_name?(operand, alias_name, ctx),
          do: alias_name

    columns =
      for {{:ref, parts}, nil} <- items,
          SQLDmlOperand.column?(parts, ctx),
          {column, _quoted} = List.last(parts),
          column in named,
          do: column

    case columns do
      [] ->
        :ok

      _clashing ->
        name = Enum.min(columns)

        {:error,
         %{
           status: 500,
           body:
             "Schema error: Schema contains qualified field name #{ctx.relation_text}.#{name} " <>
               "and unqualified field name #{name} which would be ambiguous"
         }}
    end
  end

  @spec verdict(map() | {:duplicate, term(), term()}, SQLDmlOperand.ctx()) ::
          SQLDmlOperand.check()
  defp verdict({:duplicate, {first, first_shown, _operand}, {second, second_shown, _other}}, _ctx)
       when is_binary(first_shown) and is_binary(second_shown) do
    {:error,
     SQLError.planning(
       "Projections require unique expression names but the expression \"#{first_shown}\" " <>
         "at position #{first} and \"#{second_shown}\" at position #{second} have the same " <>
         "name. Consider aliasing (\"AS\") one of them."
     )}
  end

  # The words of the error print both expressions: the refusal names the first that the double
  # does not print, by what it cannot print of it.
  defp verdict({:duplicate, {_position, nil, first_operand}, _second}, ctx),
    do: unprintable(first_operand, ctx)

  defp verdict({:duplicate, _first, {_position, nil, second_operand}}, ctx),
    do: unprintable(second_operand, ctx)

  defp verdict(%{}, _ctx), do: :ok

  @spec unprintable(SQLDmlExpr.ast(), SQLDmlOperand.ctx()) :: {:refuse, SQLDml.reason()}
  defp unprintable(operand, ctx),
    do: {:refuse, "two select items that have the same name, one #{cause(operand, ctx)}"}

  # What the double cannot print of an expression: the first part of it that it cannot, else
  # the expression itself.
  @spec cause(SQLDmlExpr.ast(), SQLDmlOperand.ctx()) :: binary()
  defp cause(operand, ctx) do
    case Enum.find(SQLDmlExpr.children(operand), &(render(&1, ctx, :display) === :unknown)) do
      nil -> own_cause(operand)
      part -> cause(part, ctx)
    end
  end

  @spec own_cause(SQLDmlExpr.ast()) :: binary()
  defp own_cause({:str, _body}),
    do: "with a string whose characters the double does not print"

  defp own_cause({:num, _text}), do: "with a number the double does not print"
  defp own_cause({:ref, _parts}), do: "with a name the double does not print as a column"

  defp own_cause({:cast, _inner, _type, _try}),
    do: "with a cast to a type the double does not print"

  defp own_cause({:call, _name, _args}), do: "with a call the double does not print"
  defp own_cause({:ordered, _call, _terms}), do: "with a call the double does not print"
  defp own_cause({:bin, _op, _left, _right}), do: "with an operator the double does not print"
  defp own_cause(_other), do: "with an expression of a kind the double does not print"

  # The key an item is compared by, and the expression as the error prints it (`nil` when the
  # double does not print it).
  @spec describe(SQLDmlExpr.ast(), SQLDmlExpr.item_alias(), SQLDmlOperand.ctx()) ::
          {term(), binary() | nil}
  defp describe(operand, nil, ctx) do
    key =
      case render(operand, ctx, :name) do
        :unknown -> {:shape, shape(operand)}
        named -> {:name, named}
      end

    {key, printed(render(operand, ctx, :display))}
  end

  # A column named by an alias that is its own name is not aliased (the planner keeps it bare).
  defp describe(operand, {alias_name, _quoted} = item_alias, ctx) do
    if own_name?(operand, alias_name, ctx),
      do: describe(operand, nil, ctx),
      else: describe_aliased(operand, item_alias, ctx)
  end

  @spec own_name?(SQLDmlExpr.ast(), binary(), SQLDmlOperand.ctx()) :: boolean()
  defp own_name?({:ref, parts}, alias_name, ctx),
    do: SQLDmlOperand.column?(parts, ctx) and parts |> List.last() |> elem(0) == alias_name

  defp own_name?(_operand, _alias_name, _ctx), do: false

  @spec describe_aliased(SQLDmlExpr.ast(), SQLDmlExpr.item_alias(), SQLDmlOperand.ctx()) ::
          {term(), binary() | nil}
  defp describe_aliased(operand, {alias_name, _quoted}, ctx) do
    shown =
      case render(operand, ctx, :display) do
        :unknown -> nil
        text -> text <> " AS " <> alias_name
      end

    {{:name, alias_name}, shown}
  end

  @spec printed(binary() | :unknown) :: binary() | nil
  defp printed(:unknown), do: nil
  defp printed(text), do: text

  # ---------------------------------------------------------------------------
  # The printed expression
  # ---------------------------------------------------------------------------

  @spec render(SQLDmlExpr.ast(), SQLDmlOperand.ctx(), mode()) :: binary() | :unknown
  defp render({:num, text}, _ctx, _mode), do: number(text)
  defp render({:neg, {:num, text}}, _ctx, _mode), do: number("-" <> text)
  defp render({:bool, value}, _ctx, _mode), do: "Boolean(#{value})"
  defp render(:null, _ctx, _mode), do: "NULL"
  defp render({:param, "$" <> _number = text}, _ctx, _mode), do: text
  defp render({:pos, inner}, ctx, mode), do: render(inner, ctx, mode)
  defp render({:call, "now", []}, _ctx, _mode), do: "now()"
  # `CURRENT_TIMESTAMP` is the call `now()` named `current_timestamp()`, wherever it stands.
  defp render({:call, "current_timestamp", []}, _ctx, :name), do: "current_timestamp()"

  defp render({:call, "current_timestamp", []}, _ctx, :display),
    do: "now() AS current_timestamp()"

  defp render({:str, body}, _ctx, _mode) do
    if Regex.match?(~r/\A[A-Za-z0-9 _.,:;'!?@#$%^&*()+=\/<>-]*\z/, body),
      do: ~s|Utf8("#{body}")|,
      else: :unknown
  end

  defp render({:ref, parts}, ctx, _mode) do
    {column, _quoted} = List.last(parts)

    if SQLDmlOperand.column?(parts, ctx) and simple?(column) and simple?(ctx.relation_text),
      do: ctx.relation_text <> "." <> column,
      else: :unknown
  end

  defp render({:neg, inner}, ctx, mode), do: wrap("(- ", render(inner, ctx, mode), ")")
  defp render({:not, inner}, ctx, mode), do: wrap("NOT ", render(inner, ctx, mode))

  defp render({:is, inner, what, negated}, ctx, mode)
       when what in [:null, true, false, :unknown] do
    test = if(negated, do: " IS NOT ", else: " IS ") <> test_word(what)
    wrap("", render(inner, ctx, mode), test)
  end

  defp render({:in, inner, items, negated}, ctx, mode) do
    printed = Enum.map(items, &render(&1, ctx, mode))
    keyword = if negated, do: " NOT IN ([", else: " IN (["

    if :unknown in printed,
      do: :unknown,
      else: wrap("", render(inner, ctx, mode), keyword <> Enum.join(printed, ", ") <> "])")
  end

  defp render({:between, inner, low, high, negated}, ctx, mode) do
    keyword = if negated, do: " NOT BETWEEN ", else: " BETWEEN "

    case {render(inner, ctx, mode), render(low, ctx, mode), render(high, ctx, mode)} do
      {first, second, third} when :unknown in [first, second, third] ->
        :unknown

      {first, second, third} ->
        first <> keyword <> second <> " AND " <> third
    end
  end

  defp render({:like, inner, pattern, negated, word, nil}, ctx, mode) do
    keyword = if negated, do: " NOT " <> word <> " ", else: " " <> word <> " "

    case {render(inner, ctx, mode), render(pattern, ctx, mode)} do
      {first, second} when :unknown in [first, second] -> :unknown
      {first, second} -> first <> keyword <> second
    end
  end

  defp render({:bin, op, left, right}, ctx, mode) when is_map_key(@precedence, op) do
    with printed_left when is_binary(printed_left) <- child(left, op, ctx, mode),
         printed_right when is_binary(printed_right) <- child(right, op, ctx, mode) do
      printed_left <> " " <> Map.get(@printed, op, op) <> " " <> printed_right
    end
  end

  defp render({:call, name, args}, ctx, mode)
       when name in @printed_functions and is_list(args) and args != [] do
    printed = Enum.map(args, &render(&1, ctx, mode))

    if :unknown in printed, do: :unknown, else: name <> "(" <> Enum.join(printed, ", ") <> ")"
  end

  defp render({:cast, inner, _type, _try}, ctx, :name), do: render(inner, ctx, :name)

  defp render({:cast, inner, %{family: family, arrow: arrow}, try?}, ctx, :display)
       when family in [:int, :uint, :float, :bool, :str, :decimal] do
    wrap(if(try?, do: "TRY_CAST(", else: "CAST("), render(inner, ctx, :display), " AS #{arrow})")
  end

  defp render(_other, _ctx, _mode), do: :unknown

  @spec test_word(:null | true | false | :unknown) :: binary()
  defp test_word(:null), do: "NULL"
  defp test_word(true), do: "TRUE"
  defp test_word(false), do: "FALSE"
  defp test_word(:unknown), do: "UNKNOWN"

  # An operand of an operator, in parentheses where it is an operator of a lower precedence.
  @spec child(SQLDmlExpr.ast(), binary(), SQLDmlOperand.ctx(), mode()) :: binary() | :unknown
  defp child({:bin, op, _left, _right} = operand, parent, ctx, mode) do
    case render(operand, ctx, mode) do
      :unknown ->
        :unknown

      text ->
        if Map.get(@precedence, op, 0) < Map.fetch!(@precedence, parent),
          do: "(" <> text <> ")",
          else: text
    end
  end

  defp child(operand, _parent, ctx, mode), do: render(operand, ctx, mode)

  @spec wrap(binary(), binary() | :unknown, binary()) :: binary() | :unknown
  defp wrap(prefix, printed, suffix \\ "")
  defp wrap(_prefix, :unknown, _suffix), do: :unknown
  defp wrap(prefix, printed, suffix), do: prefix <> printed <> suffix

  @spec simple?(binary()) :: boolean()
  defp simple?(name), do: Regex.match?(~r/\A[a-z_][a-z0-9_.]*\z/, name)

  # A number as the planner prints its literal: `Int64(7)`, `UInt64(...)` above the largest
  # `Int64`, `Float64(1.5)` for any other (written to the digits Rust prints, with no exponent).
  @spec number(binary()) :: binary() | :unknown
  defp number(text) do
    cond do
      Regex.match?(~r/\A-?[0-9]+\z/, text) -> integer(String.to_integer(text), text)
      Regex.match?(~r/\A-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?\z/, text) -> float(text)
      true -> :unknown
    end
  end

  @spec integer(integer(), binary()) :: binary() | :unknown
  defp integer(value, _text)
       when value >= -9_223_372_036_854_775_808 and value <= 9_223_372_036_854_775_807,
       do: "Int64(#{value})"

  defp integer(value, _text) when value > 0 and value <= 18_446_744_073_709_551_615,
    do: "UInt64(#{value})"

  defp integer(_value, text), do: float(text)

  @spec float(binary()) :: binary() | :unknown
  defp float(text) do
    case Float.parse(text) do
      {value, ""} -> "Float64(" <> plain(value) <> ")"
      _unreadable -> :unknown
    end
  end

  # A float as Rust's `Display` writes it: the shortest digits that read back, never an exponent.
  @spec plain(float()) :: binary()
  defp plain(value) do
    [_all, sign, whole, fraction, exponent] =
      Regex.run(~r/\A(-?)([0-9]+)(?:\.([0-9]+))?(?:e([+-]?[0-9]+))?\z/, Float.to_string(value))
      |> pad_match()

    digits = whole <> fraction
    point = String.length(whole) + String.to_integer(exponent)
    sign <> place(digits, point)
  end

  @spec pad_match([binary()]) :: [binary()]
  defp pad_match([all, sign, whole, fraction]), do: [all, sign, whole, fraction, "0"]

  defp pad_match([all, sign, whole, fraction, exponent]),
    do: [all, sign, whole, fraction, exponent]

  @spec place(binary(), integer()) :: binary()
  defp place(digits, point) do
    {integer_part, fraction_part} =
      cond do
        point <= 0 ->
          {"0", String.duplicate("0", -point) <> digits}

        point >= String.length(digits) ->
          {digits <> String.duplicate("0", point - String.length(digits)), ""}

        true ->
          String.split_at(digits, point)
      end

    integer_part =
      integer_part |> String.trim_leading("0") |> then(&if(&1 == "", do: "0", else: &1))

    fraction_part = String.trim_trailing(fraction_part, "0")
    if fraction_part == "", do: integer_part, else: integer_part <> "." <> fraction_part
  end

  # ---------------------------------------------------------------------------
  # The shape of an expression the double does not print
  # ---------------------------------------------------------------------------

  # The expression with what does not change its name taken out: how a name is spelled (case,
  # quotes, the qualifier of a column, the spelling of a number), a cast and a unary plus.
  @spec shape(term()) :: term()
  defp shape({:ref, parts}), do: {:ref, parts |> List.last() |> elem(0)}
  defp shape({:cast, inner, _type, _try}), do: shape(inner)
  defp shape({:pos, inner}), do: shape(inner)

  defp shape({:num, text}) do
    case number(text) do
      :unknown -> {:num, text}
      named -> {:num, named}
    end
  end

  defp shape({:ordered, call, terms}), do: {:ordered, shape(call), Enum.map(terms, &shape/1)}

  defp shape(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> shape() |> List.to_tuple()

  defp shape(list) when is_list(list), do: Enum.map(list, &shape/1)
  defp shape(other), do: other
end
