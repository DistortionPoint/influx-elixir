defmodule InfluxElixir.Client.Local.LineProtocolParser do
  @moduledoc """
  Line protocol parser for `InfluxElixir.Client.Local`.

  Turns a line-protocol payload into point maps, honouring the escaping rules
  of the format (escaped spaces, commas, equals signs, backslashes and quotes)
  and the write precision. Errors have the same `%{status: 400, body: ...}`
  shape a real InfluxDB write endpoint returns.
  """

  @typedoc "A parsed point: fields and tags as string-keyed maps, timestamp in ns."
  @type point :: %{
          measurement: binary(),
          tags: %{binary() => binary()},
          fields: %{binary() => term()},
          timestamp: integer() | nil
        }

  @doc """
  Parses a line-protocol payload into points.

  Blank lines and `#` comments are skipped. `precision` is one of
  `:nanosecond | :microsecond | :millisecond | :second` and scales numeric
  timestamps to nanoseconds. A point without a timestamp keeps `nil`; the
  caller assigns the server time.
  """
  @spec parse(binary(), atom()) ::
          {:ok, [point()]} | {:error, map()}
  def parse(text, precision) do
    lines =
      text
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))

    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case parse_line(line, precision) do
        {:ok, point} -> {:cont, {:ok, [point | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, pts} -> {:ok, Enum.reverse(pts)}
      {:error, _reason} = err -> err
    end
  end

  # Parses a single line protocol line into a point map.
  #
  # Format: measurement[,tag=val...] field=val[,...] [timestamp]
  @spec parse_line(binary(), atom()) :: {:ok, point()} | {:error, map()}
  defp parse_line(line, precision) do
    case split_line_parts(line) do
      [key_part, fields_part | rest] ->
        ts_raw = List.first(rest)

        with {:ok, {measurement, tags}} <- parse_key_part(key_part),
             {:ok, fields} <- parse_fields_part(fields_part),
             {:ok, timestamp} <- parse_timestamp(ts_raw, precision) do
          {:ok,
           %{
             measurement: measurement,
             tags: tags,
             fields: fields,
             timestamp: timestamp
           }}
        end

      _parts ->
        {:error, %{status: 400, body: "invalid line protocol: #{line}"}}
    end
  end

  # The splitters below accumulate the current token in a binary. Appending
  # to a binary the process owns is optimised by the runtime (no copy), so
  # this is one pass with one allocation per token — the previous
  # one-byte-per-list-cell accumulation plus reverse/join was several
  # allocations per byte on every write.

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
  @spec parse_key_part(binary()) :: {:ok, {binary(), map()}} | {:error, map()}
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
  @spec parse_tags(binary()) :: {:ok, map()} | {:error, map()}
  defp parse_tags(tags_str) do
    pairs = split_unescaped_comma(tags_str)

    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      case split_first_unescaped_equals(pair) do
        {k, v} when k != "" and v != "" ->
          {:cont, {:ok, Map.put(acc, unescape_tag(k), unescape_tag(v))}}

        _invalid ->
          {:halt, {:error, %{status: 400, body: "invalid tag pair: #{pair}"}}}
      end
    end)
  end

  # Parses the "field=val[,...]" section.
  @spec parse_fields_part(binary()) :: {:ok, map()} | {:error, map()}
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
          {:halt, {:error, %{status: 400, body: "invalid field pair: #{pair}"}}}
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

  # Parses a field value string into its typed Elixir equivalent.
  @spec parse_field_value(binary()) :: {:ok, term()} | {:error, map()}
  defp parse_field_value(str) do
    cond do
      String.ends_with?(str, "i") ->
        case Integer.parse(String.slice(str, 0..-2//1)) do
          {n, ""} -> {:ok, n}
          _err -> {:error, %{status: 400, body: "invalid integer field: #{str}"}}
        end

      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        inner =
          str
          |> String.slice(1..-2//1)
          |> String.replace("\\\"", "\"")
          |> String.replace("\\\\", "\\")

        {:ok, inner}

      str in ["true", "True", "TRUE"] ->
        {:ok, true}

      str in ["false", "False", "FALSE"] ->
        {:ok, false}

      true ->
        case Float.parse(str) do
          {f, ""} -> {:ok, f}
          _err -> {:error, %{status: 400, body: "invalid field value: #{str}"}}
        end
    end
  end

  # Parses a raw timestamp string, normalising to nanoseconds.
  @spec parse_timestamp(binary() | nil, atom()) ::
          {:ok, integer() | nil} | {:error, map()}
  defp parse_timestamp(nil, _prec), do: {:ok, nil}
  defp parse_timestamp("", _prec), do: {:ok, nil}

  defp parse_timestamp(ts_str, precision) do
    case Integer.parse(ts_str) do
      {ts, ""} -> {:ok, to_nanoseconds(ts, precision)}
      _err -> {:error, %{status: 400, body: "invalid timestamp: #{ts_str}"}}
    end
  end

  @spec to_nanoseconds(integer(), atom()) :: integer()
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
