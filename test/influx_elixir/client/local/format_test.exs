defmodule InfluxElixir.Client.Local.FormatTest do
  @moduledoc """
  One unit test per behaviour of `InfluxElixir.Client.Local.Format`. What a
  query's answer is in each format, and the engine's words for a parameter it
  refuses, are pinned against both clients in `InfluxElixir.Contract.SQLParser`
  and `InfluxElixir.Contract.SQLExecutor`.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.Format
  alias InfluxElixir.Client.QueryParams

  @row %{
    "time" => ~U[2023-11-14 22:13:20.000000Z],
    "host" => "a",
    "v" => 1.5,
    "n" => -3,
    "b" => true,
    "e" => ""
  }

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
        assert Format.render_float(value) === csv, "#{inspect(value)}"
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
        assert Format.render_decimal(value) === text, "#{inspect(value)}"
      end
    end
  end

  describe "answer/4 — the request's parameters" do
    test "the format is read before the parameters, the parameters before the query" do
      params = %{"p" => [1]}

      assert {:error, %{status: 400, body: "serde json error: unknown variant `xml`" <> _rest}} =
               Format.answer(:xml, fn -> flunk("the query ran") end, "db", params)

      assert {:error, %{status: 400, body: "serde json error: JSON arrays" <> _rest}} =
               Format.answer(:json, fn -> flunk("the query ran") end, "db", params)
    end
  end

  # The engine's parser stops at the byte where the number ends in the body
  # `Client.HTTP` sends, `db` and `format` left out when the request has none.
  describe "check_params/3" do
    @out_of_range "serde json error: number out of range at line 1 column "

    test "stops the parser where a number past the float range ends, last parameter or not" do
      big = Integer.pow(10, 400)

      for {database, format, params, number} <- [
            {"rv_lib", :json, %{"p" => big}, Integer.to_string(big)},
            {"rv_lib", :json, %{"p" => Decimal.new("1e400")}, Integer.to_string(big)},
            {"rv_lib", :json, %{"p" => -big}, Integer.to_string(-big)},
            {"rv_lib", :json, %{"a" => 1, "p" => -big, "z" => 2}, Integer.to_string(-big)},
            {"rv_lib", nil, %{"p" => big}, Integer.to_string(big)},
            {"é", :json, %{"p" => big}, Integer.to_string(big)},
            {nil, :json, %{"p" => big}, Integer.to_string(big)}
          ] do
        assert {:ok, params} = QueryParams.normalize(params)
        body = QueryParams.request_body(database, "", params, format)
        {at, length} = :binary.match(body, number)

        assert Format.check_params(params, format, database) ===
                 {:error, %{status: 400, body: @out_of_range <> Integer.to_string(at + length)}},
               inspect({database, format, params})
      end
    end
  end

  describe "answer/3" do
    test ":json and :jsonl answer the rows unchanged" do
      assert Format.answer(:json, fn -> {:ok, [@row]} end, "db") === {:ok, [@row]}
      assert Format.answer(:jsonl, fn -> {:ok, [@row]} end, "db") === {:ok, [@row]}
    end

    test ":csv renders values as strings, keeps timestamps and drops empty cells" do
      assert {:ok, [row]} = Format.answer(:csv, fn -> {:ok, [@row]} end, "db")

      assert row === %{
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
      # With a named database the contract pins the column; no database leaves
      # `db` out of the body Client.HTTP sends, and the column is where the
      # format string ends in what is left.
      for {format, database} <- [{:xml, nil}, {:yaml, nil}] do
        request = QueryParams.request_body(database, "", %{}, format)
        {at, length} = :binary.match(request, ~s("format":"#{format}"))
        column = at + length

        assert Format.answer(format, fn -> flunk("the query ran") end, database) ===
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
      for format <- [:pretty, "json", "csv"] do
        assert Format.answer(format, fn -> {:ok, [@row]} end, "db") ===
                 {:error, {:unsupported_format, format}}
      end
    end

    test "a query error is answered before the format" do
      error = {:error, %{status: 400, body: "table not found"}}
      assert Format.answer(:csv, fn -> error end, "db") === error
      assert Format.answer(:pretty, fn -> error end, "db") === error
    end
  end
end
