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

  ## Validation

  A point that no InfluxDB accepts is refused here, with a tagged error,
  rather than encoded into a line the server rejects — or worse, one it
  misreads. Line protocol has no escape for a newline outside a quoted
  string value, so a newline in a measurement, tag key, tag value or field
  key ends the line early and the remainder is parsed as a *second* line:
  verified against InfluxDB 3, `tags: %{"host" => "a\\nb"}` stores a bogus
  measurement `b`. The checks, each verified against the engine:

  | Problem | Error |
  |---|---|
  | No fields | `:empty_fields` |
  | Empty measurement | `:empty_measurement` |
  | Measurement not a string, or containing a newline | `{:invalid_measurement, value}` |
  | Tag key empty, not a string, or containing a newline | `{:invalid_tag_key, key}` |
  | Tag value empty, not a string, or containing a newline | `{:invalid_tag_value, key, value}` |
  | Tag key `time` (reserved on every version) | `{:reserved_tag_key, "time"}` |
  | Field key empty, not a string, or containing a newline | `{:invalid_field_key, key}` |
  | Field value not an integer, float, string or boolean | `{:invalid_field_value, key, value}` |
  | Timestamp not a `DateTime`, integer or `nil` | `{:invalid_timestamp, value}` |

  A field named `time` is left to the server: InfluxDB 3 rejects it and
  InfluxDB 2 drops it silently. A newline inside a *string field value* is
  fine — it is quoted, and both versions store it.
  """

  alias InfluxElixir.Write.Point

  @type encode_result :: {:ok, binary()} | {:error, term()}

  @doc """
  Encodes a Point or list of Points into InfluxDB line protocol binary.

  Returns `{:ok, binary}` on success or `{:error, reason}` on failure; see
  "Validation" in the moduledoc for the reasons.

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

      iex> point = InfluxElixir.Write.Point.new("cpu", %{"v" => 1}, tags: %{"host" => ""})
      iex> InfluxElixir.Write.LineProtocol.encode(point)
      {:error, {:invalid_tag_value, "host", ""}}
  """
  @spec encode(Point.t() | [Point.t()]) :: encode_result()
  def encode(%Point{} = point), do: encode_point(point)

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

  # A name that can stand outside quotes: a non-empty string with no
  # newline (there is no escape for one, so it would end the line).
  @spec name?(term()) :: boolean()
  defp name?(value) when is_binary(value) and value != "",
    do: not String.contains?(value, "\n")

  defp name?(_value), do: false

  @spec encode_measurement(term()) :: {:ok, binary()} | {:error, term()}
  defp encode_measurement(""), do: {:error, :empty_measurement}

  defp encode_measurement(name) do
    if name?(name) do
      escaped =
        name
        |> String.replace("\\", "\\\\")
        |> String.replace(",", "\\,")
        |> String.replace(" ", "\\ ")

      {:ok, escaped}
    else
      {:error, {:invalid_measurement, name}}
    end
  end

  @spec encode_tags(%{String.t() => String.t()}) :: {:ok, binary()} | {:error, term()}
  defp encode_tags(tags) when map_size(tags) == 0, do: {:ok, ""}

  defp encode_tags(tags) do
    tags
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      case encode_tag(k, v) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, pairs |> Enum.reverse() |> Enum.join(",")}
      {:error, _reason} = error -> error
    end
  end

  @spec encode_tag(term(), term()) :: {:ok, binary()} | {:error, term()}
  defp encode_tag("time", _value), do: {:error, {:reserved_tag_key, "time"}}

  defp encode_tag(key, value) do
    cond do
      not name?(key) -> {:error, {:invalid_tag_key, key}}
      not name?(value) -> {:error, {:invalid_tag_value, key, value}}
      true -> {:ok, "#{escape_tag_key(key)}=#{escape_tag_value(value)}"}
    end
  end

  @spec encode_fields(%{String.t() => Point.field_value()}) ::
          {:ok, binary()} | {:error, term()}
  defp encode_fields(fields) do
    fields
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      case encode_field(k, v) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, pairs |> Enum.reverse() |> Enum.join(",")}
      {:error, _reason} = error -> error
    end
  end

  @spec encode_field(term(), term()) :: {:ok, binary()} | {:error, term()}
  defp encode_field(key, value) do
    cond do
      not name?(key) -> {:error, {:invalid_field_key, key}}
      not field_value?(value) -> {:error, {:invalid_field_value, key, value}}
      true -> {:ok, "#{escape_field_key(key)}=#{encode_field_value(value)}"}
    end
  end

  @spec field_value?(term()) :: boolean()
  defp field_value?(value),
    do: is_integer(value) or is_float(value) or is_binary(value) or is_boolean(value)

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

  # `:short` is the shortest representation that round-trips exactly and
  # always contains a `.` or an exponent. The previous `{:decimals, 17}`
  # rounded to 17 decimal places, so 1.0e-20 was written as 0.0.
  defp encode_field_value(value) when is_float(value) do
    :erlang.float_to_binary(value, [:short])
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
end
