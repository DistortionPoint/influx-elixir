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
  #     DESCRIBE t   (or DESC t)
  #     SELECT column_name, data_type, is_nullable
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

  @describe ~r/\A\s*DESC(?:RIBE)?\s+([\p{L}\p{N}_$.]+)\s*\z/iu

  @doc """
  The query a `SHOW` or a `DESCRIBE` is, with the `iox` table that must exist for it to be
  answered (`nil` for none), `:nomatch` for any other text, or the engine's
  error.
  """
  @spec rewrite(binary()) :: {:ok, binary(), binary() | nil} | {:error, map()} | :nomatch
  def rewrite(sql) do
    case {Regex.run(@show, sql), Regex.run(@describe, sql)} do
      {[_all, _tables], _no_describe} ->
        {:ok, "SELECT * FROM information_schema.tables", nil}

      {[_all, "", reference], _no_describe} ->
        columns(String.downcase(reference), :show)

      {nil, [_all, reference]} ->
        columns(String.downcase(reference), :describe)

      {nil, nil} ->
        :nomatch
    end
  end

  @spec columns(binary(), :show | :describe) ::
          {:ok, binary(), binary() | nil} | {:error, map()}
  defp columns(reference, form) do
    case String.split(reference, ".") do
      [name] -> columns("iox", name, form)
      [schema, name] -> columns(schema, name, form)
      ["public", schema, name] -> columns(schema, name, form)
      _other -> unresolved(reference)
    end
  end

  @spec columns(binary(), binary(), :show | :describe) ::
          {:ok, binary(), binary() | nil} | {:error, map()}
  defp columns("iox", name, form), do: {:ok, columns_sql("iox", name, form), name}

  # The engine describes the views of its other schemas from their definitions, not from the
  # `information_schema`, which the double does not hold.
  defp columns(schema, name, :describe) do
    case unresolved(schema <> "." <> name) do
      {:error, %{body: "Client.Local: " <> _refusal}} ->
        {:error, SQLError.refusal("DESCRIBE of #{schema}.#{name}: only tables of the iox schema")}

      other ->
        other
    end
  end

  defp columns("information_schema", name, form) when name in ~w(tables columns schemata),
    do: {:ok, columns_sql("information_schema", name, form), nil}

  defp columns("system", name, form) when name in @system_tables,
    do: {:ok, columns_sql("system", name, form), nil}

  defp columns(schema, name, _form), do: unresolved(schema <> "." <> name)

  # A table the engine has not (or a view the double does not model): the
  # error of reading it in a `FROM`.
  @spec unresolved(binary()) :: {:error, map()}
  defp unresolved(reference) do
    case SQLTable.resolve(reference) do
      {:error, error} -> {:error, error}
      {:ok, _resolved} -> {:error, SQLError.refusal("SHOW COLUMNS FROM #{reference}")}
    end
  end

  @spec columns_sql(binary(), binary(), :show | :describe) :: binary()
  defp columns_sql(schema, name, form) do
    select =
      case form do
        :show -> "table_catalog, table_schema, table_name, column_name, data_type, is_nullable"
        :describe -> "column_name, data_type, is_nullable"
      end

    "SELECT #{select} FROM information_schema.columns " <>
      "WHERE table_schema = '#{schema}' AND table_name = '#{name}'"
  end
end
