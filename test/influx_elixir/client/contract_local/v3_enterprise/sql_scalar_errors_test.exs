defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlScalarErrorsTest do
  @moduledoc """
  The `:errors` part of `InfluxElixir.Contract.SQLScalar`
  (type, arity and value errors)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :errors
end
