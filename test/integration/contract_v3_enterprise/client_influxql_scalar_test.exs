defmodule InfluxElixir.Integration.ContractV3Enterprise.ClientInfluxqlScalarTest do
  @moduledoc """
  The `:influxql_scalar` part of `InfluxElixir.ClientContract`
  (InfluxQL, scalar functions, query formats)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :influxql_scalar
end
