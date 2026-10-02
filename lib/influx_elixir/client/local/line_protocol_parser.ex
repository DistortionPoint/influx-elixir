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

  alias InfluxElixir.Client.Local.Format

  @typedoc """
  A parsed point: fields and tags as string-keyed maps, timestamp in ns.
  `:unreadable` marks a point InfluxDB 2 accepts and then never returns
  (see `unreadable_measurement?/1`).
  """
  @type point :: %{
          required(:measurement) => binary(),
          required(:tags) => %{binary() => binary()},
          required(:fields) => %{binary() => term()},
          required(:timestamp) => integer() | nil,
          optional(:unreadable) => true
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
  caller assigns the server time.

  A line ends at a newline that is not inside a string field value, found as
  both engines find it (see "Lines" below): a newline inside a quoted
  field value is part of the value.

  Returns `{:error, ...}` only for a payload with no lines at all ("incoming
  write was empty" on the engine); every other problem is a per-line
  `{:error, line_error}` in the list. InfluxDB 3 numbers a line among the
  lines that are not blank or comments and echoes, as `original_line`, the
  physical line with that number in the payload; this parser does both
  (verified), so a comment before a bad line shifts the echo.

  ## Lines

  Both engines find the end of a line with Go's `scanLine`: a backslash
  skips the byte after it (a newline too), the first space starts the
  fields, and a quote toggles string state only when an `=` that no comma
  has closed precedes it (`=` and `,` are counted outside strings). A quote
  in a measurement, a tag or a field key therefore means nothing, and one
  after a field value toggles the state as a quote that opens a string does.
  """
  @spec parse_lines(binary(), precision(), dialect()) ::
          {:ok, [line_result()]} | {:error, map()}
  def parse_lines(text, precision, dialect \\ :v3) do
    context = %{precision: precision, dialect: dialect}
    lines = text |> final_newline_off(dialect) |> split_lines()

    case parse_all(lines, text, context) do
      [] -> {:error, %{status: 400, body: "incoming write was empty"}}
      results -> {:ok, results}
    end
  end

  # InfluxDB 2 reads a final newline as the end of the buffer, not as part of
  # a line a stray quote has left open (verified: such a line is quoted
  # without it); InfluxDB 3 keeps it.
  @spec final_newline_off(binary(), dialect()) :: binary()
  defp final_newline_off(text, :v2) do
    size = byte_size(text) - 1

    case text do
      <<text::binary-size(size), ?\n>> -> text
      _no_final_newline -> text
    end
  end

  defp final_newline_off(text, :v3), do: text

  # The results of every line that counts, in order. A payload's results
  # are as large as the payload, and a process heap that grows by a fraction
  # at a time copies everything built so far at each step: parsed in the
  # caller, 100k lines took 2-3 times as long (measured: 0.8 s against 0.3 s
  # for lines with tags and two fields). So the lines are parsed 10k at a
  # time, each full chunk in a short-lived process whose heap starts at
  # 1M words and whose result is sent back once. A parsed line is 37 to 94
  # words (measured, bare lines to lines with four tags and three fields),
  # so 100 words a line holds a chunk without a collection. The caller's own
  # heap and flags are never touched, only one chunk runs beside it, and a
  # chunk ends on its own, so it cannot outlive a dead caller by more than
  # its own parse.
  @chunk_lines 10_000
  @chunk_heap_words 1_000_000

  @spec parse_all([binary()], binary(), map()) :: [line_result()]
  defp parse_all(lines, text, context) do
    {chunks, _count, _physical} =
      lines
      |> Enum.chunk_every(@chunk_lines)
      |> Enum.reduce({[], 0, nil}, fn chunk, {chunks, count, physical} ->
        {results, count, physical} = parse_chunk(chunk, count, physical, text, context)
        {[results | chunks], count, physical}
      end)

    chunks |> Enum.reverse() |> Enum.concat()
  end

  # The results of one chunk, in order, with the numbering and the split
  # physical lines carried on. A full chunk is parsed in a process of its
  # own, which ends with the chunk and so cannot outlive its caller by more
  # than that; a failure in it is raised again in the caller.
  @spec parse_chunk([binary()], non_neg_integer(), tuple() | nil, binary(), map()) ::
          {[line_result()], non_neg_integer(), tuple() | nil}
  defp parse_chunk(chunk, count, physical, text, context) do
    work = fn -> parse_lines_from(chunk, count, physical, text, context) end

    if length(chunk) < @chunk_lines do
      work.()
    else
      in_chunk_process(work)
    end
  end

  @spec in_chunk_process((-> result)) :: result when result: term()
  defp in_chunk_process(work) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          outcome =
            try do
              {:ok, work.()}
            catch
              kind, reason -> {:raised, kind, reason, __STACKTRACE__}
            end

          send(parent, {ref, outcome})
        end,
        [:monitor, {:min_heap_size, @chunk_heap_words}]
      )

    receive do
      {^ref, outcome} ->
        Process.demonitor(monitor, [:flush])

        case outcome do
          {:ok, result} -> result
          {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
        end

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  @spec parse_lines_from([binary()], non_neg_integer(), tuple() | nil, binary(), map()) ::
          {[line_result()], non_neg_integer(), tuple() | nil}
  defp parse_lines_from(chunk, count, physical, text, %{dialect: dialect} = context) do
    {results, count, physical} =
      Enum.reduce(chunk, {[], count, physical}, fn line, {acc, count, physical} ->
        case content(line, dialect) do
          :skip -> {acc, count, physical}
          content -> parse_numbered(content, count + 1, text, context, {acc, physical})
        end
      end)

    {Enum.reverse(results), count, physical}
  end

  # One line, numbered `number` among the lines that count. The physical
  # lines of the payload are split on the first error only.
  @spec parse_numbered(
          binary(),
          pos_integer(),
          binary(),
          map(),
          {[line_result()], tuple() | nil}
        ) :: {[line_result()], pos_integer(), tuple() | nil}
  defp parse_numbered(line, number, text, context, {acc, physical}) do
    case parse_line(line, context) do
      {:ok, point, shown} ->
        {[{:ok, point, number, shown} | acc], number, physical}

      {:error, message, shown} ->
        physical = physical || text |> :binary.split("\n", [:global]) |> List.to_tuple()
        {[{:error, echoed_error(message, number, shown, physical)} | acc], number, physical}
    end
  end

  # InfluxDB 3 echoes the physical line with the error's number; the
  # `:line` field keeps the failing line itself, which InfluxDB 2 quotes.
  @spec echoed_error(binary(), pos_integer(), binary(), tuple()) :: line_error()
  defp echoed_error(message, number, shown, physical) do
    error = line_error(message, number, shown)

    cond do
      number < tuple_size(physical) -> %{error | original_line: echo(elem(physical, number - 1))}
      # The last physical line has no newline to take a `\r` with it.
      number == tuple_size(physical) -> %{error | original_line: cut(elem(physical, number - 1))}
      true -> error
    end
  end

  # A line of only spaces and tabs is blank, and a `#` after them starts a
  # comment (both verified on both engines; nothing else is blank to
  # InfluxDB 3: a line of `\r`, `\v`, `\f` or a no-break space is its
  # "Expected at least one space character"). InfluxDB 2 also skips NUL
  # bytes there. It stops at the first other byte.
  #
  # InfluxDB 3 skips a comment through the end of its physical line, so a
  # line that a stray quote has joined to the next one (see `parse_lines/3`)
  # goes on with what follows the comment; InfluxDB 2 skips the whole line.
  @spec content(binary(), dialect()) :: :skip | binary()
  defp content(<<c, _rest::binary>> = line, _dialect) when c not in [?\s, ?\t, ?#, 0],
    do: line

  defp content(line, dialect) do
    case {skip_blanks(line, dialect), dialect} do
      {<<>>, _dialect} -> :skip
      {<<?#, _rest::binary>>, :v2} -> :skip
      {<<?#, comment::binary>>, :v3} -> after_comment(comment)
      _content -> line
    end
  end

  @spec after_comment(binary()) :: :skip | binary()
  defp after_comment(comment) do
    case :binary.split(comment, "\n") do
      [_comment] -> :skip
      [_comment, rest] -> content(rest, :v3)
    end
  end

  @spec skip_blanks(binary(), dialect()) :: binary()
  defp skip_blanks(<<c, rest::binary>>, dialect) when c in [?\s, ?\t],
    do: skip_blanks(rest, dialect)

  defp skip_blanks(<<0, rest::binary>>, :v2), do: skip_blanks(rest, :v2)
  defp skip_blanks(line, _dialect), do: line

  # Splits the payload into lines as both engines do (see `parse_lines/3`).
  # A payload with no quote and no backslash splits on newlines alone; in
  # any other a line without either is cut at its newline directly and a
  # line with one is read byte by byte.
  @spec split_lines(binary()) :: [binary()]
  defp split_lines(text) do
    if plain?(text, "\"") and plain?(text, "\\"),
      do: :binary.split(text, "\n", [:global]),
      else: split_from(text, 0, [])
  end

  @spec split_from(binary(), non_neg_integer(), [binary()]) :: [binary()]
  defp split_from(text, start, acc) when start > byte_size(text), do: Enum.reverse(acc)

  defp split_from(text, start, acc) do
    remaining = byte_size(text) - start

    case :binary.match(text, "\n", scope: {start, remaining}) do
      {newline, 1} ->
        if special_free?(text, start, newline - start),
          do: split_from(text, newline + 1, [binary_part(text, start, newline - start) | acc]),
          else: scan_line(text, start, acc)

      :nomatch ->
        if special_free?(text, start, remaining),
          do: Enum.reverse([binary_part(text, start, remaining) | acc]),
          else: scan_line(text, start, acc)
    end
  end

  @spec special_free?(binary(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp special_free?(text, start, length) do
    :binary.match(text, "\"", scope: {start, length}) == :nomatch and
      :binary.match(text, "\\", scope: {start, length}) == :nomatch
  end

  # Reads one line byte by byte from `start`, then goes on with the next.
  @spec scan_line(binary(), non_neg_integer(), [binary()]) :: [binary()]
  defp scan_line(text, start, acc) do
    <<_before::binary-size(start), line::binary>> = text
    {length, resume} = scan(line, 0, false, false, 0, 0)
    found = binary_part(line, 0, length)

    case resume do
      :end -> Enum.reverse([found | acc])
      :after_newline -> split_from(text, start + length + 1, [found | acc])
    end
  end

  # `scanLine`'s state: whether the fields have begun, whether a string is
  # open, and the `=` and `,` seen so far in the fields.
  @spec scan(
          binary(),
          non_neg_integer(),
          boolean(),
          boolean(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {non_neg_integer(), :end | :after_newline}
  defp scan(<<>>, pos, _fields, _quoted, _equals, _commas), do: {pos, :end}

  defp scan(<<?\\, _escaped, rest::binary>>, pos, fields, quoted, equals, commas),
    do: scan(rest, pos + 2, fields, quoted, equals, commas)

  defp scan(<<?\n, _rest::binary>>, pos, _fields, false, _equals, _commas),
    do: {pos, :after_newline}

  defp scan(<<?\s, rest::binary>>, pos, _fields, quoted, equals, commas),
    do: scan(rest, pos + 1, true, quoted, equals, commas)

  defp scan(<<?=, rest::binary>>, pos, true, false, equals, commas),
    do: scan(rest, pos + 1, true, false, equals + 1, commas)

  defp scan(<<?,, rest::binary>>, pos, true, false, equals, commas),
    do: scan(rest, pos + 1, true, false, equals, commas + 1)

  defp scan(<<?", rest::binary>>, pos, true, quoted, equals, commas) when equals > commas,
    do: scan(rest, pos + 1, true, not quoted, equals, commas)

  defp scan(<<_byte, rest::binary>>, pos, fields, quoted, equals, commas),
    do: scan(rest, pos + 1, fields, quoted, equals, commas)

  # True when `bytes` does not occur in `text`.
  @spec plain?(binary(), binary()) :: boolean()
  defp plain?(text, bytes), do: :binary.match(text, bytes) == :nomatch

  # Parses a single line protocol line into a point map. The two engines
  # parse differently and word their errors differently, so each has its
  # own grammar: `parse_v3/2` and `parse_v2/2`. The text returned with the
  # outcome is the line as the engine quotes it.
  @spec parse_line(binary(), map()) ::
          {:ok, point(), binary()} | {:error, binary(), binary()}
  defp parse_line(line, %{dialect: :v3, precision: precision}) do
    case line |> trim_leading_blanks() |> parse_v3(precision) do
      {:ok, point} -> {:ok, point, line}
      {:error, message} -> {:error, message, line}
    end
  end

  # InfluxDB 2 quotes the line after its leading whitespace in the error.
  defp parse_line(line, %{dialect: :v2, precision: precision}) do
    trimmed = skip_blanks(line, :v2)

    case parse_v2(trimmed, precision) do
      {:ok, point} -> {:ok, point, trimmed}
      {:error, message} -> {:error, message, trimmed}
    end
  end

  # Leading spaces and tabs, by byte.
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

  @spec parse_v3(binary(), precision()) :: {:ok, point()} | {:error, binary()}
  defp parse_v3(line, precision) do
    with {:ok, measurement, tags_raw, after_series} <- v3_series(line),
         {:ok, fields_raw, rest} <- v3_fields(skip_spaces(after_series)),
         {:ok, timestamp_text} <- v3_timestamp(rest),
         {:ok, timestamp} <- parse_timestamp(timestamp_text, precision, :v3),
         tags = v3_tag_map(line, measurement, tags_raw, after_series),
         {:ok, fields} <- v3_check_fields(tags, fields_raw),
         :ok <- v3_distinct_tags(tags, tags_raw) do
      {:ok,
       %{
         measurement: unescape_measurement(measurement),
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
  defp v3_series(line) do
    case name_end(line) do
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
    do: if(ends_in_backslash?(name), do: @trailing_backslash, else: message)

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
          ends_in_backslash?(value) ->
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
      else: Map.new(tags_raw, fn {k, v} -> {unescape_tag(k), unescape_tag(v)} end)
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
        |> Enum.map(fn {key, _value} -> unescape_tag(key) end)
        |> Enum.frequencies()
        |> Enum.find_value(fn {key, count} -> if count > 1, do: key end)

      {:error,
       "Client.Local: the tag key #{duplicate} is given twice; InfluxDB 3 Core stores such a " <>
         "line and then answers every query of the table with a 500"}
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

  # A field as written: its key is still escaped.
  @spec v3_field(binary()) :: {:ok, {binary(), term()}, binary()} | :fail | {:error, binary()}
  defp v3_field(text) do
    case key_end(text) do
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
            with {:ok, value, rest} <- v3_value(rest), do: {:ok, {key, value}, rest}
        end

      _no_key ->
        :fail
    end
  end

  # One field value and what follows it. Integers that do not fit are
  # errors of their own, not a field that fails to parse.
  @spec v3_value(binary()) :: {:ok, term(), binary()} | :fail | {:error, binary()}
  defp v3_value(<<?", text::binary>>) do
    case quote_end(text) do
      :none ->
        :fail

      pos ->
        <<inner::binary-size(pos), ?", rest::binary>> = text
        {:ok, unescape_string_field(inner), rest}
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
    sign = sign_size(text)
    <<_sign::binary-size(sign), unsigned::binary>> = text

    case digit_count(unsigned, 0) do
      0 ->
        :fail

      digits ->
        int_end = sign + digits
        <<whole::binary-size(int_end), tail::binary>> = text
        v3_number_tail(whole, tail, text, sign == 0)
    end
  end

  # `whole` is the sign and digits, `tail` what follows them and `text` all
  # of it; `unsigned?` is whether there is no sign.
  @spec v3_number_tail(binary(), binary(), binary(), boolean()) ::
          {:ok, term(), binary()} | :fail | {:error, binary()}
  defp v3_number_tail(whole, <<?i, rest::binary>>, _text, _unsigned?),
    do: integer_value(whole, rest, "integer", @int64_min, @int64_max, & &1)

  defp v3_number_tail(whole, <<?u, rest::binary>>, _text, true),
    do: integer_value(whole, rest, "unsigned integer", 0, @uint64_max, &{:uint, &1})

  defp v3_number_tail(whole, tail, text, _unsigned?), do: v3_float(whole, tail, text)

  @spec integer_value(binary(), binary(), binary(), integer(), integer(), fun()) ::
          {:ok, term(), binary()} | {:error, binary()}
  defp integer_value(digits, rest, what, min, max, wrap) do
    case :erlang.binary_to_integer(digits) do
      n when n >= min and n <= max -> {:ok, wrap.(n), rest}
      _out_of_range -> {:error, "Unable to parse #{what} value `#{digits}`"}
    end
  end

  # The fraction needs a digit after its point and the exponent a digit
  # after its sign, or they are left as trailing content.
  @spec v3_float(binary(), binary(), binary()) :: {:ok, float(), binary()} | {:error, binary()}
  defp v3_float(whole, tail, text) do
    fraction = fraction_size(tail)
    <<_fraction::binary-size(fraction), after_fraction::binary>> = tail
    exponent = exponent_size(after_fraction)
    size = byte_size(whole) + fraction + exponent
    <<number::binary-size(size), rest::binary>> = text

    case float_value(number, fraction, exponent) do
      {:ok, float} ->
        {:ok, float, rest}

      :error ->
        {:error,
         "Client.Local: the float #{number} is infinity on InfluxDB 3 Core, " <>
           "which the double cannot hold"}
    end
  end

  # The size of `.digits` at the start of `text`, 0 when there is none.
  @spec fraction_size(binary()) :: non_neg_integer()
  defp fraction_size(<<?., rest::binary>>) do
    case digit_count(rest, 0) do
      0 -> 0
      digits -> digits + 1
    end
  end

  defp fraction_size(_text), do: 0

  # The size of `e[+-]digits` at the start of `text`, 0 when there is none.
  @spec exponent_size(binary()) :: non_neg_integer()
  defp exponent_size(<<e, rest::binary>>) when e in [?e, ?E] do
    {signed, digits_from} =
      case rest do
        <<s, more::binary>> when s in [?+, ?-] -> {1, more}
        _unsigned -> {0, rest}
      end

    case digit_count(digits_from, 0) do
      0 -> 0
      digits -> 1 + signed + digits
    end
  end

  defp exponent_size(_text), do: 0

  # The float a number's text means. With a fraction Erlang reads it as it
  # is; an integer-valued one is converted; only an exponent without a
  # fraction needs `parse_float/1`. `:error` when it does not fit a float.
  @spec float_value(binary(), non_neg_integer(), non_neg_integer()) :: {:ok, float()} | :error
  defp float_value(number, fraction, exponent) do
    cond do
      fraction > 0 -> {:ok, :erlang.binary_to_float(number)}
      exponent > 0 -> parse_float(number)
      true -> {:ok, integer_float(number)}
    end
  rescue
    ArgumentError -> :error
  end

  # `-0` is the float -0.0, and a number of more digits than a float holds
  # raises `ArgumentError`.
  @spec integer_float(binary()) :: float()
  defp integer_float("-" <> digits = number) do
    case :erlang.binary_to_integer(digits) do
      0 -> -0.0
      _nonzero -> :erlang.float(:erlang.binary_to_integer(number))
    end
  end

  defp integer_float(digits), do: :erlang.float(:erlang.binary_to_integer(digits))

  # The size of the minus sign at the start of `text`: 1 or 0.
  @spec sign_size(binary()) :: 0 | 1
  defp sign_size(<<?-, _rest::binary>>), do: 1
  defp sign_size(_text), do: 0

  # The number of ASCII digits at the start of `text`.
  @spec digit_count(binary(), non_neg_integer()) :: non_neg_integer()
  defp digit_count(<<c, rest::binary>>, count) when c in ?0..?9, do: digit_count(rest, count + 1)
  defp digit_count(_text, count), do: count

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
    sign = sign_size(text)
    <<_sign::binary-size(sign), unsigned::binary>> = text

    case digit_count(unsigned, 0) do
      0 ->
        {"", text}

      digits ->
        <<integer::binary-size(sign + digits), after_integer::binary>> = text
        {integer, after_integer}
    end
  end

  @spec skip_spaces(binary()) :: binary()
  defp skip_spaces(<<?\s, rest::binary>>), do: skip_spaces(rest)
  defp skip_spaces(text), do: text

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
  defp key_end(text), do: key_end(text, 0)

  defp key_end(<<?\\, _escaped, rest::binary>>, pos), do: key_end(rest, pos + 2)
  defp key_end(<<c, _rest::binary>>, pos) when c in [?=, ?\s, ?\t], do: pos
  defp key_end(<<_c, rest::binary>>, pos), do: key_end(rest, pos + 1)
  defp key_end(<<>>, _pos), do: :none

  @spec quote_end(binary()) :: non_neg_integer() | :none
  defp quote_end(text), do: quote_end(text, 0)

  defp quote_end(<<?\\, _escaped, rest::binary>>, pos), do: quote_end(rest, pos + 2)
  defp quote_end(<<?", _rest::binary>>, pos), do: pos
  defp quote_end(<<_c, rest::binary>>, pos), do: quote_end(rest, pos + 1)
  defp quote_end(<<>>, _pos), do: :none

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

  @doc """
  Builds a `t:line_error/0` the way InfluxDB 3 reports one. The full line
  is kept under `:line` for InfluxDB 2's report, which quotes it whole.
  """
  @spec line_error(binary(), pos_integer(), binary()) :: line_error()
  def line_error(message, number, line) do
    %{error_message: message, line_number: number, original_line: echo(line), line: line}
  end

  # What InfluxDB 3 echoes of a line: without the `\r` of a CRLF ending (one
  # inside the line stays, verified), cut to 20 characters.
  @spec echo(binary()) :: binary()
  defp echo(line), do: line |> String.replace_suffix("\r", "") |> cut()

  @spec cut(binary()) :: binary()
  defp cut(line), do: String.slice(line, 0, 20)

  @doc """
  Builds the `t:line_error/0` for a schema error. InfluxDB 3 does not echo
  the raw line for those but the line as it parsed it (verified): single
  spaces, floats printed shortest and without an exponent (`2.0` → `2`,
  `1e3` → `1000`), strings unquoted, then cut to 20 characters. Parse
  errors echo the physical line (`parse_lines/3`).
  """
  @spec schema_error(binary(), pos_integer(), binary()) :: line_error()
  def schema_error(message, number, line) do
    %{line_error(message, number, line) | original_line: line |> render_line() |> echo()}
  end

  # The engine's rendering of a line that parsed: the series, the fields and
  # the timestamp, joined by single spaces. A name is written as it was, with
  # an `=` or `,` it held unescaped escaped, a string as its raw text and a
  # number as it parsed prints. The line is read by the grammar that
  # accepted it.
  @spec render_line(binary()) :: binary()
  defp render_line(line) do
    trimmed = trim_leading_blanks(line)

    with {:ok, measurement, tags, after_series} <- v3_series(trimmed),
         fields_text = skip_spaces(after_series),
         {:ok, _fields, rest} <- v3_fields(fields_text),
         {:ok, timestamp} <- v3_timestamp(rest) do
      consumed = binary_part(fields_text, 0, byte_size(fields_text) - byte_size(rest))

      series =
        measurement <>
          Enum.map_join(tags, fn {key, value} ->
            "," <> escape_raw(key, ?,) <> "=" <> escape_raw(value, ?=)
          end)

      Enum.join([series, render_fields(consumed, []) | List.wrap(timestamp)], " ")
    else
      _unparsed -> line
    end
  end

  # The fields of text the grammar has accepted, as `key=value` joined by commas.
  @spec render_fields(binary(), [binary()]) :: binary()
  defp render_fields("", shown), do: shown |> Enum.reverse() |> Enum.join(",")

  defp render_fields(text, shown) do
    key_size = key_end(text)
    <<key::binary-size(key_size), ?=, value::binary>> = text
    {rendered, rest} = render_field_value(value)
    entry = escape_raw(key, ?,) <> "=" <> rendered

    case rest do
      <<?,, next::binary>> -> render_fields(next, [entry | shown])
      _end -> render_fields("", [entry | shown])
    end
  end

  @spec render_field_value(binary()) :: {binary(), binary()}
  defp render_field_value(<<?", text::binary>>) do
    raw_size = quote_end(text)
    <<raw::binary-size(raw_size), ?", rest::binary>> = text
    {raw, rest}
  end

  defp render_field_value(text) do
    {:ok, value, rest} = v3_value(text)
    {render_value(value), rest}
  end

  # `name` with each `char` that no backslash escapes escaped.
  @spec escape_raw(binary(), byte()) :: binary()
  defp escape_raw(name, char), do: escape_raw(name, char, <<>>)

  defp escape_raw(<<?\\, c, rest::binary>>, char, acc),
    do: escape_raw(rest, char, <<acc::binary, ?\\, c>>)

  defp escape_raw(<<char, rest::binary>>, char, acc),
    do: escape_raw(rest, char, <<acc::binary, ?\\, char>>)

  defp escape_raw(<<c, rest::binary>>, char, acc), do: escape_raw(rest, char, <<acc::binary, c>>)
  defp escape_raw(<<>>, _char, acc), do: acc

  @spec render_value(term()) :: binary()
  defp render_value({:uint, n}), do: "#{n}u"
  defp render_value(n) when is_integer(n), do: "#{n}i"
  # Rust's `f64` Display, which the planner's literals share.
  defp render_value(f) when is_float(f), do: Format.render_decimal(f)
  defp render_value(value), do: to_string(value)

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
      key = unescape_tag(raw_key)

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

  # A string field's inner text with `\"` and `\\` undone, left to right.
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

  # Parses a raw timestamp (`-?digits`, as both grammars have checked it),
  # normalising to nanoseconds.
  @spec parse_timestamp(binary() | nil, precision(), dialect()) ::
          {:ok, integer() | nil} | {:error, binary()}
  defp parse_timestamp(nil, _prec, _dialect), do: {:ok, nil}
  defp parse_timestamp("", _prec, _dialect), do: {:ok, nil}

  # The stored time is nanoseconds in a signed 64-bit integer. A timestamp
  # that does not fit once scaled to nanoseconds is refused, in each
  # version's words (verified): InfluxDB 3 takes the whole int64 range,
  # InfluxDB 2 all but its two ends.
  defp parse_timestamp(ts_str, precision, dialect) do
    ts = :erlang.binary_to_integer(ts_str)

    if ts in @int64_min..@int64_max do
      ns = to_nanoseconds(ts, precision)

      if in_range?(ns, dialect),
        do: {:ok, ns},
        else: {:error, out_of_range(ts, precision, dialect)}
    else
      {:error, int64_overflow(ts_str, dialect)}
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

  # ---------------------------------------------------------------------------
  # Unescaping
  #
  # Both engines read a name left to right and undo an escape only where a
  # backslash precedes one of its characters; the sets differ (verified):
  #
  #   * InfluxDB 3 undoes `\\` as well, in every name; a measurement also
  #     takes `\,` and `\ `, any other name `\,`, `\ ` and `\=`; `\"` is
  #     never undone
  #   * InfluxDB 2 never undoes `\\` (a backslash is kept unless it precedes
  #     a code): a tag takes `\,`, `\ ` and `\=`, a field key and a
  #     measurement those and `\"`
  # ---------------------------------------------------------------------------

  @doc "Undoes line-protocol escaping in a measurement name (`\\ `, `\\,`, `\\\\`)."
  @spec unescape_measurement(binary()) :: binary()
  def unescape_measurement(str) do
    if :binary.match(str, "\\") == :nomatch,
      do: str,
      else: unescape_v3(str, [?\s, ?,], <<>>)
  end

  # A tag key or value, or a field key, of InfluxDB 3.
  @spec unescape_tag(binary()) :: binary()
  defp unescape_tag(str) do
    if :binary.match(str, "\\") == :nomatch,
      do: str,
      else: unescape_v3(str, [?\s, ?,, ?=], <<>>)
  end

  @spec unescape_v3(binary(), [byte()], binary()) :: binary()
  defp unescape_v3(<<>>, _codes, acc), do: acc

  defp unescape_v3(<<?\\, c, rest::binary>>, codes, acc) do
    if c == ?\\ or c in codes,
      do: unescape_v3(rest, codes, <<acc::binary, c>>),
      else: unescape_v3(rest, codes, <<acc::binary, ?\\, c>>)
  end

  defp unescape_v3(<<c, rest::binary>>, codes, acc),
    do: unescape_v3(rest, codes, <<acc::binary, c>>)

  # InfluxDB 2: `codes` are the characters a backslash may precede.
  @spec unescape_v2(binary(), [byte()]) :: binary()
  defp unescape_v2(str, codes) do
    if :binary.match(str, "\\") == :nomatch, do: str, else: unescape_v2(str, codes, <<>>)
  end

  defp unescape_v2(<<>>, _codes, acc), do: acc

  defp unescape_v2(<<?\\, c, rest::binary>>, codes, acc) do
    if c in codes,
      do: unescape_v2(rest, codes, <<acc::binary, c>>),
      else: unescape_v2(<<c, rest::binary>>, codes, <<acc::binary, ?\\>>)
  end

  defp unescape_v2(<<c, rest::binary>>, codes, acc),
    do: unescape_v2(rest, codes, <<acc::binary, c>>)

  @spec v2_tag_name(binary()) :: binary()
  defp v2_tag_name(str), do: unescape_v2(str, [?\s, ?,, ?=])

  @spec v2_name(binary()) :: binary()
  defp v2_name(str), do: unescape_v2(str, [?\s, ?,, ?=, ?"])
end
