defmodule InfluxElixir.Client.HTTPTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client
  alias InfluxElixir.Client.HTTP

  setup_all do
    Code.ensure_loaded!(HTTP)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Behaviour contract
  # ---------------------------------------------------------------------------

  describe "behaviour implementation" do
    test "HTTP module declares the InfluxElixir.Client behaviour" do
      behaviours =
        HTTP.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Client in behaviours
    end

    test "all Client behaviour callbacks are implemented" do
      required_callbacks = Client.behaviour_info(:callbacks)
      exported = HTTP.__info__(:functions)

      missing =
        Enum.reject(required_callbacks, fn {name, arity} ->
          Keyword.get_values(exported, name) |> Enum.member?(arity)
        end)

      assert missing == [],
             "HTTP is missing these Client callbacks: #{inspect(missing)}"
    end
  end

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
  # Integration — requires a live InfluxDB v3 instance
  #
  # Set the following environment variables to run these tests:
  #   INFLUX_HOST      — hostname or IP (e.g. "localhost")
  #   INFLUX_TOKEN     — authentication token
  #   INFLUX_DATABASE  — target database name
  # ---------------------------------------------------------------------------

  defp integration_conn do
    host = System.get_env("INFLUX_HOST")
    token = System.get_env("INFLUX_TOKEN")
    database = System.get_env("INFLUX_DATABASE")

    if is_nil(host) or is_nil(token) or is_nil(database) do
      nil
    else
      _finch =
        start_supervised!({Finch, name: :http_test_finch, pools: %{default: [size: 1]}})

      [
        host: host,
        token: token,
        database: database,
        scheme: :http,
        port: 8086,
        finch_name: :http_test_finch
      ]
    end
  end

  describe "write/3 — integration" do
    @tag :integration
    test "returns a tagged tuple for a valid write" do
      conn = integration_conn()

      if is_nil(conn) do
        :ok
      else
        lp = "http_test,source=exunit value=1.0"
        result = HTTP.write(conn, lp, database: conn[:database])
        assert match?({:ok, :written}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "health/1 — integration" do
    @tag :integration
    test "returns a tagged tuple from the health endpoint" do
      conn = integration_conn()

      if is_nil(conn) do
        :ok
      else
        result = HTTP.health(conn)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "list_databases/1 — integration" do
    @tag :integration
    test "returns a tagged tuple from the databases endpoint" do
      conn = integration_conn()

      if is_nil(conn) do
        :ok
      else
        result = HTTP.list_databases(conn)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "query_sql/3 — integration" do
    @tag :integration
    test "returns a tagged tuple for a SQL query" do
      conn = integration_conn()

      if is_nil(conn) do
        :ok
      else
        result = HTTP.query_sql(conn, "SELECT 1", database: conn[:database])
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end
end
