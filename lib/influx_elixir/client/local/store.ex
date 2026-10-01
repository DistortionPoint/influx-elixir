defmodule InfluxElixir.Client.Local.Store do
  @moduledoc """
  The ETS store behind `InfluxElixir.Client.Local`: the one module that
  knows the key layout.

  One `:ordered_set` per instance, `:public` so `async: true` tests can
  write from any process. Every mutation is a single insert or delete of
  its own key, so concurrent writers — tests sharing a database,
  `BatchWriter` flushes racing direct writes — never read-modify-write a
  shared value and no write is lost:

    * `{:database, name}` => `true`
    * `{:bucket, name}` => `%{retention: seconds}`
    * `{:token, name}` => the token map, and `:token_id` => the last id given
    * `{:point, database, measurement, seq}` => the point — `seq` is a
      monotonic integer, so points scan in insertion order
    * `{:series_time, database, measurement, tags, timestamp}` — one per
      point written; a second write of the same key adds
    * `{:duplicates, database, measurement}` — reads merge that
      measurement's duplicate points (same tags and time) only when this
      marker exists
    * `{:column, database, measurement, column}` => the column's kind
      (`iox::column_type::tag` or `iox::column_type::field::<type>`), fixed
      by the first write that names the column

  The store is policy-free: what a write may contain, which errors the
  engine returns and how a query reads rows live in `Client.Local` and the
  modules it delegates to.
  """

  @typedoc "A stored point."
  @type point :: InfluxElixir.Client.Local.LineProtocolParser.point()

  @typedoc "A store instance."
  @type t :: :ets.table()

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc "Creates a store with `databases` registered."
  @spec new(Enumerable.t()) :: t()
  def new(databases) do
    table = :ets.new(:influx_local, [:ordered_set, :public])
    Enum.each(databases, &put_database(table, &1))
    table
  end

  @doc """
  Deletes the store. Safe to call again: the table dies with its owner, and
  an `on_exit` callback can run after that, so a missing table is `:ok`.
  """
  @spec drop(t()) :: :ok
  def drop(table) do
    :ets.delete(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Databases, buckets, tokens
  # ---------------------------------------------------------------------------

  @doc "Registers a database (idempotent)."
  @spec put_database(t(), binary()) :: true
  def put_database(table, name), do: :ets.insert(table, {{:database, name}, true})

  @doc "Whether a database is registered."
  @spec database?(t(), binary()) :: boolean()
  def database?(table, name), do: :ets.member(table, {:database, name})

  @doc "The registered databases."
  @spec databases(t()) :: MapSet.t(binary())
  def databases(table) do
    table
    |> :ets.select([{{{:database, :"$1"}, :_}, [], [:"$1"]}])
    |> MapSet.new()
  end

  @doc """
  Drops a database with everything in it — points, schema, the
  duplicate index — so a re-created database starts empty. `:error` when
  it was not registered.
  """
  @spec drop_database(t(), binary()) :: :ok | :error
  def drop_database(table, name) do
    if database?(table, name) do
      :ets.match_delete(table, {{:point, name, :_, :_}, :_})
      :ets.match_delete(table, {{:column, name, :_, :_}, :_})
      :ets.match_delete(table, {{:series_time, name, :_, :_, :_}})
      :ets.match_delete(table, {{:duplicates, name, :_}})
      :ets.delete(table, {:database, name})
      :ok
    else
      :error
    end
  end

  @doc "Registers a bucket with its metadata (replacing any earlier one)."
  @spec put_bucket(t(), binary(), map()) :: true
  def put_bucket(table, name, meta), do: :ets.insert(table, {{:bucket, name}, meta})

  @doc "Whether a bucket is registered."
  @spec bucket?(t(), binary()) :: boolean()
  def bucket?(table, name), do: :ets.member(table, {:bucket, name})

  @doc "The buckets as `{name, meta}`, sorted by name."
  @spec buckets(t()) :: [{binary(), map()}]
  def buckets(table) do
    table
    |> :ets.select([{{{:bucket, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
  end

  @doc "Removes a bucket; `:error` when it was not registered."
  @spec delete_bucket(t(), binary()) :: :ok | :error
  def delete_bucket(table, name) do
    if bucket?(table, name) do
      :ets.delete(table, {:bucket, name})
      :ok
    else
      :error
    end
  end

  @doc """
  Claims a token name and gives it the next id, atomically: `{:ok, id}`, or
  `:exists` when the name is taken (which spends no id, as on the engine).
  The operator token `_admin` (id 0) always exists.
  """
  @spec claim_token(t(), binary()) :: {:ok, pos_integer()} | :exists
  def claim_token(_table, "_admin"), do: :exists

  def claim_token(table, name) do
    if :ets.insert_new(table, {{:token, name}, :claimed}),
      do: {:ok, :ets.update_counter(table, :token_id, 1, {:token_id, 0})},
      else: :exists
  end

  @doc "Stores a claimed token's map under its name."
  @spec put_token(t(), binary(), map()) :: true
  def put_token(table, name, token), do: :ets.insert(table, {{:token, name}, token})

  @doc "Removes the token named `name`: `:ok`, or `:error` when there is none."
  @spec delete_token(t(), binary()) :: :ok | :error
  def delete_token(table, name) do
    case :ets.take(table, {:token, name}) do
      [_token] -> :ok
      [] -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # Clock
  # ---------------------------------------------------------------------------

  @doc """
  The double's "now", in nanoseconds: used to stamp untimed points and for
  SQL and Flux `now()`. `System.os_time/1` and `System.system_time/1` can
  differ by microseconds (time warp), and a test stamps points with either;
  taking the later of the two means a point written a moment ago is never
  after `now()`, as it never is on a real server.
  """
  @spec now_ns() :: integer()
  def now_ns, do: max(System.os_time(:nanosecond), System.system_time(:nanosecond))

  # ---------------------------------------------------------------------------
  # Points
  # ---------------------------------------------------------------------------

  @doc """
  Stores a point as written, one insert of its own key. A point without a
  timestamp gets the server's time here as a fallback; `Client.Local.write/3`
  stamps a write's untimed lines itself, all with one time, as the engines
  do.

  Storing a measurement's points as one list meant every write read the
  list, prepended and wrote it back: concurrent writers overwrote each
  other (#15: 159 of 480 writes survived) and each insert copied the whole
  list. A plain insert is atomic and O(log n).
  """
  @spec store_point(t(), binary(), point()) :: true
  def store_point(table, database, point) do
    point = assign_default_timestamp(point)
    seq = :erlang.unique_integer([:monotonic, :positive])
    series_time = {:series_time, database, point.measurement, point.tags, point.timestamp}

    # A second point at the same series and time marks the measurement, so
    # reads merge only where a duplicate can exist. `insert_new` is atomic:
    # of two concurrent writers one sees the other.
    unless :ets.insert_new(table, {series_time}) do
      :ets.insert(table, {{:duplicates, database, point.measurement}})
    end

    :ets.insert(table, {{:point, database, point.measurement, seq}, point})
  end

  @spec assign_default_timestamp(point()) :: point()
  defp assign_default_timestamp(%{timestamp: nil} = point),
    do: %{point | timestamp: now_ns()}

  defp assign_default_timestamp(point), do: point

  @doc "Whether any point was written to the measurement."
  @spec measurement?(t(), binary(), binary()) :: boolean()
  def measurement?(table, database, measurement) do
    spec = [{{{:point, database, measurement, :_}, :_}, [], [true]}]
    :ets.select(table, spec, 1) != :"$end_of_table"
  end

  @doc "The database's measurements that hold points, first-written first."
  @spec measurements(t(), binary()) :: [binary()]
  def measurements(table, database) do
    table
    |> :ets.select([{{{:point, database, :"$1", :_}, :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end

  @doc """
  A measurement's points in insertion order, duplicates merged. InfluxDB —
  both versions, verified — treats points with the same tags and time as
  one point whose fields merge, the later write winning per field.
  """
  @spec points(t(), binary(), binary()) :: [point()]
  def points(table, database, measurement) do
    points = :ets.select(table, [{{{:point, database, measurement, :_}, :"$1"}, [], [:"$1"]}])

    if :ets.member(table, {:duplicates, database, measurement}),
      do: merge_duplicates(points),
      else: points
  end

  @doc "Every point in a database, duplicates merged."
  @spec points_in_db(t(), binary()) :: [point()]
  def points_in_db(table, database) do
    points = :ets.select(table, [{{{:point, database, :_, :_}, :"$1"}, [], [:"$1"]}])

    if :ets.match(table, {{:duplicates, database, :_}}, 1) == :"$end_of_table",
      do: points,
      else: merge_duplicates(points)
  end

  @doc """
  Deletes the points of a measurement that `match?` accepts, judged on the
  merged points as the engine sees them; every stored object behind a
  matching point is deleted by its own key, so a concurrent write is never
  lost. Returns the number of (merged) points deleted.
  """
  @spec delete_points(t(), binary(), binary(), (point() -> boolean())) :: non_neg_integer()
  def delete_points(table, database, measurement, match?) do
    stored = :ets.select(table, [{{{:point, database, measurement, :_}, :_}, [], [:"$_"]}])

    doomed =
      stored
      |> Enum.map(fn {_key, point} -> point end)
      |> merge_duplicates()
      |> Enum.filter(match?)
      |> MapSet.new(&{&1.tags, &1.timestamp})

    for {key, point} <- stored, MapSet.member?(doomed, {point.tags, point.timestamp}) do
      :ets.delete(table, {:series_time, database, measurement, point.tags, point.timestamp})
      :ets.delete(table, key)
    end

    MapSet.size(doomed)
  end

  # Merging is most of a query's cost at 100k points, so it runs only for a
  # measurement a duplicate was written to; a stale marker only costs a
  # merge that changes nothing. The merged point keeps the first write's
  # position.
  @spec merge_duplicates([point()]) :: [point()]
  defp merge_duplicates(points) do
    {merged, order} =
      Enum.reduce(points, {%{}, []}, fn point, {merged, order} ->
        key = {point.measurement, point.tags, point.timestamp}

        case merged do
          %{^key => earlier} ->
            later = %{earlier | fields: Map.merge(earlier.fields, point.fields)}
            {Map.put(merged, key, later), order}

          _first ->
            {Map.put(merged, key, point), [key | order]}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(merged, &1))
  end

  # ---------------------------------------------------------------------------
  # Column schema
  # ---------------------------------------------------------------------------

  @doc """
  Registers a column's kind if it is new. The first writer fixes it
  atomically (`insert_new`), so a concurrent writer never loses a column.
  Returns `:ok` when the kind matches (or was just registered) and
  `{:conflict, existing}` when the column already has another kind.
  """
  @spec register_column(t(), binary(), binary(), binary(), binary()) ::
          :ok | {:conflict, binary()}
  def register_column(table, database, measurement, column, kind) do
    key = {:column, database, measurement, column}

    if :ets.insert_new(table, {key, kind}) do
      :ok
    else
      case :ets.lookup(table, key) do
        [{^key, ^kind}] -> :ok
        [{^key, existing}] -> {:conflict, existing}
      end
    end
  end

  @doc "A column's registered kind, or `nil` — a read that registers nothing."
  @spec column_kind(t(), binary(), binary(), binary()) :: binary() | nil
  def column_kind(table, database, measurement, column) do
    case :ets.lookup(table, {:column, database, measurement, column}) do
      [{_key, kind}] -> kind
      [] -> nil
    end
  end

  @doc "Whether the measurement has any column registered (the table exists)."
  @spec table?(t(), binary(), binary()) :: boolean()
  def table?(table, database, measurement),
    do: :ets.match(table, {{:column, database, measurement, :_}, :_}, 1) != :"$end_of_table"

  @doc "Every column in a database as `{measurement, column, kind}`, in that order."
  @spec columns(t(), binary()) :: [{binary(), binary(), binary()}]
  def columns(table, database) do
    for [measurement, column, kind] <-
          :ets.match(table, {{:column, database, :"$1", :"$2"}, :"$3"}),
        do: {measurement, column, kind}
  end

  @doc "A measurement's tag columns."
  @spec tag_columns(t(), binary(), binary()) :: MapSet.t(binary())
  def tag_columns(table, database, measurement) do
    table
    |> :ets.match({{:column, database, measurement, :"$1"}, "iox::column_type::tag"})
    |> MapSet.new(fn [column] -> column end)
  end
end
