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

  Only 5xx and network errors are retried using exponential backoff with
  optional jitter. 4xx errors are discarded and logged.

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

  @type state :: %{
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
          pending_sync: {pid(), term()} | nil
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
  Asynchronously buffers a point (or line protocol binary) for writing.

  Returns `:ok` immediately, or `{:error, :buffer_full}` when backpressure
  kicks in.

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
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    flush_interval_ms = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    jitter_ms = Keyword.get(opts, :jitter_ms, @default_jitter_ms)

    state = %{
      buffer: [],
      buffer_size: 0,
      connection: Keyword.get(opts, :connection),
      database: Keyword.get(opts, :database),
      batch_size: batch_size,
      flush_interval_ms: flush_interval_ms,
      jitter_ms: jitter_ms,
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      no_sync: Keyword.get(opts, :no_sync, false),
      stats: %{total_writes: 0, total_errors: 0, total_bytes: 0},
      timer_ref: nil,
      pending_sync: nil
    }

    {:ok, schedule_flush(state)}
  end

  @impl GenServer
  def handle_call({:write, payload}, _from, state) do
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

  def handle_call({:write_sync, payload}, from, state) do
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

  def handle_call(:flush, _from, state) do
    new_state = do_flush(state)
    {:reply, :ok, new_state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, {:ok, state.stats}, state}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    new_state =
      state
      |> do_flush()
      |> schedule_flush()

    {:noreply, new_state, :hibernate}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec encode_payload(InfluxElixir.Write.Point.t() | binary()) :: binary()
  defp encode_payload(payload) when is_binary(payload), do: payload

  defp encode_payload(%InfluxElixir.Write.Point{} = point) do
    InfluxElixir.Write.LineProtocol.encode!(point)
  end

  @spec append_to_buffer(state(), binary()) :: state()
  defp append_to_buffer(state, line) do
    %{state | buffer: [line | state.buffer], buffer_size: state.buffer_size + 1}
  end

  @spec maybe_flush_on_batch(state()) :: state()
  defp maybe_flush_on_batch(%{buffer_size: size, batch_size: batch} = state)
       when size >= batch do
    do_flush(state)
  end

  defp maybe_flush_on_batch(state), do: state

  @spec do_flush(state()) :: state()
  defp do_flush(%{buffer_size: 0} = state) do
    reply_sync(state, :ok)
    %{state | pending_sync: nil}
  end

  defp do_flush(state) do
    state = cancel_timer(state)
    lines = state.buffer |> Enum.reverse() |> Enum.join("\n")
    bytes = byte_size(lines)

    new_state =
      case flush_with_retry(state.connection, lines, state.max_retries, state.jitter_ms) do
        {:ok, :written} ->
          stats =
            state.stats
            |> Map.update!(:total_writes, &(&1 + 1))
            |> Map.update!(:total_bytes, &(&1 + bytes))

          reply_sync(state, :ok)
          %{state | buffer: [], buffer_size: 0, stats: stats, pending_sync: nil}

        {:error, reason} ->
          Logger.error("[BatchWriter] Flush failed after retries: #{inspect(reason)}")

          stats = Map.update!(state.stats, :total_errors, &(&1 + 1))
          reply_sync(state, {:error, reason})
          %{state | buffer: [], buffer_size: 0, stats: stats, pending_sync: nil}
      end

    new_state
  end

  @spec reply_sync(state(), term()) :: :ok
  defp reply_sync(%{pending_sync: nil}, _reply), do: :ok

  defp reply_sync(%{pending_sync: from}, reply) do
    GenServer.reply(from, reply)
    :ok
  end

  @spec flush_with_retry(term(), binary(), non_neg_integer(), non_neg_integer()) ::
          InfluxElixir.Client.write_result()
  defp flush_with_retry(connection, payload, max_retries, jitter_ms) do
    do_retry(connection, payload, 0, max_retries, jitter_ms)
  end

  @spec do_retry(term(), binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          InfluxElixir.Client.write_result()
  defp do_retry(connection, payload, attempt, max_retries, jitter_ms) do
    case Writer.write(connection, payload) do
      {:ok, :written} ->
        {:ok, :written}

      {:error, {:http_error, status}} when status >= 400 and status < 500 ->
        Logger.warning("[BatchWriter] 4xx error (#{status}) — discarding batch, not retrying")
        {:error, {:http_error, status}}

      {:error, reason} when attempt < max_retries ->
        delay = backoff_delay(attempt, jitter_ms)
        Logger.warning("[BatchWriter] Write error (attempt #{attempt + 1}): #{inspect(reason)}")
        Process.sleep(delay)
        do_retry(connection, payload, attempt + 1, max_retries, jitter_ms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec backoff_delay(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp backoff_delay(attempt, jitter_ms) do
    base = (@base_retry_delay_ms * :math.pow(2, attempt)) |> round()
    jitter = if jitter_ms > 0, do: :rand.uniform(jitter_ms), else: 0
    base + jitter
  end

  @spec schedule_flush(state()) :: state()
  defp schedule_flush(state) do
    jitter = if state.jitter_ms > 0, do: :rand.uniform(state.jitter_ms), else: 0
    delay = state.flush_interval_ms + jitter
    ref = Process.send_after(self(), :flush, delay)
    %{state | timer_ref: ref}
  end

  @spec cancel_timer(state()) :: state()
  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
