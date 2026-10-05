defmodule InfluxElixir.Client.Local.SQLTable do
  @moduledoc false
  # How a statement names a table, for `InfluxElixir.Client.Local` (verified against InfluxDB 3
  # Core 3.10.1): one part, `m`, is a table of the `iox` schema; two, `schema.m`, are a schema of
  # the `public` catalog and a table; three, `catalog.schema.m`, a catalog too. The catalog is
  # `public`, the schemas are `iox` (the measurements), `information_schema` (seven views) and
  # `system` (eight tables of the engine's own).
  #
  # This is the one resolver of such a name (`locate/1`), the one table of the columns of the
  # engine's own tables (`engine_columns/2`: `SQLInformation` lists them, a DML statement plans
  # against them) and the one builder of the words of its errors (`not_found/1`, `compound/1`).
  # `resolve/1` is the query reading of a name (`FROM name`), `SQLDmlName.lookup/2` the DML one.
  #
  # A table is known by any tail of its full name (`m`, `iox.m`, `public.iox.m`) in a column's
  # qualifier; the name a query prints for a column it does not name (`count(iox.m.v)`) is the
  # one the `FROM` wrote.

  alias InfluxElixir.Client.Local.{SQLError, SQLInformation}

  @catalog "public"
  @engine_schemas ["system", "information_schema"]
  @modelled ~w(tables columns schemata)

  # The engine's own tables, in the order it lists them, with their columns in the order it
  # defines them (the order its errors list them in and an `INSERT` without a column list takes
  # the values in): `{name, type, nullable?}`. The nullability is the `information_schema`'s
  # `is_nullable` of a system table's column (the views' is not modelled).
  @system [
    {"distinct_caches",
     [
       {"table", "Utf8View", false},
       {"name", "Utf8View", false},
       {"column_ids", "List(UInt16)", false},
       {"column_names", "List(Utf8View)", false},
       {"max_cardinality", "UInt64", false},
       {"max_age_seconds", "UInt64", false}
     ]},
    {"influxdb_schema",
     [
       {"measurement", "Utf8View", false},
       {"key", "Utf8View", false},
       {"data_type", "Utf8View", false}
     ]},
    {"last_caches",
     [
       {"table", "Utf8View", false},
       {"name", "Utf8View", false},
       {"key_column_ids", "List(UInt16)", false},
       {"key_column_names", "List(Utf8View)", false},
       {"value_column_ids", "List(UInt16)", true},
       {"value_column_names", "List(Utf8View)", true},
       {"count", "UInt64", false},
       {"ttl", "UInt64", false}
     ]},
    {"parquet_files",
     [
       {"table_name", "Utf8", false},
       {"path", "Utf8", false},
       {"size_bytes", "UInt64", false},
       {"row_count", "UInt64", false},
       {"min_time", "Int64", false},
       {"max_time", "Int64", false}
     ]},
    {"processing_engine_logs",
     [
       {"event_time", "Timestamp(ns)", false},
       {"trigger_name", "Utf8", false},
       {"log_level", "Utf8", false},
       {"log_text", "Utf8", false}
     ]},
    {"processing_engine_trigger_arguments",
     [
       {"trigger_name", "Utf8", false},
       {"argument_key", "Utf8", false},
       {"argument_value", "Utf8", false}
     ]},
    {"processing_engine_triggers",
     [
       {"trigger_name", "Utf8", false},
       {"plugin_filename", "Utf8", false},
       {"trigger_specification", "Utf8", false},
       {"disabled", "Boolean", false},
       {"error_behavior", "Utf8", false}
     ]},
    {"queries",
     [
       {"id", "Utf8", false},
       {"phase", "Utf8", false},
       {"issue_time", "Timestamp(ns)", false},
       {"query_type", "Utf8", false},
       {"query_text", "Utf8", false},
       {"partitions", "Int64", true},
       {"parquet_files", "Int64", true},
       {"plan_duration", "Duration(ns)", true},
       {"permit_duration", "Duration(ns)", true},
       {"execute_duration", "Duration(ns)", true},
       {"end2end_duration", "Duration(ns)", true},
       {"compute_duration", "Duration(ns)", true},
       {"max_memory", "Int64", true},
       {"success", "Boolean", false},
       {"running", "Boolean", false},
       {"cancelled", "Boolean", false},
       {"trace_id", "Utf8", true}
     ]}
  ]

  @information_schema [
    {"tables",
     [
       {"table_catalog", "Utf8", true},
       {"table_schema", "Utf8", true},
       {"table_name", "Utf8", true},
       {"table_type", "Utf8", true}
     ]},
    {"views",
     [
       {"table_catalog", "Utf8", true},
       {"table_schema", "Utf8", true},
       {"table_name", "Utf8", true},
       {"definition", "Utf8", true}
     ]},
    {"columns",
     [
       {"table_catalog", "Utf8", true},
       {"table_schema", "Utf8", true},
       {"table_name", "Utf8", true},
       {"column_name", "Utf8", true},
       {"ordinal_position", "UInt64", true},
       {"column_default", "Utf8", true},
       {"is_nullable", "Utf8", true},
       {"data_type", "Utf8", true},
       {"character_maximum_length", "UInt64", true},
       {"character_octet_length", "UInt64", true},
       {"numeric_precision", "UInt64", true},
       {"numeric_precision_radix", "UInt64", true},
       {"numeric_scale", "UInt64", true},
       {"datetime_precision", "UInt64", true},
       {"interval_type", "Utf8", true}
     ]},
    {"df_settings",
     [{"name", "Utf8", true}, {"value", "Utf8", true}, {"description", "Utf8", true}]},
    {"schemata",
     [
       {"catalog_name", "Utf8", true},
       {"schema_name", "Utf8", true},
       {"schema_owner", "Utf8", true},
       {"default_character_set_catalog", "Utf8", true},
       {"default_character_set_schema", "Utf8", true},
       {"default_character_set_name", "Utf8", true},
       {"sql_path", "Utf8", true}
     ]},
    {"routines",
     [
       {"specific_catalog", "Utf8", true},
       {"specific_schema", "Utf8", true},
       {"specific_name", "Utf8", true},
       {"routine_catalog", "Utf8", true},
       {"routine_schema", "Utf8", true},
       {"routine_name", "Utf8", true},
       {"routine_type", "Utf8", true},
       {"is_deterministic", "Boolean", true},
       {"data_type", "Utf8", true},
       {"function_type", "Utf8", true},
       {"description", "Utf8", true},
       {"syntax_example", "Utf8", true}
     ]},
    {"parameters",
     [
       {"specific_catalog", "Utf8", true},
       {"specific_schema", "Utf8", true},
       {"specific_name", "Utf8", true},
       {"ordinal_position", "UInt64", true},
       {"parameter_mode", "Utf8", true},
       {"parameter_name", "Utf8", true},
       {"data_type", "Utf8", true},
       {"parameter_default", "Utf8", true},
       {"is_variadic", "Boolean", true},
       {"rid", "UInt8", true}
     ]}
  ]

  @typedoc "A column of an engine table: its name, its Arrow type and whether it can be null."
  @type column :: {binary(), binary(), boolean()}

  @typedoc """
  What a table name names: a table of the `iox` schema (whether it exists is for the caller to
  say), a table of the engine's own with its columns, or the engine's error.
  """
  @type located ::
          {:iox, binary()}
          | {:engine, binary(), binary(), [column()]}
          | {:error, SQLError.t()}

  @typedoc """
  What a table reference names to a query: the measurement the executor reads (an
  `information_schema` table is `information_schema.<name>`), the qualifiers its columns may
  carry besides the one written, or the engine's error.
  """
  @type resolved ::
          {:ok, %{measurement: binary(), qualifiers: [binary()]}} | {:error, SQLError.t()}

  # ---------------------------------------------------------------------------
  # The resolver
  # ---------------------------------------------------------------------------

  @doc """
  The table the parts of a name (each as the engine reads it: unquoted ones in lower case) name.
  """
  @spec locate([binary()]) :: located()
  def locate([name]), do: {:iox, name}
  def locate(["iox", name]), do: {:iox, name}
  def locate([@catalog, "iox", name]), do: {:iox, name}
  def locate([schema, name]) when schema in @engine_schemas, do: engine(schema, name)
  def locate([@catalog, schema, name]) when schema in @engine_schemas, do: engine(schema, name)
  def locate([_schema, _name] = parts), do: {:error, not_found(@catalog <> "." <> dotted(parts))}
  def locate([_catalog, _schema, _name] = parts), do: {:error, not_found(dotted(parts))}
  def locate(parts), do: {:error, compound(parts)}

  @spec engine(binary(), binary()) :: located()
  defp engine(schema, name) do
    case engine_columns(schema, name) do
      nil -> {:error, not_found("#{@catalog}.#{schema}.#{name}")}
      columns -> {:engine, schema, name, columns}
    end
  end

  @doc """
  Resolves a bare (unquoted) table reference as written, folded to lower case as the engine
  folds it. The tables of the engine's own other than three of `information_schema` are not
  modelled: they resolve to a refusal by name.
  """
  @spec resolve(binary()) :: resolved()
  def resolve(text) do
    case text |> String.split(".") |> locate() do
      {:iox, name} ->
        {:ok, %{measurement: name, qualifiers: tails("iox", name)}}

      {:engine, "information_schema", name, _columns} when name in @modelled ->
        {:ok,
         %{
           measurement: SQLInformation.relation_name(name),
           qualifiers: [name, "information_schema." <> name, "public.information_schema." <> name]
         }}

      {:engine, "information_schema", name, _columns} ->
        {:error,
         SQLError.refusal(
           "information_schema.#{name}: the double models information_schema.tables, " <>
             "information_schema.columns and information_schema.schemata"
         )}

      {:engine, "system", name, _columns} ->
        {:error, SQLError.refusal("system.#{name}: the engine's system tables are not modelled")}

      {:error, _error} = error ->
        error
    end
  end

  # `name`, `iox.name` and `public.iox.name`: the tails of the full name.
  @spec tails(binary(), binary()) :: [binary()]
  defp tails(schema, name), do: [name, schema <> "." <> name, "public." <> schema <> "." <> name]

  @doc "The qualifiers, besides the one written, that a table reference's columns may carry."
  @spec qualifiers(binary()) :: [binary()]
  def qualifiers(text) do
    case resolve(text) do
      {:ok, %{qualifiers: qualifiers}} -> qualifiers
      {:error, _reason} -> []
    end
  end

  # ---------------------------------------------------------------------------
  # The words of the errors
  # ---------------------------------------------------------------------------

  @doc "The planner's error for a table it cannot find, as it prints the name it looked for."
  @spec not_found(binary()) :: SQLError.t()
  def not_found(printed), do: SQLError.planning("table '#{printed}' not found")

  @doc "The error for a measurement of the `iox` schema that the database has not."
  @spec iox_not_found(binary()) :: SQLError.t()
  def iox_not_found(measurement), do: not_found("#{@catalog}.iox.#{measurement}")

  @doc "The error for a name of more parts than a table has (catalog, schema and name)."
  @spec compound([binary()]) :: SQLError.t()
  def compound(parts) do
    SQLError.planning(
      "Unsupported compound identifier '#{dotted(parts)}'. " <>
        "Expected 1, 2 or 3 parts, got #{length(parts)}"
    )
  end

  @spec dotted([binary()]) :: binary()
  defp dotted(parts), do: Enum.join(parts, ".")

  # ---------------------------------------------------------------------------
  # The engine's own tables
  # ---------------------------------------------------------------------------

  @doc """
  The columns of a table of the `system` or `information_schema` schema in the order the engine
  defines them, or `nil` for a table it has not.
  """
  @spec engine_columns(binary(), binary()) :: [column()] | nil
  def engine_columns("system", table), do: columns_of(@system, table)
  def engine_columns("information_schema", table), do: columns_of(@information_schema, table)

  @spec columns_of([{binary(), [column()]}], binary()) :: [column()] | nil
  defp columns_of(tables, table) do
    case List.keyfind(tables, table, 0) do
      {_table, columns} -> columns
      nil -> nil
    end
  end

  @doc "The names of the tables of the `system` schema, in the order the engine lists them."
  @spec system_tables() :: [binary()]
  def system_tables, do: Enum.map(@system, &elem(&1, 0))

  @doc "The names of the views of the `information_schema`, in the order the engine lists them."
  @spec views() :: [binary()]
  def views, do: Enum.map(@information_schema, &elem(&1, 0))

  @doc "The column names of a table of the engine's own (`[]` for a table it has not)."
  @spec column_names(binary(), binary()) :: [binary()]
  def column_names(schema, table) do
    for {name, _type, _nullable} <- engine_columns(schema, table) || [], do: name
  end
end
