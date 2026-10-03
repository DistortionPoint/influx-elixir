defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlScalarFunctionsTest do
  @moduledoc """
  The `:functions` part of `InfluxElixir.Contract.SQLScalar`
  (string and math functions)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :functions
end
