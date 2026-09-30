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
        blank?(line) or String.starts_with?(line, "#")
      end)
      |> Enum.map(fn {line, n} -> parse_line(line, n, precision, dialect) end)

    case results do
      [] -> {:error, %{status: 400, body: "incoming write was empty"}}
      results -> {:ok, results}
    end
  end

  # A line of only spaces and tabs: nothing else is blank to InfluxDB 3 (a
  # line of `\r`, `\v`, `\f` or a no-break space is its "Expected at least
  # one space character", verified). It stops at the first other byte.
  @spec blank?(binary()) :: boolean()
  defp blank?(<<c, rest::binary>>) when c in [?\s, ?\t], do: blank?(rest)
  defp blank?(<<>>), do: true
  defp blank?(_line), do: false

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
  # Parses a single line protocol line into a point map.
  #
  # Format: measurement[,tag=val...] field=val[,...] [timestamp]
  @spec parse_line(binary(), pos_integer(), precision(), dialect()) :: line_result()
  defp parse_line(line, number, precision, dialect) do
    case terminator_error(line, dialect) do
      nil -> parse_line_parts(line, number, precision, dialect)
      message -> {:error, line_error(message, number, line)}
    end
  end

  @spec parse_line_parts(binary(), pos_integer(), precision(), dialect()) :: line_result()
  defp parse_line_parts(line, number, precision, dialect) do
    # Runs of spaces between sections are one separator on the engine
    # (verified), so empty sections are dropped; so is leading whitespace,
    # a tab included.
    result =
      case line
           |> leading_whitespace_trimmed(dialect)
           |> split_line_parts()
           |> Enum.reject(&(&1 == "")) do
        [key_part, fields_part | rest] ->
          ts_raw = List.first(rest)

          with {:ok, {measurement, tags}} <- parse_key_part(key_part, dialect),
               {:ok, fields} <- parse_fields_part(v2_quote_cr(fields_part, dialect)),
               {:ok, fields} <- check_columns(tags, fields, dialect),
               {:ok, timestamp} <- parse_timestamp(ts_raw, precision, dialect) do
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

  # InfluxDB 2 accepts a string field that a `\r` follows (a CRLF ending,
  # or `s="x"\r 5`) and stores it from after the opening quote up to the
  # `\r`, closing quote included: `"x"\r` is `x"`, `""\r` is `"` (verified).
  # A number followed by `\r` is refused. Rewriting the `"\r` as an escaped
  # quote and a closing one gives that value to the string parser.
  @spec v2_quote_cr(binary(), dialect()) :: binary()
  defp v2_quote_cr(fields_part, :v2), do: String.replace_suffix(fields_part, "\"\r", "\\\"\"")
  defp v2_quote_cr(fields_part, :v3), do: fields_part

  @spec leading_whitespace_trimmed(binary(), dialect()) :: binary()
  defp leading_whitespace_trimmed(line, :v3), do: trim_leading_blanks(line)
  defp leading_whitespace_trimmed(line, :v2), do: line

  # Leading spaces and tabs, by byte: a regex here ran on every line of
  # every write.
  @spec trim_leading_blanks(binary()) :: binary()
  defp trim_leading_blanks(<<c, rest::binary>>) when c in [?\s, ?\t],
    do: trim_leading_blanks(rest)

  defp trim_leading_blanks(line), do: line

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
      else: line |> leading_whitespace_trimmed(:v3) |> scan_terminators(:measurement, %{})
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

  defp terminator_message(:tag_key_start, at, _ctx), do: "Expected tag key, got `#{at}`"
  defp terminator_message(:tag_value_start, at, _ctx), do: "Expected tag value, got `#{at}`"

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
  defp trailing(content), do: "Could not parse entire line. Found trailing content: `#{content}`"

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

  # Parses the "measurement[,tag=val...]" part.
  # InfluxDB 3 refuses a name that ends in a backslash (an escaped one
  # before a separator, `m\\,t=a`), verified. InfluxDB 2 reads `\\,` in a
  # measurement as an escaped comma and keeps it in the name, also
  # verified, so only the v3 dialect takes `\\` whole there.
  @trailing_backslash "Measurements, tag keys and values, and field keys may not end with a backslash"

  @spec parse_key_part(binary(), dialect()) :: {:ok, {binary(), map()}} | {:error, binary()}
  defp parse_key_part(key_part, dialect) do
    {measurement_raw, tags_raw} = split_first_unescaped_comma(key_part, dialect)

    cond do
      dialect == :v3 and ends_in_backslash?(measurement_raw) ->
        {:error, @trailing_backslash}

      tags_raw == "" ->
        {:ok, {unescape_measurement(measurement_raw), %{}}}

      true ->
        with {:ok, tags} <- parse_tags(tags_raw) do
          {:ok, {unescape_measurement(measurement_raw), tags}}
        end
    end
  end

  # A raw name whose last byte is a backslash: `\\` at the end, since a
  # single one would have escaped the separator.
  @spec ends_in_backslash?(binary()) :: boolean()
  defp ends_in_backslash?(""), do: false
  defp ends_in_backslash?(raw), do: :binary.last(raw) == ?\\

  # Splits at the first unescaped comma.
  @spec split_first_unescaped_comma(binary(), dialect()) :: {binary(), binary()}
  defp split_first_unescaped_comma(str, dialect) do
    if plain?(str, "\\") do
      case :binary.split(str, ",") do
        [head, rest] -> {head, rest}
        [head] -> {head, ""}
      end
    else
      do_split_comma(str, <<>>, dialect == :v3)
    end
  end

  defp do_split_comma(<<>>, acc, _whole_backslash), do: {acc, ""}

  defp do_split_comma(<<"\\\\", rest::binary>>, acc, true),
    do: do_split_comma(rest, <<acc::binary, "\\\\">>, true)

  defp do_split_comma(<<"\\,", rest::binary>>, acc, whole) do
    do_split_comma(rest, <<acc::binary, "\\,">>, whole)
  end

  defp do_split_comma(<<",", rest::binary>>, acc, _whole), do: {acc, rest}

  defp do_split_comma(<<c, rest::binary>>, acc, whole) do
    do_split_comma(rest, <<acc::binary, c>>, whole)
  end

  # Parses "tag1=v1,tag2=v2,..." into a map.
  @spec parse_tags(binary()) :: {:ok, map()} | {:error, binary()}
  defp parse_tags(tags_str) do
    pairs = split_unescaped_comma(tags_str)

    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      case split_first_unescaped_equals(pair) do
        {"", _v} ->
          {:halt, {:error, "Expected tag key, got `#{pair}`"}}

        {_k, ""} ->
          {:halt, {:error, "Expected tag value, got `#{pair}`"}}

        {k, v} ->
          if ends_in_backslash?(k) or ends_in_backslash?(v),
            do: {:halt, {:error, @trailing_backslash}},
            else: {:cont, {:ok, Map.put(acc, unescape_tag(k), unescape_tag(v))}}
      end
    end)
  end

  # Parses the "field=val[,...]" section.
  @spec parse_fields_part(binary()) :: {:ok, map()} | {:error, binary()}
  defp parse_fields_part(fields_str) do
    pairs = split_unescaped_comma(fields_str)

    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      case split_first_unescaped_equals(pair) do
        {k, _v} when k != "" and binary_part(k, byte_size(k) - 1, 1) == "\\" ->
          {:halt, {:error, @trailing_backslash}}

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

  # Parses a field value string into its typed Elixir equivalent. An
  # unsigned integer (`7u`) is stored as the integer; its kind is remembered
  # for the schema check only.
  @spec parse_field_value(binary()) :: {:ok, term()} | {:error, binary()}
  defp parse_field_value(str) do
    cond do
      String.ends_with?(str, "i") ->
        parse_integer(drop_last_byte(str), @int64_min, @int64_max)

      String.ends_with?(str, "u") ->
        with {:ok, n} <- parse_integer(drop_last_byte(str), 0, @uint64_max),
             do: {:ok, {:uint, n}}

      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        {:ok, unquote_string(binary_part(str, 1, byte_size(str) - 2))}

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

  # The suffix (`i`, `u`) is one ASCII byte; a byte slice avoids
  # String.slice's grapheme walk (4 ns against 540 ns).
  @spec drop_last_byte(binary()) :: binary()
  defp drop_last_byte(str), do: binary_part(str, 0, byte_size(str) - 1)

  @spec unquote_string(binary()) :: binary()
  defp unquote_string(inner) do
    if :binary.match(inner, "\\") == :nomatch,
      do: inner,
      else: inner |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")
  end

  @spec parse_integer(binary(), integer(), integer()) :: {:ok, integer()} | {:error, binary()}
  defp parse_integer(digits, min, max) do
    case Integer.parse(digits) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      _out_of_range -> {:error, "Unable to parse integer value `#{digits}`"}
    end
  end

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
