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

  Schema and record batch metadata is parsed using a proper FlatBuffer
  binary reader (`InfluxElixir.Flight.FlatBuffer`), following the Arrow
  IPC FlatBuffer schema specification exactly.

  ## Supported Column Types

  | Arrow Type | Elixir type    |
  |------------|----------------|
  | Int8-64    | `integer()`    |
  | UInt8-64   | `integer()`    |
  | Float32/64 | `float()`      |
  | Bool       | `boolean()`    |
  | Utf8       | `binary()`     |
  | Timestamp  | `integer()`    |

  Null bitmaps are supported; null values become `nil`.

  ## Limitations

  - Dictionary-encoded columns are not yet decoded.
  - Nested / list / struct types are not supported.
  """

  import Bitwise

  alias InfluxElixir.Flight.FlatBuffer, as: FB
  alias InfluxElixir.Flight.Proto.FlightData

  # Arrow IPC stream continuation marker
  @continuation_marker <<0xFF, 0xFF, 0xFF, 0xFF>>

  # Arrow FlatBuffer Type union discriminator values
  @fb_type_int 2
  @fb_type_floating_point 3
  @fb_type_utf8 5
  @fb_type_bool 6
  @fb_type_timestamp 10

  # Arrow FlatBuffer MessageHeader union discriminator values
  @msg_header_schema 1
  @msg_header_record_batch 3

  # Internal type IDs used by column decoders
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

  # Fixed byte widths per internal type ID (bool uses a bitmap — 0 here)
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

    * `flight_data_list` — ordered list of `FlightData` structs from a DoGet
      stream

  ## Example

      iex> InfluxElixir.Flight.Reader.decode_flight_data([])
      {:ok, []}
  """
  @spec decode_flight_data([FlightData.t()]) ::
          {:ok, [map()]} | {:error, term()}
  def decode_flight_data([]), do: {:ok, []}

  def decode_flight_data([schema_msg | batch_msgs]) do
    with {:ok, columns} <- parse_schema(schema_msg.data_header) do
      decode_batches(batch_msgs, columns)
    end
  end

  # ---------------------------------------------------------------------------
  # Schema parsing (FlatBuffer-based)
  # ---------------------------------------------------------------------------

  @doc """
  Extracts column name/type pairs from an Arrow IPC `Schema` message header.

  Parses the FlatBuffer metadata according to the Arrow IPC specification:
  Message → Schema → Field[] → name + Type union.

  Returns `{:ok, [column_schema()]}` or `{:error, reason}`.
  """
  @spec parse_schema(binary() | nil) ::
          {:ok, [column_schema()]} | {:error, term()}
  def parse_schema(nil), do: {:ok, []}
  def parse_schema(<<>>), do: {:ok, []}

  def parse_schema(header) when is_binary(header) do
    fb = strip_continuation(header)

    if byte_size(fb) < 8 do
      {:ok, []}
    else
      parse_message_schema(fb)
    end
  rescue
    _err -> {:error, :schema_parse_failed}
  end

  @spec parse_message_schema(binary()) ::
          {:ok, [column_schema()]} | {:error, term()}
  defp parse_message_schema(fb) do
    # Read root Message table
    msg_pos = FB.root_table_pos(fb)
    {vt_pos, vt_size} = FB.read_vtable(fb, msg_pos)

    # Message field 1: header_type (union discriminator, uint8)
    header_type =
      case FB.field_pos(fb, msg_pos, vt_pos, vt_size, 1) do
        nil -> 0
        pos -> FB.read_uint8(fb, pos)
      end

    if header_type == @msg_header_schema do
      # Message field 2: header (union value, offset to Schema table)
      case FB.field_pos(fb, msg_pos, vt_pos, vt_size, 2) do
        nil ->
          {:ok, []}

        header_offset_pos ->
          schema_pos = FB.read_offset(fb, header_offset_pos)
          parse_schema_table(fb, schema_pos)
      end
    else
      {:ok, []}
    end
  end

  @spec parse_schema_table(binary(), non_neg_integer()) ::
          {:ok, [column_schema()]}
  defp parse_schema_table(fb, schema_pos) do
    {vt_pos, vt_size} = FB.read_vtable(fb, schema_pos)

    # Schema field 1: fields (vector of Field table offsets)
    case FB.field_pos(fb, schema_pos, vt_pos, vt_size, 1) do
      nil ->
        {:ok, []}

      fields_offset_pos ->
        {elem_start, count} = FB.read_vector_header(fb, fields_offset_pos)

        columns =
          for i <- 0..(count - 1) do
            field_pos = FB.read_vector_table(fb, elem_start, i)
            parse_field_table(fb, field_pos)
          end

        {:ok, columns}
    end
  end

  @spec parse_field_table(binary(), non_neg_integer()) :: column_schema()
  defp parse_field_table(fb, field_pos) do
    {vt_pos, vt_size} = FB.read_vtable(fb, field_pos)

    # Field slot 0: name (string)
    name =
      case FB.field_pos(fb, field_pos, vt_pos, vt_size, 0) do
        nil -> ""
        pos -> FB.read_string(fb, pos)
      end

    # Field slot 2: type_type (union discriminator, uint8)
    type_type =
      case FB.field_pos(fb, field_pos, vt_pos, vt_size, 2) do
        nil -> 0
        pos -> FB.read_uint8(fb, pos)
      end

    # Field slot 3: type (union value, offset to type-specific table)
    type_table_pos =
      case FB.field_pos(fb, field_pos, vt_pos, vt_size, 3) do
        nil -> nil
        pos -> FB.read_offset(fb, pos)
      end

    type_id = resolve_type_id(fb, type_type, type_table_pos)
    %{name: name, type_id: type_id}
  end

  @spec resolve_type_id(binary(), non_neg_integer(), non_neg_integer() | nil) ::
          non_neg_integer()
  defp resolve_type_id(fb, @fb_type_int, type_pos) when type_pos != nil do
    {vt_pos, vt_size} = FB.read_vtable(fb, type_pos)

    # Int slot 0: bitWidth (int32)
    bit_width =
      case FB.field_pos(fb, type_pos, vt_pos, vt_size, 0) do
        nil -> 32
        pos -> FB.read_int32(fb, pos)
      end

    # Int slot 1: is_signed (bool)
    is_signed =
      case FB.field_pos(fb, type_pos, vt_pos, vt_size, 1) do
        nil -> true
        pos -> FB.read_bool(fb, pos)
      end

    map_int_type(bit_width, is_signed)
  end

  defp resolve_type_id(fb, @fb_type_floating_point, type_pos)
       when type_pos != nil do
    {vt_pos, vt_size} = FB.read_vtable(fb, type_pos)

    # FloatingPoint slot 0: precision (int16 enum: HALF=0, SINGLE=1, DOUBLE=2)
    precision =
      case FB.field_pos(fb, type_pos, vt_pos, vt_size, 0) do
        nil -> 2
        pos -> FB.read_int16(fb, pos)
      end

    case precision do
      1 -> @type_float32
      _other -> @type_float64
    end
  end

  defp resolve_type_id(_fb, @fb_type_bool, _type_pos), do: @type_bool
  defp resolve_type_id(_fb, @fb_type_utf8, _type_pos), do: @type_utf8
  defp resolve_type_id(_fb, @fb_type_timestamp, _type_pos), do: @type_timestamp
  defp resolve_type_id(_fb, _type_type, _type_pos), do: 0

  @spec map_int_type(integer(), boolean()) :: non_neg_integer()
  defp map_int_type(8, true), do: @type_int8
  defp map_int_type(16, true), do: @type_int16
  defp map_int_type(32, true), do: @type_int32
  defp map_int_type(64, true), do: @type_int64
  defp map_int_type(8, false), do: @type_uint8
  defp map_int_type(16, false), do: @type_uint16
  defp map_int_type(32, false), do: @type_uint32
  defp map_int_type(64, false), do: @type_uint64
  defp map_int_type(_width, _signed), do: 0

  # ---------------------------------------------------------------------------
  # Record batch parsing (FlatBuffer-based)
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

  @spec decode_batch(FlightData.t(), [column_schema()]) ::
          {:ok, [map()]} | {:error, term()}
  defp decode_batch(
         %FlightData{data_header: header, data_body: body},
         columns
       ) do
    with {:ok, row_count, buffer_specs} <-
           parse_record_batch_header(header),
         {:ok, col_vectors} <-
           decode_columns(columns, buffer_specs, body, row_count) do
      {:ok, zip_columns(columns, col_vectors, row_count)}
    end
  rescue
    e -> {:error, {:decode_error, Exception.message(e)}}
  end

  @spec parse_record_batch_header(binary() | nil) ::
          {:ok, non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]}
          | {:error, term()}
  defp parse_record_batch_header(nil), do: {:ok, 0, []}
  defp parse_record_batch_header(<<>>), do: {:ok, 0, []}

  defp parse_record_batch_header(header) do
    fb = strip_continuation(header)

    if byte_size(fb) < 8 do
      {:ok, 0, []}
    else
      parse_message_record_batch(fb)
    end
  rescue
    _err -> {:error, :batch_header_parse_failed}
  end

  @spec parse_message_record_batch(binary()) ::
          {:ok, non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]}
          | {:error, term()}
  defp parse_message_record_batch(fb) do
    msg_pos = FB.root_table_pos(fb)
    {vt_pos, vt_size} = FB.read_vtable(fb, msg_pos)

    # Message field 1: header_type
    header_type =
      case FB.field_pos(fb, msg_pos, vt_pos, vt_size, 1) do
        nil -> 0
        pos -> FB.read_uint8(fb, pos)
      end

    if header_type == @msg_header_record_batch do
      case FB.field_pos(fb, msg_pos, vt_pos, vt_size, 2) do
        nil ->
          {:ok, 0, []}

        header_offset_pos ->
          rb_pos = FB.read_offset(fb, header_offset_pos)
          parse_record_batch_table(fb, rb_pos)
      end
    else
      {:ok, 0, []}
    end
  end

  @spec parse_record_batch_table(binary(), non_neg_integer()) ::
          {:ok, non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]}
  defp parse_record_batch_table(fb, rb_pos) do
    {vt_pos, vt_size} = FB.read_vtable(fb, rb_pos)

    # RecordBatch slot 0: length (int64)
    row_count =
      case FB.field_pos(fb, rb_pos, vt_pos, vt_size, 0) do
        nil -> 0
        pos -> FB.read_int64(fb, pos)
      end

    # RecordBatch slot 2: buffers (vector of Buffer structs, 16 bytes each)
    buffer_specs =
      case FB.field_pos(fb, rb_pos, vt_pos, vt_size, 2) do
        nil ->
          []

        buffers_offset_pos ->
          {elem_start, count} =
            FB.read_vector_header(fb, buffers_offset_pos)

          for i <- 0..(count - 1) do
            pos = elem_start + i * 16
            offset = FB.read_int64(fb, pos)
            len = FB.read_int64(fb, pos + 8)
            {offset, len}
          end
      end

    {:ok, row_count, buffer_specs}
  end

  # ---------------------------------------------------------------------------
  # Private: IPC stream helpers
  # ---------------------------------------------------------------------------

  # Strip IPC stream continuation marker and metadata-length prefix.
  # Format: <<0xFF, 0xFF, 0xFF, 0xFF, len::little-32, flatbuffer...>>
  @spec strip_continuation(binary()) :: binary()
  defp strip_continuation(<<@continuation_marker, _meta_len::little-32, rest::binary>>),
    do: rest

  defp strip_continuation(bin), do: bin

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
  defp allocate_buffers(@type_utf8, specs) do
    {Enum.take(specs, 3), Enum.drop(specs, 3)}
  end

  defp allocate_buffers(_type_id, specs) do
    {Enum.take(specs, 2), Enum.drop(specs, 2)}
  end

  @spec decode_column(non_neg_integer(), list(), binary(), non_neg_integer()) ::
          [term()]
  defp decode_column(_type_id, [], _body, n), do: List.duplicate(nil, n)

  defp decode_column(type_id, [{_voff, vlen} | data_specs], body, n) do
    validity =
      case data_specs do
        [{off, _len} | _rest] when vlen > 0 ->
          safe_slice(body, off - vlen, vlen)

        _other ->
          nil
      end

    values = decode_column_values(type_id, data_specs, body, n)
    apply_nulls(values, validity, n)
  end

  @spec decode_column_values(
          non_neg_integer(),
          list(),
          binary(),
          non_neg_integer()
        ) :: [term()]
  defp decode_column_values(
         @type_utf8,
         [{oo, ol}, {doff, dlen} | _rest],
         body,
         _n
       ) do
    decode_utf8_column(safe_slice(body, oo, ol), safe_slice(body, doff, dlen))
  end

  defp decode_column_values(
         @type_utf8,
         [{oo, _off_len} | _rest],
         body,
         _n
       ) do
    decode_utf8_column(<<>>, safe_slice(body, oo, byte_size(body) - oo))
  end

  defp decode_column_values(type_id, [{doff, dlen} | _rest], body, n) do
    data = safe_slice(body, doff, dlen)
    width = Map.get(@byte_widths, type_id, 0)
    decode_fixed_column(type_id, data, width, n)
  end

  defp decode_column_values(_type_id, [], _body, n) do
    List.duplicate(nil, n)
  end

  @spec decode_fixed_column(
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [term()]
  defp decode_fixed_column(@type_int64, d, 8, n) do
    decode_ints(d, n, 8, :signed)
  end

  defp decode_fixed_column(@type_timestamp, d, 8, n) do
    decode_ints(d, n, 8, :signed)
  end

  defp decode_fixed_column(@type_uint64, d, 8, n) do
    decode_ints(d, n, 8, :unsigned)
  end

  defp decode_fixed_column(@type_float64, d, 8, n), do: decode_floats(d, n, 8)
  defp decode_fixed_column(@type_float32, d, 4, n), do: decode_floats(d, n, 4)

  defp decode_fixed_column(@type_int32, d, 4, n) do
    decode_ints(d, n, 4, :signed)
  end

  defp decode_fixed_column(@type_uint32, d, 4, n) do
    decode_ints(d, n, 4, :unsigned)
  end

  defp decode_fixed_column(@type_int16, d, 2, n) do
    decode_ints(d, n, 2, :signed)
  end

  defp decode_fixed_column(@type_uint16, d, 2, n) do
    decode_ints(d, n, 2, :unsigned)
  end

  defp decode_fixed_column(@type_int8, d, 1, n) do
    decode_ints(d, n, 1, :signed)
  end

  defp decode_fixed_column(@type_uint8, d, 1, n) do
    decode_ints(d, n, 1, :unsigned)
  end

  defp decode_fixed_column(@type_bool, d, 0, n), do: decode_bools(d, n)
  defp decode_fixed_column(_type_id, _d, _w, n), do: List.duplicate(nil, n)

  @spec decode_ints(
          binary(),
          non_neg_integer(),
          pos_integer(),
          :signed | :unsigned
        ) :: [integer() | nil]
  defp decode_ints(data, n, width, signedness) do
    for i <- 0..(n - 1)//1 do
      chunk = safe_slice(data, i * width, width)
      decode_int_chunk(chunk, width, signedness)
    end
  end

  @spec decode_int_chunk(binary(), pos_integer(), :signed | :unsigned) ::
          integer() | nil
  defp decode_int_chunk(<<v::little-signed-64>>, 8, :signed), do: v
  defp decode_int_chunk(<<v::little-unsigned-64>>, 8, :unsigned), do: v
  defp decode_int_chunk(<<v::little-signed-32>>, 4, :signed), do: v
  defp decode_int_chunk(<<v::little-unsigned-32>>, 4, :unsigned), do: v
  defp decode_int_chunk(<<v::little-signed-16>>, 2, :signed), do: v
  defp decode_int_chunk(<<v::little-unsigned-16>>, 2, :unsigned), do: v
  defp decode_int_chunk(<<v::little-signed-8>>, 1, :signed), do: v
  defp decode_int_chunk(<<v::little-unsigned-8>>, 1, :unsigned), do: v
  defp decode_int_chunk(_chunk, _width, _sign), do: nil

  @spec decode_floats(binary(), non_neg_integer(), pos_integer()) ::
          [float() | nil]
  defp decode_floats(data, n, width) do
    for i <- 0..(n - 1)//1 do
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
    for i <- 0..(n - 1)//1 do
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
    0..(n - 1)//1
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

  @spec zip_columns([column_schema()], [[term()]], non_neg_integer()) ::
          [map()]
  defp zip_columns(_columns, _vectors, 0), do: []

  defp zip_columns(columns, vectors, n) do
    names = Enum.map(columns, & &1.name)

    for i <- 0..(n - 1)//1 do
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
  defp safe_slice(bin, offset, len)
       when is_binary(bin) and offset >= 0 and len >= 0 do
    available = byte_size(bin) - offset

    cond do
      available <= 0 -> <<>>
      len <= available -> binary_part(bin, offset, len)
      true -> binary_part(bin, offset, available)
    end
  end

  defp safe_slice(_bin, _offset, _len), do: <<>>
end
