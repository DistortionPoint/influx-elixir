defmodule InfluxElixir.Client.Local.SQLStage do
  @moduledoc false
  # The order in which the engine finds the errors of a query, for `SQLPlan`.
  #
  # The engine does not report a query's errors in the order the text has them, but in the
  # order of the work it does (verified against InfluxDB 3 Core, each pair of kinds in each
  # pair of clauses). It first builds the plan, and finds the errors a plan cannot be built
  # with; then it replaces the `$n` placeholders by their values; then its analyzer coerces the
  # types of the plan from the scan up; then it optimizes the plan, builds the physical plan
  # and runs it. A stage is one of those places, and `index/1` is the one table that orders
  # them: an item of a check has the stage it is found at (its rank), and so has an error that
  # is held back until the stages before it are clear (its position).
  #
  # Building the plan (an error carries no `type_coercion` prefix):
  #
  #   * `:where_built`, `:select_built_concat`, `:order_built` — the operands of a `||`,
  #     which the planner types as it builds it, in the `WHERE`, the select list, the `ORDER BY`
  #   * `:select_built` — the select list's calls, operators and aggregates (and the arguments
  #     of the aggregates of a `HAVING`)
  #   * `:group` — a column of the select list or of a `HAVING` that is not grouped
  #   * `:having_filter` — a `HAVING` that is typed and is no boolean
  #   * `:order_built` — see above, after the `HAVING` is built
  #
  # Replacing the placeholders:
  #
  #   * `:placeholder` — a `$n` with no value
  #
  # The analyzer (an error carries the `type_coercion` prefix), the plan's clauses from the
  # scan up, the `WHERE` first and the select list last but for the `ORDER BY`; in a `WHERE`
  # and a `HAVING` the kinds of errors have an order of their own:
  #
  #   * `:where_logical`, `:having_logical` — the `AND`s, `OR`s and `NOT`s between the
  #     operators and calls the planner types
  #   * `:where_calls`, `:having_calls` — their calls, operators, comparisons and regexes
  #   * `:where_coerced`, `:having_coerced` — their `LIKE`s, `IN` lists and `BETWEEN`s, and
  #     what stands under a cast, a test of a value or a `NOT`
  #   * `:select_coerced` — the errors of the select list that the analyzer finds
  #   * `:order_calls` — the `ORDER BY`'s calls and operators
  #
  # After the analyzer:
  #
  #   * `:negation` — a negation of a type it does not support
  #   * `:optimizer` — a constant the optimizer folds and cannot (a `time` string it cannot
  #     read, a regular expression that does not compile)
  #   * `:physical` — an error found when the physical plan is built
  #   * `:bare_constant` — a call with no argument and nothing above it
  #   * `:conversion` — a struct given to a function of text, converted last
  #   * `:closed` — the engine closes the connection when it runs the plan
  #   * `:unmodelled` — what the engine computes with no error and the double declines to

  @stages [
    :where_built,
    :select_built_concat,
    :select_built,
    :group,
    :having_filter,
    :order_built,
    :placeholder,
    :where_logical,
    :where_calls,
    :where_coerced,
    :having_logical,
    :having_calls,
    :having_coerced,
    :select_coerced,
    :order_calls,
    :negation,
    :optimizer,
    :physical,
    :bare_constant,
    :conversion,
    :closed,
    :unmodelled
  ]

  @typedoc "A place in the engine's work."
  @type t ::
          :where_built
          | :select_built_concat
          | :select_built
          | :group
          | :having_filter
          | :order_built
          | :placeholder
          | :where_logical
          | :where_calls
          | :where_coerced
          | :having_logical
          | :having_calls
          | :having_coerced
          | :select_coerced
          | :order_calls
          | :negation
          | :optimizer
          | :physical
          | :bare_constant
          | :conversion
          | :closed
          | :unmodelled

  @doc "The stages, in the order the engine meets them."
  @spec all() :: [t()]
  def all, do: @stages

  @doc "Where a stage stands among the others: the earlier, the smaller."
  @spec index(t()) :: non_neg_integer()
  for {stage, index} <- Enum.with_index(@stages) do
    def index(unquote(stage)), do: unquote(index)
  end

  @doc """
  The stage a `HAVING` finds an error at, given the stage the same kind of error has in a
  `WHERE` (the analyzer coerces a `HAVING` after the `WHERE` below it, whatever the kind).
  """
  @spec having(t()) :: t()
  def having(:where_logical), do: :having_logical
  def having(:where_calls), do: :having_calls
  def having(:where_coerced), do: :having_coerced
  def having(stage), do: stage
end
