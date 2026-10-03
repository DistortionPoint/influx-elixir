defmodule InfluxElixir.Integration.ContractV3Core.SqlScalarErrorsTest do
  @moduledoc """
  The `:errors` part of `InfluxElixir.Contract.SQLScalar`
  (type, arity and value errors)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :errors
end
