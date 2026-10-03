defmodule InfluxElixir.ClientContract do
  @moduledoc """
  Shared contract test template for InfluxDB client implementations.

  This module defines a complete set of assertions covering every callback
  in `InfluxElixir.Client`. The **same** assertions run against both
  `InfluxElixir.Client.Local` and `InfluxElixir.Client.HTTP`, proving
  behavioral equivalence.

  ## Usage

  Each "using" module provides connection setup and declares a profile:

      defmodule MyApp.ContractLocalV3CoreTest do
        use InfluxElixir.ClientContract,
          client: InfluxElixir.Client.Local,
          profile: :v3_core

        setup do
          {:ok, conn} = Local.start(databases: ["contract_db"], profile: :v3_core)
          {:ok, conn: conn, database: "contract_db"}
        end
      end

  A `Client.Local` connection needs no `on_exit` stop: its store is tied to the
  test process and goes with it.

  ## Context keys

  The `setup` callback must return:

    * `conn` — client connection (keyword list or map)
    * `database` — test database name

  and may return:

    * `time_slack` — seconds the server's clock may differ from this
      one (default 5; a context for a real server sets it wider)

  ## Profile gating

  Test blocks are only compiled for profiles that support them.
  The profile is known at compile time, so unsupported test blocks
  are simply not generated — zero runtime overhead.

  ## Parts

  The contract is large, and a module that generates all of it is slow to
  compile. `part: part` generates one slice of it, so that each slice can be its
  own ExUnit module compiled and run in parallel with the others. Without
  `:part` (or with `part: :all`) everything is generated; the parts of a profile
  together generate exactly that.

    * `:write_admin` — health, write, line protocol, precision, gzip, databases
    * `:sql_query` — SQL queries, aggregates, CTEs, filters, joins, casts
    * `:sql_semantics` — OFFSET, DISTINCT, parameters, literals, NULLs, references
    * `:influxql_scalar` — InfluxQL, scalar functions, query formats
    * `:v2_write` — buckets, v2 write rules, bodies, precision, duplicates (`:v2` profile only)
    * `:v2_flux` — Flux query errors (`:v2` profile only; the rows Flux returns are
      pinned by `InfluxElixir.Contract.Flux`)
  """

  # Each part is a module under `test/support/client_contract/` that builds its
  # blocks of tests for a client and a profile (none for a profile it does not
  # run). `InfluxElixir.ClientContract.Helpers` holds the helpers the tests call.
  @part_modules [
    write_admin: InfluxElixir.ClientContract.WriteAdmin,
    sql_query: InfluxElixir.ClientContract.SqlQuery,
    sql_semantics: InfluxElixir.ClientContract.SqlSemantics,
    influxql_scalar: InfluxElixir.ClientContract.InfluxqlScalar,
    v2_write: InfluxElixir.ClientContract.V2Write,
    v2_flux: InfluxElixir.ClientContract.V2Flux
  ]

  @parts Keyword.keys(@part_modules)

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)
    part = Keyword.get(opts, :part, :all)

    unless part == :all or part in @parts do
      raise ArgumentError,
            "unknown :part #{inspect(part)}, expected :all or one of #{inspect(@parts)}"
    end

    blocks =
      for {block_part, module} <- @part_modules,
          part == :all or part == block_part,
          block <- module.blocks(client, profile),
          do: block

    quote location: :keep do
      (unquote_splicing(blocks))
    end
  end

  # The helpers live in `InfluxElixir.ClientContract.Helpers`; the contract tests
  # (here and in the other contracts) call them through this module.
  @doc false
  defdelegate settle(ctx), to: InfluxElixir.ClientContract.Helpers
  @doc false
  defdelegate with_database(conn, database), to: InfluxElixir.ClientContract.Helpers
  @doc false
  defdelegate with_scratch(client, ctx, kind, prefix, fun),
    to: InfluxElixir.ClientContract.Helpers

  @doc false
  defdelegate with_scratch_many(client, ctx, kind, prefix, count, fun),
    to: InfluxElixir.ClientContract.Helpers

  @doc false
  defdelegate don(client, ctx, sql), to: InfluxElixir.ClientContract.Helpers
  @doc false
  defdelegate ident(client, ctx, sql), to: InfluxElixir.ClientContract.Helpers
  @doc false
  defdelegate run(client, ctx, sql), to: InfluxElixir.ClientContract.Helpers
  @doc false
  defdelegate rows(client, ctx, sql), to: InfluxElixir.ClientContract.Helpers
  @doc false
  defdelegate column(client, ctx, key, sql), to: InfluxElixir.ClientContract.Helpers
  @doc false
  defdelegate where_values(client, ctx, where), to: InfluxElixir.ClientContract.Helpers
  @doc false
  defdelegate unix_times(client, ctx, where), to: InfluxElixir.ClientContract.Helpers
  @doc false
  defdelegate bad_precision(name), to: InfluxElixir.ClientContract.Helpers
  @doc false
  defdelegate no_field(printed, table, columns, projection \\ []),
    to: InfluxElixir.ClientContract.Helpers
end
