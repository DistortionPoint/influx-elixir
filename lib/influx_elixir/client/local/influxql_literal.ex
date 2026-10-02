defmodule InfluxElixir.Client.Local.InfluxQLLiteral do
  @moduledoc """
  A constant in the select list of an InfluxQL statement. The engine reads
  the statement and then refuses it while it plans (verified): a select item
  that is a constant has "no variable" in it, and a function given a constant
  expects "a field argument", naming the constant the way the engine's parser
  holds it (`Literal(Boolean(true))`, `Literal(Integer(1))`,
  `Literal(Float(1.5))`, `Literal(String("a"))`,
  `Literal(Duration(Duration(5000000000)))`).
  """

  alias InfluxElixir.Client.Local.InfluxQLError

  @max_signed 9_223_372_036_854_775_807

  @duration_ns %{
    "ns" => 1,
    "u" => 1_000,
    "µ" => 1_000,
    "ms" => 1_000_000,
    "s" => 1_000_000_000,
    "m" => 60_000_000_000,
    "h" => 3_600_000_000_000,
    "d" => 86_400_000_000_000,
    "w" => 604_800_000_000_000
  }

  @functions ~w(mean sum count min max first last)

  @doc """
  The engine's name for a constant written as `text`: `{:ok, "Boolean(true)"}`,
  `:none` when the text is no constant, `{:error, message}` for a constant
  the double cannot name as the engine does.
  """
  @spec debug(binary()) :: {:ok, binary()} | :none | {:error, binary()}
  def debug(text) do
    cond do
      String.downcase(text) in ["true", "false"] ->
        {:ok, "Boolean(#{String.downcase(text)})"}

      Regex.match?(~r/^[+-]?\d+$/, text) ->
        integer(text)

      Regex.match?(~r/^[+-]?(?:\d+\.\d+|\.\d+)$/, text) ->
        float(text)

      Regex.match?(~r/^\d+(?:ns|ms|u|µ|s|m|h|d|w)$/u, text) ->
        duration(text)

      String.starts_with?(text, "'") and String.ends_with?(text, "'") and byte_size(text) > 1 ->
        string(binary_part(text, 1, byte_size(text) - 2))

      true ->
        :none
    end
  end

  @spec integer(binary()) :: {:ok, binary()} | {:error, binary()}
  defp integer(text) do
    case String.to_integer(text) do
      n when abs(n) <= @max_signed -> {:ok, "Integer(#{n})"}
      _beyond -> {:error, "an integer constant beyond 64 bits"}
    end
  end

  # A float prints as the engine's Rust `Debug` does: the shortest digits
  # that read back, in plain notation from 1e-4 up to 1e16. One outside that
  # is out of reach.
  @spec float(binary()) :: {:ok, binary()} | {:error, binary()}
  defp float(text) do
    value = text |> String.trim_leading("+") |> normalise() |> String.to_float()

    if value == 0.0 or (abs(value) >= 1.0e-4 and abs(value) < 1.0e16),
      do: {:ok, "Float(#{value |> Float.to_string() |> plain()})"},
      else: {:error, "a float constant of that size"}
  end

  @spec normalise(binary()) :: binary()
  defp normalise("-." <> fraction), do: "-0." <> fraction
  defp normalise("." <> fraction), do: "0." <> fraction
  defp normalise(text), do: text

  # Elixir prints the shortest digits with an exponent where Rust prints the
  # digits in full (`1.0e14` is `100000000000000.0`).
  @spec plain(binary()) :: binary()
  defp plain(text) do
    case String.split(text, "e") do
      [plain] -> plain
      [mantissa, exponent] -> shift(mantissa, String.to_integer(exponent))
    end
  end

  @spec shift(binary(), integer()) :: binary()
  defp shift(mantissa, exponent) do
    {sign, unsigned} = split_sign(mantissa)
    [whole, fraction] = String.split(unsigned, ".")
    digits = whole <> String.trim_trailing(fraction, "0")
    point = byte_size(whole) + exponent
    size = byte_size(digits)

    cond do
      point >= size ->
        sign <> digits <> String.duplicate("0", point - size) <> ".0"

      point <= 0 ->
        sign <> "0." <> String.duplicate("0", -point) <> digits

      true ->
        sign <> binary_part(digits, 0, point) <> "." <> binary_part(digits, point, size - point)
    end
  end

  @spec split_sign(binary()) :: {binary(), binary()}
  defp split_sign("-" <> unsigned), do: {"-", unsigned}
  defp split_sign(unsigned), do: {"", unsigned}

  @spec duration(binary()) :: {:ok, binary()}
  defp duration(text) do
    [count, unit] = Regex.run(~r/^(\d+)(ns|ms|u|µ|s|m|h|d|w)$/u, text, capture: :all_but_first)
    ns = String.to_integer(count) * Map.fetch!(@duration_ns, unit)
    {:ok, "Duration(Duration(#{ns}))"}
  end

  # A string constant, its `\'` undone; one with any other backslash, or with
  # a character Rust escapes in `Debug` beyond the quote and the backslash, is
  # out of reach.
  @spec string(binary()) :: {:ok, binary()} | {:error, binary()}
  defp string(inner) do
    text = String.replace(inner, "\\'", "'")

    if String.contains?(text, "\\") or not String.printable?(text) or
         Regex.match?(~r/[\x00-\x1f\x7f]/, text),
       do: {:error, "a string constant with escapes"},
       else: {:ok, ~s|String("#{String.replace(text, "\"", "\\\"")}")|}
  end

  @doc """
  The engine's planning error for the first item of a select list that is a
  constant, or a function of one, `:ok` when there is none.
  """
  @spec check_items([term()]) :: :ok | {:error, {:engine, binary()}}
  def check_items(items) do
    Enum.find_value(items, :ok, fn
      {:literal, _text} ->
        {:error,
         {:engine, InfluxQLError.select_error("field must contain at least one variable")}}

      {:aggregate, fun, {:literal, debug}, _alias} when fun in @functions ->
        message = "expected field argument in #{fun}(), got Literal(#{debug})"
        {:error, {:engine, InfluxQLError.select_error(message)}}

      _item ->
        nil
    end)
  end

  @doc "Whether an item is a constant or a function of one."
  @spec literal_item?(term()) :: boolean()
  def literal_item?({:literal, _text}), do: true
  def literal_item?({:aggregate, _fun, {:literal, _debug}, _alias}), do: true
  def literal_item?(_item), do: false
end
