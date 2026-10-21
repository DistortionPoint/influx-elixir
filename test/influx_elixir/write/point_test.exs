defmodule InfluxElixir.Write.PointTest do
  use ExUnit.Case, async: true

  doctest InfluxElixir.Write.Point

  alias InfluxElixir.Write.Point

  describe "new/3" do
    test "creates a point with only measurement and fields" do
      assert Point.new("cpu", %{"value" => 0.64}) ===
               %Point{measurement: "cpu", fields: %{"value" => 0.64}, tags: %{}, timestamp: nil}
    end

    test "creates a point with tags" do
      point =
        Point.new("cpu", %{"value" => 1.0},
          tags: %{"host" => "server01", "region" => "us-east-1"}
        )

      assert point ===
               %Point{
                 measurement: "cpu",
                 fields: %{"value" => 1.0},
                 tags: %{"host" => "server01", "region" => "us-east-1"},
                 timestamp: nil
               }
    end

    test "creates a point with integer timestamp" do
      point = Point.new("cpu", %{"value" => 1.0}, timestamp: 1_630_424_257_000_000_000)

      assert point ===
               %Point{
                 measurement: "cpu",
                 fields: %{"value" => 1.0},
                 tags: %{},
                 timestamp: 1_630_424_257_000_000_000
               }
    end

    test "creates a point with DateTime timestamp" do
      dt = ~U[2021-08-31 16:37:37Z]
      point = Point.new("cpu", %{"value" => 1.0}, timestamp: dt)

      assert point ===
               %Point{measurement: "cpu", fields: %{"value" => 1.0}, tags: %{}, timestamp: dt}
    end

    test "accepts integer field values" do
      assert Point.new("cpu", %{"count" => 42}) ===
               %Point{measurement: "cpu", fields: %{"count" => 42}, tags: %{}, timestamp: nil}
    end

    test "accepts boolean field values" do
      assert Point.new("status", %{"active" => true}) ===
               %Point{
                 measurement: "status",
                 fields: %{"active" => true},
                 tags: %{},
                 timestamp: nil
               }
    end

    test "accepts string field values" do
      assert Point.new("event", %{"msg" => "hello world"}) ===
               %Point{
                 measurement: "event",
                 fields: %{"msg" => "hello world"},
                 tags: %{},
                 timestamp: nil
               }
    end

    test "nil tags and nil fields are empty, while false is kept as given" do
      assert Point.new("m", nil) === %Point{measurement: "m", fields: %{}, tags: %{}}

      assert Point.new("m", %{"f" => 1}, tags: nil) ===
               %Point{measurement: "m", fields: %{"f" => 1}, tags: %{}}

      assert Point.new("m", nil, tags: nil, timestamp: 5) ===
               %Point{measurement: "m", fields: %{}, tags: %{}, timestamp: 5}

      bad_fields = Point.new("m", false)
      assert bad_fields === %Point{measurement: "m", fields: false, tags: %{}}

      assert InfluxElixir.Write.LineProtocol.encode(bad_fields) ===
               {:error, {:invalid_point, bad_fields}}

      bad_tags = Point.new("m", %{"f" => 1}, tags: false)
      assert bad_tags === %Point{measurement: "m", fields: %{"f" => 1}, tags: false}

      assert InfluxElixir.Write.LineProtocol.encode(bad_tags) ===
               {:error, {:invalid_point, bad_tags}}

      for bad_opts <- [:not_opts, 123, ~c"abc", [:a | :b]] do
        bad_point = Point.new("m", %{"f" => 1}, bad_opts)

        assert bad_point === %Point{
                 measurement: "m",
                 fields: %{"f" => 1},
                 tags: {:invalid_options, bad_opts}
               }

        assert InfluxElixir.Write.LineProtocol.encode(bad_point) ===
                 {:error, {:invalid_point, bad_point}}
      end
    end
  end
end
