defmodule InfluxElixir.Client.Local.InfluxQLGroup do
  @moduledoc false
  # The `GROUP BY` clause of an InfluxQL `SELECT` and the `fill()` after it, read
  # the way the engine's parser reads them (verified), with its errors at its
  # positions:
  #
  #   * a dimension is `time(every[, offset])`, `*` or `*::tag` / `*::field`
  #     (every tag of the measurement; the cast changes nothing), `/regex/` (the
  #     tags whose key matches, unanchored and case-sensitive), or a name, bare or
  #     double-quoted, with an optional `::type` (a cast changes nothing). A name
  #     that is a field groups by its values
  #   * only the first `time()` counts; a later one is read and ignored
  #   * a dimension that cannot be read ends the list at the comma before it
  #     (the statement is then left over from there); a first one that cannot
  #     is "invalid GROUP BY clause"
  #   * `every` and `offset` are durations (`1m`, `1h30m`), `offset` with an
  #     optional sign, `every` too; what a bucket of that size would need is
  #     decided when there are points to put in it (`InfluxQLBuckets`)
  #   * `fill(...)` follows the dimensions: `null`, `none`, `previous`, `linear`
  #     (any case) or a number (`1`, `-2`, `1.5`, `.5`, signed), blanks allowed
  #     inside; an option that is none of them is "invalid FILL option" where
  #     it starts, one that is read but not closed by `)` leaves the statement
  #     from `fill`
  #   * after the clause only `ORDER BY`, `LIMIT`, `OFFSET`, `SLIMIT`,
  #     `SOFFSET` or `tz(` may follow; anything else is left over
  #
  # What the double does not read is refused by name: a name that is `time`, a
  # dotted name, an integer for `every`, an offset that is not a duration.

  alias InfluxElixir.Client.Local.{
    Durations,
    InfluxQLBuckets,
    InfluxQLError,
    InfluxQLText,
    InfluxQLTime,
    SQLLimits
  }

  require SQLLimits

  @typedoc "A dimension that is not `time()`."
  @type dimension :: {:tag, binary()} | :wildcard | {:regex, binary()}

  @typedoc "A parsed `GROUP BY`; `fill` is `nil` when the statement has none."
  @type t :: %{
          required(:dimensions) => [dimension()],
          required(:time) => nil | {integer(), integer()},
          required(:fill) => InfluxQLBuckets.fill() | nil,
          optional(:rewrite_error) => binary() | nil
        }

  @types ~w(float integer unsigned string boolean field tag)
  @after_clause ~r/^(?:ORDER|LIMIT|OFFSET|SLIMIT|SOFFSET)(?![\w])|^tz\s*\(/i

  @doc """
  Reads the `GROUP BY` clause (and the `fill()` after it) of `masked_rest`, the
  text after `FROM <measurement>` with its literals masked; `whole` is the
  statement as sent and `at` where `masked_rest` starts in it.

  Returns `{result, masked_rest, rest}`: `result` is `:none` when the text has no
  `GROUP BY` in the place of one (the other checks read the text as it is),
  `{:ok, t()}`, or the error; the text comes back, masked and as sent, with the clause blanked
  to spaces, byte for byte, so that every position stays the engine's.
  """
  @spec extract(binary(), non_neg_integer(), binary()) ::
          {:none | {:ok, t()} | {:error, term()}, binary(), binary()}
  def extract(whole, at, masked_rest) do
    with [{from, length}] <- Regex.run(~r/\bGROUP\s+BY(?![\w])/i, masked_rest, return: :index),
         true <- plain_before?(binary_part(masked_rest, 0, from)),
         text = binary_part(whole, at, byte_size(masked_rest)),
         start = from + length,
         false <- blank?(text, start) do
      case clause(text, start, at, whole) do
        {:ok, group, stop} ->
          {{:ok, group}, blank(masked_rest, from, stop), blank(text, from, stop)}

        {:error, _error} = error ->
          size = byte_size(masked_rest)
          {error, blank(masked_rest, from, size), blank(text, from, size)}
      end
    else
      _not_a_clause -> {:none, masked_rest, binary_part(whole, at, byte_size(masked_rest))}
    end
  end

  # What stands before `GROUP BY`: nothing, or a `WHERE` the keyword cannot be
  # part of (an operator or connective before it wants an operand, which a
  # reserved word is not).
  @spec plain_before?(binary()) :: boolean()
  defp plain_before?(before) do
    cond do
      before =~ ~r/^\s*$/ -> true
      before =~ ~r/\b(?:ORDER|S?LIMIT|S?OFFSET)\b/i -> false
      # A `fill()` before it ends the clauses `GROUP BY` may follow: what comes after is left
      # over (see `InfluxQLCheck.cut_where/2`).
      before =~ ~r/(?<![\w])fill\s*\(/i -> false
      before =~ ~r/(?:[-+*=<>(,~!]|(?<![_\/])\/|\b(?:AND|OR))\s*$/i -> false
      true -> before =~ ~r/^\s*WHERE\s+\S/i
    end
  end

  @spec blank?(binary(), non_neg_integer()) :: boolean()
  defp blank?(text, start),
    do: text |> binary_part(start, byte_size(text) - start) |> String.trim() == ""

  @spec blank(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  defp blank(masked_rest, from, stop) do
    <<before::binary-size(from), _clause::binary-size(stop - from), rest::binary>> = masked_rest
    before <> String.duplicate(" ", stop - from) <> rest
  end

  # ---------------------------------------------------------------------------
  # Dimensions
  # ---------------------------------------------------------------------------

  @spec clause(binary(), non_neg_integer(), non_neg_integer(), binary()) ::
          {:ok, t(), non_neg_integer()} | {:error, term()}
  defp clause(text, start, at, whole) do
    ctx = %{text: text, at: at, whole: whole}

    with {:ok, dimensions, stop} <- dimensions(ctx, skip(text, start), [], 0) do
      case fill(ctx, stop) do
        {:ok, fill, stop} -> leftover(ctx, stop, dimensions, fill)
        {:bad_option, pos} -> {:error, {:engine, error(ctx, :fill, pos)}}
      end
    end
  end

  # The dimensions, then where the list ends. `first` is the position of the
  # first dimension; a later one that cannot be read ends the list before its
  # comma.
  defp dimensions(ctx, pos, acc, count) do
    case dimension(ctx, pos) do
      {:ok, dimension, stop} ->
        after_blank = skip(ctx.text, stop)

        if byte_at(ctx.text, after_blank) == ?, do
          dimensions(ctx, skip(ctx.text, after_blank + 1), [dimension | acc], count + 1)
          |> backtrack(ctx, after_blank, [dimension | acc], stop)
        else
          {:ok, Enum.reverse([dimension | acc]), stop}
        end

      :none when count == 0 ->
        {:error, {:engine, error(ctx, :group, pos)}}

      :none ->
        :none

      {:error, _error} = error ->
        error
    end
  end

  # A dimension after a comma that could not be read ends the list before the
  # comma: the comma is the first thing left over.
  defp backtrack(:none, _ctx, _comma, acc, stop), do: {:ok, Enum.reverse(acc), stop}
  defp backtrack(result, _ctx, _comma, _acc, _stop), do: result

  @spec dimension(map(), non_neg_integer()) ::
          {:ok, term(), non_neg_integer()} | :none | {:error, term()}
  defp dimension(%{text: text} = ctx, pos) do
    rest = binary_part(text, pos, byte_size(text) - pos)

    cond do
      rest == "" -> :none
      String.starts_with?(rest, "*") -> wildcard(ctx, pos)
      String.starts_with?(rest, "/") -> regex(ctx, pos)
      String.starts_with?(rest, "\"") -> quoted(ctx, pos)
      rest =~ ~r/^time(?![\w])/i and not (rest =~ ~r/^time\s*::/i) -> time_call(ctx, pos)
      true -> bare(ctx, pos, rest)
    end
  end

  defp wildcard(ctx, pos) do
    after_star = pos + 1

    case cast(ctx, after_star, ~w(tag field), :wildcard_type) do
      {:ok, stop} -> {:ok, :wildcard, stop}
      other -> other
    end
  end

  defp regex(ctx, pos) do
    rest = binary_part(ctx.text, pos + 1, byte_size(ctx.text) - pos - 1)

    case close_regex(rest, 0) do
      {:ok, size} ->
        pattern = rest |> binary_part(0, size) |> String.replace("\\/", "/")
        {:ok, {:regex, pattern}, pos + 1 + size + 1}

      :unterminated ->
        {:error, {:engine, error(ctx, :unterminated_regex, byte_size(ctx.whole) - ctx.at)}}
    end
  end

  defp close_regex(<<?\\, ?/, rest::binary>>, size), do: close_regex(rest, size + 2)
  defp close_regex(<<?/, _rest::binary>>, size), do: {:ok, size}
  defp close_regex(<<_byte, rest::binary>>, size), do: close_regex(rest, size + 1)
  defp close_regex(<<>>, _size), do: :unterminated

  defp quoted(ctx, pos) do
    rest = binary_part(ctx.text, pos, byte_size(ctx.text) - pos)

    case Regex.run(~r/^"(?:[^"\\]|\\.)*"/s, rest) do
      [quoted] ->
        name = InfluxQLText.unquote_ident(quoted)
        named(ctx, name, pos + byte_size(quoted))

      nil ->
        {:error, {:engine, error(ctx, :unterminated_string, byte_size(ctx.whole) - ctx.at)}}
    end
  end

  defp bare(ctx, pos, rest) do
    case Regex.run(~r/^[A-Za-z_][A-Za-z0-9_]*/, rest) do
      [word] ->
        if InfluxQLText.reserved_start(rest) != nil,
          do: :none,
          else: dotted_or_named(ctx, word, pos + byte_size(word))

      nil ->
        :none
    end
  end

  defp dotted_or_named(ctx, word, stop) do
    if byte_at(ctx.text, stop) == ?.,
      do: {:error, "unsupported InfluxQL (GROUP BY a dotted name)"},
      else: named(ctx, word, stop)
  end

  defp named(ctx, name, stop) do
    with {:ok, stop} <- cast(ctx, stop, @types, :data_type), do: {:ok, {:tag, name}, stop}
  end

  # An optional `::type` right after a name; a type word must be followed by
  # something that cannot continue it.
  @spec cast(map(), non_neg_integer(), [binary()], atom()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp cast(ctx, pos, types, kind) do
    if binary_part(ctx.text, pos, min(2, byte_size(ctx.text) - pos)) == "::" do
      rest = binary_part(ctx.text, pos + 2, byte_size(ctx.text) - pos - 2)
      alternatives = Enum.join(types, "|")

      case Regex.run(~r/^(?:#{alternatives})(?![\w:])/i, rest) do
        [word] -> {:ok, pos + 2 + byte_size(word)}
        nil -> {:error, {:engine, error(ctx, kind, pos + 2)}}
      end
    else
      {:ok, pos}
    end
  end

  # ---------------------------------------------------------------------------
  # time(every[, offset])
  # ---------------------------------------------------------------------------

  defp time_call(ctx, pos) do
    after_word = pos + 4
    open = skip(ctx.text, after_word)

    if byte_at(ctx.text, open) == ?(,
      do: interval(ctx, open + 1),
      else: {:error, {:engine, error(ctx, :time_call, after_word)}}
  end

  defp interval(ctx, pos) do
    case duration(ctx.text, skip(ctx.text, pos)) do
      {:ok, every, stop} ->
        after_interval(ctx, every, stop)

      {:integer, stop} ->
        integer_interval(ctx, stop)

      :big ->
        {:error, "unsupported InfluxQL (a duration beyond 64 bits)"}

      :none ->
        {:error, {:engine, error(ctx, :time_interval, pos)}}
    end
  end

  # An integer for the interval reads, and then fails planning there: refused
  # by name when the call is otherwise whole, its parse error when it is not.
  defp integer_interval(ctx, stop) do
    case after_interval(ctx, 0, stop) do
      {:ok, _time, _stop} ->
        {:error, "unsupported InfluxQL (GROUP BY time() with an integer interval)"}

      error ->
        error
    end
  end

  defp after_interval(ctx, every, stop) do
    comma = skip(ctx.text, stop)

    case byte_at(ctx.text, comma) do
      ?, -> offset(ctx, every, stop, skip(ctx.text, comma + 1))
      ?) -> {:ok, {:time, {every, 0}}, comma + 1}
      _other -> {:error, {:engine, error(ctx, :time_close, stop)}}
    end
  end

  defp offset(ctx, every, interval_stop, pos) do
    case duration(ctx.text, pos) do
      {:ok, offset, stop} ->
        close = skip(ctx.text, stop)

        if byte_at(ctx.text, close) == ?),
          do: {:ok, {:time, {every, offset}}, close + 1},
          else: {:error, {:engine, error(ctx, :time_close, stop)}}

      :big ->
        {:error, "unsupported InfluxQL (a duration beyond 64 bits)"}

      :none when pos < byte_size(ctx.text) ->
        refuse_offset(ctx, every, interval_stop, pos)

      _other ->
        {:error, {:engine, error(ctx, :time_close, interval_stop)}}
    end
  end

  defp refuse_offset(ctx, every, interval_stop, pos) do
    rest = binary_part(ctx.text, pos, byte_size(ctx.text) - pos)

    cond do
      rest =~ ~r/^now\s*\(/i ->
        {:error, "unsupported InfluxQL (GROUP BY time() offset of now())"}

      match = Regex.run(~r/^'([^'\\]*)'/, rest) ->
        timestamp_offset(ctx, every, pos, match)

      true ->
        {:error, {:engine, error(ctx, :time_close, interval_stop)}}
    end
  end

  # A quoted offset is a timestamp the planner reads: one it cannot read is its
  # error (after the whole statement has been read), one it can is not
  # answered.
  defp timestamp_offset(ctx, every, pos, [quoted, content]) do
    stop = pos + byte_size(quoted)
    close = skip(ctx.text, stop)

    cond do
      byte_at(ctx.text, close) != ?) ->
        {:error, {:engine, error(ctx, :time_close, stop)}}

      InfluxQLTime.classify(content) == :invalid ->
        {:ok, {:time, {every, {:invalid, InfluxQLError.offset_error(quoted)}}}, close + 1}

      true ->
        {:error, "unsupported InfluxQL (GROUP BY time() with a timestamp offset)"}
    end
  end

  # A duration with an optional sign, as nanoseconds, or `:integer` for a plain
  # integer (the engine reads it as an interval and fails planning), or `:none`.
  @spec duration(binary(), non_neg_integer()) ::
          {:ok, integer(), non_neg_integer()} | {:integer, non_neg_integer()} | :big | :none
  defp duration(text, pos) do
    rest = binary_part(text, pos, byte_size(text) - pos)

    case Regex.run(~r/^([+-]?)((?:\d+(?:ns|ms|u|µ|s|m|h|d|w))+)/u, rest) do
      [whole, sign, parts] ->
        total = duration_total(parts)

        if total > SQLLimits.int64_max(),
          do: :big,
          else: {:ok, if(sign == "-", do: -total, else: total), pos + byte_size(whole)}

      nil ->
        case Regex.run(~r/^[+-]?\d+/, rest) do
          [digits] -> {:integer, pos + byte_size(digits)}
          nil -> :none
        end
    end
  end

  defp duration_total(parts) do
    ~r/(\d+)(ns|ms|u|µ|s|m|h|d|w)/u
    |> Regex.scan(parts)
    |> Enum.reduce(0, fn [_all, count, unit], total ->
      total + String.to_integer(count) * Durations.ns(unit)
    end)
  end

  # ---------------------------------------------------------------------------
  # fill(...)
  # ---------------------------------------------------------------------------

  # `fill` after the dimensions: `{:ok, fill | nil, stop}`; a `fill` that is
  # none (no parenthesis, an option that is not closed) is left over.
  @spec fill(map(), non_neg_integer()) ::
          {:ok, InfluxQLBuckets.fill() | nil, non_neg_integer()}
          | {:bad_option, non_neg_integer()}
  defp fill(ctx, stop) do
    pos = skip(ctx.text, stop)
    rest = binary_part(ctx.text, pos, byte_size(ctx.text) - pos)

    with [word] <- Regex.run(~r/^fill(?![\w])/i, rest),
         open = skip(ctx.text, pos + byte_size(word)),
         ?( <- byte_at(ctx.text, open) do
      fill_option(ctx, open + 1, stop)
    else
      _no_fill -> {:ok, nil, stop}
    end
  end

  defp fill_option(ctx, option_at, stop) do
    pos = skip(ctx.text, option_at)
    rest = binary_part(ctx.text, pos, byte_size(ctx.text) - pos)

    case option(rest) do
      {:ok, fill, size} ->
        close = skip(ctx.text, pos + size)

        if byte_at(ctx.text, close) == ?),
          do: {:ok, fill, close + 1},
          else: {:ok, nil, stop}

      :error ->
        {:bad_option, option_at}
    end
  end

  @doc """
  Reads the `fill(...)` that starts at `from` in `text` (the statement from where its clauses
  start), the way the clause is read after the dimensions or, with none, after the `WHERE`:
  `{:ok, stop}` where the call ends, `{:bad_option, pos}` for an option that is none of the
  engine's (`pos` is where the option starts) and `{:unclosed, from}` for one read but not
  closed by `)`, which leaves the statement from the `fill`.
  """
  @spec read_fill(binary(), non_neg_integer()) ::
          {:ok, non_neg_integer()}
          | {:bad_option, non_neg_integer()}
          | {:unclosed, non_neg_integer()}
  def read_fill(text, from) do
    case fill(%{text: text}, from) do
      {:ok, nil, _stop} -> {:unclosed, from}
      {:ok, _fill, stop} -> {:ok, stop}
      {:bad_option, _pos} = bad -> bad
    end
  end

  # The option of a `fill()`: a keyword, or a number whose sign may stand apart from its
  # digits (verified: `fill(- 1)` is `-1`, `fill(- - 1)` and `fill(- x)` are no options).
  @spec option(binary()) :: {:ok, InfluxQLBuckets.fill(), non_neg_integer()} | :error
  defp option(rest) do
    case Regex.run(
           ~r/^(?:(null|none|previous|linear)(?![\w])|([+-]?)\s*(\d*\.\d+|\d+))/i,
           rest
         ) do
      [word, keyword] when keyword != "" and byte_size(word) > 0 ->
        case option_atom(String.downcase(keyword)) do
          nil -> :error
          fill -> {:ok, fill, byte_size(word)}
        end

      [word, "", sign, number] ->
        number(sign, number, byte_size(word))

      _other ->
        :error
    end
  end

  # The fill a keyword names, as a literal: an atom is never made from the statement's text.
  @spec option_atom(binary()) :: :null | :none | :previous | :linear | nil
  defp option_atom("null"), do: :null
  defp option_atom("none"), do: :none
  defp option_atom("previous"), do: :previous
  defp option_atom("linear"), do: :linear
  defp option_atom(_other), do: nil

  @spec number(binary(), binary(), non_neg_integer()) ::
          {:ok, InfluxQLBuckets.fill(), non_neg_integer()} | :error
  defp number(sign, text, size) do
    if String.contains?(text, ".") do
      case text |> InfluxQLText.leading_zero() |> Float.parse() do
        {float, ""} when abs(float) < 1.0e308 -> {:ok, {:number, signed(sign, float)}, size}
        _other -> :error
      end
    else
      value = String.to_integer(text)

      if value > SQLLimits.int64_max(),
        do: :error,
        else: {:ok, {:number, signed(sign, value)}, size}
    end
  end

  defp signed("-", number), do: -number
  defp signed(_sign, number), do: number

  @doc """
  The option of a `fill()` that follows no `GROUP BY` (`nil` when there is
  none): it is read, and changes nothing.
  """
  @spec parse_loose_fill(binary() | nil) ::
          {:ok, InfluxQLBuckets.fill() | nil} | {:error, binary()}
  def parse_loose_fill(nil), do: {:ok, nil}

  def parse_loose_fill(option) do
    case option(String.trim(option)) do
      {:ok, fill, _size} -> {:ok, fill}
      :error -> {:error, "unsupported InfluxQL (fill(#{String.trim(option)}))"}
    end
  end

  # ---------------------------------------------------------------------------
  # What follows
  # ---------------------------------------------------------------------------

  defp leftover(ctx, stop, dimensions, fill) do
    pos = skip(ctx.text, stop)
    rest = binary_part(ctx.text, pos, byte_size(ctx.text) - pos)

    if rest == "" or rest =~ @after_clause do
      times = for {:time, time} <- dimensions, do: time
      others = for dimension <- dimensions, not match?({:time, _time}, dimension), do: dimension
      {time, rewrite_error} = first_time(times)

      {:ok, %{dimensions: others, time: time, fill: fill, rewrite_error: rewrite_error}, stop}
    else
      {:error, {:engine, error(ctx, :nom, pos)}}
    end
  end

  # Only the first `time()` counts; its offset may be the error the planner
  # raises for it.
  defp first_time([{every, {:invalid, body}} | _more]), do: {{every, 0}, body}
  defp first_time([time | _more]), do: {time, nil}
  defp first_time([]), do: {nil, nil}

  # ---------------------------------------------------------------------------
  # Text helpers
  # ---------------------------------------------------------------------------

  @spec error(map(), atom(), non_neg_integer()) :: binary()
  defp error(ctx, kind, pos), do: InfluxQLError.syntax_error_body(kind, ctx.at + pos, ctx.whole)

  # The position after the blanks that start at `pos`.
  @spec skip(binary(), non_neg_integer()) :: non_neg_integer()
  defp skip(text, pos) do
    case text |> binary_part(pos, byte_size(text) - pos) |> then(&Regex.run(~r/^\s*/, &1)) do
      [blanks] -> pos + byte_size(blanks)
    end
  end

  @spec byte_at(binary(), non_neg_integer()) :: byte() | nil
  defp byte_at(text, pos) when pos < byte_size(text), do: :binary.at(text, pos)
  defp byte_at(_text, _pos), do: nil
end
