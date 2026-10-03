defmodule InfluxElixir.Client.Local.InfluxQLTransform do
  @moduledoc false
  # The transforms of an InfluxQL select list over a sequence of values in time
  # order, as the engine computes them (verified): `derivative`,
  # `non_negative_derivative`, `difference`, `non_negative_difference`,
  # `cumulative_sum` and `moving_average`.
  #
  #   * the sequence is a field's values at the points of a series, or an
  #     aggregate's values at the buckets of a `GROUP BY time`; a null in it
  #     (an empty bucket) is skipped, and what follows it works from the last
  #     value before it, over the time between the two
  #   * `derivative` is the change from the value before, per `unit`
  #     (`dx / (dt / unit)`, always a float; the first value has none), `difference`
  #     the change itself (an integer stays one); the `non_negative` forms drop
  #     a negative one, and keep a zero
  #   * `cumulative_sum` adds the values up; `moving_average(n)` is the mean of
  #     the last `n` values, there when `n` have been seen
  #   * the sequence is read in the order of the answer: `ORDER BY time DESC`
  #     turns it round, and the change is from the value that came before in
  #     that order (over a negative time)

  alias InfluxElixir.Client.Local.SQLLimits

  require SQLLimits

  @typedoc "A value of the sequence: a number, or `nil` for none."
  @type value :: number() | nil

  @doc """
  The results of transform `name` over `inputs`, the `{time_ns, value}` of the
  sequence in order, as a list as long as `inputs` (`nil` where the transform
  has no result). `parameter` is the unit in nanoseconds of a derivative, the
  window of a moving average.
  """
  @spec run(binary(), integer() | nil, [{integer(), value()}]) :: [value()]
  def run("derivative", unit, inputs), do: pairwise(inputs, &rate(&1, &2, &3, &4, unit))

  def run("non_negative_derivative", unit, inputs),
    do: "derivative" |> run(unit, inputs) |> Enum.map(&non_negative/1)

  def run("difference", _parameter, inputs), do: pairwise(inputs, &change/4)

  def run("non_negative_difference", _parameter, inputs),
    do: "difference" |> run(nil, inputs) |> Enum.map(&non_negative/1)

  def run("elapsed", unit, inputs) do
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

  def run("moving_average", window, inputs) do
    {results, _seen} =
      Enum.map_reduce(inputs, [], fn
        {_time, nil}, seen ->
          {nil, seen}

        {_time, value}, seen ->
          seen = Enum.take([value | seen], window)

          if length(seen) == window,
            do: {seen |> Enum.reverse() |> Enum.sum() |> Kernel./(window), seen},
            else: {nil, seen}
      end)

    results
  end

  # Each value with the one before it that is not null.
  @spec pairwise([{integer(), value()}], (number(), integer(), number(), integer() -> value())) ::
          [value()]
  defp pairwise(inputs, fun) do
    {results, _previous} =
      Enum.map_reduce(inputs, nil, fn
        {_time, nil}, previous -> {nil, previous}
        {time, value}, nil -> {nil, {time, value}}
        {time, value}, {before, earlier} -> {fun.(value, time, earlier, before), {time, value}}
      end)

    results
  end

  defp rate(_value, time, _earlier, time, _unit), do: nil
  defp rate(value, time, earlier, before, unit), do: (value - earlier) / ((time - before) / unit)

  defp change(value, _time, earlier, _before), do: value - earlier

  defp non_negative(nil), do: nil
  defp non_negative(value) when value < 0, do: nil
  defp non_negative(value), do: value

  defp add(total, value) when is_integer(total) and is_integer(value) do
    sum = SQLLimits.wrap_int64(total + value)
    {sum, sum}
  end

  defp add(total, value) do
    sum = total + value
    {sum, sum}
  end
end
