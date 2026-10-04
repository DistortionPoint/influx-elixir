defmodule InfluxElixir.Client.Local.SQLCompare do
  @moduledoc false
  # How two values compare in a SQL query of `InfluxElixir.Client.Local`, in a
  # `WHERE` and in an expression of the select list alike (verified against
  # InfluxDB 3 Core): numbers as `InfluxElixir.Client.Local.SQLNumber` orders
  # them, a number against a string by the number's text, strings and
  # booleans by their own order.

  alias InfluxElixir.Client.Local.{Format, SQLCast, SQLError, SQLNumber}

  # Both nil-actual (missing column) and nil-value (unparseable comparand)
  # short-circuit to false. Without this guard, Elixir term ordering would
  # silently produce wrong results (e.g. `5 > nil` is `true`).
  #
  # A string literal against a non-string column compares the column's text
  # rendering, which is what DataFusion does (it casts the numeric side to
  # Utf8): `amount >= '1000.00'` is lexical, so 500.0 matches. The double
  # reproduces that so a test written against it fails the same way
  # production would.
  #
  # The other way round — a string column against a numeric literal — the
  # engine keeps the column as text and renders the literal (`rack = 2`
  # matches the tag "2"; `rack > 3` is lexical, so "10" does not match), so
  # the literal is rendered here too.
  @doc """
  A `LIKE` (or, with `case_insensitive`, `ILIKE`) pattern as an anchored regular
  expression. `%` is any run, `_` any single character (a code point:
  `'caf_'` matches "café", and `ILIKE 'éa'` matches "Éa", verified), `\\`
  makes the next character literal (`'al\\%%'` matches "al%pha"); everything
  else is literal. `LIKE` is case-sensitive on the engine, `ILIKE` is not.
  """
  @spec like_regex(binary(), boolean()) :: {:ok, Regex.t()} | {:error, :pattern_too_large}
  def like_regex(pattern, case_insensitive) do
    source = pattern |> String.codepoints() |> like_source([])

    case Regex.compile("\\A" <> source <> "\\z", if(case_insensitive, do: "isu", else: "su")) do
      {:ok, regex} -> {:ok, regex}
      {:error, _reason} -> {:error, :pattern_too_large}
    end
  end

  @doc "The refusal of a `LIKE` pattern too long for the regular expression it is matched by."
  @spec pattern_too_large() :: map()
  def pattern_too_large do
    SQLError.refusal(
      "a LIKE pattern of more than tens of thousands of characters: the double matches it with " <>
        "a regular expression of bounded size"
    )
  end

  @spec like_source([binary()], [binary()]) :: binary()
  defp like_source([], acc), do: acc |> Enum.reverse() |> Enum.join()
  defp like_source(["\\", char | rest], acc), do: like_source(rest, [Regex.escape(char) | acc])
  defp like_source(["%" | rest], acc), do: like_source(rest, [".*" | acc])
  defp like_source(["_" | rest], acc), do: like_source(rest, ["." | acc])
  defp like_source([char | rest], acc), do: like_source(rest, [Regex.escape(char) | acc])

  @doc "A three-valued negation: unknown stays unknown."
  @spec negate(boolean() | nil) :: boolean() | nil
  def negate(nil), do: nil
  def negate(value) when is_boolean(value), do: not value

  # A value that is no boolean reaches a negation the type check did not see (the type of an
  # expression it has none for): the double declines it, and does not fail on it.
  def negate(_value),
    do: throw({:query_error, SQLError.refusal("NOT of a value the double has no type for")})

  @doc "Whether `actual op value` holds; a null on either side is not true."
  @spec compare(term(), atom(), term()) :: boolean()
  def compare(nil, _op, _value), do: false
  def compare(_actual, _op, nil), do: false

  def compare(actual, op, value) when is_integer(actual) and is_integer(value),
    do: term_compare(actual, op, value)

  # Zero is left to `SQLNumber`, which orders -0.0 before 0.0.
  def compare(actual, op, value)
      when is_float(actual) and is_float(value) and actual != 0.0 and value != 0.0,
      do: term_compare(actual, op, value)

  def compare(actual, op, value) do
    cond do
      is_binary(value) and not is_binary(actual) -> compare(text(actual), op, value)
      is_binary(actual) and SQLNumber.numeric?(value) -> compare(actual, op, text(value))
      SQLNumber.numeric?(actual) and SQLNumber.numeric?(value) -> ordered(actual, op, value)
      true -> term_compare(actual, op, value)
    end
  end

  # Numbers of any type, ordered as the engine orders them.
  @spec ordered(SQLNumber.t(), atom(), SQLNumber.t()) :: boolean()
  defp ordered(actual, op, value) do
    order = SQLNumber.compare(actual, value)

    case op do
      :eq -> order == :eq
      :ne -> order != :eq
      :gt -> order == :gt
      :lt -> order == :lt
      :gte -> order != :lt
      :lte -> order != :gt
    end
  end

  # The engine casts the float to the decimal's type, which holds a value to
  # about 1e20 at the most, and fails the query for a row with a larger
  # one; how large depends on the decimal's precision.
  @doc "Throws the refusal for a decimal compared with a float the engine cannot cast to it."
  @spec wide_decimal_float(term(), term()) :: :ok
  def wide_decimal_float({:dec, _coefficient, _scale}, float), do: wide_float(float)
  def wide_decimal_float(float, {:dec, _coefficient, _scale}), do: wide_float(float)
  def wide_decimal_float(_actual, _value), do: :ok

  @spec wide_float(term()) :: :ok
  defp wide_float(value)
       when value in [:inf, :neg_inf] or (is_float(value) and abs(value) > 1.0e20) do
    throw(
      {:query_error,
       SQLError.refusal(
         "a decimal expression compared with a float past 1e20 in a column: the engine fails " <>
           "its cast of the float to the decimal's type, past a size that depends on the " <>
           "decimal's precision, which is not modelled"
       )}
    )
  end

  defp wide_float(_value), do: :ok

  @spec term_compare(term(), atom(), term()) :: boolean()
  defp term_compare(actual, :eq, value), do: actual == value
  defp term_compare(actual, :ne, value), do: actual != value
  defp term_compare(actual, :gt, value), do: actual > value
  defp term_compare(actual, :lt, value), do: actual < value
  defp term_compare(actual, :gte, value), do: actual >= value
  defp term_compare(actual, :lte, value), do: actual <= value

  # A value as DataFusion casts it to text: a float as the engine writes it
  # (`5000.0`, not Erlang's `5.0e3`), a decimal with its scale, an infinity
  # `inf`.
  @doc "A value as the engine casts it to text."
  @spec text(term()) :: binary()
  def text(value) when is_float(value), do: Format.render_float(value)
  def text({:u, value}), do: Integer.to_string(value)
  def text({:int, _bits, value}), do: Integer.to_string(value)
  def text({:dec, _coefficient, _scale} = value), do: SQLCast.cast(value, :string)
  def text(:inf), do: "inf"
  def text(:neg_inf), do: "-inf"
  def text(:nan), do: "NaN"
  def text(value), do: to_string(value)
end
