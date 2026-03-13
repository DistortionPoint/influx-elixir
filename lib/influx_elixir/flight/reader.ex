defmodule InfluxElixir.Flight.Reader do
  @moduledoc """
  Arrow IPC record batch decoder for Arrow Flight query results.

  Converts a list of `FlightData` messages (received from a `DoGet` gRPC
  stream) into a list of Elixir row maps.

  ## Arrow IPC Format Overview

  Each `FlightData` message carries two binary blobs:

    * `data_header` — serialised Arrow IPC `Message` flatbuffer. The first
      message in a stream contains a `Schema` message; subsequent messages
      contain `RecordBatch` messages with buffer offset/length metadata.
    * `data_body` — raw column buffer bytes referenced by the batch metadata.

  A full Arrow IPC decoder requires a flatbuffers parser to read the binary
  metadata layout. This module implements a pragmatic, self-contained approach:

    1. **Schema extraction** — parses the Arrow IPC `Schema` message header
       to extract column names and type IDs via heuristic binary scanning.
    2. **Record batch decoding** — reads fixed-size typed columns (int64,
       float64, bool, timestamp) directly from `data_body` buffers.
       Variable-length columns (utf8 strings) are decoded from their
       offset + value buffers.
    3. **Row assembly** — zips column vectors into row maps keyed by name.

  ## Supported Column Types

  | Arrow Type ID | Elixir type    |
  |---------------|----------------|
  | 6  (Int64)    | `integer()`    |
  | 12 (Float64)  | `float()`      |
  | 14 (Bool)     | `boolean()`    |
  | 15 (Utf8)     | `binary()`     |
  | 20 (Timestamp)| `integer()`    |

  Null bitmaps are supported; null values become `nil`.

  ## Limitations

  - Dictionary-encoded columns (type 18) are not yet decoded.
  - Nested / list / struct types are not supported.
  - The flatbuffer header parser uses heuristic binary scanning; it works
    reliably for InfluxDB's simple flat schemas.
  """

  import Bitwise

  alias InfluxElixir.Flight.Proto.FlightData

  # Arrow IPC stream continuation marker (proto stream format)
  @continuation_marker <<0xFF, 0xFF, 0xFF, 0xFF>>

  # Arrow IPC type IDs we handle
  @type_int8 2
  @type_int16 3
  @type_int32 4
  @type_int64 6
  @type_uint8 7
  @type_uint16 8
  @type_uint32 9
  @type_uint64 10
  @type_float32 11
  @type_float64 12
  @type_bool 14
  @type_utf8 15
  @type_timestamp 20

  # Fixed byte widths per Arrow type ID (bool uses a bitmap — 0 here)
  @byte_widths %{
    @type_int8 => 1,
    @type_int16 => 2,
    @type_int32 => 4,
    @type_int64 => 8,
    @type_uint8 => 1,
    @type_uint16 => 2,
    @type_uint32 => 4,
    @type_uint64 => 8,
    @type_float32 => 4,
    @type_float64 => 8,
    @type_bool => 0,
    @type_timestamp => 8
  }

  @typedoc "Parsed column schema entry"
  @type column_schema :: %{name: binary(), type_id: non_neg_integer()}

  @doc """
  Decodes a list of `FlightData` messages into row maps.

  The first element of `flight_data_list` is expected to be the schema message
  (typically with an empty `data_body`). Subsequent elements are record batch
  messages.

  Returns `{:ok, [map()]}` on success or `{:error, reason}` on parse failure.

  ## Parameters

    * `flight_data_list` — ordered list of `FlightData` structs from a DoGet stream

  ## Example

      iex> InfluxElixir.Flight.Reader.decode_flight_data([])
      {:ok, []}
  """
  @spec decode_flight_data([FlightData.t()]) :: {:ok, [map()]} | {:error, term()}
  def decode_flight_data([]), do: {:ok, []}

  def decode_flight_data([schema_msg | batch_msgs]) do
    with {:ok, columns} <- parse_schema(schema_msg.data_header) do
      decode_batches(batch_msgs, columns)
    end
  end

  # ---------------------------------------------------------------------------
  # Schema parsing
  # ---------------------------------------------------------------------------

  @doc """
  Extracts column name/type pairs from an Arrow IPC `Schema` message header.

  The header is a serialised flatbuffer. This function locates field metadata
  using heuristic binary pattern matching without a full flatbuffers library.

  Returns `{:ok, [column_schema()]}` or `{:error, reason}`.
  """
  @spec parse_schema(binary() | nil) :: {:ok, [column_schema()]} | {:error, term()}
  def parse_schema(nil), do: {:ok, []}
  def parse_schema(<<>>), do: {:ok, []}

  def parse_schema(header) when is_binary(header) do
    cols = header |> strip_continuation() |> extract_columns_heuristic()
    {:ok, cols}
  rescue
    _err -> {:error, :schema_parse_failed}
  end

  # ---------------------------------------------------------------------------
  # Private: schema helpers
  # ---------------------------------------------------------------------------

  # Strip IPC stream continuation marker and metadata-length prefix.
  # Format: <<0xFF, 0xFF, 0xFF, 0xFF, len::little-32, flatbuffer...>>
  @spec strip_continuation(binary()) :: binary()
  defp strip_continuation(<<@continuation_marker, _meta_len::little-32, rest::binary>>),
    do: rest

  defp strip_continuation(bin), do: bin

  # Heuristic column extractor.
  @spec extract_columns_heuristic(binary()) :: [column_schema()]
  defp extract_columns_heuristic(data) do
    data
    |> scan_for_names([])
    |> Enum.map(fn {name, type_id} -> %{name: name, type_id: type_id} end)
  end

  @spec scan_for_names(binary(), [{binary(), non_neg_integer()}]) ::
          [{binary(), non_neg_integer()}]
  defp scan_for_names(<<>>, acc), do: Enum.reverse(acc)

  defp scan_for_names(<<len::little-16, rest::binary>>, acc)
       when len > 0 and len < 256 and byte_size(rest) >= len do
    candidate = binary_part(rest, 0, len)
    after_name = binary_part(rest, len, byte_size(rest) - len)

    if printable_ascii?(candidate) do
      type_id = peek_type_byte(after_name)
      updated = if type_id, do: [{candidate, type_id} | acc], else: acc
      <<_consumed::binary-size(len), rest2::binary>> = rest
      scan_for_names(rest2, updated)
    else
      <<_first_byte::8, rest2::binary>> = rest
      scan_for_names(<<len::little-16, rest2::binary>>, acc)
    end
  end

  defp scan_for_names(<<_byte::8, rest::binary>>, acc), do: scan_for_names(rest, acc)

  @spec printable_ascii?(binary()) :: boolean()
  defp printable_ascii?(<<>>), do: false

  defp printable_ascii?(bin) do
    Enum.all?(:binary.bin_to_list(bin), fn b -> b >= 0x20 and b <= 0x7E end)
  end

  @known_types [
    @type_int8,
    @type_int16,
    @type_int32,
    @type_int64,
    @type_uint8,
    @type_uint16,
    @type_uint32,
    @type_uint64,
    @type_float32,
    @type_float64,
    @type_bool,
    @type_utf8,
    @type_timestamp
  ]

  # Peek into a 16-byte window after the name for a recognised type byte.
  @spec peek_type_byte(binary()) :: non_neg_integer() | nil
  defp peek_type_byte(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.take(16)
    |> Enum.find(fn b -> b in @known_types end)
  end

  # ---------------------------------------------------------------------------
  # Private: record batch decoding
  # ---------------------------------------------------------------------------

  @spec decode_batches([FlightData.t()], [column_schema()]) ::
          {:ok, [map()]} | {:error, term()}
  defp decode_batches([], _columns), do: {:ok, []}

  defp decode_batches(batch_msgs, columns) do
    Enum.reduce_while(batch_msgs, {:ok, []}, fn msg, {:ok, acc} ->
      case decode_batch(msg, columns) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec decode_batch(FlightData.t(), [column_schema()]) :: {:ok, [map()]} | {:error, term()}
  defp decode_batch(%FlightData{data_header: header, data_body: body}, columns) do
    with {:ok, row_count, buffer_specs} <- parse_record_batch_header(header, columns),
         {:ok, col_vectors} <- decode_columns(columns, buffer_specs, body, row_count) do
      {:ok, zip_columns(columns, col_vectors, row_count)}
    end
  rescue
    e -> {:error, {:decode_error, Exception.message(e)}}
  end

  @spec parse_record_batch_header(binary() | nil, [column_schema()]) ::
          {:ok, non_neg_integer(), list()} | {:error, term()}
  defp parse_record_batch_header(nil, _cols), do: {:ok, 0, []}
  defp parse_record_batch_header(<<>>, _cols), do: {:ok, 0, []}

  defp parse_record_batch_header(header, columns) do
    stripped = strip_continuation(header)
    {row_count, rest} = scan_for_row_count(stripped)
    buffer_specs = extract_buffer_specs(rest, length(columns))
    {:ok, row_count, buffer_specs}
  rescue
    _err -> {:error, :batch_header_parse_failed}
  end

  @spec scan_for_row_count(binary()) :: {non_neg_integer(), binary()}
  defp scan_for_row_count(data), do: do_scan_row_count(data)

  @spec do_scan_row_count(binary()) :: {non_neg_integer(), binary()}
  defp do_scan_row_count(<<count::little-64, rest::binary>>)
       when count > 0 and count < 1_000_000_000,
       do: {count, rest}

  defp do_scan_row_count(<<_byte::8, rest::binary>>), do: do_scan_row_count(rest)
  defp do_scan_row_count(<<>>), do: {0, <<>>}

  @spec extract_buffer_specs(binary(), non_neg_integer()) ::
          [{non_neg_integer(), non_neg_integer()}]
  defp extract_buffer_specs(data, num_columns) do
    data |> scan_buffer_pairs([]) |> Enum.take(num_columns * 3)
  end

  @spec scan_buffer_pairs(binary(), list()) :: [{non_neg_integer(), non_neg_integer()}]
  defp scan_buffer_pairs(<<>>, acc), do: Enum.reverse(acc)

  defp scan_buffer_pairs(<<offset::little-64, len::little-64, rest::binary>>, acc)
       when offset >= 0 and len >= 0 and
              offset < 1_000_000_000 and len < 100_000_000,
       do: scan_buffer_pairs(rest, [{offset, len} | acc])

  defp scan_buffer_pairs(<<_byte::8, rest::binary>>, acc), do: scan_buffer_pairs(rest, acc)

  # ---------------------------------------------------------------------------
  # Private: column decoding
  # ---------------------------------------------------------------------------

  @spec decode_columns(
          [column_schema()],
          [{non_neg_integer(), non_neg_integer()}],
          binary() | nil,
          non_neg_integer()
        ) :: {:ok, [[term()]]} | {:error, term()}
  defp decode_columns(columns, buffer_specs, body, row_count) do
    body = body || <<>>

    {col_vectors, _remaining} =
      Enum.map_reduce(columns, buffer_specs, fn col, specs ->
        {allocated, rest} = allocate_buffers(col.type_id, specs)
        vector = decode_column(col.type_id, allocated, body, row_count)
        {vector, rest}
      end)

    {:ok, col_vectors}
  rescue
    e -> {:error, {:column_decode_error, Exception.message(e)}}
  end

  @spec allocate_buffers(non_neg_integer(), list()) :: {list(), list()}
  defp allocate_buffers(@type_utf8, specs), do: {Enum.take(specs, 3), Enum.drop(specs, 3)}
  defp allocate_buffers(_type_id, specs), do: {Enum.take(specs, 2), Enum.drop(specs, 2)}

  @spec decode_column(non_neg_integer(), list(), binary(), non_neg_integer()) :: [term()]
  defp decode_column(_type_id, [], _body, n), do: List.duplicate(nil, n)

  defp decode_column(type_id, [{_voff, vlen} | data_specs], body, n) do
    validity =
      case data_specs do
        [{off, _len} | _rest] when vlen > 0 -> safe_slice(body, off - vlen, vlen)
        _other -> nil
      end

    values = decode_column_values(type_id, data_specs, body, n)
    apply_nulls(values, validity, n)
  end

  @spec decode_column_values(non_neg_integer(), list(), binary(), non_neg_integer()) :: [term()]
  defp decode_column_values(@type_utf8, [{oo, ol}, {doff, dlen} | _rest], body, _n) do
    decode_utf8_column(safe_slice(body, oo, ol), safe_slice(body, doff, dlen))
  end

  defp decode_column_values(@type_utf8, [{oo, _off_len} | _rest], body, _n) do
    decode_utf8_column(<<>>, safe_slice(body, oo, byte_size(body) - oo))
  end

  defp decode_column_values(type_id, [{doff, dlen} | _rest], body, n) do
    data = safe_slice(body, doff, dlen)
    width = Map.get(@byte_widths, type_id, 0)
    decode_fixed_column(type_id, data, width, n)
  end

  defp decode_column_values(_type_id, [], _body, n), do: List.duplicate(nil, n)

  @spec decode_fixed_column(non_neg_integer(), binary(), non_neg_integer(), non_neg_integer()) ::
          [term()]
  defp decode_fixed_column(@type_int64, d, 8, n), do: decode_ints(d, n, 8, :signed)
  defp decode_fixed_column(@type_timestamp, d, 8, n), do: decode_ints(d, n, 8, :signed)
  defp decode_fixed_column(@type_uint64, d, 8, n), do: decode_ints(d, n, 8, :unsigned)
  defp decode_fixed_column(@type_float64, d, 8, n), do: decode_floats(d, n, 8)
  defp decode_fixed_column(@type_float32, d, 4, n), do: decode_floats(d, n, 4)
  defp decode_fixed_column(@type_int32, d, 4, n), do: decode_ints(d, n, 4, :signed)
  defp decode_fixed_column(@type_uint32, d, 4, n), do: decode_ints(d, n, 4, :unsigned)
  defp decode_fixed_column(@type_int16, d, 2, n), do: decode_ints(d, n, 2, :signed)
  defp decode_fixed_column(@type_uint16, d, 2, n), do: decode_ints(d, n, 2, :unsigned)
  defp decode_fixed_column(@type_int8, d, 1, n), do: decode_ints(d, n, 1, :signed)
  defp decode_fixed_column(@type_uint8, d, 1, n), do: decode_ints(d, n, 1, :unsigned)
  defp decode_fixed_column(@type_bool, d, 0, n), do: decode_bools(d, n)
  defp decode_fixed_column(_type_id, _d, _w, n), do: List.duplicate(nil, n)

  @spec decode_ints(binary(), non_neg_integer(), pos_integer(), :signed | :unsigned) ::
          [integer() | nil]
  defp decode_ints(data, n, width, signedness) do
    for i <- 0..(n - 1) do
      chunk = safe_slice(data, i * width, width)
      decode_int_chunk(chunk, width, signedness)
    end
  end

  @spec decode_int_chunk(binary(), pos_integer(), :signed | :unsigned) :: integer() | nil
  defp decode_int_chunk(<<v::little-signed-64>>, 8, :signed), do: v
  defp decode_int_chunk(<<v::little-unsigned-64>>, 8, :unsigned), do: v
  defp decode_int_chunk(<<v::little-signed-32>>, 4, :signed), do: v
  defp decode_int_chunk(<<v::little-unsigned-32>>, 4, :unsigned), do: v
  defp decode_int_chunk(<<v::little-signed-16>>, 2, :signed), do: v
  defp decode_int_chunk(<<v::little-unsigned-16>>, 2, :unsigned), do: v
  defp decode_int_chunk(<<v::little-signed-8>>, 1, :signed), do: v
  defp decode_int_chunk(<<v::little-unsigned-8>>, 1, :unsigned), do: v
  defp decode_int_chunk(_chunk, _width, _sign), do: nil

  @spec decode_floats(binary(), non_neg_integer(), pos_integer()) :: [float() | nil]
  defp decode_floats(data, n, width) do
    for i <- 0..(n - 1) do
      chunk = safe_slice(data, i * width, width)
      decode_float_chunk(chunk, width)
    end
  end

  @spec decode_float_chunk(binary(), pos_integer()) :: float() | nil
  defp decode_float_chunk(<<v::little-float-64>>, 8), do: v
  defp decode_float_chunk(<<v::little-float-32>>, 4), do: v * 1.0
  defp decode_float_chunk(_chunk, _width), do: nil

  @spec decode_bools(binary(), non_neg_integer()) :: [boolean() | nil]
  defp decode_bools(data, n) do
    for i <- 0..(n - 1) do
      byte_idx = div(i, 8)
      bit_idx = rem(i, 8)

      if byte_idx < byte_size(data) do
        (:binary.at(data, byte_idx) >>> bit_idx &&& 1) == 1
      else
        nil
      end
    end
  end

  @spec decode_utf8_column(binary(), binary()) :: [binary() | nil]
  defp decode_utf8_column(<<>>, _data), do: []

  defp decode_utf8_column(offsets_bin, data_bin) do
    n_offsets = div(byte_size(offsets_bin), 4)

    if n_offsets < 2 do
      []
    else
      offsets =
        for i <- 0..(n_offsets - 1) do
          <<v::little-signed-32>> = binary_part(offsets_bin, i * 4, 4)
          v
        end

      offsets
      |> Enum.zip(Enum.drop(offsets, 1))
      |> Enum.map(fn {start, stop} ->
        len = stop - start

        if len >= 0 and start >= 0 and start + len <= byte_size(data_bin) do
          binary_part(data_bin, start, len)
        else
          nil
        end
      end)
    end
  end

  @spec apply_nulls([term()], binary() | nil, non_neg_integer()) :: [term()]
  defp apply_nulls(values, nil, _n), do: values
  defp apply_nulls(values, <<>>, _n), do: values

  defp apply_nulls(values, validity, n) do
    0..(n - 1)
    |> Enum.zip(values)
    |> Enum.map(fn {i, value} ->
      byte_idx = div(i, 8)
      bit_idx = rem(i, 8)

      valid? =
        byte_idx < byte_size(validity) and
          (:binary.at(validity, byte_idx) >>> bit_idx &&& 1) == 1

      if valid?, do: value, else: nil
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: row assembly
  # ---------------------------------------------------------------------------

  @spec zip_columns([column_schema()], [[term()]], non_neg_integer()) :: [map()]
  defp zip_columns(_columns, _vectors, 0), do: []

  defp zip_columns(columns, vectors, n) do
    names = Enum.map(columns, & &1.name)

    for i <- 0..(n - 1) do
      names
      |> Enum.zip(vectors)
      |> Enum.map(fn {name, col} -> {name, Enum.at(col, i)} end)
      |> Map.new()
    end
  end

  # ---------------------------------------------------------------------------
  # Private: binary utilities
  # ---------------------------------------------------------------------------

  @spec safe_slice(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  defp safe_slice(bin, offset, len) when is_binary(bin) and offset >= 0 and len >= 0 do
    available = byte_size(bin) - offset

    cond do
      available <= 0 -> <<>>
      len <= available -> binary_part(bin, offset, len)
      true -> binary_part(bin, offset, available)
    end
  end

  defp safe_slice(_bin, _offset, _len), do: <<>>
end
