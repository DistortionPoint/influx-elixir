defmodule InfluxElixir.Client.Local.InfluxQLCheck do
  @moduledoc false
  # The checks the engine's parser makes on the clauses of a statement, each
  # reporting the position the engine reports (see
  # `InfluxElixir.Client.Local.InfluxQLError`): the select list and `FROM`, the
  # `WHERE` (what its tokens cannot read and its parentheses), `GROUP BY`, a
  # clause keyword swallowed by the clause before it, and `LIMIT` / `OFFSET`
  # past the unsigned range.

  alias InfluxElixir.Client.Local.{
    InfluxQLError,
    InfluxQLParens,
    InfluxQLSelectCheck,
    InfluxQLText,
    InfluxQLTokens,
    SQLLimits
  }

  require SQLLimits

  # What the engine's parser cannot read in the `WHERE` fails the statement
  # where it stands (verified), naming the position (from the
  # start of the statement) and, for a statement it cannot continue, the
  # rest of the statement, `;` and later clauses included:
  #
  #   * `NOT` is no InfluxQL keyword (the position is the operand after it);
  #     a number is `\d*\.\d+` or `\d+` only, so an exponent, a trailing dot,
  #     a hex or an underscore leaves the rest of the literal behind (the
  #     position is where that begins)
  #   * a comparison or `AND` / `OR` with no operand after it, or one that
  #     cannot start an operand (a lone dot, `)`, a connective), is an
  #     invalid conditional expression at the end of the operator
  #   * an integer beyond the unsigned 64-bit range, or a negative one
  #     beyond the signed range, is an overflow at the end of its digits; a
  #     duration whose count only fits the unsigned range leaves its unit
  #     behind
  #
  # A reserved word (`reserved?/1`) where an operand is expected is an error
  # whose shape depends on what stands before it (verified): at the start of
  # the condition the whole `WHERE` is left unparsed (the error is at the
  # `WHERE`); after a comparison or a connective it is the missing operand
  # (at the end of the operator, sign and parenthesis skipped); after `*` or
  # `/` the operator is what cannot be read; after a binary `+` or `-` the
  # engine fails from the word on, at position 0; after an operand it is the
  # word itself. A `WHERE` with nothing after it is unparsed like the first.
  # A clause keyword inside what the clause regex took for the `WHERE` means
  # the clause after it is malformed: the condition ends there, and that
  # clause is what the engine reads next.
  @clause_keyword ~r/\b(?:GROUP|ORDER|LIMIT|OFFSET|SLIMIT|SOFFSET)\b/i

  @spec cut_where(binary(), binary()) :: {binary() | nil, {non_neg_integer()} | nil}
  @doc false
  def cut_where(masked_rest, raw_where) do
    indexes = Regex.named_captures(InfluxQLText.clauses(), masked_rest, return: :index)

    case swallowed(masked_rest, indexes["where"]) do
      {at, from} ->
        {where, _fill_rest} = without_fill(binary_part(raw_where, 0, at), masked_rest, indexes)
        {InfluxQLText.blank_to_nil(where), {from}}

      nil ->
        {where, fill_rest} = without_fill(raw_where, masked_rest, indexes)

        {InfluxQLText.blank_to_nil(where),
         fill_rest || swallowed_in_group(masked_rest, indexes["group"])}
    end
  end

  # The condition without a `fill(...)` call that follows it (`WHERE c fill(1) LIMIT x`: the
  # fill is the clause after the condition, not a part of it), and where the text behind the
  # call starts when something other than blanks stands there: the engine reads that as a
  # clause, and the clause is not one the double reads.
  @spec without_fill(binary(), binary(), map()) :: {binary(), {non_neg_integer()} | nil}
  defp without_fill(where, masked_rest, %{"where" => {from, _length}}) when from >= 0 do
    masked = binary_part(masked_rest, from, min(byte_size(where), byte_size(masked_rest) - from))

    case Regex.run(~r/(?<![\w])fill\s*\([^)]*\)/i, masked, return: :index) do
      [{start, size}] ->
        rest = binary_part(masked, start + size, byte_size(masked) - start - size)
        blanks = byte_size(rest) - byte_size(String.trim_leading(rest))

        {binary_part(where, 0, start),
         if(String.trim(rest) == "", do: nil, else: {from + start + size + blanks})}

      _no_fill ->
        {where, nil}
    end
  end

  defp without_fill(where, _masked_rest, _indexes), do: {where, nil}

  defp swallowed_in_group(masked_rest, index) do
    case swallowed(masked_rest, index) do
      {_at, from} -> {from}
      nil -> nil
    end
  end

  # Where a clause keyword stands inside a clause's text (not at its start):
  # `{offset in the text, offset in the rest}`.
  defp swallowed(_masked_rest, {from, _length}) when from < 0, do: nil
  defp swallowed(_masked_rest, nil), do: nil

  defp swallowed(masked_rest, {from, length}) do
    case Regex.run(@clause_keyword, binary_part(masked_rest, from, length), return: :index) do
      [{at, _size}] when at > 0 ->
        if completes_operand?(masked_rest, from, at), do: {at, from + at}

      _none_or_start ->
        nil
    end
  end

  # A clause keyword ends the condition only after a complete operand; after
  # an operator or a connective it is a reserved word where one is wanted.
  @spec completes_operand?(binary(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp completes_operand?(masked_rest, from, at),
    do: not (binary_part(masked_rest, from, at) =~ ~r/(?:[-+*\/=<>(,~!]|\b(?:AND|OR))\s*$/i)

  @spec check_swallowed(binary(), non_neg_integer(), binary(), {non_neg_integer()} | nil) ::
          :ok | {:error, term()}
  @doc false
  def check_swallowed(_whole, _at, _masked_rest, nil), do: :ok

  def check_swallowed(whole, at, masked_rest, {from}) do
    text = binary_part(masked_rest, from, byte_size(masked_rest) - from)
    start = at + from

    cond do
      text =~ ~r/^ORDER\s+BY/i ->
        check_order(text, start, whole)

      text =~ ~r/^(?:S?LIMIT|S?OFFSET)(?![\w])/i ->
        check_count(text, start, whole)

      text =~ ~r/^GROUP(?![\w])/i ->
        check_group_keyword(text, start, whole)

      text =~ ~r/^ORDER(?![\w])/i ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, start, whole)}}

      true ->
        {:error, :unread_order}
    end
  end

  # `ORDER BY` takes `time`, `ASC` or `DESC`: another name is "expected TIME
  # column", where it starts; a reserved word or a number "expected ASC, DESC
  # or TIME", at the end of `BY`.
  @spec check_order(binary(), non_neg_integer(), binary()) :: {:error, term()}
  defp check_order(text, start, whole) do
    [{_at, size}, {_blank, blank}] = Regex.run(~r/^ORDER\s+BY(\s*)/i, text, return: :index)
    after_by = binary_part(text, size, byte_size(text) - size)

    cond do
      after_by =~ ~r/^(?:time|asc|desc)(?![\w])/i ->
        {:error, :unread_order}

      InfluxQLText.reserved_start(after_by) == nil and after_by =~ ~r/^[A-Za-z_]/ ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:order_time, start + size, whole)}}

      true ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:order, start + size - blank, whole)}}
    end
  end

  # `LIMIT` and `OFFSET` take an unsigned integer: anything else after it is "expected
  # unsigned integer", where it starts; nothing leaves the clause unparsed.
  @spec check_count(binary(), non_neg_integer(), binary()) :: {:error, term()}
  defp check_count(text, start, whole) do
    [_all, {word, word_size}, {at, _blank}, {_rest_at, rest_size}] =
      Regex.run(~r/^(S?LIMIT|S?OFFSET)\s*()(.*)$/is, text, return: :index)

    kind = text |> binary_part(word, word_size) |> String.downcase() |> count_clause()

    cond do
      rest_size == 0 -> {:error, {:engine, InfluxQLError.syntax_error_body(:nom, start, whole)}}
      binary_part(text, at, 1) =~ ~r/\d/ -> {:error, :unread_order}
      true -> {:error, {:engine, InfluxQLError.syntax_error_body(kind, start + at, whole)}}
    end
  end

  # The clause a word names, as a literal: the words are matched by a fixed pattern, and an
  # atom is never made from the statement's text.
  @spec count_clause(binary()) :: :limit | :offset | :slimit
  defp count_clause("limit"), do: :limit
  defp count_clause("offset"), do: :offset
  defp count_clause("slimit"), do: :slimit
  # A bad operand of `SOFFSET` is worded as one of `SLIMIT` (verified): the parser reads the
  # two as one alternative.
  defp count_clause("soffset"), do: :slimit

  # `GROUP` must be followed by `BY`; `GROUP` or `GROUP BY` at the very end of
  # the text is unparsed, with blanks after it the dimension is wanted there.
  @spec check_group_keyword(binary(), non_neg_integer(), binary()) :: {:error, term()}
  defp check_group_keyword(text, start, whole) do
    cond do
      text =~ ~r/^GROUP(?:\s+BY)?$/i ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, start, whole)}}

      text =~ ~r/^GROUP\s+BY\s+$/i ->
        {:error,
         {:engine, InfluxQLError.syntax_error_body(:group, start + byte_size(text), whole)}}

      text =~ ~r/^GROUP\s+BY(?![\w])/i ->
        {:error, :unread_order}

      true ->
        [{_at, size}] = Regex.run(~r/^GROUP\s*/i, text, return: :index)
        {:error, {:engine, InfluxQLError.syntax_error_body(:group_by, start + size, whole)}}
    end
  end

  # A quoted string, a quoted identifier or a regular expression (after `=~`
  # or `!~`) that is never closed is the lexer's error, before the parser
  # reads anything: at the end of the text (verified), wherever the literal
  # starts.
  @spec check_literals(binary()) :: :ok | {:error, {:engine, binary()}}
  @doc false
  def check_literals(whole) do
    case unterminated(whole, false) do
      nil -> :ok
      kind -> {:error, {:engine, InfluxQLError.syntax_error_body(kind, byte_size(whole), whole)}}
    end
  end

  @spec unterminated(binary(), boolean()) :: :unterminated_string | :unterminated_regex | nil
  defp unterminated(<<>>, _regex?), do: nil

  defp unterminated(<<quote, rest::binary>>, _regex?) when quote in [?', ?"] do
    case skip_literal(rest, quote) do
      {:ok, after_literal} -> unterminated(after_literal, false)
      :unterminated -> :unterminated_string
    end
  end

  defp unterminated(<<operator::binary-size(2), rest::binary>>, _regex?)
       when operator in ["=~", "!~"],
       do: unterminated(rest, true)

  defp unterminated(<<?/, rest::binary>>, true) do
    case skip_regex(rest) do
      {:ok, after_literal} -> unterminated(after_literal, false)
      :unterminated -> :unterminated_regex
    end
  end

  defp unterminated(<<blank, rest::binary>>, regex?) when blank in [?\s, ?\t, ?\n, ?\r],
    do: unterminated(rest, regex?)

  defp unterminated(<<_byte, rest::binary>>, _regex?), do: unterminated(rest, false)

  # Only `\/` escapes in a regular expression: `\\/` is a backslash and the
  # slash of an expression that goes on (verified).
  @spec skip_regex(binary()) :: {:ok, binary()} | :unterminated
  defp skip_regex(<<?\\, ?/, rest::binary>>), do: skip_regex(rest)
  defp skip_regex(<<?/, rest::binary>>), do: {:ok, rest}
  defp skip_regex(<<_byte, rest::binary>>), do: skip_regex(rest)
  defp skip_regex(<<>>), do: :unterminated

  @spec skip_literal(binary(), byte()) :: {:ok, binary()} | :unterminated
  defp skip_literal(<<?\\, _escaped, rest::binary>>, closing), do: skip_literal(rest, closing)
  defp skip_literal(<<closing, rest::binary>>, closing), do: {:ok, rest}
  defp skip_literal(<<_byte, rest::binary>>, closing), do: skip_literal(rest, closing)
  defp skip_literal(<<>>, _closing), do: :unterminated

  @spec check_empty_where(binary(), non_neg_integer(), binary()) ::
          :ok | {:error, {:engine, binary()}}
  @doc false
  def check_empty_where(whole, at, masked_rest) do
    case Regex.run(~r/^(\s*)WHERE\s*$/i, masked_rest, return: :index) do
      [_all, {_from, blank}] ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, at + blank, whole)}}

      nil ->
        :ok
    end
  end

  @spec check_where(binary(), non_neg_integer(), binary(), binary() | nil) ::
          :ok | {:error, {:engine, binary()}}
  @doc false
  def check_where(_whole, _at, _masked_rest, nil), do: :ok

  def check_where(whole, at, masked_rest, where) do
    case InfluxQLTokens.tokenize(where, []) do
      {:syntax_error, kind, after_error} ->
        [{from, length}] = Regex.run(~r/\bWHERE\s+/i, masked_rest, return: :index)
        pos = at + from + length + byte_size(where) - byte_size(after_error)
        {:error, {:engine, InfluxQLError.where_error_body(kind, pos, at + from, whole)}}

      {:ok, tokens} ->
        [{from, length}] = Regex.run(~r/\bWHERE\s+/i, masked_rest, return: :index)
        masked = binary_part(masked_rest, from + length, byte_size(where))
        InfluxQLParens.check(tokens, masked, at + from + length, at + from, whole)

      _refusal ->
        :ok
    end
  end

  # `GROUP BY`: a first dimension that is a reserved word is "invalid GROUP BY
  # clause" where it starts; a later one leaves the list from the comma before
  # it unparsed.
  @spec check_group(binary(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  @doc false
  def check_group(whole, at, masked_rest) do
    case Regex.named_captures(InfluxQLText.clauses(), masked_rest, return: :index) do
      %{"group" => {from, length}} when from >= 0 ->
        masked_rest
        |> binary_part(from, length)
        |> InfluxQLSelectCheck.comma_pieces(at + from)
        |> Enum.with_index()
        |> Enum.find_value(:ok, &group_dimension(&1, whole))

      _no_group ->
        :ok
    end
  end

  @spec group_dimension({{binary(), non_neg_integer()}, non_neg_integer()}, binary()) ::
          {:error, term()} | nil
  defp group_dimension({{piece, at}, index}, whole) do
    text = String.trim_leading(piece)
    start = at + byte_size(piece) - byte_size(text)

    cond do
      text =~ ~r/^time\s*$/i ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:time_call, start + 4, whole)}}

      InfluxQLText.reserved_start(text) == nil and not String.starts_with?(text, "(") ->
        nil

      index == 0 ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:group, start, whole)}}

      true ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, at - 1, whole)}}
    end
  end

  # `fill(...)` after the dimensions (verified): an option that starts with
  # something other than a sign, a digit or a dot (and is no keyword) is
  # "invalid FILL option" where the option starts; one that starts like a
  # number and is not one leaves the statement unparsed from `fill`.
  @spec check_fill(binary(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  @doc false
  def check_fill(whole, at, masked_rest) do
    case Regex.named_captures(InfluxQLText.clauses(), masked_rest, return: :index) do
      %{"fillcall" => {call_at, _size}, "fill" => {from, length}} when call_at >= 0 ->
        option = binary_part(masked_rest, from, length)
        fill_option_error(whole, option, at + from, at + call_at)

      _no_fill ->
        :ok
    end
  end

  @spec fill_option_error(binary(), binary(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp fill_option_error(whole, option, option_start, fill_start) do
    text = option

    cond do
      Regex.match?(~r/^\s*(?:null|none|previous|linear)\s*$/i, text) ->
        :ok

      Regex.match?(~r/^\s*[+-]?(?:\d+(?:\.\d+)?|\.\d+)\s*$/, text) ->
        :ok

      Regex.match?(~r/^[+-]?[\d.]/, text) ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, fill_start, whole)}}

      Regex.match?(~r/^[A-Za-z_"'(]|^$/, text) ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:fill, option_start, whole)}}

      true ->
        :ok
    end
  end

  # The clauses are read left to right, and the first operand that does not read ends the
  # statement: of a clause keyword swallowed by the clause before it (see `check_swallowed/4`)
  # and a number past the unsigned range (see `check_unsigned/3`), the one that stands
  # first is the error (verified: `LIMIT 99999999999999999999 SLIMIT x` is the overflow).
  @spec check_operands(binary(), non_neg_integer(), binary(), {non_neg_integer()} | nil) ::
          :ok | {:error, term()}
  @doc false
  def check_operands(whole, at, masked_rest, swallowed) do
    errors =
      for check <- [
            check_swallowed(whole, at, masked_rest, swallowed),
            check_unsigned(whole, at, masked_rest)
          ],
          match?({:error, _reason}, check),
          do: check

    case errors do
      [] -> :ok
      [_one | _more] -> first_error(errors)
    end
  end

  @doc "The error among `errors` that the parser meets first: the one at the leftmost position."
  @spec first_error([{:error, term()}, ...]) :: {:error, term()}
  def first_error(errors), do: Enum.min_by(errors, &error_position/1)

  defp error_position({:error, {:engine, body}}) do
    case Regex.run(~r/ at pos (\d+)/, body) do
      [_all, digits] -> String.to_integer(digits)
      nil -> 0
    end
  end

  defp error_position({:error, _other}), do: 0

  # `LIMIT` and `OFFSET` are unsigned 64-bit integers; a longer number is a
  # parse error at the end of its digits. One that fits but not the signed
  # range is a planning error (`check_window/1`).
  @spec check_unsigned(binary(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  @doc false
  def check_unsigned(whole, at, masked_rest) do
    # Read from the text, not from the clauses: a clause behind one that is overflowing
    # may not read at all, and the overflow stands first.
    ~r/(?<![\w])(?:limit|offset|slimit|soffset)\s+(\d+)/i
    |> Regex.scan(masked_rest, return: :index)
    |> Enum.find_value(:ok, fn [_all, {from, length}] ->
      if masked_rest |> binary_part(from, length) |> String.to_integer() > SQLLimits.uint64_max(),
        do:
          {:error,
           {:engine, InfluxQLError.syntax_error_body(:unsigned, at + from + length, whole)}}
    end)
  end
end
