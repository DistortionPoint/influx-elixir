defmodule InfluxElixir.Client.Local.InfluxQLClauseScan do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  # The clauses after `FROM <source>` read in turn, as the engine's parser reads them: each
  # of `WHERE`, `GROUP BY`, `fill()`, `ORDER BY`, `LIMIT`, `OFFSET`, `SLIMIT`, `SOFFSET`, `tz()`
  # is tried once, in that order, at the place the last one ended; the statement is left over
  # from the first place no clause (that is still to come) starts at (verified: a name, a
  # parenthesis, a sign or a digit there; a keyword directly against a character, a word that
  # only starts with a keyword, a keyword out of its place).
  #
  # A keyword is read when a blank follows it (`WHERE` also against `(`, `+` and `-`, `fill`
  # and `tz` against a parenthesis, see `InfluxQLBlanks`); against any other character it is not
  # read and the text is left over from it.
  #
  # The scan knows where a `LIMIT`, `OFFSET`, `SLIMIT`, `SOFFSET`, `ORDER BY`, `fill()` or
  # `tz()` ends. It stops, with no answer, at a clause whose end it does not place (`WHERE`, and
  # `GROUP BY`, which the other checks read) and at one that is malformed (their own error is
  # the engine's), so it only says where junk stands before and between the clauses it reads.

  alias InfluxElixir.Client.Local.{InfluxQLBlankRegex, InfluxQLCheck, InfluxQLLex, InfluxQLText}

  require InfluxQLLex

  @dir "(?:ASC|DESC)" <> InfluxQLText.keyword_end()
  @order_by Regex.compile!(
              InfluxQLBlankRegex.blank_pattern(
                "\\AORDER\\s+BY\\s+(?:time(?![\\w])(?:\\s+" <> @dir <> ")?|" <> @dir <> ")"
              ),
              "i"
            )

  # A clause word, and the count a `LIMIT`-like clause reads after it.
  @word ~q/\A([A-Za-z_]\w*)/
  @counted ~q/\A\w+\s+\d+/

  # The calls of the clauses that end where their parenthesis does. `fill()` takes an option
  # of word characters, signs and points; `tz()` a zone, and only `'UTC'` (as written, case
  # and all) is one the double knows: any other, an unknown zone to the engine or not, is a
  # clause whose end the scan does not place (the zone is read from the statement as sent, the
  # masked text holds only underscores in its place).
  @fill_call ~q/\Afill\s*\(\s*[\w+\-.]*\s*\)/i
  @tz_call ~q/\Atz\s*\(\s*(?-i:'UTC')\s*\)/i
  @call_start ~q/\A[A-Za-z]+\s*\(/

  @doc """
  The error of the text left over, `nil` when the scan reaches the end of the text or a clause
  it does not read. `masked_rest` is the text after the source (its literals masked, comments
  blanked), `at` where it starts in `whole`.
  """
  @spec junk(binary(), non_neg_integer(), binary()) :: InfluxQLCheck.positioned() | nil
  def junk(whole, at, masked_rest) do
    raw = binary_part(whole, at, byte_size(masked_rest))

    case scan({masked_rest, raw}, InfluxQLLex.skip_blanks(masked_rest, 0), -1) do
      pos when is_integer(pos) -> InfluxQLCheck.fail(:nom, at + pos, whole)
      nil -> nil
    end
  end

  @spec scan({binary(), binary()}, non_neg_integer(), integer()) :: non_neg_integer() | nil
  defp scan({masked, raw} = texts, pos, rank) do
    case clause(binary_part(masked, pos, byte_size(masked) - pos), raw, pos) do
      # The end of the text: every clause read, nothing left over.
      :end ->
        nil

      :junk ->
        pos

      {name, size} ->
        rank_of = Map.fetch!(InfluxQLText.clause_ranks(), name)

        cond do
          rank_of <= rank -> pos
          size == :unknown -> nil
          true -> scan(texts, InfluxQLLex.skip_blanks(masked, pos + size), rank_of)
        end
    end
  end

  # The clause the text starts with (`rest`, which starts at `pos` in `raw`): `{name, size}`, the
  # size `:unknown` when its end is not placed or it does not read, `:junk` when none starts
  # here, `:end` when the text is.
  @spec clause(binary(), binary(), non_neg_integer()) ::
          {binary(), non_neg_integer() | :unknown} | :junk | :end
  defp clause("", _raw, _pos), do: :end

  defp clause(rest, raw, pos) do
    case Regex.run(@word, rest) do
      [word, _name] ->
        keyword(String.downcase(word), word, rest, binary_part(raw, pos, byte_size(rest)))

      nil ->
        :junk
    end
  end

  defp keyword("where", word, rest, _raw) do
    if blank_or_open?(rest, byte_size(word)), do: {"where", :unknown}, else: :junk
  end

  defp keyword(name, word, rest, _raw) when name in ["group", "order"] do
    if blank_after?(rest, byte_size(word)), do: {name, by_clause(name, rest)}, else: :junk
  end

  defp keyword(name, word, rest, _raw) when name in ["limit", "offset", "slimit", "soffset"] do
    with true <- blank_after?(rest, byte_size(word)),
         [count] <- Regex.run(@counted, rest) do
      {name, byte_size(count)}
    else
      false -> :junk
      nil -> {name, :unknown}
    end
  end

  defp keyword(name, _word, rest, raw) when name in ["fill", "tz"] do
    with true <- Regex.match?(@call_start, rest),
         [call] <- Regex.run(call_pattern(name), raw) do
      {name, byte_size(call)}
    else
      false -> :junk
      nil -> {name, :unknown}
    end
  end

  defp keyword(_name, _word, _rest, _raw), do: :junk

  defp call_pattern("fill"), do: @fill_call
  defp call_pattern("tz"), do: @tz_call

  # `ORDER BY time [ASC | DESC]` and `ORDER BY ASC | DESC` are read; `GROUP BY` is not placed.
  defp by_clause("group", _rest), do: :unknown

  defp by_clause("order", rest) do
    case Regex.run(@order_by, rest) do
      [clause] -> byte_size(clause)
      nil -> :unknown
    end
  end

  defp blank_after?(rest, size) do
    case rest do
      <<_word::binary-size(size), c, _more::binary>> -> InfluxQLLex.is_blank(c)
      _end -> false
    end
  end

  defp blank_or_open?(rest, size) do
    case rest do
      <<_word::binary-size(size), c, _more::binary>> ->
        InfluxQLLex.is_blank(c) or c in [?(, ?+, ?-]

      _end ->
        false
    end
  end
end
