defmodule InfluxElixir.Write.LineProtocol do
  @moduledoc """
  Encodes Point structs into InfluxDB line protocol format.

  Handles tag sorting, field type encoding, escaping,
  multi-point delimiters, and timestamp conversion.

  ## Line Protocol Format

      measurement[,tag_key=tag_val]... field_key=field_val[,field_key=field_val]... [timestamp]

  ## Field Type Encoding

  - Integers: suffixed with `i` (e.g. `42i`)
  - Floats: as-is (e.g. `0.64`)
  - Strings: double-quoted (e.g. `"hello"`)
  - Booleans: `true` or `false`

  ## Escaping Rules

  - Measurement names: spaces, commas, backslashes
  - Tag keys/values: spaces, commas, equals, backslashes
  - Field keys: spaces, commas, equals, backslashes
  - Field string values: double-quotes, backslashes
  """

  alias InfluxElixir.Write.Point

  @type encode_result :: {:ok, binary()} | {:error, term()}

  @doc """
  Encodes a Point or list of Points into InfluxDB line protocol binary.

  Returns `{:ok, binary}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> point = InfluxElixir.Write.Point.new("cpu", %{"value" => 0.64})
      iex> {:ok, lp} = InfluxElixir.Write.LineProtocol.encode(point)
      iex> lp
      "cpu value=0.64"

      iex> point = InfluxElixir.Write.Point.new("cpu", %{"count" => 42},
      ...>   tags: %{"host" => "server01"},
      ...>   timestamp: 1_630_424_257_000_000_000
      ...> )
      iex> {:ok, lp} = InfluxElixir.Write.LineProtocol.encode(point)
      iex> lp
      "cpu,host=server01 count=42i 1630424257000000000"
  """
  @spec encode(Point.t() | [Point.t()]) :: encode_result()
  def encode(%Point{} = point) do
    case encode_point(point) do
      {:ok, line} -> {:ok, line}
      {:error, reason} -> {:error, reason}
    end
  end

  def encode(points) when is_list(points) do
    points
    |> Enum.reduce_while({:ok, []}, fn point, {:ok, acc} ->
      case encode_point(point) do
        {:ok, line} -> {:cont, {:ok, [line | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, lines |> Enum.reverse() |> Enum.join("\n")}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Encodes a Point or list of Points into InfluxDB line protocol binary.

  Raises `ArgumentError` on failure.

  ## Examples

      iex> point = InfluxElixir.Write.Point.new("cpu", %{"value" => 0.64})
      iex> InfluxElixir.Write.LineProtocol.encode!(point)
      "cpu value=0.64"
  """
  @spec encode!(Point.t() | [Point.t()]) :: binary()
  def encode!(point_or_points) do
    case encode(point_or_points) do
      {:ok, line} -> line
      {:error, reason} -> raise ArgumentError, "LineProtocol encode failed: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec encode_point(Point.t()) :: encode_result()
  defp encode_point(%Point{measurement: measurement, tags: tags, fields: fields, timestamp: ts}) do
    with :ok <- validate_fields(fields),
         {:ok, measurement_str} <- encode_measurement(measurement),
         {:ok, tags_str} <- encode_tags(tags),
         {:ok, fields_str} <- encode_fields(fields),
         {:ok, timestamp_str} <- encode_timestamp(ts) do
      line =
        case {tags_str, timestamp_str} do
          {"", ""} -> "#{measurement_str} #{fields_str}"
          {"", ts_str} -> "#{measurement_str} #{fields_str} #{ts_str}"
          {t, ""} -> "#{measurement_str},#{t} #{fields_str}"
          {t, ts_str} -> "#{measurement_str},#{t} #{fields_str} #{ts_str}"
        end

      {:ok, line}
    end
  end

  @spec validate_fields(%{String.t() => Point.field_value()}) :: :ok | {:error, term()}
  defp validate_fields(fields) when map_size(fields) == 0,
    do: {:error, :empty_fields}

  defp validate_fields(_fields), do: :ok

  @spec encode_measurement(String.t()) :: {:ok, binary()} | {:error, term()}
  defp encode_measurement(""), do: {:error, :empty_measurement}

  defp encode_measurement(name) do
    escaped =
      name
      |> String.replace("\\", "\\\\")
      |> String.replace(",", "\\,")
      |> String.replace(" ", "\\ ")

    {:ok, escaped}
  end

  @spec encode_tags(%{String.t() => String.t()}) :: {:ok, binary()} | {:error, term()}
  defp encode_tags(tags) when map_size(tags) == 0, do: {:ok, ""}

  defp encode_tags(tags) do
    tags
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> "#{escape_tag_key(k)}=#{escape_tag_value(v)}" end)
    |> Enum.join(",")
    |> then(&{:ok, &1})
  end

  @spec encode_fields(%{String.t() => Point.field_value()}) ::
          {:ok, binary()} | {:error, term()}
  defp encode_fields(fields) do
    fields
    |> Enum.map(fn {k, v} -> "#{escape_field_key(k)}=#{encode_field_value(v)}" end)
    |> Enum.join(",")
    |> then(&{:ok, &1})
  end

  @spec encode_timestamp(DateTime.t() | integer() | nil) ::
          {:ok, binary()} | {:error, term()}
  defp encode_timestamp(nil), do: {:ok, ""}

  defp encode_timestamp(%DateTime{} = dt) do
    nanos =
      dt
      |> DateTime.to_unix(:nanosecond)

    {:ok, Integer.to_string(nanos)}
  end

  defp encode_timestamp(ts) when is_integer(ts) do
    {:ok, Integer.to_string(ts)}
  end

  defp encode_timestamp(ts), do: {:error, {:invalid_timestamp, ts}}

  # Tag key escaping: spaces, commas, equals, backslashes
  @spec escape_tag_key(String.t()) :: binary()
  defp escape_tag_key(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace("=", "\\=")
    |> String.replace(" ", "\\ ")
  end

  # Tag value escaping: same as tag key
  @spec escape_tag_value(String.t()) :: binary()
  defp escape_tag_value(str), do: escape_tag_key(str)

  # Field key escaping: same as tag key
  @spec escape_field_key(String.t()) :: binary()
  defp escape_field_key(str), do: escape_tag_key(str)

  # Field value encoding by type
  @spec encode_field_value(Point.field_value()) :: binary()
  defp encode_field_value(value) when is_integer(value) do
    "#{value}i"
  end

  defp encode_field_value(value) when is_float(value) do
    # Use Erlang's float_to_list for full precision
    :erlang.float_to_binary(value, [:compact, {:decimals, 17}])
    |> normalize_float_string()
  end

  defp encode_field_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp encode_field_value(true), do: "true"
  defp encode_field_value(false), do: "false"

  # Ensure the float string always has a decimal point
  @spec normalize_float_string(binary()) :: binary()
  defp normalize_float_string(str) do
    if String.contains?(str, ".") or String.contains?(str, "e") do
      str
    else
      str <> ".0"
    end
  end
end
