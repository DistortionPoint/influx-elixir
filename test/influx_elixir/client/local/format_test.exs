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

  # What the engine's CSV and a Float64 literal write differ only in the
  # exponent form and the `.0`; the line protocol writes the literal's form.
  describe "render_decimal/1" do
    test "writes a float as the planner and the line protocol write it" do
      for {value, text} <- [
            {1.0, "1"},
            {2.5, "2.5"},
            {0.1, "0.1"},
            {1.0e20, "100000000000000000000"},
            {1.0e-7, "0.0000001"},
            {100_000.0, "100000"},
            {-1.5, "-1.5"},
            {123_456_789.5, "123456789.5"},
            {5.0e-324, "0." <> String.duplicate("0", 323) <> "5"},
            {0.0, "0"},
            {-0.0, "-0"}
          ] do
        assert Format.render_decimal(value) == text, "#{inspect(value)}"
      end
    end
  end

  describe "answer/4 — the request's parameters" do
    test "an object or an array is the engine's 400 at the byte its parser stops" do
      object =
        "serde json error: JSON objects are not supported as query parameters. " <>
          "Expected null, boolean, number, or string at line 1 column "

      array =
        "serde json error: JSON arrays are not supported as query parameters. " <>
          "Expected null, boolean, number, or string. at line 1 column "

      # Each column was read back from Core for the body Client.HTTP sends.
      for {database, params, body} <- [
            {"rv_lib", %{"p" => %{"a" => 1}}, object <> "53"},
            {"rv_lib", %{"p" => [1, 2]}, array <> "51"},
            {"rv_lib", %{"p" => []}, array <> "48"},
            {"rv_lib", %{"p" => %{"a" => %{"b" => [1]}}}, object <> "61"},
            {"rv_lib", %{"p" => [1, %{"a" => 2}]}, array <> "57"},
            {"rv_lib", %{"a" => 1, "p" => %{}}, object <> "54"},
            {"rv_lib", %{"p" => [1, 2], "z" => 1}, array <> "50"}
          ] do
        assert Format.answer(:json, fn -> flunk("the query ran") end, database, params) ==
                 {:error, %{status: 400, body: body}},
               inspect(params)
      end
    end

    test "the format is read before the parameters, the parameters before the query" do
      params = %{"p" => [1]}

      assert {:error, %{status: 400, body: "serde json error: unknown variant `xml`" <> _rest}} =
               Format.answer(:xml, fn -> flunk("the query ran") end, "db", params)

      assert {:error, %{status: 400, body: "serde json error: JSON arrays" <> _rest}} =
               Format.answer(:json, fn -> flunk("the query ran") end, "db", params)
    end

    test "scalar parameters, and a Decimal that is a JSON number, reach the query" do
      params = %{
        "a" => nil,
        "b" => true,
        "c" => 1,
        "d" => 1.5,
        "e" => "x",
        "f" => Jason.Fragment.new("1000.00"),
        "g" => ~D[2024-01-02]
      }

      assert Format.answer(:json, fn -> {:ok, [%{"n" => 1}]} end, "db", params) ==
               {:ok, [%{"n" => 1}]}
    end
  end

  describe "answer/3" do
    @row %{
      "time" => ~U[2023-11-14 22:13:20.000000Z],
      "host" => "a",
      "v" => 1.5,
      "n" => -3,
      "b" => true,
      "e" => ""
    }

    test ":json and :jsonl answer the rows unchanged" do
      assert Format.answer(:json, fn -> {:ok, [@row]} end, "db") == {:ok, [@row]}
      assert Format.answer(:jsonl, fn -> {:ok, [@row]} end, "db") == {:ok, [@row]}
    end

    test ":csv renders values as strings, keeps timestamps and drops empty cells" do
      assert {:ok, [row]} = Format.answer(:csv, fn -> {:ok, [@row]} end, "db")

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
                 Format.answer(:csv, fn -> {:ok, [%{"a" => nested}]} end, "db")
      end
    end

    test ":parquet is refused by name before the query runs" do
      assert {:error, %{status: 400, body: "Client.Local: format: :parquet" <> _rest}} =
               Format.answer(:parquet, fn -> flunk("the query ran") end, "db")
    end

    test "a format the engine does not know is its 400 before the query runs" do
      # The column is where the format string ends in the body Client.HTTP
      # sends, `db` left out when no database is named (verified on Core).
      for {format, database, column} <- [{:xml, "db", 25}, {:xml, nil, 15}, {:yaml, "a", 25}] do
        assert Format.answer(format, fn -> flunk("the query ran") end, database) ==
                 {:error,
                  %{
                    status: 400,
                    body:
                      "serde json error: unknown variant `#{format}`, expected one of " <>
                        "`parquet`, `csv`, `pretty`, `json`, `json_lines`, `jsonl` " <>
                        "at line 1 column #{column}"
                  }}
      end
    end

    test "a format the engine answers but the client cannot parse is unsupported" do
      for format <- [:pretty, :json_lines, "json", "csv"] do
        assert Format.answer(format, fn -> {:ok, [@row]} end, "db") ==
                 {:error, {:unsupported_format, format}}
      end
    end

    test "a query error is answered before the format" do
      error = {:error, %{status: 400, body: "table not found"}}
      assert Format.answer(:csv, fn -> error end, "db") == error
      assert Format.answer(:pretty, fn -> error end, "db") == error
    end
  end
end
