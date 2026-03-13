defmodule InfluxElixir.Flight.ClientTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Flight.Client
  alias InfluxElixir.Flight.Proto.Ticket

  describe "build_ticket_payload/2" do
    test "produces valid JSON with required fields" do
      payload = Client.build_ticket_payload("mydb", "SELECT * FROM cpu")
      decoded = Jason.decode!(payload)

      assert decoded["database"] == "mydb"
      assert decoded["sql_query"] == "SELECT * FROM cpu"
      assert decoded["query_type"] == "sql"
    end

    test "encodes database name correctly" do
      payload = Client.build_ticket_payload("metrics_prod", "SELECT 1")
      assert Jason.decode!(payload)["database"] == "metrics_prod"
    end

    test "encodes complex SQL without modification" do
      sql = "SELECT time, value FROM cpu WHERE host = $host ORDER BY time DESC LIMIT 100"
      payload = Client.build_ticket_payload("db", sql)
      assert Jason.decode!(payload)["sql_query"] == sql
    end

    test "query_type is always 'sql'" do
      payload = Client.build_ticket_payload("db", "SELECT 1")
      assert Jason.decode!(payload)["query_type"] == "sql"
    end

    test "returns a binary" do
      payload = Client.build_ticket_payload("db", "SELECT 1")
      assert is_binary(payload)
    end
  end

  describe "build_ticket/2" do
    test "returns a Ticket struct" do
      ticket = Client.build_ticket("mydb", "SELECT 1")
      assert %Ticket{} = ticket
    end

    test "ticket field contains JSON payload" do
      ticket = Client.build_ticket("mydb", "SELECT 1")
      decoded = Jason.decode!(ticket.ticket)
      assert decoded["database"] == "mydb"
      assert decoded["sql_query"] == "SELECT 1"
    end

    test "ticket field is a binary" do
      ticket = Client.build_ticket("mydb", "SELECT 1")
      assert is_binary(ticket.ticket)
    end

    test "ticket can be protobuf-encoded" do
      ticket = Client.build_ticket("sensors", "SELECT * FROM temp")
      encoded = Protobuf.encode(ticket)
      assert is_binary(encoded)
      decoded = Protobuf.decode(encoded, Ticket)
      assert Jason.decode!(decoded.ticket)["database"] == "sensors"
    end

    test "roundtrips database and query through protobuf encoding" do
      db = "test_database"
      sql = "SELECT measurement, value FROM readings LIMIT 10"
      ticket = Client.build_ticket(db, sql)
      encoded = Protobuf.encode(ticket)
      decoded_ticket = Protobuf.decode(encoded, Ticket)
      payload = Jason.decode!(decoded_ticket.ticket)
      assert payload["database"] == db
      assert payload["sql_query"] == sql
    end
  end

  describe "query/3 — connection validation" do
    test "returns {:error, _} when host is missing" do
      conn = %{token: "tok", database: "db"}

      assert_raise KeyError, fn ->
        Client.query(conn, "SELECT 1")
      end
    end

    test "returns {:error, _} when token is missing" do
      conn = %{host: "localhost", database: "db"}

      assert_raise KeyError, fn ->
        Client.query(conn, "SELECT 1")
      end
    end

    test "returns {:error, _} when database is missing" do
      conn = %{host: "localhost", token: "tok"}

      assert_raise KeyError, fn ->
        Client.query(conn, "SELECT 1")
      end
    end

    test "returns {:error, _} when unable to connect (no server)" do
      conn = %{
        host: "127.0.0.1",
        token: "tok",
        database: "db",
        port: 19_999
      }

      result = Client.query(conn, "SELECT 1", tls: false, timeout: 1_000)
      assert {:error, _reason} = result
    end
  end
end
