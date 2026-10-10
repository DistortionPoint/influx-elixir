defmodule InfluxElixir.Client.Local.InfluxQLArithType do
  @moduledoc false
  # The type of the arithmetic on one side of a comparison, as the engine types it (verified
  # over every pair of operands and 3,000 chains of three, against InfluxDB 3 Core). It is the
  # one typer of arithmetic in the double: `InfluxQLWhereArith`, `InfluxQLNested` and
  # `InfluxQLTyped` ask it. It is a module of the one precedence walker, `InfluxQLWalk`, which
  # reads the tokens once, left to right: the problems of the arithmetic and of the calls in it
  # (`abs()` is the only function) are found in the order they are written.
  #
  # A value is `%Value{kind, pending, named, literal, quotient, deferred}`:
  #
  #   * `kind` is what the arithmetic comes to (below)
  #   * `pending` is an error the value carries that is not raised yet, `nil` or `{class,
  #     body}`. It is the planner's error for a quotient that waits for the comparisons around it
  #     (`t / u = 1 OR t / u = ok` is the second comparison's) and that a null beside it takes
  #     away (`nosuch2 - u / b = ok` keeps no point): `erased_by_null?/1` is the one rule. The
  #     classes are `:quotient` (an unsigned number divided by text, or text by one: the number
  #     alone while it stands in a comparison with a boolean, the division's error elsewhere),
  #     `:division` (the division's coercion error) and `:comparison` (an unsigned number
  #     divided by a boolean, the time or a duration is the comparison of that operand with
  #     `UInt64`). A pending error is an unsigned number's, or a float's when a float made it
  #   * `named` is the type the engine names the value by in the signature of a call it is an
  #     argument of, when that is not its kind (the `abs()` of a null and a quotient beside a
  #     float are `Float64` there)
  #   * `literal` is whether the value is one number as written (`1`, `-1`, `(1)`), where
  #     `-(1)`, `abs(1)` and `1 + 2` are integer expressions: an integer expression beside the
  #     quotient of an unsigned number and text is the rewriter's error that no null takes away
  #     (`n + (u / s)`, `(u / s) < n`, but `2 + (u / s)` is the division's). It is raised at once,
  #     where the planner's errors below are not
  #   * `quotient` is whether the value is a float that the planner types as an integer: the
  #     quotient of integers (`n / 2`, `4 / 2`, `n / 2 * 3`, `abs(n / 2)`). Alone, the value
  #     is a float (`n / 2 = 1.5` holds), but beside an unsigned number the type of the
  #     quotient is the integer's (`u + n / 2` is an unsigned number, where `u + 2.5` is a
  #     float), so `u + n / 2 = b` is the planner's error of `UInt64 = Boolean`
  #   * `deferred` is the planning error of the operation or the call that made the value (the
  #     coercion of `u + 's'`, the signature of `abs(s)`), as a body. The planner raises it when
  #     the operation is an operand of another, which asks for the type of both operands in turn
  #     after it has built them, and for a call the errors of its arguments come first. So the
  #     errors come in an order of their own (verified: `(u + 's') + abs(s)` is the coercion but
  #     `(u + 's') + abs(s) * 2` the call, `abs(s) + -(u + b)` the coercion): an operation
  #     raises what its operands carry, left first, and carries its own. The last, the value of
  #     a side of a comparison, is raised by the comparison (`flush/1`)
  #
  # The kinds that are no type of the engine's:
  #
  #   | kind              | what it is                                                       |
  #   |-------------------|------------------------------------------------------------------|
  #   | `:unknown`        | a column the measurement lacks                                   |
  #   | `:nn`             | a null number of the type an integer makes (a "null number")     |
  #   | `:nnf`            | a null number of the type a float makes (a "null number, float") |
  #   | `:nz`             | a null of its own: two operands that are no numbers (`'x' + 1`)  |
  #   | `:false_constant` | the constant false, a boolean that is no null (`nosuch + 'x'`)   |
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
  #   * an unsigned number divided by text is a `:quotient` (see `divided/4` for what stands
  #     beside it); text or the time divided by an unsigned number is the same. An unsigned
  #     number divided by a boolean, the time or a duration is a `:comparison` error
  #   * a math function is a float (an `abs()` of an integer an integer; of a boolean, a string,
  #     a tag or the time the engine's planning error)
  #
  # What the rules above do not tell (an unsigned number beside a null of its own that is not a
  # column, a sign before the duration) is `:unread`: the caller answers as it did before, or
  # refuses.

  @behaviour InfluxElixir.Client.Local.InfluxQLWalk

  alias InfluxElixir.Client.Local.{
    InfluxQLError,
    InfluxQLExpr,
    InfluxQLTokens,
    InfluxQLWalk
  }

  alias InfluxElixir.Client.Local.InfluxQLWalk.Opts
  alias InfluxElixir.Client.Local.SQLLimits

  require SQLLimits

  defmodule Value do
    @moduledoc false
    # A value of the walk (see `InfluxQLArithType`).

    @type kind ::
            :unknown
            | :nn
            | :nnf
            | :nz
            | :false_constant
            | :integer
            | :float
            | :unsigned
            | :string
            | :tag
            | :boolean
            | :duration
            | :timestamp

    @type pending :: {:quotient | :division | :comparison, binary()}

    @type t :: %__MODULE__{
            kind: kind(),
            pending: nil | pending(),
            named: nil | kind(),
            literal: boolean(),
            quotient: boolean(),
            deferred: nil | binary()
          }

    @enforce_keys [:kind]
    defstruct [:kind, pending: nil, named: nil, literal: false, quotient: false, deferred: nil]
  end

  defmodule Config do
    @moduledoc false
    # What a walk of `InfluxQLArithType` is asked, the `state` of its `InfluxQLWalk.Opts`:
    #
    #   * `mode`: how the quotient of an unsigned number and text is read
    #   * `lazy`: `nil`, or the mode of the last operation, which is put off
    #   * `whole`: the condition is one call and nothing else (its error is worded without the
    #     signature the planner lists beside a call that is part of something)
    #   * `outermost`: the condition is a call with no arguments
    #   * `operand`: the condition has no comparison, it is a bare operand

    @type mode :: :loose | :text | :strict | :alone

    @type t :: %__MODULE__{
            mode: mode(),
            lazy: nil | mode(),
            whole: boolean(),
            outermost: boolean(),
            operand: boolean()
          }

    defstruct mode: :loose, lazy: nil, whole: false, outermost: false, operand: false
  end

  @typedoc "What arithmetic comes to."
  @type kind :: Value.kind()

  @typedoc "A value of the walk."
  @type value :: Value.t()

  @typedoc "The columns of the measurement: its tags and the types of its fields."
  @type ctx :: {MapSet.t(binary()), map()}

  @typedoc "What goes wrong with an expression: the engine's planning error, or a refusal."
  @type problem :: {:engine, binary()} | {:refuse, binary()}

  @typedoc """
  How the quotient of an unsigned number and text is read: `:loose` beside a boolean (null beside
  a float, unsigned alone), `:text` beside a string or a tag (null beside a float, the division's
  error alone), `:strict` beside a number (the division's error beside a float and alone),
  `:alone` as the whole condition (the division's error beside text, too).
  """
  @type mode :: Config.mode()

  @typedoc """
  What `kind/3` and `value/3` are asked: `mode` as above; `whole`, `outermost` and `operand` as
  `Config` (the flags of a call that is the whole condition, see `call_options/2`).
  """
  @type opts :: [
          mode: mode(),
          whole: boolean(),
          outermost: boolean(),
          operand: boolean()
        ]

  @numbers [:integer, :float, :unsigned]
  @nulls [:unknown, :nn, :nnf, :nz]
  # (The nulls arithmetic makes: a column the measurement lacks is a float to `abs()`.)
  @known_nulls [:nn, :nnf, :nz]
  @non_numeric [:string, :tag, :boolean, :duration, :false_constant]

  # (The false is a boolean to the engine.)
  @arrow %{
    false_constant: "Boolean",
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
    false_constant: "Boolean",
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
  @divisors [:boolean, :false_constant, :timestamp, :duration]

  # The classes of pending error that a null beside the value takes away.
  @erasable [:quotient, :division, :comparison]

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
  def null?(kind), do: kind in @nulls or kind == :abs_null

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

  @doc """
  Raises the first planning error among the results of `kind/3`, thrown as the refusals of the
  planner are (`{:refused, {:engine, 400, body}}`, or `{:late, class, body}` for the error of a quotient
  that waits for the comparisons around it, chosen by `pick_late/1`); `:ok` when there is none. The one place the error
  of a type is raised, whoever asked for the types. Of a pair (the two sides of a comparison) a
  late error is taken away by a null on the other side (`u / 1h > nosuch` keeps no point).
  """
  @spec raise_first_error([term()]) :: :ok
  def raise_first_error([left, right]),
    do: raise_first([erased(left, right), erased(right, left)])

  def raise_first_error(results), do: raise_first(results)

  defp raise_first(results) do
    case {Enum.find(results, &match?({:error, _body}, &1)),
          for({:late, class, body} <- results, do: {class, body})} do
      {{:error, body}, _lates} -> throw({:refused, {:engine, 400, body}})
      {nil, []} -> :ok
      {nil, lates} -> lates |> pick_late() |> throw_late()
    end
  end

  # Of several errors of quotients that wait, the engine raises the first of the comparisons of
  # an unsigned number with the wrong type (`(u / 1h) < (u / b)` is the duration's, `(u / s) <
  # (u / 1h)` too); else the first of the divisions that a sum, a product or a call made of a
  # quotient (`u + s / u = f OR b / u = f` is `Utf8 / UInt64`, `f + u / s > 1 AND u * (s / u) >
  # 1` is `UInt64 / Utf8`); else the last of the quotients themselves (`(b / u) < (u / s)` is
  # `UInt64 / Utf8`).
  @doc false
  @spec pick_late([{atom(), binary()}]) :: {atom(), binary()}
  def pick_late(lates) do
    Enum.find(lates, &match?({:comparison, _body}, &1)) ||
      Enum.find(lates, &match?({:division, _body}, &1)) || List.last(lates)
  end

  @doc false
  @spec throw_late({atom(), binary()}) :: no_return()
  def throw_late({class, body}), do: throw({:late, class, body})

  defp erased({:late, _class, _body}, {:ok, kind}) when kind in @nulls, do: {:ok, kind}
  defp erased(result, _other), do: result

  @doc """
  The rewriter's error for an integer expression beside an unsigned quotient across a comparison
  (`(u / s) < n`, `n > (u / b)`), thrown as `raise_first_error/1` throws; `:ok` for anything
  else. No null takes it away. `op` is the operator of the comparison.
  """
  @spec check_pair(value(), value(), binary()) :: :ok
  def check_pair(left, right, op) do
    if (unsigned_pending?(left) and integer_expression?(right)) or
         (unsigned_pending?(right) and integer_expression?(left)),
       do: throw({:refused, {:engine, 400, cannot_use(op)}}),
       else: :ok
  end

  defp pending?(%Value{pending: pending}), do: pending != nil

  # (The pending error of a float, one a float made, is no unsigned number to the rewriter.)
  defp unsigned_pending?(%Value{pending: pending, kind: kind}),
    do: pending != nil and kind == :unsigned

  defp integer_expression?(%Value{kind: :integer, literal: false, pending: nil}), do: true
  defp integer_expression?(_value), do: false

  defp cannot_use(op) do
    op = if op == "<>", do: "!=", else: op

    "Error during planning: cannot use #{op} between an integer and unsigned, " <>
      "an explicit cast is required"
  end

  defp arrow(kind), do: Map.fetch!(@arrow, kind)

  # The planning error for arithmetic the engine cannot coerce, worded with the Arrow type of
  # each operand as written (`UInt64 + Utf8`).
  defp coercion_body(left, op, right) do
    "Error during planning: Cannot coerce arithmetic expression " <>
      "#{arrow(left)} #{op} #{arrow(right)} to valid types"
  end

  # ---------------------------------------------------------------------------
  # Asking
  # ---------------------------------------------------------------------------

  @doc """
  The options of the calls of a condition `tokens` (see `Config`): a call that is
  the whole condition (`alone`: it is the whole `WHERE`, not a part of an `AND`, an `OR` or a
  group) is worded as the planner words a call that is the whole predicate (verified: a call
  that is part of something carries the signature, and a call with no arguments that is the
  whole condition is a coercion error of its own).
  """
  @spec call_options(list(), boolean()) :: opts()
  def call_options(tokens, alone) do
    stripped = InfluxQLTokens.strip_parens(tokens)
    whole? = alone and single_call?(stripped)

    [
      whole: whole?,
      outermost: whole? and match?([{:ident, _name}, {:raw, "("}, {:raw, ")"}], stripped),
      operand: not Enum.any?(tokens, &match?({:op, _op}, &1))
    ]
  end

  # Whether the tokens are one call and nothing else.
  defp single_call?([{:ident, _name}, {:raw, "("} | rest]),
    do: match?({_inside, []}, InfluxQLTokens.take_call(rest))

  defp single_call?(_tokens), do: false

  @doc """
  The value of the arithmetic `tokens` make, `{:ok, value}`, `:unread`, or `{:error, problem}`:
  the planner's error for arithmetic or a call it cannot type, or a refusal by name of a call
  the double does not compute. The first problem is the first in the text, but for the error
  of the last operation, which the value carries (`flush/1`).
  """
  @spec value(list(), ctx(), opts()) :: {:ok, value()} | :unread | {:error, problem()}
  def value(tokens, ctx, opts \\ []) do
    case InfluxQLWalk.walk(tokens, __MODULE__, options(ctx, opts)) do
      {:ok, value, []} -> {:ok, value}
      {:error, _problem} = error -> error
      _unread -> :unread
    end
  end

  # The walk of the whole condition on its own (`:alone`) reads its operands as a comparison with
  # a number does, and the last operation alone (`time + 1h * (u / s)` is `Interval * UInt64`,
  # and `1h * (u / s)` the division's).
  defp options(ctx, opts) do
    mode = Keyword.get(opts, :mode, :loose)

    %Opts{
      ctx: ctx,
      state: %Config{
        mode: if(mode == :alone, do: :strict, else: mode),
        lazy: if(mode == :alone, do: :alone),
        whole: Keyword.get(opts, :whole, false),
        outermost: Keyword.get(opts, :outermost, false),
        operand: Keyword.get(opts, :operand, false)
      }
    }
  end

  @doc """
  The kind of the arithmetic `tokens` make: `{:ok, kind}`, `:unread`, `{:error, body}` (the
  planner's error), or `{:late, body}` (the error of a quotient, raised after the errors of the
  comparisons around it, verified: `t / u = 1 OR t / u = ok` is the second comparison's,
  `UInt64 = Boolean`). A refusal by name is thrown, `{:refused, message}`.
  """
  @spec kind(list(), ctx(), opts()) ::
          {:ok, kind() | :abs_null} | :unread | {:error, binary()} | {:late, atom(), binary()}
  def kind(tokens, ctx, opts \\ []) do
    with {:ok, value} <- value(tokens, ctx, opts),
         {:ok, value} <- flush(value) do
      settled(value, Keyword.get(opts, :mode, :loose))
    else
      {:error, {:engine, body}} -> {:error, body}
      {:error, {:refuse, message}} -> throw({:refused, message})
      :unread -> :unread
    end
  end

  @doc """
  Whether the arithmetic `tokens` make an unsigned number that waits for the error of a division
  (`u + u / s`, `u / u / b`) as the whole of what it comes to.
  """
  @spec pending_unsigned?(list(), ctx()) :: boolean()
  def pending_unsigned?(tokens, ctx) do
    case value(tokens, ctx) do
      {:ok, %Value{kind: :unsigned, pending: {class, _body}}} -> class in [:division, :comparison]
      _other -> false
    end
  end

  @doc """
  The value, or the planning error it carries (the error of the last operation of a side, which
  the comparison raises once it has read both sides).
  """
  @spec flush(value()) :: {:ok, value()} | {:error, problem()}
  def flush(%Value{deferred: nil} = value), do: {:ok, value}
  def flush(%Value{deferred: body}), do: {:error, {:engine, body}}

  @doc """
  The value of a call, a group, a sign and its operand or a leaf at the start of `tokens`, and
  the tokens left (the walker reads one factor), or `:unread`, or the problem.
  """
  @spec operand(list(), ctx(), opts()) :: {:ok, value(), list()} | :unread | {:error, problem()}
  def operand(tokens, ctx, opts \\ []),
    do: InfluxQLWalk.operand(tokens, __MODULE__, options(ctx, opts))

  @doc """
  The kind a value comes to: a quotient of an unsigned number and text is unsigned while it
  stands in a comparison with a boolean (`:loose`), any other pending error is `{:late, body}`,
  raised after the comparisons around it.
  """
  @spec settled(value(), mode()) :: {:ok, kind() | :abs_null} | {:late, atom(), binary()}
  def settled(%Value{pending: {:quotient, _body}, kind: kind}, :loose), do: {:ok, kind}
  def settled(%Value{pending: {class, body}}, _mode), do: {:late, class, body}

  def settled(%Value{named: :float, kind: kind}, _mode) when kind in @known_nulls,
    do: {:ok, :abs_null}

  def settled(%Value{kind: kind}, _mode), do: {:ok, kind}

  # ---------------------------------------------------------------------------
  # The callbacks of the walker
  # ---------------------------------------------------------------------------

  @impl InfluxQLWalk
  def number(text, sign, _o), do: {:ok, %Value{kind: number_kind(text, sign), literal: true}}

  @impl InfluxQLWalk
  def leaf([{:str, _content} | rest], _o), do: {:ok, %Value{kind: :string}, rest}
  def leaf([{:duration, _total, _text} | rest], _o), do: {:ok, %Value{kind: :duration}, rest}

  def leaf([{:raw, word} | rest], _o) do
    if InfluxQLTokens.boolean_word?(word), do: {:ok, %Value{kind: :boolean}, rest}, else: :unread
  end

  def leaf([{:ident, name} = token | rest], %Opts{ctx: {tags, types}}) do
    cond do
      InfluxQLTokens.time?(token) -> {:ok, %Value{kind: :timestamp}, rest}
      MapSet.member?(tags, name) -> {:ok, %Value{kind: :tag}, rest}
      InfluxQLExpr.absent?(name, types, tags) -> {:ok, %Value{kind: :unknown}, rest}
      true -> {:ok, %Value{kind: Map.fetch!(types, name)}, rest}
    end
  end

  def leaf(_tokens, _o), do: :unread

  # Any function but `abs()` is a refusal by name (the engine takes a library of math functions
  # the double does not compute).
  @impl InfluxQLWalk
  def enter(name, _o) do
    if String.downcase(name) == "abs",
      do: :ok,
      else: {:error, {:refuse, "unsupported InfluxQL (#{String.downcase(name)}() in a WHERE)"}}
  end

  # A sign applies to a value as the product with -1 does: the planner asks for its type, so it
  # raises the error the value carries.
  @impl InfluxQLWalk
  def negate(value, _o) do
    with {:ok, flushed} <- flush(value), do: flushed |> negated() |> own() |> carry_name(flushed)
  end

  # (A sign keeps the name the engine gives the value in a signature.)
  defp carry_name({:ok, %Value{named: nil} = negated}, %Value{named: name}) when name != nil,
    do: {:ok, %{negated | named: name}}

  defp carry_name(outcome, _value), do: outcome

  # A sign before a column the measurement lacks is a null integer (verified: `-nosuch * u` is
  # the planner's error beside a boolean, where `nosuch * u` is a null).
  defp negated(%Value{pending: {:quotient, body}} = quotient),
    do: {:ok, pending(:division, body, quotient.kind)}

  defp negated(%Value{pending: pending} = value) when pending != nil, do: {:ok, value}
  defp negated(%Value{kind: :unknown}), do: {:ok, %Value{kind: :nn}}

  defp negated(%Value{kind: kind, quotient: quotient})
       when kind in @numbers or kind in [:nn, :nnf, :nz, :duration],
       do: {:ok, %Value{kind: kind, quotient: quotient}}

  # The engine cannot negate a string, a tag, a boolean column or the false: the sign leaves a
  # null of its own (verified: `'x' * -s` is `false` beside `ok`, `1 * -s` a null;
  # `-(nosuch + 'x') + 'x' = ok` keeps the points `ok` is false for, `-(nosuch + 'x') = ok`
  # none). (A constant of these is a parse error.)
  defp negated(%Value{kind: kind}) when kind in [:string, :tag, :boolean, :false_constant],
    do: {:ok, %Value{kind: :nz}}

  # `-time` is `-1 * time` (verified for `-(time)` and `-(time + 1h)`).
  defp negated(%Value{kind: :timestamp}), do: coerce(:integer, "*", :timestamp)

  # A call raises the errors its arguments carry, in order, before its own; the planner asks
  # for its type, and so for theirs, when the call is an operand of another operation.
  @impl InfluxQLWalk
  def call(name, arguments, o) do
    case Enum.find(arguments, &(&1.deferred != nil)) do
      %Value{deferred: body} -> {:ok, %Value{kind: :nz, deferred: body}}
      nil -> name |> signature(arguments, o) |> own()
    end
  end

  # The last operation is put off, and combined in the mode `lazy` names.
  @impl InfluxQLWalk
  def lazy(%Opts{state: %Config{lazy: nil}}), do: nil

  def lazy(%Opts{state: %Config{lazy: last} = config} = o),
    do: %{o | state: %{config | mode: last}}

  @impl InfluxQLWalk
  def combine(op, left, right, %Opts{state: %Config{mode: mode}}) do
    with {:ok, left} <- flush(left), {:ok, right} <- flush(right) do
      op |> operate(left, right, mode) |> own() |> named(op, left, right)
    end
  end

  defp operate(op, %Value{pending: nil} = left, %Value{pending: nil} = right, _mode) do
    op
    |> plain(typed_beside(left, right), typed_beside(right, left))
    |> quotient_of(left, right)
  end

  defp operate(op, left, right, mode), do: divided(op, left, right, mode)

  # The kind an operand is typed as beside the other: the quotient of integers is an integer
  # beside an unsigned number (see `quotient` above).
  defp typed_beside(%Value{kind: :float, quotient: true}, %Value{kind: :unsigned}), do: :integer
  defp typed_beside(%Value{kind: kind}, _other), do: kind

  # The result of an operation between two numbers the planner types as integers and the engine
  # computes as floats is such a quotient again (`n / 2 * 3`, `4 / 2`).
  defp quotient_of({:ok, %Value{kind: :float} = result}, left, right) do
    if integer_typed?(left) and integer_typed?(right),
      do: {:ok, %{result | quotient: true}},
      else: {:ok, result}
  end

  defp quotient_of(outcome, _left, _right), do: outcome

  defp integer_typed?(%Value{kind: :integer}), do: true
  defp integer_typed?(%Value{kind: :float, quotient: true}), do: true
  defp integer_typed?(_value), do: false

  # What the engine names the result of an operation by in a signature, when an operand is named
  # otherwise than it is typed (the `abs()` of a null is `Float64`, and a sum with it is typed
  # with that: `abs(abs(nosuch + 1) + 1, 1)` is `abs(Float64, Int64)`).
  defp named(
         {:ok, %Value{named: nil} = result},
         op,
         %Value{pending: nil, named: left_name} = left,
         %Value{pending: nil, named: right_name} = right
       )
       when left_name != nil or right_name != nil do
    case plain(op, left_name || left.kind, right_name || right.kind) do
      {:ok, %Value{kind: kind}} when kind != result.kind -> {:ok, %{result | named: kind}}
      _same_or_error -> {:ok, result}
    end
  end

  defp named(outcome, _op, _left, _right), do: outcome

  # The planning error of an operation or a call is its own: the value carries it.
  defp own({:own_error, body}), do: {:ok, %Value{kind: :nz, deferred: body}}
  defp own(outcome), do: outcome

  # ---------------------------------------------------------------------------
  # Calls
  # ---------------------------------------------------------------------------

  # A math function is a float; `abs()` of a number keeps its type.
  defp signature(_name, [], %Opts{state: %Config{outermost: outermost}}),
    do: {:own_error, zero_arguments(outermost)}

  # The engine types `abs()` of a null a float all the same, which beside no comparison is the
  # bare operand's error; the double reads such a null as no type (verified: `abs(nosuch + 1)`
  # is `Boolean AND Float64` alone, `Float64 AND Int64` beside `AND n`, where `abs(nosuch + 1) =
  # 1` keeps no point): refused by name.
  defp signature(_name, [%Value{kind: kind}], %Opts{state: %Config{operand: true}})
       when kind in @known_nulls,
       do: {:error, {:refuse, "unsupported InfluxQL (abs() of a null as a bare operand)"}}

  defp signature(_name, [argument], %Opts{state: %Config{whole: whole}}),
    do: abs_call(argument, whole)

  # As the whole condition the engine coerces the quotient of an unsigned number and text, a
  # boolean, the time or a duration among the arguments before it checks their number (verified:
  # `abs(u / s, 1)` is the division's coercion error, `abs(u / s, 1) = 1` the arity with
  # `UInt64`).
  defp signature(_name, arguments, %Opts{state: %Config{whole: whole}}) do
    with true <- whole,
         %Value{pending: {_class, body}} <- Enum.find(arguments, &pending?/1) do
      {:own_error, body}
    else
      _no_quotient -> {:own_error, arity_error(arguments, whole)}
    end
  end

  # What `abs()` of a value comes to: a number keeps its type, a column the measurement lacks a
  # float, a null stays null (and is named `Float64` in a signature), a boolean, a string, a tag,
  # a duration or the time is the engine's planning error (`bare` when the call is the whole
  # condition), the quotient of an unsigned number and text the error of the division, which no
  # null takes away from it either way.
  defp abs_call(%Value{pending: {:quotient, body}} = quotient, _bare),
    do: {:ok, pending(:division, body, quotient.kind)}

  defp abs_call(%Value{pending: pending} = value, _bare) when pending != nil, do: {:ok, value}

  defp abs_call(%Value{kind: kind, quotient: quotient}, _bare) when kind in @numbers,
    do: {:ok, %Value{kind: kind, quotient: quotient}}

  defp abs_call(%Value{kind: kind}, _bare) when kind in @known_nulls,
    do: {:ok, %Value{kind: kind, named: :float}}

  defp abs_call(%Value{kind: kind}, bare) do
    case Map.fetch(@native, kind) do
      {:ok, native} -> {:own_error, abs_body(kind, native, bare)}
      :error -> {:ok, %Value{kind: :float}}
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

  defp zero_arguments(outermost?) do
    if(outermost?, do: "type_coercion\ncaused by\n", else: "") <>
      "Error during planning: 'abs' does not support zero arguments No function matches the " <>
      "given name and argument types 'abs()'. " <> @signature
  end

  defp arity_error(arguments, whole?) do
    names = Enum.map_join(arguments, ", ", &argument_arrow/1)

    "Error during planning: Function 'abs' expects 1 arguments but received " <>
      "#{length(arguments)}" <>
      if(whole?,
        do: "",
        else:
          " No function matches the given name and argument types 'abs(#{names})'. " <>
            @signature
      )
  end

  # The type the engine names an argument by (verified): `Null` for a column the measurement
  # lacks and for the nulls arithmetic of text and numbers makes, `UInt64` for the quotient of
  # an unsigned number and anything it cannot divide, `Float64` for what `named` says.
  defp argument_arrow(%Value{named: named, kind: kind}) do
    shown = named || kind
    if shown in @nulls, do: "Null", else: arrow(shown)
  end

  # ---------------------------------------------------------------------------
  # Two operands
  # ---------------------------------------------------------------------------

  # Two operands with no pending error between them.
  defp plain(op, left, right) do
    cond do
      left in @nulls and right in @nulls -> nulls(left, right)
      left in @nulls -> with_null(left, right)
      right in @nulls -> with_null(right, left)
      true -> known(op, left, right)
    end
  end

  # The quotient of an unsigned number and text, or another pending error, beside another operand
  # (verified over every kind of it):
  #
  #   * an integer expression: the rewriter's error that no null takes away, at once
  #     (`n + (u / s)`, `(1 + 2) * (u / s)`; `2 + (u / s)` is not one, `2` is a literal)
  #   * a null: null (`-nosuch + u / s`, `(-s) + u / s`), whatever the comparison is
  #   * a float: null when the other side of the comparison is no number (`u / s + 1.5 = ok`,
  #     `= 'x'`: `:loose`, `:text`), the coercion error of the division elsewhere (`:strict`)
  #   * the false, text, a boolean, a tag, a duration or the time: the unsigned number it is,
  #     in the order written (`u / s + 'x' = 1` is `UInt64 + Utf8`), except when the quotient is
  #     the whole condition (`:alone`: `t + (u / s)` is the coercion error of the division)
  #   * any other number, or another quotient: the coercion error of the division
  defp divided(op, left, right, mode) do
    cond do
      pending?(left) and pending?(right) ->
        {:ok, both_pending(op, left, right)}

      (unsigned_pending?(left) and integer_expression?(right)) or
          (unsigned_pending?(right) and integer_expression?(left)) ->
        {:error, {:engine, cannot_use(op)}}

      pending?(left) ->
        beside(op, left, right, mode, :left)

      true ->
        beside(op, right, left, mode, :right)
    end
  end

  # The quotient and the `other` operand, which stood on `side` of the operator.
  defp beside(op, quotient, other, mode, side) do
    case {beside_quotient(other.kind, mode), side} do
      {:null, _side} ->
        if erased_by_null?(quotient), do: {:ok, null_of(other)}, else: {:ok, quotient}

      {:unsigned, :left} when op == "/" and other.kind in [:string, :tag] ->
        {:ok, pending(:division, pending_body(quotient), derived_kind(quotient, other))}

      {:unsigned, :left} ->
        plain(op, :unsigned, other.kind)

      {:division, :left} when op == "/" and other.kind in @divisors ->
        plain(op, :unsigned, other.kind)

      {:unsigned, :right} when op == "/" ->
        {:ok, pending(:division, pending_body(quotient), derived_kind(quotient, other))}

      {:unsigned, :right} ->
        plain(op, other.kind, :unsigned)

      {:division, _side} ->
        {:ok, pending(:division, pending_body(quotient), derived_kind(quotient, other))}
    end
  end

  # Two operands that both carry a pending error (verified over every pair of them): the first
  # is the error of a sum, a difference and a product, and of a quotient the last of the
  # comparisons of an unsigned number with the wrong type (`u / b`, `u / 1h`), which are raised
  # before a division (`(u / b) / (u / time)` is the time's, `(u / s) / (u / 1h)` the duration's,
  # `(u / s) / (s / u)` the first division's).
  defp both_pending(op, left, right) do
    chosen =
      cond do
        op != "/" -> left
        match?(%Value{pending: {:comparison, _body}}, right) -> right
        match?(%Value{pending: {:comparison, _body}}, left) -> left
        true -> left
      end

    {class, body} = chosen.pending

    pending(
      if(class == :comparison, do: :comparison, else: :division),
      body,
      derived_kind(left, right)
    )
  end

  # (What the engine names the quotient beside a float is a float, where the double reads it as
  # a null of its own for the comparison.)
  defp null_of(%Value{kind: :float}), do: %Value{kind: :nz, named: :float}
  defp null_of(_other), do: %Value{kind: :nz}

  defp pending_body(%Value{pending: {_class, body}}), do: body

  defp pending(class, body, kind \\ :unsigned),
    do: %Value{kind: kind, pending: {class, body}}

  # A pending error made of a float is a float's.
  defp derived_kind(%Value{kind: left}, %Value{kind: right}),
    do: if(:float in [left, right], do: :float, else: :unsigned)

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
      kind -> {:ok, %Value{kind: kind}}
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
  defp with_null(null, :unsigned),
    do: {:ok, %Value{kind: Map.fetch!(@null_beside_unsigned, null)}}

  defp with_null(:nz, kind) when kind in @numbers, do: {:ok, %Value{kind: :nz}}

  defp with_null(null, kind) when kind in @numbers,
    do: {:ok, %Value{kind: null_number(null, kind)}}

  defp with_null(_null, kind) when kind in @non_numeric or kind == :timestamp,
    do: {:ok, %Value{kind: :false_constant}}

  defp known("/", :unsigned, right) when right in @divisors,
    do: {:ok, pending(:comparison, comparison_body(right))}

  defp known("/", left, :unsigned) when left in @udiv_dividends,
    do: {:ok, pending(:quotient, coercion_body(left, "/", :unsigned))}

  defp known("/", :unsigned, right) when right in [:string, :tag],
    do: {:ok, pending(:quotient, coercion_body(:unsigned, "/", right))}

  defp known(op, left, right) do
    cond do
      left == :timestamp or right == :timestamp ->
        with_time(op, left, right)

      left == :duration and right == :duration ->
        durations(op)

      left in @numbers and right in @numbers ->
        {:ok, %Value{kind: number_result(op, left, right)}}

      uncoercible?(left, right) ->
        coerce(left, op, right)

      true ->
        text(op, left, right)
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
  defp text("+", :string, :string), do: {:ok, %Value{kind: :string}}
  defp text(_op, _left, _right), do: {:ok, %Value{kind: :nz}}

  # Two durations are summed or subtracted; the engine has no product or quotient of them.
  defp durations(op) when op in ["+", "-"], do: {:ok, %Value{kind: :duration}}
  defp durations(op), do: temporal(:duration, op)

  # A time and a duration are summed (in either order) or subtracted (the time first) to a time.
  # The difference of two times is a duration of its own (`Duration(ns)`) that the double does not
  # model: refused by name. The sum, product or quotient of two times is the engine's error, and
  # a time beside anything else is one the engine cannot coerce.
  defp with_time(op, :timestamp, :duration) when op in ["+", "-"],
    do: {:ok, %Value{kind: :timestamp}}

  defp with_time("+", :duration, :timestamp), do: {:ok, %Value{kind: :timestamp}}

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
  defp number_result(op, left, right) do
    cond do
      left == :float or right == :float -> :float
      left == :unsigned or right == :unsigned -> :unsigned
      op == "/" -> :float
      true -> :integer
    end
  end

  defp coerce(left, op, right), do: {:own_error, coercion_body(left, op, right)}

  # The planner's error for the sum, product or quotient of two times or two durations.
  defp temporal(kind, op) do
    type = arrow(kind)
    word = if kind == :timestamp, do: "timestamp", else: "interval"

    {:own_error,
     "Error during planning: Cannot get result type for temporal operation " <>
       "#{type} #{op} #{type}: Invalid argument error: Invalid #{word} arithmetic " <>
       "operation: #{type} #{op} #{type}"}
  end

  # The one rule of what a null takes away: the pending error of a value (an error that is not
  # raised yet) is taken away by a null beside it, whatever the operator, when its class is one of
  # `@erasable`. (What is raised at once is no pending error, the rewriter's `cannot_use/1`.)
  defp erased_by_null?(%Value{pending: {class, _body}}), do: class in @erasable
end
