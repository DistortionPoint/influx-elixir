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

  alias InfluxElixir.Client.Local.{Scope, Store}

  @prefix "\0information_schema."

  @tables_columns ~w(table_catalog table_schema table_name table_type)
  @columns_columns ~w(table_catalog table_schema table_name column_name ordinal_position
    column_default is_nullable data_type character_maximum_length character_octet_length
    numeric_precision numeric_precision_radix numeric_scale datetime_precision interval_type)
  @schemata_columns ~w(catalog_name schema_name schema_owner default_character_set_catalog
    default_character_set_schema default_character_set_name sql_path)

  @system_tables ~w(distinct_caches influxdb_schema last_caches parquet_files
    processing_engine_logs processing_engine_trigger_arguments processing_engine_triggers
    queries)

  @views ~w(tables views columns df_settings schemata routines parameters)

  # The columns of the system tables: `{table, column, nullable?, type}`.
  @system_columns [
    {"distinct_caches", "table", false, "Utf8View"},
    {"distinct_caches", "name", false, "Utf8View"},
    {"distinct_caches", "column_ids", false, "List(UInt16)"},
    {"distinct_caches", "column_names", false, "List(Utf8View)"},
    {"distinct_caches", "max_cardinality", false, "UInt64"},
    {"distinct_caches", "max_age_seconds", false, "UInt64"},
    {"influxdb_schema", "measurement", false, "Utf8View"},
    {"influxdb_schema", "key", false, "Utf8View"},
    {"influxdb_schema", "data_type", false, "Utf8View"},
    {"last_caches", "table", false, "Utf8View"},
    {"last_caches", "name", false, "Utf8View"},
    {"last_caches", "key_column_ids", false, "List(UInt16)"},
    {"last_caches", "key_column_names", false, "List(Utf8View)"},
    {"last_caches", "value_column_ids", true, "List(UInt16)"},
    {"last_caches", "value_column_names", true, "List(Utf8View)"},
    {"last_caches", "count", false, "UInt64"},
    {"last_caches", "ttl", false, "UInt64"},
    {"parquet_files", "table_name", false, "Utf8"},
    {"parquet_files", "path", false, "Utf8"},
    {"parquet_files", "size_bytes", false, "UInt64"},
    {"parquet_files", "row_count", false, "UInt64"},
    {"parquet_files", "min_time", false, "Int64"},
    {"parquet_files", "max_time", false, "Int64"},
    {"processing_engine_logs", "event_time", false, "Timestamp(ns)"},
    {"processing_engine_logs", "trigger_name", false, "Utf8"},
    {"processing_engine_logs", "log_level", false, "Utf8"},
    {"processing_engine_logs", "log_text", false, "Utf8"},
    {"processing_engine_trigger_arguments", "trigger_name", false, "Utf8"},
    {"processing_engine_trigger_arguments", "argument_key", false, "Utf8"},
    {"processing_engine_trigger_arguments", "argument_value", false, "Utf8"},
    {"processing_engine_triggers", "trigger_name", false, "Utf8"},
    {"processing_engine_triggers", "plugin_filename", false, "Utf8"},
    {"processing_engine_triggers", "trigger_specification", false, "Utf8"},
    {"processing_engine_triggers", "disabled", false, "Boolean"},
    {"processing_engine_triggers", "error_behavior", false, "Utf8"},
    {"queries", "id", false, "Utf8"},
    {"queries", "phase", false, "Utf8"},
    {"queries", "issue_time", false, "Timestamp(ns)"},
    {"queries", "query_type", false, "Utf8"},
    {"queries", "query_text", false, "Utf8"},
    {"queries", "partitions", true, "Int64"},
    {"queries", "parquet_files", true, "Int64"},
    {"queries", "plan_duration", true, "Duration(ns)"},
    {"queries", "permit_duration", true, "Duration(ns)"},
    {"queries", "execute_duration", true, "Duration(ns)"},
    {"queries", "end2end_duration", true, "Duration(ns)"},
    {"queries", "compute_duration", true, "Duration(ns)"},
    {"queries", "max_memory", true, "Int64"},
    {"queries", "success", false, "Boolean"},
    {"queries", "running", false, "Boolean"},
    {"queries", "cancelled", false, "Boolean"},
    {"queries", "trace_id", true, "Utf8"}
  ]

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
    do: {:ok, tables(table, database), @tables_columns}

  def relation(@prefix <> "columns", table, database),
    do: {:ok, columns(table, database), @columns_columns}

  def relation(@prefix <> "schemata", _table, _database),
    do:
      {:ok,
       [
         row("schemata", %{"catalog_name" => "public", "schema_name" => "iox"}),
         row("schemata", %{"catalog_name" => "public", "schema_name" => "system"})
       ], @schemata_columns}

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
    system = for name <- @system_tables, do: {"system", name, "BASE TABLE"}
    views = for name <- @views, do: {"information_schema", name, "VIEW"}

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
      for {name, columns} <- Enum.group_by(@system_columns, &elem(&1, 0)),
          {{_table, column, nullable?, type}, position} <- Enum.with_index(columns),
          do: column_row("system", name, column, position, nullable?, type)

    iox ++ order_system(system)
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

  # The system tables in their listed order.
  defp order_system(rows) do
    Enum.sort_by(rows, fn %{fields: fields} ->
      {Enum.find_index(@system_tables, &(&1 == fields["table_name"])),
       elem(fields["ordinal_position"], 1)}
    end)
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
