defmodule InfluxElixir.Client.Local.InvalidUtf8Test do
  @moduledoc """
  What no engine can be asked: text that is not UTF-8 cannot be sent as JSON, so the double's
  answer has no engine answer to match. Every entry point that reads text answers by name
  and never raises (the InfluxQL and Flux readers and error bodies take UTF-8; a database
  name is quoted in the 404).
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  @bad <<0xFF>>
  @flux_head "from(bucket: \"utf8_flux\") |> range(start: 0)"
  @flux_refusal ~s({"code":"invalid","message":"Client.Local: the Flux text is not valid UTF-8"})
  @iql_refusal "Client.Local: the InfluxQL text is not valid UTF-8"
  @name_refusal "Client.Local: the database name is not valid UTF-8"

  setup do
    {:ok, conn} = Local.start(databases: ["utf8_iql"])
    {:ok, :written} = Local.write(conn, "m,host=a v=1 1000000000", database: "utf8_iql")
    {:ok, v2} = Local.start(profile: :v2, databases: ["utf8_flux"])

    {:ok, :written} =
      Local.write(v2, "m,host=a v=1 1000000000",
        bucket: "utf8_flux",
        org: "o",
        database: "utf8_flux"
      )

    %{conn: conn, v2: v2}
  end

  describe "InfluxQL" do
    test "a statement that is not UTF-8 is refused by name wherever the bytes stand", %{conn: c} do
      for statement <- [
            "SELECT v FROM m WHERE host = '" <> @bad <> "'",
            "SELECT v FROM m WHERE host =~ /" <> @bad <> "/",
            "SELECT v AS \"" <> @bad <> "\" FROM m",
            "SELECT mean(\"" <> @bad <> "\") FROM m",
            "SELECT v FROM m WHERE time > '" <> @bad <> "'",
            "SELECT v FROM m -- " <> @bad,
            "SHOW MEASUREMENTS WHERE host = '" <> @bad <> "'",
            "SHOW TAG KEYS FROM \"" <> @bad <> "\"",
            @bad
          ] do
        assert Local.query_influxql(c, statement, database: "utf8_iql") ===
                 {:error, %{status: 400, body: @iql_refusal}},
               inspect(statement)
      end
    end

    test "a database name that is not UTF-8 is refused by name, not quoted into a 404", %{
      conn: c
    } do
      for statement <- ["SELECT v FROM m", "SHOW MEASUREMENTS"] do
        assert Local.query_influxql(c, statement, database: "db" <> @bad) ===
                 {:error, %{status: 400, body: @name_refusal}}
      end

      assert Local.query_sql(c, "SELECT 1", database: "db" <> @bad) ===
               {:error, %{status: 400, body: @name_refusal}}
    end
  end

  describe "Flux" do
    test "a script that is not UTF-8 is refused by name wherever the bytes stand", %{v2: c} do
      for script <- [
            @flux_head <> " |> filter(fn: (r) => r.host == \"" <> @bad <> "\")",
            "from(bucket: \"" <> @bad <> "\") |> range(start: 0)",
            @flux_head <> " |> filter(fn: (r) => r.host =~ /" <> @bad <> "/)",
            "// " <> @bad <> "\n" <> @flux_head,
            @bad
          ] do
        assert Local.query_flux(c, script, org: "o") ===
                 {:error, %{status: 400, body: @flux_refusal}},
               inspect(script)
      end
    end
  end

  describe "line protocol" do
    test "a body that is not UTF-8 is the engine's 400, wherever the bytes stand", %{conn: c} do
      for body <- [
            "m,host=" <> @bad <> " v=1 1",
            @bad <> " v=1 1",
            "m " <> @bad <> "=1 1",
            "m v=\"" <> @bad <> "\" 1",
            "# " <> @bad <> "\nm v=1 1",
            "m v=1 " <> @bad
          ] do
        assert {:error, %{status: 400, body: "body content is not valid utf8: " <> _reason}} =
                 Local.write(c, body, database: "utf8_iql")
      end
    end
  end
end
