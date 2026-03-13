defmodule InfluxElixir.Flight.FlatBuffer do
  @moduledoc """
  Minimal FlatBuffer binary reader for Arrow IPC metadata.

  Implements the subset of the FlatBuffer binary format needed to parse
  Arrow IPC `Message`, `Schema`, `RecordBatch`, and related tables.
  No external FlatBuffer library is required.

  ## FlatBuffer Binary Layout

  A FlatBuffer binary starts with a 4-byte root offset pointing to the
  root table. Tables consist of a vtable (field offset directory) and
  inline data. Strings, vectors, and child tables are referenced by
  relative offsets.

  This module exposes low-level readers that operate on `{binary, position}`
  pairs, following the FlatBuffer spec exactly.

  ## References

  - FlatBuffer encoding: https://flatbuffers.dev/flatbuffers_internals.html
  - Arrow IPC format: https://arrow.apache.org/docs/format/Columnar.html
  """

  @doc """
  Returns the absolute position of the root table in the buffer.

  The first 4 bytes of a FlatBuffer are a little-endian uint32 offset
  from position 0 to the root table.

  ## Parameters

    * `buf` — the complete FlatBuffer binary

  ## Returns

  The absolute byte position of the root table.
  """
  @spec root_table_pos(binary()) :: non_neg_integer()
  def root_table_pos(buf) when is_binary(buf) do
    <<offset::little-32, _rest::binary>> = buf
    offset
  end

  @doc """
  Reads the vtable for a table at the given position.

  Returns `{vtable_pos, vtable_size}` where `vtable_pos` is the absolute
  position of the vtable and `vtable_size` is its total size in bytes.

  ## Parameters

    * `buf` — the complete FlatBuffer binary
    * `table_pos` — absolute position of the table

  ## Returns

  `{vtable_pos, vtable_size}` tuple.
  """
  @spec read_vtable(binary(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def read_vtable(buf, table_pos) do
    <<soffset::little-signed-32>> = binary_part(buf, table_pos, 4)
    vtable_pos = table_pos - soffset
    <<vtable_size::little-16>> = binary_part(buf, vtable_pos, 2)
    {vtable_pos, vtable_size}
  end

  @doc """
  Reads a field offset from the vtable for a given field index.

  Returns the absolute position of the field data, or `nil` if the field
  is not present (offset is 0 or the vtable is too small).

  ## Parameters

    * `buf` — the complete FlatBuffer binary
    * `table_pos` — absolute position of the table
    * `vtable_pos` — absolute position of the vtable
    * `vtable_size` — total size of the vtable in bytes
    * `field_index` — zero-based field index

  ## Returns

  Absolute position of the field data, or `nil`.
  """
  @spec field_pos(
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer() | nil
  def field_pos(buf, table_pos, vtable_pos, vtable_size, field_index) do
    slot_offset = 4 + field_index * 2

    if slot_offset + 2 <= vtable_size do
      <<field_offset::little-16>> =
        binary_part(buf, vtable_pos + slot_offset, 2)

      if field_offset == 0, do: nil, else: table_pos + field_offset
    else
      nil
    end
  end

  @doc """
  Reads a scalar int16 value at the given position.
  """
  @spec read_int16(binary(), non_neg_integer()) :: integer()
  def read_int16(buf, pos) do
    <<v::little-signed-16>> = binary_part(buf, pos, 2)
    v
  end

  @doc """
  Reads a scalar int32 value at the given position.
  """
  @spec read_int32(binary(), non_neg_integer()) :: integer()
  def read_int32(buf, pos) do
    <<v::little-signed-32>> = binary_part(buf, pos, 4)
    v
  end

  @doc """
  Reads a scalar int64 value at the given position.
  """
  @spec read_int64(binary(), non_neg_integer()) :: integer()
  def read_int64(buf, pos) do
    <<v::little-signed-64>> = binary_part(buf, pos, 8)
    v
  end

  @doc """
  Reads an unsigned byte (uint8) at the given position.
  """
  @spec read_uint8(binary(), non_neg_integer()) :: non_neg_integer()
  def read_uint8(buf, pos) do
    <<v::unsigned-8>> = binary_part(buf, pos, 1)
    v
  end

  @doc """
  Reads a boolean value (stored as a byte) at the given position.
  """
  @spec read_bool(binary(), non_neg_integer()) :: boolean()
  def read_bool(buf, pos) do
    <<v::8>> = binary_part(buf, pos, 1)
    v != 0
  end

  @doc """
  Reads a FlatBuffer string at the given indirect offset position.

  The position contains a relative offset (uint32) to the string data.
  The string data starts with a uint32 length followed by UTF-8 bytes.

  ## Parameters

    * `buf` — the complete FlatBuffer binary
    * `offset_pos` — position of the offset (uoffset32) to the string

  ## Returns

  The string as a binary.
  """
  @spec read_string(binary(), non_neg_integer()) :: binary()
  def read_string(buf, offset_pos) do
    <<rel_offset::little-unsigned-32>> = binary_part(buf, offset_pos, 4)
    string_pos = offset_pos + rel_offset
    <<str_len::little-32>> = binary_part(buf, string_pos, 4)
    binary_part(buf, string_pos + 4, str_len)
  end

  @doc """
  Reads a FlatBuffer offset (uoffset32) and returns the absolute target
  position.

  ## Parameters

    * `buf` — the complete FlatBuffer binary
    * `offset_pos` — position of the offset value

  ## Returns

  The absolute position of the referenced object.
  """
  @spec read_offset(binary(), non_neg_integer()) :: non_neg_integer()
  def read_offset(buf, offset_pos) do
    <<rel_offset::little-unsigned-32>> = binary_part(buf, offset_pos, 4)
    offset_pos + rel_offset
  end

  @doc """
  Reads a vector header at an indirect offset position and returns
  `{element_start_pos, count}`.

  The offset position contains a uoffset32 to the vector. The vector
  starts with a uint32 element count, followed by the elements.

  ## Parameters

    * `buf` — the complete FlatBuffer binary
    * `offset_pos` — position of the offset (uoffset32) to the vector

  ## Returns

  `{element_start_pos, count}` where `element_start_pos` is the absolute
  position of the first element and `count` is the number of elements.
  """
  @spec read_vector_header(binary(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def read_vector_header(buf, offset_pos) do
    vec_pos = read_offset(buf, offset_pos)
    <<count::little-32>> = binary_part(buf, vec_pos, 4)
    {vec_pos + 4, count}
  end

  @doc """
  Reads a table position from a vector of table offsets.

  In FlatBuffers, a vector of tables stores uoffset32 values. Each offset
  is relative to the position of that offset within the vector.

  ## Parameters

    * `buf` — the complete FlatBuffer binary
    * `element_start` — absolute position of the first element in the vector
    * `index` — zero-based index of the element to read

  ## Returns

  The absolute position of the table at the given index.
  """
  @spec read_vector_table(binary(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def read_vector_table(buf, element_start, index) do
    offset_pos = element_start + index * 4
    read_offset(buf, offset_pos)
  end
end
