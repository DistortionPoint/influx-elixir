defmodule InfluxElixir.ContractLocal.V3Core.SqlScalarFunctionsTest do
  @moduledoc """
  The `:functions` part of `InfluxElixir.Contract.SQLScalar`
  (string and math functions)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :functions
end
