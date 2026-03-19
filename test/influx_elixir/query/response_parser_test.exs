defmodule InfluxElixir.Query.ResponseParserTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Query.ResponseParser

  describe "parse/2 with :json format" do
    test "parses JSON array response" do
      body = ~s([{"name":"cpu","value":0.64}])

      assert {:ok, [%{"name" => "cpu", "value" => 0.64}]} =
               ResponseParser.parse(body, :json)
    end

    test "parses single JSON object as one-element list" do
      body = ~s({"name":"cpu","value":42})

      assert {:ok, [%{"name" => "cpu", "value" => 42}]} =
               ResponseParser.parse(body, :json)
    end

    test "returns error on invalid JSON" do
      assert {:error, {:json_parse_error, _reason}} =
               ResponseParser.parse("not json", :json)
    end

    test "coerces time fields to DateTime" do
      body =
        ~s([{"time":"2026-03-12T10:00:00Z","value":1}])

      assert {:ok, [row]} = ResponseParser.parse(body, :json)
      assert %DateTime{} = row["time"]
    end
  end

  describe "parse/2 with :jsonl format" do
    test "parses newline-delimited JSON" do
      body = ~s({"a":1}\n{"a":2}\n{"a":3})

      assert {:ok, rows} = ResponseParser.parse(body, :jsonl)
      assert length(rows) == 3
      assert Enum.map(rows, & &1["a"]) == [1, 2, 3]
    end

    test "handles trailing newline" do
      body = ~s({"a":1}\n)

      assert {:ok, [%{"a" => 1}]} =
               ResponseParser.parse(body, :jsonl)
    end

    test "returns error on invalid JSONL line" do
      body = ~s({"a":1}\nnot json\n{"a":3})

      assert {:error, {:jsonl_parse_error, _reason}} =
               ResponseParser.parse(body, :jsonl)
    end
  end

  describe "parse/2 with :csv format" do
    test "parses CSV with header row" do
      body = "name,value\ncpu,0.64\nmem,0.85"
      assert {:ok, rows} = ResponseParser.parse(body, :csv)
      assert length(rows) == 2
      assert hd(rows)["name"] == "cpu"
    end

    test "returns empty list for empty body" do
      assert {:ok, []} = ResponseParser.parse("", :csv)
    end
  end

  describe "parse/2 with :parquet format" do
    test "returns raw binary" do
      body = <<0, 1, 2, 3>>
      assert {:ok, ^body} = ResponseParser.parse(body, :parquet)
    end
  end

  describe "parse/2 with unsupported format" do
    test "returns error" do
      assert {:error, {:unsupported_format, :xml}} =
               ResponseParser.parse("", :xml)
    end
  end

  describe "parse/1 — default format" do
    test "omitting format argument defaults to :json parsing" do
      body = ~s([{"measurement":"cpu","value":1.5}])

      assert {:ok, [row]} = ResponseParser.parse(body)
      assert row["measurement"] == "cpu"
      assert row["value"] == 1.5
    end

    test "invalid JSON body with default format returns json parse error" do
      assert {:error, {:json_parse_error, _reason}} =
               ResponseParser.parse("not valid json")
    end
  end

  describe "coerce_types/1" do
    test "converts time field to DateTime" do
      row = %{"time" => "2026-03-12T10:00:00Z", "value" => 42}
      result = ResponseParser.coerce_types(row)
      assert %DateTime{} = result["time"]
      assert result["value"] == 42
    end

    test "leaves non-time fields unchanged" do
      row = %{"name" => "cpu", "value" => 0.64}
      assert ResponseParser.coerce_types(row) == row
    end

    test "leaves invalid time strings as-is" do
      row = %{"time" => "not a date"}
      result = ResponseParser.coerce_types(row)
      assert result["time"] == "not a date"
    end
  end
end
