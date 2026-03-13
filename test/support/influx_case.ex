defmodule InfluxElixir.InfluxCase do
  @moduledoc """
  Shared ExUnit case template for InfluxElixir internal tests.

  Including this template in a test module:

  - Aliases the most-used modules (`Local`, `Point`, `LineProtocol`)
  - Starts a fresh `LocalClient` with a `"test_db"` database for every test
  - Registers an `on_exit/1` callback that cleans up the ETS table

  ## Usage

      defmodule InfluxElixir.SomeTest do
        use InfluxElixir.InfluxCase, async: true

        test "writes a point", %{conn: conn} do
          assert :ok == Local.write(conn, "cpu value=1.0", database: "test_db")
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias InfluxElixir.Client.Local
      alias InfluxElixir.Write.{LineProtocol, Point}
    end
  end

  setup do
    {:ok, conn} = InfluxElixir.Client.Local.start(databases: ["test_db"])
    on_exit(fn -> InfluxElixir.Client.Local.stop(conn) end)
    {:ok, conn: conn}
  end
end
