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

  @show ~r/\A\s*SHOW\s+(?:(TABLES)|COLUMNS\s+(?:FROM|IN)\s+([\p{L}\p{N}_$.]+))\s*\z/iu

  @describe ~r/\A\s*DESC(?:RIBE)?\s+((?:EXTENDED|FORMATTED)\s+)?([\p{L}\p{N}_$.]+)\s*\z/iu
  @modifiers ~w(extended formatted)

  @doc """
  The query a `SHOW` or a `DESCRIBE` is, with the `iox` table that must exist for it to be
  answered (`nil` for none), `:nomatch` for any other text, or the engine's
  error.
  """
  @spec rewrite(binary()) :: {:ok, binary(), binary() | nil} | {:error, map()} | :nomatch
  def rewrite(sql) do
    if String.valid?(sql) do
      case {Regex.run(@show, sql), Regex.run(@describe, sql)} do
        {[_all, _tables], _no_describe} ->
          {:ok, "SELECT * FROM information_schema.tables", nil}

        {[_all, "", reference], _no_describe} ->
          columns(String.downcase(reference), :show)

        {nil, [_all, modifier, reference]} ->
          described(modifier, String.downcase(reference))

        {nil, nil} ->
          :nomatch
      end
    else
      :nomatch
    end
  end

  # `DESC EXTENDED t` and `DESC FORMATTED t` describe `t`. Without one of them, the words are
  # not a table: the parser wants a name after the modifier.
  @spec described(binary(), binary()) ::
          {:ok, binary(), binary() | nil} | {:error, map()} | :nomatch
  defp described("", reference) do
    if reference |> String.split(".") |> hd() |> then(&(&1 in @modifiers)),
      do: :nomatch,
      else: columns(reference, :describe)
  end

  defp described(_modifier, reference), do: columns(reference, :describe)

  @spec columns(binary(), :show | :describe) ::
          {:ok, binary(), binary() | nil} | {:error, map()}
  defp columns(reference, form) do
    case String.split(reference, ".") do
      [name] -> columns("iox", name, form)
      [schema, name] -> columns(schema, name, form)
      ["public", schema, name] -> columns(schema, name, form)
      parts -> SQLTable.locate(parts)
    end
  end

  @spec columns(binary(), binary(), :show | :describe) ::
          {:ok, binary(), binary() | nil} | {:error, map()}
  defp columns("iox", name, form), do: {:ok, columns_sql("iox", name, form), name}

  # The engine describes the views of its other schemas from their definitions, not from the
  # `information_schema`, which the double does not hold.
  defp columns(schema, name, :describe) do
    case SQLTable.locate([schema, name]) do
      {:engine, _schema, _name, _columns} ->
        {:error, SQLError.refusal("DESCRIBE of #{schema}.#{name}: only tables of the iox schema")}

      {:error, _error} = error ->
        error
    end
  end

  defp columns(schema, name, form) do
    if SQLTable.modelled?(schema, name),
      do: {:ok, columns_sql(schema, name, form), nil},
      else: SQLTable.resolve(schema <> "." <> name)
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
