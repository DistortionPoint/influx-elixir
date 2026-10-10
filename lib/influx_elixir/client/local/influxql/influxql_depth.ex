defmodule InfluxElixir.Client.Local.InfluxQLDepth do
  @moduledoc false
  # How deep a `WHERE` condition is, measured before anything reads it, so that one the engine
  # cannot answer is refused by name and cheaply.
  #
  # InfluxDB 3 Core 3.10.1 overflows its stack (the server dies) on a condition nested or
  # chained deep enough, and the double, which never overflows, would answer what the engine
  # never answers. The engine's depths were measured with Core in a container of 2 GB and 2
  # CPUs, every request under 8 KB (`docs/design/2026-10-09_influxql-fuzz-fourth-review.md`):
  #
  #     shape                                        answers at     dies at (or no answer in 20 s)
  #     abs(abs(...v...)) = 5                        475 (18 s)     487 (no answer in 20 s)
  #     (v + (v + ... v)) > 0                        736            900
  #     (ok = (ok = ... (v > 1)))                    700            900
  #     ok = (v > 0 AND ok = (...ok = false))       400            412
  #     v + v + ... + v > 0                          818 terms      825
  #     ((((v)))) = 5                                1,500          1,800
  #     -(-(...v...)) = 5                            800 (15 s)     825
  #     b AND b AND ... / b OR b OR ...              1,290 / 1,560  (none found under 8 KB)
  #     (b AND (b AND ... b))                        960            (none found under 8 KB)
  #     v = - - - ... 5 (signs before a number)      2,600          (none found under 8 KB)
  #
  # No one number of levels fits them: a call is slow and a flat chain is not, and 800
  # `abs(1)` added up and 400 groups that alternate (both verified) answer a few percent under
  # where the engine dies. (The contract pins 600 and 300, well inside, so a run on the engine
  # never brings it down.) So each node of the condition costs what the shapes above say it
  # does, the cost of a path from the root is the sum of its nodes, and a condition whose most
  # costly path is past `@budget` is refused. The budget is the cost of 800 `abs(1)` added up
  # (a comparison, 799 additions and a call: 8,017), and each cost is the engine's cliff over
  # it:
  #
  #   * an arithmetic operator 10 (the sum of `v` dies at 825 terms)
  #   * a parenthesis 6 (a bare parenthesis answers at 1,500, 1,336 are allowed; it dies by 1,800)
  #   * a comparison 7 and `AND`/`OR` 7 (a group that alternates, with its parenthesis, 20)
  #   * a call 20 (475 nested calls answer in 18 s, 487 do not answer in 20 s)
  #   * a sign 6, with its parenthesis 12 (800 answer in 15 s)
  #
  # Mixed shapes were measured too, each near the budget (see the design document); none died.
  #
  # A left-associative chain nests to the left (`a + b + c` is `(a + b) + c`), so a chain of
  # `n` operators costs `n` operators: the walk below folds an operator into the cost of its
  # left side as it is met, and stops at the first that is past the budget. It reads the
  # condition once, in a pass that needs no stack deeper than the budget, and builds nothing.
  #
  # The walk is a precedence climb over the masked text, not a parser: what it cannot read it
  # leaves, and the parser that comes after gives the engine's error. Only the cost of what it
  # does read is counted.

  alias InfluxElixir.Client.Local.InfluxQLLex

  @budget 8_020
  @arith 10
  @comparison 7
  @connective 7
  @parenthesis 6
  @call 20
  @sign 6

  @message "unsupported InfluxQL (a condition nested or chained deeper than " <>
             "#{@budget} units, where InfluxDB 3 Core 3.10.1 overflows its stack: " <>
             "a call counts #{@call}, a sign #{@sign}, an arithmetic operator #{@arith}, a " <>
             "comparison #{@comparison}, AND/OR #{@connective}, a parenthesis #{@parenthesis})"

  @doc "The refusal, as the message of the parser's error."
  @spec message() :: binary()
  def message, do: @message

  @doc "The cost beyond which a condition is refused."
  @spec budget() :: pos_integer()
  def budget, do: @budget

  @doc """
  `:ok`, or the refusal, for the text after the sources of a `SELECT` (literals masked,
  comments blanked): it is read only when it starts with `WHERE`.
  """
  @spec check(binary()) :: :ok | {:error, binary()}
  def check(masked_rest) do
    case where_start(InfluxQLLex.trim_blanks(masked_rest)) do
      nil ->
        :ok

      condition ->
        try do
          _read = expression(condition, 0, 1)
          :ok
        catch
          :too_deep -> {:error, @message}
        end
    end
  end

  @spec where_start(binary()) :: binary() | nil
  defp where_start(<<w, h, e, r, e2, rest::binary>>)
       when w in [?W, ?w] and h in [?H, ?h] and e in [?E, ?e] and r in [?R, ?r] and
              e2 in [?E, ?e] do
    case rest do
      <<c, _more::binary>> when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ -> nil
      _other -> rest
    end
  end

  defp where_start(_text), do: nil

  # An expression of operators at least `least` strong; the cost of its most costly path and
  # the text left. `above` is the cost of the nodes that are known to stand over it.
  @spec expression(binary(), non_neg_integer(), pos_integer()) :: {non_neg_integer(), binary()}
  defp expression(text, above, least) do
    {left, rest} = operand(text, above)
    climb(left, rest, above, least)
  end

  defp climb(left, text, above, least) do
    case operator(InfluxQLLex.trim_blanks(text)) do
      {strength, weight, rest} when strength >= least ->
        deeper = above + weight
        past?(deeper)
        {right, rest} = expression(rest, deeper, strength + 1)
        cost = weight + max(left, right)
        past?(above + cost)
        climb(cost, rest, above, least)

      _not_an_operator_or_weaker ->
        {left, text}
    end
  end

  # The operator the text starts with: its strength (what binds tighter has more), its cost
  # and the text after it.
  @spec operator(binary()) :: {pos_integer(), pos_integer(), binary()} | nil
  defp operator(<<a, n, d, c, rest::binary>>)
       when a in [?A, ?a] and n in [?N, ?n] and d in [?D, ?d] do
    if word_end?(c), do: {2, @connective, <<c, rest::binary>>}
  end

  defp operator(<<o, r, c, rest::binary>>) when o in [?O, ?o] and r in [?R, ?r] do
    if word_end?(c), do: {1, @connective, <<c, rest::binary>>}
  end

  defp operator(<<o::binary-size(2), rest::binary>>)
       when o in ["=~", "!~", "!=", "<>", "<=", ">="],
       do: {3, @comparison, rest}

  defp operator(<<c, rest::binary>>) when c in [?=, ?<, ?>], do: {3, @comparison, rest}
  defp operator(<<c, rest::binary>>) when c in [?+, ?-, ?&, ?|, ?^], do: {4, @arith, rest}
  defp operator(<<c, rest::binary>>) when c in [?*, ?/, ?%], do: {5, @arith, rest}
  defp operator(_text), do: nil

  defp word_end?(c), do: not (c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c > 127)

  # What stands where an operand is wanted: a sign before it, a parenthesis, a quoted text
  # (its inside is masked), a regular expression (after `=~`), a call, or a word or number.
  @spec operand(binary(), non_neg_integer()) :: {non_neg_integer(), binary()}
  defp operand(text, above) do
    case InfluxQLLex.trim_blanks(text) do
      <<sign, rest::binary>> when sign in [?+, ?-] ->
        past?(above + @sign)
        {cost, rest} = operand(rest, above + @sign)
        {@sign + cost, rest}

      <<?(, rest::binary>> ->
        past?(above + @parenthesis)
        {cost, rest} = expression(rest, above + @parenthesis, 1)
        {@parenthesis + cost, close(rest)}

      <<quote, rest::binary>> when quote in [?', ?"] ->
        {0, after_quote(rest, quote)}

      <<?/, rest::binary>> ->
        {0, after_quote(rest, ?/)}

      <<c, _rest::binary>> = text when c in [?), ?,] ->
        {0, text}

      "" ->
        {0, ""}

      text ->
        word(text, above)
    end
  end

  # A word or a number, and the call its parenthesis opens.
  @spec word(binary(), non_neg_integer()) :: {non_neg_integer(), binary()}
  defp word(text, above) do
    case after_word(text) do
      ^text ->
        {0, text}

      rest ->
        case InfluxQLLex.trim_blanks(rest) do
          <<?(, args::binary>> ->
            past?(above + @call)
            {cost, rest} = arguments(args, above + @call, 0)
            {@call + cost, rest}

          _no_call ->
            {0, rest}
        end
    end
  end

  # The arguments of a call, up to its closing parenthesis.
  @spec arguments(binary(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), binary()}
  defp arguments(text, above, widest) do
    {cost, rest} = expression(text, above, 1)

    case InfluxQLLex.trim_blanks(rest) do
      <<?,, more::binary>> -> arguments(more, above, max(widest, cost))
      <<?), more::binary>> -> {max(widest, cost), more}
      _unread -> {max(widest, cost), rest}
    end
  end

  @spec close(binary()) :: binary()
  defp close(text) do
    case InfluxQLLex.trim_blanks(text) do
      <<?), rest::binary>> -> rest
      other -> other
    end
  end

  @spec after_quote(binary(), byte()) :: binary()
  defp after_quote(text, quote) do
    case :binary.split(text, <<quote>>) do
      [_inside, rest] -> rest
      [_unclosed] -> ""
    end
  end

  # The text after the characters of a word, a number, a duration, a name with dots or a cast
  # (`v::field`): everything up to a blank or a character of the grammar.
  @spec after_word(binary()) :: binary()
  defp after_word(<<c, rest::binary>> = text) do
    if c in ~c" \t\n\r(),+-*/%&|^=!<>'\"~",
      do: text,
      else: after_word(rest)
  end

  defp after_word(<<>>), do: <<>>

  @spec past?(non_neg_integer()) :: :ok
  defp past?(cost) when cost > @budget, do: throw(:too_deep)
  defp past?(_cost), do: :ok
end
