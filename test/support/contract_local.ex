defmodule InfluxElixir.ContractLocal do
  @moduledoc """
  Shared setup of the Local contract modules.

  Each contract runs in its own ExUnit module so that the modules compile and
  run in parallel. `use InfluxElixir.ContractLocal, profile: profile` makes the
  using module an async ExUnit case whose every test gets a fresh in-memory
  `Client.Local` of `profile` with the database `contract_db`, and no query
  delay (Local is synchronous). The contract itself is then `use`d beside it.

      defmodule InfluxElixir.ContractLocal.V3Core.ClientTest do
        use InfluxElixir.ContractLocal, profile: :v3_core
        use InfluxElixir.ClientContract, client: InfluxElixir.Client.Local, profile: :v3_core
      end
  """

  @doc false
  defmacro __using__(opts) do
    profile = Keyword.fetch!(opts, :profile)

    quote do
      use ExUnit.Case, async: true

      setup do
        {:ok, conn} =
          InfluxElixir.Client.Local.start(databases: ["contract_db"], profile: unquote(profile))

        {:ok, conn: conn, database: "contract_db"}
      end
    end
  end
end
