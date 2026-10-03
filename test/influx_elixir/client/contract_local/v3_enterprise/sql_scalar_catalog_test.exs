defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlScalarCatalogTest do
  @moduledoc """
  The `:catalog` part of `InfluxElixir.Contract.SQLScalar`
  (the parser, SHOW COLUMNS and the information_schema)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :catalog
end
