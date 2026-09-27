defmodule InfluxElixir.Client.Local.SQLIdentifiersTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.SQLIdentifiers

  describe "normalize/1" do
    test "folds unquoted identifiers, keywords included, to lower case" do
      assert SQLIdentifiers.normalize("SELECT Host, AVG(V) AS Avg_V FROM Cpu GROUP BY Host") ==
               "select host, avg(v) as avg_v from cpu group by host"
    end

    test "a plain quoted identifier keeps its case and loses its quotes" do
      assert SQLIdentifiers.normalize(~s|SELECT "Host" AS "The_Host" FROM "Cpu"|) ==
               "select Host as The_Host from Cpu"
    end

    test "a quoted identifier that needs its quotes keeps them" do
      assert SQLIdentifiers.normalize(~s|SELECT "Val" AS "Mixed Case", "order" FROM "my m"|) ==
               ~s|select Val as "Mixed Case", "order" from "my m"|
    end

    test "string literals, doubled quotes inside them and placeholders are left alone" do
      assert SQLIdentifiers.normalize("SELECT V FROM m WHERE K = 'It''s A' AND X = $Name") ==
               "select v from m where k = 'It''s A' and x = $Name"
    end

    test "numbers keep their exponent, intervals and subscripts are literals" do
      assert SQLIdentifiers.normalize(
               "SELECT selector_last(V, time)['Value'] FROM m WHERE V > 1E5 " <>
                 "AND time > now() - INTERVAL '5 Minutes'"
             ) ==
               "select selector_last(v, time)['Value'] from m where v > 1E5 " <>
                 "and time > now() - interval '5 Minutes'"
    end
  end
end
