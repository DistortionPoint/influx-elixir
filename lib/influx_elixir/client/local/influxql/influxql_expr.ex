defmodule InfluxElixir.Client.Local.InfluxQLExpr do
  @moduledoc false
  # Expressions in the select list of an InfluxQL `SELECT`, as the engine reads
  # and computes them (verified):
  #
  #   * `+ - * / %`, signs, parentheses, numbers, fields, tags, aggregates
  #     (`sum(n) + 1`), `field::float` / `field::integer`, the math functions
  #     (`abs round floor ceil sqrt ln log pow`) and the transforms of a field or an aggregate
  #     (`derivative(mean(f), 1m)`, see `InfluxQLTransform`); `x::type` binds
  #     to the name only, a double sign (`- -n`) and `&`, `|`, `^` are not read
  #   * a column is named by the names in it joined by `_` (`usage + 1` is
  #     `usage`, `usage + n` is `usage_n`, `sum(n) * mean(n)` is `sum_mean`, a
  #     call is its function's name whatever it holds), then numbered like any
  #     other name
  #   * the types are the fields': a signed integer, an unsigned one (it wraps
  #     at 2^64, a negative literal beside it is `2^64 + n - 1`), a float.
  #     `+ - *` on two integers wrap at 64 bits; `/` of two signed integers is
  #     a float division, of two unsigned ones an integer division; `%` is the
  #     remainder with the sign of the dividend; a division by zero is zero;
  #     a float beside an integer makes the operation a float one
  #   * `abs` keeps the type of its argument, `round floor ceil` and the rest
  #     answer floats, `pow` of an integer by a literal integer is an integer;
  #     a result that is not a finite number (the root of a negative, the
  #     logarithm of zero) is null, and unlike a missing value it is written:
  #     the column is in the row, with null in it
  #   * a row of a plain select is kept when a field the list names is in it,
  #     whatever the expression comes to there; the expression of an aggregate
  #     is computed over the aggregates after `fill()` has filled them
  #   * an integer field beside an unsigned one is the planning error `cannot
  #     use + between an integer and unsigned, an explicit cast is required`; a
  #     tag or a string in arithmetic is `incompatible operands for operator +:
  #     tag and integer`
  #   * what the double does not reproduce is refused by name: a remainder or a
  #     division by a zero it only finds in the data, a negative fraction cast
  #     to an integer, an unsigned cast, an expression of constants alone, a
  #     math function of a string, a boolean or an unsigned field

  alias InfluxElixir.Client.Local.{
    Durations,
    InfluxQLError,
    InfluxQLKernel,
    InfluxQLLiteral,
    InfluxQLText,
    SQLLimits
  }

  require SQLLimits

  @typedoc "An expression."
  @type ast ::
          {:lit, {:int, integer()} | {:float, float()}}
          | {:str, binary()}
          | {:bool, boolean()}
          | {:ref, binary()}
          | {:cast, binary(), :float | :integer}
          | {:agg, binary(), binary()}
          | {:fn, binary(), [ast()]}
          | {:transform, binary(), ast(), integer() | nil}
          | {:neg, ast()}
          | {:bin, binary(), ast(), ast()}

  @aggregates ~w(mean sum count min max first last median spread stddev mode)
  @transforms ~w(derivative non_negative_derivative difference non_negative_difference
                 cumulative_sum moving_average elapsed)
  @field_functions @aggregates ++
                     ~w(percentile integral derivative non_negative_derivative difference
                        non_negative_difference cumulative_sum moving_average elapsed)
  @one_argument ~w(abs round floor ceil sqrt ln)
  @two_arguments ~w(log pow)
  @functions @one_argument ++ @two_arguments
  @wild_in_arithmetic "unsupported binary expression: contains a wildcard or regular expression"
  @wild_names @aggregates ++
                @transforms ++ @functions ++ ["percentile", "integral", "top", "bottom"]

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  @doc """
  Reads the text of a select item as an expression (without its alias):
  `{:ok, ast}`, `{:paren_constant, ast}` for one with a constant alone in a group (the
  engine's planning error, found once the operands are typed), `{:wild, name, arguments,
  target}` for a call with `*` or a
  regular expression for its field (`mean(*)`, `percentile(/re/, 90)`), or
  `:error` for what is not an expression the double reads.
  """
  @spec parse(binary()) ::
          {:ok, ast()}
          | {:paren_constant, ast()}
          | {:wild, binary(), [ast()], term()}
          | {:multi, binary(), binary(), [binary()], pos_integer()}
          | {:planning, binary()}
          | {:expand_error, binary()}
          | {:argument, binary(), term()}
          | :error
  def parse(text) do
    with {:ok, tokens} <- tokenize(text, []),
         {:ok, ast, []} <- sum(tokens),
         {:ok, classified} <- classify(ast) do
      if paren_constant?(ast), do: {:paren_constant, classified}, else: {:ok, classified}
    else
      {:wild, _name, _arguments, _target} = wild -> wild
      {:multi, _kind, _field, _tags, _limit} = multi -> multi
      {:planning, _message} = planning -> planning
      {:expand_error, _message} = error -> error
      {:argument, _name, _argument} = argument -> argument
      _unread -> :error
    end
  end

  @spec tokenize(binary(), list()) :: {:ok, list()} | :error
  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r], do: tokenize(rest, acc)

  defp tokenize(<<?*, rest::binary>>, acc)
       when acc == [] or hd(acc) in [{:op, "("}, {:op, ","}] do
    case Regex.run(~r/^::(field|tag)(?![\w:])/i, rest) do
      [all, kind] -> tokenize(rest_after(rest, all), [{:star, String.downcase(kind)} | acc])
      nil -> tokenize(rest, [{:star, nil} | acc])
    end
  end

  defp tokenize(<<?/, rest::binary>>, acc)
       when acc == [] or hd(acc) in [{:op, "("}, {:op, ","}] do
    case regex_end(rest, []) do
      {:ok, source, after_regex} -> tokenize(after_regex, [{:regex, source} | acc])
      :error -> :error
    end
  end

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
      match = Regex.run(~r/^(?:\d+(?:ns|ms|u|µ|s|m|h|d|w))+(?![\w.])/u, text) ->
        [all] = match
        duration(rest_after(text, all), duration_ns(all), acc)

      match = Regex.run(~r/^(?:\d+\.\d+|\.\d+|\d+)(?![\w.])/, text) ->
        tokenize(rest_after(text, hd(match)), [{:number, hd(match)} | acc])

      match = Regex.run(~r/^("(?:[^"\\]|\\.)+"|[A-Za-z_][\w.]*)(?:::(float|integer))?/, text) ->
        [all, name | cast] = match

        tokenize(rest_after(text, all), [name_token(name, List.first(cast)) | acc])

      true ->
        :error
    end
  end

  # An unquoted `true` or `false` is a boolean, a quoted one a name.
  defp name_token(name, nil) do
    if String.downcase(name) in ["true", "false"],
      do: {:bool, String.downcase(name) == "true"},
      else: {:name, InfluxQLText.unquote_ident(name), nil}
  end

  defp name_token(name, cast), do: {:name, InfluxQLText.unquote_ident(name), cast}

  # The body of a regular expression up to its closing slash; `\/` is a slash.
  @spec regex_end(binary(), iodata()) :: {:ok, binary(), binary()} | :error
  defp regex_end(<<?\\, ?/, rest::binary>>, acc), do: regex_end(rest, ["/" | acc])

  defp regex_end(<<?/, rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp regex_end(<<c, rest::binary>>, acc), do: regex_end(rest, [<<c>> | acc])
  defp regex_end(<<>>, _acc), do: :error

  # A duration beyond 64 bits is the engine's parse error ("overflow"), at a
  # position the double does not track: refused by name.
  defp duration(_rest, ns, _acc) when ns > 9_223_372_036_854_775_807, do: :error
  defp duration(rest, ns, acc), do: tokenize(rest, [{:duration, ns} | acc])

  defp duration_ns(text) do
    ~r/(\d+)(ns|ms|u|µ|s|m|h|d|w)/u
    |> Regex.scan(text)
    |> Enum.reduce(0, fn [_all, count, unit], total ->
      total + String.to_integer(count) * Durations.ns(unit)
    end)
  end

  defp rest_after(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  @spec sum(list()) :: {:ok, term(), list()} | :error
  defp sum(tokens) do
    with {:ok, left, rest} <- product(tokens), do: more(rest, left, ["+", "-"], &product/1)
  end

  @spec product(list()) :: {:ok, term(), list()} | :error
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
  @spec unary(list()) :: {:ok, term(), list()} | :error
  defp unary([{:op, "-"}, {:number, text} | rest]), do: literal(text, -1, rest)

  defp unary([{:op, "-"}, {kind, _value} | _rest]) when kind in [:str, :bool], do: :error

  defp unary([{:op, "-"} | rest]) do
    with {:ok, operand, after_operand} <- atom(rest), do: {:ok, {:neg, operand}, after_operand}
  end

  defp unary([{:op, "+"} | rest]), do: atom(rest)
  defp unary(tokens), do: atom(tokens)

  @spec atom(list()) :: {:ok, term(), list()} | :error
  defp atom([{:number, text} | rest]), do: literal(text, 1, rest)
  defp atom([{:str, content} | rest]), do: {:ok, {:str, content}, rest}
  defp atom([{:bool, value} | rest]), do: {:ok, {:bool, value}, rest}
  defp atom([{:duration, ns} | rest]), do: {:ok, {:dur, ns}, rest}
  defp atom([{:regex, source} | rest]), do: {:ok, {:regex, source}, rest}
  defp atom([{:star, kind} | rest]), do: {:ok, {:star, kind}, rest}

  defp atom([{:op, "("} | rest]) do
    case sum(rest) do
      {:ok, ast, [{:op, ")"} | after_group]} -> {:ok, {:paren, ast}, after_group}
      _unbalanced -> :error
    end
  end

  defp atom([{:name, name, nil}, {:op, "("} | rest]) when is_binary(name) do
    name = String.downcase(name)

    with {:ok, arguments, after_call} <- arguments(rest, [], name in ["top", "bottom"]),
         do: {:ok, {:call, name, arguments}, after_call}
  end

  defp atom([{:name, name, nil} | rest]), do: {:ok, {:ref, name}, rest}
  defp atom([{:name, name, cast} | rest]), do: {:ok, {:cast, name, cast_type(cast)}, rest}
  defp atom(_tokens), do: :error

  # The arguments of a call, after its `(`.
  defp arguments([{:op, ")"} | rest], [], _keep?), do: {:ok, [], rest}

  defp arguments(tokens, acc, keep?) do
    with {:ok, argument, rest} <- sum(tokens) do
      argument = if acc == [] or keep?, do: argument, else: unparen_group(argument)

      case rest do
        [{:op, ","} | more] -> arguments(more, [argument | acc], keep?)
        [{:op, ")"} | after_call] -> {:ok, Enum.reverse([argument | acc]), after_call}
        _unclosed -> :error
      end
    end
  end

  # Only the first argument of a call keeps its parentheses (all of them for `top()` and
  # `bottom()`, which the double refuses): for a function of a field they are the planning
  # error (see `argument_error/4`), for the others a group means nothing.
  defp unparen({:paren, inner}), do: unparen(inner)
  defp unparen(other), do: other

  # A group around a constant stays (`pow(n, (2))`): it is the planning error of
  # `paren_constant?/1`; any other group means nothing.
  defp unparen_group({:paren, _inner} = group),
    do:
      if(match?({kind, _value} when kind in [:lit, :dur], unparen(group)),
        do: group,
        else: unparen(group)
      )

  defp unparen_group(other), do: other

  # Whether a constant stands alone in a group anywhere in an expression as it was read
  # (`n * (3)`, `-(3)`, `(1 + 2) * (3)`): the engine's planner takes the group for a node it
  # cannot find a variable in, and words "field must contain at least one variable" for the
  # whole field (verified), whatever else the field holds.
  @spec paren_constant?(term()) :: boolean()
  defp paren_constant?({:paren, inner}),
    do: match?({:lit, _number}, unparen(inner)) or paren_constant?(inner)

  defp paren_constant?({:neg, operand}), do: paren_constant?(operand)

  defp paren_constant?({:bin, _op, left, right}),
    do: paren_constant?(left) or paren_constant?(right)

  defp paren_constant?({:call, _name, arguments}), do: Enum.any?(arguments, &paren_constant?/1)
  defp paren_constant?(_other), do: false

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
  # Calls
  # ---------------------------------------------------------------------------

  # The calls of a parsed expression become what they are: an aggregate of a
  # field, a math function, a transform. A call with `*` or a regular
  # expression for its field stands for several columns and is the whole
  # expression, or nothing.
  @spec classify(term()) ::
          {:ok, ast()}
          | {:wild, binary(), [ast()], term()}
          | {:multi, binary(), binary(), [binary()], pos_integer()}
          | {:planning, binary()}
          | {:expand_error, binary()}
          | {:argument, binary(), term()}
          | :error
  defp classify({:call, name, arguments} = call) when name in ["top", "bottom"] do
    cond do
      wildcard?(List.first(arguments)) -> classify_wild(call)
      Enum.any?(arguments, &wildcard?/1) -> wildcard_arguments(name, arguments)
      true -> multi(name, arguments)
    end
  end

  defp classify({:call, _name, _arguments} = call), do: classify_wild(call)

  defp classify({:paren, inner}), do: classify(inner)

  defp classify({:neg, operand}),
    do: with({:ok, o} <- classify_inner(operand), do: {:ok, {:neg, o}})

  defp classify({:bin, op, left, right}) do
    case {classify(left), classify(right)} do
      {{:ok, l}, {:ok, r}} -> {:ok, {:bin, op, l, r}}
      {{:planning, _message} = planning, _right} -> planning
      {{:argument, _n, _a} = argument, _right} -> argument
      {{:wild, _n, _a, _t}, _right} -> {:expand_error, @wild_in_arithmetic}
      {_left, {:wild, _n, _a, _t}} -> {:expand_error, @wild_in_arithmetic}
      {_left, {:planning, _message} = planning} -> planning
      {_left, {:argument, _n, _a} = argument} -> argument
      _other -> :error
    end
  end

  defp classify({kind, _payload} = _leaf) when kind in [:star, :regex, :dur], do: :error
  defp classify(leaf), do: {:ok, leaf}

  defp wildcard?({kind, _target}), do: kind in [:star, :regex]
  defp wildcard?(_argument), do: false

  # `top(f, *::tag, n)`: the last argument is judged first (verified: a limit that is no
  # positive integer, or a wildcard), then the ones between, which must be fields or tags.
  defp wildcard_arguments(name, [_field | rest]) do
    {between, last} = Enum.split(rest, -1)

    case {last, Enum.find(between, &wildcard?/1)} do
      {[{kind, _target} = target], _between} when kind in [:star, :regex] ->
        {:planning, "expected integer as last argument for #{name}, got #{wildcard_text(target)}"}

      {[{:lit, {:int, n}}], _between} when n <= 0 ->
        {:planning, "limit (#{n}) for #{name} must be greater than 0"}

      {[{:lit, {:float, x}}], _between} ->
        {:planning,
         "expected integer as last argument for #{name}, got Literal(Float(#{Float.to_string(x)}))"}

      {[{:str, content}], _between} ->
        {:planning,
         "expected integer as last argument for #{name}, got Literal(String(#{InfluxQLError.rust_debug(content)}))"}

      {[{:lit, {:int, _n}}], target} when target != nil ->
        {:planning, "only fields or tags are allow for #{name}(), got #{wildcard_text(target)}"}

      _other ->
        :error
    end
  end

  defp wildcard_text({:star, nil}), do: "Wildcard(None)"
  defp wildcard_text({:star, "tag"}), do: "Wildcard(Some(Tag))"
  defp wildcard_text({:star, "field"}), do: "Wildcard(Some(Field))"

  defp wildcard_text({:regex, source}),
    do: "Literal(Regex(Regex(#{InfluxQLError.rust_debug(source)})))"

  # A call with `*` or a regular expression among its arguments stands for the calls of the
  # fields it names.
  @spec classify_wild(term()) ::
          {:ok, ast()}
          | {:wild, binary(), [ast()], term()}
          | {:planning, binary()}
          | {:expand_error, binary()}
          | {:argument, binary(), term()}
          | :error
  defp classify_wild({:call, name, arguments} = call) do
    case Enum.split_with(arguments, &match?({kind, _} when kind in [:star, :regex], &1)) do
      {[], _plain} ->
        classify_plain(call)

      {[{:star, "tag"}], _plain} ->
        if name in @wild_names,
          do: {:expand_error, "unable to use tag as wildcard in #{name}()"},
          else: :error

      {[{:regex, _source}], [_argument | _more]} ->
        :error

      {[target], plain} ->
        if name in @wild_names, do: {:wild, name, plain, target}, else: :error

      _several ->
        :error
    end
  end

  # A function of a field given a group in parentheses or arithmetic, not the field: the
  # planning error of `argument_error/4`.
  defp classify_plain({:call, name, [argument | _rest]} = call) when name in @field_functions do
    if nested_argument?(argument),
      do: {:argument, name, argument},
      else: classify_call(call)
  end

  defp classify_plain(call), do: classify_call(call)

  defp nested_argument?({:paren, _inner}), do: true
  defp nested_argument?({:neg, _operand}), do: true
  defp nested_argument?({:bin, _op, _left, _right}), do: true
  defp nested_argument?(_other), do: false

  # Inside another expression a call with `*` is no column of its own; a
  # planning error found in it is the error of the whole.
  defp classify_inner(ast) do
    case classify(ast) do
      {:ok, classified} -> {:ok, classified}
      {:planning, _message} = planning -> planning
      {:argument, _n, _a} = argument -> argument
      _other -> :error
    end
  end

  # `top(f, n)`, `top(f, tag, ..., n)`: the whole item, several rows.
  defp multi(name, arguments) when length(arguments) < 2 do
    {:planning,
     "invalid number of arguments for #{name}, expected at least 2, got #{length(arguments)}"}
  end

  defp multi(name, [field | rest]) do
    {tags, [last]} = Enum.split(rest, -1)

    case {field, last, Enum.all?(tags, &match?({:ref, _}, &1))} do
      {{:ref, f}, {:lit, {:int, n}}, true} when n > 0 ->
        {:multi, name, f, for({:ref, tag} <- tags, do: tag), n}

      {_field, {:lit, {:int, n}}, _tags} when n <= 0 ->
        {:planning, "limit (#{n}) for #{name} must be greater than 0"}

      {_field, {:lit, {:float, x}}, _tags} ->
        {:planning,
         "expected integer as last argument for #{name}, got Literal(Float(#{Float.to_string(x)}))"}

      {_field, {:str, content}, _tags} ->
        {:planning,
         "expected integer as last argument for #{name}, got Literal(String(#{InfluxQLError.rust_debug(content)}))"}

      _other ->
        :error
    end
  end

  defp classify_call({:call, name, [argument]}) when name in @aggregates do
    case classify_inner(argument) do
      {:ok, {:ref, field}} -> {:ok, {:agg, name, field}}
      _other -> :error
    end
  end

  defp classify_call({:call, "percentile", [argument, {:lit, {_kind, n}}]}) do
    case classify_inner(argument) do
      {:ok, {:ref, field}} -> {:ok, {:agg, "percentile:" <> number_text(n), field}}
      _other -> :error
    end
  end

  defp classify_call({:call, "integral", [argument | unit]}) when length(unit) <= 1 do
    with {:ok, {:ref, field}} <- classify_inner(argument),
         {:ok, ns} <- integral_unit(unit) do
      {:ok, {:agg, "integral:" <> Integer.to_string(ns), field}}
    else
      {:planning, _message} = planning -> planning
      _unread -> :error
    end
  end

  defp classify_call({:call, name, [argument]}) when name in @one_argument,
    do: function(name, [argument])

  defp classify_call({:call, name, [first, second]}) when name in @two_arguments,
    do: function(name, [first, second])

  defp classify_call({:call, name, arguments}) when name in @transforms,
    do: transform(name, arguments)

  defp classify_call(_call), do: :error

  @doc """
  The engine's planning error for a function of a field given something else (a group in
  parentheses, arithmetic): it words the argument as its parser read it, with the type of
  every field (verified). An argument with a typing error of its own is that error; one the
  double does not word is refused by name.
  """
  @spec argument_error(binary(), term(), %{binary() => atom()}, MapSet.t(binary())) ::
          {:error, {:engine, binary()} | binary()}
  def argument_error(name, argument, types, tags) do
    refusal = {:error, "unsupported InfluxQL (#{name}() of that argument)"}

    with {:ok, plain} <- classify_inner(argument),
         :ok <- check(plain, types, tags),
         {:ok, text} <- render(argument, types, tags) do
      {:error,
       {:engine, InfluxQLError.select_error("expected field argument in #{name}(), got #{text}")}}
    else
      {:error, _reason} = error -> error
      _unread -> refusal
    end
  end

  @spec render(term(), map(), MapSet.t(binary())) :: {:ok, binary()} | :error
  defp render({:paren, inner}, types, tags), do: wrap("Nested", render(inner, types, tags))
  defp render({:lit, {:int, n}}, _types, _tags), do: {:ok, "Literal(Integer(#{n}))"}

  defp render({:lit, {:float, x}}, _types, _tags) do
    text = Float.to_string(x)
    if String.contains?(text, "e"), do: :error, else: {:ok, "Literal(Float(#{text}))"}
  end

  defp render({:str, content}, _types, _tags) do
    if content =~ ~r/^[\w ]*$/, do: {:ok, ~s|Literal(String("#{content}"))|}, else: :error
  end

  defp render({:bool, value}, _types, _tags), do: {:ok, "Literal(Boolean(#{value}))"}
  defp render({:star, nil}, _types, _tags), do: {:ok, "Wildcard(None)"}

  defp render({:ref, name}, types, tags) do
    type =
      cond do
        String.downcase(name) == "time" -> "Some(Timestamp)"
        MapSet.member?(tags, name) -> "Some(Tag)"
        true -> type_text(Map.get(types, name))
      end

    {:ok,
     "VarRef(VarRef { name: Identifier(#{InfluxQLError.rust_debug(name)}), data_type: #{type} })"}
  end

  defp render({:neg, operand}, types, tags),
    do: render({:bin, "*", {:lit, {:int, -1}}, operand}, types, tags)

  defp render({:bin, op, left, right}, types, tags) do
    with {:ok, l} <- render(left, types, tags),
         {:ok, r} <- render(right, types, tags) do
      {:ok, "Binary(Binary { lhs: #{l}, op: #{operator_text(op)}, rhs: #{r} })"}
    end
  end

  defp render(_other, _types, _tags), do: :error

  defp wrap(name, {:ok, text}), do: {:ok, "#{name}(#{text})"}
  defp wrap(_name, :error), do: :error

  defp type_text(nil), do: "None"
  defp type_text(:float), do: "Some(Float)"
  defp type_text(:integer), do: "Some(Integer)"
  defp type_text(:unsigned), do: "Some(Unsigned)"
  defp type_text(:string), do: "Some(String)"
  defp type_text(:boolean), do: "Some(Boolean)"

  defp operator_text("+"), do: "Add"
  defp operator_text("-"), do: "Sub"
  defp operator_text("*"), do: "Mul"
  defp operator_text("/"), do: "Div"
  defp operator_text("%"), do: "Mod"

  @doc """
  The unit of an `integral()` from its argument list (none: a second): `{:ok,
  nanoseconds}`, the engine's planning error as `{:planning, message}` for a
  duration that is not positive, or `:error` for what is no duration.
  """
  @spec integral_unit([term()]) :: {:ok, pos_integer()} | {:planning, binary()} | :error
  def integral_unit([]), do: {:ok, 1_000_000_000}
  def integral_unit([duration]), do: positive_duration(duration)
  def integral_unit(_other), do: :error

  # The engine's planning error for a duration argument that is not positive.
  defp positive_duration({:dur, ns}) when ns > 0, do: {:ok, ns}
  defp positive_duration({:neg, {:dur, ns}}), do: not_positive(-ns)
  defp positive_duration({:dur, ns}), do: not_positive(ns)
  defp positive_duration(_other), do: :error

  defp not_positive(ns) do
    {:planning,
     "duration argument must be positive, got " <> InfluxQLLiteral.display_duration(ns)}
  end

  defp function(name, arguments) do
    classified = Enum.map(arguments, &classify_inner/1)

    cond do
      Enum.all?(classified, &match?({:ok, _ast}, &1)) ->
        {:ok, {:fn, name, for({:ok, ast} <- classified, do: ast)}}

      planning = Enum.find(classified, &match?({:planning, _message}, &1)) ->
        planning

      argument = Enum.find(classified, &match?({:argument, _name, _argument}, &1)) ->
        argument

      true ->
        :error
    end
  end

  defp transform(name, [argument | options]) do
    with {:ok, inner} <- classify_inner(argument),
         {:ok, parameter} <- transform_parameter(name, options),
         true <- inner_ok?(inner) do
      {:ok, {:transform, name, inner, parameter}}
    else
      {:planning, _message} = planning -> planning
      {:argument, _n, _a} = argument -> argument
      _unread -> :error
    end
  end

  defp transform(_name, []), do: :error

  # A transform reads a field or one aggregate of a field.
  defp inner_ok?({:ref, _field}), do: true
  defp inner_ok?({:agg, _fun, _field}), do: true
  defp inner_ok?(_other), do: false

  defp transform_parameter("moving_average", [{:lit, {:int, n}}]) when n > 1, do: {:ok, n}

  defp transform_parameter("moving_average", [{:lit, {:int, n}}]),
    do: {:planning, "moving_average window must be greater than 1, got #{n}"}

  defp transform_parameter("moving_average", _other), do: :error
  defp transform_parameter("cumulative_sum", []), do: {:ok, nil}
  defp transform_parameter(name, []) when name in @transforms, do: {:ok, nil}
  defp transform_parameter("cumulative_sum", _other), do: :error
  defp transform_parameter("difference", _other), do: :error
  defp transform_parameter("non_negative_difference", _other), do: :error
  defp transform_parameter(_name, [duration]), do: positive_duration(duration)
  defp transform_parameter(_name, _other), do: :error

  @doc "A number as it is written inside the name of an aggregate (`percentile:99.5`)."
  @spec number_text(number()) :: binary()
  def number_text(n) when is_integer(n), do: Integer.to_string(n)
  def number_text(x) when is_float(x), do: Float.to_string(x)

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
  defp names({:agg, fun, _arg}), do: [function_name(fun)]
  defp names({:fn, name, _arguments}), do: [name]
  defp names({:transform, name, _inner, _parameter}), do: [name]
  defp names({:neg, operand}), do: names(operand)
  defp names({:bin, _op, left, right}), do: names(left) ++ names(right)
  defp names(_literal), do: []

  @doc "The name of an aggregate function (`percentile:95` is `percentile`)."
  @spec function_name(binary()) :: binary()
  def function_name(fun), do: fun |> String.split(":") |> hd()

  @doc "The name of the first function an expression calls, in the order it is written."
  @spec first_call(ast()) :: binary() | nil
  def first_call({:fn, name, _arguments}), do: name
  def first_call({:neg, operand}), do: first_call(operand)
  def first_call({:bin, _op, left, right}), do: first_call(left) || first_call(right)
  def first_call(_other), do: nil

  @doc "The fields (and tags) an expression reads."
  @spec refs(ast()) :: [binary()]
  def refs({:ref, name}), do: [name]
  def refs({:cast, name, _type}), do: [name]
  def refs({:neg, operand}), do: refs(operand)
  def refs({:bin, _op, left, right}), do: refs(left) ++ refs(right)
  def refs({:fn, _name, arguments}), do: Enum.flat_map(arguments, &refs/1)
  def refs({:transform, _name, inner, _parameter}), do: refs(inner)
  def refs(_other), do: []

  @doc "Whether a string or a boolean stands anywhere in an expression."
  @spec text_literal?(ast()) :: boolean()
  def text_literal?({:bool, _value}), do: true
  def text_literal?({:str, _content}), do: true
  def text_literal?({:neg, operand}), do: text_literal?(operand)
  def text_literal?({:bin, _op, left, right}), do: text_literal?(left) or text_literal?(right)
  def text_literal?({:fn, _name, arguments}), do: Enum.any?(arguments, &text_literal?/1)
  def text_literal?(_other), do: false

  @doc "Whether an expression divides (`/`) anywhere in it."
  @spec divides?(ast()) :: boolean()
  def divides?({:bin, "/", _left, _right}), do: true
  def divides?({:bin, _op, left, right}), do: divides?(left) or divides?(right)
  def divides?({:neg, operand}), do: divides?(operand)
  def divides?({:fn, _name, arguments}), do: Enum.any?(arguments, &divides?/1)
  def divides?({:transform, _name, inner, _parameter}), do: divides?(inner)
  def divides?(_other), do: false

  @doc """
  Whether an expression of aggregates is made of quotients: it divides, and every aggregate in
  it is an operand of a division (`sum(f) / count(f)`, `(sum(f) + 1) / 2`,
  `sum(f) / 2 + sum(g) / 2`;
  not `sum(f) / count(f) + sum(g)`).
  """
  @spec quotients?(ast()) :: boolean()
  def quotients?(ast),
    do: divides?(ast) and aggregates(ast) != [] and undivided_aggregates(ast) == []

  defp undivided_aggregates({:bin, "/", _left, _right}), do: []
  defp undivided_aggregates({:agg, fun, arg}), do: [{fun, arg}]
  defp undivided_aggregates({:neg, operand}), do: undivided_aggregates(operand)

  defp undivided_aggregates({:bin, _op, left, right}),
    do: undivided_aggregates(left) ++ undivided_aggregates(right)

  defp undivided_aggregates({:fn, _name, arguments}),
    do: Enum.flat_map(arguments, &undivided_aggregates/1)

  defp undivided_aggregates({:transform, _name, inner, _parameter}),
    do: undivided_aggregates(inner)

  defp undivided_aggregates(_other), do: []

  @doc "The aggregates an expression holds, as `{fun, argument}`."
  @spec aggregates(ast()) :: [{binary(), binary()}]
  def aggregates({:agg, fun, arg}), do: [{fun, arg}]
  def aggregates({:neg, operand}), do: aggregates(operand)
  def aggregates({:bin, _op, left, right}), do: aggregates(left) ++ aggregates(right)
  def aggregates({:fn, _name, arguments}), do: Enum.flat_map(arguments, &aggregates/1)
  def aggregates({:transform, _name, inner, _parameter}), do: aggregates(inner)
  def aggregates(_other), do: []

  @doc """
  The transforms an expression holds, whole (`{:transform, name, inner,
  parameter}`), in the order they are read.
  """
  @spec transforms(ast()) :: [ast()]
  def transforms({:transform, _name, _inner, _parameter} = transform), do: [transform]
  def transforms({:neg, operand}), do: transforms(operand)
  def transforms({:bin, _op, left, right}), do: transforms(left) ++ transforms(right)
  def transforms({:fn, _name, arguments}), do: Enum.flat_map(arguments, &transforms/1)
  def transforms(_other), do: []

  @doc """
  The expression with each aggregate replaced by a reference to the column
  `key.(fun, arg)` names.
  """
  @spec hoist(ast(), ({binary(), binary()} -> binary())) :: ast()
  def hoist({:agg, fun, arg}, key), do: {:ref, key.({fun, arg})}
  def hoist({:neg, operand}, key), do: {:neg, hoist(operand, key)}
  def hoist({:bin, op, left, right}, key), do: {:bin, op, hoist(left, key), hoist(right, key)}
  def hoist({:fn, name, arguments}, key), do: {:fn, name, Enum.map(arguments, &hoist(&1, key))}

  def hoist({:transform, name, inner, parameter}, key),
    do: {:transform, name, hoist(inner, key), parameter}

  def hoist(other, _key), do: other

  @doc """
  The expression with each transform replaced by a reference to the column
  `key.(transform)` names.
  """
  @spec hoist_transforms(ast(), (ast() -> binary())) :: ast()
  def hoist_transforms({:transform, _name, _inner, _parameter} = transform, key),
    do: {:ref, key.(transform)}

  def hoist_transforms({:neg, operand}, key), do: {:neg, hoist_transforms(operand, key)}

  def hoist_transforms({:bin, op, left, right}, key),
    do: {:bin, op, hoist_transforms(left, key), hoist_transforms(right, key)}

  def hoist_transforms({:fn, name, arguments}, key),
    do: {:fn, name, Enum.map(arguments, &hoist_transforms(&1, key))}

  def hoist_transforms(other, _key), do: other

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @typedoc "What an operand is: its type, and whether it is a literal."
  @type type ::
          {:integer | :unsigned | :float | :string | :tag | :boolean | :timestamp | :unknown,
           boolean()}

  @doc """
  The engine's planning error for the first operation of `ast` it cannot
  type, `:ok` when there is none. `types` is the type of each field, `tags`
  the tag columns. A function of a time is the engine's error only when it runs a plan,
  which it does when a field is aggregated beside it (`physical?`, verified: `abs(max(time))`
  alone answers nothing, beside `count(v)` it is the error).
  """
  @spec check(ast(), %{binary() => atom()}, MapSet.t(binary()), boolean()) ::
          :ok | {:error, {:engine, binary()} | binary()}
  def check(ast, types, tags, physical? \\ false) do
    case infer(ast, types, tags) do
      {:engine, body} -> {:error, {:engine, body}}
      {:physical, body} -> if physical?, do: {:error, {:engine, body}}, else: :ok
      {:physical_refuse, message} -> if physical?, do: refusal(message), else: :ok
      {:refuse, message} -> {:error, "unsupported InfluxQL (#{message})"}
      {:ok, _type} -> :ok
    end
  end

  @doc """
  `check/4` of the operands as the engine types them while it expands the projection, where
  the result of `median()` is a float whatever it reads (verified: `median(b) + time` words
  `float and timestamp`); the plan that follows types it as its argument (`spread(i) /
  median(u)` is `cannot use / between an integer and unsigned`).
  """
  @spec check_expanding(ast(), map(), MapSet.t(binary())) ::
          :ok | {:error, {:engine, binary()} | binary()}
  def check_expanding(ast, types, tags), do: check(median_as_mean(ast), types, tags, false)

  defp median_as_mean({:agg, "median", arg}), do: {:agg, "mean", arg}
  defp median_as_mean({:neg, operand}), do: {:neg, median_as_mean(operand)}

  defp median_as_mean({:bin, op, left, right}),
    do: {:bin, op, median_as_mean(left), median_as_mean(right)}

  defp median_as_mean({:fn, name, arguments}),
    do: {:fn, name, Enum.map(arguments, &median_as_mean/1)}

  defp median_as_mean(other), do: other

  @doc "The type an expression comes to, for the columns after it."
  @spec result_type(ast(), %{binary() => atom()}, MapSet.t(binary())) :: atom()
  def result_type(ast, types, tags) do
    case infer(ast, types, tags) do
      {:ok, {type, _literal}} -> type
      _error -> :unknown
    end
  end

  @typep inferred ::
           {:ok, type()}
           | {:engine, binary()}
           | {:physical, binary()}
           | {:physical_refuse, binary()}
           | {:refuse, binary()}

  defp refusal(message), do: {:error, "unsupported InfluxQL (#{message})"}

  @spec infer(ast(), map(), MapSet.t(binary())) :: inferred()
  defp infer({:lit, {:int, _n}}, _types, _tags), do: {:ok, {:integer, true}}
  defp infer({:lit, {:float, _x}}, _types, _tags), do: {:ok, {:float, true}}
  defp infer({:str, _content}, _types, _tags), do: {:ok, {:string, true}}
  defp infer({:bool, _value}, _types, _tags), do: {:ok, {:boolean, true}}

  defp infer({:ref, name}, types, tags) do
    cond do
      String.downcase(name) == "time" -> {:ok, {:timestamp, false}}
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

  defp infer({:agg, fun, "time"}, _types, _tags) when fun in ~w(min max first last mode),
    do: {:ok, {:timestamp, false}}

  # A tag keeps its type through the aggregates that return a value of the column; the others
  # (`count`, `mean`, `median`, `stddev`) come to numbers (verified).
  defp infer({:agg, fun, arg}, types, tags) do
    if not Map.has_key?(types, arg) and MapSet.member?(tags, arg) and
         (fun in ~w(first last min max mode sum spread) or String.starts_with?(fun, "percentile:")),
       do: {:ok, {:tag, false}},
       else: {:ok, {aggregate_type(fun, Map.get(types, arg)), false}}
  end

  defp infer({:fn, name, arguments}, types, tags) do
    inferred = Enum.map(arguments, &infer(&1, types, tags))

    case Enum.find(inferred, &(not match?({:ok, _}, &1))) do
      nil -> function_type(name, for({:ok, type} <- inferred, do: type), arguments)
      error -> error
    end
  end

  defp infer({:transform, name, inner, _parameter}, types, tags) do
    with {:ok, {type, _literal}} <- infer(inner, types, tags) do
      transform_type(name, type)
    end
  end

  defp infer({:neg, operand}, types, tags),
    do: infer({:bin, "*", {:lit, {:int, -1}}, operand}, types, tags)

  defp infer({:bin, op, left, right}, types, tags) do
    with {:ok, l} <- operand(infer(left, types, tags)),
         {:ok, r} <- operand(infer(right, types, tags)) do
      operation(op, l, r)
    end
  end

  # A math function of a time is a timestamp to the operation around it: the engine rejects the
  # operation when it rewrites the projection (`incompatible operands`), before the plan that
  # would reject the function (verified: `1 / abs(time)`, `true + abs(time)`, `-abs(time)`).
  @spec operand(inferred()) :: inferred()
  defp operand({:physical, _body}), do: {:ok, {:timestamp, false}}
  defp operand({:physical_refuse, _message}), do: {:ok, {:timestamp, false}}
  defp operand(inferred), do: inferred

  defp cast_type_of(type, target) when type in [:integer, :float, :unknown],
    do: {:ok, {target_type(type, target), false}}

  defp cast_type_of(type, target), do: {:refuse, "a #{type} field cast to #{target}"}

  defp target_type(:unknown, _target), do: :unknown
  defp target_type(_type, target), do: target

  defp aggregate_type(fun, _type) when fun in ["count"], do: :integer
  defp aggregate_type(fun, _type) when fun in ["mean", "stddev"], do: :float
  defp aggregate_type("median", type) when type in [:string, :boolean], do: :float
  defp aggregate_type(_fun, nil), do: :unknown
  defp aggregate_type(_fun, type), do: type

  # The type of a math function of its arguments.
  @spec function_type(binary(), [type()], [ast()]) :: inferred()
  defp function_type(name, types, arguments) do
    case Enum.find(types, fn {type, _literal} -> type not in [:integer, :float, :unknown] end) do
      {:timestamp, _literal} ->
        timestamp_function(name)

      {type, _literal} ->
        {:refuse, "#{name}() of a #{type}"}

      nil ->
        function_result(name, types, arguments)
    end
  end

  # The engine plans a math function of a time only when it runs the plan (a field is
  # aggregated beside it); `abs` is worded as its library words it, the others are refused.
  @spec timestamp_function(binary()) :: inferred()
  defp timestamp_function("abs") do
    {:physical,
     "Error during planning: Function 'abs' expects NativeType::Numeric but received " <>
       "NativeType::Timestamp(Nanosecond, None) No function matches the given name and " <>
       "argument types 'abs(Timestamp(ns))'. You might need to add explicit type casts." <>
       "\n\tCandidate functions:\n\tabs(Numeric(1))"}
  end

  defp timestamp_function(name), do: {:physical_refuse, "#{name}() of a timestamp"}

  defp function_result("abs", [{type, _literal}], _arguments), do: {:ok, {type, false}}

  defp function_result("pow", [{:integer, _l1}, {:integer, _l2}], [_base, {:lit, {:int, n}}])
       when n >= 0,
       do: {:ok, {:integer, false}}

  defp function_result("pow", [{:integer, _l1}, {:integer, _l2}], _arguments),
    do: {:refuse, "pow() of an integer by that exponent"}

  defp function_result(_name, types, _arguments) do
    if Enum.any?(types, fn {type, _literal} -> type == :unknown end),
      do: {:ok, {:unknown, false}},
      else: {:ok, {:float, false}}
  end

  defp transform_type(name, type) when name in ["difference", "cumulative_sum"] do
    if type in [:integer, :float, :unknown],
      do: {:ok, {type, false}},
      else: {:refuse, "#{name}() of a #{type}"}
  end

  defp transform_type("elapsed", type) do
    if type in [:integer, :float, :unsigned, :string, :boolean, :unknown],
      do: {:ok, {:integer, false}},
      else: {:refuse, "elapsed() of a #{type}"}
  end

  defp transform_type("non_negative_difference", type) do
    if type in [:integer, :float, :unknown],
      do: {:ok, {type, false}},
      else: {:refuse, "non_negative_difference() of a #{type}"}
  end

  defp transform_type(name, type) do
    if type in [:integer, :float, :unknown],
      do: {:ok, {:float, false}},
      else: {:refuse, "#{name}() of a #{type}"}
  end

  # Operands that take no part in arithmetic: the engine's `incompatible operands`.
  @no_arithmetic [:tag, :string, :boolean, :timestamp]

  # A column the measurement lacks beside a tag, a string or a boolean is a constant false of the
  # type of the other operand (verified: `nosuch / host` is `false`, as are `nosuch / 'x'` and
  # `nosuch + ok`; beside a number it is null).
  @text_types [:tag, :string, :boolean]

  @spec operation(binary(), type(), type()) :: inferred()
  defp operation(op, {lt, _ll} = l, {rt, _rl} = r) do
    cond do
      absent_text?(lt, rt) ->
        {:ok, {if(lt == :unknown, do: rt, else: lt), false}}

      lt in @no_arithmetic or rt in @no_arithmetic ->
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

  defp absent_text?(:unknown, type), do: type in @text_types
  defp absent_text?(type, :unknown), do: type in @text_types
  defp absent_text?(_left, _right), do: false

  @doc """
  `ast` with the operation that is a constant false (a column the measurement lacks beside a
  tag, a string or a boolean) replaced by the constant.
  """
  @spec fold(ast(), map(), MapSet.t(binary())) :: ast()
  def fold({:bin, _op, left, right} = ast, types, tags) do
    with {:ok, {left_type, _literal}} <- infer(left, types, tags),
         {:ok, {right_type, _literal}} <- infer(right, types, tags),
         true <- absent_text?(left_type, right_type) do
      {:bool, false}
    else
      _other -> ast
    end
  end

  def fold(ast, _types, _tags), do: ast

  defp incompatible(op, left, right) do
    InfluxQLError.expand_error(
      "incompatible operands for operator #{op}: #{type_name(left)} and #{type_name(right)}"
    )
  end

  defp type_name(type), do: Atom.to_string(type)

  defp result(_op, {:unknown, _l}, {:unknown, _r}), do: {:unknown, false}
  defp result(_op, {:unknown, _l}, {type, _r}), do: {type, false}
  defp result(_op, {type, _l}, {:unknown, _r}), do: {type, false}
  defp result(_op, {:float, _l}, _right), do: {:float, false}
  defp result(_op, _left, {:float, _r}), do: {:float, false}
  defp result("/", {:integer, _l}, {:integer, _r}), do: {:float, false}
  defp result(_op, {:unsigned, _l}, _right), do: {:unsigned, false}
  defp result(_op, _left, {:unsigned, _r}), do: {:unsigned, false}
  defp result(_op, _left, _right), do: {:integer, false}

  # ---------------------------------------------------------------------------
  # Computing
  # ---------------------------------------------------------------------------

  @typedoc """
  A value: a signed or unsigned integer, a float, null, or `:nan`, a number that
  is not finite (written as a null that is in the row).
  """
  @type value ::
          {:int, integer()}
          | {:uint, non_neg_integer()}
          | {:float, float()}
          | {:bool, boolean()}
          | nil
          | :nan

  @doc """
  The value of `ast` over a row (`env`: name to value); `nil` for null, `:nan`
  for a number that is not finite. Throws `{:refused, message}` for what the
  double does not reproduce.
  """
  @spec eval(ast(), map(), map()) :: number() | boolean() | nil | :nan
  def eval(ast, env, types) do
    case value(ast, env, types) do
      nil -> nil
      :nan -> :nan
      {_kind, number} -> number
    end
  end

  @spec value(ast(), map(), map()) :: value()
  defp value({:lit, {:int, n}}, _env, _types), do: {:int, n}
  defp value({:lit, {:float, x}}, _env, _types), do: {:float, x}
  defp value({:bool, value}, _env, _types), do: {:bool, value}
  defp value({:ref, name}, env, types), do: typed(Map.get(types, name), Map.get(env, name))
  defp value({:cast, name, target}, env, types), do: cast(name, target, env, types)

  defp value({:fn, name, arguments}, env, types),
    do: call(name, Enum.map(arguments, &value(&1, env, types)))

  defp value({:neg, operand}, env, types),
    do: value({:bin, "*", operand, {:lit, {:int, -1}}}, env, types)

  defp value({:bin, op, left, right}, env, types),
    do: apply_op(op, value(left, env, types), value(right, env, types))

  # A string or a boolean has no value in arithmetic: the planner refuses such an expression
  # (`infer/3`) before any row is read, so this is a form the double has not seen.
  defp value(_other, _env, _types),
    do: throw({:refused, "unsupported InfluxQL (a string or a boolean in an expression)"})

  defp typed(_type, :nan), do: :nan
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

  # A math function of its argument values: null in, null out; a result that
  # is not a finite number is `:nan`.
  @spec call(binary(), [value()]) :: value()
  defp call(name, arguments) do
    cond do
      nil in arguments -> nil
      :nan in arguments -> :nan
      true -> compute(name, arguments)
    end
  end

  @spec compute(binary(), [value()]) :: value()

  defp compute("abs", [{:int, n}]) when n == -9_223_372_036_854_775_808,
    do: throw({:refused, "unsupported InfluxQL (abs() of the smallest integer)"})

  defp compute("abs", [{:int, n}]), do: {:int, abs(n)}
  defp compute("abs", [{:float, x}]), do: {:float, abs(x)}
  defp compute("round", [{_kind, x}]), do: {:float, round(x) * 1.0}
  defp compute("floor", [{_kind, x}]), do: {:float, Float.floor(x * 1.0)}
  defp compute("ceil", [{_kind, x}]), do: {:float, Float.ceil(x * 1.0)}

  defp compute("pow", [{:int, base}, {:int, exponent}]) do
    result = Integer.pow(base, exponent)

    if SQLLimits.is_int64(result),
      do: {:int, result},
      else: throw({:refused, "unsupported InfluxQL (pow() beyond 64-bit integers)"})
  end

  defp compute("pow", [{_k1, x}, {_k2, y}]), do: float(fn -> :math.pow(x * 1.0, y * 1.0) end)

  defp compute("log", [{_k1, x}, {_k2, base}]),
    do: float(fn -> :math.log(x) / :math.log(base) end)

  defp compute("sqrt", [{_kind, x}]), do: float(fn -> :math.sqrt(x * 1.0) end)
  defp compute("ln", [{_kind, x}]), do: float(fn -> :math.log(x * 1.0) end)

  defp float(compute) do
    {:float, compute.()}
  rescue
    ArithmeticError -> :nan
  end

  @spec apply_op(binary(), value(), value()) :: value()
  defp apply_op(op, left, right), do: InfluxQLKernel.apply_op(op, left, right)
end
