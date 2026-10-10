defmodule InfluxElixir.Client.Local.InfluxQLWalk do
  @moduledoc false
  # The one precedence walker of the arithmetic of a condition, over a module that gives the
  # values (`InfluxQLArithType` types them, `InfluxQLTyped` folds constants,
  # `InfluxQLTimeComparand` prints them):
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
  # A module may put off the last operation of the expression until the walk ends (`lazy/1`)
  # and combine it with the options that callback gives, where the others are combined with
  # those it was asked with (an operation is settled as soon as an operator, a sign or a comma
  # follows it, or it is an argument: only the last operation of the whole condition is the
  # condition's own, see `InfluxQLArithType`).

  defmodule Opts do
    @moduledoc false
    # What a walk is asked, handed to every callback:
    #
    #   * `ctx`: what the module reads columns from (`InfluxQLArithType` and
    #     `InfluxQLTimeComparand` give it the tags and the types of the fields of the
    #     measurement)
    #   * `calls`: whether a name followed by a parenthesis is a call (a walk of constants has
    #     none)
    #   * `state`: the module's own, which the walker passes on and never reads
    #     (`InfluxQLArithType` keeps how it reads a quotient there, and the flags of a call)

    @type t :: %__MODULE__{ctx: term(), calls: boolean(), state: term()}

    # `nil` for a walk that reads no column (the constants of `InfluxQLTyped`).
    defstruct ctx: nil, calls: true, state: nil
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

  @doc """
  A group (`(sum)`) that has been read: the value it comes to. A module that prints its values
  makes the parentheses part of it; without the callback the group is the value inside.
  """
  @callback group(value(), Opts.t()) :: outcome()

  @doc """
  `nil`, or the options to combine the last operation of an expression with, which is put off
  until the walk knows it is the last (see above).
  """
  @callback lazy(Opts.t()) :: nil | Opts.t()

  @optional_callbacks enter: 2, call: 3, group: 2, lazy: 1

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

  # The last operation is combined with the options of the walk's end; any other value is
  # settled.
  @spec finish(value() | deferred(), list(), module(), Opts.t()) :: result()
  defp finish({:lazy, op, left, right}, [], mod, o) do
    with {:ok, value} <- mod.combine(op, left, right, mod.lazy(o)), do: {:ok, value, []}
  end

  defp finish(value, rest, mod, o) do
    with {:ok, settled} <- settle(value, mod, o), do: {:ok, settled, rest}
  end

  @spec settle(value() | deferred(), module(), Opts.t()) :: outcome()
  defp settle({:lazy, op, left, right}, mod, o), do: mod.combine(op, left, right, o)
  defp settle(value, _mod, _o), do: {:ok, value}

  @spec defer(binary(), value(), value(), module(), Opts.t()) :: outcome() | {:ok, deferred()}
  defp defer(op, left, right, mod, o) do
    if lazy?(mod, o),
      do: {:ok, {:lazy, op, left, right}},
      else: mod.combine(op, left, right, o)
  end

  defp lazy?(mod, o), do: function_exported?(mod, :lazy, 1) and mod.lazy(o) != nil

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
      {:ok, value, [{:raw, ")"} | after_group]} -> grouped(value, after_group, mod, o)
      {:error, _why} = error -> error
      _unread -> :unread
    end
  end

  defp factor([{:number, text} | rest], mod, o) do
    with {:ok, value} <- mod.number(text, 1, o), do: {:ok, value, rest}
  end

  defp factor([{:ident, name}, {:raw, "("} | rest], mod, %Opts{calls: true} = o) do
    with :ok <- entered(mod, name, o),
         {:ok, values, after_call} <- arguments(rest, mod, o, []),
         {:ok, value} <- mod.call(name, values, o),
         do: {:ok, value, after_call}
  end

  defp factor(tokens, mod, o), do: mod.leaf(tokens, o)

  # (A module without `enter/2` takes every call.)
  defp entered(mod, name, o),
    do: if(function_exported?(mod, :enter, 2), do: mod.enter(name, o), else: :ok)

  # A group, as the module makes it of the value inside (the value itself, without `group/2`).
  defp grouped(value, after_group, mod, o) do
    if function_exported?(mod, :group, 2) do
      with {:ok, grouped} <- mod.group(value, o), do: {:ok, grouped, after_group}
    else
      {:ok, value, after_group}
    end
  end

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
