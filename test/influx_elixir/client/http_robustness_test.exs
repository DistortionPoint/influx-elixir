defmodule InfluxElixir.Client.HTTPRobustnessTest do
  # What the HTTP client does with a connection or a parameter that is not usable: an error
  # tuple that names it, never a raise out of Finch or Jason
  # (docs/design/2026-10-10_review-of-71e2b8c.md).
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.{StreamError, TestServer, TestSupport}

  defp connection(extra) do
    [host: "127.0.0.1", port: 1, scheme: :http, token: "t", database: "db"]
    |> Keyword.merge(extra)
  end

  @no_pool {:error, {:connection_error, :no_pool}}
  @no_pool_name {:error, {:connection_error, :no_pool_name}}

  defp absent_pool, do: :"fxi30_no_pool_#{System.unique_integer([:positive])}"

  describe "a connection whose Finch pool is not running" do
    test "every request function answers a named error" do
      conn = connection(finch_name: absent_pool(), org: "o")

      assert HTTP.query_sql(conn, "SELECT 1") === @no_pool
      assert HTTP.execute_sql(conn, "SELECT 1") === @no_pool
      assert HTTP.query_influxql(conn, "SELECT 1") === @no_pool
      assert HTTP.write(conn, "m f=1i") === @no_pool
      assert HTTP.health(conn) === @no_pool
    end

    test "a connection named for the supervisor's pool, started or not, is the same error" do
      conn = connection(name: absent_pool())
      assert HTTP.query_sql(conn, "SELECT 1") === @no_pool
    end

    test "a streaming query raises the StreamError when it is enumerated, not when built" do
      stream = HTTP.query_sql_stream(connection(finch_name: absent_pool()), "SELECT 1")

      assert %StreamError{kind: :transport, reason: :no_pool} =
               catch_error(Enum.to_list(stream))
    end
  end

  describe "a keyword connection with neither :finch_name nor :name" do
    test "every request function answers a named error" do
      conn = connection(org: "o")

      assert HTTP.query_sql(conn, "SELECT 1") === @no_pool_name
      assert HTTP.execute_sql(conn, "SELECT 1") === @no_pool_name
      assert HTTP.query_influxql(conn, "SELECT 1") === @no_pool_name
      assert HTTP.write(conn, "m f=1i") === @no_pool_name
    end

    test "a streaming query raises the StreamError when it is enumerated" do
      stream = HTTP.query_sql_stream(connection([]), "SELECT 1")

      assert %StreamError{kind: :transport, reason: :no_pool_name} =
               catch_error(Enum.to_list(stream))
    end
  end

  describe "query parameters Jason cannot write" do
    @bad_params [
      {"an improper list", [1 | 2]},
      {"a map with a tuple key", %{{1, 2} => 1}},
      {"a list holding one", [%{{1, 2} => 1}]},
      {"a pid", self()}
    ]

    test "are an invalid_param naming the parameter, before any request" do
      conn = connection(finch_name: absent_pool())

      for {label, value} <- @bad_params do
        assert HTTP.query_sql(conn, "SELECT $a", params: %{"a" => value}) ===
                 {:error, {:invalid_param, "a", :unsupported_type}},
               label

        assert HTTP.query_sql(conn, "SELECT $a", params: [a: value]) ===
                 {:error, {:invalid_param, "a", :unsupported_type}},
               label
      end
    end

    test "Client.Local answers the same" do
      {:ok, local} = InfluxElixir.Client.Local.start(databases: ["db"])

      for {label, value} <- @bad_params do
        assert InfluxElixir.Client.Local.query_sql(local, "SELECT $a", params: %{"a" => value}) ===
                 {:error, {:invalid_param, "a", :unsupported_type}},
               label
      end
    end
  end

  describe "the facade with a connection that is not one" do
    test "a host name or a number is an invalid_connection, not a raise from the span" do
      for connection <- ["hostname", 42, [1, 2], {:host, "h"}] do
        assert InfluxElixir.query_sql(connection, "SELECT 1") ===
                 {:error, {:invalid_connection, connection}}

        assert InfluxElixir.query_influxql(connection, "SELECT 1") ===
                 {:error, {:invalid_connection, connection}}

        assert InfluxElixir.execute_sql(connection, "SELECT 1") ===
                 {:error, {:invalid_connection, connection}}
      end
    end
  end

  # A server the test answers sees the request body the client wrote.
  describe "format: nil is the format left out, on both query languages" do
    setup do
      finch = :"fxi30_http_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})
      {:ok, conn: connection(port: TestServer.controlled(), finch_name: finch)}
    end

    defp request_body(fun) do
      task = Task.async(fun)
      assert_receive {:request, handler, body}, TestSupport.Await.bound()
      TestServer.respond(handler, 200)
      Task.await(task, TestSupport.Await.bound())
      Jason.decode!(body)
    end

    test "InfluxQL sends the default format, not an empty one", %{conn: conn} do
      body = request_body(fn -> HTTP.query_influxql(conn, "SELECT 1", format: nil) end)
      assert body === %{"db" => "db", "format" => "json", "q" => "SELECT 1"}
    end

    test "an InfluxQL call without the option sends the same", %{conn: conn} do
      body = request_body(fn -> HTTP.query_influxql(conn, "SELECT 1") end)
      assert body === %{"db" => "db", "format" => "json", "q" => "SELECT 1"}
    end

    test "SQL sends the default format too", %{conn: conn} do
      body = request_body(fn -> HTTP.query_sql(conn, "SELECT 1", format: nil) end)
      assert body === %{"db" => "db", "format" => "json", "params" => %{}, "q" => "SELECT 1"}
    end
  end

  # What the client makes of an answer's body, sent as the test decides.
  describe "a body the server sends" do
    setup do
      finch = :"fxi30_http_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})
      {:ok, conn: connection(port: TestServer.controlled(), finch_name: finch)}
    end

    defp answered(fun, status, body) do
      task = Task.async(fun)
      assert_receive {:request, handler, _request_body}, TestSupport.Await.bound()
      TestServer.respond(handler, status, body)
      Task.await(task, TestSupport.Await.bound())
    end

    test "a health body that is JSON but no object is a passing check, as plain text is",
         %{conn: conn} do
      # It was returned as it decoded (`{:ok, true}`), where the spec promises a map.
      for body <- ["true", ~s("OK"), "[]", "1", "OK"] do
        assert answered(fn -> HTTP.health(conn) end, 200, body) ===
                 {:ok, %{"status" => "pass"}},
               body
      end

      assert answered(fn -> HTTP.health(conn) end, 200, ~s({"status":"pass","version":"3"})) ===
               {:ok, %{"status" => "pass", "version" => "3"}}
    end

    # Each raised out of the client: a row that is no object, a listing that is no list.
    test "an answer of the wrong shape is an error, never a raise", %{conn: conn} do
      execute = fn -> HTTP.execute_sql(conn, "SELECT 1") end

      assert answered(execute, 200, ~s([{"a":1},2])) === {:error, {:unexpected_json, 2}}
      assert answered(execute, 200, "true") === {:error, {:unexpected_json, true}}

      assert answered(execute, 200, ~s([{"time":"2023-11-14T22:13:20"}])) ===
               {:ok, [%{"time" => ~U[2023-11-14 22:13:20.000000Z]}]}

      assert answered(execute, 200, ~s({"rows_affected":0})) === {:ok, %{"rows_affected" => 0}}

      databases = fn -> HTTP.list_databases(conn) end
      assert answered(databases, 200, ~s(["a"])) === {:error, {:unexpected_response, ["a"]}}
      assert answered(databases, 200, ~s({})) === {:error, {:unexpected_response, %{}}}

      assert answered(databases, 200, ~s([{"iox::database":"a"}])) ===
               {:ok, [%{"name" => "a"}]}

      buckets = fn -> HTTP.list_buckets(conn ++ [api_version: :v2, org: "o"]) end

      assert answered(buckets, 200, ~s({"buckets":null})) ===
               {:error, {:unexpected_response, %{"buckets" => nil}}}
    end

    test "a streamed row split over many chunks is one row, and CRLF ends a line as LF does",
         %{conn: conn} do
      # A blank CRLF line between the rows, and every chunk seven bytes long.
      body = ~s({"tag":"#{String.duplicate("x", 300)}","v":1}\r\n\r\n{"v":2}\r\n)

      chunks =
        body |> :binary.bin_to_list() |> Enum.chunk_every(7) |> Enum.map(&:binary.list_to_bin/1)

      rows =
        answered(
          fn -> conn |> HTTP.query_sql_stream("SELECT tag, v FROM m") |> Enum.to_list() end,
          200,
          {:chunks, chunks}
        )

      assert rows === [%{"tag" => String.duplicate("x", 300), "v" => 1}, %{"v" => 2}]
    end
  end
end
