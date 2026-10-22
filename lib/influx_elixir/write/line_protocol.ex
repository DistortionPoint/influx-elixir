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

  The two servers read a backslash differently (verified against InfluxDB 3 Core 3.10.1
  and InfluxDB 2.7.12), so the escapes depend on the `:api_version` option.

  `api_version: :v3` (the default), InfluxDB 3 reads `\\\\` as one backslash everywhere:

  - Measurement names: spaces, commas, backslashes
  - Tag keys/values: spaces, commas, equals, backslashes
  - Field keys: spaces, commas, equals, backslashes
  - Field string values: double-quotes, backslashes

  `api_version: :v2`, InfluxDB 2 never turns `\\\\` into one backslash in a name (it is
  stored as two); a backslash is kept as it is unless it stands before a character the
  name escapes, so a name's backslashes are not escaped:

  - Measurement names: spaces, commas
  - Tag keys/values: spaces, commas, equals
  - Field keys: spaces, commas, equals, double-quotes
  - Field string values: double-quotes, backslashes (as on v3)

  Encoded for the wrong server a name with a backslash is stored with different
  text: `a\\b` as a tag value written for v3 is stored on InfluxDB 2 as `a\\\\b`.

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
  | Measurement not a string, containing a newline, or starting with `#` or a tab | `{:invalid_measurement, value}` |
  | Tag key empty, not a string, or containing a newline | `{:invalid_tag_key, key}` |
  | Tag value empty, not a string, or containing a newline | `{:invalid_tag_value, key, value}` |
  | Tag key `time` (reserved on every version) | `{:reserved_tag_key, "time"}` |
  | Field key empty, not a string, or containing a newline | `{:invalid_field_key, key}` |
  | Field value not an integer, float, string or boolean, or an integer outside 64 bits | `{:invalid_field_value, key, value}` |
  | Timestamp not a `DateTime`, integer or `nil`, or a `DateTime` that `precision: :auto` would misread (see `:precision`) | `{:invalid_timestamp, value}` |

  With `api_version: :v2` two more names are refused, because InfluxDB 2.7 cannot keep them
  (verified: a write is answered `204` and no query returns the points, or it is a parse
  error): a measurement with a backslash before a comma, a space, `=` or `"` is
  `{:invalid_measurement, name}`, and a field key with a backslash before a comma, a space or
  `=` is `{:invalid_field_key, key}`. Every other name, a tag with any backslash among them,
  is stored as written (round trips of 25 strings in 5 positions, on 2.7 and on
  `Client.Local`'s `:v2` profile).

  A measurement, tag key, tag value or field key that ends in a backslash
  is refused with the same error as the other problems with that name:
  both versions reject the line even though the backslash is escaped. A
  measurement starting with `#` is a comment line to both, which drop it
  silently inside a batch, and escaping it (`\#`) stores the backslash. Both
  strip a leading tab from the measurement, and InfluxDB 2 a leading NUL, so
  `"\tcpu"` would be stored as `cpu`: it is refused, as is a measurement
  starting with NUL when `api_version: :v2`. An
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
  "Validation" in the moduledoc for the reasons. It never raises on what it is given:
  a term that is not a `Point` (or a list of them, proper) is
  `{:error, {:invalid_point, term}}`, options that are not a keyword list or hold an
  `:api_version` or `:precision` of the wrong kind are `{:error, {:invalid_options, opts}}`.
  A point with `nil` tags has none; one with `nil` fields has `:empty_fields`.

  ## Options

    * `:api_version` - `:v3` (the default) or `:v2`: whose escaping rules to write (see
      "Escaping Rules"). `Writer` and `BatchWriter` pass the connection's.

    * `:precision` - the unit of the write the line is for (`:second`,
      `:millisecond`, `:microsecond`, `:nanosecond`, or the short spellings
      `write/3` takes: `:s`, `"ms"`, `"us"`, `"u"`, `"n"`, ...). A
      `DateTime` timestamp is written in that unit, truncated; without it
      (or for `:auto`) in nanoseconds. InfluxDB 3's `auto` reads a number
      under 5e15 as seconds, milliseconds or microseconds, so with `:auto` a
      `DateTime` within 58 days of 1970 is written in seconds when it is
      whole seconds and is `{:invalid_timestamp, datetime}` otherwise. A
      `DateTime` written in nanoseconds
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
  def encode(point_or_points, opts \\ []) do
    with {:ok, context} <- read_options(opts) do
      encode_all(point_or_points, context)
    end
  end

  @spec encode_all(term(), map()) :: encode_result()
  defp encode_all(%Point{} = point, context) do
    with {:ok, line} <- encode_point(point, context), do: {:ok, IO.iodata_to_binary(line)}
  end

  defp encode_all(points, context) when is_list(points) do
    with {:ok, lines} <- encode_list(points, context, []) do
      {:ok, lines |> Enum.reverse() |> Enum.intersperse(?\n) |> IO.iodata_to_binary()}
    end
  end

  defp encode_all(other, _context), do: {:error, {:invalid_point, other}}

  # Newest line first. A list that does not end in `[]` names its tail as the invalid point.
  @spec encode_list(term(), map(), [iodata()]) :: {:ok, [iodata()]} | {:error, term()}
  defp encode_list([], _context, acc), do: {:ok, acc}

  defp encode_list([%Point{} = point | rest], context, acc) do
    with {:ok, line} <- encode_point(point, context),
         do: encode_list(rest, context, [line | acc])
  end

  defp encode_list([other | _rest], _context, _acc), do: {:error, {:invalid_point, other}}
  defp encode_list(improper_tail, _context, _acc), do: {:error, {:invalid_point, improper_tail}}

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

  # The kind of escaping each name gets, by dialect (see `@escapes`).
  #
  # InfluxDB 2 cannot keep some names whose backslash stands before a character it escapes
  # (verified on 2.7.12): a measurement with `\\,`, `\\ `, `\\=` or `\\"` is stored but no
  # query returns its points, and a field key with `\\,`, `\\ ` or `\\=` is a parse error. They
  # are listed in `:refuses`, per name, and refused rather than written.
  #
  # `:measurement_starts` lists what a measurement may not start with (verified on Core 3.10.1
  # and 2.7): `#` makes the line a comment, both engines strip a leading tab and store the
  # rest, and InfluxDB 2 strips a leading NUL too (Core refuses that line itself).
  @kinds %{
    v3: %{
      measurement: :measurement,
      tag: :name,
      field_key: :name,
      measurement_refuses: [],
      measurement_starts: ["#", "\t"],
      field_key_refuses: []
    },
    v2: %{
      measurement: :measurement_v2,
      tag: :tag_v2,
      field_key: :field_key_v2,
      measurement_refuses: ["\\,", "\\ ", "\\=", "\\\""],
      measurement_starts: ["#", "\t", <<0>>],
      field_key_refuses: ["\\,", "\\ ", "\\="]
    }
  }

  # What an encode needs from its options, or the options as the error: a list that is not a
  # keyword list, an `:api_version` that is not `:v3` or `:v2`, a `:precision` that is not an
  # atom or a string.
  @spec read_options(term()) :: {:ok, map()} | {:error, {:invalid_options, term()}}
  defp read_options(opts) do
    api_version =
      if Keyword.keyword?(opts) do
        case Keyword.get(opts, :api_version) do
          nil -> :v3
          version -> version
        end
      end

    precision = if Keyword.keyword?(opts), do: Keyword.get(opts, :precision)

    if api_version in [:v3, :v2] and
         ((is_atom(precision) and not is_boolean(precision)) or is_binary(precision)),
       do: {:ok, %{divisor: timestamp_divisor(precision), kinds: @kinds[api_version]}},
       else: {:error, {:invalid_options, opts}}
  end

  # Nanoseconds per unit of the write's precision; a `DateTime` is divided
  # by it. `:auto` is the engine's guess of the unit from the size of the number.
  # An unknown spelling is left to the server to refuse, with the timestamp in
  # nanoseconds.
  @spec timestamp_divisor(atom() | binary()) :: pos_integer() | :auto
  defp timestamp_divisor(precision) do
    case to_string(precision) do
      unit when unit in ~w(second s) -> 1_000_000_000
      unit when unit in ~w(millisecond ms) -> 1_000_000
      unit when unit in ~w(microsecond us u) -> 1_000
      "auto" -> :auto
      _nanosecond_or_unknown -> 1
    end
  end

  # A point whose fields or tags are not maps (`nil` tags are none) is not a point.
  @spec encode_point(Point.t(), map()) :: {:ok, iodata()} | {:error, term()}
  defp encode_point(%Point{tags: nil} = point, context),
    do: encode_point(%Point{point | tags: %{}}, context)

  defp encode_point(%Point{fields: nil}, _context), do: {:error, :empty_fields}

  defp encode_point(
         %Point{measurement: measurement, tags: tags, fields: fields, timestamp: ts},
         %{divisor: divisor, kinds: kinds}
       )
       when is_map(tags) and not is_struct(tags) and is_map(fields) and not is_struct(fields) do
    with :ok <- validate_fields(fields),
         {:ok, measurement_str} <- encode_measurement(measurement, kinds),
         {:ok, tags_str} <- encode_tags(tags, kinds),
         {:ok, fields_str} <- encode_fields(fields, kinds),
         {:ok, timestamp_str} <- encode_timestamp(ts, divisor) do
      # iodata: the caller makes one binary of the line (or the batch).
      {:ok, [measurement_str, tags_str, ?\s, fields_str | timestamp_str]}
    end
  end

  defp encode_point(%Point{} = point, _context), do: {:error, {:invalid_point, point}}

  @spec validate_fields(%{String.t() => Point.field_value()}) :: :ok | {:error, term()}
  defp validate_fields(fields) when map_size(fields) == 0,
    do: {:error, :empty_fields}

  defp validate_fields(_fields), do: :ok

  # A name that can stand outside quotes: a non-empty string with no
  # newline (there is no escape for one, so it would end the line) that
  # does not end in a backslash (both versions refuse it, escaped or not).
  @spec name?(term(), [binary()]) :: boolean()
  defp name?(value, refuses \\ [])

  defp name?(value, refuses) when is_binary(value) and value != "",
    do:
      not String.contains?(value, "\n") and not String.ends_with?(value, "\\") and
        (refuses == [] or :binary.match(value, refuses) == :nomatch)

  defp name?(_value, _refuses), do: false

  @spec encode_measurement(term(), map()) :: {:ok, binary()} | {:error, term()}
  defp encode_measurement("", _kinds), do: {:error, :empty_measurement}

  defp encode_measurement(name, kinds) do
    if name?(name, kinds.measurement_refuses) and
         not String.starts_with?(name, kinds.measurement_starts) do
      {:ok, escape(name, kinds.measurement)}
    else
      {:error, {:invalid_measurement, name}}
    end
  end

  # `,k=v` for each tag, sorted by key, or `[]` without tags.
  @spec encode_tags(%{String.t() => String.t()}, map()) :: {:ok, iodata()} | {:error, term()}
  defp encode_tags(tags, _kinds) when map_size(tags) == 0, do: {:ok, []}

  defp encode_tags(tags, kinds) do
    tags
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      case encode_tag(k, v, kinds) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _reason} = error -> error
    end
  end

  @spec encode_tag(term(), term(), map()) :: {:ok, iodata()} | {:error, term()}
  defp encode_tag("time", _value, _kinds), do: {:error, {:reserved_tag_key, "time"}}

  defp encode_tag(key, value, kinds) do
    cond do
      not name?(key) -> {:error, {:invalid_tag_key, key}}
      not name?(value) -> {:error, {:invalid_tag_value, key, value}}
      true -> {:ok, [?,, escape(key, kinds.tag), ?=, escape(value, kinds.tag)]}
    end
  end

  @spec encode_fields(%{String.t() => Point.field_value()}, map()) ::
          {:ok, iodata()} | {:error, term()}
  defp encode_fields(fields, kinds) do
    fields
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      case encode_field(k, v, kinds) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, pairs |> Enum.reverse() |> Enum.intersperse(?,)}
      {:error, _reason} = error -> error
    end
  end

  @spec encode_field(term(), term(), map()) :: {:ok, iodata()} | {:error, term()}
  defp encode_field(key, value, kinds) do
    cond do
      not name?(key, kinds.field_key_refuses) -> {:error, {:invalid_field_key, key}}
      not field_value?(value) -> {:error, {:invalid_field_value, key, value}}
      true -> {:ok, [escape(key, kinds.field_key), ?=, encode_field_value(value)]}
    end
  end

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @spec field_value?(term()) :: boolean()
  defp field_value?(value) when is_integer(value), do: value in @int64_min..@int64_max
  defp field_value?(value), do: is_float(value) or is_binary(value) or is_boolean(value)

  # ` <timestamp>`, or `[]` without one.
  @spec encode_timestamp(DateTime.t() | integer() | nil, pos_integer() | :auto) ::
          {:ok, iodata()} | {:error, term()}
  defp encode_timestamp(nil, _divisor), do: {:ok, []}

  # InfluxDB 3's `auto` reads a number under 5e15 in size as seconds, milliseconds or
  # microseconds (verified: `1000000000` is 2001-09-09). Nanoseconds that small are a time
  # within 58 days of 1970; one of whole seconds is written in seconds, which `auto` reads
  # back, and any other is refused.
  defp encode_timestamp(%DateTime{} = dt, :auto) do
    case DateTime.to_unix(dt, :nanosecond) do
      ns when abs(ns) >= 5_000_000_000_000_000 ->
        {:ok, [?\s, Integer.to_string(ns)]}

      ns when rem(ns, 1_000_000_000) == 0 ->
        {:ok, [?\s, Integer.to_string(div(ns, 1_000_000_000))]}

      _ambiguous ->
        {:error, {:invalid_timestamp, dt}}
    end
  end

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
  @escapes [
    name: ~c"\\,= ",
    measurement: ~c"\\, ",
    string: ~c"\\\"",
    tag_v2: ~c",= ",
    measurement_v2: ~c", ",
    field_key_v2: ~c",=\" "
  ]

  @typep escape_kind ::
           :name | :measurement | :string | :tag_v2 | :measurement_v2 | :field_key_v2

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
