defmodule InfluxElixir.Client.Local.InfluxQLFold do
  @moduledoc false
  # The type of the arithmetic on one side of a comparison, as the engine types it (verified
  # over every pair of operands and 3,000 chains of three, against InfluxDB 3 Core). It is the
  # one typer of arithmetic in the double: `InfluxQLWhereArith`, `InfluxQLNested`,
  # `InfluxQLCalls` and `InfluxQLTyped` ask it, and `walk/2` is the one precedence walker
  # (`sum`, `product`, `factor`, signs, parentheses and calls) that they all run their own
  # handlers over.
  #
  # A column the measurement lacks is `:unknown`. The kinds that are no type of the engine's:
  #
  #   | kind       | what it is                                                           |
  #   |------------|----------------------------------------------------------------------|
  #   | `:unknown` | a column the measurement lacks                                       |
  #   | `:nn`      | a null number of the type an integer makes (a "null number")        |
  #   | `:nnf`     | a null number of the type a float makes (a "null number, float")    |
  #   | `:nz`      | a null of its own: two operands that are no numbers (`'x' + 1`)    |
  #   | `false`    | the constant false, a boolean that is no null (`nosuch + 'x'`)     |
  #   | `{:udiv, left, right}` | an unsigned number divided by text, or text by one      |
  #   | `{:pending, body}` | a planning error that a null beside it takes away          |
  #
  # The rules are about the types of the two operands, whatever the operator (`+ - * /`):
  #
  #   * `:unknown` beside a number is a null number (`:nn`, `:nnf` for a float), beside the
  #     time, a string, a tag, a boolean or a duration the constant `false` (`nosuch + 'x' =
  #     ok` keeps the points `ok` is false for), beside an unknown a null number
  #   * a null number and `false` keep to that: a number leaves them null, text, a boolean, a
  #     duration or the time make them `false` again; two operands that are no numbers and no
  #     column or not (`false` beside text, `'x' + 1`, `s * n`) are a null of their own (`:nz`)
  #     that behaves as the null number but for an unsigned number
  #   * the engine's coercion errors come from the types: the time beside anything but a
  #     duration or an unknown, an unsigned number beside text, a boolean, a tag or a duration,
  #     a tag beside a string under `+` (`Dictionary(Int32, Utf8) + Utf8`), in the order written
  #   * an unsigned number divided by text is `{:udiv, ...}`: unsigned alone (the comparison's
  #     or the connective's error beside a boolean), null beside a null or a float, and the
  #     coercion error of the division in any other arithmetic after it; text or the time
  #     divided by an unsigned number is the same. An unsigned number divided by a boolean, the
  #     time or a duration is the error of comparing that operand with `UInt64`. Such an error
  #     is `{:pending, body}` until the arithmetic is done: a null beside it takes it away
  #     (`nosuch2 - u / b = ok` keeps no point), a comparison raises it
  #   * a math function is a float (an `abs()` of an integer an integer; of a boolean, a string,
  #     a tag or the time the engine's planning error)
  #
  # What the rules above do not tell (an unsigned number beside a null of its own that is not a
  # column, a sign before the duration) is `:unread`: the caller answers as it did before, or
  # refuses.

  alias InfluxElixir.Client.Local.{InfluxQLError, InfluxQLExpr, InfluxQLText, InfluxQLTokens}
  alias InfluxElixir.Client.Local.SQLLimits

  require SQLLimits

  @typedoc "What arithmetic comes to."
  @type kind ::
          :unknown
          | :nn
          | :nnf
          | :nz
          | false
          | :integer
          | :float
          | :unsigned
          | :string
          | :tag
          | :boolean
          | :duration
          | :timestamp
          | {:udiv, kind(), kind()}
          | {:pending, binary()}

  @typedoc "The columns of the measurement: its tags and the types of its fields."
  @type ctx :: {MapSet.t(binary()), map()}

  @typedoc "What a handler of the walker answers."
  @type outcome :: {:ok, term()} | :unread | {:error, term()}

  @numbers [:integer, :float, :unsigned]
  @nulls [:unknown, :nn, :nnf, :nz]
  @non_numeric [:string, :tag, :boolean, :duration, false]

  # (The false is a boolean to the engine.)
  @arrow %{
    false => "Boolean",
    integer: "Int64",
    unsigned: "UInt64",
    float: "Float64",
    string: "Utf8",
    boolean: "Boolean",
    tag: "Dictionary(Int32, Utf8)",
    timestamp: "Timestamp(ns)",
    duration: "Interval(MonthDayNano)"
  }

  @native %{
    false => "Boolean",
    string: "String",
    boolean: "Boolean",
    tag: "String",
    timestamp: "Timestamp(Nanosecond, None)",
    duration: "Interval(MonthDayNano)"
  }

  # What an unsigned number divides when it is the divisor: the time and the kinds that are no
  # numbers.
  @udiv_dividends [:timestamp | @non_numeric]

  # What an unsigned number divided is compared with `UInt64` at once.
  @divisors [:boolean, false, :timestamp, :duration]

  @signature "You might need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"

  # What two nulls come to, the first kind down the left and the second across: a null number
  # of the type a float makes when either is one, a null of its own beside the other nulls but
  # a null number, which the double does not tell (`:unread`).
  #
  #   | first \ second | `:unknown` | `:nn`     | `:nnf`    | `:nz`     |
  #   |----------------|-----------|-----------|-----------|-----------|
  #   | `:unknown`     | `:nn`     | `:nn`     | `:nnf`    | `:nz`     |
  #   | `:nn`          | `:nn`     | `:nn`     | `:nnf`    | `:unread` |
  #   | `:nnf`         | `:nnf`    | `:nnf`    | `:nnf`    | `:unread` |
  #   | `:nz`          | `:nz`     | `:unread` | `:unread` | `:nz`     |
  @null_pairs %{
    {:unknown, :unknown} => :nn,
    {:unknown, :nn} => :nn,
    {:unknown, :nnf} => :nnf,
    {:unknown, :nz} => :nz,
    {:nn, :unknown} => :nn,
    {:nn, :nn} => :nn,
    {:nn, :nnf} => :nnf,
    {:nn, :nz} => :unread,
    {:nnf, :unknown} => :nnf,
    {:nnf, :nn} => :nnf,
    {:nnf, :nnf} => :nnf,
    {:nnf, :nz} => :unread,
    {:nz, :unknown} => :nz,
    {:nz, :nn} => :unread,
    {:nz, :nnf} => :unread,
    {:nz, :nz} => :nz
  }

  # What an unsigned number comes to beside a null (the first column) of each kind.
  @null_beside_unsigned %{unknown: :unknown, nz: :nz, nn: :unsigned, nnf: :nz}

  # ---------------------------------------------------------------------------
  # The kinds
  # ---------------------------------------------------------------------------

  @doc "Whether a kind is a null (a column the measurement lacks, or a null made of operands)."
  @spec null?(term()) :: boolean()
  def null?(kind), do: kind in @nulls

  @doc """
  The kind of the number written `text` behind a sign (`-1` or `1`): `:integer`, `:unsigned`
  (past the signed range; the lowest signed integer is the literal one past the highest behind
  a minus sign) or `:float`. (The lexer refuses an integer past the unsigned range before a
  condition is read.)
  """
  @spec number_kind(binary(), 1 | -1) :: :integer | :unsigned | :float
  def number_kind(text, sign) do
    case Integer.parse(text) do
      {n, ""} when sign * n >= SQLLimits.int64_min() and sign * n <= SQLLimits.int64_max() ->
        :integer

      {_n, ""} ->
        :unsigned

      _fraction ->
        :float
    end
  end

  @doc "The Arrow type the engine names a kind of operand by."
  @spec arrow(atom() | false) :: binary()
  def arrow(kind), do: Map.fetch!(@arrow, kind)

  @doc """
  The planning error for arithmetic the engine cannot coerce, worded with the Arrow type of
  each operand as written (`UInt64 + Utf8`).
  """
  @spec coercion_body(atom() | false, binary(), atom() | false) :: binary()
  def coercion_body(left, op, right) do
    "Error during planning: Cannot coerce arithmetic expression " <>
      "#{arrow(left)} #{op} #{arrow(right)} to valid types"
  end

  @doc """
  Raises the first planning error among the results of `kind/3` (thrown as the refusals of the
  planner are: `{:refused, {:engine, 400, body}}`, or `{:late, body}` for the error of a division
  that waits for the comparisons around it), `:ok` when there is none. The one place a coercion
  error is raised, whoever asked for the types.
  """
  @spec raise_coercion([term()]) :: :ok
  def raise_coercion(results) do
    case Enum.find(results, &match?({kind, _body} when kind in [:error, :late], &1)) do
      nil -> :ok
      {:error, body} -> throw({:refused, {:engine, 400, body}})
      {:late, body} -> throw({:late, body})
    end
  end

  # ---------------------------------------------------------------------------
  # The walker
  # ---------------------------------------------------------------------------

  @typedoc """
  The handlers of `walk/2`: `:number` (the text of a number behind a sign, `1` or `-1`),
  `:leaf` (the tokens from a name, a string, a duration or a word: the value and what is
  left), `:combine` (an operator over two values), `:negate`, and for a call `:enter` (the
  name, before the arguments are read) and `:call` (the name and the values of the
  arguments). Each answers `{:ok, value}`, `:unread` or `{:error, why}`.
  """
  @type handlers :: %{
          required(:number) => (binary(), 1 | -1 -> outcome()),
          required(:leaf) => (list() -> {:ok, term(), list()} | :unread | {:error, term()}),
          required(:combine) => (binary(), term(), term() -> outcome()),
          required(:negate) => (term() -> outcome()),
          optional(:enter) => (binary() -> :ok | :unread | {:error, term()}),
          optional(:call) => (binary(), [term()] -> outcome())
        }

  @doc """
  Reads a sum from the tokens (`sum := product (("+" | "-") product)*`, `product := factor
  (("*" | "/") factor)*`, `factor := sign factor | "(" sum ")" | number | call | leaf`) with
  one precedence for all of them. Returns the value and the tokens left, `:unread` when the
  tokens are no arithmetic, or the error a handler gave. One pass: nothing is read twice.
  """
  @spec walk(list(), handlers()) :: {:ok, term(), list()} | :unread | {:error, term()}
  def walk(tokens, handlers), do: sum(tokens, handlers)

  @doc "`walk/2` for a single factor: a call, a group, a sign and its operand, or a leaf."
  @spec operand(list(), handlers()) :: {:ok, term(), list()} | :unread | {:error, term()}
  def operand(tokens, handlers), do: factor(tokens, handlers)

  defp sum(tokens, h) do
    with {:ok, left, rest} <- product(tokens, h), do: more(rest, left, ["+", "-"], &product/2, h)
  end

  defp product(tokens, h) do
    with {:ok, left, rest} <- factor(tokens, h), do: more(rest, left, ["*", "/"], &factor/2, h)
  end

  defp more([{:raw, op} | rest] = tokens, left, ops, next, h) do
    if op in ops do
      with {:ok, right, after_right} <- next.(rest, h),
           {:ok, value} <- h.combine.(op, left, right),
           do: more(after_right, value, ops, next, h)
    else
      {:ok, left, tokens}
    end
  end

  defp more(tokens, left, _ops, _next, _h), do: {:ok, left, tokens}

  # A sign directly before a number is part of the literal (`-9223372036854775808` is the
  # lowest integer); before anything else it applies to the value.
  defp factor([{:raw, sign}, {:number, text} | rest], h) when sign in ["-", "+"] do
    with {:ok, value} <- h.number.(text, if(sign == "-", do: -1, else: 1)),
         do: {:ok, value, rest}
  end

  defp factor([{:raw, "-"} | rest], h) do
    with {:ok, value, after_value} <- factor(rest, h),
         {:ok, negated} <- h.negate.(value),
         do: {:ok, negated, after_value}
  end

  defp factor([{:raw, "+"} | rest], h), do: factor(rest, h)

  defp factor([{:raw, "("} | rest], h) do
    case sum(rest, h) do
      {:ok, value, [{:raw, ")"} | after_group]} -> {:ok, value, after_group}
      {:error, _why} = error -> error
      _unread -> :unread
    end
  end

  defp factor([{:number, text} | rest], h) do
    with {:ok, value} <- h.number.(text, 1), do: {:ok, value, rest}
  end

  defp factor([{:ident, name}, {:raw, "("} | rest], %{call: call, enter: enter} = h) do
    with :ok <- enter.(name),
         {:ok, values, after_call} <- arguments(rest, h),
         {:ok, value} <- call.(name, values),
         do: {:ok, value, after_call}
  end

  defp factor(tokens, h), do: h.leaf.(tokens)

  # The arguments of a call up to its closing parenthesis (a call with none is `[]`). Only `,`
  # or `)` follows an argument, and none is missing (`abs(,1)`, `abs(1,)`, `abs(1 (2))`):
  # `InfluxQLArgs` fails the statement as the engine's parser does before it is planned.
  defp arguments([{:raw, ")"} | rest], _h), do: {:ok, [], rest}
  defp arguments(tokens, h), do: arguments(tokens, h, [])

  defp arguments(tokens, h, acc) do
    with {:ok, value, rest} <- sum(tokens, h), do: separated(rest, value, h, acc)
  end

  defp separated([{:raw, ","} | rest], value, h, acc), do: arguments(rest, h, [value | acc])

  defp separated([{:raw, ")"} | rest], value, _h, acc),
    do: {:ok, Enum.reverse([value | acc]), rest}

  # ---------------------------------------------------------------------------
  # The kind of arithmetic
  # ---------------------------------------------------------------------------

  @typedoc """
  What `kind/3` is asked: `bare` says that the whole condition is one `abs()` call (its error is
  worded without the signature); `mode` how the quotient of an unsigned number and text is
  read (see `divided/4`): `:loose` as the comparison with a boolean and the bare operand beside
  a connective read it, `:strict` as a plain comparison does (the quotient alone, or beside a
  float, is the coercion error of the division), `:alone` as the whole condition does (the
  quotient is the coercion error beside text, too).
  """
  @type opts :: [bare: boolean(), mode: mode()]

  @typedoc """
  How the quotient of an unsigned number and text is read: `:loose` beside a boolean (null beside
  a float, unsigned alone), `:text` beside a string or a tag (null beside a float, the division's
  error alone), `:strict` beside a number (the division's error beside a float and alone),
  `:alone` as the whole condition.
  """
  @type mode :: :loose | :text | :strict | :alone

  @doc """
  The kind of the arithmetic `tokens` make, `{:ok, kind}`, `:unread`, or `{:error, body}`, the
  planner's error for arithmetic the engine cannot coerce or type. The error of a division the
  quotient is left with (`{:late, body}`) is raised after the errors of the comparisons around
  it (verified: `t / u = 1 OR t / u = ok` is the second comparison's, `UInt64 = Boolean`).
  """
  @spec kind(list(), ctx(), opts()) ::
          {:ok, kind()} | :unread | {:error, binary()} | {:late, binary()}
  def kind(tokens, ctx, opts \\ []) do
    mode = Keyword.get(opts, :mode, :loose)
    tokens |> walked(ctx, opts, mode) |> settled(mode)
  end

  # The whole condition on its own (`:alone`) is read as a comparison with a number reads its
  # operands, and the last operation alone: an operation waits (`{:lazy, op, left, right}`)
  # until it is the operand of another, and the one that is left at the end is the last.
  # (`time + 1h * (u / s)` is `Interval * UInt64`, and `1h * (u / s)` the division's.)
  defp walked(tokens, ctx, opts, :alone) do
    handlers = ctx |> typer(Keyword.put(opts, :mode, :strict)) |> waiting()

    case walk(tokens, handlers) do
      {:ok, {:lazy, op, left, right}, []} -> combined(combine(op, left, right, :alone))
      other -> other
    end
  end

  defp walked(tokens, ctx, opts, mode),
    do: walk(tokens, typer(ctx, Keyword.put(opts, :mode, mode)))

  defp combined({:ok, kind}), do: {:ok, kind, []}
  defp combined(other), do: other

  # The handlers with every operation put off until its value is used.
  defp waiting(handlers) do
    settle = fn
      {:lazy, op, left, right} -> handlers.combine.(op, left, right)
      kind -> {:ok, kind}
    end

    %{
      handlers
      | combine: fn op, left, right ->
          with {:ok, left} <- settle.(left),
               {:ok, right} <- settle.(right),
               do: {:ok, {:lazy, op, left, right}}
        end,
        negate: fn value ->
          with {:ok, kind} <- settle.(value), do: handlers.negate.(kind)
        end,
        call: fn name, arguments ->
          case settle_all(arguments, settle) do
            {:ok, kinds} -> handlers.call.(name, kinds)
            error -> error
          end
        end
    }
  end

  defp settle_all(arguments, settle) do
    arguments
    |> Enum.reduce_while({:ok, []}, fn argument, {:ok, acc} ->
      case settle.(argument) do
        {:ok, kind} -> {:cont, {:ok, [kind | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, kinds} -> {:ok, Enum.reverse(kinds)}
      error -> error
    end
  end

  defp settled({:ok, {:udiv, left, right}, []}, mode) do
    if mode == :loose,
      do: {:ok, :unsigned},
      else: {:late, coercion_body(left, "/", right)}
  end

  defp settled({:ok, {:pending, body}, []}, _mode), do: {:late, body}
  defp settled({:ok, kind, []}, _mode), do: {:ok, kind}
  defp settled({:error, _body} = error, _mode), do: error
  defp settled(_unread, _mode), do: :unread

  @doc "The handlers of `walk/2` that type arithmetic; `InfluxQLCalls` replaces the calls."
  @spec typer(ctx(), opts()) :: handlers()
  def typer({tags, types}, opts) do
    bare = Keyword.get(opts, :bare, false)
    mode = Keyword.get(opts, :mode, :loose)

    %{
      number: fn text, sign -> {:ok, number_kind(text, sign)} end,
      leaf: &leaf(&1, tags, types),
      combine: &combine(&1, &2, &3, mode),
      negate: &negate/1,
      enter: &enter/1,
      call: &call(&1, &2, bare)
    }
  end

  defp leaf([{:str, _content} | rest], _tags, _types), do: {:ok, :string, rest}
  defp leaf([{:duration, _total, _text} | rest], _tags, _types), do: {:ok, :duration, rest}

  defp leaf([{:raw, word} | rest], _tags, _types) do
    if String.upcase(word) in ["TRUE", "FALSE"], do: {:ok, :boolean, rest}, else: :unread
  end

  defp leaf([{:ident, name} = token | rest], tags, types) do
    cond do
      InfluxQLTokens.time?(token) -> {:ok, :timestamp, rest}
      MapSet.member?(tags, name) -> {:ok, :tag, rest}
      InfluxQLExpr.absent?(name, types, tags) -> {:ok, :unknown, rest}
      true -> {:ok, Map.fetch!(types, name), rest}
    end
  end

  defp leaf(_tokens, _tags, _types), do: :unread

  defp enter(name), do: if(InfluxQLText.math_function?(name), do: :ok, else: :unread)

  # A math function is a float; `abs()` of a number keeps its type.
  defp call(name, [argument], bare) do
    if String.downcase(name) == "abs", do: abs_call(argument, bare), else: {:ok, :float}
  end

  defp call(_name, _arguments, _bare), do: {:ok, :float}

  @doc """
  What `abs()` of a value of `kind` comes to: a number keeps its type, a column the measurement
  lacks (or a null) is a float, a boolean, a string, a tag, a duration or the time is the engine's
  planning error (`bare` when the call is the whole condition), the quotient of an unsigned
  number and text the coercion error of the division.
  """
  @spec abs_call(term(), boolean()) :: {:ok, kind()} | {:error, binary()}
  def abs_call(kind, _bare) when kind in @numbers, do: {:ok, kind}
  def abs_call(kind, _bare) when kind in [:nn, :nnf, :nz], do: {:ok, kind}
  def abs_call({:udiv, left, right}, _bare), do: coerce(left, "/", right)
  def abs_call({:pending, body}, _bare), do: {:error, body}

  def abs_call(kind, bare) do
    case Map.fetch(@native, kind) do
      {:ok, native} -> {:error, abs_body(kind, native, bare)}
      :error -> {:ok, :float}
    end
  end

  defp abs_body(kind, native, bare) do
    "Error during planning: Function 'abs' expects NativeType::Numeric but received " <>
      "NativeType::#{native}" <>
      if(bare,
        do: "",
        else:
          " No function matches the given name and argument types " <>
            "'abs(#{arrow(kind)})'. " <> @signature
      )
  end

  @doc "The signature the engine lists for a call of `abs()` it cannot plan."
  @spec signature() :: binary()
  def signature, do: @signature

  # A sign before a column the measurement lacks is a null integer (verified: `-nosuch * u` is
  # the planner's error beside a boolean, where `nosuch * u` is a null).
  defp negate(:unknown), do: {:ok, :nn}

  defp negate(kind) when kind in @numbers or kind in [:nn, :nnf, :nz, :duration], do: {:ok, kind}

  # The engine cannot negate a string, a tag, a boolean column or the false: the sign leaves a
  # null of its own (verified: `'x' * -s` is `false` beside `ok`, `1 * -s` a null;
  # `-(nosuch + 'x') + 'x' = ok` keeps the points `ok` is false for, `-(nosuch + 'x') = ok`
  # none). (A constant of these is a parse error.)
  defp negate(kind) when kind in [:string, :tag, :boolean, false], do: {:ok, :nz}

  defp negate({:udiv, left, right}), do: pending(left, right)
  defp negate({:pending, _body} = error), do: {:ok, error}

  # `-time` is `-1 * time` (verified for `-(time)` and `-(time + 1h)`).
  defp negate(:timestamp), do: coerce(:integer, "*", :timestamp)

  # ---------------------------------------------------------------------------
  # Two operands
  # ---------------------------------------------------------------------------

  @spec combine(binary(), kind(), kind(), mode()) ::
          {:ok, kind()} | :unread | {:error, binary()}
  defp combine(op, left, right, mode) when is_tuple(left) or is_tuple(right),
    do: divided(op, left, right, mode)

  defp combine(op, left, right, _strict) do
    cond do
      left in @nulls and right in @nulls -> nulls(left, right)
      left in @nulls -> with_null(left, right)
      right in @nulls -> with_null(right, left)
      true -> known(op, left, right)
    end
  end

  # The quotient of an unsigned number and text, beside another operand (verified over every
  # kind of it):
  #
  #   * a null: null (`-nosuch + u / s`, `(-s) + u / s`), whatever the comparison is
  #   * a float: null when the other side of the comparison is no number (`u / s + 1.5 = ok`,
  #     `= 'x'`: `:loose`, `:text`), the coercion error of the division elsewhere (`:strict`)
  #   * the false, text, a boolean, a tag, a duration or the time: the unsigned number it is,
  #     in the order written (`u / s + 'x' = 1` is `UInt64 + Utf8`), except when the quotient is
  #     the whole condition (`:alone`: `t + (u / s)` is the coercion error of the division)
  #   * any other number, or another quotient: the coercion error of the division
  #
  # A quotient is `{:udiv, ...}` or an error that is `{:pending, ...}`: they read alike.
  defp divided(_op, left, right, _mode) when is_tuple(left) and is_tuple(right),
    do: {:ok, {:pending, quotient_error(left)}}

  defp divided(op, quotient, other, mode) when is_tuple(quotient) do
    case beside_quotient(other, mode) do
      :null ->
        {:ok, :nz}

      :unsigned when op == "/" and other in [:string, :tag] ->
        {:ok, {:pending, quotient_error(quotient)}}

      :unsigned ->
        combine(op, :unsigned, other, mode)

      :division when op == "/" and other in @divisors ->
        combine(op, :unsigned, other, mode)

      :division ->
        {:ok, {:pending, quotient_error(quotient)}}
    end
  end

  # (A quotient that is divided is the coercion error of the first division, whatever divides.)
  defp divided(op, other, quotient, mode) do
    case beside_quotient(other, mode) do
      :null -> {:ok, :nz}
      :unsigned when op == "/" -> {:ok, {:pending, quotient_error(quotient)}}
      :unsigned -> combine(op, other, :unsigned, mode)
      :division -> {:ok, {:pending, quotient_error(quotient)}}
    end
  end

  defp quotient_error({:udiv, left, right}), do: coercion_body(left, "/", right)
  defp quotient_error({:pending, body}), do: body

  defp pending(left, right), do: {:ok, {:pending, coercion_body(left, "/", right)}}

  defp beside_quotient(other, _mode) when other in @nulls, do: :null
  defp beside_quotient(:float, mode) when mode in [:loose, :text], do: :null

  defp beside_quotient(other, mode)
       when mode != :alone and (other in @non_numeric or other == :timestamp),
       do: :unsigned

  defp beside_quotient(_other, _mode), do: :division

  # The kinds that are a null beside one another.
  defp nulls(left, right) do
    case Map.fetch!(@null_pairs, {left, right}) do
      :unread -> :unread
      kind -> {:ok, kind}
    end
  end

  # A null number is a float when a float or a float null makes it. (A division does not: the
  # quotient of a null and an integer is a null integer, unsigned beside an unsigned number;
  # verified: `(nosuch / 1) + u = ok` is the planner's error, `(nosuch * 1.5) + u = ok` no row.)
  defp null_number(null, kind),
    do: if(:float in [null, kind] or null == :nnf, do: :nnf, else: :nn)

  # A null beside a known operand. (An unsigned number beside a column the measurement lacks
  # stays that column and beside a null of its own leaves it so; beside a null integer it is an
  # unsigned null, the planner's error beside a boolean, and beside a float null a null of its
  # own.)
  defp with_null(null, :unsigned), do: {:ok, Map.fetch!(@null_beside_unsigned, null)}
  defp with_null(:nz, kind) when kind in @numbers, do: {:ok, :nz}
  defp with_null(null, kind) when kind in @numbers, do: {:ok, null_number(null, kind)}
  defp with_null(_null, kind) when kind in @non_numeric or kind == :timestamp, do: {:ok, false}

  defp known("/", :unsigned, right) when right in @divisors,
    do: {:ok, {:pending, comparison_body(right)}}

  defp known("/", left, :unsigned) when left in @udiv_dividends,
    do: {:ok, {:udiv, left, :unsigned}}

  defp known("/", :unsigned, right) when right in [:string, :tag],
    do: {:ok, {:udiv, :unsigned, right}}

  defp known(op, left, right) do
    cond do
      left == :timestamp or right == :timestamp -> with_time(op, left, right)
      left == :duration and right == :duration -> durations(op)
      left in @numbers and right in @numbers -> {:ok, number(op, left, right)}
      uncoercible?(left, right) -> coerce(left, op, right)
      true -> text(op, left, right)
    end
  end

  # Dividing an unsigned number by a boolean, the time or a duration is the planner's error of
  # comparing that operand with `UInt64` (verified, whatever the comparison and in a bare
  # condition: `u / b = 1`, `u / time`, `u / 1h > b`).
  defp comparison_body(right) do
    "Error during planning: Cannot infer common argument type for comparison operation " <>
      "#{arrow(right)} = UInt64"
  end

  # Two operands that are text, booleans, durations or numbers beside them: a tag beside a string
  # under `+` is the planner's error, a string beside a string is concatenated, any other pair
  # makes a null.
  defp text("+", :tag, :string), do: coerce(:tag, "+", :string)
  defp text("+", :string, :tag), do: coerce(:string, "+", :tag)
  defp text("+", :string, :string), do: {:ok, :string}
  defp text(_op, _left, _right), do: {:ok, :nz}

  # Two durations are summed or subtracted; the engine has no product or quotient of them.
  defp durations(op) when op in ["+", "-"], do: {:ok, :duration}
  defp durations(op), do: temporal(:duration, op)

  # A time and a duration are summed (in either order) or subtracted (the time first) to a time.
  # The difference of two times is a duration of its own (`Duration(ns)`) that the double does not
  # model: refused by name. The sum, product or quotient of two times is the engine's error, and
  # a time beside anything else is one the engine cannot coerce.
  defp with_time(op, :timestamp, :duration) when op in ["+", "-"], do: {:ok, :timestamp}
  defp with_time("+", :duration, :timestamp), do: {:ok, :timestamp}

  defp with_time("-", :timestamp, :timestamp),
    do: InfluxQLError.refuse("the difference of two timestamps")

  defp with_time(op, :timestamp, :timestamp), do: temporal(:timestamp, op)
  defp with_time(op, left, right), do: coerce(left, op, right)

  # An unsigned number beside text, a boolean, a tag, a duration or the false: the coercion
  # error in the order written (verified for `+ - *`; a division is `known/3`'s).
  defp uncoercible?(left, right),
    do:
      (left == :unsigned and right in @non_numeric) or
        (right == :unsigned and left in @non_numeric)

  # A division of integers is a float, but not beside an unsigned number (verified: `1 / u` and
  # `u / u` are unsigned, `u / 2.5` a float).
  defp number(op, left, right) do
    cond do
      left == :float or right == :float -> :float
      left == :unsigned or right == :unsigned -> :unsigned
      op == "/" -> :float
      true -> :integer
    end
  end

  defp coerce(left, op, right), do: {:error, coercion_body(left, op, right)}

  # The planner's error for the sum, product or quotient of two times or two durations.
  defp temporal(kind, op) do
    type = arrow(kind)
    word = if kind == :timestamp, do: "timestamp", else: "interval"

    {:error,
     "Error during planning: Cannot get result type for temporal operation " <>
       "#{type} #{op} #{type}: Invalid argument error: Invalid #{word} arithmetic " <>
       "operation: #{type} #{op} #{type}"}
  end
end
