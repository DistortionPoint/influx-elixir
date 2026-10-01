defmodule InfluxElixir.Client.QueryParams do
  @compile {:no_warn_undefined, Decimal}

  @moduledoc """
  The `params:` of a SQL query, as both clients send and read them.

  `Client.HTTP` sends the parameters as the JSON object of the request body;
  `Client.Local` binds what the engine would read from that object. Both
  start from `normalize/1`, so a value either client refuses is refused with
  the same error tuple, and the JSON `Client.HTTP` sends is the JSON
  `Client.Local` reads back with `engine_values/1`.

  A parameter is a `nil`, boolean, number, string, atom (sent as its name),
  `Date`, `Time`, `NaiveDateTime`, `DateTime` (sent as ISO-8601 strings) or a
  `Decimal`, which is sent as a JSON number: `Jason` encodes a `Decimal` as a
  string, which the engine would compare as text. A map or a list encodes but
  is refused by the engine (`Client.HTTP` returns its 400, `Client.Local` the
  same body).

  ## Errors

    * `{:invalid_param, name, :non_finite_decimal}` — a `Decimal` that is NaN
      or an infinity, which has no JSON number
    * `{:invalid_param, name, :unsupported_type}` — a value `Jason` cannot
      encode (a tuple, a pid, a function)

  `name` is the parameter's name as a string.
  """

  @typedoc "The parameters as the request body carries them: string keys, JSON-encodable values."
  @type t :: %{binary() => term()}

  @typedoc "Why a parameter cannot be sent."
  @type reason :: :non_finite_decimal | :unsupported_type

  @typedoc "The error `normalize/1` returns: the parameter's name and why it is refused."
  @type error :: {:invalid_param, binary(), reason()}

  @int64_min -9_223_372_036_854_775_808
  @uint64_max 18_446_744_073_709_551_615

  @doc """
  Validates the parameters (a map or a keyword list) and returns them with
  string keys, each value ready for `Jason`.
  """
  @spec normalize(map() | keyword()) ::
          {:ok, t()} | {:error, error()}
  def normalize(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      name = to_string(key)

      case encodable(value) do
        {:ok, json} -> {:cont, {:ok, Map.put(acc, name, json)}}
        {:error, reason} -> {:halt, {:error, {:invalid_param, name, reason}}}
      end
    end)
  end

  @spec encodable(term()) :: {:ok, term()} | {:error, reason()}
  defp encodable(%{__struct__: Decimal, coef: coef}) when coef in [:NaN, :inf],
    do: {:error, :non_finite_decimal}

  defp encodable(%{__struct__: Decimal} = value),
    do: {:ok, Jason.Fragment.new(Decimal.to_string(value, :normal))}

  defp encodable(value) do
    case Jason.encode(value) do
      {:ok, _json} -> {:ok, value}
      {:error, _exception} -> {:error, :unsupported_type}
    end
  end

  @doc """
  What the engine reads from the parameters: the request body's JSON decoded.
  A number outside the engine's `Int64`/`UInt64` range is a float there.
  """
  @spec engine_values(t()) :: %{binary() => term()}
  def engine_values(params) do
    Map.new(params, fn {name, value} ->
      {name, value |> Jason.encode!() |> Jason.decode!() |> in_range()}
    end)
  end

  @spec in_range(term()) :: term()
  defp in_range(value) when is_integer(value) and (value < @int64_min or value > @uint64_max),
    do: value * 1.0

  defp in_range(value), do: value
end
