defmodule InfluxElixir.Client.QueryParams do
  @compile {:no_warn_undefined, Decimal}

  @moduledoc """
  The `params:` of a SQL query, as both clients send and read them.

  `Client.HTTP` sends the parameters as the JSON object of the request body;
  `Client.Local` binds what the engine would read from that object. Both
  start from `normalize/1`, so a value either client refuses is refused with
  the same error tuple, and the JSON `Client.HTTP` sends is the JSON
  `Client.Local` reads back with `engine_values/1`.

  `params:` is a map or a keyword list, or `nil` for none (the engine accepts
  `"params": null`). A parameter is a `nil`, boolean, number, string, atom
  (sent as its name), `Date`, `Time`, `NaiveDateTime`, `DateTime` (sent as
  ISO-8601 strings) or a `Decimal`, which is sent as a JSON number: `Jason`
  encodes a `Decimal` as a string, which the engine would compare as text. A
  map or a list encodes but is refused by the engine (`Client.HTTP` returns
  its 400, `Client.Local` the same body), and so is a number its JSON parser
  cannot read (`1e400`, `Integer.pow(10, 400)`): `number out of range`.

  ## Errors

    * `{:invalid_param, name, :non_finite_decimal}` — a `Decimal` that is NaN
      or an infinity, which has no JSON number
    * `{:invalid_param, name, :unsupported_type}` — a value `Jason` cannot
      encode (a tuple, a pid, a function)
    * `{:invalid_param, name, :unsupported_key}` — a name that is not a
      string, an atom or a number (a tuple)
    * `{:invalid_param, name, :unsupported_params}` — `params:` itself is
      neither a map nor a keyword list

  `name` is the parameter's name as a string, or the inspected term for an
  unsupported key or `params:` value.
  """

  @typedoc "The parameters as the request body carries them: string keys, JSON-encodable values."
  @type t :: %{binary() => term()}

  @typedoc "Why a parameter cannot be sent."
  @type reason ::
          :non_finite_decimal | :unsupported_type | :unsupported_key | :unsupported_params

  @typedoc "The error `normalize/1` returns: the parameter's name and why it is refused."
  @type error :: {:invalid_param, binary(), reason()}

  @typedoc "What the engine's JSON parser finds wrong with one parameter, if anything."
  @type problem :: :object | :array | :out_of_range

  @u64_max 18_446_744_073_709_551_615
  @i64_abs 9_223_372_036_854_775_808
  @i32_max 2_147_483_647

  # serde_json's table of powers of ten: the literals `1e0` to `1e308`.
  @pow10 List.to_tuple(for k <- 0..308, do: String.to_float("1.0e#{k}"))

  @doc """
  Validates the parameters (a map, a keyword list or `nil`) and returns them
  with string keys, each value ready for `Jason`.
  """
  @spec normalize(map() | keyword() | nil) :: {:ok, t()} | {:error, error()}
  def normalize(nil), do: {:ok, %{}}

  def normalize(params) when is_list(params) or (is_map(params) and not is_struct(params)) do
    Enum.reduce_while(params, {:ok, %{}}, fn entry, {:ok, acc} ->
      with {:ok, key, value} <- entry(entry),
           {:ok, name} <- key_name(key),
           {:ok, json} <- encodable(name, value) do
        {:cont, {:ok, Map.put(acc, name, json)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def normalize(other), do: {:error, {:invalid_param, inspect(other), :unsupported_params}}

  @spec entry(term()) :: {:ok, term(), term()} | {:error, error()}
  defp entry({key, value}), do: {:ok, key, value}
  defp entry(other), do: {:error, {:invalid_param, inspect(other), :unsupported_key}}

  @spec key_name(term()) :: {:ok, binary()} | {:error, error()}
  defp key_name(key) when is_binary(key), do: {:ok, key}
  defp key_name(key) when is_atom(key) or is_number(key), do: {:ok, to_string(key)}
  defp key_name(key), do: {:error, {:invalid_param, inspect(key), :unsupported_key}}

  @spec encodable(binary(), term()) :: {:ok, term()} | {:error, error()}
  defp encodable(name, %{__struct__: Decimal, coef: coef}) when coef in [:NaN, :inf],
    do: {:error, {:invalid_param, name, :non_finite_decimal}}

  defp encodable(_name, %{__struct__: Decimal} = value),
    do: {:ok, Jason.Fragment.new(Decimal.to_string(value, :normal))}

  defp encodable(name, value) do
    case Jason.encode(value) do
      {:ok, _json} -> {:ok, value}
      {:error, _exception} -> {:error, {:invalid_param, name, :unsupported_type}}
    end
  end

  @doc """
  The JSON body `Client.HTTP` posts to `/api/v3/query_sql`: `db` (left out
  when `database` is `nil`), `format` (left out when it is `nil`, as for a
  statement run with `execute_sql`), `params` and `q`, written in that order
  (Jason writes a small map's keys sorted). The engine's JSON parser reports
  an error by its byte position in this body, so `Client.Local` and the
  contract tests that pin the position read it from here.
  """
  @spec request_body(binary() | nil, binary(), t(), term()) :: binary()
  def request_body(database, sql, params, format) do
    body = %{"q" => sql, "params" => params}
    body = if database == nil, do: body, else: Map.put(body, "db", database)
    body = if format == nil, do: body, else: Map.put(body, "format", to_string(format))
    Jason.encode!(body)
  end

  @doc """
  What the engine reads from the parameters: the request body's JSON read
  as its parser reads it. A number is read as `serde_json` reads it: an
  integer in the `Int64`/`UInt64` range stays one, any other is a float. The
  parameters must be free of `problem/1`s.
  """
  @spec engine_values(t()) :: %{binary() => term()}
  def engine_values(params) do
    Map.new(params, fn {name, value} ->
      json = Jason.encode!(value)

      case number_text(json) do
        true -> {name, read_number(json)}
        false -> {name, Jason.decode!(json)}
      end
    end)
  end

  @doc """
  What the engine's JSON parser refuses in one parameter: an object, an array
  or a number it cannot read; `nil` when it reads it.
  """
  @spec problem(term()) :: problem() | nil
  def problem(value) do
    json = Jason.encode!(value)

    cond do
      String.starts_with?(json, "{") -> :object
      String.starts_with?(json, "[") -> :array
      number_text(json) and read_number(json) == :out_of_range -> :out_of_range
      true -> nil
    end
  end

  @spec number_text(binary()) :: boolean()
  defp number_text(<<c, _rest::binary>>), do: c in ?0..?9 or c == ?-

  # ---------------------------------------------------------------------------
  # A JSON number as `serde_json` reads it
  #
  # Without its `float_roundtrip` feature the parser keeps the first digits
  # that fit a `u64` as the significand and the rest as an exponent, and
  # makes the float by one multiplication or division with a power of ten.
  # The result can differ from the correctly rounded float by an ulp, and a
  # number whose product overflows is `number out of range` — whatever the
  # float range: `1.7976931348623158e308` is out, `1.7976931348623157e308`
  # is in (all verified against InfluxDB 3 Core).
  # ---------------------------------------------------------------------------

  @spec read_number(binary()) :: integer() | float() | :out_of_range
  defp read_number(json) do
    {positive, digits} =
      case json do
        "-" <> rest -> {false, rest}
        rest -> {true, rest}
      end

    {whole, after_whole} = take_digits(digits)
    {significand, overflow} = significand(whole)
    read_rest(positive, significand, overflow, after_whole)
  end

  # The leading digits that fit a `u64`, and how many digits were left over.
  @spec significand(binary()) :: {non_neg_integer(), non_neg_integer()}
  defp significand(digits), do: significand(digits, 0)

  defp significand(<<>>, acc), do: {acc, 0}

  defp significand(<<d, rest::binary>> = digits, acc) do
    next = acc * 10 + d - ?0
    if next > @u64_max, do: {acc, byte_size(digits)}, else: significand(rest, next)
  end

  @spec read_rest(boolean(), non_neg_integer(), non_neg_integer(), binary()) ::
          integer() | float() | :out_of_range
  defp read_rest(positive, significand, 0, "") do
    cond do
      positive -> significand
      significand == 0 -> -0.0
      significand <= @i64_abs -> -significand
      true -> -(significand * 1.0)
    end
  end

  defp read_rest(positive, significand, overflow, "." <> fraction) do
    {digits, after_fraction} = take_digits(fraction)
    {significand, exponent} = decimal(significand, digits, overflow)
    exponent_or_parts(positive, significand, exponent, after_fraction)
  end

  defp read_rest(positive, significand, overflow, rest),
    do: exponent_or_parts(positive, significand, overflow, rest)

  # The digits after the point join the significand while they fit; each
  # one that does moves the exponent down.
  @spec decimal(non_neg_integer(), binary(), integer()) :: {non_neg_integer(), integer()}
  defp decimal(significand, <<>>, exponent), do: {significand, exponent}

  defp decimal(significand, <<d, rest::binary>>, exponent) do
    next = significand * 10 + d - ?0

    if next > @u64_max,
      do: {significand, exponent},
      else: decimal(next, rest, exponent - 1)
  end

  @spec exponent_or_parts(boolean(), non_neg_integer(), integer(), binary()) ::
          float() | :out_of_range
  defp exponent_or_parts(positive, significand, exponent, <<e, rest::binary>>)
       when e in [?e, ?E] do
    {positive_exponent, digits} =
      case rest do
        "+" <> more -> {true, more}
        "-" <> more -> {false, more}
        more -> {true, more}
      end

    {text, _tail} = take_digits(digits)
    magnitude = String.to_integer(text)

    cond do
      magnitude > @i32_max and significand == 0 -> zero(positive)
      magnitude > @i32_max and positive_exponent -> :out_of_range
      magnitude > @i32_max -> zero(positive)
      positive_exponent -> from_parts(positive, significand, exponent + magnitude)
      true -> from_parts(positive, significand, exponent - magnitude)
    end
  end

  defp exponent_or_parts(positive, significand, exponent, _rest),
    do: from_parts(positive, significand, exponent)

  @spec zero(boolean()) :: float()
  defp zero(true), do: 0.0
  defp zero(false), do: -0.0

  @spec from_parts(boolean(), non_neg_integer(), integer()) :: float() | :out_of_range
  defp from_parts(positive, significand, exponent) do
    case scale(significand * 1.0, exponent) do
      :out_of_range -> :out_of_range
      value -> if positive, do: value, else: -value
    end
  end

  @spec scale(float(), integer()) :: float() | :out_of_range
  defp scale(f, exponent) when exponent >= 0 and exponent <= 308 do
    f * elem(@pow10, exponent)
  rescue
    ArithmeticError -> :out_of_range
  end

  defp scale(f, exponent) when exponent < 0 and exponent >= -308,
    do: f / elem(@pow10, -exponent)

  defp scale(f, _exponent) when f == 0.0, do: f
  defp scale(_f, exponent) when exponent >= 0, do: :out_of_range
  defp scale(f, exponent), do: scale(f / elem(@pow10, 308), exponent + 308)

  @spec take_digits(binary()) :: {binary(), binary()}
  defp take_digits(text) do
    size = text |> :binary.bin_to_list() |> Enum.take_while(&(&1 in ?0..?9)) |> length()
    {binary_part(text, 0, size), binary_part(text, size, byte_size(text) - size)}
  end
end
