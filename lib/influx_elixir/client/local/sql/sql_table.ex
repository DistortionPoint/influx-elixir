defmodule InfluxElixir.Client.Local.SQLTable do
  @moduledoc false
  # How a `FROM` names a table, for `InfluxElixir.Client.Local` (verified
  # against InfluxDB 3 Core): one part, `m`, is a table of the `iox` schema;
  # two, `schema.m`, are a schema of the `public` catalog and a table; three,
  # `catalog.schema.m`, a catalog too. The catalog is `public`, the schemas are
  # `iox` (the measurements), `information_schema` (its `tables`, `columns` and
  # `schemata`) and `system` (tables of the engine's own, not modelled).
  #
  # A table is known by any tail of its full name (`m`, `iox.m`, `public.iox.m`)
  # in a column's qualifier; the name a query prints for a column it does not
  # name (`count(iox.m.v)`) is the one the `FROM` wrote.

  alias InfluxElixir.Client.Local.{SQLError, SQLInformation}

  @catalog "public"
  @information ~w(tables columns schemata)
  @information_other ~w(views df_settings routines parameters)

  @typedoc """
  What a table reference names: the measurement the executor reads (an
  `information_schema` table is `information_schema.<name>`), the qualifiers
  its columns may carry besides the one written, or the engine's error.
  """
  @type resolved ::
          {:ok, %{measurement: binary(), qualifiers: [binary()]}} | {:error, SQLError.t()}

  @doc """
  Resolves a bare (unquoted) table reference as written, folded to lower case
  as the engine folds it.
  """
  @spec resolve(binary()) :: resolved()
  def resolve(text) do
    case String.split(text, ".") do
      [name] -> iox(name)
      [schema, name] -> schema_table(@catalog, schema, name)
      [catalog, schema, name] -> schema_table(catalog, schema, name)
      parts -> {:error, compound(parts)}
    end
  end

  defp iox(name), do: {:ok, %{measurement: name, qualifiers: tails("iox", name)}}

  defp schema_table(@catalog, "iox", name), do: iox(name)

  defp schema_table(@catalog, "information_schema", name) when name in @information,
    do:
      {:ok,
       %{
         measurement: SQLInformation.relation_name(name),
         qualifiers: [name, "information_schema." <> name, "public.information_schema." <> name]
       }}

  defp schema_table(@catalog, "information_schema", name) when name in @information_other,
    do:
      {:error,
       SQLError.refusal(
         "information_schema.#{name}: the double models information_schema.tables, " <>
           "information_schema.columns and information_schema.schemata"
       )}

  defp schema_table(@catalog, "system", name),
    do: {:error, SQLError.refusal("system.#{name}: the engine's system tables are not modelled")}

  defp schema_table(catalog, schema, name),
    do:
      {:error, SQLError.planning("table '#{Enum.join([catalog, schema, name], ".")}' not found")}

  # `name`, `iox.name` and `public.iox.name`: the tails of the full name.
  defp tails(schema, name), do: [name, schema <> "." <> name, "public." <> schema <> "." <> name]

  defp compound(parts) do
    SQLError.planning(
      "Unsupported compound identifier '#{Enum.join(parts, ".")}'. " <>
        "Expected 1, 2 or 3 parts, got #{length(parts)}"
    )
  end

  @doc "The qualifiers, besides the one written, that a table reference's columns may carry."
  @spec qualifiers(binary()) :: [binary()]
  def qualifiers(text) do
    case resolve(text) do
      {:ok, %{qualifiers: qualifiers}} -> qualifiers
      {:error, _reason} -> []
    end
  end
end
