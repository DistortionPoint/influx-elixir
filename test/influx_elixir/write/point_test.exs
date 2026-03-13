defmodule InfluxElixir.Write.PointTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Write.Point

  describe "new/3" do
    test "creates a point with only measurement and fields" do
      point = Point.new("cpu", %{"value" => 0.64})

      assert point.measurement == "cpu"
      assert point.fields == %{"value" => 0.64}
      assert point.tags == %{}
      assert point.timestamp == nil
    end

    test "creates a point with tags" do
      point =
        Point.new("cpu", %{"value" => 1.0},
          tags: %{"host" => "server01", "region" => "us-east-1"}
        )

      assert point.tags == %{"host" => "server01", "region" => "us-east-1"}
    end

    test "creates a point with integer timestamp" do
      point = Point.new("cpu", %{"value" => 1.0}, timestamp: 1_630_424_257_000_000_000)
      assert point.timestamp == 1_630_424_257_000_000_000
    end

    test "creates a point with DateTime timestamp" do
      dt = ~U[2021-08-31 16:37:37Z]
      point = Point.new("cpu", %{"value" => 1.0}, timestamp: dt)
      assert point.timestamp == dt
    end

    test "defaults tags to empty map when not provided" do
      point = Point.new("cpu", %{"v" => 1})
      assert point.tags == %{}
    end

    test "defaults timestamp to nil when not provided" do
      point = Point.new("cpu", %{"v" => 1})
      assert is_nil(point.timestamp)
    end

    test "accepts integer field values" do
      point = Point.new("cpu", %{"count" => 42})
      assert point.fields["count"] == 42
    end

    test "accepts boolean field values" do
      point = Point.new("status", %{"active" => true})
      assert point.fields["active"] == true
    end

    test "accepts string field values" do
      point = Point.new("event", %{"msg" => "hello world"})
      assert point.fields["msg"] == "hello world"
    end

    test "raises ArgumentError when measurement is missing" do
      assert_raise ArgumentError, fn ->
        struct!(Point, fields: %{"v" => 1})
      end
    end

    test "raises ArgumentError when fields is missing" do
      assert_raise ArgumentError, fn ->
        struct!(Point, measurement: "cpu")
      end
    end
  end
end
