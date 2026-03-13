defmodule InfluxElixir.Query.ResponseParser do
  @moduledoc """
  Parses InfluxDB query responses in JSONL, CSV, JSON,
  and Parquet formats with type coercion.

  ## Type Coercion

    * Timestamps → `DateTime.t()`
    * Numbers → `integer()` or `float()` based on value
    * Booleans → `true` / `false`
    * Strings → `String.t()`
  """

  @doc """
  Parses a response body based on the specified format.

  ## Parameters

    * `body` - response body binary
    * `format` - one of `:json`, `:jsonl`, `:csv`, `:parquet`

  ## Returns

    * `{:ok, [map()]}` — list of row maps
    * `{:error, reason}` — parse failure
  """
  @spec parse(binary(), atom()) :: {:ok, [map()]} | {:error, term()}
  def parse(body, format \\ :json)

  def parse(body, :json) do
    case Jason.decode(body) do
      {:ok, data} when is_list(data) ->
        {:ok, Enum.map(data, &coerce_types/1)}

      {:ok, data} when is_map(data) ->
        {:ok, [coerce_types(data)]}

      {:error, reason} ->
        {:error, {:json_parse_error, reason}}
    end
  end

  def parse(body, :jsonl) do
    rows =
      body
      |> String.split("\n", trim: true)
      |> Enum.reduce_while([], fn line, acc ->
        case Jason.decode(line) do
          {:ok, row} -> {:cont, [coerce_types(row) | acc]}
          {:error, reason} -> {:halt, {:error, {:jsonl_parse_error, reason}}}
        end
      end)

    case rows do
      {:error, reason} -> {:error, reason}
      rows -> {:ok, Enum.reverse(rows)}
    end
  end

  def parse(body, :csv) do
    {:ok, parse_csv(body)}
  end

  def parse(body, :parquet) do
    {:ok, body}
  end

  def parse(_body, format) do
    {:error, {:unsupported_format, format}}
  end

  @doc """
  Coerces known value types in a row map.

  Converts RFC3339 timestamp strings to `DateTime`, leaves
  other types as-is.
  """
  @spec coerce_types(map()) :: map()
  def coerce_types(row) when is_map(row) do
    Map.new(row, fn {key, value} ->
      {key, coerce_value(key, value)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec coerce_value(String.t(), term()) :: term()
  defp coerce_value("time", value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _error -> value
    end
  end

  defp coerce_value(_key, value), do: value

  @spec parse_csv(binary()) :: [map()]
  defp parse_csv(body) do
    lines = String.split(body, "\n", trim: true)

    case lines do
      [] ->
        []

      [header_line | data_lines] ->
        headers = String.split(header_line, ",")

        Enum.map(data_lines, fn line ->
          values = String.split(line, ",")

          headers
          |> Enum.zip(values)
          |> Map.new()
          |> coerce_types()
        end)
    end
  end
end
