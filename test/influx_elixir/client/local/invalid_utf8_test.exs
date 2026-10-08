defmodule InfluxElixir.Client.Local.InvalidUtf8Test do
  @moduledoc """
  What no engine can be asked: text that is not UTF-8 cannot be sent as JSON, so the double's
  answer has no engine answer to match. The SQL, InfluxQL and Flux texts, database, bucket and
  token names, parameter names, the `format:` option and v3 line protocol (plain or gzip)
  answer by name and never raise. A v2 write is the exception: InfluxDB 2.7 stores the bytes
  as they are and returns them, and so does the double.
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

  describe "SQL" do
    test "a statement, a database name or a format that is not UTF-8 is refused by name",
         %{conn: c} do
      assert Local.query_sql(c, "SELECT '" <> @bad <> "' AS a", database: "utf8_iql") ===
               {:error, %{status: 400, body: "Client.Local: the SQL text is not valid UTF-8"}}

      assert Local.query_sql(c, "SELECT 1", database: "utf8_iql" <> @bad) ===
               {:error, %{status: 400, body: @name_refusal}}

      assert Local.query_sql(c, "SELECT 1 AS a", database: "utf8_iql", format: @bad) ===
               {:error,
                %{
                  status: 400,
                  body:
                    "Client.Local: format: a value that is not valid UTF-8 (the client " <>
                      "cannot write it into the request body)"
                }}
    end

    test "a parameter whose name or value is not UTF-8 is refused before any request",
         %{conn: c} do
      assert Local.query_sql(c, "SELECT $a AS a", database: "utf8_iql", params: %{"a" => @bad}) ===
               {:error, {:invalid_param, "a", :unsupported_type}}

      assert Local.query_sql(c, "SELECT 1 AS a", database: "utf8_iql", params: %{@bad => 1}) ===
               {:error, {:invalid_param, inspect(@bad), :unsupported_key}}
    end
  end

  describe "admin names" do
    test "a database, bucket or token name that is not UTF-8 is refused by name, never raised",
         %{conn: c, v2: v2} do
      refusal = fn kind ->
        {:error, %{status: 400, body: "Client.Local: the #{kind} name is not valid UTF-8"}}
      end

      assert Local.create_database(c, "x" <> @bad) === refusal.("database")
      assert Local.delete_database(c, "x" <> @bad) === refusal.("database")
      assert Local.create_bucket(v2, "x" <> @bad) === refusal.("bucket")
      assert Local.delete_bucket(v2, "x" <> @bad) === refusal.("bucket")
      assert Local.create_token(c, "t" <> @bad) === refusal.("token")
      assert Local.delete_token(c, "t" <> @bad) === refusal.("token")
    end
  end

  describe "v2 line protocol" do
    # Verified against InfluxDB 2.7 (2026-10-08): the write is a 204, and a Flux query returns
    # the tag's bytes as they were written.
    test "a body that is not UTF-8 is stored as written, and read back as it was", %{v2: c} do
      assert Local.write(c, "u,host=a" <> @bad <> "b v=1 1",
               bucket: "utf8_flux",
               org: "o",
               database: "utf8_flux",
               precision: :second
             ) === {:ok, :written}

      assert {:ok, [row]} =
               Local.query_flux(c, @flux_head <> ~s/ |> filter(fn: (r) => r._measurement == "u")/,
                 org: "o"
               )

      assert row["host"] === "a" <> @bad <> "b"
    end
  end

  describe "line protocol" do
    test "a gzip body that inflates to text that is not UTF-8 is the same 400", %{conn: c} do
      body = :zlib.gzip("m,host=" <> @bad <> " v=1 1")

      assert Local.write(c, body, database: "utf8_iql", gzip: true) ===
               {:error,
                %{
                  status: 400,
                  body:
                    "body content is not valid utf8: invalid utf-8 sequence of 1 bytes from index 7"
                }}
    end

    test "a body that is not UTF-8 is the engine's 400, wherever the bytes stand", %{conn: c} do
      # The reason names the index of the first bad byte.
      for {body, index} <- [
            {"m,host=" <> @bad <> " v=1 1", 7},
            {@bad <> " v=1 1", 0},
            {"m " <> @bad <> "=1 1", 2},
            {"m v=\"" <> @bad <> "\" 1", 5},
            {"# " <> @bad <> "\nm v=1 1", 2},
            {"m v=1 " <> @bad, 6}
          ] do
        body_text =
          "body content is not valid utf8: invalid utf-8 sequence of 1 bytes from index " <>
            Integer.to_string(index)

        assert Local.write(c, body, database: "utf8_iql") ===
                 {:error, %{status: 400, body: body_text}}
      end
    end
  end
end
