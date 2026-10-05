defmodule InfluxElixir.Client.Local.SQLScalarCheck do
  @moduledoc false
  # The planning errors of a call of one of the functions of
  # `InfluxElixir.Client.Local.SQLScalar`, given the Arrow types of its
  # arguments (`nil` where unknown, which is never refused), as InfluxDB 3
  # Core words them (verified): the wrong number of arguments, and an argument
  # of a type the function does not take. A type the double cannot word the
  # error of is refused by name.
  #
  # Where the call stands changes the message, as for
  # `InfluxElixir.Client.Local.SQLFunctions`: in the select list it carries
  # the planner's prefix, in `WHERE` the type coercion's, and under a `CAST`,
  # `IS NULL`, `ORDER BY` and the like it is cut after its first sentence; an
  # error the engine words as an internal or an execution error is then a 500
  # without the planner's prefix.

  alias InfluxElixir.Client.Local.{
    SQLCommonType,
    SQLError,
    SQLFunctions,
    SQLNativeType
  }

  @text "Coercion(TypeSignatureClass::Native(LogicalType(Native(String), String)))"
  @internal_tail "\nThis issue was likely caused by a bug in DataFusion's code. Please help us " <>
                   "to resolve this by filing a bug report in our issue tracker: " <>
                   "https://github.com/apache/datafusion/issues"
  @log_candidates [
    "log(Coercion(TypeSignatureClass::Decimal))",
    "log(Coercion(TypeSignatureClass::Float, implicit_coercion=ImplicitCoercion([Numeric], default_type=Float64))",
    "log(Coercion(TypeSignatureClass::Float, implicit_coercion=ImplicitCoercion([Numeric], default_type=Float64), Coercion(TypeSignatureClass::Decimal))",
    "log(Coercion(TypeSignatureClass::Float, implicit_coercion=ImplicitCoercion([Numeric], default_type=Float64), Coercion(TypeSignatureClass::Float, implicit_coercion=ImplicitCoercion([Numeric], default_type=Float64))"
  ]
  @bug "This issue was likely caused by a bug in DataFusion's code. Please help us to resolve " <>
         "this by filing a bug report in our issue tracker: https://github.com/apache/datafusion/issues"
  @numbers ["Int64", "Int32", "Int16", "Int8", "UInt64", "Float64"]
  @integer_arguments ["Int64", "Int32", "Int16", "Int8"]
  @integers ["Int64", "Int32", "Int16", "Int8", "UInt64"]
  @text_types ["Utf8", "Utf8View", "Dictionary(Int32, Utf8)"]
  @shown_types ["Int64", "Float64", "Boolean", "Utf8", "Dictionary(Int32, Utf8)"]

  @typedoc "Where a call stands (see `InfluxElixir.Client.Local.SQLFunctions.context/0`)."
  @type context :: SQLFunctions.context()

  @doc """
  `:ok`, or the engine's planning error for a call with arguments of these types. `nulls`
  says which arguments are the null whatever the rows (see
  `InfluxElixir.Client.Local.SQLNullType.null_valued?/1`): a call with one is null, and what
  the double cannot compute of the other arguments' types (a timestamp's text, a narrow
  integer's coercion) is not asked of it.
  """
  @spec check(atom(), [binary() | nil], context(), [boolean()]) :: :ok | {:error, map()}
  def check(name, types, context, nulls \\ []) do
    case problem(name, types, nulls) do
      :ok ->
        :ok

      {:refuse, why} ->
        {:error, SQLError.refusal(why)}

      {:late, reason} ->
        {:error, SQLError.late_refusal(reason)}

      {:convert, type} ->
        {:error, SQLError.coercion("Cannot automatically convert #{type} to Utf8")}

      {kind, head, shown, candidates} ->
        {:error, error(kind, head, shown, types, candidates, context)}
    end
  end

  # What is wrong with a call: `:ok`, a refusal, or the engine's head (with its
  # kind, the function it names and its candidate signatures).
  @spec problem(atom(), [binary() | nil], [boolean()]) :: problem()
  defp problem(name, types, nulls) do
    cond do
      null_slice?(name, types, nulls) -> :ok
      null_math?(name, types, nulls) -> :ok
      true -> problem(name, types)
    end
  end

  # `left(time, NULL + NULL)`: the null count makes the text of the timestamp unneeded.
  @spec null_slice?(atom(), [binary() | nil], [boolean()]) :: boolean()
  defp null_slice?(name, ["Timestamp(ns)", count], [_first, true]) when name in [:left, :right],
    do: count in @integer_arguments or count == "Null"

  defp null_slice?(_name, _types, _nulls), do: false

  # `pow(CAST(NULL AS INT), NULL)`: a null whatever the integers' coercion would be.
  @spec null_math?(atom(), [binary() | nil], [boolean()]) :: boolean()
  defp null_math?(name, types, nulls) when name in [:pow, :power, :log] do
    Enum.any?(nulls) and types != [] and Enum.all?(types, &(&1 in ["Null" | @numbers]))
  end

  defp null_math?(_name, _types, _nulls), do: false

  @spec problem(atom(), [binary() | nil]) :: problem()
  defp problem(name, []) when name in [:greatest, :least] do
    {:execution,
     "Function '#{name}' user-defined coercion failed with \"Error during planning: #{name} was " <>
       "called without any arguments. It requires at least 1.\"", Atom.to_string(name),
     "#{name}(UserDefined)"}
  end

  defp problem(name, []) when name in [:lower, :upper, :starts_with],
    do:
      {:planning, "'#{name}' does not support zero arguments", Atom.to_string(name),
       text_candidate(name)}

  defp problem(:length, []),
    do:
      {:planning, "'character_length' does not support zero arguments", "character_length",
       length_candidate()}

  defp problem(name, []) when name in [:left, :right],
    do:
      {:planning, "'#{name}' does not support zero arguments", Atom.to_string(name),
       slice_candidates(name)}

  defp problem(name, []) when name in [:sqrt, :ln],
    do:
      {:planning, "'#{name}' does not support zero arguments", Atom.to_string(name),
       "#{name}(Float64/Float32)"}

  defp problem(name, []) when name in [:pow, :power],
    do: {:planning, "'power' does not support zero arguments", "power", power_candidates()}

  defp problem(:log, []),
    do:
      {:planning, "'log' does not support zero arguments", "log",
       Enum.join(@log_candidates, "\n\t")}

  defp problem(:substr, types), do: substr_problem(types)

  defp problem(name, types) do
    if Enum.any?(types, &is_nil/1), do: unknown(name, types), else: typed_problem(name, types)
  end

  # The wrong number of arguments of a call whose types are not all known
  # cannot be worded.
  @spec unknown(atom(), [binary() | nil]) :: :ok | {:refuse, binary()}
  defp unknown(name, types) do
    if arity_ok?(name, length(types)),
      do: :ok,
      else: {:refuse, "a call of #{name} with that many arguments, some of unknown type"}
  end

  @spec arity_ok?(atom(), non_neg_integer()) :: boolean()
  defp arity_ok?(name, count) when name in [:lower, :upper, :length, :sqrt, :ln], do: count == 1

  defp arity_ok?(name, count) when name in [:starts_with, :pow, :power, :left, :right],
    do: count == 2

  defp arity_ok?(:log, count), do: count in [1, 2]
  defp arity_ok?(_name, _count), do: true

  @typep problem ::
           :ok
           | {:refuse, binary()}
           | {:late, SQLError.late_reason()}
           | {:convert, binary()}
           | {:planning | :matching | :internal | :execution, binary(), binary(), binary()}

  @spec typed_problem(atom(), [binary()]) :: problem()
  defp typed_problem(name, types) when name in [:lower, :upper, :starts_with, :left, :right],
    do: text_problem(name, types)

  defp typed_problem(:length, types), do: length_problem(types)

  defp typed_problem(name, types) when name in [:sqrt, :ln, :pow, :power, :log],
    do: math_problem(name, types)

  defp typed_problem(name, types) when name in [:greatest, :least] do
    typed = Enum.reject(types, &(&1 == "Null"))

    cond do
      length(typed) < 2 ->
        :ok

      SQLCommonType.number_with_text?(typed) ->
        {:late, {:number_and_text, name}}

      SQLCommonType.common(typed, :coalesce) == :mixed and SQLCommonType.numbers?(typed) ->
        {:late, {:numbers_not_combined, name}}

      SQLCommonType.common(typed, :coalesce) == :mixed ->
        {:refuse, "#{name} of arguments with no common type the double models"}

      true ->
        :ok
    end
  end

  @spec text_problem(atom(), [binary()]) :: problem()
  defp text_problem(name, types) when name in [:lower, :upper] do
    if length(types) != 1 do
      {:planning, "Function '#{name}' expects 1 arguments but received #{length(types)}",
       Atom.to_string(name), text_candidate(name)}
    else
      text_arguments(name, types)
    end
  end

  defp text_problem(:starts_with, types) do
    if length(types) == 2,
      do: text_arguments(:starts_with, types),
      else:
        {:planning, "Function 'starts_with' expects 2 arguments but received #{length(types)}",
         "starts_with", text_candidate(:starts_with)}
  end

  # `left` and `right` take anything cast to text and an integer of 64 bits or fewer.
  defp text_problem(name, [first, count]) when name in [:left, :right] do
    cond do
      SQLNativeType.struct?(first) and (count in @integer_arguments or count == "Null") ->
        {:convert, first}

      first == "Timestamp(ns)" and count == "Null" ->
        :ok

      first == "Timestamp(ns)" ->
        {:refuse,
         "#{name} of a timestamp: the engine writes its nanoseconds as text, which the " <>
           "double keeps only to the microsecond"}

      count in @integer_arguments or count == "Null" ->
        :ok

      true ->
        slice_failure(name, [first, count])
    end
  end

  defp text_problem(name, types) when name in [:left, :right], do: slice_failure(name, types)

  @spec length_problem([binary()]) :: problem()
  defp length_problem(["Timestamp(ns)"]),
    do:
      {:refuse,
       "length of a timestamp: the engine writes its nanoseconds as text, which the double " <>
         "keeps only to the microsecond"}

  defp length_problem([type]) do
    if SQLNativeType.struct?(type), do: {:convert, type}, else: :ok
  end

  defp length_problem(types) do
    {:planning,
     "Failed to coerce arguments to satisfy a call to 'character_length' function: coercion " <>
       "from #{Enum.join(types, ", ")} to the signature Uniform(1, [Utf8, LargeUtf8, Utf8View]) " <>
       "failed", "character_length", length_candidate()}
  end

  @spec math_problem(atom(), [binary()]) :: problem()
  defp math_problem(name, types) when name in [:sqrt, :ln] do
    if length(types) == 1 and hd(types) in ["Null" | @numbers] do
      :ok
    else
      {:planning,
       "Failed to coerce arguments to satisfy a call to '#{name}' function: coercion from " <>
         "#{Enum.join(types, ", ")} to the signature Uniform(1, [Float64, Float32]) failed",
       Atom.to_string(name), "#{name}(Float64/Float32)"}
    end
  end

  defp math_problem(name, types) when name in [:pow, :power] do
    cond do
      "UInt64" in types or Enum.any?(types, &(&1 in ["Int32", "Int16", "Int8"])) ->
        {:refuse,
         "pow of an unsigned or narrow integer: the engine's coercion for it is not modelled"}

      length(types) == 2 and Enum.all?(types, &(&1 in ["Null", "Int64", "Float64"])) ->
        :ok

      true ->
        {:planning,
         "Failed to coerce arguments to satisfy a call to 'power' function: coercion from " <>
           "#{Enum.join(types, ", ")} to the signature OneOf([Exact([Int64, Int64]), " <>
           "Exact([Float64, Float64])]) failed", "power", power_candidates()}
    end
  end

  defp math_problem(:log, types) do
    cond do
      length(types) in [1, 2] and Enum.all?(types, &(&1 in ["Null", "Int64", "Float64"])) ->
        :ok

      length(types) > 2 ->
        log_failure(types, arity_errors(types))

      Enum.any?(types, &(&1 in ["UInt64", "Int32", "Int16", "Int8"])) ->
        {:refuse,
         "log of an unsigned or narrow integer: the engine's coercion for it is not modelled"}

      true ->
        log_text_failure(types)
    end
  end

  # `log` of a text, a boolean or a timestamp: the engine tries each of its four signatures, and
  # the message lists why each failed (verified against Core, each type in each place).
  @spec log_text_failure([binary()]) :: problem()
  defp log_text_failure(types) do
    case Enum.find(types, &(&1 not in ["Null" | @numbers] and native(&1) == nil)) do
      nil ->
        log_failure(types, signature_errors(types))

      other ->
        {:refuse,
         "log of an argument of the type #{other}: the engine's error for it is not modelled"}
    end
  end

  # The errors of the signatures for one and for two arguments.
  @spec signature_errors([binary()]) :: [binary()]
  defp signature_errors([only]) do
    [
      expectation("Decimal", only),
      expectation("Float", only),
      "Error during planning: Function 'log' expects 2 arguments but received 1",
      "Error during planning: Function 'log' expects 2 arguments but received 1"
    ]
  end

  defp signature_errors([base, value]) do
    wrong_count = "Error during planning: Function 'log' expects 1 arguments but received 2"

    [
      wrong_count,
      wrong_count,
      first_failure(base, value, "Decimal"),
      first_failure(base, value, "Float")
    ]
  end

  # A signature of two arguments fails at the first argument that does not satisfy it: the base is
  # a `Float` in both, the value a `Decimal` in the first and a `Float` in the second.
  @spec first_failure(binary(), binary(), binary()) :: binary()
  defp first_failure(base, value, value_class) do
    if base in ["Null" | @numbers],
      do: expectation(value_class, value),
      else: expectation("Float", base)
  end

  @spec arity_errors([binary()]) :: [binary()]
  defp arity_errors(types) do
    count = length(types)

    for expected <- [1, 1, 2, 2],
        do:
          "Error during planning: Function 'log' expects #{expected} arguments but received #{count}"
  end

  # `Internal error: Expect TypeSignatureClass::Float but received NativeType::String ...`.
  @spec expectation(binary(), binary()) :: binary()
  defp expectation(class, type) do
    "Internal error: Expect TypeSignatureClass::#{class} but received NativeType::" <>
      "#{native(type)}, DataType: #{type}.\n#{@bug}"
  end

  @spec native(binary()) :: binary() | nil
  defp native(type) when type in ["Utf8", "Utf8View", "Dictionary(Int32, Utf8)"], do: "String"
  defp native("Boolean"), do: "Boolean"
  defp native("Timestamp(ns)"), do: "Timestamp(Nanosecond, None)"
  defp native(_type), do: nil

  @spec log_failure([binary()], [binary()]) :: problem()
  defp log_failure(_types, errors) do
    {:matching,
     "Internal error: Function 'log' failed to match any signature, errors: " <>
       Enum.join(errors, ",") <> ".\n" <> @bug, "log", Enum.join(@log_candidates, "\n\t")}
  end

  # An argument of a type that is not text, for a function of text.
  @spec text_arguments(atom(), [binary()]) ::
          :ok | {:refuse, binary()} | {:internal, binary(), binary(), binary()}
  defp text_arguments(name, types) do
    case Enum.find(types, &(&1 not in ["Null" | @text_types])) do
      nil ->
        :ok

      type when type in @shown_types ->
        internal_text(name, type)

      type ->
        if SQLNativeType.struct?(type),
          do: internal_text(name, type),
          else: {:refuse, "#{name} of a #{type}: the engine's error for it is not modelled"}
    end
  end

  @spec internal_text(atom(), binary()) :: {:internal, binary(), binary(), binary()}
  defp internal_text(name, type) do
    {:internal,
     "Expect TypeSignatureClass::Native(LogicalType(Native(String), String)) but received " <>
       "NativeType::#{SQLNativeType.native(type)}, DataType: #{type}.", Atom.to_string(name),
     text_candidate(name)}
  end

  @substr_candidate "substr(str, start_pos, length)"

  @spec substr_problem([binary() | nil]) ::
          :ok | {:refuse, binary()} | {:execution, binary(), binary(), binary()}
  defp substr_problem(types) do
    ordinal = ["first", "second", "third"]

    cond do
      length(types) == 1 ->
        {:refuse,
         "substr with one argument: the engine's error quotes the argument's position in " <>
           "the query, which is not modelled"}

      length(types) not in [2, 3] ->
        shown = if Enum.any?(types, &is_nil/1), do: nil, else: types

        substr_error(
          "The substr function requires 2 or 3 arguments, but got #{length(types)}.",
          shown
        )

      Enum.any?(types, &is_nil/1) ->
        :ok

      true ->
        types
        |> Enum.with_index()
        |> Enum.find_value(:ok, fn {type, index} ->
          substr_argument(type, index, ordinal, types)
        end)
    end
  end

  @spec substr_argument(binary(), non_neg_integer(), [binary()], [binary()]) ::
          nil | {:execution, binary(), binary(), binary()}
  defp substr_argument(type, 0, ordinal, types) do
    if type not in ["Null" | @text_types],
      do:
        substr_error(
          "The #{Enum.at(ordinal, 0)} argument of the substr function can only be a string, " <>
            "but got #{printed(type)}.",
          types
        )
  end

  defp substr_argument(type, index, ordinal, types) do
    if type not in ["Null" | @integers],
      do:
        substr_error(
          "The #{Enum.at(ordinal, index)} argument of the substr function can only be an " <>
            "integer, but got #{printed(type)}.",
          types
        )
  end

  # A timestamp is named by its native type in this message.
  @spec printed(binary()) :: binary()
  defp printed("Timestamp(ns)"), do: "Timestamp(Nanosecond, None)"

  # A selector's struct, as the arrow type is debug printed there.
  defp printed("Struct(" <> _fields = type) do
    case Regex.run(~r/\AStruct\("value": (.+), "time": Timestamp\(ns\)\)\z/, type) do
      [_all, value] ->
        ~S|Struct([Field { name: \"value\", data_type: | <>
          value <>
          ~S|, nullable: true }, Field { name: \"time\", data_type: | <>
          "Timestamp(Nanosecond, None), nullable: true }])"

      nil ->
        type
    end
  end

  defp printed(type), do: type

  @spec substr_error(binary(), [binary()] | nil) ::
          {:execution, binary(), binary(), binary()} | {:refuse, binary()}
  defp substr_error(_message, nil),
    do: {:refuse, "a call of substr with that many arguments, some of unknown type"}

  defp substr_error(message, _types) do
    {:execution,
     "Function 'substr' user-defined coercion failed with \"Error during planning: #{message}\"",
     "substr", @substr_candidate}
  end

  @spec slice_failure(atom(), [binary()]) :: {:planning, binary(), binary(), binary()}
  defp slice_failure(name, types) do
    {:planning,
     "Failed to coerce arguments to satisfy a call to '#{name}' function: coercion from " <>
       "#{Enum.join(types, ", ")} to the signature OneOf([Exact([Utf8View, Int64]), " <>
       "Exact([Utf8, Int64]), Exact([LargeUtf8, Int64])]) failed", Atom.to_string(name),
     slice_candidates(name)}
  end

  @spec slice_candidates(atom()) :: binary()
  defp slice_candidates(name),
    do: Enum.map_join(["Utf8View", "Utf8", "LargeUtf8"], "\n\t", &"#{name}(#{&1}, Int64)")

  @spec text_candidate(atom()) :: binary()
  defp text_candidate(:starts_with), do: "starts_with(#{@text}, #{@text})"
  defp text_candidate(name), do: "#{name}(#{@text})"

  @spec length_candidate() :: binary()
  defp length_candidate, do: "character_length(Utf8/LargeUtf8/Utf8View)"

  @spec power_candidates() :: binary()
  defp power_candidates, do: "power(Int64, Int64)\n\tpower(Float64, Float64)"

  # The error as the call stands.
  @spec error(
          :planning | :matching | :internal | :execution,
          binary(),
          binary(),
          [binary() | nil],
          binary(),
          context()
        ) :: map()
  defp error(kind, head, shown, types, candidates, context) do
    head = word(kind, head)

    tail =
      " No function matches the given name and argument types '#{shown}(#{Enum.join(types, ", ")})'. " <>
        "You might need to add explicit type casts.\n\tCandidate functions:\n\t" <> candidates

    case {context, types} do
      {:select, _types} -> SQLError.planning(head <> tail)
      {:where, _types} -> SQLError.coercion(head <> tail)
      {cut, []} when kind == :execution -> constant(head, tail, cut)
      {cut, _types} -> cut(kind, head, cut)
    end
  end

  # A call with no argument is a constant, which the engine folds before it
  # types anything: `ORDER BY` has the bare execution error, an `IS NULL` has
  # the optimizer report it.
  @spec constant(binary(), binary(), context()) :: map()
  defp constant(head, _tail, :order_by), do: %{status: 500, body: head}

  defp constant(head, tail, _context) do
    %{
      status: 400,
      body:
        "Optimizer rule 'simplify_expressions' failed\ncaused by\n" <>
          "Error during planning: " <> head <> tail
    }
  end

  @spec word(:planning | :matching | :internal | :execution, binary()) :: binary()
  defp word(:planning, head), do: head
  defp word(:matching, head), do: head
  defp word(:internal, head), do: "Internal error: " <> head <> @internal_tail
  defp word(:execution, head), do: "Execution error: " <> head

  # Under a `CAST`, an `ORDER BY` and the like the message is its first
  # sentence: a planning error keeps the planner's prefix, the others are a 500.
  @spec cut(:planning | :matching | :internal | :execution, binary(), context()) :: map()
  defp cut(:planning, head, _context), do: SQLError.coercion(head)

  defp cut(_kind, head, _context),
    do: %{status: 500, body: "type_coercion\ncaused by\n" <> head}
end
