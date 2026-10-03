defmodule InfluxElixir.Client.Local.SqlQueryMechanicsTest do
  @moduledoc """
  What `Client.Local` does with `query_sql` that is the double's own: how it
  binds parameters, the formats it refuses, the WHERE clauses it cannot judge.
  What the engine answers to a query (filters, ordering, grouping, IN lists,
  time conditions, quoted literals, placeholders left unbound) is pinned for the
  double and for the real servers by the SQL contracts in `test/support`.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    {:ok, conn: conn}
  end

  # The time every row written with `@ts` reads back as.
  @ts 1_700_000_000_000_000_000
  @time ~U[2023-11-14 22:13:20.000000Z]

  describe "Client.Local: query_sql/3 given a statement that is not a query" do
    test "answers as execute_sql does", %{conn: conn} do
      assert {:error,
              %{status: 400, body: "Error during planning: DML not supported: Insert Into"}} =
               Local.query_sql(conn, "INSERT INTO cpu VALUES (1)", database: "test_db")
    end
  end

  describe "Client.Local: parameter substitution" do
    setup %{conn: conn} do
      {:ok, :written} =
        Local.write(conn, "cpu,host=web01 usage=10i\ncpu,host=web02 usage=20i",
          database: "test_db"
        )

      :ok
    end

    test "a placeholder that prefixes another is substituted whole", %{conn: conn} do
      # Sequential replacement rewrote `$h` inside `$hmin`, producing
      # `'web02'min` and a parse failure.
      sql = "SELECT * FROM cpu WHERE host = $h AND usage > $hmin"
      assert param_rows(conn, sql, %{h: "web02", hmin: 15}) === [{"web02", 20}]
    end

    test "a substituted value is never re-substituted", %{conn: conn} do
      # A string value containing another placeholder's name must stay literal:
      # were `$min` substituted again, the query would select host "15".
      {:ok, :written} =
        Local.write(conn, "sub,host=$min usage=20i 1\nsub,host=15 usage=30i 2",
          database: "test_db"
        )

      sql = "SELECT * FROM sub WHERE host = $host AND usage > $min"

      assert param_rows(conn, sql, %{host: "$min", min: 15}) === [{"$min", 20}]
    end
  end

  describe "Client.Local: boolean and nil parameters" do
    setup %{conn: conn} do
      {:ok, :written} =
        Local.write(
          conn,
          "devices,id=d1 active=true #{@ts}\ndevices,id=d2 active=false #{@ts}",
          database: "test_db"
        )

      :ok
    end

    test "boolean params select by the flag", %{conn: conn} do
      for {flag, id} <- [{true, "d1"}, {false, "d2"}] do
        assert Local.query_sql(conn, "SELECT * FROM devices WHERE active = $flag",
                 database: "test_db",
                 params: %{"flag" => flag}
               ) === {:ok, [%{"id" => id, "active" => flag, "time" => @time}]}
      end
    end

    test "a nil param renders as NULL, which never matches", %{conn: conn} do
      # Jason sends nil as JSON null and `id = NULL` is never true on the
      # engine; the double renders NULL and matches nothing either.
      assert {:ok, []} =
               Local.query_sql(conn, "SELECT * FROM devices WHERE id = $val",
                 database: "test_db",
                 params: %{"val" => nil}
               )
    end
  end

  describe "Client.Local: formats it does not produce" do
    test "format: :parquet is refused by name, over SQL and InfluxQL", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "m v=1i", database: "test_db")

      for query <- [&Local.query_sql/3, &Local.query_influxql/3] do
        assert {:error,
                %{
                  status: 400,
                  body:
                    "Client.Local: format: :parquet is not supported by the test double; " <>
                      "cover Parquet in the integration tier"
                }} = query.(conn, "SELECT v FROM m", database: "test_db", format: :parquet)
      end
    end
  end

  describe "Client.Local: query_sql_stream/3 on a profile without streaming" do
    test "raises StreamError with :unsupported on enumeration" do
      {:ok, v2_conn} = Local.start(profile: :v2, databases: ["v2_db"])

      stream = Local.query_sql_stream(v2_conn, "SELECT * FROM cpu")

      error = assert_raise InfluxElixir.StreamError, fn -> Enum.to_list(stream) end
      assert %InfluxElixir.StreamError{kind: :unsupported, reason: :unsupported_operation} = error
    end
  end

  describe "Client.Local: a WHERE clause it cannot judge" do
    # The fix list says clauses the parser cannot recognise must not produce wrong
    # rows. They are an explicit error, so that a future "LIKE 'foo%'" clause
    # cannot silently match everything.
    setup %{conn: conn} do
      {:ok, :written} =
        Local.write(
          conn,
          "alerts,severity=high msg=\"fire\" 1000000000\n" <>
            "alerts,severity=low msg=\"info\" 2000000000",
          database: "test_db"
        )

      :ok
    end

    test "is an error rather than dropped rows", %{conn: conn} do
      assert {:error,
              %{
                status: 400,
                body: "Client.Local: unsupported WHERE clause: severity similar to 'h%'"
              }} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM alerts WHERE severity SIMILAR TO 'h%'",
                 database: "test_db"
               )
    end
  end

  # The sorted `{host, usage}` pairs a parameterised query selects.
  defp param_rows(conn, sql, params) do
    {:ok, rows} = Local.query_sql(conn, sql, params: params, database: "test_db")
    rows |> Enum.map(&{&1["host"], &1["usage"]}) |> Enum.sort()
  end
end
