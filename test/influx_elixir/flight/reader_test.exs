defmodule InfluxElixir.Flight.ReaderTest do
  use ExUnit.Case, async: true

  doctest InfluxElixir.Flight.Reader

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
    is_signed_byte = if Keyword.get(opts, :is_signed, true) === true, do: 1, else: 0
    # vtable: 4 × u16 = 8 bytes, vtable_size=8, obj_size=10, s0=4, s1=8; an offset of 0 is a
    # slot left out of the table, which is how a FlatBuffer writes a field holding its default
    # (`is_signed: :omit` is `false`, the Arrow default).
    is_signed_slot = if Keyword.get(opts, :is_signed, true) === :omit, do: 0, else: 8
    vtable = <<8::little-16, 10::little-16, 4::little-16, is_signed_slot::little-16>>
    soffset = byte_size(vtable)
    inline = <<soffset::little-signed-32, bit_width::little-signed-32, is_signed_byte::8, 0::8>>
    {vtable <> inline, @int_vtable_size}
  end

  defp build_type_blob(3, opts) do
    precision = Keyword.get(opts, :precision, 2)
    # vtable: 3 × u16 = 6 bytes, vtable_size=6, obj_size=8, s0=4 (0 when the precision is
    # `:omit`: HALF, the Arrow default, which a FlatBuffer leaves out)
    precision_slot = if precision === :omit, do: 0, else: 4
    precision = if precision === :omit, do: 0, else: precision
    vtable = <<6::little-16, 8::little-16, precision_slot::little-16>>
    soffset = byte_size(vtable)
    inline = <<soffset::little-signed-32, precision::little-signed-16, 0::16>>
    {vtable <> inline, @fp_vtable_size}
  end

  defp build_type_blob(10, opts) do
    # Timestamp table: slot 0 = unit (int16 TimeUnit: 0=s, 1=ms, 2=us, 3=ns);
    # slot 1 (timezone) absent. Same shape as FloatingPoint.
    unit = Keyword.get(opts, :unit, 3)
    vtable = <<6::little-16, 8::little-16, 4::little-16>>
    soffset = byte_size(vtable)
    inline = <<soffset::little-signed-32, unit::little-signed-16, 0::16>>
    {vtable <> inline, @fp_vtable_size}
  end

  defp build_type_blob(_type_type, _opts) do
    # Bool, Utf8, other: empty table
    # vtable: 2 × u16 = 4 bytes, vtable_size=4, obj_size=4
    vtable = <<4::little-16, 4::little-16>>
    soffset = byte_size(vtable)
    inline = <<soffset::little-signed-32>>
    {vtable <> inline, @empty_vtable_size}
  end

  # Pad a binary to 4-byte alignment with null bytes.
  defp pad4(bin) do
    r = rem(byte_size(bin), 4)
    if r === 0, do: bin, else: bin <> :binary.copy(<<0>>, 4 - r)
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

  # Same as with_validity_bitmap/3 but inserts alignment padding between the
  # validity bitmap and the data buffer, matching how real Arrow IPC producers
  # lay out record batch bodies (Arrow mandates 8-byte minimum, 64-byte
  # recommended buffer alignment). The `alignment` argument specifies the
  # boundary to which the data buffer is aligned relative to the start of the
  # body.
  defp with_padded_validity_bitmap(
         {data, [{_voff, _vlen} | data_specs]},
         n,
         null_indices,
         alignment
       ) do
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

    rem_bytes = rem(bitmap_bytes, alignment)
    pad = if rem_bytes === 0, do: 0, else: alignment - rem_bytes
    prefix = bitmap <> :binary.copy(<<0>>, pad)
    prefix_size = byte_size(prefix)

    shifted_specs =
      Enum.map(data_specs, fn {off, len} -> {off + prefix_size, len} end)

    body = prefix <> data
    {body, [{0, bitmap_bytes} | shifted_specs]}
  end

  # Shift all buffer offsets by delta bytes (pack multiple columns into one body).
  defp shift_specs(specs, delta) do
    Enum.map(specs, fn {off, len} -> {off + delta, len} end)
  end

  # The schema entry of a column the reader decodes by type id.
  defp primitive(name, type_id, unit \\ nil) do
    %{name: name, type_id: type_id, unit: unit, kind: :primitive, children: []}
  end

  # The schema entry of a column of a type the reader does not decode.
  defp undecoded(name, type) do
    %{name: name, type_id: 0, unit: nil, kind: {:unsupported, type}, children: []}
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — empty input
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — empty input" do
    test "an empty list of messages decodes to no rows" do
      assert Reader.decode_flight_data([]) === {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: nil and degenerate inputs
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 and decode_flight_data/1 — nil and degenerate inputs" do
    test "a nil header has no columns" do
      assert Reader.parse_schema(nil) === {:ok, []}
    end

    test "an empty header has no columns" do
      assert Reader.parse_schema(<<>>) === {:ok, []}
    end

    test "a header shorter than 8 bytes has no columns" do
      for short <- [<<0, 1, 2>>, <<0, 0, 0, 0>>] do
        assert Reader.parse_schema(short) === {:ok, []}
      end
    end

    test "schema-only stream with no batches returns no rows" do
      fd = schema_fd([{"value", 2, [bit_width: 64, is_signed: true]}])
      assert Reader.decode_flight_data([fd]) === {:ok, []}
    end

    test "FlightData with nil data_header returns no rows" do
      fd = %FlightData{data_header: nil, data_body: <<>>}
      assert Reader.decode_flight_data([fd]) === {:ok, []}
    end

    test "FlightData with empty data_header returns no rows" do
      fd = %FlightData{data_header: <<>>, data_body: <<>>}
      assert Reader.decode_flight_data([fd]) === {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — signed Int columns
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — signed Int columns" do
    test "describes an Int64 column by name, type id, unit, kind and children" do
      header = schema_msg([{"value", 2, [bit_width: 64, is_signed: true]}])
      assert Reader.parse_schema(header) === {:ok, [primitive("value", 6)]}
    end

    test "maps Int32 (bitWidth=32, signed) to type_id 4" do
      header = schema_msg([{"count", 2, [bit_width: 32, is_signed: true]}])
      assert Reader.parse_schema(header) === {:ok, [primitive("count", 4)]}
    end

    test "maps Int16 (bitWidth=16, signed) to type_id 3" do
      header = schema_msg([{"small", 2, [bit_width: 16, is_signed: true]}])
      assert Reader.parse_schema(header) === {:ok, [primitive("small", 3)]}
    end

    test "maps Int8 (bitWidth=8, signed) to type_id 2" do
      header = schema_msg([{"tiny", 2, [bit_width: 8, is_signed: true]}])
      assert Reader.parse_schema(header) === {:ok, [primitive("tiny", 2)]}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — unsigned Int columns
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — unsigned Int columns" do
    test "maps UInt64 (bitWidth=64, unsigned) to type_id 10" do
      header = schema_msg([{"u64", 2, [bit_width: 64, is_signed: false]}])
      assert Reader.parse_schema(header) === {:ok, [primitive("u64", 10)]}
    end

    test "maps UInt32 (bitWidth=32, unsigned) to type_id 9" do
      header = schema_msg([{"u32", 2, [bit_width: 32, is_signed: false]}])
      assert Reader.parse_schema(header) === {:ok, [primitive("u32", 9)]}
    end

    test "maps UInt16 (bitWidth=16, unsigned) to type_id 8" do
      header = schema_msg([{"u16", 2, [bit_width: 16, is_signed: false]}])
      assert Reader.parse_schema(header) === {:ok, [primitive("u16", 8)]}
    end

    test "maps UInt8 (bitWidth=8, unsigned) to type_id 7" do
      header = schema_msg([{"u8", 2, [bit_width: 8, is_signed: false]}])
      assert Reader.parse_schema(header) === {:ok, [primitive("u8", 7)]}
    end

    # FlatBuffers leave a field out when it holds its default, and Arrow's `is_signed` defaults
    # to false: this is how InfluxDB 3 sends a UInt column.
    test "an Int whose is_signed slot is left out is unsigned" do
      for {width, type_id} <- [{8, 7}, {16, 8}, {32, 9}, {64, 10}] do
        header = schema_msg([{"u", 2, [bit_width: width, is_signed: :omit]}])
        assert Reader.parse_schema(header) === {:ok, [primitive("u", type_id)]}
      end
    end

    test "values of a UInt column with the slot left out are not read as signed" do
      body = <<200, 255, 0>>
      schema = schema_fd([{"u", 2, [bit_width: 8, is_signed: :omit]}])
      batch = batch_fd(body, [{0, 0}, {0, 3}], 3)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"u" => 200}, %{"u" => 255}, %{"u" => 0}]}

      body = <<18_446_744_073_709_551_615::little-64>>
      schema = schema_fd([{"u", 2, [bit_width: 64, is_signed: :omit]}])
      batch = batch_fd(body, [{0, 0}, {0, 8}], 1)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"u" => 18_446_744_073_709_551_615}]}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — FloatingPoint columns
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — FloatingPoint columns" do
    test "maps Float64 (precision=2) to type_id 12" do
      header = schema_msg([{"temp", 3, [precision: 2]}])
      assert Reader.parse_schema(header) === {:ok, [primitive("temp", 12)]}
    end

    test "maps Float32 (precision=1) to type_id 11" do
      header = schema_msg([{"reading", 3, [precision: 1]}])
      assert Reader.parse_schema(header) === {:ok, [primitive("reading", 11)]}
    end

    test "precision left out of the table is Float16, the Arrow default" do
      header = schema_msg([{"f", 3, [precision: :omit]}])

      assert Reader.parse_schema(header) ===
               {:ok, [%{name: "f", type_id: 0, unit: nil, kind: :float16, children: []}]}
    end

    test "Float16 cells decode as the shortest Float32 decimal, infinities and NaN as nil" do
      # 1.5, 0.1, -0.0, the smallest subnormal, 65504 (the largest), +inf, -inf, NaN
      body =
        <<0x3E00::little-16, 0x2E66::little-16, 0x8000::little-16, 0x0001::little-16,
          0x7BFF::little-16, 0x7C00::little-16, 0xFC00::little-16, 0x7E00::little-16>>

      schema = schema_fd([{"f", 3, [precision: :omit]}])
      batch = batch_fd(body, [{0, 0}, {0, byte_size(body)}], 8)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok,
                [
                  %{"f" => 1.5},
                  %{"f" => 0.099975586},
                  %{"f" => -0.0},
                  %{"f" => 5.9604645e-8},
                  %{"f" => 65_504.0},
                  %{"f" => nil},
                  %{"f" => nil},
                  %{"f" => nil}
                ]}
    end

    test "Float32 cells decode as HTTP prints them, an infinity as nil" do
      {body, specs} = float32_column([0.1, 3.14159, 1.0e30])
      schema = schema_fd([{"f", 3, [precision: 1]}])
      batch = batch_fd(body, specs, 3)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"f" => 0.1}, %{"f" => 3.14159}, %{"f" => 1.0e30}]}

      body = <<0x7F800000::little-32, 0x3F800000::little-32>>
      batch = batch_fd(body, [{0, 0}, {0, 8}], 2)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"f" => nil}, %{"f" => 1.0}]}
    end

    test "a Float64 infinity is nil and its neighbours keep their rows" do
      body = <<1.5::little-float-64, 0x7FF0000000000000::little-64, 2.5::little-float-64>>
      schema = schema_fd([{"f", 3, [precision: 2]}])
      batch = batch_fd(body, [{0, 0}, {0, 24}], 3)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"f" => 1.5}, %{"f" => nil}, %{"f" => 2.5}]}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — Bool, Utf8, Timestamp
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — Bool, Utf8, Timestamp columns" do
    test "maps Bool (type_type=6) to type_id 14" do
      header = schema_msg([{"active", 6, []}])
      assert Reader.parse_schema(header) === {:ok, [primitive("active", 14)]}
    end

    test "maps Utf8 (type_type=5) to type_id 15" do
      header = schema_msg([{"host", 5, []}])
      assert Reader.parse_schema(header) === {:ok, [primitive("host", 15)]}
    end

    test "maps Timestamp (type_type=10) to type_id 20 with its unit" do
      header = schema_msg([{"time", 10, []}])
      assert Reader.parse_schema(header) === {:ok, [primitive("time", 20, :nanosecond)]}
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

      assert Reader.parse_schema(header) ===
               {:ok, [primitive("time", 20, :nanosecond), primitive("value", 6)]}
    end

    test "preserves column order across three columns" do
      header =
        schema_msg([
          {"time", 10, []},
          {"host", 5, []},
          {"cpu", 2, [bit_width: 64, is_signed: true]}
        ])

      assert Reader.parse_schema(header) ===
               {:ok,
                [primitive("time", 20, :nanosecond), primitive("host", 15), primitive("cpu", 6)]}
    end

    test "assigns correct type_ids to a mixed-type schema" do
      header =
        schema_msg([
          {"ts", 10, []},
          {"tag", 5, []},
          {"val", 3, [precision: 2]},
          {"flag", 6, []}
        ])

      # Timestamp=20, Utf8=15, Float64=12, Bool=14
      assert Reader.parse_schema(header) ===
               {:ok,
                [
                  primitive("ts", 20, :nanosecond),
                  primitive("tag", 15),
                  primitive("val", 12),
                  primitive("flag", 14)
                ]}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — row counts a body cannot hold
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — a row count the body cannot hold" do
    # A corrupt header must not make the reader build a column of a trillion rows.
    test "is an error, not an allocation" do
      schema = schema_fd([{"value", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([10, 20, 30])
      refused = {:error, {:decode_error, "a row count the record batch's body cannot hold"}}

      for count <- [1 <<< 40, 1_048_576, 193, -1] do
        assert decode_bounded([schema, batch_fd(body, specs, count)]) === {:answered, refused}
      end
    end
  end

  describe "decode_flight_data/1 — a batch of null-type columns, which has no body" do
    test "is decoded at the engine's batch size, and refused when its cells pass the bound" do
      nulls = fn count -> schema_fd(for i <- 1..count, do: {"c#{i}", 1, []}) end

      assert decode_bounded([nulls.(3), batch_fd(<<>>, [], 8192)]) ===
               {:answered, {:ok, List.duplicate(%{}, 8192)}}

      assert decode_bounded([nulls.(200), batch_fd(<<>>, [], 8192)]) ===
               {:answered,
                {:error, {:decode_error, "a row count the record batch's body cannot hold"}}}
    end

    test "a null column beside a column with data covers the batch's rows, however wide" do
      int = {"v", 2, [bit_width: 64, is_signed: true]}
      schema = schema_fd([int | for(i <- 1..80, do: {"c#{i}", 1, []})])
      {body, specs} = int64_column(Enum.to_list(1..8192))

      assert decode_bounded([schema, batch_fd(body, specs, 8192)]) ===
               {:answered, {:ok, Enum.map(1..8192, &%{"v" => &1})}}
    end
  end

  # Decodes in a process whose heap is capped at about 40 MB, so a regression that
  # allocates by a corrupt count fails the test instead of taking the machine's memory.
  defp decode_bounded(frames) do
    test = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: 5_000_000, kill: true, error_logger: false})
        send(test, {:decoded, self(), Reader.decode_flight_data(frames)})
      end)

    receive do
      {:decoded, ^pid, answer} -> {:answered, answer}
      {:DOWN, ^ref, :process, ^pid, reason} -> {:died, reason}
    end
  end

  describe "decode_flight_data/1 — Int64 columns" do
    test "decodes three Int64 values" do
      schema = schema_fd([{"value", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([10, 20, 30])
      batch = batch_fd(body, specs, 3)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"value" => 10}, %{"value" => 20}, %{"value" => 30}]}
    end

    test "decodes negative Int64 values" do
      schema = schema_fd([{"delta", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([-1, -100, 0])
      batch = batch_fd(body, specs, 3)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"delta" => -1}, %{"delta" => -100}, %{"delta" => 0}]}
    end

    test "decodes a single-row Int64 batch" do
      schema = schema_fd([{"n", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([42])
      batch = batch_fd(body, specs, 1)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{"n" => 42}]}
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

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"temp" => 1.5}, %{"temp" => 2.5}, %{"temp" => 3.14}]}
    end

    test "decodes a negative float value" do
      schema = schema_fd([{"x", 3, [precision: 2]}])
      {body, specs} = float64_column([-0.5])
      batch = batch_fd(body, specs, 1)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{"x" => -0.5}]}
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

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"flag" => true}, %{"flag" => false}, %{"flag" => true}]}
    end

    test "decodes all-false bool column" do
      schema = schema_fd([{"active", 6, []}])
      {body, specs} = bool_column([false, false])
      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"active" => false}, %{"active" => false}]}
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

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"host" => "server01"}, %{"host" => "server02"}]}
    end

    test "decodes empty strings alongside non-empty strings" do
      schema = schema_fd([{"tag", 5, []}])
      {body, specs} = utf8_column(["", "val"])
      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"tag" => ""}, %{"tag" => "val"}]}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — Timestamp column round-trip
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — Timestamp columns" do
    test "decodes nanosecond timestamps to DateTime (microsecond precision)" do
      ts1 = 1_630_424_257_123_456_789
      ts2 = 1_630_424_258_000_000_000
      schema = schema_fd([{"time", 10, [unit: 3]}])
      {body, specs} = int64_column([ts1, ts2])
      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok,
                [
                  %{"time" => ~U[2021-08-31 15:37:37.123456Z]},
                  %{"time" => ~U[2021-08-31 15:37:38.000000Z]}
                ]}
    end

    test "honours the column's TimeUnit (milliseconds)" do
      schema = schema_fd([{"time", 10, [unit: 1]}])
      {body, specs} = int64_column([1_630_424_257_500])
      batch = batch_fd(body, specs, 1)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"time" => ~U[2021-08-31 15:37:37.500000Z]}]}
    end

    test "parses the unit into the column schema" do
      assert Reader.parse_schema(schema_fd([{"time", 10, [unit: 3]}]).data_header) ===
               {:ok, [primitive("time", 20, :nanosecond)]}

      assert Reader.parse_schema(schema_fd([{"v", 2, [bit_width: 64]}]).data_header) ===
               {:ok, [primitive("v", 6)]}
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

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"count" => 1, "value" => 0.1}, %{"count" => 2, "value" => 0.2}]}
    end

    test "each row carries a key for every declared column" do
      schema = schema_fd([{"ts", 10, []}, {"flag", 6, []}])
      {ts_data, ts_specs} = int64_column([100])
      {bool_data, bool_specs_raw} = bool_column([true])

      bool_specs = shift_specs(bool_specs_raw, byte_size(ts_data))
      body = ts_data <> bool_data
      all_specs = ts_specs ++ bool_specs
      batch = batch_fd(body, all_specs, 1)

      # 100 ns is 0 microseconds past the epoch
      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"ts" => ~U[1970-01-01 00:00:00.000000Z], "flag" => true}]}
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

      assert Reader.decode_flight_data([schema, batch1, batch2]) ===
               {:ok, [%{"v" => 1}, %{"v" => 2}, %{"v" => 3}, %{"v" => 4}]}
    end

    test "accumulates five single-row batches" do
      schema = schema_fd([{"n", 2, [bit_width: 64, is_signed: true]}])

      batches =
        Enum.map(1..5, fn i ->
          {body, specs} = int64_column([i])
          batch_fd(body, specs, 1)
        end)

      assert Reader.decode_flight_data([schema | batches]) ===
               {:ok, Enum.map(1..5, &%{"n" => &1})}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — empty batch handling
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — empty batch handling" do
    test "a batch with a nil data_header decodes no rows" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      batch = %FlightData{data_header: nil, data_body: <<>>}
      assert Reader.decode_flight_data([schema, batch]) === {:ok, []}
    end

    test "a batch with an empty data_header decodes no rows" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      batch = %FlightData{data_header: <<>>, data_body: <<>>}
      assert Reader.decode_flight_data([schema, batch]) === {:ok, []}
    end

    test "a zero-row batch with a nil data_body decodes no rows" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      batch = %FlightData{data_header: batch_msg(0, [{0, 0}, {0, 0}]), data_body: nil}
      assert Reader.decode_flight_data([schema, batch]) === {:ok, []}
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

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"count" => 100}, %{"count" => -200}, %{"count" => 0}]}
    end
  end

  describe "decode_flight_data/1 — Int16 columns" do
    test "decodes Int16 values" do
      schema = schema_fd([{"small", 2, [bit_width: 16, is_signed: true]}])
      {body, specs} = int16_column([1, -1, 32_767])
      batch = batch_fd(body, specs, 3)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"small" => 1}, %{"small" => -1}, %{"small" => 32_767}]}
    end
  end

  describe "decode_flight_data/1 — Int8 columns" do
    test "decodes Int8 values" do
      schema = schema_fd([{"tiny", 2, [bit_width: 8, is_signed: true]}])
      {body, specs} = int8_column([1, -1, 127])
      batch = batch_fd(body, specs, 3)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"tiny" => 1}, %{"tiny" => -1}, %{"tiny" => 127}]}
    end
  end

  describe "decode_flight_data/1 — UInt64 columns" do
    test "decodes UInt64 values" do
      schema = schema_fd([{"big", 2, [bit_width: 64, is_signed: false]}])
      {body, specs} = uint64_column([0, 18_446_744_073_709_551_615])
      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"big" => 0}, %{"big" => 18_446_744_073_709_551_615}]}
    end
  end

  describe "decode_flight_data/1 — UInt32 columns" do
    test "decodes UInt32 values" do
      schema = schema_fd([{"u", 2, [bit_width: 32, is_signed: false]}])
      {body, specs} = uint32_column([0, 4_294_967_295])
      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"u" => 0}, %{"u" => 4_294_967_295}]}
    end
  end

  describe "decode_flight_data/1 — UInt16 columns" do
    test "decodes UInt16 values" do
      schema = schema_fd([{"u16", 2, [bit_width: 16, is_signed: false]}])
      {body, specs} = uint16_column([0, 65_535])
      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"u16" => 0}, %{"u16" => 65_535}]}
    end
  end

  describe "decode_flight_data/1 — UInt8 columns" do
    test "decodes UInt8 values" do
      schema = schema_fd([{"byte", 2, [bit_width: 8, is_signed: false]}])
      {body, specs} = uint8_column([0, 255])
      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"byte" => 0}, %{"byte" => 255}]}
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

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"reading" => 1.0}, %{"reading" => -2.5}]}
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

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"v" => 10}, %{}, %{"v" => 30}]}

      # nulls at the first and the last row leave only the middle value
      {body, specs} = int64_column([10, 20, 30])
      {body, specs} = with_validity_bitmap({body, specs}, 3, MapSet.new([0, 2]))
      batch = batch_fd(body, specs, 3)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{}, %{"v" => 20}, %{}]}
    end

    test "a row past the end of a short bitmap is null; every bit of a byte is read" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      values = Enum.to_list(1..10)
      {data, [_validity, {_off, len}]} = int64_column(values)
      # One byte for ten rows: rows 0 and 7 are null, rows 8 and 9 have no bit.
      body = <<0b01111110>> <> data
      batch = batch_fd(body, [{0, 1}, {1, len}], 10)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{} | Enum.map(2..7, &%{"v" => &1})] ++ [%{}, %{}, %{}]}
    end

    test "marks null Float64 values based on validity bitmap" do
      schema = schema_fd([{"f", 3, [precision: 2]}])
      {body, specs} = float64_column([1.0, 2.0, 3.0])
      {body, specs} = with_validity_bitmap({body, specs}, 3, MapSet.new([0, 2]))
      batch = batch_fd(body, specs, 3)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{}, %{"f" => 2.0}, %{}]}
    end

    test "all-null column via validity bitmap" do
      schema = schema_fd([{"n", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([0, 0])
      {body, specs} = with_validity_bitmap({body, specs}, 2, MapSet.new([0, 1]))
      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{}, %{}]}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — validity bitmap with buffer alignment padding
  #
  # Regression coverage for issue #1: Arrow IPC aligns each buffer on an 8- or
  # 64-byte boundary inside the record batch body, so the validity buffer's
  # offset must be read from the RecordBatch metadata — it cannot be derived
  # from the data buffer offset by subtracting the validity length.
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — validity bitmap with alignment padding" do
    test "decodes Int64 COUNT(*) result when validity buffer is 64-byte aligned" do
      schema = schema_fd([{"n", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([547_808])

      {body, specs} =
        with_padded_validity_bitmap({body, specs}, 1, MapSet.new([]), 64)

      batch = batch_fd(body, specs, 1)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{"n" => 547_808}]}
    end

    test "marks null Int64 value with 64-byte alignment padding" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([10, 99, 30])

      {body, specs} =
        with_padded_validity_bitmap({body, specs}, 3, MapSet.new([1]), 64)

      batch = batch_fd(body, specs, 3)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:ok, [%{"v" => 10}, %{}, %{"v" => 30}]}
    end

    test "decodes Float64 values with 64-byte alignment padding" do
      schema = schema_fd([{"f", 3, [precision: 2]}])
      {body, specs} = float64_column([1.5, 2.5])

      {body, specs} =
        with_padded_validity_bitmap({body, specs}, 2, MapSet.new([]), 64)

      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{"f" => 1.5}, %{"f" => 2.5}]}
    end

    test "decodes Int64 values with 8-byte alignment padding" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      {body, specs} = int64_column([42, 7])

      {body, specs} =
        with_padded_validity_bitmap({body, specs}, 2, MapSet.new([]), 8)

      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{"v" => 42}, %{"v" => 7}]}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: parse_schema/1 — error/edge cases
  # ---------------------------------------------------------------------------

  describe "parse_schema/1 — a corrupt header" do
    test "a header long enough to parse but structurally invalid is a schema parse failure" do
      corrupt = <<0xFF, 0xFF, 0xFF, 0xFF, 20::little-32>> <> :binary.copy(<<0xFF>>, 20)
      assert Reader.parse_schema(corrupt) === {:error, :schema_parse_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests: decode_flight_data/1 — unknown type fallback
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — unknown type columns" do
    test "a type the reader does not decode is refused by name, not dropped" do
      # Dropping it silently made a column vanish from Flight rows while
      # the same query over HTTP had it.
      schema = schema_fd([{"mystery", 99, []}])
      batch = batch_fd(:binary.copy(<<0>>, 16), [{0, 0}, {0, 16}], 2)

      assert Reader.decode_flight_data([schema, batch]) ===
               {:error, {:unsupported_arrow_type, "type 99", "mystery"}}
    end
  end

  describe "decode_flight_data/1 — Decimal columns" do
    # A Decimal type table: slot 0 precision, slot 1 scale, slot 2 bitWidth (all int32). The
    # vtable is padded to 12 bytes, so the table starts 4-aligned.
    defp decimal_schema(scale, width) do
      vtable = <<10::little-16, 16::little-16, 4::little-16, 8::little-16, 12::little-16, 0::16>>

      inline =
        <<12::little-signed-32, 5::little-signed-32, scale::little-signed-32,
          width::little-signed-32>>

      fb = build_schema_fb_custom_type("d", 7, vtable <> inline, 12)
      %FlightData{data_header: schema_msg_from_fb(fb), data_body: <<>>}
    end

    test "a negative scale is an integer, as HTTP gives CAST(1234 AS DECIMAL(5,-2))" do
      body = <<12::little-signed-128, -3::little-signed-128>>
      batch = batch_fd(body, [{0, 0}, {0, 32}], 2)

      assert Reader.decode_flight_data([decimal_schema(-2, 128), batch]) ===
               {:ok, [%{"d" => 1200}, %{"d" => -300}]}
    end

    test "a scale of 0 is an integer, a positive one a float" do
      body = <<150::little-signed-128>>
      batch = batch_fd(body, [{0, 0}, {0, 16}], 1)

      assert Reader.decode_flight_data([decimal_schema(0, 128), batch]) ===
               {:ok, [%{"d" => 150}]}

      assert Reader.decode_flight_data([decimal_schema(2, 128), batch]) ===
               {:ok, [%{"d" => 1.5}]}
    end

    # HTTP prints the decimal's digits (`1.23456789012345664`, verified against Core 3.10.1),
    # which the JSON decoder rounds once to the nearest float.
    test "a positive scale is the nearest float to the decimal's digits" do
      values = [123_456_789_012_345_664, 12_345_678_901_234_567, -5, 0, 7_000_000_000_000_000_001]
      body = for v <- values, into: <<>>, do: <<v::little-signed-256>>
      batch = batch_fd(body, [{0, 0}, {0, byte_size(body)}], length(values))

      assert Reader.decode_flight_data([decimal_schema(17, 256), batch]) ===
               {:ok,
                [
                  %{"d" => 1.23456789012345664},
                  %{"d" => 0.12345678901234567},
                  %{"d" => -0.00000000000000005},
                  %{"d" => 0.0},
                  %{"d" => 70.00000000000000001}
                ]}

      assert Reader.decode_flight_data([decimal_schema(2, 256), batch]) ===
               {:ok,
                [
                  %{"d" => 1_234_567_890_123_456.64},
                  %{"d" => 123_456_789_012_345.67},
                  %{"d" => -0.05},
                  %{"d" => 0.0},
                  %{"d" => 70_000_000_000_000_000.01}
                ]}
    end

    test "a width Arrow does not define is refused, never read without end" do
      batch = batch_fd(<<1, 2, 3, 4>>, [{0, 0}, {0, 4}], 1)

      for width <- [0, 8, 100] do
        assert Reader.decode_flight_data([decimal_schema(0, width), batch]) ===
                 {:error, {:unsupported_arrow_type, "Decimal#{width}", "d"}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fields left out of a FlatBuffer
  #
  # A FlatBuffer vtable slot with value 0 means "field absent": the reader uses the field's
  # default. These tests build minimal FlatBuffers that deliberately omit specific fields.
  # ---------------------------------------------------------------------------

  # Build a field blob where the vtable has specific slots zeroed out.
  # `absent_slots` is a list of 0-based slot indices to mark absent (offset=0).
  defp build_field_blob_with_absent_slots(name, type_type, opts, absent_slots) do
    absent = MapSet.new(absent_slots)

    str_raw = <<byte_size(name)::little-32, name::binary, 0::8>>
    str_blob = pad4(str_raw)
    str_size = byte_size(str_blob)

    {type_blob, type_vtable_size} = build_type_blob(type_type, opts)

    name_offset_pos = @field_table_offset + 4
    name_target = @field_string_offset
    name_rel = name_target - name_offset_pos

    type_blob_start = @field_string_offset + str_size
    type_table_in_blob = type_blob_start + type_vtable_size
    type_offset_pos = @field_table_offset + 16
    type_rel = type_table_in_blob - type_offset_pos

    soffset = @field_table_offset

    # Slots: 0=name(4), 1=nullable(0 absent), 2=type_type(12), 3=type(16)
    slot_values = [4, 0, 12, 16]

    slot_bytes =
      slot_values
      |> Enum.with_index()
      |> Enum.reduce(<<>>, fn {val, idx}, acc ->
        effective = if MapSet.member?(absent, idx), do: 0, else: val
        acc <> <<effective::little-16>>
      end)

    vtable =
      <<@field_vtable_size::little-16, @field_obj_size::little-16>> <> slot_bytes

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

  # Build a type blob for Int with specific vtable slots zeroed out.
  # absent_slots: 0 = bitWidth absent, 1 = is_signed absent
  defp build_int_type_blob_with_absent_slots(bit_width, is_signed, absent_slots) do
    absent = MapSet.new(absent_slots)
    is_signed_byte = if is_signed, do: 1, else: 0

    # Normal Int vtable: size=8, obj_size=10, s0=4(bitWidth), s1=8(is_signed)
    slot_values = [4, 8]

    slot_bytes =
      slot_values
      |> Enum.with_index()
      |> Enum.reduce(<<>>, fn {val, idx}, acc ->
        effective = if MapSet.member?(absent, idx), do: 0, else: val
        acc <> <<effective::little-16>>
      end)

    vtable = <<8::little-16, 10::little-16>> <> slot_bytes
    soffset = byte_size(vtable)
    inline = <<soffset::little-signed-32, bit_width::little-signed-32, is_signed_byte::8, 0::8>>
    {vtable <> inline, @int_vtable_size}
  end

  # Build a full schema FlatBuffer using a pre-built field blob directly.
  defp build_schema_fb_with_blob(field_blob) do
    num_cols = 1
    fields_vec_size = 4 + num_cols * 4
    fields_data_start = @fields_vec_base + fields_vec_size

    field_blob_abs_start = fields_data_start

    root_offset = @msg_table_pos

    vtable_msg = <<
      @msg_vtable_size::little-16,
      @msg_inline_size::little-16,
      0::little-16,
      4::little-16,
      8::little-16
    >>

    msg_soffset = @msg_table_pos - @msg_vtable_pos
    schema_rel = @schema_table_pos - (@msg_table_pos + 8)

    msg_inline = <<
      msg_soffset::little-signed-32,
      1::8,
      0::8,
      0::8,
      0::8,
      schema_rel::little-unsigned-32
    >>

    vtable_schema = <<
      @schema_vtable_size::little-16,
      @schema_inline_size::little-16,
      0::little-16,
      4::little-16
    >>

    schema_soffset = @schema_table_pos - @schema_vtable_pos
    fields_rel = @fields_vec_base - (@schema_table_pos + 4)
    schema_inline = <<schema_soffset::little-signed-32, fields_rel::little-unsigned-32>>

    field_table_abs = field_blob_abs_start + @field_vtable_size
    elem_pos = @fields_vec_base + 4
    field_rel = field_table_abs - elem_pos

    field_vec_elements = <<num_cols::little-32, field_rel::little-unsigned-32>>

    <<root_offset::little-32>> <>
      vtable_msg <>
      msg_inline <>
      vtable_schema <>
      schema_inline <>
      field_vec_elements <>
      field_blob
  end

  # Build a schema FlatBuffer using a custom type blob for the single field.
  defp build_schema_fb_custom_type(name, type_type, type_blob, type_vtable_size) do
    str_raw = <<byte_size(name)::little-32, name::binary, 0::8>>
    str_blob = pad4(str_raw)
    str_size = byte_size(str_blob)

    name_offset_pos = @field_table_offset + 4
    name_target = @field_string_offset
    name_rel = name_target - name_offset_pos

    type_blob_start = @field_string_offset + str_size
    type_table_in_blob = type_blob_start + type_vtable_size
    type_offset_pos = @field_table_offset + 16
    type_rel = type_table_in_blob - type_offset_pos

    soffset = @field_table_offset

    vtable = <<
      @field_vtable_size::little-16,
      @field_obj_size::little-16,
      4::little-16,
      0::little-16,
      12::little-16,
      16::little-16
    >>

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

    field_blob = vtable <> inline <> str_blob <> type_blob
    build_schema_fb_with_blob(field_blob)
  end

  describe "parse_schema/1 — a field whose name is left out" do
    test "has the empty string as its name" do
      field_blob =
        build_field_blob_with_absent_slots("ignored", 2, [bit_width: 64, is_signed: true], [0])

      fb = build_schema_fb_with_blob(field_blob)
      header = schema_msg_from_fb(fb)
      assert Reader.parse_schema(header) === {:ok, [primitive("", 6)]}
    end
  end

  describe "parse_schema/1 — a field whose type_type is left out" do
    test "has no type id and is a type the reader does not decode" do
      field_blob =
        build_field_blob_with_absent_slots("col", 2, [bit_width: 64, is_signed: true], [2])

      fb = build_schema_fb_with_blob(field_blob)
      header = schema_msg_from_fb(fb)

      assert Reader.parse_schema(header) === {:ok, [undecoded("col", "type 0")]}
    end
  end

  describe "parse_schema/1 — an Int whose bitWidth is left out" do
    # Schema.fbs gives `bitWidth` the default 0, which is no integer width: the column has no
    # type id, as a type the reader does not decode has none.
    test "has no type id" do
      {type_blob, type_vtable_size} = build_int_type_blob_with_absent_slots(32, true, [0])
      fb = build_schema_fb_custom_type("val", 2, type_blob, type_vtable_size)
      header = schema_msg_from_fb(fb)

      assert Reader.parse_schema(header) === {:ok, [undecoded("val", "type 2")]}
    end
  end

  # Wrap a bare FlatBuffer binary in the IPC continuation header.
  defp schema_msg_from_fb(fb) do
    fb_size = byte_size(fb)
    <<0xFF, 0xFF, 0xFF, 0xFF, fb_size::little-32, fb::binary>>
  end

  # ---------------------------------------------------------------------------
  # RecordBatch header edge cases
  # ---------------------------------------------------------------------------

  # Build a RecordBatch IPC message with a specific header_type byte.
  defp non_rb_header_msg(header_type_byte) do
    vtable_msg = <<
      @rb_msg_vtable_size::little-16,
      @rb_msg_inline_size::little-16,
      0::little-16,
      4::little-16,
      8::little-16
    >>

    msg_soffset = @rb_msg_table_pos - @rb_msg_vtable_pos
    rb_rel = @rb_table_pos - (@rb_msg_table_pos + 8)

    msg_inline = <<
      msg_soffset::little-signed-32,
      header_type_byte::8,
      0::8,
      0::8,
      0::8,
      rb_rel::little-unsigned-32
    >>

    vtable_rb = <<
      @rb_vtable_size::little-16,
      @rb_inline_size::little-16,
      4::little-16,
      0::little-16,
      12::little-16
    >>

    rb_soffset = @rb_table_pos - @rb_vtable_pos
    buf_rel = @rb_bufvec_pos - (@rb_table_pos + 12)

    rb_inline = <<
      rb_soffset::little-signed-32,
      0::little-signed-64,
      buf_rel::little-unsigned-32
    >>

    buffers_vector = <<0::little-32>>
    root_offset = @rb_msg_table_pos

    fb =
      <<root_offset::little-32>> <>
        vtable_msg <>
        msg_inline <>
        vtable_rb <>
        rb_inline <>
        buffers_vector

    fb_size = byte_size(fb)
    <<0xFF, 0xFF, 0xFF, 0xFF, fb_size::little-32, fb::binary>>
  end

  # Build a RecordBatch IPC message where the Message vtable slot for
  # header_type (slot 1) is absent.
  defp rb_msg_with_absent_header_type do
    # Message vtable with slot 1 (header_type) zeroed
    vtable_msg = <<
      @rb_msg_vtable_size::little-16,
      @rb_msg_inline_size::little-16,
      0::little-16,
      0::little-16,
      8::little-16
    >>

    msg_soffset = @rb_msg_table_pos - @rb_msg_vtable_pos
    rb_rel = @rb_table_pos - (@rb_msg_table_pos + 8)

    msg_inline = <<
      msg_soffset::little-signed-32,
      3::8,
      0::8,
      0::8,
      0::8,
      rb_rel::little-unsigned-32
    >>

    vtable_rb = <<
      @rb_vtable_size::little-16,
      @rb_inline_size::little-16,
      4::little-16,
      0::little-16,
      12::little-16
    >>

    rb_soffset = @rb_table_pos - @rb_vtable_pos
    buf_rel = @rb_bufvec_pos - (@rb_table_pos + 12)

    rb_inline = <<
      rb_soffset::little-signed-32,
      1::little-signed-64,
      buf_rel::little-unsigned-32
    >>

    buffers_vector = <<0::little-32>>
    root_offset = @rb_msg_table_pos

    fb =
      <<root_offset::little-32>> <>
        vtable_msg <>
        msg_inline <>
        vtable_rb <>
        rb_inline <>
        buffers_vector

    fb_size = byte_size(fb)
    <<0xFF, 0xFF, 0xFF, 0xFF, fb_size::little-32, fb::binary>>
  end

  # Build a RecordBatch IPC message where the Message header_type is 3
  # (RecordBatch) but the header uoffset field (slot 2) is absent.
  defp rb_msg_with_absent_header_uoffset do
    # Vtable with slot 2 (header uoffset) absent
    vtable_msg = <<
      @rb_msg_vtable_size::little-16,
      @rb_msg_inline_size::little-16,
      0::little-16,
      4::little-16,
      0::little-16
    >>

    msg_soffset = @rb_msg_table_pos - @rb_msg_vtable_pos

    msg_inline = <<
      msg_soffset::little-signed-32,
      3::8,
      0::8,
      0::8,
      0::8,
      0::little-unsigned-32
    >>

    root_offset = @rb_msg_table_pos

    # Pad to at least 8 bytes beyond the header
    padding = :binary.copy(<<0>>, 8)
    fb = <<root_offset::little-32>> <> vtable_msg <> msg_inline <> padding
    fb_size = byte_size(fb)
    <<0xFF, 0xFF, 0xFF, 0xFF, fb_size::little-32, fb::binary>>
  end

  # Build a RecordBatch FlatBuffer where specific RecordBatch vtable slots
  # are absent (zeroed).  absent_slots: 0=length, 2=buffers
  defp build_rb_fb_with_absent_slots(row_count, buffer_specs, absent_slots) do
    absent = MapSet.new(absent_slots)
    buf_count = length(buffer_specs)

    vtable_msg = <<
      @rb_msg_vtable_size::little-16,
      @rb_msg_inline_size::little-16,
      0::little-16,
      4::little-16,
      8::little-16
    >>

    msg_soffset = @rb_msg_table_pos - @rb_msg_vtable_pos
    rb_rel = @rb_table_pos - (@rb_msg_table_pos + 8)

    msg_inline = <<
      msg_soffset::little-signed-32,
      3::8,
      0::8,
      0::8,
      0::8,
      rb_rel::little-unsigned-32
    >>

    # RecordBatch vtable slots: 0=length(4), 1=nodes(0 absent), 2=buffers(12)
    rb_slot_values = [4, 0, 12]

    rb_slot_bytes =
      rb_slot_values
      |> Enum.with_index()
      |> Enum.reduce(<<>>, fn {val, idx}, acc ->
        effective = if MapSet.member?(absent, idx), do: 0, else: val
        acc <> <<effective::little-16>>
      end)

    vtable_rb = <<@rb_vtable_size::little-16, @rb_inline_size::little-16>> <> rb_slot_bytes

    rb_soffset = @rb_table_pos - @rb_vtable_pos
    buf_rel = @rb_bufvec_pos - (@rb_table_pos + 12)

    rb_inline = <<
      rb_soffset::little-signed-32,
      row_count::little-signed-64,
      buf_rel::little-unsigned-32
    >>

    buffer_structs =
      Enum.reduce(buffer_specs, <<>>, fn {off, len}, acc ->
        acc <> <<off::little-signed-64, len::little-signed-64>>
      end)

    buffers_vector = <<buf_count::little-32>> <> buffer_structs
    root_offset = @rb_msg_table_pos

    fb =
      <<root_offset::little-32>> <>
        vtable_msg <>
        msg_inline <>
        vtable_rb <>
        rb_inline <>
        buffers_vector

    fb_size = byte_size(fb)
    <<0xFF, 0xFF, 0xFF, 0xFF, fb_size::little-32, fb::binary>>
  end

  describe "decode_flight_data/1 — a message that is not a record batch" do
    test "a header type other than schema or record batch decodes no rows" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      # A message whose header_type byte is 2 (Dictionary)
      msg_header = non_rb_header_msg(2)
      fd = %FlightData{data_header: msg_header, data_body: <<>>}

      assert Reader.decode_flight_data([schema, fd]) === {:ok, []}
    end

    test "a message with no header type decodes no rows" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      msg_header = rb_msg_with_absent_header_type()
      fd = %FlightData{data_header: msg_header, data_body: <<>>}

      assert Reader.decode_flight_data([schema, fd]) === {:ok, []}
    end

    test "a record batch message with no header offset decodes no rows" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      msg_header = rb_msg_with_absent_header_uoffset()
      fd = %FlightData{data_header: msg_header, data_body: <<>>}

      assert Reader.decode_flight_data([schema, fd]) === {:ok, []}
    end
  end

  describe "decode_flight_data/1 — a record batch with parts of its header left out" do
    test "a batch without a length has zero rows, whatever its buffers hold" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      msg_header = build_rb_fb_with_absent_slots(5, [{0, 0}, {0, 8}], [0])
      {body, _specs} = int64_column([42])
      fd = %FlightData{data_header: msg_header, data_body: body}

      assert Reader.decode_flight_data([schema, fd]) === {:ok, []}
    end

    test "a batch without buffer metadata decodes every cell as null" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])

      empty_body = %FlightData{
        data_header: build_rb_fb_with_absent_slots(1, [], [2]),
        data_body: <<>>
      }

      assert Reader.decode_flight_data([schema, empty_body]) === {:ok, [%{}]}

      # the body is there, but nothing says where a column's data starts
      with_body = %FlightData{
        data_header: build_rb_fb_with_absent_slots(2, [], [2]),
        data_body: <<0::64, 0::64>>
      }

      assert Reader.decode_flight_data([schema, with_body]) === {:ok, [%{}, %{}]}
    end

    test "a header under 8 bytes after its continuation prefix has no rows" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      short_header = <<0xFF, 0xFF, 0xFF, 0xFF, 4::little-32, 0::32>>
      fd = %FlightData{data_header: short_header, data_body: <<>>}

      assert Reader.decode_flight_data([schema, fd]) === {:ok, []}
    end

    test "a structurally invalid header is a batch header parse failure" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      # Long enough to be parsed, but the root offset points far outside the buffer.
      corrupt = <<0xFF, 0xFF, 0xFF, 0xFF, 20::little-32>> <> :binary.copy(<<0xFF>>, 20)
      fd = %FlightData{data_header: corrupt, data_body: <<>>}

      assert Reader.decode_flight_data([schema, fd]) === {:error, :batch_header_parse_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Buffers that cannot be read from the body
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — a data buffer outside the body" do
    test "decodes as null when its offset or length is outside the body" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      body = <<99::little-signed-64>>

      for spec <- [{10_000, 8}, {8, 8}, {-8, 8}, {0, -8}] do
        batch = batch_fd(body, [{0, 0}, spec], 1)
        assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{}]}
      end
    end

    test "an empty body decodes every cell as null" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      batch = batch_fd(<<>>, [{0, 0}, {0, 0}], 1)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{}]}
    end

    test "a data buffer shorter than one value decodes as null" do
      body = <<0::8, 0::8, 0::8>>
      specs = [{0, 0}, {0, 3}]

      int32 = schema_fd([{"v", 2, [bit_width: 32, is_signed: true]}])
      assert Reader.decode_flight_data([int32, batch_fd(body, specs, 1)]) === {:ok, [%{}]}

      float64 = schema_fd([{"f", 3, [precision: 2]}])
      assert Reader.decode_flight_data([float64, batch_fd(body, specs, 1)]) === {:ok, [%{}]}
    end

    test "a validity buffer outside the body leaves every value valid" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      body = <<7::little-signed-64, 8::little-signed-64>>
      # the validity buffer starts at the end of the body, so there is no bitmap to read
      batch = batch_fd(body, [{16, 1}, {0, 16}], 2)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{"v" => 7}, %{"v" => 8}]}
    end

    test "a zero-length validity buffer leaves every value valid" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      {data, _raw_specs} = int64_column([7, 8])
      batch = batch_fd(data, [{0, 0}, {0, byte_size(data)}], 2)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{"v" => 7}, %{"v" => 8}]}
    end
  end

  # ---------------------------------------------------------------------------
  # UTF8 edge cases
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — Utf8 columns with buffers left out" do
    test "a Utf8 column given an offsets buffer but no data buffer decodes as null" do
      schema = schema_fd([{"s", 5, []}])

      offsets_bin = <<0::little-32, 2::little-32, 5::little-32>>
      body = offsets_bin <> "hibye"

      # only the validity and offsets specs: a Utf8 column has three buffers
      specs = [{0, 0}, {0, byte_size(offsets_bin)}]
      batch = batch_fd(body, specs, 2)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{}, %{}]}
    end

    test "a Utf8 column with empty buffers decodes as null, or as no rows in an empty batch" do
      schema = schema_fd([{"s", 5, []}])
      specs = [{0, 0}, {0, 0}, {0, 0}]

      assert Reader.decode_flight_data([schema, batch_fd(<<>>, specs, 0)]) === {:ok, []}
      assert Reader.decode_flight_data([schema, batch_fd(<<>>, specs, 2)]) === {:ok, [%{}, %{}]}
    end
  end

  describe "decode_flight_data/1 — empty FlatBuffer vectors" do
    # `0..(count - 1)` with count 0 is the descending range [0, -1] in Elixir,
    # so an empty vector used to be walked twice at bogus indices. The step
    # must be explicit.
    test "a schema with an empty fields vector has no columns and decodes no rows" do
      schema = schema_fd([])
      assert Reader.parse_schema(schema.data_header) === {:ok, []}

      batch = batch_fd(<<>>, [], 0)
      assert Reader.decode_flight_data([schema, batch]) === {:ok, []}
    end

    test "a record batch with an empty buffers vector decodes every column as null (absent)" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      batch = batch_fd(<<>>, [], 2)

      assert Reader.decode_flight_data([schema, batch]) === {:ok, [%{}, %{}]}
    end

    test "malformed inputs to decode_flight_data/1 and parse_schema/1 return errors" do
      schema = schema_fd([{"v", 2, [bit_width: 64, is_signed: true]}])
      batch = batch_fd(<<>>, [], 0)

      bad_inputs = [
        :not_a_list,
        123,
        [%{}],
        [schema | :improper],
        [schema, :not_flight_data]
      ]

      for bad_input <- bad_inputs do
        assert Reader.decode_flight_data(bad_input) === {:error, :invalid_flight_data}
      end

      assert Reader.decode_flight_data([%FlightData{data_header: :bad}]) ===
               {:error, :schema_parse_failed}

      assert Reader.decode_flight_data([schema, %{batch | data_body: nil}]) === {:ok, []}

      assert Reader.decode_flight_data([schema, %{batch | data_body: :not_binary}]) ===
               {:error, :invalid_flight_data}

      assert Reader.parse_schema(:not_binary) === {:error, :schema_parse_failed}
    end
  end
end
