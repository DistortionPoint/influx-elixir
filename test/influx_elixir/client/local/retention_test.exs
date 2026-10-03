defmodule InfluxElixir.Client.Local.RetentionTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  # The duration grammar, `format/1` and `seconds/1` are exercised through
  # `create_database/3` and `SHOW RETENTION POLICIES` by
  # `InfluxElixir.Contract.Retention` (its `@durations` and `@refused` tables),
  # on this double and on Core. What only the double has is below: the server
  # holds other databases, so a listing of every database is not a contract.
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
end
