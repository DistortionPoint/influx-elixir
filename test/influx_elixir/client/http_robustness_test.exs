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

      assert %StreamError{kind: :invalid_request, reason: :no_pool_name} =
               catch_error(Enum.to_list(stream))
    end

    test "a boolean or non-atom :finch_name or :name is also :no_pool_name" do
      for bad <- [false, true, "pool", 123] do
        assert HTTP.query_sql(connection(finch_name: bad), "SELECT 1") === @no_pool_name
        assert HTTP.query_sql(connection(name: bad), "SELECT 1") === @no_pool_name
      end
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

    test "a format Jason cannot encode is an unencodable_body error, never a raise" do
      conn = connection(finch_name: absent_pool())

      for bad_format <- [<<0xFF>>, {1}, self(), [1 | 2]] do
        assert {:error, {:unencodable_body, _reason}} =
                 HTTP.query_sql(conn, "SELECT 1", format: bad_format)

        assert {:error, {:unencodable_body, _reason}} =
                 HTTP.query_influxql(conn, "SELECT 1", format: bad_format)
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

  # The server sees each request's method and path, and the test answers them in turn.
  describe "v2 buckets" do
    setup do
      finch = :"fxi30_http_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})
      port = TestServer.controlled(request_line: true)
      {:ok, conn: connection(port: port, finch_name: finch, api_version: :v2, org: "o")}
    end

    # Runs `fun`, answering its requests with `answers` in order; returns its result and
    # the requests it made.
    defp served(fun, answers) do
      task = Task.async(fun)

      requests =
        for {status, body} <- answers do
          assert_receive {:request, handler, request}, TestSupport.Await.bound()
          TestServer.respond(handler, status, body)
          request
        end

      {Task.await(task, TestSupport.Await.bound()), requests}
    end

    # The empty org name lists every org the token can read, so its first org was
    # a guess; InfluxDB 2 refuses a bucket without one (verified).
    test "create_bucket without an org sends no orgID and answers the server's 400",
         %{conn: conn} do
      refusal = ~s|{"code":"invalid","message":"organization id must be provided"}|
      body = ~s|{"name":"b","retentionRules":[{"everySeconds":0}]}|

      for org <- ["", nil] do
        create = fn -> HTTP.create_bucket(Keyword.put(conn, :org, org), "b") end

        assert served(create, [{400, refusal}]) ===
                 {{:error, %{status: 400, body: refusal}}, [{:POST, "/api/v2/buckets", body}]}
      end
    end

    test "create_bucket looks up the connection's org by name and sends its ID", %{conn: conn} do
      create = fn -> HTTP.create_bucket(conn, "b") end
      body = ~s|{"name":"b","orgID":"0123456789abcdef","retentionRules":[{"everySeconds":0}]}|

      assert served(create, [{200, ~s|{"orgs":[{"id":"0123456789abcdef"}]}|}, {201, "{}"}]) ===
               {:ok, [{:GET, "/api/v2/orgs?org=o", ""}, {:POST, "/api/v2/buckets", body}]}

      assert served(create, [{200, ~s|{"orgs":[]}|}]) ===
               {{:error, {:org_not_found, "o"}}, [{:GET, "/api/v2/orgs?org=o", ""}]}
    end

    test "create_bucket with :org_id sends it and looks up no org", %{conn: conn} do
      body = ~s|{"name":"b","orgID":"0123456789abcdef","retentionRules":[{"everySeconds":0}]}|
      create = fn -> HTTP.create_bucket(conn, "b", org_id: "0123456789abcdef") end

      assert served(create, [{201, "{}"}]) === {:ok, [{:POST, "/api/v2/buckets", body}]}
    end

    # A name of 16 hex digits was taken for an ID, so the bucket was never found.
    test "delete_bucket of 16 hex digits deletes the bucket of that name", %{conn: conn} do
      delete = fn -> HTTP.delete_bucket(conn, "deadbeefdeadbeef") end
      found = ~s|{"buckets":[{"id":"0123456789abcdef","name":"deadbeefdeadbeef"}]}|

      assert served(delete, [{200, found}, {204, ""}]) ===
               {:ok,
                [
                  {:GET, "/api/v2/buckets?name=deadbeefdeadbeef&org=o", ""},
                  {:DELETE, "/api/v2/buckets/0123456789abcdef", ""}
                ]}
    end

    test "delete_bucket of 16 hex digits no bucket is named deletes that ID", %{conn: conn} do
      delete = fn -> HTTP.delete_bucket(conn, "deadbeefdeadbeef") end
      not_found = ~s|{"code":"not found","message":"bucket \\"deadbeefdeadbeef\\" not found"}|

      assert served(delete, [{404, not_found}, {204, ""}]) ===
               {:ok,
                [
                  {:GET, "/api/v2/buckets?name=deadbeefdeadbeef&org=o", ""},
                  {:DELETE, "/api/v2/buckets/deadbeefdeadbeef", ""}
                ]}
    end

    test "delete_bucket of any other name no bucket has is not found, and deletes nothing",
         %{conn: conn} do
      delete = fn -> HTTP.delete_bucket(conn, "gone") end
      not_found = ~s|{"code":"not found","message":"bucket \\"gone\\" not found"}|

      assert served(delete, [{404, not_found}]) ===
               {{:error, %{status: 404, body: "bucket not found: gone"}},
                [{:GET, "/api/v2/buckets?name=gone&org=o", ""}]}
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

    test "format: false and database: false are sent as given, not replaced by defaults",
         %{conn: conn} do
      sql_body =
        request_body(fn ->
          HTTP.query_sql(conn, "SELECT 1", database: false, format: false)
        end)

      assert sql_body === %{
               "db" => false,
               "format" => "false",
               "params" => %{},
               "q" => "SELECT 1"
             }

      iql_body =
        request_body(fn ->
          HTTP.query_influxql(conn, "SELECT 1", database: false, format: false)
        end)

      assert iql_body === %{"db" => false, "format" => "false", "q" => "SELECT 1"}
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

    test "a stream stopped after its first row leaves nothing in the enumerating process",
         %{conn: conn} do
      take_one = fn ->
        rows = conn |> HTTP.query_sql_stream("SELECT v FROM m") |> Enum.take(1)
        {rows, Process.info(self(), :messages)}
      end

      chunks = [~s({"v":1}\n), ~s({"v":2}\n), ~s({"v":3}\n)]

      assert answered(take_one, 200, {:chunks, chunks}) === {[%{"v" => 1}], {:messages, []}}
    end
  end

  describe "a connection that is not a keyword list" do
    test "every Client.HTTP callback returns {:invalid_connection, conn}, never a raise" do
      for conn <- [%{table: :local}, "localhost", 123, ~c"localhost", [:a | :b]] do
        expected = {:error, {:invalid_connection, conn}}

        assert HTTP.init_connection(conn) === expected
        assert HTTP.write(conn, "m v=1i") === expected
        assert HTTP.query_sql(conn, "SELECT 1") === expected
        assert HTTP.execute_sql(conn, "SELECT 1") === expected
        assert HTTP.query_influxql(conn, "SELECT 1") === expected
        assert HTTP.query_flux(conn, ~s[from(bucket: "b")]) === expected
        assert HTTP.create_database(conn, "db") === expected
        assert HTTP.list_databases(conn) === expected
        assert HTTP.delete_database(conn, "db") === expected
        assert HTTP.create_bucket(conn, "b") === expected
        assert HTTP.list_buckets(conn) === expected
        assert HTTP.delete_bucket(conn, "b") === expected
        assert HTTP.create_token(conn, "tok") === expected
        assert HTTP.delete_token(conn, "tok") === expected
        assert HTTP.health(conn) === expected

        stream = HTTP.query_sql_stream(conn, "SELECT 1")

        assert %StreamError{kind: :invalid_request, reason: {:invalid_connection, ^conn}} =
                 catch_error(Enum.to_list(stream))
      end
    end

    test "create_token with an improper list or non-string map key in expiry_secs returns unencodable_body" do
      conn = connection(finch_name: absent_pool())

      for bad <- [[1 | 2], %{{1, 2} => 3}] do
        assert {:error, {:unencodable_body, msg}} =
                 HTTP.create_token(conn, "tok", expiry_secs: bad)

        assert is_binary(msg)
      end
    end

    test "query_sql over flight rejects non-integer or out-of-range flight_port including false" do
      conn = connection(finch_name: absent_pool())

      for bad_port <- [false, 0, -1, 65_536, "8181"] do
        assert HTTP.query_sql(conn, "SELECT 1", transport: :flight, flight_port: bad_port) ===
                 {:error, {:invalid_port, bad_port}}
      end
    end
  end
end
