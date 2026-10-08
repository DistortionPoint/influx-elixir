defmodule InfluxElixir.Client.Local.InfluxQLSelectCheck do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  # The checks the engine's parser makes on the select list and `FROM`, each
  # reporting the position the engine reports (see
  # `InfluxElixir.Client.Local.InfluxQLError`).

  alias InfluxElixir.Client.Local.{
    InfluxQLArgs,
    InfluxQLCheck,
    InfluxQLError,
    InfluxQLLex,
    InfluxQLText
  }

  @select_start ~q/^\s*SELECT(?![\w])\s*/i
  @regex_column ~q/^\/(?:[^\/\\]|\\.)+\/(?:\s+AS\s+(?:"[^"]+"|\w+))?$/s

  # An operator, what follows it up to the operand (signs and opening
  # parentheses) and the word the operand starts with.
  @operand ~q/([+\-*\/%&|^])\s*()(?:[+\-(]\s*)*([A-Za-z_]\w*)(?![\w])/

  # The select list and `FROM`, as the engine's parser reads them (verified):
  #
  #   * a select list that is empty or starts with a reserved word (after any
  #     signs) is "expected field" where the list starts
  #   * a later item that starts with a reserved word leaves the whole
  #     statement unparsed (position 0); a reserved word first in a function's
  #     argument fails from there, at position 0
  #   * a reserved word where the operand after a binary operator is wanted
  #     (`i + as`, `i + from FROM t`, `i + FROM t`) fails from the operand on
  #     (signs and parentheses before the word included), at position 0, after
  #     `+` or `-`; after another operator the statement is left unparsed
  #   * an alias after `AS` that is reserved is "invalid field alias", at the
  #     end of `AS`; a lone `DISTINCT` is "invalid DISTINCT expression", at
  #     `FROM`
  #   * `FROM` followed by nothing, by a reserved word or by a character that
  #     starts no identifier is "invalid FROM clause", where the name starts
  @spec check_select(binary(), binary()) :: InfluxQLCheck.positioned() | nil
  @doc false
  def check_select(whole, masked) do
    case Regex.run(@select_start, masked, return: :index) do
      [{0, items_at}] -> check_list(whole, masked, items_at)
      _no_select -> nil
    end
  end

  # An error of the engine's with the position the parser meets it at.
  @spec engine(non_neg_integer(), binary()) :: InfluxQLCheck.positioned()
  defp engine(key, body), do: {key, {:error, {:engine, body}}}

  @spec check_list(binary(), binary(), non_neg_integer()) :: InfluxQLCheck.positioned() | nil
  defp check_list(whole, masked, items_at) do
    rest = binary_part(masked, items_at, byte_size(masked) - items_at)

    if rest == "" or reserved_item?(rest) or reserved_item?(skip_signs(rest)) or
         not field_start?(skip_signs(rest)) do
      engine(items_at, InfluxQLError.syntax_error_body(:field, items_at, whole))
    else
      check_from_keyword(whole, masked, items_at)
    end
  end

  @spec check_from_keyword(binary(), binary(), non_neg_integer()) ::
          InfluxQLCheck.positioned() | nil
  defp check_from_keyword(whole, masked, items_at) do
    case from_keyword(masked, items_at) do
      {:from, from_at, from_length} ->
        items = binary_part(masked, items_at, from_at - items_at)

        check_each_item(whole, items, items_at, from_at + 1) ||
          check_from(masked, from_at + from_length)

      {:operator, operator, operand_at} ->
        engine(operand_at, operator_body(operator, operand_at, whole))

      :none ->
        rest =
          masked
          |> binary_part(items_at, byte_size(masked) - items_at)
          |> InfluxQLLex.trim_both_blanks()

        # No `FROM`: the list is the rest of the statement, and the engine leaves it unparsed
        # where an item stops reading (an item followed by what is no part of it), else as late
        # as it can be, so that a literal left open in it is the error.
        reserved_operand(rest, items_at, whole, :off) ||
          engine(none_key(masked, items_at), InfluxQLError.syntax_error_body(:nom, 0, whole))
    end
  end

  @spec none_key(binary(), non_neg_integer()) :: non_neg_integer()
  defp none_key(masked, items_at) do
    masked
    |> binary_part(items_at, byte_size(masked) - items_at)
    |> comma_pieces(items_at)
    |> Enum.find_value(byte_size(masked), fn {piece, at} ->
      text = InfluxQLLex.trim_blanks(piece)
      start = at + byte_size(piece) - byte_size(text)

      with leftover when leftover != nil <-
             InfluxQLArgs.item_leftover(InfluxQLLex.trim_both_blanks(text)),
           do: start + leftover
    end)
  end

  @spec skip_signs(binary()) :: binary()
  defp skip_signs(text), do: Regex.replace(~q/^(?:[+\-]\s*)+/, text, "")

  # Whether a field can begin with the text: a name, a quoted name or string, a number, a
  # duration, a wildcard, a regular expression, a parenthesis or a bind parameter. Any other
  # character (`,`, `#`, `)`, a `.` with no digit after it) is where the engine expects a field.
  @spec field_start?(binary()) :: boolean()
  defp field_start?(text), do: Regex.match?(~q/^(?:[A-Za-z_"'*\/(\d]|\.\d|\$\w)/, text)

  # `DISTINCT` is read by the select list, not refused as a reserved word.
  @spec reserved_item?(binary()) :: boolean()
  defp reserved_item?(text) do
    case InfluxQLText.reserved_start(text) do
      {word, _size} -> String.downcase(word) != "distinct"
      nil -> false
    end
  end

  # The `FROM` that ends the select list: one that follows a binary operator
  # is the word the operand should have been, not the keyword.
  @spec from_keyword(binary(), non_neg_integer()) ::
          {:from, non_neg_integer(), non_neg_integer()}
          | {:operator, byte(), non_neg_integer()}
          | :none
  defp from_keyword(masked, items_at) do
    candidates =
      for [{at, length}] <- Regex.scan(~q/\sFROM(?![\w])\s*/i, masked, return: :index),
          at >= items_at,
          do: {at, length}

    Enum.find_value(candidates, :none, fn {at, length} ->
      before = binary_part(masked, items_at, at - items_at)

      case operator_before(before) do
        nil -> {:from, at, length}
        {operator, operand_at} -> {:operator, operator, operand_start(before, operand_at, at)}
      end
    end)
  end

  # Where the operand after an operator starts: the `FROM` itself when nothing
  # follows the operator in the text before it.
  @spec operand_start(binary(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp operand_start(before, operand_at, from_at) do
    if operand_at == byte_size(before),
      do: from_at + 1,
      else: from_at - byte_size(before) + operand_at
  end

  # A binary operator at the end of `text`, with where its operand starts.
  @spec operator_before(binary()) :: {byte(), non_neg_integer()} | nil
  defp operator_before(text) do
    # A regular expression for a column (`SELECT /re/ FROM`) ends in a slash too.
    with false <- text =~ ~q/(?:^|,)\s*\/(?:[^\/\\]|\\.)+\/\s*$/s,
         [_all, {at, 1}, {operand_at, 0}] <-
           Regex.run(~q/([+\-*\/%&|^])\s*()(?:[+\-(]\s*)*$/, text, return: :index),
         true <- binary_operator?(text, at) do
      {:binary.at(text, at), operand_at}
    else
      _no_operator -> nil
    end
  end

  # An operator is binary when an operand stands before it.
  @spec binary_operator?(binary(), non_neg_integer()) :: boolean()
  defp binary_operator?(text, at) do
    text
    |> binary_part(0, at)
    |> InfluxQLLex.trim_trailing_blanks()
    |> String.match?(~q/[\w)"']$/)
  end

  @spec operator_body(byte(), non_neg_integer(), binary()) :: binary()
  defp operator_body(operator, operand_at, whole) when operator in [?+, ?-],
    do: InfluxQLError.syntax_error_body(:failure, operand_at, whole)

  defp operator_body(_operator, _operand_at, whole),
    do: InfluxQLError.syntax_error_body(:nom, 0, whole)

  @spec check_from(binary(), non_neg_integer()) :: InfluxQLCheck.positioned() | nil
  defp check_from(masked, from_end) do
    rest = binary_part(masked, from_end, byte_size(masked) - from_end)

    if rest == "" or InfluxQLText.reserved_start(rest) != nil or
         not (rest =~ ~q/^[A-Za-z_"\/(]/),
       do: engine(from_end, InfluxQLError.syntax_error_body(:from, from_end, masked)),
       else: nil
  end

  # The comma-separated pieces of a text (its literals masked), each with its
  # offset in the statement. A comma inside parentheses (`percentile(f, 95)`)
  # does not separate.
  @spec comma_pieces(binary(), non_neg_integer()) :: [{binary(), non_neg_integer()}]
  @doc false
  def comma_pieces(text, base) do
    text
    |> split_top_level(0, 0, [])
    |> Enum.map_reduce(base, &{{&1, &2}, &2 + byte_size(&1) + 1})
    |> elem(0)
  end

  @spec split_top_level(binary(), non_neg_integer(), non_neg_integer(), [binary()]) :: [binary()]
  defp split_top_level(text, from, depth, pieces) do
    case top_level_comma(text, from, depth) do
      nil -> Enum.reverse([binary_part(text, from, byte_size(text) - from) | pieces])
      at -> split_top_level(text, at + 1, 0, [binary_part(text, from, at - from) | pieces])
    end
  end

  @spec top_level_comma(binary(), non_neg_integer(), non_neg_integer()) :: non_neg_integer() | nil
  defp top_level_comma(text, at, _depth) when at >= byte_size(text), do: nil

  defp top_level_comma(text, at, depth) do
    case :binary.at(text, at) do
      ?, when depth == 0 -> at
      ?( -> top_level_comma(text, at + 1, depth + 1)
      ?) -> top_level_comma(text, at + 1, max(depth - 1, 0))
      _other -> top_level_comma(text, at + 1, depth)
    end
  end

  @spec check_each_item(binary(), binary(), non_neg_integer(), non_neg_integer()) ::
          InfluxQLCheck.positioned() | nil
  defp check_each_item(whole, items, items_at, from_keyword_at) do
    pieces = comma_pieces(items, items_at)
    last = length(pieces) - 1

    pieces
    |> Enum.with_index()
    |> Enum.reduce_while(true, fn {{piece, at}, index}, prior_read? ->
      case check_item(whole, piece, at, {index, index == last, prior_read?}, from_keyword_at) do
        nil -> {:cont, prior_read? and readable_piece?(piece)}
        error -> {:halt, error}
      end
    end)
    |> case do
      {_key, {:error, _reason}} = error -> error
      _all_checked -> nil
    end
  end

  # Whether the engine reads the item: an expression with an alias, or a regular expression for
  # columns. An item behind one that it may not read is not read for the failures it holds, the
  # statement being unreadable before it.
  @spec readable_piece?(binary()) :: boolean()
  defp readable_piece?(piece) do
    text = InfluxQLLex.trim_both_blanks(piece)
    InfluxQLArgs.item?(text) or Regex.match?(@regex_column, text)
  end

  @spec check_item(
          binary(),
          binary(),
          non_neg_integer(),
          {non_neg_integer(), boolean(), boolean()},
          non_neg_integer()
        ) ::
          InfluxQLCheck.positioned() | nil
  defp check_item(whole, piece, at, {index, last?, prior_read?}, from_keyword_at) do
    text = InfluxQLLex.trim_blanks(piece)
    start = at + byte_size(piece) - byte_size(text)
    text = InfluxQLLex.trim_trailing_blanks(text)

    eot = list_end(prior_read?, last?, from_keyword_at, at + byte_size(piece))

    cond do
      # A regular expression for columns (`/re/`, `/re/ AS x`) is no division.
      Regex.match?(@regex_column, text) ->
        nil

      String.downcase(text) == "distinct" and last? ->
        engine(
          from_keyword_at,
          InfluxQLError.syntax_error_body(:distinct, from_keyword_at, whole)
        )

      String.downcase(text) == "distinct" ->
        InfluxQLCheck.refuse(start, "unsupported InfluxQL (DISTINCT)")

      index > 0 and unreadable_start?(text) ->
        engine(start, InfluxQLError.syntax_error_body(:nom, 0, whole))

      kind = dangling_dot(text) ->
        engine(start, dangling_dot_body(kind, index, start, whole))

      hit = reserved_operand(text, start, whole, eot) ->
        hit

      pos = reserved_alias(text, start) ->
        engine(pos, InfluxQLError.syntax_error_body(:alias, pos, whole))

      unreadable?(text) ->
        engine(start, InfluxQLError.syntax_error_body(:nom, 0, whole))

      true ->
        nil
    end
  end

  # A name with a dot and no name after it (`m.`, `m.f.`, `m.1`, `"m".`, `m. AS a`; blanks may
  # stand after the dot, a reserved word is no name) is no field (verified): the first item
  # fails as "expected field" where the list starts, a later one, or a dot in an alias, leaves
  # the statement unparsed. In a call's arguments, and as the operand of a binary operator, it
  # is another failure (see `InfluxQLArgs` and `operator_hit/3`).
  @dotted ~q/(?<![\w.])(?:[A-Za-z_]\w*|"_*")(?:\.\s*(?:[A-Za-z_]\w*|"_*"))*\./

  @spec dangling_dot(binary()) :: :alias | :field | nil
  defp dangling_dot(text) do
    @dotted
    |> Regex.scan(text, return: :index)
    |> Enum.find_value(fn [{from, length}] ->
      stop = from + length
      next = text |> binary_part(stop, byte_size(text) - stop) |> InfluxQLLex.trim_blanks()
      before = text |> binary_part(0, from) |> InfluxQLLex.trim_trailing_blanks()

      cond do
        next =~ ~q/\A(?:[A-Za-z_]|")/ and InfluxQLText.reserved_start(next) == nil -> nil
        # `m.*` and `m./re/` are qualified wildcards, read elsewhere.
        next =~ ~q/\A[*\/]/ -> nil
        # Only a name that stands where an item or an operand starts can be one: after an operand
        # (`(n)f.`) the item is left over from the name, after an operator or in a call other
        # errors come first (see `operator_hit/3` and `InfluxQLArgs`).
        before =~ ~q/(?:\A|\s)AS\z/i -> :alias
        inside_call?(before) or before =~ ~q/(?:[\w)"']|[+\-*\/%&|^])\z/ -> nil
        true -> :field
      end
    end)
  end

  # Whether the text ends inside the parentheses of a call (a name stands before the innermost
  # `(` still open).
  @spec inside_call?(binary()) :: boolean()
  defp inside_call?(prefix) do
    prefix
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce([], fn
      {?(, at}, open -> [call_before?(prefix, at) | open]
      {?), _at}, open -> Enum.drop(open, 1)
      {_byte, _at}, open -> open
    end)
    |> Enum.any?()
  end

  defp call_before?(text, at),
    do:
      text
      |> binary_part(0, at)
      |> InfluxQLLex.trim_trailing_blanks()
      |> String.match?(~q/[A-Za-z_]\w*\z/)

  @spec dangling_dot_body(:alias | :field, non_neg_integer(), non_neg_integer(), binary()) ::
          binary()
  defp dangling_dot_body(:field, 0, start, whole),
    do: InfluxQLError.syntax_error_body(:field, start, whole)

  defp dangling_dot_body(_kind, _index, _start, whole),
    do: InfluxQLError.syntax_error_body(:nom, 0, whole)

  # Where the text of the list ends for a call or an operator left open: before the `FROM` that
  # ends it, or the `,` that ends the item; `:off` for an item behind one the engine may not read.
  defp list_end(false, _last?, _from_keyword_at, _comma_at), do: :off
  defp list_end(true, true, from_keyword_at, _comma_at), do: from_keyword_at
  defp list_end(true, false, _from_keyword_at, comma_at), do: comma_at

  # Whether an item after the first cannot start a field.
  @spec unreadable_start?(binary()) :: boolean()
  defp unreadable_start?(text) do
    not field_start?(skip_signs(text)) or InfluxQLText.reserved_start(text, plain: true) != nil
  end

  @spec unreadable?(binary()) :: boolean()
  defp unreadable?(text), do: number_leftover?(text) or stray?(text)

  # A `#`, or a `)` that closes nothing, is where the engine's parser stops reading the item
  # and then the statement. A text with a regular expression is not read for them.
  @spec stray?(binary()) :: boolean()
  defp stray?(text) do
    not Regex.match?(~q{(?:^|[(,])\s*/}, text) and
      (String.contains?(text, "#") or excess_close?(String.to_charlist(text), 0))
  end

  @spec excess_close?(charlist(), non_neg_integer()) :: boolean()
  defp excess_close?([], _depth), do: false
  defp excess_close?([?) | _rest], 0), do: true
  defp excess_close?([?) | rest], depth), do: excess_close?(rest, depth - 1)
  defp excess_close?([?( | rest], depth), do: excess_close?(rest, depth + 1)
  defp excess_close?([_char | rest], depth), do: excess_close?(rest, depth)

  # A number is `\d*\.\d+` or `\d+`, or a duration of such counts and units: one that a
  # letter, digit, underscore or dot follows (`1_0`, `1e3`, `0x10`, `5.`) leaves the rest of
  # the text unread, and the engine fails the whole statement. A text with a regular
  # expression is not read for numbers.
  @spec number_leftover?(binary()) :: boolean()
  defp number_leftover?(text) do
    not Regex.match?(~q{(?:^|[(,])\s*/}, text) and
      Regex.match?(
        ~q/(?<![\w.])(?>(?:\d+(?:ns|ms|u|µ|s|m|h|d|w))+|\d*\.\d+|\d+)(?=[A-Za-z0-9_.])/,
        text
      )
  end

  # The first place a reserved word stands where an operand is wanted: after
  # a binary operator, or first in a call's parentheses. The engine fails
  # there (see `check_select/2`).
  @spec reserved_operand(binary(), non_neg_integer(), binary(), non_neg_integer() | :off) ::
          InfluxQLCheck.positioned() | nil
  defp reserved_operand(text, start, whole, eot) do
    [
      operator_hit(text, start, whole),
      argument_hit(text, start, whole),
      wildcard_hit(text, start, whole),
      list_hit(text, start, whole, eot),
      leftover_hit(text, start, whole, eot)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    |> then(fn hit -> hit && engine(elem(hit, 0), elem(hit, 1)) end)
  end

  @spec operator_hit(binary(), non_neg_integer(), binary()) :: {non_neg_integer(), binary()} | nil
  defp operator_hit(text, start, whole) do
    @operand
    |> Regex.scan(text, return: :index)
    |> Enum.find_value(fn [_all, {operator_at, 1}, {operand_at, 0}, {word_at, _length}] ->
      <<_skip::binary-size(word_at), word_and_rest::binary>> = text

      if binary_operator?(text, operator_at) and
           InfluxQLText.reserved_start(word_and_rest, plain: true) != nil do
        operator = :binary.at(text, operator_at)
        {start + operand_at, operator_body(operator, start + operand_at, whole)}
      end
    end)
  end

  @spec argument_hit(binary(), non_neg_integer(), binary()) :: {non_neg_integer(), binary()} | nil
  defp argument_hit(text, start, whole) do
    ~q/[A-Za-z_]\w*\s*\(\s*([A-Za-z_]\w*)/
    |> Regex.scan(text, return: :index)
    |> Enum.find_value(fn [_all, {from, _length}] ->
      <<_skip::binary-size(from), word_and_rest::binary>> = text

      if InfluxQLText.reserved_start(word_and_rest) != nil,
        do: reserved_argument(word_and_rest, start + from, whole)
    end)
  end

  # `count(distinct(f))`: `DISTINCT` is a function there, not a reserved word;
  # `count(distinct f)` reads the same. After the keyword only an identifier
  # will do ("invalid DISTINCT expression" where the other token starts); any
  # other reserved word is where the engine fails.
  @spec reserved_argument(binary(), non_neg_integer(), binary()) ::
          {non_neg_integer(), binary()} | nil
  defp reserved_argument(word_and_rest, at, whole) do
    case Regex.run(~q/^distinct(\s*)(\S?)/i, word_and_rest, return: :index) do
      [_all, {_start, spaces}, {token_at, token_size}] ->
        token = binary_part(word_and_rest, token_at, token_size)
        distinct_hit(token, spaces, at, token_at, whole)

      nil ->
        {at, InfluxQLError.syntax_error_body(:failure, at, whole)}
    end
  end

  defp distinct_hit(token, spaces, at, token_at, whole) do
    cond do
      token == "(" or (spaces > 0 and token =~ ~q/^[A-Za-z_"]$/) -> nil
      token in [")", ""] -> {at, InfluxQLError.syntax_error_body(:failure, at, whole)}
      true -> {at, InfluxQLError.syntax_error_body(:distinct, at + token_at, whole)}
    end
  end

  # The arguments of a call that are not `expression {, expression}` closed by `)`: the engine
  # fails where they stop reading (see `InfluxQLArgs`). A call left open at the end of the list
  # fails at the `FROM` that ends it (`eot`), which only the last item has. With no `FROM`
  # (`:off`) the text is the whole statement, not a list, and is not read.
  @spec list_hit(binary(), non_neg_integer(), binary(), non_neg_integer() | :off) ::
          {non_neg_integer(), binary()} | nil
  defp list_hit(_text, _start, _whole, :off), do: nil

  defp list_hit(text, start, whole, eot) do
    case InfluxQLArgs.item_failure(text) do
      {:fail, :eot} when is_integer(eot) -> failure_hit(eot, whole)
      {:fail, at} when is_integer(at) -> failure_hit(start + at, whole)
      _read_or_unknown -> nil
    end
  end

  # A select item followed by what is no part of it leaves the statement unparsed from its
  # start; the position it ranks at is where the leftover starts.
  defp leftover_hit(_text, _start, _whole, :off), do: nil

  defp leftover_hit(text, start, whole, _eot) do
    with at when at != nil <- InfluxQLArgs.item_leftover(text),
         do: {start + at, InfluxQLError.syntax_error_body(:nom, 0, whole)}
  end

  defp failure_hit(pos, whole), do: {pos, InfluxQLError.syntax_error_body(:failure, pos, whole)}

  # A regular expression stands alone in a call's parentheses: the engine fails
  # from whatever follows it (`percentile(/re/, 90)` fails at the comma). A `*`
  # may be followed by arguments, but not by a comma with none.
  @spec wildcard_hit(binary(), non_neg_integer(), binary()) ::
          {non_neg_integer(), binary()} | nil
  defp wildcard_hit(text, start, whole) do
    ~q{[A-Za-z_]\w*\s*\(\s*(?:/(?:[^/\\]|\\.)+/\s*(?=[^)\s])|\*\s*(?=,\s*\)))}
    |> Regex.scan(text, return: :index)
    |> Enum.find_value(fn [{from, length}] ->
      {start + from, InfluxQLError.syntax_error_body(:failure, start + from + length, whole)}
    end)
  end

  # The end of `AS` when the alias after it is reserved.
  @spec reserved_alias(binary(), non_neg_integer()) :: non_neg_integer() | nil
  defp reserved_alias(text, start) do
    # An alias is an identifier or a quoted one: a number, a quote or a sign is not (verified).
    case Regex.run(~q/\s(AS)(?![\w])\s*(?=[\d'.+-])/i, text, return: :index) do
      [_all, {as_at, as_length}] -> start + as_at + as_length
      nil -> reserved_word_alias(text, start)
    end
  end

  defp reserved_word_alias(text, start) do
    case Regex.run(~q/\s(AS)(?![\w])\s*([A-Za-z_]\w*)/i, text, return: :index) do
      [_all, {as_at, as_length}, {alias_at, _length}] ->
        <<_skip::binary-size(alias_at), alias_and_rest::binary>> = text
        if InfluxQLText.reserved_start(alias_and_rest), do: start + as_at + as_length

      nil ->
        last_as(text, start)
    end
  end

  # An `AS` last in the list: the word after it was cut off as `FROM`.
  @spec last_as(binary(), non_neg_integer()) :: non_neg_integer() | nil
  defp last_as(text, start) do
    case Regex.run(~q/\s(AS)(?![\w])\s*$/i, text, return: :index) do
      [_all, {as_at, as_length}] -> start + as_at + as_length
      nil -> nil
    end
  end
end
