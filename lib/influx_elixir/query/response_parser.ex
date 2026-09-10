defmodule InfluxElixir.Query.ResponseParser do
  @moduledoc """
  Parses InfluxDB query responses in JSON, JSONL, and Flux annotated CSV
  formats, and passes Parquet bodies through untouched.

  ## Type Coercion

    * `time`, `_time`, `_start`, `_stop` RFC3339 strings → `DateTime.t()`
    * JSON / JSONL numbers and booleans keep the types Jason decodes
    * CSV cells are typed from the Flux `#datatype` annotation row when the
      query requested one (`double`, `long`, `unsignedLong`, `boolean`,
      `dateTime:RFC3339[Nano]`); without it every cell stays a string
  """

  alias NimbleCSV.RFC4180, as: CSV

  @time_keys ~w(time _time _start _stop)

  @doc """
  Parses a response body based on the specified format.

  ## Parameters

    * `body` - response body binary
    * `format` - one of `:json`, `:jsonl`, `:csv`, `:parquet`

  ## Returns

    * `{:ok, [map()]}` — list of row maps (`{:ok, binary()}` for `:parquet`)
    * `{:error, reason}` — parse failure
  """
  @spec parse(binary(), atom()) :: {:ok, [map()] | binary()} | {:error, term()}
  def parse(body, format \\ :json)

  def parse(body, :json) do
    case Jason.decode(body) do
      {:ok, data} when is_list(data) -> {:ok, Enum.map(data, &coerce_types/1)}
      {:ok, data} when is_map(data) -> {:ok, [coerce_types(data)]}
      {:ok, other} -> {:error, {:unexpected_json, other}}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  def parse(body, :jsonl) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, row} -> {:cont, {:ok, [coerce_types(row) | acc]}}
        {:error, reason} -> {:halt, {:error, {:jsonl_parse_error, reason}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _reason} = error -> error
    end
  end

  def parse(body, :csv), do: {:ok, parse_csv(body)}

  def parse(body, :parquet), do: {:ok, body}

  def parse(_body, format), do: {:error, {:unsupported_format, format}}

  @doc """
  Coerces known value types in a row map.

  Converts RFC3339 strings under `time`, `_time`, `_start` and `_stop` to
  `DateTime`; leaves everything else as-is.
  """
  @spec coerce_types(map()) :: map()
  def coerce_types(row) when is_map(row) do
    Map.new(row, fn {key, value} -> {key, coerce_value(key, value)} end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec coerce_value(String.t(), term()) :: term()
  defp coerce_value(key, value) when key in @time_keys and is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _error -> value
    end
  end

  defp coerce_value(_key, value), do: value

  # Flux annotated CSV: tables are separated by an empty line; each table
  # starts with optional `#`-prefixed annotation rows, then a header row.
  # The first column is the annotation column (empty header) and is dropped.
  # Lines end in CRLF and cells may be quoted — NimbleCSV handles both.
  @spec parse_csv(binary()) :: [map()]
  defp parse_csv(body) do
    body
    |> CSV.parse_string(skip_headers: false)
    |> Enum.chunk_by(&blank_row?/1)
    |> Enum.reject(fn [row | _rest] -> blank_row?(row) end)
    |> Enum.flat_map(&parse_csv_table/1)
  end

  @spec blank_row?([binary()]) :: boolean()
  defp blank_row?([]), do: true
  defp blank_row?([""]), do: true
  defp blank_row?(_row), do: false

  @spec parse_csv_table([[binary()]]) :: [map()]
  defp parse_csv_table(rows) do
    case Enum.split_while(rows, &annotation_row?/1) do
      {annotations, [header | data]} ->
        datatypes = annotation(annotations, "#datatype")
        columns = Enum.zip(header, datatypes ++ List.duplicate(nil, length(header)))
        Enum.map(data, &csv_row(columns, &1))

      {_annotations_only, []} ->
        []
    end
  end

  @spec annotation_row?([binary()]) :: boolean()
  defp annotation_row?([first | _rest]), do: String.starts_with?(first, "#")
  defp annotation_row?(_row), do: false

  # The annotation row's first cell is its name ("#datatype"); the rest line
  # up with the header columns after the annotation column.
  @spec annotation([[binary()]], binary()) :: [binary() | nil]
  defp annotation(rows, name) do
    case Enum.find(rows, fn [first | _rest] -> first == name end) do
      [_name | types] -> [nil | types]
      nil -> []
    end
  end

  @spec csv_row([{binary(), binary() | nil}], [binary()]) :: map()
  defp csv_row(columns, values) do
    columns
    |> Enum.zip(values)
    |> Enum.reject(fn {{name, _type}, _value} -> name == "" end)
    |> Map.new(fn {{name, type}, value} -> {name, cast(type, name, value)} end)
  end

  @spec cast(binary() | nil, binary(), binary()) :: term()
  defp cast(_type, _key, ""), do: nil
  defp cast("double", _key, value), do: parse_number(Float.parse(value), value)
  defp cast("long", _key, value), do: parse_number(Integer.parse(value), value)
  defp cast("unsignedLong", _key, value), do: parse_number(Integer.parse(value), value)
  defp cast("boolean", _key, "true"), do: true
  defp cast("boolean", _key, "false"), do: false
  defp cast("dateTime:" <> _layout, key, value), do: coerce_value(key, value)
  defp cast(_type, key, value), do: coerce_value(key, value)

  @spec parse_number({number(), binary()} | :error, binary()) :: number() | binary()
  defp parse_number({number, ""}, _raw), do: number
  defp parse_number(_other, raw), do: raw
end
