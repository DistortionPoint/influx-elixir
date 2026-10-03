defmodule InfluxElixir.TestSupport.Check do
  @moduledoc """
  Assertions for tests that loop over cases and for values whose last digit
  depends on the order of accumulation.

    * `check_cases/2` runs a check on every case and fails once, listing every
      case that did not hold, instead of stopping at the first.
    * `check_ratchet/3` is `check_cases/2` for a table of cases that the double
      may refuse by name instead of answering: the number it refused is pinned
      with `===`, so that a regression to "refused" and an improvement both fail
      until the pin is moved.
    * `assert_rows_close/3` compares rows exactly, except that two floats may
      differ by a relative `1.0e-12`: a mean or a sum of floats is correct to
      that precision whatever order the engine added the values in.
    * `rows_close?/3` is the same comparison as a boolean, for a check that
      reports a mismatch itself.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @default_tolerance 1.0e-12

  @doc """
  Runs `check` on each of `cases` and fails once with every mismatch.

  `check` returns `:ok` when the case holds, or `{:mismatch, description}`.
  """
  @spec check_cases(Enumerable.t(), (term() -> :ok | {:mismatch, term()})) :: :ok
  def check_cases(cases, check) when is_function(check, 1) do
    case for(item <- cases, {:mismatch, why} <- [check.(item)], do: {item, why}) do
      [] -> :ok
      failed -> flunk(describe_failures(failed))
    end
  end

  @doc """
  Runs `check` on each of `cases` like `check_cases/2`, where `check` may also
  return `:refused` (the double refused the case by name), and fails unless
  exactly `pinned` cases were refused.

  The count is a ratchet. Above the pin, a case that used to be answered is now
  refused: a regression, listed. Below it, a case that used to be refused is now
  answered: the pin is lowered and the case moved out of its refusable table into
  the table of answers. On a real engine nothing may be refused: the pin is `0`.
  """
  @spec check_ratchet(
          Enumerable.t(),
          (term() -> :ok | :refused | {:mismatch, term()}),
          non_neg_integer()
        ) :: :ok
  def check_ratchet(cases, check, pinned) when is_function(check, 1) and pinned >= 0 do
    results = for item <- cases, do: {item, check.(item)}
    mismatches = for {item, {:mismatch, why}} <- results, do: {item, why}
    refused = for {item, :refused} <- results, do: item

    cond do
      mismatches !== [] ->
        flunk(describe_failures(mismatches))

      length(refused) === pinned ->
        :ok

      true ->
        flunk(
          "#{length(refused)} case(s) refused, #{pinned} pinned (of #{length(results)}); " <>
            "refused:\n" <> Enum.map_join(refused, "\n", &"  #{inspect(&1)}")
        )
    end
  end

  @doc """
  Runs `fun` on each of `cases`, which asserts, and fails once with the message of
  every case whose assertion failed, instead of stopping at the first.
  """
  @spec each_case(Enumerable.t(), (term() -> term())) :: :ok
  def each_case(cases, fun) when is_function(fun, 1) do
    cases
    |> Enum.flat_map(fn item ->
      try do
        fun.(item)
        []
      rescue
        error in [ExUnit.AssertionError, MatchError] -> [{item, Exception.message(error)}]
      end
    end)
    |> flunk_mismatches()
  end

  @doc """
  Fails once with `failed`, a list of `{case, why}`, unless it is empty.
  """
  @spec flunk_mismatches([{term(), term()}]) :: :ok
  def flunk_mismatches([]), do: :ok
  def flunk_mismatches(failed), do: flunk(describe_failures(failed))

  @doc """
  Asserts that `actual` equals `expected` with floats compared to a relative
  `tolerance` (default `1.0e-12`) and everything else compared strictly.

  Works on any nesting of lists, maps, tuples and scalars. On a mismatch it
  fails once with the path of every differing value.
  """
  @spec assert_rows_close(term(), term(), float()) :: :ok
  def assert_rows_close(actual, expected, tolerance \\ @default_tolerance) do
    case diffs(actual, expected, tolerance, []) do
      [] -> :ok
      found -> flunk(describe_diffs(found, actual, expected))
    end
  end

  @doc """
  True when `actual` equals `expected` as `assert_rows_close/3` reads it: floats
  to a relative `tolerance`, everything else strictly, on any nesting of lists,
  maps and tuples.
  """
  @spec rows_close?(term(), term(), float()) :: boolean()
  def rows_close?(actual, expected, tolerance \\ @default_tolerance),
    do: diffs(actual, expected, tolerance, []) === []

  @doc """
  True when `a` and `b` are equal floats to a relative `tolerance`.
  """
  @spec close?(float(), float(), float()) :: boolean()
  def close?(a, b, tolerance \\ @default_tolerance)
  def close?(a, b, _tolerance) when a === b, do: true

  def close?(a, b, tolerance) when is_float(a) and is_float(b),
    do: abs(a - b) <= tolerance * max(abs(a), abs(b))

  defp diffs(a, b, tol, path) when is_float(a) and is_float(b) do
    if close?(a, b, tol), do: [], else: [{Enum.reverse(path), a, b}]
  end

  defp diffs(a, b, tol, path) when is_list(a) and is_list(b) and length(a) === length(b) do
    a
    |> Enum.zip(b)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{x, y}, i} -> diffs(x, y, tol, [i | path]) end)
  end

  defp diffs(a, b, tol, path) when is_map(a) and is_map(b) and not is_struct(a) do
    if Map.keys(a) -- Map.keys(b) === [] and Map.keys(b) -- Map.keys(a) === [] do
      Enum.flat_map(a, fn {k, x} -> diffs(x, Map.fetch!(b, k), tol, [k | path]) end)
    else
      [{Enum.reverse(path), a, b}]
    end
  end

  defp diffs(a, b, tol, path)
       when is_tuple(a) and is_tuple(b) and tuple_size(a) === tuple_size(b),
       do: diffs(Tuple.to_list(a), Tuple.to_list(b), tol, path)

  defp diffs(a, b, _tol, _path) when a === b, do: []
  defp diffs(a, b, _tol, path), do: [{Enum.reverse(path), a, b}]

  defp describe_diffs(found, actual, expected) do
    lines =
      for {path, a, b} <- found, do: "  at #{inspect(path)}: #{inspect(a)} !== #{inspect(b)}"

    "rows differ beyond a relative tolerance:\n" <>
      Enum.join(lines, "\n") <>
      "\nactual:   #{inspect(actual, limit: :infinity)}\nexpected: #{inspect(expected, limit: :infinity)}"
  end

  defp describe_failures(failed) do
    lines = for {item, why} <- failed, do: "  #{inspect(item)}: #{inspect(why, limit: :infinity)}"
    "#{length(failed)} case(s) did not hold:\n" <> Enum.join(lines, "\n")
  end
end
