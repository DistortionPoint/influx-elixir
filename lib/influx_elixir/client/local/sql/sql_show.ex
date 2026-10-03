defmodule InfluxElixir.Client.Local.SQLShow do
  @moduledoc false
  # `SHOW TABLES` and `SHOW COLUMNS FROM <table>` for
  # `InfluxElixir.Client.Local` (verified against InfluxDB 3 Core): the engine
  # answers them from the `information_schema` (see
  # `InfluxElixir.Client.Local.SQLInformation`), so they are read as the query
  # it runs:
  #
  #     SHOW TABLES
  #     SELECT * FROM information_schema.tables
  #
  #     SHOW COLUMNS FROM t
  #     SELECT table_catalog, table_schema, table_name, column_name, data_type, is_nullable
  #       FROM information_schema.columns WHERE table_schema = 'iox' AND table_name = 't'
  #
  # `FROM` and `IN` are one. A table of the `iox` schema that does not exist is
  # the planner's "table not found"; one of `information_schema` has no
  # columns (the view is not listed in its own `columns`). Every other
  # `SHOW` is left to the rest of the double.

  alias InfluxElixir.Client.Local.{SQLError, SQLTable}

  @system_tables ~w(distinct_caches influxdb_schema last_caches parquet_files
    processing_engine_logs processing_engine_trigger_arguments processing_engine_triggers
    queries)

  @show ~r/\A\s*SHOW\s+(?:(TABLES)|COLUMNS\s+(?:FROM|IN)\s+([\p{L}\p{N}_$.]+))\s*\z/iu

  @doc """
  The query a `SHOW` is, with the `iox` table that must exist for it to be
  answered (`nil` for none), `:nomatch` for any other text, or the engine's
  error.
  """
  @spec rewrite(binary()) :: {:ok, binary(), binary() | nil} | {:error, map()} | :nomatch
  def rewrite(sql) do
    case Regex.run(@show, sql) do
      [_all, _tables] -> {:ok, "SELECT * FROM information_schema.tables", nil}
      [_all, "", reference] -> columns(String.downcase(reference))
      nil -> :nomatch
    end
  end

  @spec columns(binary()) :: {:ok, binary(), binary() | nil} | {:error, map()}
  defp columns(reference) do
    case String.split(reference, ".") do
      [name] -> columns("iox", name)
      [schema, name] -> columns(schema, name)
      ["public", schema, name] -> columns(schema, name)
      _other -> unresolved(reference)
    end
  end

  @spec columns(binary(), binary()) :: {:ok, binary(), binary() | nil} | {:error, map()}
  defp columns("iox", name), do: {:ok, columns_sql("iox", name), name}

  defp columns("information_schema", name) when name in ~w(tables columns schemata),
    do: {:ok, columns_sql("information_schema", name), nil}

  defp columns("system", name) when name in @system_tables,
    do: {:ok, columns_sql("system", name), nil}

  defp columns(schema, name), do: unresolved(schema <> "." <> name)

  # A table the engine has not (or a view the double does not model): the
  # error of reading it in a `FROM`.
  @spec unresolved(binary()) :: {:error, map()}
  defp unresolved(reference) do
    case SQLTable.resolve(reference) do
      {:error, error} -> {:error, error}
      {:ok, _resolved} -> {:error, SQLError.refusal("SHOW COLUMNS FROM #{reference}")}
    end
  end

  @spec columns_sql(binary(), binary()) :: binary()
  defp columns_sql(schema, name) do
    "SELECT table_catalog, table_schema, table_name, column_name, data_type, is_nullable " <>
      "FROM information_schema.columns " <>
      "WHERE table_schema = '#{schema}' AND table_name = '#{name}'"
  end
end
