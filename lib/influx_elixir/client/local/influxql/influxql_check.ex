defmodule InfluxElixir.Client.Local.InfluxQLCheck do
  @moduledoc false
  # The checks the engine's parser makes on the clauses of a statement, each
  # reporting the position the engine reports (see
  # `InfluxElixir.Client.Local.InfluxQLError`): the select list and `FROM`, the
  # `WHERE` (what its tokens cannot read and its parentheses), `GROUP BY`, a
  # clause keyword swallowed by the clause before it, and `LIMIT` / `OFFSET`
  # past the unsigned range.

  alias InfluxElixir.Client.Local.{
    InfluxQLArgs,
    InfluxQLError,
    InfluxQLGroup,
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

  # The functions the engine's parser accepts in a condition: the scalar math functions.
  @math_functions ~w(abs sin cos tan asin acos atan atan2 exp log ln log2 log10 sqrt pow floor ceil round date_part)

  # Where the text the double has not read starts: the clause keyword a clause swallowed
  # (`{from}`), or the `fill()` that follows a complete condition (`{:fill, from}`, see
  # `split_fill/3`), each as an offset in the text after `FROM`.
  @type unread :: {non_neg_integer()} | {:fill, non_neg_integer()}

  @typep check :: (-> :ok | {:error, term()})

  # An error with the position the engine reports it at: the parser reads left to right, so of
  # several errors the one at the leftmost position is the one it meets.
  @type positioned :: {non_neg_integer(), {:error, term()}}

  @spec cut_where(binary(), binary()) :: {binary() | nil, unread() | nil}
  @doc false
  def cut_where(masked_rest, raw_where) do
    indexes = Regex.named_captures(InfluxQLText.clauses(), masked_rest, return: :index)
    raw_where = take_call(raw_where, masked_rest, indexes)

    case swallowed(masked_rest, indexes["where"]) do
      {at, from} ->
        {where, fill} = split_fill(binary_part(raw_where, 0, at), masked_rest, indexes)
        {InfluxQLText.blank_to_nil(where), fill || {from}}

      nil ->
        {where, fill} = split_fill(raw_where, masked_rest, indexes)

        {InfluxQLText.blank_to_nil(where),
         fill || swallowed_in_group(masked_rest, indexes["group"])}
    end
  end

  # The clauses' pattern takes a `fill(...)` for the clause after the condition wherever it
  # can, `WHERE c AND fill(1)` included; one that stands where an operand is wanted is part of
  # the condition (see `check_where_call/4`), which then holds the call (masked: the call's
  # own text is not read).
  @spec take_call(binary(), binary(), map()) :: binary()
  defp take_call(raw_where, masked_rest, %{"where" => {from, length}, "fillcall" => {call, size}})
       when from >= 0 and call >= 0 do
    if clause_position?(binary_part(masked_rest, from, length), length),
      do: raw_where,
      else: raw_where <> binary_part(masked_rest, from + length, call + size - from - length)
  end

  defp take_call(raw_where, _masked_rest, _indexes), do: raw_where

  # The condition without the `fill(...)` that follows it (`WHERE c fill(1) LIMIT x`: the
  # fill is the clause after the condition, not a part of it), and where that clause starts.
  # A `fill(` that stands where an operand is wanted (first, or after an operator, a connective
  # or a parenthesis) is no clause but a call in the condition: it stays there (see
  # `check_where_call/4`).
  @spec split_fill(binary(), binary(), map()) :: {binary(), {:fill, non_neg_integer()} | nil}
  defp split_fill(where, masked_rest, %{"where" => {from, _length}}) when from >= 0 do
    masked = binary_part(masked_rest, from, min(byte_size(where), byte_size(masked_rest) - from))

    with [{start, _size}] <- Regex.run(InfluxQLText.fill_call(), masked, return: :index),
         true <- clause_position?(masked, start) do
      {binary_part(where, 0, start), {:fill, from + start}}
    else
      _no_clause -> {where, nil}
    end
  end

  defp split_fill(where, _masked_rest, _indexes), do: {where, nil}

  # Whether what stands before `start` in the condition is a complete operand.
  @spec clause_position?(binary(), non_neg_integer()) :: boolean()
  defp clause_position?(masked, start) do
    before = binary_part(masked, 0, start)
    String.trim(before) != "" and completes_operand?(masked, 0, start)
  end

  defp swallowed_in_group(masked_rest, index) do
    case swallowed(masked_rest, index) do
      {_at, from} -> {from}
      nil -> nil
    end
  end

  # `fill(` where an operand is wanted in the condition is a call the engine's parser refuses
  # where it starts (verified, whatever stands before it that reads and whatever follows it:
  # `WHERE n > 1 AND fill(1) LIMIT x`, `WHERE (n > fill(1)`). A call whose arguments are not a
  # flat list closed by `)` fails in ways not verified, and is refused by name. What stands
  # before the call is read first: its own error, if it has one, is the engine's (the check of
  # the `WHERE` reports it).
  @spec check_where_call(binary(), non_neg_integer(), binary(), binary() | nil) ::
          :ok | {:error, term()}
  @doc false
  def check_where_call(_whole, _at, _masked_rest, nil), do: :ok

  def check_where_call(whole, at, masked_rest, where) do
    [{from, length}] = Regex.run(~r/\bWHERE\s+/i, masked_rest, return: :index)
    masked = binary_part(masked_rest, from + length, byte_size(where))

    # The clauses taken out of the text (blanked) are in the statement the parser reads.
    text = InfluxQLText.mask_literals(binary_part(whole, at, byte_size(masked_rest)))
    calls = Regex.scan(~r/(?<![\w])([A-Za-z_]\w*)\s*\(/, masked, return: :index)

    read_calls(calls, %{
      whole: whole,
      at: at,
      text: text,
      where: where,
      masked: masked,
      from: from + length
    })
  end

  # The calls of the condition, left to right: the first that fails is the answer. What
  # stands before a call is read first: its own error, if it has one, is the engine's (the
  # check of the `WHERE` reports it), so a call behind one is not read.
  defp read_calls([], _ctx), do: :ok

  defp read_calls([[{start, size}, {name_at, name_size}] | calls], ctx) do
    name = ctx.masked |> binary_part(name_at, name_size) |> String.downcase()

    # `now()` has no arguments to read, a connective before a parenthesis is no call.
    if name in ["now", "and", "or", "not"] or InfluxQLText.reserved?(name),
      do: read_calls(calls, ctx),
      else: read_call(name, start, size, calls, ctx)
  end

  defp read_call(name, start, size, calls, ctx) do
    with {:ok, _tokens} <- InfluxQLTokens.tokenize(binary_part(ctx.where, 0, start) <> "0", []),
         false <- InfluxQLParens.excess_close?(binary_part(ctx.masked, 0, start)),
         false <- top_level_comma?(binary_part(ctx.masked, 0, start)) do
      call_at = ctx.from + start

      case call_result(ctx, name, call_at, call_at + size - 1) do
        :next -> read_calls(calls, ctx)
        result -> result
      end
    else
      _earlier_error -> :ok
    end
  end

  # A `,` outside every parenthesis is where the condition ends: the engine leaves the rest
  # over, so a call behind it is not read.
  defp top_level_comma?(text) do
    text
    |> :binary.bin_to_list()
    |> Enum.reduce_while(0, fn
      ?(, depth -> {:cont, depth + 1}
      ?), depth -> {:cont, depth - 1}
      ?,, 0 -> {:halt, :comma}
      _byte, depth -> {:cont, depth}
    end)
    |> Kernel.==(:comma)
  end

  # A call is read as the engine reads it: its arguments first. Arguments that do not read are
  # the parser's failure where they stop (`fill(+)`, `fill(1.)`, `abs(n x)`); arguments that
  # read are a call the engine does not know unless it is one of the scalar math functions
  # (verified: `fill`, `mean`, `trunc` and `foo` are not; `date_part` is read elsewhere).
  # Arguments the double cannot place are refused for a call that is no math function.
  @spec call_result(map(), binary(), non_neg_integer(), non_neg_integer()) ::
          :next | {:error, term()}
  defp call_result(ctx, name, call_at, open_at) do
    case {InfluxQLArgs.read(ctx.text, open_at), name in @math_functions} do
      {{:ok, _stop}, false} ->
        {:error, {:engine, InfluxQLError.syntax_error_body(:call, ctx.at + call_at, ctx.whole)}}

      {{:fail, :eot}, _math?} ->
        failure_at(ctx.at + byte_size(ctx.text), ctx.whole)

      {{:fail, pos}, _math?} ->
        failure_at(ctx.at + pos, ctx.whole)

      {:unknown, false} ->
        {:error, "unsupported InfluxQL (#{name}() in a WHERE)"}

      {_read_or_unknown, true} ->
        :next
    end
  end

  defp failure_at(pos, whole) do
    {_pos, error} = fail(:failure, pos, whole)
    error
  end

  # The error the `WHERE` condition has, with where the parser meets it, for a statement whose
  # clauses do not read: the condition comes before every clause, so its error is the
  # engine's whatever the clauses hold (`WHERE time > now-() - 1d GROUP BY time(1h)
  # ORDER BY host` fails at `()`, not at `host`).
  @spec condition_error(binary(), non_neg_integer(), binary(), binary()) :: positioned() | nil
  @doc false
  def condition_error(whole, at, masked_rest, rest) do
    with [{0, length}] <- Regex.run(~r/\A\s*WHERE\s+/i, masked_rest, return: :index),
         where = condition_text(rest, masked_rest, length),
         true <- where != "",
         {:error, reason} = error <- first_condition_error(whole, at, masked_rest, where) do
      positioned_condition_error(error, reason, whole)
    else
      _no_error_of_its_own -> nil
    end
  end

  # An error of the engine's stands where the parser meets it. A condition the double does not
  # read is refused first (position 0): what stands behind it may hold an error that the engine
  # meets only if the condition reads.
  defp positioned_condition_error(error, {:engine, body}, whole) do
    with pos when pos != nil <- InfluxQLError.position(body, whole), do: {pos, error}
  end

  defp positioned_condition_error(error, _refusal, _whole), do: {0, error}

  defp first_condition_error(whole, at, masked_rest, where) do
    with :ok <- check_where_call(whole, at, masked_rest, where),
         do: check_where(whole, at, masked_rest, where)
  end

  # The condition's text: up to the first clause that stands after a complete operand (a
  # `fill(` where an operand is wanted is a call in it).
  defp condition_text(rest, masked_rest, start) do
    condition = binary_part(masked_rest, start, byte_size(masked_rest) - start)

    stop =
      ~r/(?<![\w])(?:GROUP(?![\w])|ORDER\s+BY|S?LIMIT|S?OFFSET|tz\s*\(|fill\s*\()/i
      |> Regex.scan(condition, return: :index)
      |> Enum.find_value(byte_size(condition), fn [{from, _size}] ->
        if clause_position?(condition, from), do: from
      end)

    rest |> binary_part(start, stop) |> String.trim_trailing()
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
  # an operator or a connective it is a reserved word where one is wanted. A slash is an
  # operator unless it closes a regular expression (masked to underscores up to it).
  @spec completes_operand?(binary(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp completes_operand?(masked_rest, from, at),
    do: not (binary_part(masked_rest, from, at) =~ InfluxQLText.open_operand())

  # The error the parser meets at `unread` (`nil` for none): the clause keyword it stands at
  # is read for its own error, a `fill()` for its option and for what follows it.
  @spec check_swallowed(binary(), non_neg_integer(), binary(), unread() | nil) ::
          positioned() | nil
  @doc false
  def check_swallowed(_whole, _at, _masked_rest, nil), do: nil

  def check_swallowed(whole, at, masked_rest, {:fill, from}) do
    text = binary_part(whole, at, byte_size(masked_rest))

    case InfluxQLGroup.read_fill(text, from) do
      {:ok, stop} -> after_fill(whole, at, masked_rest, stop)
      {:bad_option, pos} -> fail(:fill, at + pos, whole)
      {:unclosed, pos} -> fail(:nom, at + pos, whole)
    end
  end

  def check_swallowed(whole, at, masked_rest, {from}) do
    text = binary_part(masked_rest, from, byte_size(masked_rest) - from)
    start = at + from

    cond do
      text =~ ~r/^ORDER\s+BY/i -> check_order(text, start, whole)
      text =~ ~r/^(?:S?LIMIT|S?OFFSET)(?![\w])/i -> check_count(text, start, whole)
      text =~ ~r/^GROUP(?![\w])/i -> check_group_keyword(text, start, whole)
      text =~ ~r/^ORDER(?![\w])/i -> fail(:nom, start, whole)
      true -> unread()
    end
  end

  # After a `fill()` that follows the condition only the clauses from `ORDER BY` on may stand
  # (verified): anything else, `GROUP BY` and another `fill()` included, is left over from
  # where it starts. The `tz()` clause is read by the double only in its place, after the
  # others.
  @spec after_fill(binary(), non_neg_integer(), binary(), non_neg_integer()) :: positioned() | nil
  defp after_fill(whole, at, masked_rest, stop) do
    rest = binary_part(masked_rest, stop, byte_size(masked_rest) - stop)
    text = String.trim_leading(rest)
    from = stop + byte_size(rest) - byte_size(text)

    cond do
      text == "" ->
        nil

      text =~ ~r/^(?:ORDER|S?LIMIT|S?OFFSET)(?![\w])/i ->
        check_swallowed(whole, at, masked_rest, {from})

      text =~ ~r/^tz\s*\(/i ->
        unread()

      true ->
        fail(:nom, at + from, whole)
    end
  end

  # A parse error of `kind` at `pos`, with the position as data.
  @spec fail(atom(), non_neg_integer(), binary()) :: positioned()
  @doc false
  def fail(kind, pos, whole),
    do: {pos, {:error, {:engine, InfluxQLError.syntax_error_body(kind, pos, whole)}}}

  # A statement the double does not read in that order: refused. Its position is 0, the start
  # of the statement, so that it is the leftmost of the errors and stands before every error of
  # the engine's: what the double has not read may hold an error that the engine meets first.
  @spec unread() :: positioned()
  @doc false
  def unread, do: {0, {:error, :unread_order}}

  # `ORDER BY` takes `time`, `ASC` or `DESC`: another name is "expected TIME
  # column", where it starts; a reserved word or a number "expected ASC, DESC
  # or TIME", at the end of `BY`.
  @spec check_order(binary(), non_neg_integer(), binary()) :: positioned()
  defp check_order(text, start, whole) do
    [{_at, size}, {_blank, blank}] = Regex.run(~r/^ORDER\s+BY(\s*)/i, text, return: :index)
    after_by = binary_part(text, size, byte_size(text) - size)

    cond do
      after_by =~ ~r/^(?:time|asc|desc)(?![\w])/i ->
        unread()

      InfluxQLText.reserved_start(after_by) == nil and after_by =~ ~r/^[A-Za-z_]/ ->
        fail(:order_time, start + size, whole)

      true ->
        fail(:order, start + size - blank, whole)
    end
  end

  # `LIMIT` and `OFFSET` take an unsigned integer: anything else after it is "expected
  # unsigned integer", where it starts; nothing leaves the clause unparsed.
  @spec check_count(binary(), non_neg_integer(), binary()) :: positioned()
  defp check_count(text, start, whole) do
    [_all, {word, word_size}, {at, _blank}, {_rest_at, rest_size}] =
      Regex.run(~r/^(S?LIMIT|S?OFFSET)\s*()(.*)$/is, text, return: :index)

    kind = text |> binary_part(word, word_size) |> String.downcase() |> count_clause()

    cond do
      rest_size == 0 -> fail(:nom, start, whole)
      binary_part(text, at, 1) =~ ~r/\d/ -> unread()
      true -> fail(kind, start + at, whole)
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
  @spec check_group_keyword(binary(), non_neg_integer(), binary()) :: positioned()
  defp check_group_keyword(text, start, whole) do
    cond do
      text =~ ~r/^GROUP(?:\s+BY)?$/i ->
        fail(:nom, start, whole)

      text =~ ~r/^GROUP\s+BY\s+$/i ->
        fail(:group, start + byte_size(text), whole)

      text =~ ~r/^GROUP\s+BY(?![\w])/i ->
        unread()

      true ->
        [{_at, size}] = Regex.run(~r/^GROUP\s*/i, text, return: :index)
        fail(:group_by, start + size, whole)
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
        masked = binary_part(masked_rest, from + length, byte_size(where))
        error_at = byte_size(where) - byte_size(after_error)

        case group_failure(kind, masked, error_at) do
          nil ->
            {:error, {:engine, InfluxQLError.where_error_body(kind, pos, at + from, whole)}}

          group ->
            {:error, {:engine, group_failure_body(group, at + from, at + from + length, whole)}}
        end

      {:ok, tokens} ->
        [{from, length}] = Regex.run(~r/\bWHERE\s+/i, masked_rest, return: :index)
        masked = binary_part(masked_rest, from + length, byte_size(where))
        InfluxQLParens.check(tokens, masked, at + from + length, at + from, whole)

      _refusal ->
        :ok
    end
  end

  # What the engine's parser does with a parenthesised condition that does not read inside: it
  # is no operand, and the error is that of the operand missing where the group stands (verified:
  # `WHERE (n > 1 'a')` is left unparsed from the `WHERE`, `AND (n > 1 'a')` fails at the end of
  # the `AND`, `n > (1e2 = 1)` at the end of the `>`). The group is the outermost one open where
  # the leftover stands, and a parenthesis after a name is a call, which reads its own errors.
  @spec group_failure(atom(), binary(), non_neg_integer()) ::
          :where_unparsed | {:operand_after, non_neg_integer()} | nil
  defp group_failure(:nom, masked, error_at) do
    with open when open != nil <- outermost_group(binary_part(masked, 0, error_at)) do
      before = masked |> binary_part(0, open) |> String.trim_trailing()

      cond do
        Regex.match?(~r/\A[ \t\r\n(+\-]*\z/, before) ->
          :where_unparsed

        Regex.match?(~r/(?:\A|[^\w])(?:AND|OR)\z/i, before) ->
          {:operand_after, byte_size(before)}

        Regex.match?(~r/(?:=~|!~|!=|<>|<=|>=|=|<|>)\z/, before) ->
          {:operand_after, byte_size(before)}

        true ->
          nil
      end
    end
  end

  defp group_failure(_kind, _masked, _error_at), do: nil

  # Where the outermost parenthesis that is no call and is still open at the end of `text` is.
  defp outermost_group(text) do
    ~r/[()]/
    |> Regex.scan(text, return: :index)
    |> List.flatten()
    |> Enum.reduce([], fn {at, 1}, open ->
      case :binary.at(text, at) do
        ?( -> [{call_or_group(text, at), at} | open]
        ?) -> Enum.drop(open, 1)
      end
    end)
    |> Enum.reverse()
    |> Enum.find_value(fn
      {:group, at} -> at
      {:call, _at} -> nil
    end)
  end

  defp call_or_group(text, at) do
    if text
       |> binary_part(0, at)
       |> String.trim_trailing()
       |> String.match?(~r/(?<![\w])(?!(?:and|or|not)\z)[A-Za-z_]\w*\s*\z/i),
       do: :call,
       else: :group
  end

  defp group_failure_body(:where_unparsed, where_at, _start, whole),
    do: InfluxQLError.syntax_error_body(:nom, where_at, whole)

  defp group_failure_body({:operand_after, offset}, _where_at, start, whole),
    do: InfluxQLError.syntax_error_body(:operand, start + offset, whole)

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

  # The `fill(...)` the clauses hold (verified): an option that is none of the engine's is
  # "invalid FILL option" where the option starts; one that starts like a number and is not
  # one leaves the statement unparsed from `fill` (see `InfluxQLGroup.read_fill/2`).
  @spec fill_error(binary(), non_neg_integer(), binary()) :: positioned() | nil
  @doc false
  def fill_error(whole, at, masked_rest) do
    case Regex.run(InfluxQLText.fill_call(), masked_rest, return: :index) do
      [{call_at, _size}] ->
        read_fill_error(whole, at, binary_part(whole, at, byte_size(masked_rest)), call_at)

      nil ->
        nil
    end
  end

  defp read_fill_error(whole, at, text, call_at) do
    case InfluxQLGroup.read_fill(text, call_at) do
      {:ok, _stop} -> nil
      {:bad_option, pos} -> fail(:fill, at + pos, whole)
      {:unclosed, pos} -> fail(:nom, at + pos, whole)
    end
  end

  # The clauses are read left to right, and the first operand that does not read ends the
  # statement: of a clause keyword swallowed by the clause before it (see `check_swallowed/4`),
  # a number past the unsigned range (see `check_unsigned/3`) and a `fill()` whose option
  # does not read (see `fill_error/3`), the one that stands first is the error (verified:
  # `LIMIT 99999999999999999999 SLIMIT x` is the overflow, `fill(x) ORDER BY y` the option).
  @spec check_operands(binary(), non_neg_integer(), binary(), unread() | nil) ::
          :ok | {:error, term()}
  @doc false
  def check_operands(whole, at, masked_rest, swallowed) do
    case Enum.reject(
           [
             check_swallowed(whole, at, masked_rest, swallowed),
             check_unsigned(whole, at, masked_rest),
             fill_error(whole, at, masked_rest)
           ],
           &is_nil/1
         ) do
      [] -> :ok
      errors -> first_error(errors)
    end
  end

  @doc """
  The first of the `checks` (functions that answer `:ok` or an error) that fails, or, when it
  fails with a parse error of the engine's, the parse error of the checks after it that stands
  further left in the statement: the parser reads left to right and stops at the first
  error, whichever check finds it (`WHERE time > now-() - 1d GROUP BY time(1h) fill(- x)`
  fails at `()`, not at `x`). A check after the first that raises has no say. A `{:final,
  check}` reads a stretch of the statement in full (a call in the condition, whose errors
  all stand inside it): its parse error is the answer.
  """
  @spec earliest([check() | {:final, check()}], binary()) :: :ok | {:error, term()}
  def earliest([], _whole), do: :ok

  def earliest([{:final, check} | checks], whole) do
    case check.() do
      {:error, {:engine, _body}} = error -> error
      other -> earliest_after(other, checks, whole)
    end
  end

  def earliest([check | checks], whole), do: earliest_after(check.(), checks, whole)

  defp earliest_after(result, checks, whole) do
    case result do
      :ok ->
        earliest(checks, whole)

      {:error, {:engine, body}} = error ->
        case position(body, whole) do
          nil -> error
          at -> further_left(checks, whole, {error, at})
        end

      error ->
        error
    end
  end

  defp further_left(checks, whole, best) do
    checks
    |> Enum.reduce(best, fn check, {_error, at} = best ->
      with {:error, {:engine, body}} = error <- guarded(check),
           pos when is_integer(pos) <- position(body, whole),
           true <- pos < at do
        {error, pos}
      else
        _not_further_left -> best
      end
    end)
    |> elem(0)
  end

  defp position(body, whole), do: InfluxQLError.position(body, whole)

  defp guarded(check) do
    check.()
  rescue
    _error -> :ok
  end

  @doc "The error among `errors` that the parser meets first: the one at the leftmost position."
  @spec first_error([positioned(), ...]) :: {:error, term()}
  def first_error(errors) do
    {_pos, error} = Enum.min_by(errors, fn {pos, _error} -> pos end)
    error
  end

  # `LIMIT` and `OFFSET` are unsigned 64-bit integers; a longer number is a
  # parse error at the end of its digits. One that fits but not the signed
  # range is a planning error (`check_window/1`).
  @spec check_unsigned(binary(), non_neg_integer(), binary()) :: positioned() | nil
  @doc false
  def check_unsigned(whole, at, masked_rest) do
    # Read from the text, not from the clauses: a clause behind one that is overflowing
    # may not read at all, and the overflow stands first.
    ~r/(?<![\w])(?:limit|offset|slimit|soffset)\s+(\d+)/i
    |> Regex.scan(masked_rest, return: :index)
    |> Enum.find_value(fn [_all, {from, length}] ->
      if masked_rest |> binary_part(from, length) |> String.to_integer() > SQLLimits.uint64_max(),
        do: fail(:unsigned, at + from + length, whole)
    end)
  end
end
