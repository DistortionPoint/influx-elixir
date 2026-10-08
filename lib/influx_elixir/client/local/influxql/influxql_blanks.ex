defmodule InfluxElixir.Client.Local.InfluxQLBlanks do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
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

  alias InfluxElixir.Client.Local.{InfluxQLCheck, InfluxQLError, InfluxQLLex}

  @select_stage ~q/(?<![\w])(SELECT|AS|FROM)(?:\r|[\x80-\xFF])/i
  @clause_stage ~q/(?<![\w])(WHERE|GROUP|BY|ORDER|ASC|DESC|LIMIT|OFFSET|SLIMIT|SOFFSET)(?:\r|[\x80-\xFF])/i
  @name_stage ~q/(?<![\w])(?:fill|tz)\r[ \t\r\n]*\(/i
  @option_stage Regex.compile!(
                  "(?<![\\w])fill[ \\t\\r\\n]*(\\()[ \\t\\r\\n+\\-]*(?:null|none|previous|linear)\\r",
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

    InfluxQLCheck.leftmost([
      stray(whole, at, masked_rest),
      keywords | calls(whole, at, masked_rest)
    ])
  end

  # What stands directly after the source (past any blanks) and starts no clause: a
  # non-ASCII character or a control character. The statement is left over from it, whatever
  # the clauses behind it hold (verified for U+00A0, U+2003, `é`, `٣` and U+0001, with and
  # without a blank before it, after a name and a quoted name).
  @spec stray(binary(), non_neg_integer(), binary()) :: InfluxQLCheck.positioned() | nil
  defp stray(whole, at, masked_rest) do
    blanks = byte_size(masked_rest) - byte_size(InfluxQLLex.trim_blanks(masked_rest))

    case binary_part(masked_rest, blanks, min(1, byte_size(masked_rest) - blanks)) do
      <<c>> when c >= 0x80 or c == 1 -> InfluxQLCheck.fail(:nom, at + blanks, whole)
      _other -> nil
    end
  end

  # `fill` or `tz` with a carriage return before its parenthesis is left over from its name,
  # and a `fill()` option with one directly after it is an invalid option, read from just
  # after the parenthesis (verified, blanks, signs and the other clauses around). Inside a
  # condition the word is a call, whose errors are another's (see `InfluxQLCheck`): refused.
  defp calls(whole, at, masked_rest) do
    stages = condition_stages(masked_rest)

    names =
      for [{from, _size}] <- Regex.scan(@name_stage, masked_rest, return: :index),
          do:
            call_error(
              stages,
              from,
              fn -> InfluxQLCheck.fail(:nom, at + from, whole) end,
              at
            )

    options =
      for [{from, _size}, {paren, 1}] <- Regex.scan(@option_stage, masked_rest, return: :index),
          do:
            call_error(
              stages,
              from,
              fn -> InfluxQLCheck.fail(:fill, at + paren + 1, whole) end,
              at
            )

    names ++ options
  end

  defp call_error(stages, from, answer, at) do
    if in_condition?(stages, from),
      do: InfluxQLCheck.refuse(at + from, @call_refusal),
      else: answer.()
  end

  # Where a `WHERE` condition starts and ends in the text, read once: the `WHERE` keywords and
  # the clause keywords that end a condition, as `{end of the word, :where | :end}` in order.
  @stage ~q/(?<![\w])(?:(WHERE)|(GROUP|ORDER|S?LIMIT|S?OFFSET|tz|fill))(?![\w])/i

  defp condition_stages(masked_rest) do
    for [{from, size}, {where, _size} | _rest] <- Regex.scan(@stage, masked_rest, return: :index) do
      {from + size, if(where == from, do: :where, else: :end)}
    end
  end

  # Whether the text at `from` stands in a `WHERE` condition: after a `WHERE` with no clause
  # keyword between. The last keyword that ends before `from` decides.
  defp in_condition?(stages, from) do
    stages
    |> Enum.take_while(fn {stop, _kind} -> stop <= from end)
    |> List.last()
    |> case do
      {_stop, :where} -> true
      _end_or_none -> false
    end
  end

  defp keyword_error(word, from, masked_rest, at, whole) when word in ["asc", "desc"] do
    before = binary_part(masked_rest, 0, from)

    cond do
      before =~ ~q/(?<![\w])ORDER\s+BY\s+time\s+\z/i -> InfluxQLCheck.fail(:nom, at + from, whole)
      before =~ ~q/(?<![\w])ORDER\s+BY\s+\z/i -> InfluxQLCheck.fail(:order_time, at + from, whole)
      true -> nil
    end
  end

  defp keyword_error("by", from, masked_rest, at, whole) do
    before = binary_part(masked_rest, 0, from)

    cond do
      before =~ ~q/(?<![\w])GROUP\s+\z/i ->
        InfluxQLCheck.fail(:group_by, at + from, whole)

      order = Regex.run(~q/(?<![\w])ORDER\s+\z/i, before, return: :index) ->
        [{order_at, _size}] = order
        InfluxQLCheck.fail(:nom, at + order_at, whole)

      true ->
        nil
    end
  end

  defp keyword_error(_word, from, _masked_rest, at, whole),
    do: InfluxQLCheck.fail(:nom, at + from, whole)
end
