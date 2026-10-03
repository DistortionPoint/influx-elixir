defmodule InfluxElixir.Client.Local.RetentionTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Client.Local.Retention

  describe "Retention.seconds/1 and valid?/1" do
    test "read the engine's grammar into whole seconds" do
      for {text, seconds} <- [
            {"1h", 3_600},
            {"1.5h", 5_400},
            {"1h 30m", 5_400},
            {"1m500ms", 60},
            {"1500ms", 1},
            {"100ms", 0},
            {"0", 0},
            {"1M", 2_630_016},
            {"1y", 31_557_600},
            {"3months", 7_890_048},
            {"1w", 604_800},
            {"10min", 600},
            {"0.1h", 360}
          ] do
        assert true === Retention.valid?(text)
        assert {text, seconds} === {text, Retention.seconds(text)}
      end
    end

    test "refuse what the engine refuses" do
      for text <- ["", "1", "h", "1H", "1mo", "-1h", "1.h", "1 hour ago", "0.5"] do
        assert {text, false} === {text, Retention.valid?(text)}
      end
    end
  end

  describe "Retention.format/1" do
    test "prints seconds as Go prints a duration" do
      for {seconds, text} <- [
            {nil, "0s"},
            {0, "0s"},
            {1, "1s"},
            {60, "1m0s"},
            {90, "1m30s"},
            {3_600, "1h0m0s"},
            {3_661, "1h1m1s"},
            {604_800, "168h0m0s"}
          ] do
        assert {seconds, text} === {seconds, Retention.format(seconds)}
      end
    end
  end

  describe "SHOW RETENTION POLICIES without a database" do
    test "lists every database, _internal among them, with its own period" do
      {:ok, conn} = Local.start(profile: :v3_core)
      :ok = Local.create_database(conn, "plain")
      :ok = Local.create_database(conn, "kept", retention: "2h")

      assert {:ok,
              [
                %{"iox::database" => "_internal", "name" => "autogen", "duration" => "168h0m0s"},
                %{"iox::database" => "kept", "name" => "autogen", "duration" => "2h0m0s"},
                %{"iox::database" => "plain", "name" => "autogen", "duration" => "0s"}
              ]} === Local.query_influxql(conn, "SHOW RETENTION POLICIES")
    end
  end

  describe "create_database/3 with a retention" do
    test "a retention the engine refuses creates nothing" do
      {:ok, conn} = Local.start(profile: :v3_core)

      assert {:error, %{status: 400}} = Local.create_database(conn, "bad", retention: "zz")
      assert {:ok, [%{"name" => "_internal"}]} === Local.list_databases(conn)
    end

    test "an expired point that is rewritten stays hidden and a live one is merged" do
      {:ok, conn} = Local.start(profile: :v3_core)
      :ok = Local.create_database(conn, "r", retention: "1h")
      now = System.os_time(:nanosecond)
      old = now - 3 * 3_600_000_000_000

      for line <- ["m v=1i #{old}", "m,host=a v=2i #{now}", "m,host=a w=3i #{now}"] do
        assert {:ok, :written} === Local.write(conn, line, database: "r")
      end

      assert {:ok, [%{"v" => 2, "w" => 3}]} ===
               Local.query_sql(conn, "SELECT v, w FROM m", database: "r")
    end
  end
end
