defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlScalarCatalogTest do
  @moduledoc """
  The `:catalog` part of `InfluxElixir.Contract.SQLScalar`
  (the parser, SHOW COLUMNS and the information_schema)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :catalog
end
