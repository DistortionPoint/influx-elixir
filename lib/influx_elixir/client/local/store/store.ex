defmodule InfluxElixir.Client.Local.Store do
  @moduledoc false
  # The ETS store behind `InfluxElixir.Client.Local`: the one module that
  # knows the key layout.
  #
  # One `:ordered_set` per instance, `:public` so `async: true` tests can
  # write from any process, with `write_concurrency` so writers do not queue
  # on one lock. Every mutation is an insert or delete of its own keys (a
  # payload's points go in as one batched insert), so concurrent writers —
  # tests sharing a database, `BatchWriter` flushes racing direct writes —
  # never read-modify-write a shared value and no write is lost:
  #
  #   * `{:database, name}` => `true`
  #   * `{:retention, name}` => the database's retention in whole seconds, present only
  #     for a database created with one (see `Retention`)
  #   * `{:bucket, name}` => `%{retention: seconds}`
  #   * `{:token, name}` => the token map, and `:token_id` => the last id given
  #     (a token is created by one insert of its full map, under a lock that
  #     also gives the id, so a delete can never be overwritten)
  #   * `{:point, database, measurement, seq}` => the point — `seq` is a
  #     monotonic integer, so points scan in insertion order
  #   * `{:series_time, database, measurement, timestamp, tags}` — one per
  #     point written; a second write of the same key adds
  #   * `{:chunk, database, measurement, index}` — a database with a retention
  #     has one for each 10-minute chunk (see `Retention`) it was written to
  #   * `{:duplicates, database, measurement}` — reads merge that
  #     measurement's duplicate points (same tags and time) only when this
  #     marker exists
  #   * `{:column, database, measurement, column}` => the column's kind
  #     (`iox::column_type::tag` or `iox::column_type::field::<type>`), fixed
  #     by the first write that names the column
  #   * `{:lock, resource}` => the process holding that resource's lock, for
  #     as long as it runs the one operation that needs it (database limit,
  #     token ids)
  #
  # The store is policy-free: what a write may contain, which errors the
  # engine returns and how a query reads rows live in `Client.Local` and the
  # modules it delegates to.

  alias InfluxElixir.Client.Local.Retention

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
    table = :ets.new(:influx_local, [:ordered_set, :public, write_concurrency: true])
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

  # Registers a database (idempotent).
  @spec put_database(t(), binary()) :: true
  defp put_database(table, name), do: :ets.insert(table, {{:database, name}, true})

  @doc """
  Registers a database after `check` approves it, atomically: `check` is
  called with the registered databases while no other process creates one,
  so a limit such as Core's five cannot be passed by concurrent first
  writes (each would have seen four). A database that exists is `:ok`
  without taking the lock, and keeps the retention it has: the engine's 409
  changes nothing. `check` returns `:ok` or `{:error, reason}`. `retention`
  is the new database's, in whole seconds, or `nil` for none.
  """
  @spec create_database(
          t(),
          binary(),
          (Enumerable.t(binary()) -> :ok | {:error, term()}),
          Retention.t()
        ) :: :ok | {:error, term()}
  def create_database(table, name, check, retention \\ nil) do
    if database?(table, name) do
      :ok
    else
      with_lock(table, :databases, fn ->
        with :ok <- check.(databases(table)) do
          # The retention first: a write that finds the database must find its retention too.
          put_retention(table, name, retention)
          put_database(table, name)
          :ok
        end
      end)
    end
  end

  @spec put_retention(t(), binary(), Retention.t()) :: true
  defp put_retention(_table, _name, nil), do: true
  defp put_retention(table, name, seconds), do: :ets.insert(table, {{:retention, name}, seconds})

  @doc "A database's retention in whole seconds, or `nil` when it has none."
  @spec retention(t(), binary()) :: Retention.t()
  def retention(table, name) do
    case :ets.lookup(table, {:retention, name}) do
      [{_key, seconds}] -> seconds
      [] -> nil
    end
  end

  # A lock on one store's resource: a key naming its holder, taken by one
  # `insert_new`, so it is atomic, belongs to this store alone and a waiter
  # retries at once instead of backing off for as long as a node-wide lock
  # would make it. The holder deletes its key when the function returns or
  # raises; a key left by a holder that died is deleted, as that exact
  # object, by the next waiter that finds the holder dead. A waiter waits
  # without bound while a live holder runs, and the lock is not re-entrant:
  # a holder that asks for its own lock again raises instead of spinning.
  @spec with_lock(t(), atom(), (-> result)) :: result when result: term()
  defp with_lock(table, resource, fun) do
    key = {:lock, resource}
    acquire(table, key)

    try do
      fun.()
    after
      :ets.delete_object(table, {key, self()})
    end
  end

  @spec acquire(t(), {:lock, atom()}) :: :ok
  defp acquire(table, key) do
    if :ets.insert_new(table, {key, self()}) do
      :ok
    else
      with [{^key, holder} = held] <- :ets.lookup(table, key),
           :ok <- not_self(holder, key),
           false <- Process.alive?(holder) do
        :ets.delete_object(table, held)
      end

      receive do
      after
        1 -> acquire(table, key)
      end
    end
  end

  @spec not_self(pid(), {:lock, atom()}) :: :ok
  defp not_self(holder, {:lock, resource}) when holder == self(),
    do:
      raise(
        "Client.Local.Store: the #{resource} lock is already held by this process; " <>
          "a critical section cannot start another that takes it"
      )

  defp not_self(_holder, _key), do: :ok

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

  It takes the lock that `create_database/4` takes: a database created by another
  process while this one removes the data of an earlier one of its name would otherwise lose
  its retention and the points it was written.
  """
  @spec drop_database(t(), binary()) :: :ok | :error
  def drop_database(table, name) do
    with_lock(table, :databases, fn ->
      if database?(table, name) do
        # The database goes first, so no reader finds it while its data is being removed.
        :ets.delete(table, {:database, name})
        delete_data(table, name)
        :ets.delete(table, {:retention, name})
        :ok
      else
        :error
      end
    end)
  end

  # Everything written to a database or bucket: points, schema, the series
  # index and the duplicate markers.
  @spec delete_data(t(), binary()) :: true
  defp delete_data(table, name) do
    :ets.match_delete(table, {{:point, name, :_, :_}, :_})
    :ets.match_delete(table, {{:column, name, :_, :_}, :_})
    :ets.match_delete(table, {{:series_time, name, :_, :_, :_}})
    :ets.match_delete(table, {{:duplicates, name, :_}})
    :ets.match_delete(table, {{:chunk, name, :_, :_}})
  end

  @doc "Registers a bucket with its metadata (replacing any earlier one)."
  @spec put_bucket(t(), binary(), map()) :: true
  def put_bucket(table, name, meta), do: :ets.insert(table, {{:bucket, name}, meta})

  @doc "Whether a bucket is registered."
  @spec bucket?(t(), binary()) :: boolean()
  def bucket?(table, name), do: :ets.member(table, {:bucket, name})

  @doc "A bucket's metadata, or `nil` when it is not registered."
  @spec bucket(t(), binary()) :: map() | nil
  def bucket(table, name) do
    case :ets.lookup(table, {:bucket, name}) do
      [{_key, meta}] -> meta
      [] -> nil
    end
  end

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
      delete_data(table, name)
      :ok
    else
      :error
    end
  end

  @doc """
  Creates the token named `name`: `build` is called with the next id and
  returns the token map, which is stored by one `insert_new`. `{:ok, token}`,
  or `:exists` when the name is taken, which spends no id (as on the
  engine). The operator token `_admin` (id 0) always exists.

  The id is chosen, and the name checked, under a lock so that no id is
  spent on a duplicate; the token goes in whole, never as a placeholder to
  be filled in later, so a `delete_token/2` can never be overwritten and
  bring the token back.
  """
  @spec create_token(t(), binary(), (pos_integer() -> map())) :: {:ok, map()} | :exists
  def create_token(_table, "_admin", _build), do: :exists

  def create_token(table, name, build) do
    with_lock(table, :tokens, fn ->
      id = last_token_id(table) + 1
      token = build.(id)

      if :ets.insert_new(table, {{:token, name}, token}) do
        :ets.insert(table, {:token_id, id})
        {:ok, token}
      else
        :exists
      end
    end)
  end

  @spec last_token_id(t()) :: non_neg_integer()
  defp last_token_id(table) do
    case :ets.lookup(table, :token_id) do
      [{:token_id, id}] -> id
      [] -> 0
    end
  end

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
  Stores a payload's points as written, each its own object, in one batched
  insert. A point without a timestamp gets the server's time here as a
  fallback; `Client.Local.write/3` stamps a write's untimed lines itself,
  all with one time, as the engines do.

  Concurrent writers never read-modify-write a shared value, so no write is
  lost. A series and time already written, by this payload or another
  writer, marks the measurement `duplicates` so reads merge it. The payload's
  own repeats are found with a map and the keys it adds are claimed by one
  `insert_new`, which is all-or-nothing: only when another writer holds one
  of them are the keys claimed singly to find which.
  """
  @spec store_points(t(), binary(), [point()]) :: true
  def store_points(table, database, points) do
    stamped = Enum.map(points, &assign_default_timestamp/1)

    keys =
      for point <- stamped,
          do: {:series_time, database, point.measurement, point.timestamp, point.tags}

    unique = :maps.from_keys(keys, true)

    {claimed, repeated} =
      if map_size(unique) == length(keys),
        do: {keys, []},
        else: {Map.keys(unique), repeated_measurements(keys)}

    taken = claim_series(table, claimed)

    markers = for m <- Enum.uniq(repeated ++ taken), do: {{:duplicates, database, m}}
    :ets.insert(table, markers)
    mark_chunks(table, database, stamped)

    :ets.insert(
      table,
      for point <- stamped do
        seq = :erlang.unique_integer([:monotonic, :positive])
        {{:point, database, point.measurement, seq}, point}
      end
    )
  end

  # The points of a measurement (`:_` for all of them) that a query sees.
  # Without a retention they are all of them, and so they are when no chunk
  # written to reaches back to the cut-off: the markers of the chunks are few,
  # the points are not read to find out.
  @spec visible_points(t(), binary(), binary() | :_) :: [point()]
  defp visible_points(table, database, measurement) do
    all = [{{{:point, database, measurement, :_}, :"$1"}, [], [:"$1"]}]

    case retention(table, database) do
      nil ->
        :ets.select(table, all)

      seconds ->
        now = now_ns()
        oldest = Retention.oldest_chunk(Retention.cutoff(seconds, now))
        old = [{{{:chunk, database, measurement, :"$1"}}, [{:"=<", :"$1", oldest}], [true]}]

        if :ets.select_count(table, old) == 0,
          do: :ets.select(table, all),
          else: table |> :ets.select(all) |> Retention.visible(seconds, now)
    end
  end

  # A database with a retention keeps a marker for each chunk (see
  # `Retention`) it holds points in, which only tells reads that no point can
  # have expired. A marker outlives the points deleted from its chunk; a
  # database without a retention keeps none.
  @spec mark_chunks(t(), binary(), [point()]) :: true
  defp mark_chunks(table, database, points) do
    if retention(table, database) do
      markers =
        for {measurement, index} <- Retention.chunks(points),
            do: {{:chunk, database, measurement, index}}

      :ets.insert(table, markers)
    else
      true
    end
  end

  # The measurements of the series keys that occur more than once.
  @spec repeated_measurements([tuple()]) :: [binary()]
  defp repeated_measurements(keys) do
    {_seen, repeated} =
      Enum.reduce(keys, {%{}, []}, fn key, {seen, repeated} ->
        if is_map_key(seen, key),
          do: {seen, [elem(key, 2) | repeated]},
          else: {Map.put(seen, key, true), repeated}
      end)

    repeated
  end

  # Claims series keys; returns the measurements of the keys another writer
  # already held.
  @spec claim_series(t(), [tuple()]) :: [binary()]
  defp claim_series(table, keys) do
    if :ets.insert_new(table, for(key <- keys, do: {key})) do
      []
    else
      for key <- keys, not :ets.insert_new(table, {key}), do: elem(key, 2)
    end
  end

  @spec assign_default_timestamp(point()) :: point()
  defp assign_default_timestamp(%{timestamp: nil} = point),
    do: %{point | timestamp: now_ns()}

  defp assign_default_timestamp(point), do: point

  @doc """
  The database's measurements, sorted by name: the ones with a table,
  which a write creates by registering its columns. They are read from the
  column keys, which are few, not from the points, which are many. The
  order is the keys', alphabetical, which is how InfluxDB lists them.
  """
  @spec measurements(t(), binary()) :: [binary()]
  def measurements(table, database) do
    table
    |> :ets.select([{{{:column, database, :"$1", :_}, :_}, [], [:"$1"]}])
    |> Enum.dedup()
  end

  @doc """
  A measurement's points in insertion order, duplicates merged. InfluxDB —
  both versions, verified — treats points with the same tags and time as
  one point whose fields merge, the later write winning per field. The
  points of a database with a retention are the ones `Retention.visible/3`
  leaves.
  """
  @spec points(t(), binary(), binary()) :: [point()]
  def points(table, database, measurement) do
    points = visible_points(table, database, measurement)

    if :ets.member(table, {:duplicates, database, measurement}),
      do: merge_duplicates(points),
      else: points
  end

  @doc """
  The points of a database, duplicates merged: every measurement's with
  `:all`, or only the listed measurements' (a query that names them need
  not read the rest).
  """
  @spec points_in_db(t(), binary(), :all | [binary()]) :: [point()]
  def points_in_db(table, database, only \\ :all)

  def points_in_db(table, database, :all) do
    points = visible_points(table, database, :_)

    if :ets.match(table, {{:duplicates, database, :_}}, 1) == :"$end_of_table",
      do: points,
      else: merge_duplicates(points)
  end

  def points_in_db(table, database, measurements) do
    measurements
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&points(table, database, &1))
  end

  @doc """
  Deletes the points of a measurement that `match?` accepts, judged on the
  merged points as the engine sees them; every stored object behind a
  matching point is deleted by its own key, so a concurrent write is never
  lost. Returns the number of (merged) points deleted.

  The `series_time` key of a doomed point is deleted with it, which a
  writer racing the delete may have just claimed. The invariant that makes
  this safe: a writer that finds the key taken has already put the
  measurement's `duplicates` marker, which is never removed, so reads merge
  it with any point left at that series and time; one that finds the key
  gone writes a point that nothing deleted here refers to. Either way the
  point the writer stored is kept, as a write after the delete would be, and
  no point is merged with one that was deleted.
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
      :ets.delete(table, {:series_time, database, measurement, point.timestamp, point.tags})
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
