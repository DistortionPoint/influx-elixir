defmodule InfluxElixir.Client.Local.InfluxQLWalk do
  @moduledoc false
  # The one precedence walker of the arithmetic of a condition, over a module that gives the
  # values (`InfluxQLArithType` types them, `InfluxQLTyped` folds constants):
  #
  #     sum     := product (("+" | "-") product)*
  #     product := factor (("*" | "/") factor)*
  #     factor  := sign factor | "(" sum ")" | number | call | leaf
  #
  # The walker owns the grammar and the order of the work: tokens are read once, left to right,
  # and an operation is combined as soon as its right operand is read, so the first problem of
  # an expression is the first one in the text. It knows nothing of the values: a module that
  # implements the behaviour below gives them, with the options (`Opts`) it was asked with.
  #
  # With `lazy` set the last operation of the expression is put off until the walk ends and is
  # then combined in the mode `lazy` names, where the others are combined in `mode` (an
  # operation is settled as soon as an operator, a sign or a comma follows it, or it is an
  # argument: only the last operation of the whole condition is the condition's own, see
  # `InfluxQLArithType`).

  defmodule Opts do
    @moduledoc false
    # What a walk is asked, handed to every callback:
    #
    #   * `ctx`: the tags and the types of the fields of the measurement
    #   * `mode`: how the quotient of an unsigned number and text is read (`InfluxQLArithType`)
    #   * `lazy`: `nil`, or the mode of the last operation, which is put off (see above)
    #   * `whole`: the condition is one call and nothing else (its error is worded without the
    #     signature the planner lists beside a call that is part of something)
    #   * `outermost`: the condition is a call with no arguments
    #   * `operand`: the condition has no comparison, it is a bare operand
    #   * `calls`: whether a name followed by a parenthesis is a call (a walk of constants has
    #     none)

    @type mode :: :loose | :text | :strict | :alone

    @type t :: %__MODULE__{
            ctx: nil | {MapSet.t(binary()), map()},
            mode: mode(),
            lazy: nil | mode(),
            whole: boolean(),
            outermost: boolean(),
            operand: boolean(),
            calls: boolean()
          }

    # `nil` for a walk that reads no column (the constants of `InfluxQLTyped`).
    defstruct ctx: nil,
              mode: :loose,
              lazy: nil,
              whole: false,
              outermost: false,
              operand: false,
              calls: true
  end

  @typedoc "A value of the module that is walked with: it is the module's own."
  @type value :: term()

  @typedoc "What a callback answers: a value, the tokens are no arithmetic, or the module's error."
  @type outcome :: {:ok, value()} | :unread | {:error, term()}

  @typedoc "What a walk answers: the value and the tokens left, `:unread`, or an error."
  @type result :: {:ok, value(), list()} | :unread | {:error, term()}

  @doc "The value of a number written `text` behind a sign, `1` or `-1`."
  @callback number(text :: binary(), sign :: 1 | -1, Opts.t()) :: outcome()

  @doc "The value that starts the tokens (a name, a string, a duration or a word) and what is left."
  @callback leaf(tokens :: list(), Opts.t()) :: result()

  @doc "An operator over two values."
  @callback combine(op :: binary(), left :: value(), right :: value(), Opts.t()) :: outcome()

  @doc "A minus sign before a value."
  @callback negate(value(), Opts.t()) :: outcome()

  @doc "The name of a call, before its arguments are read (`:ok`, or `:unread`/error to stop)."
  @callback enter(name :: binary(), Opts.t()) :: :ok | :unread | {:error, term()}

  @doc "A call: the name and the values of its arguments."
  @callback call(name :: binary(), arguments :: [value()], Opts.t()) :: outcome()

  @optional_callbacks enter: 2, call: 3

  # An operation put off until the walk knows whether it is the last.
  @typep deferred :: {:lazy, binary(), value(), value()}

  @doc """
  Reads a sum from the tokens. Returns the value and the tokens left, `:unread` when the tokens
  are no arithmetic, or the error a callback gave. One pass: nothing is read twice.
  """
  @spec walk(list(), module(), Opts.t()) :: result()
  def walk(tokens, mod, %Opts{} = o) do
    case sum(tokens, mod, o) do
      {:ok, value, rest} -> finish(value, rest, mod, o)
      other -> other
    end
  end

  @doc "`walk/3` for a single factor: a call, a group, a sign and its operand, or a leaf."
  @spec operand(list(), module(), Opts.t()) :: result()
  def operand(tokens, mod, %Opts{} = o) do
    case factor(tokens, mod, o) do
      {:ok, value, rest} -> finish(value, rest, mod, o)
      other -> other
    end
  end

  # The last operation is combined in the mode of the walk's end; any other value is settled.
  @spec finish(value() | deferred(), list(), module(), Opts.t()) :: result()
  defp finish({:lazy, op, left, right}, [], mod, %Opts{lazy: last} = o) do
    with {:ok, value} <- mod.combine(op, left, right, %{o | mode: last}), do: {:ok, value, []}
  end

  defp finish(value, rest, mod, o) do
    with {:ok, settled} <- settle(value, mod, o), do: {:ok, settled, rest}
  end

  @spec settle(value() | deferred(), module(), Opts.t()) :: outcome()
  defp settle({:lazy, op, left, right}, mod, o), do: mod.combine(op, left, right, o)
  defp settle(value, _mod, _o), do: {:ok, value}

  @spec defer(binary(), value(), value(), module(), Opts.t()) :: outcome() | {:ok, deferred()}
  defp defer(op, left, right, _mod, %Opts{lazy: last}) when last != nil,
    do: {:ok, {:lazy, op, left, right}}

  defp defer(op, left, right, mod, o), do: mod.combine(op, left, right, o)

  defp sum(tokens, mod, o) do
    with {:ok, left, rest} <- product(tokens, mod, o),
         do: more(rest, left, ["+", "-"], &product/3, mod, o)
  end

  defp product(tokens, mod, o) do
    with {:ok, left, rest} <- factor(tokens, mod, o),
         do: more(rest, left, ["*", "/"], &factor/3, mod, o)
  end

  defp more([{:raw, op} | rest] = tokens, left, ops, next, mod, o) do
    if op in ops do
      with {:ok, left} <- settle(left, mod, o),
           {:ok, right, after_right} <- next.(rest, mod, o),
           {:ok, right} <- settle(right, mod, o),
           {:ok, value} <- defer(op, left, right, mod, o),
           do: more(after_right, value, ops, next, mod, o)
    else
      {:ok, left, tokens}
    end
  end

  defp more(tokens, left, _ops, _next, _mod, _o), do: {:ok, left, tokens}

  # A sign directly before a number is part of the literal (`-9223372036854775808` is the
  # lowest integer); before anything else it applies to the value.
  defp factor([{:raw, sign}, {:number, text} | rest], mod, o) when sign in ["-", "+"] do
    with {:ok, value} <- mod.number(text, if(sign == "-", do: -1, else: 1), o),
         do: {:ok, value, rest}
  end

  defp factor([{:raw, "-"} | rest], mod, o) do
    with {:ok, value, after_value} <- factor(rest, mod, o),
         {:ok, value} <- settle(value, mod, o),
         {:ok, negated} <- mod.negate(value, o),
         do: {:ok, negated, after_value}
  end

  defp factor([{:raw, "+"} | rest], mod, o), do: factor(rest, mod, o)

  defp factor([{:raw, "("} | rest], mod, o) do
    case sum(rest, mod, o) do
      {:ok, value, [{:raw, ")"} | after_group]} -> {:ok, value, after_group}
      {:error, _why} = error -> error
      _unread -> :unread
    end
  end

  defp factor([{:number, text} | rest], mod, o) do
    with {:ok, value} <- mod.number(text, 1, o), do: {:ok, value, rest}
  end

  defp factor([{:ident, name}, {:raw, "("} | rest], mod, %Opts{calls: true} = o) do
    with :ok <- mod.enter(name, o),
         {:ok, values, after_call} <- arguments(rest, mod, o, []),
         {:ok, value} <- mod.call(name, values, o),
         do: {:ok, value, after_call}
  end

  defp factor(tokens, mod, o), do: mod.leaf(tokens, o)

  # The arguments of a call up to its closing parenthesis (a call with none is `[]`). Only `,`
  # or `)` follows an argument, and none is missing (`abs(,1)`, `abs(1,)`, `abs(1 (2))`):
  # `InfluxQLArgs` fails the statement as the engine's parser does before it is planned. Tokens
  # that are no arithmetic (`abs(n > 1)`) are unread, and the caller passes over the call.
  defp arguments([{:raw, ")"} | rest], _mod, _o, []), do: {:ok, [], rest}

  defp arguments(tokens, mod, o, acc) do
    with {:ok, value, rest} <- sum(tokens, mod, o),
         {:ok, value} <- settle(value, mod, o),
         do: separated(rest, value, mod, o, acc)
  end

  defp separated([{:raw, ","} | rest], value, mod, o, acc),
    do: arguments(rest, mod, o, [value | acc])

  defp separated([{:raw, ")"} | rest], value, _mod, _o, acc),
    do: {:ok, Enum.reverse([value | acc]), rest}

  defp separated(_tokens, _value, _mod, _o, _acc), do: :unread
end
