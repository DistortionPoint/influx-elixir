defmodule InfluxElixir.Flight.FlatBufferTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Flight.FlatBuffer, as: FB

  # ---------------------------------------------------------------------------
  # FlatBuffer binary construction helpers
  #
  # A FlatBuffer is built bottom-up. The layout used throughout these tests:
  #
  #   [root_offset(4)] [data_area] [vtable] [table_inline_data]
  #
  # - root_offset: uint32 LE pointing to the table from position 0
  # - table_inline_data: first 4 bytes are soffset32 LE pointing *backward*
  #   to the vtable (table_pos - vtable_pos, signed)
  # - vtable: vtable_size(uint16) + object_size(uint16) + field_offsets(uint16 each)
  # - strings: relative uoffset32 to (len_uint32 + bytes)
  # - vectors: relative uoffset32 to (count_uint32 + elements)
  # ---------------------------------------------------------------------------

  # Build a simple single-table FlatBuffer with one int32 scalar field.
  #
  # Layout:
  #   pos 0:  root_offset = 8  (table is at byte 8)
  #   pos 4:  padding (4 zero bytes — vtable lives here)
  #   pos 4:  vtable_size=10 (uint16), obj_size=8 (uint16),
  #           field0_offset=4 (uint16), field1_offset=0 (uint16 — absent)
  #           -- WAIT: let's compute carefully --
  #
  # We use a flat layout:
  #   [0..3]  root_offset (points to table_pos)
  #   [4..13] vtable: vtable_size=10, obj_size=8, slot0=4, slot1=0
  #   [14..17] table: soffset=-(14-4)=-10 (i.e. table_pos - vtable_pos),
  #            field0_data at table_pos+4
  #   [18..21] field0 value (int32)
  #
  # Actually for simplicity we'll compute offsets programmatically:
  defp build_int32_table(value) do
    # vtable: vtable_size=10, obj_size=8, slot0_offset=4, slot1_offset=0
    vtable = <<10::little-16, 8::little-16, 4::little-16, 0::little-16>>
    vtable_size = byte_size(vtable)

    # root_offset (4) + vtable_size (10) = table starts at 14
    table_pos = 4 + vtable_size
    vtable_pos = 4

    # soffset: table_pos - vtable_pos = positive, stored as signed int32 LE
    soffset = table_pos - vtable_pos
    # field0 is at table_pos + 4 (inline in table, after the 4-byte soffset)
    field_data = <<soffset::little-signed-32, value::little-signed-32>>

    # root offset points to table_pos
    root_offset = table_pos

    <<root_offset::little-32>> <> vtable <> field_data
  end

  # Build a table with two fields: int32 at slot 0, int16 at slot 1.
  defp build_two_field_table(v0, v1) do
    # vtable: size=12, obj_size=10, slot0=4, slot1=8
    vtable = <<12::little-16, 10::little-16, 4::little-16, 8::little-16>>
    vtable_size = byte_size(vtable)

    table_pos = 4 + vtable_size
    vtable_pos = 4
    soffset = table_pos - vtable_pos

    # table inline data: soffset(4) + v0(4) + padding(2) + v1(2) = 12 bytes
    # slot0 at table_pos+4, slot1 at table_pos+8
    field_data = <<soffset::little-signed-32, v0::little-signed-32, v1::little-signed-16>>

    root_offset = table_pos

    <<root_offset::little-32>> <> vtable <> field_data
  end

  # Build a FlatBuffer whose table has a string in slot 0.
  #
  # Memory layout (all positions relative to start of buf):
  #   [0..3]   root_offset = 4 + vtable_size + 4  (table_pos)
  #   [4..]    vtable: size=8, obj_size=8, slot0=4
  #   [+4..]   table inline: soffset(4) + string_rel_offset(4)
  #   [+8..]   string data: len(4) + bytes
  defp build_string_table(str) do
    # vtable: size=8, obj_size=8, slot0=4
    vtable = <<8::little-16, 8::little-16, 4::little-16>>
    vtable_size = byte_size(vtable)

    table_pos = 4 + vtable_size
    vtable_pos = 4
    soffset = table_pos - vtable_pos

    # string sits after the table inline data (4 soffset + 4 uoffset = 8 bytes)
    string_pos = table_pos + 8
    str_offset_pos = table_pos + 4
    string_rel = string_pos - str_offset_pos

    str_len = byte_size(str)
    string_data = <<str_len::little-32, str::binary, 0>>

    table_inline = <<soffset::little-signed-32, string_rel::little-unsigned-32>>

    root_offset = table_pos

    <<root_offset::little-32>> <> vtable <> table_inline <> string_data
  end

  # Build a FlatBuffer with a vector of int32 values at slot 0.
  defp build_vector_table(values) do
    # vtable: size=8, obj_size=8, slot0=4
    vtable = <<8::little-16, 8::little-16, 4::little-16>>
    vtable_size = byte_size(vtable)

    table_pos = 4 + vtable_size
    vtable_pos = 4
    soffset = table_pos - vtable_pos

    # vector offset_pos = table_pos + 4
    # vector data follows table inline (4 soffset + 4 uoffset = 8 bytes)
    vec_pos = table_pos + 8
    vec_offset_pos = table_pos + 4
    vec_rel = vec_pos - vec_offset_pos

    count = length(values)

    vec_elements =
      Enum.reduce(values, <<>>, fn v, acc ->
        acc <> <<v::little-signed-32>>
      end)

    vec_data = <<count::little-32>> <> vec_elements

    table_inline = <<soffset::little-signed-32, vec_rel::little-unsigned-32>>

    root_offset = table_pos

    <<root_offset::little-32>> <> vtable <> table_inline <> vec_data
  end

  # Build a table that has a child table offset at slot 0 (for testing
  # read_offset / read_vector_table with two tables).
  defp build_two_table_buf(child_value) do
    # child table: simple int32 table
    # vtable_c: size=8, obj_size=8, slot0=4
    vtable_c = <<8::little-16, 8::little-16, 4::little-16>>
    vtable_c_size = byte_size(vtable_c)

    # parent table vtable: size=8, obj_size=8, slot0=4
    vtable_p = <<8::little-16, 8::little-16, 4::little-16>>
    vtable_p_size = byte_size(vtable_p)

    # Layout:
    #   [0..3]              root_offset (parent_table_pos)
    #   [4..4+vtable_p-1]   parent vtable
    #   [parent_table_pos]  parent table inline: soffset + child_rel_offset
    #   [child_vtable_pos]  child vtable
    #   [child_table_pos]   child table inline: soffset + child_value

    parent_vtable_pos = 4
    parent_table_pos = parent_vtable_pos + vtable_p_size
    # parent inline = 4 (soffset) + 4 (offset to child table)
    child_vtable_pos = parent_table_pos + 8
    child_table_pos = child_vtable_pos + vtable_c_size

    parent_soffset = parent_table_pos - parent_vtable_pos
    # The child offset_pos is at parent_table_pos + 4
    child_offset_pos = parent_table_pos + 4
    child_table_rel = child_table_pos - child_offset_pos

    child_soffset = child_table_pos - child_vtable_pos

    parent_inline =
      <<parent_soffset::little-signed-32, child_table_rel::little-unsigned-32>>

    child_inline = <<child_soffset::little-signed-32, child_value::little-signed-32>>

    root_offset = parent_table_pos

    <<root_offset::little-32>> <>
      vtable_p <>
      parent_inline <>
      vtable_c <>
      child_inline
  end

  # ---------------------------------------------------------------------------
  # root_table_pos/1
  # ---------------------------------------------------------------------------

  describe "root_table_pos/1" do
    test "reads the root table position from the first four bytes" do
      buf = <<24::little-32, 0, 0, 0, 0>>
      assert FB.root_table_pos(buf) == 24
    end

    test "returns 0 when root offset is zero" do
      buf = <<0::little-32, 0, 0>>
      assert FB.root_table_pos(buf) == 0
    end

    test "correctly interprets little-endian byte order" do
      # 0x00000008 little-endian = <<8, 0, 0, 0>>
      buf = <<8, 0, 0, 0, 0, 0, 0, 0>>
      assert FB.root_table_pos(buf) == 8
    end

    test "reads table position from a real constructed buffer" do
      buf = build_int32_table(99)
      pos = FB.root_table_pos(buf)
      # Must be non-negative and within the buffer
      assert pos >= 0
      assert pos < byte_size(buf)
    end
  end

  # ---------------------------------------------------------------------------
  # read_vtable/2
  # ---------------------------------------------------------------------------

  describe "read_vtable/2" do
    test "returns vtable position and size for a simple table" do
      buf = build_int32_table(42)
      table_pos = FB.root_table_pos(buf)
      {vtable_pos, vtable_size} = FB.read_vtable(buf, table_pos)
      # vtable lives before the table
      assert vtable_pos < table_pos
      # vtable_size is the byte size declared in the vtable header
      assert vtable_size > 0
    end

    test "vtable_pos is always less than table_pos" do
      buf = build_string_table("hello")
      table_pos = FB.root_table_pos(buf)
      {vtable_pos, _size} = FB.read_vtable(buf, table_pos)
      assert vtable_pos < table_pos
    end

    test "vtable_size matches the declared size in the vtable header" do
      buf = build_int32_table(0)
      table_pos = FB.root_table_pos(buf)
      {vtable_pos, vtable_size} = FB.read_vtable(buf, table_pos)
      # The vtable header starts with vtable_size as uint16
      <<declared::little-16, _rest::binary>> = binary_part(buf, vtable_pos, vtable_size)
      assert declared == vtable_size
    end

    test "two-field table vtable has larger size" do
      buf1 = build_int32_table(1)
      buf2 = build_two_field_table(1, 2)
      table_pos1 = FB.root_table_pos(buf1)
      table_pos2 = FB.root_table_pos(buf2)
      {_vp1, vsize1} = FB.read_vtable(buf1, table_pos1)
      {_vp2, vsize2} = FB.read_vtable(buf2, table_pos2)
      assert vsize2 > vsize1
    end
  end

  # ---------------------------------------------------------------------------
  # field_pos/5
  # ---------------------------------------------------------------------------

  describe "field_pos/5" do
    test "returns the absolute position of a present field" do
      buf = build_int32_table(77)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      assert is_integer(pos)
      assert pos > 0
    end

    test "returns nil for an absent field (offset 0 in vtable)" do
      buf = build_int32_table(0)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      # slot 1 has offset 0 in our single-field table
      result = FB.field_pos(buf, table_pos, vt_pos, vt_size, 1)
      assert result == nil
    end

    test "returns nil when field index is beyond the vtable" do
      buf = build_int32_table(0)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      # Very large index — beyond any vtable we built
      result = FB.field_pos(buf, table_pos, vt_pos, vt_size, 100)
      assert result == nil
    end

    test "both fields present in two-field table" do
      buf = build_two_field_table(10, 20)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      pos0 = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      pos1 = FB.field_pos(buf, table_pos, vt_pos, vt_size, 1)
      assert is_integer(pos0)
      assert is_integer(pos1)
      assert pos0 != pos1
    end

    test "field position differs from table_pos" do
      buf = build_int32_table(5)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      assert pos != table_pos
    end
  end

  # ---------------------------------------------------------------------------
  # Scalar readers
  # ---------------------------------------------------------------------------

  describe "read_int32/2" do
    test "reads a positive int32 value" do
      buf = build_int32_table(12_345)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      assert FB.read_int32(buf, pos) == 12_345
    end

    test "reads a negative int32 value" do
      buf = build_int32_table(-1)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      assert FB.read_int32(buf, pos) == -1
    end

    test "reads zero" do
      buf = build_int32_table(0)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      assert FB.read_int32(buf, pos) == 0
    end

    test "reads max int32" do
      buf = build_int32_table(2_147_483_647)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      assert FB.read_int32(buf, pos) == 2_147_483_647
    end

    test "reads arbitrary position in a raw binary" do
      buf = <<0::32, 42::little-signed-32, 0::32>>
      assert FB.read_int32(buf, 4) == 42
    end
  end

  describe "read_int16/2" do
    test "reads int16 value from two-field table slot 1" do
      buf = build_two_field_table(0, 32_767)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 1)
      assert FB.read_int16(buf, pos) == 32_767
    end

    test "reads negative int16" do
      buf = <<0::32, -300::little-signed-16>>
      assert FB.read_int16(buf, 4) == -300
    end

    test "reads zero int16" do
      buf = <<0::32, 0::little-signed-16>>
      assert FB.read_int16(buf, 4) == 0
    end
  end

  describe "read_int64/2" do
    test "reads an int64 value" do
      buf = <<0::32, 9_999_999_999::little-signed-64>>
      assert FB.read_int64(buf, 4) == 9_999_999_999
    end

    test "reads a negative int64" do
      buf = <<0::32, -1::little-signed-64>>
      assert FB.read_int64(buf, 4) == -1
    end

    test "reads a timestamp-like nanosecond value" do
      ts = 1_630_424_257_000_000_000
      buf = <<0::32, ts::little-signed-64>>
      assert FB.read_int64(buf, 4) == ts
    end
  end

  describe "read_uint8/2" do
    test "reads zero" do
      buf = <<0::32, 0::8>>
      assert FB.read_uint8(buf, 4) == 0
    end

    test "reads 255" do
      buf = <<0::32, 255::8>>
      assert FB.read_uint8(buf, 4) == 255
    end

    test "reads a mid-range value" do
      buf = <<0::32, 42::8>>
      assert FB.read_uint8(buf, 4) == 42
    end

    test "reads the schema message header type discriminator" do
      # header_type = 1 (Schema), stored as uint8
      buf = <<0::32, 1::8>>
      assert FB.read_uint8(buf, 4) == 1
    end
  end

  describe "read_bool/2" do
    test "reads true when byte is non-zero" do
      buf = <<0::32, 1::8>>
      assert FB.read_bool(buf, 4) == true
    end

    test "reads false when byte is zero" do
      buf = <<0::32, 0::8>>
      assert FB.read_bool(buf, 4) == false
    end

    test "any non-zero byte is true" do
      buf = <<0::32, 255::8>>
      assert FB.read_bool(buf, 4) == true
    end

    test "reads consecutive bool positions" do
      buf = <<0::32, 0::8, 1::8, 0::8>>
      assert FB.read_bool(buf, 4) == false
      assert FB.read_bool(buf, 5) == true
      assert FB.read_bool(buf, 6) == false
    end
  end

  # ---------------------------------------------------------------------------
  # read_string/2
  # ---------------------------------------------------------------------------

  describe "read_string/2" do
    test "reads a simple ASCII string" do
      buf = build_string_table("hello")
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      offset_pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      assert FB.read_string(buf, offset_pos) == "hello"
    end

    test "reads an empty string" do
      buf = build_string_table("")
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      offset_pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      assert FB.read_string(buf, offset_pos) == ""
    end

    test "reads a column name string" do
      buf = build_string_table("temperature")
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      offset_pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      assert FB.read_string(buf, offset_pos) == "temperature"
    end

    test "reads a utf-8 string with multi-byte characters" do
      buf = build_string_table("caf\u00e9")
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      offset_pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      assert FB.read_string(buf, offset_pos) == "caf\u00e9"
    end

    test "reads string length correctly for long names" do
      long_name = String.duplicate("x", 64)
      buf = build_string_table(long_name)
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      offset_pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      result = FB.read_string(buf, offset_pos)
      assert byte_size(result) == 64
      assert result == long_name
    end
  end

  # ---------------------------------------------------------------------------
  # read_offset/2
  # ---------------------------------------------------------------------------

  describe "read_offset/2" do
    test "resolves offset relative to its position" do
      buf = build_two_table_buf(55)
      parent_table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, parent_table_pos)
      offset_pos = FB.field_pos(buf, parent_table_pos, vt_pos, vt_size, 0)
      child_table_pos = FB.read_offset(buf, offset_pos)
      # The child table should be a valid position in the buffer
      assert child_table_pos > offset_pos
      assert child_table_pos < byte_size(buf)
    end

    test "offset_pos + rel_offset = absolute_pos" do
      # Manually crafted: at position 4 we store rel_offset=8,
      # so read_offset(buf, 4) = 4 + 8 = 12
      buf = <<0, 0, 0, 0, 8::little-unsigned-32, 0, 0, 0, 0>>
      assert FB.read_offset(buf, 4) == 12
    end

    test "zero relative offset resolves to the offset_pos itself" do
      buf = <<0, 0, 0, 0, 0::little-unsigned-32>>
      assert FB.read_offset(buf, 4) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # read_vector_header/2
  # ---------------------------------------------------------------------------

  describe "read_vector_header/2" do
    test "returns element start position and count" do
      buf = build_vector_table([10, 20, 30])
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      offset_pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      {_elem_start, count} = FB.read_vector_header(buf, offset_pos)
      assert count == 3
    end

    test "empty vector returns count 0" do
      buf = build_vector_table([])
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      offset_pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      {_elem_start, count} = FB.read_vector_header(buf, offset_pos)
      assert count == 0
    end

    test "single-element vector returns count 1" do
      buf = build_vector_table([42])
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      offset_pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      {_elem_start, count} = FB.read_vector_header(buf, offset_pos)
      assert count == 1
    end

    test "element_start is past the count header" do
      buf = build_vector_table([1, 2])
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      offset_pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      {elem_start, _count} = FB.read_vector_header(buf, offset_pos)
      # The vector header resolves to vec_pos, and elem_start = vec_pos + 4
      # vec_pos is read_offset(buf, offset_pos), so:
      vec_pos = FB.read_offset(buf, offset_pos)
      assert elem_start == vec_pos + 4
    end
  end

  # ---------------------------------------------------------------------------
  # read_vector_table/3
  # ---------------------------------------------------------------------------

  describe "read_vector_table/3" do
    test "reads first element table offset" do
      # Build a vector of int32 values stored as offsets to inline 4-byte tables.
      # We use a simpler fixture: just verify the offset arithmetic
      # at index 0: offset_pos = elem_start + 0*4, result = offset_pos + rel
      buf = <<0, 0, 0, 0, 4::little-unsigned-32, 8::little-unsigned-32>>
      # elem_start = 4, index = 0 => offset_pos = 4, rel = 4, result = 8
      assert FB.read_vector_table(buf, 4, 0) == 8
    end

    test "reads second element table offset" do
      # elem_start = 4, index 0 rel=4, index 1 rel=8
      buf = <<0, 0, 0, 0, 4::little-unsigned-32, 8::little-unsigned-32>>
      # index 1: offset_pos = 4 + 1*4 = 8, rel = 8, result = 16
      assert FB.read_vector_table(buf, 4, 1) == 16
    end

    test "index arithmetic: each element stride is 4 bytes" do
      # For index i at elem_start, offset_pos = elem_start + i*4
      # We verify all three index positions independently
      buf =
        <<
          0::32,
          # elem_start=4, three 4-byte offsets
          10::little-unsigned-32,
          20::little-unsigned-32,
          30::little-unsigned-32
        >>

      # index 0: pos=4, result=4+10=14
      assert FB.read_vector_table(buf, 4, 0) == 14
      # index 1: pos=8, result=8+20=28
      assert FB.read_vector_table(buf, 4, 1) == 28
      # index 2: pos=12, result=12+30=42
      assert FB.read_vector_table(buf, 4, 2) == 42
    end

    test "round-trips through a constructed vector table — element count is correct" do
      # build_vector_table stores int32 scalars as vector elements.
      # read_vector_table interprets elements as uoffset32 relative offsets,
      # so the resolved address can exceed the buffer (that is expected for
      # raw integer values). We only assert the count here.
      buf = build_vector_table([5, 10, 15])
      table_pos = FB.root_table_pos(buf)
      {vt_pos, vt_size} = FB.read_vtable(buf, table_pos)
      offset_pos = FB.field_pos(buf, table_pos, vt_pos, vt_size, 0)
      {_elem_start, count} = FB.read_vector_header(buf, offset_pos)
      assert count == 3
    end
  end
end
