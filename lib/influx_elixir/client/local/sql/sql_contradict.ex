defmodule InfluxElixir.Client.Local.SQLContradict do
  @moduledoc false
  # The equalities of a `WHERE` that the engine's optimizer proves contradictory, so that it
  # replaces the plan with an empty relation (verified against InfluxDB 3 Core, each rule below
  # on integers, unsigned integers, floats, text, tags and `time`).
  #
  # Two rules fold, and only these:
  #
  #   * two `IN` lists of one operand become the `IN` list of the values they share, or `false`
  #     when they share none (`n IN (1, 2) AND n IN (3, 4)`). A one-element list is an `IN` list
  #     here, so `n IN (1) AND n IN (2, 3)` folds; the two must be adjacent in the tree (`n IN
  #     (1, 2) AND v > 0 AND n IN (3, 4)` does not fold). The node `A AND (B AND R)` folds as
  #     well when `A` is a leaf and the first predicate of its right operand is `B` (see
  #     `InfluxElixir.Client.Local.SQLSimplify.nested_in?/1`), and not when `B` is deeper in a
  #     right operand that starts with something else. A `NULL` in a list shares nothing, and a
  #     list of nothing but `NULL` shares nothing with any list
  #   * among all the top-level conjuncts of what is left, two equalities of one operand to
  #     different values (`n = 1 AND v > 0 AND n = 2`); a one-element `IN` counts as an equality
  #     here (also when it is written with a value repeated, `n IN (1, 1)`), but a longer one
  #     never does (`n = 1 AND n IN (2, 3)` does not fold, nor does `n IN (NULL, 1) AND n = 2`),
  #     and no `OR` or `NOT` is looked into (`(n = 1 AND n = 2) OR (n = 3 AND n = 4)` does not
  #     fold)
  #
  # The operand is any expression, compared by its text (`n + 1 = 1 AND n + 1 = 2`), the
  # literal any constant expression, and the two fold only when they are compared in the same
  # form, the form the engine's coercion gives the comparison: `n = 1.5` casts the column to
  # `Float64`, so `n = 1 AND n = 2.5` does not fold. A string beside an integer column is read
  # as the integer only when it is that integer's own text (`'1'` but not `'01'`, `'+1'` or
  # `' 1'`), else the column is compared as text; a string beside a float column is always text;
  # a number beside a text column is its text. A boolean never folds (`b = true AND b = false`).
  #
  # The engine folds more than that, in ways the double has not verified: a `NULL` in an `IN`
  # list beside an equality or a `NULL`, `time IS NULL` (time is never null), a `NOT IN` beside
  # a test of its operand, a group of an `OR` that repeats a branch. What this does not know it
  # says so (`unknown/3`, `uncertainty/2`, `grouped_overlap?/1`) instead of guessing: the caller
  # refuses by name a query whose answer depends on it.

  alias InfluxElixir.Client.Local.{SQLExpr, SQLExprType, SQLFold}

  @typep types :: %{binary() => binary()}
  @typep clause :: tuple()
  @typep operand :: binary() | {:expr, SQLExpr.t()}
  @typep form :: atom()
  @typep keyed :: {form(), term()} | :null | :unknown | :skip

  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807
  @u64_max 18_446_744_073_709_551_615
  @text_types ["Utf8", "Utf8View", "Dictionary(Int32, Utf8)"]

  @doc """
  The two `IN` clauses of one `AND`, folded: `:none` when they do not fold, `:empty` when they
  share no value, `{:ok, clause}` for the list of the values they share.
  """
  @spec intersect(clause(), clause(), types()) :: :none | :empty | {:ok, clause()}
  def intersect({:in, left, xs}, {:in, other, ys}, types) when is_list(xs) and is_list(ys) do
    if same_operand?(left, other) and nil not in xs and nil not in ys,
      do: intersect_lists(left, {xs, ys}, class(left, types), types),
      else: :none
  end

  def intersect(_left, _right, _types), do: :none

  @doc """
  The same for two `IN` lists of which one holds a `NULL`: they fold into the list of the
  values they share when they are the whole filter (`n IN (NULL, 1) AND n IN (2)`, verified);
  beside other clauses the engine folds some and not others, and the double does not say.
  """
  @spec intersect_nulls(clause(), clause(), types()) :: :none | :empty | {:ok, clause()}
  def intersect_nulls({:in, left, xs}, {:in, other, ys}, types)
      when is_list(xs) and is_list(ys) do
    if same_operand?(left, other) and (nil in xs or nil in ys),
      do: intersect_lists(left, {xs, ys}, class(left, types), types),
      else: :none
  end

  def intersect_nulls(_left, _right, _types), do: :none

  @spec intersect_lists(operand(), {[term()], [term()]}, atom(), types()) ::
          :none | :empty | {:ok, clause()}
  defp intersect_lists(operand, {xs, ys}, class, types) do
    cond do
      nulls?(xs) and nulls?(ys) -> :empty
      nulls?(xs) -> if plain_list?(class, ys), do: :empty, else: :none
      nulls?(ys) -> if plain_list?(class, xs), do: :empty, else: :none
      respelled?(class, xs) or respelled?(class, ys) -> :none
      true -> fold(operand, xs, ys, types)
    end
  end

  @spec fold(operand(), [term()], [term()], types()) :: :none | :empty | {:ok, clause()}
  defp fold(operand, xs, ys, types) do
    class = class(operand, types)

    with false <- texts?(class, xs) or texts?(class, ys),
         {form, left_values} <- list_keys(class, xs),
         {^form, right_values} <- list_keys(class, ys) do
      shared = for {value, original} <- left_values, member?(right_values, value), do: original
      if shared == [], do: :empty, else: {:ok, {:in, operand, shared}}
    else
      _no_fold -> :none
    end
  end

  @doc """
  Whether a query holds two `IN`-family lists of one operand where the engine folds the pair to a
  constant, and the constant is not what three-valued logic makes of the pair for a row whose
  operand is `NULL` (verified on Core, also with a `NULL` in a list and for the `NOT IN` of a
  list):

    * `IN` beside `IN`, or `IN` beside `NOT IN`, in an `AND` is `false` when the lists share no
      value (`n IN (0) AND n IN (1, 2)`), where a `NULL` row makes it `NULL`: the same when a
      filter keeps the row or not, and not when a `NOT` or an expression reads it
      (`NOT (n IN (0) AND n IN (1, 2))` is true for the rows where `n` is `NULL`)
    * `NOT IN` beside `NOT IN` or `IN` in an `OR` is `true` when the lists share no value
      (`n NOT IN (0, 1) OR n NOT IN (2)`), for a `NULL` row too, which a filter keeps and
      three-valued logic does not; `NOT (n IN (7)) OR NOT (n IN (0))` is the same

  The fold depends on the operand's type and on the engine's rule for a `NULL` in a list, which
  the double does not model, so a caller refuses it. `filters` are the `WHERE` and `HAVING`
  (what a filter keeps), `values` the select list and `ORDER BY` (what an expression is).
  """
  @spec fold_gap?(%{filters: [term()], values: [term()]}) :: boolean()
  def fold_gap?(%{filters: filters, values: values}),
    do: gap?(filters, :filter) or gap?(values, :value)

  @typep mode :: :filter | :value

  @spec gap?(term(), mode()) :: boolean()
  defp gap?({:and, _left, _right} = expr, mode) do
    chain = expr |> chain(:and) |> Enum.map(&polarity/1)
    (mode == :value and positive_pair?(chain)) or Enum.any?(chain(expr, :and), &gap?(&1, mode))
  end

  defp gap?({:or, _left, _right} = expr, mode) do
    members = chain(expr, :or)
    negative_pair?(Enum.map(members, &polarity/1)) or Enum.any?(members, &gap?(&1, mode))
  end

  defp gap?({:or, branches}, mode) when is_list(branches) do
    single = for [member] <- branches, do: polarity(member)
    negative_pair?(single) or Enum.any?(branches, &gap?(&1, mode))
  end

  defp gap?({:not, inner}, _mode), do: gap?(inner, :value)

  defp gap?(nodes, mode) when is_list(nodes) do
    (mode == :value and positive_pair?(Enum.map(nodes, &polarity/1))) or
      Enum.any?(nodes, &gap?(&1, mode))
  end

  defp gap?(%{nodes: nodes}, mode), do: gap?(nodes, mode)

  defp gap?(tuple, mode) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&gap?(&1, mode))

  defp gap?(_other, _mode), do: false

  # The operands of nested `AND`s (or `OR`s) of expressions, however they are grouped.
  @spec chain(term(), :and | :or) :: [term()]
  defp chain({op, left, right}, op), do: chain(left, op) ++ chain(right, op)
  defp chain(other, _op), do: [other]

  # Two members that test one operand against lists, one of them an `IN` (an `AND` folds it).
  @spec positive_pair?([{term(), boolean()} | nil]) :: boolean()
  defp positive_pair?(polarities), do: listed_pair?(polarities, false)

  # The same, one of them a `NOT IN` (an `OR` folds it).
  @spec negative_pair?([{term(), boolean()} | nil]) :: boolean()
  defp negative_pair?(polarities), do: listed_pair?(polarities, true)

  @spec listed_pair?([{term(), boolean()} | nil], boolean()) :: boolean()
  defp listed_pair?(polarities, negative?) do
    polarities
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.any?(fn {_operand, signs} -> match?([_, _ | _], signs) and negative? in signs end)
  end

  # The operand a member tests against a list and whether it is a `NOT IN` (a `NOT` of an `IN`
  # is one), else `nil`.
  @spec polarity(term()) :: {term(), boolean()} | nil
  defp polarity({op, operand, list}) when op in [:in, :not_in] and is_list(list),
    do: {operand_key(operand), op == :not_in}

  defp polarity({:in, operand, list, negated}) when is_list(list),
    do: {expr_key(operand), negated}

  defp polarity({:not, [member]}), do: flip(polarity(member))
  defp polarity({:not, member}) when is_tuple(member), do: flip(polarity(member))
  defp polarity(_member), do: nil

  @spec flip({term(), boolean()} | nil) :: {term(), boolean()} | nil
  defp flip({operand, negative?}), do: {operand, not negative?}
  defp flip(nil), do: nil

  @spec expr_key(term()) :: term()
  defp expr_key({:field, name}) when is_binary(name), do: name
  defp expr_key(other), do: {:expr, other}

  @doc """
  Whether two equalities of the clauses (top-level conjuncts) are to different values. The
  equalities of an operand that is an expression (`abs(n) = 1 AND abs(n) = 2`) fold only when
  the first conjunct is one of them (verified: with another conjunct before them, the engine
  does not fold them), and are not looked into otherwise (`unknown/3` says so).
  """
  @spec conflict?([clause()], types()) :: boolean()
  def conflict?(clauses, types) do
    clauses |> conflicts(types) |> Enum.any?(&(is_binary(&1) or first?(&1, clauses, types)))
  end

  # The operands compared to different values.
  @spec conflicts([clause()], types()) :: [term()]
  defp conflicts(clauses, types) do
    clauses
    |> Enum.flat_map(&equality(&1, types))
    |> Enum.group_by(fn {operand, form, _value} -> {operand, form} end, &elem(&1, 2))
    |> Enum.filter(fn {_group, values} -> not Enum.all?(values, &(&1 == hd(values))) end)
    |> Enum.map(fn {{operand, _form}, _values} -> operand end)
  end

  # Whether the first conjunct is an equality of the operand.
  @spec first?(term(), [clause()], types()) :: boolean()
  defp first?(operand, [first | _rest], types),
    do: Enum.any?(equality(first, types), &(elem(&1, 0) == operand))

  defp first?(_operand, [], _types), do: false

  # Whether an expression is compared to different values where the double does not know that
  # the engine folds them (the first conjunct is not one of them).
  @spec late_conflict?([clause()], types()) :: boolean()
  defp late_conflict?(clauses, types) do
    clauses
    |> conflicts(types)
    |> Enum.any?(&(is_tuple(&1) and not first?(&1, clauses, types)))
  end

  @typedoc """
  A shape the double has no verified rule for (see `uncertainty/2`): `:time_null` a test of
  `time` for `NULL`, `:null_list` a `NULL` in an `IN` list beside a clause the engine folds it
  with, `:not_in` a `NOT IN` beside another test of its operand, `:respelled` a list that writes
  one value in two spellings, `:float` an integer equal to a float beside two more tests, and
  `:late_conflict` an expression compared to different values with a first conjunct that is
  none of them.
  """
  @type uncertainty ::
          :time_null | :null_list | :not_in | :respelled | :float | :late_conflict

  @doc """
  What the double does not know of a `WHERE` that has a negation: the `uncertainty/2` of its
  predicates, or that it compares an expression to different values with a first conjunct that
  is none of them (the engine folds only those), `:literals` when its top-level conjuncts
  compare one operand to two or more different literals of which one is of a kind that is not
  modelled, else `nil`. `clauses` are the predicates wherever they stand, `where` the conjuncts
  of the whole (the engine looks into no `OR` or `NOT` for equalities that contradict).
  """
  @spec unknown([clause()], [term()], types()) :: uncertainty() | :literals | nil
  def unknown(clauses, where, types) do
    cond do
      cause = uncertainty(clauses, types) -> cause
      late_conflict?(where, types) -> :late_conflict
      shared_unmodelled?(where, types) -> :literals
      true -> nil
    end
  end

  @doc """
  Whether an operand that an `OR` or a `NOT` of a `WHERE` compares to literals is also tested
  by the whole: the engine simplifies the group first (it drops a repeated branch, and the
  equalities of an `OR` are one `IN` list) and may then fold it with an `IN` list of two or
  more values of that operand at the top (`n IN (3, 4) AND (n IN (2, 2) OR n = 1)`), or with
  an equality when it dropped a branch (`n = 2 AND (n = 1 OR 1 = n)`). A group of different
  values beside an equality is not (`n = 1 AND (n = 2 OR n = 3)`, verified).
  """

  @spec grouped_overlap?([term()]) :: boolean()
  def grouped_overlap?(where) do
    top_lists =
      for {:in, operand, literals} <- where,
          is_list(literals),
          match?([_first, _second | _more], Enum.uniq(literals)),
          do: operand_key(operand)

    top = for {op, operand, _rest} <- where, op in [:eq, :in, :not_in], do: operand_key(operand)

    where
    |> Enum.flat_map(&groups/1)
    |> Enum.any?(fn items -> Enum.any?(items, &overlaps?(&1, items, top_lists, top)) end)
  end

  @spec overlaps?({term(), [term()]}, [{term(), [term()]}], [term()], [term()]) ::
          boolean()
  defp overlaps?({key, _literals}, items, top_lists, top) do
    literals = for {^key, list} <- items, value <- list, do: value
    key in top_lists or (key in top and length(literals) != length(Enum.uniq(literals)))
  end

  @doc """
  Whether a `WHERE` tests one operand with an `IN` list and a `NOT IN` list of which one holds
  a `NULL`: the engine takes the one list out of the other (`n IN (5, NULL) AND n NOT IN (NULL,
  3)` keeps `n = 5`, verified), where three-valued logic keeps no row, and the double does not
  model that.
  """
  @spec null_difference?([term()]) :: boolean()
  def null_difference?(where) do
    lists = where |> collect_lists([]) |> Enum.reverse()

    Enum.any?(lists, fn
      {:in, key, literals} ->
        Enum.any?(lists, fn
          {:not_in, ^key, other} -> nil in literals or nil in other
          _other -> false
        end)

      _not_in ->
        false
    end)
  end

  @spec collect_lists(term(), [{atom(), term(), [term()]}]) :: [{atom(), term(), [term()]}]
  defp collect_lists({op, operand, literals}, found)
       when op in [:in, :not_in] and is_list(literals),
       do: [{op, operand_key(operand), literals} | found]

  defp collect_lists({:or, branches}, found), do: collect_lists(Enum.concat(branches), found)
  defp collect_lists({:not, nodes}, found), do: collect_lists(nodes, found)

  defp collect_lists(nodes, found) when is_list(nodes),
    do: Enum.reduce(nodes, found, &collect_lists/2)

  defp collect_lists(_node, found), do: found

  # The comparisons to literals of each `OR` and `NOT` group of a clause, as `{operand, list}`.
  @spec groups(term()) :: [[{term(), [term()]}]]
  defp groups({:or, branches}), do: group_of(Enum.concat(branches))
  defp groups({:not, nodes}), do: group_of(nodes)
  defp groups(_clause), do: []

  @spec group_of([term()]) :: [[{term(), [term()]}]]
  defp group_of(nodes) do
    items =
      for {op, operand, rest} <- nodes,
          is_tuple(operand) or is_binary(operand),
          op in [:eq, :in, :not_in],
          do: {operand_key(operand), List.wrap(rest)}

    [items | Enum.flat_map(nodes, &groups/1)]
  end

  # Shapes whose folding the double has not verified, so that it does not guess:
  #
  #   * a `NULL` in an `IN` list beside a clause the engine folds it with in a way the double
  #     does not read (see `foldable_with_null?/3`), and a `NOT IN` list with a `NULL`
  #   * a test of `time` for `NULL` (it is never null, and the engine proves it)
  #   * a `NOT IN` beside another test of its operand
  #   * a list whose literals are written in different spellings of one value (`IN (1, '1')`)
  #   * an integer equal to a float beside two more tests (the engine fails internally)
  @doc "The first shape of the kind named above that the clauses hold, or `nil`."
  @spec uncertainty([clause()], types()) :: uncertainty() | nil
  def uncertainty(clauses, types) do
    cond do
      Enum.any?(clauses, &time_null?/1) -> :time_null
      null_list_beside?(clauses) -> :null_list
      not_in_beside?(clauses) -> :not_in
      Enum.any?(clauses, &respelled_clause?(&1, types)) -> :respelled
      float_beside?(clauses, types) -> :float
      true -> nil
    end
  end

  @spec time_null?(clause()) :: boolean()
  defp time_null?({op, "time", _nil}) when op in [:is_null, :is_not_null], do: true
  defp time_null?(_clause), do: false

  @spec null_list_beside?([clause()]) :: boolean()
  defp null_list_beside?(clauses) do
    Enum.any?(clauses, fn
      {:not_in, _operand, literals} when is_list(literals) ->
        nil in literals

      {:in, operand, literals} = clause when is_list(literals) ->
        nil in literals and
          Enum.any?(List.delete(clauses, clause), &foldable_with_null?(&1, operand, literals))

      _clause ->
        false
    end)
  end

  # Whether a clause beside `operand IN (literals)`, which holds a `NULL`, is folded with it
  # in a way the double does not read. Verified on Core: a range comparison with a value is
  # not, and an equality is not with a list that holds a value beside its `NULL` (`n IN (NULL,
  # 1) AND n = 2` is not empty). A list of nothing but `NULL` is a `NULL` to the engine, which
  # folds it with most things; any list with a `NULL` is folded with a `NULL`, a test for
  # `NULL`, a `NOT IN` of its operand and an `IN` list of its operand that is not beside it in
  # the tree (the double reads only the lists that are, `intersect/3`).
  @spec foldable_with_null?(clause(), term(), [term()]) :: boolean()
  defp foldable_with_null?({op, _operand, value}, _other, _literals)
       when op in [:gt, :gte, :lt, :lte],
       do: value == nil

  defp foldable_with_null?({:eq, _operand, nil}, _other, _literals), do: true
  defp foldable_with_null?({:eq, _operand, _literal}, _other, literals), do: nulls?(literals)

  defp foldable_with_null?({:in, operand, list}, other, literals) when is_list(list),
    do: operand_key(operand) == operand_key(other) or nulls?(literals) or nulls?(list)

  defp foldable_with_null?({:not_in, operand, _list}, other, literals),
    do: operand_key(operand) == operand_key(other) or nulls?(literals)

  defp foldable_with_null?({:truthy_expr, _expr, _nil}, _other, _literals), do: true

  defp foldable_with_null?({op, _operand, _nil}, _other, _literals)
       when op in [:is_null, :is_not_null],
       do: true

  defp foldable_with_null?(_clause, _other, _literals), do: false

  # An integer operand compared for equality to a float and to something else, with a third
  # test in the query: the engine's range analysis fails with an internal error (verified:
  # `n IN (2) AND n > 0 AND n = 1.5`, `n IN (2) AND g > 0 AND n = 1.5`), which the double does
  # not reproduce.
  @spec float_beside?([clause()], types()) :: boolean()
  defp float_beside?(clauses, types) do
    Enum.any?(clauses, fn clause ->
      with {op, operand, rest} when op in [:eq, :in] <- clause,
           true <- class(operand, types) in [:i64, :u64],
           true <- Enum.any?(List.wrap(rest), &is_float/1) do
        length(clauses) >= 3 and
          Enum.count(clauses, &(elem(&1, 0) in [:eq, :in] and elem(&1, 1) == operand)) >= 2
      else
        _other -> false
      end
    end)
  end

  @spec not_in_beside?([clause()]) :: boolean()
  defp not_in_beside?(clauses) do
    tested =
      for {op, operand, _rest} <- clauses, op in [:eq, :in], do: operand_key(operand)

    Enum.any?(clauses, fn
      {:not_in, operand, _literals} -> operand_key(operand) in tested
      _clause -> false
    end)
  end

  @spec respelled_clause?(clause(), types()) :: boolean()
  defp respelled_clause?({:in, operand, literals}, types) when is_list(literals),
    do: respelled?(class(operand, types), literals)

  defp respelled_clause?(_clause, _types), do: false

  # A list of several literals the engine reads as one value (`IN (1, '1')`).
  @spec respelled?(atom(), [term()]) :: boolean()
  defp respelled?(class, literals) do
    match?([_, _ | _], literals |> Enum.reject(&is_nil/1) |> Enum.uniq()) and
      match?({_form, [_one]}, list_keys(class, literals))
  end

  # A list of literals of the kind of the column itself (`NULL` aside), none of them a string
  # beside a number.
  @spec plain_list?(atom(), [term()]) :: boolean()
  defp plain_list?(class, literals) do
    Enum.all?(literals, fn
      nil ->
        true

      literal ->
        case {class, key(class, literal)} do
          {:text, {:text, _text}} -> is_binary(literal)
          {class, {class, _value}} when class in [:i64, :u64, :f64] -> not is_binary(literal)
          _other -> false
        end
    end)
  end

  @spec shared_unmodelled?([clause()], types()) :: boolean()
  defp shared_unmodelled?(clauses, types) do
    clauses
    |> Enum.flat_map(&compared/1)
    |> Enum.group_by(&operand_key(elem(&1, 0)), & &1)
    |> Enum.any?(fn {_operand, members} ->
      match?([_, _ | _], members) and differing?(members) and
        Enum.any?(members, &unmodelled?(&1, types))
    end)
  end

  # Two or more different literals: the same one written again cannot contradict itself.
  @spec differing?([{operand(), :eq | :in, [term()]}]) :: boolean()
  defp differing?(members),
    do: match?([_, _ | _], members |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq())

  # ---------------------------------------------------------------------------
  # The clauses
  # ---------------------------------------------------------------------------

  # The equalities a clause stands for, `{operand, form, value}`.
  @spec equality(clause(), types()) :: [{term(), form(), term()}]
  defp equality({:eq, operand, literal}, types) when literal != nil do
    case key(class(operand, types), literal) do
      {form, value} -> [{operand_key(operand), form, value}]
      _other -> []
    end
  end

  # A list is an equality when it is one literal, however often it is written (`n IN (1, 1)`,
  # verified); a `NULL` or a second literal of another spelling (`IN (1, '1')`, `IN (NULL, 1)`)
  # makes it no equality, and `unknown?/2` says that the engine's reading of it is not known.
  defp equality({:in, operand, literals}, types) when is_list(literals) do
    with [_one] <- Enum.uniq(literals),
         {form, [{value, _original}]} <- list_keys(class(operand, types), literals) do
      [{operand_key(operand), form, value}]
    else
      _other -> []
    end
  end

  defp equality(_clause, _types), do: []

  # The clauses that compare an operand to literals: `{operand, kind, literals}`.
  @spec compared(clause()) :: [{operand(), :eq | :in, [term()]}]
  defp compared({:eq, operand, literal}) when literal != nil, do: [{operand, :eq, [literal]}]
  defp compared({:in, operand, literals}) when is_list(literals), do: [{operand, :in, literals}]
  defp compared(_clause), do: []

  @spec unmodelled?({operand(), :eq | :in, [term()]}, types()) :: boolean()
  defp unmodelled?({operand, kind, literals}, types) do
    class = class(operand, types)

    class != :bool and
      case kind do
        :eq ->
          Enum.any?(literals, &(key(class, &1) == :unknown))

        :in ->
          list_keys(class, literals) == :unknown and Enum.any?(literals, &(&1 != nil)) and
            not texts?(class, literals)
      end
  end

  # A list of several values beside a number column, with strings that are all numbers: the
  # engine casts them to the column's type after it has looked for what folds, so it does not
  # fold them (`u IN ('1', '2') AND u IN (3, 4)` stays, where a list of one string is an
  # equality, and a string that is not a number makes the comparison one of text, which folds).
  @spec texts?(atom(), [term()]) :: boolean()
  defp texts?(class, literals) do
    values = Enum.reject(literals, &is_nil/1)
    strings = Enum.filter(values, &is_binary/1)

    class in [:i64, :u64, :f64] and match?([_, _ | _], values) and strings != [] and
      Enum.all?(strings, &match?({_number, ""}, Float.parse(&1)))
  end

  # A list of nothing but `NULL`, which shares no value with any list.
  @spec nulls?([term()]) :: boolean()
  defp nulls?(literals), do: literals != [] and Enum.all?(literals, &is_nil/1)

  @spec same_operand?(operand(), operand()) :: boolean()
  defp same_operand?(left, right), do: operand_key(left) == operand_key(right)

  # A column is the same operand however it is written (`n`, `m.n`).
  @spec operand_key(operand()) :: term()
  defp operand_key({:expr, {:field, name}}) when is_binary(name), do: name
  defp operand_key({:expr, expr}), do: {:expr, expr}
  defp operand_key(column), do: column

  # ---------------------------------------------------------------------------
  # The form a literal is compared in
  # ---------------------------------------------------------------------------

  @spec class(operand(), types()) :: atom()
  defp class(operand, types) do
    case operand_type(operand, types) do
      "Int64" -> :i64
      "UInt64" -> :u64
      "Float64" -> :f64
      "Boolean" -> :bool
      "Timestamp(ns)" -> :ts
      type when type in @text_types -> :text
      _other -> :other
    end
  end

  @spec operand_type(operand(), types()) :: term()
  defp operand_type({:expr, expr}, types), do: SQLExprType.known_type(expr, types)

  defp operand_type(column, types), do: Map.get(types, column)

  # The elements of a list in the form of the whole list: one form for all of them, or integers
  # and floats together, which the engine compares as floats. `NULL` shares nothing and is left
  # out. `:unknown` for a list that mixes other kinds.
  @spec list_keys(atom(), [term()]) :: {form(), [{term(), term()}]} | :unknown
  defp list_keys(class, literals) do
    class = if textual?(class, literals), do: :text, else: class
    keyed = for literal <- literals, (k = key(class, literal)) != :null, do: {k, literal}
    forms = keyed |> Enum.map(fn {k, _literal} -> form_of(k) end) |> Enum.uniq()

    cond do
      Enum.any?(keyed, fn {k, _literal} -> k in [:unknown, :skip] end) ->
        :unknown

      keyed == [] ->
        :unknown

      match?([_one], forms) ->
        {hd(forms), dedupe(for {{_form, v}, original} <- keyed, do: {v, original})}

      Enum.sort(forms) == [:f64, :i64] ->
        {:f64, promote(keyed)}

      true ->
        :unknown
    end
  end

  # A list beside a number column with a string that is not a number: the engine compares the
  # column as text, every value of the list as its text.
  @spec textual?(atom(), [term()]) :: boolean()
  defp textual?(class, literals) do
    class in [:i64, :u64, :f64] and
      Enum.any?(literals, &(is_binary(&1) and not match?({_number, ""}, Float.parse(&1))))
  end

  @spec form_of(keyed()) :: form() | keyed()
  defp form_of({form, _value}), do: form
  defp form_of(other), do: other

  @spec promote([{keyed(), term()}]) :: [{term(), term()}]
  defp promote(keyed) do
    keyed
    |> Enum.map(fn
      {{:i64, v}, original} -> {v * 1.0, original}
      {{:f64, v}, original} -> {v, original}
    end)
    |> dedupe()
  end

  @spec dedupe([{term(), term()}]) :: [{term(), term()}]
  defp dedupe(pairs), do: Enum.uniq_by(pairs, fn {value, _original} -> value end)

  @spec member?([{term(), term()}], term()) :: boolean()
  defp member?(pairs, value), do: Enum.any?(pairs, fn {other, _original} -> other == value end)

  # One literal against an operand of a class: the form it is compared in and its value there.
  @spec key(atom(), term()) :: keyed()
  defp key(_class, nil), do: :null
  defp key(:bool, _literal), do: :skip
  defp key(:other, _literal), do: :unknown
  defp key(class, {:uint, value}), do: key(class, value)

  defp key(:i64, value) when is_integer(value) and value in @i64_min..@i64_max,
    do: {:i64, value}

  defp key(:i64, value) when is_integer(value), do: {:wide, value}
  defp key(:i64, value) when is_float(value), do: {:f64, value}
  defp key(:i64, text) when is_binary(text), do: integer_text(text, @i64_min, @i64_max, :i64)

  defp key(:u64, value) when is_integer(value) and value in 0..@u64_max, do: {:u64, value}
  defp key(:u64, value) when is_integer(value) and value < 0, do: {:negative, value}
  defp key(:u64, value) when is_integer(value), do: {:wide, value}
  defp key(:u64, value) when is_float(value), do: {:f64, value}
  defp key(:u64, text) when is_binary(text), do: integer_text(text, 0, @u64_max, :u64)

  defp key(:f64, value) when is_integer(value), do: {:f64, value * 1.0}
  defp key(:f64, value) when is_float(value), do: {:f64, value}
  defp key(:f64, text) when is_binary(text), do: {:text, text}

  defp key(:text, text) when is_binary(text), do: {:text, text}
  defp key(:text, value) when is_integer(value), do: {:text, Integer.to_string(value)}
  defp key(:text, value) when is_float(value), do: float_text(value)

  defp key(:ts, value) when is_integer(value), do: {:ts, value}

  # An expression of the literal's place: its value when it reads no column, and no equality
  # to a constant when it does (`n = v`).
  defp key(class, {:expr, expr}) do
    if SQLExpr.columns(expr) == [],
      do: constant_key(class, SQLFold.constant(expr)),
      else: :skip
  end

  defp key(_class, _literal), do: :unknown

  @spec constant_key(atom(), {:ok, term()} | :error) :: keyed()
  defp constant_key(class, {:ok, value}) when is_number(value) or is_binary(value),
    do: key(class, value)

  defp constant_key(_class, _folded), do: :unknown

  # A string is the integer it spells only when it is that integer's own text; any other string
  # leaves the column compared as text.
  @spec integer_text(binary(), integer(), integer(), atom()) :: keyed()
  defp integer_text(text, low, high, form) do
    case Integer.parse(text) do
      {value, ""} when value >= low and value <= high ->
        if Integer.to_string(value) == text, do: {form, value}, else: {:text, text}

      _text ->
        {:text, text}
    end
  end

  # A float as the engine writes it as text, for the plain numbers only.
  @spec float_text(float()) :: keyed()
  defp float_text(value) when abs(value) >= 1.0e-4 and abs(value) < 1.0e15,
    do: {:text, Float.to_string(value)}

  defp float_text(value) when value == 0.0, do: {:text, "0.0"}
  defp float_text(_value), do: :unknown
end
