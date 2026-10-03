defmodule InfluxElixir.Client.Local.InfluxQLShow do
  @moduledoc false
  # What a `SHOW` statement does with what it read (`InfluxQLShowParser`),
  # as InfluxDB 3 does it (verified): which of the names it lists, in what
  # order, and the part of them `LIMIT` and `OFFSET` keep. The store and the
  # SQL engine are asked by `InfluxQLQuery`; this module is pure.

  alias InfluxElixir.Client.Local.{InfluxQL, InfluxQLShowParser, InfluxQLTokens, Retention}

  @int64_max 9_223_372_036_854_775_807
  @two_64 18_446_744_073_709_551_616

  @doc "Whether a tag key is one a `key_filter/0` lists."
  @spec key_listed?(binary(), InfluxQL.key_filter()) :: boolean()
  def key_listed?(key, {:eq, name}), do: key == name
  def key_listed?(key, {:ne, name}), do: key != name
  def key_listed?(key, {:in, names}), do: key in names
  def key_listed?(key, {:regex, regex, match?}), do: Regex.match?(regex, key) == match?

  @doc "Whether a `WHERE` names `time`: then it, not the default window, bounds the rows."
  @spec mentions_time?(binary() | nil) :: boolean()
  def mentions_time?(nil), do: false

  def mentions_time?(where) do
    case InfluxQLTokens.tokenize(where, []) do
      {:ok, tokens} -> Enum.any?(tokens, &InfluxQLTokens.time?/1)
      _not_or_refusal -> false
    end
  end

  @doc """
  The measurements a `FROM` list (or `WITH MEASUREMENT`, as a one-item list)
  selects among those the database has, in their order; all of them without
  one. A name the database lacks selects nothing.
  """
  @spec select_measurements([binary()], [InfluxQLShowParser.source()] | nil) :: [binary()]
  def select_measurements(names, nil), do: names

  def select_measurements(names, sources),
    do: Enum.filter(names, fn name -> Enum.any?(sources, &selects?(&1, name)) end)

  @spec selects?(InfluxQLShowParser.source(), binary()) :: boolean()
  defp selects?({:name, wanted}, name), do: wanted == name
  defp selects?({:regex, regex}, name), do: Regex.match?(regex, name)

  @doc """
  The planning error of `SHOW MEASUREMENTS` for a `LIMIT` or `OFFSET` beyond
  the signed 64-bit range, which the engine reads as the negative number it
  wraps to (verified: the `LIMIT` is judged first; an `OFFSET` beside a
  `LIMIT` fails in another rule), or `nil`.
  """
  @spec window_error(non_neg_integer() | nil, non_neg_integer()) :: binary() | nil
  def window_error(limit, offset) do
    cond do
      limit != nil and limit > @int64_max ->
        failed("eliminate_limit", "LIMIT must be >= 0", limit)

      offset > @int64_max and limit != nil ->
        failed("push_down_limit", "OFFSET must be >=0", offset)

      offset > @int64_max ->
        failed("eliminate_limit", "OFFSET must be >=0", offset)

      true ->
        nil
    end
  end

  @spec failed(binary(), binary(), non_neg_integer()) :: binary()
  defp failed(rule, message, value) do
    "Optimizer rule '#{rule}' failed\ncaused by\n" <>
      "Error during planning: #{message}, '#{value - @two_64}' was provided"
  end

  @doc """
  The measurements `LIMIT` and `OFFSET` keep. With a `WHERE` and an `OFFSET`
  but no `LIMIT` the engine keeps none (verified, whatever the offset past
  zero and however many measurements match).
  """
  @spec measurement_window([binary()], map()) :: [binary()]
  def measurement_window(_names, %{where: where, limit: nil, offset: offset})
      when where != nil and offset > 0,
      do: []

  def measurement_window(names, %{limit: limit, offset: offset}),
    do: window(names, limit, offset)

  @doc "`LIMIT` and `OFFSET` over a list: the offset is dropped first, then the limit taken."
  @spec window([term()], non_neg_integer() | nil, non_neg_integer()) :: [term()]
  def window(items, limit, offset) do
    dropped = Enum.drop(items, offset)
    if limit, do: Enum.take(dropped, limit), else: dropped
  end

  @doc """
  The rows of `SHOW RETENTION POLICIES` for databases: each has the one policy
  `autogen`, whose duration is the database's retention as the engine prints it
  (`0s` for a database without one).
  """
  @spec retention_rows([{binary(), Retention.t()}]) :: [map()]
  def retention_rows(databases) do
    Enum.map(databases, fn {database, retention} ->
      %{
        "iox::database" => database,
        "name" => "autogen",
        "duration" => Retention.format(retention)
      }
    end)
  end
end
