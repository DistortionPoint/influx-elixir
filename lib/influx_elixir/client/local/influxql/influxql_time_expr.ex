defmodule InfluxElixir.Client.Local.InfluxQLTimeExpr do
  @moduledoc false
  # What `time` is compared with when it is more than one quoted time: an
  # expression of quoted times, durations, integers, `now()` and parentheses
  # joined by `+` and `-`, as the engine's planner folds it (verified):
  #
  #   * a quoted time is an instant, a duration a length (`1h30m` is 90
  #     minutes) and an integer a length in nanoseconds; `now()` is the
  #     instant the query was planned at
  #   * an instant plus or minus a length is an instant, a length plus an
  #     instant is one, an instant minus an instant is a length, two lengths
  #     make a length; the other combinations are the engine's errors, which
  #     the double refuses by name (an instant is added to nothing, a length
  #     has no instant taken from it, an integer is not added to `now()`, and
  #     `*`, `/`, `%` are for lengths)
  #   * instants are folded without a range of their own: only what the whole
  #     expression comes to must fit 64-bit nanoseconds, or it is
  #     `timestamp out of range` (`2024-01-01T00:00:00Z + 100000d - 100000d`
  #     is an instant of 2024)
  #   * what the whole expression comes to, an instant or a length, is the
  #     nanoseconds since the epoch the `time` column is compared with

  alias InfluxElixir.Client.Local.InfluxQLTime

  @two63 9_223_372_036_854_775_808

  # An instant (`now?` when it is, or comes from, `now()`) or a length; an
  # integer literal is a length that remembers it is not a duration.
  @typep value :: {:ts, integer(), boolean()} | {:dur, integer()} | {:int, integer()}

  @doc """
  The nanoseconds `tokens` come to, with `now` the instant of `now()`.
  Throws `{:refused, ...}` for what the double does not read as the engine.
  """
  @spec eval(list(), integer()) :: integer()
  def eval(tokens, now) do
    case sum(tokens, now) do
      {{:ts, ns, _now?}, []} when ns >= -@two63 and ns < @two63 -> ns
      {{:ts, ns, _now?}, []} -> InfluxQLTime.out_of_range(ns)
      {{_length, ns}, []} -> ns
      _leftover -> refuse("a time compared with an expression")
    end
  end

  @spec sum(list(), integer()) :: {value(), list()}
  defp sum(tokens, now) do
    {left, rest} = unary(tokens, now)
    more(rest, left, now)
  end

  @spec more(list(), value(), integer()) :: {value(), list()}
  defp more([{:raw, op} | rest], left, now) when op in ["+", "-"] do
    {right, after_right} = unary(rest, now)
    more(after_right, combine(op, left, right), now)
  end

  defp more(rest, left, _now), do: {left, rest}

  @spec unary(list(), integer()) :: {value(), list()}
  defp unary([{:raw, "-"} | rest], now) do
    case unary(rest, now) do
      {{:dur, n}, after_term} -> {{:dur, -n}, after_term}
      {{:int, n}, after_term} -> {{:int, -n}, after_term}
      {{:ts, _ns, _now?}, _rest} -> refuse("an instant negated")
    end
  end

  defp unary([{:raw, "+"} | rest], now), do: unary(rest, now)

  defp unary([{:raw, "("} | rest], now) do
    case sum(rest, now) do
      {value, [{:raw, ")"} | after_group]} -> {value, after_group}
      _unbalanced -> refuse("a time compared with an expression")
    end
  end

  defp unary([{:duration, ns, _text} | rest], _now), do: {{:dur, ns}, rest}

  defp unary([{:number, text} | rest], _now) do
    case Integer.parse(text) do
      {n, ""} -> {{:int, n}, rest}
      _fraction -> refuse("non-integer time #{text}")
    end
  end

  defp unary([{:raw, "now()"} | rest], now), do: {{:ts, now, true}, rest}

  defp unary([{:str, content} | rest], _now) do
    case InfluxQLTime.classify(content) do
      {:ok, ns} -> {{:ts, ns, false}, rest}
      _unread -> refuse("a quoted time in an expression that the double cannot read")
    end
  end

  defp unary(_tokens, _now), do: refuse("a time compared with an expression")

  @spec combine(binary(), value(), value()) :: value()
  defp combine(op, {:ts, a, now?}, length) when elem(length, 0) in [:dur, :int],
    do: {:ts, apply_op(op, a, elem(length, 1)), now?}

  defp combine("+", {:int, _n}, {:ts, _ns, true}), do: refuse("an integer added to now()")

  defp combine("+", length, {:ts, b, now?}) when elem(length, 0) in [:dur, :int],
    do: {:ts, elem(length, 1) + b, now?}

  defp combine("-", {:ts, a, _left_now}, {:ts, b, _right_now}), do: span(a - b)

  defp combine(op, {_left_kind, a}, {_right_kind, b}) when op in ["+", "-"],
    do: span(apply_op(op, a, b))

  defp combine(_op, _left, _right), do: refuse("an instant and a length combined that way")

  @spec apply_op(binary(), integer(), integer()) :: integer()
  defp apply_op("+", a, b), do: a + b
  defp apply_op("-", a, b), do: a - b

  @spec span(integer()) :: value()
  defp span(ns) when ns >= -@two63 and ns < @two63, do: {:dur, ns}
  defp span(_ns), do: refuse("a length beyond 64-bit nanoseconds")

  @spec refuse(binary()) :: no_return()
  defp refuse(what), do: throw({:refused, "unsupported InfluxQL (#{what})"})
end
