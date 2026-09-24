defmodule InfluxElixir.Client.Local.Flux do
  @moduledoc """
  The Flux subset `InfluxElixir.Client.Local` answers, with InfluxDB 2's
  semantics (verified against `influxdb:2.7`; see
  `docs/design/2026-09-24_local-flux-pipeline.md`).

  A query is a pipeline, `from(bucket: "b") |> range(...) |> ...`, and every
  stage is applied — or the query is refused. Before this module the double
  matched a few regexes anywhere in the text and ignored the rest, so
  `|> mean()` returned the raw rows.

  Supported stages:

    * `from(bucket: "b")` — first; the bucket must exist (404 otherwise)
    * `range(start: s[, stop: s])` — required, as on the engine; `s` is
      Unix seconds, an RFC3339 time, a negative duration (`-1h`, `-30m`,
      `-7d`, `-10s`, `-2w`) or `now()`; `stop` defaults to now. Every row
      carries `_start` and `_stop`.
    * `filter(fn: (r) => ...)` — `r.key` or `r["key"]` compared with
      `== != < <= > >=` against a string, number or boolean, combined with
      `and`, `or`, `not` and parentheses. A key the row lacks never matches.
    * `first() last() min() max()` — the selected row per table
    * `mean() sum() count()` — one row per table, without `_time`
      (`mean` is a float; `count` counts rows)
    * `limit(n: N[, offset: M])` — per table
    * `yield(name: "x")` — names the result

  Tables are the series — measurement, tag set, field — numbered from `0`
  in that order, rows in time order, as the engine numbers them.
  """

  alias InfluxElixir.Query.ResponseParser

  @typedoc "A comparison operand: a row key compared against a literal."
  @type predicate ::
          {:cmp, binary(), binary(), term()}
          | {:and, predicate(), predicate()}
          | {:or, predicate(), predicate()}
          | {:not, predicate()}

  @typedoc "One pipeline stage after `from`."
  @type stage ::
          {:range, integer(), integer()}
          | {:filter, predicate()}
          | {:selector, :first | :last | :min | :max}
          | {:aggregate, :mean | :sum | :count}
          | {:limit, non_neg_integer(), non_neg_integer()}
          | {:yield, binary()}

  @typedoc "A parsed query."
  @type query :: %{bucket: binary(), stages: [stage()]}

  @doc """
  Parses a Flux query. `now_ns` is the instant `now()` and a relative
  `range` resolve against. Returns `{:error, message}` for syntax the
  double does not model.
  """
  @spec parse(binary(), integer()) :: {:ok, query()} | {:error, binary()}
  def parse(flux, now_ns) do
    with {:ok, calls} <- split_pipeline(flux),
         {:ok, bucket, rest} <- parse_from(calls),
         {:ok, stages} <- parse_stages(rest, now_ns),
         :ok <- require_range(stages, bucket) do
      {:ok, %{bucket: bucket, stages: stages}}
    end
  end

  @doc """
  Runs a parsed query over the bucket's points (`%{measurement, tags,
  fields, timestamp}` maps, duplicates already merged).
  """
  @spec run(query(), [map()]) :: {:ok, [map()]} | {:error, binary()}
  def run(%{stages: stages}, points) do
    {range, rest} = split_range(stages)
    {start_ns, stop_ns} = range

    tables =
      points
      |> Enum.filter(&(&1.timestamp >= start_ns and &1.timestamp < stop_ns))
      |> Enum.flat_map(&rows(&1, start_ns, stop_ns))
      |> Enum.group_by(&series_key/1)
      |> Enum.sort_by(fn {key, _rows} -> key end)
      |> Enum.map(fn {_key, rows} -> Enum.sort_by(rows, & &1["_time"], DateTime) end)

    {tables, result} = Enum.reduce(rest, {tables, "_result"}, &apply_stage/2)

    rows =
      tables
      |> Enum.reject(&(&1 == []))
      |> Enum.with_index()
      |> Enum.flat_map(fn {rows, index} ->
        Enum.map(rows, &Map.merge(&1, %{"table" => index, "result" => result}))
      end)

    {:ok, rows}
  catch
    {:flux_error, message} -> {:error, message}
  end

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  @spec split_range([stage()]) :: {{integer(), integer()}, [stage()]}
  defp split_range([{:range, start_ns, stop_ns} | rest]), do: {{start_ns, stop_ns}, rest}

  defp split_range([stage | rest]) do
    {range, others} = split_range(rest)
    {range, [stage | others]}
  end

  @spec rows(map(), integer(), integer()) :: [map()]
  defp rows(point, start_ns, stop_ns) do
    base =
      Map.merge(point.tags, %{
        "_measurement" => point.measurement,
        "_start" => datetime(start_ns),
        "_stop" => datetime(stop_ns),
        "_time" => datetime(point.timestamp)
      })

    for {field, value} <- point.fields do
      Map.merge(base, %{"_field" => field, "_value" => value})
    end
  end

  # The engine's series order: measurement, then the tag set, then field.
  @spec series_key(map()) :: {binary(), [{binary(), binary()}], binary()}
  defp series_key(row) do
    tags =
      row
      |> Map.drop(["_measurement", "_field", "_value", "_time", "_start", "_stop"])
      |> Enum.sort()

    {row["_measurement"], tags, row["_field"]}
  end

  @spec apply_stage(stage(), {[[map()]], binary()}) :: {[[map()]], binary()}
  defp apply_stage({:yield, name}, {tables, _result}), do: {tables, name}

  defp apply_stage(stage, {tables, result}),
    do: {Enum.map(tables, &apply_to_table(stage, &1)), result}

  @spec apply_to_table(stage(), [map()]) :: [map()]
  defp apply_to_table({:filter, predicate}, rows),
    do: Enum.filter(rows, &(matches?(predicate, &1) == true))

  defp apply_to_table({:limit, n, offset}, rows), do: rows |> Enum.drop(offset) |> Enum.take(n)
  defp apply_to_table({:selector, _kind}, []), do: []
  defp apply_to_table({:selector, :first}, [row | _rest]), do: [row]
  defp apply_to_table({:selector, :last}, rows), do: [List.last(rows)]

  # The first row with the extreme value wins a tie.
  defp apply_to_table({:selector, kind}, rows) do
    better? = if kind == :max, do: &Kernel.>/2, else: &Kernel.</2

    [
      Enum.reduce(rows, fn row, best ->
        if better?.(row["_value"], best["_value"]), do: row, else: best
      end)
    ]
  end

  defp apply_to_table({:aggregate, _kind}, []), do: []

  defp apply_to_table({:aggregate, kind}, [first | _rest] = rows) do
    values = Enum.map(rows, & &1["_value"])

    if kind != :count and not Enum.all?(values, &is_number/1) do
      throw({:flux_error, "unsupported input type for #{kind} aggregate: #{type_name(values)}"})
    end

    value =
      case kind do
        :count -> length(values)
        :sum -> Enum.sum(values)
        :mean -> Enum.sum(values) / length(values)
      end

    [first |> Map.delete("_time") |> Map.put("_value", value)]
  end

  # Flux logic is three-valued: a key the row does not have is null, a
  # comparison with null is null, `not null` is null, and filter keeps a
  # row only when the predicate is true.
  @spec matches?(predicate(), map()) :: boolean() | nil
  defp matches?({:and, a, b}, row) do
    case {matches?(a, row), matches?(b, row)} do
      {false, _b} -> false
      {_a, false} -> false
      {true, true} -> true
      _null -> nil
    end
  end

  defp matches?({:or, a, b}, row) do
    case {matches?(a, row), matches?(b, row)} do
      {true, _b} -> true
      {_a, true} -> true
      {false, false} -> false
      _null -> nil
    end
  end

  defp matches?({:not, a}, row) do
    case matches?(a, row) do
      nil -> nil
      value -> not value
    end
  end

  defp matches?({:cmp, key, op, literal}, row) do
    case Map.fetch(row, key) do
      {:ok, value} -> compare(op, value, literal)
      :error -> nil
    end
  end

  @spec compare(binary(), term(), term()) :: boolean()
  defp compare(op, a, b) when is_number(a) and is_number(b), do: ordered(op, a, b)
  defp compare(op, a, b) when is_binary(a) and is_binary(b), do: ordered(op, a, b)
  defp compare("==", a, b), do: a === b
  defp compare("!=", a, b), do: a !== b
  defp compare(_op, _a, _b), do: false

  @spec ordered(binary(), term(), term()) :: boolean()
  defp ordered("==", a, b), do: a == b
  defp ordered("!=", a, b), do: a != b
  defp ordered("<", a, b), do: a < b
  defp ordered("<=", a, b), do: a <= b
  defp ordered(">", a, b), do: a > b
  defp ordered(">=", a, b), do: a >= b

  @spec type_name([term()]) :: binary()
  defp type_name(values) do
    case Enum.find(values, &(not is_number(&1))) do
      value when is_binary(value) -> "string"
      value when is_boolean(value) -> "boolean"
      _other -> "unknown"
    end
  end

  @spec datetime(integer()) :: DateTime.t()
  defp datetime(ns) do
    ns |> DateTime.from_unix!(:nanosecond) |> ResponseParser.microsecond_precision()
  end

  # ---------------------------------------------------------------------------
  # Parsing — the pipeline
  # ---------------------------------------------------------------------------

  # Splits `a(...) |> b(...)` at top-level pipes into `{name, args}` calls.
  @spec split_pipeline(binary()) :: {:ok, [{binary(), binary()}]} | {:error, binary()}
  defp split_pipeline(flux) do
    flux
    |> split_top_level("|>")
    |> Enum.reduce_while({:ok, []}, fn text, {:ok, acc} ->
      case Regex.run(~r/^\s*([A-Za-z_]\w*)\s*\((.*)\)\s*$/s, text) do
        [_full, name, args] ->
          {:cont, {:ok, [{name, args} | acc]}}

        nil ->
          {:halt, {:error, "Client.Local: unsupported Flux expression: #{String.trim(text)}"}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  @spec parse_from([{binary(), binary()}]) ::
          {:ok, binary(), [{binary(), binary()}]} | {:error, binary()}
  defp parse_from([{"from", args} | rest]) do
    case Regex.run(~r/^\s*bucket\s*:\s*"([^"]*)"\s*$/, args) do
      [_full, bucket] -> {:ok, bucket, rest}
      nil -> {:error, "Client.Local: unsupported from(): #{args}"}
    end
  end

  defp parse_from(_calls),
    do: {:error, "Client.Local: a Flux query must start with from(bucket: ...)"}

  @spec parse_stages([{binary(), binary()}], integer()) :: {:ok, [stage()]} | {:error, binary()}
  defp parse_stages(calls, now_ns) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, acc} ->
      case parse_stage(call, now_ns) do
        {:ok, stage} -> {:cont, {:ok, [stage | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, stages} -> {:ok, Enum.reverse(stages)}
      error -> error
    end
  end

  @selectors %{"first" => :first, "last" => :last, "min" => :min, "max" => :max}
  @aggregates %{"mean" => :mean, "sum" => :sum, "count" => :count}

  @spec parse_stage({binary(), binary()}, integer()) :: {:ok, stage()} | {:error, binary()}
  defp parse_stage({"range", args}, now_ns) do
    params = named_args(args)

    with {:ok, start} <- fetch_time(params, "start", now_ns),
         {:ok, stop} <- optional_time(params, "stop", now_ns) do
      {:ok, {:range, start, stop}}
    end
  end

  defp parse_stage({"filter", args}, _now_ns) do
    case Regex.run(~r/^\s*fn\s*:\s*\(\s*r\s*\)\s*=>\s*(.+?)\s*$/s, args) do
      [_full, body] ->
        with {:ok, predicate} <- parse_predicate(body), do: {:ok, {:filter, predicate}}

      nil ->
        {:error, "Client.Local: unsupported filter(): #{args}"}
    end
  end

  defp parse_stage({"limit", args}, _now_ns) do
    params = named_args(args)

    with {:ok, n} <- fetch_int(params, "n"),
         {:ok, offset} <- optional_int(params, "offset") do
      {:ok, {:limit, n, offset}}
    end
  end

  defp parse_stage({"yield", args}, _now_ns) do
    case named_args(args) do
      %{"name" => "\"" <> _rest = quoted} -> {:ok, {:yield, String.trim(quoted, "\"")}}
      params when params == %{} -> {:ok, {:yield, "_result"}}
      _other -> {:error, "Client.Local: unsupported yield(): #{args}"}
    end
  end

  defp parse_stage({name, args}, _now_ns) do
    cond do
      String.trim(args) != "" and Map.has_key?(Map.merge(@selectors, @aggregates), name) ->
        {:error, "Client.Local: unsupported Flux arguments: #{name}(#{args})"}

      kind = @selectors[name] ->
        {:ok, {:selector, kind}}

      kind = @aggregates[name] ->
        {:ok, {:aggregate, kind}}

      true ->
        {:error, "Client.Local: unsupported Flux function: #{name}()"}
    end
  end

  @spec require_range([stage()], binary()) :: :ok | {:error, binary()}
  defp require_range(stages, bucket) do
    case Enum.count(stages, &match?({:range, _start, _stop}, &1)) do
      1 ->
        :ok

      0 ->
        {:error,
         "error in building plan while starting program: cannot submit unbounded read to " <>
           "\"#{bucket}\"; try bounding 'from' with a call to 'range'"}

      _many ->
        {:error, "Client.Local: unsupported Flux: more than one range()"}
    end
  end

  # `key: value, key: value` at top level (values may hold commas in quotes
  # or parentheses).
  @spec named_args(binary()) :: %{binary() => binary()}
  defp named_args(args) do
    args
    |> split_top_level(",")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Map.new(fn pair ->
      case String.split(pair, ":", parts: 2) do
        [key, value] -> {String.trim(key), String.trim(value)}
        [bare] -> {String.trim(bare), ""}
      end
    end)
  end

  @spec fetch_time(map(), binary(), integer()) :: {:ok, integer()} | {:error, binary()}
  defp fetch_time(params, key, now_ns) do
    case Map.fetch(params, key) do
      {:ok, text} -> parse_time(text, now_ns)
      :error -> {:error, "Client.Local: range() needs #{key}"}
    end
  end

  @spec optional_time(map(), binary(), integer()) :: {:ok, integer()} | {:error, binary()}
  defp optional_time(params, key, now_ns) do
    if Map.has_key?(params, key), do: fetch_time(params, key, now_ns), else: {:ok, now_ns}
  end

  @duration_units %{
    "s" => 1_000_000_000,
    "m" => 60_000_000_000,
    "h" => 3_600_000_000_000,
    "d" => 86_400_000_000_000,
    "w" => 604_800_000_000_000
  }

  @spec parse_time(binary(), integer()) :: {:ok, integer()} | {:error, binary()}
  defp parse_time("now()", now_ns), do: {:ok, now_ns}

  defp parse_time(text, now_ns) do
    cond do
      match = Regex.run(~r/^-(\d+)(s|m|h|d|w)$/, text) ->
        [_full, amount, unit] = match
        {:ok, now_ns - String.to_integer(amount) * @duration_units[unit]}

      Regex.match?(~r/^-?\d+$/, text) ->
        {:ok, String.to_integer(text) * 1_000_000_000}

      true ->
        case DateTime.from_iso8601(text) do
          {:ok, dt, _offset} -> {:ok, DateTime.to_unix(dt, :nanosecond)}
          {:error, _reason} -> {:error, "Client.Local: unsupported range() time: #{text}"}
        end
    end
  end

  @spec fetch_int(map(), binary()) :: {:ok, non_neg_integer()} | {:error, binary()}
  defp fetch_int(params, key) do
    with {:ok, text} <- Map.fetch(params, key),
         {n, ""} when n >= 0 <- Integer.parse(text) do
      {:ok, n}
    else
      _missing -> {:error, "Client.Local: limit() needs a non-negative integer #{key}"}
    end
  end

  @spec optional_int(map(), binary()) :: {:ok, non_neg_integer()} | {:error, binary()}
  defp optional_int(params, key),
    do: if(Map.has_key?(params, key), do: fetch_int(params, key), else: {:ok, 0})

  # ---------------------------------------------------------------------------
  # Parsing — filter predicates: or > and > not > comparison | ( ... )
  # ---------------------------------------------------------------------------

  @token ~r/^\s*(?:(?<str>"(?:[^"\\]|\\.)*")|(?<num>-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|(?<key>r\.[A-Za-z_]\w*|r\s*\[\s*"(?:[^"\\]|\\.)*"\s*\])|(?<op>==|!=|<=|>=|<|>)|(?<paren>[()])|(?<word>[A-Za-z_]\w*))/

  @spec parse_predicate(binary()) :: {:ok, predicate()} | {:error, binary()}
  defp parse_predicate(text) do
    with {:ok, tokens} <- tokenize(text, []),
         {:ok, predicate, []} <- parse_or(tokens) do
      {:ok, predicate}
    else
      _error -> {:error, "Client.Local: unsupported filter predicate: #{text}"}
    end
  end

  @spec tokenize(binary(), list()) :: {:ok, list()} | :error
  defp tokenize(text, acc) do
    with false <- String.trim(text) == "",
         [full] <- Regex.run(@token, text, capture: :first),
         {:ok, token} <- token(Regex.named_captures(@token, text)) do
      rest = binary_part(text, byte_size(full), byte_size(text) - byte_size(full))
      tokenize(rest, [token | acc])
    else
      true -> {:ok, Enum.reverse(acc)}
      _unknown -> :error
    end
  end

  @spec token(map()) :: {:ok, tuple()} | :error
  defp token(%{"str" => "\"" <> _rest = str}),
    do: {:ok, {:lit, str |> String.slice(1..-2//1) |> String.replace(~s(\\"), ~s("))}}

  defp token(%{"num" => num}) when num != "", do: {:ok, {:lit, number(num)}}
  defp token(%{"key" => key}) when key != "", do: {:ok, {:key, key_name(key)}}
  defp token(%{"op" => op}) when op != "", do: {:ok, {:op, op}}
  defp token(%{"paren" => paren}) when paren != "", do: {:ok, {:paren, paren}}
  defp token(%{"word" => word}) when word in ["true", "false"], do: {:ok, {:lit, word == "true"}}
  defp token(%{"word" => "and"}), do: {:ok, {:and}}
  defp token(%{"word" => "or"}), do: {:ok, {:or}}
  defp token(%{"word" => "not"}), do: {:ok, {:not}}
  defp token(_other), do: :error

  @spec key_name(binary()) :: binary()
  defp key_name("r." <> name), do: name

  defp key_name(bracket) do
    [_full, name] = Regex.run(~r/"((?:[^"\\]|\\.)*)"/, bracket)
    String.replace(name, ~s(\\"), ~s("))
  end

  @spec number(binary()) :: number()
  defp number(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _float -> text |> Float.parse() |> elem(0)
    end
  end

  @spec parse_or(list()) :: {:ok, predicate(), list()} | :error
  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens), do: or_tail(left, rest)
  end

  defp or_tail(left, [{:or} | rest]) do
    with {:ok, right, rest} <- parse_and(rest), do: or_tail({:or, left, right}, rest)
  end

  defp or_tail(left, rest), do: {:ok, left, rest}

  @spec parse_and(list()) :: {:ok, predicate(), list()} | :error
  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_not(tokens), do: and_tail(left, rest)
  end

  defp and_tail(left, [{:and} | rest]) do
    with {:ok, right, rest} <- parse_not(rest), do: and_tail({:and, left, right}, rest)
  end

  defp and_tail(left, rest), do: {:ok, left, rest}

  @spec parse_not(list()) :: {:ok, predicate(), list()} | :error
  defp parse_not([{:not} | rest]) do
    with {:ok, inner, rest} <- parse_not(rest), do: {:ok, {:not, inner}, rest}
  end

  defp parse_not([{:paren, "("} | rest]) do
    case parse_or(rest) do
      {:ok, inner, [{:paren, ")"} | rest]} -> {:ok, inner, rest}
      _error -> :error
    end
  end

  defp parse_not([{:key, key}, {:op, op}, {:lit, literal} | rest]),
    do: {:ok, {:cmp, key, op, literal}, rest}

  defp parse_not(_tokens), do: :error

  # ---------------------------------------------------------------------------
  # Splitting outside strings and parentheses
  # ---------------------------------------------------------------------------

  @spec split_top_level(binary(), binary()) :: [binary()]
  defp split_top_level(text, separator), do: do_split(text, separator, 0, false, "", [])

  defp do_split("", _sep, _depth, _quoted, current, acc), do: Enum.reverse([current | acc])

  defp do_split(<<"\\", c::utf8, rest::binary>>, sep, depth, true, current, acc),
    do: do_split(rest, sep, depth, true, current <> "\\" <> <<c::utf8>>, acc)

  defp do_split(<<"\"", rest::binary>>, sep, depth, quoted, current, acc),
    do: do_split(rest, sep, depth, not quoted, current <> "\"", acc)

  defp do_split(<<c::utf8, rest::binary>>, sep, depth, true, current, acc),
    do: do_split(rest, sep, depth, true, current <> <<c::utf8>>, acc)

  defp do_split(<<c, rest::binary>>, sep, depth, false, current, acc) when c in [?(, ?[],
    do: do_split(rest, sep, depth + 1, false, current <> <<c>>, acc)

  defp do_split(<<c, rest::binary>>, sep, depth, false, current, acc) when c in [?), ?]],
    do: do_split(rest, sep, depth - 1, false, current <> <<c>>, acc)

  defp do_split(text, sep, 0, false, current, acc) do
    if String.starts_with?(text, sep) do
      rest = binary_part(text, byte_size(sep), byte_size(text) - byte_size(sep))
      do_split(rest, sep, 0, false, "", [current | acc])
    else
      <<c::utf8, rest::binary>> = text
      do_split(rest, sep, 0, false, current <> <<c::utf8>>, acc)
    end
  end

  defp do_split(<<c::utf8, rest::binary>>, sep, depth, false, current, acc),
    do: do_split(rest, sep, depth, false, current <> <<c::utf8>>, acc)
end
