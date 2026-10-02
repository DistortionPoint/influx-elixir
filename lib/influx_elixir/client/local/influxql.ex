defmodule InfluxElixir.Client.Local.InfluxQL do
  @moduledoc """
  The InfluxQL `SELECT` subset `InfluxElixir.Client.Local` answers, shaped
  the way InfluxDB 3 answers it (verified against the engine; see
  `docs/design/2026-09-23_local-influxql.md`).

  InfluxQL is not SQL with other keywords. Every row carries
  `"iox::measurement"` and `"time"`; rows come back in time order; a row with
  no selected field value is dropped; an unknown column or measurement is an
  empty result, not an error; aggregates are named after the function
  (`mean`, `count`, ...) and put `time` at the lower bound the `WHERE`
  gives `time` (the epoch when it gives none), except a lone selector
  (`MAX`, `MIN`, `FIRST`, `LAST`), which returns its point's time and tags;
  `LIMIT` and `OFFSET` apply per `GROUP BY` series.

  This module is pure. `parse/1` turns the statement into a query map;
  `run/4` shapes rows the caller has already filtered with the statement's
  `WHERE` clause (Client.Local runs it through its SQL engine) and put in
  time order.

  `WHERE` follows InfluxQL, not SQL (`where_plan/2`): a missing tag is the
  empty string (`host != 'a'` keeps points without `host`, `host = ''`
  finds them), `=~ /re/` and `!~ /re/` are unanchored matches on tags and
  false on fields, `<`/`>` on a tag is false, durations (`now() - 30m`)
  are intervals, double-quoted identifiers are exact, and `NOT` is the
  engine's parse error. Compared with `time`, a bare integer or a duration
  is an offset from the epoch in nanoseconds (`time >= 2`, `time > 0s`,
  `time > 1s - 999999999ns`), `!=` and `<>` are the engine's planning
  error, and a float is refused. The engine pulls `time` comparisons out
  of the whole `WHERE` as if they were joined by `AND`, so one inside an
  `OR` is refused by name. `SHOW TAG VALUES [FROM m] WITH KEY = | != | =~ |
  !~ | IN (...)` [WHERE ...] lists values as the engine does, over the
  last 24 hours unless the `WHERE` bounds `time` (`parse_show_tag_values/1`).

  Refused by name, rather than answered wrongly: `GROUP BY time(...)` (the
  engine fills every empty bucket), `fill()`, `INTO`, `SLIMIT`/`SOFFSET`,
  subqueries, `GROUP BY *`, functions other than
  `MEAN SUM COUNT MIN MAX FIRST LAST`, `F(*)` other than `COUNT(*)`, plain
  columns beside anything but a single selector, arithmetic in the select
  list, several measurements in `FROM`, sub-second durations in `now() -
  ...`, and `LIMIT` / `OFFSET` on `SHOW TAG VALUES`. A keyword inside a
  quoted string, quoted identifier or regular expression is not one:
  `WHERE k = 'into'` is answered.
  """

  alias InfluxElixir.Client.Local.{SQLMask, SQLParser}

  @epoch DateTime.from_unix!(0, :microsecond)

  @aggregates ~w(mean sum count min max first last)
  @selectors ~w(min max first last)

  @typedoc "A select item: every column, a column, or a function of a column."
  @type item ::
          :star
          | {:column, binary(), binary()}
          | {:aggregate, binary(), binary() | :star, binary() | nil}

  @typedoc "A parsed `SELECT`."
  @type query :: %{
          items: [item()],
          measurement: binary(),
          where: binary() | nil,
          group_by: [binary()],
          descending: boolean(),
          limit: non_neg_integer() | nil,
          offset: non_neg_integer()
        }

  # Regexes nested in a list cannot be module attributes on OTP 28, so the
  # table is a function.
  @spec unsupported() :: [{Regex.t(), binary()}]
  defp unsupported do
    [
      {~r/\bfill\s*\(/i, "fill()"},
      {~r/\bINTO\b/i, "INTO"},
      {~r/\bS(?:LIMIT|OFFSET)\b/i, "SLIMIT/SOFFSET"},
      {~r/\bFROM\s*\(/i, "subqueries"},
      {~r/\bGROUP\s+BY\b.*\btime\s*\(/is, "GROUP BY time(...)"},
      {~r/\bGROUP\s+BY\s+\*/i, "GROUP BY *"},
      {~r/\btz\s*\(/i, "tz()"}
    ]
  end

  @select ~r/^\s*SELECT\s+(?<items>.+?)\s+FROM\s+(?<from>"(?:[^"\\]|\\.)+"|[A-Za-z_][\w\-]*)(?<rest>.*)$/is

  @rest ~r/^\s*(?:WHERE\s+(?<where>.+?))?\s*(?:GROUP\s+BY\s+(?<group>.+?))?\s*(?:ORDER\s+BY\s+time(?:\s+(?<dir>ASC|DESC))?)?\s*(?:LIMIT\s+(?<limit>\d+))?\s*(?:OFFSET\s+(?<offset>\d+))?\s*;?\s*$/is

  @function ~r/^(?<fn>[A-Za-z_]\w*)\s*\(\s*(?<arg>\*|"[^"]+"|[\w.]+)\s*\)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is
  @column ~r/^(?<col>"[^"]+"|[\w.]+)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is

  @doc """
  Parses an InfluxQL `SELECT`. Returns `{:error, message}` for syntax the
  engine rejects and for the constructs listed in the moduledoc.
  """
  @spec parse(binary()) :: {:ok, query()} | {:error, binary() | {:engine, binary()}}
  def parse(statement) do
    masked = mask_literals(statement)

    with :ok <- check_supported(masked),
         %{"items" => items, "from" => from, "rest" => rest} <-
           slices(@select, masked, statement) || {:error, "invalid statement"},
         %{"rest" => masked_rest} = slices(@select, masked, masked),
         %{} = clauses <- slices(@rest, masked_rest, rest) || {:error, "invalid clauses"},
         :ok <- check_where(statement, rest, masked_rest, blank_to_nil(clauses["where"])),
         {:ok, items} <- parse_items(items),
         :ok <- check_mix(items) do
      {:ok,
       %{
         items: items,
         measurement: unquote_ident(from),
         where: blank_to_nil(clauses["where"]),
         group_by: parse_group(clauses["group"]),
         descending: String.upcase(clauses["dir"]) == "DESC",
         limit: to_int(clauses["limit"]),
         offset: to_int(clauses["offset"]) || 0
       }}
    end
  end

  @doc """
  Shapes `rows` — the measurement's points already filtered by the
  statement's `WHERE`, as SQL row maps with `"time"`, **in time order** —
  into the engine's answer. `tags` names the measurement's tag columns;
  everything else but `time` is a field.

  Options:

    * `:lower` - the lower bound (nanoseconds) the `WHERE` gives `time`;
      an aggregate row is stamped with it, and with the epoch without one
      (verified: `WHERE time >= 2` answers `mean` at 2 ns, `WHERE time < 3`
      at the epoch; with `GROUP BY` every series carries it)
    * `:fields` - the measurement's field names, when `LIMIT` or `OFFSET`
      need them (they are read from the rows otherwise)
  """
  @spec run(query(), [map()], MapSet.t(binary()), keyword()) :: [map()]
  def run(query, rows, tags, opts \\ []) do
    context = %{
      query: query,
      tags: tags,
      time: lower_time(Keyword.get(opts, :lower)),
      fields: Keyword.get(opts, :fields),
      sources: Map.new(for({:column, column, name} <- query.items, do: {name, column}))
    }

    query
    |> series_groups(rows)
    |> Enum.flat_map(fn {key, group} ->
      group
      |> series(context, key)
      |> window(context)
    end)
  end

  # `LIMIT` and `OFFSET` of one series. A row of an aggregate is one row;
  # for plain columns the engine counts per selected field, not per row
  # (verified): `SELECT v, x FROM m LIMIT 1` is the first row with a `v` and
  # the first with an `x`, which may be two rows, each with its own field
  # only. A row that keeps no field is dropped.
  @spec window([map()], map()) :: [map()]
  defp window(rows, %{query: %{limit: nil, offset: 0}}), do: rows

  defp window(rows, %{query: query} = context) do
    if Enum.any?(query.items, &match?({:aggregate, _fn, _arg, _alias}, &1)),
      do: rows |> Enum.drop(query.offset) |> take(query.limit),
      else: window_per_field(rows, context)
  end

  defp window_per_field(rows, %{query: query} = context) do
    fields = window_fields(rows, context)

    # row index => the fields of it inside their windows
    kept =
      Enum.reduce(fields, %{}, fn field, kept ->
        field
        |> window_indices(rows, query)
        |> Enum.reduce(kept, fn index, kept -> Map.update(kept, index, [field], &[field | &1]) end)
      end)

    last = kept |> Map.keys() |> Enum.max(fn -> -1 end)

    for {row, index} <- rows |> Enum.take(last + 1) |> Enum.with_index(),
        {:ok, keep} <- [Map.fetch(kept, index)] do
      Map.drop(row, fields -- keep)
    end
  end

  # The fields a window counts, as the rows name them: the selected
  # columns that are fields, `*` being the measurement's (or, when the
  # caller did not say, those the rows hold).
  @spec window_fields([map()], map()) :: [binary()]
  defp window_fields(rows, %{query: query} = context) do
    query.items
    |> Enum.flat_map(fn
      :star -> star_fields(rows, context)
      {:column, column, name} -> if MapSet.member?(context.tags, column), do: [], else: [name]
    end)
    |> Enum.uniq()
  end

  defp star_fields(rows, %{fields: nil} = context) do
    rows
    |> Enum.flat_map(fn row ->
      for {name, _value} <- row,
          name not in ["iox::measurement", "time"],
          field?(name, context),
          do: name
    end)
    |> Enum.uniq()
  end

  defp star_fields(_rows, %{fields: fields}), do: fields

  # The indices of the rows that hold `field` inside its window, stopping
  # at the end of it.
  @spec window_indices(binary(), [map()], query()) :: [non_neg_integer()]
  defp window_indices(field, rows, query) do
    wanted = if query.limit, do: query.offset + query.limit, else: :all
    rows |> field_indices(field, 0, wanted, []) |> Enum.drop(query.offset)
  end

  defp field_indices(_rows, _field, _index, 0, acc), do: Enum.reverse(acc)
  defp field_indices([], _field, _index, _wanted, acc), do: Enum.reverse(acc)

  defp field_indices([row | rows], field, index, wanted, acc) do
    if Map.has_key?(row, field),
      do: field_indices(rows, field, index + 1, decrement(wanted), [index | acc]),
      else: field_indices(rows, field, index + 1, wanted, acc)
  end

  defp decrement(:all), do: :all
  defp decrement(n), do: n - 1

  # The rows of each `GROUP BY` series, in order of the tag values; the
  # rows keep the time order they came in (the grouping is stable). Without
  # a `GROUP BY` there is one series and no pass to group it.
  @spec series_groups(query(), [map()]) :: [{map(), [map()]}]
  defp series_groups(%{group_by: []}, []), do: []
  defp series_groups(%{group_by: []}, rows), do: [{%{}, rows}]

  defp series_groups(%{group_by: group_by}, rows) do
    rows
    |> Enum.group_by(&Map.take(&1, group_by))
    |> Enum.sort_by(fn {key, _rows} -> Enum.map(group_by, &series_sort_key(key, &1)) end)
  end

  # The series that lacks the tag comes after every tag value, as the engine lists it.
  @spec series_sort_key(map(), binary()) :: {boolean(), term()}
  defp series_sort_key(key, tag) do
    value = Map.get(key, tag)
    {is_nil(value), value}
  end

  @spec lower_time(integer() | nil) :: DateTime.t()
  defp lower_time(nil), do: @epoch
  defp lower_time(ns), do: DateTime.from_unix!(Integer.floor_div(ns, 1_000), :microsecond)

  # ---------------------------------------------------------------------------
  # One series (one GROUP BY key)
  # ---------------------------------------------------------------------------

  @spec series([map()], map(), map()) :: [map()]
  defp series(rows, %{query: query} = context, key) do
    base = Map.put(key, "iox::measurement", query.measurement)

    if Enum.any?(query.items, &match?({:aggregate, _fn, _arg, _alias}, &1)),
      do: aggregate(rows, query.items, context.tags, base, context.time),
      else: project(rows, context, base)
  end

  @spec project([map()], map(), map()) :: [map()]
  defp project(rows, %{query: query} = context, base) do
    rows = if query.descending, do: Enum.reverse(rows), else: rows
    star? = query.items == [:star]

    for row <- rows,
        projected = if(star?, do: Map.delete(row, "time"), else: projection(query.items, row)),
        Enum.any?(projected, fn {name, _value} -> field?(name, context) end) do
      base |> Map.put("time", row["time"]) |> Map.merge(projected)
    end
  end

  @spec projection([item()], map()) :: map()
  defp projection(items, row), do: Enum.reduce(items, %{}, &put_item(&1, row, &2))

  @spec put_item(item(), map(), map()) :: map()
  defp put_item(:star, row, acc), do: Map.merge(acc, Map.delete(row, "time"))

  defp put_item({:column, column, name}, row, acc) do
    case Map.fetch(row, column) do
      {:ok, value} -> Map.put(acc, name, value)
      :error -> acc
    end
  end

  # A projected key counts as a field value unless it is a tag (under its
  # own name or an alias; `sources` maps an alias to its column).
  @spec field?(binary(), map()) :: boolean()
  defp field?(name, %{sources: sources, tags: tags}),
    do: not MapSet.member?(tags, Map.get(sources, name, name))

  @spec aggregate([map()], [item()], MapSet.t(binary()), map(), DateTime.t()) :: [map()]
  defp aggregate(rows, items, tags, base, time) do
    aggregates = for {:aggregate, _fn, _arg, _alias} = item <- items, do: item
    fields = if count_star?(aggregates), do: field_names(rows, tags), else: []

    {values, _names} =
      Enum.flat_map_reduce(aggregates, %{}, fn item, names ->
        item
        |> compute(rows, fields)
        |> Enum.map_reduce(names, fn {name, value}, names ->
          {unique, names} = unique_name(name, names)
          {{unique, value}, names}
        end)
      end)

    values = for {name, {:value, value, _point}} <- values, into: %{}, do: {name, value}

    cond do
      values == %{} ->
        []

      lone_selector?(aggregates) ->
        [{:aggregate, fun, field, _alias}] = aggregates
        {:value, _value, point} = select(fun, rows, field)

        columns =
          for {:column, column, name} <- items,
              Map.has_key?(point, column),
              into: %{},
              do: {name, point[column]}

        [base |> Map.put("time", point["time"]) |> Map.merge(columns) |> Map.merge(values)]

      true ->
        [base |> Map.put("time", time) |> Map.merge(values)]
    end
  end

  @spec count_star?([item()]) :: boolean()
  defp count_star?(aggregates),
    do: Enum.any?(aggregates, &match?({:aggregate, "count", :star, _alias}, &1))

  # The field names the rows hold, sorted: only `COUNT(*)` needs them.
  @spec field_names([map()], MapSet.t(binary())) :: [binary()]
  defp field_names(rows, tags) do
    rows
    |> Enum.reduce(MapSet.new(), fn row, names ->
      row |> Map.keys() |> MapSet.new() |> MapSet.union(names)
    end)
    |> Enum.reject(&(&1 == "time" or MapSet.member?(tags, &1)))
    |> Enum.sort()
  end

  @spec lone_selector?([item()]) :: boolean()
  defp lone_selector?([{:aggregate, fun, arg, _alias}]), do: fun in @selectors and arg != :star
  defp lone_selector?(_aggregates), do: false
  # [{output_name, {:value, value, point} | :none}]
  @spec compute(item(), [map()], [binary()]) :: [{binary(), {:value, term(), map()} | :none}]
  defp compute({:aggregate, "count", :star, _alias}, rows, fields) do
    for field <- fields, do: {"count_" <> field, count(rows, field)}
  end

  defp compute({:aggregate, fun, field, alias}, rows, _fields) do
    [{alias || fun, apply_function(fun, rows, field)}]
  end

  @spec apply_function(binary(), [map()], binary()) :: {:value, term(), map() | nil} | :none
  defp apply_function("count", rows, field), do: count(rows, field)
  defp apply_function(fun, rows, field) when fun in @selectors, do: select(fun, rows, field)

  defp apply_function(fun, rows, field) do
    case numbers(rows, field) do
      [] -> :none
      values when fun == "sum" -> {:value, Enum.sum(values), nil}
      values -> {:value, Enum.sum(values) / length(values), nil}
    end
  end

  @spec count([map()], binary()) :: {:value, non_neg_integer(), nil} | :none
  defp count(rows, field) do
    case Enum.count(rows, &Map.has_key?(&1, field)) do
      0 -> :none
      n -> {:value, n, nil}
    end
  end

  # Rows arrive in time order, so the first extreme wins a tie, as on the
  # engine.
  @spec select(binary(), [map()], binary()) :: {:value, term(), map()} | :none
  defp select(fun, rows, field) do
    candidates =
      if fun in ["first", "last"],
        do: Enum.filter(rows, &Map.has_key?(&1, field)),
        else: Enum.filter(rows, &is_number(&1[field]))

    case candidates do
      [] -> :none
      points -> pick(fun, points, field)
    end
  end

  @spec pick(binary(), [map(), ...], binary()) :: {:value, term(), map()}
  defp pick("first", [point | _rest], field), do: {:value, point[field], point}
  defp pick("last", points, field), do: pick("first", Enum.reverse(points), field)

  defp pick("max", points, field) do
    point = Enum.reduce(points, fn p, best -> if p[field] > best[field], do: p, else: best end)
    {:value, point[field], point}
  end

  defp pick("min", points, field) do
    point = Enum.reduce(points, fn p, best -> if p[field] < best[field], do: p, else: best end)
    {:value, point[field], point}
  end

  @spec numbers([map()], binary()) :: [number()]
  defp numbers(rows, field), do: for(%{^field => v} <- rows, is_number(v), do: v)

  # The engine names a second `min` `min_1`, a third `min_2`.
  @spec unique_name(binary(), map()) :: {binary(), map()}
  defp unique_name(name, names) do
    case Map.fetch(names, name) do
      :error -> {name, Map.put(names, name, 1)}
      {:ok, n} -> {"#{name}_#{n}", Map.put(names, name, n + 1)}
    end
  end

  # ---------------------------------------------------------------------------
  # Parsing helpers
  # ---------------------------------------------------------------------------

  @spec check_supported(binary()) :: :ok | {:error, binary()}
  defp check_supported(masked) do
    case Enum.find(unsupported(), fn {pattern, _name} -> Regex.match?(pattern, masked) end) do
      nil -> :ok
      {_pattern, name} -> {:error, "unsupported InfluxQL (#{name})"}
    end
  end

  # The named captures of `regex` run over `masked`, read from `text` (the
  # same length): a keyword inside a literal cannot end a clause early.
  @spec slices(Regex.t(), binary(), binary()) :: %{binary() => binary()} | nil
  defp slices(regex, masked, text) do
    with %{} = indexes <- Regex.named_captures(regex, masked, return: :index) do
      Map.new(indexes, fn {name, {from, length}} ->
        {name, if(from < 0, do: "", else: binary_part(text, from, length))}
      end)
    end
  end

  # The statement with the inside of every quoted string, quoted identifier
  # and `=~ /regex/` blanked to underscores, byte for byte (spaces would let
  # the clause regexes backtrack for ages), so that what is
  # looked for in it (`fill(`, `INTO`, `GROUP BY`) is a keyword and not a
  # piece of a value.
  @spec mask_literals(binary()) :: binary()
  defp mask_literals(statement) do
    SQLMask.mask(statement,
      blank: ?_,
      doubled: false,
      backslash: true,
      regex: true,
      lenient: true
    )
  end

  # ---------------------------------------------------------------------------
  # WHERE
  #
  # The caller runs the WHERE through its SQL engine; `where_plan/2` rewrites
  # it into that SQL with InfluxQL's semantics (verified against InfluxDB 3):
  #
  #   * a tag the point lacks is the empty string, so `host != 'a'` and
  #     `host !~ /a/` keep it and `host = ''` finds it — the caller fills
  #     missing tags with "" before filtering; a field keeps SQL's null
  #   * `tag =~ /re/` and `tag !~ /re/` are unanchored regular-expression
  #     (non-)matches; either on a field is false
  #   * `<`, `<=`, `>` and `>=` on a tag are false
  #   * a duration (`30m`, `1h`, `2d`, `1w`) is an interval next to `now()`;
  #     `now()` works
  #   * a double-quoted identifier is exact; InfluxQL folds no case
  #   * `NOT` does not exist: the engine's parse error
  #   * next to `time`, a duration or an integer is nanoseconds since the
  #     epoch (`time >= 2`, `time > 0s`, `time = 2ns`), constants add and
  #     subtract (`time > 1s - 999999999ns`); `!=` and `<>` are a planning
  #     error; a float is refused
  #   * the engine takes every `time` comparison out of the whole condition
  #     and joins them with the rest by `AND`, `OR` or not, so one inside an
  #     `OR` is refused rather than answered differently
  # ---------------------------------------------------------------------------

  @duration_ns %{
    "ns" => 1,
    "u" => 1_000,
    "µ" => 1_000,
    "ms" => 1_000_000,
    "s" => 1_000_000_000,
    "m" => 60_000_000_000,
    "h" => 3_600_000_000_000,
    "d" => 86_400_000_000_000,
    "w" => 604_800_000_000_000
  }

  @typedoc """
  A bound on `time`: nanoseconds since the epoch, or an offset from the
  query's `now()`.
  """
  @type bound :: integer() | {:now, integer()}

  @typedoc "A `WHERE` as the caller's SQL, with the lower bounds its `time` comparisons give."
  @type where_plan :: %{sql: binary(), lowers: [bound()], idents: MapSet.t(binary())}

  @doc """
  Rewrites an InfluxQL `WHERE` into the caller's SQL, given the
  measurement's tag columns. `{:error, message}` for what the double
  refuses by name; `{:error, {:engine, body}}` for what the engine itself
  answers with a 400.
  """
  @spec where_sql(binary(), MapSet.t(binary())) ::
          {:ok, binary()} | {:error, binary() | {:engine, binary()}}
  def where_sql(where, tags) do
    with {:ok, %{sql: sql}} <- where_plan(where, tags), do: {:ok, sql}
  end

  @doc """
  Like `where_sql/2`, with the column names the `WHERE` mentions and the
  lower bounds it puts on `time`:
  `time >= x` and `time = x` give `x`, `time > x` gives `x + 1`, upper
  bounds give none. An aggregate over a lower bound is stamped with the
  greatest of them (`run/4`).
  """
  @spec where_plan(binary(), MapSet.t(binary())) ::
          {:ok, where_plan()} | {:error, binary() | {:engine, binary()}}
  def where_plan(where, tags) do
    case tokenize(where, []) do
      {:ok, tokens} ->
        {tree, _rest} = parse_or(tokens)
        {sql, lowers} = plan(tree, tags)
        idents = for {:ident, name} <- tokens, into: MapSet.new(), do: name
        {:ok, %{sql: sql, lowers: lowers, idents: idents}}

      {:parse_error, rest} ->
        {:error, "unsupported InfluxQL WHERE: #{rest}"}

      {:error, _message} = error ->
        error
    end
  catch
    {:refused, message} -> {:error, message}
  end

  # What the engine's parser cannot read in the `WHERE` fails the statement
  # where it stands (verified), naming the position and the rest of the
  # statement, `;` and later clauses included. `NOT` is no InfluxQL keyword
  # (the position is the operand after it); a number is `\d*\.\d+` or `\d+`
  # only, so an exponent, a trailing dot, a hex or an underscore leaves the
  # rest of the literal behind (the position is where that begins).
  @spec check_where(binary(), binary(), binary(), binary() | nil) ::
          :ok | {:error, {:engine, binary()}}
  defp check_where(_statement, _rest, _masked_rest, nil), do: :ok

  defp check_where(statement, rest, masked_rest, where) do
    case tokenize(where, []) do
      {:parse_error, after_error} ->
        [{from, length}] = Regex.run(~r/\bWHERE\s+/i, masked_rest, return: :index)
        where_at = byte_size(statement) - byte_size(rest) + from + length
        pos = where_at + byte_size(where) - byte_size(after_error)
        leftover = binary_part(statement, pos, byte_size(statement) - pos)

        {:error,
         {:engine,
          "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos " <>
            "#{pos}. Parsing Error: Nom(#{inspect(leftover)}, Tag)"}}

      _tokens_or_refusal ->
        :ok
    end
  end

  @spec tokenize(binary(), list()) ::
          {:ok, list()} | {:parse_error, binary()} | {:error, binary()}
  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r], do: tokenize(rest, acc)

  defp tokenize(<<?', rest::binary>>, acc) do
    {content, rest} = take_until(rest, ?', [])
    # InfluxQL escapes a quote with a backslash, SQL by doubling it.
    tokenize(rest, [{:str, String.replace(content, "\\'", "''")} | acc])
  end

  defp tokenize(<<?", rest::binary>>, acc) do
    {name, rest} = take_until(rest, ?", [])
    tokenize(rest, [{:ident, String.replace(name, "\\\"", "\"")} | acc])
  end

  defp tokenize(<<?/, rest::binary>>, [{:op, op} | _tokens] = acc) when op in ["=~", "!~"] do
    {pattern, rest} = take_until(rest, ?/, [])
    tokenize(rest, [{:regex, String.replace(pattern, "\\/", "/")} | acc])
  end

  defp tokenize(<<op::binary-size(2), rest::binary>>, acc)
       when op in ["=~", "!~", "!=", "<>", "<=", ">="],
       do: tokenize(rest, [{:op, op} | acc])

  defp tokenize(<<c, rest::binary>>, acc) when c in [?=, ?<, ?>],
    do: tokenize(rest, [{:op, <<c>>} | acc])

  defp tokenize(<<c, rest::binary>>, acc) when c in [?(, ?), ?+, ?-, ?*, ?/, ?,],
    do: tokenize(rest, [{:raw, <<c>>} | acc])

  defp tokenize(text, acc) do
    case Regex.run(
           ~r/^(?:(\d+)(ns|ms|u|µ|s|m|h|d|w)\b|(\d*\.\d+|\d+)|(now\s*\(\s*\))|([A-Za-z_]\w*))/u,
           text
         ) do
      [full, n, unit] ->
        duration = {:duration, String.to_integer(n) * Map.fetch!(@duration_ns, unit), full}
        tokenize(rest_after(text, full), [duration | acc])

      [full, "", "", number] ->
        case rest_after(text, full) do
          <<c, _more::binary>> = rest
          when c in ?0..?9 or c in ?a..?z or c in ?A..?Z or c in [?_, ?.] ->
            {:parse_error, rest}

          rest ->
            tokenize(rest, [{:number, number} | acc])
        end

      [full, "", "", "", _now] ->
        tokenize(rest_after(text, full), [{:raw, "now()"} | acc])

      [full, "", "", "", "", word] ->
        if String.upcase(word) == "NOT",
          do: {:parse_error, String.trim_leading(rest_after(text, full))},
          else: tokenize(rest_after(text, full), [word_token(word) | acc])

      nil ->
        {:error, "unsupported InfluxQL WHERE: #{text}"}
    end
  end

  @spec rest_after(binary(), binary()) :: binary()
  defp rest_after(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  @spec word_token(binary()) :: tuple()
  defp word_token(word) do
    if String.upcase(word) in ~w(AND OR TRUE FALSE), do: {:raw, word}, else: {:ident, word}
  end

  @spec take_until(binary(), char(), iodata()) :: {binary(), binary()}
  defp take_until(<<?\\, c, rest::binary>>, q, acc), do: take_until(rest, q, [<<?\\, c>> | acc])
  defp take_until(<<q, rest::binary>>, q, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}
  defp take_until(<<c::utf8, rest::binary>>, q, acc), do: take_until(rest, q, [<<c::utf8>> | acc])
  defp take_until(<<>>, _q, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), <<>>}

  # The condition as a tree: `OR` of `AND`s of comparisons and
  # parenthesised conditions, as InfluxQL binds them.
  #
  #     {:or, [node]} | {:and, [node]} | {:group, node} | {:cmp, [token]}
  @spec parse_or(list()) :: {tuple(), list()}
  defp parse_or(tokens) do
    {first, rest} = parse_and(tokens)
    collect(rest, "OR", [first], &parse_and/1, :or)
  end

  @spec parse_and(list()) :: {tuple(), list()}
  defp parse_and(tokens) do
    {first, rest} = parse_atom(tokens)
    collect(rest, "AND", [first], &parse_atom/1, :and)
  end

  defp collect([{:raw, word} | rest], keyword, acc, parse, kind) do
    if String.upcase(word) == keyword do
      {node, rest} = parse.(rest)
      collect(rest, keyword, [node | acc], parse, kind)
    else
      done([{:raw, word} | rest], acc, kind)
    end
  end

  defp collect(rest, _keyword, acc, _parse, kind), do: done(rest, acc, kind)

  defp done(rest, [single], _kind), do: {single, rest}
  defp done(rest, acc, kind), do: {{kind, Enum.reverse(acc)}, rest}

  # A parenthesis opens a condition when it closes before an `AND`, an `OR`
  # or the end and holds a comparison or connective; `(a + b) > 1` is an
  # expression and stays a comparison.
  defp parse_atom([{:raw, "("} | after_paren] = tokens) do
    with {inside, [next | _more] = rest} <- split_group(after_paren, 1, []),
         true <- boundary?(next) and condition?(inside) do
      {node, []} = parse_or(inside)
      {{:group, node}, rest}
    else
      {inside, []} -> if condition?(inside), do: group_to_end(inside), else: comparison(tokens)
      _expression -> comparison(tokens)
    end
  end

  defp parse_atom(tokens), do: comparison(tokens)

  defp group_to_end(inside) do
    {node, []} = parse_or(inside)
    {{:group, node}, []}
  end

  # Tokens up to the closing parenthesis of the group just opened.
  defp split_group([], _depth, _acc), do: :unbalanced

  defp split_group([{:raw, ")"} | rest], 1, acc), do: {Enum.reverse(acc), rest}

  defp split_group([{:raw, ")"} = token | rest], depth, acc),
    do: split_group(rest, depth - 1, [token | acc])

  defp split_group([{:raw, "("} = token | rest], depth, acc),
    do: split_group(rest, depth + 1, [token | acc])

  defp split_group([token | rest], depth, acc), do: split_group(rest, depth, [token | acc])

  defp boundary?({:raw, word}), do: String.upcase(word) in ["AND", "OR", ")"]
  defp boundary?(_token), do: false

  defp condition?(tokens) do
    Enum.any?(tokens, fn
      {:op, _op} -> true
      {:raw, word} -> String.upcase(word) in ["AND", "OR"]
      _token -> false
    end)
  end

  # Tokens up to the next `AND` or `OR` outside parentheses.
  defp comparison(tokens), do: comparison(tokens, 0, [])

  defp comparison([], _depth, acc), do: {{:cmp, Enum.reverse(acc)}, []}

  defp comparison([{:raw, word} = token | rest], 0, acc) do
    if String.upcase(word) in ["AND", "OR"],
      do: {{:cmp, Enum.reverse(acc)}, [token | rest]},
      else: comparison(rest, depth_after(word, 0), [token | acc])
  end

  defp comparison([{:raw, word} = token | rest], depth, acc),
    do: comparison(rest, depth_after(word, depth), [token | acc])

  defp comparison([token | rest], depth, acc), do: comparison(rest, depth, [token | acc])

  defp depth_after("(", depth), do: depth + 1
  defp depth_after(")", depth), do: max(depth - 1, 0)
  defp depth_after(_word, depth), do: depth

  # The tree as SQL, with the lower bounds its `time` comparisons give.
  @spec plan(tuple(), MapSet.t(binary())) :: {binary(), [bound()]}
  defp plan({:cmp, tokens}, tags) do
    if Enum.any?(tokens, &match?({:ident, "time"}, &1)),
      do: time_plan(tokens, tags),
      else: {tokens |> drop_unary_plus([]) |> rewrite(tags, []) |> Enum.join(" "), []}
  end

  defp plan({:group, node}, tags) do
    {sql, lowers} = plan(node, tags)
    {"(" <> sql <> ")", lowers}
  end

  defp plan({:and, nodes}, tags), do: join_plans(nodes, " AND ", tags)

  defp plan({:or, nodes}, tags) do
    if Enum.any?(nodes, &mentions_time_node?/1),
      do: throw({:refused, "unsupported InfluxQL (a time comparison inside OR)"})

    join_plans(nodes, " OR ", tags)
  end

  defp join_plans(nodes, separator, tags) do
    {sqls, lowers} = nodes |> Enum.map(&plan(&1, tags)) |> Enum.unzip()
    {Enum.join(sqls, separator), Enum.concat(lowers)}
  end

  defp mentions_time_node?({:cmp, tokens}), do: Enum.any?(tokens, &match?({:ident, "time"}, &1))
  defp mentions_time_node?({:group, node}), do: mentions_time_node?(node)
  defp mentions_time_node?({_kind, nodes}), do: Enum.any?(nodes, &mentions_time_node?/1)

  # A comparison with `time` on one side and a time on the other.
  @flipped %{"=" => "=", "<" => ">", "<=" => ">=", ">" => "<", ">=" => "<="}

  defp time_plan(tokens, tags) do
    case time_sides(tokens) do
      {op, comparand} -> time_comparison(op, comparand)
      :other -> {tokens |> rewrite(tags, []) |> Enum.join(" "), []}
    end
  end

  defp time_sides([{:ident, "time"}, {:op, op} | comparand]) when comparand != [] do
    if Enum.any?(comparand, &match?({:ident, _name}, &1)),
      do: :other,
      else: {op, comparand}
  end

  defp time_sides(tokens) when length(tokens) > 2 do
    case Enum.split(tokens, -2) do
      {comparand, [{:op, op}, {:ident, "time"}]} ->
        if op in ["=~", "!~"] or Enum.any?(comparand, &match?({:ident, _name}, &1)),
          do: :other,
          else: {Map.get(@flipped, op, op), comparand}

      _other ->
        :other
    end
  end

  defp time_sides(_tokens), do: :other

  defp time_comparison(op, _comparand) when op in ["!=", "<>"] do
    throw(
      {:refused,
       {:engine,
        "rewriting statement\ncaused by\nsplit condition\ncaused by\n" <>
          "Error during planning: invalid time comparison operator: !="}}
    )
  end

  defp time_comparison(op, _comparand) when op not in ["=", "<", "<=", ">", ">="],
    do: throw({:refused, "unsupported InfluxQL (time #{op} ...)"})

  defp time_comparison(op, comparand) do
    case time_value(comparand) do
      {:ns, ns} ->
        {"time #{op} '#{iso_ns(ns)}'", lower(op, ns)}

      {:str, content} ->
        {"time #{op} '#{content}'", lower(op, string_ns(content))}

      {:now, offset, sql} ->
        {"time #{op} #{sql}", lower(op, {:now, offset})}
    end
  end

  # `time >= x` and `time = x` start at x, `time > x` just after it.
  @spec lower(binary(), integer() | {:now, integer()} | nil) :: [bound()]
  defp lower(_op, nil), do: []
  defp lower(op, bound) when op in ["=", ">="], do: [bound]
  defp lower(">", {:now, offset}), do: [{:now, offset + 1}]
  defp lower(">", ns), do: [ns + 1]
  defp lower(_op, _bound), do: []

  # What a time is compared with: a quoted time, `now()` and durations, or
  # a constant of integers and durations in nanoseconds.
  defp time_value([{:str, content}]), do: {:str, content}

  defp time_value([{:raw, "now()"} | terms]) do
    {offset, sql} = now_terms(terms, 0, ["now()"])
    {:now, offset, Enum.join(sql, " ")}
  end

  defp time_value(tokens), do: {:ns, constant(tokens)}

  defp now_terms([], offset, sql), do: {offset, Enum.reverse(sql)}

  defp now_terms([{:raw, sign}, {:duration, ns, text} | rest], offset, sql)
       when sign in ["+", "-"] do
    signed = if sign == "-", do: -ns, else: ns
    now_terms(rest, offset + signed, [duration_sql(ns, text), sign | sql])
  end

  defp now_terms(_terms, _offset, _sql),
    do: throw({:refused, "unsupported InfluxQL (a time compared with now() and something else)"})

  # A duration next to `now()` is an interval in whole seconds, the unit
  # the SQL engine's INTERVAL takes; a finer one is refused by name.
  defp duration_sql(ns, _text) when rem(ns, 1_000_000_000) == 0,
    do: "INTERVAL '#{div(ns, 1_000_000_000)} seconds'"

  defp duration_sql(_ns, text),
    do: throw({:refused, "unsupported InfluxQL (sub-second duration #{text})"})

  # `[-] term [(+|-) term]...` of integers and durations.
  defp constant([{:raw, "-"} | rest]), do: constant_sum(rest, 0, -1)
  defp constant([{:raw, "+"} | rest]), do: constant_sum(rest, 0, 1)
  defp constant(tokens), do: constant_sum(tokens, 0, 1)

  defp constant_sum([term | rest], total, sign) do
    total = total + sign * term_ns(term)

    case rest do
      [] -> total
      [{:raw, "+"} | more] -> constant_sum(more, total, 1)
      [{:raw, "-"} | more] -> constant_sum(more, total, -1)
      _other -> throw({:refused, "unsupported InfluxQL (a time compared with an expression)"})
    end
  end

  defp constant_sum([], _total, _sign),
    do: throw({:refused, "unsupported InfluxQL (a time compared with an expression)"})

  defp term_ns({:duration, ns, _text}), do: ns

  defp term_ns({:number, text}) do
    case Integer.parse(text) do
      {n, ""} -> n
      _float_or_error -> throw({:refused, "unsupported InfluxQL (non-integer time #{text})"})
    end
  end

  defp term_ns(_token),
    do: throw({:refused, "unsupported InfluxQL (a time compared with an expression)"})

  # nanoseconds since the epoch as the nine-digit ISO-8601 time the SQL
  # engine reads exactly; the 64-bit range is the engine's.
  @spec iso_ns(integer()) :: binary()
  defp iso_ns(ns) when ns >= -9_223_372_036_854_775_808 and ns <= 9_223_372_036_854_775_807 do
    seconds = Integer.floor_div(ns, 1_000_000_000)
    nanos = Integer.mod(ns, 1_000_000_000)
    stamp = seconds |> DateTime.from_unix!() |> DateTime.to_iso8601() |> String.trim_trailing("Z")
    "#{stamp}.#{String.pad_leading(Integer.to_string(nanos), 9, "0")}Z"
  end

  defp iso_ns(_ns),
    do: throw({:refused, "unsupported InfluxQL (a time outside 64-bit nanoseconds)"})

  # A quoted time, as the SQL engine reads it.
  @spec string_ns(binary()) :: integer() | nil
  defp string_ns(content) do
    case SQLParser.parse_where(" WHERE time >= '#{content}'") do
      {:ok, [{:gte, "time", ns}]} when is_integer(ns) -> ns
      _unreadable -> nil
    end
  end

  @spec rewrite(list(), MapSet.t(binary()), [binary()]) :: [binary()]
  defp rewrite([], _tags, acc), do: Enum.reverse(acc)

  defp rewrite([{:ident, name}, {:op, op}, {:regex, pattern} | rest], tags, acc) do
    sql =
      if MapSet.member?(tags, name),
        do:
          "#{ident_sql(name)} #{if op == "=~", do: "~", else: "!~"} '#{String.replace(pattern, "'", "''")}'",
        else: always_false(name)

    rewrite(rest, tags, [sql | acc])
  end

  defp rewrite([{:ident, name}, {:op, op}, value | rest], tags, acc)
       when op in ["<", "<=", ">", ">="] do
    if MapSet.member?(tags, name),
      do: rewrite(rest, tags, [always_false(name) | acc]),
      else: rewrite(rest, tags, [token_sql(value), op, ident_sql(name) | acc])
  end

  defp rewrite([token | rest], tags, acc), do: rewrite(rest, tags, [token_sql(token) | acc])

  # InfluxQL reads `+5` as 5; the SQL the double hands on does not read a
  # unary plus. A `+` is unary at the start, after a comparison operator,
  # after an opening parenthesis and after another sign or operator.
  @spec drop_unary_plus(list(), list()) :: list()
  defp drop_unary_plus([], acc), do: Enum.reverse(acc)
  defp drop_unary_plus([{:raw, "+"} | rest], []), do: drop_unary_plus(rest, [])

  defp drop_unary_plus([{:raw, "+"} | rest], [{:op, _op} | _more] = acc),
    do: drop_unary_plus(rest, acc)

  defp drop_unary_plus([{:raw, "+"} | rest], [{:raw, prev} | _more] = acc)
       when prev in ["(", "+", "-", "*", "/"],
       do: drop_unary_plus(rest, acc)

  defp drop_unary_plus([token | rest], acc), do: drop_unary_plus(rest, [token | acc])

  @spec token_sql(tuple()) :: binary()
  defp token_sql({:ident, name}), do: ident_sql(name)
  defp token_sql({:str, content}), do: "'" <> content <> "'"
  defp token_sql({:regex, pattern}), do: "'" <> String.replace(pattern, "'", "''") <> "'"
  defp token_sql({:op, op}), do: op
  defp token_sql({:raw, text}), do: text
  defp token_sql({:number, "." <> _fraction = text}), do: "0" <> text
  defp token_sql({:number, text}), do: text
  defp token_sql({:duration, ns, text}), do: duration_sql(ns, text)

  @spec ident_sql(binary()) :: binary()
  defp ident_sql(name) do
    if Regex.match?(~r/^[A-Za-z_]\w*$/, name), do: name, else: ~s("#{name}")
  end

  # False for every row, in the SQL the caller's engine reads.
  @spec always_false(binary()) :: binary()
  defp always_false(name),
    do: "(#{ident_sql(name)} IS NULL AND #{ident_sql(name)} IS NOT NULL)"

  # ---------------------------------------------------------------------------
  # SHOW TAG VALUES
  # ---------------------------------------------------------------------------

  @show_tag_values ~r/^\s*SHOW\s+TAG\s+VALUES(?:\s+FROM\s+(?<from>"(?:[^"\\]|\\.)+"|[\w\-]+))?\s+WITH\s+KEY\s*(?<op>=~|!~|!=|=|IN\b)\s*(?<spec>.+?)(?:\s+WHERE\s+(?<where>.+?))?\s*;?\s*$/is

  @typedoc "Which tag keys a `SHOW TAG VALUES` lists."
  @type key_filter ::
          {:eq, binary()} | {:ne, binary()} | {:in, [binary()]} | {:regex, Regex.t(), boolean()}

  @doc """
  Parses `SHOW TAG VALUES [FROM m] WITH KEY = k | != k | =~ /re/ | !~ /re/ |
  IN (k, ...) [WHERE ...]`, or `nil` when the statement is not one.
  `LIMIT` and `OFFSET` are refused by name: the engine applies them per
  measurement in an order the double does not reproduce.
  """
  @spec parse_show_tag_values(binary()) ::
          nil
          | {:ok, %{measurement: binary() | nil, keys: key_filter(), where: binary() | nil}}
          | {:error, binary()}
  def parse_show_tag_values(statement) do
    with %{} = captures <- Regex.named_captures(@show_tag_values, statement) do
      if Regex.match?(~r/\b(?:LIMIT|OFFSET)\b/i, captures["where"] <> " " <> captures["spec"]) do
        {:error, "unsupported InfluxQL (SHOW TAG VALUES with LIMIT/OFFSET)"}
      else
        with {:ok, keys} <-
               key_filter(String.upcase(captures["op"]), String.trim(captures["spec"])) do
          {:ok,
           %{
             measurement: captures["from"] |> blank_to_nil() |> then(&(&1 && unquote_ident(&1))),
             keys: keys,
             where: blank_to_nil(captures["where"])
           }}
        end
      end
    end
  end

  @spec key_filter(binary(), binary()) :: {:ok, key_filter()} | {:error, binary()}
  defp key_filter(op, "/" <> _rest = spec) when op in ["=~", "!~"] do
    case Regex.compile(spec |> String.trim("/") |> String.replace("\\/", "/"), "u") do
      {:ok, regex} -> {:ok, {:regex, regex, op == "=~"}}
      {:error, _reason} -> {:error, "unsupported InfluxQL (invalid regex #{spec})"}
    end
  end

  defp key_filter("IN", "(" <> _rest = spec) do
    keys = spec |> String.trim_leading("(") |> String.trim_trailing(")") |> String.split(",")
    {:ok, {:in, Enum.map(keys, &(&1 |> String.trim() |> unquote_ident()))}}
  end

  defp key_filter("=", spec), do: {:ok, {:eq, unquote_ident(spec)}}
  defp key_filter("!=", spec), do: {:ok, {:ne, unquote_ident(spec)}}
  defp key_filter(op, spec), do: {:error, "unsupported InfluxQL (WITH KEY #{op} #{spec})"}

  @doc "Whether a tag key is one a `key_filter/0` lists."
  @spec key_listed?(binary(), key_filter()) :: boolean()
  def key_listed?(key, {:eq, name}), do: key == name
  def key_listed?(key, {:ne, name}), do: key != name
  def key_listed?(key, {:in, names}), do: key in names
  def key_listed?(key, {:regex, regex, match?}), do: Regex.match?(regex, key) == match?

  @doc "Whether a `WHERE` names `time`: then it, not the default window, bounds the rows."
  @spec mentions_time?(binary() | nil) :: boolean()
  def mentions_time?(nil), do: false

  def mentions_time?(where) do
    case tokenize(where, []) do
      {:ok, tokens} -> Enum.any?(tokens, &match?({:ident, "time"}, &1))
      _not_or_refusal -> false
    end
  end

  @spec parse_items(binary()) :: {:ok, [item()]} | {:error, binary()}
  defp parse_items(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while({:ok, []}, fn text, {:ok, acc} ->
      case parse_item(text) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  @spec parse_item(binary()) :: {:ok, item()} | {:error, binary()}
  defp parse_item("*"), do: {:ok, :star}

  defp parse_item(text) do
    cond do
      captures = Regex.named_captures(@function, text) ->
        function_item(captures, text)

      captures = Regex.named_captures(@column, text) ->
        column = unquote_ident(captures["col"])
        {:ok, {:column, column, alias_or(captures["alias"], column)}}

      true ->
        {:error, "unsupported select item: #{text}"}
    end
  end

  @spec function_item(map(), binary()) :: {:ok, item()} | {:error, binary()}
  defp function_item(%{"fn" => fun, "arg" => arg, "alias" => alias}, text) do
    fun = String.downcase(fun)

    cond do
      fun not in @aggregates -> {:error, "unsupported InfluxQL function: #{text}"}
      arg == "*" and fun != "count" -> {:error, "unsupported InfluxQL (#{fun}(*))"}
      arg == "*" -> {:ok, {:aggregate, fun, :star, nil}}
      true -> {:ok, {:aggregate, fun, unquote_ident(arg), blank_to_nil(unquote_ident(alias))}}
    end
  end

  # Plain columns beside aggregates take their values from the selected
  # point, so only a single selector can carry them.
  @spec check_mix([item()]) :: :ok | {:error, binary()}
  defp check_mix(items) do
    aggregates = for {:aggregate, _fn, _arg, _alias} = item <- items, do: item
    plain = Enum.reject(items, &match?({:aggregate, _fn, _arg, _alias}, &1))

    case {aggregates, plain} do
      {[], _plain} ->
        :ok

      {_aggregates, []} ->
        :ok

      {[{:aggregate, fun, arg, _alias}], _plain} when fun in @selectors and arg != :star ->
        :ok

      _mixed ->
        {:error, "unsupported InfluxQL (columns beside aggregates other than one selector)"}
    end
  end

  @spec parse_group(binary()) :: [binary()]
  defp parse_group(""), do: []

  defp parse_group(text) do
    text |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> unquote_ident()))
  end

  @spec unquote_ident(binary()) :: binary()
  defp unquote_ident("\"" <> _rest = quoted),
    do: quoted |> String.trim("\"") |> String.replace("\\\"", "\"")

  defp unquote_ident(ident), do: ident

  @spec alias_or(binary(), binary()) :: binary()
  defp alias_or("", column), do: column
  defp alias_or(alias, _column), do: unquote_ident(alias)

  @spec blank_to_nil(binary()) :: binary() | nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: String.trim(text)

  @spec to_int(binary()) :: non_neg_integer() | nil
  defp to_int(""), do: nil
  defp to_int(digits), do: String.to_integer(digits)

  @spec take([map()], non_neg_integer() | nil) :: [map()]
  defp take(rows, nil), do: rows
  defp take(rows, limit), do: Enum.take(rows, limit)
end
