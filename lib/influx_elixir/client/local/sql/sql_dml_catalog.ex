defmodule InfluxElixir.Client.Local.SQLDmlCatalog do
  @moduledoc false
  # The columns of the engine's own tables, `system` and `information_schema` (read from
  # InfluxDB 3 Core 3.10.1), in the order it defines them: the order its errors list them in
  # and an `INSERT` without a column list takes the values in. A statement names these tables
  # as it names a table of the database; none of them can be written.

  @system [
    {"distinct_caches",
     [
       {"table", "Utf8View"},
       {"name", "Utf8View"},
       {"column_ids", "List(UInt16)"},
       {"column_names", "List(Utf8View)"},
       {"max_cardinality", "UInt64"},
       {"max_age_seconds", "UInt64"}
     ]},
    {"influxdb_schema",
     [{"measurement", "Utf8View"}, {"key", "Utf8View"}, {"data_type", "Utf8View"}]},
    {"last_caches",
     [
       {"table", "Utf8View"},
       {"name", "Utf8View"},
       {"key_column_ids", "List(UInt16)"},
       {"key_column_names", "List(Utf8View)"},
       {"value_column_ids", "List(UInt16)"},
       {"value_column_names", "List(Utf8View)"},
       {"count", "UInt64"},
       {"ttl", "UInt64"}
     ]},
    {"parquet_files",
     [
       {"table_name", "Utf8"},
       {"path", "Utf8"},
       {"size_bytes", "UInt64"},
       {"row_count", "UInt64"},
       {"min_time", "Int64"},
       {"max_time", "Int64"}
     ]},
    {"processing_engine_logs",
     [
       {"event_time", "Timestamp(ns)"},
       {"trigger_name", "Utf8"},
       {"log_level", "Utf8"},
       {"log_text", "Utf8"}
     ]},
    {"processing_engine_trigger_arguments",
     [{"trigger_name", "Utf8"}, {"argument_key", "Utf8"}, {"argument_value", "Utf8"}]},
    {"processing_engine_triggers",
     [
       {"trigger_name", "Utf8"},
       {"plugin_filename", "Utf8"},
       {"trigger_specification", "Utf8"},
       {"disabled", "Boolean"},
       {"error_behavior", "Utf8"}
     ]},
    {"queries",
     [
       {"id", "Utf8"},
       {"phase", "Utf8"},
       {"issue_time", "Timestamp(ns)"},
       {"query_type", "Utf8"},
       {"query_text", "Utf8"},
       {"partitions", "Int64"},
       {"parquet_files", "Int64"},
       {"plan_duration", "Duration(ns)"},
       {"permit_duration", "Duration(ns)"},
       {"execute_duration", "Duration(ns)"},
       {"end2end_duration", "Duration(ns)"},
       {"compute_duration", "Duration(ns)"},
       {"max_memory", "Int64"},
       {"success", "Boolean"},
       {"running", "Boolean"},
       {"cancelled", "Boolean"},
       {"trace_id", "Utf8"}
     ]}
  ]

  @information_schema [
    {"tables",
     [
       {"table_catalog", "Utf8"},
       {"table_schema", "Utf8"},
       {"table_name", "Utf8"},
       {"table_type", "Utf8"}
     ]},
    {"views",
     [
       {"table_catalog", "Utf8"},
       {"table_schema", "Utf8"},
       {"table_name", "Utf8"},
       {"definition", "Utf8"}
     ]},
    {"columns",
     [
       {"table_catalog", "Utf8"},
       {"table_schema", "Utf8"},
       {"table_name", "Utf8"},
       {"column_name", "Utf8"},
       {"ordinal_position", "UInt64"},
       {"column_default", "Utf8"},
       {"is_nullable", "Utf8"},
       {"data_type", "Utf8"},
       {"character_maximum_length", "UInt64"},
       {"character_octet_length", "UInt64"},
       {"numeric_precision", "UInt64"},
       {"numeric_precision_radix", "UInt64"},
       {"numeric_scale", "UInt64"},
       {"datetime_precision", "UInt64"},
       {"interval_type", "Utf8"}
     ]},
    {"df_settings", [{"name", "Utf8"}, {"value", "Utf8"}, {"description", "Utf8"}]},
    {"schemata",
     [
       {"catalog_name", "Utf8"},
       {"schema_name", "Utf8"},
       {"schema_owner", "Utf8"},
       {"default_character_set_catalog", "Utf8"},
       {"default_character_set_schema", "Utf8"},
       {"default_character_set_name", "Utf8"},
       {"sql_path", "Utf8"}
     ]},
    {"routines",
     [
       {"specific_catalog", "Utf8"},
       {"specific_schema", "Utf8"},
       {"specific_name", "Utf8"},
       {"routine_catalog", "Utf8"},
       {"routine_schema", "Utf8"},
       {"routine_name", "Utf8"},
       {"routine_type", "Utf8"},
       {"is_deterministic", "Boolean"},
       {"data_type", "Utf8"},
       {"function_type", "Utf8"},
       {"description", "Utf8"},
       {"syntax_example", "Utf8"}
     ]},
    {"parameters",
     [
       {"specific_catalog", "Utf8"},
       {"specific_schema", "Utf8"},
       {"specific_name", "Utf8"},
       {"ordinal_position", "UInt64"},
       {"parameter_mode", "Utf8"},
       {"parameter_name", "Utf8"},
       {"data_type", "Utf8"},
       {"parameter_default", "Utf8"},
       {"is_variadic", "Boolean"},
       {"rid", "UInt8"}
     ]}
  ]

  @doc "The columns of a table of the `system` or `information_schema` schema, `{name, Arrow type}` in its order, or `nil` for a table it has not."
  @spec columns(binary(), binary()) :: [{binary(), binary()}] | nil
  def columns("system", table), do: List.keyfind(@system, table, 0) |> columns_of()

  def columns("information_schema", table),
    do: List.keyfind(@information_schema, table, 0) |> columns_of()

  @spec columns_of({binary(), [{binary(), binary()}]} | nil) :: [{binary(), binary()}] | nil
  defp columns_of(nil), do: nil
  defp columns_of({_table, columns}), do: columns
end
