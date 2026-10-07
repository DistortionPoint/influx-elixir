defmodule InfluxElixir.Client.Local.SQLDmlDelete do
  @moduledoc false
  # The planner's answer to a `DELETE`, which it never runs (verified against InfluxDB 3 Core),
  # for `InfluxElixir.Client.Local.SQLDml`. The steps are the planner's, in its order:
  #
  #   1. the parser reads `DELETE [FROM] name [[AS] alias] [USING tables] [WHERE operand]
  #      [RETURNING items] [ORDER BY terms] [LIMIT operand]` (`SQLDmlExpr.delete_clauses/1`); a
  #      second table (`DELETE FROM a, b`) is an error of the engine that prints its parse tree
  #   2. the clauses the planner refuses, in this order, whether the table is there or not:
  #      `USING`, `RETURNING`, `ORDER BY`, `LIMIT`
  #   3. the table is looked up (`SQLDmlName.lookup/2`, the resolver `INSERT` and `UPDATE` use)
  #   4. the `WHERE` is planned as an `UPDATE`'s is, its fields qualified by the table as
  #      written (the alias is not used)
  #   5. `DML not supported: Delete`

  alias InfluxElixir.Client.Local.{SQLDml, SQLDmlExpr, SQLDmlName, SQLError, SQLTokenizer}

  @typep token :: SQLTokenizer.token()

  @doc """
  The answer to a `DELETE` from the tokens after the keyword and the token that ends it.
  """
  @spec error([token()], token(), SQLDml.env()) :: SQLError.t() | map()
  def error(tokens, stop, env) do
    with {:ok, reference, clauses} <- parse(tokens, stop),
         :ok <- SQLDmlName.arity(reference) do
      answer(reference, clauses, env)
    else
      {:error, error} -> error
      {:refuse, why} -> SQLDml.not_modelled(:delete, why)
    end
  end

  @doc """
  What the parser reads of a `DELETE` from the tokens after the keyword and the token that ends
  it: the table and the clauses.
  """
  @spec parse([token()], token()) ::
          {:ok, [binary()], SQLDmlExpr.delete_clauses()}
          | {:error, SQLError.t() | map()}
          | {:refuse, SQLDml.reason()}
  def parse(tokens, stop) do
    with {:ok, reference, rest} <- SQLDmlName.reference(skip_from(tokens)),
         {:ok, clauses} <- SQLDmlExpr.delete_clauses(rest ++ [stop]),
         do: {:ok, reference, clauses}
  end

  @spec skip_from([token()]) :: [token()]
  defp skip_from([{:word, _p, "FROM", _l, _c} | rest]), do: rest
  defp skip_from(tokens), do: tokens

  @spec answer([binary()], SQLDmlExpr.delete_clauses(), SQLDml.env()) :: SQLError.t() | map()
  defp answer(_reference, %{several: true}, _env),
    do: SQLDml.not_modelled(:delete, "a delete of several tables")

  defp answer(reference, clauses, env) do
    case refused_clause(clauses) do
      nil -> planned(reference, clauses, env)
      message -> SQLError.planning(message)
    end
  end

  @spec refused_clause(SQLDmlExpr.delete_clauses()) :: binary() | nil
  defp refused_clause(%{using: true}), do: "Using clause not supported"
  defp refused_clause(%{returning: true}), do: "Delete-returning clause not yet supported"
  defp refused_clause(%{order_by: true}), do: "Delete-order-by clause not yet supported"
  defp refused_clause(%{limit: true}), do: "Delete-limit clause not yet supported"
  defp refused_clause(_clauses), do: nil

  @spec planned([binary()], SQLDmlExpr.delete_clauses(), SQLDml.env()) :: SQLError.t() | map()
  defp planned(reference, clauses, env) do
    with {:ok, table} <- SQLDmlName.lookup(reference, env.tables),
         :ok <- not_function(clauses),
         :ok <- SQLDml.where(clauses.where, SQLDml.context(table, reference, env)) do
      SQLDml.dml(:delete)
    else
      {:error, error} -> error
      {:refuse, why} -> SQLDml.not_modelled(:delete, why)
    end
  end

  @spec not_function(SQLDmlExpr.delete_clauses()) :: :ok | {:refuse, SQLDml.reason()}
  defp not_function(%{function: true}), do: {:refuse, "a delete of a table function"}
  defp not_function(_clauses), do: :ok
end
