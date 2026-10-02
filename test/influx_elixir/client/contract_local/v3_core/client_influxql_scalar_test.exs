defmodule InfluxElixir.ContractLocal.V3Core.ClientInfluxqlScalarTest do
  @moduledoc """
  The `:influxql_scalar` part of `InfluxElixir.ClientContract`
  (InfluxQL, scalar functions, query formats)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :influxql_scalar
end
