defmodule InfluxElixir.Client.Local.LineProtocolV3 do
  @moduledoc false
  # The InfluxDB 3 line grammar: `series SP+ fields [SP+ timestamp] SP*`, with
  # the engine's errors for what does not parse.

  alias InfluxElixir.Client.Local.{
    LineProtocolEscape,
    LineProtocolNumber,
    LineProtocolParser,
    LineProtocolTime
  }

  @typep precision :: LineProtocolParser.precision()
  @typep point :: LineProtocolParser.point()

  # ---------------------------------------------------------------------------
  # InfluxDB 3 grammar
  #
  # `series SP+ fields [SP+ timestamp] SP*`, and what is left over is the
  # error "Could not parse entire line. Found trailing content". Every
  # rule below was probed against Core:
  #
  #   * names (measurement, tag keys and values, field keys) end at an
  #     unescaped separator and know no quotes: a `"` is an ordinary byte
  #     there and a quoted measurement keeps its quotes; a tag or field key
  #     may hold commas (`a,b=1` is the key `a,b`)
  #   * a field that does not parse ends the field list: the first one is
  #     "No fields were provided", a later one leaves the rest of the line
  #     as trailing content, starting after its comma when it is the second
  #     field and at the comma from the third on
  #   * a number is `-?digits[.digits][e[+-]digits]`, `i` and `u` suffixes
  #     make integers; whatever follows the longest match is trailing
  #     content (`5.` leaves `.`, `1e` leaves `e`, `tRUE` is `t` and `RUE`);
  #     `.5`, `+5`, `NaN` and `inf` are not values
  #   * a timestamp is `-?digits`
  #   * a tag key given twice is accepted, and then every query of the
  #     table answers 500 "record batch lengths"; the double refuses the
  #     line by name instead
  #   * a float too large for 64 bits (`1e999`) is stored as infinity,
  #     which the double cannot hold, so it refuses the line by name
  # ---------------------------------------------------------------------------

  @need_space "Expected at least one space character, got end of input"
  @trailing_backslash "Measurements, tag keys and values, and field keys may not end with a backslash"
  @no_fields "No fields were provided"

  @spec parse(binary(), precision()) :: {:ok, point()} | {:error, binary()}
  def parse(line, precision) do
    with {:ok, measurement, tags_raw, after_series} <- v3_series(line),
         {:ok, fields_raw, rest} <- v3_fields(skip_spaces(after_series)),
         {:ok, timestamp_text} <- v3_timestamp(rest),
         {:ok, timestamp} <- LineProtocolTime.parse_timestamp(timestamp_text, precision, :v3),
         tags = v3_tag_map(line, measurement, tags_raw, after_series),
         {:ok, fields} <- v3_check_fields(tags, fields_raw),
         :ok <- v3_distinct_tags(tags, tags_raw) do
      {:ok,
       %{
         measurement: LineProtocolEscape.unescape_measurement(measurement),
         tags: tags,
         fields: fields,
         timestamp: timestamp
       }}
    end
  end

  # The measurement and the tag set. `after_series` starts at the space
  # that ends them.
  @spec v3_series(binary()) ::
          {:ok, binary(), [{binary(), binary()}], binary()} | {:error, binary()}
  @doc false
  def v3_series(line) do
    case name_end(line) do
      :none ->
        if LineProtocolEscape.ends_in_backslash?(line),
          do: {:error, @trailing_backslash},
          else: {:error, @need_space}

      0 ->
        {:error, "Invalid measurement was provided"}

      pos ->
        <<measurement::binary-size(pos), separator, rest::binary>> = line

        cond do
          LineProtocolEscape.ends_in_backslash?(measurement) ->
            {:error, @trailing_backslash}

          separator == ?, ->
            with {:ok, tags, after_series} <- v3_tags(rest, rest, []),
                 do: {:ok, measurement, tags, after_series}

          separator == ?\t ->
            {:error, need_space(binary_part(line, pos, byte_size(line) - pos))}

          true ->
            {:ok, measurement, [], binary_part(line, pos, byte_size(line) - pos)}
        end
    end
  end

  # `key=value` pairs separated by commas, up to the space. `whole` is the
  # tag set from its first byte, which a malformed one quotes.
  @spec v3_tags(binary(), binary(), [{binary(), binary()}]) ::
          {:ok, [{binary(), binary()}], binary()} | {:error, binary()}
  defp v3_tags("", _whole, _acc), do: {:error, "Expected tag key, got end of input"}

  defp v3_tags(tags, whole, acc) do
    case key_end(tags) do
      :none ->
        {:error, name_error(tags, tag_set_malformed(whole))}

      0 ->
        {:error, "Expected tag key, got `#{excerpt(tags)}`"}

      pos ->
        <<key::binary-size(pos), separator, rest::binary>> = tags

        if separator == ?=,
          do: v3_tag_value(key, rest, whole, acc),
          else: {:error, name_error(key, tag_set_malformed(whole))}
    end
  end

  # What a name that did not end properly is reported as: a name that ends
  # in a backslash is refused before anything else is said about it.
  @spec name_error(binary(), binary()) :: binary()
  defp name_error(name, message),
    do: if(LineProtocolEscape.ends_in_backslash?(name), do: @trailing_backslash, else: message)

  @spec v3_tag_value(binary(), binary(), binary(), [{binary(), binary()}]) ::
          {:ok, [{binary(), binary()}], binary()} | {:error, binary()}
  defp v3_tag_value(key, _rest, _whole, _acc)
       when binary_part(key, byte_size(key) - 1, 1) == "\\",
       do: {:error, @trailing_backslash}

  defp v3_tag_value(_key, "", _whole, _acc), do: {:error, "Expected tag value, got end of input"}

  defp v3_tag_value(key, rest, whole, acc) do
    case name_end(rest) do
      :none ->
        {:error, name_error(rest, @need_space)}

      0 ->
        {:error, "Expected tag value, got `#{excerpt(rest)}`"}

      pos ->
        <<value::binary-size(pos), separator, more::binary>> = rest

        cond do
          LineProtocolEscape.ends_in_backslash?(value) ->
            {:error, @trailing_backslash}

          separator == ?, ->
            v3_tags(more, whole, [{key, value} | acc])

          separator == ?\t ->
            {:error, need_space(binary_part(rest, pos, byte_size(rest) - pos))}

          true ->
            {:ok, Enum.reverse([{key, value} | acc]),
             binary_part(rest, pos, byte_size(rest) - pos)}
        end
    end
  end

  # A tab ends a name as a space does, but only a space separates the
  # sections of a line (verified): the engine quotes everything from it.
  @spec need_space(binary()) :: binary()
  defp need_space(from_tab),
    do: "Expected at least one space character, got `#{from_tab}`"

  @spec tag_set_malformed(binary()) :: binary()
  defp tag_set_malformed(whole),
    do: "Tag set malformed: could not find equals sign in `#{excerpt(whole)}`"

  # What the engine quotes of the rest of a line in an error: ten
  # characters, and "..." when there is more. ("Expected at least one space
  # character" quotes all of it.)
  @spec excerpt(binary()) :: binary()
  defp excerpt(text) do
    if String.length(text) > 10, do: String.slice(text, 0, 10) <> "...", else: text
  end

  # The tag map. Nearly every series has no escape, and then its names are
  # what was written.
  @spec v3_tag_map(binary(), binary(), [{binary(), binary()}], binary()) :: %{
          binary() => binary()
        }
  defp v3_tag_map(_line, _measurement, [], _after_series), do: %{}

  defp v3_tag_map(line, _measurement, tags_raw, after_series) do
    series_size = byte_size(line) - byte_size(after_series)

    if :binary.match(line, "\\", scope: {0, series_size}) == :nomatch,
      do: Map.new(tags_raw),
      else:
        Map.new(tags_raw, fn {k, v} ->
          {LineProtocolEscape.unescape_tag(k), LineProtocolEscape.unescape_tag(v)}
        end)
  end

  # A tag key given twice (after unescaping) is stored by the engine and
  # then fails every query of the table; the double refuses it by name.
  @spec v3_distinct_tags(map(), [{binary(), binary()}]) :: :ok | {:error, binary()}
  defp v3_distinct_tags(tags, tags_raw) do
    if map_size(tags) == length(tags_raw) do
      :ok
    else
      duplicate =
        tags_raw
        |> Enum.map(fn {key, _value} -> LineProtocolEscape.unescape_tag(key) end)
        |> Enum.frequencies()
        |> Enum.find_value(fn {key, count} -> if count > 1, do: key end)

      {:error,
       "Client.Local: the tag key #{duplicate} is given twice; InfluxDB 3 Core stores such a " <>
         "line and then answers every query of the table with a 500"}
    end
  end

  @spec v3_fields(binary()) :: {:ok, [{binary(), term()}], binary()} | {:error, binary()}
  @doc false
  def v3_fields(""), do: {:error, @no_fields}

  def v3_fields(text) do
    case v3_field(text) do
      {:ok, field, rest} -> v3_more_fields(rest, [field], 2)
      :fail -> {:error, @no_fields}
      {:error, _message} = error -> error
    end
  end

  # The comma between fields is consumed with the next field; when that one
  # does not parse the list ends before it, with the engine's two
  # positions for what is left (see above).
  @spec v3_more_fields(binary(), [{binary(), term()}], pos_integer()) ::
          {:ok, [{binary(), term()}], binary()} | {:error, binary()}
  defp v3_more_fields(<<?,, next::binary>> = rest, acc, count) do
    case v3_field(next) do
      {:ok, field, rest} ->
        v3_more_fields(rest, [field | acc], count + 1)

      :fail ->
        {:ok, Enum.reverse(acc), if(count == 2, do: next, else: rest)}

      {:error, _message} = error ->
        error
    end
  end

  defp v3_more_fields(rest, acc, _count), do: {:ok, Enum.reverse(acc), rest}

  # A field as written: its key is still escaped.
  @spec v3_field(binary()) :: {:ok, {binary(), term()}, binary()} | :fail | {:error, binary()}
  defp v3_field(text) do
    case key_end(text) do
      :none ->
        if LineProtocolEscape.ends_in_backslash?(text),
          do: {:error, @trailing_backslash},
          else: :fail

      pos when pos > 0 ->
        <<key::binary-size(pos), separator, rest::binary>> = text

        cond do
          LineProtocolEscape.ends_in_backslash?(key) ->
            {:error, @trailing_backslash}

          separator != ?= ->
            :fail

          true ->
            with {:ok, value, rest} <- v3_value(rest), do: {:ok, {key, value}, rest}
        end

      _no_key ->
        :fail
    end
  end

  # One field value and what follows it. Integers that do not fit are
  # errors of their own, not a field that fails to parse.
  @spec v3_value(binary()) :: {:ok, term(), binary()} | :fail | {:error, binary()}
  @doc false
  def v3_value(<<?", text::binary>>) do
    case quote_end(text) do
      :none ->
        :fail

      pos ->
        <<inner::binary-size(pos), ?", rest::binary>> = text
        {:ok, LineProtocolEscape.unescape_string_field(inner), rest}
    end
  end

  def v3_value(<<c, _rest::binary>> = text) when c in ?0..?9 or c == ?-,
    do: LineProtocolNumber.scan(text)

  def v3_value("true" <> rest), do: {:ok, true, rest}
  def v3_value("True" <> rest), do: {:ok, true, rest}
  def v3_value("TRUE" <> rest), do: {:ok, true, rest}
  def v3_value("t" <> rest), do: {:ok, true, rest}
  def v3_value("T" <> rest), do: {:ok, true, rest}
  def v3_value("false" <> rest), do: {:ok, false, rest}
  def v3_value("False" <> rest), do: {:ok, false, rest}
  def v3_value("FALSE" <> rest), do: {:ok, false, rest}
  def v3_value("f" <> rest), do: {:ok, false, rest}
  def v3_value("F" <> rest), do: {:ok, false, rest}
  def v3_value(_other), do: :fail

  # Whitespace1 and a timestamp, then optional whitespace. Anything else
  # left is trailing content, and a space that no timestamp follows is
  # left with it.
  @spec v3_timestamp(binary()) :: {:ok, binary() | nil} | {:error, binary()}
  @doc false
  def v3_timestamp(""), do: {:ok, nil}

  def v3_timestamp(<<?\s, _more::binary>> = rest) do
    case rest |> skip_spaces() |> take_integer() do
      {"", _after} ->
        trailing_error(rest)

      {timestamp, after_timestamp} ->
        case skip_spaces(after_timestamp) do
          "" -> {:ok, timestamp}
          more -> trailing_error(more)
        end
    end
  end

  def v3_timestamp(rest), do: trailing_error(rest)

  @spec trailing_error(binary()) :: {:error, binary()}
  defp trailing_error(rest),
    do: {:error, "Could not parse entire line. Found trailing content: `#{excerpt(rest)}`"}

  @spec take_integer(binary()) :: {binary(), binary()}
  defp take_integer(text) do
    sign = LineProtocolNumber.sign_size(text)
    <<_sign::binary-size(sign), unsigned::binary>> = text

    case LineProtocolNumber.digit_count(unsigned, 0) do
      0 ->
        {"", text}

      digits ->
        <<integer::binary-size(sign + digits), after_integer::binary>> = text
        {integer, after_integer}
    end
  end

  @spec skip_spaces(binary()) :: binary()
  @doc false
  def skip_spaces(<<?\s, rest::binary>>), do: skip_spaces(rest)
  def skip_spaces(text), do: text

  # The position of the first separator of a name at or after the start of
  # `text` that no backslash escapes (a backslash takes the byte after it
  # with it), `:none` when there is none: a measurement or tag value ends
  # at a comma or a space, a tag or field key at an equals sign or a space,
  # a string at a quote.
  @spec name_end(binary()) :: non_neg_integer() | :none
  defp name_end(text), do: name_end(text, 0)

  defp name_end(<<?\\, _escaped, rest::binary>>, pos), do: name_end(rest, pos + 2)
  defp name_end(<<c, _rest::binary>>, pos) when c in [?,, ?\s, ?\t], do: pos
  defp name_end(<<_c, rest::binary>>, pos), do: name_end(rest, pos + 1)
  defp name_end(<<>>, _pos), do: :none

  @spec key_end(binary()) :: non_neg_integer() | :none
  @doc false
  def key_end(text), do: key_end(text, 0)

  defp key_end(<<?\\, _escaped, rest::binary>>, pos), do: key_end(rest, pos + 2)
  defp key_end(<<c, _rest::binary>>, pos) when c in [?=, ?\s, ?\t], do: pos
  defp key_end(<<_c, rest::binary>>, pos), do: key_end(rest, pos + 1)
  defp key_end(<<>>, _pos), do: :none

  @spec quote_end(binary()) :: non_neg_integer() | :none
  @doc false
  def quote_end(text), do: quote_end(text, 0)

  defp quote_end(<<?\\, _escaped, rest::binary>>, pos), do: quote_end(rest, pos + 2)
  defp quote_end(<<?", _rest::binary>>, pos), do: pos
  defp quote_end(<<_c, rest::binary>>, pos), do: quote_end(rest, pos + 1)
  defp quote_end(<<>>, _pos), do: :none

  # A key is one column, so a key used as both a tag and a field cannot be
  # typed — on InfluxDB 3 — and a field named twice is refused. They are
  # met in field order, the first one wins (verified). `time` on InfluxDB 3
  # is checked by the store, because the engine's wording depends on
  # whether the table already exists. The field keys arrive as written and
  # are unescaped here.
  @spec v3_check_fields(map(), [{binary(), term()}]) :: {:ok, map()} | {:error, binary()}
  defp v3_check_fields(tags, fields) do
    fields
    |> Enum.reduce_while(%{}, fn {raw_key, value}, seen ->
      key = LineProtocolEscape.unescape_tag(raw_key)

      cond do
        is_map_key(seen, key) ->
          {:halt, {:error, "invalid line protocol - multiple instances of '#{key}' field found"}}

        is_map_key(tags, key) ->
          {:halt,
           {:error,
            "invalid column type for column '#{key}', expected iox::column_type::tag, got " <>
              LineProtocolNumber.column_type(:field, value)}}

        true ->
          {:cont, Map.put(seen, key, value)}
      end
    end)
    |> case do
      {:error, _message} = error -> error
      seen -> {:ok, seen}
    end
  end
end
