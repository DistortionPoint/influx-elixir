defmodule InfluxElixir.Client.Local.SQLScalar do
  @moduledoc false
  # The string and math functions `Client.Local` evaluates in SQL expressions,
  # beside those of `InfluxElixir.Client.Local.SQLFunctions`, as InfluxDB 3
  # does (verified against Core):
  #
  #   * `lower(s)`, `upper(s)` — text, any case (Unicode); a tag is text
  #   * `length(x)` — the characters (code points) of the text, of a number or
  #     of a boolean as it is cast to text; an `Int32`
  #   * `substr(s, from[, count])`, `substring` is `substr` — the characters at
  #     positions `from` to `from + count - 1` (1-based), whichever of them the
  #     text has: `substr('abc', 0)` is `abc`, `substr('abc', -1, 3)` is `a`,
  #     `substr('abc', 4)` is empty. A negative count, and a start of the
  #     smallest `Int64` given with a count, close the connection (without a
  #     count that start is just the whole text)
  #   * `starts_with(s, prefix)`
  #   * `sqrt(x)`, `ln(x)`, `log(x)` (base 10), `log(base, x)` — `Float64`; the
  #     domain's errors are the specials (`sqrt(-1)`, `ln(0)` are a `null` that
  #     is there). `log(b, x)` is `ln(x) / ln(b)`, as the engine computes it
  #     (`log(1000)` is `2.9999999999999996`)
  #   * `pow(a, b)` / `power(a, b)` — `Int64` for two integers (an overflow, and
  #     a negative exponent, close the connection), else `Float64`
  #   * `greatest(a, ...)`, `least(a, ...)` — the largest or smallest value
  #     that is not null, null when all are; the arguments share one type
  #
  # A null argument makes the result null, except for `greatest` and `least`.

  alias InfluxElixir.Client.Local.{SQLCompare, SQLError, SQLLimits, SQLNumber}

  require SQLLimits

  @names %{
    "lower" => :lower,
    "upper" => :upper,
    "length" => :length,
    "substr" => :substr,
    "substring" => :substr,
    "starts_with" => :starts_with,
    "sqrt" => :sqrt,
    "ln" => :ln,
    "log" => :log,
    "pow" => :pow,
    "power" => :power,
    "greatest" => :greatest,
    "least" => :least
  }

  @typedoc "A function of this module."
  @type name ::
          :lower
          | :upper
          | :length
          | :substr
          | :starts_with
          | :sqrt
          | :ln
          | :log
          | :pow
          | :power
          | :greatest
          | :least

  @doc "The function a name (any case) calls, or `nil`."
  @spec lookup(binary()) :: name() | nil
  def lookup(name), do: Map.get(@names, String.downcase(name))

  @doc "Whether the function is one of this module's."
  @spec function?(atom()) :: boolean()
  def function?(name), do: name in Map.values(@names)

  @doc "The Arrow type of a call, given the types of its arguments (`nil` when not known)."
  @spec type_of(name(), [binary() | nil]) :: binary() | nil
  def type_of(name, _types) when name in [:lower, :upper], do: "Utf8"
  def type_of(:substr, _types), do: "Utf8View"
  def type_of(:length, _types), do: "Int32"
  def type_of(:starts_with, _types), do: "Boolean"
  def type_of(name, _types) when name in [:sqrt, :ln, :log], do: "Float64"

  def type_of(name, types) when name in [:pow, :power],
    do: if(types == ["Int64", "Int64"], do: "Int64", else: "Float64")

  def type_of(name, _types) when name in [:greatest, :least], do: nil

  @doc """
  Evaluates a call the planner has accepted, its arguments already evaluated
  and none of them null.
  """
  @spec compute(name(), [term()]) :: term()
  def compute(:lower, [text]), do: String.downcase(text)
  def compute(:upper, [text]), do: String.upcase(text)

  def compute(:length, [value]),
    do: {:int, 32, value |> SQLCompare.text() |> String.to_charlist() |> length()}

  def compute(:substr, [text, from]), do: substring(text, from, nil)
  def compute(:substr, [text, from, count]), do: substring(text, from, count)
  def compute(:starts_with, [text, prefix]), do: String.starts_with?(text, prefix)
  def compute(:sqrt, [x]), do: x |> SQLNumber.to_float() |> square_root()
  def compute(:ln, [x]), do: x |> SQLNumber.to_float() |> natural_log()
  def compute(:log, [x]), do: compute(:log, [10, x])

  def compute(:log, [base, x]) do
    SQLNumber.arithmetic(
      :/,
      x |> SQLNumber.to_float() |> natural_log(),
      base |> SQLNumber.to_float() |> natural_log()
    )
  end

  def compute(name, [base, exponent]) when name in [:pow, :power], do: power(base, exponent)

  @doc "The largest (`:greatest`) or smallest (`:least`) of the values that are not null."
  @spec extreme(:greatest | :least, [term()]) :: term()
  def extreme(name, values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      present -> Enum.reduce(present, &pick(name, &1, &2))
    end
  end

  @spec pick(:greatest | :least, term(), term()) :: term()
  defp pick(:greatest, value, best),
    do: if(SQLCompare.compare(value, :gt, best), do: value, else: best)

  defp pick(:least, value, best),
    do: if(SQLCompare.compare(value, :lt, best), do: value, else: best)

  # ---------------------------------------------------------------------------
  # substr
  # ---------------------------------------------------------------------------

  @spec substring(binary(), term(), term()) :: binary()
  defp substring(text, from, count) do
    start = integer(from)
    length = if count, do: integer(count)

    cond do
      not is_nil(length) and start == SQLLimits.int64_min() -> closed()
      not is_nil(length) and length < 0 -> closed()
      true -> slice(text, start, length)
    end
  end

  # The characters at positions `start` to `start + length - 1`, those the
  # text has.
  @spec slice(binary(), integer(), integer() | nil) :: binary()
  defp slice(text, start, length) do
    first = max(start, 1)
    last = if length, do: start + length - 1, else: :infinity
    characters = String.codepoints(text)

    if last != :infinity and last < first,
      do: "",
      else: characters |> Enum.drop(first - 1) |> take(last, first) |> Enum.join()
  end

  defp take(characters, :infinity, _first), do: characters
  defp take(characters, last, first), do: Enum.take(characters, last - first + 1)

  @spec integer(term()) :: integer()
  defp integer({:int, _bits, value}), do: value
  defp integer({:u, value}), do: value
  defp integer(value) when is_integer(value), do: value

  # ---------------------------------------------------------------------------
  # math
  # ---------------------------------------------------------------------------

  @spec square_root(float() | SQLNumber.special()) :: float() | SQLNumber.special()
  defp square_root(x) when is_float(x), do: if(x < 0, do: :nan, else: :math.sqrt(x))
  defp square_root(:inf), do: :inf
  defp square_root(_special), do: :nan

  @spec natural_log(float() | SQLNumber.special()) :: float() | SQLNumber.special()
  defp natural_log(x) when is_float(x) and x > 0, do: :math.log(x)
  defp natural_log(x) when x == 0, do: :neg_inf
  defp natural_log(:inf), do: :inf
  defp natural_log(_negative_or_special), do: :nan

  @spec power(term(), term()) :: term()
  defp power(base, exponent) when is_integer(base) and is_integer(exponent) do
    if exponent < 0, do: closed(), else: checked_power(base, exponent)
  end

  defp power(base, exponent) do
    if tagged?(base) or tagged?(exponent),
      do:
        refused(
          "pow of an unsigned or narrow integer, or a decimal: the engine's coercion for it " <>
            "is not modelled"
        ),
      else: float_power(SQLNumber.to_float(base), SQLNumber.to_float(exponent))
  end

  @spec tagged?(term()) :: boolean()
  defp tagged?(value), do: is_tuple(value)

  @spec checked_power(integer(), non_neg_integer()) :: integer()
  defp checked_power(base, exponent) do
    result = Integer.pow(base, exponent)

    if result < SQLLimits.int64_min() or result > SQLLimits.int64_max(),
      do: closed(),
      else: result
  end

  @spec float_power(float() | SQLNumber.special(), float() | SQLNumber.special()) ::
          float() | SQLNumber.special()
  defp float_power(base, exponent) when is_float(base) and is_float(exponent) do
    if base == 0 and exponent < 0, do: :inf, else: :math.pow(base, exponent)
  rescue
    ArithmeticError -> power_error(base, exponent)
  end

  defp float_power(_base, _exponent),
    do: refused("pow of an infinity or a NaN: the engine's result for it is not modelled")

  # `:math.pow/2` raises where Rust's `powf` answers: an overflow is an
  # infinity, a negative base with a fractional exponent a NaN.
  @spec power_error(float(), float()) :: float() | SQLNumber.special()
  defp power_error(base, exponent) do
    if base < 0 and exponent != Float.round(exponent),
      do: :nan,
      else: if(base < 0 and rem(trunc(exponent), 2) != 0, do: :neg_inf, else: :inf)
  end

  @spec closed() :: no_return()
  defp closed, do: throw({:query_error, SQLError.closed()})

  @spec refused(binary()) :: no_return()
  defp refused(message), do: throw({:query_error, SQLError.refusal(message)})
end
