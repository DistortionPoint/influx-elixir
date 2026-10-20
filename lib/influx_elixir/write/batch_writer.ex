defmodule InfluxElixir.Write.BatchWriter do
  @default_shutdown 5_000
  @default_stats_timeout 5_000

  # The options, validated by `start_link/1`; the moduledoc lists them from
  # here, so the two cannot drift.
  @options_schema NimbleOptions.new!(
                    connection: [
                      type: :any,
                      required: true,
                      doc:
                        "connection term passed to `InfluxElixir.Write.Writer`, or the name " <>
                          "of a registered connection, resolved on every flush"
                    ],
                    database: [
                      type: :string,
                      doc: "database every flush writes to. A `:database` in `:write_opts` wins."
                    ],
                    batch_size: [
                      type: :pos_integer,
                      default: 5_000,
                      doc:
                        "lines a flush is made of: the buffer is written when it holds this " <>
                          "many lines (a payload of several lines counts them all; one write " <>
                          "is never split, so a flush may hold more)"
                    ],
                    flush_interval_ms: [
                      type: :pos_integer,
                      default: 1_000,
                      doc: "timer interval in milliseconds"
                    ],
                    jitter_ms: [
                      type: :non_neg_integer,
                      default: 0,
                      doc: "random jitter added to the flush timer and retry backoff"
                    ],
                    max_retries: [
                      type: :non_neg_integer,
                      default: 3,
                      doc:
                        "retry attempts for transport errors, 5xx, 408 and 429; every other " <>
                          "error is permanent and not retried"
                    ],
                    base_retry_delay_ms: [
                      type: :non_neg_integer,
                      default: 100,
                      doc: "base of the exponential backoff: attempt N waits about `base * 2^N`"
                    ],
                    max_retry_delay_ms: [
                      type: :pos_integer,
                      default: 30_000,
                      doc:
                        "cap on the exponential backoff, before jitter: no retry waits " <>
                          "longer than this (plus `:jitter_ms`)"
                    ],
                    no_sync: [
                      type: :boolean,
                      default: false,
                      doc:
                        "when `true`, `write_sync/3` behaves like `write/3`. Not InfluxDB 3's " <>
                          "`no_sync` write parameter: pass that, like `accept_partial: false`, " <>
                          "in `:write_opts`."
                    ],
                    write_opts: [
                      type: :keyword_list,
                      default: [],
                      doc:
                        "options for `InfluxElixir.Write.Writer.write/3` on every flush " <>
                          "(`:database`, `:timeout`, `:precision`, ...). A `Point`'s " <>
                          "`DateTime` timestamp is encoded in its `:precision`; an integer " <>
                          "timestamp must already be in that unit."
                    ],
                    client: [
                      type: :atom,
                      doc:
                        "client module to write with instead of the configured one " <>
                          "(`InfluxElixir.Client.impl/0`)"
                    ],
                    name: [type: :any, doc: "a `GenServer` name to register the writer under"],
                    shutdown: [
                      type: {:or, [:non_neg_integer, {:in, [:infinity, :brutal_kill]}]},
                      default: @default_shutdown,
                      doc:
                        "how long a supervisor waits for the final flush when it stops the " <>
                          "writer (OTP's default for workers); see \"Shutdown\""
                    ]
                  )

  @moduledoc """
  GenServer-based batch writer with configurable flush intervals,
  batch sizes, retry with exponential backoff, and backpressure.

  Points or pre-encoded line protocol are buffered in memory and
  flushed either when the buffer reaches `batch_size` lines or when the
  `flush_interval_ms` timer fires — whichever comes first. Every flush,
  however triggered (size, timer, `flush/2`, `write_sync/3`), restarts the
  interval, so a write is never left buffered longer than one interval
  after the last flush.

  A connection started with a `batch_writer:` option has one of these; reach it
  with `InfluxElixir.write_batched/3`, `InfluxElixir.flush/2` and
  `InfluxElixir.stats/2`.

  ## Options

  Validated by `start_link/1`, which returns
  `{:error, %NimbleOptions.ValidationError{}}` for an unknown key or a
  value of the wrong type — a `batch_size: 0` used to refuse every write
  as `:buffer_full`, and a misspelt key was silently ignored.

  #{NimbleOptions.docs(@options_schema)}

  ## What can be written

  `write/3` and `write_sync/3` take a `InfluxElixir.Write.Point`, a list of them,
  or line protocol (a binary or iodata). The payload is encoded in the *caller*, so
  a point no server accepts is the caller's `{:error, reason}` (the one
  `InfluxElixir.Write.LineProtocol.encode/2` gives) and never reaches, or crashes, the
  writer. Anything else is `{:error, {:invalid_payload, payload}}`, and the writer
  keeps running.

  A `Point` is encoded for the connection's `api_version` and the flushes' `:precision`.
  One without a `:timestamp` is stamped with the time of the call (a `DateTime` in that
  precision), not left for the server to stamp: a retry re-sends the same bytes, and
  a server that committed a write which then timed out would otherwise store the
  retried points a second time, at a later time. Pre-encoded line protocol without
  timestamps is still stamped by the server, on every attempt.

  ## Requests

  The HTTP requests are made by a process of their own, one at a time and in the
  order the batches were taken, and the writer handles the answer as a message. A batch
  waiting out its retry delay is not in that order: an explicit `flush/2` or
  `write_sync/3` meanwhile is written first, so a point it rewrites (same series and
  time) can be overwritten by the older batch's retry. The
  writer therefore answers `write/3`, `flush/2` and `stats/2` while a request is
  in flight, whatever the server's speed, and a `write/3` that completes a batch
  returns at once instead of waiting for the request.

  ## Backpressure

  The buffer is counted in lines. While any batch is in flight or being retried,
  the automatic flushes (batch size reached, timer fired) wait for every batch to
  finish instead of starting another against a server that is already failing;
  writes keep buffering meanwhile. Once the buffer holds `10 * batch_size` lines,
  `write/3` and `write_sync/3` return `{:error, :buffer_full}` until the
  last batch ends, so the body of a flush is bounded by `10 * batch_size` lines plus
  the one write that crossed the bound (a write is never split). An explicit
  `flush/2`, and `write_sync/3` without `:no_sync`, always take the buffer
  immediately — their request waits only for the request in flight. When the last
  batch ends the deferred buffer is flushed if it has reached `batch_size`;
  otherwise the timer takes it.

  ## Shutdown

  The writer traps exits, so a supervisor stopping it — application
  shutdown, `InfluxElixir.remove_connection/1` — runs `terminate/2`, which
  waits for the request in flight, then writes every batch that is still
  waiting to be retried and then the buffer, once each
  and in the order they were written, and answers any `write_sync/3`
  caller waiting on them. A write that fails there is logged and dropped; it is
  not counted in `stats/2`, which nobody can read any more. The supervisor kills the
  writer if that takes longer than `:shutdown`.

  ## Retry Policy

  A write's outcome is `:ok`, retryable or permanent, by one rule:

    * retryable: a transport error (`{:connection_error, _}`, `:pool_timeout`,
      `:timeout`), a 5xx status, 408 (request timeout) and 429 (too many requests);
    * permanent: everything else — any other status, `{:invalid_connection, _}`,
      `:no_database_specified`, `{:invalid_*, _}`, `{:unencodable_body, _}`,
      `{:invalid_options, _}`. The same batch would fail again; it is discarded
      and logged at once, whatever `max_retries` is.

  Retryable errors are retried with exponential backoff (`base_retry_delay_ms * 2^attempt`,
  capped at `max_retry_delay_ms`) and optional jitter. Retries are non-blocking: the
  writer keeps answering between attempts and during them. A `write_sync/3` caller whose
  batch is being retried is answered with that chain's final result; a `flush/2`
  caller is answered when its batch's first attempt has finished.

  ## Stats

  Call `stats/2` to retrieve a map with `:total_writes`, `:total_errors`,
  and `:total_bytes` counters. A batch is counted once, when it has been written or
  has failed for good.
  """

  use GenServer
  require Logger

  alias InfluxElixir.Client.Options
  alias InfluxElixir.Connection
  alias InfluxElixir.Write.{LineProtocol, Point, Writer}

  @backpressure_multiplier 10

  # GenServer.call wait-bound defaults. Generous enough to cover one HTTP
  # write at the default `Client.HTTP.@default_timeout` (30s). `write_sync`
  # waits through the full retry chain so its default scales accordingly.
  # All three are overridable per call.
  @default_write_timeout 60_000
  @default_flush_timeout 60_000
  @default_write_sync_timeout 300_000

  @type stat_key :: :total_writes | :total_errors | :total_bytes
  @type stats :: %{stat_key() => non_neg_integer()}

  # A batch is a chain: its bytes, and the `write_sync/3` caller to answer with its final
  # result. An attempt at a chain is a job on the queue, behind the one in flight.
  @typep chain :: {binary(), GenServer.from() | nil}
  @typep job ::
           {:attempt, integer(), non_neg_integer(), GenServer.from() | nil}
           | {:barrier, GenServer.from()}
  @typep attempt :: %{
           ref: reference(),
           monitor: reference(),
           chain: integer(),
           attempt: non_neg_integer(),
           notify: GenServer.from() | nil
         }

  defstruct [
    :connection,
    :database,
    :timer_ref,
    :inflight,
    # Set from the validated options by init/1.
    :batch_size,
    :flush_interval_ms,
    :jitter_ms,
    :max_retries,
    :base_retry_delay_ms,
    :max_retry_delay_ms,
    :no_sync,
    :write_opts,
    buffer: [],
    buffer_size: 0,
    stats: %{total_writes: 0, total_errors: 0, total_bytes: 0},
    chains: %{},
    queue: :queue.new()
  ]

  @type t :: %__MODULE__{
          buffer: [binary()],
          buffer_size: non_neg_integer(),
          connection: term(),
          database: binary() | nil,
          batch_size: pos_integer(),
          flush_interval_ms: pos_integer(),
          jitter_ms: non_neg_integer(),
          max_retries: non_neg_integer(),
          base_retry_delay_ms: non_neg_integer(),
          max_retry_delay_ms: pos_integer(),
          no_sync: boolean(),
          write_opts: keyword(),
          stats: stats(),
          timer_ref: reference() | nil,
          inflight: attempt() | nil,
          chains: %{integer() => chain()},
          queue: :queue.queue(job())
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a BatchWriter GenServer linked to the calling process.

  ## Options

  See module documentation for available options.

  ## Examples

      {:ok, pid} = InfluxElixir.Write.BatchWriter.start_link(connection: conn, database: "mydb")
  """
  @spec start_link(keyword()) ::
          GenServer.on_start() | {:error, NimbleOptions.ValidationError.t()}
  def start_link(opts) do
    with {:ok, opts} <- validate_opts(opts) do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end
  end

  @spec validate_opts(term()) ::
          {:ok, keyword()} | {:error, NimbleOptions.ValidationError.t()}
  defp validate_opts(opts) do
    if Options.keyword?(opts) do
      NimbleOptions.validate(opts, @options_schema)
    else
      {:error,
       %NimbleOptions.ValidationError{
         message: "expected the options to be a keyword list, got: #{inspect(opts)}"
       }}
    end
  end

  @doc """
  The child spec a supervisor starts the writer with; `:shutdown` in
  `opts` sets how long it waits for the final flush.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    shutdown =
      if Options.keyword?(opts),
        do: Keyword.get(opts, :shutdown, @default_shutdown),
        else: @default_shutdown

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: shutdown
    }
  end

  @doc """
  Buffers a point, a list of points or line protocol for writing.

  Returns as soon as the payload is buffered; a payload that completes a batch
  starts the batch's request in a process of its own and does not wait for it. The
  `timeout` argument bounds the `GenServer.call/3` wait — defaults to
  `#{@default_write_timeout}` ms.

  A `Point` (or list of them) is encoded here, in the caller, for the writer's
  `:precision` and its connection's `api_version`; that costs a call to the writer
  for those two values. A point with no `:timestamp` is stamped with the time of
  this call (see "What can be written" in the module documentation).

  ## Parameters

    * `server` - PID or registered name of the BatchWriter
    * `payload` - a `InfluxElixir.Write.Point.t()`, a list of them, or line protocol
      (a binary or iodata)
    * `timeout` - `GenServer.call` wait bound in ms (default: `60_000`)

  ## Returns

    * `:ok` - the payload is buffered
    * `{:error, :buffer_full}` - see "Backpressure"
    * `{:error, reason}` - a point that cannot be encoded, or
      `{:error, {:invalid_payload, payload}}`; the writer is untouched

  ## Examples

      :ok = InfluxElixir.Write.BatchWriter.write(pid, "cpu value=1.0")
  """
  @spec write(
          GenServer.server(),
          Point.t() | [Point.t()] | iodata(),
          timeout()
        ) :: :ok | {:error, :buffer_full | term()}
  def write(server, payload, timeout \\ @default_write_timeout) do
    with {:ok, lines} <- prepare(server, payload, timeout) do
      GenServer.call(server, {:write, lines}, timeout)
    end
  end

  @doc """
  Synchronously writes a point and waits for the next flush to complete.

  Blocks until the buffered data has been flushed and the write is confirmed.
  When `no_sync: true` is configured, behaves identically to `write/3`.

  The caller waits through the full retry chain. The default `timeout`
  of `#{@default_write_sync_timeout}` ms covers up to `max_retries + 1`
  HTTP writes at the default 30s HTTP timeout plus exponential backoff.
  Override for endpoints with longer expected tail latencies.

  ## Parameters

    * `server` - PID or registered name of the BatchWriter
    * `payload` - as for `write/3`
    * `timeout` - `GenServer.call` wait bound in ms (default: `300_000`).
      Pass `:infinity` for unbounded blocking.

  ## Examples

      :ok = InfluxElixir.Write.BatchWriter.write_sync(pid, "cpu value=1.0")
  """
  @spec write_sync(
          GenServer.server(),
          Point.t() | [Point.t()] | iodata(),
          timeout()
        ) :: :ok | {:error, term()}
  def write_sync(server, payload, timeout \\ @default_write_sync_timeout) do
    with {:ok, lines} <- prepare(server, payload, timeout) do
      GenServer.call(server, {:write_sync, lines}, timeout)
    end
  end

  @doc """
  Forces an immediate flush of the buffer.

  Bounded by `timeout` (default: `#{@default_flush_timeout}` ms). Returns
  `:ok` once every request that was in flight or waiting for its turn when
  the call was made, and the one that writes the buffer, has finished its first
  attempt, whatever its outcome. Retries scheduled after a failed attempt are
  asynchronous and do NOT extend the caller's wait.

  ## Parameters

    * `server` - PID or registered name of the BatchWriter
    * `timeout` - `GenServer.call` wait bound in ms (default: `60_000`)

  ## Examples

      :ok = InfluxElixir.Write.BatchWriter.flush(pid)
  """
  @spec flush(GenServer.server(), timeout()) :: :ok
  def flush(server, timeout \\ @default_flush_timeout) do
    GenServer.call(server, :flush, timeout)
  end

  @doc """
  Returns the current stats map.

  The writer answers while a request is in flight. `timeout` (default
  `#{@default_stats_timeout}` ms) bounds the call.

  ## Keys

    * `:total_writes` - total successful write operations
    * `:total_errors` - total failed write operations
    * `:total_bytes` - total bytes flushed

  ## Examples

      {:ok, %{total_writes: _, total_errors: _, total_bytes: _}} =
        InfluxElixir.Write.BatchWriter.stats(pid)
  """
  @spec stats(GenServer.server(), timeout()) :: {:ok, stats()}
  def stats(server, timeout \\ @default_stats_timeout) do
    GenServer.call(server, :stats, timeout)
  end

  # ---------------------------------------------------------------------------
  # In the caller: the payload becomes line protocol
  # ---------------------------------------------------------------------------

  # A point no server accepts is the caller's `{:error, reason}` (as from
  # `LineProtocol.encode/2`), never a crash that loses every other caller's
  # buffered lines. Line protocol is as given; Points are encoded here, with the options
  # only the writer knows (the flushes' `:precision`, the connection's server).
  @spec prepare(GenServer.server(), term(), timeout()) :: {:ok, binary()} | {:error, term()}
  defp prepare(_server, payload, _timeout) when is_binary(payload), do: {:ok, payload}

  defp prepare(server, payload, timeout) do
    if Writer.points?(payload) do
      with {:ok, encode_opts} <- GenServer.call(server, :encode_options, timeout) do
        payload |> stamp(DateTime.utc_now()) |> LineProtocol.encode(encode_opts)
      end
    else
      case Options.iodata(payload) do
        {:ok, lines} -> {:ok, lines}
        :error -> {:error, {:invalid_payload, payload}}
      end
    end
  end

  # A point without a time gets this call's, so every attempt at it, and a retry after a
  # write the server committed, carry one time. Whatever is not a Point (an error for
  # `encode/2` to name) is left as it is.
  @spec stamp(term(), DateTime.t()) :: term()
  defp stamp([head | tail], now), do: [stamp(head, now) | stamp(tail, now)]
  defp stamp(%Point{timestamp: nil} = point, now), do: %{point | timestamp: now}
  defp stamp(other, _now), do: other

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # Without this a supervisor's shutdown kills the writer outright and
    # terminate/2 never flushes the buffer.
    Process.flag(:trap_exit, true)

    # `opts` were validated, defaults filled in, by `start_link/1`.
    state = %__MODULE__{
      connection: opts[:connection],
      database: opts[:database],
      batch_size: opts[:batch_size],
      flush_interval_ms: opts[:flush_interval_ms],
      jitter_ms: opts[:jitter_ms],
      max_retries: opts[:max_retries],
      base_retry_delay_ms: opts[:base_retry_delay_ms],
      max_retry_delay_ms: opts[:max_retry_delay_ms],
      no_sync: opts[:no_sync],
      write_opts: resolve_write_opts(opts)
    }

    {:ok, state, {:continue, :schedule_initial_flush}}
  end

  # `:database` is the writer's target unless `:write_opts` names one
  # explicitly. It used to be stored and never forwarded, so every flush
  # silently landed in the connection's default database.
  @spec resolve_write_opts(keyword()) :: keyword()
  defp resolve_write_opts(opts) do
    opts
    |> Keyword.get(:write_opts, [])
    |> put_new_opt(:database, Keyword.get(opts, :database))
    |> put_new_opt(:client, Keyword.get(opts, :client))
  end

  @spec put_new_opt(keyword(), atom(), term()) :: keyword()
  defp put_new_opt(write_opts, _key, nil), do: write_opts
  defp put_new_opt(write_opts, key, value), do: Keyword.put_new(write_opts, key, value)

  @impl GenServer
  def handle_continue(:schedule_initial_flush, state) do
    {:noreply, schedule_flush(state)}
  end

  # What a caller needs to encode a Point as this writer's flushes will send it: the
  # precision of the flushes and the server generation of its connection (InfluxDB 2 and 3
  # read a backslash differently).
  @impl GenServer
  def handle_call(:encode_options, _from, %__MODULE__{} = state) do
    options =
      state.write_opts
      |> Keyword.take([:precision])
      |> Keyword.put(:api_version, Connection.api_version(state.connection))

    {:reply, {:ok, options}, state}
  end

  def handle_call({:write, payload}, _from, %__MODULE__{} = state) do
    case admit(state, payload) do
      {:ok, state} -> {:reply, :ok, maybe_flush_on_batch(state)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:write_sync, payload}, from, %__MODULE__{} = state) do
    case admit(state, payload) do
      {:ok, %__MODULE__{no_sync: true} = state} ->
        {:reply, :ok, maybe_flush_on_batch(state)}

      # Nothing buffered, so nothing to wait for.
      {:ok, %__MODULE__{buffer_size: 0} = state} ->
        {:reply, :ok, state}

      {:ok, state} ->
        {:noreply, write_buffer(state, nil, from)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # The caller is answered when the batch that holds the buffer has had its first attempt;
  # with an empty buffer, when the requests ahead of this call have finished theirs.
  def handle_call(:flush, from, %__MODULE__{} = state) do
    cond do
      state.buffer_size > 0 -> {:noreply, write_buffer(state, from, nil)}
      state.inflight == nil -> {:reply, :ok, state}
      true -> {:noreply, enqueue(state, {:barrier, from})}
    end
  end

  def handle_call(:stats, _from, %__MODULE__{} = state) do
    {:reply, {:ok, state.stats}, state}
  end

  # The timer flush waits for in-flight and retrying batches (see "Backpressure").
  @impl GenServer
  def handle_info(:flush, %__MODULE__{chains: chains} = state) when map_size(chains) == 0 do
    if state.buffer_size > 0,
      do: {:noreply, write_buffer(state, nil, nil)},
      else: {:noreply, schedule_flush(state)}
  end

  def handle_info(:flush, %__MODULE__{} = state) do
    {:noreply, schedule_flush(state)}
  end

  # A retry timer fired: the next attempt at the chain takes its turn. Each chain keeps its
  # payload and its write_sync caller (or nil) in `chains`, so a later chain cannot answer
  # that caller by mistake and terminate/2 can still write the payload.
  def handle_info({:retry, chain, attempt}, %__MODULE__{chains: chains} = state)
      when is_map_key(chains, chain) do
    {:noreply, enqueue(state, {:attempt, chain, attempt, nil})}
  end

  # The request in flight answered.
  def handle_info(
        {:attempt, ref, result},
        %__MODULE__{inflight: %{ref: ref, monitor: monitor} = attempt} = state
      ) do
    Process.demonitor(monitor, [:flush])
    {:noreply, attempt_finished(%{state | inflight: nil}, attempt, result)}
  end

  # The request's process died without answering (the client raised).
  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %__MODULE__{inflight: %{monitor: monitor} = attempt} = state
      ) do
    result = {:error, {:write_crashed, reason}}
    {:noreply, attempt_finished(%{state | inflight: nil}, attempt, result)}
  end

  # Trapping exits delivers the exit of a linked process that is not the
  # parent (the parent's ends the writer through terminate/2); nothing
  # else is linked, and a stray message must not crash the writer and lose
  # its buffer.
  def handle_info(message, %__MODULE__{} = state) do
    Logger.debug("[BatchWriter] ignoring unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # The request in flight is waited for, then one attempt each, oldest first: the batches that
  # are still to be written, then the buffer. Retries cannot outlive the writer. The stats are
  # not updated here: nothing can read them once this returns.
  @impl GenServer
  def terminate(_reason, %__MODULE__{} = state) do
    state = await_inflight(state)

    state.chains
    |> Enum.sort()
    |> Enum.each(fn {_chain, {payload, from}} -> final_write(state, payload, from) end)

    if state.buffer_size > 0 do
      final_write(state, join(state.buffer), nil)
    end

    # Callers still waiting for a first attempt that this has just made.
    for job <- :queue.to_list(state.queue), do: reply_job(job)
    :ok
  end

  # The request in flight is not abandoned: its answer settles its batch, and a batch that
  # failed in a way a retry could mend is written once more with the others.
  @spec await_inflight(t()) :: t()
  defp await_inflight(%__MODULE__{inflight: nil} = state), do: state

  defp await_inflight(%__MODULE__{inflight: %{ref: ref, monitor: monitor} = attempt} = state) do
    result =
      receive do
        {:attempt, ^ref, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, _pid, reason} ->
          {:error, {:write_crashed, reason}}
      end

    reply_to(attempt.notify, :ok)
    state = %{state | inflight: nil}
    result = normalize(result)

    case classify(result) do
      :retryable -> state
      _settled -> settle_chain(state, attempt.chain, result)
    end
  end

  @spec settle_chain(t(), integer(), :ok | {:error, term()}) :: t()
  defp settle_chain(%__MODULE__{} = state, chain, result) do
    {{_payload, from}, chains} = Map.pop!(state.chains, chain)
    reply_to(from, result)
    %{state | chains: chains}
  end

  @spec final_write(t(), binary(), GenServer.from() | nil) :: :ok
  defp final_write(state, payload, from) do
    result =
      case Writer.write(state.connection, payload, state.write_opts) do
        {:ok, :written} ->
          :ok

        {:error, reason} = error ->
          Logger.error("[BatchWriter] Final flush failed: #{inspect(reason)}")
          error
      end

    reply_to(from, result)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # The writer admits a payload while its buffer is under the backpressure bound. What it is
  # handed is line protocol, encoded by the caller; anything else is a caller that bypassed
  # `write/3`, told so, not a crash that loses the buffer.
  @spec admit(t(), term()) :: {:ok, t()} | {:error, :buffer_full | {:invalid_payload, term()}}
  defp admit(%__MODULE__{} = state, payload) when is_binary(payload) do
    if state.buffer_size >= state.batch_size * @backpressure_multiplier,
      do: {:error, :buffer_full},
      else: {:ok, append_to_buffer(state, payload)}
  end

  defp admit(%__MODULE__{}, payload), do: {:error, {:invalid_payload, payload}}

  # The buffer counts lines, so `batch_size` and the backpressure bound bound the body of a flush.
  @spec append_to_buffer(t(), binary()) :: t()
  defp append_to_buffer(%__MODULE__{} = state, "") do
    state
  end

  defp append_to_buffer(%__MODULE__{} = state, payload) do
    %{
      state
      | buffer: [payload | state.buffer],
        buffer_size: state.buffer_size + line_count(payload)
    }
  end

  # The lines of a payload (see `Options.line_count/1`), at least one.
  @spec line_count(binary()) :: pos_integer()
  defp line_count(payload), do: max(Options.line_count(payload), 1)

  # A batch-size flush is deferred while a batch is in flight or being retried; the
  # buffer keeps filling up to the backpressure bound instead.
  @spec maybe_flush_on_batch(t()) :: t()
  defp maybe_flush_on_batch(
         %__MODULE__{buffer_size: size, batch_size: batch, chains: chains} = state
       )
       when size >= batch and map_size(chains) == 0 do
    write_buffer(state, nil, nil)
  end

  defp maybe_flush_on_batch(%__MODULE__{} = state), do: state

  # Takes the buffer as a batch: it becomes a chain, its first attempt a job on the queue.
  # `notify` is a `flush/2` caller to answer when that attempt has finished; `sync_from` a
  # `write_sync/3` caller to answer when the chain ends. Any flush that takes the buffer
  # restarts the interval, so the timer is running exactly once afterwards
  # (schedule_flush/1 cancels a pending one first).
  @spec write_buffer(t(), GenServer.from() | nil, GenServer.from() | nil) :: t()
  defp write_buffer(%__MODULE__{} = state, notify, sync_from) do
    # Monotonic, so terminate/2 can write chains in the order they began.
    chain = System.unique_integer([:monotonic])

    %{
      state
      | buffer: [],
        buffer_size: 0,
        chains: Map.put(state.chains, chain, {join(state.buffer), sync_from})
    }
    |> schedule_flush()
    |> enqueue({:attempt, chain, 0, notify})
  end

  @spec join([binary()]) :: binary()
  defp join(buffer), do: buffer |> Enum.reverse() |> Enum.join("\n")

  @spec enqueue(t(), job()) :: t()
  defp enqueue(%__MODULE__{} = state, job) do
    pump(%{state | queue: :queue.in(job, state.queue)})
  end

  # One request at a time, in the order of the queue: when none is in flight, the next
  # job starts. A barrier is answered when it reaches the front.
  @spec pump(t()) :: t()
  defp pump(%__MODULE__{inflight: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, {:barrier, from}}, queue} ->
        GenServer.reply(from, :ok)
        pump(%{state | queue: queue})

      {{:value, {:attempt, chain, attempt, notify}}, queue} ->
        state = %{state | queue: queue}

        case Map.fetch(state.chains, chain) do
          {:ok, {payload, _from}} ->
            start_attempt(state, chain, attempt, notify, payload)

          :error ->
            reply_to(notify, :ok)
            pump(state)
        end
    end
  end

  defp pump(%__MODULE__{} = state), do: state

  # The request runs in a process of its own, monitored and not linked: whatever it does
  # cannot take the writer down, and the writer's mailbox stays free while it waits.
  @spec start_attempt(t(), integer(), non_neg_integer(), GenServer.from() | nil, binary()) ::
          t()
  defp start_attempt(%__MODULE__{} = state, chain, attempt, notify, payload) do
    parent = self()
    ref = make_ref()
    connection = state.connection
    write_opts = state.write_opts

    {_pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:attempt, ref, Writer.write(connection, payload, write_opts)})
      end)

    %{
      state
      | inflight: %{ref: ref, monitor: monitor, chain: chain, attempt: attempt, notify: notify}
    }
  end

  # An attempt has finished: the chain ends (written, or failed for good) or is retried
  # later, the caller waiting for the attempt is answered, and the next job starts.
  @spec attempt_finished(t(), attempt(), term()) :: t()
  defp attempt_finished(%__MODULE__{} = state, %{chain: chain, attempt: attempt} = done, result) do
    result = normalize(result)

    state =
      case classify(result) do
        :ok ->
          finish_chain(state, chain, :ok)

        :permanent ->
          Logger.warning("[BatchWriter] permanent error — discarding batch: #{inspect(result)}")
          finish_chain(state, chain, result)

        :retryable when attempt < state.max_retries ->
          Logger.warning(
            "[BatchWriter] Write error (attempt #{attempt + 1}): " <>
              inspect(elem(result, 1))
          )

          schedule_retry(state, chain, attempt + 1)
          state

        :retryable ->
          Logger.error("[BatchWriter] Flush failed after retries: #{inspect(elem(result, 1))}")
          finish_chain(state, chain, result)
      end

    reply_to(done.notify, :ok)
    pump(state)
  end

  # The one rule for what a write's outcome means. Retryable: the server or the network may
  # answer differently next time. Permanent: the same batch would fail again — a status the
  # server gives a request that is wrong, or an error from this side (no database, a body
  # that cannot be encoded, bad options).
  @spec classify(:ok | {:error, term()}) :: :ok | :permanent | :retryable
  defp classify(:ok), do: :ok
  defp classify({:error, {:connection_error, _reason}}), do: :retryable
  defp classify({:error, reason}) when reason in [:pool_timeout, :timeout], do: :retryable
  defp classify({:error, %{status: status}}) when status in 500..599, do: :retryable
  defp classify({:error, %{status: status}}) when status in [408, 429], do: :retryable
  defp classify({:error, _reason}), do: :permanent

  @spec normalize(term()) :: :ok | {:error, term()}
  defp normalize({:ok, _written}), do: :ok
  defp normalize({:error, _reason} = error), do: error
  defp normalize(other), do: {:error, {:unexpected_result, other}}

  # Ends a chain: answers its write_sync caller, then — once no chain is left —
  # flushes whatever accumulated meanwhile if it has reached batch_size (the timer takes
  # anything smaller).
  @spec finish_chain(t(), integer(), :ok | {:error, term()}) :: t()
  defp finish_chain(%__MODULE__{} = state, chain, result) do
    {{payload, from}, chains} = Map.pop!(state.chains, chain)
    reply_to(from, result)

    maybe_flush_on_batch(%{
      state
      | stats: update_stats(state.stats, result, byte_size(payload)),
        chains: chains
    })
  end

  @spec update_stats(stats(), :ok | {:error, term()}, non_neg_integer()) ::
          stats()
  defp update_stats(stats, :ok, bytes) do
    stats
    |> Map.update!(:total_writes, &(&1 + 1))
    |> Map.update!(:total_bytes, &(&1 + bytes))
  end

  defp update_stats(stats, {:error, _reason}, _bytes) do
    Map.update!(stats, :total_errors, &(&1 + 1))
  end

  @spec reply_to(GenServer.from() | nil, term()) :: :ok
  defp reply_to(nil, _reply), do: :ok

  defp reply_to(from, reply) do
    GenServer.reply(from, reply)
    :ok
  end

  @spec reply_job(job()) :: :ok
  defp reply_job({:barrier, from}), do: reply_to(from, :ok)
  defp reply_job({:attempt, _chain, _attempt, notify}), do: reply_to(notify, :ok)

  @spec schedule_retry(t(), integer(), pos_integer()) :: :ok
  defp schedule_retry(%__MODULE__{} = state, chain, attempt) do
    delay =
      backoff_delay(
        attempt,
        state.jitter_ms,
        state.base_retry_delay_ms,
        state.max_retry_delay_ms
      )

    Process.send_after(self(), {:retry, chain, attempt}, delay)
    :ok
  end

  @doc false
  # `base * 2^attempt`, capped at `max` before the jitter is added.
  @spec backoff_delay(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer() | :infinity
        ) :: non_neg_integer()
  def backoff_delay(attempt, jitter_ms, base_retry_delay_ms, max_retry_delay_ms \\ :infinity) do
    # 2^62 is past any cap a delay can have, and keeps the number small for a huge attempt.
    uncapped = base_retry_delay_ms * Integer.pow(2, min(attempt, 62))

    base =
      if max_retry_delay_ms == :infinity, do: uncapped, else: min(uncapped, max_retry_delay_ms)

    jitter = if jitter_ms > 0, do: :rand.uniform(jitter_ms), else: 0
    base + jitter
  end

  @spec schedule_flush(t()) :: t()
  defp schedule_flush(%__MODULE__{} = state) do
    state = cancel_timer(state)
    jitter = if state.jitter_ms > 0, do: :rand.uniform(state.jitter_ms), else: 0
    delay = state.flush_interval_ms + jitter
    ref = Process.send_after(self(), :flush, delay)
    %{state | timer_ref: ref}
  end

  @spec cancel_timer(t()) :: t()
  defp cancel_timer(%__MODULE__{timer_ref: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer_ref: ref} = state) do
    case Process.cancel_timer(ref) do
      false ->
        receive do
          :flush -> :ok
        after
          0 -> :ok
        end

      _time_left ->
        :ok
    end

    %{state | timer_ref: nil}
  end
end
