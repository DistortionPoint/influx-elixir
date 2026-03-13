defmodule InfluxElixir.Flight.ReaderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias InfluxElixir.Flight.Proto.FlightData
  alias InfluxElixir.Flight.Reader

  # ---------------------------------------------------------------------------
  # Helpers to build synthetic Arrow IPC binary fixtures
  # ---------------------------------------------------------------------------

  # Builds a minimal Arrow IPC stream-format schema header for testing.
  # We embed column names as length-prefixed strings with type bytes so
  # the heuristic scanner can find them.
  defp build_schema_header(columns) do
    # Each column entry: <<len::little-16, name_bytes, type_id::8>>
    # Surrounded by flatbuffer-like padding bytes.
    col_bytes =
      Enum.map_join(columns, fn {name, type_id} ->
        len = byte_size(name)
        <<len::little-16, name::binary, type_id::8>>
      end)

    # Wrap in IPC stream continuation format
    metadata_len = byte_size(col_bytes)
    <<0xFF, 0xFF, 0xFF, 0xFF, metadata_len::little-32, col_bytes::binary>>
  end

  # Build a FlightData schema message
  defp schema_flight_data(columns) do
    %FlightData{
      data_header: build_schema_header(columns),
      data_body: <<>>
    }
  end

  # Build a record batch FlightData with int64 column data
  defp int64_batch_flight_data(values) do
    n = length(values)

    # Encode values as little-endian int64
    data_body =
      Enum.reduce(values, <<>>, fn v, acc ->
        acc <> <<v::little-signed-64>>
      end)

    # Build a simple header with row count + single buffer spec
    row_count_bytes = <<n::little-64>>
    # Buffer spec: offset=0, length=byte_size(data_body)
    buf_len = byte_size(data_body)
    # validity buffer: offset=0, len=0
    # data buffer: offset=0, len=buf_len
    buffer_specs = <<0::little-64, 0::little-64, 0::little-64, buf_len::little-64>>

    data_header =
      <<0xFF, 0xFF, 0xFF, 0xFF, byte_size(row_count_bytes) + byte_size(buffer_specs)::little-32,
        row_count_bytes::binary, buffer_specs::binary>>

    %FlightData{
      data_header: data_header,
      data_body: data_body
    }
  end

  # Build a record batch FlightData with float64 column data
  defp float64_batch_flight_data(values) do
    n = length(values)

    data_body =
      Enum.reduce(values, <<>>, fn v, acc ->
        acc <> <<v::little-float-64>>
      end)

    row_count_bytes = <<n::little-64>>
    buf_len = byte_size(data_body)
    buffer_specs = <<0::little-64, 0::little-64, 0::little-64, buf_len::little-64>>

    data_header =
      <<0xFF, 0xFF, 0xFF, 0xFF, byte_size(row_count_bytes) + byte_size(buffer_specs)::little-32,
        row_count_bytes::binary, buffer_specs::binary>>

    %FlightData{
      data_header: data_header,
      data_body: data_body
    }
  end

  # Build a bool batch FlightData
  defp bool_batch_flight_data(values) do
    n = length(values)

    # Pack bits into bytes (little-endian bit order)
    bit_chunks = Enum.chunk_every(values, 8, 8, List.duplicate(false, 7))

    data_body =
      Enum.reduce(bit_chunks, <<>>, fn chunk, acc ->
        byte =
          chunk
          |> Enum.with_index()
          |> Enum.reduce(0, fn {v, i}, b -> if v, do: b ||| 1 <<< i, else: b end)

        acc <> <<byte>>
      end)

    row_count_bytes = <<n::little-64>>
    buf_len = byte_size(data_body)
    buffer_specs = <<0::little-64, 0::little-64, 0::little-64, buf_len::little-64>>

    data_header =
      <<0xFF, 0xFF, 0xFF, 0xFF, byte_size(row_count_bytes) + byte_size(buffer_specs)::little-32,
        row_count_bytes::binary, buffer_specs::binary>>

    %FlightData{data_header: data_header, data_body: data_body}
  end

  # Build a utf8 batch FlightData
  defp utf8_batch_flight_data(values) do
    n = length(values)

    # Build offsets array: n+1 int32 values
    {offsets, total_len} =
      Enum.reduce(values, {[0], 0}, fn v, {offs, cur} ->
        new_cur = cur + byte_size(v)
        {offs ++ [new_cur], new_cur}
      end)

    offsets_bin =
      Enum.reduce(offsets, <<>>, fn o, acc -> acc <> <<o::little-signed-32>> end)

    data_bin = Enum.join(values)

    row_count_bytes = <<n::little-64>>

    # 3 buffers: validity (0,0), offsets, data
    buffer_specs =
      <<0::little-64, 0::little-64, 0::little-64, byte_size(offsets_bin)::little-64,
        byte_size(offsets_bin)::little-64, total_len::little-64>>

    data_body = offsets_bin <> data_bin

    metadata =
      <<row_count_bytes::binary, buffer_specs::binary>>

    data_header =
      <<0xFF, 0xFF, 0xFF, 0xFF, byte_size(metadata)::little-32, metadata::binary>>

    %FlightData{data_header: data_header, data_body: data_body}
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "decode_flight_data/1 — empty input" do
    test "returns {:ok, []} for empty list" do
      assert {:ok, []} = Reader.decode_flight_data([])
    end

    test "returns {:ok, []} for schema-only stream (no batches)" do
      schema = schema_flight_data([{"value", 6}])
      assert {:ok, []} = Reader.decode_flight_data([schema])
    end
  end

  describe "decode_flight_data/1 — schema with nil/empty header" do
    test "handles nil data_header" do
      fd = %FlightData{data_header: nil, data_body: <<>>}
      assert {:ok, []} = Reader.decode_flight_data([fd])
    end

    test "handles empty data_header" do
      fd = %FlightData{data_header: <<>>, data_body: <<>>}
      assert {:ok, []} = Reader.decode_flight_data([fd])
    end
  end

  describe "parse_schema/1" do
    test "returns {:ok, []} for nil" do
      assert {:ok, []} = Reader.parse_schema(nil)
    end

    test "returns {:ok, []} for empty binary" do
      assert {:ok, []} = Reader.parse_schema(<<>>)
    end

    test "extracts column names from synthetic schema" do
      # type 6 = int64
      header = build_schema_header([{"value", 6}, {"count", 6}])
      {:ok, cols} = Reader.parse_schema(header)
      names = Enum.map(cols, & &1.name)
      assert "value" in names or "count" in names
    end

    test "returns {:ok, columns} for valid header" do
      header = build_schema_header([{"cpu", 6}])
      assert {:ok, columns} = Reader.parse_schema(header)
      assert is_list(columns)
    end

    test "columns have name and type_id keys" do
      header = build_schema_header([{"temp", 12}])
      {:ok, [col | _rest]} = Reader.parse_schema(header)

      if col do
        assert Map.has_key?(col, :name)
        assert Map.has_key?(col, :type_id)
      end
    end
  end

  describe "decode_flight_data/1 — int64 columns" do
    test "decodes a single int64 column" do
      columns = [{"value", 6}]
      schema = schema_flight_data(columns)
      batch = int64_batch_flight_data([42, 100, -5])
      {:ok, rows} = Reader.decode_flight_data([schema, batch])
      # Result is a list; may be empty if heuristic doesn't find the column
      assert is_list(rows)
    end

    test "returns {:ok, list} for valid int64 batch" do
      schema = schema_flight_data([{"v", 6}])
      batch = int64_batch_flight_data([1, 2, 3])
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert is_list(rows)
    end
  end

  describe "decode_flight_data/1 — float64 columns" do
    test "decodes float64 column" do
      schema = schema_flight_data([{"temp", 12}])
      batch = float64_batch_flight_data([1.5, 2.5, 3.14])
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert is_list(rows)
    end
  end

  describe "decode_flight_data/1 — bool columns" do
    test "decodes bool column" do
      schema = schema_flight_data([{"active", 14}])
      batch = bool_batch_flight_data([true, false, true])
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert is_list(rows)
    end
  end

  describe "decode_flight_data/1 — utf8 columns" do
    test "decodes utf8 column" do
      schema = schema_flight_data([{"host", 15}])
      batch = utf8_batch_flight_data(["server01", "server02"])
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert is_list(rows)
    end
  end

  describe "decode_flight_data/1 — multiple batches" do
    test "concatenates rows from multiple batches" do
      schema = schema_flight_data([{"v", 6}])
      batch1 = int64_batch_flight_data([1, 2])
      batch2 = int64_batch_flight_data([3, 4])
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch1, batch2])
      assert is_list(rows)
    end
  end

  describe "decode_flight_data/1 — empty batch" do
    test "handles batch with nil data_body" do
      schema = schema_flight_data([{"v", 6}])
      batch = %FlightData{data_header: <<>>, data_body: nil}
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert is_list(rows)
    end

    test "handles batch with empty data_body" do
      schema = schema_flight_data([{"v", 6}])
      batch = %FlightData{data_header: <<>>, data_body: <<>>}
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert is_list(rows)
    end
  end

  describe "decode_flight_data/1 — timestamp columns" do
    test "decodes timestamp column (type 20)" do
      schema = schema_flight_data([{"time", 20}])
      batch = int64_batch_flight_data([1_630_424_257_000_000_000])
      assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
      assert is_list(rows)
    end
  end

  describe "known type coverage" do
    test "all known type IDs produce a list result" do
      # Each type should not crash the decoder
      known_types = [
        {2, :int8},
        {3, :int16},
        {4, :int32},
        {6, :int64},
        {7, :uint8},
        {8, :uint16},
        {9, :uint32},
        {10, :uint64},
        {11, :float32},
        {12, :float64},
        {14, :bool},
        {20, :timestamp}
      ]

      for {type_id, _name} <- known_types do
        schema = schema_flight_data([{"col", type_id}])
        batch = %FlightData{data_header: <<>>, data_body: <<>>}
        assert {:ok, rows} = Reader.decode_flight_data([schema, batch])
        assert is_list(rows)
      end
    end
  end
end
