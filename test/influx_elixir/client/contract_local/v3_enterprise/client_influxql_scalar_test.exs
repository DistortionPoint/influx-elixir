defmodule InfluxElixir.ContractLocal.V3Enterprise.ClientInfluxqlScalarTest do
  @moduledoc """
  The `:influxql_scalar` part of `InfluxElixir.ClientContract`
  (InfluxQL, scalar functions, query formats)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :influxql_scalar
end
