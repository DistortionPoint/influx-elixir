defmodule InfluxElixir.Client.Local.SQLDmlOperand do
  @moduledoc false
  # The planner's reading of the operands of an `UPDATE` (the values it assigns and its `WHERE`),
  # for `InfluxElixir.Client.Local.SQLDml` (verified against InfluxDB 3 Core).
  #
  # The planner reads an operand in two passes. The first (`names/2`) turns the SQL into an
  # expression, meeting its names and calls in order and finding fault with
  #
  #   * a name that is no field of the relation (a name before a `.` must be the relation: the
  #     alias when there is one, else the table, whose schema and catalog must agree as far as
  #     both are written), and a function it has not
  #   * a unary `+` of anything but a number, an interval or a timestamp, and a `||` whose
  #     operands have no type (both need the types of their operands at that point)
  #
  # The second types the value assigned to a column to convert it to the column's type. A
  # value's type is found through an arithmetic or comparison operator, a negation, a cast, a
  # `CASE` result and the arguments of a function, which fail by the words of a select item of
  # the same operand (`plan/2` plans it as one). It is not found through `IS [NOT] NULL`,
  # `IS [NOT] TRUE/FALSE/UNKNOWN`, which are booleans whatever they test; and what stands in a
  # `NOT`, `BETWEEN`, `IN` or `LIKE` is reached only where it is a call, whose arguments are
  # typed whole. A `WHERE` is not typed at all but for its names, the checks above and a
  # predicate that is not a boolean.
  #
  # Nothing that only a later pass finds is an error here: a negation of text, a `LIKE` of a
  # number, a constant the optimizer cannot fold.

  alias InfluxElixir.Client.Local.{SQLDmlExpr, SQLDmlName, SQLDmlType, SQLError, SQLFunctions}

  @typedoc "What the operands of a statement are read against."
  @type ctx :: %{
          table: binary() | nil,
          columns: [binary()],
          types: %{binary() => binary()},
          relation: [binary()],
          relation_text: binary(),
          planner: (binary() | nil, binary() -> :ok | {:error, term()})
        }

  @typedoc "`:ok`, the engine's error, or a refusal by name of what the double does not model."
  @type check :: :ok | {:error, SQLError.t() | map()} | {:refuse, binary()}

  @typedoc "The type of an operand as far as the checks tell."
  @type type ::
          :bool
          | :time
          | :duration
          | :null
          | :int
          | :uint
          | :float
          | :num
          | :decimal
          | :date
          | :clock
          | :interval
          | :binary
          | :list
          | :str
          | :unknown

  # What stands for a timestamp and for a boolean where the double plans a node it has no
  # planner for: of the same type to the planner.
  @time_dummy {:ref, [{"time", true}]}
  @bool_dummy {:bool, true}

  @comparisons ~w(= == <> != < > <= >= <=> ~ ~* !~ !~* ~~ ~~* !~~ !~~* AND OR)
  @arithmetic ~w(+ - * / %)
  @numeric [:int, :uint, :float, :num, :decimal]
  # Functions whose result is a boolean.
  @boolean_functions ~w(starts_with ends_with contains regexp_like)
  # Functions of one number that give a float, of text that give text, and the aggregates.
  @float_functions ~w(round trunc floor ceil sqrt ln log pow power)
  @text_functions ~w(lower upper substr left right concat)
  @same_type_functions ~w(coalesce nullif greatest least min max first_value last_value)
  # The functions the engine has that the double reads (its own, `SQLFunctions`, besides these).
  @known_functions ~w(count sum avg median stddev stddev_pop var var_pop approx_distinct
                      approx_median now date_trunc date_bin locf interpolate length)

  # The double's refusals of what the engine finds only when it runs the plan.
  @runtime_only [
    "a comparison of time with text or another time",
    "a timestamp concatenated as text",
    "IS DISTINCT FROM of a time and text",
    "IS NOT DISTINCT FROM of a time and text",
    "the engine writes its nanoseconds"
  ]

  # ---------------------------------------------------------------------------
  # The names of an operand
  # ---------------------------------------------------------------------------

  @doc """
  What the planner finds wrong as it reads an operand, in the order it meets it: a function it
  has not, a name of five parts, a field of a column, and the checkpoints (see the module) that
  fail. A name that is no field of the relation is not found here but later (`lazy/2`), unless
  a checkpoint needs the type of an operand that holds it.
  """
  @spec eager(SQLDmlExpr.ast() | [SQLDmlExpr.ast()], ctx()) :: check()
  def eager(list, ctx) when is_list(list) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case eager(item, ctx) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  def eager({:ref, parts}, ctx), do: compound(parts, ctx)

  def eager({:zero_param, text}, _ctx),
    do: {:error, SQLError.planning("Invalid placeholder, zero is not a valid index: " <> text)}

  def eager({:call, name, args}, ctx) do
    cond do
      not known_function?(name) -> {:refuse, "a function the double does not know"}
      converted_alone?(name, args) -> {:refuse, "a call the planner converts on its own"}
      args == :star -> :ok
      true -> eager(args, ctx)
    end
  end

  def eager({:pos, inner}, ctx) do
    with :ok <- eager(inner, ctx),
         :ok <- plan_top(inner, ctx),
         do: plus(inner, ctx)
  end

  # A `||` needs the types of its operands as it reads it (to rewrite it as a call or not).
  def eager({:bin, "||", left, right}, ctx) do
    with :ok <- eager([left, right], ctx),
         :ok <- plan_top(left, ctx),
         do: plan_top(right, ctx)
  end

  # The planner reads the pattern of a `LIKE`, then checks its escape, then reads the operand.
  def eager({:like, inner, pattern, _negated, _word, escape}, ctx) do
    with :ok <- eager(pattern, ctx),
         :ok <- escape_length(escape),
         do: eager(inner, ctx)
  end

  # A cast to a type the planner cannot plan fails when the planner reaches it, after what
  # it casts.
  def eager({:cast, inner, type, _try}, ctx) do
    with :ok <- eager(inner, ctx) do
      case type do
        {:unsupported, printed} -> {:error, SQLDmlType.unsupported(printed)}
        _planned -> :ok
      end
    end
  end

  def eager(node, ctx) do
    case SQLDmlExpr.children(node) do
      [] -> :ok
      children -> eager(children, ctx)
    end
  end

  # Calls the engine converts before it reads their arguments: `substr(x)` and `substring(x)`
  # are a `SUBSTRING` with neither `FROM` nor `FOR` (an error that prints the parse tree),
  # `floor` and `ceil` with a second argument a scale.
  @spec converted_alone?(binary(), [SQLDmlExpr.ast()] | :star) :: boolean()
  defp converted_alone?(name, [_one]) when name in ["substr", "substring"], do: true
  defp converted_alone?(name, [_a, _b]) when name in ["floor", "ceil"], do: true
  defp converted_alone?(_name, _args), do: false

  # The planner types the operand of a unary plus as it reads it.
  @spec escape_length(binary() | nil) :: check()
  defp escape_length(nil), do: :ok

  defp escape_length(escape) do
    if String.length(escape) == 1,
      do: :ok,
      else:
        {:error,
         SQLError.planning(
           "Invalid escape character in LIKE expression. Expected a single character wrapped " <>
             "with single quotes, got '#{escape}'"
         )}
  end

  @doc """
  The first name of an operand, in the order of the expression, that is no field of the relation:
  the planner resolves the names of an expression last.
  """
  @spec lazy(SQLDmlExpr.ast() | [SQLDmlExpr.ast()], ctx()) :: check()
  def lazy(list, ctx) when is_list(list) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case lazy(item, ctx) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  def lazy({:ref, parts}, ctx) do
    case resolve(parts, ctx) do
      {:field_of, _type} -> :ok
      other -> other
    end
  end

  def lazy(node, ctx), do: lazy(SQLDmlExpr.children(node), ctx)

  # The names the planner reaches by typing an operand: those of the whole of it but what a test
  # of a value (`IS NULL`, `IS TRUE`) holds.
  @spec reachable(SQLDmlExpr.ast() | [SQLDmlExpr.ast()], ctx()) :: check()
  defp reachable(list, ctx) when is_list(list) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case reachable(item, ctx) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp reachable({:ref, parts}, ctx), do: typed_name(parts, ctx)
  defp reachable({:is, _inner, what, _negated}, _ctx) when not is_tuple(what), do: :ok
  defp reachable({:cast, _inner, _type, _try}, _ctx), do: :ok
  defp reachable({:not, _inner}, _ctx), do: :ok
  defp reachable({:in, _inner, _items, _negated}, _ctx), do: :ok
  defp reachable({:between, _inner, _low, _high, _negated}, _ctx), do: :ok
  defp reachable({:like, _inner, _pattern, _negated, _word, _escape}, _ctx), do: :ok
  defp reachable(node, ctx), do: reachable(SQLDmlExpr.children(node), ctx)

  @spec known_function?(binary()) :: boolean()
  defp known_function?(name) do
    name in @known_functions or name in @float_functions or name in @text_functions or
      name in @same_type_functions or name in @boolean_functions or name == "abs" or
      SQLFunctions.lookup(name) != nil
  end

  @spec plus(SQLDmlExpr.ast(), ctx()) :: check()
  defp plus(inner, ctx) do
    case type_of(inner, ctx) do
      type when type in [:null, :str, :bool] ->
        {:error,
         SQLError.planning(
           "Unary operator '+' only supports numeric, interval and timestamp types"
         )}

      :unknown ->
        {:refuse, "a unary plus of an operand whose type is not known"}

      _numeric_or_time ->
        :ok
    end
  end

  # What the planner finds of a name as it reads it: one of five parts is the engine's 405, one
  # of more the engine's panic (a name that starts with a column is that column's field, whose
  # type is found later).
  @spec compound([SQLDmlExpr.name()], ctx()) :: check()
  defp compound(parts, ctx) do
    cond do
      length(parts) < 5 or elem(hd(parts), 0) in ctx.columns ->
        :ok

      length(parts) == 5 ->
        {:error,
         %{
           status: 405,
           body:
             "This feature is not implemented: compound identifier: " <>
               inspect(Enum.map(parts, &elem(&1, 0)))
         }}

      true ->
        {:error,
         %{
           status: 500,
           body:
             "Join Error\ncaused by\nExternal error: Panic: called `Result::unwrap()` on an " <>
               "`Err` value: Internal(\"Incorrect number of identifiers: #{length(parts)}\")"
         }}
    end
  end

  # A name written with up to three qualifiers: of the qualifiers, the last is the relation's
  # name, the one before its schema, and the one before that its catalog; those written must
  # agree with the relation's, as far as both are written. One that is not a field of the
  # relation but starts with a column is a field of that column (`{:field_of, type}`).
  @spec resolve([SQLDmlExpr.name()], ctx()) :: check() | {:field_of, binary() | nil}
  # A name of five parts or more reaches here only when it starts with a column (`compound/2`
  # has refused the others).
  defp resolve(parts, ctx) when length(parts) >= 5,
    do: {:field_of, ctx.types[elem(hd(parts), 0)]}

  defp resolve(parts, ctx) do
    {qualifiers, [{column, quoted}]} = Enum.split(parts, -1)
    first = elem(hd(parts), 0)

    cond do
      qualifiers != [] and qualified?(qualifiers, ctx.relation) and column in ctx.columns ->
        :ok

      qualifiers != [] and first in ctx.columns ->
        {:field_of, ctx.types[first]}

      qualifiers != [] ->
        {:error, missing(parts, ctx)}

      column in ctx.columns ->
        :ok

      # The relation's own name alone is read as a column to take a field of.
      not quoted and ctx.relation == [ctx.table] and column == ctx.table ->
        {:refuse, "a name that is the table's own"}

      true ->
        {:error, missing(parts, ctx)}
    end
  end

  # The same, for a name whose type the planner finds: a field of a column is an error then.
  @spec typed_name([SQLDmlExpr.name()], ctx()) :: check()
  defp typed_name(parts, ctx) do
    case resolve(parts, ctx) do
      {:field_of, type} ->
        {:error,
         %{
           status: 500,
           body:
             "Execution error: The expression to get an indexed field is only valid for " <>
               "`Struct`, `Map` or `Null` types, got #{type}"
         }}

      other ->
        other
    end
  end

  @spec qualified?([SQLDmlExpr.name()], [binary()]) :: boolean()
  defp qualified?(qualifiers, relation) do
    qualifiers
    |> Enum.map(&elem(&1, 0))
    |> Enum.reverse()
    |> Enum.zip(Enum.reverse(relation))
    |> Enum.all?(fn {written, own} -> written == own end)
  end

  @spec missing([SQLDmlExpr.name()], ctx()) :: map()
  defp missing(parts, ctx) do
    {name, _quoted} = List.last(parts)
    printed = Enum.map_join(parts, ".", &SQLDmlName.quote_name/1)
    SQLDmlName.no_field(printed, name, ctx.relation_text, ctx.columns)
  end

  # ---------------------------------------------------------------------------
  # The WHERE
  # ---------------------------------------------------------------------------

  @doc """
  The type check of a `WHERE` operand that has passed `names/2`: a predicate that is not a boolean
  is an error, printed as the planner prints it, where the double can print it.
  """
  @spec predicate(SQLDmlExpr.ast(), ctx()) :: check()
  def predicate(operand, ctx) do
    if exotic_in_cast?(operand) and param?(operand),
      do: {:refuse, "a placeholder beside a cast to a type the double has no planner for"},
      else: predicate_type(operand, ctx)
  end

  @spec predicate_type(SQLDmlExpr.ast(), ctx()) :: check()
  defp predicate_type({:bin, op, _left, _right}, _ctx) when op in @comparisons, do: :ok
  defp predicate_type({:not, _inner}, _ctx), do: :ok
  defp predicate_type({:is, _inner, _what, _negated}, _ctx), do: :ok
  defp predicate_type({:in, _inner, _items, _negated}, _ctx), do: :ok
  defp predicate_type({:between, _inner, _low, _high, _negated}, _ctx), do: :ok
  defp predicate_type({:like, _inner, _pattern, _negated, _word, _escape}, _ctx), do: :ok
  defp predicate_type({:bool, _value}, _ctx), do: :ok
  defp predicate_type(:null, _ctx), do: :ok
  defp predicate_type(:param, _ctx), do: :ok
  defp predicate_type({:call, name, _args}, _ctx) when name in @boolean_functions, do: :ok

  defp predicate_type({:ref, parts}, ctx) do
    {column, _quoted} = List.last(parts)

    case resolve(parts, ctx) do
      {:field_of, _type} ->
        {:refuse, "a WHERE that is a field of a column"}

      _field ->
        case ctx.types[column] do
          "Boolean" ->
            :ok

          type ->
            non_boolean("#{ctx.relation_text}.#{SQLDmlName.quote_ident(column)}", type)
        end
    end
  end

  defp predicate_type({:num, text}, _ctx), do: literal_predicate(text)
  defp predicate_type({:neg, {:num, text}}, _ctx), do: literal_predicate("-" <> text)
  defp predicate_type({:pos, {:num, text}}, _ctx), do: literal_predicate(text)

  # A sign in front of a boolean is the boolean's type, which is all the planner checks.
  defp predicate_type({sign, inner}, ctx) when sign in [:neg, :pos] do
    if type_of(inner, ctx) == :bool,
      do: :ok,
      else: {:refuse, "a WHERE that is not a comparison, a boolean or a name"}
  end

  defp predicate_type({:str, body}, _ctx) do
    if Regex.match?(~r/\A[A-Za-z0-9 _.-]*\z/, body),
      do: non_boolean(~s|Utf8("#{body}")|, "Utf8"),
      else: {:refuse, "a predicate that is a string with a character the double does not print"}
  end

  # A value the planner cannot type is let by, and one it can is no boolean: the double knows
  # the first by the select item's errors of the same operand.
  defp predicate_type({:bin, _op, _left, _right} = operand, ctx), do: untyped(operand, ctx)
  defp predicate_type({:call, _name, _args} = call, ctx), do: untyped(call, ctx)

  defp predicate_type(_other, _ctx),
    do: {:refuse, "a WHERE that is not a comparison, a boolean or a name"}

  @spec untyped(SQLDmlExpr.ast(), ctx()) :: check()
  defp untyped(operand, ctx) do
    case plan_top(operand, ctx) do
      :ok -> {:refuse, "a WHERE that is a value that is not a boolean"}
      {:error, %{body: "Client.Local: " <> why}} -> {:refuse, why}
      {:error, _typed_wrong} -> :ok
      {:refuse, _why} = refusal -> refusal
    end
  end

  @spec literal_predicate(binary()) :: check()
  defp literal_predicate(text) do
    cond do
      Regex.match?(~r/\A-?[0-9]{1,18}\z/, text) ->
        non_boolean("Int64(#{String.to_integer(text)})", "Int64")

      match?({value, ""} when abs(value) < 1.0e15, Float.parse(text)) and
          Regex.match?(~r/\A-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?\z/, text) ->
        {value, ""} = Float.parse(text)
        non_boolean("Float64(#{float_text(value)})", "Float64")

      true ->
        {:refuse, "a predicate that is a number the double does not print"}
    end
  end

  # A float as the engine prints it: no fraction when it has none, else the shortest digits.
  @spec float_text(float()) :: binary()
  defp float_text(value) do
    if value == Float.round(value) and abs(value) < 1.0e15,
      do: Integer.to_string(trunc(value)),
      else: Float.to_string(value)
  end

  @spec non_boolean(binary(), binary() | nil) :: check()
  defp non_boolean(printed, type) do
    {:error,
     SQLError.planning(
       "Cannot create filter with non-boolean predicate '#{printed}' returning #{type}"
     )}
  end

  # ---------------------------------------------------------------------------
  # The value assigned to a column
  # ---------------------------------------------------------------------------

  @doc """
  The type check of a value assigned to `column`, after `names/2`: its type as a select item of
  the same operand, then its conversion to the column's type.
  """
  @spec value(SQLDmlExpr.ast(), binary(), ctx()) :: check()
  def value(operand, column, ctx) do
    with :ok <- plan_top(operand, ctx),
         do: convertible(operand, ctx.types[column], ctx, :planning)
  end

  @doc """
  What the planner finds in the parts of a value that typing its top does not reach (what a cast,
  a `NOT`, a `BETWEEN`, an `IN` or a `LIKE` holds), when it builds the projection of the
  update: after every value was typed.
  """
  @spec deep(SQLDmlExpr.ast(), ctx()) :: check()
  def deep(operand, ctx) do
    {_lowered, deferred} = lower(operand, ctx)

    Enum.reduce_while(deferred, :ok, fn part, :ok ->
      with :ok <- plan_top(part, ctx), :ok <- deep(part, ctx) do
        {:cont, :ok}
      else
        failure -> {:halt, failure}
      end
    end)
  end

  @doc """
  The conversion of an operand to the Arrow type `target` of a column. `mode` is `:planning`
  for the projection of an `UPDATE` or of an `INSERT ... SELECT` (`Cannot automatically
  convert`) and `:values` for the cells of an `INSERT ... VALUES` (the engine's
  `type mismatch and can't cast`).
  """
  @spec convert(SQLDmlExpr.ast(), binary() | nil, ctx(), :planning | :values) :: check()
  def convert(operand, target, ctx, mode), do: convertible(operand, target, ctx, mode)

  # A value is converted to its column's type, which fails for a few pairs only (verified
  # for the source types a `CAST` can make): a boolean and a timestamp (or a duration, the
  # difference of two timestamps) into each other, and the date, time, interval, binary and
  # list types into the numbers, booleans and timestamps their kernels do not cast.
  @spec convertible(SQLDmlExpr.ast(), binary() | nil, ctx(), :planning | :values) :: check()
  defp convertible(operand, target, ctx, mode) do
    case {unconvertible(operand, target, ctx), type_of(operand, ctx)} do
      {{:no, from}, _type} ->
        conversion(mode, from, target)

      {:known, _type} ->
        :ok

      {:ok, type} when target in ["Boolean", "Timestamp(ns)"] and type in [:unknown, :decimal] ->
        {:refuse, "a value whose type is not known where a boolean or a timestamp is assigned"}

      _convertible ->
        :ok
    end
  end

  @spec unconvertible(SQLDmlExpr.ast(), binary() | nil, ctx()) ::
          :ok | :known | {:no, binary()}
  defp unconvertible({:cast, _inner, %{family: family, arrow: arrow}, _try}, target, _ctx)
       when family in ~w(date clock interval binary list)a do
    if target in non_castable(family, arrow), do: {:no, arrow}, else: :ok
  end

  # A cast to a decimal is known by its precision: it cannot be cast to a boolean.
  defp unconvertible({:cast, _inner, %{family: :decimal, arrow: arrow}, _try}, target, _ctx),
    do: if(target == "Boolean", do: {:no, arrow}, else: :known)

  defp unconvertible(operand, target, ctx) do
    case {target, type_of(operand, ctx)} do
      {"Boolean", :time} -> {:no, "Timestamp(ns)"}
      {"Boolean", :duration} -> {:no, "Duration(ns)"}
      {"Timestamp(ns)", :bool} -> {:no, "Boolean"}
      {"Timestamp(ns)", :duration} -> {:no, "Duration(ns)"}
      _convertible -> :ok
    end
  end

  # The column types a value of each such family cannot be cast to.
  @spec non_castable(atom(), binary()) :: [binary()]
  defp non_castable(:date, _arrow), do: ["UInt64", "Float64", "Boolean"]
  defp non_castable(:clock, _arrow), do: ["UInt64", "Float64", "Boolean", "Timestamp(ns)"]

  # A fixed-size list is not cast to text either.
  defp non_castable(:list, "FixedSizeList" <> _rest),
    do: [
      "UInt64",
      "Int64",
      "Float64",
      "Boolean",
      "Timestamp(ns)",
      "Utf8",
      "Dictionary(Int32, Utf8)"
    ]

  defp non_castable(family, _arrow) when family in [:interval, :binary, :list],
    do: ["UInt64", "Int64", "Float64", "Boolean", "Timestamp(ns)"]

  @spec conversion(:planning | :values, binary(), binary() | nil) :: {:error, map()}
  defp conversion(:planning, from, to),
    do: {:error, SQLError.planning("Cannot automatically convert #{from} to #{to}")}

  defp conversion(:values, from, to),
    do:
      {:error,
       %{
         status: 500,
         body: "Execution error: type mismatch and can't cast to got #{from} and #{to}"
       }}

  # ---------------------------------------------------------------------------
  # Typing an operand as a select item
  # ---------------------------------------------------------------------------

  @doc """
  The types of an operand through its top, as the planner finds them in a select item of the
  same operand: through arithmetic and comparison operators, negations, the arguments of
  functions, not through what `deep/2` reaches.
  """
  @spec plan_top(SQLDmlExpr.ast(), ctx()) :: check()
  def plan_top({:num, _text}, _ctx), do: :ok
  def plan_top({:str, _body}, _ctx), do: :ok
  def plan_top({:bool, _value}, _ctx), do: :ok
  def plan_top(:null, _ctx), do: :ok
  def plan_top(:param, _ctx), do: :ok
  def plan_top({:ref, parts}, ctx), do: typed_name(parts, ctx)

  def plan_top(operand, ctx) do
    if exotic_nested?(operand, true),
      do: {:refuse, "an operator or a call over a cast to a type the double has no planner for"},
      else: plan_typed(operand, ctx)
  end

  @spec plan_typed(SQLDmlExpr.ast(), ctx()) :: check()
  defp plan_typed(operand, ctx) do
    if type_of(operand, ctx) == :duration do
      # The difference of two timestamps is a duration, which no select item here can be.
      {:bin, _op, left, right} = operand
      with :ok <- plan_top(left, ctx), do: plan_top(right, ctx)
    else
      {lowered, _deferred} = lower(operand, ctx)

      with :ok <- reachable(operand, ctx),
           do: inferred_text(operand, lowered, ctx)
    end
  end

  # The engine words the error of an operand a placeholder takes its type from by that operand's
  # printed expression, which the double does not print.
  @spec inferred_text(SQLDmlExpr.ast(), SQLDmlExpr.ast(), ctx()) :: check()
  defp inferred_text(operand, lowered, ctx) do
    case plan_text(lowered, ctx) do
      {:error, %{body: "Client.Local: " <> _reason}} = refusal ->
        refusal

      {:error, %{}} = error ->
        if Enum.any?(inferred_from(operand), &(plan_top(&1, ctx) != :ok)),
          do: {:refuse, "an operand a placeholder takes its type from that fails to type"},
          else: error

      other ->
        other
    end
  end

  # The operands a placeholder beside them takes its type from.
  @spec inferred_from(SQLDmlExpr.ast()) :: [SQLDmlExpr.ast()]
  defp inferred_from({:bin, _op, :param, other}) when other != :param, do: [other]
  defp inferred_from({:bin, _op, other, :param}) when other != :param, do: [other]

  defp inferred_from({:is, :param, {:distinct, other}, _negated}) when other != :param,
    do: [other]

  defp inferred_from({:is, other, {:distinct, :param}, _negated}) when other != :param,
    do: [other]

  defp inferred_from(node), do: node |> SQLDmlExpr.children() |> Enum.flat_map(&inferred_from/1)

  @spec plan_text(SQLDmlExpr.ast(), ctx()) :: check()
  defp plan_text(lowered, ctx) do
    text = SQLDmlExpr.unparse(lowered, &field_text/1)

    case ctx.planner.(ctx.table, text) do
      :ok ->
        :ok

      # The optimizer's errors are found when the plan is optimized, which a DML statement
      # never is (it is refused first): `UPDATE t SET f = coalesce('a', 1)` is the refusal.
      {:error, %{body: "Optimizer rule " <> _rest}} ->
        :ok

      # A negation is checked late, after the planning an update stops at.
      {:error, %{body: "Error during planning: Negation only supports" <> _rest}} ->
        :ok

      # What the double cannot word because the engine reads a value (a timestamp against text,
      # a timestamp joined as text) is the engine's error only when it runs a plan.
      {:error, %{body: "Client.Local: " <> reason}} = refusal ->
        if Enum.any?(@runtime_only, &String.contains?(reason, &1)), do: :ok, else: refusal

      {:error, _reason} = error ->
        error

      {:refuse, _why} = refusal ->
        refusal
    end
  end

  @spec field_text([SQLDmlExpr.name()]) :: binary()
  defp field_text(parts), do: parts |> List.last() |> elem(0) |> SQLDmlName.quote_always()

  # The operand with each node the planner does not type through replaced by a stand-in of its
  # type, and the operands it holds that are typed anyway, to be planned on their own first.
  @spec lower(SQLDmlExpr.ast(), ctx()) :: {SQLDmlExpr.ast(), [SQLDmlExpr.ast()]}
  defp lower({:call, "now", []}, _ctx), do: {@time_dummy, []}

  # A test of a value is a boolean whatever the value is.
  defp lower({:is, _inner, what, _negated}, _ctx) when not is_tuple(what),
    do: {@bool_dummy, []}

  defp lower({:is, inner, {:distinct, other}, negated}, ctx) do
    {[inner, other], operands} = lower_all(inferred([inner, other]), ctx)
    {{:is, inner, {:distinct, other}, negated}, operands}
  end

  defp lower({kind, _a} = node, _ctx) when kind == :not, do: {@bool_dummy, calls(node)}
  defp lower({:in, _a, _b, _c} = node, _ctx), do: {@bool_dummy, calls(node)}
  defp lower({:between, _a, _b, _c, _d} = node, _ctx), do: {@bool_dummy, calls(node)}
  defp lower({:like, _a, _b, _c, _d, _e} = node, _ctx), do: {@bool_dummy, calls(node)}

  # The planner types a cast as its type, and what it casts only when it builds the projection.
  defp lower({:cast, inner, type, try?}, _ctx), do: {cast_stand_in(type, try?), [inner]}

  defp lower({:call, name, args}, ctx) when is_list(args) do
    kinds = args |> Enum.map(&type_of(&1, ctx)) |> Enum.uniq()

    if name in ~w(coalesce nullif greatest least) and kinds in [[:time], [:bool]] do
      {if(kinds == [:time], do: @time_dummy, else: @bool_dummy), args}
    else
      {lowered, operands} = lower_all(args, ctx)
      {{:call, name, lowered}, operands}
    end
  end

  defp lower({sign, inner}, ctx) when sign in [:neg, :pos] do
    {lowered, operands} = lower(inner, ctx)
    {{sign, lowered}, operands}
  end

  defp lower({:bin, op, left, right}, ctx) do
    {[left, right], operands} = lower_all(inferred([left, right]), ctx)
    {{:bin, op, left, right}, operands}
  end

  defp lower(leaf, _ctx), do: {leaf, []}

  # A placeholder beside an operand has that operand's type.
  @spec inferred([SQLDmlExpr.ast()]) :: [SQLDmlExpr.ast()]
  defp inferred([:param, other]) when other != :param, do: [other, other]
  defp inferred([other, :param]) when other != :param, do: [other, other]
  defp inferred(pair), do: pair

  @spec lower_all([SQLDmlExpr.ast()], ctx()) :: {[SQLDmlExpr.ast()], [SQLDmlExpr.ast()]}
  defp lower_all(parts, ctx) do
    {lowered, operands} = parts |> Enum.map(&lower(&1, ctx)) |> Enum.unzip()
    {lowered, Enum.concat(operands)}
  end

  # What the planner types a cast as: a node of that type. The casts to a type the double has
  # no planner for stand as a number of the family (those that sit in an operator are refused
  # before, see `exotic_nested?/2`).
  @spec cast_stand_in(SQLDmlType.t(), boolean()) :: SQLDmlExpr.ast()
  defp cast_stand_in(%{family: :bool}, _try?), do: @bool_dummy
  defp cast_stand_in(%{family: :timestamp}, _try?), do: @time_dummy
  defp cast_stand_in(%{family: :float, arrow: "Float64"}, _try?), do: {:num, "0.5"}
  defp cast_stand_in(%{family: :int, bits: 64}, _try?), do: {:num, "0"}
  defp cast_stand_in(%{family: :uint}, _try?), do: {:num, "9223372036854775808"}

  defp cast_stand_in(%{sql: sql} = type, try?) when is_binary(sql),
    do: {:cast, {:num, "0"}, type, try?}

  defp cast_stand_in(_type, _try?), do: {:num, "0"}

  # Types the double has no planner for: an operator or a call over a cast to one of them
  # is not planned.
  @spec exotic?(SQLDmlType.t()) :: boolean()
  defp exotic?(%{family: family}) when family in ~w(date clock interval binary list decimal)a,
    do: true

  defp exotic?(%{arrow: "Float32"}), do: true
  defp exotic?(_type), do: false

  # A cast to such a type anywhere in an operand, and a placeholder anywhere in it (a
  # placeholder takes its type from what stands beside it, which fails for such a cast).
  @spec exotic_in_cast?(SQLDmlExpr.ast()) :: boolean()
  defp exotic_in_cast?({:cast, inner, type, _try}),
    do: exotic?(type) or exotic_in_cast?(inner)

  defp exotic_in_cast?(node), do: node |> SQLDmlExpr.children() |> Enum.any?(&exotic_in_cast?/1)

  @spec param?(SQLDmlExpr.ast()) :: boolean()
  defp param?(:param), do: true
  defp param?(node), do: node |> SQLDmlExpr.children() |> Enum.any?(&param?/1)
  # Whether a cast to such a type sits where the planner types it through an operator.
  @spec exotic_nested?(SQLDmlExpr.ast(), boolean()) :: boolean()
  defp exotic_nested?({:cast, _inner, type, _try}, root?), do: not root? and exotic?(type)
  defp exotic_nested?({:not, _inner}, _root?), do: false
  defp exotic_nested?({:in, _a, _b, _c}, _root?), do: false
  defp exotic_nested?({:between, _a, _b, _c, _d}, _root?), do: false
  defp exotic_nested?({:like, _a, _b, _c, _d, _e}, _root?), do: false
  defp exotic_nested?({:is, _a, what, _c}, _root?) when not is_tuple(what), do: false

  defp exotic_nested?(node, _root?),
    do: node |> SQLDmlExpr.children() |> Enum.any?(&exotic_nested?(&1, false))

  # The calls in an operand that the planner types, outermost first: it reaches a call through
  # anything but a test of a value (`IS ...`).
  @spec calls(SQLDmlExpr.ast()) :: [SQLDmlExpr.ast()]
  defp calls({:call, "now", []}), do: []
  defp calls({:call, _name, _args} = call), do: [call]
  defp calls({:is, _inner, _what, _negated}), do: []

  # The planner types the operand of an `IN`, a `BETWEEN` and a `LIKE`, not the list, the bounds
  # and the pattern (verified: `b = n IN (abs(s))` is the update's own error).
  defp calls({:in, inner, _items, _negated}), do: calls(inner)
  defp calls({:between, inner, _low, _high, _negated}), do: calls(inner)
  defp calls({:like, inner, _pattern, _negated, _word, _escape}), do: calls(inner)
  defp calls(node), do: node |> SQLDmlExpr.children() |> Enum.flat_map(&calls/1)

  # ---------------------------------------------------------------------------
  # The type of an operand
  # ---------------------------------------------------------------------------

  @doc "The type of an operand, as far as the checks tell (`:unknown` when not)."
  @spec type_of(SQLDmlExpr.ast(), ctx()) :: type()
  def type_of({:num, text}, _ctx),
    do: if(Regex.match?(~r/[.eE]/, text), do: :float, else: :int)

  def type_of({:str, _body}, _ctx), do: :str
  def type_of({:bool, _value}, _ctx), do: :bool
  def type_of(:null, _ctx), do: :null
  def type_of(:param, _ctx), do: :null
  def type_of({:ref, parts}, ctx), do: column_type(ctx.types[parts |> List.last() |> elem(0)])
  def type_of({:bin, op, _left, _right}, _ctx) when op in @comparisons, do: :bool
  def type_of({kind, _inner}, _ctx) when kind == :not, do: :bool
  def type_of({:is, _a, _b, _c}, _ctx), do: :bool
  def type_of({:in, _a, _b, _c}, _ctx), do: :bool
  def type_of({:between, _a, _b, _c, _d}, _ctx), do: :bool
  def type_of({:like, _a, _b, _c, _d, _e}, _ctx), do: :bool
  def type_of({sign, inner}, ctx) when sign in [:neg, :pos], do: type_of(inner, ctx)
  def type_of({:bin, "||", _left, _right}, _ctx), do: :str

  def type_of({:bin, op, left, right}, ctx) when op in @arithmetic do
    case {type_of(left, ctx), type_of(right, ctx)} do
      {:time, :time} when op == "-" -> :duration
      {left_type, right_type} -> arithmetic(left_type, right_type)
    end
  end

  def type_of({:cast, _inner, type, _try}, _ctx), do: cast_type(type)
  def type_of({:call, name, args}, ctx), do: call_type(name, args, ctx)
  def type_of(_other, _ctx), do: :unknown

  @spec arithmetic(type(), type()) :: type()
  defp arithmetic(:null, :null), do: :int
  defp arithmetic(:null, other) when other in @numeric, do: other
  defp arithmetic(other, :null) when other in @numeric, do: other

  defp arithmetic(left, right)
       when left in [:int, :uint] and right in [:int, :uint] and left != right,
       do: :decimal

  defp arithmetic(left, right) when left in @numeric and right in @numeric, do: :num
  defp arithmetic(_left, _right), do: :unknown

  @spec call_type(binary(), [SQLDmlExpr.ast()] | :star, ctx()) :: type()
  defp call_type("now", _args, _ctx), do: :time
  defp call_type("abs", [arg], ctx), do: type_of(arg, ctx)
  defp call_type("length", _args, _ctx), do: :int
  defp call_type("count", _args, _ctx), do: :int
  defp call_type(name, _args, _ctx) when name in @boolean_functions, do: :bool
  defp call_type(name, _args, _ctx) when name in @float_functions, do: :float
  defp call_type(name, _args, _ctx) when name in @text_functions, do: :str

  defp call_type(name, args, ctx)
       when is_list(args) and name in @same_type_functions do
    args
    |> Enum.map(&type_of(&1, ctx))
    |> Enum.reject(&(&1 == :null))
    |> Enum.uniq()
    |> case do
      [] -> :null
      [single] -> single
      several -> if Enum.all?(several, &(&1 in @numeric)), do: :num, else: :unknown
    end
  end

  defp call_type(name, _args, _ctx) when name in ~w(sum avg median stddev var), do: :num
  defp call_type(_name, _args, _ctx), do: :unknown

  @spec column_type(binary() | nil) :: type()
  defp column_type("Int64"), do: :int
  defp column_type("UInt64"), do: :uint
  defp column_type("Float64"), do: :float
  defp column_type("Boolean"), do: :bool
  defp column_type("Timestamp(ns)"), do: :time
  defp column_type(type) when type in ["Utf8", "Dictionary(Int32, Utf8)"], do: :str
  defp column_type(_type), do: :unknown

  @spec cast_type(SQLDmlType.t()) :: type()
  defp cast_type({:unsupported, _printed}), do: :unknown
  defp cast_type(%{family: :timestamp}), do: :time
  defp cast_type(%{family: family}), do: family
end
