defmodule InfluxElixir.Client.Local.SQLBatch do
  @moduledoc false
  # The order in which InfluxDB 3 Core evaluates the operands of a `WHERE`, for
  # `InfluxElixir.Client.Local`: what decides whether an operand that fails for
  # some row (`100 / n` for `n = 0`, an overflowing `abs`) fails the query when
  # another operand would have left that row out.
  #
  # A conjunction is not run row by row. The engine reads a table in one of two
  # states, and the two evaluate it differently (verified, by `EXPLAIN` and by
  # probing the same data before and after Core persisted it):
  #
  #   * **A fresh write** (still in the write buffer): a conjunct over tag
  #     columns only is applied by the scan, before the rows are deduplicated,
  #     so it leaves a row out for every other conjunct, whatever its place. A
  #     conjunct over tags and `time` only is applied there too. The other
  #     conjuncts run in the written order over a batch of rows: the right side
  #     of an `AND` runs over the whole batch, or over the rows the left side
  #     selects when that is under a fifth of the batch (and over none when
  #     the left side selects none). The batches do not follow the rows.
  #   * **A persisted table** (Parquet): the conjuncts are row filters, each run
  #     over the rows the ones before it kept, ordered by the compressed size of
  #     the columns they read. A conjunct over a tag column is the cheapest; one
  #     over a subset of another's columns is cheaper than it; two over the same
  #     columns keep the written order; any other pair is ordered by sizes the
  #     double does not know. `time` is not cheap.
  #
  # An operand that fails for a row it is run over fails the query by closing
  # the connection. Whether it is run over a row that another conjunct leaves out
  # can therefore differ between the two states, and between two tables of the
  # same data. The double answers a query only when the outcome is the same in
  # both: no row reaches a failing operand, or a row does and it fails in both
  # states, or a tag conjunct leaves every failing row out. Any other query
  # is refused by name.
  #
  # A refusal of the double itself (a NaN compared, a decimal it does not
  # model), or a NaN, in an operand a row does not reach is not a failure: the
  # row is left out as the operand before it decides. An error the engine raises
  # at planning (an operator applied to the wrong type) fails the query whatever
  # the rows are.

  alias InfluxElixir.Client.Local.{SQLCondition, SQLError, SQLExpr, SQLParser, SQLRow, SQLWhere}

  @typep point :: SQLRow.point()
  @typep verdict :: boolean() | nil
  @typep risk ::
           :none | :maybe | :fail | {:refused, SQLError.t()} | {:error, SQLError.t()}
  @typep entry :: {verdict(), risk()}
  @typep state :: :ok | :maybe | :fail
  @typep kind :: :tag | :time | :constant | :other
  @typep plan :: %{columns: tuple(), kinds: tuple(), fallible: [non_neg_integer()]}
  @typep acc :: %{
           kept: [point()],
           counts: %{non_neg_integer() => non_neg_integer()},
           fresh: state(),
           persisted: state(),
           pending: MapSet.t(non_neg_integer())
         }

  @state_rank %{ok: 0, maybe: 1, fail: 2}

  @doc """
  Whether an operand that can fail stands beside another one of a `WHERE`, so
  that the order the engine runs them in decides the query.
  """
  @spec guarded?([SQLParser.where_node()]) :: boolean()
  def guarded?(conjunction) do
    (multiple?(conjunction) and Enum.any?(conjunction, &fallible?/1)) or
      Enum.any?(conjunction, &nested_guard?/1)
  end

  @spec nested_guard?(SQLParser.where_node()) :: boolean()
  defp nested_guard?({:or, branches}) do
    (multiple?(branches) and Enum.any?(branches, &fallible_conjunction?/1)) or
      Enum.any?(branches, &guarded?/1)
  end

  defp nested_guard?({:not, conjunction}), do: guarded?(conjunction)
  defp nested_guard?(_clause), do: false

  @spec multiple?([term()]) :: boolean()
  defp multiple?([_first, _second | _rest]), do: true
  defp multiple?(_parts), do: false

  @spec fallible_conjunction?([SQLParser.where_node()]) :: boolean()
  defp fallible_conjunction?(conjunction), do: Enum.any?(conjunction, &fallible?/1)

  @spec fallible?(SQLParser.where_node()) :: boolean()
  defp fallible?(node),
    do: node |> SQLWhere.exprs() |> Enum.any?(fn expr -> SQLExpr.any?(expr, &can_fail?/1) end)

  @spec can_fail?(SQLExpr.t()) :: boolean()
  defp can_fail?({:op, op, _left, _right}), do: op in [:/, :rem]
  defp can_fail?({:call, _function, _args}), do: true
  defp can_fail?({:neg, _inner}), do: true
  defp can_fail?({:cast, _inner, _type}), do: true
  defp can_fail?(_other), do: false

  @doc """
  The refusal for a query whose outcome the engine's two storage states
  settle differently.
  """
  @spec refusal() :: SQLError.t()
  def refusal do
    SQLError.refusal(
      "a WHERE whose AND or OR runs an operand that fails over a row the other operand " <>
        "leaves out: whether the engine fails the query depends on how the table is stored " <>
        "(freshly written or persisted) and on how it batches the rows"
    )
  end

  @doc """
  The points that satisfy a conjunction, or the throw of `{:query_error, error}`
  the engine's outcome calls for: the closed connection when the query fails
  in both storage states, the refusal when the two differ.
  """
  @spec filter([point()], [SQLParser.where_node()]) :: [point()]
  def filter(points, conjunction) do
    plan = plan(points, conjunction)

    start = %{
      kept: [],
      counts: %{},
      fresh: :ok,
      persisted: :ok,
      pending: MapSet.new()
    }

    result = Enum.reduce(points, start, &row(&1, conjunction, plan, &2))

    case outcome(result) do
      :answer -> Enum.reverse(result.kept)
      :closed -> throw({:query_error, SQLError.closed()})
      :refuse -> throw({:query_error, refusal()})
    end
  end

  # ---------------------------------------------------------------------------
  # What each conjunct reads
  # ---------------------------------------------------------------------------

  @spec plan([point()], [SQLParser.where_node()]) :: plan()
  defp plan(points, conjunction) do
    columns = Enum.map(conjunction, &MapSet.new(SQLWhere.columns(&1)))
    tags = tag_columns(points, columns)

    %{
      columns: List.to_tuple(columns),
      kinds: columns |> Enum.map(&kind(&1, tags)) |> List.to_tuple(),
      fallible: for({node, index} <- Enum.with_index(conjunction), fallible?(node), do: index)
    }
  end

  # A column is a tag when any point holds it as one.
  @spec tag_columns([point()], [MapSet.t(binary())]) :: MapSet.t(binary())
  defp tag_columns(points, columns) do
    columns
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    |> MapSet.delete("time")
    |> Enum.filter(fn name -> Enum.any?(points, &Map.has_key?(&1.tags, name)) end)
    |> MapSet.new()
  end

  @spec kind(MapSet.t(binary()), MapSet.t(binary())) :: kind()
  defp kind(columns, tags) do
    cond do
      MapSet.size(columns) == 0 -> :constant
      MapSet.subset?(columns, tags) -> :tag
      columns |> MapSet.delete("time") |> MapSet.subset?(tags) -> :time
      true -> :other
    end
  end

  # ---------------------------------------------------------------------------
  # One row
  # ---------------------------------------------------------------------------

  @spec row(point(), [SQLParser.where_node()], plan(), acc()) :: acc()
  defp row(point, conjunction, plan, acc) do
    entries = Enum.map(conjunction, &probe(point, &1))
    throw_plan_error(entries)
    throw_refusal(entries, plan)

    if pruned?(entries, plan) do
      acc
    else
      verdicts = Enum.map(entries, &verdict/1)

      acc
      |> count_prefixes(verdicts, plan)
      |> hazards(entries, verdicts, plan)
      |> keep(point, entries)
    end
  end

  # The verdict a conjunct gives the others' reach: a failing one or one the
  # double declines to compute does not leave a row out.
  @spec verdict(entry()) :: verdict()
  defp verdict({_value, :fail}), do: true
  defp verdict({_value, {:refused, _error}}), do: true
  defp verdict({value, _risk}), do: value

  @spec keep(acc(), point(), [entry()]) :: acc()
  defp keep(acc, point, entries) do
    if Enum.all?(entries, &match?({true, risk} when risk in [:none, :maybe], &1)),
      do: %{acc | kept: [point | acc.kept]},
      else: acc
  end

  @spec throw_plan_error([entry()]) :: :ok
  defp throw_plan_error(entries) do
    case Enum.find(entries, &match?({_value, {:error, _error}}, &1)) do
      {_value, {:error, error}} -> throw({:query_error, error})
      nil -> :ok
    end
  end

  # A refusal the evaluation of a conjunct raises for a row that reaches it:
  # the tag conjuncts first, as the engine runs them, then the others in the
  # order written, until one leaves the row out.
  @spec throw_refusal([entry()], plan()) :: :ok
  defp throw_refusal(entries, plan) do
    entries
    |> Enum.with_index()
    |> Enum.sort_by(fn {_entry, index} -> kind_at(plan, index) != :tag end)
    |> Enum.reduce_while(:ok, fn
      {{_value, {:refused, error}}, _index}, _acc -> throw({:query_error, error})
      {{false, risk}, _index}, _acc when risk in [:none, :maybe] -> {:halt, :ok}
      {_entry, _index}, acc -> {:cont, acc}
    end)
  end

  # A row a conjunct over tags leaves out is never run through the others.
  @spec pruned?([entry()], plan()) :: boolean()
  defp pruned?(entries, plan) do
    entries
    |> Enum.with_index()
    |> Enum.any?(fn {entry, index} ->
      kind_at(plan, index) == :tag and verdict(entry) != true
    end)
  end

  @spec kind_at(plan(), non_neg_integer()) :: kind()
  defp kind_at(plan, index), do: elem(plan.kinds, index)

  @spec columns_at(plan(), non_neg_integer()) :: MapSet.t(binary())
  defp columns_at(plan, index), do: elem(plan.columns, index)

  # How many rows each conjunct that can fail is run over when the ones before
  # it run first.
  @spec count_prefixes(acc(), [verdict()], plan()) :: acc()
  defp count_prefixes(acc, _verdicts, %{fallible: []}), do: acc

  defp count_prefixes(acc, verdicts, %{fallible: fallible}) do
    counts =
      Enum.reduce(fallible, acc.counts, fn index, counts ->
        if verdicts |> Enum.take(index) |> Enum.all?(&(&1 == true)),
          do: Map.update(counts, index, 1, &(&1 + 1)),
          else: counts
      end)

    %{acc | counts: counts}
  end

  # ---------------------------------------------------------------------------
  # The two states
  # ---------------------------------------------------------------------------

  @spec hazards(acc(), [entry()], [verdict()], plan()) :: acc()
  defp hazards(acc, entries, verdicts, plan) do
    not_true = for {value, index} <- Enum.with_index(verdicts), value != true, do: index

    entries
    |> Enum.with_index()
    |> Enum.reduce(acc, fn
      {{_value, risk}, index}, acc when risk in [:fail, :maybe] ->
        acc
        |> fold_fresh(index, risk, fresh_reach(index, not_true, plan))
        |> fold_persisted(risk, persisted_reach(index, not_true, plan))

      {_entry, _index}, acc ->
        acc
    end)
  end

  # Whether the engine runs a conjunct over a row that `not_true` conjuncts do
  # not keep, on a fresh write: always when it reads no column; never when a
  # conjunct over `time` and tags leaves the row out; for certain when none
  # stands before it; otherwise by the density of the rows that reach it.
  @spec fresh_reach(non_neg_integer(), [non_neg_integer()], plan()) :: :yes | :no | :density
  defp fresh_reach(index, not_true, plan) do
    cond do
      kind_at(plan, index) == :constant -> :yes
      Enum.any?(not_true, &(kind_at(plan, &1) == :time)) -> :no
      Enum.all?(not_true, &(&1 > index)) -> :yes
      true -> :density
    end
  end

  # The same on a persisted table, where the order is the one of the columns'
  # sizes: a conjunct that reads fewer of the same columns, or the same ones
  # and stands before, is run first.
  @spec persisted_reach(non_neg_integer(), [non_neg_integer()], plan()) ::
          :yes | :no | :unknown
  defp persisted_reach(index, not_true, plan) do
    cond do
      not_true == [] -> :yes
      kind_at(plan, index) == :constant -> :unknown
      Enum.any?(not_true, &runs_before?(&1, index, plan)) -> :no
      Enum.all?(not_true, &runs_before?(index, &1, plan)) -> :yes
      true -> :unknown
    end
  end

  @spec runs_before?(non_neg_integer(), non_neg_integer(), plan()) :: boolean()
  defp runs_before?(first, second, plan) do
    {first_columns, second_columns} = {columns_at(plan, first), columns_at(plan, second)}

    cond do
      MapSet.equal?(first_columns, second_columns) -> first < second
      MapSet.size(first_columns) == 0 -> false
      true -> MapSet.subset?(first_columns, second_columns)
    end
  end

  @spec fold_fresh(acc(), non_neg_integer(), :fail | :maybe, :yes | :no | :density) :: acc()
  defp fold_fresh(acc, _index, _risk, :no), do: acc

  defp fold_fresh(acc, index, _risk, :density),
    do: %{acc | pending: MapSet.put(acc.pending, index)}

  defp fold_fresh(acc, _index, risk, :yes), do: %{acc | fresh: worst(acc.fresh, risk)}

  @spec fold_persisted(acc(), :fail | :maybe, :yes | :no | :unknown) :: acc()
  defp fold_persisted(acc, _risk, :no), do: acc
  defp fold_persisted(acc, risk, :yes), do: %{acc | persisted: worst(acc.persisted, risk)}
  defp fold_persisted(acc, _risk, :unknown), do: %{acc | persisted: worst(acc.persisted, :maybe)}

  @spec worst(state(), :fail | :maybe) :: state()
  defp worst(state, risk), do: if(@state_rank[state] >= @state_rank[risk], do: state, else: risk)

  @spec outcome(acc()) :: :answer | :closed | :refuse
  defp outcome(result) do
    dense? = Enum.any?(result.pending, &(Map.get(result.counts, &1, 0) > 0))
    fresh = if dense?, do: worst(result.fresh, :maybe), else: result.fresh

    case {fresh, result.persisted} do
      {:ok, :ok} -> :answer
      {:fail, :fail} -> :closed
      _differ -> :refuse
    end
  end

  # ---------------------------------------------------------------------------
  # Evaluating a node without stopping at its first failure
  # ---------------------------------------------------------------------------

  # `{verdict, risk}`: the node's three-valued value as the rows alone give it,
  # and whether evaluating it fails (`:fail`), may fail by how the engine runs
  # the operands inside it (`:maybe`), is refused by the double, or is an error
  # the engine raises at planning.
  @spec probe(point(), SQLParser.where_node()) :: entry()
  defp probe(point, {:or, branches}), do: walk(point, branches, :or)

  defp probe(point, {:not, conjunction}) do
    {value, risk} = walk(point, conjunction, :and)
    {SQLCondition.negate(value), risk}
  end

  defp probe(point, clause) do
    {SQLCondition.node_value(point, clause), :none}
  catch
    {:query_error, error} -> {nil, classify(error)}
  end

  @spec classify(term()) :: risk()
  defp classify({:connection_error, _reason}), do: :fail
  defp classify(%{status: 400, body: "Client.Local: " <> _rest} = error), do: {:refused, error}
  defp classify(error), do: {:error, error}

  # The parts of an `AND` (nodes) or of an `OR` (conjunctions) in order. A part
  # that follows the one that decides is skipped by the double and run by the
  # engine over the whole batch: it can only make the node `:maybe` fail.
  @spec walk(point(), [term()], :and | :or) :: entry()
  defp walk(point, parts, kind) do
    decisive = kind == :or

    parts
    |> Enum.reduce_while({not decisive, :none, false, true}, fn part, state ->
      point |> part_entry(part, kind) |> step(state, kind)
    end)
    |> case do
      {:done, value, risk} -> {value, risk}
      {value, risk, _decided, _clean} -> {value, risk}
    end
  end

  @spec part_entry(point(), term(), :and | :or) :: entry()
  defp part_entry(point, branch, :or), do: walk(point, branch, :and)
  defp part_entry(point, node, :and), do: probe(point, node)

  @spec step(entry(), {verdict(), risk(), boolean(), boolean()}, :and | :or) ::
          {:cont, term()} | {:halt, term()}
  defp step({_value, {:error, _error} = risk}, _state, _kind), do: {:halt, {:done, nil, risk}}

  defp step({_value, part_risk}, {acc, risk, true, clean}, _kind),
    do: {:cont, {acc, merge(risk, skipped(part_risk)), true, clean}}

  defp step({_value, {:refused, _error} = part_risk}, _state, _kind),
    do: {:halt, {:done, nil, part_risk}}

  defp step({_value, :fail}, {_acc, _risk, _decided, clean}, _kind),
    do: {:halt, {:done, nil, if(clean, do: :fail, else: :maybe)}}

  defp step({value, part_risk}, {acc, risk, _decided, clean}, kind) do
    risk = merge(risk, part_risk)
    decisive = kind == :or

    cond do
      value == decisive -> {:cont, {decisive, risk, true, clean}}
      is_nil(value) -> {:cont, {nil, risk, false, clean and kind == :or}}
      true -> {:cont, {acc, risk, false, clean and (kind == :or or value == true)}}
    end
  end

  @spec skipped(risk()) :: :none | :maybe
  defp skipped(risk) when risk in [:fail, :maybe], do: :maybe
  defp skipped(_none_or_refused), do: :none

  @spec merge(risk(), risk()) :: risk()
  defp merge(:maybe, _other), do: :maybe
  defp merge(_none, other), do: other
end
