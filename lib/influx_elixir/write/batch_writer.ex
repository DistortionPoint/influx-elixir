defmodule InfluxElixir.Write.BatchWriter do
  @default_shutdown 5_000

  # The options, validated by `start_link/1`; the moduledoc lists them from
  # here, so the two cannot drift.
  @options_schema NimbleOptions.new!(
                    connection: [
                      type: :any,
                      required: true,
                      doc: "connection term passed to `InfluxElixir.Write.Writer`"
                    ],
                    database: [
                      type: :string,
                      doc: "database every flush writes to. A `:database` in `:write_opts` wins."
                    ],
                    batch_size: [
                      type: :pos_integer,
                      default: 5_000,
                      doc: "maximum points per flush"
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
                      doc: "retry attempts for 5xx and transport errors. 4xx is never retried."
                    ],
                    base_retry_delay_ms: [
                      type: :non_neg_integer,
                      default: 100,
                      doc: "base of the exponential backoff: attempt N waits about `base * 2^N`"
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

  Points or pre-encoded line protocol strings are buffered in memory and
  flushed either when the buffer reaches `batch_size` or when the
  `flush_interval_ms` timer fires — whichever comes first.

  ## Options

  Validated by `start_link/1`, which returns
  `{:error, %NimbleOptions.ValidationError{}}` for an unknown key or a
  value of the wrong type — a `batch_size: 0` used to refuse every write
  as `:buffer_full`, and a misspelt key was silently ignored.

  #{NimbleOptions.docs(@options_schema)}

  ## Backpressure

  While any batch is being retried, the automatic flushes (batch size
  reached, timer fired) wait for every retry chain to finish instead of
  starting another against a server that is already failing; writes keep
  buffering meanwhile. Once the buffer holds `10 * batch_size` entries,
  `write/3` and `write_sync/3` return `{:error, :buffer_full}` until the
  last chain ends. An explicit `flush/2`, and `write_sync/3` without
  `:no_sync`, always flush immediately — and may start a chain of their
  own. When the last chain ends the deferred buffer is flushed if it has
  reached `batch_size`; otherwise the timer takes it.

  ## Shutdown

  The writer traps exits, so a supervisor stopping it — application
  shutdown, `InfluxElixir.remove_connection/1` — runs `terminate/2`, which
  writes every batch still being retried and then the buffer, once each
  and in the order they were written, and answers any `write_sync/3`
  caller waiting on them. A write that fails there is logged and dropped.
  The supervisor kills the writer if that takes longer than `:shutdown`.

  ## Retry Policy

  Only 5xx and network errors are retried using asynchronous exponential
  backoff with optional jitter. 4xx errors are discarded and logged.
  Retries are non-blocking — the GenServer continues to accept messages
  between retry attempts. A `write_sync/3` caller whose batch is being
  retried is answered with that chain's final result.

  ## Stats

  Call `stats/1` to retrieve a map with `:total_writes`, `:total_errors`,
  and `:total_bytes` counters.
  """

  use GenServer
  require Logger

  alias InfluxElixir.Write.Writer

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

  defstruct [
    :connection,
    :database,
    :timer_ref,
    :pending_sync,
    # Set from the validated options by init/1.
    :batch_size,
    :flush_interval_ms,
    :jitter_ms,
    :max_retries,
    :base_retry_delay_ms,
    :no_sync,
    :write_opts,
    buffer: [],
    buffer_size: 0,
    stats: %{total_writes: 0, total_errors: 0, total_bytes: 0},
    chains: %{}
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
          no_sync: boolean(),
          write_opts: keyword(),
          stats: stats(),
          timer_ref: reference() | nil,
          pending_sync: GenServer.from() | nil,
          chains: %{integer() => {binary(), GenServer.from() | nil}}
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a BatchWriter GenServer linked to the calling process.

  ## Options

  See module documentation for available options.

  ## Examples

      iex> {:ok, pid} = InfluxElixir.Write.BatchWriter.start_link(
      ...>   connection: conn,
      ...>   database: "mydb"
      ...> )
      iex> is_pid(pid)
      true
  """
  @spec start_link(keyword()) ::
          GenServer.on_start() | {:error, NimbleOptions.ValidationError.t()}
  def start_link(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @options_schema) do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end
  end

  @doc """
  The child spec a supervisor starts the writer with; `:shutdown` in
  `opts` sets how long it waits for the final flush.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Keyword.get(opts, :shutdown, @default_shutdown)
    }
  end

  @doc """
  Buffers a point (or line protocol binary) for writing.

  Returns immediately after buffering unless the buffer reaches `batch_size`,
  in which case `handle_call` triggers a synchronous `do_flush` that calls
  the HTTP client. The `timeout` argument bounds the `GenServer.call/3`
  wait — defaults to `#{@default_write_timeout}` ms, generous enough to
  cover a single HTTP write at `Client.HTTP`'s 30s default.

  ## Parameters

    * `server` - PID or registered name of the BatchWriter
    * `payload` - a `InfluxElixir.Write.Point.t()` or pre-encoded binary
    * `timeout` - `GenServer.call` wait bound in ms (default: `60_000`)

  ## Examples

      iex> InfluxElixir.Write.BatchWriter.write(pid, "cpu value=1.0")
      :ok
  """
  @spec write(
          GenServer.server(),
          InfluxElixir.Write.Point.t() | binary(),
          timeout()
        ) :: :ok | {:error, :buffer_full | term()}
  def write(server, payload, timeout \\ @default_write_timeout) do
    GenServer.call(server, {:write, payload}, timeout)
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
    * `payload` - a `InfluxElixir.Write.Point.t()` or pre-encoded binary
    * `timeout` - `GenServer.call` wait bound in ms (default: `300_000`).
      Pass `:infinity` for unbounded blocking.

  ## Examples

      iex> InfluxElixir.Write.BatchWriter.write_sync(pid, "cpu value=1.0")
      :ok
  """
  @spec write_sync(
          GenServer.server(),
          InfluxElixir.Write.Point.t() | binary(),
          timeout()
        ) :: :ok | {:error, term()}
  def write_sync(server, payload, timeout \\ @default_write_sync_timeout) do
    GenServer.call(server, {:write_sync, payload}, timeout)
  end

  @doc """
  Forces an immediate flush of the buffer.

  Bounded by `timeout` (default: `#{@default_flush_timeout}` ms). Returns
  `:ok` once the underlying HTTP write completes (or schedules a retry).
  Retries scheduled by `do_flush` are asynchronous and do NOT extend the
  caller's wait.

  ## Parameters

    * `server` - PID or registered name of the BatchWriter
    * `timeout` - `GenServer.call` wait bound in ms (default: `60_000`)

  ## Examples

      iex> InfluxElixir.Write.BatchWriter.flush(pid)
      :ok
  """
  @spec flush(GenServer.server(), timeout()) :: :ok
  def flush(server, timeout \\ @default_flush_timeout) do
    GenServer.call(server, :flush, timeout)
  end

  @doc """
  Returns the current stats map.

  ## Keys

    * `:total_writes` - total successful write operations
    * `:total_errors` - total failed write operations
    * `:total_bytes` - total bytes flushed

  ## Examples

      iex> {:ok, stats} = InfluxElixir.Write.BatchWriter.stats(pid)
      iex> Map.keys(stats)
      [:total_bytes, :total_errors, :total_writes]
  """
  @spec stats(GenServer.server()) :: {:ok, stats()}
  def stats(server) do
    GenServer.call(server, :stats)
  end

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

  @impl GenServer
  def handle_call({:write, payload}, _from, %__MODULE__{} = state) do
    max_buffer = state.batch_size * @backpressure_multiplier

    with false <- state.buffer_size >= max_buffer,
         {:ok, line} <- encode_payload(payload, state.write_opts) do
      {:reply, :ok, state |> append_to_buffer(line) |> maybe_flush_on_batch()}
    else
      true -> {:reply, {:error, :buffer_full}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call({:write_sync, payload}, from, %__MODULE__{} = state) do
    max_buffer = state.batch_size * @backpressure_multiplier

    with false <- state.buffer_size >= max_buffer,
         {:ok, line} <- encode_payload(payload, state.write_opts) do
      if state.no_sync,
        do: {:reply, :ok, state |> append_to_buffer(line) |> maybe_flush_on_batch()},
        else: {:noreply, do_flush(append_to_buffer(%{state | pending_sync: from}, line))}
    else
      true -> {:reply, {:error, :buffer_full}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, %__MODULE__{} = state) do
    new_state = do_flush(state)
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:stats, _from, %__MODULE__{} = state) do
    {:reply, {:ok, state.stats}, state}
  end

  # The timer flush waits for in-flight retry chains (see "Backpressure").
  @impl GenServer
  def handle_info(:flush, %__MODULE__{chains: chains} = state) when map_size(chains) == 0 do
    new_state =
      state
      |> do_flush()
      |> schedule_flush()

    {:noreply, new_state, :hibernate}
  end

  def handle_info(:flush, %__MODULE__{} = state) do
    {:noreply, schedule_flush(state), :hibernate}
  end

  # Each chain keeps its payload and its write_sync caller (or nil) in
  # `chains`, so a later chain cannot answer that caller by mistake and
  # terminate/2 can still write the payload.
  def handle_info({:retry, chain, attempt}, %__MODULE__{chains: chains} = state)
      when is_map_key(chains, chain) do
    {payload, _from} = Map.fetch!(chains, chain)

    case Writer.write(state.connection, payload, state.write_opts) do
      {:ok, :written} ->
        finish_chain(state, chain, :ok)

      {:error, %{status: status}} = error when status in 400..499 ->
        Logger.warning("[BatchWriter] 4xx error (#{status}) — discarding batch")

        finish_chain(state, chain, error)

      {:error, reason} when attempt < state.max_retries ->
        Logger.warning(
          "[BatchWriter] Write error (attempt #{attempt + 1}): " <>
            inspect(reason)
        )

        schedule_retry(state, chain, attempt + 1)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("[BatchWriter] Flush failed after retries: #{inspect(reason)}")

        finish_chain(state, chain, {:error, reason})
    end
  end

  # Trapping exits delivers the exit of a linked process that is not the
  # parent (the parent's ends the writer through terminate/2); nothing
  # else is linked, and a stray message must not crash the writer and lose
  # its buffer.
  def handle_info(message, %__MODULE__{} = state) do
    Logger.debug("[BatchWriter] ignoring unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # One attempt each, oldest first: the batches being retried, then the
  # buffer. Retries cannot outlive the writer.
  @impl GenServer
  def terminate(_reason, %__MODULE__{} = state) do
    state.chains
    |> Enum.sort()
    |> Enum.each(fn {_chain, {payload, from}} -> final_write(state, payload, from) end)

    if state.buffer_size > 0 do
      lines = state.buffer |> Enum.reverse() |> Enum.join("\n")
      final_write(state, lines, state.pending_sync)
    end

    :ok
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

    reply_sync(%{state | pending_sync: from}, result)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # A point no server accepts is the caller's `{:error, reason}` (as from
  # `LineProtocol.encode/2`), never a crash that loses every other caller's
  # buffered lines. It is encoded here, where the flushes' `:precision` is
  # known: a `DateTime` timestamp is written in that unit.
  @spec encode_payload(InfluxElixir.Write.Point.t() | binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  defp encode_payload(payload, _write_opts) when is_binary(payload), do: {:ok, payload}

  defp encode_payload(%InfluxElixir.Write.Point{} = point, write_opts),
    do: InfluxElixir.Write.LineProtocol.encode(point, Keyword.take(write_opts, [:precision]))

  @spec append_to_buffer(t(), binary()) :: t()
  defp append_to_buffer(%__MODULE__{} = state, line) do
    %{state | buffer: [line | state.buffer], buffer_size: state.buffer_size + 1}
  end

  # A batch-size flush is deferred while a retry chain is in flight; the
  # buffer keeps filling up to the backpressure bound instead.
  @spec maybe_flush_on_batch(t()) :: t()
  defp maybe_flush_on_batch(
         %__MODULE__{buffer_size: size, batch_size: batch, chains: chains} = state
       )
       when size >= batch and map_size(chains) == 0 do
    do_flush(state)
  end

  defp maybe_flush_on_batch(%__MODULE__{} = state), do: state

  @spec do_flush(t()) :: t()
  defp do_flush(%__MODULE__{buffer_size: 0} = state) do
    reply_sync(state, :ok)
    %{state | pending_sync: nil}
  end

  defp do_flush(%__MODULE__{} = state) do
    state = cancel_timer(state)
    lines = state.buffer |> Enum.reverse() |> Enum.join("\n")

    case Writer.write(state.connection, lines, state.write_opts) do
      {:ok, :written} ->
        finish_flush_immediate(state, lines, :ok)

      # Clients report HTTP failures as %{status, body}. A 4xx is the
      # payload's fault and will never succeed on retry, so it is discarded.
      # (The clause used to match {:http_error, status}, a shape no client
      # produces, so bad batches were retried with backoff.)
      {:error, %{status: status}} = error when status in 400..499 ->
        Logger.warning("[BatchWriter] 4xx error (#{status}) — discarding batch")

        finish_flush_immediate(state, lines, error)

      {:error, reason} when state.max_retries > 0 ->
        Logger.warning("[BatchWriter] Write error (attempt 1): #{inspect(reason)}")

        # Monotonic, so terminate/2 can write chains in the order they began.
        chain = System.unique_integer([:monotonic])
        schedule_retry(state, chain, 1)

        %{
          state
          | buffer: [],
            buffer_size: 0,
            pending_sync: nil,
            chains: Map.put(state.chains, chain, {lines, state.pending_sync})
        }

      {:error, reason} ->
        Logger.error("[BatchWriter] Flush failed: #{inspect(reason)}")

        finish_flush_immediate(state, lines, {:error, reason})
    end
  end

  @spec finish_flush_immediate(t(), binary(), :ok | {:error, term()}) :: t()
  defp finish_flush_immediate(%__MODULE__{} = state, lines, result) do
    bytes = byte_size(lines)
    stats = update_stats(state.stats, result, bytes)
    reply_sync(state, result)

    %{
      state
      | buffer: [],
        buffer_size: 0,
        stats: stats,
        pending_sync: nil
    }
  end

  # Ends a retry chain: answers the chain's write_sync caller, then — once
  # no chain is left — flushes whatever accumulated meanwhile if it has
  # reached batch_size (the timer takes anything smaller).
  @spec finish_chain(t(), integer(), :ok | {:error, term()}) :: {:noreply, t()}
  defp finish_chain(%__MODULE__{} = state, chain, result) do
    {{payload, from}, chains} = Map.pop!(state.chains, chain)
    reply_sync(%{state | pending_sync: from}, result)

    new_state =
      %{state | stats: update_stats(state.stats, result, byte_size(payload)), chains: chains}
      |> maybe_flush_on_batch()

    {:noreply, new_state}
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

  @spec reply_sync(t(), term()) :: :ok
  defp reply_sync(%__MODULE__{pending_sync: nil}, _reply), do: :ok

  defp reply_sync(%__MODULE__{pending_sync: from}, reply) do
    GenServer.reply(from, reply)
    :ok
  end

  @spec schedule_retry(t(), integer(), pos_integer()) :: :ok
  defp schedule_retry(%__MODULE__{} = state, chain, attempt) do
    delay = backoff_delay(attempt, state.jitter_ms, state.base_retry_delay_ms)
    Process.send_after(self(), {:retry, chain, attempt}, delay)
    :ok
  end

  @doc false
  @spec backoff_delay(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def backoff_delay(attempt, jitter_ms, base_retry_delay_ms) do
    base = (base_retry_delay_ms * :math.pow(2, attempt)) |> round()
    jitter = if jitter_ms > 0, do: :rand.uniform(jitter_ms), else: 0
    base + jitter
  end

  @spec schedule_flush(t()) :: t()
  defp schedule_flush(%__MODULE__{} = state) do
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
