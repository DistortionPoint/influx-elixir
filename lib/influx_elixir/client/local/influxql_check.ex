defmodule InfluxElixir.Client.Local.InfluxQLCheck do
  @moduledoc """
  The checks the engine's parser makes on the clauses of a statement, each
  reporting the position the engine reports (see
  `InfluxElixir.Client.Local.InfluxQLError`): the select list and `FROM`, the
  `WHERE` (what its tokens cannot read and its parentheses), `GROUP BY`, a
  clause keyword swallowed by the clause before it, and `LIMIT` / `OFFSET`
  past the unsigned range.
  """

  alias InfluxElixir.Client.Local.{
    InfluxQLError,
    InfluxQLParens,
    InfluxQLParser,
    InfluxQLReserved,
    InfluxQLSelectCheck,
    InfluxQLTokens
  }

  @max_unsigned 18_446_744_073_709_551_615

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
  @clause_keyword ~r/\b(?:GROUP|ORDER|LIMIT|OFFSET)\b/i

  @spec cut_where(binary(), binary()) :: {binary() | nil, {non_neg_integer()} | nil}
  @doc false
  def cut_where(masked_rest, raw_where) do
    indexes = Regex.named_captures(InfluxQLParser.rest(), masked_rest, return: :index)

    case swallowed(masked_rest, indexes["where"]) do
      {at, from} ->
        {InfluxQLParser.blank_to_nil(binary_part(raw_where, 0, at)), {from}}

      nil ->
        {InfluxQLParser.blank_to_nil(raw_where),
         swallowed_in_group(masked_rest, indexes["group"])}
    end
  end

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

      text =~ ~r/^(?:LIMIT|OFFSET)(?![\w])/i ->
        check_count(text, start, whole)

      text =~ ~r/^GROUP(?![\w])/i ->
        check_group_keyword(text, start, whole)

      text =~ ~r/^ORDER(?![\w])/i ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, start, whole)}}

      true ->
        {:error, "invalid clauses"}
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
        {:error, "invalid clauses"}

      InfluxQLReserved.reserved_start(after_by) == nil and after_by =~ ~r/^[A-Za-z_]/ ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:order_time, start + size, whole)}}

      true ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:order, start + size - blank, whole)}}
    end
  end

  # `LIMIT` and `OFFSET` take an unsigned integer: anything else after it is "expected
  # unsigned integer", where it starts; nothing leaves the clause unparsed.
  @spec check_count(binary(), non_neg_integer(), binary()) :: {:error, term()}
  defp check_count(text, start, whole) do
    [_all, {word, _word_size}, {at, _blank}, {_rest_at, rest_size}] =
      Regex.run(~r/^(LIMIT|OFFSET)\s*()(.*)$/is, text, return: :index)

    kind = if text |> binary_part(word, 1) |> String.upcase() == "L", do: :limit, else: :offset

    cond do
      rest_size == 0 -> {:error, {:engine, InfluxQLError.syntax_error_body(:nom, start, whole)}}
      binary_part(text, at, 1) =~ ~r/\d/ -> {:error, "invalid clauses"}
      true -> {:error, {:engine, InfluxQLError.syntax_error_body(kind, start + at, whole)}}
    end
  end

  # `GROUP` must be followed by `BY`; `GROUP BY` and nothing is unparsed.
  @spec check_group_keyword(binary(), non_neg_integer(), binary()) :: {:error, term()}
  defp check_group_keyword(text, start, whole) do
    cond do
      text =~ ~r/^GROUP\s+BY\s*$/i ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, start, whole)}}

      text =~ ~r/^GROUP\s+BY(?![\w])/i ->
        {:error, "invalid clauses"}

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
    case skip_literal(rest, ?/) do
      {:ok, after_literal} -> unterminated(after_literal, false)
      :unterminated -> :unterminated_regex
    end
  end

  defp unterminated(<<blank, rest::binary>>, regex?) when blank in [?\s, ?\t, ?\n, ?\r],
    do: unterminated(rest, regex?)

  defp unterminated(<<_byte, rest::binary>>, _regex?), do: unterminated(rest, false)

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
    case Regex.named_captures(InfluxQLParser.rest(), masked_rest, return: :index) do
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

      InfluxQLReserved.reserved_start(text) == nil and not String.starts_with?(text, "(") ->
        nil

      index == 0 ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:group, start, whole)}}

      true ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:nom, at - 1, whole)}}
    end
  end

  # `LIMIT` and `OFFSET` are unsigned 64-bit integers; a longer number is a
  # parse error at the end of its digits. One that fits but not the signed
  # range is a planning error (`check_window/1`).
  @spec check_unsigned(binary(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  @doc false
  def check_unsigned(whole, at, masked_rest) do
    indexes = Regex.named_captures(InfluxQLParser.rest(), masked_rest, return: :index)

    Enum.find_value(["limit", "offset"], :ok, fn clause ->
      with {from, length} when from >= 0 <- indexes[clause],
           digits = binary_part(masked_rest, from, length),
           true <- String.to_integer(digits) > @max_unsigned do
        {:error, {:engine, InfluxQLError.syntax_error_body(:unsigned, at + from + length, whole)}}
      else
        _fits -> nil
      end
    end)
  end
end
