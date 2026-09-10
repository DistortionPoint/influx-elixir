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

    test "returns error for a JSON scalar instead of crashing" do
      assert {:error, {:unexpected_json, nil}} = ResponseParser.parse("null", :json)
      assert {:error, {:unexpected_json, 42}} = ResponseParser.parse("42", :json)
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
    test "parses plain CSV with a header row, cells stay strings" do
      body = "name,value\ncpu,0.64\nmem,0.85"

      assert {:ok, [%{"name" => "cpu", "value" => "0.64"}, %{"name" => "mem", "value" => "0.85"}]} =
               ResponseParser.parse(body, :csv)
    end

    test "returns empty list for empty body" do
      assert {:ok, []} = ResponseParser.parse("", :csv)
    end

    test "parses Flux annotated CSV: CRLF, multiple tables, quoted cells, typed columns" do
      # Captured verbatim from InfluxDB 2.7 with dialect annotations: ["datatype"].
      body =
        "#datatype,string,long,dateTime:RFC3339,string,string,string,string\r\n" <>
          ",result,table,_time,_value,_field,_measurement,host\r\n" <>
          ",_result,0,2023-11-14T22:13:20Z,\"x, y\",label,probe_flux,a\r\n" <>
          "\r\n" <>
          "#datatype,string,long,dateTime:RFC3339,double,string,string,string\r\n" <>
          ",result,table,_time,_value,_field,_measurement,host\r\n" <>
          ",_result,1,2023-11-14T22:13:20Z,42.5,value,probe_flux,a\r\n" <>
          "\r\n"

      assert {:ok, [label_row, value_row]} = ResponseParser.parse(body, :csv)

      assert %{"table" => 0, "_value" => "x, y", "_field" => "label", "host" => "a"} = label_row
      assert %{"table" => 1, "_value" => 42.5, "_field" => "value"} = value_row
      assert value_row["_time"] == ~U[2023-11-14 22:13:20Z]
      refute Map.has_key?(value_row, "")
    end

    test "other annotations without #datatype leave cells as strings" do
      body = "#group,false,false\n,result,value\n,_result,42.5\n"

      assert {:ok, [%{"result" => "_result", "value" => "42.5"}]} =
               ResponseParser.parse(body, :csv)
    end

    test "a table with only annotation rows yields no rows" do
      body = "#datatype,string,double\n\n,result,value\n,_result,1.5\n"
      assert {:ok, [%{"value" => "1.5"}]} = ResponseParser.parse(body, :csv)
    end

    test "a typed cell that does not parse falls back to the raw string" do
      body = "#datatype,string,double,long\n,result,ratio,count\n,_result,abc,1.5\n"
      assert {:ok, [%{"ratio" => "abc", "count" => "1.5"}]} = ResponseParser.parse(body, :csv)
    end

    test "types long, unsignedLong and boolean columns and maps empty cells to nil" do
      body =
        "#datatype,string,long,unsignedLong,boolean,double\n" <>
          ",result,count,ucount,flag,ratio\n" <>
          ",_result,3,7,true,\n"

      assert {:ok, [%{"count" => 3, "ucount" => 7, "flag" => true, "ratio" => nil}]} =
               ResponseParser.parse(body, :csv)
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

    test "converts the Flux _time, _start and _stop columns too" do
      row = %{
        "_time" => "2026-03-12T10:00:00Z",
        "_start" => "2026-03-12T09:00:00Z",
        "_stop" => "2026-03-12T11:00:00Z"
      }

      assert %{
               "_time" => ~U[2026-03-12 10:00:00Z],
               "_start" => ~U[2026-03-12 09:00:00Z],
               "_stop" => ~U[2026-03-12 11:00:00Z]
             } = ResponseParser.coerce_types(row)
    end
  end
end
