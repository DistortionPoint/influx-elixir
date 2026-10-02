defmodule InfluxElixir.Client.QueryParamsTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.QueryParams

  describe "normalize/1" do
    test "takes a map, a keyword list, nil and an empty list, naming every key as a string" do
      assert QueryParams.normalize(%{"b" => "x", 3 => nil, a: 1}) ==
               {:ok, %{"a" => 1, "b" => "x", "3" => nil}}

      assert QueryParams.normalize(b: 2, a: true) == {:ok, %{"a" => true, "b" => 2}}
      assert QueryParams.normalize(nil) == {:ok, %{}}
      assert QueryParams.normalize([]) == {:ok, %{}}
      assert QueryParams.normalize(%{}) == {:ok, %{}}
    end

    test "turns a Decimal into a JSON number" do
      assert {:ok, %{"p" => fragment}} = QueryParams.normalize(p: Decimal.new("1.2E+4"))
      assert fragment |> Jason.encode!() == "12000"
    end

    test "refuses what the engine could not be sent, naming it" do
      for {params, error} <- [
            {%{p: Decimal.new("NaN")}, {"p", :non_finite_decimal}},
            {%{p: Decimal.new("Infinity")}, {"p", :non_finite_decimal}},
            {%{p: {1, 2}}, {"p", :unsupported_type}},
            {[p: self()], {"p", :unsupported_type}},
            {%{{1, 2} => 1}, {"{1, 2}", :unsupported_key}},
            {[{[1], 1}], {"[1]", :unsupported_key}},
            {[1], {"1", :unsupported_key}},
            {5, {"5", :unsupported_params}},
            {"p", {~s|"p"|, :unsupported_params}},
            {%URI{}, {inspect(%URI{}), :unsupported_params}}
          ] do
        {name, reason} = error
        assert QueryParams.normalize(params) == {:error, {:invalid_param, name, reason}}
      end
    end
  end

  # Every pair was read back from InfluxDB 3 Core: the number as it was sent
  # and the value its JSON parser made of it.
  @engine_reads [
    {"0.1", 0.1},
    {"0.30000000000000004", 0.30000000000000004},
    {"123456789.123456789", 123_456_789.12345679},
    {"1.7976931348623157e308", "1.7976931348623157e308"},
    {"1.7976931348623156e308", "1.7976931348623157e308"},
    {"4.9e-324", 5.0e-324},
    {"8.5e-324", 1.0e-323},
    {"1e-400", 0.0},
    {"9007199254740993", 9_007_199_254_740_993},
    {"18446744073709551615", 18_446_744_073_709_551_615},
    {"18446744073709551616", "1.8446744073709552e19"},
    {"-9223372036854775808", -9_223_372_036_854_775_808},
    {"-9223372036854775809", "-9.223372036854776e18"},
    {"123456789012345678901234567890", "1.2345678901234568e29"},
    {"12345678901234567890.123", "1.2345678901234567e19"},
    {"100000000000000000000.5", 1.0e20},
    {"9.999999999999999e22", 1.0e23},
    {"3.14159265358979323846", 3.141592653589793},
    {"1E5", 100_000.0},
    {"1e+5", 100_000.0},
    {"12e-3", 0.012},
    {"0.5e1", 5.0}
  ]

  # The engine's own print of a float, which is how the table spells one.
  defp number(text) when is_binary(text), do: String.to_float(text)
  defp number(value), do: value

  describe "engine_values/1 and problem/1 — a number as the engine's JSON parser reads it" do
    test "reads a number as serde_json does, an ulp off a correct rounding where it is" do
      for {text, value} <- @engine_reads do
        params = %{"p" => Jason.Fragment.new(text)}

        assert QueryParams.problem(params["p"]) == nil, text
        assert QueryParams.engine_values(params) == %{"p" => number(value)}, text
      end
    end

    test "refuses a number past the float range, though the largest double is in" do
      for text <- [
            "1e400",
            "-1e400",
            "1.7976931348623158e308",
            "1797693134862315907729305190789024733617976978942306572734300811577326758055009631327084773224075360211201138798713933576587897688144166224928474306394741243777678934248654852763022196012460941194530829520850057688381506823424628814739131105408272371633505106845862982399472459384797163048353563296242241372160",
            String.duplicate("9", 400)
          ] do
        assert QueryParams.problem(Jason.Fragment.new(text)) == :out_of_range, text
      end
    end

    test "an object or an array is a problem, any other value is not" do
      assert QueryParams.problem(%{a: 1}) == :object
      assert QueryParams.problem([]) == :array
      assert QueryParams.problem([1, %{a: 2}]) == :array

      for value <- [nil, true, 1, 1.5, "x", ~D[2024-01-02], :name] do
        assert QueryParams.problem(value) == nil, inspect(value)
      end
    end

    test "reads the other values as the request's JSON does" do
      assert QueryParams.engine_values(%{
               "a" => nil,
               "b" => true,
               "c" => "x",
               "d" => ~D[2024-01-02],
               "e" => :name,
               "f" => ~U[2024-01-02 03:04:05.000000Z]
             }) == %{
               "a" => nil,
               "b" => true,
               "c" => "x",
               "d" => "2024-01-02",
               "e" => "name",
               "f" => "2024-01-02T03:04:05.000000Z"
             }
    end
  end
end
