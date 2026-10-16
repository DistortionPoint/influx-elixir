defmodule InfluxElixir.Write.LineProtocolTest do
  use ExUnit.Case, async: true

  doctest InfluxElixir.Write.LineProtocol

  alias InfluxElixir.Write.{LineProtocol, Point}

  describe "encode/1 — basic encoding" do
    test "encodes a minimal point with float field" do
      point = Point.new("cpu", %{"value" => 0.64})
      assert LineProtocol.encode(point) === {:ok, "cpu value=0.64"}
    end

    test "encodes a point with integer field (i suffix)" do
      point = Point.new("cpu", %{"count" => 42})
      assert LineProtocol.encode(point) === {:ok, "cpu count=42i"}
    end

    test "encodes a point with boolean true field" do
      point = Point.new("status", %{"active" => true})
      assert LineProtocol.encode(point) === {:ok, "status active=true"}
    end

    test "encodes a point with boolean false field" do
      point = Point.new("status", %{"active" => false})
      assert LineProtocol.encode(point) === {:ok, "status active=false"}
    end

    test "encodes a point with string field (double-quoted)" do
      point = Point.new("event", %{"msg" => "hello"})
      assert LineProtocol.encode(point) === {:ok, ~s(event msg="hello")}
    end

    test "encodes a point with integer timestamp" do
      point = Point.new("cpu", %{"value" => 1.0}, timestamp: 1_630_424_257_000_000_000)
      assert LineProtocol.encode(point) === {:ok, "cpu value=1.0 1630424257000000000"}
    end

    test "encodes a point with DateTime timestamp in nanoseconds" do
      point = Point.new("cpu", %{"value" => 1.0}, timestamp: ~U[2021-08-31 16:37:37Z])
      assert LineProtocol.encode(point) === {:ok, "cpu value=1.0 1630427857000000000"}
    end

    test "a DateTime is written in the write's precision, truncated toward the past" do
      point = Point.new("cpu", %{"v" => 1}, timestamp: ~U[2026-09-28 12:00:00.123456Z])

      for {precision, ts} <- [
            {:second, "1790596800"},
            {"s", "1790596800"},
            {:millisecond, "1790596800123"},
            {"ms", "1790596800123"},
            {:microsecond, "1790596800123456"},
            {"u", "1790596800123456"},
            {:nanosecond, "1790596800123456000"},
            {:auto, "1790596800123456000"}
          ] do
        assert LineProtocol.encode(point, precision: precision) === {:ok, "cpu v=1i " <> ts}
      end

      # Before 1970, truncating toward zero would move the time forward.
      early = Point.new("cpu", %{"v" => 1}, timestamp: ~U[1969-12-31 23:59:59.500Z])
      assert LineProtocol.encode(early, precision: :second) === {:ok, "cpu v=1i -1"}
    end

    # `auto` reads a number under 5e15 as seconds, milliseconds or microseconds.
    test "with :auto, a DateTime near 1970 is whole seconds or refused" do
      encode = fn dt ->
        LineProtocol.encode(Point.new("cpu", %{"v" => 1}, timestamp: dt), precision: :auto)
      end

      assert encode.(~U[1970-01-01 00:00:01Z]) === {:ok, "cpu v=1i 1"}
      assert encode.(~U[1969-12-31 23:59:59Z]) === {:ok, "cpu v=1i -1"}
      assert encode.(~U[1970-01-01 00:00:00Z]) === {:ok, "cpu v=1i 0"}

      for dt <- [~U[1970-01-01 00:00:01.5Z], ~U[1970-02-27 20:53:19.999999Z]] do
        assert encode.(dt) === {:error, {:invalid_timestamp, dt}}
      end

      # 5e15 ns and more, either side of 1970, `auto` reads as nanoseconds.
      assert encode.(~U[1970-02-27 20:53:20.000001Z]) === {:ok, "cpu v=1i 5000000000001000"}
      assert encode.(~U[1969-11-04 03:06:39.999999Z]) === {:ok, "cpu v=1i -5000000000001000"}
    end

    test "an integer timestamp is already in the caller's unit, whatever the precision" do
      point = Point.new("cpu", %{"v" => 1}, timestamp: 1_790_596_800)
      assert LineProtocol.encode(point, precision: :second) === {:ok, "cpu v=1i 1790596800"}
    end

    test "omits timestamp when nil" do
      point = Point.new("cpu", %{"value" => 1.0})
      assert LineProtocol.encode(point) === {:ok, "cpu value=1.0"}
    end
  end

  describe "encode/1 — tags" do
    test "encodes a single tag" do
      point = Point.new("cpu", %{"v" => 1.0}, tags: %{"host" => "server01"})
      assert LineProtocol.encode(point) === {:ok, "cpu,host=server01 v=1.0"}
    end

    test "sorts tags lexicographically by key" do
      point =
        Point.new("cpu", %{"v" => 1.0}, tags: %{"zone" => "a", "host" => "b", "app" => "c"})

      assert LineProtocol.encode(point) === {:ok, "cpu,app=c,host=b,zone=a v=1.0"}
    end

    test "encodes multiple tags" do
      point =
        Point.new("cpu", %{"v" => 1.0}, tags: %{"host" => "s1", "region" => "us-east"})

      assert LineProtocol.encode(point) === {:ok, "cpu,host=s1,region=us-east v=1.0"}
    end
  end

  describe "encode/1 — escaping" do
    test "escapes spaces in measurement name" do
      point = Point.new("my measurement", %{"v" => 1.0})
      assert LineProtocol.encode(point) === {:ok, "my\\ measurement v=1.0"}
    end

    test "escapes commas in measurement name" do
      point = Point.new("my,measurement", %{"v" => 1.0})
      assert LineProtocol.encode(point) === {:ok, "my\\,measurement v=1.0"}
    end

    test "escapes spaces in tag keys" do
      point = Point.new("cpu", %{"v" => 1.0}, tags: %{"my key" => "val"})
      assert LineProtocol.encode(point) === {:ok, "cpu,my\\ key=val v=1.0"}
    end

    test "escapes equals in tag keys" do
      point = Point.new("cpu", %{"v" => 1.0}, tags: %{"k=ey" => "val"})
      assert LineProtocol.encode(point) === {:ok, "cpu,k\\=ey=val v=1.0"}
    end

    test "escapes commas in tag values" do
      point = Point.new("cpu", %{"v" => 1.0}, tags: %{"host" => "a,b"})
      assert LineProtocol.encode(point) === {:ok, "cpu,host=a\\,b v=1.0"}
    end

    test "escapes spaces in tag values" do
      point = Point.new("cpu", %{"v" => 1.0}, tags: %{"host" => "a b"})
      assert LineProtocol.encode(point) === {:ok, "cpu,host=a\\ b v=1.0"}
    end

    test "escapes backslashes in measurement" do
      point = Point.new("my\\measurement", %{"v" => 1.0})
      assert LineProtocol.encode(point) === {:ok, "my\\\\measurement v=1.0"}
    end

    test "escapes double-quotes in string field values" do
      point = Point.new("event", %{"msg" => ~s(say "hi")})
      assert LineProtocol.encode(point) === {:ok, ~s(event msg="say \\"hi\\"")}
    end

    test "escapes backslashes in string field values" do
      point = Point.new("event", %{"path" => "C:\\Users"})
      assert LineProtocol.encode(point) === {:ok, ~s(event path="C:\\\\Users")}
    end

    test "each kind of text escapes only its own bytes, beside multi-byte characters" do
      point =
        Point.new("m=é, ü", %{"f é=, k" => ~s(v é,= "q" \\ x)}, tags: %{"t é=, k" => "v ü=, x"})

      assert LineProtocol.encode(point) ===
               {:ok, ~S(m=é\,\ ü,t\ é\=\,\ k=v\ ü\=\,\ x f\ é\=\,\ k="v é,= \"q\" \\ x")}
    end
  end

  describe "encode/1 — field types" do
    test "large integer retains i suffix" do
      point = Point.new("cpu", %{"big" => 9_007_199_254_740_993})
      assert LineProtocol.encode(point) === {:ok, "cpu big=9007199254740993i"}
    end

    test "the largest int64 is written in full with the i suffix" do
      point = Point.new("cpu", %{"max" => 9_223_372_036_854_775_807})
      assert LineProtocol.encode(point) === {:ok, "cpu max=9223372036854775807i"}
    end

    test "negative integer gets i suffix" do
      point = Point.new("cpu", %{"delta" => -5})
      assert LineProtocol.encode(point) === {:ok, "cpu delta=-5i"}
    end

    test "zero integer gets i suffix" do
      point = Point.new("cpu", %{"count" => 0})
      assert LineProtocol.encode(point) === {:ok, "cpu count=0i"}
    end

    test "float 0.64 is encoded as-is" do
      point = Point.new("cpu", %{"v" => 0.64})
      assert LineProtocol.encode(point) === {:ok, "cpu v=0.64"}
    end

    test "encodes multiple fields" do
      point = Point.new("cpu", %{"int_v" => 1, "float_v" => 2.0, "bool_v" => true})
      # Map iteration order of the three keys is the sorted key order for small maps.
      assert LineProtocol.encode(point) === {:ok, "cpu bool_v=true,float_v=2.0,int_v=1i"}
    end
  end

  describe "encode/1 — full format" do
    test "encodes a complete point with tags and timestamp" do
      point =
        Point.new("cpu", %{"value" => 0.64},
          tags: %{"host" => "server01"},
          timestamp: 1_630_424_257_000_000_000
        )

      assert LineProtocol.encode(point) ===
               {:ok, "cpu,host=server01 value=0.64 1630424257000000000"}
    end
  end

  describe "encode/1 — error cases" do
    test "returns {:error, :empty_fields} when fields map is empty" do
      # Use struct directly to bypass new/3 since it doesn't validate
      point = %Point{measurement: "cpu", fields: %{}}
      assert LineProtocol.encode(point) === {:error, :empty_fields}
    end

    test "returns {:error, :empty_measurement} for empty measurement" do
      point = %Point{measurement: "", fields: %{"v" => 1.0}}
      assert LineProtocol.encode(point) === {:error, :empty_measurement}
    end

    test "returns {:error, {:invalid_timestamp, value}} for invalid timestamp" do
      point = %Point{measurement: "cpu", fields: %{"v" => 1.0}, timestamp: "bad"}
      assert LineProtocol.encode(point) === {:error, {:invalid_timestamp, "bad"}}
    end
  end

  # Verified against InfluxDB 3: each of these lines is rejected by the
  # server, and a newline outside a quoted value splits the line so the
  # remainder is stored as a second, bogus point
  # (docs/design/2026-09-22_encoder-validation-and-reserved-time.md).
  describe "encode/1 — refuses what no server accepts" do
    test "an empty, non-string or newline-carrying measurement" do
      newline = %Point{measurement: "a\nb", fields: %{"v" => 1}}
      atom = %Point{measurement: :cpu, fields: %{"v" => 1}}

      assert LineProtocol.encode(newline) === {:error, {:invalid_measurement, "a\nb"}}
      assert LineProtocol.encode(atom) === {:error, {:invalid_measurement, :cpu}}
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
        assert LineProtocol.encode(point) === {:error, error}
      end
    end

    test "time as a tag key is reserved on every InfluxDB version" do
      point = Point.new("cpu", %{"v" => 1}, tags: %{"time" => "x"})
      assert LineProtocol.encode(point) === {:error, {:reserved_tag_key, "time"}}
    end

    test "an empty, non-string or newline-carrying field key" do
      for key <- ["", "a\nb", :v] do
        point = Point.new("cpu", %{key => 1})
        assert LineProtocol.encode(point) === {:error, {:invalid_field_key, key}}
      end
    end

    test "a field value that is not an integer, float, string or boolean" do
      for value <- [nil, :up, [1], %{}, Decimal.new("1.5")] do
        point = Point.new("cpu", %{"v" => value})
        assert LineProtocol.encode(point) === {:error, {:invalid_field_value, "v", value}}
      end
    end

    test "an integer outside 64 bits; the int64 bounds themselves encode" do
      for value <- [9_223_372_036_854_775_808, -9_223_372_036_854_775_809] do
        point = Point.new("cpu", %{"v" => value})
        assert LineProtocol.encode(point) === {:error, {:invalid_field_value, "v", value}}
      end

      min_point = Point.new("cpu", %{"v" => -9_223_372_036_854_775_808})
      assert LineProtocol.encode(min_point) === {:ok, "cpu v=-9223372036854775808i"}
    end

    test "a measurement starting with # is a comment line to the server" do
      comment = Point.new("#cpu", %{"v" => 1})
      assert LineProtocol.encode(comment) === {:error, {:invalid_measurement, "#cpu"}}

      # Anywhere else, and in a tag value, # is an ordinary character.
      ordinary = Point.new("c#pu", %{"v" => 1}, tags: %{"h" => "#a"})
      assert LineProtocol.encode(ordinary) === {:ok, "c#pu,h=#a v=1i"}
    end

    test "a measurement starting with a tab, or with NUL for v2, the server would strip" do
      tab = Point.new("\tcpu", %{"v" => 1})
      nul = Point.new(<<0, "cpu">>, %{"v" => 1})

      for api_version <- [:v3, :v2] do
        assert LineProtocol.encode(tab, api_version: api_version) ===
                 {:error, {:invalid_measurement, "\tcpu"}}
      end

      assert LineProtocol.encode(nul, api_version: :v2) ===
               {:error, {:invalid_measurement, <<0, "cpu">>}}

      # InfluxDB 3 refuses a line whose measurement starts with NUL, so it is the server's
      # to answer, as a tab or a NUL further in is.
      assert LineProtocol.encode(nul) === {:ok, <<0, "cpu v=1i">>}
      assert LineProtocol.encode(Point.new("c\tpu", %{"v" => 1})) === {:ok, "c\tpu v=1i"}
    end

    test "a name ending in a backslash, which both versions refuse even escaped" do
      measurement = Point.new("cpu\\", %{"v" => 1})
      tag_key = Point.new("cpu", %{"v" => 1}, tags: %{"h\\" => "a"})
      tag_value = Point.new("cpu", %{"v" => 1}, tags: %{"h" => "a\\\\"})
      field_key = Point.new("cpu", %{"v\\" => 1})

      assert LineProtocol.encode(measurement) === {:error, {:invalid_measurement, "cpu\\"}}
      assert LineProtocol.encode(tag_key) === {:error, {:invalid_tag_key, "h\\"}}
      assert LineProtocol.encode(tag_value) === {:error, {:invalid_tag_value, "h", "a\\\\"}}
      assert LineProtocol.encode(field_key) === {:error, {:invalid_field_key, "v\\"}}

      # Inside a name, or at the end of a string value, it is escaped and fine.
      inside = Point.new("cpu", %{"s" => "x\\"}, tags: %{"h" => "a\\b"})
      assert LineProtocol.encode(inside) === {:ok, ~S|cpu,h=a\\b s="x\\"|}
    end

    test "a newline inside a string field value is quoted and accepted" do
      point = Point.new("cpu", %{"s" => "a\nb"})
      assert LineProtocol.encode(point) === {:ok, ~s|cpu s="a\nb"|}
    end

    test "a field named time is left to the server" do
      point = Point.new("cpu", %{"time" => 1})
      assert LineProtocol.encode(point) === {:ok, "cpu time=1i"}
    end
  end

  describe "encode/1 — list of points" do
    test "encodes an empty list to empty string" do
      assert LineProtocol.encode([]) === {:ok, ""}
    end

    test "encodes a single-element list" do
      point = Point.new("cpu", %{"v" => 1.0})
      assert LineProtocol.encode([point]) === {:ok, "cpu v=1.0"}
    end

    test "encodes multiple points as newline-delimited" do
      points = [
        Point.new("cpu", %{"v" => 1.0}),
        Point.new("mem", %{"free" => 512})
      ]

      assert LineProtocol.encode(points) === {:ok, "cpu v=1.0\nmem free=512i"}
    end

    test "returns error when any point in list is invalid" do
      points = [
        Point.new("cpu", %{"v" => 1.0}),
        %Point{measurement: "mem", fields: %{}}
      ]

      assert LineProtocol.encode(points) === {:error, :empty_fields}
    end
  end

  describe "encode/1 — float representation" do
    # InfluxDB accepts scientific notation; the shortest round-trip form is
    # used so no precision is lost. Verified against InfluxDB 3 Core: these
    # exact literals write and read back as the same floats.
    test "large float keeps a decimal separator or exponent" do
      point = Point.new("cpu", %{"big" => 1.0e17})
      assert LineProtocol.encode(point) === {:ok, "cpu big=1.0e17"}
    end

    test "tiny float is not rounded to zero" do
      # {:decimals, 17} formatting previously produced "0.0" here.
      tiny = Point.new("cpu", %{"tiny" => 1.0e-20})
      small = Point.new("cpu", %{"small" => 2.5e-7})

      assert LineProtocol.encode(tiny) === {:ok, "cpu tiny=1.0e-20"}
      assert LineProtocol.encode(small) === {:ok, "cpu small=2.5e-7"}
    end

    test "float precision round-trips exactly" do
      value = 123_456_789.123456789
      # The digits are Erlang's shortest round-trip form; the invariant is the exact float.
      assert {:ok, "cpu v=" <> encoded} = LineProtocol.encode(Point.new("cpu", %{"v" => value}))
      assert String.to_float(encoded) === value
    end
  end

  describe "encode!/1" do
    test "returns binary on success" do
      point = Point.new("cpu", %{"v" => 1.0})
      assert LineProtocol.encode!(point) === "cpu v=1.0"
    end

    test "raises ArgumentError on failure" do
      point = %Point{measurement: "cpu", fields: %{}}

      assert_raise ArgumentError, "LineProtocol encode failed: :empty_fields", fn ->
        LineProtocol.encode!(point)
      end
    end
  end
end
