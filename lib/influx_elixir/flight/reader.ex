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

  Every type decodes to the value the HTTP transport returns for it, so a
  row is the same map on both (verified against InfluxDB 3, and recorded in
  `test/fixtures/flight`):

  | Arrow Type | Elixir value |
  |------------|--------------|
  | Int8-64, UInt8-64 | `integer()` |
  | Float16/32/64 | `float()` |
  | Bool | `boolean()` |
  | Utf8, LargeUtf8, Utf8View (string functions return it) | `binary()` |
  | Binary, LargeBinary, BinaryView | lowercase hex, as HTTP renders it |
  | Timestamp | `DateTime.t()` (microsecond precision, as on HTTP) |
  | Date32/64 | `"YYYY-MM-DD"` |
  | Duration | `"PT60S"`, `"PT0.5S"`, `"-PT0.000000001S"`, `"P0D"` |
  | Decimal128/256 | a number (integer at scale 0, else float) |
  | Struct (`selector_*` without a subscript) | a map of its members |
  | List, LargeList, FixedSizeList (`array_agg`) | a list |
  | Null | `nil` |

  Nested types are read with the batch's field nodes and, for view types,
  its variadic buffer counts, in Arrow's depth-first layout.

  Null bitmaps are supported. A null cell is left out of the row map, the
  same as a null column in InfluxDB 3's JSON, so a row is identical over
  Flight and HTTP; assert with `refute Map.has_key?(row, "col")`.

  ## Limitations

  Interval, Time, Map, Union, FixedSizeBinary, run-end encoded and
  list-view columns, dictionary-encoded fields and compressed IPC bodies
  are refused with `{:error, {:unsupported_arrow_type, type, column}}`
  rather than dropped. (InfluxDB 3 sends tag columns hydrated, so their
  `Dictionary(Int32, Utf8)` type does not reach the reader.)
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

  @fb_type_null 1
  @fb_type_binary 4
  @fb_type_decimal 7
  @fb_type_date 8
  @fb_type_list 12
  @fb_type_struct 13
  @fb_type_fixed_size_list 16
  @fb_type_duration 18
  @fb_type_large_binary 19
  @fb_type_large_utf8 20
  @fb_type_large_list 21
  @fb_type_binary_view 23
  @fb_type_utf8_view 24

  # Names for the types refused by name.
  @fb_type_names %{
    9 => "Time",
    11 => "Interval",
    14 => "Union",
    15 => "FixedSizeBinary",
    17 => "Map",
    22 => "RunEndEncoded",
    25 => "ListView",
    26 => "LargeListView"
  }

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

  # Arrow TimeUnit enum (Timestamp table slot 0)
  @time_units %{0 => :second, 1 => :millisecond, 2 => :microsecond, 3 => :nanosecond}

  @typedoc "How a column decodes (see \"Supported Column Types\")."
  @type kind ::
          :primitive
          | :null
          | :binary
          | :large_binary
          | :large_utf8
          | :binary_view
          | :utf8_view
          | :float16
          | :struct
          | :list
          | :large_list
          | {:fixed_size_list, integer()}
          | {:duration, System.time_unit()}
          | {:date, :day | :millisecond}
          | {:decimal, integer(), integer()}
          | {:unsupported, binary()}

  @typedoc "Parsed column schema entry (`unit` is set for Timestamp columns)"
  @type column_schema :: %{
          name: binary(),
          type_id: non_neg_integer(),
          unit: System.time_unit() | nil,
          kind: kind(),
          children: [column_schema()]
        }

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
          for i <- 0..(count - 1)//1 do
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

    # Field slot 4: dictionary encoding; slot 5: children (nested types).
    dictionary? = FB.field_pos(fb, field_pos, vt_pos, vt_size, 4) != nil

    children =
      case FB.field_pos(fb, field_pos, vt_pos, vt_size, 5) do
        nil ->
          []

        pos ->
          {start, count} = FB.read_vector_header(fb, pos)

          for i <- 0..(count - 1)//1,
              do: parse_field_table(fb, FB.read_vector_table(fb, start, i))
      end

    kind =
      if dictionary?,
        do: {:unsupported, "Dictionary"},
        else: field_kind(fb, type_type, type_table_pos, type_id)

    %{
      name: name,
      type_id: type_id,
      unit: timestamp_unit(fb, type_type, type_table_pos),
      kind: kind,
      children: children
    }
  end

  # How a column decodes. The flat types the reader has always handled are
  # `:primitive` (decoded by `type_id`); the rest are what InfluxDB 3
  # returns for functions, casts and aggregates (verified), and anything
  # else is refused by name rather than dropped.
  @spec field_kind(binary(), non_neg_integer(), non_neg_integer() | nil, non_neg_integer()) ::
          term()
  defp field_kind(_fb, _type_type, _pos, type_id) when type_id != 0, do: :primitive
  defp field_kind(_fb, @fb_type_null, _pos, _type_id), do: :null
  defp field_kind(_fb, @fb_type_binary, _pos, _type_id), do: :binary
  defp field_kind(_fb, @fb_type_large_binary, _pos, _type_id), do: :large_binary
  defp field_kind(_fb, @fb_type_large_utf8, _pos, _type_id), do: :large_utf8
  defp field_kind(_fb, @fb_type_binary_view, _pos, _type_id), do: :binary_view
  defp field_kind(_fb, @fb_type_utf8_view, _pos, _type_id), do: :utf8_view
  defp field_kind(_fb, @fb_type_struct, _pos, _type_id), do: :struct
  defp field_kind(_fb, @fb_type_list, _pos, _type_id), do: :list
  defp field_kind(_fb, @fb_type_large_list, _pos, _type_id), do: :large_list

  defp field_kind(fb, @fb_type_fixed_size_list, pos, _type_id),
    do: {:fixed_size_list, type_slot(fb, pos, 0, :int32, 0)}

  defp field_kind(fb, @fb_type_duration, pos, _type_id),
    do: {:duration, Map.get(@time_units, type_slot(fb, pos, 0, :int16, 1), :millisecond)}

  defp field_kind(fb, @fb_type_date, pos, _type_id),
    do: {:date, if(type_slot(fb, pos, 0, :int16, 1) == 0, do: :day, else: :millisecond)}

  defp field_kind(fb, @fb_type_decimal, pos, _type_id),
    do: {:decimal, type_slot(fb, pos, 1, :int32, 0), div(type_slot(fb, pos, 2, :int32, 128), 8)}

  defp field_kind(fb, @fb_type_floating_point, pos, _type_id) do
    if type_slot(fb, pos, 0, :int16, 2) == 0, do: :float16, else: {:unsupported, "FloatingPoint"}
  end

  defp field_kind(_fb, type_type, _pos, _type_id),
    do: {:unsupported, Map.get(@fb_type_names, type_type, "type #{type_type}")}

  # A scalar slot of a type table, or its default when absent.
  @spec type_slot(
          binary(),
          non_neg_integer() | nil,
          non_neg_integer(),
          :int16 | :int32,
          integer()
        ) ::
          integer()
  defp type_slot(_fb, nil, _slot, _kind, default), do: default

  defp type_slot(fb, type_pos, slot, kind, default) do
    {vt_pos, vt_size} = FB.read_vtable(fb, type_pos)

    case FB.field_pos(fb, type_pos, vt_pos, vt_size, slot) do
      nil -> default
      pos when kind == :int16 -> FB.read_int16(fb, pos)
      pos -> FB.read_int32(fb, pos)
    end
  end

  # Timestamp slot 0: unit (int16 TimeUnit enum). Absent means SECOND per
  # the Arrow schema default; InfluxDB writes NANOSECOND explicitly.
  @spec timestamp_unit(binary(), non_neg_integer(), non_neg_integer() | nil) ::
          System.time_unit() | nil
  defp timestamp_unit(fb, @fb_type_timestamp, type_pos) when type_pos != nil do
    {vt_pos, vt_size} = FB.read_vtable(fb, type_pos)

    case FB.field_pos(fb, type_pos, vt_pos, vt_size, 0) do
      nil -> :second
      pos -> Map.get(@time_units, FB.read_int16(fb, pos), :nanosecond)
    end
  end

  defp timestamp_unit(_fb, @fb_type_timestamp, nil), do: :second
  defp timestamp_unit(_fb, _type_type, _type_pos), do: nil

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

  # Batches are collected newest-first and concatenated once at the end;
  # appending each batch with `++` was quadratic in the number of batches.
  defp decode_batches(batch_msgs, columns) do
    batch_msgs
    |> Enum.reduce_while({:ok, []}, fn msg, {:ok, acc} ->
      case decode_batch(msg, columns) do
        {:ok, rows} -> {:cont, {:ok, [rows | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, batches} -> {:ok, batches |> Enum.reverse() |> Enum.concat()}
      {:error, _reason} = err -> err
    end
  end

  @spec decode_batch(FlightData.t(), [column_schema()]) ::
          {:ok, [map()]} | {:error, term()}
  defp decode_batch(
         %FlightData{data_header: header, data_body: body},
         columns
       ) do
    with {:ok, row_count, buffer_specs, meta} <-
           parse_record_batch_header(header),
         :ok <- check_uncompressed(meta),
         :ok <- check_row_counts(columns, row_count, meta.nodes, body),
         {:ok, col_vectors} <-
           decode_columns(columns, buffer_specs, body, row_count, meta) do
      {:ok, zip_columns(columns, col_vectors, row_count)}
    end
  rescue
    e -> {:error, {:decode_error, Exception.message(e)}}
  catch
    {:unsupported_arrow_type, type, column} -> {:error, {:unsupported_arrow_type, type, column}}
  end

  @spec check_uncompressed(map()) :: :ok | {:error, term()}
  defp check_uncompressed(%{compressed: true}),
    do: {:error, {:unsupported_arrow_type, "compressed IPC body", nil}}

  defp check_uncompressed(_meta), do: :ok

  @empty_meta %{nodes: [], variadic: [], compressed: false}

  @spec parse_record_batch_header(binary() | nil) ::
          {:ok, non_neg_integer(), [{non_neg_integer(), non_neg_integer()}], map()}
          | {:error, term()}
  defp parse_record_batch_header(nil), do: {:ok, 0, [], @empty_meta}
  defp parse_record_batch_header(<<>>), do: {:ok, 0, [], @empty_meta}

  defp parse_record_batch_header(header) do
    fb = strip_continuation(header)

    if byte_size(fb) < 8 do
      {:ok, 0, [], @empty_meta}
    else
      parse_message_record_batch(fb)
    end
  rescue
    _err -> {:error, :batch_header_parse_failed}
  end

  @spec parse_message_record_batch(binary()) ::
          {:ok, non_neg_integer(), [{non_neg_integer(), non_neg_integer()}], map()}
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
          {:ok, 0, [], @empty_meta}

        header_offset_pos ->
          rb_pos = FB.read_offset(fb, header_offset_pos)
          parse_record_batch_table(fb, rb_pos)
      end
    else
      {:ok, 0, [], @empty_meta}
    end
  end

  # Every column is built to its row count, and every row is a map, so a count from a corrupt
  # header (one flipped byte of metadata) would allocate gigabytes. Each node (one per field,
  # depth-first, the order `decode_field/3` reads them) is bounded by its own field:
  #
  #   * a field with data holds at least one bit per row in the body, so its length is at most
  #     8 per byte received (with a small floor for a batch that omits its buffers);
  #   * a field with no buffers of its own (the null type; a struct, whose children carry its
  #     data) is bounded by cells: its length times the batch's fields, at most
  #     `@cells_without_body` — far above any batch the engine sends (8192 rows), and a few
  #     megabytes at most for a corrupt one.
  #
  # A field of a type the reader does not decode is that error first, whatever its count.
  @rows_floor 64
  @cells_without_body 524_288

  @spec check_row_counts(
          [column_schema()],
          integer(),
          [{integer(), integer()}],
          binary() | nil
        ) :: :ok | {:error, term()}
  defp check_row_counts(columns, row_count, nodes, body) do
    fields = Enum.flat_map(columns, &flatten_field/1)
    with_body = max(8 * byte_size(body || <<>>), @rows_floor)
    without_body = div(@cells_without_body, max(length(fields), 1))
    limit = fn kind -> if kind in [:null, :struct], do: without_body, else: with_body end
    batch_limit = fields |> Enum.map(&limit.(&1.kind)) |> Enum.max(fn -> with_body end)

    unsupported = Enum.find(fields, &match?({:unsupported, _type}, &1.kind))
    lengths = Enum.zip(Enum.map(nodes, &elem(&1, 0)), fields)

    cond do
      unsupported ->
        {:unsupported, type} = unsupported.kind
        {:error, {:unsupported_arrow_type, type, unsupported.name}}

      row_count in 0..batch_limit//1 and
          Enum.all?(lengths, fn {len, field} -> len in 0..limit.(field.kind)//1 end) ->
        :ok

      true ->
        {:error, {:decode_error, "a row count the record batch's body cannot hold"}}
    end
  end

  @spec flatten_field(column_schema()) :: [column_schema()]
  defp flatten_field(field), do: [field | Enum.flat_map(field.children, &flatten_field/1)]

  @spec parse_record_batch_table(binary(), non_neg_integer()) ::
          {:ok, non_neg_integer(), [{non_neg_integer(), non_neg_integer()}], map()}
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

          for i <- 0..(count - 1)//1 do
            pos = elem_start + i * 16
            offset = FB.read_int64(fb, pos)
            len = FB.read_int64(fb, pos + 8)
            {offset, len}
          end
      end

    # RecordBatch slot 1: nodes (FieldNode structs: length, null_count —
    # 16 bytes each), one per field depth-first; slot 3: compression;
    # slot 4: variadicBufferCounts (int64s, one per view column).
    nodes = read_int64_pairs(fb, FB.field_pos(fb, rb_pos, vt_pos, vt_size, 1))
    compressed = FB.field_pos(fb, rb_pos, vt_pos, vt_size, 3) != nil

    variadic =
      case FB.field_pos(fb, rb_pos, vt_pos, vt_size, 4) do
        nil ->
          []

        pos ->
          {start, count} = FB.read_vector_header(fb, pos)
          for i <- 0..(count - 1)//1, do: FB.read_int64(fb, start + i * 8)
      end

    {:ok, row_count, buffer_specs, %{nodes: nodes, variadic: variadic, compressed: compressed}}
  end

  @spec read_int64_pairs(binary(), non_neg_integer() | nil) :: [{integer(), integer()}]
  defp read_int64_pairs(_fb, nil), do: []

  defp read_int64_pairs(fb, offset_pos) do
    {start, count} = FB.read_vector_header(fb, offset_pos)

    for i <- 0..(count - 1)//1,
        do: {FB.read_int64(fb, start + i * 16), FB.read_int64(fb, start + i * 16 + 8)}
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
          non_neg_integer(),
          map()
        ) :: {:ok, [[term()]]} | {:error, term()}
  defp decode_columns(columns, buffer_specs, body, row_count, meta) do
    cursor = %{specs: buffer_specs, nodes: meta.nodes, variadic: meta.variadic, rows: row_count}
    {col_vectors, _cursor} = Enum.map_reduce(columns, cursor, &decode_field(&1, &2, body || <<>>))
    {:ok, col_vectors}
  rescue
    e -> {:error, {:column_decode_error, Exception.message(e)}}
  end

  # One field, depth-first as Arrow lays it out: its FieldNode (length,
  # nulls), then its buffers, then its children's. A batch without nodes
  # (a flat, hand-built message) gives every column the batch's length.
  @spec decode_field(column_schema(), map(), binary()) :: {[term()], map()}
  defp decode_field(col, cursor, body) do
    {len, cursor} = pop_node(cursor)
    decode_kind(col.kind, col, len, cursor, body)
  end

  @spec pop_node(map()) :: {non_neg_integer(), map()}
  defp pop_node(%{nodes: [{len, _nulls} | rest]} = cursor), do: {len, %{cursor | nodes: rest}}
  defp pop_node(%{nodes: []} = cursor), do: {cursor.rows, cursor}

  @spec pop_specs(map(), non_neg_integer()) :: {list(), map()}
  defp pop_specs(cursor, n) do
    {taken, rest} = Enum.split(cursor.specs, n)
    {taken, %{cursor | specs: rest}}
  end

  @spec decode_kind(term(), column_schema(), non_neg_integer(), map(), binary()) ::
          {[term()], map()}
  defp decode_kind(:primitive, col, len, cursor, body) do
    {allocated, cursor} = pop_specs(cursor, if(col.type_id == @type_utf8, do: 3, else: 2))
    {col.type_id |> decode_column(allocated, body, len) |> to_datetimes(col), cursor}
  end

  defp decode_kind(:null, _col, len, cursor, _body), do: {List.duplicate(nil, len), cursor}

  defp decode_kind(kind, _col, len, cursor, body)
       when kind in [:binary, :large_binary, :large_utf8] do
    {specs, cursor} = pop_specs(cursor, 3)
    [validity, offsets, data] = pad_specs(specs, 3)
    width = if kind == :binary, do: 4, else: 8

    values =
      body
      |> slice(offsets)
      |> offsets_list(width)
      |> var_width_values(slice(body, data))
      |> fit(len)
      |> Enum.map(&render_bytes(kind, &1))

    {apply_nulls(values, slice_validity(body, validity), len), cursor}
  end

  defp decode_kind(kind, _col, len, cursor, body) when kind in [:utf8_view, :binary_view] do
    {specs, cursor} = pop_specs(cursor, 2)
    [validity, views] = pad_specs(specs, 2)
    [count | rest] = if cursor.variadic == [], do: [0], else: cursor.variadic
    {data_specs, cursor} = pop_specs(%{cursor | variadic: rest}, count)
    buffers = Enum.map(data_specs, &slice(body, &1))

    values =
      for <<view::binary-16 <- slice(body, views)>> do
        view
        |> decode_view(buffers)
        |> then(&if(kind == :binary_view, do: Base.encode16(&1, case: :lower), else: &1))
      end

    {apply_nulls(fit(values, len), slice_validity(body, validity), len), cursor}
  end

  defp decode_kind(kind, _col, len, cursor, body)
       when kind == :float16 or elem(kind, 0) in [:duration, :date, :decimal] do
    {specs, cursor} = pop_specs(cursor, 2)
    [validity, data] = pad_specs(specs, 2)
    values = kind |> decode_fixed_kind(slice(body, data)) |> fit(len)
    {apply_nulls(values, slice_validity(body, validity), len), cursor}
  end

  defp decode_kind(:struct, col, len, cursor, body) do
    {specs, cursor} = pop_specs(cursor, 1)
    [validity] = pad_specs(specs, 1)
    {vectors, cursor} = Enum.map_reduce(col.children, cursor, &decode_field(&1, &2, body))

    # Null members are left out, as they are left out of a row.
    rows =
      zip_columns(col.children, vectors, len)
      |> fit(len)

    {apply_nulls(rows, slice_validity(body, validity), len), cursor}
  end

  defp decode_kind(kind, col, len, cursor, body) when kind in [:list, :large_list] do
    {specs, cursor} = pop_specs(cursor, 2)
    [validity, offsets] = pad_specs(specs, 2)
    {items, cursor} = decode_field(hd(col.children), cursor, body)
    items = List.to_tuple(items)

    lists =
      body
      |> slice(offsets)
      |> offsets_list(if kind == :list, do: 4, else: 8)
      |> pairs()
      # Offsets lie inside the child array; clamped, a corrupt one cannot make
      # a list of billions of nils.
      |> Enum.map(fn {from, to} ->
        for i <- max(from, 0)..(min(to, tuple_size(items)) - 1)//1, do: elem(items, i)
      end)
      |> fit(len)

    {apply_nulls(lists, slice_validity(body, validity), len), cursor}
  end

  defp decode_kind({:fixed_size_list, size}, col, len, cursor, body) do
    {specs, cursor} = pop_specs(cursor, 1)
    [validity] = pad_specs(specs, 1)
    {items, cursor} = decode_field(hd(col.children), cursor, body)
    lists = items |> Enum.chunk_every(max(size, 1)) |> fit(len)
    {apply_nulls(lists, slice_validity(body, validity), len), cursor}
  end

  defp decode_kind({:unsupported, type}, col, _len, _cursor, _body),
    do: throw({:unsupported_arrow_type, type, col.name})

  # ---------------------------------------------------------------------------
  # Private: the decoders for the non-primitive kinds
  # ---------------------------------------------------------------------------

  @spec pad_specs(list(), non_neg_integer()) :: list()
  defp pad_specs(specs, n), do: specs ++ List.duplicate(nil, n - length(specs))

  @spec slice(binary(), {non_neg_integer(), non_neg_integer()} | nil) :: binary()
  defp slice(_body, nil), do: <<>>
  defp slice(body, {offset, len}), do: safe_slice(body, offset, len)

  @spec slice_validity(binary(), {non_neg_integer(), non_neg_integer()} | nil) :: binary() | nil
  defp slice_validity(_body, nil), do: nil
  defp slice_validity(_body, {_offset, 0}), do: nil
  defp slice_validity(body, spec), do: slice(body, spec)

  @spec offsets_list(binary(), 4 | 8) :: [integer()]
  defp offsets_list(bin, 4), do: for(<<v::little-signed-32 <- bin>>, do: v)
  defp offsets_list(bin, 8), do: for(<<v::little-signed-64 <- bin>>, do: v)

  @spec pairs([integer()]) :: [{integer(), integer()}]
  defp pairs([]), do: []
  defp pairs(offsets), do: Enum.zip(offsets, tl(offsets))

  @spec var_width_values([integer()], binary()) :: [binary() | nil]
  defp var_width_values(offsets, data) do
    for {from, to} <- pairs(offsets) do
      if from >= 0 and to >= from and to <= byte_size(data),
        do: binary_part(data, from, to - from),
        else: nil
    end
  end

  # HTTP renders binary as lowercase hex (`CAST(host AS BYTEA)` is "61").
  @spec render_bytes(atom(), binary() | nil) :: binary() | nil
  defp render_bytes(_kind, nil), do: nil
  defp render_bytes(:large_utf8, value), do: value
  defp render_bytes(_binary, value), do: Base.encode16(value, case: :lower)

  # A view is 16 bytes: the length, then the bytes inline (12 or fewer) or
  # a 4-byte prefix, the data buffer's index and the offset in it.
  @spec decode_view(binary(), [binary()]) :: binary() | nil
  defp decode_view(<<len::little-32, inline::binary-12>>, _buffers) when len <= 12,
    do: binary_part(inline, 0, len)

  defp decode_view(
         <<len::little-32, _prefix::binary-4, index::little-32, offset::little-32>>,
         buffers
       ) do
    buffer = Enum.at(buffers, index, <<>>)
    if offset + len <= byte_size(buffer), do: binary_part(buffer, offset, len), else: nil
  end

  @spec decode_fixed_kind(term(), binary()) :: [term()]
  defp decode_fixed_kind(:float16, data), do: for(<<v::little-float-16 <- data>>, do: v)

  defp decode_fixed_kind({:duration, unit}, data) do
    for <<v::little-signed-64 <- data>>,
      do: render_duration(System.convert_time_unit(v, unit, :nanosecond))
  end

  defp decode_fixed_kind({:date, :day}, data),
    do: for(<<d::little-signed-32 <- data>>, do: Date.to_iso8601(Date.add(~D[1970-01-01], d)))

  defp decode_fixed_kind({:date, :millisecond}, data) do
    for <<ms::little-signed-64 <- data>>,
      do: Date.to_iso8601(Date.add(~D[1970-01-01], Integer.floor_div(ms, 86_400_000)))
  end

  defp decode_fixed_kind({:decimal, scale, bytes}, data) do
    bits = bytes * 8
    for <<v::little-signed-size(bits) <- data>>, do: scale_decimal(v, scale)
  end

  # HTTP's JSON has the decimal as a number: an integer at scale 0, else a
  # float (`CAST(v AS DECIMAL(10,2))` of 1.5 is 1.5).
  @spec scale_decimal(integer(), integer()) :: number()
  defp scale_decimal(v, 0), do: v
  defp scale_decimal(v, scale), do: v / Integer.pow(10, scale)

  # InfluxDB 3's HTTP rendering of a Duration (verified): `P0D` for zero,
  # else `[-]PT<seconds>[.<fraction>]S` with the fraction's trailing zeros
  # dropped — `PT60S`, `PT0.5S`, `-PT0.000000001S`, `PT7199.75S`.
  @doc false
  @spec render_duration(integer()) :: binary()
  def render_duration(0), do: "P0D"
  def render_duration(ns) when ns < 0, do: "-" <> render_duration(-ns)

  def render_duration(ns) do
    seconds = div(ns, 1_000_000_000)

    fraction =
      case rem(ns, 1_000_000_000) do
        0 ->
          ""

        frac ->
          "." <>
            (frac
             |> Integer.to_string()
             |> String.pad_leading(9, "0")
             |> String.trim_trailing("0"))
      end

    "PT#{seconds}#{fraction}S"
  end

  # Timestamps come off the wire as integers in the column's unit. They are
  # converted to DateTime so a row is the same whether it arrived over
  # Flight or HTTP (where ResponseParser converts the RFC3339 string).
  @spec to_datetimes([term()], column_schema()) :: [term()]
  defp to_datetimes(values, %{type_id: @type_timestamp, unit: unit}) do
    Enum.map(values, fn
      nil ->
        nil

      value ->
        value
        |> DateTime.from_unix!(unit || :nanosecond)
        |> InfluxElixir.Query.ResponseParser.microsecond_precision()
    end)
  end

  defp to_datetimes(values, _column), do: values

  @spec decode_column(non_neg_integer(), list(), binary(), non_neg_integer()) ::
          [term()]
  defp decode_column(_type_id, [], _body, n), do: List.duplicate(nil, n)

  # The validity buffer's position is taken directly from the RecordBatch
  # buffer metadata. Arrow IPC aligns each buffer (8-byte minimum, 64-byte
  # recommended), so the validity offset cannot be derived from the data
  # buffer offset by subtracting the validity length — that arithmetic lands
  # in alignment padding, which would mask every value to nil.
  defp decode_column(type_id, [{voff, vlen} | data_specs], body, n) do
    validity = if vlen > 0, do: safe_slice(body, voff, vlen), else: nil
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

  # Fixed-width columns are decoded with a binary comprehension — one pass
  # over the buffer with no per-element slicing. A short buffer yields
  # fewer values; `fit/2` pads with nil (or trims) to the batch length.
  @spec decode_ints(
          binary(),
          non_neg_integer(),
          pos_integer(),
          :signed | :unsigned
        ) :: [integer() | nil]
  defp decode_ints(data, n, width, :signed) do
    bits = width * 8
    fit(for(<<v::little-signed-size(bits) <- data>>, do: v), n)
  end

  defp decode_ints(data, n, width, :unsigned) do
    bits = width * 8
    fit(for(<<v::little-unsigned-size(bits) <- data>>, do: v), n)
  end

  @spec decode_floats(binary(), non_neg_integer(), pos_integer()) ::
          [float() | nil]
  defp decode_floats(data, n, width) do
    bits = width * 8
    fit(for(<<v::little-float-size(bits) <- data>>, do: v), n)
  end

  @spec fit([term()], non_neg_integer()) :: [term()]
  defp fit(values, n) do
    case length(values) do
      ^n -> values
      len when len > n -> Enum.take(values, n)
      len -> values ++ List.duplicate(nil, n - len)
    end
  end

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
      offsets = for <<v::little-signed-32 <- offsets_bin>>, do: v

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

  # Columns are converted to tuples once so each cell is an O(1) `elem/2`;
  # `Enum.at/2` on the column lists made row assembly quadratic in the
  # batch's row count. A null cell (or a column shorter than `n`) is left
  # out of the row, as InfluxDB 3's JSON leaves a null column out: a row is
  # the same map over Flight and HTTP (verified against the engine).
  defp zip_columns(columns, vectors, n) do
    named_tuples =
      columns
      |> Enum.map(& &1.name)
      |> Enum.zip(Enum.map(vectors, &List.to_tuple/1))

    for i <- 0..(n - 1)//1 do
      Enum.reduce(named_tuples, %{}, fn {name, col}, row ->
        case cell(col, i) do
          nil -> row
          value -> Map.put(row, name, value)
        end
      end)
    end
  end

  @spec cell(tuple(), non_neg_integer()) :: term()
  defp cell(col, i) when i < tuple_size(col), do: elem(col, i)
  defp cell(_col, _i), do: nil

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
