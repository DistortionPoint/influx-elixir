defmodule InfluxElixir.Client.Local.InfluxQLBlanks do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  alias InfluxElixir.Client.Local.InfluxQLBlankRegex
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

  alias InfluxElixir.Client.Local.{InfluxQLCheck, InfluxQLError, InfluxQLLex, InfluxQLText}

  @select_stage ~q/(?<![\w])(SELECT|FROM)(?:\r|[\x80-\xFF])/i
  # `AS` directly against anything that is no blank, no word character and no character of an
  # operator or a parenthesis (`AS"x"`, `AS.x`, `AS$x`, `AS\r`) is not read as the keyword
  # either. Against an operator it is read, and the alias is wanted (`InfluxQLSelectCheck`).
  @as_stage Regex.compile!(
              InfluxQLBlankRegex.blank_pattern(
                "(?<![\\w])(AS)[^\\w \\t\\n" <> InfluxQLText.operator_glue_chars() <> "]"
              ),
              "i"
            )
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
    list = select_list(masked_head)

    [{@select_stage, masked_head}, {@as_stage, list}]
    |> Enum.flat_map(fn {regex, text} ->
      case Regex.run(regex, text, return: :index) do
        [{from, _size}, {word_at, word_size}] ->
          word = masked_head |> binary_part(word_at, word_size) |> String.downcase()
          key = if word == "select", do: 0, else: from
          [{key, {:error, {:engine, InfluxQLError.syntax_error_body(:nom, 0, whole)}}}]

        nil ->
          []
      end
    end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
  end

  # The select list: the text up to the `FROM` that ends it, all of it without one.
  @spec select_list(binary()) :: binary()
  defp select_list(masked_head) do
    case Regex.run(InfluxQLText.from_keyword(), masked_head, return: :index) do
      [{from, _size}] -> binary_part(masked_head, 0, from)
      nil -> masked_head
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

    InfluxQLCheck.leftmost(
      [stray(whole, at, masked_rest)] ++
        glued(whole, at, masked_rest) ++ [keywords | calls(whole, at, masked_rest)]
    )
  end

  # A clause keyword directly against the character after it. The engine's parser takes a
  # blank after the keyword to read it as one, and with none the clause is not there: the
  # statement is left over from the keyword (verified for each ASCII character, a control
  # character and a non-ASCII byte after each keyword):
  #
  #   * `LIMIT`, `OFFSET`, `SLIMIT`, `SOFFSET`: any character that is no blank and no word
  #     character (a word character makes another word, which may be a name in a condition:
  #     the double refuses that)
  #   * `WHERE`: any such character but the ones a condition may start with (`(`, `+`, `-`)
  #   * `GROUP BY` and `ORDER BY` split the characters in two (`InfluxQLText.operator_glue/0`):
  #     against an operator or a parenthesis `BY` is read, and `GROUP BY` is left over from
  #     `GROUP` where `ORDER BY` is "expected ASC, DESC or TIME" (read by `InfluxQLCheck`);
  #     against anything else `BY` is another word: `GROUP BY` fails as "expected BY" where
  #     `BY` starts, `ORDER BY` is left over from `ORDER`
  @count_glue ~q/(?<![\w.])(?:S?LIMIT|S?OFFSET)[^\w \t\n]/i
  @where_glue Regex.compile!(
                InfluxQLBlankRegex.blank_pattern(
                  "(?<![\\w.])WHERE[^\\w \\t\\n" <> InfluxQLText.operand_open_chars() <> "]"
                ),
                "i"
              )
  @by_glue ~q/(?<![\w.])(GROUP|ORDER)\s+BY([^ \t\n])/i
  # Those same keywords with a word character directly against them, first after the source,
  # are a word of another name: the statement is left over from it (later in the text the word
  # may be a field of a condition, and the double refuses it).
  @lead_glue ~q/\A\s*(WHERE|S?LIMIT|S?OFFSET)\w/i

  @spec glued(binary(), non_neg_integer(), binary()) :: [InfluxQLCheck.positioned() | nil]
  defp glued(whole, at, masked_rest) do
    count = first_glue(@count_glue, masked_rest)
    where = first_glue(@where_glue, masked_rest)
    lead = lead_glue(masked_rest)

    by =
      Enum.find_value(Regex.scan(@by_glue, masked_rest, return: :index), fn
        [_all, {from, _size}, {char_at, 1}] ->
          by_glue(masked_rest, whole, at, from, char_at)
      end)

    [
      count && InfluxQLCheck.fail(:nom, at + count, whole),
      where && InfluxQLCheck.fail(:nom, at + where, whole),
      lead && InfluxQLCheck.fail(:nom, at + lead, whole),
      by
    ]
  end

  @spec lead_glue(binary()) :: non_neg_integer() | nil
  defp lead_glue(masked_rest) do
    case Regex.run(@lead_glue, masked_rest, return: :index) do
      [_all, {from, _size}] -> from
      nil -> nil
    end
  end

  @spec first_glue(Regex.t(), binary()) :: non_neg_integer() | nil
  defp first_glue(regex, masked_rest) do
    case Regex.run(regex, masked_rest, return: :index) do
      [{from, _size}] -> from
      nil -> nil
    end
  end

  defp by_glue(masked_rest, whole, at, from, char_at) do
    operator? = binary_part(masked_rest, char_at, 1) in InfluxQLText.operator_glue()
    group? = String.downcase(binary_part(masked_rest, from, 5)) == "group"
    by_at = char_at - 2

    cond do
      group? and operator? -> InfluxQLCheck.fail(:nom, at + from, whole)
      group? -> InfluxQLCheck.fail(:group_by, at + by_at, whole)
      operator? -> nil
      true -> InfluxQLCheck.fail(:nom, at + from, whole)
    end
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
