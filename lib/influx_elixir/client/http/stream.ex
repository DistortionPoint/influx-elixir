defmodule InfluxElixir.Client.HTTP.Stream do
  @moduledoc false
  # The streaming SQL query of `InfluxElixir.Client.HTTP`: a producer process that runs the
  # request and the callbacks of the consumer's `Stream.resource/3`.
  #
  # True incremental streaming with constant memory. `Finch.stream/5` is
  # push-based (it invokes a callback as chunks arrive), while `Stream.resource`
  # is pull-based. We bridge the two with a producer process: the producer runs
  # `Finch.stream/5` and, for each status/data chunk, sends a message to the
  # consumer and blocks until the consumer acks. Because the callback blocks
  # inside the HTTP receive loop, this gives real back-pressure — a chunk is
  # only pulled off the socket when the downstream consumer asks for the next
  # element. JSONL is decoded line-by-line as bytes arrive; only one chunk plus
  # a partial-line buffer is ever held in memory.
  #
  # Errors are never swallowed: a non-2xx status or a transport error raises an
  # `InfluxElixir.StreamError` when the stream is consumed, mirroring the
  # `{:error, reason}` contract of `query_sql/3`.

  alias InfluxElixir.Client.HTTP.Request
  alias InfluxElixir.Query.ResponseParser

  @doc false
  # The lazy stream of the rows `url` answers (JSONL), one request per enumeration.
  @spec resource(atom(), binary(), list(), binary(), keyword()) :: Enumerable.t()
  def resource(finch_name, url, headers, body, finch_opts) do
    Elixir.Stream.resource(
      fn -> start_stream(finch_name, url, headers, body, finch_opts) end,
      &stream_next/1,
      &stream_cleanup/1
    )
  end

  @typep stream_state :: %{
           producer: pid(),
           ref: reference(),
           monitor: reference(),
           status: non_neg_integer() | nil,
           buffer: binary(),
           error_body: iodata(),
           phase: :streaming | :halt
         }

  @spec start_stream(atom(), binary(), list(), binary(), keyword()) ::
          stream_state()
  defp start_stream(finch_name, url, headers, body, finch_opts) do
    parent = self()
    ref = make_ref()

    producer =
      spawn(fn ->
        run_producer(parent, ref, finch_name, url, headers, body, finch_opts)
      end)

    monitor = Process.monitor(producer)

    %{
      producer: producer,
      ref: ref,
      monitor: monitor,
      status: nil,
      buffer: "",
      error_body: [],
      phase: :streaming
    }
  end

  # Producer process body. Runs the blocking Finch stream, forwarding each
  # chunk to the consumer with back-pressure, then signalling completion.
  @spec run_producer(pid(), reference(), atom(), binary(), list(), binary(), keyword()) ::
          :ok
  defp run_producer(parent, ref, finch_name, url, headers, body, finch_opts) do
    request = Finch.build(:post, url, headers, body)
    # The consumer may die without running `stream_cleanup/1` (killed, or
    # its task shut down brutally); the producer then waited for an ack
    # that never came and kept its pool connection checked out for good.
    consumer = Process.monitor(parent)

    # The request is ended with `{:halt, _}`, never by killing this process:
    # Finch then checks the connection back in, and a request already
    # queued for the pool is served. A pool whose checked-out owner dies
    # drops that connection without serving its queue (verified), so the
    # waiting request timed out.
    outcome =
      try do
        Finch.stream_while(
          request,
          finch_name,
          :streaming,
          fn
            {:status, status}, acc -> emit_and_wait(parent, consumer, ref, {:status, status}, acc)
            {:data, data}, acc -> emit_and_wait(parent, consumer, ref, {:data, data}, acc)
            {_headers_or_trailers, _value}, acc -> {:cont, acc}
          end,
          finch_opts
        )
      rescue
        # No pool of that name, or none to check a connection out of: the consumer is told
        # by name (as `do_request/6` tells a caller), not by a crashed process.
        error in [RuntimeError, ArgumentError] ->
          {:error, Request.classify_finch_error(error), :streaming}
      end

    # A consumer that cancelled, or died, is sent nothing more.
    case outcome do
      {:ok, :streaming} -> send(parent, {ref, :done})
      {:ok, :cancelled} -> :ok
      {:error, reason, :streaming} -> send(parent, {ref, {:transport_error, reason}})
      {:error, _reason, :cancelled} -> :ok
    end

    :ok
  end

  # Send a chunk to the consumer and block until it acks. A consumer that
  # stops early cancels (`stream_cleanup/1`), and one that dies is seen by
  # its monitor; either way the request halts.
  @spec emit_and_wait(pid(), reference(), reference(), term(), :streaming) ::
          {:cont, :streaming} | {:halt, :cancelled}
  defp emit_and_wait(parent, consumer, ref, msg, acc) do
    send(parent, {ref, msg})

    receive do
      {:ack, ^ref} -> {:cont, acc}
      {:cancel, ^ref} -> {:halt, :cancelled}
      {:DOWN, ^consumer, :process, ^parent, _reason} -> {:halt, :cancelled}
    end
  end

  @spec stream_next(stream_state()) :: {[map()], stream_state()} | {:halt, stream_state()}
  defp stream_next(%{phase: :halt} = state), do: {:halt, state}

  defp stream_next(%{ref: ref, producer: producer, monitor: monitor} = state) do
    receive do
      {^ref, {:status, status}} ->
        ack(producer, ref)
        {[], %{state | status: status}}

      {^ref, {:data, data}} ->
        ack(producer, ref)
        handle_data(state, data)

      {^ref, :done} ->
        finish(state)

      {^ref, {:transport_error, reason}} ->
        raise InfluxElixir.StreamError, kind: :transport, reason: reason

      {:DOWN, ^monitor, :process, ^producer, :normal} ->
        {:halt, %{state | phase: :halt}}

      # The producer crashed. A pool checkout timeout surfaces here because
      # Finch raises inside the producer; report it by name.
      {:DOWN, ^monitor, :process, ^producer, {%error_module{} = error, _stack}}
      when error_module in [RuntimeError, ArgumentError] ->
        raise InfluxElixir.StreamError,
          kind: :transport,
          reason: Request.classify_finch_error(error)

      {:DOWN, ^monitor, :process, ^producer, reason} ->
        raise InfluxElixir.StreamError, kind: :transport, reason: reason
    end
  end

  # Decode a data chunk. On a 200 response, complete JSONL lines are decoded
  # and emitted while the trailing partial line is buffered. On any other
  # response, the body is accumulated so it can be reported when the stream ends.
  @spec handle_data(stream_state(), binary()) :: {[map()], stream_state()}
  defp handle_data(%{status: 200, buffer: buffer} = state, data) do
    {lines, rest} = split_lines(buffer, data)
    {Enum.map(lines, &decode_line/1), %{state | buffer: rest}}
  end

  defp handle_data(%{error_body: acc} = state, data) do
    {[], %{state | error_body: [acc, data]}}
  end

  # Producer signalled a clean end-of-response.
  @spec finish(stream_state()) :: {[map()], stream_state()}
  defp finish(%{status: 200, buffer: buffer} = state) do
    rows =
      case String.trim(buffer) do
        "" -> []
        line -> [decode_line(line)]
      end

    {rows, %{state | buffer: "", phase: :halt}}
  end

  defp finish(%{status: status, error_body: acc}) do
    raise InfluxElixir.StreamError,
      kind: :http_status,
      status: status,
      body: IO.iodata_to_binary(acc)
  end

  # Split a chunk into the lines it completes plus a trailing remainder that has not yet been
  # terminated by a newline. Only the new chunk is scanned: the buffered start of a line is
  # joined to the chunk's first piece, so a line arriving over many chunks costs its length
  # once, not once per chunk. Blank lines (a `\r\n` terminator's lone `\r` among them) are
  # dropped, as the end of the stream drops a blank remainder.
  @spec split_lines(binary(), binary()) :: {[binary()], binary()}
  defp split_lines(buffer, data) do
    [first | parts] = :binary.split(data, "\n", [:global])
    {complete, [rest]} = Enum.split([buffer <> first | parts], length(parts))
    {Enum.reject(complete, &(String.trim(&1) == "")), rest}
  end

  # The same coercion `query_sql/3` applies (timestamps become DateTimes),
  # so a row is the same map streamed or not.
  @spec decode_line(binary()) :: map()
  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, row} when is_map(row) ->
        ResponseParser.coerce_types(row)

      {:ok, other} ->
        raise InfluxElixir.StreamError, kind: :decode, reason: {:unexpected_json, other}

      {:error, reason} ->
        raise InfluxElixir.StreamError, kind: :decode, reason: reason
    end
  end

  @spec ack(pid(), reference()) :: :ok
  defp ack(producer, ref) do
    send(producer, {:ack, ref})
    :ok
  end

  # Stop the producer and drain its messages from the consumer's mailbox:
  # the stream runs in the caller's process, so a leftover chunk or :DOWN
  # would otherwise pollute that mailbox. A producer still running is asked
  # to cancel, so its request halts and the connection goes back to the
  # pool (see `run_producer/7`); it notices at its next chunk. One that does
  # not stop within the grace period (a server gone silent) is killed.
  # Waiting for its :DOWN first means every message it sent is already in
  # the mailbox when it is flushed.
  @cancel_grace_ms 1_000

  @spec stream_cleanup(stream_state() | term()) :: :ok
  defp stream_cleanup(%{producer: producer, ref: ref, monitor: monitor}) do
    if Process.alive?(producer) do
      send(producer, {:cancel, ref})
      await_down(producer, monitor)
    end

    Process.demonitor(monitor, [:flush])
    flush_ref(ref)
  end

  defp stream_cleanup(_state), do: :ok

  @spec await_down(pid(), reference()) :: :ok
  defp await_down(producer, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^producer, _reason} -> :ok
    after
      @cancel_grace_ms ->
        Process.exit(producer, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^producer, _reason} -> :ok
        end
    end
  end

  @spec flush_ref(reference()) :: :ok
  defp flush_ref(ref) do
    receive do
      {^ref, _msg} -> flush_ref(ref)
    after
      0 -> :ok
    end
  end
end
