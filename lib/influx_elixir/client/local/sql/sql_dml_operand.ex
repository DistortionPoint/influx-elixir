defmodule InfluxElixir.Client.Local.SQLDmlOperand do
  @moduledoc false
  # The planner's reading of the operands of an `INSERT`, an `UPDATE` and a `DELETE` (the values
  # it assigns or inserts, the items it selects and its `WHERE`), for
  # `InfluxElixir.Client.Local.SQLDml` (verified against InfluxDB 3 Core 3.10.1).
  #
  # The planner reads an operand in two passes. The first turns the SQL into an expression. It
  # meets the calls and types (`eager/2`) in order and finds fault with
  #
  #   * a function it has not, a type it cannot plan, a placeholder of index zero
  #   * a unary `+` of anything but a number, an interval or a timestamp, a `||` whose operands
  #     have no type and a `CAST` to a timestamp of an operand that has none (all need the types
  #     of their operands at that point, `get_type`: the planner turns a number it casts to a
  #     timestamp into seconds)
  #
  # and finds the names last (`lazy/2`): a name that is no field of the relation (a name before
  # a `.` must be the relation: the alias when there is one, else the table, whose schema and
  # catalog must agree as far as both are written).
  #
  # The second types the value assigned to a column to convert it to the column's type. A
  # value's type is found through an arithmetic or comparison operator, a negation, a cast, a
  # `CASE` result and the arguments of a function, which fail by the words of a select item of
  # the same operand (`plan_top/2` plans it as one). It is not found through `IS [NOT] NULL`,
  # `IS [NOT] TRUE/FALSE/UNKNOWN`, which are booleans whatever they test; and what stands in a
  # `NOT`, `BETWEEN`, `IN` or `LIKE` is reached only where it is a call, whose arguments are
  # typed whole. A `WHERE` is not typed at all but for its names, the checks above and a
  # predicate that is not a boolean.
  #
  # Nothing that only a later pass finds is an error here: a negation of text, a `LIKE` of a
  # number, a constant the optimizer cannot fold.

  alias InfluxElixir.Client.Local.{
    SQLCommonType,
    SQLDml,
    SQLDmlExpr,
    SQLDmlName,
    SQLDmlType,
    SQLError,
    SQLFunctions,
    SQLNumber
  }

  @typedoc "What the operands of a statement are read against."
  @type ctx :: %{
          optional(:infer) => boolean(),
          table: binary() | nil,
          columns: [binary()],
          types: %{binary() => binary()},
          relation: [binary()],
          relation_text: binary(),
          planner: (binary() | nil, binary() -> :ok | {:error, term()})
        }

  @typedoc "`:ok`, the engine's error, or a refusal by name of what the double does not model."
  @type check :: :ok | {:error, SQLError.t() | map()} | {:refuse, SQLDml.reason()}

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

  # A placeholder, which takes its type from what stands beside it.
  defguardp is_param(node)
            when is_tuple(node) and tuple_size(node) == 2 and elem(node, 0) == :param

  # What stands for a timestamp and for a boolean where the double plans a node it has no
  # planner for: of the same type to the planner.
  @time_dummy {:ref, [{"time", true}]}
  @bool_dummy {:bool, true}

  @comparisons ~w(= == <> != < > <= >= <=> ~ ~* !~ !~* ~~ ~~* !~~ !~~* AND OR)
  @arithmetic ~w(+ - * / %)
  @exact [:int, :uint, :float, :decimal]
  @exact_numbers [:int, :uint, :float]
  @compared ~w(= == <> != < > <= >=)
  @numeric [:int, :uint, :float, :num, :decimal]
  # Functions whose result is a boolean.
  @boolean_functions ~w(starts_with ends_with contains regexp_like)
  # Functions of one number that give a float, of text that give text, and the aggregates.
  @float_functions ~w(round trunc floor ceil sqrt ln log pow power)
  @text_functions ~w(lower upper substr left right concat)
  @same_type_functions ~w(coalesce nullif greatest least min max first_value last_value)
  # The functions the engine has that the double reads (its own, `SQLFunctions`, besides these).
  @known_functions ~w(count sum avg median stddev stddev_pop var var_pop approx_distinct
                      approx_median now current_timestamp date_trunc date_bin locf
                      interpolate length)

  # The aggregate functions: a select list that calls one groups every column outside of one.
  # The calls of the time (`CURRENT_TIMESTAMP` is the call `now()`, named as it was written).
  @now ~w(now current_timestamp)

  @aggregates ~w(count sum avg min max median stddev stddev_pop var var_pop approx_distinct
                 approx_median first_value last_value)

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
      not known_function?(name) -> {:refuse, {:unknown_function, name}}
      converted_alone?(name, args) -> {:refuse, "a call the planner converts on its own"}
      args == :star -> :ok
      true -> eager(args, ctx)
    end
  end

  def eager({:pos, inner}, ctx) do
    with :ok <- eager(inner, ctx) do
      case nullable(inner, ctx) do
        {:fail, failure} -> failure
        :unknown -> inner |> plus_typed(ctx) |> unless_unresolved(inner, ctx)
        _decided -> plus_typed(inner, ctx)
      end
    end
  end

  def eager({:bin, "||", _left, _right} = node, ctx) do
    concat(node, ctx)
  end

  def eager({:in, inner, items, _negated}, ctx) do
    with :ok <- eager(items, ctx), do: eager(inner, ctx)
  end

  def eager({:ordered, call, terms}, ctx) do
    with :ok <- eager(call, ctx), do: eager(Enum.map(terms, &elem(&1, 0)), ctx)
  end

  # The planner reads the pattern of a `LIKE`, then checks its escape, then reads the operand.
  def eager({:like, inner, pattern, _negated, _word, escape}, ctx) do
    with :ok <- eager(pattern, ctx),
         :ok <- escape_length(escape),
         do: eager(inner, ctx)
  end

  # A `CAST` (or `::`) to a type the planner cannot plan fails before what it casts is read, a
  # `TRY_CAST` after it. A cast (not a `TRY_CAST`) to a timestamp finds the type of what it casts
  # there and then, as a `||` does of its operands.
  def eager({:cast, _inner, {:unsupported, printed}, false}, _ctx),
    do: {:error, SQLDmlType.unsupported(printed)}

  def eager({:cast, inner, type, try?}, ctx) do
    with :ok <- eager(inner, ctx) do
      case {type, try?} do
        {{:unsupported, printed}, true} -> {:error, SQLDmlType.unsupported(printed)}
        {%{family: :timestamp}, false} -> early_top(inner, ctx)
        _planned -> :ok
      end
    end
  end

  # A row of values must start with a name or a literal, which the engine says as it reads the
  # row (the other values are read as any operand is).
  def eager({:tuple, [first | _rest] = items}, ctx) do
    if tuple_item?(first),
      do: eager(items, ctx),
      else:
        {:error,
         %{
           status: 405,
           body:
             "This feature is not implemented: Only identifiers and literals are supported in tuples"
         }}
  end

  def eager(node, ctx) do
    case SQLDmlExpr.children(node) do
      [] -> :ok
      children -> eager(children, ctx)
    end
  end

  @spec tuple_item?(SQLDmlExpr.ast()) :: boolean()
  defp tuple_item?({kind, _value}) when kind in [:ref, :num, :str, :bool, :param, :zero_param],
    do: true

  defp tuple_item?(:null), do: true
  defp tuple_item?(_other), do: false

  # A `||` needs the types of its operands as it reads it (to rewrite it as a call or not): it
  # reads both operands whole (their own errors, in the order of the expression), then types the
  # left, then the right. An operand that is a `||` is typed by its own concatenation alone: what
  # it holds was typed when it was read, so a chain of `n` terms is `n` small checks and not `n`
  # nested ones that each type all that is below (that is the cost of typing a chain by typing
  # every prefix of it).
  @spec concat(SQLDmlExpr.ast(), ctx()) :: check()
  defp concat({:bin, "||", left, right}, ctx) do
    with :ok <- operand(left, ctx),
         :ok <- operand(right, ctx),
         :ok <- typed(left, ctx),
         do: typed(right, ctx)
  end

  @spec operand(SQLDmlExpr.ast(), ctx()) :: check()
  defp operand({:bin, "||", _left, _right} = node, ctx), do: concat(node, ctx)
  defp operand(node, ctx), do: eager(node, ctx)

  @spec typed(SQLDmlExpr.ast(), ctx()) :: check()
  defp typed({:bin, "||", left, right}, ctx) do
    own = {:bin, "||", stood_in(left), stood_in(right)}
    if plain_concat?(own, ctx), do: :ok, else: early_top(own, ctx)
  end

  defp typed(node, ctx), do: early_top(node, ctx)

  # A `||` read already stands for the text it makes.
  @spec stood_in(SQLDmlExpr.ast()) :: SQLDmlExpr.ast()
  defp stood_in({:bin, "||", _left, _right}), do: {:str, ""}
  defp stood_in(node), do: node

  # `text || anything simple` is a text, whatever the other operand is (a tag is not text here,
  # it is the dictionary of one: `host || 1` is the planner's error).
  @spec plain_concat?(SQLDmlExpr.ast(), ctx()) :: boolean()
  defp plain_concat?({:bin, "||", left, right}, ctx),
    do: (text?(left, ctx) and simple?(right)) or (text?(right, ctx) and simple?(left))

  @spec text?(SQLDmlExpr.ast(), ctx()) :: boolean()
  defp text?({:str, _body}, _ctx), do: true
  defp text?({:ref, parts}, ctx), do: column?(parts, ctx) and column_arrow(parts, ctx) == "Utf8"
  defp text?(_node, _ctx), do: false

  @spec simple?(SQLDmlExpr.ast()) :: boolean()
  defp simple?({kind, _text}) when kind in [:num, :str, :bool, :ref, :param], do: true
  defp simple?(:null), do: true
  defp simple?(_node), do: false

  # Whether an operator takes operands of these types (numbers of the engine's kinds, texts,
  # booleans and timestamps with their own kind; `AND` and `OR` take booleans).
  @spec shared?(binary(), type(), type()) :: boolean()
  defp shared?(op, left, right) when op in @arithmetic,
    do: left in @exact_numbers and right in @exact_numbers

  defp shared?(op, left, right) when op in ["AND", "OR"], do: left == :bool and right == :bool

  defp shared?(_comparison, left, right) do
    (left in @exact_numbers and right in @exact_numbers) or
      (left == right and left in [:str, :bool, :time])
  end

  @spec column_arrow([SQLDmlExpr.name()], ctx()) :: binary() | nil
  defp column_arrow(parts, ctx), do: ctx.types[parts |> List.last() |> elem(0)]

  # An operand the planner cannot find fault with: a chain of `||` whose every link is a text
  # beside a constant, a placeholder or a column, and arithmetic, a comparison, `AND` and `OR`
  # of operands of types that share one. The double plans only what can be wrong.
  @spec trivially_typed?(SQLDmlExpr.ast(), ctx()) :: boolean()
  defp trivially_typed?({:bin, "||", left, right}, ctx) do
    plain_concat?({:bin, "||", stood_in(left), stood_in(right)}, ctx) and
      trivially_typed?(left, ctx) and trivially_typed?(right, ctx)
  end

  defp trivially_typed?({:bin, op, left, right}, ctx)
       when op in @arithmetic or op in @compared or op in ~w(AND OR) do
    trivially_typed?(left, ctx) and trivially_typed?(right, ctx) and
      shared?(op, type_of(left, ctx), type_of(right, ctx))
  end

  defp trivially_typed?({kind, _text}, _ctx) when kind in [:num, :str, :bool, :param],
    do: true

  defp trivially_typed?(:null, _ctx), do: true
  defp trivially_typed?({:ref, parts}, ctx), do: column?(parts, ctx)
  defp trivially_typed?(_node, _ctx), do: false

  # The planner finds the type of an operand as it reads it (a placeholder in it has no type
  # yet: the planner gives it one once the statement is read). An arithmetic operator over two
  # tags is the planner's `Cannot coerce` there as anywhere else (verified, in a `||`, a cast,
  # a call, a unary sign, an `IS`, in `UPDATE`, `DELETE` and `INSERT ... SELECT`).
  @spec early_top(SQLDmlExpr.ast(), ctx()) :: check()
  defp early_top(node, ctx), do: plan_top(node, Map.put(ctx, :infer, false))

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
  def lazy(operand, ctx) do
    with :ok <- unresolved(operand, ctx), do: inference(operand, ctx)
  end

  # A field of a column (`host.a`) is a name until its type is asked for. The planner asks it of
  # a value it assigns or selects when it finds whether the value can be null, which it does
  # through every operand but a test of a value (`IS NULL`), stopping at the first operand that
  # can: a column can, a constant cannot, `time` cannot.
  @doc """
  What the planner finds of the fields of columns in a value it types (an assigned or selected
  one), after everything else: the type error of the first it asks the null-ness of, or a
  refusal where the double does not follow which that is.
  """
  @spec late(SQLDmlExpr.ast(), ctx()) :: check()
  def late(operand, ctx) do
    if dotted?(operand) do
      case nullable(operand, ctx) do
        {:fail, failure} -> failure
        :unknown -> unfollowed(operand, ctx)
        _decided -> :ok
      end
    else
      :ok
    end
  end

  @spec unfollowed(SQLDmlExpr.ast(), ctx()) :: check()
  defp unfollowed(operand, ctx) do
    if field_of?(operand, ctx),
      do: {:refuse, "a field of a column in a value whose nullability is not followed"},
      else: :ok
  end

  @spec dotted?(SQLDmlExpr.ast()) :: boolean()
  defp dotted?({:ref, [_one, _two | _more]}), do: true
  defp dotted?(node), do: node |> SQLDmlExpr.children() |> Enum.any?(&dotted?/1)

  @spec nullable(SQLDmlExpr.ast(), ctx()) :: boolean() | {:fail, check()} | :unknown
  defp nullable({:ref, parts}, ctx) do
    {column, _quoted} = List.last(parts)

    case resolve(parts, ctx) do
      {:field_of, type} -> {:fail, {:error, indexed_field(type)}}
      :ok when is_binary(ctx.table) -> column != "time"
      :ok -> :unknown
      failure -> {:fail, failure}
    end
  end

  defp nullable({kind, _text}, _ctx) when kind in [:num, :str, :bool], do: false
  defp nullable(:null, _ctx), do: true
  defp nullable({kind, _text}, _ctx) when kind in [:param, :zero_param], do: true
  defp nullable({kind, inner}, ctx) when kind in [:neg, :pos, :not], do: nullable(inner, ctx)
  defp nullable({:cast, inner, _type, false}, ctx), do: nullable(inner, ctx)
  defp nullable({:cast, _inner, _type, true}, _ctx), do: true
  defp nullable({:is, _inner, what, _negated}, _ctx) when not is_tuple(what), do: false
  defp nullable({:bin, _op, left, right}, ctx), do: any_nullable([left, right], ctx)
  defp nullable({:in, inner, items, _negated}, ctx), do: any_nullable([inner | items], ctx)

  defp nullable({:between, inner, low, high, _negated}, ctx),
    do: any_nullable([inner, low, high], ctx)

  defp nullable({:like, inner, pattern, _negated, _word, _escape}, ctx),
    do: any_nullable([inner, pattern], ctx)

  defp nullable(_other, _ctx), do: :unknown

  @spec any_nullable([SQLDmlExpr.ast()], ctx()) :: boolean() | {:fail, check()} | :unknown
  defp any_nullable(operands, ctx) do
    Enum.reduce_while(operands, false, fn operand, false ->
      case nullable(operand, ctx) do
        false -> {:cont, false}
        decided -> {:halt, decided}
      end
    end)
  end

  @spec indexed_field(binary() | nil) :: map()
  defp indexed_field(type) do
    %{
      status: 500,
      body:
        "Execution error: The expression to get an indexed field is only valid for " <>
          "`Struct`, `Map` or `Null` types, got #{type}"
    }
  end

  @doc "Whether a name is a column of the relation (not a field of one, nor a name it has not)."
  @spec column?([SQLDmlExpr.name()], ctx()) :: boolean()
  def column?(parts, ctx), do: resolve(parts, ctx) == :ok

  @spec unresolved(SQLDmlExpr.ast() | [SQLDmlExpr.ast()], ctx()) :: check()
  defp unresolved(list, ctx) when is_list(list) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case unresolved(item, ctx) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp unresolved({:ref, parts}, ctx) do
    case resolve(parts, ctx) do
      {:field_of, _type} -> :ok
      other -> other
    end
  end

  defp unresolved(node, ctx), do: unresolved(SQLDmlExpr.children(node), ctx)

  # The planner gives a placeholder the type of the operand beside it, as it reads the operand
  # that holds it (inside a `NOT` or a cast too), and finds fault with that operand in words that
  # print it and what it fails with. The double does not print them: it refuses the operand when
  # the one beside a placeholder cannot be typed, is a field of a column, or is a timestamp the
  # placeholder is an arithmetic operand of.
  @spec inference(SQLDmlExpr.ast() | [SQLDmlExpr.ast()], ctx()) :: check()
  defp inference(operand, ctx), do: if(param?(operand), do: infer(operand, ctx, false), else: :ok)

  @spec infer(SQLDmlExpr.ast() | [SQLDmlExpr.ast()], ctx(), boolean()) :: check()
  defp infer(list, ctx, cast?) when is_list(list) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case infer(item, ctx, cast?) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp infer({:cast, _inner, _type, _try} = node, ctx, _cast?),
    do: infer(SQLDmlExpr.children(node), ctx, true)

  defp infer(node, ctx, cast?) do
    with :ok <- beside_all(siblings(node), ctx, cast?),
         do: infer(SQLDmlExpr.children(node), ctx, cast?)
  end

  # The operands a placeholder in a node takes its type from, each with the operator between.
  @spec siblings(SQLDmlExpr.ast()) :: [{SQLDmlExpr.ast(), binary()}]
  defp siblings({:bin, op, left, right}), do: pair_sibling(left, right, op)
  defp siblings({:is, left, {:distinct, right}, _negated}), do: pair_sibling(left, right, "")

  defp siblings({:like, inner, pattern, _negated, _word, _escape}),
    do: pair_sibling(inner, pattern, "")

  defp siblings({:between, inner, low, high, _negated}) do
    if is_param(low) or is_param(high),
      do: pair_sibling(inner, :param_beside, ""),
      else: pair_sibling(inner, low, "")
  end

  defp siblings({:in, inner, items, _negated}) do
    cond do
      Enum.any?(items, &is_param/1) ->
        pair_sibling(inner, :param_beside, "")

      is_param(inner) ->
        items
        |> Enum.reject(&is_param/1)
        |> Enum.take(1)
        |> Enum.flat_map(&pair_sibling(inner, &1, ""))

      true ->
        []
    end
  end

  defp siblings(_node), do: []

  @spec pair_sibling(SQLDmlExpr.ast(), SQLDmlExpr.ast() | :param_beside, binary()) ::
          [{SQLDmlExpr.ast(), binary()}]
  defp pair_sibling(left, :param_beside, op), do: if(is_param(left), do: [], else: [{left, op}])

  defp pair_sibling(left, right, op) do
    cond do
      is_param(left) and not is_param(right) -> [{right, op}]
      is_param(right) and not is_param(left) -> [{left, op}]
      true -> []
    end
  end

  @spec beside_all([{SQLDmlExpr.ast(), binary()}], ctx(), boolean()) :: check()
  defp beside_all(siblings, ctx, cast?) do
    Enum.reduce_while(siblings, :ok, fn sibling, :ok ->
      case beside(sibling, ctx, cast?) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  # A timestamp beside a placeholder in arithmetic is the planner's own error, in words the double
  # has; but not inside a cast, whose operand the planner does not type until later.
  @spec beside({SQLDmlExpr.ast(), binary()}, ctx(), boolean()) :: check()
  defp beside({operand, op}, ctx, cast?) do
    cond do
      field_of?(operand, ctx) ->
        {:refuse, "a placeholder beside a field of a column"}

      plan_top(operand, ctx) != :ok ->
        {:refuse, "an operand a placeholder takes its type from that fails to type"}

      cast? and op in @arithmetic and type_of(operand, ctx) == :time ->
        {:refuse, "a placeholder beside a timestamp in arithmetic inside a cast"}

      true ->
        :ok
    end
  end

  @spec field_of?(SQLDmlExpr.ast(), ctx()) :: boolean()
  defp field_of?({:ref, parts}, ctx), do: match?({:field_of, _type}, resolve(parts, ctx))
  defp field_of?(node, ctx), do: node |> SQLDmlExpr.children() |> Enum.any?(&field_of?(&1, ctx))

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

  @doc """
  Whether a check is the refusal of a call to a function the double does not know (which the
  planner finds with the errors of its own, where the double cannot say which comes first).
  """
  @spec unknown_function?(check()) :: boolean()
  def unknown_function?({:refuse, {:unknown_function, _name}}), do: true

  def unknown_function?(_check), do: false

  @spec known_function?(binary()) :: boolean()
  defp known_function?(name) do
    name in @known_functions or name in @float_functions or name in @text_functions or
      name in @same_type_functions or name in @boolean_functions or name == "abs" or
      SQLFunctions.lookup(name) != nil
  end

  # The planner asks whether the operand of a plus can be null (`nullable/2`, which meets the
  # names of the operand that typing alone does not, and stops at the first that can be null),
  # then types it. Where the double does not follow which operands can be null (a call), a type
  # error beside a name it has not found is refused.
  @spec plus_typed(SQLDmlExpr.ast(), ctx()) :: check()
  defp plus_typed(inner, ctx) do
    with :ok <- early_top(inner, ctx), do: plus(inner, ctx)
  end

  @spec unless_unresolved(check(), SQLDmlExpr.ast(), ctx()) :: check()
  defp unless_unresolved(
         {:error, %{body: "Schema error: No field named" <> _name}} = failure,
         _inner,
         _ctx
       ),
       do: failure

  defp unless_unresolved(failure, inner, ctx) do
    case reaching(inner, ctx) do
      :ok -> failure
      ^failure -> failure
      _unresolved -> {:refuse, "a unary plus of an operand with a type error and an unknown name"}
    end
  end

  @spec reaching(SQLDmlExpr.ast() | [SQLDmlExpr.ast()], ctx()) :: check()
  defp reaching(list, ctx) when is_list(list) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case reaching(item, ctx) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp reaching({:ref, parts}, ctx), do: typed_name(parts, ctx)
  defp reaching({:is, _inner, what, _negated}, _ctx) when not is_tuple(what), do: :ok
  defp reaching(node, ctx), do: reaching(SQLDmlExpr.children(node), ctx)

  @spec plus(SQLDmlExpr.ast(), ctx()) :: check()
  defp plus(inner, ctx) do
    case type_of(inner, ctx) do
      type when type in [:null, :str, :bool, :date, :clock, :binary, :list, :duration] ->
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
      {:field_of, type} -> {:error, indexed_field(type)}
      other -> other
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
  Whether a select list calls an aggregate and names a column outside of every aggregate (the
  planner then groups the list, and finds fault with that column in words the double does not
  print).
  """
  @spec ungrouped?([SQLDmlExpr.ast()]) :: boolean()
  def ungrouped?(operands),
    do: Enum.any?(operands, &aggregate?/1) and Enum.any?(operands, &column_outside?/1)

  @spec aggregate?(SQLDmlExpr.ast()) :: boolean()
  defp aggregate?({:call, name, _args}) when name in @aggregates, do: true
  defp aggregate?({:ordered, call, _terms}), do: aggregate?(call)
  defp aggregate?(node), do: node |> SQLDmlExpr.children() |> Enum.any?(&aggregate?/1)

  @spec column_outside?(SQLDmlExpr.ast()) :: boolean()
  defp column_outside?({:ref, _parts}), do: true
  defp column_outside?({:call, name, _args}) when name in @aggregates, do: false
  defp column_outside?({:ordered, call, _terms}), do: column_outside?(call)
  defp column_outside?(node), do: node |> SQLDmlExpr.children() |> Enum.any?(&column_outside?/1)

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
  defp predicate_type({:param, _text}, _ctx), do: :ok
  defp predicate_type({:call, name, _args}, _ctx) when name in @boolean_functions, do: :ok
  defp predicate_type({:ordered, _call, _terms} = call, ctx), do: untyped(call, ctx)

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
      else: {:refuse, "a WHERE that is a sign in front of a value that is not a boolean"}
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

  defp predicate_type({:cast, _inner, _type, _try}, _ctx),
    do: {:refuse, "a WHERE that is a cast, which the planner types as the cast type"}

  defp predicate_type({:tuple, _items}, _ctx),
    do: {:refuse, "a WHERE that is a row of values"}

  defp predicate_type(_other, _ctx),
    do: {:refuse, "a WHERE of a kind the double has not verified"}

  @spec untyped(SQLDmlExpr.ast(), ctx()) :: check()
  defp untyped(operand, ctx) do
    case plan_top(operand, ctx) do
      :ok -> if type_of(operand, ctx) == :bool, do: :ok, else: not_boolean_value(operand)
      {:error, %{body: "Client.Local: " <> why}} -> {:refuse, why}
      {:error, _typed_wrong} -> :ok
      {:refuse, _why} = refusal -> refusal
    end
  end

  @spec not_boolean_value(SQLDmlExpr.ast()) :: check()
  defp not_boolean_value({:bin, "||", _left, _right}),
    do: {:refuse, "a WHERE that is a concatenation, a value that is not a boolean"}

  defp not_boolean_value({:bin, _op, _left, _right}),
    do: {:refuse, "a WHERE that is arithmetic, a value that is not a boolean"}

  defp not_boolean_value({:call, name, _args}) when name in @now,
    do: {:refuse, "a WHERE that is the time of the query, a value that is not a boolean"}

  defp not_boolean_value({:call, name, _args}) when name in @aggregates,
    do: {:refuse, "a WHERE that is an aggregate, a value that is not a boolean"}

  defp not_boolean_value({:call, _name, _args}),
    do: {:refuse, "a WHERE that is a call of a function with a value that is not a boolean"}

  defp not_boolean_value({:ordered, _call, _terms}),
    do: {:refuse, "a WHERE that is an ordered aggregate, a value that is not a boolean"}

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
    cond do
      negative_zero?(value) -> "-0"
      value == Float.round(value) and abs(value) < 1.0e15 -> Integer.to_string(trunc(value))
      true -> Float.to_string(value)
    end
  end

  @spec negative_zero?(float()) :: boolean()
  defp negative_zero?(value), do: value == 0.0 and match?(<<1::1, _rest::63>>, <<value::float>>)

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

      {:ok, type}
      when (target == "Boolean" and type in [:unknown, :decimal]) or
             (target == "Timestamp(ns)" and type == :unknown) ->
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
  def plan_top({:param, _text}, _ctx), do: :ok
  def plan_top({:ref, parts}, ctx), do: typed_name(parts, ctx)

  def plan_top(operand, ctx) do
    cond do
      exotic_nested?(operand, true) ->
        {:refuse, "an operator or a call over a cast to a type the double has no planner for"}

      negated_unsigned?(operand) ->
        {:refuse, "a negation of a cast to an unsigned type"}

      unsigned_against_time?(operand, ctx) ->
        {:refuse, "a comparison of a timestamp with an unsigned number or a narrow integer"}

      trivially_typed?(operand, ctx) ->
        :ok

      true ->
        plan_typed(operand, ctx)
    end
  end

  # The planner finds the comparison of a timestamp with an unsigned number, or with an integer
  # of fewer than 64 bits (the length of a text is an `Int32`), wrong wherever it stands in the
  # operand; the double finds it only at the top, or takes it for the comparison of a timestamp
  # with a text.
  @spec unsigned_against_time?(SQLDmlExpr.ast(), ctx()) :: boolean()
  defp unsigned_against_time?({:bin, op, left, right} = node, ctx) do
    types = {type_of(left, ctx), type_of(right, ctx)}

    (op in @compared and
       (types in [{:uint, :time}, {:time, :uint}] or length_of_text?(types, left, right))) or
      node |> SQLDmlExpr.children() |> Enum.any?(&unsigned_against_time?(&1, ctx))
  end

  defp unsigned_against_time?(node, ctx),
    do: node |> SQLDmlExpr.children() |> Enum.any?(&unsigned_against_time?(&1, ctx))

  @spec length_of_text?({type(), type()}, SQLDmlExpr.ast(), SQLDmlExpr.ast()) :: boolean()
  defp length_of_text?({:time, _other}, _left, right), do: narrow?(right)
  defp length_of_text?({_other, :time}, left, _right), do: narrow?(left)
  defp length_of_text?(_types, _left, _right), do: false

  # An operand of a width the double does not give its own type: the length of a text, an integer
  # of fewer than 64 bits.
  @spec narrow?(SQLDmlExpr.ast()) :: boolean()
  defp narrow?({:call, "length", _args}), do: true
  defp narrow?({:cast, _inner, %{family: :int, bits: bits}, _try}), do: bits != 64
  defp narrow?(_node), do: false

  # An unsigned cast stands in as a number the planner negates to a signed one.
  @spec negated_unsigned?(SQLDmlExpr.ast()) :: boolean()
  defp negated_unsigned?({:neg, {:cast, _inner, %{family: :uint}, _try}}), do: true

  defp negated_unsigned?(node),
    do: node |> SQLDmlExpr.children() |> Enum.any?(&negated_unsigned?/1)

  @spec plan_typed(SQLDmlExpr.ast(), ctx()) :: check()
  defp plan_typed(operand, ctx) do
    if type_of(operand, ctx) == :duration do
      # The difference of two timestamps is a duration, which no select item here can be.
      {:bin, _op, left, right} = operand
      with :ok <- plan_top(left, ctx), do: plan_top(right, ctx)
    else
      {lowered, _deferred} = lower(operand, ctx)

      case reachable(operand, ctx) do
        :ok -> operand |> inferred_text(lowered, ctx) |> unless_hidden(operand, ctx)
        unresolved -> unless_mixed(unresolved, operand, ctx)
      end
    end
  end

  # The planner types an operand from its left to its right, so that a type error of an operand
  # before a name the table lacks is found first, and the double finds all the names first. It
  # cannot tell which comes first when the operand has both: it refuses it.
  @spec unless_mixed(check(), SQLDmlExpr.ast(), ctx()) :: check()
  defp unless_mixed(unresolved, operand, ctx) do
    {lowered, _deferred} = lower(operand, ctx)

    case plan_text(lowered, ctx, &missing_as_null(&1, ctx)) do
      :ok -> unresolved
      _also_wrong -> {:refuse, "an operand with a name the table lacks and a type error"}
    end
  end

  # A type error found beside a name the table lacks that the typing does not reach (inside a
  # test, a `LIKE`) is the first the planner meets only if the name comes after it.
  @spec unless_hidden(check(), SQLDmlExpr.ast(), ctx()) :: check()
  defp unless_hidden({:error, %{body: "Client.Local: " <> _reason}} = refusal, _operand, _ctx),
    do: refusal

  defp unless_hidden({:error, _type_error} = error, operand, ctx) do
    case reaching(operand, ctx) do
      :ok -> error
      _missing -> {:refuse, "an operand with a name the table lacks and a type error"}
    end
  end

  defp unless_hidden(other, _operand, _ctx), do: other

  # A name that is no field is written as the null.
  @spec missing_as_null([SQLDmlExpr.name()], ctx()) :: binary()
  defp missing_as_null(parts, ctx),
    do: if(typed_name(parts, ctx) == :ok, do: field_text(parts), else: "NULL")

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
  defp inferred_from({:bin, _op, param, other}) when is_param(param) and not is_param(other),
    do: [other]

  defp inferred_from({:bin, _op, other, param}) when is_param(param) and not is_param(other),
    do: [other]

  defp inferred_from({:is, param, {:distinct, other}, _negated})
       when is_param(param) and not is_param(other),
       do: [other]

  defp inferred_from({:is, other, {:distinct, param}, _negated})
       when is_param(param) and not is_param(other),
       do: [other]

  defp inferred_from(node), do: node |> SQLDmlExpr.children() |> Enum.flat_map(&inferred_from/1)

  @spec plan_text(SQLDmlExpr.ast(), ctx(), ([SQLDmlExpr.name()] -> binary())) :: check()
  defp plan_text(lowered, ctx, names \\ &field_text/1) do
    text = SQLDmlExpr.unparse(lowered, names)

    case ctx.planner.(ctx.table, text) do
      :ok ->
        :ok

      # A negation is checked late, after the planning an update stops at.
      {:error, %{body: "Error during planning: Negation only supports" <> _rest}} ->
        :ok

      # What the double cannot word because the engine reads a value (a timestamp against text,
      # a timestamp joined as text) is the engine's error only when it runs a plan; but not
      # where a cast stands beside it, whose type the planner finds and may find wrong.
      {:error, %{body: "Client.Local: " <> reason}} = refusal ->
        if Enum.any?(@runtime_only, &String.contains?(reason, &1)) and
             not String.contains?(text, "CAST("),
           do: :ok,
           else: refusal

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
  defp lower({:call, name, []}, _ctx) when name in @now, do: {@time_dummy, []}

  # A test of a value is a boolean whatever the value is.
  defp lower({:is, _inner, what, _negated}, _ctx) when not is_tuple(what),
    do: {@bool_dummy, []}

  defp lower({:is, inner, {:distinct, other}, negated}, ctx) do
    {[inner, other], operands} = lower_all(inferred([inner, other], ctx), ctx)
    {{:is, inner, {:distinct, other}, negated}, operands}
  end

  defp lower({kind, _a} = node, ctx) when kind == :not, do: {@bool_dummy, calls(node, ctx)}
  defp lower({:in, _a, _b, _c} = node, ctx), do: {@bool_dummy, calls(node, ctx)}
  defp lower({:between, _a, _b, _c, _d} = node, ctx), do: {@bool_dummy, calls(node, ctx)}
  defp lower({:like, _a, _b, _c, _d, _e} = node, ctx), do: {@bool_dummy, calls(node, ctx)}

  # The planner types a cast as its type, and what it casts only when it builds the projection;
  # a `TRY_CAST` never types what it casts (only its names are read).
  defp lower({:cast, inner, type, false}, _ctx), do: {cast_stand_in(type, false), [inner]}
  defp lower({:cast, _inner, type, true}, _ctx), do: {cast_stand_in(type, true), []}

  defp lower({:call, name, args}, ctx) when is_list(args) do
    # Only a call of these over arguments of one kind, time or boolean, stands for that kind; a
    # number or a text among the arguments settles it without typing the rest (typing each
    # argument at every level of a nest of calls costs the square of its depth).
    kinds =
      if name in ~w(coalesce nullif greatest least) and not Enum.any?(args, &other_literal?/1),
        do: args |> Enum.map(&type_of(&1, ctx)) |> Enum.uniq()

    if kinds in [[:time], [:bool]] do
      {if(kinds == [:time], do: @time_dummy, else: @bool_dummy), args}
    else
      {lowered, operands} = lower_all(args, ctx)
      {{:call, name, lowered}, operands}
    end
  end

  defp lower({:ordered, call, terms}, ctx) do
    {lowered, operands} = lower(call, ctx)
    {ordering, deferred} = lower_all(Enum.map(terms, &elem(&1, 0)), ctx)

    case lowered do
      {:call, _name, _args} ->
        {{:ordered, lowered, Enum.zip(ordering, Enum.map(terms, &elem(&1, 1)))},
         operands ++ deferred}

      _stood_in ->
        {lowered, operands ++ deferred}
    end
  end

  defp lower({sign, inner}, ctx) when sign in [:neg, :pos] do
    {lowered, operands} = lower(inner, ctx)
    {{sign, lowered}, operands}
  end

  defp lower({:bin, op, left, right}, ctx) do
    {[left, right], operands} = lower_all(inferred([left, right], ctx), ctx)
    {{:bin, op, left, right}, operands}
  end

  defp lower({:tuple, items}, ctx) do
    {lowered, operands} = lower_all(items, ctx)
    {{:tuple, lowered}, operands}
  end

  defp lower(leaf, _ctx), do: {leaf, []}

  # A placeholder beside an operand has that operand's type, once the statement is read.
  @spec inferred([SQLDmlExpr.ast()], ctx()) :: [SQLDmlExpr.ast()]
  defp inferred(pair, %{infer: false}), do: pair

  defp inferred([param, other], _ctx) when is_param(param) and not is_param(other),
    do: [other, other]

  defp inferred([other, param], _ctx) when is_param(param) and not is_param(other),
    do: [other, other]

  defp inferred(pair, _ctx), do: pair

  # A literal that is neither a time nor a boolean.
  @spec other_literal?(SQLDmlExpr.ast()) :: boolean()
  defp other_literal?({kind, _value}) when kind in [:num, :str], do: true
  defp other_literal?(_node), do: false

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
  defp exotic?(%{family: :uint, bits: bits}) when bits != 64, do: true
  defp exotic?(_type), do: false

  # A cast to such a type anywhere in an operand, and a placeholder anywhere in it (a
  # placeholder takes its type from what stands beside it, which fails for such a cast).
  @spec exotic_in_cast?(SQLDmlExpr.ast()) :: boolean()
  defp exotic_in_cast?({:cast, inner, type, _try}),
    do: exotic?(type) or exotic_in_cast?(inner)

  defp exotic_in_cast?(node), do: node |> SQLDmlExpr.children() |> Enum.any?(&exotic_in_cast?/1)

  @spec param?(SQLDmlExpr.ast()) :: boolean()
  defp param?(param) when is_param(param), do: true
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
  @spec calls(SQLDmlExpr.ast(), ctx()) :: [SQLDmlExpr.ast()]
  defp calls({:call, name, []}, _ctx) when name in @now, do: []
  defp calls({:call, name, _args}, _ctx) when name in @aggregates, do: []
  defp calls({:ordered, {:call, name, _args}, _terms}, _ctx) when name in @aggregates, do: []
  defp calls({:call, _name, _args} = call, _ctx), do: [call]
  defp calls({:ordered, _call, _terms} = call, _ctx), do: [call]
  defp calls({:is, _inner, _what, _negated}, _ctx), do: []

  # The planner types the operand of an `IN`, a `BETWEEN` and a `LIKE`, and the list, the bounds
  # and the pattern only as far as it asks whether they can be null: it stops at the first that
  # can (verified: `b = n IN (abs(s))` is the update's own error, as `n` can be null, where
  # `5 IN (abs(s))` types `abs(s)`).
  defp calls({:in, inner, items, _negated}, ctx), do: asked([inner | items], ctx)
  defp calls({:between, inner, low, high, _negated}, ctx), do: asked([inner, low, high], ctx)

  defp calls({:like, inner, pattern, _negated, _word, _escape}, ctx),
    do: asked([inner, pattern], ctx)

  defp calls(node, ctx), do: node |> SQLDmlExpr.children() |> Enum.flat_map(&calls(&1, ctx))

  # The calls of the operands the planner asks about, in order, up to the first that can be null.
  @spec asked([SQLDmlExpr.ast()], ctx()) :: [SQLDmlExpr.ast()]
  defp asked(operands, ctx) do
    {asked, _stopped} =
      Enum.reduce(operands, {[], false}, fn
        _operand, {asked, true} -> {asked, true}
        operand, {asked, false} -> {asked ++ calls(operand, ctx), nullable(operand, ctx) != false}
      end)

    asked
  end

  # ---------------------------------------------------------------------------
  # The type of an operand
  # ---------------------------------------------------------------------------

  @doc "The type of an operand, as far as the checks tell (`:unknown` when not)."
  @spec type_of(SQLDmlExpr.ast(), ctx()) :: type()
  def type_of({:num, text}, _ctx), do: number_type(text)

  def type_of({:str, _body}, _ctx), do: :str
  def type_of({:bool, _value}, _ctx), do: :bool
  def type_of(:null, _ctx), do: :null
  def type_of({:param, _text}, _ctx), do: :null
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
  def type_of({:ordered, call, _terms}, ctx), do: type_of(call, ctx)
  def type_of({:call, name, args}, ctx), do: call_type(name, args, ctx)
  def type_of(_other, _ctx), do: :unknown

  # A number is an `Int64`, a `UInt64` above the largest `Int64`, else a `Float64`.
  @spec number_type(binary()) :: type()
  defp number_type(text) do
    cond do
      not Regex.match?(~r/\A[0-9]+\z/, text) -> :float
      byte_size(text) < 19 -> :int
      true -> integer_type(String.to_integer(text))
    end
  end

  @spec integer_type(non_neg_integer()) :: type()
  defp integer_type(value) when value <= 9_223_372_036_854_775_807, do: :int
  defp integer_type(value) when value <= 18_446_744_073_709_551_615, do: :uint
  defp integer_type(_value), do: :float

  @spec arithmetic(type(), type()) :: type()
  defp arithmetic(:null, :null), do: :int
  defp arithmetic(:null, other) when other in @numeric, do: other
  defp arithmetic(other, :null) when other in @numeric, do: other

  # Two numbers of known types are the type of the engine's arithmetic on them
  # (`SQLNumber.result_type/2`, the one table of it); a number of a type the checks do not
  # track gives a number of none.
  defp arithmetic(left, right) when left in @exact and right in @exact do
    left |> arrow() |> SQLNumber.result_type(arrow(right)) |> from_arrow()
  end

  defp arithmetic(left, right) when left in @numeric and right in @numeric, do: :num
  defp arithmetic(_left, _right), do: :unknown

  # The Arrow type of each type of the checks that has a name the engine's tables know.
  @spec arrow(type()) :: binary()
  defp arrow(:int), do: "Int64"
  defp arrow(:uint), do: "UInt64"
  defp arrow(:float), do: "Float64"
  defp arrow(:decimal), do: "Decimal128(?)"

  @spec from_arrow(binary()) :: type()
  defp from_arrow("Int64"), do: :int
  defp from_arrow("UInt64"), do: :uint
  defp from_arrow("Float64"), do: :float
  defp from_arrow(_decimal), do: :decimal

  @spec call_type(binary(), [SQLDmlExpr.ast()] | :star, ctx()) :: type()
  defp call_type(name, _args, _ctx) when name in @now, do: :time

  defp call_type("abs", [arg], ctx) do
    case type_of(arg, ctx) do
      :null -> :float
      type -> type
    end
  end

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
      several -> several_types(several)
    end
  end

  defp call_type(name, _args, _ctx) when name in ~w(sum avg median stddev var), do: :num
  defp call_type(_name, _args, _ctx), do: :unknown

  # The type of the result of a function over arguments of several types: numbers of known types
  # are folded as the engine folds them (`SQLCommonType.planned/2`).
  @spec several_types([type()]) :: type()
  defp several_types(types) do
    cond do
      Enum.all?(types, &(&1 in @exact)) ->
        case types |> Enum.map(&arrow/1) |> SQLCommonType.planned(:coalesce) do
          folded when is_binary(folded) -> from_arrow(folded)
          _unfolded -> :num
        end

      Enum.all?(types, &(&1 in @numeric)) ->
        :num

      true ->
        :unknown
    end
  end

  @spec column_type(binary() | nil) :: type()
  defp column_type("Int64"), do: :int
  defp column_type("UInt64"), do: :uint
  defp column_type("Float64"), do: :float
  defp column_type("Boolean"), do: :bool
  defp column_type("Timestamp(ns)"), do: :time
  defp column_type(type) when type in ["Utf8", "Dictionary(Int32, Utf8)"], do: :str
  defp column_type(_type), do: :unknown

  @spec cast_type(SQLDmlType.t()) :: type()
  defp cast_type(%{family: :timestamp}), do: :time
  defp cast_type(%{family: family}), do: family
end
