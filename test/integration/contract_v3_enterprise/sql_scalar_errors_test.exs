defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlScalarErrorsTest do
  @moduledoc """
  The `:errors` part of `InfluxElixir.Contract.SQLScalar`
  (type, arity and value errors)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :errors
end
