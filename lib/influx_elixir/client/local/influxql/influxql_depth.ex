defmodule InfluxElixir.Client.Local.InfluxQLDepth do
  @moduledoc false
  # How deep the expressions of a statement are, measured before anything reads them, so that
  # one the engine cannot answer is refused by name and cheaply.
  #
  # InfluxDB 3 Core 3.10.1 overflows its stack (the server dies) on an expression nested or
  # chained deep enough, and the double, which never overflows, would answer what the engine
  # never answers. The engine's depths were measured with Core in a container of 2 GB and 2
  # CPUs, every request under 8 KB (`docs/design/2026-10-09_influxql-fuzz-fourth-review.md` for
  # the `WHERE`, `docs/design/2026-10-09_sql-influxql-fuzz-fifth-review.md` for the rest). The
  # expressions of two places are read, each with the costs of its own, since the engine
  # converts each in its own recursion:
  #
  #   * the `WHERE` condition
  #   * each item of the select list
  #
  # (`GROUP BY time(...)` takes an expression too, and the double reads none of them: any
  # expression there is refused by name by `InfluxQLGroup`. The engine answers 1,500
  # parentheses and 2,600 terms of a sum there and dies at 2,500 parentheses, so what is
  # refused is refused whatever its depth.)
  #
  # `WHERE` (last answer, first death or no answer in 20 s):
  #
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
  # A select item (`select <item> from m`):
  #
  #     abs(abs(...n...))                            625 (13 s)     650
  #     ((((n))))                                    1,500          1,900
  #     n + n + ... + n                              800 terms      850
  #     n + (n + (... n))                            700            1,000
  #     -(-(...n...))                                800            1,000
  #     abs(n) + abs(n) + ... (800 terms)            answers        (not searched)
  #     200 abs( around a sum of 500; 300 -( around 200 abs( around a sum of 200;
  #     1,000 ( around a sum of 280                  answer         (not searched)
  #
  # No one number of levels fits them: a call is slow and a flat chain is not, and a
  # parenthesis that stands where an operand does (`n + (...)`) costs the engine far less than
  # one that stands alone. So each node costs what the shapes above say it does, the cost of a
  # path from the root is the sum of its nodes, and an expression whose most costly path is past
  # the `budget` of its place is refused. The budget of the `WHERE` is the cost of 800 `abs(1)`
  # added up (a comparison, 799 additions and a call: 8,017); each cost of a place is the
  # engine's cliff over it, kept under the last depth the engine was seen to answer:
  #
  #   | place | budget  | `+ - *` | `( )` | `( )` after `+` | call | sign | `=`, `AND`, `OR` |
  #   |-------|---------|---------|-------|-----------------|------|------|------------------|
  #   | WHERE | 8,020   | 10      | 6     | 6               | 20   | 6    | 7                |
  #   | item  | 160,100 | 200     | 100   | 20              | 256  | 100  | 140              |
  #
  # (An item is costed in a finer unit than the `WHERE`: the engine takes 625 calls nested in an
  # item where the `WHERE`'s 20 allow 401, and the call is 12.8 of the units in which an
  # operator is 10. Each bound is a depth the engine answers: 625 calls, 1,601 parentheses, 800
  # terms, 727 levels of `n + (...)`, 800 levels of `-(...)`. A parenthesis after an operator
  # costs the engine far less than one that stands alone.) Mixed shapes were measured too, each
  # near the budget (see the design documents); none died.
  #
  # A left-associative chain nests to the left (`a + b + c` is `(a + b) + c`), so a chain of
  # `n` operators costs `n` operators: the walk below folds an operator into the cost of its
  # left side as it is met, and stops at the first that is past the budget. It reads the
  # text once, in a pass that needs no stack deeper than the budget, and builds nothing.
  #
  # The walk is a precedence climb over the masked text, not a parser: what it cannot read it
  # leaves, and the parser that comes after gives the engine's error. Only the cost of what it
  # does read is counted.

  alias InfluxElixir.Client.Local.InfluxQLLex

  # `after_operator` is the cost of `(` that stands where an operand does, after an operator.
  @places %{
    where: %{
      budget: 8_020,
      arith: 10,
      comparison: 7,
      connective: 7,
      paren: 6,
      after_operator: 6,
      call: 20,
      sign: 6,
      subject: "a condition"
    },
    item: %{
      budget: 160_100,
      arith: 200,
      comparison: 140,
      connective: 140,
      paren: 100,
      after_operator: 20,
      call: 256,
      sign: 100,
      subject: "a select item"
    }
  }

  @doc """
  `:ok`, or the refusal, for a statement: its select list (`items`, the text between `SELECT`
  and `FROM`), and the text after the sources (literals masked, comments blanked), where the
  `WHERE` is read when it starts the text.
  """
  @spec check(binary(), binary()) :: :ok | {:error, binary()}
  def check(masked_items, masked_rest) do
    trimmed = InfluxQLLex.trim_blanks(masked_rest)

    with :ok <- check_items(masked_items), do: check_where(trimmed)
  end

  defp check_where(trimmed) do
    case where_start(trimmed) do
      nil -> :ok
      condition -> guard(:where, fn -> expression(condition, 0, 1, @places.where, false) end)
    end
  end

  # The expressions of the select list (`a, b + 1 AS c`), each read with the costs of an item.
  defp check_items(text), do: guard(:item, fn -> items(text, @places.item) end)

  defp items(text, costs) do
    {_cost, rest} = expression(text, 0, 1, costs, false)

    case rest |> InfluxQLLex.trim_blanks() |> skip_alias() |> InfluxQLLex.trim_blanks() do
      <<?,, more::binary>> -> items(more, costs)
      _end_of_list -> :ok
    end
  end

  # `AS name` or `AS "name"` after an item.
  defp skip_alias(<<a, s, c, rest::binary>> = text)
       when a in [?A, ?a] and s in [?S, ?s] do
    if word_end?(c) do
      case InfluxQLLex.trim_blanks(<<c, rest::binary>>) do
        <<quote, more::binary>> when quote in [?', ?"] -> after_quote(more, quote)
        name -> after_word(name)
      end
    else
      text
    end
  end

  defp skip_alias(text), do: text

  defp guard(place, fun) do
    fun.()
    :ok
  catch
    :too_deep -> {:error, message(place)}
  end

  defp message(:where) do
    costs = @places.where

    "unsupported InfluxQL (a condition nested or chained deeper than " <>
      "#{costs.budget} units, where InfluxDB 3 Core 3.10.1 overflows its stack: " <>
      "a call counts #{costs.call}, a sign #{costs.sign}, an arithmetic operator #{costs.arith}, " <>
      "a comparison #{costs.comparison}, AND/OR #{costs.connective}, " <>
      "a parenthesis #{costs.paren})"
  end

  defp message(place) do
    costs = @places[place]

    "unsupported InfluxQL (#{costs.subject} nested or chained deeper than " <>
      "#{costs.budget} units, where InfluxDB 3 Core 3.10.1 overflows its stack: " <>
      "a call counts #{costs.call}, a sign #{costs.sign}, an arithmetic operator #{costs.arith}, " <>
      "a parenthesis #{costs.paren}, after an operator #{costs.after_operator})"
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
  # the text left. `above` is the cost of the nodes that are known to stand over it, and
  # `after_operator?` whether it is the right operand of an operator.
  @spec expression(binary(), non_neg_integer(), pos_integer(), map(), boolean()) ::
          {non_neg_integer(), binary()}
  defp expression(text, above, least, costs, after_operator?) do
    {left, rest} = operand(text, above, costs, after_operator?)
    climb(left, rest, above, least, costs)
  end

  defp climb(left, text, above, least, costs) do
    case operator(InfluxQLLex.trim_blanks(text), costs) do
      {strength, weight, rest} when strength >= least ->
        deeper = above + weight
        past?(deeper, costs)
        {right, rest} = expression(rest, deeper, strength + 1, costs, true)
        cost = weight + max(left, right)
        past?(above + cost, costs)
        climb(cost, rest, above, least, costs)

      _not_an_operator_or_weaker ->
        {left, text}
    end
  end

  # The operator the text starts with: its strength (what binds tighter has more), its cost
  # and the text after it.
  @spec operator(binary(), map()) :: {pos_integer(), pos_integer(), binary()} | nil
  defp operator(<<a, n, d, c, rest::binary>>, costs)
       when a in [?A, ?a] and n in [?N, ?n] and d in [?D, ?d] do
    if word_end?(c), do: {2, costs.connective, <<c, rest::binary>>}
  end

  defp operator(<<o, r, c, rest::binary>>, costs) when o in [?O, ?o] and r in [?R, ?r] do
    if word_end?(c), do: {1, costs.connective, <<c, rest::binary>>}
  end

  defp operator(<<o::binary-size(2), rest::binary>>, costs)
       when o in ["=~", "!~", "!=", "<>", "<=", ">="],
       do: {3, costs.comparison, rest}

  defp operator(<<c, rest::binary>>, costs) when c in [?=, ?<, ?>],
    do: {3, costs.comparison, rest}

  defp operator(<<c, rest::binary>>, costs) when c in [?+, ?-, ?&, ?|, ?^],
    do: {4, costs.arith, rest}

  defp operator(<<c, rest::binary>>, costs) when c in [?*, ?/, ?%], do: {5, costs.arith, rest}
  defp operator(_text, _costs), do: nil

  defp word_end?(c), do: not (c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c > 127)

  # What stands where an operand is wanted: a sign before it, a parenthesis, a quoted text
  # (its inside is masked), a regular expression (after `=~`), a call, or a word or number.
  @spec operand(binary(), non_neg_integer(), map(), boolean()) :: {non_neg_integer(), binary()}
  defp operand(text, above, costs, after_operator?) do
    case InfluxQLLex.trim_blanks(text) do
      <<sign, rest::binary>> when sign in [?+, ?-] ->
        past?(above + costs.sign, costs)
        {cost, rest} = operand(rest, above + costs.sign, costs, false)
        {costs.sign + cost, rest}

      <<?(, rest::binary>> ->
        paren = if after_operator?, do: costs.after_operator, else: costs.paren
        past?(above + paren, costs)
        {cost, rest} = expression(rest, above + paren, 1, costs, false)
        {paren + cost, close(rest)}

      <<quote, rest::binary>> when quote in [?', ?"] ->
        {0, after_quote(rest, quote)}

      <<?/, rest::binary>> ->
        {0, after_quote(rest, ?/)}

      <<c, _rest::binary>> = text when c in [?), ?,] ->
        {0, text}

      "" ->
        {0, ""}

      text ->
        word(text, above, costs)
    end
  end

  # A word or a number, and the call its parenthesis opens.
  @spec word(binary(), non_neg_integer(), map()) :: {non_neg_integer(), binary()}
  defp word(text, above, costs) do
    case after_word(text) do
      ^text ->
        {0, text}

      rest ->
        case InfluxQLLex.trim_blanks(rest) do
          <<?(, args::binary>> ->
            past?(above + costs.call, costs)
            {cost, rest} = arguments(args, above + costs.call, 0, costs)
            {costs.call + cost, rest}

          _no_call ->
            {0, rest}
        end
    end
  end

  # The arguments of a call, up to its closing parenthesis.
  @spec arguments(binary(), non_neg_integer(), non_neg_integer(), map()) ::
          {non_neg_integer(), binary()}
  defp arguments(text, above, widest, costs) do
    {cost, rest} = expression(text, above, 1, costs, false)

    case InfluxQLLex.trim_blanks(rest) do
      <<?,, more::binary>> -> arguments(more, above, max(widest, cost), costs)
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

  @spec past?(non_neg_integer(), map()) :: :ok
  defp past?(cost, %{budget: budget}) when cost > budget, do: throw(:too_deep)
  defp past?(_cost, _costs), do: :ok
end
