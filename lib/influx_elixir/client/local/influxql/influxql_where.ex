defmodule InfluxElixir.Client.Local.InfluxQLWhere do
  @moduledoc false
  # Plans an InfluxQL `WHERE`: the condition as a tree of `OR`, `AND` and
  # comparisons, each comparison as SQL for the caller's engine, and the lower
  # bounds its `time` comparisons give.

  alias InfluxElixir.Client.Local.{
    InfluxQL,
    InfluxQLArithmetic,
    InfluxQLError,
    InfluxQLSql,
    InfluxQLTime,
    InfluxQLTimeExpr,
    InfluxQLTokens,
    InfluxQLTyped,
    SQLLimits
  }

  require SQLLimits

  @doc "Plans a `WHERE`; see `InfluxElixir.Client.Local.InfluxQL.where_plan/3`."
  @spec where_plan(
          binary(),
          MapSet.t(binary()),
          %{binary() => InfluxQL.field_type()},
          keyword()
        ) ::
          {:ok, InfluxQL.where_plan()}
          | {:error, binary() | {:engine, binary()} | {:engine, pos_integer(), binary()}}
  def where_plan(where, tags, types \\ %{}, opts \\ []) do
    case InfluxQLTokens.tokenize(where, []) do
      {:ok, tokens} ->
        {tree, _rest} = parse_or(tokens)
        InfluxQLTime.check_bare(tree)
        ctx = {tags, types}
        now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:nanosecond) end)
        deferred = InfluxQLTyped.bare_condition(tree, ctx)
        {sql, bounds, checks} = if deferred, do: {"true", [], []}, else: plan(tree, ctx, now)
        idents = for {:ident, name} <- tokens, into: MapSet.new(), do: name

        {:ok,
         %{
           sql: sql,
           lowers: for({:lower, ns} <- bounds, do: ns),
           uppers: for({:upper, ns} <- bounds, do: ns),
           checks: checks,
           idents: idents,
           deferred: deferred
         }}

      {:syntax_error, _kind, rest} ->
        {:error, "unsupported InfluxQL WHERE: #{rest}"}

      {:error, _message} = error ->
        error
    end
  catch
    {:refused, message} -> {:error, message}
  end

  # The condition as a tree: `OR` of `AND`s of comparisons and
  # parenthesised conditions, as InfluxQL binds them.
  #
  #     {:or, [node]} | {:and, [node]} | {:group, node} | {:cmp, [token]}
  @spec parse_or(list()) :: {tuple(), list()}
  defp parse_or(tokens) do
    {first, rest} = parse_and(tokens)
    collect(rest, "OR", [first], &parse_and/1, :or)
  end

  @spec parse_and(list()) :: {tuple(), list()}
  defp parse_and(tokens) do
    {first, rest} = parse_atom(tokens)
    collect(rest, "AND", [first], &parse_atom/1, :and)
  end

  defp collect([{:raw, word} | rest], keyword, acc, parse, kind) do
    if String.upcase(word) == keyword do
      {node, rest} = parse.(rest)
      collect(rest, keyword, [node | acc], parse, kind)
    else
      done([{:raw, word} | rest], acc, kind)
    end
  end

  defp collect(rest, _keyword, acc, _parse, kind), do: done(rest, acc, kind)

  defp done(rest, [single], _kind), do: {single, rest}
  defp done(rest, acc, kind), do: {{kind, Enum.reverse(acc)}, rest}

  # A parenthesis opens a condition when it closes before an `AND`, an `OR`
  # or the end and holds a comparison or connective; `(a + b) > 1` is an
  # expression and stays a comparison.
  defp parse_atom([{:raw, "("} | after_paren] = tokens) do
    with {inside, [next | _more] = rest} <- split_group(after_paren, 1, []),
         true <- boundary?(next) and condition?(inside) do
      {node, []} = parse_or(inside)
      {{:group, node}, rest}
    else
      {inside, []} -> if condition?(inside), do: group_to_end(inside), else: comparison(tokens)
      _expression -> comparison(tokens)
    end
  end

  defp parse_atom(tokens), do: comparison(tokens)

  defp group_to_end(inside) do
    {node, []} = parse_or(inside)
    {{:group, node}, []}
  end

  # Tokens up to the closing parenthesis of the group just opened.
  defp split_group([], _depth, _acc), do: :unbalanced

  defp split_group([{:raw, ")"} | rest], 1, acc), do: {Enum.reverse(acc), rest}

  defp split_group([{:raw, ")"} = token | rest], depth, acc),
    do: split_group(rest, depth - 1, [token | acc])

  defp split_group([{:raw, "("} = token | rest], depth, acc),
    do: split_group(rest, depth + 1, [token | acc])

  defp split_group([token | rest], depth, acc), do: split_group(rest, depth, [token | acc])

  defp boundary?({:raw, word}), do: String.upcase(word) in ["AND", "OR", ")"]
  defp boundary?(_token), do: false

  defp condition?(tokens) do
    Enum.any?(tokens, fn
      {:op, _op} -> true
      {:raw, word} -> String.upcase(word) in ["AND", "OR"]
      _token -> false
    end)
  end

  # Tokens up to the next `AND` or `OR` outside parentheses.
  defp comparison(tokens), do: comparison(tokens, 0, [])

  defp comparison([], _depth, acc), do: {{:cmp, Enum.reverse(acc)}, []}

  defp comparison([{:raw, word} = token | rest], 0, acc) do
    if String.upcase(word) in ["AND", "OR"],
      do: {{:cmp, Enum.reverse(acc)}, [token | rest]},
      else: comparison(rest, depth_after(word, 0), [token | acc])
  end

  defp comparison([{:raw, word} = token | rest], depth, acc),
    do: comparison(rest, depth_after(word, depth), [token | acc])

  defp comparison([token | rest], depth, acc), do: comparison(rest, depth, [token | acc])

  defp depth_after("(", depth), do: depth + 1
  defp depth_after(")", depth), do: max(depth - 1, 0)
  defp depth_after(_word, depth), do: depth

  # The tree as SQL, with the lower bounds its `time` comparisons give and the
  # checks to run over the rows for what the SQL engine does not read as the
  # engine does.
  @spec plan(tuple(), {MapSet.t(binary()), map()}, integer()) ::
          {binary(), [InfluxQL.bound()], [{binary(), InfluxQLArithmetic.check()}]}
  defp plan({:cmp, tokens}, {tags, _types} = ctx, now) do
    if Enum.any?(tokens, &InfluxQLTokens.time?/1) do
      {sql, lowers} = time_plan(tokens, tags, now)
      {sql, lowers, []}
    else
      {sql, checks} = InfluxQLTyped.plan_comparison(tokens, ctx)
      {sql, [], checks}
    end
  end

  defp plan({:group, node}, ctx, now) do
    {sql, lowers, checks} = plan(node, ctx, now)
    {"(" <> sql <> ")", lowers, checks}
  end

  defp plan({:and, nodes}, ctx, now), do: join_plans(nodes, " AND ", ctx, now)

  # The comparisons are planned first: what the engine reads wrongly in one is
  # its error, before the refusal of the connective.
  defp plan({:or, nodes}, ctx, now) do
    joined = join_plans(nodes, " OR ", ctx, now)

    if Enum.any?(nodes, &mentions_time_node?/1),
      do: throw({:refused, "unsupported InfluxQL (a time comparison inside OR)"})

    joined
  end

  defp join_plans(nodes, separator, ctx, now) do
    {sqls, lowers, checks} = nodes |> Enum.map(&plan(&1, ctx, now)) |> unzip3()
    {Enum.join(sqls, separator), Enum.concat(lowers), Enum.concat(checks)}
  end

  defp unzip3(plans) do
    {Enum.map(plans, &elem(&1, 0)), Enum.map(plans, &elem(&1, 1)), Enum.map(plans, &elem(&1, 2))}
  end

  defp mentions_time_node?({:cmp, tokens}), do: Enum.any?(tokens, &InfluxQLTokens.time?/1)
  defp mentions_time_node?({:group, node}), do: mentions_time_node?(node)
  defp mentions_time_node?({_kind, nodes}), do: Enum.any?(nodes, &mentions_time_node?/1)

  # A comparison with `time` on one side and a time on the other.
  @flipped %{"=" => "=", "<" => ">", "<=" => ">=", ">" => "<", ">=" => "<="}

  defp time_plan(tokens, tags, now) do
    case time_sides(tokens) do
      {op, comparand} -> time_comparison(op, comparand, now)
      :other -> {tokens |> InfluxQLSql.rewrite(tags, []) |> Enum.join(" "), []}
    end
  end

  defp time_sides([first, {:op, op} | comparand] = tokens) when comparand != [] do
    cond do
      not InfluxQLTokens.time?(first) -> time_right(tokens)
      Enum.any?(comparand, &match?({:ident, _name}, &1)) -> :other
      true -> {op, comparand}
    end
  end

  defp time_sides(tokens), do: time_right(tokens)

  defp time_right(tokens) when length(tokens) > 2 do
    with {comparand, [{:op, op}, {:ident, _name} = last]} <- Enum.split(tokens, -2),
         true <- InfluxQLTokens.time?(last) do
      if op in ["=~", "!~"] or Enum.any?(comparand, &match?({:ident, _name}, &1)),
        do: :other,
        else: {Map.get(@flipped, op, op), comparand}
    else
      _other -> :other
    end
  end

  defp time_right(_tokens), do: :other

  defp time_comparison(op, _comparand, _now) when op in ["!=", "<>"] do
    throw(
      {:refused,
       {:engine,
        "rewriting statement\ncaused by\nsplit condition\ncaused by\n" <>
          "Error during planning: invalid time comparison operator: !="}}
    )
  end

  defp time_comparison(op, _comparand, _now) when op not in ["=", "<", "<=", ">", ">="],
    do: throw({:refused, "unsupported InfluxQL (time #{op} ...)"})

  defp time_comparison(op, comparand, now) do
    ns = time_ns(comparand, now)
    {"time #{op} '#{iso_ns(ns)}'", bounds(op, ns)}
  end

  # What a time is compared with, in nanoseconds since the epoch: a lone
  # quoted time, read as the planner reads it, or an expression of quoted
  # times, `now()`, durations and integers.
  @spec time_ns(list(), integer()) :: integer()
  defp time_ns([{:str, content}], _now), do: check_time_string(content)
  defp time_ns(tokens, now), do: InfluxQLTimeExpr.eval(tokens, now)

  # The planner reads a quoted time before the SQL engine does.
  @spec check_time_string(binary()) :: integer()
  defp check_time_string(content) do
    case InfluxQLTime.classify(content) do
      {:ok, ns} ->
        ns

      :invalid ->
        message =
          "Error during planning: invalid expression \"'#{content}'\": " <>
            "'#{content}' is not a valid timestamp"

        throw({:refused, {:engine, 400, InfluxQLError.split_error(message)}})

      {:out_of_range, shown} ->
        message = "Error during planning: timestamp out of range: #{shown}"
        throw({:refused, {:engine, 400, InfluxQLError.split_error(message)}})

      :unknown ->
        throw(
          {:refused,
           "unsupported InfluxQL (the time '#{content}' in a form the double does not read)"}
        )
    end
  end

  # `time >= x` and `time = x` start at x, `time > x` just after it; `time <= x`
  # and `time = x` end at x, `time < x` just before it.
  @spec bounds(binary(), integer()) :: [{:lower | :upper, InfluxQL.bound()}]
  defp bounds("=", ns), do: [{:lower, ns}, {:upper, ns}]
  defp bounds(">=", ns), do: [{:lower, ns}]
  defp bounds(">", ns), do: [{:lower, ns + 1}]
  defp bounds("<=", ns), do: [{:upper, ns}]
  defp bounds("<", ns), do: [{:upper, ns - 1}]

  # The earliest instant the SQL engine reads (1677-09-21T00:12:44).
  @arrow_min -9_223_372_036_000_000_000

  # nanoseconds since the epoch as the nine-digit ISO-8601 time the SQL
  # engine reads exactly; from `@arrow_min` on, which it reads, to the 64-bit
  # end.
  @spec iso_ns(integer()) :: binary()
  defp iso_ns(ns) when ns >= @arrow_min and ns <= SQLLimits.int64_max() do
    seconds = Integer.floor_div(ns, 1_000_000_000)
    nanos = Integer.mod(ns, 1_000_000_000)
    stamp = seconds |> DateTime.from_unix!() |> DateTime.to_iso8601() |> String.trim_trailing("Z")
    "#{stamp}.#{String.pad_leading(Integer.to_string(nanos), 9, "0")}Z"
  end

  defp iso_ns(ns) when ns < @arrow_min and ns >= SQLLimits.int64_min(),
    do: throw({:refused, "unsupported InfluxQL (a time before 1677-09-21T00:12:44)"})

  defp iso_ns(_ns),
    do: throw({:refused, "unsupported InfluxQL (a time outside 64-bit nanoseconds)"})
end
