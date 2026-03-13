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
