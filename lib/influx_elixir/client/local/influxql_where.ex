defmodule InfluxElixir.Client.Local.InfluxQLWhere do
  @moduledoc """
  Plans an InfluxQL `WHERE`: the condition as a tree of `OR`, `AND` and
  comparisons, each comparison as SQL for the caller's engine, and the lower
  bounds its `time` comparisons give.
  """

  alias InfluxElixir.Client.Local.{
    InfluxQL,
    InfluxQLArithmetic,
    InfluxQLError,
    InfluxQLSql,
    InfluxQLTime,
    InfluxQLTokens,
    InfluxQLTyped,
    SQLParser
  }

  @doc "Plans a `WHERE`; see `InfluxElixir.Client.Local.InfluxQL.where_plan/3`."
  @spec where_plan(binary(), MapSet.t(binary()), %{binary() => InfluxQL.field_type()}) ::
          {:ok, InfluxQL.where_plan()}
          | {:error, binary() | {:engine, binary()} | {:engine, pos_integer(), binary()}}
  def where_plan(where, tags, types \\ %{}) do
    case InfluxQLTokens.tokenize(where, []) do
      {:ok, tokens} ->
        {tree, _rest} = parse_or(tokens)
        InfluxQLTime.check_bare(tree)
        ctx = {tags, types}
        deferred = InfluxQLTyped.bare_condition(tree, ctx)
        {sql, lowers, checks} = if deferred, do: {"true", [], []}, else: plan(tree, ctx)
        idents = for {:ident, name} <- tokens, into: MapSet.new(), do: name

        {:ok, %{sql: sql, lowers: lowers, checks: checks, idents: idents, deferred: deferred}}

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
  @spec plan(tuple(), {MapSet.t(binary()), map()}) ::
          {binary(), [InfluxQL.bound()], [InfluxQLArithmetic.check()]}
  defp plan({:cmp, tokens}, {tags, _types} = ctx) do
    if Enum.any?(tokens, &InfluxQLTokens.time?/1) do
      {sql, lowers} = time_plan(tokens, tags)
      {sql, lowers, []}
    else
      {sql, checks} = InfluxQLTyped.plan_comparison(tokens, ctx)
      {sql, [], checks}
    end
  end

  defp plan({:group, node}, ctx) do
    {sql, lowers, checks} = plan(node, ctx)
    {"(" <> sql <> ")", lowers, checks}
  end

  defp plan({:and, nodes}, ctx), do: join_plans(nodes, " AND ", ctx)

  # The comparisons are planned first: what the engine reads wrongly in one is
  # its error, before the refusal of the connective.
  defp plan({:or, nodes}, ctx) do
    {_sql, _lowers, checks} = joined = join_plans(nodes, " OR ", ctx)

    if Enum.any?(nodes, &mentions_time_node?/1),
      do: throw({:refused, "unsupported InfluxQL (a time comparison inside OR)"})

    if checks != [],
      do: throw({:refused, "unsupported InfluxQL (an unsigned arithmetic comparison inside OR)"})

    joined
  end

  defp join_plans(nodes, separator, ctx) do
    {sqls, lowers, checks} = nodes |> Enum.map(&plan(&1, ctx)) |> unzip3()
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

  defp time_plan(tokens, tags) do
    case time_sides(tokens) do
      {op, comparand} -> time_comparison(op, comparand)
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

  defp time_comparison(op, _comparand) when op in ["!=", "<>"] do
    throw(
      {:refused,
       {:engine,
        "rewriting statement\ncaused by\nsplit condition\ncaused by\n" <>
          "Error during planning: invalid time comparison operator: !="}}
    )
  end

  defp time_comparison(op, _comparand) when op not in ["=", "<", "<=", ">", ">="],
    do: throw({:refused, "unsupported InfluxQL (time #{op} ...)"})

  defp time_comparison(op, comparand) do
    case time_value(comparand) do
      {:ns, ns} ->
        {"time #{op} '#{iso_ns(ns)}'", lower(op, ns)}

      {:str, content} ->
        check_time_string(content)
        {"time #{op} '#{content}'", lower(op, string_ns(content))}

      {:now, offset, sql} ->
        {"time #{op} #{sql}", lower(op, {:now, offset})}
    end
  end

  # The earliest instant the SQL engine reads (1677-09-21T00:12:44).
  @arrow_min -9_223_372_036_000_000_000

  # The planner reads a quoted time before the SQL engine does.
  @spec check_time_string(binary()) :: :ok
  defp check_time_string(content) do
    case InfluxQLTime.classify(content) do
      {:ok, ns} when ns < @arrow_min ->
        throw({:refused, "unsupported InfluxQL (a time before 1677-09-21T00:12:44)"})

      {:ok, _ns} ->
        :ok

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

  # `time >= x` and `time = x` start at x, `time > x` just after it.
  @spec lower(binary(), integer() | {:now, integer()} | nil) :: [InfluxQL.bound()]
  defp lower(_op, nil), do: []
  defp lower(op, bound) when op in ["=", ">="], do: [bound]
  defp lower(">", {:now, offset}), do: [{:now, offset + 1}]
  defp lower(">", ns), do: [ns + 1]
  defp lower(_op, _bound), do: []

  # What a time is compared with: a quoted time, `now()` and durations, or
  # a constant of integers and durations in nanoseconds.
  defp time_value([{:str, content}]), do: {:str, content}

  defp time_value([{:raw, "now()"} | terms]) do
    {offset, sql} = now_terms(terms, 0, ["now()"])
    {:now, offset, Enum.join(sql, " ")}
  end

  defp time_value(tokens), do: {:ns, constant(tokens)}

  defp now_terms([], offset, sql), do: {offset, Enum.reverse(sql)}

  defp now_terms([{:raw, sign}, {:duration, ns, text} | rest], offset, sql)
       when sign in ["+", "-"] do
    signed = if sign == "-", do: -ns, else: ns
    now_terms(rest, offset + signed, [InfluxQLSql.duration_sql(ns, text), sign | sql])
  end

  defp now_terms(_terms, _offset, _sql),
    do: throw({:refused, "unsupported InfluxQL (a time compared with now() and something else)"})

  # `[-] term [(+|-) term]...` of integers and durations.
  defp constant([{:raw, "-"} | rest]), do: constant_sum(rest, 0, -1)
  defp constant([{:raw, "+"} | rest]), do: constant_sum(rest, 0, 1)
  defp constant(tokens), do: constant_sum(tokens, 0, 1)

  defp constant_sum([term | rest], total, sign) do
    total = total + sign * term_ns(term)

    case rest do
      [] -> total
      [{:raw, "+"} | more] -> constant_sum(more, total, 1)
      [{:raw, "-"} | more] -> constant_sum(more, total, -1)
      _other -> throw({:refused, "unsupported InfluxQL (a time compared with an expression)"})
    end
  end

  defp constant_sum([], _total, _sign),
    do: throw({:refused, "unsupported InfluxQL (a time compared with an expression)"})

  defp term_ns({:duration, ns, _text}), do: ns

  defp term_ns({:number, text}) do
    case Integer.parse(text) do
      {n, ""} -> n
      _float_or_error -> throw({:refused, "unsupported InfluxQL (non-integer time #{text})"})
    end
  end

  defp term_ns(_token),
    do: throw({:refused, "unsupported InfluxQL (a time compared with an expression)"})

  # nanoseconds since the epoch as the nine-digit ISO-8601 time the SQL
  # engine reads exactly; from `@arrow_min` on, which it reads, to the 64-bit
  # end.
  @spec iso_ns(integer()) :: binary()
  defp iso_ns(ns) when ns >= @arrow_min and ns <= 9_223_372_036_854_775_807 do
    seconds = Integer.floor_div(ns, 1_000_000_000)
    nanos = Integer.mod(ns, 1_000_000_000)
    stamp = seconds |> DateTime.from_unix!() |> DateTime.to_iso8601() |> String.trim_trailing("Z")
    "#{stamp}.#{String.pad_leading(Integer.to_string(nanos), 9, "0")}Z"
  end

  defp iso_ns(ns) when ns < @arrow_min and ns >= -9_223_372_036_854_775_808,
    do: throw({:refused, "unsupported InfluxQL (a time before 1677-09-21T00:12:44)"})

  defp iso_ns(_ns),
    do: throw({:refused, "unsupported InfluxQL (a time outside 64-bit nanoseconds)"})

  # A quoted time, as the SQL engine reads it.
  @spec string_ns(binary()) :: integer() | nil
  defp string_ns(content) do
    case SQLParser.parse_where(" WHERE time >= '#{content}'") do
      {:ok, [{:gte, "time", ns}]} when is_integer(ns) -> ns
      _unreadable -> nil
    end
  end
end
