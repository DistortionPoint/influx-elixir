defmodule InfluxElixir.Client.Local.LineProtocolParser do
  @moduledoc """
  Line protocol parser for `InfluxElixir.Client.Local`.

  Turns a line-protocol payload into point maps, honouring the escaping rules
  of the format (escaped spaces, commas, equals signs, backslashes and quotes)
  and the write precision. Each line is parsed on its own so a caller can
  store the good lines and report the bad ones, which is what InfluxDB 3
  does ("partial write of line protocol occurred").

  Per-line rules verified against InfluxDB 3 Core: an integer must fit in
  64 bits (`u` marks an unsigned one), `time` is a reserved column, and a
  key cannot be both a tag and a field on one line.
  """

  @typedoc "A parsed point: fields and tags as string-keyed maps, timestamp in ns."
  @type point :: %{
          measurement: binary(),
          tags: %{binary() => binary()},
          fields: %{binary() => term()},
          timestamp: integer() | nil
        }

  @typedoc """
  One rejected line, in the shape InfluxDB 3's partial-write response lists
  (the original line is truncated to 20 characters, as the engine does).
  """
  @type line_error :: %{
          error_message: binary(),
          line_number: pos_integer(),
          original_line: binary(),
          line: binary()
        }

  @typedoc "A line's outcome: the point with its line number and text, or the error."
  @type line_result :: {:ok, point(), pos_integer(), binary()} | {:error, line_error()}

  @typedoc """
  Whose rules apply. InfluxDB 3 refuses a key that is
  both tag and field (and, in the store, `time` as a column); InfluxDB 2
  drops a `time` field silently and lets a
  tag and a field share a name.
  """
  @type dialect :: :v3 | :v2

  @typedoc "The unit numeric timestamps are in; `:auto` guesses it from the magnitude."
  @type precision :: :nanosecond | :microsecond | :millisecond | :second | :auto

  @int64_max 9_223_372_036_854_775_807
  @int64_min -9_223_372_036_854_775_808
  @uint64_max 18_446_744_073_709_551_615

  @doc """
  Parses a line-protocol payload line by line.

  Blank lines and `#` comments are skipped. `precision` is a `t:precision/0`:
  a unit scales numeric timestamps to nanoseconds and `:auto` guesses the unit
  from the magnitude as InfluxDB 3 does. A point without a timestamp keeps `nil`; the
  caller assigns the server time. A newline inside a quoted string field
  value is part of the value, as the engine reads it.

  Returns `{:error, ...}` only for a payload with no lines at all ("incoming
  write was empty" on the engine); every other problem is a per-line
  `{:error, line_error}` in the list, numbered as the engine numbers it.
  """
  @spec parse_lines(binary(), precision(), dialect()) ::
          {:ok, [line_result()]} | {:error, map()}
  def parse_lines(text, precision, dialect \\ :v3) do
    results =
      text
      |> split_lines()
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _n} ->
        String.trim(line) == "" or String.starts_with?(line, "#")
      end)
      |> Enum.map(fn {line, n} -> parse_line(line, n, precision, dialect) end)

    case results do
      [] -> {:error, %{status: 400, body: "incoming write was empty"}}
      results -> {:ok, results}
    end
  end

  # Splits the payload at newlines that are not inside a quoted string
  # field value.
  @spec split_lines(binary()) :: [binary()]
  defp split_lines(text), do: do_split_lines(text, <<>>, [], false)

  defp do_split_lines(<<>>, current, acc, _in_quotes), do: Enum.reverse([current | acc])

  defp do_split_lines(<<"\\\\", rest::binary>>, current, acc, in_quotes),
    do: do_split_lines(rest, <<current::binary, "\\\\">>, acc, in_quotes)

  defp do_split_lines(<<"\\\"", rest::binary>>, current, acc, in_quotes),
    do: do_split_lines(rest, <<current::binary, "\\\"">>, acc, in_quotes)

  defp do_split_lines(<<"\"", rest::binary>>, current, acc, in_quotes),
    do: do_split_lines(rest, <<current::binary, "\"">>, acc, !in_quotes)

  defp do_split_lines(<<"\n", rest::binary>>, current, acc, false),
    do: do_split_lines(rest, <<>>, [current | acc], false)

  defp do_split_lines(<<c, rest::binary>>, current, acc, in_quotes),
    do: do_split_lines(rest, <<current::binary, c>>, acc, in_quotes)

  # Parses a single line protocol line into a point map.
  #
  # Format: measurement[,tag=val...] field=val[,...] [timestamp]
  @spec parse_line(binary(), pos_integer(), precision(), dialect()) :: line_result()
  defp parse_line(line, number, precision, dialect) do
    result =
      case split_line_parts(line) do
        [key_part, fields_part | rest] ->
          ts_raw = List.first(rest)

          with {:ok, {measurement, tags}} <- parse_key_part(key_part),
               {:ok, fields} <- parse_fields_part(fields_part),
               {:ok, fields} <- check_columns(tags, fields, dialect),
               {:ok, timestamp} <- parse_timestamp(ts_raw, precision) do
            {:ok, %{measurement: measurement, tags: tags, fields: fields, timestamp: timestamp}}
          end

        _parts ->
          {:error, "Expected at least one space character, got end of input"}
      end

    case result do
      {:ok, point} -> {:ok, point, number, line}
      {:error, message} -> {:error, line_error(message, number, line)}
    end
  end

  @doc """
  Builds a `t:line_error/0` the way InfluxDB 3 reports one. The full line
  is kept under `:line` for InfluxDB 2's report, which quotes it whole.
  """
  @spec line_error(binary(), pos_integer(), binary()) :: line_error()
  def line_error(message, number, line) do
    %{
      error_message: message,
      line_number: number,
      original_line: String.slice(line, 0, 20),
      line: line
    }
  end

  # A key is one column, so a key used as both a tag and a field cannot be
  # typed — on InfluxDB 3. InfluxDB 2 keeps tags and fields in separate
  # namespaces and drops a `time` field. `time` on InfluxDB 3 is checked
  # by the store, because the engine's wording depends on whether the
  # table already exists.
  @spec check_columns(map(), map(), dialect()) :: {:ok, map()} | {:error, binary()}
  defp check_columns(tags, _fields, :v2) when is_map_key(tags, "time"),
    do: {:error, "cannot use reserved tag key \"time\""}

  defp check_columns(_tags, fields, :v2), do: {:ok, Map.delete(fields, "time")}

  defp check_columns(tags, fields, :v3) do
    case Enum.find(Map.keys(fields), &Map.has_key?(tags, &1)) do
      nil ->
        {:ok, fields}

      key ->
        {:error,
         "invalid column type for column '#{key}', expected iox::column_type::tag, got " <>
           column_type(:field, Map.fetch!(fields, key))}
    end
  end

  @doc """
  The engine's name for a column kind: `iox::column_type::tag` or
  `iox::column_type::field::<integer | uinteger | float | string | boolean>`.
  """
  @spec column_type(:tag | :field, term()) :: binary()
  def column_type(:tag, _value), do: "iox::column_type::tag"

  def column_type(:field, {:uint, _n}), do: "iox::column_type::field::uinteger"
  def column_type(:field, value) when is_integer(value), do: "iox::column_type::field::integer"
  def column_type(:field, value) when is_float(value), do: "iox::column_type::field::float"
  def column_type(:field, value) when is_binary(value), do: "iox::column_type::field::string"
  def column_type(:field, value) when is_boolean(value), do: "iox::column_type::field::boolean"

  @doc "InfluxDB 2's name for a field type (`integer`, `unsigned`, `float`, `string`, `boolean`)."
  @spec v2_field_type(binary()) :: binary()
  def v2_field_type("iox::column_type::field::uinteger"), do: "unsigned"
  def v2_field_type("iox::column_type::field::" <> type), do: type

  # The splitters below accumulate the current token in a binary. Appending
  # to a binary the process owns is optimised by the runtime (no copy), so
  # this is one pass with one allocation per token.

  # Splits a line into [key_part, fields_part, optional_timestamp] by
  # unescaped spaces that are not inside double-quoted strings.
  @spec split_line_parts(binary()) :: [binary()]
  defp split_line_parts(line) do
    do_lp_split(line, <<>>, [], false)
  end

  # End of input — flush remaining token.
  defp do_lp_split(<<>>, current, acc, _in_quotes), do: Enum.reverse([current | acc])

  # Escaped backslash — keep both chars, quote state unchanged.
  defp do_lp_split(<<"\\\\", rest::binary>>, current, acc, in_quotes) do
    do_lp_split(rest, <<current::binary, "\\\\">>, acc, in_quotes)
  end

  # Escaped double-quote — keep both chars, do not toggle quote state.
  defp do_lp_split(<<"\\\"", rest::binary>>, current, acc, in_quotes) do
    do_lp_split(rest, <<current::binary, "\\\"">>, acc, in_quotes)
  end

  # Escaped space outside quotes — keep both chars, no split.
  defp do_lp_split(<<"\\ ", rest::binary>>, current, acc, false) do
    do_lp_split(rest, <<current::binary, "\\ ">>, acc, false)
  end

  # Unescaped double-quote — toggle in_quotes flag.
  defp do_lp_split(<<"\"", rest::binary>>, current, acc, in_quotes) do
    do_lp_split(rest, <<current::binary, "\"">>, acc, !in_quotes)
  end

  # Unescaped space outside a quoted string — emit token.
  defp do_lp_split(<<" ", rest::binary>>, current, acc, false) do
    do_lp_split(rest, <<>>, [current | acc], false)
  end

  # All other bytes — accumulate.
  defp do_lp_split(<<c, rest::binary>>, current, acc, in_quotes) do
    do_lp_split(rest, <<current::binary, c>>, acc, in_quotes)
  end

  # Parses the "measurement[,tag=val...]" part.
  @spec parse_key_part(binary()) :: {:ok, {binary(), map()}} | {:error, binary()}
  defp parse_key_part(key_part) do
    case split_first_unescaped_comma(key_part) do
      {measurement_raw, ""} ->
        {:ok, {unescape_measurement(measurement_raw), %{}}}

      {measurement_raw, tags_raw} ->
        with {:ok, tags} <- parse_tags(tags_raw) do
          {:ok, {unescape_measurement(measurement_raw), tags}}
        end
    end
  end

  # Splits at the first unescaped comma.
  @spec split_first_unescaped_comma(binary()) :: {binary(), binary()}
  defp split_first_unescaped_comma(str) do
    do_split_comma(str, <<>>)
  end

  defp do_split_comma(<<>>, acc), do: {acc, ""}

  defp do_split_comma(<<"\\,", rest::binary>>, acc) do
    do_split_comma(rest, <<acc::binary, "\\,">>)
  end

  defp do_split_comma(<<",", rest::binary>>, acc), do: {acc, rest}

  defp do_split_comma(<<c, rest::binary>>, acc) do
    do_split_comma(rest, <<acc::binary, c>>)
  end

  # Parses "tag1=v1,tag2=v2,..." into a map.
  @spec parse_tags(binary()) :: {:ok, map()} | {:error, binary()}
  defp parse_tags(tags_str) do
    pairs = split_unescaped_comma(tags_str)

    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      case split_first_unescaped_equals(pair) do
        {"", _v} -> {:halt, {:error, "Expected tag key, got `#{pair}`"}}
        {_k, ""} -> {:halt, {:error, "Expected tag value, got `#{pair}`"}}
        {k, v} -> {:cont, {:ok, Map.put(acc, unescape_tag(k), unescape_tag(v))}}
      end
    end)
  end

  # Parses the "field=val[,...]" section.
  @spec parse_fields_part(binary()) :: {:ok, map()} | {:error, binary()}
  defp parse_fields_part(fields_str) do
    pairs = split_unescaped_comma(fields_str)

    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      case split_first_unescaped_equals(pair) do
        {k, v} when k != "" and v != "" ->
          case parse_field_value(v) do
            {:ok, typed} -> {:cont, {:ok, Map.put(acc, unescape_tag(k), typed)}}
            {:error, _reason} = err -> {:halt, err}
          end

        _invalid ->
          {:halt, {:error, "No fields were provided"}}
      end
    end)
  end

  # Splits a CSV-like string on unescaped commas, respecting quoted strings.
  @spec split_unescaped_comma(binary()) :: [binary()]
  defp split_unescaped_comma(str) do
    do_csv_split(str, <<>>, [], false)
  end

  defp do_csv_split(<<>>, current, acc, _in_quotes), do: Enum.reverse([current | acc])

  defp do_csv_split(<<"\\\"", rest::binary>>, current, acc, in_quotes) do
    do_csv_split(rest, <<current::binary, "\\\"">>, acc, in_quotes)
  end

  defp do_csv_split(<<"\"", rest::binary>>, current, acc, in_quotes) do
    do_csv_split(rest, <<current::binary, "\"">>, acc, !in_quotes)
  end

  defp do_csv_split(<<"\\,", rest::binary>>, current, acc, in_quotes) do
    do_csv_split(rest, <<current::binary, "\\,">>, acc, in_quotes)
  end

  defp do_csv_split(<<",", rest::binary>>, current, acc, false) do
    do_csv_split(rest, <<>>, [current | acc], false)
  end

  defp do_csv_split(<<c, rest::binary>>, current, acc, in_quotes) do
    do_csv_split(rest, <<current::binary, c>>, acc, in_quotes)
  end

  # Splits at the first unescaped = sign.
  @spec split_first_unescaped_equals(binary()) :: {binary(), binary()}
  defp split_first_unescaped_equals(str) do
    do_split_eq(str, <<>>)
  end

  defp do_split_eq(<<>>, acc), do: {acc, ""}

  defp do_split_eq(<<"\\=", rest::binary>>, acc) do
    do_split_eq(rest, <<acc::binary, "\\=">>)
  end

  defp do_split_eq(<<"=", rest::binary>>, acc), do: {acc, rest}

  defp do_split_eq(<<c, rest::binary>>, acc) do
    do_split_eq(rest, <<acc::binary, c>>)
  end

  # Parses a field value string into its typed Elixir equivalent. An
  # unsigned integer (`7u`) is stored as the integer; its kind is remembered
  # for the schema check only.
  @spec parse_field_value(binary()) :: {:ok, term()} | {:error, binary()}
  defp parse_field_value(str) do
    cond do
      String.ends_with?(str, "i") ->
        parse_integer(String.slice(str, 0..-2//1), @int64_min, @int64_max)

      String.ends_with?(str, "u") ->
        with {:ok, n} <- parse_integer(String.slice(str, 0..-2//1), 0, @uint64_max),
             do: {:ok, {:uint, n}}

      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        inner =
          str
          |> String.slice(1..-2//1)
          |> String.replace("\\\"", "\"")
          |> String.replace("\\\\", "\\")

        {:ok, inner}

      str in ["true", "True", "TRUE", "t", "T"] ->
        {:ok, true}

      str in ["false", "False", "FALSE", "f", "F"] ->
        {:ok, false}

      true ->
        case Float.parse(str) do
          {f, ""} -> {:ok, f}
          _err -> {:error, "Unable to parse field value `#{str}`"}
        end
    end
  end

  @spec parse_integer(binary(), integer(), integer()) :: {:ok, integer()} | {:error, binary()}
  defp parse_integer(digits, min, max) do
    case Integer.parse(digits) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      _out_of_range -> {:error, "Unable to parse integer value `#{digits}`"}
    end
  end

  # Parses a raw timestamp string, normalising to nanoseconds.
  @spec parse_timestamp(binary() | nil, precision()) ::
          {:ok, integer() | nil} | {:error, binary()}
  defp parse_timestamp(nil, _prec), do: {:ok, nil}
  defp parse_timestamp("", _prec), do: {:ok, nil}

  defp parse_timestamp(ts_str, precision) do
    case Integer.parse(ts_str) do
      {ts, ""} -> {:ok, to_nanoseconds(ts, precision)}
      _err -> {:error, "Unable to parse timestamp value `#{ts_str}`"}
    end
  end

  # `:auto` is InfluxDB 3's guess from the magnitude, verified against the
  # engine: |ts| below 5e9 is seconds, below 5e12 milliseconds, below 5e15
  # microseconds, otherwise nanoseconds.
  @spec to_nanoseconds(integer(), precision()) :: integer()
  defp to_nanoseconds(ts, :auto) when abs(ts) < 5_000_000_000, do: to_nanoseconds(ts, :second)

  defp to_nanoseconds(ts, :auto) when abs(ts) < 5_000_000_000_000,
    do: to_nanoseconds(ts, :millisecond)

  defp to_nanoseconds(ts, :auto) when abs(ts) < 5_000_000_000_000_000,
    do: to_nanoseconds(ts, :microsecond)

  defp to_nanoseconds(ts, :auto), do: ts
  defp to_nanoseconds(ts, :nanosecond), do: ts
  defp to_nanoseconds(ts, :microsecond), do: ts * 1_000
  defp to_nanoseconds(ts, :millisecond), do: ts * 1_000_000
  defp to_nanoseconds(ts, :second), do: ts * 1_000_000_000

  # Unescape a measurement name (backslash, comma, space).
  @doc "Undoes line-protocol escaping in a measurement name (`\\ `, `\\,`, `\\\\`)."
  @spec unescape_measurement(binary()) :: binary()
  def unescape_measurement(str) do
    str
    |> String.trim("\"")
    |> String.replace("\\ ", " ")
    |> String.replace("\\,", ",")
    |> String.replace("\\\\", "\\")
  end

  # Unescape a tag key or value (backslash, comma, equals, space).
  @spec unescape_tag(binary()) :: binary()
  defp unescape_tag(str) do
    str
    |> String.replace("\\ ", " ")
    |> String.replace("\\,", ",")
    |> String.replace("\\=", "=")
    |> String.replace("\\\\", "\\")
  end
end
