defmodule InfluxElixir.Client.Local.InfluxQLBlanks do
  @moduledoc false
  # The carriage return that stands directly after a keyword (see `InfluxQLLex`): the engine's
  # parser does not read the keyword, and fails where it should have (verified, each of these
  # with the keyword last in the text, in the middle, and with the rest of the statement
  # valid):
  #
  #   * `SELECT`, `AS` and `FROM` leave the whole statement unparsed (position 0)
  #   * `WHERE`, `GROUP`, `ORDER`, `LIMIT`, `OFFSET`, `SLIMIT`, `SOFFSET`, and `ASC` / `DESC`
  #     after `ORDER BY time`, leave the statement over from the keyword (`AND` and `OR` do the
  #     same in a condition, see `InfluxQLTokens`)
  #   * `BY` after `ORDER` leaves it over from the `ORDER`; after `GROUP` it is "expected BY",
  #     where the `BY` starts
  #   * `ASC` / `DESC` right after `ORDER BY` is not read as a keyword, and is a name that is
  #     no time column: "expected TIME column", where it starts
  #   * `fill` and `tz` before their parenthesis, and the option of a `fill()` (`null`, `none`,
  #     `previous`, `linear`) before the `)`, fail in ways not placed: refused by name
  #
  # Each check answers its error with the position the parser meets it at, or `nil`.

  alias InfluxElixir.Client.Local.{InfluxQLCheck, InfluxQLError}

  @select_stage ~r/(?<![\w])(SELECT|AS|FROM)\r/i
  @clause_stage ~r/(?<![\w])(WHERE|GROUP|BY|ORDER|ASC|DESC|LIMIT|OFFSET|SLIMIT|SOFFSET)\r/i
  @call_stage Regex.compile!(
                "(?<![\\w])(?:fill|tz)\\r[ \\t\\r\\n]*\\(|" <>
                  "(?<![\\w])fill[ \\t\\r\\n]*\\([ \\t\\r\\n+\\-]*(?:null|none|previous|linear)\\r",
                "i"
              )

  @call_refusal "unsupported InfluxQL (a carriage return after fill, tz or a fill() option)"

  @doc """
  The select list's keywords (`SELECT`, `AS`, `FROM`) with a carriage return after them. The
  statement is left unparsed, whatever stands after. `SELECT` is the first word, so its error is
  at position 0: nothing comes before it.
  """
  @spec select_stage(binary(), binary()) :: InfluxQLCheck.positioned() | nil
  def select_stage(whole, masked_head) do
    case Regex.run(@select_stage, masked_head, return: :index) do
      [{from, _size}, {word_at, word_size}] ->
        word = masked_head |> binary_part(word_at, word_size) |> String.downcase()
        key = if word == "select", do: 0, else: from
        {key, {:error, {:engine, InfluxQLError.syntax_error_body(:nom, 0, whole)}}}

      nil ->
        nil
    end
  end

  @doc """
  The clause keywords of the text after `FROM` (`at` is where it starts in `whole`, `masked_rest`
  the text with its literals masked) with a carriage return after them.
  """
  @spec clauses(binary(), non_neg_integer(), binary()) :: InfluxQLCheck.positioned() | nil
  def clauses(whole, at, masked_rest) do
    keywords =
      @clause_stage
      |> Regex.scan(masked_rest, return: :index)
      |> Enum.find_value(fn [_all, {from, size}] ->
        word = masked_rest |> binary_part(from, size) |> String.downcase()
        keyword_error(word, from, masked_rest, at, whole)
      end)

    InfluxQLCheck.leftmost([keywords, calls(at, masked_rest)])
  end

  defp calls(at, masked_rest) do
    with [{from, _size}] <- Regex.run(@call_stage, masked_rest, return: :index),
         do: InfluxQLCheck.refuse(at + from, @call_refusal)
  end

  defp keyword_error(word, from, masked_rest, at, whole) when word in ["asc", "desc"] do
    before = binary_part(masked_rest, 0, from)

    cond do
      before =~ ~r/(?<![\w])ORDER\s+BY\s+time\s+\z/i -> InfluxQLCheck.fail(:nom, at + from, whole)
      before =~ ~r/(?<![\w])ORDER\s+BY\s+\z/i -> InfluxQLCheck.fail(:order_time, at + from, whole)
      true -> nil
    end
  end

  defp keyword_error("by", from, masked_rest, at, whole) do
    before = binary_part(masked_rest, 0, from)

    cond do
      before =~ ~r/(?<![\w])GROUP\s+\z/i ->
        InfluxQLCheck.fail(:group_by, at + from, whole)

      order = Regex.run(~r/(?<![\w])ORDER\s+\z/i, before, return: :index) ->
        [{order_at, _size}] = order
        InfluxQLCheck.fail(:nom, at + order_at, whole)

      true ->
        nil
    end
  end

  defp keyword_error(_word, from, _masked_rest, at, whole),
    do: InfluxQLCheck.fail(:nom, at + from, whole)
end
