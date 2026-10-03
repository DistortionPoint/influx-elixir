defmodule InfluxElixir.Client.Local.InfluxQLTransform do
  @moduledoc false
  # The transforms of an InfluxQL select list over a sequence of values in time
  # order, as the engine computes them (verified): `derivative`,
  # `non_negative_derivative`, `difference`, `non_negative_difference`,
  # `cumulative_sum`, `moving_average` and `elapsed`.
  #
  #   * the sequence is a field's values at the points of a series, or an
  #     aggregate's values at the buckets of a `GROUP BY time`; a null in it
  #     (an empty bucket) is skipped, and what follows it works from the last
  #     value before it, over the time between the two
  #   * `derivative` is the change from the value before, per `unit`
  #     (`dx / (dt / unit)`, always a float computed from both values as floats;
  #     the first value has none), `difference` the change itself (an integer
  #     stays one and wraps at 64 bits); the `non_negative` forms drop a
  #     negative one, and keep a zero
  #   * `cumulative_sum` adds the values up (integers wrap at 64 bits);
  #     `moving_average(n)` is the mean of the last `n` values taken as floats,
  #     there when `n` have been seen
  #   * a float result that overflows is infinite, which the engine writes as a
  #     null in the row (`:nan` here, unlike `nil`, which is no result); a
  #     negative infinity is negative to the `non_negative` forms, which drop it
  #   * the sequence is read in the order of the answer: `ORDER BY time DESC`
  #     turns it round, and the change is from the value that came before in
  #     that order (over a negative time)

  alias InfluxElixir.Client.Local.SQLLimits

  require SQLLimits

  @typedoc "A value of the sequence: a number, or `nil` for none."
  @type value :: number() | nil

  @typedoc "A result: a number, `nil` for none, `:nan` for a number that is not finite."
  @type result :: number() | nil | :nan

  @typedoc "A float, or an infinity that overflowed."
  @type extended :: float() | :inf | :neg_inf

  @doc """
  The results of transform `name` over `inputs`, the `{time_ns, value}` of the
  sequence in order, as a list as long as `inputs` (`nil` where the transform
  has no result). `parameter` is the unit in nanoseconds of a derivative or of
  `elapsed`, the window of a moving average. Throws `{:refused, message}` for a
  parameter the planner never lets through.
  """
  @spec run(binary(), integer() | nil, [{integer(), value()}]) :: [result()]
  def run("derivative", unit, inputs) when is_integer(unit) and unit > 0,
    do: inputs |> rates(unit) |> Enum.map(&finite/1)

  def run("non_negative_derivative", unit, inputs) when is_integer(unit) and unit > 0,
    do: inputs |> rates(unit) |> Enum.map(&non_negative/1)

  def run("difference", _parameter, inputs), do: inputs |> changes() |> Enum.map(&finite/1)

  def run("non_negative_difference", _parameter, inputs),
    do: inputs |> changes() |> Enum.map(&non_negative/1)

  def run("elapsed", unit, inputs) when is_integer(unit) and unit > 0 do
    {results, _previous} =
      Enum.map_reduce(inputs, nil, fn
        {_time, nil}, previous -> {nil, previous}
        {time, _value}, nil -> {0, time}
        {time, _value}, before -> {div(time - before, unit), time}
      end)

    results
  end

  def run("cumulative_sum", _parameter, inputs) do
    {results, _total} =
      Enum.map_reduce(inputs, 0, fn
        {_time, nil}, total -> {nil, total}
        {_time, value}, total -> add(total, value)
      end)

    results
  end

  def run("moving_average", window, inputs) when is_integer(window) and window > 1 do
    {results, _seen} =
      Enum.map_reduce(inputs, [], fn
        {_time, nil}, seen ->
          {nil, seen}

        {_time, value}, seen ->
          seen = Enum.take([value | seen], window)
          {if(length(seen) == window, do: mean(seen, window)), seen}
      end)

    results
  end

  def run(name, parameter, _inputs),
    do: throw({:refused, "unsupported InfluxQL (#{name}() with the parameter #{parameter})"})

  # What a step comes to, an infinity written as a null in the row.
  @spec finite(extended() | number() | nil) :: result()
  defp finite(infinity) when infinity in [:inf, :neg_inf], do: :nan
  defp finite(other), do: other

  @spec non_negative(extended() | number() | nil) :: result()
  defp non_negative(:neg_inf), do: nil
  defp non_negative(value) when is_number(value) and value < 0, do: nil
  defp non_negative(value), do: finite(value)

  # Each value with the one before it that is not null.
  @spec pairwise([{integer(), value()}], (number(), integer(), number(), integer() -> term())) ::
          [term()]
  defp pairwise(inputs, fun) do
    {results, _previous} =
      Enum.map_reduce(inputs, nil, fn
        {_time, nil}, previous -> {nil, previous}
        {time, value}, nil -> {nil, {time, value}}
        {time, value}, {before, earlier} -> {fun.(value, time, earlier, before), {time, value}}
      end)

    results
  end

  @spec rates([{integer(), value()}], pos_integer()) :: [extended() | nil]
  defp rates(inputs, unit), do: pairwise(inputs, &rate(&1, &2, &3, &4, unit))

  defp rate(_value, time, _earlier, time, _unit), do: nil

  defp rate(value, time, earlier, before, unit),
    do: value |> as_float() |> subtract(as_float(earlier)) |> divide((time - before) / unit)

  @spec changes([{integer(), value()}]) :: [extended() | integer() | nil]
  defp changes(inputs), do: pairwise(inputs, &change/4)

  defp change(value, _time, earlier, _before) when is_integer(value) and is_integer(earlier),
    do: SQLLimits.wrap_int64(value - earlier)

  defp change(value, _time, earlier, _before),
    do: value |> as_float() |> subtract(as_float(earlier))

  defp as_float(value), do: value * 1.0

  @spec subtract(float(), float()) :: extended()
  defp subtract(left, right) do
    left - right
  rescue
    ArithmeticError -> if left > right, do: :inf, else: :neg_inf
  end

  @spec divide(extended(), float()) :: extended()
  defp divide(:inf, divisor), do: if(divisor > 0, do: :inf, else: :neg_inf)
  defp divide(:neg_inf, divisor), do: if(divisor > 0, do: :neg_inf, else: :inf)

  defp divide(dividend, divisor) do
    dividend / divisor
  rescue
    ArithmeticError -> if dividend > 0 == divisor > 0, do: :inf, else: :neg_inf
  end

  @spec add(number() | :nan, number()) :: {result(), number() | :nan}
  defp add(:nan, _value), do: {:nan, :nan}

  defp add(total, value) when is_integer(total) and is_integer(value) do
    sum = SQLLimits.wrap_int64(total + value)
    {sum, sum}
  end

  defp add(total, value) do
    sum = total + value
    {sum, sum}
  rescue
    ArithmeticError -> {:nan, :nan}
  end

  @spec mean([number(), ...], pos_integer()) :: float() | :nan
  defp mean(seen, window) do
    sum = seen |> Enum.reverse() |> Enum.map(&as_float/1) |> Enum.sum()
    sum / window
  rescue
    ArithmeticError -> :nan
  end
end
