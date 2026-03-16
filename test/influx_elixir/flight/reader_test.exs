defmodule InfluxElixir.Flight.ReaderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias InfluxElixir.Flight.Proto.FlightData
  alias InfluxElixir.Flight.Reader

  # ---------------------------------------------------------------------------
  # Arrow IPC FlatBuffer builder
  #
  # FlatBuffers use forward-only references: a uoffset32 at position P resolves
  # to absolute address P + value. All referenced objects must sit at higher
  # addresses than their referencing fields.
  #
  # Build strategy: emit sections in the order they appear in memory (low to
  # high), computing exact byte positions analytically before writing bytes.
  # Validate everything with the companion debug script in tmp/.
  #
  # Key sizes (all in bytes):
  #
  # Message vtable: 5 × u16 = 10   (vtable_size, obj_size, s0, s1, s2)
  # Message inline: 12              (soffset:4 + ht:1+3pad + header:4)
  # Schema vtable:  4 × u16 = 8    (vtable_size, obj_size, s0, s1)
  # Schema inline:  8               (soffset:4 + fields_vec:4)
  # Field vtable:   6 × u16 = 12   (vtable_size, obj_size, s0-s3)
  # Field inline:   20              (soffset:4 + name:4 + nullable:4 + tt:4 + type:4)
  # Int vtable:     4 × u16 = 8    (vtable_size, obj_size, s0, s1)
  # Int inline:     10              (soffset:4 + bitWidth:4 + is_signed:1 + pad:1)
  # FP vtable:      3 × u16 = 6    (vtable_size, obj_size, s0)
  # FP inline:      8               (soffset:4 + precision:2 + pad:2)
  # Empty vtable:   2 × u16 = 4    (vtable_size, obj_size)
  # Empty inline:   4               (soffset:4)
  # ---------------------------------------------------------------------------

  # Type-blob vtable sizes (just the vtable portion, in bytes)
  @int_vtable_size 8
  @fp_vtable_size 6
  @empty_vtable_size 4

  # Field blob layout (positions relative to field-blob start)
  @field_vtable_size 12
  @field_obj_size 20
  # 12
  @field_table_offset @field_vtable_size
  # 32
  @field_string_offset @field_table_offset + @field_obj_size

  # Schema/Message layout (absolute positions in the bare FlatBuffer, base=0)
  # root_offset: 4 bytes
  # msg_vtable: 10 bytes
  # msg_inline: 12 bytes → msg_table at 4+10=14, schema_vtable at 14+12=26
  @root_size 4
  # 4
  @msg_vtable_pos @root_size
  @msg_vtable_size 10
  @msg_inline_size 12
  # 14
  @msg_table_pos @msg_vtable_pos + @msg_vtable_size
  # 26
  @schema_vtable_pos @msg_table_pos + @msg_inline_size
  @schema_vtable_size 8
  @schema_inline_size 8
  # 34
  @schema_table_pos @schema_vtable_pos + @schema_vtable_size
  # 42
  @fields_vec_base @schema_table_pos + @schema_inline_size

  # Build a type blob and return {blob_binary, vtable_size_bytes}.
  # The type TABLE within the blob starts at vtable_size_bytes offset from blob start.
  defp build_type_blob(2, opts) do
    bit_width = Keyword.get(opts, :bit_width, 64)
    is_signed_byte = if Keyword.get(opts, :is_signed, true), do: 1, else: 0
    # vtable: 4 × u16 = 8 bytes, vtable_size=8, obj_size=10, s0=4, s1=8
    vtable = <<8::little-16, 10::little-16, 4::little-16, 8::little-16>>
    soffset = byte_size(vtable)
    inline = <<soffset::little-signed-32, bit_width::little-signed-32, is_signed_byte::8, 0::8>>
    {vtable <> inline, @int_vtable_size}
  end

  defp build_type_blob(3, opts) do
    precision = Keyword.get(opts, :precision, 2)
    # vtable: 3 × u16 = 6 bytes, vtable_size=6, obj_size=8, s0=4
    vtable = <<6::little-16, 8::little-16, 4::little-16>>
    soffset = byte_size(vtable)
    inline = <<soffset::little-signed-32, precision::little-signed-16, 0::16>>
    {vtable <> inline, @fp_vtable_size}
  end

  defp build_type_blob(_type_type, _opts) do
    # Bool, Utf8, Timestamp, other: empty table
    # vtable: 2 × u16 = 4 bytes, vtable_size=4, obj_size=4
    vtable = <<4::little-16, 4::little-16>>
    soffset = byte_size(vtable)
    inline = <<soffset::little-signed-32>>
    {vtable <> inline, @empty_vtable_size}
  end

  # Pad a binary to 4-byte alignment with null bytes.
  defp pad4(bin) do
    r = rem(byte_size(bin), 4)
    if r == 0, do: bin, else: bin <> :binary.copy(<<0>>, 4 - r)
  end

  # Build a self-contained field blob.
  # Layout (positions relative to blob start):
  #   [0..11]       field vtable (6 × u16 = 12 bytes)
  #   [12..31]      field inline (20 bytes: soffset+name_rel+4pad+tt_3pad+type_rel)
  #   [32..]        name string  (len:4 + bytes + null, padded to 4)
  #   [32+str_size] type blob    (vtable + inline)
  defp build_field_blob(name, type_type, opts) do
    # Build sub-parts first to know their sizes
    str_raw = <<byte_size(name)::little-32, name::binary, 0::8>>
    str_blob = pad4(str_raw)
    str_size = byte_size(str_blob)

    {type_blob, type_vtable_size} = build_type_blob(type_type, opts)

    # Compute relative offsets (all from the referencing field's position in the blob)

    # name_rel: stored at field_table_offset+4, references the start of str_blob
    # (which is the string length prefix — correct per FlatBuffer string format)
    # 16
    name_offset_pos = @field_table_offset + 4
    # 32
    name_target = @field_string_offset
    # 16
    name_rel = name_target - name_offset_pos

    # type_rel: stored at field_table_offset+16, references the TYPE TABLE
    # which is type_blob_start + type_vtable_size
    # 32 + str_size
    type_blob_start = @field_string_offset + str_size
    # type's table pos
    type_table_in_blob = type_blob_start + type_vtable_size
    # 28
    type_offset_pos = @field_table_offset + 16
    type_rel = type_table_in_blob - type_offset_pos

    # 12
    soffset = @field_table_offset

    # field vtable: vtable_size=12, obj_size=20, s0=4, s1=0(absent), s2=12, s3=16
    vtable = <<
      @field_vtable_size::little-16,
      @field_obj_size::little-16,
      4::little-16,
      0::little-16,
      12::little-16,
      16::little-16
    >>

    # field inline (20 bytes)
    inline = <<
      soffset::little-signed-32,
      name_rel::little-unsigned-32,
      0::8,
      0::8,
      0::8,
      0::8,
      type_type::8,
      0::8,
      0::8,
      0::8,
      type_rel::little-unsigned-32
    >>

    vtable <> inline <> str_blob <> type_blob
  end

  # Build a bare Arrow IPC Schema FlatBuffer (without the IPC continuation prefix).
  # columns = [{name, type_type, opts}]
  defp build_schema_fb(columns) do
    num_cols = length(columns)

    # Build all field blobs and record their sizes
    field_blobs =
      Enum.map(columns, fn {name, type_type, opts} ->
        build_field_blob(name, type_type, opts)
      end)

    fields_vec_size = 4 + num_cols * 4
    fields_data_start = @fields_vec_base + fields_vec_size

    # Absolute blob-start position for each field in the full buffer
    {field_blob_abs_starts, _final_pos} =
      Enum.map_reduce(field_blobs, fields_data_start, fn blob, pos ->
        {pos, pos + byte_size(blob)}
      end)

    # Build root offset
    # 14
    root_offset = @msg_table_pos

    # vtable_msg: 5 × u16 = 10 bytes
    # vtable_size=10, obj_size=12, s0=0(absent), s1=4(header_type), s2=8(header)
    vtable_msg = <<
      @msg_vtable_size::little-16,
      @msg_inline_size::little-16,
      0::little-16,
      4::little-16,
      8::little-16
    >>

    # 10
    msg_soffset = @msg_table_pos - @msg_vtable_pos
    # schema_rel: offset_pos = msg_table_pos + 8 = 22, target = schema_table_pos = 34
    # 12
    schema_rel = @schema_table_pos - (@msg_table_pos + 8)

    msg_inline = <<
      msg_soffset::little-signed-32,
      1::8,
      0::8,
      0::8,
      0::8,
      schema_rel::little-unsigned-32
    >>

    # vtable_schema: 4 × u16 = 8 bytes
    # vtable_size=8, obj_size=8, s0=0(absent), s1=4(fields)
    vtable_schema = <<
      @schema_vtable_size::little-16,
      @schema_inline_size::little-16,
      0::little-16,
      4::little-16
    >>

    # 8
    schema_soffset = @schema_table_pos - @schema_vtable_pos
    # fields_rel: offset_pos = schema_table_pos + 4 = 38, target = fields_vec_base = 42
    # 4
    fields_rel = @fields_vec_base - (@schema_table_pos + 4)
    schema_inline = <<schema_soffset::little-signed-32, fields_rel::little-unsigned-32>>

    # fields vector elements
    field_vec_elements =
      Enum.with_index(field_blob_abs_starts)
      |> Enum.reduce(<<num_cols::little-32>>, fn {blob_abs_start, i}, acc ->
        # Field TABLE is at blob_abs_start + @field_vtable_size
        field_table_abs = blob_abs_start + @field_vtable_size
        # Element position in buffer: fields_vec_base + 4 + i*4
        elem_pos = @fields_vec_base + 4 + i * 4
        field_rel = field_table_abs - elem_pos
        acc <> <<field_rel::little-unsigned-32>>
      end)

    all_blobs = IO.iodata_to_binary(field_blobs)

    <<root_offset::little-32>> <>
      vtable_msg <>
      msg_inline <>
      vtable_schema <>
      schema_inline <>
      field_vec_elements <>
      all_blobs
  end

  # Build an IPC-wrapped Schema message header.
  defp schema_msg(columns) do
    fb = build_schema_fb(columns)
    fb_size = byte_size(fb)
    <<0xFF, 0xFF, 0xFF, 0xFF, fb_size::little-32, fb::binary>>
  end

  # ---------------------------------------------------------------------------
  # RecordBatch IPC message builder
  #
  # Layout (bare FlatBuffer, base=0):
  #   [0..3]   root_offset → msg_table_pos
  #   [4..13]  vtable_msg (5 × u16 = 10 bytes)
  #   [14..25] msg_inline (12 bytes): soffset + header_type + 3pad + rb_rel
  #   [26..37] vtable_rb (6 × u16 = 12 bytes): vtable_size=12, obj_size=20,
  #            s0=4(length), s1=0(nodes absent), s2=12(buffers)
  #   [38..57] rb_inline (20 bytes): soffset + row_count(8) + buf_rel(4) + pad(4)
  #   [58..]   buffers_vector: count(4) + N×16 bytes (buf structs inline)
  # ---------------------------------------------------------------------------

  # RecordBatch FlatBuffer layout constants
  # vtable_rb has 5 entries: vtable_size, obj_size, s0, s1, s2 = 5 × 2 = 10 bytes
  # rb_inline has: soffset(4) + row_count(8) + buf_rel(4) = 16 bytes
  # 4
  @rb_msg_vtable_pos @root_size
  @rb_msg_vtable_size 10
  @rb_msg_inline_size 12
  # 14
  @rb_msg_table_pos @rb_msg_vtable_pos + @rb_msg_vtable_size
  # 26
  @rb_vtable_pos @rb_msg_table_pos + @rb_msg_inline_size
  @rb_vtable_size 10
  # 36
  @rb_table_pos @rb_vtable_pos + @rb_vtable_size
  @rb_inline_size 16
  # 52
  @rb_bufvec_pos @rb_table_pos + @rb_inline_size

  defp build_record_batch_fb(row_count, buffer_specs) do
    buf_count = length(buffer_specs)

    # vtable_msg: s0=0(absent), s1=4(header_type), s2=8(header)
    vtable_msg = <<
      @rb_msg_vtable_size::little-16,
      @rb_msg_inline_size::little-16,
      0::little-16,
      4::little-16,
      8::little-16
    >>

    # 10
    msg_soffset = @rb_msg_table_pos - @rb_msg_vtable_pos
    # rb_rel: offset_pos = rb_msg_table_pos + 8 = 22, target = rb_table_pos = 36
    # 14
    rb_rel = @rb_table_pos - (@rb_msg_table_pos + 8)

    msg_inline = <<
      msg_soffset::little-signed-32,
      3::8,
      0::8,
      0::8,
      0::8,
      rb_rel::little-unsigned-32
    >>

    # vtable_rb: 5 × u16 = 10 bytes
    # vtable_size=10, obj_size=16, s0=4(length int64), s1=0(nodes absent), s2=12(buffers)
    # Row count (int64) is at rb_table_pos+4 (slot0).
    # Buffers uoffset32 is at rb_table_pos+12 (slot2).
    # obj_size = soffset(4) + length(8) + buf_rel(4) = 16
    vtable_rb = <<
      @rb_vtable_size::little-16,
      @rb_inline_size::little-16,
      4::little-16,
      0::little-16,
      12::little-16
    >>

    # 10
    rb_soffset = @rb_table_pos - @rb_vtable_pos
    # buf_rel: offset_pos = rb_table_pos + 12 = 48, target = rb_bufvec_pos = 52
    # 4
    buf_rel = @rb_bufvec_pos - (@rb_table_pos + 12)
    # rb_inline: soffset(4) + row_count(8) + buf_rel(4) = 16 bytes
    rb_inline = <<
      rb_soffset::little-signed-32,
      row_count::little-signed-64,
      buf_rel::little-unsigned-32
    >>

    # Buffer structs are 16-byte flat structs: offset::int64 + length::int64
    buffer_structs =
      Enum.reduce(buffer_specs, <<>>, fn {off, len}, acc ->
        acc <> <<off::little-signed-64, len::little-signed-64>>
      end)

    buffers_vector = <<buf_count::little-32>> <> buffer_structs

    # 14
    root_offset = @rb_msg_table_pos

    <<root_offset::little-32>> <>
      vtable_msg <>
      msg_inline <>
      vtable_rb <>
      rb_inline <>
      buffers_vector
  end

  # Build an IPC-wrapped RecordBatch message header.
  defp batch_msg(row_count, buffer_specs) do
    fb = build_record_batch_fb(row_count, buffer_specs)
    fb_size = byte_size(fb)
    <<0xFF, 0xFF, 0xFF, 0xFF, fb_size::little-32, fb::binary>>
  end

  # ---------------------------------------------------------------------------
  # FlightData helpers
  # ---------------------------------------------------------------------------

  defp schema_fd(columns) do
    %FlightData{data_header: schema_msg(columns), data_body: <<>>}
  end

  defp batch_fd(body, buffer_specs, row_count) do
    %FlightData{data_header: batch_msg(row_count, buffer_specs), data_body: body}
  end

  # ---------------------------------------------------------------------------
  # Column data helpers — produce {body_binary, buffer_specs} pairs
  # ---------------------------------------------------------------------------

  defp int64_column(values) do
    data = Enum.reduce(values, <<>>, fn v, acc -> acc <> <<v::little-signed-64>> end)
    {data, [{0, 0}, {0, byte_size(data)}]}
  end

  defp float64_column(values) do
    data = Enum.reduce(values, <<>>, fn v, acc -> acc <> <<v::little-float-64>> end)
    {data, [{0, 0}, {0, byte_size(data)}]}
  end

  defp bool_column(values) do
    n = length(values)
    chunks = Enum.chunk_every(values, 8, 8, List.duplicate(false, 7))

    data =
      Enum.reduce(chunks, <<>>, fn chunk, acc ->
        byte =
          chunk
          |> Enum.with_index()
          |> Enum.reduce(0, fn {v, i}, b -> if v, do: b ||| 1 <<< i, else: b end)

        acc <> <<byte::8>>
      end)

    bitmap_bytes = div(n + 7, 8)
    {data, [{0, 0}, {0, bitmap_bytes}]}
  end

  defp utf8_column(values) do
    {cumulative, total} =
      Enum.map_reduce(values, 0, fn v, cur -> {cur, cur + byte_size(v)} end)

    all_offsets = cumulative ++ [total]

    offsets_bin =
      Enum.reduce(all_offsets, <<>>, fn o, acc -> acc <> <<o::little-signed-32>> end)

    char_data = IO.iodata_to_binary(values)
    body = offsets_bin <> char_data

    buf_specs = [
      {0, 0},
      {0, byte_size(offsets_bin)},
      {byte_size(offsets_bin), total}
    ]

    {body, buf_specs}
  end

  defp int32_column(values) do
    data = Enum.reduce(values, <<>>, fn v, acc -> acc <> <<v::little-signed-32>> end)
    {data, [{0, 0}, {0, byte_size(data)}]}
  end

  defp int16_column(values) do
    data = Enum.reduce(values, <<>>, fn v, acc -> acc <> <<v::little-signed-16>> end)
    {data, [{0, 0}, {0, byte_size(data)}]}
  end

  defp int8_column(values) do
    data = Enum.reduce(values, <<>>, fn v, acc -> acc <> <<v::little-signed-8>> end)
    {data, [{0, 0}, {0, byte_size(data)}]}
  end

  defp uint64_column(values) do
    data = Enum.reduce(values, <<>>, fn v, acc -> acc <> <<v::little-unsigned-64>> end)
    {data, [{0, 0}, {0, byte_size(data)}]}
  end

  defp uint32_column(values) do
    data = Enum.reduce(values, <<>>, fn v, acc -> acc <> <<v::little-unsigned-32>> end)
    {data, [{0, 0}, {0, byte_size(data)}]}
  end

  defp uint16_column(values) do
    data = Enum.reduce(values, <<>>, fn v, acc -> acc <> <<v::little-unsigned-16>> end)
    {data, [{0, 0}, {0, byte_size(data)}]}
  end

  defp uint8_column(values) do
    data = Enum.reduce(values, <<>>, fn v, acc -> acc <> <<v::little-unsigned-8>> end)
    {data, [{0, 0}, {0, byte_size(data)}]}
  end

  defp float32_column(values) do
    data = Enum.reduce(values, <<>>, fn v, acc -> acc <> <<v::little-float-32>> end)
    {data, [{0, 0}, {0, byte_size(data)}]}
  end

  # Build a column with a validity bitmap marking some values as null.
  # null_indices is a MapSet of 0-based indices that should be null.
  defp with_validity_bitmap({data, [{_voff, _vlen} | data_specs]}, n, null_indices) do
    bitmap_bytes = div(n + 7, 8)

    bitmap =
      for byte_idx <- 0..(bitmap_bytes - 1), into: <<>> do
        byte =
          Enum.reduce(0..7, 0, fn bit_idx, acc ->
            row = byte_idx * 8 + bit_idx

            if row < n and not MapSet.member?(null_indices, row) do
              acc ||| 1 <<< bit_idx
            else
              acc
            end
          end)

        <<byte::8>>
      end

    # Validity bitmap comes before data; shift data offsets accordingly
    shifted_specs =
      Enum.map(data_specs, fn {off, len} -> {off + bitmap_bytes, len} end)

    body = bitmap <> data
    {body, [{0, bitmap_bytes} | shifted_specs]}
  end

  # Shift all buffer offsets by delta bytes (pack multiple columns into one body).
  defp shift_specs(specs, delta) do
    Enum.map(specs, fn {off, len} -> {off + delta, len} end)
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — empty input
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — empty input" do
    test "returns {:ok, []} for empty list" do
      assert {:ok, []} = Reader.decode_flight_data([])
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — nil and degenerate inputs
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — nil and degenerate inputs" do
    test "returns {:ok, []} for nil" do
      assert {:ok, []} = Reader.parse_schema(nil)
    end

    test "returns {:ok, []} for empty binary" do
      assert {:ok, []} = Reader.parse_schema(<<>>)
    end

    test "returns {:ok, []} for too-short binary (< 8 bytes)" do
      assert {:ok, []} = Reader.parse_schema(<<0, 1, 2>>)
    end

    test "schema-only stream with no batches returns no rows" do
      fd = schema_fd([{"value", 2, [bit_width: 64, is_signed: true]}])
      assert {:ok, []} = Reader.decode_flight_data([fd])
    end

    test "FlightData with nil data_header returns {:ok, []}" do
      fd = %FlightData{data_header: nil, data_body: <<>>}
      assert {:ok, []} = Reader.decode_flight_data([fd])
    end

    test "FlightData with empty data_header returns {:ok, []}" do
      fd = %FlightData{data_header: <<>>, data_body: <<>>}
      assert {:ok, []} = Reader.decode_flight_data([fd])
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — signed Int columns
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — signed Int columns" do
    test "extracts column name from Int64 schema" do
      header = schema_msg([{"value", 2, [bit_width: 64, is_signed: true]}])
      {:ok, cols} = Reader.parse_schema(header)
      assert length(cols) == 1
      assert hd(cols).name == "value"
    end

    test "maps Int64 (bitWidth=64, signed) to type_id 6" do
      header = schema_msg([{"value", 2, [bit_width: 64, is_signed: true]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 6
    end

    test "maps Int32 (bitWidth=32, signed) to type_id 4" do
      header = schema_msg([{"count", 2, [bit_width: 32, is_signed: true]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 4
    end

    test "maps Int16 (bitWidth=16, signed) to type_id 3" do
      header = schema_msg([{"small", 2, [bit_width: 16, is_signed: true]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 3
    end

    test "maps Int8 (bitWidth=8, signed) to type_id 2" do
      header = schema_msg([{"tiny", 2, [bit_width: 8, is_signed: true]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — unsigned Int columns
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — unsigned Int columns" do
    test "maps UInt64 (bitWidth=64, unsigned) to type_id 10" do
      header = schema_msg([{"u64", 2, [bit_width: 64, is_signed: false]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 10
    end

    test "maps UInt32 (bitWidth=32, unsigned) to type_id 9" do
      header = schema_msg([{"u32", 2, [bit_width: 32, is_signed: false]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 9
    end

    test "maps UInt16 (bitWidth=16, unsigned) to type_id 8" do
      header = schema_msg([{"u16", 2, [bit_width: 16, is_signed: false]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 8
    end

    test "maps UInt8 (bitWidth=8, unsigned) to type_id 7" do
      header = schema_msg([{"u8", 2, [bit_width: 8, is_signed: false]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 7
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — FloatingPoint columns
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — FloatingPoint columns" do
    test "maps Float64 (precision=2) to type_id 12" do
      header = schema_msg([{"temp", 3, [precision: 2]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 12
    end

    test "maps Float32 (precision=1) to type_id 11" do
      header = schema_msg([{"reading", 3, [precision: 1]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 11
    end

    test "defaults to Float64 when precision not specified" do
      header = schema_msg([{"f", 3, []}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 12
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — Bool, Utf8, Timestamp
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — Bool, Utf8, Timestamp columns" do
    test "maps Bool (type_type=6) to type_id 14" do
      header = schema_msg([{"active", 6, []}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 14
    end

    test "maps Utf8 (type_type=5) to type_id 15" do
      header = schema_msg([{"host", 5, []}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 15
    end

    test "maps Timestamp (type_type=10) to type_id 20" do
      header = schema_msg([{"time", 10, []}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert col.type_id == 20
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — multiple columns
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — multiple columns" do
    test "extracts two columns with correct names" do
      header =
        schema_msg([
          {"time", 10, []},
          {"value", 2, [bit_width: 64, is_signed: true]}
        ])

      {:ok, cols} = Reader.parse_schema(header)
      assert length(cols) == 2
      names = Enum.map(cols, & &1.name)
      assert "time" in names
      assert "value" in names
    end

    test "preserves column order across three columns" do
      header =
        schema_msg([
          {"time", 10, []},
          {"host", 5, []},
          {"cpu", 2, [bit_width: 64, is_signed: true]}
        ])

      {:ok, cols} = Reader.parse_schema(header)
      assert length(cols) == 3
      assert Enum.at(cols, 0).name == "time"
      assert Enum.at(cols, 1).name == "host"
      assert Enum.at(cols, 2).name == "cpu"
    end

    test "assigns correct type_ids to a mixed-type schema" do
      header =
        schema_msg([
          {"ts", 10, []},
          {"tag", 5, []},
          {"val", 3, [precision: 2]},
          {"flag", 6, []}
        ])

      {:ok, cols} = Reader.parse_schema(header)
      assert length(cols) == 4
      # Timestamp=20, Utf8=15, Float64=12, Bool=14
      assert Enum.map(cols, & &1.type_id) == [20, 15, 12, 14]
    end

    test "each column map has name and type_id keys" do
      header = schema_msg([{"x", 2, [bit_width: 64, is_signed: true]}])
      {:ok, [col]} = Reader.parse_schema(header)
      assert Map.has_key?(col, :name)
      assert Map.has_key?(col, :type_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — Int64 column round-trip
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — Int64 columns" do
    test "decodes three Int64 values" do
      schema = schema_fd([{"value", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([10, 20, 30])
      batch = batch_fd(body, specs, 3)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert length(rows) == 3
      assert Enum.at(rows, 0)["value"] == 10
      assert Enum.at(rows, 1)["value"] == 20
      assert Enum.at(rows, 2)["value"] == 30
    end

    test "decodes negative Int64 values" do
      schema = schema_fd([{"delta", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([-1, -100, 0])
      batch = batch_fd(body, specs, 3)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.at(rows, 0)["delta"] == -1
      assert Enum.at(rows, 1)["delta"] == -100
      assert Enum.at(rows, 2)["delta"] == 0
    end

    test "decodes a single-row Int64 batch" do
      schema = schema_fd([{"n", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([42])
      batch = batch_fd(body, specs, 1)

      assert {:ok, [row]} = Reader.decode_flight_data([schema, batch])
      assert row["n"] == 42
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — Float64 column round-trip
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — Float64 columns" do
    test "decodes three Float64 values" do
      schema = schema_fd([{"temp", 3, [precision: 2]}])
      {body, specs} = float64_column([1.5, 2.5, 3.14])
      batch = batch_fd(body, specs, 3)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert length(rows) == 3
      assert_in_delta Enum.at(rows, 0)["temp"], 1.5, 1.0e-9
      assert_in_delta Enum.at(rows, 1)["temp"], 2.5, 1.0e-9
      assert_in_delta Enum.at(rows, 2)["temp"], 3.14, 1.0e-9
    end

    test "decodes a negative float value" do
      schema = schema_fd([{"x", 3, [precision: 2]}])
      {body, specs} = float64_column([-0.5])
      batch = batch_fd(body, specs, 1)

      assert {:ok, [row]} = Reader.decode_flight_data([schema, batch])
      assert_in_delta row["x"], -0.5, 1.0e-9
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — Bool column round-trip
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — Bool columns" do
    test "decodes three Bool values" do
      schema = schema_fd([{"flag", 6, []}])
      {body, specs} = bool_column([true, false, true])
      batch = batch_fd(body, specs, 3)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert length(rows) == 3
      assert Enum.at(rows, 0)["flag"] == true
      assert Enum.at(rows, 1)["flag"] == false
      assert Enum.at(rows, 2)["flag"] == true
    end

    test "decodes all-false bool column" do
      schema = schema_fd([{"active", 6, []}])
      {body, specs} = bool_column([false, false])
      batch = batch_fd(body, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.all?(rows, fn r -> r["active"] == false end)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — Utf8 column round-trip
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — Utf8 columns" do
    test "decodes two Utf8 strings" do
      schema = schema_fd([{"host", 5, []}])
      {body, specs} = utf8_column(["server01", "server02"])
      batch = batch_fd(body, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert length(rows) == 2
      assert Enum.at(rows, 0)["host"] == "server01"
      assert Enum.at(rows, 1)["host"] == "server02"
    end

    test "decodes empty strings alongside non-empty strings" do
      schema = schema_fd([{"tag", 5, []}])
      {body, specs} = utf8_column(["", "val"])
      batch = batch_fd(body, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.at(rows, 0)["tag"] == ""
      assert Enum.at(rows, 1)["tag"] == "val"
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — Timestamp column round-trip
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — Timestamp columns" do
    test "decodes nanosecond timestamp values" do
      ts1 = 1_630_424_257_000_000_000
      ts2 = 1_630_424_258_000_000_000
      schema = schema_fd([{"time", 10, []}])
      {body, specs} = int64_column([ts1, ts2])
      batch = batch_fd(body, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.at(rows, 0)["time"] == ts1
      assert Enum.at(rows, 1)["time"] == ts2
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — multiple columns
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — multiple columns" do
    test "decodes a two-column (Int64 + Float64) batch" do
      schema =
        schema_fd([
          {"count", 2, [bit_width: 64, is_signed: true]},
          {"value", 3, [precision: 2]}
        ])

      {int_data, int_specs} = int64_column([1, 2])
      {float_data, float_specs_raw} = float64_column([0.1, 0.2])

      float_specs = shift_specs(float_specs_raw, byte_size(int_data))
      body = int_data <> float_data
      all_specs = int_specs ++ float_specs
      batch = batch_fd(body, all_specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert length(rows) == 2
      assert Enum.at(rows, 0)["count"] == 1
      assert Enum.at(rows, 1)["count"] == 2
      assert_in_delta Enum.at(rows, 0)["value"], 0.1, 1.0e-9
      assert_in_delta Enum.at(rows, 1)["value"], 0.2, 1.0e-9
    end

    test "each row map contains all declared column keys" do
      schema = schema_fd([{"ts", 10, []}, {"flag", 6, []}])
      {ts_data, ts_specs} = int64_column([100])
      {bool_data, bool_specs_raw} = bool_column([true])

      bool_specs = shift_specs(bool_specs_raw, byte_size(ts_data))
      body = ts_data <> bool_data
      all_specs = ts_specs ++ bool_specs
      batch = batch_fd(body, all_specs, 1)

      assert {:ok, [row]} = Reader.decode_flight_data([schema, batch])
      assert Map.has_key?(row, "ts")
      assert Map.has_key?(row, "flag")
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — multiple batches
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — multiple batches" do
    test "concatenates rows from two Int64 batches" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      {body1, specs1} = int64_column([1, 2])
      {body2, specs2} = int64_column([3, 4])
      batch1 = batch_fd(body1, specs1, 2)
      batch2 = batch_fd(body2, specs2, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch1, batch2])
      assert length(rows) == 4
      assert Enum.map(rows, fn r -> r["v"] end) == [1, 2, 3, 4]
    end

    test "accumulates five single-row batches" do
      schema = schema_fd([{"n", 2, [bit_width: 64, is_signed: true]}])

      batches =
        Enum.map(1..5, fn i ->
          {body, specs} = int64_column([i])
          batch_fd(body, specs, 1)
        end)

      assert {:ok, rows} = Reader.decode_flight_data([schema | batches])
      assert length(rows) == 5
      assert Enum.map(rows, fn r -> r["n"] end) == [1, 2, 3, 4, 5]
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — empty batch handling
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — empty batch handling" do
    test "handles batch with nil data_header" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      batch = %FlightData{data_header: nil, data_body: <<>>}
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert rows == []
    end

    test "handles batch with empty data_header" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      batch = %FlightData{data_header: <<>>, data_body: <<>>}
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert rows == []
    end

    test "handles batch with nil data_body" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      batch = %FlightData{data_header: batch_msg(0, [{0, 0}, {0, 0}]), data_body: nil}
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert rows == []
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — smaller integer types
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — Int32 columns" do
    test "decodes Int32 values" do
      schema = schema_fd([{"count", 2, [bit_width: 32, is_signed: true]}])
      {body, specs} = int32_column([100, -200, 0])
      batch = batch_fd(body, specs, 3)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.map(rows, & &1["count"]) == [100, -200, 0]
    end
  end

  describe "decode_flight_data/1 — Int16 columns" do
    test "decodes Int16 values" do
      schema = schema_fd([{"small", 2, [bit_width: 16, is_signed: true]}])
      {body, specs} = int16_column([1, -1, 32_767])
      batch = batch_fd(body, specs, 3)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.map(rows, & &1["small"]) == [1, -1, 32_767]
    end
  end

  describe "decode_flight_data/1 — Int8 columns" do
    test "decodes Int8 values" do
      schema = schema_fd([{"tiny", 2, [bit_width: 8, is_signed: true]}])
      {body, specs} = int8_column([1, -1, 127])
      batch = batch_fd(body, specs, 3)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.map(rows, & &1["tiny"]) == [1, -1, 127]
    end
  end

  describe "decode_flight_data/1 — UInt64 columns" do
    test "decodes UInt64 values" do
      schema = schema_fd([{"big", 2, [bit_width: 64, is_signed: false]}])
      {body, specs} = uint64_column([0, 18_446_744_073_709_551_615])
      batch = batch_fd(body, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.at(rows, 0)["big"] == 0
      assert Enum.at(rows, 1)["big"] == 18_446_744_073_709_551_615
    end
  end

  describe "decode_flight_data/1 — UInt32 columns" do
    test "decodes UInt32 values" do
      schema = schema_fd([{"u", 2, [bit_width: 32, is_signed: false]}])
      {body, specs} = uint32_column([0, 4_294_967_295])
      batch = batch_fd(body, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.map(rows, & &1["u"]) == [0, 4_294_967_295]
    end
  end

  describe "decode_flight_data/1 — UInt16 columns" do
    test "decodes UInt16 values" do
      schema = schema_fd([{"u16", 2, [bit_width: 16, is_signed: false]}])
      {body, specs} = uint16_column([0, 65_535])
      batch = batch_fd(body, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.map(rows, & &1["u16"]) == [0, 65_535]
    end
  end

  describe "decode_flight_data/1 — UInt8 columns" do
    test "decodes UInt8 values" do
      schema = schema_fd([{"byte", 2, [bit_width: 8, is_signed: false]}])
      {body, specs} = uint8_column([0, 255])
      batch = batch_fd(body, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.map(rows, & &1["byte"]) == [0, 255]
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — Float32 column round-trip
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — Float32 columns" do
    test "decodes Float32 values" do
      schema = schema_fd([{"reading", 3, [precision: 1]}])
      {body, specs} = float32_column([1.0, -2.5])
      batch = batch_fd(body, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert length(rows) == 2
      assert_in_delta Enum.at(rows, 0)["reading"], 1.0, 1.0e-5
      assert_in_delta Enum.at(rows, 1)["reading"], -2.5, 1.0e-5
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — null/validity bitmap
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — validity bitmap (nulls)" do
    test "marks null Int64 values based on validity bitmap" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      # Three values, but index 1 is null
      {body, specs} = int64_column([10, 99, 30])
      {body, specs} = with_validity_bitmap({body, specs}, 3, MapSet.new([1]))
      batch = batch_fd(body, specs, 3)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.at(rows, 0)["v"] == 10
      assert Enum.at(rows, 1)["v"] == nil
      assert Enum.at(rows, 2)["v"] == 30
    end

    test "marks null Float64 values based on validity bitmap" do
      schema = schema_fd([{"f", 3, [precision: 2]}])
      {body, specs} = float64_column([1.0, 2.0, 3.0])
      {body, specs} = with_validity_bitmap({body, specs}, 3, MapSet.new([0, 2]))
      batch = batch_fd(body, specs, 3)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.at(rows, 0)["f"] == nil
      assert_in_delta Enum.at(rows, 1)["f"], 2.0, 1.0e-9
      assert Enum.at(rows, 2)["f"] == nil
    end

    test "all-null column via validity bitmap" do
      schema = schema_fd([{"n", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([0, 0])
      {body, specs} = with_validity_bitmap({body, specs}, 2, MapSet.new([0, 1]))
      batch = batch_fd(body, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert Enum.all?(rows, fn r -> r["n"] == nil end)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — error/edge cases
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — error handling" do
    test "returns {:error, :schema_parse_failed} for corrupt binary" do
      # Binary long enough to attempt parsing but with invalid structure
      corrupt = <<0xFF, 0xFF, 0xFF, 0xFF, 20::little-32>> <> :binary.copy(<<0xFF>>, 20)
      assert {:error, :schema_parse_failed} = Reader.parse_schema(corrupt)
    end

    test "schema without continuation marker still parses" do
      # A bare FlatBuffer < 8 bytes returns empty
      assert {:ok, []} = Reader.parse_schema(<<0, 0, 0, 0>>)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — unknown type fallback
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — unknown type columns" do
    test "unknown type_type produces nil values" do
      # type_type 99 is not recognized — should produce type_id 0
      schema = schema_fd([{"mystery", 99, []}])
      # Provide some dummy data; unknown type decodes to nils
      dummy_data = :binary.copy(<<0>>, 16)
      specs = [{0, 0}, {0, 16}]
      batch = batch_fd(dummy_data, specs, 2)

      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert length(rows) == 2
      assert Enum.all?(rows, fn r -> r["mystery"] == nil end)
    end
  end
end
