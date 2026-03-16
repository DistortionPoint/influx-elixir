defmodule InfluxElixir.TestHelper do
  @moduledoc """
  Test setup helpers for consuming applications.

  Provides convenience functions for configuring `InfluxElixir.Client.Local`
  with per-process ETS isolation for `async: true` tests.

  ## Usage in a consuming application's test suite

      defmodule MyApp.TimeSeriesTest do
        use ExUnit.Case, async: true
        import InfluxElixir.TestHelper

        setup do
          setup_influx(databases: ["mydb"])
        end

        test "writes and reads data", %{conn: conn} do
          :ok = InfluxElixir.Client.Local.write(conn, "cpu value=1.0", [])
          {:ok, rows} = InfluxElixir.Client.Local.query_sql(conn, "SELECT * FROM cpu", [])
          assert length(rows) == 1
        end
      end

  The `setup_influx/1` helper registers an `on_exit/1` callback that tears
  down the ETS table automatically, so there is no manual cleanup required.
  """

  alias InfluxElixir.Client.Local

  @doc """
  Sets up a `LocalClient` instance for use in an ExUnit test.

  Starts a fresh in-memory `LocalClient`, optionally pre-creating the
  databases listed in `:databases`, and registers an `on_exit/1` callback
  to stop the client when the test finishes.

  Returns `{:ok, %{conn: conn}}` so it can be returned directly from an
  ExUnit `setup` block, merging `conn` into the test context map.

  ## Options

    * `:databases` — list of database name strings to pre-create
      (default: `[]`)

  ## Examples

      setup do
        setup_influx(databases: ["metrics", "events"])
      end

      test "writes a point", %{conn: conn} do
        assert :ok == InfluxElixir.Client.Local.write(conn, "m v=1i", [])
      end
  """
  @spec setup_influx(keyword()) :: {:ok, [{:conn, Local.conn()}]}
  def setup_influx(opts \\ []) do
    {:ok, conn} = Local.start(opts)
    ExUnit.Callbacks.on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end
end
