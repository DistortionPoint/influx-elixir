defmodule InfluxElixir.Client.Local.LineProtocolScanner do
  @moduledoc """
  Finds the lines of a line-protocol payload and runs each through the grammar
  of its dialect, as both engines find them (see
  `InfluxElixir.Client.Local.LineProtocolParser.parse_lines/3`): the end of a
  line, blank lines and comments, the numbering that counts, and the error each
  failing line is reported with.
  """

  alias InfluxElixir.Client.Local.{
    LineProtocolError,
    LineProtocolParser,
    LineProtocolV2,
    LineProtocolV3
  }

  @typep dialect :: LineProtocolParser.dialect()
  @typep line_result :: LineProtocolParser.line_result()
  @typep line_error :: LineProtocolParser.line_error()
  @typep point :: LineProtocolParser.point()

  # InfluxDB 2 reads a final newline as the end of the buffer, not as part of
  # a line a stray quote has left open (verified: such a line is quoted
  # without it); InfluxDB 3 keeps it.
  @spec final_newline_off(binary(), dialect()) :: binary()
  @doc false
  def final_newline_off(text, :v2) do
    size = byte_size(text) - 1

    case text do
      <<text::binary-size(size), ?\n>> -> text
      _no_final_newline -> text
    end
  end

  def final_newline_off(text, :v3), do: text

  # The results of every line that counts, in order. A payload's results
  # are as large as the payload, and a process heap that grows by a fraction
  # at a time copies everything built so far at each step, so parsing a large
  # payload in the caller is dominated by that copying. Instead the lines are
  # parsed a chunk at a time, each full chunk in a short-lived process whose
  # heap starts large enough to hold the chunk's results without a
  # collection, and whose result is sent back once. The caller's own heap and
  # flags are never touched, only one chunk runs beside it, and a chunk ends
  # on its own, so it cannot outlive a dead caller by more than its own parse.
  @chunk_lines 10_000
  @chunk_heap_words 1_000_000

  @spec parse_all([binary()], binary(), map()) :: [line_result()]
  @doc false
  def parse_all(lines, text, context) do
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
    error = LineProtocolError.line_error(message, number, shown)

    cond do
      number < tuple_size(physical) ->
        %{error | original_line: LineProtocolError.echo(elem(physical, number - 1))}

      # The last physical line has no newline to take a `\r` with it.
      number == tuple_size(physical) ->
        %{error | original_line: LineProtocolError.cut(elem(physical, number - 1))}

      true ->
        error
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
  @doc false
  def split_lines(text) do
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
    case line |> trim_leading_blanks() |> LineProtocolV3.parse(precision) do
      {:ok, point} -> {:ok, point, line}
      {:error, message} -> {:error, message, line}
    end
  end

  # InfluxDB 2 quotes the line after its leading whitespace in the error.
  defp parse_line(line, %{dialect: :v2, precision: precision}) do
    trimmed = skip_blanks(line, :v2)

    case LineProtocolV2.parse(trimmed, precision) do
      {:ok, point} -> {:ok, point, trimmed}
      {:error, message} -> {:error, message, trimmed}
    end
  end

  # Leading spaces and tabs, by byte.
  @spec trim_leading_blanks(binary()) :: binary()
  @doc false
  def trim_leading_blanks(<<c, rest::binary>>) when c in [?\s, ?\t],
    do: trim_leading_blanks(rest)

  def trim_leading_blanks(line), do: line
end
