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
  | Measurement not a string, containing a newline, or starting with `#` | `{:invalid_measurement, value}` |
  | Tag key empty, not a string, or containing a newline | `{:invalid_tag_key, key}` |
  | Tag value empty, not a string, or containing a newline | `{:invalid_tag_value, key, value}` |
  | Tag key `time` (reserved on every version) | `{:reserved_tag_key, "time"}` |
  | Field key empty, not a string, or containing a newline | `{:invalid_field_key, key}` |
  | Field value not an integer, float, string or boolean, or an integer outside 64 bits | `{:invalid_field_value, key, value}` |
  | Timestamp not a `DateTime`, integer or `nil` | `{:invalid_timestamp, value}` |

  A measurement, tag key, tag value or field key that ends in a backslash
  is refused with the same error as the other problems with that name:
  both versions reject the line even though the backslash is escaped. A
  measurement starting with `#` is a comment line to both, which drop it
  silently inside a batch, and escaping it (`\#`) stores the backslash. An
  integer field must fit in a signed 64-bit integer; there is no unsigned
  field type on a `Point`.

  A field named `time` is left to the server: InfluxDB 3 rejects it and
  InfluxDB 2 drops it silently. So is a tab in a name: InfluxDB 3 refuses
  the line and InfluxDB 2 stores the tab. A newline inside a *string field
  value* is fine — it is quoted, and both versions store it.
  """

  alias InfluxElixir.Write.Point

  @type encode_result :: {:ok, binary()} | {:error, term()}

  @doc """
  Encodes a Point or list of Points into InfluxDB line protocol binary.

  Returns `{:ok, binary}` on success or `{:error, reason}` on failure; see
  "Validation" in the moduledoc for the reasons.

  ## Options

    * `:precision` - the unit of the write the line is for (`:second`,
      `:millisecond`, `:microsecond`, `:nanosecond`, or the short spellings
      `write/3` takes: `:s`, `"ms"`, `"us"`, `"u"`, `"n"`, ...). A
      `DateTime` timestamp is written in that unit, truncated; without it
      (or for `:auto`) in nanoseconds. A `DateTime` written in nanoseconds
      to a write with `precision: :second` is out of range on the server
      (verified), so pass the write's precision here. An integer timestamp
      is written as given: it is already in the caller's unit.

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
  @spec encode(Point.t() | [Point.t()], keyword()) :: encode_result()
  def encode(point_or_points, opts \\ [])

  def encode(%Point{} = point, opts) do
    with {:ok, line} <- encode_point(point, timestamp_divisor(opts)) do
      {:ok, IO.iodata_to_binary(line)}
    end
  end

  def encode(points, opts) when is_list(points) do
    divisor = timestamp_divisor(opts)

    points
    |> Enum.reduce_while({:ok, []}, fn point, {:ok, acc} ->
      case encode_point(point, divisor) do
        {:ok, line} -> {:cont, {:ok, [line | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, lines} ->
        {:ok, lines |> Enum.reverse() |> Enum.intersperse(?\n) |> IO.iodata_to_binary()}

      {:error, reason} ->
        {:error, reason}
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
  @spec encode!(Point.t() | [Point.t()], keyword()) :: binary()
  def encode!(point_or_points, opts \\ []) do
    case encode(point_or_points, opts) do
      {:ok, line} -> line
      {:error, reason} -> raise ArgumentError, "LineProtocol encode failed: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Nanoseconds per unit of the write's precision; a `DateTime` is divided
  # by it. An unknown spelling is left to the server to refuse, with the
  # timestamp in nanoseconds.
  @spec timestamp_divisor(keyword()) :: pos_integer()
  defp timestamp_divisor(opts) do
    case opts |> Keyword.get(:precision) |> to_string() do
      unit when unit in ~w(second s) -> 1_000_000_000
      unit when unit in ~w(millisecond ms) -> 1_000_000
      unit when unit in ~w(microsecond us u) -> 1_000
      _nanosecond_auto_or_unknown -> 1
    end
  end

  @spec encode_point(Point.t(), pos_integer()) :: {:ok, iodata()} | {:error, term()}
  defp encode_point(
         %Point{measurement: measurement, tags: tags, fields: fields, timestamp: ts},
         divisor
       ) do
    with :ok <- validate_fields(fields),
         {:ok, measurement_str} <- encode_measurement(measurement),
         {:ok, tags_str} <- encode_tags(tags),
         {:ok, fields_str} <- encode_fields(fields),
         {:ok, timestamp_str} <- encode_timestamp(ts, divisor) do
      # iodata: the caller makes one binary of the line (or the batch).
      {:ok, [measurement_str, tags_str, ?\s, fields_str | timestamp_str]}
    end
  end

  @spec validate_fields(%{String.t() => Point.field_value()}) :: :ok | {:error, term()}
  defp validate_fields(fields) when map_size(fields) == 0,
    do: {:error, :empty_fields}

  defp validate_fields(_fields), do: :ok

  # A name that can stand outside quotes: a non-empty string with no
  # newline (there is no escape for one, so it would end the line) that
  # does not end in a backslash (both versions refuse it, escaped or not).
  @spec name?(term()) :: boolean()
  defp name?(value) when is_binary(value) and value != "",
    do: not String.contains?(value, "\n") and not String.ends_with?(value, "\\")

  defp name?(_value), do: false

  @spec encode_measurement(term()) :: {:ok, binary()} | {:error, term()}
  defp encode_measurement(""), do: {:error, :empty_measurement}

  defp encode_measurement(name) do
    if name?(name) and not String.starts_with?(name, "#") do
      {:ok, escape(name, :measurement)}
    else
      {:error, {:invalid_measurement, name}}
    end
  end

  # `,k=v` for each tag, sorted by key, or `[]` without tags.
  @spec encode_tags(%{String.t() => String.t()}) :: {:ok, iodata()} | {:error, term()}
  defp encode_tags(tags) when map_size(tags) == 0, do: {:ok, []}

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
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _reason} = error -> error
    end
  end

  @spec encode_tag(term(), term()) :: {:ok, iodata()} | {:error, term()}
  defp encode_tag("time", _value), do: {:error, {:reserved_tag_key, "time"}}

  defp encode_tag(key, value) do
    cond do
      not name?(key) -> {:error, {:invalid_tag_key, key}}
      not name?(value) -> {:error, {:invalid_tag_value, key, value}}
      true -> {:ok, [?,, escape(key, :name), ?=, escape(value, :name)]}
    end
  end

  @spec encode_fields(%{String.t() => Point.field_value()}) ::
          {:ok, iodata()} | {:error, term()}
  defp encode_fields(fields) do
    fields
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      case encode_field(k, v) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, pairs |> Enum.reverse() |> Enum.intersperse(?,)}
      {:error, _reason} = error -> error
    end
  end

  @spec encode_field(term(), term()) :: {:ok, iodata()} | {:error, term()}
  defp encode_field(key, value) do
    cond do
      not name?(key) -> {:error, {:invalid_field_key, key}}
      not field_value?(value) -> {:error, {:invalid_field_value, key, value}}
      true -> {:ok, [escape(key, :name), ?=, encode_field_value(value)]}
    end
  end

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @spec field_value?(term()) :: boolean()
  defp field_value?(value) when is_integer(value), do: value in @int64_min..@int64_max
  defp field_value?(value), do: is_float(value) or is_binary(value) or is_boolean(value)

  # ` <timestamp>`, or `[]` without one.
  @spec encode_timestamp(DateTime.t() | integer() | nil, pos_integer()) ::
          {:ok, iodata()} | {:error, term()}
  defp encode_timestamp(nil, _divisor), do: {:ok, []}

  # Truncated toward the past, so a timestamp never moves forward.
  defp encode_timestamp(%DateTime{} = dt, divisor),
    do:
      {:ok,
       [
         ?\s,
         dt
         |> DateTime.to_unix(:nanosecond)
         |> Integer.floor_div(divisor)
         |> Integer.to_string()
       ]}

  defp encode_timestamp(ts, _divisor) when is_integer(ts),
    do: {:ok, [?\s, Integer.to_string(ts)]}

  defp encode_timestamp(ts, _divisor), do: {:error, {:invalid_timestamp, ts}}

  # The bytes each kind of text backslash-escapes: tag keys, tag values and
  # field keys (`:name`), measurements, and string field values. All ASCII,
  # so no byte of a multi-byte UTF-8 character can match.
  @escapes [name: ~c"\\,= ", measurement: ~c"\\, ", string: ~c"\\\""]

  @typep escape_kind :: :name | :measurement | :string

  # Most text needs no escape: one byte scan returns it as it is.
  @spec escape(binary(), escape_kind()) :: binary()
  defp escape(str, kind) do
    if clean?(str, kind),
      do: str,
      else: for(<<byte <- str>>, into: "", do: escape_byte(byte, kind))
  end

  @spec clean?(binary(), escape_kind()) :: boolean()
  @spec escape_byte(byte(), escape_kind()) :: binary()
  for {kind, bytes} <- @escapes do
    defp clean?(<<byte, _rest::binary>>, unquote(kind)) when byte in unquote(bytes), do: false
    defp escape_byte(byte, unquote(kind)) when byte in unquote(bytes), do: <<?\\, byte>>
  end

  defp clean?(<<_byte, rest::binary>>, kind), do: clean?(rest, kind)
  defp clean?(<<>>, _kind), do: true

  defp escape_byte(byte, _kind), do: <<byte>>

  # Field value encoding by type
  @spec encode_field_value(Point.field_value()) :: iodata()
  defp encode_field_value(value) when is_integer(value) do
    [Integer.to_string(value), ?i]
  end

  # `:short` is the shortest representation that round-trips exactly and
  # always contains a `.` or an exponent. The previous `{:decimals, 17}`
  # rounded to 17 decimal places, so 1.0e-20 was written as 0.0.
  defp encode_field_value(value) when is_float(value) do
    :erlang.float_to_binary(value, [:short])
  end

  defp encode_field_value(value) when is_binary(value) do
    [?", escape(value, :string), ?"]
  end

  defp encode_field_value(true), do: "true"
  defp encode_field_value(false), do: "false"
end
