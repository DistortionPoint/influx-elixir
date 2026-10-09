defmodule InfluxElixir.Client.Local.InfluxQLProjection do
  @moduledoc false
  # The projection plan of a `SELECT`: every column of the answer in the order the engine
  # lists them, with its source, its role and its final name. The names of the columns, the
  # windows of `LIMIT` and `OFFSET` and the planning error of two columns with one name are
  # all read from this one plan.
  #
  # The engine lists the columns of a projection as: the time (the first `time` that is
  # selected takes this place, under its alias), the dimensions of the `GROUP BY` that are not
  # selected under their own name, then the select list in order, a `*` written out as the
  # columns it stands for and `top()` / `bottom()` as the value followed by the tags it
  # chooses by (verified).
  #
  # A name is given twice (verified):
  #
  #   * first the select list alone, in order, takes each name that is free and numbers one
  #     that is taken `name_1`, `name_2`, skipping the names taken (`i AS i_1, i, i` is
  #     `i_1, i, i_2`)
  #   * then the projection, with the time and the dimensions, numbers a name by how many
  #     columns before it were written with it (`name_1`, `name_2`), and two columns that end
  #     up with one name are the planning error (`usage AS time, n AS time_1` and
  #     `top(v, host, 1) AS host_1 ... GROUP BY host` are errors)
  #
  # A role is what the column is to the rows: `:time`, a `:dimension` of the series, a `:tag`
  # or a `:field`. A row of a plain select is kept when it holds a field.

  alias InfluxElixir.Client.Local.{InfluxQL, InfluxQLExpr, InfluxQLNames}

  @typedoc "What a column is to the rows."
  @type role :: :time | :dimension | :tag | :field

  @typedoc "Where a column comes from."
  @type kind ::
          :time
          | :time_expr
          | :dimension
          | :column
          | :star
          | :expr
          | :constant
          | :aggregate
          | :value
          | :chosen

  @typedoc "A column of the projection."
  @type entry :: %{
          role: role(),
          kind: kind(),
          source: binary() | nil,
          item: non_neg_integer() | nil,
          written: binary() | nil,
          name: binary() | nil
        }

  @typedoc "The plan: its columns, the select list under their names, and the lookups."
  @type t :: %{
          entries: [entry()],
          items: [InfluxQL.item()],
          time: binary(),
          dimensions: %{binary() => binary()},
          star: [{binary(), binary()}],
          fields: [binary()],
          kept: [binary()],
          multi: nil | %{value: binary(), tags: [binary()]}
        }

  @typedoc "What the plan reads of the measurement and the `GROUP BY`."
  @type schema :: %{
          tags: MapSet.t(binary()),
          types: %{binary() => atom()},
          dimensions: [binary()],
          regex?: boolean()
        }

  @doc """
  The plan of `query` over `schema`. Throws `{:refused, {:engine, 400, body}}` when two
  columns end up with one name, and `{:refused, message}` for a form the double has not seen.
  """
  @spec build(InfluxQL.query(), schema()) :: t()
  # A `*` alone is the time and every column under its own name: the names of a schema are free.
  def build(%{items: [:star]}, %{dimensions: []} = schema) do
    star = star_columns(schema)

    entries =
      [
        entry(:time, :time, "time", nil, "time")
        | for(source <- star, do: starred(source, schema))
      ]

    fields = for %{role: :field, written: name} <- entries, do: name

    %{
      entries: Enum.map(entries, &%{&1 | name: &1.written}),
      items: [:star],
      time: "time",
      dimensions: %{},
      star: for(source <- star, do: {source, source}),
      fields: fields,
      kept: fields,
      multi: nil
    }
  end

  def build(%{items: items, measurement: table} = query, schema) do
    star = if :star in items, do: star_columns(schema), else: []

    {pieces, _taken} =
      items
      |> Enum.with_index()
      |> Enum.flat_map_reduce(InfluxQLNames.new_taken(), &piece(&1, &2, star, schema))

    lead = lead_entry(pieces)
    rest = Enum.reject(pieces, &(&1 === lead))
    entries = name_entries([lead | placed(schema, pieces)] ++ rest)
    fields = field_names(entries)

    kept =
      if Enum.any?(entries, &(&1.kind == :constant)),
        do: field_names(Enum.reject(entries, &(&1.kind == :constant))),
        else: fields

    # The engine plans the projection when a field is read; a list of tags and times alone
    # answers nothing, whatever the names.
    if Enum.any?(entries, &reads_field?(&1, items, schema)) do
      if captured?(pieces, schema),
        do:
          throw(
            {:refused, "unsupported InfluxQL (a tag or a time aliased to a GROUP BY dimension)"}
          )

      if absent_captured?(pieces, schema),
        do:
          throw(
            {:refused,
             "unsupported InfluxQL (a column the measurement lacks aliased to a GROUP BY dimension)"}
          )

      if dimension_renamed?(query, pieces, schema),
        do:
          throw(
            {:refused,
             "unsupported InfluxQL (a GROUP BY tag selected under another name beside a second " <>
               "dimension, with LIMIT or OFFSET)"}
          )

      unique_names!(entries, table, schema)
    end

    %{
      entries: entries,
      items: rename(items, entries, schema),
      time: hd(entries).name,
      dimensions:
        for(%{kind: :dimension, source: tag, name: name} <- entries, into: %{}, do: {tag, name}),
      star: for(%{kind: :star, source: source, name: name} <- entries, do: {source, name}),
      fields: fields,
      kept: kept,
      multi: multi(entries, query)
    }
  end

  # ---------------------------------------------------------------------------
  # The select list, in order
  # ---------------------------------------------------------------------------

  # What `*` stands for: every field and the tags the series are not told apart by (with a
  # regular expression among the dimensions only those it groups by are shown).
  @spec star_columns(schema()) :: [binary()]
  defp star_columns(%{tags: tags, types: types, dimensions: dimensions, regex?: regex?}) do
    shown = if regex?, do: MapSet.intersection(tags, MapSet.new(dimensions)), else: tags
    (Map.keys(types) ++ (MapSet.to_list(shown) -- dimensions)) |> Enum.uniq() |> Enum.sort()
  end

  # The columns of one item, each with the name the select list gives it.
  @spec piece({InfluxQL.item(), non_neg_integer()}, InfluxQLNames.taken(), [binary()], schema()) ::
          {[entry()], InfluxQLNames.taken()}
  defp piece({:star, index}, taken, star, schema) do
    {entries, taken} =
      Enum.map_reduce(star, taken, fn source, taken ->
        {written, taken} = InfluxQLNames.unique(source, taken)
        {entry(source_role(source, schema), :star, source, index, written), taken}
      end)

    {entries, taken}
  end

  defp piece(
         {{:multi, _kind, field, tags, _limit, _alias} = item, index},
         taken,
         _star,
         _schema
       ) do
    {written, taken} = InfluxQLNames.unique(InfluxQLNames.item_name(item), taken)

    chosen =
      for tag <- tags, do: entry(:tag, :chosen, tag, index, tag)

    {[entry(:field, :value, field, index, written) | chosen], taken}
  end

  defp piece({item, index}, taken, _star, schema) do
    case InfluxQLNames.item_name(item) do
      nil ->
        {opaque(item, index), taken}

      name ->
        {written, taken} = InfluxQLNames.unique(name, taken)
        {[named(item, index, written, schema)], taken}
    end
  end

  # An item whose names are known once the rows are (`count(*)`): it takes no part in the names.
  defp opaque({:aggregate, _fun, _arg, _alias}, index),
    do: [entry(:field, :aggregate, nil, index, nil)]

  defp opaque(_item, _index), do: []

  defp named({:column, column, _name} = item, index, written, schema) do
    if InfluxQLNames.time_item?(item),
      do: entry(:time, :time, column, index, written),
      else: entry(source_role(column, schema), :column, column, index, written)
  end

  defp named({:expr, ast, _alias}, index, written, schema) do
    cond do
      time_ref?(ast) -> entry(:time, :time_expr, "time", index, written)
      constant?(ast, schema) -> entry(:field, :constant, nil, index, written)
      true -> entry(:field, :expr, nil, index, written)
    end
  end

  defp named({:aggregate, _fun, _arg, _alias}, index, written, _schema),
    do: entry(:field, :aggregate, nil, index, written)

  # Whether a column reads a field of the measurement (a tag, the time, a constant and a column
  # the measurement lacks are none): the engine plans the projection, and so words its errors,
  # only for a list that reads one.
  @spec reads_field?(entry(), [InfluxQL.item()], schema()) :: boolean()
  defp reads_field?(%{kind: kind, source: source}, _items, %{types: types})
       when kind in [:star, :column],
       do: Map.has_key?(types, source)

  defp reads_field?(%{kind: kind}, _items, _schema) when kind in [:value, :aggregate], do: true

  defp reads_field?(%{kind: :expr, item: index}, items, %{types: types}) do
    {:expr, ast, _alias} = Enum.at(items, index)
    Enum.any?(InfluxQLExpr.refs(ast), &Map.has_key?(types, &1))
  end

  defp reads_field?(_entry, _items, _schema), do: false

  # An expression that is a constant false: a column the measurement lacks beside a tag, a
  # string or a boolean. It is a column of every row that is kept, and keeps none.
  defp constant?(ast, %{types: types, tags: tags}),
    do: match?({:bool, _value}, InfluxQLExpr.fold(ast, types, tags))

  defp time_ref?({:ref, name}), do: String.downcase(name) == "time"
  defp time_ref?(_ast), do: false

  defp starred(source, schema),
    do: entry(source_role(source, schema), :star, source, 0, source)

  defp source_role(column, %{tags: tags}),
    do: if(MapSet.member?(tags, column), do: :tag, else: :field)

  defp entry(role, kind, source, item, written),
    do: %{role: role, kind: kind, source: source, item: item, written: written, name: nil}

  # The time that leads: the first `time` that is selected, else the one the engine adds.
  @spec lead_entry([entry()]) :: entry()
  defp lead_entry(pieces) do
    Enum.find(pieces, &(&1.kind == :time)) || entry(:time, :time, "time", nil, "time")
  end

  # The dimensions that are columns of their own: one selected under its own name is that
  # column.
  @spec placed(schema(), [entry()]) :: [entry()]
  defp placed(%{dimensions: dimensions}, pieces) do
    for dimension <- dimensions,
        not Enum.any?(
          pieces,
          &(&1.kind == :column and &1.source == dimension and &1.written == dimension)
        ),
        do: entry(:dimension, :dimension, dimension, nil, dimension)
  end

  # A tag that is a dimension, selected under another name beside a second dimension, with a
  # `LIMIT` or an `OFFSET`, makes the engine's physical plan fail its own sanity check (a 400
  # of several lines of plan, verified: `SELECT host AS x, u ... GROUP BY region, host
  # LIMIT 1`; not without the `LIMIT`, with one dimension, or beside an aggregate).
  @spec dimension_renamed?(InfluxQL.query(), [entry()], schema()) :: boolean()
  defp dimension_renamed?(query, pieces, %{dimensions: dimensions}) do
    (query.limit != nil or query.offset > 0) and length(dimensions) > 1 and
      not Enum.any?(pieces, &(&1.kind in [:aggregate, :value])) and
      Enum.any?(pieces, fn piece ->
        piece.kind == :column and piece.role == :tag and piece.source in dimensions and
          piece.written != piece.source
      end)
  end

  # A column the measurement lacks, named as a dimension: the series the engine answers are not
  # those of the dimension (verified: `SELECT nosuch AS host, usage ... GROUP BY host LIMIT 1`
  # is one row, not one per host), which the double does not tell.
  @spec absent_captured?([entry()], schema()) :: boolean()
  defp absent_captured?(pieces, %{dimensions: dimensions, types: types, tags: tags}) do
    Enum.any?(pieces, fn piece ->
      piece.kind == :column and piece.role == :field and piece.written in dimensions and
        piece.source != piece.written and not Map.has_key?(types, piece.source) and
        not MapSet.member?(tags, piece.source)
    end)
  end

  # A tag or the time aliased to the name of a dimension is the dimension: the engine tells the
  # series apart by it (verified: `SELECT usage, host AS region ... GROUP BY region` is
  # grouped by the hosts, and `time AS host ... GROUP BY host` by the times). The double does
  # not group so; a list with no field answers nothing, whatever the names.
  @spec captured?([entry()], schema()) :: boolean()
  defp captured?(pieces, %{dimensions: dimensions}) do
    Enum.any?(pieces, fn piece ->
      piece.role in [:tag, :time] and piece.kind != :chosen and piece.written in dimensions and
        not (piece.kind == :column and piece.source == piece.written)
    end)
  end

  # ---------------------------------------------------------------------------
  # Names
  # ---------------------------------------------------------------------------

  # A name that columns before it were written with is numbered by how many.
  @spec name_entries([entry()]) :: [entry()]
  defp name_entries(entries) do
    {named, _seen} =
      Enum.map_reduce(entries, %{}, fn
        %{written: nil} = entry, seen ->
          {entry, seen}

        %{written: written} = entry, seen ->
          count = Map.get(seen, written, 0)
          name = if count == 0, do: written, else: "#{written}_#{count}"
          {%{entry | name: name}, Map.put(seen, written, count + 1)}
      end)

    named
  end

  # The select list under the names of the plan (the `*` and the tags `top()` chooses by are
  # not items of it).
  @spec rename([InfluxQL.item()], [entry()], schema()) :: [InfluxQL.item()]
  defp rename(items, entries, schema) do
    names =
      for %{item: index, name: name, kind: kind} <- entries,
          index != nil,
          kind in [:time, :time_expr, :column, :expr, :constant, :aggregate, :value],
          name != nil,
          into: %{},
          do: {index, name}

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> renamed(item, Map.get(names, index), schema) end)
  end

  defp renamed(item, nil, _schema), do: item
  defp renamed({:column, column, _name}, name, _schema), do: {:column, column, name}

  defp renamed({:expr, ast, _alias}, name, %{types: types, tags: tags}),
    do: {:expr, InfluxQLExpr.fold(ast, types, tags), name}

  defp renamed({:aggregate, fun, arg, _alias}, name, _schema),
    do: {:aggregate, fun, arg, name}

  defp renamed({:multi, kind, field, tags, limit, _alias}, name, _schema),
    do: {:multi, kind, field, tags, limit, name}

  defp renamed(item, _name, _schema), do: item

  # The columns a window counts: the fields, once each, under their names.
  @spec field_names([entry()]) :: [binary()]
  defp field_names(entries) do
    for(%{role: :field, name: name} when name != nil <- entries, do: name) |> Enum.uniq()
  end

  # The names of the value `top()` / `bottom()` answers and of the tags it chooses by.
  @spec multi([entry()], InfluxQL.query()) :: nil | %{value: binary(), tags: [binary()]}
  defp multi(entries, %{items: items}) do
    case Enum.find_index(items, &match?({:multi, _k, _f, _t, _n, _a}, &1)) do
      nil ->
        nil

      index ->
        chosen = Enum.filter(entries, &(&1.item == index))
        %{value: hd(chosen).name, tags: for(%{kind: :chosen, name: name} <- chosen, do: name)}
    end
  end

  # ---------------------------------------------------------------------------
  # Two columns with one name
  # ---------------------------------------------------------------------------

  # The planning error, worded with the expression of each column.
  @spec unique_names!([entry()], binary(), schema()) :: :ok
  defp unique_names!(entries, table, schema) do
    case first_clash(Enum.with_index(entries), %{}) do
      nil ->
        :ok

      {{first, index_a}, {second, index_b}} ->
        body =
          "Error during planning: Projections require unique expression names but the " <>
            "expression \"#{expression(first, table, schema)}\" at position #{index_a} and " <>
            "\"#{expression(second, table, schema)}\" at position #{index_b} have the same " <>
            "name. Consider aliasing (\"AS\") one of them."

        throw({:refused, {:engine, 400, body}})
    end
  end

  defp first_clash([], _seen), do: nil

  defp first_clash([{%{name: nil}, _index} | rest], seen), do: first_clash(rest, seen)

  defp first_clash([{%{name: name}, _index} = indexed | rest], seen) do
    case seen do
      %{^name => earlier} -> {earlier, indexed}
      _unseen -> first_clash(rest, Map.put(seen, name, indexed))
    end
  end

  # The expression the engine prints for a column: its source under its name; a column the
  # measurement lacks is a NULL. A column printed as it is, with no `AS`, and an expression
  # are forms the double has not seen.
  defp expression(%{kind: kind, source: source, name: name}, table, %{tags: tags, types: types})
       when kind in [:time, :time_expr, :dimension, :column, :star, :chosen, :value] do
    cond do
      kind in [:column, :chosen, :star] and
          not (MapSet.member?(tags, source) or Map.has_key?(types, source)) ->
        "NULL AS #{name}"

      source != name ->
        "#{table}.#{source} AS #{name}"

      true ->
        refuse()
    end
  end

  defp expression(_entry, _table, _schema), do: refuse()

  defp refuse,
    do: throw({:refused, "unsupported InfluxQL (select items that end up with the same name)"})

  @doc "Whether an expression is the `time` column in parentheses (a column of its own)."
  @spec time_expr?(InfluxQLExpr.ast()) :: boolean()
  def time_expr?(ast), do: time_ref?(ast)
end
