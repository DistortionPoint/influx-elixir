defmodule InfluxElixir.Client.Local.InfluxQL do
  @moduledoc """
  The InfluxQL `SELECT` subset `InfluxElixir.Client.Local` answers, shaped
  the way InfluxDB 3 answers it (verified against the engine; see
  `docs/design/2026-09-23_local-influxql.md`).

  InfluxQL is not SQL with other keywords. Every row carries
  `"iox::measurement"` and `"time"`; rows come back in time order; a row with
  no selected field value is dropped; an unknown column or measurement is an
  empty result, not an error; aggregates are named after the function
  (`mean`, `count`, ...) and put `time` at the epoch, except a lone selector
  (`MAX`, `MIN`, `FIRST`, `LAST`), which returns its point's time and tags;
  `LIMIT` and `OFFSET` apply per `GROUP BY` series.

  This module is pure. `parse/1` turns the statement into a query map;
  `run/3` shapes rows the caller has already filtered with the statement's
  `WHERE` clause (Client.Local runs it through its SQL engine).

  Refused by name, rather than answered wrongly: `GROUP BY time(...)` (the
  engine fills every empty bucket), regular expressions, `fill()`, `INTO`,
  `SLIMIT`/`SOFFSET`, subqueries, `GROUP BY *`, functions other than
  `MEAN SUM COUNT MIN MAX FIRST LAST`, `F(*)` other than `COUNT(*)`, and
  plain columns beside anything but a single selector.
  """

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
      {~r/=~|!~/, "regular expressions"},
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
  @spec parse(binary()) :: {:ok, query()} | {:error, binary()}
  def parse(statement) do
    with :ok <- check_supported(statement),
         %{"items" => items, "from" => from, "rest" => rest} <-
           Regex.named_captures(@select, statement) || {:error, "invalid statement"},
         %{} = clauses <- Regex.named_captures(@rest, rest) || {:error, "invalid clauses"},
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
  statement's `WHERE`, as SQL row maps with `"time"` — into the engine's
  answer. `tags` names the measurement's tag columns; everything else but
  `time` is a field.
  """
  @spec run(query(), [map()], MapSet.t(binary())) :: [map()]
  def run(query, rows, tags) do
    rows
    |> Enum.group_by(&Map.take(&1, query.group_by))
    |> Enum.sort_by(fn {key, _rows} -> Enum.map(query.group_by, &Map.get(key, &1)) end)
    |> Enum.flat_map(fn {key, group} ->
      group
      |> Enum.sort_by(& &1["time"], DateTime)
      |> series(query, tags, key)
      |> Enum.drop(query.offset)
      |> take(query.limit)
    end)
  end

  # ---------------------------------------------------------------------------
  # One series (one GROUP BY key)
  # ---------------------------------------------------------------------------

  @spec series([map()], query(), MapSet.t(binary()), map()) :: [map()]
  defp series(rows, query, tags, key) do
    base = Map.put(key, "iox::measurement", query.measurement)

    if Enum.any?(query.items, &match?({:aggregate, _fn, _arg, _alias}, &1)),
      do: aggregate(rows, query.items, tags, base),
      else: project(rows, query, tags, base)
  end

  @spec project([map()], query(), MapSet.t(binary()), map()) :: [map()]
  defp project(rows, query, tags, base) do
    rows = if query.descending, do: Enum.reverse(rows), else: rows

    for row <- rows,
        projected = Enum.reduce(query.items, %{}, &put_item(&1, row, &2)),
        Enum.any?(Map.keys(projected), &field?(&1, projected, tags, query.items)) do
      base |> Map.put("time", row["time"]) |> Map.merge(projected)
    end
  end

  @spec put_item(item(), map(), map()) :: map()
  defp put_item(:star, row, acc), do: Map.merge(acc, Map.delete(row, "time"))

  defp put_item({:column, column, name}, row, acc) do
    case Map.fetch(row, column) do
      {:ok, value} -> Map.put(acc, name, value)
      :error -> acc
    end
  end

  # A projected key counts as a field value unless it is a tag (under its
  # own name or an alias).
  @spec field?(binary(), map(), MapSet.t(binary()), [item()]) :: boolean()
  defp field?(name, _projected, tags, items) do
    source =
      Enum.find_value(items, name, fn
        {:column, column, ^name} -> column
        _other -> nil
      end)

    not MapSet.member?(tags, source)
  end

  @spec aggregate([map()], [item()], MapSet.t(binary()), map()) :: [map()]
  defp aggregate(rows, items, tags, base) do
    aggregates = for {:aggregate, _fn, _arg, _alias} = item <- items, do: item
    fields = rows |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()
    fields = Enum.reject(fields, &(&1 == "time" or MapSet.member?(tags, &1)))

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
        [base |> Map.put("time", @epoch) |> Map.merge(values)]
    end
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
  defp check_supported(statement) do
    case Enum.find(unsupported(), fn {pattern, _name} -> Regex.match?(pattern, statement) end) do
      nil -> :ok
      {_pattern, name} -> {:error, "unsupported InfluxQL (#{name})"}
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
