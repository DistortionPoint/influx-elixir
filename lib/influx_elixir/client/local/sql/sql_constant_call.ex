defmodule InfluxElixir.Client.Local.SQLConstantCall do
  @moduledoc false
  # The planning error of a call with no argument (`coalesce()`, `lower()`),
  # in the words the engine finds it in (verified against InfluxDB 3 Core).
  # Such a call is a constant, which the engine folds, so where it stands
  # decides which pass reports the error:
  #
  #   * directly under an `IS [NOT] NULL` (a `CAST` may stand between), in the
  #     select list, `WHERE` or `ORDER BY`: the optimizer's `simplify_expressions`
  #     rule, with the planner's whole message
  #   * in the select list the planner types it at once (`Error during planning:`
  #     and the whole message), unless some `IS [NOT] NULL` stands above it, which
  #     leaves it to the type coercion (`type_coercion\ncaused by\n` and the whole
  #     message)
  #   * in `WHERE` the type coercion, except under a `CAST`, where the planner
  #     (`Error during planning:`, its first sentence) or, for a function that
  #     fails as an execution error (`coalesce()`, `greatest()`), an error of
  #     status 500 with the first sentence alone
  #   * in `ORDER BY` the first sentence alone as in `WHERE`'s `CAST`, when the
  #     call stands at the top or directly under a `CAST` or a negation, and the
  #     type coercion's whole message otherwise
  #
  # The message is the planner's own, which the function's checker words.

  alias InfluxElixir.Client.Local.{SQLError, SQLExpr, SQLExprCheck, SQLFunctions}

  @typedoc "What stands above a call, the nearest first."
  @type ancestors :: [:cast | :neg | :isnull | :deferred | :when | :other]

  @doc """
  `:ok`, or the engine's error for the call with no argument, given what
  stands above it and the clause it stands in.
  """
  @spec check(SQLExpr.t(), ancestors(), :select | :where | :order_by) :: :ok | {:error, map()}
  def check({:call, name, []} = call, ancestors, clause) do
    case planned(name, call) do
      :ok ->
        :ok

      {:error, %{body: "Client.Local: " <> _reason} = refusal} ->
        {:error, refusal}

      {:error, %{body: "Error during planning: " <> message}} ->
        {:error, shape(message, ancestors, clause)}
    end
  end

  # The planner's error for the call, whole.
  @spec planned(atom(), SQLExpr.t()) :: :ok | {:error, map()}
  defp planned(name, call) when name in [:coalesce, :nullif],
    do: SQLExprCheck.check(call, %{}, :select)

  defp planned(name, _call), do: SQLFunctions.check(name, [], :select)

  @typedoc "The pass that reports the call, in the order the engine runs them."
  @type phase :: :planner | :coercion | :optimizer | :bare

  @doc """
  The pass that reports a call with no argument given what stands above it and its
  clause: the planner, the type coercion, the optimizer (which reports after
  them), or the planner's own check of a clause that stands alone (`bare`, the
  first sentence of the error, which comes last).
  """
  @spec phase(ancestors(), :select | :where | :order_by) :: phase()
  def phase(ancestors, clause) do
    cond do
      optimizer?(ancestors) -> :optimizer
      clause == :select and (:isnull in ancestors or :deferred in ancestors) -> :coercion
      clause == :select -> :planner
      clause == :where and hd_or(ancestors) != :cast -> :coercion
      clause == :order_by and hd_or(ancestors) not in [nil, :cast, :neg] -> :coercion
      true -> :bare
    end
  end

  @spec shape(binary(), ancestors(), :select | :where | :order_by) :: map()
  defp shape(message, ancestors, clause) do
    case phase(ancestors, clause) do
      :optimizer -> simplify(message)
      :coercion -> coercion(message, ancestors)
      :planner -> SQLError.planning(message)
      :bare -> first_sentence(message)
    end
  end

  # The type coercion's error. A call that is a `WHEN` condition by itself fails when the
  # condition is made a boolean, which the engine says.
  @spec coercion(binary(), ancestors()) :: map()
  defp coercion(message, [:when | _above]) do
    %{
      status: 400,
      body:
        "type_coercion\ncaused by\nWHEN expressions in CASE couldn't be converted to common " <>
          "type (Boolean)\ncaused by\nError during planning: " <> message
    }
  end

  defp coercion(message, _ancestors), do: SQLError.coercion(message)

  # Whether the optimizer reports the call: it stands directly under an `IS [NOT] NULL`,
  # with only `CAST`s between.
  # It reports after the passes that type the query.
  @spec optimizer?(ancestors()) :: boolean()
  defp optimizer?(ancestors), do: hd_or(Enum.drop_while(ancestors, &(&1 == :cast))) == :isnull

  @spec hd_or([atom()]) :: atom() | nil
  defp hd_or([]), do: nil
  defp hd_or([nearest | _rest]), do: nearest

  @spec simplify(binary()) :: map()
  defp simplify(message) do
    %{
      status: 400,
      body:
        "Optimizer rule 'simplify_expressions' failed\ncaused by\n" <>
          "Error during planning: " <> message
    }
  end

  # The error without the candidate signatures: a planning error keeps the planner's
  # prefix, an execution error is bare, with status 500.
  @spec first_sentence(binary()) :: map()
  defp first_sentence(message) do
    head = message |> String.split(" No function matches", parts: 2) |> hd()

    if String.starts_with?(head, "Execution error: "),
      do: %{status: 500, body: head},
      else: SQLError.planning(head)
  end
end
