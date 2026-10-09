defmodule InfluxElixir.Client.Local.InfluxQLCalls do
  @moduledoc false
  # The calls of a condition (a name followed by a parenthesis), as the engine's planner reads
  # them: `abs()` of one number, or its planning error, or a refusal by name for any other call
  # (the engine takes a library of math functions the double does not compute).
  #
  # One pass over the tokens, with the walker and the types of `InfluxQLFold`: at each call the
  # walker reads its arguments (and the calls inside them) once, typing them as it goes, so a
  # call nested n deep costs n and not n squared. The first problem is the answer: a name that
  # is no `abs` the moment the call is met, the type or the number of the arguments of an
  # `abs` once they are read. The coercion error of the arithmetic inside an argument is raised
  # before the call's own (the argument is `{:poisoned, body}` and the call answers that body
  # when it has a problem of its own), and passes on when the call has none: `InfluxQLFold`
  # raises it after the calls.

  alias InfluxElixir.Client.Local.{InfluxQLFold, InfluxQLTokens}

  @typedoc "What is wrong with the calls of a condition: the engine's error, or a refusal."
  @type problem :: {:engine, binary()} | {:refuse, binary()}

  @doc """
  The problem of the first call of the condition `tokens` that has one, or `:ok`. `alone` says
  that the condition is the whole `WHERE` (not a part of an `AND`, an `OR` or a group): a
  condition that is one call is then worded as the planner words a call that is the whole
  predicate (verified: a call that is part of something carries the signature, and a call with
  no arguments that is the whole condition is a coercion error of its own).
  """
  @spec problem(list(), InfluxQLFold.ctx(), boolean()) :: :ok | problem()
  def problem(tokens, ctx, alone \\ true) do
    if call?(tokens) do
      stripped = strip_parens(tokens)
      whole? = alone and single_call?(stripped)
      outermost? = whole? and match?([{:ident, _name}, {:raw, "("}, {:raw, ")"}], stripped)
      bare? = not Enum.any?(tokens, &match?({:op, _op}, &1))
      scan(tokens, handlers(ctx, whole?, outermost?, bare?))
    else
      :ok
    end
  end

  defp call?([{:ident, _name}, {:raw, "("} | _rest]), do: true
  defp call?([_token | rest]), do: call?(rest)
  defp call?([]), do: false

  defp strip_parens(tokens), do: tokens |> InfluxQLTokens.unwrap_group() |> elem(0)

  # Whether the tokens are one call and nothing else.
  defp single_call?([{:ident, _name}, {:raw, "("} | rest]),
    do: match?({_inside, []}, InfluxQLTokens.take_call(rest))

  defp single_call?(_tokens), do: false

  # Each call is read by the walker, from its name to its closing parenthesis, and the tokens
  # behind it go on being scanned. A call whose arguments are no arithmetic (`abs(n > 1)`) is
  # passed over: the calls inside it are met on their own.
  defp scan([{:ident, _name}, {:raw, "("} | rest] = tokens, handlers) do
    case InfluxQLFold.operand(tokens, handlers) do
      {:ok, _kind, after_call} -> scan(after_call, handlers)
      {:error, problem} -> problem
      :unread -> scan(rest, handlers)
    end
  end

  defp scan([_token | rest], handlers), do: scan(rest, handlers)
  defp scan([], _handlers), do: :ok

  defp handlers(ctx, whole?, outermost?, bare?) do
    typer = InfluxQLFold.typer(ctx, bare: whole?)

    %{
      typer
      | combine: fn op, left, right -> combine(typer, op, left, right) end,
        negate: fn kind -> negate(typer, kind) end,
        enter: &enter/1,
        call: &call(&1, &2, whole?, outermost?, bare?)
    }
  end

  # A coercion error inside an argument is the arithmetic's, raised after the calls; here it
  # makes the value of the arithmetic `{:poisoned, body}` (the argument is a null to the rest).
  # What the engine names a quotient of an unsigned number and text beside a float is a float,
  # where the double reads it as a null of its own for the comparison.
  defp combine(typer, op, left, right) do
    case poisoned([left, right]) do
      nil -> op |> typer.combine.(left, right) |> floated(left, right) |> tolerated()
      poison -> {:ok, poison}
    end
  end

  defp negate(typer, kind) do
    if poisoned([kind]), do: {:ok, kind}, else: kind |> typer.negate.() |> tolerated()
  end

  defp tolerated({:error, body}), do: {:ok, {:poisoned, body}}
  defp tolerated(outcome), do: outcome

  defp floated({:ok, :nz}, left, right) when is_tuple(left) and right == :float, do: {:ok, :float}
  defp floated({:ok, :nz}, left, right) when left == :float and is_tuple(right), do: {:ok, :float}
  defp floated(outcome, _left, _right), do: outcome

  defp poisoned(kinds), do: Enum.find(kinds, &match?({:poisoned, _body}, &1))

  defp enter(name) do
    if String.downcase(name) == "abs",
      do: :ok,
      else: {:error, {:refuse, "unsupported InfluxQL (#{String.downcase(name)}() in a WHERE)"}}
  end

  # The error in the arguments of a call is raised before the call's own (verified: `abs(u + 's',
  # 1)` is the coercion error, not the arity); a call with none of its own passes the poison on.
  defp call(_name, arguments, whole?, outermost?, bare?) do
    case {poisoned(arguments), checked(arguments, whole?, outermost?, bare?)} do
      {nil, outcome} -> outcome
      {{:poisoned, body}, {:error, _problem}} -> {:error, {:engine, body}}
      {poison, _no_problem} -> {:ok, poison}
    end
  end

  defp checked([], _whole?, outermost?, _bare?),
    do: {:error, {:engine, zero_arguments(outermost?)}}

  defp checked([argument], whole?, _outermost?, bare?), do: one_argument(argument, whole?, bare?)

  # As the whole condition the engine coerces the quotient of an unsigned number and text, a
  # boolean, the time or a duration among the arguments before it checks their number (verified:
  # `abs(u / s, 1)` is the division's coercion error, `abs(u / s, 1) = 1` the arity with
  # `UInt64`).
  defp checked(arguments, whole?, _outermost?, _bare?) do
    case whole? && Enum.find(arguments, &quotient?/1) do
      quotient when is_tuple(quotient) -> one_argument(quotient, whole?, false)
      _no_quotient -> {:error, {:engine, many_arguments(arguments, whole?)}}
    end
  end

  defp quotient?({:udiv, _left, _right}), do: true
  defp quotient?({:pending, _body}), do: true
  defp quotient?(_kind), do: false

  # The engine types `abs()` of a null a float all the same, which beside no comparison is the
  # bare operand's error; the double reads such a null as no type (verified: `abs(nosuch + 1)`
  # is `Boolean AND Float64` alone, `Float64 AND Int64` beside `AND n`, where `abs(nosuch + 1) =
  # 1` keeps no point): refused by name.
  defp one_argument(argument, _whole?, true) when argument in [:nn, :nnf, :nz],
    do: {:error, {:refuse, "unsupported InfluxQL (abs() of a null as a bare operand)"}}

  # (To the signature of a call it is in, the `abs()` of a null is a float.)
  defp one_argument(argument, whole?, _bare?) do
    case InfluxQLFold.abs_call(argument, whole?) do
      {:error, body} -> {:error, {:engine, body}}
      {:ok, null} when null in [:nn, :nnf, :nz] -> {:ok, :float}
      outcome -> outcome
    end
  end

  defp zero_arguments(outermost?) do
    if(outermost?, do: "type_coercion\ncaused by\n", else: "") <>
      "Error during planning: 'abs' does not support zero arguments No function matches the " <>
      "given name and argument types 'abs()'. " <> InfluxQLFold.signature()
  end

  defp many_arguments(arguments, whole?) do
    names = Enum.map_join(arguments, ", ", &argument_arrow/1)

    "Error during planning: Function 'abs' expects 1 arguments but received " <>
      "#{length(arguments)}" <>
      if(whole?,
        do: "",
        else:
          " No function matches the given name and argument types 'abs(#{names})'. " <>
            InfluxQLFold.signature()
      )
  end

  # The type the engine names an argument by (verified): `Null` for a column the measurement
  # lacks and for the nulls arithmetic of text and numbers makes, `UInt64` for the quotient of
  # an unsigned number and anything it cannot divide.
  defp argument_arrow(kind) when kind in [:unknown, :nn, :nnf, :nz], do: "Null"
  defp argument_arrow(kind) when is_tuple(kind), do: InfluxQLFold.arrow(:unsigned)
  defp argument_arrow(kind), do: InfluxQLFold.arrow(kind)
end
