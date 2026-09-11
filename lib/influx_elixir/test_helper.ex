defmodule InfluxElixir.TestHelper do
  @moduledoc """
  Test setup helpers for consuming applications.

  Provides convenience functions for configuring `InfluxElixir.Client.Local`
  with per-test ETS isolation for `async: true` tests. This module ships in
  the package (it lives under `lib/`), so it is available to any consumer's
  test suite; it only calls `ExUnit` at runtime, from inside a test.

  ## Usage in a consuming application's test suite

      defmodule MyApp.TimeSeriesTest do
        use ExUnit.Case, async: true
        import InfluxElixir.TestHelper

        setup do
          setup_influx(databases: ["mydb"])
        end

        test "writes and reads data", %{conn: conn} do
          {:ok, :written} = InfluxElixir.write(conn, "cpu value=1.0", database: "mydb")
          {:ok, [row]} = InfluxElixir.query_sql(conn, "SELECT * FROM cpu", database: "mydb")
          assert row["value"] == 1.0
        end
      end

  The `setup_influx/1` helper registers an `on_exit/1` callback that tears
  down the ETS table automatically, so there is no manual cleanup required.
  """

  alias InfluxElixir.Client.Local

  @doc """
  Sets up a `Client.Local` instance for use in an ExUnit test.

  Starts a fresh in-memory `Client.Local`, passing `opts` straight to
  `InfluxElixir.Client.Local.start/1` (so `:databases`, `:database` and
  `:profile` all work), and registers an `on_exit/1` callback to stop the
  client when the test finishes.

  Returns `{:ok, conn: conn}` so it can be returned directly from an ExUnit
  `setup` block, merging `conn` into the test context map.

  ## Options

    * `:databases` — list of database name strings to pre-create (default: `[]`)
    * `:database` — connection-level default database
    * `:profile` — `:v3_core` (default), `:v3_enterprise` or `:v2`

  ## Examples

      setup do
        setup_influx(databases: ["metrics", "events"])
      end

      test "writes a point", %{conn: conn} do
        assert {:ok, :written} = InfluxElixir.write(conn, "m v=1i", database: "metrics")
      end
  """
  @spec setup_influx(keyword()) :: {:ok, [{:conn, Local.conn()}]}
  def setup_influx(opts \\ []) do
    {:ok, conn} = Local.start(opts)
    ExUnit.Callbacks.on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end
end
