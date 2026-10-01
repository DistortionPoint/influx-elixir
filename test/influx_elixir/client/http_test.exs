defmodule InfluxElixir.Client.HTTPTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.HTTP

  # ---------------------------------------------------------------------------
  # init_connection — :database resolution parity with Client.Local
  #
  # Regression coverage for issue #2: both impls must resolve the same default
  # database for the same config so a config is a drop-in replacement.
  # ---------------------------------------------------------------------------

  describe "init_connection/1 — :database resolution" do
    test "passes :database through unchanged" do
      {:ok, conn} = HTTP.init_connection(host: "h", token: "t", database: "primary")
      assert Keyword.get(conn, :database) == "primary"
    end

    test "defaults :database to first of :databases when singular missing" do
      {:ok, conn} =
        HTTP.init_connection(host: "h", token: "t", databases: ["a", "b"])

      assert Keyword.get(conn, :database) == "a"
    end

    test "preserves :database when both keys are given" do
      {:ok, conn} =
        HTTP.init_connection(
          host: "h",
          token: "t",
          database: "primary",
          databases: ["a", "b"]
        )

      assert Keyword.get(conn, :database) == "primary"
    end

    test "leaves :database absent when neither key is given" do
      {:ok, conn} = HTTP.init_connection(host: "h", token: "t")
      assert Keyword.get(conn, :database) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_timeout/2 precedence (issue #8)
  #
  # The HTTP transport previously dropped :timeout on the floor (Finch's 15s
  # default applied unconditionally). Now opts > connection > 30s default.
  # ---------------------------------------------------------------------------

  describe "resolve_pool_timeout/2" do
    test "uses opts :pool_timeout when both opts and conn have it" do
      assert HTTP.resolve_pool_timeout([pool_timeout: 250], pool_timeout: 9_000) == 250
    end

    test "falls back to connection :pool_timeout when opts has none" do
      assert HTTP.resolve_pool_timeout([], pool_timeout: 9_000) == 9_000
    end

    test "falls back to Finch's 5s default when neither has it" do
      assert HTTP.resolve_pool_timeout([], []) == 5_000
    end

    test "is independent of :timeout" do
      assert HTTP.resolve_pool_timeout([timeout: 180_000], timeout: 180_000) == 5_000
    end
  end

  describe "resolve_timeout/2" do
    test "uses opts :timeout when both opts and conn have it" do
      assert HTTP.resolve_timeout([timeout: 5_000], timeout: 60_000) == 5_000
    end

    test "falls back to connection :timeout when opts has none" do
      assert HTTP.resolve_timeout([], timeout: 60_000) == 60_000
    end

    test "falls back to 30s default when neither has it" do
      assert HTTP.resolve_timeout([], host: "h") == 30_000
    end

    test "ignores nil :timeout in opts" do
      # Keyword.get(opts, :timeout) returns nil when absent OR when explicitly
      # set to nil; both should fall through to conn / default.
      assert HTTP.resolve_timeout([timeout: nil], timeout: 7_000) == 7_000
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql_stream/3 — error surfacing (issue #10)
  #
  # The stream must never swallow errors as "zero rows". Each error class is
  # raised as an InfluxElixir.StreamError when the stream is enumerated. These
  # tests use a real Finch pool (no mocking) — the transport case points at a
  # closed port so the failure is a genuine connection error.
  # ---------------------------------------------------------------------------

  describe "query_sql_stream/3 — error surfacing" do
    test "raises :no_database when no database can be resolved" do
      conn = [host: "h", token: "t", finch_name: :unused_finch]

      stream = HTTP.query_sql_stream(conn, "SELECT 1")

      assert_raise InfluxElixir.StreamError, fn -> Enum.to_list(stream) end

      error =
        try do
          Enum.to_list(stream)
          nil
        rescue
          e in InfluxElixir.StreamError -> e
        end

      assert error.kind == :no_database
    end

    test "raises :transport on a connection failure rather than yielding []" do
      finch = :"stream_transport_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1]}})

      # Port 1 is not listening — Finch will fail to connect.
      conn = [
        host: "127.0.0.1",
        port: 1,
        scheme: :http,
        token: "t",
        database: "test_db",
        finch_name: finch
      ]

      stream = HTTP.query_sql_stream(conn, "SELECT 1")

      error =
        try do
          Enum.to_list(stream)
          nil
        rescue
          e in InfluxElixir.StreamError -> e
        end

      assert error.kind == :transport
      refute is_nil(error.reason)
    end
  end

  # ---------------------------------------------------------------------------
  # sql_request_body/4 — the JSON a query_sql request carries
  # ---------------------------------------------------------------------------

  describe "sql_request_body/4" do
    test "sends a Decimal as a JSON number, not a string" do
      # A string would be compared as text by the engine.
      assert HTTP.sql_request_body(
               "db",
               "select 1",
               [
                 params: %{
                   p: Decimal.new("1000.00"),
                   q: Decimal.new("-1"),
                   r: Decimal.new("1.2E+4")
                 }
               ],
               :json
             ) ==
               {:ok,
                ~s|{"db":"db","format":"json","params":{"p":1000.00,"q":-1,"r":12000},"q":"select 1"}|}
    end

    test "takes a keyword list as it takes a map, and names every key as a string" do
      assert HTTP.sql_request_body("db", "select 1", [params: [b: 2, a: "x"]], :jsonl) ==
               {:ok, ~s|{"db":"db","format":"jsonl","params":{"a":"x","b":2},"q":"select 1"}|}

      assert HTTP.sql_request_body("db", "select 1", [params: %{"$a" => 1}], :json) ==
               {:ok, ~s|{"db":"db","format":"json","params":{"$a":1},"q":"select 1"}|}
    end

    test "sends the scalars as JSON, dates as ISO-8601 strings and atoms as names" do
      params = %{
        a: nil,
        b: true,
        c: 1.5,
        d: ~D[2024-01-02],
        e: ~U[2024-01-02 03:04:05.000000Z],
        f: :name
      }

      assert HTTP.sql_request_body("db", "select 1", [params: params], :json) ==
               {:ok,
                ~s|{"db":"db","format":"json","params":{"a":null,"b":true,"c":1.5,| <>
                  ~s|"d":"2024-01-02","e":"2024-01-02T03:04:05.000000Z","f":"name"},| <>
                  ~s|"q":"select 1"}|}
    end

    test "leaves params an empty object and format out when there is none" do
      assert HTTP.sql_request_body("db", "select 1", [], nil) ==
               {:ok, ~s|{"db":"db","params":{},"q":"select 1"}|}
    end

    test "refuses a Decimal that has no JSON number and a value with no JSON form" do
      for value <- ["NaN", "Infinity", "-Infinity"] do
        assert HTTP.sql_request_body("db", "select 1", [params: %{p: Decimal.new(value)}], :json) ==
                 {:error, {:invalid_param, "p", :non_finite_decimal}},
               value
      end

      assert HTTP.sql_request_body("db", "select 1", [params: %{p: {1, 2}}], :json) ==
               {:error, {:invalid_param, "p", :unsupported_type}}
    end

    test "a query with such a parameter is not sent" do
      conn = [host: "localhost", port: 1, scheme: "http", token: "t", database: "db"]
      params = [params: %{p: Decimal.new("NaN")}]

      assert HTTP.query_sql(conn, "select 1", params) ==
               {:error, {:invalid_param, "p", :non_finite_decimal}}

      assert HTTP.execute_sql(conn, "select 1", params) ==
               {:error, {:invalid_param, "p", :non_finite_decimal}}

      assert_raise InfluxElixir.StreamError, fn ->
        conn |> HTTP.query_sql_stream("select 1", params) |> Enum.to_list()
      end
    end
  end
end
