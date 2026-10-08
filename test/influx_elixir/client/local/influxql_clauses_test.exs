defmodule InfluxElixir.Client.Local.InfluxQLClausesTest do
  @moduledoc """
  The clauses after a statement's `FROM`, which the engine reads in one order and word
  position by position: whatever is written there is an answer or an error by name, and
  never an exception, in a VM that has seen no statement before it. The answers are pinned
  by the planner contract (`InfluxElixir.Contract.InfluxQLDefectCases`).
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  @clauses [
    "LIMIT",
    "OFFSET",
    "SLIMIT",
    "SOFFSET",
    "GROUP BY host",
    "ORDER BY time DESC",
    "fill(1)"
  ]
  @operands ["x", "1", "99999999999999999999", ""]

  setup do
    {:ok, conn} = Local.start(databases: ["clauses_db"])
    {:ok, :written} = Local.write(conn, "m,host=a v=1.5 1000000000", database: "clauses_db")
    {:ok, conn: conn}
  end

  defp statements do
    for first <- @clauses,
        second <- @clauses,
        first_operand <- @operands,
        second_operand <- @operands do
      "SELECT v FROM m #{first} #{first_operand} #{second} #{second_operand}"
    end
  end

  test "a statement with two clauses in any order, with any operand, is answered or refused",
       %{conn: conn} do
    for statement <- statements() do
      answer =
        try do
          Local.query_influxql(conn, statement, database: "clauses_db")
        rescue
          exception -> {:raised, Exception.message(exception)}
        catch
          kind, reason -> {kind, reason}
        end

      assert match?({:ok, rows} when is_list(rows), answer) or
               match?(
                 {:error, %{status: status, body: body}}
                 when status in [400, 405] and is_binary(body),
                 answer
               ),
             "#{statement} => #{inspect(answer)}"
    end
  end

  test "a bad SLIMIT or SOFFSET operand is the parse error of the SLIMIT clause", %{conn: conn} do
    assert {:error, %{status: 400, body: slimit}} =
             Local.query_influxql(conn, "SELECT v FROM m SLIMIT x", database: "clauses_db")

    assert slimit ===
             "error in InfluxQL statement: parsing error: " <>
               "invalid SLIMIT clause, expected unsigned integer at pos 23"

    # the engine words a bad SOFFSET operand as the SLIMIT clause's
    assert {:error, %{status: 400, body: soffset}} =
             Local.query_influxql(conn, "SELECT v FROM m SOFFSET x", database: "clauses_db")

    assert soffset ===
             "error in InfluxQL statement: parsing error: " <>
               "invalid SLIMIT clause, expected unsigned integer at pos 24"
  end

  test "clauses out of their order are left over from the first one out of its place",
       %{conn: conn} do
    assert {:error, %{status: 400, body: body}} =
             Local.query_influxql(
               conn,
               "SELECT v FROM m GROUP BY host fill(null) SLIMIT 1 LIMIT 2 OFFSET 1",
               database: "clauses_db"
             )

    assert body ===
             "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 50. " <>
               ~s|Parsing Error: Nom("LIMIT 2 OFFSET 1", Tag)|
  end

  # A text no atom exists for: the VM has not met it, and no other test can write it.
  defp unique_text, do: "zz_" <> Integer.to_string(System.unique_integer([:positive]))

  # The 500s the double gives on purpose, because the engine does (verified, and pinned in the
  # SQL contract tables): the answer for a name no table has as a field. A 500 with any other
  # body is a defect: the double ran into something it did not expect.
  @pinned_500_prefixes ["Schema error: No field named "]

  # The atoms and tuples Local documents as errors: a refusal by name (`Client.Local`,
  # `Shared.Format`, `QueryParams`), never a raw internal term.
  @documented_atoms [:no_database_specified, :unsupported_operation]
  @invalid_param_reasons [
    :non_finite_decimal,
    :unsupported_type,
    :unsupported_key,
    :unsupported_params
  ]
  @answer_statuses [400, 404, 405, 409, 422]

  defp answered?(:ok), do: true
  defp answered?({:ok, :written}), do: true
  defp answered?({:ok, rows}) when is_list(rows), do: Enum.all?(rows, &is_map/1)
  defp answered?({:ok, result}) when is_map(result), do: true
  defp answered?({:error, reason}) when reason in @documented_atoms, do: true
  defp answered?({:error, {:unsupported_format, _format}}), do: true
  # `Admin.Tokens` documents this for a permission not in `kind:name:action` form.
  defp answered?({:error, {:invalid_permission, permission}}), do: is_binary(permission)

  defp answered?({:error, {:invalid_param, name, reason}}),
    do: is_binary(name) and reason in @invalid_param_reasons

  defp answered?({:error, %{status: 500, body: body}}) when is_binary(body),
    do: String.starts_with?(body, @pinned_500_prefixes)

  defp answered?({:error, %{status: status, body: body}}),
    do: status in @answer_statuses and is_binary(body)

  defp answered?(_other), do: false

  # Runs `fun` and asserts that it answered, by name, with an exception nowhere, and that
  # no atom now exists for the text; a failure names the statement (`label`) that did it.
  defp ask_call(text, label, fun) do
    answer =
      try do
        fun.()
      rescue
        exception -> {:raised, Exception.message(exception)}
      catch
        kind, reason -> {kind, reason}
      end

    assert answered?(answer), "#{label} => #{inspect(answer)}"
    assert_no_atom(text, label)
  end

  defp ask(text, fun, statement), do: ask_call(text, statement, fn -> fun.(statement) end)

  describe "no atom is made from the text of a statement" do
    # The first statement in a fresh VM met an atom that did not exist yet, and raised. A
    # test cannot make a VM fresh, but it can use a text that no atom exists for and ask the
    # VM, after the statements, whether one was made for it: `String.to_existing_atom/1` of
    # the text raises when none was. The text stands where the statements read names and
    # operands: as a measurement, a field, a tag, a function, a time unit, and the operand of
    # each clause.
    test "in an InfluxQL statement", %{conn: conn} do
      text = unique_text()

      {:ok, :written} =
        Local.write(conn, "#{text},t=a #{text}=1.5 1000000000", database: "clauses_db")

      statements = [
        "SELECT #{text} FROM #{text}",
        "SELECT #{text}(v) FROM m",
        "SELECT mean(#{text}) FROM #{text} GROUP BY #{text}",
        "SELECT v FROM #{text}.#{text}",
        "SELECT v FROM m WHERE #{text} = '#{text}'",
        "SELECT v FROM m WHERE host = #{text}",
        "SELECT v FROM m WHERE time > #{text}",
        "SELECT v FROM m LIMIT #{text}",
        "SELECT v FROM m OFFSET #{text}",
        "SELECT v FROM m LIMIT #{text} OFFSET #{text}",
        "SELECT v FROM m SLIMIT #{text}",
        "SELECT v FROM m SOFFSET #{text}",
        "SELECT v FROM m SLIMIT #{text} SOFFSET #{text}",
        "SELECT v FROM m GROUP BY #{text}",
        "SELECT v FROM m GROUP BY time(#{text})",
        "SELECT v FROM m GROUP BY host fill(#{text})",
        "SELECT mean(v) FROM m GROUP BY time(1s) fill(#{text})",
        "SELECT v FROM m ORDER BY #{text}",
        "SELECT v FROM m ORDER BY time #{text}",
        "SELECT v AS #{text} FROM m",
        "SELECT v::#{text} FROM m",
        "SHOW TAG KEYS FROM #{text}",
        "SHOW FIELD KEYS FROM #{text}",
        "SHOW TAG VALUES FROM #{text} WITH KEY = #{text}",
        "SHOW #{text}"
      ]

      for statement <- statements do
        ask(text, &Local.query_influxql(conn, &1, database: "clauses_db"), statement)
        ask(text, &Local.query_influxql(conn, &1, database: text), statement)
      end

      assert_no_atom(text, "the test as a whole")
    end

    test "in a SQL statement", %{conn: conn} do
      text = unique_text()

      {:ok, :written} =
        Local.write(conn, "#{text},t=a #{text}=1.5 1000000000", database: "clauses_db")

      statements = [
        "SELECT #{text} FROM #{text}",
        "SELECT \"#{text}\" FROM \"#{text}\"",
        "SELECT #{text}(v) FROM m",
        "SELECT v AS #{text} FROM m",
        "SELECT v FROM m AS #{text}",
        "SELECT #{text}.v FROM m AS #{text}",
        "SELECT v FROM #{text}.m",
        "SELECT v FROM m WHERE #{text} = '#{text}'",
        "SELECT v FROM m WHERE host = #{text}",
        "SELECT v FROM m WHERE v IN (#{text}, 1)",
        "SELECT v FROM m GROUP BY #{text}",
        "SELECT v FROM m ORDER BY #{text}",
        "SELECT v FROM m LIMIT #{text}",
        "SELECT v FROM m LIMIT 1 OFFSET #{text}",
        "SELECT CAST(v AS #{text}) FROM m",
        "SELECT v::#{text} FROM m",
        "SELECT date_trunc('#{text}', time) FROM m",
        "SELECT v FROM m WHERE time > now() - interval '#{text}'",
        "WITH #{text} AS (SELECT v FROM m) SELECT * FROM #{text}",
        "INSERT INTO #{text} (#{text}) VALUES (#{text})",
        "INSERT INTO m (#{text}) VALUES (1)",
        "INSERT INTO m (v) SELECT #{text} FROM #{text}",
        "UPDATE #{text} SET #{text} = #{text} WHERE #{text} = #{text}",
        "UPDATE m SET #{text} = #{text}(v)",
        "DELETE FROM #{text} WHERE #{text} = #{text}",
        "DELETE FROM m WHERE #{text} = '#{text}'",
        "SHOW #{text}",
        "SELECT * FROM information_schema.#{text}"
      ]

      for statement <- statements do
        ask(text, &Local.query_sql(conn, &1, database: "clauses_db"), statement)
        ask(text, &Local.query_sql(conn, &1, database: text), statement)
      end

      assert_no_atom(text, "the test as a whole")
    end

    test "in more SQL statements: EXPLAIN, SET, COPY, SHOW and the rest", %{conn: conn} do
      text = unique_text()

      statements = [
        "EXPLAIN SELECT #{text} FROM #{text}",
        "EXPLAIN ANALYZE SELECT v FROM #{text}",
        "EXPLAIN VERBOSE SELECT v FROM m WHERE #{text} = 1",
        "EXPLAIN #{text}",
        "SET #{text} = #{text}",
        "SET #{text} TO '#{text}'",
        "SET TIME ZONE '#{text}'",
        "SET TIME ZONE #{text}",
        "RESET #{text}",
        "COPY m TO '#{text}'",
        "COPY #{text} TO '#{text}' (FORMAT #{text})",
        "COPY (SELECT #{text} FROM m) TO '#{text}'",
        "COPY m FROM '#{text}'",
        "SHOW TABLES",
        "SHOW TABLES FROM #{text}",
        "SHOW COLUMNS FROM #{text}",
        "SHOW COLUMNS IN #{text} FROM #{text}",
        "SHOW ALL",
        "SHOW #{text} #{text}",
        "SHOW CREATE TABLE #{text}",
        "SHOW FUNCTIONS LIKE '#{text}'",
        "DESCRIBE #{text}",
        "DESC #{text}",
        "CREATE TABLE #{text} (#{text} INT)",
        "CREATE VIEW #{text} AS SELECT v FROM m",
        "CREATE DATABASE #{text}",
        "DROP TABLE #{text}",
        "DROP DATABASE #{text}",
        "PREPARE #{text} AS SELECT v FROM m",
        "EXECUTE #{text}(#{text})",
        "DEALLOCATE #{text}",
        "BEGIN #{text}",
        "USE #{text}",
        "VALUES (#{text}), (#{text})",
        "SELECT * FROM (SELECT #{text} FROM m) AS #{text}",
        "SELECT v FROM m UNION SELECT #{text} FROM #{text}"
      ]

      for statement <- statements do
        ask(text, &Local.query_sql(conn, &1, database: "clauses_db"), statement)
        ask(text, &Local.execute_sql(conn, &1, database: "clauses_db"), statement)
      end

      assert_no_atom(text, "the test as a whole")
    end

    test "in the parameters of a SQL or an InfluxQL query", %{conn: conn} do
      text = unique_text()

      sql = [
        {"SELECT v FROM m WHERE host = $#{text}", %{text => "a"}},
        {"SELECT v FROM m WHERE host = $#{text}", %{text => text}},
        {"SELECT v FROM m WHERE host = $#{text}", %{text => 1}},
        {"SELECT v FROM m WHERE host = $#{text}", %{text => nil}},
        {"SELECT v FROM m WHERE host = $#{text}", %{"other_#{text}" => "a"}},
        {"SELECT v FROM m WHERE host = $1", %{text => "a"}},
        {"SELECT $#{text} FROM m", %{text => [text]}},
        {"SELECT v FROM m LIMIT $#{text}", %{text => text}}
      ]

      for {statement, params} <- sql do
        label = "#{statement} #{inspect(params)}"

        ask_call(text, label, fn ->
          Local.query_sql(conn, statement, database: "clauses_db", params: params)
        end)

        ask_call(text, label, fn ->
          Local.query_influxql(conn, statement, database: "clauses_db", params: params)
        end)
      end

      assert_no_atom(text, "the test as a whole")
    end

    test "in the Flux of a query" do
      text = unique_text()
      {:ok, v2} = Local.start(profile: :v2, org: text)
      :ok = Local.create_bucket(v2, "b")
      :ok = Local.create_bucket(v2, text)
      {:ok, :written} = Local.write(v2, "m,host=a v=1.5 1000000000", database: "b")

      {:ok, :written} =
        Local.write(v2, "#{text},#{text}=a #{text}=1.5 1000000000", database: text)

      base = ~s/from(bucket: "b") |> range(start: 0)/

      queries = [
        ~s/from(bucket: "#{text}") |> range(start: 0)/,
        ~s/from(bucket: #{text}) |> range(start: 0)/,
        ~s/from(#{text}: "b") |> range(start: 0)/,
        ~s/#{text}(bucket: "b") |> range(start: 0)/,
        ~s/#{base} |> #{text}()/,
        ~s/#{base} |> #{text}(#{text}: "#{text}")/,
        ~s/#{base} |> filter(fn: (r) => r._measurement == "#{text}")/,
        ~s/#{base} |> filter(fn: (r) => r.#{text} == "#{text}")/,
        ~s/#{base} |> filter(fn: (r) => r["#{text}"] == #{text})/,
        ~s/#{base} |> filter(fn: (#{text}) => #{text}._field == "#{text}")/,
        ~s/#{base} |> filter(#{text}: (r) => r._field == "v")/,
        ~s/#{base} |> filter(fn: (r) => r._field == "v" and r.#{text} != "#{text}")/,
        ~s/from(bucket: "b") |> range(start: #{text})/,
        ~s/from(bucket: "b") |> range(start: 0, stop: #{text})/,
        ~s/from(bucket: "b") |> range(start: -#{text}h)/,
        ~s/from(bucket: "b") |> range(#{text}: 0)/,
        ~s/#{base} |> limit(n: #{text})/,
        ~s/#{base} |> first(column: "#{text}")/,
        ~s/#{base} |> yield(name: "#{text}")/,
        ~s/#{base} |> yield(#{text}: "#{text}")/,
        ~s/import "#{text}"\n#{base}/,
        ~s/import "#{text}"\nimport #{text} "#{text}"\n#{base}/,
        ~s/import "#{text}"\n#{base} |> #{text}.sum()/,
        ~s/#{text} = #{text}\n#{base}/,
        ~s/option #{text} = "#{text}"\n#{base}/
      ]

      for flux <- queries do
        ask_call(text, flux, fn -> Local.query_flux(v2, flux) end)
        ask_call(text, flux, fn -> Local.query_flux(v2, flux, database: text) end)
      end

      assert_no_atom(text, "the test as a whole")
    end

    test "in line protocol: names, tags, string values, escapes and parameters", %{conn: conn} do
      text = unique_text()
      {:ok, v2} = Local.start(profile: :v2, org: text)
      :ok = Local.create_bucket(v2, text)

      payloads = [
        "#{text},#{text}=#{text} #{text}=1.5 1",
        "#{text},#{text}=#{text} #{text}=1i 1",
        ~s|#{text},t=a #{text}="#{text}" 1|,
        ~s|#{text},t=a f="#{text} \\" \\\\ #{text}" 1|,
        ~s|#{text},t=a f=#{text} 1|,
        ~s|#{text},t=a f=#{text}i 1|,
        ~s|#{text},t=a f=1 #{text}|,
        ~s|#{text}\\ x,#{text}\\,k=\\ #{text}\\=v f=1 1|,
        ~s|m,#{text}\\ k=a\\ #{text} #{text}\\ f=1 1|,
        ~s|m,t=a f=t,#{text}=T,g=#{text} 1|,
        "#{text} #{text}",
        "#{text}",
        "m,#{text} f=1 1",
        "m,t=#{text} #{text} 1",
        "# #{text}\n#{text},t=a f=1 1\n\n#{text} f=2 2"
      ]

      for payload <- payloads do
        ask_call(text, payload, fn -> Local.write(conn, payload, database: "clauses_db") end)
        ask_call(text, payload, fn -> Local.write(conn, payload, database: text) end)
        ask_call(text, payload, fn -> Local.write(v2, payload, database: text) end)

        ask_call(text, payload, fn ->
          Local.write(v2, payload, database: text, org: text, bucket: text, precision: text)
        end)

        ask_call(text, payload, fn ->
          Local.write(conn, payload, database: "clauses_db", precision: text)
        end)
      end

      assert_raise ArgumentError, fn -> Local.start(profile: text) end
      assert_no_atom(text, "the test as a whole")
    end

    test "in the names of databases, buckets and tokens", %{conn: conn} do
      text = unique_text()
      {:ok, v2} = Local.start(profile: :v2, org: text)
      {:ok, enterprise} = Local.start(profile: :v3_enterprise, org: text, databases: [text])

      calls = [
        {"create_database", fn -> Local.create_database(conn, text) end},
        {"create_database retention",
         fn -> Local.create_database(conn, text, retention: text) end},
        {"create_database again", fn -> Local.create_database(conn, text) end},
        {"list_databases", fn -> Local.list_databases(conn) end},
        {"delete_database", fn -> Local.delete_database(conn, text) end},
        {"delete_database missing", fn -> Local.delete_database(conn, text) end},
        {"create_token", fn -> Local.create_token(conn, text) end},
        {"create_token again", fn -> Local.create_token(conn, text) end},
        {"create_token expiry", fn -> Local.create_token(conn, text, expiry_secs: text) end},
        {"create_token permissions",
         fn -> Local.create_token(enterprise, text, permissions: ["db:#{text}:read"]) end},
        {"create_token bad permissions",
         fn ->
           Local.create_token(enterprise, "p_#{text}", permissions: [text, "#{text}:#{text}"])
         end},
        {"delete_token", fn -> Local.delete_token(conn, text) end},
        {"delete_token missing", fn -> Local.delete_token(conn, text) end},
        {"create_bucket", fn -> Local.create_bucket(v2, text) end},
        {"create_bucket retention", fn -> Local.create_bucket(v2, text, retention: text) end},
        {"list_buckets", fn -> Local.list_buckets(v2) end},
        {"delete_bucket", fn -> Local.delete_bucket(v2, text) end},
        {"delete_bucket missing", fn -> Local.delete_bucket(v2, text) end},
        {"v3 bucket", fn -> Local.create_bucket(conn, text) end},
        {"v2 database", fn -> Local.create_database(v2, text) end},
        {"health", fn -> Local.health(enterprise) end}
      ]

      for {label, call} <- calls, do: ask_call(text, label, call)

      assert_no_atom(text, "the test as a whole")
    end

    # Every spelling the tests send or derive: the text, upper-, lower- and capitalised, and
    # with the prefixes of the derived names (`other_`, `p_`, `v2_`).
    defp spellings(text) do
      for base <- [text, "other_" <> text, "p_" <> text, "v2_" <> text],
          form <- [base, String.upcase(base), String.downcase(base), String.capitalize(base)],
          uniq: true,
          do: form
    end

    defp assert_no_atom(text, label) do
      for spelling <- spellings(text) do
        try do
          atom = String.to_existing_atom(spelling)
          flunk("#{label}: an atom was made for #{inspect(spelling)}: #{inspect(atom)}")
        rescue
          ArgumentError -> :ok
        end
      end

      :ok
    end

    test "the check fails for an atom made from any spelling (positive control)" do
      for make <- [
            & &1,
            &String.upcase/1,
            &String.downcase/1,
            &String.capitalize/1,
            &("other_" <> &1),
            &("p_" <> &1),
            &("v2_" <> &1)
          ] do
        text = unique_text()
        _atom = text |> make.() |> String.to_atom()

        assert_raise ExUnit.AssertionError, ~r/an atom was made for/, fn ->
          assert_no_atom(text, "control")
        end
      end
    end
  end
end
