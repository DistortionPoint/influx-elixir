defmodule InfluxElixir.Client.HTTPRobustnessTest do
  # What the HTTP client does with a connection or a parameter that is not usable: an error
  # tuple that names it, never a raise out of Finch or Jason
  # (docs/design/2026-10-10_review-of-71e2b8c.md).
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.TokenRequest
  alias InfluxElixir.Client.{HTTP, Local}
  alias InfluxElixir.Client.HTTP.Request
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
      {:ok, local} = Local.start(databases: ["db"])

      for {label, value} <- @bad_params do
        assert Local.query_sql(local, "SELECT $a", params: %{"a" => value}) ===
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

      assert served(delete, [{200, ~s|{"buckets":[]}|}]) ===
               {{:error, %{status: 404, body: "bucket not found: gone"}},
                [{:GET, "/api/v2/buckets?name=gone&org=o", ""}]}

      org_404 = ~s|{"code":"not found","message":"organization name \\"o\\" not found"}|

      assert served(delete, [{404, org_404}]) ===
               {{:error, %{status: 404, body: org_404}},
                [{:GET, "/api/v2/buckets?name=gone&org=o", ""}]}
    end

    test "create_bucket treats 422 already exists as :ok and passes other 422s through",
         %{conn: conn} do
      create = fn -> HTTP.create_bucket(conn, "b", org_id: "0123456789abcdef") end
      body = ~s|{"name":"b","orgID":"0123456789abcdef","retentionRules":[{"everySeconds":0}]}|

      assert served(create, [{422, ~s|{"message":"bucket with name b already exists"}|}]) ===
               {:ok, [{:POST, "/api/v2/buckets", body}]}

      other_422 = ~s|{"message":"retention rule invalid"}|

      assert served(create, [{422, other_422}]) ===
               {{:error, %{status: 422, body: other_422}}, [{:POST, "/api/v2/buckets", body}]}
    end

    test "list_buckets paginates 100-item pages and omits org when empty or nil",
         %{conn: conn} do
      page_1 = Enum.map(1..100, &%{"name" => "b#{&1}"})
      page_2 = [%{"name" => "b101"}]
      expected = page_1 ++ page_2

      assert served(
               fn -> HTTP.list_buckets(conn) end,
               [
                 {200, Jason.encode!(%{"buckets" => page_1})},
                 {200, Jason.encode!(%{"buckets" => page_2})}
               ]
             ) ===
               {{:ok, expected},
                [
                  {:GET, "/api/v2/buckets?limit=100&offset=0&org=o", ""},
                  {:GET, "/api/v2/buckets?limit=100&offset=100&org=o", ""}
                ]}

      for empty_org <- ["", nil] do
        conn_no_org = Keyword.put(conn, :org, empty_org)

        assert served(
                 fn -> HTTP.list_buckets(conn_no_org) end,
                 [{200, ~s|{"buckets":[{"name":"b1"}]}|}]
               ) ===
                 {{:ok, [%{"name" => "b1"}]}, [{:GET, "/api/v2/buckets?limit=100&offset=0", ""}]}
      end
    end

    test "write, admin, and query endpoints format flags, precisions, and bodies accurately",
         %{conn: conn} do
      v3_conn = Keyword.put(conn, :api_version, :v3)

      assert HTTP.shutdown_connection(v3_conn) === :ok
      assert HTTP.write(v3_conn, :not_iodata) === {:error, {:invalid_body, :not_iodata}}

      assert served(
               fn ->
                 HTTP.write(v3_conn, "m v=1i",
                   accept_partial: false,
                   no_sync: true,
                   gzip: true
                 )
               end,
               [{204, ""}]
             ) ===
               {{:ok, :written},
                [
                  {:POST,
                   "/api/v3/write_lp?db=db&precision=nanosecond&accept_partial=false&no_sync=true",
                   "m v=1i"}
                ]}

      for {input, wire} <- [
            {:microsecond, "us"},
            {:millisecond, "ms"},
            {:second, "s"},
            {"custom", "custom"}
          ] do
        assert served(
                 fn -> HTTP.write(conn, "m v=1i", precision: input) end,
                 [{204, ""}]
               ) ===
                 {{:ok, :written},
                  [{:POST, "/api/v2/write?org=o&bucket=db&precision=#{wire}", "m v=1i"}]}
      end

      assert served(
               fn -> HTTP.create_database(v3_conn, "db", retention: "7d") end,
               [{201, ""}]
             ) ===
               {:ok,
                [{:POST, "/api/v3/configure/database", ~s|{"db":"db","retention_period":"7d"}|}]}

      assert served(fn -> HTTP.delete_database(v3_conn, "db") end, [{204, ""}]) ===
               {:ok, [{:DELETE, "/api/v3/configure/database?db=db", ""}]}

      assert served(fn -> HTTP.create_token(v3_conn, "tok") end, [{201, ~s|{"token":"t1"}|}]) ===
               {{:ok, %{"token" => "t1"}},
                [
                  {:POST, "/api/v3/configure/token/named_admin",
                   ~s|{"token_name":"tok","expiry_secs":null}|}
                ]}

      assert served(fn -> HTTP.delete_token(v3_conn, "tok") end, [{204, ""}]) ===
               {:ok, [{:DELETE, "/api/v3/configure/token?token_name=tok", ""}]}

      no_db_conn = Keyword.delete(v3_conn, :database)

      assert served(
               fn -> HTTP.query_influxql(no_db_conn, "SHOW DATABASES") end,
               [{200, "[]"}]
             ) ===
               {{:ok, []},
                [{:POST, "/api/v3/query_influxql", ~s|{"format":"json","q":"SHOW DATABASES"}|}]}

      flux_csv = "#datatype,string,long,double\r\n,result,table,_value\r\n,_result,0,2.5\r\n\r\n"

      assert served(
               fn -> HTTP.query_flux(conn, ~s[from(bucket: "b")]) end,
               [{200, flux_csv}]
             ) ===
               {{:ok, [%{"result" => "_result", "table" => 0, "_value" => 2.5}]},
                [
                  {:POST, "/api/v2/query?org=o",
                   ~s|{"dialect":{"annotations":["datatype"],"delimiter":",","header":true},"query":"from(bucket: \\"b\\")","type":"flux"}|}
                ]}
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

      assert answered(buckets, 200, ~s({"buckets":["not_a_map"]})) ===
               {:error, {:unexpected_response, %{"buckets" => ["not_a_map"]}}}

      assert answered(buckets, 200, ~s({"buckets":[{"id":"b1","name":"n1"}]})) ===
               {:ok, [%{"id" => "b1", "name" => "n1"}]}

      create_tok = fn -> HTTP.create_token(conn, "tok") end

      assert answered(create_tok, 200, ~s(["not_an_object"])) ===
               {:error, {:unexpected_response, ["not_an_object"]}}

      assert answered(create_tok, 200, ~s({"id":1,"name":"tok"})) ===
               {:ok, %{"id" => 1, "name" => "tok"}}

      create_bkt = fn -> HTTP.create_bucket(conn ++ [api_version: :v2, org: "o"], "b") end

      assert answered(create_bkt, 200, ~s({"orgs":[{"id":null}]})) ===
               {:error, {:org_not_found, "o"}}

      assert answered(create_bkt, 200, ~s({"orgs":[{"id":""}]})) ===
               {:error, {:org_not_found, "o"}}

      delete_bkt = fn -> HTTP.delete_bucket(conn ++ [api_version: :v2, org: "o"], "b") end

      assert answered(delete_bkt, 200, ~s({"buckets":[{"id":null}]})) ===
               {:error, %{status: 404, body: "bucket not found: b"}}

      assert answered(delete_bkt, 200, ~s({"buckets":[{"id":""}]})) ===
               {:error, %{status: 404, body: "bucket not found: b"}}
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

    test "a stream handles trailing non-newline JSONL, non-200 error bodies, and malformed JSONL",
         %{conn: conn} do
      stream_list = fn ->
        conn |> HTTP.query_sql_stream("SELECT v FROM m") |> Enum.to_list()
      end

      assert answered(stream_list, 200, ~s({"v":1})) === [%{"v" => 1}]

      assert %StreamError{kind: :http_status, status: 400, body: "bad sql"} =
               answered(fn -> catch_error(stream_list.()) end, 400, "bad sql")

      assert %StreamError{kind: :decode, reason: {:unexpected_json, 123}} =
               answered(fn -> catch_error(stream_list.()) end, 200, "123\n")

      assert %StreamError{kind: :decode, reason: %Jason.DecodeError{}} =
               answered(fn -> catch_error(stream_list.()) end, 200, "not json\n")
    end
  end

  describe "a connection that is not a keyword list" do
    test "every Client.HTTP callback returns {:invalid_connection, conn}, never a raise" do
      for conn <- [
            %{table: :local},
            "localhost",
            123,
            ~c"localhost",
            [:a | :b],
            [api_version: :v4],
            [host: %{}],
            [port: {1}],
            [scheme: [1]],
            [token: %{}],
            [timeout: false],
            [timeout: -1],
            [pool_timeout: false],
            [pool_timeout: -1]
          ] do
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

        conn_with_port = Keyword.put(conn, :flight_port, bad_port)

        assert HTTP.query_sql(conn_with_port, "SELECT 1", transport: :flight) ===
                 {:error, {:invalid_port, bad_port}}
      end

      assert HTTP.query_sql(conn, "SELECT 1", transport: :bogus) ===
               {:error, {:unknown_transport, :bogus}}

      assert HTTP.query_sql(conn, "SELECT $a", transport: :flight, params: %{"a" => 1}) ===
               {:error, :params_unsupported_over_flight}

      assert HTTP.query_sql(conn, "SELECT $a", transport: :flight, params: %{"a" => self()}) ===
               {:error, {:invalid_param, "a", :unsupported_type}}

      for bad_opt <- [
            [timeout: false],
            [timeout: -1],
            [timeout: "30s"],
            [pool_timeout: false],
            [pool_timeout: -1],
            [connect_timeout: false],
            [connect_timeout: -1],
            [tls: "false"]
          ] do
        assert HTTP.query_sql(conn, "SELECT 1", bad_opt) ===
                 {:error, {:invalid_options, bad_opt}}
      end

      assert TokenRequest.build("tok", :bad) ===
               {:error, {:invalid_options, :bad}}

      assert Request.resolve_timeout([timeout: :infinity], []) === :infinity
      assert Request.resolve_pool_timeout([pool_timeout: :infinity], []) === :infinity

      assert Request.auth_headers(token: nil) === []
      assert Request.auth_headers(token: "") === []

      other_err = %RuntimeError{message: "other"}
      assert Request.classify_finch_error(other_err) === other_err

      assert {:error, {:json_parse_error, %Jason.DecodeError{}}} =
               Request.decode_json("not json")

      for bad_frag <- [%Jason.Fragment{encode: 123}, Jason.Fragment.new([1 | 2])] do
        assert {:error, {:unencodable_body, msg}} = Request.json_body(%{"a" => bad_frag})
        assert is_binary(msg)
      end
    end
  end
end
