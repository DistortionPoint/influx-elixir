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

  @ranks %{
    "where" => 0,
    "group" => 1,
    "fill" => 2,
    "order" => 3,
    "limit" => 4,
    "offset" => 5,
    "slimit" => 6,
    "soffset" => 7,
    "tz" => 8
  }

  require InfluxQLLex

  @dir "(?:ASC|DESC)" <> InfluxQLText.keyword_end()
  @order_by Regex.compile!(
              InfluxQLBlankRegex.blank_pattern(
                "\\AORDER\\s+BY\\s+(?:time(?![\\w])(?:\\s+" <> @dir <> ")?|" <> @dir <> ")"
              ),
              "i"
            )

  @doc """
  The error of the text left over, `nil` when the scan reaches the end of the text or a clause
  it does not read. `masked_rest` is the text after the source (its literals masked, comments
  blanked), `at` where it starts in `whole`.
  """
  @spec junk(binary(), non_neg_integer(), binary()) :: InfluxQLCheck.positioned() | nil
  def junk(whole, at, masked_rest) do
    case scan(masked_rest, skip(masked_rest, 0), -1) do
      pos when is_integer(pos) -> InfluxQLCheck.fail(:nom, at + pos, whole)
      nil -> nil
    end
  end

  @spec scan(binary(), non_neg_integer(), integer()) :: non_neg_integer() | nil
  defp scan(text, pos, _rank) when pos >= byte_size(text), do: nil

  defp scan(text, pos, rank) do
    rest = binary_part(text, pos, byte_size(text) - pos)

    case clause(rest) do
      :junk ->
        pos

      {name, size} ->
        rank_of = Map.fetch!(@ranks, name)

        cond do
          rank_of <= rank -> pos
          size == :unknown -> nil
          true -> scan(text, skip(text, pos + size), rank_of)
        end
    end
  end

  # The clause the text starts with: `{name, size}`, the size `:unknown` when its end is not
  # placed or it does not read, `:junk` when none starts here.
  @spec clause(binary()) :: {binary(), non_neg_integer() | :unknown} | :junk
  defp clause(rest) do
    case Regex.run(~q/\A([A-Za-z_]\w*)/, rest) do
      [word, _name] -> keyword(String.downcase(word), word, rest)
      nil -> :junk
    end
  end

  defp keyword("where", word, rest) do
    if blank_or_open?(rest, byte_size(word)), do: {"where", :unknown}, else: :junk
  end

  defp keyword(name, word, rest) when name in ["group", "order"] do
    if blank_after?(rest, byte_size(word)), do: {name, by_clause(name, rest)}, else: :junk
  end

  defp keyword(name, word, rest) when name in ["limit", "offset", "slimit", "soffset"] do
    with true <- blank_after?(rest, byte_size(word)),
         [count] <- Regex.run(~q/\A#{word}\s+\d+/i, rest) do
      {name, byte_size(count)}
    else
      false -> :junk
      nil -> {name, :unknown}
    end
  end

  defp keyword(name, _word, rest) when name in ["fill", "tz"] do
    cond do
      not (rest =~ ~q/\A[A-Za-z]+\s*\(/) -> :junk
      name == "fill" -> call(name, rest, ~q/\Afill\s*\(\s*[\w+\-.]*\s*\)/i)
      true -> call(name, rest, ~q/\Atz\s*\(\s*'_*'\s*\)/i)
    end
  end

  defp keyword(_name, _word, _rest), do: :junk

  defp call(name, rest, pattern) do
    case Regex.run(pattern, rest) do
      [call] -> {name, byte_size(call)}
      nil -> {name, :unknown}
    end
  end

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

  defp skip(text, pos) do
    rest = binary_part(text, pos, byte_size(text) - pos)
    pos + byte_size(rest) - byte_size(InfluxQLLex.trim_blanks(rest))
  end
end
