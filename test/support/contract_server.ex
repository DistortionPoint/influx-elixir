defmodule InfluxElixir.ContractServer do
  @moduledoc """
  Shared setup of the contract modules that run against a real server.

  Each contract runs in its own ExUnit module. `use InfluxElixir.ContractServer,
  profile: profile` gives the using module:

    * the tags `:integration` and the profile's (`:v3_core`, `:v3_enterprise` or
      `:v2`), which `test_helper.exs` excludes unless asked for;
    * its own Finch pool, started for the module and named after it, so that
      modules share no pool;
    * a failure that says so when the server is unreachable;
    * for the v3 profiles a database created for every test and deleted after
      it, so that no two tests share data; for `:v2` the connection's bucket.

  The context holds `conn`, `database`, `query_delay: 0` (InfluxDB 3 Core and
  2.7 answer a query with every write they acknowledged before it; 200
  write-then-read pairs on each found none missing) and `time_slack: 60`
  (how far, in seconds, the server's clock may be from this one).

  Option: `:profile` (required).

  The modules are `async: false`, although each has its own Finch pool and the
  v3 modules give every test its own database, so that they share no data.
  What they share is the server's capacity: InfluxDB 3 Core refuses a sixth
  database ("would exceed limit of 5 databases", counting `_internal`), so
  modules that each hold a database at once cannot all run at the same time
  (measured: three further databases fit on a server that has two of its own);
  a v2 module writes to the one bucket of its connection; and a real server
  ingests asynchronously, so concurrent load only lengthens the waits.
  """

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.IntegrationHelper, as: H

  @doc false
  defmacro __using__(opts) do
    profile = Keyword.fetch!(opts, :profile)

    quote do
      use ExUnit.Case, async: false

      @moduletag :integration
      @moduletag unquote(profile)

      setup_all do
        InfluxElixir.ContractServer.setup_all(unquote(profile), __MODULE__)
      end

      setup ctx do
        InfluxElixir.ContractServer.setup(unquote(profile), ctx)
      end
    end
  end

  @doc false
  @spec setup_all(atom(), module()) :: {:ok, keyword()}
  def setup_all(profile, module) do
    finch = Module.concat(module, Finch)
    {:ok, _pid} = ExUnit.Callbacks.start_supervised({Finch, name: finch, pools: pool()})
    conn = base_conn(profile, finch)

    if H.reachable?(conn) do
      {:ok, base_conn: conn}
    else
      {:ok, skip: true, base_conn: conn}
    end
  end

  @doc false
  @spec setup(atom(), map()) :: {:ok, keyword()}
  def setup(profile, %{base_conn: base_conn} = ctx) do
    if ctx[:skip] do
      ExUnit.Assertions.flunk("#{label(profile)} not reachable on port #{base_conn[:port]}")
    end

    database(profile, base_conn)
  end

  # `:v2` shares the connection's bucket; the v3 profiles create a database per test.
  defp database(:v2, base_conn) do
    {:ok, conn: base_conn, database: base_conn[:database], query_delay: 0, time_slack: 60}
  end

  defp database(profile, base_conn) do
    db = H.unique_name("contract_#{profile}")

    case HTTP.create_database(base_conn, db) do
      :ok ->
        ExUnit.Callbacks.on_exit(fn -> HTTP.delete_database(base_conn, db) end)
        {:ok, conn: base_conn, database: db, query_delay: 0, time_slack: 60}

      {:error, reason} ->
        ExUnit.Assertions.flunk("Failed to create test database: #{inspect(reason)}")
    end
  end

  defp pool, do: %{default: [size: 5]}

  defp base_conn(:v2, finch), do: H.v2_conn(finch_name: finch)
  defp base_conn(:v3_core, finch), do: H.v3_core_conn(finch_name: finch)
  defp base_conn(:v3_enterprise, finch), do: H.v3_enterprise_conn(finch_name: finch)

  defp label(:v2), do: "InfluxDB v2"
  defp label(:v3_core), do: "InfluxDB v3 Core"
  defp label(:v3_enterprise), do: "InfluxDB v3 Enterprise"
end
