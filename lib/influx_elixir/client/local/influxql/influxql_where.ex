defmodule InfluxElixir.Client.Local.InfluxQLWhere do
  @moduledoc false
  # Plans an InfluxQL `WHERE`: the condition as a tree of `OR`, `AND` and
  # comparisons, each comparison as SQL for the caller's engine, and the lower
  # bounds its `time` comparisons give.

  import Bitwise, only: [|||: 2]

  alias InfluxElixir.Client.Local.{
    InfluxQL,
    InfluxQLArithmetic,
    InfluxQLArithType,
    InfluxQLError,
    InfluxQLExpr,
    InfluxQLNested,
    InfluxQLSql,
    InfluxQLTime,
    InfluxQLTimeComparand,
    InfluxQLTimeExpr,
    InfluxQLTokens,
    InfluxQLTyped,
    InfluxQLWhereArith,
    SQLLimits
  }

  require SQLLimits

  @param_refusal "unsupported InfluxQL (a bind parameter in a condition)"

  # What a group holds that the tokens of a comparison are read for (see `nest/2`).
  @time 1
  @duration 2
  @absent 4
  @call 8

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
        ctx = {tags, types}
        {tree, _rest} = tokens |> nest(ctx) |> parse_or()
        InfluxQLTime.check_bare(tree)
        now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:nanosecond) end)

        times = %{
          now: now,
          extend: Keyword.get(opts, :extend_lower, 0),
          known: Keyword.get(opts, :known),
          alone: true,
          timed: InfluxQLTime.mentions_time_comparison?(tree),
          first: true,
          show: Keyword.get(opts, :show, false),
          bare: false
        }

        # The planner reads the times of the condition before it types the rest: a time it
        # cannot read is its error, before the stack breaks on a bare operand.
        check_times(tree, ctx, times)
        InfluxQLTyped.check_stack(tree, ctx)

        # The planner raises the error of a comparison, and that of a connective it cannot type,
        # as it builds the filter, leaves first and in order: each comparison of a condition with
        # a bare operand is planned as the connectives are typed.
        leaf = &plan_comparisons(&1, ctx, %{times | alone: false, bare: true}, &2)

        {deferred, {sql, bounds, checks}} =
          case InfluxQLTyped.bare_condition(tree, ctx, Keyword.get(opts, :filter), leaf) do
            nil -> {nil, plan(tree, ctx, times)}
            {:tree, bare_tree} -> {nil, plan(bare_tree, ctx, times)}
            :empty -> {nil, {InfluxQLSql.never(), [], []}}
            error -> {error, {"true", [], []}}
          end

        idents = for {:ident, name} <- tokens, into: MapSet.new(), do: name
        lowers = for {:lower, ns} <- bounds, do: ns
        uppers = for {:upper, ns} <- bounds, do: ns

        {:ok,
         %{
           sql: sql,
           lowers: lowers,
           uppers: uppers,
           prune: prune_of(tree, ctx, lowers, uppers),
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
      late_clash(where, {tags, types}, body, Keyword.get(opts, :late_clash, false))

    # The error of a division, which waits for the comparisons around it (see `join_plans/4`).
    {:late, _class, body} ->
      {:error, {:engine, 400, body}}
  end

  defp check_times({:group, node}, ctx, times), do: check_times(node, ctx, times)

  defp check_times({kind, nodes}, ctx, times) when kind in [:and, :or],
    do: Enum.each(nodes, &check_times(&1, ctx, times))

  defp check_times({:cmp, tokens}, {tags, _types} = ctx, times) do
    if Enum.any?(tokens, &InfluxQLTokens.time?/1) do
      tokens = expand(tokens)
      # (A SHOW statement words the symbol its own way, which is not verified: it is left to the
      # stage that refuses it.)
      unless times.show, do: split_error(tokens, ctx)
      engine_time_error(tokens, tags, times)
    end

    :ok
  end

  defp check_times(_node, _ctx, _times), do: :ok

  # The planner splits the bare time out of the condition first, and its error comes before
  # every other (see `InfluxQLTimeComparand`); one it words in a form the double does not tell
  # is refused by name, where the stack of the planner would break beside a bare operand.
  defp split_error(tokens, ctx) do
    case InfluxQLTimeComparand.check(tokens, ctx) do
      :ok -> :ok
      {:error, body} -> throw({:refused, {:engine, 400, body}})
      {:error, status, body} -> throw({:refused, {:engine, status, body}})
      :unclear -> InfluxQLError.refuse("a time compared with an operand the double cannot word")
    end
  end

  # Only the planner's own error for a time is raised here; a time the double does not read is
  # left to the stage that refuses it.
  defp engine_time_error(tokens, tags, times) do
    time_plan(tokens, tags, times)
  catch
    {:refused, {:engine, _status, _body}} = engine -> throw(engine)
    {:refused, {:engine, _body}} = engine -> throw(engine)
    {:refused, _message} -> :ok
  end

  defp late_clash(_where, _ctx, body, false), do: {:error, {:engine, body}}

  defp late_clash(where, ctx, body, true) do
    tokens = tokens_of(where)
    {tree, _rest} = tokens |> nest(ctx) |> parse_or()
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
         prune: nil,
         deferred: nil,
         clash: {400, body}
       }}
    end
  end

  # The points a condition keeps by its tags and its time alone, what the engine reads before it
  # evaluates the rest (verified: an unsigned division by zero fails the stream over the points
  # the tag and time comparisons of an `AND` keep, where a comparison of a field is evaluated
  # on the whole batch in a way the double does not tell): the tag comparisons with a string
  # (`=`, `!=`) that stand in the `AND`, and the bounds of the times.
  @spec prune_of(tuple(), {MapSet.t(binary()), map()}, [integer()], [integer()]) ::
          InfluxQL.prune()
  defp prune_of(tree, {tags, _types}, lowers, uppers) do
    conjuncts = if match?({:and, _nodes}, tree), do: elem(tree, 1), else: [tree]

    %{
      tags: Enum.flat_map(conjuncts, &tag_comparison(&1, tags)),
      lower: Enum.max(lowers, fn -> nil end),
      upper: Enum.min(uppers, fn -> nil end)
    }
  end

  defp tag_comparison({:cmp, [{:ident, name}, {:op, op}, {:str, value}]}, tags)
       when op in ["=", "!=", "<>"],
       do: if(MapSet.member?(tags, name), do: [{name, op, value}], else: [])

  defp tag_comparison({:cmp, [{:str, value}, {:op, op}, {:ident, name}]}, tags)
       when op in ["=", "!=", "<>"],
       do: if(MapSet.member?(tags, name), do: [{name, op, value}], else: [])

  defp tag_comparison(_node, _tags), do: []

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
  # condition?, facts}`, in one pass; `condition?` says whether an operator or a connective
  # stands anywhere inside, `facts` what the group holds that the planner reads in the tokens of
  # a comparison (a time, a duration, a column the measurement lacks, a call: bits). A
  # parenthesis that closes nothing, or is never closed, stays a token. The groups are then read
  # without looking for their ends again: a condition nested to a depth of n would otherwise be
  # scanned n times over.
  @spec nest(list(), {MapSet.t(binary()), map()}) :: list()
  defp nest(tokens, ctx), do: nest(tokens, ctx, [{[], false, 0}])

  # `frames` are the open groups, the innermost first, each with its items so far (latest
  # first), whether it holds a condition and its facts.
  defp nest([], _ctx, frames), do: close_all(frames)

  defp nest([{:raw, "("} | rest], ctx, frames), do: nest(rest, ctx, [{[], false, 0} | frames])

  defp nest([{:raw, ")"} = token | rest], ctx, [{acc, cond?, facts}]),
    do: nest(rest, ctx, [{[token | acc], cond?, facts}])

  defp nest(
         [{:raw, ")"} | rest],
         ctx,
         [{acc, cond?, facts}, {outer, outer_cond?, outer_facts} | frames]
       ) do
    item = {:nested, Enum.reverse(acc), cond?, facts}
    nest(rest, ctx, [{[item | outer], outer_cond? or cond?, outer_facts ||| facts} | frames])
  end

  defp nest([token | rest], ctx, [{acc, cond?, facts} | frames]) do
    facts = facts ||| token_facts(token, rest, ctx)
    nest(rest, ctx, [{[token | acc], cond? or connective_token?(token), facts} | frames])
  end

  # What is left open stays tokens: the `(` and the items after it, in place.
  defp close_all([{acc, _cond?, _facts}]), do: Enum.reverse(acc)

  defp close_all([{acc, cond?, facts}, {outer, outer_cond?, outer_facts} | frames]),
    do:
      close_all([
        {acc ++ [{:raw, "("} | outer], outer_cond? or cond?, outer_facts ||| facts} | frames
      ])

  # The time, `now()`, a duration, a column the measurement lacks, a call.
  defp token_facts({:ident, name} = token, rest, {tags, types}) do
    cond do
      match?([{:raw, "("} | _more], rest) -> @call
      InfluxQLTokens.time?(token) -> @time
      InfluxQLExpr.absent?(name, types, tags) -> @absent
      true -> 0
    end
  end

  defp token_facts({:duration, _total, _text}, _rest, _ctx), do: @duration
  defp token_facts({:raw, "now()"}, _rest, _ctx), do: @time
  defp token_facts(_token, _rest, _ctx), do: 0

  defp connective_token?({:op, _op}), do: true
  defp connective_token?({:raw, word}), do: String.upcase(word) in ["AND", "OR"]
  defp connective_token?(_token), do: false

  # A group opens a condition when it closes before an `AND`, an `OR` or the end and holds a
  # comparison or connective; `(a + b) > 1` is an expression and stays a comparison.
  defp parse_atom([{:nested, inside, condition?, _facts} | after_group] = items) do
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

  # A condition in parentheses that holds nothing the comparison's own tokens are read for (no
  # time, duration, call or column the measurement lacks in it) is read here, once, and the
  # comparison holds its tree as one token: a condition nested n deep would be flattened to
  # tokens and read again at each of its n levels otherwise.
  defp comparison([{:nested, inside, true, 0} = item | rest], depth, acc) do
    {node, []} = parse_or(inside)
    comparison(rest, depth, [{:cond_group, node, item} | acc])
  end

  defp comparison([item | rest], depth, acc), do: comparison(rest, depth, flat(item, acc))

  # An item as tokens, pushed on a reversed list.
  defp flat({:nested, inside, _condition?, _facts}, acc),
    do: [{:raw, ")"} | Enum.reduce(inside, [{:raw, "("} | acc], &flat/2)]

  defp flat({:cond_group, _node, item}, acc), do: flat(item, acc)
  defp flat(token, acc), do: [token | acc]

  # The tokens of a comparison with the groups it holds as trees written out again.
  defp expand(tokens) do
    if Enum.any?(tokens, &match?({:cond_group, _node, _item}, &1)),
      do: tokens |> Enum.reduce([], &flat/2) |> Enum.reverse(),
      else: tokens
  end

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
           alone: boolean(),
           timed: boolean(),
           first: boolean(),
           show: boolean(),
           bare: boolean()
         }

  @spec plan(tuple(), {MapSet.t(binary()), map()}, times()) ::
          {binary(), [InfluxQL.bound()], [{binary(), InfluxQLArithmetic.check()}]}
  defp plan({:cmp, tokens}, {tags, types} = ctx, times) do
    InfluxQLWhereArith.check_operands(tokens, tags, types, times.alone)
    time? = Enum.any?(tokens, &InfluxQLTokens.time?/1)

    # A condition in parentheses as an operand decides the comparison before the types of the
    # other side are coerced: the engine does not coerce them then (verified: `'x' + v > (w >
    # 1)` keeps no row and is no error, where `'x' + v > 1` is the coercion error).
    # (The tokens are dead in the branch that plans the conditions inside the groups, which
    # recurse: a statement nested n deep would hold n copies of them otherwise.)
    case InfluxQLNested.classify(tokens, ctx, %{timed: times.timed and not times.first}) do
      :unplaced ->
        plan_flat(expand(tokens), ctx, times, time?)

      classification ->
        {sql, checks} = nested_sql(classification, ctx, times)
        {sql, [], checks}
    end
  end

  defp plan({:never, nil}, _ctx, _times), do: {InfluxQLSql.never(), [], []}

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

  @spec nested_sql(InfluxQLNested.classification(), {MapSet.t(binary()), map()}, times()) ::
          {binary(), list()}
  defp nested_sql(:never, _ctx, _times), do: {InfluxQLSql.never(), []}

  defp nested_sql({same_or_different, left, right}, ctx, times)
       when same_or_different in [:same, :different] do
    {a, a_checks} = operand_sql(left, ctx, times)
    {b, b_checks} = operand_sql(right, ctx, times)

    sql =
      if same_or_different == :same,
        do: "((#{a} AND #{b}) OR (NOT #{a} AND NOT #{b}))",
        else: "((#{a} AND NOT #{b}) OR (NOT #{a} AND #{b}))"

    {sql, a_checks ++ b_checks}
  end

  # (What is needed after the SQL of an operand is worked out before it: the operand may hold
  # the tokens of a condition nested n deep, and a frame that kept the whole classification
  # would keep n copies of them.)
  defp nested_sql({:column, operand, op, name}, ctx, times) do
    prefix = "#{InfluxQLSql.ident_sql(name)} #{op} "
    {sql, checks} = operand_sql(operand, ctx, times)
    {prefix <> sql, checks}
  end

  defp nested_sql({:constant, operand, true}, ctx, times), do: operand_sql(operand, ctx, times)

  defp nested_sql({:constant, operand, false}, ctx, times) do
    {sql, checks} = operand_sql(operand, ctx, times)
    {"NOT " <> sql, checks}
  end

  # The condition inside a group is planned as a condition: its comparisons are typed (`s > 'a'`
  # is false for every row), and the groups inside it are planned the same way.
  @spec operand_sql(InfluxQLNested.operand(), {MapSet.t(binary()), map()}, times()) ::
          {binary(), list()}
  defp operand_sql(false, _ctx, _times), do: {InfluxQLSql.never(), []}

  defp operand_sql({:node, tree}, ctx, times) do
    {sql, _lowers, checks} = plan(tree, ctx, %{times | alone: false})
    {"(" <> sql <> ")", checks}
  end

  defp operand_sql({:group, tokens}, ctx, times) do
    {tree, _rest} = tokens |> nest(ctx) |> parse_or()
    operand_sql({:node, tree}, ctx, times)
  end

  defp plan_flat(tokens, {tags, types} = ctx, times, time?) do
    check_coercion(tokens, tags, types, times.alone)

    cond do
      # Arithmetic of the time that comes to a null (`n + b + time + 1`: the planner reads
      # `n + b` as a null, and a null beside the time is a null) keeps no point, where the SQL
      # engine raises its own coercion error.
      time? and not InfluxQLTokens.time_comparison?(tokens) and
          InfluxQLWhereArith.timed_null?(tokens, tags, types) ->
        {InfluxQLSql.never(), [], []}

      time? ->
        # (The SQL of the time raises its own error when it is run, which a pair with a bare
        # operand, put to false, would never run.)
        if times.bare and not InfluxQLTokens.time_comparison?(tokens),
          do: InfluxQLError.refuse("a time in arithmetic beside a bare operand")

        {sql, lowers} = time_plan(InfluxQLNested.group_last(tokens), tags, times)
        {sql, lowers, []}

      true ->
        plan_typed(tokens, ctx, times.known)
    end
  end

  # A comparison that reads a column the measurement does not have is null for
  # every point, so false (verified: `host = 'a' OR zone = 'z'` finds the points
  # of host a, `zone != 'z'` none). `known` is the measurement's columns, `nil`
  # when the caller does not know them.
  @spec plan_typed(list(), {MapSet.t(binary()), map()}, MapSet.t(binary()) | nil) ::
          {binary(), [InfluxQL.bound()], [{binary(), InfluxQLArithmetic.check()}]}
  defp plan_typed(tokens, ctx, known) do
    if absent_column?(tokens, known) do
      {InfluxQLSql.never(), [], []}
    else
      {sql, checks} = InfluxQLTyped.plan_comparison(tokens, ctx)
      {sql, [], checks}
    end
  end

  defp absent_column?(_tokens, nil), do: false

  # (The name of a call is no column.)
  defp absent_column?(tokens, known) do
    present? = fn name -> InfluxQLTokens.time?({:ident, name}) or MapSet.member?(known, name) end
    InfluxQLTokens.lacking(tokens, present?) != []
  end

  # An unsigned number under arithmetic with a string, a boolean, a tag or the time is the
  # planner's coercion error.
  @spec check_coercion(list(), MapSet.t(binary()), map(), boolean()) :: :ok
  defp check_coercion(tokens, tags, types, alone),
    do: InfluxQLWhereArith.check_coercion(tokens, tags, types, alone)

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
    # The coercion error of arithmetic, and the rewriter's error for an integer beside an unsigned
    # quotient, are the engine's whatever bare operand stands beside it (verified: `time * 2 > 1
    # AND n`, `n + (u / s) > 1 AND b`).
    {:refused, {:engine, 400, "Error during planning: Cannot coerce arithmetic" <> _rest}} = error ->
      throw(error)

    {:refused, {:engine, 400, "Error during planning: cannot use " <> _rest}} = error ->
      throw(error)

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
    not Enum.any?(tokens, &match?({:cond_group, _node, _item}, &1)) and
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
    do: if(InfluxQLTokens.boolean_word?(word), do: :bool, else: :other)

  defp constant_kind(_token), do: :other

  defp absent_leaf?(_tokens, nil), do: false

  # (A comparison, or a column alone: arithmetic that stands as an operand is typed by its
  # operands, `InfluxQLArithType`.)
  defp absent_leaf?(tokens, known) do
    MapSet.size(known) > 0 and absent_column?(tokens, known) and
      (Enum.any?(tokens, &match?({:op, _op}, &1)) or match?([{:ident, _name}], tokens))
  end

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
  defp string_partner?({:raw, word}, _tags), do: InfluxQLTokens.boolean_word?(word)
  defp string_partner?({:ident, name}, tags), do: MapSet.member?(tags, name)
  defp string_partner?(_token, _tags), do: false

  defp join_plans(nodes, separator, ctx, times) do
    # Only the first of the conditions joined is the first of the statement's (see `plan_nested`).
    {first, rest} = Enum.split(nodes, 1)
    others = %{times | first: false}

    planned = Enum.map(first, &held(&1, ctx, times)) ++ Enum.map(rest, &held(&1, ctx, others))

    # The error of a division waits for the comparisons after it: theirs is the engine's.
    case for({:late, class, body} <- planned, do: {class, body}) do
      [_first | _rest] = lates ->
        lates |> InfluxQLArithType.pick_late() |> InfluxQLArithType.throw_late()

      [] ->
        {sqls, lowers, checks} = unzip3(planned)
        {Enum.join(sqls, separator), Enum.concat(lowers), Enum.concat(checks)}
    end
  end

  defp held(node, ctx, times) do
    plan(node, ctx, times)
  catch
    {:late, class, body} -> {:late, class, body}
  end

  defp unzip3(plans) do
    {Enum.map(plans, &elem(&1, 0)), Enum.map(plans, &elem(&1, 1)), Enum.map(plans, &elem(&1, 2))}
  end

  # (An operand that is no comparison with the time in it is read by the SQL, which the double
  # cannot combine with the rest of an `OR`; a comparison that has the time in its arithmetic is
  # typed like any other.)
  defp mentions_time_node?({:cmp, tokens}) do
    InfluxQLTokens.time_comparison?(tokens) or
      (Enum.any?(tokens, &InfluxQLTokens.time?/1) and
         not Enum.any?(tokens, &match?({:op, _op}, &1)))
  end

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
        # (A duration in arithmetic with the time is the SQL's interval, whose error is the
        # engine's `Timestamp(ns) = Int64` or a null by the operands: refused by name.)
        if Enum.any?(tokens, &match?({:duration, _total, _text}, &1)),
          do: InfluxQLError.refuse("a duration in arithmetic with the time")

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
        message = InfluxQLError.invalid_timestamp("'#{content}'")
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
