defmodule InfluxElixir.Client.Local.FormatTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.Format

  # Every pair was read back from InfluxDB 3 Core's `format: "csv"`.
  @engine_csv [
    {0.5, "0.5"},
    {2.0, "2.0"},
    {100.0, "100.0"},
    {12_345_678.9, "12345678.9"},
    {0.001, "0.001"},
    {0.0001, "0.0001"},
    {0.00001, "0.00001"},
    {1.5e-5, "0.000015"},
    {9.5e-6, "9.5e-6"},
    {1.0e-6, "1e-6"},
    {1.5e-7, "1.5e-7"},
    {5.0e-324, "5e-324"},
    {1.0e15, "1000000000000000.0"},
    {9.999e15, "9999000000000000.0"},
    {1.0e16, "1e16"},
    {1.0e20, "1e20"},
    {123_456_789_012_345_678.0, "1.2345678901234568e17"},
    {1.797_693_134_862_315_7e308, "1.7976931348623157e308"},
    {-12.25, "-12.25"},
    {-2.5e-6, "-2.5e-6"},
    {-1.0e16, "-1e16"},
    {0.0, "0.0"},
    {-0.0, "-0.0"}
  ]

  describe "render_float/1" do
    test "writes each float as the engine's CSV does" do
      for {value, csv} <- @engine_csv do
        assert Format.render_float(value) == csv, "#{inspect(value)}"
      end
    end
  end

  describe "answer/2" do
    @row %{
      "time" => ~U[2023-11-14 22:13:20.000000Z],
      "host" => "a",
      "v" => 1.5,
      "n" => -3,
      "b" => true,
      "e" => ""
    }

    test ":json and :jsonl answer the rows unchanged" do
      assert Format.answer(:json, fn -> {:ok, [@row]} end) == {:ok, [@row]}
      assert Format.answer(:jsonl, fn -> {:ok, [@row]} end) == {:ok, [@row]}
    end

    test ":csv renders values as strings, keeps timestamps and drops empty cells" do
      assert {:ok, [row]} = Format.answer(:csv, fn -> {:ok, [@row]} end)

      assert row == %{
               "time" => ~U[2023-11-14 22:13:20.000000Z],
               "host" => "a",
               "v" => "1.5",
               "n" => "-3",
               "b" => "true"
             }
    end

    test ":csv fails like the engine's aborted body on a nested value" do
      for nested <- [[1.5, 0.0], %{"time" => ~U[2023-11-14 22:13:20.000000Z], "value" => 1.5}] do
        assert {:error, {:connection_error, %Mint.TransportError{reason: :closed}}} =
                 Format.answer(:csv, fn -> {:ok, [%{"a" => nested}]} end)
      end
    end

    test ":parquet is refused by name before the query runs" do
      assert {:error, %{status: 400, body: "Client.Local: format: :parquet" <> _rest}} =
               Format.answer(:parquet, fn -> flunk("the query ran") end)
    end

    test "a format the engine does not know is its 400 before the query runs" do
      assert {:error, %{status: 400, body: body}} =
               Format.answer(:xml, fn -> flunk("the query ran") end)

      assert body =~ "unknown variant `xml`, expected one of `parquet`, `csv`, `pretty`"
    end

    test "a format the engine answers but the client cannot parse is unsupported" do
      for format <- [:pretty, :json_lines, "json", "csv"] do
        assert Format.answer(format, fn -> {:ok, [@row]} end) ==
                 {:error, {:unsupported_format, format}}
      end
    end

    test "a query error is answered before the format" do
      error = {:error, %{status: 400, body: "table not found"}}
      assert Format.answer(:csv, fn -> error end) == error
      assert Format.answer(:pretty, fn -> error end) == error
    end
  end
end
