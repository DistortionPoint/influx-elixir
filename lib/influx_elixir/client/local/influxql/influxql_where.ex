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
    InfluxQLWhereArith,
    SQLLimits
  }

  require SQLLimits

  @param_refusal "unsupported InfluxQL (a bind parameter in a condition)"

  @doc "Plans a `WHERE`; see `InfluxElixir.Client.Local.InfluxQL.where_plan/3`. The option `:extend_lower` reads the lower bounds that much earlier in the SQL."
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
        # The engine binds the parameters (or says the first one has no value) as it plans,
        # with planning errors of its own before and after that are not verified.
        if Enum.any?(tokens, &match?({:param, _name}, &1)), do: throw({:refused, @param_refusal})
        {tree, _rest} = tokens |> nest() |> parse_or()
        InfluxQLTime.check_bare(tree)
        ctx = {tags, types}
        InfluxQLTyped.check_stack(tree, ctx)
        now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:nanosecond) end)

        times = %{
          now: now,
          extend: Keyword.get(opts, :extend_lower, 0),
          known: Keyword.get(opts, :known),
          alone: true
        }

        # The planner raises the error of a comparison, and that of a connective it cannot type,
        # as it builds the filter, leaves first and in order: each comparison of a condition with
        # a bare operand is planned as the connectives are typed.
        leaf = &plan_comparisons(&1, ctx, %{times | alone: false}, &2)

        {deferred, {sql, bounds, checks}} =
          case InfluxQLTyped.bare_condition(tree, ctx, Keyword.get(opts, :filter), leaf) do
            nil -> {nil, plan(tree, ctx, times)}
            {:tree, bare_tree} -> {nil, plan(bare_tree, ctx, times)}
            :empty -> {nil, {"(1 = 0)", [], []}}
            error -> {error, {"true", [], []}}
          end

        idents = for {:ident, name} <- tokens, into: MapSet.new(), do: name

        {:ok,
         %{
           sql: sql,
           lowers: for({:lower, ns} <- bounds, do: ns),
           uppers: for({:upper, ns} <- bounds, do: ns),
           checks: checks,
           idents: idents,
           deferred: deferred,
           clash: nil
         }}

      {:syntax_error, _kind, rest} ->
        {:error, "unsupported InfluxQL WHERE: #{rest}"}

      {:error, _message} = error ->
        error
    end
  catch
    {:refused, message} ->
      {:error, message}

    # The planning error of a comparison is raised after the errors of the statement's
    # rewriting (the select list, the grouping) and before those of its `LIMIT`: the plan holds
    # nothing, and the caller raises the error in its turn (verified: `count(f), g ... WHERE
    # b <= u` is the mixing of aggregate and non-aggregate columns, not the comparison).
    {:deferred, body} ->
      late_clash(where, body, Keyword.get(opts, :late_clash, false))
  end

  defp late_clash(_where, body, false), do: {:error, {:engine, body}}

  defp late_clash(where, body, true) do
    tokens = tokens_of(where)
    {tree, _rest} = tokens |> nest() |> parse_or()
    idents = for {:ident, name} <- tokens, into: MapSet.new(), do: name

    # The error of a comparison stands in for the plan, and with it the refusals the rest of
    # the condition would have been planned into.
    if time_inside_or?(tree) do
      {:error, "unsupported InfluxQL (a time comparison inside OR)"}
    else
      {:ok,
       %{
         sql: "true",
         lowers: [],
         uppers: [],
         checks: [],
         idents: idents,
         deferred: nil,
         clash: {400, body}
       }}
    end
  end

  defp time_inside_or?({:or, nodes}), do: Enum.any?(nodes, &mentions_time_node?/1)
  defp time_inside_or?({:and, nodes}), do: Enum.any?(nodes, &time_inside_or?/1)
  defp time_inside_or?({:group, node}), do: time_inside_or?(node)
  defp time_inside_or?(_leaf), do: false

  defp tokens_of(where) do
    case InfluxQLTokens.tokenize(where, []) do
      {:ok, tokens} -> tokens
      _error -> []
    end
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

  # The tokens with every balanced pair of parentheses made one item, `{:nested, items,
  # condition?}`, in one pass; `condition?` says whether an operator or a connective stands
  # anywhere inside. A parenthesis that closes nothing, or is never closed, stays a token. The
  # groups are then read without looking for their ends again: a condition nested to a depth
  # of n would otherwise be scanned n times over.
  @spec nest(list()) :: list()
  defp nest(tokens), do: nest(tokens, [{[], false}])

  # `frames` are the open groups, the innermost first, each with its items so far (latest
  # first) and whether it holds a condition.
  defp nest([], frames), do: close_all(frames)

  defp nest([{:raw, "("} | rest], frames), do: nest(rest, [{[], false} | frames])

  defp nest([{:raw, ")"} = token | rest], [{acc, cond?}]),
    do: nest(rest, [{[token | acc], cond?}])

  defp nest([{:raw, ")"} | rest], [{acc, cond?}, {outer, outer_cond?} | frames]) do
    nest(rest, [{[{:nested, Enum.reverse(acc), cond?} | outer], outer_cond? or cond?} | frames])
  end

  defp nest([token | rest], [{acc, cond?} | frames]),
    do: nest(rest, [{[token | acc], cond? or connective_token?(token)} | frames])

  # What is left open stays tokens: the `(` and the items after it, in place.
  defp close_all([{acc, _cond?}]), do: Enum.reverse(acc)

  defp close_all([{acc, cond?}, {outer, outer_cond?} | frames]),
    do: close_all([{acc ++ [{:raw, "("} | outer], outer_cond? or cond?} | frames])

  defp connective_token?({:op, _op}), do: true
  defp connective_token?({:raw, word}), do: String.upcase(word) in ["AND", "OR"]
  defp connective_token?(_token), do: false

  # A group opens a condition when it closes before an `AND`, an `OR` or the end and holds a
  # comparison or connective; `(a + b) > 1` is an expression and stays a comparison.
  defp parse_atom([{:nested, inside, condition?} | after_group] = items) do
    case after_group do
      [next | _more] when condition? ->
        if boundary?(next), do: group(inside, after_group), else: comparison(items)

      [] when condition? ->
        group(inside, [])

      _expression ->
        comparison(items)
    end
  end

  defp parse_atom(items), do: comparison(items)

  defp group(inside, rest) do
    {node, []} = parse_or(inside)
    {{:group, node}, rest}
  end

  defp boundary?({:raw, word}), do: String.upcase(word) in ["AND", "OR", ")"]
  defp boundary?(_token), do: false

  # Items up to the next `AND` or `OR` outside parentheses, as the tokens they are.
  defp comparison(items), do: comparison(items, 0, [])

  defp comparison([], _depth, acc), do: {{:cmp, Enum.reverse(acc)}, []}

  defp comparison([{:raw, word} = token | rest], 0, acc) do
    if String.upcase(word) in ["AND", "OR"],
      do: {{:cmp, Enum.reverse(acc)}, [token | rest]},
      else: comparison(rest, depth_after(word, 0), [token | acc])
  end

  defp comparison([{:raw, word} = token | rest], depth, acc),
    do: comparison(rest, depth_after(word, depth), [token | acc])

  defp comparison([item | rest], depth, acc), do: comparison(rest, depth, flat(item, acc))

  # An item as tokens, pushed on a reversed list.
  defp flat({:nested, inside, _condition?}, acc),
    do: [{:raw, ")"} | Enum.reduce(inside, [{:raw, "("} | acc], &flat/2)]

  defp flat(token, acc), do: [token | acc]

  defp depth_after("(", depth), do: depth + 1
  defp depth_after(")", depth), do: max(depth - 1, 0)
  defp depth_after(_word, depth), do: depth

  # The tree as SQL, with the lower bounds its `time` comparisons give and the
  # checks to run over the rows for what the SQL engine does not read as the
  # engine does.
  @typep times :: %{
           now: integer(),
           extend: non_neg_integer(),
           known: MapSet.t(binary()) | nil,
           alone: boolean()
         }

  @spec plan(tuple(), {MapSet.t(binary()), map()}, times()) ::
          {binary(), [InfluxQL.bound()], [{binary(), InfluxQLArithmetic.check()}]}
  defp plan({:cmp, tokens}, {tags, types} = ctx, times) do
    check_calls(tokens, tags, types, times.alone)
    check_coercion(tokens, tags, types)

    if Enum.any?(tokens, &InfluxQLTokens.time?/1) do
      {sql, lowers} = time_plan(tokens, tags, times)
      {sql, lowers, []}
    else
      plan_typed(tokens, ctx, times.known)
    end
  end

  defp plan({:never, nil}, _ctx, _times), do: {"(1 = 0)", [], []}

  defp plan({:group, node}, ctx, times) do
    {sql, lowers, checks} = plan(node, ctx, times)
    {"(" <> sql <> ")", lowers, checks}
  end

  defp plan({:and, nodes}, ctx, times),
    do: join_plans(nodes, " AND ", ctx, %{times | alone: false})

  # The comparisons are planned first: what the engine reads wrongly in one is
  # its error, before the refusal of the connective.
  defp plan({:or, nodes}, ctx, times) do
    joined = join_plans(nodes, " OR ", ctx, %{times | alone: false})

    if Enum.any?(nodes, &mentions_time_node?/1),
      do: throw({:refused, "unsupported InfluxQL (a time comparison inside OR)"})

    joined
  end

  # A comparison that reads a column the measurement does not have is null for
  # every point, so false (verified: `host = 'a' OR zone = 'z'` finds the points
  # of host a, `zone != 'z'` none). `known` is the measurement's columns, `nil`
  # when the caller does not know them.
  @spec plan_typed(list(), {MapSet.t(binary()), map()}, MapSet.t(binary()) | nil) ::
          {binary(), [InfluxQL.bound()], [{binary(), InfluxQLArithmetic.check()}]}
  defp plan_typed(tokens, ctx, known) do
    if absent_column?(tokens, known) do
      {"(1 = 0)", [], []}
    else
      {sql, checks} = InfluxQLTyped.plan_comparison(tokens, ctx)
      {sql, [], checks}
    end
  end

  defp absent_column?(_tokens, nil), do: false

  # The name of a call is no column.
  defp absent_column?(tokens, known) do
    tokens
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.any?(fn
      [{:ident, name}, next] -> next != {:raw, "("} and not MapSet.member?(known, name)
      _tokens -> false
    end)
  end

  # The calls of a comparison are `abs()` of a number, or the engine's planning error, or
  # refused by name. `alone` is whether the comparison is the whole condition.
  @spec check_calls(list(), MapSet.t(binary()), map(), boolean()) :: :ok
  defp check_calls(tokens, tags, types, alone) do
    case InfluxQLWhereArith.call_error(tokens, tags, types, alone) do
      :ok -> :ok
      {:engine, body} -> throw({:refused, {:engine, body}})
      {:refuse, message} -> throw({:refused, message})
    end
  end

  # An unsigned number under arithmetic with a string, a boolean, a tag or the time is the
  # planner's coercion error.
  @spec check_coercion(list(), MapSet.t(binary()), map()) :: :ok
  defp check_coercion(tokens, tags, types) do
    case InfluxQLWhereArith.coercion_error(tokens, tags, types) do
      nil -> :ok
      body -> throw({:refused, {:engine, 400, body}})
    end
  end

  # A comparison of a condition with a bare operand, planned for the error the planner raises
  # at it (see `late_clash`). A comparison the double refuses is found among the connectives'
  # errors in an order it does not tell, and it refuses the whole. A comparison of constants
  # and one of a column the measurement lacks raise no error of their own beside a bare operand
  # (verified over every kind of operand and pairs and chains of three), and are not planned:
  # the pair they are in keeps no point (see `InfluxQLTyped`).
  @spec plan_comparisons(tuple(), {MapSet.t(binary()), map()}, map(), boolean()) :: term()
  defp plan_comparisons({:cmp, tokens} = leaf, ctx, times, other_bare?) do
    cond do
      constants_comparison?(tokens) -> check_constants(tokens)
      absent_leaf?(tokens, times.known) -> check_absent(tokens, ctx, other_bare?)
      true -> plan_leaf(leaf, ctx, times)
    end
  end

  defp plan_leaf(leaf, ctx, times) do
    plan(leaf, ctx, times)
  catch
    {:refused, _reason} ->
      throw(
        {:refused,
         "unsupported InfluxQL (a bare non-boolean operand beside a comparison the engine refuses)"}
      )
  end

  # A comparison has an operand on each side of its operator: a leaf that starts or ends with
  # one (`= 1`, `=~ /a/`) is no comparison of constants, whatever it holds (the engine's parser
  # refuses it where it stands, see `InfluxQLTokens`).
  defp constants_comparison?(tokens) do
    Enum.any?(tokens, &match?({:op, _op}, &1)) and
      not match?({:op, _op}, List.first(tokens)) and
      not match?({:op, _op}, List.last(tokens)) and
      not Enum.any?(tokens, &(match?({:ident, _name}, &1) or InfluxQLTokens.time?(&1)))
  end

  # Of the comparisons of constants those of numbers, strings and regular expressions are
  # verified (mixed, too: `'a' = 1`), and arithmetic over one kind of constant; arithmetic over
  # strings and numbers (`1 = 1 + 'a'`) is typed as a null, and the rest (booleans, durations,
  # `now()`) is not verified.
  defp check_constants(tokens) do
    kinds = for token <- tokens, kind = constant_kind(token), uniq: true, do: kind

    operands = kinds -- [:arithmetic]

    if :other in kinds or
         (:arithmetic in kinds and (length(operands) > 1 or :bool in operands)),
       do:
         throw(
           {:refused, "unsupported InfluxQL (a bare operand beside that comparison of constants)"}
         ),
       else: :ok
  end

  defp constant_kind({:number, _text}), do: :number
  defp constant_kind({:str, _content}), do: :string
  defp constant_kind({:regex, _pattern}), do: :regex
  defp constant_kind({:raw, op}) when op in ["+", "-", "*", "/"], do: :arithmetic
  defp constant_kind({:raw, paren}) when paren in ["(", ")"], do: nil
  defp constant_kind({:op, _op}), do: nil

  defp constant_kind({:raw, word}),
    do: if(String.upcase(word) in ["TRUE", "FALSE"], do: :bool, else: :other)

  defp constant_kind(_token), do: :other

  defp absent_leaf?(_tokens, nil), do: false

  defp absent_leaf?(tokens, known),
    do: MapSet.size(known) > 0 and absent_column?(tokens, known)

  # A column the measurement lacks, compared with a number (or another such column), is typed
  # as a null number: beside a bare string, tag or other non-number the planner's error is
  # raised (verified: `nosuch = 1 AND s` is an error, `nosuch = 1 AND n` and `nosuch = 's'
  # AND s` are none). Beside non-number bare operands only the comparison with a string, a
  # regular expression, a boolean or a tag is known to keep no error.
  defp check_absent(_tokens, _ctx, false), do: :ok

  defp check_absent(tokens, {tags, _types}, true) do
    if absent_with_string_partner?(tokens, tags),
      do: :ok,
      else:
        throw(
          {:refused,
           "unsupported InfluxQL (a bare string or tag beside a comparison of a column " <>
             "the measurement lacks)"}
        )
  end

  defp absent_with_string_partner?([{:ident, _name}, {:op, _op}, partner], tags),
    do: string_partner?(partner, tags)

  defp absent_with_string_partner?([partner, {:op, _op}, {:ident, _name}], tags),
    do: string_partner?(partner, tags)

  defp absent_with_string_partner?(_tokens, _tags), do: false

  defp string_partner?({:str, _content}, _tags), do: true
  defp string_partner?({:regex, _pattern}, _tags), do: true
  defp string_partner?({:raw, word}, _tags), do: String.upcase(word) in ["TRUE", "FALSE"]
  defp string_partner?({:ident, name}, tags), do: MapSet.member?(tags, name)
  defp string_partner?(_token, _tags), do: false

  defp join_plans(nodes, separator, ctx, times) do
    {sqls, lowers, checks} = nodes |> Enum.map(&plan(&1, ctx, times)) |> unzip3()
    {Enum.join(sqls, separator), Enum.concat(lowers), Enum.concat(checks)}
  end

  defp unzip3(plans) do
    {Enum.map(plans, &elem(&1, 0)), Enum.map(plans, &elem(&1, 1)), Enum.map(plans, &elem(&1, 2))}
  end

  defp mentions_time_node?({:cmp, tokens}), do: Enum.any?(tokens, &InfluxQLTokens.time?/1)
  defp mentions_time_node?({:never, nil}), do: false
  defp mentions_time_node?({:group, node}), do: mentions_time_node?(node)
  defp mentions_time_node?({_kind, nodes}), do: Enum.any?(nodes, &mentions_time_node?/1)

  # A comparison with `time` on one side and a time on the other.
  @flipped %{"=" => "=", "<" => ">", "<=" => ">=", ">" => "<", ">=" => "<="}

  defp time_plan(tokens, tags, times) do
    case time_sides(tokens) do
      {op, comparand} ->
        time_comparison(op, comparand, times)

      :other ->
        if {:raw, "now()"} not in tokens, do: negated_time(tokens, nil)
        {tokens |> InfluxQLSql.rewrite(tags, []) |> Enum.join(" "), []}
    end
  end

  # A minus sign before `time` is the planning error of `-1 * time` (verified), not the
  # SQL engine's broken connection.
  defp negated_time([{:raw, "-"} | rest], previous)
       when previous in [nil, "(", "+", "-", "*", "/", :op] do
    case rest do
      [token | _more] ->
        if InfluxQLTokens.time?(token),
          do:
            throw(
              {:refused,
               {:engine, 400,
                "Error during planning: Cannot coerce arithmetic expression " <>
                  "Int64 * Timestamp(ns) to valid types"}}
            ),
          else: negated_time(rest, "-")

      [] ->
        :ok
    end
  end

  defp negated_time([{:op, _op} | rest], _previous), do: negated_time(rest, :op)
  defp negated_time([{:raw, text} | rest], _previous), do: negated_time(rest, text)
  defp negated_time([_token | rest], _previous), do: negated_time(rest, :operand)
  defp negated_time([], _previous), do: :ok

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

  # A lower bound is read earlier by `extend` nanoseconds for the SQL (the
  # transforms that look back scan one bucket before the range, see
  # `InfluxQLRun`); the bounds it gives are the statement's own.
  defp time_comparison(op, comparand, %{now: now, extend: extend}) do
    ns = time_ns(comparand, now)

    if wraps?(op, ns) do
      {"(1 = 1)", wrapped_bounds(op)}
    else
      scanned = if op in [">=", ">"], do: ns - extend, else: ns
      {"time #{op} '#{iso_ns(scanned)}'", bounds(op, ns)}
    end
  end

  # The engine adds one to the bound of `time > x` and takes one from that of `time < x`, in
  # 64 bits: past the largest time the bound wraps to the smallest (and the reverse), so
  # `time > 9223372036854775807` and `time < -9223372036854775808` keep every point (verified).
  @spec wraps?(binary(), integer()) :: boolean()
  defp wraps?(">", ns), do: ns == SQLLimits.int64_max()
  defp wraps?("<", ns), do: ns == SQLLimits.int64_min()
  defp wraps?(_op, _ns), do: false

  @spec wrapped_bounds(binary()) :: [{:lower | :upper, InfluxQL.bound()}]
  defp wrapped_bounds(">"), do: [{:lower, SQLLimits.int64_min()}]
  defp wrapped_bounds("<"), do: [{:upper, SQLLimits.int64_max()}]

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
