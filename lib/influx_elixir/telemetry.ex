defmodule InfluxElixir.Telemetry do
  @moduledoc """
  Telemetry event emission for write and query operations.

  ## Events

  ### Write Events
  - `[:influx_elixir, :write, :start]` — emitted before a write
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{database: binary(), point_count: integer(), bytes: integer()}`

  - `[:influx_elixir, :write, :stop]` — emitted after a successful write
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{database: binary(), point_count: integer(), bytes: integer(),
        compressed_bytes: integer()}`

  - `[:influx_elixir, :write, :exception]` — emitted on write failure
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{database: binary(), kind: atom(), reason: term(), stacktrace: list()}`

  ### Query Events
  - `[:influx_elixir, :query, :start]` — emitted before a query
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{database: binary(), transport: atom()}`

  - `[:influx_elixir, :query, :stop]` — emitted after a successful query
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{database: binary(), transport: atom(), row_count: integer()}`

  - `[:influx_elixir, :query, :exception]` — emitted on query failure
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{database: binary(), transport: atom(), kind: atom(), reason: term(),
        stacktrace: list()}`

  ## Usage

  Attach handlers using `:telemetry.attach/4` or `:telemetry.attach_many/4`:

      :telemetry.attach(
        "my-handler",
        [:influx_elixir, :write, :stop],
        fn _event, measurements, metadata, _config ->
          Logger.info("Write completed in \#{measurements.duration}ns",
            database: metadata.database
          )
        end,
        nil
      )

  To wrap operations automatically, use the span helpers:

      InfluxElixir.Telemetry.span_write(%{database: "mydb", point_count: 1, bytes: 42},
        fn -> do_write() end
      )
  """

  @write_event [:influx_elixir, :write]
  @query_event [:influx_elixir, :query]

  # ---------- Span helpers ----------

  @doc """
  Wraps a write operation with telemetry start, stop, and exception events.

  Emits `[:influx_elixir, :write, :start]` before calling `fun`, then either
  `[:influx_elixir, :write, :stop]` on success or `[:influx_elixir, :write, :exception]`
  on failure. Re-raises any exception after emitting the exception event.

  ## Parameters

    * `metadata` - map with at minimum `:database`, `:point_count`, and `:bytes` keys
    * `fun` - zero-arity function that performs the write

  ## Examples

      InfluxElixir.Telemetry.span_write(
        %{database: "mydb", point_count: 3, bytes: 128},
        fn -> Writer.write(conn, line_protocol) end
      )
  """
  @spec span_write(map(), (-> result)) :: result when result: term()
  def span_write(metadata, fun) do
    :telemetry.span(@write_event, metadata, fn ->
      result = fun.()
      {result, metadata}
    end)
  end

  @doc """
  Wraps a query operation with telemetry start, stop, and exception events.

  Emits `[:influx_elixir, :query, :start]` before calling `fun`, then either
  `[:influx_elixir, :query, :stop]` on success or `[:influx_elixir, :query, :exception]`
  on failure. Re-raises any exception after emitting the exception event.

  ## Parameters

    * `metadata` - map with at minimum `:database` and `:transport` keys
    * `fun` - zero-arity function that performs the query

  ## Examples

      InfluxElixir.Telemetry.span_query(
        %{database: "mydb", transport: :http},
        fn -> SQL.query(conn, "SELECT * FROM cpu") end
      )
  """
  @spec span_query(map(), (-> result)) :: result when result: term()
  def span_query(metadata, fun) do
    :telemetry.span(@query_event, metadata, fn ->
      result = fun.()
      {result, metadata}
    end)
  end

  # ---------- Manual write events ----------

  @doc """
  Emits the `[:influx_elixir, :write, :start]` telemetry event.

  ## Parameters

    * `metadata` - map with `:database`, `:point_count`, and `:bytes` keys

  ## Examples

      InfluxElixir.Telemetry.write_start(%{database: "mydb", point_count: 1, bytes: 42})
  """
  @spec write_start(map()) :: :ok
  def write_start(metadata) do
    :telemetry.execute(
      @write_event ++ [:start],
      %{system_time: System.monotonic_time()},
      metadata
    )
  end

  @doc """
  Emits the `[:influx_elixir, :write, :stop]` telemetry event.

  ## Parameters

    * `duration` - elapsed time in native units (from `System.monotonic_time/0`)
    * `metadata` - map with `:database`, `:point_count`, `:bytes`, and
      `:compressed_bytes` keys

  ## Examples

      start = System.monotonic_time()
      # ... perform write ...
      InfluxElixir.Telemetry.write_stop(System.monotonic_time() - start,
        %{database: "mydb", point_count: 1, bytes: 42, compressed_bytes: 30}
      )
  """
  @spec write_stop(integer(), map()) :: :ok
  def write_stop(duration, metadata) do
    :telemetry.execute(
      @write_event ++ [:stop],
      %{duration: duration},
      metadata
    )
  end

  @doc """
  Emits the `[:influx_elixir, :write, :exception]` telemetry event.

  ## Parameters

    * `duration` - elapsed time in native units (from `System.monotonic_time/0`)
    * `metadata` - map with `:database`, `:kind`, `:reason`, and `:stacktrace` keys

  ## Examples

      start = System.monotonic_time()
      try do
        Writer.write(conn, data)
      rescue
        e ->
          InfluxElixir.Telemetry.write_exception(
            System.monotonic_time() - start,
            %{database: "mydb", kind: :error, reason: e, stacktrace: __STACKTRACE__}
          )
          reraise e, __STACKTRACE__
      end
  """
  @spec write_exception(integer(), map()) :: :ok
  def write_exception(duration, metadata) do
    :telemetry.execute(
      @write_event ++ [:exception],
      %{duration: duration},
      metadata
    )
  end

  # ---------- Manual query events ----------

  @doc """
  Emits the `[:influx_elixir, :query, :start]` telemetry event.

  ## Parameters

    * `metadata` - map with `:database` and `:transport` keys

  ## Examples

      InfluxElixir.Telemetry.query_start(%{database: "mydb", transport: :http})
  """
  @spec query_start(map()) :: :ok
  def query_start(metadata) do
    :telemetry.execute(
      @query_event ++ [:start],
      %{system_time: System.monotonic_time()},
      metadata
    )
  end

  @doc """
  Emits the `[:influx_elixir, :query, :stop]` telemetry event.

  ## Parameters

    * `duration` - elapsed time in native units (from `System.monotonic_time/0`)
    * `metadata` - map with `:database`, `:transport`, and `:row_count` keys

  ## Examples

      start = System.monotonic_time()
      # ... perform query ...
      InfluxElixir.Telemetry.query_stop(System.monotonic_time() - start,
        %{database: "mydb", transport: :http, row_count: 42}
      )
  """
  @spec query_stop(integer(), map()) :: :ok
  def query_stop(duration, metadata) do
    :telemetry.execute(
      @query_event ++ [:stop],
      %{duration: duration},
      metadata
    )
  end

  @doc """
  Emits the `[:influx_elixir, :query, :exception]` telemetry event.

  ## Parameters

    * `duration` - elapsed time in native units (from `System.monotonic_time/0`)
    * `metadata` - map with `:database`, `:transport`, `:kind`, `:reason`, and
      `:stacktrace` keys

  ## Examples

      start = System.monotonic_time()
      try do
        SQL.query(conn, sql)
      rescue
        e ->
          InfluxElixir.Telemetry.query_exception(
            System.monotonic_time() - start,
            %{database: "mydb", transport: :http, kind: :error,
              reason: e, stacktrace: __STACKTRACE__}
          )
          reraise e, __STACKTRACE__
      end
  """
  @spec query_exception(integer(), map()) :: :ok
  def query_exception(duration, metadata) do
    :telemetry.execute(
      @query_event ++ [:exception],
      %{duration: duration},
      metadata
    )
  end
end
