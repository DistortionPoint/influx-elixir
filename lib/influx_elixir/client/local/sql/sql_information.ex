defmodule InfluxElixir.Client.Local.SQLInformation do
  @moduledoc false
  # The `information_schema` of `InfluxElixir.Client.Local`: its `tables`,
  # `columns` and `schemata`, as InfluxDB 3 Core 3.10 answers them (verified):
  #
  #   * `tables` lists the tables of the `iox` schema (the measurements, by
  #     name), the eight tables of the `system` schema and the seven views of
  #     `information_schema` itself
  #   * `columns` lists the columns of the `iox` and `system` tables (not the
  #     views): a table's columns sorted by name, `time` among them, each with
  #     its 0-based position, `is_nullable` (`NO` for `time` and for every
  #     column of a `system` table that cannot be null), the Arrow `data_type`
  #     (a tag is `Dictionary(Int32, Utf8)`), and for a `Utf8` the
  #     `character_octet_length` of 2147483647, for a `Float64` a
  #     `numeric_precision` of 24 and a radix of 2
  #   * `schemata` lists `iox` and `system`
  #
  # A value the engine holds as null is no key of the row. The system
  # tables' own rows are not modelled, only their place in these views.

  alias InfluxElixir.Client.Local.{Scope, SQLTable, Store}

  @prefix "\0information_schema."

  @dual "\0dual"

  @doc "The name of the table of one row and no column that a `SELECT` with no `FROM` reads."
  @spec dual() :: binary()
  def dual, do: @dual

  @doc "The name the executor reads the `information_schema` relation `name` by."
  @spec relation_name(binary()) :: binary()
  def relation_name(name), do: @prefix <> name

  @doc """
  The points and the declared columns of an `information_schema` relation
  (named as `relation_name/1` names it), or `:error` for any other name.
  """
  @spec relation(binary(), Store.t(), binary()) ::
          {:ok, [map()], [binary()]} | :error
  def relation(@prefix <> "tables", table, database),
    do: {:ok, tables(table, database), SQLTable.column_names("information_schema", "tables")}

  def relation(@prefix <> "columns", table, database),
    do: {:ok, columns(table, database), SQLTable.column_names("information_schema", "columns")}

  def relation(@prefix <> "schemata", _table, _database),
    do:
      {:ok,
       [
         row("schemata", %{"catalog_name" => "public", "schema_name" => "iox"}),
         row("schemata", %{"catalog_name" => "public", "schema_name" => "system"})
       ], SQLTable.column_names("information_schema", "schemata")}

  def relation(@dual, _table, _database), do: {:ok, [row("dual", %{})], []}
  def relation(_other, _table, _database), do: :error

  @doc "The points a query reads for `measurement`: an `information_schema` relation or a table."
  @spec fetch(Store.t(), binary(), binary()) ::
          {:ok, [map()]} | {:ok, [map()], [binary()]} | :error
  def fetch(table, database, measurement) do
    case relation(measurement, table, database) do
      :error -> Scope.point_source(table, database, measurement)
      found -> found
    end
  end

  @spec tables(Store.t(), binary()) :: [map()]
  defp tables(table, database) do
    iox = for name <- Store.measurements(table, database), do: {"iox", name, "BASE TABLE"}
    system = for name <- SQLTable.system_tables(), do: {"system", name, "BASE TABLE"}
    views = for name <- SQLTable.views(), do: {"information_schema", name, "VIEW"}

    for {schema, name, type} <- iox ++ system ++ views do
      row("tables", %{
        "table_catalog" => "public",
        "table_schema" => schema,
        "table_name" => name,
        "table_type" => type
      })
    end
  end

  @spec columns(Store.t(), binary()) :: [map()]
  defp columns(table, database) do
    stored =
      table
      |> Store.columns(database)
      |> Enum.group_by(&elem(&1, 0), fn {_measurement, column, kind} -> {column, kind} end)

    iox =
      for measurement <- Store.measurements(table, database),
          {{column, type, nullable?}, position} <-
            measurement |> iox_columns(stored) |> Enum.with_index(),
          do: column_row("iox", measurement, column, position, nullable?, type)

    system =
      for name <- SQLTable.system_tables(),
          {{column, type, nullable?}, position} <-
            "system" |> SQLTable.engine_columns(name) |> Enum.with_index(),
          do: column_row("system", name, column, position, nullable?, type)

    iox ++ system
  end

  # A table's columns by name, with its `time`.
  @spec iox_columns(binary(), %{binary() => [{binary(), binary()}]}) ::
          [{binary(), binary(), boolean()}]
  defp iox_columns(measurement, stored) do
    columns =
      for {column, kind} <- Map.get(stored, measurement, []),
          do: {column, arrow_type(kind), true}

    Enum.sort([{"time", "Timestamp(ns)", false} | columns])
  end

  @spec column_row(binary(), binary(), binary(), non_neg_integer(), boolean(), binary()) :: map()
  defp column_row(schema, table, column, position, nullable?, type) do
    %{
      "table_catalog" => "public",
      "table_schema" => schema,
      "table_name" => table,
      "column_name" => column,
      "ordinal_position" => {:u, position},
      "is_nullable" => if(nullable?, do: "YES", else: "NO"),
      "data_type" => type
    }
    |> Map.merge(type_attributes(type))
    |> then(&row("columns", &1))
  end

  # What the engine derives from a column's type.
  @spec type_attributes(binary()) :: map()
  defp type_attributes("Utf8"), do: %{"character_octet_length" => {:u, 2_147_483_647}}

  defp type_attributes("Float64"),
    do: %{"numeric_precision" => {:u, 24}, "numeric_precision_radix" => {:u, 2}}

  defp type_attributes(_type), do: %{}

  @spec arrow_type(binary()) :: binary()
  defp arrow_type("iox::column_type::tag"), do: "Dictionary(Int32, Utf8)"
  defp arrow_type("iox::column_type::field::integer"), do: "Int64"
  defp arrow_type("iox::column_type::field::uinteger"), do: "UInt64"
  defp arrow_type("iox::column_type::field::float"), do: "Float64"
  defp arrow_type("iox::column_type::field::string"), do: "Utf8"
  defp arrow_type("iox::column_type::field::boolean"), do: "Boolean"

  @spec row(binary(), map()) :: map()
  defp row(name, fields), do: %{measurement: name, tags: %{}, fields: fields, timestamp: nil}
end
