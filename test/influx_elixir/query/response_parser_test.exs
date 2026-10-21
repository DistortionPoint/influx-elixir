defmodule InfluxElixir.Query.ResponseParserTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Query.ResponseParser

  describe "parse/2 with :json format" do
    test "parses JSON array response" do
      body = ~s([{"name":"cpu","value":0.64}])

      assert ResponseParser.parse(body, :json) === {:ok, [%{"name" => "cpu", "value" => 0.64}]}
    end

    test "parses single JSON object as one-element list" do
      body = ~s({"name":"cpu","value":42})

      assert ResponseParser.parse(body, :json) === {:ok, [%{"name" => "cpu", "value" => 42}]}
    end

    test "returns error on invalid JSON" do
      assert {:error, {:json_parse_error, _reason}} =
               ResponseParser.parse("not json", :json)
    end

    test "returns error for a JSON scalar instead of crashing" do
      assert {:error, {:unexpected_json, nil}} = ResponseParser.parse("null", :json)
      assert {:error, {:unexpected_json, 42}} = ResponseParser.parse("42", :json)
    end

    test "an array with an element that is not an object is an error, not a crash" do
      assert ResponseParser.parse("[1]", :json) === {:error, {:unexpected_json, 1}}
      assert ResponseParser.parse("[null]", :json) === {:error, {:unexpected_json, nil}}

      assert ResponseParser.parse(~s([{"a":1},[]]), :json) ===
               {:error, {:unexpected_json, []}}
    end

    test "coerces time fields to DateTime" do
      body =
        ~s([{"time":"2026-03-12T10:00:00Z","value":1}])

      assert ResponseParser.parse(body, :json) ===
               {:ok, [%{"time" => ~U[2026-03-12 10:00:00.000000Z], "value" => 1}]}
    end
  end

  describe "parse/2 with :jsonl format" do
    test "parses newline-delimited JSON" do
      body = ~s({"a":1}\n{"a":2}\n{"a":3})

      assert ResponseParser.parse(body, :jsonl) ===
               {:ok, [%{"a" => 1}, %{"a" => 2}, %{"a" => 3}]}
    end

    test "handles trailing newline" do
      body = ~s({"a":1}\n)

      assert ResponseParser.parse(body, :jsonl) === {:ok, [%{"a" => 1}]}
    end

    test "a CRLF blank line is skipped, as the streaming path skips it" do
      body = ~s({"a":1}\r\n\r\n{"a":2}\r\n)

      assert ResponseParser.parse(body, :jsonl) === {:ok, [%{"a" => 1}, %{"a" => 2}]}
    end

    test "returns error on invalid JSONL line" do
      body = ~s({"a":1}\nnot json\n{"a":3})

      assert {:error, {:jsonl_parse_error, _reason}} =
               ResponseParser.parse(body, :jsonl)
    end

    test "a line that is JSON but not an object is an error, not a crash" do
      assert ResponseParser.parse(~s({"a":1}\n"str"), :jsonl) ===
               {:error, {:unexpected_json, "str"}}

      assert ResponseParser.parse("[1]", :jsonl) === {:error, {:unexpected_json, [1]}}
    end
  end

  describe "parse/2 with :csv format (InfluxDB 3)" do
    test "parses plain CSV with a header row, cells stay strings" do
      body = "name,value\ncpu,0.64\nmem,0.85"

      assert ResponseParser.parse(body, :csv) ===
               {:ok,
                [%{"name" => "cpu", "value" => "0.64"}, %{"name" => "mem", "value" => "0.85"}]}
    end

    test "returns empty list for empty body" do
      assert ResponseParser.parse("", :csv) === {:ok, []}
    end

    test "a value's CRLF and newline come back as InfluxDB 3 sent them" do
      # `SELECT 'a' || chr(13) || chr(10) || 'b' AS s, 'x' || chr(10) || 'y' AS n`
      # from InfluxDB 3 Core, verbatim. Only InfluxDB 2's CSV turns "\n" into "\r\n".
      body = "s,n\n\"a\r\nb\",\"x\ny\"\n"

      assert ResponseParser.parse(body, :csv) === {:ok, [%{"s" => "a\r\nb", "n" => "x\ny"}]}
    end

    test "a one-column row that is null or empty is a row, not a table separator" do
      # `SELECT host FROM t` from InfluxDB 3 Core, verbatim: the engine
      # writes the null `host` as `""`. The row was dropped and "b" read as
      # a header, so the answer was one row instead of four.
      body = "host\na\n\"\"\nb\nc\n"

      assert ResponseParser.parse(body, :csv) ===
               {:ok, [%{"host" => "a"}, %{}, %{"host" => "b"}, %{"host" => "c"}]}
    end

    test "a column named like an annotation is a column" do
      assert ResponseParser.parse("#tag\nx\n", :csv) === {:ok, [%{"#tag" => "x"}]}
    end

    test "InfluxDB 3's CSV has no annotations: values are strings, empty cells absent" do
      # `format: "csv"` from InfluxDB 3 Core, verbatim.
      body =
        "iox::measurement,time,v,b\nm,2023-11-14T22:13:20,1.5,true\nm,2023-11-14T22:14:20,0.0,\n"

      assert ResponseParser.parse(body, :csv) ===
               {:ok,
                [
                  %{
                    "iox::measurement" => "m",
                    "time" => ~U[2023-11-14 22:13:20.000000Z],
                    "v" => "1.5",
                    "b" => "true"
                  },
                  %{
                    "iox::measurement" => "m",
                    "time" => ~U[2023-11-14 22:14:20.000000Z],
                    "v" => "0.0"
                  }
                ]}
    end
  end

  describe "parse/2 with a body that is not CSV" do
    # A proxy's error page or a body cut off inside a quoted cell.
    test "is an error for both CSV formats, not a crash" do
      for format <- [:csv, :flux_csv],
          {body, message} <- [
            {~s("a\nb), ~s(expected escape character " but reached the end of file)},
            {~s({"a":1}\n{), ~s(unexpected escape character " in "{\\"a\\":1}\\n")}
          ] do
        assert ResponseParser.parse(body, format) === {:error, {:csv_parse_error, message}}
      end
    end
  end

  describe "parse/2 with :flux_csv format (InfluxDB 2)" do
    test "returns empty list for empty body" do
      assert ResponseParser.parse("", :flux_csv) === {:ok, []}
    end

    test "a dateTime column is a DateTime whatever its name" do
      # `map(fn: (r) => ({r with t: r._time})) |> keep(columns: ["_value", "t"])`
      # from InfluxDB 2.7, verbatim: `t` was left a string.
      body =
        "#datatype,string,long,double,dateTime:RFC3339\r\n" <>
          ",result,table,_value,t\r\n" <>
          ",_result,0,1,2023-11-14T22:13:20Z\r\n\r\n"

      assert ResponseParser.parse(body, :flux_csv) ===
               {:ok,
                [
                  %{
                    "result" => "_result",
                    "table" => 0,
                    "_value" => 1.0,
                    "t" => ~U[2023-11-14 22:13:20.000000Z]
                  }
                ]}
    end

    test "a dateTime cell that is not a time falls back to the raw string" do
      body = "#datatype,string,dateTime:RFC3339\n,result,t\n,_result,soon\n"

      assert ResponseParser.parse(body, :flux_csv) ===
               {:ok, [%{"result" => "_result", "t" => "soon"}]}
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

      # The empty first column of the header names no cell.
      assert ResponseParser.parse(body, :flux_csv) ===
               {:ok,
                [
                  %{
                    "result" => "_result",
                    "table" => 0,
                    "_time" => ~U[2023-11-14 22:13:20.000000Z],
                    "_value" => "x, y",
                    "_field" => "label",
                    "_measurement" => "probe_flux",
                    "host" => "a"
                  },
                  %{
                    "result" => "_result",
                    "table" => 1,
                    "_time" => ~U[2023-11-14 22:13:20.000000Z],
                    "_value" => 42.5,
                    "_field" => "value",
                    "_measurement" => "probe_flux",
                    "host" => "a"
                  }
                ]}
    end

    test "a newline inside a quoted value comes back as the \\n it was stored as" do
      # InfluxDB 2's CSV writer turns "\n" in a value into "\r\n" (verified:
      # the stored `s="l1\nl2"` arrives as "l1\r\nl2" on the wire).
      body = "#datatype,string,long,string\r\n,result,table,s\r\n,_result,0,\"l1\r\nl2\"\r\n\r\n"

      assert ResponseParser.parse(body, :flux_csv) ===
               {:ok, [%{"result" => "_result", "s" => "l1\nl2", "table" => 0}]}
    end

    test "other annotations without #datatype leave cells as strings" do
      body = "#group,false,false\n,result,value\n,_result,42.5\n"

      assert ResponseParser.parse(body, :flux_csv) ===
               {:ok, [%{"result" => "_result", "value" => "42.5"}]}
    end

    test "annotations a blank line ends belong to no table: the next one is untyped" do
      body = "#datatype,string,double\n\n,result,value\n,_result,1.5\n"

      assert ResponseParser.parse(body, :flux_csv) ===
               {:ok, [%{"result" => "_result", "value" => "1.5"}]}
    end

    test "a typed cell that does not parse falls back to the raw string" do
      huge = String.duplicate("9", 310)

      body =
        "#datatype,string,double,double,long\n,result,ratio,huge,count\n,_result,abc,#{huge},1.5\n"

      assert ResponseParser.parse(body, :flux_csv) ===
               {:ok,
                [%{"result" => "_result", "ratio" => "abc", "huge" => huge, "count" => "1.5"}]}
    end

    test "types long, unsignedLong and boolean columns" do
      body =
        "#datatype,string,long,unsignedLong,boolean\n" <>
          ",result,count,ucount,flag\n" <>
          ",_result,3,7,true\n"

      assert ResponseParser.parse(body, :flux_csv) ===
               {:ok, [%{"result" => "_result", "count" => 3, "ucount" => 7, "flag" => true}]}
    end

    test "an empty Flux cell is absent from the row, as a null column is in JSON" do
      # A v2 pivot leaves a field the row lacks empty; an empty string
      # field is an empty cell too (verified).
      body =
        "#datatype,string,long,string,double,double\r\n" <>
          ",result,table,s,x,y\r\n" <>
          ",_result,0,,1,\r\n"

      assert {:ok, [row]} = ResponseParser.parse(body, :flux_csv)
      assert row === %{"result" => "_result", "table" => 0, "x" => 1.0}
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

    test "returns {:invalid_body, body} when body is not a binary across all formats" do
      for format <- [:json, :jsonl, :csv, :flux_csv, :parquet],
          body <- [nil, 123, %{"a" => 1}, [:list]] do
        assert ResponseParser.parse(body, format) === {:error, {:invalid_body, body}}
      end
    end
  end

  describe "parse/1 — default format" do
    test "omitting format argument defaults to :json parsing" do
      body = ~s([{"measurement":"cpu","value":1.5}])

      assert {:ok, [row]} = ResponseParser.parse(body)
      assert row["measurement"] === "cpu"
      assert row["value"] === 1.5
    end

    test "invalid JSON body with default format returns json parse error" do
      assert {:error, {:json_parse_error, _reason}} =
               ResponseParser.parse("not valid json")
    end
  end

  describe "coerce_types/1" do
    test "converts time field to DateTime" do
      row = %{"time" => "2026-03-12T10:00:00Z", "value" => 42}

      assert ResponseParser.coerce_types(row) ===
               %{"time" => ~U[2026-03-12 10:00:00.000000Z], "value" => 42}
    end

    test "leaves non-time fields unchanged" do
      row = %{"name" => "cpu", "value" => 0.64}
      assert ResponseParser.coerce_types(row) === row
    end

    test "treats a zone-less time (InfluxDB 3's JSON rendering) as UTC" do
      # Captured from InfluxDB 3 Core: no "Z", nanosecond fraction.
      row = %{"time" => "2023-11-14T22:13:20.123456789"}

      assert %{"time" => ~U[2023-11-14 22:13:20.123456Z]} =
               ResponseParser.coerce_types(row)
    end

    test "leaves invalid time strings as-is" do
      row = %{"time" => "not a date"}
      result = ResponseParser.coerce_types(row)
      assert result["time"] === "not a date"
    end

    test "a date-shaped string that is not a timestamp stays a string" do
      row = %{"label" => "2023-11-14Tomorrow", "code" => "2023-11-14T22:13"}
      assert ResponseParser.coerce_types(row) === row
    end

    test "timestamps inside structs and lists are coerced too" do
      row = %{
        "sl" => %{"time" => "2023-11-14T22:15:20", "value" => 10.0},
        "ts" => ["2023-11-14T22:13:20", "2023-11-14T22:14:20.5"],
        "at" => ~U[2023-11-14 22:13:20.000000Z]
      }

      assert %{
               "sl" => %{"time" => ~U[2023-11-14 22:15:20.000000Z], "value" => 10.0},
               "ts" => [~U[2023-11-14 22:13:20.000000Z], ~U[2023-11-14 22:14:20.500000Z]],
               "at" => ~U[2023-11-14 22:13:20.000000Z]
             } = ResponseParser.coerce_types(row)
    end

    test "decodes InfluxDB 3's zone-less timestamp under any column name" do
      # Captured from InfluxDB 3 Core for
      #   DATE_BIN(...) AS bucket, selector_min(value, time)['time'] AS low_at
      row = %{
        "bucket" => "2023-11-14T22:12:00",
        "low_at" => "2023-11-14T22:13:20.5",
        "label" => "bucket"
      }

      assert %{
               "bucket" => ~U[2023-11-14 22:12:00.000000Z],
               "low_at" => ~U[2023-11-14 22:13:20.500000Z],
               "label" => "bucket"
             } === ResponseParser.coerce_types(row)
    end

    test "a zoned RFC3339 string outside the time keys stays a string" do
      # Only InfluxDB 3's zone-less rendering is evidence of a timestamp
      # column; a string field carrying an RFC3339 value is left alone.
      row = %{"created_at" => "2026-03-12T10:00:00Z", "note" => "2026-03-12"}
      assert ResponseParser.coerce_types(row) === row
    end

    test "converts the Flux _time, _start and _stop columns too" do
      row = %{
        "_time" => "2026-03-12T10:00:00Z",
        "_start" => "2026-03-12T09:00:00Z",
        "_stop" => "2026-03-12T11:00:00Z"
      }

      # Always microsecond precision, so values compare equal across transports.
      assert %{
               "_time" => ~U[2026-03-12 10:00:00.000000Z],
               "_start" => ~U[2026-03-12 09:00:00.000000Z],
               "_stop" => ~U[2026-03-12 11:00:00.000000Z]
             } === ResponseParser.coerce_types(row)
    end
  end
end
