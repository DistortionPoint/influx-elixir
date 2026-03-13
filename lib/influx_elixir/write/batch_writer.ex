defmodule InfluxElixir.Write.BatchWriter do
  @moduledoc """
  GenServer-based batch writer with configurable flush intervals,
  batch sizes, retry with exponential backoff, and backpressure.

  Points or pre-encoded line protocol strings are buffered in memory and
  flushed either when the buffer reaches `batch_size` or when the
  `flush_interval_ms` timer fires — whichever comes first.

  ## Options

    * `:connection` - connection term passed to `InfluxElixir.Write.Writer`
    * `:database` - default database name (binary)
    * `:batch_size` - maximum points per flush (default: `5000`)
    * `:flush_interval_ms` - timer interval in milliseconds (default: `1000`)
    * `:jitter_ms` - random jitter added to flush timer (default: `0`)
    * `:max_retries` - max retry attempts for 5xx errors (default: `3`)
    * `:no_sync` - when `true`, `write_sync/2` behaves like `write/2` (default: `false`)

  ## Backpressure

  When the buffer exceeds `10 * batch_size` entries, new writes are rejected
  with `{:error, :buffer_full}`.

  ## Retry Policy

  Only 5xx and network errors are retried using asynchronous exponential
  backoff with optional jitter. 4xx errors are discarded and logged.
  Retries are non-blocking — the GenServer continues to accept messages
  between retry attempts.

  ## Stats

  Call `stats/1` to retrieve a map with `:total_writes`, `:total_errors`,
  and `:total_bytes` counters.
  """

  use GenServer
  require Logger

  alias InfluxElixir.Write.Writer

  @default_batch_size 5_000
  @default_flush_interval_ms 1_000
  @default_jitter_ms 0
  @default_max_retries 3
  @backpressure_multiplier 10
  @base_retry_delay_ms 100

  @type stat_key :: :total_writes | :total_errors | :total_bytes
  @type stats :: %{stat_key() => non_neg_integer()}

  defstruct [
    :connection,
    :database,
    :timer_ref,
    :pending_sync,
    buffer: [],
    buffer_size: 0,
    batch_size: @default_batch_size,
    flush_interval_ms: @default_flush_interval_ms,
    jitter_ms: @default_jitter_ms,
    max_retries: @default_max_retries,
    no_sync: false,
    stats: %{total_writes: 0, total_errors: 0, total_bytes: 0},
    retry_payload: nil,
    retry_attempt: 0
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
          no_sync: boolean(),
          stats: stats(),
          timer_ref: reference() | nil,
          pending_sync: {pid(), term()} | nil,
          retry_payload: binary() | nil,
          retry_attempt: non_neg_integer()
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
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Buffers a point (or line protocol binary) for writing.

  Blocks until the buffer accepts the point, then returns. Does not wait
  for the data to be flushed to InfluxDB. Returns `{:error, :buffer_full}`
  when the buffer exceeds the backpressure threshold.

  ## Parameters

    * `server` - PID or registered name of the BatchWriter
    * `payload` - a `InfluxElixir.Write.Point.t()` or pre-encoded binary

  ## Examples

      iex> InfluxElixir.Write.BatchWriter.write(pid, "cpu value=1.0")
      :ok
  """
  @spec write(GenServer.server(), InfluxElixir.Write.Point.t() | binary()) ::
          :ok | {:error, :buffer_full}
  def write(server, payload) do
    GenServer.call(server, {:write, payload})
  end

  @doc """
  Synchronously writes a point and waits for the next flush to complete.

  Blocks until the buffered data has been flushed and the write is confirmed.
  When `no_sync: true` is configured, behaves identically to `write/2`.

  ## Parameters

    * `server` - PID or registered name of the BatchWriter
    * `payload` - a `InfluxElixir.Write.Point.t()` or pre-encoded binary

  ## Examples

      iex> InfluxElixir.Write.BatchWriter.write_sync(pid, "cpu value=1.0")
      :ok
  """
  @spec write_sync(GenServer.server(), InfluxElixir.Write.Point.t() | binary()) ::
          :ok | {:error, term()}
  def write_sync(server, payload) do
    GenServer.call(server, {:write_sync, payload}, 30_000)
  end

  @doc """
  Forces an immediate flush of the buffer.

  ## Examples

      iex> InfluxElixir.Write.BatchWriter.flush(pid)
      :ok
  """
  @spec flush(GenServer.server()) :: :ok
  def flush(server) do
    GenServer.call(server, :flush)
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
    state = %__MODULE__{
      connection: Keyword.get(opts, :connection),
      database: Keyword.get(opts, :database),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms),
      jitter_ms: Keyword.get(opts, :jitter_ms, @default_jitter_ms),
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      no_sync: Keyword.get(opts, :no_sync, false)
    }

    {:ok, state, {:continue, :schedule_initial_flush}}
  end

  @impl GenServer
  def handle_continue(:schedule_initial_flush, state) do
    {:noreply, schedule_flush(state)}
  end

  @impl GenServer
  def handle_call({:write, payload}, _from, %__MODULE__{} = state) do
    max_buffer = state.batch_size * @backpressure_multiplier

    if state.buffer_size >= max_buffer do
      {:reply, {:error, :buffer_full}, state}
    else
      line = encode_payload(payload)
      new_state = append_to_buffer(state, line)

      if new_state.buffer_size >= new_state.batch_size do
        {:reply, :ok, do_flush(new_state)}
      else
        {:reply, :ok, new_state}
      end
    end
  end

  @impl GenServer
  def handle_call({:write_sync, payload}, from, %__MODULE__{} = state) do
    max_buffer = state.batch_size * @backpressure_multiplier

    cond do
      state.buffer_size >= max_buffer ->
        {:reply, {:error, :buffer_full}, state}

      state.no_sync ->
        line = encode_payload(payload)
        new_state = append_to_buffer(state, line)
        {:reply, :ok, maybe_flush_on_batch(new_state)}

      true ->
        line = encode_payload(payload)
        new_state = append_to_buffer(%{state | pending_sync: from}, line)
        {:noreply, do_flush(new_state)}
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

  @impl GenServer
  def handle_info(:flush, %__MODULE__{} = state) do
    new_state =
      state
      |> do_flush()
      |> schedule_flush()

    {:noreply, new_state, :hibernate}
  end

  @impl GenServer
  def handle_info({:retry, payload, attempt}, %__MODULE__{} = state) do
    case Writer.write(state.connection, payload) do
      {:ok, :written} ->
        finish_flush(state, payload, :ok)

      {:error, {:http_error, status}} when status >= 400 and status < 500 ->
        Logger.warning("[BatchWriter] 4xx error (#{status}) — discarding batch")

        finish_flush(state, payload, {:error, {:http_error, status}})

      {:error, reason} when attempt < state.max_retries ->
        Logger.warning(
          "[BatchWriter] Write error (attempt #{attempt + 1}): " <>
            inspect(reason)
        )

        schedule_retry(payload, attempt + 1, state.jitter_ms)
        {:noreply, %{state | retry_payload: payload, retry_attempt: attempt + 1}}

      {:error, reason} ->
        Logger.error("[BatchWriter] Flush failed after retries: #{inspect(reason)}")

        finish_flush(state, payload, {:error, reason})
    end
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{} = state) do
    do_flush(state)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec encode_payload(InfluxElixir.Write.Point.t() | binary()) :: binary()
  defp encode_payload(payload) when is_binary(payload), do: payload

  defp encode_payload(%InfluxElixir.Write.Point{} = point) do
    InfluxElixir.Write.LineProtocol.encode!(point)
  end

  @spec append_to_buffer(t(), binary()) :: t()
  defp append_to_buffer(%__MODULE__{} = state, line) do
    %{state | buffer: [line | state.buffer], buffer_size: state.buffer_size + 1}
  end

  @spec maybe_flush_on_batch(t()) :: t()
  defp maybe_flush_on_batch(%__MODULE__{buffer_size: size, batch_size: batch} = state)
       when size >= batch do
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

    case Writer.write(state.connection, lines) do
      {:ok, :written} ->
        finish_flush_immediate(state, lines, :ok)

      {:error, {:http_error, status}} when status >= 400 and status < 500 ->
        Logger.warning("[BatchWriter] 4xx error (#{status}) — discarding batch")

        finish_flush_immediate(state, lines, {:error, {:http_error, status}})

      {:error, reason} when state.max_retries > 0 ->
        Logger.warning("[BatchWriter] Write error (attempt 1): #{inspect(reason)}")

        schedule_retry(lines, 1, state.jitter_ms)

        %{
          state
          | buffer: [],
            buffer_size: 0,
            retry_payload: lines,
            retry_attempt: 1
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
        pending_sync: nil,
        retry_payload: nil,
        retry_attempt: 0
    }
  end

  @spec finish_flush(t(), binary(), :ok | {:error, term()}) ::
          {:noreply, t()}
  defp finish_flush(%__MODULE__{} = state, payload, result) do
    bytes = byte_size(payload)
    stats = update_stats(state.stats, result, bytes)
    reply_sync(state, result)

    new_state = %{
      state
      | stats: stats,
        pending_sync: nil,
        retry_payload: nil,
        retry_attempt: 0
    }

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

  @spec schedule_retry(binary(), non_neg_integer(), non_neg_integer()) :: :ok
  defp schedule_retry(payload, attempt, jitter_ms) do
    delay = backoff_delay(attempt, jitter_ms)
    Process.send_after(self(), {:retry, payload, attempt}, delay)
    :ok
  end

  @spec backoff_delay(non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp backoff_delay(attempt, jitter_ms) do
    base = (@base_retry_delay_ms * :math.pow(2, attempt)) |> round()
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
