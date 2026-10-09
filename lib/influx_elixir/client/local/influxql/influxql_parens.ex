defmodule InfluxElixir.Client.Local.InfluxQLParens do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  # The parentheses of an InfluxQL `WHERE`, as the engine's parser reads them
  # (verified). A `)` that closes nothing ends the condition: the statement is
  # left from it. A `(` that is never closed makes the parser give up on the
  # parenthesised condition, and the error depends on what stands before it, as
  # for a reserved word where an operand is wanted
  # (see `InfluxQLTokens`): at the start
  # the whole `WHERE` is left unparsed, after a comparison or a connective the
  # operand is missing, after a binary `+` or `-` the engine fails from the
  # parenthesis, after an operand the parenthesis is left over. The last
  # parenthesis left open decides.

  alias InfluxElixir.Client.Local.{InfluxQLCheck, InfluxQLError, InfluxQLLex, InfluxQLTokens}

  require InfluxQLLex

  # `now()` has parentheses of its own, which are no grouping.
  @parens ~q/(?<![\w])now\s*\(\s*\)|[()]/i

  @doc """
  `nil` when the parentheses of the `WHERE` balance, else the engine's error with its position.
  `tokens` are those of the condition, `masked` its text with the inside of
  literals blanked, `start` where it starts in `whole` (the statement as
  sent) and `where_at` where its `WHERE` does.
  """
  @spec check(list(), binary(), non_neg_integer(), non_neg_integer(), binary()) ::
          InfluxQLCheck.positioned() | nil
  def check(tokens, masked, start, where_at, whole) do
    case scan(masked) do
      :balanced ->
        nil

      {:excess, offset} ->
        InfluxQLCheck.fail(:nom, start + offset, whole)

      {:open, offset, ordinal} ->
        kind = tokens |> before_open(ordinal) |> InfluxQLTokens.reserved_kind()
        {_key, body} = InfluxQLError.where_error(kind, start + offset, where_at, whole)

        # A `(` left open is found when the condition ends, not where it stands: whatever the
        # parser meets inside the condition comes first (verified: a call it refuses, `fill(1)`,
        # is the error before, inside or after an open parenthesis).
        InfluxQLCheck.found_at({0, {:error, {:engine, body}}}, start + byte_size(masked))
    end
  end

  @doc "Whether a `)` in `masked` closes nothing: the condition ends there."
  @spec excess_close?(binary()) :: boolean()
  def excess_close?(masked), do: excess_offset(masked) != nil

  @doc "Where the first `)` in `masked` that closes nothing stands, `nil` for none."
  @spec excess_offset(binary()) :: non_neg_integer() | nil
  def excess_offset(masked) do
    case scan(masked) do
      {:excess, offset} -> offset
      _balanced_or_open -> nil
    end
  end

  # The first `)` that closes nothing, else the last `(` left open with the
  # number of `(` before it.
  @spec scan(binary()) :: :balanced | {:excess, non_neg_integer()} | {:open, integer(), integer()}
  defp scan(masked) do
    parens =
      for [{at, 1}] <- Regex.scan(@parens, masked, return: :index),
          do: {at, :binary.at(masked, at)}

    walk(parens, [], 0, masked, nil)
  end

  # `closed` is where the last `)` ended: a `(` right after it is left over from itself.
  defp walk([], [], _count, _masked, _closed), do: :balanced

  defp walk([], [{offset, ordinal} | _outer], _count, _masked, _closed),
    do: {:open, offset, ordinal}

  defp walk([{at, ?(} | rest], open, count, masked, closed) do
    if closed != nil and
         InfluxQLLex.trim_both_blanks(binary_part(masked, closed, at - closed)) == "",
       do: {:excess, at},
       else: walk(rest, [{at, count} | open], count + 1, masked, nil)
  end

  defp walk([{at, ?)} | _rest], [], _count, _masked, _closed), do: {:excess, at}

  # A pair with nothing in it is as unreadable as a `(` left open, unless it is the call of a
  # function with no arguments (`abs()`: the planner has its say).
  defp walk([{at, ?)} | rest], [{offset, ordinal} | outer], count, masked, _closed) do
    inside = binary_part(masked, offset + 1, at - offset - 1)

    if InfluxQLLex.trim_both_blanks(inside) == "" and not call?(masked, offset),
      do: {:open, offset, ordinal},
      else: walk(rest, outer, count, masked, at + 1)
  end

  defp call?(masked, offset),
    do: masked |> binary_part(0, offset) |> String.match?(~q/[A-Za-z_]\w*$/)

  # The tokens before the `(` that has `ordinal` before it, latest first.
  @spec before_open(list(), non_neg_integer()) :: list()
  defp before_open(tokens, ordinal), do: before_open(tokens, ordinal, [])

  defp before_open([{:raw, "("} | _rest], 0, acc), do: acc

  defp before_open([{:raw, "("} = token | rest], n, acc),
    do: before_open(rest, n - 1, [token | acc])

  defp before_open([token | rest], n, acc), do: before_open(rest, n, [token | acc])

  # ---------------------------------------------------------------------------
  # A condition in parentheses beside arithmetic
  # ---------------------------------------------------------------------------
  #
  # The engine's parser reads a parenthesised condition (`(w > 1)`, `(a AND b)`: a comparison
  # or a connective inside) as a complete operand of a comparison, never of arithmetic
  # (verified). Where the group would be an operand of arithmetic the parse stops:
  #
  #   * after it, an operator `+ - * /` is left over, from the operator (`v > (w > 1) + 1` is
  #     `Nom("+ 1")`)
  #   * as the operand of an operator or a sign the parser fails as it does for a word it cannot
  #     read there (see `InfluxQLTokens.reserved_kind/1`): after `+` or `-` a failure from the
  #     start of the operand, signs included (`v > 1 + (w > 1)` is `Failure("(w > 1)")`, `v + -(w
  #     > 1)` is `Failure("-(w > 1)")`), after `*` or `/` the operator is left over, after a
  #     comparison or a connective the operand is missing, at the start of the condition it is
  #     left unparsed
  #   * inside the arguments of a call it is no error of the parser's (`abs((w > 1) + 1)`)
  #
  # One pass over the masked text finds the first such place. A group is a condition when a
  # comparison operator or `AND` / `OR` stands in it (or in a group in it, but not in the
  # arguments of a call). The characters `% & | ^` are not read by the double at all.

  @comparison_starts ~c"=<>!"
  @word_bytes ~c"_.0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  @typedoc "Where a parenthesised condition beside arithmetic stops the parse, and how."
  @type group_error :: {atom(), non_neg_integer(), non_neg_integer()}

  @doc """
  The first place in `masked` (a condition with its literals blanked) where a parenthesised
  condition stands beside arithmetic, as `{kind, offset, limit}`: the kind of error the parser meets
  there (see `InfluxQLError.where_error/4`), the offset it stands at and the offset past which the
  text reads (the end of the group: an error of the text inside the group is met first); `nil` for
  none.
  """
  @spec group_error(binary()) :: group_error() | nil
  def group_error(masked) do
    case scan(masked, 0, start()) do
      %{found: nil} -> nil
      %{found: {_key, kind, offset, limit}} -> {kind, offset, limit}
    end
  end

  @doc """
  The error of a text that fails at `error_at` inside a group that is the operand of arithmetic,
  as `{kind, offset}` (verified: the parser gives up on the whole operand, whatever fails in it):
  a failure from the start of the operand for the innermost group after `+` or `-`, which no
  enclosing group undoes, else the operator the outermost group after `*` or `/` is left over
  from. `nil` when no such group is open at `error_at`.
  """
  @spec enclosing_error(binary(), non_neg_integer()) :: {atom(), non_neg_integer()} | nil
  def enclosing_error(masked, error_at) do
    %{stack: frames} = scan(binary_part(masked, 0, error_at), 0, start())
    groups = Enum.reject(frames, & &1.call?)

    case Enum.find(groups, &match?(%{before: {:reserved_failure, _offset}}, &1)) do
      %{before: before} -> before
      nil -> outermost_multiplicative(groups)
    end
  end

  defp outermost_multiplicative(groups) do
    case List.last(groups) do
      %{before: {:nom, _offset} = before} -> before
      _other -> nil
    end
  end

  defp start do
    %{
      stack: [],
      calls: 0,
      prev: :none,
      before: {:where_unparsed, 0},
      operand_at: nil,
      after_group: false,
      found: nil
    }
  end

  # `prev` is the kind of the token before (`:none`, `:open`, `:close`, `:operand`, `{:word,
  # text}`, `:comma`, `:comparison`, `:connective`, `:additive`, `:multiplicative`, `:sign`),
  # `before` the error a group would be as the operand that follows the last operator
  # (`{kind, offset}`, the offset where the operand starts when it is not the operator's),
  # `operand_at` where its signs start, `after_group` whether the token just read closed a
  # condition, `found` the error with the lowest position so far.
  defp scan(masked, at, state) do
    case masked do
      <<_before::binary-size(at), c, _rest::binary>> when InfluxQLLex.is_blank(c) ->
        scan(masked, at + 1, state)

      <<_before::binary-size(at), rest::binary>> when rest != "" ->
        read(rest, at, masked, state)

      _end ->
        state
    end
  end

  # A `)` that closes nothing ends the condition, and so does a `,` outside every parenthesis.
  defp read(<<?), _rest::binary>>, _at, _masked, %{stack: []} = state), do: state
  defp read(<<?,, _rest::binary>>, _at, _masked, %{stack: []} = state), do: state

  defp read(<<?(, _rest::binary>>, at, masked, state) do
    call? = match?({:word, _text}, state.prev)
    arithmetic? = state.prev in [:additive, :multiplicative, :sign]
    {kind, offset} = state.before

    frame = %{
      call?: call?,
      condition?: false,
      before:
        if(arithmetic? and not call?,
          do: {kind, group_offset(kind, offset, state.operand_at || at)}
        )
    }

    state = %{
      state
      | stack: [frame | state.stack],
        calls: if(call?, do: state.calls + 1, else: state.calls),
        prev: :open,
        after_group: false
    }

    scan(masked, at + 1, state)
  end

  defp read(<<?), _rest::binary>>, at, masked, %{stack: [frame | stack]} = state) do
    state = %{
      state
      | stack: stack,
        calls: if(frame.call?, do: state.calls - 1, else: state.calls),
        prev: :close,
        operand_at: nil,
        after_group: false
    }

    scan(masked, at + 1, if(frame.call?, do: state, else: close_group(frame, at, state)))
  end

  defp read(<<?,, _rest::binary>>, at, masked, state),
    do: scan(masked, at + 1, %{state | prev: :comma, after_group: false})

  defp read(<<quote, rest::binary>>, at, masked, state) when quote in [?', ?"],
    do: scan(masked, at + 1 + literal_size(rest, quote), operand(state))

  defp read(<<?/, rest::binary>>, at, masked, %{prev: :regex_operator} = state),
    do: scan(masked, at + 1 + literal_size(rest, ?/), operand(state))

  defp read(<<two::binary-size(2), _rest::binary>>, at, masked, state)
       when two in ["=~", "!~", "!=", "<>", "<=", ">="],
       do: scan(masked, at + 2, comparison(state, two))

  defp read(<<c, _rest::binary>>, at, masked, state) when c in @comparison_starts,
    do: scan(masked, at + 1, comparison(state, <<c>>))

  defp read(<<c, _rest::binary>>, at, masked, state) when c in ~c"+-*/",
    do: scan(masked, at + 1, arithmetic(state, c, at))

  defp read(<<c, _rest::binary>> = text, at, masked, state) when c in @word_bytes do
    size = word_size(text)
    scan(masked, at + size, word(state, binary_part(text, 0, size)))
  end

  defp read(<<_other, _rest::binary>>, at, masked, state),
    do: scan(masked, at + 1, operand(state))

  # A group that holds a condition and is no argument of a call: where it is the operand of an
  # operator or a sign it is the error of that place, else what follows it is looked at.
  defp close_group(frame, at, %{stack: stack} = state) do
    state = pass_condition(state, stack, frame.condition?)

    cond do
      not frame.condition? or state.calls > 0 -> state
      frame.before != nil -> found(state, frame.before, at)
      true -> %{state | after_group: true}
    end
  end

  # A condition inside a group makes the group one (not through the arguments of a call).
  defp pass_condition(state, _stack, false), do: state
  defp pass_condition(state, [], true), do: state
  defp pass_condition(state, [%{call?: true} | _outer], true), do: state

  defp pass_condition(state, [outer | stack], true),
    do: %{state | stack: [%{outer | condition?: true} | stack]}

  defp comparison(state, text) do
    state
    |> mark_condition()
    |> Map.merge(%{
      prev: if(text in ["=~", "!~"], do: :regex_operator, else: :comparison),
      before: {:reserved_operand, 0},
      operand_at: nil,
      after_group: false
    })
  end

  defp word(state, text) do
    if String.upcase(text) in ["AND", "OR"] do
      state
      |> mark_condition()
      |> Map.merge(%{
        prev: :connective,
        before: {:reserved_operand, 0},
        operand_at: nil,
        after_group: false
      })
    else
      %{operand(state) | prev: {:word, text}}
    end
  end

  defp operand(state), do: %{state | prev: :operand, operand_at: nil, after_group: false}

  defp mark_condition(%{stack: [top | stack]} = state),
    do: %{state | stack: [%{top | condition?: true} | stack]}

  defp mark_condition(state), do: state

  # An operator after an operand or a group is binary; a `+` or `-` anywhere else is a sign.
  defp arithmetic(state, c, at) do
    binary? = state.prev in [:close, :operand] or match?({:word, _text}, state.prev)
    state = if state.after_group and binary?, do: found(state, {:nom, at}, at), else: state

    cond do
      binary? and c in ~c"+-" ->
        %{
          state
          | prev: :additive,
            before: {:reserved_failure, 0},
            operand_at: nil,
            after_group: false
        }

      binary? or c in ~c"*/" ->
        %{state | prev: :multiplicative, before: {:nom, at}, operand_at: nil, after_group: false}

      true ->
        %{state | prev: :sign, operand_at: state.operand_at || at, after_group: false}
    end
  end

  # Where the error of a group as an operand stands: the operator it is left over from, the
  # start of the condition for one left unparsed, else where the operand (its signs included)
  # starts.
  defp group_offset(:nom, operator_at, _operand_at), do: operator_at
  defp group_offset(:where_unparsed, _offset, _operand_at), do: 0
  defp group_offset(_kind, _offset, operand_at), do: operand_at

  # The error with the lowest position of those found.
  defp found(%{found: found} = state, {kind, offset}, limit) do
    if found == nil or offset < elem(found, 0),
      do: %{state | found: {offset, kind, offset, limit}},
      else: state
  end

  # The size of a quoted literal or a regular expression whose contents are masked, after its
  # opening character: up to and with the closing one.
  defp literal_size(rest, closing) do
    case :binary.match(rest, <<closing>>) do
      {at, 1} -> at + 1
      :nomatch -> byte_size(rest)
    end
  end

  defp word_size(text), do: word_size(text, 0)

  defp word_size(<<c, rest::binary>>, size) when c in @word_bytes, do: word_size(rest, size + 1)
  defp word_size(_text, size), do: size
end
