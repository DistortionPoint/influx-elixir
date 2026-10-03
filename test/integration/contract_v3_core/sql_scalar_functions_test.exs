defmodule InfluxElixir.Integration.ContractV3Core.SqlScalarFunctionsTest do
  @moduledoc """
  The `:functions` part of `InfluxElixir.Contract.SQLScalar`
  (string and math functions)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :functions
end
