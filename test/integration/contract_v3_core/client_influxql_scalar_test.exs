defmodule InfluxElixir.Integration.ContractV3Core.ClientInfluxqlScalarTest do
  @moduledoc """
  The `:influxql_scalar` part of `InfluxElixir.ClientContract`
  (InfluxQL, scalar functions, query formats)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :influxql_scalar
end
