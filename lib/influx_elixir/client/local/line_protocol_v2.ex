defmodule InfluxElixir.Client.Local.LineProtocolV2 do
  @moduledoc """
  The InfluxDB 2 line grammar, a port of Go's `models.ParsePoints` scanners,
  whose errors name the scanner that failed.
  """

  alias InfluxElixir.Client.Local.{
    LineProtocolEscape,
    LineProtocolNumber,
    LineProtocolParser,
    LineProtocolTime
  }

  @typep dialect :: LineProtocolParser.dialect()
  @typep precision :: LineProtocolParser.precision()
  @typep point :: LineProtocolParser.point()

  @int64_max 9_223_372_036_854_775_807
  @int64_min -9_223_372_036_854_775_808
  @uint64_max 18_446_744_073_709_551_615

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

  @spec binary_at(binary(), integer()) :: byte() | nil
  defp binary_at(text, i) when i >= 0 and i < byte_size(text), do: :binary.at(text, i)
  defp binary_at(_text, _i), do: nil

  @spec parse(binary(), precision()) :: {:ok, point()} | {:error, binary()}
  def parse(buf, precision) do
    with {:ok, measurement_raw, tags_raw, fields_from} <- v2_key(buf),
         :ok <- v2_distinct(tags_raw),
         {:ok, fields_start, fields_end} <- v2_scan_fields(buf, fields_from),
         {:ok, time_start, time_end} <- v2_scan_time(buf, fields_end),
         {:ok, timestamp} <-
           v2_timestamp(binary_part(buf, time_start, time_end - time_start), precision),
         :ok <- v2_only_spaces(buf, time_end),
         {:ok, fields} <- v2_fields(binary_part(buf, fields_start, fields_end - fields_start)) do
      tags = Map.new(tags_raw, fn {k, v} -> {v2_tag_name(k), v2_tag_name(v)} end)

      with {:ok, fields} <- check_columns(tags, fields, :v2) do
        point = %{
          measurement: v2_name(measurement_raw),
          tags: tags,
          fields: fields,
          timestamp: timestamp
        }

        {:ok,
         if(unreadable_measurement?(measurement_raw),
           do: Map.put(point, :unreadable, true),
           else: point
         )}
      end
    end
  end

  # InfluxDB 2 accepts a measurement whose escapes its index and its data
  # read differently, and no query then returns the point (verified): one
  # with a backslash before `=` or `"`, or a run of two or more backslashes
  # before a `,` or a space. A single `\,` or `\ ` is an ordinary escape.
  @spec unreadable_measurement?(binary()) :: boolean()
  defp unreadable_measurement?(raw),
    do: :binary.match(raw, "\\") != :nomatch and unreadable_run?(raw, 0)

  defp unreadable_run?(<<?\\, rest::binary>>, run), do: unreadable_run?(rest, run + 1)

  defp unreadable_run?(<<c, _rest::binary>>, run) when run > 0 and c in [?=, ?"], do: true

  defp unreadable_run?(<<c, _rest::binary>>, run) when run > 1 and c in [?,, ?\s], do: true

  defp unreadable_run?(<<_c, rest::binary>>, _run), do: unreadable_run?(rest, 0)
  defp unreadable_run?(<<>>, _run), do: false

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
      LineProtocolNumber.parse_float(text) == :error -> {:error, "invalid float"}
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

  defp v2_timestamp(text, precision), do: LineProtocolTime.parse_timestamp(text, precision, :v2)

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

      LineProtocolEscape.ends_in_backslash?(key) ->
        {:error, "invalid value: field-key=#{key}=#{value}"}

      true ->
        with {:ok, typed} <- v2_value(value),
             do: v2_fields(text, value_end + 1, [{v2_name(key), typed} | acc])
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
    {:ok, LineProtocolEscape.unescape_string_field(inner)}
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
    case LineProtocolNumber.parse_float(text) do
      {:ok, float} -> {:ok, float}
      :error -> {:error, "invalid float"}
    end
  end

  # InfluxDB 2 keeps tags and fields in separate namespaces, refuses a
  # `time` tag and drops a `time` field.
  @spec check_columns(map(), map(), dialect()) :: {:ok, map()} | {:error, binary()}
  defp check_columns(tags, _fields, :v2) when is_map_key(tags, "time"),
    do: {:error, "cannot use reserved tag key \"time\""}

  defp check_columns(_tags, fields, :v2), do: {:ok, Map.delete(fields, "time")}

  @spec v2_tag_name(binary()) :: binary()
  defp v2_tag_name(str), do: LineProtocolEscape.unescape_v2(str, [?\s, ?,, ?=])

  @spec v2_name(binary()) :: binary()
  defp v2_name(str), do: LineProtocolEscape.unescape_v2(str, [?\s, ?,, ?=, ?"])
end
