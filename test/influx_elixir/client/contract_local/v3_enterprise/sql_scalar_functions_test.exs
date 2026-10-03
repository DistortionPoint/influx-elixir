defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlScalarFunctionsTest do
  @moduledoc """
  The `:functions` part of `InfluxElixir.Contract.SQLScalar`
  (string and math functions)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :functions
end
