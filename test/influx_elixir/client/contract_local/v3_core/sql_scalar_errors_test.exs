defmodule InfluxElixir.ContractLocal.V3Core.SqlScalarErrorsTest do
  @moduledoc """
  The `:errors` part of `InfluxElixir.Contract.SQLScalar`
  (type, arity and value errors)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :errors
end
