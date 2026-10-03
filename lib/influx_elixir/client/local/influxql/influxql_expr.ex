defmodule InfluxElixir.Client.Local.InfluxQLExpr do
  @moduledoc false
  # Arithmetic in the select list of an InfluxQL `SELECT`, as the engine reads
  # and computes it (verified):
  #
  #   * `+ - * / %`, signs, parentheses, numbers, fields, tags, aggregates
  #     (`sum(n) + 1`) and `field::float` / `field::integer`; `x::type` binds to
  #     the name only, a double sign (`- -n`) and `&`, `|`, `^` are not read
  #   * a column is named by the names in it joined by `_` (`usage + 1` is
  #     `usage`, `usage + n` is `usage_n`, `sum(n) * mean(n)` is `sum_mean`),
  #     then numbered like any other name
  #   * the types are the fields': a signed integer, an unsigned one (it wraps
  #     at 2^64, a negative literal beside it is `2^64 + n - 1`), a float.
  #     `+ - *` on two integers wrap at 64 bits; `/` of two signed integers is
  #     a float division, of two unsigned ones an integer division; `%` is the
  #     remainder with the sign of the dividend; a division by zero is zero;
  #     a float beside an integer makes the operation a float one
  #   * a row of a plain select is kept when a field the list names is in it,
  #     whatever the expression comes to there; the expression of an aggregate
  #     is computed over the aggregates after `fill()` has filled them
  #   * an integer field beside an unsigned one is the planning error `cannot
  #     use + between an integer and unsigned, an explicit cast is required`; a
  #     tag or a string in arithmetic is `incompatible operands for operator +:
  #     tag and integer`
  #   * what the double does not reproduce is refused by name: a remainder or a
  #     division by a zero it only finds in the data, a negative fraction cast
  #     to an integer, an unsigned cast, an expression of constants alone

  alias InfluxElixir.Client.Local.{InfluxQLAggregate, InfluxQLError, SQLLimits}

  require SQLLimits

  @typedoc "An expression."
  @type ast ::
          {:lit, {:int, integer()} | {:float, float()}}
          | {:str, binary()}
          | {:ref, binary()}
          | {:cast, binary(), :float | :integer}
          | {:agg, binary(), binary()}
          | {:neg, ast()}
          | {:bin, binary(), ast(), ast()}

  @aggregates ~w(mean sum count min max first last median spread stddev)

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  @doc """
  Reads the text of a select item as an expression (without its alias):
  `{:ok, ast}`, or `:error` for what is not arithmetic the double reads.
  """
  @spec parse(binary()) :: {:ok, ast()} | :error
  def parse(text) do
    with {:ok, tokens} <- tokenize(text, []),
         {:ok, ast, []} <- sum(tokens) do
      {:ok, ast}
    else
      _unread -> :error
    end
  end

  @spec tokenize(binary(), list()) :: {:ok, list()} | :error
  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r], do: tokenize(rest, acc)

  defp tokenize(<<c, rest::binary>>, acc) when c in [?+, ?-, ?*, ?/, ?%, ?(, ?), ?,],
    do: tokenize(rest, [{:op, <<c>>} | acc])

  defp tokenize(<<?', _rest::binary>> = text, acc) do
    case Regex.run(~r/^'((?:[^'\\]|\\.)*)'/s, text) do
      [all, content] -> tokenize(rest_after(text, all), [{:str, content} | acc])
      nil -> :error
    end
  end

  defp tokenize(text, acc) do
    cond do
      match = Regex.run(~r/^(?:\d+\.\d+|\.\d+|\d+)(?![\w.])/, text) ->
        tokenize(rest_after(text, hd(match)), [{:number, hd(match)} | acc])

      match = Regex.run(~r/^("(?:[^"\\]|\\.)+"|[A-Za-z_][\w.]*)(?:::(float|integer))?/, text) ->
        [all, name | cast] = match
        tokenize(rest_after(text, all), [{:name, unquote_name(name), List.first(cast)} | acc])

      true ->
        :error
    end
  end

  defp rest_after(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  defp unquote_name("\"" <> _rest = quoted),
    do: quoted |> String.trim("\"") |> String.replace("\\\"", "\"")

  defp unquote_name(name), do: name

  @spec sum(list()) :: {:ok, ast(), list()} | :error
  defp sum(tokens) do
    with {:ok, left, rest} <- product(tokens), do: more(rest, left, ["+", "-"], &product/1)
  end

  @spec product(list()) :: {:ok, ast(), list()} | :error
  defp product(tokens) do
    with {:ok, left, rest} <- unary(tokens), do: more(rest, left, ["*", "/", "%"], &unary/1)
  end

  defp more([{:op, op} | rest] = tokens, left, ops, next) do
    if op in ops do
      with {:ok, right, after_right} <- next.(rest),
           do: more(after_right, {:bin, op, left, right}, ops, next)
    else
      {:ok, left, tokens}
    end
  end

  defp more(tokens, left, _ops, _next), do: {:ok, left, tokens}

  # One sign, then what it applies to (`- -n` is the engine's parse error).
  @spec unary(list()) :: {:ok, ast(), list()} | :error
  defp unary([{:op, "-"}, {:number, text} | rest]), do: literal(text, -1, rest)

  defp unary([{:op, "-"} | rest]) do
    with {:ok, operand, after_operand} <- atom(rest), do: {:ok, {:neg, operand}, after_operand}
  end

  defp unary([{:op, "+"} | rest]), do: atom(rest)
  defp unary(tokens), do: atom(tokens)

  @spec atom(list()) :: {:ok, ast(), list()} | :error
  defp atom([{:number, text} | rest]), do: literal(text, 1, rest)
  defp atom([{:str, content} | rest]), do: {:ok, {:str, content}, rest}

  defp atom([{:op, "("} | rest]) do
    case sum(rest) do
      {:ok, ast, [{:op, ")"} | after_group]} -> {:ok, ast, after_group}
      _unbalanced -> :error
    end
  end

  defp atom([{:name, name, nil}, {:op, "("}, {:name, arg, nil}, {:op, ")"} | rest])
       when is_binary(name) do
    if String.downcase(name) in @aggregates,
      do: {:ok, {:agg, String.downcase(name), arg}, rest},
      else: :error
  end

  defp atom([{:name, name, nil} | rest]), do: {:ok, {:ref, name}, rest}
  defp atom([{:name, name, cast} | rest]), do: {:ok, {:cast, name, cast_type(cast)}, rest}
  defp atom(_tokens), do: :error

  defp cast_type("float"), do: :float
  defp cast_type("integer"), do: :integer

  defp literal(text, sign, rest) do
    if String.contains?(text, "."),
      do: {:ok, {:lit, {:float, sign * String.to_float(float_text(text))}}, rest},
      else: integer_literal(String.to_integer(text), sign, rest)
  end

  defp integer_literal(n, sign, rest) when n <= SQLLimits.int64_max(),
    do: {:ok, {:lit, {:int, sign * n}}, rest}

  defp integer_literal(_n, _sign, _rest), do: :error

  defp float_text("." <> _fraction = text), do: "0" <> text
  defp float_text(text), do: text

  # ---------------------------------------------------------------------------
  # What an expression is made of
  # ---------------------------------------------------------------------------

  @doc "The column name the engine gives an expression: the names in it joined by `_`."
  @spec name(ast()) :: binary() | nil
  def name(ast) do
    case ast |> names() |> Enum.reject(&is_nil/1) do
      [] -> nil
      names -> Enum.join(names, "_")
    end
  end

  defp names({:ref, name}), do: [name]
  defp names({:cast, name, _type}), do: [name]
  defp names({:agg, fun, _arg}), do: [fun]
  defp names({:neg, operand}), do: names(operand)
  defp names({:bin, _op, left, right}), do: names(left) ++ names(right)
  defp names(_literal), do: []

  @doc "The fields (and tags) an expression reads."
  @spec refs(ast()) :: [binary()]
  def refs({:ref, name}), do: [name]
  def refs({:cast, name, _type}), do: [name]
  def refs({:neg, operand}), do: refs(operand)
  def refs({:bin, _op, left, right}), do: refs(left) ++ refs(right)
  def refs(_other), do: []

  @doc "The aggregates an expression holds, as `{fun, argument}`."
  @spec aggregates(ast()) :: [{binary(), binary()}]
  def aggregates({:agg, fun, arg}), do: [{fun, arg}]
  def aggregates({:neg, operand}), do: aggregates(operand)
  def aggregates({:bin, _op, left, right}), do: aggregates(left) ++ aggregates(right)
  def aggregates(_other), do: []

  @doc """
  The expression with each aggregate replaced by a reference to the column
  `key.(fun, arg)` names.
  """
  @spec hoist(ast(), ({binary(), binary()} -> binary())) :: ast()
  def hoist({:agg, fun, arg}, key), do: {:ref, key.({fun, arg})}
  def hoist({:neg, operand}, key), do: {:neg, hoist(operand, key)}
  def hoist({:bin, op, left, right}, key), do: {:bin, op, hoist(left, key), hoist(right, key)}
  def hoist(other, _key), do: other

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @typedoc "What an operand is: its type, and whether it is a literal."
  @type type :: {:integer | :unsigned | :float | :string | :tag | :boolean | :unknown, boolean()}

  @doc """
  The engine's planning error for the first operation of `ast` it cannot
  type, `:ok` when there is none. `types` is the type of each field, `tags`
  the tag columns.
  """
  @spec check(ast(), %{binary() => atom()}, MapSet.t(binary())) ::
          :ok | {:error, {:engine, binary()} | binary()}
  def check(ast, types, tags) do
    case infer(ast, types, tags) do
      {:engine, body} -> {:error, {:engine, body}}
      {:refuse, message} -> {:error, "unsupported InfluxQL (#{message})"}
      {:ok, _type} -> :ok
    end
  end

  @typep inferred :: {:ok, type()} | {:engine, binary()} | {:refuse, binary()}

  @spec infer(ast(), map(), MapSet.t(binary())) :: inferred()
  defp infer({:lit, {:int, _n}}, _types, _tags), do: {:ok, {:integer, true}}
  defp infer({:lit, {:float, _x}}, _types, _tags), do: {:ok, {:float, true}}
  defp infer({:str, _content}, _types, _tags), do: {:ok, {:string, true}}

  defp infer({:ref, name}, types, tags) do
    cond do
      MapSet.member?(tags, name) -> {:ok, {:tag, false}}
      Map.has_key?(types, name) -> {:ok, {Map.fetch!(types, name), false}}
      true -> {:ok, {:unknown, false}}
    end
  end

  defp infer({:cast, name, :float}, types, tags) do
    with {:ok, {type, _literal}} <- infer({:ref, name}, types, tags),
         do: cast_type_of(type, :float)
  end

  defp infer({:cast, name, :integer}, types, tags) do
    with {:ok, {type, _literal}} <- infer({:ref, name}, types, tags),
         do: cast_type_of(type, :integer)
  end

  defp infer({:agg, fun, arg}, types, _tags) do
    {:ok, {aggregate_type(fun, Map.get(types, arg)), false}}
  end

  defp infer({:neg, operand}, types, tags),
    do: infer({:bin, "*", {:lit, {:int, -1}}, operand}, types, tags)

  defp infer({:bin, op, left, right}, types, tags) do
    with {:ok, l} <- infer(left, types, tags),
         {:ok, r} <- infer(right, types, tags) do
      operation(op, l, r)
    end
  end

  defp cast_type_of(type, target) when type in [:integer, :float, :unknown],
    do: {:ok, {target_type(type, target), false}}

  defp cast_type_of(type, target), do: {:refuse, "a #{type} field cast to #{target}"}

  defp target_type(:unknown, _target), do: :unknown
  defp target_type(_type, target), do: target

  defp aggregate_type("count", _type), do: :integer
  defp aggregate_type(fun, _type) when fun in ["mean", "stddev"], do: :float
  defp aggregate_type(_fun, nil), do: :unknown
  defp aggregate_type(_fun, type), do: type

  @spec operation(binary(), type(), type()) :: inferred()
  defp operation(op, {lt, _ll} = l, {rt, _rl} = r) do
    cond do
      lt == :boolean or rt == :boolean ->
        {:refuse, "a boolean in arithmetic"}

      lt in [:tag, :string] or rt in [:tag, :string] ->
        {:engine, incompatible(op, lt, rt)}

      {lt, rt} in [{:integer, :unsigned}, {:unsigned, :integer}] and not literal?(l, r) ->
        {:engine,
         "Error during planning: cannot use #{op} between an integer and unsigned, " <>
           "an explicit cast is required"}

      true ->
        {:ok, result(op, l, r)}
    end
  end

  defp literal?({_lt, left}, {_rt, right}), do: left or right

  defp incompatible(op, left, right) do
    InfluxQLError.expand_error(
      "incompatible operands for operator #{op}: #{type_name(left)} and #{type_name(right)}"
    )
  end

  defp type_name(type), do: Atom.to_string(type)

  defp result(_op, {:unknown, _l}, _right), do: {:unknown, false}
  defp result(_op, _left, {:unknown, _r}), do: {:unknown, false}
  defp result(_op, {:float, _l}, _right), do: {:float, false}
  defp result(_op, _left, {:float, _r}), do: {:float, false}
  defp result("/", {:integer, _l}, {:integer, _r}), do: {:float, false}
  defp result(_op, {:unsigned, _l}, _right), do: {:unsigned, false}
  defp result(_op, _left, {:unsigned, _r}), do: {:unsigned, false}
  defp result(_op, _left, _right), do: {:integer, false}

  # ---------------------------------------------------------------------------
  # Computing
  # ---------------------------------------------------------------------------

  @two64 18_446_744_073_709_551_616

  @typedoc "A value: a signed or unsigned integer, a float, or null."
  @type value :: {:int, integer()} | {:uint, non_neg_integer()} | {:float, float()} | nil

  @doc """
  The value of `ast` over a row (`env`: name to value); `nil` for null.
  Throws `{:refused, message}` for what the double does not reproduce.
  """
  @spec eval(ast(), map(), map()) :: number() | nil
  def eval(ast, env, types) do
    case value(ast, env, types) do
      nil -> nil
      {_kind, number} -> number
    end
  end

  @spec value(ast(), map(), map()) :: value()
  defp value({:lit, {:int, n}}, _env, _types), do: {:int, n}
  defp value({:lit, {:float, x}}, _env, _types), do: {:float, x}
  defp value({:ref, name}, env, types), do: typed(Map.get(types, name), Map.get(env, name))
  defp value({:cast, name, target}, env, types), do: cast(name, target, env, types)

  defp value({:neg, operand}, env, types),
    do: value({:bin, "*", operand, {:lit, {:int, -1}}}, env, types)

  defp value({:bin, op, left, right}, env, types),
    do: apply_op(op, value(left, env, types), value(right, env, types))

  defp typed(:integer, n) when is_integer(n), do: {:int, n}
  defp typed(:unsigned, n) when is_integer(n), do: {:uint, n}
  defp typed(:float, x) when is_number(x), do: {:float, x * 1.0}
  defp typed(_type, _value), do: nil

  defp cast(name, :float, env, types) do
    case value({:ref, name}, env, types) do
      nil -> nil
      {_kind, n} -> {:float, n * 1.0}
    end
  end

  defp cast(name, :integer, env, types) do
    case value({:ref, name}, env, types) do
      nil -> nil
      {:int, n} -> {:int, n}
      {:float, x} -> {:int, truncate(x)}
      {:uint, _n} -> throw({:refused, "unsupported InfluxQL (an unsigned field cast to integer)"})
    end
  end

  defp truncate(x) when x >= 0 or x == trunc(x) * 1.0, do: trunc(x)

  defp truncate(_negative_fraction),
    do: throw({:refused, "unsupported InfluxQL (a negative fraction cast to integer)"})

  @spec apply_op(binary(), value(), value()) :: value()
  defp apply_op(_op, nil, _right), do: nil
  defp apply_op(_op, _left, nil), do: nil

  defp apply_op(op, left, right) do
    case common(left, right) do
      {:float, x, y} -> float_op(op, x, y)
      {:uint, x, y} -> uint_op(op, x, y)
      {:int, x, y} -> int_op(op, x, y)
    end
  end

  # The type both are taken to: a float with a number makes floats, an unsigned
  # with a signed literal an unsigned (a negative one as `2^64 + n - 1`).
  defp common({:float, x}, {_kind, y}), do: {:float, x, y * 1.0}
  defp common({_kind, x}, {:float, y}), do: {:float, x * 1.0, y}
  defp common({:int, x}, {:int, y}), do: {:int, x, y}
  defp common({:uint, x}, {:uint, y}), do: {:uint, x, y}
  defp common({:uint, x}, {:int, y}), do: {:uint, x, to_unsigned(y)}
  defp common({:int, x}, {:uint, y}), do: {:uint, to_unsigned(x), y}

  defp to_unsigned(n) when n >= 0, do: n
  defp to_unsigned(n), do: @two64 + n - 1

  defp int_op("/", x, y), do: float_op("/", x * 1.0, y * 1.0)
  defp int_op("%", _x, 0), do: refuse_remainder()
  defp int_op("%", x, y), do: {:int, SQLLimits.wrap_int64(rem(x, y))}
  defp int_op(op, x, y), do: {:int, SQLLimits.wrap_int64(arith(op, x, y))}

  defp uint_op("/", _x, 0), do: {:uint, 0}
  defp uint_op("/", x, y), do: {:uint, div(x, y)}
  defp uint_op("%", _x, 0), do: refuse_remainder()
  defp uint_op("%", x, y), do: {:uint, rem(x, y)}
  defp uint_op(op, x, y), do: {:uint, SQLLimits.wrap_uint64(arith(op, x, y))}

  defp float_op("/", _x, y) when y == 0.0, do: {:float, 0.0}
  defp float_op("%", _x, y) when y == 0.0, do: refuse_remainder()

  defp float_op(op, x, y) do
    {:float, float_arith(op, x, y)}
  rescue
    ArithmeticError -> nil
  end

  @spec refuse_remainder() :: no_return()
  defp refuse_remainder, do: throw({:refused, "unsupported InfluxQL (a remainder by zero)"})

  defp arith("+", x, y), do: x + y
  defp arith("-", x, y), do: x - y
  defp arith("*", x, y), do: x * y

  defp float_arith("%", x, y), do: :math.fmod(x, y)
  defp float_arith("/", x, y), do: x / y
  defp float_arith(op, x, y), do: arith(op, x, y)

  @doc "The aggregates a function name may take in an expression."
  @spec aggregate_function?(binary()) :: boolean()
  def aggregate_function?(fun), do: fun in @aggregates and InfluxQLAggregate.function?(fun)
end
