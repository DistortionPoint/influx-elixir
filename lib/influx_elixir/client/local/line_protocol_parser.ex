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

  The two engines do not parse alike, and each is parsed as it parses, so
  that a line they refuse is refused with their words:

    * InfluxDB 3 (`:v3`) reads `series SP+ fields [SP+ timestamp] SP*`; what
      is left is "Could not parse entire line. Found trailing content" and
      a first field that does not parse is "No fields were provided". The
      grammar is in the comments above `parse_v3/2`.
    * InfluxDB 2 (`:v2`) is a port of Go's `models.ParsePoints` scanners
      (`scanKey`, `scanFields`, `scanNumber`, `scanBoolean`, `scanTime`),
      whose errors name the scanner that failed: `invalid field format`,
      `missing field value`, `invalid number`, `bad timestamp`, ... See
      `parse_v2/2`.
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
      |> Enum.reject(fn {line, _n} -> blank_or_comment?(line, dialect) end)
      |> Enum.map(fn {line, n} -> parse_line(line, n, precision, dialect) end)

    case results do
      [] -> {:error, %{status: 400, body: "incoming write was empty"}}
      results -> {:ok, results}
    end
  end

  # A line of only spaces and tabs is blank, and a `#` after them starts a
  # comment (both verified on both engines; nothing else is blank to
  # InfluxDB 3: a line of `\r`, `\v`, `\f` or a no-break space is its
  # "Expected at least one space character"). InfluxDB 2 also skips NUL
  # bytes there. It stops at the first other byte.
  @spec blank_or_comment?(binary(), dialect()) :: boolean()
  defp blank_or_comment?(line, dialect) do
    case skip_blanks(line, dialect) do
      <<>> -> true
      <<?#, _rest::binary>> -> true
      _content -> false
    end
  end

  @spec skip_blanks(binary(), dialect()) :: binary()
  defp skip_blanks(<<c, rest::binary>>, dialect) when c in [?\s, ?\t],
    do: skip_blanks(rest, dialect)

  defp skip_blanks(<<0, rest::binary>>, :v2), do: skip_blanks(rest, :v2)
  defp skip_blanks(line, _dialect), do: line

  # Splits the payload at newlines that are not inside a quoted string
  # field value.
  @spec split_lines(binary()) :: [binary()]
  # Without a quote no newline can be inside a string value, and a plain
  # split gives the same lines as the careful scan below, much faster.
  defp split_lines(text) do
    if plain?(text, "\""),
      do: :binary.split(text, "\n", [:global]),
      else: do_split_lines(text, <<>>, [], false)
  end

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

  # True when none of the bytes that change how a token splits (a quote, a
  # backslash) occur; the split functions then take `:binary.split/3`.
  @spec plain?(binary(), binary() | [binary()]) :: boolean()
  defp plain?(text, bytes) when is_binary(bytes), do: :binary.match(text, bytes) == :nomatch
  defp plain?(text, bytes), do: Enum.all?(bytes, &plain?(text, &1))
  # Parses a single line protocol line into a point map. The two engines
  # parse differently and word their errors differently, so each has its
  # own grammar: `parse_v3/2` and `parse_v2/2`.
  @spec parse_line(binary(), pos_integer(), precision(), dialect()) :: line_result()
  defp parse_line(line, number, precision, dialect) do
    case terminator_error(line, dialect) do
      nil -> parse_line_parts(line, number, precision, dialect)
      message -> {:error, line_error(message, number, line)}
    end
  end

  @spec parse_line_parts(binary(), pos_integer(), precision(), dialect()) :: line_result()
  defp parse_line_parts(line, number, precision, :v3) do
    case line |> trim_leading_blanks() |> parse_v3(precision) do
      {:ok, point} -> {:ok, point, number, line}
      {:error, message} -> {:error, line_error(message, number, line)}
    end
  end

  # InfluxDB 2 quotes the line after its leading whitespace in the error.
  defp parse_line_parts(line, number, precision, :v2) do
    trimmed = skip_blanks(line, :v2)

    case parse_v2(trimmed, precision) do
      {:ok, point} -> {:ok, point, number, trimmed}
      {:error, message} -> {:error, line_error(message, number, trimmed)}
    end
  end

  # Leading spaces and tabs, by byte: a regex here ran on every line of
  # every write.
  @spec trim_leading_blanks(binary()) :: binary()
  defp trim_leading_blanks(<<c, rest::binary>>) when c in [?\s, ?\t],
    do: trim_leading_blanks(rest)

  defp trim_leading_blanks(line), do: line

  # ---------------------------------------------------------------------------
  # InfluxDB 3 grammar
  #
  # `series SP+ fields [SP+ timestamp] SP*`, and what is left over is the
  # error "Could not parse entire line. Found trailing content". Every
  # rule below was probed against Core:
  #
  #   * names (measurement, tag keys and values, field keys) end at an
  #     unescaped separator and know no quotes; a tag or field key may hold
  #     commas (`a,b=1` is the key `a,b`)
  #   * a field that does not parse ends the field list: the first one is
  #     "No fields were provided", a later one leaves the rest of the line
  #     as trailing content, starting after its comma when it is the second
  #     field and at the comma from the third on
  #   * a number is `-?digits[.digits][e[+-]digits]`, `i` and `u` suffixes
  #     make integers; whatever follows the longest match is trailing
  #     content (`5.` leaves `.`, `1e` leaves `e`, `tRUE` is `t` and `RUE`);
  #     `.5`, `+5`, `NaN` and `inf` are not values
  #   * a timestamp is `-?digits`
  # ---------------------------------------------------------------------------

  @need_space "Expected at least one space character, got end of input"
  @trailing_backslash "Measurements, tag keys and values, and field keys may not end with a backslash"
  @no_fields "No fields were provided"

  @spec parse_v3(binary(), precision()) :: {:ok, point()} | {:error, binary()}
  defp parse_v3(line, precision) do
    with {:ok, measurement_raw, tags_raw, after_series} <- v3_series(line),
         {:ok, measurement, tags} <- v3_names(measurement_raw, tags_raw, line, after_series),
         {:ok, fields, rest} <- v3_fields(skip_spaces(after_series)),
         {:ok, timestamp_text} <- v3_timestamp(rest),
         {:ok, timestamp} <- parse_timestamp(timestamp_text, precision, :v3),
         {:ok, fields} <- v3_check_fields(tags, fields) do
      {:ok, %{measurement: measurement, tags: tags, fields: fields, timestamp: timestamp}}
    end
  end

  # The measurement and the tag set. `after_series` starts at the space
  # that ends them.
  @spec v3_series(binary()) ::
          {:ok, binary(), [{binary(), binary()}], binary()} | {:error, binary()}
  defp v3_series(line) do
    case find_unescaped(line, :name_end, 0) do
      :none ->
        if ends_in_backslash?(line),
          do: {:error, @trailing_backslash},
          else: {:error, @need_space}

      0 ->
        {:error, "Invalid measurement was provided"}

      pos ->
        <<measurement::binary-size(pos), separator, rest::binary>> = line

        cond do
          ends_in_backslash?(measurement) ->
            {:error, @trailing_backslash}

          separator == ?, ->
            with {:ok, tags, after_series} <- v3_tags(rest, rest, []),
                 do: {:ok, measurement, tags, after_series}

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
    case find_unescaped(tags, :key_end, 0) do
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
    do: if(ends_in_backslash?(name), do: @trailing_backslash, else: message)

  @spec v3_tag_value(binary(), binary(), binary(), [{binary(), binary()}]) ::
          {:ok, [{binary(), binary()}], binary()} | {:error, binary()}
  defp v3_tag_value(key, _rest, _whole, _acc)
       when binary_part(key, byte_size(key) - 1, 1) == "\\",
       do: {:error, @trailing_backslash}

  defp v3_tag_value(_key, "", _whole, _acc), do: {:error, "Expected tag value, got end of input"}

  defp v3_tag_value(key, rest, whole, acc) do
    case find_unescaped(rest, :name_end, 0) do
      :none ->
        {:error, name_error(rest, @need_space)}

      0 ->
        {:error, "Expected tag value, got `#{excerpt(rest)}`"}

      pos ->
        <<value::binary-size(pos), separator, more::binary>> = rest

        cond do
          ends_in_backslash?(value) ->
            {:error, @trailing_backslash}

          separator == ?, ->
            v3_tags(more, whole, [{key, value} | acc])

          true ->
            {:ok, Enum.reverse([{key, value} | acc]),
             binary_part(rest, pos, byte_size(rest) - pos)}
        end
    end
  end

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

  @spec v3_names(binary(), [{binary(), binary()}], binary(), binary()) ::
          {:ok, binary(), %{binary() => binary()}} | {:error, binary()}
  defp v3_names(measurement_raw, tags_raw, line, after_series) do
    series = binary_part(line, 0, byte_size(line) - byte_size(after_series))

    # Nearly every series has no escape and no quote, and then its names
    # are what was written.
    if :binary.match(series, pattern(:escapes)) == :nomatch do
      {:ok, measurement_raw, Map.new(tags_raw)}
    else
      {:ok, unescape_measurement(measurement_raw),
       Map.new(tags_raw, fn {k, v} -> {unescape_tag(k), unescape_tag(v)} end)}
    end
  end

  # A raw name whose last byte is a backslash: `\\` at the end, since a
  # single one would have escaped the separator.
  @spec ends_in_backslash?(binary()) :: boolean()
  defp ends_in_backslash?(""), do: false
  defp ends_in_backslash?(raw), do: :binary.last(raw) == ?\\

  @spec v3_fields(binary()) :: {:ok, [{binary(), term()}], binary()} | {:error, binary()}
  defp v3_fields(""), do: {:error, @no_fields}

  defp v3_fields(text) do
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

  @spec v3_field(binary()) :: {:ok, {binary(), term()}, binary()} | :fail | {:error, binary()}
  defp v3_field(text) do
    case find_unescaped(text, :key_end, 0) do
      :none ->
        if ends_in_backslash?(text), do: {:error, @trailing_backslash}, else: :fail

      pos when pos > 0 ->
        <<key::binary-size(pos), separator, rest::binary>> = text

        cond do
          ends_in_backslash?(key) ->
            {:error, @trailing_backslash}

          separator != ?= ->
            :fail

          true ->
            with {:ok, value, rest} <- v3_value(rest), do: {:ok, {unescape_tag(key), value}, rest}
        end

      _no_key ->
        :fail
    end
  end

  # One field value and what follows it. Integers that do not fit are
  # errors of their own, not a field that fails to parse.
  @spec v3_value(binary()) :: {:ok, term(), binary()} | :fail | {:error, binary()}
  defp v3_value(<<?", text::binary>>) do
    case find_unescaped(text, :quote_end, 0) do
      :none ->
        :fail

      pos ->
        <<inner::binary-size(pos), ?", rest::binary>> = text
        {:ok, unquote_string(inner), rest}
    end
  end

  defp v3_value(<<c, _rest::binary>> = text) when c in ?0..?9 or c == ?-, do: v3_number(text)
  defp v3_value("true" <> rest), do: {:ok, true, rest}
  defp v3_value("True" <> rest), do: {:ok, true, rest}
  defp v3_value("TRUE" <> rest), do: {:ok, true, rest}
  defp v3_value("t" <> rest), do: {:ok, true, rest}
  defp v3_value("T" <> rest), do: {:ok, true, rest}
  defp v3_value("false" <> rest), do: {:ok, false, rest}
  defp v3_value("False" <> rest), do: {:ok, false, rest}
  defp v3_value("FALSE" <> rest), do: {:ok, false, rest}
  defp v3_value("f" <> rest), do: {:ok, false, rest}
  defp v3_value("F" <> rest), do: {:ok, false, rest}
  defp v3_value(_other), do: :fail

  @spec v3_number(binary()) :: {:ok, term(), binary()} | :fail | {:error, binary()}
  defp v3_number(text) do
    sign = if binary_at(text, 0) == ?-, do: 1, else: 0
    digits = digit_run(text, sign)
    int_end = sign + digits

    cond do
      digits == 0 ->
        :fail

      binary_at(text, int_end) == ?i ->
        integer_value(text, int_end, "integer", @int64_min, @int64_max, & &1)

      binary_at(text, int_end) == ?u and sign == 0 ->
        integer_value(text, int_end, "unsigned integer", 0, @uint64_max, &{:uint, &1})

      true ->
        v3_float(text, int_end)
    end
  end

  @spec integer_value(binary(), non_neg_integer(), binary(), integer(), integer(), fun()) ::
          {:ok, term(), binary()} | {:error, binary()}
  defp integer_value(text, int_end, what, min, max, wrap) do
    digits = binary_part(text, 0, int_end)
    rest = binary_part(text, int_end + 1, byte_size(text) - int_end - 1)

    case Integer.parse(digits) do
      {n, ""} when n >= min and n <= max -> {:ok, wrap.(n), rest}
      _out_of_range -> {:error, "Unable to parse #{what} value `#{digits}`"}
    end
  end

  # The fraction needs a digit after its point and the exponent a digit
  # after its sign, or they are left as trailing content.
  @spec v3_float(binary(), non_neg_integer()) :: {:ok, float(), binary()} | {:error, binary()}
  defp v3_float(text, int_end) do
    frac_end =
      case {binary_at(text, int_end), digit_run(text, int_end + 1)} do
        {?., n} when n > 0 -> int_end + 1 + n
        _no_fraction -> int_end
      end

    exp_end = exponent_end(text, frac_end)
    number = binary_part(text, 0, exp_end)
    rest = binary_part(text, exp_end, byte_size(text) - exp_end)

    case parse_float(number) do
      {:ok, float} -> {:ok, float, rest}
      :error -> {:error, "Client.Local: the float #{number} is outside what Elixir can hold"}
    end
  end

  @spec exponent_end(binary(), non_neg_integer()) :: non_neg_integer()
  defp exponent_end(text, from) do
    if binary_at(text, from) in [?e, ?E] do
      digits_from = if binary_at(text, from + 1) in [?+, ?-], do: from + 2, else: from + 1

      case digit_run(text, digits_from) do
        0 -> from
        n -> digits_from + n
      end
    else
      from
    end
  end

  # The number of ASCII digits from `from`.
  @spec digit_run(binary(), non_neg_integer()) :: non_neg_integer()
  defp digit_run(text, from), do: digit_run(text, from, 0)

  defp digit_run(text, from, n) do
    case text do
      <<_skip::binary-size(from), c, _rest::binary>> when c in ?0..?9 ->
        digit_run(text, from + 1, n + 1)

      _end ->
        n
    end
  end

  @spec binary_at(binary(), integer()) :: byte() | nil
  defp binary_at(text, i) when i >= 0 and i < byte_size(text), do: :binary.at(text, i)
  defp binary_at(_text, _i), do: nil

  # The float a number's text means; `:error` when it does not fit a float.
  # Elixir reads most spellings as they are; `5.` and `.5` (which InfluxDB 2
  # reads too) it does not, so they are written the way it does (`5.0` and
  # `0.5`) and tried again.
  @spec parse_float(binary()) :: {:ok, float()} | :error
  defp parse_float(text) do
    case Float.parse(text) do
      {float, ""} -> {:ok, float}
      _unread -> parse_float_normalised(text)
    end
  end

  defp parse_float_normalised(text) do
    {mantissa, exponent} = split_exponent(text)
    {sign, unsigned} = split_sign(mantissa)
    {whole, fraction} = split_point(unsigned)

    if whole == "" and fraction == "" do
      :error
    else
      normal =
        sign <>
          if(whole == "", do: "0", else: whole) <>
          "." <> if(fraction == "", do: "0", else: fraction) <> exponent

      case Float.parse(normal) do
        {float, ""} -> {:ok, float}
        _unread -> :error
      end
    end
  end

  @spec split_exponent(binary()) :: {binary(), binary()}
  defp split_exponent(text) do
    case :binary.split(text, ["e", "E"]) do
      [mantissa, exponent] -> {mantissa, "e" <> exponent}
      [mantissa] -> {mantissa, ""}
    end
  end

  @spec split_sign(binary()) :: {binary(), binary()}
  defp split_sign("-" <> unsigned), do: {"-", unsigned}
  defp split_sign(unsigned), do: {"", unsigned}

  @spec split_point(binary()) :: {binary(), binary()}
  defp split_point(unsigned) do
    case :binary.split(unsigned, ".") do
      [whole, fraction] -> {whole, fraction}
      [whole] -> {whole, ""}
    end
  end

  # Whitespace1 and a timestamp, then optional whitespace. Anything else
  # left is trailing content, and a space that no timestamp follows is
  # left with it.
  @spec v3_timestamp(binary()) :: {:ok, binary() | nil} | {:error, binary()}
  defp v3_timestamp(""), do: {:ok, nil}

  defp v3_timestamp(<<?\s, _more::binary>> = rest) do
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

  defp v3_timestamp(rest), do: trailing_error(rest)

  @spec trailing_error(binary()) :: {:error, binary()}
  defp trailing_error(rest),
    do: {:error, "Could not parse entire line. Found trailing content: `#{excerpt(rest)}`"}

  @spec take_integer(binary()) :: {binary(), binary()}
  defp take_integer(text) do
    sign = if binary_at(text, 0) == ?-, do: 1, else: 0

    case digit_run(text, sign) do
      0 ->
        {"", text}

      n ->
        {binary_part(text, 0, sign + n), binary_part(text, sign + n, byte_size(text) - sign - n)}
    end
  end

  @spec skip_spaces(binary()) :: binary()
  defp skip_spaces(<<?\s, rest::binary>>), do: skip_spaces(rest)
  defp skip_spaces(text), do: text

  # The position of the first byte of `stops` at or after `from` that no
  # backslash escapes: one that follows an odd run of backslashes does not
  # end the name. `:none` when there is no such byte. `stops` names a
  # compiled pattern: matching against a list of bytes compiles it on every
  # call, which cost more than the rest of the line.
  @spec find_unescaped(binary(), atom(), non_neg_integer()) :: non_neg_integer() | :none
  defp find_unescaped(text, stops, from) do
    case :binary.match(text, pattern(stops), scope: {from, byte_size(text) - from}) do
      :nomatch ->
        :none

      {pos, 1} ->
        if rem(backslash_run(text, pos - 1, 0), 2) == 1,
          do: find_unescaped(text, stops, pos + 1),
          else: pos
    end
  end

  # The stop bytes of each kind of name: a measurement or tag value ends at
  # a comma or a space, a tag or field key at an equals sign or a space, a
  # string at a quote. Compiled on first use and kept.
  @patterns %{
    name_end: [",", " "],
    key_end: ["=", " "],
    quote_end: ["\""],
    escapes: ["\\", "\""]
  }

  @spec pattern(atom()) :: :binary.cp()
  defp pattern(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        compiled = :binary.compile_pattern(Map.fetch!(@patterns, name))
        :persistent_term.put(key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  @spec backslash_run(binary(), integer(), non_neg_integer()) :: non_neg_integer()
  defp backslash_run(_text, i, n) when i < 0, do: n

  defp backslash_run(text, i, n) do
    if :binary.at(text, i) == ?\\, do: backslash_run(text, i - 1, n + 1), else: n
  end

  # ---------------------------------------------------------------------------
  # InfluxDB 2 grammar
  #
  # InfluxDB 2 parses with Go's `models.ParsePoints`, which scans a line in
  # three blocks (key, fields, time) and words its errors after the scanner
  # that failed. This is a port of those scanners, each rule checked against
  # 2.7:
  #
  #   * the key ends at the first unescaped space; a name with no space left
  #     is "missing fields"; tags are `key=value`, `missing tag key|value`,
  #     `invalid tag format` (an unescaped `=` in a value), `duplicate tags`
  #   * fields need an `=` and a value that is not empty: `missing field
  #     key|value`, `invalid field format` (no `=`, or a comma without a
  #     field), `unbalanced quotes`, `invalid number`, `invalid float`,
  #     `invalid boolean`; a quote is a string's only when an `=` is open
  #   * the time is `-?digits`: `bad timestamp`; anything but spaces after
  #     it is `point is invalid`
  #
  # Every failed line is reported, joined by newlines, in the frame
  # `unable to parse '<line>': <reason>`.
  # ---------------------------------------------------------------------------

  @spec parse_v2(binary(), precision()) :: {:ok, point()} | {:error, binary()}
  defp parse_v2(buf, precision) do
    with {:ok, measurement_raw, tags_raw, fields_from} <- v2_key(buf),
         :ok <- v2_distinct(tags_raw),
         {:ok, fields_start, fields_end} <- v2_scan_fields(buf, fields_from),
         {:ok, time_start, time_end} <- v2_scan_time(buf, fields_end),
         {:ok, timestamp} <-
           v2_timestamp(binary_part(buf, time_start, time_end - time_start), precision),
         :ok <- v2_only_spaces(buf, time_end),
         {:ok, fields} <- v2_fields(binary_part(buf, fields_start, fields_end - fields_start)) do
      tags = Map.new(tags_raw, fn {k, v} -> {unescape_tag(k), unescape_tag(v)} end)

      with {:ok, fields} <- check_columns(tags, fields, :v2) do
        {:ok,
         %{
           measurement: unescape_measurement(measurement_raw),
           tags: tags,
           fields: fields,
           timestamp: timestamp
         }}
      end
    end
  end

  # The measurement and tags, and where the fields block starts (the space).
  @spec v2_key(binary()) ::
          {:ok, binary(), [{binary(), binary()}], non_neg_integer()} | {:error, binary()}
  defp v2_key(<<>>), do: {:error, "missing measurement"}
  defp v2_key(<<?,, _rest::binary>>), do: {:error, "missing measurement"}

  defp v2_key(buf) do
    case v2_measurement(buf, 1) do
      :end ->
        {:error, "missing fields"}

      {:fields, at} ->
        {:ok, binary_part(buf, 0, at), [], at}

      {:tags, from, comma} ->
        with {:ok, pairs, state, at} <- v2_tags(buf, from, []) do
          if state == :fields,
            do: {:ok, binary_part(buf, 0, comma), pairs, at},
            else: {:error, "missing fields"}
        end
    end
  end

  @spec v2_measurement(binary(), non_neg_integer()) ::
          :end | {:fields, non_neg_integer()} | {:tags, non_neg_integer(), non_neg_integer()}
  defp v2_measurement(buf, i) do
    char = binary_at(buf, i)
    escaped = binary_at(buf, i - 1) == ?\\

    cond do
      char == nil -> :end
      char == ?, and not escaped -> {:tags, i + 1, i}
      char == ?\s and not escaped -> {:fields, i}
      true -> v2_measurement(buf, i + 1)
    end
  end

  @spec v2_tags(binary(), non_neg_integer(), [{binary(), binary()}]) ::
          {:ok, [{binary(), binary()}], :fields | :end, non_neg_integer()} | {:error, binary()}
  defp v2_tags(buf, from, acc) do
    with {:ok, equals} <- v2_tag_key(buf, from),
         {:ok, state, value_end, next} <- v2_tag_value(buf, equals + 1) do
      pair =
        {binary_part(buf, from, equals - from),
         binary_part(buf, equals + 1, value_end - equals - 1)}

      if state == :key,
        do: v2_tags(buf, next, [pair | acc]),
        else: {:ok, Enum.reverse([pair | acc]), state, next}
    end
  end

  # The index of the `=` that ends the tag key starting at `i`.
  @spec v2_tag_key(binary(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, binary()}
  defp v2_tag_key(buf, i) do
    if binary_at(buf, i) in [nil, ?\s, ?,, ?=],
      do: {:error, "missing tag key"},
      else: v2_tag_key_scan(buf, i + 1)
  end

  defp v2_tag_key_scan(buf, i) do
    char = binary_at(buf, i)
    escaped = binary_at(buf, i - 1) == ?\\

    cond do
      char == nil or (char in [?\s, ?,] and not escaped) -> {:error, "missing tag value"}
      char == ?= and not escaped -> {:ok, i}
      true -> v2_tag_key_scan(buf, i + 1)
    end
  end

  # `{:ok, next_state, value_end, next}`: `:key` after a comma, `:fields` at
  # the space, `:end` when the line ends in the value.
  @spec v2_tag_value(binary(), non_neg_integer()) ::
          {:ok, :key | :fields | :end, non_neg_integer(), non_neg_integer()}
          | {:error, binary()}
  defp v2_tag_value(buf, i) do
    if binary_at(buf, i) in [nil, ?,, ?\s],
      do: {:error, "missing tag value"},
      else: v2_tag_value_scan(buf, i + 1)
  end

  defp v2_tag_value_scan(buf, i) do
    char = binary_at(buf, i)
    escaped = binary_at(buf, i - 1) == ?\\

    cond do
      char == nil -> {:ok, :end, i, i}
      char == ?= and not escaped -> {:error, "invalid tag format"}
      char == ?, and not escaped -> {:ok, :key, i, i + 1}
      char == ?\s and not escaped -> {:ok, :fields, i, i}
      true -> v2_tag_value_scan(buf, i + 1)
    end
  end

  @spec v2_distinct([{binary(), binary()}]) :: :ok | {:error, binary()}
  defp v2_distinct(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))
    if length(Enum.uniq(keys)) == length(keys), do: :ok, else: {:error, "duplicate tags"}
  end

  # Go's `skipWhitespace`: spaces, tabs and NUL.
  @spec v2_skip(binary(), non_neg_integer()) :: non_neg_integer()
  defp v2_skip(buf, i) do
    if binary_at(buf, i) in [?\s, ?\t, 0], do: v2_skip(buf, i + 1), else: i
  end

  # The fields block: `{:ok, start, end}`.
  @spec v2_scan_fields(binary(), non_neg_integer()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, binary()}
  defp v2_scan_fields(buf, from) do
    start = v2_skip(buf, from)
    v2_fields_loop(buf, start, start, false, 0, 0)
  end

  defp v2_fields_loop(buf, start, i, quoted, equals, commas),
    do: v2_fields_step(buf, start, i, binary_at(buf, i), quoted, equals, commas)

  # One byte of the fields block. `quoted` is whether a string is open; a
  # quote opens one only after an `=` that no comma has closed.
  defp v2_fields_step(_buf, start, i, nil, quoted, equals, commas),
    do: v2_fields_done(start, i, quoted, equals, commas)

  defp v2_fields_step(buf, start, i, ?\\, quoted, equals, commas) when i + 1 < byte_size(buf),
    do: v2_fields_loop(buf, start, i + 2, quoted, equals, commas)

  defp v2_fields_step(buf, start, i, ?", quoted, equals, commas) when equals > commas,
    do: v2_fields_loop(buf, start, i + 1, not quoted, equals, commas)

  defp v2_fields_step(buf, start, i, ?=, false, equals, commas),
    do: v2_field_value(buf, start, i, equals + 1, commas)

  defp v2_fields_step(buf, start, i, ?,, false, equals, commas),
    do: v2_fields_loop(buf, start, i + 1, false, equals, commas + 1)

  defp v2_fields_step(_buf, start, i, ?\s, false, equals, commas),
    do: v2_fields_done(start, i, false, equals, commas)

  defp v2_fields_step(buf, start, i, _char, quoted, equals, commas),
    do: v2_fields_loop(buf, start, i + 1, quoted, equals, commas)

  # An `=` outside a string: the key before it and the value after it.
  defp v2_field_value(buf, start, i, equals, commas) do
    before = binary_at(buf, i - 1)
    before_that = binary_at(buf, i - 2)
    next = binary_at(buf, i + 1)

    cond do
      before in [?\s, ?,] and before_that != ?\\ ->
        {:error, "missing field key"}

      next in [nil, ?,, ?\s] ->
        {:error, "missing field value"}

      next in ?0..?9 or next in [?., ?-, ?N, ?n] ->
        v2_number_then(buf, start, i + 1, equals, commas)

      next == ?" ->
        v2_fields_loop(buf, start, i + 1, false, equals, commas)

      true ->
        v2_boolean_then(buf, start, i + 1, equals, commas)
    end
  end

  defp v2_number_then(buf, start, i, equals, commas) do
    with {:ok, next} <- v2_scan_number(buf, i),
         do: v2_fields_loop(buf, start, next, false, equals, commas)
  end

  defp v2_boolean_then(buf, start, i, equals, commas) do
    with {:ok, next} <- v2_scan_boolean(buf, i),
         do: v2_fields_loop(buf, start, next, false, equals, commas)
  end

  defp v2_fields_done(_start, _i, true, _equals, _commas), do: {:error, "unbalanced quotes"}

  defp v2_fields_done(_start, _i, _quoted, equals, commas)
       when equals == 0 or commas != equals - 1,
       do: {:error, "invalid field format"}

  defp v2_fields_done(start, i, _quoted, _equals, _commas), do: {:ok, start, i}

  # Go's `scanNumber`: where the number ends, or why it is not one.
  @spec v2_scan_number(binary(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, binary()}
  defp v2_scan_number(buf, start) do
    i = if binary_at(buf, start) == ?-, do: start + 1, else: start

    if i == byte_size(buf),
      do: {:error, "invalid number"},
      else: v2_number_loop(buf, start, i, %{int: false, uint: false, decimal: false, exp: false})
  end

  defp v2_number_loop(buf, start, i, flags),
    do: v2_number_step(buf, start, i, binary_at(buf, i), binary_at(buf, i - 1), flags)

  # One byte of a number: digits go on, `i` and `u` end an integer's
  # digits, a point is allowed once, `e` only after the first byte and a
  # sign only after it, and anything else is not a number.
  defp v2_number_step(buf, start, i, char, _previous, flags) when char in [nil, ?,, ?\s],
    do: v2_number_done(buf, start, i, flags)

  defp v2_number_step(buf, start, i, ?i, _previous, %{int: false, uint: false} = flags)
       when i > start,
       do: v2_number_loop(buf, start, i + 1, %{flags | int: true})

  defp v2_number_step(buf, start, i, ?u, _previous, %{int: false, uint: false} = flags)
       when i > start,
       do: v2_number_loop(buf, start, i + 1, %{flags | uint: true})

  defp v2_number_step(_buf, _start, _i, ?., _previous, %{decimal: true}),
    do: {:error, "invalid number"}

  defp v2_number_step(buf, start, i, ?., _previous, flags),
    do: v2_number_loop(buf, start, i + 1, %{flags | decimal: true})

  defp v2_number_step(buf, start, i, char, _previous, flags) when i > start and char in [?e, ?E],
    do: v2_number_loop(buf, start, i + 1, %{flags | exp: true})

  defp v2_number_step(buf, start, i, char, previous, flags)
       when char in [?+, ?-] and previous in [?e, ?E],
       do: v2_number_loop(buf, start, i + 1, flags)

  defp v2_number_step(buf, start, i, char, _previous, flags) when char in ?0..?9,
    do: v2_number_loop(buf, start, i + 1, flags)

  defp v2_number_step(_buf, _start, _i, _char, _previous, _flags), do: {:error, "invalid number"}

  defp v2_number_done(buf, start, i, flags) do
    text = binary_part(buf, start, i - start)
    digits = byte_size(text) - bool_int(flags.int) - bool_int(flags.decimal) - negative(text)

    cond do
      (flags.int or flags.uint) and (flags.decimal or flags.exp) -> {:error, "invalid number"}
      digits == 0 -> {:error, "invalid number"}
      flags.int -> v2_check_integer(text, i, "integer", @int64_min, @int64_max, "ParseInt", ?i)
      flags.uint -> v2_check_integer(text, i, "unsigned", 0, @uint64_max, "ParseUint", ?u)
      parse_float(text) == :error -> {:error, "invalid float"}
      true -> {:ok, i}
    end
  end

  defp v2_check_integer(text, i, what, min, max, parser, suffix) do
    digits = binary_part(text, 0, byte_size(text) - 1)

    cond do
      :binary.last(text) != suffix ->
        {:error, "invalid number"}

      suffix == ?u and String.starts_with?(text, "-") ->
        {:error, "invalid number"}

      match?({n, ""} when n >= min and n <= max, Integer.parse(digits)) ->
        {:ok, i}

      true ->
        {:error,
         "unable to parse #{what} #{digits}: strconv.#{parser}: parsing \"#{digits}\": " <>
           "value out of range"}
    end
  end

  @spec bool_int(boolean()) :: 0 | 1
  defp bool_int(true), do: 1
  defp bool_int(false), do: 0

  @spec negative(binary()) :: 0 | 1
  defp negative("-" <> _rest), do: 1
  defp negative(_text), do: 0

  # Go's `scanBoolean`: `t`, `T`, `true`, `True`, `TRUE` and the `f` forms.
  @spec v2_scan_boolean(binary(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, binary()}
  defp v2_scan_boolean(buf, start) do
    if binary_at(buf, start) in [?t, ?T, ?f, ?F] do
      finish = v2_boolean_end(buf, start + 1)
      word = binary_part(buf, start, finish - start)

      if word in ~w(t T f F true True TRUE false False FALSE),
        do: {:ok, finish},
        else: {:error, "invalid boolean"}
    else
      {:error, "invalid boolean"}
    end
  end

  defp v2_boolean_end(buf, i) do
    if binary_at(buf, i) in [nil, ?,, ?\s], do: i, else: v2_boolean_end(buf, i + 1)
  end

  # The time block: `-?digits`, up to a space or the end.
  @spec v2_scan_time(binary(), non_neg_integer()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, binary()}
  defp v2_scan_time(buf, from) do
    start = v2_skip(buf, from)
    v2_time_loop(buf, start, start)
  end

  defp v2_time_loop(buf, start, i) do
    char = binary_at(buf, i)

    cond do
      char in [nil, ?\n, ?\s] -> {:ok, start, i}
      i == start and char == ?- -> v2_time_loop(buf, start, i + 1)
      char in ?0..?9 -> v2_time_loop(buf, start, i + 1)
      true -> {:error, "bad timestamp"}
    end
  end

  @spec v2_timestamp(binary(), precision()) :: {:ok, integer() | nil} | {:error, binary()}
  defp v2_timestamp("", _precision), do: {:ok, nil}

  defp v2_timestamp("-", _precision),
    do: {:error, ~s|strconv.ParseInt: parsing "-": invalid syntax|}

  defp v2_timestamp(text, precision), do: parse_timestamp(text, precision, :v2)

  @spec v2_only_spaces(binary(), non_neg_integer()) :: :ok | {:error, binary()}
  defp v2_only_spaces(buf, from) do
    case binary_at(buf, from) do
      nil -> :ok
      ?\s -> v2_only_spaces(buf, from + 1)
      _other -> {:error, "point is invalid"}
    end
  end

  # The fields block, already validated: `key=value` pairs. A value is a
  # string when it opens with a quote (its last byte is dropped, whatever
  # it is), a boolean by its first letter, an integer or unsigned integer
  # by its suffix, otherwise a float.
  @spec v2_fields(binary()) :: {:ok, map()} | {:error, binary()}
  defp v2_fields(text), do: v2_fields(text, 0, [])

  defp v2_fields(text, i, acc) when i >= byte_size(text),
    do: {:ok, acc |> Enum.reverse() |> Map.new()}

  defp v2_fields(text, i, acc) do
    equals = v2_to_equals(text, i)
    value_end = v2_value_end(text, equals + 1, false)
    key = binary_part(text, i, equals - i)

    value =
      if equals + 1 <= value_end,
        do: binary_part(text, equals + 1, value_end - equals - 1),
        else: ""

    cond do
      key == "" or value == "" ->
        v2_fields(text, value_end + 1, acc)

      ends_in_backslash?(key) ->
        {:error, "invalid value: field-key=#{key}=#{value}"}

      true ->
        with {:ok, typed} <- v2_value(value),
             do: v2_fields(text, value_end + 1, [{unescape_tag(key), typed} | acc])
    end
  end

  # The `=` that ends a key: a backslash skips the byte after it.
  defp v2_to_equals(text, i) do
    case binary_at(text, i) do
      nil -> byte_size(text)
      ?\\ -> v2_to_equals(text, i + 2)
      ?= -> i
      _other -> v2_to_equals(text, i + 1)
    end
  end

  defp v2_value_end(text, i, quoted) do
    case {binary_at(text, i), binary_at(text, i + 1)} do
      {nil, _next} -> byte_size(text)
      {?\\, next} when next in [?", ?\\] -> v2_value_end(text, i + 2, quoted)
      {?", _next} -> v2_value_end(text, i + 1, not quoted)
      {?,, _next} when not quoted -> i
      _other -> v2_value_end(text, i + 1, quoted)
    end
  end

  @spec v2_value(binary()) :: {:ok, term()} | {:error, binary()}
  defp v2_value(<<?", rest::binary>>) do
    inner = if rest == "", do: "", else: binary_part(rest, 0, byte_size(rest) - 1)
    {:ok, unescape_string_field(inner)}
  end

  defp v2_value(<<c, _rest::binary>>) when c in [?t, ?T], do: {:ok, true}
  defp v2_value(<<c, _rest::binary>>) when c in [?f, ?F], do: {:ok, false}

  defp v2_value(value) do
    body = binary_part(value, 0, byte_size(value) - 1)

    case :binary.last(value) do
      ?i -> v2_integer(body, @int64_min, @int64_max, & &1)
      ?u -> v2_integer(body, 0, @uint64_max, &{:uint, &1})
      _float -> v2_float(value)
    end
  end

  defp v2_integer(digits, min, max, wrap) do
    case Integer.parse(digits) do
      {n, ""} when n >= min and n <= max -> {:ok, wrap.(n)}
      _invalid -> {:error, "invalid number"}
    end
  end

  defp v2_float(text) do
    case parse_float(text) do
      {:ok, float} -> {:ok, float}
      :error -> {:error, "invalid float"}
    end
  end

  # ---------------------------------------------------------------------------
  # Tabs (InfluxDB 3)
  #
  # InfluxDB 3's parser ends a token at an unescaped tab as it does at a
  # space, but only a space separates sections, so a tab outside a quoted
  # string is refused with a message that depends on where it stands
  # (verified; InfluxDB 2 stores the tab instead). A leading tab is
  # whitespace, and `\<tab>` is part of the name. The scan answers only for
  # a tab: a line with no tab, or one malformed before its first tab, is
  # left to the parser.
  # ---------------------------------------------------------------------------

  @spec terminator_error(binary(), dialect()) :: binary() | nil
  defp terminator_error(_line, :v2), do: nil

  defp terminator_error(line, :v3) do
    if plain?(line, ["\t", "\r"]),
      do: nil,
      else: line |> trim_leading_blanks() |> scan_terminators(:measurement, %{})
  end

  @spec scan_terminators(binary(), atom(), map()) :: binary() | nil
  defp scan_terminators(<<>>, _state, _ctx), do: nil

  defp scan_terminators(<<?\\, _c, rest::binary>>, state, ctx),
    do: scan_terminators(rest, advance(state), ctx)

  defp scan_terminators(<<?\t, _rest::binary>> = at, state, ctx),
    do: terminator_message(state, at, ctx)

  # A carriage return ends only a field value or a timestamp (a CRLF line
  # ending among them); in a name or a tag it is an ordinary character
  # (both verified).
  defp scan_terminators(<<?\r, rest::binary>> = at, state, ctx) do
    if region(state) in [:value, :timestamp],
      do: terminator_message(state, at, ctx),
      else: scan_terminators(rest, advance(state), ctx)
  end

  defp scan_terminators(<<?", rest::binary>>, :value_start, ctx), do: skip_string(rest, ctx)

  defp scan_terminators(<<c, rest::binary>> = at, state, ctx),
    do: transition(region(state), state, c, rest, at, ctx)

  # The region a state belongs to: a `*_start` state is its token's region.
  @spec region(atom()) :: atom()
  defp region(state) when state in [:tag_key_start, :tag_key], do: :tag_key
  defp region(state) when state in [:tag_value_start, :tag_value], do: :tag_value
  defp region(state) when state in [:key_start, :key], do: :key
  defp region(state) when state in [:value_start, :value], do: :value
  defp region(state), do: state

  # One character in one region: a separator moves to the next token, a
  # separator where the parser expects none leaves the line to it (`nil`).
  @spec transition(atom(), atom(), byte(), binary(), binary(), map()) :: binary() | nil
  defp transition(:measurement, _state, ?,, rest, _at, ctx),
    do: scan_terminators(rest, :tag_key_start, Map.put(ctx, :tag_set, rest))

  defp transition(:measurement, _state, ?\s, rest, _at, ctx),
    do: scan_terminators(rest, :key_start, Map.put(ctx, :field, :first))

  defp transition(:tag_key, _state, ?=, rest, _at, ctx),
    do: scan_terminators(rest, :tag_value_start, ctx)

  defp transition(:tag_key, _state, c, _rest, _at, _ctx) when c in [?,, ?\s], do: nil

  defp transition(:tag_value, _state, ?,, rest, _at, ctx),
    do: scan_terminators(rest, :tag_key_start, ctx)

  defp transition(:tag_value, _state, ?\s, rest, _at, ctx),
    do: scan_terminators(String.trim_leading(rest, " "), :key_start, Map.put(ctx, :field, :first))

  defp transition(:key, _state, ?=, rest, _at, ctx),
    do: scan_terminators(rest, :value_start, Map.put(ctx, :value_from, rest))

  defp transition(:key, _state, c, _rest, _at, _ctx) when c in [?,, ?\s], do: nil

  defp transition(:value, _state, ?,, rest, at, ctx),
    do: scan_terminators(rest, :key_start, %{ctx | field: {:later, next_field(ctx.field), at}})

  defp transition(:value, _state, ?\s, rest, _at, ctx),
    do: scan_terminators(rest, :timestamp, ctx)

  defp transition(_region, state, _c, rest, _at, ctx),
    do: scan_terminators(rest, advance(state), ctx)

  # A character read in a `*_start` state means the token has begun.
  @spec advance(atom()) :: atom()
  defp advance(:tag_key_start), do: :tag_key
  defp advance(:tag_value_start), do: :tag_value
  defp advance(:key_start), do: :key
  defp advance(:value_start), do: :value
  defp advance(state), do: state

  # A quoted string value, tabs and all, up to its closing quote.
  @spec skip_string(binary(), map()) :: binary() | nil
  defp skip_string(<<>>, _ctx), do: nil
  defp skip_string(<<?\\, _c, rest::binary>>, ctx), do: skip_string(rest, ctx)
  defp skip_string(<<?", rest::binary>>, ctx), do: scan_terminators(rest, :value, ctx)
  defp skip_string(<<_c, rest::binary>>, ctx), do: skip_string(rest, ctx)

  @spec terminator_message(atom(), binary(), map()) :: binary()
  defp terminator_message(state, at, _ctx) when state in [:measurement, :tag_value],
    do: "Expected at least one space character, got `#{at}`"

  defp terminator_message(:tag_key_start, at, _ctx), do: "Expected tag key, got `#{excerpt(at)}`"

  defp terminator_message(:tag_value_start, at, _ctx),
    do: "Expected tag value, got `#{excerpt(at)}`"

  defp terminator_message(:tag_key, _at, %{tag_set: tag_set}) do
    excerpt =
      if String.length(tag_set) > 10, do: String.slice(tag_set, 0, 10) <> "...", else: tag_set

    "Tag set malformed: could not find equals sign in `#{excerpt}`"
  end

  defp terminator_message(state, _at, %{field: :first})
       when state in [:key_start, :key, :value_start],
       do: "No fields were provided"

  # A later field with a tab in its key, or at the start of its value, ends
  # the field list before it: after its comma when it is the second field,
  # at its comma from the third on (verified).
  defp terminator_message(state, _at, %{field: {:later, 2, <<?,, field::binary>>}})
       when state in [:key_start, :key, :value_start],
       do: trailing(field)

  defp terminator_message(state, _at, %{field: {:later, _n, comma}})
       when state in [:key_start, :key, :value_start],
       do: trailing(comma)

  # A terminator after a value that does not parse fails that field, as an
  # empty value does (verified).
  defp terminator_message(:value, at, %{value_from: from} = ctx) do
    value = binary_part(from, 0, byte_size(from) - byte_size(at))

    case parse_field_value(value) do
      {:ok, _typed} -> trailing(at)
      {:error, _reason} -> terminator_message(:value_start, at, ctx)
    end
  end

  defp terminator_message(_timestamp, at, _ctx), do: trailing(at)

  # The number of the field that starts after the next comma.
  @spec next_field(:first | {:later, pos_integer(), binary()}) :: pos_integer()
  defp next_field(:first), do: 2
  defp next_field({:later, n, _comma}), do: n + 1

  @spec trailing(binary()) :: binary()
  defp trailing(content),
    do: "Could not parse entire line. Found trailing content: `#{excerpt(content)}`"

  @doc """
  Builds a `t:line_error/0` the way InfluxDB 3 reports one. The full line
  is kept under `:line` for InfluxDB 2's report, which quotes it whole.
  """
  @spec line_error(binary(), pos_integer(), binary()) :: line_error()
  def line_error(message, number, line) do
    %{
      error_message: message,
      line_number: number,
      # InfluxDB 3 echoes the line without the `\r` of a CRLF ending; one
      # inside the line stays (verified).
      original_line: line |> String.replace_suffix("\r", "") |> String.slice(0, 20),
      line: line
    }
  end

  @doc """
  Builds the `t:line_error/0` for a schema error. InfluxDB 3 does not echo
  the raw line for those but the line as it parsed it (verified): single
  spaces, floats printed shortest and without an exponent (`2.0` → `2`,
  `1e3` → `1000`), strings unquoted, then cut to 20 characters. Parse
  errors keep the raw line (`line_error/3`).
  """
  @spec schema_error(binary(), pos_integer(), binary()) :: line_error()
  def schema_error(message, number, line) do
    %{line_error(message, number, line) | original_line: String.slice(render_line(line), 0, 20)}
  end

  # The engine's rendering of a line that parsed: the key part and
  # timestamp as written, each field value as its parsed value prints.
  @spec render_line(binary()) :: binary()
  defp render_line(line) do
    case line |> String.trim() |> split_line_parts() |> Enum.reject(&(&1 == "")) do
      [key_part, fields_part | rest] ->
        fields =
          fields_part
          |> split_unescaped_comma()
          |> Enum.map_join(",", fn pair ->
            {key, raw} = split_first_unescaped_equals(pair)
            key <> "=" <> render_value(raw)
          end)

        Enum.join([key_part, fields | rest], " ")

      _unparsed ->
        line
    end
  end

  @spec render_value(binary()) :: binary()
  defp render_value(raw) do
    case parse_field_value(raw) do
      {:ok, {:uint, n}} -> "#{n}u"
      {:ok, n} when is_integer(n) -> "#{n}i"
      {:ok, f} when is_float(f) -> render_float(f)
      {:ok, value} -> to_string(value)
      {:error, _reason} -> raw
    end
  end

  # Rust's `f64` Display: the shortest digits that round-trip, never in
  # exponent form, no trailing `.0`.
  @spec render_float(float()) :: binary()
  defp render_float(f) when f == 0.0, do: if(<<f::float>> == <<-0.0::float>>, do: "-0", else: "0")
  defp render_float(f) when f < 0, do: "-" <> render_float(-f)

  defp render_float(f) do
    {mantissa, exponent} =
      case :erlang.float_to_binary(f, [:short]) |> String.split("e") do
        [mantissa, exp] -> {mantissa, String.to_integer(exp)}
        [mantissa] -> {mantissa, 0}
      end

    [whole, frac] = String.split(mantissa, ".")
    digits = whole <> frac
    point = byte_size(whole) + exponent

    cond do
      point <= 0 ->
        "0." <> String.duplicate("0", -point) <> digits

      point >= byte_size(digits) ->
        digits <> String.duplicate("0", point - byte_size(digits))

      true ->
        binary_part(digits, 0, point) <>
          "." <> binary_part(digits, point, byte_size(digits) - point)
    end
    |> trim_fraction()
  end

  @spec trim_fraction(binary()) :: binary()
  defp trim_fraction(text) do
    if String.contains?(text, "."),
      do: text |> String.trim_trailing("0") |> String.trim_trailing("."),
      else: text |> String.trim_leading("0") |> then(&if(&1 == "", do: "0", else: &1))
  end

  # A key is one column, so a key used as both a tag and a field cannot be
  # typed — on InfluxDB 3 — and a field named twice is refused. They are
  # met in field order, the first one wins (verified). `time` on InfluxDB 3
  # is checked by the store, because the engine's wording depends on
  # whether the table already exists.
  @spec v3_check_fields(map(), [{binary(), term()}]) :: {:ok, map()} | {:error, binary()}
  defp v3_check_fields(tags, fields) do
    fields
    |> Enum.reduce_while(%{}, fn {key, value}, seen ->
      cond do
        is_map_key(seen, key) ->
          {:halt, {:error, "invalid line protocol - multiple instances of '#{key}' field found"}}

        is_map_key(tags, key) ->
          {:halt,
           {:error,
            "invalid column type for column '#{key}', expected iox::column_type::tag, got " <>
              column_type(:field, value)}}

        true ->
          {:cont, Map.put(seen, key, value)}
      end
    end)
    |> case do
      {:error, _message} = error -> error
      seen -> {:ok, seen}
    end
  end

  # InfluxDB 2 keeps tags and fields in separate namespaces, refuses a
  # `time` tag and drops a `time` field.
  @spec check_columns(map(), map(), dialect()) :: {:ok, map()} | {:error, binary()}
  defp check_columns(tags, _fields, :v2) when is_map_key(tags, "time"),
    do: {:error, "cannot use reserved tag key \"time\""}

  defp check_columns(_tags, fields, :v2), do: {:ok, Map.delete(fields, "time")}

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
    if plain?(line, ["\"", "\\"]),
      do: :binary.split(line, " ", [:global]),
      else: do_lp_split(line, <<>>, [], false)
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

  # Splits a CSV-like string on unescaped commas, respecting quoted strings.
  @spec split_unescaped_comma(binary()) :: [binary()]
  defp split_unescaped_comma(str) do
    if plain?(str, ["\"", "\\"]),
      do: :binary.split(str, ",", [:global]),
      else: do_csv_split(str, <<>>, [], false)
  end

  defp do_csv_split(<<>>, current, acc, _in_quotes), do: Enum.reverse([current | acc])

  # An escaped backslash is taken whole, so `"ends\\"` closes the string:
  # without this clause the `\"` was read as an escaped quote and the next
  # field was swallowed (verified: the engine stores `ends\`).
  defp do_csv_split(<<"\\\\", rest::binary>>, current, acc, in_quotes) do
    do_csv_split(rest, <<current::binary, "\\\\">>, acc, in_quotes)
  end

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
    if plain?(str, "\\") do
      case :binary.split(str, "=") do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    else
      do_split_eq(str, <<>>)
    end
  end

  defp do_split_eq(<<>>, acc), do: {acc, ""}

  defp do_split_eq(<<"\\\\", rest::binary>>, acc),
    do: do_split_eq(rest, <<acc::binary, "\\\\">>)

  defp do_split_eq(<<"\\=", rest::binary>>, acc) do
    do_split_eq(rest, <<acc::binary, "\\=">>)
  end

  defp do_split_eq(<<"=", rest::binary>>, acc), do: {acc, rest}

  defp do_split_eq(<<c, rest::binary>>, acc) do
    do_split_eq(rest, <<acc::binary, c>>)
  end

  # Parses a whole field value string into its typed Elixir equivalent. An
  # unsigned integer (`7u`) is `{:uint, n}`: its kind is remembered for the
  # schema check only.
  @spec parse_field_value(binary()) :: {:ok, term()} | {:error, binary()}
  defp parse_field_value(text) do
    case v3_value(text) do
      {:ok, value, ""} -> {:ok, value}
      _other -> {:error, "Unable to parse field value `#{text}`"}
    end
  end

  # A string field's inner text with `\"` and `\\` undone, left to right.
  @spec unquote_string(binary()) :: binary()
  defp unquote_string(inner), do: unescape_string_field(inner)

  @spec unescape_string_field(binary()) :: binary()
  defp unescape_string_field(inner) do
    if :binary.match(inner, "\\") == :nomatch,
      do: inner,
      else: do_unescape_string(inner, <<>>)
  end

  defp do_unescape_string(<<>>, acc), do: acc

  defp do_unescape_string(<<?\\, c, rest::binary>>, acc) when c in [?\\, ?"],
    do: do_unescape_string(rest, <<acc::binary, c>>)

  defp do_unescape_string(<<c, rest::binary>>, acc),
    do: do_unescape_string(rest, <<acc::binary, c>>)

  # Parses a raw timestamp string, normalising to nanoseconds.
  @spec parse_timestamp(binary() | nil, precision(), dialect()) ::
          {:ok, integer() | nil} | {:error, binary()}
  defp parse_timestamp(nil, _prec, _dialect), do: {:ok, nil}
  defp parse_timestamp("", _prec, _dialect), do: {:ok, nil}

  # The stored time is nanoseconds in a signed 64-bit integer. A timestamp
  # that does not fit once scaled to nanoseconds is refused, in each
  # version's words (verified): InfluxDB 3 takes the whole int64 range,
  # InfluxDB 2 all but its two ends.
  defp parse_timestamp(ts_str, precision, dialect) do
    with {ts, ""} <- Integer.parse(ts_str),
         true <- ts in @int64_min..@int64_max do
      ns = to_nanoseconds(ts, precision)

      if in_range?(ns, dialect),
        do: {:ok, ns},
        else: {:error, out_of_range(ts, precision, dialect)}
    else
      {_ts, _rest} -> {:error, "Unable to parse timestamp value `#{ts_str}`"}
      :error -> {:error, "Unable to parse timestamp value `#{ts_str}`"}
      false -> {:error, int64_overflow(ts_str, dialect)}
    end
  end

  @spec in_range?(integer(), dialect()) :: boolean()
  defp in_range?(ns, :v3), do: ns in @int64_min..@int64_max
  defp in_range?(ns, :v2), do: ns in (@int64_min + 2)..(@int64_max - 1)

  @spec out_of_range(integer(), precision(), dialect()) :: binary()
  defp out_of_range(ts, precision, :v3),
    do: "timestamp, #{ts}, out of range for precision: #{precision_name(precision)}"

  defp out_of_range(_ts, _precision, :v2),
    do: "time outside range #{@int64_min + 2} - #{@int64_max - 1}"

  @spec int64_overflow(binary(), dialect()) :: binary()
  defp int64_overflow(ts_str, :v3), do: "Unable to parse timestamp value `#{ts_str}`"

  defp int64_overflow(ts_str, :v2),
    do: ~s|strconv.ParseInt: parsing "#{ts_str}": value out of range|

  @spec precision_name(precision()) :: binary()
  defp precision_name(:second), do: "Second"
  defp precision_name(:millisecond), do: "Millisecond"
  defp precision_name(:microsecond), do: "Microsecond"
  defp precision_name(_nanosecond_or_auto), do: "Nanosecond"

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
  # Nearly every name has no escape and no quote; checking for the two
  # bytes first (about 70 ns) skips the replace chain (about 1.3 µs).
  def unescape_measurement(str) do
    if :binary.match(str, "\\") == :nomatch and :binary.match(str, "\"") == :nomatch do
      str
    else
      str
      |> String.trim("\"")
      |> String.replace("\\ ", " ")
      |> String.replace("\\,", ",")
      |> String.replace("\\\\", "\\")
    end
  end

  # Unescape a tag key or value (backslash, comma, equals, space).
  @spec unescape_tag(binary()) :: binary()
  defp unescape_tag(str) do
    if :binary.match(str, "\\") == :nomatch do
      str
    else
      str
      |> String.replace("\\ ", " ")
      |> String.replace("\\,", ",")
      |> String.replace("\\=", "=")
      |> String.replace("\\\\", "\\")
    end
  end
end
