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

  A reserved word (`reserved?/1`) is no bare identifier: the engine's parse
  errors for it, and for a select list, `FROM`, `WHERE`, `GROUP BY`,
  `ORDER BY`, `LIMIT` or a statement after a `;` that stops short, are
  positioned in the text as sent and read with the statement's own offset. A
  field is compared with a literal by the types of the two (`b = 1` is false
  for every row, `u > -1` wraps the `-1`, an integer past the signed range
  compares as unsigned), `LIMIT` and `OFFSET` beyond the signed 64-bit range
  are the planning error and beyond the unsigned a parse error.

  Refused by name, rather than answered wrongly: `GROUP BY time(...)` (the
  engine fills every empty bucket), `fill()`, `INTO`, `SLIMIT`/`SOFFSET`,
  subqueries, `GROUP BY *`, functions other than
  `MEAN SUM COUNT MIN MAX FIRST LAST`, `F(*)` other than `COUNT(*)`, plain
  columns beside anything but a single selector, arithmetic in the select
  list, several measurements in `FROM`, sub-second durations in `now() -
  ...`, `LIMIT` / `OFFSET` on `SHOW TAG VALUES`, an unsigned field
  compared with a string, a string field or a tag compared with an integer
  past the signed range, a field compared with a constant the double cannot
  fold, a bare non-boolean field inside `AND` / `OR`, `DISTINCT`, and a
  statement after a `;` that the double does not read. A keyword inside a
  quoted string, quoted identifier or regular expression is not one:
  `WHERE k = 'into'` is answered.
  """

  alias InfluxElixir.Client.Local.{SQLMask, SQLParser}

  @epoch DateTime.from_unix!(0, :microsecond)

  @max_unsigned 18_446_744_073_709_551_615
  @max_signed 9_223_372_036_854_775_807

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

  @rest ~r/^\s*(?:WHERE\s+(?<where>.+?))?\s*(?:GROUP\s+BY\s+(?<group>.+?))?\s*(?:ORDER\s+BY\s+(?:time\s+(?=ASC|DESC)|(?=ASC\b|DESC\b)|time\b)(?<dir>ASC|DESC)?)?\s*(?:LIMIT\s+(?<limit>\d+))?\s*(?:OFFSET\s+(?<offset>\d+))?\s*;?\s*$/is

  @function ~r/^(?<fn>[A-Za-z_]\w*)\s*\(\s*(?<arg>\*|"[^"]+"|[\w.]+)\s*\)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is
  @column ~r/^(?<col>"[^"]+"|[\w.]+)(?:\s+AS\s+(?<alias>"[^"]+"|\w+))?$/is

  @doc """
  Parses an InfluxQL `SELECT`. Returns `{:error, message}` for syntax the
  engine rejects and for the constructs listed in the moduledoc.
  """
  @spec parse(binary()) :: {:ok, query()} | {:error, binary() | {:engine, binary()}}
  def parse(statement) do
    {clean, masked} = blank_comments(statement, mask_literals(statement))
    {head, masked_head, tail} = split_statement(clean, masked)

    with :ok <- check_supported(masked_head),
         :ok <- check_select(clean, masked_head),
         %{"items" => items, "from" => from, "rest" => rest} <-
           slices(@select, masked_head, head) || {:error, "invalid statement"},
         %{"rest" => masked_rest} = slices(@select, masked_head, masked_head),
         at = byte_size(head) - byte_size(rest),
         :ok <- check_empty_where(clean, at, masked_rest),
         %{} = clauses <- slices(@rest, masked_rest, rest) || {:error, "invalid clauses"},
         {where, swallowed} = cut_where(masked_rest, clauses["where"]),
         :ok <- check_where(clean, at, masked_rest, where),
         :ok <- check_group(clean, at, masked_rest),
         :ok <- check_swallowed(clean, at, masked_rest, swallowed),
         :ok <- check_unsigned(clean, at, masked_rest),
         {:ok, items} <- parse_items(items),
         :ok <- check_mix(items),
         :ok <- check_single(statement, tail) do
      {:ok,
       %{
         items: items,
         measurement: unquote_ident(from),
         where: where,
         group_by: parse_group(clauses["group"]),
         descending: String.upcase(clauses["dir"]) == "DESC",
         limit: to_int(clauses["limit"]),
         offset: to_int(clauses["offset"]) || 0
       }}
    end
  end

  # A `--` outside a literal comments out the rest of its line. The comment
  # becomes spaces, byte for byte, in the statement and its mask, so every
  # offset stays the engine's.
  @spec blank_comments(binary(), binary()) :: {binary(), binary()}
  defp blank_comments(statement, masked) do
    comments = ~r/--[^\n]*/ |> Regex.scan(masked, return: :index) |> List.flatten()
    {Enum.reduce(comments, statement, &blank/2), Enum.reduce(comments, masked, &blank/2)}
  end

  @spec blank({non_neg_integer(), non_neg_integer()}, binary()) :: binary()
  defp blank({from, length}, text) do
    <<before::binary-size(from), _comment::binary-size(length), rest::binary>> = text
    before <> String.duplicate(" ", length) <> rest
  end

  # The statement up to its first `;` outside a literal, with its mask, and
  # the offset just after the `;` (`nil` without one).
  @spec split_statement(binary(), binary()) ::
          {binary(), binary(), non_neg_integer() | nil}
  defp split_statement(clean, masked) do
    case :binary.match(masked, ";") do
      {at, 1} ->
        {binary_part(clean, 0, at), binary_part(masked, 0, at), at + 1}

      :nomatch ->
        {clean, masked, nil}
    end
  end

  # What follows a statement's `;` is another statement or nothing. The
  # engine takes one statement per query (verified): a second that reads is
  # "only one InfluxQl statement per query", and what does not read is its
  # own parse error at the position it starts, the rest of the text shown.
  # Repeated `;` and whitespace between are skipped.
  @spec check_single(binary(), non_neg_integer() | nil) :: :ok | {:error, term()}
  defp check_single(_statement, nil), do: :ok

  defp check_single(statement, after_semicolon) do
    rest = binary_part(statement, after_semicolon, byte_size(statement) - after_semicolon)
    {clean_rest, _masked} = blank_comments(rest, mask_literals(rest))
    [skipped] = Regex.run(~r/^[\s;]*/, clean_rest)
    start = after_semicolon + byte_size(skipped)

    case binary_part(statement, start, byte_size(statement) - start) do
      "" -> :ok
      next -> next_statement_error(statement, next, start)
    end
  end

  @only_one "must provide only one InfluxQl statement per query"
  @other_statements ~r/^SHOW\s+(?:DATABASES|MEASUREMENTS|TAG\s+(?:KEYS|VALUES)|FIELD\s+KEYS)\b/i

  # Statements the engine reads in ways the double does not follow; any
  # other text is not a statement at all, and the engine fails it where it
  # starts (verified).
  @known_statements ~r/^(?:(?:SELECT|SHOW|EXPLAIN|CREATE|DELETE)(?![\w])|DROP(?![\w])\s*\S)/i

  @spec next_statement_error(binary(), binary(), non_neg_integer()) :: {:error, term()}
  defp next_statement_error(statement, next, start) do
    case parse(next) do
      {:ok, _query} ->
        {:error, {:engine, @only_one}}

      {:error, {:engine, body}} ->
        {:error, {:engine, shift_position(body, start)}}

      {:error, "unsupported" <> _rest} = refusal ->
        refusal

      {:error, message} ->
        cond do
          Regex.match?(@other_statements, next) ->
            {:error, {:engine, @only_one}}

          Regex.match?(@known_statements, next) ->
            {:error, "#{message} (in a statement after `;`)"}

          true ->
            {:error, {:engine, syntax_error_body(:nom, start, statement)}}
        end
    end
  end

  @spec shift_position(binary(), non_neg_integer()) :: binary()
  defp shift_position(body, by) do
    Regex.replace(~r/at pos (\d+)/, body, fn _match, pos ->
      "at pos #{String.to_integer(pos) + by}"
    end)
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

  # The rows of each `GROUP BY` series, in order of the tag values by tag
  # key (verified: `GROUP BY r, h` orders as `GROUP BY h, r`); the
  # rows keep the time order they came in (the grouping is stable). Without
  # a `GROUP BY` there is one series and no pass to group it.
  @spec series_groups(query(), [map()]) :: [{map(), [map()]}]
  defp series_groups(%{group_by: []}, []), do: []
  defp series_groups(%{group_by: []}, rows), do: [{%{}, rows}]

  defp series_groups(%{group_by: group_by}, rows) do
    keys = Enum.sort(group_by)

    rows
    |> Enum.group_by(&Map.take(&1, keys))
    |> Enum.sort_by(fn {key, _rows} -> Enum.map(keys, &series_sort_key(key, &1)) end)
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
  @type where_plan :: %{
          sql: binary(),
          lowers: [bound()],
          idents: MapSet.t(binary()),
          deferred: binary() | nil
        }

  @doc """
  Rewrites an InfluxQL `WHERE` into the caller's SQL, given the
  measurement's tag columns, with the column names the `WHERE` mentions and
  the lower bounds it puts on `time`:
  `time >= x` and `time = x` give `x`, `time > x` gives `x + 1`, upper
  bounds give none. An aggregate over a lower bound is stamped with the
  greatest of them (`run/4`). `types` maps each field to its type: a
  comparison of a field with a literal follows the engine's rules for the
  two types (see the section on typed comparisons). `deferred` is the engine's
  error for a bare field as the whole condition, which it raises after it has
  checked `LIMIT` and `OFFSET`. `{:error, message}` for what the double
  refuses by name; `{:error, {:engine, body}}` for what the engine itself
  answers with a 400.
  """
  @spec where_plan(binary(), MapSet.t(binary()), %{binary() => field_type()}) ::
          {:ok, where_plan()} | {:error, binary() | {:engine, binary()}}
  def where_plan(where, tags, types \\ %{}) do
    case tokenize(where, []) do
      {:ok, tokens} ->
        {tree, _rest} = parse_or(tokens)
        ctx = {tags, types}
        deferred = bare_condition(tree, ctx)
        {sql, lowers} = if deferred, do: {"true", []}, else: plan(tree, ctx)
        idents = for {:ident, name} <- tokens, into: MapSet.new(), do: name
        {:ok, %{sql: sql, lowers: lowers, idents: idents, deferred: deferred}}

      {:syntax_error, _kind, rest} ->
        {:error, "unsupported InfluxQL WHERE: #{rest}"}

      {:error, _message} = error ->
        error
    end
  catch
    {:refused, message} -> {:error, message}
  end

  # What the engine's parser cannot read in the `WHERE` fails the statement
  # where it stands (verified), naming the position (from the
  # start of the statement) and, for a statement it cannot continue, the
  # rest of the statement, `;` and later clauses included:
  #
  #   * `NOT` is no InfluxQL keyword (the position is the operand after it);
  #     a number is `\d*\.\d+` or `\d+` only, so an exponent, a trailing dot,
  #     a hex or an underscore leaves the rest of the literal behind (the
  #     position is where that begins)
  #   * a comparison or `AND` / `OR` with no operand after it, or one that
  #     cannot start an operand (a lone dot, `)`, a connective), is an
  #     invalid conditional expression at the end of the operator
  #   * an integer beyond the unsigned 64-bit range, or a negative one
  #     beyond the signed range, is an overflow at the end of its digits; a
  #     duration whose count only fits the unsigned range leaves its unit
  #     behind
  #
  # A reserved word (`reserved?/1`) where an operand is expected is an error
  # whose shape depends on what stands before it (verified): at the start of
  # the condition the whole `WHERE` is left unparsed (the error is at the
  # `WHERE`); after a comparison or a connective it is the missing operand
  # (at the end of the operator, sign and parenthesis skipped); after `*` or
  # `/` the operator is what cannot be read; after a binary `+` or `-` the
  # engine fails from the word on, at position 0; after an operand it is the
  # word itself. A `WHERE` with nothing after it is unparsed like the first.
  # A clause keyword inside what the clause regex took for the `WHERE` means
  # the clause after it is malformed: the condition ends there, and that
  # clause is what the engine reads next.
  @clause_keyword ~r/\b(?:GROUP|ORDER|LIMIT|OFFSET)\b/i

  @spec cut_where(binary(), binary()) :: {binary() | nil, {non_neg_integer()} | nil}
  defp cut_where(masked_rest, raw_where) do
    indexes = Regex.named_captures(@rest, masked_rest, return: :index)

    case swallowed(masked_rest, indexes["where"]) do
      {at, from} -> {blank_to_nil(binary_part(raw_where, 0, at)), {from}}
      nil -> {blank_to_nil(raw_where), swallowed_in_group(masked_rest, indexes["group"])}
    end
  end

  defp swallowed_in_group(masked_rest, index) do
    case swallowed(masked_rest, index) do
      {_at, from} -> {from}
      nil -> nil
    end
  end

  # Where a clause keyword stands inside a clause's text (not at its start):
  # `{offset in the text, offset in the rest}`.
  defp swallowed(_masked_rest, {from, _length}) when from < 0, do: nil
  defp swallowed(_masked_rest, nil), do: nil

  defp swallowed(masked_rest, {from, length}) do
    case Regex.run(@clause_keyword, binary_part(masked_rest, from, length), return: :index) do
      [{at, _size}] when at > 0 ->
        if completes_operand?(masked_rest, from, at), do: {at, from + at}

      _none_or_start ->
        nil
    end
  end

  # A clause keyword ends the condition only after a complete operand; after
  # an operator or a connective it is a reserved word where one is wanted.
  @spec completes_operand?(binary(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp completes_operand?(masked_rest, from, at),
    do: not (binary_part(masked_rest, from, at) =~ ~r/(?:[-+*\/=<>(,~!]|\b(?:AND|OR))\s*$/i)

  @spec check_swallowed(binary(), non_neg_integer(), binary(), {non_neg_integer()} | nil) ::
          :ok | {:error, term()}
  defp check_swallowed(_whole, _at, _masked_rest, nil), do: :ok

  defp check_swallowed(whole, at, masked_rest, {from}) do
    text = binary_part(masked_rest, from, byte_size(masked_rest) - from)
    start = at + from

    cond do
      text =~ ~r/^ORDER\s+BY/i -> check_order(text, start, whole)
      text =~ ~r/^(?:LIMIT|OFFSET)(?![\w])/i -> check_count(text, start, whole)
      text =~ ~r/^GROUP(?![\w])/i -> check_group_keyword(text, start, whole)
      text =~ ~r/^ORDER(?![\w])/i -> {:error, {:engine, syntax_error_body(:nom, start, whole)}}
      true -> {:error, "invalid clauses"}
    end
  end

  # `ORDER BY` takes `time`, `ASC` or `DESC`: another name is "expected TIME
  # column", where it starts; a reserved word or a number "expected ASC, DESC
  # or TIME", at the end of `BY`.
  @spec check_order(binary(), non_neg_integer(), binary()) :: {:error, term()}
  defp check_order(text, start, whole) do
    [{_at, size}, {_blank, blank}] = Regex.run(~r/^ORDER\s+BY(\s*)/i, text, return: :index)
    after_by = binary_part(text, size, byte_size(text) - size)

    cond do
      after_by =~ ~r/^(?:time|asc|desc)(?![\w])/i ->
        {:error, "invalid clauses"}

      reserved_start(after_by) == nil and after_by =~ ~r/^[A-Za-z_]/ ->
        {:error, {:engine, syntax_error_body(:order_time, start + size, whole)}}

      true ->
        {:error, {:engine, syntax_error_body(:order, start + size - blank, whole)}}
    end
  end

  # `LIMIT` and `OFFSET` take an unsigned integer: anything else after it is "expected
  # unsigned integer", where it starts; nothing leaves the clause unparsed.
  @spec check_count(binary(), non_neg_integer(), binary()) :: {:error, term()}
  defp check_count(text, start, whole) do
    [_all, {word, _word_size}, {at, _blank}, {_rest_at, rest_size}] =
      Regex.run(~r/^(LIMIT|OFFSET)\s*()(.*)$/is, text, return: :index)

    kind = if text |> binary_part(word, 1) |> String.upcase() == "L", do: :limit, else: :offset

    cond do
      rest_size == 0 -> {:error, {:engine, syntax_error_body(:nom, start, whole)}}
      binary_part(text, at, 1) =~ ~r/\d/ -> {:error, "invalid clauses"}
      true -> {:error, {:engine, syntax_error_body(kind, start + at, whole)}}
    end
  end

  # `GROUP` must be followed by `BY`; `GROUP BY` and nothing is unparsed.
  @spec check_group_keyword(binary(), non_neg_integer(), binary()) :: {:error, term()}
  defp check_group_keyword(text, start, whole) do
    cond do
      text =~ ~r/^GROUP\s+BY\s*$/i ->
        {:error, {:engine, syntax_error_body(:nom, start, whole)}}

      text =~ ~r/^GROUP\s+BY(?![\w])/i ->
        {:error, "invalid clauses"}

      true ->
        [{_at, size}] = Regex.run(~r/^GROUP\s*/i, text, return: :index)
        {:error, {:engine, syntax_error_body(:group_by, start + size, whole)}}
    end
  end

  @spec check_empty_where(binary(), non_neg_integer(), binary()) ::
          :ok | {:error, {:engine, binary()}}
  defp check_empty_where(whole, at, masked_rest) do
    case Regex.run(~r/^(\s*)WHERE\s*$/i, masked_rest, return: :index) do
      [_all, {_from, blank}] -> {:error, {:engine, syntax_error_body(:nom, at + blank, whole)}}
      nil -> :ok
    end
  end

  @spec check_where(binary(), non_neg_integer(), binary(), binary() | nil) ::
          :ok | {:error, {:engine, binary()}}
  defp check_where(_whole, _at, _masked_rest, nil), do: :ok

  defp check_where(whole, at, masked_rest, where) do
    case tokenize(where, []) do
      {:syntax_error, kind, after_error} ->
        [{from, length}] = Regex.run(~r/\bWHERE\s+/i, masked_rest, return: :index)
        pos = at + from + length + byte_size(where) - byte_size(after_error)
        {:error, {:engine, where_error_body(kind, pos, at + from, whole)}}

      _tokens_or_refusal ->
        :ok
    end
  end

  @spec where_error_body(atom(), non_neg_integer(), non_neg_integer(), binary()) :: binary()
  defp where_error_body(:where_unparsed, _pos, where_at, whole),
    do: syntax_error_body(:nom, where_at, whole)

  defp where_error_body(:reserved_operand, pos, _where_at, whole),
    do: syntax_error_body(:operand, before_operand(whole, pos), whole)

  defp where_error_body(:reserved_operator, pos, _where_at, whole),
    do: syntax_error_body(:nom, before_operand(whole, pos) - 1, whole)

  defp where_error_body(:reserved_failure, pos, _where_at, whole),
    do: syntax_error_body(:failure, pos, whole)

  defp where_error_body(kind, pos, _where_at, whole), do: syntax_error_body(kind, pos, whole)

  # The end of the operator before the operand that starts at `pos`:
  # whitespace, opening parentheses and unary signs between them are skipped.
  @spec before_operand(binary(), non_neg_integer()) :: non_neg_integer()
  defp before_operand(whole, pos) do
    skipped = whole |> binary_part(0, pos) |> String.reverse()
    [spaces] = Regex.run(~r/^[\s(+\-]*/, skipped)
    pos - byte_size(spaces)
  end

  # ---------------------------------------------------------------------------
  # Reserved words
  #
  # InfluxQL takes a reserved word as an identifier only quoted. The list is
  # the engine's (probed one word at a time: each is refused as a bare
  # identifier in the select list, `WHERE` and `GROUP BY`); `fill`, `nan`,
  # `not`, `now`, `null`, `time`, `true` and `false` are not reserved.
  # ---------------------------------------------------------------------------

  @reserved ~w(
    all alter analyze and any as asc begin by cardinality continuous create database
    databases default delete desc destinations diagnostics distinct drop duration end every
    exact explain field for from grant grants group groups in inf insert into key keys kill
    limit measurement measurements name offset on or order password policies policy
    privileges queries query read replication resample retention revoke select series set
    shard shards show slimit soffset stats subscription subscriptions tag to user users
    values where with write
  )

  @doc "Whether a bare word is one InfluxQL reserves (any case)."
  @spec reserved?(binary()) :: boolean()
  def reserved?(word), do: String.downcase(word) in @reserved

  # The reserved word a text starts with, as `{word, length}`, unless a `::`
  # follows (a cast, which the engine reads) or, with `plain: true`, a `(`
  # (a call).
  @spec reserved_start(binary(), keyword()) :: {binary(), non_neg_integer()} | nil
  defp reserved_start(text, opts \\ []) do
    with [_all, word] <- Regex.run(~r/^([A-Za-z_]\w*)(?![\w:])/, text),
         true <- reserved?(word),
         false <- Keyword.get(opts, :plain, false) and called?(text, word) do
      {word, byte_size(word)}
    else
      _other -> nil
    end
  end

  @spec called?(binary(), binary()) :: boolean()
  defp called?(text, word),
    do:
      text
      |> binary_part(byte_size(word), byte_size(text) - byte_size(word))
      |> then(&(&1 =~ ~r/^\s*\(/))

  # The select list and `FROM`, as the engine's parser reads them (verified):
  #
  #   * a select list that is empty or starts with a reserved word is
  #     "expected field" where the list starts
  #   * a later item that starts with a reserved word leaves the whole
  #     statement unparsed (position 0); a reserved word first in a function's
  #     argument fails from there, at position 0
  #   * an alias after `AS` that is reserved is "invalid field alias", at the
  #     end of `AS`; a lone `DISTINCT` is "invalid DISTINCT expression", at
  #     `FROM`
  #   * `FROM` followed by nothing, by a reserved word or by a character that
  #     starts no identifier is "invalid FROM clause", where the name starts
  @spec check_select(binary(), binary()) :: :ok | {:error, term()}
  defp check_select(whole, masked) do
    with [{0, items_at}] <- Regex.run(~r/^\s*SELECT(?![\w])\s*/i, masked, return: :index),
         rest = binary_part(masked, items_at, byte_size(masked) - items_at),
         false <- rest == "" or reserved_item?(rest),
         [{from_at, from_length}] <- from_keyword(masked, items_at) || :no_from do
      items = binary_part(masked, items_at, from_at - items_at)
      from_end = from_at + from_length

      with :ok <- check_items(whole, items, items_at, from_at + 1),
           do: check_from(masked, from_end)
    else
      true ->
        {:error, {:engine, syntax_error_body(:field, items_at_of(masked), whole)}}

      :no_from ->
        {:error, {:engine, syntax_error_body(:nom, 0, whole)}}

      _no_select_or_from ->
        :ok
    end
  end

  # `DISTINCT` is read by the select list, not refused as a reserved word.
  @spec reserved_item?(binary()) :: boolean()
  defp reserved_item?(text) do
    case reserved_start(text) do
      {word, _size} -> String.downcase(word) != "distinct"
      nil -> false
    end
  end

  @spec items_at_of(binary()) :: non_neg_integer()
  defp items_at_of(masked) do
    [{0, at}] = Regex.run(~r/^\s*SELECT(?![\w])\s*/i, masked, return: :index)
    at
  end

  @spec from_keyword(binary(), non_neg_integer()) ::
          [{non_neg_integer(), non_neg_integer()}] | nil
  defp from_keyword(masked, items_at) do
    case Regex.run(~r/\sFROM(?![\w])\s*/i, masked, return: :index, offset: items_at) do
      [{at, length}] -> [{at, length}]
      nil -> nil
    end
  end

  @spec check_from(binary(), non_neg_integer()) :: :ok | {:error, term()}
  defp check_from(masked, from_end) do
    rest = binary_part(masked, from_end, byte_size(masked) - from_end)

    if rest == "" or reserved_start(rest) != nil or not (rest =~ ~r/^[A-Za-z_"\/(]/),
      do: {:error, {:engine, syntax_error_body(:from, from_end, masked)}},
      else: :ok
  end

  # The comma-separated pieces of a text, each with its offset in the statement.
  @spec comma_pieces(binary(), non_neg_integer()) :: [{binary(), non_neg_integer()}]
  defp comma_pieces(text, base) do
    text
    |> String.split(",")
    |> Enum.map_reduce(base, &{{&1, &2}, &2 + byte_size(&1) + 1})
    |> elem(0)
  end

  @spec check_items(binary(), binary(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp check_items(whole, items, items_at, from_keyword_at) do
    pieces = comma_pieces(items, items_at)
    last = length(pieces) - 1

    pieces
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {{piece, at}, index} ->
      case check_item(whole, piece, at, index, index == last, from_keyword_at) do
        :ok -> nil
        error -> error
      end
    end)
  end

  @spec check_item(
          binary(),
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          non_neg_integer()
        ) ::
          :ok | {:error, term()}
  defp check_item(whole, piece, at, index, last?, from_keyword_at) do
    text = String.trim_leading(piece)
    start = at + byte_size(piece) - byte_size(text)
    text = String.trim_trailing(text)

    cond do
      String.downcase(text) == "distinct" and last? ->
        {:error, {:engine, syntax_error_body(:distinct, from_keyword_at, whole)}}

      String.downcase(text) == "distinct" ->
        {:error, "unsupported InfluxQL (DISTINCT)"}

      index > 0 and (text == "" or reserved_start(text, plain: true) != nil) ->
        {:error, {:engine, syntax_error_body(:nom, 0, whole)}}

      pos = reserved_argument(text, start) ->
        {:error, {:engine, syntax_error_body(:failure, pos, whole)}}

      pos = reserved_alias(text, start) ->
        {:error, {:engine, syntax_error_body(:alias, pos, whole)}}

      true ->
        :ok
    end
  end

  # Where a reserved word is the first thing in a call's parentheses.
  @spec reserved_argument(binary(), non_neg_integer()) :: non_neg_integer() | nil
  defp reserved_argument(text, start) do
    with [_all, {from, _length}] <-
           Regex.run(~r/^[A-Za-z_]\w*\s*\(\s*([A-Za-z_]\w*)/, text, return: :index),
         <<_skip::binary-size(from), word_and_rest::binary>> = text,
         {_word, _size} <- reserved_start(word_and_rest) do
      start + from
    else
      _not_reserved -> nil
    end
  end

  # The end of `AS` when the alias after it is reserved.
  @spec reserved_alias(binary(), non_neg_integer()) :: non_neg_integer() | nil
  defp reserved_alias(text, start) do
    case Regex.run(~r/\s(AS)(?![\w])\s*([A-Za-z_]\w*)/i, text, return: :index) do
      [_all, {as_at, as_length}, {alias_at, _length}] ->
        <<_skip::binary-size(alias_at), alias_and_rest::binary>> = text
        if reserved_start(alias_and_rest), do: start + as_at + as_length

      nil ->
        last_as(text, start)
    end
  end

  # An `AS` last in the list: the word after it was cut off as `FROM`.
  @spec last_as(binary(), non_neg_integer()) :: non_neg_integer() | nil
  defp last_as(text, start) do
    case Regex.run(~r/\s(AS)(?![\w])\s*$/i, text, return: :index) do
      [_all, {as_at, as_length}] -> start + as_at + as_length
      nil -> nil
    end
  end

  # `GROUP BY`: a first dimension that is a reserved word is "invalid GROUP BY
  # clause" where it starts; a later one leaves the list from the comma before
  # it unparsed.
  @spec check_group(binary(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  defp check_group(whole, at, masked_rest) do
    case Regex.named_captures(@rest, masked_rest, return: :index) do
      %{"group" => {from, length}} when from >= 0 ->
        masked_rest
        |> binary_part(from, length)
        |> comma_pieces(at + from)
        |> Enum.with_index()
        |> Enum.find_value(:ok, &group_dimension(&1, whole))

      _no_group ->
        :ok
    end
  end

  @spec group_dimension({{binary(), non_neg_integer()}, non_neg_integer()}, binary()) ::
          {:error, term()} | nil
  defp group_dimension({{piece, at}, index}, whole) do
    text = String.trim_leading(piece)
    start = at + byte_size(piece) - byte_size(text)

    cond do
      reserved_start(text) == nil -> nil
      index == 0 -> {:error, {:engine, syntax_error_body(:group, start, whole)}}
      true -> {:error, {:engine, syntax_error_body(:nom, at - 1, whole)}}
    end
  end

  # `LIMIT` and `OFFSET` are unsigned 64-bit integers; a longer number is a
  # parse error at the end of its digits. One that fits but not the signed
  # range is a planning error (`check_window/1`).
  @spec check_unsigned(binary(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  defp check_unsigned(whole, at, masked_rest) do
    indexes = Regex.named_captures(@rest, masked_rest, return: :index)

    Enum.find_value(["limit", "offset"], :ok, fn clause ->
      with {from, length} when from >= 0 <- indexes[clause],
           digits = binary_part(masked_rest, from, length),
           true <- String.to_integer(digits) > @max_unsigned do
        {:error, {:engine, syntax_error_body(:unsigned, at + from + length, whole)}}
      else
        _fits -> nil
      end
    end)
  end

  @doc """
  The engine's planning error for a `LIMIT` or `OFFSET` beyond the signed
  64-bit range (`LIMIT` first), or `:ok`. It is raised only for a measurement
  that exists.
  """
  @spec check_window(query()) :: :ok | {:error, {:engine, binary()}}
  def check_window(%{limit: limit, offset: offset}) do
    cond do
      is_integer(limit) and limit > @max_signed ->
        {:error, {:engine, "Error during planning: limit out of range"}}

      offset > @max_signed ->
        {:error, {:engine, "Error during planning: offset out of range"}}

      true ->
        :ok
    end
  end

  @engine_error_prefix "error in InfluxQL statement: parsing error: "

  @spec syntax_error_body(atom(), non_neg_integer(), binary()) :: binary()
  defp syntax_error_body(:nom, pos, whole) do
    leftover = binary_part(whole, pos, byte_size(whole) - pos)

    @engine_error_prefix <>
      "invalid InfluxQL statement at pos #{pos}. Parsing Error: Nom(#{inspect(leftover)}, Tag)"
  end

  defp syntax_error_body(:operand, pos, _whole),
    do: @engine_error_prefix <> "invalid conditional expression at pos #{pos}"

  defp syntax_error_body(:regex, pos, _whole),
    do: @engine_error_prefix <> "invalid conditional, expected regular expression at pos #{pos}"

  defp syntax_error_body(:overflow, pos, _whole),
    do: @engine_error_prefix <> "unable to parse integer due to overflow at pos #{pos}"

  defp syntax_error_body(:signed_overflow, pos, _whole),
    do: @engine_error_prefix <> "constant overflows signed integer at pos #{pos}"

  defp syntax_error_body(:field, pos, _whole),
    do: @engine_error_prefix <> "invalid SELECT statement, expected field at pos #{pos}"

  defp syntax_error_body(:from, pos, _whole) do
    @engine_error_prefix <>
      "invalid FROM clause, expected identifier, regular expression or subquery at pos #{pos}"
  end

  defp syntax_error_body(:alias, pos, _whole),
    do: @engine_error_prefix <> "invalid field alias, expected identifier at pos #{pos}"

  defp syntax_error_body(:group, pos, _whole) do
    @engine_error_prefix <>
      "invalid GROUP BY clause, expected wildcard, TIME, identifier or regular expression " <>
      "at pos #{pos}"
  end

  defp syntax_error_body(:order, pos, _whole),
    do: @engine_error_prefix <> "invalid ORDER BY, expected ASC, DESC or TIME at pos #{pos}"

  defp syntax_error_body(:order_time, pos, _whole),
    do: @engine_error_prefix <> "invalid ORDER BY, expected TIME column at pos #{pos}"

  defp syntax_error_body(:limit, pos, _whole),
    do: @engine_error_prefix <> "invalid LIMIT clause, expected unsigned integer at pos #{pos}"

  defp syntax_error_body(:offset, pos, _whole),
    do: @engine_error_prefix <> "invalid OFFSET clause, expected unsigned integer at pos #{pos}"

  defp syntax_error_body(:group_by, pos, _whole),
    do: @engine_error_prefix <> "invalid GROUP BY clause, expected BY at pos #{pos}"

  defp syntax_error_body(:distinct, pos, _whole),
    do: @engine_error_prefix <> "invalid DISTINCT expression, expected identifier at pos #{pos}"

  defp syntax_error_body(:unsigned, pos, _whole),
    do: @engine_error_prefix <> "unable to parse unsigned integer at pos #{pos}"

  defp syntax_error_body(:failure, pos, whole) do
    leftover = binary_part(whole, pos, byte_size(whole) - pos)

    @engine_error_prefix <>
      "invalid InfluxQL statement at pos 0. Parsing Failure: Nom(#{inspect(leftover)}, Char)"
  end

  @spec tokenize(binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
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
       do: operand(rest, {:op, op}, acc)

  defp tokenize(<<c, rest::binary>>, acc) when c in [?=, ?<, ?>],
    do: operand(rest, {:op, <<c>>}, acc)

  defp tokenize(<<c, rest::binary>>, acc) when c in [?(, ?), ?+, ?-, ?*, ?/, ?,],
    do: tokenize(rest, [{:raw, <<c>>} | acc])

  defp tokenize(text, acc) do
    case Regex.run(
           ~r/^(?:(\d+)(ns|ms|u|µ|s|m|h|d|w)\b|(\d*\.\d+|\d+)|(now\s*\(\s*\))|([A-Za-z_]\w*))/u,
           text
         ) do
      [full, n, unit] ->
        count = String.to_integer(n)

        cond do
          count > @max_unsigned -> {:syntax_error, :overflow, rest_after(text, n)}
          count > @max_signed -> {:syntax_error, :nom, rest_after(text, n)}
          true -> duration_token(count, unit, full, text, acc)
        end

      [full, "", "", number] ->
        number_token(number, rest_after(text, full), acc)

      [full, "", "", "", _now] ->
        tokenize(rest_after(text, full), [{:raw, "now()"} | acc])

      [full, "", "", "", "", word] ->
        word_token(String.upcase(word), word, rest_after(text, full), acc)

      nil ->
        {:error, "unsupported InfluxQL WHERE: #{text}"}
    end
  end

  @spec duration_token(non_neg_integer(), binary(), binary(), binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp duration_token(count, unit, full, text, acc) do
    duration = {:duration, count * Map.fetch!(@duration_ns, unit), full}
    tokenize(rest_after(text, full), [duration | acc])
  end

  # A number that a letter, digit, underscore or dot follows is cut short
  # there, which the engine cannot continue from.
  @spec number_token(binary(), binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp number_token(number, rest, acc) do
    case rest do
      <<c, _more::binary>> when c in ?0..?9 or c in ?a..?z or c in ?A..?Z or c in [?_, ?.] ->
        {:syntax_error, :nom, rest}

      _ended ->
        case integer_overflow(number, acc) do
          nil -> tokenize(rest, [{:number, number} | acc])
          kind -> {:syntax_error, kind, rest}
        end
    end
  end

  # An integer literal fits the unsigned 64-bit range, a negated one the
  # signed range; a number with a fraction has no range.
  @spec integer_overflow(binary(), list()) :: :overflow | :signed_overflow | nil
  defp integer_overflow(number, acc) do
    case Integer.parse(number) do
      {n, ""} when n > @max_unsigned -> :overflow
      {n, ""} when n > @max_signed + 1 -> if negated?(acc), do: :signed_overflow
      _fits_or_fraction -> nil
    end
  end

  # A minus is a sign, not a subtraction, at the start, after a comparison,
  # an opening parenthesis, a connective or another operator.
  @spec negated?(list()) :: boolean()
  defp negated?([{:raw, "-"} | before]) do
    case before do
      [] -> true
      [{:op, _op} | _more] -> true
      [{:raw, word} | _more] -> String.upcase(word) in ["(", "AND", "OR", "+", "-", "*", "/"]
      _operand -> false
    end
  end

  defp negated?(_acc), do: false

  # `NOT` is no keyword; `AND` or `OR` with nothing after it has no operand.
  @spec word_token(binary(), binary(), binary(), list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp word_token("NOT", word, rest, acc) do
    if rest =~ ~r/^\s*[=!<>]/,
      do: tokenize(rest, [{:ident, word} | acc]),
      else: {:syntax_error, :nom, String.trim_leading(rest)}
  end

  defp word_token(upcased, word, rest, acc) when upcased in ["AND", "OR"] do
    cond do
      reserved_kind(acc) != :nom -> {:syntax_error, reserved_kind(acc), word <> rest}
      String.trim(rest) == "" -> {:syntax_error, :operand, rest}
      true -> tokenize(rest, [{:raw, word} | acc])
    end
  end

  defp word_token(upcased, word, rest, acc) do
    if reserved?(word) and not String.starts_with?(rest, ":"),
      do: {:syntax_error, reserved_kind(acc), word <> rest},
      else: tokenize(rest, [plain_word(upcased, word) | acc])
  end

  # What stands before a word where an operand is expected decides the
  # error (see `check_where/4`).
  @spec reserved_kind(list()) :: atom()
  defp reserved_kind([]), do: :where_unparsed
  defp reserved_kind([{:raw, "("} | before]), do: reserved_kind(before)
  defp reserved_kind([{:op, _op} | _before]), do: :reserved_operand

  defp reserved_kind([{:raw, sign} | before]) when sign in ["+", "-"] do
    if unary_sign?(before), do: reserved_kind(before), else: :reserved_failure
  end

  defp reserved_kind([{:raw, op} | _before]) when op in ["*", "/"], do: :reserved_operator

  defp reserved_kind([{:raw, word} | _before]) do
    if String.upcase(word) in ["AND", "OR"], do: :reserved_operand, else: :nom
  end

  defp reserved_kind(_operand), do: :nom

  @spec unary_sign?(list()) :: boolean()
  defp unary_sign?([]), do: true
  defp unary_sign?([{:op, _op} | _before]), do: true

  defp unary_sign?([{:raw, word} | _before]),
    do: String.upcase(word) in ["(", "AND", "OR", "+", "-", "*", "/"]

  defp unary_sign?(_operand), do: false

  # A comparison operator needs an operand after it; the engine reports the
  # end of the operator.
  @spec operand(binary(), {:op, binary()}, list()) ::
          {:ok, list()} | {:syntax_error, atom(), binary()} | {:error, binary()}
  defp operand(rest, {:op, op} = token, acc) do
    trimmed = String.trim_leading(rest)

    cond do
      trimmed == "" and op in ["=~", "!~"] -> {:syntax_error, :regex, rest}
      trimmed == "" -> {:syntax_error, :operand, rest}
      cannot_start_operand?(trimmed) -> {:syntax_error, :operand, rest}
      true -> tokenize(rest, [token | acc])
    end
  end

  # A closing parenthesis, a connective or a dot with no digit after it.
  @spec cannot_start_operand?(binary()) :: boolean()
  defp cannot_start_operand?(text),
    do: Regex.match?(~r/^(?:\)|[-+]?\.(?!\d)|(?:AND|OR)\b)/i, text)

  @spec rest_after(binary(), binary()) :: binary()
  defp rest_after(text, prefix),
    do: binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))

  @spec plain_word(binary(), binary()) :: tuple()
  defp plain_word(upcased, word) do
    if upcased in ~w(TRUE FALSE), do: {:raw, word}, else: {:ident, word}
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
  @spec plan(tuple(), {MapSet.t(binary()), map()}) :: {binary(), [bound()]}
  defp plan({:cmp, tokens}, {tags, _types} = ctx) do
    if Enum.any?(tokens, &match?({:ident, "time"}, &1)),
      do: time_plan(tokens, tags),
      else: {plain_or_typed(tokens, ctx), []}
  end

  defp plan({:group, node}, ctx) do
    {sql, lowers} = plan(node, ctx)
    {"(" <> sql <> ")", lowers}
  end

  defp plan({:and, nodes}, ctx), do: join_plans(nodes, " AND ", ctx)

  defp plan({:or, nodes}, ctx) do
    if Enum.any?(nodes, &mentions_time_node?/1),
      do: throw({:refused, "unsupported InfluxQL (a time comparison inside OR)"})

    join_plans(nodes, " OR ", ctx)
  end

  defp join_plans(nodes, separator, ctx) do
    {sqls, lowers} = nodes |> Enum.map(&plan(&1, ctx)) |> Enum.unzip()
    {Enum.join(sqls, separator), Enum.concat(lowers)}
  end

  defp mentions_time_node?({:cmp, tokens}), do: Enum.any?(tokens, &match?({:ident, "time"}, &1))
  defp mentions_time_node?({:group, node}), do: mentions_time_node?(node)
  defp mentions_time_node?({_kind, nodes}), do: Enum.any?(nodes, &mentions_time_node?/1)

  # ---------------------------------------------------------------------------
  # Typed comparisons
  #
  # The engine compares a field with a literal by the field's type
  # (verified, for every operator):
  #
  #   * a literal of another kind than the field (a boolean or string
  #     against a number, a number against a boolean or string) is false for
  #     every row, not an error
  #   * an integer beyond the signed range (up to the unsigned) is an
  #     unsigned literal: an integer field is compared as unsigned (a
  #     negative value as 2^64 + value - 1, the lowest integer as null), an
  #     unsigned or float field
  #     as it is, a boolean field is the planning error "Cannot infer common
  #     argument type"
  #   * a negative integer against an unsigned field is 2^64 + n - 1
  #     (`u > -1` is false for all but the largest)
  #   * an unsigned field against a boolean is the same planning error;
  #     against a string, a string field against a big integer and a tag
  #     against a big integer, the engine compares as text: refused by name
  #   * a bare field as the whole condition is a planning error (after the
  #     LIMIT is checked) naming the field's type; inside `AND` / `OR` it is
  #     refused
  # ---------------------------------------------------------------------------

  @typedoc "The type of a field, as the engine plans it."
  @type field_type :: :integer | :unsigned | :float | :string | :boolean

  @arrow_types %{
    integer: "Int64",
    unsigned: "UInt64",
    float: "Float64",
    string: "Utf8",
    boolean: "Boolean",
    tag: "Dictionary(Int32, Utf8)"
  }

  @comparison_ops ["=", "!=", "<>", "<", "<=", ">", ">="]
  @flipped_ops %{
    "=" => "=",
    "!=" => "!=",
    "<>" => "<>",
    "<" => ">",
    "<=" => ">=",
    ">" => "<",
    ">=" => "<="
  }

  # The SQL of a comparison tokens, typed when it is a field against a literal.
  @spec plain_or_typed(list(), {MapSet.t(binary()), map()}) :: binary()
  defp plain_or_typed(tokens, {tags, types}) do
    case typed_comparison(tokens, tags, types) do
      nil -> tokens |> drop_unary_plus([]) |> rewrite(tags, []) |> Enum.join(" ")
      sql -> sql
    end
  end

  @spec typed_comparison(list(), MapSet.t(binary()), map()) :: binary() | nil
  defp typed_comparison(tokens, tags, types) do
    with {name, op, literal, flipped?} <- comparison_parts(tokens),
         type when type != nil <- field_kind(name, tags, types),
         literal when literal != nil <- literal_kind(literal) do
      op = if flipped?, do: Map.fetch!(@flipped_ops, op), else: op
      typed_sql(type, literal, ident_sql(name), op, flipped?)
    else
      _untyped -> nil
    end
  end

  @spec field_kind(binary(), MapSet.t(binary()), map()) :: atom() | nil
  defp field_kind(name, tags, types) do
    if MapSet.member?(tags, name), do: :tag, else: Map.get(types, name)
  end

  # `name op literal` and `literal op name`, the literal a number (signed),
  # a boolean or a string.
  @spec comparison_parts(list()) :: {binary(), binary(), list(), boolean()} | nil
  defp comparison_parts([{:ident, name}, {:op, op} | literal]) when op in @comparison_ops,
    do: {name, op, literal, false}

  defp comparison_parts(tokens) when length(tokens) in [3, 4] do
    case Enum.split(tokens, -2) do
      {literal, [{:op, op}, {:ident, name}]} when op in @comparison_ops ->
        {name, op, literal, true}

      _other ->
        nil
    end
  end

  defp comparison_parts(_tokens), do: nil

  @spec literal_kind(list()) ::
          {:integer, integer()} | :float | :boolean | :string | :expression | nil
  defp literal_kind([{:raw, sign}, {:number, _text} = number]) when sign in ["-", "+"],
    do: signed_kind(sign, number)

  defp literal_kind([{:number, _text} = number]), do: signed_kind("+", number)
  defp literal_kind([{:str, _content}]), do: :string

  defp literal_kind([{:raw, word}]) do
    if String.upcase(word) in ["TRUE", "FALSE"], do: :boolean
  end

  defp literal_kind(tokens) do
    if Enum.all?(tokens, &constant_token?/1), do: constant_kind(tokens)
  end

  defp constant_token?({:number, _text}), do: true
  defp constant_token?({:raw, text}), do: text in ["+", "-", "*", "/", "(", ")"]
  defp constant_token?(_token), do: false

  # A constant of numbers, `+ - *` and parentheses is folded before it is
  # compared, as the engine does; anything else numeric (`/`, an
  # overflow) is `:expression`, which the caller refuses.
  @spec constant_kind(list()) :: {:integer, integer()} | :float | :expression
  defp constant_kind(tokens) do
    case fold_sum(tokens) do
      {value, []} when is_float(value) ->
        :float

      {value, []} when is_integer(value) and value >= -@max_signed - 1 and value <= @max_signed ->
        {:integer, value}

      _unfoldable ->
        :expression
    end
  end

  defp fold_sum(tokens) do
    with {value, rest} <- fold_product(tokens),
         do: fold_more(rest, value, ["+", "-"], &fold_product/1)
  end

  defp fold_product(tokens) do
    with {value, rest} <- fold_factor(tokens), do: fold_more(rest, value, ["*"], &fold_factor/1)
  end

  defp fold_more([{:raw, op} | rest] = tokens, left, ops, next) do
    if op in ops do
      case next.(rest) do
        {right, after_right} -> fold_more(after_right, apply_op(op, left, right), ops, next)
        :error -> :error
      end
    else
      {left, tokens}
    end
  end

  defp fold_more(tokens, left, _ops, _next), do: {left, tokens}

  defp apply_op("+", left, right), do: left + right
  defp apply_op("-", left, right), do: left - right
  defp apply_op("*", left, right), do: left * right

  defp fold_factor([{:raw, "-"} | rest]) do
    with {value, after_value} <- fold_factor(rest), do: {-value, after_value}
  end

  defp fold_factor([{:raw, "+"} | rest]), do: fold_factor(rest)

  defp fold_factor([{:raw, "("} | rest]) do
    case fold_sum(rest) do
      {value, [{:raw, ")"} | after_group]} -> {value, after_group}
      _unbalanced -> :error
    end
  end

  defp fold_factor([{:number, text} | rest]) do
    case Integer.parse(text) do
      {n, ""} -> {n, rest}
      _fraction -> {text |> number_text() |> String.to_float(), rest}
    end
  end

  defp fold_factor(_tokens), do: :error

  defp number_text("." <> _fraction = text), do: "0" <> text
  defp number_text(text), do: text

  defp signed_kind(sign, {:number, text}) do
    case Integer.parse(text) do
      {n, ""} -> {:integer, if(sign == "-", do: -n, else: n)}
      _fraction -> :float
    end
  end

  # The SQL for a field of `type` against `literal`, or `nil` to leave the
  # comparison as written.
  @spec typed_sql(atom(), term(), binary(), binary(), boolean()) :: binary() | nil
  defp typed_sql(type, literal, column, op, flipped?) do
    case decide(type, literal, op) do
      :plain -> nil
      :never -> "(#{column} IS NULL AND #{column} IS NOT NULL)"
      {:unsigned, n} -> "#{column} #{op} #{n}"
      :wrap -> wrapped_sql(column, op, literal)
      :mismatch -> mismatch(type, literal, op, flipped?)
      :refuse -> throw({:refused, "unsupported InfluxQL (#{refusal(type, literal)})"})
    end
  end

  # Booleans and strings have equality only: an ordering is false for all.
  @spec decide(atom(), term(), binary()) ::
          :plain | :never | :wrap | :mismatch | :refuse | {:unsigned, non_neg_integer()}
  defp decide(type, kind, op) when type in [:boolean, :string] and op in ["<", "<=", ">", ">="] do
    if decide(type, kind, "=") == :plain, do: :never, else: decide(type, kind, "=")
  end

  defp decide(:float, :expression, _op), do: :plain
  defp decide(_type, :expression, _op), do: :refuse
  defp decide(:integer, {:integer, n}, _op) when n > @max_signed, do: :wrap
  defp decide(:integer, kind, _op) when kind == :float or is_tuple(kind), do: :plain
  defp decide(:float, kind, _op) when kind == :float or is_tuple(kind), do: :plain

  defp decide(:unsigned, {:integer, n}, _op) when n == -9_223_372_036_854_775_808,
    do: :refuse

  defp decide(:unsigned, {:integer, n}, _op) when n < 0,
    do: {:unsigned, n + 18_446_744_073_709_551_615}

  defp decide(:unsigned, kind, _op) when kind == :float or is_tuple(kind), do: :plain
  defp decide(:unsigned, :boolean, _op), do: :mismatch
  defp decide(:unsigned, :string, _op), do: :refuse
  defp decide(:boolean, :boolean, _op), do: :plain
  defp decide(:boolean, {:integer, n}, _op) when n > @max_signed, do: :mismatch
  defp decide(:string, :string, _op), do: :plain
  defp decide(:string, {:integer, n}, _op) when n > @max_signed, do: :refuse
  defp decide(:tag, {:integer, n}, _op) when n > @max_signed, do: :refuse
  defp decide(:tag, :string, _op), do: :plain
  defp decide(_type, _literal, _op), do: :never

  # An integer field against an unsigned literal `n` (verified): a
  # non-negative value is itself, a negative one `2^64 + value - 1`, and the
  # lowest 64-bit integer is null. With `m = n - 2^64 + 1` (negative) a
  # negative value therefore compares as `value` against `m`, a non-negative
  # one is below `n`.
  @spec wrapped_sql(binary(), binary(), {:integer, integer()}) :: binary()
  defp wrapped_sql(column, op, {:integer, n}) do
    m = n - 18_446_744_073_709_551_615

    negative =
      "(#{column} < 0 AND #{column} > -9223372036854775808 AND #{column} #{op} #{m})"

    if op in ["=", ">", ">="], do: negative, else: "(#{column} >= 0 OR #{negative})"
  end

  @spec mismatch(atom(), term(), binary(), boolean()) :: no_return()
  defp mismatch(type, literal, op, flipped?) do
    field = Map.fetch!(@arrow_types, type)
    other = if literal == :boolean, do: "Boolean", else: "UInt64"
    {left, right} = if flipped?, do: {other, field}, else: {field, other}
    op = if flipped?, do: Map.fetch!(@flipped_ops, op), else: op
    op = if op == "<>", do: "!=", else: op

    throw(
      {:refused,
       {:engine,
        "Error during planning: Cannot infer common argument type for comparison " <>
          "operation #{left} #{op} #{right}"}}
    )
  end

  @spec refusal(atom(), term()) :: binary()
  defp refusal(_type, :expression), do: "a field compared with a constant expression"
  defp refusal(:unsigned, :string), do: "an unsigned field compared with a string"

  defp refusal(:unsigned, _literal),
    do: "an unsigned field compared with the lowest 64-bit integer"

  defp refusal(_type, _literal), do: "a string compared with an integer beyond 64 bits signed"

  # A bare field (or tag) as the whole condition: the engine's planning
  # error, raised after the LIMIT. Inside `AND` / `OR` it is refused.
  @spec bare_condition(tuple(), {MapSet.t(binary()), map()}) :: binary() | nil
  defp bare_condition({:group, node}, ctx), do: bare_condition(node, ctx)

  defp bare_condition({:cmp, tokens}, {tags, types}) do
    case tokens |> strip_parens() |> bare_field(tags, types) do
      nil -> nil
      :boolean -> nil
      type -> bare_error(type)
    end
  end

  defp bare_condition({kind, nodes}, ctx) when kind in [:and, :or] do
    if Enum.any?(nodes, &bare_member?(&1, ctx)),
      do: throw({:refused, "unsupported InfluxQL (a bare non-boolean field inside AND/OR)"})

    nil
  end

  defp bare_condition(_node, _ctx), do: nil

  @spec bare_field(list(), MapSet.t(binary()), map()) :: atom() | nil
  defp bare_field([{:ident, name}], tags, types), do: field_kind(name, tags, types)
  defp bare_field(_tokens, _tags, _types), do: nil

  @spec strip_parens(list()) :: list()
  defp strip_parens([{:raw, "("} | rest] = tokens) do
    case Enum.split(rest, -1) do
      {inside, [{:raw, ")"}]} -> strip_parens(inside)
      _other -> tokens
    end
  end

  defp strip_parens(tokens), do: tokens

  defp bare_member?({:group, node}, ctx), do: bare_member?(node, ctx)

  defp bare_member?({:cmp, tokens}, {tags, types}),
    do: bare_field(strip_parens(tokens), tags, types) not in [nil, :boolean]

  defp bare_member?({kind, nodes}, ctx) when kind in [:and, :or],
    do: Enum.any?(nodes, &bare_member?(&1, ctx))

  defp bare_member?(_node, _ctx), do: false

  @spec bare_error(atom()) :: binary()
  defp bare_error(type) do
    "type_coercion\ncaused by\nError during planning: Cannot infer common argument type " <>
      "for logical boolean operation Boolean AND #{Map.fetch!(@arrow_types, type)}"
  end

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

  # Words the SQL the double hands on reads as keywords, though InfluxQL
  # takes them as names.
  @sql_words ~w(not is like ilike between case when then else exists)

  @spec ident_sql(binary()) :: binary()
  defp ident_sql(name) do
    if Regex.match?(~r/^[A-Za-z_]\w*$/, name) and String.downcase(name) not in @sql_words,
      do: name,
      else: ~s("#{name}")
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
