defmodule InfluxElixir.Flight.FlatBufferTest do
  # The readers against one FlatBuffer laid out by hand, whose every position is known: each
  # assertion is the exact position or value the FlatBuffer format gives.
  use ExUnit.Case, async: true

  alias InfluxElixir.Flight.FlatBuffer, as: FB

  # The byte position of each part is in its comment. Offsets are little-endian; a table's
  # soffset is its own position less its vtable's, a uoffset is relative to where it is stored.
  @buf <<
    # 0: the root uoffset, to the table at 18
    18::little-32,
    # 4: the table's vtable: its own size (14), the table's (20), and each of five fields'
    # offset in the table; the fifth is absent (0)
    14::little-16,
    20::little-16,
    4::little-16,
    8::little-16,
    12::little-16,
    16::little-16,
    0::little-16,
    # 18: the table: its soffset (18 - 4), an int32, an int16 and two bytes of padding, and
    # the uoffsets to a string (30 + 8 = 38) and to a vector (34 + 14 = 48)
    14::little-signed-32,
    -123_456::little-signed-32,
    -300::little-signed-16,
    0::16,
    8::little-32,
    14::little-32,
    # 38: the string: its byte length, its bytes and a NUL
    5::little-32,
    "café",
    0,
    # 48: a vector of two tables: its length, and the uoffsets to them (52 + 8, 56 + 16)
    2::little-32,
    8::little-32,
    16::little-32,
    # 60 and 72: two tables sharing the vtable after them, so their soffsets are negative
    # (60 - 84, 72 - 84); each holds an int64
    -24::little-signed-32,
    1_630_424_257_000_000_000::little-signed-64,
    -12::little-signed-32,
    -1::little-signed-64,
    # 84: their vtable: its size (6), the table's (12), the int64 at 4
    6::little-16,
    12::little-16,
    4::little-16
  >>

  test "the fixture is laid out as its comments say" do
    assert byte_size(@buf) === 90
  end

  test "the root table, its vtable and the position of each field" do
    assert FB.root_table_pos(@buf) === 18
    assert FB.read_vtable(@buf, 18) === {4, 14}

    assert Enum.map(0..4, &FB.field_pos(@buf, 18, 4, 14, &1)) === [22, 26, 30, 34, nil]

    # Slot 5 lies past the vtable's 14 bytes: its two bytes would be the table's soffset
    # (14), so a reader that ignored the size would answer 18 + 14.
    assert FB.field_pos(@buf, 18, 4, 14, 5) === nil
  end

  test "a field's scalar, string and vector" do
    assert FB.read_int32(@buf, 22) === -123_456
    assert FB.read_int16(@buf, 26) === -300
    assert FB.read_string(@buf, 30) === "café"
    assert FB.read_offset(@buf, 34) === 48
    assert FB.read_vector_header(@buf, 34) === {52, 2}
  end

  test "a vector of tables, whose shared vtable lies after them" do
    assert FB.read_vector_table(@buf, 52, 0) === 60
    assert FB.read_vector_table(@buf, 52, 1) === 72

    assert FB.read_vtable(@buf, 60) === {84, 6}
    assert FB.read_vtable(@buf, 72) === {84, 6}

    assert FB.field_pos(@buf, 60, 84, 6, 0) === 64
    assert FB.field_pos(@buf, 72, 84, 6, 0) === 76
    assert FB.field_pos(@buf, 60, 84, 6, 1) === nil

    assert FB.read_int64(@buf, 64) === 1_630_424_257_000_000_000
    assert FB.read_int64(@buf, 76) === -1
  end

  test "an empty string and an empty vector" do
    # A uoffset at 0 to a length of 0 at 4.
    empty = <<4::little-32, 0::little-32>>

    assert FB.read_string(empty, 0) === ""
    assert FB.read_vector_header(empty, 0) === {8, 0}
  end

  test "the scalar readers are little-endian, and signed but for uint8" do
    assert FB.read_int16(<<0x00, 0x80>>, 0) === -32_768
    assert FB.read_int16(<<0xFF, 0x7F>>, 0) === 32_767
    assert FB.read_int32(<<0x01, 0x02, 0x03, 0x04>>, 0) === 0x04030201
    assert FB.read_int32(<<0x00, 0x00, 0x00, 0x80>>, 0) === -2_147_483_648
    assert FB.read_int64(<<0::56, 0x80>>, 0) === -9_223_372_036_854_775_808
    assert FB.read_uint8(<<0, 255>>, 1) === 255
    assert Enum.map(0..2, &FB.read_bool(<<0, 1, 255>>, &1)) === [false, true, true]
  end
end
