defmodule InfluxElixir.Write.LineProtocolTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Write.{LineProtocol, Point}

  describe "encode/1 — basic encoding" do
    test "encodes a minimal point with float field" do
      point = Point.new("cpu", %{"value" => 0.64})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "cpu value=0.64"
    end

    test "encodes a point with integer field (i suffix)" do
      point = Point.new("cpu", %{"count" => 42})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "cpu count=42i"
    end

    test "encodes a point with boolean true field" do
      point = Point.new("status", %{"active" => true})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "status active=true"
    end

    test "encodes a point with boolean false field" do
      point = Point.new("status", %{"active" => false})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "status active=false"
    end

    test "encodes a point with string field (double-quoted)" do
      point = Point.new("event", %{"msg" => "hello"})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == ~s(event msg="hello")
    end

    test "encodes a point with integer timestamp" do
      point = Point.new("cpu", %{"value" => 1.0}, timestamp: 1_630_424_257_000_000_000)
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "cpu value=1.0 1630424257000000000"
    end

    test "encodes a point with DateTime timestamp" do
      dt = ~U[2021-08-31 16:37:37Z]
      point = Point.new("cpu", %{"value" => 1.0}, timestamp: dt)
      assert {:ok, lp} = LineProtocol.encode(point)
      assert String.ends_with?(lp, "#{DateTime.to_unix(dt, :nanosecond)}")
    end

    test "omits timestamp when nil" do
      point = Point.new("cpu", %{"value" => 1.0})
      assert {:ok, lp} = LineProtocol.encode(point)
      refute String.contains?(lp, " 1")
    end
  end

  describe "encode/1 — tags" do
    test "encodes a single tag" do
      point = Point.new("cpu", %{"v" => 1.0}, tags: %{"host" => "server01"})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "cpu,host=server01 v=1.0"
    end

    test "sorts tags lexicographically by key" do
      point =
        Point.new("cpu", %{"v" => 1.0}, tags: %{"zone" => "a", "host" => "b", "app" => "c"})

      assert {:ok, lp} = LineProtocol.encode(point)
      assert String.starts_with?(lp, "cpu,app=c,host=b,zone=a ")
    end

    test "encodes multiple tags" do
      point =
        Point.new("cpu", %{"v" => 1.0}, tags: %{"host" => "s1", "region" => "us-east"})

      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "cpu,host=s1,region=us-east v=1.0"
    end
  end

  describe "encode/1 — escaping" do
    test "escapes spaces in measurement name" do
      point = Point.new("my measurement", %{"v" => 1.0})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert String.starts_with?(lp, "my\\ measurement")
    end

    test "escapes commas in measurement name" do
      point = Point.new("my,measurement", %{"v" => 1.0})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert String.starts_with?(lp, "my\\,measurement")
    end

    test "escapes spaces in tag keys" do
      point = Point.new("cpu", %{"v" => 1.0}, tags: %{"my key" => "val"})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp =~ "my\\ key=val"
    end

    test "escapes equals in tag keys" do
      point = Point.new("cpu", %{"v" => 1.0}, tags: %{"k=ey" => "val"})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp =~ "k\\=ey=val"
    end

    test "escapes commas in tag values" do
      point = Point.new("cpu", %{"v" => 1.0}, tags: %{"host" => "a,b"})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp =~ "host=a\\,b"
    end

    test "escapes spaces in tag values" do
      point = Point.new("cpu", %{"v" => 1.0}, tags: %{"host" => "a b"})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp =~ "host=a\\ b"
    end

    test "escapes backslashes in measurement" do
      point = Point.new("my\\measurement", %{"v" => 1.0})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert String.starts_with?(lp, "my\\\\measurement")
    end

    test "escapes double-quotes in string field values" do
      point = Point.new("event", %{"msg" => ~s(say "hi")})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp =~ ~s(msg="say \\"hi\\"")
    end

    test "escapes backslashes in string field values" do
      point = Point.new("event", %{"path" => "C:\\Users"})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp =~ ~s(path="C:\\\\Users")
    end
  end

  describe "encode/1 — field types" do
    test "large integer retains i suffix" do
      large_int = 9_007_199_254_740_993
      point = Point.new("cpu", %{"big" => large_int})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "cpu big=#{large_int}i"
    end

    test "very large integer (beyond 2^53) round-trips" do
      # 2^63 - 1 (max int64)
      max_int64 = 9_223_372_036_854_775_807
      point = Point.new("cpu", %{"max" => max_int64})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "cpu max=#{max_int64}i"
    end

    test "negative integer gets i suffix" do
      point = Point.new("cpu", %{"delta" => -5})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "cpu delta=-5i"
    end

    test "zero integer gets i suffix" do
      point = Point.new("cpu", %{"count" => 0})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "cpu count=0i"
    end

    test "float 0.64 is encoded as-is" do
      point = Point.new("cpu", %{"v" => 0.64})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp =~ "v=0.64"
    end

    test "encodes multiple fields" do
      point = Point.new("cpu", %{"int_v" => 1, "float_v" => 2.0, "bool_v" => true})
      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp =~ "int_v=1i"
      assert lp =~ "float_v=2.0"
      assert lp =~ "bool_v=true"
    end
  end

  describe "encode/1 — full format" do
    test "encodes a complete point with tags and timestamp" do
      point =
        Point.new("cpu", %{"value" => 0.64},
          tags: %{"host" => "server01"},
          timestamp: 1_630_424_257_000_000_000
        )

      assert {:ok, lp} = LineProtocol.encode(point)
      assert lp == "cpu,host=server01 value=0.64 1630424257000000000"
    end
  end

  describe "encode/1 — error cases" do
    test "returns {:error, :empty_fields} when fields map is empty" do
      # Use struct directly to bypass new/3 since it doesn't validate
      point = %Point{measurement: "cpu", fields: %{}}
      assert {:error, :empty_fields} = LineProtocol.encode(point)
    end

    test "returns {:error, :empty_measurement} for empty measurement" do
      point = %Point{measurement: "", fields: %{"v" => 1.0}}
      assert {:error, :empty_measurement} = LineProtocol.encode(point)
    end

    test "returns {:error, {:invalid_timestamp, _}} for invalid timestamp" do
      point = %Point{measurement: "cpu", fields: %{"v" => 1.0}, timestamp: "bad"}
      assert {:error, {:invalid_timestamp, "bad"}} = LineProtocol.encode(point)
    end
  end

  # Verified against InfluxDB 3: each of these lines is rejected by the
  # server, and a newline outside a quoted value splits the line so the
  # remainder is stored as a second, bogus point
  # (docs/design/2026-09-22_encoder-validation-and-reserved-time.md).
  describe "encode/1 — refuses what no server accepts" do
    test "an empty, non-string or newline-carrying measurement" do
      assert {:error, {:invalid_measurement, "a\nb"}} =
               LineProtocol.encode(%Point{measurement: "a\nb", fields: %{"v" => 1}})

      assert {:error, {:invalid_measurement, :cpu}} =
               LineProtocol.encode(%Point{measurement: :cpu, fields: %{"v" => 1}})
    end

    test "an empty, non-string or newline-carrying tag key or value" do
      for {tags, error} <- [
            {%{"" => "x"}, {:invalid_tag_key, ""}},
            {%{"a\nb" => "x"}, {:invalid_tag_key, "a\nb"}},
            {%{host: "x"}, {:invalid_tag_key, :host}},
            {%{"host" => ""}, {:invalid_tag_value, "host", ""}},
            {%{"host" => "a\nb v=2i"}, {:invalid_tag_value, "host", "a\nb v=2i"}},
            {%{"host" => 1}, {:invalid_tag_value, "host", 1}}
          ] do
        point = Point.new("cpu", %{"v" => 1}, tags: tags)
        assert {:error, ^error} = LineProtocol.encode(point)
      end
    end

    test "time as a tag key is reserved on every InfluxDB version" do
      point = Point.new("cpu", %{"v" => 1}, tags: %{"time" => "x"})
      assert {:error, {:reserved_tag_key, "time"}} = LineProtocol.encode(point)
    end

    test "an empty, non-string or newline-carrying field key" do
      for key <- ["", "a\nb", :v] do
        assert {:error, {:invalid_field_key, ^key}} =
                 LineProtocol.encode(Point.new("cpu", %{key => 1}))
      end
    end

    test "a field value that is not an integer, float, string or boolean" do
      for value <- [nil, :up, [1], %{}, Decimal.new("1.5")] do
        assert {:error, {:invalid_field_value, "v", ^value}} =
                 LineProtocol.encode(Point.new("cpu", %{"v" => value}))
      end
    end

    test "a newline inside a string field value is quoted and accepted" do
      assert {:ok, ~s|cpu s="a\nb"|} = LineProtocol.encode(Point.new("cpu", %{"s" => "a\nb"}))
    end

    test "a field named time is left to the server" do
      assert {:ok, "cpu time=1i"} = LineProtocol.encode(Point.new("cpu", %{"time" => 1}))
    end
  end

  describe "encode/1 — list of points" do
    test "encodes an empty list to empty string" do
      assert {:ok, ""} = LineProtocol.encode([])
    end

    test "encodes a single-element list" do
      point = Point.new("cpu", %{"v" => 1.0})
      assert {:ok, lp} = LineProtocol.encode([point])
      assert lp == "cpu v=1.0"
    end

    test "encodes multiple points as newline-delimited" do
      points = [
        Point.new("cpu", %{"v" => 1.0}),
        Point.new("mem", %{"free" => 512})
      ]

      assert {:ok, lp} = LineProtocol.encode(points)
      lines = String.split(lp, "\n")
      assert length(lines) == 2
      assert Enum.at(lines, 0) == "cpu v=1.0"
      assert Enum.at(lines, 1) == "mem free=512i"
    end

    test "returns error when any point in list is invalid" do
      points = [
        Point.new("cpu", %{"v" => 1.0}),
        %Point{measurement: "mem", fields: %{}}
      ]

      assert {:error, :empty_fields} = LineProtocol.encode(points)
    end
  end

  describe "encode/1 — float representation" do
    # InfluxDB accepts scientific notation; the shortest round-trip form is
    # used so no precision is lost. Verified against InfluxDB 3 Core: these
    # exact literals write and read back as the same floats.
    test "large float keeps a decimal separator or exponent" do
      assert {:ok, "cpu big=1.0e17"} = LineProtocol.encode(Point.new("cpu", %{"big" => 1.0e17}))
    end

    test "tiny float is not rounded to zero" do
      # {:decimals, 17} formatting previously produced "0.0" here.
      assert {:ok, "cpu tiny=1.0e-20"} =
               LineProtocol.encode(Point.new("cpu", %{"tiny" => 1.0e-20}))

      assert {:ok, "cpu small=2.5e-7"} =
               LineProtocol.encode(Point.new("cpu", %{"small" => 2.5e-7}))
    end

    test "float precision round-trips exactly" do
      value = 123_456_789.123456789
      assert {:ok, "cpu v=" <> encoded} = LineProtocol.encode(Point.new("cpu", %{"v" => value}))
      assert String.to_float(encoded) == value
    end
  end

  describe "encode!/1" do
    test "returns binary on success" do
      point = Point.new("cpu", %{"v" => 1.0})
      assert LineProtocol.encode!(point) == "cpu v=1.0"
    end

    test "raises ArgumentError on failure" do
      point = %Point{measurement: "cpu", fields: %{}}

      assert_raise ArgumentError, ~r/LineProtocol encode failed/, fn ->
        LineProtocol.encode!(point)
      end
    end
  end
end
